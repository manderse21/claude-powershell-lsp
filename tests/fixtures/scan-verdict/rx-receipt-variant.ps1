# RX -- RECEIPT VARIANTS (dispatch 000304, A2): the negative controls for the completion receipt.
#
# A FAKE scripts/lsp-client.ps1 (see s1-silent-exit-zero.ps1 for how it is driven). Every variant
# writes a receipt built by the PRODUCTION producer from the receipt library copied beside it
# (Read-ScanSourceSnapshot, New-ScanAnalysisBinding, New-ScanReceipt, Write-ScanReceipt), and then
# -- for a fault variant -- perturbs exactly one thing. Most variants are VALID-ENVELOPE controls:
# the receipt parses and is schema-valid, and the scanner must still refuse to certify the file,
# because envelope validity alone proves nothing. The variant name is read from
# <CLAUDE_PLUGIN_DATA>/rx-variant.txt, which the test writes before the run, so no environment
# variable is involved.
#
#   valid                 the control: a settled PSScriptAnalyzer pass over the bytes on disk
#   valid-with-finding    the control with one finding, captured by the production writer
#   unknown-engine        a valid receipt whose engine versions are 'unknown' (still complete; the
#                         certification must say unknown, never verified)
#   stderr-with-receipt   a valid receipt plus a stderr line (stderr is evidence, not a verdict)
#   degraded              status degraded: parser-only, PSScriptAnalyzer absent
#   incomplete            status incomplete: the pass did not settle
#   unavailable           status unavailable: no bytes consumed
#   capped                a per-file cap omitted a finding
#   forged-complete       a degraded receipt rewritten to claim complete with no reasons
#   wrong-request         the receipt answers a different request id
#   daemon-wrong-request  the daemon binding echoes a different request id
#   wrong-path            the receipt names a different file
#   wrong-source          the binding carries the SHA-256 of bytes other than the file's
#   source-changed        a valid receipt, then the file is changed before the child exits
#   diagnostics-mismatch  the receipt vouches for one finding nobody captured
#   truncated             the receipt file stops halfway through its JSON
#   malformed             the receipt file is not JSON
#   policy-certified      a valid receipt rewritten to claim a verified policy identity
#   config-bound          a valid receipt rewritten to claim a bound configuration
#   nonzero-after-receipt a valid receipt, then exit 1
#
# ASCII-only (PS 5.1 reads a UTF-8-without-BOM file through Windows-1252).

. (Join-Path $PSScriptRoot 'lib/lsp-common.ps1')
. (Join-Path $PSScriptRoot 'lib/lsp-scan-receipt.ps1')
$raw = Get-StdinText   # BOM-tolerant, as the real hooks read it (a 5.1 parent prepends a BOM)
$variant = ([System.IO.File]::ReadAllText((Join-Path $env:CLAUDE_PLUGIN_DATA 'rx-variant.txt'))).Trim()
[System.IO.File]::WriteAllText((Join-Path $env:CLAUDE_PLUGIN_DATA 'fake-ran.txt'), 'RX:' + $variant)
$payload = $raw | ConvertFrom-Json
$path = [System.IO.Path]::GetFullPath([string](($payload.tool_input).file_path))
$ctx = Get-ScanRequestContext -Payload $payload
if ($null -eq $ctx) { exit 2 }

$snap = Read-ScanSourceSnapshot -Path $path
$engine = Get-ScanEngineIdentity -PsesHost 'rx-receipt-variant'
if ($variant -ne 'unknown-engine') {
    # A fake has no PSES bundle beside it; stand in observed versions so 'unknown' is this one variant's.
    $engine['pses'] = '4.6.0'; $engine['pssa'] = '1.25.0'
}
$settled = $true; $pssa = $true; $status = 'ok'; $omitted = 0
$rid = $ctx.RequestId; $file = $path; $bindId = $ctx.RequestId
$records = @()
switch ($variant) {
    'degraded' { $pssa = $false; $status = 'degraded' }
    'forged-complete' { $pssa = $false; $status = 'degraded' }
    'incomplete' { $settled = $false; $status = 'incomplete' }
    'unavailable' { $settled = $false; $status = 'unavailable'; $snap = $null }
    'capped' { $omitted = 1 }
    'wrong-request' { $rid = [guid]::NewGuid().ToString('N') }
    'daemon-wrong-request' { $bindId = [guid]::NewGuid().ToString('N') }
    'wrong-path' { $file = $path + '.not-this-file.ps1' }
    'wrong-source' { $snap.Sha256 = Get-Sha256HexFromBytes -Bytes ([System.Text.Encoding]::UTF8.GetBytes('these are not the bytes on disk')) }
}
$diag = [pscustomobject]@{
    severity = 'Warning'; line = 1; col = 10; source = 'PSScriptAnalyzer'; code = 'PSUseApprovedVerbs'
    message  = 'The cmdlet ''Frobnicate-Thing'' uses an unapproved verb.'
}
if ($variant -eq 'valid-with-finding') {
    $records = @(New-CaptureRecordFromDiag $diag)
    Add-DiagnosticCaptureEntries -File $path -Records $records | Out-Null
}
if ($variant -eq 'diagnostics-mismatch') { $records = @(New-CaptureRecordFromDiag $diag) }   # vouched for, never captured

$binding = New-ScanAnalysisBinding -RequestId $bindId -AnalyzedPath $path -Snapshot $snap -Settled $settled `
    -PssaAvailable $pssa -Engine $engine
$receipt = New-ScanReceipt -RequestId $rid -File $file -Pass 'pssa' -Status $status -Binding $binding `
    -Omitted $omitted -Records $records -FormatMode 'off'

switch ($variant) {
    'forged-complete' { $receipt['completeness'] = 'complete'; $receipt['reasons'] = @() }
    'policy-certified' { $receipt['policy'] = [ordered]@{ state = 'verified' } }
    'config-bound' { $receipt['config'] = [ordered]@{ state = 'bound'; observed = $null } }
}
switch ($variant) {
    'truncated' {
        # Cut mid-object; a cut that happens to land just after a '}' is trimmed back, so the text
        # always stops before its JSON does.
        $json = $receipt | ConvertTo-Json -Depth 8 -Compress
        [System.IO.File]::WriteAllText($ctx.ReceiptPath, $json.Substring(0, [int]($json.Length / 2)).TrimEnd('}'))
    }
    'malformed' { [System.IO.File]::WriteAllText($ctx.ReceiptPath, 'this is not a completion receipt') }
    default { [void](Write-ScanReceipt -Path $ctx.ReceiptPath -Receipt $receipt) }
}
if ($variant -eq 'source-changed') { [System.IO.File]::AppendAllText($path, "# changed while it was being scanned`n") }
if ($variant -eq 'stderr-with-receipt') { [Console]::Error.WriteLine('rx: a warning on stderr, after a valid receipt') }
if ($variant -eq 'nonzero-after-receipt') { exit 1 }
exit 0
