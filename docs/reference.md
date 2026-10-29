# Reference

Every file, service, command and setting, for when you want to know exactly what's where.

## Commands on your PC

| Linux and macOS | Windows | What it does |
| --- | --- | --- |
| `steam-connect` | *Steam Machine - Connect* | Wake, log in, start Sunshine, stream. Press **Q** to end |
| `steam-connect restart` | `steam-connect.ps1 -Restart` | Same, restarting Sunshine first |
| `steam-connect nostream` | *Steam Machine - Connect (no stream)* | Everything except Moonlight (for pairing or the web UI) |
| `steam-connect disconnect` | (not needed) | Clean up after a crash |
| `steam-wake` | (not needed: use `steam-ssh.ps1`) | Wake the Steam Machine and wait until it answers. Plain `ssh steam-machine` and `scp` run it by themselves |
| `steam-ssh [command]` | *Steam Machine - SSH* / `steam-ssh.ps1 [command]` | A terminal on the Steam Machine, or run one command there |
| `steam-pair login` / `steam-pair` | `steam-pair.ps1 -Login` / `steam-pair.ps1` | Create Sunshine's web UI login / pair Moonlight |
| `steam-remote-setup` | *Steam Machine - Setup* | First-time setup; safe to re-run |
| `steam-remote-setup displays` | `steam-remote-setup.ps1 displays` | Choose the stream and TV outputs again |
| `steam-remote-setup remote` | `steam-remote-setup.ps1 remote` | Remote access on or off, or change VPN addresses |
| `steam-remote-setup remote off` | `steam-remote-setup.ps1 remote off` | Remote access off for every PC |
| `steam-remote-setup ssh-config` | (none) | Rewrite this project's block in `~/.ssh/config`. The installer does this when updating |
| `steam-remote-setup auth` | `steam-remote-setup.ps1 auth` | What a login needs: key and password (default), or key only ([security.md](security.md#key-only-logins)) |
| `steam-remote-setup quality` | `steam-remote-setup.ps1 quality` | Stream resolution, frame rate, bitrate, codec, HDR and the encoder preset ([quality.md](quality.md)) |
| `steam-remote-setup check` | `steam-remote-setup.ps1 check` | Report problems on the Steam Machine |
| `steam-remote-setup update-server` | `steam-remote-setup.ps1 update-server` | Send this version's server script and apply it |
| `steam-remote-setup add-client IP KEY.pub` | `steam-remote-setup.ps1 add-client IP KEY.pub` | Allow another PC |
| `steam-remote-setup remove-client IP` | `steam-remote-setup.ps1 remove-client IP` | Stop allowing a PC |
| `steam-remote-setup uninstall-server` | `steam-remote-setup.ps1 uninstall-server` | Remove everything from the Steam Machine |

Every Linux and macOS command has `--help` and `--version`.

## On the Steam Machine

Everything this project needs lives in **`/home/.steam-remote`** (owned by root). `/home` survives SteamOS updates. The files under `/etc` are generated from it, so they can always be rebuilt.

| Path | What it is |
| --- | --- |
| `/home/.steam-remote/steam-remote-server.sh` | The server script. It installs, repairs, checks and uninstalls everything below |
| `/home/.steam-remote/config` | Steam Machine settings (see below) |
| `/home/.steam-remote/sunshine-backup/` | A copy of Sunshine's settings, login and pairing (root-only), restored if an update resets `/root`. Delete it too if you want to reset Sunshine |
| `/etc/ssh/sshd_config.d/10-steam-remote.conf` | SSH lockdown (follows `AUTH_MODE`) |
| `/etc/ssh/sshd_config` | Gets an `Include /etc/ssh/sshd_config.d/*.conf` line at the top if missing |
| `/etc/steam-remote-guard.nft` | Firewall rules (nftables table `inet steam_remote`) |
| `/etc/sudoers.d/zz-steam-remote` | The narrow sudo rule |
| `/etc/systemd/system/sshd.service.d/10-steam-remote.conf` | Makes SteamOS's SSH service require the firewall, and refuse to start unless the lockdown is in effect |
| `/etc/atomic-update.conf.d/steam-remote.conf` | Adds the lockdown, firewall rules, sudo rule and idle timer to SteamOS's update keep list |
| `/root/.var/app/dev.lizardbyte.app.Sunshine/config/sunshine/` | Sunshine's own config, web UI login and paired devices |
| `/var/lib/sunshine-bwrap/bwrap` | Root-only setuid copy of bubblewrap for KMS capture, recreated at each start |
| NetworkManager wired connections | `802-3-ethernet.wake-on-lan magic` |

### Services (`/etc/systemd/system/`)

| Unit | Enabled at boot | What it does |
| --- | --- | --- |
| `steam-remote-heal.service` | yes | Runs `steam-remote-server.sh --apply` before sshd and the firewall start. It restores anything an update removed |
| `steam-remote-guard.service` | yes | Loads the firewall |
| `steam-remote-display.service` | yes | Starts on the TV: turns the stream output off before the display manager starts |
| `steam-remote-idle.timer` / `.service` | yes (unless `IDLE_MINUTES=0`) | Every 5 minutes: if Sunshine runs and no stream traffic arrived for `IDLE_MINUTES`, stops it and switches back to the TV |
| `steam-remote-sunshine.service` | **no** (on demand) | Sunshine itself, as root with KMS capture. Started and stopped by the client scripts. When it stops, it undoes the Game Mode capture fix (`--composite off`, run as your user) |

### `steam-remote-server.sh`

| Command | Needs sudo | What it does |
| --- | --- | --- |
| `--setup [--client-ip IP] [--pubkey FILE]` | yes | Interactive first-time setup (the PC's setup runs this) |
| *(no option)* / `--apply` | yes | Check and repair everything; write only what's missing or different |
| `--check` | no | Report what's missing or wrong; exit code 1 if anything is |
| `--outputs` | no | List display outputs with status, mode and device name |
| `--displays` | yes | Choose the stream and TV outputs again |
| `--add-client IP [--pubkey FILE]` | yes | Allow another PC (and authorise its key) |
| `--remove-client IP` | yes | Stop allowing a PC (refuses to remove the last one) |
| `--remote-add ADDRESS` / `--remote-remove ADDRESS` | yes | Allow or stop allowing a PC's VPN address (can be repeated) |
| `--set-remote "ADDRESSES"` / `--set-remote off` | yes | Replace the whole remote list; `off` turns remote access off for every PC |
| `--set-encoder quality\|balanced\|speed\|auto` | yes | Set the encoder preset (`ENCODER_QUALITY`) and apply it |
| `--set-auth key+password\|key` | yes | Set what an SSH login needs (`AUTH_MODE`) and apply it |
| `--auth-mode` | no | Print the login mode: `key+password` or `key` |
| `--stream-info` | no | The stream check: what the stream output offers, Game Mode's HDR state, the encoder, and whether HDR can work |
| `--stream-watch [SECONDS]` | no | Wait (default 300 seconds) for a stream to start, then say whether it's SDR or HDR |
| `--composite on\|off` | no | Turn the Game Mode capture fix on, or put back what was there before. Does nothing in Desktop Mode |
| `--uninstall [--keep-sunshine] [--keep-ssh]` | yes | Remove everything; by default also uninstalls Sunshine and turns SSH off |
| `--boot-display` | yes | Switch to the TV now (what the boot service runs) |
| `--idle-check` | yes | One idle-timer check |
| `--backup-sunshine` | yes | Back up Sunshine's data now (runs after every Sunshine stop) |
| `--wol-state` | no | Print `magic` if a wired card has magic-packet wake on |
| `--version`, `--help` | no | |

### Steam Machine settings: `/home/.steam-remote/config`

| Setting | Default | Meaning |
| --- | --- | --- |
| `USER_NAME` | `deck` | The account you log in as |
| `ALLOWED_IPS` | (set by setup) | Space-separated home addresses of the PCs allowed in |
| `REMOTE_IPS` | empty (off) | Space-separated VPN addresses of PCs allowed in from outside your home. Private addresses or ranges of /24 or smaller, or single 100.64-127.x.x addresses; public addresses are refused |
| `STREAM_OUTPUT` | (chosen in setup) | Output Sunshine streams from, e.g. `card0-HDMI-A-1`. Empty = no switching |
| `TV_OUTPUT` | (chosen in setup) | Output with the TV, turned off while streaming. Empty = no switching |
| `IDLE_MINUTES` | `60` | Stop Sunshine after this long with no stream traffic. `0` = never |
| `SUNSHINE_NAME` | `steam-machine` | Name shown in Moonlight |
| `WAKE_ON_LAN` | `yes` | Keep magic-packet Wake-on-LAN on for wired connections |
| `AUTH_MODE` | `key+password` | What an SSH login needs: `key+password`, or `key` (the SSH key only). Anything else counts as `key+password`. See [security.md](security.md#key-only-logins) |
| `ENCODER_QUALITY` | `quality` | The video encoder's preset: `quality`, `balanced`, `speed` or `auto` (the driver's default). Needs Sunshine 2026.906 or later. See [quality.md](quality.md#the-encoder-preset) |

Values are parsed and validated, never run as code. After editing, apply with `sudo /home/.steam-remote/steam-remote-server.sh`. A fully commented example is in [server/config.example](../server/config.example).

## On a Linux PC or a Mac

| Path | What it is |
| --- | --- |
| `~/.local/bin/steam-connect`, `steam-ssh`, `steam-wake`, `steam-pair`, `steam-remote-setup` | The commands |
| `~/.local/share/steam-remote/lib.sh` | Code shared by the commands |
| `~/.local/share/steam-remote/server/steam-remote-server.sh` | The server script that setup sends to the Steam Machine |
| `~/.local/share/applications/steam-remote-*.desktop` | App-menu launchers (Linux) |
| `~/Applications/Steam Machine - Connect.command`, `... - SSH.command` | Double-click launchers (macOS) |
| `~/.local/share/icons/hicolor/scalable/apps/steam-remote-*.svg` | Their icons (Linux) |
| `~/.config/steam-remote/config` | This PC's settings (`0600`) |
| `~/.config/steam-remote/mac` | The Steam Machine's learned MAC address |
| `~/.local/state/steam-remote/disconnect.log` | Output of disconnects done after the window was closed |
| `~/.local/state/steam-remote/moonlight.log` | Moonlight's messages from the last stream `steam-connect` started |
| `~/.ssh/steam-machine_ed25519` (+ `.pub`) | The SSH key (default name) |
| `~/.ssh/config` | The `Host steam-machine` block between `# >>> steam-machine-remote >>>` markers, with a `Match ... exec` line that runs `steam-wake --ssh` so plain `ssh` and `scp` wake the Steam Machine |
| `~/.ssh/cm-steam-machine` | The shared-login socket, while connected |

## On a Windows PC

| Path | What it is |
| --- | --- |
| `%LOCALAPPDATA%\steam-remote\*.ps1` | The commands, plus `common.ps1` |
| `%LOCALAPPDATA%\steam-remote\server\steam-remote-server.sh` | The server script that setup sends to the Steam Machine |
| `%LOCALAPPDATA%\steam-remote\icons\*.ico` | Shortcut icons |
| Start menu > *Steam Machine Remote* | Connect, Connect (no stream), SSH, Setup |
| Desktop | *Steam Machine - Connect*, *Steam Machine - SSH* |
| User `PATH` | Includes `%LOCALAPPDATA%\steam-remote` |
| `%APPDATA%\steam-remote\config` | This PC's settings |
| `%APPDATA%\steam-remote\mac` | The Steam Machine's learned MAC address |
| `%USERPROFILE%\.ssh\steam-machine_ed25519` (+ `.pub`) | The SSH key (default name) |
| `%USERPROFILE%\.ssh\config` | The `Host steam-machine` block between markers |

## PC settings: `config`

| Setting | Default | Meaning |
| --- | --- | --- |
| `MACHINE_IP` | (required) | The Steam Machine's fixed home IP |
| `REMOTE_MODE` | `off` | `off`, `router`, `tailscale` or `other`; set by `steam-remote-setup remote` |
| `REMOTE_PC_IP` | empty | This PC's address on the VPN |
| `REMOTE_MACHINE_IP` | empty | The Steam Machine's VPN address, if it has its own (Tailscale). Tried when `MACHINE_IP` doesn't answer |
| `MACHINE_USER` | `deck` | The account on the Steam Machine |
| `HOST_ALIAS` | `steam-machine` | Its name in your SSH config |
| `KEY_FILE` | `~/.ssh/steam-machine_ed25519` | The SSH key |
| `MACHINE_MAC` | (learned) | Override the MAC for Wake-on-LAN |
| `BROADCAST` | `x.y.z.255` | Where wake packets go. Set it if your network isn't a /24 |
| `WAKE_TIMEOUT` | `90` | Seconds to wait for it to wake |
| `MOONLIGHT_APP` | `Desktop` | The Sunshine app Moonlight opens |
| `CLIENT_NAME` | computer name | This PC's name in Sunshine's paired list |
| `WEBUI_PORT` | `47990` | Local port for the web UI tunnel |
| `PERSIST` | `2h` | Linux: the shared login closes after this long unused |
| `KEEPALIVE` | `600` | Linux: seconds between keep-alive checks while connected |
| `BLACK_SCREEN_FIX` | `yes` | The Game Mode capture fix while streaming: avoids a black stream, missing menus and wrong HDR colours. Keep it on |
| `STREAM_RESOLUTION` | empty | Passed to Moonlight, e.g. `3840x2160`. Empty = Moonlight's own setting |
| `STREAM_FPS` | empty | Passed to Moonlight, e.g. `60` or `120` |
| `STREAM_BITRATE` | empty | Bitrate in Mbps at home |
| `STREAM_BITRATE_AWAY` | `20` | Bitrate in Mbps when connected through the VPN. Empty = same as at home |
| `STREAM_CODEC` | empty | `auto`, `HEVC`, `AV1` or `H.264` |
| `STREAM_HDR` | empty | `yes` or `no`. Empty = Moonlight's own **Enable HDR** |

A fully commented example is in [config.example](../config.example).

## Ports

| Port | Protocol | Used by | Reachable from |
| --- | --- | --- | --- |
| 22 | TCP | SSH | Allowed PCs (home and VPN addresses) |
| 47984, 47989, 48010 | TCP | Sunshine (HTTPS, HTTP, RTSP) | Allowed PCs |
| 47998-48000, 48002, 48010 | UDP | Sunshine (video, control, audio, mic) | Allowed PCs |
| 47990 | TCP | Sunshine web UI | The Steam Machine only, through the SSH tunnel |
| 9 | UDP (broadcast) | Wake-on-LAN, from the PC | Your local network |

Sunshine's `port` setting must stay at its default (47989). The firewall rules expect these ports.

## What happens when you connect

1. **Find and wake:** ping the home address, then the VPN address (if set). If neither answers and this PC is at home, send a magic packet to the learned MAC and wait for ping and SSH. Away from home, stop with an explanation, because wake packets can't cross a VPN.
2. **Log in:** one SSH login (key + password) with a tunnel from `localhost:WEBUI_PORT` to the web UI.
3. **Check:** run `steam-remote-server.sh --check`. If anything is missing, show it and repair it with sudo (password).
4. **Switch:** read `STREAM_OUTPUT` and `TV_OUTPUT` from the Steam Machine's config. If both are set, turn the TV output off and the stream output on.
5. **Start Sunshine,** wait for it to answer, and check it can see a screen.
6. **Black-screen workaround,** if enabled.
7. **Moonlight:** `moonlight stream STEAM_MACHINE_IP Desktop`.
8. **Wait** for Q, Ctrl+C or the window closing, then undo 7, 6, 5 and 4 and close the login.
