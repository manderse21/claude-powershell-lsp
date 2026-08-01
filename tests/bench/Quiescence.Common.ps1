#Requires -Version 5.1

# Quiescence.Common.ps1 -- the host-quiescence measurement instrument (dispatch 000172, D4).
#
# WHY THIS FILE IS COMMITTED, AND NOT A SCRATCHPAD SCRIPT
# ------------------------------------------------------
# The latency-sweep gate needs the host to be quiet before a millisecond figure is publishable.
# That gate has now been built WRONG TWICE, once per train, because it was rebuilt from scratch
# each time in a scratchpad that does not survive:
#
#   * dispatch 000170 built a gate that could not exclude its own apparatus AT ALL, which makes
#     the gate unreachable by construction -- the measuring rig's own load counts against the
#     threshold it is being measured against.
#   * dispatch 000171 built one that excluded the apparatus AS OF A SINGLE INSTANT. The agent
#     process tree was resolved ONCE at probe start, so every process the agent host spawned
#     DURING the probe was misclassified as foreign load: 0.064 of the 0.3363 cores measured at
#     point P1, against a 0.15-core threshold. Enough to fail a gate on the apparatus's own noise.
#
# An instrument that is thrown away cannot accumulate the lesson that broke it. So it is committed,
# under tests/bench/ beside the other instruments, and the lesson is encoded as behavior:
#
#   THE EXCLUSION IS RE-RESOLVED FOR EVERY SAMPLE. The parent map is rebuilt and each observed
#   process's ancestry is walked at SCORING time, so a process spawned mid-probe is classified by
#   what it actually descends from, not by a snapshot taken before it existed.
#
# DISCOVERY: this is an INSTRUMENT, not a test. It follows the convention already established by
# Benchmark.Common.ps1 and Invoke-LatencyBench.ps1 in this same directory -- Pester's default
# discovery matches *.Tests.ps1 only, and tests/run-tests.ps1 points Run.Path at tests/ with that
# default, so a file not named *.Tests.ps1 is never collected. Its behavior is tested from
# tests/PowerShellLsp.Benchmark.Tests.ps1. Defines functions only; ASCII-only.

# The gate threshold, in CORES of sustained foreign load. NOT changed by dispatch 000172 --
# 000171's measurements were taken against this value and moving it would invalidate the
# comparison and quietly convert a failed gate into a passed one.
$script:QuiescenceThresholdCores = 0.15

function Get-QuiescenceThresholdCores {
    return $script:QuiescenceThresholdCores
}

function Get-ProcessParentMap {
    # Build a FRESH pid -> parent-pid map. Called once per sample, never cached: a cached map is
    # exactly the 000171 defect, because a process created after the cache was built has no entry
    # and therefore no ancestry, and anything without ancestry scores as foreign.
    #
    # Windows uses CIM; Linux and macOS use `ps`, which both carry. Returns a hashtable; an
    # unreadable process table yields an EMPTY map, and the caller treats that as a failed sample
    # rather than as "nothing is excluded" (see Measure-QuiescenceSample).
    $map = @{}
    $onWindows = if (Test-Path 'Variable:\IsWindows') { [bool]$IsWindows } else { $true }
    if ($onWindows) {
        try {
            foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId -ErrorAction Stop)) {
                $map[[int]$p.ProcessId] = [int]$p.ParentProcessId
            }
        } catch { return $map }
        return $map
    }
    # The NATIVE ps binary, named by absolute path on purpose: bare `ps` is a PowerShell ALIAS for
    # Get-Process on every host, so `& ps -A -o pid=,ppid=` would call the cmdlet with nonsense
    # parameters instead of the process-table utility. (Caught by this repo's own analyzer,
    # PSAvoidUsingCmdletAliases, while writing it.)
    $psExe = @('/bin/ps', '/usr/bin/ps') | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($psExe)) { return $map }
    try {
        # EAP is pinned to Continue for the native call: a native command writing to stderr under
        # -ErrorActionPreference Stop is a terminating RemoteException on Windows PowerShell 5.1.
        $eap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        # -A = every process; the trailing '=' on each column suppresses the header.
        $lines = @(& $psExe -A -o pid=,ppid= 2>$null)
        $ErrorActionPreference = $eap
        foreach ($line in $lines) {
            $t = ([string]$line).Trim() -split '\s+'
            if ($t.Count -ge 2) {
                $childPid = 0; $parentPid = 0
                if ([int]::TryParse($t[0], [ref]$childPid) -and [int]::TryParse($t[1], [ref]$parentPid)) {
                    $map[$childPid] = $parentPid
                }
            }
        }
    } catch { return $map }
    return $map
}

function Get-ProcessTreePids {
    # The DESCENDANT CLOSURE of $RootPids under $ParentMap, roots included. Resolution is by
    # walking each live process's ancestry UP to a root, which is what makes a mid-probe child
    # excludable: it is classified by where it came from, not by when the set was built.
    #
    # Depth is bounded so a cyclic or self-parented entry in a torn process table cannot spin.
    param([int[]] $RootPids, [hashtable] $ParentMap)
    $roots = @{}
    foreach ($r in @($RootPids)) { if ($r -gt 0) { $roots[[int]$r] = $true } }
    # NOTE: these return a plain @() with NO unary comma. The comma operator is what stops a
    # returned array unrolling, but EVERY caller here already wraps the call in @(), so a comma
    # would hand them an array containing the array and every [int] cast downstream would die on
    # an Object[]. (It did, first run.)
    $out = @{}
    foreach ($r in $roots.Keys) { $out[[int]$r] = $true }
    if ($null -eq $ParentMap) { return @(@($out.Keys) | Sort-Object) }

    foreach ($candidate in @($ParentMap.Keys)) {
        $cur = [int]$candidate
        $depth = 0
        while ($cur -gt 0 -and $depth -lt 64) {
            if ($roots.ContainsKey($cur)) { $out[[int]$candidate] = $true; break }
            if (-not $ParentMap.ContainsKey($cur)) { break }
            $next = [int]$ParentMap[$cur]
            if ($next -eq $cur) { break }   # self-parented: a torn read, not a real ancestry
            $cur = $next
            $depth++
        }
    }
    return @(@($out.Keys) | Sort-Object)
}

