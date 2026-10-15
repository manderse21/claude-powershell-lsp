#Requires -Version 5.1

# Settings files the analysis rests on, and the policy evidence about them (Pester 5) -- dispatch 000306,
# B1b: the follow-ups B1's reviews routed here (B1-K04, B1-K05, B1-K07, B1-OOB-I01; B1-Q03's mode change is
# tested beside the rest of the mode in PowerShellLsp.EffectivePolicy.Tests.ps1).
#
# SIX LAYERS:
#   1. What PSScriptAnalyzer accepts in a settings file (no daemon): the measured key set, the reader
#      (Read-PssaSettingsFile) over a fixture matrix, that it never runs the file, and PARITY with the
#      vendored PSScriptAnalyzer on the running host -- every fixture's verdict equal to whether
#      Invoke-ScriptAnalyzer, called the way PSES calls it, accepts it -- plus the one documented boundary.
#   2. The RequiredRules merge carries exactly the accepted entries: Rules and Severity survive, a rejected
#      key never reaches the merged text, and a merge of IncludeRules/ExcludeRules alone renders the text
#      (so the content-addressed name) it always had.
#   3. Stale merged settings files are swept, and never one a live daemon on the same data root uses.
#   4. The daemon (its own Initialize-PssaSettings and Reset-PsesState, lifted from pses-daemon.ps1 by AST,
#      PSES stubbed): a rejected settings file is never handed to PSES and the verdict is recorded; a
#      settings resolution that throws records the TERMINAL settings-unresolved; a PSES re-spawn forgets the
#      dead child's evidence -- the staged re-spawn the review found certifying on stale evidence now refuses.
#   5. Evidence consumers: the managed verdict, the receipt shape, doctor, the unmanaged scan's warning.
#   6. The real daemon, every ambient plugin variable cleared: Rules survive a RequiredRules merge end to
#      end; a rejected settings file is refused (managed) or warned about and fallen back from (unmanaged).
#      (A LIVE Windows PowerShell 5.1 daemon whose settings resolution throws -- the one host where a '|' in
#      settingsPath makes it throw for real -- is measured by tests/measure-policy-b1b-controls.ps1, not
#      here: no other test starts PSES under 5.1, and the suite should not gain a CI dependency on how fast
#      a hosted runner brings one up. Layer 4 runs the daemon's own code for that path on every leg.)
#
# ASCII-only (PS 5.1 em-dash trap); StrictMode-safe.

$script:PsOnWindows = if (Test-Path 'Variable:\IsWindows') { [bool]$IsWindows } else { $true }
$script:PsOnLinux = (Test-Path 'Variable:\IsLinux') -and [bool]$IsLinux
$script:PsOnMacOS = (Test-Path 'Variable:\IsMacOS') -and [bool]$IsMacOS
$script:PsUnsupported = -not ($script:PsOnWindows -or $script:PsOnLinux -or $script:PsOnMacOS)
$script:PsNoTestJson = ($PSVersionTable.PSVersion.Major -lt 6)

