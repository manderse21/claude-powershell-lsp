#Requires -Version 5.1

# The scan COMPLETION RECEIPT contract (dispatch 000304, leg A2).
#
# WHAT IS UNDER TEST. scripts/lib/lsp-scan-receipt.ps1 defines what a scan-mode receipt means, the
# client (scripts/lsp-client.ps1) produces one per scanned file, and the scanner
# (Invoke-ScanFileDiagnostics, scripts/lib/lsp-scan-common.ps1) reports a file analyzed only when the
# receipt validates as COMPLETE. PowerShellLsp.ScanVerdict.Tests.ps1 drives that end to end through
# fake and real children; this file pins the contract itself:
#   1. the vocabulary -- the four public status tokens and nothing else, the reason table, and the
#      explicit status/completeness table;
#   2. the producer and the validator agree, and VALID-ENVELOPE negative controls prove that a
#      degraded / parser-only, incomplete or unavailable result -- or a receipt that claims more than
#      its facts, answers another request, names another file, binds other bytes, or vouches for
#      findings nobody recorded -- can never certify complete PSScriptAnalyzer analysis;
#   3. docs/scan-receipt.schema.json and the in-code shape check are the same contract;
#   4. the source identity is of raw bytes, and the diagnostics digest is order-free, duplicate- and
#      message-sensitive;
#   5. the typed scan spawner: exit code, both streams drained, a payload made pure ASCII (each
#      non-ASCII character a JSON escape), a stderr flood that does not hold a finished child, a cap
#      kill that terminates the whole tree on BOTH Windows hosts, formatter-off containment of every
#      spelling, and the compatibility wrapper every existing caller still uses;
#   6. the scan payload does not depend on the console code page (review A2-F01 / A2-F02): under a
#      console pinned to code page 437, a non-ASCII file path and data root reach the scan child
#      intact, the same payload as raw UTF-8 does not (the control), and the shipped CLI completes;
#   7. the REAL daemon binds the bytes it consumed, and an interactive request is answered unchanged;
#   8. the shipped CLI with the capture mode full / metadata / off: the same complete SARIF with the
#      real message text, the persistent dogfood log untouched, the privacy default unchanged.
#
# ASCII-only (PS 5.1 Windows-1252 trap); StrictMode-safe. Run via tests/run-tests.ps1.

$script:RtOnWindows = if (Test-Path 'Variable:\IsWindows') { [bool]$IsWindows } else { $true }
$script:RtOnLinux = (Test-Path 'Variable:\IsLinux') -and [bool]$IsLinux
$script:RtOnMacOS = (Test-Path 'Variable:\IsMacOS') -and [bool]$IsMacOS
$script:RtUnsupported = -not ($script:RtOnWindows -or $script:RtOnLinux -or $script:RtOnMacOS)
$script:RtNoTestJson = ($PSVersionTable.PSVersion.Major -lt 6)

BeforeAll {
    $script:RtRepo = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:RtRepo 'scripts/lib/lsp-common.ps1')
    . (Join-Path $script:RtRepo 'scripts/lib/lsp-scan-common.ps1')
    . (Join-Path $script:RtRepo 'scripts/lib/lsp-scan-receipt.ps1')

    function New-RtFixture {
        # A target file plus its snapshot, under $TestDrive.
        param([string]$Name = 'target.ps1', [string]$Text = "function Get-RtTarget {`n    [CmdletBinding()]`n    param([string]`$Name)`n    Write-Output `$Name`n}`n")
        $path = Join-Path $TestDrive $Name
        [System.IO.File]::WriteAllText($path, $Text, (New-Object System.Text.UTF8Encoding($false)))
        $full = [System.IO.Path]::GetFullPath($path)
        return [pscustomobject]@{ Path = $full; Snap = (Read-ScanSourceSnapshot -Path $full) }
    }

    function New-RtReceipt {
        # A receipt from the PRODUCTION producer for $Fixture: a settled PSScriptAnalyzer pass over its
        # bytes, under $RequestId, unless the parameters say otherwise.
        param(
            $Fixture,
            [string]$RequestId,
            [string]$Status = 'ok',
            [string]$Pass = 'pssa',
            [bool]$Settled = $true,
            [bool]$Pssa = $true,
            [int]$Omitted = 0,
            [bool]$ScopeApplied = $false,
            [string]$FormatMode = 'off',
            [object[]]$Records = @(),
            [string]$EnginePses = '4.6.0',
            [string]$EnginePssa = '1.25.0',
            [switch]$NoSource
        )
        $engine = [ordered]@{ pses = $EnginePses; pssa = $EnginePssa; source = 'module-manifest'; daemonPlugin = '9.9.9'; daemonHost = 'Core 7.6.6'; psesHost = 'pwsh' }
        $snap = if ($NoSource) { $null } else { $Fixture.Snap }
        $binding = New-ScanAnalysisBinding -RequestId $RequestId -AnalyzedPath $Fixture.Path -Snapshot $snap -Settled $Settled -PssaAvailable $Pssa -Engine $engine
        return (New-ScanReceipt -RequestId $RequestId -File $Fixture.Path -Pass $Pass -Status $Status -Binding $binding `
                -Omitted $Omitted -ScopeApplied $ScopeApplied -Records $Records -FormatMode $FormatMode -ClientSource $Fixture.Snap)
    }

    function Test-RtReceipt {
        # Write $Receipt (or raw $Text) to a fresh path and validate it as the scanner would, with the
        # fixture's bytes before and after unless overridden. $Text is deliberately UNTYPED: a [string]
        # parameter turns $null into '', which would write an empty receipt for every case.
        param($Fixture, [string]$RequestId, $Receipt = $null, $Text = $null, $Pre = 'same', $Post = 'same',
            $Child = $null, [object[]]$Records = @())
        $dir = Join-Path $TestDrive ('rcpt-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $path = Join-Path $dir ($RequestId + '.json')
        if ($null -ne $Text) { [System.IO.File]::WriteAllText($path, $Text) }
        elseif ($null -ne $Receipt) { [System.IO.File]::WriteAllText($path, ($Receipt | ConvertTo-Json -Depth 8 -Compress)) }
        $preSnap = if ($Pre -is [string] -and $Pre -eq 'same') { $Fixture.Snap } else { $Pre }
        $postSnap = if ($Post -is [string] -and $Post -eq 'same') { $Fixture.Snap } else { $Post }
        if ($null -eq $Child) { $Child = [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = ''; Killed = $false; Exited = $true } }
        return (Test-ScanReceipt -Path $path -RequestId $RequestId -FilePath $Fixture.Path -PreSnapshot $preSnap `
                -PostSnapshot $postSnap -Child $Child -Records $Records)
    }

    function Get-RtContractTokens {
        # The four frozen tokens, read from CONTRACT.md's drift-guarded table (the same block the
        # contract drift guard pins to the banner functions).
        $text = [System.IO.File]::ReadAllText((Join-Path $script:RtRepo 'CONTRACT.md'))
        $m = [regex]::Match($text, '(?s)FROZEN-STATUS-TOKENS:BEGIN.*?-->(.*?)<!-- FROZEN-STATUS-TOKENS:END')
        if (-not $m.Success) { return @() }
        return @([regex]::Matches($m.Groups[1].Value, '(?m)^\|\s*`([a-z]+)`\s*\|') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
    }
}

