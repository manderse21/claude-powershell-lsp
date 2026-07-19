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
# Per-process rationale-table cache (dispatch 000121). MUST be initialized here: under
# Set-StrictMode -Version Latest, reading an unset variable is a TERMINATING error, and
# Import-RuleRationales tests this on its first call.
$script:RuleRationaleCache = $null

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

function Get-PinnedPssaVersion {
    # The PINNED PSScriptAnalyzer version, READ (never executed) from scripts/ensure-pssa.ps1 --
    # the SINGLE source of truth for the pin (dispatch 000046/000049). Same regex shape as
    # scripts/print-pssa-pin.ps1. Returns '' when it cannot be resolved, so a caller on a tree
    # without the script degrades rather than throwing.
    $libDir = $script:LspCommonDir
    if ([string]::IsNullOrWhiteSpace($libDir)) { $libDir = $PSScriptRoot }
    if ([string]::IsNullOrWhiteSpace($libDir)) { return '' }
    $ensurePssa = Join-Path (Split-Path -Parent $libDir) 'ensure-pssa.ps1'
    if (-not (Test-Path -LiteralPath $ensurePssa -PathType Leaf)) { return '' }
    try {
        $src = [System.IO.File]::ReadAllText($ensurePssa)
        $rx = [regex]"\`$PssaVersion\s*=\s*'([^']+)'"
        $m = $rx.Match($src)
        if ($m.Success) { return $m.Groups[1].Value }
    } catch { }
    return ''
}

function Get-RuleRationalePath {
    # Absolute path to the shipped GENERATED rationale table (rulesets/rule-rationales.psd1;
    # dispatch 000121). Located exactly like Get-PluginBaseSettingsPath: walk up from this lib's
    # dir (scripts/lib -> scripts -> root), then fall back to $env:CLAUDE_PLUGIN_ROOT. Returns ''
    # when absent -- the caller then renders findings with NO rationale line (graceful degrade;
    # a missing table never blocks or breaks the diagnostics surface).
    $libDir = $script:LspCommonDir
    if ([string]::IsNullOrWhiteSpace($libDir)) { $libDir = $PSScriptRoot }
    if (-not [string]::IsNullOrWhiteSpace($libDir)) {
        $root = Split-Path -Parent (Split-Path -Parent $libDir)
        if (-not [string]::IsNullOrWhiteSpace($root)) {
            $candidate = Join-Path $root 'rulesets/rule-rationales.psd1'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return [System.IO.Path]::GetFullPath($candidate) }
        }
    }
    $envRoot = $env:CLAUDE_PLUGIN_ROOT
    if (-not [string]::IsNullOrWhiteSpace($envRoot)) {
        $candidate = Join-Path $envRoot 'rulesets/rule-rationales.psd1'
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
        [string]$Ruleset = 'pses-default',
        [string]$ModuleAwareness = 'off',
        [string]$ReferenceSurfacing = 'off',
        # Daemon settle cap (ms) forward (dispatch 000133). The daemon's own MaxWaitMs (pses-daemon.ps1,
        # default 5000) is the hard cap on the settle wait -- the BINDING per-file budget (dispatch 000132).
        # Internal / daemon-level ONLY: NOT a userConfig knob, never sourced from CLAUDE_PLUGIN_OPTION_*, so
        # it adds no CONTRACT surface. 0 (the default) means "unset" -- no arg is emitted and the daemon
        # keeps its own 5000 default, so the in-agent launch is byte-identical to pre-000133. Only the scan
        # (Start-ScanDaemon, option B) passes a raised value; in-agent editing is untouched.
        [int]$MaxWaitMs = 0
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
    # Pass -ModuleAwareness ONLY when opted in ('suggest'); the daemon defaults to 'off', so the
    # default path's daemon invocation is byte-identical to pre-000101 (no extra arg, no index load,
    # no installed-modules snapshot). The value is canonicalized upstream (ConvertTo-ModuleAwarenessMode).
    if ($ModuleAwareness -eq 'suggest') { $daemonArgs += @('-ModuleAwareness', 'suggest') }
    # Pass -ReferenceSurfacing ONLY when opted in ('counts'); the daemon defaults to 'off', so the default
    # path's daemon invocation is byte-identical to pre-000128 (no extra arg, no index build). Canonicalized
    # upstream (ConvertTo-ReferenceSurfacingMode).
    if ($ReferenceSurfacing -eq 'counts') { $daemonArgs += @('-ReferenceSurfacing', 'counts') }
    # Pass -MaxWaitMs ONLY when a caller set it (> 0); the daemon defaults to 5000, so the default path's
    # daemon invocation is byte-identical to pre-000133 (no extra arg). Only the scan raises it (option B,
    # dispatch 000133) -- the in-agent daemon keeps the 5000 settle cap, so edit latency is unchanged.
    if ($MaxWaitMs -gt 0) { $daemonArgs += @('-MaxWaitMs', [string]$MaxWaitMs) }
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

# --- rule rationales: static "why this rule matters" prose (dispatch 000121, I0.1) ---------
# ADDITIVE prose on the existing additionalContext channel, riding ONLY existing findings. No
# userConfig knob, no status token, no CONTRACT surface: a clean file has no findings, so it
# emits NOTHING and stays byte-identical (the frozen clean-token property).
#
# The table (rulesets/rule-rationales.psd1) is GENERATED by scripts/regen-rule-rationales.ps1
# from the vendored PSScriptAnalyzer pin plus a hand-authored owned-finder table, and is keyed by
# the diagnostic's `code`. THREE degrade paths, all silent and non-blocking, because a missing
# rationale must never cost a user their diagnostics:
#   1. the table file is absent          -> Get-RuleRationalePath returns '' -> @{}
#   2. the table file is unparseable     -> the try/catch below            -> @{}
#   3. a surfaced code has no entry      -> the lookup misses -> that finding gets no line
# Never fabricated, never blocking.

function Import-RuleRationales {
    # Load the shipped rationale table as @{ code -> text }, cached per process (the client is a
    # short-lived hook process; the daemon is long-lived and re-reads nothing per edit). Any
    # failure -- absent, unparseable, wrong shape -- yields an EMPTY table, never an exception.
    param([switch]$Force)
    if ((-not $Force) -and $null -ne $script:RuleRationaleCache) { return $script:RuleRationaleCache }
    $table = @{}
    try {
        $path = Get-RuleRationalePath
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $data = Import-PowerShellDataFile -LiteralPath $path
            if ($null -ne $data -and $data.ContainsKey('entries')) {
                foreach ($k in @($data['entries'].Keys)) {
                    $v = [string]$data['entries'][$k]
                    if (-not [string]::IsNullOrWhiteSpace($v)) { $table[[string]$k] = $v }
                }
            }
        }
    } catch { $table = @{} }
    $script:RuleRationaleCache = $table
    return $table
}

