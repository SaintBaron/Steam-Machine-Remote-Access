# Security model

What this project protects against, how, and the trade-offs it makes.

## Goals

- Only **your PC(s)** can log in to the Steam Machine or stream from it.
- Every login needs **two things**: your SSH key (protected by its passphrase) **and** the Steam Machine's password.
- Sunshine runs **only while you're using it**, streams only to **paired** devices, and always **encrypts**.
- Nothing is reachable **from the internet**.
- The setup **survives SteamOS updates** without leaving gaps.

## What it doesn't protect against

- **Access straight from the internet.** Nothing is port-forwarded, and public addresses are refused. Remote access is only possible through a VPN you control (see [remote-access.md](remote-access.md)).
- **Someone with physical access** to the Steam Machine. They can use it directly.
- **A compromised PC.** Anything running as your user on an allowed PC can do what you can, including using an open SSH login or capturing what you type.

## The layers

### 1. Router

Nothing is forwarded to the Steam Machine. Sunshine's own UPnP is turned off (`upnp = disabled`), so it never asks the router to open ports. Router UPnP can stay on for your games.

### 2. Firewall on the Steam Machine (`steam-remote-guard.service`)

An nftables table, `inet steam_remote`, added on top of SteamOS's own firewalld:

| Rule | Effect |
| --- | --- |
| TCP 47990 dropped (except from the Steam Machine itself) | Sunshine's web UI is never on the network; you reach it through the SSH tunnel |
| SSH (22) and Sunshine's ports (TCP 47984, 47989, 48010; UDP 47998-48000, 48002, 48010) dropped unless from `ALLOWED_IPS` | Other devices can't log in or stream |
| The same ports over IPv6 dropped | No IPv6 way around the rules |
| Outbound SSH dropped unless to `ALLOWED_IPS` | The Steam Machine can't be used to SSH elsewhere |
| A packet counter on Sunshine's stream ports | Lets the idle timer tell whether anyone is streaming |

Sunshine's service has `Requires=steam-remote-guard.service`, so it won't start if the firewall can't load.

An IP address can be faked on a local network. The firewall cuts out noise and casual attempts. The real checks are layers 3 and 4.

### 3. SSH (`/etc/ssh/sshd_config.d/10-steam-remote.conf`)

```
PermitRootLogin no
AddressFamily inet
AllowUsers deck@<each allowed PC>
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
```

- `AuthenticationMethods publickey,password` means a stolen key alone isn't enough, and a guessed password alone isn't enough.
- SteamOS locks the account for 10 minutes after 3 wrong passwords (pam_faillock), which slows guessing.
- `AllowUsers` repeats the IP restriction inside SSH itself.
- Port forwarding is limited to the one tunnel the scripts use (to the web UI). A login can't be used to reach anything else through the Steam Machine, and agent forwarding is off. If you want your own tunnels, add a `PermitOpen` line in a separate file such as `/etc/ssh/sshd_config.d/20-my-tunnels.conf`. Files are read in name order and the first value wins, so put the line in a file that sorts *before* `10-steam-remote.conf` if you want it to replace the default, e.g. `05-my-tunnels.conf`.
- Dead connections are dropped after about 2 minutes (`ClientAlive*`). On Windows, this is what triggers the clean-up if the PC crashes or the network drops.

### 4. Sunshine

- **Pairing.** Moonlight must be paired with a PIN, entered through the web UI, which is only reachable over SSH. After pairing, each side checks the other's certificate.
- **Encryption required** for LAN and WAN streams (`lan_encryption_mode = 2`, `wan_encryption_mode = 2`). By default, Sunshine sends LAN video unencrypted.
- **On demand.** The service has no `[Install]` section, so it never starts at boot. The idle timer stops it if no stream traffic arrives for `IDLE_MINUTES`.
- **Web UI origin** restricted to the PC (`origin_web_ui_allowed = pc`), so only the Steam Machine itself, which means the tunnel, can use it.
- These settings (plus `upnp = disabled` and `address_family = ipv4`) are put back at every boot and every repair, even if they're changed in Sunshine's web UI. Other Sunshine settings are left alone.

### 5. Sudo (`/etc/sudoers.d/zz-steam-remote`)

The scripts need a few root actions without a password prompt. The rule allows exactly these, and nothing else:

