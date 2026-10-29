#!/bin/bash
# steam-remote-server.sh: the Steam Machine side of Steam Machine Remote Access.
# https://github.com/SaintBaron/Steam-Machine-Remote-Access
#
# Installs and maintains everything on the Steam Machine (SteamOS):
#   SSH lockdown    only your PC(s), key + password (or key only, if chosen), no root
#   Firewall        SSH and Sunshine reachable from your PC(s) only
#   Sunshine        on-demand (never at boot), KMS capture, encryption required
#   Sudo rule       lets the client scripts start/stop Sunshine and switch displays
#   Displays        boot on the TV; the client scripts switch to the stream output
#   Idle timer      stops Sunshine (and switches back to the TV) if nobody streams
#   Wake-on-LAN     magic packet only
#   Self-heal       a boot service that puts all of the above back after SteamOS
#                   updates, which can wipe /etc
#
# Everything this script needs lives in /home/.steam-remote (root-owned), because
# /home survives SteamOS updates.
#
# Usage (sudo needed unless marked):
#   steam-remote-server.sh --setup [--client-ip IP] [--pubkey FILE]   first-time setup (interactive)
#   steam-remote-server.sh                     check and repair everything (same as --apply)
#   steam-remote-server.sh --check             report problems only; no sudo needed; exit 1 if any
#   steam-remote-server.sh --outputs           list display outputs; no sudo needed
#   steam-remote-server.sh --displays          choose the stream and TV outputs again
#   steam-remote-server.sh --add-client IP [--pubkey FILE]
#   steam-remote-server.sh --remove-client IP
#   steam-remote-server.sh --remote-add ADDRESS     allow a PC's VPN address (remote access)
#   steam-remote-server.sh --remote-remove ADDRESS  stop allowing a VPN address
#   steam-remote-server.sh --set-remote "ADDRESSES" | off   replace the whole remote list (off = home only)
#   steam-remote-server.sh --set-encoder quality|balanced|speed|auto   the video encoder's preset
#   steam-remote-server.sh --set-auth key+password|key   what an SSH login needs
#   steam-remote-server.sh --uninstall [--keep-sunshine] [--keep-ssh]
#   steam-remote-server.sh --version
# No sudo needed (the client scripts use these):
#   --auth-mode          print what an SSH login needs: key+password or key
#   --stream-info [sdr|hdr]  what the stream can do now: dummy plug, HDR, encoder (sdr/hdr:
#                        what this PC asks Moonlight for, so the HDR hint fits)
#   --stream-watch [S] [sdr]   wait up to S seconds for Moonlight to connect; report SDR or HDR
#                              ("sdr": SDR was chosen on purpose, so no HDR hints)
#   --composite on|off   make Game Mode draw onto one layer while streaming, then undo it
#   --hdr on|off         Game Mode's HDR for this stream (Steam's own setting comes back after)
#   --stream-end         put back everything a stream changed in Game Mode (run when Sunshine stops)
# Used by the systemd units it installs:
#   --boot-display   --idle-check   --backup-sunshine

set -u
umask 022

VERSION="1.2.0"
R="${STEAM_REMOTE_TEST_ROOT:-}"   # test prefix only; leave unset for real use

KIT_REAL="/home/.steam-remote"
KIT="$R$KIT_REAL"
SELF_REAL="$KIT_REAL/steam-remote-server.sh"
CONFIG="$KIT/config"
SUN_BACKUP="$KIT/sunshine-backup"
UNITS_DIR="$R/etc/systemd/system"
SSHD_MAIN="$R/etc/ssh/sshd_config"
SSHD_DROPIN="$R/etc/ssh/sshd_config.d/10-steam-remote.conf"
NFT_FILE="$R/etc/steam-remote-guard.nft"
SUDOERS="$R/etc/sudoers.d/zz-steam-remote"
SSHD_UNIT_DROPIN="$R/etc/systemd/system/sshd.service.d/10-steam-remote.conf"
KEEP_LIST="$R/etc/atomic-update.conf.d/steam-remote.conf"
DRM="$R/sys/class/drm"
SUN_APP="dev.lizardbyte.app.Sunshine"
SUN_DATA="$R/root/.var/app/$SUN_APP"
SUN_CONF="$SUN_DATA/config/sunshine/sunshine.conf"
SUN_STATE="$SUN_DATA/config/sunshine/sunshine_state.json"
SUN_UNIT="steam-remote-sunshine.service"
UNITS=(steam-remote-guard.service steam-remote-display.service steam-remote-idle.timer steam-remote-heal.service)
ALL_UNIT_FILES=(steam-remote-guard.service "$SUN_UNIT" steam-remote-display.service
                steam-remote-idle.service steam-remote-idle.timer steam-remote-heal.service)

