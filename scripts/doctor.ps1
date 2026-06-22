#Requires -Version 5.1

# doctor.ps1 -- preflight self-check for the powershell-lsp plugin. Turns the worst
# onboarding failure mode -- the plugin is enabled but a prerequisite is missing, so
# diagnostics silently do nothing -- into a named, actionable fix-list.
#
# REPORT-ONLY by design (dispatch 000036). It checks prerequisites and bootstrap
# health and tells you how to fix what is wrong; it NEVER downloads, repairs, runs the
# bootstrap, or mutates the environment in any way. (The hub's own 'dispatch doctor
# --fix' is unrelated -- this is the plugin's read-only doctor.)
#
# Each check returns one of three statuses, reusing the plugin's never-silent honesty
# (000024/000028): 'pass'; a specific 'fail' that names the blocked component AND the
# remediation (tied to the README Requirements / Install / Troubleshooting); or an
# honest 'unknown' when it genuinely cannot determine (for example when run outside a
# Claude Code session, where it cannot see the plugin data directory). "Could not check"
# is never silently reported as "checked, fine."
#
# SECURITY BOUNDARY (dispatch 000036, hard fence): this doctor does NOT detect or
# diagnose security-control blocks (WDAC / App Control / AppLocker / ExecutionPolicy /
# Smart App Control / Constrained Language Mode). That surface is the separate ROADMAP
# L3 security track (survey 000032), which on disk has not built a detection surface
# yet. So for an indeterminate failure the doctor emits only a single GENERIC pointer
# (a security control may be blocking the component; see Troubleshooting and the
# forthcoming security work). Zero control-specific probing here.
#
# Usage:  pwsh -File scripts/doctor.ps1
#         pwsh -File scripts/doctor.ps1 -SessionId <claude-code-session-id>   # scope check 6
#
# Exit 0 when no check FAILED (passes and honest unknowns are not failures); exit 1
# when at least one check failed. The script is dot-source safe: dot-sourcing defines
# the functions without running the checks (so the unit tests can exercise the pure
# decision functions in isolation).
#
# Author: Mike Andersen / powershell-lsp plugin.

param(
    # Optional Claude Code session id to scope the daemon-health check (check 6) to a
    # specific session's warm daemon. Empty (default) resolves from $env:CLAUDE_SESSION_ID,
    # then discovers the live daemon(s) under the session data dir. A standalone run has no
    # session id (Claude Code passes it only on hook stdin, never as an env var to a
    # directly-invoked script), so the daemon check stays honest about what it can determine.
    [string] $SessionId = ''
)

. (Join-Path $PSScriptRoot 'lib/lsp-common.ps1')

# ===========================================================================
# Pure decision functions -- env-independent, mockable, unit-tested. Each takes
# already-resolved probe inputs and returns a status object. No I/O here, so the
# decision logic is testable without a live PSES install or network.
# ===========================================================================

function New-DoctorResult {
    # The one status-object shape. ValidateSet pins the vocabulary to pass/fail/unknown
    # (the inbox rule: do not invent new status words) -- an out-of-set status throws.
    param(
        [Parameter(Mandatory = $true)][ValidateSet('pass', 'fail', 'unknown')][string] $Status,
        [Parameter(Mandatory = $true)][string] $Component,
        [string] $Detail = '',
        [string] $Remediation = ''
    )
    return [pscustomobject]@{
        Status      = $Status
        Component   = $Component
        Detail      = $Detail
        Remediation = $Remediation
    }
}

