# Invoke-DeviceRetirement.ps1
# orchestrator - runs retirement scripts against Absolute, Cisco AMP, SCCM, and AD
# usage:
#   .\Invoke-DeviceRetirement.ps1 -TestAuthOnly
#   .\Invoke-DeviceRetirement.ps1 -CsvPath ..\ToBeRetired\batch.csv
#   .\Invoke-DeviceRetirement.ps1 -CsvPath ..\ToBeRetired\batch.csv -PreviewOnly $false
#   .\Invoke-DeviceRetirement.ps1 -CsvPath ..\ToBeRetired\batch.csv -Systems Absolute,SCCM

[CmdletBinding()]
param(
    [string]$CsvPath,
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
if (-not $EnvPath) { $EnvPath = Join-Path (Split-Path $scriptDir -Parent) '.env' }

# pull output dir from .env if not passed in
if (-not $OutputDir) {
    foreach ($line in (Get-Content -LiteralPath $EnvPath -ErrorAction SilentlyContinue)) {
        if ($line -match '^OUTPUT_DIR\s*=\s*(.+)') { $OutputDir = $Matches[1].Trim(); break }
    }
}
if (-not $OutputDir) { $OutputDir = Join-Path (Split-Path $scriptDir -Parent) 'out' }

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
    Write-Host "TestAuthOnly — Systems: $($Systems -join ', ')" -ForegroundColor Cyan
    foreach ($s in $Systems) {
        Write-Host "--- $s ---" -ForegroundColor Cyan
        try   { & $scripts[$s] -EnvPath $EnvPath -TestAuthOnly }
        catch { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red }
    }
    exit
}

# --- validate CSV ---
if (-not $CsvPath)                          { Write-Error "CsvPath is required." }
if (-not (Test-Path -LiteralPath $CsvPath)) { Write-Error "CSV not found: $CsvPath" }
if (@(Import-Csv -LiteralPath $CsvPath).Count -eq 0) { Write-Error "CSV is empty." }

# --- action-mode brakes ---
if (-not $PreviewOnly) {
    $deviceCount = @(Import-Csv -LiteralPath $CsvPath).Count

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
New-Item -ItemType Directory -LiteralPath $runDir | Out-Null

Write-Host ""
Write-Host "Device Retirement | Systems: $($Systems -join ', ') | PreviewOnly: $PreviewOnly" -ForegroundColor Cyan
Write-Host "CSV: $CsvPath"
Write-Host "Logs: $runDir"
if (-not $PreviewOnly) { Write-Host "ACTION MODE" -ForegroundColor Yellow }
Write-Host ""

$results = @{}
foreach ($s in $Systems) {
    Write-Host "--- $s ---" -ForegroundColor Cyan
    try {
        $extra = @{}
        if ($s -eq 'CiscoAmp' -and $ConfirmCiscoDelete) { $extra['ConfirmDelete'] = $true }
        & $scripts[$s] -CsvPath $CsvPath -EnvPath $EnvPath -OutputDir $runDir -PreviewOnly $PreviewOnly @extra
        $results[$s] = 'OK'
    }
    catch {
        Write-Host "ERROR in ${s}: $($_.Exception.Message)" -ForegroundColor Red
        $results[$s] = "ERROR: $($_.Exception.Message)"
    }
    Write-Host ""
}

Write-Host "--- Results ---" -ForegroundColor Cyan
foreach ($s in $Systems) {
    $color = if ($results[$s] -eq 'OK') { 'Green' } else { 'Red' }
    Write-Host "  $s : $($results[$s])" -ForegroundColor $color
}
Write-Host "Logs: $runDir" -ForegroundColor Green
