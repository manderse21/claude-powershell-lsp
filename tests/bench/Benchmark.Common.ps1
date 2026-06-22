#Requires -Version 5.1

# Benchmark.Common.ps1 -- shared measurement helpers for the performance benchmark
# harness (dispatch 000040, Gap C). Times the REAL daemon/pipe path:
#   * cold-start  -- SessionStart hook invoked -> the per-session PSES daemon reaches
#                    'ready' (a fresh PSES process + pipe per iteration).
#   * warm-path   -- one edit -> diagnostic round-trip against an already-warm daemon
#                    (a real content change each iteration, so a fresh analysis is
#                    timed, not a pure cache hit).
# Emits structured numbers (Write-BenchmarkResults) and exposes a median so a CI guard
# can assert against a generous threshold. Defines functions only; ASCII-only.

$script:BenchCommonDir = $PSScriptRoot
$script:BenchTestsDir = Split-Path -Parent $script:BenchCommonDir
$script:BenchPluginRoot = Split-Path -Parent $script:BenchTestsDir
$script:BenchScriptsDir = Join-Path $script:BenchPluginRoot 'scripts'

. (Join-Path $script:BenchScriptsDir 'lib/lsp-common.ps1')

function Get-BenchPaths {
    return [pscustomobject]@{
        ScriptsDir  = $script:BenchScriptsDir
        PluginRoot  = $script:BenchPluginRoot
        FixturePath = (Join-Path $script:BenchCommonDir 'bench-fixture.ps1')
    }
}

function Invoke-BenchHook {
    # Spawn a plugin hook under pwsh with stdin + env, returning its stdout. Mirrors the
    # integration suite's Invoke-PluginHook (pwsh is the analysis host on every leg).
    param([string]$ScriptPath, [string]$StdinJson, [int]$CapMs, [string]$DataRoot, [string[]]$ExtraArgs = @(), [hashtable]$ExtraEnv)
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

function Measure-BenchColdStartMs {
    # Time from invoking the real SessionStart hook to the per-session daemon reaching
    # 'ready'. Each call uses its OWN session id and tears the daemon back down, so the
    # next iteration times a genuinely cold per-session spin-up (PSES is bundled
    # already; this is the per-session daemon start a user pays, NOT a first-install
    # download). Returns the elapsed ms, or -1 if the daemon never became ready.
    param([string]$ScriptsDir, [string]$DataRoot, [string]$SessionId, [int]$TimeoutMs = 60000)
    $sf = Join-Path $DataRoot ('session/' + $SessionId + '.json')
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-BenchHook -ScriptPath (Join-Path $ScriptsDir 'session-start.ps1') `
        -StdinJson (@{ session_id = $SessionId } | ConvertTo-Json -Compress) `
        -ExtraArgs @('-PreferredHost', 'pwsh') -CapMs $TimeoutMs -DataRoot $DataRoot | Out-Null
    $ready = $false; $info = $null
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if (Test-Path -LiteralPath $sf) {
            $info = Get-Content -LiteralPath $sf -Raw | ConvertFrom-Json
            if ($info.state -eq 'ready') { $ready = $true; break }
        }
        Start-Sleep -Milliseconds 25
    }
    $sw.Stop()
    $elapsed = if ($ready) { [int]$sw.ElapsedMilliseconds } else { -1 }
    # Tear the daemon down so the next cold-start is independent.
    try {
        Invoke-BenchHook -ScriptPath (Join-Path $ScriptsDir 'session-end.ps1') `
            -StdinJson (@{ session_id = $SessionId } | ConvertTo-Json -Compress) `
            -ExtraArgs @() -CapMs 8000 -DataRoot $DataRoot | Out-Null
    } catch { }
    if ($null -ne $info) {
        foreach ($pidVal in @($info.pid, $info.psesPid)) {
            if ($pidVal) { Stop-Process -Id $pidVal -Force -ErrorAction SilentlyContinue }
        }
    }
    return $elapsed
}

function Measure-BenchWarmPathMs {
    # Time one edit -> diagnostic round-trip against an already-warm daemon. The caller
    # mutates $ScratchFile (a real content change) before each call so a FRESH analysis
    # is timed, not a cache hit. Returns the elapsed ms for the lsp-client round-trip.
    param([string]$ScriptsDir, [string]$DataRoot, [string]$SessionId, [string]$ScratchFile, [int]$CapMs = 25000)
    $stdin = (@{ session_id = $SessionId; tool_input = @{ file_path = $ScratchFile }; cwd = (Split-Path -Parent $ScratchFile) } | ConvertTo-Json -Compress)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-BenchHook -ScriptPath (Join-Path $ScriptsDir 'lsp-client.ps1') `
        -StdinJson $stdin -CapMs $CapMs -DataRoot $DataRoot `
        -ExtraEnv @{ CLAUDE_PLUGIN_OPTION_timeoutMs = '18000' } | Out-Null
    $sw.Stop()
    return [int]$sw.ElapsedMilliseconds
}

function Get-BenchMedian {
    param([int[]]$Values)
    $sorted = @(@($Values) | Where-Object { $_ -ge 0 } | Sort-Object)
    $n = $sorted.Count
    if ($n -eq 0) { return -1 }
    if ($n % 2 -eq 1) { return [int]$sorted[[int][math]::Floor($n / 2)] }
    return [int][math]::Round((([double]$sorted[$n / 2 - 1] + [double]$sorted[$n / 2]) / 2.0), 0)
}

function Get-BenchStats {
    # min / median / max over a sample set, plus the raw samples.
    param([int[]]$Values)
    $clean = @(@($Values) | Where-Object { $_ -ge 0 })
    if ($clean.Count -eq 0) {
        return [ordered]@{ samples = @(); count = 0; minMs = -1; medianMs = -1; maxMs = -1 }
    }
    $sorted = @($clean | Sort-Object)
    return [ordered]@{
        samples  = @($clean)
        count    = $clean.Count
        minMs    = [int]$sorted[0]
        medianMs = (Get-BenchMedian -Values $clean)
        maxMs    = [int]$sorted[-1]
    }
}

function Write-BenchmarkResults {
    # Emit a structured JSON results file (uploadable as a CI artifact from
    # <dataRoot>/logs) AND return the object so the test can print + assert on it.
    param([string]$DataRoot, $ColdStats, $WarmStats, [hashtable]$Thresholds)
    $hostLabel = 'pwsh ' + $PSVersionTable.PSVersion.ToString()
    $platform = if (Test-Path 'Variable:\IsWindows') {
        if ($IsWindows) { 'windows' } elseif ($IsLinux) { 'linux' } elseif ($IsMacOS) { 'macos' } else { 'other' }
    } else { 'windows' }
    $result = [ordered]@{
        schema       = 'powershell-lsp-benchmark/1'
        host         = $hostLabel
        platform     = $platform
        coldStart    = $ColdStats
        warmPath     = $WarmStats
        thresholdsMs = $Thresholds
    }
    try {
        $logDir = Join-Path $DataRoot 'logs'
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText((Join-Path $logDir 'benchmark-results.json'), (($result | ConvertTo-Json -Depth 6) + "`n"), $enc)
    } catch { }
    return $result
}
