# Displays, dummy plugs and adapters

Sunshine streams by capturing what the Steam Machine sends to a display output. So while you stream, one output has to be **active**: something is plugged in, it says it's connected, and SteamOS is drawing to it. This page covers your options, how the switching works, and what to do when a plug isn't detected.

## Your options

| Setup | How it works | Good | Watch out for |
| --- | --- | --- | --- |
| **Dummy plug + TV** (recommended) | Stream from the dummy plug; the TV is switched off while you stream and back on when you disconnect | Stream with the TV off or in use; the TV works normally the rest of the time | Needs a dummy plug that works with the Steam Machine's sockets (below) |
| **Dummy plug only** | Stream from the dummy plug; no TV attached | Simplest: nothing switches | No local picture unless you plug a screen in |
| **TV only** (no dummy plug) | Stream whatever the TV shows | No extra hardware | The TV must be **on** (not in standby) while you stream, and it shows the stream's picture too |
| **Monitor instead of TV** | As above, with a monitor | | Same as TV only |

A **dummy plug** (also *EDID emulator*, *headless display adapter* or *display emulator*) is a small plug that tells the Steam Machine "a screen is connected, and it supports these resolutions". The list of resolutions it reports is its **EDID**.

During setup you choose the **stream output** (the dummy plug) and the **TV output**. Switching only happens when both are set. Change them any time with `steam-remote-setup displays` (Windows: `steam-remote-setup.ps1 displays`).

## How switching works

Game Mode (gamescope) uses **one screen at a time**, and with two connected it won't necessarily pick the one you want. So the scripts tell the Linux graphics driver to ignore one of the outputs:

| When | Stream output | TV output |
| --- | --- | --- |
| Boot, and after you disconnect | turned off (ignored) | normal |
| While you're connected | normal | turned off (ignored) |

This uses the kernel's display connector control: writing `off` or `detect` to `/sys/class/drm/<output>/status`. Nothing is unplugged, no setting is saved, and a reboot always starts on the TV (the `steam-remote-display` boot service makes sure of that). The sudo rule lets the scripts write to exactly those two files and nothing else.

## Output names

Outputs are named like `card0-HDMI-A-1` or `card1-DP-2`:

- `card0`, `card1`... is the graphics card. It's usually `card0`, but it can be `card1` after some driver updates.
- `HDMI-A-1`, `DP-1`, `DP-2`... is the socket.

To list them with what's plugged in, on the Steam Machine (or with `steam-ssh` from your PC):

```bash
/home/.steam-remote/steam-remote-server.sh --outputs
```

Before the setup has run, use this instead:

```bash
for f in /sys/class/drm/card*-*/status; do echo "$(basename "$(dirname "$f")"): $(cat "$f")"; done
```

If an update renames an output (say `card0` becomes `card1`), `steam-connect` and `--check` print a `NOTE` about it. Run `steam-remote-setup displays` again to fix it.

## Choosing a dummy plug

**HDMI dummy plug into the HDMI port:** the simplest option, and it works.

**Anything on the DisplayPort socket needs care.** The Steam Machine's DisplayPort socket doesn't appear to support **DP++ (dual-mode)**: passive adapters fail on it, with the kernel logging AUX errors. DP++ is the feature that lets *passive* adapters turn a DisplayPort socket into HDMI. Without it:

| Plug in the DP socket | Works? |
| --- | --- |
| A **native DisplayPort** dummy plug (reports a DP EDID) | Often, but not always. Check the maker doesn't exclude the Steam Machine or SteamOS |
| An **active** DP-to-HDMI adapter + HDMI dummy plug or TV | Yes. Active adapters have their own converter chip, often powered over USB |
| A **passive** DP-to-HDMI cable or adapter (most cheap ones) | **No.** It shows as `disconnected` |
| A DisplayPort monitor | Yes |

How to tell active from passive: listings for active adapters usually say *active*, mention a chipset or USB power, or support 4K at 60 Hz or more over HDMI 2.0. Passive ones are often a simple cable, sometimes advertised as "DP++ compatible" (they need DP++ in the socket, which this socket doesn't have).

### A typical working setup

- The TV on **DisplayPort** through an **active** DP-to-HDMI adapter (or a DP monitor).
- The **HDMI dummy plug** in the HDMI port.
- Stream output: the HDMI one. TV output: the DP one.

## HDR and 4K

The stream can only be as good as the dummy plug's EDID:

- For **4K**, pick a dummy plug that advertises 3840x2160. Many cheap ones top out at 1080p or 4K 30 Hz.
- For **HDR**, the dummy plug must advertise HDR (HDR10 metadata in its EDID). Look for "HDR" in the listing, or plugs sold for game streaming. Without it, Game Mode won't enable HDR on that output, and Moonlight gets SDR.
- Match Moonlight's resolution and frame rate to something the plug supports, or Sunshine scales the picture.

To see what the dummy plug advertises, run this with it as the active output (connected and in use):

```bash
head -n 5 /sys/class/drm/card0-HDMI-A-1/modes      # use your stream output's name
```

## When a plug isn't detected

**1. Is it seen at all?**

```bash
cat /sys/class/drm/card*-*/status
```

`disconnected` for a plug you know is in means the Steam Machine gets no "hot-plug" signal from it. Re-seat it firmly. If it's on the DP socket, re-read the table above: a passive adapter can't work there.

**2. What does the kernel say?** Plug it in, wait 5 seconds, then:

```bash
sudo journalctl -k -b --no-pager | grep -iE 'drm|amdgpu|dp|hdmi|edid' | tail -n 30
```

| Message (roughly) | Meaning |
| --- | --- |
| `AUX ... fail` / `aux transfer failed` / timeouts | The DP socket can't talk to the plug: typically a passive adapter, or a DP dummy plug that needs DP++ |
| `EDID checksum is invalid` / `EDID block ... is all zeroes` | The plug's EDID is corrupt or unreadable. Try another plug |
| Nothing at all | No hot-plug detected. Check the cable and the socket, and try the other port |

**3. Is it detected but not in use?** The `In use` column in `--outputs` says `disabled` for whichever output is currently switched off, so when you're not connected the dummy plug shows `disabled`.

**4. Sunshine says `Unable to find display or encoder`** even though the output is connected: the switch happened after Sunshine started. Reconnect with `steam-connect restart` (Windows: `steam-connect.ps1 -Restart`).

## Without a dummy plug

Choose **0** for the stream output during setup (or set `STREAM_OUTPUT=""` in `/home/.steam-remote/config`). Then:

- Nothing switches. Sunshine streams whatever the TV shows.
- The TV must be **on**. Some TVs drop the connection in standby, and Sunshine then has nothing to capture (`Unable to find display or encoder`).
- The TV shows the same picture you're streaming.
