# S1 -- SILENT EXIT 0 (dispatch 000302, A1 scan-verdict census).
#
# A FAKE scripts/lsp-client.ps1. tests/ScanHarness.Common.ps1 copies it into a contained fake
# scripts directory, where the REAL Invoke-ScanFileDiagnostics (scripts/lib/lsp-scan-common.ps1)
# spawns it exactly as it spawns the real client.
#
# It consumes its stdin and ends with exit 0, writing nothing to stdout, nothing to stderr and
# no capture record. That is the observable shape of every fail-safe exit in the real client
# (empty stdin, no session id, file gone, daemon error, the FATAL catch): the child ended, and
# nothing it produced says whether any analysis happened.
#
# Its observable output is IDENTICAL to s9-clean-complete.ps1. That is the point of the pair,
# not an accident -- see the header of that file.
#
# ASCII-only (PS 5.1 reads a UTF-8-without-BOM file through Windows-1252).

$null = [Console]::In.ReadToEnd()
[System.IO.File]::WriteAllText((Join-Path $env:CLAUDE_PLUGIN_DATA 'fake-ran.txt'), 'S1')
exit 0
