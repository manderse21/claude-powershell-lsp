#Requires -Version 5.1

# Performance benchmark tests (Pester 5) -- dispatch 000040, Gap C.
#
# WHAT THIS MEASURES + GUARDS: the two latencies that define the tool's feel, timed
# against the REAL daemon/pipe path, repeatably, with a structured emit and a CI
# regression guard:
#   * cold-start -- SessionStart hook -> the per-session PSES daemon reaches 'ready'.
#   * warm-path  -- one edit -> diagnostic round-trip against an already-warm daemon.
# The numbers are emitted to <data>/logs/benchmark-results.json (uploaded as a CI
# artifact) and printed to the run log; the guard asserts each median stays under a
# documented, deliberately GENEROUS threshold.
#
# THRESHOLDS (generous first pass -- dispatch 000040). Local Windows medians measured
# at build time: cold ~4.5 s, warm ~2.2 s (the README's prior reference was ~6 s cold
# / ~1998 ms warm). The bounds below are ~4x the local median: loose enough that the
# slower, noisier hosted runners (especially macOS) never flake a median-of-N, tight
# enough to catch a gross regression or a near-failure -- cold approaching the daemon's
# own 30 s startup ceiling, warm approaching the 18 s client hard cap. They are NOT a
# tight SLA: the harness EMITS the real per-leg numbers so a later pass can tighten
# them once CI latency is characterized across all four legs. Never hardcode a measured
# value as the bound; these are bounds, not measurements.
#
# Runs on the same platforms as the integration/corpus suites (Windows/Linux/macOS);
# other platforms self-skip. Spawns pwsh as the analysis host on every leg. If the
# daemon genuinely cannot reach 'ready', the median is -1 and the test FAILS loudly --
# it never fabricates a passing number.

. (Join-Path $PSScriptRoot 'bench/Benchmark.Common.ps1')

# Discovery-time platform gate (StrictMode-safe).
$script:OnWindows = if (Test-Path 'Variable:\IsWindows') { [bool]$IsWindows } else { $true }
$script:OnLinux = (Test-Path 'Variable:\IsLinux') -and [bool]$IsLinux
$script:OnMacOS = (Test-Path 'Variable:\IsMacOS') -and [bool]$IsMacOS
$script:SkipBench = -not ($script:OnWindows -or $script:OnLinux -or $script:OnMacOS)

