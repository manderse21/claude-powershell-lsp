#Requires -Version 5.1
# Invoke-PluginHook -- ONE definition, and it is the superset every caller needs (dispatch 000292,
# routed debt 2(e); Hub Rule 18).
#
# THE GAP THIS CLOSES. The integration suite drives the plugin's hooks as child processes through
# one helper, Invoke-PluginHook. Until 000292 that helper was defined TEN times inside
# PowerShellLsp.Integration.Tests.ps1 -- once per Describe -- on top of a shared copy in
# Integration.Common.ps1. Measured at the tip by the parser, not by brace matching, the ten were
# FIVE DISTINCT BODIES: six were the shared body once indentation is set aside, one (the
# warm-start block's) had NO $ExtraEnv parameter at all, and three recorded the child's exit code
# under THREE different variable names. The same helper name meant different signatures and
# different side effects in different blocks of one file.
#
# WHAT THE MEASUREMENT FOUND THAT THE DOCUMENTATION DID NOT. The shared copy's header said every
# Describe dot-sourced Integration.Common.ps1 BEFORE defining its local copy, so every local copy
# shadowed the shared one. Two did not: in the 000028 and 000030 blocks the dot-source came AFTER
# the local definition in the same BeforeAll, so the shared copy REPLACED the local one. Those two
# local copies were dead code, and the "unused" shared copy was in force for 12 of the 46 calls --
# harmless only because those two bodies happened to match it.
#
# THE PROPERTY, TESTED BOTH WAYS.
#   1. There is exactly ONE definition under tests/, in Integration.Common.ps1.
#   2. It is the SUPERSET: every call passes only NAMED parameters, and every name any call passes
#      is declared by the shared signature. Asserted over the parser's view of every call, never a
#      text grep: a text grep counts comments too, and at the collapse it read 74 "call sites"
#      where the parser finds 46 calls and 28 comments.
#   3. It carries the one behaviour the variants added: the child's exit code in
#      $script:LastHookExit, reset to $null on EVERY call and set only when the child exits on its
#      own -- so a reader can never see an earlier call's code, and a child killed at the cap
#      reads $null rather than a fabricated one.
#
# THE RED CONTROLS ARE THE PRIOR IMPLEMENTATIONS, reconstructed by UNDOING the fix on the SHIPPED
# source -- never by `git show <sha>:<path>`, which exits 128 under CI's shallow checkout, and
# never through a git binary at all, which the container leg does not have. Every substitution
# anchor is asserted to occur EXACTLY ONCE before it is removed, the mutant is proven to have
# LANDED and to still parse, and each control carries an arm that must stay GREEN, so a mutant
# that broke the helper instead of removing the one property cannot be credited as a bite.
#
# The census is the PowerShell parser's AST, so a string in this file that merely contains the
# helper's name is neither a definition nor a call -- the file cannot match itself. The scan root
# is tests/ (this file's own directory): the nested checkouts 000291's guard prunes live under the
# repository root's worktrees/, never under tests/, and if one ever appeared here the
# one-definition arm would fail LOUDLY (it would count two), not pass silently.
#
# The behavioural tests shell out (the helper exists to start child processes). Windows
# PowerShell 5.1 has no Process.Kill(bool), so the helper's kill is a caught no-op there; the
# at-the-cap child is therefore written to exit ON ITS OWN a few seconds later on every host.
#
# ASCII-only (Windows PowerShell 5.1 reads a UTF-8-without-BOM file through Windows-1252).

