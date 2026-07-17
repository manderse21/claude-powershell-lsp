#Requires -Version 5.1

# AliasesToExport-orphan tests (Pester 5) -- dispatch 000128, N1.6 slice 2.
#
# The check rides the EXISTING always-on ManifestConsistency finder (same ruleId/code -- no new owned
# diagnostic code, no rationale change). It fires when an alias in AliasesToExport has no matching literal
# Set-Alias/New-Alias definition, and degrades to SILENCE on every ambiguity (the 000127 leg-4 requirements
# spec, whose two probe hits are Pester's dynamic `& $SafeCommands['Set-Alias']` and BurntToast's
# `Export-ModuleMember -Alias`). Three layers:
#   (1) Get-ModuleAliasSurface -- the alias half of the module surface (literal defs + the degrade signal).
#   (2) Test-ManifestConsistency -- the alias-orphan block (pure, injected).
#   (3) the enlarged corpus oracle through Get-ProjectIntelligenceFindings -- orphan fires; consistent and
#       BOTH probe-hit shapes stay silent.
#
# ASCII-only; straight quotes; LF.
#
# Author: Mike Andersen / powershell-lsp plugin.

BeforeAll {
    $script:PluginRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsDir = Join-Path $script:PluginRoot 'scripts'
    . (Join-Path $script:ScriptsDir 'lib/lsp-common.ps1')
    $script:AcTmp = Join-Path ([System.IO.Path]::GetTempPath()) ('ac-unit-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $script:AcTmp | Out-Null
    function New-AcModule([string]$Name, [string]$Content) {
        $p = Join-Path $script:AcTmp ($Name + '.psm1'); Set-Content -LiteralPath $p -Value $Content -Encoding ascii; return $p
    }
    function AliasMsgs($r) { return @(@($r.Findings) | Where-Object { $_.message -match 'AliasesToExport' } | ForEach-Object { [string]$_.message }) }
}
AfterAll {
    if (Test-Path -LiteralPath $script:AcTmp) { Remove-Item -LiteralPath $script:AcTmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Get-ModuleAliasSurface -- alias definitions and the degrade signal (dispatch 000128)' {
    It 'collects a literal Set-Alias name and stays determinate' {
        $m = New-AcModule 'gmas1' "function Get-Foo { }`nSet-Alias gf Get-Foo`n"
        $s = Get-ModuleAliasSurface -ModuleFilePath $m
        $s.Indeterminate | Should -BeFalse
        @($s.DefinedAliases) | Should -Contain 'gf'
    }
    It 'collects a New-Alias -Name literal and stays determinate' {
        $m = New-AcModule 'gmas2' "function Get-Foo { }`nNew-Alias -Name nf -Value Get-Foo`n"
        $s = Get-ModuleAliasSurface -ModuleFilePath $m
        $s.Indeterminate | Should -BeFalse
        @($s.DefinedAliases) | Should -Contain 'nf'
    }
    It 'a dynamic invocation (& $x) makes the surface INDETERMINATE (Pester shape)' {
        $m = New-AcModule 'gmas3' "`$sc = @{ 'Set-Alias' = Get-Command Set-Alias }`n& `$sc['Set-Alias'] 'gx' 'Get-Foo'`n"
        (Get-ModuleAliasSurface -ModuleFilePath $m).Indeterminate | Should -BeTrue
    }
    It 'an Export-ModuleMember -Alias makes the surface INDETERMINATE (BurntToast shape)' {
        $m = New-AcModule 'gmas4' "function Get-Foo { }`nSet-Alias gf Get-Foo`nExport-ModuleMember -Function Get-Foo -Alias gf`n"
        (Get-ModuleAliasSurface -ModuleFilePath $m).Indeterminate | Should -BeTrue
    }
    It 'a Set-Alias with a non-literal (splatted) name is INDETERMINATE' {
        $m = New-AcModule 'gmas5' "function Get-Foo { }`n`$p = @{ Name = 'gf'; Value = 'Get-Foo' }`nSet-Alias @p`n"
        (Get-ModuleAliasSurface -ModuleFilePath $m).Indeterminate | Should -BeTrue
    }
    It 'a missing file degrades to the SAFE default (indeterminate, no aliases)' {
        $s = Get-ModuleAliasSurface -ModuleFilePath (Join-Path $script:AcTmp 'does-not-exist.psm1')
        $s.Indeterminate | Should -BeTrue
        @($s.DefinedAliases).Count | Should -Be 0
    }
}

Describe 'Test-ManifestConsistency -- alias-orphan block (pure, injected) (dispatch 000128)' {
    It 'fires on an alias in AliasesToExport with no matching definition' {
        $r = Test-ManifestConsistency -FunctionsToExport @('Get-Foo') -DefinedNames @('Get-Foo') -ExportedNames @('Get-Foo') `
            -AliasesToExport @('gf', 'gMissing') -DefinedAliases @('gf') -AliasesIndeterminate $false
        $am = @(AliasMsgs $r)
        $am.Count | Should -Be 1
        $am[0] | Should -Match "'gMissing'"
    }
    It 'stays silent when every exported alias is defined' {
        $r = Test-ManifestConsistency -FunctionsToExport @('Get-Foo') -DefinedNames @('Get-Foo') -ExportedNames @('Get-Foo') `
            -AliasesToExport @('gf') -DefinedAliases @('gf') -AliasesIndeterminate $false
        (AliasMsgs $r).Count | Should -Be 0
    }
    It 'DEGRADES to silence when the alias surface is indeterminate (never a wrong fire)' {
        $r = Test-ManifestConsistency -FunctionsToExport @('Get-Foo') -DefinedNames @('Get-Foo') -ExportedNames @('Get-Foo') `
            -AliasesToExport @('gMissing') -DefinedAliases @() -AliasesIndeterminate $true
        (AliasMsgs $r).Count | Should -Be 0
    }
    It 'default alias params keep the alias check OFF (existing callers unchanged)' {
        # No -DefinedAliases / -AliasesIndeterminate: the default is indeterminate=true, so a slice-1 caller
        # gets byte-identical behavior (no alias findings) even with AliasesToExport present.
        $r = Test-ManifestConsistency -FunctionsToExport @('Get-Foo') -DefinedNames @('Get-Foo') -ExportedNames @('Get-Foo') `
            -AliasesToExport @('gMissing')
        (AliasMsgs $r).Count | Should -Be 0
    }
    It 'the alias finding rides the EXISTING ManifestConsistency code (no new owned code)' {
        $r = Test-ManifestConsistency -FunctionsToExport @('Get-Foo') -DefinedNames @('Get-Foo') -ExportedNames @('Get-Foo') `
            -AliasesToExport @('gMissing') -DefinedAliases @() -AliasesIndeterminate $false
        $f = @(@($r.Findings) | Where-Object { $_.message -match 'AliasesToExport' })[0]
        $f.code   | Should -BeExactly 'ManifestConsistency'
        $f.ruleId | Should -BeExactly 'ManifestConsistency'
        $f.source | Should -BeExactly 'powershell-lsp'
    }
}

Describe 'Export-ModuleMember -Alias is not a function export -- slice-1 fix (dispatch 000128)' {
    It 'an -Alias export name is NOT folded into the function ExportedNames set' {
        $m = New-AcModule 'emmfix' "function Get-Foo { }`nSet-Alias gf Get-Foo`nExport-ModuleMember -Function Get-Foo -Alias gf`n"
        $info = Get-ModuleDefinedFunctionNames -ModuleFilePath $m
        @($info.ExportedNames) | Should -Contain 'Get-Foo'
        @($info.ExportedNames) | Should -Not -Contain 'gf'
    }
}

Describe 'AliasesToExport corpus oracle + detection through Get-ProjectIntelligenceFindings (dispatch 000128)' {
    # The enlarged known-good oracle (the two 000127 leg-4 probe-hit shapes + a consistent module) must stay
    # SILENT; the orphan fixture must FIRE. Together: 0% FP on the added oracle, 100% detection on the orphan.
    BeforeAll { $script:AcCorpus = Join-Path (Split-Path -Parent $PSScriptRoot) 'tests/corpus/samples/module' }
    It 'alias-orphan FIRES on the undefined alias (gaoMissing)' {
        $r = Get-ProjectIntelligenceFindings -EditedFilePath (Join-Path $script:AcCorpus 'alias-orphan/AliasOrphan.psm1')
        $am = @(AliasMsgs $r)
        $am.Count | Should -Be 1
        $am[0] | Should -Match 'gaoMissing'
    }
    It 'alias-consistent is SILENT (the alias is defined)' {
        (AliasMsgs (Get-ProjectIntelligenceFindings -EditedFilePath (Join-Path $script:AcCorpus 'alias-consistent/AliasConsistent.psm1'))).Count | Should -Be 0
    }
    It 'alias-dynamic-good is SILENT (Pester dynamic-invocation shape)' {
        $r = Get-ProjectIntelligenceFindings -EditedFilePath (Join-Path $script:AcCorpus 'alias-dynamic-good/AliasDynamicGood.psm1')
        @($r.Findings).Count | Should -Be 0
    }
    It 'alias-exportmember-good is SILENT (BurntToast Export-ModuleMember -Alias shape)' {
        $r = Get-ProjectIntelligenceFindings -EditedFilePath (Join-Path $script:AcCorpus 'alias-exportmember-good/AliasExportGood.psm1')
        @($r.Findings).Count | Should -Be 0
    }
}
