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

Describe 'ConvertTo-UriKey -- case-insensitive URI matching (regression: PSES lowercases the Windows drive)' {
    # Guard 2b -- the MATCH side of landmine 1 (the construction side is the
    # ConvertTo-FileUri block above). ConvertTo-FileUri emits an UPPERCASE drive,
    # but PSES echoes the drive back LOWERCASED in publishDiagnostics. The daemon
    # keys both the stored publish (Invoke-LspMessage) and the request lookup
    # (Get-Diagnostics) through ConvertTo-UriKey so a lowercased-drive publish still
    # matches the document we opened -- otherwise diagnostics are silently dropped.
    # Adversarial control: make ConvertTo-UriKey return $Uri unchanged and the
    # 'maps ... to the same key' assertion goes RED.
    # NOTE: assertions use -BeExactly (case-SENSITIVE). Pester's plain -Be folds
    # case, which would mask the very mismatch this guards -- with -Be the key
    # equality would pass even if ConvertTo-UriKey did nothing, making the test
    # decorative. -BeExactly is what gives the adversarial control teeth.
    It 'maps an uppercase-drive and a lowercase-drive URI to the same key' {
        $upper = 'file:///C:/temp/foo.ps1'    # what ConvertTo-FileUri emits
        $lower = 'file:///c:/temp/foo.ps1'    # what PSES echoes back
        $upper | Should -Not -BeExactly $lower                # they differ before keying
        (ConvertTo-UriKey $upper) | Should -BeExactly (ConvertTo-UriKey $lower)
    }
    It 'round-trips a real ConvertTo-FileUri result against a lowercased-drive publish' -Skip:(-not $script:OnWindows) {
        $ours = ConvertTo-FileUri 'C:\temp\foo.ps1'           # file:///C:/temp/foo.ps1
        $psesEcho = $ours.Substring(0, 8) + $ours.Substring(8, 1).ToLowerInvariant() + $ours.Substring(9)
        $ours | Should -Not -BeExactly $psesEcho              # raw URIs mismatch on drive case
        (ConvertTo-UriKey $ours) | Should -BeExactly (ConvertTo-UriKey $psesEcho)
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

Describe 'New-InitializeParams -- omits workspaceFolders (regression: PSES #2300 OnInitialize NRE on Linux)' {
    # Guard 3 -- landmine 3. PSES v4.6.0 throws a NullReferenceException in its own
    # OnInitialize handler (the workspaceFolders add path) on Linux when initialize
    # carries a top-level workspaceFolders member (upstream #2300). The daemon dodges
    # it by OMITTING that member and relying on rootUri alone. This is the client-side
    # workaround being pinned; it does NOT fix the upstream bug. Adversarial control:
    # add a workspaceFolders key to New-InitializeParams and the 'does NOT include'
    # assertion goes RED.
    BeforeAll {
        $script:InitParams = New-InitializeParams -RootUri 'file:///C:/proj' -ProcessId 4242
    }
    It 'does NOT include a top-level workspaceFolders member (the #2300 dodge)' {
        $script:InitParams.ContainsKey('workspaceFolders') | Should -BeFalse
    }
    It 'still carries rootUri, processId, clientInfo, and capabilities' {
        $script:InitParams.rootUri | Should -Be 'file:///C:/proj'
        $script:InitParams.processId | Should -Be 4242
        $script:InitParams.clientInfo | Should -Not -BeNullOrEmpty
        $script:InitParams.capabilities | Should -Not -BeNullOrEmpty
    }
    It 'still declares the workspaceFolders CAPABILITY boolean -- distinct from the params member that trips the NRE' {
        # capabilities.workspace.workspaceFolders = $true is SAFE (it only advertises
        # support); it is the params-level folder list that is omitted. This guards
        # that a future edit does not "fix" #2300 by dropping the capability (which
        # would not help) instead of keeping the params member omitted.
        $script:InitParams.capabilities.workspace.workspaceFolders | Should -BeTrue
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

Describe 'Get-PluginOptionBool -- boolean userConfig (Track A enableStats)' {
    # The manifest types every option as a STRING, so a boolean knob arrives as the
    # text 'true'/'false'/etc. Get-PluginOptionBool maps the truthy/falsey tokens and
    # falls back (like Get-PluginOptionInt) on absent / blank / unexpanded token.
    BeforeEach {
        Get-ChildItem Env: | Where-Object { $_.Name -like 'CLAUDE_PLUGIN_OPTION_*' } |
            ForEach-Object { Remove-Item -LiteralPath ('Env:' + $_.Name) -ErrorAction SilentlyContinue }
    }
    AfterEach {
        Get-ChildItem Env: | Where-Object { $_.Name -like 'CLAUDE_PLUGIN_OPTION_*' } |
            ForEach-Object { Remove-Item -LiteralPath ('Env:' + $_.Name) -ErrorAction SilentlyContinue }
    }
    It 'defaults to $false when unset' {
        Get-PluginOptionBool 'enableStats' | Should -BeFalse
    }
    It 'honors a non-default fallback when unset' {
        Get-PluginOptionBool 'enableStats' $true | Should -BeTrue
    }
    It 'reads "<_>" as true' -ForEach @('true', '1', 'yes', 'on', 'TRUE', 'On') {
        $env:CLAUDE_PLUGIN_OPTION_enableStats = $_
        Get-PluginOptionBool 'enableStats' | Should -BeTrue
    }
    It 'reads "<_>" as false (overriding a true default)' -ForEach @('false', '0', 'no', 'off', 'FALSE') {
        $env:CLAUDE_PLUGIN_OPTION_enableStats = $_
        Get-PluginOptionBool 'enableStats' $true | Should -BeFalse
    }
    It 'falls back on an unexpanded user_config token' {
        $env:CLAUDE_PLUGIN_OPTION_enableStats = '${user_config.enableStats}'
        Get-PluginOptionBool 'enableStats' $false | Should -BeFalse
    }
    It 'falls back to the default on an unrecognized value' {
        $env:CLAUDE_PLUGIN_OPTION_enableStats = 'maybe'
        Get-PluginOptionBool 'enableStats' $true | Should -BeTrue
    }
}

Describe 'Write-StatsLine -- telemetry writer (Track A: JSONL, append, rotation, fail-safe)' {
    # Stats land under Get-LogDir, which keys off CLAUDE_PLUGIN_DATA -- so each test
    # points it at a throwaway temp root and cleans up after.
    BeforeEach {
        $script:PrevData = $env:CLAUDE_PLUGIN_DATA
        $script:TmpData = Join-Path ([System.IO.Path]::GetTempPath()) ('psls-stats-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $env:CLAUDE_PLUGIN_DATA = $script:TmpData
        $script:StatsFile = Join-Path (Get-LogDir) 'stats.jsonl'
    }
    AfterEach {
        if (Test-Path -LiteralPath $script:TmpData) { Remove-Item -LiteralPath $script:TmpData -Recurse -Force -ErrorAction SilentlyContinue }
        if ($null -eq $script:PrevData) {
            Remove-Item -LiteralPath 'Env:CLAUDE_PLUGIN_DATA' -ErrorAction SilentlyContinue
        } else {
            $env:CLAUDE_PLUGIN_DATA = $script:PrevData
        }
    }
    It 'writes exactly one JSONL line that round-trips with its fields' {
        Write-StatsLine @{ ts = 'T'; taken = 'daemon-analyze'; totalMs = 42; records = 3 }
        $lines = @(Get-Content -LiteralPath $script:StatsFile)
        $lines.Count | Should -Be 1
        $obj = $lines[0] | ConvertFrom-Json
        $obj.taken | Should -BeExactly 'daemon-analyze'
        $obj.totalMs | Should -Be 42
        $obj.records | Should -Be 3
    }
    It 'appends (does not overwrite) across calls' {
        Write-StatsLine @{ taken = 'a' }
        Write-StatsLine @{ taken = 'b' }
        @(Get-Content -LiteralPath $script:StatsFile).Count | Should -Be 2
    }
    It 'rotates to stats.jsonl.1 once the cap is exceeded (single rollover)' {
        # Tiny cap: the first write creates the file; the second sees it over-cap and
        # rolls it to .1 before writing a fresh live file.
        Write-StatsLine -Record @{ taken = 'first' } -CapBytes 5
        Write-StatsLine -Record @{ taken = 'second' } -CapBytes 5
        (Test-Path -LiteralPath ($script:StatsFile + '.1')) | Should -BeTrue
        $live = @(Get-Content -LiteralPath $script:StatsFile)
        $live.Count | Should -Be 1
        ($live[0] | ConvertFrom-Json).taken | Should -BeExactly 'second'
        (@(Get-Content -LiteralPath ($script:StatsFile + '.1'))[0] | ConvertFrom-Json).taken | Should -BeExactly 'first'
    }
    It 'is fail-safe: a directory squatting the stats path does not throw' {
        # Force a write failure: create a directory where stats.jsonl should be. The
        # writer must swallow it (best-effort) and never throw to its caller.
        New-Item -ItemType Directory -Force -Path $script:StatsFile | Out-Null
        { Write-StatsLine @{ taken = 'blocked' } } | Should -Not -Throw
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

Describe 'Resolve-PssaSettingsPath -- honor PSScriptAnalyzerSettings.psd1 (dispatch 000018)' {
    # Track 1 (PSES v4.6.0 source) proved PSES needs an ABSOLUTE settings path: its
    # WorkspaceService.FindFileInWorkspace returns a rooted path AS-IS, before the
    # WorkspaceFolders loop the daemon leaves EMPTY (#2300 dodge); a relative path
    # would resolve against PSES's process CWD and miss. These guard the resolver:
    # absolute override wins, a RELATIVE override is ignored, discovery walks up to
    # the nearest file, and the project-root bound stops the walk.
    BeforeAll {
        $script:Root = Join-Path $TestDrive 'proj'
        $script:Sub = Join-Path $script:Root 'src'
        New-Item -ItemType Directory -Force -Path $script:Sub | Out-Null
        $script:RootCfg = Join-Path $script:Root 'PSScriptAnalyzerSettings.psd1'
        $script:SubCfg = Join-Path $script:Sub 'PSScriptAnalyzerSettings.psd1'
        $script:EditFile = Join-Path $script:Sub 'edited.ps1'
        Set-Content -LiteralPath $script:EditFile -Value 'Get-Process' -Encoding ascii
    }
    AfterEach {
        Remove-Item -LiteralPath $script:RootCfg -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:SubCfg -Force -ErrorAction SilentlyContinue
    }

    It 'returns an absolute override as-is (resolved to a full path); existence is left to PSES' {
        $override = Join-Path (Join-Path $TestDrive 'elsewhere') 'custom.psd1'
        Resolve-PssaSettingsPath -EditedFilePath $script:EditFile -ProjectRoot $script:Root -Override $override |
            Should -BeExactly ([System.IO.Path]::GetFullPath($override))
    }
    It 'ignores a RELATIVE override and falls through to discovery (absolute only)' {
        Set-Content -LiteralPath $script:RootCfg -Value '@{}' -Encoding ascii
        Resolve-PssaSettingsPath -EditedFilePath $script:EditFile -ProjectRoot $script:Root -Override 'relative-custom.psd1' |
            Should -BeExactly ([System.IO.Path]::GetFullPath($script:RootCfg))
    }
    It 'discovers a settings file at the project root by walking up from a subdir' {
        Set-Content -LiteralPath $script:RootCfg -Value '@{}' -Encoding ascii
        Resolve-PssaSettingsPath -EditedFilePath $script:EditFile -ProjectRoot $script:Root |
            Should -BeExactly ([System.IO.Path]::GetFullPath($script:RootCfg))
    }
    It 'prefers the NEAREST settings file (subdir over root)' {
        Set-Content -LiteralPath $script:RootCfg -Value '@{}' -Encoding ascii
        Set-Content -LiteralPath $script:SubCfg -Value '@{}' -Encoding ascii
        Resolve-PssaSettingsPath -EditedFilePath $script:EditFile -ProjectRoot $script:Root |
            Should -BeExactly ([System.IO.Path]::GetFullPath($script:SubCfg))
    }
    It 'does NOT honor a settings file ABOVE the project root (the bound)' {
        # Settings ONLY in the root's parent; the walk must stop at the root and find
        # nothing. Adversarial control: drop the bound and this returns the parent
        # file -> RED.
        $parentCfg = Join-Path $TestDrive 'PSScriptAnalyzerSettings.psd1'
        Set-Content -LiteralPath $parentCfg -Value '@{}' -Encoding ascii
        try {
            Resolve-PssaSettingsPath -EditedFilePath $script:EditFile -ProjectRoot $script:Root | Should -BeExactly ''
        } finally { Remove-Item -LiteralPath $parentCfg -Force -ErrorAction SilentlyContinue }
    }
    It 'returns empty when no settings file exists and no override is given (no-config path)' {
        Resolve-PssaSettingsPath -EditedFilePath $script:EditFile -ProjectRoot $script:Root | Should -BeExactly ''
    }
    It 'checks the edited file own directory but does not escape upward when the file is outside the project root' {
        $outsideSub = Join-Path (Join-Path $TestDrive 'outside') 'deep'
        New-Item -ItemType Directory -Force -Path $outsideSub | Out-Null
        $ownCfg = Join-Path $outsideSub 'PSScriptAnalyzerSettings.psd1'
        $parentCfg = Join-Path (Join-Path $TestDrive 'outside') 'PSScriptAnalyzerSettings.psd1'
        $f = Join-Path $outsideSub 'x.ps1'; Set-Content -LiteralPath $f -Value 'Get-Process' -Encoding ascii
        Set-Content -LiteralPath $parentCfg -Value '@{}' -Encoding ascii
        try {
            # parent-only settings, file outside the root -> not honored (no upward escape)
            Resolve-PssaSettingsPath -EditedFilePath $f -ProjectRoot $script:Root | Should -BeExactly ''
            # own-dir settings -> honored
            Set-Content -LiteralPath $ownCfg -Value '@{}' -Encoding ascii
            Resolve-PssaSettingsPath -EditedFilePath $f -ProjectRoot $script:Root |
                Should -BeExactly ([System.IO.Path]::GetFullPath($ownCfg))
        } finally { Remove-Item -LiteralPath $ownCfg, $parentCfg -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'New-ScriptAnalysisSettings -- the PSES scriptAnalysis settings object (dispatch 000018)' {
    It 'always enables analysis (with or without a settings path)' {
        (New-ScriptAnalysisSettings).enable | Should -BeTrue
        (New-ScriptAnalysisSettings 'C:\proj\PSScriptAnalyzerSettings.psd1').enable | Should -BeTrue
    }
    It 'omits settingsPath when none is given (no-config -> PSES default rules)' {
        (New-ScriptAnalysisSettings).ContainsKey('settingsPath') | Should -BeFalse
        ((New-ScriptAnalysisSettings '') | ConvertTo-Json -Compress) | Should -Not -Match 'settingsPath'
    }
    It 'includes settingsPath when resolved (the camelCase wire key PSES consumes)' {
        $obj = New-ScriptAnalysisSettings 'C:\proj\PSScriptAnalyzerSettings.psd1'
        $obj.settingsPath | Should -BeExactly 'C:\proj\PSScriptAnalyzerSettings.psd1'
        ($obj | ConvertTo-Json -Compress) | Should -Match '"settingsPath"'
    }
}

# ===========================================================================
# Analysis status: clean vs incomplete vs degraded (dispatch 000022)
# ===========================================================================

Describe 'Resolve-AnalysisStatus -- clean vs incomplete vs degraded (dispatch 000022)' {
    # The pure seam that keeps "could not analyze" from looking identical to "analyzed,
    # found nothing." Maps (settled, pssaAvailable) -> status; the daemon shapes it, the
    # client renders it, so the two cannot drift. Adversarial control: collapse the
    # not-settled branch in Resolve-AnalysisStatus and the 'incomplete beats degraded' and
    # 'distinguishes clean from incomplete' assertions go RED.
    It 'settled + PSSA available -> ok (a genuinely clean pass)' {
        Resolve-AnalysisStatus -Settled $true -PssaAvailable $true | Should -BeExactly 'ok'
    }
    It 'NOT settled -> incomplete (did not settle = we do not know the file is clean)' {
        Resolve-AnalysisStatus -Settled $false -PssaAvailable $true | Should -BeExactly 'incomplete'
    }
    It 'settled but PSSA absent -> degraded (parser-only)' {
        Resolve-AnalysisStatus -Settled $true -PssaAvailable $false | Should -BeExactly 'degraded'
    }
    It 'incomplete OUTRANKS degraded: not settled on a parser-only daemon is still incomplete' {
        # "this edit was not checked at all" beats "checked with fewer rules" (000022 Q(c)).
        Resolve-AnalysisStatus -Settled $false -PssaAvailable $false | Should -BeExactly 'incomplete'
    }
    It 'distinguishes clean (settled, zero records) from incomplete (did not settle) -- they must NOT be equal' {
        # The core acceptance (000022): a clean settled pass and a non-settling pass must
        # map to different statuses, so the client can render one as nothing and the other
        # as a visible "unavailable."
        $clean = Resolve-AnalysisStatus -Settled $true -PssaAvailable $true
        $incomplete = Resolve-AnalysisStatus -Settled $false -PssaAvailable $true
        $clean | Should -Not -BeExactly $incomplete
    }
}

Describe 'Get-DiagnosticsStatusBanner -- the visible, non-clean wording (dispatch 000022)' {
    # The exact user-facing text, owned in one place so daemon + client never disagree.
    # 'ok' MUST render empty -- that is the byte-identical warm-path guard (a clean pass
    # adds nothing to additionalContext). Adversarial control: return a non-empty string
    # for 'ok' and both this and the warm-path additivity integration test go RED.
    It 'renders nothing for ok (clean) -- the byte-identical warm-path guard' {
        Get-DiagnosticsStatusBanner 'ok' 'C:\x\foo.ps1' | Should -BeExactly ''
    }
    It 'renders nothing for an empty/absent status' {
        Get-DiagnosticsStatusBanner '' 'C:\x\foo.ps1' | Should -BeExactly ''
    }
    It 'incomplete: a single visible "analysis did not complete" message naming the file' {
        $b = Get-DiagnosticsStatusBanner 'incomplete' 'C:\x\foo.ps1'
        $b | Should -Match 'unavailable'
        $b | Should -Match 'did not complete'
        $b | Should -Match ([regex]::Escape('C:\x\foo.ps1'))
    }
    It 'degraded: a DISTINCT parser-only / PSScriptAnalyzer-unavailable message' {
        $b = Get-DiagnosticsStatusBanner 'degraded' 'C:\x\foo.ps1'
        $b | Should -Match 'parser-only'
        $b | Should -Match 'PSScriptAnalyzer unavailable'
    }
    It 'incomplete and degraded are DIFFERENT messages (two categories, not one)' {
        (Get-DiagnosticsStatusBanner 'incomplete' 'C:\x\foo.ps1') |
            Should -Not -BeExactly (Get-DiagnosticsStatusBanner 'degraded' 'C:\x\foo.ps1')
    }
    It 'unavailable (dispatch 000024): a DISTINCT install-incomplete message naming the file' {
        # The install-time case -- the PSES bundle never bootstrapped. Its remediation differs
        # from the transient 'incomplete' (fix the install/network, not "retry"), so it must
        # read distinctly: "not installed" / "bootstrap did not complete", not "did not settle."
        $b = Get-DiagnosticsStatusBanner 'unavailable' 'C:\x\foo.ps1'
        $b | Should -Match 'unavailable'
        $b | Should -Match 'not installed'
        $b | Should -Match 'bootstrap'
        $b | Should -Match ([regex]::Escape('C:\x\foo.ps1'))
    }
    It 'unavailable (dispatch 000024) is DIFFERENT from BOTH incomplete and degraded (three categories, not one)' {
        # 000024 extends the 000022 "make failure modes distinct" thesis to install-time: a
        # broken install must never render identically to a transient miss or a parser-only pass.
        $u = Get-DiagnosticsStatusBanner 'unavailable' 'C:\x\foo.ps1'
        $u | Should -Not -BeExactly (Get-DiagnosticsStatusBanner 'incomplete' 'C:\x\foo.ps1')
        $u | Should -Not -BeExactly (Get-DiagnosticsStatusBanner 'degraded' 'C:\x\foo.ps1')
    }
    It 'is ASCII-only (PS 5.1 em-dash trap)' {
        foreach ($s in @('incomplete', 'degraded', 'unavailable')) {
            $b = Get-DiagnosticsStatusBanner $s 'C:\x\foo.ps1'
            (@([System.Text.Encoding]::UTF8.GetBytes($b) | Where-Object { $_ -gt 127 }).Count) | Should -Be 0
        }
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

# ===========================================================================
# Edit-range diagnostic scoping (dispatch 000019)
# ===========================================================================

Describe 'ConvertTo-TouchedRanges -- derive touched line ranges from tool_response (dispatch 000019)' {
    # Track 1 finding (confirmed against real PostToolUse payloads): a successful Edit /
    # MultiEdit / Write-update carries structuredPatch hunks with 1-based post-edit
    # newStart/newLines; a FAILED edit reports a STRING tool_response; a Write-create has
    # an EMPTY patch. Derivation is keyed on PATCH STATE, not tool name, and FAILS OPEN
    # (returns $null) on anything indeterminate so scoping can never hide a diagnostic.
    BeforeAll {
        # Defined in BeforeAll (run phase): a function in the Describe body would only
        # exist during Pester's discovery phase and be invisible to the It blocks.
        function New-Resp { param($Hunks) [pscustomobject]@{ structuredPatch = $Hunks } }
        function New-Hunk { param($NewStart, $NewLines) [pscustomobject]@{ newStart = $NewStart; newLines = $NewLines } }
    }

    It 'derives a single hunk span [newStart, newStart+newLines-1]' {
        $r = @(ConvertTo-TouchedRanges -ToolResponse (New-Resp @((New-Hunk 10 3))))
        $r.Count | Should -Be 1
        $r[0].start | Should -Be 10
        $r[0].end | Should -Be 12
    }
    It 'unions multiple hunks (a single Edit can split into several)' {
        $r = @(ConvertTo-TouchedRanges -ToolResponse (New-Resp @((New-Hunk 279 18), (New-Hunk 306 7))))
        $r.Count | Should -Be 2
        $r[0].start | Should -Be 279; $r[0].end | Should -Be 296
        $r[1].start | Should -Be 306; $r[1].end | Should -Be 312
    }
    It 'widens by ContextLines and clamps the low end to line 1' {
        $r = @(ConvertTo-TouchedRanges -ToolResponse (New-Resp @((New-Hunk 2 1))) -ContextLines 3)
        $r[0].start | Should -Be 1     # 2 - 3 = -1 -> clamped to 1
        $r[0].end | Should -Be 5       # (2 + 1 - 1) + 3 = 5
    }
    It 'defaults ContextLines to 0 (the patch already includes diff context; do not stack)' {
        $r = @(ConvertTo-TouchedRanges -ToolResponse (New-Resp @((New-Hunk 10 1))))
        $r[0].start | Should -Be 10
        $r[0].end | Should -Be 10
    }
    It 'treats a 0-line (pure deletion) hunk as the single line at newStart' {
        $r = @(ConvertTo-TouchedRanges -ToolResponse (New-Resp @((New-Hunk 40 0))))
        $r[0].start | Should -Be 40
        $r[0].end | Should -Be 40
    }
    It 'FAILS OPEN ($null) on a string tool_response (a FAILED edit reports a string error)' {
        ConvertTo-TouchedRanges -ToolResponse 'Error: String to replace not found in file.' | Should -BeNullOrEmpty
    }
    It 'FAILS OPEN ($null) on a null tool_response (missing payload field)' {
        ConvertTo-TouchedRanges -ToolResponse $null | Should -BeNullOrEmpty
    }
    It 'FAILS OPEN ($null) when there is no structuredPatch property' {
        ConvertTo-TouchedRanges -ToolResponse ([pscustomobject]@{ filePath = 'x.ps1'; type = 'create' }) | Should -BeNullOrEmpty
    }
    It 'FAILS OPEN ($null) on an EMPTY structuredPatch (a Write that created a new file)' {
        ConvertTo-TouchedRanges -ToolResponse (New-Resp @()) | Should -BeNullOrEmpty
    }
    It 'FAILS OPEN ($null) when hunks carry no usable newStart' {
        ConvertTo-TouchedRanges -ToolResponse (New-Resp @(([pscustomobject]@{ newLines = 3 }))) | Should -BeNullOrEmpty
    }
}

Describe 'Select-DiagnosticsInRange -- overlap not containment, fail-open (dispatch 000019)' {
    BeforeAll {
        function New-Rec { param($Line, $EndLine) [ordered]@{ severity = 'Warning'; line = $Line; endLine = $EndLine; col = 1; source = 'PSSA'; code = 'X'; message = ('m' + $Line) } }
    }
    It 'keeps a diagnostic whose multi-line span STRADDLES the edit boundary (overlap, not containment)' {
        # Diagnostic spans lines 3..7; the edit touched only line 6. Neither endpoint is
        # inside the range, but the span crosses it -> kept (000019 Q4: overlap).
        $recs = @((New-Rec 3 7))
        $range = @([pscustomobject]@{ start = 6; end = 6 })
        @(Select-DiagnosticsInRange $recs $range).Count | Should -Be 1
    }
    It 'drops a diagnostic entirely outside the touched range' {
        @(Select-DiagnosticsInRange @((New-Rec 3 3)) @([pscustomobject]@{ start = 6; end = 6 })).Count | Should -Be 0
    }
    It 'keeps an in-range diagnostic (never over-filters the edited line itself)' {
        @(Select-DiagnosticsInRange @((New-Rec 6 6)) @([pscustomobject]@{ start = 6; end = 6 })).Count | Should -Be 1
    }
    It 'FAILS OPEN: null OR empty ranges return ALL records (an indeterminate range hides nothing)' {
        $recs = @((New-Rec 3 3), (New-Rec 99 99))
        @(Select-DiagnosticsInRange $recs $null).Count | Should -Be 2
        @(Select-DiagnosticsInRange $recs @()).Count | Should -Be 2
    }
    It 'treats a record without endLine as a point at its start line' {
        $recs = @([ordered]@{ severity = 'Warning'; line = 6; col = 1; source = 'PSSA'; code = 'X'; message = 'no-end' })
        @(Select-DiagnosticsInRange $recs @([pscustomobject]@{ start = 6; end = 6 })).Count | Should -Be 1
        @(Select-DiagnosticsInRange $recs @([pscustomobject]@{ start = 8; end = 8 })).Count | Should -Be 0
    }
}

Describe 'Get-ScopedCappedResult -- scope then cap, with telemetry counts (dispatch 000019)' {
    # The load-bearing adversarial control (mirrors 000018's RED/GREEN): with a touched
    # range, the out-of-range diagnostic is filtered; with no range (scoping off /
    # indeterminate), it reappears. Plus: scope runs BEFORE the cap, and the pre-scope
    # (total) / post-scope (surfaced) counts are recorded so the noise reduction is
    # measurable.
    BeforeAll {
        function New-Rec { param($Line, $EndLine) [ordered]@{ severity = 'Warning'; line = $Line; endLine = $EndLine; col = 1; source = 'PSSA'; code = 'X'; message = ('m' + $Line) } }
        $script:Recs = @((New-Rec 5 5), (New-Rec 50 50), (New-Rec 6 8))
        $script:Range = @([pscustomobject]@{ start = 4; end = 6 })
    }
    It 'GREEN: scopes to the touched range (out-of-range dropped, overlap kept)' {
        $r = Get-ScopedCappedResult -Records $script:Recs -Ranges $script:Range -PerFileCap 20
        @($r.shown).Count | Should -Be 2
        $r.shown.line | Should -Not -Contain 50
        $r.scopeApplied | Should -BeTrue
        $r.total | Should -Be 3
        $r.surfaced | Should -Be 2
    }
    It 'RED on revert: no ranges -> NOTHING dropped (whole-file, byte-identical to cap-only)' {
        $r = Get-ScopedCappedResult -Records $script:Recs -Ranges $null -PerFileCap 20
        @($r.shown).Count | Should -Be 3
        $r.shown.line | Should -Contain 50
        $r.scopeApplied | Should -BeFalse
        $r.total | Should -Be 3
        $r.surfaced | Should -Be 3
    }
    It 'scope-then-cap: the cap applies to the SCOPED set (30 in-range, cap 20 -> 20 shown, 10 omitted, 30 surfaced)' {
        $many = @(1..30 | ForEach-Object { New-Rec 5 5 })
        $r = Get-ScopedCappedResult -Records $many -Ranges $script:Range -PerFileCap 20
        $r.surfaced | Should -Be 30
        @($r.shown).Count | Should -Be 20
        $r.omitted | Should -Be 10
    }
    It 'scope-then-cap: scoping below the cap means the cap never fires (5 in-range of 30 -> 5 shown, 0 omitted)' {
        # If the cap ran FIRST (cap-then-scope), it would slice the unscoped 30 down to 20
        # and then scope -- a different result. surfaced=5 + omitted=0 proves scope ran first.
        $mix = @(1..5 | ForEach-Object { New-Rec 5 5 }) + @(1..25 | ForEach-Object { New-Rec 99 99 })
        $r = Get-ScopedCappedResult -Records $mix -Ranges $script:Range -PerFileCap 20
        $r.surfaced | Should -Be 5
        @($r.shown).Count | Should -Be 5
        $r.omitted | Should -Be 0
    }
}

Describe 'ConvertTo-DiagRecord -- endLine for edit-range scoping (dispatch 000019)' {
    It 'emits endLine (1-based); equals the start line for a single-line diagnostic' {
        $d = [pscustomobject]@{
            range = [pscustomobject]@{ start = [pscustomobject]@{ line = 4; character = 0 }; end = [pscustomobject]@{ line = 4; character = 3 } }
            severity = 2; source = 'PSScriptAnalyzer'; code = 'X'; message = 'one line'
        }
        $r = ConvertTo-DiagRecord $d
        $r.Contains('endLine') | Should -BeTrue
        $r.line | Should -Be 5
        $r.endLine | Should -Be 5
    }
    It 'carries a multi-line span end (end line > start line)' {
        $d = [pscustomobject]@{
            range = [pscustomobject]@{ start = [pscustomobject]@{ line = 4; character = 0 }; end = [pscustomobject]@{ line = 9; character = 2 } }
            severity = 2; source = 'PSScriptAnalyzer'; code = 'X'; message = 'spans lines'
        }
        $r = ConvertTo-DiagRecord $d
        $r.line | Should -Be 5
        $r.endLine | Should -Be 10   # 0-based 9 -> 1-based 10
    }
    It 'defaults endLine to the start line when no range end is present' {
        $d = [pscustomobject]@{
            range = [pscustomobject]@{ start = [pscustomobject]@{ line = 7; character = 0 } }
            severity = 2; source = 'PSScriptAnalyzer'; code = 'X'; message = 'no end'
        }
        $r = ConvertTo-DiagRecord $d
        $r.endLine | Should -Be 8
    }
}