function Get-RationaleForCode {
    # First-appearance lookup used by the render loop: the rationale for $Code if the table has one
    # AND $Code has not been rendered yet in this file. $Rendered is a HashSet the caller owns, so
    # the dedup state lives with the render pass -- that is what makes the rationale render ONCE per
    # distinct rule per file, however many findings that rule produces. Returns '' when there is
    # nothing to render (no code, no table, no entry, or already rendered).
    param([string]$Code, [hashtable]$Table, $Rendered)
    if ([string]::IsNullOrWhiteSpace($Code) -or $Code -eq '0') { return '' }
    if ($null -eq $Table -or $Table.Count -eq 0) { return '' }
    if (-not $Table.ContainsKey($Code)) { return '' }
    if ($null -ne $Rendered -and (-not $Rendered.Add($Code))) { return '' }
    return [string]$Table[$Code]
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

# --- pre-PSSA pack: Unix/bash command names in .ps1 (dispatch 000097) ----------
# A command-NAME pass over the parser AST the pre-pass already produces (reusing the
# 000060/000096 seam) that flags Unix shell command NAMES an AI commonly drops into a .ps1
# -- grep, sed, awk, export, which, touch, chmod, chown, ln -- which either fail at runtime
# on a clean Windows host or silently depend on Git Bash being on PATH. This is the 000055
# survey's "AI's most common tell" and the LAST net-new slice of that pack. Same finding
# shape and source label as Find-NonAsciiSmuggling / Find-Ps7OnlySyntax (source
# 'powershell-lsp', a portability WARNING) with a distinct, stable check id BashIsm.
# Always-on additive; no knob.
#
# OWNERSHIP BOUNDARIES (one construct, one owner, one ruleId): the pipeline-chain operators
# && / || belong to Find-Ps7OnlySyntax (000096); the PowerShell alias subset (ls, cat, cp,
# mv, rm, echo, ...) belongs to PSScriptAnalyzer's PSAvoidUsingCmdletAliases under the pinned
# PSSA. This check owns ONLY the non-alias Unix command NAMES below and never re-reports
# either. The set was confirmed against the pinned PSScriptAnalyzer 1.25.0 -- its
# PSAvoidUsingCmdletAliases fires ZERO hits on every name here on BOTH hosts, and none is a
# Get-Alias entry on pwsh 7 or Windows PowerShell 5.1 -- so there is no double-report;
# ls/cat/... are deliberately EXCLUDED because that rule already owns them.
#
# THE FP DISCIPLINE (where this slice is won or lost): command-NAME matching over CommandAst
# ONLY -- a grep inside a string literal or a comment is not a CommandAst node and never
# flags. Two suppressions make deliberate use silent:
#   (a) an explicit call-operator invocation ('& grep') -- InvocationOperator Ampersand --
#       is the "I mean the external binary" signal (the analog of 000096's #Requires -Version
#       7 escape), and
#   (b) a same-file definition of the name -- a FunctionDefinitionAst, or a Set-Alias /
#       New-Alias defining that name -- means the call is the user's own function/alias.
# Severity is Warning, never Error: the residual legitimate case is a genuinely-installed
# Unix tool on PATH (common on the Linux/macOS legs), a portability heads-up, not a failure.
#
# HOST / StrictMode SAFETY: unlike Find-Ps7OnlySyntax, every AST type this pass touches
# (CommandAst, FunctionDefinitionAst, CommandParameterAst, StringConstantExpressionAst) and
# every member it reads (GetCommandName(), InvocationOperator, CommandElements, .Name) is
# CORE and present on BOTH Windows PowerShell 5.1 and pwsh 7 -- these are not 7-only nodes.
# Detection still uses GetType().Name string checks and an enum-to-string operator compare
# (never a type/enum literal), and every property access is guarded, so it dot-sources and
# runs silent under 5.1 + StrictMode exactly like the rest of the pack.

function Get-AliasDefinitionNameFromCommand {
    # Extract the alias NAME a Set-Alias/New-Alias CommandAst defines: the value bound to
    # -Name if present, else the first positional string argument (PowerShell binds the alias
    # name to position 0). Returns '' when it cannot be determined statically (e.g. a
    # variable/expression name) -- an indeterminate name simply does not suppress. Core AST
    # members only (5.1/StrictMode-safe); every access guarded.
    param($CommandAstNode)
    $elems = @()
    try { $elems = @($CommandAstNode.CommandElements) } catch { return '' }
    $namedValue = ''
    $firstPositional = ''
    $wantNameValue = $false
    # elems[0] is the command name (Set-Alias/New-Alias); scan the arguments after it.
    for ($k = 1; $k -lt $elems.Count; $k++) {
        $el = $elems[$k]
        $etn = ''
        try { $etn = $el.GetType().Name } catch { $etn = '' }
        if ($etn -eq 'CommandParameterAst') {
            $pn = ''
            try { $pn = [string]$el.ParameterName } catch { $pn = '' }
            # -Name, or an unambiguous prefix of it (-n/-na/-nam) -- PowerShell prefix-matches
            # parameters. A blank name never matches (guarded), so '' can never be read as -Name.
            $isName = (-not [string]::IsNullOrWhiteSpace($pn)) -and ('name'.StartsWith($pn.ToLowerInvariant()))
            $wantNameValue = $isName
            if ($isName) {
                # -Name:foo binds the argument inline on the CommandParameterAst.
                $arg = $el.PSObject.Properties['Argument']
                if ($null -ne $arg -and $null -ne $arg.Value) {
                    try {
                        if ($arg.Value.GetType().Name -eq 'StringConstantExpressionAst') {
                            $namedValue = [string]$arg.Value.Value; $wantNameValue = $false
                        }
                    } catch { }
                }
            }
        } elseif ($etn -eq 'StringConstantExpressionAst') {
            $val = ''
            try { $val = [string]$el.Value } catch { $val = '' }
            if ($wantNameValue) { $namedValue = $val; $wantNameValue = $false }
            elseif ([string]::IsNullOrWhiteSpace($firstPositional)) { $firstPositional = $val }
        } else {
            $wantNameValue = $false
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($namedValue)) { return $namedValue }
    return $firstPositional
}

function Find-BashIsm {
    <#
    .SYNOPSIS
        Flag Unix/bash command NAMES used as commands in a parsed AST, suppressed for an
        explicit '& name' call-operator invocation or a same-file definition of the name.
    .DESCRIPTION
        PURE over the supplied AST (the object the parser pre-pass already produces).
        Returns @() when the AST is $null or no bash-ism command call is present. Otherwise
        one finding per offending CommandAst. A finding is SUPPRESSED when the invocation
        uses the call operator '&' (InvocationOperator Ampersand -- a deliberate external
        call) or when the file itself defines that name (function / Set-Alias / New-Alias).
        Finding source = 'powershell-lsp', ruleId/code = 'BashIsm', severity 'Warning' --
        the same shape and channel as Find-NonAsciiSmuggling / Find-Ps7OnlySyntax.
    #>
    param($Ast)
    if ($null -eq $Ast) { return @() }

    # The net-new bash-ism command NAMES this check owns (OQ1). Excludes the PowerShell alias
    # subset (PSAvoidUsingCmdletAliases owns ls/cat/cp/mv/rm/echo/...) and the && / || chain
    # operators (Find-Ps7OnlySyntax owns them). Lower-case; matching is case-insensitive.
    $bashIsmNames = @('grep', 'sed', 'awk', 'export', 'which', 'touch', 'chmod', 'chown', 'ln')

    # ONE AST walk collects both the candidate CommandAst nodes and the same-file definitions
    # (function names + Set-Alias/New-Alias targets) that suppress them.
    $nodes = @()
    try {
        $nodes = @($Ast.FindAll({ param($n)
                    $tn = $n.GetType().Name
                    ($tn -eq 'CommandAst') -or ($tn -eq 'FunctionDefinitionAst')
                }, $true))
    } catch { return @() }

    $commands = New-Object System.Collections.ArrayList
    $definedNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $nodes) {
        $tn = ''
        try { $tn = $n.GetType().Name } catch { $tn = '' }
        if ($tn -eq 'FunctionDefinitionAst') {
            $nm = ''
            try { $nm = [string]$n.Name } catch { $nm = '' }
            if (-not [string]::IsNullOrWhiteSpace($nm)) { [void]$definedNames.Add($nm) }
        } elseif ($tn -eq 'CommandAst') {
            [void]$commands.Add($n)
            # If this command is Set-Alias/New-Alias (or the sal/nal aliases), record the alias
            # NAME it defines so a later call to that name is treated as the user's own.
            $cn = $null
            try { $cn = $n.GetCommandName() } catch { $cn = $null }
            if (-not [string]::IsNullOrWhiteSpace($cn)) {
                $cnl = $cn.ToLowerInvariant()
                if ($cnl -eq 'set-alias' -or $cnl -eq 'new-alias' -or $cnl -eq 'sal' -or $cnl -eq 'nal') {
                    $aliasName = Get-AliasDefinitionNameFromCommand $n
                    if (-not [string]::IsNullOrWhiteSpace($aliasName)) { [void]$definedNames.Add($aliasName) }
                }
            }
        }
    }

    $findings = New-Object System.Collections.ArrayList
    foreach ($node in $commands) {
        # Command NAME only -- GetCommandName() returns the bareword/string name, or $null for
        # an expression/dynamic invocation (never flags). String literals and comments are not
        # CommandAst nodes, so they are structurally excluded.
        $name = $null
        try { $name = $node.GetCommandName() } catch { $name = $null }
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $nameLower = $name.ToLowerInvariant()
        if ($bashIsmNames -notcontains $nameLower) { continue }

        # Suppression (a): explicit call-operator invocation '& grep' is a deliberate external
        # call. Enum-to-string compare (5.1/StrictMode-safe -- never a TokenKind literal).
        $inv = ''
        try { $inv = [string]$node.InvocationOperator } catch { $inv = '' }
        if ($inv -eq 'Ampersand') { continue }

        # Suppression (b): the file defines this name itself (function / alias) -- the call is
        # the user's own, not the Unix binary. Case-insensitive membership.
        if ($definedNames.Contains($name)) { continue }

        $line = 1; $col = 1
        try { $line = [int]$node.Extent.StartLineNumber } catch { $line = 1 }
        try { $col = [int]$node.Extent.StartColumnNumber } catch { $col = 1 }
        [void]$findings.Add([pscustomobject]@{
                ruleId = 'BashIsm'; code = 'BashIsm'
                source = 'powershell-lsp'
                severity = 'Warning'; line = $line; col = $col
                message = "Unix/bash command '$name' used in a PowerShell script. This is not a " +
                    "PowerShell cmdlet and will fail on a clean Windows host (or silently depend " +
                    "on Git Bash being on PATH). Use the PowerShell equivalent, or invoke the " +
                    "external tool explicitly with the call operator (& $name)."
            })
    }
    return @($findings)
}

function Find-CommandLinePlaceholder {
    <#
    .SYNOPSIS
        Flag a literal angle-bracket placeholder -- '<Name>' -- left on a command line
        (dispatch 000139, S3.4). A signature AI-era defect: schema-valid to a human eye,
        a redirection-operator parse error at run time.
    .DESCRIPTION
        PURE over the token stream the parser pre-pass already produces (the same $ptoks
        Parser::ParseFile emits at the 000060 seam). A bare '<Name>' tokenizes as the
        RESERVED '<' input-redirection operator (a parse error, "the '<' operator is
        reserved") IMMEDIATELY followed by a Generic bareword ending in '>'. This is a
        0-FP shape (measured 0/281 over a widened oracle, dispatch 000139): legitimate
        OUTPUT redirection ('>', '>>', '2>&1', '*>&1') is a DIFFERENT token kind
        (Redirection), and any '<...>' inside a string, here-string, or comment stays
        inside that token and never yields a RedirectInStd. Conservative by construction
        (precision over recall): only a single adjacent bareword of placeholder-name shape
        is matched, so a composite like '<owner>/<repo>' is deliberately not flagged.
        Finding source = 'powershell-lsp', ruleId/code = 'CommandLinePlaceholder',
        severity 'Warning' -- the same shape and channel as Find-Ps7OnlySyntax.

        HOST / StrictMode SAFETY: TokenKind is compared as a STRING (.Kind.ToString()) and
        every member read is guarded, so this dot-sources and runs silent under Windows
        PowerShell 5.1 + StrictMode exactly like the rest of the pre-PSSA pack.
    #>
    param($Tokens)
    if ($null -eq $Tokens) { return @() }
    $toks = @($Tokens)
    $findings = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $toks.Count - 1; $i++) {
        $t = $toks[$i]
        if ([string]$t.Kind.ToString() -ne 'RedirectInStd') { continue }
        if ([string]$t.Text -ne '<') { continue }
        $n = $toks[$i + 1]
        if ([string]$n.Kind.ToString() -ne 'Generic') { continue }
        $ntext = [string]$n.Text
        if (-not $ntext.EndsWith('>')) { continue }
        # Adjacency: the '<' must immediately abut the bareword ('<Name>', never '< target'),
        # which distinguishes a placeholder from a genuine (reserved) input redirect '< file'.
        $adj = $false
        try { $adj = ([int]$n.Extent.StartOffset -eq [int]$t.Extent.EndOffset) } catch { $adj = $false }
        if (-not $adj) { continue }
        $inner = $ntext.Substring(0, $ntext.Length - 1)
        if ($inner.Length -lt 1) { continue }
        # Placeholder-name shape only (letters, digits, _, ., -, space); no slashes/quotes,
        # keeping the match to the dominant AI placeholder form and the 0-FP measurement.
        if ($inner -notmatch '^[A-Za-z0-9_.\- ]+$') { continue }
        $line = 1; $col = 1
        try { $line = [int]$t.Extent.StartLineNumber } catch { $line = 1 }
        try { $col = [int]$t.Extent.StartColumnNumber } catch { $col = 1 }
        [void]$findings.Add([pscustomobject]@{
            ruleId = 'CommandLinePlaceholder'; code = 'CommandLinePlaceholder'
            source = 'powershell-lsp'
            severity = 'Warning'; line = $line; col = $col
            message = "Unfilled placeholder '<$inner>' left on a command line. Angle " +
                "brackets are the reserved redirection operators in PowerShell, so this " +
                "is a parse error, not text -- replace the placeholder with a real value, " +
                "or quote it if the literal text was intended."
        })
    }
    return @($findings)
}

# --- module awareness: command from an uninstalled module (PL-6, dispatch 000101) -----------
# A daemon-side, knob-gated (moduleAwareness=suggest), Information-severity hint that a
# CommandAst NAME is exported by a KNOWN module (the shipped offline command->module index)
# that is NOT installed on this machine -- so the call would fail to resolve. Design B (the
# 000100 survey): the install-check is what earns the actionable message, because PowerShell
# AUTO-LOADS an installed module, so an index-only design is noise on any box that has the
# module. Fires ONLY on the survey's rung 0-6 positive-identification predicate; EVERY ambiguity
# degrades to SILENCE (a missing hint costs a web search; a wrong "install M" teaches the user to
# ignore the plugin -- the FP this feature cannot afford).
#
# WHERE IT RUNS (survey-vs-disk reconciliation, dispatch 000101): unlike Find-BashIsm / the
# pre-PSSA pack (which run CLIENT-side over the client-parsed AST), this check runs DAEMON-side --
# the once-per-session installed-modules snapshot (the machine-state rung 6) lives in the warm
# daemon ($script:, the 000062 cache model), taken by a background pre-warm OFF the critical path.
# This function is the PURE core (AST + index + installed-set + declared-modules in, findings out),
# unit-testable in isolation; the daemon wrapper (Get-ModuleAwarenessFindings in pses-daemon.ps1)
# parses the edited file, resolves the nearest manifest's RequiredModules, and supplies the
# session snapshot. It REUSES the BashIsm machinery (the CommandAst walk, the $definedNames
# same-file-suppression HashSet, Get-AliasDefinitionNameFromCommand) verbatim.
#
# HOST / StrictMode SAFETY: every AST type touched (CommandAst, FunctionDefinitionAst,
# StringConstantExpressionAst, VariableExpressionAst, ArrayLiteralAst, CommandParameterAst) and
# member read (GetCommandName, InvocationOperator, CommandElements, ScriptRequirements
# .RequiredModules, .Extent) is CORE on BOTH Windows PowerShell 5.1 and pwsh 7. Detection uses
# GetType().Name string checks + guarded property access -- never a 7-only type/enum literal --
# so it dot-sources and runs silent under 5.1 + StrictMode exactly like the rest of the pack.

function Get-ModuleNameArgClass {
    # Classify ONE argument node as literal module name(s) or dynamic. A literal string constant
    # (or an array literal of only string constants) yields Names; ANYTHING else (a variable, an
    # expandable "$mod" string, a sub-expression) is Dynamic -> the caller degrades honestly.
    # Core AST members only (5.1/StrictMode-safe); every access guarded.
    param($Node)
    $tn = ''
    try { $tn = $Node.GetType().Name } catch { return @{ Names = @(); Dynamic = $true } }
    if ($tn -eq 'StringConstantExpressionAst') {
        $v = ''
        try { $v = [string]$Node.Value } catch { $v = '' }
        if ([string]::IsNullOrWhiteSpace($v)) { return @{ Names = @(); Dynamic = $false } }
        return @{ Names = @($v); Dynamic = $false }
    }
    if ($tn -eq 'ArrayLiteralAst') {
        $names = New-Object System.Collections.Generic.List[string]
        $elems = @()
        try { $elems = @($Node.Elements) } catch { return @{ Names = @(); Dynamic = $true } }
        foreach ($e in $elems) {
            $etn = ''
            try { $etn = $e.GetType().Name } catch { $etn = '' }
            if ($etn -eq 'StringConstantExpressionAst') {
                $ev = ''
                try { $ev = [string]$e.Value } catch { $ev = '' }
                if (-not [string]::IsNullOrWhiteSpace($ev)) { $names.Add($ev) }
            } else {
                return @{ Names = @(); Dynamic = $true }   # a dynamic element -> the whole import is dynamic
            }
        }
        return @{ Names = @($names); Dynamic = $false }
    }
    return @{ Names = @(); Dynamic = $true }   # variable / expandable-string / sub-expression -> dynamic
}

function Get-ImportModuleModuleNames {
    # From an Import-Module (or ipmo) CommandAst, return @{ Names = @(...); Dynamic = $bool }.
    # Names = the LITERAL module names imported (positional string args + -Name string values +
    # an array literal of string constants). Dynamic = $true if ANY module-name argument is not a
    # literal (a variable / expression) -- rung 5 degrade: the caller suppresses firing for the
    # whole file, since a dynamic import could pull in any module. Over-collecting a non-module
    # string (e.g. a -Scope value) is harmless: an extra declared name only SUPPRESSES (fail-safe).
    param($CommandAstNode)
    $names = New-Object System.Collections.Generic.List[string]
    $dynamic = $false
    $elems = @()
    try { $elems = @($CommandAstNode.CommandElements) } catch { return @{ Names = @(); Dynamic = $true } }
    $expectNameValue = $false
    for ($i = 1; $i -lt $elems.Count; $i++) {
        $el = $elems[$i]
        $etn = ''
        try { $etn = $el.GetType().Name } catch { $etn = '' }
        if ($etn -eq 'CommandParameterAst') {
            $pn = ''
            try { $pn = [string]$el.ParameterName } catch { $pn = '' }
            $isName = (-not [string]::IsNullOrWhiteSpace($pn)) -and ('name'.StartsWith($pn.ToLowerInvariant()))
            $expectNameValue = $isName
            if ($isName) {
                $arg = $el.PSObject.Properties['Argument']
                if ($null -ne $arg -and $null -ne $arg.Value) {
                    $r = Get-ModuleNameArgClass $arg.Value
                    if ($r.Dynamic) { $dynamic = $true } else { foreach ($n in $r.Names) { $names.Add($n) } }
                    $expectNameValue = $false
                }
            }
        } elseif ($expectNameValue) {
            $r = Get-ModuleNameArgClass $el
            if ($r.Dynamic) { $dynamic = $true } else { foreach ($n in $r.Names) { $names.Add($n) } }
            $expectNameValue = $false
        } else {
            # A positional argument -- the first positional binds to -Name (the module).
            $r = Get-ModuleNameArgClass $el
            if ($r.Dynamic) { $dynamic = $true } else { foreach ($n in $r.Names) { $names.Add($n) } }
        }
    }
    return @{ Names = @($names); Dynamic = $dynamic }
}

function Get-DotSourceClass {
    # Classify a CommandAst as a dot-source. Returns @{ IsDotSource; Dynamic; Path }.
    # A LITERAL dot-source (`. ./helpers.ps1`) -- InvocationOperator Dot, first element a string
    # constant -- is FOLLOWABLE (Path set, Dynamic $false). A DYNAMIC dot-source (`. $path`) --
    # Dot with a non-literal first element -- is Dynamic $true (rung 3 degrade -> suppress file).
    # Not a dot-source at all -> IsDotSource $false. Core members only; guarded.
    param($CommandAstNode)
    $inv = ''
    try { $inv = [string]$CommandAstNode.InvocationOperator } catch { $inv = '' }
    if ($inv -ne 'Dot') { return @{ IsDotSource = $false; Dynamic = $false; Path = '' } }
    $elems = @()
    try { $elems = @($CommandAstNode.CommandElements) } catch { return @{ IsDotSource = $true; Dynamic = $true; Path = '' } }
    if ($elems.Count -lt 1) { return @{ IsDotSource = $true; Dynamic = $true; Path = '' } }
    $e0 = $elems[0]
    $etn = ''
    try { $etn = $e0.GetType().Name } catch { $etn = '' }
    if ($etn -eq 'StringConstantExpressionAst') {
        $p = ''
        try { $p = [string]$e0.Value } catch { $p = '' }
        if ([string]::IsNullOrWhiteSpace($p)) { return @{ IsDotSource = $true; Dynamic = $true; Path = '' } }
        return @{ IsDotSource = $true; Dynamic = $false; Path = $p }
    }
    return @{ IsDotSource = $true; Dynamic = $true; Path = '' }   # `. $var` / `. (expr)` -> dynamic
}

function Add-DotSourcedDefinitionNames {
    # Follow ONE literal dot-source (rung 3): resolve $RelPath relative to $BaseDir, parse the
    # target, and add its top-level function names + Set-Alias/New-Alias names to $DefinedNames.
    # Returns $true when the include was fully resolved + harvested, $false on ANY failure (a path
    # that does not resolve to a readable, parseable file) -- the caller then SUPPRESSES the file
    # (fail-safe: never guess across an include it could not read). One level deep, no recursion.
    param([string]$RelPath, [string]$BaseDir, $DefinedNames)
    if ([string]::IsNullOrWhiteSpace($BaseDir)) { return $false }
    $full = ''
    try {
        if ([System.IO.Path]::IsPathRooted($RelPath)) { $full = [System.IO.Path]::GetFullPath($RelPath) }
        else { $full = [System.IO.Path]::GetFullPath((Join-Path $BaseDir $RelPath)) }
    } catch { return $false }
    if ([string]::IsNullOrWhiteSpace($full) -or -not (Test-Path -LiteralPath $full -PathType Leaf)) { return $false }
    try {
        $incAst = [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$null, [ref]$null)
        if ($null -eq $incAst) { return $false }
        $nodes = @($incAst.FindAll({ param($n)
                    $tn = $n.GetType().Name
                    ($tn -eq 'FunctionDefinitionAst') -or ($tn -eq 'CommandAst')
                }, $true))
        foreach ($n in $nodes) {
            $tn = ''
            try { $tn = $n.GetType().Name } catch { $tn = '' }
            if ($tn -eq 'FunctionDefinitionAst') {
                $nm = ''
                try { $nm = [string]$n.Name } catch { $nm = '' }
                if (-not [string]::IsNullOrWhiteSpace($nm)) { [void]$DefinedNames.Add($nm) }
            } elseif ($tn -eq 'CommandAst') {
                $cn = $null
                try { $cn = $n.GetCommandName() } catch { $cn = $null }
                if (-not [string]::IsNullOrWhiteSpace($cn)) {
                    $cnl = $cn.ToLowerInvariant()
                    if ($cnl -eq 'set-alias' -or $cnl -eq 'new-alias' -or $cnl -eq 'sal' -or $cnl -eq 'nal') {
                        $aliasName = Get-AliasDefinitionNameFromCommand $n
                        if (-not [string]::IsNullOrWhiteSpace($aliasName)) { [void]$DefinedNames.Add($aliasName) }
                    }
                }
            }
        }
        return $true
    } catch { return $false }
}

function Find-ModuleAwareness {
    <#
    .SYNOPSIS
        Flag a CommandAst NAME that the shipped index maps to a module NOT installed on this
        machine and NOT locally resolved (defined, dot-sourced, required, or imported).
    .DESCRIPTION
        PURE over the supplied AST + injected index / installed-set / declared modules. Returns @()
        when $Ast is $null, when the file has a dynamic dot-source or dynamic Import-Module (rung
        3/5 degrade -- the whole file is suppressed), or when no name survives the rung 0-6
        predicate. Otherwise one finding per firing CommandAst. Finding source = 'powershell-lsp',
        ruleId/code = 'ModuleNotInstalled', severity 'Information'.

        THE PREDICATE (0-FP-defensible, the 000100 survey). Fire for CommandAst name N iff:
          (0) GetCommandName() returns a literal N (dynamic invocation returns $null -> never);
          (1) N is not a built-in (guaranteed by construction: built-ins are never in the index);
          (2) N is not defined same-file as a function / Set-Alias / New-Alias ($definedNames);
          (3) the file has no dynamic dot-source (a literal dot-source is FOLLOWED, its defs folded
              into $definedNames; a dynamic one suppresses the whole file);
          (4)+(5) N's owning module M is not declared via #Requires -Modules, the nearest manifest's
              RequiredModules, or a literal Import-Module M (a dynamic import suppresses the file);
          (6) N is a POSITIVE index hit -> M, AND M is NOT installed (design B, the machine-state
              rung -- the injected session snapshot).
    #>
    param(
        $Ast,
        $Index,                                     # hashtable: command name -> owning module name
        $InstalledModules,                          # collection of installed module names
        [string[]]$ManifestRequiredModules = @(),   # RequiredModules from the nearest manifest (daemon-resolved)
        [string]$FilePath = ''                      # edited file path (for resolving literal dot-source includes)
    )
    if ($null -eq $Ast) { return @() }
    if ($null -eq $Index) { return @() }

    # Build case-insensitive lookups from the injected inputs (never trust the caller's casing).
    $indexLookup = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
    try {
        foreach ($k in @($Index.Keys)) {
            $kn = [string]$k
            if (-not [string]::IsNullOrWhiteSpace($kn) -and -not $indexLookup.ContainsKey($kn)) {
                $indexLookup[$kn] = [string]$Index[$k]
            }
        }
    } catch { return @() }
    if ($indexLookup.Count -eq 0) { return @() }

    $installedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($m in @($InstalledModules)) {
        $mn = [string]$m
        if (-not [string]::IsNullOrWhiteSpace($mn)) { [void]$installedSet.Add($mn) }
    }

    $declaredModules = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($m in @($ManifestRequiredModules)) {
        $mn = [string]$m
        if (-not [string]::IsNullOrWhiteSpace($mn)) { [void]$declaredModules.Add($mn) }
    }
    # #Requires -Modules M (rung 4) -- ModuleSpecification.Name off the SAME AST Find-Ps7OnlySyntax
    # reads RequiredPSVersion from (000096). Guarded so a shape lacking ScriptRequirements never throws.
    try {
        $req = $Ast.ScriptRequirements
        if ($null -ne $req) {
            foreach ($rm in @($req.RequiredModules)) {
                $rn = ''
                try { $rn = [string]$rm.Name } catch { $rn = '' }
                if (-not [string]::IsNullOrWhiteSpace($rn)) { [void]$declaredModules.Add($rn) }
            }
        }
    } catch { }

    # ONE AST walk: candidate CommandAsts + same-file definitions + imports + dot-source shape.
    $nodes = @()
    try {
        $nodes = @($Ast.FindAll({ param($n)
                    $tn = $n.GetType().Name
                    ($tn -eq 'CommandAst') -or ($tn -eq 'FunctionDefinitionAst')
                }, $true))
    } catch { return @() }

    $definedNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $candidates = New-Object System.Collections.ArrayList
    $literalIncludes = New-Object System.Collections.ArrayList
    $suppressFile = $false
    foreach ($n in $nodes) {
        $tn = ''
        try { $tn = $n.GetType().Name } catch { $tn = '' }
        if ($tn -eq 'FunctionDefinitionAst') {
            $nm = ''
            try { $nm = [string]$n.Name } catch { $nm = '' }
            if (-not [string]::IsNullOrWhiteSpace($nm)) { [void]$definedNames.Add($nm) }
            continue
        }
        # CommandAst. First: is it a dot-source? (rung 3)
        $ds = Get-DotSourceClass $n
        if ($ds.IsDotSource) {
            if ($ds.Dynamic) { $suppressFile = $true }
            else { [void]$literalIncludes.Add([string]$ds.Path) }
            continue   # a dot-source is never a command candidate (its name is a path)
        }
        $cn = $null
        try { $cn = $n.GetCommandName() } catch { $cn = $null }
        if (-not [string]::IsNullOrWhiteSpace($cn)) {
            $cnl = $cn.ToLowerInvariant()
            if ($cnl -eq 'set-alias' -or $cnl -eq 'new-alias' -or $cnl -eq 'sal' -or $cnl -eq 'nal') {
                $aliasName = Get-AliasDefinitionNameFromCommand $n
                if (-not [string]::IsNullOrWhiteSpace($aliasName)) { [void]$definedNames.Add($aliasName) }
                continue
            }
            if ($cnl -eq 'import-module' -or $cnl -eq 'ipmo') {
                $imp = Get-ImportModuleModuleNames $n   # rung 5
                if ($imp.Dynamic) { $suppressFile = $true }
                foreach ($mn in @($imp.Names)) { if (-not [string]::IsNullOrWhiteSpace($mn)) { [void]$declaredModules.Add($mn) } }
                continue
            }
        }
        [void]$candidates.Add($n)
    }

    # Follow literal dot-sources (rung 3): harvest their defs; ANY failure suppresses the file.
    if (-not $suppressFile -and $literalIncludes.Count -gt 0) {
        $baseDir = ''
        if (-not [string]::IsNullOrWhiteSpace($FilePath)) {
            try { $baseDir = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($FilePath)) } catch { $baseDir = '' }
        }
        foreach ($inc in $literalIncludes) {
            if (-not (Add-DotSourcedDefinitionNames -RelPath $inc -BaseDir $baseDir -DefinedNames $definedNames)) {
                $suppressFile = $true; break
            }
        }
    }
    if ($suppressFile) { return @() }   # rung 3/5 honest degrade: never guess across an unresolved include/import

    $findings = New-Object System.Collections.ArrayList
    foreach ($node in $candidates) {
        $name = $null
        try { $name = $node.GetCommandName() } catch { $name = $null }
        if ([string]::IsNullOrWhiteSpace($name)) { continue }          # rung 0
        if ($definedNames.Contains($name)) { continue }                # rung 2 (+ followed rung 3)
        if (-not $indexLookup.ContainsKey($name)) { continue }         # rung 1 (built-ins never indexed) + unknown
        $module = [string]$indexLookup[$name]
        if ([string]::IsNullOrWhiteSpace($module)) { continue }
        if ($declaredModules.Contains($module)) { continue }           # rung 4 / 5
        if ($installedSet.Contains($module)) { continue }              # rung 6 (design B discriminator)

        $line = 1; $col = 1
        try { $line = [int]$node.Extent.StartLineNumber } catch { $line = 1 }
        try { $col = [int]$node.Extent.StartColumnNumber } catch { $col = 1 }
        [void]$findings.Add([pscustomobject]@{
                ruleId = 'ModuleNotInstalled'; code = 'ModuleNotInstalled'
                source = 'powershell-lsp'
                severity = 'Information'; line = $line; col = $col
                message = "'$name' is exported by module '$module', which is not installed on this " +
                    "machine; Install-Module $module or import it."
            })
    }
    return @($findings)
}

