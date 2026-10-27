#!/usr/bin/env bash
# install.sh: install the Steam Machine Remote Access commands on a Linux PC
# (Arch, CachyOS, Manjaro, EndeavourOS, Debian, Ubuntu, Linux Mint, Pop!_OS...).
# https://github.com/SaintBaron/Steam-Machine-Remote-Access
#
#   curl -fsSL https://raw.githubusercontent.com/SaintBaron/Steam-Machine-Remote-Access/v1.0.0/install.sh | bash
#   ./install.sh                 from a cloned copy of the repo
#
# Options:
#   --no-deps      don't install system packages or Moonlight
#   --ref REF      install a different tag or branch (default: this release) (download mode only)
#   --uninstall    remove the commands, launchers and icons (keeps your config and SSH key)
#   --purge        --uninstall, and also delete the config
#
# Installs, all inside your home folder (no root needed except for system packages):
#   ~/.local/bin/                       steam-connect, steam-ssh, steam-pair, steam-remote-setup
#   ~/.local/share/steam-remote/        shared code and the Steam Machine's server script
#   ~/.local/share/applications/        app-menu launchers
#   ~/.local/share/icons/hicolor/...    their icons

# shellcheck disable=SC2015,SC1091
set -euo pipefail

REPO="${STEAM_REMOTE_REPO:-SaintBaron/Steam-Machine-Remote-Access}"
REF="v1.0.0"   # the release this installer belongs to
DEPS=1
ACTION=install

BIN="$HOME/.local/bin"
SHARE="$HOME/.local/share/steam-remote"
APPS="$HOME/.local/share/applications"
ICONS="$HOME/.local/share/icons/hicolor/scalable/apps"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/steam-remote"
COMMANDS=(steam-connect steam-ssh steam-pair steam-remote-setup)

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }
ask_yes() { local r; read -r -p "$1 [Y/n] " r </dev/tty || r=n; [[ ! "$r" =~ ^[Nn] ]]; }

while [ $# -gt 0 ]; do
  case "$1" in
    --no-deps)   DEPS=0 ;;
    --ref)       REF=${2:?--ref needs a tag or branch}; shift ;;
    --uninstall) ACTION=uninstall ;;
    --purge)     ACTION=purge ;;
    -h|--help)   sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option '$1'" ;;
  esac
  shift
done

[ "$(id -u)" != 0 ] || die "Run this as your normal user, not root (it installs into your home folder)."

# ------------------------------------------------------------------ uninstall
if [ "$ACTION" != install ]; then
  for c in "${COMMANDS[@]}"; do rm -f "$BIN/$c"; done
  rm -rf "$SHARE"
  rm -f "$APPS/steam-remote-connect.desktop" "$APPS/steam-remote-ssh.desktop"
  rm -f "$ICONS/steam-remote-connect.svg" "$ICONS/steam-remote-ssh.svg"
  [ "$ACTION" = purge ] && rm -rf "$CONFIG_DIR"
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS" >/dev/null 2>&1 || true
  say "Removed the commands, launchers and icons."
  [ "$ACTION" = purge ] && say "Removed $CONFIG_DIR."
  echo "Not touched: your SSH key, the 'Host' block in ~/.ssh/config, Moonlight, and the Steam Machine."
  echo "See docs/uninstall.md for those."
  exit 0
fi

# ------------------------------------------------------------------ where the files come from
SRC=""
here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)
if [ -n "$here" ] && [ -f "$here/linux/steam-connect" ] && [ -f "$here/server/steam-remote-server.sh" ]; then
  SRC=$here
  say "Installing from $SRC"
else
  command -v curl >/dev/null 2>&1 || die "curl is needed to download. Install it, or clone the repo and run ./install.sh"
  SRC=$(mktemp -d)
  trap 'rm -rf "$SRC"' EXIT
  say "Downloading $REPO ($REF)"
  base="https://raw.githubusercontent.com/$REPO/$REF"
  for f in linux/lib.sh linux/steam-connect linux/steam-ssh linux/steam-pair linux/steam-remote-setup \
           server/steam-remote-server.sh assets/icons/steam-remote-connect.svg assets/icons/steam-remote-ssh.svg \
           config.example VERSION; do
    mkdir -p "$SRC/$(dirname "$f")"
    curl -fsSL --retry 2 "$base/$f" -o "$SRC/$f" || die "Couldn't download $f from $base"
    [ -s "$SRC/$f" ] || die "Downloaded an empty $f"
  done
  head -n 1 "$SRC/linux/steam-connect" | grep -q '^#!/usr/bin/env bash' || die "The download doesn't look right (check the repo name: $REPO)."
fi

