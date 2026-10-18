#Requires -Version 5.1

# The routes where a managed scan certified while a rule the organization requires, or one the repository
# declared, did not run (Pester 5) -- dispatch 000307, B1c: B1b's out-of-band review findings B1b-OOB2-R01
# to R04 and I05; B1c's correction round 1, the owner's rulings (2026-10-17) on review 6656dadf4a4b's
# findings B1c-RV-01 to B1c-RV-04; and its correction round 2, the owner's rulings (2026-10-18, RR-01 as
# amended) on review 4ae359b10fe5's findings B1c-RR-01 and B1c-RR-04.
#
# SIX LAYERS:
#   1. How PSScriptAnalyzer names and matches a rule: Get-PssaRuleMatchName and Test-PssaRuleNameMatch over
#      the forms MEASURED on the vendored PSScriptAnalyzer 1.25.0 -- and PARITY with that analyzer on the
#      running host, every form judged by it the way PSES calls it, so the mirror cannot drift from it; with
#      the IncludeRules = @() reading (R03) and the rule-source order the documentation states (I05).
#   2. The merge (no daemon): a pattern in the repository's ExcludeRules no longer keeps a required rule off
#      (R01), a required custom rule reaches the analyzer by its bare name (R02), IncludeRules = @() keeps the
#      repository's rule set (R03), every ExcludeRules entry is written as the repository gave it (RV-04) --
#      and the shapes these routes do not touch merge byte for byte as before.
#   3. The merged settings judged by the vendored analyzer: every rule the repository's file runs alone still
#      runs, the required one beside it, and every rule the repository's pattern excluded stays excluded.
#   4. The static check (Get-RequiredRulesNotRunnable): a required code with no rule behind it, and one the
#      merged settings still exclude, are reported; nothing else is (R04, and R01's case beside a CustomRulePath).
#   5. The daemon and the evidence consumers: the record carries cannotRun, the receipt types it, the scan
#      warns, and a managed verdict over such a record is refused (policy-required-rule-cannot-run: RV-02,
#      RV-03); so is one over a tree holding a settings file below the scan root (policy-settings-nested: RV-01),
#      which is found the way the settings lookup finds one.
#   6. The real daemon, every ambient plugin variable cleared: R01, R03 and R04 end to end, and RV-01 to RV-04.
#
# The tests named 'B1c-R01:' to 'B1c-R04:' fail with f5b46ec's scripts (the base); the controls ('B1c
# controls:', 'B1c-R01 control:', 'B1c-R02 control:') pass there too -- they pin the text f5b46ec writes for
# the shapes these routes do not touch (captured from its own functions on both hosts). 'B1c-R03 measured:'
# and 'B1c-I05:' measure the analyzer itself and pass on any tree. The tests named 'B1c-RV01:' to 'B1c-RV04:'
# fail with 491ecb5's scripts (the head review 6656dadf4a4b read); the controls named 'B1c-RV01 control:' to
# 'B1c-RV04 control:' pass there too.
#
# Correction round 2 adds, in layer 1, a run of '*' matched as one (RR-04), and a Describe of its own for RR-01
# spanning layers 2 to 4: a required configurable built-in rule named Module\Name is switched on by its match
# name, the merged settings are judged by the analyzer, and the static check names one the merged Rules do not
# switch on. The tests named 'B1c-RR01:' fail with d7cf111's scripts (the head review 4ae359b10fe5 read), and
# 'B1c-RR04:' fails there under Windows PowerShell 5.1, where a run of '*' backtracked; the controls named
# 'B1c-RR01 control:' and 'B1c-RR04 control:' pass there too.
#
# ASCII-only (PS 5.1 em-dash trap); StrictMode-safe.

$script:RtOnWindows = if (Test-Path 'Variable:\IsWindows') { [bool]$IsWindows } else { $true }
$script:RtOnLinux = (Test-Path 'Variable:\IsLinux') -and [bool]$IsLinux
$script:RtOnMacOS = (Test-Path 'Variable:\IsMacOS') -and [bool]$IsMacOS
$script:RtUnsupported = -not ($script:RtOnWindows -or $script:RtOnLinux -or $script:RtOnMacOS)

