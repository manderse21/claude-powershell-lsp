#Requires -Version 5.1

# lsp-scan-common.ps1 -- shared helpers for the standalone SARIF / CI scan entry
# point (scripts/lsp-scan.ps1, dispatch 000057, PL-5). Dot-sourced by the entry point
# AND the SARIF-scan test. Defines functions only; no side effects on import. ASCII-only
# (PS 5.1 reads a UTF-8-without-BOM file through Windows-1252; keep to bytes 0x00-0x7F --
# "--" not an em-dash, straight quotes only). StrictMode-safe.
#
# THE ONE-ENGINE INVARIANT (dispatch 000057): the CI scan's findings come from the EXACT
# same analysis path as the in-agent PostToolUse hook -- this module NEVER reimplements
# rule logic. It brings up the real warm daemon (scripts/session-start.ps1) and runs the
# real scripts/lsp-client.ps1 per file, reading back the structured records the tool tees
# through its own capture channel (POWERSHELL_LSP_DOGFOOD_LOG), redirected to a hermetic
# throwaway file per run -- NEVER the repo dogfood log. This is the SAME derivation the
# diagnostic-correctness corpus (tests/corpus/Corpus.Common.ps1) uses to prove the tool's
# findings, so a divergence between in-agent and in-CI is a corpus regression caught in
# CI, not a silent defect. No second PSScriptAnalyzer acquisition path and no pinned-hash
# change: the daemon vendors PSSA via the existing ensure-pssa.ps1 (000046 L2), unchanged.
#
# THE VERDICT IS A RECEIPT (dispatch 000304, A2). Whether a file was analyzed is no longer
# inferred from what the child did NOT say: the client writes a typed completion receipt in scan
# mode (scripts/lib/lsp-scan-receipt.ps1), and Invoke-ScanFileDiagnostics reports a file analyzed
# only when that receipt validates as COMPLETE for this request, this file and these bytes. The
# findings still come from the capture transport above; the receipt binds their count and digest.
# REQUIRES scripts/lib/lsp-scan-receipt.ps1 to be dot-sourced by the caller (scripts/lsp-scan.ps1
# does): a library may not dot-source at top level (tests/PowerShellLsp.LibPurity.Tests.ps1), and
# Invoke-ScanFileDiagnostics refuses to run without the validator rather than guess.
#
# Author: Mike Andersen / powershell-lsp plugin.

$script:LspScanCommonDir = $PSScriptRoot
# Get-Prop, Add-ProcessArguments, Resolve-PsHost, ConvertTo-FileUri, Get-PluginVersion.
. (Join-Path $script:LspScanCommonDir 'lsp-common.ps1')

# --- target enumeration ----------------------------------------------------

function Get-ScanPowerShellExtensions {
    # The EXACT file-type set the in-agent hook handles (lsp-client.ps1): .ps1/.psm1/.psd1.
    # Single source so the entry point, this module, and the tests can never disagree about
    # which files are analyzed. Other extensions are skipped (never analyzed, never a finding).
    return @('.ps1', '.psm1', '.psd1')
}

function Get-ScanTargets {
    # Resolve a scan path (a single file OR a directory) into the set of PowerShell files to
    # analyze, the count of non-PowerShell files skipped, and the scan root (the base for SARIF
    # relative URIs). A directory recurses by default; pass -Recurse:$false for top-level only.
    # Only .ps1/.psm1/.psd1 are returned; every other file is counted in Skipped and otherwise
    # ignored (the documented behavior: analyze the types the tool handles, skip the rest).
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [bool]$Recurse = $true
    )
    $exts = Get-ScanPowerShellExtensions
    $full = $Path
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { $full = $Path }
    $result = @{ Files = @(); Skipped = 0; Root = $full }
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        $result['Root'] = [System.IO.Path]::GetDirectoryName($full)
        $ext = [System.IO.Path]::GetExtension($full).ToLowerInvariant()
        if ($exts -contains $ext) { $result['Files'] = @($full) } else { $result['Skipped'] = 1 }
        return $result
    }
    if (Test-Path -LiteralPath $full -PathType Container) {
        $all = @(Get-ChildItem -LiteralPath $full -File -Recurse:$Recurse -ErrorAction SilentlyContinue)
        $ps = New-Object System.Collections.ArrayList
        $skip = 0
        foreach ($f in $all) {
            $ext = [System.IO.Path]::GetExtension($f.Name).ToLowerInvariant()
            if ($exts -contains $ext) { [void]$ps.Add($f.FullName) } else { $skip++ }
        }
        $result['Files'] = @(@($ps) | Sort-Object)
        $result['Skipped'] = $skip
        return $result
    }
    return $result   # path does not exist -> empty set; the caller surfaces a loud error
}

function Get-ScanRelativeUri {
    # A SARIF artifactLocation.uri: the file path relative to the scan root, with forward
    # slashes (the SARIF + GitHub code-scanning convention). A file under the root yields a
    # root-relative path; a file outside the root (or no root) yields the absolute path with
    # forward slashes. Never throws.
    param([string]$FilePath, [string]$Root)
    $full = $FilePath
    try { $full = [System.IO.Path]::GetFullPath($FilePath) } catch { $full = $FilePath }
    $rootFull = ''
    if (-not [string]::IsNullOrWhiteSpace($Root)) {
        try { $rootFull = [System.IO.Path]::GetFullPath($Root) } catch { $rootFull = '' }
    }
    $rel = $full
    if (-not [string]::IsNullOrWhiteSpace($rootFull)) {
        $sep = [System.IO.Path]::DirectorySeparatorChar
        $alt = [System.IO.Path]::AltDirectorySeparatorChar
        $rootTrim = $rootFull.TrimEnd($sep, $alt)
        if ($full.StartsWith($rootTrim + $sep, [System.StringComparison]::OrdinalIgnoreCase)) {
            $rel = $full.Substring($rootTrim.Length + 1)
        } elseif ([string]::Equals($full, $rootTrim, [System.StringComparison]::OrdinalIgnoreCase)) {
            $rel = [System.IO.Path]::GetFileName($full)
        }
    }
    return ($rel -replace '\\', '/')
}

# --- SARIF 2.1.0 assembly (honest severity mapping) ------------------------
# Severity-to-SARIF-level mapping (dispatch 000057 OQ2 -- map honestly, never inflate or
# deflate). The tool's diagnostic severities are Error / Warning / Information / Hint
# (ConvertTo-DiagRecord in lsp-common.ps1) plus parser 'Error'. SARIF 2.1.0 defines exactly
# four result levels: error, warning, note, none. The mapping is one-to-one where SARIF has
# a matching level (Error->error, Warning->warning); the ONLY fold is Information AND Hint
# -> note, because SARIF has no separate "info"/"hint" level below warning -- note is its
# least-alarming non-suppressed level. Nothing is mapped to 'none' (which suppresses a
# result from code-scanning views): an unknown severity maps to 'warning', so a finding is
# never silently dropped by a mapping gap. Documented in CHANGELOG.md and README.md.

