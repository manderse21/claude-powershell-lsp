#Requires -Version 5.1

# The merged settings file reads the same on Windows PowerShell 5.1 as on PowerShell 7 (Pester 5) -- dispatch
# 000308, B1d: owner ruling RR-02 on review findings B1c-RR-02 (a non-ASCII IncludeRules entry selected nothing
# on a 5.1 host once merged, so a managed scan certified without that rule) and B1c-RX-12 (a non-ASCII
# ExcludeRules entry stopped excluding there), with B1c's found-on-the-way encoding item 1/3 (a CustomRulePath
# directory named with an accent read as a path that does not exist, a false policy-settings-rejected), and
# review finding B1c-RX-09 (the receipt schema's cannotRun description). Correction round 1: owner ruling RV-01
# on review finding B1d-RV-01 (a string holding a typographic single quote re-parsed once merged).
#
# Windows PowerShell 5.1 reads a settings file that has no byte order mark as Windows-1252; PowerShell 7 reads
# it as UTF-8. The merged file is now written with the UTF-8 byte order mark exactly when it holds a character
# outside ASCII (ConvertTo-MergedPssaSettingsBytes), so every all-ASCII merged file keeps its bytes and its
# content-addressed name.
#
# SIX LAYERS:
#   1. The bytes (pure): the mark exactly when a character is outside ASCII.
#   2. The writer: a non-ASCII merged file opens with the mark, is named by the SHA-256 of the bytes written, is
#      read back by THIS host as written, and never reuses a file an earlier daemon wrote without the mark; every
#      merged text B1b and B1c pinned by SHA-256 is written byte for byte under the name it always had.
#   3. The merged files, as written, judged by the vendored PSScriptAnalyzer in a child of this host.
#   4. The receipt schema names every reason the daemon's static check can record (RX-09).
#   5. The real daemon, on THIS host (scanner, daemon and PSES alike), every ambient plugin variable cleared.
#   6. Typographic single quotes (correction round 1): PowerShell also ends a single-quoted string at U+2018,
#      U+2019, U+201A and U+201B, so the merged file doubles each as it doubles U+0027 -- an ExcludeRules entry, an
#      IncludeRules entry, a Rules argument string and a quoted Rules key holding one read back from the merged
#      file (Read-PssaSettingsFile) exactly as the repository wrote them.
#
# Run against f0a8ec0 (the base) -- its scripts/ and its docs/scan-receipt.schema.json -- the bytes' and the
# writer's own tests (layers 1 and 2: the mark, the name, no reuse) and 'B1d-RX09:' fail on both hosts; the
# tests that read or judge a merged file on this host ('B1d-R02:', 'B1d-RX12:', 'B1d-ENC1:' in layers 2 and 3)
# and those of layer 5 fail under Windows PowerShell 5.1 only -- PowerShell 7 reads a merged file the same with
# or without the mark, so they pass there on both trees. The controls ('B1d control:') pass on both trees and
# both hosts. The tests named 'B1d-RV01:' (layer 6) fail there on both hosts too.
#
# Run against eb7b419 (B1d's head before correction round 1) -- its scripts/ -- exactly the 'B1d-RV01:' tests
# fail, on both hosts: each typographic quote ended the string once merged, so the entry, the argument or the key
# read back as other data or as none. Every other test passes there.
#
# ASCII-only (PS 5.1 em-dash trap; each non-ASCII character is built with [char]); StrictMode-safe.

$script:EnOnWindows = if (Test-Path 'Variable:\IsWindows') { [bool]$IsWindows } else { $true }
$script:EnOnLinux = (Test-Path 'Variable:\IsLinux') -and [bool]$IsLinux
$script:EnOnMacOS = (Test-Path 'Variable:\IsMacOS') -and [bool]$IsMacOS
$script:EnUnsupported = -not ($script:EnOnWindows -or $script:EnOnLinux -or $script:EnOnMacOS)

