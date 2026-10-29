# shellcheck shell=bash disable=SC2034  # variables are used by the scripts that source this
# lib.sh: shared code for the Steam Machine Remote Access commands on Linux and macOS.
# Written for bash 3.2 (macOS's built-in bash) and later.
# Sourced by steam-connect, steam-ssh and steam-remote-setup; not run on its own.

SR_VERSION="1.2.0"
SR_OS=$(uname -s)   # Linux or Darwin (macOS)
SR_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/steam-remote"
SR_CONFIG="$SR_CONFIG_DIR/config"
SR_MAC_CACHE="$SR_CONFIG_DIR/mac"
SR_SHARE="${STEAM_REMOTE_SHARE:-$HOME/.local/share/steam-remote}"
SR_KIT="/home/.steam-remote"                     # on the Steam Machine
SR_SERVER="$SR_KIT/steam-remote-server.sh"       # on the Steam Machine
SR_SUN_UNIT="steam-remote-sunshine.service"      # on the Steam Machine
SR_MOONLIGHT_FLATPAK="com.moonlight_stream.Moonlight"

# Defaults (the config file overrides these).
MACHINE_IP=""
REMOTE_MODE="off"          # off | router | tailscale | other
REMOTE_MACHINE_IP=""       # the Steam Machine's address on the VPN, if different from MACHINE_IP
REMOTE_PC_IP=""            # this PC's address on the VPN (what the Steam Machine allows)
MACHINE_USER="deck"
HOST_ALIAS="steam-machine"
KEY_FILE="$HOME/.ssh/steam-machine_ed25519"
MACHINE_MAC=""
BROADCAST=""
MOONLIGHT_APP="Desktop"
WEBUI_PORT="47990"
PERSIST="2h"
KEEPALIVE="600"
WAKE_TIMEOUT="90"
BLACK_SCREEN_FIX="yes"
CLIENT_NAME=""
# Stream settings handed to Moonlight (empty = Moonlight's own setting).
STREAM_RESOLUTION=""       # e.g. 3840x2160
STREAM_FPS=""              # e.g. 60 or 120
STREAM_BITRATE=""          # Mbps, at home
STREAM_BITRATE_AWAY="20"   # Mbps, through a VPN
STREAM_CODEC=""            # auto, HEVC, AV1 or H.264
STREAM_HDR=""              # yes or no

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWarning:\033[0m %s\n' "$*" >&2; }
die()  {
  printf '\033[1;31mError:\033[0m %s\n' "$*" >&2
  # Launched from the app menu: keep the window open so the error can be read.
  # (steam-connect pauses after disconnecting instead, so it isn't asked twice.)
  [ -n "${STEAM_REMOTE_PAUSE:-}" ] && [ -t 0 ] && [ "${SR_ARMED:-0}" != 1 ] && read -r -p 'Press Enter to close this window' _
  exit 1
}

valid_ip()     { [[ "$1" =~ ^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$ ]]; }
valid_mac()    { [[ "$1" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]]; }
valid_output() { [[ "$1" =~ ^card[0-9]+-[A-Za-z0-9-]+$ ]]; }

# The config is plain KEY="value" lines. It's parsed (never run), and only known keys are read.
sr_parse_config() {
  local file=$1 line key val
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^([A-Z_]+)=(\"([^\"]*)\"|([^[:space:]#\"]*))[[:space:]]*(#.*)?$ ]] || continue
    key=${BASH_REMATCH[1]}; val=${BASH_REMATCH[3]}${BASH_REMATCH[4]}
    case "$key" in
      MACHINE_IP|REMOTE_MODE|REMOTE_MACHINE_IP|REMOTE_PC_IP|MACHINE_USER|HOST_ALIAS|MACHINE_MAC|BROADCAST|MOONLIGHT_APP|WEBUI_PORT|PERSIST|KEEPALIVE|WAKE_TIMEOUT|BLACK_SCREEN_FIX|CLIENT_NAME|\
      STREAM_RESOLUTION|STREAM_FPS|STREAM_BITRATE|STREAM_BITRATE_AWAY|STREAM_CODEC|STREAM_HDR)
        printf -v "$key" '%s' "$val" ;;
      KEY_FILE) KEY_FILE=${val/#\~/$HOME} ;;
    esac
  done <"$file"
}

load_config() {
  sr_parse_config "$SR_CONFIG" || die "No config yet. Run: steam-remote-setup"
  valid_ip "$MACHINE_IP" || die "MACHINE_IP in $SR_CONFIG isn't set to an IPv4 address. Run: steam-remote-setup"
  [[ "$HOST_ALIAS" =~ ^[A-Za-z0-9._-]+$ ]] || die "HOST_ALIAS in $SR_CONFIG may only use letters, numbers, . _ -"
  [[ "$WEBUI_PORT" =~ ^[0-9]{2,5}$ ]] || die "WEBUI_PORT in $SR_CONFIG must be a port number"
  [[ "$KEEPALIVE" =~ ^[0-9]+$ ]] && [ "$KEEPALIVE" -ge 30 ] || KEEPALIVE=600
  [[ "$WAKE_TIMEOUT" =~ ^[0-9]+$ ]] || WAKE_TIMEOUT=90
  [ -z "$REMOTE_MACHINE_IP" ] || valid_ip "$REMOTE_MACHINE_IP" || die "REMOTE_MACHINE_IP in $SR_CONFIG isn't an IPv4 address"
  [ -z "$REMOTE_PC_IP" ] || valid_ip "$REMOTE_PC_IP" || die "REMOTE_PC_IP in $SR_CONFIG isn't an IPv4 address"
  [[ "$REMOTE_MODE" =~ ^(off|router|tailscale|other)$ ]] || REMOTE_MODE=off
  TARGET=$MACHINE_IP   # the address actually used; ensure_awake may switch it to REMOTE_MACHINE_IP
  [[ "$PERSIST" =~ ^([0-9]+[smhdwSMHDW]?)+$ ]] || PERSIST=2h
  [ -n "$BROADCAST" ] || BROADCAST="${MACHINE_IP%.*}.255"
  valid_ip "$BROADCAST" || die "BROADCAST in $SR_CONFIG isn't an IPv4 address"
  [ -n "$CLIENT_NAME" ] || CLIENT_NAME=$(uname -n 2>/dev/null || echo linux-pc)
  if ! check_stream_settings; then
    warn "Using Moonlight's own stream settings instead. Fix it with: steam-remote-setup quality"
    STREAM_RESOLUTION=""; STREAM_FPS=""; STREAM_BITRATE=""; STREAM_BITRATE_AWAY=""; STREAM_CODEC=""; STREAM_HDR=""
  fi
  CTL="$HOME/.ssh/cm-$HOST_ALIAS"   # the shared login's socket
}

# Stream settings: each is empty (Moonlight decides) or a plain value. Codec names are
# matched case-insensitively and stored the way Moonlight spells them.
check_stream_settings() {
  local c
  [ -z "$STREAM_RESOLUTION" ] || [[ "$STREAM_RESOLUTION" =~ ^[1-9][0-9]{2,4}x[1-9][0-9]{2,4}$ ]] \
    || { warn "STREAM_RESOLUTION must look like 3840x2160 (or be empty)"; return 1; }
  [ -z "$STREAM_FPS" ] || [[ "$STREAM_FPS" =~ ^[1-9][0-9]{1,2}$ ]] \
    || { warn "STREAM_FPS must be a number like 60 or 120 (or be empty)"; return 1; }
  for c in "$STREAM_BITRATE" "$STREAM_BITRATE_AWAY"; do
    [ -z "$c" ] || { [[ "$c" =~ ^[1-9][0-9]{0,2}$ ]] && [ "$c" -le 500 ]; } \
      || { warn "STREAM_BITRATE and STREAM_BITRATE_AWAY are in Mbps, from 1 to 500 (or empty)"; return 1; }
  done
  c=$(printf '%s' "$STREAM_CODEC" | tr '[:lower:]' '[:upper:]')
  case "$c" in
    "") ;; AUTO) STREAM_CODEC=auto ;; HEVC|H265|H.265) STREAM_CODEC=HEVC ;; AV1) STREAM_CODEC=AV1 ;;
    H264|H.264) STREAM_CODEC=H.264 ;;
    *) warn "STREAM_CODEC must be auto, HEVC, AV1 or H.264 (or empty)"; return 1 ;;
  esac
  [[ "$STREAM_HDR" =~ ^(yes|no|)$ ]] || { warn "STREAM_HDR must be yes, no or empty"; return 1; }
}

