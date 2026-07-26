#Requires -Version 5.1

# Structural guards for the dot-source hazard (dispatch 000156, leg 3).
#
# THE HAZARD. In PowerShell, dot-sourcing is the only way to reuse functions from a .ps1, and
# dot-sourcing executes the ENTIRE file in the CALLER's scope. So any file that is both an entry
# point (has param(), does IO) and a library (exports reusable functions) will, the moment someone
# borrows a function from it, silently rewrite the borrower's own variables. scripts/rule-efficacy-
# ledger.ps1 hit exactly that against scripts/review-dogfood.ps1 and shipped a workaround for it.
#
# Fixing that one pair treats the instance. These two guards close the CLASS, so the next script
# that grows a reusable function cannot reintroduce it:
#
#   G1 -- STRUCTURAL. Parse every file a shipped script dot-sources to obtain functions and refuse
#         a top-level param() block, or any top-level statement that is not a function definition.
#         A bare Set-StrictMode or an $ErrorActionPreference assignment leaks into the caller's
#         scope exactly as a param block does, so the rule is the whole class, not just param().
#
#   G2 -- BEHAVIORAL. Set distinctly-named sentinel variables in a scope, load each library THE WAY
#         CALLERS ACTUALLY LOAD IT, and assert every sentinel survives byte-identical. This encodes
#         the observable defect rather than a proxy for it: G1 could in principle be satisfied by a
#         file that still clobbers a caller, and G2 would still catch it.
#
# BOTH ARE RED-PROVEN against tests/fixtures/lib-purity/, two files built for the purpose. Proving
# a guard by temporarily corrupting a shipped file risks committing the corruption; a permanent
# fixture cannot rot into the product.
#
# THE COVERED SET IS DERIVED FROM THE TREE, never hardcoded. Add a new shared library and dot-source
# it from a shipped script and it is covered automatically; convert one to a module and it leaves
# the set automatically, because a module cannot leak into a caller's scope in the first place.
#
# ASCII-only (PS 5.1 Windows-1252 trap). Run via tests/run-tests.ps1.

