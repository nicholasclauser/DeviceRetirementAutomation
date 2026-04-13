# _shared.ps1
# dot-source this into every Retire-*.ps1 script
# $script:logPath needs to be set by the caller before Write-RetirementLog is used


function Get-DotEnv {
    param([string]$Path)
    $map = @{}
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $map }

    foreach ($line in Get-Content -LiteralPath $Path) {
        $l = $line.Trim()
        if (-not $l -or $l.StartsWith('#')) { continue }

        $kv = $l -split '=', 2
        if ($kv.Count -eq 2) {
            $k = $kv[0].Trim()
            $v = $kv[1].Trim()
            # strip surrounding quotes if present
            if (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'"))) {
                $v = $v.Substring(1, $v.Length - 2)
            }
            $map[$k] = $v
        }
    }
    return $map
}


function Test-Whitelist {
    param([string]$Hostname, [string]$SerialNumber, [string[]]$ExtraPatterns = @())

    # skip distribution points and site server
    # add site-specific hostnames to EXTRA_SKIP_PATTERNS in .env
    if ($Hostname -match 'PC')    { return $true }

    foreach ($pat in $ExtraPatterns) {
        if ($pat -and $Hostname     -match [regex]::Escape($pat)) { return $true }
        if ($pat -and $SerialNumber -match [regex]::Escape($pat)) { return $true }
    }
    return $false
}


function Write-RetirementLog {
    param(
        [string]$Hostname,
        [string]$SerialNumber,
        [string]$System,
        [string]$Action,
        [string]$Status,
        [string]$Detail = ''
    )

    [pscustomobject]@{
        Timestamp    = (Get-Date -Format 'o')
        Hostname     = $Hostname
        SerialNumber = $SerialNumber
        System       = $System
        Action       = $Action
        Status       = $Status
        Detail       = $Detail
    } | Export-Csv -LiteralPath $script:logPath -Append -NoTypeInformation -Encoding UTF8
}
