#Requires -Version 5.1

<#
.SYNOPSIS
    Decide whether a PRODUCING release run is paired with a successful DRY RUN of the same workflow,
    on the same target commit, inside a bounded recency window.

.DESCRIPTION
    THE GAP THIS CLOSES. docs/RELEASING.md has always described the release as a PAIR -- rehearse
    with dry_run=true, then cut for real -- but nothing refused a producing run that skipped the
    rehearsal. v1.29.0 proved the gap by shipping with no dry run at all; only a later true-up
    dispatch noticed. A convention that nothing enforces is a convention that is eventually skipped
    under time pressure, which is exactly when the rehearsal is worth most.

    WHY THIS IS A SCRIPT AND NOT INLINE BASH. Dispatches 000161 and 000169 both had to answer
    "which of these runs was the dry run?" and both had to do it the hard way, because dry_run is
    NOT discriminable from a run object -- the input does not appear on it. That made the question
    a log/step-forensics exercise. The decision logic therefore lives here, where it can be unit
    tested against synthetic run sets, instead of inside a workflow step where it can only ever be
    exercised by cutting a real release.

    THE DISCRIMINATOR, going forward: the workflow's `run-name` encodes the dry_run input and the
    commit input, and `run-name` is evaluated into the run object's own name/display_title. GitHub
    documents the `inputs` context as available to `run-name`, so this is a structural property of
    the run rather than a fact recoverable only from its logs.

    THE FALLBACK, for runs created BEFORE that marker shipped: the caller may supply
    `legacyIsDryRun` per run, determined by step-conclusion inspection (the 000169 method -- a dry
    run's mutating steps are `skipped` and its "Dry-run summary" step is `success`). A run with
    neither a marker nor a legacy verdict is UNKNOWN and never satisfies the gate: an unproven
    rehearsal is not a rehearsal.

.PARAMETER RunsJsonPath
    Path to a JSON file holding an ARRAY of workflow-run objects. Required fields per run:
    `conclusion`, `created_at`, `head_sha`, and one of `display_title` / `name`. Optional:
    `legacyIsDryRun` (boolean) for pre-marker runs, and `id` for reporting.

.PARAMETER TargetCommit
    The resolved target commit the producing run intends to tag. A candidate dry run matches when
    its run-name carries `target=<that sha>`, or -- when the run-name carries `target=HEAD`,
    meaning the commit input was left blank -- when its own `head_sha` equals this value.

.PARAMETER WindowDays
    How recent a dry run must be to count. Defaults to 3; see the justification the workflow echoes.

.PARAMETER NowUtc
    Overrides "now" (ISO 8601, UTC) so the window is testable without waiting. Defaults to the
    current UTC time.

.NOTES
    ASCII-only. Exit 0 = a matching dry run was found; exit 1 = refuse.

    THE HOST THIS RUNS UNDER, and why the #Requires above still matters. In the pipeline this
    script executes ONLY under pwsh: Gate 6 is a `shell: bash` step on a `runs-on: ubuntu-24.04`
    job that invokes it as `pwsh -NoProfile -File ./release/Test-DryRunPair.ps1`, so the
    `#Requires -Version 5.1` at the top of this file is never exercised there. That declaration is
    a real claim nonetheless -- this script is dual-host correct as of dispatch 000200, which found
    and fixed a Windows PowerShell 5.1 defect that would have made the shipped gate refuse every
    genuine rehearsal had it ever run under 5.1. Keep edits 5.1-clean: the only thing enforcing
    that is the test suite's `windows-powershell` leg, which has now demonstrably caught one.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $RunsJsonPath,
    [Parameter(Mandatory = $true)] [string] $TargetCommit,
    [int] $WindowDays = 3,
    [string] $NowUtc = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# THE MARKERS. These strings are the contract between this script and the workflow's `run-name`.
# PowerShellLsp.Release.Tests.ps1 asserts the workflow's run-name literal carries both of them and
# the `target=` field, so the two cannot drift apart silently.
$script:DryRunMarker = '[DRY-RUN]'
$script:ProducingMarker = '[PRODUCING]'

function Get-RunTitle {
    param($Run)
    foreach ($prop in @('display_title', 'name')) {
        if ($Run.PSObject.Properties.Name -contains $prop) {
            $v = $Run.$prop
            if (-not [string]::IsNullOrWhiteSpace([string]$v)) { return [string]$v }
        }
    }
    return ''
}

function Get-RunProp {
    param($Run, [string] $Name)
    if ($Run.PSObject.Properties.Name -contains $Name) { return $Run.$Name }
    return $null
}

function Test-RunIsDryRun {
    # Returns $true / $false / $null (unknown). The marker wins; the legacy verdict is the fallback.
    param($Run)
    $title = Get-RunTitle -Run $Run
    if ($title.Contains($script:DryRunMarker)) { return $true }
    if ($title.Contains($script:ProducingMarker)) { return $false }
    $legacy = Get-RunProp -Run $Run -Name 'legacyIsDryRun'
    if ($null -ne $legacy -and $legacy -is [bool]) { return [bool]$legacy }
    return $null
}

function Get-RunTargetCommit {
    # The commit a run was aimed at: the run-name's `target=` field when it names a real sha,
    # otherwise (target=HEAD, i.e. a blank commit input) the run's own head_sha.
    param($Run)
    $title = Get-RunTitle -Run $Run
    $m = [regex]::Match($title, 'target=([0-9a-fA-F]{7,40}|HEAD)')
    if ($m.Success -and $m.Groups[1].Value -ne 'HEAD') { return $m.Groups[1].Value.ToLowerInvariant() }
    $head = Get-RunProp -Run $Run -Name 'head_sha'
    if ($null -eq $head) { return '' }
    return ([string]$head).ToLowerInvariant()
}

function ConvertTo-Utc {
    param([string] $Value)
    return [datetime]::Parse(
        $Value, [cultureinfo]::InvariantCulture,
        ([System.Globalization.DateTimeStyles]::AdjustToUniversal -bor
         [System.Globalization.DateTimeStyles]::AssumeUniversal))
}

if (-not (Test-Path -LiteralPath $RunsJsonPath)) {
    throw "runs JSON not found at '$RunsJsonPath' -- refusing (a missing run list is not an empty one)."
}
$rawJson = Get-Content -LiteralPath $RunsJsonPath -Raw
if ([string]::IsNullOrWhiteSpace($rawJson)) {
    throw "runs JSON at '$RunsJsonPath' is empty -- refusing (cannot distinguish 'no runs' from 'no data')."
}
# THE 5.1 INGESTION TRAP. Windows PowerShell 5.1's ConvertFrom-Json does NOT enumerate a top-level
# JSON array -- it emits the whole object[] as ONE pipeline item -- so `@(ConvertFrom-Json ...)`
# wraps the entire run list in a 1-element array. Every field lookup below then runs against an
# object[], whose PSObject properties are Count/Length/Rank/..., so `id` and `conclusion` both read
# EMPTY and every run is rejected as a failed rehearsal regardless of its content. PowerShell 6+
# enumerates the array, which is why the pwsh legs never saw this.
# Assigning FIRST and wrapping second is correct on both hosts: the assignment collects 5.1's single
# array (becoming that array) and 7's N items alike, and @() re-normalizes a lone object to an array.
# The $null guard keeps a genuinely empty list empty on 7, where '[]' yields nothing and @($null)
# would otherwise manufacture one phantom run.
$parsed = ConvertFrom-Json $rawJson
$runs = @()
if ($null -ne $parsed) { $runs = @($parsed) }

$now = if ([string]::IsNullOrWhiteSpace($NowUtc)) { [datetime]::UtcNow } else { ConvertTo-Utc $NowUtc }
$cutoff = $now.AddDays(-[double]$WindowDays)
$target = $TargetCommit.ToLowerInvariant()

Write-Host ('  target commit   : ' + $target)
Write-Host ('  recency window  : ' + $WindowDays + ' day(s), so a dry run must be no older than ' +
    $cutoff.ToString('o') + ' (now ' + $now.ToString('o') + ')')
Write-Host ('  candidate runs  : ' + $runs.Count)

$match = $null
$rejected = @()

foreach ($run in $runs) {
    $id = [string](Get-RunProp -Run $run -Name 'id')
    $title = Get-RunTitle -Run $run
    $conclusion = [string](Get-RunProp -Run $run -Name 'conclusion')
    $createdRaw = [string](Get-RunProp -Run $run -Name 'created_at')

    # COMMIT IDENTITY IS THE QUESTION, so it is asked FIRST (dispatch 000217). Pairing asks exactly
    # one thing -- "is there a successful dry run for THIS target commit?" -- and answering that
    # before anything order- or time-dependent is what keeps the verdict independent of how many
    # unrelated runs have piled up since the rehearsal. The gate's scalability rests here: a run is
    # a candidate because of the commit it targeted, never because of where it sits in a list.
    # Moving this check first changes no verdict (every condition below is conjunctive); it changes
    # which reason is reported for a run that fails more than one, and reports the load-bearing one.
    $runTarget = Get-RunTargetCommit -Run $run
    if ($runTarget -ne $target) {
        $rejected += ('run ' + $id + ': dry run targeted ' + $runTarget + ', not ' + $target)
        continue
    }
    if ($conclusion -ne 'success') {
        $rejected += ('run ' + $id + ': conclusion=' + $conclusion + ' (a failed rehearsal is not a rehearsal)')
        continue
    }
    $isDry = Test-RunIsDryRun -Run $run
    if ($null -eq $isDry) {
        $rejected += ('run ' + $id + ': dry_run NOT DISCRIMINABLE from this run (no marker, no legacy verdict) -- "' + $title + '"')
        continue
    }
    if (-not $isDry) {
        $rejected += ('run ' + $id + ': was a PRODUCING run, not a dry run')
        continue
    }
    if ([string]::IsNullOrWhiteSpace($createdRaw)) {
        $rejected += ('run ' + $id + ': no created_at -- cannot place it in the window')
        continue
    }
    $created = ConvertTo-Utc $createdRaw
    if ($created -lt $cutoff) {
        $rejected += ('run ' + $id + ': dry run at ' + $created.ToString('o') + ' is OUTSIDE the ' +
            $WindowDays + '-day window')
        continue
    }
    $match = [pscustomobject]@{
        Id        = $id
        Title     = $title
        CreatedAt = $created.ToString('o')
        Target    = $runTarget
    }
    break
}

if ($null -ne $match) {
    Write-Host ''
    Write-Host '  MATCHED a successful dry run:'
    Write-Host ('    run id     : ' + $match.Id)
    Write-Host ('    run name   : ' + $match.Title)
    Write-Host ('    created    : ' + $match.CreatedAt)
    Write-Host ('    target     : ' + $match.Target)
    Write-Host ''
    Write-Host 'OK: the dry-run pair is satisfied.'
    exit 0
}

Write-Host ''
Write-Host '  No matching dry run. Every candidate was rejected, and why:'
if ($rejected.Count -eq 0) {
    Write-Host '    (there were no candidate runs at all)'
} else {
    foreach ($r in $rejected) { Write-Host ('    - ' + $r) }
}
Write-Host ''
Write-Host ('::error::no SUCCESSFUL dry_run=true run of this workflow exists for commit ' + $target +
    ' within ' + $WindowDays + ' day(s) -- refusing to produce a release that was never rehearsed. ' +
    'Re-run this workflow with dry_run=true on this exact commit first, or set skip_dry_check=true ' +
    'to record a deliberate bypass as a run parameter.')
exit 1
