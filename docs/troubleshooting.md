# Troubleshooting

Find the symptom, then follow the fix. Commands are shown for Linux. On Windows, use `steam-ssh.ps1` for `steam-ssh`, `steam-connect.ps1 -Restart` for `steam-connect restart`, and `steam-remote-setup.ps1` for `steam-remote-setup`.

**First, always:** run the setup again. It's safe to repeat, keeps what's done, and repairs most half-finished states:

```sh
steam-remote-setup
```

**Useful logs**, from your PC:

```sh
# Sunshine's log for this boot (the drm fb lines are noise)
steam-ssh "sudo journalctl -u steam-remote-sunshine.service -b --no-pager -o cat | grep -v 'get drm fb' | tail -n 40"
# What the self-heal service did at boot
steam-ssh "journalctl -u steam-remote-heal.service -b --no-pager -o cat"
# Is everything in place?
steam-ssh /home/.steam-remote/steam-remote-server.sh --check
```

## Contents

- [Locked out](#locked-out)
- [Login problems](#login-problems)
- [Wake-on-LAN](#wake-on-lan)
- [Remote access](#remote-access)
- [Setup problems](#setup-problems)
- [Sunshine and streaming](#sunshine-and-streaming)
- [Black picture](#black-picture)
- [Displays](#displays)
- [After a SteamOS update](#after-a-steamos-update)
- [macOS-specific](#macos-specific)
- [Windows-specific](#windows-specific)
- [Host key changed](#host-key-changed)

## Locked out

You can't SSH in at all, usually because this PC's IP changed or a setting went wrong. Fix it at the Steam Machine, in Desktop Mode, in Konsole.

1. See what's allowed:
   ```bash
   grep ALLOWED_IPS /home/.steam-remote/config
   ip -4 -br addr
   ```
2. **Your PC's IP changed?** Allow the new address. Find it on the PC with `ip -4 -br addr` (Windows: `ipconfig`).
   ```bash
   sudo /home/.steam-remote/steam-remote-server.sh --add-client NEW_PC_IP
   ```
   Then fix the DHCP reservation in your router so it doesn't change again.
3. **Something else?** See what's wrong, and let the setup repair it:
   ```bash
   /home/.steam-remote/steam-remote-server.sh --check
   systemctl status sshd.service steam-remote-guard.service --no-pager
   sudo /home/.steam-remote/steam-remote-server.sh
   ```
   SSH is built to stay **off** if its lockdown or the firewall is missing, so `sshd.service` failing to start usually means one of those is broken. The repair command fixes it.

Last resort: `sudo /home/.steam-remote/steam-remote-server.sh --uninstall --keep-sunshine` removes the lockdown (SSH is turned off). Then set it up again from your PC.

## Login problems

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Permission denied` with the right password | Keyboard layout differed when you set it (UK vs US symbols), or the 10-minute lockout after 3 wrong tries | Wait 10 minutes for the lockout to clear. If the password itself is the problem, set it again at the Steam Machine with `passwd`, using letters and numbers only |
| `Permission denied (publickey)` straight away | Wrong key, or the key isn't authorised | Check `IdentityFile` in your SSH config points to the key you set up. Re-run `steam-remote-setup` |
| `Connection closed by ... port 22` before any prompt | sshd is restarting, or too many logins are in progress at once | Wait a few seconds and try again. Close any SSH windows you don't need |
| `Connection timed out` / `No route to host` | Asleep, off, or the firewall drops this PC's IP (it's not in `ALLOWED_IPS`) | Wake it. If it's awake, this PC's IP probably changed: [Locked out](#locked-out) |
| Asked for the passphrase several times | The key passphrase was mistyped, or an agent offered the wrong key | Type carefully. Keep `IdentitiesOnly yes` in the SSH config block |
| Prompts seem to ignore your typing | Several SSH commands waiting on one terminal, or one paused with Ctrl+Z | Ctrl+C, then `steam-connect disconnect` (Linux) or close the terminal. Run one command at a time |
| `Address already in use` / `cannot listen to port: 47990` | An old connection still holds the web UI tunnel | Linux: `steam-connect disconnect`. Windows: close other Connect windows, or `Get-Process ssh \| Stop-Process` |
| `steam-connect is already running in another window` | Only one Connect at a time | Use the existing window, or close it |

## Wake-on-LAN

`steam-connect` says `Asleep or off: sending a Wake-on-LAN signal`, but nothing wakes.

1. **Was it asleep, or shut down?** Wake-on-LAN works from sleep. From shutdown it usually doesn't: press the power button.
2. **Is the Steam Machine on Ethernet?** Wi-Fi can't be woken.
3. **Check the Steam Machine's side**, while it's awake:
   ```sh
   steam-ssh "/home/.steam-remote/steam-remote-server.sh --check; /home/.steam-remote/steam-remote-server.sh --wol-state; grep . /sys/class/net/*/device/power/wakeup"
   ```
   You want no `WAKE-ON-LAN OFF` line, then `magic`, then `enabled` for the wired card (the one starting `en`). If not, run `steam-remote-setup update-server`, which applies Wake-on-LAN. If `--wol-state` prints nothing, the card doesn't report Wake-on-LAN support.
4. **Is the right MAC known?** It's learned on every successful connection. On Linux it's in `~/.config/steam-remote/mac`; on Windows in `%APPDATA%\steam-remote\mac`. It must be the **wired** card's MAC. Set `MACHINE_MAC` in your config to override it.
5. **Is the packet reaching it?** Both devices must be on the same network: no guest network, VLAN or AP isolation between them. If your network isn't a `/24` (for example `255.255.0.0`), set `BROADCAST` in your config to its broadcast address (Linux: `ip -4 addr` shows it after `brd`).
6. **Router or switch** "green Ethernet" or energy-saving features sometimes drop the link of a sleeping device. Try turning them off.

**Plain `ssh steam-machine` or `scp` says `No route to host` or times out, and doesn't try to wake it** (Linux and macOS): the `~/.ssh/config` block is from before 1.2.0, or you have your own `Host steam-machine` entry. Run `steam-remote-setup ssh-config`, or wake it first with `steam-wake`. On Windows, plain `ssh` never wakes it; use `steam-ssh.ps1`.

## Remote access

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Can't reach the Steam Machine. Away from home? Connect your VPN first.` | The VPN isn't connected, or the Steam Machine is asleep | Connect the VPN. Wake-on-LAN can't work through a VPN, so it has to be awake already |
| `Remote access is off` when away | This PC hasn't been given a VPN address | `steam-remote-setup remote` (do it at home, or connect the VPN first) |
| Ping works over the VPN but SSH times out | The VPN address isn't allowed, or the router translates VPN addresses | Check the allowed list with `steam-ssh grep _IPS= /home/.steam-remote/config` (at home). Compare it with this PC's VPN address; see [remote-access.md](remote-access.md#option-a-your-routers-vpn) about address translation |
| `'...' can't be used for remote access` | A public address, a range bigger than /24, or a Tailscale range | Use this PC's own address on the VPN |
| Tailscale: no reply from the `100.x` address | Tailscale isn't running on the Steam Machine (often after a SteamOS update) | At the Steam Machine: `tailscale status`. Re-run the community installer if needed ([remote-access.md](remote-access.md#option-b-tailscale)) |
| Moonlight shows the host as locked or unknown when away | Moonlight doesn't know the VPN address yet | In Moonlight, add the Steam Machine's VPN address with **+**. No need to pair again |
| Stutters or freezes away from home | Upload speed at home, or the VPN's packet size | Lower Moonlight's bitrate (10 to 20 Mbps). For WireGuard, try `MTU = 1380` in the client config |

## Setup problems

| Symptom | Cause | Fix |
| --- | --- | --- |
| `SSH doesn't answer` | sshd isn't running | At the Steam Machine: `sudo systemctl enable --now sshd` |
| `No reply from ...` during setup | Wrong IP, or the Steam Machine is asleep | Check its IP (guide, Part 2). The MAC isn't known yet during the first setup, so wake it by hand |
| `sudo: a password is required` during setup | You pressed Enter at the sudo prompt, or no password is set | Set one with `passwd` at the Steam Machine |
| `Sunshine didn't install` | No internet, or Flathub is unreachable | Check the Steam Machine's internet, then re-run the setup |
| `sshd rejected the config; moved ... aside` | An unexpected SteamOS sshd change | Report it (see [security.md](security.md#reporting-a-vulnerability)); SSH still works with SteamOS's defaults meanwhile |
| `the sudo rule failed validation` | An unexpected sudo change | Same as above |
| Setup shows the wrong PC IP under Allowed PCs | You connected through a VPN, or from a different network | Connect from the PC's normal network, or fix with `--remove-client` / `--add-client` |

## Sunshine and streaming

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Couldn't start Sunshine (sudo rule missing?)` | A SteamOS update removed the sudo rule and the self-heal didn't run yet | Connect again: it detects and repairs this. Or `steam-ssh sudo /home/.steam-remote/steam-remote-server.sh` |
| `Sunshine didn't answer within 30 seconds` | Sunshine crashed while starting | Read the log lines printed with it, then see the log rows below |
| Moonlight: `unable to connect to the specified PC` | Sunshine not started yet, or not paired | Wait 10 seconds and retry. Re-pair (guide, Part 5) if it shows a lock icon |
| Moonlight shows a lock icon on the host | This PC isn't paired (or the pairing data was lost) | Pair again (guide, Part 5) |
| Log: `bwrap: Can't find source path /run/user/1000/pulse/native` | Audio not reachable, usually nobody logged in on the Steam Machine yet | Let it reach Game Mode or Desktop Mode, then `steam-connect restart` |
| Log: `Failed to gain CAP_SYS_ADMIN` / `Flatpak do not support KMS capture` | The sandbox copy isn't in use | Re-apply: `steam-ssh sudo /home/.steam-remote/steam-remote-server.sh`. Check `FLATPAK_BWRAP` is in `systemctl cat steam-remote-sunshine.service` |
| Log: `Unable to find display or encoder` | No active output when Sunshine started | See [Displays](#displays) |
| Washed-out colours, or a stall when Game Mode switches HDR | HDR is on in Game Mode but off in Moonlight | Keep `MATCH_HDR="yes"` (the default) so they match, or turn on **Enable HDR** in Moonlight, and HDR for your monitor. More in [quality.md](quality.md#colours-look-wrong) |
| `streaming in SDR` when you wanted HDR | One link in the HDR chain is missing | The message says which side; follow [the HDR checklist](quality.md#hdr) |
| Soft or blurry picture | The Steam Machine's resolution on the dummy plug doesn't match Moonlight's, or the bitrate is low | [quality.md](quality.md#quick-checklist) |
| Stream check: `Encoder: software` | Sunshine couldn't use the graphics card's encoder | `steam-connect restart`. If it stays, update Sunshine (guide, *Updating*) and read its log: `steam-ssh journalctl -u steam-remote-sunshine.service -b --no-pager -o cat` |
| Stutter or blockiness | Bitrate too high for the network, or Wi-Fi | Lower the bitrate (`steam-remote-setup quality`, or Moonlight's settings); use Ethernet. [Moonlight's stats](quality.md#reading-moonlights-stats) show which |
| Web UI says `Unauthorized`, or its login page keeps coming back | Wrong username, or a browser quirk | The username is what you set with `steam-pair login` (default `sunshine`). Use `steam-pair` instead of the browser |
| Sunshine stops by itself mid-session | The idle timer saw no stream traffic for `IDLE_MINUTES` | Only happens with no stream running. Raise `IDLE_MINUTES` or set it to `0` (guide, *Changing things later*) |

## Black picture

The stream connects but shows black, and Sunshine's log fills with `Couldn't get drm fb for plane`.

This is a Sunshine problem in Game Mode (2026.906 and later, LizardByte/Sunshine #5839). `steam-connect` works around it with the Game Mode capture fix when `BLACK_SCREEN_FIX="yes"` (the default). If it's still black:

1. In Moonlight, quit the stream (Ctrl+Alt+Shift+Q) and click **Desktop** again.
2. Check the stream check says `capture fix on`. It only applies in Game Mode, so if the Steam Machine was still starting up, run `steam-connect restart`.
3. Update Sunshine (guide, *Updating*). In Desktop Mode, the problem doesn't happen.

Keep `BLACK_SCREEN_FIX="yes"` even once Sunshine fixes this: the same fix is what gets Steam's menus and correct HDR colours into the stream ([quality.md](quality.md#hdr)).

## Displays

| Symptom | Fix |
| --- | --- |
| `Sunshine is running but can't see a screen` | The stream output isn't active. Check the dummy plug is fully in, then `steam-connect restart`. Still failing: run `--outputs` and see [displays.md](displays.md#when-a-plug-isnt-detected) |
| The dummy plug shows `disconnected` | Usually a passive adapter on the DP socket. See [displays.md](displays.md#choosing-a-dummy-plug) |
| The TV stays dark after disconnecting | The disconnect didn't reach the Steam Machine (PC crash, network drop). Linux: `steam-connect disconnect`. Any PC: `steam-ssh sudo /home/.steam-remote/steam-remote-server.sh --boot-display`. Or wait for the idle timer, or reboot the Steam Machine |
| The wrong screen goes dark | Stream and TV outputs are swapped. Run `steam-remote-setup displays` |
| `NOTE output ... doesn't exist now` | An update renamed the outputs (e.g. `card0` to `card1`). Run `steam-remote-setup displays` |
| Low resolution or no HDR on the stream | The dummy plug's EDID doesn't offer it. The stream check's first line shows what it offers. See [displays.md](displays.md#hdr-and-4k) |

## After a SteamOS update

SteamOS updates discard most changes in `/etc`. This project's files are on SteamOS's keep list, the self-heal service restores anything missing at boot, and every connect checks too. If Connect says *Part of the Steam Machine setup is missing*, it lists what and repairs it after asking for the password.

If you can't connect at all after an update, SSH has probably stayed off on purpose because part of its lockdown was missing. At the Steam Machine's keyboard, run `sudo /home/.steam-remote/steam-remote-server.sh` to repair it.

If the self-heal service itself is gone and Connect can't repair it, run the setup again from your PC. The settings in `/home/.steam-remote/config` survive updates.

To see what was restored at the last boot:

```sh
steam-ssh "journalctl -u steam-remote-heal.service -b --no-pager -o cat"
```

## macOS-specific

| Symptom | Fix |
| --- | --- |
| `No route to host` or timeouts, though the Steam Machine is on | macOS 15+ blocks apps from your local network until you allow them: **System Settings > Privacy & Security > Local Network**, turn on Terminal (and Moonlight) |
| `python3` asks to install the Command Line Tools | Let it, or run `xcode-select --install`. Wake-on-LAN, `steam-pair` and the clean disconnect when you close the window need it |
| `steam-connect: command not found` | `echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zprofile && source ~/.zprofile` |
| Double-clicking a launcher says it can't be opened | Right-click it > **Open** once, or run `chmod +x ~/Applications/Steam*.command` |
| Moonlight doesn't open | It must be in `/Applications` or `~/Applications`. Connect with `steam-connect nostream` and open Moonlight by hand |

## Windows-specific

| Symptom | Fix |
| --- | --- |
| `running scripts is disabled on this system` | Use the shortcuts, or once: `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` |
| `The term 'steam-connect.ps1' is not recognized` | Open a **new** PowerShell window after installing (PATH is read at start), or use the full path `%LOCALAPPDATA%\steam-remote\steam-connect.ps1` |
| `ssh.exe` not found | Install the OpenSSH Client optional feature (guide, Part 3) |
| `Bad owner or permissions on .../.ssh/config` | In PowerShell: `icacls $HOME\.ssh\config /inheritance:r /grant:r "${env:USERNAME}:F"` |
| `UNPROTECTED PRIVATE KEY FILE` | `icacls $HOME\.ssh\steam-machine_ed25519 /inheritance:r /grant:r "${env:USERNAME}:F"` |
| Moonlight doesn't open | Check it's installed in the default place, or that `Moonlight.exe` is on your PATH. Connect with `-NoStream` and open Moonlight by hand |
| The connect window closes too fast to read | Use the Start menu shortcut (it pauses on errors), or run `steam-connect.ps1` from a PowerShell window |

## Host key changed

SSH prints `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!` and refuses to connect.

This is expected **only** if you reinstalled or reset SteamOS. Otherwise, stop and treat it as a possible impostor on your network.

If you did reinstall: at the Steam Machine, run `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` and note the fingerprint. On your PC, remove the old entry, then reconnect and compare:

```sh
ssh-keygen -R STEAM_MACHINE_IP
steam-remote-setup
```

A reinstall also wipes `/home`, so the setup runs from scratch. Do Part 2 of the guide again first.