BeforeAll {
    $script:PsRepo = Split-Path -Parent $PSScriptRoot
    $script:PsScripts = Join-Path $script:PsRepo 'scripts'
    . (Join-Path $script:PsRepo 'scripts/lib/lsp-common.ps1')
    . (Join-Path $script:PsRepo 'scripts/lib/lsp-scan-common.ps1')
    . (Join-Path $script:PsRepo 'scripts/lib/lsp-scan-receipt.ps1')
    . (Join-Path $script:PsRepo 'scripts/lib/lsp-policy.ps1')

    function New-PsFile {
        # A file under $TestDrive holding $Text (UTF-8, no BOM), returned as its absolute path.
        param([string]$Text, [string]$Name = 'PSScriptAnalyzerSettings.psd1')
        $d = Join-Path $TestDrive ('ps-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        $p = Join-Path $d $Name
        [System.IO.File]::WriteAllText($p, $Text, (New-Object System.Text.UTF8Encoding($false)))
        return $p
    }
}

Describe 'What PSScriptAnalyzer accepts in a settings file -- measured, and a reader that mirrors it (dispatch 000306 B1b, review finding B1-K04)' {

    BeforeAll {
        # One absolute custom rule module, and an empty directory, for the CustomRulePath cases.
        $script:RdRules = Join-Path $TestDrive 'rd-rules'
        New-Item -ItemType Directory -Force -Path $script:RdRules | Out-Null
        $script:RdModule = Join-Path $script:RdRules 'B1b.Rules.psm1'
        [System.IO.File]::WriteAllText($script:RdModule, (@(
                    'function Measure-B1bNoGci {'
                    '    [CmdletBinding()]'
                    '    [OutputType([Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord[]])]'
                    '    param([Parameter(Mandatory = $true)][System.Management.Automation.Language.ScriptBlockAst]$ScriptBlockAst)'
                    '    return @()'
                    '}'
                    'Export-ModuleMember -Function Measure-B1bNoGci') -join "`n"))
        $script:RdEmpty = Join-Path $TestDrive 'rd-empty'
        New-Item -ItemType Directory -Force -Path $script:RdEmpty | Out-Null
        $script:RdMissing = Join-Path $TestDrive 'rd-no-such/rules.psm1'
        # Review finding B1b-K01 -- where a CustomRulePath leads PSScriptAnalyzer (measured, both hosts): a
        # module directory named for its module, or holding it in a version folder; one nested below a
        # directory given with RecurseCustomRulePath; and places that hold no module or assembly. Then the
        # boundary: rule sources that RESOLVE but hold no rule.
        function New-RdRuleModule([string]$Path, [string]$Function, [switch]$NoRule) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
            $body = if ($NoRule) { 'function ' + $Function + " { 'x' }" } else {
                'function ' + $Function + " {`n    param([Parameter(Mandatory = `$true)][System.Management.Automation.Language.ScriptBlockAst]`$ScriptBlockAst)`n    return @()`n}"
            }
            [System.IO.File]::WriteAllText($Path, ($body + "`nExport-ModuleMember -Function " + $Function + "`n"))
        }
        $script:RdModDir = Join-Path $TestDrive 'rd-moddirs/B1b.ModDir'
        New-RdRuleModule (Join-Path $script:RdModDir 'B1b.ModDir.psm1') 'Measure-B1bModDir'
        $script:RdVerDir = Join-Path $TestDrive 'rd-moddirs/B1b.Ver'
        New-RdRuleModule (Join-Path $script:RdVerDir '1.0.0/B1b.Ver.psm1') 'Measure-B1bVer'
        [System.IO.File]::WriteAllText((Join-Path $script:RdVerDir '1.0.0/B1b.Ver.psd1'), "@{ RootModule = 'B1b.Ver.psm1'; ModuleVersion = '1.0.0'; GUID = '3f6a1c2e-8b4d-4e5f-9a7b-0c1d2e3f4a5b'; FunctionsToExport = @('Measure-B1bVer') }`n")
        $script:RdOuter = Join-Path $TestDrive 'rd-outer'
        New-RdRuleModule (Join-Path $script:RdOuter 'B1b.Deep/B1b.Deep.psm1') 'Measure-B1bDeep'
        $script:RdTxtDir = Join-Path $TestDrive 'rd-txtonly'
        New-Item -ItemType Directory -Force -Path $script:RdTxtDir | Out-Null
        $script:RdTxtFile = Join-Path $script:RdTxtDir 'readme.txt'
        [System.IO.File]::WriteAllText($script:RdTxtFile, 'not a rule module')
        $script:RdNoRule = Join-Path $TestDrive 'rd-norule/B1b.NoRule.psm1'
        New-RdRuleModule $script:RdNoRule 'Get-B1bNothing' -NoRule
        $script:RdNoRuleDir = Join-Path $TestDrive 'rd-norule-dir/B1b.NoRuleDir'
        New-RdRuleModule (Join-Path $script:RdNoRuleDir 'B1b.NoRuleDir.psm1') 'Get-B1bNothingEither' -NoRule
        $script:RdFakeAssembly = Join-Path $TestDrive 'rd-fake-assembly'
        New-Item -ItemType Directory -Force -Path $script:RdFakeAssembly | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $script:RdFakeAssembly 'NotAnAssembly.dll'), 'not an assembly')
        # THE MATRIX. Verdicts are the reader's; 'Pssa' is what the vendored PSScriptAnalyzer 1.25.0 was
        # MEASURED to do with the same file on Windows PowerShell 5.1 and PowerShell 7 (dispatch 000306),
        # and what the parity test below re-measures on the running host.
        $q = [char]39
        $script:RdCases = @(
            @{ Name = 'every accepted key'; Verdict = 'valid'; Text = "@{ Severity = @('Warning'); IncludeRules = @('PSAvoidUsingCmdletAliases'); ExcludeRules = @('PSAvoidGlobalVars'); IncludeDefaultRules = `$true; RecurseCustomRulePath = `$false; Rules = @{ PSAvoidUsingCmdletAliases = @{ Enable = `$true; allowlist = @('gci') } } }" }
            @{ Name = 'keys in any case'; Verdict = 'valid'; Text = "@{ severity = @('warning'); INCLUDERULES = @('PSAvoidUsingCmdletAliases') }" }
            @{ Name = 'a scalar string list'; Verdict = 'valid'; Text = "@{ Severity = 'Error'; IncludeRules = 'PSAvoidUsingCmdletAliases' }" }
            @{ Name = 'an empty table'; Verdict = 'valid'; Text = '@{}' }
            @{ Name = 'a statement before the table'; Verdict = 'valid'; Text = "`$x = 1`n@{ Severity = @('Warning') }" }
            @{ Name = 'a cast and a negative number'; Verdict = 'valid'; Text = "@{ Rules = @{ PSAvoidLongLines = @{ Enable = `$true; MaximumLineLength = [int]80; Other = -1 } } }" }
            @{ Name = 'a double rule argument'; Verdict = 'valid'; Text = "@{ Rules = @{ PSAvoidLongLines = @{ Enable = `$true; MaximumLineLength = 1.5 } } }" }
            @{ Name = 'a parenthesized list (B1b-R02)'; Verdict = 'valid'; Text = "@{ ExcludeRules = ('PSAvoidUsingCmdletAliases', 'PSAvoidGlobalVars') }" }
            @{ Name = 'a parenthesized scalar (B1b-R02)'; Verdict = 'valid'; Text = "@{ IncludeRules = ('PSAvoidGlobalVars') }" }
            @{ Name = 'a parenthesized boolean (B1b-R02)'; Verdict = 'valid'; Text = "@{ IncludeDefaultRules = (`$true) }" }
            @{ Name = 'parenthesized values nested in Rules (B1b-R02)'; Verdict = 'valid'; Text = "@{ Rules = @{ PSAvoidLongLines = @{ Enable = (`$true); MaximumLineLength = (120) } } }" }
            @{ Name = 'a signed parenthesized number (B1b-R02)'; Verdict = 'valid'; Text = "@{ Rules = @{ PSAvoidLongLines = @{ Enable = `$true; Other = -(5) } } }" }
            @{ Name = 'a parenthesized key and a parenthesized cast (B1b-R02)'; Verdict = 'valid'; Text = "@{ ('Severity') = @('Warning'); Rules = @{ PSAvoidLongLines = @{ MaximumLineLength = ([int]80) } } }" }
            @{ Name = 'severity names padded, numeric, comma-joined'; Verdict = 'valid'; Text = "@{ Severity = @(' Warning ', '1', 'Warning,Error') }" }
            @{ Name = 'RuleArguments'; Verdict = 'rejected'; Text = "@{ RuleArguments = @{ PSAvoidUsingCmdletAliases = @{ Enable = `$true } } }" }
            @{ Name = 'Severities'; Verdict = 'rejected'; Text = "@{ Severities = @('Warning') }" }
            @{ Name = 'FilePath'; Verdict = 'rejected'; Text = "@{ FilePath = 'x.ps1' }" }
            @{ Name = 'a key that is not a string'; Verdict = 'rejected'; Text = "@{ 1 = 'x' }" }
            @{ Name = 'Severity as a number'; Verdict = 'rejected'; Text = '@{ Severity = 5 }' }
            @{ Name = 'Severity Hint'; Verdict = 'rejected'; Text = "@{ Severity = @('Hint') }" }
            @{ Name = 'a blank Severity'; Verdict = 'rejected'; Text = "@{ Severity = @('') }" }
            @{ Name = 'a trailing comma in a Severity'; Verdict = 'rejected'; Text = "@{ Severity = @('Warning,') }" }
            @{ Name = 'a null in IncludeRules'; Verdict = 'rejected'; Text = "@{ IncludeRules = @('PSAvoidUsingCmdletAliases', `$null) }" }
            @{ Name = 'a null value'; Verdict = 'rejected'; Text = '@{ Severity = $null }' }
            @{ Name = 'IncludeDefaultRules as a string'; Verdict = 'rejected'; Text = "@{ IncludeDefaultRules = 'true' }" }
            @{ Name = 'Rules as a string'; Verdict = 'rejected'; Text = "@{ Rules = 'x' }" }
            @{ Name = 'a Rules entry that is not a table'; Verdict = 'rejected'; Text = "@{ Rules = @{ PSAvoidUsingCmdletAliases = 'x' } }" }
            @{ Name = 'a null deep in Rules'; Verdict = 'rejected'; Text = '@{ Rules = @{ PSAvoidUsingCmdletAliases = @{ Enable = $null } } }' }
            @{ Name = 'an empty CustomRulePath'; Verdict = 'rejected'; Text = '@{ CustomRulePath = @() }' }
            @{ Name = 'a blank CustomRulePath'; Verdict = 'rejected'; Text = "@{ CustomRulePath = @('') }" }
            @{ Name = 'a relative CustomRulePath'; Verdict = 'rejected'; Text = "@{ CustomRulePath = @('./rules/B1b.Rules.psm1') }" }
            @{ Name = 'a missing absolute CustomRulePath'; Verdict = 'rejected'; Text = ('@{ CustomRulePath = @(' + $q + $script:RdMissing + $q + ') }') }
            @{ Name = 'an absolute custom rule module'; Verdict = 'valid'; Text = ('@{ CustomRulePath = @(' + $q + $script:RdModule + $q + ') }') }
            @{ Name = 'a wildcard CustomRulePath'; Verdict = 'valid'; Text = ('@{ CustomRulePath = @(' + $q + (Join-Path $script:RdRules '*.psm1') + $q + ') }') }
            @{ Name = 'a wildcard CustomRulePath matching nothing, beside the default rules'; Verdict = 'valid'; Text = ('@{ CustomRulePath = @(' + $q + (Join-Path $script:RdRules '*.nomatch') + $q + '); IncludeDefaultRules = $true }') }
            @{ Name = 'a FileSystem-qualified CustomRulePath'; Verdict = 'valid'; Text = ('@{ CustomRulePath = @(' + $q + 'FileSystem::' + $script:RdModule + $q + ') }') }
            @{ Name = 'a drive-relative CustomRulePath'; Verdict = 'rejected'; Text = "@{ CustomRulePath = @('C:rd-rules\B1b.Rules.psm1') }" }
            @{ Name = 'a FileSystem-qualified relative CustomRulePath'; Verdict = 'rejected'; Text = "@{ CustomRulePath = @('FileSystem::rd-rules\B1b.Rules.psm1') }" }
            @{ Name = 'a CustomRulePath wildcard matching nothing (B1b-K01)'; Verdict = 'rejected'; Text = ('@{ CustomRulePath = @(' + $q + (Join-Path $script:RdRules '*.nomatch') + $q + ') }') }
            @{ Name = 'an empty CustomRulePath directory (B1b-K01)'; Verdict = 'rejected'; Text = ('@{ CustomRulePath = @(' + $q + $script:RdEmpty + $q + ') }') }
            @{ Name = 'a CustomRulePath directory holding no module or assembly (B1b-K01)'; Verdict = 'rejected'; Text = ('@{ CustomRulePath = @(' + $q + $script:RdTxtDir + $q + ') }') }
            @{ Name = 'a CustomRulePath file that is no module (B1b-K01)'; Verdict = 'rejected'; Text = ('@{ CustomRulePath = @(' + $q + $script:RdTxtFile + $q + ') }') }
            @{ Name = 'a CustomRulePath directory holding a module named otherwise (B1b-K01)'; Verdict = 'rejected'; Text = ('@{ CustomRulePath = @(' + $q + $script:RdRules + $q + ') }') }
            @{ Name = 'a nested module directory without RecurseCustomRulePath (B1b-K01)'; Verdict = 'rejected'; Text = ('@{ CustomRulePath = @(' + $q + $script:RdOuter + $q + ') }') }
            @{ Name = 'a module directory as CustomRulePath'; Verdict = 'valid'; Text = ('@{ CustomRulePath = @(' + $q + $script:RdModDir + $q + ') }') }
            @{ Name = 'a versioned module directory as CustomRulePath'; Verdict = 'valid'; Text = ('@{ CustomRulePath = @(' + $q + $script:RdVerDir + $q + ') }') }
            @{ Name = 'a nested module directory with RecurseCustomRulePath'; Verdict = 'valid'; Text = ('@{ CustomRulePath = @(' + $q + $script:RdOuter + $q + '); RecurseCustomRulePath = $true }') }
            @{ Name = 'a CustomRulePath entry reaching nothing beside one reaching a module'; Verdict = 'valid'; Text = ('@{ CustomRulePath = @(' + $q + (Join-Path $script:RdRules '*.nomatch') + $q + ', ' + $q + $script:RdModule + $q + ') }') }
            @{ Name = 'an empty CustomRulePath directory beside the default rules'; Verdict = 'valid'; Text = ('@{ CustomRulePath = @(' + $q + $script:RdEmpty + $q + '); IncludeDefaultRules = $true }') }
            @{ Name = 'an empty file'; Verdict = 'unparsable'; Text = '' }
            @{ Name = 'no table'; Verdict = 'unparsable'; Text = "'x'" }
            @{ Name = 'a syntax error'; Verdict = 'unparsable'; Text = '@{ Severity = ' }
            @{ Name = 'a command in a value'; Verdict = 'unparsable'; Text = '@{ Severity = (Get-Date) }' }
            @{ Name = 'a parenthesized pipeline'; Verdict = 'unparsable'; Text = "@{ IncludeRules = (@('PSAvoidGlobalVars') | Sort-Object) }" }
            @{ Name = 'a parenthesized assignment'; Verdict = 'unparsable'; Text = "@{ Severity = (`$x = 'Warning') }" }
            @{ Name = 'an expandable string'; Verdict = 'unparsable'; Text = '@{ IncludeRules = @("$env:USERNAME") }' }
            @{ Name = 'a variable other than true, false, null'; Verdict = 'unparsable'; Text = '@{ CustomRulePath = @($PSScriptRoot) }' }
            @{ Name = 'a duplicate key'; Verdict = 'unparsable'; Text = "@{ Severity = @('Error'); severity = @('Warning') }" }
        )
        # A home-relative entry, where the test drive lies under the home directory (Windows; not a Linux
        # /tmp): ~ is what the FileSystem provider's Home is, in this process and in the parity child alike.
        $script:RdHomeCase = $null
        $fsHome = [string](Get-PSProvider -PSProvider FileSystem).Home
        if (-not [string]::IsNullOrWhiteSpace($fsHome)) {
            $fsHome = $fsHome.TrimEnd('\', '/')
            if ($script:RdModule.StartsWith($fsHome + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
                $script:RdHomeCase = @{ Name = 'a home-relative CustomRulePath'; Verdict = 'valid'; Text = ('@{ CustomRulePath = @(' + $q + '~' + $script:RdModule.Substring($fsHome.Length) + $q + ') }') }
                $script:RdCases += $script:RdHomeCase
            }
        }
    }

    It 'the accepted key set is the measured seven, in canonical case -- and docs/DEV_NOTES.md lists the same seven' {
        (Get-PssaSettingsKeyNames) -join ',' | Should -BeExactly 'CustomRulePath,ExcludeRules,IncludeRules,IncludeDefaultRules,RecurseCustomRulePath,Rules,Severity'
        $notes = [System.IO.File]::ReadAllText((Join-Path $script:PsRepo 'docs/DEV_NOTES.md'))
        $m = [regex]::Match($notes, 'Its valid keys are\s+((?:`[A-Za-z]+`,?\s*(?:and\s+)?)+)')
        $m.Success | Should -BeTrue -Because 'docs/DEV_NOTES.md states the valid keys in one sentence'
        $listed = @([regex]::Matches($m.Groups[1].Value, '`([A-Za-z]+)`') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
        ($listed -join ',') | Should -BeExactly (@(Get-PssaSettingsKeyNames | Sort-Object) -join ',')
    }

    It 'Read-PssaSettingsFile reads <Name> as <Verdict>' -TestCases @(
        @{ Name = 'every accepted key'; Verdict = 'valid' }
        @{ Name = 'keys in any case'; Verdict = 'valid' }
        @{ Name = 'a scalar string list'; Verdict = 'valid' }
        @{ Name = 'an empty table'; Verdict = 'valid' }
        @{ Name = 'a statement before the table'; Verdict = 'valid' }
        @{ Name = 'a cast and a negative number'; Verdict = 'valid' }
        @{ Name = 'a double rule argument'; Verdict = 'valid' }
        @{ Name = 'a parenthesized list (B1b-R02)'; Verdict = 'valid' }
        @{ Name = 'a parenthesized scalar (B1b-R02)'; Verdict = 'valid' }
        @{ Name = 'a parenthesized boolean (B1b-R02)'; Verdict = 'valid' }
        @{ Name = 'parenthesized values nested in Rules (B1b-R02)'; Verdict = 'valid' }
        @{ Name = 'a signed parenthesized number (B1b-R02)'; Verdict = 'valid' }
        @{ Name = 'a parenthesized key and a parenthesized cast (B1b-R02)'; Verdict = 'valid' }
        @{ Name = 'severity names padded, numeric, comma-joined'; Verdict = 'valid' }
        @{ Name = 'RuleArguments'; Verdict = 'rejected' }
        @{ Name = 'Severities'; Verdict = 'rejected' }
        @{ Name = 'FilePath'; Verdict = 'rejected' }
        @{ Name = 'a key that is not a string'; Verdict = 'rejected' }
        @{ Name = 'Severity as a number'; Verdict = 'rejected' }
        @{ Name = 'Severity Hint'; Verdict = 'rejected' }
        @{ Name = 'a blank Severity'; Verdict = 'rejected' }
        @{ Name = 'a trailing comma in a Severity'; Verdict = 'rejected' }
        @{ Name = 'a null in IncludeRules'; Verdict = 'rejected' }
        @{ Name = 'a null value'; Verdict = 'rejected' }
        @{ Name = 'IncludeDefaultRules as a string'; Verdict = 'rejected' }
        @{ Name = 'Rules as a string'; Verdict = 'rejected' }
        @{ Name = 'a Rules entry that is not a table'; Verdict = 'rejected' }
        @{ Name = 'a null deep in Rules'; Verdict = 'rejected' }
        @{ Name = 'an empty CustomRulePath'; Verdict = 'rejected' }
        @{ Name = 'a blank CustomRulePath'; Verdict = 'rejected' }
        @{ Name = 'a relative CustomRulePath'; Verdict = 'rejected' }
        @{ Name = 'a missing absolute CustomRulePath'; Verdict = 'rejected' }
        @{ Name = 'an absolute custom rule module'; Verdict = 'valid' }
        @{ Name = 'a wildcard CustomRulePath'; Verdict = 'valid' }
        @{ Name = 'a wildcard CustomRulePath matching nothing, beside the default rules'; Verdict = 'valid' }
        @{ Name = 'a FileSystem-qualified CustomRulePath'; Verdict = 'valid' }
        @{ Name = 'a drive-relative CustomRulePath'; Verdict = 'rejected' }
        @{ Name = 'a FileSystem-qualified relative CustomRulePath'; Verdict = 'rejected' }
        @{ Name = 'a CustomRulePath wildcard matching nothing (B1b-K01)'; Verdict = 'rejected' }
        @{ Name = 'an empty CustomRulePath directory (B1b-K01)'; Verdict = 'rejected' }
        @{ Name = 'a CustomRulePath directory holding no module or assembly (B1b-K01)'; Verdict = 'rejected' }
        @{ Name = 'a CustomRulePath file that is no module (B1b-K01)'; Verdict = 'rejected' }
        @{ Name = 'a CustomRulePath directory holding a module named otherwise (B1b-K01)'; Verdict = 'rejected' }
        @{ Name = 'a nested module directory without RecurseCustomRulePath (B1b-K01)'; Verdict = 'rejected' }
        @{ Name = 'a module directory as CustomRulePath'; Verdict = 'valid' }
        @{ Name = 'a versioned module directory as CustomRulePath'; Verdict = 'valid' }
        @{ Name = 'a nested module directory with RecurseCustomRulePath'; Verdict = 'valid' }
        @{ Name = 'a CustomRulePath entry reaching nothing beside one reaching a module'; Verdict = 'valid' }
        @{ Name = 'an empty CustomRulePath directory beside the default rules'; Verdict = 'valid' }
        @{ Name = 'an empty file'; Verdict = 'unparsable' }
        @{ Name = 'no table'; Verdict = 'unparsable' }
        @{ Name = 'a syntax error'; Verdict = 'unparsable' }
        @{ Name = 'a command in a value'; Verdict = 'unparsable' }
        @{ Name = 'a parenthesized pipeline'; Verdict = 'unparsable' }
        @{ Name = 'a parenthesized assignment'; Verdict = 'unparsable' }
        @{ Name = 'an expandable string'; Verdict = 'unparsable' }
        @{ Name = 'a variable other than true, false, null'; Verdict = 'unparsable' }
        @{ Name = 'a duplicate key'; Verdict = 'unparsable' }
    ) {
        param($Name, $Verdict)
        $case = @($script:RdCases | Where-Object { $_.Name -eq $Name })
        $case.Count | Should -Be 1 -Because 'every test case names one fixture of the matrix'
        $r = Read-PssaSettingsFile -Path (New-PsFile $case[0].Text)
        $r.Verdict | Should -BeExactly $Verdict -Because ([string]$r.Problem)
        if ($Verdict -eq 'valid') { $r.Problem | Should -BeExactly '' } else { $r.Problem | Should -Not -BeNullOrEmpty }
        $r.Problem | Should -Not -Match '[^\x20-\x7E]' -Because 'a problem is one printable-ASCII line'
    }

    It 'a home-relative (~) CustomRulePath reads valid: PowerShell resolves ~ to the same home inside PSES' {
        if ($null -eq $script:RdHomeCase) { Set-ItResult -Skipped -Because 'the test drive is not under the home directory on this host'; return }
        $r = Read-PssaSettingsFile -Path (New-PsFile $script:RdHomeCase.Text)
        $r.Verdict | Should -BeExactly 'valid' -Because ([string]$r.Problem)
    }

    It 'B1b-K01: the review''s one-line file -- a CustomRulePath wildcard under ~ that matches nothing -- reads REJECTED and is never carried: PSScriptAnalyzer finds no rules in it' {
        $r = Read-PssaSettingsFile -Path (New-PsFile "@{ CustomRulePath = @('~/*.b1b-review-nomatch') }")
        $r.Verdict | Should -BeExactly 'rejected' -Because ([string]$r.Problem)
        $r.Problem | Should -Match 'reaches no rule module or assembly'
        @($r.Rejected) | Should -Contain 'CustomRulePath'
        $r.Entries.Contains('CustomRulePath') | Should -BeFalse -Because 'a merge must not carry an entry PSScriptAnalyzer refuses'
        (Read-PssaSettingsFile -Path (New-PsFile "@{ CustomRulePath = @('~/*.b1b-review-nomatch'); IncludeDefaultRules = `$true }")).Verdict |
            Should -BeExactly 'valid' -Because 'CONTROL: beside the default rules PSScriptAnalyzer accepts the same entry'
    }

    It 'B1b-K01: the directory check never refuses on a guess -- a tree larger than its budget counts as a rule source' {
        $root = Join-Path $TestDrive 'rd-budget'
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'a/b/c') | Out-Null
        Test-PssaSettingsRuleDirectory -Path $root -Recurse $true | Should -BeFalse -Because 'CONTROL: no rule source anywhere in the tree'
        Test-PssaSettingsRuleDirectory -Path $root -Recurse $true -Budget 2 | Should -BeTrue
    }

    It 'a drive-relative or root-relative CustomRulePath reads REJECTED even when it exists from the reader''s own location -- PSES resolves it from elsewhere' -Skip:(-not $script:PsOnWindows) {
        # Measured (dispatch 000306): 'C:rules\x.psm1' that existed from the daemon's location read VALID
        # (it is "rooted" to .NET) while PSScriptAnalyzer, run from another directory, refused it -- the
        # settled empty result this check exists to prevent. '\rules\x.psm1' names the current DRIVE's
        # root, and PSES's current drive is its log directory's, not necessarily the daemon's.
        $here = Join-Path $TestDrive 'rd-here'
        New-Item -ItemType Directory -Force -Path (Join-Path $here 'rules') | Out-Null
        Copy-Item -LiteralPath $script:RdModule -Destination (Join-Path $here 'rules\B1b.Rules.psm1')
        $driveRelative = $here.Substring(0, 2) + 'rules\B1b.Rules.psm1'
        $rootRelative = $here.Substring(2) + '\rules\B1b.Rules.psm1'
        Push-Location -LiteralPath $here
        try {
            foreach ($e in @($driveRelative, $rootRelative)) {
                Test-Path -LiteralPath $e | Should -BeTrue -Because ('CONTROL: ' + $e + ' exists from the reader''s own location')
                $r = Read-PssaSettingsFile -Path (New-PsFile ("@{ CustomRulePath = @('" + $e + "') }"))
                $r.Verdict | Should -BeExactly 'rejected' -Because $e
                $r.Problem | Should -Match 'is relative'
            }
        } finally { Pop-Location }
    }

    It 'a missing file, a relative path and a blank path read unparsable, never valid' {
        (Read-PssaSettingsFile -Path (Join-Path $TestDrive 'nope.psd1')).Verdict | Should -BeExactly 'unparsable'
        (Read-PssaSettingsFile -Path 'relative/PSScriptAnalyzerSettings.psd1').Verdict | Should -BeExactly 'unparsable'
        (Read-PssaSettingsFile -Path '').Verdict | Should -BeExactly 'unparsable'
    }

    It 'Entries carries ONLY the accepted entries, under canonical names and in canonical order; Rejected names the rest' {
        $r = Read-PssaSettingsFile -Path (New-PsFile "@{ severity = @('Warning'); Rules = @{ PSAvoidLongLines = @{ Enable = `$true } }; RuleArguments = @{}; Foo = 1; IncludeDefaultRules = 'yes' }")
        $r.Verdict | Should -BeExactly 'rejected'
        (@($r.Entries.Keys) -join ',') | Should -BeExactly 'Rules,Severity'
        (@($r.Rejected | Sort-Object) -join ',') | Should -BeExactly 'Foo,IncludeDefaultRules,RuleArguments'
        @($r.Entries['Severity']) -join ',' | Should -BeExactly 'Warning'
        [bool]$r.Entries['Rules']['PSAvoidLongLines']['Enable'] | Should -BeTrue
    }

    It 'the reader NEVER RUNS the file: a command inside the table is not executed, and the file reads unparsable' {
        $marker = Join-Path $TestDrive ('ran-' + [guid]::NewGuid().ToString('N') + '.txt')
        $text = "@{ Severity = @(New-Item -ItemType File -Path '" + $marker + "') }"
        (Read-PssaSettingsFile -Path (New-PsFile $text)).Verdict | Should -BeExactly 'unparsable'
        Test-Path -LiteralPath $marker | Should -BeFalse -Because 'nothing in a settings file is evaluated except as data'
    }

    It 'the reader NEVER RUNS a command in parentheses either: only a pure expression in parentheses is data' {
        $marker = Join-Path $TestDrive ('ran-' + [guid]::NewGuid().ToString('N') + '.txt')
        $text = "@{ Severity = (New-Item -ItemType File -Path '" + $marker + "'); Rules = @{ X = @{ N = -(New-Item -ItemType File -Path '" + $marker + "') } } }"
        (Read-PssaSettingsFile -Path (New-PsFile $text)).Verdict | Should -BeExactly 'unparsable'
        Test-Path -LiteralPath $marker | Should -BeFalse -Because 'a parenthesized command is a command, not data'
    }

    It 'B1b-R02: a parenthesized or signed value is DATA, read as PSScriptAnalyzer reads it -- the list, the boolean and the numbers it holds' {
        $r = Read-PssaSettingsFile -Path (New-PsFile ("@{ ExcludeRules = ('PSAvoidUsingCmdletAliases', 'PSAvoidGlobalVars'); IncludeDefaultRules = (`$true);" +
                " Rules = @{ PSAvoidLongLines = @{ Enable = (`$true); MaximumLineLength = (120); Other = -(5) } } }"))
        $r.Verdict | Should -BeExactly 'valid' -Because ([string]$r.Problem)
        (@($r.Entries['ExcludeRules']) -join ',') | Should -BeExactly 'PSAvoidUsingCmdletAliases,PSAvoidGlobalVars'
        $r.Entries['IncludeDefaultRules'] | Should -BeOfType [bool]
        $r.Entries['IncludeDefaultRules'] | Should -BeTrue
        $r.Entries['Rules']['PSAvoidLongLines']['MaximumLineLength'] | Should -Be 120
        $r.Entries['Rules']['PSAvoidLongLines']['Other'] | Should -Be -5
    }

    It 'severity names follow the measured enum parse: <Entry> -> <Ok>' -TestCases @(
        @{ Entry = 'Warning'; Ok = $true }
        @{ Entry = 'information'; Ok = $true }
        @{ Entry = 'PARSEERROR'; Ok = $true }
        @{ Entry = '  Error  '; Ok = $true }
        @{ Entry = '7'; Ok = $true }
        @{ Entry = 'Warning,Error'; Ok = $true }
        @{ Entry = 'Hint'; Ok = $false }
        @{ Entry = ''; Ok = $false }
        @{ Entry = 'Warning,'; Ok = $false }
        @{ Entry = '99999999999'; Ok = $false }
        @{ Entry = '-1'; Ok = $false }
    ) {
        param($Entry, $Ok)
        Test-PssaSettingsSeverityName $Entry | Should -Be $Ok
    }

    Context 'PARITY with the vendored PSScriptAnalyzer on this host' -Skip:$script:PsUnsupported {

        BeforeAll {
            $script:RpData = if (-not [string]::IsNullOrWhiteSpace($env:PSLS_TEST_DATA_DIR)) { $env:PSLS_TEST_DATA_DIR } else { Join-Path ([System.IO.Path]::GetTempPath()) 'psls-sarifscan-test-data' }
            New-Item -ItemType Directory -Force -Path $script:RpData | Out-Null
            $prevData = $env:CLAUDE_PLUGIN_DATA
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $env:CLAUDE_PLUGIN_DATA = $script:RpData
                $hostExe = Resolve-PsHost 'pwsh'
                & $hostExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:PsScripts 'ensure-pssa.ps1') 2>&1 | Out-Null
                $script:RpManifest = [string](Find-VendoredPssaManifest)
            } finally { $ErrorActionPreference = $prevEap; $env:CLAUDE_PLUGIN_DATA = $prevData }
            # Every fixture of the matrix, plus the boundary case, written once; one child runs the real
            # analyzer over all of them, the way PSES 4.6.0 calls it (-Severity beside -Settings), from an
            # EMPTY working directory -- PSES runs from the daemon's log directory, never the repository's.
            $script:RpDir = Join-Path $TestDrive 'parity'
            New-Item -ItemType Directory -Force -Path $script:RpDir | Out-Null
            $script:RpFiles = [ordered]@{}
            $i = 0
            foreach ($c in @($script:RdCases)) {
                $i++
                $p = Join-Path $script:RpDir ('case-' + $i + '.psd1')
                [System.IO.File]::WriteAllText($p, [string]$c.Text, (New-Object System.Text.UTF8Encoding($false)))
                $script:RpFiles[[string]$c.Name] = $p
            }
            # The boundary (review finding B1b-K01 closed the rest, now matrix fixtures above): a rule source
            # that RESOLVES but holds no rule -- a module exporting no rule function, the module directory
            # around one, a .dll that is no rule assembly -- with no IncludeDefaultRules.
            $script:RpBoundaries = [ordered]@{
                'boundary-module.psd1'    = ("@{ CustomRulePath = @('" + $script:RdNoRule + "') }")
                'boundary-moduledir.psd1' = ("@{ CustomRulePath = @('" + $script:RdNoRuleDir + "') }")
                'boundary-assembly.psd1'  = ("@{ CustomRulePath = @('" + $script:RdFakeAssembly + "') }")
            }
            foreach ($k in @($script:RpBoundaries.Keys)) { [System.IO.File]::WriteAllText((Join-Path $script:RpDir $k), [string]$script:RpBoundaries[$k]) }
            # Values PSScriptAnalyzer ACCEPTS that the reader still refuses (review finding B1b-R02 kept the
            # reader to parentheses and signs): stricter by design, measured, kept visible below.
            $script:RpStricter = [ordered]@{
                'stricter-subexpression.psd1' = "@{ Severity = `$('Warning') }"
                'stricter-not.psd1'           = "@{ IncludeDefaultRules = -not `$false }"
                'stricter-exclaim.psd1'       = "@{ IncludeDefaultRules = !`$false }"
                'stricter-bnot.psd1'          = "@{ Rules = @{ PSAvoidLongLines = @{ Other = -bnot 5 } } }"
            }
            foreach ($k in @($script:RpStricter.Keys)) { [System.IO.File]::WriteAllText((Join-Path $script:RpDir $k), [string]$script:RpStricter[$k]) }
            $cwd = Join-Path $TestDrive 'parity-cwd'
            New-Item -ItemType Directory -Force -Path $cwd | Out-Null
            $driver = Join-Path $script:RpDir 'driver.ps1'
            [System.IO.File]::WriteAllText($driver, (@(
                        'param([string]$Manifest, [string]$Dir)'
                        '$ErrorActionPreference = ''Stop'''
                        'Import-Module $Manifest -Force'
                        '$code = ''gci | % { $_ }'' + [string][char]10'
                        'foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Filter ''*.psd1'')) {'
                        '    $ok = $true'
                        '    try { $null = @(Invoke-ScriptAnalyzer -ScriptDefinition $code -Severity @(''Error'', ''Warning'', ''Information'') -Settings $f.FullName -ErrorAction Stop) } catch { $ok = $false }'
                        '    [string]$f.Name + ''='' + [string]$ok'
                        '}') -join "`n"))
            $script:RpVerdicts = @{}
            if (-not [string]::IsNullOrWhiteSpace($script:RpManifest)) {
                $exe = (Get-Process -Id $PID).Path
                $prev = Get-Location
                try {
                    Set-Location -LiteralPath $cwd
                    $lines = @(& $exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $driver -Manifest $script:RpManifest -Dir $script:RpDir 2>$null)
                } finally { Set-Location $prev }
                foreach ($l in $lines) {
                    $kv = ([string]$l).Split('=')
                    if ($kv.Count -eq 2) { $script:RpVerdicts[$kv[0]] = ($kv[1] -eq 'True') }
                }
            }
        }

        It 'the vendored analyzer was found and judged every fixture (this Context cannot pass vacuously)' {
            $script:RpManifest | Should -Not -BeNullOrEmpty
            $script:RpVerdicts.Count | Should -Be (@($script:RdCases).Count + $script:RpBoundaries.Count + $script:RpStricter.Count)
        }

        It 'every fixture''s verdict equals whether PSScriptAnalyzer accepts it, called as PSES calls it' {
            $mismatch = New-Object System.Collections.Generic.List[string]
            $i = 0
            foreach ($c in @($script:RdCases)) {
                $i++
                $pssa = $script:RpVerdicts[('case-' + $i + '.psd1')]
                $mine = ((Read-PssaSettingsFile -Path $script:RpFiles[[string]$c.Name]).Verdict -eq 'valid')
                if ($mine -ne $pssa) { $mismatch.Add(([string]$c.Name + ': reader valid=' + $mine + ', PSScriptAnalyzer accepted=' + $pssa)) }
            }
            ($mismatch.ToArray() -join '; ') | Should -BeExactly ''
        }

        It 'BOUNDARY, documented in docs/repository-scanning.md: a rule module or assembly that resolves but holds no rule, without IncludeDefaultRules, reads valid here and is refused by PSScriptAnalyzer' {
            # Measured, so the gap stays visible: whether a module or an assembly HOLDS a rule is not
            # something a static read can see without loading it (left to a runtime signal, A3). Every
            # other way a CustomRulePath reaches no rule is refused since review finding B1b-K01 -- the
            # matrix fixtures above. If PSScriptAnalyzer ever accepts these, or the reader ever refuses
            # them, this test says so.
            foreach ($k in @($script:RpBoundaries.Keys)) {
                (Read-PssaSettingsFile -Path (Join-Path $script:RpDir $k)).Verdict | Should -BeExactly 'valid' -Because $k
                $script:RpVerdicts[$k] | Should -BeFalse -Because $k
            }
        }

        It 'KEPT STRICTER, documented in docs/repository-scanning.md: a sub-expression holding data, and the operators -not, ! and -bnot, read unparsable here though PSScriptAnalyzer accepts them' {
            # Stricter is the safe direction for certification (a managed scan refuses; an unmanaged one
            # warns and falls back to PSES's defaults). If PSScriptAnalyzer ever refuses these, or the reader
            # ever accepts them, this test says so.
            foreach ($k in @($script:RpStricter.Keys)) {
                (Read-PssaSettingsFile -Path (Join-Path $script:RpDir $k)).Verdict | Should -BeExactly 'unparsable' -Because $k
                $script:RpVerdicts[$k] | Should -BeTrue -Because $k
            }
        }
    }
}

