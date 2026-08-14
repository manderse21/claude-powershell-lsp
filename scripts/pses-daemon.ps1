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
    # Base-ruleset opt-in (dispatch 000087). 'pses-default' (default) keeps PSES's 15-rule
    # no-settings allow-list -- byte-for-byte the pre-000087 surface; 'base' resolves the
    # shipped plugin base ruleset when no repo-local settings and no explicit SettingsPath
    # override resolve first. Threaded ONLY into the diagnostics settings resolution
    # (Initialize-PssaSettings); the formatter path keeps its own repo-local/override-only
    # resolution (the base carries no formatter rules).
    [string] $Ruleset = 'pses-default',
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
    [int] $InitTimeoutMs = 30000,
    # Module awareness (dispatch 000101, PL-6): 'off' (default) keeps the diagnostics surface
    # byte-for-byte unchanged (the check never runs; no index load, no installed-modules snapshot);
    # 'suggest' turns on the daemon-side "command N is from module M, which is not installed" hint.
    # The value arrives already canonicalized (off|suggest) from session-start / lsp-client
    # (ConvertTo-ModuleAwarenessMode), and is passed ONLY when 'suggest' (mirrors -Ruleset), so the
    # default path's daemon invocation is byte-identical to pre-000101.
    [string] $ModuleAwareness = 'off',
    # TEST-ONLY injectable seam for the 000101 corpus -- deterministic installed-modules snapshot so
    # the kb/kg fixtures do not depend on what is really installed on the runner. NEVER passed by the
    # production launcher (session-start / lsp-client). '' = production (the real background pre-warm);
    # '__defer__' = the snapshot never latches ready (the fail-safe not-ready fixture); '__empty__' =
    # ready with an EMPTY installed-set (kb1: module absent -> fires); 'A,B' = ready with those names.
    [string] $ModuleAwarenessInstalledInject = '',
    # Reference surfacing (dispatch 000128, N1.2/N1.3): 'off' (default) keeps the diagnostics surface
    # byte-for-byte unchanged (no index, no build, no check); 'counts' turns on the session workspace
    # reference index and the per-edit bare-facts pass. The value arrives already canonicalized
    # (off|counts) from session-start / lsp-client (ConvertTo-ReferenceSurfacingMode), passed ONLY when
    # 'counts' (mirrors -ModuleAwareness), so the default path's daemon invocation is byte-identical.
    [string] $ReferenceSurfacing = 'off',
    # TEST-ONLY injectable seam for the 000128 corpus -- force the reference index to build SYNCHRONOUSLY
    # from this root at load, so the fixtures do not depend on background timing. NEVER passed by the
    # production launcher (which kicks a BACKGROUND build from the first request's cwd). '' = production.
    [string] $ReferenceSurfacingRootInject = ''
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
# Closed-loop agentic correction (dispatch 000061, PL-4 slice 1): per-URI memory of what was
# SURFACED last turn, so the NEXT edit turn can diff this pass against it and confirm a prior
# finding CLEARED or escalate that it is STILL-PRESENT. uri-key -> @{ shapeHash -> @{ ruleId;
# line; message; attempts } }. The daemon is the ONLY per-session-persistent component, so this
# memory can only live here (the PostToolUse client is a fresh process per edit). NOT cleared on
# a PSES respawn (Reset-PsesState) -- it tracks findings about the file, not PSES lifecycle state,
# so a respawn must not wipe the closed-loop memory.
$script:lastSurfaced = @{}
# Per-rule lifecycle persistence (dispatch 000171 leg 2). ONE stamp per daemon process, so the
# sibling log is one file per daemon run and therefore a member of a rolling family that
# session-start.ps1's existing Invoke-LogSweep already trims to keepLastN. Computed once here
# rather than per turn: a per-turn stamp would create a new file every edit and defeat the sweep's
# grouping entirely.
$script:lifecycleStamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff')
# Latched so a persistently unwritable log warns ONCE per daemon, not once per edit. The
# requirement is that a telemetry failure surfaces exactly one warning and never becomes a
# diagnostics failure -- a warning per keystroke would be its own defect.
$script:lifecycleWarned = $false
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
# Module surface cache (PL-6, dispatch 000062): the module surface is parsed ONCE per
# session and cached in the daemon (the only per-session-persistent component). Per-edit
# is then a cache lookup + cheap cross-reference, never a re-parse. Invalidation: the
# cache is refreshed when the manifest file's content hash changes.
$script:moduleCacheManifest = ''    # path to the cached .psd1
$script:moduleCacheHash = ''        # SHA-256 hex of the manifest content (for invalidation)
$script:moduleCacheDegrade = ''     # non-empty = cached indeterminate state (wildcard/dynamic/etc)
$script:moduleCacheFnExports = @()  # FunctionsToExport from the manifest
$script:moduleCacheCmdExports = @() # CmdletsToExport
$script:moduleCacheAliasExports = @()  # AliasesToExport
$script:moduleCacheDefinedNames = @()  # defined function names from the module
$script:moduleCacheExportedNames = $null  # $null = implicitly all; @(...) = explicit list
$script:moduleCacheDefinedAliases = @()          # literal Set-Alias/New-Alias names (dispatch 000128 slice 2)
$script:moduleCacheAliasesIndeterminate = $true  # alias surface cannot be statically verified -> alias check silent
# Format-on-edit (dispatch 000059, PL-8): the vendored PSScriptAnalyzer is imported into THIS
# daemon process ONCE (lazy, on the first format request) so Invoke-Formatter runs on the warm
# path with no cold-start. Latched here so the import cost is paid at most once per daemon.
$script:formatterReady = $false
# Module awareness (PL-6, dispatch 000101): the once-per-session installed-modules snapshot (the
# machine-state rung 6, design B) lives here -- taken by a BACKGROUND pre-warm OFF the critical path
# (a raw runspace; Start-ThreadJob is absent on Windows PowerShell 5.1) so it NEVER delays first-edit
# diagnostics. The shipped command->module index is loaded ONCE. FAIL-SAFE: until the snapshot
# latches ready, the check is SILENT. With the knob 'off' (default) NONE of this runs and the surface
# is byte-for-byte unchanged.
$script:moduleAwarenessMode = ConvertTo-ModuleAwarenessMode $ModuleAwareness
$script:commandModuleIndex = @{}
$script:installedModulesSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$script:installedSnapshotReady = $false      # latch: $true once the snapshot is populated (or injected)
$script:installedSnapshotStarted = $false    # latch: the background pre-warm was kicked (or injection resolved)
$script:snapshotPs = $null                   # background [PowerShell] instance
$script:snapshotAsync = $null                # its IAsyncResult
$script:snapshotRunspace = $null             # its dedicated runspace
if ($script:moduleAwarenessMode -eq 'suggest') {
    $script:commandModuleIndex = Import-CommandModuleIndex
    Write-DLog ('module awareness: mode=suggest; index (' + @($script:commandModuleIndex.Keys).Count + ' entries) loaded')
    # Resolve the TEST-ONLY injection seam deterministically at load (the corpus); production ('')
    # kicks the real background pre-warm at daemon-ready (Complete-PsesReady). Inlined here (not a
    # function) because top-level load runs before the later function definitions are reached.
    $inj = [string]$ModuleAwarenessInstalledInject
    if (-not [string]::IsNullOrWhiteSpace($inj)) {
        $script:installedSnapshotStarted = $true
        if ($inj -eq '__defer__') {
            Write-DLog 'module awareness: installed snapshot DEFERRED (injected not-ready; check stays silent)'
        } else {
            if ($inj -ne '__empty__') {
                foreach ($n in @($inj -split ',')) { $nn = ([string]$n).Trim(); if (-not [string]::IsNullOrWhiteSpace($nn)) { [void]$script:installedModulesSet.Add($nn) } }
            }
            $script:installedSnapshotReady = $true
            Write-DLog ('module awareness: installed snapshot INJECTED (' + $script:installedModulesSet.Count + ' names; ready)')
        }
    }
}