Describe 'Scan receipt vocabulary and the status/completeness table (dispatch 000304 A2)' {

    It 'a receipt status is one of exactly the four public tokens CONTRACT.md freezes -- no new token' {
        $contract = @(Get-RtContractTokens)
        $contract.Count | Should -Be 4 -Because 'the contract table must be found and read'
        (@(Get-ScanReceiptStatusTokens | Sort-Object) -join ',') | Should -BeExactly ($contract -join ',')
    }

    It 'every reason code carries a ceiling, an origin and a meaning' {
        $table = Get-ScanReceiptReasonTable
        @($table.Keys).Count | Should -BeGreaterThan 25
        foreach ($k in @($table.Keys)) {
            [string]$k | Should -Match '^[a-z][a-z-]*[a-z]$'
            @('complete', 'partial', 'failed') | Should -Contain ([string]$table[$k].Ceiling) -Because $k
            @('scanner', 'client', 'daemon') | Should -Contain ([string]$table[$k].Origin) -Because $k
            [string]$table[$k].Meaning | Should -Not -BeNullOrEmpty -Because $k
        }
    }

    It 'the dispatch''s enumerated failure classes each have a code that can only fail the file' {
        foreach ($code in @('child-silent-exit', 'child-nonzero-exit', 'child-stderr-only', 'receipt-malformed', 'receipt-truncated',
                'receipt-missing', 'daemon-refused', 'deadline-kill', 'source-vanished', 'source-changed', 'correlation-mismatch')) {
            (Get-ScanReasonCeiling -Reason $code) | Should -BeExactly 'failed' -Because $code
        }
    }

    It 'completeness is the lowest ceiling among the reasons, complete when there are none' {
        (Get-ScanCompletenessFromReasons -Reasons @()) | Should -BeExactly 'complete'
        (Get-ScanCompletenessFromReasons -Reasons @('cache-hit')) | Should -BeExactly 'complete'
        (Get-ScanCompletenessFromReasons -Reasons @('cache-hit', 'parse-errors')) | Should -BeExactly 'partial'
        (Get-ScanCompletenessFromReasons -Reasons @('parse-errors', 'receipt-missing')) | Should -BeExactly 'failed'
    }

    It 'an unknown reason code can only lower a verdict' {
        (Get-ScanReasonCeiling -Reason 'something-nobody-defined') | Should -BeExactly 'failed'
    }

    It 'THE TABLE: status <Status> with a bound, settled pass -> completeness <Completeness>, analyzed=<Analyzed>' -TestCases @(
        @{ Status = 'ok'; Settled = $true; Pssa = $true; NoSource = $false; Completeness = 'complete'; Analyzed = $true; Reason = '' }
        @{ Status = 'degraded'; Settled = $true; Pssa = $false; NoSource = $false; Completeness = 'partial'; Analyzed = $false; Reason = 'pssa-unavailable' }
        @{ Status = 'incomplete'; Settled = $false; Pssa = $true; NoSource = $false; Completeness = 'failed'; Analyzed = $false; Reason = 'analysis-not-settled' }
        @{ Status = 'unavailable'; Settled = $false; Pssa = $true; NoSource = $true; Completeness = 'failed'; Analyzed = $false; Reason = 'engine-unavailable' }
    ) {
        param($Status, $Settled, $Pssa, $NoSource, $Completeness, $Analyzed, $Reason)
        $f = New-RtFixture
        $rid = New-ScanRequestId
        $r = New-RtReceipt -Fixture $f -RequestId $rid -Status $Status -Settled $Settled -Pssa $Pssa -NoSource:$NoSource
        [string]$r['completeness'] | Should -BeExactly $Completeness -Because 'the producer derives it from the facts'
        $v = Test-RtReceipt -Fixture $f -RequestId $rid -Receipt $r
        [string]$v.Completeness | Should -BeExactly $Completeness
        ($v.Completeness -eq 'complete') | Should -Be $Analyzed
        [string]$v.Status | Should -BeExactly $Status -Because 'the public token passes through unchanged'
        if ($Reason -ne '') { @($v.Reasons) | Should -Contain $Reason }
        @($v.Reasons) | Should -Not -Contain 'receipt-inconsistent' -Because 'an honestly produced receipt is consistent with its own facts'
    }

    It 'an honestly produced receipt with SEVERAL reasons round-trips consistent, each reason its own element' {
        # Regression guard (found by this dispatch's first run): reading the reasons array back through
        # a wrapped @(...) nested it and stringified the whole list into ONE element, so every honest
        # multi-reason receipt was refused as receipt-inconsistent.
        $f = New-RtFixture
        $rid = New-ScanRequestId
        $r = New-RtReceipt -Fixture $f -RequestId $rid -Status 'unavailable' -Settled $false -NoSource
        @($r['reasons']).Count | Should -BeGreaterThan 2
        $v = Test-RtReceipt -Fixture $f -RequestId $rid -Receipt $r
        @($v.Reasons) | Should -Not -Contain 'receipt-inconsistent'
        foreach ($x in @($v.Reasons)) { [string]$x | Should -Not -Match '\s' -Because 'a reason code is one token' }
        foreach ($x in @($r['reasons'])) { @($v.Reasons) | Should -Contain ([string]$x) }
    }

    It 'a short-circuit pass (<Pass>) is partial with its findings, never complete' -TestCases @(
        @{ Pass = 'parser'; Reason = 'parse-errors' }
        @{ Pass = 'pre-pssa'; Reason = 'pre-pssa-short-circuit' }
    ) {
        param($Pass, $Reason)
        $f = New-RtFixture
        $rid = New-ScanRequestId
        $rec = @{ line = 1; col = 1; ruleId = 'MissingEndCurlyBrace'; source = 'parser'; severity = 'Error'; message = 'Missing closing brace.' }
        $r = New-ScanReceipt -RequestId $rid -File $f.Path -Pass $Pass -Status 'ok' -ClientSource $f.Snap -Records @($rec) -FormatMode 'off'
        [string]$r['completeness'] | Should -BeExactly 'partial'
        [string]$r['source']['boundary'] | Should -BeExactly 'client'
        $v = Test-RtReceipt -Fixture $f -RequestId $rid -Receipt $r -Records @([pscustomobject]$rec)
        [string]$v.Completeness | Should -BeExactly 'partial'
        @($v.Reasons) | Should -Contain $Reason
    }
}

