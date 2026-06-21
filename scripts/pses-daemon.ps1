#Requires -Version 5.1

# pses-daemon.ps1 -- long-lived, per-session process that owns ONE warm PSES
# child (over stdio) and serves diagnostics requests over a named pipe
# (powershell-lsp-<sessionid>). Keeping PSES warm removes the per-edit cold-start
# that dominated the loose-hook latency.
#
# Transport: named pipe (client<->daemon) + stdio (daemon<->PSES). The stdio side
# is fixed by contract and never changes.
#
# stdout of THIS process is reserved: the daemon writes nothing to stdout. All
# output goes to files under CLAUDE_PLUGIN_DATA/logs. -NoLogo -NoProfile is set on
# the PSES child launch. State/pids/logs live under CLAUDE_PLUGIN_DATA only.
#
# Author: Mike Andersen / powershell-lsp plugin.

param(
    [Parameter(Mandatory = $true)][string] $SessionId,
    [string] $PsHost = 'pwsh',
    # Explicit data root (set by session-start). Decouples the daemon from env
    # inheritance, which is unreliable across a detached launch.
    [string] $DataRoot = '',
    # Quiet window (ms) with no new publish before a diagnostics pass is "settled".
    # Bridges the early parser publish to the slower PSScriptAnalyzer publish. The
    # settle is adaptive (it resets on each publish), so this is the trailing
    # quiet window, not a fixed wait; 600ms keeps warm-path latency near 2s while
    # still clearing the early publish.
    [int] $SettleMs = 600,
    # Coalesce window (ms): edits landing within this window fold into one pass.
    # (Identical-content requests also coalesce via the content-hash cache.)
    [int] $DebounceMs = 150,
    # Hard cap (ms) on waiting for any single settled publish.
    [int] $MaxWaitMs = 5000,
    # Idle TTL (min): self-terminate after this long with no client request.
    [int] $IdleTtlMin = 30,
    # Diagnostics filtering (Stage 4 userConfig knobs).
    [string] $SeverityThreshold = 'Hint',   # least-severe level to report
    [string] $RuleInclude = '',              # comma-separated; empty = all
    [string] $RuleExclude = '',              # comma-separated rule codes to drop
    [int] $PerFileCap = 20,                   # max diagnostics per file (0 = no cap)
    # Explicit PSScriptAnalyzerSettings.psd1 override (absolute). Empty = auto-discover
    # the nearest settings file walked up from the edited file, bounded at the project
    # root (dispatch 000018). Absolute only -- see Resolve-PssaSettingsPath in lib.
    [string] $SettingsPath = '',
    # Supervised PSES re-spawn (dispatch 000022): bound a mid-session crash recovery so a
    # transient PSES exit recovers but a hard-broken PSES does not thrash. MaxPsesRestarts
    # mirrors the manifest's advertised maxRestarts (3) but on the ACTUAL daemon path; the
    # budget is consecutive and resets after any settled pass. NOT a userConfig knob (the
    # native lspServers knobs stay dormant per 000021); daemon-level so a test can force
    # exhaustion by launching the daemon directly with a low value.
    [int] $MaxPsesRestarts = 3,
    [int] $RestartBackoffMs = 500,
    # Init deadline (ms): how long the daemon waits for PSES to answer `initialize` before
    # declaring a PERMANENT first-start failure (pipe-first, dispatch 000028). While waiting,
    # the daemon is already serving the pipe with a transient 'incomplete'; only after this
    # deadline (or a PSES exit) does it flip to a permanent 'unavailable'. 30s mirrors the
    # manifest lspServers.startupTimeout. NOT a userConfig knob; daemon-level so a surfacing
    # test can hold the daemon in 'initializing' (set it high) or force a fast fail.
    [int] $InitTimeoutMs = 30000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/lsp-common.ps1')

# Pin the data root explicitly (a detached launch may not inherit the env var).
if (-not [string]::IsNullOrWhiteSpace($DataRoot)) { $env:CLAUDE_PLUGIN_DATA = $DataRoot }

# Parse rule include/exclude lists once.
$script:RuleIncludeArr = Split-RuleList $RuleInclude
$script:RuleExcludeArr = Split-RuleList $RuleExclude

# --- paths / logging -------------------------------------------------------
$logDir    = Get-LogDir
$sessionDir = Get-SessionDir
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null
$daemonLog = Join-Path $logDir 'pses-daemon.log'
$sessionFile = Join-Path $sessionDir ($SessionId + '.json')

function Write-DLog([string]$m) {
    try { ('[' + (Get-Date -Format 'o') + '] [' + $PID + '] ' + $m) | Out-File -FilePath $daemonLog -Append -Encoding ascii } catch { }
}

# --- shared LSP state ------------------------------------------------------
$script:proc      = $null
$script:stdin     = $null
$script:stdout    = $null
$script:buf       = New-Object System.Collections.Generic.List[byte]
$script:chunk     = New-Object byte[] 16384
$script:pending   = $null
$script:nextId    = 100
$script:initDone  = $false
# Per-URI: latest diagnostics records, last-publish time, a sequence stamp, and
# the content hash that produced them (for coalescing) and open/version state.
$script:diag      = @{}   # uri -> @{ records=@(); at=DateTime; seq=int }
$script:openDocs  = @{}   # uri -> version int
$script:lastHash  = @{}   # uri -> content hash string
$script:respSeen  = @{}   # request id -> $true once a response arrives
$script:respResult = @{}  # request id -> response result body (for codeAction)
$script:reqId     = 1000  # monotonic id for daemon-initiated requests (codeAction)
# PSScriptAnalyzerSettings honoring (000018): lazy-from-first-file. Resolve the
# settings path ONCE on the first analyzed file, then lock -- PSES applies it
# per-session (one analysis engine, rebuilt on a config change), so re-resolving per
# file would force an engine rebuild on the hot path.
$script:settingsResolved  = $false   # have we run the one-time resolve+push yet?
$script:settingsPathInUse = ''        # the absolute settings file honored this session ('' = default rules)
# Supervised re-spawn bookkeeping (000022): psesRestarts is the CONSECUTIVE re-spawn
# count for the current crash episode (reset to 0 after any settled pass); psesGaveUp
# latches once the budget is spent so the exhaustion logs once and the daemon then stays
# up serving 'incomplete'. pssaAvailable records whether the vendored PSScriptAnalyzer was
# present when PSES launched (a false = parser-only degrade for the daemon's whole life).
$script:psesRestarts  = 0
$script:psesGaveUp    = $false
$script:pssaAvailable = $true
# Pipe-first lifecycle (dispatch 000028). The named pipe is created BEFORE PSES is brought
# up, so the daemon can serve an HONEST status while PSES is still starting -- closing the
# no-pipe silent miss (a first edit that raced the old after-init pipe got NOTHING, not even
# a banner). psesState drives what a request is served:
#   'initializing' -> PSES spawned, awaiting `initialize`; serve 'incomplete' (TRANSIENT --
#                     not ready yet, the next edit will be checked). This is sub-case A.
#   'ready'        -> handshake done; serve real diagnostics (or, if PSES died mid-session,
#                     the existing 000022 down/respawn path).
#   'unavailable'  -> PSES could not start at all (missing bundle, OR present-but-failed init
#                     -- the bundle-present failure 000024 left as a silent fail-fast); serve
#                     'unavailable' (PERMANENT this session). This is sub-case B + the 000024
#                     install-missing case, unified under one token (generalized banner prose).
# warmDone latches the one-shot analyzer pre-warm (warm-start rides free on pipe-first).
$script:psesState     = 'initializing'
$script:initSentAt    = [DateTime]::MinValue
$script:warmDone      = $false

function Get-ContentHash([string]$text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
        return [System.BitConverter]::ToString($sha.ComputeHash($bytes))
    } finally { $sha.Dispose() }
}

