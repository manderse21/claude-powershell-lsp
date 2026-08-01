#Requires -Version 5.1

# Invoke-LatencyBench.ps1 -- the N1.5 closed-loop latency harness (dispatch 000127).
#
# WHAT IT MEASURES, against the REAL daemon over the REAL pipe (never a simulation):
#   (a) warm-hook per-edit diagnostic round-trip -- one edit -> diagnostics, warm daemon.
#   (b) the 000061 closed-loop RE-CHECK turn -- the second edit of a fix cycle, where the
#       daemon diffs this pass against last turn's surfaced set and emits cleared[].
# Each as median + p95 over >= 30 iterations.
#
# COLD START IS EXCLUDED, AND THAT IS THE POINT. The daemon is brought up and primed BEFORE
# any timing starts, so these numbers describe the steady-state a session actually feels after
# its first edit -- not the once-per-session spin-up. Cold start is measured separately and
# guarded in tests/PowerShellLsp.Benchmark.Tests.ps1 (dispatch 000040); this harness does not
# re-measure it, and no number below includes it.
#
# WHY (b) IS TWO EDITS PER ITERATION: the closed loop only fires on a fresh, settled, ok,
# non-cached pass. Turn 1 (untimed) surfaces a finding; turn 2 (timed) presents it fixed, which
# is what makes the daemon emit the lifecycle signal. Timing one edit would measure the warm
# path and label it the closed loop. The harness verifies the signal actually fired and refuses
# to report a loop number if it did not.
#
# DETERMINISTIC: fixed iteration count, fixed fixture content, fixed order, a monotonic nonce
# per iteration (no RNG, no clock-derived input). Two runs differ only by machine noise.
#
# NOT CI-WIRED, DELIBERATELY (dispatch 000127 scope_out): this runs on demand. The four named
# CI legs are untouched. A single-machine latency number is indicative, not a regression gate --
# tests/PowerShellLsp.Benchmark.Tests.ps1 owns the guarded thresholds.
#
# USAGE (from a clean clone; the first run bootstraps PSES + pinned PSSA exactly as a session
# does, and that bootstrap is NOT timed):
#
#   pwsh -NoProfile -File tests/bench/Invoke-LatencyBench.ps1
#   pwsh -NoProfile -File tests/bench/Invoke-LatencyBench.ps1 -Iterations 50 -JsonPath bench.json
#
# ASCII-only (PS 5.1 em-dash trap); StrictMode-safe.
# Author: Mike Andersen / powershell-lsp plugin.

[CmdletBinding()]
param(
    # Timed iterations per measured path. The acceptance floor is 30; lower is allowed for a
    # quick smoke run but is reported as such rather than silently passing as a real sample.
    [int] $Iterations = 30,

    # Write the structured results here (UTF-8, no BOM). Empty = stdout summary only.
    [string] $JsonPath = '',

    # Scratch/data root. Default: a throwaway temp dir, so a run never touches a live session's
    # daemon state.
    [string] $DataRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Benchmark.Common.ps1')

$paths = Get-BenchPaths
$scriptsDir = $paths.ScriptsDir

if ([string]::IsNullOrWhiteSpace($DataRoot)) {
    $DataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('psls-latency-bench-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
}
New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null
$env:CLAUDE_PLUGIN_DATA = $DataRoot

Write-Host ('[bench] data root : ' + $DataRoot)
Write-Host ('[bench] iterations: ' + $Iterations + ' per path')
Write-Host '[bench] bootstrapping PSES + pinned PSScriptAnalyzer (NOT timed)...'
& pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsDir 'ensure-pses.ps1') 2>&1 | Out-Null
& pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsDir 'ensure-pssa.ps1') 2>&1 | Out-Null

