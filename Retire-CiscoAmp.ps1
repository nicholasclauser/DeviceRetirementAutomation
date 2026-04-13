# Retire-CiscoAmp.ps1
# finds devices in Cisco Secure Endpoint by hostname and deletes the console record
# usage:
#   .\Retire-CiscoAmp.ps1 -TestAuthOnly
#   .\Retire-CiscoAmp.ps1 -CsvPath ..\ToBeRetired\batch.csv

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
$clientId = Get-Secret -Name CiscoAmpClientId -AsPlainText -ErrorAction Stop
$apiKey   = Get-Secret -Name CiscoAmpApiKey   -AsPlainText -ErrorAction Stop

$authHeader = @{ Authorization = "Basic $([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${clientId}:${apiKey}")))" }

$cfg     = Get-DotEnv -Path $EnvPath
$apiBase = if ($cfg['CISCO_AMP_API_BASE']) { $cfg['CISCO_AMP_API_BASE'].TrimEnd('/') } else { 'https://api.amp.cisco.com' }

if (-not $OutputDir -and $cfg['OUTPUT_DIR']) { $OutputDir = $cfg['OUTPUT_DIR'] }
if (-not $OutputDir) { $OutputDir = Join-Path (Split-Path $scriptDir -Parent) 'out' }

$extraSkipPatterns = if ($cfg['EXTRA_SKIP_PATTERNS']) {
    $cfg['EXTRA_SKIP_PATTERNS'] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
} else { @() }

$script:rlRemaining = 999


# --- api helper ---

function Invoke-AmpApi {
    param([string]$Method = 'GET', [string]$Path, [hashtable]$QueryParams = @{})

    $qs  = if ($QueryParams.Count) { '?' + (($QueryParams.GetEnumerator() | ForEach-Object { "$([uri]::EscapeDataString($_.Key))=$([uri]::EscapeDataString($_.Value))" }) -join '&') } else { '' }
    $url = "$apiBase$Path$qs"

    # back off if rate limit is getting low
    if ($script:rlRemaining -lt 10) {
        Write-Warning "Rate limit low — pausing 60s."
        Start-Sleep -Seconds 60
        $script:rlRemaining = 999
    }

    try {
        $r = Invoke-WebRequest -Uri $url -Method $Method -Headers $authHeader -UseBasicParsing -SkipHttpErrorCheck -ErrorAction Stop
        if ($r.Headers['X-RateLimit-Remaining']) { $script:rlRemaining = [int]($r.Headers['X-RateLimit-Remaining'] | Select-Object -First 1) }

        if ($r.StatusCode -in 200,201,204) {
            if ($r.Content) { return $r.Content | ConvertFrom-Json } else { return [pscustomobject]@{ success = $true } }
        }
        if ($r.StatusCode -eq 429) {
            $wait = if ($r.Headers['Retry-After']) { [int]($r.Headers['Retry-After'] | Select-Object -First 1) } else { 60 }
            Write-Warning "429 — waiting ${wait}s."
            Start-Sleep -Seconds $wait
            return Invoke-AmpApi -Method $Method -Path $Path -QueryParams $QueryParams
        }
        if ($r.StatusCode -eq 404) { return $null }
        Write-Warning "AMP $Method $Path -> HTTP $($r.StatusCode)"
        return $null
    }
    catch { Write-Warning "AMP $Method $Path -> $($_.Exception.Message)"; return $null }
}


# --- test auth ---

if ($TestAuthOnly) {
    Write-Host "TestAuthOnly — Cisco AMP" -ForegroundColor Cyan
    $r = Invoke-AmpApi -Method GET -Path '/v1/computers' -QueryParams @{ limit = '1' }
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
$script:logPath = Join-Path $OutputDir "Retirement-CiscoAmp-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"

Write-Host "Retire-CiscoAmp | $(@($rows).Count) devices | PreviewOnly=$PreviewOnly | Log: $script:logPath"

$stats = @{ Total=0; Whitelisted=0; Found=0; NotFound=0; Deleted=0; Errors=0 }

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

    if (-not $hn) {
        Write-Host '  No hostname — skipping' -ForegroundColor DarkGray
        Write-RetirementLog -Hostname $hn -SerialNumber $sn -System 'CiscoAmp' -Action 'Skip' -Status 'Skipped' -Detail 'No hostname'
        $stats.NotFound++; continue
    }

    try {
        $r   = Invoke-AmpApi -Method GET -Path '/v1/computers' -QueryParams @{ hostname = $hn }
        $dev = if ($r -and $r.PSObject.Properties['data']) {
            @($r.data) | Where-Object { $_.hostname -ieq $hn } | Select-Object -First 1
        }

        if ($dev) {
            $guid = $dev.connector_guid
            Write-Host "  Found (guid=$guid)" -ForegroundColor Green

            if (-not $PreviewOnly) {
                $ok = Invoke-AmpApi -Method DELETE -Path "/v1/computers/$guid"
                if ($ok) {
                    Write-Host "  Deleted" -ForegroundColor Green
                    Write-RetirementLog -Hostname $hn -SerialNumber $sn -System 'CiscoAmp' -Action 'Delete' -Status 'Done' -Detail "GUID=$guid"
                    $stats.Deleted++
                } else {
                    Write-Host "  Delete failed" -ForegroundColor Red
                    Write-RetirementLog -Hostname $hn -SerialNumber $sn -System 'CiscoAmp' -Action 'Delete' -Status 'Error' -Detail "GUID=$guid"
                    $stats.Errors++
                }
            } else {
                Write-RetirementLog -Hostname $hn -SerialNumber $sn -System 'CiscoAmp' -Action 'Lookup' -Status 'Found' -Detail "GUID=$guid | Active=$($dev.active) | LastSeen=$($dev.last_seen)"
                $stats.Found++
            }
        } else {
            Write-Host '  Not in AMP' -ForegroundColor DarkGray
            Write-RetirementLog -Hostname $hn -SerialNumber $sn -System 'CiscoAmp' -Action 'Lookup' -Status 'NotFound' -Detail 'Not found'
            $stats.NotFound++
        }
    }
    catch {
        Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
        Write-RetirementLog -Hostname $hn -SerialNumber $sn -System 'CiscoAmp' -Action 'Lookup' -Status 'Error' -Detail $_.Exception.Message
        $stats.Errors++
    }
}

Write-Host ""
Write-Host "CiscoAmp — Total:$($stats.Total) Whitelisted:$($stats.Whitelisted) Found:$($stats.Found) NotFound:$($stats.NotFound) Deleted:$($stats.Deleted) Errors:$($stats.Errors)"
Write-Host "Log: $script:logPath" -ForegroundColor Green
