# Retire-AD.ps1
# disables computer account in AD and moves it to the disabled computers OU
# usage:
#   .\Retire-AD.ps1 -TestAuthOnly
#   .\Retire-AD.ps1 -CsvPath ..\ToBeRetired\batch.csv

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

$cfg        = Get-DotEnv -Path $EnvPath
$disabledOU = if ($cfg['AD_DISABLED_COMPUTERS_OU']) { $cfg['AD_DISABLED_COMPUTERS_OU'] } else { '' }

if (-not $OutputDir -and $cfg['OUTPUT_DIR']) { $OutputDir = $cfg['OUTPUT_DIR'] }
if (-not $OutputDir) { $OutputDir = Join-Path (Split-Path $scriptDir -Parent) 'out' }

$extraSkipPatterns = if ($cfg['EXTRA_SKIP_PATTERNS']) {
    $cfg['EXTRA_SKIP_PATTERNS'] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
} else { @() }

Import-Module ActiveDirectory -UseWindowsPowerShell


# --- test auth ---

if ($TestAuthOnly) {
    Write-Host "TestAuthOnly — AD" -ForegroundColor Cyan
    try {
        Get-ADDomain -ErrorAction Stop | Format-List DNSRoot, PDCEmulator
        Write-Host "AD OK" -ForegroundColor Green
    }
    catch { Write-Host "AD FAILED: $($_.Exception.Message)" -ForegroundColor Red }
    Write-Host "Disabled OU: $(if ($disabledOU) { $disabledOU } else { 'NOT SET' })"
    exit
}


# --- main ---

if (-not $PreviewOnly -and -not $disabledOU) {
    Write-Error "AD_DISABLED_COMPUTERS_OU not set in .env — required for action mode."
}

if (-not $CsvPath)                               { Write-Error "CsvPath is required." }
if (-not (Test-Path -LiteralPath $CsvPath))      { Write-Error "CSV not found: $CsvPath" }
$rows = Import-Csv -LiteralPath $CsvPath
if (@($rows).Count -eq 0)                        { Write-Error "CSV is empty." }

$s0        = @($rows)[0]
$hasHost   = [bool]$s0.PSObject.Properties['Hostname']
$hasSerial = [bool]$s0.PSObject.Properties['SerialNumber']
if (-not $hasHost -and -not $hasSerial) { Write-Error "CSV needs Hostname and/or SerialNumber columns." }

if (-not (Test-Path -LiteralPath $OutputDir)) { New-Item -ItemType Directory -LiteralPath $OutputDir | Out-Null }
$script:logPath = Join-Path $OutputDir "Retirement-AD-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"

Write-Host "Retire-AD | $(@($rows).Count) devices | PreviewOnly=$PreviewOnly | Log: $script:logPath"

$stats = @{ Total=0; Whitelisted=0; Found=0; NotFound=0; Disabled=0; Moved=0; Errors=0 }

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
        Write-Host '  No hostname — AD lookup requires hostname, skipping' -ForegroundColor DarkGray
        Write-RetirementLog -Hostname $hn -SerialNumber $sn -System 'AD' -Action 'Skip' -Status 'Skipped' -Detail 'No hostname'
        $stats.NotFound++; continue
    }

    try {
        $computer = Get-ADComputer -Filter { Name -eq $hn } `
            -Properties DistinguishedName, Enabled, LastLogonDate, OperatingSystem -ErrorAction SilentlyContinue

        if ($computer) {
            Write-Host "  Found (Enabled=$($computer.Enabled))" -ForegroundColor Green

            if (-not $PreviewOnly) {
                $disableErr = $null
                if ($computer.Enabled -ne $false) {
                    try   { Disable-ADAccount -Identity $computer -ErrorAction Stop; $stats.Disabled++ }
                    catch { $disableErr = $_.Exception.Message; Write-Host "  Disable ERROR: $disableErr" -ForegroundColor Red; $stats.Errors++ }
                }

                if (-not $disableErr) {
                    try {
                        Move-ADObject -Identity $computer.DistinguishedName -TargetPath $disabledOU -ErrorAction Stop
                        Write-Host "  Disabled + Moved" -ForegroundColor Green
                        Write-RetirementLog -Hostname $hn -SerialNumber $sn -System 'AD' -Action 'DisableAndMove' -Status 'Done' `
                            -Detail "DN=$($computer.DistinguishedName) | MovedTo=$disabledOU"
                        $stats.Moved++
                    }
                    catch {
                        Write-Host "  Move ERROR: $($_.Exception.Message)" -ForegroundColor Red
                        Write-RetirementLog -Hostname $hn -SerialNumber $sn -System 'AD' -Action 'Move' -Status 'Error' -Detail $_.Exception.Message
                        $stats.Errors++
                    }
                }
            } else {
                Write-RetirementLog -Hostname $hn -SerialNumber $sn -System 'AD' -Action 'Lookup' -Status 'Found' `
                    -Detail "DN=$($computer.DistinguishedName) | Enabled=$($computer.Enabled) | OS=$($computer.OperatingSystem)"
                $stats.Found++
            }
        } else {
            Write-Host '  Not in AD' -ForegroundColor DarkGray
            Write-RetirementLog -Hostname $hn -SerialNumber $sn -System 'AD' -Action 'Lookup' -Status 'NotFound' -Detail 'Not found'
            $stats.NotFound++
        }
    }
    catch {
        Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
        Write-RetirementLog -Hostname $hn -SerialNumber $sn -System 'AD' -Action 'Lookup' -Status 'Error' -Detail $_.Exception.Message
        $stats.Errors++
    }
}

Write-Host ""
Write-Host "AD — Total:$($stats.Total) Whitelisted:$($stats.Whitelisted) Found:$($stats.Found) NotFound:$($stats.NotFound) Disabled:$($stats.Disabled) Moved:$($stats.Moved) Errors:$($stats.Errors)"
Write-Host "Log: $script:logPath" -ForegroundColor Green