function Resolve-QuiescenceExclusion {
    # RE-RESOLVE both excluded process trees, right now. This is the whole fix: callers invoke it
    # once per sample rather than once per probe.
    #
    #   AgentPids -- the agent host's tree (the Claude Code session driving the work). Its
    #                descendants are apparatus: shells, hooks, analyzers it spawns mid-probe.
    #   ProbePids -- this probe's own tree. A measurement rig must not measure itself.
    #
    # BOTH sets are returned in full and are printed by the probe, so the exclusion stays
    # auditable: a reader can see exactly which pids were removed and challenge any of them.
    param([int] $AgentRootPid, [int] $ProbeRootPid = $PID, [hashtable] $ParentMap)
    $map = if ($null -ne $ParentMap) { $ParentMap } else { Get-ProcessParentMap }
    $agent = @()
    if ($AgentRootPid -gt 0) { $agent = @(Get-ProcessTreePids -RootPids @($AgentRootPid) -ParentMap $map) }
    $probe = @(Get-ProcessTreePids -RootPids @($ProbeRootPid) -ParentMap $map)
    $union = @{}
    foreach ($p in @($agent) + @($probe)) { $union[[int]$p] = $true }
    return [pscustomobject]@{
        AgentRootPid = [int]$AgentRootPid
        ProbeRootPid = [int]$ProbeRootPid
        AgentPids    = @($agent)
        ProbePids    = @($probe)
        ExcludedPids = @(@($union.Keys) | Sort-Object)
        MapSize      = $map.Count
        ResolvedAt   = ([datetime]::UtcNow.ToString('o'))
    }
}

function Get-ProcessCpuSnapshot {
    # pid -> total processor SECONDS consumed so far, for every readable process. A process that
    # exits between enumeration and read is skipped rather than fatal -- that is normal churn on a
    # live host, not an error.
    $snap = @{}
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        try { $snap[[int]$p.Id] = [double]$p.TotalProcessorTime.TotalSeconds } catch { }
    }
    return $snap
}

function Measure-QuiescenceSample {
    # ONE sample of FOREIGN cpu load, in cores.
    #
    # Foreign load is the CPU consumed over the interval by every process that is NOT in the
    # freshly-resolved exclusion, divided by the wall time and reported in cores (1.0 = one logical
    # core saturated). The agent's own draw is reported ALONGSIDE rather than folded in, so a
    # reader can see how much was excluded and judge whether the exclusion was fair.
    #
    # The exclusion is resolved AFTER the interval, against a parent map rebuilt at that moment, so
    # a process created during the interval is scored by its real ancestry (dispatch 000172, D4).
    param([int] $AgentRootPid, [int] $ProbeRootPid = $PID, [int] $IntervalMs = 1000)
    $before = Get-ProcessCpuSnapshot
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Milliseconds $IntervalMs
    $sw.Stop()
    $after = Get-ProcessCpuSnapshot

    $map = Get-ProcessParentMap
    $excl = Resolve-QuiescenceExclusion -AgentRootPid $AgentRootPid -ProbeRootPid $ProbeRootPid -ParentMap $map
    $excluded = @{}
    foreach ($p in @($excl.ExcludedPids)) { $excluded[[int]$p] = $true }
    $agentOnly = @{}
    foreach ($p in @($excl.AgentPids)) { $agentOnly[[int]$p] = $true }

    $elapsed = [double]$sw.Elapsed.TotalSeconds
    if ($elapsed -le 0) { $elapsed = [double]$IntervalMs / 1000.0 }

    $foreignSec = 0.0; $agentSec = 0.0
    $topForeign = @{}
    foreach ($k in @($after.Keys)) {
        $endSec = [double]$after[$k]
        $startSec = if ($before.ContainsKey($k)) { [double]$before[$k] } else { 0.0 }
        $delta = $endSec - $startSec
        # A negative delta means pid reuse inside the interval -- a different process now wears
        # that id. Discard rather than subtract, which would understate real load.
        if ($delta -le 0) { continue }
        if ($excluded.ContainsKey([int]$k)) {
            if ($agentOnly.ContainsKey([int]$k)) { $agentSec += $delta }
            continue
        }
        $foreignSec += $delta
        $topForeign[[int]$k] = $delta
    }

    $top = @(@($topForeign.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 5) |
            ForEach-Object { [pscustomobject]@{ ProcessId = [int]$_.Key; Cores = [math]::Round(([double]$_.Value / $elapsed), 4) } })

    return [pscustomobject]@{
        ForeignCores = [math]::Round(($foreignSec / $elapsed), 4)
        AgentCores   = [math]::Round(($agentSec / $elapsed), 4)
        ElapsedSec   = [math]::Round($elapsed, 3)
        Exclusion    = $excl
        TopForeign   = @($top)
        # A sample taken against an EMPTY parent map excluded nothing but the roots, so it cannot
        # be trusted -- surfaced rather than silently averaged in.
        MapReadable  = ([int]$excl.MapSize -gt 0)
    }
}
