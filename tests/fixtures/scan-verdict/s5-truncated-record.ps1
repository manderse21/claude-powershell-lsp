# S5 -- TRUNCATED COMPLETION (dispatch 000302, A1 scan-verdict census).
#
# A FAKE scripts/lsp-client.ps1 (see s1-silent-exit-zero.ps1 for how it is driven). The child
# announces TWO diagnostics on stdout, but the record stream the scanner reads is cut short:
# one complete capture row, then a second row that stops mid-object with no newline -- the
# shape a writer leaves when it dies in the middle of an append. It exits 0.
#
# The complete row is written by the PRODUCTION capture writer (New-CaptureRecordFromDiag +
# Add-DiagnosticCaptureEntries from the lib copy beside this script), not spelled by hand, so it
# is exactly the row the real client would write for the same diagnostic. Only the truncated
# tail is hand-made, because no production code path writes half a row on purpose.
#
# ASCII-only (PS 5.1 reads a UTF-8-without-BOM file through Windows-1252).

. (Join-Path $PSScriptRoot 'lib/lsp-common.ps1')
$raw = Get-StdinText   # BOM-tolerant, as the real hooks read it (a 5.1 parent prepends a BOM)
[System.IO.File]::WriteAllText((Join-Path $env:CLAUDE_PLUGIN_DATA 'fake-ran.txt'), 'S5')
$path = [string]((($raw | ConvertFrom-Json).tool_input).file_path)

$diag = [pscustomobject]@{
    severity = 'Warning'; line = 1; col = 10; source = 'PSScriptAnalyzer'; code = 'PSUseApprovedVerbs'
    message  = 'The cmdlet ''Frobnicate-Thing'' uses an unapproved verb.'
}
Add-DiagnosticCaptureEntries -File $path -Records @(New-CaptureRecordFromDiag $diag) | Out-Null

$tail = '{"ts":"2026-10-09T00:00:00.0000000Z","file":"' + ($path -replace '\\', '\\') + '","line":2,"col":5,"ruleId":"PSAvoidUsingCmdl'
[System.IO.File]::AppendAllText($env:POWERSHELL_LSP_DOGFOOD_LOG, $tail)

$ctx = 'PowerShell diagnostics (2) for ' + $path + ':' + "`n" +
    '  [Warning] line 1, col 10 -- The cmdlet ''Frobnicate-Thing'' uses an unapproved verb. (PSScriptAnalyzer/PSUseApprovedVerbs)' + "`n" +
    '  [Warning] line 2, col 5 -- ''gps'' is an alias of ''Get-Process''. (PSScriptAnalyzer/PSAvoidUsingCmdletAliases)'
$out = @{ hookSpecificOutput = @{ hookEventName = 'PostToolUse'; additionalContext = $ctx } }
[Console]::Out.Write(($out | ConvertTo-Json -Depth 6 -Compress))
exit 0
