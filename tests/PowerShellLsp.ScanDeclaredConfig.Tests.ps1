#Requires -Version 5.1

# A SCAN DECLARES ITS CHILDREN'S CONFIGURATION -- dispatch 000314 (ER2), enterprise-review finding ER-F02,
# rulings ER2-R2 (the declaration), ER2-R3 (nothing else moves) and ER2-R6 (in-agent behavior is untouched).
#
# The fifteen tests that specify the fix live in PowerShellLsp.ScanReadOnly.Tests.ps1: dispatch 000302 (A1)
# measured them RED and tagged them ScanRed-A3, and this dispatch turned them green and retired the tag. This
# file holds what they do not cover:
#   1. THE ROUTINE on a ProcessStartInfo, with no child: every spelling of the eight declared knobs is removed
#      -- including spellings only ANOTHER runtime's option resolver reads -- each declared value is set
#      under exactly one spelling, every other knob's variables are left exactly as they were, and this
#      process's own environment is never touched.
#   2. A SPELLING ONLY ANOTHER RUNTIME READS, through real scan children. The resolver (Get-RawPluginOption)
#      compares with PowerShell -eq, a culture-aware comparison whose ignorable and equivalent characters
#      differ by runtime: measured, PowerShell 7 reads CLAUDE_PLUGIN_OPTION_ followed by a name holding a
#      zero-width space, a circled or mathematical letter or a superscript i as the knob, and Windows
#      PowerShell 5.1 does not; 5.1 reads a thorn as 'th' and U+A7F2 (which PowerShell 7 decomposes to C) as
#      nothing, and PowerShell 7 does not. A scan run by Windows PowerShell 5.1 spawns PowerShell 7 children
#      whenever both are installed, and a PowerShell 7 scan run with -PsHost powershell spawns 5.1 children,
#      so a removal that replayed the resolver -- or the Unicode decomposition -- of the parent's runtime would
#      leave such a name for the child to read. These cases run both pairings (the second on Windows only).
#   3. THE IN-AGENT CONTROL. One fixed hostile environment; the scan declares its children's configuration
#      from this very process; then an interactive SessionStart and an interactive client -- launched as
#      plugin.json launches the hooks, inheriting the environment -- must resolve exactly the hostile values
#      they resolved before this dispatch. A declaration that reached beyond a scan child's own block (into
#      this process, or into the shared resolver every hook loads) turns it RED.
#
# The recording fakes (tests/fixtures/scan-verdict/fake-session-start.ps1, env-record-client.ps1) report what
# reached them and what the PRODUCTION resolver makes of it; PowerShellLsp.ScanReadOnly.Tests.ps1 pins their
# knob tables to the real scripts'. ASCII-only (PS 5.1 Windows-1252 trap): every other character is built
# from its code point. StrictMode-safe. Run via tests/run-tests.ps1.

$script:DcOnWindows = if (Test-Path 'Variable:\IsWindows') { [bool]$IsWindows } else { $true }
$script:DcOnLinux = (Test-Path 'Variable:\IsLinux') -and [bool]$IsLinux
$script:DcOnMacOS = (Test-Path 'Variable:\IsMacOS') -and [bool]$IsMacOS
$script:DcUnsupported = -not ($script:DcOnWindows -or $script:DcOnLinux -or $script:DcOnMacOS)

# Spellings PowerShell 7's resolver reads and Windows PowerShell 5.1's does not (measured, dispatch 000314),
# one per knob that a child records. Names hold no control character, so every OS can carry them.
$script:DcCrossRuntime = @(
    @{ Label = 'ruleInclude with a zero-width space'; Knob = 'ruleInclude'; Child = 'session-start'
        Suffix = ('rule' + [char]0x200B + 'Include'); Value = 'PSAvoidUsingCmdletAliases'; Field = 'ruleInclude'; Expect = '' }
    @{ Label = 'ruleExclude with a circled first letter'; Knob = 'ruleExclude'; Child = 'session-start'
        Suffix = ([string][char]0x24E1 + 'uleExclude'); Value = 'PSUseApprovedVerbs'; Field = 'ruleExclude'; Expect = '' }
    @{ Label = 'ps_host with a circled first letter'; Knob = 'ps_host'; Child = 'session-start'
        Suffix = ([string][char]0x24DF + 's_host'); Value = 'powershell'; Field = 'ps_host'; Expect = 'pwsh' }
    @{ Label = 'profile with a superscript i'; Knob = 'profile'; Child = 'session-start'
        Suffix = ('prof' + [char]0x2071 + 'le'); Value = 'strict'; Field = 'ruleset'; Expect = 'pses-default' }
    @{ Label = 'perFileCap with a mathematical bold first letter'; Knob = 'perFileCap'; Child = 'session-start'
        Suffix = ([char]::ConvertFromUtf32(0x1D429) + 'erFileCap'); Value = '1'; Field = 'perFileCap'; Expect = '0' }
    @{ Label = 'timeoutMs with a zero-width space'; Knob = 'timeoutMs'; Child = 'client'
        Suffix = ('time' + [char]0x200B + 'outMs'); Value = '1'; Field = 'timeoutMs'; Expect = '18000' }
    # The other direction: Windows PowerShell 5.1 reads a thorn as 'th', PowerShell 7 does not.
    @{ Label = 'severityThreshold with a thorn'; Knob = 'severityThreshold'; Child = 'session-start'
        Suffix = ('severity' + [char]0x00FE + 'reshold'); Value = 'Error'; Field = 'severityThreshold'; Expect = 'Hint' }
)

