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

function Get-PluginDataRootResolution {
    # THE SHARED PROVENANCE SEAM (dispatch 000185, D1-A). Returns the data root TOGETHER WITH
    # how it was resolved, so a reader can distinguish "the input is absent" from "I did not
    # find the input under the directory I happened to resolve".
    #
    # WHY THIS EXISTS. Get-PluginDataRoot above substitutes a temp fallback SILENTLY when
    # CLAUDE_PLUGIN_DATA is unset, and nothing in its return value carries which branch was
    # taken. A reader that searches the substituted root and finds nothing then renders a claim
    # about THE WORLD ("the signal was never captured") on evidence that only supports a claim
    # about THE READER ("I found no file where I looked"). Dispatch 000182 found that live in
    # rule-efficacy-ledger.ps1; 000183 leg 2 found the same silent-fallback shape at four
    # independent sites resolving to three different directories, with doctor.ps1's
    # Get-DoctorDataRootKnown as the one in-tree site that already had it right. This function
    # PROMOTES that predicate into the shared library so the knowledge lives in one place
    # instead of being re-invented per reader.
    #
    # Get-PluginDataRoot is deliberately NOT changed: its signature and return value stay
    # byte-identical, its fallback stays, and every existing caller keeps its behavior. The fix
    # is to make the resolution LEGIBLE, not to make it strict -- out-of-band invocations and
    # the test suite depend on the fallback existing.
    #
    # Root is byte-identical to Get-PluginDataRoot's return by construction: this calls it.
    $known = (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_PLUGIN_DATA))
    return [pscustomobject]@{
        Root       = (Get-PluginDataRoot)
        Known      = $known
        Provenance = $(if ($known) { 'env:CLAUDE_PLUGIN_DATA' } else { 'fallback:temp' })
    }
}

function Test-PluginDataRootKnown {
    # $true iff the data root came from CLAUDE_PLUGIN_DATA rather than the temp fallback.
    #
    # DERIVED from Get-PluginDataRootResolution above, never re-implemented, so the predicate
    # and the resolution object cannot disagree -- which is the exact failure (the same
    # knowledge written down twice and drifting) this seam exists to end.
    return [bool](Get-PluginDataRootResolution).Known
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

# --- artifact-source layering (dispatch 000244) -----------------------------
# The two pinned artifacts may be resolved from more than one PLACE without changing what
# is TRUSTED. Resolution order is mirror -> bundle -> the caller's own default download.
# The FIRST layer that yields the artifact wins, and that artifact then passes the caller's
# EXISTING Test-PinnedFileHash gate byte-for-byte identically, whichever layer produced it.
#
# THE GOVERNING PRINCIPLE, inherited verbatim from the 000049 pinned-.nupkg cache: a source
# is a TRANSPORT OPTIMIZATION, NEVER A TRUST SHORTCUT. The pins in the ensure-scripts remain
# the only trust root. A mirror or a bundle is not a trust root and cannot become one -- it
# changes which bytes are OFFERED, never whether they are BELIEVED.
#
# TWO CONSEQUENCES, both deliberate:
#   1. A pin MISMATCH from any layer FAILS CLOSED in the caller. It does NOT fall through to
#      the next layer. Falling through would let anyone who controls one layer force a
#      downgrade onto another, and it would turn a tamper signal into a retry. This is the
#      000049 cache rule exactly (a poisoned cache entry exits 1; it never self-heals).
#   2. A layer MISS -- not configured, or configured but the artifact is absent -- is NOT a
#      failure. It falls through to the next layer. That is what makes an UNSET configuration
#      byte-identical to pre-000244 behavior: with neither variable set this resolver returns
#      unresolved immediately, having touched no network and no disk.
#
# WHY ENVIRONMENT VARIABLES AND NOT userConfig KNOBS (ruled by Mike, dispatch 000244). Every
# POWERSHELL_LSP_* variable in this project is infrastructure/admin plumbing (the PSSA cache,
# the SARIF artifact dir, the dogfood log, the push guard); every userConfig knob is user-facing
# diagnostics behavior. A mirror base and a staged bundle directory are fleet plumbing set once
# by IT, and the env surface is the fleet-DEPLOYABLE one (GPO, Intune, machine scope) -- which
# a per-user /plugin config panel is not. They therefore add NO CONTRACT.md frozen surface.

function Get-PinnedArtifactFileName {
    # THE single source of truth for what a staged artifact is CALLED. The ensure-scripts, the
    # release bundle builder, the doctor's offline-readiness check, and the Pester suite all
    # derive the name here rather than each spelling it out -- the same one-place-for-one-fact
    # rule that keeps the SBOM from disagreeing with what the tool downloads.
    #
    # Names are VERSION-QUALIFIED because upstream's own names are not sufficient: the PSES
    # release asset is a bare 'PowerShellEditorServices.zip' (identical across every tag), and
    # the PSSA Gallery URL carries no filename at all. An admin mirroring two versions needs
    # them to be distinguishable on disk.
    #
    # The pin hash is deliberately NOT in the name, which is where this departs from the 000049
    # cache. That cache binds the SHA into its filename so a re-pin is a guaranteed MISS and
    # self-heals by re-downloading. A mirror has no such self-healing to protect: on a hash-only
    # re-pin a stale mirrored artifact FAILS CLOSED loudly and tells the admin to refresh the
    # mirror, which is the outcome an operator wants over a silent substitution.
    param([ValidateSet('pses', 'pssa')][string]$Component, [string]$Version)
    if ($Component -eq 'pses') { return ('PowerShellEditorServices-' + $Version + '.zip') }
    return ('PSScriptAnalyzer-' + $Version + '.nupkg')
}

function Get-ArtifactSourceSettings {
    # The two configured layers, TOGETHER WITH whether each is configured -- the
    # Get-PluginDataRootResolution provenance shape, for the same reason: a caller that finds
    # nothing must be able to tell "no mirror is configured" from "the mirror had no such file".
    #
    # MirrorBase is accepted ONLY over https. The pin is the trust root, so a plaintext mirror
    # would not actually break integrity -- but the layer is specified as an HTTPS mirror, and
    # refusing an unexpected scheme is the fail-closed direction. A non-https value is reported
    # as configured-but-INVALID rather than silently ignored, so a typo surfaces as a named
    # banner instead of an inexplicable fall-through to the internet.
    $mirror = $env:POWERSHELL_LSP_ARTIFACT_MIRROR_BASE
    $bundle = $env:POWERSHELL_LSP_ARTIFACT_BUNDLE_DIR
    $mirrorSet = -not [string]::IsNullOrWhiteSpace($mirror)
    $bundleSet = -not [string]::IsNullOrWhiteSpace($bundle)
    $mirrorValid = $false
    $mirrorReason = ''
    if ($mirrorSet) {
        $mirror = $mirror.Trim().TrimEnd('/')
        if ($mirror -match '^https://') { $mirrorValid = $true }
        else { $mirrorReason = 'not an https:// URL' }
    }
    $bundleValid = $false
    $bundleReason = ''
    if ($bundleSet) {
        $bundle = $bundle.Trim()
        if (-not [System.IO.Path]::IsPathRooted($bundle)) { $bundleReason = 'not an absolute path' }
        elseif (-not (Test-Path -LiteralPath $bundle -PathType Container)) { $bundleReason = 'directory does not exist' }
        else { $bundleValid = $true }
    }
    return [pscustomobject]@{
        MirrorBase       = $(if ($mirrorSet) { $mirror } else { '' })
        MirrorConfigured = $mirrorSet
        MirrorValid      = $mirrorValid
        MirrorReason     = $mirrorReason
        BundleDir        = $(if ($bundleSet) { $bundle } else { '' })
        BundleConfigured = $bundleSet
        BundleValid      = $bundleValid
        BundleReason     = $bundleReason
        AnyConfigured    = ($mirrorSet -or $bundleSet)
    }
}

function Resolve-PinnedArtifactSource {
    # Try mirror, then bundle, placing the artifact at $Destination. Returns WHICH layer
    # produced it so the caller can name the layer in its log, its failure banner, and the
    # doctor's artifact-source check -- never a bare boolean, which would leave a reader unable
    # to say where the bytes came from.
    #
    # This function does NOT verify the pin. Verification stays in the caller, on the caller's
    # existing Test-PinnedFileHash line, precisely so there is exactly ONE gate per artifact
    # and no layer can acquire a second, weaker one. A $true Resolved here means only "bytes
    # were placed at $Destination", never "bytes were trusted".
    param([string]$FileName, [string]$Destination)

    $notes = @()
    $settings = Get-ArtifactSourceSettings

    if ($settings.MirrorConfigured -and -not $settings.MirrorValid) {
        $notes += ('mirror configured but unusable (' + $settings.MirrorReason + '); skipping layer')
    }
    if ($settings.BundleConfigured -and -not $settings.BundleValid) {
        $notes += ('bundle configured but unusable (' + $settings.BundleReason + '); skipping layer')
    }

    # LAYER 1 -- mirror. Same filenames as the bundle, over an internal HTTPS base URL.
    if ($settings.MirrorValid) {
        $url = $settings.MirrorBase + '/' + $FileName
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $url -OutFile $Destination -UseBasicParsing
            if (Test-Path -LiteralPath $Destination -PathType Leaf) {
                return [pscustomobject]@{ Layer = 'mirror'; Resolved = $true; Source = $url; Notes = $notes }
            }
            $notes += ('mirror fetch produced no file: ' + $url)
        } catch {
            # A MISS, not a tamper signal -- fall through to the next layer. An unreachable or
            # 404ing mirror must not strand a machine that also has a bundle or the internet.
            $notes += ('mirror miss (' + $_.Exception.Message + '): ' + $url)
        }
    }

    # LAYER 2 -- bundle. Pre-staged artifacts on local disk; the air-gapped path.
    if ($settings.BundleValid) {
        $staged = Join-Path $settings.BundleDir $FileName
        if (Test-Path -LiteralPath $staged -PathType Leaf) {
            try {
                Copy-Item -LiteralPath $staged -Destination $Destination -Force
                return [pscustomobject]@{ Layer = 'bundle'; Resolved = $true; Source = $staged; Notes = $notes }
            } catch {
                $notes += ('bundle copy failed (' + $_.Exception.Message + '): ' + $staged)
            }
        } else {
            $notes += ('bundle configured but artifact missing: ' + $staged)
        }
    }

    return [pscustomobject]@{ Layer = ''; Resolved = $false; Source = ''; Notes = $notes }
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

# --- the `profile` meta-knob (dispatch 000166) -----------------------------
# A profile is a PRESET over the other knobs, resolved BETWEEN an explicitly-set knob and
# the shipped default. Precedence, highest wins:
#
#     explicit knob value  >  profile mapping  >  shipped default
#
# The explicit-wins half is load-bearing on the 1.x contract: if a profile could override a
# value a user set, every existing 1.x config would silently change meaning on upgrade, which
# CONTRACT.md:178-184 makes a MAJOR. It resolves inside Get-PluginOption rather than at each
# call site so Get-PluginOptionInt / Get-PluginOptionBool (which both delegate here) inherit
# it, and so no caller can forget it.
#
# `safe` maps NOTHING. That is not an oversight -- it is the proof obligation: with the
# profile unset or `safe`, Get-PluginOption returns $Default on exactly the path it did
# before this knob existed, so the diagnostics surface is byte-for-byte unchanged BY
# CONSTRUCTION, not by a table that happens to restate the defaults correctly today.
#
# THREE VALUES ARE DELIBERATELY ABSENT FROM EVERY MAPPING, and each absence is a ruling:
#   * nativeServe  -- stays `off` in every profile (Mike Andersen ruling R2, 2026-07-30). The
#     shim works around an upstream client bug; a profile must not put a workaround in front
#     of more users.
#   * enableStats  -- stays `false` in every profile (ruling R3b). logs/stats.jsonl records
#     absolute paths today; redaction lands BEFORE any flip, as its own later dispatch.
#   * formatOnEdit=apply -- appears in NO profile. `apply` is the one mode that writes a
#     user's file, and it is deliberately doubly opt-in; `suggest` is as far as a preset goes.
# timeoutMs is absent for a measured reason rather than a ruling: the warm-path p95 under
# ruleset=base measured 2337 ms on the build host (n=20), leaving 53.3 pct headroom under the
# shipped 5000 ms, so per OQ2 the profiles keep 5000 and the cell is not a departure at all.
# That figure is the 000207 per-profile sweep, taken under a passing quiescence gate and
# recorded in docs/benchmarks.md -- which is the authority. Re-derive from that page rather
# than trusting this line.
# orgPolicy is absent because a profile cannot hardcode a site-specific path; `strict` names
# it as the intended slot and the operator supplies the value.
#
# EVOLUTION POLICY: these mappings are CURATED and MAY change in a MINOR. An explicitly-set
# knob is never affected by such a change, which is what makes a future re-mapping (including
# the later enableStats flip, once redaction ships) contractually clean rather than a semver
# argument.
#
# The map is a FUNCTION, not a top-level `$script:` assignment. This file is dot-sourced, and a
# dot-source executes every top-level statement in the CALLER's scope -- so a module-level variable
# here would silently write into every caller (the dispatch 000156 hazard class, structurally
# guarded by G1 in tests/PowerShellLsp.LibPurity.Tests.ps1). A function definition is the one
# top-level form that cannot leak. Returning the literal each call is deliberate over memoizing
# into `$script:` for the same reason.
function Get-PluginProfileMap {
    return @{
        'safe'        = @{}
        'recommended' = @{
            'editContextLines'   = '2'
            'formatOnEdit'       = 'suggest'
            'ruleset'            = 'base'
            'moduleAwareness'    = 'suggest'
            'referenceSurfacing' = 'counts'
        }
        'strict'      = @{
            # strict = recommended, plus the three enforcement-posture departures.
            # editContextLines rides along from recommended and is INERT here, because
            # scopeToEdit=false already reports whole-file.
            'editContextLines'   = '2'
            'formatOnEdit'       = 'suggest'
            'ruleset'            = 'base'
            'moduleAwareness'    = 'suggest'
            'referenceSurfacing' = 'counts'
            'keepLastN'          = '30'
            'perFileCap'         = '0'
            'scopeToEdit'        = 'false'
        }
    }
}

function Get-RawPluginOption {
    # The env-only read: the CLAUDE_PLUGIN_OPTION_<key> value, or '' if absent/blank. The
    # exported name's casing is normalized away (underscores stripped, lower-cased) so
    # 'ps_host' matches CLAUDE_PLUGIN_OPTION_PS_HOST / _ps_host / _psHost alike. Split out of
    # Get-PluginOption so the profile lookup can read the `profile` knob itself WITHOUT
    # recursing back through profile resolution.
    param([string]$Key)
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
    return ''
}

function ConvertTo-ProfileName {
    # Canonicalize the profile knob: 'safe' (default), 'recommended', 'strict'. Anything else
    # -- blank, an unexpanded '${user_config...}' token, a typo, a future value this build does
    # not know -- degrades to 'safe', which maps nothing. An unrecognized profile therefore
    # produces the SHIPPED defaults rather than a partial or guessed preset.
    param([string]$Value)
    $v = ([string]$Value).Trim().ToLowerInvariant()
    if ($v -eq 'recommended' -or $v -eq 'strict') { return $v }
    return 'safe'
}

function Get-ProfileKnobValue {
    # The profile's value for one knob, or '' when the profile does not map it (which is
    # every knob under 'safe'). Key matching is normalized the same way Get-RawPluginOption
    # normalizes the env name, so a caller's casing never silently misses a mapping.
    # NOTE: the parameter is $ProfileName, not $Profile -- $Profile is a PowerShell AUTOMATIC
    # variable (the profile-script path) and binding it is PSAvoidAssignmentToAutomaticVariable.
    # This plugin's own PostToolUse diagnostics flagged it while this function was being written.
    param([string]$ProfileName, [string]$Key)
    $p = ConvertTo-ProfileName $ProfileName
    $all = Get-PluginProfileMap
    if (-not $all.ContainsKey($p)) { return '' }
    $map = $all[$p]
    $target = ($Key -replace '_', '').ToLowerInvariant()
    foreach ($k in $map.Keys) {
        if ((([string]$k) -replace '_', '').ToLowerInvariant() -eq $target) { return [string]$map[$k] }
    }
    return ''
}

function Get-PluginOptionProvenance {
    # Resolve a knob AND say where the value came from (dispatch 000233).
    #
    # WHY THIS EXISTS. Configured state and effective state diverged silently inside the LSP
    # serve subprocess for the entire life of the `nativeServe` knob: a user could set it, the
    # shim would resolve `off`, and the only thing the log said was `nativeServe=off` -- which
    # is indistinguishable from "you never set it". A value without its provenance cannot tell
    # a user whether their configuration reached the process at all, which is exactly the
    # question that went unanswered. So the serve log and /doctor now report WHY, not just what.
    #
    # Returns a hashtable: Key, Value, Provenance ('env' | 'profile' | 'default'), and the
    # canonicalized ProfileName that was in force.
    #
    # THIS IS THE ONE RESOLVER. Get-PluginOption below is a thin projection of it, so the value
    # a caller acts on and the provenance a log reports can never disagree -- a second copy of
    # the precedence chain is precisely where that drift would live.
    param([string]$Key, [string]$Default = '')
    $profileRaw = Get-RawPluginOption 'profile'
    $profileName = ConvertTo-ProfileName $profileRaw
    $explicit = Get-RawPluginOption $Key
    if (-not [string]::IsNullOrWhiteSpace($explicit)) {
        return @{ Key = $Key; Value = $explicit; Provenance = 'env'; ProfileName = $profileName }
    }
    # `profile` itself is never profile-resolved -- that would recurse, and a preset cannot
    # sensibly select itself.
    if (($Key -replace '_', '').ToLowerInvariant() -ne 'profile') {
        $fromProfile = Get-ProfileKnobValue -ProfileName $profileRaw -Key $Key
        if (-not [string]::IsNullOrWhiteSpace($fromProfile)) {
            return @{ Key = $Key; Value = $fromProfile; Provenance = 'profile'; ProfileName = $profileName }
        }
    }
    return @{ Key = $Key; Value = $Default; Provenance = 'default'; ProfileName = $profileName }
}

function Get-PluginOption {
    # Resolve a knob: explicit CLAUDE_PLUGIN_OPTION_<key> value > the active profile's
    # mapping > $Default. See the precedence note above Get-RawPluginOption.
    # Delegates to Get-PluginOptionProvenance so exactly one precedence chain exists.
    param([string]$Key, [string]$Default = '')
    return (Get-PluginOptionProvenance -Key $Key -Default $Default).Value
}

function Format-PluginOptionProvenance {
    # One human-readable line for a resolved knob, for the serve log and /doctor.
    # It must say WHY, not merely report a value -- including in the DEFAULT case, which is
    # the case that used to be indistinguishable from a knob that never arrived at all.
    param($Resolved)
    if ($null -eq $Resolved) { return 'unresolved' }
    $v = [string]$Resolved.Value
    if ([string]::IsNullOrWhiteSpace($v)) { $v = '(empty)' }
    switch ([string]$Resolved.Provenance) {
        'env' {
            return ([string]$Resolved.Key + '=' + $v + ' -- provenance: env (the configured value reached this process through the server env block)')
        }
        'profile' {
            return ([string]$Resolved.Key + '=' + $v + " -- provenance: profile '" + [string]$Resolved.ProfileName + "' (the knob itself is unset here)")
        }
        default {
            return ([string]$Resolved.Key + '=' + $v + " -- provenance: default (nothing configured reached this process, and profile '" + [string]$Resolved.ProfileName + "' does not map this knob)")
        }
    }
}

function Get-ServeTransportSuspension {
    # The knobs whose ${user_config.*} transport into the LSP serve subprocess is SUSPENDED,
    # and the exact condition that lifts each one (dispatch 000241).
    #
    # WHAT THIS IS NOT. It is not a retreat from dispatch 000233. That ruling -- the server's
    # own `env` block is the supported transport for a knob the serve subprocess reads -- stands,
    # is proven end-to-end against a real marketplace install, and remains the intended
    # architecture. What is suspended is the USE of that transport on a Claude Code whose
    # implementation of it is defective; the design is untouched.
    #
    # THE GATE. On Claude Code 2.1.233 the LSP loader interpolates ${user_config.<key>} against
    # the user's STORED options only. The sibling MCP path merges the schema defaults first; the
    # LSP path does not, so a declared `default` is meaningful for one server type and inert for
    # the other. A key the user never explicitly typed is undefined, the interpolator THROWS, and
    # the per-plugin catch discards EVERY server the plugin declares -- not just the entry that
    # referenced the key. One mapping is therefore enough to break a zero-configuration install,
    # which is why no "safe subset" of mappings exists and all three are suspended together.
    #
    # The /plugin configuration panel does not rescue this. Its fields are seeded from the same
    # defaults-free reader (so an unset knob shows EMPTY, never its declared default), and its
    # submit reducer SKIPS a blank non-required key whose stored value is undefined -- so opening
    # the panel and pressing Save writes nothing at all. The user must type each value by hand.
    #
    # RESTORATION IS MECHANICAL, BY CONSTRUCTION. Each record below carries the exact env name
    # and the exact mapping value that was removed. Lifting the gate is: add
    # "<EnvName>": "<Mapping>" back to lspServers.powershell.env for each record, then delete
    # the record. Nothing else was changed, and nothing has to be remembered or re-derived --
    # tests/PowerShellLsp.LspServerLoadability.Tests.ps1 asserts each record still describes a
    # mapping that would genuinely restore that knob's transport.
    #
    # Full root cause, the decompiled call sites, and the upstream report:
    # docs/upstream/claude-code-lspservers-userconfig-defaults.md
    $gate = 'claude-code-lspservers-userconfig-defaults'
    $affected = '2.1.233'
    $lifts = 'Claude Code merges the plugin userConfig schema defaults into the option map it ' +
             'interpolates lspServers against (the sibling MCP path already does). VERIFY BY ' +
             'MEASUREMENT, not by release notes -- upstream fixes in this area have shipped ' +
             'undocumented before: install the plugin with NO stored options for these keys and ' +
             'confirm the LSP server registers with no "Plugin option ... isn''t set" error.'
    $reference = 'docs/upstream/claude-code-lspservers-userconfig-defaults.md'
    $records = @(
        @{ Key = 'profile';     EnvName = 'CLAUDE_PLUGIN_OPTION_PROFILE';     Mapping = '${user_config.profile}' }
        @{ Key = 'ps_host';     EnvName = 'CLAUDE_PLUGIN_OPTION_PS_HOST';     Mapping = '${user_config.ps_host}' }
        @{ Key = 'nativeServe'; EnvName = 'CLAUDE_PLUGIN_OPTION_NATIVESERVE'; Mapping = '${user_config.nativeServe}' }
    )
    foreach ($r in $records) {
        $r['Gate'] = $gate
        $r['AffectedVersion'] = $affected
        $r['LiftsWhen'] = $lifts
        $r['Reference'] = $reference
    }
    # NOT comma-wrapped. `return , @($records)` emits the wrapper, which unrolls to the INNER
    # array as a single pipeline item -- so `@(Get-ServeTransportSuspension)` collects one
    # element (the whole array) and every `foreach` over it runs exactly once, with $_.Key
    # member-enumerating into 'profile ps_host nativeServe'. The comma idiom protects a
    # ONE-element result from unrolling to a scalar; here every caller wraps in @() already,
    # which handles the empty and single cases correctly on its own.
    return @($records)
}

function Test-ServeTransportSuspended {
    # Is this knob's transport suspended by the upstream gate? Key matching is normalized the
    # same way Get-RawPluginOption normalizes the env name, so a caller's casing never silently
    # misses a record.
    param([string]$Key)
    $target = ([string]$Key -replace '_', '').ToLowerInvariant()
    foreach ($r in (Get-ServeTransportSuspension)) {
        if ((([string]$r.Key) -replace '_', '').ToLowerInvariant() -eq $target) { return $true }
    }
    return $false
}

function Get-ServeTransportGateNotice {
    # The one line the serve subprocess logs beside its provenance lines.
    #
    # WHY IT IS MANDATORY. Inside this subprocess a suspended knob resolves with
    # `provenance: default` -- and that phrase makes a claim about the USER ("nothing you
    # configured reached this process"), which under the gate is the wrong claim. The subprocess
    # cannot see what the user configured, so it cannot report the fork; what it CAN do is stop
    # implying a user cause and state the system one. Reporting the bare default here is exactly
    # the silent divergence dispatch 000233 was raised to kill, so it is not an option.
    # /doctor runs hook-adjacent, DOES receive CLAUDE_PLUGIN_OPTION_*, and is where both
    # branches of the fork are distinguishable.
    $records = @(Get-ServeTransportSuspension)
    if ($records.Count -eq 0) { return '' }
    $keys = (@($records | ForEach-Object { [string]$_.Key }) -join ', ')
    $first = $records[0]
    return ('serve transport SUSPENDED BY UPSTREAM GATE (' + [string]$first.Gate + '): no userConfig ' +
        'can reach this subprocess on Claude Code ' + [string]$first.AffectedVersion + ', so the SHIPPED ' +
        'DEFAULTS below are in effect for ' + $keys + ' REGARDLESS of what is configured -- a "provenance: ' +
        'default" line for these knobs states the transport, NOT that the knob was left unset. ' +
        'nativeServe=shim in particular cannot take effect while this gate holds. See ' + [string]$first.Reference)
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
# and letting PSES READ it (we never EXECUTE the user's .psd1 -- it is PowerShell
# data, an arbitrary-code risk; PSES is the trusted consumer). The resolver below only
# resolves the path. Since dispatch 000306 the daemon also reads the file it resolved
# as DATA -- Read-PssaSettingsFile: parsed, never run, nothing evaluated but constants --
# to check PSScriptAnalyzer will accept it before PSES is handed it.
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

# --- org policy layer (E2.2, dispatch 000142) ------------------------------
# The OUTERMOST, centrally-managed voice -- the one layer ABOVE the repo-local settings
# file the precedence chain above resolves. An organization points the `orgPolicy` knob at
# a settings .psd1 on a share; its ExcludeRules are ENFORCED, applied client-side as a FINAL
# subtractive drop over the surfaced findings, AFTER every local include. So a rule the org
# excludes can never be re-enabled by a repo-local PSScriptAnalyzerSettings.psd1 or by the
# `ruleInclude` knob. The org's own IncludeRules stay ADVISORY (repo-local wins the include
# path): an org can take a rule away, it cannot force one on. That include/exclude asymmetry
# IS the design (dispatch 000135, decision 1) -- not an omission.
#
# Client-side by construction (dispatch 000135, the same decision record): the daemon, its
# launch, and its session-start threading are structurally untouched, and every branch is
# gated on the knob being set -- so with `orgPolicy` unset the surfaced bytes are identical
# to the pre-layer build.

function Get-SeverityNames {
    # THE severity vocabulary, in rank order, as ONE source (Hub Rule 18). Resolve-SeverityName
    # canonicalises against this list, and a unit test asserts that every member of it ranks
    # BELOW Get-SeverityRank's junk default while a non-member does not -- so this list and that
    # ranking function cannot drift apart silently. Deriving the set and asserting the partition
    # is non-empty is the same discipline the census rule asks for, applied to a vocabulary.
    return @('Error', 'Warning', 'Information', 'Hint')
}

function Resolve-SeverityName {
    # Canonical casing for a caller-supplied severity name, or '' when it names none of them.
    #
    # CANONICALISE, never normalise. Lowercasing or upper-casing a severity name happens to work
    # for a vocabulary whose members are all single-cased, and stops working the moment one is
    # not -- which is exactly how 'documentSymbol' broke ToLowerInvariant in dispatch 000288. A
    # name that is not in the vocabulary is a MALFORMED expectation and returns '', so the caller
    # can skip it rather than enforce a level nothing can rank.
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    $n = $Name.Trim()
    foreach ($s in (Get-SeverityNames)) {
        if ([string]::Equals($s, $n, [System.StringComparison]::OrdinalIgnoreCase)) { return $s }
    }
    return ''
}

function New-EmptyOrgPolicy {
    # The knob-off / no-constraint policy value. Named rather than repeated so that "no org
    # constraint" is ONE value with ONE shape, and a caller can never accidentally construct a
    # half-empty one.
    #
    # RequiredRules / ProhibitedSuppressions (P1-5 remainder, R23=D, dispatch 000294): the two
    # members added beside ExcludeRules / SeverityOverrides. Both empty by construction, which is
    # what keeps every knob-off and v1/v2-no-key surface byte-identical to pre-000294.
    return @{ ExcludeRules = @(); SeverityOverrides = @{}; RequiredRules = @(); ProhibitedSuppressions = @() }
}

function Test-OrgPolicyIntegrity {
    # The org policy INTEGRITY gate (dispatch 000259, threat T4.1). Returns '' when the policy
    # at $PolicyPath may be trusted -- either because no integrity artifact sits beside it (the
    # gate is OPT-IN, and absent means "exactly as before"), or because one does and the file
    # hashes to it. Returns a degrade REASON otherwise, and the caller then applies NO
    # exclusions and logs that reason exactly once, like every other orgPolicy degrade.
    #
    # WHY THIS EXISTS: orgPolicy is the outermost precedence layer and its ExcludeRules are a
    # final subtractive drop no local setting can re-add, so whoever can WRITE that file
    # controls what the analyzer enforces fleet-wide. Reading it with no integrity check makes
    # write access to a share equal to control over enforcement.
    #
    # The artifact is DISCOVERED FROM THE POLICY PATH, never configured: '<policy>.sha256'
    # beside the policy file. That discovery is what keeps this slice at ZERO freeze exposure --
    # it adds no userConfig key, so the .strict() manifest schema is untouched.
    #
    # Accepts a bare 64-character hex digest or the 'sha256sum' shape ('<hash> *<name>'): the
    # first stand-alone 64-hex token wins. The boundary guards matter -- without them a 65-char
    # run of hex would silently match on its first 64 characters, which is a malformed
    # expectation reported as a satisfied one.
    #
    # A malformed or unreadable sidecar DEGRADES rather than passing. An unsatisfiable
    # expectation is not an absent one: a gate that waves through what it cannot check is not a
    # gate. Absence is the ONLY thing that means "no gate," and absence is unambiguous.
    #
    # Adversarial control: return '' on a mismatch and 'a TAMPERED policy applies no exclusions'
    # goes RED; treat a malformed sidecar as absent and 'an unsatisfiable expectation degrades'
    # goes RED; drop the boundary guards and 'a 65-hex-char digest is malformed' goes RED.
    #
    # $CodeOut (dispatch 000305, B1) receives the FIXED reason code beside the prose, set at the
    # same site that writes the prose, so a caller that must branch on the cause (the managed scan)
    # never string-matches this function's wording. Optional; every existing caller omits it.
    param([string]$PolicyPath, [ref]$CodeOut)
    $sidecar = $PolicyPath + '.sha256'
    if (-not (Test-Path -LiteralPath $sidecar -PathType Leaf)) { return '' }
    $raw = ''
    try {
        $raw = [string](Get-Content -LiteralPath $sidecar -Raw -ErrorAction Stop)
    } catch {
        if ($null -ne $CodeOut) { $CodeOut.Value = 'policy-integrity-unreadable' }
        return 'orgPolicy integrity file could not be read; no org exclusions applied: ' + $sidecar
    }
    $m = [regex]::Match($raw, '(?<![0-9A-Fa-f])[0-9A-Fa-f]{64}(?![0-9A-Fa-f])')
    if (-not $m.Success) {
        if ($null -ne $CodeOut) { $CodeOut.Value = 'policy-integrity-malformed' }
        return 'orgPolicy integrity file declares no SHA-256 digest; no org exclusions ' +
            'applied: ' + $sidecar
    }
    if (Test-PinnedFileHash -Path $PolicyPath -ExpectedSha256 $m.Value) { return '' }
    if ($null -ne $CodeOut) { $CodeOut.Value = 'policy-integrity-mismatch' }
    return 'orgPolicy integrity check FAILED; no org exclusions applied: ' + $PolicyPath
}

function Test-OrgPolicyRuleCode {
    # Is one org-policy rule-code entry, AS WRITTEN (before it is trimmed), well formed? $true when it
    # is a RULE NAME -- one or more ASCII letters, digits, '_', '-', '.' or '\' -- or blank (empty or
    # ASCII whitespace only: no rule, skipped by Import-OrgPolicy exactly as before), padded only by
    # ASCII whitespace; $false for anything else, which Import-OrgPolicy then refuses through its
    # corrupt-policy degrade (policy-unreadable). Refused, never escaped: such a string names no rule
    # any enforcement point can match (dispatch 000305, B1, review finding B1-R01).
    #
    # WHY THIS SET. It holds every rule name a finding can carry: PSScriptAnalyzer's own rules
    # (PSAvoidGlobalVars), this plugin's (ProhibitedSuppression), and a custom rule, which reports itself
    # as '<module>\<function>' -- measured with PSScriptAnalyzer 1.25.0 on pwsh 7.6.6 and Windows
    # PowerShell 5.1: 'My.Rules\Measure-NoFoo'. And it is what keeps the policy identity
    # (ConvertTo-EffectivePolicyText, lsp-policy.ps1) injective and host-independent: no code can carry
    # the TAB or LF that separate the canonical text's fields and lines, and every code is ASCII, so
    # folding A-Z alone is exactly the OrdinalIgnoreCase match every enforcement point uses, on every
    # host. The entry is checked BEFORE it is trimmed and may be padded only by ASCII whitespace, so
    # String.Trim's idea of Unicode whitespace never decides which code a policy names.
    #
    # [regex]::IsMatch with no options, never -match: -match ignores case, and then [A-Z] admits
    # U+212A KELVIN SIGN (measured on both hosts); with no options [A-Za-z] is exactly 52 code points.
    # \z, not $, so a trailing LF is never forgiven.
    param($Entry)
    if ($Entry -isnot [string]) { return $false }
    return [regex]::IsMatch($Entry, '\A[\t\n\v\f\r ]*(?:[A-Za-z0-9_.\\-]+[\t\n\v\f\r ]*)?\z')
}

function Format-OrgPolicyRuleCodeError {
    # The reason Import-OrgPolicy refuses a policy whose $Member holds $Entry, an entry
    # Test-OrgPolicyRuleCode rejects. The entry is shown with every character outside printable ASCII
    # replaced by '?' and cut at 80, so the one warning a degrade writes stays one ASCII line.
    param([string]$Member, [string]$Entry)
    $shown = -join @($Entry.ToCharArray() | ForEach-Object { if ([int]$_ -ge 0x20 -and [int]$_ -le 0x7E) { [string]$_ } else { '?' } })
    if ($shown.Length -gt 80) { $shown = $shown.Substring(0, 80) + '...' }
    return ($Member + " names '" + $shown + "', which is not a rule name (a rule code may hold only " +
        "ASCII letters, digits, '_', '-', '.' and '\')")
}

function Import-OrgPolicy {
    # Read the ExcludeRules of the org settings .psd1 at $Path as a trimmed, de-duplicated
    # string[] of rule codes. @() means "no org constraint" -- and @() is also the answer for
    # EVERY failure: relative path, missing file, unreadable file, unparseable data, a shape
    # that carries no rule list, (dispatch 000259) a FAILED integrity gate, or (dispatch 000305)
    # a rule code that is not a rule name.
    #
    # FAIL-OPEN is the load-bearing invariant: an org policy that cannot be read must never
    # break the user's edit (the hook never fails). But a policy that silently stops enforcing
    # is its own hazard, so every degrade sets $WarningOut ONCE to a human-readable reason and
    # the caller logs it. Two cases are deliberately NOT degrades and set no warning: an empty
    # $Path (the knob is off), and a readable policy that simply declares no ExcludeRules (a
    # valid no-op policy).
    #
    # Parsed with Import-PowerShellDataFile, which evaluates the file in PowerShell's
    # RESTRICTED language mode -- data only, no command invocation, no expressions. That is
    # why the client may read THIS .psd1 itself where Resolve-PssaSettingsPath deliberately
    # does not: that path hands its file to PSES to consume as full settings, whereas this one
    # only lifts a string array out through the data-only parser. Same idiom as the shipped
    # Import-RuleRationales. Verified present with -LiteralPath on BOTH hosts (Windows
    # PowerShell 5.1 and PowerShell 7); the 7-only -SkipLimitCheck is deliberately not used.
    #
    # ABSOLUTE only, mirroring settingsPath (dispatch 000018): a relative org path would
    # resolve against the hook process's current directory -- whatever folder Claude Code
    # happened to launch in -- which is not a stable org-wide location. Unlike settingsPath
    # (which is silently ignored) a relative org path IS a warned degrade: silence is exactly
    # the failure mode an enforcement layer cannot afford.
    #
    # INTEGRITY (dispatch 000259, threat T4.1): when a '<policy>.sha256' artifact sits beside
    # the policy, the file must hash to it before ANY exclusion is lifted -- see
    # Test-OrgPolicyIntegrity. A failed gate is just another degrade and travels the same
    # fail-open-but-never-silent road as the cases above: @() plus exactly ONE warning. With no
    # artifact present nothing is checked and the behavior is byte-for-byte pre-gate, so this
    # is opt-in and adds no userConfig key.
    #
    # Adversarial control: drop the [string] type test and 'ignores non-string entries' goes
    # RED; drop the try/catch and 'an unparseable policy degrades without throwing' goes RED;
    # accept a relative path and 'a relative path is a warned degrade' goes RED; parse the
    # policy regardless of $reason and 'a TAMPERED policy applies no exclusions' goes RED;
    # drop the rule-code checks and 'A RULE CODE MUST BE A RULE NAME' goes RED.
    #
    # A RULE CODE MUST BE A RULE NAME (dispatch 000305, B1, review finding B1-R01). A string entry in
    # any of the four members -- or a SeverityOverrides key -- that Test-OrgPolicyRuleCode rejects (a
    # TAB or line end inside it, any character outside ASCII letters, digits and '_', '-', '.', '\')
    # makes the whole policy unreadable: thrown inside the try below, so it is the same corrupt-policy
    # degrade as unparseable data -- @() for every member, policy-unreadable, ONE warning. Before this,
    # such a string was kept as a code: it matched nothing, yet one carrying a TAB and LF rendered,
    # in the policy identity's canonical text, as the lines of a different policy.
    #
    # $ReasonOut (dispatch 000305, B1) receives a FIXED code for the same degrade the prose names --
    # policy-path-relative, policy-file-missing, policy-integrity-unreadable / -malformed /
    # -mismatch, policy-unreadable -- set where the prose is set, so the managed scan can state the
    # cause without string-matching the wording above. '' whenever $WarningOut is ''. Optional.
    #
    # THE PARSE FAILURE NO LONGER DEPENDS ON THE CALLER (dispatch 000305, measured on pwsh 7.6.6 and
    # Windows PowerShell 5.1.26100). Import-PowerShellDataFile reports an unparseable, empty or
    # non-hashtable file as a NON-terminating error. Under a caller whose $ErrorActionPreference is
    # Stop that becomes the catch below; under Continue it was printed and $data came back $null --
    # and a corrupt policy read as a valid, EMPTY one, with no warning at all. -ErrorAction Stop makes
    # the degrade the same for every caller; under Stop callers (every shipped entry point) nothing
    # changes.
    param([string]$Path, [ref]$WarningOut, [ref]$ReasonOut)
    if ([string]::IsNullOrWhiteSpace($Path)) { return (New-EmptyOrgPolicy) }
    $reason = ''
    $code = ''
    $codes = @()
    $sev = @{}
    $req = @()
    $prohib = @()
    try {
        if (-not [System.IO.Path]::IsPathRooted($Path)) {
            $reason = 'orgPolicy path is not absolute; no org exclusions applied: ' + $Path
            $code = 'policy-path-relative'
        } else {
            $full = [System.IO.Path]::GetFullPath($Path)
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
                $reason = 'orgPolicy file not found; no org exclusions applied: ' + $full
                $code = 'policy-file-missing'
            } else {
                # Integrity gate (dispatch 000259) -- evaluated BEFORE the policy is parsed and
                # before any exclusion is lifted, so an unverified policy never reaches the
                # filter. With no '<policy>.sha256' beside the file this returns '' and the
                # read below is byte-for-byte the pre-gate path; the gate is pure opt-in.
                $reason = Test-OrgPolicyIntegrity -PolicyPath $full -CodeOut ([ref]$code)
            }
            if ($reason -eq '') {
                $data = Import-PowerShellDataFile -LiteralPath $full -ErrorAction Stop
                if ($null -ne $data -and $data.ContainsKey('ExcludeRules')) {
                    $seen = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
                    foreach ($entry in @($data['ExcludeRules'])) {
                        # A rule code is a STRING. A nested table or a number in the list is
                        # malformed policy, not a rule -- skip it rather than stringify it into
                        # a code that can never match (or, worse, one that matches nothing while
                        # looking like enforcement).
                        if ($entry -isnot [string]) { continue }
                        if (-not (Test-OrgPolicyRuleCode $entry)) { throw (Format-OrgPolicyRuleCodeError -Member 'ExcludeRules' -Entry $entry) }
                        $c = $entry.Trim()
                        if ([string]::IsNullOrWhiteSpace($c)) { continue }
                        if ($seen.Add($c)) { $codes += $c }
                    }
                }
                # POLICY v2 (dispatch 000289, ruling R9): the INCLUDE-SIDE payload, read from
                # the SAME parse, behind the SAME integrity gate, reported through the SAME
                # single warning. One read, one gate, one degrade -- Hub Rule 18. A v1 policy
                # carries no SeverityOverrides key and this block leaves $sev empty, which is
                # what keeps a v1 file byte-identical in behaviour to the pre-v2 build.
                if ($null -ne $data -and $data.ContainsKey('SeverityOverrides')) {
                    $table = $data['SeverityOverrides']
                    # The value must be a dictionary. A list or a scalar here is malformed
                    # policy, not an override set -- skipped, exactly as a non-string rule code
                    # is skipped above, rather than coerced into something that looks enforced.
                    if ($table -is [System.Collections.IDictionary]) {
                        foreach ($k in @($table.Keys)) {
                            if ($k -isnot [string]) { continue }
                            if (-not (Test-OrgPolicyRuleCode $k)) { throw (Format-OrgPolicyRuleCodeError -Member 'SeverityOverrides' -Entry $k) }
                            $rule = ([string]$k).Trim()
                            if ([string]::IsNullOrWhiteSpace($rule)) { continue }
                            $v = $table[$k]
                            if ($v -isnot [string]) { continue }
                            # Canonicalise against the vocabulary rather than lowercasing or
                            # accepting what we are handed: an unknown severity name is a
                            # malformed expectation, and an override that names a level the
                            # renderer cannot rank would surface as the junk default. This is
                            # the ToLowerInvariant lesson from 000288, applied rather than
                            # recalled.
                            $canon = Resolve-SeverityName ([string]$v)
                            if ($canon -eq '') { continue }
                            if (-not $sev.ContainsKey($rule)) { $sev[$rule] = $canon }
                        }
                    }
                }
                # POLICY v2 REMAINDER (P1-5, R23=D, dispatch 000294): RequiredRules and
                # ProhibitedSuppressions, read from the SAME parse, behind the SAME integrity
                # gate, into the SAME single warning -- Hub Rule 18, the identical pattern
                # SeverityOverrides established beside ExcludeRules. A v1 or v2-pre-000294
                # policy carries neither key and these two blocks leave $req / $prohib empty,
                # which is what keeps that policy's behaviour byte-identical to pre-000294.
                if ($null -ne $data -and $data.ContainsKey('RequiredRules')) {
                    $seenReq = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
                    foreach ($entry in @($data['RequiredRules'])) {
                        if ($entry -isnot [string]) { continue }
                        if (-not (Test-OrgPolicyRuleCode $entry)) { throw (Format-OrgPolicyRuleCodeError -Member 'RequiredRules' -Entry $entry) }
                        $c = $entry.Trim()
                        if ([string]::IsNullOrWhiteSpace($c)) { continue }
                        if ($seenReq.Add($c)) { $req += $c }
                    }
                }
                if ($null -ne $data -and $data.ContainsKey('ProhibitedSuppressions')) {
                    $seenProhib = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
                    foreach ($entry in @($data['ProhibitedSuppressions'])) {
                        if ($entry -isnot [string]) { continue }
                        if (-not (Test-OrgPolicyRuleCode $entry)) { throw (Format-OrgPolicyRuleCodeError -Member 'ProhibitedSuppressions' -Entry $entry) }
                        $c = $entry.Trim()
                        if ([string]::IsNullOrWhiteSpace($c)) { continue }
                        if ($seenProhib.Add($c)) { $prohib += $c }
                    }
                }
            }
        }
    } catch {
        $reason = 'orgPolicy could not be read; no org exclusions applied: ' + $_.Exception.Message
        $code = 'policy-unreadable'
        $codes = @()
        $sev = @{}
        $req = @()
        $prohib = @()
    }
    if ($reason -ne '' -and $null -ne $WarningOut) { $WarningOut.Value = $reason }
    if ($reason -ne '' -and $null -ne $ReasonOut) { $ReasonOut.Value = $(if ($code -ne '') { $code } else { 'policy-unreadable' }) }
    return @{ ExcludeRules = @($codes); SeverityOverrides = $sev; RequiredRules = @($req); ProhibitedSuppressions = @($prohib) }
}

function Import-OrgPolicyExcludes {
    # The v1 reader, preserved EXACTLY as its callers know it: a trimmed, de-duplicated
    # string[] of excluded rule codes, @() for every failure, one warning on a degrade. It is
    # now a projection of Import-OrgPolicy rather than a second reader, so the integrity gate,
    # the absolute-path rule and the degrade vocabulary cannot drift between the two halves of
    # the payload (Hub Rule 18). Every existing caller -- lsp-client.ps1 and doctor.ps1 -- and
    # every existing test keeps calling this and sees no change.
    param([string]$Path, [ref]$WarningOut)
    $pol = if ($null -eq $WarningOut) { Import-OrgPolicy -Path $Path }
           else { Import-OrgPolicy -Path $Path -WarningOut $WarningOut }
    return @($pol.ExcludeRules)
}

function Get-OrgPolicyReportInfo {
    # The fleet-visible identity of the org policy that is (or is not) active on this host --
    # "which exact policy was active on this device" -- for the doctor -Json envelope (dispatch
    # 000299, W3-2). Same additive-field discipline as Get-DiagnosticCaptureModeInfo /
    # Get-OtelEndpointReportInfo above: doctor.ps1 wires this in as a new key and nothing
    # existing moves, so schemaVersion does not bump.
    #
    # NO SECOND VERIFIER (Hub Rule 18). `applied` is read straight off Import-OrgPolicyExcludes
    # -- the SAME shipped reader lsp-client.ps1 calls to decide what actually filters a live
    # edit -- and `sidecarMatch` is read straight off Test-OrgPolicyIntegrity -- the SAME
    # shipped integrity gate that reader calls internally (dispatch 000259). Neither verdict is
    # re-derived here; a second, independently-computed opinion could disagree with the one
    # that really governs an edit and would then report confidently while being wrong. The one
    # thing this function adds that neither shipped function surfaces on its own is a bare
    # `Test-Path` on the discovered '<policy>.sha256' location -- needed only to tell "no
    # sidecar next to the policy" apart from "a sidecar is there and satisfied", since
    # Test-OrgPolicyIntegrity returns '' for both. That is an existence check, not a hash
    # computed a second way.
    #
    #   path         the orgPolicy knob value verbatim, '' when unset.
    #   sha256       SHA-256 of the policy file AS READ (Get-FileHash, the one hashing
    #                primitive this codebase uses for a pinned artifact -- see
    #                Test-PinnedFileHash above), '' when there is no file to hash.
    #   sidecarMatch 'not-present' when no '<policy>.sha256' sits beside the file (the gate is
    #                opt-in -- this is the common case and is NOT a degrade); 'match' when one
    #                exists and Test-OrgPolicyIntegrity is satisfied; 'mismatch' for every other
    #                outcome that function has (an unreadable sidecar, one with no parseable
    #                digest, or a digest that does not hash-match). The shipped gate does not
    #                distinguish those three from each other either -- it fails the same way,
    #                fail-open, for all of them -- so this field does not invent a distinction
    #                the reader it reports on does not make.
    #   applied      whether exclusions from this policy actually govern a live edit right now:
    #                $false with no policy configured (nothing to apply), $false on ANY read
    #                degrade (relative path, missing file, unreadable/unparseable data, or a
    #                failed integrity gate -- Import-OrgPolicyExcludes's own $WarningOut is
    #                non-empty on every one of those, and empty only when it is genuinely
    #                enforcing, whether or not it declares any rule), $true otherwise.
    #
    # HONEST ON "NO POLICY", NOT ABSENT OR EMPTY-STRINGED (W3-2 acceptance). All four keys are
    # always present on every return, so a consumer never has to tell "the field is missing"
    # apart from "the field is blank": 'not-present' / $false / '' are the explicit, honest
    # values for "no policy governs this host" rather than a bare blank path left to imply it.
    $path = [string](Get-PluginOption 'orgPolicy' '')
    $info = [ordered]@{ path = $path; sha256 = ''; sidecarMatch = 'not-present'; applied = $false }
    if ([string]::IsNullOrWhiteSpace($path)) { return $info }

    $warning = ''
    [void]@(Import-OrgPolicyExcludes -Path $path -WarningOut ([ref]$warning))
    $info.applied = [string]::IsNullOrWhiteSpace($warning)

    if (-not [System.IO.Path]::IsPathRooted($path)) { return $info }
    $full = ''
    try { $full = [System.IO.Path]::GetFullPath($path) } catch { return $info }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return $info }

    try { $info.sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $full -ErrorAction Stop).Hash } catch { $info.sha256 = '' }

    $sidecar = $full + '.sha256'
    if (Test-Path -LiteralPath $sidecar -PathType Leaf) {
        $reason = Test-OrgPolicyIntegrity -PolicyPath $full
        $info.sidecarMatch = if ($reason -eq '') { 'match' } else { 'mismatch' }
    }
    return $info
}

