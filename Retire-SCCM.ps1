# Retire-SCCM.ps1
# finds and removes the device record from SCCM
# usage:
#   .\Retire-SCCM.ps1 -TestAuthOnly
#   .\Retire-SCCM.ps1 -CsvPath ..\ToBeRetired\batch.csv

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

if (-not $EnvPath) {
    $EnvPath = Join-Path $scriptDir '.env'
    if (-not (Test-Path -LiteralPath $EnvPath)) { $EnvPath = Join-Path (Split-Path $scriptDir -Parent) '.env' }
}

$cfg      = Get-DotEnv -Path $EnvPath
$siteCode = if ($cfg['SCCM_SITE_CODE']) { $cfg['SCCM_SITE_CODE'] } else { 'ABC' }

if (-not $OutputDir -and $cfg['OUTPUT_DIR']) { $OutputDir = $cfg['OUTPUT_DIR'] }
if (-not $OutputDir) { $OutputDir = Join-Path (Split-Path $scriptDir -Parent) 'out' }

$extraSkipPatterns = if ($cfg['EXTRA_SKIP_PATTERNS']) {
    $cfg['EXTRA_SKIP_PATTERNS'] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
} else { @() }


function Start-SccmSession {
    Import-Module ConfigurationManager -ErrorAction Stop
    if ((Get-Location).Drive.Name -ne $siteCode) { Push-Location "${siteCode}:" }
}

function Stop-SccmSession {
    try { Set-Location C: } catch {}
}


# --- test auth ---

if ($TestAuthOnly) {
    Write-Host "TestAuthOnly — SCCM" -ForegroundColor Cyan
    Start-SccmSession
    try {
        Get-CMSite -ErrorAction Stop | Format-List SiteCode, SiteName, ServerName, Version
        Write-Host "SCCM OK" -ForegroundColor Green
    }
    catch { Write-Host "SCCM FAILED: $($_.Exception.Message)" -ForegroundColor Red }
    finally { Stop-SccmSession }
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

if (-not (Test-Path -LiteralPath $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }
$script:logPath = Join-Path $OutputDir "Retirement-SCCM-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"

Write-Host "Retire-SCCM | $(@($rows).Count) devices | PreviewOnly=$PreviewOnly | Log: $script:logPath"

Start-SccmSession

$stats = @{ Total=0; Whitelisted=0; Found=0; NotFound=0; Removed=0; Errors=0 }

try {
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
            Write-RetirementLog -Hostname $hn -SerialNumber $sn -System 'SCCM' -Action 'Skip' -Status 'Skipped' -Detail 'No hostname'
            $stats.NotFound++; continue
        }

        try {
            $dev = Get-CMDevice -Name $hn -Fast -ErrorAction SilentlyContinue

            if ($dev) {
                Write-Host "  Found (ResourceID=$($dev.ResourceID))" -ForegroundColor Green

                if (-not $PreviewOnly) {
                    Remove-CMDevice -InputObject $dev -Force -ErrorAction Stop
                    Write-Host "  Removed" -ForegroundColor Green
                    Write-RetirementLog -Hostname $hn -SerialNumber $sn -System 'SCCM' -Action 'Remove' -Status 'Done' -Detail "ResourceID=$($dev.ResourceID)"
                    $stats.Removed++
                } else {
                    Write-RetirementLog -Hostname $hn -SerialNumber $sn -System 'SCCM' -Action 'Lookup' -Status 'Found' -Detail "ResourceID=$($dev.ResourceID) | LastActive=$($dev.LastActiveTime)"
                    $stats.Found++
                }
            } else {
                Write-Host '  Not in SCCM' -ForegroundColor DarkGray
                Write-RetirementLog -Hostname $hn -SerialNumber $sn -System 'SCCM' -Action 'Lookup' -Status 'NotFound' -Detail 'Not found'
                $stats.NotFound++
            }
        }
        catch {
            Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
            Write-RetirementLog -Hostname $hn -SerialNumber $sn -System 'SCCM' -Action 'Lookup' -Status 'Error' -Detail $_.Exception.Message
            $stats.Errors++
        }
    }
}
finally { Stop-SccmSession }

Write-Host ""
Write-Host "SCCM — Total:$($stats.Total) Whitelisted:$($stats.Whitelisted) Found:$($stats.Found) NotFound:$($stats.NotFound) Removed:$($stats.Removed) Errors:$($stats.Errors)"
Write-Host "Log: $script:logPath" -ForegroundColor Green
