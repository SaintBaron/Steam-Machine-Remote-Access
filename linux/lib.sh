# shellcheck shell=bash disable=SC2034  # variables are used by the scripts that source this
# lib.sh: shared code for the Steam Machine Remote Access Linux commands.
# Sourced by steam-connect, steam-ssh and steam-remote-setup; not run on its own.

SR_VERSION="1.0.1"
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
      MACHINE_IP|REMOTE_MODE|REMOTE_MACHINE_IP|REMOTE_PC_IP|MACHINE_USER|HOST_ALIAS|MACHINE_MAC|BROADCAST|MOONLIGHT_APP|WEBUI_PORT|PERSIST|KEEPALIVE|WAKE_TIMEOUT|BLACK_SCREEN_FIX|CLIENT_NAME)
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
  CTL="$HOME/.ssh/cm-$HOST_ALIAS"   # the shared login's socket
}

port_open() { timeout 2 bash -c "</dev/tcp/$TARGET/$1" 2>/dev/null; }
wait_port() {   # PORT SECONDS: wait until the port answers
  local end=$((SECONDS + $2))
  until port_open "$1"; do
    [ "$SECONDS" -lt "$end" ] || return 1
    sleep 1
  done
}
ping_ok()   { ping -c 1 -W 2 "$1" >/dev/null 2>&1; }
is_awake()  { ping_ok "$TARGET"; }
# Is the Steam Machine on a network this PC is directly plugged into (not through a VPN)?
# Wake-on-LAN only works then. Ethernet, Wi-Fi and bridges are type 1 (ARPHRD_ETHER);
# VPN interfaces (wg0, tailscale0, tun0...) are not.
on_home_network() {
  local route dev
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
  mac=$(ip neigh show "$MACHINE_IP" 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "lladdr") { print $(i + 1); exit }}')
  if valid_mac "$mac" && [ "$mac" != "$(cat "$SR_MAC_CACHE" 2>/dev/null)" ]; then
    mkdir -p "$SR_CONFIG_DIR"
    (umask 077; printf '%s\n' "$mac" >"$SR_MAC_CACHE")
  fi
}

# Moonlight: the Flatpak if installed, otherwise a native moonlight / moonlight-qt.
moonlight_cmd() {
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
  return 0
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