function Get-DiagnosticRuleCode {
    # The rule code of ONE diagnostic record, across every shape the client's stream carries.
    # This exists because Get-Prop alone is NOT sufficient here: it resolves via
    # $Object.PSObject.Properties, which sees the members of a [pscustomobject] (the JSON-parsed
    # daemon records and the pre-PSSA findings) but NOT the keys of a [hashtable] or the
    # [ordered] hashtable that ConvertTo-DiagRecord itself returns -- for those it returns $null.
    # A $null code reads as "no code", and a record with no code is never dropped, so relying on
    # Get-Prop alone would make an org exclusion SILENTLY stop enforcing the moment a record
    # arrived as a dictionary. Silent non-enforcement is the one failure an enforcement layer
    # cannot have, so dictionaries are resolved by key first and PSObjects second.
    #
    # Falls back to 'ruleId' -- the field name the pre-PSSA finders and the corpus derivation
    # use -- so a record that carries only that name is still matchable. Returns '' when the
    # record names no rule at all (a parser error).
    #
    # Adversarial control: delete the IDictionary branch and 'drops a rule delivered as an
    # ordered hashtable' goes RED; delete the ruleId fallback and 'matches on ruleId' goes RED.
    param($Record)
    if ($null -eq $Record) { return '' }
    foreach ($name in @('code', 'ruleId')) {
        if ($Record -is [System.Collections.IDictionary]) {
            if ($Record.Contains($name)) {
                $v = [string]$Record[$name]
                if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
            }
        } else {
            $v = [string](Get-Prop $Record $name)
            if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
        }
    }
    return ''
}

function Select-OrgPolicyFiltered {
    # THE FINAL SUBTRACTIVE DROP: remove every record whose rule code the org policy excludes.
    # Pure, order-preserving, and deliberately NOT severity- or include-aware -- it runs AFTER
    # every other filter, so anything a local include (a repo-local settings file or the
    # `ruleInclude` knob) put on the surface is still subject to it, and no code path can
    # re-add a dropped record. That ordering IS the "org wins for excludes" semantic.
    #
    # An empty $OrgExclude makes this the IDENTITY function -- that is what makes the knob-off
    # surface byte-identical. Matching is on the record's rule code via Get-DiagnosticRuleCode,
    # which handles every shape the client's stream mixes (PSCustomObject daemon records from
    # JSON, the pre-PSSA finding shape, and dictionary records). A record with NO code (a parser
    # error) is never dropped: an org rule list names PSScriptAnalyzer rules, and a syntax error
    # is not a rule. Comparison is case-insensitive, as PSScriptAnalyzer's own matching is.
    #
    # Adversarial control: make the comparison ordinal-case-sensitive and 'matches a rule code
    # case-insensitively' goes RED; drop the no-code passthrough and 'never drops a record that
    # carries no code' goes RED; return $Records unconditionally and the precedence matrix goes RED.
    param([object[]]$Records, [string[]]$OrgExclude = @())
    if ($null -eq $Records) { return @() }
    $exc = @($OrgExclude | Where-Object { $_ })
    if ($exc.Count -eq 0) { return @($Records) }
    $set = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($e in $exc) { [void]$set.Add(([string]$e).Trim()) }
    $out = @()
    foreach ($r in $Records) {
        $code = Get-DiagnosticRuleCode $r
        if (-not [string]::IsNullOrWhiteSpace($code) -and $set.Contains($code)) { continue }
        $out += $r
    }
    return @($out)
}

# --- requiredRules (P1-5 remainder, R23=D member, dispatch 000294) ---------
# The include-side member the settings CHANNEL can carry (000292-PHASE-RECORDS.md): unlike
# prohibitedSuppressions, PSSA's settings object DOES have an IncludeRules property, so a
# required rule can be forced on by writing PSES a settings file that names it -- but ONLY if
# the merged file also preserves every rule PSES would otherwise have run. A settings file with
# NO IncludeRules key runs every INSTALLED PSSA rule (PSSA's own default), which is a much wider
# surface than PSES's own curated no-settings default -- so with NO settings file the merge must pin
# that default explicitly rather than merely appending to whatever IncludeRules already existed. The
# same fact cuts the other way when the repository's own settings file names no IncludeRules: PSES
# then runs every enabled rule, and pinning its default would narrow that -- so there the merge writes
# no IncludeRules at all (owner ruling R03, dispatch 000306; Merge-RequiredRulesSettings).

function Get-PssaDefaultRuleNames {
    # PSES's OWN no-settings default rule set -- read from the PINNED PSES v4.6.0 source
    # (AnalysisService.cs, s_defaultRules), never recalled or reconstructed from a DLL string
    # scan. Verified 2026-09-13 against the exact tagged source at
    # github.com/PowerShell/PowerShellEditorServices, tag v4.6.0. This is DIFFERENT from
    # rulesets/base.psd1 (this plugin's OWN opt-in curated ruleset, a much larger list) and from
    # PSProvideCommentHelp (a SEPARATE hardcoded rule PSES uses only for its comment-help
    # generation feature, not for diagnostics) -- do not conflate any of the three.
    #
    # PINNED, guarded: Get-PssaDefaultRulesVerifiedForPsesTag records the PSES tag this list
    # was verified against. Merge-RequiredRulesSettings refuses to trust this list (and degrades
    # to NOT merging) when the caller's current tag does not match, rather than silently shipping
    # a stale list the day PSES's own default set changes across a version bump.
    return @(
        'PSAvoidAssignmentToAutomaticVariable',
        'PSUseToExportFieldsInManifest',
        'PSMisleadingBacktick',
        'PSAvoidUsingCmdletAliases',
        'PSUseApprovedVerbs',
        'PSAvoidUsingPlainTextForPassword',
        'PSReservedCmdletChar',
        'PSReservedParams',
        'PSShouldProcess',
        'PSMissingModuleManifestField',
        'PSAvoidDefaultValueSwitchParameter',
        'PSUseDeclaredVarsMoreThanAssignments',
        'PSPossibleIncorrectComparisonWithNull',
        'PSAvoidDefaultValueForMandatoryParameter',
        'PSPossibleIncorrectUsageOfRedirectionOperator'
    )
}

