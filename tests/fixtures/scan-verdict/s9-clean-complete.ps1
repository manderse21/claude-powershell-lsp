# S9 -- VALID COMPLETED ZERO FINDINGS (dispatch 000302, A1 scan-verdict census; the CONTROL).
#
# A FAKE scripts/lsp-client.ps1 (see s1-silent-exit-zero.ps1 for how it is driven). It stands
# for a settled, clean analysis: it reads its payload, confirms the target exists and parses
# with zero errors, and then produces EXACTLY what the real client produces for a clean pass --
# no stdout (an empty context is never emitted), no capture record (only diagnostic
# occurrences are captured), exit 0 -- AND, since dispatch 000304, the completion receipt the
# real client writes in scan mode.
#
# WHY THIS FILE AND s1-silent-exit-zero.ps1 USED TO LOOK THE SAME FROM OUTSIDE. Under the
# pre-000304 protocol a clean pass had NO positive completion signal: an ordinary healthy hook is
# silent on purpose (the interactive contract), and the scanner's only evidence of a finding was a
# capture row. So "analysis completed and found nothing" and "the child ended before analysing"
# were byte-identical at the scanner's boundary, and no scanner could satisfy both S1 (expected NOT
# analyzed) and this case (expected analyzed). That pair was the measured form of the gap.
#
# HOW IT MIGRATED (dispatch 000304, as A1 required). The receipt is emitted by CALLING the
# production producer from the receipt library copied beside this script -- the way
# s5-truncated-record.ps1 calls the production capture writer -- never by writing a hand-made row.
# Standing in for the client AND its daemon, it reads the target's bytes with the production
# Read-ScanSourceSnapshot, binds them with the production New-ScanAnalysisBinding under the request
# id the scanner sent, and builds and writes the receipt with New-ScanReceipt / Write-ScanReceipt.
# The scanner then validates it exactly as it validates the real client's. s1-silent-exit-zero.ps1
# stays receipt-less, which is now the whole difference between the two.
#
# Exit 2 marks a HARNESS error (missing or unparseable target) so a misused control fails loudly.
#
# ASCII-only (PS 5.1 reads a UTF-8-without-BOM file through Windows-1252).

. (Join-Path $PSScriptRoot 'lib/lsp-common.ps1')
. (Join-Path $PSScriptRoot 'lib/lsp-scan-receipt.ps1')
$raw = Get-StdinText   # BOM-tolerant, as the real hooks read it (a 5.1 parent prepends a BOM)
[System.IO.File]::WriteAllText((Join-Path $env:CLAUDE_PLUGIN_DATA 'fake-ran.txt'), 'S9')
$payload = $raw | ConvertFrom-Json
$path = [System.IO.Path]::GetFullPath([string](($payload.tool_input).file_path))
if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { exit 2 }
$tokens = $null; $errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if (@($errors).Count -gt 0) { exit 2 }

$ctx = Get-ScanRequestContext -Payload $payload
if ($null -ne $ctx) {
    $snap = Read-ScanSourceSnapshot -Path $path
    $binding = New-ScanAnalysisBinding -RequestId $ctx.RequestId -AnalyzedPath $path -Snapshot $snap `
        -Settled $true -PssaAvailable $true -Engine (Get-ScanEngineIdentity -PsesHost 's9-clean-complete')
    $receipt = New-ScanReceipt -RequestId $ctx.RequestId -File $path -Pass 'pssa' -Status 'ok' -Binding $binding `
        -Records @() -FormatMode 'off'
    [void](Write-ScanReceipt -Path $ctx.ReceiptPath -Receipt $receipt)
}
exit 0
