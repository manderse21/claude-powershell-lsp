#Requires -Version 7.0

<#
.SYNOPSIS
    Assert the doctor's CENSUS inside the official PowerShell container (dispatch 000286, P2-3).

.DESCRIPTION
    The enterprise docket asks for a container CI leg running the suite plus
    "doctor -RequireProven". Derived fresh rather than assumed, -RequireProven CANNOT pass in a
    container, and no change to this repository can make it:

      pass 6 / fail 0 / unknown 8 / total 14   ->  default exit 0, -RequireProven exit 2

    Six of the eight unknowns are unknowable outside a live Claude Code plugin subprocess, because
    CLAUDE_PLUGIN_DATA is exported to the plugin's own hooks and to nothing else. Setting it to a
    writable directory does not help and actively hurts -- measured, the census then reads
    UNHEALTHY with pass 7 / fail 2 / unknown 5, because an empty data directory turns honest
    unknowns into real failures. A seventh unknown ("Offline readiness") reports that no offline
    artifact source is configured, which is the shipped default. The eighth ("PSES child host")
    is unknown BY DESIGN whenever ps_host is at its default, since it defers to check 1 rather
    than deciding the same executable twice.

    So this leg asserts the KNOWN POSTURE explicitly instead of gating on a value it cannot reach.
    That is a stronger gate than it sounds, because the defect P2-3 was blocked on was not a
    missing feature -- it was check 1 answering "found pwsh 0.0.0.0 but PowerShell 7+ is required"
    on a host running 7.4.2, a confident and precise WRONG answer produced by reading the
    executable's Windows-only file-version resource. The assertions below are what would have
    caught it:

      * fail MUST be 0            -- a fabricated failure is exactly what the old probe produced
      * check 1 MUST be 'pass'    -- on a container whose only PowerShell is the one running this
      * and its detail MUST name  -- proving the probe read the REAL in-process version rather
        the running version          than a zero, which is the substance of the 000285 fix
      * the UNKNOWN set is pinned -- so a check silently changing status is a build failure

.NOTES
    ENVIRONMENT-DEPENDENT CHECKS ARE REPORTED, NOT ASSERTED. "First-run download hosts reachable"
    measures the runner's egress, not this repository's code. Gating on it would let a network
    blip redden a required check, and a gate that goes red for reasons its owner cannot fix is a
    gate that gets silenced. Its status is printed for the record and excluded from the strict
    comparison -- but its PRESENCE in the census is still asserted, so a rename cannot quietly
    drop it from both sides of the comparison and leave the exclusion covering nothing.

    ASCII-only (PS 5.1 em-dash trap), though this script is pwsh-only by construction.
#>
[CmdletBinding()]
param(
    # The doctor to exercise. Default: scripts/doctor.ps1 beside this checkout.
    [string] $DoctorPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($DoctorPath)) {
    $DoctorPath = Join-Path (Join-Path $repoRoot 'scripts') 'doctor.ps1'
}
if (-not (Test-Path -LiteralPath $DoctorPath)) {
    Write-Error "doctor not found: $DoctorPath"
    exit 1
}

# THE EXPECTED CENSUS. Derived by running the doctor in
# mcr.microsoft.com/powershell:7.5-ubuntu-24.04 as uid 1000, no TTY, no profile, and confirmed
# identical in shape under :latest (7.4.2). These are the values a change must consciously
# update, which is the point of pinning them.
$ExpectedTotal = 14
$ExpectedRequireProvenExit = 2

$ExpectedPass = @(
    'PowerShell 7 (pwsh) host'
    'Active ruleset surface'
    'Org policy exclusions'
    'Native-serve status (hover / definition / references)'
    'Serve-subprocess config transport (configured vs effective)'
)
$ExpectedUnknown = @(
    'Plugin enabled'
    'PSES bundle bootstrapped'
    'PSScriptAnalyzer vendored'
    'Artifact source'
    'Offline readiness'
    'Warm PSES daemon (runtime)'
    'Test diagnostic observed end-to-end'
    'PSES child host (ps_host)'
)
# Reported, never asserted -- see .NOTES.
$EnvironmentDependent = @('First-run download hosts reachable')