# --- LSP send/handle/pump --------------------------------------------------
function Send-Lsp([object]$obj) {
    Write-LspFrame -Stream $script:stdin -Json ($obj | ConvertTo-Json -Depth 20 -Compress)
}
function Send-LspResponse($id, [string]$resultJson) {
    $idJson = if ($id -is [string]) { ConvertTo-Json $id -Compress } else { [string]$id }
    Write-LspFrame -Stream $script:stdin -Json ('{"jsonrpc":"2.0","id":' + $idJson + ',"result":' + $resultJson + '}')
}

function Invoke-LspMessage([string]$body) {
    $msg = $null
    try { $msg = $body | ConvertFrom-Json } catch { Write-DLog ('bad json frame: ' + $_.Exception.Message); return }
    $hasId = Test-Prop $msg 'id'
    $hasMethod = Test-Prop $msg 'method'

    if ($hasId -and $hasMethod) {
        # server -> client request: must respond or PSES stalls.
        $method = [string](Get-Prop $msg 'method')
        $id = Get-Prop $msg 'id'
        if ($method -eq 'workspace/configuration') {
            $params = Get-Prop $msg 'params'
            $items = @(Get-Prop $params 'items')
            # Answer each requested item with the scriptAnalysis settings, carrying the
            # resolved settingsPath once known (000018). The push via
            # didChangeConfiguration is the load-bearing channel (PSES's
            # ConfigurationHandler consumes it); this pull response is kept in lockstep
            # so the two never disagree. ConvertTo-Json escapes the (Windows) path.
            $saJson = (New-ScriptAnalysisSettings $script:settingsPathInUse | ConvertTo-Json -Compress -Depth 5)
            $parts = @()
            foreach ($it in $items) { $parts += ('{"scriptAnalysis":' + $saJson + '}') }
            $arr = if ($parts.Count -gt 0) { '[' + ($parts -join ',') + ']' } else { '[]' }
            Send-LspResponse $id $arr
        } else {
            Send-LspResponse $id 'null'
        }
        return
    }
    if ($hasMethod) {
        $method = [string](Get-Prop $msg 'method')
        if ($method -eq 'textDocument/publishDiagnostics') {
            $params = Get-Prop $msg 'params'
            $uri = [string](Get-Prop $params 'uri')
            $key = ConvertTo-UriKey $uri
            $rawDiags = @(Get-Prop $params 'diagnostics')
            $records = @()
            foreach ($d in $rawDiags) { $records += (ConvertTo-DiagRecord $d) }
            # Keep the raw diagnostics too: the codeAction enrichment pass replays
            # them as request context to fetch PSSA suggested corrections.
            $script:diag[$key] = @{ records = $records; raw = $rawDiags; at = (Get-Date); seq = ($script:nextId) }
            Write-DLog ('publishDiagnostics ' + $uri + ' count=' + $records.Count)
        }
        return
    }
    if ($hasId) {
        $id = Get-Prop $msg 'id'
        $script:respSeen[[string]$id] = $true
        # Capture the result body so request/response calls (codeAction) can read
        # it; previously a response was acknowledged but its payload discarded.
        $script:respResult[[string]$id] = (Get-Prop $msg 'result')
    }
}

function Invoke-LspPump {
    # Pump available PSES output through the handler. Returns once $Until is true
    # or $MaxMs elapses. Keeps a single outstanding async read so a poll timeout
    # never starts a second concurrent read.
    param([scriptblock]$Until, [int]$MaxMs = 250, [int]$PollMs = 60)
    $deadline = (Get-Date).AddMilliseconds($MaxMs)
    while ($true) {
        $f = Read-LspFrame -Buffer $script:buf
        while ($null -ne $f) { Invoke-LspMessage $f; $f = Read-LspFrame -Buffer $script:buf }
        if (& $Until) { return $true }
        $remMs = [int][Math]::Max(0, ($deadline - (Get-Date)).TotalMilliseconds)
        if ($remMs -le 0) { return (& $Until) }
        if ($script:proc.HasExited) { Write-DLog 'PSES child exited during pump'; return (& $Until) }
        if ($null -eq $script:pending) {
            $script:pending = $script:stdout.ReadAsync($script:chunk, 0, $script:chunk.Length)
        }
        $wait = [Math]::Min($remMs, $PollMs)
        if ($script:pending.Wait($wait)) {
            $count = $script:pending.Result
            $script:pending = $null
            if ($count -le 0) { Write-DLog 'PSES stdout closed'; return (& $Until) }
            $sub = New-Object byte[] $count
            [Array]::Copy($script:chunk, 0, $sub, 0, $count)
            $script:buf.AddRange($sub)
        }
    }
}

