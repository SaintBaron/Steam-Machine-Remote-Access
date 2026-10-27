# steam-ssh.ps1: open a terminal on the Steam Machine (no Sunshine, no stream).
# https://github.com/SaintBaron/Steam-Machine-Remote-Access
# Wakes it first if needed.
#
#   steam-ssh.ps1                 interactive shell
#   steam-ssh.ps1 <command...>    run one command, e.g.  steam-ssh.ps1 systemctl is-active steam-remote-sunshine.service
param([switch]$Pause, [switch]$Version, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Command)

. (Join-Path $PSScriptRoot 'common.ps1')
if ($Version) { "steam-ssh $SrVersion"; exit 0 }
if ($Pause) { $env:STEAM_REMOTE_PAUSE = '1' }
Test-SrSsh
Import-SrConfig
Wait-SrAwake -Quiet
Save-SrMac

& ssh.exe -t -o "HostName=$($Cfg.TARGET)" $Cfg.HOST_ALIAS @Command
$rc = $LASTEXITCODE
if ($rc -eq 255) {
    Write-Host "Error: couldn't connect to the Steam Machine. See docs/troubleshooting.md." -ForegroundColor Red
    if ($env:STEAM_REMOTE_PAUSE) { Read-Host 'Press Enter to close this window' | Out-Null }
}
exit $rc
