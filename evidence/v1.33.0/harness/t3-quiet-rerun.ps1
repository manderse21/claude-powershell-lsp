#Requires -Version 5.1
<#
    t3-quiet-rerun.ps1 -- the QUIET-HOST re-measurement of SLO T3, at release
    identity C = 6ab2d24. Dispatch 000273. ASCII only.

    WHY THIS SCRIPT EXISTS. The v1.33.0 freeze measured T3 on a saturated host
    (84-95% CPU, 619-677 processes, several co-tenant agent sessions live) and
    recorded 6 of 15 sessions returning TWO "NOT checked" edits where the target
    allows one. That reading was recorded as measured and NOT re-run until green,
    per the charter. It left T3 neither passed nor failed but PENDING a compliant
    measurement. This script is that measurement.

    WHAT IT REFUSES TO DO. It will not produce a second non-compliant reading by
    accident. A quiescence PRE-FLIGHT runs first and ABORTS if the host is not at
    least as quiet as the run that ratified the bar; load is then sampled
    CONTINUOUSLY, not just at block boundaries, so the record proves quietness
    across the whole run rather than at its edges. If the host goes loud mid-run
    the result is still written, but flagged non-compliant -- an honest reading
    that says so beats a clean-looking number.

    WHAT IT MEASURES. T3 is a per-session property, so only the two blocks that
    produce per-session "NOT checked" counts are re-run:
      m2  -- cold start, 10 sessions, small fixture
      m4b -- large-file convergence, 5 sessions, the p100 runtime file
    That is the same 15 sessions the ratified standing was judged on. m1 and m35
    are deliberately NOT re-run: neither produces a per-session unchecked count,
    so neither can move T3.

    RUN IT LIKE THIS, with every Claude Code session closed:

        pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File <this file>

    Expect roughly 20-30 minutes. Leave the machine alone while it runs.
#>