Describe 'The RequiredRules merge carries exactly what PSScriptAnalyzer accepts (dispatch 000306 B1b, review finding B1-K04)' {

    It 'Rules and Severity SURVIVE the merge; Severities, RuleArguments and FilePath never reach the merged text' {
        $repo = New-PsFile ("@{ IncludeRules = @('PSAvoidUsingCmdletAliases', 'PSAvoidLongLines'); Severity = @('Warning', 'Error');" +
            " Rules = @{ PSAvoidLongLines = @{ Enable = `$true; MaximumLineLength = 40 } }; Severities = @('Error');" +
            " RuleArguments = @{ X = @{ Enable = `$true } }; FilePath = 'x.ps1' }")
        $m = Merge-RequiredRulesSettings -ResolvedSettingsPath $repo -RequiredRules @('PSAvoidGlobalVars') -CurrentPsesTag 'v4.6.0'
        (@($m.Keys | Sort-Object) -join ',') | Should -BeExactly 'IncludeRules,Rules,Severity'
        @($m.IncludeRules) -join ',' | Should -BeExactly 'PSAvoidUsingCmdletAliases,PSAvoidLongLines,PSAvoidGlobalVars'
        @($m.Severity) -join ',' | Should -BeExactly 'Warning,Error'
        [int]$m.Rules['PSAvoidLongLines']['MaximumLineLength'] | Should -Be 40
        $text = ConvertTo-MergedPssaSettingsText -Settings $m
        $text | Should -Not -Match 'Severities|RuleArguments|FilePath'
        $text | Should -Match 'Severity = '
        $text | Should -Match 'Rules = '
    }

    It 'every key the renderer may write is one PSScriptAnalyzer accepts (the old list wrote three it rejects)' {
        $src = [System.IO.File]::ReadAllText((Join-Path $script:PsRepo 'scripts/lib/lsp-common.ps1'))
        $body = $src.Substring($src.IndexOf('function ConvertTo-MergedPssaSettingsText'))
        $body = $body.Substring(0, $body.IndexOf('function Get-MergedPssaSettingsDir'))
        $list = [regex]::Match($body, "foreach \(\`$key in @\(([^)]*)\)\)")
        $list.Success | Should -BeTrue
        $keys = @([regex]::Matches($list.Groups[1].Value, "'([A-Za-z]+)'") | ForEach-Object { $_.Groups[1].Value })
        $keys.Count | Should -Be 7 -Because 'the renderer writes every accepted key, and only those'
        (@($keys | Sort-Object) -join ',') | Should -BeExactly (@(Get-PssaSettingsKeyNames | Sort-Object) -join ',')
    }

    It 'a merge of IncludeRules and ExcludeRules alone renders byte-for-byte the text it always had (so the same content-addressed name)' {
        $t = ConvertTo-MergedPssaSettingsText -Settings @{ IncludeRules = @('A', 'B'); ExcludeRules = @('C') }
        $want = '# GENERATED by Write-MergedPssaSettingsFile (dispatch 000294). DO NOT EDIT.' + "`n" + '@{' + "`n" +
            "    IncludeRules = @('A', 'B')" + "`n" + "    ExcludeRules = @('C')" + "`n" + '}' + "`n"
        $t | Should -BeExactly $want
    }

    It 'the merged file of a Rules-bearing repository reads back VALID -- a double argument and a custom rule''s Module\Name key included' {
        $repo = New-PsFile ("@{ IncludeRules = @('PSAvoidLongLines'); Rules = @{ PSAvoidLongLines = @{ Enable = `$true; MaximumLineLength = 1.5 };" +
            " 'My.Rules\Measure-Thing' = @{ Enable = `$true } } }")
        $m = Merge-RequiredRulesSettings -ResolvedSettingsPath $repo -RequiredRules @('PSAvoidGlobalVars') -CurrentPsesTag 'v4.6.0'
        $p = Write-MergedPssaSettingsFile -Settings $m -DataRoot (Join-Path $TestDrive ('mr-' + [guid]::NewGuid().ToString('N').Substring(0, 8)))
        $p | Should -Not -BeNullOrEmpty
        $back = Read-PssaSettingsFile -Path $p
        $back.Verdict | Should -BeExactly 'valid' -Because ([string]$back.Problem)
        [double]$back.Entries['Rules']['PSAvoidLongLines']['MaximumLineLength'] | Should -Be 1.5
        @($back.Entries['Rules'].Keys) | Should -Contain 'My.Rules\Measure-Thing'
    }

    It 'B1b-I01: a <Form> rule argument survives the merge with its TYPE and its value (it rendered $null, or another type)' -TestCases @(
        @{ Form = '[uint32]120' }
        @{ Form = '120d' }
        @{ Form = '0.1000000000000000000000000001d' }
        @{ Form = '[byte]120' }
        @{ Form = '[single]1.1' }
        @{ Form = '[long]120' }
        @{ Form = '[double]120' }
        @{ Form = "[double]'NaN'" }
        @{ Form = '[int16]-120' }
        @{ Form = '[uint16]120' }
        @{ Form = "[uint64]'18446744073709551615'" }
        @{ Form = '[sbyte]-5' }
    ) {
        param($Form)
        $repo = New-PsFile ("@{ Rules = @{ PSAvoidLongLines = @{ Enable = `$true; MaximumLineLength = 40; Other = " + $Form + ' } } }')
        $before = Read-PssaSettingsFile -Path $repo
        $before.Verdict | Should -BeExactly 'valid' -Because ('CONTROL: the repository file is one PSScriptAnalyzer accepts -- ' + [string]$before.Problem)
        $orig = $before.Entries['Rules']['PSAvoidLongLines']['Other']
        $m = Merge-RequiredRulesSettings -ResolvedSettingsPath $repo -RequiredRules @('PSAvoidGlobalVars') -CurrentPsesTag 'v4.6.0'
        $p = Write-MergedPssaSettingsFile -Settings $m -DataRoot (Join-Path $TestDrive ('i01-' + [guid]::NewGuid().ToString('N').Substring(0, 8)))
        $p | Should -Not -BeNullOrEmpty
        $back = Read-PssaSettingsFile -Path $p
        $back.Verdict | Should -BeExactly 'valid' -Because ([string]$back.Problem + ' -- ' + [System.IO.File]::ReadAllText($p))
        $v = $back.Entries['Rules']['PSAvoidLongLines']['Other']
        $v.GetType().FullName | Should -BeExactly $orig.GetType().FullName
        if ($orig -is [double] -and [double]::IsNaN($orig)) { [double]::IsNaN($v) | Should -BeTrue } else { $v | Should -Be $orig }
    }

    It 'B1b-I01: a PowerShell 7 suffix literal (120u, 120uy, 120s, 120ul) survives the merge with its type' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
        $repo = New-PsFile '@{ Rules = @{ PSAvoidLongLines = @{ Enable = $true; MaximumLineLength = 120u; A = 120uy; B = 120s; C = 120ul } } }'
        $m = Merge-RequiredRulesSettings -ResolvedSettingsPath $repo -RequiredRules @('PSAvoidGlobalVars') -CurrentPsesTag 'v4.6.0'
        $p = Write-MergedPssaSettingsFile -Settings $m -DataRoot (Join-Path $TestDrive ('i01s-' + [guid]::NewGuid().ToString('N').Substring(0, 8)))
        $back = Read-PssaSettingsFile -Path $p
        $back.Verdict | Should -BeExactly 'valid' -Because ([string]$back.Problem)
        $t = $back.Entries['Rules']['PSAvoidLongLines']
        $t['MaximumLineLength'] | Should -BeOfType [uint32]
        $t['A'] | Should -BeOfType [byte]
        $t['B'] | Should -BeOfType [int16]
        $t['C'] | Should -BeOfType [uint64]
        [System.IO.File]::ReadAllText($p) | Should -Not -Match '120u' -Because 'the merged file is read by either host, and Windows PowerShell 5.1 has no suffix literals'
    }

    It 'an int and a double rule argument render as they did, and read back the same (the I01 control)' {
        (ConvertTo-Psd1Literal 120) | Should -BeExactly '120'
        (ConvertTo-Psd1Literal (-7)) | Should -BeExactly '-7'
        $repo = New-PsFile '@{ Rules = @{ PSAvoidLongLines = @{ Enable = $true; MaximumLineLength = 40; Other = 0.1 } } }'
        $m = Merge-RequiredRulesSettings -ResolvedSettingsPath $repo -RequiredRules @('PSAvoidGlobalVars') -CurrentPsesTag 'v4.6.0'
        $p = Write-MergedPssaSettingsFile -Settings $m -DataRoot (Join-Path $TestDrive ('i01c-' + [guid]::NewGuid().ToString('N').Substring(0, 8)))
        $back = Read-PssaSettingsFile -Path $p
        $back.Entries['Rules']['PSAvoidLongLines']['Other'] | Should -BeOfType [double]
        $back.Entries['Rules']['PSAvoidLongLines']['Other'] | Should -Be 0.1
        $back.Entries['Rules']['PSAvoidLongLines']['MaximumLineLength'] | Should -BeOfType [int]
    }

    It 'an UNPARSABLE repository file is not merged onto: the merge starts from PSES''s own default list, as before' {
        $repo = New-PsFile '@{ IncludeRules = @( this is not'
        $m = Merge-RequiredRulesSettings -ResolvedSettingsPath $repo -RequiredRules @('PSAvoidGlobalVars') -CurrentPsesTag 'v4.6.0'
        @($m.IncludeRules).Count | Should -Be 16
        ($m.Keys -join ',') | Should -BeExactly 'IncludeRules'
    }

    It 'the merge uses the read it is HANDED (-ResolvedSettings), so a caller merges exactly what it validated' {
        $repo = New-PsFile "@{ IncludeRules = @('FromDisk') }"
        $handed = [ordered]@{ Path = $repo; Verdict = 'valid'; Problem = ''; Entries = [ordered]@{ IncludeRules = @('FromTheRead') }; Rejected = @() }
        $m = Merge-RequiredRulesSettings -ResolvedSettingsPath $repo -RequiredRules @('PSAvoidGlobalVars') -ResolvedSettings $handed -CurrentPsesTag 'v4.6.0'
        @($m.IncludeRules) -join ',' | Should -BeExactly 'FromTheRead,PSAvoidGlobalVars'
    }
}

