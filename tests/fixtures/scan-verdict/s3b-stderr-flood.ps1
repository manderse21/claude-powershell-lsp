# S3b -- STDERR FLOOD (dispatch 000302, A1 scan-verdict census; the volume half of S3).
#
# A FAKE scripts/lsp-client.ps1 (see s1-silent-exit-zero.ps1 for how it is driven). It writes
# 1 MiB to stderr and then exits 0 on its own -- it needs no cap to end.
#
# Invoke-ScanHook redirects stderr but starts no reader for it. A redirected pipe holds only its
# buffer (4 KiB on Windows, 64 KiB on Linux) before a write BLOCKS, so with nobody draining it
# this child cannot finish its writes, never reaches `exit 0`, and is held until the scanner's
# cap kill. A drained stderr lets it finish in well under a second.
#
# Its pid goes to <CLAUDE_PLUGIN_DATA>/fake-child.pid FIRST, before stdin is read, so the test
# can always reap it -- including on Windows PowerShell 5.1, where the cap kill does not kill
# (see the S7 census case).
#
# ASCII-only (PS 5.1 reads a UTF-8-without-BOM file through Windows-1252).

[System.IO.File]::WriteAllText((Join-Path $env:CLAUDE_PLUGIN_DATA 'fake-child.pid'), [string]$PID)
$null = [Console]::In.ReadToEnd()
$line = 'x' * 1023
for ($i = 0; $i -lt 1024; $i++) { [Console]::Error.WriteLine($line) }
exit 0
