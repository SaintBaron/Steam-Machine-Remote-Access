# common.ps1: shared code for the Steam Machine Remote Access Windows commands.
# https://github.com/SaintBaron/Steam-Machine-Remote-Access
# Dot-sourced by the other scripts; not run on its own. Works in Windows PowerShell 5.1 and PowerShell 7.

$SrVersion    = '1.1.0'
$SrConfigDir  = Join-Path $env:APPDATA 'steam-remote'
$SrConfig     = Join-Path $SrConfigDir 'config'
$SrMacCache   = Join-Path $SrConfigDir 'mac'
$SrHome       = Join-Path $env:LOCALAPPDATA 'steam-remote'
$SrKit        = '/home/.steam-remote'                  # on the Steam Machine
$SrServer     = "$SrKit/steam-remote-server.sh"        # on the Steam Machine
$SrSunUnit    = 'steam-remote-sunshine.service'        # on the Steam Machine
$SrConfigKeys = 'MACHINE_IP','REMOTE_MODE','REMOTE_PC_IP','REMOTE_MACHINE_IP','MACHINE_USER','HOST_ALIAS','KEY_FILE','MACHINE_MAC','BROADCAST',
                'WAKE_TIMEOUT','MOONLIGHT_APP','CLIENT_NAME','WEBUI_PORT','PERSIST','KEEPALIVE','BLACK_SCREEN_FIX'

function Write-SrInfo([string]$Message) { Write-Host '==> ' -ForegroundColor Blue -NoNewline; Write-Host $Message }
function Write-SrWarn([string]$Message) { Write-Host "Warning: $Message" -ForegroundColor Yellow }
function Stop-SrError([string]$Message) {
    Write-Host "Error: $Message" -ForegroundColor Red
    if ($env:STEAM_REMOTE_PAUSE) { Read-Host 'Press Enter to close this window' | Out-Null }
    exit 1
}

function Test-SrIp([string]$Ip) {
    $Ip -match '^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$'
}
function Test-SrMac([string]$Mac) { $Mac -match '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$' }

# Plain KEY="value" lines; parsed, never run. Unknown keys are ignored.
function Read-SrConfigFile([string]$Path) {
    $c = [ordered]@{
        MACHINE_IP = ''; REMOTE_MODE = 'off'; REMOTE_PC_IP = ''; REMOTE_MACHINE_IP = ''
        MACHINE_USER = 'deck'; HOST_ALIAS = 'steam-machine'
        KEY_FILE = '~/.ssh/steam-machine_ed25519'; MACHINE_MAC = ''; BROADCAST = ''
        WAKE_TIMEOUT = '90'; MOONLIGHT_APP = 'Desktop'; CLIENT_NAME = ''; WEBUI_PORT = '47990'
        PERSIST = '2h'; KEEPALIVE = '600'; BLACK_SCREEN_FIX = 'yes'
    }
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in Get-Content -LiteralPath $Path) {
            if ($line -match '^([A-Z_]+)=(?:"([^"]*)"|([^\s#"]*))\s*(?:#.*)?$' -and $SrConfigKeys -contains $Matches[1]) {
                if ($null -ne $Matches[2]) { $c[$Matches[1]] = $Matches[2] } else { $c[$Matches[1]] = $Matches[3] }
            }
        }
    }
    $c
}

