#Requires -Version 5.1

# show-stats.ps1 -- readout for the Track A telemetry log (stats.jsonl). Summarizes
# per-stage p50/p95 (connect, analysis, codeAction, total), the cache-hit rate, the
# path-taken breakdown, and the sample count. Read-only: it never writes the log or
# touches the daemon. Tolerates an empty or missing log without erroring (exit 0).
#
# The log is written by lsp-client.ps1 when the plugin option enableStats is on
# (one JSONL line per analyzed edit). JSONL -- not a JSON array -- so a partial last
# line or PS 5.1's empty-array-returns-null quirk never breaks the read.
#
# Usage:  pwsh -File scripts/show-stats.ps1            # default log dir
#         pwsh -File scripts/show-stats.ps1 -Path X    # an explicit stats.jsonl
#
# Author: Mike Andersen / powershell-lsp plugin.

param(
    # Explicit stats.jsonl to read. Default: the live log dir's stats.jsonl. Its
    # rolled sibling (<path>.1) is included automatically when present.
    [string] $Path = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/lsp-common.ps1')

# DATA-ROOT PROVENANCE (dispatch 000185, D1-C). Only the DEFAULT path is exposed to the silent
# fallback: an explicit -Path is a directory the caller named, so a miss there is a real miss.
$script:StatsRootKnown = $true
$script:StatsProvenance = 'explicit:-Path'
if ([string]::IsNullOrWhiteSpace($Path)) {
    $res = Get-PluginDataRootResolution
    $script:StatsRootKnown = [bool]$res.Known
    $script:StatsProvenance = [string]$res.Provenance
    $Path = Join-Path (Get-LogDir) 'stats.jsonl'
}

function Read-StatsLines([string]$file) {
    # Return parsed record objects from one JSONL file, skipping blank / malformed
    # lines. Missing file -> empty array. Never throws.
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    $out = @()
    foreach ($line in @(Get-Content -LiteralPath $file -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $out += ($line | ConvertFrom-Json) } catch { }
    }
    return @($out)
}

function Get-Pctl([double[]]$Values, [double]$P) {
    # Nearest-rank percentile. $null for an empty set.
    $s = @($Values | Sort-Object)
    if ($s.Count -eq 0) { return $null }
    $rank = [int][Math]::Ceiling(($P / 100.0) * $s.Count)
    if ($rank -lt 1) { $rank = 1 }
    if ($rank -gt $s.Count) { $rank = $s.Count }
    return $s[$rank - 1]
}

function Get-NumField([object[]]$Records, [string]$Name) {
    # Collect a numeric field across records, dropping nulls / non-numbers (e.g. the
    # parser-prepass path leaves connect/analysis/codeAction null).
    $vals = @()
    foreach ($r in @($Records)) {
        if ($r.PSObject.Properties.Name -notcontains $Name) { continue }
        $v = $r.$Name
        if ($null -eq $v) { continue }
        $d = 0.0
        if ([double]::TryParse([string]$v, [ref]$d)) { $vals += $d }
    }
    return @($vals)
}

function Format-Ms($v) { if ($null -eq $v) { return '-' } return ([string][int]$v + ' ms') }

# --- load (live + rolled) --------------------------------------------------
$live = Read-StatsLines $Path
$rolledPath = $Path + '.1'
$rolled = Read-StatsLines $rolledPath
$records = @(@($live) + @($rolled))

Write-Host ('powershell-lsp telemetry -- ' + $Path)
Write-Host ('  data root resolved via: ' + $script:StatsProvenance +
    '   data-root known: ' + $(if ($script:StatsRootKnown) { 'YES' } else { 'NO' }))

if (@($records).Count -eq 0) {
    # A FALLBACK ROOT CANNOT SUPPORT "no telemetry recorded yet" (dispatch 000185, D1-C).
    # That sentence is a claim about THE WORLD -- nothing was ever written. What a bare-shell run
    # actually establishes is a claim about THE READER: it found no stats.jsonl under a directory
    # it substituted for one it was never told. This is the same defect 000182 found in
    # rule-efficacy-ledger.ps1, at a second live site, and it is PROVEN here rather than inferred:
    # a stats.jsonl under the real data root is invisible to a bare-shell run.
    if (-not $script:StatsRootKnown) {
        Write-Host '  NO TELEMETRY FOUND, under a FALLBACK data root -- CANNOT DETERMINE whether none was ever'
        Write-Host '    recorded or it simply is not here. Set CLAUDE_PLUGIN_DATA to the real data root and'
        Write-Host '    re-run to get a determinate answer.'
        exit 0
    }
    Write-Host '  no telemetry recorded yet (enable the plugin option "enableStats" and make an edit).'
    exit 0
}

$total = @($records).Count
$nLive = @($live).Count
$nRolled = @($rolled).Count
Write-Host ('  samples: ' + $total + '   (stats.jsonl: ' + $nLive + ', stats.jsonl.1: ' + $nRolled + ')')

# --- path-taken breakdown + cache-hit rate ---------------------------------
$byPath = @{}
foreach ($r in $records) {
    $t = if ($r.PSObject.Properties.Name -contains 'taken') { [string]$r.taken } else { '' }
    if ([string]::IsNullOrWhiteSpace($t)) { $t = '(unknown)' }
    if (-not $byPath.ContainsKey($t)) { $byPath[$t] = 0 }
    $byPath[$t]++
}
$pathParts = @()
foreach ($k in ($byPath.Keys | Sort-Object)) { $pathParts += ($k + ' ' + $byPath[$k]) }
Write-Host ('  path taken:  ' + ($pathParts -join '   '))

$cacheHits = if ($byPath.ContainsKey('cache-hit')) { $byPath['cache-hit'] } else { 0 }
$rate = if ($total -gt 0) { [int][Math]::Round(100.0 * $cacheHits / $total) } else { 0 }
Write-Host ('  cache-hit rate: ' + $rate + '%')

# --- per-stage p50/p95 -----------------------------------------------------
Write-Host ''
Write-Host ('  {0,-12} {1,-10} {2,-10} {3}' -f 'stage', 'p50', 'p95', 'n')
foreach ($stage in @(
        @{ name = 'connect';    field = 'connectMs' },
        @{ name = 'analysis';   field = 'analysisMs' },
        @{ name = 'codeAction'; field = 'codeActionMs' },
        @{ name = 'total';      field = 'totalMs' })) {
    $vals = Get-NumField $records $stage.field
    $p50 = Format-Ms (Get-Pctl $vals 50)
    $p95 = Format-Ms (Get-Pctl $vals 95)
    Write-Host ('  {0,-12} {1,-10} {2,-10} {3}' -f $stage.name, $p50, $p95, @($vals).Count)
}

# THE TOTAL ROW'S BOUNDARY, stated where the number is actually read (dispatch 000265, O1).
# totalMs's stopwatch starts inside the ALREADY-RUNNING client process, so this table cannot see
# the per-edit pwsh spawn, the dot-source of the shared library, or the option reads that precede
# it -- a 931 ms / 45% median gap (docs/roadmap-ii/SLO-BASELINES.md, finding 1). Printed for the
# same reason as the fallback-root message above: an instrument that will not name its own
# boundary invites the reader to assume it has none, and here that understates the wait by ~45%.
Write-Host ''
Write-Host '  NOTE: total = analysis round-trip INSIDE the client, NOT end-to-end per-edit wall.'
Write-Host '    It excludes the pwsh spawn + dot-source + option reads before the stopwatch starts'
Write-Host '    -- about 931 ms (45%) more at the median. See docs/configuration.md#enablestats.'

# --- record / correction counts --------------------------------------------
$recVals = Get-NumField $records 'records'
$corrVals = Get-NumField $records 'corrections'
$recMed = Get-Pctl $recVals 50
$recMedStr = if ($null -eq $recMed) { '-' } else { [string][int]$recMed }
$corrSum = 0.0; foreach ($c in $corrVals) { $corrSum += $c }
Write-Host ''
Write-Host ('  records/edit: median ' + $recMedStr + '   corrections: total ' + [int]$corrSum)

# --- edit-range scoping noise reduction (dispatch 000019) ------------------
# How often scoping fired and how much it trimmed. surfaced-vs-total measures the
# noise reduction: total = whole-file candidates (after severity/rule filtering),
# surfaced = what scoping kept. Tolerant of older lines that predate these fields
# (no scopeApplied -> counted as not-scoped).
$scopedRecs = @($records | Where-Object { ($_.PSObject.Properties.Name -contains 'scopeApplied') -and $_.scopeApplied })
$scopedCount = @($scopedRecs).Count
Write-Host ''
if ($scopedCount -gt 0) {
    $totSum = 0; $surfSum = 0
    foreach ($r in $scopedRecs) {
        if ($r.PSObject.Properties.Name -contains 'scopeTotal') { $totSum += [int]$r.scopeTotal }
        if ($r.PSObject.Properties.Name -contains 'scopeSurfaced') { $surfSum += [int]$r.scopeSurfaced }
    }
    $trimmed = $totSum - $surfSum
    $pct = if ($totSum -gt 0) { [int][Math]::Round(100.0 * $trimmed / $totSum) } else { 0 }
    Write-Host ('  edit-scope:   ' + $scopedCount + ' of ' + $total + ' edits scoped; ' +
        $surfSum + ' surfaced / ' + $totSum + ' whole-file (' + $pct + '% trimmed)')
} else {
    Write-Host '  edit-scope:   no scoped edits recorded'
}

exit 0