# --- PSES child lifecycle --------------------------------------------------
function Start-PsesProcess {
    # Spawn the PSES child and SEND `initialize` -- NON-BLOCKING (dispatch 000028). Returns
    # $true once the process is started and initialize is on the wire; the response is awaited
    # cooperatively by Complete-PsesInit so the daemon can serve the pipe (an honest transient
    # 'incomplete') WHILE PSES initializes. Returns $false when PSES cannot even be launched
    # (start script missing / no host / spawn threw) -- the caller comes up serving the
    # permanent 'unavailable' over the already-open pipe (never the old exit-before-pipe).
    $startScript = Get-PsesStartScript
    if (-not (Test-Path -LiteralPath $startScript)) {
        Write-DLog ('PSES start script missing: ' + $startScript); return $false
    }
    $bundleRoot = Get-PsesBundleRoot
    $hostExe = Resolve-PsHost $PsHost
    if ($null -eq $hostExe) { Write-DLog 'no PowerShell host found (pwsh/powershell)'; return $false }
    if ($hostExe -ne $PsHost) { Write-DLog ('requested host ' + $PsHost + ' unavailable; using ' + $hostExe) }

    $stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff')
    $pseLog = Join-Path $logDir ('pses-server-' + $stamp + '.log')
    $sess = Join-Path $logDir ('pses-server-' + $stamp + '.json')
    $errLog = Join-Path $logDir ('pses-stderr-' + $stamp + '.log')

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $hostExe
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $logDir
    Add-ProcessArguments $psi @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $startScript,
        '-HostName', 'Claude Code PSES Daemon', '-HostProfileId', 'cc-pses-daemon', '-HostVersion', (Get-PluginVersion),
        '-BundledModulesPath', $bundleRoot,
        '-LogPath', $pseLog, '-LogLevel', 'Information',
        '-SessionDetailsPath', $sess,
        '-Stdio')
    # Make the vendored PSScriptAnalyzer visible to PSES so the analyzer pass runs.
    $pssaDir = Get-PssaModuleDir
    if (Test-Path -LiteralPath $pssaDir) {
        $script:pssaAvailable = $true
        $psi.EnvironmentVariables['PSModulePath'] = $pssaDir + [System.IO.Path]::PathSeparator + $env:PSModulePath
        Write-DLog ('prepended vendored PSSA to child PSModulePath: ' + $pssaDir)
    } else {
        # R6-surfaced (000022): record the reduced capability so every pass this daemon
        # serves carries the 'degraded' (parser-only) status -- not a silent reduced pass.
        $script:pssaAvailable = $false
        Write-DLog ('vendored PSSA dir absent (' + $pssaDir + '); analyzer pass is parser-only (degraded)')
    }

    try {
        Write-DLog ('launching PSES via ' + $hostExe)
        $script:proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Write-DLog ('PSES process start threw: ' + $_.Exception.Message); $script:proc = $null; return $false
    }
    $script:stdin = $script:proc.StandardInput.BaseStream
    $script:stdout = $script:proc.StandardOutput.BaseStream
    $errFs = [System.IO.File]::Open($errLog, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    $null = $script:proc.StandardError.BaseStream.CopyToAsync($errFs)

    # initialize handshake (declares rename -> avoids PSES v4.6.0 NRE; see lib).
    $rootUri = ConvertTo-FileUri (Get-Location).Path
    # [trackA] initialize OMITS workspaceFolders to dodge the PSES v4.6.0 Linux
    # OnInitialize NRE (#2300); the omission and its full rationale live in
    # New-InitializeParams (lib/lsp-common.ps1) and are guarded by the unit suite.
    Send-Lsp @{
        jsonrpc = '2.0'; id = 1; method = 'initialize'
        params = (New-InitializeParams -RootUri $rootUri -ProcessId $PID)
    }
    $script:initSentAt = Get-Date
    $script:psesState = 'initializing'
    Write-DLog 'PSES launched; initialize sent (awaiting response, non-blocking)'
    return $true
}

function Complete-PsesReady {
    # PSES has answered `initialize`: finish the handshake (initialized + scriptAnalysis
    # enable), flip to 'ready', record it, and pre-warm the analyzer. Shared by BOTH the
    # cooperative first-init (Complete-PsesInit) and the blocking respawn (Start-Pses), so the
    # "PSES is up => warmed and ready" invariant holds on either path.
    Send-Lsp @{ jsonrpc = '2.0'; method = 'initialized'; params = @{} }
    Send-Lsp @{ jsonrpc = '2.0'; method = 'workspace/didChangeConfiguration'; params = @{ settings = @{ powershell = @{ scriptAnalysis = @{ enable = $true } } } } }
    $script:initDone = $true
    $script:psesState = 'ready'
    Write-DLog 'PSES initialized'
    Write-SessionFile $pipeName 'ready'
    Invoke-WarmStart
}

function Invoke-WarmStart {
    # Warm-start (dispatch 000028), the latency win that rides FREE on pipe-first: right after
    # PSES goes ready, drive ONE synthetic in-memory didOpen so PSScriptAnalyzer loads +
    # compiles its rule engine NOW, in the idle gap before the user's first real edit -- so
    # that edit pays only the per-file cost (~0.8s), not the analyzer cold-start (measured
    # ~0.77s warm / ~2.2s cold-box on top). Default rules (the per-file settingsPath push stays
    # lazy-from-first-file and is cheap, ~0ms measured). Result is discarded. BEST-EFFORT and
    # off the request path: any failure is swallowed -- warm-start is an optimization layered
    # on top, never a correctness dependency (a failed warm just means the first edit self-warms
    # as before). One-shot per PSES (re-armed on a respawn via Reset-PsesState).
    if ($script:warmDone) { return }
    $script:warmDone = $true
    if (-not (Test-PsesAlive)) { return }
    try {
        $warmFile = Join-Path $logDir '__warmup__.ps1'
        $warmText = "function Warmup-Pses {`n    Get-Process`n}`n"   # unapproved verb -> a real PSSA pass
        [System.IO.File]::WriteAllText($warmFile, $warmText, (New-Object System.Text.UTF8Encoding($false)))
        $warmUri = ConvertTo-FileUri $warmFile
        $warmKey = ConvertTo-UriKey $warmUri
        if ($script:diag.ContainsKey($warmKey)) { $script:diag.Remove($warmKey) | Out-Null }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Send-Lsp @{ jsonrpc = '2.0'; method = 'textDocument/didOpen'
            params = @{ textDocument = @{ uri = $warmUri; languageId = 'powershell'; version = 0; text = $warmText } } }
        Invoke-LspPump -Until { $script:diag.ContainsKey($warmKey) } -MaxMs $MaxWaitMs | Out-Null
        $sw.Stop()
        # didClose + drop the synthetic entry so PSES holds no phantom doc and the warm-up
        # publish never collides with a real request's key.
        Send-Lsp @{ jsonrpc = '2.0'; method = 'textDocument/didClose'
            params = @{ textDocument = @{ uri = $warmUri } } }
        if ($script:diag.ContainsKey($warmKey)) { $script:diag.Remove($warmKey) | Out-Null }
        Write-DLog ('warm-start: analyzer pre-warmed in ' + [int]$sw.ElapsedMilliseconds + 'ms (informational, non-gating)')
    } catch {
        Write-DLog ('warm-start error (ignored, best-effort): ' + $_.Exception.Message)
    }
}