# Defaults, overridden by $CONFIG.
USER_NAME="deck"
ALLOWED_IPS=""
REMOTE_IPS=""
STREAM_OUTPUT=""
TV_OUTPUT=""
IDLE_MINUTES="60"
SUNSHINE_NAME="steam-machine"
WAKE_ON_LAN="yes"
ENCODER_QUALITY="quality"
AUTH_MODE="key+password"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
log()  { echo "steam-remote: $*"; }
warn() { printf '\033[1;33mWarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }
sc()   { if [ -n "$R" ]; then echo "(test) systemctl $*" >>"$R/systemctl.log"; return 0; fi; systemctl "$@"; }
ORIG_ARGS="$*"
need_root() { [ -n "$R" ] || [ "$(id -u)" = 0 ] || die "Run this with sudo: sudo $0 $ORIG_ARGS"; }
ask() { local reply; read -r -p "$1" reply </dev/tty; printf '%s' "$reply"; }

valid_ip()     { [[ "$1" =~ ^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$ ]]; }
valid_output() { [[ "$1" =~ ^card[0-9]+-[A-Za-z0-9-]+$ ]]; }
valid_user()   { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
valid_name()   { [[ "$1" =~ ^[A-Za-z0-9._-]{1,40}$ ]]; }
# A remote (VPN) address: a private address, a private /24-or-smaller range, or a single
# Tailscale-style 100.64.0.0/10 address. Public addresses are refused: this project never
# exposes SSH or Sunshine to the internet directly.
valid_remote() {
  local ip=${1%/*} len=32 a b
  [[ "$1" == */* ]] && len=${1#*/}
  valid_ip "$ip" && [[ "$len" =~ ^[0-9]+$ ]] || return 1
  IFS=. read -r a b _ _ <<<"$ip"
  if [ "$a" = 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ]; then [ "$len" = 32 ]; return; fi
  [ "$len" -ge 24 ] && [ "$len" -le 32 ] || return 1
  # A range must be written as its network address (192.168.3.0/24, not 192.168.3.7/24).
  local c d; IFS=. read -r _ _ c d <<<"$ip"
  [ $(( ((c << 8) | d) & ((1 << (32 - len)) - 1) )) -eq 0 ] || return 1
  [ "$a" = 10 ] || { [ "$a" = 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ]; } || { [ "$a" = 192 ] && [ "$b" = 168 ]; }
}

# ------------------------------------------------------------------ config
# The config is root-owned (only root can change it), but it is parsed, not sourced,
# and every value is validated before use.
load_config() {
  [ -f "$CONFIG" ] || return 1
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^([A-Z_]+)=(\"([^\"]*)\"|([^[:space:]#\"]*))[[:space:]]*(#.*)?$ ]] || continue
    key=${BASH_REMATCH[1]}; val=${BASH_REMATCH[3]}${BASH_REMATCH[4]}
    case "$key" in
      USER_NAME|ALLOWED_IPS|REMOTE_IPS|STREAM_OUTPUT|TV_OUTPUT|IDLE_MINUTES|SUNSHINE_NAME|WAKE_ON_LAN|ENCODER_QUALITY|AUTH_MODE) printf -v "$key" '%s' "$val" ;;
    esac
  done <"$CONFIG"
  # A mistyped preset isn't worth locking anyone out over: use the default.
  [[ "$ENCODER_QUALITY" =~ ^(quality|balanced|speed|auto)$ ]] || ENCODER_QUALITY=quality
  # Anything but an exact "key" keeps the stricter key-and-password login.
  [ "$AUTH_MODE" = key ] || AUTH_MODE="key+password"
  return 0
}

validate_config() {
  local ok=0 ip
  valid_user "$USER_NAME" || { warn "USER_NAME '$USER_NAME' isn't a valid user name"; ok=1; }
  [ -n "$ALLOWED_IPS" ] || { warn "ALLOWED_IPS is empty: no PC would be able to connect"; ok=1; }
  for ip in $ALLOWED_IPS; do valid_ip "$ip" || { warn "ALLOWED_IPS: '$ip' isn't an IPv4 address"; ok=1; }; done
  for ip in $REMOTE_IPS; do
    valid_remote "$ip" || { warn "REMOTE_IPS: '$ip' isn't allowed. Use a VPN address: private (10.x, 172.16-31.x, 192.168.x, ranges /24 or smaller) or a single Tailscale address (100.64-127.x.x)"; ok=1; }
  done
  [ -z "$STREAM_OUTPUT" ] || valid_output "$STREAM_OUTPUT" || { warn "STREAM_OUTPUT '$STREAM_OUTPUT' isn't an output name like card0-HDMI-A-1"; ok=1; }
  [ -z "$TV_OUTPUT" ] || valid_output "$TV_OUTPUT" || { warn "TV_OUTPUT '$TV_OUTPUT' isn't an output name like card0-DP-1"; ok=1; }
  [[ "$IDLE_MINUTES" =~ ^[0-9]{1,4}$ ]] || { warn "IDLE_MINUTES must be a number of minutes (0 turns it off)"; ok=1; }
  valid_name "$SUNSHINE_NAME" || { warn "SUNSHINE_NAME may only use letters, numbers, . _ and -"; ok=1; }
  [[ "$WAKE_ON_LAN" =~ ^(yes|no)$ ]] || { warn "WAKE_ON_LAN must be yes or no"; ok=1; }
  return $ok
}

write_config() {
  mkdir -p "$KIT"
  local tmp; tmp=$(mktemp)
  cat >"$tmp" <<EOF
# Steam Machine Remote Access: Steam Machine settings.
# After editing, apply with:  sudo $SELF_REAL
# Values are read, not run, so only plain text in quotes works here.

# The Steam Machine account you log in as.
USER_NAME="$USER_NAME"

# The PCs allowed to connect, separated by spaces. Give each one a fixed IP
# (a DHCP reservation) in your router, or you'll lock yourself out when it changes.
ALLOWED_IPS="$ALLOWED_IPS"

# Remote access from outside your home, through a VPN (see docs/remote-access.md).
# The addresses your PC(s) have on the VPN, separated by spaces. Empty = home network only.
# Allowed: private addresses (or private ranges of /24 or smaller) and single Tailscale
# addresses (100.64.x.x-100.127.x.x). Public internet addresses are refused.
REMOTE_IPS="$REMOTE_IPS"

# Display outputs (list them with: $SELF_REAL --outputs).
# STREAM_OUTPUT: the output Sunshine streams from, usually an HDMI/DP dummy plug
#                (EDID emulator). Leave empty to stream whatever screen is on.
# TV_OUTPUT:     the output with your TV/monitor. It's turned off while you stream
#                and turned back on when you disconnect. Leave empty for no TV.
# Switching only happens when both are set.
STREAM_OUTPUT="$STREAM_OUTPUT"
TV_OUTPUT="$TV_OUTPUT"

# Stop Sunshine after this many minutes with nobody streaming (0 = never).
IDLE_MINUTES="$IDLE_MINUTES"

# The name Moonlight shows for this machine.
SUNSHINE_NAME="$SUNSHINE_NAME"

# Keep Wake-on-LAN (magic packet only) switched on for wired connections.
WAKE_ON_LAN="$WAKE_ON_LAN"

# The video encoder's preset: quality (sharpest), balanced, speed (lowest delay) or
# auto (the graphics driver's default). Use balanced or speed if Moonlight's stats
# (Ctrl+Alt+Shift+S) show host processing latency above one frame (16.7 ms at 60 FPS).
ENCODER_QUALITY="$ENCODER_QUALITY"

# What an SSH login needs. key+password (the default): your SSH key AND the $USER_NAME
# password. key: the SSH key only, so give it a strong passphrase. sudo always needs
# the password. See docs/security.md.
AUTH_MODE="$AUTH_MODE"
EOF
  install -m 644 "$tmp" "$CONFIG"; rm -f "$tmp"
  [ -n "$R" ] || chown root:root "$CONFIG"
}

# ------------------------------------------------------------------ outputs
edid_name() {   # the monitor name stored in an EDID, if any
  [ -s "$1" ] || return 0
  python3 -I - "$1" 2>/dev/null <<'PY'
import sys
e = open(sys.argv[1], "rb").read()
for off in (54, 72, 90, 108):
    d = e[off:off + 18]
    if len(d) == 18 and d[:3] == b"\0\0\0" and d[3] == 0xFC:
        name = d[5:].split(b"\n")[0].decode("ascii", "replace")
        print("".join(c for c in name if c.isprintable() and c.isascii()).strip()[:13]); break
PY
}

output_names() {
  local d
  for d in "$DRM"/card*-*; do
    [ -e "$d/status" ] || continue
    echo "${d##*/}"
  done
}

list_outputs() {   # numbered table; argument: "numbered" to show numbers
  local n=0 name d status enabled mode monitor
  printf '  %-3s %-22s %-13s %-9s %-11s %s\n' "#" "Output" "Status" "In use" "Best mode" "Device name (from its EDID)"
  for name in $(output_names); do
    n=$((n + 1)); d="$DRM/$name"
    status=$(cat "$d/status" 2>/dev/null)
    enabled=$(cat "$d/enabled" 2>/dev/null)
    mode=$(head -n 1 "$d/modes" 2>/dev/null)
    monitor=$(edid_name "$d/edid")
    printf '  %-3s %-22s %-13s %-9s %-11s %s\n' "$n" "$name" "${status:-?}" "${enabled:-?}" "${mode:--}" "${monitor:--}"
  done
  [ "$n" -gt 0 ] || echo "  (no display outputs found under $DRM)"
}

output_by_number() { output_names | sed -n "${1}p"; }

choose_outputs() {
  local names count reply
  echo
  say "Display outputs"
  cat <<'EOF'
Sunshine streams whatever is on one display output. Most people stream from a
dummy plug (an HDMI or DisplayPort EDID emulator) so the Steam Machine always
has a "screen", even with the TV off. If you also have a TV plugged in, it can
be switched off while you stream and back on when you disconnect, because Game
Mode only uses one screen at a time.

Tips for telling them apart:
  * The dummy plug shows "connected" even with the TV off; the device name is
    usually the plug's maker or blank.
  * Unplug one, type r to refresh, and see which line changes.
  * "disconnected" for a plug you know is in usually means the adapter isn't
    compatible with that socket (see docs/displays.md: DP++ and active adapters).
EOF
  while :; do
    echo; list_outputs; echo
    names=$(output_names); count=$(printf '%s\n' "$names" | grep -c .)
    reply=$(ask "Which number is the STREAM output (dummy plug)? 0 = none, stream the TV; r = refresh: ")
    [ "$reply" = r ] && continue
    if [ "$reply" = 0 ]; then STREAM_OUTPUT=""
    elif [[ "$reply" =~ ^[0-9]+$ ]] && [ "$reply" -le "$count" ]; then STREAM_OUTPUT=$(output_by_number "$reply")
    else echo "Type a number from the list, 0 or r."; continue; fi

    reply=$(ask "Which number is the TV/monitor output, switched off while streaming? 0 = none: ")
    [ "$reply" = r ] && continue
    if [ "$reply" = 0 ]; then TV_OUTPUT=""
    elif [[ "$reply" =~ ^[0-9]+$ ]] && [ "$reply" -le "$count" ]; then TV_OUTPUT=$(output_by_number "$reply")
    else echo "Type a number from the list, 0 or r."; continue; fi

    if [ -n "$STREAM_OUTPUT" ] && [ "$STREAM_OUTPUT" = "$TV_OUTPUT" ]; then
      echo "The stream and TV outputs must be different (or set one to 0)."; continue
    fi
    echo
    echo "  Stream output: ${STREAM_OUTPUT:-none (stream whatever screen is on)}"
    echo "  TV output:     ${TV_OUTPUT:-none}"
    if [ -n "$STREAM_OUTPUT" ] && [ -n "$TV_OUTPUT" ]; then
      echo "  Switching:     on. Streaming turns $TV_OUTPUT off; disconnecting turns it back on."
    else
      echo "  Switching:     off (it needs both outputs)."
    fi
    [ "$(ask "Is that right? [Y/n] ")" != n ] && break
  done
}

choose_options() {
  local v
  echo
  say "Options (press Enter to keep the value in brackets)"
  echo "Sunshine starts when you connect and stops when you disconnect. If a PC forgets to"
  echo "disconnect, it's stopped after this many minutes with nobody streaming (0 = never)."
  while :; do
    v=$(ask "  Idle stop, in minutes [$IDLE_MINUTES]: "); v=${v:-$IDLE_MINUTES}
    [[ "$v" =~ ^[0-9]{1,4}$ ]] && break
    echo "  Type a number of minutes, like 60, or 0."
  done
  IDLE_MINUTES=$v
  echo
  echo "Wake-on-LAN lets steam-connect wake the Steam Machine from sleep (wired network only,"
  echo "magic packet only, so ordinary network traffic won't wake it)."
  v=$(ask "  Keep Wake-on-LAN on? [Y/n]: ")
  case "$v" in n|N|no) WAKE_ON_LAN=no ;; *) WAKE_ON_LAN=yes ;; esac
  echo
  while :; do
    v=$(ask "  The name Moonlight shows for this machine [$SUNSHINE_NAME]: "); v=${v:-$SUNSHINE_NAME}
    valid_name "$v" && break
    echo "  Use letters, numbers, dots, dashes or underscores (up to 40)."
  done
  SUNSHINE_NAME=$v
  echo
  echo "The encoder preset trades picture quality against delay. 'quality' is the sharpest and"
  echo "suits most streams up to 4K at 60 FPS. Pick 'balanced' for 4K at 120 FPS, or if the"
  echo "stream lags. 'speed' has the lowest delay. 'auto' leaves it to the graphics driver."
  while :; do
    v=$(ask "  Encoder preset: quality, balanced, speed or auto [$ENCODER_QUALITY]: "); v=${v:-$ENCODER_QUALITY}
    [[ "$v" =~ ^(quality|balanced|speed|auto)$ ]] && break
    echo "  Type quality, balanced, speed or auto."
  done
  ENCODER_QUALITY=$v
  echo
  echo "How SSH logins work. key+password (the default) needs your SSH key AND the $USER_NAME"
  echo "password, so a copied key file is useless on its own. key needs the SSH key only: one"
  echo "passphrase, or none once your PC remembers it. Only choose key if the key has a strong"
  echo "passphrase. sudo always needs the password. Details: docs/security.md."
  while :; do
    v=$(ask "  Login: key+password or key [$AUTH_MODE]: "); v=${v:-$AUTH_MODE}
    [[ "$v" =~ ^(key\+password|key)$ ]] && break
    echo "  Type key+password or key."
  done
  AUTH_MODE=$v
}

