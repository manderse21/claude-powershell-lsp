#Requires -Version 5.1

# Unit + subprocess regression tests (Pester 5) for scripts/rule-efficacy-ledger.ps1 -- the Arc A
# slice A1 per-rule diagnostic efficacy ledger (dispatch 000153). No network, no daemon.
#
# EVERY fixture in this file lives under $TestDrive. The real dogfood logs are NEVER read and NEVER
# written by this suite -- not the checkout log, not the installed cache log. That is not merely
# hygiene: the tool under test is a READER whose whole contract is that it does not mutate its
# input, and a test that operated on the real capture log would both risk that record and make the
# read-only assertion unfalsifiable (a hash match over a file nothing else touches proves nothing
# about a file the harness is also appending to).
#
# The hand-counted fixture is deliberately small enough to verify BY HAND from the constants below,
# because acceptance 1 asks that the counts match hand-counted values rather than whatever the
# implementation happens to produce.
#
# Run via tests/run-tests.ps1 (auto-discovered).

BeforeAll {
    $script:PluginRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsDir = Join-Path $script:PluginRoot 'scripts'
    $script:LedgerScript = Join-Path $script:ScriptsDir 'rule-efficacy-ledger.ps1'

    # Dot-sourcing the ledger brings in its own functions AND (transitively, through
    # review-dogfood.ps1) Get-DogfoodSourceBucket / Get-DogfoodSourceSplit / Get-DiagnosticShapeHash.
    # That transitive load is itself part of the contract under test: the ledger REUSES those symbols
    # rather than re-implementing them, so it must be loadable exactly this way.
    . $script:LedgerScript

    $script:HostExe = Resolve-PsHost 'pwsh'

    # --- fixture path shapes, one per source bucket (Get-DogfoodSourceBucket's three cases) -------
    $script:FileOther = 'C:\proj\alpha\a.ps1'                                    # other-genuine
    $script:FileCanon = 'C:\Users\x\nortam\claude-powershell-lsp\scripts\b.ps1'  # canonical-checkout
    $script:FileSynth = 'C:\Temp\claude\build-1\c.ps1'                           # synthetic

    function script:New-CaptureLine {
        # One capture-log line in the shipped schema. -Hash '' deliberately omits the hash so the
        # recompute path (Get-DiagnosticShapeHash over ruleId + snippet) can be exercised.
        param(
            [string] $RuleId, [string] $File, [string] $Hash = '',
            [string] $Snippet = 'Get-Thing -Foo', [string] $Severity = 'Warning'
        )
        $o = [ordered]@{
            ts       = '2026-07-25T00:00:00.0000000-04:00'
            file     = $File
            line     = 1
            col      = 1
            ruleId   = $RuleId
            source   = 'PSScriptAnalyzer'
            severity = $Severity
            message  = 'fixture'
            snippet  = $Snippet
            hash     = $Hash
            verdict  = ''
        }
        return ($o | ConvertTo-Json -Depth 5 -Compress)
    }

    function script:New-AnnotationLine {
        param([string] $Hash, [string] $Verdict, [string] $RuleId = '', [string] $Rationale = '')
        $o = [ordered]@{
            hash = $Hash; ruleId = $RuleId; verdict = $Verdict; rationale = $Rationale
            ts   = '2026-07-25T00:00:00.0000000-04:00'
        }
        return ($o | ConvertTo-Json -Depth 5 -Compress)
    }

    function script:Write-Utf8NoBom {
        # Explicit LF + UTF-8-no-BOM, matching how the shipped writers append, so a byte-level hash
        # comparison is meaningful rather than an artifact of Set-Content's platform defaults.
        param([string] $Path, [string[]] $Lines)
        $dir = Split-Path -Parent $Path
        if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"), $enc)
    }
}

