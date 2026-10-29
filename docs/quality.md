# Picture quality and HDR

How to get the sharpest stream, and how to get HDR working from end to end. Do your OS guide first ([Arch](arch.md), [Debian/Ubuntu](debian.md), [macOS](macos.md) or [Windows](windows.md)).

- [Quick checklist](#quick-checklist)
- [Stream settings](#stream-settings)
- [The Steam Machine's side](#the-steam-machines-side)
- [HDR](#hdr)
- [Reading Moonlight's stats](#reading-moonlights-stats)

## Quick checklist

1. **Use wired Ethernet** on both the Steam Machine and the PC if you can. Wi-Fi is the most common cause of a soft or stuttering picture.
2. **Match the stream to your PC's screen.** Set the same resolution and frame rate in Moonlight (or with `steam-remote-setup quality`, below) **and** on the Steam Machine while you're streaming (see [The Steam Machine's side](#the-steam-machines-side)). If the two differ, the picture gets scaled and loses sharpness.
3. **Give it enough bitrate:** 60 to 150 Mbps on a wired home network.
4. **Use HEVC or AV1**, not H.264. HDR needs one of them.
5. **For HDR**, work through [the HDR checklist](#hdr).

## Stream settings

You can set these in Moonlight's own **Settings**, or keep them in this project's settings so `steam-connect` hands them to Moonlight on every connection:

| Linux or macOS | Windows |
| --- | --- |
| `steam-remote-setup quality` | `steam-remote-setup.ps1 quality` |

It asks for each setting below. Press Enter to keep the value shown, or type `-` to clear it, so Moonlight's own setting is used instead. They're saved in this PC's config as the `STREAM_*` settings.

| Setting | Suggested | Notes |
| --- | --- | --- |
| Resolution (`STREAM_RESOLUTION`) | Your screen's, e.g. `3840x2160` or `2560x1440` | Can't be higher than the dummy plug offers (the stream check shows it) |
| Frames per second (`STREAM_FPS`) | `60`, or `120` if your screen and the dummy plug do 120 Hz | 120 FPS needs more bitrate for the same sharpness: Moonlight's own default goes up about 40% |
| Bitrate at home (`STREAM_BITRATE`) | 60 to 150 Mbps wired, 30 to 60 Mbps on Wi-Fi | In Mbps. Higher is sharper until the network can't keep up |
| Bitrate away (`STREAM_BITRATE_AWAY`) | 10 to 25 Mbps (default 20) | Used instead of the home bitrate when you connect through the VPN, so the stream fits your home's upload. See [remote-access.md](remote-access.md) |
| Codec (`STREAM_CODEC`) | `HEVC`, or `AV1` if this PC's graphics can decode it | AV1 is sharper at the same bitrate. `auto` lets Moonlight choose |
| HDR (`STREAM_HDR`) | `yes` if you've done [the HDR checklist](#hdr) | `no` forces SDR; empty uses Moonlight's own **Enable HDR** |

`steam-connect` shows what it passed on, for example `Starting Moonlight (Desktop; --resolution 3840x2160 --fps 60 --bitrate 120000 --video-codec HEVC --hdr)`. Moonlight measures bitrate in Kbps, so 120 Mbps shows as `120000`. These only apply to streams that `steam-connect` starts. Moonlight's own saved settings stay as they are.

**Away from home**, `steam-connect` uses `STREAM_BITRATE_AWAY` automatically whenever it reaches the Steam Machine through the VPN. Home upload speeds are usually much lower than download speeds, and the stream has to fit inside your upload.

## The Steam Machine's side

### Its screen resolution

Sunshine streams whatever resolution the Steam Machine is showing on the dummy plug. If that's 1080p and Moonlight asks for 4K, the picture is upscaled and looks soft.

While a stream is running (so the setting applies to the dummy plug, not the TV), open **Steam > Settings > Display** on the stream and set the **resolution** (and refresh rate) to match Moonlight's. Steam normally remembers this for each display separately, so the TV keeps its own. If the stream is soft again later, check this first.

### The encoder preset

The Steam Machine's video encoder can work harder for a sharper picture, at the cost of a little delay. The setup asks for this, and `steam-remote-setup quality` asks too. It's `ENCODER_QUALITY` in the Steam Machine's config.

| Preset | Use it when |
| --- | --- |
| `quality` (default) | Most streams, up to 4K at 60 FPS |
| `balanced` | 4K at 120 FPS, or Moonlight's stats show the encoder can't keep up (see [below](#reading-moonlights-stats)) |
| `speed` | You want the lowest possible delay and can give up some sharpness |
| `auto` | Leave it to the graphics driver |

The preset needs Sunshine 2026.906 or later; older versions ignore it. To update Sunshine, see *Updating* in your OS guide.

### The stream check

`steam-connect` prints this before Moonlight opens:

```text
==> Stream check
    Stream output HDMI-A-1: up to 3840x2160 at 120 Hz, HDR10
    Game Mode: HDR on, capture fix on
    Encoder: vaapi, preset quality, AV1 available
    HDR: ready. Turn on Enable HDR in Moonlight to use it
```

| Line | What it tells you |
| --- | --- |
| `Stream output ...` | The biggest mode the dummy plug offers, and whether it accepts HDR: `HDR10` (good), `no HDR`, or `HDR, but not the BT.2020 colours Game Mode needs` (Game Mode won't use HDR on it) |
| `Game Mode: HDR on/off` | Steam's **Enable HDR** setting for the dummy plug |
| `capture fix on/off` | Whether Game Mode is drawing everything onto one layer for Sunshine (see [HDR](#hdr), step 3) |
| `Desktop Mode: ...` | The Steam Machine is in Desktop Mode, where HDR follows KDE's own display setting |
| `Encoder: ...` | The graphics card's encoder Sunshine is using (`vaapi` or `vulkan`) and the preset. `software` means the graphics encoder failed: expect a soft, laggy picture, and check Sunshine's log |
| `HDR: ...` | Whether HDR can work right now, and what to change if not |

You can run it yourself at any time, while Sunshine is running:

| Linux or macOS | Windows |
| --- | --- |
| `steam-ssh /home/.steam-remote/steam-remote-server.sh --stream-info` | `steam-ssh.ps1 /home/.steam-remote/steam-remote-server.sh --stream-info` |

## HDR

HDR only works if every link in the chain does HDR. Go through these in order.

**1. A dummy plug that offers HDR.** The Steam Machine only turns on HDR for a display that says it supports it, and a dummy plug is a display as far as it knows. The stream check's first line must end in `HDR10`. Game Mode needs the plug to list both HDR10 (PQ) and BT.2020 colours. If it says `no HDR`, or `not the BT.2020 colours Game Mode needs`, you need a different plug: look for one sold as HDR or for game streaming, that offers 4K at 60 Hz or more. See [displays.md](displays.md#hdr-and-4k).

**2. HDR on in Game Mode, for the dummy plug.** While streaming, open **Steam > Settings > Display** on the stream and turn on **Enable HDR**. Steam remembers this for the dummy plug. The TV keeps its own setting. The stream check then shows `Game Mode: HDR on`.

**3. The capture fix on.** In Game Mode, Steam's menus and the game can be on separate hardware layers, and part of the HDR colour conversion is done by the display hardware as the picture goes out. Sunshine only captures one layer, before that conversion, so without the fix HDR colours come out wrong (washed out or too dark), menus can be missing, or the stream can be black. While you're connected, `steam-connect` makes Game Mode draw everything onto one layer first, then undoes it when Sunshine stops. It costs a little graphics power, so it's only on while you stream. This is `BLACK_SCREEN_FIX="yes"` in this PC's config, the default. The stream check shows `capture fix on`.

**4. Moonlight asks for HDR.** Turn on **Enable HDR** in Moonlight's settings, or set HDR to `yes` with `steam-remote-setup quality`. Use HEVC or AV1: H.264 has no HDR. If **Enable HDR** is greyed out, Moonlight couldn't decode or display 10-bit HEVC or AV1 on this PC; updating the graphics driver usually fixes it.

**5. HDR on for this PC's screen.**

| PC | Where |
| --- | --- |
| Windows 10 or 11 | **Settings > System > Display**, turn on **Use HDR** for the monitor |
| Linux, KDE Plasma 6 | **System Settings > Display & Monitor**, turn on **HDR** for the monitor |
| Linux, GNOME 48 or later | **Settings > Displays**, turn on **HDR** for the monitor |
| macOS | **System Settings > Displays**, turn on **High Dynamic Range**, if the display offers it. Built-in XDR displays do HDR without a switch |

On Linux, Moonlight uses its Vulkan renderer for HDR, so the graphics driver needs working Vulkan. On a desktop without HDR (X11, or an older desktop), Moonlight still plays an HDR stream, converted to SDR.

**6. The game itself.** Many games have their own HDR switch in their video settings. Steam's menus and SDR games still look right with HDR on: they're shown inside the HDR picture.

### Is it working?

When Moonlight connects, `steam-connect` says which it got:

| Message | Meaning | Fix |
| --- | --- | --- |
| `streaming in HDR (10-bit)` | Working | |
| `streaming in SDR. Moonlight asked for HDR, but the Steam Machine's output isn't in HDR` | Steps 4 and 5 are fine; the problem is on the Steam Machine | Steps 1 to 3. The stream check's `HDR:` line says which |
| `streaming in SDR (8-bit). For HDR, turn on Enable HDR in Moonlight's settings` | The Steam Machine is ready, but Moonlight didn't ask for HDR | Step 4 |
| `streaming in SDR (8-bit)` | Moonlight didn't ask for HDR, and the Steam Machine isn't in HDR either | Fine if you didn't want HDR; otherwise all of the steps |

In Moonlight's stats overlay (below), the first line shows the codec: `HEVC 10-bit HDR` or `AV1 10-bit HDR` when it's working. `10-bit SDR` means Moonlight asked for HDR but the Steam Machine sent SDR.

### HDR in Desktop Mode

Desktop Mode (KDE Plasma on the Steam Machine) has its own HDR switch. While streaming, open **System Settings > Display & Monitor** on the stream, select the dummy plug and turn on **HDR**. The capture fix isn't needed in Desktop Mode.

### Colours look wrong

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Washed out, greyish | Game Mode is in HDR, but Moonlight asked for SDR | Step 4, or turn off HDR in Game Mode |
| Washed out or far too dark, though the stream says HDR | The capture fix isn't on | Check `capture fix on` in the stream check, and `BLACK_SCREEN_FIX="yes"` in this PC's config |
| Too bright or oversaturated on the PC | This PC's screen is in SDR, or HDR is off on it | Step 5 |

## Reading Moonlight's stats

Turn the stats overlay on and off with **Ctrl+Alt+Shift+S** (macOS: **Control+Option+Shift+S**), or turn on **Show performance stats while streaming** in Moonlight's settings.

| Stat | What to look for |
| --- | --- |
| `Video stream: ... (Codec: ...)` | The resolution, frame rate and codec you actually got, including `10-bit HDR` |
| `Bitrate:` | Roughly what you set. Static scenes use less |
| `Frames dropped by your network connection` | Above 1%: lower the bitrate, or use Ethernet |
| `Frames dropped due to network jitter` | Above 1%: the network is uneven, often Wi-Fi. Use Ethernet, or lower the bitrate |
| `Host processing latency min/max/average` | The Steam Machine's capture and encode time. If the average is above one frame (16.7 ms at 60 FPS, 8.3 ms at 120 FPS), use the `balanced` or `speed` encoder preset |
| `Average decoding time` | This PC's decode time. If it's above one frame, this PC's graphics are struggling: try HEVC instead of AV1, or a lower resolution |
| `Average network latency` | Round trip to the Steam Machine. Under 5 ms on a home network; more through a VPN |
