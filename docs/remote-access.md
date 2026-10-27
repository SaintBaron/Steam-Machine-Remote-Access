# Remote access: streaming from outside your home

**Do your OS guide first** ([Arch](arch.md), [Debian/Ubuntu](debian.md) or [Windows](windows.md)), then come back here.

Remote access works through a **VPN**, a private, encrypted link between your PC and your home. Nothing is opened to the internet, and every login still needs your key and password.

> [!IMPORTANT]
> Wake-on-LAN doesn't work from outside your home, so the Steam Machine must already be **awake** when you connect remotely. Turn off its sleep timer before you leave, or wake it with your router's app if the app has a Wake-on-LAN button.

## Pick your VPN

| Your situation | Use |
| --- | --- |
| Your router has a built-in VPN server (UniFi, ASUS, FRITZ!Box, OpenWrt, most mid-range routers and up) | [Option A: your router's VPN](#option-a-your-routers-vpn) (recommended: nothing to install on the Steam Machine) |
| Your router can't do VPN, or you already use Tailscale | [Option B: Tailscale](#option-b-tailscale) |
| You already run another VPN (ZeroTier, NetBird, a VPN on a NAS...) | [Option C: another VPN](#option-c-another-vpn) |

## Option A: your router's VPN

1. **Turn on the router's VPN server**, and choose WireGuard if it's offered:

   | Router | Where |
   | --- | --- |
   | UniFi | *Settings* > *VPN* > **VPN Server** |
   | ASUS | *VPN* > **VPN Server** |
   | FRITZ!Box | *Internet* > *Permit Access* > **VPN (WireGuard)** |
   | OpenWrt | Install `luci-proto-wireguard`, then *Network* > *Interfaces* > add a WireGuard interface |
   | TP-Link | Archer: *Advanced* > *VPN Server*; Omada: *VPN* > **WireGuard** |
   | Others | Look for *VPN Server* in the router's settings |

2. **Create a client for your PC** in the router's VPN settings and download its config file. On the PC, install the [WireGuard app](https://www.wireguard.com/install/) (or OpenVPN, if that's what the router uses) and import the file. On Linux, NetworkManager can import WireGuard `.conf` files too: *Settings* > *Network* > **+** > *Import from file*.
3. **Note your PC's VPN address.** It's the `Address` line in the config file, for example `Address = 10.6.0.2/32`. You need the part before the `/`, here `10.6.0.2`.
4. **Check the VPN reaches your home network.** Connect the VPN from outside your home (your phone's hotspot works), then ping the Steam Machine's normal home address. If there's no reply, make sure the client config's `AllowedIPs` line includes your home network (for example `192.168.0.0/24`), or is `0.0.0.0/0`.
5. **Tell the Steam Machine about it**, while you're at home. Run the command below, choose **2**, and enter the address from step 3.

   | Linux | Windows |
   | --- | --- |
   | `steam-remote-setup remote` | `steam-remote-setup.ps1 remote` |

6. **Try it.** Away from home, connect the VPN, then run `steam-connect` (Linux) or click **Steam Machine - Connect** (Windows).

If it connects over ping but SSH times out, your router may be presenting VPN clients as its own address. This setting is often called *NAT* or *masquerade* for VPN clients; turn it off in the router's VPN settings. Don't enter the router's own address in step 5: that would let every VPN client in.

## Option B: Tailscale

1. **On your PC:** install Tailscale from [tailscale.com/download](https://tailscale.com/download) and sign in.
2. **On the Steam Machine:** there's no official SteamOS package, so use Tailscale's community installer, [deck-tailscale](https://github.com/tailscale-dev/deck-tailscale). At the Steam Machine, in Konsole (Desktop Mode):

   ```bash
   git clone https://github.com/tailscale-dev/deck-tailscale.git ~/deck-tailscale
   sudo -i
   ```

   That opens a root shell. In it, run:

   ```bash
   cd ~deck/deck-tailscale
   bash tailscale.sh
   source /etc/profile.d/tailscale.sh
   tailscale up --qr --operator=deck
   exit
   ```

   Scan the QR code with your phone to sign in.

   > [!WARNING]
   > Don't add `--ssh` to `tailscale up`, even though the deck-tailscale readme does. Tailscale SSH would answer logins on the Tailscale address with Tailscale's own sign-in instead of your key and password, which bypasses this project's lockdown.

3. **Note both Tailscale addresses.** They start with `100.`. Run `tailscale ip -4` on each device, or check the *Machines* page in the [Tailscale admin console](https://login.tailscale.com/admin/machines).
4. **Tell the Steam Machine about it.** Run the command below, choose **3**, and enter both addresses. If Tailscale is running on the PC, its address is filled in for you.

   | Linux | Windows |
   | --- | --- |
   | `steam-remote-setup remote` | `steam-remote-setup.ps1 remote` |

5. **Try it.** Away from home, make sure Tailscale is connected, then run `steam-connect` (Linux) or click **Steam Machine - Connect** (Windows).

**After a SteamOS update**, check Tailscale is still running on the Steam Machine with `tailscale status`. If it isn't, run `cd ~/deck-tailscale && sudo bash tailscale.sh` again. This project's self-heal service can't repair Tailscale.

## Option C: another VPN

Run `steam-remote-setup remote` (Windows: `steam-remote-setup.ps1 remote`), choose **4**, and enter:

- **your PC's address on the VPN**: the address the Steam Machine will see;
- **the Steam Machine's address on the VPN**, if it has its own (like ZeroTier). Leave it empty if the VPN reaches your home network, like a router VPN does.

Only private addresses are accepted: `10.x.x.x`, `172.16-31.x.x` and `192.168.x.x` (single addresses, or ranges of `/24` or smaller), plus single `100.64-127.x.x` addresses. Public internet addresses are refused.

## Good to know

- **Bitrate:** home upload speeds are often low. Start Moonlight at 10 to 20 Mbps when away, and raise it until the stream stutters. Moonlight's stats overlay (Ctrl+Alt+Shift+S) shows what you're getting.
- **Moonlight shows the host as locked or unknown when away** (Tailscale): add the Steam Machine's Tailscale address in Moonlight with **+**. You don't need to pair again.
- **Stalls or black frames over WireGuard:** add `MTU = 1380` under `[Interface]` in the client config.
- **Turning it off:** run `steam-remote-setup remote` and choose 1 (this PC only), or `steam-remote-setup remote off` (every PC). On Windows, use `steam-remote-setup.ps1`.

<details>
<summary>How it works, and why there's no port-forwarding option</summary>

At home, your PC connects from its home address, which is the only address the Steam Machine accepts. On a VPN, the PC has a second address. Turning on remote access adds that one address to the Steam Machine's firewall and SSH rules. Other devices on the VPN are still refused. `steam-connect` tries the home address first, then the Steam Machine's VPN address if it has one.

Forwarding SSH and Sunshine's ports from your router to the Steam Machine would let anyone on the internet try to log in and probe Sunshine, which was never designed to face the internet. That's why public addresses are refused. A VPN gives the same result without exposing anything.

</details>
