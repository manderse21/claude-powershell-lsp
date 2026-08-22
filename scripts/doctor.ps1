#Requires -Version 5.1

# doctor.ps1 -- preflight self-check for the powershell-lsp plugin. Turns the worst
# onboarding failure mode -- the plugin is enabled but a prerequisite is missing, so
# diagnostics silently do nothing -- into a named, actionable fix-list.
#
# REPORT-ONLY by design (dispatch 000036). It checks prerequisites and bootstrap
# health and tells you how to fix what is wrong; it NEVER downloads, repairs, runs the
# bootstrap, or mutates the environment in any way. (The hub's own 'dispatch doctor
# --fix' is unrelated -- this is the plugin's read-only doctor.)
#
# Each check returns one of three statuses, reusing the plugin's never-silent honesty
# (000024/000028): 'pass'; a specific 'fail' that names the blocked component AND the
# remediation (tied to the README Requirements / Install / Troubleshooting); or an
# honest 'unknown' when it genuinely cannot determine (for example when run outside a
# Claude Code session, where it cannot see the plugin data directory). "Could not check"
# is never silently reported as "checked, fine."
#
# SECURITY BOUNDARY (dispatch 000036, hard fence): this doctor does NOT detect or
# diagnose security-control blocks (WDAC / App Control / AppLocker / ExecutionPolicy /
# Smart App Control / Constrained Language Mode). That surface is the separate ROADMAP
# L3 security track (survey 000032), which on disk has not built a detection surface
# yet. So for an indeterminate failure the doctor emits only a single GENERIC pointer
# (a security control may be blocking the component; see Troubleshooting and the
# forthcoming security work). Zero control-specific probing here.
#
# Usage:  pwsh -File scripts/doctor.ps1
#         pwsh -File scripts/doctor.ps1 -SessionId <claude-code-session-id>   # scope check 6
#         pwsh -File scripts/doctor.ps1 -ProbeNativeServe                     # add opt-in check 7
#
# Exit 0 when no check FAILED (passes and honest unknowns are not failures); exit 1
# when at least one check failed. The script is dot-source safe: dot-sourcing defines
# the functions without running the checks (so the unit tests can exercise the pure
# decision functions in isolation).
#
# Author: Mike Andersen / powershell-lsp plugin.

param(
    # Optional Claude Code session id to scope the daemon-health check (check 6) to a
    # specific session's warm daemon. Empty (default) resolves from $env:CLAUDE_SESSION_ID,
    # then discovers the live daemon(s) under the session data dir. A standalone run has no
    # session id (Claude Code passes it only on hook stdin, never as an env var to a
    # directly-invoked script), so the daemon check stays honest about what it can determine.
    [string] $SessionId = '',

    # OPT-IN (dispatch 000104): also run the native-serve REMOVABILITY probe (check 7). It launches
    # PSES via the DIRECT launcher (scripts/pses-stdio.ps1, shim bypassed), sends a Claude-Code-shaped
    # initialize, and reports whether native serve is still gated on the upstream #1359 handshake
    # (today) or now serves statically (the nativeServe shim can be removed). It costs a PSES
    # cold-start plus a bounded init wait, so it is OFF by default -- the routine doctor stays fast
    # and this check appears ONLY when requested. Report-only, like every other check.
    [switch] $ProbeNativeServe,

    # Compact rendering (dispatch 000166 B10): one line per check plus the summary, with the
    # per-check detail and remediation prose omitted. It is a RENDERING over the SAME
    # Invoke-Doctor seam -- the checks that run, their statuses, and the exit code are
    # byte-for-byte identical to a normal run; only the presentation differs. This is what the
    # /powershell-lsp:status command surfaces, so a health glance costs one screen instead of
    # scrolling a full fix-list.
    [switch] $Summary
)

. (Join-Path $PSScriptRoot 'lib/lsp-common.ps1')
# The lifecycle READ side (dispatch 000216) -- Resolve-LifecycleLogSearch / Read-LifecycleLog /
# Get-LifecycleProvenanceFloor, the single source the efficacy ledger renders its own floor from.
# Loaded AFTER lsp-common.ps1, which it depends on.
. (Join-Path $PSScriptRoot 'lib/lifecycle-provenance.ps1')

# The native-serve removability probe's init-result wait bound (dispatch 000104, OQ2). Measured:
# the direct launcher's initialize RESULT arrives ~1.9 s (warm, this repo's Windows dev host); the
# 000102 survey measured the LATEST init-phase server->client event (client/registerCapability) at
# +7.8 s. 20 s is ~2.5x that latest landmark and ~10x the observed init, giving margin on the
# slowest cold CI leg. The discriminator is the init RESULT CONTENT (are the nav providers
# advertised statically?), NOT a race against the ~30 s registration stall, so exceeding this bound
# reports UNKNOWN (PSES did not init in time) -- never a false "still gated".
$script:NativeServeInitTimeoutMs = 20000

# ===========================================================================
# Pure decision functions -- env-independent, mockable, unit-tested. Each takes
# already-resolved probe inputs and returns a status object. No I/O here, so the
# decision logic is testable without a live PSES install or network.
# ===========================================================================

function New-DoctorResult {
    # The one status-object shape. ValidateSet pins the vocabulary to pass/fail/unknown
    # (the inbox rule: do not invent new status words) -- an out-of-set status throws.
    param(
        [Parameter(Mandatory = $true)][ValidateSet('pass', 'fail', 'unknown')][string] $Status,
        [Parameter(Mandatory = $true)][string] $Component,
        [string] $Detail = '',
        [string] $Remediation = ''
    )
    return [pscustomobject]@{
        Status      = $Status
        Component   = $Component
        Detail      = $Detail
        Remediation = $Remediation
    }
}

function Test-DoctorPwsh {
    # Check 1: PowerShell 7+ (pwsh) is present and new enough. The plugin's hooks launch
    # under pwsh (README Requirements), so a missing or too-old pwsh means nothing runs.
    # $Found = pwsh on PATH; $Version = its resolved [version] (or $null if undeterminable).
    param([bool] $Found, [version] $Version)
    $component = 'PowerShell 7 (pwsh) host'
    $install = 'Install PowerShell 7: "winget install Microsoft.PowerShell" or https://aka.ms/powershell (README: Requirements).'
    if (-not $Found) {
        return (New-DoctorResult -Status fail -Component $component `
                -Detail 'pwsh was not found on PATH; the plugin hooks launch under pwsh and cannot start without it.' `
                -Remediation $install)
    }
    if ($null -eq $Version) {
        return (New-DoctorResult -Status unknown -Component $component `
                -Detail 'pwsh is on PATH but its version could not be determined.' `
                -Remediation 'Confirm with "pwsh -v" that it reports PowerShell 7 or newer.')
    }
    if ($Version.Major -lt 7) {
        return (New-DoctorResult -Status fail -Component $component `
                -Detail ('found pwsh ' + $Version.ToString() + ' but PowerShell 7+ is required for the hooks (Windows PowerShell 5.1 alone cannot launch them).') `
                -Remediation $install)
    }
    return (New-DoctorResult -Status pass -Component $component `
            -Detail ('pwsh ' + $Version.ToString() + ' is present and satisfies the PowerShell 7+ requirement.'))
}

function Test-DoctorPsHost {
    # Check: does the configured `ps_host` -- the PSES CHILD host -- actually resolve (dispatch
    # 000203 survey failure class F11)?
    #
    # The gap this closes: check 1 validates `pwsh`, the HOOK INTERPRETER. `ps_host` is a
    # DIFFERENT value. It selects the executable that hosts PowerShell Editor Services
    # (docs/troubleshooting.md:24 states the distinction explicitly), and until this check the
    # doctor read it zero times. Conflating the two is the mistake this check exists to prevent,
    # so it names the child host in its own component line rather than folding into check 1.
    #
    # WHY IT IS FAIL-CAPABLE, when almost every other added check is not: the shipped resolver
    # FALLS BACK. Resolve-PsHost (lib/lsp-common.ps1) tries the configured value, then 'pwsh',
    # then 'powershell', and returns the first that resolves -- so a `ps_host` naming an
    # executable that is not there does not error, it is silently REPLACED. All three shipped
    # consumers read it that way (lsp-client.ps1:209, pses-serve-shim.ps1:85, and
    # session-start.ps1:53 via $PreferredHost). The user gets a working plugin that is ignoring
    # their configuration, with nothing anywhere saying so. That is a real, dated, silent
    # failure of a deliberate setting, which is exactly the class that earns a FAIL.
    #
    #   knob value not resolvable (outside a session)  -> UNKNOWN
    #   ps_host is unset / at its default ('pwsh')     -> UNKNOWN, deferring to check 1
    #   set to a non-default value that RESOLVES       -> PASS, naming it
    #   set to a non-default value that does NOT       -> FAIL (the silent-substitution case)
    #
    # The default branch is UNKNOWN rather than PASS on purpose. At the default this check has
    # nothing of its OWN to report -- check 1 already decides whether `pwsh` is present, and a
    # PASS here would be a second, independently-derived opinion about the same executable that
    # could disagree with check 1 and would double-count in the summary counts.
    #
    #   $Determinable : the knob value could be read.
    #   $Reason       : when not determinable, the honest why.
    #   $Value        : the effective ps_host value.
    #   $IsDefault    : that value is the shipped default ('pwsh') -- unset and explicitly-'pwsh'
    #                   are the same observable state and are treated as one.
    #   $Found        : the value resolved through Get-Command.
    #   $ResolvedPath : what it resolved to (named in the PASS, so the answer is checkable).
    param(
        [bool] $Determinable,
        [string] $Reason = '',
        [string] $Value = '',
        [bool] $IsDefault = $false,
        [bool] $Found = $false,
        [string] $ResolvedPath = ''
    )
    $component = 'PSES child host (ps_host)'
    if (-not $Determinable) {
        $why = if ([string]::IsNullOrWhiteSpace($Reason)) {
            'the plugin knob values could not be resolved in this context.'
        } else { $Reason }
        return (New-DoctorResult -Status unknown -Component $component `
                -Detail ('not determined -- ' + $why) `
                -Remediation ('Run the doctor from inside an enabled Claude Code session so the ' +
                    'knob values resolve.'))
    }
    if ($IsDefault) {
        return (New-DoctorResult -Status unknown -Component $component `
                -Detail ('ps_host is at its default ("' + $Value + '"), so this check defers to ' +
                    'the PowerShell 7 (pwsh) host check above rather than deciding the same ' +
                    'executable twice. It reports on its own only when ps_host names something ' +
                    'else -- the PSES child host is a DISTINCT value from the hook interpreter.') `
                -Remediation ('Nothing to do. Set ps_host only if PSES must run under a ' +
                    'different host than pwsh; see docs/configuration.md#ps_host.'))
    }
    if ($Found) {
        $where = if ([string]::IsNullOrWhiteSpace($ResolvedPath)) { '' } else { ' (' + $ResolvedPath + ')' }
        return (New-DoctorResult -Status pass -Component $component `
                -Detail ('ps_host = "' + $Value + '" resolves on PATH' + $where + ', so PSES will ' +
                    'be hosted by the executable you configured. This is the PSES child host; the ' +
                    'hook interpreter is checked separately above.'))
    }
    return (New-DoctorResult -Status fail -Component $component `
            -Detail ('ps_host = "' + $Value + '" does NOT resolve on PATH, and this fails SILENTLY ' +
                'rather than loudly: the shipped resolver falls back to pwsh, then powershell, so ' +
                'PSES is hosted by whichever of those exists and your configured host is ignored ' +
                'with no error anywhere. The plugin appears to work while disregarding the setting.') `
            -Remediation ('Install "' + $Value + '" or put it on PATH, set ps_host to an ' +
                'executable that exists ("pwsh" or "powershell"), or clear it to accept the ' +
                'default; see docs/configuration.md#ps_host.'))
}

function Test-DoctorEnabled {
    # Check 2: the plugin is enabled. It ships disabled by default (defaultEnabled:false).
    # The only enablement signal the plugin can observe of ITSELF is its subprocess
    # environment: Claude Code sets CLAUDE_PLUGIN_ROOT for plugin subprocesses.
    # $PluginRootResolved = $true when that env points at THIS plugin. Outside a plugin
    # subprocess we cannot read Claude Code's enabled-plugins registry without inventing
    # its location/schema, so the honest result is UNKNOWN -- never a fabricated fail.
    param([bool] $PluginRootResolved)
    $component = 'Plugin enabled'
    if ($PluginRootResolved) {
        return (New-DoctorResult -Status pass -Component $component `
                -Detail 'the plugin is loaded in this Claude Code session (its plugin environment is present).')
    }
    return (New-DoctorResult -Status unknown -Component $component `
            -Detail 'cannot confirm enablement from outside a Claude Code plugin subprocess (the plugin ships disabled by default).' `
            -Remediation 'Enable it with "/plugin enable powershell-lsp" then start a new session (README: Install). Run this doctor from inside an enabled session for a definitive check.')
}

function Test-DoctorPses {
    # Check 3: the PSES bundle finished bootstrapping. Healthy iff BOTH the per-pin marker
    # AND Start-EditorServices.ps1 are present -- the EXACT pair ensure-pses.ps1 gates its
    # no-op on and pses-stdio.ps1 launches. $DataRootKnown is $false when CLAUDE_PLUGIN_DATA
    # is unset: the doctor then cannot locate the real data dir, so it must NOT report a
    # false "not bootstrapped" -- it returns UNKNOWN.
    param([bool] $DataRootKnown, [bool] $MarkerPresent, [bool] $StartScriptPresent, [string] $PinTag = '')
    $component = 'PSES bundle bootstrapped'
    if (-not $DataRootKnown) {
        return (New-DoctorResult -Status unknown -Component $component `
                -Detail 'cannot locate the plugin data directory (CLAUDE_PLUGIN_DATA is not set), so the bundle state is indeterminate.' `
                -Remediation ('CLAUDE_PLUGIN_DATA is unset in THIS shell. Claude Code ' +
                    'exports it to the plugin''s own hooks -- NOT to tool shells or a ' +
                    'directly-invoked script -- so merely being inside a session does not ' +
                    'set it, and re-running here will not either. Set it to the plugin data ' +
                    'directory (the one holding session/ and logs/) and re-run, or run ' +
                    '/powershell-lsp:doctor so the check runs as the plugin.'))
    }
    if ($MarkerPresent -and $StartScriptPresent) {
        return (New-DoctorResult -Status pass -Component $component `
                -Detail ('the PSES ' + $PinTag + ' bundle is bootstrapped (marker present and Start-EditorServices.ps1 in place).'))
    }
    $missing = @()
    if (-not $MarkerPresent) { $missing += ('the bootstrap marker (pses-' + $PinTag + '.ok)') }
    if (-not $StartScriptPresent) { $missing += 'Start-EditorServices.ps1' }
    return (New-DoctorResult -Status fail -Component $component `
            -Detail ('the PSES bundle did not finish bootstrapping -- missing ' + ($missing -join ' and ') + '.') `
            -Remediation 'Start a fresh Claude Code session so the SessionStart hook runs ensure-pses; if it persists, the first-run download was likely interrupted (network/proxy) -- see logs/ensure-pses.log (README: Troubleshooting).')
}

