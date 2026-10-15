#Requires -Version 5.1

# lsp-scan-receipt.ps1 -- the scan COMPLETION RECEIPT (dispatch 000304, leg A2).
#
# THE GAP THIS CLOSES (review finding F1, measured by dispatch 000302). A scan used to call a file
# analyzed unless something proved otherwise: Invoke-ScanFileDiagnostics started from
# Analyzed=$true and flipped it only on a cap kill or a 'NOT checked' banner. A healthy clean pass
# is SILENT by the interactive contract, so a silent exit, a nonzero exit, a stderr-only failure, a
# malformed or missing record stream, a daemon refusal and a vanished source all looked exactly like
# a clean file at the scanner's boundary -- A1 measured seven of nine such situations reported
# analyzed. The cure is POSITIVE evidence: a typed receipt the scan child writes only in scan mode,
# which the scanner validates before it believes anything. A missing receipt never means zero
# findings.
#
# THREE PARTIES, ONE VOCABULARY. What a receipt means is defined here, once, and dot-sourced by all
# three parties:
#   - the DAEMON (scripts/pses-daemon.ps1) binds the analysis it actually ran: the request id it was
#     asked under, the path it normalized, the SHA-256 of the exact bytes it read and handed to PSES,
#     whether the pass settled, whether PSScriptAnalyzer was available, the engine versions it can
#     observe and the configuration it was launched with (New-ScanAnalysisBinding);
#   - the CLIENT (scripts/lsp-client.ps1) is the scan-only completion PRODUCER: in scan mode it
#     writes one receipt per request, on every exit path, from what it actually did
#     (New-ScanReceipt, Write-ScanReceipt);
#   - the SCANNER (scripts/lib/lsp-scan-common.ps1) is the CONSUMER: it re-derives completeness from
#     the receipt's own facts, and checks the correlation, the file identity, the bytes it saw on
#     disk before and after the child against the bytes the daemon says it consumed, and the finding
#     records it read against the receipt's count and digest (Test-ScanReceipt).
#
# SCAN MODE ONLY. A receipt is requested by a field of the hook payload Claude Code never sends
# (powershell_lsp_scan). An interactive edit carries no such field, so no receipt is written, no
# request id is sent, the daemon adds no binding, and the interactive surface is byte-identical.
#
# STATUS AND COMPLETENESS ARE DIFFERENT AXES. status is one of the four PUBLIC tokens CONTRACT.md
# freezes (ok / incomplete / degraded / unavailable) and means on a receipt what it means on the
# edit path. completeness (complete / partial / failed) is ADDITIVE and scan-only:
#   complete  the configured PSScriptAnalyzer pass settled, over bytes the scanner can identify;
#   partial   the findings are real, but that pass did not fully run (parser-only, a byte-check
#             short-circuit, a per-file cap, an edit-range scope);
#   failed    nothing about the file's analysis can be relied on.
# Only complete is reported analyzed. The reason table below is the explicit mapping: every reason
# carries the highest completeness a receipt holding it can reach, and a receipt's completeness is
# the lowest ceiling among its reasons.
#
# NOTHING IS CERTIFIED THAT WAS NOT BOUND. A receipt records the configuration the daemon was
# launched with as OBSERVED and unbound: binding the declared scan environment is A3's leg. Since
# schema version 2 (dispatch 000305, B1) it also carries the POLICY APPLICATION EVIDENCE each party
# recorded -- the client's adjudication and the daemon's application (scripts/lib/lsp-policy.ps1) --
# under policy.state 'observed'. That is evidence, not a verdict: a receipt never certifies a policy;
# only a managed scan does (Test-ScanPolicyCertification), and only from this evidence. The engine
# versions are what the daemon can read from the module manifests on disk, or 'unknown' -- never a
# pin standing in for an observation. Nothing in this file writes a digest it did not compute from
# real bytes.
#
# Load-silent: function definitions only (G1/G2, tests/PowerShellLsp.LibPurity.Tests.ps1). Uses
# Get-Prop, Get-PluginVersion, Get-Sha256HexFromBytes, Get-PsesBundleRoot and
# Find-VendoredPssaManifest from scripts/lib/lsp-common.ps1 -- dot-source that library first.
# docs/scan-receipt.schema.json describes the same shape as JSON Schema, and
# tests/PowerShellLsp.ScanReceipt.Tests.ps1 holds the two together. ASCII-only; StrictMode-safe.
#
# Author: Mike Andersen / powershell-lsp plugin.

# --- vocabulary ------------------------------------------------------------

function Get-ScanReceiptSchema {
    # The receipt's identity on the wire. Bump Version only for a change a reader must know about.
    # 2 (dispatch 000305, B1): policy.state may be 'observed', carrying application evidence -- a
    # version-1 reader refuses any policy state but 'unbound', so it must know.
    return [ordered]@{ Id = 'powershell-lsp/scan-receipt'; Version = 2 }
}

function Get-ScanReceiptPolicyStates {
    # What a receipt's policy block may say: 'unbound' (no evidence was recorded) or 'observed' (each
    # party's own application record rides beside it). Never 'verified' or 'certified': certification
    # is the managed scan's verdict over this evidence, never a receipt's claim about itself.
    return @('unbound', 'observed')
}

function Get-ScanReceiptStatusTokens {
    # The four PUBLIC status tokens (CONTRACT.md Tier 1.2). A receipt's status is one of these and
    # nothing else -- the receipt adds an axis, never a token. Pinned to the contract's frozen set by
    # tests/PowerShellLsp.ScanReceipt.Tests.ps1.
    return @('ok', 'incomplete', 'degraded', 'unavailable')
}

function Get-ScanReceiptPasses {
    # Which analysis produced the receipt's findings:
    #   pssa      the daemon's settled PSES/PSScriptAnalyzer pass (the only pass that can be complete);
    #   parser    the client's parser pre-pass short-circuit (the file does not parse);
    #   pre-pssa  the client's byte-level pre-pass short-circuit (smart punctuation etc.);
    #   none      no analysis ran for this request.
    return @('pssa', 'parser', 'pre-pssa', 'none')
}

function Get-ScanCompletenessRank {
    # complete (2) > partial (1) > failed (0). Any other value ranks BELOW failed, so an unknown
    # value can never rise to complete.
    param([string]$Completeness)
    switch ([string]$Completeness) {
        'complete' { return 2 }
        'partial' { return 1 }
        'failed' { return 0 }
        default { return -1 }
    }
}

