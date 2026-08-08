#Requires -Version 5.1

<#
.SYNOPSIS
    Per-profile latency, cold-start, finding-count and additionalContext-byte sweep
    across the three shipped profiles (dispatch 000197 leg 4, executed under 000207).

.DESCRIPTION
    Invoke-LatencyBench.ps1 answers "how fast is the warm path?" for ONE configuration --
    whatever the ambient environment happens to resolve to. This script answers a
    different question: what does CHOOSING a profile cost, and what does it buy?

    ONE PROFILE PER INVOCATION, deliberately. A profile is read from the process
    environment by every hook the harness spawns, so sweeping all three inside one
    process would mean mutating that environment between phases and hoping no daemon
    outlived the change. A profile per process makes the environment immutable for the
    life of the measurement, and it keeps a single run inside a sane wall-clock.

    WHAT IS MEASURED, all against the REAL daemon over the REAL pipe:

      (1) COLD START -- SessionStart hook invoked to the per-session daemon reaching
          'ready', a fresh daemon per iteration, torn down after each. This is the
          per-session spin-up a user pays once.
      (2) WARM PATH -- one edit to diagnostic round-trip against an already-warm daemon,
          a real content change per iteration so a fresh analysis is timed. Cold start is
          EXCLUDED here by construction: the daemon is up and primed before timing.
      (3) FINDING COUNT + additionalContext BYTES -- the dirty fixture analyzed to a
          settled pass, with the rendered context measured as the model would receive it.

    THE NON-VACUITY FLOOR. Phase 3 THROWS when the finding count is zero. Zero findings
    would make the byte figure a measurement of the empty string, and an empty string is
    equally "small" under all three profiles -- a per-profile comparison built on it would
    show a clean, symmetric, meaningless result. The floor is what makes the byte number a
    claim rather than a shape.

    PATH BYTES ARE HELD CONSTANT ACROSS PROFILES. The rendered context embeds the analyzed
    file's absolute path, so a scratch file under a per-run temp root would make the byte
    totals differ by the length of a GUID rather than by anything about the profile. The
    scratch directory is therefore a FIXED, deterministic path (see -ScratchDir) shared by
    every profile, and the byte deltas between profiles are surface deltas only.

    REPORT-ONLY. It measures, prints, and optionally writes JSON. It publishes nothing.

.PARAMETER ProfileName
    Which profile to sweep: safe, recommended, or strict. The parameter is ProfileName
    rather than Profile because $Profile is a PowerShell AUTOMATIC variable and binding it
    is PSAvoidAssignmentToAutomaticVariable.

.PARAMETER ColdIterations
    Cold-start samples. Default 10, which is the acceptance floor; each costs a full
    daemon spin-up and teardown, so this is the expensive phase.

.PARAMETER WarmIterations
    Warm-path samples. Default 20. Above the floor on purpose: p95 here is NEAREST-RANK,
    so at n=10 the p95 IS the observed maximum and carries no information the max does not
    already carry. At n=20 it is the 19th of 20 ordered samples.

.PARAMETER JsonPath
    Write the structured result here (UTF-8, no BOM). Empty = stdout summary only.

.PARAMETER DataRoot
    Daemon/session state root. Default: a throwaway temp dir, so a run never touches a
    live session's daemon state.

.PARAMETER ScratchDir
    Where the analyzed scratch files live. Default is a FIXED temp path, not a per-run
    one -- see the path-bytes note above. Override only if you accept that the byte
    figures stop being comparable with the ones recorded in docs/benchmarks.md.

.EXAMPLE
    pwsh -NoProfile -File tests/bench/Invoke-ProfileSweep.ps1 -ProfileName safe