# Moonlight's options for this stream, one per line (Moonlight's bitrate is in Kbps).
# Away from home (through a VPN), STREAM_BITRATE_AWAY replaces STREAM_BITRATE.
moonlight_args() {
  local rate=$STREAM_BITRATE
  if [ -n "$STREAM_BITRATE_AWAY" ] && { [ "$TARGET" != "$MACHINE_IP" ] || ! on_home_network; }; then
    rate=$STREAM_BITRATE_AWAY
  fi
  [ -z "$STREAM_RESOLUTION" ] || printf '%s\n' --resolution "$STREAM_RESOLUTION"
  [ -z "$STREAM_FPS" ] || printf '%s\n' --fps "$STREAM_FPS"
  [ -z "$rate" ] || printf '%s\n' --bitrate "$((rate * 1000))"
  [ -z "$STREAM_CODEC" ] || printf '%s\n' --video-codec "$STREAM_CODEC"
  case "$STREAM_HDR" in yes) echo --hdr ;; no) echo --no-hdr ;; esac
}

port_open() {   # PORT: does it accept a connection within ~2 seconds?
  if command -v timeout >/dev/null 2>&1; then timeout 2 bash -c "</dev/tcp/$TARGET/$1" 2>/dev/null
  else nc -z -G 2 "$TARGET" "$1" >/dev/null 2>&1; fi   # macOS: no timeout command, but nc has -G
}
wait_port() {   # PORT SECONDS: wait until the port answers
  local end=$((SECONDS + $2))
  until port_open "$1"; do
    [ "$SECONDS" -lt "$end" ] || return 1
    sleep 1
  done
}
ping_ok() {
  if [ "$SR_OS" = Darwin ]; then ping -c 1 -t 2 "$1" >/dev/null 2>&1   # macOS: -t = timeout in seconds
  else ping -c 1 -W 2 "$1" >/dev/null 2>&1; fi
}
is_awake()  { ping_ok "$TARGET"; }
# Is the Steam Machine on a network this PC is directly plugged into (not through a VPN)?
# Wake-on-LAN only works then. Ethernet, Wi-Fi and bridges are type 1 (ARPHRD_ETHER);
# VPN interfaces (wg0, tailscale0, tun0...) are not.
on_home_network() {
  local route dev
  if [ "$SR_OS" = Darwin ]; then
    # macOS: on the home network the route has no gateway and uses a physical port (en*).
    route=$(route -n get "$MACHINE_IP" 2>/dev/null) || return 1
    grep -q 'flags:.*GATEWAY' <<<"$route" && return 1
    dev=$(awk '$1 == "interface:" {print $2; exit}' <<<"$route")
    case "$dev" in en*|bridge*) return 0 ;; *) return 1 ;; esac
  fi
  route=$(ip -o route get "$MACHINE_IP" 2>/dev/null) || return 1
  case "$route" in *" via "*) return 1 ;; esac
  dev=$(sed -n 's/.* dev \([^ ]*\).*/\1/p' <<<"$route")
  [ -n "$dev" ] && [ "$(cat "/sys/class/net/$dev/type" 2>/dev/null)" = 1 ]
}
logged_in() { ssh -S "$CTL" -O check "$HOST_ALIAS" >/dev/null 2>&1; }
# Run a command over the shared login. -n: never read this terminal, so it can't eat keypresses.
run()       { ssh -n -S "$CTL" -o ControlMaster=no "$HOST_ALIAS" "$@"; }

