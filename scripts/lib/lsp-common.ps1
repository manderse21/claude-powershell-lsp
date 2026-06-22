#Requires -Version 5.1

# lsp-common.ps1 -- shared helpers dot-sourced by the daemon, the PostToolUse
# client, the session hooks, and the Pester suite. No side effects on import:
# defines functions only. ASCII-only (PS 5.1 em-dash trap).
#
# Author: Mike Andersen / powershell-lsp plugin.

# --- environment / paths ---------------------------------------------------

function Get-PluginDataRoot {
    # All state, logs, pids, and the vendored PSSA live under CLAUDE_PLUGIN_DATA.
    # Never under CLAUDE_PLUGIN_ROOT (read-only plugin tree). Fall back to a temp
    # subdir only so out-of-band invocations (tests) do not explode.
    $root = $env:CLAUDE_PLUGIN_DATA
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) 'powershell-lsp-data'
    }
    return $root
}

function Get-SessionDir {
    return (Join-Path (Get-PluginDataRoot) 'session')
}

function Get-LogDir {
    return (Join-Path (Get-PluginDataRoot) 'logs')
}

function Get-PssaModuleDir {
    # Vendored PSScriptAnalyzer destination, prepended to the PSES child's
    # PSModulePath so the analyzer pass runs.
    return (Join-Path (Get-PluginDataRoot) 'modules')
}

function Get-PsesBundleRoot {
    # Resolution order: explicit env (set by plugin.json lspServers.env for the
    # parked path), then the canonical CLAUDE_PLUGIN_DATA location.
    $bundle = $env:PSES_BUNDLE_PATH
    if ([string]::IsNullOrWhiteSpace($bundle)) {
        $bundle = Join-Path (Get-PluginDataRoot) 'PowerShellEditorServices'
    }
    return $bundle
}

function Get-PsesStartScript {
    return (Join-Path (Get-PsesBundleRoot) 'PowerShellEditorServices/Start-EditorServices.ps1')
}

# --- plugin version: single source of truth is the manifest (dispatch 000025) ----
# The host/client version stamps (pses-stdio HostVersion, daemon HostVersion, the LSP
# clientInfo.version) and the startup log line all read the version from
# .claude-plugin/plugin.json at runtime -- ONE source of truth, so a bump of the manifest
# (the only place a version is hand-set) can never leave a stale literal behind, not even
# on a hand-edit that bypasses bump-version.ps1. This replaces three drifted literals
# (1.0.0 / 1.1.0 / 1.1.0 vs the real version) found by the 000023 audit (S1b), the same
# one-place-for-one-fact principle as the M1 decorative-constant finding.
#
# LOAD-SILENT by contract: this lib is dot-sourced by the -Stdio launcher (pses-stdio.ps1),
# whose stdout carries the LSP byte stream -- a single stray byte corrupts the protocol.
# These are function definitions plus one silent assignment; nothing is emitted at import,
# and Get-PluginVersion returns its value (consumed as a parameter), never writing a stream.

# Capture this lib's own directory at dot-source time. The top-level $PSScriptRoot is
# unambiguously scripts/lib here regardless of which script dot-sources us, dodging the
# "$PSScriptRoot inside a dot-sourced function" ambiguity.
$script:LspCommonDir = $PSScriptRoot
$script:PluginVersionCache = $null

