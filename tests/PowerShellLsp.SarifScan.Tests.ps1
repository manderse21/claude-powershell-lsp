#Requires -Version 5.1

# SARIF + standalone CI-scan tests (Pester 5) -- dispatch 000057, PL-5.
#
# THREE LAYERS:
#   1. Pure helpers (no daemon, every leg): target enumeration, the honest severity-to-SARIF
#      mapping, SARIF 2.1.0 assembly + conformance (structural on all legs, plus a real schema
#      validation against the vendored sarif-2.1.0.json on pwsh), and text rendering.
#   2. Finding-identity (warm daemon): the ONE-ENGINE proof. Each committed corpus sample is run
#      through the SCAN entry point's OWN derivation (scripts/lib/lsp-scan-common.ps1 ->
#      lsp-client.ps1 -> the same warm PSES + PSScriptAnalyzer pass the in-agent hook uses) and
#      its findings are asserted to match the corpus snapshot -- the SAME tool-derived oracle the
#      in-agent corpus test asserts. If the CI path and the in-agent path ever diverge, this goes
#      RED (a divergence is a defect, not a feature). The measured 0% FP / 100% TP is recomputed
#      over the CI-derived findings.
#   3. Entry point end-to-end (warm daemon): scripts/lsp-scan.ps1 run over a real directory emits
#      conformant SARIF carrying the expected finding, and the text mode + exit code behave.
#
# Runs on the same platforms as the corpus/integration suites; other platforms self-skip. The
# analysis host is always pwsh (named pipes map to Unix domain sockets on .NET), even when this
# test FILE is interpreted by Windows PowerShell 5.1 -- so derived findings are host-consistent.
#
# ASCII-only (PS 5.1 em-dash trap); StrictMode-safe (index hashtables, init-before-use).

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-scan-common.ps1')
. (Join-Path $PSScriptRoot 'corpus/Corpus.Common.ps1')

# Discovery-time platform gate (StrictMode-safe; PS 5.1 has no $IsWindows/$IsLinux).
$script:OnWindows = if (Test-Path 'Variable:\IsWindows') { [bool]$IsWindows } else { $true }
$script:OnLinux = (Test-Path 'Variable:\IsLinux') -and [bool]$IsLinux
$script:OnMacOS = (Test-Path 'Variable:\IsMacOS') -and [bool]$IsMacOS
$script:SkipDaemon = -not ($script:OnWindows -or $script:OnLinux -or $script:OnMacOS)

# Corpus specs enumerated at discovery time for the data-driven identity It blocks.
$script:CorpusSamples = @(Get-CorpusSampleSpec)