BeforeAll {
    $script:EnRepo = Split-Path -Parent $PSScriptRoot
    $script:EnScripts = Join-Path $script:EnRepo 'scripts'
    . (Join-Path $script:EnRepo 'scripts/lib/lsp-common.ps1')
    . (Join-Path $script:EnRepo 'scripts/lib/lsp-scan-common.ps1')
    . (Join-Path $script:EnRepo 'scripts/lib/lsp-scan-receipt.ps1')
    . (Join-Path $script:EnRepo 'scripts/lib/lsp-policy.ps1')

    $script:EnKelvinTick = 'PSMisleadingBac' + [string][char]0x212A + 'tick'
    $script:EnAccented = 'r' + [string][char]0x00E8 + 'gles'
    $script:EnUtf8 = New-Object System.Text.UTF8Encoding($false)
    $script:EnUtf8Bom = New-Object System.Text.UTF8Encoding($true)

    function New-EnFile {
        # A file under $TestDrive holding $Text (UTF-8, no BOM unless asked), returned as its absolute path.
        param([string]$Text, [string]$Name = 'PSScriptAnalyzerSettings.psd1', [switch]$Bom, [string]$Dir = '')
        $d = $(if ($Dir -ne '') { $Dir } else { Join-Path $TestDrive ('en-' + [guid]::NewGuid().ToString('N').Substring(0, 8)) })
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        $p = Join-Path $d $Name
        [System.IO.File]::WriteAllText($p, $Text, $(if ($Bom) { $script:EnUtf8Bom } else { $script:EnUtf8 }))
        return $p
    }
    function New-EnRuleModule {
        # A custom rule module whose one rule REPORTS once per file (so the analyzer shows it ran), in $Dir.
        param([string]$Dir, [string]$Module, [string]$Function)
        return (New-EnFile -Dir $Dir -Name ($Module + '.psm1') -Text ((@(
                        ('function ' + $Function + ' {')
                        '    [CmdletBinding()]'
                        '    [OutputType([Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord[]])]'
                        '    param([Parameter(Mandatory = $true)][System.Management.Automation.Language.ScriptBlockAst]$ScriptBlockAst)'
                        '    if ($null -ne $ScriptBlockAst.Parent) { return @() }'
                        '    return @([Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]@{ Message = ''ran''; Extent = $ScriptBlockAst.Extent; RuleName = $PSCmdlet.MyInvocation.InvocationName; Severity = ''Warning'' })'
                        '}'
                        ('Export-ModuleMember -Function ' + $Function)) -join "`n") + "`n"))
    }
    function Invoke-EnMerge([string]$Repo, [string[]]$Required) {
        return (Merge-RequiredRulesSettings -ResolvedSettingsPath $Repo -RequiredRules $Required -CurrentPsesTag 'v4.6.0')
    }
    function New-EnDataRoot { return (Join-Path $TestDrive ('en-data-' + [guid]::NewGuid().ToString('N').Substring(0, 8))) }
    function Test-EnBom([byte[]]$Bytes) { return ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) }
    function Get-EnShown([string]$Text) {
        # $Text with every character outside printable ASCII shown as \uXXXX (for a readable failure message).
        return ((@($Text.ToCharArray() | ForEach-Object { if ([int]$_ -lt 0x20 -or [int]$_ -gt 0x7E) { '\u{0:X4}' -f [int]$_ } else { [string]$_ } })) -join '')
    }
    function Get-EnVendoredManifest {
        # The vendored analyzer's manifest in the suite's provisioned data root (ensure-pssa first).
        $data = if (-not [string]::IsNullOrWhiteSpace($env:PSLS_TEST_DATA_DIR)) { $env:PSLS_TEST_DATA_DIR } else { Join-Path ([System.IO.Path]::GetTempPath()) 'psls-sarifscan-test-data' }
        New-Item -ItemType Directory -Force -Path $data | Out-Null
        $prevData = $env:CLAUDE_PLUGIN_DATA
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $env:CLAUDE_PLUGIN_DATA = $data
            & (Resolve-PsHost 'pwsh') -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:EnScripts 'ensure-pssa.ps1') 2>&1 | Out-Null
            return [string](Find-VendoredPssaManifest)
        } finally { $ErrorActionPreference = $prevEap; $env:CLAUDE_PLUGIN_DATA = $prevData }
    }
    function Invoke-EnJudge {
        # Judge every <name>.psd1 in $Dir with the vendored PSScriptAnalyzer in a child of THIS host, called as PSES
        # calls it (-ScriptDefinition, -Settings <path>, -Severity Error,Warning,Information), from an empty working
        # directory: '<name>' -> the rules that reported, sorted ('refused' when it threw). The sample is code.txt.
        param([string]$Manifest, [string]$Dir)
        $driver = Join-Path $TestDrive ('en-judge-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
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
        $out = @{}
        $cwd = Join-Path $TestDrive ('en-cwd-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
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
}

Describe 'The bytes of a merged settings file (dispatch 000308 B1d, owner ruling RR-02)' {

    It 'B1d-R02: a text holding a character outside ASCII is written as UTF-8 opened with the byte order mark -- the Kelvin sign, an accented letter, U+0080, a character beyond the BMP' {
        foreach ($ch in @([string][char]0x212A, [string][char]0x00E8, [string][char]0x0080, ([string][char]0xD83D + [string][char]0xDE00))) {
            $text = "@{ IncludeRules = @('A" + $ch + "') }`n"
            $b = ConvertTo-MergedPssaSettingsBytes -Text $text
            $b.GetType().FullName | Should -BeExactly 'System.Byte[]'
            Test-EnBom $b | Should -BeTrue -Because ('U+' + ('{0:X4}' -f [int]$ch[0]) + ' is outside ASCII')
            $body = $script:EnUtf8.GetBytes($text)
            $b.Length | Should -Be ($body.Length + 3)
            (Get-Sha256HexFromBytes -Bytes $b) | Should -BeExactly (Get-Sha256HexFromBytes -Bytes ([byte[]](@(0xEF, 0xBB, 0xBF) + $body)))
        }
    }

    It 'B1d-R02: an all-ASCII text -- DEL and TAB included, and the empty text -- is written as UTF-8 without the mark, byte for byte the text' {
        foreach ($text in @("@{ IncludeRules = @('PSAvoidGlobalVars') }`n", ("@{ IncludeRules = @('A" + [string][char]0x7F + "') }`n"), ("@{`tIncludeRules = @('A') }`n"), '')) {
            $b = ConvertTo-MergedPssaSettingsBytes -Text $text
            $b.GetType().FullName | Should -BeExactly 'System.Byte[]'
            Test-EnBom $b | Should -BeFalse
            (Get-Sha256HexFromBytes -Bytes $b) | Should -BeExactly (Get-Sha256HexFromBytes -Bytes ($script:EnUtf8.GetBytes($text)))
        }
    }

    It 'B1d-R02: the Kelvin sign alone gets the mark, though a case-insensitive match for a character outside ASCII misses it' {
        ([string][char]0x212A -match '[^\x00-\x7F]') | Should -BeFalse -Because 'CONTROL: the trap a comparison by character code avoids (IgnoreCase folds U+212A to k; measured, both hosts)'
        Test-EnBom (ConvertTo-MergedPssaSettingsBytes -Text ("@{ IncludeRules = @('" + [string][char]0x212A + "') }`n")) | Should -BeTrue
    }

    It 'B1d control: an all-ASCII merged file -- DEL and TAB included -- is written as its text in UTF-8, without the mark' {
        $s = @{ IncludeRules = @(('A' + [string][char]0x7F), ("B`tC")) }
        $p = Write-MergedPssaSettingsFile -Settings $s -DataRoot (New-EnDataRoot)
        $p | Should -Not -BeNullOrEmpty
        $bytes = [System.IO.File]::ReadAllBytes($p)
        Test-EnBom $bytes | Should -BeFalse
        (Get-Sha256HexFromBytes -Bytes $bytes) | Should -BeExactly (Get-Sha256HexFromBytes -Bytes ($script:EnUtf8.GetBytes((ConvertTo-MergedPssaSettingsText -Settings $s))))
    }
}

Describe 'The merged settings file as written (dispatch 000308 B1d)' {

    BeforeAll {
        $script:WrKelvin = Invoke-EnMerge (New-EnFile ("@{ IncludeRules = @('PSAvoidUsingCmdletAliases', '" + $script:EnKelvinTick + "') }") -Bom) @('PSAvoidGlobalVars')
        $script:WrExclude = Invoke-EnMerge (New-EnFile ("@{ IncludeRules = @('PSAvoidUsingCmdletAliases', 'PSMisleadingBacktick'); ExcludeRules = @('" + $script:EnKelvinTick + "') }") -Bom) @('PSAvoidGlobalVars')
        $script:WrModuleDir = Join-Path $TestDrive ('en-cp-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '\' + $script:EnAccented)
        $script:WrModule = New-EnRuleModule -Dir $script:WrModuleDir -Module 'B1dEn.Rules' -Function 'Measure-B1dEnReports'
        $script:WrCustom = Invoke-EnMerge (New-EnFile ("@{ CustomRulePath = @('" + $script:WrModule + "'); IncludeDefaultRules = `$true }") -Bom) @('PSAvoidGlobalVars')
    }

    It 'B1d-R02: a merged file holding the Kelvin sign opens with the byte order mark, and is named by the SHA-256 of the bytes written' {
        $p = Write-MergedPssaSettingsFile -Settings $script:WrKelvin -DataRoot (New-EnDataRoot)
        $p | Should -Not -BeNullOrEmpty
        $bytes = [System.IO.File]::ReadAllBytes($p)
        Test-EnBom $bytes | Should -BeTrue -Because 'without the mark Windows PowerShell 5.1 reads the file as Windows-1252'
        $sha = Get-Sha256HexFromBytes -Bytes $bytes
        [System.IO.Path]::GetFileName($p) | Should -BeExactly ('merged-settings-' + $sha.Substring(0, 16) + '.psd1')
        $script:EnUtf8.GetString($bytes, 3, $bytes.Length - 3) | Should -BeExactly (ConvertTo-MergedPssaSettingsText -Settings $script:WrKelvin)
        (Get-PolicyFileSha256 -Path $p) | Should -BeExactly $sha -Because 'the evidence hash is the hash of the bytes on disk, and the name agrees with it'
    }

    It 'B1d-R02: this host reads a merged Kelvin-sign IncludeRules entry exactly as written (it read three other characters on Windows PowerShell 5.1)' {
        $p = Write-MergedPssaSettingsFile -Settings $script:WrKelvin -DataRoot (New-EnDataRoot)
        $r = Read-PssaSettingsFile -Path $p
        $r.Verdict | Should -BeExactly 'valid'
        $got = @($r.Entries['IncludeRules']) -join '|'
        $got -ceq ('PSAvoidUsingCmdletAliases|' + $script:EnKelvinTick + '|PSAvoidGlobalVars') | Should -BeTrue -Because ('read: ' + (Get-EnShown $got))
    }

    It 'B1d-RX12: this host reads a merged Kelvin-sign ExcludeRules entry exactly as written' {
        $p = Write-MergedPssaSettingsFile -Settings $script:WrExclude -DataRoot (New-EnDataRoot)
        $r = Read-PssaSettingsFile -Path $p
        $r.Verdict | Should -BeExactly 'valid'
        $got = @($r.Entries['ExcludeRules']) -join '|'
        $got -ceq $script:EnKelvinTick | Should -BeTrue -Because ('read: ' + (Get-EnShown $got))
    }

    It 'B1d-ENC1: this host reads a merged CustomRulePath whose directory is named with an accent as the path that exists, and the file is valid (it read as a missing path on Windows PowerShell 5.1)' {
        $p = Write-MergedPssaSettingsFile -Settings $script:WrCustom -DataRoot (New-EnDataRoot)
        $r = Read-PssaSettingsFile -Path $p
        $r.Verdict | Should -BeExactly 'valid' -Because ([string]$r.Problem)
        (@($r.Entries['CustomRulePath']) -join '|') -ceq $script:WrModule | Should -BeTrue -Because ('read: ' + (Get-EnShown (@($r.Entries['CustomRulePath']) -join '|')))
    }

    It 'B1d-R02: a non-ASCII merged file an earlier daemon wrote without the mark is not reused, and is left in place (another name)' {
        $data = New-EnDataRoot
        $text = ConvertTo-MergedPssaSettingsText -Settings $script:WrKelvin
        $oldBytes = $script:EnUtf8.GetBytes($text)
        $oldName = 'merged-settings-' + (Get-Sha256HexFromBytes -Bytes $oldBytes).Substring(0, 16) + '.psd1'
        $old = Join-Path (Get-MergedPssaSettingsDir -DataRoot $data) $oldName
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $old) | Out-Null
        [System.IO.File]::WriteAllBytes($old, $oldBytes)
        $p = Write-MergedPssaSettingsFile -Settings $script:WrKelvin -DataRoot $data
        $p | Should -Not -BeNullOrEmpty
        $p | Should -Not -BeExactly $old -Because 'a file without the mark is read as Windows-1252 on a 5.1 host; it must not be the one handed to PSES'
        Test-EnBom ([System.IO.File]::ReadAllBytes($p)) | Should -BeTrue
        (Get-Sha256HexFromBytes -Bytes ([System.IO.File]::ReadAllBytes($old))) | Should -BeExactly (Get-Sha256HexFromBytes -Bytes $oldBytes) -Because 'an earlier daemon may still be using its file'
    }

    It 'B1d control: every merged file is named by the SHA-256 of its bytes on disk, and an all-ASCII one has no mark' {
        $data = New-EnDataRoot
        $a = Write-MergedPssaSettingsFile -Settings @{ IncludeRules = @('PSAvoidGlobalVars') } -DataRoot $data
        $k = Write-MergedPssaSettingsFile -Settings $script:WrKelvin -DataRoot $data
        foreach ($p in @($a, $k)) {
            [System.IO.Path]::GetFileName($p) | Should -BeExactly ('merged-settings-' + (Get-PolicyFileSha256 -Path $p).Substring(0, 16) + '.psd1')
        }
        Test-EnBom ([System.IO.File]::ReadAllBytes($a)) | Should -BeFalse
    }

    It 'B1d control: every merged text B1b and B1c pinned by SHA-256 is written byte for byte, without the mark, under the name it always had -- <Name>' -ForEach @(
        # B1c's controls (tests/PowerShellLsp.PolicyRoutes.Tests.ps1) and B1b's R03 controls
        # (tests/PowerShellLsp.PolicySettings.Tests.ps1): the same texts and the same SHA-256 they pin.
        @{ Name = 'an exact required name in ExcludeRules'; Text = "@{ ExcludeRules = @('PSAvoidGlobalVars', 'PSAvoidUsingWriteHost') }"; Required = @('PSAvoidGlobalVars'); Sha = '0cfc858e3bad2114c4afb4441945c87729a105497868cb66f6e18b11f65808a9' }
        @{ Name = 'the same in lower case'; Text = "@{ ExcludeRules = @('psavoidglobalvars', 'PSAvoidUsingCmdletAliases') }"; Required = @('PSAvoidGlobalVars'); Sha = 'd963b7292ad9a4dbfb848552345a90e173e69988d659d2931a240b0f0d21be78' }
        @{ Name = 'a pattern that names no required rule, beside own IncludeRules'; Text = "@{ IncludeRules = @('PSAvoidUsingCmdletAliases'); ExcludeRules = @('PSUse*', 'PSAvoidUsingWriteHost') }"; Required = @('PSAvoidGlobalVars'); Sha = '8da528a8684df5e1a633512f579467865c516bac055b7b3078373075d941b106' }
        @{ Name = 'a list of one blank IncludeRules entry'; Text = "@{ IncludeRules = @('') }"; Required = @('PSAvoidGlobalVars'); Sha = 'bbb41a7182771d736c01e571291b223a6da92a890fe3b222719642067d320628' }
        @{ Name = 'a REJECTED file whose IncludeRules has no entry'; Text = "@{ IncludeRules = @(); ExcludeRules = @('PSAvoidUsingWriteHost'); RuleArguments = @{ X = @{ Enable = `$true } } }"; Required = @('PSAvoidGlobalVars'); Sha = '71a10fb1c77bb90910ad0c89ccc0be0932c501befd2594f0d1edaf4a8aae4dd3' }
        @{ Name = 'two required rules beside own IncludeRules'; Text = "@{ IncludeRules = @('PSAvoidUsingCmdletAliases'); ExcludeRules = @('PSAvoidLongLines') }"; Required = @('PSAvoidGlobalVars', 'PSAvoidLongLines'); Sha = '92ab5485203ab125820618cbec67e53f88adfcfcf80490bfd3a4e76a8fd096c1' }
        @{ Name = 'no settings file'; Text = ''; Required = @('PSAvoidGlobalVars'); Sha = '866b8a5d243638d540387f324439311e02a3852c4732b9ffe39ebf9406985280' }
        @{ Name = 'PSAvoidLongLines, no settings file'; Text = ''; Required = @('PSAvoidLongLines'); Sha = 'dc1e694887b1aedab1b1fbd9667aef79737c2c30552666cbe91139a673590c6e' }
        @{ Name = 'PSUseSingularNouns over Enable = $false'; Text = "@{ Rules = @{ PSUseSingularNouns = @{ Enable = `$false } } }"; Required = @('PSUseSingularNouns'); Sha = 'c57939f1d54d85494afe6a4b838beeb935c184813810341a9bedbe089367a90b' }
        @{ Name = 'a custom rule keyed Module\Name: switched on'; Text = "@{ Rules = @{ 'My.Rules\Measure-Thing' = @{ Enable = `$false; Limit = 3 } } }"; Required = @('My.Rules\Measure-Thing'); Sha = 'd63dce93fab4b67bb1d3f0af6c0bc6fb18806926f2621db8ddaa8446a48704d4' }
        @{ Name = 'a custom rule keyed by its bare name: left as written'; Text = "@{ Rules = @{ 'Measure-Thing' = @{ Enable = `$false; Limit = 3 } } }"; Required = @('My.Rules\Measure-Thing'); Sha = '78a2ff2278c413877a11b67b75735816aaf87fe81be821059f270d38c488e30a' }
        @{ Name = 'B1b R03: no settings file, two required rules'; Text = ''; Required = @('PSAvoidLongLines', 'PSAvoidGlobalVars'); Sha = 'dfb4aab81a5b0bfe8521e4322a8733e111483760c2ddf9db1ea7adfa8d30c34a' }
        @{ Name = 'B1b R03: a file naming its own IncludeRules'; Text = "@{ IncludeRules = @('PSAvoidUsingCmdletAliases', 'PSAvoidLongLines'); ExcludeRules = @('PSAvoidGlobalVars', 'PSAvoidUsingWriteHost'); Severity = @('Warning', 'Error'); Rules = @{ PSAvoidLongLines = @{ Enable = `$true; MaximumLineLength = 40 } } }"; Required = @('PSAvoidGlobalVars'); Sha = '37c720b7dadebf1725fb031f36135c4b51472fd8fc0c0e75f926897a07f64801' }
        @{ Name = 'B1b R03: a REJECTED file naming no IncludeRules'; Text = "@{ ExcludeRules = @('PSAvoidUsingCmdletAliases'); RuleArguments = @{ X = @{ Enable = `$true } } }"; Required = @('PSAvoidGlobalVars'); Sha = '917d4ede944228efeb4df5d01525c2e18f48727f531409122978f64b212284b0' }
    ) {
        $repo = ''
        if ($Text -ne '') { $repo = New-EnFile $Text }
        $p = Write-MergedPssaSettingsFile -Settings (Invoke-EnMerge $repo $Required) -DataRoot (New-EnDataRoot)
        $p | Should -Not -BeNullOrEmpty
        $bytes = [System.IO.File]::ReadAllBytes($p)
        Test-EnBom $bytes | Should -BeFalse
        (Get-Sha256HexFromBytes -Bytes $bytes) | Should -BeExactly $Sha
        [System.IO.Path]::GetFileName($p) | Should -BeExactly ('merged-settings-' + $Sha.Substring(0, 16) + '.psd1')
    }
}

Describe 'The merged files as written, judged by the vendored PSScriptAnalyzer on this host (dispatch 000308 B1d)' -Skip:$script:EnUnsupported {

    BeforeAll {
        $script:JdManifest = Get-EnVendoredManifest
        $script:JdDir = Join-Path $TestDrive 'en-judged'
        New-Item -ItemType Directory -Force -Path $script:JdDir | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $script:JdDir 'code.txt'), "gci`n`$global:En = 1`nWrite-Output 'a' `` `n'b'`n", $script:EnUtf8)
        $moduleDir = Join-Path $TestDrive ('en-jcp-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '\' + $script:EnAccented)
        $script:JdModule = New-EnRuleModule -Dir $moduleDir -Module 'B1dJd.Rules' -Function 'Measure-B1dJdReports'
        $script:JdCases = [ordered]@{
            'include-kelvin' = "@{ IncludeRules = @('PSAvoidUsingCmdletAliases', '" + $script:EnKelvinTick + "') }"
            'exclude-kelvin' = "@{ IncludeRules = @('PSAvoidUsingCmdletAliases', 'PSMisleadingBacktick'); ExcludeRules = @('" + $script:EnKelvinTick + "') }"
            'custom-accented' = "@{ CustomRulePath = @('" + $script:JdModule + "'); IncludeDefaultRules = `$true; IncludeRules = @('PSAvoidUsingCmdletAliases', 'Measure-B1dJdReports') }"
            'ascii' = "@{ IncludeRules = @('PSAvoidUsingCmdletAliases', 'PSMisleadingBacktick') }"
        }
        $script:JdBom = @{}
        foreach ($k in @($script:JdCases.Keys)) {
            # The repository's own file is saved WITH a mark, so this host reads it as written alone; the merged
            # file is the writer's own bytes, copied as they are.
            $repo = New-EnFile $script:JdCases[$k] -Bom
            [System.IO.File]::WriteAllBytes((Join-Path $script:JdDir ($k + '.alone.psd1')), [System.IO.File]::ReadAllBytes($repo))
            $p = Write-MergedPssaSettingsFile -Settings (Invoke-EnMerge $repo @('PSAvoidGlobalVars')) -DataRoot (New-EnDataRoot)
            $bytes = [System.IO.File]::ReadAllBytes($p)
            $script:JdBom[$k] = Test-EnBom $bytes
            [System.IO.File]::WriteAllBytes((Join-Path $script:JdDir ($k + '.psd1')), $bytes)
        }
        $script:Jd = @{}
        if (-not [string]::IsNullOrWhiteSpace($script:JdManifest)) { $script:Jd = Invoke-EnJudge -Manifest $script:JdManifest -Dir $script:JdDir }
    }

    It 'the vendored analyzer judged every file (this Describe cannot pass vacuously)' {
        $script:JdManifest | Should -Not -BeNullOrEmpty
        $script:Jd.Count | Should -Be (2 * $script:JdCases.Count)
    }

    It 'B1d-R02: judged -- a Kelvin-sign IncludeRules entry merged runs PSMisleadingBacktick, as the repository''s file runs it alone (merged, it ran nothing for that entry on Windows PowerShell 5.1)' {
        (@($script:Jd['include-kelvin.alone']) -join ',') | Should -BeExactly 'PSAvoidUsingCmdletAliases,PSMisleadingBacktick' -Because 'CONTROL: the repository''s file, read on this host with its mark'
        (@($script:Jd['include-kelvin']) -join ',') | Should -BeExactly 'PSAvoidGlobalVars,PSAvoidUsingCmdletAliases,PSMisleadingBacktick'
    }

    It 'B1d-RX12: judged -- a Kelvin-sign ExcludeRules entry merged still excludes PSMisleadingBacktick (merged, it stopped excluding on Windows PowerShell 5.1)' {
        (@($script:Jd['exclude-kelvin.alone']) -join ',') | Should -BeExactly 'PSAvoidUsingCmdletAliases' -Because 'CONTROL: the analyzer folds the Kelvin sign to k, and an exclusion wins'
        (@($script:Jd['exclude-kelvin']) -join ',') | Should -BeExactly 'PSAvoidGlobalVars,PSAvoidUsingCmdletAliases'
    }

    It 'B1d-ENC1: judged -- a merged CustomRulePath under a directory named with an accent loads its rule (merged, the analyzer refused the file on Windows PowerShell 5.1)' {
        (@($script:Jd['custom-accented.alone']) -join ',') | Should -BeExactly 'B1dJd.Rules\Measure-B1dJdReports,PSAvoidUsingCmdletAliases' -Because 'CONTROL: the repository''s file alone'
        (@($script:Jd['custom-accented']) -join ',') | Should -BeExactly 'B1dJd.Rules\Measure-B1dJdReports,PSAvoidGlobalVars,PSAvoidUsingCmdletAliases'
    }

    It 'B1d control: judged -- an all-ASCII merged file, written without the mark, runs exactly what it ran' {
        $script:JdBom['ascii'] | Should -BeFalse
        (@($script:Jd['ascii']) -join ',') | Should -BeExactly 'PSAvoidGlobalVars,PSAvoidUsingCmdletAliases,PSMisleadingBacktick'
    }
}

Describe 'The receipt schema names every reason the static check can record (dispatch 000308 B1d, review finding B1c-RX-09)' {

    It 'B1d-RX09: policy.daemon.requiredRules.cannotRun''s description names each reason Get-RequiredRulesNotRunnable writes' {
        # Every reason is a string literal assigned to $why in the function (one is followed by the entry).
        $fn = (Get-Command Get-RequiredRulesNotRunnable).ScriptBlock.Ast
        $why = @($fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath -eq 'why' }, $true) |
                ForEach-Object { @($_.Right.FindAll({ param($m) $m -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true))[0] } |
                Where-Object { $null -ne $_ -and [string]$_.Value -ne '' } | ForEach-Object { ([string]$_.Value).TrimEnd(' ', [char]39) } | Sort-Object -Unique)
        $why.Count | Should -Be 5 -Because ('the reasons found: ' + ($why -join ' | '))
        # The schema node, found wherever it sits (properties.policy.properties.daemon.oneOf[..]...), exactly once.
        $schema = [System.IO.File]::ReadAllText((Join-Path $script:EnRepo 'docs/scan-receipt.schema.json')) | ConvertFrom-Json
        $nodes = New-Object System.Collections.ArrayList
        $stack = New-Object System.Collections.Stack
        $stack.Push($schema)
        while ($stack.Count -gt 0) {
            $n = $stack.Pop()
            if ($n -is [System.Management.Automation.PSCustomObject]) {
                foreach ($p in $n.PSObject.Properties) {
                    if ($p.Name -ceq 'cannotRun') { [void]$nodes.Add($p.Value) }
                    $stack.Push($p.Value)
                }
            } elseif ($n -is [System.Array]) { foreach ($x in $n) { $stack.Push($x) } }
        }
        $nodes.Count | Should -Be 1
        $desc = [string]$nodes[0].description
        $desc | Should -Not -BeNullOrEmpty
        foreach ($w in $why) { $desc.Contains($w) | Should -BeTrue -Because ("the description must name '" + $w + "'") }
    }
}