Describe 'The merged settings, judged by the vendored PSScriptAnalyzer: what the repository configures and the organization requires runs (dispatch 000306 B1b, review findings B1b-R01, B1b-K02, B1b-I01)' -Skip:$script:PsUnsupported {

    BeforeAll {
        $script:MjData = if (-not [string]::IsNullOrWhiteSpace($env:PSLS_TEST_DATA_DIR)) { $env:PSLS_TEST_DATA_DIR } else { Join-Path ([System.IO.Path]::GetTempPath()) 'psls-sarifscan-test-data' }
        New-Item -ItemType Directory -Force -Path $script:MjData | Out-Null
        $prevData = $env:CLAUDE_PLUGIN_DATA
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $env:CLAUDE_PLUGIN_DATA = $script:MjData
            & (Resolve-PsHost 'pwsh') -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:PsScripts 'ensure-pssa.ps1') 2>&1 | Out-Null
            $script:MjManifest = [string](Find-VendoredPssaManifest)
        } finally { $ErrorActionPreference = $prevEap; $env:CLAUDE_PLUGIN_DATA = $prevData }
        # Each case: a repository settings file (or none) merged with a RequiredRules list by THIS tree's
        # Merge-RequiredRulesSettings and rendered by its ConvertTo-MergedPssaSettingsText -- the exact text
        # the daemon would hand PSES -- then judged by the analyzer the way PSES calls it, from an empty
        # working directory.
        $script:MjDir = Join-Path $TestDrive 'merged-judged'
        New-Item -ItemType Directory -Force -Path $script:MjDir | Out-Null
        $script:MjCases = [ordered]@{}
        function Add-MjCase([string]$Name, [string]$RepoText, [string[]]$Required) {
            $repo = ''
            if ($RepoText -ne '') { $repo = New-PsFile $RepoText }
            $m = Merge-RequiredRulesSettings -ResolvedSettingsPath $repo -RequiredRules $Required -CurrentPsesTag 'v4.6.0'
            $text = ConvertTo-MergedPssaSettingsText -Settings $m
            [System.IO.File]::WriteAllText((Join-Path $script:MjDir ($Name + '.psd1')), $text, (New-Object System.Text.UTF8Encoding($false)))
            $script:MjCases[$Name] = $text
        }
        Add-MjCase 'i01-uint32-line-length' "@{ IncludeRules = @('PSAvoidLongLines'); Rules = @{ PSAvoidLongLines = @{ Enable = `$true; MaximumLineLength = [uint32]40 } } }" @('PSAvoidGlobalVars')
        # The sample: a plural noun, an alias, a global and a 62-column line.
        [System.IO.File]::WriteAllText((Join-Path $script:MjDir 'code.txt'), ("function Get-Items { param() 'x' }`ngci`n`$global:mj = 1`n# " + ('x' * 60) + "`n"))
        $driver = Join-Path $TestDrive 'merged-judged-driver.ps1'
        [System.IO.File]::WriteAllText($driver, (@(
                    'param([string]$Manifest, [string]$Dir)'
                    '$ErrorActionPreference = ''Stop'''
                    'Import-Module $Manifest -Force'
                    '$code = [System.IO.File]::ReadAllText((Join-Path $Dir ''code.txt''))'
                    'foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Filter ''*.psd1'')) {'
                    '    $r = ''refused'''
                    '    try { $r = (@(Invoke-ScriptAnalyzer -ScriptDefinition $code -Severity @(''Error'', ''Warning'', ''Information'') -Settings $f.FullName -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.RuleName } | Sort-Object -Unique) -join '','') } catch { $r = ''refused'' }'
                    '    [string]$f.BaseName + ''='' + $r'
                    '}') -join "`n"))
        $script:MjResults = @{}
        if (-not [string]::IsNullOrWhiteSpace($script:MjManifest)) {
            $cwd = Join-Path $TestDrive 'merged-judged-cwd'
            New-Item -ItemType Directory -Force -Path $cwd | Out-Null
            $exe = (Get-Process -Id $PID).Path
            $prev = Get-Location
            try {
                Set-Location -LiteralPath $cwd
                $lines = @(& $exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $driver -Manifest $script:MjManifest -Dir $script:MjDir 2>$null)
            } finally { Set-Location $prev }
            foreach ($l in $lines) {
                $i = ([string]$l).IndexOf('=')
                if ($i -gt 0) { $script:MjResults[([string]$l).Substring(0, $i)] = ([string]$l).Substring($i + 1) }
            }
        }
        function Get-MjRules([string]$Name) { return @(([string]$script:MjResults[$Name]).Split(',') | Where-Object { $_ }) }
    }

    It 'the vendored analyzer judged every merged file (this Describe cannot pass vacuously)' {
        $script:MjManifest | Should -Not -BeNullOrEmpty
        $script:MjResults.Count | Should -Be $script:MjCases.Count
    }

    It 'B1b-I01: a [uint32] line length the repository sets survives the merge -- PSAvoidLongLines reports the 62-column line under it' {
        $script:MjCases['i01-uint32-line-length'] | Should -Match "MaximumLineLength = \[uint32\]'40'"
        Get-MjRules 'i01-uint32-line-length' | Should -Contain 'PSAvoidLongLines' -Because $script:MjResults['i01-uint32-line-length']
        Get-MjRules 'i01-uint32-line-length' | Should -Contain 'PSAvoidGlobalVars'
    }
}