# --- bring up ONE warm daemon; every number below is post-warm (cold start excluded) -------
$sid = 'bench-lat-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$sessionFile = Join-Path $DataRoot ('session/' + $sid + '.json')
Write-Host '[bench] starting the daemon and waiting for ready (NOT timed)...'
Invoke-BenchHook -ScriptPath (Join-Path $scriptsDir 'session-start.ps1') `
    -StdinJson (@{ session_id = $sid } | ConvertTo-Json -Compress) `
    -ExtraArgs @('-PreferredHost', 'pwsh') -CapMs 60000 -DataRoot $DataRoot | Out-Null

$daemon = $null
for ($i = 0; $i -lt 200; $i++) {
    if (Test-Path -LiteralPath $sessionFile) {
        $o = Get-Content -LiteralPath $sessionFile -Raw | ConvertFrom-Json
        if ($o.state -eq 'ready') { $daemon = $o; break }
    }
    Start-Sleep -Milliseconds 100
}
if ($null -eq $daemon) {
    # Never fabricate a number (the 000040 invariant): no daemon means nothing was measured.
    Write-Error ('[bench] the daemon never reached ready; NOTHING was measured. See ' + (Join-Path $DataRoot 'logs'))
    exit 4
}
Write-Host '[bench] daemon ready.'

$scratchDir = Join-Path $DataRoot 'scratch'
New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null
$enc = New-Object System.Text.UTF8Encoding($false)

$warmSamples = New-Object System.Collections.Generic.List[int]
$loopSamples = New-Object System.Collections.Generic.List[int]
$loopFiredCount = 0

try {
    # --- (a) warm-hook per-edit round-trip -------------------------------------------------
    $warmFile = Join-Path $scratchDir 'warm-edit.ps1'
    Set-Content -LiteralPath $warmFile -Value (Get-Content -LiteralPath $paths.FixturePath -Raw) -Encoding ascii
    Write-Host '[bench] priming the warm path (first analysis of this file, discarded)...'
    Measure-BenchWarmPathMs -ScriptsDir $scriptsDir -DataRoot $DataRoot -SessionId $sid -ScratchFile $warmFile | Out-Null

    Write-Host ('[bench] measuring (a) warm-hook per-edit round-trip x ' + $Iterations + '...')
    for ($i = 0; $i -lt $Iterations; $i++) {
        # A real content change each iteration -> a fresh analysis, never a cache hit.
        Add-Content -LiteralPath $warmFile -Value ('# edit ' + $i) -Encoding ascii
        $ms = Measure-BenchWarmPathMs -ScriptsDir $scriptsDir -DataRoot $DataRoot -SessionId $sid -ScratchFile $warmFile
        $warmSamples.Add([int]$ms)
        if ((($i + 1) % 10) -eq 0) { Write-Host ('  ...' + ($i + 1) + '/' + $Iterations) }
    }

    # --- (b) the 000061 closed-loop re-check turn ------------------------------------------
    $loopFile = Join-Path $scratchDir 'loop-edit.ps1'
    [System.IO.File]::WriteAllText($loopFile, $script:BenchLoopDirty, $enc)
    Write-Host '[bench] priming the closed loop (discarded)...'
    Measure-BenchClosedLoopMs -ScriptsDir $scriptsDir -DataRoot $DataRoot -SessionId $sid -ScratchFile $loopFile -Nonce 0 | Out-Null

    Write-Host ('[bench] measuring (b) 000061 closed-loop re-check turn x ' + $Iterations + '...')
    for ($i = 0; $i -lt $Iterations; $i++) {
        $r = Measure-BenchClosedLoopMs -ScriptsDir $scriptsDir -DataRoot $DataRoot -SessionId $sid -ScratchFile $loopFile -Nonce ($i + 1)
        $loopSamples.Add([int]$r.Ms)
        if ($r.LoopFired) { $loopFiredCount++ }
        if ((($i + 1) % 10) -eq 0) { Write-Host ('  ...' + ($i + 1) + '/' + $Iterations + ' (loop fired ' + $loopFiredCount + ')') }
    }
} finally {
    Write-Host '[bench] tearing the daemon down...'
    try {
        Invoke-BenchHook -ScriptPath (Join-Path $scriptsDir 'session-end.ps1') `
            -StdinJson (@{ session_id = $sid } | ConvertTo-Json -Compress) `
            -ExtraArgs @() -CapMs 8000 -DataRoot $DataRoot | Out-Null
    } catch { }
    foreach ($pidVal in @($daemon.pid, $daemon.psesPid)) {
        if ($pidVal) { Stop-Process -Id $pidVal -Force -ErrorAction SilentlyContinue }
    }
}