```
deck ALL=(root) NOPASSWD: /usr/bin/systemctl start steam-remote-sunshine.service,
                          /usr/bin/systemctl stop steam-remote-sunshine.service,
                          /usr/bin/systemctl restart steam-remote-sunshine.service,
                          /usr/bin/tee /sys/class/drm/<stream output>/status,
                          /usr/bin/tee /sys/class/drm/<TV output>/status
```

The file is named `zz-...` so it sorts last: sudo applies the **last** matching rule, so an earlier rule can't override it. It's validated with `visudo` before it's installed.

The worst case if someone abuses these, from an already-logged-in session: they can start or stop streaming, or turn either of two display outputs off or on.

## Other notes

### Sunshine runs as root

Sunshine captures the screen with KMS, which needs `CAP_SYS_ADMIN`. Running the Flatpak as root keeps that capability, and Flatpak's sandbox still applies. To keep it inside the sandbox, the service uses a **setuid copy of bubblewrap** (`/var/lib/sunshine-bwrap/bwrap`) in a folder only root can enter (`0700`). It's recreated from SteamOS's own `/usr/bin/bwrap` every time Sunshine starts, so it stays up to date. Other users can't run it.

### The shared login (Linux)

`steam-connect` keeps one SSH login open and shares it through a socket at `~/.ssh/cm-steam-machine`. While it's open, any program running as **your user** on the PC can use it without credentials. That's no worse than what such a program could already do (read your keystrokes, for example). Other users can't reach it: `~/.ssh` is private. The login closes when you disconnect, and on its own after `PERSIST` (2 hours) unused if `steam-connect` is killed. Windows doesn't share logins.

### The web UI certificate

Sunshine's web UI uses a self-signed certificate. `steam-pair` accepts it only for `localhost`, which is your end of the SSH tunnel. Before sending the web UI password, `steam-pair` also checks that the tunnel is up and that the local port belongs to `ssh`, so another program listening on that port can't collect it.

### Passwords and logs

- No script takes a password as an argument, so passwords never appear in shell history or process lists.
- The Sunshine web UI password is typed at a hidden prompt and sent through the tunnel. It's not logged on either side.
- The configs hold no secrets: just IPs, output names and options. The PC config is still created as private (`0600`).

### The web UI tunnel on your PC

While `steam-connect` is open, Sunshine's web UI is reachable at `localhost:47990` on your PC. On a PC shared with other people, their programs could reach that address too, but they'd still need the Sunshine web UI login. Use a strong web UI password, and disconnect when you're done.

### The SSH key passphrase

The setup can't force a passphrase, but it warns if the key has none, because then anyone who copies the key file only needs the password. Add one any time with `ssh-keygen -p -f ~/.ssh/steam-machine_ed25519`.

### Sunshine and the audio socket

Sunshine runs as root but connects to the `deck` user's PipeWire/PulseAudio socket for sound. That's the only thing the root process takes from the user's session. The service grants root access to that socket with `setfacl -P`, which never follows symlinks.

### Remote access

Remote access is off by default. When you turn it on, the Steam Machine allows one more address per PC: its address on your VPN (`REMOTE_IPS`). It's added to the same firewall and SSH rules as the home addresses, and nothing else changes: still key + password, still a paired and encrypted stream. To keep that from widening by accident:

- **Public internet addresses are refused**, so the firewall can't be pointed at the internet. Only private addresses (`10.x`, `172.16-31.x`, `192.168.x`) are accepted, plus single `100.64-127.x.x` addresses (Tailscale and similar).
- **Ranges are limited** to `/24` or smaller, and Tailscale-style addresses must be single addresses, so a whole tailnet can't be allowed in one go.
- **Tailscale SSH must stay off.** Started with `--ssh`, Tailscale answers SSH on its own address with its own sign-in, bypassing the key + password lockdown. The guide's command leaves it out.
- **Router VPNs that translate addresses:** if the router presents VPN clients as its own home address, don't allow the router's address. That would let anything the router forwards through. Turn the translation off instead (see [remote-access.md](remote-access.md#option-a-your-routers-vpn)).
- **The VPN is now part of your security.** Anyone who can join it and use an allowed address can try to log in (they still need the key and password). Use strong VPN keys, and remove VPN clients you no longer use.

### Wake-on-LAN

Only **magic packet** wake is enabled (`wake-on-lan magic`), not "wake on any traffic". A magic packet is unauthenticated: anyone on your network who knows the MAC can wake the Steam Machine. They can't do anything else with it, because waking only turns it on.

### The self-heal service

`steam-remote-heal.service` runs `/home/.steam-remote/steam-remote-server.sh --apply` as root at every boot. The script, its folder and its config are owned by root and not writable by `deck`, so a compromised `deck` account can't change what runs as root. If you add files to `/home/.steam-remote` yourself, keep them root-owned.

The heal service also restores Sunshine's pairing and web UI login from its backup if they disappear. That means deleting Sunshine's files is **not** a way to reset them. To unpair a device, use the web UI's paired-devices list. To reset everything, delete the backup too:

```bash
sudo rm -rf /home/.steam-remote/sunshine-backup /root/.var/app/dev.lizardbyte.app.Sunshine/config/sunshine/sunshine_state.json
```

### After a SteamOS update

Since SteamOS 3.6, an update discards every change in `/etc` except the paths on SteamOS's keep list. The list includes systemd `.service` files, `.service.d` drop-ins and enable links, but not SSH config drop-ins, sudo rules or firewall files. So without help, an update would leave SSH switched on but without its lockdown: password-only logins from your network. Three layers stop that from happening:

1. **The protections stay put.** The setup adds its files to SteamOS's keep list, through `/etc/atomic-update.conf.d/steam-remote.conf`. This is SteamOS's own mechanism for keeping files through updates.
2. **SSH refuses to start without them.** A drop-in for SteamOS's SSH service (`/etc/systemd/system/sshd.service.d/10-steam-remote.conf`, kept by SteamOS's default list) makes SSH require the firewall. Before every start, it also checks that SSH's real, effective settings demand key **and** password from an allowed address. If anything is missing (the lockdown file, the line that loads it, or the firewall), SSH stays **off** rather than falling back to SteamOS's defaults.
3. **Anything lost is put back.** The heal service (kept by SteamOS's default list) runs at every boot, before SSH, and restores anything that's missing. `steam-connect` also checks on every connect.

If `/home/.steam-remote/config` is missing or invalid, the heal service doesn't loosen anything: SSH stays closed until the config is fixed at the Steam Machine's keyboard.

Layer 2 needs the drop-in itself to survive. It's on SteamOS's default keep list, so it does today. If Valve ever changed that list, layers 1 and 3 would still apply, and running `--check` after a big update shows straight away if anything is missing:

```bash
/home/.steam-remote/steam-remote-server.sh --check
```

### Setup trusts the Steam Machine account at that moment

During setup, the server script is copied into `deck`'s home and run with sudo. If something were already running as `deck` on the Steam Machine, it could tamper with that file, or with sudo itself, before you type the password. That's true of any sudo you run in a compromised account, so set up from a Steam Machine you trust (ideally a fresh one). After setup, everything that runs as root lives in the root-owned `/home/.steam-remote`.

### The one-line installers

The one-line install commands run whatever is on the `main` branch at that moment. To install a specific tagged release instead (once the repository has release tags), pass the tag:

```sh
curl -fsSL https://raw.githubusercontent.com/SaintBaron/Steam-Machine-Remote-Access/main/install.sh | bash -s -- --ref v1.0.0
```

```powershell
$env:STEAM_REMOTE_REF = 'v1.0.0'; irm https://raw.githubusercontent.com/SaintBaron/Steam-Machine-Remote-Access/main/install.ps1 | iex
```

If you'd rather read everything first, download or clone the repository, read the scripts, and run `bash install.sh` (or `install.ps1`) from your copy. It then installs from your copy without downloading anything.

## Host key fingerprint mismatch

During setup you compare the fingerprint SSH shows with the one you noted at the Steam Machine. If they **don't match**:

1. Type `no`. Don't connect.
2. Re-check at the Steam Machine: `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`.
3. Make sure you typed the right IP. The address may belong to another device, for example if the DHCP reservation isn't in effect yet. `ip -4 -br addr` at the Steam Machine shows its real IP.
4. If the IP is right and the fingerprint still differs, something on your network may be intercepting connections. Don't continue until you understand why.

## Checking it yourself

Part 6 of each guide has the tests: a port scan from your PC and from another device, the three refused logins, and the sudo and outbound-SSH checks. Re-run them after big changes, such as a new router or a major SteamOS update.

## Reporting a vulnerability

Please don't open a public issue for security problems. Use GitHub's **Report a vulnerability** button (the repository's *Security* tab), with steps to reproduce. Expect a reply within a week.
