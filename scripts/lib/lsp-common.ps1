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

# --- downloaded-dependency integrity (dispatch 000046, Gap B L2) ------------
# The plugin downloads PSES (a GitHub release zip) and PSScriptAnalyzer (a PowerShell
# Gallery .nupkg). Both are hashed against a SHA-256 pin COMPUTED FROM THE REAL known-good
# artifact (Get-FileHash on the actual pinned download) right after download and BEFORE the
# bundle is used. A match proceeds exactly as before; a mismatch is treated by the caller as
# FAIL CLOSED -- refuse the unverified bundle, leave any prior working bundle intact, exit
# non-zero so SessionStart surfaces the existing honest 'unavailable' banner, and keep the
# hook itself exiting 0 (editing is never broken; the analyzer is simply OFF until a verified
# bundle lands). This adds NO diagnostics status token: it reuses the 000024/000028
# 'unavailable' surface, so the 000027 contract drift-guard stays green.

function Test-PinnedFileHash {
    # Return $true ONLY when the file at $Path hashes (SHA-256) EXACTLY to $ExpectedSha256
    # (compared case-insensitively -- Get-FileHash emits upper-case hex). Returns $false on
    # ANY other outcome: a blank pin, a missing/unreadable file, a hash that cannot be
    # computed, or a genuine mismatch. The conservative direction is deliberate -- the caller
    # fails CLOSED on $false, so an unreadable artifact or an empty pin can never be mistaken
    # for "verified." PURE over the file bytes; no side effects, nothing written to any stream.
    param([string]$Path, [string]$ExpectedSha256)
    if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) { return $false }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $actual = ''
    try { $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path -ErrorAction Stop).Hash } catch { return $false }
    if ([string]::IsNullOrWhiteSpace($actual)) { return $false }
    return [string]::Equals($actual, $ExpectedSha256, [System.StringComparison]::OrdinalIgnoreCase)
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

function Get-PluginBaseSettingsPath {
    # Absolute path to the shipped plugin-owned base ruleset (rulesets/base.psd1) -- the
    # OPT-IN fallback the 'ruleset' knob selects when ruleset='base' and no repo-local
    # settings / explicit override resolve first (dispatch 000087). Located the SAME way as
    # Get-PluginManifestPath: walk up from this lib's dir (scripts/lib -> scripts -> root),
    # then fall back to $env:CLAUDE_PLUGIN_ROOT. Returns '' if not found -- the caller then
    # degrades to the PSES default rules (honest: base requested but unshipped never breaks
    # editing). DELIBERATELY named base.psd1, NOT PSScriptAnalyzerSettings.psd1, so the
    # repo-local discovery walk-up (which matches only that exact name) can NEVER auto-select
    # it -- it is reachable ONLY through this explicit resolver, so shipping it inside the
    # plugin tree does not change the plugin's own repo lint surface.
    $libDir = $script:LspCommonDir
    if ([string]::IsNullOrWhiteSpace($libDir)) { $libDir = $PSScriptRoot }
    if (-not [string]::IsNullOrWhiteSpace($libDir)) {
        $root = Split-Path -Parent (Split-Path -Parent $libDir)
        if (-not [string]::IsNullOrWhiteSpace($root)) {
            $candidate = Join-Path $root 'rulesets/base.psd1'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return [System.IO.Path]::GetFullPath($candidate) }
        }
    }
    $envRoot = $env:CLAUDE_PLUGIN_ROOT
    if (-not [string]::IsNullOrWhiteSpace($envRoot)) {
        $candidate = Join-Path $envRoot 'rulesets/base.psd1'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return [System.IO.Path]::GetFullPath($candidate) }
    }
    return ''
}

function Get-RulesetFallbackPath {
    # The no-repo-local, no-override fallback the 'ruleset' knob selects (dispatch 000087).
    # 'base' -> the shipped plugin base ruleset (broadens the live surface); ANY other value
    # (incl. the default 'pses-default') -> '' (PSES's own 15-rule no-settings allow-list --
    # byte-for-byte the pre-000087 behavior). When 'base' is requested but the base file
    # cannot be located, degrade to '' (PSES default) rather than fail: editing is never
    # broken and the analyzer stays honest.
    param([string]$Ruleset = 'pses-default')
    if ($Ruleset -eq 'base') {
        $basePath = Get-PluginBaseSettingsPath
        if (-not [string]::IsNullOrWhiteSpace($basePath)) { return $basePath }
    }
    return ''
}