Describe 'SARIF scan -- pure helpers (no daemon)' {

    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-scan-common.ps1')
        $script:SchemaPath = Join-Path $PSScriptRoot 'sarif/sarif-2.1.0.json'

        # A synthetic finding set spanning every severity the mapping must handle.
        $script:Synth = @(
            [pscustomobject]@{ file = (Join-Path $TestDrive 'a.ps1'); ruleId = 'PSUseApprovedVerbs'; source = 'PSScriptAnalyzer'; severity = 'Warning'; line = 3; col = 10; message = 'unapproved verb' },
            [pscustomobject]@{ file = (Join-Path $TestDrive 'a.ps1'); ruleId = 'ExpectedExpression'; source = 'parser'; severity = 'Error'; line = 7; col = 1; message = 'parse error' },
            [pscustomobject]@{ file = (Join-Path $TestDrive 'sub/b.ps1'); ruleId = 'SomeInfoRule'; source = 'PSScriptAnalyzer'; severity = 'Information'; line = 1; col = 1; message = 'info finding' },
            [pscustomobject]@{ file = (Join-Path $TestDrive 'sub/b.ps1'); ruleId = 'SomeHintRule'; source = 'PSScriptAnalyzer'; severity = 'Hint'; line = 2; col = 2; message = 'hint finding' }
        )
        $script:Report = New-SarifReport -Findings $script:Synth -Root $TestDrive -ToolVersion '9.9.9' -ExecutionSuccessful $true
        $script:ReportJson = $script:Report | ConvertTo-Json -Depth 16
        $script:Parsed = $script:ReportJson | ConvertFrom-Json
    }

    Context 'the -FailOn exit-code policy matrix (dispatch 000127; policy shipped 000057)' {
        # -FailOn has existed since dispatch 000057 (v1.19.0); what did NOT exist was a matrix
        # pinning its semantics, so the policy could drift silently. These are pure over injected
        # findings -- no daemon, no analysis -- so the whole matrix runs in milliseconds and the
        # e2e Describe below only has to prove the WIRING, not re-derive the policy.
        BeforeAll {
            # One finding per severity the tool actually emits (ConvertTo-DiagRecord's set).
            $script:FErr = @([pscustomobject]@{ severity = 'Error' })
            $script:FWarn = @([pscustomobject]@{ severity = 'Warning' })
            $script:FInfo = @([pscustomobject]@{ severity = 'Information' })
            $script:FHint = @([pscustomobject]@{ severity = 'Hint' })
        }

        It 'the DEFAULT (none) never gates -- exit 0 even with an Error finding' {
            # THE regression guard: absent -FailOn, the exit code is what it has been since
            # 000057. If this ever returns 2, every existing SARIF-upload caller breaks.
            Get-FailExitCode -Findings $script:FErr -FailOn 'none' | Should -Be 0
            Get-FailExitCode -Findings @() -FailOn 'none' | Should -Be 0
        }

        It 'gates at-or-ABOVE the threshold, never below (the whole point of a threshold)' {
            # -FailOn error: only an Error trips it.
            Get-FailExitCode -Findings $script:FErr -FailOn 'error' | Should -Be 2
            Get-FailExitCode -Findings $script:FWarn -FailOn 'error' | Should -Be 0
            Get-FailExitCode -Findings $script:FInfo -FailOn 'error' | Should -Be 0
            # -FailOn warning: Error and Warning trip it; Information (-> note) does not.
            Get-FailExitCode -Findings $script:FErr -FailOn 'warning' | Should -Be 2
            Get-FailExitCode -Findings $script:FWarn -FailOn 'warning' | Should -Be 2
            Get-FailExitCode -Findings $script:FInfo -FailOn 'warning' | Should -Be 0
            # -FailOn note: everything the tool emits trips it (Information AND Hint fold to note).
            Get-FailExitCode -Findings $script:FErr -FailOn 'note' | Should -Be 2
            Get-FailExitCode -Findings $script:FWarn -FailOn 'note' | Should -Be 2
            Get-FailExitCode -Findings $script:FInfo -FailOn 'note' | Should -Be 2
            Get-FailExitCode -Findings $script:FHint -FailOn 'note' | Should -Be 2
        }

        It 'no findings never gates, at any threshold (a clean scan is a clean gate)' {
            foreach ($t in @('none', 'note', 'warning', 'error')) {
                Get-FailExitCode -Findings @() -FailOn $t | Should -Be 0 -Because "an empty scan must not fail -FailOn $t"
            }
        }

        It 'gates on the MOST severe finding present, not the first one seen (order-independent)' {
            # Adversarial: a Warning listed BEFORE an Error must not mask the Error at -FailOn error.
            $mixed = @([pscustomobject]@{ severity = 'Warning' }, [pscustomobject]@{ severity = 'Error' })
            Get-FailExitCode -Findings $mixed -FailOn 'error' | Should -Be 2
            $mixedRev = @([pscustomobject]@{ severity = 'Error' }, [pscustomobject]@{ severity = 'Warning' })
            Get-FailExitCode -Findings $mixedRev -FailOn 'error' | Should -Be 2
        }

        It 'an unknown severity maps to warning and gates accordingly (never silently dropped)' {
            # ConvertTo-SarifLevel maps an unknown severity to 'warning' rather than dropping it;
            # the gate must honor that rather than treating it as un-rankable.
            $weird = @([pscustomobject]@{ severity = 'Banana' })
            Get-FailExitCode -Findings $weird -FailOn 'warning' | Should -Be 2
            Get-FailExitCode -Findings $weird -FailOn 'error' | Should -Be 0
        }

        It 'ranks severity most-severe-first, with a never-gates rank outside the ordered set' {
            Get-ScanSeverityRank 'error' | Should -Be 1
            Get-ScanSeverityRank 'warning' | Should -Be 2
            Get-ScanSeverityRank 'note' | Should -Be 3
            Get-ScanSeverityRank 'none' | Should -Be 99
            Get-ScanSeverityRank '' | Should -Be 99
        }
    }

    Context 'target enumeration (Get-ScanTargets)' {
        BeforeAll {
            $script:Tree = Join-Path $TestDrive 'tree'
            New-Item -ItemType Directory -Force -Path (Join-Path $script:Tree 'sub') | Out-Null
            Set-Content -LiteralPath (Join-Path $script:Tree 'one.ps1') -Value 'function Get-One { 1 }' -Encoding ascii
            Set-Content -LiteralPath (Join-Path $script:Tree 'two.psm1') -Value 'function Get-Two { 2 }' -Encoding ascii
            Set-Content -LiteralPath (Join-Path $script:Tree 'm.psd1') -Value '@{ ModuleVersion = "1.0" }' -Encoding ascii
            Set-Content -LiteralPath (Join-Path $script:Tree 'readme.txt') -Value 'text' -Encoding ascii
            Set-Content -LiteralPath (Join-Path $script:Tree 'sub/three.ps1') -Value 'function Get-Three { 3 }' -Encoding ascii
        }
        It 'handles exactly .ps1/.psm1/.psd1' {
            (Get-ScanPowerShellExtensions) | Should -Be @('.ps1', '.psm1', '.psd1')
        }
        It 'recurses a directory by default and counts skipped non-PowerShell files' {
            $t = Get-ScanTargets -Path $script:Tree -Recurse $true
            @($t['Files']).Count | Should -Be 4
            [int]$t['Skipped'] | Should -Be 1
        }
        It 'limits to the top level when not recursing' {
            $t = Get-ScanTargets -Path $script:Tree -Recurse $false
            @($t['Files']).Count | Should -Be 3
        }
        It 'accepts a single PowerShell file' {
            $t = Get-ScanTargets -Path (Join-Path $script:Tree 'one.ps1') -Recurse $true
            @($t['Files']).Count | Should -Be 1
        }
        It 'skips a single non-PowerShell file (0 analyzed, 1 skipped)' {
            $t = Get-ScanTargets -Path (Join-Path $script:Tree 'readme.txt') -Recurse $true
            @($t['Files']).Count | Should -Be 0
            [int]$t['Skipped'] | Should -Be 1
        }
    }

    Context 'honest severity-to-SARIF-level mapping (ConvertTo-SarifLevel)' {
        It 'maps Error -> error' { (ConvertTo-SarifLevel 'Error') | Should -BeExactly 'error' }
        It 'maps Warning -> warning' { (ConvertTo-SarifLevel 'Warning') | Should -BeExactly 'warning' }
        It 'maps Information -> note (SARIF has no info level)' { (ConvertTo-SarifLevel 'Information') | Should -BeExactly 'note' }
        It 'maps Hint -> note (SARIF has no hint level)' { (ConvertTo-SarifLevel 'Hint') | Should -BeExactly 'note' }
        It 'maps an unknown severity -> warning (never silently dropped to none)' { (ConvertTo-SarifLevel 'Zonk') | Should -BeExactly 'warning' }
    }

    Context 'rule-key resolution (Get-ScanRuleKey)' {
        It 'prefers the analyzer rule code' {
            (Get-ScanRuleKey ([pscustomobject]@{ ruleId = 'PSUseApprovedVerbs'; source = 'PSScriptAnalyzer' })) | Should -BeExactly 'PSUseApprovedVerbs'
        }
        It 'falls back to the source label when there is no rule code' {
            (Get-ScanRuleKey ([pscustomobject]@{ ruleId = ''; source = 'parser' })) | Should -BeExactly 'parser'
        }
        It 'falls back to powershell-lsp when neither is present' {
            (Get-ScanRuleKey ([pscustomobject]@{ ruleId = ''; source = '' })) | Should -BeExactly 'powershell-lsp'
        }
    }

    Context 'relative artifact URIs (Get-ScanRelativeUri)' {
        It 'is root-relative with forward slashes for a file under the root' {
            (Get-ScanRelativeUri -FilePath (Join-Path $TestDrive 'sub/b.ps1') -Root $TestDrive) | Should -BeExactly 'sub/b.ps1'
        }
    }

    Context 'SARIF 2.1.0 conformance (structural)' {
        It 'declares the SARIF schema and version 2.1.0' {
            [string]$script:Parsed.'$schema' | Should -Not -BeNullOrEmpty
            [string]$script:Parsed.version | Should -BeExactly '2.1.0'
        }
        It 'has exactly one run with a tool driver' {
            @($script:Parsed.runs).Count | Should -Be 1
            [string]$script:Parsed.runs[0].tool.driver.name | Should -BeExactly 'powershell-lsp'
            [string]$script:Parsed.runs[0].tool.driver.version | Should -BeExactly '9.9.9'
            [string]$script:Parsed.runs[0].tool.driver.informationUri | Should -Not -BeNullOrEmpty
        }
        It 'declares a deduplicated rule table referenced by ruleIndex' {
            $rules = @($script:Parsed.runs[0].tool.driver.rules)
            $rules.Count | Should -Be 4
            foreach ($r in @($script:Parsed.runs[0].results)) {
                [int]$r.ruleIndex | Should -BeGreaterOrEqual 0
                [string]$rules[[int]$r.ruleIndex].id | Should -BeExactly ([string]$r.ruleId)
            }
        }
        It 'emits one result per finding with ruleId, level, message and a physical location' {
            $results = @($script:Parsed.runs[0].results)
            $results.Count | Should -Be 4
            foreach ($r in $results) {
                [string]$r.ruleId | Should -Not -BeNullOrEmpty
                @('error', 'warning', 'note', 'none') | Should -Contain ([string]$r.level)
                [string]$r.message.text | Should -Not -BeNullOrEmpty
                $loc = $r.locations[0].physicalLocation
                [string]$loc.artifactLocation.uri | Should -Not -BeNullOrEmpty
                [string]$loc.artifactLocation.uriBaseId | Should -BeExactly 'SRCROOT'
                [int]$loc.region.startLine | Should -BeGreaterOrEqual 1
                [int]$loc.region.startColumn | Should -BeGreaterOrEqual 1
            }
        }
        It 'maps severities honestly in the assembled report (Error/Warning/Information/Hint)' {
            $byRule = @{}
            foreach ($r in @($script:Parsed.runs[0].results)) { $byRule[[string]$r.ruleId] = [string]$r.level }
            $byRule['PSUseApprovedVerbs'] | Should -BeExactly 'warning'
            $byRule['ExpectedExpression'] | Should -BeExactly 'error'
            $byRule['SomeInfoRule'] | Should -BeExactly 'note'
            $byRule['SomeHintRule'] | Should -BeExactly 'note'
        }
        It 'anchors relative URIs to the scan root (originalUriBaseIds.SRCROOT)' {
            [string]$script:Parsed.runs[0].originalUriBaseIds.SRCROOT.uri | Should -Match '^file:'
        }
        It 'reports an incomplete scan via invocations.executionSuccessful' {
            $bad = New-SarifReport -Findings $script:Synth -Root $TestDrive -ToolVersion '9.9.9' -ExecutionSuccessful $false
            [bool]$bad.runs[0].invocations[0].executionSuccessful | Should -BeFalse
        }
        It 'produces a well-formed empty report when there are no findings' {
            $empty = New-SarifReport -Findings @() -Root $TestDrive -ToolVersion '9.9.9' -ExecutionSuccessful $true
            $ej = $empty | ConvertTo-Json -Depth 16 | ConvertFrom-Json
            [string]$ej.version | Should -BeExactly '2.1.0'
            @($ej.runs).Count | Should -Be 1
            @($ej.runs[0].results).Count | Should -Be 0
        }
    }

    Context 'SARIF 2.1.0 conformance (schema validation)' {
        # Test-Json -Schema exists only on PowerShell 6+ (the windows-powershell 5.1 leg gets the
        # structural assertions above instead). The vendored schema is the official SARIF 2.1.0
        # JSON Schema (self-contained, no external $ref), so this validates fully offline.
        It 'validates against the vendored SARIF 2.1.0 JSON Schema' -Skip:($PSVersionTable.PSVersion.Major -lt 6) {
            (Test-Path -LiteralPath $script:SchemaPath) | Should -BeTrue -Because 'tests/sarif/sarif-2.1.0.json must be vendored'
            $schema = Get-Content -LiteralPath $script:SchemaPath -Raw
            (Test-Json -Json $script:ReportJson -Schema $schema) | Should -BeTrue -Because 'the emitted SARIF must conform to the SARIF 2.1.0 schema'
        }
    }

    Context 'text mode (Format-ScanTextReport)' {
        It 'lists findings per file with a summary and the skipped count' {
            $txt = Format-ScanTextReport -Findings $script:Synth -Root $TestDrive -Skipped 2 -FilesScanned 2 -NotAnalyzed @()
            $txt | Should -Match 'a\.ps1'
            $txt | Should -Match 'unapproved verb'
            $txt | Should -Match '4 finding\(s\)'
            $txt | Should -Match '2 non-PowerShell file\(s\) skipped'
        }
        It 'surfaces a not-analyzed warning (never silent on a degraded file)' {
            $txt = Format-ScanTextReport -Findings @() -Root $TestDrive -Skipped 0 -FilesScanned 1 -NotAnalyzed @((Join-Path $TestDrive 'x.ps1'))
            $txt | Should -Match 'could NOT be analyzed'
        }
    }

    Context 'not-analyzed name surfacing (dispatch 000131 -- diagnosability first)' {
        # LEG 1: an INCOMPLETE scan must name WHICH files could not be analyzed, not merely how
        # many. Pure over injected not-analyzed paths (no daemon), so the SARIF vehicle
        # (invocation.toolExecutionNotifications) and the bounded enumeration are pinned in
        # milliseconds. RED on the pre-change tree: New-SarifReport had no -NotAnalyzed parameter
        # and Get-ScanNotAnalyzedNames did not exist (today only a COUNT is surfaced in SARIF mode).
        BeforeAll {
            $script:NaPaths = @(
                (Join-Path $TestDrive 'zeta.ps1'),
                (Join-Path $TestDrive 'sub/alpha.ps1'),
                (Join-Path $TestDrive 'mid.psm1')
            )
            $script:NaReport = New-SarifReport -Findings $script:Synth -Root $TestDrive -ToolVersion '9.9.9' -ExecutionSuccessful $false -NotAnalyzed $script:NaPaths
            $script:NaJson = $script:NaReport | ConvertTo-Json -Depth 16
            $script:NaParsed = $script:NaJson | ConvertFrom-Json
        }

        It 'relativizes, sorts, and reports total + overflow for a small set (Get-ScanNotAnalyzedNames)' {
            $r = Get-ScanNotAnalyzedNames -NotAnalyzed $script:NaPaths -Root $TestDrive
            @($r.Names) | Should -Be @('mid.psm1', 'sub/alpha.ps1', 'zeta.ps1')
            [int]$r.Total | Should -Be 3
            [int]$r.Overflow | Should -Be 0
        }

        It 'caps the enumerated names and reports the overflow when the set exceeds the cap' {
            $many = @(1..10 | ForEach-Object { Join-Path $TestDrive ('f{0:D2}.ps1' -f $_) })
            $r = Get-ScanNotAnalyzedNames -NotAnalyzed $many -Root $TestDrive -Cap 4
            @($r.Names).Count | Should -Be 4
            [int]$r.Total | Should -Be 10
            [int]$r.Overflow | Should -Be 6
        }

        It 'ignores blank entries and never throws on an empty set' {
            $r = Get-ScanNotAnalyzedNames -NotAnalyzed @('', $null) -Root $TestDrive
            @($r.Names).Count | Should -Be 0
            [int]$r.Total | Should -Be 0
        }

        It 'names the unanalyzed files in the SARIF invocation notifications, not just a count' {
            $notifs = @($script:NaParsed.runs[0].invocations[0].toolExecutionNotifications)
            $notifs.Count | Should -BeGreaterOrEqual 3
            $joined = (@($notifs | ForEach-Object { [string]$_.message.text }) -join "`n")
            $joined | Should -Match 'zeta\.ps1'
            $joined | Should -Match 'sub/alpha\.ps1'
            $joined | Should -Match 'mid\.psm1'
        }

        It 'attaches a SRCROOT-relative navigable location to each named file' {
            $notifs = @($script:NaParsed.runs[0].invocations[0].toolExecutionNotifications)
            $withLoc = @($notifs | Where-Object { $null -ne $_.locations })
            $withLoc.Count | Should -BeGreaterOrEqual 3
            foreach ($n in $withLoc) {
                [string]$n.locations[0].physicalLocation.artifactLocation.uriBaseId | Should -BeExactly 'SRCROOT'
                [string]$n.locations[0].physicalLocation.artifactLocation.uri | Should -Not -BeNullOrEmpty
            }
        }

        It 'marks the incomplete scan executionSuccessful=false alongside the names' {
            [bool]$script:NaParsed.runs[0].invocations[0].executionSuccessful | Should -BeFalse
        }

        It 'a COMPLETE scan grows no notifications (the added surface is inert when nothing is unanalyzed)' {
            # scope_out guard: SARIF is byte-identical apart from the added unanalyzed reporting,
            # so a clean scan must NOT sprout a toolExecutionNotifications array.
            $clean = New-SarifReport -Findings $script:Synth -Root $TestDrive -ToolVersion '9.9.9' -ExecutionSuccessful $true -NotAnalyzed @()
            $cj = $clean | ConvertTo-Json -Depth 16 | ConvertFrom-Json
            $inv = $cj.runs[0].invocations[0]
            [bool]$inv.executionSuccessful | Should -BeTrue
            ($inv.PSObject.Properties.Name -contains 'toolExecutionNotifications') | Should -BeFalse
        }

        It 'keeps the notification-bearing SARIF valid against the vendored 2.1.0 schema' -Skip:($PSVersionTable.PSVersion.Major -lt 6) {
            $schema = Get-Content -LiteralPath $script:SchemaPath -Raw
            (Test-Json -Json $script:NaJson -Schema $schema) | Should -BeTrue -Because 'toolExecutionNotifications must keep the SARIF schema-valid so code scanning still ingests it'
        }

        # LEG 2 (dispatch 000132): each named unanalyzed file carries how long it actually ran before
        # the budget cut it, not merely that it ran out. The elapsed rides IN the notification message
        # text, so the workflow annotation (which echoes message.text) surfaces it for free. RED on the
        # pre-change tree: -NotAnalyzed took bare path strings and no surface carried an elapsed.
        It 'names each unanalyzed file WITH its elapsed ms in the SARIF notification text (dispatch 000132 leg 2)' {
            $withElapsed = @(
                [pscustomobject]@{ Path = (Join-Path $TestDrive 'zeta.ps1'); ElapsedMs = 18042 },
                [pscustomobject]@{ Path = (Join-Path $TestDrive 'sub/alpha.ps1'); ElapsedMs = 25001 }
            )
            $rep = New-SarifReport -Findings @() -Root $TestDrive -ToolVersion '9.9.9' -ExecutionSuccessful $false -NotAnalyzed $withElapsed
            $notifs = @($rep.runs[0].invocations[0].toolExecutionNotifications)
            $joined = (@($notifs | ForEach-Object { [string]$_.message.text }) -join "`n")
            $joined | Should -Match 'zeta\.ps1 after 18042ms'
            $joined | Should -Match 'sub/alpha\.ps1 after 25001ms'
        }

        It 'carries elapsed ms alongside each sorted name in the shared bounding helper (Get-ScanNotAnalyzedNames)' {
            $withElapsed = @(
                [pscustomobject]@{ Path = (Join-Path $TestDrive 'zeta.ps1'); ElapsedMs = 18042 },
                [pscustomobject]@{ Path = (Join-Path $TestDrive 'mid.psm1'); ElapsedMs = 20500 }
            )
            $r = Get-ScanNotAnalyzedNames -NotAnalyzed $withElapsed -Root $TestDrive
            @($r.Names) | Should -Be @('mid.psm1', 'zeta.ps1')
            $byName = @{}
            foreach ($it in @($r.Items)) { $byName[[string]$it.Name] = [int]$it.ElapsedMs }
            [int]$byName['zeta.ps1'] | Should -Be 18042
            [int]$byName['mid.psm1'] | Should -Be 20500
        }

        It 'still surfaces a plain name (no elapsed) when a bare path string is passed (backward compatible)' {
            $r = Get-ScanNotAnalyzedNames -NotAnalyzed @((Join-Path $TestDrive 'only.ps1')) -Root $TestDrive
            @($r.Names) | Should -Be @('only.ps1')
            $rep = New-SarifReport -Findings @() -Root $TestDrive -ToolVersion '9.9.9' -ExecutionSuccessful $false -NotAnalyzed @((Join-Path $TestDrive 'only.ps1'))
            $txt = [string]$rep.runs[0].invocations[0].toolExecutionNotifications[0].message.text
            $txt | Should -Match 'could not analyze only\.ps1 \(scan INCOMPLETE'
        }
    }
}