function Test-DoctorPssa {
    # Check 4: PSScriptAnalyzer is vendored AND importable. Healthy iff BOTH the per-version
    # marker is present AND the module imports (mirrors ensure-pssa.ps1's own fast-path test).
    # If only the parser runs, analysis is "degraded" (lint rules not checked). Same
    # data-root-unknown -> UNKNOWN rule as the PSES check.
    param([bool] $DataRootKnown, [bool] $MarkerPresent, [bool] $Importable, [string] $PinVersion = '')
    $component = 'PSScriptAnalyzer vendored'
    if (-not $DataRootKnown) {
        return (New-DoctorResult -Status unknown -Component $component `
                -Detail 'cannot locate the plugin data directory (CLAUDE_PLUGIN_DATA is not set), so the analyzer state is indeterminate.' `
                -Remediation ('CLAUDE_PLUGIN_DATA is unset in THIS shell. Claude Code ' +
                    'exports it to the plugin''s own hooks -- NOT to tool shells or a ' +
                    'directly-invoked script -- so merely being inside a session does not ' +
                    'set it, and re-running here will not either. Set it to the plugin data ' +
                    'directory (the one holding session/ and logs/) and re-run, or run ' +
                    '/powershell-lsp:doctor so the check runs as the plugin.'))
    }
    if ($MarkerPresent -and $Importable) {
        return (New-DoctorResult -Status pass -Component $component `
                -Detail ('PSScriptAnalyzer ' + $PinVersion + ' is vendored and importable.'))
    }
    $why = if (-not $MarkerPresent) { 'the vendor marker (.pssa-' + $PinVersion + '.ok) is missing' } else { 'the vendored module is not importable' }
    return (New-DoctorResult -Status fail -Component $component `
            -Detail ('PSScriptAnalyzer ' + $PinVersion + ' is not ready -- ' + $why + '; analysis would run parser-only (degraded -- lint rules NOT checked).') `
            -Remediation 'Start a fresh session so ensure-pssa re-vendors the analyzer; see logs/ensure-pssa.log (README: Diagnostics status, "degraded").')
}

function Get-DoctorMarkerLayer {
    # Read the artifact-source layer an ensure-script recorded in its install marker (000244).
    # Returns '' for every ambiguous outcome -- absent marker, empty marker (every marker written
    # before 000244), unreadable file -- so the caller reports an honest UNKNOWN instead of
    # turning a read failure into a claim about provenance.
    #
    # The value is CONSTRAINED to the known layer vocabulary. A marker is a file under a
    # user-writable data directory; echoing arbitrary content of it into the doctor's output
    # would let that file dictate what the diagnostic says.
    param([string] $MarkerPath)
    try {
        if ([string]::IsNullOrWhiteSpace($MarkerPath)) { return '' }
        if (-not (Test-Path -LiteralPath $MarkerPath -PathType Leaf)) { return '' }
        $raw = (Get-Content -LiteralPath $MarkerPath -Raw -ErrorAction Stop)
        if ($null -eq $raw) { return '' }
        $value = $raw.Trim()
        $known = @('mirror', 'bundle', 'cache', 'download', 'gallery-fallback')
        if ($known -contains $value) { return $value }
        return ''
    } catch { return '' }
}

function Test-DoctorArtifactSource {
    # Check: WHICH artifact source layer produced the installed dependencies (dispatch 000244).
    #
    # PASS ON ANY LAYER is the whole design. This check does not have an opinion about which
    # source is better -- mirror, bundle, cache and download all feed the identical SHA-256 pin
    # gate, so an install is exactly as trustworthy whichever one produced it. What the check
    # exists to do is ANSWER THE QUESTION "where did these bytes come from?", which before 000244
    # nothing on the machine could answer at all.
    #
    # It reads the layer RECORDED IN THE MARKER at install time, never today's environment. The
    # env vars can change after an install, and re-deriving provenance from current configuration
    # would confidently describe an install that never happened that way.
    #
    #   data root unknown (outside a session)          -> UNKNOWN
    #   no layer recorded on either marker             -> UNKNOWN (pre-000244 markers, or nothing
    #                                                     bootstrapped) -- never a fabricated PASS
    #   any layer recorded                             -> PASS, naming each component's layer
    param([bool] $DataRootKnown, [string] $PsesLayer = '', [string] $PssaLayer = '')
    $component = 'Artifact source'
    if (-not $DataRootKnown) {
        return (New-DoctorResult -Status unknown -Component $component `
                -Detail 'cannot locate the plugin data directory (CLAUDE_PLUGIN_DATA is not set), so the installed artifacts'' source is indeterminate.' `
                -Remediation ('CLAUDE_PLUGIN_DATA is unset in THIS shell. Claude Code ' +
                    'exports it to the plugin''s own hooks -- NOT to tool shells or a ' +
                    'directly-invoked script -- so merely being inside a session does not ' +
                    'set it, and re-running here will not either. Set it to the plugin data ' +
                    'directory (the one holding session/ and logs/) and re-run, or run ' +
                    '/powershell-lsp:doctor so the check runs as the plugin.'))
    }
    $known = @()
    if (-not [string]::IsNullOrWhiteSpace($PsesLayer)) { $known += ('PSES from ' + $PsesLayer) }
    if (-not [string]::IsNullOrWhiteSpace($PssaLayer)) { $known += ('PSScriptAnalyzer from ' + $PssaLayer) }
    if ($known.Count -eq 0) {
        return (New-DoctorResult -Status unknown -Component $component `
                -Detail 'no install marker records an artifact source; the markers predate this feature, or nothing has been bootstrapped yet.' `
                -Remediation 'Start a fresh session to re-run the bootstrap, which records the source it resolved.')
    }
    # The Gallery fallback is the one acquisition route the SHA-256 pin does NOT gate (it rests on
    # the Gallery''s publisher/catalog integrity instead). It is still a real, working install, so
    # it PASSES -- but the detail says so plainly rather than letting a green tick imply the pin
    # verified it. See TRUST.md, "What it downloads".
    $detail = ($known -join '; ') + '.'
    if ($PssaLayer -eq 'gallery-fallback') {
        $detail += ' NOTE: the gallery-fallback route is not SHA-256 pin-gated -- it relies on the PowerShell Gallery''s own publisher/catalog integrity.'
    }
    return (New-DoctorResult -Status pass -Component $component -Detail $detail)
}

function Test-DoctorOfflineReadiness {
    # Check: could this machine bootstrap with no internet access (dispatch 000244)?
    #
    # THE HONEST-VERDICT RULE that shapes every branch below: only a BUNDLE can be proven ready
    # by this check, because proving readiness means hashing the artifacts against the pins, and
    # only a bundle''s artifacts are on local disk. A mirror would have to be DOWNLOADED to be
    # hashed, and a doctor that pulls tens of megabytes is not a doctor. So a configured mirror
    # that is well-formed yields UNKNOWN with the reason stated, never a PASS that would claim a
    # verification this check did not perform.
    #
    #   neither source configured                      -> UNKNOWN (the default; nothing to say)
    #   configured but unusable (bad scheme/path)      -> FAIL (a deliberate setting that cannot work)
    #   bundle holds both artifacts, both pin-valid    -> PASS
    #   bundle missing an artifact                     -> FAIL, naming which
    #   bundle artifact present but pin-INVALID        -> FAIL, loudly (stale or tampered)
    #   only a mirror, well-formed                     -> UNKNOWN, saying why it cannot be proven
    param(
        [bool] $MirrorConfigured, [bool] $MirrorValid, [string] $MirrorReason = '',
        [bool] $BundleConfigured, [bool] $BundleValid, [string] $BundleReason = '',
        [object[]] $BundleArtifacts = @()
    )
    $component = 'Offline readiness'
    $remediate = 'See docs/configuration.md, "Offline and air-gapped installation", for POWERSHELL_LSP_ARTIFACT_BUNDLE_DIR and POWERSHELL_LSP_ARTIFACT_MIRROR_BASE.'

    if (-not $MirrorConfigured -and -not $BundleConfigured) {
        return (New-DoctorResult -Status unknown -Component $component `
                -Detail 'no offline artifact source is configured, so this machine bootstraps from the default download and offline readiness is not established.' `
                -Remediation $remediate)
    }
    if ($BundleConfigured -and -not $BundleValid) {
        return (New-DoctorResult -Status fail -Component $component `
                -Detail ('POWERSHELL_LSP_ARTIFACT_BUNDLE_DIR is set but unusable -- ' + $BundleReason + '.') `
                -Remediation $remediate)
    }
    if ($MirrorConfigured -and -not $MirrorValid) {
        return (New-DoctorResult -Status fail -Component $component `
                -Detail ('POWERSHELL_LSP_ARTIFACT_MIRROR_BASE is set but unusable -- ' + $MirrorReason + '.') `
                -Remediation $remediate)
    }
    if ($BundleConfigured -and $BundleValid) {
        $missing = @(); $invalid = @(); $ok = @()
        foreach ($a in $BundleArtifacts) {
            if (-not $a.Present) { $missing += $a.Name }
            elseif (-not $a.PinValid) { $invalid += $a.Name }
            else { $ok += $a.Name }
        }
        if ($invalid.Count -gt 0) {
            return (New-DoctorResult -Status fail -Component $component `
                    -Detail ('a staged bundle artifact does NOT match its SHA-256 pin: ' + ($invalid -join ', ') +
                        '. Bootstrap would FAIL CLOSED against it rather than use it, and would not fall through to another source.') `
                    -Remediation 'Re-stage the bundle from the airgap release asset for the version you are running; a pin mismatch means the staged bytes are stale or tampered.')
        }
        if ($missing.Count -gt 0) {
            return (New-DoctorResult -Status fail -Component $component `
                    -Detail ('the configured bundle directory is missing: ' + ($missing -join ', ') + '.') `
                    -Remediation 'Unpack the powershell-lsp-airgap-<version>.zip release asset into the bundle directory so it holds every pinned artifact.')
        }
        return (New-DoctorResult -Status pass -Component $component `
                -Detail ('the configured bundle holds every pinned artifact and each matches its SHA-256 pin (' + ($ok -join ', ') +
                    '); this machine can bootstrap with no network access.'))
    }
    return (New-DoctorResult -Status unknown -Component $component `
            -Detail 'a mirror is configured and well-formed, but offline readiness cannot be PROVEN here: verifying a mirror means hashing artifacts against the pins, which would require downloading them. Bootstrap still verifies every byte it fetches.' `
            -Remediation 'To make offline readiness locally verifiable, also stage a bundle with POWERSHELL_LSP_ARTIFACT_BUNDLE_DIR.')
}

