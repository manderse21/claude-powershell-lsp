#Requires -Version 5.1

<#
.SYNOPSIS
    Measure sustained FOREIGN cpu load on this host and report it against the quiescence gate.

.DESCRIPTION
    The gate a latency sweep must clear before any millisecond figure it produces is publishable.
    Timing is load-sensitive; a latency measured on a busy host is a wrong number, and a wrong
    latency is worse than none because it gets published.

    Foreign load is everything NOT in the freshly-resolved exclusion: the agent host's process
    tree (apparatus) and this probe's own tree (a rig must not measure itself). Both excluded pid
    sets are PRINTED IN FULL so the exclusion is auditable rather than asserted.

    THE EXCLUSION IS RE-RESOLVED FOR EVERY SAMPLE. Dispatch 000171 resolved it once at probe start
    and consequently scored every process the agent spawned mid-probe as foreign -- 0.064 of the
    0.3363 cores it measured at point P1, against a 0.15-core threshold. See the header of
    Quiescence.Common.ps1 for the full history; this script exists so that lesson stops being
    rebuilt from scratch, and wrong, once per train.

    REPORT-ONLY. It measures and prints a verdict. It changes nothing, and it does not itself run
    a sweep.

.PARAMETER AgentRootPid
    Root pid of the agent host whose tree is apparatus. Defaults to this process's PARENT, which
    is the agent when the probe is launched by one. Pass 0 to exclude nothing but the probe.

.PARAMETER Samples
    Number of samples to take. Default 30.

.PARAMETER IntervalMs
    Wall time per sample, in milliseconds. Default 1000.

.PARAMETER Label
    A name for this measurement point (e.g. P0, 'after strict'), echoed into the output so a
    series of probes is readable as a series.

.PARAMETER BusyProbeCommand
    A caller-supplied command line, run BEFORE any sampling, that answers one question: is this
    host busy with work the probe must not measure across? The contract is deliberately minimal,
    so the probe stays generic and this script never learns anything about the caller's world:

        QUIET -- exit code 0 AND no output.
        BUSY  -- a non-zero exit code, OR one or more busy-signal lines of output.

    On BUSY the probe REFUSES to sample, names the refusal, and exits 3. On QUIET it samples as
    usual. EITHER WAY the command and its raw output are recorded in the report beside the
    samples, so a reader can audit what 'quiet' actually meant for a given run rather than
    taking the word 'quiet' on trust.

    FAIL-CLOSED: a pre-flight that cannot be run at all (an unparseable command line, a missing
    executable) counts as BUSY. A quiescence guard that silently permits sampling when it breaks
    is worse than no guard, because it reports as though it checked.

    When this parameter is absent, no pre-flight runs and the report carries no pre-flight
    section -- behavior is exactly what it was before the parameter existed.

.EXAMPLE
    pwsh -NoProfile -File tests/bench/Invoke-QuiescenceProbe.ps1 -Label P0

.EXAMPLE
    # LOCAL EXAMPLE (Mike Andersen's strategic-dispatch hub) -- shown here rather than built in,
    # because this script is public and must not depend on any particular caller's tooling.
    # `dispatch claims --live` prints 'no claims match.' when the registry is empty, so the
    # example filters that line out to meet the no-output-means-quiet contract:
    #
    #   -BusyProbeCommand "@(dispatch claims --live) -notmatch 'no claims match' -notmatch '^\s*$'"
    #
    # Any equivalent works: the probe only reads the exit code and whether anything was emitted.

.NOTES
    Instrument, not a test: Pester discovers *.Tests.ps1 only, matching the convention already
    used by Invoke-LatencyBench.ps1 in this directory. Its behavior is tested from
    tests/PowerShellLsp.Benchmark.Tests.ps1. ASCII-only.

    EXIT CODES: 0 = PASS, 1 = FAIL (verdict), 2 = no samples taken, 3 = refused, host BUSY.
