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

# Format-on-edit (000059, PL-8): OFF by default. When 'suggest', AFTER the diagnostics pass the
# client asks the warm daemon to format the edited file (Invoke-Formatter honoring the repo
# settings) and surfaces the result as a SUGGESTION -- never rewriting the file. Read ONCE.
# 'off' (the default, and any unrecognized value) skips the format path entirely below, so the
# diagnostics surface is byte-for-byte unchanged. No apply path exists (suggest-only).
$FormatMode = ConvertTo-FormatOnEditMode (Get-PluginOption 'formatOnEdit' 'off')

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

function Get-FormatResponse([string]$pipeName, [string]$filePath, [int]$connectMs, [int]$hardCapMs, [string]$cwd = '', [bool]$Apply = $false) {
    # Format-on-edit (000059 suggest; 000099 apply): ask the warm daemon to format the edited file (a
    # SEPARATE 'format' action from diagnostics). Returns the parsed response object, or $null on any
    # connect/read/timeout failure -- the caller then surfaces nothing (degrade honestly). Deliberately
    # separate from Get-Diagnostics so the diagnostics path is untouched; one bounded connect + read
    # within the remaining hard cap. The CLIENT never writes the file: with -Apply the daemon performs
    # the GUARDED write and this returns its result (formatStatus 'applied' / 'apply-aborted'); without
    # it the daemon returns a suggestion only. -Apply defaults $false, so the suggest request is
    # byte-identical to before (no 'apply' field is sent).
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $client = $null
    try {
        $client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipeName,
            [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
        $remaining = [Math]::Max(1, $hardCapMs - [int]$sw.ElapsedMilliseconds)
        $client.Connect([Math]::Min($connectMs, $remaining))
        $writer = New-Object System.IO.StreamWriter($client, (New-Object System.Text.UTF8Encoding($false)), 4096, $true)
        $writer.NewLine = "`n"; $writer.AutoFlush = $true
        $reader = New-Object System.IO.StreamReader($client, [System.Text.Encoding]::UTF8, $false, 4096, $true)
        $reqObj = [ordered]@{ action = 'format'; file = $filePath; cwd = $cwd }
        if ($Apply) { $reqObj['apply'] = $true }   # 000099: request the daemon's guarded write-back
        $writer.WriteLine(($reqObj | ConvertTo-Json -Compress)); $writer.Flush()
        $remaining = [Math]::Max(1, $hardCapMs - [int]$sw.ElapsedMilliseconds)
        $readTask = $reader.ReadLineAsync()
        if (-not $readTask.Wait($remaining)) { Write-CLog 'format response timed out (hard cap)'; return $null }
        $line = $readTask.Result
        if ([string]::IsNullOrWhiteSpace($line)) { Write-CLog 'empty format response'; return $null }
        return ($line | ConvertFrom-Json)
    } catch {
        Write-CLog ('format request error: ' + $_.Exception.Message)
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
        -SettingsPath (Get-PluginOption 'settingsPath' '') `
        -Ruleset (Get-PluginOption 'ruleset' 'pses-default') `
        -ModuleAwareness (ConvertTo-ModuleAwarenessMode (Get-PluginOption 'moduleAwareness' 'off')) `
        -ReferenceSurfacing (ConvertTo-ReferenceSurfacingMode (Get-PluginOption 'referenceSurfacing' 'off')))
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

    # Track C -- pre-PSSA byte pass (dispatch 000060): scan for non-ASCII
    # smart-punctuation characters (em/en dash, smart quotes, arrow glyphs) that
    # would mojibake under PS 5.1 reading UTF-8 without BOM as Windows-1252.
    # Runs BEFORE the parser pre-pass so it catches the mojibake case even when
    # the file no longer parses. Wrapped so any failure degrades gracefully and
    # never blocks the edit.
    $prePssaFindings = $null
    try {
        $prePssaFindings = @(Find-NonAsciiSmuggling -Path $path)
        if ($null -ne $prePssaFindings -and $prePssaFindings.Count -gt 0) {
            Write-CLog ('pre-PSSA (non-ASCII) found ' + $prePssaFindings.Count + ' finding(s)')
        }
    } catch {
        Write-CLog ('pre-PSSA scan threw (degrading gracefully): ' + $_.Exception.Message)
        $prePssaFindings = $null
    }

    # Track B -- in-process parser pre-pass. A syntax error means PSScriptAnalyzer
    # cannot run anyway (the file does not parse), so PSES would only return parser
    # errors too: emit them straight from the in-process parser and SKIP the warm
    # pipe round-trip. The saving is the ~2s warm-daemon latency -- NOT ~6s, which
    # was the old cold loose hook. A clean parse falls through to the daemon as
    # before (lint-always). Wrapped so any failure degrades to the pipe path and
    # never blocks the edit.
    $parseErrors = $null
    $parsedAst = $null
    try {
        $ptoks = $null; $perrs = $null
        $parsedAst = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$ptoks, [ref]$perrs)
        $parseErrors = @($perrs)
    } catch {
        Write-CLog ('parser pre-pass threw (falling through to daemon): ' + $_.Exception.Message)
        $parseErrors = $null
        $parsedAst = $null
    }
    # Track B2 -- pre-PSSA TOKEN pass (dispatch 000139): flag an unfilled angle-bracket
    # placeholder '<Name>' left on a command line, over the SAME tokens the parser pre-pass
    # just produced ($ptoks). A placeholder is the reserved '<' input-redirection operator (a
    # parse error) abutting a bareword ending in '>', so it ALWAYS co-occurs with a parse error
    # and rides the pre-PSSA early-exit alongside it -- like the non-ASCII pass, and unlike the
    # compat/bash-ism passes (which parse cleanly and ride the daemon merge). Appended to
    # $prePssaFindings so it is surfaced AND dogfood-captured on the early-exit path below,
    # giving an actionable message where the raw parser error is only "'<' is reserved".
    # Wrapped so any failure degrades gracefully and never blocks the edit.
    try {
        $placeholderFindings = @(Find-CommandLinePlaceholder -Tokens $ptoks)
        if ($placeholderFindings.Count -gt 0) {
            Write-CLog ('pre-PSSA (placeholder) found ' + $placeholderFindings.Count + ' finding(s)')
            if ($null -eq $prePssaFindings) { $prePssaFindings = @() }
            $prePssaFindings = @($prePssaFindings + $placeholderFindings)
        }
    } catch {
        Write-CLog ('pre-PSSA placeholder scan threw (degrading gracefully): ' + $_.Exception.Message)
    }
    # Track C -- pre-PSSA AST compat pass (dispatch 000096): flag PowerShell-7-only SYNTAX
    # (&& / ||, ternary, ?? / ??= / ?. / ?[]) over the SAME AST the parser pre-pass just
    # produced, suppressed when the file declares #Requires -Version 7+. Wrapped so any
    # failure degrades gracefully. Unlike the non-ASCII pass, compat findings do NOT gate
    # the parse-error/pre-PSSA early-exit below: a file using 7-only syntax parses cleanly
    # under the pwsh-7 daemon and must still get full PSScriptAnalyzer analysis, so these
    # ride the daemon merge path (below), surfaced + dogfood-captured alongside the daemon
    # diagnostics -- never skipping the daemon on their own.
    $compatFindings = $null
    try {
        if ($null -ne $parsedAst) {
            $compatFindings = @(Find-Ps7OnlySyntax -Ast $parsedAst)
            if ($null -ne $compatFindings -and $compatFindings.Count -gt 0) {
                Write-CLog ('pre-PSSA (PS7-only syntax) found ' + $compatFindings.Count + ' finding(s)')
            }
        }
    } catch {
        Write-CLog ('pre-PSSA compat scan threw (degrading gracefully): ' + $_.Exception.Message)
        $compatFindings = $null
    }
    # Track C -- pre-PSSA AST bash-ism pass (dispatch 000097): flag Unix/bash command names
    # (grep, sed, awk, export, which, touch, chmod, chown, ln) used as commands over the SAME
    # AST the parser pre-pass produced, suppressed for an explicit '& name' call or a same-file
    # definition of the name. Wrapped so any failure degrades gracefully. Like the 000096 compat
    # pass, bash-ism findings do NOT gate the parse-error/pre-PSSA early-exit: a file using a
    # bash-ism parses cleanly under the daemon and must still get full PSScriptAnalyzer analysis,
    # so these ride the daemon merge path (below), never skipping the daemon on their own.
    $bashismFindings = $null
    try {
        if ($null -ne $parsedAst) {
            $bashismFindings = @(Find-BashIsm -Ast $parsedAst)
            if ($null -ne $bashismFindings -and $bashismFindings.Count -gt 0) {
                Write-CLog ('pre-PSSA (bash-ism) found ' + $bashismFindings.Count + ' finding(s)')
            }
        }
    } catch {
        Write-CLog ('pre-PSSA bash-ism scan threw (degrading gracefully): ' + $_.Exception.Message)
        $bashismFindings = $null
    }
    $hasParseErrors = ($null -ne $parseErrors -and $parseErrors.Count -gt 0)
    $hasPrePssa = ($null -ne $prePssaFindings -and $prePssaFindings.Count -gt 0)
    if ($hasParseErrors -or $hasPrePssa) {
        $cap = Get-PluginOptionInt 'perFileCap' 20
        # Collect all items: pre-PSSA findings first, then parse errors.
        $allItems = New-Object System.Collections.ArrayList
        if ($hasPrePssa) { foreach ($f in $prePssaFindings) { [void]$allItems.Add($f) } }
        if ($hasParseErrors) { foreach ($pe in $parseErrors) { [void]$allItems.Add($pe) } }
        $total = $allItems.Count
        $shown = if ($cap -gt 0 -and $total -gt $cap) { @($allItems[0..($cap - 1)]) } else { @($allItems.ToArray()) }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('PowerShell diagnostics (' + @($shown).Count + ') for ' + $path + ':')
        foreach ($item in $shown) {
            $src = [string](Get-Prop $item 'source')
            $cd = [string](Get-Prop $item 'code')
            if ($src -eq 'powershell-lsp') {
                $ln = [string](Get-Prop $item 'line'); $cl = [string](Get-Prop $item 'col')
                $m = ((Get-Prop $item 'message') -replace "[`r`n`t]", ' ').Trim()
                $lbl = if ($cd) { $src + '/' + $cd } else { $src }
                [void]$sb.AppendLine('  [Warning] line ' + $ln + ', col ' + $cl + ' -- ' + $m + ' (' + $lbl + ')')
            } else {
                $ln = [string]$item.Extent.StartLineNumber
                $cl = [string]$item.Extent.StartColumnNumber
                $m = ($item.Message -replace "[`r`n`t]", ' ').Trim()
                [void]$sb.AppendLine('  [Error] line ' + $ln + ', col ' + $cl + ' -- ' + $m + ' (parser)')
            }
        }
        if ($cap -gt 0 -and $total -gt $cap) { [void]$sb.AppendLine('  ... and ' + ($total - $cap) + ' more (per-file cap)') }
        Write-HookContext ($sb.ToString().TrimEnd())
        Write-CLog ('pre-PSSA/parse errors -> emitted ' + @($shown).Count + ' diagnostic(s); skipped daemon round-trip')
        # Dogfood capture (000039): tee the surfaced diagnostics into the local
        # append-only log. Pre-PSSA findings are captured as daemon-like records
        # (using New-CaptureRecordFromDiag with source='powershell-lsp') so the
        # corpus derivation sees them. Parse errors use the existing ParseError
        # path. Both capture blocks are wrapped and fail-safe.
        if ($hasPrePssa) {
            try {
                $capRecords = @($prePssaFindings | ForEach-Object { New-CaptureRecordFromDiag $_ })
                Add-DiagnosticCaptureEntries -File $path -Records $capRecords | Out-Null
            } catch { Write-CLog ('dogfood capture (pre-PSSA path) failed -- swallowed: ' + $_.Exception.Message) }
        }
        if ($hasParseErrors) {
            try {
                $capRecords = @($parseErrors | ForEach-Object { New-CaptureRecordFromParseError $_ })
                Add-DiagnosticCaptureEntries -File $path -Records $capRecords | Out-Null
            } catch { Write-CLog ('dogfood capture (parser path) failed -- swallowed: ' + $_.Exception.Message) }
        }
        # Track A: telemetry. Strictly after the emit; file-only; never throws.
        if ($StatsOn) {
            Write-StatsLine @{ ts = (Get-Date -Format 'o'); path = $path; ext = $ext; taken = 'pre-pssa-or-parse'
                connectMs = $null; analysisMs = $null; codeActionMs = $null; totalMs = [int]$swTotal.ElapsedMilliseconds
                records = $total; corrections = 0; cached = $false
                scopeApplied = $false; scopeTotal = $total; scopeSurfaced = @($shown).Count }
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
    # Merge pre-PSSA (non-ASCII smuggling) findings into the diagnostics stream
    # (dispatch 000060). These are client-side byte-level findings, independent of
    # the daemon. They appear alongside daemon diagnostics; the existing rendering
    # loop handles their source/code/severity fields correctly.
    if ($null -ne $prePssaFindings -and $prePssaFindings.Count -gt 0) {
        $diags = @($prePssaFindings) + @($diags)
    }
    # Merge pre-PSSA compat (PS7-only syntax) findings into the diagnostics stream (dispatch
    # 000096). These are client-side AST findings, independent of the daemon; they ride here
    # (not the early-exit) so a 7-only-syntax file still gets full daemon analysis. They
    # appear alongside daemon diagnostics; the existing render + dogfood-capture loop below
    # handles their source/code/severity fields, exactly like the non-ASCII findings.
    if ($null -ne $compatFindings -and $compatFindings.Count -gt 0) {
        $diags = @($compatFindings) + @($diags)
    }
    # Merge pre-PSSA bash-ism findings into the diagnostics stream (dispatch 000097). Same as
    # the 000096 compat findings: client-side AST findings, independent of the daemon, riding
    # the merge path (not the early-exit) so a bash-ism file still gets full daemon analysis.
    # They appear alongside daemon diagnostics; the existing render + dogfood-capture loop below
    # handles their source/code/severity fields, exactly like the non-ASCII and compat findings.
    if ($null -ne $bashismFindings -and $bashismFindings.Count -gt 0) {
        $diags = @($bashismFindings) + @($diags)
    }
    # Project findings (PL-6, dispatch 000062): merge manifest-consistency findings from
    # the daemon's module surface cache into the diagnostics stream. Uses the same
    # `powershell-lsp` source label. Non-determinate findings (wildcard/dynamic/dot-source)
    # carry an _indeterminate flag and are rendered as prose notes instead of diagnostics.
    # $indeterminateMsg MUST be initialized unconditionally here: it is read below at the
    # status/banner stage (the 'Project intelligence:' note), which runs on EVERY file. Under
    # Set-StrictMode -Version Latest + $ErrorActionPreference='Stop' (top of this script),
    # reading it unset is a TERMINATING error that aborts the emit before any diagnostic is
    # surfaced -- which silently wiped the whole diagnostics path for every file without
    # indeterminate project findings (i.e. every non-module file). Same init-then-guard idiom
    # as $prePssaFindings above. $null = no indeterminate shape (the guard short-circuits).
    $indeterminateMsg = $null
    # Filter nulls: @(Get-Prop ...) on an ABSENT property yields @($null) -- a one-element
    # array holding a single $null -- because the daemon omits projectFindings entirely for
    # every non-module file (no manifest in scope). Left unfiltered that lone $null has
    # Count 1, so the block below runs; Get-Prop on $null returns $null so it reads as
    # "determinate" and gets prepended to $diags as a phantom all-empty diagnostic, surfaced
    # and dogfood-captured on EVERY edit. Filtering makes an absent property an empty set.
    $projectFinds = @(@(Get-Prop $resp 'projectFindings') | Where-Object { $null -ne $_ })
    if ($projectFinds.Count -gt 0) {
        $determinate = @($projectFinds | Where-Object { -not [bool](Get-Prop $_ '_indeterminate') })
        $indeterminate = @($projectFinds | Where-Object { [bool](Get-Prop $_ '_indeterminate') })
        if ($determinate.Count -gt 0) { $diags = @($determinate) + @($diags) }
        if ($indeterminate.Count -gt 0) {
            $indeterminateMsg = @($indeterminate | ForEach-Object { [string](Get-Prop $_ 'message') })
        }
    }
    # Closed-loop agentic correction (dispatch 000061): the daemon's additive cleared[]/
    # stillPresent[] lifecycle fields. Init-then-guard + null-filter, exactly like $projectFinds
    # above -- @(Get-Prop ...) on an ABSENT property is @($null) (Count 1, a lone $null), which
    # left unfiltered would make the render loop dereference $null and (under StrictMode +
    # ErrorActionPreference=Stop) abort the whole emit on every edit with no lifecycle event
    # (the 000062 read-before-assign / @($null) phantom class). Filtering makes absent == empty.
    $clearedItems = @(@(Get-Prop $resp 'cleared') | Where-Object { $null -ne $_ })
    $stillPresentItems = @(@(Get-Prop $resp 'stillPresent') | Where-Object { $null -ne $_ })
    # Reference surfacing (dispatch 000128): the daemon's additive referenceFindings -- bare per-function
    # facts (referenced-by-N / exported / defined-in) computed from the session workspace index. Init-then-
    # guard + null-filter, exactly like $projectFinds above: @(Get-Prop ...) on an ABSENT property is
    # @($null) (Count 1, a lone $null), which left unfiltered would dereference $null in the render loop and
    # (under StrictMode + ErrorActionPreference=Stop) abort the whole emit on every edit with the knob off.
    # Filtering makes an absent property an empty set -> the surface is byte-identical when off / not ready.
    $refFinds = @(@(Get-Prop $resp 'referenceFindings') | Where-Object { $null -ne $_ })
    # Analysis status (dispatch 000022/000024): '' / 'ok' = a clean, settled pass (behave
    # exactly as before); 'incomplete' = the pass did NOT settle (this edit was not checked);
    # 'degraded' = a settled but parser-only pass (PSScriptAnalyzer unavailable); 'unavailable'
    # = the PSES bundle never bootstrapped at first start (install incomplete -- 000024). The
    # non-clean banners ride the SAME additionalContext channel as the diagnostics, so the user
    # sees them inline -- "could not analyze", "fewer rules", and "not installed" never look
    # like "analyzed, found nothing." A clean pass adds NOTHING, so the warm output is unchanged.
    $status = [string](Get-Prop $resp 'status')

    # Format-on-edit APPLY suppression flag (000099): set true only when a real apply WROTE the file
    # this turn. Initialized here (StrictMode-safe) and read below to suppress the now-stale pre-apply
    # diagnostics from both the surface and the dogfood capture. Stays false for off/suggest.
    $applyModified = $false

    # Build the feedback block. The diagnostics rendering is byte-identical to before;
    # 'degraded' leads with its banner then still lists any parser-only findings, and
    # 'incomplete' (no trustworthy findings) renders the banner alone. A clean 0-diagnostic
    # edit produces an empty block and emits nothing -- exactly as before -- but it IS still
    # an analyzed edit, so it gets a stats line below.
    $sb = New-Object System.Text.StringBuilder
    if ($status -eq 'degraded') { [void]$sb.AppendLine((Get-DiagnosticsStatusBanner 'degraded' $path)) }
    # Project intelligence note (PL-6, dispatch 000062): indeterminate shape message
    # rendered as a separate note before any diagnostic findings.
    if ($null -ne $indeterminateMsg -and $indeterminateMsg.Count -gt 0) {
        [void]$sb.AppendLine('Project intelligence: ' + ($indeterminateMsg -join '; '))
    }
    if ($diags.Count -gt 0) {
        # Rule rationales (dispatch 000121): a static "why this rule matters" line, ADDITIVE prose
        # on this same channel. Loaded ONLY when there is at least one finding, so a clean file
        # never even reads the table and its emit stays byte-identical. An absent or unparseable
        # table yields an empty lookup -- findings then render exactly as before (graceful degrade).
        # $renderedRules carries the per-rule dedup state for THIS file: a rule's rationale is
        # rendered once, at its first finding, however many times it fires.
        $rationales = Import-RuleRationales
        $renderedRules = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)
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
            # The rationale is about the RULE, so it precedes the per-finding fix and renders only
            # on this rule's FIRST finding. A code with no table entry adds nothing.
            $why = Get-RationaleForCode -Code $code -Table $rationales -Rendered $renderedRules
            if (-not [string]::IsNullOrWhiteSpace($why)) { [void]$sb.AppendLine('      why: ' + $why) }
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
    # Closed-loop agentic correction note (dispatch 000061): the cleared / still-present lifecycle
    # signal in its OWN labelled section, kept VISIBLY DISTINCT from the diagnostics block so the
    # agent never confuses a lifecycle signal with a correctness finding. CLEARED is a positive
    # confirmation and may fire on a now-clean file (no diagnostics block at all); STILL-PRESENT
    # escalates a finding the edit did not clear, bounded at K=2 attempts then ONE neutral downgrade
    # then silence. The daemon only emits these on a fresh, settled, ok pass, so they never co-occur
    # with an incomplete/unavailable banner. Absent (the common case) -> nothing added -> byte-identical.
    if ($clearedItems.Count -gt 0 -or $stillPresentItems.Count -gt 0) {
        [void]$sb.AppendLine('Correction check (since your last edit):')
        foreach ($c in $clearedItems) {
            $cr = [string](Get-Prop $c 'ruleId')
            $cm = ((Get-Prop $c 'message') -replace "[`r`n`t]", ' ').Trim()
            $crLbl = if ($cr) { $cr } else { 'finding' }
            [void]$sb.AppendLine('  resolved: ' + $crLbl + ' cleared after your last edit -- ' + $cm)
        }
        foreach ($s in $stillPresentItems) {
            $sr = [string](Get-Prop $s 'ruleId')
            $sl = [string](Get-Prop $s 'line')
            $sm = ((Get-Prop $s 'message') -replace "[`r`n`t]", ' ').Trim()
            $sa = [int](Get-Prop $s 'attempts')
            $sd = [bool](Get-Prop $s 'downgraded')
            $srLbl = if ($sr) { $sr } else { 'finding' }
            if ($sd) {
                [void]$sb.AppendLine('  still present: ' + $srLbl + ' at line ' + $sl + ' unchanged after ' + $sa + ' edits -- ' + $sm)
            } else {
                [void]$sb.AppendLine('  still present: ' + $srLbl + ' at line ' + $sl + ' not resolved by your edit (attempt ' + $sa + ' of 2) -- ' + $sm)
            }
        }
    }
    # Reference surfacing note (PL-6, dispatch 000128): bare per-function facts in their OWN labelled
    # 'References:' section, kept visibly distinct from diagnostics -- these are FACTS, not defects (no
    # "fix" attaches). The daemon pre-renders each fact's message (deduped per function, ordered by name);
    # the client only prints them. Absent (knob off, index not ready, or nothing provable) -> nothing added
    # -> byte-identical. Placed after diagnostics + the correction check so facts never sit above findings.
    if ($refFinds.Count -gt 0) {
        [void]$sb.AppendLine('References:')
        foreach ($rf in $refFinds) {
            $rm = ((Get-Prop $rf 'message') -replace "[`r`n`t]", ' ').Trim()
            if (-not [string]::IsNullOrWhiteSpace($rm)) { [void]$sb.AppendLine('  ' + $rm) }
        }
    }
    # Format-on-edit SUGGESTION (000059, PL-8): a SEPARATE warm round-trip, gated on the knob and
    # appended AFTER the diagnostics block. When the knob is off (the default) this block does not
    # run, so the emitted context is byte-for-byte identical to the pre-000059 behavior -- the
    # diagnostics surface is unchanged. Fully wrapped and fail-safe: any failure logs and surfaces
    # nothing (the hook still exits 0; the file is NEVER modified). Reaching here means the daemon
    # answered diagnostics (reachable); the parser-pre-pass early-exit path above never runs format
    # (a syntax error takes precedence and an unparseable file is not formatted).
    if ($FormatMode -eq 'suggest') {
        try {
            $fmtResp = Get-FormatResponse $pipeName $path $ConnectTimeoutMs $HardCapMs $cwd
            if ($null -ne $fmtResp -and [bool](Get-Prop $fmtResp 'ok') -and
                [string](Get-Prop $fmtResp 'formatStatus') -eq 'ok' -and [bool](Get-Prop $fmtResp 'changed')) {
                $fmtBlock = Format-FormattingSuggestionBlock `
                    -Path $path -Diff ([string](Get-Prop $fmtResp 'diff')) `
                    -Removed ([int](Get-Prop $fmtResp 'removed')) -Added ([int](Get-Prop $fmtResp 'added')) `
                    -Truncated ([bool](Get-Prop $fmtResp 'truncated')) -SettingsPath ([string](Get-Prop $fmtResp 'settingsPath'))
                if (-not [string]::IsNullOrEmpty($fmtBlock)) {
                    if ($sb.Length -gt 0) { [void]$sb.AppendLine() }   # blank line separating from diagnostics
                    [void]$sb.AppendLine($fmtBlock)
                    Write-CLog 'format-on-edit: surfaced a formatting suggestion'
                }
            } elseif ($null -ne $fmtResp) {
                Write-CLog ('format-on-edit: no suggestion (formatStatus=' + [string](Get-Prop $fmtResp 'formatStatus') +
                    ' changed=' + [string](Get-Prop $fmtResp 'changed') + ')')
            }
        } catch {
            Write-CLog ('format-on-edit suggestion failed (degrading, no surface): ' + $_.Exception.Message)
        }
    }
    elseif ($FormatMode -eq 'apply') {
        # Format-on-edit APPLY (000099): request the daemon's GUARDED write-back. Fully wrapped and
        # fail-safe -- any failure logs and surfaces nothing beyond what already rendered; the hook
        # still exits 0; the CLIENT never writes the file (the daemon does, guarded). Three outcomes:
        #   applied       -> the file WAS written. The diagnostics rendered above are PRE-apply (their
        #                    line numbers may have shifted, OQ2), so SUPPRESS them: rebuild the surface
        #                    as [any analysis-health banner] + the visibly-distinct WAS-MODIFIED block
        #                    (which tells the agent to re-read). No re-derive round-trip -- the agent's
        #                    next edit re-checks the file, and the 000061 lifecycle is not double-diffed.
        #   apply-aborted -> the file was NOT touched (a stale-write guard trip, mixed EOL, a UTF-16
        #                    file, or a write error). The rendered diagnostics stand; append the
        #                    suggest-shaped fallback with the honest reason (only when there is a diff).
        #   ok / other    -> no change (no write) or a degrade: surface nothing extra (like suggest).
        try {
            $fmtResp = Get-FormatResponse $pipeName $path $ConnectTimeoutMs $HardCapMs $cwd $true
            if ($null -ne $fmtResp -and [bool](Get-Prop $fmtResp 'ok')) {
                $fst = [string](Get-Prop $fmtResp 'formatStatus')
                if ($fst -eq 'applied') {
                    $applyModified = $true
                    $applyBlock = Format-FormattingAppliedBlock `
                        -Path $path -Diff ([string](Get-Prop $fmtResp 'diff')) `
                        -Removed ([int](Get-Prop $fmtResp 'removed')) -Added ([int](Get-Prop $fmtResp 'added')) `
                        -Truncated ([bool](Get-Prop $fmtResp 'truncated')) -SettingsPath ([string](Get-Prop $fmtResp 'settingsPath'))
                    # Suppress the stale pre-apply diagnostics: rebuild from scratch, preserving only
                    # the analysis-health banner (which carries no line numbers) so a 'PSES did not
                    # start' signal is not lost on the apply turn.
                    $sb = New-Object System.Text.StringBuilder
                    if ($status -and $status -ne 'ok') {
                        $applyBanner = Get-DiagnosticsStatusBanner $status $path
                        if (-not [string]::IsNullOrEmpty($applyBanner)) { [void]$sb.AppendLine($applyBanner) }
                    }
                    if (-not [string]::IsNullOrEmpty($applyBlock)) {
                        if ($sb.Length -gt 0) { [void]$sb.AppendLine() }
                        [void]$sb.AppendLine($applyBlock)
                    }
                    Write-CLog 'format-on-edit: APPLIED formatting (file modified on disk; suppressed stale pre-apply diagnostics)'
                } elseif ($fst -eq 'apply-aborted') {
                    if ([bool](Get-Prop $fmtResp 'changed')) {
                        $fbBlock = Format-FormattingApplyAbortedBlock `
                            -Path $path -Diff ([string](Get-Prop $fmtResp 'diff')) `
                            -Removed ([int](Get-Prop $fmtResp 'removed')) -Added ([int](Get-Prop $fmtResp 'added')) `
                            -Truncated ([bool](Get-Prop $fmtResp 'truncated')) -SettingsPath ([string](Get-Prop $fmtResp 'settingsPath')) `
                            -Reason ([string](Get-Prop $fmtResp 'error'))
                        if (-not [string]::IsNullOrEmpty($fbBlock)) {
                            if ($sb.Length -gt 0) { [void]$sb.AppendLine() }
                            [void]$sb.AppendLine($fbBlock)
                            Write-CLog ('format-on-edit: apply aborted (' + [string](Get-Prop $fmtResp 'error') + '); surfaced suggest fallback')
                        }
                    } else {
                        Write-CLog ('format-on-edit: apply aborted, no change to suggest (' + [string](Get-Prop $fmtResp 'error') + ')')
                    }
                } else {
                    Write-CLog ('format-on-edit apply: no action (formatStatus=' + $fst +
                        ' changed=' + [string](Get-Prop $fmtResp 'changed') + ')')
                }
            } elseif ($null -ne $fmtResp) {
                Write-CLog 'format-on-edit apply: response not ok'
            }
        } catch {
            Write-CLog ('format-on-edit apply failed (degrading, no surface): ' + $_.Exception.Message)
        }
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
    # OCCURRENCES are captured -- a status-only banner (incomplete/unavailable) is not one. On a real
    # apply (000099) the pre-apply diagnostics were SUPPRESSED (stale line numbers), so they are not
    # captured either -- the dogfood log records only what was actually surfaced to Claude.
    if ($diags.Count -gt 0 -and -not $applyModified) {
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
