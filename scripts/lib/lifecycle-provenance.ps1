#Requires -Version 5.1

# lib/lifecycle-provenance.ps1 -- the READ side of the lifecycle sibling log: where to find it,
# how to parse it, and where its version-attributable knowledge BEGINS.
#
# WHY THIS FILE EXISTS (dispatch 000216). These five functions lived in
# scripts/rule-efficacy-ledger.ps1 and had exactly one consumer. Surfacing the provenance floor in
# the doctor and /status gave them a second, and a second consumer is what turns private helpers
# into a shared library. The alternative -- having doctor.ps1 dot-source the ledger -- is
# STRUCTURALLY FORBIDDEN here and rightly so: the ledger is an entry point carrying a param()
# block, and dot-sourcing a .ps1 runs its param() block in the CALLER's scope, silently rewriting
# the caller's variables. That is the 000156 defect, and tests/PowerShellLsp.LibPurity.Tests.ps1
# (G1) refuses it as an invariant with no baseline. It refused this, live, during 000216 -- after
# the same trap had already been hit by hand.
#
# The bodies are UNCHANGED by the move. No computation, no ruling, and no rendering differs: the
# floor is the same floor, derived the same way, from the same records. This file is a relocation
# so that ONE definition can serve both readers, which is the whole point -- the doctor readout and
# the efficacy ledger cannot disagree about the same log because there is nothing to disagree with.
#
# PURITY CONTRACT (G1). Functions only. No param() block, no top-level statement, no dot-source of
# its own -- a new top-level statement in a covered library is itself a test failure. That last
# constraint is why the prerequisite below is documented rather than enforced in code.
#
# PREREQUISITE: the caller must have dot-sourced lib/lsp-common.ps1 FIRST. These functions call
# Get-LogDir, Get-PluginDataRootResolution and Get-Prop from it. Both shipped consumers
# (scripts/doctor.ps1 and scripts/rule-efficacy-ledger.ps1) load it before this file.
#
# READ-ONLY, ABSOLUTELY. The only I/O here is Test-Path / Get-ChildItem / Get-Content. Nothing in
# this file writes, rotates, trims, or creates anything.
#
# Author: Mike Andersen / powershell-lsp plugin.

function Resolve-LifecycleLogPaths {
    # Resolve which lifecycle log(s) to read. A file is honored verbatim; a directory is scanned
    # for the lifecycle-*.jsonl rolling family. Default: the family in Get-LogDir.
    #
    # Returns @() when nothing is found -- which the caller renders as ABSENT, never as zeros.
    # Read-only: Test-Path / Get-ChildItem only.
    param([string] $LifecyclePath = '')
    return @((Resolve-LifecycleLogSearch -LifecyclePath $LifecyclePath).Paths)
}

function Resolve-LifecycleLogSearch {
    # Resolve the lifecycle log family AND report WHERE it searched and HOW that directory was
    # resolved (dispatch 000185, D1-B).
    #
    # THE DEFECT THIS CLOSES. Resolve-LifecycleLogPaths returns only paths. When it returned an
    # empty set the caller set Present=$false, and Get-LifecycleRates rendered 'absent' -- whose
    # documented meaning is "the signal was NEVER CAPTURED", a claim about THE WORLD. But the
    # default search directory is Get-LogDir, which derives from Get-PluginDataRoot, which in a
    # bare shell SILENTLY substitutes a temp fallback. So the world-claim was reachable on
    # evidence that only supported "I found no lifecycle file under the directory I happened to
    # resolve" -- a claim about THE READER. Nothing in the call chain carried the substitution.
    #
    # RootKnown is what closes it. It is $false only when the search fell back to Get-LogDir AND
    # the data root came from the temp fallback rather than from CLAUDE_PLUGIN_DATA. An EXPLICIT
    # -LifecyclePath is always Known: the caller named the directory, so a miss there really is
    # a miss, not a misdirection.
    #
    # Read-only: Test-Path / Get-ChildItem only.
    param([string] $LifecyclePath = '')
    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($LifecyclePath)) {
        if (Test-Path -LiteralPath $LifecyclePath -PathType Leaf) { $candidates.Add($LifecyclePath) | Out-Null }
        elseif (Test-Path -LiteralPath $LifecyclePath -PathType Container) {
            foreach ($f in @(Get-ChildItem -LiteralPath $LifecyclePath -Filter 'lifecycle-*.jsonl' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
                $candidates.Add([string]$f.FullName) | Out-Null
            }
        }
        return [pscustomobject]@{
            Paths      = @($candidates.ToArray())
            SearchRoot = [string]$LifecyclePath
            RootKnown  = $true
            Provenance = 'explicit:-LifecyclePath'
        }
    }
    $dir = ''
    try { $dir = Get-LogDir } catch { $dir = '' }
    if (-not [string]::IsNullOrWhiteSpace($dir) -and (Test-Path -LiteralPath $dir -PathType Container)) {
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'lifecycle-*.jsonl' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $candidates.Add([string]$f.FullName) | Out-Null
        }
    }
    # The shared seam (lib/lsp-common.ps1, dispatch 000185 D1-A). Consulted, never re-derived.
    $res = $null
    try { $res = Get-PluginDataRootResolution } catch { $res = $null }
    $known = $true; $prov = 'unknown'
    if ($null -ne $res) { $known = [bool]$res.Known; $prov = [string]$res.Provenance }
    return [pscustomobject]@{
        Paths      = @($candidates.ToArray())
        SearchRoot = [string]$dir
        RootKnown  = $known
        Provenance = $prov
    }
}

