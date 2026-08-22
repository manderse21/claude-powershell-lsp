#Requires -Version 5.1

# rule-efficacy-ledger.ps1 -- Arc A Slice A1: the READ-ONLY per-rule diagnostic efficacy ledger
# over the two shipped dogfood logs (dispatch 000153, chartered by the 000148 leg-2 survey).
#
# WHAT IT IS. A per-rule aggregation of what the plugin has already captured, keyed by `ruleId`,
# carrying SIX data columns. Four are the reader-side columns the 000148 survey section (c) proved
# derivable from the capture logs alone:
#
#   fired_count           capture occurrences per rule          diagnostics.jsonl (Add-DiagnosticCaptureEntries)
#   distinct_shapes       distinct shape-hash per rule          diagnostics.jsonl `.hash` / Get-DiagnosticShapeHash
#   source_split          per-record source bucket              Get-DogfoodSourceBucket over `.file`
#   verdict_distribution  annotation verdicts by shape-hash     annotations.jsonl `.verdict` (frozen enum)
#
# The other two derive from the closed-loop CLEARED / STILL-PRESENT signal:
#
#   fixed_next_turn_rate  cleared / (cleared + stillPresent)       lifecycle-*.jsonl (Get-LifecycleRates)
#   persistence_rate      stillPresent / (cleared + stillPresent)  lifecycle-*.jsonl (Get-LifecycleRates)
#
# HISTORY, kept because the reason still governs how those two RENDER. Through dispatch 000153 they
# were deliberately absent: Get-FindingLifecycleDiff computed the signal and the daemon emitted it,
# but nothing PERSISTED it per rule -- it lived in daemon in-memory state, in the turn payload, and
# as a per-file aggregate debug line -- so a reader-side slice could not have populated them without
# inventing data. Dispatch 000171 leg 2 shipped that persistence as a SIBLING log, which is why they
# are derived and present now. The old constraint survives as a rendering rule: each rate carries a
# state -- 'absent', 'no-events' or 'derived', per Get-LifecycleRates -- so an unmeasured rate
# renders '(absent)' or '(no-events)' and NEVER 0. A zero would still be a fabricated fact.
#
# FACTS ONLY -- the S3.2 positioning guardrail. This tool reports counts. It does NOT score, rank,
# grade, prioritize, or recommend: rows come out sorted by `ruleId` (a stable, meaningful-free
# order), never by magnitude. Feedback item #6's disposition is "drop the score, keep the facts",
# and a ledger that ranks is a score with extra steps. Interpretation is the reader's job.
#
# SYNTHETIC EXCLUSION. Test-harness and Pester captures ('*Temp?claude*', '*psls-pester-data*')
# dominate raw occurrence counts -- the 000148 survey measured 1803 synthetic occurrences against 16
# genuine ones. They are EXCLUDED from the headline ledger and reported separately, LABELLED, so a
# published efficacy figure is honest. The synthetic tally is never folded into a headline number.
# There is deliberately NO switch to fold it in.
#
# UNION-READ (dispatch 000153). Captures accrue under the INSTALLED marketplace cache, whose path
# carries the plugin VERSION -- so an upgrade starts a fresh log and resets the denominator. This
# reader therefore UNIONS every per-version cache log it discovers rather than selecting the newest
# (which is what the shipped Get-DogfoodCacheLogPath does, correctly, for its own purpose). The
# directories unioned and the discovery method are printed with the ledger, never assumed.
#
# NEVER A SILENT SKIP. An absent or empty named log is a FAILURE with a distinct exit code, not a
# zero-row ledger -- a ledger of zeros and a ledger over nothing are different claims and must not
# render identically. Exit codes:
#
#   0   ledger produced
#   3   a selected log is ABSENT or EMPTY (nothing to read -- not "zero findings")
#   4   union discovery found ZERO per-version cache directories (nothing to union)
#
# READ-ONLY, ABSOLUTELY. Its only I/O is Test-Path / Get-ChildItem / Get-Content. It writes NOTHING:
# not the capture log, not the annotations file, not a cache, not a report file. It changes no
# capture format, adds no userConfig knob, and touches no daemon or hook path. `review-dogfood.ps1`
# is a SIBLING, not a host: its contract and output are byte-unchanged by this file's existence.
#
# REUSE, NEVER RE-IMPLEMENT. Shape-hashing (Get-DiagnosticShapeHash, lib/lsp-common.ps1) and source
# bucketing (Get-DogfoodSourceBucket, lib/dogfood-reader.psm1) are loaded from where they already
# live. A second implementation of either would let this ledger disagree with review-dogfood.ps1 on
# identical input, which is worse than having no ledger.
#
# Usage:
#   pwsh -File scripts/rule-efficacy-ledger.ps1                    # union every per-version cache log
#   pwsh -File scripts/rule-efficacy-ledger.ps1 -Source all        # ... plus the running-tree log
#   pwsh -File scripts/rule-efficacy-ledger.ps1 -Source cache      # the single current cache log
#   pwsh -File scripts/rule-efficacy-ledger.ps1 -Source checkout   # the running-tree log
#   pwsh -File scripts/rule-efficacy-ledger.ps1 -Path X -AnnotationsPath Y   # explicit files
#
# Dot-source safe: dot-sourcing defines the functions without running anything, so the unit tests
# exercise the pure logic in isolation. It is nonetheless not a library -- it carries a param()
# block, so anything wanting its helpers should be split out the way lib/dogfood-reader.psm1 was
# (dispatch 000156) rather than dot-sourcing this file.
#
# Author: Mike Andersen / powershell-lsp plugin.

param(
    # Explicit diagnostics.jsonl to read. Overrides -Source entirely (honored verbatim).
    [string] $Path = '',

    # WHICH log(s) the ledger reads. All five are READ-ONLY resolutions; none affects where the
    # hook WRITES:
    #   union     (default) the DATA-ROOT log (the live write target since the T2.3 relocation)
    #             PLUS every per-version marketplace-cache log discovered, unioned -- so the
    #             denominator survives a plugin upgrade instead of resetting with the version dir.
    #   all       the union above PLUS the running-tree (checkout) log.
    #   data      the single data-root log (Get-DogfoodLogPath -- where captures land now).
    #   cache     the single CURRENT cache log (Get-DogfoodCacheLogPath, reused unchanged).
    #   checkout  the running-tree log (Get-LegacyDogfoodLogPath, READ-ONLY).
    # -Path always wins over -Source.
    #
    # T2.3 NOTE, load-bearing for the denominator. Before the relocation every capture landed in
    # a VERSIONED cache directory, which is the whole reason `union` had to enumerate version
    # dirs to keep a denominator across upgrades. The data root carries no version segment, so
    # accrual from here on is already unfragmented -- but the pre-relocation per-version logs
    # still hold real history, so `union` keeps reading them rather than discarding the past.
    [ValidateSet('union', 'all', 'data', 'cache', 'checkout')]
    [string] $Source = 'union',

    # Explicit annotations.jsonl to read. Default: the annotations.jsonl beside EACH resolved log
    # (unioned the same way the capture logs are).
    [string] $AnnotationsPath = '',

    # Override the plugin cache root for discovery (a test seam). Default: <home>/.claude/plugins/cache.
    [string] $CacheRoot = '',

    # Explicit per-rule lifecycle log(s) to read (dispatch 000171 leg 2). Accepts a file or a
    # directory; a directory is scanned for lifecycle-*.jsonl. Default: the lifecycle family in
    # Get-LogDir. This is the SIBLING log -- reading it never touches diagnostics.jsonl, and its
    # absence is reported as ABSENT rather than silently rendered as zeros.
    [string] $LifecyclePath = ''
)

