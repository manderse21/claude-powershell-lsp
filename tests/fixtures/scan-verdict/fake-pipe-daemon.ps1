# FAKE per-session daemon for the REAL-client reachability cases (dispatch 000302, A1).
#
# The scan-verdict census drives FAKE clients. These cases drive the REAL scripts/lsp-client.ps1
# instead, to show the real client produces the same child behaviour the fakes model. The real
# client needs a daemon on the session pipe; this is the smallest one that can answer it. It
# serves the session pipe built by the PRODUCTION helpers (Get-DaemonPipeName, New-DaemonPipeServer,
# Reset-PipeServerConnection -- the same name, options and reuse rule the real daemon uses), and
# answers every request line with ONE canned response read from -ResponseFile. No PSES, no
# analysis.
#
# It keeps serving -- accept, answer, reset, accept again -- until -LifetimeMs elapses or it is
# killed, so the pipe stays PRESENT after the first answer. That matters: on a $null result the
# real client asks Test-DaemonPipePresent before deciding to relaunch, and a vanished pipe would
# send it down the relaunch path instead of the one under test. (The tests also pre-stamp the
# relaunch cooldown, so the real client can never launch a real daemon from here.)
#
# -ReadyFile is written (with this pid) only after the server stream exists, so a test can wait
# for readiness instead of sleeping. Every request line is appended to -RequestLog.
#
# ASCII-only (PS 5.1 reads a UTF-8-without-BOM file through Windows-1252).

param(
    [Parameter(Mandatory = $true)][string] $SessionId,
    [Parameter(Mandatory = $true)][string] $ResponseFile,
    [Parameter(Mandatory = $true)][string] $ReadyFile,
    [Parameter(Mandatory = $true)][string] $RequestLog,
    [Parameter(Mandatory = $true)][string] $LibPath,
    [int] $LifetimeMs = 120000
)

$ErrorActionPreference = 'Stop'
. $LibPath

$pipeName = Get-DaemonPipeName -SessionId $SessionId
$response = ([System.IO.File]::ReadAllText($ResponseFile)).TrimEnd("`r", "`n")
$server = New-DaemonPipeServer -PipeName $pipeName
[System.IO.File]::WriteAllText($ReadyFile, [string]$PID)

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$connectTask = $null
try {
    while ($sw.ElapsedMilliseconds -lt $LifetimeMs) {
        if ($null -eq $connectTask) { $connectTask = $server.WaitForConnectionAsync() }
        if (-not $connectTask.Wait(250)) { continue }
        $connectTask = $null
        try {
            $reader = New-Object System.IO.StreamReader($server, [System.Text.Encoding]::UTF8, $false, 4096, $true)
            $writer = New-Object System.IO.StreamWriter($server, (New-Object System.Text.UTF8Encoding($false)), 4096, $true)
            $writer.NewLine = "`n"; $writer.AutoFlush = $true
            $line = $reader.ReadLine()
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                [System.IO.File]::AppendAllText($RequestLog, $line + "`n")
                $writer.WriteLine($response)
                $writer.Flush()
            }
        } catch {
            [System.IO.File]::AppendAllText($RequestLog, '# handler error: ' + $_.Exception.Message + "`n")
        } finally {
            $reset = Reset-PipeServerConnection -Server $server
            if (-not $reset.Ok) {
                try { $server.Dispose() } catch { }
                $server = New-DaemonPipeServer -PipeName $pipeName
            }
        }
    }
} finally {
    try { $server.Dispose() } catch { }
}