[CmdletBinding()]
param(
    [string] $Worktree = 'C:\Users\mande\projects\work\nortam\claude-powershell-lsp\worktrees\s000273-freeze',
    [string] $Commit   = '6ab2d24bf254787520ad9449c4e6c17f74ee708d',
    [string] $Base     = 'C:\Users\mande\AppData\Local\Temp\psl-t3',
    [string] $LiveData = 'C:\Users\mande\.claude\plugins\data\powershell-lsp-claude-powershell-lsp',

    # The quiescence bar. NOT invented: the v1.32.0 run that RATIFIED T1-T6 measured
    # 13-32% CPU median with ~385 processes at its block boundaries. Requiring <= 35%
    # is "at least as quiet as the run the bar was ratified on".
    [int] $MaxCpuMedian = 35,
    [int] $MaxAgentProcs = 0,
    [int] $PreflightSeconds = 30,

    # Escape hatch. Use only deliberately; it is recorded in the result either way.
    [switch] $IgnoreQuiescenceGate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Harness = Split-Path -Parent $MyInvocation.MyCommand.Path
$Bundle  = Split-Path -Parent $Harness
$Results = Join-Path $Bundle 'results'
$Out     = Join-Path $Base 'out'
$SampleFile = Join-Path $Base 'load-samples.txt'
$LogFile = Join-Path $Results 't3-quiet-rerun.log'

function Write-Both([string] $m) {
    Write-Host $m
    try { Add-Content -LiteralPath $LogFile -Value $m -Encoding ASCII } catch { }
}

function Get-CpuNow {
    try {
        return [double](Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor `
            -Filter "Name='_Total'" -ErrorAction Stop).PercentProcessorTime
    } catch { return $null }
}

function Get-AgentProcs {
    # Co-tenant agent sessions are what made the freeze reading non-compliant.
    $names = @('claude', 'node')
    $n = 0
    foreach ($nm in $names) {
        $n += @(Get-Process -Name $nm -ErrorAction SilentlyContinue).Count
    }
    return $n
}

function Get-Median([double[]] $v) {
    $s = @($v | Sort-Object); $n = $s.Count
    if ($n -eq 0) { return $null }
    if ($n % 2 -eq 1) { return [double]$s[[int][math]::Floor($n / 2)] }
    return (([double]$s[$n / 2 - 1] + [double]$s[$n / 2]) / 2.0)
}

# ------------------------------------------------------------------ preconditions
New-Item -ItemType Directory -Path $Base -Force | Out-Null
New-Item -ItemType Directory -Path $Out -Force | Out-Null
if (Test-Path -LiteralPath $LogFile) { Remove-Item -LiteralPath $LogFile -Force }

Write-Both ''
Write-Both '=================================================================='
Write-Both ' T3 QUIET-HOST RE-RUN -- powershell-lsp v1.33.0 at C = 6ab2d24'
Write-Both '=================================================================='
Write-Both ("started: " + (Get-Date).ToString('o'))

foreach ($p in @(
    @{ path = $Worktree; what = 'the freeze worktree' },
    @{ path = (Join-Path $Harness 'stage-c.ps1'); what = 'stage-c.ps1' },
    @{ path = (Join-Path $Harness 'prove-equals-c.ps1'); what = 'prove-equals-c.ps1' },
    @{ path = (Join-Path $Harness 'measure.ps1'); what = 'measure.ps1' },
    @{ path = $LiveData; what = 'the live PSES/PSSA bundle root' }
)) {
    if (-not (Test-Path -LiteralPath $p.path)) {
        Write-Both ('ABORT: cannot find ' + $p.what + ' at ' + $p.path)
        Write-Both '       Re-create the worktree with:'
        Write-Both ('       git -C C:\Users\mande\projects\work\nortam\claude-powershell-lsp worktree add --no-track -b t3-rerun worktrees\s000273-freeze ' + $Commit)
        throw ('missing prerequisite: ' + $p.what)
    }
}

# THE WORKTREE IS NOT AT C, AND MUST NOT BE. This bundle -- including this script --
# is committed ON TOP of C, so HEAD is the evidence branch tip. Requiring HEAD == C
# would be the same over-strict identity mistake that a tip-equality assertion made
# earlier in this dispatch. What the run actually needs is:
#   (1) C RESOLVES in this repo, because staging is `git archive C`;
#   (2) C is an ANCESTOR of HEAD, so this worktree descends from the release commit;
#   (3) the working tree's .gitignore matches C's -- prove-equals-c.ps1 asserts that
#       itself and throws if not, so it is not re-checked here.
# The bytes actually measured are proven equal to C by the equality proof, which is
# where that claim belongs -- not in a guess about which commit is checked out.
$head = (& git -C $Worktree rev-parse HEAD).Trim()
$ctype = (& git -C $Worktree cat-file -t $Commit 2>$null)
if ($LASTEXITCODE -ne 0 -or ([string]$ctype).Trim() -cne 'commit') {
    Write-Both ('ABORT: C (' + $Commit + ') does not resolve to a commit in ' + $Worktree)
    Write-Both '       Fetch it first:  git -C <repo> fetch origin'
    throw 'C does not resolve'
}
& git -C $Worktree merge-base --is-ancestor $Commit $head
if ($LASTEXITCODE -ne 0) {
    Write-Both ('ABORT: C (' + $Commit + ') is not an ancestor of this worktree HEAD (' + $head + ')')
    Write-Both '       This worktree does not descend from the release commit.'
    throw 'worktree does not descend from C'
}
Write-Both ('worktree HEAD    : ' + $head + '  (the evidence branch tip -- expected)')
Write-Both ('C is an ancestor : yes  -- staging will `git archive ' + $Commit.Substring(0, 12) + '`')

foreach ($exe in @('pwsh', 'git')) {
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { throw ('required on PATH: ' + $exe) }
}

# ------------------------------------------------------------------ quiescence pre-flight
Write-Both ''
Write-Both ('--- quiescence pre-flight (' + $PreflightSeconds + 's) ---')
Write-Both ('    bar: CPU median <= ' + $MaxCpuMedian + '%, agent/node processes <= ' + $MaxAgentProcs)
Write-Both '    basis: the v1.32.0 run that RATIFIED T1-T6 measured 13-32% CPU with ~385 processes.'
Write-Both ''

$pf = @()
$pfProcs = @()
for ($i = 0; $i -lt $PreflightSeconds; $i++) {
    $c = Get-CpuNow
    if ($null -ne $c) { $pf += $c }
    $pfProcs += (Get-AgentProcs)
    if ($i % 5 -eq 0) {
        Write-Host ("    t+" + $i + "s  cpu=" + $c + "%  agent/node procs=" + $pfProcs[-1]) -NoNewline
        Write-Host "`r" -NoNewline
    }
    Start-Sleep -Seconds 1
}
Write-Host ''

$pfCpu = Get-Median $pf
$pfAgents = ($pfProcs | Measure-Object -Maximum).Maximum
$pfTotal = @(Get-Process).Count
Write-Both ('    CPU median            : ' + $pfCpu + '%')
Write-Both ('    CPU max               : ' + ($pf | Measure-Object -Maximum).Maximum + '%')
Write-Both ('    agent/node procs (max): ' + $pfAgents)
Write-Both ('    total processes       : ' + $pfTotal)

$quietOk = ($pfCpu -le $MaxCpuMedian -and $pfAgents -le $MaxAgentProcs)
if (-not $quietOk) {
    Write-Both ''
    Write-Both '    QUIESCENCE GATE: NOT MET.'
    if ($pfAgents -gt $MaxAgentProcs) {
        Write-Both ('      -> ' + $pfAgents + ' claude/node process(es) still running. Close every Claude Code')
        Write-Both '         session (and any editor running one) and re-run this script.'
    }
    if ($pfCpu -gt $MaxCpuMedian) {
        Write-Both ('      -> CPU median ' + $pfCpu + '% exceeds ' + $MaxCpuMedian + '%. Something is busy; let it settle.')
        Write-Both '         Top CPU consumers right now:'
        Get-Process | Sort-Object CPU -Descending | Select-Object -First 6 |
            ForEach-Object { Write-Both ('           ' + ('{0,-24}' -f $_.Name) + 'pid=' + $_.Id) }
    }
    if (-not $IgnoreQuiescenceGate) {
        Write-Both ''
        Write-Both '    ABORTING rather than producing a second non-compliant reading.'
        Write-Both '    (Deliberate override: re-run with -IgnoreQuiescenceGate.)'
        throw 'quiescence gate not met'
    }
    Write-Both '    -IgnoreQuiescenceGate set: continuing, and the result will be flagged NON-COMPLIANT.'
} else {
    Write-Both '    QUIESCENCE GATE: MET.'
}

# ------------------------------------------------------------------ background load sampler
# Sampling ONLY at block boundaries is what let the freeze run look quieter than it
# was between them. This samples throughout and the aggregate goes in the record.
if (Test-Path -LiteralPath $SampleFile) { Remove-Item -LiteralPath $SampleFile -Force }
$samplerScript = @'
param([string] $OutFile)
while ($true) {
    try {
        $c = (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop).PercentProcessorTime
        $a = @(Get-Process -Name claude -ErrorAction SilentlyContinue).Count + @(Get-Process -Name node -ErrorAction SilentlyContinue).Count
        $t = @(Get-Process).Count
        Add-Content -LiteralPath $OutFile -Value ("{0},{1},{2},{3}" -f (Get-Date).ToString('o'), $c, $a, $t) -Encoding ASCII
    } catch { }
    Start-Sleep -Seconds 5
}
'@
$samplerPath = Join-Path $Base 'sampler.ps1'
Set-Content -LiteralPath $samplerPath -Value $samplerScript -Encoding ASCII
$sampler = Start-Process -FilePath 'pwsh' `
    -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $samplerPath, '-OutFile', $SampleFile) `
    -PassThru -WindowStyle Hidden
Write-Both ('load sampler started (pid ' + $sampler.Id + '), sampling every 5s for the whole run')

$blocks = @()
$equality = @()
$failure = $null

try {
    # -------------------------------------------------------------- stage C
    Write-Both ''
    Write-Both '--- staging C into an isolated scratch plugin cache ---'
    & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Harness 'stage-c.ps1') `
        -Commit $Commit -Repo $Worktree -Base $Base -LiveData $LiveData 2>&1 |
        ForEach-Object { Write-Both ('    ' + $_) }
    if ($LASTEXITCODE -ne 0) { throw ('staging failed: exit ' + $LASTEXITCODE) }

    function Invoke-Equality([string] $label, [string] $tag) {
        $json = Join-Path $Out ('equality-' + $tag + '.json')
        & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Harness 'prove-equals-c.ps1') `
            -Commit $Commit -Repo $Worktree -Root (Join-Path $Base 'root') -Data (Join-Path $Base 'data') `
            -Label $label -JsonOut $json 2>&1 | ForEach-Object { Write-Both ('    ' + $_) }
        if ($LASTEXITCODE -ne 0) { throw ('EQUALITY PROOF FAILED at ' + $label) }
        return (Get-Content -LiteralPath $json -Raw | ConvertFrom-Json)
    }

    Write-Both ''
    Write-Both '--- equality proof: the measured build IS C (before) ---'
    $equality += (Invoke-Equality 'before-t3' 'before-t3')

    # -------------------------------------------------------------- the two T3 blocks
    foreach ($b in @(
        @{ name = 'm2';  label = 'M2 cold start -- 10 sessions, small fixture'; minutes = '4-6' },
        @{ name = 'm4b'; label = 'M4b large-file convergence -- 5 sessions, p100 file'; minutes = '10-15' }
    )) {
        Write-Both ''
        Write-Both ('=========== BLOCK ' + $b.name + ' : ' + $b.label + ' (~' + $b.minutes + ' min) ===========')
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Harness 'measure.ps1') `
            -Block $b.name -Base $Base 2>&1 | ForEach-Object { Write-Both ('    ' + $_) }
        $rc = $LASTEXITCODE
        $sw.Stop()
        Write-Both ('    block ' + $b.name + ' exit=' + $rc + ' elapsed=' + [math]::Round($sw.Elapsed.TotalSeconds, 1) + 's')
        if ($rc -ne 0) { throw ('block ' + $b.name + ' FAILED with exit ' + $rc) }
        $blocks += (Get-Content -LiteralPath (Join-Path $Out ($b.name + '.json')) -Raw | ConvertFrom-Json)
    }

    Write-Both ''
    Write-Both '--- equality proof: the measured build WAS STILL C (after) ---'
    $equality += (Invoke-Equality 'after-t3' 'after-t3')
}
catch {
    $failure = $_.Exception.Message
    Write-Both ''
    Write-Both ('RUN FAILED: ' + $failure)
}
finally {
    try { Stop-Process -Id $sampler.Id -Force -ErrorAction SilentlyContinue } catch { }
    # Scoped sweep: every kill is filtered on this run's private base path, a string
    # a co-tenant daemon structurally cannot carry.
    try {
        Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction Stop | ForEach-Object {
            if ($_.CommandLine -and $_.CommandLine.Contains('psl-t3')) {
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            }
        }
    } catch { }
}