function Test-DoctorPwsh {
    # Check 1: PowerShell 7+ (pwsh) is present and new enough. The plugin's hooks launch
    # under pwsh (README Requirements), so a missing or too-old pwsh means nothing runs.
    # $Found = pwsh on PATH; $Version = its resolved [version] (or $null if undeterminable).
    param([bool] $Found, [version] $Version)
    $component = 'PowerShell 7 (pwsh) host'
    $install = 'Install PowerShell 7: "winget install Microsoft.PowerShell" or https://aka.ms/powershell (README: Requirements).'
    if (-not $Found) {
        return (New-DoctorResult -Status fail -Component $component `
                -Detail 'pwsh was not found on PATH; the plugin hooks launch under pwsh and cannot start without it.' `
                -Remediation $install)
    }
    if ($null -eq $Version) {
        return (New-DoctorResult -Status unknown -Component $component `
                -Detail 'pwsh is on PATH but its version could not be determined.' `
                -Remediation 'Confirm with "pwsh -v" that it reports PowerShell 7 or newer.')
    }
    if ($Version.Major -lt 7) {
        return (New-DoctorResult -Status fail -Component $component `
                -Detail ('found pwsh ' + $Version.ToString() + ' but PowerShell 7+ is required for the hooks (Windows PowerShell 5.1 alone cannot launch them).') `
                -Remediation $install)
    }
    return (New-DoctorResult -Status pass -Component $component `
            -Detail ('pwsh ' + $Version.ToString() + ' is present and satisfies the PowerShell 7+ requirement.'))
}

function Test-DoctorEnabled {
    # Check 2: the plugin is enabled. It ships disabled by default (defaultEnabled:false).
    # The only enablement signal the plugin can observe of ITSELF is its subprocess
    # environment: Claude Code sets CLAUDE_PLUGIN_ROOT for plugin subprocesses.
    # $PluginRootResolved = $true when that env points at THIS plugin. Outside a plugin
    # subprocess we cannot read Claude Code's enabled-plugins registry without inventing
    # its location/schema, so the honest result is UNKNOWN -- never a fabricated fail.
    param([bool] $PluginRootResolved)
    $component = 'Plugin enabled'
    if ($PluginRootResolved) {
        return (New-DoctorResult -Status pass -Component $component `
                -Detail 'the plugin is loaded in this Claude Code session (its plugin environment is present).')
    }
    return (New-DoctorResult -Status unknown -Component $component `
            -Detail 'cannot confirm enablement from outside a Claude Code plugin subprocess (the plugin ships disabled by default).' `
            -Remediation 'Enable it with "/plugin enable powershell-lsp" then start a new session (README: Install). Run this doctor from inside an enabled session for a definitive check.')
}

function Test-DoctorPses {
    # Check 3: the PSES bundle finished bootstrapping. Healthy iff BOTH the per-pin marker
    # AND Start-EditorServices.ps1 are present -- the EXACT pair ensure-pses.ps1 gates its
    # no-op on and pses-stdio.ps1 launches. $DataRootKnown is $false when CLAUDE_PLUGIN_DATA
    # is unset: the doctor then cannot locate the real data dir, so it must NOT report a
    # false "not bootstrapped" -- it returns UNKNOWN.
    param([bool] $DataRootKnown, [bool] $MarkerPresent, [bool] $StartScriptPresent, [string] $PinTag = '')
    $component = 'PSES bundle bootstrapped'
    if (-not $DataRootKnown) {
        return (New-DoctorResult -Status unknown -Component $component `
                -Detail 'cannot locate the plugin data directory (CLAUDE_PLUGIN_DATA is not set), so the bundle state is indeterminate.' `
                -Remediation 'Run this doctor from inside a Claude Code session (where CLAUDE_PLUGIN_DATA is set) for a definitive check.')
    }
    if ($MarkerPresent -and $StartScriptPresent) {
        return (New-DoctorResult -Status pass -Component $component `
                -Detail ('the PSES ' + $PinTag + ' bundle is bootstrapped (marker present and Start-EditorServices.ps1 in place).'))
    }
    $missing = @()
    if (-not $MarkerPresent) { $missing += ('the bootstrap marker (pses-' + $PinTag + '.ok)') }
    if (-not $StartScriptPresent) { $missing += 'Start-EditorServices.ps1' }
    return (New-DoctorResult -Status fail -Component $component `
            -Detail ('the PSES bundle did not finish bootstrapping -- missing ' + ($missing -join ' and ') + '.') `
            -Remediation 'Start a fresh Claude Code session so the SessionStart hook runs ensure-pses; if it persists, the first-run download was likely interrupted (network/proxy) -- see logs/ensure-pses.log (README: Troubleshooting).')
}

function Test-DoctorPssa {
    # Check 4: PSScriptAnalyzer is vendored AND importable. Healthy iff BOTH the per-version
    # marker is present AND the module imports (mirrors ensure-pssa.ps1's own fast-path test).
    # If only the parser runs, analysis is "degraded" (lint rules not checked). Same
    # data-root-unknown -> UNKNOWN rule as the PSES check.
    param([bool] $DataRootKnown, [bool] $MarkerPresent, [bool] $Importable, [string] $PinVersion = '')
    $component = 'PSScriptAnalyzer vendored'
    if (-not $DataRootKnown) {
        return (New-DoctorResult -Status unknown -Component $component `
                -Detail 'cannot locate the plugin data directory (CLAUDE_PLUGIN_DATA is not set), so the analyzer state is indeterminate.' `
                -Remediation 'Run this doctor from inside a Claude Code session for a definitive check.')
    }
    if ($MarkerPresent -and $Importable) {
        return (New-DoctorResult -Status pass -Component $component `
                -Detail ('PSScriptAnalyzer ' + $PinVersion + ' is vendored and importable.'))
    }
    $why = if (-not $MarkerPresent) { 'the vendor marker (.pssa-' + $PinVersion + '.ok) is missing' } else { 'the vendored module is not importable' }
    return (New-DoctorResult -Status fail -Component $component `
            -Detail ('PSScriptAnalyzer ' + $PinVersion + ' is not ready -- ' + $why + '; analysis would run parser-only (degraded -- lint rules NOT checked).') `
            -Remediation 'Start a fresh session so ensure-pssa re-vendors the analyzer; see logs/ensure-pssa.log (README: Diagnostics status, "degraded").')
}