function Import-SrConfig {
    if (-not (Test-Path -LiteralPath $SrConfig)) { Stop-SrError 'No config yet. Run "Steam Machine - Setup" from the Start menu (or steam-remote-setup.ps1).' }
    $script:Cfg = Read-SrConfigFile $SrConfig
    if (-not (Test-SrIp $Cfg.MACHINE_IP)) { Stop-SrError "MACHINE_IP in $SrConfig isn't an IPv4 address. Run the setup again." }
    if ($Cfg.HOST_ALIAS -notmatch '^[A-Za-z0-9._-]+$') { Stop-SrError "HOST_ALIAS in $SrConfig may only use letters, numbers, . _ -" }
    if ($Cfg.WEBUI_PORT -notmatch '^[0-9]{2,5}$') { Stop-SrError "WEBUI_PORT in $SrConfig must be a port number" }
    if ($Cfg.WAKE_TIMEOUT -notmatch '^[0-9]+$') { $Cfg.WAKE_TIMEOUT = '90' }
    if ($Cfg.REMOTE_MACHINE_IP -and -not (Test-SrIp $Cfg.REMOTE_MACHINE_IP)) { Stop-SrError "REMOTE_MACHINE_IP in $SrConfig isn't an IPv4 address" }
    if ($Cfg.REMOTE_PC_IP -and -not (Test-SrIp $Cfg.REMOTE_PC_IP)) { Stop-SrError "REMOTE_PC_IP in $SrConfig isn't an IPv4 address" }
    if ($Cfg.REMOTE_MODE -notmatch '^(off|router|tailscale|other)$') { $Cfg.REMOTE_MODE = 'off' }
    $Cfg.TARGET = $Cfg.MACHINE_IP   # the address actually used; Wait-SrAwake may switch it to REMOTE_MACHINE_IP
    if (-not $Cfg.BROADCAST) { $Cfg.BROADCAST = ($Cfg.MACHINE_IP -replace '\.[0-9]+$', '.255') }
    if (-not $Cfg.CLIENT_NAME) { $Cfg.CLIENT_NAME = $env:COMPUTERNAME }
    $Cfg.KEY_FILE = $Cfg.KEY_FILE -replace '^~', $HOME
}

function Test-SrPing([string]$Ip) {
    try { (New-Object Net.NetworkInformation.Ping).Send($Ip, 2000).Status -eq 'Success' } catch { $false }
}
function Test-SrAwake { Test-SrPing $Cfg.TARGET }

# Set TARGET to whichever address answers (home first, then the VPN address). $false if neither.
function Find-SrTarget {
    if (Test-SrPing $Cfg.MACHINE_IP) { $Cfg.TARGET = $Cfg.MACHINE_IP; return $true }
    if ($Cfg.REMOTE_MACHINE_IP -and (Test-SrPing $Cfg.REMOTE_MACHINE_IP)) { $Cfg.TARGET = $Cfg.REMOTE_MACHINE_IP; return $true }
    $false
}

# Is the Steam Machine on a network this PC is plugged straight into (not through a VPN)?
# Wake-on-LAN only works then. VPN adapters (WireGuard, Tailscale...) aren't hardware.
function Test-SrHomeNetwork {
    try {
        $route = Find-NetRoute -RemoteIPAddress $Cfg.MACHINE_IP -ErrorAction Stop | Where-Object { $null -ne $_.NextHop } | Select-Object -First 1
        if (-not $route -or ($route.NextHop -ne '0.0.0.0')) { return $false }
        [bool](Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction Stop).HardwareInterface
    } catch { $false }
}

function Test-SrPort([int]$Port) {
    $client = New-Object Net.Sockets.TcpClient
    try { $client.ConnectAsync($Cfg.TARGET, $Port).Wait(1500) -and $client.Connected }
    catch { $false }
    finally { $client.Dispose() }
}

# Wake-on-LAN magic packet: 6 x 0xFF, then the MAC 16 times, to UDP port 9.
function Send-SrWake([string]$Mac) {
    $bytes = $Mac -split ':' | ForEach-Object { [Convert]::ToByte($_, 16) }
    $packet = [byte[]](,0xFF * 6 + ($bytes * 16))
    $udp = New-Object Net.Sockets.UdpClient
    try {
        $udp.EnableBroadcast = $true
        foreach ($addr in @('255.255.255.255', $Cfg.BROADCAST)) {
            for ($i = 0; $i -lt 3; $i++) { [void]$udp.Send($packet, $packet.Length, $addr, 9) }
        }
    } finally { $udp.Close() }
}