function Test-DoctorHosts {
    # Check 5: the first-run download hosts are reachable. $HostProbes is an array of
    # [pscustomobject]@{ Host=<name>; Reachable=$true|$false|$null }; $null means the probe
    # could not run (UNKNOWN for that host). Any definitely-unreachable host -> fail; else
    # any unknown -> unknown; else pass. Reachability is a preflight convenience, not a
    # guarantee the download will succeed.
    param([object[]] $HostProbes)
    $component = 'First-run download hosts reachable'
    $names = (@($HostProbes) | ForEach-Object { $_.Host }) -join ', '
    $unreachable = @($HostProbes | Where-Object { $_.Reachable -eq $false })
    $unknown = @($HostProbes | Where-Object { $null -eq $_.Reachable })
    if ($unreachable.Count -gt 0) {
        $bad = (@($unreachable) | ForEach-Object { $_.Host }) -join ', '
        return (New-DoctorResult -Status fail -Component $component `
                -Detail ('could not reach ' + $bad + ' on TCP 443; the first-run dependency download would fail.') `
                -Remediation 'PSES and PSScriptAnalyzer are downloaded on first run; ensure these hosts are reachable (check network / proxy / firewall).')
    }
    if ($unknown.Count -gt 0) {
        return (New-DoctorResult -Status unknown -Component $component `
                -Detail ('reachability of ' + $names + ' could not be determined (the probe did not complete).') `
                -Remediation 'Re-run when a network probe is possible, or verify manually that the hosts are reachable.')
    }
    return (New-DoctorResult -Status pass -Component $component `
            -Detail ('reachable on TCP 443: ' + $names + '.'))
}

function Test-DoctorDaemon {
    # Check 6 (dispatch 000037): the warm per-session PSES daemon's RUNTIME health -- is it
    # alive and answering on its named pipe right now? This closes the "installed vs actually
    # working" gap checks 1-5 cannot see: all five can pass while the language server is dead
    # or wedged. REPORT-ONLY -- the probe observes; it never launches, relaunches, repairs, or
    # kills the daemon.
    #
    # The status mapping is HONEST about the 000028 pipe-first + 000030 auto-relaunch semantics
    # (grounded in the 000030 outbox: the recoverable/permanent split is structural at the pipe
    # -- a $null/absent daemon auto-relaunches on the next edit (benign); a daemon parked
    # 'unavailable' is genuinely degraded):
    #   answering its pipe                         -> PASS
    #   alive but parked 'unavailable'/'degraded'  -> FAIL + remediation (the genuine problem)
    #   alive but NOT answering its pipe (wedged)  -> FAIL + remediation
    #   NO daemon present (would auto-relaunch)    -> PASS, benign, says exactly that (never a scary FAIL)
    #   indeterminate from outside the session     -> UNKNOWN
    #
    # Inputs are already-resolved observations (Get-DoctorDaemonObservation does the I/O), so
    # the decision is unit-tested without a live daemon or pipe:
    #   $DataRootKnown : CLAUDE_PLUGIN_DATA is set, so the session dir can be located.
    #   $Determinable  : a single in-scope daemon could be identified ($false = ambiguous --
    #                    several live daemons and no session id to pick THIS session's).
    #   $DaemonPresent : a live daemon (recorded pid alive) is in scope.
    #   $State         : that daemon's recorded session-file state (ready/starting/unavailable/degraded).
    #   $Reachable     : the ping round-trip answered ($true) / did not ($false) / not attempted ($null).
    #   $LiveCount     : how many live daemons were found (for the ambiguous message).
    param(
        [bool] $DataRootKnown,
        [bool] $Determinable,
        [bool] $DaemonPresent,
        [string] $State = '',
        $Reachable = $null,
        [int] $LiveCount = 0
    )
    $component = 'Warm PSES daemon (runtime)'
    $restart = 'Start a fresh Claude Code session to replace the daemon; see logs/pses-daemon.log (README: Diagnostics status).'

    if (-not $DataRootKnown) {
        return (New-DoctorResult -Status unknown -Component $component `
                -Detail 'cannot locate the plugin data directory (CLAUDE_PLUGIN_DATA is not set), so the warm daemon cannot be discovered from outside a session.' `
                -Remediation ('CLAUDE_PLUGIN_DATA is unset in THIS shell. Claude Code ' +
                    'exports it to the plugin''s own hooks -- NOT to tool shells or a ' +
                    'directly-invoked script -- so merely being inside a session does not ' +
                    'set it, and re-running here will not either. Set it to the plugin data ' +
                    'directory (the one holding session/ and logs/) and re-run, or run ' +
                    '/powershell-lsp:doctor so the check runs as the plugin.'))
    }
    if (-not $Determinable) {
        return (New-DoctorResult -Status unknown -Component $component `
                -Detail ('found ' + $LiveCount + ' live daemons but no session id, so which one serves THIS session cannot be determined from outside it.') `
                -Remediation ('Re-run with -SessionId <session-id> to scope the check. ' +
                    'The ids are the file names under the session/ directory of the plugin ' +
                    'data directory: each live daemon writes <session-id>.json there, ' +
                    'carrying its pid, pipe, state and heartbeat -- match on those to pick ' +
                    'the right one. Do NOT expect CLAUDE_SESSION_ID to be set: Claude Code ' +
                    'passes the session id only on hook stdin, never to a directly-invoked ' +
                    'doctor.'))
    }
    if (-not $DaemonPresent) {
        # The benign 000030 case: a $null/absent daemon auto-relaunches on the next edit, so
        # reporting it as a FAIL would lie about a self-healing state. PASS that says so.
        return (New-DoctorResult -Status pass -Component $component `
                -Detail 'no warm daemon is running for this session right now; this is benign -- one auto-relaunches on your next PowerShell edit (dispatch 000030). Nothing to fix.')
    }
    if ($State -eq 'unavailable') {
        return (New-DoctorResult -Status fail -Component $component `
                -Detail 'a daemon is alive but parked "unavailable" -- PowerShell editor services could not start for this session, so edits are NOT being linted (diagnostics stay OFF until it is fixed and the session is restarted).' `
                -Remediation 'Fix the install/startup, then start a fresh Claude Code session; see logs/pses-daemon.log and logs/ensure-pses.log (README: Diagnostics status, "unavailable").')
    }
    if ($State -eq 'degraded') {
        return (New-DoctorResult -Status fail -Component $component `
                -Detail 'a daemon is alive but "degraded" -- its PSES child died and the supervised re-spawn budget is exhausted, so edits return parser-only / incomplete results.' `
                -Remediation 'Start a fresh Claude Code session to get a healthy analyzer; see logs/pses-daemon.log (README: Diagnostics status, "degraded").')
    }
    if ($Reachable -eq $true) {
        $note = if ($State -eq 'starting') { ' (PSES is still initializing; the first edit may read "incomplete" until it is ready).' } else { '.' }
        return (New-DoctorResult -Status pass -Component $component `
                -Detail ('the warm per-session daemon is alive and answered on its named pipe (round-trip ok)' + $note))
    }
    # Live pid but the pipe did not answer within the cap. Pipe-first means a healthy daemon
    # ALWAYS holds its pipe open (dispatch 000028), so an alive-but-silent pipe is a real fault
    # (wedged), distinct from the benign no-daemon case above.
    return (New-DoctorResult -Status fail -Component $component `
            -Detail 'the daemon process is alive but did not answer on its named pipe within the timeout (it may be wedged), so edits would not be checked.' `
            -Remediation $restart)
}

function Test-DoctorNativeServe {
    # Check 7 (dispatch 000104, the 000103 OQ4): is the nativeServe shim removable yet? The shim
    # exists ONLY to route around the upstream #1359-class client init-handshake bug. This decision
    # maps the removability observation (resolved by Get-DoctorNativeServeObservation, which drives
    # the DIRECT launcher via a pwsh subprocess) to a status. REPORT-ONLY and NEVER 'fail' -- it is a
    # removability diagnostic, not a health gate, so it must not move the doctor's exit code:
    #   not determinable (no data dir / PSES not bootstrapped / no pwsh)  -> UNKNOWN + how to enable it
    #   init result not received within the bound                        -> UNKNOWN (PSES did not init)
    #   init received, nav NOT advertised statically (today)             -> PASS  "still gated" (expected)
    #   init received, nav advertised STATICALLY                         -> PASS  "removable"
    #
    #   $Determinable : the probe could run (data root known + PSES bootstrapped + pwsh available).
    #   $Reason       : when not determinable, the honest why (for the UNKNOWN detail).
    #   $InitReceived : the direct launcher returned an initialize result within $TimeoutMs.
    #   $HasStaticNav : that init result advertised hover/definition/references providers STATICALLY.
    #   $ProbeError   : any error string the probe subprocess reported.
    #   $ElapsedMs    : how long the init result took (for the served/gated detail).
    #   $TimeoutMs    : the init-result wait bound (for the not-received message).
    param(
        [bool] $Determinable,
        [string] $Reason = '',
        [bool] $InitReceived = $false,
        [bool] $HasStaticNav = $false,
        [string] $ProbeError = '',
        [int] $ElapsedMs = 0,
        [int] $TimeoutMs = 0
    )
    $component = 'Native-serve removability (opt-in probe)'
    if (-not $Determinable) {
        $why = if ([string]::IsNullOrWhiteSpace($Reason)) { 'the removability probe could not run in this context.' } else { $Reason }
        return (New-DoctorResult -Status unknown -Component $component `
                -Detail ('not probed -- ' + $why) `
                -Remediation 'Run "pwsh -File scripts/doctor.ps1 -ProbeNativeServe" from inside a Claude Code session (where the PSES bundle is bootstrapped) for a definitive removability check.')
    }
    if (-not $InitReceived) {
        $extra = if ([string]::IsNullOrWhiteSpace($ProbeError)) { '' } else { ' (' + $ProbeError + ')' }
        return (New-DoctorResult -Status unknown -Component $component `
                -Detail ('the direct launcher (pses-stdio.ps1) did not return an initialize result within ' + [int]([math]::Round($TimeoutMs / 1000)) + ' s' + $extra + ', so removability is indeterminate -- PSES may have failed to start.') `
                -Remediation 'Confirm the PSES bundle is healthy (see the PSES bundle check and logs/pses-lsp.log), then re-run with -ProbeNativeServe.')
    }
    if ($HasStaticNav) {
        return (New-DoctorResult -Status pass -Component $component `
                -Detail ('native serve now completes STATICALLY -- under a Claude-Code-shaped client the direct launcher advertised the nav providers in its initialize result (in ' + $ElapsedMs + ' ms), so the #1359 handshake gate is gone and the nativeServe shim can be REMOVED (point the lspServers command back at pses-stdio.ps1, or leave nativeServe=off; see docs/upstream/claude-code-lsp-registration.md). Confirm with the manual real claude -p re-probe before removing.'))
    }
    return (New-DoctorResult -Status pass -Component $component `
            -Detail ('native serve is still GATED -- under a Claude-Code-shaped client the direct launcher deferred the nav providers to the client/registerCapability handshake (the init result carried no static hover/definition/references; result in ' + $ElapsedMs + ' ms), exactly the request the upstream #1359 client bug mishandles. The nativeServe shim remains needed; this is the expected state today. A purely client-side #1359 fix would not show here -- the manual real claude -p re-probe stays authoritative.'))
}

function Test-DoctorRuleset {
    # Check: which rule surface is ACTIVE right now (dispatch 000166 B9, checklist item 6).
    #
    # The gap this closes: checks 3/4 confirm the analyzer is INSTALLED, and check 6 confirms the
    # daemon is ANSWERING, but nothing told you WHICH RULES it would apply. A user who set
    # ruleset=base and still never sees PSAvoidUsingWriteHost had no way to learn that a repo-local
    # PSScriptAnalyzerSettings.psd1 was quietly winning -- which is the documented precedence, not
    # a bug, but silently.
    #
    # REPORT-ONLY and NEVER 'fail'. This is a "what is active" report, not a health gate; a
    # deliberate configuration must not move the doctor's exit code.
    #
    #   not determinable (the shipped resolver could not be consulted)      -> UNKNOWN
    #   ruleset=base requested but the shipped base ruleset is UNRESOLVABLE -> UNKNOWN (honest:
    #     the request degrades to PSES defaults at analysis time, and a PASS reading "PSES
    #     built-in set" would be indistinguishable from a user who chose pses-default)
    #   otherwise                                                           -> PASS, naming the
    #     effective knob value, the resolved settings file (or the PSES built-in set), and WHICH
    #     layer won.
    #
    #   $Determinable  : the shipped resolver ran.
    #   $Reason        : when not determinable, the honest why.
    #   $RulesetKnob   : the effective `ruleset` value (profile-resolved, so a profile shows here).
    #   $ResolvedPath  : what Resolve-PssaSettingsPath returned ('' = PSES's own no-settings set).
    #   $Source        : which layer won -- 'override' | 'repo-local' | 'plugin-base' | 'pses-default'.
    #   $ProbeDir      : the directory the repo-local walk-up was rooted at (named in the detail,
    #                    because "which rules apply" is a per-location answer).
    param(
        [bool] $Determinable,
        [string] $Reason = '',
        [string] $RulesetKnob = '',
        [string] $ResolvedPath = '',
        [string] $Source = '',
        [string] $ProbeDir = ''
    )
    $component = 'Active ruleset surface'
    if (-not $Determinable) {
        $why = if ([string]::IsNullOrWhiteSpace($Reason)) { 'the shipped settings resolver could not be consulted in this context.' } else { $Reason }
        return (New-DoctorResult -Status unknown -Component $component `
                -Detail ('not determined -- ' + $why) `
                -Remediation 'Run the doctor from inside an enabled Claude Code session so the plugin root and knob values resolve.')
    }
    $where = if ([string]::IsNullOrWhiteSpace($ProbeDir)) { 'this directory' } else { $ProbeDir }
    if ($Source -eq 'unresolved-base') {
        return (New-DoctorResult -Status unknown -Component $component `
                -Detail ('ruleset = "base" is requested, but the shipped base ruleset (rulesets/base.psd1) could not be located, so live analysis will fall back to PSES built-in rules -- a NARROWER surface than you configured.') `
                -Remediation 'Confirm the plugin tree is intact (rulesets/base.psd1 ships with the plugin) and that CLAUDE_PLUGIN_ROOT points at it; see docs/configuration.md#ruleset.')
    }
    if ($Source -eq 'override') {
        return (New-DoctorResult -Status pass -Component $component `
                -Detail ('an explicit settingsPath override is active: ' + $ResolvedPath + ' -- it wins over both the repo-local file and the ruleset knob (ruleset = "' + $RulesetKnob + '" is inert while it is set).'))
    }
    if ($Source -eq 'repo-local') {
        return (New-DoctorResult -Status pass -Component $component `
                -Detail ('a repo-local PSScriptAnalyzerSettings.psd1 is active for ' + $where + ': ' + $ResolvedPath + ' -- it wins over the ruleset knob (ruleset = "' + $RulesetKnob + '" is inert here). This is the documented precedence, not a fault.'))
    }
    if ($Source -eq 'plugin-base') {
        return (New-DoctorResult -Status pass -Component $component `
                -Detail ('ruleset = "' + $RulesetKnob + '" -- the shipped base ruleset is active for ' + $where + ': ' + $ResolvedPath + ' (PSScriptAnalyzer default-on rules minus the compatibility profiles; broader than the PSES built-in set). No repo-local settings file or override was found above ' + $where + '.'))
    }
    return (New-DoctorResult -Status pass -Component $component `
            -Detail ('ruleset = "' + $RulesetKnob + '" -- PowerShell Editor Services'' own built-in no-settings rule set is active for ' + $where + ' (about 15 rules; narrower than the PSScriptAnalyzer CLI default -- PSAvoidUsingWriteHost is NOT among them). Set ruleset = "base", or add a repo-local PSScriptAnalyzerSettings.psd1, to broaden it; see docs/configuration.md#ruleset.'))
}

function Test-DoctorOrgPolicy {
    # Check: is the `orgPolicy` exclusion layer applying, and if not, WHY (dispatch 000203
    # survey candidate C2, failure class F12)?
    #
    # The gap this closes: check 7 above models the SETTINGS-RESOLVER chain -- override,
    # repo-local, plugin-base, pses-default. `orgPolicy` is applied at a different seam
    # entirely (lsp-client.ps1:81), AFTER analysis, by dropping org-excluded rule codes from
    # what the user is shown. Its three degrade reasons -- a relative path, a missing file,
    # an unparseable file -- are routed to Write-CLog, the client log. Not to the user's turn,
    # and, until this check, not to any doctor check either. So an org whose exclusions have
    # silently stopped applying looked exactly like an org whose exclusions were applying.
    #
    # REPORT-ONLY and NEVER 'fail'. Fail-open is the DESIGNED behavior (dispatch 000135,
    # decision 1): an org policy that cannot be read must never break the user's edit. The
    # defect this surfaces is that the degrade is INVISIBLE, not that it happens -- so moving
    # the doctor's exit code would be reporting a correct behavior as a fault.
    #
    #   knob values not resolvable (outside a session)  -> UNKNOWN
    #   `orgPolicy` not set                             -> PASS (the default; no org layer)
    #   set and read, N >= 0 exclusions declared        -> PASS, naming the path and the count
    #   set but DEGRADED                                -> UNKNOWN, quoting the exact reason
    #
    # UNKNOWN (not PASS) for a degrade mirrors check 7's `unresolved-base` case, which is the
    # same shape: a layer was ASKED for and silently did not apply. A PASS there would be
    # indistinguishable from an org that genuinely declares no exclusions, which is the one
    # confusion this check exists to remove.
    #
    #   $Determinable   : the knob values resolved.
    #   $Reason         : when not determinable, the honest why.
    #   $KnobSet        : `orgPolicy` carries a non-blank value.
    #   $PolicyPath     : the knob value as the client passes it to Import-OrgPolicyExcludes.
    #   $ExcludeCount   : how many rule codes the shipped reader lifted out of it.
    #   $DegradeReason  : the reader's own warning text, verbatim, or '' when it did not degrade.
    param(
        [bool] $Determinable,
        [string] $Reason = '',
        [bool] $KnobSet = $false,
        [string] $PolicyPath = '',
        [int] $ExcludeCount = 0,
        [string] $DegradeReason = ''
    )
    $component = 'Org policy exclusions'
    if (-not $Determinable) {
        $why = if ([string]::IsNullOrWhiteSpace($Reason)) {
            'the plugin knob values could not be resolved in this context.'
        } else { $Reason }
        return (New-DoctorResult -Status unknown -Component $component `
                -Detail ('not determined -- ' + $why) `
                -Remediation ('Run the doctor from inside an enabled Claude Code session so the ' +
                    'knob values resolve.'))
    }
    if (-not $KnobSet) {
        return (New-DoctorResult -Status pass -Component $component `
                -Detail ('orgPolicy is not set -- no org-wide rule exclusions are applied, and ' +
                    'every rule the active ruleset surface enables is shown. This is the ' +
                    'default; the knob is an enterprise opt-in.'))
    }
    if (-not [string]::IsNullOrWhiteSpace($DegradeReason)) {
        return (New-DoctorResult -Status unknown -Component $component `
                -Detail ('orgPolicy is SET but its exclusions are NOT being applied -- the ' +
                    'shipped reader degraded, fail-open, with: "' + $DegradeReason + '". ' +
                    'Diagnostics are never blocked by this (that is the designed behavior), ' +
                    'but rules your organization excluded are being shown as if there were ' +
                    'no policy.') `
                -Remediation ('Point orgPolicy at an ABSOLUTE path to a readable .psd1 that ' +
                    'declares an ExcludeRules array; see docs/configuration.md#orgpolicy.'))
    }
    if ($ExcludeCount -eq 0) {
        return (New-DoctorResult -Status pass -Component $component `
                -Detail ('orgPolicy = ' + $PolicyPath + ' -- read successfully, and it declares ' +
                    'NO excluded rules. This is a valid no-op policy, not a degrade: nothing is ' +
                    'being filtered out of your diagnostics.'))
    }
    $plural = if ($ExcludeCount -eq 1) { 'rule' } else { 'rules' }
    return (New-DoctorResult -Status pass -Component $component `
            -Detail ('orgPolicy = ' + $PolicyPath + ' -- read successfully, enforcing ' +
                $ExcludeCount + ' excluded ' + $plural + '. Those rule codes are dropped from ' +
                'what you are shown, on top of whatever the active ruleset surface enables.'))
}

