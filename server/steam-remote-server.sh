#!/bin/bash
# steam-remote-server.sh: the Steam Machine side of Steam Machine Remote Access.
# https://github.com/SaintBaron/Steam-Machine-Remote-Access
#
# Installs and maintains everything on the Steam Machine (SteamOS):
#   SSH lockdown    only your PC(s), only key + password, no root
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
#   steam-remote-server.sh --uninstall [--keep-sunshine] [--keep-ssh]
#   steam-remote-server.sh --version
# Used by the systemd units it installs:
#   --boot-display   --idle-check   --backup-sunshine

set -u
umask 022

VERSION="1.0.0"
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
      USER_NAME|ALLOWED_IPS|REMOTE_IPS|STREAM_OUTPUT|TV_OUTPUT|IDLE_MINUTES|SUNSHINE_NAME|WAKE_ON_LAN) printf -v "$key" '%s' "$val" ;;
    esac
  done <"$CONFIG"
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
  put "$SSHD_DROPIN" 644 <<EOF && ssh_changed=1
# Steam Machine Remote Access: only $USER_NAME, only from the allowed PCs, key AND password.
PermitRootLogin no
AddressFamily inet
AllowUsers$ips_ssh
AuthenticationMethods publickey,password
PubkeyAuthentication yes
PasswordAuthentication yes
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
  else
    local kv k
    for kv in "sunshine_name = $SUNSHINE_NAME" "address_family = ipv4" "lan_encryption_mode = 2" \
              "wan_encryption_mode = 2" "upnp = disabled" "origin_web_ui_allowed = pc"; do
      k=${kv%% =*}
      grep -qxF "$kv" "$SUN_CONF" && continue
      sed -i "/^$k *=/d" "$SUN_CONF" && echo "$kv" >>"$SUN_CONF" && CHANGED+=("Sunshine: $kv")
    done
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

# ------------------------------------------------------------------ check (no root)
check() {
  local bad=0 f u
  if ! load_config; then echo "MISSING $CONFIG (run the first-time setup)"; exit 1; fi
  validate_config 2>&1 | sed 's/^/CONFIG /' | grep . && bad=1
  for f in "$SSHD_DROPIN" "$NFT_FILE"; do
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
    command -v xprop >/dev/null 2>&1 || warn "xprop is missing, so the Game Mode black-screen workaround won't work."
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
  if [ "$first" = 1 ] || [ "$(ask "Options: idle stop after ${IDLE_MINUTES} min, Wake-on-LAN ${wol_text}, name '${SUNSHINE_NAME}'. Change them? [y/N] ")" = y ]; then
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
  say "Done. From now on SSH needs your key AND the $USER_NAME password, from $(echo "$ALLOWED_IPS $REMOTE_IPS" | xargs | sed 's/ / or /g') only."
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
  --uninstall)       shift; uninstall "$@" ;;
  --boot-display)    need_root; load_config && show_tv ;;
  --idle-check)      need_root; idle_check ;;
  --backup-sunshine) need_root; backup_sunshine ;;
  --wol-state)       wol_state ;;
  --version)         echo "steam-remote-server $VERSION" ;;
  -h|--help)         sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' ;;
  *)                 die "Unknown option '$1'. See: $0 --help" ;;
esac