function Get-PssaDefaultRulesVerifiedForPsesTag {
    # The PSES tag Get-PssaDefaultRuleNames's hardcoded list was verified against (a function, not
    # a top-level script-scoped assignment: dispatch 000156's lib-purity guard forbids any
    # top-level statement in a dot-sourced shared library, since it executes in the CALLER's
    # scope on every dot-source, not once). Merge-RequiredRulesSettings compares its caller's
    # current tag against this value and refuses to trust the pinned list on a mismatch.
    return 'v4.6.0'
}

# --- what PSScriptAnalyzer accepts in a settings file (dispatch 000306, B1b; review finding B1-K04) ---
# A settings file PSScriptAnalyzer rejects makes PSES analyze NOTHING while it still publishes a
# settled, empty result -- zero findings that read clean, unmanaged and managed alike (measured
# 2026-10-13 and 2026-10-15). So the merge writes only what PSScriptAnalyzer accepts, and the daemon
# validates every settings file it would hand PSES BEFORE PSES sees it (Read-PssaSettingsFile). The
# rules below are MEASURED against the vendored PSScriptAnalyzer 1.25.0 under Windows PowerShell 5.1
# and PowerShell 7 -- identical verdicts on both hosts, with and without the -Severity argument PSES
# passes beside -Settings -- not recalled from documentation.

function Get-PssaSettingsKeyNames {
    # THE keys a PSScriptAnalyzer settings file may hold, in canonical case. Measured: the vendored
    # 1.25.0 refuses any other key with "<key> is not a valid key in the settings hashtable. Valid keys
    # are CustomRulePath, ExcludeRules, IncludeRules, IncludeDefaultRules, RecurseCustomRulePath, Rules
    # and Severity." -- these seven, the same on both hosts -- and accepts each of them in any case.
    return @('CustomRulePath', 'ExcludeRules', 'IncludeRules', 'IncludeDefaultRules', 'RecurseCustomRulePath', 'Rules', 'Severity')
}

function Get-PssaBuiltinRuleNames {
    # The vendored PSScriptAnalyzer 1.25.0's built-in rules, in canonical case (dispatch 000306, review
    # findings B1b-R01 and B1b-K02): MEASURED with Get-ScriptAnalyzerRule under Windows PowerShell 5.1 and
    # PowerShell 7 -- the same 75 on both -- and re-measured against the vendored analyzer on every CI leg
    # (tests/PowerShellLsp.PolicySettings.Tests.ps1). A rule not named here is a custom rule (a
    # CustomRulePath module's 'Module\Measure-Name', or an assembly's).
    return @(
        'PSAlignAssignmentStatement', 'PSAvoidAssignmentToAutomaticVariable', 'PSAvoidDefaultValueForMandatoryParameter',
        'PSAvoidDefaultValueSwitchParameter', 'PSAvoidExclaimOperator', 'PSAvoidGlobalAliases', 'PSAvoidGlobalFunctions',
        'PSAvoidGlobalVars', 'PSAvoidInvokingEmptyMembers', 'PSAvoidLongLines', 'PSAvoidMultipleTypeAttributes',
        'PSAvoidNullOrEmptyHelpMessageAttribute', 'PSAvoidOverwritingBuiltInCmdlets', 'PSAvoidReservedWordsAsFunctionNames',
        'PSAvoidSemicolonsAsLineTerminators', 'PSAvoidShouldContinueWithoutForce', 'PSAvoidTrailingWhitespace',
        'PSAvoidUsingAllowUnencryptedAuthentication', 'PSAvoidUsingBrokenHashAlgorithms', 'PSAvoidUsingCmdletAliases',
        'PSAvoidUsingComputerNameHardcoded', 'PSAvoidUsingConvertToSecureStringWithPlainText', 'PSAvoidUsingDeprecatedManifestFields',
        'PSAvoidUsingDoubleQuotesForConstantString', 'PSAvoidUsingEmptyCatchBlock', 'PSAvoidUsingInvokeExpression',
        'PSAvoidUsingPlainTextForPassword', 'PSAvoidUsingPositionalParameters', 'PSAvoidUsingUsernameAndPasswordParams',
        'PSAvoidUsingWMICmdlet', 'PSAvoidUsingWriteHost', 'PSDSCDscExamplesPresent', 'PSDSCDscTestsPresent',
        'PSDSCReturnCorrectTypesForDSCFunctions', 'PSDSCStandardDSCFunctionsInResource', 'PSDSCUseIdenticalMandatoryParametersForDSC',
        'PSDSCUseIdenticalParametersForDSC', 'PSDSCUseVerboseMessageInDSCResource', 'PSMisleadingBacktick', 'PSMissingModuleManifestField',
        'PSPlaceCloseBrace', 'PSPlaceOpenBrace', 'PSPossibleIncorrectComparisonWithNull', 'PSPossibleIncorrectUsageOfAssignmentOperator',
        'PSPossibleIncorrectUsageOfRedirectionOperator', 'PSProvideCommentHelp', 'PSReservedCmdletChar', 'PSReservedParams',
        'PSReviewUnusedParameter', 'PSShouldProcess', 'PSUseApprovedVerbs', 'PSUseBOMForUnicodeEncodedFile', 'PSUseCmdletCorrectly',
        'PSUseCompatibleCmdlets', 'PSUseCompatibleCommands', 'PSUseCompatibleSyntax', 'PSUseCompatibleTypes', 'PSUseConsistentIndentation',
        'PSUseConsistentParameterSetName', 'PSUseConsistentParametersKind', 'PSUseConsistentWhitespace', 'PSUseConstrainedLanguageMode',
        'PSUseCorrectCasing', 'PSUseDeclaredVarsMoreThanAssignments', 'PSUseLiteralInitializerForHashtable', 'PSUseOutputTypeCorrectly',
        'PSUseProcessBlockForPipelineCommand', 'PSUsePSCredentialType', 'PSUseShouldProcessForStateChangingFunctions',
        'PSUseSingleValueFromPipelineParameter', 'PSUseSingularNouns', 'PSUseSupportsShouldProcess', 'PSUseToExportFieldsInManifest',
        'PSUseUsingScopeModifierInNewRunspaces', 'PSUseUTF8EncodingForHelpFile'
    )
}

function Get-PssaConfigurableRuleNames {
    # The built-in rules that take settings -- those deriving from PSScriptAnalyzer's ConfigurableRule, whose
    # Enable flag in a settings file's Rules switches them on or off (dispatch 000306, review finding
    # B1b-R01). MEASURED like Get-PssaBuiltinRuleNames: 21 on both hosts, four of them on by default
    # (PSAvoidOverwritingBuiltInCmdlets, PSAvoidUsingPositionalParameters, PSProvideCommentHelp,
    # PSUseSingularNouns) and seventeen off -- naming one of those in IncludeRules alone does not make it
    # run. Enable on any other rule is ignored (measured). PSScriptAnalyzer matches a Rules key to a rule
    # name CASE-SENSITIVELY (a 'psusesingularnouns' entry configures nothing) and a setting's name in any
    # case ('enable' works) -- measured on both hosts.
    return @(
        'PSAlignAssignmentStatement', 'PSAvoidExclaimOperator', 'PSAvoidLongLines', 'PSAvoidOverwritingBuiltInCmdlets',
        'PSAvoidSemicolonsAsLineTerminators', 'PSAvoidUsingDoubleQuotesForConstantString', 'PSAvoidUsingPositionalParameters',
        'PSPlaceCloseBrace', 'PSPlaceOpenBrace', 'PSProvideCommentHelp', 'PSUseCompatibleCommands', 'PSUseCompatibleSyntax',
        'PSUseCompatibleTypes', 'PSUseConsistentIndentation', 'PSUseConsistentParameterSetName', 'PSUseConsistentParametersKind',
        'PSUseConsistentWhitespace', 'PSUseConstrainedLanguageMode', 'PSUseCorrectCasing', 'PSUseSingleValueFromPipelineParameter',
        'PSUseSingularNouns'
    )
}

# --- how PSScriptAnalyzer names and matches a rule (dispatch 000307, B1c) ---
# MEASURED on the vendored PSScriptAnalyzer 1.25.0 under Windows PowerShell 5.1 and PowerShell 7, called as
# PSES calls it -- the same on both hosts (review findings B1b-OOB2-R01 to R03):
#   - an IncludeRules or ExcludeRules entry is matched against the WHOLE rule name, ignoring case; '*' stands
#     for any run of characters, none included ('PSAvoidGlobalVars*' names PSAvoidGlobalVars), and every other
#     character is literal: '?', '[s]', '.', '.*', '+', '|', '(...)', '^...$', '(?i)', a backslash, a TAB and
#     surrounding blanks (' PSAvoidGlobalVars ' names no rule);
#   - case is folded the way .NET's regular expressions fold it, not ASCII's way: 'PSMisleadingBac' + U+212A
#     KELVIN SIGN + '*' excludes PSMisleadingBacktick;
#   - a custom rule is matched by its BARE name: a module rule whose findings read 'Module\Measure-Name' is
#     selected and excluded by 'Measure-Name' (or a pattern over it), never by 'Module\Measure-Name';
#   - an exclusion beats IncludeRules and an Enable = $true in Rules;
#   - IncludeRules = @() is no IncludeRules (every enabled rule runs); @('') and @(' ') select nothing.

