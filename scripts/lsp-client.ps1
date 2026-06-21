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
        # Never-silent backstop (dispatch 000028): $null means the daemon was UNREACHABLE -- no
        # pipe yet (the brief daemon-launch window before pipe-first's pipe exists), the
        # per-session daemon has stopped (e.g. idle-TTL self-terminate, or the daemon process
        # died), or a connect/read failure. The daemon-served honesty banners ride the pipe, so
        # with NO pipe there is no daemon banner -- the client must surface its own, or this edit
        # reads as "analyzed, clean" (the exact could-not-X-looks-like-X-found-nothing failure
        # 000028 exists to kill). This closes the residual no-pipe window pipe-first cannot reach
        # from the daemon side. GATED on $null, which a HEALTHY pass is NEVER (a clean pass returns
        # an ok response object -> renders nothing), so the byte-identical warm/clean path is
        # untouched: the backstop fires only on a genuine could-not-reach, never on a clean result.
        Write-HookContext ('PowerShell diagnostics unavailable for ' + $path + ': the analyzer was not reachable -- this edit was NOT checked. The per-session daemon may still be starting, or has stopped (e.g. after idle); start a new session to restart it.')
        Write-CLog 'daemon unreachable -> emitted never-silent backstop banner (no pipe)'
        exit 0
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