Describe 'Through the real daemon on this host, every ambient plugin variable cleared (dispatch 000308 B1d)' -Skip:$script:EnUnsupported {

    BeforeAll {
        . (Join-Path $PSScriptRoot 'Integration.Common.ps1')
        . (Join-Path $PSScriptRoot 'ScanHarness.Common.ps1')
        $script:RdScan = Join-Path $script:EnScripts 'lsp-scan.ps1'
        # The scanner, the daemon and PSES all run on THIS host: on the windows-powershell leg that is Windows
        # PowerShell 5.1, the host the merged file was misread on.
        $script:RdHost = (Get-Process -Id $PID).Path
        $script:RdPsHost = $(if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell' } else { 'pwsh' })
        $script:RdData = if (-not [string]::IsNullOrWhiteSpace($env:PSLS_TEST_DATA_DIR)) { $env:PSLS_TEST_DATA_DIR } else { Join-Path ([System.IO.Path]::GetTempPath()) 'psls-sarifscan-test-data' }
        New-Item -ItemType Directory -Force -Path $script:RdData | Out-Null
        $prevData = $env:CLAUDE_PLUGIN_DATA
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $env:CLAUDE_PLUGIN_DATA = $script:RdData
            & (Resolve-PsHost 'pwsh') -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:EnScripts 'ensure-pses.ps1') 2>&1 | Out-Null
            & (Resolve-PsHost 'pwsh') -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:EnScripts 'ensure-pssa.ps1') 2>&1 | Out-Null
        } finally { $ErrorActionPreference = $prevEap; $env:CLAUDE_PLUGIN_DATA = $prevData }

        $script:RdWork = Join-Path $script:RdData ('b1d-encoding-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        function New-RdDir([string]$Name, [string]$Settings) {
            # The repository's settings file is saved WITH a mark, so each host reads it as written on its own.
            $d = Join-Path $script:RdWork $Name
            New-Item -ItemType Directory -Force -Path $d | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $d 'thing.ps1'), "gci`n`$global:RdEn = 1`nWrite-Output 'a' `` `n'b'`n", $script:EnUtf8)
            if ($Settings -ne '') { [System.IO.File]::WriteAllText((Join-Path $d 'PSScriptAnalyzerSettings.psd1'), ($Settings + "`n"), $script:EnUtf8Bom) }
            return $d
        }
        # A rule name unique to this run in IncludeRules or ExcludeRules (it matches no rule) keeps each merged text
        # -- and so each content-addressed merged file -- this run's alone.
        $unique = 'PSB1dUnique' + [guid]::NewGuid().ToString('N')
        $rdModule = New-EnRuleModule -Dir (Join-Path $script:RdWork $script:EnAccented) -Module 'B1dRd.Rules' -Function 'Measure-B1dRdReports'
        $script:RdInclude = New-RdDir 'include-kelvin' ("@{ IncludeRules = @('PSAvoidUsingCmdletAliases', '" + $script:EnKelvinTick + "', '" + $unique + "') }")
        $script:RdExclude = New-RdDir 'exclude-kelvin' ("@{ IncludeRules = @('PSAvoidUsingCmdletAliases', 'PSMisleadingBacktick'); ExcludeRules = @('" + $script:EnKelvinTick + "', '" + $unique + "') }")
        $script:RdCustom = New-RdDir 'custom-accented' ("@{ CustomRulePath = @('" + $rdModule + "'); IncludeDefaultRules = `$true; IncludeRules = @('PSAvoidUsingCmdletAliases', 'Measure-B1dRdReports', '" + $unique + "') }")
        $script:RdGlobal = Join-Path $script:RdWork 'required.psd1'
        [System.IO.File]::WriteAllText($script:RdGlobal, "@{ RequiredRules = @('PSAvoidGlobalVars') }`n")

        function Invoke-RdScan {
            param([string]$Target, [string]$Policy = '', [string]$Mode = '')
            $out = Join-Path $script:RdWork ('out-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.sarif')
            $a = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:RdScan, $Target, '-Format', 'sarif', '-OutputPath', $out, '-PsHost', $script:RdPsHost)
            if ($Policy -ne '') { $a += @('-OrgPolicyPath', $Policy) }
            if ($Mode -ne '') { $a += @('-PolicyMode', $Mode) }
            $run = Invoke-SvChildProcess -HostExe $script:RdHost -CapMs 300000 -ArgumentList $a -ExtraEnv @{ CLAUDE_PLUGIN_DATA = $script:RdData } `
                -RemoveEnvPrefix @('CLAUDE_PLUGIN_OPTION_', 'POWERSHELL_LSP_')
            $text = Read-SvTextFile -Path $out
            $sarif = $null; $results = @(); $pol = $null
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $sarif = $text | ConvertFrom-Json
                $results = @(@(@($sarif.runs[0].results) | Where-Object { $null -ne $_ }) | ForEach-Object { [string]$_.ruleId } | Sort-Object -Unique)
                $inv = $sarif.runs[0].invocations[0]
                if ($null -ne $inv.PSObject.Properties['properties']) { $pol = $inv.properties.policy }
            }
            return @{ Exit = [int]$run.ExitCode; Err = [string]$run.Err; Sarif = $sarif; Results = $results; Policy = $pol; TimedOut = [bool]$run.TimedOut }
        }

        $script:Rd = @{}
        $script:Rd.Include = Invoke-RdScan -Target $script:RdInclude -Policy $script:RdGlobal -Mode 'closed'
        $script:Rd.IncludeAlone = Invoke-RdScan -Target $script:RdInclude
        $script:Rd.Exclude = Invoke-RdScan -Target $script:RdExclude -Policy $script:RdGlobal -Mode 'closed'
        $script:Rd.Custom = Invoke-RdScan -Target $script:RdCustom -Policy $script:RdGlobal -Mode 'closed'
    }

    AfterAll {
        if ($script:RdWork -and (Test-Path -LiteralPath $script:RdWork)) { Remove-Item -LiteralPath $script:RdWork -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'every scan ran to its report on this host (this Describe cannot pass vacuously)' {
        foreach ($k in @($script:Rd.Keys)) {
            $script:Rd[$k].TimedOut | Should -BeFalse -Because ($k + ' must finish')
            $script:Rd[$k].Sarif | Should -Not -BeNullOrEmpty -Because ($k + ' must write its SARIF; stderr: ' + $script:Rd[$k].Err)
        }
    }

    It 'B1d-R02: a Kelvin-sign IncludeRules entry -- the managed scan certifies WITH PSMisleadingBacktick, as the repository''s file runs it alone (on Windows PowerShell 5.1 it certified without it)' {
        @($script:Rd.IncludeAlone.Results) | Should -Contain 'PSMisleadingBacktick' -Because ('CONTROL: no policy, no merge; stderr: ' + $script:Rd.IncludeAlone.Err)
        $m = $script:Rd.Include
        $m.Exit | Should -Be 0 -Because ('stderr: ' + $m.Err)
        $m.Policy.certification | Should -BeExactly 'certified'
        ($m.Results -join ',') | Should -BeExactly 'PSAvoidGlobalVars,PSAvoidUsingCmdletAliases,PSMisleadingBacktick'
    }

    It 'B1d-RX12: a Kelvin-sign ExcludeRules entry -- the managed scan certifies with PSMisleadingBacktick still excluded (on Windows PowerShell 5.1 it ran)' {
        $m = $script:Rd.Exclude
        $m.Exit | Should -Be 0 -Because ('stderr: ' + $m.Err)
        $m.Policy.certification | Should -BeExactly 'certified'
        ($m.Results -join ',') | Should -BeExactly 'PSAvoidGlobalVars,PSAvoidUsingCmdletAliases'
    }

    It 'B1d-ENC1: a CustomRulePath under a directory named with an accent -- the managed scan certifies with the custom rule (on Windows PowerShell 5.1 it was refused, policy-settings-rejected)' {
        $m = $script:Rd.Custom
        $m.Exit | Should -Be 0 -Because ('stderr: ' + $m.Err)
        $m.Policy.certification | Should -BeExactly 'certified'
        $m.Err | Should -Not -Match 'would reject a settings file'
        ($m.Results -join ',') | Should -BeExactly 'B1dRd.Rules\Measure-B1dRdReports,PSAvoidGlobalVars,PSAvoidUsingCmdletAliases'
    }
}

Describe 'Typographic single quotes reach the merged settings file as the repository wrote them (dispatch 000308 B1d correction round 1, owner ruling RV-01)' {

    BeforeAll {
        function Get-QtValue {
            # The strings the Read-PssaSettingsFile result $Read holds where a case puts its string: a rule list's
            # entries, the Placement argument Rules gives PSProvideCommentHelp (a value that did not read as a string
            # is shown by its type first, so it never equals one), or the Rules keys.
            param($Read, [string]$Where)
            $e = $Read.Entries
            switch ($Where) {
                'an ExcludeRules entry' { if ($e.Contains('ExcludeRules')) { return , @(@($e['ExcludeRules']) | ForEach-Object { [string]$_ }) } }
                'an IncludeRules entry' { if ($e.Contains('IncludeRules')) { return , @(@($e['IncludeRules']) | ForEach-Object { [string]$_ }) } }
                'a Rules argument string' {
                    if ($e.Contains('Rules') -and $e['Rules'].Contains('PSProvideCommentHelp')) {
                        $v = $e['Rules']['PSProvideCommentHelp']['Placement']
                        if ($v -is [string]) { return , @($v) }
                        return , @(@('(not a string)') + @(@($v) | ForEach-Object { [string]$_ }))
                    }
                }
                'a quoted Rules key' { if ($e.Contains('Rules')) { return , @(@($e['Rules'].Keys) | ForEach-Object { [string]$_ }) } }
            }
            return , @('(absent)')
        }
    }

    It '<Class>: <Quote> in <Where> reads back from the merged file exactly as the repository wrote it' -ForEach @(
        foreach ($qc in @(
                @{ Class = 'B1d-RV01'; Quote = 'U+2018'; Code = 0x2018 }
                @{ Class = 'B1d-RV01'; Quote = 'U+2019'; Code = 0x2019 }
                @{ Class = 'B1d-RV01'; Quote = 'U+201A'; Code = 0x201A }
                @{ Class = 'B1d-RV01'; Quote = 'U+201B'; Code = 0x201B }
                @{ Class = 'B1d control'; Quote = 'U+0027'; Code = 0x27 }
                @{ Class = 'B1d control'; Quote = 'no quote'; Code = 0 })) {
            foreach ($where in @('an ExcludeRules entry', 'an IncludeRules entry', 'a Rules argument string', 'a quoted Rules key')) {
                @{ Class = $qc.Class; Quote = $qc.Quote; Code = $qc.Code; Where = $where }
            }
        }
    ) {
        # The quote twice around a comma, the review's reproducer: ONE string that would re-parse as two were each
        # quote read as the end of the string. The repository's file writes it in double quotes, where none of these
        # characters is special, and is saved with a byte order mark, so this host reads it as written.
        $q = $(if ($Code -eq 0) { '' } else { [string][char]$Code })
        $dq = [string][char]34
        switch ($Where) {
            'an ExcludeRules entry' { $s = 'PSAvoidUsingWriteHost' + $q + ',' + $q + 'PSAvoidUsingCmdletAliases'; $text = '@{ ExcludeRules = @(' + $dq + $s + $dq + ') }'; $want = @($s) }
            'an IncludeRules entry' { $s = 'PSAvoidUsingCmdletAliases' + $q + ',' + $q + 'PSAvoidUsingWriteHost'; $text = '@{ IncludeRules = @(' + $dq + $s + $dq + ') }'; $want = @($s, 'PSAvoidGlobalVars') }
            'a Rules argument string' { $s = 'before' + $q + ',' + $q + 'end'; $text = '@{ Rules = @{ PSProvideCommentHelp = @{ Enable = $true; Placement = ' + $dq + $s + $dq + ' } } }'; $want = @($s) }
            'a quoted Rules key' { $s = 'B1dQt.Rules\Measure' + $q + ',' + $q + 'Thing'; $text = '@{ Rules = @{ ' + $dq + $s + $dq + ' = @{ Enable = $true } } }'; $want = @($s) }
        }
        $repo = New-EnFile $text -Bom
        $alone = Read-PssaSettingsFile -Path $repo
        $alone.Verdict | Should -BeExactly 'valid' -Because ('CONTROL: the repository file alone; ' + [string]$alone.Problem)
        $a = Get-QtValue $alone $Where
        ($a -join ' | ') -ceq $s | Should -BeTrue -Because ('CONTROL: the repository file alone reads ' + (Get-EnShown ($a -join ' | ')))
        $p = Write-MergedPssaSettingsFile -Settings (Invoke-EnMerge $repo @('PSAvoidGlobalVars')) -DataRoot (New-EnDataRoot)
        $p | Should -Not -BeNullOrEmpty
        $r = Read-PssaSettingsFile -Path $p
        $r.Verdict | Should -BeExactly 'valid' -Because ([string]$r.Problem)
        $got = Get-QtValue $r $Where
        $shown = Get-EnShown ($got -join ' | ')
        $got.Count | Should -Be $want.Count -Because ('read back: ' + $shown)
        for ($i = 0; $i -lt $want.Count; $i++) { $got[$i] -ceq $want[$i] | Should -BeTrue -Because ('read back: ' + $shown) }
    }
}
