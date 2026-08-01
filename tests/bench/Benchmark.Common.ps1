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
            # Read through the guarded reader: the daemon writes this file WHILE we poll it, so a
            # read can land mid-write. An unguarded read of a torn file is a terminating error
            # under StrictMode -- see Read-BenchSessionFile (dispatch 000172 D2).
            $probe = Read-BenchSessionFile -Path $sf
            if ($null -ne $probe.Info) { $info = $probe.Info }
            if ($probe.State -eq 'ready') { $ready = $true; break }
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
        # Same guard on the teardown read: $info may be the LAST partial parse we saw, so
        # neither pid property is guaranteed to exist.
        foreach ($pidVal in @((Get-BenchProp $info 'pid'), (Get-BenchProp $info 'psesPid'))) {
            if ($pidVal) { Stop-Process -Id $pidVal -Force -ErrorAction SilentlyContinue }
        }
    }
    return $elapsed
}

function Get-BenchProp {
    # StrictMode-safe member read: returns $null for an absent member instead of throwing.
    # Direct dotted access on a PSCustomObject that lacks the member is a TERMINATING error under
    # Set-StrictMode -Version Latest, which tests/bench/Invoke-LatencyBench.ps1,
    # tests/validate-sarif-artifacts.ps1 and tests/ServeShim.Driver.ps1 all set.
    #
    # BOTH shapes are handled deliberately: Get-BenchStats returns an [ordered] dictionary
    # (OrderedDictionary) while ConvertFrom-Json returns a PSCustomObject. A PSObject-only reader
    # silently returns $null for EVERY key of the stats object -- which is a vacuous read, the same
    # class of defect as the -1 sentinel this file's D1 fix exists to close.
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $props = $Object.PSObject.Properties
    if ($null -eq $props) { return $null }
    $p = $props[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Read-BenchSessionFile {
    # Read the per-session daemon state file, tolerating a MID-WRITE read (dispatch 000172, D2).
    #
    # THE DEFECT THIS CURES: the cold-start poller reads this file every 25 ms while the daemon is
    # writing it. A read that lands mid-write yields truncated JSON, and the shipped code did
    #     $info = Get-Content -Raw | ConvertFrom-Json ; if ($info.state -eq 'ready')
    # which can die three separate ways -- ConvertFrom-Json throws on torn JSON, $info is $null on
    # an empty file, and $info.state throws under StrictMode when the object parsed but the
    # property has not been written yet. Any of the three aborts the whole benchmark run with an
    # unhandled terminating error, turning a 25 ms timing artifact into a red leg.
    #
    # DISPOSITION (000172 leg 4, pre-authorized fork 2 -- guard, do not add a retry): a bad read is
    # reported as a not-yet-ready MISS and the CALLER decides. No retry is added here because the
    # caller is already a bounded retry loop -- it re-polls every 25 ms until its own TimeoutMs and
    # then records the miss as -1. Adding a second retry budget inside the reader would nest two
    # timeouts and make neither one the real bound.
    #
    # Returns an object with State (the state string, or $null when it could not be read) and Info
    # (the parsed object, or $null). Never throws.
    param([string]$Path)
    $miss = [pscustomobject]@{ State = $null; Info = $null }
    $raw = $null
    try { $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop } catch { return $miss }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $miss }
    $info = $null
    try { $info = $raw | ConvertFrom-Json -ErrorAction Stop } catch { return $miss }
    if ($null -eq $info) { return $miss }
    $state = Get-BenchProp $info 'state'
    return [pscustomobject]@{ State = $(if ($null -eq $state) { $null } else { [string]$state }); Info = $info }
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

function Get-BenchPercentile {
    # NEAREST-RANK percentile (dispatch 000127): sort ascending, take ceil(p*n) as a 1-based
    # rank. No interpolation -- at the sample sizes this harness runs (30-ish), interpolating
    # between two neighbours invents precision the data does not carry. Every reported p95 is
    # therefore an OBSERVED sample, never a synthesized one. Returns -1 on an empty set.
    param([int[]]$Values, [double]$Percentile = 0.95)
    $clean = @(@($Values) | Where-Object { $_ -ge 0 })
    $n = $clean.Count
    if ($n -eq 0) { return -1 }
    $sorted = @($clean | Sort-Object)
    $rank = [int][math]::Ceiling($Percentile * $n) - 1
    if ($rank -lt 0) { $rank = 0 }
    if ($rank -ge $n) { $rank = $n - 1 }
    return [int]$sorted[$rank]
}

function Get-BenchStats {
    # min / median / p95 / max over a sample set, plus the raw samples. p95Ms is ADDITIVE
    # (dispatch 000127): existing consumers key on medianMs and are unaffected.
    #
    # `count` is the SAMPLE COUNT and is the load-bearing field for any threshold assertion --
    # see Get-BenchMeasuredMedian below and dispatch 000172 D1. The -1 aggregates are a DISPLAY
    # sentinel meaning "nothing was measured"; they are NOT a latency and must never be compared
    # against a ceiling directly.
    param([int[]]$Values)
    $clean = @(@($Values) | Where-Object { $_ -ge 0 })
    if ($clean.Count -eq 0) {
        return [ordered]@{ samples = @(); count = 0; minMs = -1; medianMs = -1; p95Ms = -1; maxMs = -1 }
    }
    $sorted = @($clean | Sort-Object)
    return [ordered]@{
        samples  = @($clean)
        count    = $clean.Count
        minMs    = [int]$sorted[0]
        medianMs = (Get-BenchMedian -Values $clean)
        p95Ms    = (Get-BenchPercentile -Values $clean -Percentile 0.95)
        maxMs    = [int]$sorted[-1]
    }
}

function Get-BenchMeasuredMedian {
    # THE SELECTED-COUNT FLOOR, APPLIED TO A STATISTICS OBJECT (dispatch 000172, D1).
    #
    # THE DEFECT THIS CURES -- the vacuous-match class. Get-BenchStats returns medianMs = -1 when
    # NOTHING WAS MEASURED. A threshold assertion written the obvious way,
    #     $stats.medianMs | Should -BeLessThan 20000
    # is then satisfied by -1: a run that produced zero samples reads as comfortably inside budget.
    # That is exactly what happened on the failing CI run for PR #118 -- the companion
    # `Should -BeGreaterThan 0` caught the real failure while the threshold assertion sat green.
    #
    # WHY NOT A $null SENTINEL (pre-authorized fork 2, REFUTED BY MEASUREMENT): making the empty
    # aggregate $null does NOT make a bare comparison fail. PowerShell coerces $null to 0 in a
    # numeric comparison, so ($null -lt 60000) is True and `$null | Should -BeLessThan 60000`
    # PASSES just as -1 does. Measured on pwsh 7.6.3 while working 000172. Swapping the sentinel
    # would have moved the defect, not closed it.
    #
    # THE MECHANISM: a threshold assertion can only reach a number by calling THIS, and this
    # THROWS when count is zero. The comparison is therefore unreachable on an empty sample set
    # by any path, rather than merely accompanied by a separate assertion someone can forget.
    param($Stats, [string]$Label = 'measurement')
    if ($null -eq $Stats) {
        throw ("NOTHING WAS MEASURED for '" + $Label + "': the stats object is null. A threshold " +
            'assertion must not run against an absent measurement.')
    }
    $count = [int](Get-BenchProp $Stats 'count')
    if ($count -le 0) {
        throw ("NOTHING WAS MEASURED for '" + $Label + "': 0 samples. medianMs is the -1 " +
            '"not measured" sentinel, NOT a latency -- comparing it against a ceiling would ' +
            'report a run that measured nothing as being within budget (dispatch 000172, D1).')
    }
    $median = [int](Get-BenchProp $Stats 'medianMs')
    if ($median -lt 0) {
        throw ("INCONSISTENT STATS for '" + $Label + "': count=" + $count + ' but medianMs=' +
            $median + '. A counted sample set cannot have a negative median.')
    }
    return $median
}

function Format-BenchStatValue {
    # Render an aggregate for a HUMAN report. The -1 sentinel means "not measured" and must never
    # be printed as though it were a latency (dispatch 000172, D1 -- the display half).
    param($Stats, [string]$Field)
    if ($null -eq $Stats -or [int](Get-BenchProp $Stats 'count') -le 0) { return 'n/a (0 samples)' }
    return [string](Get-BenchProp $Stats $Field)
}

# --- the 000061 closed-loop re-check turn (dispatch 000127, N1.5) -----------
# The closed loop fires ONLY on a fresh, settled, ok, NON-CACHED pass (Add-LifecycleSignal's
# gating in pses-daemon.ps1), so a re-check turn is inherently TWO edits: turn 1 surfaces a
# finding, turn 2 changes the file such that the finding is gone and the daemon emits cleared[].
# Only turn 2 -- the re-check -- is timed. Timing a single edit would measure the warm path and
# mislabel it as the closed loop.

# A file whose unapproved verb makes PSUseApprovedVerbs fire (the warm-PSES default surface;
# Write-Host does NOT fire there -- it is not in the PSES 15-rule no-settings set).
$script:BenchLoopDirty = "function Frobnicate-BenchTarget {`n    param([string]`$Name)`n    Get-Process -Name `$Name`n}`n"
# The same file with the finding FIXED (approved verb) -- so turn 2 emits cleared[].
$script:BenchLoopClean = "function Get-BenchTarget {`n    param([string]`$Name)`n    Get-Process -Name `$Name`n}`n"

function Measure-BenchClosedLoopMs {
    # Time ONE 000061 closed-loop re-check turn against an already-warm daemon. Returns
    # @{ Ms; LoopFired } -- Ms is the re-check round-trip, LoopFired reports whether the
    # response actually carried the lifecycle signal. LoopFired is not decoration: if the loop
    # never fires, Ms is just a warm-path number wearing the wrong label, and the harness must
    # say so rather than publish it. $Nonce keeps each iteration's content unique so the
    # daemon's cache-hit path (which skips the loop) is never taken.
    param([string]$ScriptsDir, [string]$DataRoot, [string]$SessionId, [string]$ScratchFile, [int]$Nonce, [int]$CapMs = 25000)
    $stdin = (@{ session_id = $SessionId; tool_input = @{ file_path = $ScratchFile }; cwd = (Split-Path -Parent $ScratchFile) } | ConvertTo-Json -Compress)
    $enc = New-Object System.Text.UTF8Encoding($false)

    # --- turn 1 (NOT timed): surface the finding so the daemon records a prior set ---
    [System.IO.File]::WriteAllText($ScratchFile, ($script:BenchLoopDirty + "# dirty $Nonce`n"), $enc)
    Invoke-BenchHook -ScriptPath (Join-Path $ScriptsDir 'lsp-client.ps1') `
        -StdinJson $stdin -CapMs $CapMs -DataRoot $DataRoot `
        -ExtraEnv @{ CLAUDE_PLUGIN_OPTION_timeoutMs = '18000' } | Out-Null

    # --- turn 2 (TIMED): the finding is fixed -> the re-check emits cleared[] ---
    [System.IO.File]::WriteAllText($ScratchFile, ($script:BenchLoopClean + "# fixed $Nonce`n"), $enc)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = Invoke-BenchHook -ScriptPath (Join-Path $ScriptsDir 'lsp-client.ps1') `
        -StdinJson $stdin -CapMs $CapMs -DataRoot $DataRoot `
        -ExtraEnv @{ CLAUDE_PLUGIN_OPTION_timeoutMs = '18000' }
    $sw.Stop()

    # The client renders the lifecycle signal under its own labelled section.
    $fired = $false
    try { $fired = ([string]$out) -match 'Correction check' } catch { $fired = $false }
    return @{ Ms = [int]$sw.ElapsedMilliseconds; LoopFired = $fired }
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