function Complete-PsesInit {
    # Cooperative, NON-BLOCKING advance of the first-start init (pipe-first). Called each loop
    # iteration while state is 'initializing'. Pumps PSES briefly; on the `initialize` response
    # -> Complete-PsesReady (handshake + warm + ready). On a PSES exit or the init deadline ->
    # declare a PERMANENT first-start failure: serve 'unavailable', NEVER exit (the daemon stays
    # up to surface the honest banner over the already-open pipe). This is exactly the
    # bundle-present init failure that 000024 left as a silent fail-fast (sub-case B); it now
    # reads as 'unavailable' (permanent), distinct from the transient 'incomplete' served while
    # still initializing (sub-case A).
    if ($script:psesState -ne 'initializing') { return }
    Invoke-LspPump -Until { $script:respSeen.ContainsKey('1') } -MaxMs 80 | Out-Null
    if ($script:respSeen.ContainsKey('1')) { Complete-PsesReady; return }
    $exited = ($null -ne $script:proc) -and $script:proc.HasExited
    $timedOut = ((Get-Date) - $script:initSentAt).TotalMilliseconds -ge $InitTimeoutMs
    if ($exited -or $timedOut) {
        $cause = if ($exited) { 'PSES exited during init' } else { ('init timed out after ' + $InitTimeoutMs + 'ms') }
        Write-DLog ('first-start PSES did not initialize (' + $cause + '); serving unavailable (permanent this session)')
        $script:serveUnavailable = $true
        $script:psesState = 'unavailable'
        try { if ($null -ne $script:proc -and -not $script:proc.HasExited) { $script:proc.Kill($true) } } catch { }
        Write-SessionFile $pipeName 'unavailable'
    }
}

function Start-Pses {
    # Blocking bring-up used by the mid-session supervised RESPAWN path (dispatch 000022):
    # spawn, wait for `initialize`, finish the handshake, go ready. Returns $true on success.
    # The FIRST-start bring-up uses Start-PsesProcess + Complete-PsesInit (pipe-first) instead,
    # so the daemon can serve the pipe while PSES initializes; respawn keeps the blocking shape
    # because it already runs off the client's critical path (the idle loop) and is bounded.
    if (-not (Start-PsesProcess)) { return $false }
    if (-not (Invoke-LspPump -Until { $script:respSeen.ContainsKey('1') } -MaxMs $InitTimeoutMs)) {
        Write-DLog 'initialize response not received before deadline'
        return $false
    }
    Complete-PsesReady
    return $true
}

function Stop-Pses {
    if ($null -eq $script:proc) { return }
    try { Send-Lsp @{ jsonrpc = '2.0'; id = 999; method = 'shutdown' } } catch { }
    Start-Sleep -Milliseconds 120
    try { Send-Lsp @{ jsonrpc = '2.0'; method = 'exit' } } catch { }
    Start-Sleep -Milliseconds 120
    try { if (-not $script:proc.HasExited) { $script:proc.Kill($true) } } catch {
        try { if (-not $script:proc.HasExited) { $script:proc.Kill() } } catch { }
    }
    Write-DLog 'PSES stopped'
}

# --- supervised re-spawn (dispatch 000022: the daemon never silently dies) --
function Test-PsesAlive {
    # True only when the PSES child handle exists AND the OS process is still running.
    # StrictMode-safe: a $null proc (e.g. after a failed re-spawn) must read as NOT alive
    # rather than throw on .HasExited. Every PSES touch gates on this.
    return ($null -ne $script:proc) -and (-not $script:proc.HasExited)
}

function Reset-PsesState {
    # Drop ALL per-PSES shared state before a re-spawn so the NEW child starts clean.
    # Each clear is load-bearing -- otherwise the restarted session is silently corrupt:
    #   - respSeen still holding init id '1' would make the new Start-Pses believe
    #     initialize was already answered and skip the handshake wait;
    #   - diag/openDocs/lastHash carrying the dead child's per-URI state would make the
    #     next request send a didChange (not didOpen) for a doc the new PSES never opened
    #     -> no publish -> a FALSE 'incomplete' (the restart proving-test would catch this);
    #   - settingsResolved left $true would skip re-pushing the analyzer settings the new
    #     child needs; buf may hold a half-read frame from the dead child.
    $script:proc = $null
    $script:stdin = $null
    $script:stdout = $null
    $script:pending = $null
    $script:buf.Clear()
    $script:initDone = $false
    $script:diag = @{}
    $script:openDocs = @{}
    $script:lastHash = @{}
    $script:respSeen = @{}
    $script:respResult = @{}
    $script:settingsResolved = $false
    # Re-arm warm-start so the freshly re-spawned (cold) PSES is pre-warmed too, and mark the
    # lifecycle 'respawning' -- a DISTINCT state from first-start 'initializing' so the
    # cooperative first-init (Complete-PsesInit) never grabs a mid-session respawn and wrongly
    # flips it to permanent 'unavailable'; the respawn's Start-Pses flips it back to 'ready' on
    # success, and Get-Diagnostics serves the transient 'incomplete' meanwhile (dispatch 000028).
    $script:warmDone = $false
    $script:psesState = 'respawning'
}