# The four $Ledger* variables below are the only argument values the entry point trusts.
#
# THEY USED TO BE A WORKAROUND, AND ARE NOT ONE ANY MORE (dispatch 000156). This file previously
# dot-sourced review-dogfood.ps1 to borrow its readers. That script carries a `param()` block of
# its own with $Path, $Source and $AnnotationsPath, and dot-sourcing a .ps1 RUNS its param block in
# THIS scope -- so all three were silently reset to review-dogfood's defaults ($Path '', $Source
# 'auto') the moment the dot-source executed. Reading them afterwards discarded -Path and read
# -Source as 'auto': the script quietly ignored its own arguments, which is the exact silent-wrong
# failure this tool exists to refuse. Capturing first was the defensive fix.
#
# The hazard is now STRUCTURALLY GONE: the readers come from lib/dogfood-reader.psm1, a module with
# no param block that cannot write this scope at all. The captures are retained deliberately --
# they are read throughout the file, so keeping them holds this entry point's behavior byte-for-byte
# unchanged, and capturing an argument once at the top is good practice independent of the bug that
# first forced it.
$script:LedgerArgPath = $Path
$script:LedgerArgSource = $Source
$script:LedgerArgAnnotationsPath = $AnnotationsPath
$script:LedgerArgCacheRoot = $CacheRoot
$script:LedgerArgLifecyclePath = $LifecyclePath

# Reuse the shipped readers and classifiers rather than re-implementing them, and load each from
# where it actually lives. Both imports resolve $PSScriptRoot-relative -- the plugin runs from the
# marketplace cache, not a checkout and not PSModulePath.
#   dogfood-reader.psm1 : Read-DogfoodLog, Read-DogfoodAnnotations, Get-DogfoodSourceBucket,
#                         Get-DogfoodAnnotationsPath, Get-DogfoodCacheLogPath,
#                         Get-DefaultPluginCacheRoot, Test-DogfoodVerdict
#   lib/lsp-common.ps1  : Get-DiagnosticShapeHash, Get-DogfoodLogPath, Get-Prop
Import-Module (Join-Path $PSScriptRoot 'lib/dogfood-reader.psd1') -Force -DisableNameChecking
. (Join-Path $PSScriptRoot 'lib/lsp-common.ps1')
# The lifecycle READ side (dispatch 000216). It moved to a shared library when the doctor
# became its second consumer; the bodies are unchanged and this file is still the only
# place that RENDERS them. Loaded AFTER lsp-common.ps1, which it depends on.
. (Join-Path $PSScriptRoot 'lib/lifecycle-provenance.ps1')

# The three source buckets in a fixed display order, and the subset that is REAL signal. 'synthetic'
# is real data about the test harness, not about the plugin's field behavior, so it is excluded from
# the headline and reported separately. Mirrors Get-DogfoodSourceSplit's ordering deliberately.
$script:LedgerBuckets = @('canonical-checkout', 'other-genuine', 'synthetic')
$script:LedgerRealBuckets = @('canonical-checkout', 'other-genuine')

# ===========================================================================
# Discovery -- the union-read over per-version cache directories.
# ===========================================================================