# ------------------------------------------------------------------ system packages
. /etc/os-release 2>/dev/null || true
family=""
case " ${ID:-} ${ID_LIKE:-} " in
  *" arch "*)                 family=arch ;;
  *" debian "*|*" ubuntu "*)  family=debian ;;
esac

if [ "$DEPS" = 1 ]; then
  case "$family" in
    arch)   pkgs=(openssh python iproute2 iputils util-linux procps-ng coreutils gawk findutils flatpak curl); cmd=(sudo pacman -S --needed --noconfirm) ;;
    debian) pkgs=(openssh-client python3 iproute2 iputils-ping util-linux procps coreutils findutils flatpak curl); cmd=(sudo apt-get install -y) ;;
    *)      pkgs=(); warn "Unrecognised distribution (${PRETTY_NAME:-unknown}). Install these yourself: the OpenSSH client, python3, iproute2 (ip, ss), ping, util-linux (flock, setsid), procps (pgrep), coreutils (timeout), awk and flatpak." ;;
  esac
  missing=()
  for p in ssh scp ssh-keygen python3 ip ss ping flock setsid pgrep pkill timeout awk xargs flatpak; do command -v "$p" >/dev/null 2>&1 || missing+=("$p"); done
  if [ ${#pkgs[@]} -gt 0 ] && [ ${#missing[@]} -gt 0 ]; then
    say "Missing: ${missing[*]}"
    if ask_yes "Install the needed packages with sudo (${pkgs[*]})?"; then
      [ "$family" = debian ] && sudo apt-get update
      "${cmd[@]}" "${pkgs[@]}"
    else
      warn "Skipped. The commands won't work until these are installed."
    fi
  fi

  # Moonlight (Flatpak, per-user, from Flathub)
  if ! { command -v flatpak >/dev/null 2>&1 && flatpak info com.moonlight_stream.Moonlight >/dev/null 2>&1; } \
     && ! command -v moonlight >/dev/null 2>&1 && ! command -v moonlight-qt >/dev/null 2>&1; then
    if command -v flatpak >/dev/null 2>&1 && ask_yes "Install Moonlight from Flathub (Flatpak, just for you)?"; then
      flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
      flatpak install --user -y flathub com.moonlight_stream.Moonlight
    else
      warn "Moonlight isn't installed. Install it before streaming (see the guide)."
    fi
  fi
fi

# ------------------------------------------------------------------ install files
mkdir -p "$BIN" "$SHARE/server" "$APPS" "$ICONS"
install -m 644 "$SRC/linux/lib.sh" "$SHARE/lib.sh"
install -m 755 "$SRC/server/steam-remote-server.sh" "$SHARE/server/steam-remote-server.sh"
install -m 644 "$SRC/config.example" "$SHARE/config.example"
[ -f "$SRC/VERSION" ] && install -m 644 "$SRC/VERSION" "$SHARE/VERSION"
for c in "${COMMANDS[@]}"; do install -m 755 "$SRC/linux/$c" "$BIN/$c"; done
install -m 644 "$SRC/assets/icons/steam-remote-connect.svg" "$ICONS/steam-remote-connect.svg"
install -m 644 "$SRC/assets/icons/steam-remote-ssh.svg" "$ICONS/steam-remote-ssh.svg"

# App-menu launchers. They open a terminal; STEAM_REMOTE_PAUSE keeps it open on errors.
cat >"$APPS/steam-remote-connect.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Steam Machine: Connect
Comment=Wake the Steam Machine, start Sunshine and stream it in Moonlight
Exec=env STEAM_REMOTE_PAUSE=1 "$BIN/steam-connect"
Icon=steam-remote-connect
Terminal=true
Categories=Network;RemoteAccess;Game;
EOF
cat >"$APPS/steam-remote-ssh.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Steam Machine: SSH
Comment=Open a terminal on the Steam Machine
Exec=env STEAM_REMOTE_PAUSE=1 "$BIN/steam-ssh"
Icon=steam-remote-ssh
Terminal=true
Categories=Network;RemoteAccess;
EOF
chmod 644 "$APPS"/steam-remote-*.desktop
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS" >/dev/null 2>&1 || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true

say "Installed $(cat "$SHARE/VERSION" 2>/dev/null || echo Steam Machine Remote Access): ${COMMANDS[*]}"

# ------------------------------------------------------------------ PATH
case ":$PATH:" in
  *":$BIN:"*) ;;
  *)
    warn "$BIN isn't on your PATH yet, so the commands won't be found. Fix it with ONE of:"
    echo "   fish:  fish_add_path ~/.local/bin"
    echo "   bash:  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc && source ~/.bashrc"
    echo "   zsh:   echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc && source ~/.zshrc"
    ;;
esac

echo
say "Next (Part 4 of your guide): run steam-remote-setup. Do Part 2, at the Steam Machine, first if you haven't."
