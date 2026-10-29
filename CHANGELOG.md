# Changelog

## 1.2.0 - 2026-10-29

- Picture quality and HDR guide: `docs/quality.md`.
- Every connection prints a **stream check**: the dummy plug's best mode and whether it accepts HDR, Game Mode's HDR setting, the encoder, and whether HDR can work. When Moonlight connects, it says whether the stream is SDR or HDR, and which side to fix if it isn't what you asked for.
- New `steam-remote-setup quality` (Windows: `steam-remote-setup.ps1 quality`): resolution, frame rate, bitrate, codec and HDR, handed to Moonlight on every connection, plus the Steam Machine's encoder preset.
- The first-time setup now offers everything: a new optional stream quality step (step 3), the less common PC settings (Moonlight app, capture fix, wake wait, Wake-on-LAN broadcast, name in Sunshine) in step 1, and the encoder preset among the Steam Machine's options. The setup now has 8 steps.
- Moonlight's **Enable HDR** is now the one HDR switch: each stream turns Game Mode's HDR on or off to match it (or `STREAM_HDR`), and Steam's own setting comes back when you disconnect. `MATCH_HDR="no"` turns this off. The stream check's HDR line follows the same choice.
- Optional key-only SSH logins (`AUTH_MODE="key"`): one passphrase instead of a passphrase and a password. Key and password stays the default. Choose it in the setup or with `steam-remote-setup auth`, which refuses if the key has no passphrase. SSH's start check accepts either mode and still refuses SteamOS's defaults. See `docs/security.md`.
- The self-heal and repairs rebuild everything from the Steam Machine's config, including the login mode, encoder preset and the capture-fix clean-up. The saved capture-fix state is tied to the current boot, so a stale one is never "restored".
- A lower bitrate is used automatically when connecting through the VPN (`STREAM_BITRATE_AWAY`, 20 Mbps by default).
- Linux and macOS: plain `ssh steam-machine` and `scp` now wake the Steam Machine first if it's asleep and you're at home, through a new `steam-wake` command run from `~/.ssh/config`. It's silent when it's already awake, does nothing through a VPN, and never changes SSH's settings. The installer updates the `~/.ssh/config` block when updating (or run `steam-remote-setup ssh-config`). `steam-wake` on its own just wakes it.
- Linux and macOS: Moonlight's messages go to `~/.local/state/steam-remote/moonlight.log`, and `steam-connect` warns if an older Moonlight rejects one of the stream settings.
- The Steam Machine's video encoder now uses its `quality` preset by default (`ENCODER_QUALITY`; needs Sunshine 2026.906 or later). Choose `balanced`, `speed` or `auto` instead with the setup.
- The Game Mode capture fix (`BLACK_SCREEN_FIX`) now also keeps HDR colours and Steam's menus right in the stream. It's undone whenever Sunshine stops, including by the idle timer, and puts back Steam's own *Force Composite* setting if you had it on.

## 1.1.0 - 2026-10-29

- macOS support (12 Monterey or later): the same commands as Linux, double-click launchers, and a macOS guide (`docs/macos.md`).
- Fixed: closing the `steam-connect` window could, rarely, skip the automatic disconnect.

## 1.0.1 - 2026-10-29

- SteamOS updates can no longer leave SSH open with SteamOS's default settings:
  - the SSH lockdown, firewall rules, sudo rule and idle timer are added to SteamOS's own update keep list (`/etc/atomic-update.conf.d/steam-remote.conf`);
  - SteamOS's SSH service now requires the firewall, and refuses to start unless the lockdown is actually in effect.
- To update: run the installer again, then `steam-remote-setup update-server` (Windows: `steam-remote-setup.ps1 update-server`).

## 1.0.0 - 2026-10-27

First public release.

- Installers for Linux (Arch and Debian based) and Windows 10/11
- `steam-remote-setup` sets up both the PC and the Steam Machine, including picking which display output is the dummy plug and which is the TV
- `steam-connect` stays open while you stream and cleans up when you press Q or close the window
- `steam-ssh`, and `steam-pair` for setting the web UI login and pairing Moonlight from the terminal
- Steam Machine side: SSH and firewall locked to your PC(s), Sunshine on demand, Wake-on-LAN, idle timer, pairing backup, and a boot service that repairs things after SteamOS updates
- More than one PC can be allowed (`add-client` / `remove-client`)
- Optional remote access through a VPN (router VPN, Tailscale or another), off by default (`steam-remote-setup remote`)
