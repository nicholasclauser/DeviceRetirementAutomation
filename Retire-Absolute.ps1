# Retire-Absolute.ps1
# looks up devices in Absolute by hostname or serial, unenrolls if active
# usage:
#   .\Retire-Absolute.ps1 -TestAuthOnly
#   .\Retire-Absolute.ps1 -CsvPath ..\ToBeRetired\batch.csv

[CmdletBinding()]
param(
    [string]$CsvPath,
    [string]$EnvPath,
    [string]$OutputDir,
    [bool]$PreviewOnly = $true,
    [switch]$TestAuthOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir '_shared.ps1')

if (-not $EnvPath) { $EnvPath = Join-Path (Split-Path $scriptDir -Parent) '.env' }

# grab credentials from secretstore
$tokenId     = Get-Secret -Name AbsoluteTokenId     -AsPlainText -ErrorAction Stop
$tokenSecret = Get-Secret -Name AbsoluteTokenSecret -AsPlainText -ErrorAction Stop

$cfg     = Get-DotEnv -Path $EnvPath
$apiBase = if ($cfg['ABSOLUTE_API_BASE']) { $cfg['ABSOLUTE_API_BASE'].TrimEnd('/') } else { 'https://api.absolute.com' }

if (-not $OutputDir -and $cfg['OUTPUT_DIR']) { $OutputDir = $cfg['OUTPUT_DIR'] }
if (-not $OutputDir) { $OutputDir = Join-Path (Split-Path $scriptDir -Parent) 'out' }

$extraSkipPatterns = if ($cfg['EXTRA_SKIP_PATTERNS']) {
    $cfg['EXTRA_SKIP_PATTERNS'] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
} else { @() }


# --- JWS token builder (Absolute v3 auth, HS256) ---

function New-JwsToken {
    param([string]$Method, [string]$Uri, [string]$QueryString = '', [hashtable]$Body = @{})

    $header = [ordered]@{
        alg             = 'HS256'
        kid             = $tokenId
        method          = $Method.ToUpper()
        'content-type'  = 'application/json'
        uri             = $Uri
        'query-string'  = $QueryString
        issuedAt        = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) + 30000
    }

    $payload = if ($Method.ToUpper() -eq 'GET') { @{} } else { @{ data = $Body } }

    function B64U ([string]$t) {
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($t)).TrimEnd('=').Replace('+','-').Replace('/','_')
    }

    $h = B64U ($header  | ConvertTo-Json -Compress)
    $p = B64U ($payload | ConvertTo-Json -Compress | ForEach-Object { [regex]::Unescape($_) })
    $s = [Convert]::ToBase64String(
        [Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($tokenSecret)).ComputeHash(
            [Text.Encoding]::UTF8.GetBytes("$h.$p")
        )
    ).TrimEnd('=').Replace('+','-').Replace('/','_')

    return "$h.$p.$s"
}


# --- api helpers ---

function Invoke-AbsoluteApi {
    param([string]$Method = 'GET', [string]$Path, [hashtable]$QueryParams = @{}, [hashtable]$Body = @{})

    $qs = ($QueryParams.GetEnumerator() | Sort-Object Key | ForEach-Object {
        "$([uri]::EscapeDataString($_.Key))=$([uri]::EscapeDataString($_.Value))"
    }) -join '&'

    for ($i = 1; $i -le 3; $i++) {
        try {
            $r = Invoke-WebRequest -Uri "$apiBase/jws/validate" -Method POST `
                -Body (New-JwsToken -Method $Method -Uri $Path -QueryString $qs -Body $Body) `
                -ContentType 'text/plain' -UseBasicParsing -SkipHttpErrorCheck -ErrorAction Stop

            if ($r.StatusCode -in 200,202) { return ($r.Content | ConvertFrom-Json) }
            if ($r.StatusCode -eq 403 -and $i -lt 3) { Start-Sleep -Milliseconds 500; continue }
            Write-Warning "Absolute $Method $Path -> HTTP $($r.StatusCode)"
            return $null
        }
        catch { Write-Warning "Absolute $Method $Path -> $($_.Exception.Message)"; return $null }
    }
}

function Find-AbsoluteDevice {
    param([string]$Hostname, [string]$SerialNumber)

    $sel = 'deviceUid,esn,deviceName,agentStatus,lastUpdatedDateTimeUtc'

    if ($Hostname) {
        $r = Invoke-AbsoluteApi -Method GET -Path '/v3/reporting/devices' -QueryParams @{ deviceName = $Hostname; select = $sel; pageSize = '10' }
        if ($r -and $r.PSObject.Properties['data']) {
            $m = @($r.data) | Where-Object { $_.deviceName -ieq $Hostname } | Select-Object -First 1
            if ($m) { return $m }
        }
    }

    if ($SerialNumber) {
        $r = Invoke-AbsoluteApi -Method GET -Path '/v3/reporting/devices' -QueryParams @{ esn = $SerialNumber; select = $sel; pageSize = '10' }
        if ($r -and $r.PSObject.Properties['data']) {
            $m = @($r.data) | Where-Object { $_.esn -ieq $SerialNumber } | Select-Object -First 1
            if ($m) { return $m }
        }
    }

    return $null
}

