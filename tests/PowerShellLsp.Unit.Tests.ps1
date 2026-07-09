#Requires -Version 5.1

# Unit regression tests (Pester 5) for the powershell-lsp plugin. No network, no
# daemon: fast and cross-platform. Run via tests/run-tests.ps1.

BeforeAll {
    $script:PluginRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsDir = Join-Path $script:PluginRoot 'scripts'
    . (Join-Path $script:ScriptsDir 'lib/lsp-common.ps1')
    . (Join-Path $script:ScriptsDir 'lib/security-classifier.ps1')
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

Describe 'Dogfood diagnostic capture (dispatch 000039)' {
    # The capture side-channel mirrors Write-StatsLine's fail-safe contract: append-only
    # JSONL, best-effort, never alters the diagnostics surface or the exit code. The log path
    # is redirected to a throwaway temp file via the POWERSHELL_LSP_DOGFOOD_LOG override so
    # these never touch the real (gitignored) dogfood/ tree.
    BeforeEach {
        $script:PrevDfLog = $env:POWERSHELL_LSP_DOGFOOD_LOG
        $script:DfDir = Join-Path $TestDrive ('df-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $script:DfDir | Out-Null
        $script:DfLog = Join-Path $script:DfDir 'diagnostics.jsonl'
        $env:POWERSHELL_LSP_DOGFOOD_LOG = $script:DfLog
    }
    AfterEach {
        if ($null -eq $script:PrevDfLog) {
            Remove-Item -LiteralPath 'Env:POWERSHELL_LSP_DOGFOOD_LOG' -ErrorAction SilentlyContinue
        } else {
            $env:POWERSHELL_LSP_DOGFOOD_LOG = $script:PrevDfLog
        }
    }

    Context 'Get-DiagnosticShapeHash -- stable analysis-time dedup key (OQ2 normalization)' {
        It 'is identical for identical (rule, line)' {
            (Get-DiagnosticShapeHash -RuleId 'PSUseApprovedVerbs' -OffendingLine 'function Frob-X {') |
                Should -BeExactly (Get-DiagnosticShapeHash -RuleId 'PSUseApprovedVerbs' -OffendingLine 'function Frob-X {')
        }
        It 'collapses interior whitespace and trims (same shape -> same hash)' {
            (Get-DiagnosticShapeHash -RuleId 'R' -OffendingLine '  a   b  ') |
                Should -BeExactly (Get-DiagnosticShapeHash -RuleId 'R' -OffendingLine 'a b')
        }
        It 'differs across distinct rule ids (same line)' {
            (Get-DiagnosticShapeHash -RuleId 'R1' -OffendingLine 'x') |
                Should -Not -BeExactly (Get-DiagnosticShapeHash -RuleId 'R2' -OffendingLine 'x')
        }
        It 'differs across distinct lines (same rule)' {
            (Get-DiagnosticShapeHash -RuleId 'R' -OffendingLine 'x') |
                Should -Not -BeExactly (Get-DiagnosticShapeHash -RuleId 'R' -OffendingLine 'y')
        }
        It 'PRESERVES case -- lines differing only in case do NOT collapse (the conservative OQ2 choice)' {
            # Lowercasing would risk collapsing genuinely distinct lines (e.g. two string
            # literals differing only in case), so case is preserved. Adversarial control:
            # add .ToLowerInvariant() to the normalization and this goes RED.
            (Get-DiagnosticShapeHash -RuleId 'R' -OffendingLine 'Get-Item') |
                Should -Not -BeExactly (Get-DiagnosticShapeHash -RuleId 'R' -OffendingLine 'get-item')
        }
        It 'does not collide across the rule/line boundary (separator works)' {
            (Get-DiagnosticShapeHash -RuleId 'AB' -OffendingLine '') |
                Should -Not -BeExactly (Get-DiagnosticShapeHash -RuleId 'A' -OffendingLine 'B')
        }
        It 'is a 64-char lowercase hex SHA-256 digest' {
            (Get-DiagnosticShapeHash -RuleId 'R' -OffendingLine 'x') | Should -Match '^[0-9a-f]{64}$'
        }
    }

    Context 'record normalizers -- the two emit-site shapes' {
        It 'New-CaptureRecordFromDiag maps a PSSA diagnostic (code -> ruleId, source kept)' {
            $d = [pscustomobject]@{ severity = 'Warning'; line = 9; col = 5; source = 'PSScriptAnalyzer'; code = 'PSUseApprovedVerbs'; message = 'verb' }
            $r = New-CaptureRecordFromDiag $d
            $r.ruleId | Should -BeExactly 'PSUseApprovedVerbs'
            $r.source | Should -BeExactly 'PSScriptAnalyzer'
            $r.severity | Should -BeExactly 'Warning'
            $r.line | Should -Be 9
            $r.col | Should -Be 5
        }
        It 'New-CaptureRecordFromDiag falls back to source=parser and ruleId="" on a no-source/no-code diag' {
            $d = [pscustomobject]@{ severity = 'Error'; line = 1; col = 1; source = ''; code = ''; message = 'm' }
            $r = New-CaptureRecordFromDiag $d
            $r.source | Should -BeExactly 'parser'
            $r.ruleId | Should -BeExactly ''
        }
        It 'New-CaptureRecordFromDiag treats a "0" code as no rule id' {
            $d = [pscustomobject]@{ severity = 'Error'; line = 1; col = 1; source = 'X'; code = '0'; message = 'm' }
            (New-CaptureRecordFromDiag $d).ruleId | Should -BeExactly ''
        }
        It 'New-CaptureRecordFromParseError maps a real ParseError (source=parser, severity=Error, ErrorId)' {
            $t = $null; $e = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput("function X {`n  Get-Process", [ref]$t, [ref]$e)
            $r = New-CaptureRecordFromParseError $e[0]
            $r.source | Should -BeExactly 'parser'
            $r.severity | Should -BeExactly 'Error'
            $r.ruleId | Should -Not -BeNullOrEmpty       # the parser's ErrorId (e.g. MissingEndCurlyBrace)
            $r.line | Should -BeGreaterThan 0
        }
    }

    Context 'Add-DiagnosticCaptureEntries -- append-only JSONL, every occurrence, fail-safe' {
        It 'appends one entry carrying every required field, with verdict present and EMPTY' {
            $src = Join-Path $script:DfDir 'sample.ps1'
            "line one`nfunction Frobnicate-X {`n  Get-Process`n}" | Set-Content -LiteralPath $src -Encoding ascii
            $rec = @{ line = 2; col = 10; ruleId = 'PSUseApprovedVerbs'; source = 'PSScriptAnalyzer'; severity = 'Warning'; message = 'verb' }
            Add-DiagnosticCaptureEntries -File $src -Records @($rec)
            $lines = @(Get-Content -LiteralPath $script:DfLog)
            $lines.Count | Should -Be 1
            $o = $lines[0] | ConvertFrom-Json
            foreach ($field in @('ts', 'file', 'line', 'col', 'ruleId', 'source', 'severity', 'message', 'snippet', 'hash', 'verdict')) {
                ($o.PSObject.Properties.Name -contains $field) | Should -BeTrue -Because "the entry must carry '$field'"
            }
            $o.verdict | Should -BeExactly ''                          # present AND empty (reserved for later annotation)
            $o.ruleId | Should -BeExactly 'PSUseApprovedVerbs'
            $o.source | Should -BeExactly 'PSScriptAnalyzer'
            $o.snippet | Should -BeExactly 'function Frobnicate-X {'   # the offending line at line 2
            $o.hash | Should -Match '^[0-9a-f]{64}$'
        }
        It 'logs EVERY occurrence -- two identical diagnostics yield two entries (no capture-time dedup)' {
            $src = Join-Path $script:DfDir 'sample2.ps1'
            'Write-Host hi' | Set-Content -LiteralPath $src -Encoding ascii
            $rec = @{ line = 1; col = 1; ruleId = 'PSAvoidUsingWriteHost'; source = 'PSScriptAnalyzer'; severity = 'Warning'; message = 'wh' }
            Add-DiagnosticCaptureEntries -File $src -Records @($rec, $rec)
            $lines = @(Get-Content -LiteralPath $script:DfLog)
            $lines.Count | Should -Be 2
            # identical (rule, line shape) -> identical hash, yet both occurrences are kept.
            ($lines[0] | ConvertFrom-Json).hash | Should -BeExactly ($lines[1] | ConvertFrom-Json).hash
        }
        It 'appends across calls (does not overwrite)' {
            $src = Join-Path $script:DfDir 'sample3.ps1'
            'gci' | Set-Content -LiteralPath $src -Encoding ascii
            $rec = @{ line = 1; col = 1; ruleId = 'PSAvoidUsingCmdletAliases'; source = 'PSScriptAnalyzer'; severity = 'Warning'; message = 'a' }
            Add-DiagnosticCaptureEntries -File $src -Records @($rec)
            Add-DiagnosticCaptureEntries -File $src -Records @($rec)
            @(Get-Content -LiteralPath $script:DfLog).Count | Should -Be 2
        }
        It 'is fail-safe: a directory squatting the log path does not throw (mirrors Write-StatsLine)' {
            Remove-Item -LiteralPath $script:DfLog -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Force -Path $script:DfLog | Out-Null   # squat -> every append fails
            $src = Join-Path $script:DfDir 'sample4.ps1'
            'gci' | Set-Content -LiteralPath $src -Encoding ascii
            $rec = @{ line = 1; col = 1; ruleId = 'R'; source = 'PSScriptAnalyzer'; severity = 'Warning'; message = 'm' }
            { Add-DiagnosticCaptureEntries -File $src -Records @($rec) } | Should -Not -Throw
        }
        It 'is a fail-safe no-op when given no records' {
            { Add-DiagnosticCaptureEntries -File 'C:\nope\x.ps1' -Records @() } | Should -Not -Throw
            (Test-Path -LiteralPath $script:DfLog) | Should -BeFalse
        }
        It 'writes an empty snippet when the diagnostic line is out of range (still appends)' {
            $src = Join-Path $script:DfDir 'sample5.ps1'
            'only one line' | Set-Content -LiteralPath $src -Encoding ascii
            $rec = @{ line = 999; col = 1; ruleId = 'R'; source = 'PSScriptAnalyzer'; severity = 'Warning'; message = 'm' }
            Add-DiagnosticCaptureEntries -File $src -Records @($rec)
            $o = @(Get-Content -LiteralPath $script:DfLog)[0] | ConvertFrom-Json
            $o.snippet | Should -BeExactly ''
            $o.line | Should -Be 999
        }
    }

    Context 'Get-DogfoodLogPath -- resolution + override' {
        It 'honors the POWERSHELL_LSP_DOGFOOD_LOG override verbatim' {
            $env:POWERSHELL_LSP_DOGFOOD_LOG = 'C:\custom\df.jsonl'
            Get-DogfoodLogPath | Should -BeExactly 'C:\custom\df.jsonl'
        }
        It 'defaults to the plugin-root dogfood/diagnostics.jsonl when no override is set' {
            Remove-Item -LiteralPath 'Env:POWERSHELL_LSP_DOGFOOD_LOG' -ErrorAction SilentlyContinue
            Get-DogfoodLogPath | Should -BeExactly (Join-Path $script:PluginRoot 'dogfood/diagnostics.jsonl')
        }
    }
}

Describe 'Dogfood annotation/review tool (dispatch 000043)' {
    # The reviewer FILLS the empty verdict the 000039 capture reserves. It is dot-source safe
    # (the doctor.ps1 pattern), so these exercise the pure logic with no I/O beyond TestDrive
    # temp files. Persistence keys on the capture record's shape-hash and lands in a SEPARATE
    # annotations file -- the diagnostics log is never rewritten (the non-destructive fence).
    BeforeAll {
        . (Join-Path $script:ScriptsDir 'review-dogfood.ps1')

        # Build one capture entry in the EXACT 000039 on-disk shape (ts/file/line/col/ruleId/
        # source/severity/message/snippet/hash/verdict). Defined in BeforeAll so the It blocks
        # (run phase) can see it.
        function New-DfEntry {
            param(
                [string] $Hash,
                [string] $RuleId = 'PSUseApprovedVerbs',
                [string] $Source = 'PSScriptAnalyzer',
                [string] $Severity = 'Warning',
                [string] $Message = 'msg',
                [string] $Snippet = 'function Frob-X {',
                [int] $Line = 1,
                [int] $Col = 10,
                [string] $File = 'C:\proj\a.ps1'
            )
            return [ordered]@{
                ts = '2026-06-23T00:00:00.0000000Z'; file = $File; line = $Line; col = $Col
                ruleId = $RuleId; source = $Source; severity = $Severity; message = $Message
                snippet = $Snippet; hash = $Hash; verdict = ''
            }
        }
        function Write-DfLog {
            param([string] $LogPath, [object[]] $Entries)
            $sb = New-Object System.Text.StringBuilder
            foreach ($e in @($Entries)) { [void]$sb.Append(($e | ConvertTo-Json -Depth 5 -Compress)); [void]$sb.Append("`n") }
            [System.IO.File]::WriteAllText($LogPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
        }
    }

    BeforeEach {
        $script:DfDir = Join-Path $TestDrive ('rev-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $script:DfDir | Out-Null
        $script:DfLog = Join-Path $script:DfDir 'diagnostics.jsonl'
        $script:DfAnn = Join-Path $script:DfDir 'annotations.jsonl'
    }

    Context 'frozen verdict vocabulary (NOT the 000027 taxonomy; no userConfig knob)' {
        It 'accepts each of the five frozen verdicts' {
            foreach ($v in @('useful', 'false-positive', 'noisy', 'bad-fix', 'unsure')) {
                (Test-DogfoodVerdict $v) | Should -BeTrue -Because "$v is frozen-valid"
            }
        }
        It 'rejects an out-of-enum verdict' {
            (Test-DogfoodVerdict 'great') | Should -BeFalse
        }
        It 'is case-sensitive (the enum is lower-case by definition)' {
            # Adversarial control: switch -ccontains to -contains in Test-DogfoodVerdict and this
            # goes RED -- the freeze is exact, not case-folded.
            (Test-DogfoodVerdict 'Useful') | Should -BeFalse
        }
        It 'the -Verdict ValidateSet and $script:DogfoodVerdicts are the SAME frozen set (no drift)' {
            # Both in-code sources of the enum are read FROM THE SCRIPT AST and must equal the
            # frozen five. Adversarial control: add a value to the ValidateSet or the array (not
            # both) and the set-equality goes RED -- the two cannot drift apart silently.
            $frozen = @('bad-fix', 'false-positive', 'noisy', 'unsure', 'useful')   # sorted
            $scriptPath = Join-Path $script:ScriptsDir 'review-dogfood.ps1'
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
            $vParam = $ast.Find({
                    param($n) $n -is [System.Management.Automation.Language.ParameterAst] -and
                    $n.Name.VariablePath.UserPath -eq 'Verdict' }, $true)
            $vsAttr = @($vParam.Attributes | Where-Object { $_.TypeName.FullName -match 'ValidateSet' })[0]
            $vsValues = @($vsAttr.PositionalArguments | ForEach-Object { [string]$_.Value }) | Sort-Object
            ($vsValues -join ',') | Should -BeExactly ($frozen -join ',')
            $assign = $ast.Find({
                    param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $n.Left.VariablePath.UserPath -eq 'script:DogfoodVerdicts' }, $true)
            $arrValues = @($assign.Right.FindAll({
                        param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) |
                    ForEach-Object { [string]$_.Value }) | Sort-Object
            ($arrValues -join ',') | Should -BeExactly ($frozen -join ',')
        }
    }

    Context 'readers -- tolerant JSONL parse (mirrors show-stats)' {
        It 'Read-DogfoodLog returns empty for a missing file (never throws)' {
            @(Read-DogfoodLog -LogPath (Join-Path $script:DfDir 'nope.jsonl')).Count | Should -Be 0
        }
        It 'Read-DogfoodLog parses valid lines and skips blank / malformed ones' {
            Write-DfLog -LogPath $script:DfLog -Entries @((New-DfEntry -Hash 'h-a'), (New-DfEntry -Hash 'h-b'))
            Add-Content -LiteralPath $script:DfLog -Value '' -Encoding ascii
            Add-Content -LiteralPath $script:DfLog -Value '{ not json' -Encoding ascii
            @(Read-DogfoodLog -LogPath $script:DfLog).Count | Should -Be 2
        }
        It 'Read-DogfoodAnnotations returns an empty hashtable for a missing file' {
            (Read-DogfoodAnnotations -AnnotationsPath (Join-Path $script:DfDir 'nope.jsonl')).Count | Should -Be 0
        }
        It 'Read-DogfoodAnnotations is last-write-wins per hash (append-only correction)' {
            Set-DogfoodVerdict -LogPath $script:DfLog -AnnotationsPath $script:DfAnn -Hash 'h-a' -Verdict 'noisy' | Out-Null
            Set-DogfoodVerdict -LogPath $script:DfLog -AnnotationsPath $script:DfAnn -Hash 'h-a' -Verdict 'false-positive' | Out-Null
            $ann = Read-DogfoodAnnotations -AnnotationsPath $script:DfAnn
            $ann['h-a'].verdict | Should -BeExactly 'false-positive'   # the later line wins
            @(Get-Content -LiteralPath $script:DfAnn).Count | Should -Be 2   # both kept (non-destructive)
        }
    }

    Context 'Get-DogfoodShapes -- collapse occurrences to distinct shapes by hash' {
        It 'groups by hash, counts occurrences, and keeps the first representative + order' {
            Write-DfLog -LogPath $script:DfLog -Entries @(
                (New-DfEntry -Hash 'h-x' -RuleId 'PSAvoidUsingCmdletAliases' -Snippet 'gci'),
                (New-DfEntry -Hash 'h-x' -RuleId 'PSAvoidUsingCmdletAliases' -Snippet 'gci'),
                (New-DfEntry -Hash 'h-x' -RuleId 'PSAvoidUsingCmdletAliases' -Snippet 'gci'),
                (New-DfEntry -Hash 'h-y' -RuleId 'PSUseApprovedVerbs' -Snippet 'function Frob-Z {'))
            $shapes = @(Get-DogfoodShapes -Records (Read-DogfoodLog -LogPath $script:DfLog))
            $shapes.Count | Should -Be 2
            $shapes[0].hash | Should -BeExactly 'h-x'      # first-seen order preserved
            $shapes[0].count | Should -Be 3                # all three occurrences counted
            $shapes[0].ruleId | Should -BeExactly 'PSAvoidUsingCmdletAliases'
            $shapes[1].count | Should -Be 1
        }
    }

    Context 'Get-DogfoodPendingShapes -- resumability' {
        It 'excludes shapes whose hash already carries a verdict' {
            Write-DfLog -LogPath $script:DfLog -Entries @((New-DfEntry -Hash 'h-a'), (New-DfEntry -Hash 'h-b'))
            Set-DogfoodVerdict -LogPath $script:DfLog -AnnotationsPath $script:DfAnn -Hash 'h-a' -Verdict 'useful' | Out-Null
            $shapes = Get-DogfoodShapes -Records (Read-DogfoodLog -LogPath $script:DfLog)
            $ann = Read-DogfoodAnnotations -AnnotationsPath $script:DfAnn
            $pending = @(Get-DogfoodPendingShapes -Shapes $shapes -Annotations $ann)
            $pending.Count | Should -Be 1
            $pending[0].hash | Should -BeExactly 'h-b'
        }
    }

    Context 'persistence model -- hash-keyed, sibling file, non-destructive' {
        It 'Get-DogfoodAnnotationsPath is annotations.jsonl beside the log' {
            # Portable base: a hardcoded C:\ literal makes PowerShell resolve a non-existent
            # C: PSDrive off-Windows (DriveNotFoundException) before the assertion runs, so
            # use $TestDrive -- a real per-platform temp dir -- and prove the same beside-the-
            # log derivation on all four CI legs (dispatch 000044).
            $dir = Join-Path $TestDrive 'dogfood'
            Get-DogfoodAnnotationsPath -LogPath (Join-Path $dir 'diagnostics.jsonl') |
                Should -BeExactly (Join-Path $dir 'annotations.jsonl')
        }
        It 'New-DogfoodAnnotation carries hash/ruleId/verdict/rationale/ts and honors a pinned timestamp' {
            $a = New-DogfoodAnnotation -Hash 'h-a' -Verdict 'noisy' -RuleId 'R' -Rationale 'why' -Now '2020-01-01T00:00:00Z'
            $a.hash | Should -BeExactly 'h-a'
            $a.verdict | Should -BeExactly 'noisy'
            $a.ruleId | Should -BeExactly 'R'
            $a.rationale | Should -BeExactly 'why'
            $a.ts | Should -BeExactly '2020-01-01T00:00:00Z'
        }
        It 'New-DogfoodAnnotation throws on an out-of-enum verdict' {
            { New-DogfoodAnnotation -Hash 'h' -Verdict 'bogus' } | Should -Throw
        }
        It 'Set-DogfoodVerdict writes, resolves the ruleId from the log, and is idempotent' {
            Write-DfLog -LogPath $script:DfLog -Entries @((New-DfEntry -Hash 'h-a' -RuleId 'PSUseApprovedVerbs'))
            (Set-DogfoodVerdict -LogPath $script:DfLog -AnnotationsPath $script:DfAnn -Hash 'h-a' -Verdict 'false-positive') | Should -BeExactly 'written'
            (Set-DogfoodVerdict -LogPath $script:DfLog -AnnotationsPath $script:DfAnn -Hash 'h-a' -Verdict 'false-positive') | Should -BeExactly 'unchanged'
            @(Get-Content -LiteralPath $script:DfAnn).Count | Should -Be 1   # idempotent: no duplicate line
            (Read-DogfoodAnnotations -AnnotationsPath $script:DfAnn)['h-a'].ruleId | Should -BeExactly 'PSUseApprovedVerbs'
        }
        It 'annotating NEVER mutates the diagnostics log -- byte-identical (non-destructive fence)' {
            # The load-bearing fence (analog of the 000039 byte-identity capture test): a verdict
            # is ADDED to a separate file; the capture evidence is immutable. Adversarial control:
            # make Set-DogfoodVerdict rewrite the log in place and this goes RED.
            Write-DfLog -LogPath $script:DfLog -Entries @((New-DfEntry -Hash 'h-a'), (New-DfEntry -Hash 'h-b'))
            $before = [System.IO.File]::ReadAllBytes($script:DfLog)
            Set-DogfoodVerdict -LogPath $script:DfLog -AnnotationsPath $script:DfAnn -Hash 'h-a' -Verdict 'useful' | Out-Null
            $after = [System.IO.File]::ReadAllBytes($script:DfLog)
            ([System.Convert]::ToBase64String($after)) | Should -BeExactly ([System.Convert]::ToBase64String($before))
        }
        It 'the annotation file never carries the snippet (only hash/ruleId/verdict/rationale/ts)' {
            Write-DfLog -LogPath $script:DfLog -Entries @((New-DfEntry -Hash 'h-a' -Snippet 'secret-source-token'))
            Set-DogfoodVerdict -LogPath $script:DfLog -AnnotationsPath $script:DfAnn -Hash 'h-a' -Verdict 'useful' | Out-Null
            (Get-Content -LiteralPath $script:DfAnn -Raw) | Should -Not -Match 'secret-source-token'
        }
    }

    Context 'Get-DogfoodSummary -- the ranked readout (occurrence-weighted)' {
        BeforeEach {
            Write-DfLog -LogPath $script:DfLog -Entries @(
                (New-DfEntry -Hash 'h-fp' -RuleId 'PSUseApprovedVerbs'),
                (New-DfEntry -Hash 'h-fp' -RuleId 'PSUseApprovedVerbs'),
                (New-DfEntry -Hash 'h-fp' -RuleId 'PSUseApprovedVerbs'),
                (New-DfEntry -Hash 'h-ok' -RuleId 'PSAvoidUsingCmdletAliases'))
        }
        It 'reports coverage, per-verdict shape/occurrence counts, and excludes useful from top rules' {
            Set-DogfoodVerdict -LogPath $script:DfLog -AnnotationsPath $script:DfAnn -Hash 'h-fp' -Verdict 'false-positive' | Out-Null
            Set-DogfoodVerdict -LogPath $script:DfLog -AnnotationsPath $script:DfAnn -Hash 'h-ok' -Verdict 'useful' | Out-Null
            $shapes = Get-DogfoodShapes -Records (Read-DogfoodLog -LogPath $script:DfLog)
            $ann = Read-DogfoodAnnotations -AnnotationsPath $script:DfAnn
            $sum = Get-DogfoodSummary -Shapes $shapes -Annotations $ann
            $sum.totalShapes | Should -Be 2
            $sum.totalOccurrences | Should -Be 4
            $sum.annotatedShapes | Should -Be 2
            $sum.coveragePct | Should -Be 100
            $sum.byVerdict['false-positive'].shapes | Should -Be 1
            $sum.byVerdict['false-positive'].occurrences | Should -Be 3      # occurrence-weighted
            $sum.byVerdict['useful'].occurrences | Should -Be 1
            # 'useful' is NOT actionable, so only the false-positive rule ranks.
            @($sum.topRules).Count | Should -Be 1
            $sum.topRules[0].ruleId | Should -BeExactly 'PSUseApprovedVerbs'
            $sum.topRules[0].occurrences | Should -Be 3
        }
        It 'an empty log summarizes cleanly (zero shapes, zero coverage)' {
            $sum = Get-DogfoodSummary -Shapes @() -Annotations @{}
            $sum.totalShapes | Should -Be 0
            $sum.coveragePct | Should -Be 0
        }
    }

    Context 'rendering -- snippet redaction is the source fence for sharing' {
        It 'Format-DogfoodSnippet masks to a length placeholder under -Redact' {
            (Format-DogfoodSnippet -Snippet 'gci -Recurse' -Redact) | Should -BeExactly '[redacted 12 chars]'
        }
        It 'Format-DogfoodSnippet returns the snippet verbatim without -Redact' {
            (Format-DogfoodSnippet -Snippet 'gci -Recurse') | Should -BeExactly 'gci -Recurse'
        }
        It 'Format-DogfoodSnippet renders an empty snippet as (no snippet)' {
            (Format-DogfoodSnippet -Snippet '') | Should -BeExactly '(no snippet)'
        }
        It 'Format-DogfoodShape redacts the snippet but still shows rule + hash' {
            # Round-trip through the log (JSON -> PSCustomObject) exactly as real usage does.
            Write-DfLog -LogPath $script:DfLog -Entries @((New-DfEntry -Hash 'h-a' -Snippet 'leak-me' -RuleId 'PSUseApprovedVerbs'))
            $shape = (Get-DogfoodShapes -Records (Read-DogfoodLog -LogPath $script:DfLog))[0]
            $out = Format-DogfoodShape -Shape $shape -Annotations @{} -Redact
            $out | Should -Not -Match 'leak-me'
            $out | Should -Match 'PSUseApprovedVerbs'
            $out | Should -Match 'h-a'
        }
    }
}

Describe 'Dogfood reader: source resolution + source split (dispatch 000088)' {
    # READER-ONLY hardening. Two additive changes, both provable without touching the hook
    # write-side (Get-DogfoodLogPath is byte-for-byte unchanged -- these exercise only the NEW
    # reader helpers): (1) the reader resolves the INSTALLED marketplace-cache log so a run from
    # the dev checkout stops seeing zero real captures; (2) a source-split dimension (canonical-
    # checkout / other-genuine / synthetic) lifted from the 000066/000084 inline path patterns.
    # Env is saved/cleared/restored per-It so cache discovery and the checkout resolver are
    # hermetic (no ambient CLAUDE_PLUGIN_ROOT / POWERSHELL_LSP_DOGFOOD_LOG bleeds in).
    BeforeAll {
        . (Join-Path $script:ScriptsDir 'review-dogfood.ps1')

        # Build a fake installed-cache log at
        # <root>/<marketplace>/powershell-lsp/<version>/dogfood/diagnostics.jsonl. Uses
        # [IO.Path]::Combine (PS 5.1 has no multi-segment Join-Path) with the platform separator,
        # so the tree is correct on all four CI legs. Returns the log path.
        function New-FakeCacheLog {
            param(
                [string] $CacheRoot,
                [string] $Version,
                [string] $Marketplace = 'claude-powershell-lsp',
                [string[]] $Lines = @('{"file":"C:\\proj\\a.ps1","hash":"h1","ruleId":"R"}')
            )
            $dir = [System.IO.Path]::Combine($CacheRoot, $Marketplace, 'powershell-lsp', $Version, 'dogfood')
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            $log = Join-Path $dir 'diagnostics.jsonl'
            Set-Content -LiteralPath $log -Value $Lines -Encoding ascii
            return $log
        }
        # One capture record in the shape Read-DogfoodLog yields (a PSCustomObject with file+hash).
        function New-Rec {
            param([string] $File, [string] $Hash = 'h1')
            return [pscustomobject]@{ file = $File; hash = $Hash }
        }
    }

    BeforeEach {
        $script:PrevPluginRoot = $env:CLAUDE_PLUGIN_ROOT
        $script:PrevDfLog = $env:POWERSHELL_LSP_DOGFOOD_LOG
        Remove-Item -LiteralPath 'Env:CLAUDE_PLUGIN_ROOT' -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath 'Env:POWERSHELL_LSP_DOGFOOD_LOG' -ErrorAction SilentlyContinue
        $script:SrcDir = Join-Path $TestDrive ('src-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $script:SrcDir | Out-Null
    }
    AfterEach {
        if ($null -eq $script:PrevPluginRoot) { Remove-Item -LiteralPath 'Env:CLAUDE_PLUGIN_ROOT' -ErrorAction SilentlyContinue }
        else { $env:CLAUDE_PLUGIN_ROOT = $script:PrevPluginRoot }
        if ($null -eq $script:PrevDfLog) { Remove-Item -LiteralPath 'Env:POWERSHELL_LSP_DOGFOOD_LOG' -ErrorAction SilentlyContinue }
        else { $env:POWERSHELL_LSP_DOGFOOD_LOG = $script:PrevDfLog }
    }

    Context 'Get-DogfoodSourceBucket -- lifted 000066/000084 patterns, conservative default' {
        It 'a canonical-checkout path classifies as canonical-checkout' {
            (Get-DogfoodSourceBucket -File 'C:\Users\m\projects\work\nortam\claude-powershell-lsp\scripts\a.ps1') |
                Should -BeExactly 'canonical-checkout'
        }
        It 'is separator-agnostic -- a forward-slash canonical path also classifies as canonical-checkout' {
            # The '?' single-char wildcard matches '/' as well as '\', so a path built with the
            # POSIX separator (as the CI legs do via Join-Path) still classifies correctly.
            (Get-DogfoodSourceBucket -File '/home/runner/work/nortam/claude-powershell-lsp/scripts/a.ps1') |
                Should -BeExactly 'canonical-checkout'
        }
        It 'a Temp\claude harness path classifies as synthetic' {
            (Get-DogfoodSourceBucket -File 'C:\Users\m\AppData\Local\Temp\claude\sess\scratchpad\a.ps1') |
                Should -BeExactly 'synthetic'
        }
        It 'a psls-pester-data fixture path classifies as synthetic' {
            (Get-DogfoodSourceBucket -File 'C:\x\psls-pester-data\fixture.ps1') | Should -BeExactly 'synthetic'
        }
        It 'synthetic is checked FIRST -- a Temp\claude path embedding the mangled repo slug is synthetic, NOT canonical' {
            # The harness worktree dir name embeds the slug ...nortam-claude-powershell-lsp..., which
            # the canonical pattern would otherwise match. Ordering (synthetic before canonical) is
            # load-bearing. Adversarial control: reorder the checks and this goes RED.
            $slugTemp = 'C:\Users\m\AppData\Local\Temp\claude\C--Users-m-projects-work-nortam-claude-powershell-lsp\s\a.ps1'
            (Get-DogfoodSourceBucket -File $slugTemp) | Should -BeExactly 'synthetic'
        }
        It 'a linked worktree path (pls-wt-000059) classifies as other-genuine, NOT canonical' {
            (Get-DogfoodSourceBucket -File 'C:\Users\m\projects\work\nortam\pls-wt-000059\scripts\lsp-client.ps1') |
                Should -BeExactly 'other-genuine'
        }
        It 'the hub demo recording (demo-take.ps1) classifies as other-genuine, NOT canonical' {
            (Get-DogfoodSourceBucket -File 'C:\Users\m\projects\work\nortam\strategic-dispatch\projects\powershell-lsp\demo-take.ps1') |
                Should -BeExactly 'other-genuine'
        }
        It 'an empty path classifies conservatively as other-genuine (never canonical)' {
            (Get-DogfoodSourceBucket -File '') | Should -BeExactly 'other-genuine'
        }
    }

    Context 'Get-DogfoodSourceSplit -- per-record occurrences + distinct shapes' {
        It 'the known baseline else-bucket entries land as other-genuine (demo-take.ps1 x3 + pls-wt-000059)' {
            # Mirrors the real cache log's non-canonical tail (per 000085): 3 hub-demo records and 1
            # worktree record must bucket as other-genuine, with the canonical edits as canonical-
            # checkout. This is the acceptance's named guard.
            $canon = 'C:\Users\m\projects\work\nortam\claude-powershell-lsp\scripts\show-stats.ps1'
            $demo = 'C:\Users\m\projects\work\nortam\strategic-dispatch\projects\powershell-lsp\demo-take.ps1'
            $wtree = 'C:\Users\m\projects\work\nortam\pls-wt-000059\scripts\lsp-client.ps1'
            $records = @(
                (New-Rec -File $canon -Hash 'c1'), (New-Rec -File $canon -Hash 'c2'),
                (New-Rec -File $demo -Hash 'd1'), (New-Rec -File $demo -Hash 'd1'), (New-Rec -File $demo -Hash 'd2'),
                (New-Rec -File $wtree -Hash 'w1'))
            $split = Get-DogfoodSourceSplit -Records $records
            $split['canonical-checkout'].occurrences | Should -Be 2
            $split['other-genuine'].occurrences | Should -Be 4      # 3 demo + 1 worktree
            $split['synthetic'].occurrences | Should -Be 0
            $split['other-genuine'].shapes | Should -Be 3           # d1, d2, w1 (d1 repeats)
        }
        It 'classifies PER RECORD, not per shape -- one hash across two files counts in both buckets' {
            # hash collision across a canonical and a synthetic file: rule + line-shape can match in
            # two files. A per-shape split would mis-attribute; per-record keeps each occurrence in
            # its own file's bucket.
            $records = @(
                (New-Rec -File 'C:\Users\m\projects\work\nortam\claude-powershell-lsp\a.ps1' -Hash 'same'),
                (New-Rec -File 'C:\Users\m\AppData\Local\Temp\claude\s\a.ps1' -Hash 'same'))
            $split = Get-DogfoodSourceSplit -Records $records
            $split['canonical-checkout'].occurrences | Should -Be 1
            $split['synthetic'].occurrences | Should -Be 1
            $split['canonical-checkout'].shapes | Should -Be 1
            $split['synthetic'].shapes | Should -Be 1
        }
        It 'all three buckets are present even when empty (fixed display order)' {
            $split = Get-DogfoodSourceSplit -Records @()
            @($split.Keys) | Should -Be @('canonical-checkout', 'other-genuine', 'synthetic')
            $split['synthetic'].occurrences | Should -Be 0
        }
    }

    Context 'cache-path resolution -- discovered, never hardcoded' {
        It 'Select-DogfoodCacheVersion picks the highest semantic version' {
            $cands = @(
                [pscustomobject]@{ Version = '1.9.0'; Path = 'p-1-9-0' },
                [pscustomobject]@{ Version = '1.18.1'; Path = 'p-1-18-1' },
                [pscustomobject]@{ Version = '1.10.0'; Path = 'p-1-10-0' })
            # semantic (not lexical) ordering: 1.18.1 > 1.10.0 > 1.9.0.
            (Select-DogfoodCacheVersion -Candidates $cands) | Should -BeExactly 'p-1-18-1'
        }
        It 'Select-DogfoodCacheVersion returns empty for no candidates' {
            (Select-DogfoodCacheVersion -Candidates @()) | Should -BeExactly ''
        }
        It 'Get-DogfoodCacheLogPath rule 1: CLAUDE_PLUGIN_ROOT / -PluginRoot points straight at the log' {
            $root = Join-Path $script:SrcDir 'installed'
            $dir = Join-Path $root 'dogfood'
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            $log = Join-Path $dir 'diagnostics.jsonl'
            Set-Content -LiteralPath $log -Value '{"file":"x","hash":"h"}' -Encoding ascii
            (Get-DogfoodCacheLogPath -PluginRoot $root) | Should -BeExactly $log
        }
        It 'Get-DogfoodCacheLogPath rule 2: discovers the versioned cache log under the cache tree' {
            $cache = Join-Path $script:SrcDir 'cache'
            $log = New-FakeCacheLog -CacheRoot $cache -Version '1.18.1'
            (Get-DogfoodCacheLogPath -CacheRoot $cache) | Should -BeExactly $log
        }
        It 'NO HARDCODED VERSION: an arbitrary future version resolves, and the highest wins over 1.18.1' {
            # The load-bearing proof for the acceptance: resolution is independent of any embedded
            # version segment. A tree whose ONLY version is 9.9.9 resolves; add 1.18.1 and the
            # discovery still returns the highest (2.0.0), never a baked-in 1.18.1.
            $cache = Join-Path $script:SrcDir 'cache-arbitrary'
            $only = New-FakeCacheLog -CacheRoot $cache -Version '9.9.9'
            (Get-DogfoodCacheLogPath -CacheRoot $cache) | Should -BeExactly $only

            $cache2 = Join-Path $script:SrcDir 'cache-multi'
            New-FakeCacheLog -CacheRoot $cache2 -Version '1.18.1' | Out-Null
            $newest = New-FakeCacheLog -CacheRoot $cache2 -Version '2.0.0'
            (Get-DogfoodCacheLogPath -CacheRoot $cache2) | Should -BeExactly $newest
        }
        It 'Get-DogfoodCacheLogPath returns empty when no cache log exists' {
            $empty = Join-Path $script:SrcDir 'no-cache'
            New-Item -ItemType Directory -Force -Path $empty | Out-Null
            (Get-DogfoodCacheLogPath -CacheRoot $empty) | Should -BeExactly ''
        }
        It 'the reader source carries no hardcoded 1.18.1 version literal (regression guard)' {
            # 000084 warned the cache path must not bake in the observed 1.18.1. Adversarial control:
            # hardcode 1.18.1 in the resolver and this goes RED.
            $scriptPath = Join-Path $script:ScriptsDir 'review-dogfood.ps1'
            (Get-Content -LiteralPath $scriptPath -Raw) | Should -Not -Match '1\.18\.1'
        }
    }

    Context 'Test-DogfoodLogNonEmpty' {
        It 'is false for a missing file' {
            (Test-DogfoodLogNonEmpty -LogPath (Join-Path $script:SrcDir 'nope.jsonl')) | Should -BeFalse
        }
        It 'is false for an empty or whitespace-only file' {
            $e = Join-Path $script:SrcDir 'empty.jsonl'; Set-Content -LiteralPath $e -Value '' -Encoding ascii
            (Test-DogfoodLogNonEmpty -LogPath $e) | Should -BeFalse
        }
        It 'is true once the file has a non-blank line' {
            $f = Join-Path $script:SrcDir 'one.jsonl'; Set-Content -LiteralPath $f -Value '{"hash":"h"}' -Encoding ascii
            (Test-DogfoodLogNonEmpty -LogPath $f) | Should -BeTrue
        }
    }

    Context 'Resolve-DogfoodLogSource -- -Source semantics + effective label' {
        It '-Path wins over -Source and is honored verbatim' {
            $r = Resolve-DogfoodLogSource -Source 'cache' -Path 'C:\explicit\df.jsonl'
            $r.LogPath | Should -BeExactly 'C:\explicit\df.jsonl'
            $r.Effective | Should -BeExactly 'path'
        }
        It 'checkout reuses the UNCHANGED write-side resolver (Get-DogfoodLogPath) READ-ONLY' {
            # The read-side/write-side boundary: the reader's checkout source is exactly the hook's
            # own resolver, driven here via its documented override seam.
            $env:POWERSHELL_LSP_DOGFOOD_LOG = 'C:\co\df.jsonl'
            $r = Resolve-DogfoodLogSource -Source 'checkout'
            $r.LogPath | Should -BeExactly (Get-DogfoodLogPath)
            $r.LogPath | Should -BeExactly 'C:\co\df.jsonl'
            $r.Effective | Should -BeExactly 'checkout'
        }
        It 'cache resolves the discovered cache log' {
            $cache = Join-Path $script:SrcDir 'cache'
            $log = New-FakeCacheLog -CacheRoot $cache -Version '1.18.1'
            $r = Resolve-DogfoodLogSource -Source 'cache' -CacheRoot $cache
            $r.LogPath | Should -BeExactly $log
            $r.Effective | Should -BeExactly 'cache'
        }
        It 'auto prefers a NON-EMPTY cache log (Effective auto->cache)' {
            $cache = Join-Path $script:SrcDir 'cache'
            $log = New-FakeCacheLog -CacheRoot $cache -Version '1.18.1' -Lines @('{"file":"x","hash":"h"}')
            $env:POWERSHELL_LSP_DOGFOOD_LOG = 'C:\co\df.jsonl'   # checkout would resolve here
            $r = Resolve-DogfoodLogSource -Source 'auto' -CacheRoot $cache
            $r.LogPath | Should -BeExactly $log
            $r.Effective | Should -BeExactly 'auto->cache'
        }
        It 'auto falls back to checkout when the cache log is absent/empty (Effective auto->checkout)' {
            $empty = Join-Path $script:SrcDir 'no-cache'
            New-Item -ItemType Directory -Force -Path $empty | Out-Null
            $env:POWERSHELL_LSP_DOGFOOD_LOG = 'C:\co\df.jsonl'
            $r = Resolve-DogfoodLogSource -Source 'auto' -CacheRoot $empty
            $r.LogPath | Should -BeExactly 'C:\co\df.jsonl'
            $r.Effective | Should -BeExactly 'auto->checkout'
        }
    }

    Context 'Resolve-DogfoodPaths -- annotations beside the resolved log + Source field' {
        It 'surfaces the effective Source and puts annotations beside the resolved log' {
            $log = Join-Path $script:SrcDir 'diagnostics.jsonl'
            $r = Resolve-DogfoodPaths -Path $log
            $r.LogPath | Should -BeExactly $log
            $r.Source | Should -BeExactly 'path'
            $r.AnnotationsPath | Should -BeExactly (Join-Path $script:SrcDir 'annotations.jsonl')
        }
        It 'honors an explicit -AnnotationsPath' {
            $log = Join-Path $script:SrcDir 'diagnostics.jsonl'
            $ann = Join-Path $script:SrcDir 'custom-ann.jsonl'
            (Resolve-DogfoodPaths -Path $log -AnnotationsPath $ann).AnnotationsPath | Should -BeExactly $ann
        }
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

Describe 'Resolve-PssaSettingsPath -- opt-in ruleset=base fallback + four precedence levels (dispatch 000087)' {
    # The 'ruleset' knob selects the fallback ONLY when no explicit override and no repo-local
    # PSScriptAnalyzerSettings.psd1 resolve first. These prove all four precedence levels the
    # dispatch requires, at the resolver -- the single place the fallback is decided:
    #   L1 default-unchanged  : pses-default (and the default) -> '' (PSES 15-rule fallback).
    #   L2 base-broadens      : ruleset=base, no repo-local, no override -> the shipped base.
    #   L3 repo-local-wins    : a discovered PSScriptAnalyzerSettings.psd1 wins over the base.
    #   L4 settingsPath-wins  : an explicit absolute override wins over base AND repo-local.
    BeforeAll {
        $script:R87Root = Join-Path $TestDrive 'proj87'
        $script:R87Sub = Join-Path $script:R87Root 'src'
        New-Item -ItemType Directory -Force -Path $script:R87Sub | Out-Null
        $script:R87Edit = Join-Path $script:R87Sub 'edited.ps1'
        Set-Content -LiteralPath $script:R87Edit -Value 'Get-Process' -Encoding ascii
        $script:R87RepoCfg = Join-Path $script:R87Root 'PSScriptAnalyzerSettings.psd1'
        $script:BaseShipped = Get-PluginBaseSettingsPath
    }
    AfterEach {
        Remove-Item -LiteralPath $script:R87RepoCfg -Force -ErrorAction SilentlyContinue
    }

    It 'the shipped base ruleset resolves from the plugin tree (Get-PluginBaseSettingsPath)' {
        $script:BaseShipped | Should -Not -BeNullOrEmpty
        [System.IO.Path]::IsPathRooted($script:BaseShipped) | Should -BeTrue
        (Split-Path -Leaf $script:BaseShipped) | Should -BeExactly 'base.psd1'
        Test-Path -LiteralPath $script:BaseShipped -PathType Leaf | Should -BeTrue
    }
    It 'L1 default-unchanged: pses-default (and the omitted default) returns empty -- the PSES 15-rule path' {
        # Adversarial control: this is the byte-for-byte pre-000087 behavior; if the fallback
        # ever returned the base for pses-default, the default surface would broaden -> RED.
        Resolve-PssaSettingsPath -EditedFilePath $script:R87Edit -ProjectRoot $script:R87Root | Should -BeExactly ''
        Resolve-PssaSettingsPath -EditedFilePath $script:R87Edit -ProjectRoot $script:R87Root -Ruleset 'pses-default' | Should -BeExactly ''
    }
    It 'L2 base-broadens: ruleset=base with no repo-local and no override resolves the shipped base' {
        Resolve-PssaSettingsPath -EditedFilePath $script:R87Edit -ProjectRoot $script:R87Root -Ruleset 'base' |
            Should -BeExactly $script:BaseShipped
    }
    It 'L3 repo-local-wins: a discovered PSScriptAnalyzerSettings.psd1 wins over the base' {
        Set-Content -LiteralPath $script:R87RepoCfg -Value '@{}' -Encoding ascii
        $r = Resolve-PssaSettingsPath -EditedFilePath $script:R87Edit -ProjectRoot $script:R87Root -Ruleset 'base'
        $r | Should -BeExactly ([System.IO.Path]::GetFullPath($script:R87RepoCfg))
        $r | Should -Not -Be $script:BaseShipped
    }
    It 'L4 settingsPath-wins: an explicit absolute override wins over the base AND a repo-local file' {
        Set-Content -LiteralPath $script:R87RepoCfg -Value '@{}' -Encoding ascii
        $ovr = Join-Path (Join-Path $TestDrive 'elsewhere87') 'custom.psd1'
        Resolve-PssaSettingsPath -EditedFilePath $script:R87Edit -ProjectRoot $script:R87Root -Override $ovr -Ruleset 'base' |
            Should -BeExactly ([System.IO.Path]::GetFullPath($ovr))
    }
    It 'an unknown ruleset value degrades to the PSES default (no base, no throw)' {
        Resolve-PssaSettingsPath -EditedFilePath $script:R87Edit -ProjectRoot $script:R87Root -Ruleset 'nonsense' | Should -BeExactly ''
    }
}

Describe 'base.psd1 is NOT auto-discovered as a repo-local settings file (dispatch 000087 guard)' {
    # The shipped base ruleset is named base.psd1, NOT PSScriptAnalyzerSettings.psd1, so the
    # repo-local discovery walk-up (which matches only that exact name) never selects it --
    # shipping it inside the plugin tree cannot change the plugin's own repo lint surface.
    It 'a file literally named base.psd1 in the project tree is ignored by discovery (pses-default -> empty)' {
        $root = Join-Path $TestDrive 'guard1'
        $sub = Join-Path $root 'src'; New-Item -ItemType Directory -Force -Path $sub | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'base.psd1') -Value '@{}' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $sub 'base.psd1') -Value '@{}' -Encoding ascii
        $edit = Join-Path $sub 'x.ps1'; Set-Content -LiteralPath $edit -Value 'Get-Process' -Encoding ascii
        Resolve-PssaSettingsPath -EditedFilePath $edit -ProjectRoot $root | Should -BeExactly ''
    }
    It 'under ruleset=base, a local base.psd1 in the tree is NOT selected as repo-local -- the SHIPPED base is used' {
        $root = Join-Path $TestDrive 'guard2'
        $sub = Join-Path $root 'src'; New-Item -ItemType Directory -Force -Path $sub | Out-Null
        $localBase = Join-Path $sub 'base.psd1'
        Set-Content -LiteralPath $localBase -Value '@{}' -Encoding ascii
        $edit = Join-Path $sub 'x.ps1'; Set-Content -LiteralPath $edit -Value 'Get-Process' -Encoding ascii
        $r = Resolve-PssaSettingsPath -EditedFilePath $edit -ProjectRoot $root -Ruleset 'base'
        $r | Should -BeExactly (Get-PluginBaseSettingsPath)
        $r | Should -Not -Be ([System.IO.Path]::GetFullPath($localBase))
    }
}

Describe 'rulesets/base.psd1 -- enumerated, deterministic base ruleset (dispatch 000087; curated 000092)' {
    # The base ENUMERATES its rules explicitly (not IncludeDefaultRules=$true) so the surfaced
    # set is pin-independent and a pin bump is a deliberate regeneration. These guard the
    # shipped file's content directly (parse only -- no PSScriptAnalyzer needed, so they run on
    # every leg): the security rules + Write-Host are in, the formatting/compat rules are out, the
    # three survey-evidenced noisy rules (dispatch 000092) are out, no duplicates.
    BeforeAll {
        $script:BaseFile = Join-Path $script:PluginRoot 'rulesets/base.psd1'
        $script:BaseData = Import-PowerShellDataFile -LiteralPath $script:BaseFile
        $script:BaseRules = @($script:BaseData['IncludeRules'])
    }
    It 'exists and parses as a settings hashtable with a non-empty IncludeRules array' {
        Test-Path -LiteralPath $script:BaseFile -PathType Leaf | Should -BeTrue
        $script:BaseData.ContainsKey('IncludeRules') | Should -BeTrue
        $script:BaseRules.Count | Should -BeGreaterThan 0
    }
    It 'enumerates explicitly -- NOT a bare IncludeDefaultRules (the determinism property)' {
        # Adversarial control: switch base.psd1 to IncludeDefaultRules=$true and this goes RED.
        $script:BaseData.ContainsKey('IncludeDefaultRules') | Should -BeFalse
    }
    It 'ships exactly the derived rule count at the current pin (54 at PSScriptAnalyzer 1.25.0)' {
        # Pin-coupled by design: a pinned-analyzer bump regenerates the base
        # (scripts/regen-base-ruleset.ps1) and updates this count in the same reviewed diff.
        # 54 = 58 default-on minus 1 default-on compat rule (PSUseCompatibleCmdlets) minus the
        # 3 survey-evidenced exclusions (dispatch 000092; down from 57 at 000087).
        $script:BaseRules.Count | Should -Be 54
    }
    It 'includes the three Error-severity security rules and a Write-Host-class rule (RETAINED through 000092)' {
        # These are load-bearing signal and MUST survive the 000092 exclude curation.
        foreach ($r in @(
                'PSAvoidUsingComputerNameHardcoded',
                'PSAvoidUsingConvertToSecureStringWithPlainText',
                'PSAvoidUsingUsernameAndPasswordParams',
                'PSAvoidUsingWriteHost')) {
            $script:BaseRules | Should -Contain $r
        }
    }
    It 'EXCLUDES the three survey-evidenced noisy rules (dispatch 000092, from the 000091 quality wave)' {
        # Removed as measured noise: PSReviewUnusedParameter (~90% FP on the param-block +
        # nested-functions shape), PSUseSingularNouns (0 true-issues; intentional plurals),
        # PSUseShouldProcessForStateChangingFunctions (verb-triggered FP on clean New-*/Set-*
        # builders). All three are base-only (not in the PSES 15-rule allow-list), so their
        # removal tightens the opt-in base surface alone and leaves pses-default unchanged.
        foreach ($r in @(
                'PSReviewUnusedParameter',
                'PSUseSingularNouns',
                'PSUseShouldProcessForStateChangingFunctions')) {
            $script:BaseRules | Should -Not -Contain $r
        }
    }
    It 'EXCLUDES the formatting and compatibility rules (Phase 2 item 2, not this base)' {
        foreach ($r in @(
                'PSPlaceOpenBrace', 'PSPlaceCloseBrace', 'PSUseConsistentIndentation',
                'PSUseConsistentWhitespace', 'PSAlignAssignmentStatement', 'PSUseCorrectCasing',
                'PSAvoidUsingDoubleQuotesForConstantString', 'PSAvoidSemicolonsAsLineTerminators',
                'PSAvoidLongLines',
                'PSUseCompatibleCmdlets', 'PSUseCompatibleCommands', 'PSUseCompatibleSyntax', 'PSUseCompatibleTypes')) {
            $script:BaseRules | Should -Not -Contain $r
        }
    }
    It 'has no duplicate entries and every name is a PS-prefixed rule code' {
        (@($script:BaseRules | Sort-Object -Unique)).Count | Should -Be $script:BaseRules.Count
        foreach ($r in $script:BaseRules) { $r | Should -Match '^PS' }
    }
}

# ===========================================================================
# Rule rationales (dispatch 000121, I0.1 slice-1)
# ===========================================================================

Describe 'rulesets/rule-rationales.psd1 -- shipped table invariants (dispatch 000121)' {
    # OFFLINE, parse-only: no PSScriptAnalyzer, no daemon, no network, so this runs on every leg.
    # It pins the table's SHAPE and its coupling to the two things it derives over -- the PSSA pin
    # in scripts/ensure-pssa.ps1 and the enumerated rulesets/base.psd1 surface. A pin bump or a
    # base-ruleset edit therefore goes RED here until the table is regenerated in the same reviewed
    # diff. The full text-level derivation match lives in the -Check Describe below.
    BeforeAll {
        $script:RatFile = Join-Path $script:PluginRoot 'rulesets/rule-rationales.psd1'
        $script:RatData = Import-PowerShellDataFile -LiteralPath $script:RatFile
        $script:RatEntries = $script:RatData['entries']
        $script:RatOwned = @($script:RatData['owned'])
        $script:RatBase = @((Import-PowerShellDataFile -LiteralPath (Join-Path $script:PluginRoot 'rulesets/base.psd1'))['IncludeRules'])
    }
    It 'exists and parses as a v1 table with entries, owned, pin and cap' {
        Test-Path -LiteralPath $script:RatFile -PathType Leaf | Should -BeTrue
        $script:RatData['schema'] | Should -BeExactly 'rule-rationales/v1'
        $script:RatEntries.Count | Should -BeGreaterThan 0
        $script:RatOwned.Count | Should -BeGreaterThan 0
    }
    It 'is PIN-COUPLED: pssa_version equals the pin in scripts/ensure-pssa.ps1' {
        # The load-bearing coupling. Bump $PssaVersion without regenerating and this goes RED.
        # Adversarial control: change pssa_version in the shipped table and this goes RED.
        $pin = Get-PinnedPssaVersion
        $pin | Should -Not -BeNullOrEmpty
        [string]$script:RatData['pssa_version'] | Should -BeExactly $pin
    }
    It 'covers the base ruleset surface EXACTLY: entries = base-54 PSSA rules + the owned finders' {
        $pssaKeys = @($script:RatEntries.Keys | Where-Object { $script:RatOwned -notcontains $_ } | Sort-Object)
        $baseSorted = @($script:RatBase | Sort-Object)
        ($pssaKeys -join ',') | Should -BeExactly ($baseSorted -join ',')
        [int]$script:RatData['pssa_count'] | Should -Be $baseSorted.Count
        [int]$script:RatData['owned_count'] | Should -Be $script:RatOwned.Count
        $script:RatEntries.Count | Should -Be ($baseSorted.Count + $script:RatOwned.Count)
    }
    It 'hand-authors an entry for each of the 4 plugin-owned finders, keyed by the EMITTED ruleId' {
        # NOT the finder FUNCTION names: Find-ModuleAwareness emits code 'ModuleNotInstalled', and
        # the runtime lookup keys on the diagnostic `code`. An entry keyed 'ModuleAwareness' would
        # silently never match. Adversarial control: rename any key here and this goes RED.
        foreach ($c in @('BashIsm', 'PS7OnlySyntax', 'NonAsciiChar', 'ModuleNotInstalled')) {
            $script:RatOwned | Should -Contain $c
            [string]$script:RatEntries[$c] | Should -Not -BeNullOrEmpty
        }
    }
    It 'every rationale is non-empty, within the declared cap, and never ends mid-word' {
        $cap = [int]$script:RatData['max_length']
        $cap | Should -BeGreaterThan 0
        foreach ($k in @($script:RatEntries.Keys)) {
            $v = [string]$script:RatEntries[$k]
            $v | Should -Not -BeNullOrEmpty
            $v.Length | Should -BeLessOrEqual $cap
            # A truncated rationale ends '...' preceded by a whole word, never a bare fragment.
            if ($v.EndsWith('...')) { $v | Should -Match '\w\.\.\.$' }
        }
    }
    It 'every rationale is pure printable ASCII (the PS 5.1 no-BOM mojibake trap)' {
        # Collect offenders then assert ONCE: a per-character Should is ~17k assertions and
        # dominates the unit suite's runtime. Adversarial control: put an em-dash in any entry.
        $bad = @()
        foreach ($k in @($script:RatEntries.Keys)) {
            foreach ($ch in ([string]$script:RatEntries[$k]).ToCharArray()) {
                if ([int]$ch -lt 32 -or [int]$ch -gt 126) { $bad += ('{0}: U+{1:X4}' -f $k, [int]$ch) }
            }
        }
        ($bad -join '; ') | Should -BeExactly ''
    }
    It 'the shipped file itself is no-BOM UTF-8 with LF endings and no non-ASCII byte' {
        $bytes = [System.IO.File]::ReadAllBytes($script:RatFile)
        $bytes.Length | Should -BeGreaterThan 0
        # no UTF-8 BOM
        ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
        @($bytes | Where-Object { $_ -eq 0x0D }).Count | Should -Be 0    # no CR -> LF only
        @($bytes | Where-Object { $_ -gt 0x7E }).Count | Should -Be 0    # no non-ASCII
    }
}

Describe 'Import-RuleRationales / Get-RationaleForCode -- runtime lookup + per-rule dedup (dispatch 000121)' {
    # The rendering seam, PURE and offline. Adversarial control: drop the $Rendered.Add() guard in
    # Get-RationaleForCode and the 'renders once per distinct rule' assertion goes RED.
    BeforeAll {
        $script:RatTable = Import-RuleRationales
    }
    It 'loads the shipped table keyed by rule code' {
        $script:RatTable.Count | Should -BeGreaterThan 0
        $script:RatTable.ContainsKey('PSAvoidUsingWriteHost') | Should -BeTrue
        $script:RatTable.ContainsKey('BashIsm') | Should -BeTrue
    }
    It 'renders a rule rationale ONCE per file, however many times the rule fires (dedup per rule)' {
        $rendered = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)
        $first = Get-RationaleForCode -Code 'PSUseApprovedVerbs' -Table $script:RatTable -Rendered $rendered
        $second = Get-RationaleForCode -Code 'PSUseApprovedVerbs' -Table $script:RatTable -Rendered $rendered
        $third = Get-RationaleForCode -Code 'PSUseApprovedVerbs' -Table $script:RatTable -Rendered $rendered
        $first | Should -Not -BeNullOrEmpty
        $second | Should -BeExactly ''
        $third | Should -BeExactly ''
    }
    It 'a DIFFERENT rule in the same file still renders its own rationale' {
        $rendered = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)
        (Get-RationaleForCode -Code 'PSUseApprovedVerbs' -Table $script:RatTable -Rendered $rendered) | Should -Not -BeNullOrEmpty
        (Get-RationaleForCode -Code 'PSAvoidUsingWriteHost' -Table $script:RatTable -Rendered $rendered) | Should -Not -BeNullOrEmpty
    }
    It 'DEGRADES GRACEFULLY: a code with no table entry yields no rationale line, never a throw' {
        $rendered = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)
        # ManifestConsistency is a REAL plugin-owned code with no hand-authored entry (see the
        # 000121 outbox): it must surface its finding with no rationale, never fabricate one.
        (Get-RationaleForCode -Code 'ManifestConsistency' -Table $script:RatTable -Rendered $rendered) | Should -BeExactly ''
        (Get-RationaleForCode -Code 'PSTotallyMadeUpRule' -Table $script:RatTable -Rendered $rendered) | Should -BeExactly ''
    }
    It 'a parser finding (empty or 0 code) never carries a rationale' {
        $rendered = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)
        (Get-RationaleForCode -Code '' -Table $script:RatTable -Rendered $rendered) | Should -BeExactly ''
        (Get-RationaleForCode -Code '0' -Table $script:RatTable -Rendered $rendered) | Should -BeExactly ''
    }
    It 'an EMPTY table degrades to no rationale lines at all (absent/unparseable file)' {
        $rendered = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)
        (Get-RationaleForCode -Code 'PSUseApprovedVerbs' -Table @{} -Rendered $rendered) | Should -BeExactly ''
    }
    It 'a whole-file render pass emits one rationale per distinct rule, in first-appearance order' {
        # Drives the exact sequence lsp-client.ps1's render loop drives: one $Rendered set for the
        # file, one Get-RationaleForCode call per finding, in render order.
        $records = @(
            [pscustomobject]@{ code = 'PSAvoidUsingWriteHost' }
            [pscustomobject]@{ code = 'PSUseApprovedVerbs' }
            [pscustomobject]@{ code = 'PSAvoidUsingWriteHost' }   # repeat -> no second line
            [pscustomobject]@{ code = 'ManifestConsistency' }     # owned, no entry -> degrade
            [pscustomobject]@{ code = '' }                        # parser -> skipped
        )
        $rendered = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)
        $emitted = @()
        foreach ($r in $records) {
            $why = Get-RationaleForCode -Code ([string]$r.code) -Table $script:RatTable -Rendered $rendered
            if (-not [string]::IsNullOrWhiteSpace($why)) { $emitted += [string]$r.code }
        }
        $emitted.Count | Should -Be 2
        $emitted[0] | Should -BeExactly 'PSAvoidUsingWriteHost'
        $emitted[1] | Should -BeExactly 'PSUseApprovedVerbs'
    }
}