function Get-ScanReceiptReasonTable {
    # THE REASON VOCABULARY. Each machine reason code maps to:
    #   Ceiling  the highest completeness a receipt carrying it can reach -- the explicit
    #            status/completeness table, one row per cause;
    #   Origin   who observes it: the scanner (outside the child), the client (the producing hook),
    #            or the daemon binding (derived from what the daemon reported);
    #   Meaning  one line, for the docs and the SARIF reader.
    # A reason code nobody declared here is refused by the validator (receipt-malformed): a code is a
    # contract with the reader, so a new one is a schema change, not an improvisation.
    $t = [ordered]@{}
    # the child process, observed by the scanner
    $t['child-silent-exit'] = [ordered]@{ Ceiling = 'failed'; Origin = 'scanner'; Meaning = 'the analysis child exited 0 with no output and no receipt' }
    $t['child-nonzero-exit'] = [ordered]@{ Ceiling = 'failed'; Origin = 'scanner'; Meaning = 'the analysis host exited nonzero' }
    $t['child-stderr-only'] = [ordered]@{ Ceiling = 'failed'; Origin = 'scanner'; Meaning = 'the child reported only on stderr and wrote no receipt' }
    $t['deadline-kill'] = [ordered]@{ Ceiling = 'failed'; Origin = 'scanner'; Meaning = 'the child did not exit within the per-file cap and was killed' }
    $t['kill-unverified'] = [ordered]@{ Ceiling = 'failed'; Origin = 'scanner'; Meaning = 'the killed child was still running after the kill' }
    # the receipt itself, observed by the scanner
    $t['receipt-missing'] = [ordered]@{ Ceiling = 'failed'; Origin = 'scanner'; Meaning = 'no completion receipt was written' }
    $t['receipt-truncated'] = [ordered]@{ Ceiling = 'failed'; Origin = 'scanner'; Meaning = 'the receipt ends before its JSON does' }
    $t['receipt-malformed'] = [ordered]@{ Ceiling = 'failed'; Origin = 'scanner'; Meaning = 'the receipt is not JSON, or not a valid receipt of this schema' }
    $t['receipt-inconsistent'] = [ordered]@{ Ceiling = 'failed'; Origin = 'scanner'; Meaning = 'the receipt claims more than its own facts support' }
    $t['correlation-mismatch'] = [ordered]@{ Ceiling = 'failed'; Origin = 'scanner'; Meaning = 'the receipt or the daemon answered a different request id' }
    $t['correlation-missing'] = [ordered]@{ Ceiling = 'failed'; Origin = 'daemon'; Meaning = 'the daemon answer carries no request id, so it cannot be tied to this request' }
    $t['path-mismatch'] = [ordered]@{ Ceiling = 'failed'; Origin = 'scanner'; Meaning = 'the receipt or the daemon names a different file' }
    $t['diagnostics-mismatch'] = [ordered]@{ Ceiling = 'failed'; Origin = 'scanner'; Meaning = 'the finding records read back differ from the receipt count or digest' }
    # the source bytes
    $t['source-vanished'] = [ordered]@{ Ceiling = 'failed'; Origin = 'scanner'; Meaning = 'the file was gone before, during or after the analysis' }
    $t['source-changed'] = [ordered]@{ Ceiling = 'failed'; Origin = 'scanner'; Meaning = 'the file bytes changed while it was being scanned' }
    $t['source-mismatch'] = [ordered]@{ Ceiling = 'failed'; Origin = 'scanner'; Meaning = 'the daemon consumed bytes other than the bytes on disk' }
    $t['source-unbound'] = [ordered]@{ Ceiling = 'failed'; Origin = 'daemon'; Meaning = 'no daemon-consumed source identity, so which bytes were analyzed is unprovable' }
    # what the producing client did
    $t['request-invalid'] = [ordered]@{ Ceiling = 'failed'; Origin = 'client'; Meaning = 'the hook payload had no session id or file path' }
    $t['not-powershell'] = [ordered]@{ Ceiling = 'failed'; Origin = 'client'; Meaning = 'the file is not .ps1, .psm1 or .psd1' }
    $t['daemon-unreachable'] = [ordered]@{ Ceiling = 'failed'; Origin = 'client'; Meaning = 'no analysis daemon could be reached' }
    $t['daemon-no-answer'] = [ordered]@{ Ceiling = 'failed'; Origin = 'client'; Meaning = 'the daemon was present but gave no usable answer within the cap' }
    $t['daemon-refused'] = [ordered]@{ Ceiling = 'failed'; Origin = 'client'; Meaning = 'the daemon answered ok=false' }
    $t['client-fatal'] = [ordered]@{ Ceiling = 'failed'; Origin = 'client'; Meaning = 'the client failed before rendering a verdict' }
    $t['policy-fail-closed'] = [ordered]@{ Ceiling = 'failed'; Origin = 'client'; Meaning = 'managed mode refused an org policy that did not validate' }
    $t['analysis-not-run'] = [ordered]@{ Ceiling = 'failed'; Origin = 'client'; Meaning = 'no analysis pass ran for this request' }
    $t['formatter-active'] = [ordered]@{ Ceiling = 'failed'; Origin = 'client'; Meaning = 'format-on-edit was not off, so the file may have been rewritten' }
    $t['parse-errors'] = [ordered]@{ Ceiling = 'partial'; Origin = 'client'; Meaning = 'the file does not parse; PSScriptAnalyzer rules did not run' }
    $t['pre-pssa-short-circuit'] = [ordered]@{ Ceiling = 'partial'; Origin = 'client'; Meaning = 'the byte-level pre-pass stopped the analysis before PSScriptAnalyzer' }
    # what the daemon binding says about the pass it ran
    $t['analysis-not-settled'] = [ordered]@{ Ceiling = 'failed'; Origin = 'daemon'; Meaning = 'the pass did not settle (status incomplete)' }
    $t['engine-unavailable'] = [ordered]@{ Ceiling = 'failed'; Origin = 'daemon'; Meaning = 'PowerShell editor services could not start (status unavailable)' }
    $t['pssa-unavailable'] = [ordered]@{ Ceiling = 'partial'; Origin = 'daemon'; Meaning = 'parser-only pass, PSScriptAnalyzer absent (status degraded)' }
    $t['diagnostics-capped'] = [ordered]@{ Ceiling = 'partial'; Origin = 'daemon'; Meaning = 'a per-file cap omitted findings' }
    $t['diagnostics-scoped'] = [ordered]@{ Ceiling = 'partial'; Origin = 'daemon'; Meaning = 'the findings were filtered to an edit range' }
    $t['cache-hit'] = [ordered]@{ Ceiling = 'complete'; Origin = 'daemon'; Meaning = 'a settled result for identical text was served from the daemon cache (informational)' }
    return $t
}

function Get-ScanReasonCeiling {
    # The completeness ceiling of one reason code. An UNKNOWN code is 'failed': a reason nobody
    # defined can only lower a verdict, never leave it standing.
    param([string]$Reason)
    $table = Get-ScanReceiptReasonTable
    if ($table.Contains([string]$Reason)) { return [string]$table[[string]$Reason].Ceiling }
    return 'failed'
}

