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


function Read-DeviceList {
    param([string[]]$Paths)

    # takes any mix of headed csv files and raw name dumps, returns Hostname/SerialNumber rows
    # raw dumps: every token that looks like a device name (XX-something) counts, everything else is ignored
    $rows = [System.Collections.Generic.List[object]]::new()
    $seen = @{}

    foreach ($p in $Paths) {
        $src   = Split-Path $p -Leaf
        $first = Get-Content -LiteralPath $p -TotalCount 1

        if ($first -match '(?i)^\s*"?(hostname|serialnumber)"?\s*(,|$)') {
            foreach ($r in Import-Csv -LiteralPath $p) {
                $hn = if ($r.PSObject.Properties['Hostname'])     { "$($r.Hostname)".Trim() }     else { '' }
                $sn = if ($r.PSObject.Properties['SerialNumber']) { "$($r.SerialNumber)".Trim() } else { '' }
                if (-not $hn -and -not $sn) { continue }
                $key = "$hn|$sn".ToUpper()
                if ($seen[$key]) { continue }
                $seen[$key] = $true
                $rows.Add([pscustomobject]@{ Hostname = $hn; SerialNumber = $sn; Source = $src })
            }
        } else {
            foreach ($line in Get-Content -LiteralPath $p) {
                if ($line -match '^\s*#') { continue }
                foreach ($tok in ($line -split '[\s,;]+')) {
                    $t = $tok.Trim().Trim('"', "'")
                    if ($t -notmatch '^[A-Za-z]{2,4}-[A-Za-z0-9-]{3,}$') { continue }
                    $key = "$t|".ToUpper()
                    if ($seen[$key]) { continue }
                    $seen[$key] = $true
                    $rows.Add([pscustomobject]@{ Hostname = $t; SerialNumber = ''; Source = $src })
                }
            }
        }
    }
    return @($rows)
}


function Add-RetirementLedger {
    param([string]$RunDir, [string]$LedgerPath)

    # one ledger across every run so you never have to stitch out\ folders together
    $runId = Split-Path $RunDir -Leaf
    foreach ($log in Get-ChildItem -LiteralPath $RunDir -Filter 'Retirement-*.csv' -File) {
        Import-Csv -LiteralPath $log.FullName |
            Select-Object @{ n = 'RunId'; e = { $runId } }, * |
            Export-Csv -LiteralPath $LedgerPath -Append -NoTypeInformation -Encoding UTF8
    }
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
