#Requires -Version 5.1

# Diagnostic-correctness corpus tests (Pester 5) -- dispatch 000040, Gap A.
#
# WHAT THIS PROVES: that the diagnostics the tool REPORTS are correct, not merely
# present. For each curated sample (clean / known-bad-per-rule / parser-error) the
# test runs the REAL tool (warm PSES daemon + PScriptAnalyzer, or the in-process
# parser pre-pass) and asserts its live output matches a committed snapshot of what
# the tool emitted. A future behavior change becomes a visible, located test failure.
#
# THE INVARIANT (why this corpus is trustworthy): the expected findings are NEVER
# hand-authored or model-authored. Every snapshot in tests/corpus/expected/ was
# DERIVED by running the real tool (tests/corpus/Update-CorpusSnapshots.ps1) and
# reading the structured records it teed to its own dogfood capture log. This test
# re-derives the same way and compares. A hand-edited snapshot cannot make the test
# pass -- it would simply disagree with the live tool. See Corpus.Common.ps1.
#
# Runs on the same platforms as the integration suite (Windows/Linux/macOS -- named
# pipes map to Unix domain sockets on .NET); other platforms self-skip. Spawns pwsh
# as the analysis host on every leg, exactly like the integration tests.

. (Join-Path $PSScriptRoot 'corpus/Corpus.Common.ps1')

# Discovery-time platform gate (StrictMode-safe; PS 5.1 has no $IsWindows/$IsLinux).
$script:OnWindows = if (Test-Path 'Variable:\IsWindows') { [bool]$IsWindows } else { $true }
$script:OnLinux = (Test-Path 'Variable:\IsLinux') -and [bool]$IsLinux
$script:OnMacOS = (Test-Path 'Variable:\IsMacOS') -and [bool]$IsMacOS
$script:SkipCorpus = -not ($script:OnWindows -or $script:OnLinux -or $script:OnMacOS)

# Sample specs, enumerated at discovery time for the data-driven It blocks.
$script:CorpusSamples = @(Get-CorpusSampleSpec)

