#Requires -Version 5.1

# session-end.ps1 -- SessionEnd hook. Graceful teardown of this session's warm
# daemon: send {shutdown} over the pipe so the daemon issues LSP shutdown/exit to
# its PSES child and exits, removing its own session file. If the pipe is
# unreachable, fall back to a verified-pid kill (recorded pid only). Silent on
# stdout; logs to CLAUDE_PLUGIN_DATA/logs.
#
# Author: Mike Andersen / powershell-lsp plugin.

param(
    [int] $ConnectTimeoutMs = 1500
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/lsp-common.ps1')

$logDir = Get-LogDir
$sessionDir = Get-SessionDir
try { New-Item -ItemType Directory -Force -Path $logDir | Out-Null } catch { }
$endLog = Join-Path $logDir 'session-end.log'
function Write-ELog([string]$m) {
    try { ('[' + (Get-Date -Format 'o') + '] ' + $m) | Out-File -FilePath $endLog -Append -Encoding ascii } catch { }
}

function Send-Shutdown([string]$pipeName, [int]$timeoutMs) {
    $client = $null
    try {
        $client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipeName,
            [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
        $client.Connect($timeoutMs)
        $writer = New-Object System.IO.StreamWriter($client, (New-Object System.Text.UTF8Encoding($false)), 4096, $true)
        $writer.NewLine = "`n"; $writer.AutoFlush = $true
        $reader = New-Object System.IO.StreamReader($client, [System.Text.Encoding]::UTF8, $false, 4096, $true)
        $writer.WriteLine('{"action":"shutdown"}')
        $writer.Flush()
        $readTask = $reader.ReadLineAsync()
        [void]$readTask.Wait(2000)
        return $true
    } catch {
        Write-ELog ('pipe shutdown failed: ' + $_.Exception.Message)
        return $false
    } finally {
        try { if ($null -ne $client) { $client.Dispose() } } catch { }
    }
}

function Test-IsOurDaemon([int]$daemonPid) {
    try {
        $proc = Get-Process -Id $daemonPid -ErrorAction SilentlyContinue
        if ($null -eq $proc) { return $false }
        if (@('pwsh', 'powershell') -notcontains $proc.ProcessName.ToLowerInvariant()) { return $false }
        return ((Get-ProcessCommandLine $daemonPid) -match 'pses-daemon\.ps1')
    } catch { return $false }
}

function Stop-OrphanPses([int]$psesPid) {
    if (-not $psesPid) { return }
    try {
        $proc = Get-Process -Id $psesPid -ErrorAction SilentlyContinue
        if ($null -eq $proc) { return }
        if (@('pwsh', 'powershell') -notcontains $proc.ProcessName.ToLowerInvariant()) { return }
        if ((Get-ProcessCommandLine $psesPid) -match 'Start-EditorServices\.ps1') {
            Stop-Process -Id $psesPid -Force -ErrorAction SilentlyContinue
            Write-ELog ('fallback: killed orphaned PSES child pid ' + $psesPid)
        }
    } catch { }
}

try {
    $sessionId = $null
    try {
        $raw = Get-StdinText
        if (-not [string]::IsNullOrWhiteSpace($raw)) { $sessionId = [string](Get-Prop ($raw | ConvertFrom-Json) 'session_id') }
    } catch { }
    Write-ELog ('--- SessionEnd (session=' + $sessionId + ') ---')
    if ([string]::IsNullOrWhiteSpace($sessionId)) { Write-ELog 'no session_id; nothing to tear down'; exit 0 }

    $pipeName = 'powershell-lsp-' + $sessionId
    $sessionFile = Join-Path $sessionDir ($sessionId + '.json')

    $ok = Send-Shutdown $pipeName $ConnectTimeoutMs
    if ($ok) {
        Write-ELog 'graceful shutdown sent'
        # give the daemon a moment to remove its own file; clean up if it lingers
        Start-Sleep -Milliseconds 600
        if (Test-Path -LiteralPath $sessionFile) { try { Remove-Item -LiteralPath $sessionFile -Force } catch { } }
        exit 0
    }

    # Fallback: verified-pid kill from the recorded session file.
    if (Test-Path -LiteralPath $sessionFile) {
        $obj = $null
        try { $obj = (Get-Content -LiteralPath $sessionFile -Raw) | ConvertFrom-Json } catch { }
        if ($null -ne $obj) {
            $recPid = [int](Get-Prop $obj 'pid')
            $psesPid = [int](Get-Prop $obj 'psesPid')
            if (Test-IsOurDaemon $recPid) {
                Write-ELog ('fallback kill of our daemon pid ' + $recPid)
                try { Stop-Process -Id $recPid -Force -ErrorAction Stop } catch { Write-ELog ('fallback kill failed: ' + $_.Exception.Message) }
            }
            Stop-OrphanPses $psesPid
        }
        try { Remove-Item -LiteralPath $sessionFile -Force } catch { }
    }
    exit 0
}
catch {
    Write-ELog ('FATAL (fail-safe, exit 0): ' + $_.Exception.Message)
    exit 0
}