BeforeAll {
    $script:IH_TestsDir = $PSScriptRoot
    $script:IH_RepoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:IH_RepoRoot 'scripts/lib/lsp-common.ps1')   # Add-ProcessArguments
    . (Join-Path $PSScriptRoot 'Integration.Common.ps1')                # the ONE Invoke-PluginHook
    $script:IH_CommonPath = Join-Path $PSScriptRoot 'Integration.Common.ps1'
    $script:IH_Cr = [string][char]13

    # The contract's parameter union, as every caller passes it (measured at the collapse).
    $script:IH_Union = @('CapMs', 'DataRoot', 'ExtraArgs', 'ExtraEnv', 'ScriptPath', 'StdinJson')

    # Anchors for the capture control: the two lines this change added to the shared body. Matched
    # as whole lines by the statement they carry, so a comment edit does not break the control.
    $script:IH_ResetRx = '(?m)^[ \t]*\$script:LastHookExit = \$null\b[^\n]*\n'
    $script:IH_SetRx = '(?m)^[ \t]*\$script:LastHookExit = \$p\.ExitCode\b[^\n]*\n'

    # The two AST predicates, defined ONCE and used by every walk below.
    $script:IH_IsDef = {
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-PluginHook'
    }
    $script:IH_IsCall = {
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-PluginHook'
    }

    function Get-IHDefinition {
        # The Invoke-PluginHook FunctionDefinitionAst parsed from -Text, or from the shared file.
        param([string] $Text)
        $tok = $null; $errs = $null
        if ($PSBoundParameters.ContainsKey('Text')) {
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tok, [ref]$errs)
        } else {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:IH_CommonPath, [ref]$tok, [ref]$errs)
        }
        $defs = @($ast.FindAll($script:IH_IsDef, $true))
        if ($defs.Count -ne 1) { throw ('expected exactly one Invoke-PluginHook definition, parsed ' + $defs.Count) }
        return $defs[0]
    }

    function Get-IHParamName {
        # The declared parameter names of a FunctionDefinitionAst, from its param() block.
        param([Parameter(Mandatory = $true)] $FunctionAst)
        if ($FunctionAst.Body.ParamBlock) {
            return , @($FunctionAst.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        }
        return , @($FunctionAst.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    }

    function Get-IHCensus {
        # The parser's view of every Invoke-PluginHook DEFINITION and CALL under $Root, plus the
        # census's one blind spot: a file that mentions the name but did not parse cleanly.
        param([Parameter(Mandatory = $true)][string] $Root)
        $defs = @(); $calls = @(); $blind = @(); $files = 0
        foreach ($f in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.ps1' -ErrorAction SilentlyContinue)) {
            $files++
            $tok = $null; $errs = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tok, [ref]$errs)
            if (@($errs).Count -gt 0 -and ([System.IO.File]::ReadAllText($f.FullName)).Contains('Invoke-PluginHook')) {
                $blind += $f.FullName
            }
            foreach ($d in @($ast.FindAll($script:IH_IsDef, $true))) {
                $defs += [pscustomobject]@{ File = $f.FullName; Line = $d.Extent.StartLineNumber }
            }
            foreach ($c in @($ast.FindAll($script:IH_IsCall, $true))) {
                $named = @(); $other = 0
                $e = $c.CommandElements
                for ($i = 1; $i -lt $e.Count; $i++) {
                    $x = $e[$i]
                    if ($x -is [System.Management.Automation.Language.CommandParameterAst]) {
                        $named += $x.ParameterName
                        # every parameter of this helper takes a value: `-Name value` carries it as
                        # the NEXT element, `-Name:value` carries it attached
                        if ($null -eq $x.Argument -and ($i + 1) -lt $e.Count -and
                            -not ($e[$i + 1] -is [System.Management.Automation.Language.CommandParameterAst])) { $i++ }
                    }
                    else { $other++ }   # positional or splatted: either defeats a NAMED superset proof
                }
                $calls += [pscustomobject]@{ File = $f.FullName; Line = $c.Extent.StartLineNumber; Named = $named; Other = $other }
            }
        }
        return [pscustomobject]@{ Files = $files; Blind = $blind; Definitions = $defs; Calls = $calls }
    }

    function Get-IHUndeclared {
        # Every named parameter some call passes that $Declared does not declare, sorted, unique.
        param([string[]] $Declared, [object[]] $Calls)
        $miss = @()
        foreach ($c in @($Calls)) { foreach ($n in @($c.Named)) { if (-not ($Declared -contains $n)) { $miss += $n } } }
        return , @($miss | Sort-Object -Unique)
    }

    function New-IHChild {
        # A throwaway child script under $TestDrive; returns its path.
        param([Parameter(Mandatory = $true)][string] $Name, [Parameter(Mandatory = $true)][string[]] $Lines)
        $p = Join-Path $TestDrive $Name
        [System.IO.File]::WriteAllLines($p, $Lines)
        return $p
    }
}