# Wake-on-LAN: a magic packet (6 x 0xFF, then the MAC 16 times) to UDP port 9.
wake() {
  python3 -I - "$1" "$BROADCAST" <<'PY'
import socket, sys
mac = bytes.fromhex(sys.argv[1].replace(":", ""))
packet = b"\xff" * 6 + mac * 16
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
for addr in ("255.255.255.255", sys.argv[2]):
    for _ in range(3):
        try:
            s.sendto(packet, (addr, 9))
        except OSError:
            pass
PY
}

# Set TARGET to whichever address answers (home first, then VPN). Returns 1 if neither does.
find_target() {
  if ping_ok "$MACHINE_IP"; then TARGET=$MACHINE_IP; return 0; fi
  if [ -n "$REMOTE_MACHINE_IP" ] && ping_ok "$REMOTE_MACHINE_IP"; then TARGET=$REMOTE_MACHINE_IP; return 0; fi
  return 1
}

# Find the Steam Machine (home address first, then its VPN address) and make sure
# SSH answers, waking it with Wake-on-LAN if we're at home. Sets TARGET.
# "quiet" skips the progress messages when it's already awake.
ensure_awake() {
  [ "${1:-}" = quiet ] || say "Checking the Steam Machine is awake"
  if ping_ok "$MACHINE_IP"; then
    TARGET=$MACHINE_IP
    on_home_network || [ "${1:-}" = quiet ] || say "Reaching it through the VPN"
    [ "${1:-}" = quiet ] || say "Awake"; return 0
  fi
  if [ -n "$REMOTE_MACHINE_IP" ] && ping_ok "$REMOTE_MACHINE_IP"; then
    TARGET=$REMOTE_MACHINE_IP
    [ "${1:-}" = quiet ] || say "Awake (through the VPN, at $TARGET)"; return 0
  fi
  if ! on_home_network; then
    if [ "$REMOTE_MODE" = off ]; then
      die "Can't reach $MACHINE_IP. Is this PC on your home network? (Remote access is off: see docs/remote-access.md.)"
    fi
    die "Can't reach the Steam Machine. Away from home? Connect your VPN first. It also has to be awake: Wake-on-LAN only works from your home network (see docs/remote-access.md)."
  fi
  TARGET=$MACHINE_IP
  local mac="${MACHINE_MAC:-$(cat "$SR_MAC_CACHE" 2>/dev/null)}"
  valid_mac "$mac" \
    || die "No reply from $MACHINE_IP and its network address (MAC) isn't known yet. Wake it by hand this once; it's learned on every successful connection."
  say "Asleep or off: sending a Wake-on-LAN signal to $mac"
  wake "$mac" || die "Couldn't send the Wake-on-LAN signal (is python3 installed?)."
  local end=$((SECONDS + WAKE_TIMEOUT)) resend=$((SECONDS + 10))
  until is_awake; do
    [ "$SECONDS" -lt "$end" ] || die "No reply $WAKE_TIMEOUT seconds after the wake signal. If it was shut down (not asleep), press its power button. See docs/troubleshooting.md."
    # Wake packets are UDP and can get lost, so send another every 10 seconds.
    if [ "$SECONDS" -ge "$resend" ]; then wake "$mac"; resend=$((SECONDS + 10)); fi
    sleep 1
  done
  say "Awake. Waiting for SSH"
  wait_port 22 60 || die "It woke up, but SSH didn't answer within 60 seconds."
}

