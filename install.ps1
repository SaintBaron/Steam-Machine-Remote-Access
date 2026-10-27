# install.ps1: install the Steam Machine Remote Access commands on Windows 10/11.
# https://github.com/SaintBaron/Steam-Machine-Remote-Access
#
# In PowerShell (no admin needed):
#   irm https://raw.githubusercontent.com/SaintBaron/Steam-Machine-Remote-Access/main/install.ps1 | iex
# Or from a cloned/downloaded copy of the repo:
#   powershell -ExecutionPolicy Bypass -File .\install.ps1
#
# Options (environment variables, because "irm | iex" can't take parameters):
#   $env:STEAM_REMOTE_REF = 'v1.0.0'     install a tag or branch instead of main
#   $env:STEAM_REMOTE_UNINSTALL = '1'    remove the scripts, shortcuts and PATH entry (keeps your config)
#
# Installs into %LOCALAPPDATA%\steam-remote, adds Start menu and desktop shortcuts,
# and adds that folder to your user PATH.

$ErrorActionPreference = 'Stop'
$Repo = if ($env:STEAM_REMOTE_REPO) { $env:STEAM_REMOTE_REPO } else { 'SaintBaron/Steam-Machine-Remote-Access' }
$Ref  = if ($env:STEAM_REMOTE_REF)  { $env:STEAM_REMOTE_REF }  else { 'main' }
$Dest = Join-Path $env:LOCALAPPDATA 'steam-remote'
$StartDir = Join-Path ([Environment]::GetFolderPath('Programs')) 'Steam Machine Remote'
$Desktop  = [Environment]::GetFolderPath('Desktop')
$Files = @('windows/common.ps1', 'windows/steam-connect.ps1', 'windows/steam-ssh.ps1', 'windows/steam-pair.ps1',
           'windows/steam-remote-setup.ps1', 'server/steam-remote-server.sh', 'assets/icons/steam-remote-connect.ico',
           'assets/icons/steam-remote-ssh.ico', 'config.example', 'VERSION')

function Say([string]$m) { Write-Host '==> ' -ForegroundColor Blue -NoNewline; Write-Host $m }
function Warn([string]$m) { Write-Host "Warning: $m" -ForegroundColor Yellow }