# Find the Steam Machine (home address first, then its VPN address) and make sure SSH
# answers, waking it with Wake-on-LAN if this PC is at home. Sets $Cfg.TARGET.
function Wait-SrAwake([switch]$Quiet) {
    if (-not $Quiet) { Write-SrInfo 'Checking the Steam Machine is awake' }
    if (Find-SrTarget) {
        if (-not $Quiet) {
            if ($Cfg.TARGET -ne $Cfg.MACHINE_IP) { Write-SrInfo "Awake (through the VPN, at $($Cfg.TARGET))" }
            elseif (-not (Test-SrHomeNetwork)) { Write-SrInfo 'Awake (through the VPN)' }
            else { Write-SrInfo 'Awake' }
        }
        return
    }
    if (-not (Test-SrHomeNetwork)) {
        if ($Cfg.REMOTE_MODE -eq 'off') { Stop-SrError "Can't reach $($Cfg.MACHINE_IP). Is this PC on your home network? (Remote access is off: see docs/remote-access.md.)" }
        Stop-SrError "Can't reach the Steam Machine. Away from home? Connect your VPN first. It also has to be awake: Wake-on-LAN only works from your home network (see docs/remote-access.md)."
    }
    $Cfg.TARGET = $Cfg.MACHINE_IP
    $mac = $Cfg.MACHINE_MAC
    if (-not $mac -and (Test-Path -LiteralPath $SrMacCache)) { $mac = (Get-Content -LiteralPath $SrMacCache -TotalCount 1).Trim() }
    if (-not (Test-SrMac $mac)) {
        Stop-SrError "No reply from $($Cfg.MACHINE_IP) and its network address (MAC) isn't known yet. Wake it by hand this once; it's learned on every successful connection."
    }
    Write-SrInfo "Asleep or off: sending a Wake-on-LAN signal to $mac"
    Send-SrWake $mac
    $deadline = (Get-Date).AddSeconds([int]$Cfg.WAKE_TIMEOUT)
    $resend = (Get-Date).AddSeconds(10)
    while (-not (Test-SrAwake) -and (Get-Date) -lt $deadline) {
        # Wake packets are UDP and can get lost, so send another every 10 seconds.
        if ((Get-Date) -ge $resend) { Send-SrWake $mac; $resend = (Get-Date).AddSeconds(10) }
        Start-Sleep -Seconds 1
    }
    if (-not (Test-SrAwake)) { Stop-SrError "No reply $($Cfg.WAKE_TIMEOUT) seconds after the wake signal. If it was shut down (not asleep), press its power button. See docs/troubleshooting.md." }
    Write-SrInfo 'Awake. Waiting for SSH'
    $deadline = (Get-Date).AddSeconds(60)
    while (-not (Test-SrPort 22) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
    if (-not (Test-SrPort 22)) { Stop-SrError "It woke up, but SSH didn't answer within 60 seconds." }
}

# Remember the Steam Machine's MAC (from Windows' own neighbour table) for Wake-on-LAN.
function Save-SrMac {
    if ($Cfg.TARGET -ne $Cfg.MACHINE_IP -or -not (Test-SrHomeNetwork)) { return }
    try {
        $n = Get-NetNeighbor -IPAddress $Cfg.MACHINE_IP -ErrorAction Stop |
             Where-Object { $_.LinkLayerAddress -match '^([0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2}$' -and $_.LinkLayerAddress -ne '00-00-00-00-00-00' } |
             Select-Object -First 1
        if ($n) {
            $mac = $n.LinkLayerAddress.Replace('-', ':').ToLower()
            New-Item -ItemType Directory -Force -Path $SrConfigDir | Out-Null
            Set-Content -LiteralPath $SrMacCache -Value $mac -Encoding ASCII
        }
    } catch { }
}

function Get-SrMoonlight {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Moonlight Game Streaming\Moonlight.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Moonlight Game Streaming\Moonlight.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Moonlight Game Streaming\Moonlight.exe')
    )
    foreach ($p in $candidates) { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
    $cmd = Get-Command Moonlight.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Test-SrSsh {
    foreach ($exe in 'ssh.exe', 'scp.exe', 'ssh-keygen.exe') {
        if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) {
            Stop-SrError "The OpenSSH client ($exe) is missing. Settings > System > Optional features > Add `"OpenSSH Client`", then try again."
        }
    }
}

# Bash scripts must reach the Steam Machine with Unix line endings.
function Copy-SrUnixFile([string]$Source, [string]$Destination) {
    $text = [IO.File]::ReadAllText($Source) -replace "`r`n", "`n"
    [IO.File]::WriteAllText($Destination, $text, (New-Object Text.UTF8Encoding $false))
}

function Write-SrTextFile([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
}