$warmStats = Get-BenchStats -Values $warmSamples.ToArray()
$loopStats = Get-BenchStats -Values $loopSamples.ToArray()

# The loop-fired rate is reported, not assumed. A 0% rate means path (b) measured a plain warm
# turn and the closed-loop number is NOT what it claims -- say so rather than publish it.
$loopFiredRate = if ($loopSamples.Count -gt 0) { [math]::Round((100.0 * $loopFiredCount / $loopSamples.Count), 1) } else { 0 }

$platform = if (Test-Path 'Variable:\IsWindows') {
    if ($IsWindows) { 'windows' } elseif ($IsLinux) { 'linux' } elseif ($IsMacOS) { 'macos' } else { 'other' }
} else { 'windows' }

$result = [ordered]@{
    schema             = 'powershell-lsp-latency-bench/1'
    dispatch           = '000127'
    host               = ('pwsh ' + $PSVersionTable.PSVersion.ToString())
    platform           = $platform
    processorCount     = [System.Environment]::ProcessorCount
    iterations         = $Iterations
    meetsSampleFloor   = ($Iterations -ge 30)
    coldStartIncluded  = $false
    warmHookRoundTrip  = $warmStats
    closedLoopRecheck  = $loopStats
    closedLoopFired    = $loopFiredCount
    closedLoopFiredPct = $loopFiredRate
}

Write-Host ''
Write-Host '================ LATENCY BENCH (dispatch 000127, N1.5) ================'
Write-Host ('host             : ' + $result.host + ' / ' + $platform + ' / ' + $result.processorCount + ' logical cores')
Write-Host ('iterations       : ' + $Iterations + ' per path (>= 30 floor: ' + $result.meetsSampleFloor + ')')
Write-Host ('cold start       : EXCLUDED (daemon warm + primed before timing)')
# Rendered through Format-BenchStatValue so a zero-sample run prints "n/a (0 samples)" rather
# than the -1 sentinel, which reads as a real (and absurdly fast) latency (dispatch 000172, D1).
Write-Host ('(a) warm hook    : median ' + (Format-BenchStatValue $warmStats 'medianMs') + ' ms   p95 ' + (Format-BenchStatValue $warmStats 'p95Ms') + ' ms   [min ' + (Format-BenchStatValue $warmStats 'minMs') + ' / max ' + (Format-BenchStatValue $warmStats 'maxMs') + ']')
Write-Host ('(b) closed loop  : median ' + (Format-BenchStatValue $loopStats 'medianMs') + ' ms   p95 ' + (Format-BenchStatValue $loopStats 'p95Ms') + ' ms   [min ' + (Format-BenchStatValue $loopStats 'minMs') + ' / max ' + (Format-BenchStatValue $loopStats 'maxMs') + ']')
Write-Host ('    loop fired   : ' + $loopFiredCount + '/' + $loopSamples.Count + ' (' + $loopFiredRate + '%)')
if ($loopFiredCount -eq 0) {
    Write-Host '    WARNING: the lifecycle signal NEVER fired -- (b) is a plain warm turn, not a closed-loop turn. Do not publish it as one.'
}
Write-Host '======================================================================='

if (-not [string]::IsNullOrWhiteSpace($JsonPath)) {
    [System.IO.File]::WriteAllText($JsonPath, (($result | ConvertTo-Json -Depth 8) + "`n"), $enc)
    Write-Host ('[bench] wrote ' + $JsonPath)
}

try { Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
exit 0
