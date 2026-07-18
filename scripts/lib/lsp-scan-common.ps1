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
    # Map a set of not-analyzed file paths to sorted, root-relative names, bounded to $Cap.
    # ONE source so the SARIF notifications and the incomplete-scan stderr line bound and order
    # the names identically. Returns @{ Names = <string[]> (<= Cap, sorted, forward-slash
    # relative); Total = <int>; Overflow = <int> }. $Cap <= 0 means no cap (enumerate all).
    # Blank/null entries are dropped; never throws on an empty set.
    param(
        [string[]]$NotAnalyzed,
        [string]$Root,
        [int]$Cap = $script:ScanNotAnalyzedNameCap
    )
    $rels = @(@($NotAnalyzed) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { Get-ScanRelativeUri -FilePath $_ -Root $Root } |
        Sort-Object)
    $total = $rels.Count
    $shown = if ($Cap -gt 0 -and $total -gt $Cap) { @($rels[0..($Cap - 1)]) } else { @($rels) }
    return @{ Names = @($shown); Total = $total; Overflow = ($total - @($shown).Count) }
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
        [string[]]$NotAnalyzed = @()
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
    # Name the unanalyzed files (dispatch 000131). Only when there ARE any, so a complete scan's
    # invocation stays byte-identical to before. Each name is a SARIF toolExecutionNotification --
    # a runtime tool-status entry (NOT a result), carrying the file's SRCROOT-relative location so
    # it is navigable in code scanning without becoming a spurious alert. Bounded to the cap, with
    # a trailing summary notification when the set overflows.
    $na = Get-ScanNotAnalyzedNames -NotAnalyzed $NotAnalyzed -Root $Root
    if ($na.Total -gt 0) {
        $notifs = New-Object System.Collections.ArrayList
        foreach ($rel in $na.Names) {
            [void]$notifs.Add([ordered]@{
                level     = 'error'
                message   = [ordered]@{ text = ('powershell-lsp: could not analyze ' + [string]$rel + ' (scan INCOMPLETE for this file).') }
                locations = @(
                    [ordered]@{
                        physicalLocation = [ordered]@{
                            artifactLocation = [ordered]@{ uri = [string]$rel; uriBaseId = 'SRCROOT' }
                        }
                    }
                )
            })
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
    param(
        [object[]]$Findings,
        [string]$Root,
        [int]$Skipped = 0,
        [int]$FilesScanned = 0,
        [string[]]$NotAnalyzed = @()
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
    $na = @(@($NotAnalyzed) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($na.Count -gt 0) {
        [void]$sb.AppendLine('WARNING: ' + $na.Count + ' file(s) could NOT be analyzed (the analyzer was not reachable for them):')
        foreach ($p in $na) { [void]$sb.AppendLine('  ' + (Get-ScanRelativeUri -FilePath $p -Root $Root)) }
    }
    return $sb.ToString().TrimEnd()
}

# --- one-engine derivation: drive the real hook over a real file -----------
# These wrap the real session lifecycle + PostToolUse client so the scan reuses the EXACT
# request/shape path of the in-agent hook (dispatch 000057: a SIBLING invocation, not a fork).
# They mirror tests/corpus/Corpus.Common.ps1 (the corpus's proven derivation) but are the
# production path; the SARIF-scan test cross-checks them against the committed corpus snapshots.

function Invoke-ScanHook {
    # Spawn a plugin hook (session-start.ps1 / session-end.ps1 / lsp-client.ps1) under the
    # resolved PowerShell host with the given stdin + env; return its stdout. The analysis host
    # is ALWAYS a real PowerShell (pwsh preferred) so findings are host-consistent regardless of
    # who launched the scan -- the same rule the corpus/integration harnesses follow.
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
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $HostExe; $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    Add-ProcessArguments $psi (@(@('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + @($ExtraArgs)) | Where-Object { $_ })
    $psi.EnvironmentVariables['CLAUDE_PLUGIN_DATA'] = $DataRoot
    if ($ExtraEnv) { foreach ($k in $ExtraEnv.Keys) { $psi.EnvironmentVariables[$k] = [string]$ExtraEnv[$k] } }
    $p = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $p.StandardOutput.ReadToEndAsync()
    if ($StdinJson) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($StdinJson)   # no BOM
        $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $p.StandardInput.BaseStream.Flush()
    }
    $p.StandardInput.Close()
    if (-not $p.WaitForExit($CapMs)) { try { $p.Kill($true) } catch { }; if ($null -ne $Killed) { $Killed.Value = $true }; return '' }
    [void]$stdoutTask.Wait(1500)
    if ($stdoutTask.IsCompleted) { return $stdoutTask.Result } else { return '' }
}

function Start-ScanDaemon {
    # Bring up ONE warm daemon for the whole scan via the REAL SessionStart hook, exactly as
    # the corpus does: perFileCap=0 (capture every finding, never an "and N more" elision) and
    # severityThreshold=Hint (keep all severities) so the scan's output is the tool's full,
    # faithful set, mapped honestly to SARIF afterward. Returns the daemon details object (the
    # session file once it reports state 'ready'), or $null on timeout (the caller fails loud --
    # an unready daemon must never read as a clean scan).
    param([string]$ScriptsDir, [string]$DataRoot, [string]$SessionId, [string]$HostExe)
    New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null
    Invoke-ScanHook -HostExe $HostExe -ScriptPath (Join-Path $ScriptsDir 'session-start.ps1') `
        -StdinJson (@{ session_id = $SessionId } | ConvertTo-Json -Compress) `
        -ExtraArgs @('-PreferredHost', $HostExe) -CapMs 180000 -DataRoot $DataRoot `
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
    #   @{ File; Findings = @({ file; ruleId; source; severity; line; col; message }); Analyzed }
    # Analyzed=$false when the hook output signals the analyzer was not reachable for this file
    # (a 'NOT checked' banner) -- surfaced by the caller so a degraded analysis is never reported
    # as a clean file (the project's never-silent rule). The file is analyzed IN PLACE so SARIF
    # carries its real path and the repo's own PSScriptAnalyzerSettings.psd1 is honored, exactly
    # as the in-agent hook honors it (000018).
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
    $full = $FilePath
    try { $full = [System.IO.Path]::GetFullPath($FilePath) } catch { $full = $FilePath }
    if ([string]::IsNullOrWhiteSpace($Cwd)) { $Cwd = [System.IO.Path]::GetDirectoryName($full) }
    if ([string]::IsNullOrWhiteSpace($CaptureDir)) { $CaptureDir = Join-Path $DataRoot 'scan-capture' }
    if (-not (Test-Path -LiteralPath $CaptureDir)) { New-Item -ItemType Directory -Force -Path $CaptureDir | Out-Null }
    $log = Join-Path $CaptureDir ('scan-' + [guid]::NewGuid().ToString('N').Substring(0, 12) + '.jsonl')

    $stdin = (@{ session_id = $SessionId; tool_input = @{ file_path = $full }; cwd = $Cwd } | ConvertTo-Json -Compress)
    # scopeToEdit=false => whole-file (a scan carries no edit patch); timeoutMs raised so a first
    # cold analysis on a slow leg still settles inside the client cap. The dogfood log is the SAME
    # structured-finding channel the corpus reads, pointed at a throwaway file (never the repo log).
    $extraEnv = @{
        POWERSHELL_LSP_DOGFOOD_LOG       = $log
        CLAUDE_PLUGIN_OPTION_scopeToEdit = 'false'
        CLAUDE_PLUGIN_OPTION_timeoutMs   = '18000'
    }
    $killed = $false
    $stdout = Invoke-ScanHook -HostExe $HostExe -ScriptPath (Join-Path $ScriptsDir 'lsp-client.ps1') `
        -StdinJson $stdin -CapMs $CapMs -DataRoot $DataRoot -ExtraEnv $extraEnv -Killed ([ref]$killed)

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
    # Never-silent: a file is "analyzed" only with POSITIVE evidence the analysis reached a verdict.
    # It did NOT in two cases: (1) the client cap KILLED the process (dispatch 000132 leg 1) -- an
    # empty stdout that must not read as clean; or (2) a 'NOT checked' banner (the daemon per-file
    # budget was exhausted). Either way the file is NOT analyzed, so the caller drops it into
    # $notAnalyzed -- it is NAMED by 000131 and the scan exits 4 -- never reporting a killed or
    # degraded file as a clean one.
    $analyzed = $true
    if ($killed) {
        $analyzed = $false
    } elseif (-not [string]::IsNullOrWhiteSpace($stdout) -and $stdout -match 'NOT checked') {
        $analyzed = $false
    }
    return [pscustomobject]@{
        File     = $full
        Findings = @(@($findings) | Where-Object { $null -ne $_ })
        Analyzed = $analyzed
    }
}
