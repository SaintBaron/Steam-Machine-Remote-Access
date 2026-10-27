# steam-pair.ps1: set Sunshine's web UI login and pair Moonlight, from PowerShell.
# https://github.com/SaintBaron/Steam-Machine-Remote-Access
#
# Run "steam-connect.ps1 -NoStream" in another window first: it starts Sunshine and
# opens the tunnel this talks through (https://localhost:47990 by default).
#
#   steam-pair.ps1 -Login    create the web UI login (or change it)
#   steam-pair.ps1           pair Moonlight with Sunshine
param([switch]$Login, [switch]$Version)

. (Join-Path $PSScriptRoot 'common.ps1')
if ($Version) { "steam-pair $SrVersion"; exit 0 }
$Cfg = Read-SrConfigFile $SrConfig
if (-not $Cfg.CLIENT_NAME) { $Cfg.CLIENT_NAME = $env:COMPUTERNAME }
$Url = "https://localhost:$($Cfg.WEBUI_PORT)"

# Only send the web UI password into steam-connect's own SSH tunnel. Anything else
# listening on that local port would see it.
$listeners = @(Get-NetTCPConnection -State Listen -LocalPort ([int]$Cfg.WEBUI_PORT) -ErrorAction SilentlyContinue)
if ($listeners.Count -eq 0) { Stop-SrError 'steam-connect isn''t connected. Run steam-connect.ps1 -NoStream in another window first.' }
foreach ($l in $listeners) {
    $p = Get-Process -Id $l.OwningProcess -ErrorAction SilentlyContinue
    if (-not $p -or $p.ProcessName -ne 'ssh') { Stop-SrError "Port $($Cfg.WEBUI_PORT) is held by another program, not the SSH tunnel. Not sending the password." }
}

# Sunshine uses a self-signed certificate. The connection only reaches this PC's end of
# the SSH tunnel, which is already encrypted and authenticated, so the certificate is
# accepted for localhost only.
$IsLegacy = $PSVersionTable.PSVersion.Major -lt 6
if ($IsLegacy) {
    if (-not ('SrLocalhostTrust' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class SrLocalhostTrust {
    public static bool Check(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors) {
        if (errors == SslPolicyErrors.None) return true;
        HttpWebRequest r = sender as HttpWebRequest;
        return r != null && r.RequestUri.Host == "localhost";
    }
}
'@
    }
    [Net.ServicePointManager]::ServerCertificateValidationCallback =
        [Delegate]::CreateDelegate([Net.Security.RemoteCertificateValidationCallback], [SrLocalhostTrust], 'Check')
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

function Invoke-Sunshine([string]$Method, [string]$Path, [string]$Auth, $Body, [int]$Timeout = 10) {
    $p = @{ Method = $Method; Uri = "$Url$Path"; TimeoutSec = $Timeout; Headers = @{} }
    if ($Auth) { $p.Headers['Authorization'] = "Basic $Auth" }
    if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Compress); $p.ContentType = 'application/json' }
    if (-not $IsLegacy) { $p.SkipCertificateCheck = $true }
    Invoke-RestMethod @p
}
function Get-StatusCode($Err) { try { [int]$Err.Exception.Response.StatusCode } catch { 0 } }
function ConvertTo-Basic([string]$User, [string]$Pass) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${User}:$Pass")) }
function Read-Secret([string]$Prompt) {
    $s = Read-Host -Prompt $Prompt -AsSecureString
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}
function Stop-Unreachable($Err) { Stop-SrError "Can't reach Sunshine at $Url ($($Err.Exception.Message)). Run steam-connect.ps1 -NoStream in another window first." }