function Get-PluginManifestPath {
    # Locate .claude-plugin/plugin.json. Primary: walk up from this lib's directory
    # (scripts/lib -> scripts -> plugin root), the deterministic layout in the shipped
    # tree. Fallback: CLAUDE_PLUGIN_ROOT (set by Claude Code for plugin subprocesses).
    # Returns '' if neither resolves (caller stamps an honest sentinel).
    $libDir = $script:LspCommonDir
    if ([string]::IsNullOrWhiteSpace($libDir)) { $libDir = $PSScriptRoot }
    if (-not [string]::IsNullOrWhiteSpace($libDir)) {
        $root = Split-Path -Parent (Split-Path -Parent $libDir)
        if (-not [string]::IsNullOrWhiteSpace($root)) {
            $candidate = Join-Path $root '.claude-plugin/plugin.json'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }
    $envRoot = $env:CLAUDE_PLUGIN_ROOT
    if (-not [string]::IsNullOrWhiteSpace($envRoot)) {
        $candidate = Join-Path $envRoot '.claude-plugin/plugin.json'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return ''
}

function Get-PluginVersion {
    # The single source of truth for the plugin version, read from the manifest and cached
    # per process (read once, off the hot path). Returns '0.0.0-unknown' if the manifest
    # cannot be located or parsed -- an honest sentinel that itself reads as a resolution
    # failure in a log, never a fabricated version. Emits nothing but its return value.
    if (-not [string]::IsNullOrWhiteSpace([string]$script:PluginVersionCache)) {
        return $script:PluginVersionCache
    }
    $version = '0.0.0-unknown'
    try {
        $manifest = Get-PluginManifestPath
        if (-not [string]::IsNullOrWhiteSpace($manifest)) {
            $json = (Get-Content -LiteralPath $manifest -Raw) | ConvertFrom-Json
            $ver = Get-Prop $json 'version'
            if (-not [string]::IsNullOrWhiteSpace([string]$ver)) { $version = [string]$ver }
        }
    } catch { $version = '0.0.0-unknown' }
    $script:PluginVersionCache = $version
    return $version
}

function Get-VersionStamp {
    # The product+version token for the startup log line, so a stranger's log or bug report
    # can be tied to a plugin version from the log alone (000023 S1a). One wording, one
    # source (Get-PluginVersion). The bare version (Get-PluginVersion) is what the
    # HostVersion / clientInfo.version fields carry; this is the human-readable log form.
    return ('powershell-lsp ' + (Get-PluginVersion))
}

# --- host detection (Stage 2 shared helper) --------------------------------

function Resolve-PsHost {
    # D1: prefer pwsh 7; fall back to Windows PowerShell 5.1; $null if neither.
    # An explicit preference (user_config ps_host) is honored first when present.
    param([string]$Preferred)

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($Preferred)) { $candidates += $Preferred }
    foreach ($c in @('pwsh', 'powershell')) {
        if ($candidates -notcontains $c) { $candidates += $c }
    }
    foreach ($exe in $candidates) {
        $cmd = Get-Command $exe -ErrorAction SilentlyContinue
        if ($null -ne $cmd) { return $exe }
    }
    return $null
}

# --- userConfig env fallback (v1.1.1 first-run fix) ------------------------
# Hook commands no longer pass ${user_config.*} (CC v2.1.167 refuses to launch a
# hook when any referenced option is unset -- the schema default is not applied to
# the substitution -- which errored every hook on a clean install). Scripts read
# each knob from the CLAUDE_PLUGIN_OPTION_<key> env vars CC exports to plugin
# subprocesses, each with a fallback default.

function Get-PluginOption {
    # Return the CLAUDE_PLUGIN_OPTION_<key> value, or $Default if absent/blank. The
    # exported name's casing is normalized away (underscores stripped, lower-cased)
    # so 'ps_host' matches CLAUDE_PLUGIN_OPTION_PS_HOST / _ps_host / _psHost alike.
    param([string]$Key, [string]$Default = '')
    $target = ($Key -replace '_', '').ToLowerInvariant()
    $prefix = 'CLAUDE_PLUGIN_OPTION_'
    foreach ($entry in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) {
        $name = [string]$entry.Key
        if ($name.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $k = ($name.Substring($prefix.Length) -replace '_', '').ToLowerInvariant()
            if ($k -eq $target) {
                $val = [string]$entry.Value
                if (-not [string]::IsNullOrWhiteSpace($val)) { return $val }
            }
        }
    }
    return $Default
}

function Get-PluginOptionInt {
    # Integer Get-PluginOption: fall back to $Default on absent / blank / non-numeric
    # (e.g. an unexpanded '${user_config...}' token).
    param([string]$Key, [int]$Default)
    $raw = Get-PluginOption $Key ''
    $n = 0
    if ([int]::TryParse($raw, [ref]$n)) { return $n }
    return $Default
}

function Get-PluginOptionBool {
    # Boolean Get-PluginOption, mirroring Get-PluginOptionInt's fallback shape. The
    # userConfig manifest types every option as a STRING (perFileCap = '20',
    # timeoutMs = '5000'), so a boolean knob arrives as the text 'true'/'false'.
    # 'true'/'1'/'yes'/'on' (case-insensitive) -> $true; 'false'/'0'/'no'/'off' ->
    # $false; absent / blank / an unexpanded '${user_config...}' token -> $Default.
    param([string]$Key, [bool]$Default = $false)
    $raw = (Get-PluginOption $Key '').Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    switch ($raw.ToLowerInvariant()) {
        'true'  { return $true }
        '1'     { return $true }
        'yes'   { return $true }
        'on'    { return $true }
        'false' { return $false }
        '0'     { return $false }
        'no'    { return $false }
        'off'   { return $false }
        default { return $Default }
    }
}

# --- PSScriptAnalyzer settings resolution (dispatch 000018) ----------------
# Honor a repo-local PSScriptAnalyzerSettings.psd1 by resolving its ABSOLUTE path
# and letting PSES READ it (we never parse or execute the user's .psd1 ourselves --
# it is PowerShell data, an arbitrary-code risk; PSES is the trusted consumer).
# Track 1 (cited from PSES v4.6.0 source) pinned the mechanism and the bound:
#   - PSES takes the path via workspace/didChangeConfiguration as
#     Powershell.ScriptAnalysis.SettingsPath (camelCased on the wire) and hands it
#     straight to PSScriptAnalyzer (WithSettingsFile). Granularity is per-SESSION
#     (one analysis engine, rebuilt on a config change) -- not per-file.
#   - WorkspaceService.FindFileInWorkspace returns a ROOTED path AS-IS, BEFORE the
#     WorkspaceFolders loop -- and the daemon deliberately leaves workspaceFolders
#     EMPTY (the #2300 Linux OnInitialize NRE dodge). So an ABSOLUTE path sidesteps
#     that loop entirely (no workspace-root field, no collision); a RELATIVE path
#     would resolve against PSES's process CWD (the daemon's log dir) and miss.
#     Hence: absolute only.

function New-ScriptAnalysisSettings {
    # The PSES `scriptAnalysis` settings object: `enable` always, plus `settingsPath`
    # ONLY when one is resolved. Omitting settingsPath is the no-config path -- PSES
    # then loads its default rules (byte-unchanged from before honoring). Used for
    # BOTH the didChangeConfiguration push and the workspace/configuration pull
    # response so the two config channels never disagree.
    param([string]$SettingsPath = '')
    $sa = @{ enable = $true }
    if (-not [string]::IsNullOrWhiteSpace($SettingsPath)) { $sa['settingsPath'] = $SettingsPath }
    return $sa
}

function Resolve-PssaSettingsPath {
    # Resolve the ABSOLUTE PSScriptAnalyzerSettings.psd1 to honor, or '' if none.
    # Precedence: explicit absolute override > nearest PSScriptAnalyzerSettings.psd1
    # walked up from the edited file's directory, bounded at (and including) the
    # project root > '' (PSES loads default rules). Best-effort and cheap: a path
    # walk-up is a chain of stats, off the hot path (resolved once per session).
    #
    # Adversarial control: drop the `$rootFull` bound (walk to the filesystem root)
    # and the 'settings file ABOVE the project root is not honored' unit test goes
    # RED; return $Override unconditionally and the 'relative override is ignored'
    # test goes RED.
    param(
        [string]$EditedFilePath,
        [string]$ProjectRoot,
        [string]$Override = ''
    )
    # Explicit override -- ABSOLUTE only (Mike's gate; a relative override cannot
    # resolve safely through PSES, so it is ignored and we fall through to
    # discovery). Existence is left to PSES (it logs + loads defaults if the file is
    # missing); we resolve only the path, never read it.
    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        if ([System.IO.Path]::IsPathRooted($Override)) {
            return [System.IO.Path]::GetFullPath($Override)
        }
    }
    if ([string]::IsNullOrWhiteSpace($EditedFilePath)) { return '' }
    $fileFull = [System.IO.Path]::GetFullPath($EditedFilePath)
    $dir = [System.IO.Path]::GetDirectoryName($fileFull)
    if ([string]::IsNullOrWhiteSpace($dir)) { return '' }

    $sep = [System.IO.Path]::DirectorySeparatorChar
    $alt = [System.IO.Path]::AltDirectorySeparatorChar
    $rootFull = ''
    if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
        try { $rootFull = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd($sep, $alt) } catch { $rootFull = '' }
    }

    $cur = $dir
    while (-not [string]::IsNullOrWhiteSpace($cur)) {
        $candidate = Join-Path $cur 'PSScriptAnalyzerSettings.psd1'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
        $curTrim = $cur.TrimEnd($sep, $alt)
        if ($rootFull -ne '' -and $curTrim -eq $rootFull) { break }   # reached the project root: stop (the bound)
        $parent = [System.IO.Path]::GetDirectoryName($cur)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $cur) { break }   # filesystem root
        if ($rootFull -ne '') {
            # If the edited file lives OUTSIDE the project root, do not walk above its
            # own directory -- never escape an out-of-workspace file upward.
            $under = ($curTrim -eq $rootFull) -or $curTrim.StartsWith($rootFull + $sep, [System.StringComparison]::OrdinalIgnoreCase)
            if (-not $under) { break }
        }
        $cur = $parent
    }
    return ''
}