function ConvertTo-ModuleAwarenessMode {
    # Map the raw moduleAwareness knob string to a mode: 'off' | 'suggest'. Default-safe: absent /
    # blank / an unexpanded '${user_config...}' token / any unrecognized value -> 'off' (the feature
    # is opt-in; an unparseable knob NEVER silently turns it on -- the 000101 acceptance). Mirrors
    # ConvertTo-FormatOnEditMode's boolean-truthy aliases (true/on/1/yes -> the active mode) so a user
    # who reaches for a boolean gets the safe advisory behavior. There is no 'apply'-class escalation
    # here: a module-awareness hint only surfaces an Information diagnostic, it never writes a file.
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

function Get-CommandModuleIndexPath {
    # Absolute path to the shipped rulesets/command-module-index.psd1 (scripts/lib -> scripts -> root).
    $scriptsDir = Split-Path -Parent $script:LspCommonDir
    if ([string]::IsNullOrWhiteSpace($scriptsDir)) { $scriptsDir = Split-Path -Parent $PSScriptRoot }
    $root = Split-Path -Parent $scriptsDir
    return (Join-Path $root 'rulesets/command-module-index.psd1')
}

function Import-CommandModuleIndex {
    # Load the shipped command->module index entries (name -> module) as a hashtable. FAIL-SAFE:
    # returns @{} on ANY error (missing file, parse failure, no entries) -> the check then never
    # fires (a positive hit against an empty index is impossible). Reads the SHIPPED artifact ONLY --
    # no network, no live module (the 000100 determinism requirement: no network at edit time, ever).
    param([string]$Path = '')
    if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Get-CommandModuleIndexPath }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @{} }
    try {
        $data = Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop
        if ($null -eq $data) { return @{} }
        $entries = $data['entries']
        if ($null -eq $entries) { return @{} }
        return $entries
    } catch { return @{} }
}

