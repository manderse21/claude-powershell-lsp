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
        $script:ColdStats.medianMs | Should -BeLessThan $script:ColdThresholdMs `
            -Because ("cold-start median " + $script:ColdStats.medianMs + "ms must stay under the generous " + $script:ColdThresholdMs + "ms guard")
    }

    It 'measured a warm-path latency (the edit round-trip ran)' {
        $script:WarmStats.medianMs | Should -BeGreaterThan 0 -Because 'the edit -> diagnostic round-trip must be measurable'
    }

    It 'warm-path median is within the regression threshold' {
        $script:WarmStats.medianMs | Should -BeLessThan $script:WarmThresholdMs `
            -Because ("warm-path median " + $script:WarmStats.medianMs + "ms must stay under the generous " + $script:WarmThresholdMs + "ms guard")
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