Describe 'Scan receipt producer and validator agree; valid-envelope negative controls cannot certify (dispatch 000304 A2)' {

    It 'THE CONTROL: a bound, settled, clean pass validates COMPLETE with the source bound' {
        $f = New-RtFixture
        $rid = New-ScanRequestId
        $v = Test-RtReceipt -Fixture $f -RequestId $rid -Receipt (New-RtReceipt -Fixture $f -RequestId $rid)
        [string]$v.Completeness | Should -BeExactly 'complete'
        $v.Valid | Should -BeTrue
        ($v.Reasons -join ',') | Should -BeExactly ''
        [string]$v.Certification.Source | Should -BeExactly 'bound'
        [string]$v.Certification.Engine | Should -BeExactly 'observed'
    }

    It 'the control with findings: the digest binds exactly the records read back' {
        $f = New-RtFixture
        $rid = New-ScanRequestId
        $rec = @{ line = 1; col = 10; ruleId = 'PSUseApprovedVerbs'; source = 'PSScriptAnalyzer'; severity = 'Warning'; message = 'unapproved verb' }
        $r = New-RtReceipt -Fixture $f -RequestId $rid -Records @($rec)
        $readBack = [pscustomobject]@{ file = $f.Path; ruleId = 'PSUseApprovedVerbs'; source = 'PSScriptAnalyzer'; severity = 'Warning'; line = 1; col = 10; message = 'unapproved verb' }
        (Test-RtReceipt -Fixture $f -RequestId $rid -Receipt $r -Records @($readBack)).Completeness | Should -BeExactly 'complete'
    }

    It 'NEGATIVE CONTROL <Name> -- valid envelope, NOT complete (<Reason>)' -TestCases @(
        @{ Name = 'per-file cap omitted a finding'; Reason = 'diagnostics-capped'; Mutate = { param($r) }; Build = @{ Omitted = 1 } }
        @{ Name = 'findings scoped to an edit range'; Reason = 'diagnostics-scoped'; Mutate = { param($r) }; Build = @{ ScopeApplied = $true } }
        @{ Name = 'format-on-edit was not off'; Reason = 'formatter-active'; Mutate = { param($r) }; Build = @{ FormatMode = 'suggest' } }
        @{ Name = 'no daemon-consumed source identity'; Reason = 'source-unbound'; Mutate = { param($r) }; Build = @{ NoSource = $true } }
        @{ Name = 'degraded rewritten to claim complete'; Reason = 'receipt-inconsistent'; Mutate = { param($r) $r['completeness'] = 'complete'; $r['reasons'] = @() }; Build = @{ Status = 'degraded'; Pssa = $false } }
        @{ Name = 'declared reasons omit one the facts imply'; Reason = 'receipt-inconsistent'; Mutate = { param($r) $r['reasons'] = @() }; Build = @{ Status = 'degraded'; Pssa = $false } }
        @{ Name = 'parser-only rewritten to claim complete'; Reason = 'receipt-inconsistent'; Mutate = { param($r) $r['pass'] = 'parser'; $r['completeness'] = 'complete' }; Build = @{} }
        @{ Name = 'answers another request id'; Reason = 'correlation-mismatch'; Mutate = { param($r) $r['requestId'] = [guid]::NewGuid().ToString('N') }; Build = @{} }
        @{ Name = 'daemon echoed another request id'; Reason = 'correlation-mismatch'; Mutate = { param($r) $r['daemon']['requestId'] = [guid]::NewGuid().ToString('N'); $r['reasons'] = @('correlation-mismatch'); $r['completeness'] = 'failed' }; Build = @{} }
        @{ Name = 'daemon echoed no request id'; Reason = 'correlation-missing'; Mutate = { param($r) $r['daemon']['requestId'] = ''; $r['reasons'] = @('correlation-missing'); $r['completeness'] = 'failed' }; Build = @{} }
        @{ Name = 'names another file'; Reason = 'path-mismatch'; Mutate = { param($r) $r['file'] = [string]$r['file'] + '.other.ps1' }; Build = @{} }
        @{ Name = 'daemon analyzed another path'; Reason = 'path-mismatch'; Mutate = { param($r) $r['daemon']['path'] = 'C:/elsewhere.ps1'; $r['reasons'] = @('path-mismatch'); $r['completeness'] = 'failed' }; Build = @{} }
        @{ Name = 'binds bytes other than the ones on disk'; Reason = 'source-mismatch'; Mutate = { param($r) $r['source']['sha256'] = ('0' * 64) }; Build = @{} }
        @{ Name = 'vouches for a finding nobody recorded'; Reason = 'diagnostics-mismatch'; Mutate = { param($r) $r['diagnostics'] = (Get-ScanDiagnosticsDigest -Records @(@{ line = 1; col = 1; ruleId = 'X'; source = 'Y'; severity = 'Warning'; message = 'phantom' })) }; Build = @{} }
    ) {
        param($Name, $Reason, $Mutate, $Build)
        $f = New-RtFixture
        $rid = New-ScanRequestId
        $r = New-RtReceipt -Fixture $f -RequestId $rid @Build
        & $Mutate $r
        @(Get-ScanReceiptShapeProblems -Receipt (($r | ConvertTo-Json -Depth 8 -Compress) | ConvertFrom-Json)).Count | Should -Be 0 -Because ('the envelope of "' + $Name + '" must be valid -- envelope validity alone certifies nothing')
        $v = Test-RtReceipt -Fixture $f -RequestId $rid -Receipt $r
        [string]$v.Completeness | Should -Not -BeExactly 'complete' -Because $Name
        @($v.Reasons) | Should -Contain $Reason
    }

    It 'a source that changed between the scanner''s before and after reads is not complete (source-changed)' {
        $f = New-RtFixture
        $rid = New-ScanRequestId
        $other = New-RtFixture -Name 'other.ps1' -Text "# not the same bytes`n"
        $v = Test-RtReceipt -Fixture $f -RequestId $rid -Receipt (New-RtReceipt -Fixture $f -RequestId $rid) -Post $other.Snap
        [string]$v.Completeness | Should -BeExactly 'failed'
        @($v.Reasons) | Should -Contain 'source-changed'
        [string]$v.Certification.Source | Should -BeExactly 'changed'
    }

    It 'a source that vanished during the scan is not complete (source-vanished)' {
        $f = New-RtFixture
        $rid = New-ScanRequestId
        $gone = Read-ScanSourceSnapshot -Path (Join-Path $TestDrive 'never-existed.ps1')
        $v = Test-RtReceipt -Fixture $f -RequestId $rid -Receipt (New-RtReceipt -Fixture $f -RequestId $rid) -Post $gone
        @($v.Reasons) | Should -Contain 'source-vanished'
        [string]$v.Completeness | Should -BeExactly 'failed'
    }

    It 'a receipt the scanner cannot tie to bytes it read itself is not complete, however clean it looks' {
        $f = New-RtFixture
        $rid = New-ScanRequestId
        $v = Test-RtReceipt -Fixture $f -RequestId $rid -Receipt (New-RtReceipt -Fixture $f -RequestId $rid) -Pre $null -Post $null
        [string]$v.Completeness | Should -BeExactly 'failed'
        @($v.Reasons) | Should -Contain 'source-unbound'
    }

    It 'a receipt whose finding has a different message does not match the record read back (digest covers the message)' {
        $f = New-RtFixture
        $rid = New-ScanRequestId
        $rec = @{ line = 1; col = 10; ruleId = 'PSUseApprovedVerbs'; source = 'PSScriptAnalyzer'; severity = 'Warning'; message = 'the real message' }
        $r = New-RtReceipt -Fixture $f -RequestId $rid -Records @($rec)
        # A metadata-mode capture row drops `message`: the scanner would read back the same rule, line
        # and column with an empty message. That must NOT pass as the same finding set.
        $readBack = [pscustomobject]@{ ruleId = 'PSUseApprovedVerbs'; source = 'PSScriptAnalyzer'; severity = 'Warning'; line = 1; col = 10; message = '' }
        $v = Test-RtReceipt -Fixture $f -RequestId $rid -Receipt $r -Records @($readBack)
        @($v.Reasons) | Should -Contain 'diagnostics-mismatch'
    }

    It 'STRUCTURAL NEGATIVE CONTROL <Name> -- refused as <Reason>' -TestCases @(
        @{ Name = 'truncated mid-object'; Reason = 'receipt-truncated'; Text = '{"schema":"powershell-lsp/scan-receipt","schemaVersion":1,"requestId":"' }
        @{ Name = 'empty file'; Reason = 'receipt-truncated'; Text = '' }
        @{ Name = 'not JSON'; Reason = 'receipt-malformed'; Text = 'this is not a receipt' }
        @{ Name = 'a JSON array'; Reason = 'receipt-malformed'; Text = '[1,2,3]' }
    ) {
        param($Name, $Reason, $Text)
        $f = New-RtFixture
        $rid = New-ScanRequestId
        $v = Test-RtReceipt -Fixture $f -RequestId $rid -Text $Text
        @($v.Reasons) | Should -Contain $Reason
        [string]$v.Completeness | Should -BeExactly 'failed'
        $v.Valid | Should -BeFalse
    }

    It 'SHAPE NEGATIVE CONTROL <Name> -- receipt-malformed' -TestCases @(
        @{ Name = 'a field is missing'; Mutate = { param($r) $r.Remove('diagnostics') } }
        @{ Name = 'a status that is not a public token'; Mutate = { param($r) $r['status'] = 'mostly-ok' } }
        @{ Name = 'an unknown reason code'; Mutate = { param($r) $r['reasons'] = @('trust-me') } }
        @{ Name = 'a policy claimed verified'; Mutate = { param($r) $r['policy'] = [ordered]@{ state = 'verified' } } }
        @{ Name = 'a configuration claimed bound'; Mutate = { param($r) $r['config'] = [ordered]@{ state = 'bound'; observed = $null } } }
        @{ Name = 'a future schema version'; Mutate = { param($r) $r['schemaVersion'] = 2 } }
        @{ Name = 'a source digest that is not a SHA-256'; Mutate = { param($r) $r['source']['sha256'] = 'abc' } }
        @{ Name = 'reasons that are not an array'; Mutate = { param($r) $r['reasons'] = 'cache-hit' } }
        @{ Name = 'an engine version left empty instead of unknown'; Mutate = { param($r) $r['engine']['pses'] = '' } }
    ) {
        param($Name, $Mutate)
        $f = New-RtFixture
        $rid = New-ScanRequestId
        $r = New-RtReceipt -Fixture $f -RequestId $rid
        & $Mutate $r
        $v = Test-RtReceipt -Fixture $f -RequestId $rid -Receipt $r
        @($v.Reasons) | Should -Contain 'receipt-malformed'
        [string]$v.Completeness | Should -BeExactly 'failed'
        @($v.Problems).Count | Should -BeGreaterThan 0 -Because 'a refusal names its problem'
    }

    It 'the child facts decide too: <Name> -> <Reason>' -TestCases @(
        @{ Name = 'a valid receipt, then a nonzero exit'; Reason = 'child-nonzero-exit'; Child = [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = ''; Killed = $false; Exited = $true }; Receipt = $true }
        @{ Name = 'a cap kill'; Reason = 'deadline-kill'; Child = [pscustomobject]@{ ExitCode = $null; StdOut = ''; StdErr = ''; Killed = $true; Exited = $true }; Receipt = $false }
        @{ Name = 'a cap kill that did not take'; Reason = 'kill-unverified'; Child = [pscustomobject]@{ ExitCode = $null; StdOut = ''; StdErr = ''; Killed = $true; Exited = $false }; Receipt = $false }
        @{ Name = 'a silent exit 0 without a receipt'; Reason = 'child-silent-exit'; Child = [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = ''; Killed = $false; Exited = $true }; Receipt = $false }
        @{ Name = 'a stderr-only exit 0 without a receipt'; Reason = 'child-stderr-only'; Child = [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = 'boom'; Killed = $false; Exited = $true }; Receipt = $false }
    ) {
        param($Name, $Reason, $Child, $Receipt)
        $f = New-RtFixture
        $rid = New-ScanRequestId
        $r = if ($Receipt) { New-RtReceipt -Fixture $f -RequestId $rid } else { $null }
        $v = Test-RtReceipt -Fixture $f -RequestId $rid -Receipt $r -Child $Child
        @($v.Reasons) | Should -Contain $Reason
        [string]$v.Completeness | Should -BeExactly 'failed'
        if (-not $Receipt) { @($v.Reasons) | Should -Contain 'receipt-missing' }
    }

    It 'unknown engine versions are reported unknown -- the analysis can complete, but nothing is certified as known or verified' {
        $f = New-RtFixture
        $rid = New-ScanRequestId
        $v = Test-RtReceipt -Fixture $f -RequestId $rid -Receipt (New-RtReceipt -Fixture $f -RequestId $rid -EnginePses 'unknown' -EnginePssa 'unknown')
        [string]$v.Completeness | Should -BeExactly 'complete'
        [string]$v.Certification.Engine | Should -BeExactly 'unknown'
        [string]$v.Certification.Config | Should -BeExactly 'unbound'
        [string]$v.Certification.Policy | Should -BeExactly 'unbound'
    }

    It 'the producer refuses to claim more than its facts: an unknown status degrades to incomplete, an unknown pass to none' {
        $f = New-RtFixture
        $rid = New-ScanRequestId
        $r = New-ScanReceipt -RequestId $rid -File $f.Path -Pass 'magic' -Status 'great'
        [string]$r['pass'] | Should -BeExactly 'none'
        [string]$r['status'] | Should -BeExactly 'incomplete'
        [string]$r['completeness'] | Should -BeExactly 'failed'
        @($r['reasons']) | Should -Contain 'analysis-not-run'
    }
}