function Get-ScanCompletenessFromReasons {
    # The completeness a set of reasons allows: the LOWEST ceiling among them, 'complete' when there
    # are none. One function, called by the producer and the validator alike, so the two can never
    # apply different tables.
    param([string[]]$Reasons)
    $best = 'complete'
    foreach ($r in @($Reasons)) {
        if ([string]::IsNullOrWhiteSpace([string]$r)) { continue }
        $c = Get-ScanReasonCeiling -Reason ([string]$r)
        if ((Get-ScanCompletenessRank $c) -lt (Get-ScanCompletenessRank $best)) { $best = $c }
    }
    return $best
}

function Get-ScanStatusReason {
    # The reason a non-ok public status carries into a receipt ('' for ok).
    param([string]$Status)
    switch ([string]$Status) {
        'incomplete' { return 'analysis-not-settled' }
        'degraded' { return 'pssa-unavailable' }
        'unavailable' { return 'engine-unavailable' }
        default { return '' }
    }
}

# --- field access over both shapes ------------------------------------------

function Test-ScanReceiptHasField {
    # $true when $Object carries a field named $Name, whatever its value (null included). Reads both
    # shapes a receipt takes: the [ordered] dictionary the producer builds and the PSCustomObject
    # ConvertFrom-Json returns. Anything else -- a string, a number -- carries no fields.
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Name) }
    if ($Object.GetType().FullName -ne 'System.Management.Automation.PSCustomObject') { return $false }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Get-ScanReceiptField {
    # One read for both receipt shapes (see Test-ScanReceiptHasField). The value comes back through
    # the comma operator, so an array field survives the function return intact: a plain `return`
    # would unroll a one-element array into its element and an empty one into $null, and the shape
    # check could then not tell an array from a scalar.
    param($Object, [string]$Name)
    if (-not (Test-ScanReceiptHasField -Object $Object -Name $Name)) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return , $Object[$Name] }
    return , $Object.PSObject.Properties[$Name].Value
}

function Test-ScanReceiptInt {
    # $true when $Value is an integral number at or above $Minimum. JSON numbers arrive as Int32,
    # Int64, Decimal or Double depending on the host, so the test is on the value, not one type.
    param($Value, [long]$Minimum = 0)
    if ($null -eq $Value -or $Value -is [bool] -or $Value -is [string]) { return $false }
    if (-not ($Value -is [int] -or $Value -is [long] -or $Value -is [decimal] -or $Value -is [double])) { return $false }
    try {
        $d = [decimal]$Value
        if ($d -ne [decimal]::Truncate($d)) { return $false }
        return ($d -ge $Minimum)
    } catch { return $false }
}

# --- source identity -------------------------------------------------------

function Read-ScanSourceSnapshot {
    # Read a file's bytes ONCE and return their identity together with the text decoded FROM THOSE
    # SAME BYTES, so the hash and the analyzed text can never describe two different reads. Decoding
    # mirrors [System.IO.File]::ReadAllText exactly (UTF-8 default, BOM detected), which is how the
    # daemon read a file before this seam existed, so the text PSES receives is unchanged.
    # Returns @{ Exists; Sha256 (lower-case hex of the raw bytes); Length; Text; Error }. Never throws:
    # a read that fails reports Exists=$false with the reason, and the caller decides what that means.
    param([string]$Path, [switch]$NoText)
    $snap = [pscustomobject]@{ Exists = $false; Sha256 = ''; Length = 0; Text = ''; Error = '' }
    if ([string]::IsNullOrWhiteSpace($Path)) { $snap.Error = 'no path'; return $snap }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $snap.Sha256 = Get-Sha256HexFromBytes -Bytes $bytes
        $snap.Length = $bytes.Length
        if (-not $NoText) {
            $ms = New-Object System.IO.MemoryStream(, $bytes)
            $sr = New-Object System.IO.StreamReader($ms, [System.Text.Encoding]::UTF8, $true)
            try { $snap.Text = $sr.ReadToEnd() } finally { $sr.Dispose() }
        }
        $snap.Exists = $true
    } catch {
        $snap.Error = $_.Exception.Message
    }
    return $snap
}

# --- engine and configuration, as the daemon observes them --------------------

