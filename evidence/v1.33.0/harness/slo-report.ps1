#Requires -Version 5.1
# slo-report.ps1 -- derive the T1-T6 regression table from the raw block results.
#
# Dispatch 000273 (freeze 1B). ASCII only.
#
# SLO-BASELINES.md section 9 is FROZEN: this script reads the ratified targets as
# constants and reports measured-at-C against them. It does not compute a target
# from a measurement, and a FAIL is emitted as a FAIL.
#
# Every figure is derived from the block JSON rather than transcribed, so the table
# cannot drift from the evidence it claims to summarise.

param(
    [string] $Out    = 'C:\Users\mande\AppData\Local\Temp\psl-273\out',
    [string] $Commit = '6ab2d24bf254787520ad9449c4e6c17f74ee708d'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-Block([string] $n) {
    $p = Join-Path $Out ($n + '.json')
    if (-not (Test-Path -LiteralPath $p)) { throw ('missing block result: ' + $p) }
    return (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json)
}

$m1  = Read-Block 'm1'
$m2  = Read-Block 'm2'
$m35 = Read-Block 'm35'
$m4b = Read-Block 'm4b'

foreach ($pair in @(@('m1', $m1), @('m2', $m2), @('m35', $m35), @('m4b', $m4b))) {
    if ($pair[1].commit -cne $Commit) {
        throw ('block ' + $pair[0] + ' was measured at ' + $pair[1].commit + ', not C (' + $Commit + ')')
    }
}

function Get-Summary($block, [string] $metric, [string] $prop = 'summaries') {
    foreach ($s in $block.$prop) { if ($s.metric -eq $metric) { return $s } }
    return $null
}

# ---------------------------------------------------------------- T1
# The timeoutMs-governed round trip is the DAEMON-SIDE settle window plus the
# correction pass -- analysisMs + codeActionMs -- which is what the 5000 ms
# timeoutMs actually caps. Past it the client degrades to log-only. Counted over
# every WARM kept edit in the suite: M1 (small), M35 (120-edit run), M4b (large).
$cap = 5000
$roundTrips = New-Object System.Collections.Generic.List[double]

# M1 and M35 report analysis/codeAction as summaries only; use their maxima as the
# worst case and their n as the count, then verify the worst case fits the cap.
$m1a  = Get-Summary $m1  'daemon_analysisMs'
$m1ca = Get-Summary $m1  'daemon_codeActionMs'
$m35a = Get-Summary $m35 'daemon_analysisMs_whole_run'
# M4b carries per-edit arrays, so it is counted exactly.
foreach ($s in $m4b.per_session) {
    for ($i = 0; $i -lt @($s.keptAnalysis).Count; $i++) {
        $ca = 0.0
        if ($i -lt @($s.keptCodeAction).Count) { $ca = [double]$s.keptCodeAction[$i] }
        $roundTrips.Add([double]$s.keptAnalysis[$i] + $ca)
    }
}
$m4bOver   = @($roundTrips | Where-Object { $_ -gt $cap }).Count
$m4bN      = $roundTrips.Count
# Worst case for the summary-only blocks: max analysis + max codeAction (pessimistic,
# because the two maxima need not fall on the same edit).
$m1Worst  = [double]$m1a.max + [double]$m1ca.max
$m35Worst = [double]$m35a.max
$m1Over   = $(if ($m1Worst  -gt $cap) { 'UNKNOWN-worst-case-over' } else { 0 })
$m35Over  = $(if ($m35Worst -gt $cap) { 'UNKNOWN-worst-case-over' } else { 0 })

$t1N    = [int]$m1a.n + [int]$m35a.n + $m4bN
$t1Over = $m4bOver + $(if ($m1Worst -gt $cap) { [int]$m1a.n } else { 0 }) + $(if ($m35Worst -gt $cap) { [int]$m35a.n } else { 0 })
$t1Pct  = [math]::Round(100.0 * ($t1N - $t1Over) / $t1N, 2)
$t1Pass = ($t1Pct -ge 99.0)

# ---------------------------------------------------------------- T2
# User-visible per-edit wall, across every warm block. The bar is 10 s; 1 s is the
# stated aspiration and is reported separately, never as the pass line.
$wallMaxes = @(
    @{ block = 'm1 (small, warm)';        s = (Get-Summary $m1  'end_to_end_wall_ms') },
    @{ block = 'm35 (120-edit run)';      s = (Get-Summary $m35 'end_to_end_wall_ms_whole_run') },
    @{ block = 'm4b (large, converged)';  s = (Get-Summary $m4b 'end_to_end_wall_ms' 'm4_conditional_summaries') }
)
$t2Max = ($wallMaxes | ForEach-Object { [double]$_.s.max } | Measure-Object -Maximum).Maximum
$t2Pass = ($t2Max -lt 10000)
$t2AspirationMet = ($t2Max -lt 1000)

# ---------------------------------------------------------------- T3
# At most ONE edit per session returns "NOT checked", and only during cold start.
# Counted per session across BOTH fixtures, exactly as the ratified standing was.
$t3Sessions = @()
foreach ($s in $m2.sessions)      { $t3Sessions += [ordered]@{ fixture = 'small'; i = $s.i; unchecked = [int]$s.unchecked } }
foreach ($s in $m4b.per_session)  { $t3Sessions += [ordered]@{ fixture = 'large'; i = $s.i; unchecked = [int]$s.unchecked } }
$t3Over  = @($t3Sessions | Where-Object { $_.unchecked -gt 1 })
$t3Max   = ($t3Sessions | ForEach-Object { $_.unchecked } | Measure-Object -Maximum).Maximum
$t3Pass  = ($t3Over.Count -eq 0)

# ---------------------------------------------------------------- T4
# Every shipped .ps1/.psm1 settles on the edit path; the p100 runtime file is the
# binding case, and the block measures exactly it.
$t4Pass = ([int]$m4b.converged -eq @($m4b.per_session).Count -and [int]$m4b.converged -gt 0)

# ---------------------------------------------------------------- T5
# Daemon + PSES steady-state working set under 512 MB.
$dws = $null; $pws = $null
foreach ($s in $m35.mem_summaries) {
    if ($s.metric -eq 'daemon_working_set_mb') { $dws = $s }
    if ($s.metric -eq 'pses_working_set_mb')   { $pws = $s }
}
$t5Median = [math]::Round([double]$dws.median + [double]$pws.median, 1)
$t5Peak   = [math]::Round([double]$dws.max + [double]$pws.max, 1)
$t5Pass   = ($t5Peak -lt 512)

# ---------------------------------------------------------------- T6
# No monotonic upward latency trend; memory plateaus.
$q = $m35.drift
$wallDrift     = [math]::Round(100.0 * ([double]$q.last_quartile_wall_median - [double]$q.first_quartile_wall_median) / [double]$q.first_quartile_wall_median, 1)
$analysisDrift = [math]::Round(100.0 * ([double]$q.last_quartile_analysis_median - [double]$q.first_quartile_analysis_median) / [double]$q.first_quartile_analysis_median, 1)
$memFirst = [double]$m35.mem_samples[0].daemon_ws_mb + [double]$m35.mem_samples[0].pses_ws_mb
$memLast  = [double]$m35.mem_samples[-1].daemon_ws_mb + [double]$m35.mem_samples[-1].pses_ws_mb
$memDrift = [math]::Round($memLast - $memFirst, 1)
$t6Pass = ($wallDrift -le 0 -and $analysisDrift -lt 5 -and [math]::Abs($memDrift) -lt 50 -and [int]$m35.excluded -eq 0)

# ---------------------------------------------------------------- load context
$loads = @()
foreach ($pair in @(@('m1', $m1), @('m2', $m2), @('m35', $m35), @('m4b', $m4b))) {
    $loads += [ordered]@{
        block = $pair[0]
        cpu_median_before = $pair[1].load_before.cpu_median
        cpu_median_after  = $pair[1].load_after.cpu_median
        processes_before  = $pair[1].load_before.processes
    }
}

$rows = @(
    [ordered]@{ id='T1'; target='timeoutMs-governed round trip (analysisMs + codeActionMs) within the shipped 5000 ms cap on >= 99% of warm edits'
                measured=('' + $t1Pct + '% of ' + $t1N + ' warm edits within 5000 ms; worst observed round trip ' + [math]::Round((@($m1Worst,$m35Worst,($roundTrips | Measure-Object -Maximum).Maximum) | Measure-Object -Maximum).Maximum,1) + ' ms')
                verdict=$(if ($t1Pass) { 'PASS' } else { 'FAIL' }) }
    [ordered]@{ id='T2'; target='user-visible per-edit wall under 10 s (1 s aspiration, not the pass line)'
                measured=('worst per-edit wall ' + $t2Max + ' ms across all warm blocks; 1 s aspiration met = ' + $t2AspirationMet)
                verdict=$(if ($t2Pass) { 'PASS' } else { 'FAIL' }) }
    [ordered]@{ id='T3'; target='at most ONE edit per session returns NOT checked, and only during cold start'
                measured=('max ' + $t3Max + ' per session; ' + $t3Over.Count + ' of ' + $t3Sessions.Count + ' sessions returned more than one')
                verdict=$(if ($t3Pass) { 'PASS' } else { 'FAIL' }) }
    [ordered]@{ id='T4'; target='every shipped .ps1/.psm1 settles on the edit path'
                measured=('p100 runtime file (' + $m4b.fixture.bytes + ' bytes) converged in ' + $m4b.converged + ' of ' + @($m4b.per_session).Count + ' sessions, cap ' + $m4b.attempt_cap_each)
                verdict=$(if ($t4Pass) { 'PASS' } else { 'FAIL' }) }
    [ordered]@{ id='T5'; target='daemon + PSES steady-state working set under 512 MB'
                measured=('median ' + $t5Median + ' MB, peak ' + $t5Peak + ' MB')
                verdict=$(if ($t5Pass) { 'PASS' } else { 'FAIL' }) }
    [ordered]@{ id='T6'; target='no monotonic upward per-edit latency trend; resident memory plateaus'
                measured=('wall Q1->Q4 ' + $wallDrift + '%, analysisMs Q1->Q4 ' + $analysisDrift + '%, daemon+PSES WS drift ' + $memDrift + ' MB over ' + $m35.attempted + ' edits / ' + $m35.run_seconds + ' s, ' + $m35.excluded + ' excluded')
                verdict=$(if ($t6Pass) { 'PASS' } else { 'FAIL' }) }
)

$report = [ordered]@{
    commit = $Commit
    version = '1.33.0'
    generated = (Get-Date).ToString('o')
    note = 'SLO-BASELINES.md section 9 is a FROZEN regression bar. Targets are read as constants; a FAIL is reported as measured and is not renegotiated here.'
    slo_table = $rows
    t3_detail = $t3Sessions
    load_context = $loads
    comparator = [ordered]@{
        note = 'SLO-BASELINES section 10 names analysisMs the load-insensitive comparator, because wall clock is not comparable between runs of unequal load.'
        m1_analysisMs_median_at_C = (Get-Summary $m1 'daemon_analysisMs').median
        m1_wall_median_at_C       = (Get-Summary $m1 'end_to_end_wall_ms').median
        m4b_analysisMs_median_at_C = (Get-Summary $m4b 'daemon_analysisMs' 'm4_conditional_summaries').median
        m4b_fixture_bytes_at_C     = $m4b.fixture.bytes
    }
}

($report | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $Out 'slo-regression.json') -Encoding UTF8

Write-Output ('SLO REGRESSION TABLE at C = ' + $Commit)
Write-Output ''
foreach ($r in $rows) {
    Write-Output (('{0,-4}{1,-6}' -f $r.id, $r.verdict) + $r.measured)
}
Write-Output ''
Write-Output 'LOAD CONTEXT (CPU _Total median at block boundaries):'
foreach ($l in $loads) {
    Write-Output ('  ' + ('{0,-5}' -f $l.block) + 'before=' + $l.cpu_median_before + '%  after=' + $l.cpu_median_after + '%  processes=' + $l.processes_before)
}
$fails = @($rows | Where-Object { $_.verdict -ne 'PASS' })
Write-Output ''
Write-Output ('MET ' + ($rows.Count - $fails.Count) + ' of ' + $rows.Count + '; MISSED: ' + $(if ($fails.Count) { ($fails | ForEach-Object { $_.id }) -join ', ' } else { 'none' }))