# The reverse pairing (review R1): a scan on PowerShell 7 whose children run on Windows PowerShell 5.1
# (lsp-scan.ps1 -PsHost powershell). Spellings Windows PowerShell 5.1 reads and PowerShell 7 does not: U+A7F2
# (PowerShell 7 reads and decomposes it as C; 5.1 reads it as nothing), a thorn, an oe ligature, a repetition
# mark. Windows only, where both hosts exist.
$script:DcHas51 = $script:DcOnWindows -and ($null -ne (Get-Command 'powershell.exe' -ErrorAction SilentlyContinue))
$script:DcCrossRuntime51 = @(
    @{ Label = 'ruleExclude after U+A7F2'; Knob = 'ruleExclude'; Child = 'session-start'
        Suffix = ([string][char]0xA7F2 + 'ruleExclude'); Value = 'PSUseApprovedVerbs'; Field = 'ruleExclude'; Expect = '' }
    @{ Label = 'ps_host holding U+A7F2'; Knob = 'ps_host'; Child = 'session-start'
        Suffix = ('ps' + [char]0xA7F2 + '_host'); Value = 'pwsh'; Field = 'ps_host'; Expect = 'powershell' }
    @{ Label = 'severityThreshold with a thorn'; Knob = 'severityThreshold'; Child = 'session-start'
        Suffix = ('severity' + [char]0x00FE + 'reshold'); Value = 'Error'; Field = 'severityThreshold'; Expect = 'Hint' }
    @{ Label = 'ruleExclude with a repetition mark'; Knob = 'ruleExclude'; Child = 'session-start'
        Suffix = ('rule' + [char]0x309D + 'xclude'); Value = 'PSUseApprovedVerbs'; Field = 'ruleExclude'; Expect = '' }
    @{ Label = 'scopeToEdit with an oe ligature'; Knob = 'scopeToEdit'; Child = 'client'
        Suffix = ('scopet' + [char]0x0153 + 'dit'); Value = 'true'; Field = 'scopeToEdit'; Expect = 'False' }
)
Describe 'The scan child declaration on a ProcessStartInfo (dispatch 000314, ER2)' {

    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-scan-common.ps1')
        $script:DcPrefix = 'CLAUDE_PLUGIN_OPTION_'

        function New-DcStartInfo {
            # A ProcessStartInfo whose block holds NO CLAUDE_PLUGIN_OPTION_* variable but the ones given.
            param([System.Collections.IDictionary]$Vars)
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            foreach ($n in @($psi.EnvironmentVariables.Keys)) {
                if (([string]$n).StartsWith($script:DcPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { $psi.EnvironmentVariables.Remove([string]$n) }
            }
            foreach ($k in @($Vars.Keys)) { $psi.EnvironmentVariables[[string]$k] = [string]$Vars[$k] }
            return $psi
        }

        function Get-DcBlock {
            # The block's CLAUDE_PLUGIN_OPTION_* variables as name -> value, keyed by ORDINAL name.
            param([System.Diagnostics.ProcessStartInfo]$Psi)
            $out = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
            foreach ($n in @($Psi.EnvironmentVariables.Keys)) {
                $s = [string]$n
                if ($s.StartsWith($script:DcPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { $out[$s] = [string]$Psi.EnvironmentVariables[$s] }
            }
            return , $out
        }

        function Get-DcVisible {
            # A pattern or name in a visible, ASCII-only form -- [char]0 as '*', anything else outside printable
            # ASCII as \uXXXX -- so it is compared ORDINALLY in effect: Pester's -BeExactly compares culture-aware,
            # and measured on both hosts it takes 'rule' + [char]0 + 'include' for 'ruleinclude'.
            param([string]$Text)
            $sb = New-Object System.Text.StringBuilder
            foreach ($ch in $Text.ToCharArray()) {
                $n = [int]$ch
                if ($n -eq 0) { [void]$sb.Append('*') }
                elseif ($n -ge 0x20 -and $n -le 0x7E) { [void]$sb.Append($ch) }
                else { [void]$sb.Append('\u' + $n.ToString('x4')) }
            }
            return $sb.ToString()
        }
        function Get-DcAsciiSpellings {
            # The 'NAME=value' of every variable in the block whose name, underscores stripped and ASCII
            # lower-cased, is the knob -- an ordinal reading, independent of the routine under test.
            param($Block, [string]$Key)
            $target = ($Key -replace '_', '').ToLowerInvariant()
            $hits = @(@($Block.Keys) | Where-Object {
                    [string]::Equals(([string]$_).Substring($script:DcPrefix.Length).Replace('_', '').ToLowerInvariant(), $target, [System.StringComparison]::Ordinal)
                } | ForEach-Object { [string]$_ + '=' + [string]$Block[[string]$_] })
            return (@($hits | Sort-Object) -join ',')
        }

        # Every spelling staged below is read as its knob by at least one runtime's resolver, measured
        # (dispatch 000314): the ASCII ones by both; a thorn, an oe ligature, a repetition mark and U+A7F2 by
        # Windows PowerShell 5.1 only; the others by PowerShell 7 only.
        $zw = [string][char]0x200B
        # An ORDINAL ordered dictionary, never a hash literal: a hash literal compares its keys culture-aware on
        # Windows PowerShell 5.1, where several of these names are the SAME key (measured: duplicate-key error).
        $script:DcHostile = New-Object System.Collections.Specialized.OrderedDictionary ([System.StringComparer]::Ordinal)
        $script:DcHostile.Add('CLAUDE_PLUGIN_OPTION_perFileCap', '1')
        $script:DcHostile.Add('CLAUDE_PLUGIN_OPTION_PER_FILE_CAP', '2')
        $script:DcHostile.Add(('CLAUDE_PLUGIN_OPTION_' + [char]::ConvertFromUtf32(0x1D429) + 'erFileCap'), '3')
        $script:DcHostile.Add('CLAUDE_PLUGIN_OPTION_severityThreshold', 'Error')
        $script:DcHostile.Add('CLAUDE_PLUGIN_OPTION_SEVERITY_THRESHOLD', 'Warning')
        $script:DcHostile.Add(('CLAUDE_PLUGIN_OPTION_severity' + [char]0x034F + 'Threshold'), 'Information')
        $script:DcHostile.Add(('CLAUDE_PLUGIN_OPTION_severity' + [char]0x00FE + 'reshold'), 'Error')
        $script:DcHostile.Add('CLAUDE_PLUGIN_OPTION_scopeToEdit', 'true')
        $script:DcHostile.Add('CLAUDE_PLUGIN_OPTION_SCOPE_TO_EDIT', 'yes')
        $script:DcHostile.Add(('CLAUDE_PLUGIN_OPTION_scope' + [char]0x2060 + 'ToEdit'), 'on')
        $script:DcHostile.Add(('CLAUDE_PLUGIN_OPTION_scopet' + [char]0x0153 + 'dit'), 'true')
        $script:DcHostile.Add('CLAUDE_PLUGIN_OPTION_timeoutMs', '1')
        $script:DcHostile.Add('CLAUDE_PLUGIN_OPTION_TIMEOUT_MS', '2')
        $script:DcHostile.Add(('CLAUDE_PLUGIN_OPTION_time' + [char]0x0001 + 'outMs'), '3')
        $script:DcHostile.Add('CLAUDE_PLUGIN_OPTION_profile', 'strict')
        $script:DcHostile.Add('CLAUDE_PLUGIN_OPTION_PRO_FILE', 'recommended')
        $script:DcHostile.Add(('CLAUDE_PLUGIN_OPTION_prof' + [char]0x2071 + 'le'), 'strict')
        $script:DcHostile.Add('CLAUDE_PLUGIN_OPTION_ps_host', 'powershell')
        $script:DcHostile.Add('CLAUDE_PLUGIN_OPTION_psHost', 'powershell')
        $script:DcHostile.Add(('CLAUDE_PLUGIN_OPTION_' + [char]0x24DF + 's_host'), 'powershell')
        $script:DcHostile.Add('CLAUDE_PLUGIN_OPTION_ruleInclude', 'PSAvoidUsingCmdletAliases')
        $script:DcHostile.Add('CLAUDE_PLUGIN_OPTION_RULE_INCLUDE', 'PSAvoidUsingWriteHost')
        $script:DcHostile.Add(('CLAUDE_PLUGIN_OPTION_rule' + $zw + 'Include'), 'PSAvoidGlobalVars')
        $script:DcHostile.Add(('CLAUDE_PLUGIN_OPTION_' + [char]0x24E1 + 'uleInclude'), 'PSAvoidUsingPositionalParameters')
        $script:DcHostile.Add('CLAUDE_PLUGIN_OPTION_ruleExclude', 'PSUseApprovedVerbs')
        $script:DcHostile.Add('CLAUDE_PLUGIN_OPTION_RULE_EXCLUDE', 'PSAvoidUsingWriteHost')
        $script:DcHostile.Add(('CLAUDE_PLUGIN_OPTION_rule' + [char]0x00AD + 'Exclude'), 'PSAvoidGlobalVars')
        $script:DcHostile.Add(('CLAUDE_PLUGIN_OPTION_rule' + [char]0x200D + 'Exclude'), 'PSAvoidUsingCmdletAliases')
        $script:DcHostile.Add(('CLAUDE_PLUGIN_OPTION_rule' + [char]0x309D + 'xclude'), 'PSAvoidUsingPositionalParameters')
        $script:DcHostile.Add(('CLAUDE_PLUGIN_OPTION_rul' + [char]0x0364 + 'Include'), 'PSAvoidUsingEmptyCatchBlock')
        $script:DcHostile.Add(('CLAUDE_PLUGIN_OPTION_' + [char]0xA7F2 + 'ruleExclude'), 'PSAvoidUsingWriteHost')
    }

    It 'removes every staged spelling of the eight knobs and sets each declared value under exactly one spelling' {
        $psi = New-DcStartInfo -Vars $script:DcHostile
        Set-ScanChildDeclaredOptions -StartInfo $psi -HostExe 'pwsh'
        $block = Get-DcBlock -Psi $psi
        # Ordinal, never -contains: -contains is culture-aware and would take an exotic spelling for the declared name.
        $declaredNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($n in @('CLAUDE_PLUGIN_OPTION_perFileCap', 'CLAUDE_PLUGIN_OPTION_severityThreshold', 'CLAUDE_PLUGIN_OPTION_scopeToEdit',
                'CLAUDE_PLUGIN_OPTION_timeoutMs', 'CLAUDE_PLUGIN_OPTION_profile', 'CLAUDE_PLUGIN_OPTION_ps_host')) { [void]$declaredNames.Add($n) }
        $script:DcHostile.Count | Should -Be 31 -Because 'every hostile spelling must be staged, none merged into another'
        $left = @(@($script:DcHostile.Keys) | Where-Object { -not $declaredNames.Contains([string]$_) -and $block.ContainsKey([string]$_) })
        (@($left | ForEach-Object { ([string]$_).Length }) -join ',') | Should -BeExactly '' -Because 'no staged hostile spelling may survive in a scan child''s block'
        (@($block.Keys | Sort-Object { [string]$_ } -CaseSensitive | ForEach-Object { [string]$_ + '=' + $block[[string]$_] }) -join ';') |
            Should -BeExactly ('CLAUDE_PLUGIN_OPTION_perFileCap=0;CLAUDE_PLUGIN_OPTION_profile=safe;CLAUDE_PLUGIN_OPTION_ps_host=pwsh;' +
                'CLAUDE_PLUGIN_OPTION_scopeToEdit=false;CLAUDE_PLUGIN_OPTION_severityThreshold=Hint;CLAUDE_PLUGIN_OPTION_timeoutMs=18000')
        (Get-DcAsciiSpellings -Block $block -Key 'ruleInclude') | Should -BeExactly '' -Because 'a scan runs the whole rule set its settings select'
        (Get-DcAsciiSpellings -Block $block -Key 'ruleExclude') | Should -BeExactly ''
    }

    It 'declares ps_host as the host the scan resolved, whatever host that is' {
        $psi = New-DcStartInfo -Vars @{ 'CLAUDE_PLUGIN_OPTION_PS_HOST' = 'pwsh' }
        Set-ScanChildDeclaredOptions -StartInfo $psi -HostExe 'powershell'
        (Get-DcAsciiSpellings -Block (Get-DcBlock -Psi $psi) -Key 'ps_host') | Should -BeExactly 'CLAUDE_PLUGIN_OPTION_ps_host=powershell'
    }

    It 'leaves every other knob''s variables exactly as they were, under every spelling (ruling ER2-R3)' {
        $others = New-Object System.Collections.Specialized.OrderedDictionary ([System.StringComparer]::Ordinal)
        foreach ($pair in @(
                @('CLAUDE_PLUGIN_OPTION_settingsPath', 'C:\s.psd1'), @('CLAUDE_PLUGIN_OPTION_SETTINGS_PATH', 'C:\t.psd1'),
                @('CLAUDE_PLUGIN_OPTION_editContextLines', '7'), @('CLAUDE_PLUGIN_OPTION_orgPolicy', 'C:\p.psd1'),
                @('CLAUDE_PLUGIN_OPTION_ORG_POLICY', 'C:\q.psd1'), @('CLAUDE_PLUGIN_OPTION_ruleset', 'base'),
                @('CLAUDE_PLUGIN_OPTION_moduleAwareness', 'suggest'), @('CLAUDE_PLUGIN_OPTION_referenceSurfacing', 'counts'),
                @('CLAUDE_PLUGIN_OPTION_formatOnEdit', 'apply'), @('CLAUDE_PLUGIN_OPTION_maxWaitMs', '1'),
                @('CLAUDE_PLUGIN_OPTION_MAX_WAIT_MS', '2'), @('CLAUDE_PLUGIN_OPTION_keepLastN', '3'),
                @('CLAUDE_PLUGIN_OPTION_nativeServe', 'shim'), @('CLAUDE_PLUGIN_OPTION_enableStats', 'true'),
                @('CLAUDE_PLUGIN_OPTION_debounceMs', '9'), @('CLAUDE_PLUGIN_OPTION_idleTtlMin', '4'),
                @('CLAUDE_PLUGIN_OPTION_ruleIncludes', 'near-miss'), @('CLAUDE_PLUGIN_OPTION_timeout', 'near-miss'),
                @('CLAUDE_PLUGIN_OPTION_rule-include', 'neither runtime reads an ASCII hyphen as nothing'),
                @('CLAUDE_PLUGIN_OPTION_profile s', 'near-miss'))) { $others.Add([string]$pair[0], [string]$pair[1]) }
        $others.Count | Should -Be 20 -Because 'every pair must be staged'
        $psi = New-DcStartInfo -Vars $others
        $psi.EnvironmentVariables['PERFILECAP'] = 'not an option variable'
        $psi.EnvironmentVariables['POWERSHELL_LSP_CAPTURE_MODE'] = 'off'
        Set-ScanChildDeclaredOptions -StartInfo $psi -HostExe 'pwsh'
        $changed = @(@($others.Keys) | Where-Object { [string]$psi.EnvironmentVariables[[string]$_] -cne [string]$others[$_] })
        ($changed -join ';') | Should -BeExactly ''
        [string]$psi.EnvironmentVariables['PERFILECAP'] | Should -BeExactly 'not an option variable'
        [string]$psi.EnvironmentVariables['POWERSHELL_LSP_CAPTURE_MODE'] | Should -BeExactly 'off'
    }

    It 'the declaration agrees with the copies the managed verdict keeps of it (review R3)' {
        # scripts/lib/lsp-policy.ps1 (not edited by this dispatch) keeps its own copy of the values a scan
        # declares: the daemon launch configuration a managed scan expects (Get-ScanDeclaredAnalysisConfiguration)
        # and the values its ambient refusal does not report (Get-ScanAmbientAnalysisOptions). An edit to one copy
        # alone would make a managed scan refuse every file, or report a declared value as ambient.
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-policy.ps1')
        $declared = Get-ScanChildDeclaredOptions -HostExe 'pwsh'
        $want = Get-ScanDeclaredAnalysisConfiguration
        @($want.Keys).Count | Should -BeGreaterThan 3 -Because 'the managed verdict must expect a launch configuration'
        foreach ($k in @($want.Keys)) {
            $declared.Contains([string]$k) | Should -BeTrue -Because ([string]$k + ' is in the launch configuration a managed scan expects')
            $v = if ($null -eq $declared[[string]$k]) { '' } else { [string]$declared[[string]$k] }
            $v | Should -BeExactly ([string]$want[$k]) -Because ([string]$k + ': the declared value is the one the managed verdict expects')
        }
        foreach ($k in @($declared.Keys)) {
            # ps_host is not in the refusal's table: an ambient ps_host is refused whatever it holds (unchanged).
            if ($null -eq $declared[[string]$k] -or [string]$k -eq 'ps_host') { continue }
            $one = @{ ('CLAUDE_PLUGIN_OPTION_' + [string]$k) = [string]$declared[[string]$k] }
            @(Get-ScanAmbientAnalysisOptions -Environment $one).Count | Should -Be 0 -Because ([string]$k + ' holds the declared value, which the refusal does not report')
        }
        @(Get-ScanAmbientAnalysisOptions -Environment @{ 'CLAUDE_PLUGIN_OPTION_perFileCap' = '1' }).Count | Should -Be 1 -Because 'another value is reported (the control)'
    }

    It 'edits the child''s block only -- this process''s environment keeps every hostile value' {
        $names = @('CLAUDE_PLUGIN_OPTION_RULE_INCLUDE', ('CLAUDE_PLUGIN_OPTION_rule' + [char]0x200B + 'Exclude'), 'CLAUDE_PLUGIN_OPTION_profile')
        $saved = @{}
        foreach ($n in $names) { $saved[$n] = [System.Environment]::GetEnvironmentVariable($n) }
        try {
            foreach ($n in $names) { [System.Environment]::SetEnvironmentVariable($n, 'hostile') }
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            Set-ScanChildDeclaredOptions -StartInfo $psi -HostExe 'pwsh'
            foreach ($n in $names) {
                $psi.EnvironmentVariables.ContainsKey($n) -and [string]$psi.EnvironmentVariables[$n] -eq 'hostile' | Should -BeFalse -Because 'the child''s block loses it'
                [System.Environment]::GetEnvironmentVariable($n) | Should -BeExactly 'hostile' -Because 'this process keeps it'
            }
        } finally {
            foreach ($n in $names) { [System.Environment]::SetEnvironmentVariable($n, $saved[$n]) }
        }
    }

    It 'the pattern keeps printable ASCII and reads every other character as a wildcard, whatever it decomposes to' {
        $z = [string][char]0
        (Get-DcVisible (ConvertTo-ScanOptionPattern -Text ([string][char]0x24E1 + 'ule_Include'))) | Should -BeExactly '*uleinclude' -Because 'a circled letter is a wildcard, not its decomposition'
        (Get-DcVisible (ConvertTo-ScanOptionPattern -Text ('per' + [char]0xFB01 + 'leCap'))) | Should -BeExactly 'per*lecap' -Because 'a ligature is a wildcard too'
        (Get-DcVisible (ConvertTo-ScanOptionPattern -Text ([char]::ConvertFromUtf32(0x1D42B) + 'uleInclude'))) | Should -BeExactly '*uleinclude' -Because 'a surrogate pair is one wildcard'
        (Get-DcVisible (ConvertTo-ScanOptionPattern -Text ([string][char]0xA7F2 + 'ruleExclude'))) | Should -BeExactly '*ruleexclude' -Because 'PowerShell 7 decomposes U+A7F2 to C, Windows PowerShell 5.1 reads it as nothing (review R1)'
        (Get-DcVisible (ConvertTo-ScanOptionPattern -Text ('rule' + [char]0x200B + [char]0x200D + 'Include'))) | Should -BeExactly 'rule*include' -Because 'a run of other characters is one wildcard'
        (Get-DcVisible (ConvertTo-ScanOptionPattern -Text ('rul' + [char]0x0364 + 'Include'))) | Should -BeExactly 'rul*include' -Because 'PowerShell 7 reads a combining small e as e'
        (Get-DcVisible (ConvertTo-ScanOptionPattern -Text ('severity' + [char]0x00FE + 'reshold'))) | Should -BeExactly 'severity*reshold' -Because 'Windows PowerShell 5.1 reads a thorn as th'
        (Get-DcVisible (ConvertTo-ScanOptionPattern -Text ('time' + [char]0x0001 + 'out_MS'))) | Should -BeExactly 'time*outms'
        (Get-DcVisible (ConvertTo-ScanOptionPattern -Text ('time' + [char]0xFFFE + 'outMs'))) | Should -BeExactly 'time*outms' -Because 'a noncharacter is a wildcard, never an error'
        (Get-DcVisible (ConvertTo-ScanOptionPattern -Text ('PS' + [char]0xD800 + '_HOST'))) | Should -BeExactly 'ps*host' -Because 'a lone surrogate is a wildcard, never an error'
        (Get-DcVisible (ConvertTo-ScanOptionPattern -Text 'Rule-Include')) | Should -BeExactly 'rule-include' -Because 'an ASCII hyphen is no spelling of the knob on either runtime (measured)'
        (Test-ScanOptionPatternMatch -Pattern ('rul' + $z + 'include') -Target 'ruleinclude') | Should -BeTrue
        (Test-ScanOptionPatternMatch -Pattern ('severity' + $z + 'reshold') -Target 'severitythreshold') | Should -BeTrue
        (Test-ScanOptionPatternMatch -Pattern ($z + 'ruleexclude') -Target 'ruleexclude') | Should -BeTrue -Because 'a wildcard can stand for nothing'
        (Test-ScanOptionPatternMatch -Pattern ($z + 'e' + $z) -Target 'profile') | Should -BeTrue
        (Test-ScanOptionPatternMatch -Pattern 'rule-include' -Target 'ruleinclude') | Should -BeFalse
        (Test-ScanOptionPatternMatch -Pattern ('x' + $z) -Target 'ruleinclude') | Should -BeFalse
        (Test-ScanOptionPatternMatch -Pattern 'profil' -Target 'profile') | Should -BeFalse -Because 'the whole name must fit'
        (Test-ScanOptionPatternMatch -Pattern '' -Target 'profile') | Should -BeFalse
        (Test-ScanOptionSpelling -Name ('claude_plugin_option_' + [char]0x24DF + 'sHost') -Key @('ps_host')) | Should -BeTrue
        (Test-ScanOptionSpelling -Name ('CLAUDE_PLUGIN_OPTION_rule' + [char]0x309D + 'xclude') -Key @('ruleExclude')) | Should -BeTrue -Because 'Windows PowerShell 5.1 reads a repetition mark as the letter before it'
        (Test-ScanOptionSpelling -Name ('CLAUDE_PLUGIN_OPTION_' + [char]0xA7F2 + 'ruleExclude') -Key @('ruleExclude')) | Should -BeTrue -Because 'Windows PowerShell 5.1 reads U+A7F2 as nothing (review R1)'
        (Test-ScanOptionSpelling -Name 'CLAUDE_PLUGIN_OPTIONS_psHost' -Key @('ps_host')) | Should -BeFalse -Because 'another prefix is no option variable'
        (Test-ScanOptionSpelling -Name 'CLAUDE_PLUGIN_OPTION_settingsPath' -Key @('perFileCap', 'ps_host')) | Should -BeFalse
    }

    It 'a crafted long name costs a bounded match, never a runaway one' {
        $long = 'CLAUDE_PLUGIN_OPTION_' + ((@(1..2000) | ForEach-Object { 'r' + [char]0x200B }) -join '')
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        (Test-ScanOptionSpelling -Name $long -Key @('ruleInclude', 'ruleExclude')) | Should -BeFalse
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 30
    }
}

Describe 'A spelling only another runtime reads never reaches a scan child (dispatch 000314, ER2)' -Skip:$script:DcUnsupported {

    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-scan-common.ps1')
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-scan-receipt.ps1')
        . (Join-Path $PSScriptRoot 'Integration.Common.ps1')
        . (Join-Path $PSScriptRoot 'ScanHarness.Common.ps1')
        $script:XrHost = Resolve-PsHost 'pwsh'
        if ($null -eq $script:XrHost) { throw 'no PowerShell host (pwsh / powershell) to spawn the recording fakes' }
        $script:XrSavedEnv = Save-SvAmbientEnv
        $script:XrRoot = New-SvTempRoot -Tag 'xr' -MintingFile 'tests/PowerShellLsp.ScanDeclaredConfig.Tests.ps1'
        $script:XrScripts = New-SvFakeScriptsDir -Root $script:XrRoot -ClientFixture 'env-record-client.ps1'

        function Assert-XrCase {
            # One cross-runtime case: stage the hostile name, run the scan child on $HostExe, read its record.
            param([string]$HostExe, [string]$Label, [string]$Knob, [string]$Child, [string]$Suffix, [string]$Value, [string]$Field, [string]$Expect)
            $name = 'CLAUDE_PLUGIN_OPTION_' + $Suffix
            $data = Join-Path $script:XrRoot ('data-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            $sid = 'xr-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            Restore-SvAmbientEnv -Saved @{}
            [System.Environment]::SetEnvironmentVariable($name, $Value)
            try {
                if ($Child -eq 'session-start') {
                    $info = Start-ScanDaemon -ScriptsDir $script:XrScripts -DataRoot $data -SessionId $sid -HostExe $HostExe
                    Stop-ScanDaemon -ScriptsDir $script:XrScripts -DataRoot $data -SessionId $sid -HostExe $HostExe -DaemonInfo $info
                    $info | Should -Not -BeNullOrEmpty -Because 'the fake session-start must have reported ready'
                    $file = Join-Path $data ('env-session-start-' + $sid + '.json')
                } else {
                    $src = Join-Path $data 'src'
                    New-Item -ItemType Directory -Force -Path $src | Out-Null
                    $target = Join-Path $src 'target.ps1'
                    [System.IO.File]::WriteAllText($target, "Write-Output 'x'`n", (New-Object System.Text.UTF8Encoding($false)))
                    [void](Invoke-ScanFileDiagnostics -ScriptsDir $script:XrScripts -DataRoot $data -SessionId $sid -HostExe $HostExe -FilePath $target -Cwd $src)
                    $file = @(Get-ChildItem -LiteralPath $data -File -Filter 'env-client-*.json')[0].FullName
                }
            } finally {
                Restore-SvAmbientEnv -Saved @{}
            }
            $rec = [System.IO.File]::ReadAllText($file) | ConvertFrom-Json
            $seen = @(@($rec.env.PSObject.Properties) | Where-Object { [string]::Equals([string]$_.Name, $name, [System.StringComparison]::Ordinal) })
            $seen.Count | Should -Be 0 -Because ('the hostile ' + $Knob + ' spelling must not reach a scan child (a child on the other PowerShell reads it as the knob)')
            $hostileAnywhere = @(@($rec.env.PSObject.Properties) | Where-Object { [string]$_.Value -ceq $Value -and (Test-ScanOptionSpelling -Name ([string]$_.Name) -Key @($Knob)) })
            $hostileAnywhere.Count | Should -Be 0 -Because ('the hostile ' + $Knob + ' value must reach a scan child under no spelling')
            [string]$rec.resolved.$Field.value | Should -BeExactly $Expect
        }
    }

    AfterAll {
        Restore-SvAmbientEnv -Saved $script:XrSavedEnv
        Remove-SvTempRoot -Path $script:XrRoot
    }

    It '<Label>: the hostile value reaches a PowerShell 7 scan <Child> under no spelling' -ForEach $script:DcCrossRuntime {
        Assert-XrCase -HostExe $script:XrHost -Label $Label -Knob $Knob -Child $Child -Suffix $Suffix -Value $Value -Field $Field -Expect $Expect
    }

    It '<Label>: the hostile value reaches a Windows PowerShell 5.1 scan <Child> under no spelling' -ForEach $script:DcCrossRuntime51 -Skip:(-not $script:DcHas51) {
        Assert-XrCase -HostExe 'powershell' -Label $Label -Knob $Knob -Child $Child -Suffix $Suffix -Value $Value -Field $Field -Expect $Expect
    }
}

Describe 'An interactive hook never receives the scan''s declared configuration (dispatch 000314, ER2, in-agent control)' -Skip:$script:DcUnsupported {

    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-scan-common.ps1')
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-scan-receipt.ps1')
        . (Join-Path $PSScriptRoot 'Integration.Common.ps1')
        . (Join-Path $PSScriptRoot 'ScanHarness.Common.ps1')
        $script:IaHost = Resolve-PsHost 'pwsh'
        if ($null -eq $script:IaHost) { throw 'no PowerShell host (pwsh / powershell) to spawn the recording fakes' }
        $script:IaSavedEnv = Save-SvAmbientEnv
        $script:IaRoot = New-SvTempRoot -Tag 'ia' -MintingFile 'tests/PowerShellLsp.ScanDeclaredConfig.Tests.ps1'
        $script:IaScripts = New-SvFakeScriptsDir -Root $script:IaRoot -ClientFixture 'env-record-client.ps1'

        # THE fixed hostile environment: every knob the scan declares, each under its own spelling.
        $script:IaHostile = [ordered]@{
            ruleInclude = 'PSAvoidUsingCmdletAliases'; ruleExclude = 'PSUseApprovedVerbs'; profile = 'strict'; ps_host = 'powershell'
            perFileCap = '1'; severityThreshold = 'Error'; scopeToEdit = 'true'; timeoutMs = '1234'
        }
        Restore-SvAmbientEnv -Saved @{}
        foreach ($k in @($script:IaHostile.Keys)) { Set-SvAmbientOption -Key ([string]$k) -Value ([string]$script:IaHostile[$k]) }

        function Format-IaResolved {
            # A record's resolved table as one comparable line: key=value(provenance);...
            param($Record)
            return (@(@($Record.resolved.PSObject.Properties) | ForEach-Object { [string]$_.Name + '=' + [string]$_.Value.value + '(' + [string]$_.Value.provenance + ')' }) -join ';')
        }

        try {
            # 1. THE SCAN, from this process: the production Start-ScanDaemon and Invoke-ScanFileDiagnostics.
            $scanData = Join-Path $script:IaRoot 'scan-data'
            $scanSid = 'ia-scan-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            $info = Start-ScanDaemon -ScriptsDir $script:IaScripts -DataRoot $scanData -SessionId $scanSid -HostExe $script:IaHost
            Stop-ScanDaemon -ScriptsDir $script:IaScripts -DataRoot $scanData -SessionId $scanSid -HostExe $script:IaHost -DaemonInfo $info
            if ($null -eq $info) { throw 'the fake session-start never reported ready for the scan step' }
            $src = Join-Path $script:IaRoot 'src'
            New-Item -ItemType Directory -Force -Path $src | Out-Null
            $target = Join-Path $src 'target.ps1'
            [System.IO.File]::WriteAllText($target, "Write-Output 'x'`n", (New-Object System.Text.UTF8Encoding($false)))
            [void](Invoke-ScanFileDiagnostics -ScriptsDir $script:IaScripts -DataRoot $scanData -SessionId $scanSid -HostExe $script:IaHost -FilePath $target -Cwd $src)
            $script:IaScanStart = [System.IO.File]::ReadAllText((Join-Path $scanData ('env-session-start-' + $scanSid + '.json'))) | ConvertFrom-Json
            $script:IaScanClient = [System.IO.File]::ReadAllText(@(Get-ChildItem -LiteralPath $scanData -File -Filter 'env-client-*.json')[0].FullName) | ConvertFrom-Json

            # 2. What this process holds after the scan.
            $script:IaAfter = [ordered]@{}
            foreach ($k in @($script:IaHostile.Keys)) { $script:IaAfter[[string]$k] = [string][System.Environment]::GetEnvironmentVariable('CLAUDE_PLUGIN_OPTION_' + [string]$k) }

            # 3. THE INTERACTIVE HOOKS, launched as plugin.json launches them (no arguments), inheriting this
            # process's environment, with Claude Code's CLAUDE_PLUGIN_DATA.
            $agentData = Join-Path $script:IaRoot 'agent-data'
            New-Item -ItemType Directory -Force -Path $agentData | Out-Null
            $agentSid = 'ia-agent-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            $script:IaStartRun = Invoke-SvChildProcess -HostExe $script:IaHost -CapMs 120000 `
                -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $script:IaScripts 'session-start.ps1')) `
                -StdinText (@{ session_id = $agentSid } | ConvertTo-Json -Compress) -ExtraEnv @{ CLAUDE_PLUGIN_DATA = $agentData }
            $script:IaClientRun = Invoke-SvChildProcess -HostExe $script:IaHost -CapMs 120000 `
                -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $script:IaScripts 'lsp-client.ps1')) `
                -StdinText (@{ session_id = $agentSid; tool_input = @{ file_path = $target }; cwd = $src } | ConvertTo-Json -Compress) `
                -ExtraEnv @{ CLAUDE_PLUGIN_DATA = $agentData }
            $script:IaAgentStart = [System.IO.File]::ReadAllText((Join-Path $agentData ('env-session-start-' + $agentSid + '.json'))) | ConvertFrom-Json
            $script:IaAgentClient = [System.IO.File]::ReadAllText(@(Get-ChildItem -LiteralPath $agentData -File -Filter 'env-client-*.json')[0].FullName) | ConvertFrom-Json
        } finally {
            Restore-SvAmbientEnv -Saved @{}
        }
    }

    AfterAll {
        Restore-SvAmbientEnv -Saved $script:IaSavedEnv
        Remove-SvTempRoot -Path $script:IaRoot
    }

    It 'the scan step declared its children''s configuration from this process (the routine ran)' {
        [string]$script:IaScanStart.resolved.ps_host.value | Should -BeExactly $script:IaHost
        [string]$script:IaScanStart.resolved.ruleInclude.value | Should -BeExactly ''
        [string]$script:IaScanStart.resolved.ruleExclude.value | Should -BeExactly ''
        [string]$script:IaScanStart.resolved.perFileCap.value | Should -BeExactly '0'
        [string]$script:IaScanStart.resolved.severityThreshold.value | Should -BeExactly 'Hint'
        [string]$script:IaScanStart.resolved.ruleset.value | Should -BeExactly 'pses-default'
        [string]$script:IaScanClient.resolved.timeoutMs.value | Should -BeExactly '18000'
        [string]$script:IaScanClient.resolved.scopeToEdit.value | Should -BeExactly 'False'
    }

    It 'this process still holds every hostile value after the scan' {
        (@($script:IaAfter.Keys | ForEach-Object { [string]$_ + '=' + $script:IaAfter[$_] }) -join ';') |
            Should -BeExactly (@($script:IaHostile.Keys | ForEach-Object { [string]$_ + '=' + $script:IaHostile[$_] }) -join ';')
    }

    It 'an interactive SessionStart resolves the hostile environment exactly as it did before this dispatch' {
        $script:IaStartRun.TimedOut | Should -BeFalse
        [string]$script:IaAgentStart.preferredHost | Should -BeExactly 'pwsh' -Because 'plugin.json passes no -PreferredHost'
        (Format-IaResolved -Record $script:IaAgentStart) | Should -BeExactly ('ps_host=powershell(env);severityThreshold=Error(env);' +
            'ruleInclude=PSAvoidUsingCmdletAliases(env);ruleExclude=PSUseApprovedVerbs(env);keepLastN=30(profile);debounceMs=150(default);' +
            'idleTtlMin=30(default);perFileCap=1(env);settingsPath=(default);ruleset=base(profile);orgPolicy=(default);' +
            'moduleAwareness=suggest(profile);referenceSurfacing=counts(profile)')
    }

    It 'an interactive client resolves the hostile environment exactly as it did before this dispatch' {
        $script:IaClientRun.TimedOut | Should -BeFalse
        [string]$script:IaAgentClient.formatMode | Should -BeExactly 'suggest' -Because 'profile strict maps formatOnEdit=suggest for an interactive edit'
        (Format-IaResolved -Record $script:IaAgentClient) | Should -BeExactly ('timeoutMs=1234(env);enableStats=False(default);' +
            'scopeToEdit=True(env);editContextLines=2(profile);formatOnEdit=suggest(profile);orgPolicy=(default);ps_host=powershell(env);' +
            'severityThreshold=Error(env);ruleInclude=PSAvoidUsingCmdletAliases(env);ruleExclude=PSUseApprovedVerbs(env);debounceMs=150(default);' +
            'idleTtlMin=30(default);perFileCap=1(env);settingsPath=(default);ruleset=base(profile);moduleAwareness=suggest(profile);' +
            'referenceSurfacing=counts(profile)')
    }
}
