# steam-remote-setup.ps1: set up (or change) Steam Machine Remote Access from this Windows PC.
# https://github.com/SaintBaron/Steam-Machine-Remote-Access
#
#   steam-remote-setup.ps1                               first-time setup, or re-run it safely
#   steam-remote-setup.ps1 displays                      choose the stream and TV outputs again
#   steam-remote-setup.ps1 check                         report problems on the Steam Machine
#   steam-remote-setup.ps1 update-server                 send this version's server script and apply it
#   steam-remote-setup.ps1 add-client IP C:\path\key.pub allow another PC (its IP and public key)
#   steam-remote-setup.ps1 remove-client IP              stop allowing a PC
#   steam-remote-setup.ps1 remote                        choose remote access (outside your home, through a VPN)
#   steam-remote-setup.ps1 remote off                    turn remote access off for every PC
#   steam-remote-setup.ps1 uninstall-server              remove everything from the Steam Machine
param([string]$Command = '', [string]$Ip = '', [string]$KeyPath = '', [switch]$Pause, [switch]$Version)

. (Join-Path $PSScriptRoot 'common.ps1')
if ($Version) { "steam-remote-setup $SrVersion"; exit 0 }
if ($Pause) { $env:STEAM_REMOTE_PAUSE = '1' }
$ServerSrc = Join-Path $SrHome 'server\steam-remote-server.sh'
$MarkBegin = '# >>> steam-machine-remote >>>'
$MarkEnd   = '# <<< steam-machine-remote <<<'
$SshDir    = Join-Path $HOME '.ssh'
$SshConfig = Join-Path $SshDir 'config'

function Read-Default([string]$Prompt, [string]$Default) {
    $r = Read-Host "$Prompt [$Default]"
    if ($r) { $r } else { $Default }
}