function Test-DoctorHosts {
    # Check 5: the first-run download hosts are reachable. $HostProbes is an array of
    # [pscustomobject]@{ Host=<name>; Reachable=$true|$false|$null }; $null means the probe
    # could not run (UNKNOWN for that host). Any definitely-unreachable host -> fail; else
    # any unknown -> unknown; else pass. Reachability is a preflight convenience, not a
    # guarantee the download will succeed.
    param([object[]] $HostProbes)
    $component = 'First-run download hosts reachable'
    $names = (@($HostProbes) | ForEach-Object { $_.Host }) -join ', '
    $unreachable = @($HostProbes | Where-Object { $_.Reachable -eq $false })
    $unknown = @($HostProbes | Where-Object { $null -eq $_.Reachable })
    if ($unreachable.Count -gt 0) {
        $bad = (@($unreachable) | ForEach-Object { $_.Host }) -join ', '
        return (New-DoctorResult -Status fail -Component $component `
                -Detail ('could not reach ' + $bad + ' on TCP 443; the first-run dependency download would fail.') `
                -Remediation 'PSES and PSScriptAnalyzer are downloaded on first run; ensure these hosts are reachable (check network / proxy / firewall).')
    }
    if ($unknown.Count -gt 0) {
        return (New-DoctorResult -Status unknown -Component $component `
                -Detail ('reachability of ' + $names + ' could not be determined (the probe did not complete).') `
                -Remediation 'Re-run when a network probe is possible, or verify manually that the hosts are reachable.')
    }
    return (New-DoctorResult -Status pass -Component $component `
            -Detail ('reachable on TCP 443: ' + $names + '.'))
}

function Test-DoctorDaemon {
    # Check 6 (dispatch 000037): the warm per-session PSES daemon's RUNTIME health -- is it
    # alive and answering on its named pipe right now? This closes the "installed vs actually
    # working" gap checks 1-5 cannot see: all five can pass while the language server is dead
    # or wedged. REPORT-ONLY -- the probe observes; it never launches, relaunches, repairs, or
    # kills the daemon.
    #
    # The status mapping is HONEST about the 000028 pipe-first + 000030 auto-relaunch semantics
    # (grounded in the 000030 outbox: the recoverable/permanent split is structural at the pipe
    # -- a $null/absent daemon auto-relaunches on the next edit (benign); a daemon parked
    # 'unavailable' is genuinely degraded):
    #   answering its pipe                         -> PASS
    #   alive but parked 'unavailable'/'degraded'  -> FAIL + remediation (the genuine problem)
    #   alive but NOT answering its pipe (wedged)  -> FAIL + remediation
    #   NO daemon present (would auto-relaunch)    -> PASS, benign, says exactly that (never a scary FAIL)
    #   indeterminate from outside the session     -> UNKNOWN
    #
    # Inputs are already-resolved observations (Get-DoctorDaemonObservation does the I/O), so
    # the decision is unit-tested without a live daemon or pipe:
    #   $DataRootKnown : CLAUDE_PLUGIN_DATA is set, so the session dir can be located.
    #   $Determinable  : a single in-scope daemon could be identified ($false = ambiguous --
    #                    several live daemons and no session id to pick THIS session's).
    #   $DaemonPresent : a live daemon (recorded pid alive) is in scope.
    #   $State         : that daemon's recorded session-file state (ready/starting/unavailable/degraded).
    #   $Reachable     : the ping round-trip answered ($true) / did not ($false) / not attempted ($null).
    #   $LiveCount     : how many live daemons were found (for the ambiguous message).
    param(
        [bool] $DataRootKnown,
        [bool] $Determinable,
        [bool] $DaemonPresent,
        [string] $State = '',
        $Reachable = $null,
        [int] $LiveCount = 0
    )
    $component = 'Warm PSES daemon (runtime)'
    $restart = 'Start a fresh Claude Code session to replace the daemon; see logs/pses-daemon.log (README: Diagnostics status).'

    if (-not $DataRootKnown) {
        return (New-DoctorResult -Status unknown -Component $component `
                -Detail 'cannot locate the plugin data directory (CLAUDE_PLUGIN_DATA is not set), so the warm daemon cannot be discovered from outside a session.' `
                -Remediation 'Run this doctor from inside a Claude Code session (where CLAUDE_PLUGIN_DATA is set) for a definitive runtime check.')
    }
    if (-not $Determinable) {
        return (New-DoctorResult -Status unknown -Component $component `
                -Detail ('found ' + $LiveCount + ' live daemons but no session id, so which one serves THIS session cannot be determined from outside it.') `
                -Remediation 'Re-run with -SessionId <session-id> (or from a context that sets CLAUDE_SESSION_ID) to scope the check to this session.')
    }
    if (-not $DaemonPresent) {
        # The benign 000030 case: a $null/absent daemon auto-relaunches on the next edit, so
        # reporting it as a FAIL would lie about a self-healing state. PASS that says so.
        return (New-DoctorResult -Status pass -Component $component `
                -Detail 'no warm daemon is running for this session right now; this is benign -- one auto-relaunches on your next PowerShell edit (dispatch 000030). Nothing to fix.')
    }
    if ($State -eq 'unavailable') {
        return (New-DoctorResult -Status fail -Component $component `
                -Detail 'a daemon is alive but parked "unavailable" -- PowerShell editor services could not start for this session, so edits are NOT being linted (diagnostics stay OFF until it is fixed and the session is restarted).' `
                -Remediation 'Fix the install/startup, then start a fresh Claude Code session; see logs/pses-daemon.log and logs/ensure-pses.log (README: Diagnostics status, "unavailable").')
    }
    if ($State -eq 'degraded') {
        return (New-DoctorResult -Status fail -Component $component `
                -Detail 'a daemon is alive but "degraded" -- its PSES child died and the supervised re-spawn budget is exhausted, so edits return parser-only / incomplete results.' `
                -Remediation 'Start a fresh Claude Code session to get a healthy analyzer; see logs/pses-daemon.log (README: Diagnostics status, "degraded").')
    }
    if ($Reachable -eq $true) {
        $note = if ($State -eq 'starting') { ' (PSES is still initializing; the first edit may read "incomplete" until it is ready).' } else { '.' }
        return (New-DoctorResult -Status pass -Component $component `
                -Detail ('the warm per-session daemon is alive and answered on its named pipe (round-trip ok)' + $note))
    }
    # Live pid but the pipe did not answer within the cap. Pipe-first means a healthy daemon
    # ALWAYS holds its pipe open (dispatch 000028), so an alive-but-silent pipe is a real fault
    # (wedged), distinct from the benign no-daemon case above.
    return (New-DoctorResult -Status fail -Component $component `
            -Detail 'the daemon process is alive but did not answer on its named pipe within the timeout (it may be wedged), so edits would not be checked.' `
            -Remediation $restart)
}

# ===========================================================================
# Live probes -- the environment-dependent half. Kept OUT of the pure functions so
# the decision logic stays unit-testable; these are exercised by the end-to-end run.
# ===========================================================================

function Get-DoctorPwsh {
    # Resolve pwsh on PATH and its version WITHOUT launching a child process (read the
    # ApplicationInfo.Version -- the exe file version, which for pwsh is the PS version).
    try {
        $cmd = Get-Command 'pwsh' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $cmd) { return [pscustomobject]@{ Found = $false; Version = $null } }
        $v = $null
        try { if ($cmd.Version -is [version]) { $v = $cmd.Version } } catch { $v = $null }
        return [pscustomobject]@{ Found = $true; Version = $v }
    } catch { return [pscustomobject]@{ Found = $false; Version = $null } }
}

function Get-DoctorPluginRootResolved {
    # $true iff CLAUDE_PLUGIN_ROOT is set AND its manifest names THIS plugin.
    try {
        $root = $env:CLAUDE_PLUGIN_ROOT
        if ([string]::IsNullOrWhiteSpace($root)) { return $false }
        $manifest = Join-Path $root '.claude-plugin/plugin.json'
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { return $false }
        $name = [string](((Get-Content -LiteralPath $manifest -Raw) | ConvertFrom-Json).name)
        return ($name -eq 'powershell-lsp')
    } catch { return $false }
}

function Get-DoctorDataRootKnown {
    # $true iff CLAUDE_PLUGIN_DATA is set, so Get-PluginDataRoot returns the REAL data dir
    # rather than its temp fallback (which would make marker checks meaningless).
    return (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_PLUGIN_DATA))
}

function Get-DoctorPin {
    # Single source of truth for a pinned version: parse a single-quoted pin variable out of
    # a bootstrap script WITHOUT executing it (the ensure-* scripts have side effects).
    # Returns '' if the variable is not found.
    param([string] $ScriptPath, [string] $VarName)
    try {
        if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { return '' }
        $text = Get-Content -LiteralPath $ScriptPath -Raw
        $rx = [regex] ('(?m)^\s*\$' + [regex]::Escape($VarName) + "\s*=\s*'([^']+)'")
        $m = $rx.Match($text)
        if ($m.Success) { return $m.Groups[1].Value }
        return ''
    } catch { return '' }
}

function Get-DoctorHostsFromScript {
    # Single source of truth for the download hosts: extract the distinct hostnames from a
    # bootstrap script's https:// URL literals (never executes the script).
    param([string] $ScriptPath)
    $found = @()
    try {
        if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { return @() }
        $text = Get-Content -LiteralPath $ScriptPath -Raw
        foreach ($m in [regex]::Matches($text, 'https://([A-Za-z0-9.\-]+)')) {
            $h = $m.Groups[1].Value
            if ($found -notcontains $h) { $found += $h }
        }
    } catch { }
    return @($found)
}

function Test-DoctorPssaImportableProbe {
    # Read-only mirror of ensure-pssa.ps1's importability test (we do not edit that script,
    # so the doctor carries its own copy): $true iff a pinned PSScriptAnalyzer.psd1 under
    # $VendorDir imports and exposes Invoke-ScriptAnalyzer.
    param([string] $VendorDir, [string] $PinVersion)
    try {
        if ([string]::IsNullOrWhiteSpace($VendorDir) -or -not (Test-Path -LiteralPath $VendorDir)) { return $false }
        $manifest = Get-ChildItem -LiteralPath $VendorDir -Recurse -Filter 'PSScriptAnalyzer.psd1' -File -ErrorAction SilentlyContinue |
            Sort-Object { $_.FullName.Length } | Select-Object -First 1
        if ($null -eq $manifest) { return $false }
        $data = Import-PowerShellDataFile -LiteralPath $manifest.FullName
        if (-not [string]::IsNullOrWhiteSpace($PinVersion) -and $data.ModuleVersion -ne $PinVersion) { return $false }
        Import-Module $manifest.FullName -Force -ErrorAction Stop
        return ($null -ne (Get-Command Invoke-ScriptAnalyzer -ErrorAction Stop))
    } catch { return $false }
}

function Test-DoctorHostReachableProbe {
    # TCP connect with a short timeout. $true reachable; $false refused/timed-out/DNS-fail;
    # $null if the probe itself could not run. (Uses System.Net.Sockets -- the doctor is not
    # claimed CLM-safe; security/CLM is explicitly out of scope.)
    param([string] $HostName, [int] $Port = 443, [int] $TimeoutMs = 3000)
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        $completed = $iar.AsyncWaitHandle.WaitOne($TimeoutMs)
        if (-not $completed) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch [System.Net.Sockets.SocketException] {
        return $false
    } catch {
        return $null
    } finally {
        if ($null -ne $client) { try { $client.Close() } catch { } }
    }
}

function Test-DoctorDaemonPingProbe {
    # Read-only liveness round-trip over the warm daemon's named pipe, REUSING the daemon's
    # existing 'ping' action and the SAME one-line-JSON pipe protocol the PostToolUse client
    # uses (lsp-client.ps1 Get-Diagnostics) -- NOT a second client or a parallel protocol. The
    # daemon's 'ping' handler returns {ok,pid,psesPid} WITHOUT touching its PSES child (no
    # didOpen/didChange, no analysis, no state change), so the probe is non-disruptive: it
    # cannot wedge the daemon or steal analysis; it connects, asks, disconnects, like any
    # client (a connection only resets the daemon's idle-TTL timer, exactly as a real edit
    # does -- benign). $true iff a ping response with ok=true came back; $false otherwise.
    param([string] $PipeName, [int] $ConnectTimeoutMs = 1500, [int] $ReadTimeoutMs = 1500)
    $attempts = 0
    while ($attempts -lt 2) {
        $attempts++
        $client = $null
        try {
            $client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $PipeName,
                [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
            $client.Connect($ConnectTimeoutMs)
            $writer = New-Object System.IO.StreamWriter($client, (New-Object System.Text.UTF8Encoding($false)), 4096, $true)
            $writer.NewLine = "`n"; $writer.AutoFlush = $true
            $reader = New-Object System.IO.StreamReader($client, [System.Text.Encoding]::UTF8, $false, 4096, $true)
            $writer.WriteLine('{"action":"ping"}')
            $writer.Flush()
            $readTask = $reader.ReadLineAsync()
            if (-not $readTask.Wait($ReadTimeoutMs)) { return $false }
            $line = $readTask.Result
            if ([string]::IsNullOrWhiteSpace($line)) { return $false }
            $resp = $line | ConvertFrom-Json
            return ([bool](Get-Prop $resp 'ok'))
        } catch {
            # Connect timeout / refused / broken pipe -> not reachable on this attempt; retry once.
        } finally {
            if ($null -ne $client) { try { $client.Dispose() } catch { } }
        }
    }
    return $false
}