function Set-UserPath([bool]$Add) {
    $path = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($path -split ';' | Where-Object { $_ -and $_ -ne $Dest })
    if ($Add) { $parts += $Dest }
    [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
}

# ------------------------------------------------------------------ uninstall
if ($env:STEAM_REMOTE_UNINSTALL) {
    Remove-Item -Recurse -Force -LiteralPath $Dest, $StartDir -ErrorAction SilentlyContinue
    Remove-Item -Force -LiteralPath (Join-Path $Desktop 'Steam Machine - Connect.lnk'), (Join-Path $Desktop 'Steam Machine - SSH.lnk') -ErrorAction SilentlyContinue
    Set-UserPath $false
    Say 'Removed the scripts, shortcuts and PATH entry.'
    Write-Host "Not touched: your config ($env:APPDATA\steam-remote), SSH key, SSH config, Moonlight and the Steam Machine. See docs/uninstall.md."
    return
}

# ------------------------------------------------------------------ prerequisites
if (@(Get-Command ssh.exe, scp.exe, ssh-keygen.exe -ErrorAction SilentlyContinue).Count -lt 3) {
    Warn 'The OpenSSH client is missing or incomplete. Add it in Settings > System > Optional features > "OpenSSH Client",'
    Warn 'or in an admin PowerShell: Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0'
}

# ------------------------------------------------------------------ files
$here = $null
if ($PSCommandPath) { $here = Split-Path -Parent $PSCommandPath }
New-Item -ItemType Directory -Force -Path $Dest, (Join-Path $Dest 'server'), (Join-Path $Dest 'icons') | Out-Null
if ($here -and (Test-Path (Join-Path $here 'windows\steam-connect.ps1'))) {
    Say "Installing from $here"
    foreach ($f in $Files) {
        $target = if ($f -like 'windows/*') { Join-Path $Dest (Split-Path $f -Leaf) }
                  elseif ($f -like 'assets/icons/*') { Join-Path $Dest ('icons\' + (Split-Path $f -Leaf)) }
                  else { Join-Path $Dest ($f -replace '/', '\') }
        Copy-Item -Force -LiteralPath (Join-Path $here ($f -replace '/', '\')) -Destination $target
    }
} else {
    Say "Downloading $Repo ($Ref)"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $base = "https://raw.githubusercontent.com/$Repo/$Ref"
    foreach ($f in $Files) {
        $target = if ($f -like 'windows/*') { Join-Path $Dest (Split-Path $f -Leaf) }
                  elseif ($f -like 'assets/icons/*') { Join-Path $Dest ('icons\' + (Split-Path $f -Leaf)) }
                  else { Join-Path $Dest ($f -replace '/', '\') }
        Invoke-WebRequest -UseBasicParsing -Uri "$base/$f" -OutFile $target
        if ((Get-Item -LiteralPath $target).Length -eq 0) { throw "Downloaded an empty $f" }
    }
}
# The server script runs on Linux: make sure it has Unix line endings.
$srv = Join-Path $Dest 'server\steam-remote-server.sh'
[IO.File]::WriteAllText($srv, ([IO.File]::ReadAllText($srv) -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
Get-ChildItem -LiteralPath $Dest -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

# ------------------------------------------------------------------ Moonlight
$moonlight = @("$env:ProgramFiles\Moonlight Game Streaming\Moonlight.exe",
               "${env:ProgramFiles(x86)}\Moonlight Game Streaming\Moonlight.exe",
               "$env:LOCALAPPDATA\Programs\Moonlight Game Streaming\Moonlight.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $moonlight) {
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
        $r = Read-Host 'Moonlight is not installed. Install it now with winget? [Y/n]'
        if ($r -notmatch '^[Nn]') { & winget.exe install --id MoonlightGameStreamingProject.Moonlight -e --accept-package-agreements --accept-source-agreements }
    } else {
        Warn 'Moonlight is not installed. Get it from https://moonlight-stream.org before streaming.'
    }
}

# ------------------------------------------------------------------ shortcuts
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$shell = New-Object -ComObject WScript.Shell
function New-Shortcut([string]$Path, [string]$Script, [string]$ScriptArgs, [string]$Icon, [string]$Description) {
    $s = $shell.CreateShortcut($Path)
    $s.TargetPath = $ps
    $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $Dest $Script)`" -Pause $ScriptArgs".TrimEnd()
    $s.WorkingDirectory = $HOME
    $s.IconLocation = (Join-Path $Dest "icons\$Icon")
    $s.Description = $Description
    $s.Save()
}
New-Item -ItemType Directory -Force -Path $StartDir | Out-Null
New-Shortcut (Join-Path $StartDir 'Steam Machine - Connect.lnk') 'steam-connect.ps1' '' 'steam-remote-connect.ico' 'Wake the Steam Machine and stream it in Moonlight'
New-Shortcut (Join-Path $StartDir 'Steam Machine - Connect (no stream).lnk') 'steam-connect.ps1' '-NoStream' 'steam-remote-connect.ico' 'Start Sunshine and the web UI tunnel without Moonlight (for pairing)'
New-Shortcut (Join-Path $StartDir 'Steam Machine - SSH.lnk') 'steam-ssh.ps1' '' 'steam-remote-ssh.ico' 'Open a terminal on the Steam Machine'
New-Shortcut (Join-Path $StartDir 'Steam Machine - Setup.lnk') 'steam-remote-setup.ps1' '' 'steam-remote-ssh.ico' 'Set up or change Steam Machine Remote Access'
New-Shortcut (Join-Path $Desktop 'Steam Machine - Connect.lnk') 'steam-connect.ps1' '' 'steam-remote-connect.ico' 'Wake the Steam Machine and stream it in Moonlight'
New-Shortcut (Join-Path $Desktop 'Steam Machine - SSH.lnk') 'steam-ssh.ps1' '' 'steam-remote-ssh.ico' 'Open a terminal on the Steam Machine'

Set-UserPath $true
Say "Installed $(Get-Content (Join-Path $Dest 'VERSION') -TotalCount 1) into $Dest"
Write-Host '   Shortcuts: Start menu > Steam Machine Remote, and two on your desktop.'
Write-Host '   To run the scripts by name in a terminal, open a NEW PowerShell window and allow local scripts once:'
Write-Host '     Set-ExecutionPolicy -Scope CurrentUser RemoteSigned'
Write-Host ''
Say 'Next (Part 4 of your guide): Start menu > Steam Machine Remote > Steam Machine - Setup. Do Part 2, at the Steam Machine, first if you haven''t.'