Describe 'Stale merged settings files are swept -- never one a live daemon uses (dispatch 000306 B1b, review finding B1-K07)' {

    BeforeAll {
        function New-SwRoot {
            $d = Join-Path $TestDrive ('sw-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Force -Path (Join-Path $d 'orgpolicy-settings') | Out-Null
            return $d
        }
        function New-SwFile([string]$Path, [int]$AgeMinutes = 120) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
            [System.IO.File]::WriteAllText($Path, '@{}')
            [System.IO.File]::SetLastWriteTimeUtc($Path, [DateTime]::UtcNow.AddMinutes(-1 * $AgeMinutes))
            return $Path
        }
        function New-SwSession([string]$Root, [int]$RecordPid, $Policy, [switch]$NoPolicy) {
            $sd = Join-Path $Root 'session'
            New-Item -ItemType Directory -Force -Path $sd | Out-Null
            $rec = [ordered]@{ sessionId = 's'; pid = $RecordPid; state = 'ready' }
            if (-not $NoPolicy) { $rec['policy'] = $Policy }
            [System.IO.File]::WriteAllText((Join-Path $sd ([guid]::NewGuid().ToString('N') + '.json')), ($rec | ConvertTo-Json -Depth 6))
        }
        $script:SwSettings = @{ IncludeRules = @('PSB1bSweep') }
    }

    It 'an old merged file nobody uses, a crashed writer''s temp file and the legacy fixed file are removed; this call''s own file stays' {
        $root = New-SwRoot
        $old = New-SwFile (Join-Path $root 'orgpolicy-settings/merged-settings-0123456789abcdef.psd1')
        $tmp = New-SwFile (Join-Path $root 'orgpolicy-settings/merged-settings-0123456789abcdef.psd1.0badf00d.tmp')
        $legacy = New-SwFile (Join-Path $root 'orgpolicy-merged-settings.psd1')
        $swept = @()
        $mine = Write-MergedPssaSettingsFile -Settings $script:SwSettings -DataRoot $root -SweptOut ([ref]$swept)
        $mine | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $mine | Should -BeTrue
        foreach ($p in @($old, $tmp, $legacy)) { Test-Path -LiteralPath $p | Should -BeFalse -Because ($p + ' is stale and unused') }
        @($swept).Count | Should -Be 3
    }

    It 'a file a LIVE daemon''s session record names is kept, however old -- by either of its two fields' {
        $root = New-SwRoot
        $a = New-SwFile (Join-Path $root 'orgpolicy-settings/merged-settings-aaaaaaaaaaaaaaaa.psd1')
        $b = New-SwFile (Join-Path $root 'orgpolicy-settings/merged-settings-bbbbbbbbbbbbbbbb.psd1')
        New-SwSession -Root $root -RecordPid $PID -Policy ([ordered]@{ settings = [ordered]@{ path = $a }; requiredRules = [ordered]@{ mergedSettingsPath = '' } })
        New-SwSession -Root $root -RecordPid $PID -Policy ([ordered]@{ settings = [ordered]@{ path = '' }; requiredRules = [ordered]@{ mergedSettingsPath = $b } })
        $swept = Remove-StaleMergedPssaSettings -DataRoot $root
        Test-Path -LiteralPath $a | Should -BeTrue
        Test-Path -LiteralPath $b | Should -BeTrue
        @($swept).Count | Should -Be 0
    }

    It 'a record names its file by NAME: the same file under another spelling of the data root is still kept' {
        $root = New-SwRoot
        $a = New-SwFile (Join-Path $root 'orgpolicy-settings/merged-settings-cccccccccccccccc.psd1')
        $other = Join-Path (Join-Path $TestDrive 'another-spelling') 'orgpolicy-settings/merged-settings-cccccccccccccccc.psd1'
        New-SwSession -Root $root -RecordPid $PID -Policy ([ordered]@{ settings = [ordered]@{ path = $other }; requiredRules = [ordered]@{ mergedSettingsPath = $other } })
        [void](Remove-StaleMergedPssaSettings -DataRoot $root)
        Test-Path -LiteralPath $a | Should -BeTrue
    }

    It 'a DEAD daemon''s record protects nothing' {
        $root = New-SwRoot
        $a = New-SwFile (Join-Path $root 'orgpolicy-settings/merged-settings-dddddddddddddddd.psd1')
        $deadPid = [int]::MaxValue - 1   # no process can hold it, so the record is a dead daemon's on every platform
        (Get-Process -Id $deadPid -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty -Because 'CONTROL: the pid really is not running'
        New-SwSession -Root $root -RecordPid $deadPid -Policy ([ordered]@{ settings = [ordered]@{ path = $a }; requiredRules = [ordered]@{ mergedSettingsPath = $a } })
        [void](Remove-StaleMergedPssaSettings -DataRoot $root)
        Test-Path -LiteralPath $a | Should -BeFalse
    }

    It 'a file inside the grace window is kept (a daemon may not have recorded it yet)' {
        $root = New-SwRoot
        $young = New-SwFile (Join-Path $root 'orgpolicy-settings/merged-settings-eeeeeeeeeeeeeeee.psd1') -AgeMinutes 2
        $old = New-SwFile (Join-Path $root 'orgpolicy-settings/merged-settings-ffffffffffffffff.psd1') -AgeMinutes 30
        [void](Remove-StaleMergedPssaSettings -DataRoot $root -GraceMinutes 10)
        Test-Path -LiteralPath $young | Should -BeTrue
        Test-Path -LiteralPath $old | Should -BeFalse
    }

    It 'NEVER outside orgpolicy-settings/ or the one legacy file: other names, a directory, a nested file and a merged-looking file elsewhere all stay' {
        $root = New-SwRoot
        $keep = @(
            (New-SwFile (Join-Path $root 'orgpolicy-settings/notes.txt'))
            (New-SwFile (Join-Path $root 'orgpolicy-settings/merged-settings-0123456789ABCDEF.psd1'))
            (New-SwFile (Join-Path $root 'orgpolicy-settings/merged-settings-0123.psd1'))
            (New-SwFile (Join-Path $root 'orgpolicy-settings/sub/merged-settings-0123456789abcdef.psd1'))
            (New-SwFile (Join-Path $root 'merged-settings-0123456789abcdef.psd1'))
            (New-SwFile (Join-Path $root 'session-like/orgpolicy-merged-settings.psd1'))
        )
        $dir = Join-Path $root 'orgpolicy-settings/merged-settings-1111111111111111.psd1'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        [void](Remove-StaleMergedPssaSettings -DataRoot $root)
        foreach ($p in $keep) { Test-Path -LiteralPath $p | Should -BeTrue -Because ($p + ' is not a file the sweep owns') }
        Test-Path -LiteralPath $dir -PathType Container | Should -BeTrue -Because 'a directory is never removed (the B1 squat test relies on one)'
    }

    It 'the legacy file stays while a live daemon from before dispatch 000305 (a record with no policy block) may be using it' {
        $root = New-SwRoot
        $legacy = New-SwFile (Join-Path $root 'orgpolicy-merged-settings.psd1')
        New-SwSession -Root $root -RecordPid $PID -NoPolicy
        [void](Remove-StaleMergedPssaSettings -DataRoot $root)
        Test-Path -LiteralPath $legacy | Should -BeTrue
    }

    It 'a session record that cannot be read stops the whole sweep (nobody can say what is in use)' {
        $root = New-SwRoot
        $old = New-SwFile (Join-Path $root 'orgpolicy-settings/merged-settings-9999999999999999.psd1')
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'session') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $root 'session/half-written.json'), '{ "pid": 12')
        [void](Remove-StaleMergedPssaSettings -DataRoot $root)
        Test-Path -LiteralPath $old | Should -BeTrue
    }

    It 'reusing an existing merged file refreshes its write time, so the grace window covers the gap before the record names it' {
        $root = New-SwRoot
        $p = Write-MergedPssaSettingsFile -Settings $script:SwSettings -DataRoot $root
        [System.IO.File]::SetLastWriteTimeUtc($p, [DateTime]::UtcNow.AddHours(-3))
        $again = Write-MergedPssaSettingsFile -Settings $script:SwSettings -DataRoot $root
        $again | Should -BeExactly $p
        [System.IO.File]::GetLastWriteTimeUtc($p) | Should -BeGreaterThan ([DateTime]::UtcNow.AddMinutes(-5))
    }
}