# Remember the Steam Machine's MAC (from this PC's own neighbour table) for Wake-on-LAN.
learn_mac() {
  local mac
  [ "$TARGET" = "$MACHINE_IP" ] && on_home_network || return 0
  if [ "$SR_OS" = Darwin ]; then
    # macOS: "? (192.168.0.50) at 4:d9:f5:1:2:3 on en0 ...": pad each part to two digits.
    mac=$(arp -n "$MACHINE_IP" 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "at") { print $(i + 1); exit }}' \
          | awk -F: 'NF == 6 {for (i = 1; i <= 6; i++) printf "%s%02s", (i > 1 ? ":" : ""), $i; print ""}' | tr ' ' 0 | tr 'A-F' 'a-f')
  else
    mac=$(ip neigh show "$MACHINE_IP" 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "lladdr") { print $(i + 1); exit }}')
  fi
  if valid_mac "$mac" && [ "$mac" != "$(cat "$SR_MAC_CACHE" 2>/dev/null)" ]; then
    mkdir -p "$SR_CONFIG_DIR"
    (umask 077; printf '%s\n' "$mac" >"$SR_MAC_CACHE")
  fi
}

# Moonlight: the macOS app, the Flatpak, or a native moonlight / moonlight-qt.
moonlight_cmd() {
  local app
  for app in /Applications/Moonlight.app "$HOME/Applications/Moonlight.app"; do
    if [ -x "$app/Contents/MacOS/Moonlight" ]; then echo "$app/Contents/MacOS/Moonlight"; return; fi
  done
  if command -v flatpak >/dev/null 2>&1 && flatpak info "$SR_MOONLIGHT_FLATPAK" >/dev/null 2>&1; then
    echo "flatpak run $SR_MOONLIGHT_FLATPAK"
  elif command -v moonlight >/dev/null 2>&1; then echo moonlight
  elif command -v moonlight-qt >/dev/null 2>&1; then echo moonlight-qt
  fi
}
moonlight_kill() {
  flatpak kill "$SR_MOONLIGHT_FLATPAK" >/dev/null 2>&1
  pkill -x moonlight >/dev/null 2>&1
  pkill -x moonlight-qt >/dev/null 2>&1
  pkill -x Moonlight >/dev/null 2>&1   # macOS
  return 0
}