Describe 'regen-rule-rationales.ps1 -Check -- the shipped table matches the derivation at the pin (dispatch 000121)' {
    # The pin-coupled DERIVATION guard (the 000087 regen -Check shape). Vendors the pinned
    # PSScriptAnalyzer through the plugin's own ensure-pssa.ps1 -- the SAME BeforeAll bootstrap the
    # Corpus/Integration suites use -- then re-derives the whole table and diffs it against the
    # shipped file. Proven RED in-session: perturbing one rationale text, and dropping one owned
    # entry, each produced exit 1 with a precise diff; restoring produced exit 0 and the identical
    # SHA-256. So the shipped table can never drift silently from the pin.
    BeforeAll {
        & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:ScriptsDir 'ensure-pssa.ps1') 2>&1 | Out-Null
        $script:RegenScript = Join-Path $script:ScriptsDir 'regen-rule-rationales.ps1'
    }
    It 'the regen script ships and carries a -Check switch' {
        Test-Path -LiteralPath $script:RegenScript -PathType Leaf | Should -BeTrue
        (Get-Content -Raw -LiteralPath $script:RegenScript) | Should -Match '\[switch\]\s*\$Check'
    }
    It '-Check exits 0 against the shipped table (derived == shipped, offline at the pin)' {
        $out = & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $script:RegenScript -Check 2>&1
        $code = $LASTEXITCODE
        if ($code -ne 0) { Write-Host ($out | Out-String) }
        $code | Should -Be 0
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
    It 'unavailable (dispatch 000028): the GENERALIZED prose covers BOTH causes AND lands PERMANENCE, distinct from the transient incomplete' {
        # 000028 widened 'unavailable' from install-only to ALSO cover "present but failed to start"
        # (the bundle-present init failure 000024 had left as a silent fail-fast). The token SET is
        # unchanged (still 4) -- only the PROSE generalizes (a PATCH-level refinement per CONTRACT.md).
        # It MUST land PERMANENT-this-session so a user never reads it as the TRANSIENT 'incomplete'
        # ("the next edit will be checked"). Adversarial control: drop the permanence clause from the
        # banner and this goes RED.
        $u = Get-DiagnosticsStatusBanner 'unavailable' 'C:\x\foo.ps1'
        $u | Should -Match 'could not start'                 # one wording for install-missing OR present-but-failed
        $u | Should -Match 'failed to start'                 # the present-but-failed cause (sub-case B)
        $u | Should -Match 'whole session'                   # PERMANENT this session, not a per-edit retry
        $u | Should -Match 'restarted'                       # remediation: fix + restart (not "retry")
        $u | Should -Not -Match 'analysis did not complete'  # must NOT borrow the transient incomplete signature
        # And the transient incomplete must NOT accidentally claim permanence -- the two stay distinct.
        (Get-DiagnosticsStatusBanner 'incomplete' 'C:\x\foo.ps1') | Should -Not -Match 'whole session'
    }
    It 'is ASCII-only (PS 5.1 em-dash trap)' {
        foreach ($s in @('incomplete', 'degraded', 'unavailable')) {
            $b = Get-DiagnosticsStatusBanner $s 'C:\x\foo.ps1'
            (@([System.Text.Encoding]::UTF8.GetBytes($b) | Where-Object { $_ -gt 127 }).Count) | Should -Be 0
        }
    }
}