Describe 'The daemon validates settings before PSES, records a terminal state when resolution throws, and forgets a dead child''s evidence (dispatch 000306 B1b, review findings B1-K04, B1-K05, B1-OOB-I01)' {

    BeforeAll {
        # The daemon's OWN functions, lifted from scripts/pses-daemon.ps1 by AST and defined verbatim here,
        # with PSES stubbed: Send-Lsp records what would have been pushed, Write-DLog what would have been
        # logged, and the PSES version is the pinned one. The daemon's parameters and state are script
        # variables, exactly as the functions read them.
        $daemonAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:PsScripts 'pses-daemon.ps1'), [ref]$null, [ref]$null)
        foreach ($name in @('Initialize-PssaSettings', 'Reset-PsesState')) {
            $fn = $daemonAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
            if ($null -eq $fn) { throw ('pses-daemon.ps1 has no ' + $name) }
            . ([scriptblock]::Create([string]$fn.Extent.Text))
        }
        $top = @($daemonAst.EndBlock.Statements | Where-Object {
                $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$script:policyApplication' })
        if ($top.Count -ne 1) { throw ('pses-daemon.ps1 must build ONE top-level startup record; found ' + $top.Count) }
        $script:DmStartup = [scriptblock]::Create('param($OrgPolicyPath) ' + $top[0].Right.Extent.Text)
        function Write-DLog { param([string]$m) [void]$script:DmLog.Add($m) }
        function Send-Lsp { param($obj) [void]$script:DmSent.Add($obj) }
        function Get-DaemonPsesVersionTag { return 'v4.6.0' }

        function Reset-DmDaemon {
            # A fresh daemon: its parameters, its settings state and its startup record.
            param([string]$Policy = '', [string]$Override = '')
            $script:OrgPolicyPath = $Policy
            $script:SettingsPath = $Override
            $script:Ruleset = 'pses-default'
            $script:DataRoot = Join-Path $TestDrive ('dm-data-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Force -Path $script:DataRoot | Out-Null
            $script:settingsResolved = $false
            $script:settingsPathInUse = ''
            $script:buf = New-Object System.Collections.Generic.List[byte]
            $script:DmLog = New-Object System.Collections.ArrayList
            $script:DmSent = New-Object System.Collections.ArrayList
            $script:policyApplication = & $script:DmStartup $Policy
        }
        function New-DmRepo([string]$Settings = '') {
            $d = Join-Path $TestDrive ('dm-repo-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Force -Path $d | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $d 'thing.ps1'), "gci`n")
            if ($Settings -ne '') { [System.IO.File]::WriteAllText((Join-Path $d 'PSScriptAnalyzerSettings.psd1'), $Settings) }
            return $d
        }
        function Get-DmPushed {
            # The settings paths the daemon pushed to PSES.
            return @(@($script:DmSent) | ForEach-Object { [string]$_.params.settings.powershell.scriptAnalysis['settingsPath'] })
        }
        $script:DmRequired = New-PsFile "@{ RequiredRules = @('PSAvoidGlobalVars') }" -Name 'org-required.psd1'
        $script:DmExclude = New-PsFile "@{ ExcludeRules = @('PSUseApprovedVerbs') }" -Name 'org-exclude.psd1'
        $script:DmRejectedText = "@{ IncludeRules = @('PSAvoidUsingCmdletAliases'); RuleArguments = @{ PSAvoidUsingCmdletAliases = @{ Enable = `$true } } }"
    }

    It 'a valid repository settings file is handed to PSES and recorded valid' {
        Reset-DmDaemon -Policy $script:DmExclude
        $repo = New-DmRepo "@{ IncludeRules = @('PSAvoidUsingCmdletAliases') }"
        Initialize-PssaSettings -FilePath (Join-Path $repo 'thing.ps1') -ProjectRoot $repo
        (Get-DmPushed) | Should -Contain (Join-Path $repo 'PSScriptAnalyzerSettings.psd1')
        $script:policyApplication.settings.validation | Should -BeExactly 'valid'
        $script:policyApplication.settings.source | Should -BeExactly 'resolved'
        $script:policyApplication.requiredRules.state | Should -BeExactly 'not-required'
    }

    It 'a REJECTED repository settings file is never handed to PSES: default rules, validation rejected, and the detail names it' {
        Reset-DmDaemon -Policy $script:DmExclude
        $repo = New-DmRepo $script:DmRejectedText
        Initialize-PssaSettings -FilePath (Join-Path $repo 'thing.ps1') -ProjectRoot $repo
        @($script:DmSent).Count | Should -Be 0 -Because 'a settings file PSScriptAnalyzer rejects makes PSES analyze nothing'
        $script:settingsPathInUse | Should -BeExactly ''
        $script:policyApplication.settings.validation | Should -BeExactly 'rejected'
        $script:policyApplication.settings.validationDetail | Should -Match 'resolved settings file: .RuleArguments. is not a key'
        $script:policyApplication.settings.delivered | Should -BeFalse
        (@($script:DmLog) -join "`n") | Should -Match 'would REJECT'
    }

    It 'an unparsable one reads unparsable, and no settings file at all reads none' {
        Reset-DmDaemon
        $repo = New-DmRepo '@{ Severity = (Get-Date) }'
        Initialize-PssaSettings -FilePath (Join-Path $repo 'thing.ps1') -ProjectRoot $repo
        $script:policyApplication.settings.validation | Should -BeExactly 'unparsable'
        @($script:DmSent).Count | Should -Be 0
        Reset-DmDaemon
        $bare = New-DmRepo
        Initialize-PssaSettings -FilePath (Join-Path $bare 'thing.ps1') -ProjectRoot $bare
        $script:policyApplication.settings.validation | Should -BeExactly 'none'
        $script:policyApplication.requiredRules.state | Should -BeExactly 'not-configured'
    }

    It 'RequiredRules over a REJECTED repository file: the merged file carries only the accepted entries and IS handed; validation still says rejected' {
        Reset-DmDaemon -Policy $script:DmRequired
        $repo = New-DmRepo $script:DmRejectedText
        Initialize-PssaSettings -FilePath (Join-Path $repo 'thing.ps1') -ProjectRoot $repo
        $script:policyApplication.requiredRules.state | Should -BeExactly 'activated'
        $merged = [string]$script:policyApplication.requiredRules.mergedSettingsPath
        (Get-DmPushed) | Should -Contain $merged
        [System.IO.File]::ReadAllText($merged) | Should -Not -Match 'RuleArguments'
        (Read-PssaSettingsFile -Path $merged).Verdict | Should -BeExactly 'valid'
        $script:policyApplication.settings.validation | Should -BeExactly 'rejected' -Because 'the repository''s file is still one PSScriptAnalyzer refuses: a managed scan must not certify it'
    }

    It 'a merged file PSScriptAnalyzer would reject is not handed either: RequiredRules settings-rejected, and the pre-merge path is used' {
        Reset-DmDaemon -Policy $script:DmRequired
        $repo = New-DmRepo "@{ IncludeRules = @('PSAvoidUsingCmdletAliases') }"
        Mock Read-PssaSettingsFile -ParameterFilter { [string]$Path -like '*merged-settings-*' } -MockWith {
            [ordered]@{ Path = $Path; Verdict = 'rejected'; Problem = 'staged'; Entries = [ordered]@{}; Rejected = @() }
        }
        Initialize-PssaSettings -FilePath (Join-Path $repo 'thing.ps1') -ProjectRoot $repo
        $script:policyApplication.requiredRules.state | Should -BeExactly 'settings-rejected'
        (Get-DmPushed) -join ',' | Should -BeExactly (Join-Path $repo 'PSScriptAnalyzerSettings.psd1')
        $script:policyApplication.settings.validation | Should -BeExactly 'rejected'
        $script:policyApplication.settings.validationDetail | Should -Match '^merged settings file: staged'
    }

    It 'a settings resolution that THROWS records the terminal settings-unresolved -- and a second call leaves it so (review finding B1-OOB-I01)' {
        Reset-DmDaemon -Policy $script:DmRequired
        $repo = New-DmRepo
        Mock Resolve-PssaSettingsPath { throw 'Illegal characters in path.' }
        Initialize-PssaSettings -FilePath (Join-Path $repo 'thing.ps1') -ProjectRoot $repo
        $script:policyApplication.requiredRules.state | Should -BeExactly 'settings-unresolved'
        $script:policyApplication.settings.validation | Should -BeExactly 'unresolved'
        $script:policyApplication.settings.validationDetail | Should -Match 'settings resolution failed: Illegal characters'
        @($script:DmSent).Count | Should -Be 0
        Initialize-PssaSettings -FilePath (Join-Path $repo 'thing.ps1') -ProjectRoot $repo
        $script:policyApplication.requiredRules.state | Should -BeExactly 'settings-unresolved' -Because 'terminal for this PSES child -- not pending, for the daemon''s whole life'
    }

    It 'with no policy configured, a throwing resolution still records unresolved settings (RequiredRules not-configured)' {
        Reset-DmDaemon
        $repo = New-DmRepo
        Mock Resolve-PssaSettingsPath { throw 'boom' }
        Initialize-PssaSettings -FilePath (Join-Path $repo 'thing.ps1') -ProjectRoot $repo
        $script:policyApplication.requiredRules.state | Should -BeExactly 'not-configured'
        $script:policyApplication.settings.validation | Should -BeExactly 'unresolved'
    }

    It 'Reset-PsesState returns the record to the startup state and forgets the settings path (review finding B1-K05)' {
        Reset-DmDaemon -Policy $script:DmRequired
        $repo = New-DmRepo
        Initialize-PssaSettings -FilePath (Join-Path $repo 'thing.ps1') -ProjectRoot $repo
        $script:policyApplication.requiredRules.state | Should -BeExactly 'activated'
        $script:settingsPathInUse | Should -Not -BeNullOrEmpty
        Reset-PsesState
        $script:policyApplication.requiredRules.state | Should -BeExactly 'pending'
        $script:policyApplication.settings.validation | Should -BeExactly 'pending'
        $script:settingsPathInUse | Should -BeExactly ''
        $script:settingsResolved | Should -BeFalse
    }

    It 'THE STAGED RE-SPAWN: activated, PSES re-spawned, the new child''s settings resolution throws -- a managed verdict now REFUSES (it certified on the dead child''s evidence)' {
        Reset-DmDaemon -Policy $script:DmRequired
        $repo = New-DmRepo
        Initialize-PssaSettings -FilePath (Join-Path $repo 'thing.ps1') -ProjectRoot $repo
        Reset-PsesState
        Mock Resolve-PssaSettingsPath { throw 'staged: settings resolution failed for the new child' }
        Initialize-PssaSettings -FilePath (Join-Path $repo 'thing.ps1') -ProjectRoot $repo
        # The binding a scan-mode answer would carry now, built as Get-ScanAnalysisBindingFor builds it.
        $daemon = Copy-PolicyApplicationEvidence -Evidence $script:policyApplication -SettingsSha256 (Get-PolicyFileSha256 -Path ([string]$script:settingsPathInUse))
        $declared = Resolve-EffectivePolicy -Path $script:DmRequired -Source 'cli'
        $client = New-PolicyAdjudicationEvidence -Resolution $declared -Path $script:DmRequired -Mode 'closed'
        $receipt = [ordered]@{
            engine = [ordered]@{ pses = '4.6.0'; pssa = '1.25.0' }
            config = [ordered]@{ state = 'unbound'; observed = [ordered]@{ severityThreshold = 'Hint'; ruleInclude = ''; ruleExclude = ''; perFileCap = 0 } }
            policy = [ordered]@{ state = 'observed'; client = $client; daemon = $daemon }
        }
        $f = [pscustomobject]@{ File = 'C:\x.ps1'; Completeness = 'complete'; Pass = 'pssa'; Receipt = (($receipt | ConvertTo-Json -Depth 8) | ConvertFrom-Json) }
        $c = Test-ScanPolicyCertification -Mode 'closed' -Declared $declared -Files @($f)
        $c.Certified | Should -BeFalse
        @($c.Files[0].Reasons) -join ',' | Should -BeExactly 'policy-evidence-missing'
    }
}

Describe 'Evidence consumers: the managed verdict, the receipt shape, doctor and the unmanaged warning (dispatch 000306 B1b)' {

    BeforeAll {
        $script:EvReq = Resolve-EffectivePolicy -Path (New-PsFile "@{ RequiredRules = @('PSAvoidGlobalVars') }" -Name 'org.psd1') -Source 'cli'
        $script:EvExc = Resolve-EffectivePolicy -Path (New-PsFile "@{ ExcludeRules = @('PSUseApprovedVerbs') }" -Name 'org.psd1') -Source 'cli'
        function New-EvFile {
            # One file's evidence as the scan reads it back: both parties agreeing, the daemon's
            # RequiredRules state and settings verdict as given.
            param($Declared, [string]$State, [string]$Validation, [string]$Detail = '')
            $needs = ([string]$Declared.obligations.mergedSettings -eq 'required')
            $sha = ('c' * 64)
            $daemon = New-PolicyApplicationEvidence -RequiredState $State -RequiredCount 1 -GuardVerifiedFor 'v4.6.0' -GuardObserved 'v4.6.0' `
                -GuardResult 'pass' -MergedPath 'm' -MergedSha256 $(if ($needs) { $sha } else { '' }) -SettingsPath 'm' `
                -SettingsSource $(if ($needs) { 'merged' } else { 'none' }) -SettingsSha256 $(if ($needs) { $sha } else { '' }) -Delivered $needs `
                -SettingsValidation $Validation -SettingsValidationDetail $Detail
            if ($State -ne 'settings-unresolved' -and $State -ne 'pending') {
                $daemon.resolution = [ordered]@{ path = 'p'; configured = $true; usable = $true; reason = ''; effectiveSha256 = [string]$Declared.identity.sha256 }
            }
            $client = New-PolicyAdjudicationEvidence -Mode 'closed'
            $client.resolution = [ordered]@{ path = 'p'; configured = $true; usable = $true; reason = ''; effectiveSha256 = [string]$Declared.identity.sha256 }
            $receipt = [ordered]@{
                engine = [ordered]@{ pses = '4.6.0'; pssa = '1.25.0' }
                config = [ordered]@{ state = 'unbound'; observed = [ordered]@{ severityThreshold = 'Hint'; ruleInclude = ''; ruleExclude = ''; perFileCap = 0 } }
                policy = [ordered]@{ state = 'observed'; client = $client; daemon = $daemon }
            }
            return [pscustomobject]@{ File = 'C:\x.ps1'; Completeness = 'complete'; Pass = 'pssa'; Receipt = (($receipt | ConvertTo-Json -Depth 8) | ConvertFrom-Json) }
        }
    }

    It 'THE CONTROL: settings <Validation> certifies (<Key>)' -TestCases @(
        @{ Validation = 'valid'; Key = 'EvReq'; State = 'activated' }
        @{ Validation = 'none'; Key = 'EvExc'; State = 'not-required' }
        @{ Validation = 'valid'; Key = 'EvExc'; State = 'not-required' }
    ) {
        param($Validation, $Key, $State)
        $decl = Get-Variable -Name $Key -Scope Script -ValueOnly
        $c = Test-ScanPolicyCertification -Mode 'closed' -Declared $decl -Files @((New-EvFile -Declared $decl -State $State -Validation $Validation))
        @($c.AllReasons) -join ',' | Should -BeExactly ''
        $c.Certified | Should -BeTrue
    }

    It 'PER-FILE REFUSAL: settings <Validation> -> <Code> (<Key>)' -TestCases @(
        @{ Validation = 'rejected'; Code = 'policy-settings-rejected'; Key = 'EvExc'; State = 'not-required' }
        @{ Validation = 'unparsable'; Code = 'policy-settings-rejected'; Key = 'EvExc'; State = 'not-required' }
        @{ Validation = 'rejected'; Code = 'policy-settings-rejected'; Key = 'EvReq'; State = 'activated' }
        @{ Validation = 'pending'; Code = 'policy-evidence-missing'; Key = 'EvExc'; State = 'not-required' }
        @{ Validation = 'unresolved'; Code = 'policy-evidence-missing'; Key = 'EvExc'; State = 'not-required' }
    ) {
        param($Validation, $Code, $Key, $State)
        $decl = Get-Variable -Name $Key -Scope Script -ValueOnly
        $c = Test-ScanPolicyCertification -Mode 'closed' -Declared $decl -Files @((New-EvFile -Declared $decl -State $State -Validation $Validation))
        $c.Certified | Should -BeFalse
        @($c.Files[0].Reasons) -join ',' | Should -BeExactly $Code
    }

    It 'a daemon record that carries NO settings verdict (an older shape) is missing evidence, never certified' {
        $f = New-EvFile -Declared $script:EvExc -State 'not-required' -Validation 'valid'
        $f.Receipt.policy.daemon.settings.PSObject.Properties.Remove('validation')
        $c = Test-ScanPolicyCertification -Mode 'closed' -Declared $script:EvExc -Files @($f)
        @($c.Files[0].Reasons) | Should -Contain 'policy-evidence-missing'
    }

    It 'RequiredRules settings-rejected -> policy-settings-rejected; the terminal settings-unresolved -> exactly policy-evidence-missing' {
        $c1 = Test-ScanPolicyCertification -Mode 'closed' -Declared $script:EvReq -Files @((New-EvFile -Declared $script:EvReq -State 'settings-rejected' -Validation 'rejected'))
        @($c1.Files[0].Reasons) -join ',' | Should -BeExactly 'policy-settings-rejected'
        foreach ($decl in @($script:EvReq, $script:EvExc)) {
            $c2 = Test-ScanPolicyCertification -Mode 'closed' -Declared $decl -Files @((New-EvFile -Declared $decl -State 'settings-unresolved' -Validation 'unresolved'))
            @($c2.Files[0].Reasons) -join ',' | Should -BeExactly 'policy-evidence-missing' -Because 'it carries no resolution, so it cannot disagree'
        }
    }

    It 'the new code is declared, and the new states are in the vocabularies the evidence builder enforces' {
        (Get-PolicyReasonTable).Contains('policy-settings-rejected') | Should -BeTrue
        (Get-PolicyRequiredRuleStates) | Should -Contain 'settings-rejected'
        (Get-PolicyRequiredRuleStates) | Should -Contain 'settings-unresolved'
        (Get-PolicySettingsValidationStates) -join ',' | Should -BeExactly 'pending,none,valid,rejected,unparsable,unresolved'
        (New-PolicyApplicationEvidence -SettingsValidation 'made-up').settings.validation | Should -BeExactly 'pending'
        (New-PolicyApplicationEvidence).settings.validation | Should -BeExactly 'pending' -Because 'an omitted observation reads not checked, never valid'
        (New-PolicyApplicationEvidence -SettingsValidationDetail ("a`nb" + [char]0x212A)).settings.validationDetail | Should -BeExactly 'a?b?'
    }

    It 'the receipt carries the verdict as typed evidence: a receipt whose settings.<Field> is not a string is malformed' -TestCases @(
        @{ Field = 'validation' }
        @{ Field = 'validationDetail' }
    ) {
        param($Field)
        $daemon = New-PolicyApplicationEvidence -RequiredState 'not-required' -SettingsValidation 'valid'
        $policy = (([ordered]@{ client = (New-PolicyAdjudicationEvidence); daemon = $daemon }) | ConvertTo-Json -Depth 8) | ConvertFrom-Json
        @(Get-ScanReceiptPolicyEvidenceProblems -Policy $policy).Count | Should -Be 0
        $policy.daemon.settings.$Field = 5
        @(Get-ScanReceiptPolicyEvidenceProblems -Policy $policy) | Should -Contain ('policy.daemon.settings.' + $Field + ' is not a string')
    }

    It 'docs/scan-receipt.schema.json requires the verdict and enumerates exactly the evidence builder''s vocabulary' {
        $schema = [System.IO.File]::ReadAllText((Join-Path $script:PsRepo 'docs/scan-receipt.schema.json')) | ConvertFrom-Json
        $settings = $schema.properties.policy.properties.daemon.oneOf[1].properties.settings
        @($settings.required) | Should -Contain 'validation'
        @($settings.required) | Should -Contain 'validationDetail'
        (@($settings.properties.validation.enum) -join ',') | Should -BeExactly ((Get-PolicySettingsValidationStates) -join ',')
    }

    It 'doctor reads the terminal settings-unresolved as not-observed with that reason -- never pending, never a match (review finding B1-OOB-I01)' {
        . (Join-Path $script:PsScripts 'doctor.ps1')
        $p = New-PsFile "@{ RequiredRules = @('PSAvoidGlobalVars') }" -Name 'org.psd1'
        $prev = $env:CLAUDE_PLUGIN_OPTION_ORGPOLICY
        try {
            $env:CLAUDE_PLUGIN_OPTION_ORGPOLICY = $p
            $rec = New-PolicyApplicationEvidence -Path $p -RequiredState 'settings-unresolved' -GuardVerifiedFor 'v4.6.0' -SettingsValidation 'unresolved' -SettingsValidationDetail 'settings resolution failed: x'
            $obs = @{ DataRootKnown = $true; DaemonPresent = $true; Determinable = $true; Policy = ((($rec | ConvertTo-Json -Depth 6) | ConvertFrom-Json)) }
            $info = Get-OrgPolicyEnforcementReportInfo -DaemonObservation $obs
            $info.enforcement.state | Should -BeExactly 'not-observed'
            $info.enforcement.reason | Should -BeExactly 'settings-unresolved'
            $info.enforcement.matchesParsed | Should -BeNullOrEmpty
            $info.applied | Should -BeTrue -Because 'the policy still parses -- applied never meant enforced'
            (@($info.Keys) -join ',') | Should -BeExactly 'path,sha256,sidecarMatch,applied,effectiveSha256,enforcement'
        } finally {
            if ($null -eq $prev) { Remove-Item Env:\CLAUDE_PLUGIN_OPTION_ORGPOLICY -ErrorAction SilentlyContinue } else { $env:CLAUDE_PLUGIN_OPTION_ORGPOLICY = $prev }
        }
    }

    It 'the unmanaged scan''s warning names the first rejected record, and stays silent for valid ones' {
        $ok = New-EvFile -Declared $script:EvExc -State 'not-required' -Validation 'valid'
        Get-ScanSettingsRejection -Files @($ok) | Should -BeExactly ''
        $bad = New-EvFile -Declared $script:EvExc -State 'not-required' -Validation 'unparsable' -Detail 'resolved settings file: it does not contain a table'
        Get-ScanSettingsRejection -Files @($ok, $bad, $null) | Should -BeExactly 'unparsable -- resolved settings file: it does not contain a table'
    }
}

Describe 'Settings files through the real daemon, every ambient plugin variable cleared (dispatch 000306 B1b)' -Skip:$script:PsUnsupported {

    BeforeAll {
        . (Join-Path $PSScriptRoot 'Integration.Common.ps1')
        . (Join-Path $PSScriptRoot 'ScanHarness.Common.ps1')
        $script:RsScan = Join-Path $script:PsScripts 'lsp-scan.ps1'
        $script:RsHost = Resolve-PsHost 'pwsh'
        $script:RsData = if (-not [string]::IsNullOrWhiteSpace($env:PSLS_TEST_DATA_DIR)) { $env:PSLS_TEST_DATA_DIR } else { Join-Path ([System.IO.Path]::GetTempPath()) 'psls-sarifscan-test-data' }
        New-Item -ItemType Directory -Force -Path $script:RsData | Out-Null
        $prevData = $env:CLAUDE_PLUGIN_DATA
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $env:CLAUDE_PLUGIN_DATA = $script:RsData
            & $script:RsHost -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:PsScripts 'ensure-pses.ps1') 2>&1 | Out-Null
            & $script:RsHost -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:PsScripts 'ensure-pssa.ps1') 2>&1 | Out-Null
        } finally { $ErrorActionPreference = $prevEap; $env:CLAUDE_PLUGIN_DATA = $prevData }

        $script:RsWork = Join-Path $script:RsData ('b1b-settings-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        function New-RsDir([string]$Name, [hashtable]$Files) {
            $d = Join-Path $script:RsWork $Name
            New-Item -ItemType Directory -Force -Path $d | Out-Null
            foreach ($k in @($Files.Keys)) {
                $p = Join-Path $d $k
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null
                [System.IO.File]::WriteAllText($p, [string]$Files[$k], (New-Object System.Text.UTF8Encoding($false)))
            }
            return $d
        }
        # A rule name unique to this run in IncludeRules (PSScriptAnalyzer matches an unknown name to nothing,
        # measured) keeps each merged text -- and so each content-addressed merged file -- this run's alone.
        $unique = 'PSB1bUnique' + [guid]::NewGuid().ToString('N')
        $thing = "function Set-RsGlobal {`n    gci`n    `$global:RsThing = 1`n}`n# " + ('x' * 60) + "`n"
        $script:RsRulesDir = New-RsDir 'src-rules' @{
            'thing.ps1'                     = $thing
            'PSScriptAnalyzerSettings.psd1' = ("@{ IncludeRules = @('PSAvoidUsingCmdletAliases', 'PSAvoidLongLines', '" + $unique + "'); Severity = @('Warning', 'Error');" +
                " Rules = @{ PSAvoidLongLines = @{ Enable = `$true; MaximumLineLength = 40 } } }`n")
        }
        $script:RsRejectedDir = New-RsDir 'src-rejected' @{
            'thing.ps1'                     = $thing
            'PSScriptAnalyzerSettings.psd1' = ("@{ IncludeRules = @('PSAvoidUsingCmdletAliases', '" + $unique + "'); RuleArguments = @{ PSAvoidUsingCmdletAliases = @{ Enable = `$true } } }`n")
        }
        $script:RsRelativeDir = New-RsDir 'src-relative' @{
            'thing.ps1'                     = $thing
            'rules/B1b.Rules.psm1'          = "function Measure-B1bNothing { param([System.Management.Automation.Language.ScriptBlockAst]`$ScriptBlockAst) return @() }`nExport-ModuleMember -Function Measure-B1bNothing`n"
            'PSScriptAnalyzerSettings.psd1' = "@{ CustomRulePath = @('./rules/B1b.Rules.psm1'); IncludeDefaultRules = `$true }`n"
        }
        $script:RsReqPolicy = Join-Path $script:RsWork 'required.psd1'
        [System.IO.File]::WriteAllText($script:RsReqPolicy, "@{ RequiredRules = @('PSAvoidGlobalVars') }`n")
        $script:RsExcPolicy = Join-Path $script:RsWork 'exclude.psd1'
        [System.IO.File]::WriteAllText($script:RsExcPolicy, "@{ ExcludeRules = @('PSUseApprovedVerbs') }`n")

        function Invoke-RsScan {
            param([string]$Target, [string]$Policy = '', [string]$Mode = '')
            $out = Join-Path $script:RsWork ('out-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.sarif')
            $a = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:RsScan, $Target, '-Format', 'sarif', '-OutputPath', $out)
            if ($Policy -ne '') { $a += @('-OrgPolicyPath', $Policy) }
            if ($Mode -ne '') { $a += @('-PolicyMode', $Mode) }
            $run = Invoke-SvChildProcess -HostExe $script:RsHost -CapMs 300000 -ArgumentList $a -ExtraEnv @{ CLAUDE_PLUGIN_DATA = $script:RsData } `
                -RemoveEnvPrefix @('CLAUDE_PLUGIN_OPTION_', 'POWERSHELL_LSP_')
            $text = Read-SvTextFile -Path $out
            $sarif = $null; $results = @(); $pol = $null; $inv = $null
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $sarif = $text | ConvertFrom-Json
                $results = @(@($sarif.runs[0].results) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.ruleId + ':' + [string]$_.level } | Sort-Object -Unique)
                $inv = $sarif.runs[0].invocations[0]
                if ($null -ne $inv.PSObject.Properties['properties']) { $pol = $inv.properties.policy }
            }
            return @{ Exit = [int]$run.ExitCode; Err = [string]$run.Err; Text = $text; Sarif = $sarif; Results = $results; Policy = $pol; Invocation = $inv; TimedOut = [bool]$run.TimedOut }
        }

        $script:Rs = @{}
        $script:Rs.RulesNoPolicy = Invoke-RsScan -Target $script:RsRulesDir
        $script:Rs.RulesManaged = Invoke-RsScan -Target $script:RsRulesDir -Policy $script:RsReqPolicy -Mode 'closed'
        $script:Rs.RejectedManaged = Invoke-RsScan -Target $script:RsRejectedDir -Policy $script:RsExcPolicy -Mode 'closed'
        $script:Rs.RejectedOpen = Invoke-RsScan -Target $script:RsRejectedDir -Policy $script:RsExcPolicy
        $script:Rs.RejectedMergeManaged = Invoke-RsScan -Target $script:RsRejectedDir -Policy $script:RsReqPolicy -Mode 'closed'
        $script:Rs.RelativeOpen = Invoke-RsScan -Target $script:RsRelativeDir
    }

    AfterAll {
        if ($script:RsWork -and (Test-Path -LiteralPath $script:RsWork)) { Remove-Item -LiteralPath $script:RsWork -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'every scan ran to its report (this Describe cannot pass vacuously)' {
        foreach ($k in @($script:Rs.Keys)) {
            $script:Rs[$k].TimedOut | Should -BeFalse -Because ($k + ' must finish')
            $script:Rs[$k].Sarif | Should -Not -BeNullOrEmpty -Because ($k + ' must write its SARIF; stderr: ' + $script:Rs[$k].Err)
        }
    }

    It 'RULES SURVIVE THE MERGE: the repository''s PSAvoidLongLines configuration runs with the required rule, and the managed scan certifies' {
        $script:Rs.RulesNoPolicy.Results | Should -Contain 'PSAvoidLongLines:warning' -Because 'CONTROL: the repository enables it through Rules'
        $m = $script:Rs.RulesManaged
        $m.Exit | Should -Be 0 -Because ('stderr: ' + $m.Err)
        $m.Policy.certification | Should -BeExactly 'certified'
        $m.Results | Should -Contain 'PSAvoidLongLines:warning' -Because 'before dispatch 000306 the merge dropped Rules and this rule went silent'
        $m.Results | Should -Contain 'PSAvoidGlobalVars:warning'
        $m.Results | Should -Contain 'PSAvoidUsingCmdletAliases:warning'
    }

    It 'A REJECTED SETTINGS FILE, managed: NOT CERTIFIED with policy-settings-rejected (it certified an empty settled result)' {
        $m = $script:Rs.RejectedManaged
        $m.Exit | Should -Be 4 -Because ('stderr: ' + $m.Err)
        [bool]$m.Invocation.executionSuccessful | Should -BeFalse
        $m.Policy.certification | Should -BeExactly 'not-certified'
        @($m.Policy.reasons) | Should -Contain 'policy-settings-rejected'
        $m.Err | Should -Match 'policy-settings-rejected'
    }

    It 'the same file UNMANAGED: a warning on stderr, the default rules analyze, exit 0 -- never an empty clean' {
        $o = $script:Rs.RejectedOpen
        $o.Exit | Should -Be 0 -Because ('stderr: ' + $o.Err)
        $o.Err | Should -Match 'would reject a settings file'
        $o.Err | Should -Match 'RuleArguments'
        $o.Results | Should -Contain 'PSAvoidUsingCmdletAliases:warning' -Because 'the fallback analyzed with PSES''s defaults instead of nothing'
        $o.Policy.certification | Should -BeExactly 'not-requested'
    }

    It 'RequiredRules over the rejected file, managed: the merged file carries the accepted entries and the required rule runs, and the scan is still refused' {
        $m = $script:Rs.RejectedMergeManaged
        $m.Exit | Should -Be 4 -Because ('stderr: ' + $m.Err)
        @($m.Policy.reasons) | Should -Contain 'policy-settings-rejected'
        $m.Results | Should -Contain 'PSAvoidGlobalVars:warning' -Because 'the merged file, without the rejected key, was valid and was handed to PSES'
    }

    It 'a RELATIVE CustomRulePath, unmanaged: warned about and fallen back from (it made PSES analyze nothing)' {
        $o = $script:Rs.RelativeOpen
        $o.Exit | Should -Be 0 -Because ('stderr: ' + $o.Err)
        $o.Err | Should -Match 'is relative'
        $o.Results | Should -Contain 'PSAvoidUsingCmdletAliases:warning'
    }

    It 'the refused and warned SARIF still validates against the vendored SARIF 2.1.0 schema' -Skip:$script:PsNoTestJson {
        $schema = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'sarif/sarif-2.1.0.json'))
        foreach ($k in @('RejectedManaged', 'RejectedOpen')) {
            (Test-Json -Json $script:Rs[$k].Text -Schema $schema -ErrorAction SilentlyContinue) | Should -BeTrue -Because $k
        }
    }
}