$failures = New-Object System.Collections.Generic.List[string]
function Add-Failure { param([string] $Message) $script:failures.Add($Message) }

Write-Host '== container doctor census =================================================='
Write-Host ("host pwsh   : {0}" -f $PSVersionTable.PSVersion)
Write-Host ("doctor      : {0}" -f $DoctorPath)

# ---------------------------------------------------------------------------------------------
# 1. The default run. Exit 0, and a parseable envelope.
# ---------------------------------------------------------------------------------------------
$raw = & pwsh -NoProfile -NonInteractive -File $DoctorPath -Json 2>&1 | Out-String
$defaultExit = $LASTEXITCODE

# PAYLOAD FLOOR. Every assertion below reads this object, so if it did not parse, or parsed to
# nothing, the whole file must FAIL rather than sail through a pile of vacuous comparisons over
# an empty set. An exit code alone is blind to a payload that was corrupted before it was read.
$doc = $null
try { $doc = $raw | ConvertFrom-Json } catch { $doc = $null }
if ($null -eq $doc) {
    Write-Host 'FATAL: the doctor did not emit parseable JSON. Raw output follows.'
    Write-Host $raw
    exit 1
}
$checks = @($doc.checks)
if ($checks.Count -eq 0) {
    Write-Host 'FATAL: the census carried ZERO checks; every comparison below would be vacuous.'
    exit 1
}
if ($ExpectedUnknown.Count -eq 0 -or $ExpectedPass.Count -eq 0) {
    Write-Host 'FATAL: the expected sets are empty; this script would assert nothing.'
    exit 1
}