BeforeAll {
    $script:LpPluginRoot = Split-Path -Parent $PSScriptRoot
    $script:LpScriptsDir = Join-Path $script:LpPluginRoot 'scripts'
    $script:LpFixtureDir = Join-Path (Join-Path $script:LpPluginRoot 'tests') 'fixtures/lib-purity'

    function Get-LpAst {
        param([Parameter(Mandatory)][string] $FilePath)
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($FilePath, [ref]$null, [ref]$errors)
        if (@($errors).Count -gt 0) { throw ("could not parse " + $FilePath + ": " + (@($errors)[0].Message)) }
        return $ast
    }

    function Get-LpDotSourceTargets {
        # DERIVE the covered set: every file that a shipped script dot-sources. Walks scripts/*.ps1
        # and scripts/lib/* looking for a dot-source PipelineAst, and resolves its argument when it
        # is the shipped shape -- `. (Join-Path <root> 'relative/path.ps1')`. A dot-source whose
        # target cannot be resolved statically is RETURNED AS UNRESOLVED rather than dropped, so an
        # unreadable shape fails loudly instead of shrinking the covered set to nothing.
        param([Parameter(Mandatory)][string] $ScriptsDir)
        $resolved = New-Object System.Collections.Generic.List[string]
        $unresolved = New-Object System.Collections.Generic.List[string]
        $sources = @(Get-ChildItem -LiteralPath $ScriptsDir -Filter *.ps1 -File)
        $libDir = Join-Path $ScriptsDir 'lib'
        if (Test-Path -LiteralPath $libDir) {
            $sources += @(Get-ChildItem -LiteralPath $libDir -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') })
        }
        foreach ($src in $sources) {
            $ast = Get-LpAst -FilePath $src.FullName
            $cmds = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true))
            foreach ($cmd in $cmds) {
                # A dot-source is a CommandAst whose InvocationOperator is Dot. The '.' is the
                # OPERATOR, not a CommandElement -- `. (Join-Path $PSScriptRoot 'lib/x.ps1')` parses
                # to exactly one element, the paren expression. Matching on CommandElements[0] -eq
                # '.' finds nothing at all, which is the failure mode where a guard silently covers
                # an empty set; the vacuity assertion above is what catches that.
                if ($cmd.InvocationOperator -ne [System.Management.Automation.Language.TokenKind]::Dot) { continue }
                $elems = @($cmd.CommandElements)
                if ($elems.Count -lt 1) { continue }
                # `. (Join-Path <something> 'relative/path')`
                $arg = $elems[0]
                $literal = $null
                $inner = $arg
                if ($inner -is [System.Management.Automation.Language.ParenExpressionAst]) {
                    $innerCmd = $inner.Pipeline.PipelineElements[0]
                    if ($innerCmd -is [System.Management.Automation.Language.CommandAst]) {
                        $ie = @($innerCmd.CommandElements)
                        if (([string]$ie[0]) -match '^(?i)join-path$' -and $ie.Count -ge 3) {
                            $tail = $ie[$ie.Count - 1]
                            if ($tail -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                                $literal = [string]$tail.Value
                            }
                        }
                    }
                }
                if ($null -eq $literal) { $unresolved.Add(($src.Name + ': ' + $arg.Extent.Text)); continue }
                # every shipped dot-source is rooted at the scripts dir or the lib dir beside it
                $candidates = @(
                    (Join-Path $ScriptsDir $literal),
                    (Join-Path $libDir $literal)
                )
                $hit = @($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
                if ($hit.Count -ge 1) {
                    $full = (Resolve-Path -LiteralPath $hit[0]).ProviderPath
                    if (-not $resolved.Contains($full)) { $resolved.Add($full) }
                } else {
                    $unresolved.Add(($src.Name + ': ' + $literal))
                }
            }
        }
        # .ToArray() rather than @(): the array subexpression operator throws
        # "Argument types do not match" on a generic List[T].
        return @{ Resolved = $resolved.ToArray(); Unresolved = $unresolved.ToArray() }
    }

    function Get-LpTopLevelImpurities {
        # G1 CORE. Return one record per top-level construct that would execute in a caller's scope.
        # A top-level param() block is reported as its own kind, because it is the rung that can
        # never be legitimate in a dot-sourced library and is therefore never baseline-able.
        param([Parameter(Mandatory)][string] $FilePath)
        $ast = Get-LpAst -FilePath $FilePath
        $out = New-Object System.Collections.Generic.List[object]
        if ($null -ne $ast.ParamBlock) {
            $out.Add([pscustomobject]@{
                    File = [System.IO.Path]::GetFileName($FilePath)
                    Kind = 'ParamBlock'
                    Line = $ast.ParamBlock.Extent.StartLineNumber
                    Text = 'param(...)'
                })
        }
        foreach ($stmt in @($ast.EndBlock.Statements)) {
            if ($stmt -is [System.Management.Automation.Language.FunctionDefinitionAst]) { continue }
            $first = (($stmt.Extent.Text -split "`n")[0]).Trim()
            $collapsed = [regex]::Replace($first, '\s+', ' ')
            $out.Add([pscustomobject]@{
                    File = [System.IO.Path]::GetFileName($FilePath)
                    Kind = $stmt.GetType().Name
                    Line = $stmt.Extent.StartLineNumber
                    Text = $collapsed
                })
        }
        # .ToArray() rather than @(): the array subexpression operator throws "Argument types do not
        # match" on a generic List[T]. No leading comma -- every caller re-wraps in @(), and a comma
        # here would nest the result so an empty list read as a count of one.
        return $out.ToArray()
    }

    # ---------------------------------------------------------------------------------------
    # REGISTERED LEGACY BASELINE.
    #
    # These seven statements predate the guard. They are recorded EXACTLY, by file and by collapsed
    # statement text, so the guard is green on today's tree while any NEW top-level statement in any
    # covered library fails immediately. The list may only SHRINK: an entry that no longer matches
    # anything on disk is itself a failure, so it cannot rot into a permanent excuse.
    #
    # A param() block is NEVER baseline-able. There is no entry for one here and the guard refuses
    # to honor one, because that rung is the defect this dispatch exists to close.
    #
    # WHY EACH ONE IS STILL HERE (dispatch 000156 measured this rather than assuming it):
    #   - the three $PSScriptRoot / cap / pattern statements are constants and are mechanically
    #     convertible to functions; they are left for a scoped follow-up rather than edited inside a
    #     restructuring dispatch that must keep every CLI contract byte-unchanged.
    #   - $script:PluginVersionCache and $script:RuleRationaleCache are MUTABLE lazy caches. A
    #     functions-only file cannot express them at all -- initialize them inside a function and
    #     StrictMode throws on first read. That is not a tidiness problem, it is the pure-lib
    #     contract meeting its own limit, and the honest fix is converting lsp-common.ps1 to a
    #     module (where they become module state that cannot leak). Recorded, not hidden.
    #   - the lsp-scan-common.ps1 dot-source of lsp-common.ps1 is structural and disappears the same
    #     way, when the target becomes a module.
    $script:LpBaseline = @(
        @{ File = 'lsp-common.ps1'; Text = '$script:LspCommonDir = $PSScriptRoot' }
        @{ File = 'lsp-common.ps1'; Text = '$script:PluginVersionCache = $null' }
        @{ File = 'lsp-common.ps1'; Text = '$script:RuleRationaleCache = $null' }
        @{ File = 'lsp-scan-common.ps1'; Text = '$script:LspScanCommonDir = $PSScriptRoot' }
        @{ File = 'lsp-scan-common.ps1'; Text = ". (Join-Path `$script:LspScanCommonDir 'lsp-common.ps1')" }
        @{ File = 'lsp-scan-common.ps1'; Text = '$script:ScanNotAnalyzedNameCap = 50' }
        @{ File = 'security-classifier.ps1'; Text = '$script:PluginComponentPatterns = @(' }
    )

    function Test-LpBaselined {
        param([Parameter(Mandatory)][object] $Impurity)
        if ($Impurity.Kind -eq 'ParamBlock') { return $false }   # never baseline-able
        foreach ($b in $script:LpBaseline) {
            if ($b.File -eq $Impurity.File -and $b.Text -eq $Impurity.Text) { return $true }
        }
        return $false
    }

    function Test-LpSentinelSurvival {
        # G2 CORE. Set distinctly-named sentinels in a scope, dot-source the library into THAT scope
        # exactly as a caller does, and report every sentinel whose value did not survive.
        #
        # The sentinel names are chosen to collide with the parameter names real entry points carry,
        # because that collision IS the defect. $ErrorActionPreference is included as the
        # preference-variable rung. Language strictness has no readable variable to sentinel, so
        # that rung is G1's to catch structurally -- the two guards are complementary by design.
        param([Parameter(Mandatory)][string] $LibraryPath)
        $expected = [ordered]@{
            Path                  = 'LP-SENTINEL-Path-7c31e9'
            Source                = 'LP-SENTINEL-Source-7c31e9'
            AnnotationsPath       = 'LP-SENTINEL-AnnotationsPath-7c31e9'
            Verdict               = 'LP-SENTINEL-Verdict-7c31e9'
            Hash                  = 'LP-SENTINEL-Hash-7c31e9'
            ErrorActionPreference = 'Continue'
        }
        $probe = {
            param($LpTargetPath, $LpExpected)
            $Path = $LpExpected['Path']
            $Source = $LpExpected['Source']
            $AnnotationsPath = $LpExpected['AnnotationsPath']
            $Verdict = $LpExpected['Verdict']
            $Hash = $LpExpected['Hash']
            $ErrorActionPreference = $LpExpected['ErrorActionPreference']
            . $LpTargetPath
            return [ordered]@{
                Path                  = $Path
                Source                = $Source
                AnnotationsPath       = $AnnotationsPath
                Verdict               = $Verdict
                Hash                  = $Hash
                ErrorActionPreference = $ErrorActionPreference
            }
        }
        $actual = & $probe $LibraryPath $expected
        $damaged = New-Object System.Collections.Generic.List[object]
        foreach ($k in $expected.Keys) {
            if ([string]$actual[$k] -ne [string]$expected[$k]) {
                $damaged.Add([pscustomobject]@{
                        Sentinel = $k
                        Expected = [string]$expected[$k]
                        Actual   = [string]$actual[$k]
                    })
            }
        }
        return @{ Damaged = $damaged.ToArray(); Actual = $actual }
    }
}