function Test-DoctorTestDiagnostic {
    # Check: is a REAL diagnostic observed end-to-end (dispatch 000166 B9, checklist item 8)?
    #
    # The gap this closes: every other check is a proxy. The daemon check's 'ping' handler answers
    # WITHOUT touching its PSES child (no didOpen, no analysis), so a daemon can be alive, pinging,
    # and still analyzing nothing. This is the only check that asserts the actual product works: a
    # synthetic file with a known defect goes in, and the expected rule id comes back.
    #
    # OQ5 CONSTRAINTS, honored: the probe analyzes a file in the TEMP directory (never the repo, and
    # never a file the user owns), it asks the ALREADY-RUNNING warm daemon over the same one-line
    # JSON pipe protocol lsp-client.ps1 uses -- it NEVER starts, restarts, or leaves behind a daemon
    # -- and it can only report, never repair. With no daemon reachable the answer is UNKNOWN.
    #
    # NEVER 'fail'... with ONE exception, which is the point of the check: the daemon ANSWERED and
    # the analysis SETTLED, yet the planted defect did not come back. That is the silent-failure
    # mode the whole plugin exists to avoid -- a user believing "no findings" means "clean" when it
    # means "not actually analyzed" -- so it is the one condition worth failing on. Every
    # could-not-determine path stays UNKNOWN, preserving unknown-is-never-fail.
    #
    #   $Determinable  : the probe ran (temp file written + a reachable daemon to ask).
    #   $Reason        : when not determinable, the honest why.
    #   $Responded     : the daemon returned a well-formed diagnostics response.
    #   $Status        : the response's analysis status ('' / ok / incomplete / degraded / unavailable).
    #   $ExpectedRule  : the rule id the planted defect must produce.
    #   $RuleIds       : the rule ids actually returned.
    #   $ElapsedMs     : the round-trip.
    param(
        [bool] $Determinable,
        [string] $Reason = '',
        [bool] $Responded = $false,
        [string] $Status = '',
        [string] $ExpectedRule = '',
        [string[]] $RuleIds = @(),
        [int] $ElapsedMs = 0
    )
    $component = 'Test diagnostic observed end-to-end'
    if (-not $Determinable) {
        $why = if ([string]::IsNullOrWhiteSpace($Reason)) { 'the end-to-end probe could not run in this context.' } else { $Reason }
        return (New-DoctorResult -Status unknown -Component $component `
                -Detail ('not observed -- ' + $why) `
                -Remediation 'Run the doctor from inside an enabled Claude Code session with a warm daemon running (edit any PowerShell file first), for a definitive end-to-end result.')
    }
    if (-not $Responded) {
        return (New-DoctorResult -Status unknown -Component $component `
                -Detail 'the warm daemon did not return a well-formed diagnostics response for the synthetic probe file, so end-to-end analysis is indeterminate.' `
                -Remediation 'Check the daemon health check above and logs/pses-daemon.log, then re-run.')
    }
    # A non-ok status is the daemon telling us it did not finish analyzing -- exactly the honest
    # banner a real edit would get. That is a working plugin reporting a transient condition, not
    # a broken one, so it is UNKNOWN and the status is quoted rather than paraphrased.
    if (-not [string]::IsNullOrWhiteSpace($Status) -and $Status -ne 'ok') {
        return (New-DoctorResult -Status unknown -Component $component `
                -Detail ('the analysis did not settle for the probe file -- the daemon reported status "' + $Status + '", which is the same honest banner a real edit would receive. End-to-end correctness is indeterminate until it settles.') `
                -Remediation 'This is usually transient (PSES still starting). Re-run the doctor in a few seconds; if it persists, see the Diagnostics status section of the README.')
    }
    if (@($RuleIds) -contains $ExpectedRule) {
        return (New-DoctorResult -Status pass -Component $component `
                -Detail ('a real diagnostic was observed end-to-end in ' + $ElapsedMs + ' ms: a synthetic temp file with a deliberate defect returned ' + $ExpectedRule + ', through the same warm daemon and pipe your edits use. Diagnostics are genuinely working, not merely installed.'))
    }
    $got = if (@($RuleIds).Count -eq 0) { 'no findings at all' } else { 'only: ' + ((@($RuleIds) | Sort-Object -Unique) -join ', ') }
    return (New-DoctorResult -Status fail -Component $component `
            -Detail ('the daemon answered and reported a SETTLED analysis, but the synthetic probe file''s deliberate defect did not come back -- expected ' + $ExpectedRule + ', got ' + $got + '. A settled-but-empty result is the dangerous case: an edit would read as "analyzed, clean" when the analyzer is not actually producing findings.') `
            -Remediation 'Check that PSScriptAnalyzer is vendored and importable (the check above), inspect logs/pses-daemon.log for analyzer errors, then start a fresh session so the bootstrap re-vendors.')
}

function Test-DoctorNativeServeStatus {
    # Check: what is the native-serve tier's configured state (dispatch 000166 B9, item-7 promotion)?
    #
    # Split out of the opt-in removability PROBE (check 'Native-serve removability') so the routine
    # doctor answers the question a user actually has -- "is native navigation on for me, and if not
    # why" -- without paying a PSES cold-start. This check spawns NOTHING: it reads the effective
    # knob value and the shipped gate state. The heavier removability probe stays opt-in behind
    # -ProbeNativeServe and is unchanged.
    #
    # REPORT-ONLY and NEVER 'fail' -- nativeServe is off by default and that is a correct,
    # supported configuration, not a fault.
    #
    #   $Determinable : the effective knob value could be read.
    #   $Reason       : when not determinable, the honest why.
    #   $Value        : the effective nativeServe value ('off' | 'shim' | something else).
    #   $ShimPresent  : the shim script ships in this tree (the mechanism exists).
    #   $Probed       : whether the opt-in removability probe also ran this invocation.
    param(
        [bool] $Determinable,
        [string] $Reason = '',
        [string] $Value = '',
        [bool] $ShimPresent = $false,
        [bool] $Probed = $false
    )
    $component = 'Native-serve status (hover / definition / references)'
    if (-not $Determinable) {
        $why = if ([string]::IsNullOrWhiteSpace($Reason)) { 'the nativeServe value could not be read in this context.' } else { $Reason }
        return (New-DoctorResult -Status unknown -Component $component `
                -Detail ('not determined -- ' + $why) `
                -Remediation 'Run the doctor from inside an enabled Claude Code session so the configured knob values resolve.')
    }
    $probeHint = if ($Probed) { '' } else { ' Run with -ProbeNativeServe to also test whether the upstream handshake gate has lifted.' }
    if ($Value -eq 'shim') {
        if (-not $ShimPresent) {
            return (New-DoctorResult -Status unknown -Component $component `
                    -Detail 'nativeServe = "shim" is configured, but the shim script (scripts/pses-serve-shim.ps1) was not found in the plugin tree, so the navigation tier''s state is indeterminate.' `
                    -Remediation 'Confirm the plugin tree is intact and CLAUDE_PLUGIN_ROOT points at it.')
        }
        return (New-DoctorResult -Status pass -Component $component `
                -Detail ('nativeServe = "shim" -- hover, go-to-definition, find-references, and documentSymbol are ENABLED through the handshake shim. Diagnostics are unaffected by this knob either way.' + $probeHint))
    }
    if ($Value -eq 'off' -or [string]::IsNullOrWhiteSpace($Value)) {
        return (New-DoctorResult -Status pass -Component $component `
                -Detail ('nativeServe = "off" (the default) -- native hover / go-to-definition / find-references do NOT serve; the proxy is a byte-exact pass-through and the navigation tier stays gated on the upstream client init-handshake bug. This is the shipped default, not a fault: the PostToolUse diagnostics hook is independent of this knob and works regardless. Set nativeServe = "shim" to enable navigation (docs/configuration.md#nativeserve).' + $probeHint))
    }
    return (New-DoctorResult -Status unknown -Component $component `
            -Detail ('nativeServe is set to "' + $Value + '", which is not a recognized value -- the plugin treats anything other than "shim" as "off", so navigation is not serving.') `
            -Remediation 'Set nativeServe to "off" (default) or "shim"; see docs/configuration.md#nativeserve.')
}

function Test-DoctorServeTransport {
    # Check: does a knob the LSP SERVE SUBPROCESS reads actually REACH it (dispatch 000233)?
    #
    # THE QUESTION THIS EXISTS TO ANSWER. Every other knob check in this file reports the value
    # the DOCTOR can see -- and the doctor is a hook-adjacent process, which Claude Code does
    # export CLAUDE_PLUGIN_OPTION_* to. The LSP serve subprocess is not: it receives only what
    # the manifest's own `lspServers.<server>.env` block declares. So for the whole life of the
    # `nativeServe` knob the doctor could truthfully report `nativeServe = "shim"` while the
    # process that acts on it resolved `off`, and no surface anywhere showed the difference.
    # This check reports CONFIGURED against EFFECTIVE-IN-SERVE, so that divergence is visible
    # rather than silent.
    #
    # FAIL-CAPABLE in exactly one state, report-only otherwise. A knob the user has SET that has
    # no transport into the subprocess is a real fault: the user asked for something the running
    # system will silently not do, which is the entire defect class this check exists to end.
    # That is the same reasoning check 11 (ps_host) records for being fail-capable -- a shipped
    # fallback makes a bad value invisible rather than loud. An UNSET knob with no mapping is not
    # a fault, and a recognized-value divergence is reported UNKNOWN rather than failed, because
    # degrading an unrecognized value to the documented default is deliberate behaviour.
    # (The status set here is pass / fail / unknown -- New-DoctorResult has no 'warn'.)
    #
    #   $Determinable : the manifest and the knob values could both be read.
    #   $Reason       : when not determinable, the honest why.
    #   $Rows         : one hashtable per knob -- Key, Configured, Mapped (bool), Effective.
    param(
        [bool] $Determinable,
        [string] $Reason = '',
        [object[]] $Rows = @()
    )
    $component = 'Serve-subprocess config transport (configured vs effective)'
    if (-not $Determinable) {
        $why = if ([string]::IsNullOrWhiteSpace($Reason)) { 'the manifest or the knob values could not be read in this context.' } else { $Reason }
        return (New-DoctorResult -Status unknown -Component $component `
                -Detail ('not determined -- ' + $why) `
                -Remediation 'Run the doctor from inside an enabled Claude Code session, with CLAUDE_PLUGIN_ROOT pointing at the plugin tree.')
    }
    $rows = @($Rows)
    if ($rows.Count -eq 0) {
        return (New-DoctorResult -Status unknown -Component $component `
                -Detail 'no serve-subprocess knobs were enumerated, so nothing could be compared.' `
                -Remediation 'Confirm the plugin tree is intact (scripts/pses-serve-shim.ps1 and .claude-plugin/plugin.json).')
    }
    $lines = @($rows | ForEach-Object {
            $cfg = if ([string]::IsNullOrWhiteSpace([string]$_.Configured)) { '(unset)' } else { [string]$_.Configured }
            $tag = if ($_.Mapped) { '' } elseif ($_.Suspended) { ' [SUSPENDED BY UPSTREAM GATE]' } else { ' [NO TRANSPORT]' }
            ('' + $_.Key + ': configured=' + $cfg + ' effective=' + [string]$_.Effective + $tag)
        })
    $detail = ($lines -join '; ')

    # THE FORK, AND WHY IT HAS THREE BRANCHES AND NOT TWO (dispatch 000241).
    #
    # Before the upstream gate there were two states worth naming: a knob with a transport, and a
    # knob the user SET that had none -- the second being a real fault, because the user asked for
    # something the running system silently would not do. The gate introduces a third: a knob
    # whose mapping was REMOVED ON PURPOSE, because on Claude Code 2.1.233 one unset referenced
    # key makes the host discard every LSP server this plugin declares.
    #
    # Reporting a suspended knob as FAIL would cry wolf on every install that configures one, and
    # would name a remediation the user cannot perform. Reporting it as PASS would be the silent
    # divergence dispatch 000233 was raised to kill. So it is neither: it is STATED, with the
    # upstream condition that lifts it, and the fail-capable branch stays armed for the case it
    # was built for -- a knob that is unmapped for any reason OTHER than the recorded suspension.
    $brokenUnsuspended = @($rows | Where-Object {
            -not $_.Mapped -and -not $_.Suspended -and -not [string]::IsNullOrWhiteSpace([string]$_.Configured)
        })
    if ($brokenUnsuspended.Count -gt 0) {
        $names = (@($brokenUnsuspended | ForEach-Object { [string]$_.Key }) -join ', ')
        return (New-DoctorResult -Status fail -Component $component `
                -Detail ('CONFIGURED BUT NOT DELIVERED -- ' + $names + ' is set, but .claude-plugin/plugin.json declares no ${user_config.*} mapping for it in lspServers.powershell.env, and it is not on the recorded upstream-gate suspension list either, so the serve subprocess will use the shipped default instead. ' + $detail) `
                -Remediation ('Add "CLAUDE_PLUGIN_OPTION_<KEY>": "${user_config.<key>}" to lspServers.powershell.env in .claude-plugin/plugin.json for: ' + $names + '. The environment variables Claude Code exports to hooks do NOT reach LSP server subprocesses; the server env block is the supported transport.'))
    }

    # A knob the user SET whose transport is suspended: not a fault, but never silent.
    $suspendedConfigured = @($rows | Where-Object { $_.Suspended -and -not [string]::IsNullOrWhiteSpace([string]$_.Configured) })
    if ($suspendedConfigured.Count -gt 0) {
        $names = (@($suspendedConfigured | ForEach-Object { [string]$_.Key }) -join ', ')
        $rec = @(Get-ServeTransportSuspension)[0]
        return (New-DoctorResult -Status unknown -Component $component `
                -Detail ('SUSPENDED BY UPSTREAM GATE -- you have configured ' + $names + ', and that value is NOT in effect inside the LSP serve subprocess. This is a Claude Code ' + [string]$rec.AffectedVersion + ' defect (' + [string]$rec.Gate + '), not a fault in your configuration: the ${user_config.*} transport dispatch 000233 established is correct and proven, but on this Claude Code one unset referenced key makes the host discard EVERY LSP server this plugin declares, so the mappings are temporarily removed. Diagnostics are unaffected -- they run through the hooks. What is not in effect is the serve subprocess reading these knobs; nativeServe=shim in particular cannot take effect while this holds. ' + $detail) `
                -Remediation ('No action is available in the plugin. The gate lifts when: ' + [string]$rec.LiftsWhen + ' Tracking and the upstream report: ' + [string]$rec.Reference))
    }
    $divergent = @($rows | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Configured) -and ([string]$_.Configured -ne [string]$_.Effective) })
    if ($divergent.Count -gt 0) {
        return (New-DoctorResult -Status unknown -Component $component `
                -Detail ('configured and effective DIVERGE for: ' + (@($divergent | ForEach-Object { [string]$_.Key }) -join ', ') + '. ' + $detail) `
                -Remediation 'Check the value is one this build recognizes (see docs/configuration.md); an unrecognized value degrades to the documented default rather than failing loudly.')
    }
    # PASS, but the claim must match what is actually true. With knobs suspended, "every knob has
    # a transport" is false even when nothing is configured -- so say what holds instead: nothing
    # the user set is being quietly dropped, and the suspension is still named so it stays
    # discoverable rather than only appearing once someone trips over it.
    $suspendedAny = @($rows | Where-Object { $_.Suspended })
    if ($suspendedAny.Count -gt 0) {
        $names = (@($suspendedAny | ForEach-Object { [string]$_.Key }) -join ', ')
        $rec = @(Get-ServeTransportSuspension)[0]
        return (New-DoctorResult -Status pass -Component $component `
                -Detail ('nothing you configured is being silently dropped. Transport for ' + $names + ' is SUSPENDED BY UPSTREAM GATE (' + [string]$rec.Gate + ', Claude Code ' + [string]$rec.AffectedVersion + '), and none of those knobs is currently set, so the shipped defaults in effect are also the documented ones. ' + $detail))
    }
    return (New-DoctorResult -Status pass -Component $component `
            -Detail ('every knob the serve subprocess reads has a transport into it, and configured matches effective. ' + $detail))
}

# ===========================================================================
# Live probes -- the environment-dependent half. Kept OUT of the pure functions so
# the decision logic stays unit-testable; these are exercised by the end-to-end run.
# ===========================================================================

function Get-DoctorPwsh {
    # Resolve pwsh on PATH and its version WITHOUT launching a child process (read the
    # ApplicationInfo.Version -- the exe file version, which for pwsh is the PS version).
    try {
        $cmd = Get-Command 'pwsh' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $cmd) { return [pscustomobject]@{ Found = $false; Version = $null } }
        $v = $null
        try { if ($cmd.Version -is [version]) { $v = $cmd.Version } } catch { $v = $null }
        return [pscustomobject]@{ Found = $true; Version = $v }
    } catch { return [pscustomobject]@{ Found = $false; Version = $null } }
}

function Get-DoctorPluginRootResolved {
    # $true iff CLAUDE_PLUGIN_ROOT is set AND its manifest names THIS plugin.
    try {
        $root = $env:CLAUDE_PLUGIN_ROOT
        if ([string]::IsNullOrWhiteSpace($root)) { return $false }
        $manifest = Join-Path $root '.claude-plugin/plugin.json'
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { return $false }
        $name = [string](((Get-Content -LiteralPath $manifest -Raw) | ConvertFrom-Json).name)
        return ($name -eq 'powershell-lsp')
    } catch { return $false }
}

function Get-DoctorDataRootKnown {
    # $true iff CLAUDE_PLUGIN_DATA is set, so Get-PluginDataRoot returns the REAL data dir
    # rather than its temp fallback (which would make marker checks meaningless).
    #
    # DELEGATES to the shared seam (dispatch 000185, D1-A). This file is where the correct
    # shape was FIRST written, and for a while it was the only place that had it -- which is
    # why six other readers re-invented the wrong version or skipped it. Test-PluginDataRootKnown
    # is this same predicate promoted into lib/lsp-common.ps1; doctor now CONSUMES it rather
    # than keeping a private second copy. Same input, same answer, one implementation.
    return (Test-PluginDataRootKnown)
}

function Get-DoctorPin {
    # Single source of truth for a pinned version: parse a single-quoted pin variable out of
    # a bootstrap script WITHOUT executing it (the ensure-* scripts have side effects).
    # Returns '' if the variable is not found.
    param([string] $ScriptPath, [string] $VarName)
    try {
        if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { return '' }
        $text = Get-Content -LiteralPath $ScriptPath -Raw
        $rx = [regex] ('(?m)^\s*\$' + [regex]::Escape($VarName) + "\s*=\s*'([^']+)'")
        $m = $rx.Match($text)
        if ($m.Success) { return $m.Groups[1].Value }
        return ''
    } catch { return '' }
}

function Get-DoctorHostsFromScript {
    # Single source of truth for the download hosts: extract the distinct hostnames from a
    # bootstrap script's https:// URL literals (never executes the script).
    param([string] $ScriptPath)
    $found = @()
    try {
        if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { return @() }
        $text = Get-Content -LiteralPath $ScriptPath -Raw
        foreach ($m in [regex]::Matches($text, 'https://([A-Za-z0-9.\-]+)')) {
            $h = $m.Groups[1].Value
            if ($found -notcontains $h) { $found += $h }
        }
    } catch { }
    return @($found)
}

function Test-DoctorPssaImportableProbe {
    # Read-only mirror of ensure-pssa.ps1's importability test (we do not edit that script,
    # so the doctor carries its own copy): $true iff a pinned PSScriptAnalyzer.psd1 under
    # $VendorDir imports and exposes Invoke-ScriptAnalyzer.
    param([string] $VendorDir, [string] $PinVersion)
    try {
        if ([string]::IsNullOrWhiteSpace($VendorDir) -or -not (Test-Path -LiteralPath $VendorDir)) { return $false }
        $manifest = Get-ChildItem -LiteralPath $VendorDir -Recurse -Filter 'PSScriptAnalyzer.psd1' -File -ErrorAction SilentlyContinue |
            Sort-Object { $_.FullName.Length } | Select-Object -First 1
        if ($null -eq $manifest) { return $false }
        $data = Import-PowerShellDataFile -LiteralPath $manifest.FullName
        if (-not [string]::IsNullOrWhiteSpace($PinVersion) -and $data.ModuleVersion -ne $PinVersion) { return $false }
        Import-Module $manifest.FullName -Force -ErrorAction Stop
        return ($null -ne (Get-Command Invoke-ScriptAnalyzer -ErrorAction Stop))
    } catch { return $false }
}

function Test-DoctorHostReachableProbe {
    # TCP connect with a short timeout. $true reachable; $false refused/timed-out/DNS-fail;
    # $null if the probe itself could not run. (Uses System.Net.Sockets -- the doctor is not
    # claimed CLM-safe; security/CLM is explicitly out of scope.)
    param([string] $HostName, [int] $Port = 443, [int] $TimeoutMs = 3000)
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        $completed = $iar.AsyncWaitHandle.WaitOne($TimeoutMs)
        if (-not $completed) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch [System.Net.Sockets.SocketException] {
        return $false
    } catch {
        return $null
    } finally {
        if ($null -ne $client) { try { $client.Close() } catch { } }
    }
}

function Test-DoctorDaemonPingProbe {
    # Read-only liveness round-trip over the warm daemon's named pipe, REUSING the daemon's
    # existing 'ping' action and the SAME one-line-JSON pipe protocol the PostToolUse client
    # uses (lsp-client.ps1 Get-Diagnostics) -- NOT a second client or a parallel protocol. The
    # daemon's 'ping' handler returns {ok,pid,psesPid} WITHOUT touching its PSES child (no
    # didOpen/didChange, no analysis, no state change), so the probe is non-disruptive: it
    # cannot wedge the daemon or steal analysis; it connects, asks, disconnects, like any
    # client (a connection only resets the daemon's idle-TTL timer, exactly as a real edit
    # does -- benign). $true iff a ping response with ok=true came back; $false otherwise.
    param([string] $PipeName, [int] $ConnectTimeoutMs = 1500, [int] $ReadTimeoutMs = 1500)
    $attempts = 0
    while ($attempts -lt 2) {
        $attempts++
        $client = $null
        try {
            $client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $PipeName,
                [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
            $client.Connect($ConnectTimeoutMs)
            $writer = New-Object System.IO.StreamWriter($client, (New-Object System.Text.UTF8Encoding($false)), 4096, $true)
            $writer.NewLine = "`n"; $writer.AutoFlush = $true
            $reader = New-Object System.IO.StreamReader($client, [System.Text.Encoding]::UTF8, $false, 4096, $true)
            $writer.WriteLine('{"action":"ping"}')
            $writer.Flush()
            $readTask = $reader.ReadLineAsync()
            if (-not $readTask.Wait($ReadTimeoutMs)) { return $false }
            $line = $readTask.Result
            if ([string]::IsNullOrWhiteSpace($line)) { return $false }
            $resp = $line | ConvertFrom-Json
            return ([bool](Get-Prop $resp 'ok'))
        } catch {
            # Connect timeout / refused / broken pipe -> not reachable on this attempt; retry once.
        } finally {
            if ($null -ne $client) { try { $client.Dispose() } catch { } }
        }
    }
    return $false
}