# ------------------------------------------------------------------ load aggregate
$cpu = @(); $agents = @(); $procs = @()
if (Test-Path -LiteralPath $SampleFile) {
    foreach ($line in (Get-Content -LiteralPath $SampleFile)) {
        $p = $line -split ','
        if ($p.Count -ge 4) { $cpu += [double]$p[1]; $agents += [int]$p[2]; $procs += [int]$p[3] }
    }
}
$cpuMedian = Get-Median $cpu
$cpuMax = $null; $agentMax = $null; $procMax = $null
if ($cpu.Count) { $cpuMax = ($cpu | Measure-Object -Maximum).Maximum }
if ($agents.Count) { $agentMax = ($agents | Measure-Object -Maximum).Maximum }
if ($procs.Count) { $procMax = ($procs | Measure-Object -Maximum).Maximum }

# COMPLIANT means quiet at pre-flight AND quiet THROUGHOUT, not merely at the edges.
$compliant = ($quietOk -and $cpu.Count -gt 0 -and $cpuMedian -le $MaxCpuMedian -and $agentMax -le $MaxAgentProcs)

# ------------------------------------------------------------------ the T3 verdict
$sessions = @()
foreach ($b in $blocks) {
    if ($b.PSObject.Properties['sessions']) {
        foreach ($s in $b.sessions) { $sessions += [ordered]@{ fixture = 'small'; i = $s.i; unchecked = [int]$s.unchecked } }
    }
    if ($b.PSObject.Properties['per_session']) {
        foreach ($s in $b.per_session) { $sessions += [ordered]@{ fixture = 'large'; i = $s.i; unchecked = [int]$s.unchecked } }
    }
}
$over = @($sessions | Where-Object { $_.unchecked -gt 1 })
$maxUnchecked = $null
if ($sessions.Count) { $maxUnchecked = ($sessions | ForEach-Object { $_.unchecked } | Measure-Object -Maximum).Maximum }

