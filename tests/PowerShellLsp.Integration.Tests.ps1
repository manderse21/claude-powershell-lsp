#Requires -Version 5.1

# Integration regression tests (Pester 5): drive the REAL daemon end to end.
# Needs PSES + PSScriptAnalyzer bootstrapped (the BeforeAll does it idempotently)
# and named pipes. Runs on Windows, Linux, and macOS (named pipes map to Unix domain
# sockets on .NET); only genuinely unsupported platforms are skipped -- see the
# discovery-time gate below.

# Discovery-time platform gate for -Skip (StrictMode-safe; PS 5.1 has no $IsWindows/$IsLinux).
# Integration runs on Windows, Linux, and macOS; other platforms stay skipped.
$script:OnWindows = if (Test-Path 'Variable:\IsWindows') { [bool]$IsWindows } else { $true }
$script:OnLinux = (Test-Path 'Variable:\IsLinux') -and [bool]$IsLinux
$script:OnMacOS = (Test-Path 'Variable:\IsMacOS') -and [bool]$IsMacOS
$script:SkipIntegration = -not ($script:OnWindows -or $script:OnLinux -or $script:OnMacOS)

Describe 'Integration: warm-start daemon (Windows + Linux + macOS)' -Skip:$script:SkipIntegration {

    BeforeAll {
        # Shared helpers (Add-ProcessArguments is cross-version: ArgumentList on
        # pwsh, quoted .Arguments on Windows PowerShell 5.1).
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')

        # Helpers must be defined in the run phase (a top-level function would only
        # exist during discovery and be invisible here). Defined in BeforeAll, they
        # are available to this block and every It below it.
        function Invoke-PluginHook {
            param([string]$ScriptPath, [string]$StdinJson, [string[]]$ExtraArgs, [int]$CapMs, [string]$DataRoot)
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'pwsh'; $psi.UseShellExecute = $false
            $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            Add-ProcessArguments $psi (@(@('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + @($ExtraArgs)) | Where-Object { $_ })
            $psi.EnvironmentVariables['CLAUDE_PLUGIN_DATA'] = $DataRoot
            $p = [System.Diagnostics.Process]::Start($psi)
            $stdoutTask = $p.StandardOutput.ReadToEndAsync()
            if ($StdinJson) {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($StdinJson)   # no BOM
                $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
                $p.StandardInput.BaseStream.Flush()
            }
            $p.StandardInput.Close()
            $script:LastHookExit = $null   # Track A fail-safe test reads the hook's exit code
            if (-not $p.WaitForExit($CapMs)) { try { $p.Kill($true) } catch { }; return '' }
            $script:LastHookExit = $p.ExitCode
            [void]$stdoutTask.Wait(1500)
            if ($stdoutTask.IsCompleted) { return $stdoutTask.Result } else { return '' }
        }

        $script:ScriptsDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts'
        # DataDir is a throwaway scratch root. Default: a temp subdir (local runs
        # unchanged). CI sets PSLS_TEST_DATA_DIR to a workspace path so the warm
        # daemon's logs land somewhere the workflow can upload as a diagnostic
        # artifact (essential for debugging the cross-platform bring-up).
        $script:DataDir = if (-not [string]::IsNullOrWhiteSpace($env:PSLS_TEST_DATA_DIR)) {
            $env:PSLS_TEST_DATA_DIR
        } else {
            Join-Path ([System.IO.Path]::GetTempPath()) 'psls-pester-data'
        }
        $script:Sid = 'pester-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $script:DataDir | Out-Null
        $env:CLAUDE_PLUGIN_DATA = $script:DataDir

        # Idempotent bootstrap of PSES + pinned PSSA (no-op if already present).
        & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:ScriptsDir 'ensure-pses.ps1') 2>&1 | Out-Null
        & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:ScriptsDir 'ensure-pssa.ps1') 2>&1 | Out-Null

        # Launch the daemon for this session via the real SessionStart hook.
        Invoke-PluginHook -ScriptPath (Join-Path $script:ScriptsDir 'session-start.ps1') `
            -StdinJson (@{ session_id = $script:Sid } | ConvertTo-Json -Compress) `
            -ExtraArgs @('-PreferredHost', 'pwsh') -CapMs 60000 -DataRoot $script:DataDir | Out-Null

        $sf = Join-Path $script:DataDir ('session/' + $script:Sid + '.json')
        $script:DaemonInfo = $null
        for ($i = 0; $i -lt 40; $i++) {
            if (Test-Path $sf) { $o = Get-Content $sf -Raw | ConvertFrom-Json; if ($o.state -eq 'ready') { $script:DaemonInfo = $o; break } }
            Start-Sleep -Milliseconds 500
        }
    }

    AfterAll {
        if ($null -ne $script:DaemonInfo) {
            foreach ($pidVal in @($script:DaemonInfo.pid, $script:DaemonInfo.psesPid)) {
                if ($pidVal) { Stop-Process -Id $pidVal -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    It 'brings up exactly one ready daemon' {
        $script:DaemonInfo | Should -Not -BeNullOrEmpty
        (Get-Process -Id $script:DaemonInfo.pid -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }

    It 'returns the PSScriptAnalyzer diagnostic, not the early parser publish (settled publish)' {
        # Fixture trips PSUseApprovedVerbs -- a PSSA rule PSES does NOT emit from
        # the parser pass. Getting it back proves the daemon waited for the
        # settled analyzer publish.
        $fix = Join-Path $script:DataDir 'pester-pssa-fixture.ps1'
        "function Frobnicate-Pester {`n    Get-Process`n}" | Set-Content -LiteralPath $fix -Encoding ascii
        $out = Invoke-PluginHook -ScriptPath (Join-Path $script:ScriptsDir 'lsp-client.ps1') `
            -StdinJson (@{ session_id = $script:Sid; tool_input = @{ file_path = $fix }; cwd = $script:DataDir } | ConvertTo-Json -Compress) `
            -ExtraArgs @() -CapMs 9000 -DataRoot $script:DataDir
        $out | Should -Match 'PSUseApprovedVerbs'
    }

    It 'surfaces the PSSA suggested fix text for a fixable finding (Track C)' {
        # An alias use trips PSAvoidUsingCmdletAliases, which carries a
        # SuggestedCorrection. The daemon's codeAction pass should thread the fix
        # ('Get-ChildItem') into the feedback block as a 'fix:' line.
        $fix = Join-Path $script:DataDir 'pester-alias-fixture.ps1'
        'gci' | Set-Content -LiteralPath $fix -Encoding ascii
        $out = Invoke-PluginHook -ScriptPath (Join-Path $script:ScriptsDir 'lsp-client.ps1') `
            -StdinJson (@{ session_id = $script:Sid; tool_input = @{ file_path = $fix }; cwd = $script:DataDir } | ConvertTo-Json -Compress) `
            -ExtraArgs @() -CapMs 9000 -DataRoot $script:DataDir
        $out | Should -Match 'PSAvoidUsingCmdletAliases'
        $out | Should -Match 'fix: Get-ChildItem'
    }

    It 'surfaces a syntax error via the in-process parser with zero pipe call (Track B)' {
        # Broken file written to scratch (NOT the repo tree -- the repo ASCII/parse
        # unit test would fail on a deliberately broken .ps1). Use a session id with
        # NO daemon: if a result still appears it came from the in-process parser
        # pre-pass, proving the daemon round-trip was skipped (no daemon could have
        # answered).
        $broken = Join-Path $script:DataDir 'pester-broken-fixture.ps1'
        "function Test-Broken {`n    Get-Process" | Set-Content -LiteralPath $broken -Encoding ascii   # unclosed brace
        $noDaemonSid = 'no-daemon-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $out = Invoke-PluginHook -ScriptPath (Join-Path $script:ScriptsDir 'lsp-client.ps1') `
            -StdinJson (@{ session_id = $noDaemonSid; tool_input = @{ file_path = $broken }; cwd = $script:DataDir } | ConvertTo-Json -Compress) `
            -ExtraArgs @() -CapMs 9000 -DataRoot $script:DataDir
        $out | Should -Match 'PowerShell diagnostics'
        $out | Should -Match '\(parser\)'
    }

    It 'telemetry is additive: PostToolUse feedback is byte-identical with stats ON vs OFF (Track A)' {
        # The load-bearing invariant: turning stats on must not change a single byte
        # of the FEEDBACK delivered to Claude (hookSpecificOutput.additionalContext).
        # Prime the daemon cache for one fixed file, then run the client twice over
        # identical content (both cache-hits) -- once with enableStats off, once on --
        # and compare the additionalContext EXACTLY. (The raw JSON wrapper's key order
        # is a pre-existing, per-process ConvertTo-Json artifact independent of
        # telemetry -- it differs run to run regardless -- so the assertion is on the
        # feedback payload, not the wrapper bytes.) To keep it honest, also assert the
        # ON run actually WROTE a stats line (else "identical" would be vacuous) and the
        # OFF run wrote nothing.
        $fix = Join-Path $script:DataDir 'pester-additive-fixture.ps1'
        'gci' | Set-Content -LiteralPath $fix -Encoding ascii   # PSAvoidUsingCmdletAliases (+ a fix)
        $stdin = (@{ session_id = $script:Sid; tool_input = @{ file_path = $fix }; cwd = $script:DataDir } | ConvertTo-Json -Compress)
        $statsFile = Join-Path $script:DataDir 'logs/stats.jsonl'
        $clientPath = Join-Path $script:ScriptsDir 'lsp-client.ps1'
        $countLines = { param($f) if (Test-Path -LiteralPath $f) { @(Get-Content -LiteralPath $f).Count } else { 0 } }

        try {
            # Prime (populate the daemon cache for this content); stats off.
            $env:CLAUDE_PLUGIN_OPTION_enableStats = 'false'
            Invoke-PluginHook -ScriptPath $clientPath -StdinJson $stdin -ExtraArgs @() -CapMs 9000 -DataRoot $script:DataDir | Out-Null

            # OFF run.
            $beforeOff = & $countLines $statsFile
            $offOut = Invoke-PluginHook -ScriptPath $clientPath -StdinJson $stdin -ExtraArgs @() -CapMs 9000 -DataRoot $script:DataDir
            $afterOff = & $countLines $statsFile

            # ON run (identical content -> still a cache-hit -> identical emit).
            $env:CLAUDE_PLUGIN_OPTION_enableStats = 'true'
            $beforeOn = & $countLines $statsFile
            $onOut = Invoke-PluginHook -ScriptPath $clientPath -StdinJson $stdin -ExtraArgs @() -CapMs 9000 -DataRoot $script:DataDir
            $afterOn = & $countLines $statsFile
        } finally {
            Remove-Item -LiteralPath 'Env:CLAUDE_PLUGIN_OPTION_enableStats' -ErrorAction SilentlyContinue
        }

        $offCtx = ($offOut | ConvertFrom-Json).hookSpecificOutput.additionalContext
        $onCtx = ($onOut | ConvertFrom-Json).hookSpecificOutput.additionalContext
        $offCtx | Should -Match 'PSAvoidUsingCmdletAliases'   # the run actually produced the emit
        $onCtx | Should -BeExactly $offCtx                    # feedback byte-identical (telemetry is additive)
        $afterOff | Should -Be $beforeOff                     # OFF wrote no stats line
        $afterOn | Should -Be ($beforeOn + 1)                 # ON wrote exactly one
    }

    It 'telemetry is fail-safe: a forced stats-write failure still emits the diagnostic and exits 0 (Track A)' {
        # Force the stats write to fail by squatting a DIRECTORY on the stats.jsonl
        # path, then run the client with stats ON. The diagnostic must still emit and
        # the hook must still exit 0 -- telemetry is best-effort, off the hot path.
        $logDir = Join-Path $script:DataDir 'logs'
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
        $statsPath = Join-Path $logDir 'stats.jsonl'
        if (Test-Path -LiteralPath $statsPath) { Remove-Item -LiteralPath $statsPath -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Force -Path $statsPath | Out-Null   # squat the path -> every write fails

        $fix = Join-Path $script:DataDir 'pester-failsafe-fixture.ps1'
        "function Frobnicate-Failsafe {`n    Get-Process`n}" | Set-Content -LiteralPath $fix -Encoding ascii   # PSUseApprovedVerbs
        try {
            $env:CLAUDE_PLUGIN_OPTION_enableStats = 'true'
            $out = Invoke-PluginHook -ScriptPath (Join-Path $script:ScriptsDir 'lsp-client.ps1') `
                -StdinJson (@{ session_id = $script:Sid; tool_input = @{ file_path = $fix }; cwd = $script:DataDir } | ConvertTo-Json -Compress) `
                -ExtraArgs @() -CapMs 9000 -DataRoot $script:DataDir
            $exit = $script:LastHookExit
        } finally {
            Remove-Item -LiteralPath 'Env:CLAUDE_PLUGIN_OPTION_enableStats' -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $statsPath -Recurse -Force -ErrorAction SilentlyContinue   # unsquat for later tests
        }

        $out | Should -Match 'PSUseApprovedVerbs'   # diagnostic still emitted despite the write failure
        $exit | Should -Be 0                         # and the hook still exited 0
    }

    It 'shuts down cleanly on SessionEnd with no orphaned daemon or PSES' {
        $daemonPid = $script:DaemonInfo.pid
        $psesPid = $script:DaemonInfo.psesPid
        Invoke-PluginHook -ScriptPath (Join-Path $script:ScriptsDir 'session-end.ps1') `
            -StdinJson (@{ session_id = $script:Sid } | ConvertTo-Json -Compress) `
            -ExtraArgs @() -CapMs 8000 -DataRoot $script:DataDir | Out-Null
        Start-Sleep -Seconds 3
        (Get-Process -Id $daemonPid -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
        (Get-Process -Id $psesPid -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
        (Test-Path (Join-Path $script:DataDir ('session/' + $script:Sid + '.json'))) | Should -BeFalse
        $script:DaemonInfo = $null   # mark handled so AfterAll does not double-reap
    }
}

Describe 'Integration: honor PSScriptAnalyzerSettings.psd1 (dispatch 000018)' -Skip:$script:SkipIntegration {
    # The load-bearing adversarial pair (mirrors 000014's RED/GREEN control): a file
    # violating ONLY a rule the repo settings exclude must produce NO diagnostic for
    # that rule (GREEN) -- and the SAME file with NO settings honored must show it
    # (RED). Plus: a non-excluded rule still fires (we did not silence everything), an
    # explicit ABSOLUTE settingsPath override is applied, and the no-settings case is
    # unchanged from default. Each scenario gets its OWN warm daemon: settings resolve
    # lazily-from-first-file and lock per session (Track 1: PSES applies them
    # per-session, one analysis engine), so honoring cannot be toggled within one daemon.
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')

        function Invoke-PluginHook {
            param([string]$ScriptPath, [string]$StdinJson, [string[]]$ExtraArgs, [int]$CapMs, [string]$DataRoot, [hashtable]$ExtraEnv)
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'pwsh'; $psi.UseShellExecute = $false
            $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            Add-ProcessArguments $psi (@(@('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + @($ExtraArgs)) | Where-Object { $_ })
            $psi.EnvironmentVariables['CLAUDE_PLUGIN_DATA'] = $DataRoot
            if ($ExtraEnv) { foreach ($k in $ExtraEnv.Keys) { $psi.EnvironmentVariables[$k] = [string]$ExtraEnv[$k] } }
            $p = [System.Diagnostics.Process]::Start($psi)
            $stdoutTask = $p.StandardOutput.ReadToEndAsync()
            if ($StdinJson) {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($StdinJson)
                $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length); $p.StandardInput.BaseStream.Flush()
            }
            $p.StandardInput.Close()
            if (-not $p.WaitForExit($CapMs)) { try { $p.Kill($true) } catch { }; return '' }
            [void]$stdoutTask.Wait(1500)
            if ($stdoutTask.IsCompleted) { return $stdoutTask.Result } else { return '' }
        }

        $script:H_ScriptsDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts'
        # Share the warm-start block's data root so PSES/PSSA bootstrap is a no-op here
        # (no second download per CI leg). Fixtures live in a dedicated subtree and
        # session ids are unique, so daemons never collide; we never delete this root.
        $script:H_Data = if (-not [string]::IsNullOrWhiteSpace($env:PSLS_TEST_DATA_DIR)) {
            $env:PSLS_TEST_DATA_DIR
        } else {
            Join-Path ([System.IO.Path]::GetTempPath()) 'psls-pester-data'
        }
        New-Item -ItemType Directory -Force -Path $script:H_Data | Out-Null
        $env:CLAUDE_PLUGIN_DATA = $script:H_Data
        $script:H_Fixtures = Join-Path $script:H_Data 'honor-000018'
        if (Test-Path -LiteralPath $script:H_Fixtures) { Remove-Item -LiteralPath $script:H_Fixtures -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Force -Path $script:H_Fixtures | Out-Null

        # Idempotent bootstrap of PSES + pinned PSSA (no-op if the other block did it).
        & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:H_ScriptsDir 'ensure-pses.ps1') 2>&1 | Out-Null
        & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:H_ScriptsDir 'ensure-pssa.ps1') 2>&1 | Out-Null

        # Shared fixture content (identical bytes for GREEN and RED -- the ONLY
        # difference is whether settings are honored): gci -> PSAvoidUsingCmdletAliases
        # (the EXCLUDED rule -- it reliably fires in the PSES default ruleset, unlike
        # PSAvoidUsingWriteHost which PSES's own default already drops); Frobnicate- ->
        # PSUseApprovedVerbs (the non-excluded sentinel that proves analysis ran).
        $script:DualContent = "function Frobnicate-Thing {`n    gci`n}"
        $excludeAliases = "@{ ExcludeRules = @('PSAvoidUsingCmdletAliases') }"

        # GREEN project: a settings file that excludes PSAvoidUsingCmdletAliases.
        $script:GreenDir = Join-Path $script:H_Fixtures 'proj-green'
        New-Item -ItemType Directory -Force -Path $script:GreenDir | Out-Null
        Set-Content -LiteralPath (Join-Path $script:GreenDir 'PSScriptAnalyzerSettings.psd1') -Value $excludeAliases -Encoding ascii
        $script:GreenFile = Join-Path $script:GreenDir 'green.ps1'
        Set-Content -LiteralPath $script:GreenFile -Value $script:DualContent -Encoding ascii

        # RED / no-config project: NO settings file anywhere in the walk-up.
        $script:RedDir = Join-Path $script:H_Fixtures 'proj-red'
        New-Item -ItemType Directory -Force -Path $script:RedDir | Out-Null
        $script:RedFile = Join-Path $script:RedDir 'red.ps1'
        Set-Content -LiteralPath $script:RedFile -Value $script:DualContent -Encoding ascii

        # OVERRIDE: a settings file OUTSIDE the fixture's walk path, pointed at by the
        # settingsPath option. Fixture trips an alias rule (kept) + Write-Host (excluded).
        $script:OvrCfg = Join-Path (Join-Path $script:H_Fixtures 'cfg-elsewhere') 'PSScriptAnalyzerSettings.psd1'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:OvrCfg) | Out-Null
        Set-Content -LiteralPath $script:OvrCfg -Value $excludeAliases -Encoding ascii
        $script:OvrDir = Join-Path $script:H_Fixtures 'proj-override'
        New-Item -ItemType Directory -Force -Path $script:OvrDir | Out-Null
        $script:OvrFile = Join-Path $script:OvrDir 'ovr.ps1'
        Set-Content -LiteralPath $script:OvrFile -Value "function Frobnicate-Ovr {`n    gci`n}" -Encoding ascii

        function Start-HonorDaemon {
            param([string]$Sid, [hashtable]$ExtraEnv)
            Invoke-PluginHook -ScriptPath (Join-Path $script:H_ScriptsDir 'session-start.ps1') `
                -StdinJson (@{ session_id = $Sid } | ConvertTo-Json -Compress) `
                -ExtraArgs @('-PreferredHost', 'pwsh') -CapMs 60000 -DataRoot $script:H_Data -ExtraEnv $ExtraEnv | Out-Null
        }
        function Wait-HonorDaemon {
            param([string]$Sid)
            $sf = Join-Path $script:H_Data ('session/' + $Sid + '.json')
            for ($i = 0; $i -lt 60; $i++) {
                if (Test-Path $sf) { $o = Get-Content $sf -Raw | ConvertFrom-Json; if ($o.state -eq 'ready') { return $o } }
                Start-Sleep -Milliseconds 500
            }
            return $null
        }
        # Raise the CLIENT hard cap for these calls: the FIRST analyzed file pushes the
        # settings and PSES rebuilds its analysis engine, which can exceed the 5s default.
        function Get-HonorDiag {
            param([string]$Sid, [string]$File, [string]$Cwd)
            Invoke-PluginHook -ScriptPath (Join-Path $script:H_ScriptsDir 'lsp-client.ps1') `
                -StdinJson (@{ session_id = $Sid; tool_input = @{ file_path = $File }; cwd = $Cwd } | ConvertTo-Json -Compress) `
                -ExtraArgs @() -CapMs 25000 -DataRoot $script:H_Data -ExtraEnv @{ CLAUDE_PLUGIN_OPTION_timeoutMs = '18000' }
        }

        $script:GreenSid = 'honor-green-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:RedSid = 'honor-red-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:OvrSid = 'honor-ovr-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))

        # Launch all three detached, then wait -- overlaps the PSES warm-starts. GREEN
        # and RED carry an EMPTY settingsPath option (no override); OVERRIDE carries the
        # absolute path. Distinct session ids => distinct daemons (no cross-reap).
        Start-HonorDaemon -Sid $script:GreenSid -ExtraEnv @{ CLAUDE_PLUGIN_OPTION_settingsPath = '' }
        Start-HonorDaemon -Sid $script:RedSid -ExtraEnv @{ CLAUDE_PLUGIN_OPTION_settingsPath = '' }
        Start-HonorDaemon -Sid $script:OvrSid -ExtraEnv @{ CLAUDE_PLUGIN_OPTION_settingsPath = $script:OvrCfg }
        $script:GreenInfo = Wait-HonorDaemon -Sid $script:GreenSid
        $script:RedInfo = Wait-HonorDaemon -Sid $script:RedSid
        $script:OvrInfo = Wait-HonorDaemon -Sid $script:OvrSid
    }

    AfterAll {
        foreach ($info in @($script:GreenInfo, $script:RedInfo, $script:OvrInfo)) {
            if ($null -ne $info) {
                foreach ($pidVal in @($info.pid, $info.psesPid)) {
                    if ($pidVal) { Stop-Process -Id $pidVal -Force -ErrorAction SilentlyContinue }
                }
            }
        }
        # Clean only OUR fixtures + session files -- never the shared data root (it
        # holds the bootstrapped PSES/PSSA bundle reused across runs).
        foreach ($sid in @($script:GreenSid, $script:RedSid, $script:OvrSid)) {
            $sf = Join-Path $script:H_Data ('session/' + $sid + '.json')
            if (Test-Path -LiteralPath $sf) { Remove-Item -LiteralPath $sf -Force -ErrorAction SilentlyContinue }
        }
        if (Test-Path -LiteralPath $script:H_Fixtures) { Remove-Item -LiteralPath $script:H_Fixtures -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'GREEN: a rule excluded by PSScriptAnalyzerSettings.psd1 is suppressed, and a non-excluded rule still fires' {
        $script:GreenInfo | Should -Not -BeNullOrEmpty
        $out = Get-HonorDiag -Sid $script:GreenSid -File $script:GreenFile -Cwd $script:GreenDir
        $out | Should -Match 'PSUseApprovedVerbs'              # NOT excluded -> still fires (we did not silence everything)
        $out | Should -Not -Match 'PSAvoidUsingCmdletAliases'  # excluded by the repo settings -> suppressed
    }

    It 'RED control: the SAME file with NO settings honored shows the excluded rule (honoring is load-bearing)' {
        $script:RedInfo | Should -Not -BeNullOrEmpty
        $out = Get-HonorDiag -Sid $script:RedSid -File $script:RedFile -Cwd $script:RedDir
        $out | Should -Match 'PSAvoidUsingCmdletAliases'    # reappears without honoring -> RED to GREEN's absence
    }

    It 'explicit absolute settingsPath override is applied (points PSES at a settings file elsewhere)' {
        $script:OvrInfo | Should -Not -BeNullOrEmpty
        $out = Get-HonorDiag -Sid $script:OvrSid -File $script:OvrFile -Cwd $script:OvrDir
        $out | Should -Match 'PSUseApprovedVerbs'              # analysis ran (verb rule not excluded)
        $out | Should -Not -Match 'PSAvoidUsingCmdletAliases'  # excluded via the override settings file
    }

    It 'no-config non-regression: with no settings and no override, default diagnostics are unchanged' {
        # The RED daemon honors nothing; the default rules must fire -- nothing is
        # silently suppressed, so behavior matches the pre-honoring default.
        $out = Get-HonorDiag -Sid $script:RedSid -File $script:RedFile -Cwd $script:RedDir
        $out | Should -Match 'PSAvoidUsingCmdletAliases'
        $out | Should -Match 'PSUseApprovedVerbs'
    }
}

Describe 'Integration: edit-range diagnostic scoping (dispatch 000019)' -Skip:$script:SkipIntegration {
    # End-to-end over the REAL daemon with a REAL PostToolUse payload carrying
    # tool_response.structuredPatch. The adversarial control mirrors 000018: a file with
    # one diagnostic INSIDE the edited range (gci on the last line -> PSAvoidUsingCmdletAliases)
    # and one OUTSIDE it (an unapproved-verb function at the top -> PSUseApprovedVerbs). With
    # scoping on and the patch on the gci line, only the in-range rule surfaces; turning
    # scoping off makes the out-of-range rule reappear (RED-on-revert). Plus: fail open on a
    # string/empty tool_response, and the surfaced-vs-total telemetry.
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')

        function Invoke-PluginHook {
            param([string]$ScriptPath, [string]$StdinJson, [string[]]$ExtraArgs, [int]$CapMs, [string]$DataRoot, [hashtable]$ExtraEnv)
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'pwsh'; $psi.UseShellExecute = $false
            $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            Add-ProcessArguments $psi (@(@('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + @($ExtraArgs)) | Where-Object { $_ })
            $psi.EnvironmentVariables['CLAUDE_PLUGIN_DATA'] = $DataRoot
            if ($ExtraEnv) { foreach ($k in $ExtraEnv.Keys) { $psi.EnvironmentVariables[$k] = [string]$ExtraEnv[$k] } }
            $p = [System.Diagnostics.Process]::Start($psi)
            $stdoutTask = $p.StandardOutput.ReadToEndAsync()
            if ($StdinJson) {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($StdinJson)
                $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length); $p.StandardInput.BaseStream.Flush()
            }
            $p.StandardInput.Close()
            if (-not $p.WaitForExit($CapMs)) { try { $p.Kill($true) } catch { }; return '' }
            [void]$stdoutTask.Wait(1500)
            if ($stdoutTask.IsCompleted) { return $stdoutTask.Result } else { return '' }
        }

        $script:S_ScriptsDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts'
        $script:S_Data = if (-not [string]::IsNullOrWhiteSpace($env:PSLS_TEST_DATA_DIR)) {
            $env:PSLS_TEST_DATA_DIR
        } else {
            Join-Path ([System.IO.Path]::GetTempPath()) 'psls-pester-data'
        }
        New-Item -ItemType Directory -Force -Path $script:S_Data | Out-Null
        $env:CLAUDE_PLUGIN_DATA = $script:S_Data
        $script:S_Fixtures = Join-Path $script:S_Data 'scope-000019'
        if (Test-Path -LiteralPath $script:S_Fixtures) { Remove-Item -LiteralPath $script:S_Fixtures -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Force -Path $script:S_Fixtures | Out-Null

        & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:S_ScriptsDir 'ensure-pses.ps1') 2>&1 | Out-Null
        & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:S_ScriptsDir 'ensure-pssa.ps1') 2>&1 | Out-Null

        # Fixture: unapproved-verb function (line 1 -> PSUseApprovedVerbs, OUT of range)
        # and an alias on the LAST line (line 11 -> PSAvoidUsingCmdletAliases, IN range).
        # Comment padding between keeps the two findings far apart with nothing else firing.
        $script:S_File = Join-Path $script:S_Fixtures 'scope.ps1'
        $lines = @(
            'function Frobnicate-Thing {',
            '    Get-Process',
            '}',
            '# padding', '# padding', '# padding', '# padding', '# padding', '# padding', '# padding',
            'gci')
        Set-Content -LiteralPath $script:S_File -Value ($lines -join "`n") -Encoding ascii
        $script:S_GciLine = 11

        # structuredPatch as the PostToolUse tool_response would carry it: the edit
        # touched only the gci line (newStart = 11, newLines = 1).
        $script:S_Patch = @(@{ oldStart = 11; oldLines = 1; newStart = $script:S_GciLine; newLines = 1; lines = @('-gci', '+gci') })

        function New-ScopeStdin {
            # Build a PostToolUse payload. $Patch present -> tool_response with that patch;
            # $ErrString set -> a STRING tool_response (a failed edit); neither -> an EMPTY
            # patch (a Write that created a new file). Depth 8: structuredPatch nests deep.
            param($Patch, [string]$ErrString)
            $tr = if (-not [string]::IsNullOrEmpty($ErrString)) { $ErrString }
                  elseif ($null -ne $Patch) { @{ filePath = $script:S_File; structuredPatch = $Patch } }
                  else { @{ type = 'create'; filePath = $script:S_File; structuredPatch = @() } }
            return (@{ session_id = $script:S_Sid; tool_input = @{ file_path = $script:S_File }; cwd = $script:S_Fixtures; tool_response = $tr } | ConvertTo-Json -Depth 8 -Compress)
        }
        function Get-ScopeDiag {
            param($Patch, [string]$ErrString, [hashtable]$ExtraEnv = @{ })
            Invoke-PluginHook -ScriptPath (Join-Path $script:S_ScriptsDir 'lsp-client.ps1') `
                -StdinJson (New-ScopeStdin -Patch $Patch -ErrString $ErrString) `
                -ExtraArgs @() -CapMs 25000 -DataRoot $script:S_Data `
                -ExtraEnv (@{ CLAUDE_PLUGIN_OPTION_timeoutMs = '18000' } + $ExtraEnv)
        }

        $script:S_Sid = 'scope-000019-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
        Invoke-PluginHook -ScriptPath (Join-Path $script:S_ScriptsDir 'session-start.ps1') `
            -StdinJson (@{ session_id = $script:S_Sid } | ConvertTo-Json -Compress) `
            -ExtraArgs @('-PreferredHost', 'pwsh') -CapMs 60000 -DataRoot $script:S_Data -ExtraEnv @{ } | Out-Null
        $sf = Join-Path $script:S_Data ('session/' + $script:S_Sid + '.json')
        $script:S_Info = $null
        for ($i = 0; $i -lt 60; $i++) {
            if (Test-Path $sf) { $o = Get-Content $sf -Raw | ConvertFrom-Json; if ($o.state -eq 'ready') { $script:S_Info = $o; break } }
            Start-Sleep -Milliseconds 500
        }
    }

    AfterAll {
        if ($null -ne $script:S_Info) {
            foreach ($pidVal in @($script:S_Info.pid, $script:S_Info.psesPid)) {
                if ($pidVal) { Stop-Process -Id $pidVal -Force -ErrorAction SilentlyContinue }
            }
        }
        $sf = Join-Path $script:S_Data ('session/' + $script:S_Sid + '.json')
        if (Test-Path -LiteralPath $sf) { Remove-Item -LiteralPath $sf -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $script:S_Fixtures) { Remove-Item -LiteralPath $script:S_Fixtures -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'brings up the daemon for the scoping session' {
        $script:S_Info | Should -Not -BeNullOrEmpty
    }

    It 'GREEN: scoping on + a patch on the gci line surfaces only the in-range rule' {
        # scopeToEdit defaults ON. The edit touched line 11 (gci) -> only
        # PSAvoidUsingCmdletAliases (line 11) surfaces; PSUseApprovedVerbs (line 1) is
        # filtered as out-of-range.
        $out = Get-ScopeDiag -Patch $script:S_Patch -ExtraEnv @{ }
        $out | Should -Match 'PSAvoidUsingCmdletAliases'
        $out | Should -Not -Match 'PSUseApprovedVerbs'
    }

    It 'RED on revert: scopeToEdit=off surfaces the whole file again (the out-of-range rule reappears)' {
        # Same payload, scoping OFF -> both rules surface (byte-for-byte the pre-000019
        # whole-file behavior). This is the adversarial control: the GREEN above is only
        # meaningful because this RED proves the out-of-range rule was really there.
        $out = Get-ScopeDiag -Patch $script:S_Patch -ExtraEnv @{ CLAUDE_PLUGIN_OPTION_scopeToEdit = 'false' }
        $out | Should -Match 'PSAvoidUsingCmdletAliases'
        $out | Should -Match 'PSUseApprovedVerbs'
    }

    It 'FAIL OPEN: a string tool_response (a failed edit) surfaces the whole file' {
        # Scoping on, but the tool_response is a string error -> indeterminate range ->
        # everything surfaces. A scoping failure must never hide a diagnostic.
        $out = Get-ScopeDiag -ErrString 'Error: String to replace not found in file.' -ExtraEnv @{ }
        $out | Should -Match 'PSAvoidUsingCmdletAliases'
        $out | Should -Match 'PSUseApprovedVerbs'
    }

    It 'FAIL OPEN: an empty structuredPatch (a Write that created the file) surfaces the whole file' {
        # Scoping on, empty patch (a create IS the whole file) -> whole-file, never
        # scoped to nothing.
        $out = Get-ScopeDiag -ExtraEnv @{ }   # no patch, no err -> empty structuredPatch
        $out | Should -Match 'PSAvoidUsingCmdletAliases'
        $out | Should -Match 'PSUseApprovedVerbs'
    }

    It 'telemetry records surfaced-vs-total so the noise reduction is measurable' {
        # With stats on and scoping applied, the stats line records scopeApplied=true and
        # scopeSurfaced < scopeTotal (1 surfaced of 2 whole-file candidates).
        $statsFile = Join-Path $script:S_Data 'logs/stats.jsonl'
        $before = if (Test-Path -LiteralPath $statsFile) { @(Get-Content -LiteralPath $statsFile).Count } else { 0 }
        Get-ScopeDiag -Patch $script:S_Patch -ExtraEnv @{ CLAUDE_PLUGIN_OPTION_enableStats = 'true' } | Out-Null
        @(Get-Content -LiteralPath $statsFile).Count | Should -BeGreaterThan $before
        $last = (@(Get-Content -LiteralPath $statsFile))[-1] | ConvertFrom-Json
        $last.scopeApplied | Should -BeTrue
        [int]$last.scopeSurfaced | Should -Be 1            # only gci is on the edited line
        [int]$last.scopeTotal | Should -BeGreaterThan 1    # >= the verb + alias whole-file candidates
        [int]$last.scopeSurfaced | Should -BeLessThan ([int]$last.scopeTotal)
    }
}