Describe 'SARIF scan -- finding identity (one engine)' -Skip:$script:SkipDaemon {

    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-scan-common.ps1')
        . (Join-Path $PSScriptRoot 'corpus/Corpus.Common.ps1')
        . (Join-Path $PSScriptRoot 'Integration.Common.ps1')
        $paths = Get-CorpusPaths
        $script:ScriptsDir = $paths.ScriptsDir

        # Share the integration suite's data root when CI pins it (PSES/PSSA bootstrap is then a
        # no-op); else a local temp root.
        $script:DataDir = if (-not [string]::IsNullOrWhiteSpace($env:PSLS_TEST_DATA_DIR)) {
            $env:PSLS_TEST_DATA_DIR
        } else {
            Join-Path ([System.IO.Path]::GetTempPath()) 'psls-sarifscan-test-data'
        }
        New-Item -ItemType Directory -Force -Path $script:DataDir | Out-Null
        $env:CLAUDE_PLUGIN_DATA = $script:DataDir

        $script:HostExe = Resolve-PsHost 'pwsh'

        # Idempotent bootstrap of PSES + pinned PSSA (no-op if already vendored). Same acquisition
        # path as the in-agent hook -- no second path, no pinned-hash change.
        & $script:HostExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:ScriptsDir 'ensure-pses.ps1') 2>&1 | Out-Null
        & $script:HostExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:ScriptsDir 'ensure-pssa.ps1') 2>&1 | Out-Null

        $script:Sid = 'sarifscan-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:Daemon = Start-ScanDaemon -ScriptsDir $script:ScriptsDir -DataRoot $script:DataDir -SessionId $script:Sid -HostExe $script:HostExe
        if ($null -ne $script:Daemon) {
            # Deterministic serve-readiness before deriving (the 000050/000051 lesson: assert over a
            # real diagnostics round-trip, never a fixed sleep).
            [void](Wait-DaemonRequestReady -SessionId $script:Sid -DataRoot $script:DataDir -TimeoutMs 30000)
        }
        $script:ScratchDir = Join-Path $script:DataDir ('sarifscan-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $script:ScratchDir | Out-Null

        # Materialize each corpus sample the SAME way the corpus derivation does (exact bytes ->
        # a real .ps1, or the whole module dir copied + the .psd1), then derive its findings
        # through the SCAN ENTRY POINT's own engine (Invoke-ScanFileDiagnostics -> lsp-client.ps1).
        $script:CiDerived = @{ }
        if ($null -ne $script:Daemon) {
            foreach ($spec in (Get-CorpusSampleSpec)) {
                $scratchName = [string]$spec.ScratchName
                $bytes = [System.IO.File]::ReadAllBytes([string]$spec.SourcePath)
                $modDir = if ($spec.Contains('ModuleDir')) { [string]$spec.ModuleDir } else { '' }
                if (-not [string]::IsNullOrWhiteSpace($modDir) -and (Test-Path -LiteralPath $modDir)) {
                    $moduleScratch = Join-Path $script:ScratchDir $scratchName
                    New-Item -ItemType Directory -Force -Path $moduleScratch | Out-Null
                    Get-ChildItem -LiteralPath $modDir -File | ForEach-Object {
                        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $moduleScratch $_.Name) -Force
                    }
                    $matPath = Join-Path $moduleScratch ($scratchName + '.psd1')
                    [System.IO.File]::WriteAllBytes($matPath, $bytes)
                } else {
                    $matPath = Join-Path $script:ScratchDir ($scratchName + '.ps1')
                    [System.IO.File]::WriteAllBytes($matPath, $bytes)
                }
                $r = Invoke-ScanFileDiagnostics -ScriptsDir $script:ScriptsDir -DataRoot $script:DataDir `
                    -SessionId $script:Sid -HostExe $script:HostExe -FilePath $matPath -Cwd $script:ScratchDir
                $script:CiDerived[[string]$spec.Label] = @($r.Findings)
            }
        }
        $script:CiReport = Get-CorpusCorrectnessReport -Derived $script:CiDerived
    }

    AfterAll {
        if (Get-Command Stop-ScanDaemon -ErrorAction SilentlyContinue) {
            Stop-ScanDaemon -ScriptsDir $script:ScriptsDir -DataRoot $script:DataDir -SessionId $script:Sid -HostExe $script:HostExe -DaemonInfo $script:Daemon
        }
        if ($script:ScratchDir -and (Test-Path -LiteralPath $script:ScratchDir)) {
            Remove-Item -LiteralPath $script:ScratchDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'brings up the warm daemon used by the scan entry point' {
        # If this fails the rest are meaningless -- a scan derived from a dead tool would assert
        # emptiness, not identity. Fail loud, never vacuously pass.
        $script:Daemon | Should -Not -BeNullOrEmpty
    }

    It 'sample <Label>: the scan entry point finds EXACTLY what the in-agent corpus snapshot records' -ForEach $script:CorpusSamples {
        $derived = $script:CiDerived[$Label]
        $snapshot = Import-CorpusSnapshot -Path $ExpectedPath
        $derivedCanon = Get-CorpusCanonicalString -Findings $derived
        $snapshotCanon = Get-CorpusCanonicalString -Findings $snapshot
        # The load-bearing one-engine assertion: the CI scan path and the in-agent path share one
        # engine, so the CI-derived findings must equal the tool-derived corpus snapshot exactly.
        $derivedCanon | Should -BeExactly $snapshotCanon -Because "in-CI findings for $Label must equal the in-agent corpus snapshot (one engine, no fork)"
    }

    It 'measured correctness via the scan path: zero false positives on clean code (FP rate == 0)' {
        $script:CiReport.falsePositiveRate | Should -Be 0 -Because (
            "$($script:CiReport.falsePositives) of $($script:CiReport.knownGood) clean sample(s) wrongly produced a finding via the CI scan path")
    }

    It 'measured correctness via the scan path: 100% true-positive coverage on known-bad code (TP rate == 100)' {
        $script:CiReport.truePositiveRate | Should -Be 100 -Because (
            "$($script:CiReport.truePositives) of $($script:CiReport.knownBad) known-bad sample(s) surfaced their expected rule via the CI scan path")
    }

    It 'known-bad samples surface their PSScriptAnalyzer rule through the scan path' {
        $bad = @(Get-CorpusSampleSpec | Where-Object { $_.Category -eq 'bad' })
        $bad.Count | Should -BeGreaterThan 0
        foreach ($s in $bad) {
            $d = @($script:CiDerived[$s.Label])
            $d.Count | Should -BeGreaterThan 0 -Because "$($s.Label) must surface at least one finding via the scan path"
            @($d | ForEach-Object { $_.ruleId }) | Should -Contain $s.RuleId
            ($d | Select-Object -First 1).source | Should -BeExactly 'PSScriptAnalyzer'
        }
    }
}

Describe 'code-scanning workflow: inert until merged, SHA-pinned, CI legs untouched (dispatch 000127)' {
    # Text-level guards on the NEW upload workflow, mirroring the release-workflow guards in
    # PowerShellLsp.Release.Tests.ps1 (dispatch 000042): the full parse-and-execute proof is
    # GitHub's own, so what is worth pinning here is the handful of properties whose silent
    # regression would be expensive -- the trigger set, the pin, and the blast radius.
    BeforeAll {
        $script:PluginRoot = Split-Path -Parent $PSScriptRoot
        $script:ScanWf = Join-Path $script:PluginRoot '.github/workflows/powershell-lsp-code-scanning.yml'
        $script:ScanWfText = if (Test-Path -LiteralPath $script:ScanWf) { [System.IO.File]::ReadAllText($script:ScanWf) } else { '' }
        $script:ScanWfLines = $script:ScanWfText -split "\r?\n"
        $script:CiWfText = [System.IO.File]::ReadAllText((Join-Path $script:PluginRoot '.github/workflows/powershell-lsp-ci.yml'))
    }

    It 'the workflow file exists and is non-empty (the guard cannot pass vacuously)' {
        $script:ScanWfText.Length | Should -BeGreaterThan 0
    }

    It 'is INERT until merged: no pull_request trigger (it adds no check to the PR that introduces it)' {
        # push is scoped to main and schedule only runs on the default branch, so the absence of
        # pull_request is what makes this workflow unable to fire from a topic branch.
        @($script:ScanWfLines | Where-Object { $_ -match '^\s*pull_request:\s*$' }).Count | Should -Be 0
        $script:ScanWfText | Should -Match '(?m)^\s+workflow_dispatch:'
    }

    It 'pins upload-sarif by a 40-hex COMMIT SHA, never by a movable tag' {
        # This action runs with security-events: write -- the only write scope in the repo. A tag
        # can be moved under us; a commit SHA cannot.
        $script:ScanWfText | Should -Match 'github/codeql-action/upload-sarif@[0-9a-f]{40}'
        # Adversarial: assert no TAG-pinned form of this action slipped in alongside.
        $script:ScanWfText | Should -Not -Match 'github/codeql-action/upload-sarif@v\d'
    }

    It 'requests security-events: write, and only where it is needed (job scope, not workflow-wide)' {
        # A workflow-level write grant would hand every step the token; keep it on the one job.
        $script:ScanWfText | Should -Match '(?m)^\s+security-events:\s+write'
        # The workflow-level permissions block stays read-only.
        $script:ScanWfText | Should -Match '(?m)^permissions:\r?\n\s+contents:\s+read'
    }

    It 'does not gate on findings: -FailOn is left at its default (emit, do not fail the build)' {
        $script:ScanWfText | Should -Not -Match '-FailOn\s+(note|warning|error)'
    }

    It 'leaves the four named CI legs intact (this workflow is additive, never a merge-gate change)' {
        # The blast-radius guard: the labels the branch protection names must still be declared by
        # the CI workflow, whatever this file does.
        foreach ($leg in @('ubuntu-pwsh', 'windows-powershell', 'windows-pwsh', 'macos-pwsh')) {
            $script:CiWfText | Should -Match ([regex]::Escape('label: ' + $leg))
        }
    }

    It 'surfaces the not-analyzed file NAMES from the SARIF on an INCOMPLETE scan (dispatch 000131)' {
        # Diagnosability: on exit 4 the scan step reads results.sarif's invocation notifications and
        # emits the culprit file name(s) so a future INCOMPLETE is resolvable from the Actions tab
        # alone. RED on the pre-change tree (the workflow named no files, only a bare count).
        $script:ScanWfText | Should -Match 'toolExecutionNotifications'
    }

    It 'exposes a DIAGNOSTIC daemon-budget override as an OPT-IN workflow_dispatch input (dispatch 000132 leg 3)' {
        # The measurement lever: a workflow_dispatch input that raises the daemon per-file budget for a
        # single run. It must be OPT-IN -- absent the input, the scan command is the production one, so a
        # normal push/schedule run is byte-for-byte the shipped 18000 ms behavior. RED on the pre-change
        # tree (no such input existed).
        $script:ScanWfText | Should -Match 'diagnostic_daemon_budget_ms'
        # The override is applied ONLY when the input is non-empty; an absent/empty input runs the
        # production command verbatim (byte-for-byte the shipped default).
        $script:ScanWfText | Should -Match 'IsNullOrWhiteSpace\(\$diagBudget\)'
        $script:ScanWfText | Should -Match '-DaemonBudgetMs \$diagBudget -DiagnosticTiming'
        # The default (no-override) branch runs the production invocation exactly as before.
        $script:ScanWfText | Should -Match 'lsp-scan\.ps1 ./scripts -Format sarif -OutputPath results\.sarif'
    }

    It 'defaults the diagnostic input to empty so a non-dispatch run is byte-for-byte unchanged (dispatch 000132 leg 3)' {
        $script:ScanWfText | Should -Match "default: ''"
    }

    It 'indents with spaces only (no tabs -- YAML indentation safety)' {
        $script:ScanWfText | Should -Not -Match "`t"
    }
}