function Get-DoctorDaemonObservation {
    # Resolve the daemon-health observation that the pure Test-DoctorDaemon decides on, doing
    # ALL the I/O here (kept out of the pure function so the decision stays unit-testable).
    #
    # Discovery uses the daemon's OWN durable handle -- the per-session details json the daemon
    # writes at <data>/session/<sessionid>.json (sessionId/pid/pipe/state/heartbeat) -- and its
    # OWN liveness notion (recorded pid alive), exactly as session-start's reap does; there is
    # no second discovery path. Session id precedence: explicit $SessionId, then
    # $env:CLAUDE_SESSION_ID, then discovery across all session files. Claude Code does not
    # expose the session id to a directly-invoked doctor (it arrives only on hook stdin), so an
    # unscoped run that finds several live daemons is honestly UNKNOWN, not a guess.
    param([string] $SessionId = '')

    if (-not (Get-DoctorDataRootKnown)) {
        return @{ DataRootKnown = $false; Determinable = $false; DaemonPresent = $false; State = ''; Reachable = $null; LiveCount = 0; Pipe = '' }
    }
    $sessionDir = Get-SessionDir
    $sid = $SessionId
    if ([string]::IsNullOrWhiteSpace($sid)) { $sid = [string]$env:CLAUDE_SESSION_ID }
    $scoped = -not [string]::IsNullOrWhiteSpace($sid)

    # Gather candidate handles: the one scoped file, or every session file for discovery.
    $files = @()
    try {
        if ($scoped) {
            $one = Join-Path $sessionDir ($sid + '.json')
            if (Test-Path -LiteralPath $one -PathType Leaf) { $files = @(Get-Item -LiteralPath $one) }
        } else {
            $files = @(Get-ChildItem -LiteralPath $sessionDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
        }
    } catch { $files = @() }

    # A live candidate = a parseable handle whose recorded pid is alive. A dead pid means the
    # daemon is gone (benign-absent); a lingering stale file is NOT a live daemon.
    $live = @()
    foreach ($f in $files) {
        $obj = $null
        try { $obj = (Get-Content -LiteralPath $f.FullName -Raw) | ConvertFrom-Json } catch { $obj = $null }
        if ($null -eq $obj) { continue }
        $recPid = 0; $pv = Get-Prop $obj 'pid'
        if ($null -ne $pv) { try { $recPid = [int]$pv } catch { $recPid = 0 } }
        if ($recPid -le 0) { continue }
        $alive = $false
        try { $alive = ($null -ne (Get-Process -Id $recPid -ErrorAction SilentlyContinue)) } catch { $alive = $false }
        if (-not $alive) { continue }
        $pipe = [string](Get-Prop $obj 'pipe')
        if ([string]::IsNullOrWhiteSpace($pipe)) { $pipe = 'powershell-lsp-' + [string](Get-Prop $obj 'sessionId') }
        # DaemonVersion (DX finding O2): the version the RUNNING daemon stamped into its own
        # record. '' when the record carries no such field -- which is exactly what a daemon
        # older than the field looks like, and is reported as unknown, never as a mismatch.
        $live += [pscustomobject]@{
            Pipe = $pipe
            State = [string](Get-Prop $obj 'state')
            DaemonVersion = [string](Get-Prop $obj 'pluginVersion')
        }
    }

    if ($live.Count -eq 0) {
        # No live daemon in scope -> the benign 000030 absent-but-relaunchable case.
        return @{ DataRootKnown = $true; Determinable = $true; DaemonPresent = $false; State = ''; Reachable = $null; LiveCount = 0; Pipe = ''; DaemonVersion = '' }
    }
    if (-not $scoped -and $live.Count -gt 1) {
        # Several live daemons and no session id to pick THIS session's -> honest UNKNOWN.
        return @{ DataRootKnown = $true; Determinable = $false; DaemonPresent = $true; State = ''; Reachable = $null; LiveCount = $live.Count; Pipe = ''; DaemonVersion = '' }
    }
    $d = $live[0]
    $reachable = Test-DoctorDaemonPingProbe -PipeName $d.Pipe
    # Pipe rides along (dispatch 000166) so the end-to-end check can ask the SAME daemon this
    # check just identified, instead of re-discovering and possibly disagreeing with it. The
    # daemon's own version rides along for the same reason: the reconciliation below must describe
    # the daemon THIS resolution identified, never one re-discovered separately.
    return @{ DataRootKnown = $true; Determinable = $true; DaemonPresent = $true; State = $d.State; Reachable = $reachable; LiveCount = 1; Pipe = $d.Pipe; DaemonVersion = $d.DaemonVersion }
}

function Get-DoctorVersionLine {
    # The doctor / status header's version line, reconciling the TREE against the RUNNING daemon
    # (DX finding O2). PURE: it decides wording from two strings and never touches disk.
    #
    # O2 recorded that the doctor "gets a confidently wrong answer" to the first question of any
    # support thread. Dispatch 000265 closed the honesty half by appending a caveat -- "(this tree;
    # a live daemon may be older -- see logs/pses-daemon.log)" -- which stopped the report being
    # confidently wrong but still did not ANSWER the question: it told the reader the number might
    # be wrong and pointed at a log. This closes the other half.
    #
    # Four cases, and the distinction between the middle two is the whole point:
    #   agree     -> one version, stated plainly.
    #   differ    -> BOTH versions, named, plus why that is expected rather than broken (the old
    #                daemon serves out the session by design -- better than a mid-session restart).
    #   unknown   -> a daemon is live but its record carries no version, i.e. it predates this
    #                field. Say so. An ABSENT version is not evidence of a mismatch.
    #   no daemon -> nothing to reconcile against, so the tree version stands alone.
    param([string] $TreeVersion, [string] $DaemonVersion, [bool] $DaemonPresent)
    if (-not $DaemonPresent) {
        return ('  version: ' + $TreeVersion + '   (this tree; no live daemon to reconcile against)')
    }
    if ([string]::IsNullOrWhiteSpace($DaemonVersion)) {
        return ('  version: ' + $TreeVersion +
            '   (this tree; the live daemon predates version stamping -- see logs/pses-daemon.log)')
    }
    if ($DaemonVersion -eq $TreeVersion) {
        return ('  version: ' + $TreeVersion + '   (this tree AND the live daemon agree)')
    }
    return ('  version: ' + $TreeVersion + '   (this tree) -- the LIVE DAEMON is running ' +
        $DaemonVersion + '; it keeps serving until the session ends, so this is expected after an upgrade')
}

function Get-DoctorRulesetObservation {
    # Resolve the active-ruleset observation the pure Test-DoctorRuleset decides on (item 6).
    #
    # It consults the SHIPPED resolver -- Resolve-PssaSettingsPath, the same function the daemon
    # calls at analysis time (pses-daemon.ps1) -- rather than re-deriving precedence here. A second
    # implementation could disagree with the real one and would report confidently while being
    # wrong, which is worse than not reporting.
    #
    # Read-only: the resolver is a path walk-up (a chain of stats) plus a Test-Path. It never reads
    # or executes a settings file -- PSES is the trusted consumer of those.
    #
    # $ProbeDir defaults to the current directory, because "which rules apply" has no answer
    # independent of location: the repo-local walk-up starts from the edited file. The detail text
    # names the directory so the answer is never mistaken for a global one.
    param([string] $ProbeDir = '')
    $dir = $ProbeDir
    if ([string]::IsNullOrWhiteSpace($dir)) {
        try { $dir = (Get-Location).Path } catch { $dir = '' }
    }
    if ([string]::IsNullOrWhiteSpace($dir)) {
        return @{ Determinable = $false; Reason = 'the current directory could not be resolved.'; RulesetKnob = ''; ResolvedPath = ''; Source = ''; ProbeDir = '' }
    }
    try {
        # Effective values, so a `profile` shows through exactly as the daemon would see it.
        $knob = Get-PluginOption 'ruleset' 'pses-default'
        $override = Get-PluginOption 'settingsPath' ''
        # A probe PATH, never a probe FILE: the resolver only needs a location to walk up from,
        # and nothing is created on disk.
        $probeFile = Join-Path $dir '__doctor_ruleset_probe__.ps1'
        $resolved = [string](Resolve-PssaSettingsPath -EditedFilePath $probeFile -ProjectRoot $dir -Override $override -Ruleset $knob)
        $basePath = [string](Get-RulesetFallbackPath 'base')

        # Which layer won. The resolver returns the OVERRIDE verbatim when it is honored (absolute
        # and non-blank), so equality with it is the discriminator -- and a RELATIVE override,
        # which the resolver deliberately ignores, correctly falls through to the layer that
        # actually applied rather than being reported as active.
        $source = 'pses-default'
        if (-not [string]::IsNullOrWhiteSpace($resolved)) {
            if (-not [string]::IsNullOrWhiteSpace($override) -and $resolved -eq $override) {
                $source = 'override'
            } elseif (-not [string]::IsNullOrWhiteSpace($basePath) -and $resolved -eq $basePath) {
                $source = 'plugin-base'
            } else {
                $source = 'repo-local'
            }
        } elseif ($knob -eq 'base') {
            # base was asked for and the resolver still returned nothing -> the shipped ruleset is
            # missing. The knob's own documented degrade, surfaced instead of silently swallowed.
            $source = 'unresolved-base'
        }
        return @{ Determinable = $true; Reason = ''; RulesetKnob = $knob; ResolvedPath = $resolved; Source = $source; ProbeDir = $dir }
    } catch {
        return @{ Determinable = $false; Reason = ('the shipped settings resolver threw: ' + $_.Exception.Message); RulesetKnob = ''; ResolvedPath = ''; Source = ''; ProbeDir = $dir }
    }
}

function Get-DoctorOrgPolicyObservation {
    # Resolve the org-policy observation the pure Test-DoctorOrgPolicy decides on (C2 / F12).
    #
    # It calls the SHIPPED reader -- Import-OrgPolicyExcludes, in lib/lsp-common.ps1, which
    # doctor.ps1 already dot-sources -- with the knob value read exactly as lsp-client.ps1
    # reads it. That is deliberate and load-bearing: a second implementation of "is this
    # policy applying" could disagree with the one that really filters the user's
    # diagnostics, and would then report confidently while being wrong. Every verdict here,
    # including every degrade reason quoted to the user, is the client's own verdict.
    #
    # This is the ONE doctor check that reads a user-named file. The crossing is the reader's
    # own recorded contract, not a new decision: Import-OrgPolicyExcludes parses through
    # Import-PowerShellDataFile, PowerShell's RESTRICTED language mode -- data only, no
    # command invocation, no expressions -- which is why the client may read THIS .psd1 where
    # Resolve-PssaSettingsPath deliberately does not (that path hands its file to PSES to
    # consume as full settings). Read-only; nothing is created, and the reader never throws
    # out (it catches internally and fails open to @()).
    $warning = ''
    try {
        $knob = [string](Get-PluginOption 'orgPolicy' '')
        if ([string]::IsNullOrWhiteSpace($knob)) {
            return @{ Determinable = $true; Reason = ''; KnobSet = $false; PolicyPath = '';
                ExcludeCount = 0; DegradeReason = '' }
        }
        # @() around the call, not just inside the reader: PowerShell unrolls a one-element
        # return to a scalar on assignment, and a scalar's .Count is $null on Windows
        # PowerShell 5.1 -- which would silently report a one-rule policy as no policy.
        $codes = @(Import-OrgPolicyExcludes -Path $knob -WarningOut ([ref]$warning))
        return @{ Determinable = $true; Reason = ''; KnobSet = $true; PolicyPath = $knob;
            ExcludeCount = $codes.Count; DegradeReason = [string]$warning }
    } catch {
        return @{ Determinable = $false; KnobSet = $false; PolicyPath = ''; ExcludeCount = 0;
            DegradeReason = ''
            Reason = ('the shipped org-policy reader threw: ' + $_.Exception.Message) }
    }
}

function Get-DoctorServeTransportObservation {
    # Resolve what Test-DoctorServeTransport decides on (dispatch 000233).
    #
    # The knob list is the set the LSP serve subprocess actually reads, and it is DERIVED from
    # the shim's source rather than typed here -- the same reason the ps_host observation calls
    # the shipped reader instead of re-implementing it. A knob added to the shim tomorrow shows
    # up in the doctor without anyone remembering to add it.
    #
    # CONFIGURED is read through the SHIPPED reader (Get-PluginOption), so profile resolution
    # and env-name normalization apply here exactly as on the live path. EFFECTIVE is what the
    # serve subprocess would resolve: the configured value when the manifest carries a
    # ${user_config.*} mapping for that knob, and the shipped default when it does not.
    $obsReason = ''
    $obsRows = @()
    try {
        $manifestPath = Get-PluginManifestPath
        if ([string]::IsNullOrWhiteSpace($manifestPath) -or -not (Test-Path -LiteralPath $manifestPath)) {
            return @{ Determinable = $false; Reason = 'the plugin manifest (.claude-plugin/plugin.json) could not be located.'; Rows = @() }
        }
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $envBlock = $null
        if ($manifest.lspServers -and $manifest.lspServers.powershell) { $envBlock = $manifest.lspServers.powershell.env }

        $shimPath = Join-Path $PSScriptRoot 'pses-serve-shim.ps1'
        if (-not (Test-Path -LiteralPath $shimPath)) {
            return @{ Determinable = $false; Reason = 'the serve shim (scripts/pses-serve-shim.ps1) is not present in this tree.'; Rows = @() }
        }
        # Derive the knobs and their shipped defaults from the shim's own reader calls.
        $shimText = [System.IO.File]::ReadAllText($shimPath)
        $knobs = New-Object System.Collections.Generic.List[object]
        foreach ($m in [regex]::Matches($shimText, "Get-PluginOptionProvenance\s+-Key\s+'([^']+)'\s+-Default\s+'([^']*)'")) {
            $knobs.Add(@{ Key = $m.Groups[1].Value; Default = $m.Groups[2].Value })
        }
        foreach ($m in [regex]::Matches($shimText, "Get-PluginOption\s+'([^']+)'\s+'([^']*)'")) {
            if (-not (($knobs.ToArray() | ForEach-Object { $_.Key }) -contains $m.Groups[1].Value)) {
                $knobs.Add(@{ Key = $m.Groups[1].Value; Default = $m.Groups[2].Value })
            }
        }
        if ($knobs.Count -eq 0) {
            return @{ Determinable = $false; Reason = 'no knob reads could be derived from the serve shim.'; Rows = @() }
        }

        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($k in $knobs) {
            $key = [string]$k.Key
            $configured = Get-PluginOption $key ''
            $mapped = $false
            if ($null -ne $envBlock) {
                $target = ($key -replace '_', '').ToLowerInvariant()
                foreach ($p in $envBlock.PSObject.Properties) {
                    $n = [string]$p.Name
                    if (-not $n.StartsWith('CLAUDE_PLUGIN_OPTION_', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                    if ((($n.Substring('CLAUDE_PLUGIN_OPTION_'.Length)) -replace '_', '').ToLowerInvariant() -ne $target) { continue }
                    if ([string]$p.Value -match ('^\$\{user_config\.' + [regex]::Escape($key) + '\}$')) { $mapped = $true; break }
                }
            }
            $effective = if ($mapped -and -not [string]::IsNullOrWhiteSpace($configured)) { $configured } else { [string]$k.Default }
            # SUSPENDED is a THIRD state, distinct from both mapped and merely-unmapped (dispatch
            # 000241). An unmapped knob is normally a defect -- the user asked for something the
            # running system will silently not do. A SUSPENDED knob is unmapped ON PURPOSE, because
            # keeping its mapping made Claude Code 2.1.233 discard every LSP server this plugin
            # declares. Collapsing the two would either cry wolf on every install that configures
            # one of them, or blind the check to a genuinely forgotten mapping. The verdict keeps
            # them apart, and the suspension list is the SHIPPED one -- not a copy.
            $rows.Add(@{ Key = $key; Configured = $configured; Mapped = $mapped; Effective = $effective
                    Suspended = [bool](Test-ServeTransportSuspended -Key $key)
                })
        }
        # .ToArray(), NOT @($rows). The array-subexpression idiom throws
        # "System.ArgumentException: Argument types do not match" on a raw
        # System.Collections.Generic.List[object]; .ToArray() hands back a real object[].
        # Found by RUNNING the check rather than reading it -- the defect surfaced only as an
        # UNKNOWN row in the doctor's own output, which is exactly the shape of silent failure
        # this check exists to make visible.
        $obsRows = $rows.ToArray()
        return @{ Determinable = $true; Reason = ''; Rows = $obsRows }
    } catch {
        $obsReason = ('reading the manifest or the shim failed at line ' + $_.InvocationInfo.ScriptLineNumber + ': ' + $_.Exception.Message)
    }
    return @{ Determinable = $false; Reason = $obsReason; Rows = $obsRows }
}

function Get-DoctorPsHostObservation {
    # Resolve the ps_host observation the pure Test-DoctorPsHost decides on (F11).
    #
    # Two deliberate mirrorings, both for the same reason the org-policy observation calls the
    # shipped reader -- a second implementation could disagree with the one that really runs:
    #
    #   1. The knob is read through Get-PluginOption with the SAME default the three shipped
    #      consumers pass ('pwsh' -- lsp-client.ps1:209, pses-serve-shim.ps1:85,
    #      session-start.ps1:53), so profile resolution and the env-name normalization apply
    #      here exactly as they do on the live path.
    #   2. Resolution uses a BARE Get-Command, with no -CommandType filter, because that is
    #      literally what Resolve-PsHost does. Narrowing it to Application here would make the
    #      doctor reject values the plugin itself would accept, which is a worse failure than
    #      not checking: a confident, wrong FAIL.
    #
    # Read-only -- Get-Command is a lookup. Nothing is launched.
    $default = 'pwsh'
    try {
        $value = [string](Get-PluginOption 'ps_host' $default)
        # Unset and explicitly-'pwsh' are indistinguishable AFTER Get-PluginOption applies the
        # default, and they are also the same state operationally, so they are not distinguished.
        $isDefault = ($value -eq $default)
        $found = $false
        $resolved = ''
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $cmd = Get-Command $value -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $cmd) {
                $found = $true
                try { $resolved = [string]$cmd.Source } catch { $resolved = '' }
                if ([string]::IsNullOrWhiteSpace($resolved)) { $resolved = [string]$cmd.Name }
            }
        }
        return @{ Determinable = $true; Reason = ''; Value = $value; IsDefault = $isDefault
            Found = $found; ResolvedPath = $resolved }
    } catch {
        return @{ Determinable = $false; Value = ''; IsDefault = $false; Found = $false
            ResolvedPath = ''
            Reason = ('the ps_host value could not be read: ' + $_.Exception.Message) }
    }
}

# The synthetic probe used by the end-to-end check (item 8). An unapproved verb trips
# PSUseApprovedVerbs, which is in PSES's BUILT-IN no-settings set -- so the probe works on the
# shipped default configuration, not only under ruleset=base. It is the README's own example.
$script:DoctorProbeRuleId = 'PSUseApprovedVerbs'
$script:DoctorProbeSource = @(
    '# powershell-lsp doctor -- synthetic probe file. Safe to delete.',
    '# The unapproved verb below is DELIBERATE: it is the defect the doctor expects back.',
    'function Frobnicate-DoctorProbe {',
    '    Get-Process',
    '}'
) -join "`n"

function Get-DoctorTestDiagnosticObservation {
    # Resolve the end-to-end observation the pure Test-DoctorTestDiagnostic decides on (item 8).
    #
    # WHAT IT DOES NOT DO, per OQ5: it does not start a daemon, does not restart one, does not
    # write anywhere in the repository, and does not leave a process or a file behind. It writes
    # ONE file under the OS temp directory, asks a daemon that is ALREADY running, and deletes the
    # file in a finally block.
    #
    # It reuses the daemon-discovery result rather than re-discovering, so this check can never
    # disagree with the daemon-health check directly above it about which daemon is live.
    param($DaemonObservation, [int] $ConnectTimeoutMs = 2000, [int] $ReadTimeoutMs = 15000)

    $none = @{ Determinable = $false; Reason = ''; Responded = $false; Status = ''; RuleIds = @(); ElapsedMs = 0 }
    if ($null -eq $DaemonObservation -or -not $DaemonObservation.DataRootKnown) {
        $none.Reason = 'the plugin data directory is not visible (run from inside an enabled Claude Code session).'
        return $none
    }
    if (-not $DaemonObservation.Determinable -or -not $DaemonObservation.DaemonPresent) {
        $none.Reason = 'no single live warm daemon was identified to ask -- the doctor never starts one (it is report-only).'
        return $none
    }
    if ($DaemonObservation.Reachable -ne $true) {
        $none.Reason = 'the live daemon did not answer its pipe, so there is nothing to analyze through.'
        return $none
    }
    $pipeName = [string]$DaemonObservation.Pipe
    if ([string]::IsNullOrWhiteSpace($pipeName)) {
        $none.Reason = 'the live daemon handle carried no pipe name.'
        return $none
    }

    $probeDir = $null
    $probeFile = $null
    $client = $null
    try {
        # A private temp subdirectory, so the repo-local settings walk-up starts somewhere neutral
        # and no existing temp file can be clobbered.
        $probeDir = Join-Path ([System.IO.Path]::GetTempPath()) ('powershell-lsp-doctor-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
        New-Item -ItemType Directory -Force -Path $probeDir | Out-Null
        $probeFile = Join-Path $probeDir 'doctor-probe.ps1'
        [System.IO.File]::WriteAllText($probeFile, ($script:DoctorProbeSource + "`n"), (New-Object System.Text.UTF8Encoding($false)))

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipeName,
            [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
        $client.Connect($ConnectTimeoutMs)
        $writer = New-Object System.IO.StreamWriter($client, (New-Object System.Text.UTF8Encoding($false)), 4096, $true)
        $writer.NewLine = "`n"; $writer.AutoFlush = $true
        $reader = New-Object System.IO.StreamReader($client, [System.Text.Encoding]::UTF8, $false, 4096, $true)
        # The SAME one-line JSON request lsp-client.ps1 sends. No touchedRanges -> whole-file, which
        # is what the client also does when the edit range is indeterminate.
        $req = [ordered]@{ action = 'diagnostics'; file = $probeFile; cwd = $probeDir }
        $writer.WriteLine(($req | ConvertTo-Json -Compress))
        $writer.Flush()
        $readTask = $reader.ReadLineAsync()
        if (-not $readTask.Wait($ReadTimeoutMs)) {
            $sw.Stop()
            return @{ Determinable = $true; Reason = ''; Responded = $false; Status = ''; RuleIds = @(); ElapsedMs = [int]$sw.ElapsedMilliseconds }
        }
        $line = $readTask.Result
        $sw.Stop()
        if ([string]::IsNullOrWhiteSpace($line)) {
            return @{ Determinable = $true; Reason = ''; Responded = $false; Status = ''; RuleIds = @(); ElapsedMs = [int]$sw.ElapsedMilliseconds }
        }
        $resp = $line | ConvertFrom-Json
        if (-not [bool](Get-Prop $resp 'ok')) {
            return @{ Determinable = $true; Reason = ''; Responded = $false; Status = ''; RuleIds = @(); ElapsedMs = [int]$sw.ElapsedMilliseconds }
        }
        # The pipe payload names the rule 'code' (pses-daemon.ps1's diagnostics payload); 'ruleId'
        # is the DOGFOOD CAPTURE's name for the same field. Reading the wrong one yields an empty
        # id list, which this check would then report as "settled but no findings" -- a loud,
        # wrong FAIL. Both names are accepted so the check cannot be broken by that confusion again.
        $ids = @()
        foreach ($d in @(Get-Prop $resp 'diagnostics')) {
            $rid = [string](Get-Prop $d 'code')
            if ([string]::IsNullOrWhiteSpace($rid)) { $rid = [string](Get-Prop $d 'ruleId') }
            if (-not [string]::IsNullOrWhiteSpace($rid)) { $ids += $rid }
        }
        return @{ Determinable = $true; Reason = ''; Responded = $true
            Status = [string](Get-Prop $resp 'status'); RuleIds = @($ids); ElapsedMs = [int]$sw.ElapsedMilliseconds }
    } catch {
        $none.Determinable = $true
        $none.Reason = ''
        $none.Responded = $false
        return $none
    } finally {
        if ($null -ne $client) { try { $client.Dispose() } catch { } }
        # Leave nothing behind -- the file AND its private directory.
        if ($null -ne $probeFile) { try { Remove-Item -LiteralPath $probeFile -Force -ErrorAction SilentlyContinue } catch { } }
        if ($null -ne $probeDir) { try { Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue } catch { } }
    }
}

function Get-DoctorNativeServeStatusObservation {
    # Resolve the native-serve STATUS observation (item-7 promotion). Deliberately cheap: it reads
    # the effective knob value and checks that the shim script is present. It spawns NOTHING --
    # that is the whole point of promoting this out of the opt-in probe.
    param([string] $ScriptsDir = '')
    try {
        $value = Get-PluginOption 'nativeServe' 'off'
        $shim = $false
        if (-not [string]::IsNullOrWhiteSpace($ScriptsDir)) {
            $shim = Test-Path -LiteralPath (Join-Path $ScriptsDir 'pses-serve-shim.ps1') -PathType Leaf
        }
        return @{ Determinable = $true; Reason = ''; Value = $value; ShimPresent = $shim }
    } catch {
        return @{ Determinable = $false; Reason = ('the nativeServe value could not be read: ' + $_.Exception.Message); Value = ''; ShimPresent = $false }
    }
}

function Get-DoctorNativeServeObservation {
    # Resolve the native-serve removability observation the pure Test-DoctorNativeServe decides on,
    # doing ALL the I/O here (kept out of the pure function so the decision stays unit-testable). It
    # spawns scripts/probe-native-serve.ps1 as a PWSH SUBPROCESS (the 000103 5.1-stdin lesson: a
    # Windows PowerShell 5.1 host cannot interactively drive a child's stdin on the headless CI
    # runner, so the interactive client<->PSES stdio must be pwsh<->pwsh regardless of THIS doctor's
    # own host) and reads its result file. Determinable requires the data root (CLAUDE_PLUGIN_DATA),
    # a bootstrapped PSES bundle (the direct launcher needs it), pwsh (to host the driver), and the
    # driver script. REPORT-ONLY: it drives a throwaway PSES that the driver reaps; it mutates nothing.
    param([string] $ScriptsDir, [int] $InitTimeoutMs = 20000)
    $none = @{ Determinable = $false; Reason = ''; InitReceived = $false; HasStaticNav = $false; Error = ''; ElapsedMs = 0 }
    if (-not (Get-DoctorDataRootKnown)) {
        $none.Reason = 'the plugin data directory is not known (CLAUDE_PLUGIN_DATA is unset), so PSES cannot be launched.'
        return $none
    }
    if (-not (Test-Path -LiteralPath (Get-PsesStartScript))) {
        $none.Reason = 'the PSES bundle is not bootstrapped, so the direct launcher cannot start (see the PSES bundle check).'
        return $none
    }
    if (-not (Get-DoctorPwsh).Found) {
        $none.Reason = 'pwsh was not found, and the probe drives PSES via a pwsh subprocess (see the pwsh host check).'
        return $none
    }
    $driver = Join-Path $ScriptsDir 'probe-native-serve.ps1'
    if (-not (Test-Path -LiteralPath $driver)) {
        $none.Reason = 'the probe driver (scripts/probe-native-serve.ps1) is missing.'
        return $none
    }
    $dataRoot = Get-PluginDataRoot
    $resultPath = Join-Path ([System.IO.Path]::GetTempPath()) ('nsprobe-' + ([guid]::NewGuid().ToString('N').Substring(0, 8)) + '.json')
    $err = ''
    $flat = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'pwsh'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        Add-ProcessArguments $psi @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $driver,
            '-DataRoot', $dataRoot, '-ResultPath', $resultPath, '-InitTimeoutMs', [string]$InitTimeoutMs)
        $p = [System.Diagnostics.Process]::Start($psi)
        $null = $p.StandardOutput.ReadToEndAsync()
        $null = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($InitTimeoutMs + 30000)) {
            try { $p.Kill($true) } catch { }
            $err = 'the probe subprocess timed out'
        }
        if (Test-Path -LiteralPath $resultPath) {
            $flat = (Get-Content -LiteralPath $resultPath -Raw) | ConvertFrom-Json
        }
    } catch {
        $err = [string]$_.Exception.Message
    } finally {
        try { Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue } catch { }
    }
    if ($null -eq $flat) {
        if ([string]::IsNullOrWhiteSpace($err)) { $err = 'the probe produced no result' }
        return @{ Determinable = $true; Reason = ''; InitReceived = $false; HasStaticNav = $false; Error = $err; ElapsedMs = 0 }
    }
    return @{
        Determinable = $true
        Reason       = ''
        InitReceived = [bool](Get-Prop $flat 'InitReceived')
        HasStaticNav = [bool](Get-Prop $flat 'InitHasStaticNav')
        Error        = [string](Get-Prop $flat 'Error')
        ElapsedMs    = [int](Get-Prop $flat 'InitElapsedMs')
    }
}

