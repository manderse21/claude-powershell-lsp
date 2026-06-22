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
#
# Exit 0 when no check FAILED (passes and honest unknowns are not failures); exit 1
# when at least one check failed. The script is dot-source safe: dot-sourcing defines
# the functions without running the checks (so the unit tests can exercise the pure
# decision functions in isolation).
#
# Author: Mike Andersen / powershell-lsp plugin.

. (Join-Path $PSScriptRoot 'lib/lsp-common.ps1')

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
    return (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_PLUGIN_DATA))
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

# ===========================================================================
# Compose + render
# ===========================================================================

function Invoke-Doctor {
    # Gather the live probes, run the pure checks, and return the ordered result objects.
    # Separated from rendering so the structured results can be consumed programmatically.
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

# ===========================================================================
# Entry point -- runs ONLY on direct invocation (pwsh -File ...), not when the script
# is dot-sourced (so the unit tests load the functions without running live probes).
# ===========================================================================
if ($MyInvocation.InvocationName -ne '.') {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $doctorResults = Invoke-Doctor
    Write-Host (Format-DoctorReport -Results $doctorResults)
    $doctorFailures = @($doctorResults | Where-Object { $_.Status -eq 'fail' }).Count
    if ($doctorFailures -gt 0) { exit 1 } else { exit 0 }
}
