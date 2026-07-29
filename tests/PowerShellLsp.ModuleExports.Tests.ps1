#Requires -Version 5.1

# Export-ModuleMember name collection -- the multi-name list fix (dispatch 000159, leg 2).
#
# THE DEFECT, as dispatch 000156 recorded it with a four-form minimal reproducer measured
# against the shipped code. Get-ModuleDefinedFunctionNames collected export names only from
# individual StringConstantExpressionAst command elements. A MULTI-NAME export list parses as
# ONE node in either idiomatic form --
#     Export-ModuleMember -Function 'Get-Alpha', 'Get-Beta'     one ArrayLiteralAst
#     Export-ModuleMember -Function @('Get-Alpha','Get-Beta')   one ArrayExpressionAst
# -- so neither was a StringConstantExpressionAst, both were skipped whole, and the collected
# set stayed EMPTY. The caller reads an empty set as "no explicit Export-ModuleMember" and
# assumes export-all, so every PRIVATE function is then reported as an under-declared export.
#
# Measured live impact before the fix: the plugin's own scripts/lib/dogfood-reader.psm1 drew
# 13 false ManifestConsistency warnings, exactly one per private function (25 defined - 12
# really exported = 13), against a REAL surface of 12 exports.
#
# THE CLASS, NOT THE INSTANCE. -Function and -Cmdlet share one collection path, so -Cmdlet was
# measured to carry the identical defect and is fixed by the same change. -Alias is different
# on purpose: alias names are deliberately NOT folded into the FUNCTION set (the BurntToast
# shape, dispatch 000128 slice 2), and these tests pin that they still are not.
#
# GROUND TRUTH comes from PowerShell itself -- (Get-Module).ExportedFunctions after importing
# the fixture -- never from the parser under test. A parser asserted against itself proves
# nothing.
#
# ASCII-only (PS 5.1 em-dash trap); StrictMode-safe.
#
# Author: Mike Andersen / powershell-lsp plugin.

BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')

    function New-ExportFixture {
        param([string]$Name, [string]$Body)
        $dir = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $p = Join-Path $dir ($Name + '.psm1')
        Set-Content -LiteralPath $p -Value $Body -Encoding ascii
        return $p
    }

    # Ground truth: what PowerShell ACTUALLY exports from the fixture.
    function Get-TrueExportedFunction {
        param([string]$ModulePath)
        $names = @()
        try {
            $m = Import-Module $ModulePath -PassThru -Force -ErrorAction Stop
            $names = @($m.ExportedFunctions.Keys | Sort-Object)
            Remove-Module $m -Force -ErrorAction SilentlyContinue
        } catch { }
        return $names
    }

    # The 000156 four-form reproducer, verbatim in shape: two functions defined, ONE exported
    # in the single-name forms and BOTH in the multi-name forms.
    $script:Preamble = "function Get-Alpha { 1 }`nfunction Get-Beta { 2 }`n"
}

Describe 'Export-ModuleMember collection -- the 000156 four-form reproducer (dispatch 000159 leg 2)' {

    It 'FORM 1 (single, bare) resolves to the one exported name' {
        $p = New-ExportFixture 'Form1' ($script:Preamble + "Export-ModuleMember -Function Get-Alpha")
        $r = Get-ModuleDefinedFunctionNames -ModuleFilePath $p
        @($r.DefinedNames).Count | Should -Be 2
        @($r.ExportedNames) | Should -Be @('Get-Alpha')
        $r.Degrade | Should -BeExactly ''
        @(Get-TrueExportedFunction $p) | Should -Be @('Get-Alpha')     # ground truth agrees
    }

    It 'FORM 2 (single, quoted) resolves to the one exported name' {
        $p = New-ExportFixture 'Form2' ($script:Preamble + "Export-ModuleMember -Function 'Get-Alpha'")
        $r = Get-ModuleDefinedFunctionNames -ModuleFilePath $p
        @($r.ExportedNames) | Should -Be @('Get-Alpha')
        $r.Degrade | Should -BeExactly ''
        @(Get-TrueExportedFunction $p) | Should -Be @('Get-Alpha')
    }

    It 'FORM 3 (multi, quoted list) resolves BOTH names -- RED before this dispatch' {
        # Pre-fix this returned ExportedNames = $null, which the caller reads as export-all.
        $p = New-ExportFixture 'Form3' ($script:Preamble + "Export-ModuleMember -Function 'Get-Alpha', 'Get-Beta'")
        $r = Get-ModuleDefinedFunctionNames -ModuleFilePath $p
        $r.ExportedNames | Should -Not -BeNullOrEmpty
        @($r.ExportedNames | Sort-Object) | Should -Be @('Get-Alpha', 'Get-Beta')
        $r.Degrade | Should -BeExactly ''
        @(Get-TrueExportedFunction $p) | Should -Be @('Get-Alpha', 'Get-Beta')
    }

    It 'FORM 4 (multi, @() array) resolves BOTH names -- RED before this dispatch' {
        $p = New-ExportFixture 'Form4' ($script:Preamble + "Export-ModuleMember -Function @('Get-Alpha','Get-Beta')")
        $r = Get-ModuleDefinedFunctionNames -ModuleFilePath $p
        $r.ExportedNames | Should -Not -BeNullOrEmpty
        @($r.ExportedNames | Sort-Object) | Should -Be @('Get-Alpha', 'Get-Beta')
        $r.Degrade | Should -BeExactly ''
        @(Get-TrueExportedFunction $p) | Should -Be @('Get-Alpha', 'Get-Beta')
    }

    It 'the modelled surface MATCHES PowerShell ground truth on all four forms' {
        # The single assertion that makes the other four non-vacuous: our model and the real
        # runtime surface agree, form by form.
        $cases = @(
            @{ N = 'G1'; B = "Export-ModuleMember -Function Get-Alpha" },
            @{ N = 'G2'; B = "Export-ModuleMember -Function 'Get-Alpha'" },
            @{ N = 'G3'; B = "Export-ModuleMember -Function 'Get-Alpha', 'Get-Beta'" },
            @{ N = 'G4'; B = "Export-ModuleMember -Function @('Get-Alpha','Get-Beta')" }
        )
        foreach ($c in $cases) {
            $p = New-ExportFixture $c.N ($script:Preamble + $c.B)
            $r = Get-ModuleDefinedFunctionNames -ModuleFilePath $p
            $modelled = @(@($r.ExportedNames) | Sort-Object)
            $truth = @(Get-TrueExportedFunction $p)
            ($modelled -join ',') | Should -BeExactly ($truth -join ',') -Because ('form ' + $c.N + ' must model the real surface')
        }
    }
}