function Get-ScanManifestVersion {
    # ModuleVersion from a module manifest, READ (never executed), or 'unknown'.
    param([string]$ManifestPath)
    if ([string]::IsNullOrWhiteSpace($ManifestPath) -or -not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { return 'unknown' }
    try {
        $src = [System.IO.File]::ReadAllText($ManifestPath)
        $m = [regex]::Match($src, "(?m)^\s*ModuleVersion\s*=\s*['""]([^'""]+)['""]")
        if ($m.Success) { return [string]$m.Groups[1].Value }
    } catch { }
    return 'unknown'
}

function Get-ScanEngineIdentity {
    # The engine versions a daemon can OBSERVE: the PSES module manifest it launches and the
    # PSScriptAnalyzer module manifest it prepends to PSES's PSModulePath. Read from the manifests on
    # disk, not from the pins: a pin says what SHOULD be installed, a manifest what IS. 'unknown' when
    # a manifest is absent or unreadable. The version PSES loaded in-process is not queried -- PSES
    # offers no request for it -- so this is the version made available to it, and says so.
    param([string]$PsesHost = '')
    $psesManifest = Join-Path (Get-PsesBundleRoot) 'PowerShellEditorServices/PowerShellEditorServices.psd1'
    $pssaManifest = ''
    try { $pssaManifest = [string](Find-VendoredPssaManifest) } catch { $pssaManifest = '' }
    return [ordered]@{
        pses         = (Get-ScanManifestVersion -ManifestPath $psesManifest)
        pssa         = (Get-ScanManifestVersion -ManifestPath $pssaManifest)
        source       = 'module-manifest'
        daemonPlugin = [string](Get-PluginVersion)
        daemonHost   = ([string]$PSVersionTable.PSEdition + ' ' + [string]$PSVersionTable.PSVersion)
        psesHost     = [string]$PsesHost
    }
}

function New-ScanAnalysisBinding {
    # DAEMON SIDE: the binding a scan-mode diagnostics answer carries -- what this daemon actually
    # analyzed, for which request. Called by scripts/pses-daemon.ps1 for a request that carries a
    # requestId, and by nothing on the interactive path. source is $null when the daemon consumed no
    # bytes (a not-ready or unavailable answer), which a receipt then reports as source-unbound.
    param(
        [string]$RequestId,
        [string]$AnalyzedPath,
        $Snapshot = $null,
        [bool]$Settled = $false,
        [bool]$PssaAvailable = $false,
        [bool]$Cached = $false,
        $Engine = $null,
        $Config = $null,
        # The daemon's policy application record (dispatch 000305, B1; New-PolicyApplicationEvidence in
        # scripts/lib/lsp-policy.ps1), or $null. Carried, never interpreted, here.
        $Policy = $null
    )
    $src = $null
    if ($null -ne $Snapshot -and [bool]$Snapshot.Exists -and -not [string]::IsNullOrWhiteSpace([string]$Snapshot.Sha256)) {
        $src = [ordered]@{ boundary = 'daemon'; sha256 = [string]$Snapshot.Sha256; length = [int]$Snapshot.Length }
    }
    return [ordered]@{
        requestId     = [string]$RequestId
        path          = [string]$AnalyzedPath
        source        = $src
        settled       = $Settled
        pssaAvailable = $PssaAvailable
        cached        = $Cached
        engine        = $Engine
        config        = $Config
        policy        = $Policy
    }
}

# --- the request a scan sends -------------------------------------------------

function New-ScanRequestId {
    # 32 lower-case hex characters, fresh per file analysis.
    return [guid]::NewGuid().ToString('N')
}

function New-ScanRequestField {
    # SCANNER SIDE: the hook-payload field that turns a client run into a scan-mode run. It rides the
    # payload (never the environment), so an ambient variable cannot switch an interactive edit into
    # scan mode, and the correlation travels with the one request it belongs to.
    param([Parameter(Mandatory = $true)][string]$RequestId, [Parameter(Mandatory = $true)][string]$ReceiptPath)
    return [ordered]@{ request_id = $RequestId; receipt_path = $ReceiptPath }
}

function Get-ScanRequestContext {
    # CLIENT SIDE: the scan-mode request a parsed hook payload carries, or $null -- for every
    # interactive edit, and for a scan field that is not well formed (no receipt is then written, and
    # the scanner reads receipt-missing: a malformed request can only fail closed).
    param($Payload)
    $scan = Get-Prop $Payload 'powershell_lsp_scan'
    if ($null -eq $scan) { return $null }
    $rid = [string](Get-Prop $scan 'request_id')
    $path = [string](Get-Prop $scan 'receipt_path')
    if ($rid -notmatch '^[0-9a-f]{32}$') { return $null }
    if ([string]::IsNullOrWhiteSpace($path)) { return $null }
    try { if (-not [System.IO.Path]::IsPathRooted($path)) { return $null } } catch { return $null }
    return [pscustomobject]@{ RequestId = $rid; ReceiptPath = $path }
}

# --- the diagnostics a receipt vouches for -------------------------------------

function ConvertTo-ScanDiagnosticLine {
    # One canonical line per finding record: line, col, ruleId, source, severity, message, joined by
    # the unit separator. Built by concatenation, never by ConvertTo-Json: the producer and the
    # validator may run under different hosts, and Windows PowerShell 5.1 and PowerShell 7 serialize
    # JSON differently. Accepts the capture-record hashtable and the parsed finding object alike.
    param($Record)
    $line = 0; $col = 0
    try { $line = [int](Get-ScanReceiptField $Record 'line') } catch { $line = 0 }
    try { $col = [int](Get-ScanReceiptField $Record 'col') } catch { $col = 0 }
    $us = [string][char]31
    return ([string]$line + $us + [string]$col + $us +
        [string](Get-ScanReceiptField $Record 'ruleId') + $us +
        [string](Get-ScanReceiptField $Record 'source') + $us +
        [string](Get-ScanReceiptField $Record 'severity') + $us +
        [string](Get-ScanReceiptField $Record 'message'))
}

function Get-ScanDiagnosticsDigest {
    # The binding over a finding set: its count and a SHA-256 over the canonical lines SORTED
    # (ordinal), so the binding is order-free but keeps duplicates. The producer computes it over the
    # records it handed to the capture writer; the validator over the records it read back.
    param([object[]]$Records)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($r in @($Records)) {
        if ($null -eq $r) { continue }
        $lines.Add((ConvertTo-ScanDiagnosticLine -Record $r))
    }
    $arr = $lines.ToArray()
    [System.Array]::Sort($arr, [System.StringComparer]::Ordinal)
    $text = [string]::Join([string][char]30, $arr)
    return [ordered]@{
        count  = $arr.Length
        digest = (Get-Sha256HexFromBytes -Bytes ([System.Text.Encoding]::UTF8.GetBytes($text)))
    }
}

# --- deriving reasons from a receipt's own facts -------------------------------

function Get-ScanReceiptDerivedReasons {
    # The reasons a receipt's OWN FACTS imply, whatever its producer wrote. The producer folds these
    # into the receipt it writes; the validator recomputes them and refuses a receipt whose declared
    # reasons omit one, or whose declared completeness is better than they allow
    # (receipt-inconsistent). That is what keeps envelope validity from certifying anything: a
    # well-formed receipt saying status=degraded and completeness=complete is refused.
    param($Receipt)
    $out = New-Object System.Collections.Generic.List[string]
    # Assigned FIRST: Get-ScanReceiptField returns an array as ONE object, so wrapping the call itself
    # in @() would nest it and stringify the whole list into one element.
    $declaredRaw = Get-ScanReceiptField $Receipt 'reasons'
    $declared = @(@($declaredRaw) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
    $status = [string](Get-ScanReceiptField $Receipt 'status')
    $sr = Get-ScanStatusReason -Status $status
    if ($sr -eq 'engine-unavailable' -and $declared -contains 'policy-fail-closed') { $sr = '' }   # the policy refusal names its own cause
    if ($sr -ne '') { $out.Add($sr) }
    $pass = [string](Get-ScanReceiptField $Receipt 'pass')
    switch ($pass) {
        'parser' { $out.Add('parse-errors') }
        'pre-pssa' { $out.Add('pre-pssa-short-circuit') }
        'none' { $out.Add('analysis-not-run') }
        'pssa' {
            $d = Get-ScanReceiptField $Receipt 'daemon'
            if ($null -eq $d) {
                $out.Add('correlation-missing')
                $out.Add('source-unbound')
            } else {
                $echo = [string](Get-ScanReceiptField $d 'requestId')
                if ([string]::IsNullOrWhiteSpace($echo)) { $out.Add('correlation-missing') }
                elseif ($echo -cne [string](Get-ScanReceiptField $Receipt 'requestId')) { $out.Add('correlation-mismatch') }
                if ([string](Get-ScanReceiptField $d 'path') -cne [string](Get-ScanReceiptField $Receipt 'file')) { $out.Add('path-mismatch') }
                if ((Get-ScanReceiptField $d 'settled') -ne $true) { $out.Add('analysis-not-settled') }
                if ((Get-ScanReceiptField $d 'pssaAvailable') -ne $true) { $out.Add('pssa-unavailable') }
                $omitted = Get-ScanReceiptField $d 'omitted'
                if ((Test-ScanReceiptInt $omitted 1)) { $out.Add('diagnostics-capped') }
                if ((Get-ScanReceiptField $d 'scopeApplied') -eq $true) { $out.Add('diagnostics-scoped') }
                if ((Get-ScanReceiptField $d 'cached') -eq $true) { $out.Add('cache-hit') }
            }
            $s = Get-ScanReceiptField $Receipt 'source'
            if ([string](Get-ScanReceiptField $s 'boundary') -ne 'daemon' -or [string]::IsNullOrWhiteSpace([string](Get-ScanReceiptField $s 'sha256'))) {
                $out.Add('source-unbound')
            }
        }
        default { $out.Add('analysis-not-run') }
    }
    if ([string](Get-ScanReceiptField $Receipt 'formatMode') -ne 'off') { $out.Add('formatter-active') }
    return @($out.ToArray() | Sort-Object -Unique)
}

# --- the producer (client side) --------------------------------------------------

function New-ScanReceipt {
    # CLIENT SIDE: build the receipt for one scan-mode request from what the client actually did.
    # The caller passes FACTS -- the pass that ran, the public status it got, the daemon's binding,
    # the records it captured -- plus any reason it observed itself; this function derives every
    # other reason and the completeness from those facts with the same functions the validator uses,
    # so a receipt can never be produced claiming more than its facts allow. Returns an [ordered]
    # dictionary ready for Write-ScanReceipt.
    param(
        [Parameter(Mandatory = $true)][string]$RequestId,
        [string]$File = '',
        [string]$Pass = 'none',
        [string]$Status = '',
        $Binding = $null,
        [int]$Omitted = 0,
        [bool]$ScopeApplied = $false,
        [int]$AnalysisMs = 0,
        $ClientSource = $null,
        [object[]]$Records = @(),
        [string]$FormatMode = 'off',
        [int]$ElapsedMs = 0,
        [string[]]$Reasons = @(),
        [string]$Detail = '',
        # The client's policy adjudication record (dispatch 000305, B1; New-PolicyAdjudicationEvidence
        # in scripts/lib/lsp-policy.ps1). With it the receipt's policy block is 'observed' and carries
        # it beside the daemon's record from the binding; without it the block stays 'unbound'.
        $PolicyEvidence = $null
    )
    $schema = Get-ScanReceiptSchema
    if ((Get-ScanReceiptPasses) -notcontains $Pass) { $Pass = 'none' }
    $tokens = Get-ScanReceiptStatusTokens
    $st = ([string]$Status).Trim().ToLowerInvariant()
    if ($st -eq '') { $st = $(if ($Pass -eq 'none') { 'incomplete' } else { 'ok' }) }
    if ($tokens -notcontains $st) { $st = 'incomplete' }

    $source = [ordered]@{ boundary = 'none'; sha256 = ''; length = 0 }
    $daemon = $null
    $engine = [ordered]@{ pses = 'unknown'; pssa = 'unknown'; source = 'none'; daemonPlugin = 'unknown'; daemonHost = 'unknown'; psesHost = '' }
    $observed = $null
    $daemonPolicy = $null
    if ($Pass -eq 'pssa' -and $null -ne $Binding) {
        $daemonPolicy = Get-ScanReceiptField $Binding 'policy'
        $bsrc = Get-ScanReceiptField $Binding 'source'
        if ($null -ne $bsrc -and -not [string]::IsNullOrWhiteSpace([string](Get-ScanReceiptField $bsrc 'sha256'))) {
            $source = [ordered]@{
                boundary = [string](Get-ScanReceiptField $bsrc 'boundary')
                sha256   = [string](Get-ScanReceiptField $bsrc 'sha256')
                length   = [int](Get-ScanReceiptField $bsrc 'length')
            }
        }
        $daemon = [ordered]@{
            requestId     = [string](Get-ScanReceiptField $Binding 'requestId')
            path          = [string](Get-ScanReceiptField $Binding 'path')
            settled       = ((Get-ScanReceiptField $Binding 'settled') -eq $true)
            pssaAvailable = ((Get-ScanReceiptField $Binding 'pssaAvailable') -eq $true)
            cached        = ((Get-ScanReceiptField $Binding 'cached') -eq $true)
            omitted       = [int]$Omitted
            scopeApplied  = [bool]$ScopeApplied
            analysisMs    = [int]$AnalysisMs
        }
        $be = Get-ScanReceiptField $Binding 'engine'
        if ($null -ne $be) {
            foreach ($k in @('pses', 'pssa', 'source', 'daemonPlugin', 'daemonHost', 'psesHost')) {
                $v = [string](Get-ScanReceiptField $be $k)
                if (-not [string]::IsNullOrWhiteSpace($v)) { $engine[$k] = $v }
            }
        }
        $observed = Get-ScanReceiptField $Binding 'config'
    } elseif (($Pass -eq 'parser' -or $Pass -eq 'pre-pssa') -and $null -ne $ClientSource -and [bool]$ClientSource.Exists) {
        $source = [ordered]@{ boundary = 'client'; sha256 = [string]$ClientSource.Sha256; length = [int]$ClientSource.Length }
    }

    $receipt = [ordered]@{
        schema        = [string]$schema.Id
        schemaVersion = [int]$schema.Version
        requestId     = [string]$RequestId
        file          = [string]$File
        status        = $st
        completeness  = 'failed'
        pass          = $Pass
        reasons       = @()
        source        = $source
        daemon        = $daemon
        engine        = $engine
        config        = [ordered]@{ state = 'unbound'; observed = $observed }
        policy        = $(if ($null -ne $PolicyEvidence) { [ordered]@{ state = 'observed'; client = $PolicyEvidence; daemon = $daemonPolicy } } else { [ordered]@{ state = 'unbound' } })
        diagnostics   = (Get-ScanDiagnosticsDigest -Records @($Records))
        formatMode    = [string]$FormatMode
        elapsedMs     = [Math]::Max(0, [int]$ElapsedMs)
        detail        = [string]$Detail
        producedAt    = (Get-Date).ToUniversalTime().ToString('o')
        producer      = [ordered]@{
            plugin  = [string](Get-PluginVersion)
            edition = [string]$PSVersionTable.PSEdition
            version = [string]$PSVersionTable.PSVersion
        }
    }
    $receipt['reasons'] = @($Reasons | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
    $all = @(@($receipt['reasons']) + @(Get-ScanReceiptDerivedReasons -Receipt $receipt) | Sort-Object -Unique)
    $receipt['reasons'] = @($all)
    $receipt['completeness'] = Get-ScanCompletenessFromReasons -Reasons $all
    return $receipt
}

function Write-ScanReceipt {
    # Write a receipt ATOMICALLY: to a temp file beside the target, then a rename, so a crash leaves
    # no receipt rather than half of one. Never overwrites (the scanner mints a fresh path per
    # request; a path that already exists is not this request's). The scan's receipt directory is
    # created owner-only (New-ContainedDirectory), which contains the file on POSIX without a chmod
    # per receipt. Returns $true on success; never throws and writes nothing to any stream.
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Receipt)
    $tmp = ''
    try {
        if (-not [System.IO.Path]::IsPathRooted($Path)) { return $false }
        $dir = [System.IO.Path]::GetDirectoryName($Path)
        if ([string]::IsNullOrWhiteSpace($dir) -or -not (Test-Path -LiteralPath $dir -PathType Container)) { return $false }
        if (Test-Path -LiteralPath $Path) { return $false }
        $json = $Receipt | ConvertTo-Json -Depth 8 -Compress
        $tmp = $Path + '.' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::Move($tmp, $Path)
        $tmp = ''
        return $true
    } catch {
        return $false
    } finally {
        if (-not [string]::IsNullOrWhiteSpace($tmp)) {
            try { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } } catch { }
        }
    }
}

# --- the validator (scanner side) -------------------------------------------------

function Read-ScanReceiptFile {
    # Read and parse one receipt file. Returns @{ Present; Text; Object; Problem } where Problem is
    # '' (parsed), 'receipt-truncated' (the text stops before its JSON does) or 'receipt-malformed'.
    param([string]$Path)
    $r = [pscustomobject]@{ Present = $false; Text = ''; Object = $null; Problem = '' }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $r }
    $r.Present = $true
    try { $r.Text = [System.IO.File]::ReadAllText($Path) } catch { $r.Problem = 'receipt-malformed'; return $r }
    $trimmed = ([string]$r.Text).Trim()
    if ($trimmed -eq '') { $r.Problem = 'receipt-truncated'; return $r }
    try { $r.Object = $trimmed | ConvertFrom-Json } catch { $r.Object = $null }
    if ($null -eq $r.Object -or $r.Object -is [string] -or $r.Object -is [System.ValueType] -or $r.Object -is [System.Array]) {
        $r.Object = $null
        $r.Problem = $(if ($trimmed.StartsWith('{') -and -not $trimmed.EndsWith('}')) { 'receipt-truncated' } else { 'receipt-malformed' })
    }
    return $r
}

