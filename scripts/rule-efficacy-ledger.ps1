#Requires -Version 5.1

# rule-efficacy-ledger.ps1 -- Arc A Slice A1: the READ-ONLY per-rule diagnostic efficacy ledger
# over the two shipped dogfood logs (dispatch 000153, chartered by the 000148 leg-2 survey).
#
# WHAT IT IS. A per-rule aggregation of what the plugin has already captured, keyed by `ruleId`,
# carrying EXACTLY the four reader-side columns the 000148 survey section (c) proved derivable
# from persisted data:
#
#   fired_count           capture occurrences per rule          diagnostics.jsonl (Add-DiagnosticCaptureEntries)
#   distinct_shapes       distinct shape-hash per rule          diagnostics.jsonl `.hash` / Get-DiagnosticShapeHash
#   source_split          per-record source bucket              Get-DogfoodSourceBucket over `.file`
#   verdict_distribution  annotation verdicts by shape-hash     annotations.jsonl `.verdict` (frozen enum)
#
# The survey's other two candidate columns -- fixed_next_turn_rate and persistence_rate -- are
# DELIBERATELY ABSENT. They derive from the closed-loop CLEARED / STILL-PRESENT signal, which
# Get-FindingLifecycleDiff computes and the daemon emits but NOTHING PERSISTS per-rule (it lives in
# daemon in-memory state, in the turn payload, and as a per-file aggregate debug line). A
# reader-side slice cannot populate them without a persistence change, which is a separately gated
# dispatch. Adding them here would mean inventing data.
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
# bucketing (Get-DogfoodSourceBucket, review-dogfood.ps1) are dot-sourced from where they already
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
# exercise the pure logic in isolation.
#
# Author: Mike Andersen / powershell-lsp plugin.

param(
    # Explicit diagnostics.jsonl to read. Overrides -Source entirely (honored verbatim).
    [string] $Path = '',

    # WHICH log(s) the ledger reads. All four are READ-ONLY resolutions; none affects where the
    # hook WRITES (Get-DogfoodLogPath's write-side is untouched):
    #   union     (default) EVERY per-version marketplace-cache log discovered, unioned -- so the
    #             denominator survives a plugin upgrade instead of resetting with the version dir.
    #   all       the union above PLUS the running-tree (checkout) log.
    #   cache     the single CURRENT cache log (Get-DogfoodCacheLogPath, reused unchanged).
    #   checkout  the running-tree log (Get-DogfoodLogPath, reused READ-ONLY, unchanged).
    # -Path always wins over -Source.
    [ValidateSet('union', 'all', 'cache', 'checkout')]
    [string] $Source = 'union',

    # Explicit annotations.jsonl to read. Default: the annotations.jsonl beside EACH resolved log
    # (unioned the same way the capture logs are).
    [string] $AnnotationsPath = '',

    # Override the plugin cache root for discovery (a test seam). Default: <home>/.claude/plugins/cache.
    [string] $CacheRoot = ''
)

# CAPTURE THE ARGUMENTS BEFORE THE DOT-SOURCE, and never read $Path / $Source / $AnnotationsPath
# again below. review-dogfood.ps1 has a `param()` block of its own carrying $Path, $Source and
# $AnnotationsPath, and dot-sourcing a script RUNS that param block in THIS scope -- silently
# resetting all three to its own defaults ($Path '', $Source 'auto'). Read after the dot-source,
# -Path is discarded and -Source reads 'auto', so the script quietly ignores its own arguments: the
# exact silent-wrong failure this tool exists to refuse. Capturing first is the fix; the four
# $Ledger* variables below are the only argument values the entry point trusts.
$script:LedgerArgPath = $Path
$script:LedgerArgSource = $Source
$script:LedgerArgAnnotationsPath = $AnnotationsPath
$script:LedgerArgCacheRoot = $CacheRoot