Describe 'SARIF scan -- entry point end-to-end (lsp-scan.ps1)' -Skip:$script:SkipDaemon {

    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-scan-common.ps1')
        $script:ScriptsDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts'
        $script:ScanScript = Join-Path $script:ScriptsDir 'lsp-scan.ps1'
        $script:SchemaPath = Join-Path $PSScriptRoot 'sarif/sarif-2.1.0.json'
        $script:HostExe = Resolve-PsHost 'pwsh'

        $script:DataDir = if (-not [string]::IsNullOrWhiteSpace($env:PSLS_TEST_DATA_DIR)) {
            $env:PSLS_TEST_DATA_DIR
        } else {
            Join-Path ([System.IO.Path]::GetTempPath()) 'psls-sarifscan-test-data'
        }
        New-Item -ItemType Directory -Force -Path $script:DataDir | Out-Null

        # A real input tree: one clean file (must stay silent) + one known-bad file (unapproved
        # verb -> PSUseApprovedVerbs) in a subdirectory + one non-PowerShell file (must be skipped).
        $script:InputDir = Join-Path $script:DataDir ('scan-e2e-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path (Join-Path $script:InputDir 'nested') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:InputDir 'clean.ps1') -Value "function Get-Clean {`n    [CmdletBinding()]`n    param([string]`$Name)`n    Write-Output `$Name`n}`n" -Encoding ascii
        Set-Content -LiteralPath (Join-Path $script:InputDir 'nested/bad.ps1') -Value "function Frobnicate-Thing {`n    Get-Process`n}`n" -Encoding ascii
        Set-Content -LiteralPath (Join-Path $script:InputDir 'notes.txt') -Value 'not powershell' -Encoding ascii

        $script:SarifOut = Join-Path $script:InputDir 'out.sarif'
        $script:FailOnOut = Join-Path $script:InputDir 'failon.sarif'
        $prevData = $env:CLAUDE_PLUGIN_DATA
        $env:CLAUDE_PLUGIN_DATA = $script:DataDir
        try {
            & $script:HostExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $script:ScanScript $script:InputDir -Format sarif -OutputPath $script:SarifOut 2>$null | Out-Null
            $script:SarifExit = $LASTEXITCODE
            # WIRING proof for -FailOn (dispatch 000127): the pure matrix above pins the POLICY;
            # this pins that the CLI parameter actually reaches it. Same tree, same findings --
            # the ONLY difference is the flag, so a differing exit code isolates the wiring.
            & $script:HostExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $script:ScanScript $script:InputDir -Format sarif -OutputPath $script:FailOnOut -FailOn warning 2>$null | Out-Null
            $script:FailOnExit = $LASTEXITCODE
        } finally {
            $env:CLAUDE_PLUGIN_DATA = $prevData
        }
        $script:SarifText = if (Test-Path -LiteralPath $script:SarifOut) { Get-Content -LiteralPath $script:SarifOut -Raw } else { '' }
        $script:Sarif = if (-not [string]::IsNullOrWhiteSpace($script:SarifText)) { $script:SarifText | ConvertFrom-Json } else { $null }
    }

    AfterAll {
        if ($script:InputDir -and (Test-Path -LiteralPath $script:InputDir)) {
            Remove-Item -LiteralPath $script:InputDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'exits 0 and writes a SARIF file' {
        $script:SarifExit | Should -Be 0
        $script:Sarif | Should -Not -BeNullOrEmpty
    }

    It '-FailOn warning gates the SAME tree the default invocation passed (wiring, dispatch 000127)' {
        # The default run above exits 0 over a tree that DOES carry a Warning finding
        # (nested/bad.ps1 -> PSUseApprovedVerbs). Adding only -FailOn warning must flip it to 2.
        # Asserting both halves here is what makes this a wiring proof rather than a restatement
        # of the pure matrix: same tree, same engine, same findings -- only the flag differs.
        $script:SarifExit | Should -Be 0 -Because 'the default (-FailOn none) must never gate -- the 000057 behavior'
        $script:FailOnExit | Should -Be 2 -Because '-FailOn warning must exit 2 on a tree carrying a Warning finding'
    }

    It 'emits a conformant SARIF 2.1.0 envelope' {
        [string]$script:Sarif.version | Should -BeExactly '2.1.0'
        @($script:Sarif.runs).Count | Should -Be 1
        [string]$script:Sarif.runs[0].tool.driver.name | Should -BeExactly 'powershell-lsp'
    }

    It 'carries the known-bad finding as a SARIF warning at the right file' {
        $results = @($script:Sarif.runs[0].results)
        $verb = @($results | Where-Object { [string]$_.ruleId -eq 'PSUseApprovedVerbs' })
        $verb.Count | Should -BeGreaterThan 0 -Because 'the unapproved-verb function must be flagged'
        [string]$verb[0].level | Should -BeExactly 'warning'
        [string]$verb[0].locations[0].physicalLocation.artifactLocation.uri | Should -Match 'bad\.ps1$'
    }

    It 'does not flag the clean file (no false positive through the entry point)' {
        $results = @($script:Sarif.runs[0].results)
        @($results | Where-Object { [string]$_.locations[0].physicalLocation.artifactLocation.uri -match 'clean\.ps1$' }).Count | Should -Be 0
    }

    It 'the entry-point SARIF validates against the vendored schema' -Skip:($PSVersionTable.PSVersion.Major -lt 6) {
        $schema = Get-Content -LiteralPath $script:SchemaPath -Raw
        (Test-Json -Json $script:SarifText -Schema $schema) | Should -BeTrue
    }

    It 'with -DiagnosticTiming, emits a per-file elapsed line for every scanned file (dispatch 000132 leg 3)' {
        # LEG 3 measurement surface: -DiagnosticTiming records EVERY file's true elapsed, not only the
        # timed-out ones -- the number a measurement run needs to learn what a file costs when it
        # COMPLETES. Both input files analyze cleanly here (analyzed=True), so this proves the timing is
        # emitted for completing files. The daemon budget is unchanged (no -DaemonBudgetMs), so exit is 0.
        $diagErr = Join-Path $script:InputDir 'diag.err'
        $diagSarif = Join-Path $script:InputDir 'diag.sarif'
        $prevData = $env:CLAUDE_PLUGIN_DATA
        $env:CLAUDE_PLUGIN_DATA = $script:DataDir
        try {
            & $script:HostExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $script:ScanScript $script:InputDir `
                -Format sarif -OutputPath $diagSarif -DiagnosticTiming 2>$diagErr | Out-Null
            $script:DiagExit = $LASTEXITCODE
        } finally {
            $env:CLAUDE_PLUGIN_DATA = $prevData
        }
        $errText = if (Test-Path -LiteralPath $diagErr) { Get-Content -LiteralPath $diagErr -Raw } else { '' }
        $script:DiagExit | Should -Be 0 -Because 'the default daemon budget analyzes both files, so the scan completes'
        $errText | Should -Match 'lsp-scan diag:.*analyzed=True.*elapsed=\d+ms'
        @([regex]::Matches($errText, 'lsp-scan diag:')).Count | Should -BeGreaterOrEqual 2 -Because 'the input tree has 2 PowerShell files, each timed'
    }
}

Describe 'SARIF scan -- a client-cap kill is never a clean file (dispatch 000132 leg 1)' {
    # LEG 1 (never-silent, 000024): the client per-file cap enforces itself by KILLING the analysis
    # process (Invoke-ScanHook's WaitForExit), which returns '' (empty stdout). Pre-change,
    # Invoke-ScanFileDiagnostics defaulted Analyzed=$true and only flipped it on a 'NOT checked'
    # banner, so an empty (killed) stdout left the file marked analyzed -- a cap-killed file read as
    # a CLEAN file, the latent gap 000131 named. This forces the kill deterministically (CapMs = 1 ms,
    # so WaitForExit fires before lsp-client.ps1 can emit anything -- no daemon required, the process
    # is terminated at start) and asserts the file is recorded NOT analyzed, so it flows into the same
    # $notAnalyzed naming path (000131) and the scan takes the INCOMPLETE exit-4 branch.
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-scan-common.ps1')
        $script:ScriptsDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts'
        $script:HostExe = Resolve-PsHost 'pwsh'
        $script:KillDataRoot = Join-Path $TestDrive 'killdata'
        New-Item -ItemType Directory -Force -Path $script:KillDataRoot | Out-Null
        $script:KillTarget = Join-Path $TestDrive 'slow.ps1'
        Set-Content -LiteralPath $script:KillTarget -Value 'function Get-Slow { Get-Process }' -Encoding ascii
    }

    It 'reports a cap-killed file as NOT analyzed (never-silent -- a killed analysis is not a clean one)' {
        if ($null -eq $script:HostExe) { Set-ItResult -Skipped -Because 'no PowerShell host available to spawn'; return }
        $r = Invoke-ScanFileDiagnostics -ScriptsDir $script:ScriptsDir -DataRoot $script:KillDataRoot `
            -SessionId 'kill-test' -HostExe $script:HostExe -FilePath $script:KillTarget -CapMs 1
        $r.Analyzed | Should -BeFalse -Because 'a cap-killed analysis produced no verdict and must not read as a clean file'
    }
}