function Get-DoctorProvenanceObservation {
    # Resolve the CLEARANCE PROVENANCE FLOOR that the report-only header line states beside the
    # version (dispatch 000216). The floor answers the second question every support interaction
    # asks after "what version are you on?" -- "and how far back can that answer be trusted?"
    #
    # SURFACES, NEVER RE-DERIVES. The floor is computed by Get-LifecycleProvenanceFloor in
    # lib/lifecycle-provenance.ps1 and nowhere else -- the same definition scripts/rule-efficacy-
    # ledger.ps1 renders from. This asks that function, exactly as the version header asks
    # Get-PluginVersion. A private re-implementation here could disagree with the ledger about the
    # same log -- the drift the single-source rule exists to refuse -- and would also have to
    # re-decide what counts as attributable, which is not this file's ruling to make.
    #
    # THE LIBRARY IS WHY THIS WORKS AT ALL. Reaching into the ledger directly is not an option: it
    # is an entry point carrying a param() block, and dot-sourcing a .ps1 runs that block in the
    # CALLER's scope. Hit by hand while building this (every explicit -LifecyclePath came back as
    # the fallback-root rendering, because the ledger's own $LifecyclePath default overwrote the
    # parameter), and then refused structurally by the G1 purity guard, which treats a dot-sourced
    # param() block as an invariant violation with no baseline. The functions moved to a shared
    # library instead; nothing about the computation changed.
    #
    # FAIL-OPEN, ALWAYS. This is a readout over a telemetry log. Any failure to locate, load or
    # read degrades to an UNDETERMINED observation the renderer states honestly -- never a throw,
    # never a fabricated floor, and never a result object, a check row, or an exit-code input.
    #
    # -LifecyclePath is a TEST SEAM, not a knob: empty (the shipped call) lets the reader resolve
    # its own rolling family under Get-LogDir, carrying the search provenance with it.
    param([string] $ScriptsDir = '', [string] $LifecyclePath = '')
    $none = @{
        Determinable = $false; Reason = ''; State = ''; Floor = ''
        Attributable = 0; PreFloor = 0; Records = 0; Present = $false; RootKnown = $true
    }
    try {
        $dir = $ScriptsDir
        if ([string]::IsNullOrWhiteSpace($dir)) { $dir = $PSScriptRoot }
        # -ScriptsDir stays a seam so the fail-open path is reachable in a test: it is the only way
        # to point this at a tree where the library is genuinely absent.
        if (-not (Test-Path -LiteralPath (Join-Path $dir 'lib/lifecycle-provenance.ps1') -PathType Leaf)) {
            $none.Reason = 'the lifecycle provenance library (scripts/lib/lifecycle-provenance.ps1) is missing, so the floor cannot be asked for.'
            return $none
        }
        # Resolved through the provenance-carrying seam (dispatch 000185, D1-B) so a NOT-FOUND
        # result knows whether it searched the real data root or a silent temp substitute -- the
        # difference between "nothing was ever captured" and "this reader could not find it".
        $search = Resolve-LifecycleLogSearch -LifecyclePath $LifecyclePath
        $life = Read-LifecycleLog -LogPaths @($search.Paths) -Search $search
        $floor = Get-LifecycleProvenanceFloor -Versions $life.Versions -PreFloor ([int]$life.PreFloorRecords)
        return @{
            Determinable = $true
            Reason       = ''
            State        = [string]$floor.State
            Floor        = [string]$floor.Floor
            Attributable = [int]$floor.Attributable
            PreFloor     = [int]$floor.PreFloor
            Records      = [int]$life.Records
            Present      = [bool]$life.Present
            RootKnown    = [bool]$life.RootKnown
        }
    } catch {
        $none.Reason = ('the lifecycle provenance floor could not be read: ' + $_.Exception.Message)
        return $none
    }
}