function Test-LifecycleVersionAttributable {
    # PURE. Is this record's `pluginVersion` a value the ledger may attribute to a RELEASE?
    #
    # THREE ways a record fails to be attributable, and they are one category, not three:
    #   * MISSING / blank  -- written before dispatch 000209 stamped the field. The un-instrumented
    #                         past; unrecoverable by construction (see the header of
    #                         New-LifecycleLedgerRecords in lib/lsp-common.ps1).
    #   * '0.0.0-unknown'  -- Get-PluginVersion's OWN sentinel for "the manifest would not resolve".
    #                         It is stamped honestly and must be read honestly: the emit site is
    #                         saying it did not know the version. Counting it as a version would
    #                         attribute real clearance data to a release that does not exist.
    #   * unparseable      -- anything whose release core is not a [System.Version]. Not a version,
    #                         so not an attribution.
    #
    # The unparseable branch is why this does NOT reuse ConvertTo-CacheVersionKey (dogfood-reader):
    # that helper maps a junk name to 0.0.0 so any real version OUTRANKS it, which is right for
    # picking a MAXIMUM (the current cache dir) and inverts for picking a MINIMUM (a floor) -- junk
    # would become the floor every time. Same [System.Version]::TryParse primitive, opposite
    # tie-handling, so the sort direction cannot silently import the wrong default.
    param([string] $Version)
    if ([string]::IsNullOrWhiteSpace($Version)) { return $false }
    if ($Version -eq '0.0.0-unknown') { return $false }
    $core = ([string]$Version -split '-', 2)[0]
    $v = $null
    return ([System.Version]::TryParse($core, [ref] $v))
}

function Get-LifecycleProvenanceFloor {
    # PURE. The PROVENANCE FLOOR: the earliest plugin version for which lifecycle data is
    # version-attributable, plus the size of the bounded gap below it.
    #
    # WHY A FLOOR AND NOT A FILTER. The clearance columns (fixed_next_turn_rate, persistence_rate)
    # read a log whose pre-000209 records carry no version and whose path is not
    # version-partitioned, so their provenance is not merely unfiltered -- it is unrecoverable. You
    # cannot recover an un-instrumented past. You CAN stop the bleed and say exactly where the
    # knowable part starts. This computes that boundary and NOTHING else: it selects no record,
    # drops no record, and no figure anywhere in this ledger is derived from its output.
    #
    # THE FLOOR IS THE MINIMUM, NOT THE MAXIMUM. "Earliest version-attributable point" is a claim
    # about where knowledge BEGINS, so it is the lowest attributable version present -- taking the
    # highest would name the newest release and silently disown every older stamped record.
    # Ordering is semantic (release core as [System.Version]), with a lexical tiebreak so two
    # pre-release builds of one release order deterministically rather than by hashtable order.
    #
    # Returns { State; Floor; Attributable; PreFloor; Versions[] }. Three states, three claims:
    #   'none'      -- no lifecycle records at all. There is nothing to floor.
    #   'gap-only'  -- records exist, NONE is attributable. The whole window is the bounded gap and
    #                  there is no floor to name -- distinct from 'none', which has no data at all.
    #   'floored'   -- at least one attributable record; Floor names the earliest.
    param([hashtable] $Versions, [int] $PreFloor = 0)
    $v = if ($null -eq $Versions) { @{} } else { $Versions }
    $names = @($v.Keys | Where-Object { Test-LifecycleVersionAttributable -Version ([string]$_) })
    $attributable = 0
    foreach ($n in $names) { $attributable += [int]$v[$n] }
    if ($names.Count -eq 0) {
        $state = if ([int]$PreFloor -gt 0) { 'gap-only' } else { 'none' }
        return @{ State = $state; Floor = $null; Attributable = 0; PreFloor = [int]$PreFloor; Versions = @() }
    }
    $sorted = @($names | Sort-Object `
        @{ Expression = { $parsed = $null
                [void][System.Version]::TryParse((([string]$_) -split '-', 2)[0], [ref] $parsed)
                $parsed } }, `
        @{ Expression = { [string]$_ } })
    return @{
        State = 'floored'; Floor = [string]$sorted[0]; Attributable = $attributable
        PreFloor = [int]$PreFloor; Versions = @($sorted)
    }
}