# --- WS2: downloaded-dependency integrity (dispatch 000046, Gap B L2) -------
Describe 'Test-PinnedFileHash -- downloaded-dependency integrity (dispatch 000046)' {
    BeforeAll {
        $script:GoodFile = Join-Path $TestDrive 'artifact.bin'
        [System.IO.File]::WriteAllText($script:GoodFile, 'pinned-artifact-bytes', (New-Object System.Text.ASCIIEncoding))
        $script:GoodHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $script:GoodFile).Hash
    }
    It 'returns $true when the file matches its pinned SHA-256 (the verified-bundle direction)' {
        Test-PinnedFileHash -Path $script:GoodFile -ExpectedSha256 $script:GoodHash | Should -BeTrue
    }
    It 'matches case-insensitively (Get-FileHash emits upper-case hex)' {
        Test-PinnedFileHash -Path $script:GoodFile -ExpectedSha256 $script:GoodHash.ToLowerInvariant() | Should -BeTrue
    }
    It 'returns $false on a hash MISMATCH (the tampered-artifact direction -> caller fails closed)' {
        Test-PinnedFileHash -Path $script:GoodFile -ExpectedSha256 ('0' * 64) | Should -BeFalse
    }
    It 'detects a single-byte tamper (flipping one byte flips the verdict to $false)' {
        $tampered = Join-Path $TestDrive 'tampered.bin'
        [System.IO.File]::WriteAllText($tampered, 'pinned-artifact-byteS', (New-Object System.Text.ASCIIEncoding))
        Test-PinnedFileHash -Path $tampered -ExpectedSha256 $script:GoodHash | Should -BeFalse
    }
    It 'returns $false when the artifact is missing (absence is never read as verified)' {
        Test-PinnedFileHash -Path (Join-Path $TestDrive 'nope.bin') -ExpectedSha256 $script:GoodHash | Should -BeFalse
    }
    It 'returns $false on a blank pin (an empty pin can never count as verified)' {
        Test-PinnedFileHash -Path $script:GoodFile -ExpectedSha256 '' | Should -BeFalse
    }
}

