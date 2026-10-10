# S9 -- VALID COMPLETED ZERO FINDINGS (dispatch 000302, A1 scan-verdict census; the CONTROL).
#
# A FAKE scripts/lsp-client.ps1 (see s1-silent-exit-zero.ps1 for how it is driven). It stands
# for a settled, clean analysis: it reads its payload, confirms the target exists and parses
# with zero errors, and then produces EXACTLY what the real client produces for a clean pass --
# no stdout (an empty context is never emitted), no capture record (only diagnostic
# occurrences are captured), exit 0.
#
# WHY THIS FILE AND s1-silent-exit-zero.ps1 LOOK THE SAME FROM OUTSIDE. Under the current
# protocol a clean pass has NO positive completion signal: an ordinary healthy hook is silent on
# purpose (the interactive contract), and the scanner's only evidence of a finding is a capture
# row. So "analysis completed and found nothing" and "the child ended before analysing" are
# byte-identical at the scanner's boundary. S1 is expected NOT analyzed, this case is expected
# analyzed, and no scanner can satisfy both while the two children are indistinguishable. That
# pair is the measured form of the gap: absence of finding records is not evidence of
# completion.
#
# HOW THIS FIXTURE MIGRATES (the receipt producer does not exist yet). When the A2 leg lands a
# completion receipt, this fixture must emit it by CALLING A2's production producer from the lib
# copy beside it (dot-sourced exactly as s5-truncated-record.ps1 calls the production capture
# writer) -- never by writing a hand-made row. Until then it writes NOTHING that pretends to be a
# completion record: no current protocol has one, and a made-up row here would be a forgery the
# scanner could be taught to accept. s1-silent-exit-zero.ps1 must stay receipt-less.
#
# Exit 2 marks a HARNESS error (missing or unparseable target) so a misused control fails loudly.
#
# ASCII-only (PS 5.1 reads a UTF-8-without-BOM file through Windows-1252).

. (Join-Path $PSScriptRoot 'lib/lsp-common.ps1')
$raw = Get-StdinText   # BOM-tolerant, as the real hooks read it (a 5.1 parent prepends a BOM)
[System.IO.File]::WriteAllText((Join-Path $env:CLAUDE_PLUGIN_DATA 'fake-ran.txt'), 'S9')
$path = [System.IO.Path]::GetFullPath([string]((($raw | ConvertFrom-Json).tool_input).file_path))
if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { exit 2 }
$tokens = $null; $errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if (@($errors).Count -gt 0) { exit 2 }
exit 0
