# Invoke-DeviceRetirement.ps1
# orchestrator - runs retirement scripts against Absolute, Cisco AMP, SCCM, and AD
# usage:
#   .\Invoke-DeviceRetirement.ps1 -TestAuthOnly
#   .\Invoke-DeviceRetirement.ps1                                   (preview, reads DangerZone-DevicesToBeRetired\)
#   .\Invoke-DeviceRetirement.ps1 -PreviewOnly $false -ConfirmCiscoDelete
#   .\Invoke-DeviceRetirement.ps1 -CsvPath .\somewhere\batch.csv
#   .\Invoke-DeviceRetirement.ps1 -Systems Absolute,SCCM

[CmdletBinding()]
param(
    [string]$CsvPath,
    [string]$InputDir,
    [string]$EnvPath,
    [string]$OutputDir,
    [bool]$PreviewOnly = $true,
    [string[]]$Systems = @('Absolute','CiscoAmp','SCCM','AD'),
    [int]$MaxBatch = 500,
    [switch]$ConfirmCiscoDelete,
    [switch]$Force,
    [switch]$TestAuthOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir '_shared.ps1')

# .env lives in the repo root, fall back to one folder up for older layouts
if (-not $EnvPath) {
    $EnvPath = Join-Path $scriptDir '.env'
    if (-not (Test-Path -LiteralPath $EnvPath)) { $EnvPath = Join-Path (Split-Path $scriptDir -Parent) '.env' }
}

if (-not $InputDir) { $InputDir = Join-Path $scriptDir 'DangerZone-DevicesToBeRetired' }

# pull output dir from .env if not passed in
if (-not $OutputDir) {
    $cfg = Get-DotEnv -Path $EnvPath
    if ($cfg['OUTPUT_DIR']) { $OutputDir = $cfg['OUTPUT_DIR'] }
}
if (-not $OutputDir) { $OutputDir = Join-Path $scriptDir 'out' }

$valid = @('Absolute','CiscoAmp','SCCM','AD')
foreach ($s in $Systems) {
    if ($s -notin $valid) { Write-Error "Unknown system '$s'. Valid: $($valid -join ', ')" }
}

$scripts = @{
    Absolute = Join-Path $scriptDir 'Retire-Absolute.ps1'
    CiscoAmp = Join-Path $scriptDir 'Retire-CiscoAmp.ps1'
    SCCM     = Join-Path $scriptDir 'Retire-SCCM.ps1'
    AD       = Join-Path $scriptDir 'Retire-AD.ps1'
}

# --- test auth mode ---
if ($TestAuthOnly) {
    Write-Host "TestAuthOnly - Systems: $($Systems -join ', ')" -ForegroundColor Cyan
    foreach ($s in $Systems) {
        Write-Host "--- $s ---" -ForegroundColor Cyan
        try   { & $scripts[$s] -EnvPath $EnvPath -TestAuthOnly }
        catch { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red }
    }
    exit
}

# --- collect targets ---
# one csv via -CsvPath, or every .csv/.txt dropped in the DangerZone folder
if ($CsvPath) {
    if (-not (Test-Path -LiteralPath $CsvPath)) { Write-Error "File not found: $CsvPath" }
    $files = @($CsvPath)
} else {
    if (-not (Test-Path -LiteralPath $InputDir)) { Write-Error "Input folder not found: $InputDir" }
    $files = @(Get-ChildItem -LiteralPath $InputDir -File | Where-Object { $_.Extension -in '.csv','.txt' -and $_.Name -notmatch '^README' } | ForEach-Object { $_.FullName })
    if ($files.Count -eq 0) { Write-Error "Nothing to do. Drop a .csv or .txt of device names in $InputDir" }
}

$targets = Read-DeviceList -Paths $files
if ($targets.Count -eq 0) { Write-Error "No device names found in: $($files -join ', ')" }
$deviceCount = $targets.Count

# --- action-mode brakes ---
if (-not $PreviewOnly) {
    if ($deviceCount -gt $MaxBatch) {
        Write-Error "Refusing to action $deviceCount devices; exceeds -MaxBatch cap of $MaxBatch. Raise -MaxBatch only if this batch size is intended."
    }

    if (('CiscoAmp' -in $Systems) -and -not $ConfirmCiscoDelete) {
        Write-Error "CiscoAmp deletes the console record permanently and cannot be undone. Re-run with -ConfirmCiscoDelete to include it in action mode, or drop CiscoAmp from -Systems."
    }

    if (-not $Force) {
        Write-Host ""
        Write-Host "ACTION MODE: this will modify $deviceCount device(s) across $($Systems -join ', ')." -ForegroundColor Yellow
        $confirm = Read-Host "Type the device count ($deviceCount) to proceed, anything else aborts"
        if ($confirm -ne "$deviceCount") { Write-Error "Aborted (confirmation did not match)." }
    }
}

# --- run ---
$runDir = Join-Path $OutputDir (Get-Date -Format 'yyyyMMdd-HHmmss')
New-Item -ItemType Directory -Path $runDir -Force | Out-Null

# the retire scripts all read the same normalized csv, saved with the logs so the run is reproducible
$targetsCsv = Join-Path $runDir 'targets.csv'
$targets | Export-Csv -LiteralPath $targetsCsv -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "Device Retirement | Systems: $($Systems -join ', ') | PreviewOnly: $PreviewOnly" -ForegroundColor Cyan
Write-Host "Input: $($files -join ', ')"
Write-Host "Devices: $deviceCount (deduped)"
Write-Host "Logs: $runDir"
if (-not $PreviewOnly) { Write-Host "ACTION MODE" -ForegroundColor Yellow }
Write-Host ""

$results = @{}
foreach ($s in $Systems) {
    Write-Host "--- $s ---" -ForegroundColor Cyan
    try {
        $extra = @{}
        if ($s -eq 'CiscoAmp' -and $ConfirmCiscoDelete) { $extra['ConfirmDelete'] = $true }
        & $scripts[$s] -CsvPath $targetsCsv -EnvPath $EnvPath -OutputDir $runDir -PreviewOnly $PreviewOnly @extra
        $results[$s] = 'OK'
    }
    catch {
        Write-Host "ERROR in ${s}: $($_.Exception.Message)" -ForegroundColor Red
        $results[$s] = "ERROR: $($_.Exception.Message)"
    }
    Write-Host ""
}

$ledger = Join-Path $OutputDir 'ledger.csv'
try   { Add-RetirementLedger -RunDir $runDir -LedgerPath $ledger }
catch { Write-Host "Ledger append failed: $($_.Exception.Message)" -ForegroundColor Yellow }

Write-Host "--- Results ---" -ForegroundColor Cyan
foreach ($s in $Systems) {
    $color = if ($results[$s] -eq 'OK') { 'Green' } else { 'Red' }
    Write-Host "  $s : $($results[$s])" -ForegroundColor $color
}
Write-Host "Logs: $runDir" -ForegroundColor Green
Write-Host "Ledger: $ledger" -ForegroundColor Green