BeforeAll {
    $script:RtRepo = Split-Path -Parent $PSScriptRoot
    $script:RtScripts = Join-Path $script:RtRepo 'scripts'
    . (Join-Path $script:RtRepo 'scripts/lib/lsp-common.ps1')
    . (Join-Path $script:RtRepo 'scripts/lib/lsp-scan-common.ps1')
    . (Join-Path $script:RtRepo 'scripts/lib/lsp-scan-receipt.ps1')
    . (Join-Path $script:RtRepo 'scripts/lib/lsp-policy.ps1')

    function New-RtFile {
        # A file under $TestDrive holding $Text (UTF-8, no BOM unless asked), returned as its absolute path.
        param([string]$Text, [string]$Name = 'PSScriptAnalyzerSettings.psd1', [switch]$Bom)
        $d = Join-Path $TestDrive ('rt-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        $p = Join-Path $d $Name
        [System.IO.File]::WriteAllText($p, $Text, (New-Object System.Text.UTF8Encoding([bool]$Bom)))
        return $p
    }
    function New-RtRuleModule {
        # A custom rule module whose one rule REPORTS (once per file, so the analyzer shows it ran) -- or
        # THROWS -- its findings named 'Module\Function'.
        param([string]$Module, [string]$Function, [switch]$Throw)
        $body = if ($Throw) { '    throw ''the rule throws''' } else {
            '    if ($null -ne $ScriptBlockAst.Parent) { return @() }' + "`n" +
            '    return @([Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]@{ Message = ''ran''; Extent = $ScriptBlockAst.Extent; RuleName = $PSCmdlet.MyInvocation.InvocationName; Severity = ''Warning'' })'
        }
        return (New-RtFile -Name ($Module + '.psm1') -Text ((@(
                        ('function ' + $Function + ' {')
                        '    [CmdletBinding()]'
                        '    [OutputType([Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord[]])]'
                        '    param([Parameter(Mandatory = $true)][System.Management.Automation.Language.ScriptBlockAst]$ScriptBlockAst)'
                        $body
                        '}'
                        ('Export-ModuleMember -Function ' + $Function)) -join "`n") + "`n"))
    }
    function Get-RtText($Merged) { return (ConvertTo-MergedPssaSettingsText -Settings $Merged) }
    function Get-RtSha([string]$Text) { return (Get-Sha256HexFromBytes -Bytes ((New-Object System.Text.UTF8Encoding($false)).GetBytes($Text))) }
    $script:RtHead = '# GENERATED by Write-MergedPssaSettingsFile (dispatch 000294). DO NOT EDIT.' + "`n" + '@{' + "`n"

    function Invoke-RtJudge {
        # Judge every <name>.psd1 in $Dir with the vendored PSScriptAnalyzer in a child of this host, called as
        # PSES calls it (-ScriptDefinition, -Settings, -Severity Error,Warning,Information), from an empty
        # working directory: '<name>' -> the rules that reported, sorted ('refused' when it threw). A case may
        # bring its own sample as <name>.code.txt; the default is code.txt.
        param([string]$Manifest, [string]$Dir)
        $driver = Join-Path $TestDrive ('rt-judge-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
        [System.IO.File]::WriteAllText($driver, (@(
                    'param([string]$Manifest, [string]$Dir)'
                    '$ErrorActionPreference = ''Stop'''
                    'Import-Module $Manifest -Force'
                    '$default = [System.IO.File]::ReadAllText((Join-Path $Dir ''code.txt''))'
                    'foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Filter ''*.psd1'')) {'
                    '    $own = Join-Path $Dir ($f.BaseName + ''.code.txt'')'
                    '    $code = if (Test-Path -LiteralPath $own) { [System.IO.File]::ReadAllText($own) } else { $default }'
                    '    $r = ''refused'''
                    '    try { $r = (@(Invoke-ScriptAnalyzer -ScriptDefinition $code -Severity @(''Error'', ''Warning'', ''Information'') -Settings $f.FullName -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.RuleName } | Sort-Object -Unique) -join '','') } catch { $r = ''refused'' }'
                    '    [string]$f.BaseName + ''='' + $r'
                    '}') -join "`n"))
        $out = @{}
        $cwd = Join-Path $TestDrive ('rt-cwd-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $cwd | Out-Null
        $exe = (Get-Process -Id $PID).Path
        $prev = Get-Location
        try {
            Set-Location -LiteralPath $cwd
            $lines = @(& $exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $driver -Manifest $Manifest -Dir $Dir 2>$null)
        } finally { Set-Location $prev }
        foreach ($l in $lines) {
            $i = ([string]$l).IndexOf('=')
            if ($i -gt 0) { $out[([string]$l).Substring(0, $i)] = @(([string]$l).Substring($i + 1).Split(',') | Where-Object { $_ }) }
        }
        return $out
    }
    function Get-RtVendoredManifest {
        # The vendored analyzer's manifest in the suite's provisioned data root (ensure-pssa first).
        $data = if (-not [string]::IsNullOrWhiteSpace($env:PSLS_TEST_DATA_DIR)) { $env:PSLS_TEST_DATA_DIR } else { Join-Path ([System.IO.Path]::GetTempPath()) 'psls-sarifscan-test-data' }
        New-Item -ItemType Directory -Force -Path $data | Out-Null
        $prevData = $env:CLAUDE_PLUGIN_DATA
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $env:CLAUDE_PLUGIN_DATA = $data
            & (Resolve-PsHost 'pwsh') -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:RtScripts 'ensure-pssa.ps1') 2>&1 | Out-Null
            return [string](Find-VendoredPssaManifest)
        } finally { $ErrorActionPreference = $prevEap; $env:CLAUDE_PLUGIN_DATA = $prevData }
    }
}

Describe 'How PSScriptAnalyzer names and matches a rule (dispatch 000307 B1c, review findings B1b-OOB2-R01 and B1b-OOB2-R02)' {

    It 'B1c-R02: a custom rule''s Module\Measure-Name is matched by its bare name, and a built-in or bare code by itself' {
        Get-PssaRuleMatchName 'B1c.Rules\Measure-B1c' | Should -BeExactly 'Measure-B1c'
        Get-PssaRuleMatchName '  PSAvoidGlobalVars ' | Should -BeExactly 'PSAvoidGlobalVars'
        Get-PssaRuleMatchName 'Measure-B1c' | Should -BeExactly 'Measure-B1c'
        Get-PssaRuleMatchName 'A\B\Measure-C' | Should -BeExactly 'Measure-C'
        Get-PssaRuleMatchName 'B1c.Rules\' | Should -BeExactly '' -Because 'nothing follows the last backslash: it names no rule'
    }

    It 'B1c-R01: the entry <Entry> names PSAvoidGlobalVars: <Names> (as measured on both hosts)' -TestCases @(
        @{ Entry = 'PSAvoidGlobalVars'; Names = $true }
        @{ Entry = 'psavoidglobalvars'; Names = $true }
        @{ Entry = 'PSAvoidGlobal*'; Names = $true }
        @{ Entry = 'psavoidglobal*'; Names = $true }
        @{ Entry = '*'; Names = $true }
        @{ Entry = 'PS*'; Names = $true }
        @{ Entry = '*Vars'; Names = $true }
        @{ Entry = 'PSAvoid*Vars'; Names = $true }
        @{ Entry = '*Global*'; Names = $true }
        @{ Entry = 'PSAvoidGlobalVars*'; Names = $true }
        @{ Entry = '**'; Names = $true }
        @{ Entry = 'PS*Global*Vars'; Names = $true }
        @{ Entry = ' PSAvoidGlobalVars '; Names = $false }
        @{ Entry = ' PSAvoidGlobal* '; Names = $false }
        @{ Entry = 'PSAvoidGlobalVar?'; Names = $false }
        @{ Entry = 'PSAvoidGlobalVar[s]'; Names = $false }
        @{ Entry = 'PSAvoidGlobalVar.'; Names = $false }
        @{ Entry = 'PSAvoid.*'; Names = $false }
        @{ Entry = 'PSAvoidGlobalVars|PSUseSingularNouns'; Names = $false }
        @{ Entry = '^PSAvoidGlobalVars$'; Names = $false }
        @{ Entry = 'PSAvoid(Global)Vars'; Names = $false }
        @{ Entry = '(?i)PSAvoidGlobalVars'; Names = $false }
        @{ Entry = 'PSAvoidGlobalVar+'; Names = $false }
        @{ Entry = 'PSAvoidGlobalVars\'; Names = $false }
        @{ Entry = 'PSUse*'; Names = $false }
        @{ Entry = ''; Names = $false }
    ) {
        param($Entry, $Names)
        Test-PssaRuleNameMatch -Entry $Entry -Name 'PSAvoidGlobalVars' | Should -Be $Names
    }

    It 'B1c-R01: case is folded the way the analyzer''s regular expression folds it -- the Kelvin sign names a k' {
        Test-PssaRuleNameMatch -Entry ('PSMisleadingBac' + [char]0x212A + 'tick') -Name 'PSMisleadingBacktick' | Should -BeTrue
        Test-PssaRuleNameMatch -Entry ('PSMisleadingBac' + [char]0x212A + '*') -Name 'PSMisleadingBacktick' | Should -BeTrue
    }

    It 'B1c-R02: a custom rule is matched by its bare name, never by Module\Measure-Name' {
        Test-PssaRuleNameMatch -Entry 'Measure-B1c' -Name (Get-PssaRuleMatchName 'B1c.Rules\Measure-B1c') | Should -BeTrue
        Test-PssaRuleNameMatch -Entry 'Measure-B1*' -Name 'Measure-B1c' | Should -BeTrue
        Test-PssaRuleNameMatch -Entry 'B1c.Rules\Measure-B1c' -Name 'Measure-B1c' | Should -BeFalse
        Test-PssaRuleNameMatch -Entry 'B1c.Rules\*' -Name 'Measure-B1c' | Should -BeFalse
    }

    It 'B1c-RR04: an entry with a run of eight ''*'' and a tail no rule name ends in answers at once (under Windows PowerShell 5.1 it backtracked for tens of seconds)' {
        # Owner ruling RR-04 (dispatch 000307, correction round 2): a run of '*' is matched as one. Measured on
        # d7cf111's matcher under Windows PowerShell 5.1: six stars about half a second, eight over 40 seconds.
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $m = Test-PssaRuleNameMatch -Entry (('*' * 8) + 'Z') -Name 'PSAvoidUsingConvertToSecureStringWithPlainText'
        $sw.Stop()
        $m | Should -BeFalse
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 5 -Because ('it took ' + [int]$sw.Elapsed.TotalMilliseconds + ' ms')
    }

    It 'B1c-RR04 control: a run of ''*'' matches exactly what one ''*'' matches -- every entry with a run gives the answer the uncollapsed construction gives' {
        function Test-RtUncollapsed([string]$Entry, [string]$Name) {
            # d7cf111's construction: each '*' its own '.*'.
            $p = '^' + [regex]::Escape($Entry).Replace('\*', '.*') + '$'
            return [regex]::IsMatch($Name, $p, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        }
        $names = @(Get-PssaBuiltinRuleNames) + @('Measure-B1c', 'xy', 'x*y', 'x**y')
        $entries = @('**', '***', '**Vars', 'PSAvoid**', 'PSAvoid***Vars', '**Global**', 'PS**Global***Vars', ' PSAvoid** ', '***Z', 'Measure-**',
            'x**y', '**Parity', ('PSMisleadingBac' + [char]0x212A + '**'))
        $diff = New-Object System.Collections.Generic.List[string]
        $hits = 0
        foreach ($e in $entries) {
            foreach ($n in $names) {
                $a = Test-PssaRuleNameMatch -Entry $e -Name $n
                if ($a) { $hits++ }
                if ($a -ne (Test-RtUncollapsed $e $n)) { $diff.Add(("'" + $e + "' vs '" + $n + "'")) }
            }
        }
        ($diff.ToArray() -join '; ') | Should -BeExactly ''
        $hits | Should -BeGreaterThan 100 -Because 'the corpus must match something, or agreeing proves nothing'
        Test-PssaRuleNameMatch -Entry (('*' * 8) + 'Text') -Name 'PSAvoidUsingConvertToSecureStringWithPlainText' | Should -BeTrue
    }

    Context 'PARITY with the vendored PSScriptAnalyzer on this host' -Skip:$script:RtUnsupported {

        BeforeAll {
            $script:PyManifest = Get-RtVendoredManifest
            $script:PyDir = Join-Path $TestDrive 'parity'
            New-Item -ItemType Directory -Force -Path $script:PyDir | Out-Null
            $enc = New-Object System.Text.UTF8Encoding($false)
            $encBom = New-Object System.Text.UTF8Encoding($true)
            $q = [string][char]39
            [System.IO.File]::WriteAllText((Join-Path $script:PyDir 'code.txt'), ("function Get-Items { param() Write-Host 'x' }`ngci`n`$global:py = 1`nWrite-Output 'a' `` `n'b'`n"), $enc)
            $script:PyModule = New-RtRuleModule 'B1c.Parity' 'Measure-B1cParity'
            $script:PyWorking2 = New-RtRuleModule 'B1c.Parity2' 'Measure-B1cParity2'
            $script:PyThrow = New-RtRuleModule 'B1c.Throws' 'Measure-B1cThrows' -Throw
            # A module PSScriptAnalyzer lists but cannot load: its manifest names a nested root module.
            $modDir = Join-Path $TestDrive 'py-unloadable/B1c.Unloadable'
            New-Item -ItemType Directory -Force -Path (Join-Path $modDir 'impl') | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $modDir 'impl/Impl.psm1'), "function Measure-B1cImpl {`n    param([Parameter(Mandatory = `$true)][System.Management.Automation.Language.ScriptBlockAst]`$ScriptBlockAst)`n    return @()`n}`nExport-ModuleMember -Function Measure-B1cImpl`n")
            $script:PyUnloadable = Join-Path $modDir 'B1c.Unloadable.psd1'
            [System.IO.File]::WriteAllText($script:PyUnloadable, "@{ RootModule = 'impl\Impl.psm1'; ModuleVersion = '1.0.0'; GUID = '7c1e9a3b-2d4f-4b6a-9e8d-0f1a2b3c4d5e'; FunctionsToExport = @('Measure-B1cImpl') }`n")
            function Q([string]$s) { return ($q + $s.Replace($q, $q + $q) + $q) }
            # ExcludeRules forms over a built-in rule.
            $script:PyBuiltinForms = @('PSAvoidGlobalVars', 'psavoidglobalvars', ' PSAvoidGlobalVars ', 'PSAvoidGlobal*', 'psavoidglobal*', '*', 'PS*',
                '*Vars', 'PSAvoid*Vars', '*Global*', 'PSAvoidGlobalVars*', '**', ' PSAvoidGlobal* ', 'PSAvoidGlobalVar?', 'PSAvoidGlobalVar[s]',
                'PSAvoidGlobalVar.', 'PSAvoid.*', 'PSAvoidGlobalVars|PSUseSingularNouns', '^PSAvoidGlobalVars$', 'PSAvoid(Global)Vars',
                '(?i)PSAvoidGlobalVars', 'PSAvoidGlobalVar+', 'PSAvoidGlobalVars\', "PSAvoid`t*", 'PSUse*', 'Measure-*')
            for ($i = 0; $i -lt $script:PyBuiltinForms.Count; $i++) {
                [System.IO.File]::WriteAllText((Join-Path $script:PyDir ('xb-' + $i + '.psd1')), ('@{ ExcludeRules = @(' + (Q $script:PyBuiltinForms[$i]) + ') }'), $enc)
            }
            [System.IO.File]::WriteAllText((Join-Path $script:PyDir 'xk-0.psd1'), ('@{ ExcludeRules = @(' + (Q ('PSMisleadingBac' + [char]0x212A + 'tick')) + ') }'), $encBom)
            [System.IO.File]::WriteAllText((Join-Path $script:PyDir 'xk-1.psd1'), ('@{ ExcludeRules = @(' + (Q ('PSMisleadingBac' + [char]0x212A + '*')) + ') }'), $encBom)
            # ExcludeRules and IncludeRules forms over a custom rule (its built-in rules loaded too).
            $cp = 'CustomRulePath = @(' + (Q $script:PyModule) + '); IncludeDefaultRules = $true'
            $script:PyCustomForms = @('Measure-B1cParity', 'measure-b1cparity', 'Measure-B1c*', '*Parity', 'B1c.Parity\Measure-B1cParity', 'B1c.Parity\*', 'B1c.Parity*', '*')
            for ($i = 0; $i -lt $script:PyCustomForms.Count; $i++) {
                [System.IO.File]::WriteAllText((Join-Path $script:PyDir ('xc-' + $i + '.psd1')), ('@{ ExcludeRules = @(' + (Q $script:PyCustomForms[$i]) + '); ' + $cp + ' }'), $enc)
                [System.IO.File]::WriteAllText((Join-Path $script:PyDir ('ic-' + $i + '.psd1')), ('@{ IncludeRules = @(' + (Q $script:PyCustomForms[$i]) + '); ' + $cp + ' }'), $enc)
            }
            # IncludeRules that name nothing (B1b-OOB2-R03), beside the control that names none.
            $script:PyEmpty = [ordered]@{ 'ie-none' = '@{ }'; 'ie-empty' = '@{ IncludeRules = @() }'; 'ie-paren' = '@{ IncludeRules = (@()) }'; 'ie-blank' = "@{ IncludeRules = @('') }"; 'ie-space' = "@{ IncludeRules = @(' ') }" }
            foreach ($k in @($script:PyEmpty.Keys)) { [System.IO.File]::WriteAllText((Join-Path $script:PyDir ($k + '.psd1')), $script:PyEmpty[$k], $enc) }
            # Rule-source order (B1b-OOB2-I05): a source the analyzer cannot load, or whose rule throws, before or after a working one.
            $script:PyOrder = [ordered]@{
                'o-unloadable-first' = @($script:PyUnloadable, $script:PyModule); 'o-unloadable-last' = @($script:PyModule, $script:PyUnloadable)
                'o-throw-first' = @($script:PyThrow, $script:PyModule); 'o-throw-last' = @($script:PyModule, $script:PyThrow)
                'o-control' = @($script:PyModule, $script:PyWorking2)
            }
            foreach ($k in @($script:PyOrder.Keys)) {
                $list = '@(' + (@($script:PyOrder[$k] | ForEach-Object { Q $_ }) -join ', ') + ')'
                [System.IO.File]::WriteAllText((Join-Path $script:PyDir ($k + '.psd1')), ('@{ CustomRulePath = ' + $list + ' }'), $enc)
                [System.IO.File]::WriteAllText((Join-Path $script:PyDir ($k + '-idr.psd1')), ('@{ CustomRulePath = ' + $list + '; IncludeDefaultRules = $true }'), $enc)
            }
            $script:Py = @{}
            if (-not [string]::IsNullOrWhiteSpace($script:PyManifest)) { $script:Py = Invoke-RtJudge -Manifest $script:PyManifest -Dir $script:PyDir }
        }

        It 'the vendored analyzer was found and judged every case (this Context cannot pass vacuously)' {
            $script:PyManifest | Should -Not -BeNullOrEmpty
            $script:Py.Count | Should -Be ($script:PyBuiltinForms.Count + 2 + 2 * $script:PyCustomForms.Count + $script:PyEmpty.Count + 2 * $script:PyOrder.Count)
            @($script:Py['ie-none']) | Should -Contain 'PSAvoidGlobalVars' -Because 'CONTROL: the sample draws PSAvoidGlobalVars'
            @($script:Py['ie-none']) | Should -Contain 'PSMisleadingBacktick' -Because 'CONTROL: the sample draws PSMisleadingBacktick'
            @($script:Py['xc-0']) | Should -Contain 'PSAvoidGlobalVars' -Because 'CONTROL: IncludeDefaultRules loads the built-in rules beside the custom one'
        }

        It 'B1c-R01: every ExcludeRules form excludes PSAvoidGlobalVars exactly when Test-PssaRuleNameMatch says it names it' {
            $mismatch = New-Object System.Collections.Generic.List[string]
            for ($i = 0; $i -lt $script:PyBuiltinForms.Count; $i++) {
                $ran = (@($script:Py[('xb-' + $i)]) -contains 'PSAvoidGlobalVars')
                $names = Test-PssaRuleNameMatch -Entry $script:PyBuiltinForms[$i] -Name 'PSAvoidGlobalVars'
                if ($ran -eq $names) { $mismatch.Add(("'" + $script:PyBuiltinForms[$i] + "': analyzer ran it=" + $ran + ', mirror names it=' + $names)) }
            }
            ($mismatch.ToArray() -join '; ') | Should -BeExactly ''
            @($script:Py['xb-5']).Count | Should -Be 0 -Because "'*' excludes every rule"
        }

        It 'B1c-R01: the Kelvin sign in an ExcludeRules entry excludes PSMisleadingBacktick, as the mirror says' {
            @($script:Py['xk-0']) | Should -Not -Contain 'PSMisleadingBacktick'
            @($script:Py['xk-1']) | Should -Not -Contain 'PSMisleadingBacktick'
            @($script:Py['xk-0']) | Should -Contain 'PSAvoidGlobalVars' -Because 'CONTROL: only the one rule is excluded'
            Test-PssaRuleNameMatch -Entry ('PSMisleadingBac' + [char]0x212A + 'tick') -Name 'PSMisleadingBacktick' | Should -BeTrue
            Test-PssaRuleNameMatch -Entry ('PSMisleadingBac' + [char]0x212A + '*') -Name 'PSMisleadingBacktick' | Should -BeTrue
        }

        It 'B1c-R02: every ExcludeRules and IncludeRules form selects or excludes the custom rule exactly when the mirror names its bare name' {
            $mismatch = New-Object System.Collections.Generic.List[string]
            $name = Get-PssaRuleMatchName 'B1c.Parity\Measure-B1cParity'
            for ($i = 0; $i -lt $script:PyCustomForms.Count; $i++) {
                $names = Test-PssaRuleNameMatch -Entry $script:PyCustomForms[$i] -Name $name
                $ranEx = (@($script:Py[('xc-' + $i)]) -contains 'B1c.Parity\Measure-B1cParity')
                $ranIn = (@($script:Py[('ic-' + $i)]) -contains 'B1c.Parity\Measure-B1cParity')
                if ($ranEx -eq $names) { $mismatch.Add(("ExcludeRules '" + $script:PyCustomForms[$i] + "': ran=" + $ranEx + ', names=' + $names)) }
                if ($ranIn -ne $names) { $mismatch.Add(("IncludeRules '" + $script:PyCustomForms[$i] + "': ran=" + $ranIn + ', names=' + $names)) }
            }
            ($mismatch.ToArray() -join '; ') | Should -BeExactly ''
            @($script:Py['xc-4']) | Should -Contain 'B1c.Parity\Measure-B1cParity' -Because 'the qualified name, as its findings read, excludes nothing'
            @($script:Py['ic-4']) | Should -Not -Contain 'B1c.Parity\Measure-B1cParity' -Because 'and selects nothing'
        }

        It 'B1c-R03 measured: IncludeRules = @() runs every rule, as no IncludeRules does; a list of blank entries runs none' {
            $all = @($script:Py['ie-none'])
            (@($script:Py['ie-empty']) -join ',') | Should -BeExactly ($all -join ',')
            (@($script:Py['ie-paren']) -join ',') | Should -BeExactly ($all -join ',')
            @($script:Py['ie-blank']).Count | Should -Be 0
            @($script:Py['ie-space']).Count | Should -Be 0
        }

        It 'B1c-I05: a rule source the analyzer cannot load, or whose rule throws, stops every custom rule source listed after it, never one listed before it, nor the built-in rules' {
            $w = 'B1c.Parity\Measure-B1cParity'
            @($script:Py['o-control']) | Should -Contain $w -Because 'CONTROL: two working sources both run'
            @($script:Py['o-control']) | Should -Contain 'B1c.Parity2\Measure-B1cParity2'
            # The unloadable fixture -- a manifest whose RootModule sits in a subfolder -- was MEASURED unloadable
            # on Windows (both hosts); whether PowerShell elsewhere loads it was not measured, so that half is
            # asserted on Windows. A rule that throws is the same on every platform.
            $onWindows = if (Test-Path 'Variable:\IsWindows') { [bool]$IsWindows } else { $true }
            $faulty = @('o-throw') + $(if ($onWindows) { @('o-unloadable') } else { @() })
            foreach ($k in @($faulty | ForEach-Object { $_ + '-first' })) {
                @($script:Py[$k]) | Should -Not -Contain $w -Because ($k + ': the working source is listed after the faulty one')
                @($script:Py[$k + '-idr']) | Should -Not -Contain $w -Because ($k + '-idr')
                @($script:Py[$k + '-idr']) | Should -Contain 'PSAvoidGlobalVars' -Because 'the built-in rules still run'
            }
            foreach ($k in @($faulty | ForEach-Object { $_ + '-last' })) {
                @($script:Py[$k]) | Should -Contain $w -Because ($k + ': listed before the faulty source, it runs')
                @($script:Py[$k + '-idr']) | Should -Contain $w -Because ($k + '-idr')
            }
        }
    }
}

Describe 'The RequiredRules merge reads the repository''s settings the way PSScriptAnalyzer does (dispatch 000307 B1c, review findings B1b-OOB2-R01 to R03)' {

    BeforeAll {
        $script:MgModule = New-RtRuleModule 'B1c.Merge' 'Measure-B1cMerge'
        $script:MgCustom = "CustomRulePath = @('" + $script:MgModule + "')"
        function Invoke-RtMerge([string]$Repo, [string[]]$Required, [string]$Tag = 'v4.6.0', [string[]]$OrgExclude = @()) {
            $g = ''
            $m = Merge-RequiredRulesSettings -ResolvedSettingsPath $Repo -RequiredRules $Required -OrgExcludeRules $OrgExclude -CurrentPsesTag $Tag -GuardOut ([ref]$g)
            return @{ Merged = $m; Guard = $g; Text = (Get-RtText $m) }
        }
        $script:MgGlobals = @('PSAvoidGlobalAliases', 'PSAvoidGlobalFunctions')
    }

    It 'B1c-R01: a pattern in the repository''s ExcludeRules that names a required rule is written as the built-in rules it matches, minus the required one' {
        $r = Invoke-RtMerge (New-RtFile "@{ ExcludeRules = @('PSAvoidGlobal*') }") @('PSAvoidGlobalVars')
        (@($r.Merged.Keys | Sort-Object) -join ',') | Should -BeExactly 'ExcludeRules' -Because 'the file names no IncludeRules: R03 keeps its rule set'
        (@($r.Merged.ExcludeRules) -join ',') | Should -BeExactly ($script:MgGlobals -join ',')
        $r.Guard | Should -BeExactly 'not-needed'
    }

    It 'B1c-R01: ''*'' is written as every built-in rule but the required one' {
        $r = Invoke-RtMerge (New-RtFile "@{ ExcludeRules = @('*') }") @('PSAvoidGlobalVars')
        $ex = @($r.Merged.ExcludeRules)
        $ex.Count | Should -Be (@(Get-PssaBuiltinRuleNames).Count - 1)
        $ex | Should -Not -Contain 'PSAvoidGlobalVars'
        (@($ex | Sort-Object) -join ',') | Should -BeExactly (@(Get-PssaBuiltinRuleNames | Where-Object { $_ -ne 'PSAvoidGlobalVars' } | Sort-Object) -join ',')
    }

    It 'B1c-R01: beside the repository''s own IncludeRules, the pattern is narrowed the same way and the required rule is still named' {
        $r = Invoke-RtMerge (New-RtFile "@{ IncludeRules = @('PSAvoidUsingCmdletAliases'); ExcludeRules = @('PSAvoidGlobal*') }") @('PSAvoidGlobalVars')
        $r.Text | Should -BeExactly ($script:RtHead + "    IncludeRules = @('PSAvoidUsingCmdletAliases', 'PSAvoidGlobalVars')" + "`n" +
            "    ExcludeRules = @('PSAvoidGlobalAliases', 'PSAvoidGlobalFunctions')" + "`n" + '}' + "`n")
    }

    It 'B1c-R01: over a required configurable rule the merge switches on, a pattern that names it no longer wins' {
        $r = Invoke-RtMerge (New-RtFile "@{ ExcludeRules = @('PSAvoidLong*', 'PSAvoidUsingWriteHost') }") @('PSAvoidLongLines')
        (@($r.Merged.ExcludeRules) -join ',') | Should -BeExactly 'PSAvoidUsingWriteHost' -Because 'PSAvoidLong* matches no built-in rule but the required one'
        $r.Merged.Rules['PSAvoidLongLines']['Enable'] | Should -BeTrue
    }

    It 'B1c-R01: an exact entry the pattern already covered is written once; a pattern that names no required rule is kept as written' {
        $r = Invoke-RtMerge (New-RtFile "@{ ExcludeRules = @('PSAvoid*', 'PSAvoidUsingWriteHost', 'PSUse*') }") @('PSAvoidGlobalVars')
        $ex = @($r.Merged.ExcludeRules)
        @($ex | Where-Object { $_ -eq 'PSAvoidUsingWriteHost' }).Count | Should -Be 1
        $ex | Should -Not -Contain 'PSAvoidGlobalVars'
        $ex | Should -Not -Contain 'PSAvoid*'
        $ex[-1] | Should -BeExactly 'PSUse*' -Because 'it matches no required rule: written as the repository wrote it'
        $ex | Should -Contain 'PSAvoidUsingCmdletAliases'
    }

    It 'B1c-R01: an entry in any case the analyzer folds is taken out -- an exact one with the Kelvin sign too, which the exact-name strip kept' {
        $r = Invoke-RtMerge (New-RtFile ("@{ ExcludeRules = @('PSMisleadingBac" + [char]0x212A + "tick', 'PSAvoidUsingWriteHost') }") -Bom) @('PSMisleadingBacktick')
        (@($r.Merged.ExcludeRules) -join ',') | Should -BeExactly 'PSAvoidUsingWriteHost'
        $r2 = Invoke-RtMerge (New-RtFile "@{ ExcludeRules = @('psavoidglobal*') }") @('PSAvoidGlobalVars')
        (@($r2.Merged.ExcludeRules) -join ',') | Should -BeExactly ($script:MgGlobals -join ',')
    }

    It 'B1c-RV03 control: beside a CustomRulePath the pattern is still kept as written -- the owner ruled refusal, not narrowing (RV-03) -- and the static check names the rule it shuts out' {
        # A pattern may match custom rules no static read can list; narrowing it to the built-in rules would
        # run custom rules the repository excluded. So it is kept and reported, and a managed scan refuses it
        # (policy-required-rule-cannot-run: the tests named 'B1c-RV03:' below).
        $r = Invoke-RtMerge (New-RtFile ("@{ " + $script:MgCustom + "; ExcludeRules = @('PSAvoidGlobal*') }")) @('PSAvoidGlobalVars')
        (@($r.Merged.ExcludeRules) -join ',') | Should -BeExactly 'PSAvoidGlobal*'
        (@(Get-RequiredRulesNotRunnable -Settings $r.Merged -RequiredRules @('PSAvoidGlobalVars')) -join '|') | Should -BeExactly "PSAvoidGlobalVars: excluded by 'PSAvoidGlobal*'"
        $r.Merged['IncludeDefaultRules'] | Should -BeTrue -Because 'K02 still applies'
    }

    It 'B1c-R02: a required custom rule named Module\Measure-Name is written into IncludeRules by its bare name -- beside the repository''s own IncludeRules, and with no settings file' {
        $r = Invoke-RtMerge (New-RtFile ("@{ IncludeRules = @('PSAvoidUsingCmdletAliases'); " + $script:MgCustom + '; IncludeDefaultRules = $true }')) @('B1c.Merge\Measure-B1cMerge')
        (@($r.Merged.IncludeRules) -join ',') | Should -BeExactly 'PSAvoidUsingCmdletAliases,Measure-B1cMerge'
        $n = Invoke-RtMerge '' @('B1c.Merge\Measure-B1cMerge', 'PSAvoidGlobalVars')
        @($n.Merged.IncludeRules)[-2] | Should -BeExactly 'Measure-B1cMerge'
        @($n.Merged.IncludeRules)[-1] | Should -BeExactly 'PSAvoidGlobalVars'
        $n.Text | Should -Not -Match ([regex]::Escape('B1c.Merge\'))
    }

    It 'B1c-R02: the repository''s exclusion of a required custom rule''s bare name is taken out (a pattern over it, beside the CustomRulePath that rule needs, is R01''s open case)' {
        $r = Invoke-RtMerge (New-RtFile ("@{ " + $script:MgCustom + "; ExcludeRules = @('Measure-B1cMerge', 'PSAvoidUsingWriteHost') }")) @('B1c.Merge\Measure-B1cMerge')
        (@($r.Merged.ExcludeRules) -join ',') | Should -BeExactly 'PSAvoidUsingWriteHost'
        $q = Invoke-RtMerge (New-RtFile ("@{ " + $script:MgCustom + "; ExcludeRules = @('B1c.Merge\Measure-B1cMerge', 'PSAvoidUsingWriteHost') }")) @('B1c.Merge\Measure-B1cMerge')
        (@($q.Merged.ExcludeRules) -join ',') | Should -BeExactly 'PSAvoidUsingWriteHost' -Because 'an entry naming the code as written is taken out, as before'
    }

    It 'B1c-R02 control: the bare spelling of a required custom rule merges as it did' {
        $r = Invoke-RtMerge (New-RtFile ("@{ IncludeRules = @('PSAvoidUsingCmdletAliases'); " + $script:MgCustom + '; IncludeDefaultRules = $true }')) @('Measure-B1cMerge')
        $r.Text | Should -BeExactly ($script:RtHead + "    IncludeRules = @('PSAvoidUsingCmdletAliases', 'Measure-B1cMerge')" + "`n" +
            '    ' + $script:MgCustom + "`n" + '    IncludeDefaultRules = $true' + "`n" + '}' + "`n")
        $k = Invoke-RtMerge (New-RtFile ('@{ ' + $script:MgCustom + ' }')) @('B1c.Merge\Measure-B1cMerge')
        $k.Merged.ContainsKey('IncludeDefaultRules') | Should -BeFalse -Because 'a required CUSTOM rule needs no built-in one (K02), qualified or not'
    }

    It 'B1c-R03: an accepted file whose IncludeRules has no entry keeps its rule set -- the merged file names no IncludeRules (<Form>)' -TestCases @(
        @{ Form = '@()' }
        @{ Form = '(@())' }
        @{ Form = '@(@())' }
    ) {
        param($Form)
        $repo = New-RtFile ('@{ IncludeRules = ' + $Form + '; Rules = @{ PSAvoidLongLines = @{ Enable = $true; MaximumLineLength = 40 } } }')
        (Read-PssaSettingsFile -Path $repo).Verdict | Should -BeExactly 'valid' -Because 'CONTROL: PSScriptAnalyzer accepts it'
        $r = Invoke-RtMerge $repo @('PSAvoidGlobalVars')
        (@($r.Merged.Keys | Sort-Object) -join ',') | Should -BeExactly 'Rules'
        $r.Text | Should -Not -Match 'IncludeRules'
        [int]$r.Merged.Rules['PSAvoidLongLines']['MaximumLineLength'] | Should -Be 40
        $r.Guard | Should -BeExactly 'not-needed'
        $o = Invoke-RtMerge $repo @('PSAvoidGlobalVars') -Tag 'v9.9.9'
        $o.Merged | Should -Not -Be $null -Because 'no pinned default list is used, so another PSES version does not decline'
    }

    It 'B1c-R03: beside a CustomRulePath, IncludeRules = @() keeps the custom rules, and K02 adds the built-in ones' {
        $r = Invoke-RtMerge (New-RtFile ("@{ IncludeRules = @(); " + $script:MgCustom + ' }')) @('PSAvoidGlobalVars')
        (@($r.Merged.Keys | Sort-Object) -join ',') | Should -BeExactly 'CustomRulePath,IncludeDefaultRules'
    }

    It 'B1c-RV04: a padded ExcludeRules entry is written exactly as the repository gave it, so it still names no rule once merged (<Name>)' -TestCases @(
        @{ Name = 'blanks on both sides'; Entry = ' PSAvoidUsingWriteHost ' }
        @{ Name = 'a blank before'; Entry = ' PSAvoidUsingWriteHost' }
        @{ Name = 'a blank after'; Entry = 'PSAvoidUsingWriteHost ' }
        @{ Name = 'a TAB after'; Entry = ('PSAvoidUsingWriteHost' + [char]9) }
    ) {
        param($Name, $Entry)
        # PSScriptAnalyzer reads a surrounding blank as a character to match (measured, both hosts): the entry
        # names no rule alone, and the merge wrote it trimmed -- PSAvoidUsingWriteHost then stopped running.
        $r = Invoke-RtMerge (New-RtFile ("@{ ExcludeRules = @('" + $Entry + "') }")) @('PSAvoidGlobalVars')
        @($r.Merged.ExcludeRules).Count | Should -Be 1
        [string]@($r.Merged.ExcludeRules)[0] | Should -BeExactly $Entry
        $r.Text | Should -Match ([regex]::Escape("ExcludeRules = @('" + $Entry + "')"))
    }

    It 'B1c-RV04: a padded pattern names no required rule as written, so it is written as given -- not narrowed to the built-in rules' {
        $r = Invoke-RtMerge (New-RtFile "@{ ExcludeRules = @(' PSAvoid* ', 'PSUse*') }") @('PSAvoidGlobalVars')
        (@($r.Merged.ExcludeRules) | ForEach-Object { '[' + $_ + ']' }) -join ',' | Should -BeExactly '[ PSAvoid* ],[PSUse*]'
    }

    It 'B1c-RV04: beside the repository''s own IncludeRules, and beside a CustomRulePath, a padded entry is written as given and shuts nothing out' {
        $o = Invoke-RtMerge (New-RtFile "@{ IncludeRules = @('PSAvoidUsingCmdletAliases'); ExcludeRules = @(' PSAvoidUsingCmdletAliases ') }") @('PSAvoidGlobalVars')
        (@($o.Merged.ExcludeRules) | ForEach-Object { '[' + $_ + ']' }) -join ',' | Should -BeExactly '[ PSAvoidUsingCmdletAliases ]'
        $c = Invoke-RtMerge (New-RtFile ("@{ " + $script:MgCustom + "; ExcludeRules = @(' PSAvoidGlobal* ') }")) @('PSAvoidGlobalVars')
        (@($c.Merged.ExcludeRules) | ForEach-Object { '[' + $_ + ']' }) -join ',' | Should -BeExactly '[ PSAvoidGlobal* ]'
        (@(Get-RequiredRulesNotRunnable -Settings $c.Merged -RequiredRules @('PSAvoidGlobalVars')) -join '|') | Should -BeExactly '' -Because 'the padded pattern names no rule, so the required one runs'
    }

    It 'B1c-RV04 control: an entry spelled like a required code is still taken out, padded or not, and blank entries are still dropped -- byte for byte as 491ecb5 and f5b46ec merged them (<Name>)' -TestCases @(
        @{ Name = 'a padded required name'; Text = "@{ ExcludeRules = @(' PSAvoidGlobalVars ', 'PSAvoidUsingWriteHost') }" }
        @{ Name = 'blank entries'; Text = "@{ ExcludeRules = @('', ' ', 'PSAvoidUsingWriteHost') }" }
    ) {
        param($Name, $Text)
        # Both name no rule to PSScriptAnalyzer, so taking them out changes nothing that runs; the text is the
        # one the exact-name control below pins (captured from 491ecb5's and f5b46ec's own functions, both hosts).
        Get-RtSha (Invoke-RtMerge (New-RtFile $Text) @('PSAvoidGlobalVars')).Text | Should -BeExactly '0cfc858e3bad2114c4afb4441945c87729a105497868cb66f6e18b11f65808a9' -Because $Name
    }

    It 'B1c controls: the shapes these routes do not touch merge byte for byte as f5b46ec did (<Name>)' -TestCases @(
        @{ Name = 'an exact required name in ExcludeRules'; Text = "@{ ExcludeRules = @('PSAvoidGlobalVars', 'PSAvoidUsingWriteHost') }"; Required = @('PSAvoidGlobalVars'); Sha = '0cfc858e3bad2114c4afb4441945c87729a105497868cb66f6e18b11f65808a9' }
        @{ Name = 'the same in lower case'; Text = "@{ ExcludeRules = @('psavoidglobalvars', 'PSAvoidUsingCmdletAliases') }"; Required = @('PSAvoidGlobalVars'); Sha = 'd963b7292ad9a4dbfb848552345a90e173e69988d659d2931a240b0f0d21be78' }
        @{ Name = 'a pattern that names no required rule, beside own IncludeRules'; Text = "@{ IncludeRules = @('PSAvoidUsingCmdletAliases'); ExcludeRules = @('PSUse*', 'PSAvoidUsingWriteHost') }"; Required = @('PSAvoidGlobalVars'); Sha = '8da528a8684df5e1a633512f579467865c516bac055b7b3078373075d941b106' }
        @{ Name = 'a list of one blank IncludeRules entry'; Text = "@{ IncludeRules = @('') }"; Required = @('PSAvoidGlobalVars'); Sha = 'bbb41a7182771d736c01e571291b223a6da92a890fe3b222719642067d320628' }
        @{ Name = 'a REJECTED file whose IncludeRules has no entry'; Text = "@{ IncludeRules = @(); ExcludeRules = @('PSAvoidUsingWriteHost'); RuleArguments = @{ X = @{ Enable = `$true } } }"; Required = @('PSAvoidGlobalVars'); Sha = '71a10fb1c77bb90910ad0c89ccc0be0932c501befd2594f0d1edaf4a8aae4dd3' }
        @{ Name = 'two required rules beside own IncludeRules'; Text = "@{ IncludeRules = @('PSAvoidUsingCmdletAliases'); ExcludeRules = @('PSAvoidLongLines') }"; Required = @('PSAvoidGlobalVars', 'PSAvoidLongLines'); Sha = '92ab5485203ab125820618cbec67e53f88adfcfcf80490bfd3a4e76a8fd096c1' }
        @{ Name = 'no settings file'; Text = ''; Required = @('PSAvoidGlobalVars'); Sha = '866b8a5d243638d540387f324439311e02a3852c4732b9ffe39ebf9406985280' }
    ) {
        param($Name, $Text, $Required, $Sha)
        $repo = if ($Text -ne '') { New-RtFile $Text } else { '' }
        Get-RtSha (Invoke-RtMerge $repo $Required).Text | Should -BeExactly $Sha -Because $Name
    }
}

Describe 'The merged settings, judged by the vendored PSScriptAnalyzer: the repository''s rules and the required one run, and what its pattern excluded stays excluded (dispatch 000307 B1c)' -Skip:$script:RtUnsupported {

    BeforeAll {
        $script:JgManifest = Get-RtVendoredManifest
        $script:JgDir = Join-Path $TestDrive 'judged'
        New-Item -ItemType Directory -Force -Path $script:JgDir | Out-Null
        $enc = New-Object System.Text.UTF8Encoding($false)
        $script:JgModule = New-RtRuleModule 'B1c.Judged' 'Measure-B1cJudged'
        $script:JgRule = 'B1c.Judged\Measure-B1cJudged'
        $cp = "CustomRulePath = @('" + $script:JgModule + "')"
        # The sample draws PSAvoidGlobalVars, PSAvoidUsingCmdletAliases, PSAvoidUsingWriteHost, PSUseSingularNouns,
        # PSAvoidTrailingWhitespace and PSMisleadingBacktick; a 62-column line for a PSAvoidLongLines at 40, and
        # a 132-column one for the default 120.
        [System.IO.File]::WriteAllText((Join-Path $script:JgDir 'code.txt'), ("function Get-Items { param() Write-Host 'x' }`ngci`n`$global:jg = 1`n# " + ('x' * 130) + "`nWrite-Output 'a' `` `n'b'`n"), $enc)
        $script:JgCases = [ordered]@{
            'r01-psavoid'        = @("@{ ExcludeRules = @('PSAvoid*') }", @('PSAvoidGlobalVars'))
            'r01-star'           = @("@{ ExcludeRules = @('*') }", @('PSAvoidGlobalVars'))
            'r01-own-include'    = @("@{ IncludeRules = @('PSAvoidUsingCmdletAliases', 'PSAvoidGlobalVars'); ExcludeRules = @('PSAvoidGlobal*') }", @('PSAvoidGlobalVars'))
            'r01-configurable'   = @("@{ ExcludeRules = @('PSAvoidLong*', 'PSAvoidUsing*') }", @('PSAvoidLongLines'))
            'r01-kelvin'         = @(("@{ ExcludeRules = @('PSMisleadingBac" + [char]0x212A + "tick') }"), @('PSMisleadingBacktick'))
            'r02-own-include'    = @(("@{ IncludeRules = @('PSAvoidUsingCmdletAliases'); " + $cp + '; IncludeDefaultRules = $true }'), @($script:JgRule))
            'r02-own-include-nd' = @(("@{ IncludeRules = @('PSAvoidUsingCmdletAliases'); " + $cp + ' }'), @($script:JgRule, 'PSAvoidGlobalVars'))
            'r02-bare-excluded'  = @(("@{ " + $cp + "; ExcludeRules = @('Measure-B1cJudged') }"), @($script:JgRule))
            'r02-pattern-noncustom' = @(("@{ ExcludeRules = @('Measure-*', 'PSAvoidUsingWriteHost') }"), @('PSAvoidGlobalVars'))
            'r03-empty'          = @("@{ IncludeRules = @(); Rules = @{ PSAvoidLongLines = @{ Enable = `$true; MaximumLineLength = 40 } } }", @('PSAvoidGlobalVars'))
            'r03-empty-custom'   = @(("@{ IncludeRules = @(); " + $cp + ' }'), @('PSAvoidGlobalVars'))
            'open-custom-path'   = @(("@{ " + $cp + "; ExcludeRules = @('PSAvoidGlobal*') }"), @('PSAvoidGlobalVars'))
            # B1c-RV-04: padded entries, which name no rule to PSScriptAnalyzer.
            'rv04-padded-exact'  = @("@{ ExcludeRules = @(' PSAvoidUsingWriteHost ') }", @('PSAvoidGlobalVars'))
            'rv04-padded-pattern' = @("@{ ExcludeRules = @(' PSAvoid* ') }", @('PSAvoidGlobalVars'))
            'rv04-padded-own-include' = @("@{ IncludeRules = @('PSAvoidUsingCmdletAliases'); ExcludeRules = @(' PSAvoidUsingCmdletAliases ') }", @('PSAvoidGlobalVars'))
        }
        $encBom = New-Object System.Text.UTF8Encoding($true)
        foreach ($k in @($script:JgCases.Keys)) {
            $repo = New-RtFile $script:JgCases[$k][0] -Bom:($k -eq 'r01-kelvin')
            [System.IO.File]::WriteAllText((Join-Path $script:JgDir ($k + '.alone.psd1')), $script:JgCases[$k][0], $(if ($k -eq 'r01-kelvin') { $encBom } else { $enc }))
            $m = Merge-RequiredRulesSettings -ResolvedSettingsPath $repo -RequiredRules $script:JgCases[$k][1] -CurrentPsesTag 'v4.6.0'
            [System.IO.File]::WriteAllText((Join-Path $script:JgDir ($k + '.psd1')), (Get-RtText $m), $enc)
        }
        $script:Jg = @{}
        if (-not [string]::IsNullOrWhiteSpace($script:JgManifest)) { $script:Jg = Invoke-RtJudge -Manifest $script:JgManifest -Dir $script:JgDir }
        function Test-RtExactlyAloneAnd([string]$Case, [string[]]$Added) {
            # The merged file runs EXACTLY what the repository's file runs alone, plus $Added: nothing the
            # repository ran is lost, and nothing it excluded comes back.
            $want = @(@($script:Jg[$Case + '.alone']) + $Added | Sort-Object -Unique)
            (@($script:Jg[$Case] | Sort-Object -Unique) -join ',') | Should -BeExactly ($want -join ',') -Because ('alone: ' + (@($script:Jg[$Case + '.alone']) -join ','))
        }
    }

    It 'the vendored analyzer judged every file (this Describe cannot pass vacuously)' {
        $script:JgManifest | Should -Not -BeNullOrEmpty
        $script:Jg.Count | Should -Be (2 * $script:JgCases.Count)
    }

    It 'B1c-R01: judged -- ExcludeRules ''PSAvoid*'': every PSAvoid rule the file excluded stays excluded, and the required PSAvoidGlobalVars runs' {
        @($script:Jg['r01-psavoid.alone']) | Should -Contain 'PSUseSingularNouns' -Because 'CONTROL: the file alone runs the rules its pattern does not name'
        @($script:Jg['r01-psavoid.alone']) | Should -Not -Contain 'PSAvoidUsingWriteHost' -Because 'CONTROL: the pattern excludes it'
        Test-RtExactlyAloneAnd 'r01-psavoid' @('PSAvoidGlobalVars')
    }

    It 'B1c-R01: judged -- ExcludeRules ''*'': the file alone runs nothing; merged, the required rule alone runs' {
        @($script:Jg['r01-star.alone']).Count | Should -Be 0
        (@($script:Jg['r01-star']) -join ',') | Should -BeExactly 'PSAvoidGlobalVars'
    }

    It 'B1c-R01: judged -- a pattern beside the repository''s own IncludeRules, and one over a required configurable rule' {
        Test-RtExactlyAloneAnd 'r01-own-include' @('PSAvoidGlobalVars')
        Test-RtExactlyAloneAnd 'r01-configurable' @('PSAvoidLongLines')
        @($script:Jg['r01-configurable']) | Should -Not -Contain 'PSAvoidUsingCmdletAliases' -Because 'PSAvoidUsing* still excludes it'
    }

    It 'B1c-R01: judged -- an exact entry with the Kelvin sign no longer keeps PSMisleadingBacktick off' {
        @($script:Jg['r01-kelvin.alone']) | Should -Not -Contain 'PSMisleadingBacktick' -Because 'CONTROL: the analyzer folds the Kelvin sign to k'
        Test-RtExactlyAloneAnd 'r01-kelvin' @('PSMisleadingBacktick')
    }

    It 'B1c-R02: judged -- a required custom rule named Module\Measure-Name runs beside the repository''s own IncludeRules, with and without IncludeDefaultRules' {
        @($script:Jg['r02-own-include']) | Should -Contain $script:JgRule
        @($script:Jg['r02-own-include']) | Should -Contain 'PSAvoidUsingCmdletAliases'
        @($script:Jg['r02-own-include-nd']) | Should -Contain $script:JgRule
        @($script:Jg['r02-own-include-nd']) | Should -Contain 'PSAvoidGlobalVars'
    }

    It 'B1c-R02: judged -- the repository''s exclusion of its bare name no longer keeps it off' {
        @($script:Jg['r02-bare-excluded.alone']).Count | Should -Be 0 -Because 'CONTROL: the file alone loads only the custom rule and excludes it'
        (@($script:Jg['r02-bare-excluded']) -join ',') | Should -BeExactly $script:JgRule
    }

    It 'B1c-R01 control: a pattern that names no required rule is kept as written, and the merged file runs exactly what the file runs alone' {
        Test-RtExactlyAloneAnd 'r02-pattern-noncustom' @()
    }

    It 'B1c-R03: judged -- IncludeRules = @() runs every rule the file runs alone, the required one included; beside a CustomRulePath its custom rule too' {
        @($script:Jg['r03-empty.alone']) | Should -Contain 'PSAvoidLongLines' -Because 'CONTROL: the file alone runs every enabled rule'
        Test-RtExactlyAloneAnd 'r03-empty' @('PSAvoidGlobalVars')
        @($script:Jg['r03-empty-custom']) | Should -Contain $script:JgRule
        @($script:Jg['r03-empty-custom']) | Should -Contain 'PSAvoidGlobalVars'
    }

    It 'B1c-RV03 control: judged -- beside a CustomRulePath the kept pattern still shuts the required rule out, and the static check says so (so a managed scan refuses it)' {
        @($script:Jg['open-custom-path']) | Should -Not -Contain 'PSAvoidGlobalVars'
        $m = Read-PssaSettingsFile -Path (Join-Path $script:JgDir 'open-custom-path.psd1')
        @(Get-RequiredRulesNotRunnable -Settings $m.Entries -RequiredRules @('PSAvoidGlobalVars')).Count | Should -Be 1
    }

    It 'B1c-RV04: judged -- a padded ExcludeRules entry excluded nothing alone, and merged it still excludes nothing: the merged file runs exactly what the file runs, the required rule included' {
        @($script:Jg['rv04-padded-exact.alone']) | Should -Contain 'PSAvoidUsingWriteHost' -Because 'CONTROL: the padded entry names no rule alone'
        @($script:Jg['rv04-padded-pattern.alone']) | Should -Contain 'PSAvoidUsingCmdletAliases' -Because 'CONTROL: the padded pattern names no rule alone'
        @($script:Jg['rv04-padded-own-include.alone']) | Should -Contain 'PSAvoidUsingCmdletAliases' -Because 'CONTROL: the padded exclusion does not beat the repository''s own IncludeRules'
        Test-RtExactlyAloneAnd 'rv04-padded-exact' @('PSAvoidGlobalVars')
        Test-RtExactlyAloneAnd 'rv04-padded-pattern' @('PSAvoidGlobalVars')
        Test-RtExactlyAloneAnd 'rv04-padded-own-include' @('PSAvoidGlobalVars')
    }
}

Describe 'A required rule the merged settings cannot run is named (dispatch 000307 B1c, review findings B1b-OOB2-R04 and B1b-OOB2-R01)' {

    BeforeAll {
        $script:NrModule = New-RtRuleModule 'B1c.Static' 'Measure-B1cStatic'
        function Get-RtNr($Settings, [string[]]$Required, [string[]]$OrgExclude = @()) {
            return (@(Get-RequiredRulesNotRunnable -Settings $Settings -RequiredRules $Required -OrgExcludeRules $OrgExclude) -join '|')
        }
    }

    It 'B1c-R04: a misspelled built-in name, a custom rule with no CustomRulePath, and a code naming nothing have no rule behind them' {
        $m = Merge-RequiredRulesSettings -ResolvedSettingsPath '' -RequiredRules @('PSAvoidGlobalVarz', 'B1c.Static\Measure-B1cStatic', 'Measure-Bare', 'B1c.Static\', 'PSAvoidGlobalVars') -CurrentPsesTag 'v4.6.0'
        Get-RtNr $m @('PSAvoidGlobalVarz', 'B1c.Static\Measure-B1cStatic', 'Measure-Bare', 'B1c.Static\', 'PSAvoidGlobalVars') |
            Should -BeExactly 'PSAvoidGlobalVarz: no rule of that name|B1c.Static\Measure-B1cStatic: no rule of that name|Measure-Bare: no rule of that name|B1c.Static\: no rule of that name'
    }

    It 'B1c-R04: beside a CustomRulePath a code that is not a built-in rule is not reported -- whether the modules hold it is A3''s runtime signal' {
        $s = @{ CustomRulePath = @($script:NrModule); IncludeDefaultRules = $true }
        Get-RtNr $s @('B1c.Static\Measure-B1cStatic', 'B1c.Static\Measure-NotThere', 'PSAvoidGlobalVarz') | Should -BeExactly ''
        Get-RtNr $s @('B1c.Static\') | Should -BeExactly 'B1c.Static\: no rule of that name' -Because 'a code naming nothing can never run'
    }

    It 'an ExcludeRules entry that matches, an IncludeRules that does not select, and built-in rules not loaded beside a CustomRulePath are each named' {
        Get-RtNr @{ ExcludeRules = @('PSUse*', 'PSAvoid*') } @('PSAvoidGlobalVars') | Should -BeExactly "PSAvoidGlobalVars: excluded by 'PSAvoid*'"
        Get-RtNr @{ IncludeRules = @('PSAvoidUsingCmdletAliases') } @('PSAvoidGlobalVars') | Should -BeExactly 'PSAvoidGlobalVars: not in IncludeRules'
        Get-RtNr @{ IncludeRules = @('') } @('PSAvoidGlobalVars') | Should -BeExactly 'PSAvoidGlobalVars: not in IncludeRules' -Because 'a blank entry selects nothing (measured)'
        Get-RtNr @{ IncludeRules = @() } @('PSAvoidGlobalVars') | Should -BeExactly '' -Because 'an IncludeRules with no entry selects every rule (measured)'
        Get-RtNr @{ CustomRulePath = @($script:NrModule) } @('PSAvoidGlobalVars') | Should -BeExactly 'PSAvoidGlobalVars: built-in rules not loaded'
        Get-RtNr @{ CustomRulePath = @($script:NrModule); IncludeDefaultRules = $false } @('PSAvoidGlobalVars') | Should -BeExactly 'PSAvoidGlobalVars: built-in rules not loaded'
        Get-RtNr @{ IncludeRules = @('Measure-B1c*'); CustomRulePath = @($script:NrModule) } @('B1c.Static\Measure-B1cStatic') | Should -BeExactly '' -Because 'a pattern over the bare name selects it'
    }

    It 'a rule the organization also excludes is not required, and is not reported; a code named twice is reported once' {
        Get-RtNr @{ ExcludeRules = @('PSAvoidGlobalVars') } @('PSAvoidGlobalVars') @('PSAvoidGlobalVars') | Should -BeExactly ''
        Get-RtNr @{} @('PSAvoidGlobalVarz', ' PSAvoidGlobalVarz ') | Should -BeExactly 'PSAvoidGlobalVarz: no rule of that name'
        @(Get-RequiredRulesNotRunnable -Settings @{} -RequiredRules @()).Count | Should -Be 0
        @(Get-RequiredRulesNotRunnable -Settings $null -RequiredRules @('PSAvoidGlobalVars')).Count | Should -Be 0
    }

    It 'THE CONTROL: every merge of a required BUILT-IN rule this leg and B1b produce can run it -- the merge''s own output reports nothing' {
        $custom = "CustomRulePath = @('" + $script:NrModule + "')"
        foreach ($t in @('', "@{ ExcludeRules = @('PSAvoid*') }", "@{ ExcludeRules = @('*') }", "@{ IncludeRules = @('PSAvoidUsingCmdletAliases'); ExcludeRules = @('PSAvoidGlobal*') }",
                "@{ IncludeRules = @() }", "@{ IncludeRules = @('') }", "@{ Rules = @{ PSAvoidGlobalVars = @{ Enable = `$false } } }", ('@{ ' + $custom + ' }'),
                ('@{ ' + $custom + '; IncludeDefaultRules = $false }'), "@{ IncludeRules = @('PSAvoidUsingCmdletAliases'); ExcludeRules = @('psavoidglobalvars') }")) {
            $repo = if ($t -ne '') { New-RtFile $t } else { '' }
            $m = Merge-RequiredRulesSettings -ResolvedSettingsPath $repo -RequiredRules @('PSAvoidGlobalVars', 'PSAvoidLongLines') -CurrentPsesTag 'v4.6.0'
            $p = Write-MergedPssaSettingsFile -Settings $m -DataRoot (Join-Path $TestDrive ('nr-' + [guid]::NewGuid().ToString('N').Substring(0, 8)))
            $back = Read-PssaSettingsFile -Path $p
            $back.Verdict | Should -BeExactly 'valid' -Because $t
            Get-RtNr $back.Entries @('PSAvoidGlobalVars', 'PSAvoidLongLines') | Should -BeExactly '' -Because ('repository file: ' + $t)
        }
    }
}

Describe 'A required configurable built-in rule is switched on however RequiredRules spells it, and the static check names one the merged Rules do not switch on (dispatch 000307 B1c correction round 2, review finding B1c-RR-01)' {

    BeforeAll {
        # Owner ruling RR-01 as amended (2026-10-18): the merge hands the Enable step a code's match name where that
        # names a configurable built-in rule, and every other code as written; the static check names a required
        # configurable built-in rule whose Rules entry under its canonical name does not set Enable = $true.
        function Invoke-RrMerge([string]$Repo, [string[]]$Required) {
            $m = Merge-RequiredRulesSettings -ResolvedSettingsPath $Repo -RequiredRules $Required -CurrentPsesTag 'v4.6.0'
            return @{ Merged = $m; Text = (Get-RtText $m) }
        }
        function Get-RrNr($Settings, [string[]]$Required) {
            return (@(Get-RequiredRulesNotRunnable -Settings $Settings -RequiredRules $Required) -join '|')
        }
        $script:RrDisabled = "@{ Rules = @{ PSUseSingularNouns = @{ Enable = `$false } } }"
    }

    It 'B1c-RR01: off by default and named Module\Name with no settings file, the rule is switched on by its match name -- byte for byte as its bare spelling (it was named in IncludeRules and never switched on)' {
        $q = Invoke-RrMerge '' @('Foo\PSAvoidLongLines')
        $q.Text | Should -BeExactly (Invoke-RrMerge '' @('PSAvoidLongLines')).Text
        $q.Merged.Rules['PSAvoidLongLines']['Enable'] | Should -BeTrue
        $l = Invoke-RrMerge '' @('Foo\psavoidlonglines')
        (@($l.Merged.Rules.Keys) -ccontains 'PSAvoidLongLines') | Should -BeTrue -Because 'under its canonical key, the one PSScriptAnalyzer matches (case-sensitively)'
    }

    It 'B1c-RR01: on by default and named Module\Name over a repository Rules entry with Enable = $false, the rule is switched on -- byte for byte as its bare spelling (the repository''s $false was kept)' {
        $repo = New-RtFile $script:RrDisabled
        $q = Invoke-RrMerge $repo @('X\PSUseSingularNouns')
        $q.Text | Should -BeExactly (Invoke-RrMerge $repo @('PSUseSingularNouns')).Text
        $q.Merged.Rules['PSUseSingularNouns']['Enable'] | Should -BeTrue
    }

    It 'B1c-RR01 control: the bare spellings, and a required custom rule''s Enable (owner amendment: still forced only under the key the repository wrote), merge byte for byte as d7cf111 did (<Name>)' -TestCases @(
        @{ Name = 'PSAvoidLongLines, no settings file'; Text = ''; Required = @('PSAvoidLongLines'); Sha = 'dc1e694887b1aedab1b1fbd9667aef79737c2c30552666cbe91139a673590c6e' }
        @{ Name = 'PSUseSingularNouns over Enable = $false'; Text = "@{ Rules = @{ PSUseSingularNouns = @{ Enable = `$false } } }"; Required = @('PSUseSingularNouns'); Sha = 'c57939f1d54d85494afe6a4b838beeb935c184813810341a9bedbe089367a90b' }
        @{ Name = 'a custom rule keyed Module\Name: switched on'; Text = "@{ Rules = @{ 'My.Rules\Measure-Thing' = @{ Enable = `$false; Limit = 3 } } }"; Required = @('My.Rules\Measure-Thing'); Sha = 'd63dce93fab4b67bb1d3f0af6c0bc6fb18806926f2621db8ddaa8446a48704d4' }
        @{ Name = 'a custom rule keyed by its bare name: left as written'; Text = "@{ Rules = @{ 'Measure-Thing' = @{ Enable = `$false; Limit = 3 } } }"; Required = @('My.Rules\Measure-Thing'); Sha = '78a2ff2278c413877a11b67b75735816aaf87fe81be821059f270d38c488e30a' }
    ) {
        param($Name, $Text, $Required, $Sha)
        # Captured from d7cf111's own functions and from this head's, on both hosts (identical).
        $repo = if ($Text -ne '') { New-RtFile $Text } else { '' }
        Get-RtSha (Invoke-RrMerge $repo $Required).Text | Should -BeExactly $Sha -Because $Name
    }

    It 'B1c-RR01: the static check names a required configurable built-in rule the Rules do not switch on, however RequiredRules spells it -- no entry, Enable = $false, an entry keyed in another case' {
        Get-RrNr @{} @('Foo\PSAvoidLongLines') | Should -BeExactly 'Foo\PSAvoidLongLines: not enabled in Rules'
        Get-RrNr @{ Rules = @{ PSUseSingularNouns = @{ Enable = $false } } } @('X\PSUseSingularNouns', 'PSUseSingularNouns') |
            Should -BeExactly 'X\PSUseSingularNouns: not enabled in Rules|PSUseSingularNouns: not enabled in Rules'
        Get-RrNr @{ Rules = @{ psavoidlonglines = @{ Enable = $true } } } @('PSAvoidLongLines') | Should -BeExactly 'PSAvoidLongLines: not enabled in Rules' -Because 'PSScriptAnalyzer matches a Rules key case-sensitively (measured, dispatch 000306): that entry configures nothing'
    }

    It 'B1c-RR01 control: Enable = $true under the canonical key -- the setting named in any case -- is not named, nor a rule the organization also excludes, nor one that is not configurable' {
        Get-RrNr @{ Rules = @{ PSAvoidLongLines = @{ Enable = $true; MaximumLineLength = 40 } } } @('Foo\PSAvoidLongLines', 'PSAvoidLongLines') | Should -BeExactly ''
        Get-RrNr @{ Rules = @{ PSUseSingularNouns = @{ enable = $true } } } @('X\PSUseSingularNouns') | Should -BeExactly ''
        @(Get-RequiredRulesNotRunnable -Settings @{} -RequiredRules @('PSAvoidLongLines') -OrgExcludeRules @('PSAvoidLongLines')).Count | Should -Be 0
        Get-RrNr @{} @('PSAvoidGlobalVars', 'Foo\PSAvoidGlobalVars') | Should -BeExactly ''
    }

    It 'B1c-RR01 control: every merge of a required configurable rule, however RequiredRules spells it, can run it -- the merge''s own output, written and read back, names nothing' {
        $module = New-RtRuleModule 'B1c.RR01' 'Measure-B1cRR01'
        $custom = "CustomRulePath = @('" + $module + "')"
        $req = @('Foo\PSAvoidLongLines', 'X\PSUseSingularNouns', 'PSAvoidGlobalVars')
        foreach ($t in @('', $script:RrDisabled, "@{ Rules = @{ psavoidlonglines = @{ Enable = `$false; MaximumLineLength = 40 } } }", "@{ ExcludeRules = @('PSAvoidLong*') }",
                "@{ IncludeRules = @('PSAvoidUsingCmdletAliases') }", "@{ IncludeRules = @() }", ('@{ ' + $custom + ' }'), ('@{ ' + $custom + '; IncludeDefaultRules = $false }'))) {
            $repo = if ($t -ne '') { New-RtFile $t } else { '' }
            $m = Merge-RequiredRulesSettings -ResolvedSettingsPath $repo -RequiredRules $req -CurrentPsesTag 'v4.6.0'
            $p = Write-MergedPssaSettingsFile -Settings $m -DataRoot (Join-Path $TestDrive ('rr-' + [guid]::NewGuid().ToString('N').Substring(0, 8)))
            $back = Read-PssaSettingsFile -Path $p
            $back.Verdict | Should -BeExactly 'valid' -Because $t
            Get-RrNr $back.Entries $req | Should -BeExactly '' -Because ('repository file: ' + $t)
        }
    }

    Context 'judged by the vendored PSScriptAnalyzer' -Skip:$script:RtUnsupported {

        BeforeAll {
            $script:RjManifest = Get-RtVendoredManifest
            $script:RjDir = Join-Path $TestDrive 'rr01-judged'
            New-Item -ItemType Directory -Force -Path $script:RjDir | Out-Null
            $enc = New-Object System.Text.UTF8Encoding($false)
            # The sample draws PSUseSingularNouns (a plural noun), PSAvoidUsingCmdletAliases and, with the rule on,
            # PSAvoidLongLines (a 132-column line; the default limit is 120).
            [System.IO.File]::WriteAllText((Join-Path $script:RjDir 'code.txt'), ("function Get-Items { param() Write-Host 'x' }`ngci`n# " + ('x' * 130) + "`n"), $enc)
            $repo = New-RtFile $script:RrDisabled
            [System.IO.File]::WriteAllText((Join-Path $script:RjDir 'rr01-nouns.alone.psd1'), $script:RrDisabled, $enc)
            foreach ($c in @(@('rr01-qual-long', '', 'Foo\PSAvoidLongLines'), @('rr01-canon-long', '', 'PSAvoidLongLines'),
                    @('rr01-qual-nouns', $repo, 'X\PSUseSingularNouns'), @('rr01-canon-nouns', $repo, 'PSUseSingularNouns'))) {
                [System.IO.File]::WriteAllText((Join-Path $script:RjDir ($c[0] + '.psd1')), (Invoke-RrMerge $c[1] @($c[2])).Text, $enc)
            }
            $script:Rj = @{}
            if (-not [string]::IsNullOrWhiteSpace($script:RjManifest)) { $script:Rj = Invoke-RtJudge -Manifest $script:RjManifest -Dir $script:RjDir }
        }

        It 'the vendored analyzer judged every file (this Context cannot pass vacuously)' {
            $script:RjManifest | Should -Not -BeNullOrEmpty
            $script:Rj.Count | Should -Be 5
        }

        It 'B1c-RR01: judged -- named Module\Name, PSAvoidLongLines runs with no settings file and PSUseSingularNouns over the repository''s Enable = $false, exactly as their bare spellings do (neither ran)' {
            @($script:Rj['rr01-qual-long']) | Should -Contain 'PSAvoidLongLines'
            (@($script:Rj['rr01-qual-long']) -join ',') | Should -BeExactly (@($script:Rj['rr01-canon-long']) -join ',')
            @($script:Rj['rr01-qual-nouns']) | Should -Contain 'PSUseSingularNouns'
            (@($script:Rj['rr01-qual-nouns']) -join ',') | Should -BeExactly (@($script:Rj['rr01-canon-nouns']) -join ',')
        }

        It 'B1c-RR01 control: judged -- the bare spellings run the rule, and the repository''s file alone keeps PSUseSingularNouns off' {
            @($script:Rj['rr01-canon-long']) | Should -Contain 'PSAvoidLongLines'
            @($script:Rj['rr01-canon-nouns']) | Should -Contain 'PSUseSingularNouns'
            @($script:Rj['rr01-nouns.alone']) | Should -Not -Contain 'PSUseSingularNouns'
            @($script:Rj['rr01-nouns.alone']) | Should -Contain 'PSAvoidUsingCmdletAliases' -Because 'CONTROL: the file alone runs the other rules'
        }
    }
}

Describe 'The daemon records a required rule it cannot run, the evidence consumers carry it, and a managed verdict refuses it (dispatch 000307 B1c, review finding B1b-OOB2-R04; correction round 1, B1c-RV-01 to RV-03)' {

    BeforeAll {
        # The daemon's OWN functions, lifted from scripts/pses-daemon.ps1 by AST, PSES stubbed -- as the B1b
        # daemon layer does (PowerShellLsp.PolicySettings.Tests.ps1).
        $daemonAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RtScripts 'pses-daemon.ps1'), [ref]$null, [ref]$null)
        foreach ($name in @('Initialize-PssaSettings', 'Reset-PsesState')) {
            $fn = $daemonAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
            if ($null -eq $fn) { throw ('pses-daemon.ps1 has no ' + $name) }
            . ([scriptblock]::Create([string]$fn.Extent.Text))
        }
        $top = @($daemonAst.EndBlock.Statements | Where-Object {
                $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$script:policyApplication' })
        if ($top.Count -ne 1) { throw ('pses-daemon.ps1 must build ONE top-level startup record; found ' + $top.Count) }
        $script:DcStartup = [scriptblock]::Create('param($OrgPolicyPath) ' + $top[0].Right.Extent.Text)
        function Write-DLog { param([string]$m) [void]$script:DcLog.Add($m) }
        function Send-Lsp { param($obj) [void]$script:DcSent.Add($obj) }
        function Get-DaemonPsesVersionTag { return 'v4.6.0' }
        function Reset-DcDaemon([string]$Policy = '') {
            $script:OrgPolicyPath = $Policy
            $script:SettingsPath = ''
            $script:Ruleset = 'pses-default'
            $script:DataRoot = Join-Path $TestDrive ('dc-data-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Force -Path $script:DataRoot | Out-Null
            $script:settingsResolved = $false
            $script:settingsPathInUse = ''
            $script:buf = New-Object System.Collections.Generic.List[byte]
            $script:DcLog = New-Object System.Collections.ArrayList
            $script:DcSent = New-Object System.Collections.ArrayList
            $script:policyApplication = & $script:DcStartup $Policy
        }
        function New-DcRepo([string]$Settings = '') {
            $d = Join-Path $TestDrive ('dc-repo-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Force -Path $d | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $d 'thing.ps1'), "gci`n")
            if ($Settings -ne '') { [System.IO.File]::WriteAllText((Join-Path $d 'PSScriptAnalyzerSettings.psd1'), $Settings) }
            return $d
        }
        $script:DcModule = New-RtRuleModule 'B1c.Daemon' 'Measure-B1cDaemon'
        $script:DcTypo = New-RtFile "@{ RequiredRules = @('PSAvoidGlobalVarz', 'PSAvoidGlobalVars') }" -Name 'org-typo.psd1'
        $script:DcGood = New-RtFile "@{ RequiredRules = @('PSAvoidGlobalVars') }" -Name 'org-good.psd1'
        $script:DcDeclared = Resolve-EffectivePolicy -Path $script:DcTypo -Source 'cli'
        $script:DcGoodDeclared = Resolve-EffectivePolicy -Path $script:DcGood -Source 'cli'
        function New-DcFile($Daemon, $Declared = $script:DcDeclared, [string]$PolicyPath = $script:DcTypo) {
            # One file's evidence as the scan reads it back: the daemon record given, a client agreeing.
            $client = New-PolicyAdjudicationEvidence -Resolution $Declared -Path $PolicyPath -Mode 'closed'
            $receipt = [ordered]@{
                engine = [ordered]@{ pses = '4.6.0'; pssa = '1.25.0' }
                config = [ordered]@{ state = 'unbound'; observed = [ordered]@{ severityThreshold = 'Hint'; ruleInclude = ''; ruleExclude = ''; perFileCap = 0 } }
                policy = [ordered]@{ state = 'observed'; client = $client; daemon = $Daemon }
            }
            return [pscustomobject]@{ File = 'C:\x.ps1'; Completeness = 'complete'; Pass = 'pssa'; Receipt = (($receipt | ConvertTo-Json -Depth 8) | ConvertFrom-Json) }
        }
    }

    It 'B1c-R04: a required code with no rule behind it is recorded in requiredRules.cannotRun and logged as a warning; the merge is still activated' {
        Reset-DcDaemon -Policy $script:DcTypo
        $repo = New-DcRepo
        Initialize-PssaSettings -FilePath (Join-Path $repo 'thing.ps1') -ProjectRoot $repo
        $script:policyApplication.requiredRules.state | Should -BeExactly 'activated'
        (@($script:policyApplication.requiredRules.cannotRun) -join '|') | Should -BeExactly 'PSAvoidGlobalVarz: no rule of that name'
        (@($script:DcLog) -join "`n") | Should -Match 'WARNING -- a required rule cannot run under the merged settings: PSAvoidGlobalVarz: no rule of that name'
    }

    It 'B1c-RV03: a repository pattern the merge keeps beside a CustomRulePath is recorded as excluding the required rule, and a managed verdict over that record is NOT CERTIFIED (policy-required-rule-cannot-run; it certified)' {
        # Owner ruling RV-03 (dispatch 000307, correction round 1): refuse with the R04 code, rather than narrow.
        Reset-DcDaemon -Policy $script:DcGood
        $repo = New-DcRepo ("@{ CustomRulePath = @('" + $script:DcModule + "'); ExcludeRules = @('PSAvoidGlobal*') }")
        Initialize-PssaSettings -FilePath (Join-Path $repo 'thing.ps1') -ProjectRoot $repo
        (@($script:policyApplication.requiredRules.cannotRun) -join '|') | Should -BeExactly "PSAvoidGlobalVars: excluded by 'PSAvoidGlobal*'"
        $daemon = Copy-PolicyApplicationEvidence -Evidence $script:policyApplication -SettingsSha256 (Get-PolicyFileSha256 -Path ([string]$script:settingsPathInUse))
        $c = Test-ScanPolicyCertification -Mode 'closed' -Declared $script:DcGoodDeclared -Files @((New-DcFile $daemon $script:DcGoodDeclared $script:DcGood))
        $c.Certified | Should -BeFalse -Because 'the required rule never ran'
        (@($c.Files[0].Reasons) -join ',') | Should -BeExactly 'policy-required-rule-cannot-run'
    }

    It 'THE CONTROL: a required rule the merged settings can run leaves cannotRun empty, and the startup and re-spawn records carry an empty list' {
        Reset-DcDaemon -Policy $script:DcGood
        @($script:policyApplication.requiredRules.cannotRun).Count | Should -Be 0 -Because 'the startup record'
        $repo = New-DcRepo "@{ ExcludeRules = @('PSAvoid*') }"
        Initialize-PssaSettings -FilePath (Join-Path $repo 'thing.ps1') -ProjectRoot $repo
        $script:policyApplication.requiredRules.state | Should -BeExactly 'activated'
        @($script:policyApplication.requiredRules.cannotRun).Count | Should -Be 0 -Because 'the pattern was narrowed (R01)'
        (@($script:DcLog) -join "`n") | Should -Not -Match 'cannot run'
        Reset-PsesState
        @($script:policyApplication.requiredRules.cannotRun).Count | Should -Be 0
    }

    It 'the evidence builder shows each entry as one ASCII line and drops blanks' {
        $e = New-PolicyApplicationEvidence -RequiredState 'activated' -RequiredCannotRun @('a: no rule of that name', '', ("b`n" + [char]0x212A))
        (@($e.requiredRules.cannotRun) -join '|') | Should -BeExactly 'a: no rule of that name|b??'
        @((New-PolicyApplicationEvidence).requiredRules.cannotRun).Count | Should -Be 0
    }

    It 'the receipt types cannotRun: an array of strings is well formed, anything else is not, and a record without it (an older daemon) is still well formed' {
        $daemon = New-PolicyApplicationEvidence -RequiredState 'activated' -RequiredCannotRun @('PSAvoidGlobalVarz: no rule of that name')
        $policy = (([ordered]@{ client = (New-PolicyAdjudicationEvidence); daemon = $daemon }) | ConvertTo-Json -Depth 8) | ConvertFrom-Json
        @(Get-ScanReceiptPolicyEvidenceProblems -Policy $policy).Count | Should -Be 0
        $policy.daemon.requiredRules.cannotRun = 'PSAvoidGlobalVarz'
        @(Get-ScanReceiptPolicyEvidenceProblems -Policy $policy) | Should -Contain 'policy.daemon.requiredRules.cannotRun is not an array'
        $policy.daemon.requiredRules.cannotRun = @(5)
        @(Get-ScanReceiptPolicyEvidenceProblems -Policy $policy) | Should -Contain 'policy.daemon.requiredRules.cannotRun holds a value that is not a string'
        $policy.daemon.requiredRules.PSObject.Properties.Remove('cannotRun')
        @(Get-ScanReceiptPolicyEvidenceProblems -Policy $policy).Count | Should -Be 0
    }

    It 'docs/scan-receipt.schema.json declares cannotRun as an optional array of strings' {
        $schema = [System.IO.File]::ReadAllText((Join-Path $script:RtRepo 'docs/scan-receipt.schema.json')) | ConvertFrom-Json
        $rr = $schema.properties.policy.properties.daemon.oneOf[1].properties.requiredRules
        [string]$rr.properties.cannotRun.type | Should -BeExactly 'array'
        [string]$rr.properties.cannotRun.items.type | Should -BeExactly 'string'
        @($rr.required) | Should -Not -Contain 'cannotRun'
    }

    It 'the scan''s warning line names each rule once, across files, and is empty when no record names one' {
        $none = New-DcFile (New-PolicyApplicationEvidence -RequiredState 'activated')
        Get-ScanRequiredRulesCannotRun -Files @($none) | Should -BeExactly ''
        $a = New-DcFile (New-PolicyApplicationEvidence -RequiredState 'activated' -RequiredCannotRun @('PSAvoidGlobalVarz: no rule of that name'))
        $b = New-DcFile (New-PolicyApplicationEvidence -RequiredState 'activated' -RequiredCannotRun @('PSAvoidGlobalVarz: no rule of that name', "X\Y: excluded by 'Y*'"))
        Get-ScanRequiredRulesCannotRun -Files @($none, $a, $b, $null) | Should -BeExactly "PSAvoidGlobalVarz: no rule of that name; X\Y: excluded by 'Y*'"
    }

    It 'B1c-RV02: a managed verdict over a record naming a required rule that cannot run is NOT CERTIFIED, with the application-stage code policy-required-rule-cannot-run (the INTERIM test it replaces asserted that it certified)' {
        # Owner ruling RV-02 (dispatch 000307, correction round 1): the code is approved, and a managed scan refuses.
        Reset-DcDaemon -Policy $script:DcTypo
        $repo = New-DcRepo
        Initialize-PssaSettings -FilePath (Join-Path $repo 'thing.ps1') -ProjectRoot $repo
        $daemon = Copy-PolicyApplicationEvidence -Evidence $script:policyApplication -SettingsSha256 (Get-PolicyFileSha256 -Path ([string]$script:settingsPathInUse))
        $c = Test-ScanPolicyCertification -Mode 'closed' -Declared $script:DcDeclared -Files @((New-DcFile $daemon))
        $c.Certified | Should -BeFalse -Because 'PSAvoidGlobalVarz has no rule behind it, so it never ran'
        (@($c.Files[0].Reasons) -join ',') | Should -BeExactly 'policy-required-rule-cannot-run'
        @($c.Reasons).Count | Should -Be 0 -Because 'a per-file reason: each file''s daemon record names the rule'
        $t = Get-PolicyReasonTable
        $t.Contains('policy-required-rule-cannot-run') | Should -BeTrue
        [string]$t['policy-required-rule-cannot-run'].Stage | Should -BeExactly 'application'
        (Get-ScanRequiredRulesCannotRun -Files @((New-DcFile $daemon))) | Should -BeExactly 'PSAvoidGlobalVarz: no rule of that name' -Because 'the warning line still names it'
        (Test-ScanPolicyCertification -Mode 'open' -Declared $script:DcDeclared -Files @((New-DcFile $daemon))).Managed | Should -BeFalse -Because 'an unmanaged verdict refuses nothing'
    }

    It 'B1c-RV02 control: the same verdict over a record whose required rules all run still certifies' {
        Reset-DcDaemon -Policy $script:DcGood
        $repo = New-DcRepo
        Initialize-PssaSettings -FilePath (Join-Path $repo 'thing.ps1') -ProjectRoot $repo
        @($script:policyApplication.requiredRules.cannotRun).Count | Should -Be 0
        $daemon = Copy-PolicyApplicationEvidence -Evidence $script:policyApplication -SettingsSha256 (Get-PolicyFileSha256 -Path ([string]$script:settingsPathInUse))
        $c = Test-ScanPolicyCertification -Mode 'closed' -Declared $script:DcGoodDeclared -Files @((New-DcFile $daemon $script:DcGoodDeclared $script:DcGood))
        $c.Certified | Should -BeTrue -Because (@($c.AllReasons) -join ',')
    }

    It 'B1c-RV01: a managed verdict over a tree holding a settings file below the scan root is NOT CERTIFIED, with the run-level certification code policy-settings-nested; an unmanaged verdict refuses nothing' {
        # Owner ruling RV-01 (dispatch 000307, correction round 1). The scan hands the verdict the settings files
        # below its root (Get-ScanNestedSettingsFiles); this record is otherwise the control above, which certifies.
        Reset-DcDaemon -Policy $script:DcGood
        $repo = New-DcRepo
        Initialize-PssaSettings -FilePath (Join-Path $repo 'thing.ps1') -ProjectRoot $repo
        $daemon = Copy-PolicyApplicationEvidence -Evidence $script:policyApplication -SettingsSha256 (Get-PolicyFileSha256 -Path ([string]$script:settingsPathInUse))
        $f = New-DcFile $daemon $script:DcGoodDeclared $script:DcGood
        $nested = @((Join-Path $repo 'lib/PSScriptAnalyzerSettings.psd1'))
        $c = Test-ScanPolicyCertification -Mode 'closed' -Declared $script:DcGoodDeclared -Files @($f) -NestedSettings $nested
        $c.Certified | Should -BeFalse
        (@($c.Reasons) -join ',') | Should -BeExactly 'policy-settings-nested'
        @($c.Files).Count | Should -Be 0 -Because 'a run-level reason: it is the tree, not one file''s evidence'
        [string](Get-PolicyReasonTable)['policy-settings-nested'].Stage | Should -BeExactly 'certification'
        (Test-ScanPolicyCertification -Mode 'closed' -Declared $script:DcGoodDeclared -Files @($f) -NestedSettings @('', ' ')).Certified | Should -BeTrue -Because 'a blank entry names no file'
        (Test-ScanPolicyCertification -Mode 'open' -Declared $script:DcGoodDeclared -Files @($f) -NestedSettings $nested).Managed | Should -BeFalse -Because 'an unmanaged verdict refuses nothing'
    }
}

Describe 'The settings files below a scan root are found the way the settings lookup finds them (dispatch 000307 B1c correction round 1, review finding B1c-RV-01)' {

    BeforeAll {
        function New-NsTree([string[]]$Files) {
            $d = Join-Path $TestDrive ('ns-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            foreach ($f in $Files) {
                $p = Join-Path $d $f
                New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($p)) | Out-Null
                [System.IO.File]::WriteAllText($p, '@{}')
            }
            return [System.IO.Path]::GetFullPath($d)
        }
        function Get-NsNested([string]$Path, [bool]$Recurse = $true) {
            # The scan's own two steps: its targets, then the settings files below its root -- as root-relative paths.
            $t = Get-ScanTargets -Path $Path -Recurse $Recurse
            $root = [string]$t['Root']
            return (@(@(Get-ScanNestedSettingsFiles -Files @($t['Files']) -Root $root) | ForEach-Object { ([string]$_).Substring($root.Length + 1).Replace('\', '/') }) -join ' ; ')
        }
    }

    It 'B1c-RV01: a settings file in a subdirectory, one further up an analyzed file''s walk, and one alone in its directory are found; the scan root''s own is not' {
        $root = New-NsTree @('PSScriptAnalyzerSettings.psd1', 'z.ps1', 'lib/PSScriptAnalyzerSettings.psd1', 'lib/b.ps1', 'a/PSScriptAnalyzerSettings.psd1',
            'a/b/c/deep.ps1', 'docs/PSScriptAnalyzerSettings.psd1', 'zz/b.ps1')
        Get-NsNested $root | Should -BeExactly 'a/PSScriptAnalyzerSettings.psd1 ; docs/PSScriptAnalyzerSettings.psd1 ; lib/PSScriptAnalyzerSettings.psd1'
    }

    It 'B1c-RV01: a HIDDEN settings file beside an analyzed file is found -- the target list omits it, the settings lookup resolves it' -Skip:(-not $script:RtOnWindows) {
        $root = New-NsTree @('PSScriptAnalyzerSettings.psd1', 'z.ps1', 'lib/PSScriptAnalyzerSettings.psd1', 'lib/b.ps1')
        $hf = [System.IO.Path]::GetFullPath((Join-Path $root 'lib/PSScriptAnalyzerSettings.psd1'))
        [System.IO.File]::SetAttributes($hf, ([System.IO.File]::GetAttributes($hf) -bor [System.IO.FileAttributes]::Hidden))
        @((Get-ScanTargets -Path $root -Recurse $true)['Files']) | Should -Not -Contain $hf -Because 'CONTROL: the target list omits a hidden file (measured, both hosts)'
        Resolve-PssaSettingsPath -EditedFilePath ([System.IO.Path]::GetFullPath((Join-Path $root 'lib/b.ps1'))) -ProjectRoot $root | Should -BeExactly $hf -Because 'CONTROL: the lookup resolves it'
        Get-NsNested $root | Should -BeExactly 'lib/PSScriptAnalyzerSettings.psd1'
    }

    It 'B1c-RV01: nothing is found for a single-file scan, a -NoRecurse scan, a tree whose only settings file is the root''s, or no root -- and a hidden directory, which the scan does not enter, is not looked into' {
        $root = New-NsTree @('PSScriptAnalyzerSettings.psd1', 'z.ps1', 'lib/b.ps1', 'lib/PSScriptAnalyzerSettings.psd1')
        Get-NsNested (Join-Path $root 'lib/b.ps1') | Should -BeExactly '' -Because 'a single-file scan: its root is the file''s own directory'
        Get-NsNested $root $false | Should -BeExactly '' -Because '-NoRecurse: no analyzed file lies below the root'
        Get-NsNested (New-NsTree @('PSScriptAnalyzerSettings.psd1', 'z.ps1', 'lib/b.ps1')) | Should -BeExactly '' -Because 'the root''s own settings file is not nested'
        $t = Get-ScanTargets -Path $root -Recurse $true
        @(Get-ScanNestedSettingsFiles -Files @($t['Files']) -Root '').Count | Should -Be 0
        if ($script:RtOnWindows) {
            $hidden = New-NsTree @('PSScriptAnalyzerSettings.psd1', 'z.ps1', 'hid/PSScriptAnalyzerSettings.psd1', 'hid/c.ps1')
            $hd = Join-Path $hidden 'hid'
            [System.IO.File]::SetAttributes($hd, ([System.IO.File]::GetAttributes($hd) -bor [System.IO.FileAttributes]::Hidden))
            @((Get-ScanTargets -Path $hidden -Recurse $true)['Files']).Count | Should -Be 2 -Because 'CONTROL: nothing in the hidden directory is a target (measured, both hosts)'
            Get-NsNested $hidden | Should -BeExactly '' -Because 'nothing in it is analyzed, so its settings file governs nothing'
        }
    }
}

Describe 'The routes through the real daemon, every ambient plugin variable cleared (dispatch 000307 B1c)' -Skip:$script:RtUnsupported {

    BeforeAll {
        . (Join-Path $PSScriptRoot 'Integration.Common.ps1')
        . (Join-Path $PSScriptRoot 'ScanHarness.Common.ps1')
        $script:RdScan = Join-Path $script:RtScripts 'lsp-scan.ps1'
        $script:RdHost = Resolve-PsHost 'pwsh'
        $script:RdData = if (-not [string]::IsNullOrWhiteSpace($env:PSLS_TEST_DATA_DIR)) { $env:PSLS_TEST_DATA_DIR } else { Join-Path ([System.IO.Path]::GetTempPath()) 'psls-sarifscan-test-data' }
        New-Item -ItemType Directory -Force -Path $script:RdData | Out-Null
        $prevData = $env:CLAUDE_PLUGIN_DATA
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $env:CLAUDE_PLUGIN_DATA = $script:RdData
            & $script:RdHost -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:RtScripts 'ensure-pses.ps1') 2>&1 | Out-Null
            & $script:RdHost -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:RtScripts 'ensure-pssa.ps1') 2>&1 | Out-Null
        } finally { $ErrorActionPreference = $prevEap; $env:CLAUDE_PLUGIN_DATA = $prevData }

        $script:RdWork = Join-Path $script:RdData ('b1c-routes-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        function New-RdDir([string]$Name, [hashtable]$Files) {
            $d = Join-Path $script:RdWork $Name
            New-Item -ItemType Directory -Force -Path $d | Out-Null
            foreach ($k in @($Files.Keys)) { [System.IO.File]::WriteAllText((Join-Path $d $k), [string]$Files[$k], (New-Object System.Text.UTF8Encoding($false))) }
            return $d
        }
        # A rule name unique to this run in ExcludeRules (it matches no rule, so it is written as given) keeps
        # each merged text -- and so each content-addressed merged file -- this run's alone.
        $unique = 'PSB1cUnique' + [guid]::NewGuid().ToString('N')
        $thing = "function Get-Items { param() Write-Host 'x' }`ngci`n`$global:RdThing = 1`n# " + ('x' * 60) + "`n"
        $script:RdStar = New-RdDir 'r01-star' @{ 'thing.ps1' = $thing; 'PSScriptAnalyzerSettings.psd1' = ("@{ ExcludeRules = @('*', '" + $unique + "') }`n") }
        $script:RdOwn = New-RdDir 'r01-own' @{ 'thing.ps1' = $thing; 'PSScriptAnalyzerSettings.psd1' = ("@{ IncludeRules = @('PSAvoidUsingCmdletAliases'); ExcludeRules = @('PSAvoidGlobal*', '" + $unique + "') }`n") }
        $script:RdEmpty = New-RdDir 'r03-empty' @{ 'thing.ps1' = $thing; 'PSScriptAnalyzerSettings.psd1' = ("@{ IncludeRules = @(); ExcludeRules = @('" + $unique + "'); Rules = @{ PSAvoidLongLines = @{ Enable = `$true; MaximumLineLength = 40 } } }`n") }
        $script:RdNone = New-RdDir 'r04-none' @{ 'thing.ps1' = $thing }
        $script:RdGlobal = Join-Path $script:RdWork 'required.psd1'
        [System.IO.File]::WriteAllText($script:RdGlobal, "@{ RequiredRules = @('PSAvoidGlobalVars') }`n")
        $script:RdTypo = Join-Path $script:RdWork 'typo.psd1'
        [System.IO.File]::WriteAllText($script:RdTypo, ("@{ RequiredRules = @('PSAvoidGlobalVarz', '" + $unique + "') }`n"))
        # Correction round 1 (review 6656dadf4a4b): a settings file nested under lib\, which sorts before the root's
        # own file (RV-01); a required custom rule no CustomRulePath supplies (RV-02); a pattern beside a
        # CustomRulePath that still excludes the required rule (RV-03); a padded ExcludeRules entry (RV-04).
        $script:RdNested = New-RdDir 'rv01-nested' @{ 'z.ps1' = $thing; 'PSScriptAnalyzerSettings.psd1' = ("@{ ExcludeRules = @('PSAvoidUsingWriteHost', '" + $unique + "') }`n") }
        [void](New-RdDir 'rv01-nested/lib' @{ 'b.ps1' = $thing; 'PSScriptAnalyzerSettings.psd1' = ("@{ ExcludeRules = @('PSAvoidUsingCmdletAliases', '" + $unique + "') }`n") })
        $script:RdBare = New-RdDir 'rv02-not-supplied' @{ 'thing.ps1' = $thing; 'PSScriptAnalyzerSettings.psd1' = ("@{ ExcludeRules = @('" + $unique + "') }`n") }
        $script:RdQualified = Join-Path $script:RdWork 'qualified.psd1'
        [System.IO.File]::WriteAllText($script:RdQualified, "@{ RequiredRules = @('B1cRd.Rules\Measure-B1cRdNone') }`n")
        $rdModule = New-RtRuleModule 'B1cRd.Rules' 'Measure-B1cRdReports'
        $script:RdCustom = New-RdDir 'rv03-custom' @{ 'thing.ps1' = $thing; 'PSScriptAnalyzerSettings.psd1' = ("@{ CustomRulePath = @('" + $rdModule + "'); ExcludeRules = @('PSAvoidGlobal*', '" + $unique + "') }`n") }
        $script:RdPadded = New-RdDir 'rv04-padded' @{ 'thing.ps1' = $thing; 'PSScriptAnalyzerSettings.psd1' = ("@{ ExcludeRules = @(' PSAvoidUsingWriteHost ', '" + $unique + "') }`n") }

        function Invoke-RdScan {
            param([string]$Target, [string]$Policy = '', [string]$Mode = '')
            $out = Join-Path $script:RdWork ('out-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.sarif')
            $a = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:RdScan, $Target, '-Format', 'sarif', '-OutputPath', $out)
            if ($Policy -ne '') { $a += @('-OrgPolicyPath', $Policy) }
            if ($Mode -ne '') { $a += @('-PolicyMode', $Mode) }
            $run = Invoke-SvChildProcess -HostExe $script:RdHost -CapMs 300000 -ArgumentList $a -ExtraEnv @{ CLAUDE_PLUGIN_DATA = $script:RdData } `
                -RemoveEnvPrefix @('CLAUDE_PLUGIN_OPTION_', 'POWERSHELL_LSP_')
            $text = Read-SvTextFile -Path $out
            $sarif = $null; $results = @(); $fileResults = @(); $pol = $null
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $sarif = $text | ConvertFrom-Json
                $res = @(@($sarif.runs[0].results) | Where-Object { $null -ne $_ })
                $results = @($res | ForEach-Object { [string]$_.ruleId } | Sort-Object -Unique)
                $fileResults = @($res | ForEach-Object { [string]$_.locations[0].physicalLocation.artifactLocation.uri + '|' + [string]$_.ruleId } | Sort-Object -Unique)
                $inv = $sarif.runs[0].invocations[0]
                if ($null -ne $inv.PSObject.Properties['properties']) { $pol = $inv.properties.policy }
            }
            return @{ Exit = [int]$run.ExitCode; Err = [string]$run.Err; Sarif = $sarif; Results = $results; FileResults = $fileResults; Policy = $pol; TimedOut = [bool]$run.TimedOut }
        }

        $script:Rd = @{}
        $script:Rd.Star = Invoke-RdScan -Target $script:RdStar -Policy $script:RdGlobal -Mode 'closed'
        $script:Rd.Own = Invoke-RdScan -Target $script:RdOwn -Policy $script:RdGlobal -Mode 'closed'
        $script:Rd.Empty = Invoke-RdScan -Target $script:RdEmpty -Policy $script:RdGlobal -Mode 'closed'
        $script:Rd.Typo = Invoke-RdScan -Target $script:RdNone -Policy $script:RdTypo -Mode 'closed'
        $script:Rd.Nested = Invoke-RdScan -Target $script:RdNested -Policy $script:RdGlobal -Mode 'closed'
        $script:Rd.NestedOpen = Invoke-RdScan -Target $script:RdNested -Policy $script:RdGlobal
        $script:Rd.Bare = Invoke-RdScan -Target $script:RdBare -Policy $script:RdQualified -Mode 'closed'
        $script:Rd.Custom = Invoke-RdScan -Target $script:RdCustom -Policy $script:RdGlobal -Mode 'closed'
        $script:Rd.Padded = Invoke-RdScan -Target $script:RdPadded -Policy $script:RdGlobal -Mode 'closed'
    }

    AfterAll {
        if ($script:RdWork -and (Test-Path -LiteralPath $script:RdWork)) { Remove-Item -LiteralPath $script:RdWork -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'every scan ran to its report (this Describe cannot pass vacuously)' {
        foreach ($k in @($script:Rd.Keys)) {
            $script:Rd[$k].TimedOut | Should -BeFalse -Because ($k + ' must finish')
            $script:Rd[$k].Sarif | Should -Not -BeNullOrEmpty -Because ($k + ' must write its SARIF; stderr: ' + $script:Rd[$k].Err)
        }
    }

    It 'B1c-R01: ExcludeRules ''*'' -- a managed scan certifies WITH the required rule (it certified an empty result)' {
        $m = $script:Rd.Star
        $m.Exit | Should -Be 0 -Because ('stderr: ' + $m.Err)
        $m.Policy.certification | Should -BeExactly 'certified'
        ($m.Results -join ',') | Should -BeExactly 'PSAvoidGlobalVars'
    }

    It 'B1c-R01: a pattern beside the repository''s own IncludeRules -- certified with the repository''s rule and the required one' {
        $m = $script:Rd.Own
        $m.Policy.certification | Should -BeExactly 'certified' -Because ('stderr: ' + $m.Err)
        ($m.Results -join ',') | Should -BeExactly 'PSAvoidGlobalVars,PSAvoidUsingCmdletAliases'
    }

    It 'B1c-R03: IncludeRules = @() -- certified with every rule the repository runs, not the required rule alone' {
        $m = $script:Rd.Empty
        $m.Policy.certification | Should -BeExactly 'certified' -Because ('stderr: ' + $m.Err)
        foreach ($r in @('PSAvoidGlobalVars', 'PSAvoidLongLines', 'PSAvoidUsingCmdletAliases', 'PSAvoidUsingWriteHost', 'PSUseSingularNouns')) { $m.Results | Should -Contain $r }
    }

    It 'B1c-R04: a misspelled required rule is named on stderr, and the managed scan is NOT CERTIFIED with policy-required-rule-cannot-run (owner ruling RV-02; it certified)' {
        $m = $script:Rd.Typo
        $m.Err | Should -Match 'a rule the policy requires cannot run under the settings PSES was handed \(PSAvoidGlobalVarz: no rule of that name'
        $m.Exit | Should -Be 4
        $m.Policy.certification | Should -BeExactly 'not-certified'
        @($m.Policy.reasons) | Should -Contain 'policy-required-rule-cannot-run'
    }

    It 'B1c-RV01: a settings file nested under a subdirectory that sorts first -- the managed scan is NOT CERTIFIED with policy-settings-nested (it certified lib''s file governing every file, the root''s own unused)' {
        $m = $script:Rd.Nested
        $m.Exit | Should -Be 4 -Because ('stderr: ' + $m.Err)
        $m.Policy.certification | Should -BeExactly 'not-certified'
        @($m.Policy.reasons) | Should -Contain 'policy-settings-nested'
        $m.Err | Should -Match 'policy-settings-nested'
        @($m.FileResults) | Should -Contain 'z.ps1|PSAvoidUsingWriteHost' -Because 'the findings are still reported -- lib''s settings governed z.ps1 too, as measured'
    }

    It 'B1c-RV01 control: the same tree scanned unmanaged is unchanged -- exit 0, nothing refused' {
        $m = $script:Rd.NestedOpen
        $m.Exit | Should -Be 0 -Because ('stderr: ' + $m.Err)
        $m.Policy.certification | Should -BeExactly 'not-requested'
        @($m.Policy.reasons).Count | Should -Be 0
    }

    It 'B1c-RV02: a required custom rule no CustomRulePath supplies -- the managed scan is NOT CERTIFIED with policy-required-rule-cannot-run (it certified)' {
        $m = $script:Rd.Bare
        $m.Exit | Should -Be 4 -Because ('stderr: ' + $m.Err)
        $m.Policy.certification | Should -BeExactly 'not-certified'
        @($m.Policy.reasons) | Should -Contain 'policy-required-rule-cannot-run'
        $m.Err | Should -Match 'B1cRd\.Rules\\Measure-B1cRdNone: no rule of that name'
    }

    It 'B1c-RV03: a repository pattern beside a CustomRulePath that still excludes the required rule -- the managed scan is NOT CERTIFIED with policy-required-rule-cannot-run (it certified)' {
        $m = $script:Rd.Custom
        $m.Exit | Should -Be 4 -Because ('stderr: ' + $m.Err)
        $m.Policy.certification | Should -BeExactly 'not-certified'
        @($m.Policy.reasons) | Should -Contain 'policy-required-rule-cannot-run'
        $m.Results | Should -Not -Contain 'PSAvoidGlobalVars' -Because 'the kept pattern shut it out (measured): the refusal says so'
    }

    It 'B1c-RV04: a padded ExcludeRules entry -- the managed scan certifies with every rule the repository runs, Write-Host included (it dropped PSAvoidUsingWriteHost)' {
        $m = $script:Rd.Padded
        $m.Exit | Should -Be 0 -Because ('stderr: ' + $m.Err)
        $m.Policy.certification | Should -BeExactly 'certified'
        ($m.Results -join ',') | Should -BeExactly 'PSAvoidGlobalVars,PSAvoidUsingCmdletAliases,PSAvoidUsingWriteHost,PSUseSingularNouns'
    }
}
