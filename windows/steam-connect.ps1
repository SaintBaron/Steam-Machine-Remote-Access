# steam-connect.ps1: stream the Steam Machine to this PC.
# https://github.com/SaintBaron/Steam-Machine-Remote-Access
#
# Wakes the Steam Machine if needed, logs in (key + password), checks the setup
# survived any SteamOS update, switches the picture to the stream output, starts
# Sunshine, opens the web UI tunnel and starts Moonlight. The window stays open.
# Press Q, press Ctrl+C or close the window to disconnect: Sunshine stops and the
# picture goes back to the TV. That part runs on the Steam Machine itself, so it
# happens even if this PC crashes or the network drops.
#
#   steam-connect.ps1              connect and stream
#   steam-connect.ps1 -Restart     restart Sunshine first (e.g. it couldn't see a screen)
#   steam-connect.ps1 -NoStream    connect without opening Moonlight (for pairing)
param([switch]$NoStream, [switch]$Restart, [switch]$Pause, [switch]$Version)

. (Join-Path $PSScriptRoot 'common.ps1')
if ($Version) { "steam-connect $SrVersion"; exit 0 }
if ($Pause) { $env:STEAM_REMOTE_PAUSE = '1' }
Test-SrSsh
Import-SrConfig

# Only one at a time, so closing a second window can't cut off the first.
$mutex = New-Object Threading.Mutex($false, 'Local\steam-remote-connect')
if (-not $mutex.WaitOne(0)) { Stop-SrError 'steam-connect is already running in another window. Use that one, or close it first.' }

# Runs on the Steam Machine for the length of the session. Its trap stops Sunshine
# and switches back to the TV however the session ends (Q, Ctrl+C, window closed,
# network lost). Sent base64-encoded so no quoting can break it.
$remote = @'
FIX=$1; RESTART=$2; PORT=$3; WANT=${4:-}; HDR=${5:-keep}
K=/home/.steam-remote; S=$K/steam-remote-server.sh; U=steam-remote-sunshine.service
say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWarning:\033[0m %s\n' "$*"; }
[ -x "$S" ] || { warn "The Steam Machine isn't set up yet. Run the setup first."; exit 1; }
if ! "$S" --check >/dev/null 2>&1; then
  warn "Part of the Steam Machine setup is missing (usually after a SteamOS update):"
  "$S" --check 2>&1 | sed 's/^/    /'
  say "Repairing it: enter the Steam Machine's password if asked"
  sudo "$S" || { warn "The repair failed. Read the messages above."; exit 1; }
fi
conf() { sed -n "s/^$1=\"\{0,1\}\([^\"#[:space:]]*\).*/\1/p" "$K/config" | head -n 1; }
ok() { [[ "$1" =~ ^card[0-9]+-[A-Za-z0-9-]+$ ]]; }
SO=$(conf STREAM_OUTPUT); TV=$(conf TV_OUTPUT); SW=0
ok "$SO" && ok "$TV" && [ "$SO" != "$TV" ] && SW=1
show() { echo off | sudo -n tee "/sys/class/drm/$1/status" >/dev/null; echo detect | sudo -n tee "/sys/class/drm/$2/status" >/dev/null; }
# Game Mode capture fix; the xprop fallback is for server scripts older than 1.2.0.
xp() {
  if [ "$1" = 1 ]; then "$S" --composite on >/dev/null 2>&1 && return; else "$S" --stream-end >/dev/null 2>&1 && return; fi
  DISPLAY=:0 xprop -root -f GAMESCOPE_COMPOSITE_FORCE 32c -set GAMESCOPE_COMPOSITE_FORCE "$1" >/dev/null 2>&1
}
WATCH=
DONE=0
cleanup() {
  [ "$DONE" = 1 ] && return; DONE=1
  [ -n "$WATCH" ] && { pkill -P "$WATCH" 2>/dev/null; kill "$WATCH" 2>/dev/null; }
  echo; say "Disconnecting: stopping Sunshine"
  { [ "$FIX" = yes ] || [ "$HDR" != keep ]; } && xp 0
  sudo -n systemctl stop "$U"
  [ "$SW" = 1 ] && show "$SO" "$TV" && say "Switched back to the TV"
  say "Disconnected."
}
trap cleanup EXIT
trap 'exec >/dev/null 2>&1 </dev/null; exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
if [ "$SW" = 1 ]; then
  say "Switching to the stream output"
  show "$TV" "$SO" || warn "Couldn't switch displays. Run: sudo $S"
  sleep 2
fi
if [ "$RESTART" = yes ]; then
  say "Restarting Sunshine"; sudo -n systemctl restart "$U" || { warn "Couldn't restart Sunshine. Run: sudo $S"; exit 1; }
elif ! systemctl is-active --quiet "$U"; then
  say "Starting Sunshine"; sudo -n systemctl start "$U" || { warn "Couldn't start Sunshine. Run: sudo $S"; exit 1; }
else
  say "Sunshine is already running"
fi
# Reports SDR or HDR once Moonlight connects (server script 1.2.0 or later).
{ "$S" --stream-watch 300 "$WANT" 2>/dev/null | while IFS= read -r l; do say "$l"; done; } &
WATCH=$!
say "Waiting for Sunshine"
for _ in $(seq 1 30); do ss -ltn | grep -q ':47989 ' && break; sleep 1; done
ss -ltn | grep -q ':47989 ' || { warn "Sunshine didn't start. Its log:"; journalctl -u "$U" -n 20 --no-pager -o cat; exit 1; }
sleep 1
if journalctl -u "$U" _SYSTEMD_INVOCATION_ID="$(systemctl show -p InvocationID --value "$U")" --no-pager -o cat 2>/dev/null | grep -q 'Unable to find display or encoder'; then
  warn "Sunshine is running but can't see a screen. Check the stream output (dummy plug) is fully"
  warn "plugged in, then connect again with -Restart. Still nothing? See docs/displays.md."
  exit 1
fi
say "Sunshine is ready. Web UI (while this window is open): https://localhost:$PORT"
if [ "$FIX" = yes ]; then xp 1 || warn "Couldn't apply the Game Mode capture fix (fine in Desktop Mode)."; fi
# Game Mode's HDR, matched to Moonlight's Enable HDR; Steam's own setting comes back afterwards.
case "$HDR" in on|off) "$S" --hdr "$HDR" >/dev/null 2>&1 && say "Game Mode HDR $HDR, to match Moonlight" ;; esac
if INFO=$("$S" --stream-info "$WANT" 2>/dev/null) && [ -n "$INFO" ]; then
  say "Stream check"; while IFS= read -r l; do echo "    $l"; done <<<"$INFO"