# Show the TV, ignore the dummy. Used at boot, by the idle timer and by --setup.
show_tv() {
  [ -n "$STREAM_OUTPUT" ] && [ -n "$TV_OUTPUT" ] || return 0
  [ -e "$DRM/$STREAM_OUTPUT/status" ] && echo off >"$DRM/$STREAM_OUTPUT/status" 2>/dev/null
  [ -e "$DRM/$TV_OUTPUT/status" ] && echo detect >"$DRM/$TV_OUTPUT/status" 2>/dev/null
  return 0
}

# ------------------------------------------------------------------ install helpers
CHANGED=()
UNITS_CHANGED=0
# put DEST MODE: desired content on stdin; writes only if missing or different.
put() {
  local dest=$1 mode=$2 tmp
  tmp=$(mktemp) || return 1
  cat >"$tmp"
  if cmp -s "$tmp" "$dest" 2>/dev/null; then
    rm -f "$tmp"; chmod "$mode" "$dest"; [ -n "$R" ] || chown root:root "$dest"
    return 1
  fi
  mkdir -p "$(dirname "$dest")"
  if [ -n "$R" ]; then install -m "$mode" "$tmp" "$dest"; else install -o root -g root -m "$mode" "$tmp" "$dest"; fi
  rm -f "$tmp"
  CHANGED+=("$dest"); log "wrote $dest"
  case "$dest" in "$UNITS_DIR"/*) UNITS_CHANGED=1 ;; esac
  return 0
}

install_self() {   # copy this script into the kit (no-op when already running from it)
  mkdir -p "$KIT"; chmod 755 "$KIT"; [ -n "$R" ] || chown root:root "$KIT"
  local src; src=$(readlink -f "$0")
  if [ "$src" != "$(readlink -f "$KIT/steam-remote-server.sh" 2>/dev/null)" ]; then
    if [ -n "$R" ]; then install -m 755 "$src" "$KIT/steam-remote-server.sh"
    else install -o root -g root -m 755 "$src" "$KIT/steam-remote-server.sh"; fi
    log "installed $KIT_REAL/steam-remote-server.sh (version $VERSION)"
  fi
}

add_pubkey() {   # FILE: append an SSH public key to the user's authorized_keys
  local file=$1 key
  key=$(grep -m 1 -E '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) [A-Za-z0-9+/=]+( [^[:cntrl:]]*)?$' "$file") \
    || die "$file doesn't contain an SSH public key (it should be one line starting with ssh-ed25519)."
  # Done as the user, not root: their home is theirs, so a link planted in ~/.ssh
  # can't trick root into writing somewhere else.
  local as_user=(runuser -u "$USER_NAME" --)
  if [ -n "$R" ]; then as_user=(env HOME="$R/home/$USER_NAME"); fi
  local out
  # shellcheck disable=SC2016  # runs in the user's own shell
  out=$(printf '%s\n' "$key" | "${as_user[@]}" sh -c '
    umask 077
    cd || exit 1
    [ -L .ssh ] || [ -L .ssh/authorized_keys ] && { echo "~/.ssh or authorized_keys is a symlink; not touching it" >&2; exit 1; }
    mkdir -p .ssh && chmod 700 .ssh && touch .ssh/authorized_keys && chmod 600 .ssh/authorized_keys || exit 1
    read -r key
    if grep -qxF "$key" .ssh/authorized_keys; then echo "that key is already authorised"
    else printf "%s\n" "$key" >>.ssh/authorized_keys && echo "authorised the key"; fi' 2>&1) \
    || die "Couldn't add the key to $USER_NAME's authorized_keys: $out"
  log "$out"
}

# ------------------------------------------------------------------ Sunshine data backup
# Pairing and the web UI login live under /root, which a SteamOS update may reset.
# A copy is kept in the kit (root-only) and restored if the original disappears.
backup_sunshine() {
  [ -d "$SUN_DATA/config/sunshine" ] || return 0
  install -d -m 700 "$SUN_BACKUP"
  rm -rf "$SUN_BACKUP/sunshine.new"
  cp -a "$SUN_DATA/config/sunshine" "$SUN_BACKUP/sunshine.new" \
    && rm -rf "$SUN_BACKUP/sunshine" && mv "$SUN_BACKUP/sunshine.new" "$SUN_BACKUP/sunshine"
}
restore_sunshine() {
  if [ ! -e "$SUN_STATE" ] && [ -e "$SUN_BACKUP/sunshine/sunshine_state.json" ]; then
    mkdir -p "$SUN_DATA/config"
    cp -a "$SUN_BACKUP/sunshine" "$SUN_DATA/config/" && { CHANGED+=("Sunshine pairing and login (restored from backup)"); log "restored Sunshine's pairing and login from the backup"; }
  fi
}

# ------------------------------------------------------------------ apply (check and repair)
apply() {
  need_root
  if ! load_config || ! validate_config; then
    # Fail closed: if the lockdown is missing too (say an update removed it), don't let
    # sshd fall back to SteamOS's defaults (password-only logins from anywhere).
    if [ -f "$KIT/steam-remote-server.sh" ] && [ ! -e "$SSHD_DROPIN" ]; then
      mkdir -p "$(dirname "$SSHD_DROPIN")"
      printf '%s\n' "# Steam Machine Remote Access: config missing or invalid, so SSH is closed until it's fixed." \
        "DenyUsers *" >"$SSHD_DROPIN"
      # (sshd's start check also refuses this, so SSH stays off rather than half-open.)
      grep -q '^Include /etc/ssh/sshd_config.d/\*.conf' "$SSHD_MAIN" 2>/dev/null || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$SSHD_MAIN"
      sc --no-block restart sshd.service
      log "SSH is closed until $CONFIG is fixed (at the Steam Machine's keyboard)"
    fi
    [ -f "$CONFIG" ] || die "No config at $CONFIG. Run the first-time setup from your PC (steam-remote-setup), or: sudo $0 --setup"
    die "Fix $CONFIG, then run: sudo $SELF_REAL"
  fi
  local user_uid ips_ssh="" ip set_ips sudo_tee=""
  user_uid=$(id -u "$USER_NAME" 2>/dev/null) || { [ -n "$R" ] && user_uid=1000; } || die "User $USER_NAME doesn't exist"
  for ip in $ALLOWED_IPS $REMOTE_IPS; do ips_ssh+=" $USER_NAME@$ip"; done
  local auth_methods=publickey,password password_auth=yes auth_text="key AND password"
  [ "$AUTH_MODE" = key ] && { auth_methods=publickey; password_auth=no; auth_text="key only (AUTH_MODE=key)"; }
  set_ips=$(echo "$ALLOWED_IPS $REMOTE_IPS" | xargs | sed 's/ /, /g')

  # SSH lockdown
  local ssh_changed=0
  if ! grep -q '^Include /etc/ssh/sshd_config.d/\*.conf' "$SSHD_MAIN" 2>/dev/null; then
    mkdir -p "$(dirname "$SSHD_MAIN")"; touch "$SSHD_MAIN"
    # At the top: sshd uses the first value it reads for each setting.
    local tmp_main; tmp_main=$(mktemp)
    { echo 'Include /etc/ssh/sshd_config.d/*.conf'; cat "$SSHD_MAIN"; } >"$tmp_main" && cat "$tmp_main" >"$SSHD_MAIN" \
      && { ssh_changed=1; CHANGED+=("$SSHD_MAIN (Include line)"); log "added the Include line to $SSHD_MAIN"; }
    rm -f "$tmp_main"
  fi
  # SSH never runs without its lockdown and firewall. SteamOS updates keep this file
  # (*.service.d/** is on SteamOS's own keep list), so even if an update removed the
  # lockdown, sshd would refuse to start rather than fall back to SteamOS's defaults.
  put "$SSHD_UNIT_DROPIN" 644 <<'EOF' || true
# Steam Machine Remote Access: never run SSH without its lockdown and firewall.
[Unit]
Requires=steam-remote-guard.service
After=steam-remote-guard.service steam-remote-heal.service

[Service]
ExecStartPre=/usr/bin/sh -c '/usr/bin/sshd -T 2>/dev/null | grep -qxE "authenticationmethods (publickey,password|publickey)" && /usr/bin/sshd -T 2>/dev/null | grep -q "^allowusers "'
EOF
  # SteamOS updates discard /etc changes not on a keep list. Add ours, so the
  # protections survive updates instead of relying on the boot-time repair alone.
  put "$KEEP_LIST" 644 <<'EOF' || true
# Steam Machine Remote Access: keep these files through SteamOS updates.
/etc/ssh/sshd_config.d/10-steam-remote.conf
/etc/steam-remote-guard.nft
/etc/sudoers.d/zz-steam-remote
/etc/systemd/system/steam-remote-idle.timer
EOF
  put "$SSHD_DROPIN" 644 <<EOF && ssh_changed=1
# Steam Machine Remote Access: only $USER_NAME, only from the allowed PCs, $auth_text.
PermitRootLogin no
AddressFamily inet
AllowUsers$ips_ssh
AuthenticationMethods $auth_methods
PubkeyAuthentication yes
PasswordAuthentication $password_auth
KbdInteractiveAuthentication no
PermitEmptyPasswords no
MaxAuthTries 4
LoginGraceTime 60
MaxStartups 4:50:10
X11Forwarding no
AllowAgentForwarding no
AllowStreamLocalForwarding no
PermitTunnel no
GatewayPorts no
AllowTcpForwarding local
PermitOpen 127.0.0.1:47990
ClientAliveInterval 30
ClientAliveCountMax 4
EOF

  # Firewall (on top of SteamOS's own firewalld)
  local fw_changed=0
  put "$NFT_FILE" 644 <<EOF && fw_changed=1
# Steam Machine Remote Access: SSH and Sunshine only from the allowed PCs.
table inet steam_remote {
  # Counts stream traffic from your PC(s); the idle timer uses it to tell if anyone is streaming.
  counter stream_in { }
  chain input {
    type filter hook input priority -10; policy accept;
    iifname "lo" accept
    tcp dport 47990 counter drop
    tcp dport { 22, 47984, 47989, 48010 } ip saddr != { $set_ips } counter drop
    udp dport { 47998-48000, 48002, 48010 } ip saddr != { $set_ips } counter drop
    meta nfproto ipv6 tcp dport { 22, 47984, 47989, 48010 } counter drop
    meta nfproto ipv6 udp dport { 47998-48000, 48002, 48010 } counter drop
    udp dport 47998-48000 counter name "stream_in"
  }
  chain output {
    type filter hook output priority -10; policy accept;
    oifname "lo" accept
    tcp dport 22 ip daddr != { $set_ips } counter reject
    meta nfproto ipv6 tcp dport 22 counter reject
  }
}
EOF
  put "$UNITS_DIR/steam-remote-guard.service" 644 <<'EOF' && fw_changed=1
[Unit]
Description=Steam Machine Remote Access firewall (SSH and Sunshine from allowed PCs only)
Before=sshd.service steam-remote-sunshine.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/usr/bin/nft delete table inet steam_remote
ExecStart=/usr/bin/nft -f /etc/steam-remote-guard.nft
ExecStop=/usr/bin/nft delete table inet steam_remote

[Install]
WantedBy=multi-user.target
EOF

  # Sunshine
  put "$UNITS_DIR/$SUN_UNIT" 644 <<EOF || true
[Unit]
Description=Sunshine for Steam Machine Remote Access (root, KMS capture, on demand)
After=network-online.target steam-remote-guard.service
Wants=network-online.target
Requires=steam-remote-guard.service

[Service]
RuntimeDirectory=sunshine
Environment=HOME=/root
Environment=XDG_RUNTIME_DIR=/run/sunshine
Environment=PULSE_SERVER=unix:/run/user/$user_uid/pulse/native
Environment=FLATPAK_BWRAP=/var/lib/sunshine-bwrap/bwrap
ExecStartPre=/usr/bin/install -d -o root -g root -m 0700 /var/lib/sunshine-bwrap
ExecStartPre=/usr/bin/install -o root -g root -m 4755 /usr/bin/bwrap /var/lib/sunshine-bwrap/bwrap.new
ExecStartPre=/usr/bin/mv -f /var/lib/sunshine-bwrap/bwrap.new /var/lib/sunshine-bwrap/bwrap
ExecStartPre=-/usr/bin/setfacl -P -m u:root:x /run/user/$user_uid /run/user/$user_uid/pulse
ExecStart=/usr/bin/flatpak run --system --socket=wayland --env=QT_QPA_PLATFORM=offscreen $SUN_APP
ExecStop=/usr/bin/flatpak kill $SUN_APP
ExecStopPost=-$SELF_REAL --backup-sunshine
ExecStopPost=-/bin/sh -c '[ "\$\$SERVICE_RESULT" = success ] && exec /usr/bin/runuser -u $USER_NAME -- $SELF_REAL --stream-end'
Restart=on-failure
RestartSec=5
EOF
  restore_sunshine
  if [ ! -e "$SUN_CONF" ]; then
    put "$SUN_CONF" 600 <<EOF || true
sunshine_name = $SUNSHINE_NAME
capture = kms
address_family = ipv4
lan_encryption_mode = 2
wan_encryption_mode = 2
upnp = disabled
origin_web_ui_allowed = pc
EOF
  fi
  if [ -e "$SUN_CONF" ]; then
    # The encoder preset applies to whichever GPU encoder Sunshine picks (VA-API or Vulkan).
    # Sunshine versions before 2026.906 ignore these two lines.
    local kv k quality=()
    [ "$ENCODER_QUALITY" = auto ] || quality=("vaapi_quality = $ENCODER_QUALITY" "vk_quality = $ENCODER_QUALITY")
    for kv in "sunshine_name = $SUNSHINE_NAME" "capture = kms" "address_family = ipv4" "lan_encryption_mode = 2" \
              "wan_encryption_mode = 2" "upnp = disabled" "origin_web_ui_allowed = pc" ${quality[@]+"${quality[@]}"}; do
      k=${kv%% =*}
      grep -qxF "$kv" "$SUN_CONF" && continue
      sed -i "/^$k *=/d" "$SUN_CONF" && echo "$kv" >>"$SUN_CONF" && CHANGED+=("Sunshine: $kv")
    done
    if [ "$ENCODER_QUALITY" = auto ] && grep -qE '^(vaapi|vk)_quality *=' "$SUN_CONF"; then
      sed -i -E '/^(vaapi|vk)_quality *=/d' "$SUN_CONF" && CHANGED+=("Sunshine: encoder preset back to the driver's default")
    fi
  fi
  [ -e "$SUN_STATE" ] || log "note: Sunshine has no web UI login or pairing yet (run steam-pair from your PC)."

  # Sudo rule: start/stop/restart Sunshine, and switch the two chosen outputs. Nothing else.
  [ -n "$STREAM_OUTPUT" ] && [ -n "$TV_OUTPUT" ] && \
    sudo_tee=", /usr/bin/tee /sys/class/drm/$STREAM_OUTPUT/status, /usr/bin/tee /sys/class/drm/$TV_OUTPUT/status"
  local tmp_sudo; tmp_sudo=$(mktemp)
  echo "$USER_NAME ALL=(root) NOPASSWD: /usr/bin/systemctl start $SUN_UNIT, /usr/bin/systemctl stop $SUN_UNIT, /usr/bin/systemctl restart $SUN_UNIT$sudo_tee" >"$tmp_sudo"
  if [ -n "$R" ] || visudo -cqf "$tmp_sudo" >/dev/null 2>&1; then
    put "$SUDOERS" 440 <"$tmp_sudo" || true
  else
    log "ERROR: the sudo rule failed validation; left $SUDOERS as it was"
  fi
  rm -f "$tmp_sudo"

  # Boot on the TV; idle timer; self-heal at boot
  put "$UNITS_DIR/steam-remote-display.service" 644 <<EOF || true
[Unit]
Description=Steam Machine Remote Access: start on the TV, not the stream output
RequiresMountsFor=$KIT_REAL
Before=display-manager.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SELF_REAL --boot-display

[Install]
WantedBy=multi-user.target
EOF
  put "$UNITS_DIR/steam-remote-idle.service" 644 <<EOF || true
[Unit]
Description=Steam Machine Remote Access: stop Sunshine when nobody is streaming
RequiresMountsFor=$KIT_REAL

[Service]
Type=oneshot
ExecStart=$SELF_REAL --idle-check
EOF
  put "$UNITS_DIR/steam-remote-idle.timer" 644 <<'EOF' || true
[Unit]
Description=Steam Machine Remote Access: check every 5 minutes whether Sunshine is idle

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
  put "$UNITS_DIR/steam-remote-heal.service" 644 <<EOF || true
[Unit]
Description=Steam Machine Remote Access: restore the setup if a SteamOS update removed it
RequiresMountsFor=$KIT_REAL
After=local-fs.target NetworkManager.service
Before=sshd.service steam-remote-guard.service display-manager.service

[Service]
Type=oneshot
ExecStart=$SELF_REAL --apply

[Install]
WantedBy=multi-user.target
EOF

  # Wake-on-LAN (stored by NetworkManager under /etc, so an update can reset it)
  [ "$WAKE_ON_LAN" = yes ] && set_wol

  # Apply. --no-block: at boot this runs before sshd/the firewall, so waiting would deadlock.
  [ "$UNITS_CHANGED" = 1 ] && sc daemon-reload
  local u
  for u in "${UNITS[@]}"; do
    [ "$u" = steam-remote-idle.timer ] && [ "$IDLE_MINUTES" = 0 ] && continue
    sc is-enabled --quiet "$u" 2>/dev/null || { sc enable "$u" >/dev/null 2>&1 && log "enabled $u"; }
  done
  if [ "$IDLE_MINUTES" = 0 ]; then sc disable --now steam-remote-idle.timer >/dev/null 2>&1
  else sc is-active --quiet steam-remote-idle.timer || sc --no-block start steam-remote-idle.timer; fi
  sc is-enabled --quiet sshd.service 2>/dev/null || sc enable sshd.service >/dev/null 2>&1

  if [ "$fw_changed" = 1 ] || ! sc is-active --quiet steam-remote-guard.service; then
    sc reset-failed steam-remote-guard.service >/dev/null 2>&1
    sc --no-block restart steam-remote-guard.service
  fi
  if [ "$ssh_changed" = 1 ]; then
    if [ -n "$R" ] || sshd -t 2>/dev/null; then
      sc --no-block restart sshd.service   # open sessions stay connected
    else
      log "ERROR: sshd rejected the config; moved $SSHD_DROPIN aside so SSH still starts"
      mv -f "$SSHD_DROPIN" "$SSHD_DROPIN.broken"
    fi
  fi
  sc is-active --quiet "$SUN_UNIT" || backup_sunshine

  if [ ${#CHANGED[@]} -eq 0 ]; then log "everything in place, nothing changed"
  else log "updated ${#CHANGED[@]} item(s)"; fi
}

set_wol() {
  if [ -n "$R" ]; then log "(test) skipping Wake-on-LAN"; return; fi
  command -v nmcli >/dev/null 2>&1 || { log "WARNING: nmcli not found; Wake-on-LAN not set"; return; }
  local name type wired=0 dev w
  while IFS=: read -r name type; do
    [ "$type" = "802-3-ethernet" ] || continue
    wired=1
    if [ "$(nmcli -g 802-3-ethernet.wake-on-lan connection show "$name" 2>/dev/null)" != "magic" ]; then
      nmcli connection modify "$name" 802-3-ethernet.wake-on-lan magic \
        && { CHANGED+=("Wake-on-LAN on '$name'"); log "set Wake-on-LAN (magic packet only) on '$name'"; }
    fi
  done < <(nmcli -t -f NAME,TYPE connection show 2>/dev/null)
  [ "$wired" = 1 ] || log "note: no wired connection, so no Wake-on-LAN (it needs Ethernet)"
  # Apply to the card now too: NetworkManager only applies it when the link next comes up.
  # SteamOS has no ethtool, so this makes the same kernel call (SIOCETHTOOL) directly.
  for dev in /sys/class/net/*; do
    if [ ! -e "$dev/device" ] || [ -d "$dev/wireless" ] || [ "$(cat "$dev/type" 2>/dev/null)" != 1 ]; then continue; fi
    python3 -I - "${dev##*/}" <<'PY' || true