Describe 'Diagnostic-correctness corpus (dispatch 000040)' -Skip:$script:SkipCorpus {

    BeforeAll {
        . (Join-Path $PSScriptRoot 'corpus/Corpus.Common.ps1')
        $paths = Get-CorpusPaths
        $script:ScriptsDir = $paths.ScriptsDir

        # Share the integration suite's data root when CI pins it, so the PSES/PSSA
        # bootstrap is a no-op; else a local temp root.
        $script:DataDir = if (-not [string]::IsNullOrWhiteSpace($env:PSLS_TEST_DATA_DIR)) {
            $env:PSLS_TEST_DATA_DIR
        } else {
            Join-Path ([System.IO.Path]::GetTempPath()) 'psls-corpus-test-data'
        }
        New-Item -ItemType Directory -Force -Path $script:DataDir | Out-Null
        $env:CLAUDE_PLUGIN_DATA = $script:DataDir

        # Idempotent bootstrap of PSES + pinned PSSA (no-op if already vendored).
        & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:ScriptsDir 'ensure-pses.ps1') 2>&1 | Out-Null
        & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:ScriptsDir 'ensure-pssa.ps1') 2>&1 | Out-Null

        $script:Sid = 'corpus-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:DaemonInfo = Start-CorpusDaemon -ScriptsDir $script:ScriptsDir -DataRoot $script:DataDir -SessionId $script:Sid
        $script:ScratchDir = Join-Path $script:DataDir ('corpus-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

        # Derive every sample ONCE through the real tool; the It blocks compare the
        # pre-derived result against its committed snapshot.
        $script:Derived = @{ }
        if ($null -ne $script:DaemonInfo) {
            foreach ($spec in (Get-CorpusSampleSpec)) {
                $content = [System.IO.File]::ReadAllText($spec.SourcePath)
                $script:Derived[$spec.Label] = @(Invoke-CorpusDerivation -ScriptsDir $script:ScriptsDir `
                        -DataRoot $script:DataDir -SessionId $script:Sid -ScratchDir $script:ScratchDir `
                        -ScratchName $spec.ScratchName -Content $content)
            }
        }

        # The MEASURED correctness report (dispatch 000046, Gap A): compute the
        # false-positive rate + true-positive coverage from the SAME live findings the
        # snapshot test asserts, and emit it as a downloadable CI artifact alongside the
        # benchmark results (the CI workflow already uploads logs/**). The report It blocks
        # below assert the trust invariants (0% FP, 100% TP, full default-set coverage), so
        # the published README numbers are a real CI regression guard, not just prose.
        $script:CorpusReport = Get-CorpusCorrectnessReport -Derived $script:Derived
        try {
            $reportPath = Join-Path (Join-Path $script:DataDir 'logs') 'corpus-correctness-report.json'
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $reportPath) | Out-Null
            $enc = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($reportPath, (($script:CorpusReport | ConvertTo-Json -Depth 5) + "`n"), $enc)
        } catch { }
    }

    AfterAll {
        Stop-CorpusDaemon -ScriptsDir $script:ScriptsDir -DataRoot $script:DataDir -SessionId $script:Sid -DaemonInfo $script:DaemonInfo
        if ($script:ScratchDir -and (Test-Path -LiteralPath $script:ScratchDir)) {
            Remove-Item -LiteralPath $script:ScratchDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'brings up the warm daemon used to derive the corpus findings' {
        # If this fails the rest are meaningless -- a corpus derived from a dead tool
        # would assert emptiness, not correctness. Fail loud, never vacuously pass.
        $script:DaemonInfo | Should -Not -BeNullOrEmpty
    }

    It 'corpus is non-empty (samples are present)' {
        @($script:CorpusSamples).Count | Should -BeGreaterThan 0
    }

    It 'every sample has a committed expected snapshot' -ForEach $script:CorpusSamples {
        (Test-Path -LiteralPath $ExpectedPath) | Should -BeTrue -Because "$Label needs a derived snapshot -- run tests/corpus/Update-CorpusSnapshots.ps1"
    }

    It 'sample <Label>: live tool output matches the derived snapshot' -ForEach $script:CorpusSamples {
        $derived = $script:Derived[$Label]
        $snapshot = Import-CorpusSnapshot -Path $ExpectedPath
        $derivedCanon = Get-CorpusCanonicalString -Findings $derived
        $snapshotCanon = Get-CorpusCanonicalString -Findings $snapshot
        # The load-bearing assertion. If it goes RED, the tool's behavior changed: review
        # the diff, and ONLY if the change is intended re-run Update-CorpusSnapshots.ps1.
        $derivedCanon | Should -BeExactly $snapshotCanon -Because "live findings for $Label must match tests/corpus/expected/$Category/$Name.json"
    }

    # --- semantic meta-guards: prove the derivation exercised the real tool, so the
    #     snapshot comparison above can never pass by a vacuously-empty derivation. ---

    It 'clean samples surface zero findings (no false positives on clean code)' {
        # Re-enumerate at run phase: a discovery-time $script: variable is not carried
        # into the run pass (the -ForEach blocks above consume it at discovery).
        $clean = @(Get-CorpusSampleSpec | Where-Object { $_.Category -eq 'clean' })
        $clean.Count | Should -BeGreaterThan 0
        foreach ($s in $clean) {
            @($script:Derived[$s.Label]).Count | Should -Be 0 -Because "$($s.Label) is clean PowerShell"
        }
    }

    It 'known-bad samples each surface their named PSScriptAnalyzer rule' {
        $bad = @(Get-CorpusSampleSpec | Where-Object { $_.Category -eq 'bad' })
        $bad.Count | Should -BeGreaterThan 0
        foreach ($s in $bad) {
            $d = @($script:Derived[$s.Label])
            $d.Count | Should -BeGreaterThan 0 -Because "$($s.Label) must surface at least one finding"
            @($d | ForEach-Object { $_.ruleId }) | Should -Contain $s.RuleId -Because "$($s.Label) must surface rule $($s.RuleId)"
            ($d | Select-Object -First 1).source | Should -BeExactly 'PSScriptAnalyzer'
        }
    }

    It 'parser-error samples each surface a parser-sourced Error diagnostic' {
        $parser = @(Get-CorpusSampleSpec | Where-Object { $_.Category -eq 'parser' })
        $parser.Count | Should -BeGreaterThan 0
        foreach ($s in $parser) {
            $d = @($script:Derived[$s.Label])
            $d.Count | Should -BeGreaterThan 0 -Because "$($s.Label) must surface a parse error"
            ($d | Select-Object -First 1).source | Should -BeExactly 'parser'
            ($d | Select-Object -First 1).severity | Should -BeExactly 'Error'
        }
    }

    # --- measured correctness report (dispatch 000046, Gap A): the trust invariants the
    #     published README numbers stand on, guarded in CI on all four legs. ---

    It 'measured correctness: the corpus is large enough to be defensible (>= 15 known-good, >= 15 known-bad)' {
        $script:CorpusReport.knownGood | Should -BeGreaterOrEqual 15 -Because 'a defensible false-positive rate needs a real known-good sample'
        $script:CorpusReport.knownBad | Should -BeGreaterOrEqual 15 -Because 'a defensible true-positive coverage needs a real known-bad sample'
    }

    It 'measured correctness: zero false positives on clean code (FP rate == 0)' {
        # The headline trust number. Every clean sample must surface NOTHING under the
        # default config; a single false positive fails this and names the regression.
        $script:CorpusReport.falsePositiveRate | Should -Be 0 -Because (
            "$($script:CorpusReport.falsePositives) of $($script:CorpusReport.knownGood) clean sample(s) wrongly produced a finding")
    }

    It 'measured correctness: 100% true-positive coverage on known-bad code (TP rate == 100)' {
        # Every curated defect must be flagged with its expected rule. A miss means the tool
        # stopped surfacing a rule the corpus proves it once did.
        $script:CorpusReport.truePositiveRate | Should -Be 100 -Because (
            "$($script:CorpusReport.truePositives) of $($script:CorpusReport.knownBad) known-bad sample(s) surfaced their expected rule")
    }

    It 'measured correctness: every expected default rule is covered by a known-bad case' {
        # Spanning the WHOLE surfaced default rule set: each distinct expected rule must be
        # proven by at least one known-bad case (else "spanning the default set" is hollow).
        $expected = @($script:CorpusReport.rulesExpected)
        $covered = @($script:CorpusReport.rulesCovered)
        $expected.Count | Should -BeGreaterThan 0
        foreach ($rule in $expected) {
            $covered | Should -Contain $rule -Because "$rule has a known-bad case but did not surface"
        }
    }
}
