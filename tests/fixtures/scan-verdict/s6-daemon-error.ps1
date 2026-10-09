# S6 -- DAEMON ok=false (dispatch 000302, A1 scan-verdict census).
#
# A FAKE scripts/lsp-client.ps1 (see s1-silent-exit-zero.ps1 for how it is driven). It mirrors
# what the real client does when the daemon answers {"ok":false}: scripts/lsp-client.ps1 logs
# `daemon error: <error>` to its client log and exits 0 with nothing on stdout and no capture
# record. The log line is written in the real client's own format, to the real client's own log
# path (Get-LogDir under CLAUDE_PLUGIN_DATA), using the lib copy beside this script.
#
# The scanner never reads that log, so this is S1 with a reason attached that nobody sees. The
# REAL client is driven into this exact path by the reachability case in
# PowerShellLsp.ScanVerdict.Tests.ps1 (fake-pipe-daemon.ps1 answering ok=false).
#
# ASCII-only (PS 5.1 reads a UTF-8-without-BOM file through Windows-1252).

$null = [Console]::In.ReadToEnd()
[System.IO.File]::WriteAllText((Join-Path $env:CLAUDE_PLUGIN_DATA 'fake-ran.txt'), 'S6')
. (Join-Path $PSScriptRoot 'lib/lsp-common.ps1')
$logDir = Get-LogDir
New-ContainedDirectory -Path $logDir
('[' + (Get-Date -Format 'o') + '] daemon error: file not found') |
    Out-File -FilePath (Join-Path $logDir 'lsp-client.log') -Append -Encoding ascii
exit 0