function Get-PssaRuleMatchName {
    # The name PSScriptAnalyzer matches the rule code $Code by in IncludeRules and ExcludeRules (dispatch 000307,
    # review finding B1b-OOB2-R02): the text after the last '\' -- a custom rule's 'Module\Measure-Name', the
    # way its findings and so RequiredRules name it, is matched as 'Measure-Name' -- and a built-in or bare
    # code as itself; trimmed. '' when nothing follows the last '\'.
    param([string]$Code)
    $t = ([string]$Code).Trim()
    $i = $t.LastIndexOf('\')
    if ($i -ge 0) { return $t.Substring($i + 1) }
    return $t
}

function Test-PssaRuleNameMatch {
    # Does PSScriptAnalyzer read the IncludeRules or ExcludeRules entry $Entry, exactly as written, as naming
    # the rule whose match name (Get-PssaRuleMatchName) is $Name? Built the way the measured behavior above
    # reads: the entry escaped as a regular expression with each '*' then standing for '.*', anchored at both
    # ends and matched ignoring case -- so every measured form agrees with the analyzer, the Kelvin sign
    # included, on both hosts.
    #
    # A RUN OF '*' IS BUILT AS ONE (dispatch 000307, correction round 2; owner ruling RR-04, review finding
    # B1c-RR-04). '.*.*' matches exactly what '.*' matches, but on Windows PowerShell 5.1 (.NET Framework) a run
    # of them before a tail no name ends in backtracks combinatorially: eight stars and a 'Z' took over 40
    # seconds against a 46-character rule name, PowerShell 7 under a millisecond (measured). So the run is
    # collapsed first. That changes no answer (measured against the uncollapsed construction on both hosts) and
    # nothing the merge writes: an entry is still written exactly as the repository gave it.
    param([string]$Entry, [string]$Name)
    if ([string]::IsNullOrEmpty($Entry) -or [string]::IsNullOrEmpty($Name)) { return $false }
    $pattern = '^' + [regex]::Escape([regex]::Replace($Entry, '\*{2,}', '*')).Replace('\*', '.*') + '$'
    return [regex]::IsMatch($Name, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Get-RequiredRulesNotRunnable {
    # Which of $RequiredRules the settings table $Settings -- what the daemon hands PSES, as read back
    # (Read-PssaSettingsFile's Entries) -- CANNOT run, by a static read of that table and the measured matching
    # above (dispatch 000307, review findings B1b-OOB2-R04 and B1b-OOB2-R01). One 'code: why' line per such
    # rule, in the order given; @() when none:
    #   'no rule of that name'      its match name (Get-PssaRuleMatchName) is none of PSScriptAnalyzer's
    #                               built-in rules and the settings carry no CustomRulePath that could supply
    #                               it -- a misspelled built-in name, a rule only another analyzer version has,
    #                               or a custom rule whose module nothing loads -- or it names nothing at all;
    #   'excluded by <entry>'       an ExcludeRules entry matches it, and an exclusion wins (measured);
    #   'not in IncludeRules'       the settings name IncludeRules and no entry selects it;
    #   'built-in rules not loaded' it is a built-in rule, beside a CustomRulePath without
    #                               IncludeDefaultRules = $true, which loads only the custom rules;
    #   'not enabled in Rules'      it is a configurable built-in rule (Get-PssaConfigurableRuleNames, by its match
    #                               name) and the settings' Rules entry under its canonical name -- the key
    #                               PSScriptAnalyzer matches, case-sensitively -- does not set Enable = $true: off
    #                               by default it never runs, and Enable = $false keeps it off. The merge switches
    #                               every required one on, so its own output never shows this; it is a backstop
    #                               (owner ruling RR-01, dispatch 000307 correction round 2, review finding
    #                               B1c-RR-01).
    # A rule the organization also excludes is not required (exclusion is the stronger verb) and is not
    # reported. Beside a CustomRulePath, whether a custom rule is in the modules that path loads, and whether
    # they load and run at all, is not something a static read can see (owner ruling K01b: leg A3's runtime
    # signal), so a code that is not a built-in rule is not reported there.
    param($Settings, [string[]]$RequiredRules = @(), [string[]]$OrgExcludeRules = @())
    $out = New-Object 'System.Collections.Generic.List[string]'
    $orgExc = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($e in @($OrgExcludeRules | Where-Object { $_ })) { [void]$orgExc.Add(([string]$e).Trim()) }
    $builtin = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in @(Get-PssaBuiltinRuleNames)) { [void]$builtin.Add($n) }
    $has = { param($k) $null -ne $Settings -and $Settings -is [System.Collections.IDictionary] -and $Settings.Contains($k) }
    $customPath = (& $has 'CustomRulePath') -and @(@($Settings['CustomRulePath']) | Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0
    $defaultsLoaded = (-not $customPath) -or ((& $has 'IncludeDefaultRules') -and $Settings['IncludeDefaultRules'] -is [bool] -and [bool]$Settings['IncludeDefaultRules'])
    $include = @()
    if (& $has 'IncludeRules') { $include = @(@($Settings['IncludeRules']) | Where-Object { $_ -is [string] }) }
    $exclude = @()
    if (& $has 'ExcludeRules') { $exclude = @(@($Settings['ExcludeRules']) | Where-Object { $_ -is [string] }) }
    $configurable = @{}
    foreach ($n in @(Get-PssaConfigurableRuleNames)) { $configurable[$n] = $n }
    $ruleTable = $null
    if (& $has 'Rules') { $ruleTable = $Settings['Rules'] }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($r in @($RequiredRules | Where-Object { $_ })) {
        $code = ([string]$r).Trim()
        if ($code -eq '' -or $orgExc.Contains($code) -or -not $seen.Add($code)) { continue }
        $name = Get-PssaRuleMatchName $code
        $why = ''
        if ($name -eq '' -or (-not $builtin.Contains($name) -and -not $customPath)) {
            $why = 'no rule of that name'
        } else {
            foreach ($x in $exclude) {
                if (Test-PssaRuleNameMatch -Entry $x -Name $name) { $why = ("excluded by '" + (Format-PssaSettingsText $x 60) + "'"); break }
            }
            if ($why -eq '' -and $include.Count -gt 0 -and @($include | Where-Object { Test-PssaRuleNameMatch -Entry $_ -Name $name }).Count -eq 0) { $why = 'not in IncludeRules' }
            if ($why -eq '' -and $builtin.Contains($name) -and -not $defaultsLoaded) { $why = 'built-in rules not loaded' }
            if ($why -eq '' -and $configurable.ContainsKey($name)) {
                # The entry PSScriptAnalyzer reads -- the canonical key, matched case-sensitively, with a setting's
                # name in any case (measured, dispatch 000306) -- must set Enable = $true.
                $canon = [string]$configurable[$name]
                $on = $false
                if ($ruleTable -is [System.Collections.IDictionary]) {
                    foreach ($k in @($ruleTable.Keys)) {
                        if (-not [string]::Equals([string]$k, $canon, [System.StringComparison]::Ordinal) -or $ruleTable[$k] -isnot [System.Collections.IDictionary]) { continue }
                        foreach ($a in @($ruleTable[$k].Keys)) {
                            if ([string]::Equals([string]$a, 'Enable', [System.StringComparison]::OrdinalIgnoreCase) -and $ruleTable[$k][$a] -is [bool] -and [bool]$ruleTable[$k][$a]) { $on = $true }
                        }
                    }
                }
                if (-not $on) { $why = 'not enabled in Rules' }
            }
        }
        if ($why -ne '') { $out.Add(($code + ': ' + $why)) }
    }
    return $out.ToArray()   # an ordinary pipeline return: wrap the call in @(...) -- an empty result is nothing
}

function Get-PssaSettingsSeverityNames {
    # PSScriptAnalyzer's severity names, which a settings file's Severity entries must parse as. Measured:
    # any case and surrounding blanks are accepted; 'Hint', '' and any other word are refused
    # ("Requested value 'Hint' was not found."), on both hosts.
    return @('Information', 'Warning', 'Error', 'ParseError')
}

function Test-PssaSettingsSeverityName {
    # Does PSScriptAnalyzer accept $Name as one Severity entry? It parses the entry as its severity enum,
    # ignoring case, so this mirrors that parse as measured: the entry is trimmed; one that starts with
    # a digit or a sign must be a number in the enum's UInt32 range ('7' is accepted, '99999999999' is
    # refused); otherwise every comma-separated part must be a severity name ('Warning,Error' is
    # accepted, 'Warning,' is refused). Stricter than the parse only where PSScriptAnalyzer might accept
    # a mixed list such as 'Warning,1' -- that reads as rejected, never as valid.
    param($Name)
    if ($Name -isnot [string]) { return $false }
    $t = $Name.Trim()
    if ($t -eq '') { return $false }
    $c = $t[0]
    if ([char]::IsDigit($c) -or $c -eq '-' -or $c -eq '+') {
        $n = [uint32]0
        return [uint32]::TryParse($t, [System.Globalization.NumberStyles]::AllowLeadingSign, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$n)
    }
    foreach ($part in $t.Split(',')) {
        $p = $part.Trim()
        if ($p -eq '') { return $false }
        $known = $false
        foreach ($s in (Get-PssaSettingsSeverityNames)) {
            if ([string]::Equals($s, $p, [System.StringComparison]::OrdinalIgnoreCase)) { $known = $true; break }
        }
        if (-not $known) { return $false }
    }
    return $true
}

function Test-PssaSettingsValueAst {
    # Is $Ast a value node the settings reader treats as DATA? Constants (strings, numbers -- a leading
    # minus is part of the number), $true / $false / $null, @(...) and comma arrays of such values,
    # nested hashtables, a cast of such a value ([int]5 -- measured, accepted), and -- review finding
    # B1b-R02 -- such a value in parentheses (('A', 'B'), ($true), (120): the parentheses' pipeline must
    # be a pure expression, never a command) or behind a sign (-(5), +(5)), all measured ACCEPTED by
    # PSScriptAnalyzer on both hosts. Anything else -- a command, a sub-expression, an expandable string,
    # any other variable ($PSScriptRoot, $env:X, all measured REFUSED by PSScriptAnalyzer) -- is not data,
    # so the file reads as unparsable without anything in it being evaluated. Deliberately no wider than
    # PSScriptAnalyzer's own reader, which evaluates like Ast.SafeGetValue: where the two might differ,
    # this refuses. Measured to differ, and kept refused (a test keeps it visible): a sub-expression
    # holding data ($('Warning')) and the operators !, -not and -bnot, which PSScriptAnalyzer accepts.
    param($Ast)
    if ($null -eq $Ast) { return $false }
    if ($Ast -is [System.Management.Automation.Language.ConstantExpressionAst]) { return $true }
    if ($Ast -is [System.Management.Automation.Language.VariableExpressionAst]) {
        if ($null -eq $Ast.VariablePath -or -not $Ast.VariablePath.IsUnqualified) { return $false }
        return (@('true', 'false', 'null') -contains ([string]$Ast.VariablePath.UserPath).ToLowerInvariant())
    }
    if ($Ast -is [System.Management.Automation.Language.ConvertExpressionAst]) { return (Test-PssaSettingsValueAst $Ast.Child) }
    if ($Ast -is [System.Management.Automation.Language.ParenExpressionAst]) {
        $pure = $null
        if ($Ast.Pipeline -is [System.Management.Automation.Language.PipelineAst]) { $pure = $Ast.Pipeline.GetPureExpression() }
        return (Test-PssaSettingsValueAst $pure)
    }
    if ($Ast -is [System.Management.Automation.Language.UnaryExpressionAst]) {
        $sign = $Ast.TokenKind
        if ($sign -ne [System.Management.Automation.Language.TokenKind]::Minus -and $sign -ne [System.Management.Automation.Language.TokenKind]::Plus) { return $false }
        return (Test-PssaSettingsValueAst $Ast.Child)
    }
    if ($Ast -is [System.Management.Automation.Language.ArrayLiteralAst]) {
        foreach ($e in @($Ast.Elements)) { if (-not (Test-PssaSettingsValueAst $e)) { return $false } }
        return $true
    }
    if ($Ast -is [System.Management.Automation.Language.ArrayExpressionAst]) {
        if ($null -eq $Ast.SubExpression) { return $false }
        foreach ($s in @($Ast.SubExpression.Statements)) {
            $pure = $null
            if ($s -is [System.Management.Automation.Language.PipelineAst]) { $pure = $s.GetPureExpression() }
            if (-not (Test-PssaSettingsValueAst $pure)) { return $false }
        }
        return $true
    }
    if ($Ast -is [System.Management.Automation.Language.HashtableAst]) {
        foreach ($pair in @($Ast.KeyValuePairs)) {
            if (-not (Test-PssaSettingsValueAst $pair.Item1)) { return $false }
            $pure = $null
            if ($pair.Item2 -is [System.Management.Automation.Language.PipelineAst]) { $pure = $pair.Item2.GetPureExpression() }
            if (-not (Test-PssaSettingsValueAst $pure)) { return $false }
        }
        return $true
    }
    return $false
}

function Format-PssaSettingsText {
    # $Text as one printable-ASCII line, cut at $Max -- for a settings problem quoted into a log line or
    # into evidence, where a key name from a user's file must not carry a line end or a non-ASCII byte.
    param([string]$Text, [int]$Max = 160)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $shown = -join @($Text.ToCharArray() | ForEach-Object { if ([int]$_ -ge 0x20 -and [int]$_ -le 0x7E) { [string]$_ } else { '?' } })
    if ($shown.Length -gt $Max) { $shown = $shown.Substring(0, $Max) + '...' }
    return $shown
}

function Get-PssaSettingsTreeProblem {
    # PSScriptAnalyzer walks a settings table recursively before it reads any key, and refuses a key that
    # is not a string ("Key  in the settings is not a string.") and a $null value ("Value  for key ... has
    # the wrong data type.") at every level of nested TABLES -- a $null inside an array is not checked
    # (all measured). '' when $Table passes that walk, else why not.
    param($Table, [string]$Where = '')
    foreach ($k in @($Table.Keys)) {
        if ($k -isnot [string]) { return ('a key' + $Where + ' is not a string') }
        $v = $Table[$k]
        if ($null -eq $v) { return ("'" + (Format-PssaSettingsText $k 60) + "'" + $Where + ' has a $null value') }
        if ($v -is [System.Collections.IDictionary]) {
            $inner = Get-PssaSettingsTreeProblem -Table $v -Where (" in '" + (Format-PssaSettingsText $k 60) + "'")
            if ($inner -ne '') { return $inner }
        }
    }
    return ''
}

function Get-PssaSettingsStringListProblem {
    # PSScriptAnalyzer reads Severity, IncludeRules, ExcludeRules and CustomRulePath as "a string or an
    # array of strings" and refuses anything else, including an array holding a non-string (measured:
    # @('Warning', 5) and @('PSAvoidGlobalVars', $null) are both refused). '' when $Value is one.
    param([string]$Key, $Value)
    if ($Value -is [string]) { return '' }
    if ($Value -is [System.Array]) {
        foreach ($e in @($Value)) { if ($e -isnot [string]) { return ($Key + ' holds an entry that is not a string') } }
        return ''
    }
    return ($Key + ' is not a string or an array of strings')
}

function Test-PssaSettingsRulePathAnchored {
    # Does the CustomRulePath entry $Path name the same place from ANY current location -- so the daemon
    # can resolve it exactly as PSScriptAnalyzer will inside PSES, which runs from the daemon's log
    # directory, never the repository's? Anchored: a full file-system path (X:\ or X:/, or a UNC
    # \\server\share, on Windows; /... elsewhere), a home-relative ~ path, or a full path behind the
    # FileSystem provider's qualifier (FileSystem:: or Microsoft.PowerShell.Core\FileSystem::). NOT
    # anchored (measured on both hosts, dispatch 000306): a relative path (.\rules, rules\x.psm1); a
    # drive-relative one (C:rules -- the current directory ON that drive, which PSES does not share: one
    # that existed from the daemon's location read valid and PSScriptAnalyzer, run from elsewhere,
    # refused it); a root-relative one (\rules -- the current drive); a path on any other PowerShell drive
    # (Temp:\ exists under PowerShell 7 only, and PSES may run under the other host). ASCII-only: the
    # drive letter is [A-Za-z], compared case-sensitively.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $p = $Path
    $qualified = $false
    foreach ($prefix in @('Microsoft.PowerShell.Core\FileSystem::', 'FileSystem::')) {
        if ($p.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $p = $p.Substring($prefix.Length)
            $qualified = $true
            break
        }
    }
    if (-not $qualified -and $p -cmatch '\A~(?:[\\/]|\z)') { return $true }
    if ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
        return (($p -cmatch '\A[A-Za-z]:[\\/]') -or ($p -cmatch '\A[\\/]{2}[^\\/]'))
    }
    return $p.StartsWith('/')
}

function Test-PssaSettingsRuleFileName {
    # Is $Name a file PSScriptAnalyzer loads rules from when a CustomRulePath directory holds it: any
    # assembly (*.dll), or the module file named after that directory ($ModuleName.psd1 / .psm1)?
    # -ModuleOnly: the module file only (a version-named subdirectory of a module directory).
    param([string]$Name, [string]$ModuleName, [switch]$ModuleOnly)
    $ext = [System.IO.Path]::GetExtension($Name)
    if (-not $ModuleOnly -and [string]::Equals($ext, '.dll', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ([string]::Equals($ext, '.psd1', [System.StringComparison]::OrdinalIgnoreCase) -or [string]::Equals($ext, '.psm1', [System.StringComparison]::OrdinalIgnoreCase)) {
        return [string]::Equals([System.IO.Path]::GetFileNameWithoutExtension($Name), $ModuleName, [System.StringComparison]::OrdinalIgnoreCase)
    }
    return $false
}

function Test-PssaSettingsRuleDirectory {
    # Does PSScriptAnalyzer load rules from the CustomRulePath directory $Path (dispatch 000306, review
    # finding B1b-K01)? MEASURED on the vendored 1.25.0, both hosts: a directory entry loads a MODULE only
    # when it is a module directory -- it holds <its own name>.psd1 or .psm1, itself or in a version-named
    # subdirectory (B1bc.Mod\B1bc.Mod.psm1, B1bc.Ver\1.0.0\B1bc.Ver.psd1) -- and otherwise loads the
    # assemblies (*.dll) in it; a directory holding only other files, or a module file under another name
    # (rules\My.Rules.psm1), yields no rule. With RecurseCustomRulePath = $true the same holds for every
    # directory below it (outer\B1bc.Deep\B1bc.Deep.psm1 loads then, and not without it). Never refuses on
    # a guess: a directory it cannot list, or a tree of more than $Budget directories, counts as a rule
    # source.
    param([string]$Path, [bool]$Recurse = $false, [int]$Budget = 2000)
    $pending = New-Object 'System.Collections.Generic.Queue[string]'
    $pending.Enqueue($Path)
    $listed = 0
    while ($pending.Count -gt 0) {
        $dir = $pending.Dequeue()
        $listed++
        if ($listed -gt $Budget) { return $true }
        try {
            $di = New-Object System.IO.DirectoryInfo($dir)
            foreach ($f in @($di.GetFiles())) {
                if (Test-PssaSettingsRuleFileName -Name $f.Name -ModuleName $di.Name) { return $true }
            }
            foreach ($sub in @($di.GetDirectories())) {
                $ver = $null
                if ([version]::TryParse($sub.Name, [ref]$ver)) {
                    foreach ($f in @($sub.GetFiles())) {
                        if (Test-PssaSettingsRuleFileName -Name $f.Name -ModuleName $di.Name -ModuleOnly) { return $true }
                    }
                }
                if ($Recurse) { $pending.Enqueue($sub.FullName) }
            }
        } catch { return $true }
    }
    return $false
}

function Test-PssaSettingsRulePathYieldsRule {
    # Does any entry of the CustomRulePath $Entries lead PSScriptAnalyzer to a rule source: a .psm1, .psd1
    # or .dll file the entry names (directly or through a wildcard), or a directory it loads rules from
    # (Test-PssaSettingsRuleDirectory)? Review finding B1b-K01, MEASURED on the vendored 1.25.0, both
    # hosts: settings whose entries TOGETHER reach none -- a wildcard matching nothing, an empty directory,
    # a directory or file holding no module or assembly (a .txt, a .ps1) -- are refused ("Cannot find
    # ScriptAnalyzer rules in the specified path", and PSES analyzes nothing) unless IncludeDefaultRules
    # is $true; a dead entry beside one that reaches a rule source is not. What stays out of sight (owner
    # ruling K01b, left to A3's runtime signal): a rule source PSScriptAnalyzer cannot load or run, or that
    # holds no rule -- a module whose manifest names a nested root module, a rule that throws, a module
    # exporting no rule function, an assembly with no rule in it.
    param([string[]]$Entries, [bool]$Recurse = $false)
    foreach ($e in @($Entries)) {
        $paths = @()
        try { $paths = @($ExecutionContext.SessionState.Path.GetResolvedPSPathFromPSPath($e) | ForEach-Object { [string]$_.ProviderPath }) } catch { $paths = @() }
        foreach ($p in $paths) {
            if ([System.IO.Directory]::Exists($p)) {
                if (Test-PssaSettingsRuleDirectory -Path $p -Recurse $Recurse) { return $true }
            } elseif ([System.IO.File]::Exists($p)) {
                $ext = [System.IO.Path]::GetExtension($p)
                foreach ($x in @('.psm1', '.psd1', '.dll')) {
                    if ([string]::Equals($ext, $x, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
                }
            }
        }
    }
    return $false
}

function Get-PssaSettingsEntryProblem {
    # '' when PSScriptAnalyzer, run by PSES as this plugin runs it, accepts $Value under the canonical
    # key $Key; otherwise one line saying why not. Each rule here was measured (see above):
    #   Severity                 a string list whose every entry parses as a severity;
    #   IncludeRules/ExcludeRules a string list;
    #   CustomRulePath           a string list that is not empty, with no blank entry, every entry
    #                            ANCHORED (Test-PssaSettingsRulePathAnchored) -- a relative entry resolves
    #                            against PSES's own working directory (the daemon's log directory), not
    #                            the repository, and through the real daemon a repository file naming
    #                            '.\rules\x.psm1' made PSES analyze nothing, IncludeDefaultRules or not --
    #                            and resolvable by PowerShell's own resolver, the call PSScriptAnalyzer
    #                            makes for each entry: it refuses the settings when that call THROWS (a
    #                            path or a drive that does not exist), and a wildcard that matches is
    #                            used while one that matches nothing is no error (measured, both hosts);
    #                            and -- review finding B1b-K01 -- unless $IncludeDefaultRules, the entries
    #                            must together reach a rule source (Test-PssaSettingsRulePathYieldsRule,
    #                            with $RecurseCustomRulePath), or PSScriptAnalyzer finds no rules at all;
    #   IncludeDefaultRules / RecurseCustomRulePath  a boolean;
    #   Rules                    a table whose every value is a table (one rule's settings).
    # What this cannot see -- a rule source PSScriptAnalyzer cannot load or run, or that holds no rule
    # (without IncludeDefaultRules = $true, PSScriptAnalyzer refuses settings whose custom paths yield
    # none) -- is a documented boundary (docs/repository-scanning.md; owner ruling K01b), left to A3's
    # runtime signal.
    param([string]$Key, $Value, [bool]$IncludeDefaultRules = $false, [bool]$RecurseCustomRulePath = $false)
    switch ($Key) {
        'Severity' {
            $p = Get-PssaSettingsStringListProblem -Key $Key -Value $Value
            if ($p -ne '') { return $p }
            foreach ($e in @($Value)) {
                if (-not (Test-PssaSettingsSeverityName $e)) {
                    return ("Severity names '" + (Format-PssaSettingsText $e 40) + "', which is not a PSScriptAnalyzer severity (" + ((Get-PssaSettingsSeverityNames) -join ', ') + ')')
                }
            }
            return ''
        }
        'IncludeRules' { return (Get-PssaSettingsStringListProblem -Key $Key -Value $Value) }
        'ExcludeRules' { return (Get-PssaSettingsStringListProblem -Key $Key -Value $Value) }
        'CustomRulePath' {
            $p = Get-PssaSettingsStringListProblem -Key $Key -Value $Value
            if ($p -ne '') { return $p }
            $entries = @($Value)
            if ($entries.Count -eq 0) { return 'CustomRulePath is empty (PSScriptAnalyzer then finds no rules in it)' }
            foreach ($e in $entries) {
                if ([string]::IsNullOrWhiteSpace($e)) { return 'CustomRulePath holds a blank entry' }
                if (-not (Test-PssaSettingsRulePathAnchored $e)) {
                    return ("CustomRulePath entry '" + (Format-PssaSettingsText $e 80) + "' is relative (to a directory, a drive or the current drive); PSES resolves it from its own working directory, not the repository")
                }
                $resolves = $true
                try { [void]$ExecutionContext.SessionState.Path.GetResolvedPSPathFromPSPath($e) } catch { $resolves = $false }
                if (-not $resolves) { return ("CustomRulePath entry '" + (Format-PssaSettingsText $e 80) + "' does not exist") }
            }
            if (-not $IncludeDefaultRules -and -not (Test-PssaSettingsRulePathYieldsRule -Entries $entries -Recurse $RecurseCustomRulePath)) {
                return 'CustomRulePath reaches no rule module or assembly, and IncludeDefaultRules is not $true: PSScriptAnalyzer finds no rules'
            }
            return ''
        }
        'IncludeDefaultRules' { if ($Value -is [bool]) { return '' } else { return 'IncludeDefaultRules is not $true or $false' } }
        'RecurseCustomRulePath' { if ($Value -is [bool]) { return '' } else { return 'RecurseCustomRulePath is not $true or $false' } }
        'Rules' {
            if ($Value -isnot [System.Collections.IDictionary]) { return 'Rules is not a table' }
            foreach ($rk in @($Value.Keys)) {
                if ($Value[$rk] -isnot [System.Collections.IDictionary]) {
                    return ("Rules entry '" + (Format-PssaSettingsText ([string]$rk) 60) + "' is not a table")
                }
            }
            return ''
        }
    }
    return ($Key + ' is not a key PSScriptAnalyzer accepts')
}

function Get-PssaSettingsFileEncoding {
    # How a settings file's bytes open (dispatch 000309, B1e; owner ruling RV-02, design a): 'bom' when they start
    # with a byte order mark PowerShell honors (UTF-8, UTF-16 little- or big-endian -- the first also opens UTF-32
    # little-endian -- or UTF-32 big-endian), 'ascii' when no byte is above 0x7F, else 'unmarked-non-ascii': the
    # file Windows PowerShell 5.1 reads in the system ANSI code page and PowerShell 7 as UTF-8. '' when it cannot be
    # read. Pure over the bytes on disk; never throws.
    param([string]$Path)
    try {
        $b = [System.IO.File]::ReadAllBytes($Path)
        if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { return 'bom' }
        if ($b.Length -ge 2 -and (($b[0] -eq 0xFF -and $b[1] -eq 0xFE) -or ($b[0] -eq 0xFE -and $b[1] -eq 0xFF))) { return 'bom' }
        if ($b.Length -ge 4 -and $b[0] -eq 0 -and $b[1] -eq 0 -and $b[2] -eq 0xFE -and $b[3] -eq 0xFF) { return 'bom' }
        foreach ($x in $b) { if ($x -gt 0x7F) { return 'unmarked-non-ascii' } }
        return 'ascii'
    } catch { return '' }
}

function Test-PssaSettingsAnsiDecoded {
    # Whether THIS host reads the settings file at $Path in the system ANSI code page (dispatch 000309, B1e; owner
    # ruling RV-02, design a, on review finding B1d-RV-02): only Windows PowerShell 5.1 does, and only for a file
    # that has no byte order mark and holds a byte above 0x7F (Get-PssaSettingsFileEncoding) -- so a character
    # outside ASCII a repository wrote in UTF-8 reaches the analysis as other characters there. PowerShell 7 reads
    # every such file as UTF-8, so this is never true under it. The daemon records the answer
    # (settings.ansiDecoded) and a managed scan refuses it (policy-settings-ansi-decoded); what PSES is handed does
    # not change.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($PSVersionTable.PSEdition -eq 'Core') { return $false }
    return ((Get-PssaSettingsFileEncoding -Path $Path) -ceq 'unmarked-non-ascii')
}

function Read-PssaSettingsFile {
    # Read the PSScriptAnalyzer settings file at $Path the way PSScriptAnalyzer reads it, as DATA, and
    # say whether PSScriptAnalyzer -- run by PSES as this plugin runs it -- would accept it. Never throws.
    # Returns [ordered]:
    #   Path      the path as given;
    #   Verdict   'valid' | 'rejected' (it reads as a table, and PSScriptAnalyzer would refuse a key or a
    #             value in it) | 'unparsable' (no file, no table, or something in it that is not data);
    #   Problem   '' when valid, else the first problem found (keys taken in sorted order), one ASCII line;
    #   Entries   the ACCEPTED entries only, under their canonical key names (Get-PssaSettingsKeyNames),
    #             in that fixed order -- what Merge-RequiredRulesSettings carries into a merged file;
    #   Rejected  the key names (as written, ASCII-shown) that are not carried.
    #
    # HOW IT READS, mirroring PSScriptAnalyzer (measured): the file is parsed -- never run -- and the
    # FIRST table in it is the settings (a statement before it, or an array around it, is allowed;
    # nothing in a script block counts), whose every value must be data (Test-PssaSettingsValueAst)
    # before Ast.SafeGetValue -- the data-only evaluation Import-PowerShellDataFile uses -- builds it.
    # A parse error is not refused by itself, exactly as PSScriptAnalyzer does not: what decides is
    # whether that first table reads as data. Then the table walk (Get-PssaSettingsTreeProblem), the key
    # set (Get-PssaSettingsKeyNames) and each value's shape (Get-PssaSettingsEntryProblem).
    param([string]$Path)
    $out = [ordered]@{ Path = [string]$Path; Verdict = 'unparsable'; Problem = ''; Entries = [ordered]@{}; Rejected = @() }
    $full = ''
    try {
        if ([string]::IsNullOrWhiteSpace($Path) -or -not [System.IO.Path]::IsPathRooted($Path)) {
            $out.Problem = 'the settings path is not absolute'
            return $out
        }
        $full = [System.IO.Path]::GetFullPath($Path)
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            $out.Problem = 'no settings file exists at that path'
            return $out
        }
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$tokens, [ref]$errors)
        $tables = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $false))
        if ($tables.Count -eq 0) {
            $out.Problem = 'it does not contain a table'
            return $out
        }
        if (-not (Test-PssaSettingsValueAst $tables[0])) {
            $out.Problem = 'its table holds something that is not data (a command, a variable, an expandable string or a sub-expression)'
            return $out
        }
        $data = $null
        try { $data = $tables[0].SafeGetValue() } catch {
            $out.Problem = 'its table could not be read as data: ' + (Format-PssaSettingsText ([string]$_.Exception.Message) 120)
            return $out
        }
        if ($data -isnot [System.Collections.IDictionary]) {
            $out.Problem = 'its table did not read as a table'
            return $out
        }
        $out.Verdict = 'valid'
        $canon = Get-PssaSettingsKeyNames
        $accepted = @{}
        $rejected = New-Object 'System.Collections.Generic.List[string]'
        $problems = New-Object 'System.Collections.Generic.List[string]'
        if (@(@($data.Keys) | Where-Object { $_ -isnot [string] }).Count -gt 0) {
            $rejected.Add('(a key that is not a string)')
            $problems.Add('a key is not a string')
        }
        $names = @(@($data.Keys) | Where-Object { $_ -is [string] })
        [System.Array]::Sort($names, [System.StringComparer]::OrdinalIgnoreCase)
        # What CustomRulePath's check needs from its neighbours (review finding B1b-K01): only a boolean
        # $true counts, as only a boolean is accepted.
        $includeDefault = $false
        $recurseRules = $false
        foreach ($k in $names) {
            if ([string]::Equals($k, 'IncludeDefaultRules', [System.StringComparison]::OrdinalIgnoreCase) -and $data[$k] -is [bool]) { $includeDefault = [bool]$data[$k] }
            if ([string]::Equals($k, 'RecurseCustomRulePath', [System.StringComparison]::OrdinalIgnoreCase) -and $data[$k] -is [bool]) { $recurseRules = [bool]$data[$k] }
        }
        foreach ($k in $names) {
            $name = $null
            foreach ($c in $canon) { if ([string]::Equals($c, $k, [System.StringComparison]::OrdinalIgnoreCase)) { $name = $c; break } }
            if ($null -eq $name) {
                $rejected.Add((Format-PssaSettingsText $k 60))
                $problems.Add(("'" + (Format-PssaSettingsText $k 60) + "' is not a key PSScriptAnalyzer accepts (" + ($canon -join ', ') + ')'))
                continue
            }
            $v = $data[$k]
            $p = ''
            if ($null -eq $v) { $p = ($name + ' has a $null value') }
            elseif ($v -is [System.Collections.IDictionary]) { $p = Get-PssaSettingsTreeProblem -Table $v -Where (' in ' + $name) }
            if ($p -eq '') { $p = Get-PssaSettingsEntryProblem -Key $name -Value $v -IncludeDefaultRules $includeDefault -RecurseCustomRulePath $recurseRules }
            if ($p -ne '') {
                $rejected.Add((Format-PssaSettingsText $k 60))
                $problems.Add($p)
                continue
            }
            $accepted[$name] = $v
        }
        foreach ($c in $canon) { if ($accepted.ContainsKey($c)) { $out.Entries[$c] = $accepted[$c] } }
        $out.Rejected = @($rejected.ToArray())
        if ($problems.Count -gt 0) {
            $out.Verdict = 'rejected'
            $out.Problem = Format-PssaSettingsText ([string]$problems[0])
        }
        return $out
    } catch {
        $out.Verdict = 'unparsable'
        $out.Entries = [ordered]@{}
        $out.Problem = 'it could not be read: ' + (Format-PssaSettingsText ([string]$_.Exception.Message) 120)
        return $out
    }
}

function Set-PssaRequiredRulesEnabled {
    # The Rules table a RequiredRules merge writes (owner ruling R01, 2026-10-15; review finding B1b-R01):
    # a COPY of the repository's $Rules (or a new table) in which no rule in $RequiredRules can be switched
    # off. For each one:
    #   - a built-in configurable rule (Get-PssaConfigurableRuleNames) gets an entry under its canonical name
    #     with Enable = $true, carrying the repository's other arguments for it; an entry the repository
    #     keyed in another case configured nothing (PSScriptAnalyzer matches Rules keys case-sensitively,
    #     measured), so it is replaced by the canonical one, with Enable alone;
    #   - any other rule the repository configures WITH an Enable key -- a custom configurable rule -- has
    #     that Enable set to $true under the repository's own key;
    #   - a built-in rule that is not configurable is left as written: PSScriptAnalyzer ignores Enable there.
    # Returns $Rules itself (possibly $null) when nothing needed forcing; never changes $Rules.
    param($Rules, [string[]]$RequiredRules)
    $configurable = @{}
    foreach ($n in @(Get-PssaConfigurableRuleNames)) { $configurable[$n] = $n }
    $builtin = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in @(Get-PssaBuiltinRuleNames)) { [void]$builtin.Add($n) }
    $out = @{}
    if ($null -ne $Rules) { foreach ($k in @($Rules.Keys)) { $out[$k] = $Rules[$k] } }
    $changed = $false
    foreach ($r in @($RequiredRules | Where-Object { $_ })) {
        $name = ([string]$r).Trim()
        if ($configurable.ContainsKey($name)) {
            $canon = [string]$configurable[$name]
            $entry = @{}
            foreach ($k in @($out.Keys)) {
                if (-not [string]::Equals([string]$k, $canon, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                if ([string]::Equals([string]$k, $canon, [System.StringComparison]::Ordinal) -and $out[$k] -is [System.Collections.IDictionary]) {
                    foreach ($a in @($out[$k].Keys)) {
                        if (-not [string]::Equals([string]$a, 'Enable', [System.StringComparison]::OrdinalIgnoreCase)) { $entry[$a] = $out[$k][$a] }
                    }
                }
                $out.Remove($k)
            }
            $entry['Enable'] = $true
            $out[$canon] = $entry
            $changed = $true
        } elseif (-not $builtin.Contains($name)) {
            foreach ($k in @($out.Keys)) {
                if (-not [string]::Equals([string]$k, $name, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                $t = $out[$k]
                if ($t -isnot [System.Collections.IDictionary]) { continue }
                if (@(@($t.Keys) | Where-Object { [string]::Equals([string]$_, 'Enable', [System.StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) { continue }
                $entry = @{}
                foreach ($a in @($t.Keys)) {
                    if (-not [string]::Equals([string]$a, 'Enable', [System.StringComparison]::OrdinalIgnoreCase)) { $entry[$a] = $t[$a] }
                }
                $entry['Enable'] = $true
                $out[$k] = $entry
                $changed = $true
            }
        }
    }
    if (-not $changed) { return $Rules }
    return $out
}

function Merge-RequiredRulesSettings {
    # Compute the MERGED PSSA settings hashtable that forces $RequiredRules onto PSES's analysis
    # pass, or $null when nothing should be merged (the caller then takes the untouched
    # pre-000294 path byte-for-byte). PURE: takes the already-resolved pre-change settings path
    # (or '' when none resolved) and reads it itself (Read-PssaSettingsFile) so the merge can be
    # unit-tested without a daemon -- or takes that read, already made, as $ResolvedSettings, so a
    # caller that validated the file merges exactly what it validated; writing the result to disk is
    # a SEPARATE step (Write-MergedPssaSettingsFile) so this function has no I/O side effect of its
    # own beyond the one read.
    #
    # ONLY WHAT PSSCRIPTANALYZER ACCEPTS IS CARRIED (dispatch 000306, B1b, review finding B1-K04). The
    # merge used to preserve a fixed key list -- Severities, CustomRulePath, RecurseCustomRulePath,
    # IncludeDefaultRules, RuleArguments, FilePath -- three of which PSScriptAnalyzer rejects, and it
    # dropped Rules and Severity, the keys it reads. So whenever RequiredRules merged, a repository's
    # Rules (the Enable flags and arguments of configurable rules -- dropping them silently turned a rule
    # like PSAvoidLongLines off) and its Severity vanished, and a repository file already holding a
    # rejected key produced a merged file PSScriptAnalyzer rejected: PSES then analyzed nothing and
    # published a settled, empty result. Now the repository file is read through Read-PssaSettingsFile
    # and exactly its ACCEPTED entries are carried -- every key of Get-PssaSettingsKeyNames whose value
    # PSScriptAnalyzer accepts; a rejected key or value is never written. An unparsable file is not
    # merged onto (as before: the merge then starts from PSES's own default list).
    #
    # Returns $null (meaning: do not merge, take the untouched path) when: $RequiredRules is
    # empty (the overwhelmingly common case -- org policy unset or names no required rule); OR
    # $CurrentPsesTag does not match Get-PssaDefaultRulesVerifiedForPsesTag AND the merge would use
    # PSES's default list -- no repo-local IncludeRules to merge onto, and no accepted settings file
    # whose own rule set it keeps (the guard: a stale default-rule list must never silently ship as
    # PSES's replacement rule set). A repo-local settings file WITH its own IncludeRules is trusted
    # as-is regardless of the PSES-tag guard, since in that case the merge never needs PSES's own
    # default list at all -- nor does one PSScriptAnalyzer accepts that names no IncludeRules (owner
    # ruling R03, below).
    #
    # PRECEDENCE, decided and tested here (no prior implementation to match -- new mechanism):
    # a rule named in BOTH $RequiredRules and $OrgExcludeRules (the SAME org policy contradicting
    # itself) is DROPPED from the merge for that one rule -- "exclusion stays the stronger verb",
    # the identical ordering SeverityOverrides already uses against ExcludeRules (a rule in both
    # lists is dropped, not re-stamped). A rule named in $RequiredRules but excluded only by the
    # REPO-LOCAL settings file's own ExcludeRules is FORCED ON regardless -- the org is the
    # OUTERMOST, centrally-managed voice (the existing org-policy-layer comment above), and that
    # voice already overrides repo-local on the exclude side; requiredRules extends the same
    # precedent to the include side rather than inventing an opposite one.
    #
    # Adversarial control: drop the PSES-tag guard and 'a stale default list is not silently
    # trusted' goes RED; drop the org-exclude-wins branch and 'a self-contradictory org policy
    # requires the excluded rule anyway' goes RED; drop the repo-local-exclude-loses branch and
    # 'org required beats repo-local excluded' goes RED; return the repo-local settings verbatim
    # when $RequiredRules is non-empty and 'a required rule not in the repo file is still added'
    # goes RED; write PSES's default list over an accepted settings file that names no IncludeRules
    # and the tests named 'B1b-R03:' go RED (dispatch 000306, correction round 2); strip only exact
    # names from the repository's ExcludeRules, write a required custom rule as 'Module\Name', or take
    # IncludeRules = @() for the repository's own list, and the tests named 'B1c-R01:', 'B1c-R02:' and
    # 'B1c-R03:' go RED (dispatch 000307); match or write an ExcludeRules entry trimmed and the tests named
    # 'B1c-RV04:' go RED (dispatch 000307, correction round 1); hand a module-qualified configurable built-in
    # rule to the Enable step as written and the tests named 'B1c-RR01:' go RED (dispatch 000307, correction
    # round 2).
    #
    # $GuardOut (dispatch 000305, B1) receives what the version guard decided, as evidence a managed
    # scan can certify on: 'pass' (the pinned default list was used and $CurrentPsesTag matched),
    # 'refused' (it did not, and the merge needed that list), 'not-needed' (the pinned list was not
    # used: a repo-local IncludeRules to merge onto, an accepted settings file whose own rule set the
    # merge keeps, or nothing was required).
    # Optional. NOTE: the guard is only as honest as $CurrentPsesTag -- its default is the verified
    # tag itself, which always passes; the daemon passes the PSES version it observes on disk.
    param(
        [string]$ResolvedSettingsPath = '',
        [string[]]$RequiredRules = @(),
        [string[]]$OrgExcludeRules = @(),
        [string]$CurrentPsesTag = (Get-PssaDefaultRulesVerifiedForPsesTag),
        [ref]$GuardOut,
        # Read-PssaSettingsFile's result for $ResolvedSettingsPath, when the caller already made it.
        $ResolvedSettings = $null
    )
    if ($null -ne $GuardOut) { $GuardOut.Value = 'not-needed' }
    $required = @($RequiredRules | Where-Object { $_ })
    if ($required.Count -eq 0) { return $null }

    $orgExcSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($e in @($OrgExcludeRules | Where-Object { $_ })) { [void]$orgExcSet.Add(([string]$e).Trim()) }

    # Load whatever repo-local settings would otherwise apply (or nothing): only the entries
    # PSScriptAnalyzer accepts (Read-PssaSettingsFile's Entries, under their canonical key names).
    $baseData = $null
    $read = $ResolvedSettings
    if ($null -eq $read -and -not [string]::IsNullOrWhiteSpace($ResolvedSettingsPath)) { $read = Read-PssaSettingsFile -Path $ResolvedSettingsPath }
    if ($null -ne $read -and [string]$read.Verdict -ne 'unparsable') { $baseData = $read.Entries }

    $hasRepoInclude = ($null -ne $baseData -and $baseData.Contains('IncludeRules'))
    # A SETTINGS FILE THAT NAMES NO IncludeRules KEEPS ITS OWN RULE SET (owner ruling R03, 2026-10-16;
    # review finding B1b-R03, pre-existing since dispatch 000294). For such a file PSScriptAnalyzer runs
    # EVERY enabled rule -- those its Rules entries switch on and its CustomRulePath rules included -- yet
    # the merge wrote PSES's 15 defaults plus the required rules as IncludeRules, so every other rule the
    # repository ran stopped running whenever RequiredRules named anything (measured: PSAvoidLongLines
    # switched on through Rules, PSAvoidUsingWriteHost, PSUseSingularNouns, a custom rule), while a
    # managed scan certified. So when the file is one PSScriptAnalyzer ACCEPTS and it names no
    # IncludeRules, the merged file names none either: every rule the repository ran still runs, and the
    # required ones run through the ExcludeRules strip, the forced Enable (R01) and IncludeDefaultRules
    # (K02) below. No settings file, a file naming its own IncludeRules, and a REJECTED file (refused by
    # PSScriptAnalyzer, so the session already falls back to PSES's defaults) merge exactly as before.
    #
    # AN IncludeRules WITH NO ENTRY IS NO IncludeRules (dispatch 000307, review finding B1b-OOB2-R03). To
    # PSScriptAnalyzer IncludeRules = @() reads exactly like a file that names none -- every enabled rule runs
    # (measured, both hosts) -- but the merge took it for the repository's own list, so the merged file named
    # the required rules ALONE as IncludeRules: every other rule the repository ran stopped running while a
    # managed scan certified. An accepted file whose IncludeRules has no entry now keeps its rule set as
    # above. A list of blank entries (@(''), which selects nothing) is still a list, and a rejected file with
    # an empty one still merges as before.
    $repoIncludeNone = ($hasRepoInclude -and @($baseData['IncludeRules']).Count -eq 0)
    $keepRuleSet = ((-not $hasRepoInclude -or $repoIncludeNone) -and $null -ne $read -and [string]$read.Verdict -eq 'valid')
    if (-not $hasRepoInclude -and -not $keepRuleSet -and $CurrentPsesTag -ne (Get-PssaDefaultRulesVerifiedForPsesTag)) {
        # The merge needs the pinned PSES default list (no IncludeRules to merge onto, and no
        # accepted settings file whose own rule set it keeps), and that list is not verified for
        # the tag actually in use: refuse to guess PSES's real default set. Degrade to "do not
        # merge" -- the caller logs ONE warning and requiredRules is not enforced this session,
        # exactly the fail-open-but-never-silent shape every other org-policy degrade in this
        # file already uses.
        if ($null -ne $GuardOut) { $GuardOut.Value = 'refused' }
        return $null
    }
    if ($null -ne $GuardOut) { $GuardOut.Value = $(if ($hasRepoInclude -or $keepRuleSet) { 'not-needed' } else { 'pass' }) }

    # The required rules the organization does not also exclude, as written, and the names PSScriptAnalyzer
    # matches them by (Get-PssaRuleMatchName: a custom rule's 'Module\Measure-Name' is 'Measure-Name').
    $active = New-Object System.Collections.ArrayList
    $activeNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($r in $required) {
        $rt = ([string]$r).Trim()
        if ([string]::IsNullOrWhiteSpace($rt) -or $orgExcSet.Contains($rt)) { continue }
        [void]$active.Add($rt)
        $mn = Get-PssaRuleMatchName $rt
        if (-not [string]::IsNullOrWhiteSpace($mn)) { [void]$activeNames.Add($mn) }
    }

    $include = New-Object System.Collections.ArrayList
    if (-not $keepRuleSet) {
        $seenInclude = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $baseIncludeList = if ($hasRepoInclude) { @($baseData['IncludeRules']) } else { @(Get-PssaDefaultRuleNames) }
        foreach ($r in $baseIncludeList) {
            if ($r -isnot [string]) { continue }
            $rt = $r.Trim()
            if ([string]::IsNullOrWhiteSpace($rt)) { continue }
            if ($seenInclude.Add($rt)) { [void]$include.Add($rt) }
        }
        # A required rule is named the way PSScriptAnalyzer matches it (dispatch 000307, review finding
        # B1b-OOB2-R02): a custom rule's 'Module\Measure-Name' -- how its findings, and so RequiredRules, name
        # it -- selects nothing in IncludeRules, so wherever the merged file named IncludeRules a required
        # custom rule never ran while a managed scan certified; its bare 'Measure-Name' selects it (measured,
        # both hosts). A built-in or bare code is written as before.
        foreach ($r in $required) {
            $rt = $r.Trim()
            if ([string]::IsNullOrWhiteSpace($rt)) { continue }
            if ($orgExcSet.Contains($rt)) { continue }   # org excludes it too: exclusion wins, skip
            $mn = Get-PssaRuleMatchName $rt
            if ([string]::IsNullOrWhiteSpace($mn)) { continue }
            if ($seenInclude.Add($mn)) { [void]$include.Add($mn) }
        }
    }

    $exclude = New-Object System.Collections.ArrayList
    if ($null -ne $baseData -and $baseData.Contains('ExcludeRules')) {
        $reqSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($r in $required) { [void]$reqSet.Add(([string]$r).Trim()) }
        $hasCustomPath = $baseData.Contains('CustomRulePath')
        $written = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $expanded = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($r in @($baseData['ExcludeRules'])) {
            if ($r -isnot [string]) { continue }
            $rt = $r.Trim()
            if ([string]::IsNullOrWhiteSpace($rt)) { continue }
            # A required rule is stripped from the merged ExcludeRules UNLESS org's own
            # ExcludeRules names it too (the self-contradiction branch above already kept it out
            # of $include in that case, so leaving it excluded here is consistent, not double
            # logic: $include and $exclude are asserted never to intersect on a required rule).
            if ($reqSet.Contains($rt) -and -not $orgExcSet.Contains($rt)) { continue }
            # ...and so is every entry PSScriptAnalyzer reads as naming one (dispatch 000307, review findings
            # B1b-OOB2-R01 and B1b-OOB2-R02). The strip compared exact names only, but the analyzer matches an
            # entry as a pattern ('*' is a wildcard), ignoring case, against a custom rule's BARE name -- so
            # 'PSAvoid*', '*' or a required custom rule's bare name kept a required rule excluded, beside the
            # repository's own IncludeRules and over a forced Enable alike (an exclusion wins), while a managed
            # scan certified. The entry is judged as it is written into the merged file -- exactly as the
            # repository gave it (below). One without
            # '*' names the rule itself and is taken out. A pattern is written instead as the built-in rules it
            # matches, minus the required ones: with no CustomRulePath those are the only rules the analysis
            # has, so the merged file still excludes every rule the repository's pattern did, a required one
            # aside. Beside a CustomRulePath the pattern may also match custom rules no static read can list,
            # so it is kept as written -- the required rule it shuts out is then reported as one that cannot
            # run (Get-RequiredRulesNotRunnable), and a managed scan refuses it (owner ruling RV-03, dispatch
            # 000307 correction round 1: refuse with policy-required-rule-cannot-run rather than narrow).
            #
            # EVERY ENTRY IS WRITTEN EXACTLY AS THE REPOSITORY GAVE IT, NEVER TRIMMED (dispatch 000307, correction
            # round 1; owner ruling RV-04, review finding B1c-RV-04, pre-existing since dispatch 000294). The merge
            # wrote each entry trimmed, while PSScriptAnalyzer reads one literally -- a surrounding blank is a
            # character to match -- so ExcludeRules = @(' PSAvoidUsingWriteHost '), which excludes nothing alone,
            # excluded PSAvoidUsingWriteHost once merged, and ' PSAvoid* ' was narrowed to every non-required
            # PSAvoid rule: rules the repository runs stopped running while a managed scan certified (measured,
            # both hosts). Now an entry is matched and written as given, so a padded one still names no rule once
            # merged. The trimmed form serves only the exact-name strip above, which still takes out an entry
            # spelled like a required code (a padded one names no rule, so that changes nothing that runs), and
            # the drop of a blank entry, which names none: every entry the merge took out before is still out.
            $hit = $false
            foreach ($n in $activeNames) { if (Test-PssaRuleNameMatch -Entry $r -Name $n) { $hit = $true; break } }
            if (-not $hit -or ($r.Contains('*') -and $hasCustomPath)) {
                if ($expanded.Contains($r)) { continue }   # a pattern above already wrote it
                [void]$written.Add($r)
                [void]$exclude.Add($r)
                continue
            }
            if (-not $r.Contains('*')) { continue }
            foreach ($b in @(Get-PssaBuiltinRuleNames)) {
                if ($activeNames.Contains($b) -or -not (Test-PssaRuleNameMatch -Entry $r -Name $b)) { continue }
                if ($written.Add($b)) { [void]$expanded.Add($b); [void]$exclude.Add($b) }
            }
        }
    }

    $merged = @{}
    if (-not $keepRuleSet) { $merged['IncludeRules'] = @($include) }
    if ($exclude.Count -gt 0) { $merged['ExcludeRules'] = @($exclude) }
    # Preserve every other ACCEPTED repo-local entry faithfully -- the Rules tables and all -- so the
    # merge changes ONLY which rules run, never how an already-running rule is configured, and writes
    # nothing PSScriptAnalyzer would refuse (dispatch 000306): the remaining keys of
    # Get-PssaSettingsKeyNames, and only the entries Read-PssaSettingsFile accepted.
    if ($null -ne $baseData) {
        foreach ($k in @(Get-PssaSettingsKeyNames)) {
            if ($k -eq 'IncludeRules' -or $k -eq 'ExcludeRules') { continue }
            if ($baseData.Contains($k)) { $merged[$k] = $baseData[$k] }
        }
    }
    # ...and REQUIRED RULES ARE FORCED ON (owner ruling R01, 2026-10-15; review finding B1b-R01). Carrying
    # the repository's Rules also carried any Enable = $false in them, which switches a configurable rule
    # off however IncludeRules names it: a second, unguarded way for the repository to drop a rule the
    # organization requires (its ExcludeRules, stripped above, is the first), while a managed scan still
    # certified. And a configurable rule that is off by default (PSAvoidLongLines and sixteen more) never
    # ran from IncludeRules alone. So every required rule the organization does not also exclude is
    # switched on in the Rules written (Set-PssaRequiredRulesEnabled); a merge whose required rules are
    # all non-configurable built-ins writes the Rules it carried, unchanged.
    #
    # A CONFIGURABLE BUILT-IN RULE REACHES THAT STEP BY ITS MATCH NAME (dispatch 000307, correction round 2;
    # review finding B1c-RR-01, owner ruling RR-01 as amended 2026-10-18). A required code that module-qualifies
    # a configurable built-in rule -- 'Foo\PSAvoidLongLines', 'X\PSUseSingularNouns' -- was named in IncludeRules
    # by its bare name but handed to that step as written, where it matched no configurable rule: off by default
    # it never ran, and over a repository's Enable = $false it stayed off, while a managed scan certified
    # (measured through the real daemon, both hosts). Such a code now reaches the step by its match name
    # (Get-PssaRuleMatchName), looked up as the step looks it up, and is switched on exactly as its bare spelling
    # is. Every other code goes as written, as before: a custom rule's Enable is still forced only under the key
    # the repository wrote.
    $configurable = @{}
    foreach ($n in @(Get-PssaConfigurableRuleNames)) { $configurable[$n] = $n }
    $enable = @($active | ForEach-Object { $en = Get-PssaRuleMatchName ([string]$_); if ($configurable.ContainsKey($en)) { $en } else { [string]$_ } })
    $rules = Set-PssaRequiredRulesEnabled -Rules $(if ($merged.ContainsKey('Rules')) { $merged['Rules'] } else { $null }) -RequiredRules $enable
    if ($null -ne $rules) { $merged['Rules'] = $rules }
    # ...and a required BUILT-IN rule runs beside a carried CustomRulePath (owner ruling K02, 2026-10-15;
    # review finding B1b-K02, pre-existing since dispatch 000294). With a CustomRulePath and no
    # IncludeDefaultRules = $true, PSScriptAnalyzer loads ONLY the custom rules, so no built-in rule
    # IncludeRules names -- a required one included -- ever ran (measured: such a merged file analyzed
    # nothing at all, and a managed scan certified). So whenever one of them is a built-in rule
    # (Get-PssaBuiltinRuleNames), the merge sets IncludeDefaultRules = $true, over a repository's $false.
    if ($merged.ContainsKey('CustomRulePath')) {
        $builtin = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($n in @(Get-PssaBuiltinRuleNames)) { [void]$builtin.Add($n) }
        foreach ($rt in @($active)) {
            if ($builtin.Contains((Get-PssaRuleMatchName ([string]$rt)))) { $merged['IncludeDefaultRules'] = $true; break }
        }
    }
    return $merged
}

function ConvertTo-MergedPssaSettingsText {
    # The exact .psd1 text Write-MergedPssaSettingsFile writes, as a PURE function (dispatch 000305,
    # B1): the same settings always render the same text -- fixed key order, LF line ends, and
    # nested tables in sorted key order (ConvertTo-Psd1Literal) -- so the SHA-256 of the bytes written
    # for it (ConvertTo-MergedPssaSettingsBytes) can name the file and identify, as evidence, the
    # settings PSES was handed.
    # ONLY KEYS PSSCRIPTANALYZER ACCEPTS are rendered (dispatch 000306): the old list wrote Severities,
    # RuleArguments and FilePath, which it rejects, and never Severity or Rules, which it reads. The
    # order keeps IncludeRules and ExcludeRules first, so a merge of those two alone -- the common one
    # -- renders byte-for-byte the text, and so the file name, it always had.
    param([hashtable]$Settings)
    if ($null -eq $Settings) { return '' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('# GENERATED by Write-MergedPssaSettingsFile (dispatch 000294). DO NOT EDIT.').Append("`n")
    [void]$sb.Append('@{').Append("`n")
    foreach ($key in @('IncludeRules', 'ExcludeRules', 'Severity', 'CustomRulePath', 'RecurseCustomRulePath', 'IncludeDefaultRules', 'Rules')) {
        if (-not $Settings.ContainsKey($key)) { continue }
        [void]$sb.Append('    ' + $key + ' = ' + (ConvertTo-Psd1Literal $Settings[$key])).Append("`n")
    }
    [void]$sb.Append('}').Append("`n")
    return $sb.ToString()
}

function ConvertTo-MergedPssaSettingsBytes {
    # The exact BYTES Write-MergedPssaSettingsFile writes for $Text (ConvertTo-MergedPssaSettingsText's output),
    # as a PURE function (dispatch 000308, B1d): the text as UTF-8, opened with the UTF-8 byte order mark
    # (EF BB BF) exactly when it holds a character outside ASCII.
    #
    # WHY THE MARK (owner ruling RR-02; review findings B1c-RR-02 and B1c-RX-12). Windows PowerShell 5.1 reads a
    # settings file that has no byte order mark in the system ANSI code page (Windows-1252 on a US or
    # Western-European system) -- PSScriptAnalyzer, and the daemon's own check, parse it with the host's parser,
    # which falls back to the system code page there, where PowerShell 7 falls back to UTF-8 -- so a non-ASCII
    # character a repository wrote in a rule list reached a 5.1 analysis as two or three other characters once
    # merged: an IncludeRules entry spelling PSMisleadingBacktick with the Kelvin sign selected nothing (a managed
    # scan certified without that rule), the same entry in ExcludeRules stopped excluding, and a CustomRulePath
    # directory named with an accent read as a path that does not exist (a false policy-settings-rejected). With
    # the mark both hosts read the file as UTF-8 (measured, both hosts, through the real daemon).
    #
    # WHY ONLY THEN. An all-ASCII text reads the same on both hosts with the mark or without it (measured), so it
    # is written exactly as before: its bytes, and so its content-addressed name, are unchanged -- and every
    # merged text B1b and B1c pinned is ASCII. Each character is compared by its code (above 0x7F), never by a
    # case-insensitive match, which lets the Kelvin sign through as a 'k'.
    param([string]$Text)
    if ($null -eq $Text) { $Text = '' }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $body = $utf8.GetBytes($Text)
    $outside = $false
    foreach ($ch in $Text.ToCharArray()) {
        if ([int]$ch -gt 0x7F) { $outside = $true; break }
    }
    if (-not $outside) { return , $body }
    $bytes = New-Object byte[] ($body.Length + 3)
    $bytes[0] = 0xEF; $bytes[1] = 0xBB; $bytes[2] = 0xBF
    [System.Array]::Copy($body, 0, $bytes, 3, $body.Length)
    return , $bytes
}

function Get-MergedPssaSettingsDir {
    # Where merged settings files live (dispatch 000305): their own directory under the data root,
    # so the file a daemon hands PSES is never one another daemon rewrites (see below).
    param([string]$DataRoot)
    return (Join-Path $DataRoot 'orgpolicy-settings')
}

function Write-MergedPssaSettingsFile {
    # I/O half of the requiredRules merge: serialize $Settings (Merge-RequiredRulesSettings's
    # return value) as a .psd1 under $DataRoot and return its absolute path, or '' on any
    # failure (fail-open -- the caller falls back to the untouched pre-change path exactly as it
    # would for a $null merge result). NEVER writes into the repo-local settings file itself:
    # this is always a NEW file under the plugin's own per-session data root, so a live edit can
    # never corrupt a file the user or the repo owns.
    #
    # CONTENT-ADDRESSED AND VERIFIED (dispatch 000305, B1). The file used to be one fixed name in the
    # data root, which every daemon sharing that root rewrote -- and PSES hands the settings PATH to
    # PSScriptAnalyzer on every analysis, so a second daemon with a different policy (a scan run
    # beside an interactive session, say) silently changed what the first one enforced. The name now
    # carries the SHA-256 of the exact bytes written (ConvertTo-MergedPssaSettingsBytes: the text, opened
    # with a UTF-8 byte order mark when it holds a character outside ASCII -- dispatch 000308, B1d -- so an
    # all-ASCII text keeps the name it always had), so two different settings can never share a file and
    # the same settings always do; the bytes are written to a temp file and renamed into place, and
    # the file is read back and re-hashed before its path is returned. A path is therefore returned
    # only when the bytes on disk are the bytes this call meant to write -- which is what lets the
    # daemon report a successful merged-settings write as evidence rather than as a hope. A text
    # outside ASCII that a daemon before dispatch 000308 wrote without the mark has another name, so
    # neither writer ever rewrites the other's file.
    #
    # A LOST RENAME IS NOT A FAILED WRITE. Two daemons on one data root that write the same NEW text
    # can both find no file, and then the second rename throws because the first one's file is already
    # in place. The name is the digest of the bytes written, so that file is accepted -- but only as a FILE, and only
    # when it re-hashes to the intended text below; a directory or any other failure still returns ''.
    #
    # OLD FILES ARE SWEPT, NEVER ONE IN USE (dispatch 000306, B1b, review finding B1-K07). One file per
    # distinct merged text used to accumulate, and the pre-000305 fixed file sat orphaned beside them.
    # After a successful write (or reuse) this calls Remove-StaleMergedPssaSettings, which removes only
    # files no LIVE daemon on this data root is using, past a grace window -- PSES hands the settings
    # PATH to PSScriptAnalyzer on every pass, so removing another daemon's file would make its every
    # later analysis come back empty. A reused file has its write time refreshed, so the grace window
    # also covers the seconds before this daemon's session record names it. $SweptOut (optional)
    # receives the paths removed; a sweep never changes this function's result.
    param([hashtable]$Settings, [string]$DataRoot, [ref]$SweptOut)
    if ($null -ne $SweptOut) { $SweptOut.Value = @() }
    if ($null -eq $Settings -or [string]::IsNullOrWhiteSpace($DataRoot)) { return '' }
    $tmp = ''
    $path = ''
    try {
        $dir = Get-MergedPssaSettingsDir -DataRoot $DataRoot
        New-ContainedDirectory -Path $dir
        $bytes = ConvertTo-MergedPssaSettingsBytes -Text (ConvertTo-MergedPssaSettingsText -Settings $Settings)
        $sha = Get-Sha256HexFromBytes -Bytes $bytes
        $target = Join-Path $dir ('merged-settings-' + $sha.Substring(0, 16) + '.psd1')
        $reused = $false
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            # Already written by this or another daemon -- identical text, so identical name.
            if ((Get-Sha256HexFromBytes -Bytes ([System.IO.File]::ReadAllBytes($target))) -ceq $sha) {
                $reused = $true
                try { [System.IO.File]::SetLastWriteTimeUtc($target, [DateTime]::UtcNow) } catch { }
            } else {
                [System.IO.File]::Delete($target)
            }
        }
        if (-not $reused) {
            $tmp = $target + '.' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp'
            [System.IO.File]::WriteAllBytes($tmp, $bytes)
            try {
                [System.IO.File]::Move($tmp, $target)
                $tmp = ''
            } catch {
                # A concurrent writer renamed first (see above); the finally removes this call's temp file.
                if (-not [System.IO.File]::Exists($target)) { throw }
                try { [System.IO.File]::SetLastWriteTimeUtc($target, [DateTime]::UtcNow) } catch { }
            }
            if ((Get-Sha256HexFromBytes -Bytes ([System.IO.File]::ReadAllBytes($target))) -cne $sha) { return '' }
        }
        $path = $target
    } catch {
        return ''
    } finally {
        if (-not [string]::IsNullOrWhiteSpace($tmp)) {
            try { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } } catch { }
        }
    }
    $swept = Remove-StaleMergedPssaSettings -DataRoot $DataRoot -KeepPath $path
    if ($null -ne $SweptOut) { $SweptOut.Value = $swept }
    return $path
}

function Get-LegacyMergedPssaSettingsPath {
    # The ONE fixed file the layout before dispatch 000305 wrote, beside everything else in the data
    # root, which every daemon sharing that root rewrote. Content-addressed files replaced it.
    param([string]$DataRoot)
    return (Join-Path $DataRoot 'orgpolicy-merged-settings.psd1')
}

function Get-MergedPssaSettingsInUse {
    # Which merged settings files LIVE daemons on $DataRoot are using, read from their own session
    # records (<data root>/session/*.json -- the handle session-start's reap and doctor already use,
    # with the same liveness notion: the recorded pid is running). A record names its file twice, as
    # policy.settings.path (what it handed PSES) and policy.requiredRules.mergedSettingsPath. Returns
    #   Names        the FILE NAMES named by live records -- names, not paths: every daemon recorded
    #                here writes into this data root's orgpolicy-settings/, the name is the content's
    #                digest, and one data root can be spelled two ways (a short 8.3 TEMP, say), so a
    #                path comparison could miss a file that is in use;
    #   LegacyInUse  $true when a live record carries NO policy block -- a daemon from before dispatch
    #                000305, which may be handing PSES the legacy fixed file;
    #   Complete     $false when a record could not be read (a daemon may be rewriting it): then nobody
    #                can say what is in use, and the caller must not remove anything.
    # A pid that is reused by an unrelated process reads as live: that only keeps a file longer.
    param([string]$DataRoot)
    $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $legacy = $false
    $complete = $true
    $sessionDir = Join-Path $DataRoot 'session'
    if (Test-Path -LiteralPath $sessionDir -PathType Container) {
        foreach ($f in @(Get-ChildItem -LiteralPath $sessionDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            $rec = $null
            try { $rec = ([System.IO.File]::ReadAllText($f.FullName)) | ConvertFrom-Json } catch { $rec = $null }
            if ($null -eq $rec) { $complete = $false; continue }
            $recPid = 0
            try { $recPid = [int](Get-Prop $rec 'pid') } catch { $recPid = 0 }
            if ($recPid -le 0 -or $null -eq (Get-Process -Id $recPid -ErrorAction SilentlyContinue)) { continue }
            $pol = Get-Prop $rec 'policy'
            if ($null -eq $pol) { $legacy = $true; continue }
            foreach ($p in @((Get-Prop (Get-Prop $pol 'settings') 'path'), (Get-Prop (Get-Prop $pol 'requiredRules') 'mergedSettingsPath'))) {
                $s = [string]$p
                if ([string]::IsNullOrWhiteSpace($s)) { continue }
                try { [void]$paths.Add([System.IO.Path]::GetFileName($s)) } catch { }
            }
        }
    }
    return @{ Names = $paths; LegacyInUse = $legacy; Complete = $complete }
}

function Remove-StaleMergedPssaSettings {
    # Remove the merged settings files on $DataRoot that nothing uses any more (dispatch 000306, B1b,
    # review finding B1-K07), and return their paths (comma-returned: assign, then wrap). Removes ONLY:
    #   - a FILE directly in orgpolicy-settings/ named merged-settings-<16 hex>.psd1 (or the
    #     .<8 hex>.tmp a crashed writer left), and
    #   - the one legacy file <data root>/orgpolicy-merged-settings.psd1,
    # and of those only one that is not $KeepPath, is not named by a live daemon's session record
    # (Get-MergedPssaSettingsInUse), and was last written more than $GraceMinutes ago. The legacy file
    # also stays while a live daemon from before dispatch 000305 might be using it. Never anything
    # outside orgpolicy-settings/ or that one file, never a directory, never a link or anything through
    # one, and nothing at all when a session record cannot be read. Best-effort: never throws.
    param([string]$DataRoot, [string]$KeepPath = '', [int]$GraceMinutes = 10)
    $removed = New-Object 'System.Collections.Generic.List[string]'
    if ([string]::IsNullOrWhiteSpace($DataRoot)) { return , $removed.ToArray() }
    try {
        $use = Get-MergedPssaSettingsInUse -DataRoot $DataRoot
        if (-not [bool]$use.Complete) { return , $removed.ToArray() }
        $keep = $use.Names
        if (-not [string]::IsNullOrWhiteSpace($KeepPath)) { try { [void]$keep.Add([System.IO.Path]::GetFileName($KeepPath)) } catch { } }
        $cutoff = [DateTime]::UtcNow.AddMinutes(-1 * [Math]::Max(0, $GraceMinutes))
        $link = [System.IO.FileAttributes]::ReparsePoint
        $dir = Get-MergedPssaSettingsDir -DataRoot $DataRoot
        if ([System.IO.Directory]::Exists($dir)) {
            $di = New-Object System.IO.DirectoryInfo($dir)
            if (($di.Attributes -band $link) -eq 0) {
                foreach ($fi in @($di.GetFiles())) {
                    $named = [regex]::IsMatch($fi.Name, '\Amerged-settings-[0-9a-f]{16}\.psd1(\.[0-9a-f]{8}\.tmp)?\z')
                    if (-not $named) { continue }
                    if (($fi.Attributes -band $link) -ne 0) { continue }
                    if ($keep.Contains($fi.Name)) { continue }
                    if ($fi.LastWriteTimeUtc -gt $cutoff) { continue }
                    try { $fi.Delete(); $removed.Add($fi.FullName) } catch { }
                }
            }
        }
        $legacyPath = Get-LegacyMergedPssaSettingsPath -DataRoot $DataRoot
        if (-not [bool]$use.LegacyInUse -and [System.IO.File]::Exists($legacyPath)) {
            $li = New-Object System.IO.FileInfo($legacyPath)
            if (($li.Attributes -band $link) -eq 0 -and $li.LastWriteTimeUtc -le $cutoff) {
                try { $li.Delete(); $removed.Add($li.FullName) } catch { }
            }
        }
    } catch { }
    return , $removed.ToArray()
}

function ConvertTo-Psd1Literal {
    # A minimal, ROUND-TRIP-SAFE .psd1 literal renderer for exactly the value shapes a PSSA
    # settings hashtable carries: string, bool, a number, an array, or a nested hashtable
    # (the Rules tables). Not a general-purpose serializer -- an unrecognized shape renders as
    # $null rather than a guess that could silently change meaning (and a merged file holding such a
    # $null fails the daemon's validation instead of reaching PSES: PSScriptAnalyzer refuses a $null
    # in a table).
    # A nested table renders in SORTED key order (dispatch 000305): a [hashtable]'s own order is
    # not stable across processes, and the merged-settings file is named by the SHA-256 of the bytes written.
    # Since dispatch 000306 the Rules tables are carried, so a nested key that is not a plain
    # identifier (a custom rule's 'Module\Measure-Name') is single-quoted rather than written bare, and
    # -- review finding B1b-I01 -- every primitive NUMBER a rule argument can hold keeps its type and its
    # value, written in the invariant culture: an [int] as a plain literal (its own type); a [decimal] as
    # a d-suffixed literal (PSScriptAnalyzer refuses a [decimal] cast -- decimal is no .NET primitive,
    # measured); every other ([long], [double], [single], [byte], [sbyte], [int16], [uint16], [uint32],
    # [uint64]) behind a cast of its text -- [uint32]'120', [double]'1.5' (17 significant digits for a
    # double and 9 for a single, which always round-trip, where .NET Framework's 'R' format may not; NaN
    # and 1E+300 survive too). Each form was measured accepted by PSScriptAnalyzer and read back with its
    # type on both hosts. A [char] or a BigInteger is no primitive number and still renders $null.
    # EVERY CHARACTER POWERSHELL READS AS A SINGLE QUOTE IS DOUBLED (dispatch 000308, B1d correction round 1;
    # owner ruling RV-01, review finding B1d-RV-01). PowerShell's parser ends a single-quoted string at U+2018,
    # U+2019, U+201A and U+201B as it does at U+0027, and reads any of them doubled as one of itself (measured,
    # both hosts). Only U+0027 was doubled, so a string holding one of the other four re-parsed once merged as
    # other data or as none: one ExcludeRules entry 'PSAvoidUsingWriteHost' + U+2019 + ',' + U+2019 +
    # 'PSAvoidUsingCmdletAliases', which excludes nothing alone, excluded both rules once merged and a managed
    # scan certified with their findings hidden, and a CustomRulePath whose directory name holds one made the
    # merged file unparsable, a false policy-settings-rejected (measured through the real daemon, both hosts).
    # Each of the five is now doubled, in a string value and in a quoted Rules key alike; a text holding none of
    # them is written byte for byte as before.
    param($Value)
    if ($null -eq $Value) { return '$null' }
    if ($Value -is [bool]) { return $(if ($Value) { '$true' } else { '$false' }) }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Value -is [int]) { return $Value.ToString($inv) }
    if ($Value -is [decimal]) { return ($Value.ToString($inv) + 'd') }
    $cast = ''
    if ($Value -is [long]) { $cast = 'long' }
    elseif ($Value -is [double]) { $cast = 'double' }
    elseif ($Value -is [single]) { $cast = 'single' }
    elseif ($Value -is [byte]) { $cast = 'byte' }
    elseif ($Value -is [sbyte]) { $cast = 'sbyte' }
    elseif ($Value -is [int16]) { $cast = 'int16' }
    elseif ($Value -is [uint16]) { $cast = 'uint16' }
    elseif ($Value -is [uint32]) { $cast = 'uint32' }
    elseif ($Value -is [uint64]) { $cast = 'uint64' }
    if ($cast -ne '') {
        $text = if ($Value -is [double]) { $Value.ToString('G17', $inv) } elseif ($Value -is [single]) { $Value.ToString('G9', $inv) } else { $Value.ToString($inv) }
        return ('[' + $cast + "]'" + $text + "'")
    }
    if ($Value -is [string]) { return "'" + [regex]::Replace($Value, '[''\u2018-\u201B]', '$0$0') + "'" }
    if ($Value -is [System.Collections.IDictionary]) {
        $parts = New-Object System.Collections.ArrayList
        $keys = @(@($Value.Keys) | ForEach-Object { [string]$_ })
        [System.Array]::Sort($keys, [System.StringComparer]::OrdinalIgnoreCase)
        foreach ($k in $keys) {
            $shown = $(if ([regex]::IsMatch($k, '\A[A-Za-z_][A-Za-z0-9_]*\z')) { $k } else { "'" + [regex]::Replace($k, '[''\u2018-\u201B]', '$0$0') + "'" })
            [void]$parts.Add('        ' + $shown + ' = ' + (ConvertTo-Psd1Literal $Value[$k]))
        }
        return "@{`n" + ($parts -join "`n") + "`n    }"
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = @($Value | ForEach-Object { ConvertTo-Psd1Literal $_ })
        return '@(' + ($items -join ', ') + ')'
    }
    return '$null'   # unrecognized shape: never guess
}


function Set-DiagnosticSeverity {
    # Return $Record with its severity re-stamped, across every shape the client's stream carries.
    #
    # This exists for the same reason Get-DiagnosticRuleCode does, and the reason is not
    # cosmetic: the stream mixes [pscustomobject] (JSON-parsed daemon records and the pre-PSSA
    # finding shape) with [hashtable] and the [ordered] hashtable ConvertTo-DiagRecord returns,
    # and no single assignment idiom reaches all three. Writing through the wrong one would
    # silently no-op, and an enforcement layer that silently stops enforcing is the one failure
    # it cannot afford.
    #
    # severityNum is re-stamped TOO, from the same vocabulary. The record shape carries both a
    # name and the LSP numeric level, and they mean the same thing; moving one and leaving the
    # other is a guard measuring a proxy of itself, and a downstream consumer that reads the
    # number would see the pre-override level while the name claimed otherwise.
    #
    # The record is COPIED, never mutated. The diagnostics stream is also handed to the dogfood
    # capture and to the SARIF scan, so mutating a shared record in place would re-stamp it for
    # a consumer that never asked. Copy semantics are what make this function pure.
    param([object]$Record, [string]$Severity)
    if ($null -eq $Record) { return $Record }
    $rank = Get-SeverityRank $Severity
    if ($Record -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($k in @($Record.Keys)) { $copy[$k] = $Record[$k] }
        $copy['severity'] = $Severity
        if ($Record.Contains('severityNum')) { $copy['severityNum'] = $rank }
        return $copy
    }
    $copy = $Record.PSObject.Copy()
    if ($null -ne $copy.PSObject.Properties['severity']) { $copy.severity = $Severity }
    else { Add-Member -InputObject $copy -NotePropertyName 'severity' -NotePropertyValue $Severity -Force }
    if ($null -ne $copy.PSObject.Properties['severityNum']) { $copy.severityNum = $rank }
    return $copy
}

function Set-OrgPolicySeverity {
    # THE ORG'S INCLUDE-SIDE IMPOSITION (Policy v2, dispatch 000289, ruling R9). Re-stamps the
    # severity of every record whose rule code the org overrides, and leaves every other record
    # -- and every other field of the overridden ones -- untouched.
    #
    # WHY THIS IS THE INCLUDE SIDE. The v1 payload is subtract-only: an org can take a rule away,
    # it cannot ask for one, and the enterprise review's argument was that a subtract-only
    # payload cannot express an org REQUIREMENT. It is right. This is the requirement half the
    # client seam can actually enforce: because it runs after every local filter, in the same
    # final position as the org drop, no repo-local settings file and no `ruleInclude` knob can
    # put the severity back.
    #
    # ORDER: it runs AFTER Select-OrgPolicyFiltered, and the order is load-bearing. Exclusion is
    # the stronger verb -- a rule the org excludes is gone, and re-stamping a record that is
    # about to be dropped is work with no observable effect. Dropping first also means an org
    # that both excludes and overrides one rule gets the exclusion, which is the only reading
    # that keeps "org exclude is final" true.
    #
    # THE BOUNDARY, NAMED RATHER THAN GLOSSED: this re-stamps a record that is ALREADY on the
    # surface. It cannot resurrect one the daemon's own severity threshold dropped before the
    # client ever saw it. At the shipped default threshold (Hint -- the LEAST severe level)
    # nothing is threshold-dropped and the override is fully effective; a site that RAISES its
    # local threshold can still hide a rule the org wanted raised. Closing that gap means moving
    # the org layer into the daemon's own filter, which is a different slice with a real freeze
    # cost. docs/configuration.md says so in the same words.
    #
    # An empty $OrgSeverity makes this the IDENTITY function -- that is what keeps the knob-off
    # surface, and a v1 policy's surface, byte-identical. Matching is on Get-DiagnosticRuleCode,
    # the same accessor the drop uses, so the two halves of the payload cannot disagree about
    # what a record's rule is; comparison is case-insensitive, as PSScriptAnalyzer's own matching
    # is. A record with NO code is never re-stamped: an org rule list names rules, and a parser
    # error is not a rule.
    #
    # Adversarial control: run this BEFORE the drop and 'org exclude wins over an override of
    # the same rule' goes RED; make the comparison ordinal-case-sensitive and 'matches a rule
    # code case-insensitively' goes RED; re-stamp a record carrying no code and 'never re-stamps
    # a record with no code' goes RED; return $Records unconditionally and every override
    # assertion goes RED.
    param([object[]]$Records, [hashtable]$OrgSeverity = @{})
    if ($null -eq $Records) { return @() }
    if ($null -eq $OrgSeverity -or $OrgSeverity.Count -eq 0) { return @($Records) }
    $map = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($k in @($OrgSeverity.Keys)) {
        if ($null -eq $k) { continue }
        $canon = Resolve-SeverityName ([string]$OrgSeverity[$k])
        if ($canon -eq '') { continue }
        $rule = ([string]$k).Trim()
        if ([string]::IsNullOrWhiteSpace($rule)) { continue }
        $map[$rule] = $canon
    }
    if ($map.Count -eq 0) { return @($Records) }
    $out = @()
    foreach ($r in $Records) {
        $code = Get-DiagnosticRuleCode $r
        if ([string]::IsNullOrWhiteSpace($code) -or -not $map.ContainsKey($code)) { $out += $r; continue }
        $out += (Set-DiagnosticSeverity -Record $r -Severity $map[$code])
    }
    return @($out)
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
        if (-not (Test-Path -LiteralPath $dir)) { New-ContainedDirectory -Path $dir }
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
        # Contain on the absent->present transition only (000277 leg C): the first write
        # creates the file, so that is the one call that has to set 0600. Every later
        # append finds it present and never reaches chmod, so the per-edit path is unchanged.
        $bornHere = -not (Test-Path -LiteralPath $statsFile)
        [System.IO.File]::AppendAllText($statsFile, ($line + "`n"), $enc)
        if ($bornHere) { [void](Set-ContainedFileMode -Path $statsFile) }
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
# THE NEVER-COMMIT FENCE: the log holds REAL source snippets. Since the T2.3 relocation below
# it lands under CLAUDE_PLUGIN_DATA -- outside every git tree -- so it is structurally
# uncommittable rather than merely gitignored. The `/dogfood/` .gitignore entry is retained to
# keep pre-relocation logs already sitting in a checkout covered.

function Get-DogfoodDir {
    # The directory the capture log and its rotated members live in.
    return (Join-Path (Get-PluginDataRoot) 'dogfood')
}

function Get-DogfoodLogPath {
    # Resolve the dogfood capture log path. Precedence:
    #   1. $env:POWERSHELL_LSP_DOGFOOD_LOG -- an explicit full-path override (a test seam and
    #      an advanced-relocation escape hatch). Honored verbatim.
    #   2. <data-root>/dogfood/diagnostics.jsonl -- the default.
    #
    # T2.3 (threat model section 8, ruled FIX 2026-08-21): this used to resolve under the
    # PLUGIN ROOT by walking up from this lib's dir. That made the plugin tree -- documented as
    # read-only by ARCHITECTURE.md ("Where state lives"), by TRUST.md, and by this very file's
    # own header ("Never under CLAUDE_PLUGIN_ROOT (read-only plugin tree)") -- written at
    # runtime on every surfaced diagnostic. The contradiction was real in both directions: a
    # reviewer allow-listing the plugin root by path was told it was read-only, and a reader
    # looking for captured snippets under the data root would not find them.
    #
    # Relocation, not a documentation edit, is the fix that makes all three statements true.
    #
    # A SECOND DEFECT CLOSES WITH IT. Under the old resolution the log lived in whichever
    # plugin tree was running, so every marketplace-cache upgrade started an EMPTY log and
    # stranded the previous one at <cache>/powershell-lsp/<version>/dogfood/. Accrual for the
    # rule-curation lane fragmented across version roots by construction. The data root does
    # not carry a version segment, so captures now accrue in ONE place across upgrades.
    #
    # Pre-relocation logs are neither moved nor deleted: Get-LegacyDogfoodLogPath below and the
    # reader's `cache` source still reach them read-only. A write-time migration was rejected --
    # this is a fail-safe side channel that must never throw, and copying multi-megabyte user
    # data on a hook path to satisfy tidiness is the wrong trade (the live dev-clone log
    # measured 5,279,427 bytes / 10,161 rows on 2026-08-21).
    $override = $env:POWERSHELL_LSP_DOGFOOD_LOG
    if (-not [string]::IsNullOrWhiteSpace($override)) { return $override }
    $dir = ''
    try { $dir = Get-DogfoodDir } catch { $dir = '' }
    if ([string]::IsNullOrWhiteSpace($dir)) { return '' }
    return (Join-Path $dir 'diagnostics.jsonl')
}

function Get-LegacyDogfoodLogPath {
    # The PRE-T2.3 capture-log location: <plugin-root>/dogfood/diagnostics.jsonl, with the root
    # resolved the SAME way as Get-PluginManifestPath (walk up from this lib's dir: scripts/lib
    # -> scripts -> root; fall back to $env:CLAUDE_PLUGIN_ROOT). Returns '' when the root cannot
    # be resolved.
    #
    # READ-ONLY BY CONTRACT. Nothing writes here any more. It exists so the reader's `checkout`
    # source keeps reaching a running tree's historical captures instead of reporting a false
    # zero -- the exact failure mode the reader's own 000088 header warns about. Kept as a
    # separate function rather than a flag so the write-side resolver has exactly one answer.
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

function Get-CaptureLogRotateBytes {
    # The size at which the capture log rotates (T6.4). Default 8 MB; overridable through
    # $env:POWERSHELL_LSP_CAPTURE_ROTATE_BYTES, which is a TEST SEAM in the same family as
    # POWERSHELL_LSP_DOGFOOD_LOG -- deliberately an env var and NOT a userConfig knob, because
    # the knob names are a drift-guarded public contract and because T6.1 is ACCEPTED-WITH-
    # RECORD: nothing here may become a gate on the capture channel itself. A non-numeric or
    # non-positive value falls back to the default rather than disabling the bound.
    $default = 8MB
    $raw = $env:POWERSHELL_LSP_CAPTURE_ROTATE_BYTES
    if ([string]::IsNullOrWhiteSpace($raw)) { return $default }
    $parsed = 0L
    if (-not [long]::TryParse($raw, [ref]$parsed)) { return $default }
    if ($parsed -le 0) { return $default }
    return $parsed
}

# --- daemon IPC protocol handshake (dispatch 000282 leg F; ruling R15) ------
# P1-4 of ENTERPRISE-PROGRAM-DOCKET section 4.3. The daemon IPC has never carried a version, so a
# client and a daemon from different installs could only discover a mismatch by misbehaving. The
# handshake is deliberately the SMALLEST additive shape that makes P1-2 negotiable later:
#
#   * every request carries protocolVersion and a capabilities object;
#   * every response carries the DAEMON's own protocolVersion and capabilities;
#   * a request with NO protocolVersion is version 1, so every existing client keeps working
#     byte-identically -- that is what makes this additive rather than breaking;
#   * a request carrying a version the daemon does not know is ANSWERED, never refused: the daemon
#     replies with its own version and capabilities and processes the request as version 1. A
#     refusal would make the first version bump a flag day, which is the failure this exists to
#     prevent. Forward compatibility is the whole point of announcing a version at all.
#
# NOT a Tier 1 surface. CONTRACT.md freezes exactly two enumerable surfaces -- the twenty
# userConfig knob names and the diagnostics status token set. The IPC is neither, so this costs
# ZERO freeze exposure. Confirmed against CONTRACT.md rather than assumed.
#
# THE VERSION LIVES HERE, ONCE. Client, daemon and doctor all dot-source this file, so there is
# exactly one place the integer is written (Hub Rule 18).

function Get-LspProtocolVersion {
    # The wire protocol version this build speaks. Bump ONLY for a change a peer must know about.
    return 1
}

function Resolve-RequestProtocolVersion {
    # The version a REQUEST claims. Absent, empty, non-numeric or non-positive all read as 1 --
    # version 1 is precisely "the protocol as it was before anyone announced a version", which is
    # what every pre-000282 client speaks. This never refuses and never throws.
    param($Request)
    $raw = $null
    try { $raw = Get-Prop $Request 'protocolVersion' } catch { $raw = $null }
    if ($null -eq $raw) { return 1 }
    $parsed = 0
    if (-not [int]::TryParse([string]$raw, [ref]$parsed)) { return 1 }
    if ($parsed -le 0) { return 1 }
    return $parsed
}

function Get-LspClientCapabilities {
    # What a CLIENT of this daemon can make use of, derived from what the shipped client actually
    # reads off a response -- never a wish list. Both request-building callers (lsp-client.ps1 and
    # the doctor's check-11 probe) send this, so one client cannot claim more than another.
    return [ordered]@{
        touchedRanges = $true      # the client derives and sends edit ranges (dispatch 000019)
        jsonResponse  = $true      # it parses the response as one line of JSON, nothing else
    }
}

function Get-DiagnosticCaptureModeInfo {
    # Resolve $env:POWERSHELL_LSP_CAPTURE_MODE into the three facts both consumers need
    # (P0-2, ruling R8 of 2026-09-05; the fleet-visible half is ruling R19):
    #   resolved    'full' | 'metadata' | 'off' -- what the writer obeys.
    #   raw         the environment value verbatim, '' when unset. NEVER interpreted.
    #   recognized  $true when raw named one of the three modes, $false otherwise.
    #
    # ONE function owns the vocabulary so the writer and the doctor envelope cannot drift
    # (Hub Rule 18). Add-DiagnosticCaptureEntries takes .resolved; doctor.ps1 renders all three,
    # which is what lets a fleet reader see a TYPO -- an unrecognized value resolves to `metadata`
    # here and says so there, rather than silently reading as a control that is not active.
    #
    # INVALID AND EMPTY BOTH FALL BACK TO `metadata` (R25, ruled 2026-09-12: the default becomes
    # metadata, `full` becomes an explicit opt-in). The fallback DIRECTION is not a preference
    # either: a fallback fails toward the safe mode or it is not a fallback. Before R25 the seed
    # below was 'full', which made an ABSENT value safe but left an UNRECOGNIZED one falling to
    # the same permissive seed -- a typo in a GPO- or Intune-deployed value would have silently
    # re-enabled source-text capture on exactly the fleet whose administrator was trying to
    # configure it. Both paths return through this one seeded $info, so correcting the seed
    # corrects both at once; there is no separate branch for "unrecognized" left to fall out of
    # step with "absent" again.
    #
    # Get-CaptureLogRotateBytes above still sets the general precedent for this family -- fall
    # back to THE DEFAULT rather than disabling the bound -- and R25 does not disturb it:
    # `metadata` is not `off`, so an absent or invalid value still captures, still keys the
    # dogfood corpus identically to `full` (hash is computed from the offending line in every
    # mode), and still never becomes a gate on WHETHER capture happens -- only on which fields a
    # default row carries. T6.1 (THREAT-MODEL.md, amended) is accepted on that same basis.
    #
    # Case- and whitespace-insensitive: a value deployed by GPO, Intune or machine-scope
    # environment is not required to match a spelling exactly to be honoured.
    $raw = $env:POWERSHELL_LSP_CAPTURE_MODE
    if ($null -eq $raw) { $raw = '' }
    $info = [ordered]@{ resolved = 'metadata'; raw = [string]$raw; recognized = $false }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $info }
    $norm = ([string]$raw).Trim().ToLowerInvariant()
    if ($norm -eq 'full' -or $norm -eq 'metadata' -or $norm -eq 'off') {
        $info.resolved = $norm
        $info.recognized = $true
    }
    return $info
}

function Get-DiagnosticCaptureMode {
    # The resolved capture mode alone -- the writer's seam. See Get-DiagnosticCaptureModeInfo
    # for the vocabulary, the fallback and the precedent it follows.
    return [string](Get-DiagnosticCaptureModeInfo).resolved
}

function Get-OtelEndpointInfo {
    # Resolve $env:POWERSHELL_LSP_OTEL_ENDPOINT into the facts a fleet reader needs
    # (P2-1, ENTERPRISE-PROGRAM-DOCKET item 7; the ruled env surface is item 15c):
    #   endpoint    the collector URL to POST to, '' when export is not active. VERBATIM.
    #   display     the same URL with userinfo and query REDACTED -- the only form that
    #               is safe to print, log, or hand to a doctor envelope.
    #   raw         the environment value verbatim, '' when unset. NEVER interpreted.
    #   configured  $true when export is active. This is the exporter's single seam.
    #   recognized  $true when raw parsed as an absolute http/https URL, $false otherwise.
    #
    # ONE function owns the vocabulary so the exporter and any later reporter cannot drift
    # (Hub Rule 18) -- the same reason Get-DiagnosticCaptureModeInfo above owns its three modes.
    #
    # THE FALLBACK DIRECTION IS INVERTED FROM THE CAPTURE-MODE PRECEDENT, DELIBERATELY.
    # Get-DiagnosticCaptureModeInfo resolves an unrecognized value to `full` and says so, because
    # T6.1 is ACCEPTED-WITH-RECORD and nothing may become a gate on the capture channel: there,
    # failing permissive costs nothing a reader did not already accept. HERE the permissive
    # direction is a NETWORK EGRESS to a destination the administrator did not name. A malformed
    # value therefore resolves to NOT CONFIGURED -- export off -- and carries recognized=$false so
    # the typo is reportable rather than swallowed. The two directions are opposite because the
    # thing on the other side of the failure is opposite, not because this one is stricter by taste.
    #
    # ONLY http and https are recognized. A collector reached over any other scheme is not a
    # thing this exporter can claim to have delivered to, and `file:` in particular would turn an
    # egress control into a silent local writer.
    $raw = $env:POWERSHELL_LSP_OTEL_ENDPOINT
    if ($null -eq $raw) { $raw = '' }
    $info = [ordered]@{ endpoint = ''; display = ''; raw = [string]$raw; configured = $false; recognized = $false }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $info }
    $trimmed = ([string]$raw).Trim()
    $uri = $null
    if (-not [System.Uri]::TryCreate($trimmed, [System.UriKind]::Absolute, [ref]$uri)) { return $info }
    if ($uri.Scheme -ne 'http' -and $uri.Scheme -ne 'https') { return $info }
    $info.endpoint = $trimmed
    $info.display = Get-OtelEndpointDisplay -Uri $uri
    $info.configured = $true
    $info.recognized = $true
    return $info
}

function Get-OtelEndpointDisplay {
    # The printable form of a collector URL: scheme, host, port and path only.
    #
    # USERINFO AND QUERY ARE DROPPED BECAUSE BOTH CARRY CREDENTIALS IN PRACTICE. An OTLP
    # collector is commonly addressed as https://user:token@host/v1/metrics or with an api-key
    # in the query string, and this value's whole purpose is to be shown to a human or written
    # into a report. Printing the raw URL would make a diagnostic aid into a credential leak --
    # the same shape as the capture log quoting a source line, one layer up.
    param([Parameter(Mandatory = $true)][System.Uri]$Uri)
    $port = ''
    if (-not $Uri.IsDefaultPort) { $port = ':' + [string]$Uri.Port }
    $shown = $Uri.Scheme + '://' + $Uri.Host + $port + $Uri.AbsolutePath
    if (-not [string]::IsNullOrEmpty($Uri.Query)) { $shown += '?<redacted>' }
    return $shown
}

function Get-OtelEndpointReportInfo {
    # The subset of Get-OtelEndpointInfo that is safe to PUBLISH -- to a doctor envelope, a
    # report, a log line, anything a human or a management plane reads.
    #
    # ONE function owns "what may leave this host about the collector address" (Hub Rule 18),
    # for the same reason Get-OtelAttributeAllowList owns what may leave it about a stats row.
    # A second consumer that re-derived the safe view would be free to re-derive it wrongly,
    # and the whole value of a privacy boundary is that there is exactly one of it.
    #
    # IT IS AN ALLOWLIST, NOT A DENYLIST, and that is the decision this function turns on. It
    # NAMES the three fields it publishes rather than removing the two it does not, so a field
    # added to Get-OtelEndpointInfo later is absent here until somebody decides otherwise. A
    # rule written as "drop endpoint and raw" keeps passing the day a third credential-bearing
    # field joins the record; this one fails closed instead. The test that tells the two apart
    # is "is an UNKNOWN field absent", never "is the known-bad field absent".
    #
    # WHY `endpoint` AND `raw` ARE NOT ON IT:
    #   endpoint  the collector URL VERBATIM, userinfo and query intact. It is what the
    #             exporter POSTs to, and it is exactly the credential-bearing form that
    #             Get-OtelEndpointDisplay above exists to redact.
    #   raw       the environment value verbatim. When `recognized` is $false it did not parse
    #             as a URL at all, so nothing has inspected it and nothing can promise it holds
    #             no secret. A value that failed to parse cannot be shown safely, which is why
    #             export-otel.ps1's own -Show refuses to echo it.
    #
    # `display` is '' whenever `configured` is $false -- the unparseable case included -- so the
    # published shape never depends on an unpublished field in order to be safe.
    $info = Get-OtelEndpointInfo
    return [ordered]@{
        display    = [string]$info.display
        configured = [bool]$info.configured
        recognized = [bool]$info.recognized
    }
}

# --- managed mode: fail-closed on policy (dispatch 000299, W3-3) -----------
# `orgPolicy` (E2.2/000142, integrity-gated by 000259) is fail-open by design (T4.2, ACCEPTED
# WITH RECORD): a policy that cannot be validated silently stops enforcing and the edit proceeds
# unfiltered, because an unreadable policy must never break the user's edit. That is still the
# default and is unchanged here. `POWERSHELL_LSP_POLICY_MODE=closed` gives a fleet an OPT-IN
# inversion for exactly the two REVIEW-II-DOCKET W3-3 cases -- a missing or hash-mismatched
# orgPolicy FILE -- converting "silently disable exclusions" into a loud, existing `unavailable`
# banner: the reason text is new, the status token is not (CONTRACT.md Tier 1.2 stays untouched).

function Get-PolicyModeInfo {
    # Resolve $env:POWERSHELL_LSP_POLICY_MODE into the three facts a caller needs (dispatch
    # 000299, W3-3; Mike's ruling at acceptance: default is `open`, today's behaviour exactly):
    #   resolved    'open' | 'closed' -- what lsp-client.ps1 obeys.
    #   raw         the environment value verbatim, '' when unset. NEVER interpreted.
    #   recognized  $true when raw named one of the two modes, $false otherwise.
    #
    # UNSET AND UNRECOGNIZED BOTH FALL BACK TO `open`, mirroring Get-DiagnosticCaptureModeInfo's
    # direction, and for the parallel reason: nothing may become a gate on the diagnostics
    # surface BY ACCIDENT. A GPO typo landing on `closed` would silently stop every edit on the
    # fleet from being checked at all; falling back to `open` means a typo can only ever cost the
    # already-accepted (T4.2) fail-open exposure, never a surprise fleet-wide diagnostics
    # outage. This is the OPPOSITE fallback direction from Get-OtelEndpointInfo, and for the same
    # reason that pair is opposite: what sits on the other side of a typo here is "everyone's
    # diagnostics go dark", not "an egress nobody named" -- permissive is the safe direction here,
    # exactly as it is for captureMode.
    #
    # Case- and whitespace-insensitive: a value deployed by GPO, Intune or machine-scope
    # environment is not required to match a spelling exactly to be honoured.
    $raw = $env:POWERSHELL_LSP_POLICY_MODE
    if ($null -eq $raw) { $raw = '' }
    $info = [ordered]@{ resolved = 'open'; raw = [string]$raw; recognized = $false }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $info }
    $norm = ([string]$raw).Trim().ToLowerInvariant()
    if ($norm -eq 'open' -or $norm -eq 'closed') {
        $info.resolved = $norm
        $info.recognized = $true
    }
    return $info
}

function Test-PolicyEnforcementFailClosed {
    # W3-3's central decision, pure and unit-testable: does an org policy that failed to
    # validate resolve THIS edit to the existing `unavailable` token? Takes already-resolved
    # inputs -- Get-PolicyModeInfo and Import-OrgPolicyExcludes already did the I/O -- so the
    # boundary between "policy degraded" and "fail this edit closed" has exactly one owner
    # (Hub Rule 18), matching how every other doctor/client decision in this file is split into
    # a pure decision over already-resolved observations.
    #
    #   $Mode     the RESOLVED POWERSHELL_LSP_POLICY_MODE ('open' | 'closed') -- pass
    #             (Get-PolicyModeInfo).resolved, never the raw value.
    #   $KnobSet  the orgPolicy userConfig knob carries a non-blank value.
    #   $Warning  Import-OrgPolicyExcludes' own degrade reason for THIS read, '' when it is not
    #             degraded (a policy that is off, or read and satisfied, either with or without
    #             exclusions declared).
    #
    # OPEN IS A NO-OP BY CONSTRUCTION: returns $false regardless of $KnobSet/$Warning, so
    # today's fail-open behaviour is preserved byte-for-byte for every host that sets nothing --
    # this function can never be the reason an `open` host's edit changes.
    #
    # CLOSED WITH NO POLICY CONFIGURED IS NOT A TRIGGER. An admin who has not deployed a policy
    # yet has nothing to validate, which is a different state from a policy that WAS deployed and
    # cannot be read: "a missing or hash-mismatched orgPolicy FILE" (REVIEW-II-DOCKET.md W3-3)
    # presupposes a file was named. Widening this to also gate on an unset knob would silently
    # disable diagnostics fleet-wide the moment an admin flips the mode, before deploying
    # anything -- a materially different (and un-chartered) blast radius.
    #
    # CLOSED WITH A POLICY CONFIGURED AND DEGRADED -- for ANY of Import-OrgPolicyExcludes' own
    # degrade reasons (missing file, unreadable, unparseable, a relative path, or a failed
    # 000259 integrity gate) -- fails closed. Deliberately not narrowed to only the integrity
    # gate or only a missing file: the docket's own rationale is "failure to validate policy
    # means analysis is noncompliant" (REVIEW-II-DOCKET.md W3-3), and every one of those reasons
    # is exactly that -- the policy could not be validated. Reusing $Warning (already computed
    # once per edit, at lsp-client.ps1's existing org-policy read) rather than re-deriving file
    # existence a second way keeps this a single source of truth with Import-OrgPolicyExcludes'
    # own verdict, per the same no-second-verifier discipline Get-OrgPolicyReportInfo follows.
    param(
        [string]$Mode = 'open',
        [bool]$KnobSet = $false,
        [string]$Warning = ''
    )
    if ($Mode -ne 'closed') { return $false }
    if (-not $KnobSet) { return $false }
    return (-not [string]::IsNullOrWhiteSpace($Warning))
}

function Invoke-CaptureLogRotation {
    # Bound the capture log (T6.4, threat model section 8, ruled FIX 2026-08-21).
    #
    # THE FINDING, MEASURED not assumed. session-start.ps1's Invoke-LogSweep bounds only STAMPED
    # ROLLING FAMILIES -- it derives a stem by collapsing -\d{8}-\d{6}-\d{3} to -STAMP and skips
    # any name that does not change, which is every single-append log. diagnostics.jsonl is a
    # single append log, so it was swept by nothing and grew for the life of the install. On
    # 2026-08-21 the live dev-clone log measured 5,279,427 bytes over 10,161 rows (~520 bytes a
    # row) with no mechanism that would ever have stopped it.
    #
    # THE FIX IS SHAPED LIKE THE SWEEP, not bolted beside it. Rather than truncating the log or
    # teaching the sweep a second concept, rotation RENAMES the over-cap log to
    # diagnostics-<yyyyMMdd-HHmmss-fff>.jsonl -- which IS the stamped-family shape the existing
    # sweep already recognises. The bound then comes from the sweep's own keepLastN, with zero
    # new retention policy:
    #
    #   ceiling = (keepLastN + 1) * rotate-bytes = 11 * 8 MB = 88 MB at the shipped default
    #
    # and the ACTIVE log alone holds ~16,100 rows at the measured row size -- more than the
    # entire historical accrual above -- so the rule-curation lane's window is never narrower
    # than the history it has ever actually had.
    #
    # FAIL-SAFE, like every other capture-path operation: any failure is swallowed and the log
    # is left exactly as it was. A rotation that threw would be worse than a log that grew.
    # Returns the rotated path when it rotated, '' otherwise.
    param([string]$LogPath = '')
    try {
        $path = $LogPath
        if ([string]::IsNullOrWhiteSpace($path)) { $path = Get-DogfoodLogPath }
        if ([string]::IsNullOrWhiteSpace($path)) { return '' }
        $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        if ($null -eq $item -or $item.PSIsContainer) { return '' }
        if ($item.Length -lt (Get-CaptureLogRotateBytes)) { return '' }
        $dir = Split-Path -Parent $path
        $base = [System.IO.Path]::GetFileNameWithoutExtension($path)
        $ext = [System.IO.Path]::GetExtension($path)
        $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
        $target = Join-Path $dir ($base + '-' + $stamp + $ext)
        # A same-millisecond collision would make Move-Item throw; step the stamp instead.
        $n = 0
        while ((Test-Path -LiteralPath $target) -and $n -lt 1000) {
            $n++
            $target = Join-Path $dir ($base + '-' + $stamp.Substring(0, $stamp.Length - 3) + ('{0:D3}' -f ($n % 1000)) + $ext)
        }
        if (Test-Path -LiteralPath $target) { return '' }
        Move-Item -LiteralPath $path -Destination $target -Force -ErrorAction Stop
        return $target
    } catch { return '' }
}

function Get-CaptureLogFamily {
    # Every retained member of the capture log's rolling family, OLDEST FIRST, ending with the
    # ACTIVE log. Rotation moves history out of diagnostics.jsonl, so a reader that opened only
    # that file would report a near-empty corpus the first time a rotation fired -- the same
    # false-zero shape the reader's own header warns about. This is what keeps the union honest.
    #
    # Returns @() when the log's directory does not exist. Never throws.
    param([string]$LogPath = '')
    try {
        $path = $LogPath
        if ([string]::IsNullOrWhiteSpace($path)) { $path = Get-DogfoodLogPath }
        if ([string]::IsNullOrWhiteSpace($path)) { return @() }
        $dir = Split-Path -Parent $path
        if ([string]::IsNullOrWhiteSpace($dir) -or -not (Test-Path -LiteralPath $dir)) { return @() }
        $base = [System.IO.Path]::GetFileNameWithoutExtension($path)
        $ext = [System.IO.Path]::GetExtension($path)
        # The stamp is fixed-width and lexically ordered, so sorting the NAMES sorts by time --
        # no LastWriteTime read, which a copy or a restore would have scrambled.
        $pattern = '^' + [regex]::Escape($base) + '-\d{8}-\d{6}-\d{3}' + [regex]::Escape($ext) + '$'
        $rotated = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match $pattern } |
                Sort-Object Name |
                ForEach-Object { $_.FullName })
        $out = @($rotated)
        if (Test-Path -LiteralPath $path -PathType Leaf) { $out += $path }
        return @($out)
    } catch { return @() }
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
    #
    # THREE CAPTURE MODES (P0-2, ruling R8 of 2026-09-05), read from
    # Get-DiagnosticCaptureMode -- see there for the vocabulary and the fallback:
    #   full      today's entry, BYTE-IDENTICAL. The [ordered] literal below is untouched, and
    #             that is why: byte-identity is structural here, not a thing a test restores.
    #   metadata  `file` demoted to its BASENAME, `message` and `snippet` dropped. The reader
    #             set the review named (EDR, backup, eDiscovery, DLP) sees no source text and
    #             no absolute path, and the dogfood corpus channel keeps working.
    #   off       nothing is written and NO directory is created.
    #
    # THE READ IS KEPT IN metadata MODE; ONLY THE WRITE IS SUPPRESSED. `hash` is computed FROM
    # `$snippet` (below), so an implementation that skipped reading the file to save the write
    # would hash the EMPTY line instead and silently key every metadata row differently from
    # the full row for the same finding -- breaking the exact channel this mode exists to
    # preserve, and breaking it invisibly, because this writer swallows everything. The mode
    # therefore branches only AFTER the entry is built.
    #
    # `message` is dropped rather than kept because PSScriptAnalyzer quotes SOURCE IDENTIFIERS
    # into it -- measured on the pinned PSSA 1.25.0: PSUseDeclaredVarsMoreThanAssignments emits
    # "The variable 'customerRecordZZQ9' is assigned but never used." and PSReviewUnusedParameter
    # emits "The parameter 'InternalTokenABC7' has been declared but not used." A row that
    # strips the snippet and keeps that has not answered the reader it exists for.
    param([string]$File, [object[]]$Records)
    try {
        $recs = @($Records)
        if ($recs.Count -eq 0) { return }
        $mode = Get-DiagnosticCaptureMode
        # `off` returns BEFORE the log path resolves, so no file and no DIRECTORY is created.
        if ($mode -eq 'off') { return }
        $logPath = Get-DogfoodLogPath
        if ([string]::IsNullOrWhiteSpace($logPath)) { return }
        $dir = Split-Path -Parent $logPath
        if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
            New-ContainedDirectory -Path $dir
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
            if ($mode -eq 'metadata') {
                # Remove() on an [ordered] dictionary preserves the order of what remains, so a
                # metadata row is the full row minus two keys -- never a differently-shaped
                # object. `hash` is already computed from $snippet above and is carried through
                # UNCHANGED, which is what makes the two modes key identically.
                # The basename is split on BOTH separators rather than with Split-Path -Leaf:
                # Split-Path is host-relative, so a Windows path handed to it on a POSIX CI leg
                # comes back whole -- with the absolute path still in the row.
                $entry['file'] = [string](([string]$File) -split '[\\/]')[-1]
                $entry.Remove('message')
                $entry.Remove('snippet')
            }
            [void]$sb.Append(($entry | ConvertTo-Json -Depth 5 -Compress))
            [void]$sb.Append("`n")
        }
        $enc = New-Object System.Text.UTF8Encoding($false)
        # Contain on the absent->present transition only -- see Write-StatsLine (000277 leg C).
        $bornHere = -not (Test-Path -LiteralPath $logPath)
        [System.IO.File]::AppendAllText($logPath, $sb.ToString(), $enc)
        if ($bornHere) { [void](Set-ContainedFileMode -Path $logPath) }
    } catch { }
}

# --- per-rule lifecycle persistence (dispatch 000171 leg 2) ----------------
# The closed-loop CLEARED / STILL-PRESENT signal is COMPUTED by Get-FindingLifecycleDiff and
# emitted on the turn payload, but until now NOTHING persisted it PER RULE -- so the efficacy
# ledger's fixed_next_turn_rate and persistence_rate columns could not be derived without
# inventing data. Dispatch 000170 leg 2 enumerated the write sites and RED-proved the absence:
# the payload is ephemeral, the client's prose is rule-keyed but not persisted, and the daemon's
# debug line is persisted but carries only counts and a path.
#
# THIS LANDS IN A SIBLING LOG, NOT IN THE CAPTURE RECORD -- ruled before execution:
#   * dogfood/diagnostics.jsonl stays BYTE-UNCHANGED in shape, so the consumer contract its two
#     shipped readers (scripts/rule-efficacy-ledger.ps1, scripts/lib/dogfood-reader.psm1) depend
#     on is untouched and no historical record needs migrating;
#   * a defect in lifecycle persistence therefore cannot corrupt the capture log.
#
# JOIN KEY: the EXISTING shape hash. Add-DiagnosticCaptureEntries hashes (ruleId + offending
# line) with Get-DiagnosticShapeHash; New-LifecycleFinding hashes the SAME material with the SAME
# function. The two are identical BY CONSTRUCTION, so the join needs NO new field on the capture
# record. (The hash material contains no line NUMBER, which is what makes it stable across turns
# for the same finding -- the same property that lets the closed loop avoid reading a moved
# finding as cleared.)
#
# FAIL OPEN, ALWAYS. This path is TELEMETRY. Any failure to resolve, open, write or flush
# degrades to ONE warning in the daemon log and the diagnostic still reaches Claude Code
# unchanged. A plugin that drops a diagnostic because a telemetry file was locked has inverted
# its own purpose. Proven by fault injection, not by inspection.
#
# BOUNDED BY CONSTRUCTION. The file is lifecycle-<yyyyMMdd-HHmmss-fff>.jsonl in Get-LogDir, so it
# is a member of a STAMPED ROLLING FAMILY that session-start.ps1's existing Invoke-LogSweep
# already trims to the keepLastN newest -- ZERO new sweep code. Per-turn cardinality is bounded
# by the active rule surface (53 under `base`, 15 under `pses-default`), because at most one
# record per distinct ruleId is written per turn; a turn with no lifecycle event writes nothing.

function Get-LifecycleLogPath {
    # Resolve the per-rule lifecycle log. Precedence mirrors Get-DogfoodLogPath:
    #   1. $env:POWERSHELL_LSP_LIFECYCLE_LOG -- explicit full-path override (test seam), verbatim.
    #   2. <logDir>/lifecycle-<Stamp>.jsonl  -- the default. The STAMP is what makes this a member
    #      of a rolling family Invoke-LogSweep already recognises (it collapses -\d{8}-\d{6}-\d{3}
    #      to -STAMP and keeps the newest keepLastN per stem).
    # Returns '' when neither resolves -- the caller then fails open and surfaces nothing.
    param([string]$Stamp = '')
    $override = $env:POWERSHELL_LSP_LIFECYCLE_LOG
    if (-not [string]::IsNullOrWhiteSpace($override)) { return $override }
    if ([string]::IsNullOrWhiteSpace($Stamp)) { return '' }
    $dir = ''
    try { $dir = Get-LogDir } catch { $dir = '' }
    if ([string]::IsNullOrWhiteSpace($dir)) { return '' }
    return (Join-Path $dir ('lifecycle-' + $Stamp + '.jsonl'))
}

function New-LifecycleLedgerRecords {
    # PURE. Project one turn's lifecycle diff into ONE RECORD PER DISTINCT RULE ID.
    #
    # Per-rule, not per-finding, is what bounds the growth rate: the worst case is the size of the
    # active rule surface, whatever the finding count. The shape-hash arrays are what let a reader
    # join back to dogfood/diagnostics.jsonl without any change to that file.
    #
    # Returns @() when the turn produced no lifecycle event at all -- a clean edit costs zero bytes
    # rather than an empty record.
    #
    # IN-RECORD VERSION PROVENANCE (dispatch 000209). Every record carries `pluginVersion`, stamped
    # HERE, at emit time, from Get-PluginVersion. In-record rather than in-path is the design: the
    # capture log is version-attributable only because its marketplace-cache PATH carries the
    # version, but this sibling lands in a flat, stamped rolling family under Get-LogDir, so a path
    # carries no version to read. A field survives a file move, a rotation, and the reader's union.
    #
    # FORWARD-ONLY, ALWAYS. This stamps what is written from now on. It does NOT and MUST NOT
    # rewrite a historical record: the un-instrumented past is not recoverable, and a reader that
    # back-filled it would be inventing provenance. The reader labels that window as a bounded gap
    # instead (Get-LifecycleProvenanceFloor, scripts/rule-efficacy-ledger.ps1).
    #
    # -PluginVersion is a TEST SEAM, not a knob: no userConfig, no caller passes it in production.
    # Empty (the default, and what the daemon call site passes by omission) resolves Get-PluginVersion
    # at emit time. Get-PluginVersion never throws and returns its own '0.0.0-unknown' sentinel on a
    # resolution failure, so the field is ALWAYS present and never fabricated -- and the reader
    # treats that sentinel as NOT version-attributable rather than as a version.
    param(
        [object]$LedgerKeys,
        [string]$File,
        [string]$Timestamp,
        [bool]$ScopeApplied,
        [string]$PluginVersion = ''
    )
    $out = New-Object System.Collections.ArrayList
    if ($null -eq $LedgerKeys) { return @($out.ToArray()) }
    $cleared = @()
    $still = @()
    try { $cleared = @($LedgerKeys['cleared'] | Where-Object { $null -ne $_ }) } catch { $cleared = @() }
    try { $still = @($LedgerKeys['stillPresent'] | Where-Object { $null -ne $_ }) } catch { $still = @() }
    if ($cleared.Count -eq 0 -and $still.Count -eq 0) { return @($out.ToArray()) }

    # Resolved ONCE per turn, after the zero-event early return, so a clean turn costs no manifest
    # read at all. Get-PluginVersion is itself per-process cached and never throws; the try is the
    # same fail-open belt this whole path wears -- a telemetry field must never break an emit.
    $ver = [string]$PluginVersion
    if ([string]::IsNullOrWhiteSpace($ver)) {
        try { $ver = [string](Get-PluginVersion) } catch { $ver = '0.0.0-unknown' }
    }
    if ([string]::IsNullOrWhiteSpace($ver)) { $ver = '0.0.0-unknown' }

    # No nested helper function here, deliberately: a `function script:Foo` inside a dot-sourced
    # library defines itself in the CALLER's script scope, which is the same leak class G1 in
    # tests/PowerShellLsp.LibPurity.Tests.ps1 guards against for variables (dispatch 000156).
    # The bucket init is inlined instead.
    $byRule = [ordered]@{}
    foreach ($c in $cleared) {
        $rid = [string]$c.ruleId
        if ([string]::IsNullOrWhiteSpace($rid)) { $rid = '(parser/no-rule)' }
        if (-not $byRule.Contains($rid)) {
            $byRule[$rid] = @{ cleared = (New-Object System.Collections.ArrayList)
                still = (New-Object System.Collections.ArrayList); attemptsMax = 0; downgraded = $false }
        }
        [void]$byRule[$rid].cleared.Add([string]$c.hash)
    }
    foreach ($s in $still) {
        $rid = [string]$s.ruleId
        if ([string]::IsNullOrWhiteSpace($rid)) { $rid = '(parser/no-rule)' }
        if (-not $byRule.Contains($rid)) {
            $byRule[$rid] = @{ cleared = (New-Object System.Collections.ArrayList)
                still = (New-Object System.Collections.ArrayList); attemptsMax = 0; downgraded = $false }
        }
        $b = $byRule[$rid]
        [void]$b.still.Add([string]$s.hash)
        $a = 0; try { $a = [int]$s.attempts } catch { $a = 0 }
        if ($a -gt [int]$b.attemptsMax) { $b.attemptsMax = $a }
        $d = $false; try { $d = [bool]$s.downgraded } catch { $d = $false }
        if ($d) { $b.downgraded = $true }
    }

    # Sorted by ruleId -- a stable, magnitude-free order, matching the ledger's own S3.2 guardrail.
    foreach ($rid in @($byRule.Keys | Sort-Object)) {
        $b = $byRule[$rid]
        [void]$out.Add([ordered]@{
                schema             = 'powershell-lsp-lifecycle/1'
                ts                 = [string]$Timestamp
                pluginVersion      = [string]$ver
                file               = [string]$File
                ruleId             = [string]$rid
                cleared            = @($b.cleared).Count
                stillPresent       = @($b.still).Count
                clearedHashes      = @($b.cleared.ToArray())
                stillPresentHashes = @($b.still.ToArray())
                attemptsMax        = [int]$b.attemptsMax
                downgraded         = [bool]$b.downgraded
                scopeApplied       = [bool]$ScopeApplied
            })
    }
    return @($out.ToArray())
}

function Add-LifecycleLedgerEntries {
    # Append the per-rule lifecycle records as JSONL. FAIL-OPEN by contract: returns $true on a
    # clean write and $false on ANY failure, and NEVER throws -- so the caller can surface exactly
    # one warning and carry on. Writes nothing to stdout, so the diagnostics surface, its order,
    # and the hook's exit code are byte-for-byte unchanged whether this succeeds, fails, or is
    # absent. Same invisible-side-channel fence as Add-DiagnosticCaptureEntries.
    #
    # An empty record set is a SUCCESS that writes nothing (a clean turn is not a failure).
    param([object[]]$Records, [string]$Stamp = '')
    try {
        $recs = @(@($Records) | Where-Object { $null -ne $_ })
        if ($recs.Count -eq 0) { return $true }
        $logPath = Get-LifecycleLogPath -Stamp $Stamp
        if ([string]::IsNullOrWhiteSpace($logPath)) { return $false }
        $dir = Split-Path -Parent $logPath
        if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
            New-ContainedDirectory -Path $dir
        }
        $sb = New-Object System.Text.StringBuilder
        foreach ($r in $recs) {
            [void]$sb.Append(($r | ConvertTo-Json -Depth 5 -Compress))
            [void]$sb.Append("`n")
        }
        $enc = New-Object System.Text.UTF8Encoding($false)
        # Contain on the absent->present transition only -- see Write-StatsLine (000277 leg C).
        $bornHere = -not (Test-Path -LiteralPath $logPath)
        [System.IO.File]::AppendAllText($logPath, $sb.ToString(), $enc)
        if ($bornHere) { [void](Set-ContainedFileMode -Path $logPath) }
        return $true
    } catch { return $false }
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
# --- POSIX containment (dispatch 000277 leg C, ruling R4) ------------------
# THE FINDING THIS CLOSES. THREAT-MODEL T5.1 and T6.2 carried their POSIX arms as
# *unmeasured* until dispatch 000276 leg F measured them on the two POSIX CI legs
# (run 33949910984). Both arms came back the same on ubuntu-pwsh and macos-pwsh:
# the data-root temp fallback and the daemon pipe's Unix-domain-socket endpoint are
# both created 755 -- 'exposed-beyond-user -- OTHER has 5'. On Linux the containing
# directory is /tmp at 1777, so nothing above them contains them either; on macOS the
# per-user temp directory is 700, so that platform contains them by accident of where
# its temp lives, not by anything this plugin does.
#
# THE FIX. Every filesystem object the PLUGIN creates on a POSIX host is made
# owner-only AT CREATION: 0700 for directories, 0600 for files the plugin writes.
# That is a default, not a policy knob -- no userConfig key, no status token, no
# CONTRACT.md line moves.
#
# WINDOWS IS BYTE-IDENTICAL. Test-OnWindows short-circuits before any mode work and
# the create call is the same `New-Item -ItemType Directory -Force` it always was, so
# the Windows DACL path that 000269 settled for T5.1 is untouched.
#
# WHAT IS DELIBERATELY NOT TOUCHED. Only segments THIS call creates are contained.
# An ancestor that already exists belongs to the user or to the platform -- /tmp, the
# macOS per-user temp, a data root the user pointed CLAUDE_PLUGIN_DATA at -- and
# re-moding it would be this plugin reaching outside its own objects. That restraint
# is why the Linux /tmp 1777 reading stays in THREAT-MODEL after this fix: it is not
# ours to close.
#
# FAIL-SAFE. Containment never fails a create. If chmod is missing or refuses, the
# directory or file still exists and the caller proceeds; the return value says what
# happened for the tests that assert on it.

function Set-OwnerOnlyMode {
    # Contain ONE existing filesystem object to owner-only. Returns $true when the mode
    # was applied, $false on Windows (by contract) and on any POSIX failure.
    #
    # Kind is explicit rather than probed because the caller always knows which it made,
    # and a probe would be one more thing to get wrong on a socket -- which is neither a
    # plain file nor a directory, and takes the File mode (0600: connect(2) on a unix
    # socket needs write, never execute).
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet('Directory', 'File')][string]$Kind = 'Directory'
    )
    if (Test-OnWindows) { return $false }
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $octal = '600'
    if ($Kind -eq 'Directory') { $octal = '700' }
    try {
        # chmod rather than [System.IO.File]::SetUnixFileMode: the managed API landed in
        # .NET 7 (pwsh 7.3), and this library still has to run on whatever pwsh the user
        # has. chmod is on every POSIX host, and this path runs once per object created,
        # not per edit, so the process spawn is not on any hot path.
        #
        # NO `--` END-OF-OPTIONS SEPARATOR, and that is not an oversight. BSD chmod (macOS)
        # does not support it: it takes `--` as the first FILE operand, applies the mode to
        # the real path, and then exits NON-ZERO on the phantom one -- so the object is
        # contained but the return value lies. Measured on macos-pwsh in this dispatch's own
        # CI run 33978662085 (`chmod: --: No such file or directory`). Every path this is
        # called with is absolute, so there is no leading-dash operand to defend against.
        & chmod $octal $Path 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    }
    catch { return $false }
}

function New-ContainedDirectory {
    # Create a directory the way `New-Item -ItemType Directory -Force` does, then contain
    # every segment THIS call had to create to 0700 on a POSIX host.
    #
    # The two-phase shape (enumerate the missing ancestors FIRST, create, then contain
    # exactly those) is the whole point. `-Force` silently creates missing ancestors at
    # the ambient umask, so containing only the leaf would leave a 755 parent that this
    # plugin, not the platform, had just made. Enumerating first is also what keeps the
    # restraint above honest: a segment that already existed is never in the list, so it
    # is never re-moded.
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $created = New-Object System.Collections.Generic.List[string]
    if (-not (Test-OnWindows)) {
        $walk = $Path
        while (-not [string]::IsNullOrWhiteSpace($walk) -and -not (Test-Path -LiteralPath $walk)) {
            $created.Add($walk)
            $parent = Split-Path -Parent $walk
            if ($parent -eq $walk) { break }
            $walk = $parent
        }
    }
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    # Deepest-first is the order the walk produced; mode order does not matter because
    # this process owns every one of them and is not traversing them concurrently.
    foreach ($seg in $created) { [void](Set-OwnerOnlyMode -Path $seg -Kind 'Directory') }
}

function Set-ContainedFileMode {
    # Contain a file the plugin has just created. Separate from Set-OwnerOnlyMode only to
    # give the append-writers a single name to call that reads as what it is at the call
    # site; the writers call it ONLY on the transition from absent to present, so a
    # per-edit hot path never spawns chmod.
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Set-OwnerOnlyMode -Path $Path -Kind 'File')
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

function Test-PipeOptionSupported {
    # $true iff this host's System.IO.Pipes.PipeOptions enum carries $Name.
    #
    # RUNTIME CAPABILITY, NOT PLATFORM NAME. The enum member is resolved by NAME rather than
    # written as a `::CurrentUserOnly` literal, because a literal is a COMPILE-time member
    # reference: on a host whose enum lacks it the expression throws, and the daemon would die
    # at pipe construction rather than fall back. Measured 2026-08-21 on this repo's own two
    # Windows CI hosts -- pwsh 7.6.5 lists None,Asynchronous,WriteThrough,CurrentUserOnly;
    # Windows PowerShell 5.1.26100.9168 (.NET Framework) lists ONLY
    # None,Asynchronous,WriteThrough. CurrentUserOnly arrived with .NET Core 3.0 and was never
    # back-ported, so the `windows-powershell` CI leg is exactly the host that needs the guard.
    param([Parameter(Mandatory)][string]$Name)
    try { return ([enum]::GetNames([System.IO.Pipes.PipeOptions]) -contains $Name) } catch { return $false }
}

function Get-DaemonPipeName {
    # THE per-session daemon pipe name. One source for a value that had 23 independent copies
    # across scripts/ and tests/ (Hub Rule 18, dispatch 000291).
    #
    # WHY THIS IS WORTH A FUNCTION rather than a constant somebody remembers to reuse: the stem
    # and the session id are what a client and a daemon must AGREE on to find each other at all.
    # Twenty-three literals is twenty-three chances for a rename to reach twenty-two of them, and
    # the failure mode of that miss is not a red test -- it is a client that connects to nothing
    # and reports the daemon unreachable, which reads as an environment problem rather than as a
    # typo. The seam being load-bearing is asserted directly: mutating this function's stem must
    # turn its callers red, and a caller still building the name inline would stay green.
    #
    # A BLANK SESSION ID RETURNS THE BARE STEM RATHER THAN THROWING, which is what every one of
    # the 23 call sites did by concatenation and is therefore the behaviour being preserved
    # rather than a new decision. Callers that care already guard on the id before calling.
    #
    # THE FOUR `evidence/` SITES ARE DELIBERATELY NOT ROUTED THROUGH THIS. They are frozen
    # byte-anchored release harnesses for v1.32.0 and v1.33.0; changing them destroys the
    # evidence they exist to be. The guard test that forbids inline construction scopes itself
    # to scripts/ and tests/ and asserts the evidence sites are STILL THERE, so the exemption
    # cannot quietly become a hole.
    param([string] $SessionId = '')
    return ('powershell-lsp-' + [string]$SessionId)
}

function Get-DaemonPipeOptions {
    # The PipeOptions the daemon's server stream is created with (T5.1).
    #
    # THE MEASUREMENT THAT MOTIVATES THIS, taken 2026-08-21 against this exact constructor on
    # Windows 11 10.0.26200 / pwsh 7.6.5 by reading the KERNEL object's security descriptor off
    # the live SafePipeHandle (GetSecurityInfo, SE_KERNEL_OBJECT). The shipped pipe carried the
    # OS DEFAULT named-pipe DACL:
    #
    #   D:(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;<invoking user>)(A;;FR;;;WD)(A;;FR;;;AN)
    #
    # The last two ACEs are the finding: WD is Everyone and AN is Anonymous, each granted
    # FILE_GENERIC_READ. Every local principal could open the daemon's pipe for read. What
    # crosses that pipe is diagnostics -- absolute file paths and verbatim source lines from
    # the file being edited -- so this is a local-disclosure surface, not a theoretical one.
    # T5.1 had stood as "unknown" precisely because nobody had measured it; measured, it is
    # permissive beyond the invoking user, which is the arm Mike's R1 grant pre-authorized.
    #
    # With CurrentUserOnly the same measurement reads:
    #
    #   D:(A;;0x1f019f;;;<invoking user>)
    #
    # -- Everyone and Anonymous gone, the invoking user holding full pipe access. Nothing else
    # about the pipe changes: InOut, one instance, Byte mode and Asynchronous are untouched, so
    # the single-instance property Test-DaemonPipePresent's busy-vs-unreachable discriminator
    # depends on is preserved.
    #
    # WHY THE CLIENTS ARE NOT CHANGED. CurrentUserOnly is asymmetric by design: on the SERVER it
    # restricts who may connect; on a CLIENT it additionally verifies the server's identity.
    # Setting it server-side alone is what the finding asks for, and it leaves every shipped
    # client construction byte-identical -- including the doctor's probe and the Unix presence
    # probe -- so no client contract moves.
    #
    # OFF-WINDOWS. .NET backs a named pipe with a unix domain socket file; CurrentUserOnly
    # narrows that file's permissions to the owner instead of writing a DACL. The socket path
    # (<temp>/CoreFxPipe_<name>) is unchanged, so Test-DaemonPipePresent's Unix arm still
    # resolves and still connects as the same user. The four CI legs are the check on that.
    $opts = [System.IO.Pipes.PipeOptions]::Asynchronous
    if (Test-PipeOptionSupported -Name 'CurrentUserOnly') {
        $opts = $opts -bor ([System.IO.Pipes.PipeOptions]'CurrentUserOnly')
    }
    return $opts
}

function New-DaemonPipeServer {
    # THE daemon's pipe-server constructor, in ONE place (dispatch 000237).
    #
    # The daemon creates its NamedPipeServerStream once at start-up and, since 000237, may
    # have to rebuild it mid-life when a stream is left unusable (see
    # Reset-PipeServerConnection below). Two `New-Object` calls with the same five arguments
    # in two files is exactly the shape that drifts -- a maxNumberOfServerInstances or a
    # PipeOptions that differs between the first pipe and its replacement would change the
    # daemon's contract silently at the worst possible moment. So both callers come here.
    #
    # The arguments are the shipped ones, unchanged: InOut, ONE instance (the single-instance
    # property the busy-vs-unreachable discriminator in Test-DaemonPipePresent depends on),
    # Byte transmission, Asynchronous (the serve loop accepts via WaitForConnectionAsync) --
    # plus CurrentUserOnly where the host offers it (T5.1, see Get-DaemonPipeOptions).
    #
    # POSIX CONTAINMENT (dispatch 000277 leg C). Off-Windows .NET backs this pipe with a unix
    # domain socket file, and the 000276 measurement (run 33949910984) read that file at 755 on
    # BOTH posix legs: CurrentUserOnly above is enforced by .NET at accept time, on the peer's
    # credentials -- it does not narrow the socket file's mode, which lands at 0777 masked by the
    # ambient umask (0022 on both runners). So the mode is set here, explicitly, as the second
    # layer: 0600, because connect(2) on a unix socket needs write and never execute.
    #
    # THE RESIDUAL RACE, stated rather than hidden: the socket is bound by the constructor and
    # contained on the next statement, so there is a window in which it exists at the umask
    # default. CurrentUserOnly covers that window -- a foreign peer that connects inside it is
    # still rejected on its credentials -- which is why this is defence in depth and not the
    # only thing standing between the pipe and another local user.
    param([Parameter(Mandatory)][string]$PipeName)
    $server = New-Object System.IO.Pipes.NamedPipeServerStream(
        $PipeName, [System.IO.Pipes.PipeDirection]::InOut, 1,
        [System.IO.Pipes.PipeTransmissionMode]::Byte, (Get-DaemonPipeOptions))
    if (-not (Test-OnWindows)) {
        try { [void](Set-OwnerOnlyMode -Path (Get-DaemonPipeSocketPath -PipeName $PipeName) -Kind 'File') } catch { }
    }
    return $server
}

function Get-DaemonPipeSocketPath {
    # The filesystem path .NET backs a named pipe with OFF-WINDOWS: <temp>/CoreFxPipe_<name>.
    #
    # It exists so the three readers of that path -- the presence probe, the containment above,
    # and the measurement harness -- cannot drift apart. On Windows a named pipe has no such
    # path (NPFS is kernel-managed), so this returns '' there rather than a lie shaped like a
    # path; every caller is already inside a non-Windows branch.
    param([Parameter(Mandatory)][string]$PipeName)
    if (Test-OnWindows) { return '' }
    return (Join-Path ([System.IO.Path]::GetTempPath()) ('CoreFxPipe_' + $PipeName))
}

function Reset-PipeServerConnection {
    # Return a pipe server to a state that can accept the NEXT client (dispatch 000237).
    #
    # THE DEFECT THIS EXISTS FOR, derived from the live serve loop rather than guessed.
    # When a client walks away at its hard cap and the daemon then writes its reply, the
    # write raises IOException "Pipe is broken." The serve loop's per-request handler CATCHES
    # and LOGS that, correctly. What killed the daemon was the line after it:
    #
    #   try { if ($server.IsConnected) { $server.Disconnect() } } catch { }
    #
    # The failed write moves the stream's internal state from Connected to BROKEN, and
    # PipeStream.IsConnected is `State == Connected` -- so it reads FALSE, and the guard
    # SKIPS the Disconnect. The stream is then left in Broken, and the next
    # WaitForConnectionAsync() -- which sits OUTSIDE the per-request try -- throws
    # IOException "Pipe is broken." synchronously, straight past the handler and into the
    # loop's outer finally. Hence the measured log shape: the handler's own
    # "request handling error: ... Pipe is broken." line followed IMMEDIATELY by
    # "main loop ended; cleanup", with no second handled error in between.
    #
    # Measured on pwsh 7.6.3 / Windows 11 with a real client that connects, sends, and exits:
    #   after the failed write   IsConnected=False  internalState=Broken
    #   guarded Disconnect       SKIPPED
    #   next WaitForConnectionAsync()  -> IOException "Pipe is broken." (synchronous)
    #   UNCONDITIONAL Disconnect -> succeeds, internalState=Disconnected
    #   next WaitForConnectionAsync()  -> arms normally
    #
    # So the guard was the bug and its removal is the cure: Disconnect() is willing to
    # transition a BROKEN stream back to Disconnected, and only the IsConnected test stopped
    # it being asked. The try/catch stays, because Disconnect() legitimately refuses a stream
    # that was never connected or has been disposed -- and in that case the caller is told to
    # rebuild rather than left to discover it at the next accept.
    #
    # Returns a hashtable: Ok (can this stream accept again?), Reason (for the log).
    # PURE apart from the Disconnect call; no logging of its own, so the caller owns the log
    # line and its wording.
    param([AllowNull()]$Server)
    if ($null -eq $Server) { return @{ Ok = $false; Reason = 'no server stream' } }
    try {
        $Server.Disconnect()
        return @{ Ok = $true; Reason = 'disconnected' }
    } catch {
        $ex = $_.Exception
        if ($ex -is [System.Management.Automation.MethodInvocationException] -and $ex.InnerException) {
            $ex = $ex.InnerException
        }
        # ORDER IS LOAD-BEARING: ObjectDisposedException DERIVES from
        # InvalidOperationException, so testing the base type first classifies a DISPOSED
        # stream as merely "never connected" and hands the serve loop a dead pipe to accept
        # on forever. Measured on .NET 9: a fresh server throws InvalidOperationException
        # "Pipe hasn't been connected yet."; a disposed one throws ObjectDisposedException
        # "Cannot access a closed pipe." Only the second needs a rebuild, and only this
        # ordering tells them apart. (Caught by the guard's own disposed-server case.)
        if ($ex -is [System.ObjectDisposedException]) {
            return @{ Ok = $false; Reason = ('disposed: ' + $ex.Message) }
        }
        if ($ex -is [System.InvalidOperationException]) {
            # The empty-request path: nothing was ever connected, so there is nothing to
            # disconnect and the stream can already accept.
            return @{ Ok = $true; Reason = 'not connected (nothing to disconnect)' }
        }
        return @{ Ok = $false; Reason = ($ex.GetType().Name + ': ' + $ex.Message) }
    }
}

function Test-DaemonPipePresent {
    # Is the per-session daemon's named pipe PRESENT in the OS namespace right now?
    # This is the busy-vs-unreachable discriminator (dispatch 000225).
    #
    # A failed client connect tells you NOTHING about which of the two you are in.
    # Measured on Windows: a pipe whose single instance is BUSY and a pipe that does not
    # exist AT ALL both throw the SAME TimeoutException after the SAME elapsed time
    # (~2.00 s vs ~2.04 s at a 2000 ms timeout). There is no connect-refused to key on.
    # The pipe's PRESENCE separates them cleanly, because the daemon holds the name for
    # its whole life -- the server stream is disposed only in the daemon's exit finally
    # (pses-daemon.ps1) -- and a busy instance does not remove the name.
    #
    # NON-OWNING by design: it never CREATES the pipe and never takes its NAME, so it can
    # never race a daemon that is legitimately (re)starting. (Probing by trying to CREATE
    # the server would be platform-neutral but would own the name for the duration, which
    # is exactly the race a relaunch path must not introduce.) The unix arm does open a
    # client connection -- see below -- which is non-owning in that same sense: a client
    # connect cannot hold a pipe name against its server.
    #
    # FAIL-SAFE: any failure returns $false, which routes the caller down the pre-000225
    # relaunch path -- so a broken probe is never WORSE than the behavior it replaced.
    # Cost is off the warm path entirely (the caller asks only after a failed round-trip)
    # and measured at ~4 ms on Windows.
    param([string]$PipeName)
    if ([string]::IsNullOrWhiteSpace($PipeName)) { return $false }
    try {
        if (Test-OnWindows) {
            # Named pipes are enumerable under the NPFS root. Filter with the exact name
            # (cheaper than listing the ~470 pipes a desktop carries), then CONFIRM an
            # exact match, so a pattern metacharacter could only ever over-match and be
            # rejected here, never mis-report. Note Test-Path on \\.\pipe\<name> is NOT a
            # substitute: it returns $false even for a pipe that demonstrably exists.
            foreach ($entry in [System.IO.Directory]::GetFiles('\\.\pipe\', $PipeName)) {
                if ([System.IO.Path]::GetFileName($entry) -eq $PipeName) { return $true }
            }
            return $false
        }
        # Unix: .NET backs a named pipe with a socket file under the temp dir. Deriving
        # that path the same way the client's own NamedPipeClientStream does keeps the
        # probe self-consistent with the transport it is asking about.
        #
        # PRESENCE IS NOT LIVENESS OFF-WINDOWS (dispatch 000231). The Windows arm above can
        # key on the name alone because NPFS is kernel-managed: the name vanishes when the
        # owning process dies, however it dies. A unix socket file does not. .NET unlinks it
        # only when the server stream is DISPOSED, so a daemon that dies WITHOUT running its
        # exit finally -- killed, crashed, or reaped -- leaves the file behind, and a bare
        # presence test reports the corpse as a live daemon. That suppressed the relaunch and
        # broke the D3 required property (a genuinely unreachable daemon must still recover)
        # on ubuntu and macos, while both Windows legs passed. The first cut of this arm was
        # written by ANALOGY from the Windows measurement above and never measured off-Windows;
        # the two behave differently, so this arm now carries its own evidence.
        $sockPath = Get-DaemonPipeSocketPath -PipeName $PipeName
        if (-not (Test-Path -LiteralPath $sockPath)) { return $false }
        # The path exists; the remaining question is whether anyone is LISTENING on it. A
        # connect to a unix domain socket with no listener is refused by the kernel
        # (ECONNREFUSED), which .NET surfaces as a failed connect and, at the end of the
        # window, a TimeoutException -- so refusal is what separates a live daemon from a
        # stale file. A live-but-BUSY daemon still answers PRESENT, which is the case the
        # 000225 gate exists to protect: the kernel completes the connection into the listen
        # backlog even while the serve loop is analyzing and not accepting, and the daemon's
        # loop already tolerates a peer that sends nothing ('empty request', then it
        # continues). The window is deliberately small: it is paid only on the DEAD path,
        # after the caller has already spent its hard cap, and never on the warm path.
        $probe = $null
        try {
            $probe = New-Object System.IO.Pipes.NamedPipeClientStream(
                '.', $PipeName, [System.IO.Pipes.PipeDirection]::InOut,
                [System.IO.Pipes.PipeOptions]::Asynchronous)
            $probe.Connect(250)
            return $true
        } catch {
            return $false
        } finally {
            if ($null -ne $probe) { try { $probe.Dispose() } catch { } }
        }
    } catch {
        return $false
    }
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
        [int]$MaxWaitMs = 0,
        # requiredRules forward (P1-5 remainder, dispatch 000294): the SAME 'orgPolicy' userConfig
        # path lsp-client.ps1 already reads client-side, now ALSO threaded to the daemon so
        # Initialize-PssaSettings can consult RequiredRules. Empty (the default) emits no arg, so
        # the daemon takes its exact pre-000294 path -- byte-identical, no new userConfig knob.
        [string]$OrgPolicyPath = ''
    )
    $scriptsDir = Split-Path -Parent $script:LspCommonDir   # scripts/lib -> scripts
    if ([string]::IsNullOrWhiteSpace($scriptsDir)) { $scriptsDir = Split-Path -Parent $PSScriptRoot }
    $daemon = Join-Path $scriptsDir 'pses-daemon.ps1'
    $logDir = Get-LogDir
    try { New-ContainedDirectory -Path $logDir } catch { }
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
    if (-not [string]::IsNullOrWhiteSpace($OrgPolicyPath)) { $daemonArgs += @('-OrgPolicyPath', $OrgPolicyPath) }
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
    #
    # $Reason (dispatch 000299, W3-3) is an OPTIONAL third cause under the SAME token, for
    # managed-mode fail-closed on org policy: a missing or hash-mismatched policy under
    # POWERSHELL_LSP_POLICY_MODE=closed is not a PSES startup failure, so the generic
    # "editor services could not start" prose above would misdescribe the cause. CONTRACT.md
    # Tier 1.2 freezes the TOKEN and the clean-empty/non-ok-distinct-visible property, not the
    # banner prose (a wording refinement is a PATCH), so an optional parameter that leaves every
    # existing call byte-identical is additive, not a contract change. Unlike the PSES case, a
    # policy re-validates on the CALLER's own very next edit (lsp-client.ps1 re-reads the policy
    # fresh every invocation -- it is a short-lived hook process, not the long-lived daemon), so
    # this wording says "fix the policy", never "restart the session": that promise would be
    # false here and is exactly the distinction $Reason exists to carry correctly.
    param([string]$Status, [string]$Path, [string]$Reason = '')
    switch ($Status) {
        'incomplete'  { return ('PowerShell diagnostics unavailable for ' + $Path + ': analysis did not complete -- this edit was NOT checked.') }
        'degraded'    { return ('PowerShell diagnostics for ' + $Path + ': parser-only mode -- PSScriptAnalyzer unavailable, lint rules were NOT checked (syntax errors are still reported).') }
        'unavailable' {
            if (-not [string]::IsNullOrWhiteSpace($Reason)) {
                return ('PowerShell diagnostics unavailable for ' + $Path + ': ' + $Reason +
                    ' Diagnostics will stay OFF until this is fixed; this edit was NOT checked, and the next edit re-validates automatically (no restart needed).')
            }
            return ('PowerShell diagnostics unavailable for ' + $Path + ': PowerShell editor services could not start -- not installed (the bootstrap did not complete), or installed but failed to start. Diagnostics will stay OFF for this whole session until it is fixed and the session is restarted; this edit was NOT checked. See logs/ensure-pses.log and logs/pses-daemon.log.')
        }
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

function Find-ProhibitedSuppression {
    <#
    .SYNOPSIS
        Flag a [SuppressMessageAttribute(...)] that names an org-prohibited PSScriptAnalyzer
        rule (P1-5 remainder, R23=D member B, dispatch 000294).
    .DESCRIPTION
        PURE over the supplied AST and an explicit prohibited-rule-name list. Unlike its
        siblings (Find-BashIsm etc.), this finder needs org policy data, so it stays pure by
        taking that data as a parameter rather than reading the policy file itself -- the
        caller resolves $OrgPolicy.ProhibitedSuppressions ONCE, the same way every other
        org-aware surface in this file already does. Returns @() when the AST is $null, the
        prohibited list is empty (the knob-off / no-policy default), or no matching attribute
        is present.

        Matches an AttributeAst whose type name's LAST dot-separated segment is 'SuppressMessage'
        or 'SuppressMessageAttribute' case-insensitively -- covering the fully-qualified form
        (System.Diagnostics.CodeAnalysis.SuppressMessageAttribute), the conventional PSSA form
        (Diagnostics.CodeAnalysis.SuppressMessageAttribute), and the bare form a `using
        namespace System.Diagnostics.CodeAnalysis` statement permits. The rule name is read ONLY
        from a literal string first positional argument (PSScriptAnalyzer's own suppression
        convention: category/rule name first, then an optional CheckId) -- a non-literal first
        argument (a variable, an expression) cannot be resolved statically and is never guessed,
        so it is silently not flagged (fail-open: this finder reports a suppression it can prove,
        never one it assumes).

        This reports the SUPPRESSION, not the underlying finding PSSA itself hid -- the true
        re-surfacing half (R23=D member A, a second -IncludeSuppressed analyzer pass) lives in
        lsp-scan.ps1 for the repository/CI path, per the docket's own cost table: PSES's settings
        object carries no suppression-aware property, so the daemon cannot re-run the analyzer
        with -IncludeSuppressed per edit without the cost R23 declined for the edit path.
        Finding source = 'powershell-lsp', ruleId/code = 'ProhibitedSuppression', severity
        'Warning' -- the same shape and channel as Find-BashIsm / Find-Ps7OnlySyntax.

        HOST / StrictMode SAFETY: every AST member read is guarded and TypeKind/Kind comparisons
        are never used here (AttributeAst exposes no enum to compare), so this runs silent under
        Windows PowerShell 5.1 + StrictMode exactly like the rest of the pre-PSSA pack.

        Adversarial control: require an exact FullName match instead of the last-segment split
        and a `using namespace`-qualified attribute (bare 'SuppressMessage') goes undetected;
        drop the StringConstantExpressionAst type check and a computed first argument would need
        evaluation this finder cannot safely do; use an ordinal-case-sensitive compare for the
        prohibited-rule set and a differently-cased prohibited name silently stops matching;
        return on an attribute with zero positional arguments without the explicit Count check
        and a bare [SuppressMessage()] indexes out of range instead of being skipped.
    #>
    param($Ast, [string[]]$ProhibitedRules)
    if ($null -eq $Ast) { return @() }
    $prohibited = @($ProhibitedRules | Where-Object { $_ })
    if ($prohibited.Count -eq 0) { return @() }
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $prohibited) { [void]$set.Add(([string]$p).Trim()) }

    $nodes = @()
    try {
        $nodes = @($Ast.FindAll({ param($n) $n.GetType().Name -eq 'AttributeAst' }, $true))
    } catch { return @() }

    $findings = New-Object System.Collections.ArrayList
    foreach ($node in $nodes) {
        $typeName = ''
        try { $typeName = [string]$node.TypeName.FullName } catch { $typeName = '' }
        if ([string]::IsNullOrWhiteSpace($typeName)) { continue }
        $segments = $typeName.Split('.')
        $lastSegment = $segments[$segments.Length - 1]
        if ($lastSegment -ne 'SuppressMessage' -and $lastSegment -ne 'SuppressMessageAttribute') { continue }

        $posArgs = @()
        try { $posArgs = @($node.PositionalArguments) } catch { $posArgs = @() }
        if ($posArgs.Count -eq 0) { continue }
        $first = $posArgs[0]
        $ruleName = ''
        try {
            if ($first.GetType().Name -eq 'StringConstantExpressionAst') { $ruleName = [string]$first.Value }
        } catch { $ruleName = '' }
        $ruleName = $ruleName.Trim()
        if ([string]::IsNullOrWhiteSpace($ruleName)) { continue }
        if (-not $set.Contains($ruleName)) { continue }

        $line = 1; $col = 1
        try { $line = [int]$node.Extent.StartLineNumber } catch { $line = 1 }
        try { $col = [int]$node.Extent.StartColumnNumber } catch { $col = 1 }
        [void]$findings.Add([pscustomobject]@{
                ruleId = 'ProhibitedSuppression'; code = 'ProhibitedSuppression'
                source = 'powershell-lsp'
                severity = 'Warning'; line = $line; col = $col
                message = "SuppressMessageAttribute names '" + $ruleName + "', which org policy " +
                    'prohibits suppressing. The underlying PSScriptAnalyzer finding is hidden by ' +
                    'this attribute; remove the suppression or resolve the finding it hides.'
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
    # No $sep/$alt here: unlike Resolve-PssaSettingsPath, this walk has no
    # ProjectRoot to bound against, so it never trims separators -- it ascends
    # via GetDirectoryName and stops when that returns empty at the filesystem
    # root. The two variables were carried over with the walking pattern and
    # were never read (PSUseDeclaredVarsMoreThanAssignments, GH-AUDIT-026).
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

function Get-ExportNameLiteral {
    # Resolve ONE Export-ModuleMember value node to the literal names it denotes
    # (dispatch 000159 leg 2). Returns:
    #   @{ Names = @(...); Literal = $true }   fully resolvable from literal string constants
    #   @{ Names = @();    Literal = $false }  anything else -- the caller must DEGRADE
    #
    # WHY THIS EXISTS. The collector previously accepted only a bare
    # StringConstantExpressionAst, so a MULTI-NAME export list -- in either idiomatic
    # form -- was skipped entirely:
    #     Export-ModuleMember -Function 'Get-A', 'Get-B'     one ArrayLiteralAst
    #     Export-ModuleMember -Function @('Get-A','Get-B')   one ArrayExpressionAst
    # Nothing was collected, the exported set stayed empty, and the caller read that as
    # "no explicit Export-ModuleMember" and assumed export-all -- so every PRIVATE
    # function was reported as an under-declared export. Measured on the plugin's own
    # dogfood-reader.psm1: 13 false warnings, one per private function.
    #
    # CONSERVATIVE BY CONSTRUCTION. Literal is $false unless EVERY element resolves to a
    # literal string. A mixed list ('Get-A', $name) must not half-resolve: a partial set
    # read as complete would turn this fix into a NEW false-positive source, which is
    # strictly worse than the silence it replaces. Silence, never a guess.
    param($Node)
    $empty = @{ Names = @(); Literal = $false }
    if ($null -eq $Node) { return $empty }

    if ($Node -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return @{ Names = @($Node.Value); Literal = $true }
    }

    # 'A', 'B' -- a comma-separated list is ONE ArrayLiteralAst argument.
    if ($Node -is [System.Management.Automation.Language.ArrayLiteralAst]) {
        $acc = New-Object System.Collections.Generic.List[string]
        foreach ($el in @($Node.Elements)) {
            $sub = Get-ExportNameLiteral $el
            if (-not $sub.Literal) { return $empty }
            foreach ($n in @($sub.Names)) { $acc.Add($n) }
        }
        return @{ Names = @($acc); Literal = $true }
    }

    # @('A','B') -- an ArrayExpressionAst wrapping a statement block. Walk it strictly:
    # any shape other than plain command-expression statements is not statically known.
    if ($Node -is [System.Management.Automation.Language.ArrayExpressionAst]) {
        $acc = New-Object System.Collections.Generic.List[string]
        $sb = $Node.SubExpression
        if ($null -eq $sb) { return $empty }
        foreach ($st in @($sb.Statements)) {
            if (-not ($st -is [System.Management.Automation.Language.PipelineAst])) { return $empty }
            $pe = @($st.PipelineElements)
            if ($pe.Count -ne 1) { return $empty }
            if (-not ($pe[0] -is [System.Management.Automation.Language.CommandExpressionAst])) { return $empty }
            $sub = Get-ExportNameLiteral $pe[0].Expression
            if (-not $sub.Literal) { return $empty }
            foreach ($n in @($sub.Names)) { $acc.Add($n) }
        }
        # @() with no statements is a literal EMPTY list, not an unknown one.
        return @{ Names = @($acc); Literal = $true }
    }

    # Variables, member/method invocations, binary expressions, sub-expressions: unknown.
    return $empty
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
                                    } elseif ($val -is [System.Management.Automation.Language.ArrayLiteralAst] -or
                                        $val -is [System.Management.Automation.Language.ArrayExpressionAst]) {
                                        # Multi-name export list (dispatch 000159 leg 2), in either idiomatic
                                        # form: 'A', 'B' parses as ONE ArrayLiteralAst and @('A','B') as ONE
                                        # ArrayExpressionAst, so neither is a StringConstantExpressionAst and
                                        # both were skipped whole -- leaving the exported set empty, which the
                                        # caller then read as "no explicit Export-ModuleMember" and answered
                                        # with export-all. Resolve the list only when EVERY element is a
                                        # literal; a mixed list degrades to silence rather than half-resolving
                                        # into a set that would read as complete.
                                        $lit = Get-ExportNameLiteral $val
                                        if (-not $lit.Literal) { $hasDynamic = $true; break }
                                        if ($collectFn) { foreach ($n in @($lit.Names)) { $exported.Add($n) } }
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
    # for orphan/typo exports and alias-orphan exports.
    #
    # Returns @{ Findings = @(...); Degrade = '' } for determinate shapes.
    # Returns @{ Findings = @(); Degrade = '<reason>' } for indeterminate (wildcard,
    #   dynamic, dot-source, etc.) -- the caller surfaces "cannot determine" as prose.
    #
    # orphan-export: a name in FunctionsToExport/CmdletsToExport/AliasesToExport
    #   that does not match any defined function name in the module.
    #
    # There were once THREE rungs here. Rung 2, under-declared-export, was REMOVED by
    # dispatch 000162 (ruled by Mike Andersen 2026-07-29) because it was wrong by design,
    # not merely buggy -- see the gap marker at rung 2 below for the measurement.
    param(
        [string[]]$FunctionsToExport,
        [string[]]$CmdletsToExport,
        [string[]]$AliasesToExport,
        [string[]]$DefinedNames,
        # RETAINED BUT NO LONGER READ (dispatch 000162): the removed under-declared rung was
        # this parameter's only consumer. It stays in the signature deliberately -- callers and
        # tests still pass it, the caller still computes it to decide whether the module surface
        # DEGRADES, and dropping it would break those call sites for no behavioural gain.
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
    # Determine what the module actually defines. Only FunctionsToExport is cross-referenced
    # (CmdletsToExport and AliasesToExport are recorded but not matched against definitions --
    # the survey's deterministic subset focuses on function exports).
    $moduleDefinedSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $DefinedNames) { [void]$moduleDefinedSet.Add($n) }
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
    # 2. UNDER-DECLARED EXPORT -- REMOVED, not disabled and not narrowed (dispatch 000162,
    #    ruled by Mike Andersen 2026-07-29). This rung reported every function the module
    #    defined and exported that FunctionsToExport omitted. It was WRONG BY DESIGN: for a
    #    determinate non-wildcard FunctionsToExport, the manifest IS the export gate -- it
    #    DETERMINES the exported surface rather than describing it -- so "defined by the module
    #    but absent from the manifest" is the normal, correct state of every well-formed module
    #    that has private functions. The rung asserted correctness was a defect.
    #
    #    Measured before removal on a 36-module live oracle (dispatch 000161 leg 3, reproduced
    #    by 000162 leg 1): 911 hits, of which ZERO named a function PowerShell actually exports
    #    -- 100% false positive, 0 true positives. The one candidate narrowing (fire only where
    #    the .psm1 carries an explicit Export-ModuleMember) still measured 96.15% FP, so no
    #    subclass reached a defensible rate and there was nothing to narrow TO.
    #
    #    Deliberately NOT solved with an orgPolicy default: that papers a source defect with
    #    config and makes the ruleset's honesty conditional on deployment. A known-100%-FP rung
    #    left in a shipping ruleset teaches users to ignore the diagnostic surface, which costs
    #    the SOUND rungs their signal -- that, not the noise volume, was the reason to remove it.
    #
    #    The numbering is left with a gap on purpose: rungs 1 and 3 keep the identities that the
    #    CHANGELOG, ROADMAP and rule-rationale docs already cite, and "rung 2 of 3" stays
    #    resolvable to what it always meant.
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

    # LedgerKeys (dispatch 000171 leg 2) -- ADDITIVE, and deliberately NOT part of the payload.
    # Cleared/StillPresent carry {ruleId, line, message} and no hash, because the daemon payload
    # never needed one. The per-rule lifecycle log DOES: the shape hash is its join key back to
    # dogfood/diagnostics.jsonl. Rather than widen the two payload arrays (which the client
    # renders) or re-derive the hashes at the call site (which would duplicate this function's
    # own matching logic), the keys ride out alongside them.
    #
    # Cleared/StillPresent/NewMap are byte-identical to before, so Add-LifecycleSignal's payload
    # and every existing test that asserts on them are unaffected.
    $clearedKeys = New-Object System.Collections.ArrayList
    foreach ($h in @($PriorMap.Keys)) {
        $hk = [string]$h
        if ($fullHashes.Contains($hk)) { continue }
        [void]$clearedKeys.Add([pscustomobject]@{ hash = $hk; ruleId = [string]$PriorMap[$hk]['ruleId'] })
    }
    $stillKeys = New-Object System.Collections.ArrayList
    foreach ($sp in @($stillPresent)) {
        # Re-associate each emitted still-present entry with the surfaced finding it came from.
        # $curSurf is this turn's surfaced set, already projected to {hash; ruleId; line; message},
        # so the match is on identity of the emitted record, not a re-derivation of the hash.
        foreach ($r in $curSurf) {
            if ([string]$r.ruleId -eq [string]$sp.ruleId -and [int]$r.line -eq [int]$sp.line -and
                [string]$r.message -eq [string]$sp.message) {
                [void]$stillKeys.Add([pscustomobject]@{
                    hash = [string]$r.hash; ruleId = [string]$r.ruleId
                    attempts = [int]$sp.attempts; downgraded = [bool]$sp.downgraded })
                break
            }
        }
    }

    return @{ Cleared = @($cleared); StillPresent = @($stillPresent); NewMap = $newMap
        LedgerKeys = @{ cleared = @($clearedKeys.ToArray()); stillPresent = @($stillKeys.ToArray()) } }
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
