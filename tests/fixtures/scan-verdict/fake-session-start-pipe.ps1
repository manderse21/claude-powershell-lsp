# FAKE scripts/session-start.ps1 for the REAL-CLIENT CLI layer (dispatch 000304, A2).
#
# The A1 CLI layer ran the shipped scripts/lsp-scan.ps1 against FAKE clients, and recorded that
# "the full real-hook CLI check for the F1 situations" was A2's to do: lsp-scan.ps1 resolves every
# hook from its own directory and has no other seam. This is that check's seam. A relocated tree
# (New-SvCliTree -RealClient) holds BYTE COPIES of the shipped CLI, its three libraries AND the
# shipped scripts/lsp-client.ps1; only session start/end are fakes. This one, instead of launching
# PSES, launches tests/fixtures/scan-verdict/fake-pipe-daemon.ps1 on the scan's own session pipe, so
# the REAL client talks to a deterministic daemon over the REAL pipe protocol.
#
# It reads its orders from <CLAUDE_PLUGIN_DATA>/cr-daemon.json (written by the test):
#   daemonScript  absolute path of fake-pipe-daemon.ps1
#   response      the canned diagnostics answer (JSON text)
#   binding       the fake daemon's -Binding mode
#   vanish        '' or an absolute path to delete NOW -- after lsp-scan.ps1 enumerated its targets and
#                 before any client runs: the vanished-source situation, at the real CLI
# Then it stamps the real client's relaunch cooldown (so a real daemon can never be launched from
# here), waits for the fake daemon's pipe, and writes session/<id>.json in state 'ready' carrying the
# fake daemon's pid -- so the PRODUCTION Stop-ScanDaemon tears it down by that pid.
#
# ASCII-only (PS 5.1 reads a UTF-8-without-BOM file through Windows-1252).

param(
    [string] $PreferredHost = 'pwsh',
    [int] $MaxWaitMs = 0
)

. (Join-Path $PSScriptRoot 'lib/lsp-common.ps1')
$raw = Get-StdinText   # BOM-tolerant, as the real hooks read it (a 5.1 parent prepends a BOM)
$sid = [string](($raw | ConvertFrom-Json).session_id)
$dataRoot = Get-PluginDataRoot
$cfg = [System.IO.File]::ReadAllText((Join-Path $dataRoot 'cr-daemon.json')) | ConvertFrom-Json

$sessionDir = Get-SessionDir
New-ContainedDirectory -Path $sessionDir
Set-Content -LiteralPath (Join-Path $sessionDir ($sid + '.relaunch')) -Value ([string]$PID) -Encoding ascii -Force

if (-not [string]::IsNullOrWhiteSpace([string]$cfg.vanish) -and (Test-Path -LiteralPath ([string]$cfg.vanish))) {
    Remove-Item -LiteralPath ([string]$cfg.vanish) -Force
}

$work = Join-Path $dataRoot ('cr-daemon-' + $sid)
New-Item -ItemType Directory -Force -Path $work | Out-Null
$responseFile = Join-Path $work 'response.json'
$readyFile = Join-Path $work 'ready.pid'
[System.IO.File]::WriteAllText($responseFile, [string]$cfg.response + "`n", (New-Object System.Text.UTF8Encoding($false)))
$hostExe = Resolve-PsHost $PreferredHost
$daemonArgs = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', [string]$cfg.daemonScript,
    '-SessionId', $sid, '-ResponseFile', $responseFile, '-ReadyFile', $readyFile,
    '-RequestLog', (Join-Path $work 'requests.log'), '-LibPath', (Join-Path $PSScriptRoot 'lib/lsp-common.ps1'),
    '-ReceiptLibPath', (Join-Path $PSScriptRoot 'lib/lsp-scan-receipt.ps1'), '-Binding', [string]$cfg.binding,
    '-LifetimeMs', '180000')
# Detached the way the real launcher detaches (Start-PsesDaemonDetached): on Windows through
# ShellExecute (-WindowStyle Hidden), which passes no inheritable handle -- so the fake daemon can
# never hold this hook's drained stdout/stderr pipes open -- and elsewhere with its streams on files.
if (Test-OnWindows) {
    $proc = Start-Process -FilePath $hostExe -PassThru -WindowStyle Hidden -ArgumentList $daemonArgs
} else {
    $proc = Start-Process -FilePath $hostExe -PassThru `
        -RedirectStandardOutput (Join-Path $work 'daemon.out') -RedirectStandardError (Join-Path $work 'daemon.err') `
        -ArgumentList $daemonArgs
}
$pipeName = Get-DaemonPipeName -SessionId $sid
$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($sw.ElapsedMilliseconds -lt 30000) {
    if ((Test-Path -LiteralPath $readyFile) -and (Test-DaemonPipePresent -PipeName $pipeName)) { break }
    if ($proc.HasExited) { break }
    Start-Sleep -Milliseconds 100
}
$ready = [ordered]@{ state = 'ready'; sessionId = $sid; pid = $proc.Id; fake = 'tests/fixtures/scan-verdict/fake-session-start-pipe.ps1' }
[System.IO.File]::WriteAllText((Join-Path $sessionDir ($sid + '.json')), ($ready | ConvertTo-Json -Compress))
exit 0