function Get-ScanReceiptShapeProblems {
    # The STRUCTURAL check: every field present, typed and inside its vocabulary. Returns the list of
    # problems; empty means the envelope is valid -- which on its own certifies nothing (see
    # Get-ScanReceiptDerivedReasons). Mirrors docs/scan-receipt.schema.json, which a test holds to
    # this function, so a host without Test-Json (Windows PowerShell 5.1) validates the same shape.
    param($Receipt)
    $p = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Receipt) { $p.Add('no receipt object'); return @($p.ToArray()) }
    foreach ($k in @('schema', 'schemaVersion', 'requestId', 'file', 'status', 'completeness', 'pass', 'reasons',
            'source', 'daemon', 'engine', 'config', 'policy', 'diagnostics', 'formatMode', 'elapsedMs')) {
        if (-not (Test-ScanReceiptHasField -Object $Receipt -Name $k)) { $p.Add('missing field: ' + $k) }
    }
    if ($p.Count -gt 0) { return @($p.ToArray()) }
    $schema = Get-ScanReceiptSchema
    if ([string](Get-ScanReceiptField $Receipt 'schema') -cne [string]$schema.Id) { $p.Add('schema is not ' + [string]$schema.Id) }
    $sv = Get-ScanReceiptField $Receipt 'schemaVersion'
    if (-not (Test-ScanReceiptInt $sv 1) -or [int]$sv -ne [int]$schema.Version) { $p.Add('schemaVersion is not ' + [int]$schema.Version) }
    if ([string](Get-ScanReceiptField $Receipt 'requestId') -cnotmatch '^[0-9a-f]{32}$') { $p.Add('requestId is not 32 lower-case hex') }
    if ([string]::IsNullOrWhiteSpace([string](Get-ScanReceiptField $Receipt 'file'))) { $p.Add('file is empty') }
    if ((Get-ScanReceiptStatusTokens) -cnotcontains [string](Get-ScanReceiptField $Receipt 'status')) { $p.Add('status is not a public status token') }
    if (@('complete', 'partial', 'failed') -cnotcontains [string](Get-ScanReceiptField $Receipt 'completeness')) { $p.Add('completeness is not complete/partial/failed') }
    if ((Get-ScanReceiptPasses) -cnotcontains [string](Get-ScanReceiptField $Receipt 'pass')) { $p.Add('pass is not a known pass') }
    $reasons = Get-ScanReceiptField $Receipt 'reasons'
    $table = Get-ScanReceiptReasonTable
    if (-not ($reasons -is [System.Array] -or $reasons -is [System.Collections.IList])) { $p.Add('reasons is not an array') }
    else {
        foreach ($r in @($reasons)) {
            if (-not ($r -is [string]) -or -not $table.Contains([string]$r)) { $p.Add('unknown reason: ' + [string]$r) }
        }
    }
    $src = Get-ScanReceiptField $Receipt 'source'
    if ($null -eq $src) { $p.Add('source is missing') }
    else {
        if (@('daemon', 'client', 'none') -cnotcontains [string](Get-ScanReceiptField $src 'boundary')) { $p.Add('source.boundary is not daemon/client/none') }
        $sha = [string](Get-ScanReceiptField $src 'sha256')
        if ($sha -ne '' -and $sha -cnotmatch '^[0-9a-f]{64}$') { $p.Add('source.sha256 is not 64 lower-case hex') }
        if (-not (Test-ScanReceiptInt (Get-ScanReceiptField $src 'length') 0)) { $p.Add('source.length is not a non-negative integer') }
    }
    $d = Get-ScanReceiptField $Receipt 'daemon'
    if ($null -ne $d) {
        foreach ($k in @('requestId', 'path')) { if (-not ((Get-ScanReceiptField $d $k) -is [string])) { $p.Add('daemon.' + $k + ' is not a string') } }
        foreach ($k in @('settled', 'pssaAvailable', 'cached', 'scopeApplied')) { if (-not ((Get-ScanReceiptField $d $k) -is [bool])) { $p.Add('daemon.' + $k + ' is not a boolean') } }
        foreach ($k in @('omitted', 'analysisMs')) { if (-not (Test-ScanReceiptInt (Get-ScanReceiptField $d $k) 0)) { $p.Add('daemon.' + $k + ' is not a non-negative integer') } }
    }
    $e = Get-ScanReceiptField $Receipt 'engine'
    if ($null -eq $e) { $p.Add('engine is missing') }
    else {
        foreach ($k in @('pses', 'pssa', 'daemonPlugin', 'daemonHost')) {
            if ([string]::IsNullOrWhiteSpace([string](Get-ScanReceiptField $e $k))) { $p.Add('engine.' + $k + ' is empty (say unknown)') }
        }
    }
    $c = Get-ScanReceiptField $Receipt 'config'
    if ([string](Get-ScanReceiptField $c 'state') -cne 'unbound') { $p.Add('config.state is not unbound (no declared environment is bound in this schema version)') }
    $pol = Get-ScanReceiptField $Receipt 'policy'
    $polState = [string](Get-ScanReceiptField $pol 'state')
    if ((Get-ScanReceiptPolicyStates) -cnotcontains $polState) {
        $p.Add('policy.state is not unbound/observed (a receipt carries policy evidence; it never certifies a policy)')
    } elseif ($polState -ceq 'observed') {
        foreach ($sp in @(Get-ScanReceiptPolicyEvidenceProblems -Policy $pol)) { $p.Add([string]$sp) }
    }
    $dg = Get-ScanReceiptField $Receipt 'diagnostics'
    if ($null -eq $dg) { $p.Add('diagnostics is missing') }
    else {
        if (-not (Test-ScanReceiptInt (Get-ScanReceiptField $dg 'count') 0)) { $p.Add('diagnostics.count is not a non-negative integer') }
        if ([string](Get-ScanReceiptField $dg 'digest') -cnotmatch '^[0-9a-f]{64}$') { $p.Add('diagnostics.digest is not 64 lower-case hex') }
    }
    if (-not ((Get-ScanReceiptField $Receipt 'formatMode') -is [string])) { $p.Add('formatMode is not a string') }
    if (-not (Test-ScanReceiptInt (Get-ScanReceiptField $Receipt 'elapsedMs') 0)) { $p.Add('elapsedMs is not a non-negative integer') }
    return @($p.ToArray())
}

