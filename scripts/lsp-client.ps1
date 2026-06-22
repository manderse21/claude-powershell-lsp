#Requires -Version 5.1

# lsp-client.ps1 -- PostToolUse hook client. Reads the Claude Code PostToolUse
# JSON from stdin, and for PowerShell files only, asks the warm per-session
# daemon (over the named pipe powershell-lsp-<sessionid>) for diagnostics on the
# edited file, then returns them to Claude as NON-BLOCKING feedback via
# hookSpecificOutput.additionalContext.
#
# Output contract (D3): empirically, this Claude Code build reads
# hookSpecificOutput.additionalContext on exit 0 (observed live 2026-06-05). That
# is what we emit. Recorded in the outbox.
#
# Fail-safe: on ANY error (bad stdin, non-PS file, daemon unreachable, timeout)
# print nothing and exit 0. Never block or slow the editing flow beyond the cap.
#
# Author: Mike Andersen / powershell-lsp plugin.

param(
    # Total hard cap before the client gives up and degrades to log-only
    # (userConfig timeoutMs). Connect timeout is derived from it.
    [int] $TimeoutMs = 5000,
    [int] $ConnectTimeoutMs = 2000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/lsp-common.ps1')

# v1.1.1: the PostToolUse hook no longer passes -TimeoutMs (the ${user_config.*}
# substitution broke first-run on CC v2.1.167). Self-source it from the exported
# env var, falling back to the param default.
$TimeoutMs = Get-PluginOptionInt 'timeoutMs' $TimeoutMs
$HardCapMs = $TimeoutMs
if ($ConnectTimeoutMs -gt $HardCapMs) { $ConnectTimeoutMs = $HardCapMs }

# Track A: telemetry is OFF unless plugin option enableStats is truthy. Read ONCE.
# The stats write is best-effort and FAIL-SAFE -- it never alters the emit below
# nor the exit code, so the feedback is byte-identical with stats on or off.
$StatsOn = Get-PluginOptionBool 'enableStats' $false
$script:StatConnectMs = $null   # client->daemon connect ms; set on a successful connect

# Edit-range scoping (000019): scopeToEdit defaults ON -- filter the surfaced
# diagnostics to the lines the edit touched. editContextLines defaults 0 (the
# structuredPatch hunks already include a few diff context lines; do not stack).
# Read ONCE; the per-edit touched range is derived from tool_response below.
$ScopeToEdit = Get-PluginOptionBool 'scopeToEdit' $true
$EditContextLines = Get-PluginOptionInt 'editContextLines' 0

# Auto-relaunch cooldown (dispatch 000030): the BOUND. After this client fires a relaunch of an
# idle-stopped daemon, suppress any further relaunch for this long. A pipe-first daemon that launched
# STAYS UP once it owns the pipe, so a fresh unreachable inside the window means the prior launch is
# still coming up (reconnect to it) or genuinely cannot stay alive (do NOT relaunch again -- the
# honest banner is the fallback; never a loop). ~InitTimeoutMs (the daemon's own time to come up or
# park as unavailable), so it is one relaunch per init window.
$script:RelaunchCooldownMs = 30000

$logDir = Get-LogDir
try { New-Item -ItemType Directory -Force -Path $logDir | Out-Null } catch { }
$clientLog = Join-Path $logDir 'lsp-client.log'
function Write-CLog([string]$m) {
    try { ('[' + (Get-Date -Format 'o') + '] ' + $m) | Out-File -FilePath $clientLog -Append -Encoding ascii } catch { }
}

function Write-HookContext([string]$Context) {
    # PostToolUse output contract (D3): non-blocking feedback via
    # hookSpecificOutput.additionalContext on exit 0. Used by both the parser
    # pre-pass (Track B) and the daemon path so the emit shape stays identical.
    $out = @{ hookSpecificOutput = @{ hookEventName = 'PostToolUse'; additionalContext = $Context } }
    $out | ConvertTo-Json -Depth 6 -Compress
}

function Get-Diagnostics([string]$pipeName, [string]$filePath, [int]$connectMs, [int]$hardCapMs, [string]$cwd = '', $touchedRanges = $null) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $client = $null
    try {
        $attempts = 0
        $connected = $false
        while ($attempts -lt 2 -and -not $connected) {
            $attempts++
            $client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipeName,
                [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
            try {
                $remaining = [Math]::Max(1, $hardCapMs - [int]$sw.ElapsedMilliseconds)
                $client.Connect([Math]::Min($connectMs, $remaining))
                $connected = $true
                # Track A: connect ms = elapsed to here (connect is this function's
                # first work, so $sw measures the pipe connect, retries included).
                $script:StatConnectMs = [int]$sw.ElapsedMilliseconds
            } catch {
                Write-CLog ('connect attempt ' + $attempts + ' failed: ' + $_.Exception.Message)
                try { $client.Dispose() } catch { }
                $client = $null
                if ($sw.ElapsedMilliseconds -ge $hardCapMs) { break }
            }
        }
        if (-not $connected) { Write-CLog 'daemon unreachable (degrading to log-only)'; return $null }

        $writer = New-Object System.IO.StreamWriter($client, (New-Object System.Text.UTF8Encoding($false)), 4096, $true)
        $writer.NewLine = "`n"; $writer.AutoFlush = $true
        $reader = New-Object System.IO.StreamReader($client, [System.Text.Encoding]::UTF8, $false, 4096, $true)

        $reqObj = [ordered]@{ action = 'diagnostics'; file = $filePath; cwd = $cwd }
        # Edit-range scoping (000019): send the touched ranges only when present.
        # Omitting them is the whole-file path (scoping off or an indeterminate range).
        if ($null -ne $touchedRanges -and @($touchedRanges).Count -gt 0) { $reqObj['touchedRanges'] = @($touchedRanges) }
        $writer.WriteLine(($reqObj | ConvertTo-Json -Compress))
        $writer.Flush()

        $remaining = [Math]::Max(1, $hardCapMs - [int]$sw.ElapsedMilliseconds)
        $readTask = $reader.ReadLineAsync()
        if (-not $readTask.Wait($remaining)) { Write-CLog 'response timed out (hard cap)'; return $null }
        $line = $readTask.Result
        if ([string]::IsNullOrWhiteSpace($line)) { Write-CLog 'empty response'; return $null }
        return ($line | ConvertFrom-Json)
    } catch {
        Write-CLog ('client error: ' + $_.Exception.Message)
        return $null
    } finally {
        try { if ($null -ne $client) { $client.Dispose() } } catch { }
    }
}

function Start-DaemonRelaunchIfRecoverable {
    # Auto-relaunch the per-session daemon when an edit finds it UNREACHABLE (dispatch 000030).
    # Reaching here means $null = no daemon process at all (a clean idle-TTL self-terminate, a
    # crashed daemon, or the ~150ms pre-pipe launch sliver) -- the RECOVERABLE no-daemon condition.
    # A PERMANENT init failure never reaches here: the pipe-first daemon stays UP serving
    # 'unavailable' (a reachable status, not $null), so this seam is structurally the recoverable
    # case -- the $null-vs-status='unavailable' gate IS the recoverable/permanent split.
    #
    # BOUND (never a loop): at most one relaunch per cooldown window, tracked by a per-session stamp.
    # Returns @{ Attempted; LaunchOk }. Attempted=$false = suppressed (cooldown) or no host found;
    # LaunchOk=$false = the spawn itself threw. The caller renders the honest banner in EVERY
    # not-recovered case -- a suppressed/failed relaunch ALWAYS yields a banner, never silence, so the
    # bound can only ever cost a banner, never a miss.
    param([string]$SessionId)
    $result = @{ Attempted = $false; LaunchOk = $false }
    $sessionDir = Get-SessionDir
    $stamp = Join-Path $sessionDir ($SessionId + '.relaunch')
    try {
        if (Test-Path -LiteralPath $stamp) {
            $age = ((Get-Date) - (Get-Item -LiteralPath $stamp).LastWriteTime).TotalMilliseconds
            if ($age -lt $script:RelaunchCooldownMs) {
                Write-CLog ('auto-relaunch suppressed (cooldown: ' + [int]$age + 'ms < ' + $script:RelaunchCooldownMs + 'ms)')
                return $result
            }
        }
    } catch { }
    $hostExe = Resolve-PsHost (Get-PluginOption 'ps_host' 'pwsh')
    if ($null -eq $hostExe) { Write-CLog 'auto-relaunch: no PowerShell host (pwsh/powershell) found'; return $result }
    # Stamp BEFORE the launch so a concurrent edit racing this one is suppressed -- one launch wins,
    # the other backstops honestly (the daemon's NamedPipeServerStream max=1 also makes a racing
    # second daemon throw and die, so at most one ever serves). The stamp only costs a banner.
    try {
        New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null
        Set-Content -LiteralPath $stamp -Value ([string]$PID) -Encoding ascii -Force
    } catch { }
    $result.Attempted = $true
    # Reuse the EXACT pipe-first launch session-start uses (Start-PsesDaemonDetached, lib). Resolve
    # the daemon knobs from the same CLAUDE_PLUGIN_OPTION_* env session-start reads, so the relaunched
    # daemon comes up identically. NOT ensure-pses/ensure-pssa (bootstrap; re-running risks the network
    # and is the permanent case we do not spin on) and NOT the reap (next SessionStart handles a
    # crash-orphaned PSES).
    $result.LaunchOk = [bool](Start-PsesDaemonDetached -SessionId $SessionId -HostExe $hostExe `
        -SeverityThreshold (Get-PluginOption 'severityThreshold' 'Hint') `
        -RuleInclude (Get-PluginOption 'ruleInclude' '') `
        -RuleExclude (Get-PluginOption 'ruleExclude' '') `
        -DebounceMs (Get-PluginOptionInt 'debounceMs' 150) `
        -IdleTtlMin (Get-PluginOptionInt 'idleTtlMin' 30) `
        -PerFileCap (Get-PluginOptionInt 'perFileCap' 20) `
        -SettingsPath (Get-PluginOption 'settingsPath' ''))
    Write-CLog ('auto-relaunch: daemon launch ' + $(if ($result.LaunchOk) { 'fired' } else { 'FAILED (spawn threw)' }))
    return $result
}

try {
    $swTotal = [System.Diagnostics.Stopwatch]::StartNew()   # Track A: end-to-end ms
    $raw = Get-StdinText
    if ([string]::IsNullOrWhiteSpace($raw)) { Write-CLog 'empty stdin'; exit 0 }
    $payload = $raw | ConvertFrom-Json

    $sessionId = [string](Get-Prop $payload 'session_id')
    if ([string]::IsNullOrWhiteSpace($sessionId)) { Write-CLog 'no session_id'; exit 0 }

    $toolInput = Get-Prop $payload 'tool_input'
    $path = [string](Get-Prop $toolInput 'file_path')
    if ([string]::IsNullOrWhiteSpace($path)) { Write-CLog 'no tool_input.file_path'; exit 0 }

    # cwd = the Claude Code session working dir (project root). Captured here for both
    # relative-path resolution AND forwarding to the daemon, which bounds the
    # PSScriptAnalyzerSettings.psd1 walk-up at it (000018).
    $cwd = [string](Get-Prop $payload 'cwd')
    if (-not [System.IO.Path]::IsPathRooted($path)) {
        if (-not [string]::IsNullOrWhiteSpace($cwd)) { $path = Join-Path $cwd $path }
    }
    $path = [System.IO.Path]::GetFullPath($path)

    $ext = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
    if (@('.ps1', '.psm1', '.psd1') -notcontains $ext) { Write-CLog ('skip non-PS file: ' + $path); exit 0 }
    if (-not (Test-Path -LiteralPath $path)) { Write-CLog ('file gone: ' + $path); exit 0 }

    # Track B -- in-process parser pre-pass. A syntax error means PSScriptAnalyzer
    # cannot run anyway (the file does not parse), so PSES would only return parser
    # errors too: emit them straight from the in-process parser and SKIP the warm
    # pipe round-trip. The saving is the ~2s warm-daemon latency -- NOT ~6s, which
    # was the old cold loose hook. A clean parse falls through to the daemon as
    # before (lint-always). Wrapped so any failure degrades to the pipe path and
    # never blocks the edit.
    $parseErrors = $null
    try {
        $ptoks = $null; $perrs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$ptoks, [ref]$perrs)
        $parseErrors = @($perrs)
    } catch {
        Write-CLog ('parser pre-pass threw (falling through to daemon): ' + $_.Exception.Message)
        $parseErrors = $null
    }
    if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) {
        $cap = Get-PluginOptionInt 'perFileCap' 20
        $total = $parseErrors.Count
        $shown = if ($cap -gt 0 -and $total -gt $cap) { @($parseErrors[0..($cap - 1)]) } else { @($parseErrors) }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('PowerShell diagnostics (' + @($shown).Count + ') for ' + $path + ':')
        foreach ($pe in $shown) {
            $ln = [string]$pe.Extent.StartLineNumber
            $cl = [string]$pe.Extent.StartColumnNumber
            $m = ($pe.Message -replace "[`r`n`t]", ' ').Trim()
            [void]$sb.AppendLine('  [Error] line ' + $ln + ', col ' + $cl + ' -- ' + $m + ' (parser)')
        }
        if ($cap -gt 0 -and $total -gt $cap) { [void]$sb.AppendLine('  ... and ' + ($total - $cap) + ' more (per-file cap)') }
        Write-HookContext ($sb.ToString().TrimEnd())
        Write-CLog ('parse error -> emitted ' + @($shown).Count + ' parse diagnostic(s); skipped daemon round-trip')
        # Dogfood capture (000039): tee the surfaced parser diagnostics into the local
        # append-only log. STRICTLY after the emit, fully wrapped, and piped to Out-Null --
        # a pure side-channel that can never alter the surface above or the exit 0 below
        # (the invisible-side-channel fence). $shown is the exact set just surfaced.
        try {
            $capRecords = @($shown | ForEach-Object { New-CaptureRecordFromParseError $_ })
            Add-DiagnosticCaptureEntries -File $path -Records $capRecords | Out-Null
        } catch { Write-CLog ('dogfood capture (parser path) failed -- swallowed: ' + $_.Exception.Message) }
        # Track A: telemetry for the parser-prepass short-circuit -- no daemon was
        # contacted, so connect/analysis/codeAction are null; records = parse errors
        # found (pre-cap). Strictly after the emit; file-only; never throws.
        if ($StatsOn) {
            Write-StatsLine @{ ts = (Get-Date -Format 'o'); path = $path; ext = $ext; taken = 'parser-prepass'
                connectMs = $null; analysisMs = $null; codeActionMs = $null; totalMs = [int]$swTotal.ElapsedMilliseconds
                records = $total; corrections = 0; cached = $false
                scopeApplied = $false; scopeTotal = $total; scopeSurfaced = $total }
        }
        exit 0
    }

    $pipeName = 'powershell-lsp-' + $sessionId
    Write-CLog ('requesting diagnostics for ' + $path + ' via ' + $pipeName)

    # Edit-range scoping (000019): derive the touched line range from the PostToolUse
    # tool_response (structuredPatch). Only the client sees the payload, so the range
    # is derived here and forwarded to the daemon, which filters before its cap. Any
    # failure or indeterminate patch -> $null -> the daemon scopes nothing -> whole-file
    # (fail open). scopeToEdit off -> also $null. The parser pre-pass above stays
    # UNSCOPED on purpose: a syntax error is critical and may surface off the edit.
    $touchedRanges = $null
    if ($ScopeToEdit) {
        try {
            $toolResponse = Get-Prop $payload 'tool_response'
            $touchedRanges = ConvertTo-TouchedRanges -ToolResponse $toolResponse -ContextLines $EditContextLines
        } catch {
            Write-CLog ('touched-range derivation failed (fail open to whole-file): ' + $_.Exception.Message)
            $touchedRanges = $null
        }
    }
    if ($null -ne $touchedRanges) { Write-CLog ('scoping to ' + @($touchedRanges).Count + ' touched range(s)') }
    else { Write-CLog 'whole-file (scoping off or indeterminate range)' }

    $resp = Get-Diagnostics $pipeName $path $ConnectTimeoutMs $HardCapMs $cwd $touchedRanges
    # $resp also carries optional telemetry fields the emit ignores (daemon-side
    # path/analysisMs/codeActionMs/recordCount/correctionCount). A null/!ok response
    # means the edit was never analyzed (unreachable/timeout) -> no stats line.
    if ($null -eq $resp) {
        # Auto-relaunch (dispatch 000030), plugged into the 000028 never-silent backstop seam. $null
        # means the daemon was UNREACHABLE -- NO pipe: a clean idle-TTL self-terminate, a crashed
        # daemon, or the ~150ms pre-pipe launch sliver. That is the RECOVERABLE no-daemon condition;
        # a PERMANENT init failure stays UP serving 'unavailable' (reachable, never $null), so it
        # never reaches here. FIRST attempt a bounded silent relaunch (the same pipe-first launch
        # session-start uses), then retry-connect within the remaining hard cap. The relaunched daemon
        # comes up pipe-first, so this edit honestly gets the transient 'incomplete' if it lands during
        # init -- ONE edit, then real analysis. Recovery is SILENT only when it works; otherwise the
        # honest banner below fires (never silence). GATED on $null, which a HEALTHY pass is NEVER (a
        # clean pass returns an ok object -> renders nothing), so the byte-identical warm path is
        # untouched: relaunch+backstop fire only on a genuine could-not-reach, never on a clean result.
        $relaunch = Start-DaemonRelaunchIfRecoverable -SessionId $sessionId
        if ($relaunch.LaunchOk) {
            while ($null -eq $resp -and $swTotal.ElapsedMilliseconds -lt $HardCapMs) {
                Start-Sleep -Milliseconds 250
                $resp = Get-Diagnostics $pipeName $path $ConnectTimeoutMs $HardCapMs $cwd $touchedRanges
            }
        }
        if ($null -eq $resp) {
            # Still unreachable -> the honest never-silent backstop (028, wording refined for 030).
            # NEVER silence. Two deliberately distinct cases:
            #  - relaunch fired and the daemon is still coming up (pipe not ready within the cap):
            #    do NOT say "start a new session" -- it IS being restarted; the next edit gets it.
            #  - relaunch suppressed (cooldown) / no host / spawn threw: a GENUINE could-not-restart
            #    -- "could not be restarted automatically", with a manual restart as the fallback.
            if ($relaunch.Attempted -and $relaunch.LaunchOk) {
                Write-HookContext ('PowerShell diagnostics unavailable for ' + $path + ': the analyzer had stopped (e.g. after idle) and is being restarted -- this edit was NOT checked; your next edit should be.')
                Write-CLog 'daemon unreachable -> relaunched, re-warming; emitted honest is-being-restarted banner'
            } else {
                Write-HookContext ('PowerShell diagnostics unavailable for ' + $path + ': the analyzer was not reachable and could not be restarted automatically -- this edit was NOT checked. Start a new session to restart it.')
                Write-CLog ('daemon unreachable -> not recovered (attempted=' + $relaunch.Attempted + ' launchOk=' + $relaunch.LaunchOk + '); emitted honest could-not-restart banner')
            }
            exit 0
        }
        Write-CLog ('auto-relaunch recovered a reachable daemon (status=' + [string](Get-Prop $resp 'status') + ')')
        # fall through: $resp now carries the relaunched daemon's status (transient 'incomplete'
        # during its init window, or a settled pass) -- rendered by the existing status path below.
    }
    if (-not (Get-Prop $resp 'ok')) { Write-CLog ('daemon error: ' + [string](Get-Prop $resp 'error')); exit 0 }

    $diags = @(Get-Prop $resp 'diagnostics')
    $omitted = [int](Get-Prop $resp 'omitted')
    # Analysis status (dispatch 000022/000024): '' / 'ok' = a clean, settled pass (behave
    # exactly as before); 'incomplete' = the pass did NOT settle (this edit was not checked);
    # 'degraded' = a settled but parser-only pass (PSScriptAnalyzer unavailable); 'unavailable'
    # = the PSES bundle never bootstrapped at first start (install incomplete -- 000024). The
    # non-clean banners ride the SAME additionalContext channel as the diagnostics, so the user
    # sees them inline -- "could not analyze", "fewer rules", and "not installed" never look
    # like "analyzed, found nothing." A clean pass adds NOTHING, so the warm output is unchanged.
    $status = [string](Get-Prop $resp 'status')

    # Build the feedback block. The diagnostics rendering is byte-identical to before;
    # 'degraded' leads with its banner then still lists any parser-only findings, and
    # 'incomplete' (no trustworthy findings) renders the banner alone. A clean 0-diagnostic
    # edit produces an empty block and emits nothing -- exactly as before -- but it IS still
    # an analyzed edit, so it gets a stats line below.
    $sb = New-Object System.Text.StringBuilder
    if ($status -eq 'degraded') { [void]$sb.AppendLine((Get-DiagnosticsStatusBanner 'degraded' $path)) }
    if ($diags.Count -gt 0) {
        [void]$sb.AppendLine('PowerShell diagnostics (' + $diags.Count + ') for ' + $path + ':')
        foreach ($d in $diags) {
            $sev = [string](Get-Prop $d 'severity')
            $line = [string](Get-Prop $d 'line')
            $col = [string](Get-Prop $d 'col')
            $src = [string](Get-Prop $d 'source')
            $code = [string](Get-Prop $d 'code')
            $msg = [string](Get-Prop $d 'message')
            $hasCode = $code -and ($code -ne '0')
            $label = if ($hasCode -and $src) { $src + '/' + $code } elseif ($src) { $src } else { 'parser' }
            [void]$sb.AppendLine('  [' + $sev + '] line ' + $line + ', col ' + $col + ' -- ' + $msg + ' (' + $label + ')')
            # Track C: surface the PSSA suggested fix (replacement text) when present.
            # Surface-only -- the model applies it; the hook never writes files. Q3:
            # primary correction plus a count of any further alternatives.
            $corr = [string](Get-Prop $d 'correction')
            if (-not [string]::IsNullOrWhiteSpace($corr)) {
                $corrCount = [int](Get-Prop $d 'correctionCount')
                $corrLine = ($corr -replace "[`r`n`t]", ' ').Trim()
                $more = if ($corrCount -gt 1) { ' (and ' + ($corrCount - 1) + ' more)' } else { '' }
                [void]$sb.AppendLine('      fix: ' + $corrLine + $more)
            }
        }
        if ($omitted -gt 0) { [void]$sb.AppendLine('  ... and ' + $omitted + ' more (per-file cap)') }
    } elseif ($status -eq 'incomplete' -or $status -eq 'unavailable') {
        # 000022 'incomplete' (transient non-settle) and 000024 'unavailable' (install
        # incomplete) both render their banner ALONE when there are no trustworthy findings.
        # The primitive owns the wording; pass $status so each renders its distinct message --
        # a broken install ('unavailable') never reads as a retryable miss ('incomplete').
        [void]$sb.AppendLine((Get-DiagnosticsStatusBanner $status $path))
    }
    $context = $sb.ToString().TrimEnd()

    if (-not [string]::IsNullOrEmpty($context)) {
        Write-HookContext $context
        Write-CLog ('emitted ' + $diags.Count + ' diagnostic(s)' + $(if ($status -and $status -ne 'ok') { ' [status=' + $status + ']' } else { '' }))
    } else {
        Write-CLog 'no diagnostics'
    }

    # Dogfood capture (000039): tee the surfaced daemon diagnostics into the local
    # append-only log. STRICTLY after the emit, fully wrapped, and piped to Out-Null -- it
    # can never alter, reorder, delay, or gate the surface above or the exit 0 below (the
    # invisible-side-channel fence). $diags is the exact (already scoped + capped) set
    # surfaced to Claude; every occurrence is logged (no capture-time dedup). Only diagnostic
    # OCCURRENCES are captured -- a status-only banner (incomplete/unavailable) is not one.
    if ($diags.Count -gt 0) {
        try {
            $capRecords = @($diags | ForEach-Object { New-CaptureRecordFromDiag $_ })
            Add-DiagnosticCaptureEntries -File $path -Records $capRecords | Out-Null
        } catch { Write-CLog ('dogfood capture (daemon path) failed -- swallowed: ' + $_.Exception.Message) }
    }

    # Track A: one best-effort JSONL line for this analyzed edit (cache-hit or
    # daemon-analyze). File-only, wrapped, emits nothing to stdout -> the feedback
    # above is byte-identical whether stats are on or off. records/corrections are
    # the daemon's analyzer-output counts (pre client-side filter/cap).
    if ($StatsOn) {
        Write-StatsLine @{ ts = (Get-Date -Format 'o'); path = $path; ext = $ext
            taken = [string](Get-Prop $resp 'path'); connectMs = $script:StatConnectMs
            analysisMs = [int](Get-Prop $resp 'analysisMs'); codeActionMs = [int](Get-Prop $resp 'codeActionMs')
            totalMs = [int]$swTotal.ElapsedMilliseconds
            records = [int](Get-Prop $resp 'recordCount'); corrections = [int](Get-Prop $resp 'correctionCount')
            cached = [bool](Get-Prop $resp 'cached')
            scopeApplied = [bool](Get-Prop $resp 'scopeApplied'); scopeTotal = [int](Get-Prop $resp 'scopeTotal'); scopeSurfaced = [int](Get-Prop $resp 'scopeSurfaced') }
    }
    exit 0
}
catch {
    Write-CLog ('FATAL (fail-safe, exit 0): ' + $_.Exception.Message)
    exit 0
}