function Read-LifecycleLog {
    # Parse the sibling log into per-rule totals: ruleId -> @{ cleared; stillPresent }.
    # Tolerates a torn or partial trailing line (the writer appends; a reader can catch it
    # mid-append) by skipping any line that does not parse -- and REPORTS the skip count rather
    # than swallowing it, because a silently-dropped record would understate a rate.
    #
    # -Search (dispatch 000185, D1-B) is the Resolve-LifecycleLogSearch result, carried through
    # verbatim so the rendering layer and Get-LifecycleRates both see WHERE the reader looked and
    # HOW that directory was resolved. Optional: omitted means the caller named its own paths, so
    # there is no fallback to disclose and RootKnown stays $true.
    #
    # VERSION PROVENANCE (dispatch 000209) is tallied here and is PURELY ADDITIVE. Every record
    # still contributes its cleared / stillPresent counts to $byRule regardless of whether it
    # carries a version -- the tally observes, it never selects. That is the load-bearing property:
    # filtering the union to stamped records would silently move fixed_next_turn_rate and
    # persistence_rate for every rule with pre-000209 history, which is exactly the
    # previously-published-figure-changes-value defect this dispatch exists to refuse.
    param([string[]] $LogPaths, $Search = $null)
    $byRule = @{}
    $records = 0
    $skipped = 0
    $versions = @{}          # attributable version string -> record count
    $preFloorRecords = 0     # records carrying no usable version (pre-instrumentation, or sentinel)
    $read = New-Object System.Collections.Generic.List[object]
    foreach ($lp in @($LogPaths)) {
        if ([string]::IsNullOrWhiteSpace($lp) -or -not (Test-Path -LiteralPath $lp -PathType Leaf)) { continue }
        $n = 0
        foreach ($line in @(Get-Content -LiteralPath $lp -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $o = $null
            try { $o = $line | ConvertFrom-Json } catch { $skipped++; continue }
            if ($null -eq $o) { $skipped++; continue }
            $rid = [string](Get-Prop $o 'ruleId')
            if ([string]::IsNullOrWhiteSpace($rid)) { $rid = '(parser/no-rule)' }
            if (-not $byRule.ContainsKey($rid)) { $byRule[$rid] = @{ cleared = 0; stillPresent = 0 } }
            $c = 0; $s = 0
            try { $c = [int](Get-Prop $o 'cleared') } catch { $c = 0 }
            try { $s = [int](Get-Prop $o 'stillPresent') } catch { $s = 0 }
            $byRule[$rid].cleared += $c
            $byRule[$rid].stillPresent += $s
            # Provenance tally -- AFTER the counts above, and with no `continue` of its own, so no
            # branch here can skip a record's contribution to the totals.
            $pv = [string](Get-Prop $o 'pluginVersion')
            if (Test-LifecycleVersionAttributable -Version $pv) {
                if (-not $versions.ContainsKey($pv)) { $versions[$pv] = 0 }
                $versions[$pv]++
            } else {
                $preFloorRecords++
            }
            $records++; $n++
        }
        $read.Add([pscustomobject]@{ LogPath = [string]$lp; Records = $n }) | Out-Null
    }
    return [pscustomobject]@{
        ByRule = $byRule; Records = $records; Skipped = $skipped
        # The provenance tally (dispatch 000209), carried alongside -- never folded into -- the
        # counts above. Attributable + PreFloor == Records, exactly, by construction.
        Versions = $versions
        # [int] on purpose: Measure-Object -Sum over an EMPTY set yields $null, not 0, and a $null
        # Attributable would render as an empty string instead of a zero.
        Attributable = [int]((@($versions.Values) | Measure-Object -Sum).Sum)
        PreFloorRecords = $preFloorRecords
        LogsRead = @($read.ToArray())
        # PRESENT means at least one lifecycle log FILE was found and opened. It is deliberately
        # NOT "at least one record": a log that exists and holds nothing is a different claim
        # from no log at all, and the two must not render identically.
        Present = (@($read.ToArray()).Count -gt 0)
        # The search provenance (dispatch 000185, D1-B), so a NOT-PRESENT result can say whether
        # it is entitled to the word 'absent'. Defaults are the no-fallback-to-disclose case.
        SearchRoot = $(if ($null -ne $Search) { [string]$Search.SearchRoot } else { '' })
        RootKnown  = $(if ($null -ne $Search) { [bool]$Search.RootKnown } else { $true })
        Provenance = $(if ($null -ne $Search) { [string]$Search.Provenance } else { 'caller-supplied paths' })
    }
}