# --- reference surfacing (dispatch 000128, N1.2/N1.3) ----------------------
# Bare per-function facts on the existing additionalContext channel, driven by a session workspace
# index built ONCE (the 000127 leg-1 survey: session-start index; per-edit is O(edited file)). Every
# ambiguity resolves to SILENCE (the survey ledger). No new owned diagnostic code; no rationale change.

function ConvertTo-ReferenceSurfacingMode {
    # Map the raw referenceSurfacing knob string to a mode: 'off' | 'counts'. Default-safe: absent /
    # blank / an unexpanded '${user_config...}' token / any unrecognized value -> 'off' (opt-in; an
    # unparseable knob NEVER silently turns it on -- mirrors the 000101 acceptance). Boolean-truthy
    # aliases map to 'counts' so a user who reaches for a boolean gets the advisory behavior. There is
    # no 'apply'-class value: reference surfacing only ADDS Information prose, it never writes a file.
    param([string]$Raw)
    $v = ([string]$Raw).Trim().ToLowerInvariant()
    switch ($v) {
        'counts' { return 'counts' }
        'true'   { return 'counts' }
        'on'     { return 'counts' }
        '1'      { return 'counts' }
        'yes'    { return 'counts' }
        default  { return 'off' }
    }
}

function Get-ReferenceFilePlural {
    param([int]$Count)
    if ($Count -eq 1) { return 'file' } else { return 'files' }
}