import array, fcntl, socket, struct, sys
SIOCETHTOOL, GWOL, SWOL, MAGIC = 0x8946, 0x5, 0x6, 1 << 5
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
def call(cmd, opts=0):
    buf = array.array("B", struct.pack("III6s2x", cmd, 0, opts, b"\0" * 6))
    fcntl.ioctl(s.fileno(), SIOCETHTOOL, struct.pack("16sP", sys.argv[1].encode(), buf.buffer_info()[0]))
    return struct.unpack("III", buf[:12].tobytes())
try:
    _, supported, current = call(GWOL)
    if supported & MAGIC and not current & MAGIC:
        call(SWOL, MAGIC)
except OSError:
    sys.exit(1)
PY
  done
  for w in /sys/class/net/*/device/power/wakeup; do
    [ "$(cat "$w" 2>/dev/null)" = enabled ] || echo enabled >"$w" 2>/dev/null || true
  done
}

wol_state() {   # prints "magic" if a wired card has magic-packet wake on, "off" if not, "" if unknown
  python3 -I - 2>/dev/null <<'PY'
import array, fcntl, glob, os, socket, struct
SIOCETHTOOL, GWOL, MAGIC = 0x8946, 0x5, 1 << 5
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
found = None
for dev in glob.glob("/sys/class/net/*"):
    if not os.path.exists(dev + "/device") or os.path.isdir(dev + "/wireless"):
        continue
    try:
        buf = array.array("B", struct.pack("III6s2x", GWOL, 0, 0, b"\0" * 6))
        fcntl.ioctl(s.fileno(), SIOCETHTOOL, struct.pack("16sP", os.path.basename(dev).encode(), buf.buffer_info()[0]))
        _, sup, cur = struct.unpack("III", buf[:12].tobytes())
        found = "magic" if cur & MAGIC else (found or "off")
    except OSError:
        pass
print(found or "")
PY
}

# ------------------------------------------------------------------ stream (no root)
# Game Mode (gamescope) is controlled through properties on its X root window.
gs_prop() {   # NAME: print the numeric value of a gamescope root property, or nothing
  DISPLAY=:0 timeout 5 xprop -root "$1" 2>/dev/null | sed -n 's/^[^=]*= *\([0-9][0-9]*\).*/\1/p' | head -n 1
}
in_game_mode() {   # gamescope sets this property as soon as it starts
  [ -n "$(gs_prop GAMESCOPE_HDR_OUTPUT_FEEDBACK)" ] || pgrep -x 'gamescope|gamescope-wl' >/dev/null 2>&1
}