function Format-DoctorProvenanceFloor {
    # PURE. Render the floor observation as the VALUE half of the header line (the renderers
    # prepend the label), so this is unit-testable without a lifecycle log (dispatch 000216).
    #
    # FIVE claims, five renderings, because they are five different things to be true:
    #   floored                    -- a floor exists; name it, and say it is window-relative.
    #   records, none attributable -- the whole retained window is the bounded gap.
    #   a log exists, no records   -- captured nothing yet. NOT the same claim as no log at all.
    #   no log, root KNOWN         -- '(absent)': nothing has been written. A claim about the world.
    #   no log, root NOT known     -- the search ran under a substituted data root, so ABSENT and
    #                                 NOT-FOUND cannot be told apart from this evidence. Saying
    #                                 '(absent)' here would be the 000182 defect: a claim about the
    #                                 world published on evidence about the reader.
    #
    # The floored rendering says RETAINED rather than "earliest ever", because the lifecycle family
    # is a rolling window Invoke-LogSweep trims to keepLastN -- the floor RISES as records age out.
    param(
        [bool] $Determinable, [string] $Reason = '', [string] $State = '', [string] $Floor = '',
        [int] $Attributable = 0, [int] $PreFloor = 0, [int] $Records = 0,
        [bool] $Present = $false, [bool] $RootKnown = $true
    )
    if (-not $Determinable) {
        $why = $Reason
        if ([string]::IsNullOrWhiteSpace($why)) { $why = 'the lifecycle provenance floor could not be read.' }
        return ('(undetermined) -- ' + $why)
    }
    if ($State -eq 'floored') {
        return ('v' + $Floor + '  (earliest version-attributable release in the RETAINED lifecycle window; ' +
            [string]$Attributable + ' attributable, ' + [string]$PreFloor + ' pre-floor)')
    }
    if ($State -eq 'gap-only') {
        return ('(none) -- ' + [string]$Records + ' retained lifecycle record(s), none version-attributable.')
    }
    if (-not $Present) {
        if (-not $RootKnown) {
            return ('(undetermined) -- the lifecycle log was searched under a FALLBACK data root, so this run ' +
                'cannot tell an uncaptured signal from one it failed to locate. Set CLAUDE_PLUGIN_DATA and re-run.')
        }
        return '(absent) -- no lifecycle log has been written yet.'
    }
    return '(absent) -- a lifecycle log exists but holds no record yet.'
}

function Get-DoctorProvenanceHeader {
    # Observe then render, in one call, so the full report and the compact status share ONE wiring
    # of the two halves rather than each repeating the parameter splat. Both surfaces state the
    # same floor from the same source; a second copy of this three-line join is a second place for
    # them to drift apart.
    param([string] $ScriptsDir = '', [string] $LifecyclePath = '')
    $o = Get-DoctorProvenanceObservation -ScriptsDir $ScriptsDir -LifecyclePath $LifecyclePath
    return (Format-DoctorProvenanceFloor -Determinable $o.Determinable -Reason $o.Reason `
            -State $o.State -Floor $o.Floor -Attributable $o.Attributable -PreFloor $o.PreFloor `
            -Records $o.Records -Present $o.Present -RootKnown $o.RootKnown)
}

# ===========================================================================
# Compose + render
# ===========================================================================