function Get-ScanReceiptPolicyEvidenceProblems {
    # The STRUCTURAL check of an 'observed' policy block (dispatch 000305, B1): types only. What the
    # evidence MEANS -- whether the identities agree, whether RequiredRules activated -- is the managed
    # scan's decision (Test-ScanPolicyCertification in scripts/lib/lsp-policy.ps1), not this check's.
    # client and daemon may each be null (a request the daemon never answered has no daemon record);
    # when present, every field must be there with its type, so the decision never reads a guess.
    # Mirrors the policy definitions in docs/scan-receipt.schema.json.
    param($Policy)
    $p = New-Object System.Collections.Generic.List[string]
    foreach ($k in @('client', 'daemon')) {
        if (-not (Test-ScanReceiptHasField -Object $Policy -Name $k)) { $p.Add('policy.' + $k + ' is missing (null when not recorded)') }
    }
    if ($p.Count -gt 0) { return @($p.ToArray()) }
    $hex = '^([0-9a-f]{64})?$'
    foreach ($party in @('client', 'daemon')) {
        $e = Get-ScanReceiptField $Policy $party
        if ($null -eq $e) { continue }
        $res = Get-ScanReceiptField $e 'resolution'
        if ($null -eq $res) { $p.Add('policy.' + $party + '.resolution is missing'); continue }
        foreach ($k in @('path', 'reason', 'effectiveSha256')) {
            if (-not ((Get-ScanReceiptField $res $k) -is [string])) { $p.Add('policy.' + $party + '.resolution.' + $k + ' is not a string') }
        }
        foreach ($k in @('configured', 'usable')) {
            if (-not ((Get-ScanReceiptField $res $k) -is [bool])) { $p.Add('policy.' + $party + '.resolution.' + $k + ' is not a boolean') }
        }
        if ([string](Get-ScanReceiptField $res 'effectiveSha256') -cnotmatch $hex) { $p.Add('policy.' + $party + '.resolution.effectiveSha256 is not empty or 64 lower-case hex') }
    }
    $c = Get-ScanReceiptField $Policy 'client'
    if ($null -ne $c) {
        if (-not ((Get-ScanReceiptField $c 'mode') -is [string])) { $p.Add('policy.client.mode is not a string') }
        if (-not ((Get-ScanReceiptField $c 'failClosed') -is [bool])) { $p.Add('policy.client.failClosed is not a boolean') }
        foreach ($k in @('dropped', 'restamped', 'prohibitedFlagged')) {
            if (-not (Test-ScanReceiptInt (Get-ScanReceiptField $c $k) 0)) { $p.Add('policy.client.' + $k + ' is not a non-negative integer') }
        }
    }
    $d = Get-ScanReceiptField $Policy 'daemon'
    if ($null -ne $d) {
        $rr = Get-ScanReceiptField $d 'requiredRules'
        if ($null -eq $rr) { $p.Add('policy.daemon.requiredRules is missing') }
        else {
            foreach ($k in @('state', 'mergedSettingsPath', 'mergedSettingsSha256')) {
                if (-not ((Get-ScanReceiptField $rr $k) -is [string])) { $p.Add('policy.daemon.requiredRules.' + $k + ' is not a string') }
            }
            if (-not (Test-ScanReceiptInt (Get-ScanReceiptField $rr 'count') 0)) { $p.Add('policy.daemon.requiredRules.count is not a non-negative integer') }
            if ([string](Get-ScanReceiptField $rr 'mergedSettingsSha256') -cnotmatch $hex) { $p.Add('policy.daemon.requiredRules.mergedSettingsSha256 is not empty or 64 lower-case hex') }
            $g = Get-ScanReceiptField $rr 'guard'
            if ($null -eq $g) { $p.Add('policy.daemon.requiredRules.guard is missing') }
            else {
                foreach ($k in @('verifiedFor', 'observed', 'result')) {
                    if (-not ((Get-ScanReceiptField $g $k) -is [string])) { $p.Add('policy.daemon.requiredRules.guard.' + $k + ' is not a string') }
                }
            }
        }
        $st = Get-ScanReceiptField $d 'settings'
        if ($null -eq $st) { $p.Add('policy.daemon.settings is missing') }
        else {
            foreach ($k in @('path', 'source', 'sha256')) {
                if (-not ((Get-ScanReceiptField $st $k) -is [string])) { $p.Add('policy.daemon.settings.' + $k + ' is not a string') }
            }
            if (-not ((Get-ScanReceiptField $st 'delivered') -is [bool])) { $p.Add('policy.daemon.settings.delivered is not a boolean') }
            if ([string](Get-ScanReceiptField $st 'sha256') -cnotmatch $hex) { $p.Add('policy.daemon.settings.sha256 is not empty or 64 lower-case hex') }
        }
    }
    return @($p.ToArray())
}