function Get-ScanSeverityRank {
    # Rank a SARIF level for threshold comparison: LOWER means MORE severe, so an at-or-above
    # test is a single `-le`. 99 is the never-gates rank for a level outside the ordered set
    # ('none', or an unmappable value) -- it can never satisfy `-le` against any real threshold.
    param([string]$SarifLevel)
    switch (([string]$SarifLevel).ToLowerInvariant()) {
        'error'   { return 1 }
        'warning' { return 2 }
        'note'    { return 3 }
        default   { return 99 }
    }
}

function Get-FailExitCode {
    # The -FailOn exit-code policy (dispatch 000057; moved here from lsp-scan.ps1 by dispatch
    # 000127 so the policy is unit-testable as a PURE function -- lsp-scan.ps1 runs a scan on
    # dot-source, so a matrix test could not reach it in place. Behavior is unchanged: the
    # script dot-sources this library, and the default 'none' still never gates).
    #
    # Returns 2 when ANY finding's SARIF level is at or above $FailOn, else 0. 'none' (the
    # default) never gates: absent the parameter, the exit code is exactly what it has been
    # since 000057 -- the SARIF-upload pattern is to emit and let code scanning surface.
    param([object[]]$Findings, [string]$FailOn)
    if ($FailOn -eq 'none') { return 0 }
    $threshold = Get-ScanSeverityRank $FailOn
    foreach ($f in @($Findings)) {
        $rank = Get-ScanSeverityRank (ConvertTo-SarifLevel ([string](Get-Prop $f 'severity')))
        if ($rank -le $threshold) { return 2 }
    }
    return 0
}

function ConvertTo-SarifLevel {
    param([string]$Severity)
    switch (([string]$Severity).ToLowerInvariant()) {
        'error'       { return 'error' }
        'warning'     { return 'warning' }
        'information' { return 'note' }
        'hint'        { return 'note' }
        default       { return 'warning' }
    }
}

function Get-ScanRuleKey {
    # The stable rule id for a finding, used for BOTH the SARIF rule table (driver.rules[].id)
    # and each result's ruleId so they always agree. Prefer the analyzer rule code (ruleId);
    # fall back to the source label (e.g. 'parser') when a finding has no rule code; finally
    # 'powershell-lsp'. Never empty (an empty ruleId weakens a SARIF result).
    param($Finding)
    $ruleId = [string](Get-Prop $Finding 'ruleId')
    if (-not [string]::IsNullOrWhiteSpace($ruleId)) { return $ruleId }
    $src = [string](Get-Prop $Finding 'source')
    if (-not [string]::IsNullOrWhiteSpace($src)) { return $src }
    return 'powershell-lsp'
}

function New-SarifResult {
    # One SARIF result object for a single finding. Line/col are clamped to >= 1 (SARIF region
    # numbers are 1-based and must be positive; the tool already emits 1-based, this is a
    # defensive floor). message.text falls back to the rule key when a finding carries no
    # message, so a result is never empty-texted.
    param($Finding, [int]$RuleIndex, [string]$RelativeUri, [string]$RuleKey)
    $line = 1
    $lv = Get-Prop $Finding 'line'; if ($null -ne $lv -and [int]$lv -ge 1) { $line = [int]$lv }
    $col = 1
    $cv = Get-Prop $Finding 'col'; if ($null -ne $cv -and [int]$cv -ge 1) { $col = [int]$cv }
    $sev = [string](Get-Prop $Finding 'severity')
    $msg = [string](Get-Prop $Finding 'message')
    if ([string]::IsNullOrWhiteSpace($msg)) { $msg = [string]$RuleKey }
    return [ordered]@{
        ruleId    = [string]$RuleKey
        ruleIndex = [int]$RuleIndex
        level     = (ConvertTo-SarifLevel $sev)
        message   = [ordered]@{ text = $msg }
        locations = @(
            [ordered]@{
                physicalLocation = [ordered]@{
                    artifactLocation = [ordered]@{ uri = [string]$RelativeUri; uriBaseId = 'SRCROOT' }
                    region           = [ordered]@{ startLine = $line; startColumn = $col }
                }
            }
        )
    }
}

# Bounded enumeration cap for not-analyzed file names surfaced to CI (the SARIF invocation
# notifications and the incomplete-scan stderr line). scripts/ holds ~two dozen PowerShell
# files, so a realistic INCOMPLETE names every unanalyzed file; the cap only engages on a
# pathological large-tree scan, where it shows the first $Cap (sorted) names and states the
# total. Text mode (a local, human-invoked full report) is intentionally NOT capped.
$script:ScanNotAnalyzedNameCap = 50

