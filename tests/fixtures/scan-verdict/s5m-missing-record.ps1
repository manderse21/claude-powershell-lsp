# S5m -- MISSING COMPLETION RECORDS (dispatch 000302, A1 scan-verdict census; the missing half
# of S5).
#
# A FAKE scripts/lsp-client.ps1 (see s1-silent-exit-zero.ps1 for how it is driven). The child
# announces TWO diagnostics on stdout and exits 0, but no capture row ever reaches
# POWERSHELL_LSP_DOGFOOD_LOG. The real writer, Add-DiagnosticCaptureEntries, swallows every
# failure by design (it is a fail-safe side channel), so a capture write that fails leaves
# exactly this: findings surfaced, nothing recorded. The scanner reads the log as its only
# source of findings, so the file arrives with zero findings.
#
# ASCII-only (PS 5.1 reads a UTF-8-without-BOM file through Windows-1252).

. (Join-Path $PSScriptRoot 'lib/lsp-common.ps1')
$raw = Get-StdinText   # BOM-tolerant, as the real hooks read it (a 5.1 parent prepends a BOM)
[System.IO.File]::WriteAllText((Join-Path $env:CLAUDE_PLUGIN_DATA 'fake-ran.txt'), 'S5m')
$path = [string]((($raw | ConvertFrom-Json).tool_input).file_path)
$ctx = 'PowerShell diagnostics (2) for ' + $path + ':' + "`n" +
    '  [Warning] line 1, col 10 -- The cmdlet ''Frobnicate-Thing'' uses an unapproved verb. (PSScriptAnalyzer/PSUseApprovedVerbs)' + "`n" +
    '  [Warning] line 2, col 5 -- ''gps'' is an alias of ''Get-Process''. (PSScriptAnalyzer/PSAvoidUsingCmdletAliases)'
$out = @{ hookSpecificOutput = @{ hookEventName = 'PostToolUse'; additionalContext = $ctx } }
[Console]::Out.Write(($out | ConvertTo-Json -Depth 6 -Compress))
exit 0