# Run a command in its own session, detached from this terminal (Linux: setsid;
# macOS has no setsid command, so python does the same system call).
detach() {
  if command -v setsid >/dev/null 2>&1; then setsid "$@"
  else python3 -I -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$@"; fi
}

# The full path of a file (macOS before 12.3 has no readlink -f).
real_path() {
  readlink -f "$1" 2>/dev/null || python3 -I -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

# PIDs of ssh processes whose command line mentions any of the given words.
ssh_pids() {
  local w args=()
  for w in "$@"; do [ -n "$w" ] && args+=(-e "$w"); done
  ps -axo pid=,command= | awk '{c = $2; sub(".*/", "", c); if (c == "ssh") print}' | grep -F "${args[@]}" | awk '{print $1}' | xargs
}

# Only one steam-connect at a time: flock on Linux, a lock folder elsewhere.
take_lock() {   # LOCKFILE
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$1"; flock -n 9; return
  fi
  local dir="$1.d" pid
  if ! mkdir "$dir" 2>/dev/null; then
    pid=$(cat "$dir/pid" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then return 1; fi
    rm -rf "$dir"; mkdir "$dir" 2>/dev/null || return 1
  fi
  echo $$ >"$dir/pid"
  SR_LOCK_DIR=$dir
}

# Read STREAM_OUTPUT / TV_OUTPUT from the Steam Machine's config (over the shared login)
# and build the display-switching commands. Values are validated before use.
DUMMY_ON=""; TV_ON=""
load_outputs() {
  local conf so tv
  conf=$(run "cat $SR_KIT/config" 2>/dev/null) || return 0
  so=$(sed -n 's/^STREAM_OUTPUT="\{0,1\}\([^"#[:space:]]*\).*/\1/p' <<<"$conf" | head -n 1)
  tv=$(sed -n 's/^TV_OUTPUT="\{0,1\}\([^"#[:space:]]*\).*/\1/p' <<<"$conf" | head -n 1)
  if valid_output "$so" && valid_output "$tv" && [ "$so" != "$tv" ]; then
    DUMMY_ON="echo off | sudo -n tee /sys/class/drm/$tv/status >/dev/null; echo detect | sudo -n tee /sys/class/drm/$so/status >/dev/null"
    TV_ON="echo off | sudo -n tee /sys/class/drm/$so/status >/dev/null; echo detect | sudo -n tee /sys/class/drm/$tv/status >/dev/null"
  fi
}
