#Requires -Version 5.1

# Integration regression tests (Pester 5): drive the REAL daemon end to end.
# Needs PSES + PSScriptAnalyzer bootstrapped (the BeforeAll does it idempotently)
# and named pipes, so it is Windows-only for now (cross-platform is authored but
# CI-verified later). Skipped on non-Windows.

# Discovery-time platform gate for -Skip (StrictMode-safe; PS 5.1 has no $IsWindows/$IsLinux).
# Integration runs on Windows and Linux; macOS stays authored-but-unverified (skipped).
$script:OnWindows = if (Test-Path 'Variable:\IsWindows') { [bool]$IsWindows } else { $true }
$script:OnLinux = (Test-Path 'Variable:\IsLinux') -and [bool]$IsLinux
$script:SkipIntegration = -not ($script:OnWindows -or $script:OnLinux)

Describe 'Integration: warm-start daemon (Windows + Linux)' -Skip:$script:SkipIntegration {

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
            if (-not $p.WaitForExit($CapMs)) { try { $p.Kill($true) } catch { }; return '' }
            [void]$stdoutTask.Wait(1500)
            if ($stdoutTask.IsCompleted) { return $stdoutTask.Result } else { return '' }
        }

        $script:ScriptsDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts'
        $script:DataDir = Join-Path ([System.IO.Path]::GetTempPath()) 'psls-pester-data'
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
