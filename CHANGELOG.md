# Changelog

## 1.0.0 - 2026-10-27

First public release.

- Installers for Linux (Arch and Debian based) and Windows 10/11
- `steam-remote-setup` sets up both the PC and the Steam Machine, including picking which display output is the dummy plug and which is the TV
- `steam-connect` stays open while you stream and cleans up when you press Q or close the window
- `steam-ssh`, and `steam-pair` for setting the web UI login and pairing Moonlight from the terminal
- Steam Machine side: SSH and firewall locked to your PC(s), Sunshine on demand, Wake-on-LAN, idle timer, pairing backup, and a boot service that repairs things after SteamOS updates
- More than one PC can be allowed (`add-client` / `remove-client`)
- Optional remote access through a VPN (router VPN, Tailscale or another), off by default (`steam-remote-setup remote`)