#>
[CmdletBinding()]
param(
    [int] $AgentRootPid = -1,
    [int] $Samples = 30,
    [int] $IntervalMs = 1000,
    [string] $Label = '',
    [string] $BusyProbeCommand = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Quiescence.Common.ps1')

# THE BOOT MAP IS RESOLVED UNCONDITIONALLY, because the ancestry-chain walk below reads it on
# EVERY path while the defaulting branch that used to assign it runs on ONE. Under the
# Set-StrictMode -Version Latest this script sets, both documented explicit forms --
# -AgentRootPid <pid> and the documented -AgentRootPid 0 -- therefore died with "The variable
# '$bootMap' cannot be retrieved because it has not been set" BEFORE taking a single sample, so
# the only invocation that ran was the default one, whose fallback root is the launching shell
# rather than the agent session (see the chain note below). Dispatch 000195 measured that; 000197
# repairs it.
#
# This does NOT move what the gate measures. The map is used for exactly two things -- picking the
# default ROOT pid, and printing the auditable ancestry chain -- and neither feeds scoring:
# Measure-QuiescenceSample builds its OWN fresh map per sample. On the default path the same
# function is called the same number of times (once) for the same value, so that path is
# unchanged; the explicit paths go from crashing to working.
$bootMap = Get-ProcessParentMap

# Default the agent root to this process's parent: when a probe is launched BY the agent, the
# agent is the parent, and its whole tree is apparatus. Resolved once here only to pick the ROOT;
# the tree BELOW that root is re-resolved per sample, which is the part that matters.
if ($AgentRootPid -lt 0) {
    $AgentRootPid = if ($bootMap.ContainsKey([int]$PID)) { [int]$bootMap[[int]$PID] } else { 0 }
}

# THE ANCESTRY CHAIN, printed so the chosen root is auditable rather than assumed.
#
# The default root is this process's PARENT, which is right when the agent launched the probe
# directly and WRONG when it launched it through a shell or tool process: the root then names only
# the launching link, and the agent's SIBLING processes score as foreign. Measured while building
# this: a default run rooted at the launching pwsh and two `claude` processes promptly appeared at
# the top of the foreign list, contributing ~0.18 cores against a 0.15-core threshold.
#
# The chain below is what makes that visible and fixable -- read it, pick the pid that really is
# the agent session, and pass it as -AgentRootPid. This is deliberately NOT auto-widened: an
# exclusion that climbed to the login session would swallow everything and make the gate
# unfailable, which is 000170's defect wearing the opposite sign.
$chain = @()
$walk = [int]$PID
for ($d = 0; $d -lt 24; $d++) {
    $nm = try { (Get-Process -Id $walk -ErrorAction Stop).ProcessName } catch { '(exited)' }
    $chain += ('{0} ({1})' -f $walk, $nm)
    if (-not $bootMap.ContainsKey($walk)) { break }
    $next = [int]$bootMap[$walk]
    if ($next -le 0 -or $next -eq $walk) { break }
    $walk = $next
}

# THE QUIET PRE-FLIGHT, run BEFORE any sampling.
#
# Three trains in a row measured this host while it was busy and published, or nearly published,
# a latency taken under load. The rail that prevents it was written into charter prose each time,
# and each time the next charter did not read it. So it lives in the INSTRUMENT now: a caller
# hands the probe a way to ask "is anything else running?", and the probe refuses to sample when
# the answer is yes.
#
# The probe stays generic on purpose. It does not know what a claim, a runner, or a dispatch is;
# it knows an exit code and whether anything was emitted. The caller's specific busy check is the
# caller's business and lives in the comment-based help above as a local example only -- this
# script is public and must carry no dependency on any one caller's tooling.
$preflightRan = $false
$preflightBusy = $false
$preflightExit = 0
$preflightOut = ''
$preflightError = ''

if (-not [string]::IsNullOrWhiteSpace($BusyProbeCommand)) {
    $preflightRan = $true
    try {
        # PARSE FIRST, so a command line that cannot possibly run is refused without spawning
        # anything. The scriptblock is built for validation only and is deliberately NOT invoked
        # here -- see below.
        $null = [scriptblock]::Create($BusyProbeCommand)

        # RUN IT IN A CHILD PROCESS, not in this one. A busy probe invoked in-process can call
        # `exit`, which terminates THIS script and makes the probe report the busy check's exit
        # code as its own -- the gate would then silently answer with something other than its own
        # verdict. A child process bounds the blast radius to an exit code and two streams, which
        # is exactly the contract the help text states.
        $hostExe = try { (Get-Process -Id $PID).Path } catch { '' }
        if ([string]::IsNullOrWhiteSpace($hostExe)) { $hostExe = 'pwsh' }

        # EAP pinned to Continue for the call, matching Get-ProcessParentMap's handling of the same
        # hazard: a native command writing to stderr under -ErrorActionPreference Stop is a
        # terminating RemoteException on Windows PowerShell 5.1, which would misreport a merely
        # chatty busy probe as a broken one.
        $eap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = 0
        $preflightOut = (& $hostExe -NoLogo -NoProfile -Command $BusyProbeCommand 2>&1 |
                Out-String -Width 500)
        $preflightExit = [int]$global:LASTEXITCODE
        $ErrorActionPreference = $eap
    } catch {
        # FAIL-CLOSED. A pre-flight that could not run has NOT established quiet.
        $preflightError = [string]$_.Exception.Message
        $preflightExit = -1
    }
    $preflightBusy = ($preflightExit -ne 0) -or (-not [string]::IsNullOrWhiteSpace($preflightOut))
}

$threshold = Get-QuiescenceThresholdCores
$cores = [int][System.Environment]::ProcessorCount

Write-Host '================ HOST QUIESCENCE PROBE (dispatch 000172, D4) ================'
if (-not [string]::IsNullOrWhiteSpace($Label)) { Write-Host ('point            : ' + $Label) }
Write-Host ('started at       : ' + ([datetime]::UtcNow.ToString('o')) + ' (UTC)')
Write-Host ('logical cores    : ' + $cores)
Write-Host ('samples          : ' + $Samples + ' x ' + $IntervalMs + ' ms')
Write-Host ('threshold        : ' + $threshold + ' cores of sustained FOREIGN load (unchanged since dispatch 000170)')
Write-Host ('agent root pid   : ' + $AgentRootPid + '   probe root pid: ' + $PID)
Write-Host ('ancestry chain   : ' + ($chain -join '  <-  '))
Write-Host '                   ^ if the agent session is HIGHER in this chain than the agent root'
Write-Host '                     above, re-run with -AgentRootPid <that pid>; otherwise the agent''s'
Write-Host '                     sibling processes will be counted as FOREIGN load.'

# THE PRE-FLIGHT RECORD, printed on BOTH paths. A gate that reports "quiet" without showing what
# it asked, and what came back, is asserting quiet rather than evidencing it.
if ($preflightRan) {
    Write-Host ''
    Write-Host '---------------- QUIET PRE-FLIGHT ----------------'
    Write-Host ('  busy probe      : ' + $BusyProbeCommand)
    Write-Host ('  exit code       : ' + $preflightExit)
    if (-not [string]::IsNullOrWhiteSpace($preflightError)) {
        Write-Host ('  probe error     : ' + $preflightError)
        Write-Host '  (a pre-flight that cannot run counts as BUSY -- fail-closed)'
    }
    if ([string]::IsNullOrWhiteSpace($preflightOut)) {
        Write-Host '  probe output    : (none)'
    } else {
        Write-Host '  probe output    :'
        foreach ($line in @(($preflightOut -split "`r?`n"))) {
            if (-not [string]::IsNullOrWhiteSpace($line)) { Write-Host ('    | ' + $line.TrimEnd()) }
        }
    }
    Write-Host ('  verdict         : ' + $(if ($preflightBusy) { 'BUSY' } else { 'QUIET' }))
} else {
    Write-Host ''
    Write-Host '  (no busy probe supplied -- pass -BusyProbeCommand to refuse sampling on a busy host)'
}

# THE REFUSAL. Before a single sample, because a sample taken across other work is the wrong
# number this whole instrument exists to stop being published.
if ($preflightBusy) {
    Write-Host ''
    Write-Host '---------------- REFUSED: HOST BUSY ----------------'
    Write-Host '  The busy probe reported activity, so NO SAMPLES WERE TAKEN and there is no'
    Write-Host '  verdict. This is not a FAIL and it is not a PASS -- the gate did not run.'
    Write-Host '  Quiesce the host and re-probe.'
    exit 3
}

Write-Host ''

$foreign = New-Object System.Collections.Generic.List[double]
$agent = New-Object System.Collections.Generic.List[double]
$unreadable = 0
$last = $null

for ($i = 1; $i -le $Samples; $i++) {
    $s = Measure-QuiescenceSample -AgentRootPid $AgentRootPid -ProbeRootPid $PID -IntervalMs $IntervalMs
    $last = $s
    if (-not $s.MapReadable) { $unreadable++ }
    $foreign.Add([double]$s.ForeignCores) | Out-Null
    $agent.Add([double]$s.AgentCores) | Out-Null
    Write-Host ('  sample {0,3}  foreign {1,8:N4} cores   agent {2,8:N4} cores   excluded {3,4} pids' -f `
            $i, $s.ForeignCores, $s.AgentCores, @($s.Exclusion.ExcludedPids).Count)
}

# SELECTED-COUNT FLOOR. A probe that took zero samples must not be able to report a verdict at
# all, let alone a passing one: a mean over an empty set is not a small number, it is no number.
if ($foreign.Count -eq 0) {
    Write-Host ''
    Write-Host 'NO SAMPLES TAKEN -- no verdict. This is not a PASS.'
    exit 2
}

$foreignArr = @($foreign.ToArray())
$agentArr = @($agent.ToArray())
$mean = ($foreignArr | Measure-Object -Average).Average
$max = ($foreignArr | Measure-Object -Maximum).Maximum
$agentMean = ($agentArr | Measure-Object -Average).Average

Write-Host ''
Write-Host '---------------- EXCLUSION (from the FINAL sample; re-resolved every sample) ----------------'
Write-Host ('  agent tree (' + @($last.Exclusion.AgentPids).Count + ' pids, root ' + $last.Exclusion.AgentRootPid + '):')
Write-Host ('    ' + ((@($last.Exclusion.AgentPids) | ForEach-Object { [string]$_ }) -join ' '))
Write-Host ('  probe tree (' + @($last.Exclusion.ProbePids).Count + ' pids, root ' + $last.Exclusion.ProbeRootPid + '):')
Write-Host ('    ' + ((@($last.Exclusion.ProbePids) | ForEach-Object { [string]$_ }) -join ' '))
Write-Host ('  process table entries seen in the final sample: ' + $last.Exclusion.MapSize)
if ($unreadable -gt 0) {
    Write-Host ('  WARNING: ' + $unreadable + ' of ' + $Samples + ' samples could not read the process table; ' +
        'their exclusion covered only the roots and their foreign figure is OVERSTATED.')
}

Write-Host ''
Write-Host '---------------- TOP FOREIGN CONSUMERS (final sample) ----------------'
foreach ($t in @($last.TopForeign)) {
    $name = try { (Get-Process -Id $t.ProcessId -ErrorAction Stop).ProcessName } catch { '(exited)' }
    Write-Host ('  {0,8} {1,-32} {2,8:N4} cores' -f $t.ProcessId, $name, $t.Cores)
}

$verdict = if ($mean -lt $threshold) { 'PASS' } else { 'FAIL' }
Write-Host ''
Write-Host ('---------------- VERDICT: ' + $verdict + ' ----------------')
Write-Host ('  foreign mean : {0:N4} cores   (threshold {1} -- must be strictly under)' -f $mean, $threshold)
Write-Host ('  foreign max  : {0:N4} cores' -f $max)
Write-Host ('  agent draw   : {0:N4} cores   (EXCLUDED from the figures above, reported so the exclusion is visible)' -f $agentMean)
Write-Host ('  samples      : ' + $foreignArr.Count)
if ($verdict -eq 'FAIL') {
    Write-Host '  The host is NOT quiet enough for a publishable latency figure. Quiesce and re-probe;'
    Write-Host '  do NOT publish millisecond numbers measured under this load.'
}

exit $(if ($verdict -eq 'PASS') { 0 } else { 1 })
