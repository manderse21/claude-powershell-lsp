#Requires -Version 5.1

# G3 -- the scalar-.Count ratchet (dispatch 000157, leg 3).
#
# THE HAZARD. Under Windows PowerShell 5.1 a pipeline that yields exactly ONE object IS that
# object -- a scalar -- and a scalar has no .Count. Reading `.Count` off it gives $null, or throws
# under StrictMode. pwsh 7 wraps the single object first and returns 1. So the same assertion is
# green on pwsh and red on 5.1, and only when a fixture happens to yield one element. CI run
# 30183490005 is the live instance: three legs green, windows-powershell red, on
#   ($found | Where-Object { $_.Text -match 'ErrorActionPreference' }).Count | Should -BeGreaterThan 0
# The rule is already banked in DEV_NOTES and the offending file already applied it correctly
# elsewhere -- so this is not a knowledge gap, it is a lapse, and lore cannot close a lapse.
#
# WHY A RATCHET AND NOT A CLEAN GUARD. A guard that must be green before it can ship makes a
# repo-wide fix its entry price, which is how guards get scoped out and never land. This one
# carries a BASELINE and fails only on NEW instances, so it lands now and the legacy burns down on
# its own schedule.
#
# THE SCOPE IS NARROW ON PURPOSE, AND THE NARROWING WAS MEASURED (000157 leg 2). This repo holds a
# 0%-false-positive standard, so the guard flags exactly ONE shape:
#
#   FLAGGED     `(<pipeline>).Count` -- a parenthesised pipeline of two or more elements.
#               Sound: a pipeline's output is subject to unrolling, so it can always be a scalar,
#               and reading .Count off a single flowed object gives that object's own Count (or
#               $null), never the number of results. Both intents are wrong.
#
#   ALLOWLISTED `(<pipeline> | Measure-Object).Count`. Measure-Object emits ONE GenericMeasureInfo
#               whose .Count is a real property; the idiom is correct and common. Flagging it would
#               be a false positive, so the terminal command is checked.
#
#   NOT ATTEMPTED, each for a measured reason:
#     `(<command>).Count`   -- 13 instances in this repo. NOT sound: 1 of the 13 is a measured
#                              false positive (Read-DogfoodAnnotations returns a HASHTABLE, whose
#                              .Count is a real property that reads 0 correctly on 5.1). 12 of 13
#                              are genuine, but a rule that is wrong 1 time in 13 does not meet the
#                              0%-FP bar, so the whole shape is left out and recorded as a finding.
#     `$var.Count`          -- 269 instances. Deciding it needs dataflow; a file-scoped
#                              approximation classified 155 as provably array-assigned and left 114
#                              unresolved. `$definitelyAnArray.Count` is correct and common.
#     `(<expr>).Count`, chained member access, index -- 15 instances, same reason as `$var.Count`.
#
# A PSScriptAnalyzer-style owned finder for this class is deliberately NOT here: it must first be
# measured against the 281-file oracle (the 000139 discipline), which is its own dispatch.
#
# BASELINE IS EMPTY, and that is a measurement rather than an aspiration -- leg 2 swept all 146
# PowerShell files in the tree and found exactly 2 in-scope instances, both of them the CI failure,
# both fixed by leg 1. The baseline MECHANISM still ships and is proven, because the value of a
# ratchet is that the next instance cannot land silently.
#
# RED-PROVEN against tests/fixtures/scalar-count/, two files built for the purpose. Proving a guard
# by temporarily corrupting a shipped file risks committing the corruption.
#
# ASCII-only (PS 5.1 Windows-1252 trap). Run via tests/run-tests.ps1.