# --- telemetry / stats (Track A) -------------------------------------------
# Observe-only per-edit timing. The writer is best-effort and FAIL-SAFE by
# contract: any failure (locked file, a directory squatting the path, disk full)
# is swallowed so a telemetry hiccup can never affect the diagnostics emit or the
# hook's exit code. JSONL (one object per line) -- not a JSON array -- so the
# readout can stream it and PS 5.1's empty-array-returns-null quirk on read never
# bites. Caller stamps the record (ts, path, ext, stage timings, counts); this
# only serializes + appends with a single-rollover size cap.

function Write-StatsLine {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Record,
        # ~5 MB live-file cap; one rollover to stats.jsonl.1 -> bounded ~2x on disk.
        [int]$CapBytes = 5242880
    )
    try {
        $dir = Get-LogDir
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $statsFile = Join-Path $dir 'stats.jsonl'
        # Rotate BEFORE appending when the live file has reached the cap: move it to
        # .1 (overwriting any prior .1) and start a fresh live file. Single rollover.
        if (Test-Path -LiteralPath $statsFile) {
            $item = Get-Item -LiteralPath $statsFile -ErrorAction Stop
            if ([long]$item.Length -ge $CapBytes) {
                Move-Item -LiteralPath $statsFile -Destination ($statsFile + '.1') -Force -ErrorAction Stop
            }
        }
        $line = ($Record | ConvertTo-Json -Depth 8 -Compress)
        # UTF-8 without BOM, explicit LF. (PS 5.1's ConvertTo-Json escapes non-ASCII
        # to \uXXXX, but pwsh 7 emits it literally -- so UTF-8 keeps a non-ASCII path
        # intact across hosts; this is a data file, not a parsed .ps1.)
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::AppendAllText($statsFile, ($line + "`n"), $enc)
    } catch { }
}

# --- dogfood diagnostic capture (dispatch 000039) --------------------------
# Tee EVERY surfaced diagnostic OCCURRENCE into a local, append-only JSONL log so the
# roadmap's quality wave (rule curation -> false-positive reduction -> fix quality) can be
# ranked on REAL diagnostics from REAL usage instead of guesses. CAPTURE ONLY: the
# annotation/review tool that consumes the empty verdict field is a deliberate fast-follow.
#
# THE INVISIBLE-SIDE-CHANNEL FENCE (the core constraint): capture is strictly additive and
# invisible to the diagnostics surface. It runs AFTER the surface is emitted, is fully
# wrapped so ANY failure is swallowed, and writes NOTHING to stdout -- so what is surfaced,
# its order, the (already-delivered) timing, and the hook's exit code are byte-for-byte
# unchanged whether capture succeeds, fails, or is absent. Same fail-safe contract as
# Write-StatsLine; the 000026 fail-safe spine and the 000024/000028 never-silent guarantee
# are preserved unchanged. No dedup/sampling/rate-limit at capture: one entry per
# occurrence (two identical diagnostics -> two entries); the hash is an ANALYSIS-time dedup
# key only.
#
# THE NEVER-COMMIT FENCE: the log holds REAL source snippets. It is gitignored and must
# NEVER be staged, added, or committed (see .gitignore and the README dogfood section).

function Get-DogfoodLogPath {
    # Resolve the dogfood capture log path. Precedence:
    #   1. $env:POWERSHELL_LSP_DOGFOOD_LOG -- an explicit full-path override (a test seam and
    #      an advanced-relocation escape hatch). Honored verbatim.
    #   2. <plugin-root>/dogfood/diagnostics.jsonl -- the default. The root is resolved the
    #      SAME way as Get-PluginManifestPath: walk up from this lib's dir (scripts/lib ->
    #      scripts -> root); fall back to $env:CLAUDE_PLUGIN_ROOT.
    # Returns '' when the root cannot be resolved -- the caller's append then fails safe and
    # surfaces nothing. The log lands in whichever plugin tree is running; for dogfooding
    # that is the dev clone, whose .gitignore covers it.
    $override = $env:POWERSHELL_LSP_DOGFOOD_LOG
    if (-not [string]::IsNullOrWhiteSpace($override)) { return $override }
    $libDir = $script:LspCommonDir
    if ([string]::IsNullOrWhiteSpace($libDir)) { $libDir = $PSScriptRoot }
    $root = ''
    if (-not [string]::IsNullOrWhiteSpace($libDir)) {
        $root = Split-Path -Parent (Split-Path -Parent $libDir)
    }
    if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root)) {
        $envRoot = $env:CLAUDE_PLUGIN_ROOT
        if (-not [string]::IsNullOrWhiteSpace($envRoot)) { $root = $envRoot }
    }
    if ([string]::IsNullOrWhiteSpace($root)) { return '' }
    return (Join-Path $root 'dogfood/diagnostics.jsonl')
}

function Get-DiagnosticShapeHash {
    # Stable analysis-time dedup key over (rule ID + normalized offending-line shape).
    # Normalization (dispatch 000039 OQ2): trim, then collapse interior whitespace runs to a
    # single space; CASE IS PRESERVED -- lowercasing risks collapsing genuinely distinct
    # lines (e.g. two string literals differing only in case), so the conservative,
    # correctness-preserving option is taken. Deterministic SHA-256 over UTF-8 bytes:
    # identical (rule, line shape) -> identical hash across processes/hosts; distinct inputs
    # -> distinct hash. Capture-time code NEVER dedups on this; it is for the later
    # annotation/analysis pass only.
    param([string]$RuleId, [string]$OffendingLine)
    $normLine = ((([string]$OffendingLine) -replace '\s+', ' ').Trim())
    # A U+0001 separator (a control char that cannot occur in a rule id or a source line) so
    # (rule 'AB' + line '') and (rule 'A' + line 'B') can never collide.
    $material = ([string]$RuleId) + ([char]1) + $normLine
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($material)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hashBytes = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
    return (([System.BitConverter]::ToString($hashBytes)) -replace '-', '').ToLowerInvariant()
}