if ($Login) {
    $user = Read-Host 'Web UI username [sunshine]'; if (-not $user) { $user = 'sunshine' }
    while ($true) {
        $p1 = Read-Secret 'New web UI password'
        if ($p1.Length -lt 8) { Write-Host 'Use at least 8 characters.'; continue }
        if ($p1 -ne (Read-Secret 'Same password again')) { Write-Host "They didn't match. Try again."; continue }
        break
    }
    $body = @{ newUsername = $user; newPassword = $p1; confirmNewPassword = $p1 }
    try {
        $r = Invoke-Sunshine POST '/api/password' $null $body   # first time: no login exists yet
    } catch {
        $code = Get-StatusCode $_
        if ($code -eq 0) { Stop-Unreachable $_ }
        if ($code -ne 401) { Stop-SrError "Sunshine answered with HTTP $code" }
        Write-SrInfo 'A web UI login already exists. To change it, enter the current one.'
        $cu = Read-Host 'Current username [sunshine]'; if (-not $cu) { $cu = 'sunshine' }
        $cp = Read-Secret 'Current password'
        $body.currentUsername = $cu; $body.currentPassword = $cp
        try { $r = Invoke-Sunshine POST '/api/password' (ConvertTo-Basic $cu $cp) $body }
        catch { if ((Get-StatusCode $_) -eq 401) { Stop-SrError 'Wrong current username or password.' } else { Stop-SrError $_.Exception.Message } }
    }
    if ($r.status -eq $true) { Write-SrInfo "Web UI login set. Username: $user" } else { Stop-SrError "Sunshine didn't accept it: $($r | ConvertTo-Json -Compress)" }
    exit 0
}

# Pair
$user = Read-Host 'Web UI username [sunshine]'; if (-not $user) { $user = 'sunshine' }
$auth = ConvertTo-Basic $user (Read-Secret 'Web UI password')
try { $waiting = @((Invoke-Sunshine GET '/api/pin' $auth $null).pairings) }
catch {
    $code = Get-StatusCode $_
    if ($code -eq 0) { Stop-Unreachable $_ }
    if ($code -eq 401) { Stop-SrError 'Wrong username or password (no login yet? run: steam-pair.ps1 -Login).' }
    Stop-SrError "Sunshine answered with HTTP $code"
}
$waiting = @($waiting | Where-Object { $_ })
Write-SrInfo 'Logged in to Sunshine'

if ($waiting.Count -eq 0) {
    $hostIp = if ($Cfg.MACHINE_IP) { $Cfg.MACHINE_IP } else { "the Steam Machine's IP" }
    Write-SrInfo "In Moonlight, add $hostIp with the + button if it isn't listed, then click it."
    Write-SrInfo 'Moonlight shows a 4-digit PIN. Leave that dialog open.'
    $deadline = (Get-Date).AddMinutes(2)
    while ($waiting.Count -eq 0 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2; Write-Host '.' -NoNewline
        $waiting = @(@((Invoke-Sunshine GET '/api/pin' $auth $null).pairings) | Where-Object { $_ })
    }
    Write-Host ''
    if ($waiting.Count -eq 0) { Stop-SrError 'No pairing request arrived within 2 minutes. Click the host in Moonlight, then run steam-pair.ps1 again.' }
}

$request = $waiting[0]
if ($waiting.Count -gt 1) {
    Write-SrInfo 'More than one pairing request is waiting:'
    for ($i = 0; $i -lt $waiting.Count; $i++) { Write-Host "  $($i + 1). $($waiting[$i].name) from $($waiting[$i].address)" }
    $choice = Read-Host 'Which one? [1]'; if (-not $choice) { $choice = '1' }
    if ($choice -notmatch '^[0-9]+$' -or [int]$choice -lt 1 -or [int]$choice -gt $waiting.Count) { Stop-SrError 'Not a valid choice.' }
    $request = $waiting[[int]$choice - 1]
}
Write-SrInfo "Pairing request from $($request.address)"
$pin = (Read-Host 'PIN shown in Moonlight').Trim()
if ($pin -notmatch '^[0-9]{4}$') { Stop-SrError 'The PIN must be exactly 4 digits.' }
Write-SrInfo 'Pairing...'
try { $r = Invoke-Sunshine POST '/api/pin' $auth @{ pairing_id = $request.id; pin = $pin; name = $Cfg.CLIENT_NAME } 60 }
catch { Stop-SrError "Sunshine rejected it: $($_.Exception.Message)" }
if ($r.status -eq $true) { Write-SrInfo "Paired as '$($Cfg.CLIENT_NAME)'. Moonlight should now unlock the host." }
else { Stop-SrError 'Pairing failed: wrong PIN, or Moonlight timed out. Click the host again and rerun steam-pair.ps1.' }