Describe 'Pinned hash verification is WIRED into the bootstrap (dispatch 000046, Gap B L2)' {
    # The helper is only load-bearing if the ensure scripts actually CALL it against their pin
    # before using the download. These guards read the LIVE source so the wiring cannot silently
    # regress (a refactor that drops the verify, or a pin declared but never checked). Adversarial
    # control: delete the Test-PinnedFileHash call from ensure-pses and the ordering assertion
    # (verify-before-extract) goes RED.
    It 'ensure-pses.ps1 declares a 64-hex SHA-256 pin and verifies BEFORE extracting' {
        $src = Get-Content -LiteralPath (Join-Path $script:ScriptsDir 'ensure-pses.ps1') -Raw
        $src | Should -Match '\$PsesSha256\s*=\s*''[0-9A-Fa-f]{64}'''
        $src | Should -Match 'Test-PinnedFileHash[^\r\n]*\$PsesSha256'
        $verifyIdx = $src.IndexOf('Test-PinnedFileHash')
        $extractIdx = $src.IndexOf('Expand-Archive')
        $verifyIdx | Should -BeGreaterThan 0
        $extractIdx | Should -BeGreaterThan $verifyIdx
    }
    It 'ensure-pssa.ps1 declares a 64-hex SHA-256 pin and verifies the downloaded .nupkg' {
        $src = Get-Content -LiteralPath (Join-Path $script:ScriptsDir 'ensure-pssa.ps1') -Raw
        $src | Should -Match '\$PssaSha256\s*=\s*''[0-9A-Fa-f]{64}'''
        $src | Should -Match 'Test-PinnedFileHash[^\r\n]*\$PssaSha256'
    }
}

# --- 000049: the pinned-.nupkg cache is verify-gated and pin-bound -----------
Describe 'PSSA .nupkg cache is verify-gated and pin-bound (dispatch 000049)' {
    # The cache (the structural cure for the 000047 Gallery / CDN egress flake) is a classic place
    # to accidentally smuggle in a verification bypass. These guards read the LIVE source so the two
    # load-bearing invariants cannot silently regress: (1) a cache HIT is verified against the pin
    # BEFORE use, exactly like a fresh download; (2) the cache key binds to the pin so a bump can
    # never draw a stale artifact. The behavioral fail-closed proof lives in the integration suite
    # ('poisoned PSSA .nupkg cache FAILS CLOSED on restore'); these are the cheap source-level guards.
    BeforeAll {
        $script:EnsurePssaSrc = Get-Content -LiteralPath (Join-Path $script:ScriptsDir 'ensure-pssa.ps1') -Raw
    }
    It 'INVARIANT 1: a cache hit is copied into the verify path BEFORE the pin gate, which precedes any expand' {
        # cache-restore copy  <  Test-PinnedFileHash  <  Expand-Archive : the restored bytes flow
        # through the SAME gate a download does, and nothing is expanded/installed before the verify.
        # Adversarial control: move the cache copy after the verify (or the expand before it) -> RED.
        $restoreIdx = $script:EnsurePssaSrc.IndexOf('cache HIT')
        $verifyIdx = $script:EnsurePssaSrc.IndexOf('Test-PinnedFileHash -Path $nupkg -ExpectedSha256 $PssaSha256')
        $expandIdx = $script:EnsurePssaSrc.IndexOf('Expand-Archive')
        $restoreIdx | Should -BeGreaterThan 0
        $verifyIdx | Should -BeGreaterThan $restoreIdx
        $expandIdx | Should -BeGreaterThan $verifyIdx
    }
    It 'INVARIANT 1: exactly ONE pin-verify gate guards the install, and a mismatch fails closed' {
        # One Test-PinnedFileHash call over $nupkg guards both the cache-hit and download paths; the
        # cache hit does NOT add a second, weaker path. The mismatch branch refuses (fail closed).
        @([regex]::Matches($script:EnsurePssaSrc, 'Test-PinnedFileHash -Path \$nupkg')).Count | Should -Be 1
        $script:EnsurePssaSrc | Should -Match 'integrity check failed \(hash mismatch\); refusing unverified package'
    }
    It 'INVARIANT 2: the cache filename binds to BOTH the pinned version and the SHA-256' {
        # A pin bump (version OR hash) yields a different filename -> a guaranteed miss, never a stale
        # draw. Adversarial control: drop $PssaSha256 from the cache filename and this goes RED.
        $script:EnsurePssaSrc | Should -Match '\$PssaVersion\s*\+\s*''-''\s*\+\s*\$PssaSha256'
    }
    It 'is OFF by default: gated on POWERSHELL_LSP_PSSA_CACHE, and the Gallery is reached only on a miss' {
        # When the env var is unset there is no cache and acquisition is byte-identical to 000047.
        $script:EnsurePssaSrc | Should -Match 'POWERSHELL_LSP_PSSA_CACHE'
        # the network fetch is gated behind the cache-miss guard
        $guardIdx = $script:EnsurePssaSrc.IndexOf('if (-not $fromCache)')
        $downloadIdx = $script:EnsurePssaSrc.IndexOf('Invoke-WebRequest')
        $guardIdx | Should -BeGreaterThan 0
        $downloadIdx | Should -BeGreaterThan $guardIdx
    }
    It 'print-pssa-pin.ps1 emits the LIVE pin as version + 64-hex sha256 (the CI cache-key source)' {
        # The CI cache key is pssa-<os>-<version>-<sha256>; this script single-sources the pin from
        # ensure-pssa.ps1 so the key binds to it. A drift here would mis-key the cache.
        $lines = @(& (Join-Path $script:ScriptsDir 'print-pssa-pin.ps1'))
        @($lines | Where-Object { $_ -match '^version=\d+\.\d+\.\d+$' }).Count | Should -Be 1
        @($lines | Where-Object { $_ -match '^sha256=[0-9A-Fa-f]{64}$' }).Count | Should -Be 1
        $vp = ([regex]'\$PssaVersion\s*=\s*''([^'']+)''').Match($script:EnsurePssaSrc).Groups[1].Value
        $hp = ([regex]'\$PssaSha256\s*=\s*''([0-9A-Fa-f]{64})''').Match($script:EnsurePssaSrc).Groups[1].Value
        $lines | Should -Contain ('version=' + $vp)
        $lines | Should -Contain ('sha256=' + $hp)
    }
}

Describe 'Pester bootstrap is bounded to the 5.x major (dispatch 000120)' {
    # Pester 6.0.0 went GA on the PowerShell Gallery 2026-07-07. tests/run-tests.ps1 resolves
    # Pester at THREE points that were all unbounded UPWARD, so a runner-image change or a
    # fresh-install path could silently run the whole suite under Pester 6 with nobody deciding
    # to upgrade. All three are now capped at the 5.x major. These text-pin guards read the LIVE
    # source (the 000073 attest-pin Should-Match-on-the-literal pattern) so a future edit cannot
    # silently UNBOUND any one of them -- remove a single cap and its assertion goes RED.
    # Migrating to Pester 6 is a separate, later, Mike-minted decision; when it lands these
    # literals are retargeted DELIBERATELY (as the 000073 pin is), never loosened by accident.
    # Adversarial control: revert the detection filter to '-ge 5' and the first It goes RED.
    BeforeAll {
        $script:RunTestsSrc = Get-Content -LiteralPath (Join-Path (Join-Path $script:PluginRoot 'tests') 'run-tests.ps1') -Raw
    }
    It 'bounds the detection filter to the 5.x major (Version.Major -eq 5, never -ge 5)' {
        $script:RunTestsSrc | Should -Match '\$_\.Version\.Major -eq 5'
        $script:RunTestsSrc | Should -Not -Match '\$_\.Version\.Major -ge 5'
    }
    It 'caps the Install-Module fresh-install path at -MaximumVersion 5.99.99' {
        $script:RunTestsSrc | Should -Match 'Install-Module Pester[^\r\n]*-MaximumVersion 5\.99\.99'
    }
    It 'caps the Import-Module import at -MaximumVersion 5.99.99 (imports by name, not the resolved $p5)' {
        $script:RunTestsSrc | Should -Match 'Import-Module Pester[^\r\n]*-MaximumVersion 5\.99\.99'
    }
}

# ===========================================================================
# Format-on-edit: suggest, never rewrite (dispatch 000059, PL-8) -- pure helpers
# ===========================================================================
# The PSSA-touching parts (real Invoke-Formatter, repo-settings honoring, failure
# degrade, suggest-not-rewrite, knob-off byte-compare) are proven end to end in the
# integration suite (which bootstraps PSSA + a real daemon). These unit tests pin the
# PURE logic: the off-by-default knob parse, the unified-diff shaping, and the surface
# wording -- no PSSA, no daemon, no network.

Describe 'ConvertTo-FormatOnEditMode -- off-by-default knob parse (dispatch 000059)' {
    It 'maps suggest (and boolean-truthy aliases) to suggest' {
        foreach ($v in @('suggest', 'SUGGEST', ' Suggest ', 'true', 'on', '1', 'yes')) {
            (ConvertTo-FormatOnEditMode $v) | Should -BeExactly 'suggest'
        }
    }
    It 'maps off / blank / unexpanded token / unknown to off -- never silently on' {
        # The feature is opt-in: anything not explicitly an ON value is OFF. Adversarial control:
        # make the default branch return 'suggest' and these go RED (the knob would default ON).
        foreach ($v in @('off', '', '   ', '${user_config.formatOnEdit}', 'garbage', 'false', '0')) {
            (ConvertTo-FormatOnEditMode $v) | Should -BeExactly 'off'
        }
    }
    It 'maps the exact value apply to apply -- and ONLY the exact value (000099, doubly opt-in)' {
        # 000099 activated apply -- the write-back mode. It is DOUBLY opt-in: only the exact string
        # 'apply' (case/whitespace-insensitive) reaches it. A boolean-truthy alias must NOT, so a
        # user reaching for a boolean gets the safe suggest, never a file-writing mode. Adversarial
        # control: route a boolean alias to 'apply' and the alias assertions below go RED.
        (ConvertTo-FormatOnEditMode 'apply')    | Should -BeExactly 'apply'
        (ConvertTo-FormatOnEditMode '  APPLY ') | Should -BeExactly 'apply'
        foreach ($v in @('true', 'on', '1', 'yes')) {
            (ConvertTo-FormatOnEditMode $v) | Should -BeExactly 'suggest'   # NOT apply
        }
    }
}

Describe 'Get-FormatDiffResult -- unified diff + counts (dispatch 000059)' {
    It 'reports no change for identical text (the clean-edit-emits-nothing property)' {
        $r = Get-FormatDiffResult -Original "a`nb`n" -Formatted "a`nb`n"
        $r.changed | Should -BeFalse
        $r.diff | Should -BeExactly ''
        $r.removed | Should -Be 0
        $r.added | Should -Be 0
    }
    It 'treats a pure CRLF/LF delta as no change (newline-normalized)' {
        (Get-FormatDiffResult -Original "a`nb`n" -Formatted "a`r`nb`r`n").changed | Should -BeFalse
    }
    It 'produces a unified diff with correct -removed/+added counts and hunk header' {
        $orig = "function T {`nGet-Process`n}`n"
        $fmt = "function T {`n    Get-Process`n}`n"
        $r = Get-FormatDiffResult -Original $orig -Formatted $fmt
        $r.changed | Should -BeTrue
        $r.removed | Should -Be 1
        $r.added | Should -Be 1
        $r.diff | Should -Match '@@ -\d+,\d+ \+\d+,\d+ @@'
        $r.diff | Should -Match '(?m)^-Get-Process$'
        $r.diff | Should -Match '(?m)^\+    Get-Process$'
        # Unchanged lines are context (leading space), never +/-.
        $r.diff | Should -Match '(?m)^ function T \{$'
    }
    It 'flags a casing-only change (case-sensitive line compare)' {
        (Get-FormatDiffResult -Original "get-process`n" -Formatted "Get-Process`n").changed | Should -BeTrue
    }
    It 'caps the diff body and flags truncation for a large reflow' {
        $orig = (1..200 | ForEach-Object { "x$_" }) -join "`n"
        $fmt = (1..200 | ForEach-Object { "    y$_" }) -join "`n"
        $r = Get-FormatDiffResult -Original $orig -Formatted $fmt -MaxLines 20
        $r.changed | Should -BeTrue
        $r.truncated | Should -BeTrue
        (@($r.diff -split "`n").Count) | Should -BeLessOrEqual 21
    }
}