function Save-SrConfig($c) {
    New-Item -ItemType Directory -Force -Path $SrConfigDir | Out-Null
    $key = $c.KEY_FILE.Replace($HOME, '~').Replace('\', '/')
    Write-SrTextFile $SrConfig @"
# Steam Machine Remote Access: this PC's settings. Plain KEY="value" lines; they're read,
# not run. Re-run the setup after changing MACHINE_IP, MACHINE_USER or HOST_ALIAS.

# The Steam Machine's fixed IP (set a DHCP reservation for it in your router).
MACHINE_IP="$($c.MACHINE_IP)"
# The account on the Steam Machine (SteamOS uses "deck").
MACHINE_USER="$($c.MACHINE_USER)"
# The name used for it in your SSH config, so "ssh $($c.HOST_ALIAS)" works.
HOST_ALIAS="$($c.HOST_ALIAS)"
# The SSH key used for it.
KEY_FILE="$key"

# Remote access from outside your home (docs/remote-access.md). Change it with:
#   steam-remote-setup.ps1 remote
# REMOTE_MODE: off (home network only), router, tailscale or other.
REMOTE_MODE="$($c.REMOTE_MODE)"
# This PC's address on the VPN (the Steam Machine allows it).
REMOTE_PC_IP="$($c.REMOTE_PC_IP)"
# The Steam Machine's address on the VPN, if it's not reachable at MACHINE_IP (Tailscale).
REMOTE_MACHINE_IP="$($c.REMOTE_MACHINE_IP)"

# Wake-on-LAN. The MAC is learned automatically; set it only to override.
MACHINE_MAC="$($c.MACHINE_MAC)"
# Leave empty to use the .255 address of a /24 home network (e.g. 192.168.0.255).
BROADCAST="$($c.BROADCAST)"
# Seconds to wait for it to wake up.
WAKE_TIMEOUT="$($c.WAKE_TIMEOUT)"

# The Sunshine app Moonlight opens ("Desktop" streams the whole screen).
MOONLIGHT_APP="$($c.MOONLIGHT_APP)"
# Name this PC is given in Sunshine's paired-devices list (empty = computer name).
CLIENT_NAME="$($c.CLIENT_NAME)"
# Local port for the web UI tunnel: https://localhost:$($c.WEBUI_PORT)
WEBUI_PORT="$($c.WEBUI_PORT)"

# Work around Sunshine's Game Mode black-screen bug (2026.906+). yes or no.
BLACK_SCREEN_FIX="$($c.BLACK_SCREEN_FIX)"
"@
}

function Invoke-ConfigWizard {
    Write-SrInfo "Step 1 of 7: this PC's settings ($SrConfig)"
    $c = Read-SrConfigFile $SrConfig
    if ((Test-SrIp $c.MACHINE_IP) -and (Read-Default "   Steam Machine $($c.MACHINE_USER)@$($c.MACHINE_IP), SSH name '$($c.HOST_ALIAS)'. Keep these? (y/n)" 'y') -match '^[Yy]') { return }
    do {
        $c.MACHINE_IP = Read-Default "   The Steam Machine's IP address (see the guide to find it)" $c.MACHINE_IP
        if (-not (Test-SrIp $c.MACHINE_IP)) { Write-Host '   That isn''t an IPv4 address like 192.168.0.50.' }
    } until (Test-SrIp $c.MACHINE_IP)
    $c.MACHINE_USER = Read-Default '   Its user name' $c.MACHINE_USER
    if ($c.MACHINE_USER -notmatch '^[a-z_][a-z0-9_-]*$') { Stop-SrError "'$($c.MACHINE_USER)' isn't a valid user name." }
    $c.HOST_ALIAS = Read-Default '   A short SSH name for it' $c.HOST_ALIAS
    if ($c.HOST_ALIAS -notmatch '^[A-Za-z0-9._-]+$') { Stop-SrError 'Use only letters, numbers, . _ - in the SSH name.' }
    Save-SrConfig $c
    Write-SrInfo "Saved $SrConfig (edit it any time; see the comments inside)"
}

function Test-OwnHostBlock {
    if (-not (Test-Path -LiteralPath $SshConfig)) { return $false }
    $skip = $false
    foreach ($line in Get-Content -LiteralPath $SshConfig) {
        if ($line -eq $MarkBegin) { $skip = $true; continue }
        if ($line -eq $MarkEnd) { $skip = $false; continue }
        if (-not $skip -and $line -match '^\s*Host\s+(.+)$' -and ($Matches[1] -split '\s+') -contains $Cfg.HOST_ALIAS) { return $true }
    }
    $false
}

function Invoke-SshSetup {
    Write-SrInfo 'Step 3 of 7: SSH key and SSH config'
    New-Item -ItemType Directory -Force -Path $SshDir | Out-Null
    $own = Test-OwnHostBlock
    if ($own) {
        Write-SrWarn "Your SSH config already has its own 'Host $($Cfg.HOST_ALIAS)' entry, so it's left as it is."
        Write-Host "   Make sure it has: HostName $($Cfg.MACHINE_IP), HostKeyAlias $($Cfg.HOST_ALIAS), User $($Cfg.MACHINE_USER), IdentityFile $($Cfg.KEY_FILE), IdentitiesOnly yes"
    }
    if (-not (Test-Path -LiteralPath $Cfg.KEY_FILE)) {
        Write-Host '   Creating an SSH key for the Steam Machine. Set a passphrase when asked: it''s one of'
        Write-Host '   the two things needed to log in, so don''t leave it empty.'
        & ssh-keygen.exe -t ed25519 -f $Cfg.KEY_FILE -C "steam-remote@$env:COMPUTERNAME"
        if ($LASTEXITCODE -ne 0) { Stop-SrError 'ssh-keygen failed.' }
    } else { Write-Host "   Using the existing key $($Cfg.KEY_FILE)" }
    # An empty argument reaches ssh-keygen as '""' in Windows PowerShell 5.1, but as '' in PowerShell 7.3+.
    $empty = if ($PSVersionTable.PSVersion -ge [version]'7.3') { '' } else { '""' }
    & ssh-keygen.exe -y -P $empty -f $Cfg.KEY_FILE *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-SrWarn "$($Cfg.KEY_FILE) has no passphrase, so anyone who copies that file only needs the password."
        Write-Host "   Add one now with: ssh-keygen -p -f `"$($Cfg.KEY_FILE)`""
    }
    if (-not (Test-Path -LiteralPath "$($Cfg.KEY_FILE).pub")) { Stop-SrError "$($Cfg.KEY_FILE).pub is missing. Recreate it with: ssh-keygen -y -f `"$($Cfg.KEY_FILE)`" > `"$($Cfg.KEY_FILE).pub`"" }

    if (-not $own) {
        $keyForConfig = $Cfg.KEY_FILE.Replace($HOME, '~').Replace('\', '/')
        $block = @($MarkBegin, '# Written by steam-remote-setup; it replaces this block when re-run.',
                   "Host $($Cfg.HOST_ALIAS)", "    HostName $($Cfg.MACHINE_IP)", "    HostKeyAlias $($Cfg.HOST_ALIAS)", "    User $($Cfg.MACHINE_USER)",
                   "    IdentityFile $keyForConfig", '    IdentitiesOnly yes', '    ServerAliveInterval 15',
                   '    ServerAliveCountMax 4', $MarkEnd, '')
        $rest = @()
        if (Test-Path -LiteralPath $SshConfig) {
            $skip = $false; $dropBlank = $false
            foreach ($line in Get-Content -LiteralPath $SshConfig) {
                if ($line -eq $MarkBegin) { $skip = $true; continue }
                if ($line -eq $MarkEnd) { $skip = $false; $dropBlank = $true; continue }
                if ($skip) { continue }
                if ($dropBlank -and $line -eq '') { $dropBlank = $false; continue }
                $dropBlank = $false; $rest += $line
            }
        }
        # Our block goes first: ssh uses the first value it finds for each setting.
        Write-SrTextFile $SshConfig ((($block + $rest) -join "`n") + "`n")
        Write-Host "   Added 'Host $($Cfg.HOST_ALIAS)' to $SshConfig"
    }
}

function Invoke-ServerSetup {
    Write-SrInfo 'Step 4 of 7: reach the Steam Machine'
    if (-not (Find-SrTarget)) { Stop-SrError "No reply from $($Cfg.MACHINE_IP). Check it's on, awake and wired, and that SSH is on (Part 2 of the guide)." }
    if ($Cfg.TARGET -ne $Cfg.MACHINE_IP) { Write-SrInfo "Using its VPN address, $($Cfg.TARGET)" }
    if (-not (Test-SrPort 22)) { Stop-SrError "$($Cfg.TARGET) answers but SSH doesn't. At the Steam Machine run: sudo systemctl enable --now sshd" }
    Save-SrMac
    $hostOpt = "HostName=$($Cfg.TARGET)"

    Write-SrInfo 'Step 5 of 7: copy the setup to the Steam Machine'
    & ssh-keygen.exe -F $Cfg.HOST_ALIAS *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host '   First connection: SSH shows the Steam Machine''s fingerprint (SHA256:...) and asks'
        Write-Host '   "Are you sure you want to continue connecting?". Compare it with the fingerprint you'
        Write-Host '   noted at the Steam Machine. Type yes ONLY if they match exactly; otherwise type no'
        Write-Host '   and see docs/security.md.'
    }
    Write-Host "   Log in with the $($Cfg.MACHINE_USER) password (and your key passphrase, if asked)."
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("steam-remote-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        Copy-SrUnixFile $ServerSrc (Join-Path $tmp 'steam-remote-server.sh')
        Copy-SrUnixFile "$($Cfg.KEY_FILE).pub" (Join-Path $tmp 'steam-remote-client.pub')
        & scp.exe -q -o $hostOpt (Join-Path $tmp 'steam-remote-server.sh') (Join-Path $tmp 'steam-remote-client.pub') "$($Cfg.HOST_ALIAS):"
        if ($LASTEXITCODE -ne 0) { Stop-SrError "Couldn't copy the files. Check the password, and that this PC's IP hasn't changed." }
    } finally { Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue }

    Write-SrInfo 'Step 6 of 7: set up the Steam Machine'
    Write-Host "   Log in again, then sudo asks for the $($Cfg.MACHINE_USER) password once more."
    # ${SSH_CLIENT%% *} expands on the Steam Machine: the IP it sees for this PC.
    # Through a VPN, the address it sees is the VPN one, which is added as a remote address instead.
    $cmd = if (($Cfg.TARGET -eq $Cfg.MACHINE_IP) -and (Test-SrHomeNetwork)) { 'sudo bash ~/steam-remote-server.sh --setup --client-ip ${SSH_CLIENT%% *}' }
           else { 'sudo bash ~/steam-remote-server.sh --setup' }
    $cmd += ' --pubkey ~/steam-remote-client.pub' + (Get-RemoteArgs) + '; rc=$?; rm -f ~/steam-remote-server.sh ~/steam-remote-client.pub; exit $rc'
    & ssh.exe -t -o $hostOpt $Cfg.HOST_ALIAS $cmd
    if ($LASTEXITCODE -ne 0) { Stop-SrError "The Steam Machine setup didn't finish. Read its messages above; it's safe to run the setup again." }

    Write-SrInfo 'Step 7 of 7: check a fresh login needs your key AND the password'
    & ssh.exe -o $hostOpt $Cfg.HOST_ALIAS 'echo "   key and password accepted"'
    if ($LASTEXITCODE -ne 0) { Stop-SrError 'That login failed. See docs/troubleshooting.md (Login problems).' }
    Write-SrInfo 'Setup complete.'
    Write-Host @'

   Next:
     1. Start menu > "Steam Machine - Connect (no stream)", or:  steam-connect.ps1 -NoStream
     2. In another PowerShell window:
          steam-pair.ps1 -Login     (create Sunshine's web UI login)
          steam-pair.ps1            (pair Moonlight; follow the prompts)
     3. Press Q in the first window. From now on, just use "Steam Machine - Connect".
'@
}

function Invoke-RemoteSudo([string]$ServerArgs) {
    Import-SrConfig
    Wait-SrAwake -Quiet
    & ssh.exe -t -o "HostName=$($Cfg.TARGET)" $Cfg.HOST_ALIAS "sudo $SrServer $ServerArgs"
}

# ------------------------------------------------------------------ remote access
$script:RemoteAdd = ''; $script:RemoteDel = ''
function Read-OptionalIp([string]$Prompt, [string]$Default) {
    while ($true) {
        $v = Read-Host "$Prompt [$Default]"
        if (-not $v) { $v = $Default }
        if (-not $v) { return '' }
        if (Test-SrIp $v) { return $v }
        Write-Host '   That isn''t an IPv4 address (like 10.6.0.2).'
    }
}
function Invoke-RemoteWizard {
    $c = Read-SrConfigFile $SrConfig
    $oldPc = if (Test-SrIp $c.REMOTE_PC_IP) { $c.REMOTE_PC_IP } else { '' }
    $current = switch ($c.REMOTE_MODE) { 'router' { '2' } 'tailscale' { '3' } 'other' { '4' } default { '1' } }
    Write-SrInfo 'Step 2 of 7: remote access (optional)'
    Write-Host '   By default only your home network can connect. You can also let this PC connect'
    Write-Host '   from elsewhere, through a VPN. Nothing is ever opened to the internet directly.'
    Write-Host '   How each option works and how to set it up: docs/remote-access.md'
    Write-Host ''
    Write-Host '     1) No, home network only            Nothing else to set up (default)'
    Write-Host '     2) Yes, through a VPN on my router  WireGuard or OpenVPN on the router, UniFi Teleport...'
    Write-Host '     3) Yes, through Tailscale           Tailscale on this PC and on the Steam Machine'
    Write-Host '     4) Yes, through another VPN         You enter the addresses yourself'
    Write-Host ''
    Write-Host '   Away from home, the Steam Machine must already be awake: Wake-on-LAN only works at home.'
    do { $choice = Read-Default '   Choose 1, 2, 3 or 4' $current } until ($choice -match '^[1-4]$')
    # Offer the old addresses as defaults only when keeping the same kind of VPN.
    if ($choice -ne $current) { $c.REMOTE_PC_IP = ''; $c.REMOTE_MACHINE_IP = '' }
    switch ($choice) {
        '1' { $c.REMOTE_MODE = 'off'; $c.REMOTE_PC_IP = ''; $c.REMOTE_MACHINE_IP = '' }
        '2' {
            $c.REMOTE_MODE = 'router'; $c.REMOTE_MACHINE_IP = ''
            Write-Host '   This PC''s address on your router''s VPN is shown in the VPN app once connected, or in'
            Write-Host '   the router''s list of VPN clients. Give it a fixed address there if you can.'
            $c.REMOTE_PC_IP = Read-OptionalIp "   This PC's VPN address (Enter to add it later)" $c.REMOTE_PC_IP
        }
        '3' {
            $c.REMOTE_MODE = 'tailscale'
            $ts = ''
            if (Get-Command tailscale.exe -ErrorAction SilentlyContinue) { $ts = (& tailscale.exe ip -4 2>$null | Select-Object -First 1) }
            Write-Host '   Tailscale addresses start with 100. Find them in the Tailscale app on each device,'
            Write-Host '   or on the Machines page of the Tailscale admin console.'
            $def = if ($c.REMOTE_PC_IP) { $c.REMOTE_PC_IP } else { "$ts".Trim() }
            $c.REMOTE_PC_IP = Read-OptionalIp "   This PC's Tailscale address (Enter to add it later)" $def
            $c.REMOTE_MACHINE_IP = Read-OptionalIp "   The Steam Machine's Tailscale address (Enter to add it later)" $c.REMOTE_MACHINE_IP
        }
        '4' {
            $c.REMOTE_MODE = 'other'
            $c.REMOTE_PC_IP = Read-OptionalIp "   This PC's address on the VPN (Enter to add it later)" $c.REMOTE_PC_IP
            Write-Host '   If the Steam Machine has its own address on that VPN, enter it. If the VPN reaches'
            Write-Host '   your home network (like a router VPN does), leave it empty.'
            $c.REMOTE_MACHINE_IP = Read-OptionalIp "   The Steam Machine's VPN address (Enter if none)" $c.REMOTE_MACHINE_IP
        }
    }
    $script:RemoteAdd = ''; $script:RemoteDel = ''
    if ($oldPc -and $oldPc -ne $c.REMOTE_PC_IP) { $script:RemoteDel = $oldPc }
    if ($c.REMOTE_PC_IP) { $script:RemoteAdd = $c.REMOTE_PC_IP }
    if ($c.REMOTE_MODE -ne 'off' -and -not $c.REMOTE_PC_IP) {
        Write-SrWarn 'Remote access stays off for this PC until you add its VPN address: steam-remote-setup.ps1 remote'
    }
    Save-SrConfig $c
}
function Get-RemoteArgs {
    $a = ''
    if ($script:RemoteDel) { $a += " --remote-remove $($script:RemoteDel)" }
    if ($script:RemoteAdd) { $a += " --remote-add $($script:RemoteAdd)" }
    $a
}

Test-SrSsh
switch ($Command) {
    '' {
        if (-not (Test-Path -LiteralPath $ServerSrc)) { Stop-SrError "Can't find $ServerSrc. Run install.ps1 again." }
        if (-not (Get-SrMoonlight)) { Write-SrWarn "Moonlight isn't installed yet. You'll need it to stream (see the guide)." }
        Invoke-ConfigWizard
        Invoke-RemoteWizard
        Import-SrConfig
        Invoke-SshSetup
        Invoke-ServerSetup
    }
    'displays' { Invoke-RemoteSudo '--displays' }
    'remote' {
        if ($Ip -eq 'off') {
            Write-Host 'This turns remote access off for every PC (home network only).'
            if ((Read-Default 'Continue? (y/n)' 'y') -match '^[Yy]') {
                Invoke-RemoteSudo '--set-remote off'
                $c = Read-SrConfigFile $SrConfig; $c.REMOTE_MODE = 'off'; $c.REMOTE_PC_IP = ''; $c.REMOTE_MACHINE_IP = ''; Save-SrConfig $c
            }
        } else {
            Invoke-RemoteWizard
            $ra = Get-RemoteArgs
            if ($ra) { Invoke-RemoteSudo $ra.Trim() } else { Write-SrInfo 'Nothing to change on the Steam Machine.' }
        }
    }
    'check' { Import-SrConfig; Wait-SrAwake -Quiet; & ssh.exe -o "HostName=$($Cfg.TARGET)" $Cfg.HOST_ALIAS "$SrServer --check" }
    'update-server' {
        Import-SrConfig
        Wait-SrAwake -Quiet
        $tmp = Join-Path ([IO.Path]::GetTempPath()) 'steam-remote-server.sh'
        Copy-SrUnixFile $ServerSrc $tmp
        & scp.exe -q -o "HostName=$($Cfg.TARGET)" $tmp "$($Cfg.HOST_ALIAS):steam-remote-server.sh"
        Remove-Item -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
        if ($LASTEXITCODE -ne 0) { Stop-SrError 'Copy failed.' }
        & ssh.exe -t -o "HostName=$($Cfg.TARGET)" $Cfg.HOST_ALIAS "sudo install -o root -g root -m 755 ~/steam-remote-server.sh $SrServer && rm -f ~/steam-remote-server.sh && sudo $SrServer"
    }
    'add-client' {
        if (-not (Test-SrIp $Ip) -or -not (Test-Path -LiteralPath $KeyPath)) { Stop-SrError 'Usage: steam-remote-setup.ps1 add-client IP C:\path\to\key.pub   (the other PC''s fixed IP and its public key file)' }
        if ((Get-Content -LiteralPath $KeyPath -TotalCount 1) -notmatch '^(ssh-|ecdsa-|sk-)') { Stop-SrError "$KeyPath doesn't look like an SSH public key (.pub)." }
        Import-SrConfig
        Wait-SrAwake -Quiet
        $tmp = Join-Path ([IO.Path]::GetTempPath()) 'steam-remote-client.pub'
        Copy-SrUnixFile $KeyPath $tmp
        & scp.exe -q -o "HostName=$($Cfg.TARGET)" $tmp "$($Cfg.HOST_ALIAS):steam-remote-client.pub"
        Remove-Item -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
        & ssh.exe -t -o "HostName=$($Cfg.TARGET)" $Cfg.HOST_ALIAS "sudo $SrServer --add-client $Ip --pubkey ~/steam-remote-client.pub; rm -f ~/steam-remote-client.pub"
    }
    'remove-client' { if (-not (Test-SrIp $Ip)) { Stop-SrError 'Usage: steam-remote-setup.ps1 remove-client IP' }; Invoke-RemoteSudo "--remove-client $Ip" }
    'uninstall-server' {
        Write-Host 'This removes everything from the Steam Machine, uninstalls Sunshine and turns SSH off.'
        if ((Read-Default 'Continue? (y/n)' 'n') -match '^[Yy]') { Invoke-RemoteSudo '--uninstall' }
    }
    default { Stop-SrError "Unknown command '$Command'. Commands: displays, remote, check, update-server, add-client, remove-client, uninstall-server" }
}
if ($env:STEAM_REMOTE_PAUSE) { Read-Host 'Press Enter to close this window' | Out-Null }
