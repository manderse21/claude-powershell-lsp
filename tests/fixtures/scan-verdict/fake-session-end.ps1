# FAKE scripts/session-end.ps1 for the scan harness (dispatch 000302, A1).
#
# The REAL Stop-ScanDaemon spawns session-end.ps1 to tear the scan daemon down. A fake scanner
# has no daemon, so this consumes its stdin and exits 0. Nothing else -- in particular it never
# looks up or kills a process.
#
# ASCII-only (PS 5.1 reads a UTF-8-without-BOM file through Windows-1252).

$null = [Console]::In.ReadToEnd()
exit 0