Describe 'G1 -- AST purity of every dot-sourced shared library (dispatch 000156)' {

    BeforeAll {
        $script:LpTargets = Get-LpDotSourceTargets -ScriptsDir $script:LpScriptsDir
    }

    It 'derives a NON-EMPTY covered set from the tree (vacuity guard)' {
        # Without this, a bug that resolved zero targets would make every purity assertion below
        # pass over nothing at all -- the failure mode where a guard reports green because it
        # checked nothing.
        @($script:LpTargets.Resolved).Count | Should -BeGreaterThan 0 `
            -Because 'shipped scripts demonstrably dot-source shared libraries'
    }

    It 'resolves EVERY dot-source it found (an unreadable shape never silently shrinks the set)' {
        $u = @($script:LpTargets.Unresolved)
        $u.Count | Should -Be 0 -Because ("these dot-sources could not be resolved to a file: " + ($u -join '; '))
    }

    It 'covers the shared libraries that shipped scripts actually dot-source' {
        $names = @($script:LpTargets.Resolved | ForEach-Object { [System.IO.Path]::GetFileName($_) } | Sort-Object -Unique)
        $names | Should -Contain 'lsp-common.ps1'
        $names | Should -Contain 'lsp-scan-common.ps1'
        $names | Should -Contain 'security-classifier.ps1'
        $names | Should -Contain 'serve-shim-common.ps1'
    }

    It 'NO covered library carries a top-level param() block' {
        # THE INVARIANT, asserted mechanically. This rung has no baseline and never will.
        $offenders = @()
        foreach ($t in @($script:LpTargets.Resolved)) {
            $offenders += @(Get-LpTopLevelImpurities -FilePath $t | Where-Object { $_.Kind -eq 'ParamBlock' })
        }
        $offenders.Count | Should -Be 0 -Because (
            "a dot-sourced library with a param() block rewrites its caller's variables: " +
            (@($offenders | ForEach-Object { $_.File }) -join ', '))
    }

    It 'NO covered library has an UNREGISTERED top-level statement' {
        $offenders = @()
        foreach ($t in @($script:LpTargets.Resolved)) {
            $offenders += @(Get-LpTopLevelImpurities -FilePath $t | Where-Object { -not (Test-LpBaselined $_) })
        }
        $rendered = @($offenders | ForEach-Object { $_.File + ':' + $_.Line + ' [' + $_.Kind + '] ' + $_.Text })
        $offenders.Count | Should -Be 0 -Because (
            "a top-level statement in a dot-sourced file executes in the caller's scope: " + ($rendered -join ' | '))
    }

    It 'every BASELINE entry still matches something on disk (the list may only shrink)' {
        # Stops the baseline rotting into a permanent excuse: once a legacy statement is cleaned up,
        # its entry must be deleted, and forgetting to delete it fails here.
        $live = @()
        foreach ($t in @($script:LpTargets.Resolved)) { $live += @(Get-LpTopLevelImpurities -FilePath $t) }
        $stale = @()
        foreach ($b in $script:LpBaseline) {
            $hit = @($live | Where-Object { $_.File -eq $b.File -and $_.Text -eq $b.Text })
            if ($hit.Count -eq 0) { $stale += ($b.File + ' :: ' + $b.Text) }
        }
        $stale.Count | Should -Be 0 -Because ("these baseline entries no longer match; delete them: " + ($stale -join ' | '))
    }

    Context 'RED-PROOF against a purpose-built impure fixture' {

        It 'FLAGS the param-block fixture (and refuses to baseline it)' {
            $f = Join-Path $script:LpFixtureDir 'impure-param.ps1'
            Test-Path -LiteralPath $f | Should -BeTrue -Because 'the fixture must exist for this proof to mean anything'
            $found = @(Get-LpTopLevelImpurities -FilePath $f)
            @($found | Where-Object { $_.Kind -eq 'ParamBlock' }).Count | Should -Be 1
            # and the baseline cannot be used to excuse it, even if someone added an entry
            foreach ($i in @($found | Where-Object { $_.Kind -eq 'ParamBlock' })) {
                (Test-LpBaselined $i) | Should -BeFalse -Because 'a param block is never baseline-able'
            }
        }

        It 'FLAGS the statement fixture on every rung of the class, not just param()' {
            $f = Join-Path $script:LpFixtureDir 'impure-statements.ps1'
            Test-Path -LiteralPath $f | Should -BeTrue
            $found = @(Get-LpTopLevelImpurities -FilePath $f)
            # four deliberate rungs: preference variable, bare cmdlet, plain assignment, side effect
            $found.Count | Should -BeGreaterOrEqual 4 -Because 'the fixture encodes four distinct rungs'
            @($found | Where-Object { $_.Text -match 'ErrorActionPreference' }).Count | Should -BeGreaterThan 0
            @($found | Where-Object { $_.Text -match 'Set-StrictMode' }).Count | Should -BeGreaterThan 0
            @($found | Where-Object { -not (Test-LpBaselined $_) }).Count | Should -Be @($found).Count `
                -Because 'none of the fixture rungs is registered, so all must be reported'
        }

        It 'PASSES a pure library (the guard is not simply always-red)' {
            # serve-shim-common.ps1 is the shipped library that already contains function definitions
            # and nothing else. If the guard flagged it too, the RED proofs above would be worthless.
            $pure = Join-Path (Join-Path $script:LpScriptsDir 'lib') 'serve-shim-common.ps1'
            Test-Path -LiteralPath $pure | Should -BeTrue
            @(Get-LpTopLevelImpurities -FilePath $pure).Count | Should -Be 0
        }
    }
}