# Reuse the shipped readers and classifiers rather than re-implementing them. review-dogfood.ps1 is
# dot-source safe (its entry point is guarded), and it in turn dot-sources lib/lsp-common.ps1 -- so
# this one line brings in Read-DogfoodLog, Read-DogfoodAnnotations, Get-DogfoodSourceBucket,
# Get-DogfoodAnnotationsPath, Get-DogfoodCacheLogPath, Get-DefaultPluginCacheRoot, and (from
# lsp-common) Get-DiagnosticShapeHash, Get-DogfoodLogPath and Get-Prop.
. (Join-Path $PSScriptRoot 'review-dogfood.ps1')

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
        'checkout' {
            $one = Get-DogfoodLogPath
            return [pscustomobject]@{
                LogPaths       = @($one | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                VersionDirs    = @()
                Discovery      = 'running-tree log via Get-DogfoodLogPath (write-side resolver, reused READ-ONLY)'
                Mode           = 'checkout'
                UnionAttempted = $false
            }
        }
        default {
            # 'union' and 'all' share the cache enumeration; 'all' appends the checkout log.
            $dirs = @(Get-DogfoodCacheLogPathSet -CacheRoot $CacheRoot)
            $paths = @($dirs | Where-Object { $_.LogExists } | ForEach-Object { [string]$_.LogPath })
            $how = 'UNION of every per-version cache log under <cache-root>/<marketplace>/powershell-lsp/<version>/dogfood/diagnostics.jsonl (marketplace and version discovered from disk)'
            if ($Source -eq 'all') {
                $co = Get-DogfoodLogPath
                if (-not [string]::IsNullOrWhiteSpace($co) -and (Test-Path -LiteralPath $co -PathType Leaf)) {
                    $paths = @($paths) + @([string]$co)
                }
                $how += ', PLUS the running-tree log via Get-DogfoodLogPath'
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
    param([object[]] $Records)
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
    # Returns { Occurrences[]; Annotations{}; LogsRead[]; NonEmptyLogs[] }. Read-only.
    param([string[]] $LogPaths, [string] $AnnotationsPath = '')
    $occ = New-Object System.Collections.Generic.List[object]
    $ann = @{}
    $read = New-Object System.Collections.Generic.List[object]
    $nonEmpty = New-Object System.Collections.Generic.List[string]

    foreach ($lp in @($LogPaths)) {
        if ([string]::IsNullOrWhiteSpace($lp)) { continue }
        $records = @(Read-DogfoodLog -LogPath $lp)
        if ($records.Count -gt 0) { $nonEmpty.Add([string]$lp) | Out-Null }
        foreach ($o in @(ConvertTo-LedgerOccurrences -Records $records)) { $occ.Add($o) | Out-Null }
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
    return [pscustomobject]@{
        Occurrences  = @($occ.ToArray())
        Annotations  = $ann
        LogsRead     = @($read.ToArray())
        NonEmptyLogs = @($nonEmpty.ToArray())
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
    param([object[]] $Occurrences, [hashtable] $Annotations)
    $ann = if ($null -eq $Annotations) { @{} } else { $Annotations }

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
        # Render the frozen enum's own order, so two runs never disagree on column order.
        $ordered = [ordered]@{}
        foreach ($v in $script:DogfoodVerdicts) { if ($dist.Contains($v)) { $ordered[$v] = $dist[$v] } }
        $row.verdict_distribution = $ordered
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

function Format-RuleEfficacyLedger {
    # The full readout: what was read and how it was discovered, the per-rule table, and the
    # separately-labelled synthetic tally. Self-locating by construction -- every number is printed
    # next to the paths it came from, so a pasted readout can be re-derived.
    param($Ledger, $Sources, $LedgerInput)
    $lines = @()
    $lines += 'powershell-lsp per-rule diagnostic efficacy ledger (Arc A slice A1) -- facts only, no scores'
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
    $lines += ''

    $rows = @($Ledger.Rows)
    $lines += ('  REAL-SIGNAL LEDGER -- synthetic occurrences EXCLUDED. ' +
        [string]$Ledger.TotalRealOccurrences + ' occurrences / ' + [string]$Ledger.TotalRealShapes +
        ' shapes / ' + [string]$rows.Count + ' rules.')
    if ($rows.Count -eq 0) {
        $lines += '  (no real-signal occurrences -- the ledger is EMPTY, which is a measurement, not an error.)'
    } else {
        $lines += ('  {0,-44} {1,-12} {2,-15} {3,-46} {4}' -f 'ruleId', 'fired_count', 'distinct_shapes', 'source_split', 'verdict_distribution')
        foreach ($r in $rows) {
            $lines += ('  {0,-44} {1,-12} {2,-15} {3,-46} {4}' -f
                [string]$r.ruleId, [int]$r.fired_count, [int]$r.distinct_shapes,
                (Format-LedgerMap -Map $r.source_split), (Format-LedgerMap -Map $r.verdict_distribution))
        }
    }
    $lines += ''
    $lines += ('  SYNTHETIC (test-harness / Pester captures) -- reported separately, NEVER folded into the ' +
        'figures above: ' + [string]$Ledger.Synthetic.occurrences + ' occurrences / ' +
        [string]$Ledger.Synthetic.shapes + ' shapes / ' + [string]$Ledger.Synthetic.rules + ' rules.')
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

    $ledger = Get-RuleEfficacyLedger -Occurrences @($ledgerInput.Occurrences) -Annotations $ledgerInput.Annotations
    Write-Host (Format-RuleEfficacyLedger -Ledger $ledger -Sources $sources -LedgerInput $ledgerInput)
    exit 0
}
