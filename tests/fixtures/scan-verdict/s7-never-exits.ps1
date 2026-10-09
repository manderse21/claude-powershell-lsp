# S7 -- DEADLINE KILL (dispatch 000302, A1 scan-verdict census).
#
# A FAKE scripts/lsp-client.ps1 (see s1-silent-exit-zero.ps1 for how it is driven). It NEVER
# exits: it blocks on an event nobody sets, so the scanner's WaitForExit($CapMs) expires
# deterministically rather than probabilistically -- the 000159 pattern, no sleep and no timing
# window. This is the census form of the existing green regression (PowerShellLsp.SarifScan.
# Tests.ps1, 'a client-cap kill is never a clean file', dispatch 000132), which stays exactly
# where it is.
#
# Its pid goes to <CLAUDE_PLUGIN_DATA>/fake-child.pid FIRST, so the test can check whether the
# cap kill actually terminated it, and reap it when it did not.
#
# ASCII-only (PS 5.1 reads a UTF-8-without-BOM file through Windows-1252).

[System.IO.File]::WriteAllText((Join-Path $env:CLAUDE_PLUGIN_DATA 'fake-child.pid'), [string]$PID)
$ev = New-Object System.Threading.ManualResetEventSlim($false)
[void]$ev.Wait()