Describe 'Performance benchmark (dispatch 000040)' -Skip:$script:SkipBench {

    BeforeAll {
        . (Join-Path $PSScriptRoot 'bench/Benchmark.Common.ps1')

        # Thresholds + sample counts are defined HERE (run phase), not at the script top:
        # a top-level $script: assignment runs only in Pester's discovery pass and is $null
        # by the time BeforeAll/It execute (which would silently run zero iterations).
        $script:ColdThresholdMs = 20000
        $script:WarmThresholdMs = 9000
        $script:ColdIterations = 3
        $script:WarmIterations = 5
        $paths = Get-BenchPaths
        $script:ScriptsDir = $paths.ScriptsDir
        $script:FixturePath = $paths.FixturePath

        $script:DataDir = if (-not [string]::IsNullOrWhiteSpace($env:PSLS_TEST_DATA_DIR)) {
            $env:PSLS_TEST_DATA_DIR
        } else {
            Join-Path ([System.IO.Path]::GetTempPath()) 'psls-bench-data'
        }
        New-Item -ItemType Directory -Force -Path $script:DataDir | Out-Null
        $env:CLAUDE_PLUGIN_DATA = $script:DataDir

        # Idempotent bootstrap (no-op if already vendored) -- NOT timed as cold-start.
        & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:ScriptsDir 'ensure-pses.ps1') 2>&1 | Out-Null
        & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:ScriptsDir 'ensure-pssa.ps1') 2>&1 | Out-Null

        # --- cold-start: a fresh per-session daemon each iteration ---
        $coldSamples = @()
        for ($i = 0; $i -lt $script:ColdIterations; $i++) {
            $sid = 'bench-cold-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
            $coldSamples += (Measure-BenchColdStartMs -ScriptsDir $script:ScriptsDir -DataRoot $script:DataDir -SessionId $sid)
            Start-Sleep -Milliseconds 500
        }
        $script:ColdStats = Get-BenchStats -Values $coldSamples

        # --- warm-path: one warm daemon, prime once, then time real content edits ---
        $warmSid = 'bench-warm-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $sf = Join-Path $script:DataDir ('session/' + $warmSid + '.json')
        Invoke-BenchHook -ScriptPath (Join-Path $script:ScriptsDir 'session-start.ps1') `
            -StdinJson (@{ session_id = $warmSid } | ConvertTo-Json -Compress) `
            -ExtraArgs @('-PreferredHost', 'pwsh') -CapMs 60000 -DataRoot $script:DataDir | Out-Null
        $script:WarmDaemon = $null
        for ($i = 0; $i -lt 80; $i++) {
            if (Test-Path -LiteralPath $sf) {
                $o = Get-Content -LiteralPath $sf -Raw | ConvertFrom-Json
                if ($o.state -eq 'ready') { $script:WarmDaemon = $o; break }
            }
            Start-Sleep -Milliseconds 100
        }
        $script:WarmSid = $warmSid

        $warmSamples = @()
        $script:WarmScratchDir = Join-Path $script:DataDir ('bench-warm-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        if ($null -ne $script:WarmDaemon) {
            New-Item -ItemType Directory -Force -Path $script:WarmScratchDir | Out-Null
            $scratch = Join-Path $script:WarmScratchDir 'edit.ps1'
            Set-Content -LiteralPath $scratch -Value (Get-Content -LiteralPath $script:FixturePath -Raw) -Encoding ascii
            # Prime (first analysis of this file) -- discarded so steady-state is timed.
            Measure-BenchWarmPathMs -ScriptsDir $script:ScriptsDir -DataRoot $script:DataDir -SessionId $warmSid -ScratchFile $scratch | Out-Null
            for ($i = 0; $i -lt $script:WarmIterations; $i++) {
                Add-Content -LiteralPath $scratch -Value ('# edit ' + $i) -Encoding ascii   # real content change -> fresh analysis
                $warmSamples += (Measure-BenchWarmPathMs -ScriptsDir $script:ScriptsDir -DataRoot $script:DataDir -SessionId $warmSid -ScratchFile $scratch)
            }
        }
        $script:WarmStats = Get-BenchStats -Values $warmSamples

        $script:Results = Write-BenchmarkResults -DataRoot $script:DataDir -ColdStats $script:ColdStats -WarmStats $script:WarmStats `
            -Thresholds @{ coldStartMs = $script:ColdThresholdMs; warmPathMs = $script:WarmThresholdMs }
        Write-Host ('BENCHMARK cold-start ms: ' + ($script:ColdStats | ConvertTo-Json -Compress))
        Write-Host ('BENCHMARK warm-path  ms: ' + ($script:WarmStats | ConvertTo-Json -Compress))
    }

    AfterAll {
        # Tear the warm daemon down + clean scratch (cold daemons self-teardown per iteration).
        try {
            Invoke-BenchHook -ScriptPath (Join-Path $script:ScriptsDir 'session-end.ps1') `
                -StdinJson (@{ session_id = $script:WarmSid } | ConvertTo-Json -Compress) `
                -ExtraArgs @() -CapMs 8000 -DataRoot $script:DataDir | Out-Null
        } catch { }
        if ($null -ne $script:WarmDaemon) {
            foreach ($pidVal in @($script:WarmDaemon.pid, $script:WarmDaemon.psesPid)) {
                if ($pidVal) { Stop-Process -Id $pidVal -Force -ErrorAction SilentlyContinue }
            }
        }
        if ($script:WarmScratchDir -and (Test-Path -LiteralPath $script:WarmScratchDir)) {
            Remove-Item -LiteralPath $script:WarmScratchDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'measured a cold-start latency (the daemon reached ready)' {
        # -1 means no iteration reached ready -> the daemon path did not run. Fail loud;
        # NEVER fabricate a number (dispatch 000040 invariant).
        $script:ColdStats.medianMs | Should -BeGreaterThan 0 -Because 'the SessionStart -> ready path must be measurable'
    }

    It 'cold-start median is within the regression threshold' {
        # The median is fetched THROUGH the selected-count floor (dispatch 000172, D1). Reading
        # $script:ColdStats.medianMs directly here would let a zero-sample run satisfy the
        # ceiling with the -1 "nothing was measured" sentinel; Get-BenchMeasuredMedian throws
        # first, so this comparison is UNREACHABLE unless something was actually measured.
        $median = Get-BenchMeasuredMedian -Stats $script:ColdStats -Label 'cold-start'
        $median | Should -BeLessThan $script:ColdThresholdMs `
            -Because ("cold-start median " + $median + "ms over " + $script:ColdStats.count +
                " sample(s) must stay under the generous " + $script:ColdThresholdMs + "ms guard")
    }

    It 'measured a warm-path latency (the edit round-trip ran)' {
        $script:WarmStats.medianMs | Should -BeGreaterThan 0 -Because 'the edit -> diagnostic round-trip must be measurable'
    }

    It 'warm-path median is within the regression threshold' {
        # Same floor on the warm measurement -- see the cold-start note above.
        $median = Get-BenchMeasuredMedian -Stats $script:WarmStats -Label 'warm-path'
        $median | Should -BeLessThan $script:WarmThresholdMs `
            -Because ("warm-path median " + $median + "ms over " + $script:WarmStats.count +
                " sample(s) must stay under the generous " + $script:WarmThresholdMs + "ms guard")
    }

    It 'emitted a structured benchmark results file' {
        $resultsPath = Join-Path $script:DataDir 'logs/benchmark-results.json'
        (Test-Path -LiteralPath $resultsPath) | Should -BeTrue
        $obj = Get-Content -LiteralPath $resultsPath -Raw | ConvertFrom-Json
        $obj.schema | Should -BeExactly 'powershell-lsp-benchmark/1'
        $obj.coldStart.medianMs | Should -BeGreaterThan 0
        $obj.warmPath.medianMs | Should -BeGreaterThan 0
    }
}

# ===========================================================================
# Bench-harness defects banked by dispatch 000171 and closed by 000172.
#
# These are PURE-FUNCTION tests over tests/bench/Benchmark.Common.ps1 -- no daemon, no pipe, no
# platform gate -- so they run on all four legs in ~milliseconds and cannot be skipped along with
# the daemon-backed benchmark above. Each one REPRODUCES the original defect before asserting the
# repair, because a fix whose bug was never reproduced is a guess.
# ===========================================================================

Describe 'D1 -- a threshold assertion is UNREACHABLE on an empty sample set (dispatch 000172)' {

    BeforeAll {
        . (Join-Path $PSScriptRoot 'bench/Benchmark.Common.ps1')
        # The exact thresholds the shipped benchmark guards with.
        $script:D1Cold = 20000
        $script:D1Warm = 9000
        $script:D1Empty = Get-BenchStats -Values @()
        $script:D1Real = Get-BenchStats -Values @(1200, 1400, 1300)
    }

    It 'REPRO: an empty sample set yields count 0 and the -1 "not measured" sentinel' {
        [int]$script:D1Empty.count | Should -Be 0
        [int]$script:D1Empty.medianMs | Should -Be -1
        [int]$script:D1Empty.p95Ms | Should -Be -1
    }

    It 'REPRO: the OLD bare comparison PASSES on that empty set -- the vacuous match, on BOTH measurements' {
        # This is the defect as it shipped. `-1 -lt 20000` is true, so a run that measured NOTHING
        # reported as comfortably within budget. Asserting -Not -Throw here is asserting that the
        # bug is real: if PowerShell ever stopped accepting this, the fix below would be moot.
        { $script:D1Empty.medianMs | Should -BeLessThan $script:D1Cold } | Should -Not -Throw
        { $script:D1Empty.medianMs | Should -BeLessThan $script:D1Warm } | Should -Not -Throw
    }

    It 'REPRO: swapping the sentinel for $null would NOT have fixed it -- fork 2 refuted' {
        # Recorded because it was a pre-authorized option: PowerShell coerces $null to 0 in a
        # numeric comparison, so a $null aggregate passes a ceiling exactly as -1 does. The cure
        # has to be a count floor, not a different sentinel value.
        ($null -lt $script:D1Cold) | Should -BeTrue
        { $null | Should -BeLessThan $script:D1Cold } | Should -Not -Throw
    }

    It 'FIXED: the floor THROWS on the empty set, for BOTH the cold and the warm measurement' {
        { Get-BenchMeasuredMedian -Stats $script:D1Empty -Label 'cold-start' } |
            Should -Throw -ExpectedMessage '*NOTHING WAS MEASURED*cold-start*'
        { Get-BenchMeasuredMedian -Stats $script:D1Empty -Label 'warm-path' } |
            Should -Throw -ExpectedMessage '*NOTHING WAS MEASURED*warm-path*'
    }

    It 'FIXED: a null stats object throws rather than comparing' {
        { Get-BenchMeasuredMedian -Stats $null -Label 'cold-start' } |
            Should -Throw -ExpectedMessage '*NOTHING WAS MEASURED*'
    }

    It 'FIXED: an INCONSISTENT stats object (counted, but negative median) throws' {
        # Defends the floor itself: a stats-shaped object that claims samples but carries the
        # sentinel must not slip a -1 through the gate.
        $bogus = [ordered]@{ samples = @(); count = 3; minMs = -1; medianMs = -1; p95Ms = -1; maxMs = -1 }
        { Get-BenchMeasuredMedian -Stats $bogus -Label 'cold-start' } |
            Should -Throw -ExpectedMessage '*INCONSISTENT STATS*'
    }

    It 'GREEN: a real sample set passes THROUGH the floor and still compares normally' {
        # The floor must not become a wall -- a genuine measurement still reaches the threshold.
        $median = Get-BenchMeasuredMedian -Stats $script:D1Real -Label 'cold-start'
        $median | Should -Be 1300
        $median | Should -BeLessThan $script:D1Cold
    }

    It 'DISPLAY: an unmeasured aggregate renders as "n/a", never as a -1 latency' {
        (Format-BenchStatValue $script:D1Empty 'medianMs') | Should -BeExactly 'n/a (0 samples)'
        (Format-BenchStatValue $script:D1Real 'medianMs') | Should -BeExactly '1300'
    }
}

Describe 'D2 -- the cold-start session-file read survives a MID-WRITE read (dispatch 000172)' {

    BeforeAll {
        . (Join-Path $PSScriptRoot 'bench/Benchmark.Common.ps1')

        # Fault-injection fixtures: the shapes a poller actually sees while the daemon writes.
        $script:D2Dir = Join-Path $TestDrive ('d2-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $script:D2Dir | Out-Null
        $enc = New-Object System.Text.UTF8Encoding($false)
        $script:D2Whole = Join-Path $script:D2Dir 'whole.json'
        $script:D2Torn = Join-Path $script:D2Dir 'torn.json'
        $script:D2Empty = Join-Path $script:D2Dir 'empty.json'
        $script:D2NoState = Join-Path $script:D2Dir 'nostate.json'
        $script:D2Absent = Join-Path $script:D2Dir 'absent.json'
        [System.IO.File]::WriteAllText($script:D2Whole, '{"state":"ready","pid":4242,"psesPid":4243}', $enc)
        # A genuinely TRUNCATED write -- the first 18 bytes of the whole file, as a 25ms poll
        # landing mid-flush would see.
        [System.IO.File]::WriteAllText($script:D2Torn, '{"state":"rea', $enc)
        [System.IO.File]::WriteAllText($script:D2Empty, '', $enc)
        # Parses cleanly, but the daemon has not written `state` yet.
        [System.IO.File]::WriteAllText($script:D2NoState, '{"pid":4242}', $enc)
    }

    It 'REPRO: the OLD unguarded read THROWS on a TORN file (ConvertFrom-Json cannot parse it)' {
        {
            & {
                Set-StrictMode -Version Latest
                $info = Get-Content -LiteralPath $script:D2Torn -Raw | ConvertFrom-Json
                if ($info.state -eq 'ready') { 'ready' }
            }
        } | Should -Throw
    }

    It 'REPRO: the OLD unguarded read THROWS under StrictMode when `state` is not written YET' {
        # This one parses -- so it is NOT a JSON failure. It is the StrictMode property access:
        # three separate callers set Set-StrictMode -Version Latest, and a dotted read of an
        # absent member is a TERMINATING error under it.
        {
            & {
                Set-StrictMode -Version Latest
                $info = Get-Content -LiteralPath $script:D2NoState -Raw | ConvertFrom-Json
                if ($info.state -eq 'ready') { 'ready' }
            }
        } | Should -Throw
    }

    It 'FIXED: the guarded reader degrades to a MISS on a <Case> file, and never throws' -ForEach @(
        @{ Case = 'torn'; File = 'torn.json' }
        @{ Case = 'empty'; File = 'empty.json' }
        @{ Case = 'no-state-yet'; File = 'nostate.json' }
        @{ Case = 'absent'; File = 'absent.json' }
    ) {
        $path = Join-Path $script:D2Dir $File
        { & { Set-StrictMode -Version Latest; Read-BenchSessionFile -Path $path } | Out-Null } | Should -Not -Throw
        $probe = & { Set-StrictMode -Version Latest; Read-BenchSessionFile -Path $path }
        $probe | Should -Not -BeNullOrEmpty
        $probe.State | Should -BeNullOrEmpty -Because "the $Case shape is a not-yet-ready MISS, not a state"
    }

    It 'FIXED: a WHOLE file still reads ready, with its pids -- the guard did not blind the reader' {
        $probe = & { Set-StrictMode -Version Latest; Read-BenchSessionFile -Path $script:D2Whole }
        $probe.State | Should -BeExactly 'ready'
        [int](Get-BenchProp $probe.Info 'pid') | Should -Be 4242
        [int](Get-BenchProp $probe.Info 'psesPid') | Should -Be 4243
    }

    It 'FIXED: the teardown pid read is guarded too -- an absent pid yields $null, not a throw' {
        # Measure-BenchColdStartMs may carry the LAST partial parse into teardown, so neither
        # pid property is guaranteed to exist on it.
        $partial = & { Set-StrictMode -Version Latest; Read-BenchSessionFile -Path $script:D2NoState }
        { & { Set-StrictMode -Version Latest; Get-BenchProp $partial.Info 'psesPid' } } | Should -Not -Throw
        (Get-BenchProp $partial.Info 'psesPid') | Should -BeNullOrEmpty
        [int](Get-BenchProp $partial.Info 'pid') | Should -Be 4242
    }
}

Describe 'D4 -- the quiescence gate excludes its own apparatus DYNAMICALLY (dispatch 000172)' {
    # THE DEFECT, in one sentence: dispatch 000171 resolved the excluded process trees ONCE at
    # probe start, so every process the agent spawned DURING the probe had no ancestry in the
    # snapshot and scored as FOREIGN load -- 0.064 of the 0.3363 cores it measured at point P1,
    # against a 0.15-core threshold. The gate failed partly on its own apparatus's noise.
    #
    # The proof below is the one the charter asks for: spawn a child from the excluded tree DURING
    # a probe, and show the dynamic resolver excludes it where the static one counts it foreign.

    BeforeAll {
        . (Join-Path $PSScriptRoot 'bench/Quiescence.Common.ps1')
        $script:Q_Self = [int]$PID
    }

    It 'the process table is readable on this host (the exclusion needs ancestry)' {
        # Floor: every assertion below is vacuous against an empty parent map, because a map with
        # no entries excludes nothing but the roots and every claim about descendants is trivially
        # true. Fail loud instead.
        $map = Get-ProcessParentMap
        $map.Count | Should -BeGreaterThan 0 -Because 'ancestry cannot be resolved without a process table'
        $map.ContainsKey($script:Q_Self) | Should -BeTrue -Because 'this very process must appear in it'
    }

    It 'RED PROOF: a child spawned MID-PROBE is FOREIGN to the static set and EXCLUDED by the dynamic one' {
        # STATIC: resolved before the child exists -- exactly what 000171 did, once, at probe start.
        $staticExcl = Resolve-QuiescenceExclusion -AgentRootPid $script:Q_Self -ProbeRootPid $script:Q_Self
        $staticPids = @($staticExcl.ExcludedPids)

        $child = $null
        try {
            # Spawn a real child of THIS process, mid-probe, from inside the excluded tree.
            $child = Start-Process -FilePath (Get-Process -Id $PID).Path `
                -ArgumentList @('-NoLogo', '-NoProfile', '-Command', 'Start-Sleep -Seconds 20') `
                -PassThru
            $child | Should -Not -BeNullOrEmpty
            $childPid = [int]$child.Id

            # Give the OS a moment to publish the new process into the process table.
            $seen = $false
            for ($i = 0; $i -lt 40 -and -not $seen; $i++) {
                if ((Get-ProcessParentMap).ContainsKey($childPid)) { $seen = $true; break }
                Start-Sleep -Milliseconds 100
            }
            $seen | Should -BeTrue -Because 'the spawned child must reach the process table to be classifiable'

            # DYNAMIC: re-resolved now, exactly as Measure-QuiescenceSample does per sample.
            $dynamicExcl = Resolve-QuiescenceExclusion -AgentRootPid $script:Q_Self -ProbeRootPid $script:Q_Self
            $dynamicPids = @($dynamicExcl.ExcludedPids)

            # THE TWO HALVES OF THE PROOF.
            $staticPids | Should -Not -Contain $childPid -Because (
                'the static set was resolved before the child existed -- this is the 000171 defect, ' +
                'and it is what made apparatus load score as foreign')
            $dynamicPids | Should -Contain $childPid -Because (
                're-resolving per sample classifies the child by its ANCESTRY, so a process spawned ' +
                'mid-probe is correctly recognized as apparatus')

            # BOTH EXCLUDED PID SETS, reported so the exclusion stays auditable.
            Write-Host ('    [D4] agent tree pids (dynamic, ' + @($dynamicExcl.AgentPids).Count + '): ' +
                ((@($dynamicExcl.AgentPids) | ForEach-Object { [string]$_ }) -join ' '))
            Write-Host ('    [D4] probe tree pids (dynamic, ' + @($dynamicExcl.ProbePids).Count + '): ' +
                ((@($dynamicExcl.ProbePids) | ForEach-Object { [string]$_ }) -join ' '))
            Write-Host ('    [D4] static set size ' + $staticPids.Count + ' -> dynamic set size ' +
                $dynamicPids.Count + '; mid-probe child ' + $childPid + ' is in the dynamic set only.')
        } finally {
            if ($null -ne $child) { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'a GRANDCHILD is excluded too -- ancestry is walked, not just direct parentage' {
        # The 000171 defect would also have missed a process two levels down. Walking ancestry
        # rather than matching a parent id is what makes the whole subtree apparatus.
        $map = Get-ProcessParentMap
        $tree = @(Get-ProcessTreePids -RootPids @($script:Q_Self) -ParentMap $map)
        # Synthesize a two-level descendant in the map: real spawning of a grandchild is timing
        # dependent, while the CLASSIFIER is pure and can be exercised exactly.
        $fakeChild = 999001; $fakeGrandchild = 999002
        $map[$fakeChild] = $script:Q_Self
        $map[$fakeGrandchild] = $fakeChild
        $withKin = @(Get-ProcessTreePids -RootPids @($script:Q_Self) -ParentMap $map)

        $tree | Should -Not -Contain $fakeGrandchild
        $withKin | Should -Contain $fakeChild
        $withKin | Should -Contain $fakeGrandchild -Because 'exclusion must cover the whole subtree'
    }

    It 'an UNRELATED process is NOT excluded -- the exclusion is not a blanket' {
        # The control that keeps the fix honest. An exclusion that swallowed everything would pass
        # every assertion above and make the gate unfailable, which is the 000170 failure mode in
        # reverse. Something real must still be able to count as foreign.
        $map = Get-ProcessParentMap
        $map[999003] = 999004        # parented outside this tree entirely
        $map[999004] = 1
        $tree = @(Get-ProcessTreePids -RootPids @($script:Q_Self) -ParentMap $map)
        $tree | Should -Not -Contain 999003
        $tree | Should -Not -Contain 999004
    }

    It 'a SELF-PARENTED entry (a torn process table) terminates instead of spinning' {
        $map = @{ 999005 = 999005 }
        { Get-ProcessTreePids -RootPids @($script:Q_Self) -ParentMap $map | Out-Null } | Should -Not -Throw
        @(Get-ProcessTreePids -RootPids @($script:Q_Self) -ParentMap $map) | Should -Not -Contain 999005
    }

    It 'the 0.15-core threshold is UNCHANGED by this train' {
        # Pinned deliberately: 000171's measurements were taken against this value, and moving it
        # would silently convert its failed gate into a passed one. 000172 fixes the apparatus and
        # explicitly does NOT touch the bar.
        Get-QuiescenceThresholdCores | Should -Be 0.15
    }

    It 'the probe is an INSTRUMENT, not a discovered test' {
        # The committed-under-tests/ hazard, closed by the convention this directory already uses:
        # Pester's default discovery matches *.Tests.ps1, so neither file is ever collected.
        $benchDir = Join-Path $PSScriptRoot 'bench'
        (Test-Path -LiteralPath (Join-Path $benchDir 'Invoke-QuiescenceProbe.ps1')) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $benchDir 'Quiescence.Common.ps1')) | Should -BeTrue
        @(Get-ChildItem -LiteralPath $benchDir -Filter '*.Tests.ps1' -File).Count | Should -Be 0 -Because (
            'tests/bench/ holds instruments only -- Invoke-LatencyBench.ps1 and Benchmark.Common.ps1 ' +
            'already establish that convention, and the probe follows it')
    }
}

Describe 'E1 -- EVERY documented probe parameter is smoke-run WITH that parameter (dispatch 000197)' {
    # THE DEFECT THIS CLOSES, in one sentence: Invoke-QuiescenceProbe.ps1 assigned $bootMap only
    # inside the branch that DEFAULTS -AgentRootPid, while the ancestry-chain walk read it on every
    # path, so under the Set-StrictMode -Version Latest the probe sets for itself, BOTH documented
    # explicit forms -- -AgentRootPid <pid> and the documented -AgentRootPid 0 -- died with
    # "The variable '$bootMap' cannot be retrieved because it has not been set" BEFORE taking a
    # single sample. Dispatch 000195 measured it; the gate had only ever been run the one way that
    # happened to work, and that way roots the exclusion at the launching shell instead of the
    # agent session.
    #
    # THE CLASS, not the instance: an instrument's documented parameter must be SMOKE-RUN WITH THAT
    # PARAMETER. So this block does not hand-list the forms -- it ENUMERATES them from the probe's
    # own param() block and its own comment-based help, requires the two to agree, and runs one
    # invocation per documented parameter. A parameter added to the probe tomorrow and not smoke-run
    # makes this block RED.

    BeforeAll {
        $script:E1_Probe = Join-Path $PSScriptRoot 'bench/Invoke-QuiescenceProbe.ps1'
        $script:E1_Src = Get-Content -LiteralPath $script:E1_Probe -Raw

        $e1Tokens = $null; $e1Errors = $null
        $script:E1_Ast = [System.Management.Automation.Language.Parser]::ParseInput(
            $script:E1_Src, [ref]$e1Tokens, [ref]$e1Errors)
        $script:E1_ParseErrors = @($e1Errors)

        # ENUMERATED, not hand-listed: the param() block's own parameter names.
        $script:E1_ParamNames = @($script:E1_Ast.ParamBlock.Parameters |
                ForEach-Object { [string]$_.Name.VariablePath.UserPath } | Sort-Object)

        # ENUMERATED, not hand-listed: the comment-based help's own .PARAMETER entries.
        $script:E1_HelpNames = @([regex]::Matches($script:E1_Src, '(?m)^\s*\.PARAMETER\s+(\S+)\s*$') |
                ForEach-Object { [string]$_.Groups[1].Value } | Sort-Object)

        # The VALUE each documented parameter is smoke-run WITH. Only the values live here; the
        # NAMES come from the script above. A documented parameter with no entry FAILS the test
        # below rather than being silently skipped -- that refusal is the class-closing part.
        # Each value is deliberately DIFFERENT from the short-run base below, so that the form for
        # a parameter is distinguishable from the default form rather than collapsing onto it --
        # a form identical to the base does not exercise its parameter at all.
        $script:E1_Values = @{
            AgentRootPid = @(0, [int]$PID)   # both documented forms: the documented 0, and a real pid
            Samples      = @(3)
            IntervalMs   = @(150)
            Label        = @('E1')
        }

        # Short-run base so the enumeration is cheap; overridden per-form when the parameter under
        # test IS one of these.
        $script:E1_Base = [ordered]@{ Samples = 2; IntervalMs = 100 }

        function script:Invoke-E1Probe {
            param([System.Collections.IDictionary] $Bound)
            $argList = @()
            foreach ($k in @($Bound.Keys)) { $argList += ('-' + [string]$k); $argList += $Bound[$k] }
            $raw = (& pwsh -NoLogo -NoProfile -File $script:E1_Probe @argList 2>&1 |
                    Out-String -Width 500)
            $code = $LASTEXITCODE
            # NORMALIZE before matching: an un-normalized needle is defeated by the column padding
            # in the probe's own sample lines and by any host-width wrapping in the captured text.
            $norm = ([regex]::Replace([string]$raw, '\s+', ' ')).Trim()
            return [pscustomobject]@{
                Args     = ($argList -join ' ')
                ExitCode = $code
                Raw      = [string]$raw
                Norm     = $norm
            }
        }
    }

    It 'the probe parses, and its parameter list is non-empty (the enumeration floor)' {
        # FLOOR. Every assertion below is vacuous over an empty enumeration: "every documented
        # parameter was smoke-run" is trivially true when zero are documented. Fail loud instead.
        $script:E1_ParseErrors.Count | Should -Be 0 -Because 'an unparseable probe enumerates nothing'
        $script:E1_ParamNames.Count | Should -BeGreaterOrEqual 2 -Because (
            'the charter floor: at least two documented parameter forms must be enumerated and run')
        $script:E1_HelpNames.Count | Should -BeGreaterOrEqual 2 -Because (
            'the help text must document at least as many forms as the floor requires')
    }

    It 'the param() block and the comment-based help document THE SAME parameters' {
        # Both directions, non-vacuously (the floor above guarantees the sets are not empty). A
        # parameter in param() but not in help is an UNDOCUMENTED form that this block would then
        # never enumerate; one in help but not in param() is a form that cannot be passed at all.
        foreach ($p in $script:E1_ParamNames) {
            $script:E1_HelpNames | Should -Contain $p -Because (
                "parameter -$p exists but is not documented, so it would escape the smoke-run enumeration")
        }
        foreach ($h in $script:E1_HelpNames) {
            $script:E1_ParamNames | Should -Contain $h -Because (
                "help documents -$h but the param() block does not declare it")
        }
    }

    It 'the probe still sets Set-StrictMode -Version Latest (without it this whole block is vacuous)' {
        # NON-VACUITY GUARD. The regression being guarded is a STRICTMODE-ONLY failure: with strict
        # mode dropped, an unset $bootMap is silently $null, .ContainsKey() on it throws nothing
        # useful, and every execution assertion below would pass against the very defect it exists
        # to catch. So the strict-mode line is itself an asserted precondition.
        $norm = ([regex]::Replace($script:E1_Src, '\s+', ' '))
        $norm | Should -Match 'Set-StrictMode -Version Latest'
    }

    It 'every documented parameter has a smoke-run value (a new parameter must be run, not skipped)' {
        # THE CLASS-CLOSING REFUSAL. Adding a parameter to the probe without adding it here makes
        # this test RED, which is what stops the next parameter from shipping un-smoke-run.
        foreach ($p in $script:E1_HelpNames) {
            $script:E1_Values.ContainsKey($p) | Should -BeTrue -Because (
                "-$p is documented but has no smoke-run value, so it would ship without ever being " +
                'executed with that parameter -- add it to $script:E1_Values')
        }
    }

    It 'STRUCTURAL: $bootMap is assigned unconditionally, not inside a branch' {
        # The fix itself, guarded structurally rather than by comment. The pre-fix code assigned
        # $bootMap inside the -AgentRootPid-defaulting if-block; the chain walk reads it on every
        # path. This is RED against that code.
        $assigns = @($script:E1_Ast.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $n.Left.VariablePath.UserPath -eq 'bootMap'
                }, $true))
        $assigns.Count | Should -BeGreaterThan 0 -Because 'the probe must still resolve a boot map'
        foreach ($a in $assigns) {
            $parent = $a.Parent
            $nested = $false
            while ($null -ne $parent) {
                if ($parent -is [System.Management.Automation.Language.IfStatementAst]) { $nested = $true; break }
                $parent = $parent.Parent
            }
            $nested | Should -BeFalse -Because (
                'an assignment reached only on one path cannot satisfy a read taken on every path')
        }
    }

    It 'EVERY enumerated documented form reaches sampling under strict mode' {
        # THE EXECUTION PROOF. One real probe run per documented parameter (plus the default form),
        # each asserting two things: no variable-retrieval throw, and sampling actually REACHED.
        # Exit code alone cannot carry this -- the pre-fix crash and a legitimate FAIL verdict both
        # exit 1, so "reached sampling" is asserted from the probe's own sample line.
        $forms = @()

        # The DEFAULT form: -AgentRootPid omitted entirely.
        $forms += , ([ordered]@{ Samples = 2; IntervalMs = 100 })

        # One form per documented parameter, per documented value.
        foreach ($p in $script:E1_HelpNames) {
            foreach ($v in @($script:E1_Values[$p])) {
                $bound = [ordered]@{}
                foreach ($k in @($script:E1_Base.Keys)) { $bound[$k] = $script:E1_Base[$k] }
                $bound[$p] = $v
                $forms += , $bound
            }
        }

        # FLOOR on what actually ran, not on what was planned.
        $forms.Count | Should -BeGreaterOrEqual 2 -Because 'the charter floor is at least two executed forms'
        $forms.Count | Should -BeGreaterOrEqual $script:E1_HelpNames.Count -Because (
            'each documented parameter contributes at least one executed form')

        # DISTINCTNESS FLOOR. Counting forms is not the same as counting DIFFERENT forms: a value
        # equal to the base collapses that parameter's form onto the default one, and the suite
        # would then report N runs while actually exercising fewer than N invocations.
        $rendered = @($forms | ForEach-Object {
                $b = $_
                (@(@($b.Keys) | ForEach-Object { ('-' + [string]$_ + ' ' + [string]$b[$_]) }) -join ' ')
            })
        @($rendered | Sort-Object -Unique).Count | Should -Be $forms.Count -Because (
            'every enumerated form must be a DISTINCT invocation, not a duplicate of the base form')

        $ran = 0
        foreach ($f in $forms) {
            $r = Invoke-E1Probe -Bound $f
            $ran++
            Write-Host ('    [E1] ' + $r.Args + '  -> exit ' + $r.ExitCode)

            $r.Norm | Should -Not -Match 'cannot be retrieved because it has not been set' -Because (
                'form "' + $r.Args + '" must not die on an unset variable under strict mode')
            $r.Norm | Should -Match 'sample 1 foreign' -Because (
                'form "' + $r.Args + '" must actually REACH sampling, not merely exit')
            $r.ExitCode | Should -BeIn @(0, 1) -Because (
                'form "' + $r.Args + '" must produce a PASS or FAIL verdict, not a crash or a no-sample exit')
        }
        $ran | Should -Be $forms.Count
    }
}