$t3Verdict = 'INCONCLUSIVE'
if ($null -eq $failure -and $sessions.Count -ge 15) {
    if ($over.Count -eq 0) { $t3Verdict = 'PASS' } else { $t3Verdict = 'FAIL' }
}

# Convergence rides along free -- same block, and T4's standing is worth re-reading.
$converged = $null; $convSessions = $null; $fixtureBytes = $null
foreach ($b in $blocks) {
    if ($b.PSObject.Properties['converged']) {
        $converged = $b.converged
        $convSessions = @($b.per_session).Count
        $fixtureBytes = $b.fixture.bytes
    }
}

$result = [ordered]@{
    gate = 'T3 quiet-host re-run (the compliant measurement the freeze deferred)'
    commit = $Commit
    version = '1.33.0'
    measured_at = (Get-Date).ToString('o')
    blocks_rerun = @('m2', 'm4b')
    blocks_not_rerun = @{
        m1 = 'warm per-edit latency -- produces no per-session unchecked count, cannot move T3'
        m35 = 'one 120-edit session -- not a per-session sample, cannot move T3'
    }
    host = [ordered]@{
        os = [string](Get-CimInstance Win32_OperatingSystem).Caption + ' ' + [string](Get-CimInstance Win32_OperatingSystem).Version
        cpu = [string](Get-CimInstance Win32_Processor).Name
        pwsh = [string]$PSVersionTable.PSVersion
    }
    quiescence = [ordered]@{
        bar_cpu_median_pct = $MaxCpuMedian
        bar_agent_procs = $MaxAgentProcs
        bar_basis = 'the v1.32.0 run that RATIFIED T1-T6 measured 13-32% CPU median with ~385 processes'
        preflight_seconds = $PreflightSeconds
        preflight_cpu_median = $pfCpu
        preflight_agent_procs_max = $pfAgents
        preflight_met = $quietOk
        during_run_samples = $cpu.Count
        during_run_cpu_median = $cpuMedian
        during_run_cpu_max = $cpuMax
        during_run_agent_procs_max = $agentMax
        during_run_total_procs_max = $procMax
        sampled_continuously = $true
        gate_overridden = [bool]$IgnoreQuiescenceGate
        COMPLIANT = $compliant
    }
    comparison = [ordered]@{
        note = 'the reading this replaces'
        freeze_run_cpu_median_by_block = '84-95%'
        freeze_run_processes = '619-677'
        freeze_run_t3 = '6 of 15 sessions returned 2 NOT-checked edits'
    }
    equality_proofs = @($equality | ForEach-Object {
        [ordered]@{ label = $_.label; equal = $_.equal; tracked = $_.tracked_observed; digest = $_.manifest_sha256 }
    })
    t3 = [ordered]@{
        target = 'at most ONE edit per session returns NOT checked, and only during cold start'
        total_sessions = $sessions.Count
        max_unchecked_per_session = $maxUnchecked
        sessions_over_one = $over.Count
        per_session = $sessions
        verdict = $t3Verdict
    }
    also_observed = [ordered]@{
        note = 'same blocks, recorded because they came free -- NOT a re-litigation of the frozen bar'
        t4_convergence = [ordered]@{ converged = $converged; sessions = $convSessions; fixture_bytes = $fixtureBytes }
    }
    run_failure = $failure
}

