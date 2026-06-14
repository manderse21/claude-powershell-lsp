#Requires -Version 5.1

# Unit regression tests (Pester 5) for the powershell-lsp plugin. No network, no
# daemon: fast and cross-platform. Run via tests/run-tests.ps1.

BeforeAll {
    $script:PluginRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsDir = Join-Path $script:PluginRoot 'scripts'
    . (Join-Path $script:ScriptsDir 'lib/lsp-common.ps1')
}

# Drive-letter casing is a Windows concept; on *nix 'c:\x' is not a drive path,
# so these specific assertions are Windows-only (the rest of the suite is not).
$script:OnWindows = if (Test-Path 'Variable:\IsWindows') { [bool]$IsWindows } else { $true }

Describe 'ConvertTo-FileUri -- URI drive-letter casing (regression: lowercased drive mismatch)' -Skip:(-not $script:OnWindows) {
    It 'uppercases a lowercase drive letter' {
        ConvertTo-FileUri 'c:\temp\foo.ps1' | Should -Match '^file:///C:/'
    }
    It 'keeps an already-uppercase drive letter uppercase' {
        ConvertTo-FileUri 'C:\temp\foo.ps1' | Should -Match '^file:///C:/'
    }
    It 'uses forward slashes and the file scheme' {
        ConvertTo-FileUri 'C:\a\b\c.ps1' | Should -Be 'file:///C:/a/b/c.ps1'
    }
    It 'percent-encodes spaces in the path' {
        ConvertTo-FileUri 'C:\a b\c.ps1' | Should -Match 'file:///C:/a%20b/c.ps1'
    }
}

Describe 'New-InitializeCapabilities -- rename capability (INVERTED from the dispatch text)' {
    # The dispatch frontmatter and the build brief both said "do not advertise
    # rename capability". That is EMPIRICALLY BACKWARDS for PSES v4.6.0: omitting
    # rename makes PrepareRenameHandler dereference a null RenameCapability and the
    # server never answers initialize (probe-verified 2026-06-05). Declaring a
    # minimal rename capability is what AVOIDS the NRE. These tests guard the
    # CORRECT invariant so a future edit cannot silently re-introduce the hang.
    It 'declares textDocument.rename (this is what avoids the v4.6.0 NRE)' {
        (New-InitializeCapabilities).textDocument.rename | Should -Not -BeNullOrEmpty
    }
    It 'declares prepareSupport on rename' {
        (New-InitializeCapabilities).textDocument.rename.prepareSupport | Should -BeTrue
    }
    It 'still declares synchronization and publishDiagnostics' {
        $caps = New-InitializeCapabilities
        $caps.textDocument.synchronization.didOpen | Should -BeTrue
        $caps.textDocument.publishDiagnostics | Should -Not -BeNullOrEmpty
    }
}

