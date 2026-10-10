# S4 -- MALFORMED RESPONSE (dispatch 000302, A1 scan-verdict census).
#
# A FAKE scripts/lsp-client.ps1 (see s1-silent-exit-zero.ps1 for how it is driven). Both
# channels the scanner could read come back unparseable, and the child exits 0:
#   - the ONE capture row it writes to POWERSHELL_LSP_DOGFOOD_LOG is not JSON. That log is the
#     scanner's only source of findings, and Invoke-ScanFileDiagnostics skips a row that fails
#     ConvertFrom-Json with a bare `continue`;
#   - stdout is a hookSpecificOutput envelope cut off mid-string, so it is not JSON either. The
#     scanner reads stdout only to look for a 'NOT checked' banner, so this half is invisible to
#     it today -- it is here so the case stays malformed on BOTH channels once a typed result
#     is read from stdout.
#
# The real-client form of this case -- a daemon answer of the wrong TYPE that drives
# scripts/lsp-client.ps1 into its FATAL fail-safe `exit 0` -- is the reachability case in
# PowerShellLsp.ScanVerdict.Tests.ps1, driven through fake-pipe-daemon.ps1.
#
# ASCII-only (PS 5.1 reads a UTF-8-without-BOM file through Windows-1252).

$null = [Console]::In.ReadToEnd()
[System.IO.File]::WriteAllText((Join-Path $env:CLAUDE_PLUGIN_DATA 'fake-ran.txt'), 'S4')
$log = $env:POWERSHELL_LSP_DOGFOOD_LOG
if (-not [string]::IsNullOrWhiteSpace($log)) {
    [System.IO.File]::AppendAllText($log, 'this capture row is not JSON: ruleId=PSUseApprovedVerbs line=1 col=10' + "`n")
}
[Console]::Out.Write('{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"PowerShell diagnostics (1) for')
exit 0