# Game Mode settings changed for a stream are put back afterwards. The value from before is
# saved per setting, tied to this boot: after a reboot (gamescope starts afresh) an old one
# means nothing and must not be "restored". Saved in the runtime folder if there is one
# (cleared on reboot), otherwise the home folder's cache.
gs_state_file() {   # NAME
  local dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  if [ ! -d "$dir" ] || [ ! -w "$dir" ]; then dir="$HOME/.cache"; mkdir -p "$dir" 2>/dev/null; fi
  echo "$dir/steam-remote-$1"
}
gs_set() {   # PROPERTY VALUE
  DISPLAY=:0 timeout 5 xprop -root -f "$1" 32c -set "$1" "$2"
}
gs_change() {   # PROPERTY VALUE NAME: remember the value from before (once per stream), then set it
  local state cur prev saved_boot boot
  state=$(gs_state_file "$3")
  boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
  read -r prev saved_boot 2>/dev/null <"$state" || { prev=""; saved_boot=""; }
  [ "$saved_boot" = "$boot" ] || rm -f "$state"
  cur=$(gs_prop "$1")
  [ -e "$state" ] || { echo "${cur:-0} $boot" >"$state"; } 2>/dev/null
  [ "${cur:-0}" = "$2" ] || gs_set "$1" "$2"
}
gs_restore() {   # PROPERTY NAME: put back what gs_change found, if it ran this boot
  local state cur prev saved_boot boot
  state=$(gs_state_file "$2")
  boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
  read -r prev saved_boot 2>/dev/null <"$state" || return 0
  rm -f "$state"
  [ "$saved_boot" = "$boot" ] && [ -n "$prev" ] || return 0
  cur=$(gs_prop "$1")
  [ "${cur:-0}" = "$prev" ] || gs_set "$1" "$prev"
}

# Game Mode normally shows the game and Steam's menus on separate hardware layers and
# lets the display hardware do part of the colour work. Sunshine captures only one
# layer, so the stream can miss menus, go black, or get HDR colours wrong. Forcing
# composition draws everything, colour-corrected, onto one layer first. It costs a
# little GPU time, so it's only on while streaming. "off" puts back what was there
# before (on, if you'd turned on Steam's own Force Composite developer option). The
# property is harmless in Desktop Mode, so "on" sets it whatever the mode. "off" only
# acts if "on" ran, so it never turns off a Force Composite you set yourself.
composite() {
  [[ "${1:-}" =~ ^(on|off)$ ]] || die "Usage: $0 --composite on|off"
  command -v xprop >/dev/null 2>&1 || { warn "xprop is missing"; return 1; }
  if [ "$1" = on ]; then gs_change GAMESCOPE_COMPOSITE_FORCE 1 composite
  else gs_restore GAMESCOPE_COMPOSITE_FORCE composite; fi
}

# Game Mode's HDR, matched to what this PC's Moonlight asks for, for the length of the
# stream. Steam's own Enable HDR setting comes back when Sunshine stops. It only has an
# effect if the stream output (the dummy plug) accepts HDR10.
game_hdr() {
  [[ "${1:-}" =~ ^(on|off)$ ]] || die "Usage: $0 --hdr on|off"
  command -v xprop >/dev/null 2>&1 || { warn "xprop is missing"; return 1; }
  in_game_mode || return 0   # Desktop Mode has its own HDR switch, in KDE's settings
  local before; before=$(gs_prop GAMESCOPE_HDR_OUTPUT_FEEDBACK)
  gs_change GAMESCOPE_DISPLAY_HDR_ENABLED "$([ "$1" = on ] && echo 1 || echo 0)" hdr || return 1
  # Give Game Mode a moment to switch the output, so the stream check that follows is current.
  local want=0 tries=6
  [ "$1" = on ] && want=1
  [ "${before:-0}" = "$want" ] && return 0
  while [ "$tries" -gt 0 ] && [ "$(gs_prop GAMESCOPE_HDR_OUTPUT_FEEDBACK)" = "$before" ]; do
    sleep 0.5; tries=$((tries - 1))
  done
  return 0
}

# Everything a stream changed in Game Mode, put back (run when Sunshine stops).
stream_end() {
  command -v xprop >/dev/null 2>&1 || return 0
  gs_restore GAMESCOPE_DISPLAY_HDR_ENABLED hdr
  gs_restore GAMESCOPE_COMPOSITE_FORCE composite
}