function Get-DogfoodCacheLogPathSet {
    # UNION discovery: every per-version marketplace-cache dogfood log, not just the current one.
    #
    # The shipped Get-DogfoodCacheLogPath answers "which log is the live hook writing to NOW" and
    # correctly SELECTS one version. This answers a different question -- "everything this plugin has
    # ever captured on this machine" -- so it enumerates instead of selecting. Same tree shape, no
    # hardcoded version:
    #   <cache-root>/<marketplace>/powershell-lsp/<version>/dogfood/diagnostics.jsonl
    # <marketplace> and <version> are both DISCOVERED from disk; only the fixed plugin-name segment
    # 'powershell-lsp' is literal.
    #
    # Returns one row per VERSION DIRECTORY found -- including directories whose log does not exist --
    # so the caller can tell "no version directories at all" (a discovery failure, exit 4) apart from
    # "version directories exist but hold no captures" (an empty-log failure, exit 3). Collapsing
    # those two into an empty list would be exactly the silent skip this tool refuses to perform.
    # Rows are ordered by marketplace then version name, so output is deterministic.
    #
    # Read-only: Test-Path and Get-ChildItem only.
    param([string] $CacheRoot = '')
    $cacheDir = if (-not [string]::IsNullOrWhiteSpace($CacheRoot)) { $CacheRoot } else { Get-DefaultPluginCacheRoot }
    $rows = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($cacheDir) -or -not (Test-Path -LiteralPath $cacheDir)) {
        return @($rows.ToArray())
    }
    foreach ($mk in @(Get-ChildItem -LiteralPath $cacheDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $pluginDir = Join-Path $mk.FullName 'powershell-lsp'
        if (-not (Test-Path -LiteralPath $pluginDir -PathType Container)) { continue }
        foreach ($ver in @(Get-ChildItem -LiteralPath $pluginDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $log = Join-Path $ver.FullName 'dogfood/diagnostics.jsonl'
            $rows.Add([pscustomobject]@{
                    Marketplace = [string]$mk.Name
                    Version     = [string]$ver.Name
                    VersionDir  = [string]$ver.FullName
                    LogPath     = [string]$log
                    LogExists   = (Test-Path -LiteralPath $log -PathType Leaf)
                }) | Out-Null
        }
    }
    # Returned WITHOUT a unary comma so a caller's @(...) collects the rows themselves rather than
    # nesting them one level deep -- the callers here all wrap in @(), which is the repo idiom.
    return @($rows.ToArray())
}

function Resolve-RuleLedgerSources {
    # Resolve WHICH logs the ledger reads, and record HOW they were discovered so the readout can
    # state it rather than leave the reader to guess. Returns
    #   { LogPaths[]; VersionDirs[]; Discovery; Mode }
    # where VersionDirs is the union-discovery evidence (empty for the non-union modes) and Discovery
    # is a one-line human description of the resolution actually used.
    param([string] $Source = 'union', [string] $Path = '', [string] $CacheRoot = '')

    # UnionAttempted, not a Mode string comparison, is what gates the exit-4 guard downstream: it is
    # set by the branch that actually performed the enumeration, so a future mode name can never
    # silently fall outside the guard.
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{
            LogPaths       = @($Path)
            VersionDirs    = @()
            Discovery      = ('explicit -Path (honored verbatim): ' + $Path)
            Mode           = 'path'
            UnionAttempted = $false
        }
    }

    switch ($Source) {
        'cache' {
            $one = Get-DogfoodCacheLogPath -CacheRoot $CacheRoot
            return [pscustomobject]@{
                LogPaths       = @($one | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                VersionDirs    = @()
                Discovery      = 'single CURRENT cache log via Get-DogfoodCacheLogPath (highest semantic version carrying a log)'
                Mode           = 'cache'
                UnionAttempted = $false
            }
        }
        'data' {
            $one = Get-DogfoodLogPath
            return [pscustomobject]@{
                LogPaths       = @($one | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                VersionDirs    = @()
                Discovery      = 'data-root log via Get-DogfoodLogPath (the LIVE write target since the T2.3 relocation)'
                Mode           = 'data'
                UnionAttempted = $false
            }
        }
        'checkout' {
            $one = Get-LegacyDogfoodLogPath
            return [pscustomobject]@{
                LogPaths       = @($one | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                VersionDirs    = @()
                Discovery      = 'pre-relocation running-tree log via Get-LegacyDogfoodLogPath (READ-ONLY; nothing writes there since T2.3)'
                Mode           = 'checkout'
                UnionAttempted = $false
            }
        }
        default {
            # 'union' and 'all' share the cache enumeration and BOTH lead with the data-root log,
            # which is where captures land since the T2.3 relocation; 'all' also appends the
            # pre-relocation checkout log. Omitting the data root would have left the ledger
            # reading only frozen history and calling it the current denominator.
            $dirs = @(Get-DogfoodCacheLogPathSet -CacheRoot $CacheRoot)
            $paths = @($dirs | Where-Object { $_.LogExists } | ForEach-Object { [string]$_.LogPath })
            $how = 'UNION of every per-version cache log under <cache-root>/<marketplace>/powershell-lsp/<version>/dogfood/diagnostics.jsonl (marketplace and version discovered from disk)'
            # AN EXPLICIT -CacheRoot SCOPES THE READ, so the ambient data-root log is NOT added to
            # it. -CacheRoot exists to point the union at one named tree -- a fixture, or a specific
            # cache being audited -- and silently folding in whatever the live machine happens to
            # have under CLAUDE_PLUGIN_DATA would break exactly that scoping and pollute the
            # denominator with captures from an unrelated population. Caught by
            # PowerShellLsp.RuleLedger.Tests.ps1's union test, which supplies a synthetic two-version
            # cache root and correctly refused a third path it had not put there.
            $scoped = -not [string]::IsNullOrWhiteSpace($CacheRoot)
            if ($scoped) {
                $how += ' -- SCOPED to the supplied -CacheRoot, so the data-root log is deliberately excluded'
            } else {
                $dataLog = Get-DogfoodLogPath
                if (-not [string]::IsNullOrWhiteSpace($dataLog) -and (Test-Path -LiteralPath $dataLog -PathType Leaf)) {
                    $paths = @([string]$dataLog) + @($paths)
                }
                $how = 'the DATA-ROOT log via Get-DogfoodLogPath, PLUS a ' + $how
            }
            if ($Source -eq 'all') {
                $co = Get-LegacyDogfoodLogPath
                if (-not [string]::IsNullOrWhiteSpace($co) -and (Test-Path -LiteralPath $co -PathType Leaf)) {
                    $paths = @($paths) + @([string]$co)
                }
                $how += ', PLUS the pre-relocation running-tree log via Get-LegacyDogfoodLogPath'
            }
            return [pscustomobject]@{
                LogPaths       = @($paths)
                VersionDirs    = @($dirs)
                Discovery      = $how
                Mode           = $Source
                UnionAttempted = $true
            }
        }
    }
}

# ===========================================================================
# Reading -- flatten the capture records into the minimal per-occurrence shape the ledger needs.
# ===========================================================================

function ConvertTo-LedgerOccurrences {
    # Flatten parsed capture records into the three facts a ledger row aggregates: rule, shape-hash,
    # and source bucket. Two reuse points, both deliberate:
    #   - the SOURCE BUCKET comes from Get-DogfoodSourceBucket (review-dogfood.ps1), the single source
    #     of truth for the synthetic / canonical-checkout / other-genuine split.
    #   - the SHAPE-HASH is the record's own `.hash` when present, and is otherwise RECOMPUTED with
    #     Get-DiagnosticShapeHash (lib/lsp-common.ps1) from (ruleId + snippet) -- the exact material
    #     the capture writer hashed. A hand-written or truncated record therefore still keys
    #     identically to a captured one, and nothing is silently dropped for want of a hash.
    # A missing rule id becomes '(parser/no-rule)', matching review-dogfood.ps1's own label, so a
    # parser diagnostic is counted rather than discarded. Pure; no I/O.
    param([object[]] $Records, [string] $Partition = '')
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($r in @($Records)) {
        $rid = [string](Get-Prop $r 'ruleId')
        if ([string]::IsNullOrWhiteSpace($rid)) { $rid = '(parser/no-rule)' }
        $h = [string](Get-Prop $r 'hash')
        if ([string]::IsNullOrWhiteSpace($h)) {
            $h = Get-DiagnosticShapeHash -RuleId ([string](Get-Prop $r 'ruleId')) -OffendingLine ([string](Get-Prop $r 'snippet'))
        }
        $out.Add([pscustomobject]@{
                ruleId = $rid
                hash   = $h
                bucket = (Get-DogfoodSourceBucket -File ([string](Get-Prop $r 'file')))
                # The VERSION PARTITION this occurrence was captured under (dispatch 000171 leg 4).
                # Carried from DISCOVERY -- the capture record itself has no version field, and the
                # ruling was explicitly NOT to add one. This is what makes retroactive rule-surface
                # attribution possible for records written long before the attribution existed.
                partition = [string]$Partition
            }) | Out-Null
    }
    return @($out.ToArray())
}

function Read-RuleLedgerInput {
    # Read every resolved log (and each log's sibling annotations file, unless one is named
    # explicitly) and return the unioned occurrences plus the merged annotation map.
    #
    # Annotation merge order follows the shipped last-write-wins rule WITHIN a file
    # (Read-DogfoodAnnotations); ACROSS files, later files in the resolved order win for a shared
    # hash. In practice hashes do not collide across version dirs unless the same shape really was
    # captured twice, in which case either verdict is the same judgment of the same shape.
    #
    # Returns { Occurrences[]; Annotations{}; LogsRead[]; NonEmptyLogs[]; MeasuredAtUtc;
    # ReadWindowMs }. Read-only.
    param([string[]] $LogPaths, [string] $AnnotationsPath = '')
    $occ = New-Object System.Collections.Generic.List[object]
    $ann = @{}
    $read = New-Object System.Collections.Generic.List[object]
    $nonEmpty = New-Object System.Collections.Generic.List[string]

    # THE MEASUREMENT INSTANT (dispatch 000172, leg 6). Stamped HERE -- immediately before the
    # first log file is opened -- and NOT at render time, because the capture logs are append-only
    # and LIVE: the installed plugin's hook writes to them while a session works, including the
    # session running this reader. Dispatch 000171 measured 124 real occurrences early in its own
    # session and 126 later, and 000170 reported 120; all three are CORRECT and differently aged.
    # An unstamped readout makes correct readings look like a contradiction, so every figure this
    # tool prints now carries the instant it was true.
    $measuredAtUtc = [datetime]::UtcNow
    $readSw = [System.Diagnostics.Stopwatch]::StartNew()

    foreach ($lp in @($LogPaths)) {
        if ([string]::IsNullOrWhiteSpace($lp)) { continue }
        $records = @(Read-DogfoodLog -LogPath $lp)
        if ($records.Count -gt 0) { $nonEmpty.Add([string]$lp) | Out-Null }
        # Recover the VERSION partition from the discovered path. The cache tree is
        # <root>/<marketplace>/powershell-lsp/<version>/dogfood/diagnostics.jsonl, so the version is
        # the grandparent directory name. A non-cache path (an explicit -Path, the checkout log)
        # has no partition and attributes to '(unpartitioned)' rather than being guessed at.
        $partition = '(unpartitioned)'
        try {
            $verDir = Split-Path -Parent (Split-Path -Parent $lp)
            $leaf = Split-Path -Leaf $verDir
            if ($leaf -match '^\d+\.\d+\.\d+$') { $partition = $leaf }
        } catch { $partition = '(unpartitioned)' }
        foreach ($o in @(ConvertTo-LedgerOccurrences -Records $records -Partition $partition)) { $occ.Add($o) | Out-Null }
        $read.Add([pscustomobject]@{ LogPath = [string]$lp; Records = $records.Count }) | Out-Null

        # Sibling annotations, one file per log. Skipped entirely when -AnnotationsPath names one
        # explicitly -- that file is then read ONCE, after the loop, rather than once per log.
        if ([string]::IsNullOrWhiteSpace($AnnotationsPath)) {
            $ap = Get-DogfoodAnnotationsPath -LogPath $lp
            foreach ($kv in (Read-DogfoodAnnotations -AnnotationsPath $ap).GetEnumerator()) { $ann[$kv.Key] = $kv.Value }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($AnnotationsPath)) {
        foreach ($kv in (Read-DogfoodAnnotations -AnnotationsPath $AnnotationsPath).GetEnumerator()) { $ann[$kv.Key] = $kv.Value }
    }

    # NOTE: no unary comma on these properties. The comma operator is needed when RETURNING an array
    # from a function (it stops the pipeline unrolling it); assigning one to a property needs no
    # protection, and a comma there would nest the array one level deep instead.
    $readSw.Stop()
    return [pscustomobject]@{
        Occurrences   = @($occ.ToArray())
        Annotations   = $ann
        LogsRead      = @($read.ToArray())
        NonEmptyLogs  = @($nonEmpty.ToArray())
        # Round-trip ('o') format: UTC, 100-ns resolution. Two reads of the same logs seconds
        # apart therefore carry visibly different stamps, which is the whole point.
        MeasuredAtUtc = $measuredAtUtc.ToString('o')
        ReadWindowMs  = [int]$readSw.ElapsedMilliseconds
    }
}

# ===========================================================================
# Rule-surface attribution -- BOTH denominators, never a silent re-baseline (000171 leg 4).
# ===========================================================================
# THE RULING: do NOT filter the union, and do NOT tag only records written from now on. Filtering
# discards history; tag-forward leaves everything already captured permanently unattributable,
# which is the exact state that forced 000170 to hand-match message prose. Instead the surface is
# DERIVED AT READ TIME from the version partition each capture already sits in, against the
# committed rulesets/surface-history.psd1 (generated by scripts/regen-surface-history.ps1).
#
# BOTH denominators are reported side by side. NOTHING is filtered out of the existing rows, so no
# figure this tool has ever printed changes value: the current-surface denominator is ADDITIONAL
# information, not a re-baselining of the total.

function Import-SurfaceHistory {
    # version -> @(rule names) from the committed history. Returns @{} when absent/unparseable --
    # the caller then reports attribution as UNAVAILABLE rather than silently attributing nothing.
    param([string] $Path = '')
    if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Join-Path (Split-Path -Parent $PSScriptRoot) 'rulesets/surface-history.psd1' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @{} }
    try {
        $data = Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop
        $map = @{}
        foreach ($v in @($data['versions'])) {
            if ($null -eq $v) { continue }
            $map[[string]$v['version']] = @($v['rules'])
        }
        return $map
    } catch { return @{} }
}

function Get-SurfaceAttribution {
    # Split occurrences into those whose rule was in the CURRENT shipped surface and those whose
    # rule is not, and separately count those attributable to a surface that has since changed.
    #
    # OWNED FINDERS AND PARSER DIAGNOSTICS ARE UNATTRIBUTABLE (dispatch 000185, ND-B). They are not
    # PSScriptAnalyzer rules and rulesets/base.psd1 says nothing about them, so this table cannot
    # tell whether the RUNG that produced one is still shipped.
    #
    # WHAT CHANGED AND WHY. Until 000185 the loop opened with
    #
    #     if (-not $rid.StartsWith('PS')) { $ownedOrParser++; $inCurrent++; continue }
    #
    # which counted every owned-finder occurrence as IN the current surface and `continue`d past
    # BOTH the removed-rule test and the unknown-partition test. The consequence was not a
    # measurement error, it was an unreachable category: an owned finder's occurrences could never
    # be reported out-of-surface BY CONSTRUCTION, so the reported figure read as "measured zero"
    # when it was really "never tested". The 65 ManifestConsistency occurrences dispatch 000170 had
    # to attribute BY HAND sat silently inside in-current-surface the whole time.
    #
    # Option (iii) of the ND-B fork is taken: an explicit UNATTRIBUTABLE bucket that is REPORTED
    # rather than folded into either side. It changes NOTHING about what is written per capture
    # record -- the write side stays exactly as it was -- and it refuses to guess. A rung catalog
    # keyed by message shape (option (i)) would move occurrences out of this bucket and into net;
    # it remains available as a follow-on and does not change the shape reported here.
    #
    # The partition test now runs for EVERY occurrence, including these. It was skipped only as a
    # side effect of the same `continue`, which is the same defect wearing a second hat.
    param([object[]] $Occurrences, [string[]] $CurrentSurface, [hashtable] $History)
    $cur = @{}
    foreach ($r in @($CurrentSurface)) { $cur[[string]$r] = $true }
    $inCurrent = 0; $outCurrent = 0; $ownedOrParser = 0
    $outRules = @{}
    $unattributableRules = @{}
    $unknownPartition = 0
    foreach ($o in @($Occurrences)) {
        $rid = [string]$o.ruleId
        $p = [string]$o.partition
        if ([string]::IsNullOrWhiteSpace($p) -or -not $History.ContainsKey($p)) { $unknownPartition++ }
        if (-not $rid.StartsWith('PS')) {
            $ownedOrParser++
            if (-not $unattributableRules.ContainsKey($rid)) { $unattributableRules[$rid] = 0 }
            $unattributableRules[$rid]++
            continue
        }
        if ($cur.ContainsKey($rid)) { $inCurrent++ } else { $outCurrent++; $outRules[$rid] = $true }
    }
    # THE THREE NUMBERS (dispatch 000185, ND-C). gross = net + unattributable, exactly, always.
    #   gross          every real occurrence the union produced
    #   net            the occurrences this mechanism CAN reason about (in-surface + out-of-surface)
    #   unattributable the occurrences it cannot, said out loud instead of absorbed
    $gross = @($Occurrences).Count
    return [pscustomobject]@{
        Total = $gross
        Gross = $gross
        Net = ($inCurrent + $outCurrent)
        Unattributable = $ownedOrParser
        InCurrentSurface = $inCurrent
        OutOfCurrentSurface = $outCurrent
        OwnedOrParser = $ownedOrParser
        OutOfSurfaceRules = @($outRules.Keys | Sort-Object)
        UnattributableRules = @($unattributableRules.Keys | Sort-Object | ForEach-Object {
                [pscustomobject]@{ ruleId = [string]$_; occurrences = [int]$unattributableRules[$_] }
            })
        UnknownPartition = $unknownPartition
        HistoryVersions = @($History.Keys).Count
    }
}

function Get-LifecycleRates {
    # PURE. The two columns 000153 could not derive. Both are computed from PERSISTED data only.
    #
    #   fixed_next_turn_rate = cleared / (cleared + stillPresent)
    #   persistence_rate     = stillPresent / (cleared + stillPresent)
    #
    # THREE distinct renderings, because they are three distinct claims:
    #   $null          -- no lifecycle log was found at all: the signal was NEVER CAPTURED.
    #   'no-events'    -- a log exists, but this rule has no lifecycle event in it.
    #   a number       -- genuine, derived from counted events.
    # A ledger over nothing and a ledger of zeros must not look the same.
    #
    # A FOURTH rendering (dispatch 000185, D1-B), because there was a fourth distinct claim the
    # three could not express:
    #
    #   'unresolvable' -- nothing was found, but the search ran under a FALLBACK data root, so
    #                     ABSENT and NOT-FOUND cannot be told apart from this evidence.
    #
    # The three above are unchanged and still mean exactly what they meant. 'absent' now carries
    # its full weight honestly: it is reached ONLY when the reader knows which directory it was
    # supposed to search. Rendering 'absent' after searching a substituted root was the 000182
    # D1 defect -- a claim about the world published on evidence about the reader -- and this
    # branch is what stops it. RootKnown defaults to $true so every existing caller and test
    # keeps its exact prior behavior; only a caller that actually knows the root was substituted
    # can reach the new state.
    param([hashtable] $ByRule, [bool] $Present, [string] $RuleId, [bool] $RootKnown = $true)
    if (-not $Present) {
        if (-not $RootKnown) { return @{ fixed = $null; persistence = $null; state = 'unresolvable'; events = 0 } }
        return @{ fixed = $null; persistence = $null; state = 'absent'; events = 0 }
    }
    if ($null -eq $ByRule -or -not $ByRule.ContainsKey($RuleId)) {
        return @{ fixed = $null; persistence = $null; state = 'no-events'; events = 0 }
    }
    $c = [int]$ByRule[$RuleId].cleared
    $s = [int]$ByRule[$RuleId].stillPresent
    $total = $c + $s
    if ($total -le 0) { return @{ fixed = $null; persistence = $null; state = 'no-events'; events = 0 } }
    return @{
        fixed       = [math]::Round((100.0 * $c / $total), 1)
        persistence = [math]::Round((100.0 * $s / $total), 1)
        state       = 'derived'; events = $total
    }
}

# ===========================================================================
# Aggregation -- the ledger itself. Pure: identical input, identical rows, no I/O.
# ===========================================================================

function Get-RuleEfficacyLedger {
    # The per-rule ledger: one row per ruleId, carrying EXACTLY the four reader-side columns.
    #
    #   fired_count           real (non-synthetic) capture occurrences for this rule
    #   distinct_shapes       distinct shape-hashes among those occurrences
    #   source_split          ordered map bucket -> occurrences, over the REAL buckets only
    #   verdict_distribution  ordered map verdict -> count, over annotations whose hash is one of
    #                         this rule's real shapes (joined by shape-hash, the shipped join key)
    #
    # SYNTHETIC OCCURRENCES ARE EXCLUDED, wholly and by construction: a synthetic occurrence never
    # enters a row, so it cannot inflate fired_count, contribute a shape, or pull an annotation in.
    # The synthetic tally is returned ALONGSIDE the rows, labelled, never inside them.
    #
    # Rows are sorted by ruleId -- alphabetical, NOT by count. That is the S3.2 guardrail expressed in
    # code: ordering by magnitude would be a ranking, and a ranking is a score.
    #
    # Returns { Rows[]; Synthetic{occurrences,shapes,rules}; TotalRealOccurrences; TotalRealShapes;
    # AnnotationsRead }.
    param([object[]] $Occurrences, [hashtable] $Annotations, $Lifecycle)
    $ann = if ($null -eq $Annotations) { @{} } else { $Annotations }
    # Lifecycle is OPTIONAL: absent means no sibling log was found, which the two new columns
    # render as (absent). Defaulting it to "present with no data" would turn a missing
    # measurement into a measured zero.
    $lcPresent = $false
    $lcByRule = @{}
    # RootKnown defaults TRUE (dispatch 000185, D1-B): a Lifecycle object that does not carry the
    # field is a caller that never resolved a root, so it cannot have fallen back, and its
    # rendering must stay byte-identical to before. Only an explicit $false reaches 'unresolvable'.
    $lcRootKnown = $true
    if ($null -ne $Lifecycle) {
        $lcPresent = [bool]$Lifecycle.Present
        if ($null -ne $Lifecycle.ByRule) { $lcByRule = $Lifecycle.ByRule }
        if ($Lifecycle.PSObject.Properties['RootKnown']) { $lcRootKnown = [bool]$Lifecycle.RootKnown }
    }

    $real = @(@($Occurrences) | Where-Object { $script:LedgerRealBuckets -contains [string]$_.bucket })
    $synth = @(@($Occurrences) | Where-Object { [string]$_.bucket -eq 'synthetic' })

    $byRule = @{}
    foreach ($o in $real) {
        $rid = [string]$o.ruleId
        if (-not $byRule.ContainsKey($rid)) {
            $split = [ordered]@{}
            foreach ($b in $script:LedgerRealBuckets) { $split[$b] = 0 }
            $byRule[$rid] = [pscustomobject]@{
                ruleId               = $rid
                fired_count          = 0
                distinct_shapes      = 0
                source_split         = $split
                verdict_distribution = [ordered]@{}
                fixed_next_turn_rate = $null
                persistence_rate     = $null
                _shapes              = @{}
            }
        }
        $row = $byRule[$rid]
        $row.fired_count++
        $b = [string]$o.bucket
        if ($row.source_split.Contains($b)) { $row.source_split[$b]++ }
        $h = [string]$o.hash
        if (-not $row._shapes.ContainsKey($h)) { $row._shapes[$h] = $true; $row.distinct_shapes++ }
    }

    # Join annotations to rows by shape-hash. Only verdicts in the frozen enum are counted; a stray
    # out-of-enum value is ignored exactly as Get-DogfoodSummary ignores it, so the two readers agree.
    foreach ($rid in @($byRule.Keys)) {
        $row = $byRule[$rid]
        $dist = [ordered]@{}
        foreach ($h in @($row._shapes.Keys)) {
            if (-not $ann.ContainsKey($h)) { continue }
            $v = [string](Get-Prop $ann[$h] 'verdict')
            if (-not (Test-DogfoodVerdict $v)) { continue }
            if (-not $dist.Contains($v)) { $dist[$v] = 0 }
            $dist[$v]++
        }
        # Render the frozen enum's own order, so two runs never disagree on column order. The
        # vocabulary is ASKED FOR (Get-DogfoodVerdicts) rather than read as $script:DogfoodVerdicts:
        # that variable only used to be in scope here because dot-sourcing review-dogfood.ps1 leaked
        # it in, which is the same silent-dependency hazard as the leaked param() block (000156).
        $ordered = [ordered]@{}
        foreach ($v in (Get-DogfoodVerdicts)) { if ($dist.Contains($v)) { $ordered[$v] = $dist[$v] } }
        $row.verdict_distribution = $ordered

        # The two lifecycle columns (dispatch 000171 leg 2). DERIVED from the sibling log, never
        # invented: with no log the state is 'absent', with a log but no event for this rule it is
        # 'no-events', and only counted events produce a number.
        $lc = Get-LifecycleRates -ByRule $lcByRule -Present $lcPresent -RuleId $rid -RootKnown $lcRootKnown
        $row.fixed_next_turn_rate = [pscustomobject]@{ state = [string]$lc.state; value = $lc.fixed; events = [int]$lc.events }
        $row.persistence_rate = [pscustomobject]@{ state = [string]$lc.state; value = $lc.persistence; events = [int]$lc.events }
    }

    $rows = @($byRule.Values | Sort-Object @{ Expression = { [string]$_.ruleId } })

    $synthShapes = @{}
    $synthRules = @{}
    foreach ($o in $synth) { $synthShapes[[string]$o.hash] = $true; $synthRules[[string]$o.ruleId] = $true }
    $realShapes = @{}
    foreach ($o in $real) { $realShapes[[string]$o.hash] = $true }

    return [pscustomobject]@{
        Rows                 = @($rows)
        Synthetic            = [pscustomobject]@{
            occurrences = $synth.Count
            shapes      = $synthShapes.Keys.Count
            rules       = $synthRules.Keys.Count
        }
        TotalRealOccurrences = $real.Count
        TotalRealShapes      = $realShapes.Keys.Count
        AnnotationsRead      = $ann.Keys.Count
    }
}

# ===========================================================================
# Rendering -- ASCII, Write-Host-free (returns a string so callers and tests can capture it).
# ===========================================================================

function Format-LedgerMap {
    # An ordered map rendered as 'k=v k=v', or a labelled placeholder when empty. Used for both
    # source_split and verdict_distribution so the two columns read the same way.
    param($Map, [string] $EmptyLabel = '(none)')
    if ($null -eq $Map) { return $EmptyLabel }
    $parts = @()
    foreach ($k in @($Map.Keys)) { $parts += ([string]$k + '=' + [string]$Map[$k]) }
    if ($parts.Count -eq 0) { return $EmptyLabel }
    return ($parts -join ' ')
}

function Format-LedgerRate {
    # Render a lifecycle rate cell. The three states render DIFFERENTLY on purpose (dispatch
    # 000171 leg 2 acceptance): '(absent)' means the signal was never captured, '(no-events)'
    # means it was captured but this rule had no lifecycle event, and a percentage is a real
    # derived figure. Rendering absence as '0.0' would state a measurement that was never made.
    #
    # '(unresolvable)' is the fourth (dispatch 000185, D1-B): nothing was found, but under a
    # FALLBACK data root, so absent and not-found are indistinguishable from this evidence. It
    # renders DIFFERENTLY from '(absent)' on purpose -- collapsing the two would re-create the
    # exact defect the fourth state exists to fix.
    param($Rate)
    if ($null -eq $Rate) { return '(absent)' }
    $state = [string]$Rate.state
    if ($state -eq 'absent') { return '(absent)' }
    if ($state -eq 'unresolvable') { return '(unresolvable)' }
    if ($state -eq 'no-events') { return '(no-events)' }
    return ([string]$Rate.value + ' pct (n=' + [string]$Rate.events + ')')
}

function Format-RuleEfficacyLedger {
    # The full readout: what was read and how it was discovered, the per-rule table, and the
    # separately-labelled synthetic tally. Self-locating by construction -- every number is printed
    # next to the paths it came from, so a pasted readout can be re-derived.
    param($Ledger, $Sources, $LedgerInput, $Lifecycle, $Attribution)
    $lines = @()
    $lines += 'powershell-lsp per-rule diagnostic efficacy ledger (Arc A slice A1) -- facts only, no scores'
    # THE VINTAGE OF EVERY FIGURE BELOW (dispatch 000172, leg 6). Stated in the output itself so a
    # pasted readout carries the instant it was true. This is a MEASUREMENT instant -- when the
    # capture logs were READ -- not when this text was formatted, and it says so, because the
    # difference is the whole reason two correct readings of a live log can disagree.
    if ($null -ne $LedgerInput -and $LedgerInput.PSObject.Properties['MeasuredAtUtc']) {
        $lines += ('  measured at: ' + [string]$LedgerInput.MeasuredAtUtc + '  (UTC, ISO-8601)')
        $lines += ('    ^ the instant the capture logs were READ, over a ' + [string]$LedgerInput.ReadWindowMs +
            ' ms window -- NOT a render time.')
        $lines += '    The capture logs are APPEND-ONLY and LIVE: the installed plugin appends to them while'
        $lines += '    a session works, including this one. A later read of the SAME logs will legitimately'
        $lines += '    report larger figures. Quote this stamp with any number taken from this readout.'
    }
    $lines += ('  discovery: ' + [string]$Sources.Discovery)

    $dirs = @($Sources.VersionDirs)
    if ($dirs.Count -gt 0) {
        $lines += ('  cache version directories found: ' + $dirs.Count)
        foreach ($d in $dirs) {
            $present = if ([bool]$d.LogExists) { 'present' } else { 'absent' }
            $lines += ('    ' + [string]$d.Marketplace + '/' + [string]$d.Version + '  log=' + $present +
                '  ' + [string]$d.LogPath)
        }
    }
    $logs = @($LedgerInput.LogsRead)
    $lines += ('  logs read: ' + $logs.Count)
    foreach ($l in $logs) { $lines += ('    ' + [string]$l.LogPath + '  (' + [string]$l.Records + ' records)') }
    $lines += ('  annotations read: ' + [string]$Ledger.AnnotationsRead)
    # The lifecycle sibling log is reported with its own provenance, so a reader can tell an
    # ABSENT signal (nothing was ever persisted) from a captured signal that happens to be empty.
    #
    # THE RESOLVED ROOT AND ITS PROVENANCE PRINT ON EVERY RUN (dispatch 000185, D1-B), including
    # runs that find nothing -- especially those. A reader has to be able to see WHICH CLAIM they
    # are being handed without re-deriving where the tool looked.
    if ($null -ne $Lifecycle -and $Lifecycle.PSObject.Properties['SearchRoot']) {
        $lines += ('  lifecycle search root: ' +
            $(if ([string]::IsNullOrWhiteSpace([string]$Lifecycle.SearchRoot)) { '(none resolved)' } else { [string]$Lifecycle.SearchRoot }))
        $lines += ('    resolved via: ' + [string]$Lifecycle.Provenance +
            '   data-root known: ' + $(if ([bool]$Lifecycle.RootKnown) { 'YES' } else { 'NO' }))
    }
    if ($null -ne $Lifecycle -and [bool]$Lifecycle.Present) {
        $lines += ('  lifecycle logs read: ' + @($Lifecycle.LogsRead).Count + ' (' + [string]$Lifecycle.Records + ' records)')
        foreach ($l in @($Lifecycle.LogsRead)) { $lines += ('    ' + [string]$l.LogPath + '  (' + [string]$l.Records + ' records)') }
        if ([int]$Lifecycle.Skipped -gt 0) { $lines += ('    unparseable lines SKIPPED: ' + [string]$Lifecycle.Skipped) }

        # THE PROVENANCE FLOOR (dispatch 000209) -- an honesty marker over the CLEARANCE columns.
        #
        # WHAT PRINTS WHEN, and why it is not "always print everything". The FLOOR line prints on
        # every run that read at least one lifecycle record: it is a positive fact about where
        # version-attributable knowledge begins, and a reader who cannot see it has to re-derive it.
        # The BOUNDED-GAP lines print only when a pre-floor record actually exists -- once the
        # rolling family has aged past the un-instrumented window there IS no gap, and a ledger
        # that kept reciting a now-empty caveat would train its reader to skip the section that
        # will matter again after the next format change. An all-attributable ledger reads clean;
        # a gap is never silent. (Open question 3, resolved this way and recorded.)
        #
        # THE FLOOR IS WINDOW-RELATIVE, AND SAYS SO IN PRINT (dispatch 000216). That meaning was
        # real from the first line of this block -- the same rolling-family trim the paragraph
        # above turns on -- but it lived only HERE, in a source comment, where the reader quoting
        # the number never sees it. A floor read as "the earliest release this plugin ever had
        # data for" is a claim about history; what it actually names is the earliest attributable
        # release among the records STILL RETAINED, and it RISES as Invoke-LogSweep trims the
        # family to keepLastN. Printed beside the value, because a caveat a reader has to open the
        # source to find is not a caveat.
        #
        # These lines are ADDITIVE. No figure above or below them changes value, and none is
        # computed from them -- the floor annotates the clearance columns, it does not filter them.
        if ($Lifecycle.PSObject.Properties['Versions']) {
            $prov = Get-LifecycleProvenanceFloor -Versions $Lifecycle.Versions -PreFloor ([int]$Lifecycle.PreFloorRecords)
            $lines += ('    clearance provenance floor: ' +
                $(if ([string]$prov.State -eq 'floored') { 'v' + [string]$prov.Floor } else { '(none -- no version-attributable record)' }))
            if ([string]$prov.State -eq 'floored') {
                # Attached to the floor VALUE, directly under it, because it qualifies that number
                # and nothing else. It is not printed in the no-floor state: there is no floor
                # there to be relative to, and a caveat about a value that was not named would be
                # noise the reader learns to skip.
                $lines += '      ^ WINDOW-RELATIVE, not a claim about this plugin''s whole history. It names the earliest'
                $lines += '        version-attributable release among the lifecycle records STILL RETAINED. The'
                $lines += '        lifecycle-*.jsonl family is a rolling window that session-start.ps1''s Invoke-LogSweep'
                $lines += '        trims to the keepLastN newest, so this floor RISES as older records age out. Quote it'
                $lines += '        with the retained-record counts below, never on its own.'
            }
            $lines += ('      version-attributable records: ' + [string]$prov.Attributable +
                '   pre-floor (bounded gap): ' + [string]$prov.PreFloor)
            if (@($prov.Versions).Count -gt 0) {
                $lines += ('      versions present, earliest first: ' + (@($prov.Versions) -join ', '))
            }
            if ([int]$prov.PreFloor -gt 0) {
                $lines += ('      ^ ' + [string]$prov.PreFloor + ' record(s) carry no usable plugin version. Those predate the in-record')
                $lines += '        stamp (or the emit site could not resolve a version), so the release that produced them'
                $lines += '        is NOT recoverable -- the path of this log carries no version to fall back on. They are'
                $lines += '        a KNOWN, BOUNDED gap: still COUNTED in fixed_next_turn_rate and persistence_rate below,'
                $lines += '        never attributed to a version. The fix is forward-only; no historical record was rewritten.'
            }
        }
    } elseif ($null -ne $Lifecycle -and $Lifecycle.PSObject.Properties['RootKnown'] -and -not [bool]$Lifecycle.RootKnown) {
        # The word 'absent' is DELIBERATELY not used here. Nothing was found, but the search ran
        # under a substituted root, so this reader cannot tell an uncaptured signal from a signal
        # it failed to locate -- and it says so instead of picking the flattering reading.
        # The words 'absent' and '(absent)' are DELIBERATELY not used anywhere in this branch, not
        # even to say what is NOT being claimed. A reader grepping the readout for the absent
        # rendering must not match on prose that merely mentions it -- that is the same
        # self-documenting-needle trap the ledger's own guards are written to avoid.
        $lines += '  lifecycle logs read: NONE FOUND, under a FALLBACK data root -- CANNOT DETERMINE whether the'
        $lines += '    signal was never captured or merely not found here. fixed_next_turn_rate and'
        $lines += '    persistence_rate render (unresolvable), and NEVER 0.'
        $lines += '    Set CLAUDE_PLUGIN_DATA to the real data root and re-run to get a determinate answer.'
    } else {
        $lines += '  lifecycle logs read: NONE -- fixed_next_turn_rate and persistence_rate render (absent), not 0.'
    }
    $lines += ''

    $rows = @($Ledger.Rows)
    $lines += ('  REAL-SIGNAL LEDGER -- synthetic occurrences EXCLUDED. ' +
        [string]$Ledger.TotalRealOccurrences + ' occurrences / ' + [string]$Ledger.TotalRealShapes +
        ' shapes / ' + [string]$rows.Count + ' rules.')
    if ($rows.Count -eq 0) {
        $lines += '  (no real-signal occurrences -- the ledger is EMPTY, which is a measurement, not an error.)'
    } else {
        $lines += ('  {0,-44} {1,-12} {2,-15} {3,-46} {4,-24} {5,-20} {6}' -f 'ruleId', 'fired_count', 'distinct_shapes',
            'source_split', 'verdict_distribution', 'fixed_next_turn_rate', 'persistence_rate')
        foreach ($r in $rows) {
            $lines += ('  {0,-44} {1,-12} {2,-15} {3,-46} {4,-24} {5,-20} {6}' -f
                [string]$r.ruleId, [int]$r.fired_count, [int]$r.distinct_shapes,
                (Format-LedgerMap -Map $r.source_split), (Format-LedgerMap -Map $r.verdict_distribution),
                (Format-LedgerRate -Rate $r.fixed_next_turn_rate), (Format-LedgerRate -Rate $r.persistence_rate))
        }
    }
    $lines += ''
    $lines += ('  SYNTHETIC (test-harness / Pester captures) -- reported separately, NEVER folded into the ' +
        'figures above: ' + [string]$Ledger.Synthetic.occurrences + ' occurrences / ' +
        [string]$Ledger.Synthetic.shapes + ' shapes / ' + [string]$Ledger.Synthetic.rules + ' rules.')

    # BOTH DENOMINATORS, side by side (dispatch 000171 leg 4). The union read deliberately spans
    # every version ever installed, so it inherits rules that no longer ship. Neither figure is
    # "the" denominator -- which is why both are printed and neither replaces the other.
    if ($null -ne $Attribution) {
        $lines += ''
        $lines += '  RULE-SURFACE ATTRIBUTION -- both denominators, neither replaces the other:'
        # THE THREE NUMBERS (dispatch 000185, ND-C). gross = net + unattributable. A net figure
        # that hides what it could not attribute is the same defect one level up, so the remainder
        # is printed beside it rather than folded into either side.
        $lines += ('    GROSS          (every real occurrence)          : ' + [string]$Attribution.Gross + ' occurrences')
        $lines += ('    NET            (attributable by this mechanism) : ' + [string]$Attribution.Net + ' occurrences')
        $lines += ('    UNATTRIBUTABLE (this table cannot represent it) : ' + [string]$Attribution.Unattributable + ' occurrences')
        $lines += '      ^ gross = net + unattributable, exactly. The remainder is REPORTED, never absorbed.'
        $lines += ''
        $lines += ('    of the NET figure -- in the CURRENT shipped rule surface : ' + [string]$Attribution.InCurrentSurface + ' occurrences')
        $lines += ('    of the NET figure -- rule NO LONGER in the surface       : ' + [string]$Attribution.OutOfCurrentSurface + ' occurrences')
        if (@($Attribution.OutOfSurfaceRules).Count -gt 0) {
            $lines += ('      rules: ' + (@($Attribution.OutOfSurfaceRules) -join ', '))
        }
        $lines += ('    surface history: ' + [string]$Attribution.HistoryVersions + ' versions known; ' +
            [string]$Attribution.UnknownPartition + ' occurrences from a partition the history does not cover')
        # The UNATTRIBUTABLE bucket, itemized. Until dispatch 000185 these occurrences were counted
        # IN-surface, which made the out-of-surface category unreachable for them by construction --
        # the reported figure read as a measured zero when it was never tested.
        $lines += ('    NOTE: the ' + [string]$Attribution.Unattributable + ' UNATTRIBUTABLE occurrences are OWNED FINDERS or ' +
            'parser diagnostics. rulesets/base.psd1 records')
        $lines += '          PSScriptAnalyzer rules only, so a finder whose rule id still ships but one of whose'
        $lines += '          internal RUNGS was removed is NOT distinguishable from this table alone. That case is'
        $lines += '          real (dispatch 000162). They are NOT counted in-surface and NOT counted out-of-surface:'
        $lines += '          this mechanism has no evidence either way, and says so.'
        foreach ($u in @($Attribution.UnattributableRules)) {
            $lines += ('            ' + [string]$u.ruleId + '  ' + [string]$u.occurrences + ' occurrences')
        }
    }
    return ($lines -join [Environment]::NewLine)
}

# ===========================================================================
# Entry point -- runs ONLY on direct invocation (pwsh -File ...), not when dot-sourced.
# ===========================================================================
if ($MyInvocation.InvocationName -ne '.') {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $sources = Resolve-RuleLedgerSources -Source $script:LedgerArgSource -Path $script:LedgerArgPath `
        -CacheRoot $script:LedgerArgCacheRoot

    # Exit 4 -- union discovery found no per-version cache directory at all. Distinct from "the
    # directories exist and hold nothing": there is no denominator to speak of, so any ledger printed
    # here would be a claim about data that was never looked for.
    if ([bool]$sources.UnionAttempted -and @($sources.VersionDirs).Count -eq 0) {
        Write-Host ('LEDGER FAILURE: union discovery found ZERO per-version cache directories under the plugin ' +
            'cache root. This is not a zero-row ledger -- nothing was found to read. ' + $sources.Discovery)
        exit 4
    }

    $ledgerInput = Read-RuleLedgerInput -LogPaths @($sources.LogPaths) `
        -AnnotationsPath $script:LedgerArgAnnotationsPath

    # Exit 3 -- every selected log is absent or empty. Never render this as a ledger of zeros.
    if (@($ledgerInput.NonEmptyLogs).Count -eq 0) {
        Write-Host ('LEDGER FAILURE: no selected diagnostics log exists with at least one record. ' +
            'An absent or empty log is NOT a zero-row ledger. ' + $sources.Discovery)
        foreach ($l in @($sources.LogPaths)) { Write-Host ('  selected: ' + [string]$l) }
        if (@($sources.LogPaths).Count -eq 0) { Write-Host '  selected: (none)' }
        exit 3
    }

    # The lifecycle sibling log (dispatch 000171 leg 2). Its ABSENCE is NOT an error and must not
    # be one: the capture log and the lifecycle log have independent lifetimes, and a ledger over
    # captures alone is still a valid ledger -- it simply renders the two lifecycle columns as
    # (absent). Only the capture log carries the exit-3 / exit-4 never-a-silent-skip contract.
    # Resolved through the provenance-carrying seam (dispatch 000185, D1-B) so a NOT-FOUND result
    # knows whether it searched the real data root or a silent temp substitute.
    $lifecycleSearch = Resolve-LifecycleLogSearch -LifecyclePath $script:LedgerArgLifecyclePath
    $lifecycle = Read-LifecycleLog -LogPaths @($lifecycleSearch.Paths) -Search $lifecycleSearch

    $ledger = Get-RuleEfficacyLedger -Occurrences @($ledgerInput.Occurrences) -Annotations $ledgerInput.Annotations `
        -Lifecycle $lifecycle

    # Rule-surface attribution over the REAL-signal occurrences only, so the two denominators are
    # directly comparable with the ledger's own headline figure (which also excludes synthetic).
    $history = Import-SurfaceHistory
    $currentSurface = @()
    try {
        $basePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'rulesets/base.psd1'
        if (Test-Path -LiteralPath $basePath -PathType Leaf) {
            $currentSurface = @([regex]::Matches((Get-Content -LiteralPath $basePath -Raw), "(?m)^\s*'(P[A-Za-z0-9]+)'") |
                ForEach-Object { $_.Groups[1].Value })
        }
    } catch { $currentSurface = @() }
    $realOcc = @(@($ledgerInput.Occurrences) | Where-Object { $script:LedgerRealBuckets -contains [string]$_.bucket })
    $attribution = Get-SurfaceAttribution -Occurrences $realOcc -CurrentSurface $currentSurface -History $history

    Write-Host (Format-RuleEfficacyLedger -Ledger $ledger -Sources $sources -LedgerInput $ledgerInput `
            -Lifecycle $lifecycle -Attribution $attribution)
    exit 0
}