# Reference surfacing (PL-6, dispatch 000128): the session WORKSPACE index (Defs/Refs/Exported/Builtins)
# is built ONCE per session by a BACKGROUND runspace (off the critical path, mirroring the 000101 installed
# snapshot) so the O(repo) parse (survey-measured ~2.4s at 130 files) NEVER delays first-edit diagnostics.
# The build is kicked from the FIRST request's cwd (the project root) -- the daemon has no cwd at launch.
# Until the index latches ready the check is SILENT (fail-safe). With the knob 'off' (default) NONE of this
# runs and the surface is byte-for-byte unchanged. Per-edit is then O(edited file): a parse (SHARED with
# module awareness) + hashtable lookups.
$script:referenceSurfacingMode = ConvertTo-ReferenceSurfacingMode $ReferenceSurfacing
$script:referenceIndex = $null
$script:referenceIndexReady = $false
$script:referenceIndexStarted = $false
$script:refIndexPs = $null                    # background [PowerShell] instance
$script:refIndexAsync = $null                 # its IAsyncResult
$script:refIndexRunspace = $null              # its dedicated runspace
if ($script:referenceSurfacingMode -eq 'counts' -and -not [string]::IsNullOrWhiteSpace($ReferenceSurfacingRootInject)) {
    # TEST seam: synchronous, deterministic build at load (the corpus). Production ('') kicks the real
    # background build at the first request (Start-ReferenceIndexPrewarm).
    try {
        $script:referenceIndex = Build-ReferenceIndex -Root $ReferenceSurfacingRootInject
        $script:referenceIndexStarted = $true
        $script:referenceIndexReady = $true
        Write-DLog ('reference surfacing: index INJECTED (root=' + $ReferenceSurfacingRootInject + '; ' +
            (@($script:referenceIndex['Defs'].Keys).Count) + ' defs, ' + [int]$script:referenceIndex['FileCount'] + ' files; ready)')
    } catch {
        Write-DLog ('reference surfacing: injected build failed (' + $_.Exception.Message + '); staying silent')
    }
}

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
    # Module awareness (dispatch 000101): kick the installed-modules snapshot pre-warm on a background
    # runspace NOW (idle gap, right after PSES is ready), OFF the critical path -- a no-op when the
    # knob is off or the snapshot was test-injected. The first-edit diagnostics never wait on it.
    Start-InstalledSnapshotPrewarm
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
        $resolved = Resolve-PssaSettingsPath -EditedFilePath $FilePath -ProjectRoot $root -Override $SettingsPath -Ruleset $Ruleset
    } catch {
        Write-DLog ('PSSA settings resolve error (ignored, default rules): ' + $_.Exception.Message); return
    }
    if ([string]::IsNullOrWhiteSpace($resolved)) { Write-DLog 'PSSA settings: none resolved (default rules)'; return }
    $script:settingsPathInUse = $resolved
    Send-Lsp @{ jsonrpc = '2.0'; method = 'workspace/didChangeConfiguration'
        params = @{ settings = @{ powershell = @{ scriptAnalysis = (New-ScriptAnalysisSettings $resolved) } } } }
    Write-DLog ('PSSA settings: honoring ' + $resolved)
}

# --- module surface cache (PL-6, dispatch 000062) ----------------------------
# THE COST MODEL: the module surface is parsed ONCE per session and cached in the
# daemon (the only per-session-persistent component). Per-edit is then a cache lookup
# + cheap cross-reference, never a re-parse. Invalidation: the cache is refreshed when
# the manifest (.psd1) content changes (content-hash compare).
#
# The cache stores BOTH the manifest export lists AND the module's defined function
# names, plus a degrade reason when the shape is indeterminate (wildcard '*', dynamic
# Export-ModuleMember, dot-sourcing, etc.).
#
# Surface trigger: project findings are returned ONLY when the edited file is a .psd1
# or a .psm1 (the manifest or the root module file), so unrelated edits never spam
# project findings (the 000058 touch-triggered surfacing).