# What the display behind the stream offers, from its EDID: the biggest mode and
# whether it accepts HDR10. Prints: "WIDTH HEIGHT HZ HDR" where HDR is 1 (HDR10: what Game
# Mode needs, PQ and BT.2020 RGB), 2 (PQ, but not BT.2020 RGB, so Game Mode won't use it)
# or 0 (no HDR).
edid_caps() {
  [ -s "$1" ] || return 1
  python3 -I - "$1" 2>/dev/null <<'PY'
import sys
e = open(sys.argv[1], "rb").read()
if len(e) < 128 or e[:8] != b"\x00\xff\xff\xff\xff\xff\xff\x00":
    sys.exit(1)
# Common CTA-861 video codes: VIC -> (width, height, Hz).
VIC = {4: (1280, 720, 60), 16: (1920, 1080, 60), 31: (1920, 1080, 50), 32: (1920, 1080, 24),
       33: (1920, 1080, 25), 34: (1920, 1080, 30), 47: (1280, 720, 120), 63: (1920, 1080, 120),
       64: (1920, 1080, 100), 93: (3840, 2160, 24), 94: (3840, 2160, 25), 95: (3840, 2160, 30),
       96: (3840, 2160, 50), 97: (3840, 2160, 60), 98: (4096, 2160, 24), 99: (4096, 2160, 25),
       100: (4096, 2160, 30), 101: (4096, 2160, 50), 102: (4096, 2160, 60), 114: (3840, 2160, 48),
       117: (3840, 2160, 100), 118: (3840, 2160, 120), 218: (4096, 2160, 100), 219: (4096, 2160, 120)}
VIC.update({v: (7680, 4320, hz) for v, hz in zip(range(194, 202), (24, 25, 30, 48, 50, 60, 100, 120))})
HDMI_VIC = {1: (3840, 2160, 30), 2: (3840, 2160, 25), 3: (3840, 2160, 24), 4: (4096, 2160, 24)}
modes, pq, bt2020 = set(), 0, 0

def dtd(d):
    if len(d) < 18:
        return
    clock = int.from_bytes(d[0:2], "little") * 10000
    if not clock or d[17] & 0x80:            # empty, or interlaced
        return
    ha, hb = d[2] | (d[4] & 0xF0) << 4, d[3] | (d[4] & 0x0F) << 8
    va, vb = d[5] | (d[7] & 0xF0) << 4, d[6] | (d[7] & 0x0F) << 8
    if ha and va:
        modes.add((ha, va, round(clock / ((ha + hb) * (va + vb)))))

def displayid(d, khz):                     # DisplayID type I (10 kHz) / VII (1 kHz) timing
    if len(d) < 20:
        return
    clock = (int.from_bytes(d[0:3], "little") + 1) * khz * 1000
    ha, hb = int.from_bytes(d[4:6], "little") + 1, int.from_bytes(d[6:8], "little") + 1
    va, vb = int.from_bytes(d[12:14], "little") + 1, int.from_bytes(d[14:16], "little") + 1
    if not d[3] & 0x10:                    # progressive only
        modes.add((ha, va, round(clock / ((ha + hb) * (va + vb)))))

def vics(data):
    for v in data:
        v = v & 0x7F if 129 <= v <= 192 else v   # 129-192: "native" flag on VICs 1-64
        if v in VIC:
            modes.add(VIC[v])

for off in (54, 72, 90, 108):
    dtd(e[off:off + 18])
for i in range(1, e[126] + 1):
    b = e[128 * i:128 * (i + 1)]
    if len(b) == 128 and b[0] == 0x70:        # DisplayID extension
        p, end = 5, min(5 + b[2], 127)
        while p + 3 <= end:
            tag, ln = b[p], b[p + 2]
            if tag in (0x03, 0x22):
                for q in range(p + 3, p + 3 + ln - 19, 20):
                    displayid(b[q:q + 20], 10 if tag == 0x03 else 1)
            p += 3 + ln
        continue
    if len(b) < 128 or b[0] != 0x02:          # otherwise CTA-861 extension blocks only
        continue
    end, p = b[2], 4
    while p < min(end, 127):
        tag, ln = b[p] >> 5, b[p] & 0x1F
        body = b[p + 1:p + 1 + ln]
        if tag == 2:
            vics(body)
        elif tag == 3 and body[:3] == b"\x03\x0c\x00" and len(body) > 7 and body[7] & 0x20:
            q = 8 + (2 if body[7] & 0x80 else 0) + (2 if body[7] & 0x40 else 0)
            if q + 1 < len(body):                # HDMI 1.4 VICs (4K at 24-30 Hz)
                for v in body[q + 2:q + 2 + (body[q + 1] >> 5)]:
                    modes.update([HDMI_VIC[v]] if v in HDMI_VIC else [])
        elif tag == 7 and body:
            if body[0] == 6 and len(body) > 1 and body[1] & 0x04:   # HDR static metadata: PQ
                pq = 1
            elif body[0] == 5 and len(body) > 1 and body[1] & 0x80:   # colorimetry: BT.2020 RGB
                bt2020 = 1
            elif body[0] == 14:                  # 4:2:0-only video codes
                vics(body[1:])
        p += 1 + ln
    q = end
    while 4 <= q <= 109 and (b[q] or b[q + 1]):
        dtd(b[q:q + 18]); q += 18
if any(m[:2] == (3840, 2160) for m in modes):   # report 4K UHD, not cinema 4K
    modes = {m for m in modes if m[:2] != (4096, 2160)}
if not modes:
    sys.exit(1)
w, h, hz = max(modes, key=lambda m: (m[0] * m[1], m[2]))
print(w, h, max(m[2] for m in modes if m[:2] == (w, h)), (1 if bt2020 else 2) if pq else 0)
PY
}

stream_output() {   # the output being streamed: the configured one, else the active one
  local d
  if [ -n "$STREAM_OUTPUT" ] && [ -e "$DRM/$STREAM_OUTPUT/status" ]; then echo "$STREAM_OUTPUT"; return; fi
  for d in "$DRM"/card*-*; do
    [ "$(cat "$d/enabled" 2>/dev/null)" = enabled ] && { echo "${d##*/}"; return; }
  done
}

stream_info() {
  local want=${1:-}
  load_config || true
  local out w h hz hdr10="" hdr10_txt gm="" hdr_on="" hdr_out="" fix="" log enc
  out=$(stream_output)
  if [ -z "$out" ]; then
    echo "Stream output: none active. Is the dummy plug (or TV) connected?"
  else
    if read -r w h hz hdr10 < <(edid_caps "$DRM/$out/edid"); then
      case "$hdr10" in
        1) hdr10_txt=HDR10 ;; 2) hdr10_txt="HDR, but not the BT.2020 colours Game Mode needs" ;; *) hdr10_txt="no HDR" ;;
      esac
      echo "Stream output ${out#card*-}: up to ${w}x${h} at ${hz} Hz, $hdr10_txt"
    else
      hdr10=""
      echo "Stream output ${out#card*-}: $(cat "$DRM/$out/status" 2>/dev/null) (couldn't read what it supports)"
    fi
  fi
  if command -v xprop >/dev/null 2>&1 && in_game_mode; then
    gm=1
    hdr_on=$(gs_prop GAMESCOPE_DISPLAY_HDR_ENABLED)
    hdr_out=$(gs_prop GAMESCOPE_HDR_OUTPUT_FEEDBACK)
    fix=$(gs_prop GAMESCOPE_COMPOSITE_FORCE)
    echo "Game Mode: HDR $([ "$hdr_on" = 1 ] && echo on || echo off), capture fix $([ "$fix" = 1 ] && echo on || echo off)"
  elif ! command -v xprop >/dev/null 2>&1; then
    echo "Game Mode: unknown (xprop is missing)"
  else
    echo "Desktop Mode: HDR follows the desktop's setting (System Settings > Display & Monitor)"
  fi
  # shellcheck disable=SC2046  # the invocation ID is one word
  log=$(journalctl -u "$SUN_UNIT" _SYSTEMD_INVOCATION_ID=$(systemctl show -p InvocationID --value "$SUN_UNIT" 2>/dev/null) --no-pager -o cat 2>/dev/null)
  enc=$(sed -n 's/.*Found HEVC encoder: [^[]*\[\([a-z]*\)\].*/\1/p' <<<"$log" | tail -n 1)
  [ -n "$enc" ] || enc=$(sed -n 's/.*Found H.264 encoder: [^[]*\[\([a-z]*\)\].*/\1/p' <<<"$log" | tail -n 1)
  case "$enc" in
    "") ;;
    software) echo "Encoder: software (the graphics card's encoder failed, so expect a soft, laggy picture; see its log)" ;;
    *) echo "Encoder: $enc, preset $ENCODER_QUALITY$(grep -q 'Found AV1 encoder' <<<"$log" && echo ', AV1 available')" ;;
  esac
  if [ -n "$gm" ]; then
    if [ "$hdr10" = 0 ] || [ "$hdr10" = 2 ]; then
      echo "HDR: not possible: the stream output doesn't offer HDR10. An HDR dummy plug is needed (docs/quality.md)"
    elif [ "$want" = sdr ]; then
      echo "HDR: off for this stream (Moonlight's Enable HDR is off, or STREAM_HDR is no)"
    elif [ "$hdr_out" = 1 ] && [ "$want" = hdr ]; then
      echo "HDR: on, and Moonlight asks for it"
    elif [ "$hdr_out" = 1 ]; then
      echo "HDR: ready. Turn on Enable HDR in Moonlight to use it"
    elif [ "$hdr_on" = 1 ]; then
      echo "HDR: on in Steam, but Game Mode doesn't see HDR on this output (docs/quality.md)"
    elif [ "$want" = hdr ]; then
      echo "HDR: Moonlight asks for it, but Game Mode's HDR is off. Check MATCH_HDR is yes, or turn on Steam > Settings > Display > Enable HDR"
    else
      echo "HDR: off. Turn on Enable HDR in Moonlight (or Steam > Settings > Display > Enable HDR)"
    fi
  fi
}

# Wait for Moonlight to start a stream, then say whether it's SDR or HDR. Sunshine logs
# "Color coding" and "Color depth" when a stream starts. 10-bit SDR means Moonlight asked
# for HDR but the Steam Machine's output isn't in HDR; 8-bit means Moonlight didn't ask.
stream_watch() {
  local secs=${1:-300} want=${2:-} line coding="" depth="" pid
  [[ "$secs" =~ ^[0-9]+$ ]] || secs=300
  exec 3< <(timeout "$secs" journalctl -u "$SUN_UNIT" -f -n 0 -o cat 2>/dev/null)
  pid=$!
  while IFS= read -r line <&3; do
    case "$line" in
      *"Color coding: "*) coding=${line#*Color coding: } ;;
      *"Color depth: "*)  depth=${line#*Color depth: }; break ;;
    esac
  done
  kill "$pid" 2>/dev/null; exec 3<&-
  [ -n "$depth" ] || return 0
  coding=$(printf '%s' "$coding" | tr -cd '[:print:]'); depth=$(printf '%s' "$depth" | tr -cd '[:print:]')
  case "$coding" in
    HDR*) echo "Moonlight connected: streaming in HDR ($depth)" ;;
    *) if [ "$depth" = 10-bit ]; then
         echo "Moonlight connected: streaming in SDR. Moonlight asked for HDR, but the Steam Machine's output isn't in HDR (see the stream check above, or docs/quality.md)"
       elif [ "$want" != sdr ] && command -v xprop >/dev/null 2>&1 && [ "$(gs_prop GAMESCOPE_HDR_OUTPUT_FEEDBACK)" = 1 ]; then
         echo "Moonlight connected: streaming in SDR ($depth). For HDR, turn on Enable HDR in Moonlight's settings"
       else
         echo "Moonlight connected: streaming in SDR ($depth)"
       fi ;;
  esac
}