BeforeAll {
    $script:ScPluginRoot = Split-Path -Parent $PSScriptRoot
    $script:ScFixtureDir = Join-Path (Join-Path $script:ScPluginRoot 'tests') 'fixtures/scalar-count'

    # The ratchet's baseline. Same shape and same exact-match discipline as G1's $script:LpBaseline
    # in PowerShellLsp.LibPurity.Tests.ps1 -- one mechanism for the repo, not two. Entries are
    # matched by file and collapsed statement text, never by line number, so unrelated edits above
    # them do not rot the list.
    $script:ScBaseline = @()

    function Test-ScBaselined {
        # $Baseline is a parameter rather than a direct $script: read (G1's helper reads its list
        # directly) for one reason: the RED proof must be able to demonstrate that a baselined hit
        # is excused, and the only honest way to show that with an EMPTY shipped baseline is to
        # hand the helper a purpose-built one. The shipped path still defaults to the real list.
        param(
            [Parameter(Mandatory)][object] $Hit,
            [AllowEmptyCollection()][object[]] $Baseline = $script:ScBaseline
        )
        foreach ($b in $Baseline) {
            if ($b.File -eq $Hit.File -and $b.Text -eq $Hit.Text) { return $true }
        }
        return $false
    }

    function Get-ScScannedFile {
        # FULL ENUMERATION of the tree -- deliberately NOT a convention-shaped glob such as
        # scripts/*.ps1 + tests/*.ps1, which silently misses whatever does not match the
        # convention. Walk everything, then filter by extension.
        #
        # Three exclusions, each narrow and each with a reason:
        #   .git/                        -- internals, not source
        #   worktrees/                   -- nested checkouts of THIS repo; scanning them would
        #                                   double-count every file and read another branch's code
        #                                   as if it were this one. (Absent in CI, present locally.)
        #   tests/fixtures/scalar-count/ -- this guard's own deliberately-broken proof material.
        #                                   Without this the guard is permanently red on itself.
        $root = $script:ScPluginRoot
        $sink = New-Object 'System.Collections.Generic.List[object]'
        foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue)) {
            if ($f.Extension -ine '.ps1' -and $f.Extension -ine '.psm1') { continue }
            $rel = $f.FullName.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
            if ($rel -match '^\.git(/|$)') { continue }
            if ($rel -match '^worktrees(/|$)') { continue }
            if ($rel -match '^tests/fixtures/scalar-count(/|$)') { continue }
            $sink.Add([pscustomobject]@{ Full = $f.FullName; Rel = $rel })
        }
        # Emit the array normally rather than `return , $array`. Every caller wraps the call in
        # @(), and the comma form would hand @() a single object that IS an array -- which nests
        # instead of enumerating. Plain emission is correct for 0, 1 and many.
        return $sink.ToArray()
    }

    function Add-ScUnwrappedCount {
        # Appends every in-scope hit in one file to $Sink.
        #
        # Results are written into a caller-supplied List rather than returned, because a function
        # that returns a collection is unrolled on the way out and an empty result then collapses
        # to nothing -- which is a cousin of the very trap this guard exists to catch. Writing to a
        # sink sidesteps it entirely.
        param(
            [Parameter(Mandatory)][string] $FilePath,
            [Parameter(Mandatory)][string] $Rel,
            [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]] $Sink
        )

        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($FilePath, [ref]$tokens, [ref]$errors)
        if ($null -eq $ast) { return }

        # MemberExpressionAst covers property access. InvokeMemberExpressionAst derives from it and
        # is a METHOD call -- excluded, because .Count() is not the shape in question.
        $members = @($ast.FindAll({
            param($n)
            ($n -is [System.Management.Automation.Language.MemberExpressionAst]) -and
            (-not ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst]))
        }, $true))

        foreach ($m in $members) {
            $name = $m.Member -as [System.Management.Automation.Language.StringConstantExpressionAst]
            if ($null -eq $name) { continue }            # $obj.$dynamicName -- unknowable
            if ($name.Value -ine 'Count') { continue }

            $target = $m.Expression
            if (-not ($target -is [System.Management.Automation.Language.ParenExpressionAst])) { continue }

            $pipe = $target.Pipeline -as [System.Management.Automation.Language.PipelineAst]
            if ($null -eq $pipe) { continue }

            $elems = @($pipe.PipelineElements)
            if ($elems.Count -lt 2) { continue }         # ( <expr> ).Count / ( <command> ).Count -- not attempted

            $last = $elems[$elems.Count - 1]
            if ($last -is [System.Management.Automation.Language.CommandAst]) {
                $lastName = [string]$last.GetCommandName()
                if ($lastName -imatch '^(Measure-Object|measure)$') { continue }   # allowlisted, real .Count
            }

            $Sink.Add([pscustomobject]@{
                File = $Rel
                Line = $m.Extent.StartLineNumber
                Text = ($m.Extent.Text -replace '\s+', ' ').Trim()
            })
        }
    }

    function Get-ScMeasureTerminalCount {
        # Counts the ALLOWLISTED shape structurally -- `(<pipeline> | Measure-Object).Count` as an
        # actual member access, not as text. A textual probe here would also match the fixture's own
        # header comment, which documents the idiom, and would then be asserting prose rather than
        # code.
        param([Parameter(Mandatory)][string] $FilePath)
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($FilePath, [ref]$tokens, [ref]$errors)
        if ($null -eq $ast) { return 0 }
        $n = 0
        foreach ($m in @($ast.FindAll({
            param($x)
            ($x -is [System.Management.Automation.Language.MemberExpressionAst]) -and
            (-not ($x -is [System.Management.Automation.Language.InvokeMemberExpressionAst]))
        }, $true))) {
            $nm = $m.Member -as [System.Management.Automation.Language.StringConstantExpressionAst]
            if ($null -eq $nm -or $nm.Value -ine 'Count') { continue }
            if (-not ($m.Expression -is [System.Management.Automation.Language.ParenExpressionAst])) { continue }
            $p = $m.Expression.Pipeline -as [System.Management.Automation.Language.PipelineAst]
            if ($null -eq $p) { continue }
            $el = @($p.PipelineElements)
            if ($el.Count -lt 2) { continue }
            $last = $el[$el.Count - 1]
            if (-not ($last -is [System.Management.Automation.Language.CommandAst])) { continue }
            if ([string]$last.GetCommandName() -imatch '^(Measure-Object|measure)$') { $n++ }
        }
        return $n
    }

    function Get-ScHitsForFile {
        param([Parameter(Mandatory)][string] $FilePath, [string] $Rel = 'fixture')
        $sink = New-Object 'System.Collections.Generic.List[object]'
        Add-ScUnwrappedCount -FilePath $FilePath -Rel $Rel -Sink $sink
        return $sink.ToArray()
    }
}

