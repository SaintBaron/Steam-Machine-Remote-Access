# Steam Machine Remote Access

Stream your Steam Machine to your PC with [Sunshine](https://github.com/LizardByte/Sunshine) and [Moonlight](https://moonlight-stream.org), and open a terminal on it over SSH, without opening it up to the rest of your network.

One command or shortcut wakes the Steam Machine, logs in, moves the picture onto a dummy plug, starts Sunshine and opens Moonlight. Press Q (or close the window) and it puts the picture back on your TV and shuts Sunshine down.

## Get started

**1. Pick your PC's operating system and follow that guide from the top:**

| Your PC | Guide |
| --- | --- |
| Arch Linux, CachyOS, Manjaro, EndeavourOS | [Arch guide](docs/arch.md) |
| Debian, Ubuntu, Linux Mint, Pop!_OS | [Debian/Ubuntu guide](docs/debian.md) |
| macOS 12 Monterey or later | [macOS guide](docs/macos.md) |
| Windows 10 or 11 | [Windows guide](docs/windows.md) |

**2. Pick how you'll connect:**

| You want to stream... | Do this |
| --- | --- |
| **At home only** (most people) | Just follow your guide. At the setup's remote-access question, press Enter. |
| **At home and when you're away** | Follow your guide, then [set up remote access](docs/remote-access.md). This needs a VPN, such as your router's own or Tailscale. |

Each guide takes 30 to 45 minutes, including about 10 minutes at the Steam Machine with a keyboard.

## What it does

- Sunshine only runs while you're connected, and stops itself if you forget.
- It streams from a dummy plug (HDMI or DisplayPort) so the TV can stay off, then gives the TV its picture back.
- It wakes the Steam Machine from sleep when you connect at home (Wake-on-LAN).
- It repairs itself after SteamOS updates.
- Optionally, you can connect from anywhere through a VPN. Nothing is ever port-forwarded.
- Works in Game Mode and Desktop Mode, including HDR.

## Is it safe?

- Only your PC can connect. Every other device on your network is blocked by a firewall on the Steam Machine.
- Every login needs your SSH key **and** the Steam Machine's password. Root logins are off.
- Streams are encrypted and only go to Moonlight on devices you've paired.
- Nothing is reachable from the internet. Remote access only works through a VPN you control.

The details and trade-offs are in [docs/security.md](docs/security.md).

## Help and reference

- [Displays and dummy plugs](docs/displays.md): which plugs and adapters work, and how the switching works
- [Remote access](docs/remote-access.md): streaming from outside your home
- [Troubleshooting](docs/troubleshooting.md)
- [Security](docs/security.md)
- [Reference](docs/reference.md): every command, file and setting
- [Uninstalling](docs/uninstall.md)

## Licence

[MIT](LICENSE). This is a personal project, not affiliated with Valve, LizardByte (Sunshine) or the Moonlight project. It changes your Steam Machine's SSH, firewall and sudo settings, so read [docs/security.md](docs/security.md) first. There's no warranty.