Describe 'Resolve-PsHost -- shared host detection' {
    It 'returns a usable host (pwsh or powershell) on this machine' {
        Resolve-PsHost 'pwsh' | Should -BeIn @('pwsh', 'powershell')
    }
    It 'honors an explicit available preference first' {
        # powershell.exe exists on Windows CI/dev; on *nix this falls through to pwsh.
        Resolve-PsHost (Resolve-PsHost 'pwsh') | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-PluginOption / Get-PluginOptionInt -- userConfig env fallback (v1.1.1 first-run fix)' {
    # v1.1.1: hooks stopped passing ${user_config.*} (CC v2.1.167 refused to launch a
    # hook when any referenced option was unset). Config now comes from the exported
    # CLAUDE_PLUGIN_OPTION_* env vars with a fallback default, so a stranger with zero
    # saved config never gets a hard error. These guard that fallback.
    BeforeEach {
        Get-ChildItem Env: | Where-Object { $_.Name -like 'CLAUDE_PLUGIN_OPTION_*' } |
            ForEach-Object { Remove-Item -LiteralPath ('Env:' + $_.Name) -ErrorAction SilentlyContinue }
    }
    AfterEach {
        Get-ChildItem Env: | Where-Object { $_.Name -like 'CLAUDE_PLUGIN_OPTION_*' } |
            ForEach-Object { Remove-Item -LiteralPath ('Env:' + $_.Name) -ErrorAction SilentlyContinue }
    }
    It 'returns the default when the option is unset' {
        Get-PluginOption 'ps_host' 'pwsh' | Should -Be 'pwsh'
    }
    It 'returns the default when the value is blank' {
        $env:CLAUDE_PLUGIN_OPTION_ps_host = '   '
        Get-PluginOption 'ps_host' 'pwsh' | Should -Be 'pwsh'
    }
    It 'reads a set value' {
        $env:CLAUDE_PLUGIN_OPTION_ps_host = 'powershell'
        Get-PluginOption 'ps_host' 'pwsh' | Should -Be 'powershell'
    }
    It 'matches regardless of exported-name casing (UPPER_SNAKE)' {
        $env:CLAUDE_PLUGIN_OPTION_PS_HOST = 'powershell'
        Get-PluginOption 'ps_host' 'pwsh' | Should -Be 'powershell'
    }
    It 'Get-PluginOptionInt parses a numeric value' {
        $env:CLAUDE_PLUGIN_OPTION_timeoutMs = '8000'
        Get-PluginOptionInt 'timeoutMs' 5000 | Should -Be 8000
    }
    It 'Get-PluginOptionInt falls back on an unexpanded token' {
        $env:CLAUDE_PLUGIN_OPTION_timeoutMs = '${user_config.timeoutMs}'
        Get-PluginOptionInt 'timeoutMs' 5000 | Should -Be 5000
    }
    It 'Get-PluginOptionInt falls back when unset' {
        Get-PluginOptionInt 'perFileCap' 20 | Should -Be 20
    }
}

Describe 'Diagnostics ordering and dedupe (Select-OrderedDiagnostics)' {
    It 'sorts by severity then line and dedupes identical findings' {
        $recs = @(
            [ordered]@{ severity='Warning'; line=10; col=1; source='PSSA'; code='X'; message='b' },
            [ordered]@{ severity='Error';   line=20; col=1; source='PSSA'; code='Y'; message='a' },
            [ordered]@{ severity='Warning'; line=10; col=1; source='PSSA'; code='X'; message='b' }
        )
        $out = @(Select-OrderedDiagnostics $recs)
        $out.Count | Should -Be 2           # one duplicate removed
        $out[0].severity | Should -Be 'Error'  # error sorts before warning
    }
}

Describe 'ConvertTo-DiagRecord -- correction threading (Track C; the prior drop is fixed)' {
    # ConvertTo-DiagRecord used to drop PSScriptAnalyzer SuggestedCorrection text.
    # It now emits 'correction' + 'correctionCount' so the fix can be carried end
    # to end (publishDiagnostics has no fix, so they default empty; the daemon's
    # codeAction pass enriches them afterward). These guard that contract.
    BeforeAll {
        $script:Diag = [pscustomobject]@{
            range = [pscustomobject]@{
                start = [pscustomobject]@{ line = 4; character = 0 }
                end   = [pscustomobject]@{ line = 4; character = 3 }
            }
            severity = 2
            source = 'PSScriptAnalyzer'
            code = 'PSAvoidUsingCmdletAliases'
            message = "'gci' is an alias of 'Get-ChildItem'."
        }
    }
    It 'emits correction and correctionCount fields' {
        $r = ConvertTo-DiagRecord $script:Diag
        $r.Contains('correction') | Should -BeTrue
        $r.Contains('correctionCount') | Should -BeTrue
    }
    It 'defaults to empty fix and zero count at publish time' {
        $r = ConvertTo-DiagRecord $script:Diag
        $r.correction | Should -Be ''
        $r.correctionCount | Should -Be 0
    }
    It 'carries a supplied correction through (the prior drop is fixed)' {
        $r = ConvertTo-DiagRecord $script:Diag 'Get-ChildItem' 1
        $r.correction | Should -Be 'Get-ChildItem'
        $r.correctionCount | Should -Be 1
        $r.line | Should -Be 5            # 0-based 4 -> 1-based 5
        $r.code | Should -Be 'PSAvoidUsingCmdletAliases'
    }
}

Describe 'Configurability -- rule-list parsing and diagnostics filtering (Stage 4 knobs)' {
    BeforeAll {
        $script:Sample = @(
            [ordered]@{ severity = 'Error';       severityNum = 1; line = 5;  col = 1; source = 'PSSA'; code = 'PSAvoidUsingCmdletAliases'; message = 'alias' },
            [ordered]@{ severity = 'Warning';     severityNum = 2; line = 9;  col = 1; source = 'PSSA'; code = 'PSUseApprovedVerbs';        message = 'verb' },
            [ordered]@{ severity = 'Information'; severityNum = 3; line = 12; col = 1; source = 'PSSA'; code = 'PSReviewUnusedParameter';   message = 'unused' }
        )
    }

    It 'Split-RuleList parses, trims, and drops empties' {
        (Split-RuleList 'A, B ,, C') | Should -Be @('A', 'B', 'C')
        @(Split-RuleList '').Count | Should -Be 0
    }

    It 'severityThreshold=Warning drops Information and below' {
        $out = @(Select-FilteredDiagnostics $script:Sample 'Warning' @() @())
        $out.Count | Should -Be 2
        $out.severity | Should -Not -Contain 'Information'
    }

    It 'severityThreshold=Error keeps only Errors' {
        $out = @(Select-FilteredDiagnostics $script:Sample 'Error' @() @())
        $out.Count | Should -Be 1
        $out[0].severity | Should -Be 'Error'
    }

    It 'ruleExclude suppresses a specific rule code' {
        $out = @(Select-FilteredDiagnostics $script:Sample 'Hint' @() @('PSUseApprovedVerbs'))
        $out.code | Should -Not -Contain 'PSUseApprovedVerbs'
        $out.Count | Should -Be 2
    }

    It 'ruleInclude keeps only listed rule codes' {
        $out = @(Select-FilteredDiagnostics $script:Sample 'Hint' @('PSUseApprovedVerbs') @())
        $out.Count | Should -Be 1
        $out[0].code | Should -Be 'PSUseApprovedVerbs'
    }

    It 'default threshold (Hint) keeps everything' {
        @(Select-FilteredDiagnostics $script:Sample 'Hint' @() @()).Count | Should -Be 3
    }
}

# (d) ASCII-clean + parse over every shipped .ps1 (scripts AND tests).
$script:AllPs1 = Get-ChildItem (Split-Path -Parent $PSScriptRoot) -Recurse -Filter *.ps1 -File

Describe 'Shipped PowerShell is ASCII-clean and parses' {
    It '<_.Name> contains no bytes greater than 127' -ForEach $script:AllPs1 {
        $bad = @([System.IO.File]::ReadAllBytes($_.FullName) | Where-Object { $_ -gt 127 })
        $bad.Count | Should -Be 0
    }
    It '<_.Name> parses with zero errors' -ForEach $script:AllPs1 {
        $errs = $null; $tokens = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errs)
        @($errs).Count | Should -Be 0
    }
}
