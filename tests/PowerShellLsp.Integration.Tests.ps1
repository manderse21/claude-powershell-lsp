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

Describe 'Integration: supervised restart + incomplete/degraded status (dispatch 000022)' -Skip:$script:SkipIntegration {
    # Proves the three live behaviors the audit graded untested:
    #   (a) a mid-session PSES child exit is RECOVERED by a bounded daemon-side re-spawn,
    #       and a subsequent request returns a real diagnostic (R1 + R2-fatal);
    #   (b) a non-settling pass returns a VISIBLE 'incomplete' status end-to-end through the
    #       client -- never empty/clean (the Spine-1 false-clean);
    #   (d) a PSSA-absent daemon comes up without crashing and surfaces a VISIBLE parser-only
    #       'degraded' status (R6-surfaced).
    # (b) and (d) launch the daemon DIRECTLY so the test can force a daemon param the
    # shipping userConfig surface does not expose (-MaxWaitMs 1) and a data root with no
    # vendored PSSA -- without touching any user-facing default.
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

        # Launch pses-daemon.ps1 DIRECTLY (long-lived) with arbitrary args + env. Returns
        # the daemon Process. The daemon writes nothing to stdout/stderr (it logs to files);
        # we drain both streams asynchronously so their buffers never fill.
        function Start-RawDaemon {
            param([string]$Sid, [string]$DataRoot, [string[]]$ExtraArgs, [hashtable]$ExtraEnv)
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'pwsh'; $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
            $daemon = Join-Path $script:R_ScriptsDir 'pses-daemon.ps1'
            $argList = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $daemon,
                '-SessionId', $Sid, '-PsHost', 'pwsh', '-DataRoot', $DataRoot) + @($ExtraArgs)
            Add-ProcessArguments $psi ($argList | Where-Object { $_ })
            $psi.EnvironmentVariables['CLAUDE_PLUGIN_DATA'] = $DataRoot
            if ($ExtraEnv) { foreach ($k in $ExtraEnv.Keys) { $psi.EnvironmentVariables[$k] = [string]$ExtraEnv[$k] } }
            $p = [System.Diagnostics.Process]::Start($psi)
            $null = $p.StandardOutput.ReadToEndAsync()
            $null = $p.StandardError.ReadToEndAsync()
            return $p
        }

        function Wait-DaemonReady {
            param([string]$DataRoot, [string]$Sid, [int]$Tries = 80)
            $sf = Join-Path $DataRoot ('session/' + $Sid + '.json')
            for ($i = 0; $i -lt $Tries; $i++) {
                if (Test-Path $sf) {
                    $o = Get-Content $sf -Raw | ConvertFrom-Json
                    if ($o.state -eq 'ready') { return $o }
                }
                Start-Sleep -Milliseconds 500
            }
            return $null
        }

        $script:R_ScriptsDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts'
        # Share the warm-start block's data root so the PSES/PSSA bootstrap is a no-op.
        $script:R_Data = if (-not [string]::IsNullOrWhiteSpace($env:PSLS_TEST_DATA_DIR)) {
            $env:PSLS_TEST_DATA_DIR
        } else {
            Join-Path ([System.IO.Path]::GetTempPath()) 'psls-pester-data'
        }
        New-Item -ItemType Directory -Force -Path $script:R_Data | Out-Null
        $env:CLAUDE_PLUGIN_DATA = $script:R_Data

        & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:R_ScriptsDir 'ensure-pses.ps1') 2>&1 | Out-Null
        & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:R_ScriptsDir 'ensure-pssa.ps1') 2>&1 | Out-Null

        # (a) RESTART daemon -- launched via the real SessionStart hook (default params,
        # so MaxPsesRestarts = 3). We kill its PSES child mid-It and assert recovery.
        $script:R_SidA = 'restart-000022-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
        Invoke-PluginHook -ScriptPath (Join-Path $script:R_ScriptsDir 'session-start.ps1') `
            -StdinJson (@{ session_id = $script:R_SidA } | ConvertTo-Json -Compress) `
            -ExtraArgs @('-PreferredHost', 'pwsh') -CapMs 60000 -DataRoot $script:R_Data -ExtraEnv @{ } | Out-Null
        $script:R_InfoA = Wait-DaemonReady -DataRoot $script:R_Data -Sid $script:R_SidA

        # (b) INCOMPLETE daemon -- launched directly with -MaxWaitMs 1 so every pass returns
        # before any publish can settle (a deterministic non-settling pass).
        $script:R_SidB = 'incomplete-000022-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:R_ProcB = Start-RawDaemon -Sid $script:R_SidB -DataRoot $script:R_Data -ExtraArgs @('-MaxWaitMs', '1') -ExtraEnv @{ }
        $script:R_InfoB = Wait-DaemonReady -DataRoot $script:R_Data -Sid $script:R_SidB

        # (d) DEGRADED daemon -- launched directly against a FRESH data root that has NO
        # vendored PSSA (no modules/ dir), with PSES_BUNDLE_PATH pointed at the SHARED
        # bundle so PSES still launches. pssaAvailable resolves $false -> parser-only.
        $script:R_DataD = Join-Path ([System.IO.Path]::GetTempPath()) ('psls-degraded-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $script:R_DataD | Out-Null
        $script:R_BundleShared = Join-Path $script:R_Data 'PowerShellEditorServices'
        $script:R_SidD = 'degraded-000022-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:R_ProcD = Start-RawDaemon -Sid $script:R_SidD -DataRoot $script:R_DataD -ExtraArgs @() -ExtraEnv @{ PSES_BUNDLE_PATH = $script:R_BundleShared }
        $script:R_InfoD = Wait-DaemonReady -DataRoot $script:R_DataD -Sid $script:R_SidD

        # (e) EXHAUSTION daemon -- launched directly with -MaxPsesRestarts 0 so the FIRST
        # mid-session PSES exit spends the budget immediately. Proves the "never dies"
        # guarantee: on exhaustion the daemon does NOT exit -- it flips the session file to
        # 'degraded' and keeps serving 'incomplete'.
        $script:R_SidE = 'exhaust-000022-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:R_ProcE = Start-RawDaemon -Sid $script:R_SidE -DataRoot $script:R_Data -ExtraArgs @('-MaxPsesRestarts', '0') -ExtraEnv @{ }
        $script:R_InfoE = Wait-DaemonReady -DataRoot $script:R_Data -Sid $script:R_SidE
    }

    AfterAll {
        # Reap every daemon + its PSES child (by recorded pid, and the raw Process handles).
        $infos = @($script:R_InfoA, $script:R_InfoB, $script:R_InfoD, $script:R_InfoE)
        foreach ($info in $infos) {
            if ($null -ne $info) {
                foreach ($pidVal in @($info.pid, $info.psesPid)) {
                    if ($pidVal) { Stop-Process -Id ([int]$pidVal) -Force -ErrorAction SilentlyContinue }
                }
            }
        }
        foreach ($p in @($script:R_ProcB, $script:R_ProcD, $script:R_ProcE)) {
            try { if ($null -ne $p -and -not $p.HasExited) { $p.Kill($true) } } catch { }
        }
        foreach ($pair in @(@($script:R_Data, $script:R_SidA), @($script:R_Data, $script:R_SidB), @($script:R_DataD, $script:R_SidD), @($script:R_Data, $script:R_SidE))) {
            $sf = Join-Path $pair[0] ('session/' + $pair[1] + '.json')
            if (Test-Path -LiteralPath $sf) { Remove-Item -LiteralPath $sf -Force -ErrorAction SilentlyContinue }
        }
        if (Test-Path -LiteralPath $script:R_DataD) { Remove-Item -LiteralPath $script:R_DataD -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It '(a) recovers from a mid-session PSES exit: a subsequent request returns a real diagnostic (R1 + R2-fatal)' {
        $script:R_InfoA | Should -Not -BeNullOrEmpty
        $origPsesPid = [int]$script:R_InfoA.psesPid
        $origPsesPid | Should -BeGreaterThan 0
        (Get-Process -Id $origPsesPid -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty   # PSES alive pre-kill

        # Kill the PSES child mid-session. The daemon's idle loop must detect the exit and
        # re-spawn a fresh PSES (bounded), updating the session file's psesPid.
        Stop-Process -Id $origPsesPid -Force -ErrorAction SilentlyContinue

        $sf = Join-Path $script:R_Data ('session/' + $script:R_SidA + '.json')
        $newPsesPid = 0
        for ($i = 0; $i -lt 80; $i++) {
            Start-Sleep -Milliseconds 500
            if (Test-Path $sf) {
                $o = Get-Content $sf -Raw | ConvertFrom-Json
                $pp = [int](Get-Prop $o 'psesPid')
                if ($pp -gt 0 -and $pp -ne $origPsesPid) { $newPsesPid = $pp; break }
            }
        }
        $newPsesPid | Should -BeGreaterThan 0           # a NEW PSES was re-spawned (the daemon did not die)
        $newPsesPid | Should -Not -Be $origPsesPid
        $script:R_InfoA = Get-Content $sf -Raw | ConvertFrom-Json   # refresh recorded pids for AfterAll

        # The recovered daemon serves a REAL result again -- not a dead pipe or silence.
        $fix = Join-Path $script:R_Data 'pester-restart-fixture.ps1'
        "function Frobnicate-Restart {`n    Get-Process`n}" | Set-Content -LiteralPath $fix -Encoding ascii   # PSUseApprovedVerbs
        $out = Invoke-PluginHook -ScriptPath (Join-Path $script:R_ScriptsDir 'lsp-client.ps1') `
            -StdinJson (@{ session_id = $script:R_SidA; tool_input = @{ file_path = $fix }; cwd = $script:R_Data } | ConvertTo-Json -Compress) `
            -ExtraArgs @() -CapMs 25000 -DataRoot $script:R_Data -ExtraEnv @{ CLAUDE_PLUGIN_OPTION_timeoutMs = '18000' }
        $out | Should -Match 'PSUseApprovedVerbs'
    }

    It '(b) a non-settling pass surfaces a VISIBLE incomplete status, never empty/clean (Spine-1 false-clean)' {
        $script:R_InfoB | Should -Not -BeNullOrEmpty   # the -MaxWaitMs 1 daemon came up ready
        $fix = Join-Path $script:R_Data 'pester-incomplete-fixture.ps1'
        # Clean-parsing (so it passes the client's in-process parser pre-pass and reaches the
        # daemon) and would trip PSUseApprovedVerbs on a settled pass -- but the pass cannot
        # settle (MaxWaitMs=1), so the client must render 'incomplete', not silence.
        "function Frobnicate-Incomplete {`n    Get-Process`n}" | Set-Content -LiteralPath $fix -Encoding ascii
        $out = Invoke-PluginHook -ScriptPath (Join-Path $script:R_ScriptsDir 'lsp-client.ps1') `
            -StdinJson (@{ session_id = $script:R_SidB; tool_input = @{ file_path = $fix }; cwd = $script:R_Data } | ConvertTo-Json -Compress) `
            -ExtraArgs @() -CapMs 25000 -DataRoot $script:R_Data -ExtraEnv @{ CLAUDE_PLUGIN_OPTION_timeoutMs = '18000' }
        $out | Should -Match 'analysis did not complete'      # the visible incomplete banner
        $out | Should -Match 'unavailable'
        $out | Should -Not -Match 'PSUseApprovedVerbs'        # NOT a settled finding list
    }

    It '(d) PSSA-absent surfaces a VISIBLE parser-only degraded status and does not crash (R6-surfaced)' {
        $script:R_InfoD | Should -Not -BeNullOrEmpty   # daemon came up ready despite no vendored PSSA (no crash)
        $fix = Join-Path $script:R_DataD 'pester-degraded-fixture.ps1'
        "function Frobnicate-Degraded {`n    Get-Process`n}" | Set-Content -LiteralPath $fix -Encoding ascii
        $out = Invoke-PluginHook -ScriptPath (Join-Path $script:R_ScriptsDir 'lsp-client.ps1') `
            -StdinJson (@{ session_id = $script:R_SidD; tool_input = @{ file_path = $fix }; cwd = $script:R_DataD } | ConvertTo-Json -Compress) `
            -ExtraArgs @() -CapMs 25000 -DataRoot $script:R_DataD -ExtraEnv @{ CLAUDE_PLUGIN_OPTION_timeoutMs = '18000' }
        $out | Should -Match 'parser-only'
        $out | Should -Match 'PSScriptAnalyzer unavailable'
    }

    It '(e) on an exhausted re-spawn budget the daemon STAYS UP and serves incomplete -- it never silently dies (000022 Q(a)/Q(d))' {
        $script:R_InfoE | Should -Not -BeNullOrEmpty
        $daemonPid = [int]$script:R_InfoE.pid
        $origPsesPid = [int]$script:R_InfoE.psesPid

        # Kill PSES. With MaxPsesRestarts=0 the first detection spends the budget at once:
        # the daemon must flip the session file to 'degraded' WITHOUT exiting.
        Stop-Process -Id $origPsesPid -Force -ErrorAction SilentlyContinue
        $sf = Join-Path $script:R_Data ('session/' + $script:R_SidE + '.json')
        $state = ''
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Milliseconds 500
            if (Test-Path $sf) { $state = [string](Get-Prop (Get-Content $sf -Raw | ConvertFrom-Json) 'state') }
            if ($state -eq 'degraded') { break }
        }
        $state | Should -Be 'degraded'                                                          # exhaustion is observable
        (Get-Process -Id $daemonPid -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty # the daemon did NOT exit

        # And every request now returns the VISIBLE incomplete status -- never empty/clean.
        $fix = Join-Path $script:R_Data 'pester-exhaust-fixture.ps1'
        "function Frobnicate-Exhaust {`n    Get-Process`n}" | Set-Content -LiteralPath $fix -Encoding ascii
        $out = Invoke-PluginHook -ScriptPath (Join-Path $script:R_ScriptsDir 'lsp-client.ps1') `
            -StdinJson (@{ session_id = $script:R_SidE; tool_input = @{ file_path = $fix }; cwd = $script:R_Data } | ConvertTo-Json -Compress) `
            -ExtraArgs @() -CapMs 25000 -DataRoot $script:R_Data -ExtraEnv @{ CLAUDE_PLUGIN_OPTION_timeoutMs = '18000' }
        $out | Should -Match 'analysis did not complete'
        $out | Should -Match 'unavailable'
    }
}

# ===========================================================================
# First-start install-incomplete is VISIBLE, never silence (dispatch 000024)
# ===========================================================================
Describe 'Integration: first-start install-incomplete is VISIBLE (dispatch 000024)' -Skip:$script:SkipIntegration {
    # Extends the 000022 false-clean guarantee from MID-SESSION to INSTALL-TIME. The 000023
    # audit (dead-proxy probe) proved a clean-box bootstrap failure is silent end to end:
    # ensure-pses fails log-only, session-start swallows it, and the daemon exits BEFORE the
    # pipe -- so the client connect-fails and the first edit shows NOTHING (identical to
    # "analyzed, clean"). These tests drive that exact clean-box scenario and assert it is now
    # VISIBLE: a missing-bundle first start serves 'unavailable', ensure-pses fails loud and
    # non-destructively, and session-start surfaces the failure instead of swallowing it.
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')

        # Run a plugin script under pwsh with an explicit data root + extra env; capture stdout,
        # stderr, and the exit code SEPARATELY (the fail-loud test asserts on all three).
        function Invoke-CaptureU {
            param([string]$ScriptPath, [string]$DataRoot, [string[]]$ExtraArgs, [hashtable]$ExtraEnv)
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'pwsh'; $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
            Add-ProcessArguments $psi ((@('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + @($ExtraArgs)) | Where-Object { $_ })
            $psi.EnvironmentVariables['CLAUDE_PLUGIN_DATA'] = $DataRoot
            if ($ExtraEnv) { foreach ($k in $ExtraEnv.Keys) { $psi.EnvironmentVariables[$k] = [string]$ExtraEnv[$k] } }
            $p = [System.Diagnostics.Process]::Start($psi)
            $outT = $p.StandardOutput.ReadToEndAsync()
            $errT = $p.StandardError.ReadToEndAsync()
            if (-not $p.WaitForExit(60000)) { try { $p.Kill($true) } catch { }; return @{ ExitCode = -999; Out = ''; Err = 'timeout' } }
            [void]$outT.Wait(2000); [void]$errT.Wait(2000)
            return @{ ExitCode = $p.ExitCode; Out = $outT.Result; Err = $errT.Result }
        }

        # Run a hook (session-start / lsp-client) with stdin JSON + extra env; return stdout.
        function Invoke-HookEnvU {
            param([string]$ScriptPath, [string]$StdinJson, [string[]]$ExtraArgs, [int]$CapMs, [string]$DataRoot, [hashtable]$ExtraEnv)
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'pwsh'; $psi.UseShellExecute = $false
            $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            Add-ProcessArguments $psi ((@('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + @($ExtraArgs)) | Where-Object { $_ })
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

        # Launch pses-daemon.ps1 DIRECTLY with arbitrary args + env; return the Process. The
        # daemon logs to files; drain stdout/stderr so their buffers never fill.
        function Start-RawDaemonU {
            param([string]$Sid, [string]$DataRoot, [string[]]$ExtraArgs, [hashtable]$ExtraEnv)
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'pwsh'; $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
            $daemon = Join-Path $script:U_ScriptsDir 'pses-daemon.ps1'
            $argList = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $daemon,
                '-SessionId', $Sid, '-PsHost', 'pwsh', '-DataRoot', $DataRoot) + @($ExtraArgs)
            Add-ProcessArguments $psi ($argList | Where-Object { $_ })
            $psi.EnvironmentVariables['CLAUDE_PLUGIN_DATA'] = $DataRoot
            if ($ExtraEnv) { foreach ($k in $ExtraEnv.Keys) { $psi.EnvironmentVariables[$k] = [string]$ExtraEnv[$k] } }
            $p = [System.Diagnostics.Process]::Start($psi)
            $null = $p.StandardOutput.ReadToEndAsync()
            $null = $p.StandardError.ReadToEndAsync()
            return $p
        }

        # Wait for the daemon's session file to reach a SPECIFIC state (e.g. 'unavailable').
        function Wait-DaemonStateU {
            param([string]$DataRoot, [string]$Sid, [string]$State, [int]$Tries = 80)
            $sf = Join-Path $DataRoot ('session/' + $Sid + '.json')
            for ($i = 0; $i -lt $Tries; $i++) {
                if (Test-Path $sf) {
                    $o = Get-Content $sf -Raw | ConvertFrom-Json
                    if ([string](Get-Prop $o 'state') -eq $State) { return $o }
                }
                Start-Sleep -Milliseconds 300
            }
            return $null
        }

        $script:U_ScriptsDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts'
        # A dead proxy forces every outbound download to a refused address -- the audit's own
        # method, deterministic on pwsh (.NET Core honors HTTP(S)_PROXY env). No real network.
        $script:U_DeadProxy = @{ HTTPS_PROXY = 'http://127.0.0.1:1'; HTTP_PROXY = 'http://127.0.0.1:1'; ALL_PROXY = 'http://127.0.0.1:1' }

        $mk = {
            param($tag)
            $d = Join-Path ([System.IO.Path]::GetTempPath()) ('psls-000024-' + $tag + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Force -Path $d | Out-Null
            return $d
        }
        $script:U_RootMarquee = & $mk 'marquee'
        $script:U_RootLoud = & $mk 'loud'
        $script:U_RootNonDestr = & $mk 'nondestr'
        $script:U_RootSurface = & $mk 'surface'

        # Seed a prior "working" bundle (sentinel start script) for the non-destructive test,
        # but write NO marker -- so ensure-pses skips its fast-path no-op and takes the
        # re-bootstrap path, where the OLD code wiped the bundle BEFORE the single download.
        $script:U_Seed = Join-Path $script:U_RootNonDestr 'PowerShellEditorServices/PowerShellEditorServices/Start-EditorServices.ps1'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:U_Seed) | Out-Null
        'SENTINEL-PRIOR-BUNDLE-000024' | Set-Content -LiteralPath $script:U_Seed -Encoding ascii

        # (marquee) launch the daemon against a guaranteed-MISSING bundle. It must come up
        # SERVING 'unavailable' (create the pipe + write the session file) -- not exit 1 before
        # the pipe (the old first-start blind spot). PSES_BUNDLE_PATH pins the missing path so
        # the test is hermetic regardless of any ambient bundle under CLAUDE_PLUGIN_DATA.
        $script:U_Missing = Join-Path $script:U_RootMarquee 'no-such-bundle'
        $script:U_Sid = 'unavail-000024-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:U_Proc = Start-RawDaemonU -Sid $script:U_Sid -DataRoot $script:U_RootMarquee -ExtraArgs @() -ExtraEnv @{ PSES_BUNDLE_PATH = $script:U_Missing }
        $script:U_Info = Wait-DaemonStateU -DataRoot $script:U_RootMarquee -Sid $script:U_Sid -State 'unavailable'
    }

    AfterAll {
        if ($null -ne $script:U_Info) {
            foreach ($pidVal in @($script:U_Info.pid, $script:U_Info.psesPid)) {
                if ($pidVal) { Stop-Process -Id ([int]$pidVal) -Force -ErrorAction SilentlyContinue }
            }
        }
        try { if ($null -ne $script:U_Proc -and -not $script:U_Proc.HasExited) { $script:U_Proc.Kill($true) } } catch { }
        foreach ($d in @($script:U_RootMarquee, $script:U_RootLoud, $script:U_RootNonDestr, $script:U_RootSurface)) {
            if ($d -and (Test-Path -LiteralPath $d)) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It '(marquee) a clean-box first edit on a missing bundle shows a VISIBLE unavailable banner, never silence' {
        # The daemon came up serving 'unavailable' instead of dying before the pipe (000024).
        $script:U_Info | Should -Not -BeNullOrEmpty
        [string](Get-Prop $script:U_Info 'state') | Should -Be 'unavailable'
        (Get-Process -Id ([int]$script:U_Info.pid) -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty

        # Drive a FIRST edit on a clean-PARSING file (so it passes the client's in-process
        # parser pre-pass and actually reaches the daemon). Before 000024 this showed nothing.
        $fix = Join-Path $script:U_RootMarquee 'pester-unavailable-fixture.ps1'
        "function Frobnicate-Unavailable {`n    Get-Process`n}" | Set-Content -LiteralPath $fix -Encoding ascii
        $out = Invoke-HookEnvU -ScriptPath (Join-Path $script:U_ScriptsDir 'lsp-client.ps1') `
            -StdinJson (@{ session_id = $script:U_Sid; tool_input = @{ file_path = $fix }; cwd = $script:U_RootMarquee } | ConvertTo-Json -Compress) `
            -ExtraArgs @() -CapMs 25000 -DataRoot $script:U_RootMarquee -ExtraEnv @{ CLAUDE_PLUGIN_OPTION_timeoutMs = '18000' }

        $out | Should -Not -BeNullOrEmpty                       # NOT silence -- the whole point
        $out | Should -Match 'unavailable'                      # the visible banner
        $out | Should -Match 'not installed'                    # install-specific (distinct wording)
        $out | Should -Match 'bootstrap'
        $out | Should -Not -Match 'analysis did not complete'   # NOT the transient 'incomplete' banner
        $out | Should -Not -Match 'PSUseApprovedVerbs'          # NOT a settled finding list
    }

    It 'ensure-pses fails LOUD on an unreachable download: non-zero exit + a clear stderr message' {
        $r = Invoke-CaptureU -ScriptPath (Join-Path $script:U_ScriptsDir 'ensure-pses.ps1') -DataRoot $script:U_RootLoud -ExtraArgs @() -ExtraEnv $script:U_DeadProxy
        $r.ExitCode | Should -Not -Be 0
        $r.Err | Should -Match 'ensure-pses'
        $r.Err | Should -Match 'bootstrap failed'
    }

    It 'ensure-pses is NON-DESTRUCTIVE on a failed re-run: the pre-existing bundle survives' {
        # ensure-pses targets CLAUDE_PLUGIN_DATA/PowerShellEditorServices (NOT PSES_BUNDLE_PATH),
        # so the seeded sentinel lives inside the very bundle the OLD code wiped before download.
        $r = Invoke-CaptureU -ScriptPath (Join-Path $script:U_ScriptsDir 'ensure-pses.ps1') -DataRoot $script:U_RootNonDestr -ExtraArgs @() -ExtraEnv $script:U_DeadProxy
        $r.ExitCode | Should -Not -Be 0                                    # the re-bootstrap failed (loud)
        (Test-Path -LiteralPath $script:U_Seed) | Should -BeTrue           # prior bundle SURVIVED
        (Get-Content -LiteralPath $script:U_Seed -Raw) | Should -Match 'SENTINEL-PRIOR-BUNDLE-000024'
    }

    It 'session-start SURFACES a bootstrap failure via additionalContext (no longer swallowed)' {
        $sid = 'ss-surface-000024-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $out = Invoke-HookEnvU -ScriptPath (Join-Path $script:U_ScriptsDir 'session-start.ps1') `
            -StdinJson (@{ session_id = $sid } | ConvertTo-Json -Compress) `
            -ExtraArgs @('-PreferredHost', 'pwsh') -CapMs 60000 -DataRoot $script:U_RootSurface -ExtraEnv $script:U_DeadProxy

        $out | Should -Match 'hookSpecificOutput'      # emitted on the SessionStart channel
        $out | Should -Match 'SessionStart'
        $out | Should -Match 'bootstrap'               # the actionable failure message
        $out | Should -Match 'unavailable'

        # Reap the detached daemon session-start launched (it came up serving 'unavailable').
        $sf = Join-Path $script:U_RootSurface ('session/' + $sid + '.json')
        if (Test-Path $sf) {
            $o = Get-Content $sf -Raw | ConvertFrom-Json
            foreach ($pidVal in @((Get-Prop $o 'pid'), (Get-Prop $o 'psesPid'))) { if ($pidVal) { Stop-Process -Id ([int]$pidVal) -Force -ErrorAction SilentlyContinue } }
        }
    }
}

Describe 'Integration: pses-stdio.ps1 emits no pre-handshake stdout (dispatch 000025 stdout-silence)' -Skip:$script:SkipIntegration {
    # pses-stdio.ps1 now dot-sources lsp-common.ps1 for the single-source Get-PluginVersion
    # HostVersion stamp. Its stdout IS the LSP byte stream once -Stdio starts, so a single
    # stray byte from the new import would corrupt the protocol. This drives the launcher on
    # the reachable bundle-MISSING path -- which exercises the import, then exits 1 with the
    # error on STDERR -- and asserts stdout is byte-empty. Spawns the CURRENT host, so it is a
    # real invocation under pwsh in CI and under Windows PowerShell 5.1 locally. Adversarial
    # control: add a bare emitting line to lsp-common.ps1 (or pses-stdio.ps1) ahead of the
    # handshake and the 'stdout is empty' assertion goes RED.
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')
        $script:S_Stdio = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/pses-stdio.ps1'
        $script:S_Host = (Get-Process -Id $PID).Path
    }
    It 'writes ZERO bytes to stdout when the bundle is missing (error -> stderr, exit 1)' {
        $missing = Join-Path ([System.IO.Path]::GetTempPath()) ('psls-000025-absent-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:S_Host; $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
        Add-ProcessArguments $psi @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:S_Stdio)
        $psi.EnvironmentVariables['PSES_BUNDLE_PATH'] = $missing
        $p = [System.Diagnostics.Process]::Start($psi)
        $outT = $p.StandardOutput.ReadToEndAsync()
        $errT = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(30000)) { try { $p.Kill($true) } catch { }; throw 'pses-stdio did not exit' }
        [void]$outT.Wait(2000); [void]$errT.Wait(2000)
        $p.ExitCode | Should -Be 1
        $outT.Result | Should -BeExactly ''       # the single byte that would corrupt the LSP stream
        $errT.Result | Should -Match 'PSES not found'
    }
}

Describe 'Integration: pipe-first honest startup (dispatch 000028)' -Skip:$script:SkipIntegration {
    # Pipe-first closes the no-pipe SILENT MISS: the daemon creates the named pipe BEFORE bringing
    # PSES up, then finishes init cooperatively, so a first edit that races startup gets an HONEST
    # banner over the pipe -- never the old silent connect-fail (client return $null -> exit 0).
    # Two sub-cases, each driven DETERMINISTICALLY via a dummy bundle (no wall-clock race):
    #   (A) PSES present but still INITIALIZING (dummy sleeps; never answers initialize) + a high
    #       -InitTimeoutMs so it stays initializing -> a request gets the TRANSIENT 'incomplete'.
    #   (B) PSES present but init FAILS (dummy exits at once) -> the daemon STAYS UP serving the
    #       PERMANENT 'unavailable', never exit 1 (the bundle-present fail-fast 000024 left silent).
    # Plus warm-start rides FREE: a real bundle reaches 'ready' with the analyzer pre-warmed (the
    # daemon log records it for that PID), and the first real edit is served the clean warm
    # diagnostic with no banner. The dummy-bundle seam mirrors the 000022/000024 daemon-direct
    # pattern (force the CONDITION, assert the served STATUS over the pipe -- not a flaky proxy).
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

        function Start-RawDaemon {
            param([string]$Sid, [string]$DataRoot, [string[]]$ExtraArgs, [hashtable]$ExtraEnv)
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'pwsh'; $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
            $daemon = Join-Path $script:P_ScriptsDir 'pses-daemon.ps1'
            $argList = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $daemon,
                '-SessionId', $Sid, '-PsHost', 'pwsh', '-DataRoot', $DataRoot) + @($ExtraArgs)
            Add-ProcessArguments $psi ($argList | Where-Object { $_ })
            $psi.EnvironmentVariables['CLAUDE_PLUGIN_DATA'] = $DataRoot
            if ($ExtraEnv) { foreach ($k in $ExtraEnv.Keys) { $psi.EnvironmentVariables[$k] = [string]$ExtraEnv[$k] } }
            $p = [System.Diagnostics.Process]::Start($psi)
            $null = $p.StandardOutput.ReadToEndAsync(); $null = $p.StandardError.ReadToEndAsync()
            return $p
        }

        function Wait-DaemonAnyState {
            param([string]$DataRoot, [string]$Sid, [string[]]$States, [int]$Tries = 80)
            $sf = Join-Path $DataRoot ('session/' + $Sid + '.json')
            for ($i = 0; $i -lt $Tries; $i++) {
                if (Test-Path $sf) {
                    $o = Get-Content $sf -Raw | ConvertFrom-Json
                    if ($States -contains [string](Get-Prop $o 'state')) { return $o }
                }
                Start-Sleep -Milliseconds 400
            }
            return $null
        }

        function New-DummyBundle {
            param([string]$Root, [string]$Body)
            $s = Join-Path $Root 'PowerShellEditorServices/Start-EditorServices.ps1'
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $s) | Out-Null
            Set-Content -LiteralPath $s -Value $Body -Encoding ascii
            return $Root
        }

        $script:P_ScriptsDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts'
        # Shared data root (real PSES + PSSA bootstrapped) for the warm-start happy path.
        $script:P_Data = if (-not [string]::IsNullOrWhiteSpace($env:PSLS_TEST_DATA_DIR)) { $env:PSLS_TEST_DATA_DIR } else { Join-Path ([System.IO.Path]::GetTempPath()) 'psls-pester-data' }
        New-Item -ItemType Directory -Force -Path $script:P_Data | Out-Null
        $env:CLAUDE_PLUGIN_DATA = $script:P_Data
        & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:P_ScriptsDir 'ensure-pses.ps1') 2>&1 | Out-Null
        & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:P_ScriptsDir 'ensure-pssa.ps1') 2>&1 | Out-Null

        # (A) dummy that SLEEPS (present, never answers initialize) + high init timeout -> stays initializing.
        $script:P_DataA = Join-Path ([System.IO.Path]::GetTempPath()) ('psls-000028-A-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $script:P_DataA | Out-Null
        $script:P_BundleA = New-DummyBundle -Root (Join-Path $script:P_DataA 'dummy') -Body "Start-Sleep -Seconds 300`n"
        $script:P_SidA = 'pf-init-000028-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $script:P_ProcA = Start-RawDaemon -Sid $script:P_SidA -DataRoot $script:P_DataA -ExtraArgs @('-InitTimeoutMs', '120000') -ExtraEnv @{ PSES_BUNDLE_PATH = $script:P_BundleA }
        $script:P_InfoA = Wait-DaemonAnyState -DataRoot $script:P_DataA -Sid $script:P_SidA -States @('starting') -Tries 30

        # (B) dummy that EXITS at once (present, init fails) -> daemon stays up serving unavailable.
        $script:P_DataB = Join-Path ([System.IO.Path]::GetTempPath()) ('psls-000028-B-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $script:P_DataB | Out-Null
        $script:P_BundleB = New-DummyBundle -Root (Join-Path $script:P_DataB 'dummy') -Body "exit 0`n"
        $script:P_SidB = 'pf-fail-000028-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $script:P_ProcB = Start-RawDaemon -Sid $script:P_SidB -DataRoot $script:P_DataB -ExtraArgs @('-InitTimeoutMs', '8000') -ExtraEnv @{ PSES_BUNDLE_PATH = $script:P_BundleB }
        $script:P_InfoB = Wait-DaemonAnyState -DataRoot $script:P_DataB -Sid $script:P_SidB -States @('unavailable') -Tries 60

        # (warm) real bundle on the shared root -> reaches ready, analyzer pre-warmed.
        $script:P_SidW = 'pf-warm-000028-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $script:P_ProcW = Start-RawDaemon -Sid $script:P_SidW -DataRoot $script:P_Data -ExtraArgs @() -ExtraEnv @{ }
        $script:P_InfoW = Wait-DaemonAnyState -DataRoot $script:P_Data -Sid $script:P_SidW -States @('ready') -Tries 80
    }

    AfterAll {
        foreach ($info in @($script:P_InfoA, $script:P_InfoB, $script:P_InfoW)) {
            if ($null -ne $info) { foreach ($pidVal in @($info.pid, $info.psesPid)) { if ($pidVal) { Stop-Process -Id ([int]$pidVal) -Force -ErrorAction SilentlyContinue } } }
        }
        foreach ($p in @($script:P_ProcA, $script:P_ProcB, $script:P_ProcW)) { try { if ($null -ne $p -and -not $p.HasExited) { $p.Kill($true) } } catch { } }
        # the warm session file lives in the SHARED root; clean only OUR session file there.
        $sfW = Join-Path $script:P_Data ('session/' + $script:P_SidW + '.json')
        if (Test-Path -LiteralPath $sfW) { Remove-Item -LiteralPath $sfW -Force -ErrorAction SilentlyContinue }
        foreach ($d in @($script:P_DataA, $script:P_DataB)) { if ($d -and (Test-Path -LiteralPath $d)) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } }
    }

    It '(A) a request while PSES is still INITIALIZING surfaces the TRANSIENT incomplete, never silence' {
        $script:P_InfoA | Should -Not -BeNullOrEmpty          # came up 'starting' (pipe open before PSES ready)
        [string](Get-Prop $script:P_InfoA 'state') | Should -Be 'starting'
        $fix = Join-Path $script:P_DataA 'init-fixture.ps1'
        "function Get-Init { 1 }" | Set-Content -LiteralPath $fix -Encoding ascii   # clean parse -> reaches the daemon
        $out = Invoke-PluginHook -ScriptPath (Join-Path $script:P_ScriptsDir 'lsp-client.ps1') `
            -StdinJson (@{ session_id = $script:P_SidA; tool_input = @{ file_path = $fix }; cwd = $script:P_DataA } | ConvertTo-Json -Compress) `
            -ExtraArgs @() -CapMs 25000 -DataRoot $script:P_DataA -ExtraEnv @{ CLAUDE_PLUGIN_OPTION_timeoutMs = '18000' }
        $out | Should -Not -BeNullOrEmpty                     # NOT the old silent connect-fail
        $out | Should -Match 'analysis did not complete'      # the TRANSIENT incomplete banner
        $out | Should -Not -Match 'whole session'             # NOT the permanent unavailable (sub-case A != B)
    }

    It '(B) a bundle-present init FAILURE stays up serving PERMANENT unavailable -- never exit 1, never silence' {
        $script:P_InfoB | Should -Not -BeNullOrEmpty
        [string](Get-Prop $script:P_InfoB 'state') | Should -Be 'unavailable'
        (Get-Process -Id ([int]$script:P_InfoB.pid) -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty   # daemon did NOT exit 1
        $fix = Join-Path $script:P_DataB 'fail-fixture.ps1'
        "function Get-Fail { 1 }" | Set-Content -LiteralPath $fix -Encoding ascii
        $out = Invoke-PluginHook -ScriptPath (Join-Path $script:P_ScriptsDir 'lsp-client.ps1') `
            -StdinJson (@{ session_id = $script:P_SidB; tool_input = @{ file_path = $fix }; cwd = $script:P_DataB } | ConvertTo-Json -Compress) `
            -ExtraArgs @() -CapMs 25000 -DataRoot $script:P_DataB -ExtraEnv @{ CLAUDE_PLUGIN_OPTION_timeoutMs = '18000' }
        $out | Should -Not -BeNullOrEmpty                      # NOT silence (the sub-case B silent miss, closed)
        $out | Should -Match 'could not start'                 # generalized unavailable wording
        $out | Should -Match 'whole session'                   # lands PERMANENCE (distinct from transient incomplete)
        $out | Should -Not -Match 'analysis did not complete'  # NOT routed through the transient incomplete
    }

    It 'warm-start rides FREE: the daemon reaches ready pre-warmed and the first real edit is served clean+warm' {
        $script:P_InfoW | Should -Not -BeNullOrEmpty
        [string](Get-Prop $script:P_InfoW 'state') | Should -Be 'ready'
        # Proof the analyzer was pre-warmed for THIS daemon (its PID). BOUNDED POLL for a DEFINITE
        # event, not an instant assert: 'ready' is written to the session file BEFORE Invoke-WarmStart
        # logs its line (the warm pass runs just after ready, up to ~MaxWaitMs for its analyzer pump),
        # so a plain scrape races a slow runner (the 000026 flaky-proxy lesson -- macOS caught exactly
        # this). Wait for the line; do not assume it is already there. A genuine warm-start failure
        # would still fail here (the line never appears -> the poll times out).
        $dlog = Join-Path $script:P_Data 'logs/pses-daemon.log'
        $warmPat = '\[' + [int]$script:P_InfoW.pid + '\].*warm-start: analyzer pre-warmed'
        $warmCount = 0
        for ($i = 0; $i -lt 60; $i++) {
            $warmCount = @(Select-String -Path $dlog -Pattern $warmPat -ErrorAction SilentlyContinue).Count
            if ($warmCount -gt 0) { break }
            Start-Sleep -Milliseconds 500
        }
        $warmCount | Should -BeGreaterThan 0
        # Behavioral complement: the first real edit is served the clean WARM diagnostic, no banner.
        $fix = Join-Path $script:P_Data 'warm-fixture.ps1'
        "function Frobnicate-Warm {`n    Get-Process`n}" | Set-Content -LiteralPath $fix -Encoding ascii   # PSUseApprovedVerbs
        $out = Invoke-PluginHook -ScriptPath (Join-Path $script:P_ScriptsDir 'lsp-client.ps1') `
            -StdinJson (@{ session_id = $script:P_SidW; tool_input = @{ file_path = $fix }; cwd = $script:P_Data } | ConvertTo-Json -Compress) `
            -ExtraArgs @() -CapMs 25000 -DataRoot $script:P_Data -ExtraEnv @{ CLAUDE_PLUGIN_OPTION_timeoutMs = '18000' }
        $out | Should -Match 'PSUseApprovedVerbs'             # real settled analyzer result
        $out | Should -Not -Match 'did not complete'          # not cold/incomplete -- served warm
        $out | Should -Not -Match 'whole session'             # not unavailable
        $out | Should -Not -Match 'was not reachable'         # the never-silent backstop does NOT fire on a healthy pass (clean-pass boundary)
    }

    It 'never-silent backstop: a clean edit with NO reachable daemon surfaces an honest banner, not silence (closes the residual no-pipe window + an idle-TTL/stopped daemon)' {
        # The fullest expression of the never-silent thesis: even when there is NO pipe at all --
        # the brief daemon-launch sliver, or a session whose daemon idle-TTL'd / died -- a clean
        # edit must not read as "analyzed, clean." A session id with no daemon = guaranteed no pipe;
        # a clean-PARSING file passes the client's in-process parser pre-pass and reaches the daemon
        # path ($null unreachable -> the client backstop), exactly the residual window pipe-first
        # cannot reach from the daemon side. Gated on $null, which a healthy pass never is (the
        # warm-start It above proves the backstop stays silent on a real result).
        $noDaemonSid = 'pf-nodaemon-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $fix = Join-Path $script:P_Data 'nodaemon-fixture.ps1'
        "function Get-NoDaemon { 1 }" | Set-Content -LiteralPath $fix -Encoding ascii
        $out = Invoke-PluginHook -ScriptPath (Join-Path $script:P_ScriptsDir 'lsp-client.ps1') `
            -StdinJson (@{ session_id = $noDaemonSid; tool_input = @{ file_path = $fix }; cwd = $script:P_Data } | ConvertTo-Json -Compress) `
            -ExtraArgs @() -CapMs 25000 -DataRoot $script:P_Data -ExtraEnv @{ CLAUDE_PLUGIN_OPTION_timeoutMs = '6000' }
        $out | Should -Not -BeNullOrEmpty                  # NOT silence -- the backstop fired
        $out | Should -Match 'was not reachable'           # the client-side unreachable banner
        $out | Should -Match 'this edit was NOT checked'
    }
}

Describe 'Third-party MIT notices are preserved in the installed bundle (dispatch 000029)' -Skip:$script:SkipIntegration {
    # GPL-correctness: the plugin DOWNLOADS PSES + PSScriptAnalyzer (MIT, Microsoft) at install. MIT
    # requires the notice 'in all copies', so the installed bundle must retain each dep's LICENSE /
    # notice. The 000029 ensure-pses fix preserves the PSES release-root LICENSE + NOTICE.txt (the
    # module-only move had dropped them -- a real pre-existing MIT violation the extraction check
    # surfaced); ensure-pssa already preserves the PSSA module LICENSE + ThirdPartyNotices. This
    # asserts BOTH survive extraction into the bundle (not merely attributed by-reference).
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')
        $script:N_Scripts = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts'
        $script:N_Data = if (-not [string]::IsNullOrWhiteSpace($env:PSLS_TEST_DATA_DIR)) { $env:PSLS_TEST_DATA_DIR } else { Join-Path ([System.IO.Path]::GetTempPath()) 'psls-pester-data' }
        New-Item -ItemType Directory -Force -Path $script:N_Data | Out-Null
        $env:CLAUDE_PLUGIN_DATA = $script:N_Data
        # Self-heal: if a PRE-FIX PSES bundle (no LICENSE) is present, force a fresh bootstrap so this
        # test exercises the CURRENT ensure-pses, not a stale bundle. A fresh CI runner has no bundle,
        # so this is a no-op there (ensure-pses bootstraps fresh, with the fix).
        $script:N_PsesBundle = Join-Path $script:N_Data 'PowerShellEditorServices'
        if ((Test-Path $script:N_PsesBundle) -and -not (Test-Path (Join-Path $script:N_PsesBundle 'LICENSE'))) {
            Remove-Item $script:N_PsesBundle -Recurse -Force -ErrorAction SilentlyContinue
            Get-ChildItem -Path $script:N_Data -Filter 'pses-*.ok' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        }
        & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:N_Scripts 'ensure-pses.ps1') 2>&1 | Out-Null
        & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:N_Scripts 'ensure-pssa.ps1') 2>&1 | Out-Null
        $psd = Get-ChildItem -Path (Join-Path $script:N_Data 'modules') -Recurse -Filter 'PSScriptAnalyzer.psd1' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        $script:N_PssaDir = if ($psd) { $psd.Directory.FullName } else { $null }
    }
    It 'PSES bundle retains its MIT LICENSE + NOTICE (the 000029 ensure-pses preservation fix)' {
        $licPath = Join-Path $script:N_PsesBundle 'LICENSE'
        (Test-Path $licPath) | Should -BeTrue
        (Test-Path (Join-Path $script:N_PsesBundle 'NOTICE.txt')) | Should -BeTrue
        (Get-Content -LiteralPath $licPath -Raw) | Should -Match 'Permission is hereby granted'   # MIT permission grant
        (Get-Content -LiteralPath $licPath -Raw) | Should -Match 'Microsoft'
        # the module still resolves alongside the notices -- zero runtime change
        (Test-Path (Join-Path $script:N_PsesBundle 'PowerShellEditorServices/Start-EditorServices.ps1')) | Should -BeTrue
    }
    It 'PSScriptAnalyzer module retains its MIT LICENSE + ThirdPartyNotices' {
        $script:N_PssaDir | Should -Not -BeNullOrEmpty
        (Test-Path (Join-Path $script:N_PssaDir 'LICENSE')) | Should -BeTrue
        (Test-Path (Join-Path $script:N_PssaDir 'ThirdPartyNotices.txt')) | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $script:N_PssaDir 'LICENSE') -Raw) | Should -Match 'Permission is hereby granted'
    }
}