function Get-ScanNotAnalyzedNames {
    # Map a set of not-analyzed files to sorted, root-relative names (bounded to $Cap), each with the
    # elapsed ms it ran before the budget cut it (dispatch 000132 leg 2). ONE source so the SARIF
    # notifications and the incomplete-scan stderr line bound, order, and time the names identically.
    # Accepts EITHER bare path strings (elapsed unknown -> $null) OR objects carrying .Path (or .File),
    # .ElapsedMs and, since dispatch 000304, .Reasons (the receipt reason codes; absent -> none).
    # Returns @{
    #   Names    = <string[]> (<= Cap, sorted, forward-slash relative) -- the unchanged 000131 surface;
    #   Items    = <object[]> of @{ Name = <rel>; ElapsedMs = <int|$null>; Reasons = <string[]> }, in the
    #              same order as Names;
    #   Total    = <int>; Overflow = <int> }.
    # $Cap <= 0 means no cap (enumerate all). Blank/null entries are dropped; never throws on empty.
    param(
        [object[]]$NotAnalyzed,
        [string]$Root,
        [int]$Cap = $script:ScanNotAnalyzedNameCap
    )
    $items = New-Object System.Collections.ArrayList
    foreach ($entry in @($NotAnalyzed)) {
        if ($null -eq $entry) { continue }
        $path = ''
        $elapsed = $null
        $why = @()
        if ($entry -is [string]) {
            $path = [string]$entry
        } else {
            $path = [string](Get-Prop $entry 'Path')
            if ([string]::IsNullOrWhiteSpace($path)) { $path = [string](Get-Prop $entry 'File') }
            $ev = Get-Prop $entry 'ElapsedMs'
            if ($null -ne $ev -and "$ev" -ne '') { $elapsed = [int]$ev }
            $why = @(@(Get-Prop $entry 'Reasons') | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
        }
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        [void]$items.Add([pscustomobject]@{ Name = (Get-ScanRelativeUri -FilePath $path -Root $Root); ElapsedMs = $elapsed; Reasons = $why })
    }
    $sorted = @(@($items) | Sort-Object -Property Name)
    $total = $sorted.Count
    $shown = if ($Cap -gt 0 -and $total -gt $Cap) { @($sorted[0..($Cap - 1)]) } else { @($sorted) }
    return @{
        Names    = @(@($shown) | ForEach-Object { [string]$_.Name })
        Items    = @($shown)
        Total    = $total
        Overflow = ($total - @($shown).Count)
    }
}

function New-SarifReport {
    # Assemble a SARIF 2.1.0 log object (ready for ConvertTo-Json) from the flat finding set.
    # Each finding is expected to carry file / line / col / severity / ruleId / source / message.
    # The single run declares the tool driver (name/version/informationUri) and a deduplicated
    # rule table (reportingDescriptor[]); each result references its rule by index. A scan that
    # could not fully analyze every file is reported via invocations[].executionSuccessful=$false
    # (never a silent clean report), and each unanalyzed file is NAMED via an
    # invocations[].toolExecutionNotifications[] entry (dispatch 000131 -- diagnosability: a timeout
    # you cannot attribute to a file is one you cannot fix). That notification vehicle keeps the
    # SARIF schema-valid and is ingested as tool status by code scanning (never a spurious alert),
    # so the finding set is byte-identical to before and a COMPLETE scan grows no notifications
    # array at all. originalUriBaseIds.SRCROOT anchors the relative URIs to the scan root.
    param(
        [object[]]$Findings,
        [string]$Root,
        [string]$ToolVersion = '',
        [bool]$ExecutionSuccessful = $true,
        [object[]]$NotAnalyzed = @()
    )
    $items = @(@($Findings) | Where-Object { $null -ne $_ })
    if ([string]::IsNullOrWhiteSpace($ToolVersion)) { $ToolVersion = Get-PluginVersion }

    # Distinct rule table in first-seen order; map rule key -> index for the result references.
    $ruleOrder = New-Object System.Collections.ArrayList
    $ruleIndex = @{}
    foreach ($f in $items) {
        $key = Get-ScanRuleKey $f
        if (-not $ruleIndex.ContainsKey($key)) {
            $ruleIndex[$key] = $ruleOrder.Count
            [void]$ruleOrder.Add($key)
        }
    }
    $rules = New-Object System.Collections.ArrayList
    foreach ($key in $ruleOrder) {
        [void]$rules.Add([ordered]@{
            id               = [string]$key
            name             = [string]$key
            shortDescription = [ordered]@{ text = ('PowerShell diagnostic rule ' + [string]$key) }
        })
    }

    $results = New-Object System.Collections.ArrayList
    foreach ($f in $items) {
        $key = Get-ScanRuleKey $f
        $idx = [int]$ruleIndex[$key]
        $rel = Get-ScanRelativeUri -FilePath ([string](Get-Prop $f 'file')) -Root $Root
        [void]$results.Add((New-SarifResult -Finding $f -RuleIndex $idx -RelativeUri $rel -RuleKey $key))
    }

    $driver = [ordered]@{
        name           = 'powershell-lsp'
        version        = [string]$ToolVersion
        informationUri = 'https://github.com/manderse21/claude-powershell-lsp'
        rules          = @($rules)
    }
    $invocation = [ordered]@{ executionSuccessful = [bool]$ExecutionSuccessful }
    # Name the unanalyzed files (dispatch 000131), each WITH the elapsed ms it ran before the budget
    # cut it (dispatch 000132 leg 2 -- the elapsed rides IN the message text so the workflow annotation,
    # which echoes message.text, surfaces it for free). Only when there ARE any, so a complete scan's
    # invocation stays byte-identical to before. Each name is a SARIF toolExecutionNotification --
    # a runtime tool-status entry (NOT a result), carrying the file's SRCROOT-relative location so
    # it is navigable in code scanning without becoming a spurious alert. Bounded to the cap, with
    # a trailing summary notification when the set overflows.
    $na = Get-ScanNotAnalyzedNames -NotAnalyzed $NotAnalyzed -Root $Root
    if ($na.Total -gt 0) {
        $notifs = New-Object System.Collections.ArrayList
        foreach ($it in $na.Items) {
            $rel = [string]$it.Name
            $elapsed = $it.ElapsedMs
            $why = @($it.Reasons)
            # The receipt reason codes (dispatch 000304) ride IN the text, so the workflow annotation
            # that echoes message.text names the cause, and in a property bag, so a reader can parse
            # them. A bare-path entry carries none, and its text is byte-identical to before.
            $tail = if ($why.Count -gt 0) { ' (scan INCOMPLETE for this file; reasons: ' + ($why -join ', ') + ').' } else { ' (scan INCOMPLETE for this file).' }
            $text = if ($null -ne $elapsed) {
                'powershell-lsp: could not analyze ' + $rel + ' after ' + [int]$elapsed + 'ms' + $tail
            } else {
                'powershell-lsp: could not analyze ' + $rel + $tail
            }
            $notif = [ordered]@{
                level     = 'error'
                message   = [ordered]@{ text = $text }
                locations = @(
                    [ordered]@{
                        physicalLocation = [ordered]@{
                            artifactLocation = [ordered]@{ uri = $rel; uriBaseId = 'SRCROOT' }
                        }
                    }
                )
            }
            if ($why.Count -gt 0) { $notif['properties'] = [ordered]@{ reasons = @($why) } }
            [void]$notifs.Add($notif)
        }
        if ($na.Overflow -gt 0) {
            [void]$notifs.Add([ordered]@{
                level   = 'error'
                message = [ordered]@{ text = ('powershell-lsp: and ' + $na.Overflow + ' more file(s) could not be analyzed (' + $na.Total + ' total).') }
            })
        }
        $invocation['toolExecutionNotifications'] = @($notifs)
    }
    $run = [ordered]@{
        tool        = [ordered]@{ driver = $driver }
        results     = @($results)
        invocations = @( $invocation )
    }
    # Anchor relative URIs to the scan root so a code-scanning consumer can resolve them.
    $rootUri = ''
    try { $rootUri = ConvertTo-FileUri $Root } catch { $rootUri = '' }
    if (-not [string]::IsNullOrWhiteSpace($rootUri)) {
        if (-not $rootUri.EndsWith('/')) { $rootUri = $rootUri + '/' }
        $run['originalUriBaseIds'] = [ordered]@{ SRCROOT = [ordered]@{ uri = $rootUri } }
    }
    return [ordered]@{
        '$schema' = 'https://json.schemastore.org/sarif-2.1.0.json'
        version   = '2.1.0'
        runs      = @($run)
    }
}

function Format-ScanTextReport {
    # The human-readable text mode: one line per finding grouped by file, then a summary.
    # Mirrors the in-agent hook's rendering idiom ([Level] line N, col C -- message (label))
    # so a finding reads the same in-CI as in-agent. Returns a single multi-line string.
    # -NotAnalyzed takes bare paths or the lsp-scan.ps1 records (.Path/.ElapsedMs/.Reasons/.Completeness,
    # dispatch 000304); a record's reason codes are printed beside its name. A record whose completeness
    # is 'partial' had a VALID receipt for a partial analysis (a file that does not parse, say), and
    # says so, so it is never mistaken for a file with no receipt (owner ruling A2-Q01, 2026-10-11).
    param(
        [object[]]$Findings,
        [string]$Root,
        [int]$Skipped = 0,
        [int]$FilesScanned = 0,
        [object[]]$NotAnalyzed = @()
    )
    $items = @(@($Findings) | Where-Object { $null -ne $_ })
    $sb = New-Object System.Text.StringBuilder
    # Group by relative file path, preserving a stable (sorted) file order.
    $byFile = @{}
    foreach ($f in $items) {
        $rel = Get-ScanRelativeUri -FilePath ([string](Get-Prop $f 'file')) -Root $Root
        if (-not $byFile.ContainsKey($rel)) { $byFile[$rel] = New-Object System.Collections.ArrayList }
        [void]$byFile[$rel].Add($f)
    }
    foreach ($rel in (@($byFile.Keys) | Sort-Object)) {
        [void]$sb.AppendLine($rel + ':')
        $rows = @($byFile[$rel] | Sort-Object @{ Expression = { [int](Get-Prop $_ 'line') } }, @{ Expression = { [int](Get-Prop $_ 'col') } })
        foreach ($f in $rows) {
            $sev = [string](Get-Prop $f 'severity')
            $line = [string](Get-Prop $f 'line')
            $col = [string](Get-Prop $f 'col')
            $src = [string](Get-Prop $f 'source')
            $code = [string](Get-Prop $f 'ruleId')
            $msg = [string](Get-Prop $f 'message')
            $hasCode = $code -and ($code -ne '0')
            $label = if ($hasCode -and $src) { $src + '/' + $code } elseif ($src) { $src } else { 'parser' }
            [void]$sb.AppendLine('  [' + $sev + '] line ' + $line + ', col ' + $col + ' -- ' + $msg + ' (' + $label + ')')
        }
    }
    $fileCount = @($byFile.Keys).Count
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine($items.Count.ToString() + ' finding(s) in ' + $fileCount + ' file(s); ' +
        $FilesScanned + ' PowerShell file(s) scanned, ' + $Skipped + ' non-PowerShell file(s) skipped.')
    $na = @(@($NotAnalyzed) | Where-Object { $null -ne $_ -and -not ($_ -is [string] -and [string]::IsNullOrWhiteSpace($_)) })
    if ($na.Count -gt 0) {
        [void]$sb.AppendLine('WARNING: ' + $na.Count + ' file(s) could NOT be analyzed (no COMPLETE completion receipt -- not a clean result):')
        foreach ($entry in $na) {
            if ($entry -is [string]) { [void]$sb.AppendLine('  ' + (Get-ScanRelativeUri -FilePath $entry -Root $Root)); continue }
            $p = [string](Get-Prop $entry 'Path')
            if ([string]::IsNullOrWhiteSpace($p)) { $p = [string](Get-Prop $entry 'File') }
            $why = @(@(Get-Prop $entry 'Reasons') | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
            $partial = ([string](Get-Prop $entry 'Completeness') -eq 'partial')
            $line = '  ' + (Get-ScanRelativeUri -FilePath $p -Root $Root)
            if ($partial) {
                $line = $line + ' (valid receipt, PARTIAL analysis'
                if ($why.Count -gt 0) { $line = $line + '; reasons: ' + ($why -join ', ') }
                $line = $line + ')'
            } elseif ($why.Count -gt 0) { $line = $line + ' (reasons: ' + ($why -join ', ') + ')' }
            [void]$sb.AppendLine($line)
        }
    }
    return $sb.ToString().TrimEnd()
}

# --- one-engine derivation: drive the real hook over a real file -----------
# These wrap the real session lifecycle + PostToolUse client so the scan reuses the EXACT
# request/shape path of the in-agent hook (dispatch 000057: a SIBLING invocation, not a fork).
# They mirror tests/corpus/Corpus.Common.ps1 (the corpus's proven derivation) but are the
# production path; the SARIF-scan test cross-checks them against the committed corpus snapshots.

function Set-ScanChildFormatterOff {
    # FORMATTER-OFF CONTAINMENT for a scan child (dispatch 000304, A2 -- the narrow slice moved here
    # from A3; A3 still owns the complete declared environment). formatOnEdit=apply makes the client
    # ask the daemon to REWRITE the analyzed file and then drop the pre-rewrite findings, so a scan
    # that inherited it rewrote what it scanned and reported nothing (A1 measured it). Overriding the
    # one spelling the scan names is not enough: the option resolver (Get-RawPluginOption) accepts
    # ANY CLAUDE_PLUGIN_OPTION_* name that normalizes to the knob -- underscores stripped, case
    # ignored -- and takes the first non-blank one it enumerates, so FORMAT_ON_EDIT (or, on Linux and
    # macOS, Claude Code's own upper-cased export) would still win some runs. So EVERY spelling is
    # removed from the child's block, and exactly one is set, to off. Explicit beats a profile
    # mapping, so a profile that maps formatOnEdit=suggest resolves off as well. Edits the child's
    # ProcessStartInfo only -- never this process's environment.
    param([Parameter(Mandatory = $true)][System.Diagnostics.ProcessStartInfo]$StartInfo)
    $prefix = 'CLAUDE_PLUGIN_OPTION_'
    foreach ($name in @($StartInfo.EnvironmentVariables.Keys)) {
        $n = [string]$name
        if (-not $n.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        if (($n.Substring($prefix.Length) -replace '_', '').ToLowerInvariant() -eq 'formatonedit') {
            $StartInfo.EnvironmentVariables.Remove($n)
        }
    }
    $StartInfo.EnvironmentVariables['CLAUDE_PLUGIN_OPTION_formatOnEdit'] = 'off'
}

function Stop-ScanProcessTree {
    # Kill a timed-out scan child AND its descendants, on both Windows hosts. Process.Kill($true) --
    # the tree kill -- exists only on .NET Core 3.0+; under Windows PowerShell 5.1 the call throws a
    # MethodException, and the old `try { $p.Kill($true) } catch { }` swallowed it and killed NOTHING
    # (dispatch 000302 measured the child alive after the "kill": S7b). So: the tree kill where it
    # exists, else `taskkill /T /F` on Windows (the error preference relaxed, because 5.1 turns a
    # native command's stderr into a terminating error under Stop), and a plain Kill() last.
    param([Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process)
    $treeKilled = $false
    try { $Process.Kill($true); $treeKilled = $true } catch { $treeKilled = $false }
    if (-not $treeKilled -and (Test-OnWindows)) {
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { & taskkill.exe /PID $Process.Id /T /F *> $null } catch { } finally { $ErrorActionPreference = $prevEap }
    }
    try { if (-not $Process.HasExited) { $Process.Kill() } } catch { }
}

function ConvertTo-ScanAsciiJson {
    # A scan child's stdin payload, made independent of the console code page (dispatch 000304, review
    # A2-F01). The child decodes stdin with the input code page of the console it is attached to
    # (Get-StdinText reads [Console]::In), and that console is the scanner's -- on a stock Windows
    # console the OEM code page (437 on en-US), not UTF-8. So a non-ASCII character in a payload path
    # arrived mangled: a receipt path under a non-ASCII data root (the default one is under the user
    # profile) named a directory that does not exist, and every file read receipt-missing. Here every
    # character above 0x7F is written as a JSON escape -- a backslash, 'u' and four hex digits; a
    # character outside the BMP becomes its two UTF-16 surrogates, as JSON specifies -- so the payload
    # is pure ASCII, which every console code page decodes alike, and ConvertFrom-Json turns each escape
    # back into the same character. JSON text only: outside its string literals JSON is ASCII already,
    # so only the spelling of string contents changes. One pass on both hosts (Windows PowerShell 5.1
    # has no ConvertTo-Json -EscapeHandling), so a child receives the same bytes from either parent.
    param([string]$Json)
    if ([string]::IsNullOrEmpty($Json)) { return $Json }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Json.ToCharArray()) {
        $code = [int]$ch
        if ($code -gt 0x7F) { [void]$sb.Append('\u').Append($code.ToString('x4')) } else { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}

function Invoke-ScanChildProcess {
    # THE scan spawner (dispatch 000304, A2): every scan child -- session-start, the client per file,
    # session-end -- runs through here. It returns a TYPED record, never a bare string:
    #   ExitCode        the child's exit code; $null when a killed child never reported one
    #   StdOut, StdErr  everything each stream carried (each drained to EOF, or '' if a drain did not end)
    #   Killed          the cap expired and the tree was killed
    #   Exited          the process is gone (after the kill, if any) -- $false is a kill that failed
    #   ElapsedMs       wall-clock from start to exit (or to the kill)
    #   StdOutComplete, StdErrComplete  whether each drain reached EOF
    #   StdinError      why the payload could not be written ('' when it was)
    # BOTH streams are drained CONCURRENTLY: each ReadToEndAsync starts before stdin is written and
    # before any wait, so a child that fills one pipe can never be held to the cap by the other (the
    # old spawner redirected stderr and never read it: dispatch 000302's S3b held a finished child to
    # the cap). The process is disposed on every path. No verdict is taken from any of this: whether a
    # file was analyzed is the receipt's to say (Test-ScanReceipt); this record is the evidence about
    # how the child ended. The analysis host is ALWAYS a real PowerShell (pwsh preferred), so findings
    # are host-consistent regardless of who launched the scan.
    param(
        [Parameter(Mandatory = $true)][string]$HostExe,
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string]$StdinJson = '',
        [int]$CapMs = 25000,
        [string]$DataRoot = '',
        [string[]]$ExtraArgs = @(),
        [hashtable]$ExtraEnv
    )
    # THE PAYLOAD IS ASCII (ConvertTo-ScanAsciiJson, below): the child decodes stdin with the code page
    # of the console it inherits, which is this process's -- often an OEM code page, not UTF-8 -- so
    # only an ASCII payload reaches it intact whatever that code page is (dispatch 000304, A2-F01).
    # NO CreateNoWindow either, for a different reason: a Windows PowerShell 5.1 parent's StandardInput
    # writer uses the console's input encoding, so on a UTF-8 console it writes a UTF-8 BOM ahead of
    # the payload (measured: EF BB BF first, although the payload itself goes to the raw stream). A
    # child sharing that console decodes it as UTF-8 and Get-StdinText strips the U+FEFF; a child given
    # a NEW console (437 on en-US) reads three characters nothing strips, and no payload parses.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $HostExe; $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    Add-ProcessArguments $psi (@(@('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + @($ExtraArgs)) | Where-Object { $_ })
    if (-not [string]::IsNullOrWhiteSpace($DataRoot)) { $psi.EnvironmentVariables['CLAUDE_PLUGIN_DATA'] = $DataRoot }
    if ($ExtraEnv) { foreach ($k in $ExtraEnv.Keys) { $psi.EnvironmentVariables[$k] = [string]$ExtraEnv[$k] } }
    Set-ScanChildFormatterOff -StartInfo $psi
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = [System.Diagnostics.Process]::Start($psi)
    try {
        $stdoutTask = $p.StandardOutput.ReadToEndAsync()
        $stderrTask = $p.StandardError.ReadToEndAsync()
        $stdinError = ''
        try {
            if (-not [string]::IsNullOrEmpty($StdinJson)) {
                # Every non-ASCII character escaped, so the child's console code page cannot change
                # what it parses; written to the raw stream, so this side adds no BOM of its own.
                $payload = ConvertTo-ScanAsciiJson -Json $StdinJson
                $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($payload)   # no BOM
                $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
                $p.StandardInput.BaseStream.Flush()
            }
        } catch { $stdinError = $_.Exception.Message }
        try { $p.StandardInput.Close() } catch { if ($stdinError -eq '') { $stdinError = $_.Exception.Message } }
        $killed = $false
        if (-not $p.WaitForExit($CapMs)) {
            $killed = $true
            Stop-ScanProcessTree -Process $p
            try { [void]$p.WaitForExit(5000) } catch { }
        }
        $elapsed = [int]$sw.ElapsedMilliseconds
        # Both drains end at EOF once the child (and anything holding its handles) is gone. Bounded,
        # so a grandchild that inherited a handle costs a wait, never a hang.
        $drainMs = [Math]::Max(1500, [Math]::Min($CapMs, 5000))
        try { [void]$stdoutTask.Wait($drainMs) } catch { }
        try { [void]$stderrTask.Wait($drainMs) } catch { }
        $outDone = ($stdoutTask.IsCompleted -and -not $stdoutTask.IsFaulted)
        $errDone = ($stderrTask.IsCompleted -and -not $stderrTask.IsFaulted)
        $exited = $false
        try { $exited = $p.HasExited } catch { $exited = $false }
        $exitCode = $null
        if ($exited) { try { $exitCode = [int]$p.ExitCode } catch { $exitCode = $null } }
        return [pscustomobject]@{
            ExitCode       = $exitCode
            StdOut         = $(if ($outDone) { [string]$stdoutTask.Result } else { '' })
            StdErr         = $(if ($errDone) { [string]$stderrTask.Result } else { '' })
            Killed         = $killed
            Exited         = $exited
            ElapsedMs      = $elapsed
            StdOutComplete = $outDone
            StdErrComplete = $errDone
            StdinError     = $stdinError
        }
    } finally {
        try { $p.Dispose() } catch { }
    }
}

function Invoke-ScanHook {
    # COMPATIBILITY WRAPPER over Invoke-ScanChildProcess, for callers that want only a hook's stdout:
    # Start-ScanDaemon / Stop-ScanDaemon below, and the frozen pre-000301 Invoke-ScanFileDiagnostics
    # in tests/fixtures/red-controls/, which must keep running verbatim. Same parameters and return as
    # before dispatch 000304 -- the stdout text, '' on a cap kill -- so every existing caller is
    # preserved; what changed underneath is that stderr is now drained, the kill reaches the tree on
    # Windows PowerShell 5.1 too, and formatOnEdit is contained off in every child it starts.
    param(
        [string]$HostExe,
        [string]$ScriptPath,
        [string]$StdinJson,
        [int]$CapMs,
        [string]$DataRoot,
        [string[]]$ExtraArgs = @(),
        [hashtable]$ExtraEnv,
        # A [ref][bool] the caller may pass to learn whether the process was KILLED because it did
        # not exit within $CapMs (the client cap). Untyped so an omitted argument stays $null and
        # StrictMode-safe; when supplied it is set $true on the cap kill so the caller can treat a
        # killed analysis as NOT analyzed (dispatch 000132 leg 1 -- never-silent: a killed file is
        # not a clean file). The stdout return is unchanged ('' on a kill).
        $Killed = $null
    )
    $r = Invoke-ScanChildProcess -HostExe $HostExe -ScriptPath $ScriptPath -StdinJson $StdinJson -CapMs $CapMs `
        -DataRoot $DataRoot -ExtraArgs $ExtraArgs -ExtraEnv $ExtraEnv
    if ($r.Killed) {
        if ($null -ne $Killed) { $Killed.Value = $true }
        return ''
    }
    return [string]$r.StdOut
}

function Start-ScanDaemon {
    # Bring up ONE warm daemon for the whole scan via the REAL SessionStart hook, exactly as
    # the corpus does: perFileCap=0 (capture every finding, never an "and N more" elision) and
    # severityThreshold=Hint (keep all severities) so the scan's output is the tool's full,
    # faithful set, mapped honestly to SARIF afterward. Returns the daemon details object (the
    # session file once it reports state 'ready'), or $null on timeout (the caller fails loud --
    # an unready daemon must never read as a clean scan).
    # MaxWaitMs (dispatch 000133, option B -- scan-specific settle cap): the SCAN's daemon gets a larger
    # settle cap than the in-agent daemon's 5000 default, because the largest scripts (lib/lsp-common.ps1,
    # ensure-pssa.ps1) need ~6-7 s of PSSA analysis on a loaded ubuntu runner and were reported INCOMPLETE
    # at 5000 (dispatch 000132). Only the scan raises it -- a batch job with no interactive waiter absorbs
    # the longer worst case for free; the in-agent daemon keeps 5000, so edit latency is untouched (the
    # forward is INTERNAL, not a userConfig knob). Passed as an explicit arg to the real SessionStart hook,
    # the same way -PreferredHost is (session-start.ps1 does NOT self-source it from CLAUDE_PLUGIN_OPTION_*).
    # 15000 ms is sized from measurement, NOT the worst measured value: across 4 ubuntu-24.04 diagnostic runs
    # the binding file lib/lsp-common.ps1 settled at 5643-8784 ms CLIENT round-trip (~1.5 s of that is
    # spawn/connect/read overhead, so ~7.3 s worst-case daemon SETTLE), a 1.56x run-to-run swing. 15000 is
    # ~2.05x that worst settle / 1.71x the worst round-trip -- above the observed variance envelope with a
    # further safety factor for an unobserved heavier-load tail. The client caps stay strictly above it and
    # were proven non-truncating at this cap (Invoke-ScanFileDiagnostics timeoutMs 18000 < lsp-scan.ps1
    # -TimeoutMs 25000; both > 15000). Full arithmetic: the 000133 outbox and CHANGELOG.
    param([string]$ScriptsDir, [string]$DataRoot, [string]$SessionId, [string]$HostExe, [int]$MaxWaitMs = 15000)
    New-ContainedDirectory -Path $DataRoot
    Invoke-ScanHook -HostExe $HostExe -ScriptPath (Join-Path $ScriptsDir 'session-start.ps1') `
        -StdinJson (@{ session_id = $SessionId } | ConvertTo-Json -Compress) `
        -ExtraArgs @('-PreferredHost', $HostExe, '-MaxWaitMs', [string]$MaxWaitMs) -CapMs 180000 -DataRoot $DataRoot `
        -ExtraEnv @{ CLAUDE_PLUGIN_OPTION_perFileCap = '0'; CLAUDE_PLUGIN_OPTION_severityThreshold = 'Hint' } | Out-Null
    $sf = Join-Path $DataRoot ('session/' + $SessionId + '.json')
    for ($i = 0; $i -lt 200; $i++) {
        if (Test-Path -LiteralPath $sf) {
            $o = $null
            try { $o = Get-Content -LiteralPath $sf -Raw | ConvertFrom-Json } catch { $o = $null }
            if ($null -ne $o -and [string](Get-Prop $o 'state') -eq 'ready') { return $o }
        }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

function Stop-ScanDaemon {
    # Tear the scan daemon down via the REAL SessionEnd hook, then best-effort kill the recorded
    # daemon + PSES pids (mirrors the corpus teardown). Fail-safe: never throws.
    param([string]$ScriptsDir, [string]$DataRoot, [string]$SessionId, [string]$HostExe, $DaemonInfo)
    try {
        Invoke-ScanHook -HostExe $HostExe -ScriptPath (Join-Path $ScriptsDir 'session-end.ps1') `
            -StdinJson (@{ session_id = $SessionId } | ConvertTo-Json -Compress) `
            -ExtraArgs @() -CapMs 15000 -DataRoot $DataRoot | Out-Null
    } catch { }
    if ($null -ne $DaemonInfo) {
        foreach ($pidVal in @((Get-Prop $DaemonInfo 'pid'), (Get-Prop $DaemonInfo 'psesPid'))) {
            if ($pidVal) { try { Stop-Process -Id ([int]$pidVal) -Force -ErrorAction SilentlyContinue } catch { } }
        }
    }
}

function Invoke-ScanFileDiagnostics {
    # Derive the REAL tool's findings for ONE file by running the REAL lsp-client.ps1 hook over
    # it (the same engine the in-agent edit path uses), with the dogfood capture log redirected
    # to a hermetic throwaway file and whole-file scoping (scopeToEdit=false -- a scan has no
    # edit range). Reads back the structured records the tool teed and returns:
    #   @{ File; Findings = @({ file; ruleId; source; severity; line; col; message }); Analyzed; ElapsedMs;
    #      Completeness; Status; Pass; Reasons; Certification; Child }
    # ElapsedMs (dispatch 000132 leg 2) is the wall-clock the per-file hook round-trip took -- for a
    # timed-out or cap-killed file this is ~the budget it hit, the "how long did it run" a bare count
    # lacked, so an INCOMPLETE can name the file AND how long it ran before the budget cut it.
    # The file is analyzed IN PLACE so SARIF carries its real path and the repo's own
    # PSScriptAnalyzerSettings.psd1 is honored, exactly as the in-agent hook honors it (000018).
    #
    # ANALYZED COMES FROM A VALIDATED RECEIPT, NOTHING ELSE (dispatch 000304, A2). The scan used to
    # start from Analyzed=$true and flip it only on a cap kill or a 'NOT checked' banner, so seven
    # ways a child can end without analyzing anything read as a clean file (dispatch 000302). Now the
    # child is asked -- in its hook payload, under a fresh request id -- to write a completion receipt,
    # and the file is analyzed only when Test-ScanReceipt finds it COMPLETE: the right request, the
    # right file, the bytes the daemon consumed equal to the bytes on disk before and after the child,
    # the settled PSScriptAnalyzer pass, and the receipt's finding count and digest equal to the
    # records read back here. A missing, truncated, malformed, mismatched or merely partial receipt is
    # NOT analyzed, with machine reasons (Reasons) the caller names in its INCOMPLETE report. Neither
    # the hook's stdout banner nor the capture telemetry decides the verdict; they are evidence only.
    #
    # `message` on the returned finding is ALWAYS the real diagnostic text, regardless of the
    # caller's ambient POWERSHELL_LSP_CAPTURE_MODE (dispatch 000301 N6): see the CAPTURE_MODE=full
    # line inside, which forces it on the throwaway transport this function owns end to end. This
    # is the ONLY thing scripts/lsp-scan.ps1's SARIF `message.text` renders, so a caller must never
    # see it degrade to a bare rule id just because nobody set a telemetry-log env var. (A degraded
    # transport could not pass anyway now: the receipt's digest covers each message.)
    param(
        [string]$ScriptsDir,
        [string]$DataRoot,
        [string]$SessionId,
        [string]$HostExe,
        [string]$FilePath,
        [string]$Cwd = '',
        [int]$CapMs = 25000,
        [string]$CaptureDir = ''
    )
    if ($null -eq (Get-Command -Name 'Test-ScanReceipt' -CommandType Function -ErrorAction SilentlyContinue)) {
        # Never guess a verdict without the validator: dot-source scripts/lib/lsp-scan-receipt.ps1.
        throw 'Invoke-ScanFileDiagnostics: scripts/lib/lsp-scan-receipt.ps1 is not loaded (dot-source it after lsp-scan-common.ps1)'
    }
    $full = $FilePath
    try { $full = [System.IO.Path]::GetFullPath($FilePath) } catch { $full = $FilePath }
    if ([string]::IsNullOrWhiteSpace($Cwd)) { $Cwd = [System.IO.Path]::GetDirectoryName($full) }
    if ([string]::IsNullOrWhiteSpace($CaptureDir)) { $CaptureDir = Join-Path $DataRoot 'scan-capture' }
    if (-not (Test-Path -LiteralPath $CaptureDir)) { New-ContainedDirectory -Path $CaptureDir }
    $log = Join-Path $CaptureDir ('scan-' + [guid]::NewGuid().ToString('N').Substring(0, 12) + '.jsonl')

    # The completion receipt this request asks for (dispatch 000304): a fresh request id and a fresh
    # path in an owner-only directory, carried in the hook payload. The path must not pre-exist (the
    # producer never overwrites), so a stale file can never be mistaken for this request's receipt.
    $receiptDir = Join-Path $DataRoot 'scan-receipts'
    if (-not (Test-Path -LiteralPath $receiptDir)) { New-ContainedDirectory -Path $receiptDir }
    $requestId = New-ScanRequestId
    $receiptPath = Join-Path $receiptDir ($requestId + '.json')
    if (Test-Path -LiteralPath $receiptPath) { Remove-Item -LiteralPath $receiptPath -Force -ErrorAction SilentlyContinue }

    $stdin = ([ordered]@{
            session_id          = $SessionId
            tool_input          = @{ file_path = $full }
            cwd                 = $Cwd
            powershell_lsp_scan = (New-ScanRequestField -RequestId $requestId -ReceiptPath $receiptPath)
        } | ConvertTo-Json -Compress -Depth 4)
    # scopeToEdit=false => whole-file (a scan carries no edit patch); timeoutMs raised so a first
    # cold analysis on a slow leg still settles inside the client cap. NOTE (dispatch 000132): this
    # client-side cap is NOT the binding per-file budget -- the daemon's own settle cap (MaxWaitMs,
    # pses-daemon.ps1, default 5000) is; see the 000132 outbox and the 000133 charter. The dogfood log
    # is the SAME structured-finding channel the corpus reads, pointed at a throwaway file (never the repo log).
    #
    # CAPTURE_MODE=full is FORCED here, unconditionally, regardless of the CALLER's ambient value
    # (dispatch 000301 N6 -- a genuine product-surface defect, not a preference). $log above is a
    # TRANSPORT, not the control surface POWERSHELL_LSP_CAPTURE_MODE governs: it is a brand-new
    # per-scan temp file under DataRoot/scan-capture/, read back three lines down, then deleted --
    # never the administrator's real, persistent dogfood/diagnostics.jsonl. Before this line, this
    # function inherited whatever CAPTURE_MODE the CALLING process happened to have, which is unset
    # on essentially every real invocation of scripts/lsp-scan.ps1 (nobody runs a CI scanner with an
    # env var tuned for a fleet telemetry log they've never heard of) -- so R25's metadata default
    # silently dropped `message` from this throwaway file too, and every SARIF result's message.text
    # fell back to New-SarifResult's bare-rule-id fallback (scan-correct, but not the diagnostic
    # text). Forcing `full` here fixes that WITHOUT touching Get-DiagnosticCaptureModeInfo's shipped
    # default or the real dogfood log's fleet-visible behavior: this is a NEW key on a per-CHILD-
    # PROCESS env block (ProcessStartInfo.EnvironmentVariables), so it overrides nothing in the
    # CALLING process's own environment and cannot leak into it, and it changes the CONTENT of a
    # file that already existed and was already deleted immediately -- never where source text is
    # written, only what this one ephemeral round-trip carries before it is discarded.
    $extraEnv = @{
        POWERSHELL_LSP_DOGFOOD_LOG       = $log
        POWERSHELL_LSP_CAPTURE_MODE      = 'full'
        CLAUDE_PLUGIN_OPTION_scopeToEdit = 'false'
        CLAUDE_PLUGIN_OPTION_timeoutMs   = '18000'
    }
    # The bytes on disk BEFORE and AFTER the child: the receipt's daemon-consumed SHA-256 must equal
    # both, so a file that changed or vanished while it was being scanned can never be certified.
    $pre = Read-ScanSourceSnapshot -Path $full -NoText
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $child = Invoke-ScanChildProcess -HostExe $HostExe -ScriptPath (Join-Path $ScriptsDir 'lsp-client.ps1') `
        -StdinJson $stdin -CapMs $CapMs -DataRoot $DataRoot -ExtraEnv $extraEnv
    $sw.Stop()
    $elapsedMs = [int]$sw.Elapsed.TotalMilliseconds
    $post = Read-ScanSourceSnapshot -Path $full -NoText

    $findings = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $log) {
        foreach ($entry in @(Get-Content -LiteralPath $log)) {
            if ([string]::IsNullOrWhiteSpace($entry)) { continue }
            $o = $null
            try { $o = $entry | ConvertFrom-Json } catch { $o = $null }
            if ($null -eq $o) { continue }
            [void]$findings.Add([pscustomobject]@{
                file     = $full
                ruleId   = [string](Get-Prop $o 'ruleId')
                source   = [string](Get-Prop $o 'source')
                severity = [string](Get-Prop $o 'severity')
                line     = [int](Get-Prop $o 'line')
                col      = [int](Get-Prop $o 'col')
                message  = [string](Get-Prop $o 'message')
            })
        }
        try { Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue } catch { }
    }
    $findingList = @(@($findings) | Where-Object { $null -ne $_ })
    # Never-silent: a file is "analyzed" only with POSITIVE evidence the analysis reached a verdict --
    # a receipt Test-ScanReceipt validates as COMPLETE (dispatch 000304). A cap kill (dispatch 000132
    # leg 1), a degraded or unsettled pass, a refusal, a crash, a vanished or changed source, and a
    # child that simply said nothing all land here as NOT analyzed, each with its reason codes, so the
    # caller names the file and the scan exits 4 -- never reporting any of them as a clean file.
    $verdict = Test-ScanReceipt -Path $receiptPath -RequestId $requestId -FilePath $full `
        -PreSnapshot $pre -PostSnapshot $post -Child $child -Records $findingList
    try { if (Test-Path -LiteralPath $receiptPath) { Remove-Item -LiteralPath $receiptPath -Force -ErrorAction SilentlyContinue } } catch { }
    return [pscustomobject]@{
        File          = $full
        Findings      = $findingList
        Analyzed      = ([string]$verdict.Completeness -eq 'complete')
        ElapsedMs     = $elapsedMs
        Completeness  = [string]$verdict.Completeness
        Status        = [string]$verdict.Status
        Pass          = [string]$verdict.Pass
        Reasons       = @($verdict.Reasons)
        Certification = $verdict.Certification
        Child         = [pscustomobject]@{
            ExitCode   = $child.ExitCode
            Killed     = [bool]$child.Killed
            Exited     = [bool]$child.Exited
            StdErr     = [string]$child.StdErr
            StdinError = [string]$child.StdinError
        }
    }
}

# --- prohibitedSuppressions, repo/CI path (P1-5 remainder, R23=D member A, dispatch 000294) ---
# True re-surfacing: Invoke-ScriptAnalyzer -IncludeSuppressed, restricted to the org-prohibited
# rule set, re-surfaces a SuppressMessageAttribute-hidden finding UNDER ITS OWN rule identity --
# "true enforcement", per R23's own option-A text, at a cost this codebase's cost table
# (000292-PHASE-RECORDS.md) explicitly declined to pay on the per-edit daemon path but accepts
# here, where a scan runs once per CI invocation rather than once per keystroke. This is a
# SEPARATE, ONE-SHOT PSScriptAnalyzer pass in THIS process (lsp-scan.ps1 is itself already a
# one-shot CI process with no warm state to preserve, unlike the rest of this file's
# daemon-routed per-file loop) -- never routed through PSES, which 000292 measured never
# requests suppressed records at all and so structurally cannot carry this member.

function Resolve-ScanPssaModulePath {
    # The vendored PSScriptAnalyzer.psd1 under CLAUDE_PLUGIN_DATA/modules -- the SAME
    # bootstrap-only acquisition path this file's own header comment names (ensure-pssa.ps1,
    # dispatch 000046 L2). Returns '' when not found rather than throwing, so a missing vendor
    # copy degrades this ONE member (logged by the caller) without failing the whole scan.
    $vendor = Get-PssaModuleDir
    if (-not (Test-Path -LiteralPath $vendor)) { return '' }
    $m = Get-ChildItem -LiteralPath $vendor -Recurse -Filter 'PSScriptAnalyzer.psd1' -File -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } | Select-Object -First 1
    if ($null -eq $m) { return '' }
    return $m.FullName
}

function Invoke-ProhibitedSuppressionScan {
    # Run the restricted -IncludeSuppressed pass over $Files and return findings in the SAME
    # flat shape every other lsp-scan finding uses (file/ruleId/source/severity/line/col/message
    # -- New-SarifReport's own documented expectation), so the caller can simply append this
    # function's return value onto $allFindings with no special-casing downstream. Returns @()
    # immediately when $ProhibitedRules is empty (the knob-off default) or the vendored module
    # cannot be resolved -- BOTH degrades are fail-open (a scan that cannot run this ONE member
    # still reports every other finding) and BOTH are logged by the caller via $WarningOut, never
    # silently.
    #
    # ruleId is the REAL suppressed rule's own name (e.g. PSAvoidUsingPlainTextForPassword), not
    # a wrapper id -- this is what makes it "true enforcement" rather than a restatement of the
    # edit-path's Find-ProhibitedSuppression (which deliberately reports the SUPPRESSION under
    # its OWN id, 'ProhibitedSuppression', because the daemon cannot afford a real second pass).
    # The two members of R23=D are intentionally NOT the same shape; this is the costlier,
    # CI-affordable half named "A" in the ruling text, not a second copy of "B".
    #
    # Adversarial control: drop the SuppressedRecord type-name filter and an ORDINARY
    # (non-suppressed) finding of the same restricted rule would double-report; drop
    # -IncludeRule and the pass re-scans every installed PSSA rule per file instead of the
    # restricted set the ruling text specifically bounds cost to; use the type's own Severity
    # enum without Resolve-SeverityName and an unrecognized or future PSSA severity name would
    # surface as an unranked value instead of being rejected the way every other org-policy
    # degrade in this codebase rejects an unrecognized severity name.
    param(
        [string[]]$Files,
        [string[]]$ProhibitedRules,
        [ref]$WarningOut
    )
    $prohibited = @($ProhibitedRules | Where-Object { $_ })
    if ($prohibited.Count -eq 0) { return @() }

    $modPath = Resolve-ScanPssaModulePath
    if ([string]::IsNullOrWhiteSpace($modPath)) {
        if ($null -ne $WarningOut) { $WarningOut.Value = 'prohibitedSuppressions (repo/CI path): vendored PSScriptAnalyzer not found; this member was NOT run' }
        return @()
    }
    try {
        Import-Module -Name $modPath -Force -ErrorAction Stop
    } catch {
        if ($null -ne $WarningOut) { $WarningOut.Value = 'prohibitedSuppressions (repo/CI path): PSScriptAnalyzer import failed (' + $_.Exception.Message + '); this member was NOT run' }
        return @()
    }

    $findings = New-Object System.Collections.ArrayList
    foreach ($file in @($Files)) {
        $records = $null
        try {
            $records = @(Invoke-ScriptAnalyzer -Path $file -IncludeRule $prohibited -IncludeSuppressed -ErrorAction Stop)
        } catch {
            if ($null -ne $WarningOut) { $WarningOut.Value = 'prohibitedSuppressions (repo/CI path): analysis error on ' + $file + ' (' + $_.Exception.Message + ')' }
            continue
        }
        foreach ($r in $records) {
            $tn = ''
            try { $tn = $r.GetType().Name } catch { $tn = '' }
            if ($tn -ne 'SuppressedRecord') { continue }   # an ordinary finding of a restricted rule: not a suppression
            $ruleName = ''
            try { $ruleName = [string]$r.RuleName } catch { $ruleName = '' }
            if ([string]::IsNullOrWhiteSpace($ruleName)) { continue }
            $sevRaw = ''
            try { $sevRaw = [string]$r.Severity } catch { $sevRaw = '' }
            $sev = Resolve-SeverityName $sevRaw
            if ($sev -eq '') { $sev = 'Warning' }   # PSSA's own Severity is never 'Hint' (no such PSSA level); default stays conservative
            $line = 1; $col = 1
            try { $line = [int]$r.Extent.StartLineNumber } catch { $line = 1 }
            try { $col = [int]$r.Extent.StartColumnNumber } catch { $col = 1 }
            $msg = ''
            try { $msg = [string]$r.Message } catch { $msg = '' }
            [void]$findings.Add([pscustomobject]@{
                    file     = $file
                    ruleId   = $ruleName
                    source   = 'PSScriptAnalyzer'
                    severity = $sev
                    line     = $line
                    col      = $col
                    message  = $msg + ' (SUPPRESSED in source; org policy prohibits suppressing ' + $ruleName + ' -- enforced by the repository/CI scan)'
                })
        }
    }
    return @($findings)
}
