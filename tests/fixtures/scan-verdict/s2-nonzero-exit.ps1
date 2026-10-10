# S2 -- NONZERO EXIT (dispatch 000302, A1 scan-verdict census).
#
# A FAKE scripts/lsp-client.ps1 (see s1-silent-exit-zero.ps1 for how it is driven). The analysis
# host process ends with exit code 1 having written nothing to stdout, nothing to stderr and no
# capture record. The real client never exits nonzero on purpose -- every path ends `exit 0` --
# so a nonzero code means the HOST failed (the script could not be loaded, or something escaped
# the fail-safe catch). Invoke-ScanHook never reads the exit code, which is what this case puts
# in front of the scanner.
#
# ASCII-only (PS 5.1 reads a UTF-8-without-BOM file through Windows-1252).

$null = [Console]::In.ReadToEnd()
[System.IO.File]::WriteAllText((Join-Path $env:CLAUDE_PLUGIN_DATA 'fake-ran.txt'), 'S2')
exit 1