function Get-DoctorDaemonObservation {
    # Resolve the daemon-health observation that the pure Test-DoctorDaemon decides on, doing
    # ALL the I/O here (kept out of the pure function so the decision stays unit-testable).
    #
    # Discovery uses the daemon's OWN durable handle -- the per-session details json the daemon
    # writes at <data>/session/<sessionid>.json (sessionId/pid/pipe/state/heartbeat) -- and its
    # OWN liveness notion (recorded pid alive), exactly as session-start's reap does; there is
    # no second discovery path. Session id precedence: explicit $SessionId, then
    # $env:CLAUDE_SESSION_ID, then discovery across all session files. Claude Code does not
    # expose the session id to a directly-invoked doctor (it arrives only on hook stdin), so an
    # unscoped run that finds several live daemons is honestly UNKNOWN, not a guess.
    param([string] $SessionId = '')

    if (-not (Get-DoctorDataRootKnown)) {
        return @{ DataRootKnown = $false; Determinable = $false; DaemonPresent = $false; State = ''; Reachable = $null; LiveCount = 0 }
    }
    $sessionDir = Get-SessionDir
    $sid = $SessionId
    if ([string]::IsNullOrWhiteSpace($sid)) { $sid = [string]$env:CLAUDE_SESSION_ID }
    $scoped = -not [string]::IsNullOrWhiteSpace($sid)

    # Gather candidate handles: the one scoped file, or every session file for discovery.
    $files = @()
    try {
        if ($scoped) {
            $one = Join-Path $sessionDir ($sid + '.json')
            if (Test-Path -LiteralPath $one -PathType Leaf) { $files = @(Get-Item -LiteralPath $one) }
        } else {
            $files = @(Get-ChildItem -LiteralPath $sessionDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
        }
    } catch { $files = @() }

    # A live candidate = a parseable handle whose recorded pid is alive. A dead pid means the
    # daemon is gone (benign-absent); a lingering stale file is NOT a live daemon.
    $live = @()
    foreach ($f in $files) {
        $obj = $null
        try { $obj = (Get-Content -LiteralPath $f.FullName -Raw) | ConvertFrom-Json } catch { $obj = $null }
        if ($null -eq $obj) { continue }
        $recPid = 0; $pv = Get-Prop $obj 'pid'
        if ($null -ne $pv) { try { $recPid = [int]$pv } catch { $recPid = 0 } }
        if ($recPid -le 0) { continue }
        $alive = $false
        try { $alive = ($null -ne (Get-Process -Id $recPid -ErrorAction SilentlyContinue)) } catch { $alive = $false }
        if (-not $alive) { continue }
        $pipe = [string](Get-Prop $obj 'pipe')
        if ([string]::IsNullOrWhiteSpace($pipe)) { $pipe = 'powershell-lsp-' + [string](Get-Prop $obj 'sessionId') }
        $live += [pscustomobject]@{ Pipe = $pipe; State = [string](Get-Prop $obj 'state') }
    }

    if ($live.Count -eq 0) {
        # No live daemon in scope -> the benign 000030 absent-but-relaunchable case.
        return @{ DataRootKnown = $true; Determinable = $true; DaemonPresent = $false; State = ''; Reachable = $null; LiveCount = 0 }
    }
    if (-not $scoped -and $live.Count -gt 1) {
        # Several live daemons and no session id to pick THIS session's -> honest UNKNOWN.
        return @{ DataRootKnown = $true; Determinable = $false; DaemonPresent = $true; State = ''; Reachable = $null; LiveCount = $live.Count }
    }
    $d = $live[0]
    $reachable = Test-DoctorDaemonPingProbe -PipeName $d.Pipe
    return @{ DataRootKnown = $true; Determinable = $true; DaemonPresent = $true; State = $d.State; Reachable = $reachable; LiveCount = 1 }
}

# ===========================================================================
# Compose + render
# ===========================================================================

function Invoke-Doctor {
    # Gather the live probes, run the pure checks, and return the ordered result objects.
    # Separated from rendering so the structured results can be consumed programmatically.
    # $SessionId (optional) scopes the daemon-health check (6) to a specific session.
    param([string] $SessionId = '')
    $scriptsDir = $PSScriptRoot
    $results = @()

    # 1) pwsh 7 host
    $pwsh = Get-DoctorPwsh
    $results += (Test-DoctorPwsh -Found $pwsh.Found -Version $pwsh.Version)

    # 2) plugin enabled
    $results += (Test-DoctorEnabled -PluginRootResolved (Get-DoctorPluginRootResolved))

    # Shared data-root state for the bootstrap-health checks.
    $dataRootKnown = Get-DoctorDataRootKnown
    $dataRoot = Get-PluginDataRoot

    # 3) PSES bundle
    $psesPin = Get-DoctorPin -ScriptPath (Join-Path $scriptsDir 'ensure-pses.ps1') -VarName 'PsesTag'
    $psesMarker = $false
    $psesStart = $false
    if ($dataRootKnown) {
        if (-not [string]::IsNullOrWhiteSpace($psesPin)) {
            $psesMarker = Test-Path -LiteralPath (Join-Path $dataRoot ('pses-' + $psesPin + '.ok'))
        }
        $psesStart = Test-Path -LiteralPath (Get-PsesStartScript)
    }
    $results += (Test-DoctorPses -DataRootKnown $dataRootKnown -MarkerPresent $psesMarker -StartScriptPresent $psesStart -PinTag $psesPin)

    # 4) PSScriptAnalyzer vendored + importable
    $pssaPin = Get-DoctorPin -ScriptPath (Join-Path $scriptsDir 'ensure-pssa.ps1') -VarName 'PssaVersion'
    $vendorDir = Get-PssaModuleDir
    $pssaMarker = $false
    $pssaImportable = $false
    if ($dataRootKnown) {
        if (-not [string]::IsNullOrWhiteSpace($pssaPin)) {
            $pssaMarker = Test-Path -LiteralPath (Join-Path $vendorDir ('.pssa-' + $pssaPin + '.ok'))
        }
        $pssaImportable = Test-DoctorPssaImportableProbe -VendorDir $vendorDir -PinVersion $pssaPin
    }
    $results += (Test-DoctorPssa -DataRootKnown $dataRootKnown -MarkerPresent $pssaMarker -Importable $pssaImportable -PinVersion $pssaPin)

    # 5) first-run download hosts reachable (hosts read single-source from the bootstrap scripts)
    $hostNames = @()
    foreach ($s in @('ensure-pses.ps1', 'ensure-pssa.ps1')) {
        foreach ($h in (Get-DoctorHostsFromScript -ScriptPath (Join-Path $scriptsDir $s))) {
            if ($hostNames -notcontains $h) { $hostNames += $h }
        }
    }
    $hostProbes = @()
    foreach ($h in $hostNames) {
        $hostProbes += [pscustomobject]@{ Host = $h; Reachable = (Test-DoctorHostReachableProbe -HostName $h) }
    }
    $results += (Test-DoctorHosts -HostProbes $hostProbes)

    # 6) warm PSES daemon runtime health (dispatch 000037): is the per-session daemon alive
    # and answering on its named pipe right now? Report-only -- the observation (discovery +
    # the non-disruptive ping round-trip) is resolved live; the pass/fail/unknown decision is
    # pure. This is the runtime bookend to check 3 (which only confirms the bundle is
    # INSTALLED): a user can pass checks 1-5 and still have a dead or wedged language server.
    $daemonObs = Get-DoctorDaemonObservation -SessionId $SessionId
    $results += (Test-DoctorDaemon -DataRootKnown $daemonObs.DataRootKnown -Determinable $daemonObs.Determinable `
            -DaemonPresent $daemonObs.DaemonPresent -State $daemonObs.State -Reachable $daemonObs.Reachable -LiveCount $daemonObs.LiveCount)

    return @($results)
}

function Format-DoctorReport {
    # Render the ordered results as the user-facing fix-list. A single generic security
    # pointer is appended when ANY check did not pass -- the doctor does not probe security
    # controls, so it can only point, never attribute (dispatch 000036 boundary).
    param([object[]] $Results)
    $lines = @()
    $lines += 'powershell-lsp doctor -- preflight self-check (report-only)'
    $lines += ''
    foreach ($r in $Results) {
        $lines += ('  ' + ('{0,-7}' -f $r.Status.ToUpperInvariant()) + '  ' + $r.Component)
        if (-not [string]::IsNullOrWhiteSpace($r.Detail)) { $lines += ('             ' + $r.Detail) }
        if (-not [string]::IsNullOrWhiteSpace($r.Remediation)) { $lines += ('             fix: ' + $r.Remediation) }
    }
    $passN = @($Results | Where-Object { $_.Status -eq 'pass' }).Count
    $failN = @($Results | Where-Object { $_.Status -eq 'fail' }).Count
    $unkN = @($Results | Where-Object { $_.Status -eq 'unknown' }).Count
    $lines += ''
    $lines += ('  summary: ' + $passN + ' pass, ' + $failN + ' fail, ' + $unkN + ' unknown (of ' + @($Results).Count + ' checks)')
    if (($failN + $unkN) -gt 0) {
        $lines += ''
        $lines += '  Note: this doctor checks prerequisites and bootstrap health only. If a check above'
        $lines += '  failed for a reason its fix does not resolve, a security control on a managed machine'
        $lines += '  (an execution or application-control policy) may be blocking the component. The doctor'
        $lines += '  does NOT probe security controls; see the README Troubleshooting section and the'
        $lines += '  ROADMAP security-block detection work (L3).'
    }
    return ($lines -join [Environment]::NewLine)
}

# ===========================================================================
# Entry point -- runs ONLY on direct invocation (pwsh -File ...), not when the script
# is dot-sourced (so the unit tests load the functions without running live probes).
# ===========================================================================
if ($MyInvocation.InvocationName -ne '.') {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $doctorResults = Invoke-Doctor -SessionId $SessionId
    Write-Host (Format-DoctorReport -Results $doctorResults)
    $doctorFailures = @($doctorResults | Where-Object { $_.Status -eq 'fail' }).Count
    if ($doctorFailures -gt 0) { exit 1 } else { exit 0 }
}