Describe 'Format-FormattingSuggestionBlock -- the suggest-not-rewrite surface (dispatch 000059)' {
    It 'is empty when there is nothing to suggest (no diff)' {
        (Format-FormattingSuggestionBlock -Path 'x.ps1' -Diff '' -Removed 0 -Added 0 -Truncated $false -SettingsPath '') |
            Should -BeExactly ''
    }
    It 'states the file was NOT modified and is visibly distinct from a diagnostic' {
        $b = Format-FormattingSuggestionBlock -Path 'x.ps1' -Diff "@@ -1,1 +1,1 @@`n-a`n+ a" -Removed 1 -Added 1 -Truncated $false -SettingsPath ''
        $b | Should -Match 'formatting suggestion'
        $b | Should -Match 'NOT modified'
        $b | Should -Not -Match 'PowerShell diagnostics \('   # never reads as a correctness finding
        $b | Should -Match 'default PSScriptAnalyzer style'
    }
    It 'names the repo settings file when one was honored' {
        $b = Format-FormattingSuggestionBlock -Path 'x.ps1' -Diff "@@ -1,1 +1,1 @@`n-a`n+ a" -Removed 1 -Added 1 -Truncated $false -SettingsPath 'C:\repo\PSScriptAnalyzerSettings.psd1'
        $b | Should -Match 'repo style \(PSScriptAnalyzerSettings\.psd1\)'
    }
    It 'appends a truncation marker when the diff was capped' {
        $b = Format-FormattingSuggestionBlock -Path 'x.ps1' -Diff "@@ -1,1 +1,1 @@`n-a`n+ a" -Removed 9 -Added 9 -Truncated $true -SettingsPath ''
        $b | Should -Match 'formatting diff truncated'
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

# ===========================================================================
# Single-source version stamp + docs honesty (dispatch 000025)
# ===========================================================================

Describe 'Get-PluginVersion -- single source of truth is the manifest (dispatch 000025)' {
    # 000023 audit S1b: three host-version literals (pses-stdio 1.0.0, pses-daemon 1.1.0,
    # lsp-common clientInfo 1.1.0) had drifted from the real plugin version and
    # bump-version.ps1 did not touch them. The fix sources every stamp from
    # .claude-plugin/plugin.json at runtime, so a manifest bump (the only place a version is
    # hand-set) can never leave a stale literal. Adversarial control: hardcode
    # Get-PluginVersion to a literal and the 'matches the manifest' assertion goes RED.
    BeforeAll {
        $manifestPath = Join-Path $script:PluginRoot '.claude-plugin/plugin.json'
        $script:ManifestVersion = [string](((Get-Content -LiteralPath $manifestPath -Raw) | ConvertFrom-Json).version)
    }
    It 'returns the exact version recorded in plugin.json' {
        Get-PluginVersion | Should -BeExactly $script:ManifestVersion
    }
    It 'returns a single, clean MAJOR.MINOR.PATCH string (no stray pipeline output)' {
        $out = @(Get-PluginVersion)
        $out.Count | Should -Be 1
        $out[0] | Should -Match '^\d+\.\d+\.\d+$'
    }
}

Describe 'Version stamps read the single source -- clientInfo + log line (dispatch 000025)' {
    # The warm-path LSP clientInfo.version (lib:409) and the daemon startup log stamp must
    # report the manifest version, not a literal. Proven against Get-PluginVersion (itself
    # proven == manifest above). Adversarial control: revert clientInfo.version to a literal
    # and the 'clientInfo carries the manifest version' assertion goes RED.
    It 'clientInfo.version equals Get-PluginVersion (the warm-path initialize stamp)' {
        (New-InitializeParams -RootUri 'file:///C:/proj' -ProcessId 1).clientInfo.version |
            Should -BeExactly (Get-PluginVersion)
    }
    It 'Get-VersionStamp embeds the plugin version (the daemon startup log surface, S1a)' {
        Get-VersionStamp | Should -BeExactly ('powershell-lsp ' + (Get-PluginVersion))
    }
}

Describe 'lsp-common.ps1 is load-silent -- the -Stdio stdout contract (dispatch 000025)' {
    # pses-stdio.ps1 dot-sources this lib, and its stdout IS the LSP byte stream once -Stdio
    # starts; a single byte emitted at import (or by Get-PluginVersion) would corrupt the
    # protocol. Guard: re-dot-sourcing the lib and calling Get-PluginVersion produce NO
    # success-stream output. Adversarial control: add a bare 'hello' expression at lib top
    # level and the 'emits nothing' assertion goes RED. (End-to-end proof that pses-stdio
    # itself prints nothing pre-handshake lives in the integration suite.)
    It 'dot-sourcing the lib emits nothing to the success stream' {
        $libPath = Join-Path $script:ScriptsDir 'lib/lsp-common.ps1'
        $captured = (. $libPath)
        $captured | Should -BeNullOrEmpty
    }
    It 'Get-PluginVersion emits nothing but its single return value' {
        @(Get-PluginVersion).Count | Should -Be 1
    }
}

Describe 'No hand-maintained host-version literal remains -- single-source guard (dispatch 000025)' {
    # The single-source fix means NONE of the three sites may carry a hardcoded
    # MAJOR.MINOR.PATCH version beside its stamp -- they must call Get-PluginVersion. This is
    # the 'can never go stale' guard: revert any site to a literal and its assertion goes
    # RED. Historical version mentions in COMMENTS (e.g. 'CHANGELOG 1.1.0') are NOT matched:
    # the patterns anchor on the -HostVersion argument and the clientInfo.version assignment.
    BeforeAll {
        $script:StdioSrc  = Get-Content -LiteralPath (Join-Path $script:ScriptsDir 'pses-stdio.ps1') -Raw
        $script:DaemonSrc = Get-Content -LiteralPath (Join-Path $script:ScriptsDir 'pses-daemon.ps1') -Raw
        $script:LibSrc    = Get-Content -LiteralPath (Join-Path $script:ScriptsDir 'lib/lsp-common.ps1') -Raw
    }
    It 'pses-stdio.ps1 stamps -HostVersion from Get-PluginVersion, not a literal' {
        $script:StdioSrc | Should -Match '-HostVersion \(Get-PluginVersion\)'
        $script:StdioSrc | Should -Not -Match "-HostVersion '\d+\.\d+\.\d+'"
    }
    It 'pses-daemon.ps1 stamps -HostVersion from Get-PluginVersion, not a literal' {
        $script:DaemonSrc | Should -Match "'-HostVersion', \(Get-PluginVersion\)"
        $script:DaemonSrc | Should -Not -Match "'-HostVersion', '\d+\.\d+\.\d+'"
    }
    It 'lsp-common.ps1 clientInfo.version is Get-PluginVersion, not a literal' {
        $script:LibSrc | Should -Match 'version = \(Get-PluginVersion\)'
        $script:LibSrc | Should -Not -Match "name = 'cc-pses-daemon'; version = '\d"
    }
    It 'pses-daemon.ps1 start banner emits the version stamp into the log (S1a)' {
        $script:DaemonSrc | Should -Match "daemon start: ' \+ \(Get-VersionStamp\)"
    }
}

Describe 'format-on-edit APPLY helpers -- byte fidelity + stale-write guard (dispatch 000099)' {
    Context 'BOM detection (byte fidelity)' {
        It 'detects a UTF-8 BOM prefix' { (Test-Utf8Bom ([byte[]](0xEF, 0xBB, 0xBF, 0x61))) | Should -BeTrue }
        It 'reports no UTF-8 BOM for plain bytes' { (Test-Utf8Bom ([byte[]](0x61, 0x62, 0x63))) | Should -BeFalse }
        It 'reports no UTF-8 BOM for an empty buffer (StrictMode-safe)' { (Test-Utf8Bom ([byte[]]@())) | Should -BeFalse }
        It 'detects UTF-16 LE and BE BOMs (unsupported for apply)' {
            (Test-Utf16Bom ([byte[]](0xFF, 0xFE, 0x61, 0x00))) | Should -BeTrue
            (Test-Utf16Bom ([byte[]](0xFE, 0xFF, 0x00, 0x61))) | Should -BeTrue
        }
        It 'reports no UTF-16 BOM for a UTF-8 file' { (Test-Utf16Bom ([byte[]](0xEF, 0xBB, 0xBF, 0x61))) | Should -BeFalse }
    }
    Context 'EOL classification (OQ4 -- mixed aborts to suggest)' {
        It 'classifies pure LF' { (Get-DominantEol "a`nb`n") | Should -BeExactly 'lf' }
        It 'classifies pure CRLF' { (Get-DominantEol "a`r`nb`r`n") | Should -BeExactly 'crlf' }
        It 'classifies MIXED CRLF+LF as mixed' { (Get-DominantEol "a`r`nb`n") | Should -BeExactly 'mixed' }
        It 'classifies a lone CR (classic Mac) as mixed/unsupported' { (Get-DominantEol "a`rb") | Should -BeExactly 'mixed' }
        It 'classifies a single line with no terminator as none' { (Get-DominantEol 'abc') | Should -BeExactly 'none' }
    }
    Context 'ConvertTo-Eol -- re-apply the original style' {
        It 're-applies CRLF to LF text' { (ConvertTo-Eol "a`nb`n" 'crlf') | Should -BeExactly "a`r`nb`r`n" }
        It 'normalizes CRLF text to LF' { (ConvertTo-Eol "a`r`nb`r`n" 'lf') | Should -BeExactly "a`nb`n" }
        It 'leaves LF for none' { (ConvertTo-Eol 'abc' 'none') | Should -BeExactly 'abc' }
    }
    Context 'Get-ApplyEncodedBytes -- the byte-fidelity assembler' {
        It 'returns a byte[] (never pipeline-unrolled)' {
            $b = Get-ApplyEncodedBytes -FormattedText "x`n" -Eol 'lf' -HasBom $false
            ($b -is [byte[]]) | Should -BeTrue
        }
        It 'prepends the UTF-8 BOM iff HasBom' {
            $b = Get-ApplyEncodedBytes -FormattedText "x`n" -Eol 'lf' -HasBom $true
            $b[0] | Should -Be 0xEF; $b[1] | Should -Be 0xBB; $b[2] | Should -Be 0xBF
            (Get-ApplyEncodedBytes -FormattedText "x`n" -Eol 'lf' -HasBom $false)[0] | Should -Be 0x78
        }
        It 'applies CRLF at the byte level (dominant-EOL preservation)' {
            $b = Get-ApplyEncodedBytes -FormattedText "a`nb`n" -Eol 'crlf' -HasBom $false
            ([System.Text.Encoding]::UTF8.GetString($b)) | Should -BeExactly "a`r`nb`r`n"
        }
    }
    Context 'Get-Sha256HexFromBytes -- the stale-write fingerprint' {
        It 'is a 64-char lowercase hex digest' {
            (Get-Sha256HexFromBytes ([System.Text.Encoding]::UTF8.GetBytes('x'))) | Should -Match '^[0-9a-f]{64}$'
        }
        It 'matches the known SHA-256 of "hello"' {
            (Get-Sha256HexFromBytes ([System.Text.Encoding]::UTF8.GetBytes('hello'))) |
                Should -BeExactly '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824'
        }
        It 'differs for a one-byte change' {
            (Get-Sha256HexFromBytes ([byte[]](1, 2, 3))) | Should -Not -Be (Get-Sha256HexFromBytes ([byte[]](1, 2, 4)))
        }
    }
    Context 'Write-FormatResultAtomic -- the stale-write compare-and-swap, proven adversarially' {
        BeforeEach {
            $script:AppDir = Join-Path ([System.IO.Path]::GetTempPath()) ('pslsp-apply-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 10))
            New-Item -ItemType Directory -Force -Path $script:AppDir | Out-Null
            $script:AppFile = Join-Path $script:AppDir 'f.ps1'
        }
        AfterEach {
            if (Test-Path -LiteralPath $script:AppDir) { Remove-Item -LiteralPath $script:AppDir -Recurse -Force -ErrorAction SilentlyContinue }
        }
        It 'HAPPY PATH: an unmutated file is written atomically with the formatted bytes' {
            $orig = [System.Text.Encoding]::UTF8.GetBytes("orig`n")
            [System.IO.File]::WriteAllBytes($script:AppFile, $orig)
            $h = Get-Sha256HexFromBytes ([System.IO.File]::ReadAllBytes($script:AppFile))
            $new = [System.Text.Encoding]::UTF8.GetBytes("formatted`n")
            $r = Write-FormatResultAtomic -Full $script:AppFile -InputHash $h -OutBytes $new
            $r.applied | Should -BeTrue
            [System.IO.File]::ReadAllBytes($script:AppFile) | Should -Be $new
        }
        It 'ADVERSARIAL: a file mutated between format-input capture and the write ABORTS, and the mutated bytes survive untouched' {
            $orig = [System.Text.Encoding]::UTF8.GetBytes("orig`n")
            [System.IO.File]::WriteAllBytes($script:AppFile, $orig)
            $h = Get-Sha256HexFromBytes ([System.IO.File]::ReadAllBytes($script:AppFile))   # (input capture)
            $mutated = [System.Text.Encoding]::UTF8.GetBytes("MUTATED-BY-A-NEWER-EDIT`n")
            [System.IO.File]::WriteAllBytes($script:AppFile, $mutated)                       # (concurrent modification)
            $new = [System.Text.Encoding]::UTF8.GetBytes("formatted`n")
            $r = Write-FormatResultAtomic -Full $script:AppFile -InputHash $h -OutBytes $new
            $r.applied | Should -BeFalse                                                     # (a) the apply ABORTED
            $r.reason | Should -Match 'changed on disk'                                      # (c) honest abort reason
            [System.IO.File]::ReadAllBytes($script:AppFile) | Should -Be $mutated            # (b) mutated bytes survive
        }
        It 'leaves NO temp file behind on either the applied or the aborted path' {
            $orig = [System.Text.Encoding]::UTF8.GetBytes("orig`n")
            [System.IO.File]::WriteAllBytes($script:AppFile, $orig)
            $h = Get-Sha256HexFromBytes $orig
            [void](Write-FormatResultAtomic -Full $script:AppFile -InputHash $h -OutBytes ([System.Text.Encoding]::UTF8.GetBytes("z`n")))       # applies
            [void](Write-FormatResultAtomic -Full $script:AppFile -InputHash 'deadbeef' -OutBytes ([System.Text.Encoding]::UTF8.GetBytes("z`n"))) # aborts (bad hash)
            @(Get-ChildItem -LiteralPath $script:AppDir -Filter '.pslsp-fmt-*' -Force).Count | Should -Be 0
        }
    }
    Context 'apply surface renderers -- visibly distinct from suggest and diagnostics' {
        It 'the APPLIED block says WAS MODIFIED and instructs a RE-READ (never "NOT modified")' {
            $b = Format-FormattingAppliedBlock -Path 'x.ps1' -Diff '@@ -1 +1 @@' -Removed 1 -Added 1 -Truncated $false -SettingsPath ''
            $b | Should -Match 'APPLIED'
            $b | Should -Match 'WAS MODIFIED'
            $b | Should -Match 'RE-READ'
            $b | Should -Not -Match 'NOT modified'
        }
        It 'the APPLIED block is empty when there is no diff' {
            (Format-FormattingAppliedBlock -Path 'x.ps1' -Diff '' -Removed 0 -Added 0 -Truncated $false -SettingsPath '') | Should -BeExactly ''
        }
        It 'the ABORTED fallback is suggest-shaped, says NOT modified, and names the reason' {
            $b = Format-FormattingApplyAbortedBlock -Path 'x.ps1' -Diff '@@ -1 +1 @@' -Removed 1 -Added 1 -Truncated $false -SettingsPath '' -Reason 'file has mixed line endings'
            $b | Should -Match 'formatting suggestion'
            $b | Should -Match 'apply did NOT run'
            $b | Should -Match 'NOT modified'
            $b | Should -Match 'mixed line endings'
        }
    }
}

Describe 'README config table documents every userConfig knob (dispatch 000025, 000023 D1 #4)' {
    # 000023 audit: the table documented 9 of 13 knobs (missing enableStats, settingsPath,
    # scopeToEdit, editContextLines). A paid product must not under-document the surface a
    # user pays to configure. Guard: the set of keys in the README Configuration table ==
    # the userConfig keys in plugin.json, exactly. Adversarial control: drop a table row (or
    # a manifest knob) and the set-equality assertion goes RED.
    BeforeAll {
        $manifestPath = Join-Path $script:PluginRoot '.claude-plugin/plugin.json'
        $manifest = (Get-Content -LiteralPath $manifestPath -Raw) | ConvertFrom-Json
        $script:ManifestKeys = @($manifest.userConfig.PSObject.Properties.Name) | Sort-Object

        # Slice the '## Configuration' section and pull the first-column `key` token of each
        # table row (the | Key | header and the |---| separator carry no backticks -> skipped;
        # the privacy blockquote starts with '>' not '|' -> skipped).
        $readmeText = Get-Content -LiteralPath (Join-Path $script:PluginRoot 'README.md') -Raw
        $m = [regex]::Match($readmeText, '(?ms)^##\s+Configuration\s*$(.*?)^##\s')
        $section = if ($m.Success) { $m.Groups[1].Value } else { '' }
        $keys = @()
        foreach ($line in ($section -split "`n")) {
            if ($line -match '^\s*\|\s*`([^`]+)`') { $keys += $Matches[1] }
        }
        $script:DocumentedKeys = @($keys) | Sort-Object
    }
    It 'documents exactly the manifest userConfig keys (none missing, none extra)' {
        ($script:DocumentedKeys -join ',') | Should -BeExactly ($script:ManifestKeys -join ',')
    }
    It 'documents the four knobs the 000023 audit found missing' {
        foreach ($k in @('enableStats', 'settingsPath', 'scopeToEdit', 'editContextLines')) {
            $script:DocumentedKeys | Should -Contain $k
        }
    }
}

Describe 'README documents the full diagnostics-status taxonomy (dispatch 000025)' {
    # Now that 000024 added the install-time 'unavailable', the README must document all four
    # statuses in one place. Guard: every status the code emits a non-empty banner for
    # (incomplete / degraded / unavailable -- the Get-DiagnosticsStatusBanner switch) appears
    # in the README, and the silent 'ok' is described too. Adversarial control: remove the
    # README docs for one banner status and the coverage assertion goes RED.
    BeforeAll {
        $script:ReadmeText = Get-Content -LiteralPath (Join-Path $script:PluginRoot 'README.md') -Raw
    }
    It 'documents every status that has a user-facing banner' {
        foreach ($s in @('incomplete', 'degraded', 'unavailable')) {
            (Get-DiagnosticsStatusBanner -Status $s -Path 'x.ps1') | Should -Not -BeNullOrEmpty
            $script:ReadmeText | Should -Match ('`' + $s + '`')
        }
    }
    It 'documents the silent clean status (ok)' {
        $script:ReadmeText | Should -Match '`ok`'
    }
}

# ===========================================================================
# CONTRACT.md 1.x freeze -- drift-guard (dispatch 000027)
# ===========================================================================
# The 1.x semver freeze (CONTRACT.md) pins two enumerable surfaces: the userConfig knob
# NAMES and the diagnostics status-token taxonomy. These guards give the freeze TEETH by
# validating CONTRACT.md against GROUND TRUTH extracted MECHANICALLY, LIVE FROM SOURCE --
# never against a hand-maintained list in this test:
#   - knob ground truth  = the userConfig keys parsed live from .claude-plugin/plugin.json.
#   - token ground truth = the Get-DiagnosticsStatusBanner switch labels (read from the
#     shipped function's AST) for the non-ok tokens, PLUS the clean token obtained by
#     CALLING Resolve-AnalysisStatus on a clean pass. ('ok' is the one token that is not a
#     banner switch label -- the banner returns '' for it -- so it is read from the resolver
#     that names it, not seeded as a literal here.)
# There is deliberately NO static {ps_host, ...} / {ok, ...} array in this file as the
# comparison anchor: the test reads the manifest and the functions, not a copy of them, so
# adding a knob to the manifest or a token to the banner FAILS CI until BOTH README and
# CONTRACT.md record it. README (above) and CONTRACT (here) are SEPARATE Describes so a red
# leg names WHICH document drifted. (Mike's non-negotiable, dispatch 000027.)

Describe 'CONTRACT.md freezes exactly the manifest userConfig knobs (dispatch 000027)' {
    BeforeAll {
        # GROUND TRUTH: the live manifest keys (read from plugin.json, NOT a copy).
        $manifestPath = Join-Path $script:PluginRoot '.claude-plugin/plugin.json'
        $manifest = (Get-Content -LiteralPath $manifestPath -Raw) | ConvertFrom-Json
        $script:ContractManifestKeys = @($manifest.userConfig.PSObject.Properties.Name) | Sort-Object

        # CONTRACT side: slice the sentinel-delimited FROZEN-KNOBS block and pull the
        # first-column backtick token of each table row. The HTML-comment markers bound the
        # machine-read region so prose backticks elsewhere in the doc cannot leak in; the
        # header (| Knob |) and separator (|---|) rows carry no backtick and are skipped.
        $contractPath = Join-Path $script:PluginRoot 'CONTRACT.md'
        $contractText = Get-Content -LiteralPath $contractPath -Raw
        $m = [regex]::Match($contractText, '(?s)FROZEN-KNOBS:BEGIN(.*?)FROZEN-KNOBS:END')
        $block = if ($m.Success) { $m.Groups[1].Value } else { '' }
        $keys = @()
        foreach ($line in ($block -split "`n")) {
            if ($line -match '^\s*\|\s*`([^`]+)`') { $keys += $Matches[1] }
        }
        $script:ContractKnobs = @($keys) | Sort-Object
    }
    It 'has a non-empty frozen-knobs block (the guard cannot pass vacuously)' {
        $script:ContractKnobs.Count | Should -BeGreaterThan 0
        $script:ContractManifestKeys.Count | Should -BeGreaterThan 0
    }
    It 'freezes exactly the manifest userConfig keys -- none missing, none extra' {
        # Set-equality against the LIVE manifest: add/rename/remove a knob in plugin.json
        # and this goes RED until CONTRACT.md matches. Adversarial control: drop or add a
        # FROZEN-KNOBS row (or a manifest knob) and the exact-match assertion goes RED.
        ($script:ContractKnobs -join ',') | Should -BeExactly ($script:ContractManifestKeys -join ',')
    }
}

Describe 'CONTRACT.md freezes exactly the diagnostics status-token taxonomy (dispatch 000027)' {
    BeforeAll {
        # GROUND TRUTH (live from source, two ways, no literal token list as the anchor):
        #   non-ok tokens <- the Get-DiagnosticsStatusBanner switch CLAUSE LABELS, via AST
        #     (the switch labels are the tokens; the clause BODIES are prose and are ignored).
        #   clean token   <- Resolve-AnalysisStatus on a settled + available pass: it RETURNS
        #     the clean token's name ('ok'), which is not a banner switch label.
        $libPath = Join-Path $script:ScriptsDir 'lib/lsp-common.ps1'
        $libAst = [System.Management.Automation.Language.Parser]::ParseFile($libPath, [ref]$null, [ref]$null)
        $bannerFn = $libAst.Find({
                param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq 'Get-DiagnosticsStatusBanner' }, $true)
        $switchAst = $bannerFn.Find({
                param($n) $n -is [System.Management.Automation.Language.SwitchStatementAst] }, $true)
        $script:NonOkTokens = @($switchAst.Clauses | ForEach-Object { [string]$_.Item1.Value })
        $script:CleanToken = Resolve-AnalysisStatus -Settled $true -PssaAvailable $true
        $script:BannerTokens = @((@($script:CleanToken) + $script:NonOkTokens) | Select-Object -Unique) | Sort-Object

        # CONTRACT side: the sentinel-delimited FROZEN-STATUS-TOKENS block, parsed the same
        # first-column-backtick way as the knob block.
        $contractPath = Join-Path $script:PluginRoot 'CONTRACT.md'
        $contractText = Get-Content -LiteralPath $contractPath -Raw
        $m = [regex]::Match($contractText, '(?s)FROZEN-STATUS-TOKENS:BEGIN(.*?)FROZEN-STATUS-TOKENS:END')
        $block = if ($m.Success) { $m.Groups[1].Value } else { '' }
        $toks = @()
        foreach ($line in ($block -split "`n")) {
            if ($line -match '^\s*\|\s*`([^`]+)`') { $toks += $Matches[1] }
        }
        $script:ContractTokens = @($toks) | Sort-Object
    }
    It 'extracts a non-empty token set from source (the guard cannot pass vacuously)' {
        $script:BannerTokens.Count | Should -BeGreaterThan 0
        $script:ContractTokens.Count | Should -BeGreaterThan 0
    }
    It 'freezes exactly the tokens the code emits -- none missing, none extra' {
        # Set-equality against the AST-derived + resolver-derived token set. Rename a switch
        # label (e.g. 'degraded' -> 'reduced') or add a clause without updating CONTRACT.md
        # and this goes RED. Adversarial control: edit a FROZEN-STATUS-TOKENS row out of sync
        # with the banner switch and the exact-match assertion goes RED.
        ($script:ContractTokens -join ',') | Should -BeExactly ($script:BannerTokens -join ',')
    }
    It 'every non-ok frozen token yields a distinct, non-empty, visible banner (the frozen property)' {
        $banners = @{}
        foreach ($t in $script:NonOkTokens) {
            $b = Get-DiagnosticsStatusBanner -Status $t -Path 'C:\x\foo.ps1'
            $b | Should -Not -BeNullOrEmpty
            $banners[$t] = $b
        }
        $set = New-Object System.Collections.Generic.HashSet[string]
        foreach ($b in $banners.Values) { [void]$set.Add($b) }
        $set.Count | Should -Be $script:NonOkTokens.Count   # all pairwise-distinct
    }
    It 'the clean token renders an empty banner (the byte-identical warm path)' {
        Get-DiagnosticsStatusBanner -Status $script:CleanToken -Path 'C:\x\foo.ps1' | Should -BeExactly ''
    }
}

Describe 'lspServers manifest declares only registrar-supported fields (dispatch 000075)' {
    # 000069 proved (on Claude Code 2.1.195) that the runtime LSP registrar SILENTLY DROPS
    # any lspServers server entry declaring restartOnCrash or shutdownTimeout. Both fields
    # are accepted by the plugin-manifest JSON schema, so the drop has NO diagnostic -- and
    # either field present means .ps1/.psm1/.psd1 -> powershell is never registered ("No LSP
    # server available for file type: .ps1"). This guard turns that silent registrar drop
    # into a LOUD test failure: every lspServers entry may declare ONLY the registrar-
    # supported allowlist, with the two known breakers named explicitly so a re-add is
    # unambiguous, and a future hostile key is caught by the closed allowlist.
    BeforeAll {
        # Single source of truth for "allowed" -- each field proven to REGISTER by the
        # 000069 probe matrix (GJ/GJT1/GJT4/GJenv/Text register; command+args register).
        $script:LspAllowlist = @(
            'command', 'args', 'extensionToLanguage', 'transport',
            'startupTimeout', 'maxRestarts', 'env'
        )
        # The two fields 000069 isolated as registrar-hostile, named per the dispatch so a
        # regression reads as "a known breaker came back", not a generic unknown key.
        $script:LspKnownBreakers = @('restartOnCrash', 'shutdownTimeout')

        # ONE checker, applied to the real manifest AND the adversarial fixtures below:
        # given a parsed lspServers entry, return the keys OUTSIDE the allowlist. No second
        # copy of the rule to drift; the allowlist is passed in (no closure ambiguity).
        $script:GetRegistrarHostileKeys = {
            param($Entry, $Allowlist)
            @($Entry.PSObject.Properties.Name | Where-Object { $Allowlist -notcontains $_ })
        }

        $manifestPath = Join-Path $script:PluginRoot '.claude-plugin/plugin.json'
        $manifest = (Get-Content -LiteralPath $manifestPath -Raw) | ConvertFrom-Json
        $script:LspServers = $manifest.lspServers
        $script:LspEntryNames = @($script:LspServers.PSObject.Properties.Name)
    }

    It 'has at least one lspServers entry and a non-empty allowlist (no vacuous pass)' {
        $script:LspEntryNames.Count | Should -BeGreaterThan 0
        $script:LspAllowlist.Count | Should -BeGreaterThan 0
    }

    It 'every shipped lspServers entry declares ONLY registrar-supported fields' {
        foreach ($name in $script:LspEntryNames) {
            $entry = $script:LspServers.$name
            $hostile = & $script:GetRegistrarHostileKeys $entry $script:LspAllowlist
            $because = "lspServers.$name declares registrar-hostile field(s): $($hostile -join ', ')"
            ($hostile -join ',') | Should -BeExactly '' -Because $because
        }
    }

    It 'declares NEITHER restartOnCrash NOR shutdownTimeout on any entry (the two breakers)' {
        foreach ($name in $script:LspEntryNames) {
            $keys = @($script:LspServers.$name.PSObject.Properties.Name)
            foreach ($breaker in $script:LspKnownBreakers) {
                $keys | Should -Not -Contain $breaker -Because "CC's registrar silently drops $breaker (000069)"
            }
        }
    }

    It 'the powershell entry still declares the working registrar-supported fields (no over-delete)' {
        $ps = $script:LspServers.powershell
        $ps | Should -Not -BeNullOrEmpty
        $keys = @($ps.PSObject.Properties.Name)
        foreach ($want in $script:LspAllowlist) {
            $keys | Should -Contain $want -Because "the fix removed ONLY the two breakers; $want must remain"
        }
    }

    # Adversarial controls -- the guard MUST go red when a breaker (or any future hostile
    # field) is re-introduced. Synthetic entries, not the manifest: this is what makes a
    # green run on the real manifest meaningful rather than vacuous.
    It 'FLAGS a fixture that re-adds restartOnCrash' {
        $fx = [pscustomobject]@{ command = 'pwsh'; args = @('-File', 'x.ps1'); restartOnCrash = $true }
        @(& $script:GetRegistrarHostileKeys $fx $script:LspAllowlist) | Should -Contain 'restartOnCrash'
    }

    It 'FLAGS a fixture that re-adds shutdownTimeout' {
        $fx = [pscustomobject]@{ command = 'pwsh'; args = @('-File', 'x.ps1'); shutdownTimeout = 5000 }
        @(& $script:GetRegistrarHostileKeys $fx $script:LspAllowlist) | Should -Contain 'shutdownTimeout'
    }

    It 'FLAGS a fixture with a future unknown field outside the allowlist (closed allowlist)' {
        $fx = [pscustomobject]@{ command = 'pwsh'; args = @('-File', 'x.ps1'); someFutureKnob = $true }
        @(& $script:GetRegistrarHostileKeys $fx $script:LspAllowlist) | Should -Contain 'someFutureKnob'
    }

    It 'PASSES a fixture declaring only allowlisted fields (no false positive)' {
        $fx = [pscustomobject]@{
            command             = 'pwsh'
            args                = @('-File', 'x.ps1')
            extensionToLanguage = @{ '.ps1' = 'powershell' }
            transport           = 'stdio'
            startupTimeout      = 30000
            maxRestarts         = 3
            env                 = @{ X = 'y' }
        }
        @(& $script:GetRegistrarHostileKeys $fx $script:LspAllowlist) | Should -BeNullOrEmpty
    }
}

Describe 'License metadata is single-sourced and consistent (dispatch 000029)' {
    # The 000027 docs-honesty / single-source discipline applied to the LICENSE: the SPDX id has ONE
    # source of truth -- plugin.json's `license` (the same manifest the version stamp reads, 000025) --
    # and the other declaration sites must agree. The LICENSE body is the GPLv3 text the SPDX id names,
    # and the README declares the same id. marketplace.json carries NO license field (the Claude Code
    # marketplace schema has none; an added value is silently ignored), so its ABSENCE is asserted
    # rather than letting a misleading/ignored declaration drift in. Adversarial control: change the
    # README SPDX id (or plugin.json's license) out of sync and the consistency assertions go RED.
    BeforeAll {
        $script:Lic_Root        = Split-Path -Parent $PSScriptRoot
        $script:Lic_Manifest    = (Get-Content -LiteralPath (Join-Path $script:Lic_Root '.claude-plugin/plugin.json') -Raw | ConvertFrom-Json)
        $script:Lic_Spdx        = [string]$script:Lic_Manifest.license
        $script:Lic_LicenseText = Get-Content -LiteralPath (Join-Path $script:Lic_Root 'LICENSE') -Raw
        $script:Lic_Readme      = Get-Content -LiteralPath (Join-Path $script:Lic_Root 'README.md') -Raw
        $script:Lic_Market      = (Get-Content -LiteralPath (Join-Path $script:Lic_Root '.claude-plugin/marketplace.json') -Raw | ConvertFrom-Json)
    }
    It 'plugin.json declares a non-empty SPDX license -- the single source of truth' {
        $script:Lic_Spdx | Should -Not -BeNullOrEmpty
        $script:Lic_Spdx | Should -Match '^GPL-3\.0-(or-later|only)$'
    }
    It 'LICENSE is the GPLv3 body the SPDX id names' {
        $script:Lic_Spdx | Should -Match '^GPL-3\.0'
        $script:Lic_LicenseText | Should -Match 'GNU GENERAL PUBLIC LICENSE'
        $script:Lic_LicenseText | Should -Match 'Version 3, 29 June 2007'
    }
    It 'README declares the SAME SPDX id as plugin.json (no drift)' {
        $script:Lic_Readme | Should -Match ([regex]::Escape($script:Lic_Spdx))
    }
    It 'marketplace.json carries NO license field (license lives in plugin.json; the marketplace schema has none)' {
        ($script:Lic_Market.PSObject.Properties.Name -contains 'license') | Should -BeFalse
        foreach ($p in @($script:Lic_Market.plugins)) {
            ($p.PSObject.Properties.Name -contains 'license') | Should -BeFalse
        }
    }
    It 'THIRD-PARTY-LICENSES.md documents both downloaded MIT deps' {
        $tp = Get-Content -LiteralPath (Join-Path $script:Lic_Root 'THIRD-PARTY-LICENSES.md') -Raw
        $tp | Should -Match 'PowerShell Editor Services'
        $tp | Should -Match 'PSScriptAnalyzer'
        $tp | Should -Match 'MIT'
    }
}

# ===========================================================================
# Preflight doctor -- per-check status decisions (dispatch 000036)
# ===========================================================================
# The doctor (scripts/doctor.ps1) is REPORT-ONLY: each check is a pure function over
# already-resolved probe inputs returning a status object, so the decision logic is
# unit-testable WITHOUT a live PSES install or network. These guards assert pass / fail /
# unknown per check with the probes injected. Dot-sourcing doctor.ps1 loads the functions
# without running the live checks (the entry-point guard skips on InvocationName '.').
# The live probes (Get-DoctorPwsh, Test-DoctorHostReachableProbe, ...) are exercised by
# the end-to-end run captured in the dispatch outbox, not here.

Describe 'Preflight doctor -- per-check status decisions (dispatch 000036)' {
    BeforeAll {
        . (Join-Path $script:ScriptsDir 'doctor.ps1')
    }

    Context 'New-DoctorResult -- the status-object shape and frozen vocabulary' {
        It 'carries Status / Component / Detail / Remediation' {
            $r = New-DoctorResult -Status pass -Component 'X' -Detail 'd'
            $r.Status | Should -Be 'pass'
            $r.Component | Should -Be 'X'
            $r.PSObject.Properties.Name | Should -Contain 'Remediation'
        }
        It 'rejects a status outside pass/fail/unknown (the inbox rule: no invented status words)' {
            # Adversarial control: widen or drop the ValidateSet and an invented token stops
            # throwing, so this assertion goes RED -- the vocabulary guard has teeth.
            { New-DoctorResult -Status 'broken' -Component 'X' } | Should -Throw
        }
    }

    Context 'Test-DoctorPwsh -- check 1: PowerShell 7 host' {
        It 'PASS when pwsh 7+ is present' {
            (Test-DoctorPwsh -Found $true -Version ([version]'7.4.2')).Status | Should -Be 'pass'
        }
        It 'FAIL when pwsh is absent (the hooks cannot launch)' {
            $r = Test-DoctorPwsh -Found $false -Version $null
            $r.Status | Should -Be 'fail'
            $r.Remediation | Should -Match 'winget install Microsoft.PowerShell'
        }
        It 'FAIL when pwsh is present but older than 7' {
            # Adversarial control: drop the Major -lt 7 branch and the 5.1 case flips
            # fail -> pass, going RED. (Resolve-PsHost accepts 5.1 as a host; the hooks do not.)
            (Test-DoctorPwsh -Found $true -Version ([version]'5.1.19041')).Status | Should -Be 'fail'
        }
        It 'UNKNOWN when pwsh is present but its version is undeterminable (honest, not a fabricated fail)' {
            (Test-DoctorPwsh -Found $true -Version $null).Status | Should -Be 'unknown'
        }
    }

    Context 'Test-DoctorEnabled -- check 2: plugin enablement' {
        It 'PASS when the plugin subprocess environment is present' {
            (Test-DoctorEnabled -PluginRootResolved $true).Status | Should -Be 'pass'
        }
        It 'UNKNOWN (never a fabricated fail) when enablement cannot be observed' {
            # Adversarial control: return 'fail' from the not-observed branch and this goes RED.
            # Absence of the plugin env does NOT prove the plugin is disabled.
            $r = Test-DoctorEnabled -PluginRootResolved $false
            $r.Status | Should -Be 'unknown'
            $r.Remediation | Should -Match '/plugin enable powershell-lsp'
        }
    }

    Context 'Test-DoctorPses -- check 3: PSES bundle bootstrapped' {
        It 'PASS only when BOTH the pinned marker and Start-EditorServices.ps1 are present' {
            (Test-DoctorPses -DataRootKnown $true -MarkerPresent $true -StartScriptPresent $true -PinTag 'v4.6.0').Status | Should -Be 'pass'
        }
        It 'FAIL when Start-EditorServices.ps1 is missing (bundle did not finish)' {
            $r = Test-DoctorPses -DataRootKnown $true -MarkerPresent $true -StartScriptPresent $false -PinTag 'v4.6.0'
            $r.Status | Should -Be 'fail'
            $r.Detail | Should -Match 'Start-EditorServices\.ps1'
        }
        It 'FAIL when the marker is missing even though the start script exists' {
            # Adversarial control: require only ONE of the two and this case flips to pass -> RED.
            (Test-DoctorPses -DataRootKnown $true -MarkerPresent $false -StartScriptPresent $true -PinTag 'v4.6.0').Status | Should -Be 'fail'
        }
        It 'UNKNOWN when the data root cannot be located (no false "not installed")' {
            # Adversarial control: treat an unknown data root as fail and this goes RED -- the
            # standalone invocation would then slander a healthy install as broken.
            (Test-DoctorPses -DataRootKnown $false -MarkerPresent $false -StartScriptPresent $false).Status | Should -Be 'unknown'
        }
    }

    Context 'Test-DoctorPssa -- check 4: PSScriptAnalyzer vendored + importable' {
        It 'PASS when the marker is present and the module imports' {
            (Test-DoctorPssa -DataRootKnown $true -MarkerPresent $true -Importable $true -PinVersion '1.25.0').Status | Should -Be 'pass'
        }
        It 'FAIL (degraded) when vendored but not importable' {
            $r = Test-DoctorPssa -DataRootKnown $true -MarkerPresent $true -Importable $false -PinVersion '1.25.0'
            $r.Status | Should -Be 'fail'
            $r.Detail | Should -Match 'degraded'
        }
        It 'FAIL when the vendor marker is missing' {
            (Test-DoctorPssa -DataRootKnown $true -MarkerPresent $false -Importable $false -PinVersion '1.25.0').Status | Should -Be 'fail'
        }
        It 'UNKNOWN when the data root cannot be located' {
            (Test-DoctorPssa -DataRootKnown $false -MarkerPresent $false -Importable $false).Status | Should -Be 'unknown'
        }
    }

    Context 'Test-DoctorHosts -- check 5: first-run download hosts reachable' {
        It 'PASS when all hosts are reachable' {
            $probes = @(
                [pscustomobject]@{ Host = 'github.com'; Reachable = $true }
                [pscustomobject]@{ Host = 'www.powershellgallery.com'; Reachable = $true }
            )
            (Test-DoctorHosts -HostProbes $probes).Status | Should -Be 'pass'
        }
        It 'FAIL (naming the host) when any host is unreachable' {
            # Adversarial control: collapse the $false branch into unknown and this fail -> unknown
            # flip goes RED -- a definite "could not reach" must read as a failure, not a maybe.
            $probes = @(
                [pscustomobject]@{ Host = 'github.com'; Reachable = $true }
                [pscustomobject]@{ Host = 'www.powershellgallery.com'; Reachable = $false }
            )
            $r = Test-DoctorHosts -HostProbes $probes
            $r.Status | Should -Be 'fail'
            $r.Detail | Should -Match 'www\.powershellgallery\.com'
        }
        It 'UNKNOWN when a probe could not run and none definitely failed' {
            $probes = @(
                [pscustomobject]@{ Host = 'github.com'; Reachable = $true }
                [pscustomobject]@{ Host = 'www.powershellgallery.com'; Reachable = $null }
            )
            (Test-DoctorHosts -HostProbes $probes).Status | Should -Be 'unknown'
        }
    }

    Context 'Format-DoctorReport -- the generic security pointer (boundary: dispatch 000036)' {
        It 'omits the security pointer when every check passed' {
            $clean = @(New-DoctorResult -Status pass -Component 'A' -Detail 'ok')
            (Format-DoctorReport -Results $clean) | Should -Not -Match 'security control'
        }
        It 'appends a single GENERIC security pointer when a check did not pass -- no control names' {
            # The doctor does not probe security controls (WDAC/AppLocker/ExecutionPolicy/CLM/SAC);
            # it may only point. Adversarial control: name a specific control here and the
            # "no control names" assertion goes RED.
            $dirty = @(
                New-DoctorResult -Status pass -Component 'A' -Detail 'ok'
                New-DoctorResult -Status fail -Component 'B' -Detail 'bad' -Remediation 'do x'
            )
            $report = Format-DoctorReport -Results $dirty
            $report | Should -Match 'security control'
            $report | Should -Not -Match 'WDAC|AppLocker|ExecutionPolicy|Constrained Language|Smart App Control'
        }
    }
}

# ===========================================================================
# Preflight doctor -- daemon/pipe health (dispatch 000037)
# ===========================================================================
# Check 6 (Test-DoctorDaemon) is the RUNTIME bookend to check 3: checks 1-5 confirm the
# bundle is INSTALLED; this confirms the warm per-session daemon is ACTUALLY ALIVE and
# answering on its named pipe. Like the 000036 checks it is a PURE decision over
# already-resolved observations (Get-DoctorDaemonObservation does the discovery + the
# non-disruptive 'ping' round-trip live), so the four-state mapping is asserted here with
# the daemon/pipe state injected -- no live daemon, no pipe. The mapping must stay HONEST
# about the 000028 pipe-first + 000030 auto-relaunch semantics: an absent daemon
# auto-relaunches on the next edit (benign), so it must NOT read as a FAIL.

Describe 'Preflight doctor -- daemon/pipe health (dispatch 000037)' {
    BeforeAll {
        . (Join-Path $script:ScriptsDir 'doctor.ps1')
    }

    Context 'Test-DoctorDaemon -- check 6: warm daemon runtime health' {
        It 'PASS when a daemon is alive and answered its pipe (the round-trip succeeded)' {
            $r = Test-DoctorDaemon -DataRootKnown $true -Determinable $true -DaemonPresent $true -State 'ready' -Reachable $true
            $r.Status | Should -Be 'pass'
            $r.Detail | Should -Match 'answered on its named pipe'
        }
        It 'PASS (still benign) when the daemon answers but PSES is still starting' {
            $r = Test-DoctorDaemon -DataRootKnown $true -Determinable $true -DaemonPresent $true -State 'starting' -Reachable $true
            $r.Status | Should -Be 'pass'
            $r.Detail | Should -Match 'still initializing'
        }
        It 'FAIL (parked unavailable) names the genuine problem and the restart remedy' {
            # Adversarial control: this is the 000030 PERMANENT case (a daemon ALIVE and reachable
            # but parked unavailable). It must FAIL even though the pipe answers -- so the State
            # check MUST precede the Reachable check. Reorder them and this fail -> pass, going RED.
            $r = Test-DoctorDaemon -DataRootKnown $true -Determinable $true -DaemonPresent $true -State 'unavailable' -Reachable $true
            $r.Status | Should -Be 'fail'
            $r.Detail | Should -Match 'unavailable'
            $r.Remediation | Should -Match 'fresh Claude Code session'
        }
        It 'FAIL (degraded) when the daemon is alive but its analyzer re-spawn budget is exhausted' {
            $r = Test-DoctorDaemon -DataRootKnown $true -Determinable $true -DaemonPresent $true -State 'degraded' -Reachable $true
            $r.Status | Should -Be 'fail'
            $r.Detail | Should -Match 'degraded'
        }
        It 'FAIL (wedged) when the daemon process is alive but the pipe did NOT answer' {
            # Adversarial control: pipe-first means a healthy daemon ALWAYS holds its pipe open, so
            # alive-but-silent is a real fault. Collapse this into the benign-absent branch and the
            # fail -> pass flip goes RED -- a wedged daemon must not read as "nothing to fix."
            $r = Test-DoctorDaemon -DataRootKnown $true -Determinable $true -DaemonPresent $true -State 'ready' -Reachable $false
            $r.Status | Should -Be 'fail'
            $r.Detail | Should -Match 'did not answer'
        }
        It 'PASS (benign, never FAIL) when no daemon is present -- it auto-relaunches on the next edit' {
            # Adversarial control: the 000030 recoverable case. A $null/absent daemon is benign (one
            # auto-relaunches on the next edit). Return fail from this branch and BOTH assertions go
            # RED -- a benign self-healing state must never be reported as a scary failure.
            $r = Test-DoctorDaemon -DataRootKnown $true -Determinable $true -DaemonPresent $false
            $r.Status | Should -Be 'pass'
            $r.Status | Should -Not -Be 'fail'
            $r.Detail | Should -Match 'auto-relaunches'
        }
        It 'UNKNOWN (no session context) when the data root cannot be located' {
            # Adversarial control: treat an unknown data root as fail/pass and this goes RED -- a
            # standalone run cannot see the daemon, so the honest answer is UNKNOWN, never a verdict.
            $r = Test-DoctorDaemon -DataRootKnown $false -Determinable $false -DaemonPresent $false
            $r.Status | Should -Be 'unknown'
            $r.Remediation | Should -Match 'inside a Claude Code session'
        }
        It 'UNKNOWN (ambiguous) when several daemons are live and no session id disambiguates' {
            # Adversarial control: guessing one of N live daemons would be a misleading PASS/FAIL.
            # The honest answer is UNKNOWN, naming the count and the -SessionId way to scope it.
            $r = Test-DoctorDaemon -DataRootKnown $true -Determinable $false -DaemonPresent $true -LiveCount 2
            $r.Status | Should -Be 'unknown'
            $r.Detail | Should -Match '2 live daemons'
            $r.Remediation | Should -Match 'SessionId'
        }
        It 'keeps its status inside the frozen pass/fail/unknown vocabulary (no invented token)' {
            foreach ($s in @(
                    (Test-DoctorDaemon -DataRootKnown $true -Determinable $true -DaemonPresent $true -State 'ready' -Reachable $true),
                    (Test-DoctorDaemon -DataRootKnown $true -Determinable $true -DaemonPresent $true -State 'unavailable' -Reachable $true),
                    (Test-DoctorDaemon -DataRootKnown $true -Determinable $true -DaemonPresent $false),
                    (Test-DoctorDaemon -DataRootKnown $false -Determinable $false -DaemonPresent $false)
                )) {
                $s.Status | Should -BeIn @('pass', 'fail', 'unknown')
            }
        }
    }
}

# ===========================================================================
# Preflight doctor -- native-serve removability (check 7, dispatch 000104)
# ===========================================================================
# The 000103 OQ4 probe, as a PURE decision over the removability observation
# Get-DoctorNativeServeObservation resolves live (it drives the DIRECT launcher via a pwsh
# subprocess and reads back InitReceived / InitHasStaticNav). The mapping is asserted here with
# the observation INJECTED -- no live PSES, no process. Two invariants are load-bearing: (1) the
# gated-today case (init received, nav NOT static) is a PASS, never a FAIL -- a removability
# diagnostic must NOT move the doctor's exit code; (2) the vocabulary stays the frozen
# pass/fail/unknown. The end-to-end drive (real PSES over the direct launcher) is a separate
# serialized e2e (PowerShellLsp.NativeServeProbe.Tests.ps1), per the 000101 one-server lesson.

Describe 'Preflight doctor -- native-serve removability (check 7, dispatch 000104)' {
    BeforeAll {
        . (Join-Path $script:ScriptsDir 'doctor.ps1')
    }

    Context 'Test-DoctorNativeServe -- check 7: is the nativeServe shim removable yet?' {
        It 'PASS "still gated" when init is received but nav is NOT advertised statically (today)' {
            # The load-bearing today case: PSES defers nav to the client/registerCapability handshake
            # the #1359 client bug breaks, so the init result carries no static nav -> the shim is
            # still needed. This is EXPECTED, so it must be a PASS.
            $r = Test-DoctorNativeServe -Determinable $true -InitReceived $true -HasStaticNav $false -ElapsedMs 1200 -TimeoutMs 20000
            $r.Status | Should -Be 'pass'
            $r.Detail | Should -Match 'still GATED'
            $r.Detail | Should -Match 'shim remains needed'
        }
        It 'PASS "still gated" is NEVER a fail -- a removability diagnostic must not move the exit code' {
            # Adversarial control: flip the gated branch to fail and the doctor would exit 1 on the
            # normal, expected state (the shim correctly still needed). That is the regression this
            # guards -- the probe reports, it never fails the run.
            (Test-DoctorNativeServe -Determinable $true -InitReceived $true -HasStaticNav $false).Status | Should -Not -Be 'fail'
        }
        It 'PASS "removable" when init is received and nav IS advertised statically' {
            # The flip the probe exists to catch: native serve completes statically, so the shim can
            # be removed. Adversarial control: collapse this into the gated branch and the removable
            # message never fires.
            $r = Test-DoctorNativeServe -Determinable $true -InitReceived $true -HasStaticNav $true -ElapsedMs 900 -TimeoutMs 20000
            $r.Status | Should -Be 'pass'
            $r.Detail | Should -Match 'can be REMOVED'
        }
        It 'UNKNOWN (not determinable) surfaces the honest reason and how to enable the probe' {
            # Adversarial control: a context where PSES cannot be launched is UNKNOWN, never a
            # verdict; the reason and the -ProbeNativeServe re-run path must be carried.
            $r = Test-DoctorNativeServe -Determinable $false -Reason 'the PSES bundle is not bootstrapped, so the direct launcher cannot start (see the PSES bundle check).'
            $r.Status | Should -Be 'unknown'
            $r.Detail | Should -Match 'not bootstrapped'
            $r.Remediation | Should -Match 'ProbeNativeServe'
        }
        It 'UNKNOWN when the direct launcher returned no initialize result within the bound' {
            # Determinable but PSES did not init in time (or crashed): indeterminate, never a false
            # "still gated". The bound (seconds) and any probe error are surfaced.
            $r = Test-DoctorNativeServe -Determinable $true -InitReceived $false -ProbeError 'the probe produced no result' -TimeoutMs 20000
            $r.Status | Should -Be 'unknown'
            $r.Detail | Should -Match 'did not return an initialize result'
            $r.Detail | Should -Match '20 s'
        }
        It 'keeps its status inside the frozen pass/fail/unknown vocabulary (no invented token)' {
            foreach ($s in @(
                    (Test-DoctorNativeServe -Determinable $true -InitReceived $true -HasStaticNav $false),
                    (Test-DoctorNativeServe -Determinable $true -InitReceived $true -HasStaticNav $true),
                    (Test-DoctorNativeServe -Determinable $true -InitReceived $false),
                    (Test-DoctorNativeServe -Determinable $false -Reason 'x')
                )) {
                $s.Status | Should -BeIn @('pass', 'fail', 'unknown')
            }
        }
        It 'NEVER returns fail on any input combination (report-only invariant)' {
            foreach ($s in @(
                    (Test-DoctorNativeServe -Determinable $true -InitReceived $true -HasStaticNav $false),
                    (Test-DoctorNativeServe -Determinable $true -InitReceived $true -HasStaticNav $true),
                    (Test-DoctorNativeServe -Determinable $true -InitReceived $false),
                    (Test-DoctorNativeServe -Determinable $false -Reason 'x')
                )) {
                $s.Status | Should -Not -Be 'fail'
            }
        }
    }
}

# ===========================================================================
# Security-block classifier (dispatch 000038, building 000032 L3)
# ===========================================================================
# Honest degradation on a security-control block: attribute a bootstrap failure to the
# control most likely blocking it -- but ONLY on positive evidence. The classifier is a
# PURE function over INJECTED evidence (these tests pass evidence directly, no live
# probes), so the honesty discipline is asserted deterministically per case. The live
# probes are exercised separately with EVERY probe mocked. This ENRICHES the existing
# never-silent surface (000024/000028); it adds NO status token (the 000027-frozen
# taxonomy is untouched -- the Get-DiagnosticsStatusBanner drift-guard above stays green).

Describe 'Resolve-SecurityBlock -- ExecutionPolicy attribution, GPO-scope only (dispatch 000038)' {
    It 'names ExecutionPolicy (likely) when a GROUP-POLICY scope is AllSigned' {
        $r = Resolve-SecurityBlock -Evidence @{ ExecutionPolicies = @{ MachinePolicy = 'AllSigned'; CurrentUser = 'Undefined' } } -Component 'PSES bootstrap'
        $r.Control | Should -BeExactly 'ExecutionPolicy'
        $r.Confidence | Should -BeExactly 'likely'
        $r.Summary | Should -Match 'MachinePolicy'
        $r.Summary | Should -Match 'AllSigned'
        $r.Evidence | Should -Match 'Get-ExecutionPolicy -List'
    }
    It 'names ExecutionPolicy for a UserPolicy RemoteSigned (the other GPO scope)' {
        $r = Resolve-SecurityBlock -Evidence @{ ExecutionPolicies = @{ UserPolicy = 'RemoteSigned' } } -Component 'PSES bootstrap'
        $r.Control | Should -BeExactly 'ExecutionPolicy'
        $r.Summary | Should -Match 'UserPolicy'
    }
    It 'does NOT name ExecutionPolicy for a CurrentUser/LocalMachine policy -- the plugin runs -ExecutionPolicy Bypass, which OVERRIDES those (the honesty boundary)' {
        # The whole correctness of this check: a non-GPO AllSigned is NOT a real block, so
        # naming it would be a false positive. Adversarial control: drop the scope filter and
        # this case starts naming ExecutionPolicy and goes RED.
        $r = Resolve-SecurityBlock -Evidence @{ ExecutionPolicies = @{ CurrentUser = 'AllSigned'; LocalMachine = 'RemoteSigned' } } -Component 'PSES bootstrap'
        $r.Control | Should -BeNullOrEmpty
        $r.Confidence | Should -BeExactly 'none'
    }
}

Describe 'Resolve-SecurityBlock -- Constrained Language Mode (dispatch 000038)' {
    It 'names CLM (likely) when the session LanguageMode is ConstrainedLanguage' {
        $r = Resolve-SecurityBlock -Evidence @{ LanguageMode = 'ConstrainedLanguage' } -Component 'PSES bootstrap'
        $r.Control | Should -BeExactly 'Constrained Language Mode'
        $r.Confidence | Should -BeExactly 'likely'
        $r.Summary | Should -Match 'Constrained Language Mode'
    }
    It 'does NOT name CLM for FullLanguage (no block)' {
        $r = Resolve-SecurityBlock -Evidence @{ LanguageMode = 'FullLanguage' } -Component 'PSES bootstrap'
        $r.Control | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-SecurityBlock -- App Control / WDAC via CodeIntegrity events (dispatch 000038)' {
    It 'names WDAC (confirmed) on a 3077 enforced-block event NAMING a plugin component' {
        $ev = @{ CodeIntegrityEvents = @(@{ Id = 3077; Message = 'Code Integrity blocked C:\data\PowerShellEditorServices\Start-EditorServices.ps1' }) }
        $r = Resolve-SecurityBlock -Evidence $ev -Component 'PSES bootstrap'
        $r.Control | Should -BeExactly 'App Control / WDAC'
        $r.Confidence | Should -BeExactly 'confirmed'
        $r.Summary | Should -Match '3077'
    }
    It 'names WDAC (likely) on a 3076 AUDIT event naming a plugin component -- audit is not enforced' {
        $ev = @{ CodeIntegrityEvents = @(@{ Id = 3076; Message = 'audit: pses-daemon.ps1' }) }
        $r = Resolve-SecurityBlock -Evidence $ev -Component 'PSES bootstrap'
        $r.Control | Should -BeExactly 'App Control / WDAC'
        $r.Confidence | Should -BeExactly 'likely'
        $r.Summary | Should -Match '3076'
    }
    It 'does NOT name WDAC on a 3077 that names some OTHER, unrelated file (no false positive)' {
        # Correlation, not bare presence: a 3077 about an unrelated binary on the box must not
        # be attributed to us. Adversarial control: drop the component-reference test and this
        # starts naming WDAC and goes RED.
        $ev = @{ CodeIntegrityEvents = @(@{ Id = 3077; Message = 'Code Integrity blocked C:\Program Files\Other\thing.exe' }) }
        $r = Resolve-SecurityBlock -Evidence $ev -Component 'PSES bootstrap'
        $r.Control | Should -BeNullOrEmpty
        $r.Confidence | Should -BeExactly 'none'
    }
}

Describe 'Resolve-SecurityBlock -- Defender ASR via events (dispatch 000038)' {
    It 'names Defender ASR (confirmed) on a 1121 block event naming a plugin component' {
        $ev = @{ DefenderAsrEvents = @(@{ Id = 1121; Message = 'ASR blocked process: ensure-pses.ps1' }) }
        $r = Resolve-SecurityBlock -Evidence $ev -Component 'PSES bootstrap'
        $r.Control | Should -BeExactly 'Microsoft Defender ASR'
        $r.Confidence | Should -BeExactly 'confirmed'
        $r.Summary | Should -Match '1121'
    }
    It 'names Defender ASR (likely) on a 1122 audit event naming a plugin component' {
        $ev = @{ DefenderAsrEvents = @(@{ Id = 1122; Message = 'ASR audit: pses-stdio.ps1' }) }
        $r = Resolve-SecurityBlock -Evidence $ev -Component 'PSES bootstrap'
        $r.Control | Should -BeExactly 'Microsoft Defender ASR'
        $r.Confidence | Should -BeExactly 'likely'
    }
}

Describe 'Resolve-SecurityBlock -- Smart App Control is SCOPED, never confirmed (dispatch 000038)' {
    It 'names SAC only as POSSIBLE when enforced (state 1), with hedged "may be" wording' {
        $r = Resolve-SecurityBlock -Evidence @{ SacState = 1 } -Component 'PSES bootstrap'
        $r.Control | Should -BeExactly 'Smart App Control'
        $r.Confidence | Should -BeExactly 'possible'
        $r.Summary | Should -Match 'may be'
    }
    It 'names SAC as POSSIBLE in evaluation mode (state 2)' {
        $r = Resolve-SecurityBlock -Evidence @{ SacState = 2 } -Component 'PSES bootstrap'
        $r.Control | Should -BeExactly 'Smart App Control'
        $r.Confidence | Should -BeExactly 'possible'
    }
    It 'does NOT name SAC when it is off (state 0)' {
        $r = Resolve-SecurityBlock -Evidence @{ SacState = 0 } -Component 'PSES bootstrap'
        $r.Control | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-SecurityBlock -- honest fallback, no fabrication (dispatch 000038)' {
    It 'returns "none" (no control) for empty evidence -- never invents a control' {
        $r = Resolve-SecurityBlock -Evidence @{ } -Component 'PSES bootstrap'
        $r.Control | Should -BeNullOrEmpty
        $r.Confidence | Should -BeExactly 'none'
    }
    It 'returns "none" for $null evidence (defensive)' {
        $r = Resolve-SecurityBlock -Evidence $null -Component 'PSES bootstrap'
        $r.Control | Should -BeNullOrEmpty
        $r.Confidence | Should -BeExactly 'none'
    }
    It 'returns "none" for benign, non-blocking evidence across the board' {
        $ev = @{ ExecutionPolicies = @{ MachinePolicy = 'Undefined'; CurrentUser = 'RemoteSigned' }; LanguageMode = 'FullLanguage'; SacState = 0; CodeIntegrityEvents = @(); DefenderAsrEvents = @() }
        $r = Resolve-SecurityBlock -Evidence $ev -Component 'PSES bootstrap'
        $r.Control | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-SecurityBlock -- precedence: highest-fidelity positive evidence wins (dispatch 000038)' {
    It 'a 3077 event (confirmed) outranks a concurrent CLM signal (likely) -- the event names the root policy' {
        $ev = @{ LanguageMode = 'ConstrainedLanguage'; CodeIntegrityEvents = @(@{ Id = 3077; Message = 'blocked pses-daemon.ps1' }) }
        $r = Resolve-SecurityBlock -Evidence $ev -Component 'PSES bootstrap'
        $r.Control | Should -BeExactly 'App Control / WDAC'
        $r.Confidence | Should -BeExactly 'confirmed'
    }
    It 'CLM (a current in-process fact) outranks an ExecutionPolicy GPO state when both are present' {
        $ev = @{ LanguageMode = 'ConstrainedLanguage'; ExecutionPolicies = @{ MachinePolicy = 'AllSigned' } }
        $r = Resolve-SecurityBlock -Evidence $ev -Component 'PSES bootstrap'
        $r.Control | Should -BeExactly 'Constrained Language Mode'
    }
    It 'an enforced 3077 outranks an audit 3076 in the same log' {
        $ev = @{ CodeIntegrityEvents = @(@{ Id = 3076; Message = 'audit pses-daemon.ps1' }, @{ Id = 3077; Message = 'blocked ensure-pses.ps1' }) }
        $r = Resolve-SecurityBlock -Evidence $ev -Component 'PSES bootstrap'
        $r.Confidence | Should -BeExactly 'confirmed'
    }
}

Describe 'Format-BootstrapFailureBanner -- enriched, never-silent, ASCII (dispatch 000038)' {
    It 'a named classification yields a banner that NAMES the control and keeps bootstrap+unavailable' {
        $c = Resolve-SecurityBlock -Evidence @{ LanguageMode = 'ConstrainedLanguage' } -Component 'PSES bootstrap'
        $b = Format-BootstrapFailureBanner -Classification $c -LogPath 'logs/ensure-pses.log'
        $b | Should -Match 'unavailable'                 # the never-silent surface (000024) holds
        $b | Should -Match 'bootstrap'                   # and the existing surface integration test
        $b | Should -Match 'Constrained Language Mode'   # the new attribution
        $b | Should -Match ([regex]::Escape('logs/ensure-pses.log'))
    }
    It 'the "none" fallback is an honest POINTER (check ExecutionPolicy / language mode / CodeIntegrity), not a fabricated control' {
        $c = Resolve-SecurityBlock -Evidence @{ } -Component 'PSES bootstrap'
        $b = Format-BootstrapFailureBanner -Classification $c -LogPath 'logs/ensure-pses.log'
        $b | Should -Match 'unavailable'
        $b | Should -Match 'bootstrap'
        $b | Should -Match 'Get-ExecutionPolicy -List'
        $b | Should -Match 'CodeIntegrity'
        $b | Should -Not -Match 'Constrained Language Mode is running'   # no asserted control in the fallback
    }
    It 'the confidence lead-in tracks the confidence (Cause / Likely cause / Possible cause)' {
        $confirmed = Format-BootstrapFailureBanner -Classification (Resolve-SecurityBlock -Evidence @{ CodeIntegrityEvents = @(@{ Id = 3077; Message = 'pses-daemon.ps1' }) }) -LogPath 'x'
        $likely = Format-BootstrapFailureBanner -Classification (Resolve-SecurityBlock -Evidence @{ LanguageMode = 'ConstrainedLanguage' }) -LogPath 'x'
        $possible = Format-BootstrapFailureBanner -Classification (Resolve-SecurityBlock -Evidence @{ SacState = 1 }) -LogPath 'x'
        $confirmed | Should -Match 'Cause:'
        $likely | Should -Match 'Likely cause:'
        $possible | Should -Match 'Possible cause:'
    }
    It 'every classification + banner is ASCII-only (PS 5.1 em-dash trap)' {
        $cases = @(
            (Resolve-SecurityBlock -Evidence @{ ExecutionPolicies = @{ MachinePolicy = 'AllSigned' } }),
            (Resolve-SecurityBlock -Evidence @{ LanguageMode = 'ConstrainedLanguage' }),
            (Resolve-SecurityBlock -Evidence @{ CodeIntegrityEvents = @(@{ Id = 3077; Message = 'pses-daemon.ps1' }) }),
            (Resolve-SecurityBlock -Evidence @{ DefenderAsrEvents = @(@{ Id = 1121; Message = 'ensure-pses.ps1' }) }),
            (Resolve-SecurityBlock -Evidence @{ SacState = 1 }),
            (Resolve-SecurityBlock -Evidence @{ })
        )
        foreach ($c in $cases) {
            foreach ($s in @([string]$c.Summary, [string]$c.Remediation, [string]$c.Evidence, (Format-BootstrapFailureBanner -Classification $c -LogPath 'logs/x.log'))) {
                (@([System.Text.Encoding]::UTF8.GetBytes($s) | Where-Object { $_ -gt 127 }).Count) | Should -Be 0
            }
        }
    }
}

Describe 'Security classifier -- the absolute fence: detect, never circumvent (dispatch 000038)' {
    # Every remediation must be INSTRUCTIONS for the user/admin, never an action the plugin
    # takes, and must never emit a control-modifying command. Adversarial control: put a
    # Set-ExecutionPolicy / Add-MpPreference into any remediation and this goes RED.
    It 'no remediation contains a control-MODIFYING command (Set-ExecutionPolicy / *-MpPreference / reg add)' {
        $cases = @(
            (Resolve-SecurityBlock -Evidence @{ ExecutionPolicies = @{ MachinePolicy = 'AllSigned' } }),
            (Resolve-SecurityBlock -Evidence @{ LanguageMode = 'ConstrainedLanguage' }),
            (Resolve-SecurityBlock -Evidence @{ CodeIntegrityEvents = @(@{ Id = 3077; Message = 'pses-daemon.ps1' }) }),
            (Resolve-SecurityBlock -Evidence @{ DefenderAsrEvents = @(@{ Id = 1121; Message = 'ensure-pses.ps1' }) }),
            (Resolve-SecurityBlock -Evidence @{ SacState = 1 })
        )
        foreach ($c in $cases) {
            [string]$c.Remediation | Should -Not -Match 'Set-ExecutionPolicy'
            [string]$c.Remediation | Should -Not -Match 'MpPreference'
            [string]$c.Remediation | Should -Not -Match 'reg(\.exe)?\s+add'
            # Positive framing: each names the plugin's REFUSAL to act ("will not") -- the fence in words.
            [string]$c.Remediation | Should -Match 'will not'
        }
    }
}

Describe 'Get-SecurityBlockEvidence + Resolve-SecurityBlock -- ALL probes mocked (dispatch 000038)' {
    # The live probes are best-effort glue; here EVERY probe is mocked so the gather -> classify
    # path is deterministic and the "all probes mocked" acceptance is met literally.
    It 'a mocked ConstrainedLanguage probe drives a CLM classification end to end' {
        Mock Get-ExecutionPolicyState { @{} }
        Mock Get-SessionLanguageMode { 'ConstrainedLanguage' }
        Mock Get-SmartAppControlState { $null }
        Mock Get-CodeIntegrityBlockEvents { @() }
        Mock Get-DefenderAsrBlockEvents { @() }
        $r = Resolve-SecurityBlock -Evidence (Get-SecurityBlockEvidence) -Component 'PSES bootstrap'
        $r.Control | Should -BeExactly 'Constrained Language Mode'
    }
    It 'a mocked 3077 CodeIntegrity probe drives a WDAC (confirmed) classification end to end' {
        Mock Get-ExecutionPolicyState { @{} }
        Mock Get-SessionLanguageMode { 'FullLanguage' }
        Mock Get-SmartAppControlState { $null }
        Mock Get-CodeIntegrityBlockEvents { @(@{ Id = 3077; Message = 'blocked pses-daemon.ps1' }) }
        Mock Get-DefenderAsrBlockEvents { @() }
        $r = Resolve-SecurityBlock -Evidence (Get-SecurityBlockEvidence) -Component 'PSES bootstrap'
        $r.Control | Should -BeExactly 'App Control / WDAC'
        $r.Confidence | Should -BeExactly 'confirmed'
    }
    It 'all-benign mocked probes yield the honest "none" fallback' {
        Mock Get-ExecutionPolicyState { @{ MachinePolicy = 'Undefined' } }
        Mock Get-SessionLanguageMode { 'FullLanguage' }
        Mock Get-SmartAppControlState { 0 }
        Mock Get-CodeIntegrityBlockEvents { @() }
        Mock Get-DefenderAsrBlockEvents { @() }
        $r = Resolve-SecurityBlock -Evidence (Get-SecurityBlockEvidence) -Component 'PSES bootstrap'
        $r.Control | Should -BeNullOrEmpty
        $r.Confidence | Should -BeExactly 'none'
    }
}

Describe 'Closed-loop agentic correction -- New-LifecycleFinding (dispatch 000061)' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')
        # A diagnostic record the way ConvertTo-DiagRecord builds it (an ordered hashtable).
        function New-Rec { param([int]$Line, [string]$Code, [string]$Msg = 'm')
            [ordered]@{ severity = 'Warning'; line = $Line; endLine = $Line; col = 1; source = 'PSScriptAnalyzer'; code = $Code; message = $Msg } }
    }

    It 'derives the shape-hash from ruleId + the offending file line at the record line' {
        $rec = New-Rec -Line 1 -Code 'PSUseApprovedVerbs'
        $lines = @('function Frob-X {', '    Get-Process', '}')
        $lf = New-LifecycleFinding -Record $rec -Lines $lines
        $lf.ruleId | Should -BeExactly 'PSUseApprovedVerbs'
        $lf.line | Should -Be 1
        $lf.hash | Should -BeExactly (Get-DiagnosticShapeHash -RuleId 'PSUseApprovedVerbs' -OffendingLine 'function Frob-X {')
    }

    It 'is line-position independent: the same offending text at a different line has the SAME hash (MOVED survives a shift)' {
        $top = New-LifecycleFinding -Record (New-Rec -Line 1 -Code 'R') -Lines @('gci', '# pad')
        $shifted = New-LifecycleFinding -Record (New-Rec -Line 2 -Code 'R') -Lines @('# inserted above', 'gci')
        $shifted.line | Should -Be 2                     # the line MOVED
        $shifted.hash | Should -BeExactly $top.hash      # but the identity (hash) is unchanged
    }

    It 'maps an absent/zero rule code to an empty ruleId (mirrors the dogfood derivation)' {
        (New-LifecycleFinding -Record (New-Rec -Line 1 -Code '0') -Lines @('x')).ruleId | Should -BeExactly ''
        (New-LifecycleFinding -Record (New-Rec -Line 1 -Code '') -Lines @('x')).ruleId | Should -BeExactly ''
    }

    It 'tolerates an out-of-range line (offending line empty, never throws)' {
        $lf = New-LifecycleFinding -Record (New-Rec -Line 99 -Code 'R') -Lines @('only one line')
        $lf.hash | Should -BeExactly (Get-DiagnosticShapeHash -RuleId 'R' -OffendingLine '')
    }
}

Describe 'Closed-loop agentic correction -- Get-FindingLifecycleDiff (dispatch 000061)' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')
        # A projected lifecycle finding ({ hash; ruleId; line; message }) with an EXPLICIT hash, so
        # the set logic is exercised in isolation from the hashing (which its own tests cover).
        function LF { param([string]$Hash, [string]$Rule = 'R', [int]$Line = 1, [string]$Msg = 'm')
            [pscustomobject]@{ hash = $Hash; ruleId = $Rule; line = $Line; message = $Msg } }
        # A prior-map entry the way the daemon stores it.
        function PriorEntry { param([string]$Rule = 'R', [int]$Line = 1, [string]$Msg = 'm', [int]$Attempts = 0)
            @{ ruleId = $Rule; line = $Line; message = $Msg; attempts = $Attempts } }
    }

    It 'NEW finding (empty prior): no cleared, no still-present; recorded in memory at attempts 0' {
        $diff = Get-FindingLifecycleDiff -PriorMap @{} -CurrentFull @((LF 'h1')) -CurrentSurfaced @((LF 'h1')) -ScopeApplied $true
        @($diff.Cleared).Count | Should -Be 0
        @($diff.StillPresent).Count | Should -Be 0
        $diff.NewMap.ContainsKey('h1') | Should -BeTrue
        [int]$diff.NewMap['h1']['attempts'] | Should -Be 0
    }

    It 'CLEARED: a prior-surfaced finding absent from the whole-file pass is reported cleared and dropped from memory' {
        $prior = @{ 'h1' = (PriorEntry -Rule 'PSAvoidUsingCmdletAliases' -Msg 'gci alias') }
        $diff = Get-FindingLifecycleDiff -PriorMap $prior -CurrentFull @() -CurrentSurfaced @() -ScopeApplied $true
        @($diff.Cleared).Count | Should -Be 1
        $diff.Cleared[0].ruleId | Should -BeExactly 'PSAvoidUsingCmdletAliases'
        @($diff.StillPresent).Count | Should -Be 0
        $diff.NewMap.ContainsKey('h1') | Should -BeFalse   # cleared -> forgotten
    }

    It 'STILL-PRESENT (attempt 1): a prior finding still surfaced under a determinate R escalates once, not downgraded' {
        $prior = @{ 'h1' = (PriorEntry -Attempts 0) }
        $diff = Get-FindingLifecycleDiff -PriorMap $prior -CurrentFull @((LF 'h1')) -CurrentSurfaced @((LF 'h1')) -ScopeApplied $true
        @($diff.Cleared).Count | Should -Be 0
        @($diff.StillPresent).Count | Should -Be 1
        [int]$diff.StillPresent[0].attempts | Should -Be 1
        [bool]$diff.StillPresent[0].downgraded | Should -BeFalse
        [int]$diff.NewMap['h1']['attempts'] | Should -Be 1
    }

    It 'BOUNDED escalation: attempts 1..2 escalate, attempt 3 downgrades ONCE, attempt 4+ goes silent (K=2)' {
        # attempt 2 (prior 1) -> escalate, not downgraded
        $d2 = Get-FindingLifecycleDiff -PriorMap @{ 'h1' = (PriorEntry -Attempts 1) } -CurrentFull @((LF 'h1')) -CurrentSurfaced @((LF 'h1')) -ScopeApplied $true
        @($d2.StillPresent).Count | Should -Be 1
        [int]$d2.StillPresent[0].attempts | Should -Be 2
        [bool]$d2.StillPresent[0].downgraded | Should -BeFalse
        # attempt 3 (prior 2) -> ONE neutral downgrade
        $d3 = Get-FindingLifecycleDiff -PriorMap @{ 'h1' = (PriorEntry -Attempts 2) } -CurrentFull @((LF 'h1')) -CurrentSurfaced @((LF 'h1')) -ScopeApplied $true
        @($d3.StillPresent).Count | Should -Be 1
        [int]$d3.StillPresent[0].attempts | Should -Be 3
        [bool]$d3.StillPresent[0].downgraded | Should -BeTrue
        # attempt 4 (prior 3) -> SILENCE (no entry), but memory keeps counting
        $d4 = Get-FindingLifecycleDiff -PriorMap @{ 'h1' = (PriorEntry -Attempts 3) } -CurrentFull @((LF 'h1')) -CurrentSurfaced @((LF 'h1')) -ScopeApplied $true
        @($d4.StillPresent).Count | Should -Be 0
        [int]$d4.NewMap['h1']['attempts'] | Should -Be 4
    }

    It 'NO determinate R (ScopeApplied false): a still-present finding is NOT escalated and NOT counted as an attempt' {
        $prior = @{ 'h1' = (PriorEntry -Attempts 0) }
        $diff = Get-FindingLifecycleDiff -PriorMap $prior -CurrentFull @((LF 'h1')) -CurrentSurfaced @((LF 'h1')) -ScopeApplied $false
        @($diff.StillPresent).Count | Should -Be 0
        [int]$diff.NewMap['h1']['attempts'] | Should -Be 0   # unchanged: a whole-file pass is not a counted attempt
    }

    It 'MOVED folds into still-present: the same hash at a new line is still-present (never a false cleared)' {
        # prior recorded the finding at line 5; this turn the same hash surfaces at line 8 (shifted).
        $prior = @{ 'h1' = (PriorEntry -Line 5 -Attempts 0) }
        $diff = Get-FindingLifecycleDiff -PriorMap $prior -CurrentFull @((LF 'h1' 'R' 8)) -CurrentSurfaced @((LF 'h1' 'R' 8)) -ScopeApplied $true
        @($diff.Cleared).Count | Should -Be 0                 # NOT a false cleared
        @($diff.StillPresent).Count | Should -Be 1
        [int]$diff.StillPresent[0].line | Should -Be 8        # reported at the new (moved) line
    }

    It 'CARRY-FORWARD: a prior finding still present but NOT surfaced this turn is kept in memory (so a later clear is still seen)' {
        # h1 present in full but not in the surfaced (touched) set this turn -> carried, attempts unchanged.
        $prior = @{ 'h1' = (PriorEntry -Attempts 1) }
        $diff = Get-FindingLifecycleDiff -PriorMap $prior -CurrentFull @((LF 'h1')) -CurrentSurfaced @() -ScopeApplied $true
        @($diff.Cleared).Count | Should -Be 0
        @($diff.StillPresent).Count | Should -Be 0
        $diff.NewMap.ContainsKey('h1') | Should -BeTrue
        [int]$diff.NewMap['h1']['attempts'] | Should -Be 1
    }

    It 'mixed turn: one finding clears while a new one appears (both signals correct in one pass)' {
        $prior = @{ 'hOld' = (PriorEntry -Rule 'PSUseApprovedVerbs' -Msg 'bad verb') }
        $diff = Get-FindingLifecycleDiff -PriorMap $prior -CurrentFull @((LF 'hNew' 'PSAvoidUsingCmdletAliases')) -CurrentSurfaced @((LF 'hNew' 'PSAvoidUsingCmdletAliases')) -ScopeApplied $true
        @($diff.Cleared).Count | Should -Be 1
        $diff.Cleared[0].ruleId | Should -BeExactly 'PSUseApprovedVerbs'
        @($diff.StillPresent).Count | Should -Be 0          # hNew is NEW, rides the normal surface
        $diff.NewMap.ContainsKey('hNew') | Should -BeTrue
        $diff.NewMap.ContainsKey('hOld') | Should -BeFalse
    }

    It 'StrictMode-safe on empty/null inputs (no read-before-assign, no @($null) phantom -- the 000062 class)' {
        { Get-FindingLifecycleDiff -PriorMap @{} -CurrentFull @() -CurrentSurfaced @() -ScopeApplied $true } | Should -Not -Throw
        $diff = Get-FindingLifecycleDiff -PriorMap @{} -CurrentFull @() -CurrentSurfaced @() -ScopeApplied $true
        @($diff.Cleared).Count | Should -Be 0
        @($diff.StillPresent).Count | Should -Be 0
        $diff.NewMap.Count | Should -Be 0
    }
}

# ===========================================================================
# pre-push guard -- refuse a direct push to origin/main (dispatch 000080)
# ===========================================================================
# The guard (scripts/pre-push-guard.ps1) makes the PR-and-HOLD discipline a refusal on the
# developer's machine: a push that UPDATES refs/heads/main on origin is refused; every other
# push (a feature branch, a tag, a delete, a fork remote) passes through; a deliberate
# override (a non-empty reason) is allowed AND audited. The script is dot-source safe (the
# doctor.ps1 pattern), so these drive the PURE decision and the audit writer directly -- no
# git, no network, I/O only into TestDrive. The git hook hooks/pre-push is the thin POSIX sh
# shim that forwards the push refspec (stdin) + remote name/url (argv) into this guard; that
# the hook fires from a LINKED worktree is proven end-to-end outside the suite (it needs a
# real `git push`), and this asserts the decision the shim trusts.

Describe 'pre-push guard refuses a direct push to origin/main (dispatch 000080)' {
    BeforeAll {
        . (Join-Path $script:ScriptsDir 'pre-push-guard.ps1')
        $script:GuardOriginUrl = 'https://github.com/manderse21/claude-powershell-lsp.git'
        $script:GuardZeroSha = '0000000000000000000000000000000000000000'

        # One pre-push stdin line: "<localref> <localsha> <remoteref> <remotesha>".
        function New-PushSpecLine {
            param(
                [string] $RemoteRef,
                [string] $LocalSha = 'aaaa111122223333444455556666777788889999',
                [string] $RemoteSha = '0000000000000000000000000000000000000000',
                [string] $LocalRef = 'refs/heads/work'
            )
            return ('{0} {1} {2} {3}' -f $LocalRef, $LocalSha, $RemoteRef, $RemoteSha)
        }
    }

    Context 'refuse-on-main' {
        It 'refuses a push that updates refs/heads/main on origin (matched by remote NAME)' {
            $r = Resolve-PushToMainGuard -RemoteName 'origin' -RemoteUrl $script:GuardOriginUrl `
                -OriginUrl $script:GuardOriginUrl `
                -PushSpecLines @((New-PushSpecLine -RemoteRef 'refs/heads/main')) -OverrideReason ''
            $r.Decision | Should -BeExactly 'refuse'
            $r.IsOrigin | Should -BeTrue
            $r.TargetsMain | Should -BeTrue
            $r.Blocks | Should -BeTrue
            $r.Sha | Should -BeExactly 'aaaa111122223333444455556666777788889999'
            $r.TargetRef | Should -BeExactly 'refs/heads/main'
        }
        It 'refuses when the remote is named by origin URL even though the NAME is not "origin"' {
            # `git push <origin-url> main` -- name match misses, URL match catches it.
            $r = Resolve-PushToMainGuard -RemoteName $script:GuardOriginUrl -RemoteUrl $script:GuardOriginUrl `
                -OriginUrl $script:GuardOriginUrl `
                -PushSpecLines @((New-PushSpecLine -RemoteRef 'refs/heads/main')) -OverrideReason ''
            $r.Decision | Should -BeExactly 'refuse'
            $r.IsOrigin | Should -BeTrue
        }
    }

    Context 'pass-throughs -- the refusal stays narrow (every other push is untouched)' {
        It 'allows a push to a feature branch on origin (the dispatch own branch is the live example)' {
            $r = Resolve-PushToMainGuard -RemoteName 'origin' -RemoteUrl $script:GuardOriginUrl `
                -OriginUrl $script:GuardOriginUrl `
                -PushSpecLines @((New-PushSpecLine -RemoteRef 'refs/heads/dispatch-000080-pre-push-guard')) -OverrideReason ''
            $r.Decision | Should -BeExactly 'allow'
            $r.TargetsMain | Should -BeFalse
        }
        It 'allows a tag push on origin' {
            $r = Resolve-PushToMainGuard -RemoteName 'origin' -RemoteUrl $script:GuardOriginUrl `
                -OriginUrl $script:GuardOriginUrl `
                -PushSpecLines @((New-PushSpecLine -RemoteRef 'refs/tags/v1.2.3')) -OverrideReason ''
            $r.Decision | Should -BeExactly 'allow'
            $r.TargetsMain | Should -BeFalse
        }
        It 'allows a DELETE of origin/main -- an all-zero local sha is a delete, not an update' {
            $r = Resolve-PushToMainGuard -RemoteName 'origin' -RemoteUrl $script:GuardOriginUrl `
                -OriginUrl $script:GuardOriginUrl `
                -PushSpecLines @((New-PushSpecLine -RemoteRef 'refs/heads/main' -LocalSha $script:GuardZeroSha -LocalRef '(delete)')) `
                -OverrideReason ''
            $r.Decision | Should -BeExactly 'allow'
            $r.TargetsMain | Should -BeFalse
        }
        It 'allows a push of main to a FORK remote (a different NAME and a different URL)' {
            $r = Resolve-PushToMainGuard -RemoteName 'fork' -RemoteUrl 'https://example.com/fork.git' `
                -OriginUrl $script:GuardOriginUrl `
                -PushSpecLines @((New-PushSpecLine -RemoteRef 'refs/heads/main')) -OverrideReason ''
            $r.Decision | Should -BeExactly 'allow'
            $r.IsOrigin | Should -BeFalse
        }
    }

    Context 'allow-with-override (+ audit line written)' {
        It 'allows the push to origin/main when a non-empty reason is set, and marks it overridden' {
            $r = Resolve-PushToMainGuard -RemoteName 'origin' -RemoteUrl $script:GuardOriginUrl `
                -OriginUrl $script:GuardOriginUrl `
                -PushSpecLines @((New-PushSpecLine -RemoteRef 'refs/heads/main')) `
                -OverrideReason 'deliberate one-off: ship the v1.18.1 hotfix'
            $r.Decision | Should -BeExactly 'allow'
            $r.Blocks | Should -BeTrue        # it WOULD refuse...
            $r.Overridden | Should -BeTrue    # ...but the explicit reason flips it to allow
        }
        It 'does NOT override on an unset / empty / whitespace-only reason (the refusal stands)' {
            foreach ($reason in @('', '   ', "`t")) {
                $r = Resolve-PushToMainGuard -RemoteName 'origin' -RemoteUrl $script:GuardOriginUrl `
                    -OriginUrl $script:GuardOriginUrl `
                    -PushSpecLines @((New-PushSpecLine -RemoteRef 'refs/heads/main')) -OverrideReason $reason
                $r.Decision | Should -BeExactly 'refuse' -Because "reason '$reason' is empty-ish and must not override"
            }
        }
        It 'writes an audit line (UTC time, reason, sha, target ref) to the bypass log' {
            $log = Join-Path $TestDrive ('bypass-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.log')
            $line = Add-PushToMainAuditLine -Path $log -Reason 'ship v1.18.1 hotfix' `
                -Sha 'aaaa111122223333' -TargetRef 'refs/heads/main' -RemoteName 'origin'
            Test-Path -LiteralPath $log | Should -BeTrue
            $written = Get-Content -LiteralPath $log -Raw
            $written | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z'   # leading UTC timestamp
            $written | Should -Match 'OVERRIDE'
            $written | Should -Match 'ship v1\.18\.1 hotfix'                   # reason
            $written | Should -Match 'aaaa111122223333'                        # sha
            $written | Should -Match 'origin refs/heads/main'                  # remote + target ref
            $line | Should -BeExactly ($written.TrimEnd("`r", "`n"))           # returns exactly what it wrote
        }
        It 'appends (never overwrites) and flattens a multi-line reason to ONE record (no log forging)' {
            $log = Join-Path $TestDrive ('bypass-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.log')
            Add-PushToMainAuditLine -Path $log -Reason 'first push' -Sha 'sha1' -TargetRef 'refs/heads/main' -RemoteName 'origin' | Out-Null
            # A newline in the reason must NOT forge a second audit record.
            Add-PushToMainAuditLine -Path $log -Reason "second push`ninjected-second-line" -Sha 'sha2' -TargetRef 'refs/heads/main' -RemoteName 'origin' | Out-Null
            $lines = @(Get-Content -LiteralPath $log | Where-Object { $_ -ne '' })
            $lines.Count | Should -Be 2
            $lines[1] | Should -Match 'second push injected-second-line'       # flattened onto one line
        }
    }

    Context 'audit log path resolution' {
        It 'honors the POWERSHELL_LSP_PUSH_AUDIT_LOG override path verbatim' {
            Get-PushAuditLogPath -GitCommonDir '/x/.git' -OverridePath '/tmp/custom-bypass.log' |
                Should -BeExactly '/tmp/custom-bypass.log'
        }
        It 'defaults to the bypass log inside the git common dir when no override is set' {
            Get-PushAuditLogPath -GitCommonDir '/x/.git' -OverridePath '' |
                Should -Match 'powershell-lsp-push-to-main-bypass\.log$'
        }
    }
}
