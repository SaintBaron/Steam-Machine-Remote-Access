# Uninstalling

Remove the Steam Machine side first, while your PC can still log in, then each PC.

## 1. The Steam Machine

### From your PC (easiest)

```sh
steam-remote-setup uninstall-server            # Linux
steam-remote-setup.ps1 uninstall-server        # Windows
```

It asks you to confirm, then (after the password and sudo):

- stops Sunshine and switches back to the TV;
- disables and deletes every `steam-remote-*` service, the firewall, the SSH lockdown and the sudo rule;
- uninstalls the Sunshine Flatpak and deletes its data (pairing, web UI login);
- deletes `/home/.steam-remote`;
- **turns SSH off**. Your current session stays connected until you close it.

Your public key stays in `~deck/.ssh/authorized_keys`. Delete that file (or the line) if you no longer need it.

### At the Steam Machine

In Desktop Mode, in Konsole:

```bash
sudo /home/.steam-remote/steam-remote-server.sh --uninstall
```

Options:

| Option | Effect |
| --- | --- |
| `--keep-sunshine` | Leave Sunshine and its pairing installed (only the service and lockdown are removed) |
| `--keep-ssh` | Leave SSH on with **SteamOS's defaults**: password logins from any device on your network. Only use this if you'll secure it another way |

If `/home/.steam-remote` is already gone, remove the leftovers by hand:

```bash
sudo systemctl disable --now steam-remote-sunshine.service steam-remote-guard.service steam-remote-display.service steam-remote-idle.timer steam-remote-heal.service
sudo rm -f /etc/systemd/system/steam-remote-* /etc/systemd/system/sshd.service.d/10-steam-remote.conf /etc/atomic-update.conf.d/steam-remote.conf /etc/steam-remote-guard.nft /etc/sudoers.d/zz-steam-remote /etc/ssh/sshd_config.d/10-steam-remote.conf
sudo rm -rf /var/lib/sunshine-bwrap
sudo systemctl daemon-reload
sudo nft delete table inet steam_remote 2>/dev/null
sudo flatpak uninstall --system -y dev.lizardbyte.app.Sunshine && sudo rm -rf /root/.var/app/dev.lizardbyte.app.Sunshine
sudo systemctl disable --now sshd
```

Wake-on-LAN stays switched on in NetworkManager, which is harmless. To turn it off: `nmcli connection modify "CONNECTION NAME" 802-3-ethernet.wake-on-lan default`. List connection names with `nmcli connection show`.

## 2. A Linux PC or a Mac

```sh
curl -fsSL https://raw.githubusercontent.com/SaintBaron/Steam-Machine-Remote-Access/main/install.sh | bash -s -- --uninstall
```

Or, from a clone: `bash install.sh --uninstall`. Use `--purge` instead to also delete `~/.config/steam-remote`.

This removes the commands, launchers and icons. Then, if you like:

```sh
rm -f ~/.ssh/steam-machine_ed25519 ~/.ssh/steam-machine_ed25519.pub   # the SSH key
ssh-keygen -R STEAM_MACHINE_IP                                        # its known_hosts entry
flatpak uninstall --user -y --delete-data com.moonlight_stream.Moonlight   # Linux
brew uninstall --cask moonlight                                            # macOS (or drag Moonlight to the Bin)
```

Finally, delete the block between `# >>> steam-machine-remote >>>` and `# <<< steam-machine-remote <<<` in `~/.ssh/config`.

## 3. A Windows PC

```powershell
$env:STEAM_REMOTE_UNINSTALL = '1'; irm https://raw.githubusercontent.com/SaintBaron/Steam-Machine-Remote-Access/main/install.ps1 | iex; Remove-Item Env:STEAM_REMOTE_UNINSTALL
```

This removes the scripts, shortcuts and PATH entry. Then, if you like:

```powershell
Remove-Item -Recurse $env:APPDATA\steam-remote                                  # settings
Remove-Item $HOME\.ssh\steam-machine_ed25519, $HOME\.ssh\steam-machine_ed25519.pub # the SSH key
ssh-keygen -R STEAM_MACHINE_IP                                                  # its known_hosts entry
winget uninstall -e --id MoonlightGameStreamingProject.Moonlight
```

Finally, delete the block between the `steam-machine-remote` markers in `%USERPROFILE%\.ssh\config` (open it with `notepad $HOME\.ssh\config`).