# ------------------------------------------------------------------ check (no root)
check() {
  local bad=0 f u
  if ! load_config; then echo "MISSING $CONFIG (run the first-time setup)"; exit 1; fi
  validate_config 2>&1 | sed 's/^/CONFIG /' | grep . && bad=1
  for f in "$SSHD_DROPIN" "$NFT_FILE" "$SSHD_UNIT_DROPIN" "$KEEP_LIST"; do
    [ -e "$f" ] || { echo "MISSING $f"; bad=1; }
  done
  # /etc/sudoers.d is root-only on some systems, so without root ask sudo instead
  # (listing your own NOPASSWD rules doesn't need a password).
  if [ -r "$(dirname "$SUDOERS")" ]; then
    [ -e "$SUDOERS" ] || { echo "MISSING $SUDOERS"; bad=1; }
  else
    sudo -n -l 2>/dev/null | grep -qF "$SUN_UNIT" || { echo "MISSING $SUDOERS (the sudo rule)"; bad=1; }
  fi
  for f in "${ALL_UNIT_FILES[@]}"; do
    [ -e "$UNITS_DIR/$f" ] || { echo "MISSING $UNITS_DIR/$f"; bad=1; }
  done
  grep -q '^Include /etc/ssh/sshd_config.d/\*.conf' "$SSHD_MAIN" 2>/dev/null || { echo "MISSING the Include line in $SSHD_MAIN"; bad=1; }
  if [ -z "$R" ]; then
    for u in "${UNITS[@]}"; do
      [ "$u" = steam-remote-idle.timer ] && [ "$IDLE_MINUTES" = 0 ] && continue
      systemctl is-enabled --quiet "$u" 2>/dev/null || { echo "NOT ENABLED $u"; bad=1; }
    done
    systemctl is-active --quiet steam-remote-guard.service || { echo "NOT RUNNING steam-remote-guard.service (the firewall)"; bad=1; }
    if [ "$WAKE_ON_LAN" = yes ] && command -v nmcli >/dev/null 2>&1; then
      local name type
      while IFS=: read -r name type; do
        [ "$type" = "802-3-ethernet" ] || continue
        [ "$(nmcli -g 802-3-ethernet.wake-on-lan connection show "$name" 2>/dev/null)" = "magic" ] \
          || { echo "WAKE-ON-LAN OFF on connection '$name'"; bad=1; }
      done < <(nmcli -t -f NAME,TYPE connection show 2>/dev/null)
    fi
  fi
  for u in "$STREAM_OUTPUT" "$TV_OUTPUT"; do
    [ -z "$u" ] || [ -e "$DRM/$u/status" ] || echo "NOTE output $u doesn't exist now (renamed after an update or a new GPU driver? run --displays)"
  done
  [ "$bad" = 0 ] && echo "All present."
  exit "$bad"
}

# ------------------------------------------------------------------ idle check (timer)
idle_check() {
  load_config || exit 0
  [ "$IDLE_MINUTES" != 0 ] || exit 0
  local state=/run/steam-remote-idle packets now started last_packets last_change
  if ! sc is-active --quiet "$SUN_UNIT"; then rm -f "$state"; exit 0; fi
  # While a stream runs, Moonlight keeps sending packets to Sunshine's UDP ports; the
  # firewall counts them. No new packets for IDLE_MINUTES means nobody is streaming.
  packets=$(nft list counter inet steam_remote stream_in 2>/dev/null | sed -n 's/.*packets \([0-9]*\).*/\1/p' | head -n 1)
  [[ "$packets" =~ ^[0-9]+$ ]] || exit 0   # firewall not loaded: do nothing rather than guess
  now=$(date +%s)
  started=$(date -d "$(systemctl show -p ActiveEnterTimestamp --value "$SUN_UNIT")" +%s 2>/dev/null) || started=$now
  read -r last_packets last_change 2>/dev/null <"$state" || { last_packets=""; last_change=$now; }
  [[ "$last_change" =~ ^[0-9]+$ ]] || last_change=$now
  [ "$last_change" -ge "$started" ] || last_change=$started   # Sunshine restarted since
  if [ "$packets" != "$last_packets" ]; then
    echo "$packets $now" >"$state"
    exit 0
  fi
  if [ $(( now - last_change )) -ge $(( IDLE_MINUTES * 60 )) ]; then
    log "nobody has streamed for $IDLE_MINUTES minutes; stopping Sunshine"
    sc stop "$SUN_UNIT"
    show_tv
    rm -f "$state"
  fi
  exit 0
}

# ------------------------------------------------------------------ setup (interactive)
setup() {
  need_root
  local client_ip="" pubkey="" radd="" rdel=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --client-ip) client_ip=${2:-}; shift 2 ;;
      --pubkey)    pubkey=${2:-}; shift 2 ;;
      --remote-add)    radd+=" ${2:-}"; shift 2 ;;
      --remote-remove) rdel+=" ${2:-}"; shift 2 ;;
      *) die "Unknown option for --setup: $1" ;;
    esac
  done
  [ -t 0 ] || exec </dev/tty
  local first=0
  load_config || first=1
  [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] && valid_user "$SUDO_USER" && USER_NAME=$SUDO_USER

  say "Steam Machine Remote Access server setup (version $VERSION)"
  if [ -z "$R" ]; then
    local c missing=""
    for c in sshd nft flatpak bwrap setfacl python3 visudo runuser systemctl journalctl getent ss; do
      command -v "$c" >/dev/null 2>&1 || missing+=" $c"
    done
    [ -z "$missing" ] || die "This system is missing:$missing. It should be SteamOS 3 or later; other systems aren't supported."
    command -v nmcli >/dev/null 2>&1 || warn "nmcli (NetworkManager) is missing, so Wake-on-LAN can't be set up."
    command -v xprop >/dev/null 2>&1 || warn "xprop is missing, so the Game Mode capture fix and the HDR report won't work."
  fi
  echo "This makes SSH and Sunshine reachable from your PC(s) only, needing your key AND"
  echo "the $USER_NAME password, and installs the self-heal service. It's safe to run again."
  echo

  # Allowed PCs
  if [ -n "$client_ip" ]; then
    valid_ip "$client_ip" || die "--client-ip '$client_ip' isn't an IPv4 address"
    case " $ALLOWED_IPS " in *" $client_ip "*) ;; *) ALLOWED_IPS=$(echo "$ALLOWED_IPS $client_ip" | xargs) ;; esac
  fi
  if [ -z "$ALLOWED_IPS" ]; then
    local ip; ip=$(ask "This PC's address on your HOME network (its fixed IP from your router, e.g. 192.168.0.20): ")
    valid_ip "$ip" || die "'$ip' isn't an IPv4 address"
    ALLOWED_IPS=$ip
  fi
  say "Allowed PCs: $ALLOWED_IPS"
  echo "   Your router must always give these PCs the same address (a DHCP reservation)."
  edit_remote "$radd" "$rdel" || exit 1
  if [ -n "$REMOTE_IPS" ]; then say "Remote access (VPN addresses): $REMOTE_IPS"
  else say "Remote access: off (home network only)"; fi

  # Key
  if [ -n "$pubkey" ]; then add_pubkey "$pubkey"; fi
  local home; home=$(getent passwd "$USER_NAME" | cut -d: -f6)
  if [ -z "$R" ] && ! grep -qE '^(ssh-|ecdsa-|sk-)' "$home/.ssh/authorized_keys" 2>/dev/null; then
    die "No SSH key is authorised for $USER_NAME yet. Run the setup from your PC (it sends your key), or pass --pubkey FILE."
  fi

  # Displays
  if [ -z "$STREAM_OUTPUT$TV_OUTPUT" ] || [ "$(ask "Displays: stream=${STREAM_OUTPUT:-none}, TV=${TV_OUTPUT:-none}. Change them? [y/N] ")" = y ]; then
    choose_outputs
  fi

  # Other options
  local wol_text="on"; [ "$WAKE_ON_LAN" = yes ] || wol_text="off"
  if [ "$first" = 1 ] || [ "$(ask "Options: idle stop after ${IDLE_MINUTES} min, Wake-on-LAN ${wol_text}, name '${SUNSHINE_NAME}', encoder preset ${ENCODER_QUALITY}, login ${AUTH_MODE}. Change them? [y/N] ")" = y ]; then
    choose_options
  fi

  # Sunshine
  if [ -z "$R" ] && ! flatpak info --system "$SUN_APP" >/dev/null 2>&1; then
    say "Installing Sunshine (Flatpak, system-wide). This can take a few minutes."
    flatpak remote-add --if-not-exists --system flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    flatpak install --system -y --noninteractive flathub "$SUN_APP" || die "Sunshine didn't install. Check the internet connection and run the setup again."
  fi

  install_self
  write_config
  say "Applying"
  apply

  # Sanity checks
  if [ -z "$R" ]; then
    echo
    say "Checking"
    sshd -T 2>/dev/null | grep -E '^(permitrootlogin|allowusers|authenticationmethods) ' | sed 's/^/   /'
    if systemctl is-active --quiet steam-remote-guard.service; then echo "   firewall: active"
    else warn "the firewall isn't running: systemctl status steam-remote-guard.service"; fi
    say "Test-starting Sunshine (about 15 seconds)"
    [ -n "$STREAM_OUTPUT" ] && [ -n "$TV_OUTPUT" ] && { echo off >"$DRM/$TV_OUTPUT/status"; echo detect >"$DRM/$STREAM_OUTPUT/status"; sleep 2; }
    systemctl start "$SUN_UNIT"
    local out=""
    for _ in $(seq 1 20); do
      out=$(journalctl -u "$SUN_UNIT" _SYSTEMD_INVOCATION_ID="$(systemctl show -p InvocationID --value "$SUN_UNIT")" -o cat --no-pager 2>/dev/null)
      grep -qE 'Screencasting with KMS|Unable to find display|Fatal' <<<"$out" && break
      sleep 1
    done
    systemctl stop "$SUN_UNIT"
    show_tv
    if grep -q 'Screencasting with KMS' <<<"$out"; then echo "   Sunshine: captured the screen OK"
    elif grep -q 'Unable to find display' <<<"$out"; then warn "Sunshine couldn't see a screen. Check the stream output is plugged in and shows 'connected' (--outputs), and see docs/displays.md."
    else warn "Sunshine didn't confirm screen capture. Its log: journalctl -u $SUN_UNIT -b --no-pager | tail -n 30"; fi
  fi
  echo
  say "Done. From now on SSH needs your key$([ "$AUTH_MODE" = key ] || echo " AND the $USER_NAME password"), from $(echo "$ALLOWED_IPS $REMOTE_IPS" | xargs | sed 's/ / or /g') only."
  echo "   Next, on your PC: steam-connect nostream, then steam-pair (see the guide)."
}

