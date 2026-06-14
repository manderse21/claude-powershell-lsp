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

function Get-Diagnostics([string]$pipeName, [string]$filePath, [int]$connectMs, [int]$hardCapMs) {
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

        $reqObj = [ordered]@{ action = 'diagnostics'; file = $filePath }
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
    $raw = Get-StdinText
    if ([string]::IsNullOrWhiteSpace($raw)) { Write-CLog 'empty stdin'; exit 0 }
    $payload = $raw | ConvertFrom-Json

    $sessionId = [string](Get-Prop $payload 'session_id')
    if ([string]::IsNullOrWhiteSpace($sessionId)) { Write-CLog 'no session_id'; exit 0 }

    $toolInput = Get-Prop $payload 'tool_input'
    $path = [string](Get-Prop $toolInput 'file_path')
    if ([string]::IsNullOrWhiteSpace($path)) { Write-CLog 'no tool_input.file_path'; exit 0 }

    if (-not [System.IO.Path]::IsPathRooted($path)) {
        $cwd = [string](Get-Prop $payload 'cwd')
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
        exit 0
    }

    $pipeName = 'powershell-lsp-' + $sessionId
    Write-CLog ('requesting diagnostics for ' + $path + ' via ' + $pipeName)

    $resp = Get-Diagnostics $pipeName $path $ConnectTimeoutMs $HardCapMs
    if ($null -eq $resp) { exit 0 }
    if (-not (Get-Prop $resp 'ok')) { Write-CLog ('daemon error: ' + [string](Get-Prop $resp 'error')); exit 0 }

    $diags = @(Get-Prop $resp 'diagnostics')
    if ($diags.Count -eq 0) { Write-CLog 'no diagnostics'; exit 0 }
    $omitted = [int](Get-Prop $resp 'omitted')

    $sb = New-Object System.Text.StringBuilder
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
    $context = $sb.ToString().TrimEnd()

    Write-HookContext $context
    Write-CLog ('emitted ' + $diags.Count + ' diagnostic(s)')
    exit 0
}
catch {
    Write-CLog ('FATAL (fail-safe, exit 0): ' + $_.Exception.Message)
    exit 0
}