function Restart-Pses {
    # Bounded supervised re-spawn of the PSES child on a mid-session exit (closes R1 + the
    # fatal half of R2). Returns $true when a live PSES is back, $false when the budget is
    # spent or the re-spawn failed. The budget is CONSECUTIVE (psesRestarts) and resets to
    # 0 after any settled pass (Get-Diagnostics), so a transient crash recovers but a PSES
    # that dies every pass exhausts and stops -- no thrash. On exhaustion the daemon does
    # NOT exit: psesGaveUp latches (logged once), the session file flips to 'degraded', and
    # every later request returns 'incomplete' so a dead analyzer is VISIBLE, never silently
    # clean. Backoff escalates (RestartBackoffMs * attempt): cheap for the common single
    # transient, deliberately slower as it approaches giving up. Runs between requests
    # (idle loop), off the client's critical path.
    param([string]$Cause)
    if ($script:psesRestarts -ge $MaxPsesRestarts) {
        if (-not $script:psesGaveUp) {
            $script:psesGaveUp = $true
            Write-DLog ('PSES re-spawn budget exhausted (' + $script:psesRestarts + '/' + $MaxPsesRestarts + ', cause=' + $Cause + '); staying up, serving incomplete')
            Write-SessionFile $pipeName 'degraded'
        }
        return $false
    }
    $script:psesRestarts++
    $attempt = $script:psesRestarts
    Write-DLog ('PSES gone (cause=' + $Cause + '); re-spawn attempt ' + $attempt + '/' + $MaxPsesRestarts)
    if ($null -ne $script:proc -and -not $script:proc.HasExited) { try { Stop-Pses } catch { } }
    Reset-PsesState
    $backoff = $RestartBackoffMs * $attempt
    if ($backoff -gt 0) { Start-Sleep -Milliseconds $backoff }
    if (Start-Pses) {
        Write-DLog ('PSES re-spawn attempt ' + $attempt + ' OK (psesPid=' + $script:proc.Id + ')')
        Write-SessionFile $pipeName 'ready'
        return $true
    }
    Write-DLog ('PSES re-spawn attempt ' + $attempt + ' FAILED')
    try { if ($null -ne $script:proc -and -not $script:proc.HasExited) { $script:proc.Kill($true) } } catch { }
    $script:proc = $null
    return $false
}

# --- code-action correction enrichment (Track C) ---------------------------
function Add-CodeActionCorrections {
    # Best-effort: ask PSES for quickfix code actions covering every current
    # diagnostic in ONE textDocument/codeAction request, then thread each
    # suggested correction (replacement text) onto the matching diag record by
    # range-start. Reuses the warm PSES's already-computed markers (no second
    # analyzer pass). Surface-only -- never writes files. Any failure or timeout
    # leaves records unchanged (corrections simply absent), so diagnostics still
    # return: this is purely additive to the warm path.
    param([string]$Uri, [object[]]$RawDiags, [object[]]$Records, [int]$WaitMs = 1500)
    if (@($Records).Count -eq 0 -or @($RawDiags).Count -eq 0) { return }
    try {
        # Full-document range covering every diagnostic (LSP line is 0-based).
        $maxLine = 0
        foreach ($d in $RawDiags) {
            $endLine = [int](Get-Prop (Get-Prop (Get-Prop $d 'range') 'end') 'line')
            if ($endLine -gt $maxLine) { $maxLine = $endLine }
        }
        $docRange = @{ start = @{ line = 0; character = 0 }; end = @{ line = ($maxLine + 1); character = 0 } }

        $script:reqId++
        $id = $script:reqId
        $idKey = [string]$id
        if ($script:respResult.ContainsKey($idKey)) { $script:respResult.Remove($idKey) | Out-Null }
        Send-Lsp @{ jsonrpc = '2.0'; id = $id; method = 'textDocument/codeAction'
            params = @{ textDocument = @{ uri = $Uri }; range = $docRange
                context = @{ diagnostics = @($RawDiags) } } }

        Invoke-LspPump -Until { $script:respResult.ContainsKey($idKey) } -MaxMs $WaitMs | Out-Null
        if (-not $script:respResult.ContainsKey($idKey)) { Write-DLog ('codeAction: no response (id=' + $idKey + ')'); return }
        $result = $script:respResult[$idKey]
        $script:respResult.Remove($idKey) | Out-Null
        if ($null -eq $result) { return }

        # Group correction text by 0-based "line,character" start position. A
        # diagnostic offering several alternative fixes yields several edits at the
        # same start -> primary (first) + count (Q3: primary plus a count).
        $byPos = @{}
        foreach ($action in @($result)) {
            $edit = Get-Prop $action 'edit'
            if ($null -eq $edit) { continue }   # command-only action (e.g. show docs)
            $textEdits = @()
            $docChanges = Get-Prop $edit 'documentChanges'
            if ($null -ne $docChanges) {
                foreach ($dc in @($docChanges)) { $textEdits += @(Get-Prop $dc 'edits') }
            } else {
                $changes = Get-Prop $edit 'changes'
                if ($null -ne $changes) {
                    foreach ($p in $changes.PSObject.Properties) { $textEdits += @($p.Value) }
                }
            }
            foreach ($te in $textEdits) {
                if ($null -eq $te) { continue }
                $start = Get-Prop (Get-Prop $te 'range') 'start'
                $posKey = ([int](Get-Prop $start 'line')).ToString() + ',' + ([int](Get-Prop $start 'character')).ToString()
                if (-not $byPos.ContainsKey($posKey)) { $byPos[$posKey] = New-Object System.Collections.Generic.List[string] }
                [void]$byPos[$posKey].Add([string](Get-Prop $te 'newText'))
            }
        }
        if ($byPos.Count -eq 0) { return }

        $enriched = 0
        foreach ($rec in $Records) {
            $posKey = ([int]$rec.line - 1).ToString() + ',' + ([int]$rec.col - 1).ToString()
            if ($byPos.ContainsKey($posKey)) {
                $list = $byPos[$posKey]
                $rec.correction = [string]$list[0]
                $rec.correctionCount = $list.Count
                $enriched++
            }
        }
        Write-DLog ('codeAction: enriched ' + $enriched + ' of ' + @($Records).Count + ' record(s) for ' + $Uri)
    } catch {
        Write-DLog ('codeAction enrich error (ignored): ' + $_.Exception.Message)
    }
}

# --- diagnostics request (didOpen/didChange + settle) ----------------------
function Measure-CorrectionCount([object[]]$Records) {
    # Telemetry (Track A): how many records carry a suggested fix. Counts only --
    # never reads correction text into the stats line.
    $n = 0
    foreach ($r in @($Records)) { if (-not [string]::IsNullOrWhiteSpace([string]$r.correction)) { $n++ } }
    return $n
}