function Invoke-AbsoluteUnenroll {
    param([string]$DeviceUid)

    $r = Invoke-AbsoluteApi -Method POST -Path '/v3/actions/requests/unenroll' `
        -Body @{ deviceUids = @($DeviceUid); excludeMissingDevices = $false }

    if ($r -and $r.PSObject.Properties['requestUid']) { return $r.requestUid }
    if ($r) { return ($r | ConvertTo-Json -Compress) }
    return $null
}


# --- test auth ---

if ($TestAuthOnly) {
    Write-Host "TestAuthOnly — Absolute" -ForegroundColor Cyan
    $r = Invoke-AbsoluteApi -Method GET -Path '/v3/reporting/devices' -QueryParams @{ pageSize = '1' }
    if ($r) { Write-Host "AUTH OK" -ForegroundColor Green; if ($r.PSObject.Properties['data'] -and @($r.data).Count -gt 0) { @($r.data)[0] | Format-List } }
    else    { Write-Host "AUTH FAILED" -ForegroundColor Red }
    exit
}


# --- main ---

if (-not $CsvPath)                               { Write-Error "CsvPath is required." }
if (-not (Test-Path -LiteralPath $CsvPath))      { Write-Error "CSV not found: $CsvPath" }
$rows = Import-Csv -LiteralPath $CsvPath
if (@($rows).Count -eq 0)                        { Write-Error "CSV is empty." }

$s0        = @($rows)[0]
$hasHost   = [bool]$s0.PSObject.Properties['Hostname']
$hasSerial = [bool]$s0.PSObject.Properties['SerialNumber']
if (-not $hasHost -and -not $hasSerial) { Write-Error "CSV needs Hostname and/or SerialNumber columns." }

if (-not (Test-Path -LiteralPath $OutputDir)) { New-Item -ItemType Directory -LiteralPath $OutputDir | Out-Null }
$script:logPath = Join-Path $OutputDir "Retirement-Absolute-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"

Write-Host "Retire-Absolute | $(@($rows).Count) devices | PreviewOnly=$PreviewOnly | Log: $script:logPath"

$stats = @{ Total=0; Whitelisted=0; Found=0; NotFound=0; Unenrolled=0; Errors=0 }

foreach ($row in $rows) {
    $hn = if ($hasHost)   { $row.Hostname.Trim()     } else { '' }
    $sn = if ($hasSerial) { $row.SerialNumber.Trim() } else { '' }
    $stats.Total++

    if (-not $hn -and -not $sn) {
        Write-RetirementLog -Hostname '' -SerialNumber '' -System 'Input' -Action 'Skip' -Status 'Error' -Detail 'Both empty'
        $stats.Errors++; continue
    }

    $lbl = if ($hn) { $hn } else { "serial:$sn" }
    Write-Host "[$($stats.Total)/$(@($rows).Count)] $lbl" -NoNewline

    if (Test-Whitelist -Hostname $hn -SerialNumber $sn -ExtraPatterns $extraSkipPatterns) {
        Write-Host '  WHITELISTED' -ForegroundColor Yellow
        Write-RetirementLog -Hostname $hn -SerialNumber $sn -System 'Whitelist' -Action 'Skip' -Status 'Skipped' -Detail 'Whitelist match'
        $stats.Whitelisted++; continue
    }

    try {
        $dev = Find-AbsoluteDevice -Hostname $hn -SerialNumber $sn

        if ($dev) {
            $uid = $dev.deviceUid
            Write-Host "  Found (status=$($dev.agentStatus))" -ForegroundColor Green

            if (-not $PreviewOnly -and $dev.agentStatus -iin @('A','Active')) {
                $reqUid = Invoke-AbsoluteUnenroll -DeviceUid $uid
                if ($reqUid) {
                    Write-Host "  Unenrolled (req=$reqUid)" -ForegroundColor Green
                    Write-RetirementLog -Hostname $hn -SerialNumber $sn -System 'Absolute' -Action 'Unenroll' -Status 'Done' -Detail "UID=$uid | Req=$reqUid"
                    $stats.Unenrolled++
                } else {
                    Write-Host "  Unenroll failed" -ForegroundColor Yellow
                    Write-RetirementLog -Hostname $hn -SerialNumber $sn -System 'Absolute' -Action 'Unenroll' -Status 'Error' -Detail "UID=$uid"
                    $stats.Errors++
                }
            } else {
                Write-RetirementLog -Hostname $hn -SerialNumber $sn -System 'Absolute' -Action 'Lookup' -Status 'Found' `
                    -Detail "UID=$uid | ESN=$($dev.esn) | Status=$($dev.agentStatus) | LastSeen=$($dev.lastUpdatedDateTimeUtc)"
                $stats.Found++
            }
        } else {
            Write-Host '  Not in Absolute' -ForegroundColor DarkGray
            Write-RetirementLog -Hostname $hn -SerialNumber $sn -System 'Absolute' -Action 'Lookup' -Status 'NotFound' -Detail 'Not enrolled'
            $stats.NotFound++
        }
    }
    catch {
        Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
        Write-RetirementLog -Hostname $hn -SerialNumber $sn -System 'Absolute' -Action 'Lookup' -Status 'Error' -Detail $_.Exception.Message
        $stats.Errors++
    }
}

Write-Host ""
Write-Host "Absolute — Total:$($stats.Total) Whitelisted:$($stats.Whitelisted) Found:$($stats.Found) NotFound:$($stats.NotFound) Unenrolled:$($stats.Unenrolled) Errors:$($stats.Errors)"
Write-Host "Log: $script:logPath" -ForegroundColor Green