Describe 'docs/scan-receipt.schema.json and the in-code shape check are one contract (dispatch 000304 A2)' {

    BeforeAll {
        $script:RtSchemaPath = Join-Path $script:RtRepo 'docs/scan-receipt.schema.json'
        $script:RtSchemaText = [System.IO.File]::ReadAllText($script:RtSchemaPath)
        $script:RtSchema = $script:RtSchemaText | ConvertFrom-Json
    }

    It 'the schema enums are exactly the code vocabularies (status, completeness, pass, reasons)' {
        (@($script:RtSchema.properties.status.enum | Sort-Object) -join ',') | Should -BeExactly (@(Get-ScanReceiptStatusTokens | Sort-Object) -join ',')
        (@($script:RtSchema.properties.completeness.enum | Sort-Object) -join ',') | Should -BeExactly 'complete,failed,partial'
        (@($script:RtSchema.properties.pass.enum | Sort-Object) -join ',') | Should -BeExactly (@(Get-ScanReceiptPasses | Sort-Object) -join ',')
        (@($script:RtSchema.properties.reasons.items.enum | Sort-Object) -join ',') | Should -BeExactly (@((Get-ScanReceiptReasonTable).Keys | Sort-Object) -join ',')
        [string]$script:RtSchema.properties.schema.const | Should -BeExactly ([string](Get-ScanReceiptSchema).Id)
        [int]$script:RtSchema.properties.schemaVersion.const | Should -Be ([int](Get-ScanReceiptSchema).Version)
        [string]$script:RtSchema.properties.policy.properties.state.const | Should -BeExactly 'unbound'
        [string]$script:RtSchema.properties.config.properties.state.const | Should -BeExactly 'unbound'
    }

    It 'every receipt the producer writes validates against the schema (<Label>)' -Skip:$script:RtNoTestJson -TestCases @(
        @{ Label = 'complete'; Status = 'ok'; Pass = 'pssa' }
        @{ Label = 'degraded'; Status = 'degraded'; Pass = 'pssa' }
        @{ Label = 'parser short-circuit'; Status = 'ok'; Pass = 'parser' }
        @{ Label = 'no analysis'; Status = 'incomplete'; Pass = 'none' }
    ) {
        param($Label, $Status, $Pass)
        $f = New-RtFixture
        $rid = New-ScanRequestId
        $r = if ($Pass -eq 'pssa') { New-RtReceipt -Fixture $f -RequestId $rid -Status $Status -Pssa ($Status -ne 'degraded') }
        else { New-ScanReceipt -RequestId $rid -File $f.Path -Pass $Pass -Status $Status -ClientSource $f.Snap -Reasons @('daemon-refused') }
        $json = $r | ConvertTo-Json -Depth 8 -Compress
        (Test-Json -Json $json -Schema $script:RtSchemaText -ErrorAction SilentlyContinue) | Should -BeTrue -Because $Label
        @(Get-ScanReceiptShapeProblems -Receipt ($json | ConvertFrom-Json)).Count | Should -Be 0
    }

    It 'the schema and the shape check both refuse <Name>' -Skip:$script:RtNoTestJson -TestCases @(
        @{ Name = 'a missing field'; Mutate = { param($r) $r.Remove('engine') } }
        @{ Name = 'a status that is not a public token'; Mutate = { param($r) $r['status'] = 'fine' } }
        @{ Name = 'an unknown reason'; Mutate = { param($r) $r['reasons'] = @('trust-me') } }
        @{ Name = 'a verified policy'; Mutate = { param($r) $r['policy'] = [ordered]@{ state = 'verified' } } }
        @{ Name = 'a bound configuration'; Mutate = { param($r) $r['config'] = [ordered]@{ state = 'bound'; observed = $null } } }
        @{ Name = 'a short source digest'; Mutate = { param($r) $r['source']['sha256'] = 'abc' } }
        @{ Name = 'schema version 2'; Mutate = { param($r) $r['schemaVersion'] = 2 } }
        @{ Name = 'an upper-case request id'; Mutate = { param($r) $r['requestId'] = ([string]$r['requestId']).ToUpperInvariant() } }
    ) {
        param($Name, $Mutate)
        $f = New-RtFixture
        $rid = New-ScanRequestId
        $r = New-RtReceipt -Fixture $f -RequestId $rid
        & $Mutate $r
        $json = $r | ConvertTo-Json -Depth 8 -Compress
        (Test-Json -Json $json -Schema $script:RtSchemaText -ErrorAction SilentlyContinue) | Should -BeFalse -Because ('the schema must refuse ' + $Name)
        @(Get-ScanReceiptShapeProblems -Receipt ($json | ConvertFrom-Json)).Count | Should -BeGreaterThan 0 -Because ('the shape check must refuse ' + $Name)
    }
}