Write-Host ("status      : {0}" -f $doc.status)
Write-Host ("versions    : pwsh={0} plugin={1}" -f $doc.versions.pwsh, $doc.versions.plugin)
Write-Host ("summary     : pass={0} fail={1} unknown={2} total={3}" -f `
    $doc.summary.pass, $doc.summary.fail, $doc.summary.unknown, $doc.summary.total)
Write-Host ("default exit: {0}" -f $defaultExit)
Write-Host ''
foreach ($c in $checks) { Write-Host ("  [{0,-7}] {1}" -f $c.status, $c.component) }
Write-Host ''

if ($defaultExit -ne 0) { Add-Failure "default doctor exit was $defaultExit, expected 0" }
if ($checks.Count -ne $ExpectedTotal) {
    Add-Failure ("census carried {0} checks, expected {1} -- a check was added or removed; update this script deliberately" -f $checks.Count, $ExpectedTotal)
}

# ---------------------------------------------------------------------------------------------
# 2. NO FABRICATED FAILURES. This is the assertion that would have caught the P2-3 blocker.
# ---------------------------------------------------------------------------------------------
$failed = @($checks | Where-Object { $_.status -eq 'fail' -and $EnvironmentDependent -notcontains $_.component })
if ($failed.Count -ne 0) {
    foreach ($f in $failed) { Add-Failure ("check FAILED in the container: '{0}' -- {1}" -f $f.component, $f.detail) }
}

# ---------------------------------------------------------------------------------------------
# 3. Check 1 must report the REAL in-process version. The substance of the 000285 fix.
# ---------------------------------------------------------------------------------------------
$hostCheck = @($checks | Where-Object { $_.component -eq 'PowerShell 7 (pwsh) host' })
if ($hostCheck.Count -ne 1) {
    Add-Failure "expected exactly one 'PowerShell 7 (pwsh) host' check, found $($hostCheck.Count)"
} else {
    if ($hostCheck[0].status -ne 'pass') {
        Add-Failure ("the pwsh host check is '{0}' in a container whose only PowerShell is this one -- {1}" -f $hostCheck[0].status, $hostCheck[0].detail)
    }
    $running = $PSVersionTable.PSVersion.ToString()
    if (-not $hostCheck[0].detail.Contains($running)) {
        Add-Failure ("the pwsh host check does not name the running version {0}; it said: {1}. A 0.0.0.0 here is the exact defect P2-3 was blocked on." -f $running, $hostCheck[0].detail)
    }
    if ($hostCheck[0].detail.Contains('0.0.0.0')) {
        Add-Failure "the pwsh host check reported 0.0.0.0 -- the Windows-only file-version resource is being read again"
    }
}

# ---------------------------------------------------------------------------------------------
# 4. The UNKNOWN and PASS sets are pinned, so a silent status change is a build failure.
# ---------------------------------------------------------------------------------------------
foreach ($name in $EnvironmentDependent) {
    if (@($checks | Where-Object { $_.component -eq $name }).Count -ne 1) {
        Add-Failure ("the environment-dependent check '{0}' is not in the census; the exclusion for it now covers nothing and must be re-derived" -f $name)
    } else {
        $st = @($checks | Where-Object { $_.component -eq $name })[0].status
        Write-Host ("reported, not asserted: '{0}' = {1}" -f $name, $st)
    }
}

$actualUnknown = @($checks | Where-Object { $_.status -eq 'unknown' -and $EnvironmentDependent -notcontains $_.component } | ForEach-Object { $_.component })
$actualPass = @($checks | Where-Object { $_.status -eq 'pass' -and $EnvironmentDependent -notcontains $_.component } | ForEach-Object { $_.component })

$unknownMissing = @($ExpectedUnknown | Where-Object { $actualUnknown -notcontains $_ })
$unknownExtra = @($actualUnknown | Where-Object { $ExpectedUnknown -notcontains $_ })
$passMissing = @($ExpectedPass | Where-Object { $actualPass -notcontains $_ })
$passExtra = @($actualPass | Where-Object { $ExpectedPass -notcontains $_ })

foreach ($m in $unknownMissing) { Add-Failure "expected UNKNOWN but was not: '$m'" }
foreach ($m in $unknownExtra) { Add-Failure "unexpectedly UNKNOWN: '$m'" }
foreach ($m in $passMissing) { Add-Failure "expected PASS but was not: '$m'" }
foreach ($m in $passExtra) { Add-Failure "unexpectedly PASS: '$m'" }

# ---------------------------------------------------------------------------------------------
# 5. -RequireProven exits 2. Not 0 (which would mean the switch is inert) and not 1 (which would
#    mean something FAILED). The exact value is the point: it is how a CI job tells "unproven"
#    from "broken" without parsing prose.
# ---------------------------------------------------------------------------------------------
& pwsh -NoProfile -NonInteractive -File $DoctorPath -RequireProven *> $null
$provenExit = $LASTEXITCODE
Write-Host ''
Write-Host ("-RequireProven exit: {0} (expected {1})" -f $provenExit, $ExpectedRequireProvenExit)
if ($provenExit -ne $ExpectedRequireProvenExit) {
    Add-Failure ("-RequireProven exited {0}, expected {1}. 0 would mean the opt-in gate is inert; 1 would mean a check FAILED." -f $provenExit, $ExpectedRequireProvenExit)
}

# ---------------------------------------------------------------------------------------------
Write-Host ''
Write-Host '== verdict =================================================================='
if ($failures.Count -eq 0) {
    Write-Host ("PASS -- the container census is exactly as pinned ({0} checks; {1} pass, {2} unknown, 0 fail), and -RequireProven exits {3}." -f `
        $ExpectedTotal, $ExpectedPass.Count, $ExpectedUnknown.Count, $ExpectedRequireProvenExit)
    exit 0
}
foreach ($f in $failures) { Write-Host "FAIL -- $f" }
Write-Host ''
Write-Host ("{0} assertion(s) failed." -f $failures.Count)
exit 1