function Test-ScanReceipt {
    # SCANNER SIDE: the verdict on one file. Combines what the scanner itself observed -- how the
    # child ended, the source bytes before and after it -- with the receipt the child left, and
    # returns the completeness the evidence supports. Never throws.
    #   -Path          the receipt path the scanner minted for this request
    #   -RequestId     the request id it minted
    #   -FilePath      the normalized path it asked about
    #   -PreSnapshot / -PostSnapshot  Read-ScanSourceSnapshot before and after the child
    #   -Child         the typed child result (Invoke-ScanChildProcess)
    #   -Records       the finding records the scanner read back for this file
    # Returns @{ Present; Valid; Completeness; Status; Pass; Reasons; Problems; Certification; Receipt }.
    # Valid means a structurally valid receipt for THIS request and file; Completeness is the verdict,
    # and only 'complete' is reported analyzed.
    param(
        [string]$Path,
        [string]$RequestId,
        [string]$FilePath,
        $PreSnapshot = $null,
        $PostSnapshot = $null,
        $Child = $null,
        [object[]]$Records = @()
    )
    $reasons = New-Object System.Collections.Generic.List[string]
    $problems = New-Object System.Collections.Generic.List[string]

    # 1. How the child ended (scanner-observed).
    $killed = $false
    if ($null -ne $Child) {
        $killed = [bool]$Child.Killed
        if ($killed) {
            $reasons.Add('deadline-kill')
            if (-not [bool]$Child.Exited) { $reasons.Add('kill-unverified') }
        } elseif ($null -ne $Child.ExitCode -and [int]$Child.ExitCode -ne 0) {
            $reasons.Add('child-nonzero-exit')
        }
    }

    # 2. The source bytes as the scanner saw them.
    $preOk = ($null -ne $PreSnapshot -and [bool]$PreSnapshot.Exists)
    $postOk = ($null -ne $PostSnapshot -and [bool]$PostSnapshot.Exists)
    $sourceState = 'unbound'
    if (($null -ne $PreSnapshot -and -not $preOk) -or ($null -ne $PostSnapshot -and -not $postOk)) {
        $reasons.Add('source-vanished'); $sourceState = 'vanished'
    } elseif ($preOk -and $postOk -and [string]$PreSnapshot.Sha256 -cne [string]$PostSnapshot.Sha256) {
        $reasons.Add('source-changed'); $sourceState = 'changed'
    }

    # 3. The receipt.
    $file = Read-ScanReceiptFile -Path $Path
    $receipt = $null
    $valid = $false
    $status = 'incomplete'
    $pass = 'none'
    $engineState = 'unknown'
    $policyState = 'unbound'
    if (-not $file.Present) {
        $reasons.Add('receipt-missing')
        if ($null -ne $Child -and -not $killed -and $null -ne $Child.ExitCode -and [int]$Child.ExitCode -eq 0) {
            if (-not [string]::IsNullOrWhiteSpace([string]$Child.StdErr)) { $reasons.Add('child-stderr-only') }
            elseif ([string]::IsNullOrWhiteSpace([string]$Child.StdOut)) { $reasons.Add('child-silent-exit') }
        }
    } elseif ($file.Problem -ne '') {
        $reasons.Add($file.Problem)
    } else {
        $receipt = $file.Object
        foreach ($sp in @(Get-ScanReceiptShapeProblems -Receipt $receipt)) { $problems.Add([string]$sp) }
        if ($problems.Count -gt 0) {
            $reasons.Add('receipt-malformed')
        } else {
            if ([string](Get-ScanReceiptField $receipt 'requestId') -cne [string]$RequestId) { $reasons.Add('correlation-mismatch') }
            if ([string](Get-ScanReceiptField $receipt 'file') -cne [string]$FilePath) { $reasons.Add('path-mismatch') }
            $valid = ($reasons -notcontains 'correlation-mismatch' -and $reasons -notcontains 'path-mismatch')
            $status = [string](Get-ScanReceiptField $receipt 'status')
            $pass = [string](Get-ScanReceiptField $receipt 'pass')

            # Re-derive from the receipt's own facts; refuse one that claims more than they allow. (The
            # field is assigned before it is wrapped -- see Get-ScanReceiptDerivedReasons.)
            $declaredRaw = Get-ScanReceiptField $receipt 'reasons'
            $declared = @(@($declaredRaw) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
            $derived = @(Get-ScanReceiptDerivedReasons -Receipt $receipt)
            $missing = @($derived | Where-Object { $declared -notcontains $_ })
            $all = @(@($declared) + @($derived) | Sort-Object -Unique)
            $allowed = Get-ScanCompletenessFromReasons -Reasons $all
            if ($missing.Count -gt 0 -or [string](Get-ScanReceiptField $receipt 'completeness') -cne $allowed) {
                $reasons.Add('receipt-inconsistent')
                if ($missing.Count -gt 0) { $problems.Add('declared reasons omit: ' + ($missing -join ', ')) }
                if ([string](Get-ScanReceiptField $receipt 'completeness') -cne $allowed) {
                    $problems.Add('declared completeness ' + [string](Get-ScanReceiptField $receipt 'completeness') + ' but its facts allow ' + $allowed)
                }
            }
            foreach ($r in $all) { $reasons.Add([string]$r) }

            # The bytes the daemon consumed against the bytes on disk.
            $src = Get-ScanReceiptField $receipt 'source'
            $rsha = [string](Get-ScanReceiptField $src 'sha256')
            if ($pass -eq 'pssa' -and [string](Get-ScanReceiptField $src 'boundary') -eq 'daemon' -and $rsha -ne '' -and $sourceState -eq 'unbound') {
                if ($preOk -and $postOk) {
                    if ($rsha -ceq [string]$PreSnapshot.Sha256) { $sourceState = 'bound' }
                    else { $reasons.Add('source-mismatch'); $sourceState = 'mismatch' }
                }
            }

            # The findings read back against the findings the receipt vouches for.
            $dg = Get-ScanReceiptField $receipt 'diagnostics'
            $mine = Get-ScanDiagnosticsDigest -Records @($Records)
            if ([int](Get-ScanReceiptField $dg 'count') -ne [int]$mine.count -or [string](Get-ScanReceiptField $dg 'digest') -cne [string]$mine.digest) {
                $reasons.Add('diagnostics-mismatch')
                $problems.Add('receipt vouches for ' + [int](Get-ScanReceiptField $dg 'count') + ' finding(s); ' + [int]$mine.count + ' read back')
            }

            $eng = Get-ScanReceiptField $receipt 'engine'
            if ([string](Get-ScanReceiptField $eng 'pses') -ne 'unknown' -and [string](Get-ScanReceiptField $eng 'pssa') -ne 'unknown') { $engineState = 'observed' }
            # Policy evidence present or not (dispatch 000305) -- 'observed' is evidence, never a
            # certification; only a managed scan certifies, from this evidence.
            $policyState = [string](Get-ScanReceiptField (Get-ScanReceiptField $receipt 'policy') 'state')
        }
    }

    $final = @($reasons.ToArray() | Sort-Object -Unique)
    $completeness = Get-ScanCompletenessFromReasons -Reasons $final
    if ($sourceState -eq 'unbound' -and $completeness -eq 'complete') {
        # Belt and braces: complete REQUIRES bytes the scanner could tie to the daemon's.
        $final = @(@($final) + 'source-unbound' | Sort-Object -Unique)
        $completeness = 'failed'
    }
    return [pscustomobject]@{
        Present       = [bool]$file.Present
        Valid         = $valid
        Completeness  = $completeness
        Status        = $status
        Pass          = $pass
        Reasons       = @($final)
        Problems      = @($problems.ToArray())
        Certification = [pscustomobject]@{
            Analysis = $completeness
            Source   = $sourceState
            Engine   = $engineState
            Config   = 'unbound'
            Policy   = $policyState
        }
        Receipt       = $receipt
    }
}