Describe 'Scan source identity, digests and the request context (dispatch 000304 A2)' {

    It 'the source identity is the SHA-256 of the RAW bytes (a BOM and CRLF file), and the text is what ReadAllText reads' {
        $path = Join-Path $TestDrive 'bom-crlf.ps1'
        $bytes = [byte[]](@(0xEF, 0xBB, 0xBF) + [System.Text.Encoding]::UTF8.GetBytes("function Get-Bom {`r`n    'caf' + [char]0x00E9`r`n}`r`n"))
        [System.IO.File]::WriteAllBytes($path, $bytes)
        $s = Read-ScanSourceSnapshot -Path $path
        $s.Exists | Should -BeTrue
        [string]$s.Sha256 | Should -BeExactly ([string](Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash).ToLowerInvariant()
        [int]$s.Length | Should -Be $bytes.Length
        [string]$s.Text | Should -BeExactly ([System.IO.File]::ReadAllText($path))
        $textHash = Get-Sha256HexFromBytes -Bytes ([System.Text.Encoding]::UTF8.GetBytes([string]$s.Text))
        [string]$s.Sha256 | Should -Not -BeExactly $textHash -Because 'the identity is of the bytes, not of the decoded text'
    }

    It 'a missing file snapshots as not existing, with the reason, and never throws' {
        $s = Read-ScanSourceSnapshot -Path (Join-Path $TestDrive 'nope.ps1')
        $s.Exists | Should -BeFalse
        [string]$s.Error | Should -Not -BeNullOrEmpty
    }

    It 'the diagnostics digest is order-free but counts duplicates and covers every field' {
        $a = @{ line = 1; col = 2; ruleId = 'R1'; source = 'S'; severity = 'Warning'; message = 'm1' }
        $b = @{ line = 3; col = 4; ruleId = 'R2'; source = 'S'; severity = 'Error'; message = 'm2' }
        $d1 = Get-ScanDiagnosticsDigest -Records @($a, $b)
        $d2 = Get-ScanDiagnosticsDigest -Records @($b, $a)
        [string]$d1.digest | Should -BeExactly ([string]$d2.digest) -Because 'order-free'
        [int]$d1.count | Should -Be 2
        $dup = Get-ScanDiagnosticsDigest -Records @($a, $a, $b)
        [int]$dup.count | Should -Be 3
        [string]$dup.digest | Should -Not -BeExactly ([string]$d1.digest) -Because 'a duplicate is a different finding set'
        foreach ($k in @('line', 'col', 'ruleId', 'source', 'severity', 'message')) {
            $c = @{} + $a
            $c[$k] = $(if ($k -eq 'line' -or $k -eq 'col') { 99 } else { 'changed' })
            [string](Get-ScanDiagnosticsDigest -Records @($c, $b)).digest | Should -Not -BeExactly ([string]$d1.digest) -Because ('the digest covers ' + $k)
        }
        [int](Get-ScanDiagnosticsDigest -Records @()).count | Should -Be 0
    }

    It 'an interactive hook payload carries no scan context; only a well-formed scan field does' {
        $interactive = '{"session_id":"s","tool_input":{"file_path":"C:/x.ps1"},"cwd":"C:/"}' | ConvertFrom-Json
        (Get-ScanRequestContext -Payload $interactive) | Should -BeNullOrEmpty
        $abs = Join-Path $TestDrive 'r.json'
        $good = ([ordered]@{ session_id = 's'; powershell_lsp_scan = (New-ScanRequestField -RequestId ('a' * 32) -ReceiptPath $abs) } | ConvertTo-Json -Depth 4) | ConvertFrom-Json
        $ctx = Get-ScanRequestContext -Payload $good
        [string]$ctx.RequestId | Should -BeExactly ('a' * 32)
        [string]$ctx.ReceiptPath | Should -BeExactly $abs
        $badId = ([ordered]@{ powershell_lsp_scan = @{ request_id = 'not-hex'; receipt_path = $abs } } | ConvertTo-Json -Depth 4) | ConvertFrom-Json
        (Get-ScanRequestContext -Payload $badId) | Should -BeNullOrEmpty
        $relPath = ([ordered]@{ powershell_lsp_scan = @{ request_id = ('b' * 32); receipt_path = 'relative/r.json' } } | ConvertTo-Json -Depth 4) | ConvertFrom-Json
        (Get-ScanRequestContext -Payload $relPath) | Should -BeNullOrEmpty
    }

    It 'a receipt is written atomically, never over an existing file, and only to an absolute path in an existing directory' {
        $f = New-RtFixture
        $rid = New-ScanRequestId
        $r = New-RtReceipt -Fixture $f -RequestId $rid
        $dir = Join-Path $TestDrive 'w'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $p = Join-Path $dir ($rid + '.json')
        (Write-ScanReceipt -Path $p -Receipt $r) | Should -BeTrue
        ([System.IO.File]::ReadAllText($p) | ConvertFrom-Json).requestId | Should -BeExactly $rid
        (Write-ScanReceipt -Path $p -Receipt $r) | Should -BeFalse -Because 'never overwrite'
        (Write-ScanReceipt -Path 'relative.json' -Receipt $r) | Should -BeFalse
        (Write-ScanReceipt -Path (Join-Path $TestDrive 'no-such-dir/x.json') -Receipt $r) | Should -BeFalse
        @(Get-ChildItem -LiteralPath $dir -File -Filter '*.tmp').Count | Should -Be 0 -Because 'no temp file is left behind'
    }
}

Describe 'The typed scan spawner (dispatch 000304 A2)' -Skip:$script:RtUnsupported {

    BeforeAll {
        $script:RtHost = Resolve-PsHost 'pwsh'
        $script:RtKids = Join-Path $TestDrive 'kids'
        New-Item -ItemType Directory -Force -Path $script:RtKids | Out-Null
        function New-RtKid {
            param([string]$Name, [string[]]$Lines)
            $p = Join-Path $script:RtKids $Name
            Set-Content -LiteralPath $p -Encoding ascii -Value $Lines
            return $p
        }
        $script:RtEcho = New-RtKid -Name 'echo.ps1' -Lines @(
            '. (Join-Path $env:RT_LIB ''lsp-common.ps1'')'
            '$in = Get-StdinText'
            '[Console]::Out.Write(''OUT:'' + $in)'
            '[Console]::Error.Write(''ERR:stderr text'')'
            'exit 3')
        $script:RtFlood = New-RtKid -Name 'flood.ps1' -Lines @(
            '$null = [Console]::In.ReadToEnd()'
            '$line = ''y'' * 1023'
            'for ($i = 0; $i -lt 2048; $i++) { [Console]::Error.WriteLine($line) }'
            'exit 0')
        $script:RtTree = New-RtKid -Name 'tree.ps1' -Lines @(
            '$null = [Console]::In.ReadToEnd()'
            '$gk = Join-Path $env:RT_DIR ''grandchild.ps1'''
            'Set-Content -LiteralPath $gk -Encoding ascii -Value @(''[System.IO.File]::WriteAllText((Join-Path $env:RT_DIR ''''grandchild.pid''''), [string]$PID)'', ''$ev = New-Object System.Threading.ManualResetEventSlim($false)'', ''[void]$ev.Wait()'')'
            '$hostExe = (Get-Process -Id $PID).Path'
            '$psi = New-Object System.Diagnostics.ProcessStartInfo'
            '$psi.FileName = $hostExe; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true'
            '$psi.Arguments = ''-NoLogo -NoProfile -ExecutionPolicy Bypass -File "'' + $gk + ''"'''
            '[void][System.Diagnostics.Process]::Start($psi)'
            '[System.IO.File]::WriteAllText((Join-Path $env:RT_DIR ''child.pid''), [string]$PID)'
            '$ev = New-Object System.Threading.ManualResetEventSlim($false)'
            '[void]$ev.Wait()')
        $script:RtEnv = New-RtKid -Name 'env.ps1' -Lines @(
            '$null = [Console]::In.ReadToEnd()'
            '$names = @([System.Environment]::GetEnvironmentVariables().GetEnumerator() | Where-Object { ([string]$_.Key).StartsWith(''CLAUDE_PLUGIN_OPTION_'', [System.StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { [string]$_.Key + ''='' + [string]$_.Value } | Sort-Object)'
            '[Console]::Out.Write(($names -join '';''))'
            'exit 0')

        function Wait-RtPidGone {
            param([int]$TargetPid, [int]$TimeoutMs = 10000)
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
                if ($null -eq (Get-Process -Id $TargetPid -ErrorAction SilentlyContinue)) { return $true }
                Start-Sleep -Milliseconds 100
            }
            return $false
        }
    }

    It 'returns a typed record: the exit code, stdout and stderr, both drained, and the stdin payload delivered' {
        $r = Invoke-ScanChildProcess -HostExe $script:RtHost -ScriptPath $script:RtEcho -StdinJson '{"x":1}' -CapMs 60000 `
            -ExtraEnv @{ RT_LIB = (Join-Path $script:RtRepo 'scripts/lib') }
        [int]$r.ExitCode | Should -Be 3
        [string]$r.StdOut | Should -BeExactly 'OUT:{"x":1}'
        [string]$r.StdErr | Should -BeExactly 'ERR:stderr text'
        $r.Killed | Should -BeFalse
        $r.Exited | Should -BeTrue
        $r.StdOutComplete | Should -BeTrue
        $r.StdErrComplete | Should -BeTrue
        [string]$r.StdinError | Should -BeExactly ''
    }

    It 'the payload is pure ASCII: each non-ASCII character is a JSON escape that parses back to the same character (review A2-F01)' {
        # The pure half of the code-page fix; the console half is the pinned-console Describe below.
        $e = [string][char]0x00E9
        $cjk = [string][char]0x65E5 + [string][char]0x672C
        $astral = [string][char]0xD83D + [string][char]0xDE00   # one character outside the BMP: a surrogate pair
        $want = 'C:\scan\caf' + $e + '-' + $cjk + $astral + '.ps1'
        $json = [ordered]@{ session_id = 'rt-ascii'; tool_input = @{ file_path = $want }; n = 1 } | ConvertTo-Json -Compress -Depth 4
        @([regex]::Matches($json, '[^\x00-\x7F]')).Count | Should -BeGreaterThan 0 -Because 'the input must carry non-ASCII, or this proves nothing'
        $ascii = ConvertTo-ScanAsciiJson -Json $json
        @([regex]::Matches($ascii, '[^\x00-\x7F]')).Count | Should -Be 0
        $bs = [string][char]0x5C
        $ascii | Should -Match ([regex]::Escape('caf' + $bs + 'u00e9-' + $bs + 'u65e5' + $bs + 'u672c' + $bs + 'ud83d' + $bs + 'ude00.ps1'))
        [string]($ascii | ConvertFrom-Json).tool_input.file_path | Should -BeExactly $want
        (ConvertTo-ScanAsciiJson -Json '{"x":"plain"}') | Should -BeExactly '{"x":"plain"}' -Because 'an ASCII payload passes byte for byte'
        (ConvertTo-ScanAsciiJson -Json '') | Should -BeExactly ''
    }

    It 'a child that floods 2 MiB of stderr and exits is not held to the cap' {
        $r = Invoke-ScanChildProcess -HostExe $script:RtHost -ScriptPath $script:RtFlood -CapMs 20000
        $r.Killed | Should -BeFalse -Because 'a drained child finishes on its own'
        [int]$r.ExitCode | Should -Be 0
        [int]$r.ElapsedMs | Should -BeLessThan 15000
        ([string]$r.StdErr).Length | Should -BeGreaterThan 2000000
    }

    It 'a cap kill terminates the WHOLE tree -- child and grandchild -- on this host (<Edition>)' -TestCases @(@{ Edition = [string]$PSVersionTable.PSEdition }) {
        param($Edition)
        $dir = Join-Path $TestDrive ('tree-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $r = Invoke-ScanChildProcess -HostExe $script:RtHost -ScriptPath $script:RtTree -CapMs 8000 -ExtraEnv @{ RT_DIR = $dir }
        $childPid = 0; $grandPid = 0
        try { $childPid = [int]([System.IO.File]::ReadAllText((Join-Path $dir 'child.pid')).Trim()) } catch { }
        try { $grandPid = [int]([System.IO.File]::ReadAllText((Join-Path $dir 'grandchild.pid')).Trim()) } catch { }
        try {
            $childPid | Should -BeGreaterThan 0 -Because 'the child must have started'
            $grandPid | Should -BeGreaterThan 0 -Because 'the grandchild must have started before the cap'
            $r.Killed | Should -BeTrue
            $r.Exited | Should -BeTrue -Because 'the killed child must be gone'
            (Wait-RtPidGone -TargetPid $childPid) | Should -BeTrue -Because 'the child must not outlive the cap kill'
            (Wait-RtPidGone -TargetPid $grandPid) | Should -BeTrue -Because ('the grandchild must die with the tree on ' + $Edition + ' (Kill($true) on .NET Core, taskkill /T on Windows PowerShell 5.1)')
        } finally {
            foreach ($p in @($childPid, $grandPid)) { if ($p -gt 0) { try { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue } catch { } } }
        }
    }

    It 'every scan child gets formatOnEdit=off under exactly one spelling, whatever spellings reached it' {
        $saved = @{}
        foreach ($n in @('CLAUDE_PLUGIN_OPTION_FORMAT_ON_EDIT', 'CLAUDE_PLUGIN_OPTION_formatOnEdit', 'CLAUDE_PLUGIN_OPTION_format_on_edit')) {
            $saved[$n] = [System.Environment]::GetEnvironmentVariable($n)
        }
        try {
            [System.Environment]::SetEnvironmentVariable('CLAUDE_PLUGIN_OPTION_FORMAT_ON_EDIT', 'apply')
            [System.Environment]::SetEnvironmentVariable('CLAUDE_PLUGIN_OPTION_format_on_edit', 'apply')
            $r = Invoke-ScanChildProcess -HostExe $script:RtHost -ScriptPath $script:RtEnv -CapMs 60000 `
                -ExtraEnv @{ CLAUDE_PLUGIN_OPTION_formatOnEdit = 'suggest'; CLAUDE_PLUGIN_OPTION_profile = 'recommended' }
        } finally {
            foreach ($n in @($saved.Keys)) { [System.Environment]::SetEnvironmentVariable($n, $saved[$n]) }
        }
        $fmt = @(([string]$r.StdOut -split ';') | Where-Object {
                $_ -match '^CLAUDE_PLUGIN_OPTION_' -and ((($_ -split '=')[0].Substring(21) -replace '_', '').ToLowerInvariant() -eq 'formatonedit')
            })
        ($fmt -join ';') | Should -BeExactly 'CLAUDE_PLUGIN_OPTION_formatOnEdit=off'
        [string]$r.StdOut | Should -Match 'CLAUDE_PLUGIN_OPTION_profile=recommended' -Because 'only formatOnEdit is contained here; the rest of the declared environment is A3''s'
    }

    It 'the compatibility wrapper Invoke-ScanHook keeps its contract: stdout text, and '''' plus the Killed flag on a cap kill' {
        $out = Invoke-ScanHook -HostExe $script:RtHost -ScriptPath $script:RtEcho -StdinJson 'hi' -CapMs 60000 -DataRoot $TestDrive `
            -ExtraEnv @{ RT_LIB = (Join-Path $script:RtRepo 'scripts/lib') }
        [string]$out | Should -BeExactly 'OUT:hi'
        $dir = Join-Path $TestDrive ('wrap-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $killed = $false
        try {
            $out2 = Invoke-ScanHook -HostExe $script:RtHost -ScriptPath $script:RtTree -StdinJson '' -CapMs 4000 -DataRoot $TestDrive `
                -ExtraEnv @{ RT_DIR = $dir } -Killed ([ref]$killed)
            [string]$out2 | Should -BeExactly ''
            $killed | Should -BeTrue
        } finally {
            foreach ($pf in @('child.pid', 'grandchild.pid')) {
                $f = Join-Path $dir $pf
                if (Test-Path -LiteralPath $f) { try { Stop-Process -Id ([int]([System.IO.File]::ReadAllText($f).Trim())) -Force -ErrorAction SilentlyContinue } catch { } }
            }
        }
    }

    It 'the scan spawner disposes its process and starts both drains before it waits (structure)' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RtRepo 'scripts/lib/lsp-scan-common.ps1'), [ref]$null, [ref]$null)
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-ScanChildProcess' }, $true)
        $fn | Should -Not -BeNullOrEmpty
        $body = $fn.Extent.Text
        $wait = $body.IndexOf('$p.WaitForExit(')
        $out = $body.IndexOf('$p.StandardOutput.ReadToEndAsync()')
        $err = $body.IndexOf('$p.StandardError.ReadToEndAsync()')
        $wait | Should -BeGreaterThan 0
        $out | Should -BeGreaterThan 0
        $err | Should -BeGreaterThan 0
        $out | Should -BeLessThan $wait
        $err | Should -BeLessThan $wait
        $body | Should -Match 'finally\s*\{\s*try\s*\{\s*\$p\.Dispose\(\)'
        $body | Should -Not -Match '\$psi\.CreateNoWindow' -Because 'a scan child shares the scanner''s console: a Windows PowerShell 5.1 parent on a UTF-8 console writes a BOM that a child on a new console cannot strip'
        $esc = $body.IndexOf('$payload = ConvertTo-ScanAsciiJson -Json $StdinJson')
        $esc | Should -BeGreaterThan 0 -Because 'the payload is made pure ASCII before it is written (review A2-F01)'
        $esc | Should -BeLessThan $body.IndexOf('$p.StandardInput.BaseStream.Write(')
        $body | Should -Match 'GetBytes\(\$payload\)'
        $body | Should -Not -Match 'GetBytes\(\$StdinJson\)' -Because 'the unescaped text must never reach the stream'
        $kill = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Stop-ScanProcessTree' }, $true)
        $kill.Extent.Text | Should -Match 'taskkill\.exe /PID \$Process\.Id /T /F'
    }
}

Describe 'The scan payload does not depend on the console code page (dispatch 000304 A2, review A2-F01 / A2-F02)' -Skip:(-not $script:RtOnWindows) {
    # Windows only: a console code page is a Windows notion. THE DEFECT (A2-F01, measured by the
    # review): a scan child decodes its stdin payload with the code page of the console it inherits,
    # which is the scanner's -- on a stock console the OEM code page (437 on en-US), not UTF-8 -- so a
    # non-ASCII path in the payload arrived mangled, a receipt path under a non-ASCII data root named a
    # directory that does not exist, and every file read receipt-missing (exit 4, where the base exited
    # 0). The guard this replaces (A2-F02) passed only where the runner's own console was UTF-8. Here a
    # stand-in scanner starts on a console of its OWN, pins it to code page 437 whatever the machine's
    # locale, and runs three things there: the production spawner's round trip; the same payload as raw
    # UTF-8 -- what the spawner wrote before the fix, the control that proves the pin bites; and the
    # shipped CLI with the shipped client over a file whose name and data root are non-ASCII. The
    # stand-in runs on THIS host, so the Windows PowerShell 5.1 run tests a 5.1 parent.

    BeforeAll {
        . (Join-Path $PSScriptRoot 'Integration.Common.ps1')
        . (Join-Path $PSScriptRoot 'ScanHarness.Common.ps1')
        $script:CpKidHost = Resolve-PsHost 'pwsh'
        $script:CpRoot = New-SvTempRoot -Tag 'cpin' -MintingFile 'tests/PowerShellLsp.ScanReceipt.Tests.ps1'
        $e = [string][char]0x00E9
        $cjk = [string][char]0x65E5 + [string][char]0x672C
        # Non-ASCII where an account name puts it -- the data root, whose default is under the user
        # profile -- and in the scanned file's own name.
        $script:CpData = Join-Path $script:CpRoot ('dat' + $e + '-' + $cjk)
        New-Item -ItemType Directory -Force -Path $script:CpData | Out-Null
        $src = Join-Path $script:CpRoot 'src'
        New-Item -ItemType Directory -Force -Path $src | Out-Null
        $script:CpFile = Join-Path $src ('caf' + $e + '-' + $cjk + '.ps1')
        [System.IO.File]::WriteAllText($script:CpFile, "function Get-CpTarget {`n    [CmdletBinding()]`n    param([string]`$Name)`n    Write-Output `$Name`n}`n",
            (New-Object System.Text.UTF8Encoding($false)))
        $kids = Join-Path $script:CpRoot 'kids'
        New-Item -ItemType Directory -Force -Path $kids | Out-Null
        # Reads the payload exactly as the real hooks do (Get-StdinText, then ConvertFrom-Json) and reports
        # the code page it decoded with and whether both paths survived. The expected paths travel in the
        # environment block, which is UTF-16 and needs no code page.
        $script:CpProbe = Join-Path $kids 'probe.ps1'
        Set-Content -LiteralPath $script:CpProbe -Encoding ascii -Value @(
            '. (Join-Path $env:CP_LIB ''lsp-common.ps1'')'
            '$cp = [Console]::InputEncoding.CodePage'
            '$raw = Get-StdinText'
            '$verdict = ''PARSE-FAIL'''
            'try {'
            '    $o = $raw | ConvertFrom-Json -ErrorAction Stop'
            '    $okFile = ([string]$o.tool_input.file_path -ceq $env:CP_WANT_FILE)'
            '    $okRcpt = ([string]$o.powershell_lsp_scan.receipt_path -ceq $env:CP_WANT_RCPT)'
            '    $verdict = $(if ($okFile -and $okRcpt) { ''PATH-OK'' } else { ''PATH-MANGLED'' })'
            '} catch { $verdict = ''PARSE-FAIL'' }'
            '[Console]::Out.Write(''cp='' + $cp + '';'' + $verdict)'
            'exit 0')
        # The stand-in SCANNER. Started on a console of its own (the harness spawner's -OwnConsole), it
        # pins that console's code page, then does what the scanner does: spawns children that inherit it.
        $script:CpScanner = Join-Path $kids 'pinned-scanner.ps1'
        Set-Content -LiteralPath $script:CpScanner -Encoding ascii -Value @(
            'param([int]$CodePage, [string]$Lib, [string]$KidHost, [string]$Probe, [string]$Scan, [string]$Out)'
            '$enc = [System.Text.Encoding]::GetEncoding($CodePage)'
            '[Console]::InputEncoding = $enc'
            '[Console]::OutputEncoding = $enc'
            '. (Join-Path $Lib ''lsp-common.ps1'')'
            '. (Join-Path $Lib ''lsp-scan-common.ps1'')'
            '. (Join-Path $Lib ''lsp-scan-receipt.ps1'')'
            '$res = [ordered]@{ pin = [int][Console]::InputEncoding.CodePage }'
            '$req = New-ScanRequestField -RequestId (''a'' * 32) -ReceiptPath $env:CP_WANT_RCPT'
            '$json = [ordered]@{ session_id = ''cp-pin''; tool_input = @{ file_path = $env:CP_WANT_FILE }; cwd = $env:CP_DATA; powershell_lsp_scan = $req } | ConvertTo-Json -Compress -Depth 4'
            '$fixed = Invoke-ScanChildProcess -HostExe $KidHost -ScriptPath $Probe -StdinJson $json -CapMs 60000 -ExtraEnv @{ CP_LIB = $Lib }'
            '$res[''fixed''] = [string]$fixed.StdOut'
            '$res[''fixedErr''] = [string]$fixed.StdErr'
            '$psi = New-Object System.Diagnostics.ProcessStartInfo'
            '$psi.FileName = $KidHost; $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true'
            'Add-ProcessArguments $psi @(''-NoLogo'', ''-NoProfile'', ''-ExecutionPolicy'', ''Bypass'', ''-File'', $Probe)'
            '$psi.EnvironmentVariables[''CP_LIB''] = $Lib'
            '$c = [System.Diagnostics.Process]::Start($psi)'
            '$raw = (New-Object System.Text.UTF8Encoding($false)).GetBytes($json)'
            '$c.StandardInput.BaseStream.Write($raw, 0, $raw.Length); $c.StandardInput.BaseStream.Flush(); $c.StandardInput.Close()'
            '$res[''control''] = $c.StandardOutput.ReadToEnd()'
            'if (-not $c.WaitForExit(60000)) { try { $c.Kill() } catch { } }'
            '$c.Dispose()'
            '& $Scan $env:CP_WANT_FILE -Format sarif -OutputPath $Out -PsHost $KidHost | Out-Null'
            '$res[''cliExit''] = [int]$LASTEXITCODE'
            '[Console]::Out.Write(''CP-RESULT:'' + ($res | ConvertTo-Json -Compress))'
            'exit 0')
        # The shipped CLI, its libraries and the shipped client, byte copies, beside a session-start fake
        # that serves the scan's pipe from the fake daemon (a bound clean answer), as C-R9 does.
        $tree = New-SvCliTree -Root (Join-Path $script:CpRoot 'cli') -RealClient -SessionStartFixture 'fake-session-start-pipe.ps1'
        $clean = '{"ok":true,"action":"diagnostics","file":"","cached":false,"count":0,"omitted":0,"diagnostics":[],"scopeApplied":false,"scopeTotal":0,"scopeSurfaced":0,"path":"analyze","analysisMs":1,"codeActionMs":0,"recordCount":0,"correctionCount":0}'
        $cfg = [ordered]@{ daemonScript = (Get-SvFixturePath 'fake-pipe-daemon.ps1'); response = $clean; binding = 'valid'; vanish = '' }
        [System.IO.File]::WriteAllText((Join-Path $script:CpData 'cr-daemon.json'), ($cfg | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
        $script:CpSarif = Join-Path $script:CpRoot 'out.sarif'
        $wantRcpt = Join-Path (Join-Path $script:CpData 'scan-receipts') (('a' * 32) + '.json')
        try {
            $script:CpRun = Invoke-SvChildProcess -HostExe ((Get-Process -Id $PID).Path) -OwnConsole -CapMs 240000 `
                -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:CpScanner, '-CodePage', '437',
                    '-Lib', (Join-Path $script:RtRepo 'scripts/lib'), '-KidHost', $script:CpKidHost, '-Probe', $script:CpProbe,
                    '-Scan', $tree.ScanScript, '-Out', $script:CpSarif) `
                -ExtraEnv @{ CLAUDE_PLUGIN_DATA = $script:CpData; CP_DATA = $script:CpData; CP_WANT_FILE = $script:CpFile; CP_WANT_RCPT = $wantRcpt } `
                -RemoveEnvPrefix @('CLAUDE_PLUGIN_OPTION_', 'POWERSHELL_LSP_')
        } finally {
            # The CLI's own Stop-ScanDaemon kills the fake daemon by its recorded pid; this is the backstop.
            foreach ($rf in @(Get-ChildItem -LiteralPath $script:CpData -Recurse -File -Filter 'ready.pid' -ErrorAction SilentlyContinue)) {
                [void](Stop-SvChildFromPidFile -PidFile $rf.FullName)
            }
        }
        $m = [regex]::Match([string]$script:CpRun.Out, 'CP-RESULT:(\{.*\})')
        $script:CpResult = $(if ($m.Success) { $m.Groups[1].Value | ConvertFrom-Json } else { $null })
        $sarifText = Read-SvTextFile -Path $script:CpSarif
        $script:CpSarifObj = $(if (-not [string]::IsNullOrWhiteSpace($sarifText)) { $sarifText | ConvertFrom-Json } else { $null })
        $script:CpClientLog = Read-SvTextFile -Path (Join-Path $script:CpData 'logs/lsp-client.log')
    }

    AfterAll {
        if ($script:CpRoot) { Remove-SvTempRoot -Path $script:CpRoot }
    }

    It 'the stand-in scanner ran on a <Edition> parent with its own console pinned to code page 437' -TestCases @(@{ Edition = [string]$PSVersionTable.PSEdition }) {
        param($Edition)
        $script:CpRun.TimedOut | Should -BeFalse
        $script:CpResult | Should -Not -BeNullOrEmpty -Because ('the stand-in must report; stdout: ' + [string]$script:CpRun.Out + ' stderr: ' + [string]$script:CpRun.Err)
        [int]$script:CpResult.pin | Should -Be 437
    }

    It 'THE CONTROL: on that console a payload sent as raw UTF-8 -- what the spawner wrote before the fix -- arrives mangled (<Edition> parent)' -TestCases @(@{ Edition = [string]$PSVersionTable.PSEdition }) {
        param($Edition)
        [string]$script:CpResult.control | Should -BeExactly 'cp=437;PATH-MANGLED' -Because 'the child must decode at 437, or the pin does not bite and the round trip below proves nothing'
    }

    It 'the production spawner delivers a non-ASCII file path and a receipt path under a non-ASCII data root intact to a child on that console (<Edition> parent)' -TestCases @(@{ Edition = [string]$PSVersionTable.PSEdition }) {
        param($Edition)
        [string]$script:CpResult.fixed | Should -BeExactly 'cp=437;PATH-OK' -Because ('the child decodes at 437 and still reads both paths as written; its stderr: ' + [string]$script:CpResult.fixedErr)
    }

    It 'on that console the shipped CLI and client analyze a file whose name and data root are non-ASCII: exit 0, a complete receipt, executionSuccessful=true (<Edition> parent)' -TestCases @(@{ Edition = [string]$PSVersionTable.PSEdition }) {
        param($Edition)
        [int]$script:CpResult.cliExit | Should -Be 0 -Because ('a clean file with a complete receipt; stand-in stderr: ' + [string]$script:CpRun.Err)
        $script:CpClientLog | Should -Match 'scan mode: request [0-9a-f]{32}' -Because 'the shipped client ran in scan mode, under the non-ASCII data root'
        $script:CpClientLog | Should -Match 'scan receipt written: complete' -Because 'the client wrote its receipt where the payload said, under the non-ASCII data root'
        $script:CpSarifObj | Should -Not -BeNullOrEmpty
        [bool]$script:CpSarifObj.runs[0].invocations[0].executionSuccessful | Should -BeTrue
    }
}

Describe 'The real daemon binds the bytes it consumed (dispatch 000304 A2)' -Skip:$script:RtUnsupported {

    BeforeAll {
        . (Join-Path $PSScriptRoot 'Integration.Common.ps1')
        $script:RdScripts = Join-Path $script:RtRepo 'scripts'
        $script:RdHost = Resolve-PsHost 'pwsh'
        $script:RdData = if (-not [string]::IsNullOrWhiteSpace($env:PSLS_TEST_DATA_DIR)) { $env:PSLS_TEST_DATA_DIR } else { Join-Path ([System.IO.Path]::GetTempPath()) 'psls-sarifscan-test-data' }
        New-Item -ItemType Directory -Force -Path $script:RdData | Out-Null
        $script:RdPrevData = $env:CLAUDE_PLUGIN_DATA
        $env:CLAUDE_PLUGIN_DATA = $script:RdData
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $script:RdHost -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:RdScripts 'ensure-pses.ps1') 2>&1 | Out-Null
            & $script:RdHost -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:RdScripts 'ensure-pssa.ps1') 2>&1 | Out-Null
        } finally { $ErrorActionPreference = $prevEap }
        $script:RdSid = 'rdbind-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $script:RdDaemon = Start-ScanDaemon -ScriptsDir $script:RdScripts -DataRoot $script:RdData -SessionId $script:RdSid -HostExe $script:RdHost
        if ($null -ne $script:RdDaemon) { [void](Wait-DaemonRequestReady -SessionId $script:RdSid -DataRoot $script:RdData -TimeoutMs 60000) }
        $script:RdPipe = Get-DaemonPipeName -SessionId $script:RdSid
        $script:RdDir = Join-Path $script:RdData ('rdbind-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $script:RdDir | Out-Null
        $script:RdFile = Join-Path $script:RdDir 'bom-crlf.ps1'
        [System.IO.File]::WriteAllBytes($script:RdFile, [byte[]](@(0xEF, 0xBB, 0xBF) + [System.Text.Encoding]::UTF8.GetBytes("function Frobnicate-Bound {`r`n    Get-Process`r`n}`r`n")))
        $script:RdFull = [System.IO.Path]::GetFullPath($script:RdFile)
        $script:RdRid = New-ScanRequestId
        $base = @{ action = 'diagnostics'; file = $script:RdFull; cwd = $script:RdDir; protocolVersion = (Get-LspProtocolVersion); capabilities = (Get-LspClientCapabilities) }
        $script:RdScan = Invoke-DaemonRequest -PipeName $script:RdPipe -Request (@{ requestId = $script:RdRid } + $base) -ReadMs 30000
        $script:RdInteractive = Invoke-DaemonRequest -PipeName $script:RdPipe -Request $base -ReadMs 30000
        $script:RdBefore = ([string](Get-FileHash -LiteralPath $script:RdFile -Algorithm SHA256).Hash).ToLowerInvariant()
        [System.IO.File]::AppendAllText($script:RdFile, "# one more line`r`n")
        $script:RdAfter = ([string](Get-FileHash -LiteralPath $script:RdFile -Algorithm SHA256).Hash).ToLowerInvariant()
        $script:RdRid2 = New-ScanRequestId
        $script:RdScan2 = Invoke-DaemonRequest -PipeName $script:RdPipe -Request (@{ requestId = $script:RdRid2 } + $base) -ReadMs 30000
        $script:RdScanFile = Invoke-ScanFileDiagnostics -ScriptsDir $script:RdScripts -DataRoot $script:RdData -SessionId $script:RdSid -HostExe $script:RdHost -FilePath $script:RdFile -Cwd $script:RdDir
        $script:RdPsesManifest = Get-ScanManifestVersion -ManifestPath (Join-Path (Get-PsesBundleRoot) 'PowerShellEditorServices/PowerShellEditorServices.psd1')
        $script:RdPssaManifest = Get-ScanManifestVersion -ManifestPath ([string](Find-VendoredPssaManifest))
    }

    AfterAll {
        if ($script:RdSid) { Stop-ScanDaemon -ScriptsDir $script:RdScripts -DataRoot $script:RdData -SessionId $script:RdSid -HostExe $script:RdHost -DaemonInfo $script:RdDaemon }
        if ($script:RdDir -and (Test-Path -LiteralPath $script:RdDir)) { Remove-Item -LiteralPath $script:RdDir -Recurse -Force -ErrorAction SilentlyContinue }
        $env:CLAUDE_PLUGIN_DATA = $script:RdPrevData
    }

    It 'the real scan daemon came up and answered (this Describe cannot pass vacuously)' {
        $script:RdDaemon | Should -Not -BeNullOrEmpty
        $script:RdScan | Should -Not -BeNullOrEmpty
        [bool]$script:RdScan.ok | Should -BeTrue
        $script:RdScan.capabilities.diagnosticsAnalysisBinding | Should -BeTrue -Because 'the daemon advertises the binding it serves'
    }

    It 'a scan-mode answer echoes the request id and binds the path and the SHA-256 of the RAW bytes PSES received' {
        [string]$script:RdScan.requestId | Should -BeExactly $script:RdRid
        [string]$script:RdScan.analysis.requestId | Should -BeExactly $script:RdRid
        [string]$script:RdScan.analysis.path | Should -BeExactly $script:RdFull
        [string]$script:RdScan.analysis.source.boundary | Should -BeExactly 'daemon'
        [string]$script:RdScan.analysis.source.sha256 | Should -BeExactly $script:RdBefore -Because 'the BOM and the CRLFs are in the identity'
        [bool]$script:RdScan.analysis.settled | Should -BeTrue
        [bool]$script:RdScan.analysis.pssaAvailable | Should -BeTrue
    }

    It 'the engine versions are the ones the module manifests on disk declare, and the configuration is the launch configuration' {
        [string]$script:RdScan.analysis.engine.pses | Should -BeExactly $script:RdPsesManifest
        [string]$script:RdScan.analysis.engine.pssa | Should -BeExactly $script:RdPssaManifest
        $script:RdPsesManifest | Should -Not -BeExactly 'unknown'
        [int]$script:RdScan.analysis.config.perFileCap | Should -Be 0 -Because 'the scan daemon is launched with perFileCap=0'
        [string]$script:RdScan.analysis.config.severityThreshold | Should -BeExactly 'Hint'
    }

    It 'an INTERACTIVE request (no request id) is answered without any binding -- the edit-path payload is unchanged' {
        [bool]$script:RdInteractive.ok | Should -BeTrue
        @($script:RdInteractive.PSObject.Properties.Name) | Should -Not -Contain 'analysis'
        @($script:RdInteractive.PSObject.Properties.Name) | Should -Not -Contain 'requestId'
    }

    It 'the binding follows the bytes: after an edit, the next answer binds the new SHA-256' {
        $script:RdAfter | Should -Not -BeExactly $script:RdBefore
        [string]$script:RdScan2.requestId | Should -BeExactly $script:RdRid2
        [string]$script:RdScan2.analysis.source.sha256 | Should -BeExactly $script:RdAfter
    }

    It 'the production scan over that file is complete, its source bound, its finding real' {
        $script:RdScanFile.Analyzed | Should -BeTrue -Because ('reasons: ' + (@($script:RdScanFile.Reasons) -join ','))
        [string]$script:RdScanFile.Certification.Source | Should -BeExactly 'bound'
        [string]$script:RdScanFile.Certification.Engine | Should -BeExactly 'observed'
        @($script:RdScanFile.Findings | ForEach-Object { $_.ruleId }) | Should -Contain 'PSUseApprovedVerbs'
    }
}

Describe 'The shipped CLI under every capture mode: same complete SARIF, real messages, private telemetry (dispatch 000304 A2)' -Skip:$script:RtUnsupported {

    BeforeAll {
        $script:CmScripts = Join-Path $script:RtRepo 'scripts'
        $script:CmHost = Resolve-PsHost 'pwsh'
        $script:CmData = if (-not [string]::IsNullOrWhiteSpace($env:PSLS_TEST_DATA_DIR)) { $env:PSLS_TEST_DATA_DIR } else { Join-Path ([System.IO.Path]::GetTempPath()) 'psls-sarifscan-test-data' }
        New-Item -ItemType Directory -Force -Path $script:CmData | Out-Null
        $script:CmIn = Join-Path $script:CmData ('capmode-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $script:CmIn | Out-Null
        Set-Content -LiteralPath (Join-Path $script:CmIn 'clean.ps1') -Value "function Get-Clean {`n    [CmdletBinding()]`n    param([string]`$Name)`n    Write-Output `$Name`n}`n" -Encoding ascii
        Set-Content -LiteralPath (Join-Path $script:CmIn 'bad.ps1') -Value "function Frobnicate-Thing {`n    Get-Process`n}`n" -Encoding ascii
        $script:CmSchema = Join-Path $PSScriptRoot 'sarif/sarif-2.1.0.json'
        $script:CmDogfood = Join-Path $script:CmData 'dogfood/diagnostics.jsonl'
        $script:CmRuns = @{}
        foreach ($mode in @('full', 'metadata', 'off')) {
            $before = if (Test-Path -LiteralPath $script:CmDogfood) { (Get-Item -LiteralPath $script:CmDogfood).Length } else { -1 }
            $out = Join-Path $script:CmIn ('out-' + $mode + '.sarif')
            $prev = @{ data = $env:CLAUDE_PLUGIN_DATA; mode = $env:POWERSHELL_LSP_CAPTURE_MODE; log = $env:POWERSHELL_LSP_DOGFOOD_LOG }
            $env:CLAUDE_PLUGIN_DATA = $script:CmData
            $env:POWERSHELL_LSP_CAPTURE_MODE = $mode
            Remove-Item -LiteralPath 'Env:POWERSHELL_LSP_DOGFOOD_LOG' -ErrorAction SilentlyContinue
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                & $script:CmHost -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:CmScripts 'lsp-scan.ps1') $script:CmIn -Format sarif -OutputPath $out 2>$null | Out-Null
                $code = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $prevEap
                $env:CLAUDE_PLUGIN_DATA = $prev.data
                if ($null -eq $prev.mode) { Remove-Item -LiteralPath 'Env:POWERSHELL_LSP_CAPTURE_MODE' -ErrorAction SilentlyContinue } else { $env:POWERSHELL_LSP_CAPTURE_MODE = $prev.mode }
                if ($null -ne $prev.log) { $env:POWERSHELL_LSP_DOGFOOD_LOG = $prev.log }
            }
            $text = if (Test-Path -LiteralPath $out) { [System.IO.File]::ReadAllText($out) } else { '' }
            # The human-readable text path, same tree, same mode.
            $txtOut = Join-Path $script:CmIn ('out-' + $mode + '.txt')
            $env:CLAUDE_PLUGIN_DATA = $script:CmData
            $env:POWERSHELL_LSP_CAPTURE_MODE = $mode
            $ErrorActionPreference = 'Continue'
            try {
                & $script:CmHost -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:CmScripts 'lsp-scan.ps1') $script:CmIn -Format text -OutputPath $txtOut 2>$null | Out-Null
                $txtCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $prevEap
                $env:CLAUDE_PLUGIN_DATA = $prev.data
                if ($null -eq $prev.mode) { Remove-Item -LiteralPath 'Env:POWERSHELL_LSP_CAPTURE_MODE' -ErrorAction SilentlyContinue } else { $env:POWERSHELL_LSP_CAPTURE_MODE = $prev.mode }
            }
            # measured AFTER both runs, so neither format may write the persistent log
            $after = if (Test-Path -LiteralPath $script:CmDogfood) { (Get-Item -LiteralPath $script:CmDogfood).Length } else { -1 }
            $script:CmRuns[$mode] = @{
                Exit = $code; Text = $text; Sarif = $(if ($text) { $text | ConvertFrom-Json } else { $null }); DogfoodBefore = $before; DogfoodAfter = $after
                TextExit = $txtCode; TextReport = $(if (Test-Path -LiteralPath $txtOut) { [System.IO.File]::ReadAllText($txtOut) } else { '' })
            }
        }
    }

    AfterAll {
        if ($script:CmIn -and (Test-Path -LiteralPath $script:CmIn)) { Remove-Item -LiteralPath $script:CmIn -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'capture mode <Mode>: the CLI exits 0 with executionSuccessful=true -- every file carried a complete receipt' -TestCases @(@{ Mode = 'full' }, @{ Mode = 'metadata' }, @{ Mode = 'off' }) {
        param($Mode)
        $run = $script:CmRuns[$Mode]
        [int]$run.Exit | Should -Be 0
        $run.Sarif | Should -Not -BeNullOrEmpty
        [bool]$run.Sarif.runs[0].invocations[0].executionSuccessful | Should -BeTrue
    }

    It 'capture mode <Mode>: the SARIF carries the REAL diagnostic text, independent of the persistent privacy mode' -TestCases @(@{ Mode = 'full' }, @{ Mode = 'metadata' }, @{ Mode = 'off' }) {
        param($Mode)
        $verb = @(@($script:CmRuns[$Mode].Sarif.runs[0].results) | Where-Object { [string]$_.ruleId -eq 'PSUseApprovedVerbs' })
        $verb.Count | Should -Be 1
        [string]$verb[0].message.text | Should -Match 'Frobnicate-Thing.*unapproved verb'
    }

    It 'capture mode <Mode>: the SARIF validates against the vendored 2.1.0 schema' -Skip:$script:RtNoTestJson -TestCases @(@{ Mode = 'full' }, @{ Mode = 'metadata' }, @{ Mode = 'off' }) {
        param($Mode)
        (Test-Json -Json $script:CmRuns[$Mode].Text -Schema ([System.IO.File]::ReadAllText($script:CmSchema))) | Should -BeTrue
    }

    It 'capture mode <Mode>: the TEXT report exits 0 with the real diagnostic text and no not-analyzed warning' -TestCases @(@{ Mode = 'full' }, @{ Mode = 'metadata' }, @{ Mode = 'off' }) {
        param($Mode)
        $run = $script:CmRuns[$Mode]
        [int]$run.TextExit | Should -Be 0
        [string]$run.TextReport | Should -Match 'Frobnicate-Thing.*unapproved verb'
        [string]$run.TextReport | Should -Match '2 PowerShell file\(s\) scanned' -Because 'nonzero discovery, both files'
        [string]$run.TextReport | Should -Not -Match 'could NOT be analyzed'
    }

    It 'capture mode <Mode>: the scan wrote nothing into the persistent dogfood log' -TestCases @(@{ Mode = 'full' }, @{ Mode = 'metadata' }, @{ Mode = 'off' }) {
        param($Mode)
        $run = $script:CmRuns[$Mode]
        $run.DogfoodAfter | Should -Be $run.DogfoodBefore -Because 'the scan child captures to its own private transport, never the administrator''s log'
    }

    It 'the telemetry privacy default is unchanged: an unset capture mode still resolves metadata' {
        $prev = $env:POWERSHELL_LSP_CAPTURE_MODE
        try {
            Remove-Item -LiteralPath 'Env:POWERSHELL_LSP_CAPTURE_MODE' -ErrorAction SilentlyContinue
            [string](Get-DiagnosticCaptureModeInfo).resolved | Should -BeExactly 'metadata'
        } finally {
            if ($null -ne $prev) { $env:POWERSHELL_LSP_CAPTURE_MODE = $prev }
        }
    }
}