function Resolve-PssaSettingsPath {
    # Resolve the ABSOLUTE settings .psd1 to honor, or '' if none. Precedence:
    #   explicit absolute override ($Override / the settingsPath knob)
    #     > nearest PSScriptAnalyzerSettings.psd1 walked up from the edited file's
    #       directory, bounded at (and including) the project root
    #     > the shipped plugin base ruleset when $Ruleset = 'base' (dispatch 000087)
    #     > '' (PSES loads its own 15-rule no-settings default set).
    # The base fallback is consulted ONLY after BOTH the override and the repo-local walk-up
    # come up empty (via Get-RulesetFallbackPath at every no-match exit), so a discovered
    # repo-local file or an explicit override ALWAYS wins over the base. With the default
    # $Ruleset = 'pses-default' the fallback returns '' -- byte-for-byte the pre-000087 path.
    # Best-effort and cheap: a path walk-up is a chain of stats, off the hot path (resolved
    # once per session).
    #
    # Adversarial control: drop the `$rootFull` bound (walk to the filesystem root) and the
    # 'settings file ABOVE the project root is not honored' unit test goes RED; return
    # $Override unconditionally and the 'relative override is ignored' test goes RED; return
    # a bare '' at the no-match exits instead of the ruleset fallback and the
    # 'ruleset=base broadens' / 'repo-local wins over base' tests go RED.
    param(
        [string]$EditedFilePath,
        [string]$ProjectRoot,
        [string]$Override = '',
        [string]$Ruleset = 'pses-default'
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
    if ([string]::IsNullOrWhiteSpace($EditedFilePath)) { return (Get-RulesetFallbackPath $Ruleset) }
    $fileFull = [System.IO.Path]::GetFullPath($EditedFilePath)
    $dir = [System.IO.Path]::GetDirectoryName($fileFull)
    if ([string]::IsNullOrWhiteSpace($dir)) { return (Get-RulesetFallbackPath $Ruleset) }

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
    # No explicit override and no repo-local settings resolved: the 'ruleset' knob decides
    # the fallback -- 'base' resolves the shipped plugin base ruleset, anything else '' (PSES
    # default). Repo-local / override already returned above, so they still win.
    return (Get-RulesetFallbackPath $Ruleset)
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
        [string]$SettingsPath = '',
        [string]$Ruleset = 'pses-default'
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
    # Pass -Ruleset ONLY when opted in ('base'); the daemon defaults to 'pses-default', so the
    # default path's daemon invocation is byte-identical to pre-000087 (no extra arg).
    if (-not [string]::IsNullOrWhiteSpace($Ruleset) -and $Ruleset -ne 'pses-default') { $daemonArgs += @('-Ruleset', $Ruleset) }
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

# --- pre-PSSA pack: non-ASCII smuggling detection (dispatch 000060) ----------
# A byte-level scan for smart-punctuation characters that PowerShell 5.1,
# reading a UTF-8-without-BOM file as Windows-1252, would silently mojibake.
# Scoped to the smart-punctuation set (em/en dash, smart quotes, arrow glyphs)
# and gated to fire ONLY on files without a UTF-8 BOM. This is a PURE function
# that returns findings independently of PSES/PSSA; it runs BEFORE the parser
# pre-pass in lsp-client.ps1 so it catches the mojibake case even when the
# file no longer parses.

function Find-NonAsciiSmuggling {
    <#
    .SYNOPSIS
        Scan a file for non-ASCII smart-punctuation characters that would
        mojibake under PS 5.1 reading UTF-8-without-BOM as Windows-1252.
    .DESCRIPTION
        Reads raw bytes. Returns findings only when the file has NO UTF-8 BOM
        AND contains smart-punctuation characters. BOM files are always safe.
        Returns @() for clean/absent/BOM files. Finding source = 'powershell-lsp',
        ruleId = 'NonAsciiChar'.
    #>
    param([string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0) { return @() }

    # UTF-8 BOM = 0xEF 0xBB 0xBF at position 0. Presence means the file
    # encoding is explicit and PowerShell 5.1 reads it correctly.
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return @()
    }

    $findings = New-Object System.Collections.ArrayList
    $line = 1; $col = 1; $i = 0; $n = $bytes.Length

    while ($i -lt $n) {
        $b = $bytes[$i]

        # Line tracking: LF
        if ($b -eq 0x0A) { $line++; $col = 1; $i++; continue }
        # CR (bare or part of CRLF): advance col only
        if ($b -eq 0x0D) { $col++; $i++; continue }

        # Smart punctuation is always a 3-byte UTF-8 sequence: 0xE2 0x<p2> 0x<p3>
        if ($b -eq 0xE2 -and $i + 2 -lt $n) {
            $b2 = $bytes[$i + 1]; $b3 = $bytes[$i + 2]

            # Group: 0xE2 0x80 ... dashes and quotes (U+2013, U+2014, U+2018,
            # U+2019, U+201C, U+201D). These are the most common AI-paste tell.
            if ($b2 -eq 0x80) {
                $name = switch ($b3) {
                    0x93 { 'en-dash' }
                    0x94 { 'em-dash' }
                    0x98 { 'left single quote' }
                    0x99 { 'right single quote' }
                    0x9C { 'left double quote' }
                    0x9D { 'right double quote' }
                    default { $null }
                }
                if ($null -ne $name) {
                    [void]$findings.Add([pscustomobject]@{
                        ruleId = 'NonAsciiChar'; code = 'NonAsciiChar'
                        source = 'powershell-lsp'
                        severity = 'Warning'; line = $line; col = $col
                        message = "Non-ASCII smart-punctuation character ($name) " +
                            "detected. This file has no UTF-8 BOM, so PowerShell " +
                            "5.1 will misinterpret it as Windows-1252."
                    })
                    $i += 3; $col++; continue
                }
            }
            # Group: 0xE2 0x86 0x92 -- right arrow (U+2192)
            if ($b2 -eq 0x86 -and $b3 -eq 0x92) {
                [void]$findings.Add([pscustomobject]@{
                    ruleId = 'NonAsciiChar'; code = 'NonAsciiChar'
                    source = 'powershell-lsp'
                    severity = 'Warning'; line = $line; col = $col
                    message = "Non-ASCII arrow glyph (right arrow) " +
                        "detected. This file has no UTF-8 BOM, so PowerShell " +
                        "5.1 will misinterpret it as Windows-1252."
                })
                $i += 3; $col++; continue
            }
            # Other 3-byte sequence (e.g. other Unicode), skip
            $i += 3; $col++; continue
        }

        # Multi-byte UTF-8 lead bytes that are NOT the smart-punctuation prefix:
        # 2-byte (0xC0-0xDF), other 3-byte (0xE0-0xEF excluding 0xE2 handled
        # above), 4-byte (0xF0-0xF7). Skip correctly so col stays in sync.
        if ($b -ge 0xC0) {
            if ($b -le 0xDF) { $i += 2 }
            elseif ($b -le 0xEF) { $i += 3 }
            elseif ($b -le 0xF7) { $i += 4 }
            else { $i++ }
            $col++; continue
        }

        # ASCII byte or continuation byte (0x80-0xBF)
        $i++; $col++
    }

    return @($findings)
}

# --- pre-PSSA pack: PowerShell 7-only syntax compatibility (dispatch 000096) --
# A syntax-only pass over the parser AST the pre-pass already produces (reusing the
# 000060 seam) that flags PowerShell-7-only SYNTAX an AI commonly emits into a file that
# may still run on Windows PowerShell 5.1: pipeline chains (&& / ||), the ternary operator
# (a ? b : c), and the null-coalescing / null-conditional family (?? / ??= / ?. / ?[]).
# Under pwsh 7 (the daemon's host) these PARSE, so the AST carries the nodes; under 5.1
# they are parse errors. The finding is SUPPRESSED when the file honestly declares
# #Requires -Version 7 (or higher) via ScriptRequirements.RequiredPSVersion -- a file that
# genuinely targets 7 is not a portability defect (the load-bearing 0-FP case). Same
# finding shape and source label as Find-NonAsciiSmuggling (source = 'powershell-lsp', a
# compatibility WARNING) with a distinct, stable check id. Always-on additive; no knob.
#
# HOST / StrictMode SAFETY: this lib is dot-sourced by BOTH pwsh 7 and Windows PowerShell
# 5.1, where the PS7 AST types (PipelineChainAst / TernaryExpressionAst), the TokenKind
# values (QuestionQuestion / QuestionQuestionEquals), and the NullConditional property do
# NOT exist. So detection uses type-NAME string comparisons, an enum-to-string operator
# compare, and a PSObject.Properties-guarded NullConditional probe -- never a type/enum
# literal or an unguarded property access that would throw under 5.1 or StrictMode. On 5.1
# the input AST never carries these nodes anyway (parse errors there), so the pass is @().

function Find-Ps7OnlySyntax {
    <#
    .SYNOPSIS
        Flag PowerShell-7-only syntax constructs in a parsed AST, suppressed when the file
        declares #Requires -Version 7 (or higher).
    .DESCRIPTION
        PURE over the supplied AST (the object the parser pre-pass already produces).
        Returns @() when the AST is $null, when the file declares #Requires -Version 7+
        (the load-bearing 0-FP: a file that targets 7 is not a portability defect), or when
        no 7-only syntax node is present. Otherwise one finding per 7-only node. Finding
        source = 'powershell-lsp', ruleId/code = 'PS7OnlySyntax', severity 'Warning' -- the
        same shape and channel as Find-NonAsciiSmuggling.
    #>
    param($Ast)
    if ($null -eq $Ast) { return @() }

    # Host-awareness suppression (the load-bearing 0-FP). RequiredPSVersion is a [version]
    # (or $null when no #Requires -Version). Guarded so a shape lacking ScriptRequirements
    # can never throw.
    try {
        $req = $Ast.ScriptRequirements
        if ($null -ne $req) {
            $rv = $req.RequiredPSVersion
            if ($null -ne $rv -and [int]$rv.Major -ge 7) { return @() }
        }
    } catch { }

    # Match the 7-only node types. Type-NAME string checks + a PSObject-guarded
    # NullConditional probe keep this safe on Windows PowerShell 5.1 + StrictMode (see the
    # section header). InvokeMemberExpressionAst derives from MemberExpressionAst and also
    # carries NullConditional, so the property probe catches ?. on both member access and
    # method invocation; IndexExpressionAst carries it for ?[].
    $predicate = {
        param($node)
        $tn = $node.GetType().Name
        if ($tn -eq 'PipelineChainAst') { return $true }
        if ($tn -eq 'TernaryExpressionAst') { return $true }
        if ($tn -eq 'BinaryExpressionAst') { return ([string]$node.Operator -eq 'QuestionQuestion') }
        if ($tn -eq 'AssignmentStatementAst') { return ([string]$node.Operator -eq 'QuestionQuestionEquals') }
        $nc = $node.PSObject.Properties['NullConditional']
        if ($null -ne $nc) { return [bool]$nc.Value }
        return $false
    }
    $nodes = @()
    try { $nodes = @($Ast.FindAll($predicate, $true)) } catch { return @() }

    $findings = New-Object System.Collections.ArrayList
    foreach ($node in $nodes) {
        $line = 1; $col = 1
        try { $line = [int]$node.Extent.StartLineNumber } catch { $line = 1 }
        try { $col = [int]$node.Extent.StartColumnNumber } catch { $col = 1 }
        $construct = switch ($node.GetType().Name) {
            'PipelineChainAst'       { 'pipeline chain operator && or ||' }
            'TernaryExpressionAst'   { 'ternary operator a ? b : c' }
            'BinaryExpressionAst'    { 'null-coalescing operator ??' }
            'AssignmentStatementAst' { 'null-coalescing assignment ??=' }
            'IndexExpressionAst'     { 'null-conditional index ?[]' }
            default                  { 'null-conditional operator ?.' }
        }
        [void]$findings.Add([pscustomobject]@{
            ruleId = 'PS7OnlySyntax'; code = 'PS7OnlySyntax'
            source = 'powershell-lsp'
            severity = 'Warning'; line = $line; col = $col
            message = "PowerShell 7-only syntax ($construct) detected. This is a parse " +
                "error under Windows PowerShell 5.1; add '#Requires -Version 7' if this " +
                "file targets PowerShell 7 only."
        })
    }
    return @($findings)
}

# --- module surface / project intelligence (PL-6, dispatch 000062) -----------
# Manifest-consistency helpers for the daemon-side module surface cache. The daemon
# caches the module surface ONCE per session keyed by manifest path + content hash;
# per-edit is a cache lookup + cheap cross-reference. These helpers are the PURE
# data-extraction layer and are also unit-testable independent of the cache.
#
# HONEST DEGRADE (never guess): on a wildcard '*' export, a runtime/dynamic
# Export-ModuleMember, dot-sourcing the static pass cannot follow, or a native
# (binary) RootModule, the check says "cannot determine the module export surface;
# manifest-consistency not checked" rather than emitting a false orphan. A
# missing/$null FunctionsToExport (means "export all" in some PS versions) is also
# treated as indeterminate.
#
# unused-export is EXPLICITLY NOT in slice 1 (the survey ranked it down as
# wrong-by-design: a public export's purpose IS external callers, so "unused within
# the module" is the normal state). See 000058 outbox for the full FP analysis.

function Find-ModuleManifest {
    # Walk UP from $FilePath to locate the nearest module manifest (.psd1) that
    # declares FunctionsToExport, CmdletsToExport, AliasesToExport, or RootModule.
    # Returns the absolute path of the manifest, or '' if none found. Bounded at
    # the filesystem root (same walking pattern as Resolve-PssaSettingsPath).
    param([string]$FilePath)
    if ([string]::IsNullOrWhiteSpace($FilePath)) { return '' }
    $full = [System.IO.Path]::GetFullPath($FilePath)
    $dir = [System.IO.Path]::GetDirectoryName($full)
    if ([string]::IsNullOrWhiteSpace($dir)) { return '' }
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $alt = [System.IO.Path]::AltDirectorySeparatorChar
    $cur = $dir
    while (-not [string]::IsNullOrWhiteSpace($cur)) {
        $candidates = @()
        try { $candidates = @(Get-ChildItem -LiteralPath $cur -Filter '*.psd1' -File -ErrorAction SilentlyContinue) } catch { }
        foreach ($f in $candidates) {
            try {
                $data = Import-PowerShellDataFile -LiteralPath $f.FullName -ErrorAction SilentlyContinue
                if ($null -ne $data) {
                    # Recognise a module manifest: declares any export list or has a RootModule.
                    # Index, never dot-access: $data is a Hashtable and a missing key via dot
                    # access throws under StrictMode (see Get-ModuleManifestExports). The catch
                    # would swallow that, but it would skip an otherwise-valid manifest that
                    # merely omits one of these keys -- so use the null-safe indexer.
                    $hasExports = ($null -ne $data['FunctionsToExport']) -or `
                        ($null -ne $data['CmdletsToExport']) -or `
                        ($null -ne $data['AliasesToExport']) -or `
                        (-not [string]::IsNullOrWhiteSpace([string]$data['RootModule']))
                    if ($hasExports) { return $f.FullName }
                }
            } catch { }
        }
        $parent = [System.IO.Path]::GetDirectoryName($cur)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $cur) { break }
        $cur = $parent
    }
    return ''
}

function Get-ModuleManifestExports {
    # Extract export lists from a module manifest (.psd1) via Import-PowerShellDataFile.
    # Returns a hashtable with the string arrays for each export type, or $null on
    # failure. The caller determines if the export is determinate (not '*') or wildcard.
    param([string]$ManifestPath)
    if ([string]::IsNullOrWhiteSpace($ManifestPath) -or -not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { return $null }
    try {
        $data = Import-PowerShellDataFile -LiteralPath $ManifestPath -ErrorAction Stop
        if ($null -eq $data) { return $null }
        # Index, never dot-access: Import-PowerShellDataFile returns a Hashtable, and under
        # Set-StrictMode -Version Latest a MISSING key via $data.CmdletsToExport THROWS
        # ("property cannot be found"), whereas the indexer $data['CmdletsToExport'] returns
        # $null. Most real manifests omit CmdletsToExport/AliasesToExport, so dot-access here
        # made the whole parse throw -> caught -> $null -> the daemon reported "could not
        # parse manifest" (a false indeterminate) for any manifest lacking all three lists.
        $fto = $data['FunctionsToExport']
        $cto = $data['CmdletsToExport']
        $ato = $data['AliasesToExport']
        $rootModule = [string]$data['RootModule']
        # Normalise export lists to string arrays.
        $fnArr = if ($null -eq $fto) { @() } elseif ($fto -is [array]) { @($fto | ForEach-Object { [string]$_ }) } else { @([string]$fto) }
        $cmdArr = if ($null -eq $cto) { @() } elseif ($cto -is [array]) { @($cto | ForEach-Object { [string]$_ }) } else { @([string]$cto) }
        $aliasArr = if ($null -eq $ato) { @() } elseif ($ato -is [array]) { @($ato | ForEach-Object { [string]$_ }) } else { @([string]$ato) }
        # Resolve RootModule to an absolute path (relative to the manifest directory).
        $rootModulePath = ''
        if (-not [string]::IsNullOrWhiteSpace($rootModule)) {
            $rootModulePath = $rootModule
            if (-not [System.IO.Path]::IsPathRooted($rootModulePath)) {
                $rootModulePath = [System.IO.Path]::GetFullPath((Join-Path ([System.IO.Path]::GetDirectoryName($ManifestPath)) $rootModulePath))
            }
        }
        return @{
            ManifestPath = $ManifestPath
            FunctionsToExport = $fnArr
            CmdletsToExport = $cmdArr
            AliasesToExport = $aliasArr
            RootModule = $rootModulePath
            Data = $data
        }
    } catch { return $null }
}

function Resolve-ModuleRootModulePath {
    # Resolve the RootModule declared by a manifest to an absolute file path.
    # Returns the path, or '' if none/missing/binary (a .dll or .exe).
    param([string]$ManifestDir, [string]$RootModule)
    if ([string]::IsNullOrWhiteSpace($RootModule)) { return '' }
    $path = $RootModule
    if (-not [System.IO.Path]::IsPathRooted($path)) {
        $path = [System.IO.Path]::GetFullPath((Join-Path $ManifestDir $path))
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    $ext = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
    if ($ext -eq '.psm1' -or $ext -eq '.ps1') { return $path }
    return ''   # binary module (dll/exe) or unknown -> cannot inspect
}

function Get-ModuleDefinedFunctionNames {
    # AST-enumerate a .psm1/.ps1 for FunctionDefinitionAst names and detect
    # Export-ModuleMember. Returns a hashtable:
    #   @{ DefinedNames = @(...);    # sorted unique function names
    #      ExportedNames = $null|@()  # $null = all defined are exported (no explicit Export-ModuleMember)
    #                                 # @(...) = explicitly exported names
    #      Degrade = ''               # non-empty when the shape is indeterminate
    #      HasDotSource = $bool       # whether the file contains dot-source operations
    #    }
    param([string]$ModuleFilePath)
    if ([string]::IsNullOrWhiteSpace($ModuleFilePath) -or -not (Test-Path -LiteralPath $ModuleFilePath -PathType Leaf)) {
        return @{ DefinedNames = @(); ExportedNames = $null; Degrade = ''; HasDotSource = $false }
    }
    $defined = New-Object System.Collections.Generic.HashSet[string]
    $exported = New-Object System.Collections.Generic.List[string]
    $degrade = ''
    $hasDotSource = $false
    try {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ModuleFilePath, [ref]$null, [ref]$null)
        # Collect all function definition names.
        $fnNodes = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
        foreach ($fn in $fnNodes) { [void]$defined.Add($fn.Name) }
        # Detect dot-sourcing (. ./file.ps1).
        $cmdNodes = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true))
        foreach ($cmd in $cmdNodes) {
            $elems = @(Get-Prop $cmd 'CommandElements')
            if ($elems.Count -ge 1) {
                $first = [string]$elems[0]
                if ($first -eq '.' -or $first -eq '.source') { $hasDotSource = $true; break }
            }
        }
        # Scan for Export-ModuleMember (skip if dot-sourced -> indeterminate shape).
        if (-not $hasDotSource) {
            foreach ($cmd in $cmdNodes) {
                $elems = @(Get-Prop $cmd 'CommandElements')
                if ($elems.Count -ge 1) {
                    $first = [string]$elems[0]
                    if ($first -eq 'Export-ModuleMember') {
                        # Check for dynamic/runtime arguments.
                        $hasDynamic = $false
                        foreach ($ce in $elems) {
                            if ($ce -is [System.Management.Automation.Language.VariableExpressionAst] -or
                                $ce -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
                                $hasDynamic = $true; break
                            }
                        }
                        if ($hasDynamic) { $degrade = 'dynamic Export-ModuleMember'; break }
                        # Extract static -Function / -Cmdlet / -Alias names.
                        $i = 0
                        while ($i -lt $elems.Count) {
                            $ceStr = [string]$elems[$i]
                            if ($ceStr -eq '-Function' -or $ceStr -eq '-Cmdlet' -or $ceStr -eq '-Alias') {
                                $i++
                                while ($i -lt $elems.Count) {
                                    $val = $elems[$i]
                                    $valStr = [string]$val
                                    if ($valStr.StartsWith('-')) { break }
                                    if ($val -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                                        $exported.Add($val.Value)
                                    } elseif ($val -is [System.Management.Automation.Language.VariableExpressionAst]) {
                                        $hasDynamic = $true; break
                                    }
                                    $i++
                                }
                                if ($hasDynamic) { break }
                            } else { $i++ }
                        }
                        if ($hasDynamic) { $degrade = 'dynamic Export-ModuleMember'; break }
                    }
                }
            }
        }
        if ($hasDotSource) { $degrade = 'dot-sourced definitions; shape is indeterminate' }
    } catch {
        $degrade = 'could not parse module file: ' + $_.Exception.Message
    }
    if (-not [string]::IsNullOrWhiteSpace($degrade)) {
        return @{ DefinedNames = @($defined | Sort-Object); ExportedNames = $null; Degrade = $degrade; HasDotSource = $hasDotSource }
    }
    if ($exported.Count -gt 0) {
        return @{ DefinedNames = @($defined | Sort-Object); ExportedNames = @($exported); Degrade = ''; HasDotSource = $hasDotSource }
    }
    # No explicit Export-ModuleMember found: by default everything defined is exported.
    return @{ DefinedNames = @($defined | Sort-Object); ExportedNames = $null; Degrade = ''; HasDotSource = $hasDotSource }
}

function Test-ManifestConsistency {
    # Core manifest-consistency check (PURE over injected data). Given the manifest
    # export lists and the module's defined/exported function names, return findings
    # for orphan/typo exports and under-declared exports.
    #
    # Returns @{ Findings = @(...); Degrade = '' } for determinate shapes.
    # Returns @{ Findings = @(); Degrade = '<reason>' } for indeterminate (wildcard,
    #   dynamic, dot-source, etc.) -- the caller surfaces "cannot determine" as prose.
    #
    # orphan-export: a name in FunctionsToExport/CmdletsToExport/AliasesToExport
    #   that does not match any defined function name in the module.
    # under-declared-export: a function defined AND exported (stated or implicitly)
    #   but absent from the manifest's export lists.
    param(
        [string[]]$FunctionsToExport,
        [string[]]$CmdletsToExport,
        [string[]]$AliasesToExport,
        [string[]]$DefinedNames,
        $ExportedNames,              # $null = implicitly all defined are exported
        [string]$ManifestPath
    )
    $findings = New-Object System.Collections.ArrayList
    # Check for wildcard -- '*' means "export all" and cannot be inconsistent.
    $isWildcard = ($FunctionsToExport -contains '*') -or ($CmdletsToExport -contains '*') -or ($AliasesToExport -contains '*')
    if ($isWildcard) {
        return @{ Findings = @(); Degrade = 'wildcard export (*)' }
    }
    # Treat missing/$null FunctionsToExport as indeterminate (means "export all" in some PS versions).
    $functionsIndeterminate = ($null -eq $FunctionsToExport) -or ($FunctionsToExport.Count -eq 0 -and @($FunctionsToExport).Count -eq 0)
    if ($functionsIndeterminate) {
        return @{ Findings = @(); Degrade = 'FunctionsToExport is empty/null (may mean export-all)' }
    }
    # Build the set of exported names we expect to find in the module.
    # Only FunctionsToExport is checked in slice 1 (CmdletsToExport and AliasesToExport
    # are recorded but not cross-referenced -- the survey's deterministic subset
    # focuses on function exports).
    $namedSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $FunctionsToExport) { [void]$namedSet.Add($n) }
    # Determine what the module actually defines and exports.
    $moduleDefinedSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $DefinedNames) { [void]$moduleDefinedSet.Add($n) }
    # Which exported names does the module claim?
    $moduleExportedSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    if ($null -eq $ExportedNames) {
        # No explicit Export-ModuleMember: everything defined is implicitly exported.
        foreach ($n in $DefinedNames) { [void]$moduleExportedSet.Add($n) }
    } else {
        foreach ($n in $ExportedNames) { [void]$moduleExportedSet.Add($n) }
    }
    # 1. ORPHAN EXPORT: manifest names that do NOT match any defined function.
    foreach ($name in $FunctionsToExport) {
        $nn = [string]$name
        if (-not $moduleDefinedSet.Contains($nn)) {
            [void]$findings.Add([pscustomobject]@{
                ruleId = 'ManifestConsistency'; code = 'ManifestConsistency'
                source = 'powershell-lsp'
                severity = 'Warning'; line = 1; col = 1
                message = "Function '$nn' is listed in FunctionsToExport but no matching function definition was found in the module."
            })
        }
    }
    # 2. UNDER-DECLARED EXPORT: a function defined AND exported by the module but
    #    absent from the manifest export list.
    foreach ($name in @($moduleExportedSet)) {
        if (-not $namedSet.Contains($name)) {
            [void]$findings.Add([pscustomobject]@{
                ruleId = 'ManifestConsistency'; code = 'ManifestConsistency'
                source = 'powershell-lsp'
                severity = 'Warning'; line = 1; col = 1
                message = "Function '$name' is defined and exported by the module but is missing from FunctionsToExport in the manifest."
            })
        }
    }
    return @{ Findings = @($findings); Degrade = '' }
}

function Get-ProjectIntelligenceFindings {
    # Top-level project-intelligence entry point: given the edited file path, walk
    # up to find the module manifest, parse exports, AST-enumerate the RootModule,
    # and cross-reference. Returns the findings array (empty = no issues OR
    # indeterminate). The daemon calls this and caches the module surface so the
    # expensive walk/parse is one-shot per session.
    #
    # Returns @{ Findings = @(...); Degrade = '' } for determinate findings, or
    # @{ Findings = @(); Degrade = '<reason>' } for indeterminate.
    param([string]$EditedFilePath)
    $manifestPath = Find-ModuleManifest -FilePath $EditedFilePath
    if ([string]::IsNullOrWhiteSpace($manifestPath)) {
        return @{ Findings = @(); Degrade = 'no module manifest found' }
    }
    $exports = Get-ModuleManifestExports -ManifestPath $manifestPath
    if ($null -eq $exports) {
        return @{ Findings = @(); Degrade = 'could not parse module manifest' }
    }
    # Resolve RootModule (.psm1).
    $manifestDir = [System.IO.Path]::GetDirectoryName($manifestPath)
    $rootModulePath = Resolve-ModuleRootModulePath -ManifestDir $manifestDir -RootModule ([string]$exports.RootModule)
    if ([string]::IsNullOrWhiteSpace($rootModulePath)) {
        # No module file to cross-reference -- either no RootModule declared, or binary.
        return @{ Findings = @(); Degrade = 'no RootModule to inspect; manifest exports cannot be cross-referenced' }
    }
    $moduleInfo = Get-ModuleDefinedFunctionNames -ModuleFilePath $rootModulePath
    if (-not [string]::IsNullOrWhiteSpace($moduleInfo.Degrade)) {
        return @{ Findings = @(); Degrade = $moduleInfo.Degrade }
    }
    # Cross-reference.
    return Test-ManifestConsistency `
        -FunctionsToExport $exports.FunctionsToExport `
        -CmdletsToExport $exports.CmdletsToExport `
        -AliasesToExport $exports.AliasesToExport `
        -DefinedNames $moduleInfo.DefinedNames `
        -ExportedNames $moduleInfo.ExportedNames `
        -ManifestPath $manifestPath
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

# --- closed-loop agentic correction (dispatch 000061, PL-4 slice 1) -----------
# After Claude applies a fix, the daemon re-checks the same range on the NEXT edit turn and
# reports whether a previously-surfaced finding CLEARED (a fix landed) or is STILL-PRESENT
# (the edit did not clear it) -- instead of passively handing context back. The prior-surfaced
# memory lives in the warm daemon (the only per-session-persistent component, per the 000056
# survey); these helpers are the PURE, unit-testable core of the diff so the daemon stays thin.
#
# Range identity is by CONTENT SHAPE, not line number: Get-DiagnosticShapeHash (ruleId +
# normalized offending line, already used by the dogfood capture). An edit that inserts/deletes
# lines above a finding leaves its offending text -- and so its shape-hash -- unchanged, so the
# finding is tracked as still-present (or moved), never mistaken for cleared.
#
# MOVED folds into still-present for slice 1 (the 000056 outbox governs over the 000061 inbox's
# four-way CLEARED/STILL-PRESENT/MOVED/NEW summary: the survey's first slice says "MOVED can fold
# into still-present for slice 1", and the inbox's OQ3 pre-authorization prefers the conservative
# signal over a confident-but-wrong MOVED label). A moved finding has the SAME shape-hash at a new
# line, so it reads as still-present, never as a false cleared.
#
# NO new status token and NO new userConfig knob: the signal rides the existing surface as additive
# output fields (cleared[]/stillPresent[]) plus client prose -- finding-lifecycle is a different
# axis from the analyzer-health taxonomy (ok/incomplete/degraded/unavailable), so folding it into a
# token would muddy the frozen clean-empty property. An additive field is a drift-guard-green MINOR.

function New-LifecycleFinding {
    # Project ONE daemon diagnostic record to its lifecycle shape: { hash; ruleId; line; message }.
    # ruleId mirrors the dogfood derivation (the rule code when present and not '0', else ''); the
    # offending line is read from the post-edit file at the record's 1-based line (or '' when out of
    # range). StrictMode-safe: every local is initialized before use, and record fields are read via
    # the null-safe indexer (records are ordered hashtables from ConvertTo-DiagRecord; a dot-access
    # on a missing key throws under StrictMode -- the 000062 class of bug).
    param($Record, [string[]]$Lines)
    $line = 0
    if ($null -ne $Record) { $lv = $Record['line']; if ($null -ne $lv) { $line = [int]$lv } }
    $code = ''
    if ($null -ne $Record) { $cv = $Record['code']; if ($null -ne $cv) { $code = [string]$cv } }
    $ruleId = if ($code -and $code -ne '0') { $code } else { '' }
    $msg = ''
    if ($null -ne $Record) { $mv = $Record['message']; if ($null -ne $mv) { $msg = [string]$mv } }
    $offending = ''
    if ($null -ne $Lines -and $line -ge 1 -and $line -le $Lines.Count) { $offending = [string]$Lines[$line - 1] }
    $hash = Get-DiagnosticShapeHash -RuleId $ruleId -OffendingLine $offending
    return [pscustomobject]@{ hash = $hash; ruleId = $ruleId; line = $line; message = $msg }
}

function Get-FindingLifecycleDiff {
    # PURE diff of this pass's findings against what was SURFACED for the same document last turn.
    # Inputs (all projected to { hash; ruleId; line; message } by New-LifecycleFinding):
    #   PriorMap        -- shapeHash -> @{ ruleId; line; message; attempts } surfaced last turn.
    #   CurrentFull     -- EVERY finding from this turn's whole-file pass (the cleared probe).
    #   CurrentSurfaced -- the findings SURFACED this turn (scoped to the touched range R).
    #   ScopeApplied    -- $true only when a determinate range R was scoped (else whole-file, so we
    #                      cannot say the edit "touched" any one finding -> no still-present escalation).
    #   MaxAttempts (K) -- escalate still-present at most K times (attempts 1..K), then ONE neutral
    #                      downgrade (attempt K+1), then silence -- the 000056 bounded-escalation rule.
    # Returns @{ Cleared=@(...); StillPresent=@(...); NewMap=@{...} }. StrictMode-safe throughout
    # (every collection initialized before use; hashtable access via ContainsKey + indexer).
    #
    # CLEARED        = a prior-surfaced shape-hash ABSENT from CurrentFull (genuinely gone).
    # STILL-PRESENT  = a prior-surfaced shape-hash still in CurrentSurfaced (present AND re-touched).
    # NEW            = a surfaced shape-hash not seen last turn -> rides the normal surface (no entry).
    # Carry-forward  = a prior shape-hash still in CurrentFull but NOT surfaced this turn (present, not
    #                  touched) is kept in NewMap with its attempts unchanged, so a later clear is still
    #                  seen across an intervening edit that did not touch it.
    param(
        [hashtable]$PriorMap = @{},
        [object[]]$CurrentFull = @(),
        [object[]]$CurrentSurfaced = @(),
        [bool]$ScopeApplied = $false,
        [int]$MaxAttempts = 2
    )
    if ($null -eq $PriorMap) { $PriorMap = @{} }
    $curFull = @(@($CurrentFull) | Where-Object { $null -ne $_ })
    $curSurf = @(@($CurrentSurfaced) | Where-Object { $null -ne $_ })

    $fullHashes = New-Object System.Collections.Generic.HashSet[string]
    foreach ($r in $curFull) { [void]$fullHashes.Add([string]$r.hash) }

    # ArrayList, not List[object]: under StrictMode, @($genericList) inside a hashtable-literal
    # value throws "Argument types do not match" -- the house pattern here is ArrayList (see
    # Find-NonAsciiSmuggling / Test-ManifestConsistency), which round-trips cleanly through @().
    $cleared = New-Object System.Collections.ArrayList
    $stillPresent = New-Object System.Collections.ArrayList
    $newMap = @{}

    # 1. CLEARED: prior-surfaced findings absent from the whole-file pass.
    foreach ($h in @($PriorMap.Keys)) {
        $hk = [string]$h
        if (-not $fullHashes.Contains($hk)) {
            $meta = $PriorMap[$hk]
            [void]$cleared.Add([pscustomobject]@{
                ruleId  = [string]$meta['ruleId']
                line    = [int]$meta['line']
                message = [string]$meta['message']
            })
        }
    }

    # 2. Findings surfaced THIS turn -> new memory + still-present escalation (bounded).
    foreach ($r in $curSurf) {
        $hk = [string]$r.hash
        if ($newMap.ContainsKey($hk)) { continue }   # de-dupe within this turn's surfaced set
        $wasPrior = $PriorMap.ContainsKey($hk)
        if ($wasPrior) {
            $priorAttempts = [int]$PriorMap[$hk]['attempts']
            if ($ScopeApplied) {
                # A DETERMINATE touch of R that did not clear the finding -> a counted attempt.
                $attempts = $priorAttempts + 1
                if ($attempts -le $MaxAttempts) {
                    [void]$stillPresent.Add([pscustomobject]@{
                        ruleId = [string]$r.ruleId; line = [int]$r.line; message = [string]$r.message
                        attempts = $attempts; downgraded = $false })
                } elseif ($attempts -eq ($MaxAttempts + 1)) {
                    [void]$stillPresent.Add([pscustomobject]@{
                        ruleId = [string]$r.ruleId; line = [int]$r.line; message = [string]$r.message
                        attempts = $attempts; downgraded = $true })
                }   # attempts > MaxAttempts + 1 -> emit nothing (stop re-reporting; never an infinite nag)
            } else {
                # No determinate R (whole-file fail-open): the edit cannot be attributed to this one
                # finding, so it is NOT a counted attempt and is NOT escalated -- attempts carries over.
                $attempts = $priorAttempts
            }
            $newMap[$hk] = @{ ruleId = [string]$r.ruleId; line = [int]$r.line; message = [string]$r.message; attempts = $attempts }
        } else {
            # NEW this turn -> rides the normal diagnostics surface; attempts starts at 0 so the FIRST
            # re-surfacing next turn reads as attempt 1.
            $newMap[$hk] = @{ ruleId = [string]$r.ruleId; line = [int]$r.line; message = [string]$r.message; attempts = 0 }
        }
    }

    # 3. Carry forward prior findings still present (in full) but NOT surfaced this turn (untouched).
    foreach ($h in @($PriorMap.Keys)) {
        $hk = [string]$h
        if ($newMap.ContainsKey($hk)) { continue }
        if ($fullHashes.Contains($hk)) {
            $meta = $PriorMap[$hk]
            $newMap[$hk] = @{ ruleId = [string]$meta['ruleId']; line = [int]$meta['line']; message = [string]$meta['message']; attempts = [int]$meta['attempts'] }
        }
        # else: absent from full -> cleared (already reported) -> drop from memory
    }

    return @{ Cleared = @($cleared); StillPresent = @($stillPresent); NewMap = $newMap }
}

# --- format-on-edit: suggest, never rewrite (dispatch 000059, PL-8) -----------
# An OFF-BY-DEFAULT formatOnEdit knob. When 'suggest', the warm daemon runs
# PSScriptAnalyzer's Invoke-Formatter on the edited file -- honoring the repo's
# PSScriptAnalyzerSettings.psd1 formatter rules (the 000018 repo-local-settings
# precedent) -- and the result is surfaced as a SUGGESTION (a capped unified diff) via
# the existing additionalContext channel. The hook NEVER rewrites the user's file:
# suggest-not-apply is the WHOLE safety posture of this feature. A formatting failure
# (no formatter, a bad/malformed settings file, a formatter throw) degrades honestly --
# no suggestion is surfaced, it is logged, and the hook still exits 0; editing is never
# broken. The vendored, pinned-hash PSSA (000046 L2) is reused -- NO second acquisition
# path -- and the format runs on the warm daemon, so no cold-start is added.
#
# The knob is an ENUM ('off' | 'suggest', default 'off'), NOT a boolean, so a future
# 'apply' mode could be added as an additive enum value without a breaking knob change.
# No apply path exists today (it is a separate, higher-risk dispatch Mike may mint later).
# These helpers are PURE and unit-testable: the formatter invocation is isolated in
# Invoke-RepoFormatter (which assumes the caller imported the vendored PSSA), the diff is
# computed by Get-FormatDiffResult, and the surface wording by Format-FormattingSuggestionBlock.

function ConvertTo-FormatOnEditMode {
    # Map the raw formatOnEdit knob string to a mode: 'off' | 'suggest'. Default-safe: absent
    # / blank / an unexpanded '${user_config...}' token / any unrecognized value -> 'off' (the
    # feature is opt-in; an unparseable knob never silently turns it on). 'suggest' is the only
    # ON value today; 'true'/'on'/'1'/'yes' are accepted aliases for it so a user who reaches
    # for a boolean still gets the suggest behavior. 'apply' is RESERVED for a future dispatch
    # and maps to 'off' here -- no apply path ships, and no current config depends on 'apply'.
    param([string]$Raw)
    $v = ([string]$Raw).Trim().ToLowerInvariant()
    switch ($v) {
        'suggest' { return 'suggest' }
        'true'    { return 'suggest' }
        'on'      { return 'suggest' }
        '1'       { return 'suggest' }
        'yes'     { return 'suggest' }
        default   { return 'off' }
    }
}

function Find-VendoredPssaManifest {
    # Locate the vendored PSScriptAnalyzer manifest (PSScriptAnalyzer.psd1) under the
    # pinned-hash vendor dir (Get-PssaModuleDir) -- the SAME module ensure-pssa.ps1 produced
    # (000046 L2). Returns the manifest's absolute path, or '' if not present. This only
    # RESOLVES what ensure-pssa already vendored: NO download, NO second acquisition path.
    # Shallowest match wins (mirrors ensure-pssa.ps1's Find-PssaManifest).
    $vendorDir = Get-PssaModuleDir
    if ([string]::IsNullOrWhiteSpace($vendorDir) -or -not (Test-Path -LiteralPath $vendorDir)) { return '' }
    try {
        $m = Get-ChildItem -LiteralPath $vendorDir -Recurse -Filter 'PSScriptAnalyzer.psd1' -File -ErrorAction SilentlyContinue |
            Sort-Object { $_.FullName.Length } | Select-Object -First 1
        if ($null -ne $m) { return $m.FullName }
    } catch { }
    return ''
}

function Invoke-RepoFormatter {
    # Run PSScriptAnalyzer's Invoke-Formatter over $Text, honoring $SettingsPath when a
    # non-empty path is given (the repo's PSScriptAnalyzerSettings.psd1 formatter rules,
    # 000018). ASSUMES Invoke-Formatter is already importable in the caller's process (the
    # daemon imports the vendored PSSA once -- see Initialize-FormatterModule in the daemon).
    # PURE w.r.t. the file system: it formats a STRING and returns a result -- reads no file,
    # writes no file (suggest-not-apply). NEVER throws: every failure (no Invoke-Formatter, a
    # bad/malformed settings file -- which Invoke-Formatter raises as a terminating
    # ArgumentException -- or any formatter error) is caught and returned as ok=$false with a
    # reason, so the caller degrades honestly. Returns:
    #   @{ ok = $true;  formatted = <string> }                  on success
    #   @{ ok = $false; error = <message>; reason = <code> }    on any failure
    param([string]$Text, [string]$SettingsPath = '')
    if ($null -eq (Get-Command Invoke-Formatter -ErrorAction SilentlyContinue)) {
        return @{ ok = $false; error = 'Invoke-Formatter not available'; reason = 'no-formatter' }
    }
    # Normalize line endings to LF before formatting. Invoke-Formatter THROWS ("Cannot determine
    # line endings...") on a file with MIXED CRLF/LF -- a common real-world state after edits across
    # tools -- so without this a mixed-ending file would always degrade to no-suggestion. This is
    # transparent to the surfaced diff: Get-FormatDiffResult normalizes BOTH sides to LF for its
    # comparison, so a pure line-ending delta never shows up as a formatting change, and the user's
    # file is never touched regardless (suggest-not-apply).
    $normalized = (([string]$Text) -replace "`r`n", "`n") -replace "`r", "`n"
    try {
        $formatted = $null
        if (-not [string]::IsNullOrWhiteSpace($SettingsPath)) {
            $formatted = Invoke-Formatter -ScriptDefinition $normalized -Settings $SettingsPath
        } else {
            $formatted = Invoke-Formatter -ScriptDefinition $normalized
        }
        if ($null -eq $formatted) { return @{ ok = $false; error = 'formatter returned null'; reason = 'null-result' } }
        return @{ ok = $true; formatted = [string]$formatted }
    } catch {
        return @{ ok = $false; error = $_.Exception.Message; reason = 'formatter-error' }
    }
}

function Get-FormatDiffResult {
    # PURE line-based unified diff (via an LCS) between $Original and $Formatted, plus the
    # changed-line counts -- the shape surfaced as a formatting SUGGESTION (never applied).
    # Line endings are normalized to LF for the comparison, so a pure CRLF/LF delta does NOT
    # read as a whole-file change. The diff is CAPPED at $MaxLines body lines; the overflow
    # collapses into a truncation marker so a large reflow never floods the surface.
    # Returns @{ changed=<bool>; diff=<string>; removed=<int>; added=<int>; truncated=<bool> }.
    # 'changed' is $false (and 'diff' empty) when the two texts are identical (case-sensitive)
    # -- the caller then surfaces nothing, preserving the clean-edit-emits-nothing property.
    param([string]$Original, [string]$Formatted, [int]$ContextLines = 2, [int]$MaxLines = 80)
    $result = @{ changed = $false; diff = ''; removed = 0; added = 0; truncated = $false }
    $aN = (([string]$Original) -replace "`r`n", "`n") -replace "`r", "`n"
    $bN = (([string]$Formatted) -replace "`r`n", "`n") -replace "`r", "`n"
    if ($aN -ceq $bN) { return $result }   # identical after newline-normalization -> no suggestion
    $result.changed = $true
    $aLines = [string[]]($aN -split "`n")
    $bLines = [string[]]($bN -split "`n")
    $n = $aLines.Length; $m = $bLines.Length
    # Guard the O(n*m) LCS for pathological inputs. Format-on-edit is opt-in and files are
    # usually modest, but never let a huge file blow up the daemon: above the bound, report the
    # change (coarse counts) without an inline diff.
    if (([long]$n * [long]$m) -gt 2000000) {
        $result.removed = $n; $result.added = $m; $result.truncated = $true
        $result.diff = '(formatted output differs; file too large to show an inline diff)'
        return $result
    }
    # LCS length table (filled from the bottom-right so a forward backtrack reads naturally).
    # Stored as a 1-D array with row stride $w and indexed by hand: Windows PowerShell 5.1's parser
    # rejects the multidimensional indexer with a parenthesized subscript (e.g. $dp[($i+1), $j]),
    # which pwsh 7 accepts -- so a flat array with explicit index arithmetic is the portable form.
    $w = $m + 1
    $dp = New-Object 'int[]' (($n + 1) * $w)
    for ($i = $n - 1; $i -ge 0; $i--) {
        $rowBase = $i * $w
        $nextBase = ($i + 1) * $w
        for ($j = $m - 1; $j -ge 0; $j--) {
            if ($aLines[$i] -ceq $bLines[$j]) { $dp[$rowBase + $j] = $dp[$nextBase + $j + 1] + 1 }
            else { $dp[$rowBase + $j] = [Math]::Max($dp[$nextBase + $j], $dp[$rowBase + $j + 1]) }
        }
    }
    # Backtrack into an edit script of '=' (context) / '-' (removed) / '+' (added) ops.
    $ops = New-Object System.Collections.Generic.List[object]
    $i = 0; $j = 0
    while ($i -lt $n -and $j -lt $m) {
        if ($aLines[$i] -ceq $bLines[$j]) { $ops.Add([pscustomobject]@{ op = '='; text = $aLines[$i] }); $i++; $j++ }
        elseif ($dp[($i + 1) * $w + $j] -ge $dp[$i * $w + $j + 1]) { $ops.Add([pscustomobject]@{ op = '-'; text = $aLines[$i] }); $i++ }
        else { $ops.Add([pscustomobject]@{ op = '+'; text = $bLines[$j] }); $j++ }
    }
    while ($i -lt $n) { $ops.Add([pscustomobject]@{ op = '-'; text = $aLines[$i] }); $i++ }
    while ($j -lt $m) { $ops.Add([pscustomobject]@{ op = '+'; text = $bLines[$j] }); $j++ }
    $opCount = $ops.Count
    # Per-op 1-based original/new line numbers (the FIRST line each op occupies on its side).
    $aNum = New-Object 'int[]' $opCount
    $bNum = New-Object 'int[]' $opCount
    $ai = 1; $bi = 1
    for ($k = 0; $k -lt $opCount; $k++) {
        $aNum[$k] = $ai; $bNum[$k] = $bi
        $o = $ops[$k].op
        if ($o -eq '=') { $ai++; $bi++ } elseif ($o -eq '-') { $ai++ } else { $bi++ }
        if ($o -eq '-') { $result.removed++ } elseif ($o -eq '+') { $result.added++ }
    }
    # Group change runs into hunks, merging runs within 2*ContextLines of each other.
    $changeIdx = New-Object System.Collections.Generic.List[int]
    for ($k = 0; $k -lt $opCount; $k++) { if ($ops[$k].op -ne '=') { [void]$changeIdx.Add($k) } }
    $hunks = New-Object System.Collections.Generic.List[object]
    $startC = $changeIdx[0]; $prevC = $changeIdx[0]
    for ($x = 1; $x -lt $changeIdx.Count; $x++) {
        $c = $changeIdx[$x]
        if (($c - $prevC) -le (2 * $ContextLines + 1)) { $prevC = $c; continue }
        $hunks.Add([pscustomobject]@{ first = $startC; last = $prevC }); $startC = $c; $prevC = $c
    }
    $hunks.Add([pscustomobject]@{ first = $startC; last = $prevC })
    # Emit unified hunks with ContextLines of context, capped at MaxLines body lines.
    $body = New-Object System.Collections.Generic.List[string]
    $truncated = $false
    foreach ($h in $hunks) {
        if ($body.Count -ge $MaxLines) { $truncated = $true; break }
        $hs = [Math]::Max(0, [int]$h.first - $ContextLines)
        $he = [Math]::Min($opCount - 1, [int]$h.last + $ContextLines)
        $aCount = 0; $bCount = 0
        for ($k = $hs; $k -le $he; $k++) {
            if ($ops[$k].op -ne '+') { $aCount++ }
            if ($ops[$k].op -ne '-') { $bCount++ }
        }
        $body.Add('@@ -' + $aNum[$hs] + ',' + $aCount + ' +' + $bNum[$hs] + ',' + $bCount + ' @@')
        for ($k = $hs; $k -le $he; $k++) {
            if ($body.Count -ge $MaxLines) { $truncated = $true; break }
            $pfx = if ($ops[$k].op -eq '=') { ' ' } elseif ($ops[$k].op -eq '-') { '-' } else { '+' }
            $body.Add($pfx + [string]$ops[$k].text)
        }
        if ($truncated) { break }
    }
    $result.diff = ($body -join "`n")
    $result.truncated = $truncated
    return $result
}

function Format-FormattingSuggestionBlock {
    # Render the additionalContext block for a format-on-edit SUGGESTION (000059), or '' when
    # there is nothing to suggest ($Diff empty). The header is deliberately distinct from the
    # 'PowerShell diagnostics (...)' line so the agent never confuses a style suggestion with a
    # correctness finding, and it states plainly that the file was NOT modified (suggest-not-
    # apply) and whether the repo's settings were honored. PURE and unit-testable.
    param([string]$Path, [string]$Diff, [int]$Removed, [int]$Added, [bool]$Truncated, [string]$SettingsPath)
    if ([string]::IsNullOrEmpty($Diff)) { return '' }
    $styleNote = if (-not [string]::IsNullOrWhiteSpace($SettingsPath)) {
        'repo style (' + (Split-Path -Leaf $SettingsPath) + ')'
    } else {
        'default PSScriptAnalyzer style'
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('PowerShell formatting suggestion for ' + $Path + ' -- ' + $styleNote +
        ': the formatted version differs (-' + $Removed + ' / +' + $Added + ' lines). ' +
        'The file was NOT modified; run Invoke-Formatter yourself to apply this style.')
    [void]$sb.Append($Diff)
    if ($Truncated) { [void]$sb.Append("`n... (formatting diff truncated)") }
    return $sb.ToString()
}