fi
echo
say "Connected. Press Q to disconnect (or Ctrl+C, or close this window)."
while read -rsn1 k; do case "$k" in q|Q) break ;; esac; done
exit 0
'@

$job = $null
try {
    $moonlight = Get-SrMoonlight
    if (-not $NoStream -and -not $moonlight) { Stop-SrError "Moonlight isn't installed. Install it (see the guide), or connect with -NoStream." }

    Wait-SrAwake
    Save-SrMac

    $fix = if ($Cfg.BLACK_SCREEN_FIX -eq 'yes') { 'yes' } else { 'no' }
    $rst = if ($Restart) { 'yes' } else { 'no' }
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($remote -replace "`r`n", "`n")))
    $hdrWant = if ($NoStream) { '' } else { Get-SrHdrWanted }
    $want = if ($hdrWant -eq 'no') { 'sdr' } elseif ($hdrWant -eq 'yes') { 'hdr' } else { 'any' }
    $hdr = if ($Cfg.MATCH_HDR -eq 'yes' -and $hdrWant -eq 'yes') { 'on' } elseif ($Cfg.MATCH_HDR -eq 'yes' -and $hdrWant -eq 'no') { 'off' } else { 'keep' }
    $command = "bash <(echo $b64 | base64 -d) $fix $rst $($Cfg.WEBUI_PORT) $want $hdr"

    # Start Moonlight in the background as soon as Sunshine answers.
    if (-not $NoStream) {
        $mlArgs = Get-SrMoonlightArgs
        if ($mlArgs.Count) { Write-SrInfo "Moonlight will use: $($mlArgs -join ' ')" }
        $job = Start-Job -ArgumentList $Cfg.TARGET, $moonlight, $Cfg.MOONLIGHT_APP, $mlArgs -ScriptBlock {
            param($Ip, $Exe, $App, $Opts)
            $deadline = (Get-Date).AddMinutes(5)
            while ((Get-Date) -lt $deadline) {
                $c = New-Object Net.Sockets.TcpClient
                try { $up = $c.ConnectAsync($Ip, 47989).Wait(1000) -and $c.Connected } catch { $up = $false } finally { $c.Dispose() }
                if ($up) { Start-Sleep -Seconds 3; Start-Process -FilePath $Exe -ArgumentList (@('stream') + @($Opts) + @($Ip, "`"$App`"")); return }
                Start-Sleep -Seconds 1
            }
        }
    }

    Write-SrInfo 'Logging in: your key passphrase, then the Steam Machine password (unless you chose key-only logins)'
    & ssh.exe -t -o "HostName=$($Cfg.TARGET)" -o ExitOnForwardFailure=yes -L "127.0.0.1:$($Cfg.WEBUI_PORT):127.0.0.1:47990" $Cfg.HOST_ALIAS $command
    $rc = $LASTEXITCODE
    if ($rc -eq 255) { Write-SrWarn "The SSH connection failed or dropped. If it mentions port $($Cfg.WEBUI_PORT), another window is using it. See docs/troubleshooting.md." }
} finally {
    if ($job) { Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue }
    Get-Process Moonlight -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $mutex.ReleaseMutex()
}
if ($env:STEAM_REMOTE_PAUSE -and $rc -ne 0) { Read-Host 'Press Enter to close this window' | Out-Null }
elseif ($env:STEAM_REMOTE_PAUSE) { Start-Sleep -Seconds 2 }
exit $rc
