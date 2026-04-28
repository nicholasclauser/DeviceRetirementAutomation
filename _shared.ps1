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

    # Protect infrastructure (distribution points, site servers, domain controllers)
    # from retirement. There is no hardcoded rule on purpose: define your real infra
    # names or wildcard patterns in EXTRA_SKIP_PATTERNS in .env, e.g. "DP01,SCCM-*,DC-*".
    # Matching is wildcard and full-string (-like), NOT a loose substring, so a short
    # pattern can't silently skip every machine that merely contains those letters.
    foreach ($pat in $ExtraPatterns) {
        if (-not $pat) { continue }
        if ($Hostname     -and $Hostname     -like $pat) { return $true }
        if ($SerialNumber -and $SerialNumber -like $pat) { return $true }
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