function New-CaptureRecordFromDiag {
    # Normalize ONE daemon-surfaced diagnostic (the PSObject the client renders) into the
    # flat capture-record shape. ruleId = the PSSA rule code when present; source = the LSP
    # source, falling back to 'parser' when empty (mirrors the surface label's own fallback).
    param($Diagnostic)
    $code = [string](Get-Prop $Diagnostic 'code')
    $ruleId = if ($code -and $code -ne '0') { $code } else { '' }
    $src = [string](Get-Prop $Diagnostic 'source')
    if ([string]::IsNullOrWhiteSpace($src)) { $src = 'parser' }
    $line = 0; $lv = Get-Prop $Diagnostic 'line'; if ($null -ne $lv) { $line = [int]$lv }
    $col = 0; $cv = Get-Prop $Diagnostic 'col'; if ($null -ne $cv) { $col = [int]$cv }
    return @{
        line = $line; col = $col; ruleId = $ruleId; source = $src
        severity = [string](Get-Prop $Diagnostic 'severity'); message = [string](Get-Prop $Diagnostic 'message')
    }
}

function New-CaptureRecordFromParseError {
    # Normalize ONE in-process parser diagnostic (a System.Management.Automation.Language.
    # ParseError) into the flat capture-record shape. source is always 'parser' and severity
    # 'Error' (mirrors the parser pre-pass surface); ruleId is the parser ErrorId when present.
    param($ParseErr)
    $line = 0; $col = 0; $ruleId = ''; $msg = ''
    try { $line = [int]$ParseErr.Extent.StartLineNumber } catch { $line = 0 }
    try { $col = [int]$ParseErr.Extent.StartColumnNumber } catch { $col = 0 }
    try { $ruleId = [string]$ParseErr.ErrorId } catch { $ruleId = '' }
    try { $msg = ((([string]$ParseErr.Message) -replace "[`r`n`t]", ' ').Trim()) } catch { $msg = '' }
    return @{
        line = $line; col = $col; ruleId = $ruleId; source = 'parser'
        severity = 'Error'; message = $msg
    }
}

function Add-DiagnosticCaptureEntries {
    # Append one JSONL entry per SURFACED diagnostic occurrence to the dogfood log. STRICTLY
    # fail-safe and additive (see the section header): any failure is swallowed, nothing is
    # written to stdout, and the caller's surface + exit code are untouched. $Records are the
    # flat hashtables produced by New-CaptureRecordFrom*; the offending-line snippet and the
    # dedup hash are derived here so the two emit call sites stay thin. The verdict field is
    # written EMPTY, reserved for the later annotation pass.
    param([string]$File, [object[]]$Records)
    try {
        $recs = @($Records)
        if ($recs.Count -eq 0) { return }
        $logPath = Get-DogfoodLogPath
        if ([string]::IsNullOrWhiteSpace($logPath)) { return }
        $dir = Split-Path -Parent $logPath
        if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        # Read the post-edit file ONCE for snippets; tolerate any read failure (snippet '').
        $lines = $null
        try { $lines = [System.IO.File]::ReadAllLines($File) } catch { $lines = $null }
        $ts = (Get-Date -Format 'o')
        $sb = New-Object System.Text.StringBuilder
        foreach ($r in $recs) {
            $lineNum = 0; try { $lineNum = [int]$r.line } catch { $lineNum = 0 }
            $colNum = 0; try { $colNum = [int]$r.col } catch { $colNum = 0 }
            $snippet = ''
            if ($null -ne $lines -and $lineNum -ge 1 -and $lineNum -le $lines.Count) {
                $snippet = [string]$lines[$lineNum - 1]
            }
            $ruleId = [string]$r.ruleId
            $entry = [ordered]@{
                ts       = $ts
                file     = [string]$File
                line     = $lineNum
                col      = $colNum
                ruleId   = $ruleId
                source   = [string]$r.source
                severity = [string]$r.severity
                message  = [string]$r.message
                snippet  = $snippet
                hash     = (Get-DiagnosticShapeHash -RuleId $ruleId -OffendingLine $snippet)
                verdict  = ''
            }
            [void]$sb.Append(($entry | ConvertTo-Json -Depth 5 -Compress))
            [void]$sb.Append("`n")
        }
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::AppendAllText($logPath, $sb.ToString(), $enc)
    } catch { }
}

# --- platform helpers (cross-platform forward-compat) ----------------------
# Non-Windows branches below are AUTHORED but CI-verified later (this build runs
# Windows only). They exist so the Windows-only calls are isolated and guarded.

function Test-OnWindows {
    # $IsWindows exists only on PowerShell 6+. Windows PowerShell 5.1 has no such
    # automatic variable and is always Windows. StrictMode-safe existence check.
    if (Test-Path 'Variable:\IsWindows') { return [bool]$IsWindows }
    return $true
}

function Add-ProcessArguments {
    # Set process arguments cross-version. PowerShell 7+ (.NET Core) has
    # ProcessStartInfo.ArgumentList (correct auto-quoting); Windows PowerShell 5.1
    # (.NET Framework) does NOT -- it only has the .Arguments string, which we
    # quote by hand. pwsh keeps using ArgumentList (the proven path), unchanged.
    param([System.Diagnostics.ProcessStartInfo]$Psi, [string[]]$Arguments)
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        foreach ($a in $Arguments) { $Psi.ArgumentList.Add([string]$a) }
    } else {
        $Psi.Arguments = (($Arguments | ForEach-Object {
            if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { [string]$_ }
        }) -join ' ')
    }
}

function Get-ProcessCommandLine {
    # Best-effort process command line by pid, cross-platform. Returns '' when
    # unavailable. Used only to VERIFY a recorded pid is ours before any kill.
    param([int]$ProcessIdValue)
    try {
        if (Test-OnWindows) {
            $cim = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $ProcessIdValue) -ErrorAction SilentlyContinue
            if ($null -ne $cim) { return [string]$cim.CommandLine }
            return ''
        }
        $procFs = "/proc/$ProcessIdValue/cmdline"   # Linux
        if (Test-Path -LiteralPath $procFs) {
            return ((Get-Content -LiteralPath $procFs -Raw -ErrorAction SilentlyContinue) -replace "`0", ' ').Trim()
        }
        # macOS / other: invoke the native ps binary (not the Get-Process alias).
        $psBin = Get-Command 'ps' -CommandType Application -ErrorAction SilentlyContinue
        if ($null -ne $psBin) { return ((& $psBin.Source -o command= -p $ProcessIdValue 2>$null) -join ' ').Trim() }
        return ''
    } catch { return '' }
}

