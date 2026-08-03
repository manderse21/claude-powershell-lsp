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
                -Remediation 'Run this doctor from inside a Claude Code session (where CLAUDE_PLUGIN_DATA is set) for a definitive check.')
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
                -Remediation 'Run this doctor from inside a Claude Code session for a definitive check.')
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
                -Remediation 'Run this doctor from inside a Claude Code session (where CLAUDE_PLUGIN_DATA is set) for a definitive runtime check.')
    }
    if (-not $Determinable) {
        return (New-DoctorResult -Status unknown -Component $component `
                -Detail ('found ' + $LiveCount + ' live daemons but no session id, so which one serves THIS session cannot be determined from outside it.') `
                -Remediation 'Re-run with -SessionId <session-id> (or from a context that sets CLAUDE_SESSION_ID) to scope the check to this session.')
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
        $live += [pscustomobject]@{ Pipe = $pipe; State = [string](Get-Prop $obj 'state') }
    }

    if ($live.Count -eq 0) {
        # No live daemon in scope -> the benign 000030 absent-but-relaunchable case.
        return @{ DataRootKnown = $true; Determinable = $true; DaemonPresent = $false; State = ''; Reachable = $null; LiveCount = 0; Pipe = '' }
    }
    if (-not $scoped -and $live.Count -gt 1) {
        # Several live daemons and no session id to pick THIS session's -> honest UNKNOWN.
        return @{ DataRootKnown = $true; Determinable = $false; DaemonPresent = $true; State = ''; Reachable = $null; LiveCount = $live.Count; Pipe = '' }
    }
    $d = $live[0]
    $reachable = Test-DoctorDaemonPingProbe -PipeName $d.Pipe
    # Pipe rides along (dispatch 000166) so the end-to-end check can ask the SAME daemon this
    # check just identified, instead of re-discovering and possibly disagreeing with it.
    return @{ DataRootKnown = $true; Determinable = $true; DaemonPresent = $true; State = $d.State; Reachable = $reachable; LiveCount = 1; Pipe = $d.Pipe }
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

    # 7) active ruleset surface (dispatch 000166 B9, checklist item 6). WHICH rules are actually
    # applied here, resolved through the SHIPPED resolver rather than a second implementation of
    # the precedence -- a re-derivation could disagree with the real one and report confidently
    # while being wrong. Read-only (a path walk-up); report-only; never fails.
    $rsObs = Get-DoctorRulesetObservation
    $results += (Test-DoctorRuleset -Determinable $rsObs.Determinable -Reason $rsObs.Reason `
            -RulesetKnob $rsObs.RulesetKnob -ResolvedPath $rsObs.ResolvedPath -Source $rsObs.Source -ProbeDir $rsObs.ProbeDir)

    # 8) test diagnostic observed end-to-end (dispatch 000166 B9, checklist item 8). The only check
    # that asserts the PRODUCT works rather than that its parts are installed: the daemon's 'ping'
    # answers without touching PSES, so a daemon can be alive, pinging, and analyzing nothing. Per
    # OQ5 this starts no daemon, writes nothing in the repository, and leaves no file behind. It
    # reuses $daemonObs so it can never disagree with check 6 about which daemon is live.
    $tdObs = Get-DoctorTestDiagnosticObservation -DaemonObservation $daemonObs
    $results += (Test-DoctorTestDiagnostic -Determinable $tdObs.Determinable -Reason $tdObs.Reason `
            -Responded $tdObs.Responded -Status $tdObs.Status -ExpectedRule $script:DoctorProbeRuleId `
            -RuleIds @($tdObs.RuleIds) -ElapsedMs $tdObs.ElapsedMs)

    # 9) native-serve STATUS (dispatch 000166 B9, the item-7 promotion). Answers "is navigation on
    # for me, and if not why" as a DEFAULT check by reading the effective knob value -- it spawns
    # nothing, so it costs nothing. The heavier removability PROBE below stays opt-in, unchanged.
    $nsStatus = Get-DoctorNativeServeStatusObservation -ScriptsDir $scriptsDir
    $results += (Test-DoctorNativeServeStatus -Determinable $nsStatus.Determinable -Reason $nsStatus.Reason `
            -Value $nsStatus.Value -ShimPresent $nsStatus.ShimPresent -Probed ([bool]$ProbeNativeServe))

    # 10) native-serve removability (dispatch 000104, the 000103 OQ4). Still OPT-IN via
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
    param([object[]] $Results)
    $lines = @()
    $lines += 'powershell-lsp doctor -- preflight self-check (report-only)'
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
    param([object[]] $Results)
    $lines = @()
    $lines += 'powershell-lsp status -- ' + @($Results).Count + ' checks (report-only)'
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
    if ($Summary) {
        Write-Host (Format-DoctorSummary -Results $doctorResults)
    } else {
        Write-Host (Format-DoctorReport -Results $doctorResults)
    }
    # The exit code is computed from the SAME results either way -- the rendering never
    # changes the verdict, and 'unknown' is never a failure.
    $doctorFailures = @($doctorResults | Where-Object { $_.Status -eq 'fail' }).Count
    if ($doctorFailures -gt 0) { exit 1 } else { exit 0 }
}