Describe 'Invoke-PluginHook -- ONE definition, the superset of every caller (routed debt 2(e))' {
    BeforeAll {
        $script:IH_Census = Get-IHCensus -Root $script:IH_TestsDir
    }

    It 'the census READ the suite: a floor on files and calls, and no blind file' {
        # NON-VACUITY FLOOR, asserted before any property: a walk that found nothing would
        # otherwise report zero duplicates and pass.
        $script:IH_Census.Files | Should -BeGreaterThan 30
        $why = '46 calls measured at the collapse (dispatch 000292), plus this file''s own'
        @($script:IH_Census.Calls).Count | Should -BeGreaterOrEqual 40 -Because $why
        $why = 'a file that mentions the helper but did not parse is a census blind spot: ' + (@($script:IH_Census.Blind) -join ', ')
        @($script:IH_Census.Blind).Count | Should -Be 0 -Because $why
    }

    It 'Invoke-PluginHook is defined exactly ONCE under tests/, in Integration.Common.ps1' {
        $defs = @($script:IH_Census.Definitions)
        $where = (@($defs | ForEach-Object { (Split-Path -Leaf $_.File) + ':' + $_.Line }) -join ', ')
        $defs.Count | Should -Be 1 -Because ('a local copy shadows or replaces the shared one; definitions found: ' + $where)
        (Split-Path -Leaf $defs[0].File) | Should -BeExactly 'Integration.Common.ps1'
    }

    It 'IN-BAND CONTROL: the census COUNTS a duplicate -- a synthetic local copy is seen' {
        # Without this arm the count of one above is equally consistent with a census that can
        # only ever see one file. Rebuild the prior shape -- a Describe-local copy beside the
        # shared one -- under $TestDrive and require the SAME census to count both.
        $dir = Join-Path $TestDrive 'dup'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Copy-Item -LiteralPath $script:IH_CommonPath -Destination (Join-Path $dir 'Integration.Common.ps1')
        $local = @(
            'Describe ''prior shape'' {',
            '    BeforeAll {',
            '        function Invoke-PluginHook { param([string]$ScriptPath) return $ScriptPath }',
            '    }',
            '    It ''calls it'' { Invoke-PluginHook -ScriptPath ''x'' }',
            '}'
        )
        [System.IO.File]::WriteAllLines((Join-Path $dir 'Local.Tests.ps1'), $local)
        $c = Get-IHCensus -Root $dir
        @($c.Definitions).Count | Should -Be 2
        @($c.Calls | Where-Object { (Split-Path -Leaf $_.File) -eq 'Local.Tests.ps1' }).Count | Should -Be 1
    }

    It 'every call passes only NAMED parameters (no positional argument, no splat)' {
        $bad = @($script:IH_Census.Calls | Where-Object { $_.Other -gt 0 })
        $where = (@($bad | ForEach-Object { (Split-Path -Leaf $_.File) + ':' + $_.Line }) -join ', ')
        $bad.Count | Should -Be 0 -Because ('a positional or splatted call defeats the named superset proof: ' + $where)
    }

    It 'the shared signature declares every parameter any caller passes -- the SUPERSET' {
        $declared = Get-IHParamName (Get-IHDefinition)
        $miss = Get-IHUndeclared -Declared $declared -Calls $script:IH_Census.Calls
        @($miss).Count | Should -Be 0 -Because ('callers pass parameters the shared helper does not declare: ' + ($miss -join ', '))
        # And the callers' union IS the contract, so the proof is not an empty set trivially fitting.
        $union = @($script:IH_Census.Calls | ForEach-Object { $_.Named } | Sort-Object -Unique)
        $moved = @(Compare-Object -ReferenceObject $script:IH_Union -DifferenceObject $union)
        $moved.Count | Should -Be 0 -Because ('the callers'' parameter union moved: ' + ($union -join ','))
    }

    It 'RED CONTROL: the PRIOR warm-start signature -- no ExtraEnv -- is NOT the superset' {
        # The warm-start block's copy was the one variant with no $ExtraEnv. Reconstruct that
        # signature by UNDOING the fix on the SHIPPED body (anchor count asserted), and require the
        # SAME predicate to name exactly the parameter it lacks. The shipped signature passing the
        # test above is this control's surviving arm.
        $shipped = (Get-IHDefinition).Extent.Text.Replace($script:IH_Cr, '')
        $anchor = ', [hashtable]$ExtraEnv'
        ([regex]::Matches($shipped, [regex]::Escape($anchor))).Count | Should -Be 1 -Because 'anchor count MUST be 1 before the mutation'
        $prior = $shipped.Replace($anchor, '')
        $prior | Should -Not -BeExactly $shipped -Because 'the mutant must have LANDED'
        $priorParams = Get-IHParamName (Get-IHDefinition -Text $prior)
        ($priorParams -contains 'ExtraEnv') | Should -BeFalse
        $miss = Get-IHUndeclared -Declared $priorParams -Calls $script:IH_Census.Calls
        ($miss -join ',') | Should -BeExactly 'ExtraEnv'
    }
}