Describe 'Export-ModuleMember collection -- closing the CLASS, not the instance (dispatch 000159 leg 2)' {

    It '-Cmdlet carries the SAME defect and is fixed by the same path (measured, not assumed)' {
        # -Function and -Cmdlet share one collection branch, so the list forms were equally lost.
        $p = New-ExportFixture 'CmdList' ($script:Preamble + "Export-ModuleMember -Cmdlet 'Get-Alpha', 'Get-Beta'")
        @((Get-ModuleDefinedFunctionNames -ModuleFilePath $p).ExportedNames | Sort-Object) |
            Should -Be @('Get-Alpha', 'Get-Beta')
        $p2 = New-ExportFixture 'CmdArr' ($script:Preamble + "Export-ModuleMember -Cmdlet @('Get-Alpha','Get-Beta')")
        @((Get-ModuleDefinedFunctionNames -ModuleFilePath $p2).ExportedNames | Sort-Object) |
            Should -Be @('Get-Alpha', 'Get-Beta')
    }

    It '-Alias names are STILL not folded into the function set, in list form too' {
        # Dispatch 000128 slice 2 (the BurntToast shape): an alias is not a function, and folding
        # an alias name into the function set falsely flagged it as an under-declared FUNCTION.
        # The list forms must not reopen that.
        $body = $script:Preamble + "Set-Alias ga Get-Alpha`nExport-ModuleMember -Function 'Get-Alpha' -Alias 'ga','gb'"
        $p = New-ExportFixture 'AliasList' $body
        @((Get-ModuleDefinedFunctionNames -ModuleFilePath $p).ExportedNames) | Should -Be @('Get-Alpha')

        $body2 = $script:Preamble + "Set-Alias ga Get-Alpha`nExport-ModuleMember -Function 'Get-Alpha' -Alias @('ga','gb')"
        $p2 = New-ExportFixture 'AliasArr' $body2
        @((Get-ModuleDefinedFunctionNames -ModuleFilePath $p2).ExportedNames) | Should -Be @('Get-Alpha')
    }
}