New-Item -ItemType Directory -Path $Results -Force | Out-Null
$resultPath = Join-Path $Results 't3-quiet-rerun.json'
($result | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $resultPath -Encoding UTF8
foreach ($b in @('m2', 'm4b')) {
    $src = Join-Path $Out ($b + '.json')
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $Results ('t3-rerun-' + $b + '.json')) -Force }
}

# LF, no BOM -- the repo is LF-tracked.
foreach ($f in @(Get-ChildItem -LiteralPath $Results -File | Where-Object { $_.Name -like 't3-*' })) {
    $t = [IO.File]::ReadAllText($f.FullName) -replace "`r`n", "`n"
    [IO.File]::WriteAllText($f.FullName, $t, (New-Object Text.UTF8Encoding($false)))
}

# The bundle carries a check asserting SHA256SUMS covers EVERY file, so adding files
# without regenerating it would leave the bundle self-inconsistent. Regenerate here.
$rows = @()
foreach ($f in (Get-ChildItem -LiteralPath $Bundle -Recurse -File | Where-Object { $_.Name -ne 'SHA256SUMS.txt' } | Sort-Object FullName)) {
    $rel = $f.FullName.Substring($Bundle.Length + 1).Replace('\', '/')
    $rows += ((Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower() + '  ' + $rel)
}
$rows = @($rows | Sort-Object { ($_ -split '  ', 2)[1] })
[IO.File]::WriteAllText((Join-Path $Bundle 'SHA256SUMS.txt'), (($rows -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))

# ------------------------------------------------------------------ report
Write-Both ''
Write-Both '=================================================================='
Write-Both ' RESULT'
Write-Both '=================================================================='
Write-Both ('  quiescence COMPLIANT : ' + $compliant + '   (pre-flight cpu median ' + $pfCpu + '%, during-run median ' + $cpuMedian + '%, max ' + $cpuMax + '%, agent procs max ' + $agentMax + ')')
Write-Both ('  equality proofs      : ' + @($equality | Where-Object { $_.equal }).Count + ' of ' + $equality.Count + ' EQUAL to C')
Write-Both ('  sessions measured    : ' + $sessions.Count + ' (10 small + 5 large)')
Write-Both ('  max unchecked/session: ' + $maxUnchecked)
Write-Both ('  sessions over one    : ' + $over.Count)
Write-Both ('  T3 VERDICT           : ' + $t3Verdict)
if ($null -ne $converged) { Write-Both ('  (also) convergence   : ' + $converged + ' of ' + $convSessions + ' on the ' + $fixtureBytes + '-byte fixture') }
if ($failure) { Write-Both ('  RUN FAILURE          : ' + $failure) }
Write-Both ''
Write-Both ('  result JSON : ' + $resultPath)
Write-Both ('  run log     : ' + $LogFile)
Write-Both ''
Write-Both '=================================================================='
Write-Both ' WHAT TO DO WITH THIS'
Write-Both '=================================================================='

if ($failure -or $t3Verdict -eq 'INCONCLUSIVE') {
    Write-Both ''
    Write-Both '  The run did not complete cleanly. Do NOT commit this.'
    Write-Both '  Hand the two paths above to Claude next session and say:'
    Write-Both '     "the T3 quiet re-run failed, here is the log"'
} elseif (-not $compliant) {
    Write-Both ''
    Write-Both '  The host was NOT quiet enough, so this reading is NON-COMPLIANT and'
    Write-Both '  does NOT settle T3. Do not commit it as the compliant measurement.'
    Write-Both '  Close everything and re-run, or hand the JSON to Claude to judge.'
} else {
    Write-Both ''
    Write-Both ('  This IS the compliant reading. T3 = ' + $t3Verdict + '.')
    Write-Both ''
    if ($t3Verdict -eq 'PASS') {
        Write-Both '  T3 is MET on a compliant host. That clears the hold on evidence PR #196.'
    } else {
        Write-Both '  T3 is MISSED on a compliant host -- which makes it a real behavioural'
        Write-Both '  regression, not a load artifact. That is a release-blocking fact to'
        Write-Both '  surface, and it is Mike''s call what follows. Do not re-run for a'
        Write-Both '  better number.'
    }
    Write-Both ''
    Write-Both '  OPTION A -- commit it yourself, to the PR #196 branch:'
    Write-Both ''
    Write-Both ('    cd ' + $Worktree)
    Write-Both '    git status --short'
    Write-Both '    git add evidence/v1.33.0'
    Write-Both ('    git commit -m "evidence(v1.33.0): T3 quiet-host re-run at C -- T3 ' + $t3Verdict + '" -- evidence/v1.33.0')
    Write-Both '    git push'
    Write-Both ''
    Write-Both '    (SHA256SUMS.txt has already been regenerated over the whole bundle,'
    Write-Both '     so the bundle-manifest check stays green. The staged files are the'
    Write-Both '     result JSON, the two block JSONs, the run log, this harness script,'
    Write-Both '     and the refreshed manifest -- nothing else.)'
    Write-Both ''
    Write-Both '  OPTION B -- hand it to Claude next session. Say:'
    Write-Both ''
    Write-Both '    "the T3 quiet re-run is done, result is in evidence/v1.33.0/results/'
    Write-Both ('     t3-quiet-rerun.json, T3 came out ' + $t3Verdict + '"')
    Write-Both ''
    Write-Both '    Claude then updates the outbox (T3 moves off PENDING), refreshes the'
    Write-Both '    SLO table, and handles the PR #196 hold.'
}
Write-Both ''
Write-Both ('finished: ' + (Get-Date).ToString('o'))
