# FAKE per-session daemon for the REAL-client reachability cases (dispatch 000302, A1; binding
# modes dispatch 000304, A2).
#
# The scan-verdict census drives FAKE clients. These cases drive the REAL scripts/lsp-client.ps1
# instead, to show the real client produces the same child behaviour the fakes model. The real
# client needs a daemon on the session pipe; this is the smallest one that can answer it. It
# serves the session pipe built by the PRODUCTION helpers (Get-DaemonPipeName, New-DaemonPipeServer,
# Reset-PipeServerConnection -- the same name, options and reuse rule the real daemon uses), and
# answers every request line with ONE canned response read from -ResponseFile. No PSES, no
# analysis.
#
# BINDING (dispatch 000304). A scan-mode request carries a requestId, and a real daemon answers it
# with that id echoed and an `analysis` binding of what it analyzed. -Binding chooses how this fake
# answers one, and every binding it writes is built by the PRODUCTION daemon-side helpers from
# -ReceiptLibPath (Read-ScanSourceSnapshot, New-ScanAnalysisBinding) -- never spelled by hand:
#   none           the canned response verbatim: a pre-000304 answer that binds nothing;
#   valid          the binding a real daemon would write for the requested file;
#   wrong-request  the binding echoes a different request id;
#   wrong-path     the binding names a different file;
#   wrong-source   the binding carries the SHA-256 of bytes other than the file's;
#   mutate-source  a valid binding of the bytes read, then the file is changed before the answer
#                  goes out (the source race, made deterministic).
# The canned response's status decides what the binding says about the pass: absent or ok =
# settled with PSScriptAnalyzer; degraded = settled without it; incomplete = did not settle;
# unavailable = no bytes consumed at all.
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
    [string] $ReceiptLibPath = '',
    [string] $Binding = 'none',
    [int] $LifetimeMs = 120000
)

$ErrorActionPreference = 'Stop'
. $LibPath
if (-not [string]::IsNullOrWhiteSpace($ReceiptLibPath)) { . $ReceiptLibPath }

function Get-FakeAnswer {
    # The canned response, with a binding merged in when the request asked for one and -Binding is
    # not 'none'.
    param([string]$RequestLine, [string]$Canned)
    if ($Binding -eq 'none') { return $Canned }
    $req = $null
    try { $req = $RequestLine | ConvertFrom-Json } catch { return $Canned }
    $rid = [string](Get-Prop $req 'requestId')
    if ([string]::IsNullOrWhiteSpace($rid)) { return $Canned }
    $answer = $Canned | ConvertFrom-Json
    $file = [System.IO.Path]::GetFullPath([string](Get-Prop $req 'file'))
    $status = [string](Get-Prop $answer 'status')
    $snap = $null
    if ($status -ne 'unavailable') { $snap = Read-ScanSourceSnapshot -Path $file -NoText }
    $settled = ($status -ne 'incomplete' -and $status -ne 'unavailable')
    $pssa = ($status -ne 'degraded')
    $boundId = $rid
    $boundPath = $file
    switch ($Binding) {
        'wrong-request' { $boundId = [guid]::NewGuid().ToString('N') }
        'wrong-path' { $boundPath = $file + '.not-this-file.ps1' }
        'wrong-source' {
            if ($null -ne $snap -and $snap.Exists) {
                $snap.Sha256 = Get-Sha256HexFromBytes -Bytes ([System.Text.Encoding]::UTF8.GetBytes('these are not the bytes on disk'))
            }
        }
    }
    $engine = Get-ScanEngineIdentity -PsesHost 'fake-pipe-daemon'
    $bind = New-ScanAnalysisBinding -RequestId $boundId -AnalyzedPath $boundPath -Snapshot $snap -Settled $settled `
        -PssaAvailable $pssa -Cached $false -Engine $engine -Config ([ordered]@{ fake = 'tests/fixtures/scan-verdict/fake-pipe-daemon.ps1' })
    $answer | Add-Member -NotePropertyName 'requestId' -NotePropertyValue $rid -Force
    $answer | Add-Member -NotePropertyName 'analysis' -NotePropertyValue $bind -Force
    if ($Binding -eq 'mutate-source' -and (Test-Path -LiteralPath $file)) {
        [System.IO.File]::AppendAllText($file, "# changed after the daemon read it`n")
    }
    return ($answer | ConvertTo-Json -Depth 8 -Compress)
}

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
                $writer.WriteLine((Get-FakeAnswer -RequestLine $line -Canned $response))
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