function Invoke-Doctor {
    # Gather the live probes, run the pure checks, and return the ordered result objects.
    # Separated from rendering so the structured results can be consumed programmatically.
    # $SessionId (optional) scopes the daemon-health check (6) to a specific session.
    # $ProbeNativeServe (optional, dispatch 000104) adds the opt-in native-serve removability
    # probe (check 7); when $false the check is omitted entirely so the default doctor stays fast.
    param([string] $SessionId = '', [bool] $ProbeNativeServe = $false)
    $scriptsDir = $PSScriptRoot
    $results = @()

    # 1) pwsh 7 host
    $pwsh = Get-DoctorPwsh
    $results += (Test-DoctorPwsh -Found $pwsh.Found -Version $pwsh.Version)

    # 2) plugin enabled
    $results += (Test-DoctorEnabled -PluginRootResolved (Get-DoctorPluginRootResolved))

    # Shared data-root state for the bootstrap-health checks.
    $dataRootKnown = Get-DoctorDataRootKnown
    $dataRoot = Get-PluginDataRoot

    # 3) PSES bundle
    $psesPin = Get-DoctorPin -ScriptPath (Join-Path $scriptsDir 'ensure-pses.ps1') -VarName 'PsesTag'
    $psesMarker = $false
    $psesStart = $false
    if ($dataRootKnown) {
        if (-not [string]::IsNullOrWhiteSpace($psesPin)) {
            $psesMarker = Test-Path -LiteralPath (Join-Path $dataRoot ('pses-' + $psesPin + '.ok'))
        }
        $psesStart = Test-Path -LiteralPath (Get-PsesStartScript)
    }
    $results += (Test-DoctorPses -DataRootKnown $dataRootKnown -MarkerPresent $psesMarker -StartScriptPresent $psesStart -PinTag $psesPin)

    # 4) PSScriptAnalyzer vendored + importable
    $pssaPin = Get-DoctorPin -ScriptPath (Join-Path $scriptsDir 'ensure-pssa.ps1') -VarName 'PssaVersion'
    $vendorDir = Get-PssaModuleDir
    $pssaMarker = $false
    $pssaImportable = $false
    if ($dataRootKnown) {
        if (-not [string]::IsNullOrWhiteSpace($pssaPin)) {
            $pssaMarker = Test-Path -LiteralPath (Join-Path $vendorDir ('.pssa-' + $pssaPin + '.ok'))
        }
        $pssaImportable = Test-DoctorPssaImportableProbe -VendorDir $vendorDir -PinVersion $pssaPin
    }
    $results += (Test-DoctorPssa -DataRootKnown $dataRootKnown -MarkerPresent $pssaMarker -Importable $pssaImportable -PinVersion $pssaPin)

    # 4a/4b) artifact source + offline readiness (dispatch 000244). The IMPURE half lives here,
    # matching every other check in this file: read the world, then hand plain values to a pure
    # decider. Both deciders are unit-testable without a data root, a bundle, or a network.
    $psesLayer = ''
    $pssaLayer = ''
    if ($dataRootKnown) {
        if (-not [string]::IsNullOrWhiteSpace($psesPin)) {
            $psesLayer = Get-DoctorMarkerLayer -MarkerPath (Join-Path $dataRoot ('pses-' + $psesPin + '.ok'))
        }
        if (-not [string]::IsNullOrWhiteSpace($pssaPin)) {
            $pssaLayer = Get-DoctorMarkerLayer -MarkerPath (Join-Path $vendorDir ('.pssa-' + $pssaPin + '.ok'))
        }
    }
    $results += (Test-DoctorArtifactSource -DataRootKnown $dataRootKnown -PsesLayer $psesLayer -PssaLayer $pssaLayer)

    # Pins are read from the ensure-scripts by the same non-executing reader the version pins use,
    # so the readiness check hashes against exactly what the bootstrap would demand -- never a
    # second copy of a hash that could drift from the scripts.
    $srcSettings = Get-ArtifactSourceSettings
    $bundleArtifacts = @()
    if ($srcSettings.BundleValid) {
        $wanted = @(
            [pscustomobject]@{ Name = (Get-PinnedArtifactFileName -Component 'pses' -Version $psesPin)
                Sha = (Get-DoctorPin -ScriptPath (Join-Path $scriptsDir 'ensure-pses.ps1') -VarName 'PsesSha256') }
            [pscustomobject]@{ Name = (Get-PinnedArtifactFileName -Component 'pssa' -Version $pssaPin)
                Sha = (Get-DoctorPin -ScriptPath (Join-Path $scriptsDir 'ensure-pssa.ps1') -VarName 'PssaSha256') }
        )
        foreach ($w in $wanted) {
            $staged = Join-Path $srcSettings.BundleDir $w.Name
            $present = Test-Path -LiteralPath $staged -PathType Leaf
            $bundleArtifacts += [pscustomobject]@{
                Name     = $w.Name
                Present  = $present
                PinValid = $(if ($present) { Test-PinnedFileHash -Path $staged -ExpectedSha256 $w.Sha } else { $false })
            }
        }
    }
    $results += (Test-DoctorOfflineReadiness `
            -MirrorConfigured $srcSettings.MirrorConfigured -MirrorValid $srcSettings.MirrorValid -MirrorReason $srcSettings.MirrorReason `
            -BundleConfigured $srcSettings.BundleConfigured -BundleValid $srcSettings.BundleValid -BundleReason $srcSettings.BundleReason `
            -BundleArtifacts $bundleArtifacts)

    # 5) first-run download hosts reachable (hosts read single-source from the bootstrap scripts)
    $hostNames = @()
    foreach ($s in @('ensure-pses.ps1', 'ensure-pssa.ps1')) {
        foreach ($h in (Get-DoctorHostsFromScript -ScriptPath (Join-Path $scriptsDir $s))) {
            if ($hostNames -notcontains $h) { $hostNames += $h }
        }
    }
    $hostProbes = @()
    foreach ($h in $hostNames) {
        $hostProbes += [pscustomobject]@{ Host = $h; Reachable = (Test-DoctorHostReachableProbe -HostName $h) }
    }
    $results += (Test-DoctorHosts -HostProbes $hostProbes)

    # 6) warm PSES daemon runtime health (dispatch 000037): is the per-session daemon alive
    # and answering on its named pipe right now? Report-only -- the observation (discovery +
    # the non-disruptive ping round-trip) is resolved live; the pass/fail/unknown decision is
    # pure. This is the runtime bookend to check 3 (which only confirms the bundle is
    # INSTALLED): a user can pass checks 1-5 and still have a dead or wedged language server.
    $daemonObs = Get-DoctorDaemonObservation -SessionId $SessionId
    $results += (Test-DoctorDaemon -DataRootKnown $daemonObs.DataRootKnown -Determinable $daemonObs.Determinable `
            -DaemonPresent $daemonObs.DaemonPresent -State $daemonObs.State -Reachable $daemonObs.Reachable -LiveCount $daemonObs.LiveCount)
    # Publish THIS observation for the header renderer (DX finding O2). Deliberately a hand-off of
    # the observation already resolved above, NOT a second call: the codebase's own rule is that
    # discovery happens once, because a re-derivation can disagree with the real one and report
    # confidently while being wrong. The version line must describe the daemon this check just
    # identified. Invoke-Doctor's return shape is unchanged, so every existing caller is untouched.
    $script:DoctorDaemonObs = $daemonObs

    # 7) active ruleset surface (dispatch 000166 B9, checklist item 6). WHICH rules are actually
    # applied here, resolved through the SHIPPED resolver rather than a second implementation of
    # the precedence -- a re-derivation could disagree with the real one and report confidently
    # while being wrong. Read-only (a path walk-up); report-only; never fails.
    $rsObs = Get-DoctorRulesetObservation
    $results += (Test-DoctorRuleset -Determinable $rsObs.Determinable -Reason $rsObs.Reason `
            -RulesetKnob $rsObs.RulesetKnob -ResolvedPath $rsObs.ResolvedPath -Source $rsObs.Source -ProbeDir $rsObs.ProbeDir)

    # 8) org policy exclusions (dispatch 000203 survey candidate C2, failure class F12). Sits
    # directly after check 7 because the two together are the whole answer to "which rules
    # actually reach me": check 7 reports the rule surface that gets ENABLED, this reports the
    # org layer that then SUBTRACTS from it at a different seam (lsp-client.ps1). They are kept
    # as two checks, not folded into one, because they are two seams -- merging them would make
    # a settings-resolution answer and a post-analysis-filter answer share one status word.
    # Report-only; never fails (fail-open is the design, dispatch 000135 decision 1).
    $opObs = Get-DoctorOrgPolicyObservation
    $results += (Test-DoctorOrgPolicy -Determinable $opObs.Determinable -Reason $opObs.Reason `
            -KnobSet $opObs.KnobSet -PolicyPath $opObs.PolicyPath `
            -ExcludeCount $opObs.ExcludeCount -DegradeReason $opObs.DegradeReason)

    # 9) test diagnostic observed end-to-end (dispatch 000166 B9, checklist item 8). The only check
    # that asserts the PRODUCT works rather than that its parts are installed: the daemon's 'ping'
    # answers without touching PSES, so a daemon can be alive, pinging, and analyzing nothing. Per
    # OQ5 this starts no daemon, writes nothing in the repository, and leaves no file behind. It
    # reuses $daemonObs so it can never disagree with check 6 about which daemon is live.
    $tdObs = Get-DoctorTestDiagnosticObservation -DaemonObservation $daemonObs
    $results += (Test-DoctorTestDiagnostic -Determinable $tdObs.Determinable -Reason $tdObs.Reason `
            -Responded $tdObs.Responded -Status $tdObs.Status -ExpectedRule $script:DoctorProbeRuleId `
            -RuleIds @($tdObs.RuleIds) -ElapsedMs $tdObs.ElapsedMs)

    # 10) native-serve STATUS (dispatch 000166 B9, the item-7 promotion). Answers "is navigation on
    # for me, and if not why" as a DEFAULT check by reading the effective knob value -- it spawns
    # nothing, so it costs nothing. The heavier removability PROBE below stays opt-in, unchanged.
    $nsStatus = Get-DoctorNativeServeStatusObservation -ScriptsDir $scriptsDir
    $results += (Test-DoctorNativeServeStatus -Determinable $nsStatus.Determinable -Reason $nsStatus.Reason `
            -Value $nsStatus.Value -ShimPresent $nsStatus.ShimPresent -Probed ([bool]$ProbeNativeServe))

    # 11) PSES child host resolution (dispatch 000203 survey failure class F11). Appended to the
    # END of the default surface rather than inserted beside check 1, deliberately: every check
    # comment from 2 onward, and half a dozen prose cross-references inside them ("check 7
    # above", "the runtime bookend to check 3", "checks 1-5"), are numbered, so inserting would
    # have renumbered ten comments and silently falsified those references. The pwsh/ps_host
    # contrast the reader needs is carried in this check's own component line and detail text,
    # where it is actually read, instead of by adjacency in the table.
    # Fail-capable -- the one added check here that can move the exit code, because the shipped
    # resolver's fallback makes a bad value invisible rather than loud.
    $phObs = Get-DoctorPsHostObservation
    $results += (Test-DoctorPsHost -Determinable $phObs.Determinable -Reason $phObs.Reason `
            -Value $phObs.Value -IsDefault $phObs.IsDefault -Found $phObs.Found `
            -ResolvedPath $phObs.ResolvedPath)

    # 13) serve-subprocess config transport (dispatch 000233). Appended at the END for the same
    # renumbering reason check 11 records. Cheap: it reads the manifest and the knob values and
    # spawns nothing.
    $stObs = Get-DoctorServeTransportObservation
    $results += (Test-DoctorServeTransport -Determinable $stObs.Determinable -Reason $stObs.Reason -Rows $stObs.Rows)

    # 12) native-serve removability (dispatch 000104, the 000103 OQ4). Still OPT-IN via
    # -ProbeNativeServe: it launches PSES via the DIRECT launcher and inspects the init handshake,
    # which costs a PSES cold-start plus a bounded init wait -- too heavy for every doctor run, so
    # this check appears ONLY when requested. The item-7 promotion above deliberately did NOT make
    # this probe default; it split the cheap STATUS question out of it.
    # Report-only, and never 'fail' (a removability diagnostic must not move the exit code).
    if ($ProbeNativeServe) {
        $nsObs = Get-DoctorNativeServeObservation -ScriptsDir $scriptsDir -InitTimeoutMs $script:NativeServeInitTimeoutMs
        $results += (Test-DoctorNativeServe -Determinable $nsObs.Determinable -Reason $nsObs.Reason `
                -InitReceived $nsObs.InitReceived -HasStaticNav $nsObs.HasStaticNav -ProbeError $nsObs.Error `
                -ElapsedMs $nsObs.ElapsedMs -TimeoutMs $script:NativeServeInitTimeoutMs)
    }

    return @($results)
}

function Format-DoctorReport {
    # Render the ordered results as the user-facing fix-list. A single generic security
    # pointer is appended when ANY check did not pass -- the doctor does not probe security
    # controls, so it can only point, never attribute (dispatch 000036 boundary).
    #
    # $Version renders as a HEADER LINE above the check table, not as a check row (dispatch
    # 000208 OQ3). A version is not a pass/fail result: every row in the table wears a status
    # token from a set CONTRACT.md freezes to pass/fail/unknown, so a version row would have to
    # borrow one of those words to say something that is neither a health verdict nor a
    # judgement -- and it would inflate the "of N checks" count with a non-check. As a header it
    # is unconditional, which is the property that matters: a support interaction can start from
    # a known build even when every check below is UNKNOWN.
    #
    # It is a PARAMETER with a shipped-source default rather than a direct call, so the renderer
    # stays injectable for tests; blank means "ask the one source of truth".
    #
    # $Provenance (dispatch 000216) rides beside it as a SECOND header line, under the same rule
    # and for the same reason: the clearance provenance floor is a fact, not a verdict, so it is a
    # header and never a row. It contributes no result object, so the "of N checks" count and the
    # exit code are computed from exactly the same inputs as before this line existed. Same seam
    # shape as $Version -- blank means "ask the one source of truth".
    #
    # $DaemonVersion / $DaemonPresent (DX finding O2) turn that header from a caveat into a
    # RECONCILIATION -- see Get-DoctorVersionLine. Same seam shape again: parameters with inert
    # defaults, so an out-of-band render still produces the honest no-daemon wording.
    param([object[]] $Results, [string] $Version = '', [string] $Provenance = '',
        [string] $DaemonVersion = '', [bool] $DaemonPresent = $false)
    if ([string]::IsNullOrWhiteSpace($Version)) { $Version = [string](Get-PluginVersion) }
    if ([string]::IsNullOrWhiteSpace($Provenance)) { $Provenance = Get-DoctorProvenanceHeader }
    $lines = @()
    $lines += 'powershell-lsp doctor -- preflight self-check (report-only)'
    $lines += (Get-DoctorVersionLine -TreeVersion $Version -DaemonVersion $DaemonVersion -DaemonPresent $DaemonPresent)
    $lines += ('  provenance floor: ' + $Provenance)
    $lines += ''
    foreach ($r in $Results) {
        $lines += ('  ' + ('{0,-7}' -f $r.Status.ToUpperInvariant()) + '  ' + $r.Component)
        if (-not [string]::IsNullOrWhiteSpace($r.Detail)) { $lines += ('             ' + $r.Detail) }
        if (-not [string]::IsNullOrWhiteSpace($r.Remediation)) { $lines += ('             fix: ' + $r.Remediation) }
    }
    $passN = @($Results | Where-Object { $_.Status -eq 'pass' }).Count
    $failN = @($Results | Where-Object { $_.Status -eq 'fail' }).Count
    $unkN = @($Results | Where-Object { $_.Status -eq 'unknown' }).Count
    $lines += ''
    $lines += ('  summary: ' + $passN + ' pass, ' + $failN + ' fail, ' + $unkN + ' unknown (of ' + @($Results).Count + ' checks)')
    if (($failN + $unkN) -gt 0) {
        $lines += ''
        $lines += '  Note: this doctor checks prerequisites and bootstrap health only. If a check above'
        $lines += '  failed for a reason its fix does not resolve, a security control on a managed machine'
        $lines += '  (an execution or application-control policy) may be blocking the component. The doctor'
        $lines += '  does NOT probe security controls; see the README Troubleshooting section and the'
        $lines += '  ROADMAP security-block detection work (L3).'
    }
    return ($lines -join [Environment]::NewLine)
}

function Format-DoctorSummary {
    # Compact rendering over the SAME results Format-DoctorReport renders (dispatch 000166 B10).
    # One line per check plus the summary line; no detail prose, no remediation. It is a pure
    # function of the results -- it re-runs nothing, re-decides nothing, and cannot disagree with
    # the full report about any check's status, because both consume the identical objects.
    #
    # When something is not PASS the compact view would be a dead end, so it appends ONE pointer
    # at the full report rather than silently dropping the fix text.
    # The version header rides here too, for the same reason and from the same source as in
    # Format-DoctorReport: /status is the surface a user is most likely to paste into a support
    # thread, so it is the one that can least afford to omit which build produced it. The
    # provenance floor (dispatch 000216) rides for exactly that reason as well -- the two facts
    # are one answer, and splitting them across surfaces would make /status the surface that
    # states a version it cannot date.
    param([object[]] $Results, [string] $Version = '', [string] $Provenance = '',
        [string] $DaemonVersion = '', [bool] $DaemonPresent = $false)
    if ([string]::IsNullOrWhiteSpace($Version)) { $Version = [string](Get-PluginVersion) }
    if ([string]::IsNullOrWhiteSpace($Provenance)) { $Provenance = Get-DoctorProvenanceHeader }
    $lines = @()
    $lines += 'powershell-lsp status -- ' + @($Results).Count + ' checks (report-only)'
    $lines += (Get-DoctorVersionLine -TreeVersion $Version -DaemonVersion $DaemonVersion -DaemonPresent $DaemonPresent)
    $lines += ('  provenance floor: ' + $Provenance)
    $lines += ''
    foreach ($r in $Results) {
        $lines += ('  ' + ('{0,-7}' -f $r.Status.ToUpperInvariant()) + '  ' + $r.Component)
    }
    $passN = @($Results | Where-Object { $_.Status -eq 'pass' }).Count
    $failN = @($Results | Where-Object { $_.Status -eq 'fail' }).Count
    $unkN = @($Results | Where-Object { $_.Status -eq 'unknown' }).Count
    $lines += ''
    $lines += ('  summary: ' + $passN + ' pass, ' + $failN + ' fail, ' + $unkN + ' unknown (of ' + @($Results).Count + ' checks)')
    if (($failN + $unkN) -gt 0) {
        $lines += ''
        $lines += '  For the per-check detail and the fix for each, run the full report:'
        $lines += '    pwsh -File "$env:CLAUDE_PLUGIN_ROOT/scripts/doctor.ps1"'
    }
    return ($lines -join [Environment]::NewLine)
}

# ===========================================================================
# Entry point -- runs ONLY on direct invocation (pwsh -File ...), not when the script
# is dot-sourced (so the unit tests load the functions without running live probes).
# ===========================================================================
if ($MyInvocation.InvocationName -ne '.') {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $doctorResults = Invoke-Doctor -SessionId $SessionId -ProbeNativeServe:([bool]$ProbeNativeServe)
    # The daemon observation Invoke-Doctor already resolved, for the O2 version reconciliation.
    # Absent or malformed -> the renderer's inert defaults, which produce the honest no-daemon
    # wording rather than a fabricated agreement.
    $dObs = $script:DoctorDaemonObs
    $dVer = ''; $dPresent = $false
    if ($null -ne $dObs) {
        try { $dVer = [string]$dObs.DaemonVersion } catch { $dVer = '' }
        try { $dPresent = [bool]$dObs.DaemonPresent } catch { $dPresent = $false }
    }
    if ($Summary) {
        Write-Host (Format-DoctorSummary -Results $doctorResults -DaemonVersion $dVer -DaemonPresent $dPresent)
    } else {
        Write-Host (Format-DoctorReport -Results $doctorResults -DaemonVersion $dVer -DaemonPresent $dPresent)
    }
    # The exit code is computed from the SAME results either way -- the rendering never
    # changes the verdict, and 'unknown' is never a failure.
    $doctorFailures = @($doctorResults | Where-Object { $_.Status -eq 'fail' }).Count
    if ($doctorFailures -gt 0) { exit 1 } else { exit 0 }
}