.EXAMPLE
    pwsh -NoProfile -File tests/bench/Invoke-ProfileSweep.ps1 -ProfileName strict `
        -JsonPath sweep-strict.json

.NOTES
    Instrument, not a test: Pester discovers *.Tests.ps1 only, matching the convention
    already used by Invoke-LatencyBench.ps1 and Invoke-QuiescenceProbe.ps1 in this
    directory. ASCII-only; StrictMode-safe.

    EXIT CODES: 0 = swept, 4 = the daemon never reached ready (nothing measured),
    5 = the non-vacuity floor failed (the dirty fixture produced no findings).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('safe', 'recommended', 'strict')]
    [string] $ProfileName,

    [int] $ColdIterations = 10,
    [int] $WarmIterations = 20,
    [string] $JsonPath = '',
    [string] $DataRoot = '',
    [string] $ScratchDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Benchmark.Common.ps1')

$paths = Get-BenchPaths
$scriptsDir = $paths.ScriptsDir
$dirtyFixture = Join-Path $PSScriptRoot 'bench-fixture-findings.ps1'
if (-not (Test-Path -LiteralPath $dirtyFixture)) {
    throw ('the findings fixture is missing: ' + $dirtyFixture)
}

if ([string]::IsNullOrWhiteSpace($DataRoot)) {
    $DataRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
    ('psls-profile-sweep-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
}
New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null

# FIXED, NOT PER-RUN. The analyzed path is embedded in the rendered context, so this is
# what keeps the byte totals comparable between profiles. See the .DESCRIPTION note.
if ([string]::IsNullOrWhiteSpace($ScratchDir)) {
    $ScratchDir = Join-Path ([System.IO.Path]::GetTempPath()) 'psls-profile-sweep-scratch'
}
New-Item -ItemType Directory -Force -Path $ScratchDir | Out-Null

# THE PROFILE RIDES THE PROCESS ENVIRONMENT. Invoke-BenchHook starts each hook with
# UseShellExecute = false, which seeds the child's environment from this process, so the
# daemon and the client both resolve the same profile without a harness change.
$env:CLAUDE_PLUGIN_OPTION_profile = $ProfileName
$env:CLAUDE_PLUGIN_DATA = $DataRoot

# WHAT THE PROFILE ACTUALLY TURNED ON, resolved in-process through the SAME
# Get-PluginOption the hooks call. Printed rather than described: a sweep whose profile
# silently failed to resolve would otherwise report three identical columns and read as
# "the profiles do not differ" instead of "the profile was never applied."
$resolved = [ordered]@{
    profile            = (Get-PluginOption 'profile' 'safe')
    ruleset            = (Get-PluginOption 'ruleset' '')
    perFileCap         = (Get-PluginOption 'perFileCap' '20')
    formatOnEdit       = (Get-PluginOption 'formatOnEdit' 'off')
    referenceSurfacing = (Get-PluginOption 'referenceSurfacing' 'off')
    moduleAwareness    = (Get-PluginOption 'moduleAwareness' 'off')
    scopeToEdit        = (Get-PluginOption 'scopeToEdit' 'true')
    editContextLines   = (Get-PluginOption 'editContextLines' '0')
    keepLastN          = (Get-PluginOption 'keepLastN' '')
}

Write-Host ('[sweep] profile    : ' + $ProfileName)
Write-Host ('[sweep] data root  : ' + $DataRoot)
Write-Host ('[sweep] scratch    : ' + $ScratchDir)
Write-Host ('[sweep] iterations : cold ' + $ColdIterations + ' / warm ' + $WarmIterations)
Write-Host '[sweep] resolved knobs under this profile:'
foreach ($k in $resolved.Keys) {
    $v = [string]$resolved[$k]
    if ([string]::IsNullOrWhiteSpace($v)) { $v = '(shipped default)' }
    Write-Host ('    {0,-19}: {1}' -f $k, $v)
}

Write-Host '[sweep] bootstrapping PSES + pinned PSScriptAnalyzer (NOT timed)...'
foreach ($boot in @('ensure-pses.ps1', 'ensure-pssa.ps1')) {
    & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsDir $boot) 2>&1 |
        Out-Null
}

$enc = New-Object System.Text.UTF8Encoding($false)

# --- (1) COLD START -------------------------------------------------------------------
Write-Host ('[sweep] measuring cold start x ' + $ColdIterations + ' (fresh daemon each)...')
$coldSamples = New-Object System.Collections.Generic.List[int]
for ($i = 0; $i -lt $ColdIterations; $i++) {
    $sid = 'sweep-cold-' + $ProfileName + '-' + $i
    $ms = Measure-BenchColdStartMs -ScriptsDir $scriptsDir -DataRoot $DataRoot -SessionId $sid
    $coldSamples.Add([int]$ms)
    Write-Host ('    cold {0,3}: {1} ms' -f ($i + 1), $ms)
}

# --- bring up ONE warm daemon for phases (2) and (3) ----------------------------------
$sid = 'sweep-warm-' + $ProfileName
$sessionFile = Join-Path $DataRoot ('session/' + $sid + '.json')
Write-Host '[sweep] starting the warm daemon and waiting for ready (NOT timed)...'
Invoke-BenchHook -ScriptPath (Join-Path $scriptsDir 'session-start.ps1') `
    -StdinJson (@{ session_id = $sid } | ConvertTo-Json -Compress) `
    -ExtraArgs @('-PreferredHost', 'pwsh') -CapMs 60000 -DataRoot $DataRoot | Out-Null

$daemon = $null
for ($i = 0; $i -lt 200; $i++) {
    if (Test-Path -LiteralPath $sessionFile) {
        $probe = Read-BenchSessionFile -Path $sessionFile
        if ($probe.State -eq 'ready') { $daemon = $probe.Info; break }
    }
    Start-Sleep -Milliseconds 100
}
if ($null -eq $daemon) {
    # Never fabricate a number: no daemon means nothing was measured.
    Write-Error ('[sweep] the daemon never reached ready; NOTHING was measured. See ' +
        (Join-Path $DataRoot 'logs'))
    exit 4
}
Write-Host '[sweep] daemon ready.'

$warmSamples = New-Object System.Collections.Generic.List[int]
$findingCount = -1
$cappedOmitted = 0
$contextBytes = -1
$contextChars = -1
$contextAttempts = 0
$contextHead = ''
# The VERBATIM rendered context, carried in the JSON only (never echoed to stdout, which
# would bury the summary). A byte total without the text it counts is a number nobody can
# audit: the delta between two profiles is only explicable from the sections themselves.
$contextFull = ''

try {
    # --- (2) WARM PATH ----------------------------------------------------------------
    $warmFile = Join-Path $ScratchDir 'warm-edit.ps1'
    Set-Content -LiteralPath $warmFile -Value (Get-Content -LiteralPath $paths.FixturePath -Raw) `
        -Encoding ascii
    Write-Host '[sweep] priming the warm path (first analysis of this file, discarded)...'
    Measure-BenchWarmPathMs -ScriptsDir $scriptsDir -DataRoot $DataRoot -SessionId $sid `
        -ScratchFile $warmFile | Out-Null

    Write-Host ('[sweep] measuring warm path x ' + $WarmIterations + '...')
    for ($i = 0; $i -lt $WarmIterations; $i++) {
        # A real content change each iteration -> a fresh analysis, never a cache hit.
        Add-Content -LiteralPath $warmFile -Value ('# edit ' + $i) -Encoding ascii
        $ms = Measure-BenchWarmPathMs -ScriptsDir $scriptsDir -DataRoot $DataRoot -SessionId $sid `
            -ScratchFile $warmFile
        $warmSamples.Add([int]$ms)
        if ((($i + 1) % 5) -eq 0) { Write-Host ('    ...' + ($i + 1) + '/' + $WarmIterations) }
    }

    # --- (3) FINDING COUNT + additionalContext BYTES ----------------------------------
    # The dirty fixture is written ONCE and never mutated, so the analyzed bytes -- and the
    # path embedded in the rendered context -- are identical on every attempt and across
    # every profile. Attempts exist because the FIRST pass after a file appears can settle
    # as 'incomplete'; they never change the input.
    $dirtyFile = Join-Path $ScratchDir 'findings-fixture.ps1'
    Set-Content -LiteralPath $dirtyFile -Value (Get-Content -LiteralPath $dirtyFixture -Raw) `
        -Encoding ascii
    $stdin = (@{
            session_id = $sid
            tool_input = @{ file_path = $dirtyFile }
            cwd        = $ScratchDir
        } | ConvertTo-Json -Compress)

    Write-Host '[sweep] analyzing the findings fixture to a settled pass...'
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        $contextAttempts = $attempt
        $out = Invoke-BenchHook -ScriptPath (Join-Path $scriptsDir 'lsp-client.ps1') `
            -StdinJson $stdin -CapMs 30000 -DataRoot $DataRoot `
            -ExtraEnv @{
            CLAUDE_PLUGIN_OPTION_timeoutMs = '18000'
            CLAUDE_PLUGIN_OPTION_profile   = $ProfileName
        }
        $ctx = ''
        if (-not [string]::IsNullOrWhiteSpace($out)) {
            $parsed = $null
            try { $parsed = $out | ConvertFrom-Json -ErrorAction Stop } catch { $parsed = $null }
            $hookOut = Get-BenchProp $parsed 'hookSpecificOutput'
            $ctxVal = Get-BenchProp $hookOut 'additionalContext'
            if ($null -ne $ctxVal) { $ctx = [string]$ctxVal }
        }
        $m = [regex]::Match($ctx, '(?m)^PowerShell diagnostics \((\d+)\) for ')
        if ($m.Success) {
            $findingCount = [int]$m.Groups[1].Value
            $capMatch = [regex]::Match($ctx, '(?m)^\s*\.\.\. and (\d+) more \(per-file cap\)')
            if ($capMatch.Success) { $cappedOmitted = [int]$capMatch.Groups[1].Value }
            $contextBytes = [System.Text.Encoding]::UTF8.GetByteCount($ctx)
            $contextChars = $ctx.Length
            $contextHead = @($ctx -split "`r?`n")[0]
            $contextFull = $ctx
            break
        }
        Start-Sleep -Milliseconds 400
    }
} finally {
    Write-Host '[sweep] tearing the daemon down...'
    try {
        Invoke-BenchHook -ScriptPath (Join-Path $scriptsDir 'session-end.ps1') `
            -StdinJson (@{ session_id = $sid } | ConvertTo-Json -Compress) `
            -ExtraArgs @() -CapMs 8000 -DataRoot $DataRoot | Out-Null
    } catch { }
    foreach ($pidVal in @((Get-BenchProp $daemon 'pid'), (Get-BenchProp $daemon 'psesPid'))) {
        if ($pidVal) { Stop-Process -Id $pidVal -Force -ErrorAction SilentlyContinue }
    }
}

$coldStats = Get-BenchStats -Values $coldSamples.ToArray()
$warmStats = Get-BenchStats -Values $warmSamples.ToArray()

$platform = if (Test-Path 'Variable:\IsWindows') {
    if ($IsWindows) { 'windows' } elseif ($IsLinux) { 'linux' } elseif ($IsMacOS) { 'macos' }
    else { 'other' }
} else { 'windows' }

$result = [ordered]@{
    schema             = 'powershell-lsp-profile-sweep/1'
    profile            = $ProfileName
    resolvedKnobs      = $resolved
    host               = ('pwsh ' + $PSVersionTable.PSVersion.ToString())
    platform           = $platform
    processorCount     = [System.Environment]::ProcessorCount
    coldIterations     = $ColdIterations
    warmIterations     = $WarmIterations
    meetsSampleFloor   = (($ColdIterations -ge 10) -and ($WarmIterations -ge 10))
    coldStart          = $coldStats
    warmPath           = $warmStats
    findingCount       = $findingCount
    cappedOmitted      = $cappedOmitted
    contextBytes       = $contextBytes
    contextChars       = $contextChars
    contextAttempts    = $contextAttempts
    contextHeaderLine  = $contextHead
    contextText        = $contextFull
    analyzedScratchDir = $ScratchDir
}

Write-Host ''
Write-Host '================ PER-PROFILE SWEEP ================'
Write-Host ('profile          : ' + $ProfileName + '   (ruleset ' +
    $(if ([string]::IsNullOrWhiteSpace([string]$resolved.ruleset)) { '(default set)' }
        else { [string]$resolved.ruleset }) + ')')
Write-Host ('host             : ' + $result.host + ' / ' + $platform + ' / ' +
    $result.processorCount + ' logical cores')
Write-Host ('cold start       : median ' + (Format-BenchStatValue $coldStats 'medianMs') +
    ' ms   p95 ' + (Format-BenchStatValue $coldStats 'p95Ms') + ' ms   [min ' +
    (Format-BenchStatValue $coldStats 'minMs') + ' / max ' +
    (Format-BenchStatValue $coldStats 'maxMs') + ']   n=' +
    (Format-BenchStatValue $coldStats 'count'))
Write-Host ('warm path        : median ' + (Format-BenchStatValue $warmStats 'medianMs') +
    ' ms   p95 ' + (Format-BenchStatValue $warmStats 'p95Ms') + ' ms   [min ' +
    (Format-BenchStatValue $warmStats 'minMs') + ' / max ' +
    (Format-BenchStatValue $warmStats 'maxMs') + ']   n=' +
    (Format-BenchStatValue $warmStats 'count'))
Write-Host ('findings         : ' + $findingCount + ' rendered' +
    $(if ($cappedOmitted -gt 0) { ' (+' + $cappedOmitted + ' omitted by the per-file cap)' }
        else { '' }) + '   [settled on attempt ' + $contextAttempts + ']')
Write-Host ('additionalContext: ' + $contextBytes + ' bytes / ' + $contextChars + ' chars')
Write-Host '==================================================='

if (-not [string]::IsNullOrWhiteSpace($JsonPath)) {
    [System.IO.File]::WriteAllText($JsonPath, (($result | ConvertTo-Json -Depth 8) + "`n"), $enc)
    Write-Host ('[sweep] wrote ' + $JsonPath)
}

# THE NON-VACUITY FLOOR, asserted LAST so the numbers above are still reported when it
# trips. Zero findings makes the byte figure a measurement of the empty string, which is
# equally small under every profile -- the comparison would look clean and mean nothing.
if ($findingCount -le 0) {
    Write-Error ('[sweep] NON-VACUITY FLOOR FAILED: the findings fixture rendered ' +
        $findingCount + ' findings under profile ' + $ProfileName + '. The byte figure ' +
        'above describes an empty context and must NOT be published as a profile ' +
        'comparison.')
    exit 5
}

exit 0