function Get-ReferenceRelativePath {
    # Best-effort relative path of $Full under $Root, forward-slashed. Falls back to the leaf name so a
    # 'defined in' fact never leaks an unexpected absolute path.
    param([string]$Full, [string]$Root)
    if ([string]::IsNullOrWhiteSpace($Full)) { return $Full }
    try {
        $rootFull = ''
        if (-not [string]::IsNullOrWhiteSpace($Root)) { $rootFull = [System.IO.Path]::GetFullPath($Root) }
        if (-not [string]::IsNullOrWhiteSpace($rootFull)) {
            $sep = [System.IO.Path]::DirectorySeparatorChar
            $prefix = $rootFull.TrimEnd($sep) + $sep
            if ($Full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                return ($Full.Substring($prefix.Length) -replace '\\', '/')
            }
        }
    } catch { }
    try { return [System.IO.Path]::GetFileName($Full) } catch { return $Full }
}

function Get-ManifestExportedFunctionNames {
    # Return the LITERAL FunctionsToExport names from a .psd1 manifest (Import-PowerShellDataFile is
    # data-only, no code execution). A wildcard '*' entry makes the export set indeterminate -> return
    # @() (contribute nothing; the survey's silence-on-ambiguity). FAIL-SAFE: @() on any error.
    param([string]$Path)
    try {
        $data = Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop
        if ($null -eq $data) { return @() }
        $fte = $data['FunctionsToExport']
        if ($null -eq $fte) { return @() }
        $names = @()
        foreach ($x in @($fte)) {
            $s = [string]$x
            if ([string]::IsNullOrWhiteSpace($s)) { continue }
            if ($s.Contains('*')) { return @() }   # wildcard export -> indeterminate -> contribute nothing
            $names += $s
        }
        return @($names)
    } catch { return @() }
}

function Add-ReferenceNameToFileSet {
    # Record that $File defines or references $Name (a case-insensitive HashSet of files per name).
    param($Map, [string]$Name, [string]$File)
    if ($null -eq $Map) { return }
    if (-not $Map.ContainsKey($Name)) {
        $Map[$Name] = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    }
    [void]$Map[$Name].Add($File)
}

function Add-ReferenceIndexFile {
    # Fold ONE parsed workspace file into the reference index: its function / alias DEFINITIONS, its
    # command REFERENCES (literal names only -- a dynamic/computed target's GetCommandName() is $null and
    # contributes nothing), and, for a .psd1, its literal FunctionsToExport. FAIL-SAFE per node.
    param($Index, $Ast, [string]$FilePath)
    if ($null -eq $Ast -or $null -eq $Index) { return }
    $nodes = @()
    try {
        $nodes = @($Ast.FindAll({ param($n)
                    $tn = $n.GetType().Name
                    ($tn -eq 'CommandAst') -or ($tn -eq 'FunctionDefinitionAst') }, $true))
    } catch { return }
    foreach ($n in $nodes) {
        $tn = ''
        try { $tn = $n.GetType().Name } catch { $tn = '' }
        if ($tn -eq 'FunctionDefinitionAst') {
            $nm = ''
            try { $nm = [string]$n.Name } catch { $nm = '' }
            if (-not [string]::IsNullOrWhiteSpace($nm)) { Add-ReferenceNameToFileSet $Index['Defs'] $nm $FilePath }
            continue
        }
        $cn = $null
        try { $cn = $n.GetCommandName() } catch { $cn = $null }
        if ([string]::IsNullOrWhiteSpace($cn)) { continue }
        $cnl = $cn.ToLowerInvariant()
        if ($cnl -eq 'set-alias' -or $cnl -eq 'new-alias' -or $cnl -eq 'sal' -or $cnl -eq 'nal') {
            $aliasName = Get-AliasDefinitionNameFromCommand $n
            if (-not [string]::IsNullOrWhiteSpace($aliasName)) { Add-ReferenceNameToFileSet $Index['Defs'] $aliasName $FilePath }
            continue
        }
        Add-ReferenceNameToFileSet $Index['Refs'] $cn $FilePath
    }
    $ext = ''
    try { $ext = [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant() } catch { $ext = '' }
    if ($ext -eq '.psd1') {
        foreach ($en in @(Get-ManifestExportedFunctionNames -Path $FilePath)) {
            if (-not [string]::IsNullOrWhiteSpace($en)) { [void]$Index['Exported'].Add($en) }
        }
    }
}

function Get-ReferenceIndexFiles {
    # Enumerate the workspace PowerShell files to index -- a manual prune-and-cap walk so a pathological
    # tree cannot make the session build unbounded and so noise dirs (.git / node_modules / a vendored
    # PSES bundle) are never descended. Returns @() on any error.
    param([string]$Root, [int]$MaxFiles = 5000)
    $out = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Root)) { return @($out) }
    $full = ''
    try { $full = [System.IO.Path]::GetFullPath($Root) } catch { return @($out) }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { return @($out) }
    $excludeDir = @('.git', 'node_modules', 'PowerShellEditorServices', '.vs', '.svn', '.hg')
    $stack = New-Object System.Collections.Stack
    $stack.Push($full)
    while ($stack.Count -gt 0 -and $out.Count -lt $MaxFiles) {
        $dir = [string]$stack.Pop()
        $children = $null
        try { $children = Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue } catch { $children = $null }
        foreach ($c in @($children)) {
            if ($out.Count -ge $MaxFiles) { break }
            if ($c.PSIsContainer) {
                if ($excludeDir -notcontains $c.Name) { $stack.Push($c.FullName) }
            } else {
                $ext = ''
                try { $ext = $c.Extension.ToLowerInvariant() } catch { $ext = '' }
                if ($ext -eq '.ps1' -or $ext -eq '.psm1' -or $ext -eq '.psd1') { [void]$out.Add([string]$c.FullName) }
            }
        }
    }
    return @($out)
}