Describe 'G2 -- behavioral sentinel survival across a real dot-source (dispatch 000156)' {

    BeforeAll {
        $script:LpTargets2 = (Get-LpDotSourceTargets -ScriptsDir (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts'))
    }

    It 'has a non-empty covered set (vacuity guard)' {
        @($script:LpTargets2.Resolved).Count | Should -BeGreaterThan 0
    }

    It 'every covered library leaves ALL caller sentinels byte-identical' {
        $damage = @()
        foreach ($t in @($script:LpTargets2.Resolved)) {
            $r = Test-LpSentinelSurvival -LibraryPath $t
            foreach ($d in @($r.Damaged)) {
                $damage += ([System.IO.Path]::GetFileName($t) + ' clobbered $' + $d.Sentinel +
                    " ('" + $d.Expected + "' -> '" + $d.Actual + "')")
            }
        }
        $damage.Count | Should -Be 0 -Because ("dot-sourcing must not write the caller's scope: " + ($damage -join ' | '))
    }

    Context 'RED-PROOF against a purpose-built impure fixture' {

        It 'DETECTS every sentinel the param-block fixture clobbers' {
            $f = Join-Path $script:LpFixtureDir 'impure-param.ps1'
            $r = Test-LpSentinelSurvival -LibraryPath $f
            # the fixture declares five parameters matching five sentinels
            @($r.Damaged).Count | Should -Be 5 -Because 'the fixture param block resets exactly five caller variables'
            @($r.Damaged | ForEach-Object { $_.Sentinel } | Sort-Object) -join ',' |
                Should -BeExactly 'AnnotationsPath,Hash,Path,Source,Verdict'
            foreach ($d in @($r.Damaged)) {
                $d.Actual | Should -BeExactly 'CLOBBERED-BY-PARAM-BLOCK'
            }
        }

        It 'DETECTS the preference-variable rung the statement fixture changes' {
            $f = Join-Path $script:LpFixtureDir 'impure-statements.ps1'
            $r = Test-LpSentinelSurvival -LibraryPath $f
            @($r.Damaged | Where-Object { $_.Sentinel -eq 'ErrorActionPreference' }).Count | Should -Be 1
            $r.Actual['ErrorActionPreference'] | Should -BeExactly 'SilentlyContinue'
        }

        It 'reports NO damage for a pure library (the guard is not simply always-red)' {
            $pure = Join-Path (Join-Path $script:LpScriptsDir 'lib') 'serve-shim-common.ps1'
            $r = Test-LpSentinelSurvival -LibraryPath $pure
            @($r.Damaged).Count | Should -Be 0
        }
    }
}
