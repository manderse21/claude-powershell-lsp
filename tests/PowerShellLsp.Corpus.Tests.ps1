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
                $modDir = if ($spec.Contains('ModuleDir')) { [string]$spec.ModuleDir } else { '' }
                $script:Derived[$spec.Label] = @(Invoke-CorpusDerivation -ScriptsDir $script:ScriptsDir `
                        -DataRoot $script:DataDir -SessionId $script:Sid -ScratchDir $script:ScratchDir `
                        -ScratchName $spec.ScratchName -Bytes ([System.IO.File]::ReadAllBytes($spec.SourcePath)) `
                        -ModuleDir $modDir)
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

    It 'pre-pssa samples each surface their expected powershell-lsp-sourced owned diagnostic' {
        # The pre-pssa category now holds more than one owned finder (NonAsciiChar and, dispatch
        # 000139, CommandLinePlaceholder). Each fixture's expected rule is the FIRST dot-segment of
        # its name ($s.RuleId), so assert that per-fixture rather than a single hard-coded ruleId.
        $prepssa = @(Get-CorpusSampleSpec | Where-Object { $_.Category -eq 'pre-pssa' })
        $prepssa.Count | Should -BeGreaterThan 0
        foreach ($s in $prepssa) {
            $d = @($script:Derived[$s.Label])
            $d.Count | Should -BeGreaterThan 0 -Because "$($s.Label) must surface at least one pre-PSSA finding"
            ($d | Select-Object -First 1).source | Should -BeExactly 'powershell-lsp'
            ($d | Select-Object -First 1).ruleId | Should -BeExactly $s.RuleId
        }
    }

    It 'compat samples each surface a powershell-lsp-sourced PS7OnlySyntax diagnostic' {
        # dispatch 000096: the PS7-only-syntax pre-PSSA AST pass. Each known-bad compat
        # fixture (&& / ||, ternary, ?? / ??=, ?. / ?[]) must surface the pack's
        # powershell-lsp-sourced PS7OnlySyntax finding. The FIRST finding is the compat one
        # because client-side pre-PSSA findings are prepended to the daemon stream. The
        # host-awareness 0-FP proof (a #Requires -Version 7 file using &&) lives in the
        # 'clean' category and is asserted silent by the clean-samples guard above.
        $compat = @(Get-CorpusSampleSpec | Where-Object { $_.Category -eq 'compat' })
        $compat.Count | Should -BeGreaterThan 0
        foreach ($s in $compat) {
            $d = @($script:Derived[$s.Label])
            $d.Count | Should -BeGreaterThan 0 -Because "$($s.Label) must surface at least one PS7-only-syntax finding"
            ($d | Select-Object -First 1).source | Should -BeExactly 'powershell-lsp'
            ($d | Select-Object -First 1).ruleId | Should -BeExactly 'PS7OnlySyntax'
        }
    }

    It 'bashism samples each surface a powershell-lsp-sourced BashIsm diagnostic' {
        # dispatch 000097: the bash-ism command-name pre-PSSA AST pass (the closing slice of the
        # 000055 pack). Each known-bad bashism fixture (grep / sed / awk / export / which / touch
        # / chmod / chown / ln, plus a pipe-to-grep and a bash-ism-plus-PSSA-issue case) must
        # surface the pack's powershell-lsp-sourced BashIsm finding. The FIRST finding is the
        # bash-ism one because client-side pre-PSSA findings are prepended to the daemon stream.
        # The 0-FP suppression proofs (& grep, function touch, Set-Alias grep, string/comment
        # mentions, idiomatic cmdlets) live in the 'clean' category and are asserted silent by
        # the clean-samples guard above.
        $bashism = @(Get-CorpusSampleSpec | Where-Object { $_.Category -eq 'bashism' })
        $bashism.Count | Should -BeGreaterThan 0
        foreach ($s in $bashism) {
            $d = @($script:Derived[$s.Label])
            $d.Count | Should -BeGreaterThan 0 -Because "$($s.Label) must surface at least one bash-ism finding"
            ($d | Select-Object -First 1).source | Should -BeExactly 'powershell-lsp'
            ($d | Select-Object -First 1).ruleId | Should -BeExactly 'BashIsm'
        }
    }

    It 'a bash-ism does NOT suppress PSScriptAnalyzer analysis of the same file (merge path, not early-exit)' {
        # dispatch 000097 acceptance: a file carrying BOTH a bash-ism AND a PSSA-detectable issue
        # must surface BOTH -- proving the bash-ism finding rides the daemon MERGE path and never
        # gates the pre-PSSA early-exit that would skip the daemon. The withPssaIssue fixture pairs
        # a 'grep' call with a '-eq $null' comparison (PSPossibleIncorrectComparisonWithNull).
        $d = @($script:Derived['bashism/BashIsm.withPssaIssue'])
        $d.Count | Should -BeGreaterThan 1 -Because 'both the bash-ism and the PSSA finding must surface'
        @($d | Where-Object { $_.source -eq 'powershell-lsp' -and $_.ruleId -eq 'BashIsm' }).Count |
            Should -BeGreaterThan 0 -Because 'the bash-ism (grep) must surface'
        @($d | Where-Object { $_.source -eq 'PSScriptAnalyzer' }).Count |
            Should -BeGreaterThan 0 -Because 'full PSScriptAnalyzer analysis still ran (a bash-ism did not gate the early-exit)'
    }

    It 'module samples: consistent/wildcard/dynamic produce zero findings; orphan/typo surface ManifestConsistency' {
        $module = @(Get-CorpusSampleSpec | Where-Object { $_.Category -eq 'module' })
        $module.Count | Should -BeGreaterThan 0
        foreach ($s in $module) {
            $d = @($script:Derived[$s.Label])
            switch ($s.Name) {
                'consistent-module' {
                    $d.Count | Should -Be 0 -Because "$($s.Label) is a consistent module with matching exports"
                }
                'orphan-export' {
                    $d.Count | Should -BeGreaterThan 0 -Because "$($s.Label) has an orphan export in FunctionsToExport"
                    ($d | Select-Object -First 1).source | Should -BeExactly 'powershell-lsp'
                    ($d | Select-Object -First 1).ruleId | Should -BeExactly 'ManifestConsistency'
                }
                'typo-export' {
                    $d.Count | Should -BeGreaterThan 0 -Because "$($s.Label) has a typo export in FunctionsToExport"
                    ($d | Select-Object -First 1).source | Should -BeExactly 'powershell-lsp'
                    ($d | Select-Object -First 1).ruleId | Should -BeExactly 'ManifestConsistency'
                }
                'wildcard-export' {
                    $d.Count | Should -Be 0 -Because "$($s.Label) uses wildcard '*' export (honest degrade, no false orphan)"
                }
                'dynamic-export' {
                    $d.Count | Should -Be 0 -Because "$($s.Label) uses dynamic Export-ModuleMember (honest degrade, no false orphan)"
                }
                'alias-consistent' {
                    $d.Count | Should -Be 0 -Because "$($s.Label) declares AliasesToExport for an alias it defines (consistent)"
                }
                'alias-orphan' {
                    # dispatch 000128 slice 2: an alias in AliasesToExport with no matching Set-Alias definition.
                    $d.Count | Should -BeGreaterThan 0 -Because "$($s.Label) has an AliasesToExport orphan"
                    ($d | Select-Object -First 1).source | Should -BeExactly 'powershell-lsp'
                    ($d | Select-Object -First 1).ruleId | Should -BeExactly 'ManifestConsistency'
                }
                'alias-dynamic-good' {
                    $d.Count | Should -Be 0 -Because "$($s.Label) defines its alias by a dynamic invocation (Pester shape -- honest degrade, no false orphan)"
                }
                'alias-exportmember-good' {
                    $d.Count | Should -Be 0 -Because "$($s.Label) manages alias exports via Export-ModuleMember -Alias (BurntToast shape -- honest degrade, no false orphan)"
                }
                'binary-rootmodule' {
                    # dispatch 000171 leg 3: a BINARY module -- RootModule is a .dll and the exports are
                    # CMDLETS, which no AST walk can ever find. Resolve-ModuleRootModulePath returns ''
                    # for a .dll/.exe, so the export surface is INDETERMINATE and the check must degrade
                    # to silence. Reporting every declared cmdlet as an orphan would be the worst kind of
                    # false positive: confidently wrong about code it structurally cannot read.
                    $d.Count | Should -Be 0 -Because "$($s.Label) is a binary module (indeterminate export surface -- honest degrade, no false orphan)"
                }
                default {
                    $true | Should -BeFalse -Because "$($s.Label) is not a known module fixture type"
                }
            }
        }
    }

    # --- measured correctness report (dispatch 000046, Gap A): the trust invariants the
    #     published README numbers stand on, guarded in CI on all four legs. ---

    It 'measured correctness: the corpus is large enough to be defensible (>= 30 known-good, >= 30 known-bad)' {
        # Floor raised from 15 to 30 when the corpus was broadened (dispatch 000048): a wider,
        # idiom-diverse known-good/known-bad surface makes the published false-positive and
        # true-positive numbers more defensible, and this guard prevents silently shrinking back.
        $script:CorpusReport.knownGood | Should -BeGreaterOrEqual 30 -Because 'a defensible false-positive rate needs a broad, idiom-diverse known-good sample'
        $script:CorpusReport.knownBad | Should -BeGreaterOrEqual 30 -Because 'a defensible true-positive coverage needs a broad, idiom-diverse known-bad sample'
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

# ===========================================================================
# D3 -- the snapshot generator's IDEMPOTENCE, as a test rather than a docstring
# (dispatch 000172).
#
# Update-CorpusSnapshots.ps1 has always DOCUMENTED itself as idempotent -- "a re-run against an
# unchanged tool is a clean no-op (no snapshot bytes change)" -- and that was FALSE. During
# dispatch 000171 a re-run rewrote 17 unrelated snapshots with different line endings and
# different indentation, no content change in any of them, and it was caught only because the
# blast radius happened to be pinned at both ends. A contract asserted only in prose is how 17
# files churn silently, so it is asserted here instead.
#
# NO DAEMON. The defect lived entirely in serialization and the changed/unchanged decision, not
# in derivation, so these tests drive the real shipped write path over the COMMITTED finding sets
# and need no PSES. That makes them fast, unskippable, and able to cover every snapshot rather
# than only the ones a daemon run happens to reach.
# ===========================================================================

Describe 'Corpus snapshot generator is IDEMPOTENT (dispatch 000172, D3)' {

    BeforeAll {
        . (Join-Path $PSScriptRoot 'corpus/Corpus.Common.ps1')
        $script:IdemSpecs = @(Get-CorpusSampleSpec | Where-Object { Test-Path -LiteralPath $_.ExpectedPath })
        $script:IdemRoot = Join-Path $TestDrive ('idem-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $script:IdemRoot | Out-Null

        function script:Get-IdemHash {
            param([string]$Path)
            return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        }
    }

    It 'SELECTED-COUNT FLOOR: there are committed snapshots to test' {
        # Without this the two -ForEach-free loops below would iterate an empty list and the whole
        # Describe would read as a pass while asserting nothing.
        @($script:IdemSpecs).Count | Should -BeGreaterThan 0
        @($script:IdemSpecs).Count | Should -BeGreaterThan 100 -Because (
            'the corpus carries 121 snapshots at dispatch 000172; a collapse below this floor ' +
            'means the enumeration broke, not that the corpus shrank')
    }

    It 'RUN TWICE: writing every snapshot twice produces byte-identical files' {
        # The literal contract: run the generator's write path twice against an unchanged tree and
        # assert zero byte changes, across EVERY snapshot -- compared by SHA-256, not by content.
        $checked = 0
        foreach ($spec in $script:IdemSpecs) {
            $findings = Import-CorpusSnapshot -Path $spec.ExpectedPath
            $tmp = Join-Path $script:IdemRoot ($spec.ScratchName + '.json')

            Write-CorpusSnapshotFile -Path $tmp -Findings $findings
            $hash1 = Get-IdemHash -Path $tmp
            Write-CorpusSnapshotFile -Path $tmp -Findings $findings
            $hash2 = Get-IdemHash -Path $tmp

            $hash2 | Should -BeExactly $hash1 -Because "$($spec.Label) must serialize to the same bytes twice"
            $checked++
        }
        $checked | Should -Be @($script:IdemSpecs).Count
    }

    It 'HOST-INDEPENDENT: every written snapshot is LF-only, never CRLF' {
        # The root cause. ConvertTo-Json indents with [Environment]::NewLine, so the old formatter
        # emitted CRLF on Windows and LF elsewhere and a snapshot written on one host churned on
        # the other. This is the assertion the adversarial control below must be able to fail.
        $checked = 0
        foreach ($spec in $script:IdemSpecs) {
            $findings = Import-CorpusSnapshot -Path $spec.ExpectedPath
            $text = Get-CorpusSnapshotText -Findings $findings
            $text | Should -Not -Match "`r" -Because "$($spec.Label) must serialize with LF endings on every host"
            $checked++
        }
        $checked | Should -BeGreaterThan 0
    }

    It 'ADVERSARIAL: a generator that writes CRLF FAILS that same assertion' {
        # Demonstrating the failure once, as required -- otherwise "the test would catch a CRLF
        # generator" is itself an unproven prose claim. Same assertion, CRLF-writing formatter.
        $findings = @([pscustomobject]@{
                ruleId = 'PSUseApprovedVerbs'; source = 'PSScriptAnalyzer'; severity = 'Warning'
                line = 1; col = 1; message = 'adversarial control'
            })
        $good = Get-CorpusSnapshotText -Findings $findings
        $crlf = $good -replace "`n", "`r`n"        # the pre-fix, [Environment]::NewLine behavior

        $good | Should -Not -Match "`r"                                   # the real one passes
        { $crlf | Should -Not -Match "`r" } | Should -Throw               # the CRLF one FAILS
    }

    It 'ONE SHAPE: a single finding indents exactly like one of many' {
        # The other half of D3. The old formatter wrapped a lone object in literal brackets, so a
        # one-finding snapshot indented its fields at 2 and its braces at 0, while a two-finding
        # snapshot used 4 and 2. Same document structure, two renderings, and a corpus sample that
        # crossed from one finding to two churned its whole file for no content reason.
        $one = @([pscustomobject]@{ ruleId = 'R1'; source = 'PSScriptAnalyzer'; severity = 'Warning'; line = 1; col = 2; message = 'm1' })
        $two = @($one[0], [pscustomobject]@{ ruleId = 'R2'; source = 'PSScriptAnalyzer'; severity = 'Warning'; line = 3; col = 4; message = 'm2' })

        $oneLines = @((Format-CorpusSnapshotJson -Findings $one) -split "`n")
        $twoLines = @((Format-CorpusSnapshotJson -Findings $two) -split "`n")

        $oneLines[0] | Should -BeExactly '['
        $oneLines[1] | Should -BeExactly '  {'
        $oneLines[-1] | Should -BeExactly ']'
        $twoLines[0] | Should -BeExactly '['
        $twoLines[1] | Should -BeExactly '  {'
        $twoLines[-1] | Should -BeExactly ']'
        # The first object renders IDENTICALLY whether or not a second one follows it.
        (($oneLines[1..7]) -join "`n") | Should -BeExactly (($twoLines[1..7]) -join "`n")
    }

    It 'ROUND-TRIPS: the deterministic rendering still parses back to the same findings' {
        # A formatter that is deterministic but wrong would pass everything above. This closes it:
        # every committed snapshot re-serializes and re-imports to the same canonical content.
        $checked = 0
        foreach ($spec in $script:IdemSpecs) {
            $findings = Import-CorpusSnapshot -Path $spec.ExpectedPath
            $tmp = Join-Path $script:IdemRoot ($spec.ScratchName + '.rt.json')
            Write-CorpusSnapshotFile -Path $tmp -Findings $findings
            $reread = Import-CorpusSnapshot -Path $tmp
            (Get-CorpusCanonicalString -Findings $reread) |
                Should -BeExactly (Get-CorpusCanonicalString -Findings $findings) -Because "$($spec.Label) must survive a write/read round trip"
            $checked++
        }
        $checked | Should -BeGreaterThan 0
    }

    It 'NO CHURN: a re-run leaves every committed snapshot alone, cosmetics and all' {
        # THE REGRESSION TEST FOR THE 17-FILE INCIDENT. Every committed snapshot -- including the
        # 47 that carry pre-fix Windows CRLF -- must be judged CURRENT against its own findings,
        # so the generator writes nothing. Under the old byte comparison this was false for 17 of
        # them, measured while working 000172.
        $stale = @()
        foreach ($spec in $script:IdemSpecs) {
            $findings = Import-CorpusSnapshot -Path $spec.ExpectedPath
            if (-not (Test-CorpusSnapshotCurrent -Path $spec.ExpectedPath -Findings $findings)) {
                $stale += $spec.Label
            }
        }
        $stale -join ', ' | Should -BeExactly '' -Because 'a re-run against an unchanged tool must rewrite NOTHING'
    }
}