function Build-ReferenceIndex {
    # Build the session workspace reference index: parse every workspace .ps1/.psm1/.psd1 ONCE and record,
    # per literal function/alias name, the files that DEFINE it and the files that REFERENCE it, plus the
    # exported-name set (manifest FunctionsToExport literals) and the builtin-cmdlet name set (the call-site
    # collision guard). This is the O(repo) session build the 000127 survey measured (~2.4s at 130 files);
    # per-edit is then O(edited file). FAIL-SAFE: a per-file parse error is skipped; a total failure yields
    # an empty index (the check then never fires -- a positive fact against an empty index is impossible).
    param([string]$Root, [int]$MaxFiles = 5000)
    $idx = @{
        Root      = ''
        Defs      = @{}
        Refs      = @{}
        Exported  = (New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase))
        Builtins  = (New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase))
        FileCount = 0
    }
    try { $idx['Root'] = [System.IO.Path]::GetFullPath($Root) } catch { $idx['Root'] = [string]$Root }
    # Builtin-cmdlet collision guard: a workspace function that SHADOWS a real cmdlet cannot be told from
    # the cmdlet at a bare call site, so such names are silenced at surface time. Cmdlets are compiled and
    # stable across hosts, so this set is deterministic enough for the guard.
    try {
        foreach ($c in @(Get-Command -CommandType Cmdlet -ErrorAction SilentlyContinue)) {
            $cn = [string]$c.Name
            if (-not [string]::IsNullOrWhiteSpace($cn)) { [void]$idx['Builtins'].Add($cn) }
        }
    } catch { }
    foreach ($f in @(Get-ReferenceIndexFiles -Root $Root -MaxFiles $MaxFiles)) {
        $ast = $null
        try { $ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$null) } catch { $ast = $null }
        if ($null -eq $ast) { continue }
        $idx['FileCount'] = [int]$idx['FileCount'] + 1
        Add-ReferenceIndexFile -Index $idx -Ast $ast -FilePath $f
    }
    return $idx
}

function Find-ReferenceSurfacing {
    <#
    .SYNOPSIS
        From the edited file's AST + the session workspace index, surface BARE per-function facts:
        for a function DEFINED in this file -- how many OTHER workspace files reference it, and whether it
        is exported; for a command CALLED in this file that resolves to a UNIQUE workspace definition
        elsewhere -- where it is defined. Every ambiguity resolves to SILENCE (the 000127 survey ledger).
    .DESCRIPTION
        PURE over the supplied AST + injected index. Returns @() when $Ast/$Index is $null, when the file
        has a DYNAMIC dot-source or DYNAMIC Import-Module (the whole file is suppressed -- a dynamic include
        could define names we cannot see), or when nothing survives the guards. Dedup per name (a definition
        fact wins over a reference fact for the same name); deterministic order (by name). Each record
        carries structured fields AND a rendered `message`; the client prints the messages under a single
        'References:' section. NO new diagnostic code / status token -- these are additive facts, not defects.

        GUARDS (each -> silence for that name, never a wrong fact):
          - the name SHADOWS a builtin cmdlet (ambiguous at the call site);
          - the workspace DEFINES the name in more than one file (cannot say WHICH is referenced);
          - a DYNAMIC dot-source / Import-Module is present (suppress the whole file);
          - a definition with NO cross-file references AND not exported (nothing positive to say);
          - a called name with 0 or >1 workspace definitions (not a unique cross-file target).
    #>
    param(
        $Ast,
        $Index,
        [string]$EditedFilePath = ''
    )
    if ($null -eq $Ast -or $null -eq $Index) { return @() }
    $defs = $Index['Defs']; $refs = $Index['Refs']; $exported = $Index['Exported']; $builtins = $Index['Builtins']
    if ($null -eq $defs) { return @() }

    $editedFull = ''
    try { if (-not [string]::IsNullOrWhiteSpace($EditedFilePath)) { $editedFull = [System.IO.Path]::GetFullPath($EditedFilePath) } } catch { $editedFull = '' }

    $nodes = @()
    try {
        $nodes = @($Ast.FindAll({ param($n)
                    $tn = $n.GetType().Name
                    ($tn -eq 'CommandAst') -or ($tn -eq 'FunctionDefinitionAst') }, $true))
    } catch { return @() }

    $localDefs = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $defOrder = New-Object System.Collections.ArrayList
    $callNodes = New-Object System.Collections.ArrayList
    $suppressFile = $false
    foreach ($n in $nodes) {
        $tn = ''
        try { $tn = $n.GetType().Name } catch { $tn = '' }
        if ($tn -eq 'FunctionDefinitionAst') {
            $nm = ''
            try { $nm = [string]$n.Name } catch { $nm = '' }
            if (-not [string]::IsNullOrWhiteSpace($nm) -and $localDefs.Add($nm)) { [void]$defOrder.Add($nm) }
            continue
        }
        $ds = Get-DotSourceClass $n
        if ($ds.IsDotSource) {
            if ($ds.Dynamic) { $suppressFile = $true }
            continue   # a dot-source's "name" is a path, never a command reference
        }
        $cn = $null
        try { $cn = $n.GetCommandName() } catch { $cn = $null }
        if (-not [string]::IsNullOrWhiteSpace($cn)) {
            $cnl = $cn.ToLowerInvariant()
            if ($cnl -eq 'import-module' -or $cnl -eq 'ipmo') {
                $imp = Get-ImportModuleModuleNames $n
                if ($imp.Dynamic) { $suppressFile = $true }
                continue
            }
        }
        [void]$callNodes.Add($n)
    }
    if ($suppressFile) { return @() }

    $records = New-Object System.Collections.ArrayList
    $emitted = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    # (1) DEFINITION facts -- functions defined in THIS file.
    foreach ($name in $defOrder) {
        if ($null -ne $builtins -and $builtins.Contains($name)) { continue }        # shadows a cmdlet
        $defFiles = $null
        if ($defs.ContainsKey($name)) { $defFiles = $defs[$name] }
        if ($null -ne $defFiles -and $defFiles.Count -gt 1) { continue }            # duplicate defs -> ambiguous
        $cnt = 0
        if ($null -ne $refs -and $refs.ContainsKey($name)) {
            foreach ($rf in @($refs[$name])) {
                $rfull = ''
                try { $rfull = [System.IO.Path]::GetFullPath([string]$rf) } catch { $rfull = [string]$rf }
                if ($rfull -ne $editedFull) { $cnt++ }
            }
        }
        $isExp = ($null -ne $exported -and $exported.Contains($name))
        if ($cnt -lt 1 -and -not $isExp) { continue }                              # nothing positive to say
        if (-not $emitted.Add($name)) { continue }
        $facts = @()
        if ($cnt -ge 1) { $facts += ('referenced by ' + $cnt + ' ' + (Get-ReferenceFilePlural $cnt)) }
        if ($isExp) { $facts += 'exported' }
        [void]$records.Add([pscustomobject]@{
                source = 'powershell-lsp'; kind = 'definition'; name = $name
                refCount = $cnt; exported = $isExp; definedIn = ''
                message = ($name + ' -- ' + ($facts -join ', '))
            })
    }

    # (2) REFERENCE facts -- a command called here whose UNIQUE workspace definition is ELSEWHERE.
    foreach ($node in $callNodes) {
        $name = $null
        try { $name = $node.GetCommandName() } catch { $name = $null }
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($localDefs.Contains($name)) { continue }                               # defined here -> not cross-file
        if ($null -ne $builtins -and $builtins.Contains($name)) { continue }
        if (-not $defs.ContainsKey($name)) { continue }
        $defFiles = @($defs[$name])
        if ($defFiles.Count -ne 1) { continue }                                    # 0 or ambiguous -> silence
        $defFull = ''
        try { $defFull = [System.IO.Path]::GetFullPath([string]$defFiles[0]) } catch { $defFull = [string]$defFiles[0] }
        if ($defFull -eq $editedFull) { continue }                                 # defined in this very file
        if (-not $emitted.Add($name)) { continue }
        $rel = Get-ReferenceRelativePath -Full $defFull -Root ([string]$Index['Root'])
        [void]$records.Add([pscustomobject]@{
                source = 'powershell-lsp'; kind = 'reference'; name = $name
                refCount = 0; exported = $false; definedIn = $rel
                message = ($name + ' -- defined in ' + $rel)
            })
    }

    return @($records | Sort-Object -Property name)
}