# --- detached daemon launch (dispatch 000030: single source of the launch) --
# The ONE place that launches the per-session PSES daemon detached. Extracted from
# session-start.ps1 (no behavior change there) so the PostToolUse client can reuse the
# EXACT pipe-first launch to AUTO-RELAUNCH a cleanly idle-stopped daemon on the next edit
# (dispatch 000030). The daemon owns its own lifecycle (pipe-first per 000028); this only
# starts it detached, with the 000026 cross-platform detachment so it never inherits the
# caller's std handles -- on non-Windows that leak would stall the session (claude-code
# #43123). Returns $true if the launch was fired, $false if it could not be (spawn threw).

function Start-PsesDaemonDetached {
    param(
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$HostExe,
        [string]$SeverityThreshold = 'Hint',
        [string]$RuleInclude = '',
        [string]$RuleExclude = '',
        [int]$DebounceMs = 150,
        [int]$IdleTtlMin = 30,
        [int]$PerFileCap = 20,
        [string]$SettingsPath = ''
    )
    $scriptsDir = Split-Path -Parent $script:LspCommonDir   # scripts/lib -> scripts
    if ([string]::IsNullOrWhiteSpace($scriptsDir)) { $scriptsDir = Split-Path -Parent $PSScriptRoot }
    $daemon = Join-Path $scriptsDir 'pses-daemon.ps1'
    $logDir = Get-LogDir
    try { New-Item -ItemType Directory -Force -Path $logDir | Out-Null } catch { }
    # Identical arg shape to the pre-000030 inline session-start launch: DataRoot is passed
    # explicitly (a detached launch may not inherit the env var), rule lists / settings path
    # only when non-empty (an empty positional element would misalign the daemon binding).
    $daemonArgs = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $daemon,
        '-SessionId', $SessionId, '-PsHost', $HostExe, '-DataRoot', (Get-PluginDataRoot),
        '-SeverityThreshold', $SeverityThreshold, '-DebounceMs', [string]$DebounceMs,
        '-IdleTtlMin', [string]$IdleTtlMin, '-PerFileCap', [string]$PerFileCap)
    if (-not [string]::IsNullOrWhiteSpace($RuleInclude)) { $daemonArgs += @('-RuleInclude', $RuleInclude) }
    if (-not [string]::IsNullOrWhiteSpace($RuleExclude)) { $daemonArgs += @('-RuleExclude', $RuleExclude) }
    if (-not [string]::IsNullOrWhiteSpace($SettingsPath)) { $daemonArgs += @('-SettingsPath', $SettingsPath) }
    try {
        if (Test-OnWindows) {
            # -WindowStyle Hidden routes through ShellExecute, which STRUCTURALLY does not pass
            # inheritable std handles to the child (Windows is already detached-safe).
            Start-Process -FilePath $HostExe -ArgumentList $daemonArgs -WindowStyle Hidden | Out-Null
        } else {
            # Non-Windows has no ShellExecute, so redirect all three std streams to per-launch
            # files (stamped, retired by the log sweep) so the daemon never holds the caller's
            # hook pipes open (000026). DISTINCT paths (Start-Process rejects two sharing one).
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
            $dlBase = Join-Path $logDir ('pses-daemon-launch-' + $stamp)
            $dlIn = $dlBase + '.in'; $dlOut = $dlBase + '.out'; $dlErr = $dlBase + '.err'
            New-Item -ItemType File -Force -Path $dlIn | Out-Null
            Start-Process -FilePath $HostExe -ArgumentList $daemonArgs `
                -RedirectStandardInput $dlIn `
                -RedirectStandardOutput $dlOut `
                -RedirectStandardError $dlErr | Out-Null
        }
        return $true
    } catch {
        return $false
    }
}

# --- file URIs (landmine 1: uppercase Windows drive letters) ---------------

function ConvertTo-FileUri {
    # Build a file:// URI from a filesystem path, cross-platform.
    # Windows: let .NET convert (handles drive + UNC), then force an UPPERCASE drive
    # letter ([System.Uri].AbsoluteUri lowercases it, a document-match hazard).
    # POSIX: the [System.Uri] STRING CAST yields a null/relative URI for an absolute
    # path like /home/x (no drive, no scheme); .AbsoluteUri on that is null, which
    # then breaks every downstream .ToLowerInvariant()/didOpen call. So build
    # file://<path> explicitly, percent-escaping each segment.
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [System.IO.Path]::GetFullPath($Path)
    if (Test-OnWindows) {
        $uri = ([System.Uri]$full).AbsoluteUri
        if ($uri -match '^file:///[a-z]:') {
            $uri = $uri.Substring(0, 8) + $uri.Substring(8, 1).ToUpperInvariant() + $uri.Substring(9)
        }
        return $uri
    }
    $sb = New-Object System.Text.StringBuilder
    foreach ($seg in ($full -split '/')) {
        if ($seg -eq '') { continue }
        [void]$sb.Append('/')
        [void]$sb.Append([System.Uri]::EscapeDataString($seg))
    }
    return ('file://' + $sb.ToString())
}

function ConvertFrom-FileUri {
    param([Parameter(Mandatory = $true)][string]$Uri)
    try { return [System.IO.Path]::GetFullPath(([System.Uri]$Uri).LocalPath) }
    catch { return $Uri }
}

function ConvertTo-UriKey {
    # Normalize a file URI to a case-insensitive lookup key (landmine 1, match side).
    # ConvertTo-FileUri emits the Windows drive letter UPPERCASED, but PSES echoes
    # it back LOWERCASED in publishDiagnostics. The daemon keys both the stored
    # publish and the request lookup through here so the two still correlate;
    # without the fold the drive-letter case mismatches and diagnostics are
    # silently dropped. Lower-casing the whole URI (not just the drive) preserves
    # the daemon's long-standing keying behavior verbatim.
    param([string]$Uri)
    return $Uri.ToLowerInvariant()
}

# --- stdin (BOM-tolerant) --------------------------------------------------

function Get-StdinText {
    # Read all of stdin and strip a leading UTF-8 BOM if present. Some parent
    # processes (e.g. a Windows PowerShell 5.1 StreamWriter) prepend one, which
    # would otherwise break ConvertFrom-Json on the hook payload.
    $raw = [Console]::In.ReadToEnd()
    if ($null -ne $raw) { $raw = $raw.TrimStart([char]0xFEFF) }
    return $raw
}

# --- JSON property helpers (StrictMode-safe) -------------------------------

function Test-Prop {
    param($Object, [string]$Name)
    return ($null -ne $Object) -and ($Object.PSObject.Properties.Name -contains $Name)
}

function Get-Prop {
    param($Object, [string]$Name)
    if (Test-Prop $Object $Name) { return $Object.$Name } else { return $null }
}

# --- initialize capabilities (landmine 2, INVERTED from the dispatch) ------

function New-InitializeCapabilities {
    # IMPORTANT: this DECLARES textDocument.rename. The dispatch frontmatter and
    # the overnight brief both say "do not advertise rename", but that is
    # empirically backwards for PSES v4.6.0: omitting rename makes its
    # PrepareRenameHandler dereference a null RenameCapability and the server
    # never answers initialize (verified by probe on 2026-06-05 -- rename omitted
    # => "NO INIT RESPONSE"; rename declared => clean handshake + diagnostics).
    # The shipped v1.0.0 README documents the same direction. Declaring a minimal
    # rename capability is what AVOIDS the NRE. See CHANGELOG 1.1.0 / outbox.
    return @{
        workspace = @{ configuration = $true; workspaceFolders = $true }
        window = @{ workDoneProgress = $true }
        textDocument = @{
            synchronization = @{ didOpen = $true; didChange = $true; didSave = $true }
            publishDiagnostics = @{ relatedInformation = $true }
            rename = @{ dynamicRegistration = $false; prepareSupport = $true }
            hover = @{ contentFormat = @('markdown', 'plaintext') }
            definition = @{ linkSupport = $true }
            completion = @{ completionItem = @{ snippetSupport = $false } }
        }
    }
}

function New-InitializeParams {
    # Build the LSP `initialize` params. CRITICAL (landmine 3): this OMITS the
    # top-level `workspaceFolders` member. PSES v4.6.0 throws a NullReferenceException
    # inside its own OnInitialize handler (PsesLanguageServer.cs:150, the
    # workspaceFolders add path) on Linux when initialize carries workspaceFolders
    # (upstream #2300) -- so the daemon relies on rootUri alone and opens each file
    # explicitly via didOpen/didChange (multi-root folders are not needed for
    # diagnostics). Re-adding a workspaceFolders member here reintroduces the Linux
    # hang. NOTE: the boolean capability workspace.workspaceFolders declared in
    # New-InitializeCapabilities is a DIFFERENT thing -- it only advertises support
    # and is safe; it is the params-level folder list that trips the NRE.
    param(
        [Parameter(Mandatory = $true)][string]$RootUri,
        [Parameter(Mandatory = $true)][int]$ProcessId
    )
    return @{
        processId = $ProcessId
        clientInfo = @{ name = 'cc-pses-daemon'; version = (Get-PluginVersion) }
        rootUri = $RootUri
        capabilities = (New-InitializeCapabilities)
    }
}

# --- LSP framing over a byte stream ----------------------------------------

function Write-LspFrame {
    # Content-Length framed JSON-RPC over the child's stdin stream.
    param([System.IO.Stream]$Stream, [string]$Json)
    $body = [System.Text.Encoding]::UTF8.GetBytes($Json)
    $header = [System.Text.Encoding]::ASCII.GetBytes("Content-Length: $($body.Length)`r`n`r`n")
    $Stream.Write($header, 0, $header.Length)
    $Stream.Write($body, 0, $body.Length)
    $Stream.Flush()
}

function Read-LspFrame {
    # Pull one complete frame body out of a byte List buffer, or $null if the
    # buffer does not yet hold a full frame. Mutates $Buffer in place.
    param([System.Collections.Generic.List[byte]]$Buffer)

    $n = $Buffer.Count
    if ($n -lt 4) { return $null }
    $sep = -1
    for ($i = 0; $i -le $n - 4; $i++) {
        if ($Buffer[$i] -eq 13 -and $Buffer[$i + 1] -eq 10 -and `
                $Buffer[$i + 2] -eq 13 -and $Buffer[$i + 3] -eq 10) { $sep = $i; break }
    }
    if ($sep -lt 0) { return $null }
    $headerBytes = $Buffer.GetRange(0, $sep).ToArray()
    $header = [System.Text.Encoding]::ASCII.GetString($headerBytes)
    $len = -1
    foreach ($line in ($header -split "`r`n")) {
        if ($line -match '(?i)^\s*Content-Length:\s*(\d+)\s*$') { $len = [int]$Matches[1] }
    }
    if ($len -lt 0) {
        $Buffer.RemoveRange(0, $sep + 4)
        return $null
    }
    $bodyStart = $sep + 4
    if ($Buffer.Count -lt $bodyStart + $len) { return $null }
    $bodyBytes = $Buffer.GetRange($bodyStart, $len).ToArray()
    $Buffer.RemoveRange(0, $bodyStart + $len)
    return [System.Text.Encoding]::UTF8.GetString($bodyBytes)
}

