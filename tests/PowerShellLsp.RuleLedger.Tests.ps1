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

    It 'carries EXACTLY the four reader-side columns -- no cleared-derived column leaked in' {
        # The two survey columns that need persistence the plugin does not have
        # (fixed_next_turn_rate / persistence_rate) must be structurally absent, not zero-filled:
        # a zero would read as "measured and found to be none", which would be a fabricated fact.
        $names = @($script:FxRows['PSUseApprovedVerbs'].PSObject.Properties.Name |
                Where-Object { -not $_.StartsWith('_') })
        $names | Should -Be @('ruleId', 'fired_count', 'distinct_shapes', 'source_split', 'verdict_distribution')
        $names | Should -Not -Contain 'fixed_next_turn_rate'
        $names | Should -Not -Contain 'persistence_rate'
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

    It 'agrees with review-dogfood.ps1 Get-DogfoodSourceSplit on identical input' {
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
        $split = Get-DogfoodSourceSplit -Records $records

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