function Get-NearestManifestRequiredModules {
    # Resolve the nearest module manifest walked up from $FilePath (Find-ModuleManifest) and return
    # its RequiredModules module NAMES (rung 4 via manifest). RequiredModules entries may be strings
    # or @{ ModuleName = 'X'; ... } hashtables -- both are normalized to the name. Returns @() when
    # there is no manifest / no RequiredModules / on ANY error (the check never throws). Reads the
    # manifest via Import-PowerShellDataFile with the index-not-dot-access StrictMode discipline
    # (a missing key via the indexer is $null, not a throw -- the 000062 lesson).
    param([string]$FilePath)
    if ([string]::IsNullOrWhiteSpace($FilePath)) { return @() }
    try {
        $manifestPath = Find-ModuleManifest -FilePath $FilePath
        if ([string]::IsNullOrWhiteSpace($manifestPath)) { return @() }
        $data = Import-PowerShellDataFile -LiteralPath $manifestPath -ErrorAction Stop
        if ($null -eq $data) { return @() }
        $rm = $data['RequiredModules']
        if ($null -eq $rm) { return @() }
        $names = New-Object System.Collections.Generic.List[string]
        foreach ($entry in @($rm)) {
            $n = ''
            if ($entry -is [string]) { $n = [string]$entry }
            elseif ($entry -is [System.Collections.IDictionary]) { $n = [string]$entry['ModuleName'] }
            else { try { $n = [string]$entry } catch { $n = '' } }
            if (-not [string]::IsNullOrWhiteSpace($n)) { $names.Add($n) }
        }
        return @($names)
    } catch { return @() }
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
                        # Extract static -Function / -Cmdlet names into the FUNCTION exported-set. NOT
                        # -Alias: an alias is not a function, and folding an Export-ModuleMember -Alias name
                        # into the function set falsely flagged it as an under-declared FUNCTION (the
                        # BurntToast shape -- dispatch 000128 slice 2). Alias exports are a separate namespace
                        # tracked by Get-ModuleAliasSurface; a -Alias parameter is still SCANNED (so a dynamic
                        # -Alias value still degrades) but its names are not added here.
                        $i = 0
                        while ($i -lt $elems.Count) {
                            $ceStr = [string]$elems[$i]
                            if ($ceStr -eq '-Function' -or $ceStr -eq '-Cmdlet' -or $ceStr -eq '-Alias') {
                                $collectFn = ($ceStr -ne '-Alias')
                                $i++
                                while ($i -lt $elems.Count) {
                                    $val = $elems[$i]
                                    $valStr = [string]$val
                                    if ($valStr.StartsWith('-')) { break }
                                    if ($val -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                                        if ($collectFn) { $exported.Add($val.Value) }
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

function Get-ModuleAliasSurface {
    # The ALIAS half of a module's surface (dispatch 000128, N1.6 slice-2): the literal Set-Alias/New-Alias
    # names the root module defines, and whether the alias-orphan check must DEGRADE to silence. Indeterminate
    # is TRUE on any shape that could define or export an alias the static check cannot see -- the 000127
    # leg-4 requirements spec, whose two probe hits name these rungs:
    #   - a DYNAMIC invocation (GetCommandName() is $null) -- e.g. Pester's `& $SafeCommands['Set-Alias']`;
    #   - a Set-Alias/New-Alias whose NAME is not a literal (splat / variable);
    #   - an `Export-ModuleMember -Alias` -- e.g. BurntToast's explicit alias-export management.
    # (Dot-source and a binary/absent RootModule already degrade the WHOLE surface upstream, so this pure
    # function need not re-detect them.) FAIL-SAFE: Indeterminate=$true on any error -- never fire against a
    # surface we could not fully read. PURE over the file; no new diagnostic code (the caller reuses the
    # existing ManifestConsistency ruleId).
    param([string]$ModuleFilePath)
    $safe = @{ DefinedAliases = @(); Indeterminate = $true }
    if ([string]::IsNullOrWhiteSpace($ModuleFilePath) -or -not (Test-Path -LiteralPath $ModuleFilePath -PathType Leaf)) { return $safe }
    try {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ModuleFilePath, [ref]$null, [ref]$null)
        if ($null -eq $ast) { return $safe }
        $defined = New-Object System.Collections.Generic.List[string]
        $indeterminate = $false
        $cmdNodes = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true))
        foreach ($cmd in $cmdNodes) {
            $cn = $null
            try { $cn = $cmd.GetCommandName() } catch { $cn = $null }
            if ([string]::IsNullOrWhiteSpace($cn)) { $indeterminate = $true; continue }   # dynamic invocation (& $x)
            $cnl = $cn.ToLowerInvariant()
            if ($cnl -eq 'set-alias' -or $cnl -eq 'new-alias' -or $cnl -eq 'sal' -or $cnl -eq 'nal') {
                $an = Get-AliasDefinitionNameFromCommand $cmd
                if (-not [string]::IsNullOrWhiteSpace($an)) { $defined.Add($an) } else { $indeterminate = $true }   # non-literal name
            } elseif ($cnl -eq 'export-modulemember') {
                foreach ($ce in @($cmd.CommandElements)) {
                    $isAlias = $false
                    try { $isAlias = ($ce -is [System.Management.Automation.Language.CommandParameterAst]) -and (([string]$ce.ParameterName).ToLowerInvariant() -eq 'alias') } catch { $isAlias = $false }
                    if ($isAlias) { $indeterminate = $true; break }
                }
            }
        }
        return @{ DefinedAliases = @($defined); Indeterminate = $indeterminate }
    } catch { return $safe }
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
        [string]$ManifestPath,
        # Alias-orphan check (dispatch 000128, slice 2). DefinedAliases = the literal Set-Alias/New-Alias
        # names the module defines; AliasesIndeterminate = the alias surface cannot be statically verified
        # (dynamic invocation / non-literal alias name / Export-ModuleMember -Alias / nested modules), in
        # which case the alias-orphan check DEGRADES to silence. DEFAULTS keep the alias check OFF for any
        # caller that does not supply alias data -- the function-export semantics are unchanged.
        [string[]]$DefinedAliases = @(),
        [bool]$AliasesIndeterminate = $true
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
    # 3. ALIAS-ORPHAN EXPORT (dispatch 000128, slice 2): an alias in AliasesToExport with no matching literal
    #    Set-Alias/New-Alias definition in the module. Symmetric with the function orphan check (rung 1),
    #    same ManifestConsistency code -- NO new owned diagnostic code, NO rationale change. GATED on a
    #    DETERMINATE alias surface: when AliasesIndeterminate the whole alias check is SILENT (a dynamic
    #    invocation / non-literal alias name / Export-ModuleMember -Alias / nested module could define the
    #    alias invisibly -- the 000127 leg-4 requirements spec, whose two probe hits are Pester and BurntToast).
    if (-not $AliasesIndeterminate -and $null -ne $AliasesToExport -and @($AliasesToExport).Count -gt 0) {
        $definedAliasSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($a in $DefinedAliases) { $an = [string]$a; if (-not [string]::IsNullOrWhiteSpace($an)) { [void]$definedAliasSet.Add($an) } }
        foreach ($aliasName in $AliasesToExport) {
            $nn = [string]$aliasName
            if ([string]::IsNullOrWhiteSpace($nn)) { continue }
            if (-not $definedAliasSet.Contains($nn)) {
                [void]$findings.Add([pscustomobject]@{
                    ruleId = 'ManifestConsistency'; code = 'ManifestConsistency'
                    source = 'powershell-lsp'
                    severity = 'Warning'; line = 1; col = 1
                    message = "Alias '$nn' is listed in AliasesToExport but no matching Set-Alias/New-Alias definition was found in the module."
                })
            }
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
    # Alias surface (dispatch 000128, slice 2): the module's literal alias definitions and whether the
    # alias check must degrade. A non-empty manifest NestedModules ALSO forces the alias check to degrade --
    # aliases could be defined in a nested module this cross-reference does not parse.
    $aliasSurface = Get-ModuleAliasSurface -ModuleFilePath $rootModulePath
    $nested = @()
    try { $nested = @($exports.Data['NestedModules']) } catch { $nested = @() }
    $nestedPresent = (@($nested | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0)
    # Cross-reference.
    return Test-ManifestConsistency `
        -FunctionsToExport $exports.FunctionsToExport `
        -CmdletsToExport $exports.CmdletsToExport `
        -AliasesToExport $exports.AliasesToExport `
        -DefinedNames $moduleInfo.DefinedNames `
        -ExportedNames $moduleInfo.ExportedNames `
        -ManifestPath $manifestPath `
        -DefinedAliases $aliasSurface.DefinedAliases `
        -AliasesIndeterminate ([bool]$aliasSurface.Indeterminate -or $nestedPresent)
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
    # Map the raw formatOnEdit knob string to a mode: 'off' | 'suggest' | 'apply'. Default-safe:
    # absent / blank / an unexpanded '${user_config...}' token / any unrecognized value -> 'off'
    # (the feature is opt-in; an unparseable knob never silently turns it on). 'suggest' surfaces a
    # diff and NEVER writes; the boolean-truthy aliases 'true'/'on'/'1'/'yes' map to 'suggest' so a
    # user who reaches for a boolean gets the safe suggest behavior. 'apply' (dispatch 000099) is the
    # ONLY value that activates the guarded write-back path: it is DOUBLY opt-in (an explicit, exact
    # 'apply' -- never reachable through a boolean alias), so no config is upgraded into file writes
    # by accident. The write path itself is guarded (stale-write compare-and-swap, byte fidelity,
    # atomic-or-abort); this function only classifies the knob.
    param([string]$Raw)
    $v = ([string]$Raw).Trim().ToLowerInvariant()
    switch ($v) {
        'suggest' { return 'suggest' }
        'true'    { return 'suggest' }
        'on'      { return 'suggest' }
        '1'       { return 'suggest' }
        'yes'     { return 'suggest' }
        'apply'   { return 'apply' }
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

# --- format-on-edit APPLY: the guarded write-back path (dispatch 000099, PL-8 slice 2) --------
# 000059 shipped suggest-not-apply; this slice activates 'apply', the FIRST feature that ever
# WRITES the user's file. The entire risk lives in the write path, so it is guarded by ALL of:
#   * a stale-write COMPARE-AND-SWAP: the file's bytes are hashed at format-input time and
#     re-hashed immediately before the write, in the SAME process that writes (the daemon); ANY
#     mismatch ABORTS -- a concurrent modification always wins (Write-FormatResultAtomic).
#   * ATOMIC-OR-ABORT: the formatted bytes are staged to a temp file in the SAME directory and
#     swapped in with [IO.File]::Replace (an atomic NTFS replace that preserves the destination's
#     ACLs/attributes); a crashed write can never leave a torn/partial file.
#   * BYTE FIDELITY: the original BOM state and dominant EOL style are captured from the RAW bytes
#     and re-applied to the formatter's (LF-normalized) output, so the only byte delta is the
#     formatting change itself (Get-ApplyEncodedBytes). The 000059 LF normalization is
#     formatter-INPUT-only; the write path re-applies the original conventions.
#   * NO-CHANGE = NO WRITE: an already-formatted file is never touched (the caller checks
#     Get-FormatDiffResult.changed before staging any write), preserving clean-edit-emits-nothing.
#   * CONSERVATIVE ABORTS (OQ4): a MIXED CRLF/LF file or a non-UTF-8 (UTF-16) file ABORTS to
#     suggest -- normalizing the minority EOL on unchanged lines would be a byte change beyond the
#     formatting delta, and a silent full normalization the surface does not mention is never
#     emitted. When in doubt, apply aborts to suggest.
# These helpers are PURE / unit-testable; the daemon orchestrator (Invoke-FormatApply) wires them
# to the REUSED 000059 formatter + settings resolution + diff engine. The apply path EXTENDS the
# 000059 core -- it never duplicates the formatter or the pinned-PSSA import.

function Get-Sha256HexFromBytes {
    # Deterministic lower-case hex SHA-256 of a byte buffer -- the stale-write guard's fingerprint.
    # Same primitive as the dogfood capture hash, kept as its own helper so the apply CAS and its
    # tests share one implementation. NEVER throws for a valid array (an empty array hashes fine).
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hashBytes = $sha.ComputeHash($Bytes) } finally { $sha.Dispose() }
    return (([System.BitConverter]::ToString($hashBytes)) -replace '-', '').ToLowerInvariant()
}

function Test-Utf8Bom {
    # $true iff the buffer opens with the UTF-8 BOM (EF BB BF). Guards the byte-fidelity contract:
    # a BOM file must come back a BOM file. StrictMode-safe (length-checked before indexing).
    param([byte[]]$Bytes)
    return ($null -ne $Bytes -and $Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF)
}

function Test-Utf16Bom {
    # $true iff the buffer opens with a UTF-16 BOM (FF FE LE or FE FF BE). Apply supports the
    # UTF-8 family only; a UTF-16 file ABORTS to suggest (re-encoding its formatted text as UTF-8
    # would rewrite every byte, far beyond the formatting delta). StrictMode-safe.
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -lt 2) { return $false }
    if ($Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) { return $true }
    if ($Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) { return $true }
    return $false
}

function Get-DominantEol {
    # Classify a text's line-ending style from its RAW content: 'crlf' (only CRLF), 'lf' (only bare
    # LF), 'none' (no terminators -- a single line), or 'mixed' (any mixture, OR a bare CR). Apply
    # writes back 'crlf'/'lf'/'none' with the ORIGINAL style re-applied; 'mixed' ABORTS to suggest
    # (OQ4) so an unchanged minority-EOL line is never silently flipped. [regex]::Matches with
    # runtime CR/LF patterns keeps the SOURCE ASCII-clean and is 5.1-safe.
    param([string]$Text)
    $t = [string]$Text
    $crlf = ([regex]::Matches($t, "`r`n")).Count
    $allLf = ([regex]::Matches($t, "`n")).Count
    $allCr = ([regex]::Matches($t, "`r")).Count
    $loneLf = $allLf - $crlf
    $loneCr = $allCr - $crlf
    if ($crlf -eq 0 -and $loneLf -eq 0 -and $loneCr -eq 0) { return 'none' }
    if ($loneCr -gt 0) { return 'mixed' }                       # a bare CR (classic Mac) -> unsupported
    if ($crlf -gt 0 -and $loneLf -gt 0) { return 'mixed' }      # genuinely mixed CRLF + LF
    if ($crlf -gt 0) { return 'crlf' }
    return 'lf'
}

function ConvertTo-Eol {
    # Re-apply a line-ending style to text. Normalize to LF first (defensive: the formatter output
    # EOL is not guaranteed), then emit: 'crlf' -> CRLF; anything else ('lf'/'none') -> LF. Mirrors
    # the 000059 Invoke-RepoFormatter normalization idiom exactly.
    param([string]$Text, [string]$Eol)
    $lf = (([string]$Text) -replace "`r`n", "`n") -replace "`r", "`n"
    if ($Eol -eq 'crlf') { return ($lf -replace "`n", "`r`n") }
    return $lf
}

function Get-ApplyEncodedBytes {
    # Assemble the exact bytes to write back: the formatter's output re-EOLed to $Eol, UTF-8
    # encoded WITHOUT a BOM, then a UTF-8 BOM prepended iff the original had one. This is the whole
    # byte-fidelity contract in one pure builder -- the only intended byte delta vs the original is
    # the formatting change. Returns a byte[] (the leading comma prevents pipeline unrolling).
    param([string]$FormattedText, [string]$Eol, [bool]$HasBom)
    $eolText = ConvertTo-Eol -Text $FormattedText -Eol $Eol
    $enc = New-Object System.Text.UTF8Encoding($false)          # UTF-8, NO BOM
    $body = $enc.GetBytes($eolText)
    if (-not $HasBom) { return , $body }
    $bom = [byte[]](0xEF, 0xBB, 0xBF)
    $out = New-Object 'byte[]' ($bom.Length + $body.Length)
    [System.Array]::Copy($bom, 0, $out, 0, $bom.Length)
    [System.Array]::Copy($body, 0, $out, $bom.Length, $body.Length)
    return , $out
}

function Write-FormatResultAtomic {
    # The stale-write COMPARE-AND-SWAP and ATOMIC write, together, in the caller's (daemon) process.
    # $InputHash is the SHA-256 of the file's bytes AS THE FORMATTER SAW THEM. Here we: stage
    # $OutBytes to a temp file in the SAME directory (touching NOTHING on the target yet), RE-READ
    # the target's current bytes as close to the swap as possible, and compare their hash to
    # $InputHash. On ANY mismatch we ABORT and the concurrent modification survives untouched (the
    # mutated file always wins). On a match we swap the temp in with [IO.File]::Replace -- atomic on
    # NTFS, preserves the destination's ACLs/attributes, and either fully replaces or throws leaving
    # the original intact (never a torn file). Any failure (a sharing violation, a read-only target)
    # ABORTS honestly; the temp is always cleaned up. NEVER throws past its own frame.
    # Returns @{ applied = <bool>; reason = <string> }.
    param([string]$Full, [string]$InputHash, [byte[]]$OutBytes)
    $tmp = $null
    try {
        $dir = [System.IO.Path]::GetDirectoryName($Full)
        $tmp = [System.IO.Path]::Combine($dir, ('.pslsp-fmt-' + [System.Guid]::NewGuid().ToString('N') + '.tmp'))
        [System.IO.File]::WriteAllBytes($tmp, $OutBytes)         # stage temp -- does NOT touch $Full
        $currentBytes = [System.IO.File]::ReadAllBytes($Full)    # CAS re-read, immediately before the swap
        if ((Get-Sha256HexFromBytes $currentBytes) -ne $InputHash) {
            return @{ applied = $false; reason = 'file changed on disk since formatting' }
        }
        # Atomic swap, right after the check. [NullString]::Value passes a REAL null for the (no)
        # backup file -- a bare $null binds to '' and File.Replace rejects it ("The path is empty").
        [System.IO.File]::Replace($tmp, $Full, [NullString]::Value)
        $tmp = $null                                             # Replace consumed the temp
        return @{ applied = $true; reason = '' }
    } catch {
        return @{ applied = $false; reason = ('write failed: ' + $_.Exception.Message) }
    } finally {
        if ($null -ne $tmp) { try { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } } catch { } }
    }
}

function Format-FormattingAppliedBlock {
    # Render the additionalContext block for a format-on-edit APPLY that WROTE the file (000099),
    # or '' when there is nothing to show ($Diff empty). Deliberately DISTINCT from both the
    # diagnostics header ('PowerShell diagnostics (...)') and the suggest header ('...suggestion...
    # The file was NOT modified...'): this states the file WAS MODIFIED and that the agent's
    # in-context copy is now STALE, so it must RE-READ before its next edit (an old_str/Edit against
    # the pre-format text would miss). The parenthetical records that this turn's diagnostics were
    # derived from the PRE-apply bytes and are omitted to avoid stale line numbers (OQ2). PURE.
    param([string]$Path, [string]$Diff, [int]$Removed, [int]$Added, [bool]$Truncated, [string]$SettingsPath)
    if ([string]::IsNullOrEmpty($Diff)) { return '' }
    $styleNote = if (-not [string]::IsNullOrWhiteSpace($SettingsPath)) {
        'repo style (' + (Split-Path -Leaf $SettingsPath) + ')'
    } else {
        'default PSScriptAnalyzer style'
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('PowerShell formatting APPLIED to ' + $Path + ' -- ' + $styleNote +
        ': the file WAS MODIFIED on disk (-' + $Removed + ' / +' + $Added + ' lines). Your in-context ' +
        'copy is now STALE -- RE-READ the file before your next edit, or an old_str/Edit against the ' +
        'pre-format text will miss. (Diagnostics for this turn were derived from the pre-format bytes ' +
        'and are omitted to avoid stale line numbers; they refresh on your next edit.)')
    [void]$sb.Append($Diff)
    if ($Truncated) { [void]$sb.Append("`n... (formatting diff truncated)") }
    return $sb.ToString()
}

function Format-FormattingApplyAbortedBlock {
    # Render the additionalContext block when an APPLY was requested but ABORTED (000099): a
    # suggest-SHAPED fallback (the file was NOT modified) carrying an honest one-line reason apply
    # did not run -- a concurrent modification, mixed line endings, an unsupported encoding, or a
    # write error. The leading 'apply did NOT run (<reason>)' clause distinguishes it from a plain
    # suggest. '' when there is nothing to show ($Diff empty). PURE.
    param([string]$Path, [string]$Diff, [int]$Removed, [int]$Added, [bool]$Truncated, [string]$SettingsPath, [string]$Reason)
    if ([string]::IsNullOrEmpty($Diff)) { return '' }
    $styleNote = if (-not [string]::IsNullOrWhiteSpace($SettingsPath)) {
        'repo style (' + (Split-Path -Leaf $SettingsPath) + ')'
    } else {
        'default PSScriptAnalyzer style'
    }
    $why = if (-not [string]::IsNullOrWhiteSpace($Reason)) { $Reason } else { 'apply could not complete safely' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('PowerShell formatting suggestion for ' + $Path + ' -- ' + $styleNote +
        ': apply did NOT run (' + $why + ') -- the file was NOT modified. The formatted version differs (-' +
        $Removed + ' / +' + $Added + ' lines); run Invoke-Formatter yourself to apply this style.')
    [void]$sb.Append($Diff)
    if ($Truncated) { [void]$sb.Append("`n... (formatting diff truncated)") }
    return $sb.ToString()
}
