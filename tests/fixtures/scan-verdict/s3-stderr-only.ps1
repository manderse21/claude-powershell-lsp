# S3 -- STDERR-ONLY ERROR (dispatch 000302, A1 scan-verdict census).
#
# A FAKE scripts/lsp-client.ps1 (see s1-silent-exit-zero.ps1 for how it is driven). The child
# reports a failure on stderr and nowhere else, then exits 0. Invoke-ScanHook redirects stderr
# but never reads it, so the only record of the failure is discarded.
#
# The message is small on purpose: this case is about the VERDICT. The volume case -- a stderr
# that overflows the pipe buffer -- is s3b-stderr-flood.ps1.
#
# ASCII-only (PS 5.1 reads a UTF-8-without-BOM file through Windows-1252).

$null = [Console]::In.ReadToEnd()
[System.IO.File]::WriteAllText((Join-Path $env:CLAUDE_PLUGIN_DATA 'fake-ran.txt'), 'S3')
[Console]::Error.WriteLine('lsp-client: unhandled failure -- the analyzer did not run (simulated stderr-only error)')
exit 0