Describe 'rule-efficacy-ledger -- hand-counted per-rule aggregation over a fixture pair' {
    # THE HAND COUNT. Six capture records; four real, two synthetic:
    #
    #   #  ruleId                       file bucket          hash
    #   1  PSUseApprovedVerbs           other-genuine        h1
    #   2  PSUseApprovedVerbs           other-genuine        h1   (repeat of shape h1)
    #   3  PSUseApprovedVerbs           canonical-checkout   h2
    #   4  PSAvoidUsingCmdletAliases    other-genuine        h3
    #   5  PSAvoidUsingCmdletAliases    synthetic            h4   EXCLUDED
    #   6  PSShouldProcess              synthetic            h5   EXCLUDED (rule is synthetic-ONLY)
    #
    # Therefore, counted by hand:
    #   PSUseApprovedVerbs         fired_count 3, distinct_shapes 2, canonical-checkout 1 / other-genuine 2
    #   PSAvoidUsingCmdletAliases  fired_count 1, distinct_shapes 1, canonical-checkout 0 / other-genuine 1
    #   PSShouldProcess            ABSENT -- every occurrence of it is synthetic
    #   synthetic tally            2 occurrences / 2 shapes / 2 rules
    #
    # Annotations: h1 useful, h2 noisy then h2 false-positive (last-write-wins), h3 false-positive,
    # h4 bad-fix. h4's only occurrence is synthetic, so bad-fix must appear NOWHERE in the ledger --
    # exclusion has to reach the verdict join, not just the occurrence count.
    #   PSUseApprovedVerbs         verdict_distribution useful=1 false-positive=1
    #   PSAvoidUsingCmdletAliases  verdict_distribution false-positive=1

    BeforeAll {
        # The FROZEN ledger row shape, declared ONCE so the guard and its RED control cannot drift
        # apart: a control that compared against its own copy of the list would keep passing even
        # if the guard were relaxed, which is exactly the failure mode it exists to prevent.
        $script:LedgerRowColumns = @(
            'ruleId', 'fired_count', 'distinct_shapes', 'source_split', 'verdict_distribution',
            'fixed_next_turn_rate', 'persistence_rate'
        )

        $script:FxDir = Join-Path $TestDrive ('ledger-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:FxLog = Join-Path $script:FxDir 'diagnostics.jsonl'
        $script:FxAnn = Join-Path $script:FxDir 'annotations.jsonl'

        Write-Utf8NoBom -Path $script:FxLog -Lines @(
            (New-CaptureLine -RuleId 'PSUseApprovedVerbs'        -File $script:FileOther -Hash 'h1')
            (New-CaptureLine -RuleId 'PSUseApprovedVerbs'        -File $script:FileOther -Hash 'h1')
            (New-CaptureLine -RuleId 'PSUseApprovedVerbs'        -File $script:FileCanon -Hash 'h2')
            (New-CaptureLine -RuleId 'PSAvoidUsingCmdletAliases' -File $script:FileOther -Hash 'h3')
            (New-CaptureLine -RuleId 'PSAvoidUsingCmdletAliases' -File $script:FileSynth -Hash 'h4')
            (New-CaptureLine -RuleId 'PSShouldProcess'           -File $script:FileSynth -Hash 'h5')
        )
        Write-Utf8NoBom -Path $script:FxAnn -Lines @(
            (New-AnnotationLine -Hash 'h1' -Verdict 'useful')
            (New-AnnotationLine -Hash 'h2' -Verdict 'noisy')
            (New-AnnotationLine -Hash 'h2' -Verdict 'false-positive')
            (New-AnnotationLine -Hash 'h3' -Verdict 'false-positive')
            (New-AnnotationLine -Hash 'h4' -Verdict 'bad-fix')
        )

        $read = Read-RuleLedgerInput -LogPaths @($script:FxLog) -AnnotationsPath $script:FxAnn
        $script:Fx = Get-RuleEfficacyLedger -Occurrences @($read.Occurrences) -Annotations $read.Annotations
        $script:FxRows = @{}
        foreach ($r in @($script:Fx.Rows)) { $script:FxRows[[string]$r.ruleId] = $r }
    }

    It 'emits exactly the two rules that have real (non-synthetic) occurrences' {
        @($script:Fx.Rows).Count | Should -Be 2
        @($script:Fx.Rows | ForEach-Object { [string]$_.ruleId }) |
            Should -Be @('PSAvoidUsingCmdletAliases', 'PSUseApprovedVerbs')
    }

    It 'carries EXACTLY the seven shipped columns -- the row shape is frozen, in order' {
        # The row shape is a FROZEN contract, asserted as an exact ORDERED set. Until dispatch
        # 000171 leg 2 the ledger carried five columns and this guard asserted that
        # fixed_next_turn_rate / persistence_rate were structurally ABSENT, because the plugin had
        # no persistence to derive them from and a zero would have read as "measured and found to
        # be none" -- a fabricated fact. 000171 shipped the sibling lifecycle log, so those two
        # columns are now DERIVED and present, and each carries a state ('absent' / 'no-events' /
        # 'derived') precisely so an unmeasured rate STILL never renders as 0. Those three are the
        # COMPLETE set Get-LifecycleRates returns; it is the emitting code, so read the state names
        # there rather than trusting this comment.
        #
        # The guard did its job when that landed: it went RED on all four CI legs because nobody
        # told it about the design change. Updating it is therefore a re-baseline, NOT a
        # relaxation -- the RED control immediately below proves an eighth column still fires it.
        $names = @($script:FxRows['PSUseApprovedVerbs'].PSObject.Properties.Name |
                Where-Object { -not $_.StartsWith('_') })
        $names | Should -Be $script:LedgerRowColumns
    }

    It 'RED control: an EIGHTH column FAILS that same guard -- it is a guard, not a rubber stamp' {
        # Proof the re-baselined assertion still REJECTS an unannounced column. This runs the
        # IDENTICAL comparison the guard above runs, over the same real row with one extra
        # property planted on it, and asserts it throws. If the guard above were ever weakened to
        # a subset test or a -Contain check, this control would stop throwing and go RED itself.
        $planted = $script:FxRows['PSUseApprovedVerbs'] | Select-Object *
        Add-Member -InputObject $planted -MemberType NoteProperty -Name 'leaked_eighth_column' -Value 1
        $names = @($planted.PSObject.Properties.Name | Where-Object { -not $_.StartsWith('_') })
        $names | Should -Contain 'leaked_eighth_column'   # the plant really is there
        { $names | Should -Be $script:LedgerRowColumns } | Should -Throw
    }

    It 'fired_count matches the hand count, per rule' {
        [int]$script:FxRows['PSUseApprovedVerbs'].fired_count | Should -Be 3
        [int]$script:FxRows['PSAvoidUsingCmdletAliases'].fired_count | Should -Be 1
    }

    It 'distinct_shapes matches the hand count, per rule' {
        [int]$script:FxRows['PSUseApprovedVerbs'].distinct_shapes | Should -Be 2
        [int]$script:FxRows['PSAvoidUsingCmdletAliases'].distinct_shapes | Should -Be 1
    }

    It 'source_split matches the hand count and covers only the real buckets' {
        $s = $script:FxRows['PSUseApprovedVerbs'].source_split
        @($s.Keys) | Should -Be @('canonical-checkout', 'other-genuine')
        [int]$s['canonical-checkout'] | Should -Be 1
        [int]$s['other-genuine'] | Should -Be 2
        $t = $script:FxRows['PSAvoidUsingCmdletAliases'].source_split
        [int]$t['canonical-checkout'] | Should -Be 0
        [int]$t['other-genuine'] | Should -Be 1
    }

    It 'verdict_distribution matches the hand count, honoring annotation last-write-wins' {
        # h2 was annotated 'noisy' then corrected to 'false-positive'; only the correction counts.
        $v = $script:FxRows['PSUseApprovedVerbs'].verdict_distribution
        @($v.Keys) | Should -Be @('useful', 'false-positive')
        [int]$v['useful'] | Should -Be 1
        [int]$v['false-positive'] | Should -Be 1
        $v.Contains('noisy') | Should -BeFalse

        $w = $script:FxRows['PSAvoidUsingCmdletAliases'].verdict_distribution
        @($w.Keys) | Should -Be @('false-positive')
        [int]$w['false-positive'] | Should -Be 1
    }

    It 'never joins a verdict whose only occurrence is synthetic' {
        # h4 carries 'bad-fix' but occurs only in a synthetic capture. Exclusion must reach the
        # verdict join, or a test-harness verdict would count as field evidence.
        foreach ($r in @($script:Fx.Rows)) {
            $r.verdict_distribution.Contains('bad-fix') | Should -BeFalse
        }
    }

    It 'reports the synthetic tally separately and labelled, never folded into the headline' {
        [int]$script:Fx.TotalRealOccurrences | Should -Be 4
        [int]$script:Fx.TotalRealShapes | Should -Be 3
        [int]$script:Fx.Synthetic.occurrences | Should -Be 2
        [int]$script:Fx.Synthetic.shapes | Should -Be 2
        [int]$script:Fx.Synthetic.rules | Should -Be 2

        $text = Format-RuleEfficacyLedger -Ledger $script:Fx -Sources ([pscustomobject]@{
                Discovery = 'fixture'; VersionDirs = @(); Mode = 'path'
            }) -LedgerInput ([pscustomobject]@{ LogsRead = @() })
        $text | Should -Match 'SYNTHETIC \(test-harness / Pester captures\) -- reported separately'
        $text | Should -Match 'synthetic occurrences EXCLUDED'
    }

    It 'orders rows by ruleId, not by magnitude -- the S3.2 facts-not-scores guardrail' {
        # PSUseApprovedVerbs has 3x the occurrences of PSAvoidUsingCmdletAliases, so a
        # ranked reader would put it FIRST. Alphabetical order puts it second. If this
        # assertion ever flips, the ledger has quietly become a ranking, i.e. a score.
        $ids = @($script:Fx.Rows | ForEach-Object { [string]$_.ruleId })
        $ids[0] | Should -Be 'PSAvoidUsingCmdletAliases'
        $ids[1] | Should -Be 'PSUseApprovedVerbs'
        [int]$script:FxRows[$ids[0]].fired_count |
            Should -BeLessThan ([int]$script:FxRows[$ids[1]].fired_count)
    }
}

Describe 'rule-efficacy-ledger -- synthetic-only fixture yields an EMPTY real-signal ledger' {
    BeforeAll {
        $script:SynDir = Join-Path $TestDrive ('ledger-syn-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:SynLog = Join-Path $script:SynDir 'diagnostics.jsonl'
        Write-Utf8NoBom -Path $script:SynLog -Lines @(
            (New-CaptureLine -RuleId 'PSUseApprovedVerbs'        -File $script:FileSynth -Hash 's1')
            (New-CaptureLine -RuleId 'PSAvoidUsingCmdletAliases' -File 'D:\work\psls-pester-data\x.ps1' -Hash 's2')
            (New-CaptureLine -RuleId 'PSUseApprovedVerbs'        -File $script:FileSynth -Hash 's1')
        )
        $r = Read-RuleLedgerInput -LogPaths @($script:SynLog)
        $script:Syn = Get-RuleEfficacyLedger -Occurrences @($r.Occurrences) -Annotations @{}
    }

    It 'produces ZERO rows -- exclusion proven, not asserted' {
        @($script:Syn.Rows).Count | Should -Be 0
        [int]$script:Syn.TotalRealOccurrences | Should -Be 0
    }

    It 'still reports the synthetic occurrences, labelled, so nothing is hidden' {
        # An empty ledger must not mean "nothing was there". Both synthetic path patterns
        # (Temp\claude and psls-pester-data) are exercised here.
        [int]$script:Syn.Synthetic.occurrences | Should -Be 3
        [int]$script:Syn.Synthetic.shapes | Should -Be 2
    }

    It 'renders the empty ledger as a measurement, not as an error or a zero-row table' {
        $text = Format-RuleEfficacyLedger -Ledger $script:Syn -Sources ([pscustomobject]@{
                Discovery = 'fixture'; VersionDirs = @(); Mode = 'path'
            }) -LedgerInput ([pscustomobject]@{ LogsRead = @() })
        $text | Should -Match 'the ledger is EMPTY, which is a measurement, not an error'
    }
}

Describe 'rule-efficacy-ledger -- reuse of the shipped shape-hash and source-bucket symbols' {
    It 'recomputes a missing hash with Get-DiagnosticShapeHash over (ruleId + snippet)' {
        # A record with no hash must key IDENTICALLY to the capture writer's own hash for the same
        # material -- otherwise the same shape splits into two, and distinct_shapes overcounts.
        $dir = Join-Path $TestDrive ('ledger-hash-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $log = Join-Path $dir 'diagnostics.jsonl'
        Write-Utf8NoBom -Path $log -Lines @(
            (New-CaptureLine -RuleId 'PSUseApprovedVerbs' -File $script:FileOther -Hash '' -Snippet 'function Frob-X {')
        )
        $occ = @((Read-RuleLedgerInput -LogPaths @($log)).Occurrences)
        $occ.Count | Should -Be 1
        [string]$occ[0].hash |
            Should -BeExactly (Get-DiagnosticShapeHash -RuleId 'PSUseApprovedVerbs' -OffendingLine 'function Frob-X {')
    }

    It 'collapses a hash-carrying and a hash-less record of the same shape into ONE shape' {
        $dir = Join-Path $TestDrive ('ledger-hash2-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $log = Join-Path $dir 'diagnostics.jsonl'
        $h = Get-DiagnosticShapeHash -RuleId 'PSUseApprovedVerbs' -OffendingLine 'function Frob-X {'
        Write-Utf8NoBom -Path $log -Lines @(
            (New-CaptureLine -RuleId 'PSUseApprovedVerbs' -File $script:FileOther -Hash $h  -Snippet 'function Frob-X {')
            (New-CaptureLine -RuleId 'PSUseApprovedVerbs' -File $script:FileOther -Hash '' -Snippet 'function Frob-X {')
        )
        $r = Read-RuleLedgerInput -LogPaths @($log)
        $led = Get-RuleEfficacyLedger -Occurrences @($r.Occurrences) -Annotations @{}
        [int]@($led.Rows)[0].fired_count | Should -Be 2
        [int]@($led.Rows)[0].distinct_shapes | Should -Be 1
    }

    It 'agrees with the shipped Get-DogfoodSourceSplit on identical input' {
        # THE ANTI-DIVERGENCE ASSERTION. The ledger and the shipped reader must classify the same
        # records into the same buckets; if the ledger ever grows its own bucketing, this goes RED.
        $dir = Join-Path $TestDrive ('ledger-split-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $log = Join-Path $dir 'diagnostics.jsonl'
        Write-Utf8NoBom -Path $log -Lines @(
            (New-CaptureLine -RuleId 'R1' -File $script:FileOther -Hash 'a')
            (New-CaptureLine -RuleId 'R1' -File $script:FileCanon -Hash 'b')
            (New-CaptureLine -RuleId 'R2' -File $script:FileSynth -Hash 'c')
            (New-CaptureLine -RuleId 'R2' -File $script:FileOther -Hash 'd')
        )
        $records = @(Read-DogfoodLog -LogPath $log)

        # Get-DogfoodSourceSplit is PRIVATE to lib/dogfood-reader.psm1: no shipped caller invokes
        # it, so it is not exported (dispatch 000156 boundary B1 -- the export surface is never
        # widened to keep a test green). Reach it through InModuleScope instead. The assertion
        # below is unchanged: this still compares the ledger against the REAL shipped classifier,
        # not a copy of it.
        $split = InModuleScope 'dogfood-reader' -Parameters @{ Records = $records } {
            param($Records)
            Get-DogfoodSourceSplit -Records $Records
        }

        $r = Read-RuleLedgerInput -LogPaths @($log)
        $led = Get-RuleEfficacyLedger -Occurrences @($r.Occurrences) -Annotations @{}

        $canon = 0; $other = 0
        foreach ($row in @($led.Rows)) {
            $canon += [int]$row.source_split['canonical-checkout']
            $other += [int]$row.source_split['other-genuine']
        }
        $canon | Should -Be ([int]$split['canonical-checkout'].occurrences)
        $other | Should -Be ([int]$split['other-genuine'].occurrences)
        [int]$led.Synthetic.occurrences | Should -Be ([int]$split['synthetic'].occurrences)
    }
}

Describe 'rule-efficacy-ledger -- union-read across per-version cache directories' {
    BeforeAll {
        # Two version directories under one marketplace: the exact shape a plugin UPGRADE produces.
        # Selecting the newest (what the shipped Get-DogfoodCacheLogPath does, for its own correct
        # purpose) would silently drop v1.23.1's captures and reset the denominator.
        $script:CacheRoot = Join-Path $TestDrive ('cache-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:V1Dir = Join-Path $script:CacheRoot 'claude-powershell-lsp/powershell-lsp/1.23.1/dogfood'
        $script:V2Dir = Join-Path $script:CacheRoot 'claude-powershell-lsp/powershell-lsp/1.27.0/dogfood'
        Write-Utf8NoBom -Path (Join-Path $script:V1Dir 'diagnostics.jsonl') -Lines @(
            (New-CaptureLine -RuleId 'PSUseApprovedVerbs' -File $script:FileOther -Hash 'u1')
            (New-CaptureLine -RuleId 'PSUseApprovedVerbs' -File $script:FileOther -Hash 'u2')
        )
        Write-Utf8NoBom -Path (Join-Path $script:V2Dir 'diagnostics.jsonl') -Lines @(
            (New-CaptureLine -RuleId 'PSUseApprovedVerbs' -File $script:FileOther -Hash 'u3')
        )
    }

    It 'discovers BOTH version directories, ordered, with their log presence recorded' {
        $dirs = @(Get-DogfoodCacheLogPathSet -CacheRoot $script:CacheRoot)
        $dirs.Count | Should -Be 2
        @($dirs | ForEach-Object { [string]$_.Version }) | Should -Be @('1.23.1', '1.27.0')
        @($dirs | Where-Object { $_.LogExists }).Count | Should -Be 2
    }

    It 'unions the captures so the denominator SURVIVES an upgrade' {
        $s = Resolve-RuleLedgerSources -Source 'union' -CacheRoot $script:CacheRoot
        @($s.LogPaths).Count | Should -Be 2
        $r = Read-RuleLedgerInput -LogPaths @($s.LogPaths)
        $led = Get-RuleEfficacyLedger -Occurrences @($r.Occurrences) -Annotations @{}
        [int]@($led.Rows)[0].fired_count | Should -Be 3
        [int]@($led.Rows)[0].distinct_shapes | Should -Be 3
    }

    It 'the shipped single-version resolver would have seen only the newest -- the gap union closes' {
        # Not a criticism of Get-DogfoodCacheLogPath: it answers "where is the hook writing NOW".
        # This pins WHY the ledger needed a second, unioning discovery rather than reusing it.
        $one = Get-DogfoodCacheLogPath -CacheRoot $script:CacheRoot
        $one | Should -Match '1\.27\.0'
        $r = Read-RuleLedgerInput -LogPaths @($one)
        $led = Get-RuleEfficacyLedger -Occurrences @($r.Occurrences) -Annotations @{}
        [int]@($led.Rows)[0].fired_count | Should -Be 1
    }

    It 'records a version directory whose log is ABSENT rather than omitting it' {
        $emptyVer = Join-Path $script:CacheRoot 'claude-powershell-lsp/powershell-lsp/1.28.0'
        New-Item -ItemType Directory -Force -Path $emptyVer | Out-Null
        try {
            $dirs = @(Get-DogfoodCacheLogPathSet -CacheRoot $script:CacheRoot)
            $dirs.Count | Should -Be 3
            @($dirs | Where-Object { -not $_.LogExists } | ForEach-Object { [string]$_.Version }) |
                Should -Be @('1.28.0')
        } finally {
            Remove-Item -LiteralPath $emptyVer -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'rule-efficacy-ledger -- READ-ONLY proven by byte-identical input hashes across a full run' {
    It 'leaves every input log byte-identical after a full subprocess run' {
        if ($null -eq $script:HostExe) { Set-ItResult -Skipped -Because 'no PowerShell host available to spawn'; return }

        # A FULL run through the entry point -- not a function call -- because the read-only claim is
        # about what the shipped script does when invoked, including its rendering and exit path.
        $dir = Join-Path $TestDrive ('ledger-ro-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $log = Join-Path $dir 'diagnostics.jsonl'
        $ann = Join-Path $dir 'annotations.jsonl'
        Write-Utf8NoBom -Path $log -Lines @(
            (New-CaptureLine -RuleId 'PSUseApprovedVerbs'        -File $script:FileOther -Hash 'r1')
            (New-CaptureLine -RuleId 'PSAvoidUsingCmdletAliases' -File $script:FileCanon -Hash 'r2')
            (New-CaptureLine -RuleId 'PSShouldProcess'           -File $script:FileSynth -Hash 'r3')
        )
        Write-Utf8NoBom -Path $ann -Lines @((New-AnnotationLine -Hash 'r1' -Verdict 'useful'))

        $before = @{
            log = (Get-FileHash -LiteralPath $log -Algorithm SHA256).Hash
            ann = (Get-FileHash -LiteralPath $ann -Algorithm SHA256).Hash
        }
        $beforeLen = @{
            log = (Get-Item -LiteralPath $log).Length
            ann = (Get-Item -LiteralPath $ann).Length
        }

        $out = & $script:HostExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $script:LedgerScript `
            -Path $log -AnnotationsPath $ann 2>&1
        $code = $LASTEXITCODE

        $code | Should -Be 0
        ($out -join "`n") | Should -Match 'PSUseApprovedVerbs'

        (Get-FileHash -LiteralPath $log -Algorithm SHA256).Hash | Should -BeExactly $before.log
        (Get-FileHash -LiteralPath $ann -Algorithm SHA256).Hash | Should -BeExactly $before.ann
        (Get-Item -LiteralPath $log).Length | Should -Be $beforeLen.log
        (Get-Item -LiteralPath $ann).Length | Should -Be $beforeLen.ann
    }

    It 'creates no file anywhere in the fixture directory' {
        if ($null -eq $script:HostExe) { Set-ItResult -Skipped -Because 'no PowerShell host available to spawn'; return }
        # The stronger companion claim: not merely "did not modify the inputs" but "wrote nothing at
        # all" -- a report file or a cache dropped beside the log would pass the hash check above.
        $dir = Join-Path $TestDrive ('ledger-ro2-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $log = Join-Path $dir 'diagnostics.jsonl'
        Write-Utf8NoBom -Path $log -Lines @(
            (New-CaptureLine -RuleId 'PSUseApprovedVerbs' -File $script:FileOther -Hash 'q1')
        )
        $before = @(Get-ChildItem -LiteralPath $dir -Recurse -Force | ForEach-Object { $_.FullName }) | Sort-Object
        & $script:HostExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $script:LedgerScript -Path $log 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
        $after = @(Get-ChildItem -LiteralPath $dir -Recurse -Force | ForEach-Object { $_.FullName }) | Sort-Object
        ($after -join '|') | Should -BeExactly ($before -join '|')
    }
}

Describe 'rule-efficacy-ledger -- never a silent skip: distinct exit codes for empty, absent, undiscovered' {
    It 'exits 3 -- not 0 with a zero-row ledger -- when the named log is ABSENT' {
        if ($null -eq $script:HostExe) { Set-ItResult -Skipped -Because 'no PowerShell host available to spawn'; return }
        $missing = Join-Path $TestDrive ('nope-' + [guid]::NewGuid().ToString('N') + '/diagnostics.jsonl')
        $out = & $script:HostExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $script:LedgerScript -Path $missing 2>&1
        $LASTEXITCODE | Should -Be 3
        ($out -join "`n") | Should -Match 'NOT a zero-row ledger'
    }

    It 'exits 3 when the named log EXISTS but holds no records' {
        if ($null -eq $script:HostExe) { Set-ItResult -Skipped -Because 'no PowerShell host available to spawn'; return }
        # The nastier of the two cases: the file is there, so a careless reader reports "0 findings"
        # and the caller concludes the rules never fired. They may simply never have been captured.
        $dir = Join-Path $TestDrive ('ledger-empty-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $log = Join-Path $dir 'diagnostics.jsonl'
        Write-Utf8NoBom -Path $log -Lines @('', '   ')
        $out = & $script:HostExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $script:LedgerScript -Path $log 2>&1
        $LASTEXITCODE | Should -Be 3
        ($out -join "`n") | Should -Match 'An absent or empty log is NOT a zero-row ledger'
    }

    It 'exits 4 when union discovery finds ZERO per-version cache directories' {
        if ($null -eq $script:HostExe) { Set-ItResult -Skipped -Because 'no PowerShell host available to spawn'; return }
        # Distinct from exit 3 on purpose: 3 means "looked, found nothing in it"; 4 means "there was
        # nothing to look at". Collapsing them would hide a broken cache-root resolution.
        $bare = Join-Path $TestDrive ('bare-cache-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $bare | Out-Null
        $out = & $script:HostExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $script:LedgerScript `
            -Source union -CacheRoot $bare 2>&1
        $LASTEXITCODE | Should -Be 4
        ($out -join "`n") | Should -Match 'ZERO per-version cache directories'
    }

    It 'exits 4, not 3, when the cache root itself does not exist' {
        if ($null -eq $script:HostExe) { Set-ItResult -Skipped -Because 'no PowerShell host available to spawn'; return }
        $gone = Join-Path $TestDrive ('gone-cache-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        & $script:HostExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $script:LedgerScript `
            -Source union -CacheRoot $gone 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 4
    }

    It 'exits 0 on a populated union -- the guards do not fire on the happy path' {
        if ($null -eq $script:HostExe) { Set-ItResult -Skipped -Because 'no PowerShell host available to spawn'; return }
        $root = Join-Path $TestDrive ('ok-cache-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        Write-Utf8NoBom -Path (Join-Path $root 'mk/powershell-lsp/1.27.0/dogfood/diagnostics.jsonl') -Lines @(
            (New-CaptureLine -RuleId 'PSUseApprovedVerbs' -File $script:FileOther -Hash 'z1')
        )
        $out = & $script:HostExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $script:LedgerScript `
            -Source union -CacheRoot $root 2>&1
        $LASTEXITCODE | Should -Be 0
        ($out -join "`n") | Should -Match 'cache version directories found: 1'
    }
}

Describe 'rule-efficacy-ledger -- review-dogfood.ps1 stays contract-unchanged' {
    It 'does not alter the shipped reader default output when both are loaded' {
        # Leg 1 built a SIBLING rather than extending review-dogfood.ps1 precisely so the shipped
        # reader's contract could not move. This pins that: with the ledger dot-sourced into the same
        # session, Show-DogfoodListing over a fixture still renders the pre-existing readout.
        $dir = Join-Path $TestDrive ('sib-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $log = Join-Path $dir 'diagnostics.jsonl'
        Write-Utf8NoBom -Path $log -Lines @(
            (New-CaptureLine -RuleId 'PSUseApprovedVerbs' -File $script:FileOther -Hash 'c1')
        )
        $text = Show-DogfoodListing -LogPath $log -AnnotationsPath (Join-Path $dir 'annotations.jsonl') -SummaryOnly
        $text | Should -Match 'powershell-lsp dogfood review'
        $text | Should -Match 'by source'
        $text | Should -Not -Match 'facts only, no scores'
    }
}

Describe 'rule-efficacy-ledger -- every readout carries its MEASUREMENT instant (000172 leg 6)' {
    # WHY THIS EXISTS: the capture logs are append-only and LIVE. 000170 reported 120 real
    # occurrences, 000171 reported 124 early in its session and 126 later, and all three are
    # correct readings of the same growing log at three different instants. Unstamped, they read
    # as a contradiction. The stamp is what makes a pasted figure re-derivable.

    BeforeAll {
        $script:StampDir = Join-Path $TestDrive ('stamp-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:StampLog = Join-Path $script:StampDir 'diagnostics.jsonl'
        $script:StampAnn = Join-Path $script:StampDir 'annotations.jsonl'
        Write-Utf8NoBom -Path $script:StampLog -Lines @(
            (New-CaptureLine -RuleId 'PSUseApprovedVerbs' -File $script:FileOther -Hash 's1')
            (New-CaptureLine -RuleId 'PSAvoidUsingCmdletAliases' -File $script:FileOther -Hash 's2')
        )
        Write-Utf8NoBom -Path $script:StampAnn -Lines @((New-AnnotationLine -Hash 's1' -Verdict 'useful'))
    }

    It 'stamps the read with a parseable UTC instant and a read-window duration' {
        $before = [datetime]::UtcNow.AddSeconds(-5)
        $read = Read-RuleLedgerInput -LogPaths @($script:StampLog) -AnnotationsPath $script:StampAnn
        $after = [datetime]::UtcNow.AddSeconds(5)

        $read.MeasuredAtUtc | Should -Not -BeNullOrEmpty
        $parsed = [datetime]::Parse($read.MeasuredAtUtc, [cultureinfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind)
        $parsed.Kind | Should -Be ([System.DateTimeKind]::Utc) -Because 'a stamp without a zone is not an instant'
        ($parsed -gt $before -and $parsed -lt $after) | Should -BeTrue -Because 'the stamp must be the real read instant'
        [int]$read.ReadWindowMs | Should -BeGreaterOrEqual 0
    }

    It 'PROOF: two readouts of the SAME UNCHANGED log carry DIFFERENT stamps' {
        # The load-bearing assertion for leg 6: the stamp tracks WHEN THE READ HAPPENED, so two
        # reads separated in time differ even though the underlying log is byte-identical
        # throughout. A stamp derived from the log's own mtime, or hardcoded, would fail this.
        $hashBefore = (Get-FileHash -LiteralPath $script:StampLog -Algorithm SHA256).Hash

        $r1 = Read-RuleLedgerInput -LogPaths @($script:StampLog) -AnnotationsPath $script:StampAnn
        Start-Sleep -Milliseconds 50
        $r2 = Read-RuleLedgerInput -LogPaths @($script:StampLog) -AnnotationsPath $script:StampAnn

        $hashAfter = (Get-FileHash -LiteralPath $script:StampLog -Algorithm SHA256).Hash
        $hashAfter | Should -BeExactly $hashBefore -Because 'the log must be UNCHANGED between the two reads'

        $r2.MeasuredAtUtc | Should -Not -BeExactly $r1.MeasuredAtUtc
        ([datetime]::Parse($r2.MeasuredAtUtc, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)) |
            Should -BeGreaterThan ([datetime]::Parse($r1.MeasuredAtUtc, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind))

        # and the counts are identical, which is what makes the differing stamps meaningful
        @($r2.Occurrences).Count | Should -Be @($r1.Occurrences).Count
    }

    It 'RENDERS the stamp in the readout, labelled as a READ instant and not a render time' {
        $read = Read-RuleLedgerInput -LogPaths @($script:StampLog) -AnnotationsPath $script:StampAnn
        $ledger = Get-RuleEfficacyLedger -Occurrences @($read.Occurrences) -Annotations $read.Annotations
        $sources = [pscustomobject]@{ Discovery = 'test'; VersionDirs = @() }
        $text = Format-RuleEfficacyLedger -Ledger $ledger -Sources $sources -LedgerInput $read

        $text | Should -Match 'measured at: '
        $text | Should -Match ([regex]::Escape($read.MeasuredAtUtc))
        $text | Should -Match 'the instant the capture logs were READ'
        $text | Should -Match 'NOT a render time'
        $text | Should -Match 'APPEND-ONLY and LIVE'
    }

    It 'the RENDERED stamp differs between two renders over the same unchanged log' {
        # End-to-end: it is the pasted READOUT that has to carry the vintage, not just the object.
        $sources = [pscustomobject]@{ Discovery = 'test'; VersionDirs = @() }
        $render = {
            $rd = Read-RuleLedgerInput -LogPaths @($script:StampLog) -AnnotationsPath $script:StampAnn
            $lg = Get-RuleEfficacyLedger -Occurrences @($rd.Occurrences) -Annotations $rd.Annotations
            Format-RuleEfficacyLedger -Ledger $lg -Sources $sources -LedgerInput $rd
        }
        $t1 = & $render
        Start-Sleep -Milliseconds 50
        $t2 = & $render
        $t1 | Should -Not -BeExactly $t2 -Because 'the readout must carry its own vintage'
        # ...and the ONLY difference is the stamp line: the facts did not move.
        $strip = { param($t) (@($t -split "`r?`n") | Where-Object { $_ -notmatch 'measured at: ' -and $_ -notmatch 'ms window' }) -join "`n" }
        (& $strip $t1) | Should -BeExactly (& $strip $t2)
    }
}

Describe 'rule-efficacy-ledger -- lifecycle columns: ABSENT, NO-EVENTS and a number are three claims (000171 leg 2)' {
    BeforeAll {
        function script:New-LifecycleLine {
            param([string] $RuleId, [int] $Cleared = 0, [int] $StillPresent = 0)
            $o = [ordered]@{
                schema = 'powershell-lsp-lifecycle/1'; ts = '2026-07-31T00:00:00.0000000-04:00'
                file = 'C:\proj\alpha\a.ps1'; ruleId = $RuleId
                cleared = $Cleared; stillPresent = $StillPresent
                clearedHashes = @(1..$Cleared | ForEach-Object { 'c' + $_ })
                stillPresentHashes = @(1..$StillPresent | ForEach-Object { 's' + $_ })
                attemptsMax = 1; downgraded = $false; scopeApplied = $true
            }
            return ($o | ConvertTo-Json -Depth 5 -Compress)
        }
    }

    It 'renders (absent) -- NOT 0 -- when no lifecycle log exists at all' {
        # THE criterion this leg exists to satisfy: a ledger over nothing and a ledger of zeros are
        # different claims and must not render identically.
        $dir = Join-Path $TestDrive ('lc-absent-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $log = Join-Path $dir 'diagnostics.jsonl'
        Write-Utf8NoBom -Path $log -Lines @((New-CaptureLine -RuleId 'PSUseApprovedVerbs' -File $script:FileOther -Hash 'c1'))
        $out = (& $script:HostExe -NoLogo -NoProfile -File $script:LedgerScript -Path $log -LifecyclePath (Join-Path $dir 'no-such-dir')) -join "`n"
        $out | Should -Match '\(absent\)'
        $out | Should -Match 'lifecycle logs read: NONE'
        # And it must NOT have quietly rendered a zero.
        $out | Should -Not -Match 'PSUseApprovedVerbs.*0\.0 pct'
    }

    It 'renders (no-events) when a lifecycle log EXISTS but holds nothing for this rule' {
        $dir = Join-Path $TestDrive ('lc-noev-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $log = Join-Path $dir 'diagnostics.jsonl'
        Write-Utf8NoBom -Path $log -Lines @((New-CaptureLine -RuleId 'PSUseApprovedVerbs' -File $script:FileOther -Hash 'c1'))
        $lcDir = Join-Path $dir 'logs'
        Write-Utf8NoBom -Path (Join-Path $lcDir 'lifecycle-20260731-000000-000.jsonl') -Lines @((New-LifecycleLine -RuleId 'PSAvoidUsingCmdletAliases' -Cleared 1))
        $out = (& $script:HostExe -NoLogo -NoProfile -File $script:LedgerScript -Path $log -LifecyclePath $lcDir) -join "`n"
        $out | Should -Match '\(no-events\)'
        $out | Should -Not -Match '\(absent\)'
    }

    It 'DERIVES both rates from counted events, and they are complementary' {
        $dir = Join-Path $TestDrive ('lc-derive-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $log = Join-Path $dir 'diagnostics.jsonl'
        Write-Utf8NoBom -Path $log -Lines @((New-CaptureLine -RuleId 'PSUseApprovedVerbs' -File $script:FileOther -Hash 'c1'))
        $lcDir = Join-Path $dir 'logs'
        # 3 cleared + 1 still-present -> 75.0 pct fixed, 25.0 pct persistence, n=4. Hand-counted.
        Write-Utf8NoBom -Path (Join-Path $lcDir 'lifecycle-20260731-000000-000.jsonl') -Lines @(
            (New-LifecycleLine -RuleId 'PSUseApprovedVerbs' -Cleared 2 -StillPresent 1),
            (New-LifecycleLine -RuleId 'PSUseApprovedVerbs' -Cleared 1 -StillPresent 0)
        )
        $out = (& $script:HostExe -NoLogo -NoProfile -File $script:LedgerScript -Path $log -LifecyclePath $lcDir) -join "`n"
        $out | Should -Match '75 pct \(n=4\)'
        $out | Should -Match '25 pct \(n=4\)'
    }

    It 'unions EVERY lifecycle-*.jsonl in the rotation family, not just the newest' {
        # The log rotates per daemon run under keepLastN, so a reader that took only the newest file
        # would silently shrink the denominator every time a session restarted.
        $dir = Join-Path $TestDrive ('lc-union-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $log = Join-Path $dir 'diagnostics.jsonl'
        Write-Utf8NoBom -Path $log -Lines @((New-CaptureLine -RuleId 'PSUseApprovedVerbs' -File $script:FileOther -Hash 'c1'))
        $lcDir = Join-Path $dir 'logs'
        Write-Utf8NoBom -Path (Join-Path $lcDir 'lifecycle-20260731-000000-000.jsonl') -Lines @((New-LifecycleLine -RuleId 'PSUseApprovedVerbs' -Cleared 1))
        Write-Utf8NoBom -Path (Join-Path $lcDir 'lifecycle-20260731-111111-111.jsonl') -Lines @((New-LifecycleLine -RuleId 'PSUseApprovedVerbs' -Cleared 3))
        $out = (& $script:HostExe -NoLogo -NoProfile -File $script:LedgerScript -Path $log -LifecyclePath $lcDir) -join "`n"
        $out | Should -Match 'n=4'          # 1 + 3, so BOTH files were read
        $out | Should -Match 'lifecycle logs read: 2'
    }

    It 'an ABSENT lifecycle log is NOT an error -- the capture ledger still renders and exits 0' {
        # The two logs have independent lifetimes. Only the CAPTURE log carries the exit-3/exit-4
        # never-a-silent-skip contract; a missing sibling must degrade to (absent), not fail.
        $dir = Join-Path $TestDrive ('lc-noerr-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $log = Join-Path $dir 'diagnostics.jsonl'
        Write-Utf8NoBom -Path $log -Lines @((New-CaptureLine -RuleId 'PSUseApprovedVerbs' -File $script:FileOther -Hash 'c1'))
        & $script:HostExe -NoLogo -NoProfile -File $script:LedgerScript -Path $log -LifecyclePath (Join-Path $dir 'nope') | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'D1 -- a NOT-FOUND under a FALLBACK data root must not render as ABSENT (dispatch 000185)' {
    # THE DEFECT, restated so this suite reads without the dispatch in hand. 'absent' is documented
    # in Get-LifecycleRates as "the signal was NEVER CAPTURED" -- a claim about the WORLD. It was
    # reachable whenever the lifecycle search returned nothing, and the default search directory
    # derives from Get-PluginDataRoot, which SILENTLY substitutes a temp fallback when
    # CLAUDE_PLUGIN_DATA is unset. So the world-claim was published on evidence that only supported
    # "I found no file under the directory I happened to resolve" -- a claim about the READER.
    #
    # THE RED CONTROL THIS SUITE IS BUILT ON is the differential 000183 recorded and 000185
    # re-derived: lifecycle logs PRESENT under the real data root, ZERO under the %TEMP% fallback.
    # The fixture below reproduces that shape hermetically under $TestDrive -- the real logs are
    # never read, per this file's header -- and these assertions FAIL against the pre-000185
    # reader, which had no fourth state to render.

    It 'renders (unresolvable), NOT (absent), when the search ran under a FALLBACK root' {
        # The load-bearing assertion. Pre-fix this returned state 'absent' and this test goes RED.
        $r = Get-LifecycleRates -ByRule @{} -Present $false -RuleId 'PSUseApprovedVerbs' -RootKnown $false
        [string]$r.state | Should -BeExactly 'unresolvable'
        (Format-LedgerRate -Rate ([pscustomobject]@{ state = $r.state; value = $r.fixed; events = $r.events })) |
            Should -BeExactly '(unresolvable)'
    }

    It 'still renders (absent) when the root IS known -- the original claim keeps its meaning' {
        # The fix must not smear every not-found into "cannot determine". When the reader knows
        # which directory it was supposed to search, a miss really is an absence.
        $r = Get-LifecycleRates -ByRule @{} -Present $false -RuleId 'PSUseApprovedVerbs' -RootKnown $true
        [string]$r.state | Should -BeExactly 'absent'
        (Format-LedgerRate -Rate ([pscustomobject]@{ state = $r.state; value = $r.fixed; events = $r.events })) |
            Should -BeExactly '(absent)'
    }

    It 'RED control: the two states are DISTINCT renderings -- collapsing them fails this test' {
        # A "fix" that rendered 'unresolvable' as '(absent)' would satisfy every one-direction
        # assertion above while restoring the exact defect. This asserts the two differ.
        $unres = Format-LedgerRate -Rate ([pscustomobject]@{ state = 'unresolvable'; value = $null; events = 0 })
        $abs = Format-LedgerRate -Rate ([pscustomobject]@{ state = 'absent'; value = $null; events = 0 })
        $unres | Should -Not -Be $abs
        $unres | Should -Not -Match 'absent'
    }

    It 'RED control: the PRE-FIX two-branch reader produces (absent) on the SAME input' {
        # A replica of the pre-000185 branch, fed the identical arguments the first It uses. It
        # returns 'absent' -- what the shipped reader used to do and what the first It now forbids.
        # Revert the fix and the first It goes RED while this one still passes, so the pair pins
        # the change in both directions rather than asserting only the new behavior.
        function script:Get-LifecycleRatesPreFix {
            param([hashtable] $ByRule, [bool] $Present, [string] $RuleId)
            if (-not $Present) { return @{ fixed = $null; persistence = $null; state = 'absent'; events = 0 } }
            return @{ fixed = 0; persistence = 0; state = 'derived'; events = 0 }
        }
        $pre = Get-LifecycleRatesPreFix -ByRule @{} -Present $false -RuleId 'PSUseApprovedVerbs'
        $post = Get-LifecycleRates -ByRule @{} -Present $false -RuleId 'PSUseApprovedVerbs' -RootKnown $false
        [string]$pre.state | Should -BeExactly 'absent'
        [string]$post.state | Should -BeExactly 'unresolvable'
        [string]$pre.state | Should -Not -Be ([string]$post.state)
    }

    It 'the DIFFERENTIAL: logs under the real root are invisible to a fallback-root search' {
        # The 000183/000185 differential, hermetically. Two lifecycle logs exist under the
        # fixture's REAL root; the FALLBACK root holds none. This is the evidence that makes
        # 'absent' FALSE rather than merely unproven.
        #
        # The fixture line is built INLINE rather than via the New-LifecycleLine helper defined in
        # the Describe above. That helper is script-scoped from ANOTHER Describe's BeforeAll, so it
        # only exists here if that Describe happened to run first -- which is true in a full-file
        # run and FALSE under -FullNameFilter. Depending on it made this test pass for a reason
        # unrelated to what it asserts; the D1-D falsification harness filters by name and caught it.
        $base = Join-Path $TestDrive ('d1-diff-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $realLogs = Join-Path $base 'real/logs'
        $fallbackLogs = Join-Path $base 'fallback/logs'
        $lcLine = ([ordered]@{
                schema = 'powershell-lsp-lifecycle/1'; ts = '2026-08-02T00:00:00.0000000-04:00'
                file = 'C:\proj\alpha\a.ps1'; ruleId = 'PSUseApprovedVerbs'
                cleared = 1; stillPresent = 0; clearedHashes = @('c1'); stillPresentHashes = @()
                attemptsMax = 1; downgraded = $false; scopeApplied = $true
            } | ConvertTo-Json -Depth 5 -Compress)
        foreach ($n in @('lifecycle-20260802-070007-318.jsonl', 'lifecycle-20260802-165744-226.jsonl')) {
            $p = Join-Path $realLogs $n
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null
            [System.IO.File]::WriteAllText($p, ($lcLine + "`n"), (New-Object System.Text.UTF8Encoding($false)))
        }
        New-Item -ItemType Directory -Force -Path $fallbackLogs | Out-Null

        @(Get-ChildItem -LiteralPath $realLogs -Filter 'lifecycle-*.jsonl' -File).Count | Should -Be 2
        @(Get-ChildItem -LiteralPath $fallbackLogs -Filter 'lifecycle-*.jsonl' -File).Count | Should -Be 0

        # Pointed at the real root the reader FINDS them; pointed at the fallback it does not.
        @((Resolve-LifecycleLogSearch -LifecyclePath $realLogs).Paths).Count | Should -Be 2
        @((Resolve-LifecycleLogSearch -LifecyclePath $fallbackLogs).Paths).Count | Should -Be 0
    }

    It 'the search result CARRIES its provenance, and an explicit -LifecyclePath is always Known' {
        # An explicitly named directory cannot be a silent substitution: the caller chose it, so a
        # miss there is a real miss and must still render (absent), not (unresolvable).
        $dir = Join-Path $TestDrive ('d1-prov-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $s = Resolve-LifecycleLogSearch -LifecyclePath $dir
        $s.RootKnown | Should -BeTrue
        $s.Provenance | Should -BeExactly 'explicit:-LifecyclePath'
        [string]$s.SearchRoot | Should -BeExactly $dir
    }

    It 'the ledger READOUT names the resolved root and its provenance on a run that finds NOTHING' {
        # Acceptance: the readout names the root on EVERY run, including runs that find nothing.
        $dir = Join-Path $TestDrive ('d1-readout-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $log = Join-Path $dir 'diagnostics.jsonl'
        Write-Utf8NoBom -Path $log -Lines @((New-CaptureLine -RuleId 'PSUseApprovedVerbs' -File $script:FileOther -Hash 'c1'))
        $missing = Join-Path $dir 'no-such-dir'
        $out = (& $script:HostExe -NoLogo -NoProfile -File $script:LedgerScript -Path $log -LifecyclePath $missing) -join "`n"
        $out | Should -Match 'lifecycle search root:'
        $out | Should -Match 'resolved via: explicit:-LifecyclePath'
        $out | Should -Match 'data-root known: YES'
    }
}

Describe 'ND-B/ND-C -- owned finders are UNATTRIBUTABLE, reported as a third number (dispatch 000185)' {
    # THE DEFECT. Get-SurfaceAttribution opened its loop with a short-circuit that counted every
    # non-PS ruleId as IN the current surface and `continue`d past both the removed-rule test and
    # the unknown-partition test. An owned finder's occurrences could therefore never be reported
    # out-of-surface BY CONSTRUCTION: the reported zero was not a measurement, it was a category
    # that could not be entered. Option (iii) of the ND-B fork is taken -- an explicit
    # UNATTRIBUTABLE bucket, reported rather than folded into either side. Nothing about what is
    # WRITTEN per capture record changes.
    BeforeAll {
        $script:NdHistory = @{ '1.27.1' = @('PSAvoidUsingCmdletAliases') }
        $script:NdSurface = @('PSAvoidUsingCmdletAliases')
        $script:NdOcc = @(
            [pscustomobject]@{ ruleId = 'PSAvoidUsingCmdletAliases'; partition = '1.27.1' }   # in surface
            [pscustomobject]@{ ruleId = 'PSUseApprovedVerbs'; partition = '1.27.1' }          # out of surface
            [pscustomobject]@{ ruleId = 'ManifestConsistency'; partition = '1.27.1' }         # owned finder
            [pscustomobject]@{ ruleId = 'ManifestConsistency'; partition = '1.27.1' }         # owned finder
        )
        $script:NdAttr = Get-SurfaceAttribution -Occurrences $script:NdOcc -CurrentSurface $script:NdSurface -History $script:NdHistory
    }

    It 'emits gross, net and unattributable as THREE separate numbers' {
        [int]$script:NdAttr.Gross | Should -Be 4
        [int]$script:NdAttr.Net | Should -Be 2
        [int]$script:NdAttr.Unattributable | Should -Be 2
    }

    It 'gross = net + unattributable, exactly -- the remainder is never absorbed' {
        ([int]$script:NdAttr.Net + [int]$script:NdAttr.Unattributable) | Should -Be ([int]$script:NdAttr.Gross)
    }

    It 'the owned finder is NOT counted in-surface -- this is the short-circuit closing' {
        # Pre-fix InCurrentSurface was 3 (1 real + 2 owned) and this goes RED against that reader.
        [int]$script:NdAttr.InCurrentSurface | Should -Be 1
        [int]$script:NdAttr.OutOfCurrentSurface | Should -Be 1
        @(@($script:NdAttr.UnattributableRules) | Where-Object { $_.ruleId -eq 'ManifestConsistency' })[0].occurrences |
            Should -Be 2
    }

    It 'RED control: fold the bucket back in and the in-surface count changes -- the guard bites' {
        # Proof the assertion above discriminates. This recomputes what the PRE-FIX line produced
        # (in-surface absorbing the owned finders) and asserts it DIFFERS from what ships now.
        $preFixInCurrent = [int]$script:NdAttr.InCurrentSurface + [int]$script:NdAttr.Unattributable
        $preFixInCurrent | Should -Be 3
        $preFixInCurrent | Should -Not -Be ([int]$script:NdAttr.InCurrentSurface)
    }

    It 'the partition test now runs for owned finders too -- it was skipped by the same continue' {
        $occ = @([pscustomobject]@{ ruleId = 'ManifestConsistency'; partition = '9.9.9' })
        $a = Get-SurfaceAttribution -Occurrences $occ -CurrentSurface $script:NdSurface -History $script:NdHistory
        [int]$a.UnknownPartition | Should -Be 1
        [int]$a.Unattributable | Should -Be 1
    }
}

Describe '000209 -- lifecycle provenance: an in-record version stamp at emit, and a printed floor' {
    # THE GAP THIS CLOSES. fired_count and distinct_shapes are version-attributable because the
    # capture log's marketplace-cache PATH carries the plugin version. The SIBLING lifecycle log
    # that feeds fixed_next_turn_rate and persistence_rate had no counterpart: no version field,
    # and a flat stamped rolling family for a path, so the provenance of the clearance columns was
    # not merely unfiltered but UNRECOVERABLE.
    #
    # THE FIX IS FORWARD-ONLY, IN TWO HALVES, AND THIS SUITE PINS BOTH:
    #   1. EMIT  -- New-LifecycleLedgerRecords stamps `pluginVersion` from Get-PluginVersion.
    #   2. READ  -- the ledger PRINTS the earliest version-attributable point and labels anything
    #               below it a bounded, known gap.
    #
    # AND IT PINS WHAT MUST NOT MOVE. The union read stays NON-FILTERING: an unstamped record is
    # still counted in every rate. Filtering the union to stamped records would silently restate
    # fixed_next_turn_rate and persistence_rate for every rule with pre-000209 history -- the
    # cardinal metrics anti-pattern this ruling exists to refuse. The golden Context below proves
    # that by COMPARISON against the pre-change rendering, not by assertion.

    BeforeAll {
        function script:New-VersionedLifecycleLine {
            # One lifecycle line. -Version $null OMITS the field entirely, which is exactly the
            # shape every pre-000209 record on disk has -- not a blank field, an ABSENT one.
            param([string] $RuleId, $Version, [int] $Cleared = 0, [int] $StillPresent = 0)
            $o = [ordered]@{ schema = 'powershell-lsp-lifecycle/1'; ts = '2026-07-31T00:00:00.0000000-04:00' }
            if ($null -ne $Version) { $o['pluginVersion'] = [string]$Version }
            $o['file'] = 'C:\proj\alpha\a.ps1'
            $o['ruleId'] = $RuleId
            $o['cleared'] = $Cleared
            $o['stillPresent'] = $StillPresent
            $o['clearedHashes'] = @()
            $o['stillPresentHashes'] = @()
            $o['attemptsMax'] = 1
            $o['downgraded'] = $false
            $o['scopeApplied'] = $true
            return ($o | ConvertTo-Json -Depth 5 -Compress)
        }

        function script:Read-LifecycleFixture {
            # Write lines to a fresh lifecycle family and read them back through the SHIPPED reader.
            param([string[]] $Lines)
            $dir = Join-Path $TestDrive ('p209-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            Write-Utf8NoBom -Path (Join-Path $dir 'lifecycle-20260731-000000-000.jsonl') -Lines $Lines
            $search = Resolve-LifecycleLogSearch -LifecyclePath $dir
            return (Read-LifecycleLog -LogPaths @($search.Paths) -Search $search)
        }
    }

    Context 'EMIT -- every new record carries a REAL plugin version, resolved at emit time' {
        It 'emit-and-read-back: the record ON DISK carries exactly Get-PluginVersion' {
            # The whole round trip through the shipped writer, not a shape assertion on an
            # in-memory object: build records, append them as JSONL, read the file back, parse.
            $p = Join-Path $TestDrive ('emit-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.jsonl')
            $env:POWERSHELL_LSP_LIFECYCLE_LOG = $p
            try {
                $recs = @(New-LifecycleLedgerRecords -File 'f.ps1' -Timestamp 't' -ScopeApplied $true `
                        -LedgerKeys @{ cleared = @([pscustomobject]@{ hash = 'h'; ruleId = 'PSUseApprovedVerbs' }); stillPresent = @() })
                Add-LifecycleLedgerEntries -Records $recs -Stamp 's' | Should -BeTrue
                $onDisk = @(Get-Content -LiteralPath $p | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                        ForEach-Object { $_ | ConvertFrom-Json })
                $onDisk.Count | Should -Be 1
                # The load-bearing assertion. Equality with Get-PluginVersion is what makes this a
                # PROVENANCE stamp rather than a literal: a hardcoded version would pass a
                # regex-shaped check and fail this one at the next release.
                [string]$onDisk[0].pluginVersion | Should -BeExactly ([string](Get-PluginVersion))
                [string]$onDisk[0].pluginVersion | Should -Not -BeNullOrEmpty
            } finally { $env:POWERSHELL_LSP_LIFECYCLE_LOG = $null }
        }

        It 'RED control: a record MISSING the field fails the very assertion the emit path passes' {
            # The pre-000209 record shape, fed to the same check. It must FAIL -- otherwise the
            # assertion above is vacuous and would pass against the unfixed emit site.
            $preFix = [ordered]@{ schema = 'powershell-lsp-lifecycle/1'; ts = 't'; ruleId = 'R'; cleared = 1; stillPresent = 0 }
            $json = ($preFix | ConvertTo-Json -Depth 5 -Compress)
            $json | Should -Not -Match 'pluginVersion'
            $parsed = $json | ConvertFrom-Json
            [string](Get-Prop $parsed 'pluginVersion') | Should -BeNullOrEmpty
            [string](Get-Prop $parsed 'pluginVersion') | Should -Not -BeExactly ([string](Get-PluginVersion))
        }

        It 'the stamp resolves at EMIT time, and the default path cannot leave the field blank' {
            # -PluginVersion is a test seam. Passing one is honored; passing NOTHING resolves the
            # real version rather than leaving the field blank or inventing a placeholder.
            $seam = @(New-LifecycleLedgerRecords -File 'f.ps1' -Timestamp 't' -ScopeApplied $true -PluginVersion '1.2.3' `
                    -LedgerKeys @{ cleared = @([pscustomobject]@{ hash = 'h'; ruleId = 'R' }); stillPresent = @() })
            [string]$seam[0].pluginVersion | Should -BeExactly '1.2.3'
            $default = @(New-LifecycleLedgerRecords -File 'f.ps1' -Timestamp 't' -ScopeApplied $true `
                    -LedgerKeys @{ cleared = @([pscustomobject]@{ hash = 'h'; ruleId = 'R' }); stillPresent = @() })
            [string]$default[0].pluginVersion | Should -BeExactly ([string](Get-PluginVersion))
        }

        It 'a turn with NO lifecycle event still writes NOTHING -- the stamp adds no empty record' {
            @(New-LifecycleLedgerRecords -LedgerKeys @{ cleared = @(); stillPresent = @() } `
                    -File 'f.ps1' -Timestamp 't' -ScopeApplied $true).Count | Should -Be 0
        }
    }

    Context 'FLOOR -- the EARLIEST version-attributable point, ordered semantically' {
        It 'the floor is the MINIMUM attributable version, not the maximum' {
            $f = Get-LifecycleProvenanceFloor -Versions @{ '1.29.1' = 7; '1.9.0' = 2; '1.10.0' = 5 } -PreFloor 0
            [string]$f.State | Should -BeExactly 'floored'
            [string]$f.Floor | Should -BeExactly '1.9.0'
            [int]$f.Attributable | Should -Be 14
        }

        It 'RED control: taking the MAXIMUM would name a DIFFERENT version on this same fixture' {
            # "Earliest version-attributable point" is a claim about where knowledge BEGINS. An
            # implementation that reused the cache-dir selector (which picks the greatest, correctly,
            # for its own purpose) would name 1.29.1 and disown every older stamped record. The two
            # must differ on this fixture, or the min/max choice is untested.
            $vers = @{ '1.29.1' = 7; '1.9.0' = 2; '1.10.0' = 5 }
            $f = Get-LifecycleProvenanceFloor -Versions $vers -PreFloor 0
            $max = @(@($vers.Keys) | Sort-Object { [System.Version](([string]$_ -split '-', 2)[0]) } -Descending)[0]
            [string]$max | Should -BeExactly '1.29.1'
            [string]$f.Floor | Should -Not -Be ([string]$max)
        }

        It 'RED control: LEXICAL ordering picks the WRONG floor -- 1.10.0 sorts before 1.9.0 as text' {
            # The exact trap a string sort would spring. If the floor were lexical it would report
            # 1.10.0, a version LATER than the true earliest.
            $vers = @{ '1.9.0' = 1; '1.10.0' = 1 }
            $lexical = @(@($vers.Keys) | Sort-Object)[0]
            [string]$lexical | Should -BeExactly '1.10.0'
            [string](Get-LifecycleProvenanceFloor -Versions $vers -PreFloor 0).Floor | Should -BeExactly '1.9.0'
            [string](Get-LifecycleProvenanceFloor -Versions $vers -PreFloor 0).Floor | Should -Not -Be ([string]$lexical)
        }

        It 'the 0.0.0-unknown SENTINEL is not a version -- it is Get-PluginVersion saying it did not know' {
            # Counting the sentinel would attribute real clearance data to a release that never
            # existed, and 0.0.0 would become the floor of every ledger that ever saw one.
            Test-LifecycleVersionAttributable -Version '0.0.0-unknown' | Should -BeFalse
            Test-LifecycleVersionAttributable -Version '' | Should -BeFalse
            Test-LifecycleVersionAttributable -Version 'not-a-version' | Should -BeFalse
            Test-LifecycleVersionAttributable -Version '1.29.1' | Should -BeTrue
            Test-LifecycleVersionAttributable -Version '1.30.0-rc1' | Should -BeTrue
            $f = Get-LifecycleProvenanceFloor -Versions @{ '0.0.0-unknown' = 3; '1.29.0' = 1 } -PreFloor 0
            [string]$f.Floor | Should -BeExactly '1.29.0'
            [int]$f.Attributable | Should -Be 1
        }

        It 'gap-only and none are DISTINCT states -- no data at all is not the same claim as no provenance' {
            [string](Get-LifecycleProvenanceFloor -Versions @{} -PreFloor 4).State | Should -BeExactly 'gap-only'
            [string](Get-LifecycleProvenanceFloor -Versions @{} -PreFloor 0).State | Should -BeExactly 'none'
            (Get-LifecycleProvenanceFloor -Versions @{} -PreFloor 4).Floor | Should -BeNullOrEmpty
        }
    }

    Context 'BACKWARD COMPAT -- a MIXED old/new log reads without throwing and floors correctly' {
        It 'a mixed log reads clean, floors at the earliest STAMPED version, and calls the rest a gap' {
            $lines = @(
                (New-VersionedLifecycleLine -RuleId 'PSUseApprovedVerbs' -Version $null -Cleared 2 -StillPresent 1)
                (New-VersionedLifecycleLine -RuleId 'PSUseApprovedVerbs' -Version $null -Cleared 1 -StillPresent 0)
                (New-VersionedLifecycleLine -RuleId 'PSUseApprovedVerbs' -Version '1.29.0' -Cleared 3 -StillPresent 1)
                (New-VersionedLifecycleLine -RuleId 'PSUseApprovedVerbs' -Version '1.29.1' -Cleared 1 -StillPresent 0)
            )
            { $script:MixedLc = Read-LifecycleFixture -Lines $lines } | Should -Not -Throw
            $lc = $script:MixedLc
            [int]$lc.Records | Should -Be 4
            [int]$lc.Skipped | Should -Be 0
            [int]$lc.Attributable | Should -Be 2
            [int]$lc.PreFloorRecords | Should -Be 2
            # Attributable + PreFloor == Records, exactly. No record falls between the two buckets.
            ([int]$lc.Attributable + [int]$lc.PreFloorRecords) | Should -Be ([int]$lc.Records)
            $f = Get-LifecycleProvenanceFloor -Versions $lc.Versions -PreFloor ([int]$lc.PreFloorRecords)
            [string]$f.Floor | Should -BeExactly '1.29.0'
            [int]$f.PreFloor | Should -Be 2
        }

        It 'RED control: the OLD unstamped records are STILL COUNTED -- the union did not filter' {
            # THE anti-pattern guard. Both fixtures carry the identical four events; only the
            # stamping differs. A reader that dropped unstamped records would report n=5 on the
            # mixed log instead of n=9, silently restating a published rate.
            $mixed = Read-LifecycleFixture -Lines @(
                (New-VersionedLifecycleLine -RuleId 'PSUseApprovedVerbs' -Version $null -Cleared 2 -StillPresent 1)
                (New-VersionedLifecycleLine -RuleId 'PSUseApprovedVerbs' -Version $null -Cleared 1 -StillPresent 0)
                (New-VersionedLifecycleLine -RuleId 'PSUseApprovedVerbs' -Version '1.29.0' -Cleared 3 -StillPresent 1)
                (New-VersionedLifecycleLine -RuleId 'PSUseApprovedVerbs' -Version '1.29.1' -Cleared 1 -StillPresent 0)
            )
            $allStamped = Read-LifecycleFixture -Lines @(
                (New-VersionedLifecycleLine -RuleId 'PSUseApprovedVerbs' -Version '1.28.0' -Cleared 2 -StillPresent 1)
                (New-VersionedLifecycleLine -RuleId 'PSUseApprovedVerbs' -Version '1.28.0' -Cleared 1 -StillPresent 0)
                (New-VersionedLifecycleLine -RuleId 'PSUseApprovedVerbs' -Version '1.29.0' -Cleared 3 -StillPresent 1)
                (New-VersionedLifecycleLine -RuleId 'PSUseApprovedVerbs' -Version '1.29.1' -Cleared 1 -StillPresent 0)
            )
            # 7 cleared + 2 still-present = 9 events. Hand-counted, and IDENTICAL either way.
            $mixedRate = Get-LifecycleRates -ByRule $mixed.ByRule -Present $true -RuleId 'PSUseApprovedVerbs'
            $stampedRate = Get-LifecycleRates -ByRule $allStamped.ByRule -Present $true -RuleId 'PSUseApprovedVerbs'
            [int]$mixedRate.events | Should -Be 9
            [int]$stampedRate.events | Should -Be 9
            [double]$mixedRate.fixed | Should -Be ([double]$stampedRate.fixed)
            [double]$mixedRate.persistence | Should -Be ([double]$stampedRate.persistence)
            # The filtered counterfactual, written down so the number this test forbids is explicit
            # rather than merely implied.
            [int]$mixedRate.events | Should -Not -Be 5
        }

        It 'an ALL-OLD log (nothing stamped anywhere) reads without throwing and reports gap-only' {
            $lc = Read-LifecycleFixture -Lines @(
                (New-VersionedLifecycleLine -RuleId 'PSUseApprovedVerbs' -Version $null -Cleared 3 -StillPresent 1)
            )
            [int]$lc.Records | Should -Be 1
            [int]$lc.PreFloorRecords | Should -Be 1
            $f = Get-LifecycleProvenanceFloor -Versions $lc.Versions -PreFloor ([int]$lc.PreFloorRecords)
            [string]$f.State | Should -BeExactly 'gap-only'
            # ...and the rate is STILL derived from those unattributable records.
            [int](Get-LifecycleRates -ByRule $lc.ByRule -Present $true -RuleId 'PSUseApprovedVerbs').events | Should -Be 4
        }
    }

    Context 'NON-FILTERING -- proven by COMPARISON with the pre-000209 rendering, not by assertion' {
        It 'GOLDEN: the pre-change readout is reproduced line-for-line; the ONLY delta is the added block' {
            # The golden below was CAPTURED by running origin/main's rule-efficacy-ledger.ps1 over
            # this exact fixture, then re-running the changed script over the same fixture. It is a
            # before/after comparison on a fixture, which is what acceptance 3 asks for: an
            # assertion that "nothing changed" would pass just as happily if everything had.
            #
            # Paths are normalised to FIXTURE and separators to '/', so the comparison is over the
            # RENDERING and cannot be defeated by a temp directory name.
            $golden = @'
powershell-lsp per-rule diagnostic efficacy ledger (Arc A slice A1) -- facts only, no scores
  discovery: FIXED FIXTURE
  logs read: 1
    FIXTURE/diagnostics.jsonl  (2 records)
  annotations read: 0
  lifecycle search root: FIXTURE/logs
    resolved via: explicit:-LifecyclePath   data-root known: YES
  lifecycle logs read: 1 (2 records)
    FIXTURE/logs/lifecycle-20260731-000000-000.jsonl  (2 records)

  REAL-SIGNAL LEDGER -- synthetic occurrences EXCLUDED. 2 occurrences / 2 shapes / 2 rules.
  ruleId                                       fired_count  distinct_shapes source_split                                   verdict_distribution     fixed_next_turn_rate persistence_rate
  PSAvoidUsingCmdletAliases                    1            1               canonical-checkout=0 other-genuine=1           (none)                   25 pct (n=4)         75 pct (n=4)
  PSUseApprovedVerbs                           1            1               canonical-checkout=0 other-genuine=1           (none)                   75 pct (n=4)         25 pct (n=4)

  SYNTHETIC (test-harness / Pester captures) -- reported separately, NEVER folded into the figures above: 0 occurrences / 0 shapes / 0 rules.
'@
            $root = Join-Path $TestDrive ('golden-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            $lcDir = Join-Path $root 'logs'
            # The UNSTAMPED fixture -- exactly what the pre-000209 world wrote.
            Write-Utf8NoBom -Path (Join-Path $lcDir 'lifecycle-20260731-000000-000.jsonl') -Lines @(
                (New-VersionedLifecycleLine -RuleId 'PSUseApprovedVerbs' -Version $null -Cleared 3 -StillPresent 1)
                (New-VersionedLifecycleLine -RuleId 'PSAvoidUsingCmdletAliases' -Version $null -Cleared 1 -StillPresent 3)
            )
            $search = Resolve-LifecycleLogSearch -LifecyclePath $lcDir
            $lifecycle = Read-LifecycleLog -LogPaths @($search.Paths) -Search $search
            $occ = @(
                [pscustomobject]@{ ruleId = 'PSUseApprovedVerbs'; bucket = 'other-genuine'; hash = 'c1' }
                [pscustomobject]@{ ruleId = 'PSAvoidUsingCmdletAliases'; bucket = 'other-genuine'; hash = 'c2' }
            )
            $ledger = Get-RuleEfficacyLedger -Occurrences $occ -Annotations @{} -Lifecycle $lifecycle
            # No MeasuredAtUtc property, so the vintage block does not render and the output is
            # deterministic -- the golden pins the FACTS, not a clock.
            $ledgerInput = [pscustomobject]@{ LogsRead = @([pscustomobject]@{ LogPath = 'FIXTURE/diagnostics.jsonl'; Records = 2 }) }
            $rendered = Format-RuleEfficacyLedger -Ledger $ledger -Lifecycle $lifecycle -LedgerInput $ledgerInput `
                -Sources ([pscustomobject]@{ Discovery = 'FIXED FIXTURE'; VersionDirs = @() }) -Attribution $null
            $norm = (($rendered -replace [regex]::Escape($root), 'FIXTURE') -replace '\\', '/')

            # Strip ONLY the added provenance block. Everything else must survive verbatim.
            $newMarkers = @('clearance provenance floor:', 'version-attributable records:',
                'versions present, earliest first:', 'record\(s\) carry no usable plugin version',
                'stamp \(or the emit site could not resolve a version\)', 'is NOT recoverable',
                'a KNOWN, BOUNDED gap:', 'never attributed to a version')
            $kept = @(@($norm -split "`r?`n") | Where-Object {
                    $line = $_
                    -not (@($newMarkers | Where-Object { $line -match $_ }).Count -gt 0)
                })
            ($kept -join "`n") | Should -BeExactly (($golden -split "`r?`n") -join "`n")

            # ...and the block really WAS added, so the strip above is not silently a no-op.
            $norm | Should -Match 'clearance provenance floor:'
            @($norm -split "`r?`n").Count | Should -BeGreaterThan @($kept).Count
        }

        It 'stamping moves NO rate: identical events render identical figures stamped or not' {
            # The golden proves the pre-change LINES survive. This proves the NUMBERS do, on a
            # fixture where the only variable is the presence of the field.
            $unstamped = Read-LifecycleFixture -Lines @(
                (New-VersionedLifecycleLine -RuleId 'PSUseApprovedVerbs' -Version $null -Cleared 3 -StillPresent 1))
            $stamped = Read-LifecycleFixture -Lines @(
                (New-VersionedLifecycleLine -RuleId 'PSUseApprovedVerbs' -Version '1.29.1' -Cleared 3 -StillPresent 1))
            $a = Get-LifecycleRates -ByRule $unstamped.ByRule -Present $true -RuleId 'PSUseApprovedVerbs'
            $b = Get-LifecycleRates -ByRule $stamped.ByRule -Present $true -RuleId 'PSUseApprovedVerbs'
            [double]$a.fixed | Should -Be ([double]$b.fixed)
            [double]$a.persistence | Should -Be ([double]$b.persistence)
            [int]$a.events | Should -Be ([int]$b.events)
            [int]$a.events | Should -Be 4
        }
    }

    Context 'the bounded-gap caveat prints ONLY when a gap exists (open question 3)' {
        BeforeAll {
            function script:Get-LedgerReadout {
                # Drive the SHIPPED entry point end to end -- this is what a user actually sees.
                param([string[]] $LifecycleLines)
                $dir = Join-Path $TestDrive ('q3-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
                $log = Join-Path $dir 'diagnostics.jsonl'
                Write-Utf8NoBom -Path $log -Lines @((New-CaptureLine -RuleId 'PSUseApprovedVerbs' -File $script:FileOther -Hash 'c1'))
                $lcDir = Join-Path $dir 'logs'
                Write-Utf8NoBom -Path (Join-Path $lcDir 'lifecycle-20260731-000000-000.jsonl') -Lines $LifecycleLines
                return ((& $script:HostExe -NoLogo -NoProfile -File $script:LedgerScript -Path $log -LifecyclePath $lcDir) -join "`n")
            }
        }

        It 'an ALL-ATTRIBUTABLE ledger prints the floor and NO now-irrelevant caveat' {
            # The chosen reading: a clean ledger reads clean. A caveat that recites an empty gap on
            # every run trains its reader to skip the section that matters after the next change.
            $out = Get-LedgerReadout -LifecycleLines @(
                (New-VersionedLifecycleLine -RuleId 'PSUseApprovedVerbs' -Version '1.29.0' -Cleared 3 -StillPresent 1)
                (New-VersionedLifecycleLine -RuleId 'PSUseApprovedVerbs' -Version '1.29.1' -Cleared 1 -StillPresent 0))
            $out | Should -Match 'clearance provenance floor: v1\.29\.0'
            $out | Should -Match 'pre-floor \(bounded gap\): 0'
            $out | Should -Not -Match 'carry no usable plugin version'
            $out | Should -Not -Match 'KNOWN, BOUNDED gap'
        }

        It 'the printed floor states its WINDOW-RELATIVE meaning (dispatch 000216)' {
            # The meaning was real from the first line of this block -- the same rolling-family
            # trim the floor has always been subject to -- but it lived only in a source comment,
            # where the reader quoting the number never saw it. Read as "the earliest release this
            # plugin ever had data for", the floor is a claim about history; what it actually
            # names is the earliest attributable release among the RETAINED records, and it rises
            # as Invoke-LogSweep trims the family. Asserted on the RENDERED readout from the
            # shipped entry point, not on the source text.
            $out = Get-LedgerReadout -LifecycleLines @(
                (New-VersionedLifecycleLine -RuleId 'PSUseApprovedVerbs' -Version '1.29.0' -Cleared 3 -StillPresent 1)
                (New-VersionedLifecycleLine -RuleId 'PSUseApprovedVerbs' -Version '1.29.1' -Cleared 1 -StillPresent 0))
            $out | Should -Match 'clearance provenance floor: v1\.29\.0'
            $out | Should -Match 'WINDOW-RELATIVE'
            $out | Should -Match 'STILL RETAINED'
            $out | Should -Match 'Invoke-LogSweep'
            $out | Should -Match 'keepLastN'
            $out | Should -Match 'RISES as older records age out'
        }

        It 'the window-relative note qualifies a FLOOR -- it does not print when none is named' {
            # The paired control. Printed in both states, the assertion above would pass for the
            # wrong reason, and the readout would carry a caveat about a value it never named.
            $out = Get-LedgerReadout -LifecycleLines @(
                (New-VersionedLifecycleLine -RuleId 'PSUseApprovedVerbs' -Version $null -Cleared 3 -StillPresent 1))
            $out | Should -Match 'clearance provenance floor: \(none -- no version-attributable record\)'
            $out | Should -Not -Match 'WINDOW-RELATIVE'
        }

        It 'a ledger WITH pre-floor records prints the caveat, naming how many' {
            $out = Get-LedgerReadout -LifecycleLines @(
                (New-VersionedLifecycleLine -RuleId 'PSUseApprovedVerbs' -Version $null -Cleared 2 -StillPresent 1)
                (New-VersionedLifecycleLine -RuleId 'PSUseApprovedVerbs' -Version $null -Cleared 1 -StillPresent 0)
                (New-VersionedLifecycleLine -RuleId 'PSUseApprovedVerbs' -Version '1.29.0' -Cleared 3 -StillPresent 1))
            $out | Should -Match 'clearance provenance floor: v1\.29\.0'
            $out | Should -Match 'pre-floor \(bounded gap\): 2'
            $out | Should -Match '2 record\(s\) carry no usable plugin version'
            # The gap is LABELLED, and the records behind it are still COUNTED: 6 cleared + 2 still.
            $out | Should -Match 'n=8'
        }

        It 'a log with NO attributable record at all still names the floor state honestly' {
            $out = Get-LedgerReadout -LifecycleLines @(
                (New-VersionedLifecycleLine -RuleId 'PSUseApprovedVerbs' -Version $null -Cleared 3 -StillPresent 1))
            $out | Should -Match 'clearance provenance floor: \(none -- no version-attributable record\)'
            $out | Should -Match 'carry no usable plugin version'
            # It must NOT invent a floor, and must NOT claim the data is attributable.
            $out | Should -Not -Match 'clearance provenance floor: v'
        }

        It 'an ABSENT lifecycle log prints NO provenance block at all -- there is nothing to floor' {
            $dir = Join-Path $TestDrive ('q3-abs-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            $log = Join-Path $dir 'diagnostics.jsonl'
            Write-Utf8NoBom -Path $log -Lines @((New-CaptureLine -RuleId 'PSUseApprovedVerbs' -File $script:FileOther -Hash 'c1'))
            $out = ((& $script:HostExe -NoLogo -NoProfile -File $script:LedgerScript -Path $log -LifecyclePath (Join-Path $dir 'nope')) -join "`n")
            $out | Should -Match 'lifecycle logs read: NONE'
            $out | Should -Not -Match 'clearance provenance floor'
            $LASTEXITCODE | Should -Be 0
        }
    }
}