Describe 'Invoke-PluginHook -- the exit-code contract every caller now shares (dispatch 000292)' {
    It 'records the child exit code in $script:LastHookExit when the child exits on its own' {
        $child = New-IHChild -Name 'exit7.ps1' -Lines @('Write-Output ''hook-out''', 'exit 7')
        $script:LastHookExit = 'STALE'
        $out = Invoke-PluginHook -ScriptPath $child -StdinJson '{}' -ExtraArgs @() -CapMs 30000 -DataRoot $TestDrive
        $out | Should -Match 'hook-out'
        $script:LastHookExit | Should -Be 7
        $script:PslsHookOutcome.Reason | Should -Be 'ok'
        $script:PslsHookOutcome.ExitCode | Should -Be 7
    }

    It 'a child still running at the cap reads $null -- never an earlier call''s code' {
        # The child exits ON ITS OWN a few seconds after the cap, so it cannot outlive the test on
        # a host where the helper's kill is a no-op (Windows PowerShell 5.1: no Process.Kill(bool)).
        $child = New-IHChild -Name 'sleeper.ps1' -Lines @('Start-Sleep -Seconds 6', 'exit 3')
        $script:LastHookExit = 0   # as if an earlier call had succeeded
        $out = Invoke-PluginHook -ScriptPath $child -StdinJson '{}' -ExtraArgs @() -CapMs 1500 -DataRoot $TestDrive
        $out | Should -BeExactly ''
        ($null -eq $script:LastHookExit) | Should -BeTrue -Because 'a killed child has no exit code, and an earlier call''s 0 must not survive'
        $script:PslsHookOutcome.Reason | Should -Be 'killed-at-cap'
    }

    It 'ExtraArgs and ExtraEnv reach the child -- the parameters the warm-start copy could not pass' {
        $child = New-IHChild -Name 'echo.ps1' -Lines @(
            'param([string]$Tag)',
            'Write-Output (''tag='' + $Tag + '';env='' + $env:PSLS_IH_PROBE)',
            'exit 0'
        )
        # Seed a sentinel first: without it, an implementation that never wrote the code would
        # inherit the 0 the previous test seeded and pass this assertion vacuously.
        $script:LastHookExit = 'STALE'
        $out = Invoke-PluginHook -ScriptPath $child -StdinJson '{}' -ExtraArgs @('-Tag', 't1') `
            -ExtraEnv @{ PSLS_IH_PROBE = 'e1' } -CapMs 30000 -DataRoot $TestDrive
        $out | Should -Match 'tag=t1;env=e1'
        $script:LastHookExit | Should -Be 0
    }

    It 'RED CONTROL: the PRIOR shared body -- the fix UNDONE on the shipped source -- never records the exit code' {
        # The prior shared copy (the six-way majority) had no exit-code capture. Reconstruct it by
        # removing exactly the two capture lines from the SHIPPED body, each anchor asserted to
        # occur exactly once, and run it in a child scope so it overrides exactly ONE function and
        # disappears afterwards.
        $shipped = (Get-IHDefinition).Extent.Text.Replace($script:IH_Cr, '')
        ([regex]::Matches($shipped, $script:IH_ResetRx)).Count | Should -Be 1 -Because 'anchor count MUST be 1 before the mutation'
        ([regex]::Matches($shipped, $script:IH_SetRx)).Count | Should -Be 1 -Because 'anchor count MUST be 1 before the mutation'
        $prior = [regex]::Replace([regex]::Replace($shipped, $script:IH_ResetRx, ''), $script:IH_SetRx, '')
        $prior | Should -Not -BeExactly $shipped -Because 'the mutant must have LANDED'
        ([regex]::Matches($prior, 'LastHookExit')).Count | Should -Be 0
        [void](Get-IHDefinition -Text $prior)   # the mutant still parses to exactly one definition

        $child = New-IHChild -Name 'exit7-red.ps1' -Lines @('Write-Output ''hook-out''', 'exit 7')
        $r = & {
            . ([scriptblock]::Create($prior))
            $script:LastHookExit = 'SENTINEL'
            $o = Invoke-PluginHook -ScriptPath $child -StdinJson '{}' -ExtraArgs @() -CapMs 30000 -DataRoot $TestDrive
            [pscustomobject]@{ Out = $o; Exit = $script:LastHookExit; Outcome = $script:PslsHookOutcome }
        }
        # BITES: the prior implementation never wrote the exit code.
        $r.Exit | Should -BeExactly 'SENTINEL'
        # SURVIVING ARM: everything the mutant did not touch is shipped behaviour and must match the
        # shipped run exactly -- output, outcome reason, and the outcome's own exit code.
        $r.Out | Should -Match 'hook-out'
        $r.Outcome.Reason | Should -Be 'ok'
        $r.Outcome.ExitCode | Should -Be 7
    }
}