function Initialize-PssaSettings {
    # Resolve the PSScriptAnalyzerSettings.psd1 to honor and push it to PSES via
    # workspace/didChangeConfiguration -- ONCE, on the first analyzed file
    # (lazy-from-first-file, 000018). PSES applies it per-session (rebuilds its single
    # analysis engine), so this is a one-time configure, not a per-file cost. An
    # ABSOLUTE path is mandatory (Track 1): PSES returns a rooted SettingsPath as-is
    # before its WorkspaceFolders loop, which the daemon leaves empty for the #2300
    # dodge -- so absolute sidesteps the collision with no workspace-root field.
    # Best-effort: any resolve failure leaves the session on PSES default rules.
    param([string]$FilePath, [string]$ProjectRoot)
    if ($script:settingsResolved) { return }
    $script:settingsResolved = $true
    $root = if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot } else { (Get-Location).Path }
    $resolved = ''
    try {
        $resolved = Resolve-PssaSettingsPath -EditedFilePath $FilePath -ProjectRoot $root -Override $SettingsPath
    } catch {
        Write-DLog ('PSSA settings resolve error (ignored, default rules): ' + $_.Exception.Message); return
    }
    if ([string]::IsNullOrWhiteSpace($resolved)) { Write-DLog 'PSSA settings: none resolved (default rules)'; return }
    $script:settingsPathInUse = $resolved
    Send-Lsp @{ jsonrpc = '2.0'; method = 'workspace/didChangeConfiguration'
        params = @{ settings = @{ powershell = @{ scriptAnalysis = (New-ScriptAnalysisSettings $resolved) } } } }
    Write-DLog ('PSSA settings: honoring ' + $resolved)
}

function Get-Diagnostics([string]$filePath, [string]$cwd = '') {
    $full = [System.IO.Path]::GetFullPath($filePath)
    if (-not (Test-Path -LiteralPath $full)) { return @{ ok = $false; error = 'file not found' } }
    $uri = ConvertTo-FileUri $full
    $key = ConvertTo-UriKey $uri

    # Pipe-first serve gate (dispatch 000028, generalizing the 000022/000024 seam). The pipe is
    # open before PSES is ready, so a request can arrive while PSES is still starting, after it
    # permanently failed to start, or after a mid-session death -- in NONE of these may we write
    # to a not-ready/closed stdin or serve empty-as-clean. Return an explicit non-clean status
    # FAST (well within the client hard cap). Precedence: a PERMANENT startup failure
    # ('unavailable' -- missing bundle OR present-but-failed init, 000024 + sub-case B) outranks
    # the TRANSIENT not-ready/down ('incomplete' -- still initializing (sub-case A), or a
    # mid-session exit the idle loop will re-spawn). The two banners are deliberately distinct:
    # 'unavailable' says "won't lint this session, fix + restart"; 'incomplete' says "not checked
    # this time, the next edit will be."
    if ($script:serveUnavailable) {
        Write-DLog ('diagnostics request while unavailable (permanent): ' + $uri)
        return @{ ok = $true; status = 'unavailable'; cached = $false; records = @()
            path = 'daemon-unavailable'; analysisMs = 0; codeActionMs = 0
            recordCount = 0; correctionCount = 0 }
    }
    if ($script:psesState -ne 'ready' -or -not (Test-PsesAlive)) {
        Write-DLog ('diagnostics request while not ready (state=' + $script:psesState + '): ' + $uri)
        return @{ ok = $true; status = 'incomplete'; cached = $false; records = @()
            path = 'daemon-incomplete'; analysisMs = 0; codeActionMs = 0
            recordCount = 0; correctionCount = 0 }
    }

    # 000018: resolve + push the settings path once, before the first didOpen, bounded
    # at the client-forwarded project root (cwd). Gated -- a no-op after the first file.
    Initialize-PssaSettings -FilePath $full -ProjectRoot $cwd

    $text = [System.IO.File]::ReadAllText($full)
    $hash = Get-ContentHash $text

    # Coalesce: identical content already analyzed -> return cached set.
    if ($script:lastHash.ContainsKey($key) -and $script:lastHash[$key] -eq $hash -and $script:diag.ContainsKey($key)) {
        Write-DLog ('cache-hit ' + $uri)
        $cachedRecs = @($script:diag[$key].records)
        return @{ ok = $true; cached = $true; records = $cachedRecs
            path = 'cache-hit'; analysisMs = 0; codeActionMs = 0
            recordCount = $cachedRecs.Count; correctionCount = (Measure-CorrectionCount $cachedRecs) }
    }

    # Debounce: let edits landing within the window fold into one pass, then
    # re-read so we analyze the freshest content exactly once.
    if ($DebounceMs -gt 0) {
        Invoke-LspPump -Until { $false } -MaxMs $DebounceMs | Out-Null
        $text2 = [System.IO.File]::ReadAllText($full)
        if ($text2 -ne $text) { $text = $text2; $hash = Get-ContentHash $text }
    }

    # Clear the prior publish for this uri so the settle waits for a NEW one.
    if ($script:diag.ContainsKey($key)) { $script:diag.Remove($key) | Out-Null }

    if ($script:openDocs.ContainsKey($key)) {
        $ver = [int]$script:openDocs[$key] + 1
        $script:openDocs[$key] = $ver
        Send-Lsp @{ jsonrpc = '2.0'; method = 'textDocument/didChange'
            params = @{ textDocument = @{ uri = $uri; version = $ver }
                contentChanges = @(@{ text = $text }) } }
    } else {
        $script:openDocs[$key] = 0
        Send-Lsp @{ jsonrpc = '2.0'; method = 'textDocument/didOpen'
            params = @{ textDocument = @{ uri = $uri; languageId = 'powershell'; version = 0; text = $text } } }
    }

    # Settle: wait for a publish, then for SettleMs of quiet after the LAST one,
    # capped at MaxWaitMs. This skips the early (often empty) parser publish in
    # favor of the settled PSScriptAnalyzer pass. [trackA] analysisMs spans exactly
    # this didChange->settle window (the debounce above is a separate, fixed wait).
    $swAnalysis = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-LspPump -Until {
        if (-not $script:diag.ContainsKey($key)) { return $false }
        $age = ((Get-Date) - $script:diag[$key].at).TotalMilliseconds
        return ($age -ge $SettleMs)
    } -MaxMs $MaxWaitMs | Out-Null
    $swAnalysis.Stop()

    # Did this pass SETTLE? We cleared $script:diag[$key] before the settle, so its
    # presence now means PSES actually published a result for this uri (regardless of
    # count -- zero diagnostics on a settled pass is genuinely clean). ABSENT means the
    # pass did NOT settle (MaxWaitMs timeout / a non-fatal PSES throw / PSES exited
    # mid-pass): we do NOT know the file is clean. This is the clean-vs-incomplete seam
    # (dispatch 000022, closes the Spine-1 false-clean).
    $entry = if ($script:diag.ContainsKey($key)) { $script:diag[$key] } else { $null }
    $settled = ($null -ne $entry)
    $records = if ($settled) { $entry.records } else { @() }
    $rawDiags = if ($settled -and $entry.Contains('raw')) { @($entry.raw) } else { @() }
    if (-not $settled) {
        $cause = if (-not (Test-PsesAlive)) { 'pses-exited' } else { 'settle-timeout' }
        Write-DLog ('analysis did not settle (cause=' + $cause + ') -> incomplete: ' + $uri)
    } else {
        # A settled pass proves PSES is healthy -- refresh the re-spawn budget so a later,
        # unrelated transient still gets the full count (000022 Q(a): reset-on-recovery).
        $script:psesRestarts = 0
        $script:psesGaveUp = $false
    }
    # Track C: thread PSSA suggested corrections onto the records (in place) via a
    # single codeAction pass -- only when there are findings, so a clean file does
    # no codeAction work and the warm fast path (and the cache-hit path above)
    # stay untouched. [trackA] codeActionMs times that enrichment (0 when skipped).
    $caMs = 0
    if (@($records).Count -gt 0) {
        $swCa = [System.Diagnostics.Stopwatch]::StartNew()
        Add-CodeActionCorrections $uri $rawDiags $records
        $swCa.Stop(); $caMs = [int]$swCa.ElapsedMilliseconds
    }
    # Cache only a SETTLED result -- never poison the content-hash cache with a
    # non-settling pass (else an identical re-edit would serve the empty set as "clean").
    if ($settled) { $script:lastHash[$key] = $hash }
    if (-not $script:diag.ContainsKey($key)) { $script:diag[$key] = @{ records = @(); raw = @(); at = (Get-Date); seq = 0 } }
    Write-DLog ('analyzed ' + $uri + ' -> ' + @($records).Count + ' record(s); settled=' + $settled)
    $recs = @($records)
    # Shape the status: clean (settled + PSSA) | incomplete (did not settle) | degraded
    # (settled but parser-only). ADDITIVE -- attached only when NOT 'ok', so the warm
    # happy-path result (and the client emit) is byte-identical to before.
    $status = Resolve-AnalysisStatus -Settled $settled -PssaAvailable $script:pssaAvailable
    $result = @{ ok = $true; cached = $false; records = $recs
        path = 'daemon-analyze'; analysisMs = [int]$swAnalysis.ElapsedMilliseconds; codeActionMs = $caMs
        recordCount = $recs.Count; correctionCount = (Measure-CorrectionCount $recs) }
    if ($status -ne 'ok') { $result['status'] = $status }
    return $result
}