# ------------------------------------------------------------------ clients
add_client() {
  need_root
  local ip=${1:-} pubkey=""
  shift || true
  [ "${1:-}" = --pubkey ] && pubkey=${2:-}
  valid_ip "$ip" || die "Usage: sudo $0 --add-client IP [--pubkey FILE]"
  load_config || die "No config yet; run --setup first."
  case " $ALLOWED_IPS " in *" $ip "*) log "$ip is already allowed" ;; *) ALLOWED_IPS=$(echo "$ALLOWED_IPS $ip" | xargs) ;; esac
  [ -n "$pubkey" ] && add_pubkey "$pubkey"
  write_config; apply
  say "Allowed PCs: $ALLOWED_IPS"
}

remove_client() {
  need_root
  local ip=${1:-} new="" x
  valid_ip "$ip" || die "Usage: sudo $0 --remove-client IP"
  load_config || die "No config yet."
  for x in $ALLOWED_IPS; do [ "$x" = "$ip" ] || new+=" $x"; done
  new=$(echo "$new" | xargs)
  [ -n "$new" ] || die "That's the last allowed PC; removing it would lock everyone out. Use --uninstall instead."
  ALLOWED_IPS=$new
  write_config; apply
  say "Allowed PCs: $ALLOWED_IPS (its SSH key is still in ~$USER_NAME/.ssh/authorized_keys; delete that line too)"
}

set_remote_list() {   # LIST or "off": validate and store REMOTE_IPS (doesn't apply)
  local list=$1 x
  [ "$list" = off ] && list=""
  list=$(echo "$list" | xargs)
  for x in $list; do
    valid_remote "$x" || { warn "'$x' can't be used for remote access. Use the address your PC has on the VPN: a private address (10.x, 172.16-31.x, 192.168.x) or a single Tailscale address (100.64-127.x.x). See docs/remote-access.md."; return 1; }
  done
  REMOTE_IPS=$list
}

edit_remote() {   # ADD REMOVE: space-separated addresses to add to / remove from REMOTE_IPS
  local x new=""
  for x in $1; do valid_remote "$x" || { set_remote_list "$x"; return 1; }; done
  for x in $REMOTE_IPS; do case " $2 " in *" $x "*) ;; *) new+=" $x" ;; esac; done
  for x in $1; do case " $new " in *" $x "*) ;; *) new+=" $x" ;; esac; done
  REMOTE_IPS=$(echo "$new" | xargs)
}

remote_cmd() {   # --remote-add ADDRESS and/or --remote-remove ADDRESS, any number of times
  need_root
  local add="" del=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --remote-add)    [ -n "${2:-}" ] || die "Usage: sudo $0 --remote-add VPN_ADDRESS"; add+=" $2"; shift 2 ;;
      --remote-remove) [ -n "${2:-}" ] || die "Usage: sudo $0 --remote-remove VPN_ADDRESS"; del+=" $2"; shift 2 ;;
      *) die "Unknown option '$1'" ;;
    esac
  done
  load_config || die "Run --setup first."
  edit_remote "$add" "$del" || exit 1
  write_config; apply
  if [ -n "$REMOTE_IPS" ]; then say "Remote access on, for: $REMOTE_IPS"
  else say "Remote access off: home network only."; fi
}

set_remote() {
  need_root
  [ $# -ge 1 ] || die "Usage: sudo $0 --set-remote \"VPN_ADDRESSES\" | off"
  load_config || die "Run --setup first."
  set_remote_list "$1" || exit 1
  write_config; apply
  if [ -n "$REMOTE_IPS" ]; then say "Remote access on, for: $REMOTE_IPS"
  else say "Remote access off: home network only."; fi
}

set_encoder() {
  need_root
  [[ "${1:-}" =~ ^(quality|balanced|speed|auto)$ ]] || die "Usage: sudo $0 --set-encoder quality|balanced|speed|auto"
  load_config || die "Run --setup first."
  ENCODER_QUALITY=$1
  write_config; apply
  say "Encoder preset: $ENCODER_QUALITY. It takes effect the next time Sunshine starts."
}

set_auth() {
  need_root
  [[ "${1:-}" =~ ^(key\+password|key)$ ]] || die "Usage: sudo $0 --set-auth key+password|key"
  load_config || die "Run --setup first."
  AUTH_MODE=$1
  write_config; apply
  if [ "$AUTH_MODE" = key ]; then say "SSH logins now need your SSH key only. sudo still needs the password."
  else say "SSH logins now need your SSH key AND the $USER_NAME password."; fi
  echo "   Logins already open stay connected."
}

# ------------------------------------------------------------------ uninstall
uninstall() {
  need_root
  local keep_sun=0 keep_ssh=0 u
  for u in "$@"; do case "$u" in --keep-sunshine) keep_sun=1 ;; --keep-ssh) keep_ssh=1 ;; esac; done
  load_config || true
  sc stop "$SUN_UNIT" >/dev/null 2>&1
  show_tv
  for u in "${ALL_UNIT_FILES[@]}"; do
    sc disable --now "$u" >/dev/null 2>&1
    rm -f "$UNITS_DIR/$u"
  done
  rm -f "$SSHD_UNIT_DROPIN" "$KEEP_LIST"
  rmdir "$(dirname "$SSHD_UNIT_DROPIN")" 2>/dev/null
  sc daemon-reload
  [ -n "$R" ] || nft delete table inet steam_remote 2>/dev/null
  rm -f "$NFT_FILE" "$SUDOERS" "$SSHD_DROPIN" "$SSHD_DROPIN.broken"
  rm -rf "$R/var/lib/sunshine-bwrap"
  if [ "$keep_sun" = 0 ]; then
    [ -n "$R" ] || flatpak uninstall --system -y --noninteractive "$SUN_APP" >/dev/null 2>&1
    rm -rf "$SUN_DATA"
  fi
  rm -rf "$KIT"
  if [ "$keep_ssh" = 0 ]; then
    sc disable --now sshd.service >/dev/null 2>&1
    log "SSH is now off. Open SSH sessions stay connected until they close."
  else
    sc restart sshd.service
    warn "SSH is still on with SteamOS's defaults: any device on your network can try the password."
  fi
  log "uninstalled. Your SSH key is still in ~$USER_NAME/.ssh/authorized_keys; delete it if you like."
}

# ------------------------------------------------------------------ main
case "${1:---apply}" in
  --apply)           apply ;;
  --check)           check ;;
  --outputs)         list_outputs ;;
  --displays)        need_root; load_config || die "Run --setup first."; choose_outputs; write_config; apply; show_tv ;;
  --setup)           shift; setup "$@" ;;
  --add-client)      shift; add_client "$@" ;;
  --remove-client)   shift; remove_client "$@" ;;
  --set-remote)      shift; set_remote "$@" ;;
  --remote-add|--remote-remove) remote_cmd "$@" ;;
  --set-encoder)     shift; set_encoder "$@" ;;
  --set-auth)        shift; set_auth "$@" ;;
  --auth-mode)       load_config >/dev/null 2>&1; echo "$AUTH_MODE" ;;
  --uninstall)       shift; uninstall "$@" ;;
  --boot-display)    need_root; load_config && show_tv ;;
  --idle-check)      need_root; idle_check ;;
  --backup-sunshine) need_root; backup_sunshine ;;
  --wol-state)       wol_state ;;
  --stream-info)     stream_info "${2:-}" ;;
  --stream-watch)    stream_watch "${2:-300}" "${3:-}" ;;
  --composite)       composite "${2:-}" ;;
  --hdr)             game_hdr "${2:-}" ;;
  --stream-end)      stream_end ;;
  --version)         echo "steam-remote-server $VERSION" ;;
  -h|--help)         sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' ;;
  *)                 die "Unknown option '$1'. See: $0 --help" ;;
esac