# --- diagnostics normalization + ordering ----------------------------------

function ConvertTo-DiagRecord {
    # Map an LSP diagnostic object to a flat ordered hashtable. Line/Col 1-based.
    #
    # Correction text is THREADED THROUGH here (it used to be dropped). LSP
    # publishDiagnostics does not carry PSScriptAnalyzer SuggestedCorrections, so
    # at publish time there is no fix yet: 'correction' defaults to '' and
    # 'correctionCount' to 0, and the daemon enriches the record afterward from a
    # textDocument/codeAction pass (see Add-CodeActionCorrections in the daemon).
    # A caller that already has the fix (e.g. a test) may pass it in directly.
    param(
        $Diagnostic,
        [string]$Correction = '',
        [int]$CorrectionCount = 0
    )
    $range = Get-Prop $Diagnostic 'range'
    $startPos = Get-Prop $range 'start'
    $endPos = Get-Prop $range 'end'
    $line = 1; $col = 1
    $lv = Get-Prop $startPos 'line'; if ($null -ne $lv) { $line = [int]$lv + 1 }
    $cv = Get-Prop $startPos 'character'; if ($null -ne $cv) { $col = [int]$cv + 1 }
    # endLine (1-based) carries the diagnostic's LAST line so edit-range scoping can
    # test true range OVERLAP, not just the start line -- a multi-line diagnostic
    # straddling the edit boundary must still be kept (dispatch 000019). Defaults to
    # the start line when no end is present (a point diagnostic).
    $endLine = $line
    $elv = Get-Prop $endPos 'line'; if ($null -ne $elv) { $endLine = [int]$elv + 1 }
    if ($endLine -lt $line) { $endLine = $line }
    $sevNum = Get-Prop $Diagnostic 'severity'
    $sev = switch ([int]$sevNum) { 1 { 'Error' } 2 { 'Warning' } 3 { 'Information' } 4 { 'Hint' } default { 'Warning' } }
    $src = [string](Get-Prop $Diagnostic 'source')
    $codeVal = Get-Prop $Diagnostic 'code'
    $code = if ($null -ne $codeVal) { [string]$codeVal } else { '' }
    $msg = [string](Get-Prop $Diagnostic 'message')
    $msg = ($msg -replace "[`r`n`t]", ' ').Trim()
    return [ordered]@{
        severity = $sev; severityNum = [int]$sevNum
        line = $line; endLine = $endLine; col = $col; source = $src; code = $code; message = $msg
        correction = [string]$Correction; correctionCount = [int]$CorrectionCount
    }
}