# --- session file / heartbeat ----------------------------------------------
function Write-SessionFile([string]$pipeName, [string]$state) {
    $obj = [ordered]@{
        sessionId = $SessionId
        pid = $PID
        pipe = $pipeName
        host = $PsHost
        state = $state
        started = $script:startedIso
        heartbeat = (Get-Date -Format 'o')
        psesPid = if ($null -ne $script:proc) { $script:proc.Id } else { $null }
    }
    try { ($obj | ConvertTo-Json -Depth 5) | Out-File -FilePath $sessionFile -Encoding ascii -Force } catch { }
}

# ===========================================================================
$script:startedIso = (Get-Date -Format 'o')
$pipeName = 'powershell-lsp-' + $SessionId
# First-start latch (000024, generalized by 000028): serveUnavailable=$true when PSES cannot be
# brought up AT ALL -- the bundle never bootstrapped (install-missing) OR it is present but fails
# to initialize (sub-case B). Either way the daemon stays up serving the PERMANENT 'unavailable'
# banner over the pipe-first pipe, never dying before the pipe exists (the old exit-1 silent miss).
$script:serveUnavailable = $false
Write-DLog ('--- daemon start: ' + (Get-VersionStamp) + ' session=' + $SessionId + ' pipe=' + $pipeName + ' host=' + $PsHost + ' ---')

# PIPE-FIRST (dispatch 000028): create the named pipe BEFORE bringing PSES up, so the client can
# ALWAYS connect and the daemon can serve an HONEST status while PSES is still starting (or after
# it fails). This is what closes the no-pipe silent miss: the install-failure honesty surface
# (000022->000024) rides this pipe, so the pipe must exist before the first edit can race PSES
# startup. PSES is then brought up NON-BLOCKING and finished cooperatively in the serve loop
# (Complete-PsesInit), so this ordering never blocks the pipe (the 000026 non-blocking spirit,
# carried inside the daemon).
$server = New-Object System.IO.Pipes.NamedPipeServerStream(
    $pipeName, [System.IO.Pipes.PipeDirection]::InOut, 1,
    [System.IO.Pipes.PipeTransmissionMode]::Byte, [System.IO.Pipes.PipeOptions]::Asynchronous)
Write-SessionFile $pipeName 'starting'
Write-DLog 'pipe server ready (PSES initializing)'

if (-not (Start-PsesProcess)) {
    # PSES could not even be launched (missing bundle / no host / spawn threw). Do NOT exit --
    # come up serving the PERMANENT 'unavailable' over the already-open pipe so the first edit
    # shows a VISIBLE banner. This generalizes the 000024 bundle-missing fall-through to ALL
    # "PSES could not start" first-start failures: the bundle-PRESENT init failure 000024 left as
    # a silent fail-fast (exit 1 before the pipe) is now visible too. A PSES that DID spawn but
    # then fails to answer initialize is handled the same way by Complete-PsesInit (in the loop).
    $script:serveUnavailable = $true
    $script:psesState = 'unavailable'
    Write-DLog ('first-start: PSES could not be launched (' + (Get-PsesStartScript) + '); serving unavailable')
    Write-SessionFile $pipeName 'unavailable'
}

$lastActivity = Get-Date
$lastHeartbeat = [DateTime]::MinValue
$connectTask = $null
$running = $true