function Update-ModuleSurfaceCache {
    # Build or refresh the module surface cache from an edited file path. Walks up to
    # find the nearest .psd1, parses exports + RootModule, AST-enumerates defined
    # functions, and caches the result. If the manifest hasn't changed since last cache,
    # this is a no-op. Logs cache state changes.
    param([string]$FilePath)
    $manifestPath = Find-ModuleManifest -FilePath $FilePath
    if ([string]::IsNullOrWhiteSpace($manifestPath)) { return }   # not inside a module tree
    # Check invalidation: refresh only when the manifest file content changed.
    $currentHash = ''
    try {
        $bytes = [System.IO.File]::ReadAllBytes($manifestPath)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $currentHash = [System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '' } finally { $sha.Dispose() }
    } catch { return }
    if ($script:moduleCacheManifest -eq $manifestPath -and $script:moduleCacheHash -eq $currentHash) {
        return   # cache is still fresh
    }
    # Reset the alias-surface cache to the SAFE default (dispatch 000128): every degrade path below inherits
    # "no defined aliases, indeterminate=true" (alias check silent), and only the fully determinate path
    # overrides it -- so a stale alias surface from a previously-cached module can never leak into a degrade.
    $script:moduleCacheDefinedAliases = @()
    $script:moduleCacheAliasesIndeterminate = $true
    # Parse the manifest.
    $exports = Get-ModuleManifestExports -ManifestPath $manifestPath
    if ($null -eq $exports) {
        Write-DLog ('module cache: could not parse manifest ' + $manifestPath)
        $script:moduleCacheManifest = $manifestPath
        $script:moduleCacheHash = $currentHash
        $script:moduleCacheDegrade = 'could not parse manifest'
        $script:moduleCacheFnExports = @()
        $script:moduleCacheCmdExports = @()
        $script:moduleCacheAliasExports = @()
        $script:moduleCacheDefinedNames = @()
        $script:moduleCacheExportedNames = $null
        return
    }
    # Check wildcard -> cache as indeterminate.
    $fnExport = @($exports.FunctionsToExport)
    $cmdExport = @($exports.CmdletsToExport)
    $aliasExport = @($exports.AliasesToExport)
    if ($fnExport -contains '*' -or $cmdExport -contains '*' -or $aliasExport -contains '*') {
        $script:moduleCacheManifest = $manifestPath
        $script:moduleCacheHash = $currentHash
        $script:moduleCacheDegrade = 'wildcard export (*)'
        $script:moduleCacheFnExports = $fnExport
        $script:moduleCacheCmdExports = $cmdExport
        $script:moduleCacheAliasExports = $aliasExport
        $script:moduleCacheDefinedNames = @()
        $script:moduleCacheExportedNames = $null
        Write-DLog ('module cache: ' + $manifestPath + ' uses wildcard exports (indeterminate)')
        return
    }
    # Resolve RootModule and AST-enumerate it.
    $manifestDir = [System.IO.Path]::GetDirectoryName($manifestPath)
    $rootModulePath = Resolve-ModuleRootModulePath -ManifestDir $manifestDir -RootModule ([string]$exports.RootModule)
    if ([string]::IsNullOrWhiteSpace($rootModulePath)) {
        Write-DLog ('module cache: ' + $manifestPath + ' has no RootModule to cross-reference')
        $script:moduleCacheManifest = $manifestPath
        $script:moduleCacheHash = $currentHash
        $script:moduleCacheDegrade = 'no RootModule to inspect'
        $script:moduleCacheFnExports = $fnExport
        $script:moduleCacheCmdExports = $cmdExport
        $script:moduleCacheAliasExports = $aliasExport
        $script:moduleCacheDefinedNames = @()
        $script:moduleCacheExportedNames = $null
        return
    }
    $moduleInfo = Get-ModuleDefinedFunctionNames -ModuleFilePath $rootModulePath
    if (-not [string]::IsNullOrWhiteSpace($moduleInfo.Degrade)) {
        Write-DLog ('module cache: ' + $rootModulePath + ' is indeterminate (' + $moduleInfo.Degrade + ')')
        $script:moduleCacheManifest = $manifestPath
        $script:moduleCacheHash = $currentHash
        $script:moduleCacheDegrade = $moduleInfo.Degrade
        $script:moduleCacheFnExports = $fnExport
        $script:moduleCacheCmdExports = $cmdExport
        $script:moduleCacheAliasExports = $aliasExport
        $script:moduleCacheDefinedNames = $moduleInfo.DefinedNames
        $script:moduleCacheExportedNames = $moduleInfo.ExportedNames
        return
    }
    # Cache the fully determinate surface.
    # Alias surface (dispatch 000128 slice 2): the module's literal alias definitions and whether the
    # alias-orphan check must degrade. A non-empty manifest NestedModules also forces the degrade (aliases
    # could live in a nested module this cross-reference does not parse).
    $aliasSurface = Get-ModuleAliasSurface -ModuleFilePath $rootModulePath
    $nested = @()
    try { $nested = @($exports.Data['NestedModules']) } catch { $nested = @() }
    $nestedPresent = (@($nested | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0)
    $script:moduleCacheManifest = $manifestPath
    $script:moduleCacheHash = $currentHash
    $script:moduleCacheDegrade = ''
    $script:moduleCacheFnExports = $fnExport
    $script:moduleCacheCmdExports = $cmdExport
    $script:moduleCacheAliasExports = $aliasExport
    $script:moduleCacheDefinedNames = $moduleInfo.DefinedNames
    $script:moduleCacheExportedNames = $moduleInfo.ExportedNames
    $script:moduleCacheDefinedAliases = $aliasSurface.DefinedAliases
    $script:moduleCacheAliasesIndeterminate = ([bool]$aliasSurface.Indeterminate -or $nestedPresent)
    Write-DLog ('module cache: cached surface for ' + $manifestPath + ' (' + $fnExport.Count + ' exports, ' + $moduleInfo.DefinedNames.Count + ' defined functions, ' + @($aliasSurface.DefinedAliases).Count + ' defined aliases, aliasesIndeterminate=' + [bool]$script:moduleCacheAliasesIndeterminate + ')')
}

function Get-CachedProjectFindings {
    # Use the cached module surface to compute manifest-consistency findings for the
    # current edited file. Only returns findings when the file is a manifest or root
    # module file. Returns @() for unrelated edits or indeterminate surfaces.
    #
    # DETERMINATE surface -> returns findings (orphan/typo/under-declared) or empty
    #   if consistent.
    # INDETERMINATE (wildcard/dynamic/dot-source) -> returns a single descriptive
    #   entry that the client renders as PROSE, NOT a diagnostic finding.
    param([string]$FilePath)
    if ([string]::IsNullOrWhiteSpace($script:moduleCacheManifest)) { return @() }
    # Surface trigger: only .psd1 (the manifest itself) or .psm1 (the root module).
    $ext = [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()
    if ($ext -ne '.psd1' -and $ext -ne '.psm1') { return @() }
    # On a .psm1 edit, also verify the file is the root module (not an unrelated .psm1).
    if ($ext -eq '.psm1') {
        $full = [System.IO.Path]::GetFullPath($FilePath)
        if ($full -ne [System.IO.Path]::GetFullPath($script:moduleCacheManifest)) {
            $manifestDir = [System.IO.Path]::GetDirectoryName($script:moduleCacheManifest)
            # Check if the edited .psm1 IS the RootModule referenced by the manifest.
            $exports = Get-ModuleManifestExports -ManifestPath $script:moduleCacheManifest
            $rmPath = ''
            if ($null -ne $exports) {
                $rmPath = Resolve-ModuleRootModulePath -ManifestDir $manifestDir -RootModule ([string]$exports.RootModule)
            }
            if ([string]::IsNullOrWhiteSpace($rmPath) -or $full -ne [System.IO.Path]::GetFullPath($rmPath)) {
                return @()   # .psm1 that is NOT the root module -> skip
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($script:moduleCacheDegrade)) {
        # Indeterminate shape: return a single honest-degrade item (rendered as prose
        # by the client, NOT a diagnostic finding).
        return @([pscustomobject]@{
            ruleId = 'ManifestConsistency'; code = 'ManifestConsistency'
            source = 'powershell-lsp'
            severity = 'Information'; line = 1; col = 1
            message = 'Module export surface cannot be determined (' + $script:moduleCacheDegrade + '); manifest-consistency not checked.'
            _indeterminate = $true
        })
    }
    # Determinate: cross-reference.
    $result = Test-ManifestConsistency `
        -FunctionsToExport $script:moduleCacheFnExports `
        -CmdletsToExport $script:moduleCacheCmdExports `
        -AliasesToExport $script:moduleCacheAliasExports `
        -DefinedNames $script:moduleCacheDefinedNames `
        -ExportedNames $script:moduleCacheExportedNames `
        -ManifestPath $script:moduleCacheManifest `
        -DefinedAliases $script:moduleCacheDefinedAliases `
        -AliasesIndeterminate $script:moduleCacheAliasesIndeterminate
    return @($result.Findings)
}

# --- module awareness: installed-modules snapshot + check (dispatch 000101) --
function Start-InstalledSnapshotPrewarm {
    # Kick off the once-per-session installed-modules snapshot (the machine-state rung 6) on a
    # BACKGROUND runspace so the multi-second Get-Module -ListAvailable (survey-MEASURED ~6.3s pwsh /
    # ~11.7s WinPS 5.1) is paid OFF the critical path and NEVER delays first-edit diagnostics. Names
    # suffice. The main path harvests the result lazily (Update-InstalledSnapshotFromBackground);
    # until it latches ready the check is SILENT (fail-safe). One-shot per daemon. A raw runspace +
    # BeginInvoke (NOT Start-ThreadJob -- absent on Windows PowerShell 5.1) keeps it portable to both
    # hosts. Best-effort: any failure leaves ready=$false, so the check simply stays silent.
    if ($script:moduleAwarenessMode -ne 'suggest') { return }
    if ($script:installedSnapshotStarted) { return }   # already started, or resolved by test injection
    $script:installedSnapshotStarted = $true
    try {
        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $rs.Open()
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript('@(Get-Module -ListAvailable -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object -Unique)')
        $script:snapshotRunspace = $rs
        $script:snapshotPs = $ps
        $script:snapshotAsync = $ps.BeginInvoke()
        Write-DLog 'module awareness: installed snapshot pre-warm started (background runspace, off the critical path)'
    } catch {
        Write-DLog ('module awareness: snapshot pre-warm could not start (' + $_.Exception.Message + '); check stays silent')
    }
}

function Update-InstalledSnapshotFromBackground {
    # If the background snapshot completed, harvest its NAME set into $script:installedModulesSet and
    # latch ready. Cheap poll (IsCompleted); a no-op once ready or when no background job is running.
    # FAIL-SAFE: any harvest error latches nothing (the check stays silent). Disposes the runspace
    # exactly once, on completion.
    if ($script:installedSnapshotReady) { return }
    if ($null -eq $script:snapshotAsync -or $null -eq $script:snapshotPs) { return }
    if (-not $script:snapshotAsync.IsCompleted) { return }
    try {
        $result = $script:snapshotPs.EndInvoke($script:snapshotAsync)
        foreach ($n in @($result)) {
            $nm = [string]$n
            if (-not [string]::IsNullOrWhiteSpace($nm)) { [void]$script:installedModulesSet.Add($nm) }
        }
        $script:installedSnapshotReady = $true
        Write-DLog ('module awareness: installed snapshot ready (' + $script:installedModulesSet.Count + ' modules)')
    } catch {
        Write-DLog ('module awareness: snapshot harvest failed (' + $_.Exception.Message + '); staying silent')
    } finally {
        try { $script:snapshotPs.Dispose() } catch { }
        try { if ($null -ne $script:snapshotRunspace) { $script:snapshotRunspace.Dispose() } } catch { }
        $script:snapshotPs = $null; $script:snapshotAsync = $null; $script:snapshotRunspace = $null
    }
}

function Get-ModuleAwarenessFindings {
    # Daemon wrapper for the 000101 module-awareness check (rides the diagnostics merge path). Gated:
    # returns @() unless the knob is 'suggest' AND the installed-modules snapshot has latched ready
    # (fail-safe -- never guess install-state). Parses the edited file, resolves the nearest manifest's
    # RequiredModules, and calls the PURE Find-ModuleAwareness with the session snapshot + shipped
    # index. NEVER throws past its own frame (a throw would be caught by the caller, but this returns
    # @() on any error so the diagnostics pass is untouched). Per-edit cost is O(index membership).
    # -Ast (dispatch 000128): reuse a SHARED edited-file parse when the serve loop already made one (the
    # 000127 survey's budget constraint -- never add a second parse). $null -> parse here (backward compat,
    # and every existing call site / test that omits -Ast is unchanged).
    param([string]$FilePath, $Ast = $null)
    if ($script:moduleAwarenessMode -ne 'suggest') { return @() }
    Update-InstalledSnapshotFromBackground
    if (-not $script:installedSnapshotReady) { return @() }              # snapshot not ready -> SILENT
    if (@($script:commandModuleIndex.Keys).Count -eq 0) { return @() }   # empty/failed index -> nothing to hit
    try {
        $full = [System.IO.Path]::GetFullPath($FilePath)
        $useAst = $Ast
        if ($null -eq $useAst) {
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return @() }
            $useAst = [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$null, [ref]$null)
        }
        if ($null -eq $useAst) { return @() }
        $reqMods = Get-NearestManifestRequiredModules -FilePath $full
        return @(Find-ModuleAwareness -Ast $useAst -Index $script:commandModuleIndex `
                -InstalledModules $script:installedModulesSet -ManifestRequiredModules $reqMods -FilePath $full)
    } catch {
        Write-DLog ('module awareness: check errored (ignored, silent): ' + $_.Exception.Message)
        return @()
    }
}

# --- reference surfacing: session workspace index + check (dispatch 000128) --
function Start-ReferenceIndexPrewarm {
    # Kick the once-per-session workspace reference-index build on a BACKGROUND runspace (off the critical
    # path, mirroring Start-InstalledSnapshotPrewarm) rooted at $Root (the first request's cwd -- the daemon
    # has no cwd at launch). One-shot per daemon. The background script dot-sources the shared lib (no import
    # side effects) and calls Build-ReferenceIndex, returning the index hashtable across the in-process
    # runspace. Best-effort: any failure leaves ready=$false, so the check simply stays silent.
    param([string]$Root)
    if ($script:referenceSurfacingMode -ne 'counts') { return }
    if ($script:referenceIndexStarted) { return }        # already started, or resolved by test injection
    if ([string]::IsNullOrWhiteSpace($Root)) { return }  # no project root yet -> wait for a request that has one
    $script:referenceIndexStarted = $true
    try {
        $libPath = Join-Path $PSScriptRoot 'lib/lsp-common.ps1'
        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $rs.Open()
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript('param($LibPath,$Root) . $LibPath; Build-ReferenceIndex -Root $Root').AddArgument($libPath).AddArgument($Root)
        $script:refIndexRunspace = $rs
        $script:refIndexPs = $ps
        $script:refIndexAsync = $ps.BeginInvoke()
        Write-DLog ('reference surfacing: index build started (background runspace, off the critical path) root=' + $Root)
    } catch {
        Write-DLog ('reference surfacing: index build could not start (' + $_.Exception.Message + '); check stays silent')
    }
}

function Update-ReferenceIndexFromBackground {
    # If the background index build completed, harvest the index hashtable and latch ready. Cheap poll;
    # a no-op once ready or when no background build is running. FAIL-SAFE: any harvest error latches
    # nothing (the check stays silent). Disposes the runspace exactly once, on completion.
    if ($script:referenceIndexReady) { return }
    if ($null -eq $script:refIndexAsync -or $null -eq $script:refIndexPs) { return }
    if (-not $script:refIndexAsync.IsCompleted) { return }
    try {
        $result = $script:refIndexPs.EndInvoke($script:refIndexAsync)
        $idx = $null
        foreach ($o in @($result)) { if ($null -ne $o) { $idx = $o; break } }
        if ($null -ne $idx) {
            $script:referenceIndex = $idx
            $script:referenceIndexReady = $true
            Write-DLog ('reference surfacing: index ready (' + (@($idx['Defs'].Keys).Count) + ' defs, ' + [int]$idx['FileCount'] + ' files)')
        }
    } catch {
        Write-DLog ('reference surfacing: index harvest failed (' + $_.Exception.Message + '); staying silent')
    } finally {
        try { $script:refIndexPs.Dispose() } catch { }
        try { if ($null -ne $script:refIndexRunspace) { $script:refIndexRunspace.Dispose() } } catch { }
        $script:refIndexPs = $null; $script:refIndexAsync = $null; $script:refIndexRunspace = $null
    }
}

function Get-ReferenceSurfacingFindings {
    # Daemon wrapper for the 000128 reference-surfacing pass (rides the diagnostics payload as an additive
    # referenceFindings field). Gated: @() unless the knob is 'counts' AND the session index has latched
    # ready (fail-safe -- never surface against a not-ready index). Uses the SHARED edited-file AST when
    # provided (the 000127 budget constraint -- never add a second parse); parses only as a fallback.
    # NEVER throws past its own frame; per-edit cost is O(edited file) + lookups.
    param([string]$FilePath, $Ast = $null)
    if ($script:referenceSurfacingMode -ne 'counts') { return @() }
    Update-ReferenceIndexFromBackground
    if (-not $script:referenceIndexReady -or $null -eq $script:referenceIndex) { return @() }   # not ready -> SILENT
    try {
        $full = [System.IO.Path]::GetFullPath($FilePath)
        $useAst = $Ast
        if ($null -eq $useAst) {
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return @() }
            $useAst = [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$null, [ref]$null)
        }
        if ($null -eq $useAst) { return @() }
        return @(Find-ReferenceSurfacing -Ast $useAst -Index $script:referenceIndex -EditedFilePath $full)
    } catch {
        Write-DLog ('reference surfacing: check errored (ignored, silent): ' + $_.Exception.Message)
        return @()
    }
}

# --- closed-loop agentic correction (dispatch 000061, PL-4 slice 1) ----------
function Add-LifecycleSignal {
    # Diff THIS pass's findings for the edited URI against what was SURFACED for it last turn
    # ($script:lastSurfaced) and attach two ADDITIVE fields to the response payload:
    #   cleared[]      -- prior-surfaced findings now ABSENT from the whole-file pass (a fix landed).
    #   stillPresent[] -- prior-surfaced findings still present AND overlapping the touched range R
    #                     (the edit tried but did not clear them), bounded at K=2 attempts then ONE
    #                     neutral downgrade, then silence (no indefinite nag). MOVED folds in here.
    # Range identity = Get-DiagnosticShapeHash (ruleId + normalized offending line), reused from the
    # dogfood path, so a line-shifting edit never reads a moved finding as cleared. NEW findings ride
    # the normal diagnostics surface (no lifecycle entry).
    #
    # GATING: runs ONLY on a FRESH, SETTLED, OK pass -- never a cache-hit (identical content re-fire),
    # never incomplete/degraded/unavailable. On any other pass "absent" does NOT mean "cleared", so we
    # skip AND leave the prior memory intact for the next ok pass. The caller wraps this in try/catch,
    # so a throw leaves the payload's core diagnostics byte-identical: the closed loop is strictly
    # additive and can never block or zero a diagnostics pass (the fail-open spine; the 000062 lesson).
    param($Payload, [string]$FilePath, $Res, [object[]]$Surfaced, [bool]$ScopeApplied)
    if ($null -eq $Res) { return }
    if (-not [bool]$Res['ok']) { return }
    if ([bool]$Res['cached']) { return }        # identical content re-fire -> no new lifecycle event
    if ($Res.Contains('status')) { return }     # non-ok pass (incomplete/degraded/unavailable) -> skip
    $full = [System.IO.Path]::GetFullPath($FilePath)
    $key = ConvertTo-UriKey (ConvertTo-FileUri $full)
    # Read the post-edit file ONCE for offending-line snippets (the dogfood path reads it the same way).
    $lines = $null
    try { $lines = [System.IO.File]::ReadAllLines($full) } catch { $lines = $null }
    $fullRecs = @($Res['records'])
    $surf = @(@($Surfaced) | Where-Object { $null -ne $_ })
    $curFull = @($fullRecs | ForEach-Object { New-LifecycleFinding -Record $_ -Lines $lines })
    $curSurf = @($surf | ForEach-Object { New-LifecycleFinding -Record $_ -Lines $lines })
    $prior = if ($script:lastSurfaced.ContainsKey($key)) { $script:lastSurfaced[$key] } else { @{} }
    $diff = Get-FindingLifecycleDiff -PriorMap $prior -CurrentFull $curFull -CurrentSurfaced $curSurf -ScopeApplied $ScopeApplied -MaxAttempts 2
    # Persist the new memory ALWAYS (even when both signals are empty) so a later clear is still seen.
    $script:lastSurfaced[$key] = $diff.NewMap
    $clearedArr = @($diff.Cleared)
    $stillArr = @($diff.StillPresent)
    if ($clearedArr.Count -gt 0) { $Payload['cleared'] = $clearedArr }
    if ($stillArr.Count -gt 0) { $Payload['stillPresent'] = $stillArr }
    if ($clearedArr.Count -gt 0 -or $stillArr.Count -gt 0) {
        Write-DLog ('lifecycle: ' + $clearedArr.Count + ' cleared, ' + $stillArr.Count + ' still-present for ' + $full)
    }

    # --- PER-RULE PERSISTENCE (dispatch 000171 leg 2) --------------------------------------
    # Everything above this point has already happened: $Payload carries its diagnostics and its
    # lifecycle fields, and the in-memory map is updated. This block is PURE TELEMETRY and sits
    # in its OWN try/catch so that a failure here cannot reach the caller's catch, cannot alter
    # $Payload, and cannot change what the user is told about their code.
    #
    # The write is per RULE, not per finding, and lands in a SIBLING log -- the capture record
    # dogfood/diagnostics.jsonl is not touched, so both shipped readers keep their contract.
    try {
        $ledgerKeys = $null
        if ($diff.Contains('LedgerKeys')) { $ledgerKeys = $diff['LedgerKeys'] }
        $records = @(New-LifecycleLedgerRecords -LedgerKeys $ledgerKeys -File $full `
                -Timestamp (Get-Date -Format 'o') -ScopeApplied $ScopeApplied)
        if ($records.Count -gt 0) {
            $ok = Add-LifecycleLedgerEntries -Records $records -Stamp $script:lifecycleStamp
            if (-not $ok -and -not $script:lifecycleWarned) {
                $script:lifecycleWarned = $true
                Write-DLog ('lifecycle ledger: WARNING -- the per-rule lifecycle log could not be written; ' +
                    'lifecycle telemetry is degraded for this daemon. Diagnostics are UNAFFECTED and were ' +
                    'delivered normally. This warning is emitted once per daemon.')
            }
        }
    } catch {
        if (-not $script:lifecycleWarned) {
            $script:lifecycleWarned = $true
            Write-DLog ('lifecycle ledger: WARNING -- threw while persisting per-rule lifecycle records (' +
                $_.Exception.Message + '). Diagnostics are UNAFFECTED. Once per daemon.')
        }
    }
}

function Get-Diagnostics([string]$filePath, [string]$cwd = '') {
    $full = [System.IO.Path]::GetFullPath($filePath)
    if (-not (Test-Path -LiteralPath $full)) { return @{ ok = $false; error = 'file not found' } }
    $uri = ConvertTo-FileUri $full
    $key = ConvertTo-UriKey $uri
    # Module surface cache (PL-6, dispatch 000062): update the cache on every
    # diagnostics request. This is a cheap no-op when the cache is already fresh
    # (only walks up + parses once per session); per-edit is a hash compare.
    Update-ModuleSurfaceCache -FilePath $full

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

# --- format-on-edit: suggest, never rewrite (dispatch 000059, PL-8) ----------
function Initialize-FormatterModule {
    # Import the vendored, pinned-hash PSScriptAnalyzer into THIS daemon process ONCE so
    # Invoke-Formatter is callable on the warm path (no cold-start). Reuses the SAME module
    # ensure-pssa.ps1 vendored (Find-VendoredPssaManifest, lib) -- NO second acquisition path,
    # NO download here. Idempotent and latched: returns $true when Invoke-Formatter is callable,
    # $false otherwise (the caller then degrades honestly). Importing PSSA into the daemon is
    # independent of the PSES child (which gets PSSA via its PSModulePath), so format works even
    # when PSES is down.
    if ($script:formatterReady -and $null -ne (Get-Command Invoke-Formatter -ErrorAction SilentlyContinue)) { return $true }
    if ($null -ne (Get-Command Invoke-Formatter -ErrorAction SilentlyContinue)) { $script:formatterReady = $true; return $true }
    $manifest = Find-VendoredPssaManifest
    if ([string]::IsNullOrWhiteSpace($manifest)) { Write-DLog 'format: vendored PSSA manifest not found (cannot import Invoke-Formatter)'; return $false }
    try {
        Import-Module $manifest -Force -ErrorAction Stop
        $script:formatterReady = ($null -ne (Get-Command Invoke-Formatter -ErrorAction SilentlyContinue))
        if ($script:formatterReady) { Write-DLog ('format: imported vendored PSSA for Invoke-Formatter from ' + $manifest) }
        return $script:formatterReady
    } catch {
        Write-DLog ('format: vendored PSSA import failed: ' + $_.Exception.Message)
        return $false
    }
}

function Get-FormatSuggestion {
    # Run Invoke-Formatter over the edited file on the WARM daemon (no cold-start), honoring the
    # repo's PSScriptAnalyzerSettings.psd1 formatter rules (the SAME resolver diagnostics uses --
    # Resolve-PssaSettingsPath, 000018), and return a SUGGESTION shape (a capped unified diff).
    # NEVER writes the file -- suggest-not-apply is the whole safety posture. Independent of PSES
    # (formatting is pure PSScriptAnalyzer), so it works even when PSES is unavailable/degraded.
    # FAIL-SAFE: every failure returns an honest non-ok formatStatus (the client surfaces nothing)
    # and this never throws past its own frame. The response is ADDITIVE -- a separate action, so
    # the diagnostics path is untouched and (knob off) never sends a 'format' request at all.
    param([string]$filePath, [string]$cwd = '')
    $resp = [ordered]@{ ok = $true; action = 'format'; file = $filePath
        changed = $false; diff = ''; removed = 0; added = 0; truncated = $false
        settingsPath = ''; formatStatus = 'ok' }
    try {
        $full = [System.IO.Path]::GetFullPath($filePath)
        if (-not (Test-Path -LiteralPath $full)) { $resp['formatStatus'] = 'error'; $resp['error'] = 'file not found'; return $resp }
        if (-not (Initialize-FormatterModule)) {
            $resp['formatStatus'] = 'unavailable'; $resp['error'] = 'formatter unavailable'; return $resp
        }
        # Honor the repo settings: explicit absolute override ($SettingsPath, the daemon param) >
        # nearest PSScriptAnalyzerSettings.psd1 walked up from the file, bounded at the project
        # root (cwd) > '' (default style). Same precedence diagnostics applies (000018).
        $root = if (-not [string]::IsNullOrWhiteSpace($cwd)) { $cwd } else { (Get-Location).Path }
        $settings = ''
        try { $settings = Resolve-PssaSettingsPath -EditedFilePath $full -ProjectRoot $root -Override $SettingsPath } catch { $settings = '' }
        $resp['settingsPath'] = $settings
        $text = [System.IO.File]::ReadAllText($full)
        $fmt = Invoke-RepoFormatter -Text $text -SettingsPath $settings
        if (-not $fmt.ok) {
            Write-DLog ('format: formatter degraded (' + [string]$fmt.reason + '): ' + [string]$fmt.error)
            $resp['formatStatus'] = 'error'; $resp['error'] = [string]$fmt.error; return $resp
        }
        $diffRes = Get-FormatDiffResult -Original $text -Formatted ([string]$fmt.formatted)
        $resp['changed'] = [bool]$diffRes.changed
        $resp['diff'] = [string]$diffRes.diff
        $resp['removed'] = [int]$diffRes.removed
        $resp['added'] = [int]$diffRes.added
        $resp['truncated'] = [bool]$diffRes.truncated
        Write-DLog ('format: ' + $full + ' changed=' + $resp['changed'] + ' -' + $resp['removed'] + '/+' + $resp['added'] +
            ' settings=' + $(if ($settings) { $settings } else { '(default)' }))
        return $resp
    } catch {
        Write-DLog ('format: unexpected error (degrading): ' + $_.Exception.Message)
        $resp['formatStatus'] = 'error'; $resp['error'] = $_.Exception.Message; return $resp
    }
}

function Invoke-FormatApply {
    # Format-on-edit APPLY (dispatch 000099). Run the SAME warm formatter Get-FormatSuggestion uses,
    # and -- when it produces a real change -- WRITE the result back GUARDED. Reuses the 000059
    # substrate verbatim (Initialize-FormatterModule, Resolve-PssaSettingsPath, Invoke-RepoFormatter,
    # Get-FormatDiffResult); the ONLY additions are the byte-fidelity encode and the stale-write
    # compare-and-swap + atomic write (Get-ApplyEncodedBytes / Write-FormatResultAtomic in lib, both
    # pure). FAIL-SAFE: every failure returns an honest non-applied formatStatus and never throws
    # past this frame; the file is written ONLY on the happy path and NEVER left torn. formatStatus
    # values (000099, an ADDITIVE daemon->client field, NOT a frozen contract token): 'applied'
    # (wrote), 'apply-aborted' (a guard / encoding / mixed-EOL / write abort -> the client surfaces
    # the suggest fallback with the reason), plus the inherited 'ok' (no change -> no write), 'error',
    # and 'unavailable'. Runs the compare-and-swap read in THIS (writing) process, so the race window
    # is only the daemon-local format runtime -- no IPC hop between the guard read and the write.
    param([string]$filePath, [string]$cwd = '')
    $resp = [ordered]@{ ok = $true; action = 'format'; file = $filePath
        applied = $false; wasModified = $false
        changed = $false; diff = ''; removed = 0; added = 0; truncated = $false
        settingsPath = ''; formatStatus = 'ok' }
    try {
        $full = [System.IO.Path]::GetFullPath($filePath)
        if (-not (Test-Path -LiteralPath $full)) { $resp['formatStatus'] = 'error'; $resp['error'] = 'file not found'; return $resp }
        if (-not (Initialize-FormatterModule)) {
            $resp['formatStatus'] = 'unavailable'; $resp['error'] = 'formatter unavailable'; return $resp
        }
        # CAS INPUT CAPTURE: the raw bytes the formatter is about to consume, and their fingerprint,
        # plus the original BOM state -- the byte-fidelity contract's inputs.
        $origBytes = [System.IO.File]::ReadAllBytes($full)
        $inputHash = Get-Sha256HexFromBytes $origBytes
        $hasBom = Test-Utf8Bom $origBytes
        # Same settings precedence as suggest (000018): explicit override > nearest settings > default.
        $root = if (-not [string]::IsNullOrWhiteSpace($cwd)) { $cwd } else { (Get-Location).Path }
        $settings = ''
        try { $settings = Resolve-PssaSettingsPath -EditedFilePath $full -ProjectRoot $root -Override $SettingsPath } catch { $settings = '' }
        $resp['settingsPath'] = $settings
        # Decode for the formatter exactly as suggest does (ReadAllText: BOM-aware, UTF-8 default).
        $text = [System.IO.File]::ReadAllText($full)
        $fmt = Invoke-RepoFormatter -Text $text -SettingsPath $settings
        if (-not $fmt.ok) {
            Write-DLog ('format-apply: formatter degraded (' + [string]$fmt.reason + '): ' + [string]$fmt.error)
            $resp['formatStatus'] = 'error'; $resp['error'] = [string]$fmt.error; return $resp
        }
        $diffRes = Get-FormatDiffResult -Original $text -Formatted ([string]$fmt.formatted)
        $resp['changed'] = [bool]$diffRes.changed
        $resp['diff'] = [string]$diffRes.diff
        $resp['removed'] = [int]$diffRes.removed
        $resp['added'] = [int]$diffRes.added
        $resp['truncated'] = [bool]$diffRes.truncated
        # NO-CHANGE = NO WRITE: an already-formatted file is never touched (formatStatus stays 'ok',
        # changed=$false -> the client surfaces nothing, exactly like suggest's clean-edit no-op).
        if (-not $diffRes.changed) {
            Write-DLog ('format-apply: ' + $full + ' already formatted -- no write')
            return $resp
        }
        # CONSERVATIVE ABORTS (OQ4 + encoding): a mixed-EOL or UTF-16 file aborts to suggest, so an
        # unchanged minority-EOL line is never flipped and a UTF-16 file is never re-encoded. The diff
        # is already computed, so the client surfaces the suggest fallback naming the reason.
        $eol = Get-DominantEol $text
        $abortReason = ''
        if (Test-Utf16Bom $origBytes) { $abortReason = 'file is UTF-16 (apply supports UTF-8 only)' }
        elseif ($eol -eq 'mixed') { $abortReason = 'file has mixed line endings' }
        if ($abortReason -ne '') {
            Write-DLog ('format-apply: aborting to suggest (' + $abortReason + '): ' + $full)
            $resp['formatStatus'] = 'apply-aborted'; $resp['error'] = $abortReason; return $resp
        }
        # Byte-fidelity output + the stale-write compare-and-swap + atomic write, all in this process.
        $outBytes = Get-ApplyEncodedBytes -FormattedText ([string]$fmt.formatted) -Eol $eol -HasBom $hasBom
        $w = Write-FormatResultAtomic -Full $full -InputHash $inputHash -OutBytes $outBytes
        if ($w.applied) {
            $resp['applied'] = $true; $resp['wasModified'] = $true; $resp['formatStatus'] = 'applied'
            Write-DLog ('format-apply: WROTE ' + $full + ' -' + $resp['removed'] + '/+' + $resp['added'] +
                ' eol=' + $eol + ' bom=' + $hasBom + ' settings=' + $(if ($settings) { $settings } else { '(default)' }))
        } else {
            $resp['formatStatus'] = 'apply-aborted'; $resp['error'] = [string]$w.reason
            Write-DLog ('format-apply: aborted (' + [string]$w.reason + '): ' + $full)
        }
        return $resp
    } catch {
        Write-DLog ('format-apply: unexpected error (degrading): ' + $_.Exception.Message)
        $resp['formatStatus'] = 'apply-aborted'; $resp['error'] = $_.Exception.Message; return $resp
    }
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
$server = New-DaemonPipeServer -PipeName $pipeName
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
# Set when a request leaves the pipe server in a state it cannot accept from again
# (dispatch 000237). Consumed at the top of the accept region below, which disposes the old
# stream and builds a fresh one on the SAME name rather than letting the loop end.
$pipeNeedsRebuild = $false

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

        # ACCEPT, GUARDED (dispatch 000237). This region used to sit BARE inside the loop's
        # outer try, which is the whole of why an abandoned reply killed the daemon: a stream
        # left unusable by the previous request threw HERE, past the per-request handler, and
        # straight into the outer finally. The primary cure is one line further down (the
        # unconditional Disconnect in the per-request finally); this is the structural
        # backstop, so no future way of leaving the stream unusable can end the process
        # either. A pipe server that cannot be armed is a pipe server to REBUILD, not a
        # reason to stop serving.
        if ($pipeNeedsRebuild) {
            try { $server.Dispose() } catch { }
            $server = New-DaemonPipeServer -PipeName $pipeName
            $connectTask = $null
            $pipeNeedsRebuild = $false
            Write-DLog 'pipe server rebuilt on the same name; still serving'
        }
        $connected = $false
        try {
            if ($null -eq $connectTask) { $connectTask = $server.WaitForConnectionAsync() }
            $connected = $connectTask.Wait(500)
        } catch {
            Write-DLog ('accept failed (' + $_.Exception.Message + '); rebuilding the pipe server and continuing')
            $connectTask = $null
            $pipeNeedsRebuild = $true
            continue
        }
        if (-not $connected) { continue }
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
                        # Reference surfacing (dispatch 000128): kick the once-per-session BACKGROUND
                        # workspace-index build from the FIRST request's cwd (the project root -- the daemon
                        # has none at launch). One-shot; silent until ready; a no-op when the knob is off or
                        # the index already started. NEVER on the critical path (the build runs on its own
                        # runspace; this call just starts it and returns).
                        if ($script:referenceSurfacingMode -eq 'counts') { Start-ReferenceIndexPrewarm -Root $reqCwd }
                        # Edit-range scoping (000019): the client derives the touched line
                        # range from the PostToolUse structuredPatch and sends it here.
                        # Absent => no scoping (whole-file, byte-identical to pre-000019).
                        # The full marker range lives daemon-side, so the filter runs here
                        # -- BEFORE the per-file cap (scope-then-cap), via Get-ScopedCappedResult.
                        $touched = Get-Prop $req 'touchedRanges'
                        $res = Get-Diagnostics $file $reqCwd
                        if ($res.ok) {
                            # Module awareness (dispatch 000101): merge daemon-side ModuleNotInstalled
                            # Information hints into the records so they ride the SAME order + severity
                            # + scope + cap pipeline as PSES diagnostics. Gated: knob 'suggest' AND a
                            # CLEAN pass (never incomplete/degraded/unavailable -- a status-carrying
                            # pass leaves the surface untouched). ADDITIVE + FAIL-SAFE: the wrapper
                            # returns @() when the snapshot is not ready or on any error, and this
                            # try/catch guarantees a throw never zeroes or blocks the diagnostics pass.
                            # With the knob OFF the whole block is skipped -> byte-for-byte unchanged.
                            # Shared edited-file parse (dispatch 000128): module awareness (000101) and
                            # reference surfacing (000128) both need the edited file's AST. Parse it AT MOST
                            # ONCE here and hand it to both -- the 000127 survey's budget constraint (never
                            # add a second parse). Only on a CLEAN settled pass, and only when at least one of
                            # the two knobs is active, so the knob-off path parses nothing extra and the
                            # surface is byte-for-byte unchanged.
                            $maRecords = @()
                            $refRecords = @()
                            if (-not $res.Contains('status')) {
                                $sharedEditedAst = $null
                                if ($script:moduleAwarenessMode -eq 'suggest' -or $script:referenceSurfacingMode -eq 'counts') {
                                    try {
                                        $sharedFull = [System.IO.Path]::GetFullPath($file)
                                        if (Test-Path -LiteralPath $sharedFull -PathType Leaf) {
                                            $sharedEditedAst = [System.Management.Automation.Language.Parser]::ParseFile($sharedFull, [ref]$null, [ref]$null)
                                        }
                                    } catch { $sharedEditedAst = $null }
                                }
                                if ($script:moduleAwarenessMode -eq 'suggest') {
                                    try { $maRecords = @(Get-ModuleAwarenessFindings -FilePath $file -Ast $sharedEditedAst) }
                                    catch { $maRecords = @(); Write-DLog ('module awareness merge error (ignored): ' + $_.Exception.Message) }
                                }
                                if ($script:referenceSurfacingMode -eq 'counts') {
                                    try { $refRecords = @(Get-ReferenceSurfacingFindings -FilePath $file -Ast $sharedEditedAst) }
                                    catch { $refRecords = @(); Write-DLog ('reference surfacing merge error (ignored): ' + $_.Exception.Message) }
                                }
                            }
                            # Stable order + dedupe, then severity threshold + rule
                            # include/exclude, then scope to the edit, then cap per file.
                            $ordered = Select-OrderedDiagnostics (@($res.records) + @($maRecords))
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
                            # Project findings (PL-6, dispatch 000062): manifest-consistency
                            # check from the cached module surface. Only surfaces when the
                            # edited file is the manifest or root module. Additive to the
                            # payload, never replaces diagnostics.
                            $projectFinds = Get-CachedProjectFindings -FilePath $file
                            if ($null -ne $projectFinds -and @($projectFinds).Count -gt 0) {
                                $payload['projectFindings'] = @($projectFinds)
                                Write-DLog ('project findings: ' + @($projectFinds).Count + ' for ' + $file)
                            }
                            # Reference surfacing (dispatch 000128): the bare per-function facts computed
                            # above ride here as an ADDITIVE referenceFindings field, rendered by the client
                            # in its own 'References:' section. Absent when the knob is off or the index is
                            # not ready or the file has nothing provable -> the payload is byte-identical.
                            if ($refRecords.Count -gt 0) {
                                $payload['referenceFindings'] = @($refRecords)
                                Write-DLog ('reference surfacing: ' + $refRecords.Count + ' fact(s) for ' + $file)
                            }
                            # Closed-loop agentic correction (dispatch 000061): diff this pass
                            # against last turn's surfaced set for this URI -> additive cleared[]/
                            # stillPresent[] fields. FAIL-OPEN: any failure leaves $payload's core
                            # diagnostics byte-identical -- the loop never blocks or zeroes a pass.
                            try {
                                Add-LifecycleSignal -Payload $payload -FilePath $file -Res $res -Surfaced @($sc.shown) -ScopeApplied ([bool]$sc.scopeApplied)
                            } catch {
                                Write-DLog ('lifecycle signal error (ignored, additive): ' + $_.Exception.Message)
                            }
                        } else {
                            $payload = [ordered]@{ ok = $false; action = 'diagnostics'; error = $res.error }
                        }
                        $writer.WriteLine(($payload | ConvertTo-Json -Depth 8 -Compress))
                    }
                    'format' {
                        # Format-on-edit (dispatch 000059 suggest; 000099 apply). A SEPARATE action
                        # from 'diagnostics' -- the client sends it only when the formatOnEdit knob is
                        # on, so with the knob off (the default) this branch is never reached and the
                        # diagnostics surface is byte-for-byte unchanged. The request's optional 'apply'
                        # flag selects the path: absent/false -> Get-FormatSuggestion (a unified-diff
                        # SUGGESTION, never a rewritten file -- the 000059 behavior, unchanged); true ->
                        # Invoke-FormatApply (the GUARDED write-back, 000099). Both reuse the one warm
                        # formatter + repo-settings resolution.
                        $file = [string](Get-Prop $req 'file')
                        $reqCwd = [string](Get-Prop $req 'cwd')
                        $doApply = [bool](Get-Prop $req 'apply')
                        $payload = if ($doApply) { Invoke-FormatApply $file $reqCwd } else { Get-FormatSuggestion $file $reqCwd }
                        $writer.WriteLine(($payload | ConvertTo-Json -Depth 6 -Compress))
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
            # THE PRIMARY CURE (dispatch 000237). This line used to read
            #   try { if ($server.IsConnected) { $server.Disconnect() } } catch { }
            # and the IsConnected guard was the bug. A reply write to a client that walked
            # away at its hard cap raises "Pipe is broken." and, in doing so, moves the
            # stream's internal state from Connected to BROKEN -- so IsConnected reads FALSE
            # and the disconnect was SKIPPED on precisely the path that needed it. The stream
            # stayed Broken, and the next accept (guarded above) threw past this handler into
            # the outer finally: four daemon deaths per session, one per abandoned reply.
            # Disconnect() is willing to take a Broken stream back to Disconnected; only the
            # guard stopped it being asked. One abandoned reply is now one discarded write.
            $reset = Reset-PipeServerConnection -Server $server
            if (-not $reset.Ok) {
                Write-DLog ('pipe server not reusable after this request (' + $reset.Reason +
                            '); rebuilding before the next accept')
                $pipeNeedsRebuild = $true
            }
        }
    }
} finally {
    Write-DLog 'main loop ended; cleanup'
    try { $server.Dispose() } catch { }
    Stop-Pses
    # Module awareness (dispatch 000101): tear down the background snapshot runspace if it is still
    # alive (best-effort; the process is exiting anyway).
    try { if ($null -ne $script:snapshotPs) { $script:snapshotPs.Dispose() } } catch { }
    try { if ($null -ne $script:snapshotRunspace) { $script:snapshotRunspace.Dispose() } } catch { }
    try { if (Test-Path -LiteralPath $sessionFile) { Remove-Item -LiteralPath $sessionFile -Force } } catch { }
    Write-DLog '--- daemon exit ---'
}