function Get-SeverityRank {
    param([string]$Severity)
    switch ($Severity) { 'Error' { 1 } 'Warning' { 2 } 'Information' { 3 } 'Hint' { 4 } default { 5 } }
}

function Split-RuleList {
    # Parse a comma-separated rule-name list (from userConfig) into a trimmed,
    # non-empty array. Empty input -> empty array (no constraint).
    param([string]$Csv)
    if ([string]::IsNullOrWhiteSpace($Csv)) { return @() }
    return @($Csv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Select-FilteredDiagnostics {
    # Apply a severity threshold and rule include/exclude. $Threshold names the
    # LEAST severe level to report (Error > Warning > Information > Hint). Empty
    # include/exclude means no constraint; an explicit include keeps only listed
    # rule codes. Returns the surviving records (order preserved).
    param(
        [object[]]$Records,
        [string]$Threshold = 'Hint',
        [string[]]$Include = @(),
        [string[]]$Exclude = @()
    )
    if ($null -eq $Records) { return @() }
    $thRank = Get-SeverityRank $Threshold
    $inc = @($Include | Where-Object { $_ })
    $exc = @($Exclude | Where-Object { $_ })
    $out = @()
    foreach ($r in $Records) {
        if ((Get-SeverityRank $r.severity) -gt $thRank) { continue }
        if ($exc.Count -gt 0 -and ($exc -contains $r.code)) { continue }
        if ($inc.Count -gt 0 -and ($inc -notcontains $r.code)) { continue }
        $out += $r
    }
    return @($out)
}

function Select-OrderedDiagnostics {
    # Stable order (severity asc, then line, then col) + dedupe on the tuple that
    # identifies a finding. Returns an array of diag-record hashtables.
    param([object[]]$Records)
    if ($null -eq $Records) { return @() }
    $seen = New-Object System.Collections.Generic.HashSet[string]
    $unique = @()
    foreach ($r in $Records) {
        $key = ('{0}|{1}|{2}|{3}|{4}' -f $r.severity, $r.line, $r.col, $r.code, $r.message)
        if ($seen.Add($key)) { $unique += $r }
    }
    return @($unique | Sort-Object `
        @{ Expression = { Get-SeverityRank $_.severity } }, `
        @{ Expression = { [int]$_.line } }, `
        @{ Expression = { [int]$_.col } })
}

# --- analysis status: clean vs incomplete vs degraded vs unavailable (000022/000024) ----
# The one failure direction a linter must never have is "could not analyze" reading
# identical to "analyzed, found nothing." These two PURE helpers separate the cases and
# own the exact user-facing wording, so the daemon (which shapes the status) and the
# client (which renders it) cannot drift, and the wording is unit-testable. 000024 extends
# the set with an install-time 'unavailable' (the bundle never bootstrapped) -- the banner
# helper owns its wording too; Resolve-AnalysisStatus is unchanged (it maps a LIVE pass's
# settled/pssa state, whereas 'unavailable' is produced by the daemon's first-start seam).
#
#   Settled = a publishDiagnostics result actually arrived for this pass (regardless of
#     count -- zero diagnostics on a SETTLED pass is genuinely clean). NOT settled = the
#     pass timed out, PSES threw, PSES exited, or a re-spawn was in progress -> we do NOT
#     know the file is clean, so the result must say so rather than render as empty.
#   PssaAvailable = the vendored PSScriptAnalyzer was present when PSES launched. Absent =
#     the analyzer pass is parser-only (reduced capability) -- a persistent, session-
#     lifetime degrade, distinct from a transient non-settle.

function Resolve-AnalysisStatus {
    # Map (settled, pssaAvailable) to one of: 'ok' | 'incomplete' | 'degraded'.
    # Precedence (000022 Q(c)): a pass that did not settle is 'incomplete' even on a
    # parser-only daemon -- "this edit was not checked at all" outranks "checked with
    # fewer rules." Adversarial control: collapse the first branch and the
    # 'incomplete beats degraded' unit assertion goes RED.
    param([bool]$Settled, [bool]$PssaAvailable)
    if (-not $Settled) { return 'incomplete' }
    if (-not $PssaAvailable) { return 'degraded' }
    return 'ok'
}

function Get-DiagnosticsStatusBanner {
    # The exact ASCII user-facing line for a non-clean status, or '' for 'ok' (so the
    # warm happy path renders nothing -- byte-identical to before). Confirmed wording
    # (Mike, dispatch 000022 Q(b)/Q(c)): one message for the transient 'incomplete'
    # family (sub-cause stays in the daemon log), and a DISTINCT message for the
    # 'degraded' parser-only case (different meaning + remediation). Adversarial control:
    # return a non-empty string for 'ok' and the byte-identical warm-path unit guard
    # goes RED.
    #
    # 'unavailable' (dispatch 000024, generalized by 000028) is the PERMANENT first-start
    # failure: PSES could not start AT ALL -- either the bundle never bootstrapped (clean box,
    # offline/proxy) OR it is present but failed to initialize (a startup failure / init timeout,
    # the sub-case 000024 had left as a silent fail-fast before the pipe). The token is
    # DELIBERATELY one (not a new fifth token): the user-facing truth is identical -- the analyzer
    # is not available -- so the prose is GENERALIZED to cover both causes. It is DISTINCT from the
    # TRANSIENT 'incomplete' on purpose, and the wording must LAND that difference: 'incomplete'
    # means "not checked this time, the next edit will be"; 'unavailable' means "OFF for this whole
    # session until fixed and restarted." A broken/absent start must never read as a retryable
    # miss. Confirmed (Mike, 000024 Q(a) + 000028): one token, generalized prose that lands the
    # permanence, NOT a new token and NOT routed through 'incomplete'.
    param([string]$Status, [string]$Path)
    switch ($Status) {
        'incomplete'  { return ('PowerShell diagnostics unavailable for ' + $Path + ': analysis did not complete -- this edit was NOT checked.') }
        'degraded'    { return ('PowerShell diagnostics for ' + $Path + ': parser-only mode -- PSScriptAnalyzer unavailable, lint rules were NOT checked (syntax errors are still reported).') }
        'unavailable' { return ('PowerShell diagnostics unavailable for ' + $Path + ': PowerShell editor services could not start -- not installed (the bootstrap did not complete), or installed but failed to start. Diagnostics will stay OFF for this whole session until it is fixed and the session is restarted; this edit was NOT checked. See logs/ensure-pses.log and logs/pses-daemon.log.') }
        default       { return '' }
    }
}

# --- edit-range diagnostic scoping (dispatch 000019) -----------------------
# Scope the surfaced diagnostics to the lines an edit touched. The touched range is
# derived CLIENT-SIDE from the PostToolUse tool_response.structuredPatch (the only
# place the per-edit line span is known) and passed to the daemon, which filters the
# markers it already holds -- a cheap post-analysis filter, never an analysis-window
# change (PSES still analyzes whole-file). FAIL OPEN is the load-bearing invariant:
# any indeterminate range surfaces ALL diagnostics. A scoping failure must never hide
# a problem the edit just introduced -- surfacing extra is the safe failure direction.

function ConvertTo-TouchedRanges {
    # Derive the touched line ranges (1-based, inclusive, post-edit) from a PostToolUse
    # tool_response. Returns an array of [pscustomobject]@{ start; end }, or $null to
    # signal an INDETERMINATE range (the caller fails open to whole-file). Keyed on
    # PATCH STATE, not tool name (000019 Track 1, confirmed against real payloads):
    #   - tool_response missing / a string  -> $null  (a FAILED edit reports a string
    #     error and leaves the file unchanged; nothing meaningful was touched)
    #   - no structuredPatch property        -> $null  (fail open)
    #   - structuredPatch present but EMPTY  -> $null  (a Write that CREATED a new file;
    #     a create IS the whole file -- never scope it to nothing, so fail open)
    #   - structuredPatch with hunks         -> union of each hunk's post-edit span
    #     [newStart, newStart + newLines - 1]  (Edit, MultiEdit, a Write that UPDATED an
    #     existing file). newStart/newLines are already 1-based post-edit and already
    #     include a few diff context lines, so ContextLines defaults to 0 (do not stack).
    param($ToolResponse, [int]$ContextLines = 0)
    if ($null -eq $ToolResponse) { return $null }
    if ($ToolResponse -is [string]) { return $null }
    if (-not (Test-Prop $ToolResponse 'structuredPatch')) { return $null }
    $hunks = @(Get-Prop $ToolResponse 'structuredPatch')
    if ($hunks.Count -eq 0) { return $null }
    if ($ContextLines -lt 0) { $ContextLines = 0 }
    $ranges = @()
    foreach ($h in $hunks) {
        $ns = Get-Prop $h 'newStart'
        if ($null -eq $ns) { continue }
        $newStart = [int]$ns
        if ($newStart -le 0) { continue }
        $nlv = Get-Prop $h 'newLines'
        $newLines = if ($null -ne $nlv) { [int]$nlv } else { 0 }
        # newLines == 0 is a pure-deletion hunk (nothing added at newStart); treat it as
        # touching the single line at newStart so an edit-adjacent diagnostic is kept.
        $start = $newStart - $ContextLines
        $end = if ($newLines -gt 0) { $newStart + $newLines - 1 } else { $newStart }
        $end = $end + $ContextLines
        if ($start -lt 1) { $start = 1 }
        if ($end -lt $start) { $end = $start }
        $ranges += [pscustomobject]@{ start = $start; end = $end }
    }
    if ($ranges.Count -eq 0) { return $null }   # patch had hunks but none usable -> fail open
    return $ranges
}

function Test-RangeOverlapsAny {
    # True if the inclusive line span [Start,End] overlaps ANY of $Ranges (each an
    # object with 1-based inclusive .start/.end). OVERLAP, not containment: a multi-line
    # diagnostic straddling an edit boundary still counts (000019 Q4).
    param([int]$Start, [int]$End, $Ranges)
    foreach ($r in @($Ranges)) {
        $rs = [int](Get-Prop $r 'start')
        $re = [int](Get-Prop $r 'end')
        if ($Start -le $re -and $End -ge $rs) { return $true }
    }
    return $false
}

function Select-DiagnosticsInRange {
    # Keep only the diagnostic records whose [line, endLine] span overlaps a touched
    # range. FAIL OPEN: a $null / empty range set returns ALL records unchanged -- an
    # indeterminate range never hides a diagnostic. Records are the flat ordered
    # hashtables from ConvertTo-DiagRecord (line + endLine, 1-based).
    param([object[]]$Records, $Ranges)
    if ($null -eq $Records) { return @() }
    if ($null -eq $Ranges -or @($Ranges).Count -eq 0) { return @($Records) }
    $out = @()
    foreach ($rec in @($Records)) {
        $s = [int]$rec.line
        $e = $s
        if (($rec -is [System.Collections.IDictionary]) -and $rec.Contains('endLine')) { $e = [int]$rec.endLine }
        elseif (Test-Prop $rec 'endLine') { $e = [int](Get-Prop $rec 'endLine') }
        if ($e -lt $s) { $e = $s }
        if (Test-RangeOverlapsAny -Start $s -End $e -Ranges $Ranges) { $out += $rec }
    }
    return @($out)
}

function Get-ScopedCappedResult {
    # Apply edit-range scoping THEN the per-file cap, in that order (000019 acceptance:
    # scope first, then cap). $Records are already ordered + severity/rule filtered.
    # Returns the shown set, the cap-omitted count, and the pre-scope (total) /
    # post-scope (surfaced) counts for telemetry. A $null/empty $Ranges means no scoping
    # (fail open / scoping off) -> byte-identical to the pre-000019 cap-only behavior.
    param([object[]]$Records, $Ranges, [int]$PerFileCap)
    $recs = @($Records)
    $total = $recs.Count
    $scopeApplied = ($null -ne $Ranges) -and (@($Ranges).Count -gt 0)
    $scoped = if ($scopeApplied) { @(Select-DiagnosticsInRange $recs $Ranges) } else { $recs }
    $surfaced = @($scoped).Count
    if ($PerFileCap -gt 0 -and $surfaced -gt $PerFileCap) {
        $shown = @($scoped[0..($PerFileCap - 1)]); $omitted = $surfaced - $PerFileCap
    } else {
        $shown = @($scoped); $omitted = 0
    }
    return @{ shown = @($shown); omitted = $omitted; total = $total; surfaced = $surfaced; scopeApplied = $scopeApplied }
}