try {
    while ($running) {
        $now = Get-Date
        if (($now - $lastHeartbeat).TotalSeconds -ge 10) {
            # Keep the heartbeat HONEST: a first-start install/startup failure stays 'unavailable'
            # (000024/000028); an exhausted re-spawn budget stays 'degraded' (000022); a daemon
            # still bringing PSES up reads 'starting' -- none may flip the session file back to
            # 'ready' until PSES actually is.
            Write-SessionFile $pipeName $(if ($script:serveUnavailable) { 'unavailable' } elseif ($script:psesGaveUp) { 'degraded' } elseif ($script:psesState -eq 'ready') { 'ready' } else { 'starting' })
            $lastHeartbeat = $now
        }
        if (($now - $lastActivity).TotalMinutes -ge $IdleTtlMin) {
            Write-DLog ('idle TTL (' + $IdleTtlMin + ' min) reached; shutting down')
            break
        }
        # Pipe-first first-start (dispatch 000028): while PSES is still initializing, advance the
        # handshake cooperatively here -- NON-BLOCKING, so the loop keeps accepting connections and
        # serving the transient 'incomplete' meanwhile. On the init response -> ready (+ warm-start);
        # on a PSES exit or the init deadline -> permanent 'unavailable' (never exit). Once settled
        # to ready/unavailable the state leaves 'initializing', so this stops running.
        if ($script:psesState -eq 'initializing') { Complete-PsesInit }

        # Supervised re-spawn (dispatch 000022, closes R1 + the fatal half of R2): on a mid-session
        # PSES exit, attempt a bounded re-spawn HERE -- between requests, off the client's critical
        # path -- instead of breaking the loop and exiting. A transient crash recovers before the
        # next edit; an exhausted budget keeps the daemon UP serving 'incomplete' (never silently
        # dead). The daemon exits only on idle-TTL or explicit shutdown. Skipped while serving
        # 'unavailable' (re-spawn cannot conjure a missing/broken bundle) and while first-start is
        # still initializing (Complete-PsesInit owns that path).
        if (-not $script:serveUnavailable -and $script:psesState -ne 'initializing' -and -not (Test-PsesAlive)) { Restart-Pses 'idle-detected' | Out-Null }

        # brief idle drain so PSES server requests get answered between clients (only when ready
        # with a live child to pump)
        if ($script:psesState -eq 'ready' -and (Test-PsesAlive)) { Invoke-LspPump -Until { $false } -MaxMs 40 | Out-Null }

        if ($null -eq $connectTask) { $connectTask = $server.WaitForConnectionAsync() }
        if (-not $connectTask.Wait(500)) { continue }
        $connectTask = $null
        $lastActivity = Get-Date

        try {
            $reader = New-Object System.IO.StreamReader($server, [System.Text.Encoding]::UTF8, $false, 4096, $true)
            $writer = New-Object System.IO.StreamWriter($server, (New-Object System.Text.UTF8Encoding($false)), 4096, $true)
            $writer.NewLine = "`n"; $writer.AutoFlush = $true
            $line = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($line)) { Write-DLog 'empty request'; }
            else {
                $req = $null
                try { $req = $line | ConvertFrom-Json } catch { }
                $action = [string](Get-Prop $req 'action')
                Write-DLog ('request action=' + $action)
                switch ($action) {
                    'diagnostics' {
                        $file = [string](Get-Prop $req 'file')
                        $reqCwd = [string](Get-Prop $req 'cwd')   # project root for settings bound (000018)
                        # Edit-range scoping (000019): the client derives the touched line
                        # range from the PostToolUse structuredPatch and sends it here.
                        # Absent => no scoping (whole-file, byte-identical to pre-000019).
                        # The full marker range lives daemon-side, so the filter runs here
                        # -- BEFORE the per-file cap (scope-then-cap), via Get-ScopedCappedResult.
                        $touched = Get-Prop $req 'touchedRanges'
                        $res = Get-Diagnostics $file $reqCwd
                        if ($res.ok) {
                            # Stable order + dedupe, then severity threshold + rule
                            # include/exclude, then scope to the edit, then cap per file.
                            $ordered = Select-OrderedDiagnostics @($res.records)
                            $filtered = @(Select-FilteredDiagnostics $ordered $SeverityThreshold $script:RuleIncludeArr $script:RuleExcludeArr)
                            $sc = Get-ScopedCappedResult -Records $filtered -Ranges $touched -PerFileCap $PerFileCap
                            $payload = [ordered]@{ ok = $true; action = 'diagnostics'; file = $file
                                cached = [bool]$res.cached; count = @($sc.shown).Count; omitted = [int]$sc.omitted; diagnostics = @($sc.shown)
                                scopeApplied = [bool]$sc.scopeApplied; scopeTotal = [int]$sc.total; scopeSurfaced = [int]$sc.surfaced
                                path = [string]$res.path; analysisMs = [int]$res.analysisMs; codeActionMs = [int]$res.codeActionMs
                                recordCount = [int]$res.recordCount; correctionCount = [int]$res.correctionCount }
                            # Status (000022): additive -- present only on a non-clean pass
                            # (incomplete/degraded), so the warm happy-path payload is
                            # byte-identical to before. The client renders it visibly.
                            if ($res.Contains('status')) { $payload['status'] = [string]$res.status }
                        } else {
                            $payload = [ordered]@{ ok = $false; action = 'diagnostics'; error = $res.error }
                        }
                        $writer.WriteLine(($payload | ConvertTo-Json -Depth 8 -Compress))
                    }
                    'ping' {
                        $psesPidVal = if (Test-PsesAlive) { $script:proc.Id } else { $null }
                        $writer.WriteLine(([ordered]@{ ok = $true; action = 'ping'; pid = $PID; psesPid = $psesPidVal } | ConvertTo-Json -Compress))
                    }
                    'shutdown' {
                        $writer.WriteLine(([ordered]@{ ok = $true; action = 'shutdown' } | ConvertTo-Json -Compress))
                        $running = $false
                    }
                    default {
                        $writer.WriteLine(([ordered]@{ ok = $false; error = ('unknown action: ' + $action) } | ConvertTo-Json -Compress))
                    }
                }
            }
            try { $writer.Flush() } catch { }
        } catch {
            Write-DLog ('request handling error: ' + $_.Exception.Message)
        } finally {
            try { if ($server.IsConnected) { $server.Disconnect() } } catch { }
        }
    }
} finally {
    Write-DLog 'main loop ended; cleanup'
    try { $server.Dispose() } catch { }
    Stop-Pses
    try { if (Test-Path -LiteralPath $sessionFile) { Remove-Item -LiteralPath $sessionFile -Force } } catch { }
    Write-DLog '--- daemon exit ---'
}