Describe 'G3 -- the scalar-.Count ratchet (dispatch 000157)' {

    BeforeAll {
        $script:ScFiles = @(Get-ScScannedFile)
        $script:ScHits = New-Object 'System.Collections.Generic.List[object]'
        foreach ($f in $script:ScFiles) {
            Add-ScUnwrappedCount -FilePath $f.Full -Rel $f.Rel -Sink $script:ScHits
        }
    }

    It 'derives a NON-EMPTY covered set (a derivation bug must not read as green)' {
        # 000156 leg 3's own lesson, applied: its first guard matched the dot-source operator the
        # wrong way, the covered set resolved to ZERO files, and two purity assertions passed over
        # nothing while reading green. Every assertion below is worthless if this one is.
        @($script:ScFiles).Count | Should -BeGreaterThan 50 -Because 'this repo has well over 50 PowerShell files; a smaller number means the walk broke'
        @($script:ScFiles | Where-Object { $_.Rel -eq 'scripts/lib/lsp-common.ps1' }).Count | Should -Be 1 -Because 'a known shipped library must be in the scanned set'
        @($script:ScFiles | Where-Object { $_.Rel -eq 'tests/PowerShellLsp.LibPurity.Tests.ps1' }).Count | Should -Be 1 -Because 'the file this dispatch repaired must be in the scanned set'
    }

    It 'EXCLUDES its own proof fixtures from the scan (or the guard is permanently red on itself)' {
        @($script:ScFiles | Where-Object { $_.Rel -match '^tests/fixtures/scalar-count/' }).Count |
            Should -Be 0 -Because 'the deliberately-broken fixtures must not be scanned as product code'
        # ...and the exclusion must be exactly that narrow: every OTHER fixture is still scanned.
        @($script:ScFiles | Where-Object { $_.Rel -match '^tests/fixtures/lib-purity/' }).Count |
            Should -BeGreaterThan 0 -Because 'the exclusion covers only these fixtures, not every fixture directory'
    }

    It 'no NEW unwrapped pipeline .Count anywhere in the repo (THE RATCHET)' {
        $offenders = @($script:ScHits | Where-Object { -not (Test-ScBaselined -Hit $_) })
        $rendered = @($offenders | ForEach-Object { $_.File + ':' + $_.Line + ' ' + $_.Text })
        @($offenders).Count | Should -Be 0 -Because (
            "a parenthesised pipeline yielding one object is a scalar on Windows PowerShell 5.1 and has no .Count -- " +
            "wrap it in @(): " + ($rendered -join ' | '))
    }

    It 'every BASELINE entry still matches something on disk (the list may only shrink)' {
        # Ships empty today, so this is deliberately a no-op NOW and load-bearing the moment anyone
        # adds an entry: a fixed instance whose baseline row was not deleted fails here, which is
        # what stops the baseline rotting into a permanent excuse.
        $stale = @()
        foreach ($b in $script:ScBaseline) {
            $hit = @($script:ScHits | Where-Object { $_.File -eq $b.File -and $_.Text -eq $b.Text })
            if (@($hit).Count -eq 0) { $stale += ($b.File + ' :: ' + $b.Text) }
        }
        @($stale).Count | Should -Be 0 -Because ("these baseline entries no longer match; delete them: " + ($stale -join ' | '))
    }

    Context 'RED-PROOF against purpose-built fixtures' {

        It 'FLAGS a NEW unwrapped instance (the guard is not always-green)' {
            $f = Join-Path $script:ScFixtureDir 'unwrapped.ps1'
            Test-Path -LiteralPath $f | Should -BeTrue -Because 'the fixture must exist for this proof to mean anything'
            $hits = @(Get-ScHitsForFile -FilePath $f -Rel 'fixture/unwrapped.ps1')
            @($hits).Count | Should -Be 2 -Because 'the fixture encodes exactly two unwrapped pipeline rungs'
            @($hits | Where-Object { $_.Text -match 'ErrorActionPreference' }).Count |
                Should -Be 1 -Because 'the verbatim shape that failed CI run 30183490005 must be caught'
        }

        It 'a BASELINED instance PASSES (the ratchet excuses recorded legacy)' {
            $f = Join-Path $script:ScFixtureDir 'unwrapped.ps1'
            $hits = @(Get-ScHitsForFile -FilePath $f -Rel 'fixture/unwrapped.ps1')
            @($hits).Count | Should -BeGreaterThan 0 -Because 'this proof is vacuous if nothing was flagged'
            $pretend = @($hits | ForEach-Object { @{ File = $_.File; Text = $_.Text } })
            $remaining = @($hits | Where-Object { -not (Test-ScBaselined -Hit $_ -Baseline $pretend) })
            @($remaining).Count | Should -Be 0 -Because 'every hit recorded in the baseline must be excused'
        }

        It 'a baseline entry that does NOT match leaves the hit flagged (the excuse is exact, not blanket)' {
            $f = Join-Path $script:ScFixtureDir 'unwrapped.ps1'
            $hits = @(Get-ScHitsForFile -FilePath $f -Rel 'fixture/unwrapped.ps1')
            $wrong = @(@{ File = 'fixture/unwrapped.ps1'; Text = '($nothing | Where-Object { $_ }).Count' })
            $remaining = @($hits | Where-Object { -not (Test-ScBaselined -Hit $_ -Baseline $wrong) })
            @($remaining).Count | Should -Be @($hits).Count -Because 'a near-miss baseline row must excuse nothing'
        }

        It 'PASSES correctly-wrapped @() forms (the guard is not always-red)' {
            $f = Join-Path $script:ScFixtureDir 'wrapped.ps1'
            Test-Path -LiteralPath $f | Should -BeTrue
            @(Get-ScHitsForFile -FilePath $f -Rel 'fixture/wrapped.ps1').Count |
                Should -Be 0 -Because 'every form in this fixture is correct on 5.1 and none may be flagged'
        }

        It 'does NOT flag the (pipeline | Measure-Object).Count idiom (the one allowlisted terminal)' {
            # Proven rather than asserted: the wrapped fixture carries two Measure-Object terminals,
            # and the previous It requires ZERO hits across that whole file -- so if the allowlist
            # were missing, this file would report 2 and both tests would fail together.
            $f = Join-Path $script:ScFixtureDir 'wrapped.ps1'
            (Get-ScMeasureTerminalCount -FilePath $f) |
                Should -Be 2 -Because 'the fixture must actually contain the idiom this allowlist covers'
            @(Get-ScHitsForFile -FilePath $f -Rel 'fixture/wrapped.ps1').Count | Should -Be 0
        }

        It 'is ASCII-only, both fixtures (PS 5.1 Windows-1252 trap)' {
            foreach ($n in @('unwrapped.ps1', 'wrapped.ps1')) {
                $bytes = [System.IO.File]::ReadAllBytes((Join-Path $script:ScFixtureDir $n))
                (@($bytes | Where-Object { $_ -gt 127 }).Count) | Should -Be 0 -Because ($n + ' must be ASCII-only')
            }
        }
    }
}