Describe 'Export-ModuleMember collection -- non-literal elements degrade to SILENCE, never a guess (dispatch 000159 leg 2)' {

    It 'a MIXED list (literal + variable) degrades rather than half-resolving' {
        # The hazard the fix had to avoid creating: collecting only the literal half would leave a
        # PARTIAL set that reads as COMPLETE, turning the fix into a new false-positive source --
        # strictly worse than the silence it replaced. Pre-fix this silently assumed export-all
        # with NO degrade recorded; it must now degrade.
        $body = $script:Preamble + "`$n = 'Get-Beta'`nExport-ModuleMember -Function 'Get-Alpha', `$n"
        $r = Get-ModuleDefinedFunctionNames -ModuleFilePath (New-ExportFixture 'MixedList' $body)
        $r.ExportedNames | Should -BeNullOrEmpty
        $r.Degrade | Should -Not -BeNullOrEmpty
    }

    It 'a MIXED @() array (literal + variable) degrades rather than half-resolving' {
        $body = $script:Preamble + "`$n = 'Get-Beta'`nExport-ModuleMember -Function @('Get-Alpha', `$n)"
        $r = Get-ModuleDefinedFunctionNames -ModuleFilePath (New-ExportFixture 'MixedArr' $body)
        $r.ExportedNames | Should -BeNullOrEmpty
        $r.Degrade | Should -Not -BeNullOrEmpty
    }

    It 'a fully dynamic -Function value still degrades (pre-existing behaviour preserved)' {
        $body = $script:Preamble + "`$n = @('Get-Alpha')`nExport-ModuleMember -Function `$n"
        $r = Get-ModuleDefinedFunctionNames -ModuleFilePath (New-ExportFixture 'DynVar' $body)
        $r.ExportedNames | Should -BeNullOrEmpty
        $r.Degrade | Should -Not -BeNullOrEmpty
    }

    It 'CHARACTERIZATION: the dot-source degrade is INERT and never fires (found by 000159 leg 2, NOT fixed here)' {
        # This pins a defect rather than a feature, deliberately, so it cannot be quietly changed
        # in either direction without a test going red.
        #
        # Get-ModuleDefinedFunctionNames intends to degrade on a dot-sourcing module ("skip if
        # dot-sourced -> indeterminate shape"), and detects it with CommandElements[0] -eq '.'.
        # PowerShell does NOT put the dot there: it carries it as the CommandAst's
        # InvocationOperator, and CommandElements[0] is the PATH. So HasDotSource is never true
        # for a real dot-source and the degrade is dead code.
        #
        # This is the SAME trap dispatch 000156 leg 3 hit and banked in its own rule observations,
        # where it made a guard's covered set derive EMPTY while two assertions read green over
        # nothing. It was fixed there, in that guard, and never swept from the shipped helper.
        #
        # NOT fixed here: it is outside this dispatch's chartered class (multi-name export lists,
        # plus the -Alias / -Cmdlet sweep), and changing it alters behaviour for a shape this
        # dispatch did not scope or measure. Recorded for its own dispatch instead.
        $body = ". `$PSScriptRoot/helper.ps1`n" + $script:Preamble + "Export-ModuleMember -Function 'Get-Alpha', 'Get-Beta'"
        $r = Get-ModuleDefinedFunctionNames -ModuleFilePath (New-ExportFixture 'DotSrc' $body)
        $r.HasDotSource | Should -BeFalse -Because 'the dot is the InvocationOperator, not CommandElements[0] -- the check cannot fire'
        $r.Degrade | Should -BeExactly '' -Because 'so the intended dot-source degrade never happens'

        # And prove the CAUSE structurally, so the pin explains itself rather than asserting a bare fact.
        $fx = New-ExportFixture 'DotSrcAst' $body
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($fx, [ref]$null, [ref]$null)
        $cmd = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true))[0]
        [string]$cmd.InvocationOperator | Should -BeExactly 'Dot'
        [string]@($cmd.CommandElements)[0] | Should -Not -BeExactly '.'
    }

    It 'two separate Export-ModuleMember calls still union (pre-existing behaviour preserved)' {
        $body = $script:Preamble + "Export-ModuleMember -Function 'Get-Alpha'`nExport-ModuleMember -Function 'Get-Beta'"
        $r = Get-ModuleDefinedFunctionNames -ModuleFilePath (New-ExportFixture 'TwoCalls' $body)
        @($r.ExportedNames | Sort-Object) | Should -Be @('Get-Alpha', 'Get-Beta')
    }
}

Describe 'The dogfood channel Arc A reads is no longer polluted (dispatch 000159 leg 2)' {

    BeforeAll {
        $script:DfPsm1 = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/dogfood-reader.psm1'
    }

    It "models dogfood-reader's REAL 12-export surface, matching PowerShell ground truth" {
        $r = Get-ModuleDefinedFunctionNames -ModuleFilePath $script:DfPsm1
        $modelled = @(@($r.ExportedNames) | Sort-Object)
        $modelled.Count | Should -Be 12
        @($r.DefinedNames).Count | Should -Be 25          # 25 defined - 12 exported = the 13 privates
        $truth = @(Get-TrueExportedFunction $script:DfPsm1)
        $truth.Count | Should -Be 12
        ($modelled -join ',') | Should -BeExactly ($truth -join ',')
    }

    It 'emits ZERO ManifestConsistency findings (was 13, one per private function)' {
        $res = Get-ProjectIntelligenceFindings -EditedFilePath $script:DfPsm1
        $mc = @(@($res.Findings) | Where-Object { [string]$_.ruleId -eq 'ManifestConsistency' })
        $mc.Count | Should -Be 0 -Because 'every one of the 13 was a false positive from the export-all assumption'
    }
}
