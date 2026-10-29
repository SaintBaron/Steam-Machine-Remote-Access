# Setup guide: Arch Linux (and CachyOS, Manjaro, EndeavourOS)

This guide sets up [Steam Machine Remote Access](https://github.com/SaintBaron/Steam-Machine-Remote-Access) with this PC as the client. Other guides: [Debian/Ubuntu](debian.md), [macOS](macos.md), [Windows](windows.md).

When you finish, this PC can wake the Steam Machine, stream it in Moonlight and open a terminal on it, all from one command or shortcut. No other device on your network can log in to it or stream from it.

**Time:** 30 to 45 minutes. About 10 of those are at the Steam Machine with a keyboard.

**Home only, or remote too?** This guide sets up streaming on your home network. If you also want to connect from outside your home, finish this guide first, then follow [remote-access.md](remote-access.md).

## Contents

1. [Before you start](#before-you-start)
2. [Part 1: Fixed IPs in your router](#part-1-fixed-ips-in-your-router)
3. [Part 2: At the Steam Machine](#part-2-at-the-steam-machine)
4. [Part 3: Install on this PC](#part-3-install-on-this-pc)
5. [Part 4: Run the setup](#part-4-run-the-setup)
6. [Part 5: Pair Moonlight](#part-5-pair-moonlight)
7. [Part 6: First stream and checks](#part-6-first-stream-and-checks)
8. [After setup](#after-setup): day-to-day use, changing settings, updating, tips

## Before you start

### You need

- [ ] The Steam Machine, **wired** to your router with Ethernet, with a keyboard (USB or Bluetooth) for Part 2.
- [ ] This PC, on the same home network. Wired is best for streaming; Wi-Fi works but expect more lag.
- [ ] Admin access to your router (its web page or app).
- [ ] *Recommended:* a dummy plug (HDMI or DisplayPort EDID emulator) for the Steam Machine, so you can stream with the TV off. Read [displays.md](displays.md) before you buy one: on the Steam Machine's DisplayPort socket, **passive** DP-to-HDMI adapters and many DP dummy plugs don't work.
- [ ] A password manager or somewhere safe to keep two new secrets: the Steam Machine password and the SSH key passphrase.

### What you'll be asked for

You won't edit any files in this repository. The setup asks for everything and writes your settings for you. Have these ready, or create them as you go:

| You'll be asked for | Where it comes from | Used for |
| --- | --- | --- |
| The Steam Machine's IP address | Part 1 (you reserve it in your router) | Finding it on the network |
| This PC's IP address | Detected automatically. It must be the one you reserve in Part 1 | The firewall and SSH "allowed PCs" list |
| The Steam Machine's password | You set it in Part 2 | Every SSH login, and sudo |
| An SSH key passphrase | You choose it in Part 4 | Every SSH login (the second factor) |
| The host key fingerprint | You note it in Part 2 | Making sure you're talking to your Steam Machine |
| Which display output is the dummy plug, and which is the TV | You pick from a list in Part 4 | Switching the picture while you stream |
| A Sunshine web UI username and password | You choose them in Part 5 | Pairing, and Sunshine's settings page |
| Whether to allow remote access, through a VPN | Your choice in Part 4. Off by default; see [remote-access.md](remote-access.md) | Streaming from outside your home |

In commands, `STEAM_MACHINE_IP` is a placeholder: replace it with your Steam Machine's IP before running the command. Nothing else needs replacing.

### Conventions

- **Where to type:** Your terminal (Konsole, kitty, Alacritty...). The commands work in fish, bash and zsh unless a line says otherwise. CachyOS uses fish by default.
- **At the Steam Machine**, commands go in **Konsole**, in Desktop Mode. Paste with **Ctrl+Shift+V**.
- Run **one command at a time**, so password prompts don't pile up.
- Stop a running command with **Ctrl+C**, never Ctrl+Z (that only pauses it in the background, and paused SSH sessions cause confusing problems later).
- SSH password prompts don't echo anything while you type.

## Part 1: Fixed IPs in your router

The firewall and SSH allow your PC **by its IP address**, and the scripts find the Steam Machine by its IP. Both addresses must stay the same, so you reserve them in your router. This is called a *DHCP reservation*. Routers also call it a *static lease*, *address reservation*, *fixed IP* or *manual assignment*.

> [!WARNING]
> If this PC's IP ever changes, the Steam Machine refuses its connections. Fixing that needs the Steam Machine's keyboard (see [troubleshooting](troubleshooting.md#locked-out)). Do this part properly first.

### 1. Find each device's MAC address and current IP

**This PC:**

```sh
ip -4 -br addr show $(ip route show default | awk '{print $5; exit}')
ip -br link show $(ip route show default | awk '{print $5; exit}')
```

**The Steam Machine:** in Game Mode, open **Settings > Internet**, select the wired connection and look at its details. Or, in Desktop Mode, run `ip -4 -br addr` and `ip -br link` in Konsole. The wired connection is the one starting with `en` (such as `enp3s0`).

### 2. Reserve the addresses

In your router's admin page, find the list of connected devices or the DHCP settings, and reserve an address for each device's MAC. Where it usually is:

| Router | Where to look |
| --- | --- |
| UniFi | *Client Devices* > the device > *Settings* > **Fixed IP Address** |
| ASUS | *LAN* > *DHCP Server* > **Manual Assignment** |
| TP-Link | *Advanced* > *Network* > *DHCP Server* > **Address Reservation** |
| Netgear | *Advanced* > *Setup* > *LAN Setup* > **Address Reservation** |
| OpenWrt | *Network* > *DHCP and DNS* > **Static Leases** |
| ISP routers (BT, Sky, Virgin, Xfinity...) | Usually *Advanced* or *My network* > the device > **Always use this IP** / **IP reservation** |

Tips:

- Keeping each device's **current** address is simplest. If you pick new ones, choose addresses inside your network (the same first three numbers, like `192.168.0.x`) that nothing else uses.
- Reserve by the **wired** MAC address. Wi-Fi and Ethernet have different MACs.
- Some routers apply a reservation only when the device next reconnects. Reboot both devices (or unplug and replug the cable), then check the addresses with the commands above.

### 3. Check nothing is forwarded from the internet

In the router's **Port Forwarding** (or *Virtual Server*, *NAT*) page, delete anything that points to the Steam Machine. This project never needs port forwarding. (If you set up remote access with a VPN on your router later, the router opens a port for its own VPN server. That's different and fine: nothing is forwarded to the Steam Machine.)

**UPnP** can stay on if your games use it. Sunshine's UPnP is switched off by the setup, and the Steam Machine's firewall drops SSH and Sunshine traffic from anywhere but your PC anyway.

### 4. Same network, no isolation

Both devices must be on your **main** network: not a guest network, and with no "AP isolation" or "client isolation" between them. Otherwise Wake-on-LAN and even ping won't reach the Steam Machine.

## Part 2: At the Steam Machine

You only need to sit at the Steam Machine this once. Have the TV on and a keyboard connected.

### 1. Open a terminal

Press the **Steam** button > **Power** > **Switch to Desktop**. In Desktop Mode, open the app launcher (bottom left) > **System** > **Konsole**.

If the on-screen keyboard is in the way, plug in a USB keyboard. In Konsole, paste is **Ctrl+Shift+V**.

### 2. Set the password

SteamOS's `deck` account has no password at first. Set one now. It's used for every SSH login and for sudo:

```bash
passwd
```

- **Make it long** (a passphrase of four or five words works well) and save it in your password manager.
- **Watch the keyboard layout.** If this keyboard's layout differs from your PC's (UK vs US, say), symbols like `@ " # £ \` are on different keys, so the password you type here won't match what you type later. Stick to letters and numbers, or set the layout first in **System Settings > Keyboard**.
- If a password is already set, `passwd` asks for the current one first. Keep using it if it's strong.
- Three wrong passwords lock the account for 10 minutes (SteamOS's default). Type carefully later.

### 3. Turn on SSH and note its fingerprint

```bash
sudo systemctl enable --now sshd
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

The second line prints the Steam Machine's **host key fingerprint**, like `256 SHA256:AbC1...xYz root@... (ED25519)`. **Take a photo of it** or write down the `SHA256:...` part. When this PC first connects, you'll check it shows the same value. That proves you're talking to your Steam Machine and not an impostor on the network.

> [!WARNING]
> Until Part 4 finishes, SSH accepts the password alone, from any device on your network. Carry on to Part 4 the same day. If you have to stop for a while, run `sudo systemctl disable --now sshd` and turn it back on when you continue.

### 4. Check the wired address

```bash
ip -4 -br addr
```

Find the line for the wired connection (it starts with `en`). Its address should be the one you reserved in Part 1. That's your `STEAM_MACHINE_IP`. If it's different, reboot the Steam Machine so it picks up the reservation, and check again.

### 5. Plug in the dummy plug (if you have one)

Plug the dummy plug into the Steam Machine's free display output. Leave the TV connected to the other one. Then list the outputs:

```bash
for f in /sys/class/drm/card*-*/status; do echo "$(basename "$(dirname "$f")"): $(cat "$f")"; done
```

You should see two lines saying `connected`: the TV's output and the dummy plug's (for example `card0-DP-1: connected` and `card0-HDMI-A-1: connected`).

- **The dummy plug shows `disconnected`?** Your adapter or plug probably isn't compatible with that socket. This is common with **passive** DP-to-HDMI adapters and some DP dummy plugs. Read [displays.md](displays.md) before going further; the rest of the setup still works without a dummy plug.
- **No dummy plug?** That's fine. Sunshine will stream whatever the TV shows, so the TV must be on while you stream.

You don't need to remember which output is which. The setup shows this list again (with device names) and lets you choose.

### 6. Leave it running

The Steam Machine can stay in Desktop Mode or go back to Game Mode (**Return to Gaming Mode** on the desktop). Leave it **on and awake**. Its automatic sleep is fine later, once Wake-on-LAN is confirmed in Part 6.

Head back to your PC.

## Part 3: Install on this PC

### 1. Install

```sh
curl -fsSL https://raw.githubusercontent.com/SaintBaron/Steam-Machine-Remote-Access/main/install.sh | bash
```

<details>
<summary>Prefer to read the script before running it, or install from a clone?</summary>

```sh
curl -fsSLo /tmp/steam-remote-install.sh https://raw.githubusercontent.com/SaintBaron/Steam-Machine-Remote-Access/main/install.sh
less /tmp/steam-remote-install.sh
bash /tmp/steam-remote-install.sh
```

Or clone the repository and run the installer from it (it then uses your local copy, without downloading):

```sh
git clone https://github.com/SaintBaron/Steam-Machine-Remote-Access.git
cd Steam-Machine-Remote-Access
bash install.sh
```

To install a specific tagged release instead of the latest code, see [the one-line installers](security.md#the-one-line-installers).

</details>

What the installer does (run it as your normal user, not with sudo):

- installs any missing system packages after asking. That's this command, which you can also run yourself:
  ```sh
  sudo pacman -S --needed openssh python iproute2 iputils util-linux procps-ng coreutils gawk findutils flatpak curl
  ```
- offers to install **Moonlight** from Flathub (just for your user). Moonlight from the `moonlight-qt` package in the AUR also works; the scripts use whichever they find;
- puts the commands in `~/.local/bin`, shared files in `~/.local/share/steam-remote`, and **Steam Machine: Connect** and **Steam Machine: SSH** launchers in your app menu.

### 2. Check the commands are found

```sh
steam-connect --version
```

If the installer warns that `~/.local/bin` isn't on your PATH, fix it once:

```sh
# fish (CachyOS's default shell):
fish_add_path ~/.local/bin
# bash:
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc
# zsh:
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

### 3. Set up Moonlight for the best picture

Open Moonlight > **Settings** (gear icon):

| Setting | Value | Why |
| --- | --- | --- |
| Resolution / FPS | Your monitor's, e.g. 1440p 60 or 4K 60 | Match what you'll watch it on |
| Video bitrate | 60 to 150 Mbps (wired), 30 to 60 (Wi-Fi) | Higher is sharper, if the network keeps up |
| Video codec | HEVC (or AV1 if your GPU decodes it) | Better quality per Mbps |
| **Enable HDR** | On, if your monitor does HDR | Without it, HDR games look washed out. [The HDR checklist](quality.md#hdr) has the rest |

For HDR, HDR must also be on for your monitor in your desktop's display settings (KDE: *System Settings > Display & Monitor*; GNOME 48+: *Settings > Displays*).

You can also keep these in the project's own settings instead: the setup in Part 4 offers to (step 3), or run `steam-remote-setup quality` later. Then `steam-connect` hands them to Moonlight each time, and lowers the bitrate automatically when you're away from home. [quality.md](quality.md) explains every setting.

## Part 4: Run the setup

Make sure the Steam Machine is on and awake, then run `steam-remote-setup`.

The setup is safe to run again at any point. It keeps what's already done, and it's the fix for most "half set up" problems. Below is what each step asks for.

### Step 1: This PC's settings

It asks for the Steam Machine's IP (`STEAM_MACHINE_IP` from Part 2), its user name (press Enter for `deck`) and a short SSH name (press Enter for `steam-machine`). These are saved in `~/.config/steam-remote/config`. Every option is explained in [config.example](../config.example).

Then it shows the less common settings and asks whether to change them. Press Enter to keep them:

- **Moonlight app** (default `Desktop`, the whole screen): another Sunshine app if you've added one.
- **Game Mode capture fix** (default `yes`): keeps the stream from going black in Game Mode, and keeps Steam's menus and HDR colours right. Leave it on.
- **Wake wait** (default 90 seconds): how long Connect waits for the Steam Machine to wake.
- **Wake-on-LAN broadcast** (default automatic, the `.255` address): set it only if your home network is bigger than a `/24`.
- **Name in Sunshine** (default this computer's name): how this PC appears in Sunshine's paired-devices list.

### Step 2: Remote access (optional)

It asks whether this PC may also connect from **outside your home**, through a VPN:

```
     1) No, home network only            Nothing else to set up (default)
     2) Yes, through a VPN on my router  WireGuard or OpenVPN on the router, UniFi Teleport...
     3) Yes, through Tailscale           Tailscale on this PC and on the Steam Machine
     4) Yes, through another VPN         You enter the addresses yourself
```

If you're not sure, press Enter for **1**. You can change it any time with `steam-remote-setup remote`. Options 2 to 4 ask for this PC's address on the VPN (and, for Tailscale, the Steam Machine's). You can leave the addresses empty and add them later. [remote-access.md](remote-access.md) explains each option and how to set up the VPN. Nothing is ever opened to the internet directly.

### Step 3: Stream quality (optional)

It shows the stream settings that Connect hands to Moonlight on every connection. At first that's Moonlight's own settings, plus 20 Mbps when you connect through the VPN. Press Enter to keep them, or **y** to set the resolution, frame rate, bitrate, codec and HDR now. [quality.md](quality.md#stream-settings) suggests values. You can change them any time with `steam-remote-setup quality`.

### Step 4: SSH key and SSH config

It creates an SSH key at `~/.ssh/steam-machine_ed25519` and asks for a **passphrase**. Choose a good one and save it in your password manager: logins need this passphrase **and** the Steam Machine's password. If you already have a key there, it's reused.

It also adds a `Host steam-machine` block to the top of `~/.ssh/config`, between `# >>> steam-machine-remote >>>` markers. This is what makes `ssh steam-machine` work. Its `HostKeyAlias` line lets SSH recognise the Steam Machine at either its home or its VPN address. If you already had your own `Host steam-machine` entry, it's left alone and the setup tells you what it should contain.

### Steps 5 and 6: First connection

The first time, SSH shows a fingerprint and asks:

```
The authenticity of host '...' can't be established.
ED25519 key fingerprint is SHA256:AbC1...xYz.
Are you sure you want to continue connecting (yes/no/[fingerprint])?
```

**Compare the `SHA256:...` value with the one you noted in Part 2.** Type `yes` only if they match exactly. If they don't, type `no` and read [security.md](security.md#host-key-fingerprint-mismatch).

Then enter the Steam Machine's **password**. This copies the server script and your public key across.

### Step 7: Setting up the Steam Machine

It logs in again (password), then **sudo** asks for the same password once more. From here the Steam Machine's side runs (`steam-remote-server.sh --setup`):

1. **Allowed PCs.** Your PC's home IP is detected from the connection and shown. Check it's the address you reserved in Part 1. If you chose remote access, the VPN address is shown on the next line.
2. **Display outputs.** You'll see a table like this:

   ```
     #   Output                 Status        In use    Best mode   Device name (from its EDID)
     1   card0-DP-1             connected     enabled   3840x2160   SONY TV
     2   card0-HDMI-A-1         connected     disabled  1920x1080   -
     3   card0-DP-2             disconnected  disabled  -           -
   ```

   - **Stream output:** type the number of the **dummy plug**. It's usually the one that isn't your TV's name and is `connected` but not in use. Type **0** if you have no dummy plug.
   - **TV output:** type the number of the output your **TV or monitor** is on. It's turned off while you stream and back on when you disconnect. Type **0** if there's no TV.
   - Not sure? Unplug one of them, type **r** to refresh, and see which line changes. Plug it back in afterwards.
   - Switching only happens when both are set. Change them any time with `steam-remote-setup displays`. [displays.md](displays.md) explains the options.
3. **Options.** Press Enter to keep each default:
   - **Idle stop** (default 60 minutes): if a PC forgets to disconnect, Sunshine is stopped after this long with nobody streaming. 0 turns it off.
   - **Wake-on-LAN** (default on): lets Connect wake the Steam Machine from sleep.
   - **Name** (default `steam-machine`): what Moonlight shows.
   - **Encoder preset** (default `quality`): the sharpest picture. Choose `balanced` if you'll stream 4K at 120 FPS, `speed` for the lowest delay, or `auto` for the graphics driver's default. See [quality.md](quality.md#the-encoder-preset).
   - **Login** (default `key+password`): every SSH login needs your key **and** the Steam Machine's password. `key` needs only the key, so one passphrase (or none, once your PC remembers it). Only choose `key` if your key has a strong passphrase. [security.md](security.md#key-only-logins) explains the trade-off; change it later with `steam-remote-setup auth`.

   Change them later by running the setup again, or the preset alone with `steam-remote-setup quality`.
4. **Sunshine** is installed from Flathub (system-wide) if it isn't already. This takes a few minutes the first time.
5. **Applying.** It writes the SSH lockdown, firewall, Sunshine service, sudo rule, boot and idle services, and Wake-on-LAN, and turns on the self-heal service. Each file it writes is listed.
6. **Checks.** You should see:

   ```
   ==> Checking
      permitrootlogin no
      allowusers deck@192.168.0.20
      authenticationmethods publickey,password
      firewall: active
   ==> Test-starting Sunshine (about 15 seconds)
      Sunshine: captured the screen OK
   ```

   During the Sunshine test, the TV goes dark for a few seconds if you set up switching.

> [!IMPORTANT]
> From now on, every SSH login needs **both** your key (passphrase) and the password, from this PC only (or just the key, if you chose `key`). Logins already open stay connected.

### Step 8: Check a fresh login

It opens one more connection the new way: key passphrase, then password. Then it prints `key and password accepted` (or `key accepted`, with key-only logins). If it does, the setup is done.

## Part 5: Pair Moonlight

Moonlight and Sunshine pair once, with a PIN. Sunshine's web UI is only reachable through the SSH connection, so the first window keeps that open.

1. **Window 1:** run `steam-connect nostream`. Enter your passphrase and password. Wait for `Connected. Press Q to disconnect`. **Leave it open.**
2. Open a **second** terminal and create Sunshine's **web UI login**. Press Enter for the username `sunshine`, then choose a password (at least 8 characters; save it in your password manager):

   ```sh
   steam-pair login
   ```

   It prints `Web UI login set`. This is only for Sunshine's settings page and pairing; it's not the Steam Machine's password.
3. **Pair:**

   ```sh
   steam-pair
   ```

   Log in with the web UI username and password. When it says so, open **Moonlight**, click **+** (top right), enter `STEAM_MACHINE_IP`, then click the new host. Moonlight shows a **4-digit PIN**. Type that PIN into the pairing window. It prints `Paired as '...'` and the host unlocks in Moonlight.
4. Go back to **window 1** and press **Q**.

**Prefer a browser?** While window 1 is open, go to `https://localhost:47990`. Your browser will warn about the certificate: Sunshine uses a self-signed one, and the connection is already protected by SSH, so it's safe to continue. Log in, open **PIN**, and enter Moonlight's PIN there. In some browsers the login page keeps reappearing; the commands above avoid that.

You pair once per PC. You'd only pair again after unpairing in the web UI or reinstalling Moonlight. Pairing data is backed up and restored automatically if a SteamOS update resets it.

## Part 6: First stream and checks

### Stream

Run `steam-connect` (or click **Steam Machine: Connect** in your app menu). It logs in, switches to the dummy plug (the TV goes dark), starts Sunshine and opens Moonlight on the **Desktop** app. Put the Steam Machine in **Game Mode** for the full experience.

Before Moonlight opens, a **Stream check** shows what the dummy plug offers and whether HDR is ready, for example:

```text
==> Stream check
    Stream output HDMI-A-1: up to 3840x2160 at 120 Hz, HDR10
    Game Mode: HDR on, capture fix on
    Encoder: vaapi, preset quality, AV1 available
    HDR: ready. Turn on Enable HDR in Moonlight to use it
```

When Moonlight connects, you'll see `Moonlight connected: streaming in HDR (10-bit)` or `... in SDR`, with what to change if HDR didn't happen. [quality.md](quality.md) explains each line.

- In Moonlight, **Ctrl+Alt+Shift+Q** quits the stream; **Ctrl+Alt+Shift+Z** releases the mouse and keyboard.
- To finish, press **Q** in the terminal. Sunshine stops and the TV gets its picture back. Closing the window or pressing **Ctrl+C** does the same.

### Test Wake-on-LAN

1. Close the Connect window, then put the Steam Machine to sleep: Steam button > **Power** > **Sleep**, or from here:

   ```sh
   ssh -t steam-machine 'sudo systemctl suspend'
   ```

   That terminal will stop responding as the Steam Machine goes to sleep. Close it.
2. Wait 30 seconds, then run `steam-connect`. You should see `Asleep or off: sending a Wake-on-LAN signal`, then `Awake`, within about 20 seconds.

If it doesn't wake, see [troubleshooting](troubleshooting.md#wake-on-lan). Once it works, you can let the Steam Machine sleep on its own timer. Wake-on-LAN works from **sleep**; from a full **shutdown** it usually doesn't.

<details>
<summary><b>Optional: prove the lock-down works</b></summary>

These prove the setup works. Run them with the Connect window open (Sunshine running).

**1. Ports.** Install nmap if you don't have it (`sudo pacman -S --needed nmap`), then:

```sh
sudo nmap -Pn -p 22,47984,47989,47990,48010 STEAM_MACHINE_IP
```

Expect 22, 47984, 47989 and 48010 **open**, and 47990 (the web UI) **filtered**. Run the same scan from any **other** device on your network (a laptop or a phone with a network scanner app): everything should be **filtered** there.

**2. SSH refuses the key alone, the password alone, and root.** Each should end in `Permission denied`. If one asks for a password, press Ctrl+C: that counts as refused.

```sh
ssh -o PreferredAuthentications=publickey steam-machine true
ssh -o PubkeyAuthentication=no steam-machine true
ssh -i ~/.ssh/steam-machine_ed25519 -o IdentitiesOnly=yes root@STEAM_MACHINE_IP true
```

**3. The Steam Machine's own limits:**

```sh
steam-ssh 'sudo -n true 2>/dev/null && echo "PROBLEM: passwordless sudo" || echo "OK: sudo needs a password"; timeout 5 bash -c "</dev/tcp/github.com/22" 2>/dev/null && echo "PROBLEM: outbound SSH open" || echo "OK: outbound SSH blocked"; /home/.steam-remote/steam-remote-server.sh --check'
```

You want `OK`, `OK` and `All present.`

</details>

## After setup

<details>
<summary><b>Day-to-day use</b></summary>

| Command | Launcher | What it does |
| --- | --- | --- |
| `steam-connect` | Steam Machine: Connect | Wake, log in, check the setup, switch to the dummy plug, start Sunshine, stream. Press **Q** to end. |
| `steam-connect restart` | | Same, but restarts Sunshine first (if it couldn't see a screen) |
| `steam-connect nostream` | | Everything except Moonlight: for pairing or the web UI |
| `steam-ssh` | Steam Machine: SSH | A terminal on the Steam Machine (wakes it first) |
| `steam-ssh <command>` | | Run one command there, e.g. `steam-ssh uptime` |
| `steam-pair login` / `steam-pair` | | Create or change the web UI login / pair Moonlight |
| `steam-connect disconnect` | | Clean up after a crash: stop Sunshine, back to the TV, close every SSH connection to the Steam Machine |
| `steam-remote-setup quality` | | Stream resolution, bitrate, codec, HDR and the encoder preset |
| `steam-remote-setup` | | First-time setup; safe to re-run |

**One login, shared.** `steam-connect` logs in once. While it's open, `steam-ssh` reuses that login, so there are no prompts. Pressing **Q** stops Sunshine and closes the web UI tunnel. The shared login itself stays until the last `steam-ssh` shell using it exits, so your shells aren't cut off.

**If the window is closed instead,** a background copy of `steam-connect` does the disconnect and logs it to `~/.local/state/steam-remote/disconnect.log`. If the PC crashes, Sunshine keeps running until the Steam Machine's idle timer stops it (60 minutes by default) and switches back to the TV. Run `steam-connect disconnect` to do it straight away.

**Fewer passphrase prompts:** most desktops run an SSH agent. `ssh-add ~/.ssh/steam-machine_ed25519` remembers the passphrase until you log out. The Steam Machine's password is still asked every time; that's the second factor working. If you'd rather type one passphrase, see [key-only logins](security.md#key-only-logins).

**Sunshine never runs on its own.** It starts when you connect and stops when you disconnect. If you forget to disconnect, the Steam Machine stops it after 60 minutes with nobody streaming and switches back to the TV (change this with `IDLE_MINUTES`, see below).

**The TV and the stream can't both have a picture.** Game Mode uses one screen at a time, so while you're connected the TV is dark. Disconnect to get it back.

</details>

<details>
<summary><b>Changing things later</b></summary>

### Display outputs

Swapped ports, added a dummy plug, changed TV?

```sh
steam-remote-setup displays
```

It shows the outputs table again and asks for the stream and TV outputs. The sudo rule follows the new choice automatically.

### Login: key and password, or key only

```sh
steam-remote-setup auth
```

Key and password is the default. Key only means one passphrase to type, at the cost described in [security.md](security.md#key-only-logins). It refuses if your key has no passphrase.

### Picture quality

Resolution, frame rate, bitrate (at home and away), codec, HDR, and the Steam Machine's encoder preset:

```sh
steam-remote-setup quality
```

[quality.md](quality.md) explains each one, and how to get HDR working.

### Remote access

Turn streaming from outside your home on or off, or change the VPN addresses:

```sh
steam-remote-setup remote
```

`steam-remote-setup remote off` turns it off for every PC. [remote-access.md](remote-access.md) covers the options.

### This PC's settings

All of them are in `~/.config/steam-remote/config`, with comments. [config.example](../config.example) explains every option.

```sh
nano ~/.config/steam-remote/config
```

Useful ones: `MOONLIGHT_APP` (another Sunshine app instead of `Desktop`), `BROADCAST` (if your network isn't a `/24`, so Wake-on-LAN reaches it), `STREAM_*` (what `steam-remote-setup quality` sets). If you change `MACHINE_IP`, `MACHINE_USER` or `HOST_ALIAS`, run `steam-remote-setup` again.

### The Steam Machine's settings

They're in `/home/.steam-remote/config` on the Steam Machine (root-owned); [server/config.example](../server/config.example) explains every option. Edit and apply:

```sh
steam-ssh 'sudo nano /home/.steam-remote/config && sudo /home/.steam-remote/steam-remote-server.sh'
```

Useful ones: `IDLE_MINUTES` (0 turns the idle timer off), `SUNSHINE_NAME` (the name Moonlight shows), `WAKE_ON_LAN`, `ENCODER_QUALITY` (the encoder preset).

Be careful with `ALLOWED_IPS`. Removing this PC's address locks it out. The commands below are safer.

### Adding another PC

Each PC needs a **fixed IP** (Part 1) and its **own SSH key**. Logins are locked to known keys and addresses, so the new PC can't add itself; an existing PC adds it.

1. **On the new PC:** install as in Part 3, then create its key without running the full setup yet:
   - Linux or macOS: `ssh-keygen -t ed25519 -f ~/.ssh/steam-machine_ed25519`
   - Windows: `ssh-keygen -t ed25519 -f $HOME\.ssh\steam-machine_ed25519`

   (If that says the folder doesn't exist, create it first: `mkdir -p ~/.ssh` on Linux or macOS, `mkdir -Force $HOME\.ssh` on Windows.) Copy its **public** key (the `.pub` file) to this PC however you like: USB stick, email or chat. It's public, so it isn't secret.
2. **On this PC:**

   ```sh
   steam-remote-setup add-client 192.168.0.21 ~/other-pc.pub
   ```

   Use the new PC's fixed IP and the path to its `.pub` file.
3. **On the new PC:** run the setup. It finds the existing setup, confirms the fingerprint, and finishes with its own config.

Remove a PC with `steam-remote-setup remove-client IP`. Then delete its key line from `~/.ssh/authorized_keys` on the Steam Machine (`steam-ssh nano .ssh/authorized_keys`).

### This PC's IP changed

If your router gave this PC a new address, the Steam Machine won't accept it. From another allowed PC, run `steam-remote-setup add-client NEW_IP` followed by the path to a copy of this PC's public key (`~/.ssh/steam-machine_ed25519.pub` on this PC). With no other PC, see [troubleshooting](troubleshooting.md#locked-out). Then fix the reservation in your router so it doesn't happen again.

</details>

<details>
<summary><b>Updating</b></summary>

**This project.** Run the install command again to get the latest version, then send the new server script to the Steam Machine:

```sh
curl -fsSL https://raw.githubusercontent.com/SaintBaron/Steam-Machine-Remote-Access/main/install.sh | bash
steam-remote-setup update-server
```

`update-server` asks for your passphrase and password, then sudo's password, and applies any changes. Check [the releases page](https://github.com/SaintBaron/Steam-Machine-Remote-Access/releases) for notes first.

**Sunshine.** Update it while you're not streaming. The next connect uses the new version:

```sh
steam-ssh 'sudo flatpak update --system -y dev.lizardbyte.app.Sunshine'
```

**Moonlight:**

```sh
flatpak update -y com.moonlight_stream.Moonlight
```

**SteamOS.** Update as normal. SteamOS updates discard most changes in `/etc`, so this project adds its files to SteamOS's keep list, and the self-heal service puts back anything still missing at the next boot. SSH won't start without its lockdown, so an update can't leave it open. `steam-connect` also checks every time it connects, and repairs anything missing after asking for the password.

</details>

<details>
<summary><b>Tips and caveats</b></summary>

- Wake-on-LAN works from sleep, as long as the network card supports it (Part 6 tests this). If the Steam Machine was shut down, you'll have to press the power button. It doesn't work from outside your home, even over a VPN, so leave the Steam Machine awake if you'll connect remotely.
- It also only works over Ethernet, and the wake packet won't cross routers or VLANs, so keep both machines on the same network.
- By default Sunshine streams to one device at a time, and disconnecting on any PC stops Sunshine for everyone.
- The TV goes dark while you're streaming (if switching is set up), because Game Mode only drives one display at a time.
- While you stream, Connect makes Game Mode draw everything onto one layer (the capture fix, `BLACK_SCREEN_FIX`). Without it the stream can be black, miss Steam's menus, or get HDR colours wrong. It's undone when Sunshine stops. If the stream is still black, see [troubleshooting](troubleshooting.md#black-picture).
- Three wrong passwords locks the account for 10 minutes, sudo included. There's no way round it except waiting.
- Don't press Ctrl+Z in a terminal running SSH. It pauses SSH in the background and it keeps hold of the web UI port. If you've done it, run `steam-connect disconnect` (Linux) or close the terminal.
- None of the scripts take passwords as arguments, so they won't end up in your shell history. Don't paste them into commands yourself either.
- Desktop Mode streams fine too. The capture fix only does anything in Game Mode. For HDR in Desktop Mode, turn on HDR for the dummy plug in the Steam Machine's *System Settings > Display & Monitor*.
- Sunshine's web UI (`https://localhost:47990`) only works while Connect is open, since it goes through the SSH tunnel.

</details>

If something isn't working, see [troubleshooting.md](troubleshooting.md). To remove everything, see [uninstall.md](uninstall.md).
