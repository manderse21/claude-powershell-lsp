#Requires -Version 5.1

# dogfood-reader.psm1 -- the dogfood capture/annotation READER, as a MODULE (dispatch 000156).
#
# WHY THIS FILE EXISTS. These functions used to live in scripts/review-dogfood.ps1, which is an
# ENTRY POINT: it carries a param() block, does IO, and exits. Reusing its functions meant
# dot-sourcing it -- and dot-sourcing a .ps1 RUNS its param() block in the CALLER's scope,
# silently resetting the caller's own $Path / $Source / $AnnotationsPath to review-dogfood's
# defaults. scripts/rule-efficacy-ledger.ps1 hit exactly that and had to capture its arguments
# into $script:LedgerArg* BEFORE the dot-source to survive it. That workaround is what a
# structural defect looks like from the inside.
#
# A file cannot be both an entry point and a library. This module is the library half; the
# entry point half stays in review-dogfood.ps1 as a thin caller. A module gives REAL scope
# isolation (nothing leaks into a caller by construction) and an EXPLICIT export surface.
#
# THE EXPORT SURFACE IS EXACTLY WHAT SHIPPED CALLERS INVOKE -- eleven functions. It is NOT
# widened to suit tests: the ten reader functions no shipped caller invokes stay PRIVATE and
# the suite reaches them with Pester 5's InModuleScope. Exporting a function to keep a test
# green would let test convenience shape the public API, which is a worse boundary than the
# dot-source hazard it replaced (dispatch 000156 boundary B1).
#
# RESOLUTION: callers import this by a $PSScriptRoot-relative path. No PSModulePath
# manipulation, no absolute path, no environment variable -- the plugin runs from the
# marketplace cache, not a checkout and not a module directory (dispatch 000156 boundary B3).
#
# ASCII-only (PS 5.1 reads a UTF-8-without-BOM file through the Windows-1252 codepage; keep to
# bytes 0x00-0x7F -- "--" not an em-dash, straight quotes only).
#
# Author: Mike Andersen / powershell-lsp plugin.

# Get-Prop and Get-DogfoodLogPath. Dot-sourced INSIDE the module, so they land in module scope
# and are not re-exported -- the caller's scope is untouched either way.
. (Join-Path $PSScriptRoot 'lsp-common.ps1')

# STRICTMODE IS SET HERE ON PURPOSE, AND IT IS A CONTRACT-PRESERVING LINE -- do not remove it.
# These functions used to be defined in review-dogfood.ps1's own scope, whose entry point runs
# `Set-StrictMode -Version Latest` before calling any of them, so they have ALWAYS executed under
# Latest. Module scope does NOT inherit a caller's StrictMode, so without this line the exact same
# CLI invocation would run them unstrict and behave differently -- measurably so: the shipped
# `$toShow.Count` on a single pending shape throws under Latest and silently returns $null without
# it, flipping `review-dogfood.ps1 -Path <log>` from exit 1 to exit 0. That is a CLI contract
# change, so the strictness moves with the functions. (The underlying scalar-.Count defect is
# PRE-EXISTING and deliberately left untouched here -- dispatch 000156 is a restructuring, and it
# is recorded as a handoff rather than fixed in passing.)
Set-StrictMode -Version Latest

# ===========================================================================
# Frozen verdict vocabulary -- ONE source of truth, mirrored by the param ValidateSet in
# review-dogfood.ps1's param() block.
# ===========================================================================

$script:DogfoodVerdicts = @('useful', 'false-positive', 'noisy', 'bad-fix', 'unsure')

# Verdicts that flag a quality problem the wave acts on (ranked in the summary). 'useful' and
# 'unsure' are excluded: the first is the rule working, the second is not yet a judgment.
$script:DogfoodActionableVerdicts = @('false-positive', 'noisy', 'bad-fix')

function Get-DogfoodVerdicts {
    # The frozen verdict vocabulary, in its canonical display order.
    #
    # This EXISTS because the vocabulary is module state now. It used to be read directly as
    # `$script:DogfoodVerdicts` by scripts/rule-efficacy-ledger.ps1 -- which worked only because
    # dot-sourcing review-dogfood.ps1 leaked that variable into the ledger's own scope. That is the
    # same hazard class as the leaked param() block: a caller silently depending on a library's
    # internal state. A module cannot leak it, so the vocabulary is published as a function instead
    # of a variable, and the ledger asks for it rather than inheriting it.
    return $script:DogfoodVerdicts
}

function Test-DogfoodVerdict {
    # $true iff $Verdict is exactly one of the frozen vocabulary tokens. The write path gates on
    # this so a programmatic caller cannot persist an invented verdict (the param ValidateSet
    # already guards the CLI). Case-sensitive: the enum is lower-case by definition.
    param([string] $Verdict)
    return ($script:DogfoodVerdicts -ccontains $Verdict)
}

# ===========================================================================
# Pure readers -- parse the JSONL files into objects. No mutation, no I/O beyond the read; a
# missing file is empty, a malformed line is skipped. (Mirrors show-stats.ps1's tolerant read.)
# ===========================================================================

function Read-DogfoodLog {
    # Return the capture records (parsed PSCustomObjects) from a capture log, skipping blank /
    # malformed lines. Missing file -> empty array. Never throws.
    #
    # READS THE ROTATED FAMILY, OLDEST FIRST, ENDING WITH THE ACTIVE LOG (T6.4). The capture log
    # is now bounded by rotation, so the file named $LogPath holds only what has accrued since
    # the last rotation. Reading it alone would make the corpus appear to collapse the first
    # time the bound fired -- a reader-side false zero, which is exactly the failure this
    # module's own 000088 header exists to prevent. Get-CaptureLogFamily (lib/lsp-common.ps1)
    # enumerates the retained members; when nothing has rotated it returns just the active log,
    # so behaviour on an unrotated log is byte-identical to before.
    param([string] $LogPath)
    if ([string]::IsNullOrWhiteSpace($LogPath)) { return @() }
    $files = @()
    try { $files = @(Get-CaptureLogFamily -LogPath $LogPath) } catch { $files = @() }
    if ($files.Count -eq 0) {
        if (-not (Test-Path -LiteralPath $LogPath)) { return @() }
        $files = @($LogPath)
    }
    $out = @()
    foreach ($file in $files) {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        foreach ($line in @(Get-Content -LiteralPath $file -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $out += ($line | ConvertFrom-Json) } catch { }
        }
    }
    return @($out)
}

function Read-DogfoodAnnotations {
    # Return a hashtable hash -> latest annotation object from one annotations.jsonl. APPEND-ONLY
    # last-write-wins: a later line for the same hash supersedes an earlier one, so a corrected
    # verdict simply replaces the prior read value. Missing file -> empty hashtable. Never throws.
    param([string] $AnnotationsPath)
    $map = @{}
    if ([string]::IsNullOrWhiteSpace($AnnotationsPath) -or -not (Test-Path -LiteralPath $AnnotationsPath)) { return $map }
    foreach ($line in @(Get-Content -LiteralPath $AnnotationsPath -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $o = $line | ConvertFrom-Json
            $h = [string](Get-Prop $o 'hash')
            if (-not [string]::IsNullOrWhiteSpace($h)) { $map[$h] = $o }   # later line wins
        } catch { }
    }
    return $map
}

# ===========================================================================
# Pure shaping -- collapse occurrences to distinct shapes (keyed by hash), join verdicts, and
# compute the summary. The schema coupling (which fields a capture record carries) lives here.
# ===========================================================================

# THE EMPTY-COLLECTION GUARD (dispatch 000258) -- why every [object[]] param below opens with
#     $items = @()
#     if ($null -ne $X) { $items = @($X) }
# instead of the bare `@($X)` it used to use.
#
# A function that emits nothing returns AutomationNull, not an empty array. Read-DogfoodLog
# honestly returns @() for a missing log (line 88), and that becomes AutomationNull. Held in a
# VARIABLE it behaves: `@($var).Count` is 0, which is why this survived review for so long. But
# BOUND TO A TYPED [object[]] PARAMETER, AutomationNull converts to a real $null -- and `@($null)`
# is a ONE-ELEMENT array holding $null. The loop body then runs once on a null record, which is
# how a provably missing capture log rendered as `shapes: 1 distinct` (dispatch 000257 leg F).
#
# It is HOST-DIVERGENT: the unroll fires under pwsh 7 and not under Windows PowerShell 5.1, so the
# suite's 5.1 leg structurally cannot see it. That is why the guard is written out at every site
# rather than left to the host.
#
# THE GUARD IS A STATEMENT, NOT AN IF-EXPRESSION, AND THAT DISTINCTION IS THE WHOLE POINT.
# 000257 leg F proposed `$x = if ($null -eq $R) { @() } else { @($R) }`. That shape is ITSELF
# defective: assigning an if-EXPRESSION captures the branch's PIPELINE OUTPUT, and a branch whose
# body is `@()` emits nothing -- so the guard hands back the very AutomationNull it meant to
# remove, and the next `$x.Count` throws under StrictMode. Measured, pwsh 7.6.3:
#   $a = if ($true) { @() } else { @(1,2) }        -> $null -eq $a is True,  $a.Count THROWS
#   $b = @(); if ($false) { $b = @(1,2) }          -> $null -eq $b is False, $b.Count is 0
# `$x = @()` is a direct ARRAY-LITERAL assignment and is always a real zero-length object[]; only
# a function, pipeline, or if-EXPRESSION branch emitting nothing produces AutomationNull.
#
# For the same reason the guard is INLINE rather than a shared helper: a helper returning @() would
# return AutomationNull to its caller and reintroduce the hazard one call deeper.

function Get-DogfoodShapes {
    # Collapse capture records to DISTINCT shapes keyed by the shape-hash. Each shape carries a
    # representative occurrence (the FIRST seen: file/line/col/ruleId/source/severity/message/
    # snippet) plus the occurrence count -- frequency is the signal the quality wave ranks on.
    # Records missing a hash are bucketed by a synthetic key so nothing is silently dropped.
    param([object[]] $Records)
    $items = @()                                                   # empty-collection guard (000258)
    if ($null -ne $Records) { $items = @($Records) }
    $order = New-Object System.Collections.Generic.List[string]
    $byHash = @{}
    foreach ($r in $items) {
        $h = [string](Get-Prop $r 'hash')
        if ([string]::IsNullOrWhiteSpace($h)) { $h = '(no-hash)' }
        if (-not $byHash.ContainsKey($h)) {
            $order.Add($h) | Out-Null
            $byHash[$h] = [pscustomobject]@{
                hash     = $h
                ruleId   = [string](Get-Prop $r 'ruleId')
                source   = [string](Get-Prop $r 'source')
                severity = [string](Get-Prop $r 'severity')
                message  = [string](Get-Prop $r 'message')
                file     = [string](Get-Prop $r 'file')
                line     = [int](Get-Prop $r 'line')
                col      = [int](Get-Prop $r 'col')
                snippet  = [string](Get-Prop $r 'snippet')
                count    = 0
            }
        }
        $byHash[$h].count++
    }
    $shapes = @()
    foreach ($h in $order) { $shapes += $byHash[$h] }
    return @($shapes)
}

function Get-DogfoodPendingShapes {
    # Shapes whose hash carries NO verdict yet -- the resumable work-list. Order preserved.
    param([object[]] $Shapes, [hashtable] $Annotations)
    $ann = if ($null -eq $Annotations) { @{} } else { $Annotations }
    $items = @()                                                   # empty-collection guard (000258)
    if ($null -ne $Shapes) { $items = @($Shapes) }
    return @($items | Where-Object { -not $ann.ContainsKey([string]$_.hash) })
}

function Get-DogfoodSummary {
    # Compute the ranked readout the quality wave consumes. Joins verdicts (from annotations) to
    # the capture log (authoritative for ruleId + occurrence counts) on the shape-hash:
    #   - totalShapes / totalOccurrences     -- distinct shapes and raw occurrences in the log.
    #   - annotatedShapes / coveragePct      -- annotation coverage (distinct shapes judged).
    #   - byVerdict[v] = { shapes; occurrences }   -- counts per frozen verdict.
    #   - topRules = [ { ruleId; verdict-buckets; shapes; occurrences } ]  -- rules ranked by
    #     ACTIONABLE verdicts (false-positive / noisy / bad-fix), the wave's prioritized input.
    param([object[]] $Shapes, [hashtable] $Annotations)
    $ann = if ($null -eq $Annotations) { @{} } else { $Annotations }
    # Empty-collection guard (000258). The holding variable is NOT named $shapes: PowerShell
    # variable names are CASE-INSENSITIVE, so `$shapes = @()` would overwrite the PARAMETER
    # $Shapes before the next line could read it, and every non-empty log would summarize as
    # zero. Guard into a distinct name first, then hand it to $shapes in one assignment.
    $inShapes = @()
    if ($null -ne $Shapes) { $inShapes = @($Shapes) }
    $shapes = $inShapes

    $totalShapes = $shapes.Count
    $totalOcc = 0; foreach ($s in $shapes) { $totalOcc += [int]$s.count }

    # Per-verdict shape/occurrence tallies (every frozen verdict present, even at zero).
    $byVerdict = [ordered]@{}
    foreach ($v in $script:DogfoodVerdicts) { $byVerdict[$v] = [pscustomobject]@{ shapes = 0; occurrences = 0 } }

    # Per-rule actionable tally, for the ranking.
    $ruleAgg = @{}
    $annotatedShapes = 0
    foreach ($s in $shapes) {
        $h = [string]$s.hash
        if (-not $ann.ContainsKey($h)) { continue }
        $v = [string](Get-Prop $ann[$h] 'verdict')
        if (-not (Test-DogfoodVerdict $v)) { continue }   # ignore a stray out-of-enum value
        $annotatedShapes++
        $byVerdict[$v].shapes++
        $byVerdict[$v].occurrences += [int]$s.count

        if ($script:DogfoodActionableVerdicts -ccontains $v) {
            $rid = [string]$s.ruleId
            if ([string]::IsNullOrWhiteSpace($rid)) { $rid = '(parser/no-rule)' }
            if (-not $ruleAgg.ContainsKey($rid)) {
                $ruleAgg[$rid] = [pscustomobject]@{
                    ruleId = $rid; shapes = 0; occurrences = 0
                    'false-positive' = 0; noisy = 0; 'bad-fix' = 0
                }
            }
            $ruleAgg[$rid].shapes++
            $ruleAgg[$rid].occurrences += [int]$s.count
            $ruleAgg[$rid].$v++
        }
    }

    $coverage = if ($totalShapes -gt 0) { [int][Math]::Round(100.0 * $annotatedShapes / $totalShapes) } else { 0 }

    # Rank rules: most occurrences of an actionable verdict first, then most shapes, then name.
    $topRules = @($ruleAgg.Values | Sort-Object `
        @{ Expression = { [int]$_.occurrences }; Descending = $true }, `
        @{ Expression = { [int]$_.shapes }; Descending = $true }, `
        @{ Expression = { [string]$_.ruleId } })

    return [pscustomobject]@{
        totalShapes      = $totalShapes
        totalOccurrences = $totalOcc
        annotatedShapes  = $annotatedShapes
        pendingShapes    = ($totalShapes - $annotatedShapes)
        coveragePct      = $coverage
        byVerdict        = $byVerdict
        topRules         = $topRules
    }
}

# ===========================================================================
# Source split (dispatch 000088) -- an ADDED bucketing DIMENSION over the capture `file` path,
# ALONGSIDE the existing shape-hash / verdict / ruleId bucketing (which is left intact). Lifts the
# 000066/000084 inline path-pattern logic into this committed reader as the single source of truth,
# so the quality wave can tell real canonical source from worktrees/demos and from synthetic
# fixtures. That split lived only inside dispatch custom_checks before; here it is reusable tooling.
# ===========================================================================

function Get-DogfoodSourceBucket {
    # Classify ONE capture record's `file` into the source dimension. Three buckets:
    #   synthetic          harness build-temp and Pester fixture data ('*Temp?claude*',
    #                      '*psls-pester-data*'). Checked FIRST so a temp path that embeds the
    #                      mangled repo slug (e.g. ...\Temp\claude\C--...-nortam-claude-powershell-lsp\...)
    #                      cannot leak into the canonical bucket.
    #   canonical-checkout an edit of the real canonical checkout ('*nortam?claude-powershell-lsp?*').
    #   other-genuine      any other real path -- linked worktrees (pls-wt-*), the hub demo
    #                      recording, other repos -- AND the conservative default for an ambiguous
    #                      or empty path (dispatch 000088: never guess a path INTO canonical).
    # '?' is the single-char wildcard for the path separator, so every pattern matches '\' and '/'
    # alike: Windows captures carry '\', while the reader's own tests build paths with the platform
    # separator, so the classifier stays correct on all four CI legs (the 000044 portability lesson).
    param([string] $File)
    $f = [string]$File
    if ([string]::IsNullOrWhiteSpace($f)) { return 'other-genuine' }
    if (($f -like '*Temp?claude*') -or ($f -like '*psls-pester-data*')) { return 'synthetic' }
    if ($f -like '*nortam?claude-powershell-lsp?*') { return 'canonical-checkout' }
    return 'other-genuine'
}

function Get-DogfoodSourceSplit {
    # The source-dimension tally. Classify EACH capture record's `file` PER-RECORD (not per-shape):
    # a shape-hash is (ruleId + normalized line), so the same hash can occur across two files, and a
    # per-shape classification would mis-attribute one file's occurrences to the other's bucket.
    # Counts occurrences (raw records) and distinct shapes (by hash) per bucket. Returns an ordered
    # map bucket -> { occurrences; shapes } with all three buckets present (even at zero), in a fixed
    # display order. Pure; no I/O. The shape-hash / verdict / ruleId bucketing is untouched.
    param([object[]] $Records)
    $out = [ordered]@{}
    $seen = @{}
    foreach ($b in @('canonical-checkout', 'other-genuine', 'synthetic')) {
        $out[$b] = [pscustomobject]@{ occurrences = 0; shapes = 0 }
        $seen[$b] = @{}
    }
    $items = @()                                                   # empty-collection guard (000258)
    if ($null -ne $Records) { $items = @($Records) }
    foreach ($r in $items) {
        $bucket = Get-DogfoodSourceBucket -File ([string](Get-Prop $r 'file'))
        $out[$bucket].occurrences++
        $h = [string](Get-Prop $r 'hash')
        if ([string]::IsNullOrWhiteSpace($h)) { $h = '(no-hash)' }
        if (-not $seen[$bucket].ContainsKey($h)) { $seen[$bucket][$h] = $true; $out[$bucket].shapes++ }
    }
    return $out
}

# ===========================================================================
# Pure persistence model -- build + locate + append annotations. Keyed on the shape-hash.
# ===========================================================================

function Get-DogfoodAnnotationsPath {
    # The annotations file beside the diagnostics log (same already-gitignored dogfood/ dir):
    # <logdir>/annotations.jsonl. Falls back to the bare name when the log has no directory.
    param([string] $LogPath)
    if ([string]::IsNullOrWhiteSpace($LogPath)) { return 'annotations.jsonl' }
    $dir = Split-Path -Parent $LogPath
    if ([string]::IsNullOrWhiteSpace($dir)) { return 'annotations.jsonl' }
    return (Join-Path $dir 'annotations.jsonl')
}

function New-DogfoodAnnotation {
    # Build one annotation record (ordered, for stable on-disk key order). Keyed by hash; ruleId
    # is denormalized in for a self-describing file (a rule code, never source). $Now lets a test
    # pin the timestamp; default is the call time.
    param(
        [Parameter(Mandatory = $true)][string] $Hash,
        [Parameter(Mandatory = $true)][string] $Verdict,
        [string] $RuleId = '',
        [string] $Rationale = '',
        [string] $Now = ''
    )
    if (-not (Test-DogfoodVerdict $Verdict)) {
        throw ("invalid verdict '" + $Verdict + "' -- must be one of: " + ($script:DogfoodVerdicts -join ', '))
    }
    $ts = if ([string]::IsNullOrWhiteSpace($Now)) { (Get-Date -Format 'o') } else { $Now }
    return [ordered]@{
        hash      = $Hash
        ruleId    = $RuleId
        verdict   = $Verdict
        rationale = $Rationale
        ts        = $ts
    }
}

function Add-DogfoodAnnotation {
    # Append one annotation as a JSONL line (UTF-8 no BOM, explicit LF), creating the directory
    # if needed. NON-destructive (append only). Unlike the fail-safe capture writer, this is an
    # EXPLICIT user action, so a real write failure propagates (the caller runs under Stop). The
    # snippet is never written here; only hash/ruleId/verdict/rationale/ts.
    param([string] $AnnotationsPath, $Annotation)
    $dir = Split-Path -Parent $AnnotationsPath
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-ContainedDirectory -Path $dir
    }
    $line = ($Annotation | ConvertTo-Json -Depth 5 -Compress)
    $enc = New-Object System.Text.UTF8Encoding($false)
    # Contain on the absent->present transition only -- see Write-StatsLine (000277 leg C).
    $bornHere = -not (Test-Path -LiteralPath $AnnotationsPath)
    [System.IO.File]::AppendAllText($AnnotationsPath, ($line + "`n"), $enc)
    if ($bornHere) { [void](Set-ContainedFileMode -Path $AnnotationsPath) }
}

function Set-DogfoodVerdict {
    # Record (or correct) the verdict for one shape-hash. IDEMPOTENT: if the latest stored
    # annotation for this hash already has the SAME (verdict, rationale), it is a no-op (no
    # duplicate line). Otherwise a new annotation is appended (last-write-wins on read). Returns
    # 'written' or 'unchanged'. RuleId is resolved from the capture log for the self-describing
    # file; it is informational only (the key is the hash).
    param(
        [string] $LogPath,
        [string] $AnnotationsPath,
        [Parameter(Mandatory = $true)][string] $Hash,
        [Parameter(Mandatory = $true)][string] $Verdict,
        [string] $Rationale = ''
    )
    if (-not (Test-DogfoodVerdict $Verdict)) {
        throw ("invalid verdict '" + $Verdict + "' -- must be one of: " + ($script:DogfoodVerdicts -join ', '))
    }
    $existing = Read-DogfoodAnnotations -AnnotationsPath $AnnotationsPath
    if ($existing.ContainsKey($Hash)) {
        $cur = $existing[$Hash]
        if (([string](Get-Prop $cur 'verdict') -ceq $Verdict) -and ([string](Get-Prop $cur 'rationale') -ceq $Rationale)) {
            return 'unchanged'
        }
    }
    # Resolve the rule id for this hash from the capture log (best-effort, informational).
    $ruleId = ''
    foreach ($r in (Read-DogfoodLog -LogPath $LogPath)) {
        if (([string](Get-Prop $r 'hash')) -eq $Hash) { $ruleId = [string](Get-Prop $r 'ruleId'); break }
    }
    $ann = New-DogfoodAnnotation -Hash $Hash -Verdict $Verdict -RuleId $ruleId -Rationale $Rationale
    Add-DogfoodAnnotation -AnnotationsPath $AnnotationsPath -Annotation $ann
    return 'written'
}

# ===========================================================================
# Rendering -- ASCII, Write-Host-free (returns strings so callers/tests can capture). Snippet
# redaction masks the only field that can carry source content.
# ===========================================================================

function Format-DogfoodSnippet {
    # The snippet for display: verbatim, or masked to '[redacted N chars]' when -Redact is set so
    # a shared listing leaks no source. An empty snippet renders as '(no snippet)'.
    param([string] $Snippet, [switch] $Redact)
    if ([string]::IsNullOrEmpty($Snippet)) { return '(no snippet)' }
    if ($Redact) { return ('[redacted ' + $Snippet.Length + ' chars]') }
    return $Snippet
}

function Format-DogfoodShape {
    # One shape as a short multi-line block: header (rule/source/severity/count + verdict if any)
    # then location, message, snippet, and the hash (the key a -Hash write needs). Returns the
    # joined string.
    param($Shape, [hashtable] $Annotations, [switch] $Redact)
    $ann = if ($null -eq $Annotations) { @{} } else { $Annotations }
    $h = [string]$Shape.hash
    $rule = if ([string]::IsNullOrWhiteSpace([string]$Shape.ruleId)) { '(parser/no-rule)' } else { [string]$Shape.ruleId }
    $verdictStr = '(pending)'
    if ($ann.ContainsKey($h)) {
        $v = [string](Get-Prop $ann[$h] 'verdict')
        $rat = [string](Get-Prop $ann[$h] 'rationale')
        $verdictStr = $v
        if (-not [string]::IsNullOrWhiteSpace($rat)) { $verdictStr += (' -- ' + $rat) }
    }
    $occ = if ([int]$Shape.count -eq 1) { '1 occurrence' } else { ([string][int]$Shape.count + ' occurrences') }
    $lines = @()
    $lines += ('  ' + $rule + '  [' + [string]$Shape.source + '/' + [string]$Shape.severity + ']  ' + $occ + '   verdict: ' + $verdictStr)
    $lines += ('      at ' + [string]$Shape.file + ':' + [string]$Shape.line + ':' + [string]$Shape.col)
    if (-not [string]::IsNullOrWhiteSpace([string]$Shape.message)) { $lines += ('      msg: ' + [string]$Shape.message) }
    $lines += ('      src: ' + (Format-DogfoodSnippet -Snippet ([string]$Shape.snippet) -Redact:$Redact))
    $lines += ('      hash: ' + $h)
    return ($lines -join [Environment]::NewLine)
}

function Format-DogfoodSummary {
    # The ranked readout (counts by verdict, annotation coverage, the source split, and top
    # actionable rules) as a joined string, in the show-stats.ps1 idiom. $LogPath (and the effective
    # $SourceLabel, dispatch 000088) are echoed so the readout is self-locating. $SourceSplit, when
    # provided, renders the added source dimension; omitting it keeps the pre-000088 readout.
    param($Summary, [string] $LogPath = '', $SourceSplit = $null, [string] $SourceLabel = '')
    $lines = @()
    $header = 'powershell-lsp dogfood review -- ' + $LogPath
    if (-not [string]::IsNullOrWhiteSpace($SourceLabel)) { $header += ('  [source: ' + $SourceLabel + ']') }
    $lines += $header
    if ([int]$Summary.totalShapes -eq 0) {
        $lines += '  no diagnostics captured yet (edit some PowerShell with the plugin enabled, then re-run).'
        return ($lines -join [Environment]::NewLine)
    }
    $lines += ('  shapes: ' + $Summary.totalShapes + ' distinct   occurrences: ' + $Summary.totalOccurrences)
    $lines += ('  coverage: ' + $Summary.annotatedShapes + '/' + $Summary.totalShapes +
        ' shapes annotated (' + $Summary.coveragePct + '%)   pending: ' + $Summary.pendingShapes)
    if ($null -ne $SourceSplit) {
        $lines += ''
        $lines += ('  {0,-20} {1,-8} {2}' -f 'by source', 'occ', 'shapes')
        foreach ($b in @('canonical-checkout', 'other-genuine', 'synthetic')) {
            $row = $SourceSplit[$b]
            $occ = if ($null -ne $row) { [int]$row.occurrences } else { 0 }
            $shp = if ($null -ne $row) { [int]$row.shapes } else { 0 }
            $lines += ('  {0,-20} {1,-8} {2}' -f $b, $occ, $shp)
        }
    }
    $lines += ''
    $lines += ('  {0,-16} {1,-8} {2}' -f 'verdict', 'shapes', 'occurrences')
    foreach ($v in $script:DogfoodVerdicts) {
        $row = $Summary.byVerdict[$v]
        $lines += ('  {0,-16} {1,-8} {2}' -f $v, [int]$row.shapes, [int]$row.occurrences)
    }
    $lines += ''
    if (@($Summary.topRules).Count -eq 0) {
        $lines += '  top actionable rules: none yet (no false-positive / noisy / bad-fix verdicts recorded).'
    } else {
        $lines += '  top actionable rules (false-positive / noisy / bad-fix), most occurrences first:'
        $lines += ('    {0,-40} {1,-7} {2,-6} {3}' -f 'rule', 'occ', 'shapes', 'fp/noisy/bad-fix')
        foreach ($r in $Summary.topRules) {
            $mix = ([string][int]$r.'false-positive' + '/' + [string][int]$r.noisy + '/' + [string][int]$r.'bad-fix')
            $lines += ('    {0,-40} {1,-7} {2,-6} {3}' -f ([string]$r.ruleId), [int]$r.occurrences, [int]$r.shapes, $mix)
        }
    }
    return ($lines -join [Environment]::NewLine)
}

# ===========================================================================
# Reader-side log-source resolution (dispatch 000088). The reader can read a DIFFERENT log than
# the running tree's: under normal installed use the LIVE hook writes to the INSTALLED
# marketplace-cache log (Claude Code sets CLAUDE_PLUGIN_ROOT to the cache tree), so a review run
# from the dev checkout would otherwise resolve the EMPTY checkout log and see zero real captures.
#
# THE READ-SIDE / WRITE-SIDE BOUNDARY (load-bearing): the hook's capture/write path is UNCHANGED --
# Add-DiagnosticCaptureEntries still calls Get-DogfoodLogPath (lib/lsp-common.ps1), whose write-side
# resolution is byte-for-byte untouched. This reader adds NEW discovery (Get-DogfoodCacheLogPath)
# and, for the 'checkout' source, REUSES Get-DogfoodLogPath in a READ-ONLY context. Nothing here
# changes where the hook writes.
# ===========================================================================

function Get-DefaultPluginCacheRoot {
    # The Claude Code plugin cache root: <home>/.claude/plugins/cache. Home is $env:USERPROFILE on
    # Windows, else $env:HOME. Returns '' when home cannot be resolved. No hardcoded user or version.
    $homeDir = if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { $env:USERPROFILE }
        elseif (-not [string]::IsNullOrWhiteSpace($env:HOME)) { $env:HOME }
        else { '' }
    if ([string]::IsNullOrWhiteSpace($homeDir)) { return '' }
    return (Join-Path $homeDir '.claude/plugins/cache')
}

function ConvertTo-CacheVersionKey {
    # A comparable [version] for a cache dir name. Parses '1.2.3' and the like; a non-semver name
    # yields 0.0.0 so any real version outranks it (the lexical tiebreak in Select-DogfoodCacheVersion
    # then decides among non-semver names). Pure -- the version is DERIVED from the name, never a
    # literal. TryParse keeps a junk dir name from throwing.
    param([string] $Text)
    $v = $null
    if ([System.Version]::TryParse([string]$Text, [ref] $v)) { return $v }
    return ([System.Version]'0.0.0')
}

function Select-DogfoodCacheVersion {
    # Pick the CURRENT installed cache log from candidate { Version; Path } objects: the greatest by
    # SEMANTIC version, breaking ties by lexically-greatest name. The version segment is thus chosen
    # deterministically and DISCOVERED from disk, never hardcoded -- so a fresh install at any future
    # version resolves with no code change. Returns the chosen .Path, or '' for no candidates. Pure.
    param([object[]] $Candidates)
    $c = @()                                                       # empty-collection guard (000258)
    if ($null -ne $Candidates) { $c = @($Candidates) }
    if ($c.Count -eq 0) { return '' }
    $sorted = @($c | Sort-Object `
            @{ Expression = { ConvertTo-CacheVersionKey ([string]$_.Version) }; Descending = $true }, `
            @{ Expression = { [string]$_.Version }; Descending = $true })
    return [string]$sorted[0].Path
}

function Get-DogfoodCacheLogPath {
    # READER-SIDE discovery of the INSTALLED marketplace-cache dogfood log -- independent of where
    # THIS reader runs from. Resolution rule (NO hardcoded version):
    #   1. CLAUDE_PLUGIN_ROOT (or -PluginRoot) when set -- Claude Code sets it for plugin
    #      subprocesses, the authoritative pointer at the running plugin tree. Use
    #      <root>/dogfood/diagnostics.jsonl when that file exists.
    #   2. else discover under the plugin cache tree
    #        <cache-root>/<marketplace>/powershell-lsp/<version>/dogfood/diagnostics.jsonl
    #      and choose the CURRENT <version> deterministically (Select-DogfoodCacheVersion: the
    #      highest semantic version that actually carries a log). <marketplace> and <version> are
    #      both discovered from disk; only the fixed plugin-name segment 'powershell-lsp' is literal.
    # Returns '' when no installed cache log can be found. A read-only locator -- its only I/O is
    # Test-Path / Get-ChildItem; it never writes and never touches the hook write-side.
    param([string] $PluginRoot = '', [string] $CacheRoot = '')
    $root = if (-not [string]::IsNullOrWhiteSpace($PluginRoot)) { $PluginRoot } else { $env:CLAUDE_PLUGIN_ROOT }
    if (-not [string]::IsNullOrWhiteSpace($root)) {
        $direct = Join-Path $root 'dogfood/diagnostics.jsonl'
        if (Test-Path -LiteralPath $direct -PathType Leaf) { return $direct }
    }
    $cacheDir = if (-not [string]::IsNullOrWhiteSpace($CacheRoot)) { $CacheRoot } else { Get-DefaultPluginCacheRoot }
    if ([string]::IsNullOrWhiteSpace($cacheDir) -or -not (Test-Path -LiteralPath $cacheDir)) { return '' }
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($mk in @(Get-ChildItem -LiteralPath $cacheDir -Directory -ErrorAction SilentlyContinue)) {
        $pluginDir = Join-Path $mk.FullName 'powershell-lsp'
        if (-not (Test-Path -LiteralPath $pluginDir -PathType Container)) { continue }
        foreach ($ver in @(Get-ChildItem -LiteralPath $pluginDir -Directory -ErrorAction SilentlyContinue)) {
            $log = Join-Path $ver.FullName 'dogfood/diagnostics.jsonl'
            if (Test-Path -LiteralPath $log -PathType Leaf) {
                $found.Add([pscustomobject]@{ Version = $ver.Name; Path = $log })
            }
        }
    }
    return (Select-DogfoodCacheVersion -Candidates $found.ToArray())
}

function Test-DogfoodLogNonEmpty {
    # $true iff the log -- or any RETAINED ROTATED MEMBER of its family (T6.4) -- holds at least one
    # non-blank line. -Source auto uses this to pick a rung only when it actually carries captures.
    #
    # The family matters here for the same reason it matters in Read-DogfoodLog: immediately after a
    # rotation the ACTIVE log is empty while the corpus is not, and testing the active file alone
    # would walk auto straight past a live data root down to a frozen pre-relocation log.
    param([string] $LogPath)
    if ([string]::IsNullOrWhiteSpace($LogPath)) { return $false }
    $files = @()
    try { $files = @(Get-CaptureLogFamily -LogPath $LogPath) } catch { $files = @() }
    if ($files.Count -eq 0) { $files = @($LogPath) }
    foreach ($file in $files) {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        foreach ($line in @(Get-Content -LiteralPath $file -ErrorAction SilentlyContinue)) {
            if (-not [string]::IsNullOrWhiteSpace($line)) { return $true }
        }
    }
    return $false
}

function Resolve-DogfoodLogSource {
    # Resolve WHICH log the reader reads, per -Source (dispatch 000088), plus the effective source
    # label (what 'auto' actually chose, for a self-locating readout). READ-SIDE only. Returns
    # { LogPath; Effective }:
    #   -Path <file>  wins over -Source -- honored verbatim (Effective 'path').
    #   data          -> Get-DogfoodLogPath -- the LIVE write target since the T2.3 relocation.
    #   cache         -> Get-DogfoodCacheLogPath (installed marketplace-cache log, pre-relocation).
    #   checkout      -> Get-LegacyDogfoodLogPath (the pre-relocation running-tree log, READ-ONLY).
    #   auto          -> data when non-empty, else cache when non-empty, else the checkout log.
    #
    # WHY 'auto' GAINED A RUNG (T2.3). The hook now writes under CLAUDE_PLUGIN_DATA. Had auto kept
    # its old cache-then-checkout order it would have gone on resolving a log that no longer
    # receives captures -- silently, and looking exactly like a healthy read of a stale corpus.
    # The data root is therefore tried FIRST, and the two pre-relocation locations are retained
    # below it so historical captures stay reachable rather than being orphaned by the move.
    # Neither of them is ever written again.
    param([string] $Source = 'auto', [string] $Path = '', [string] $CacheRoot = '')
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{ LogPath = $Path; Effective = 'path' }
    }
    switch ($Source) {
        'data' {
            return [pscustomobject]@{ LogPath = (Get-DogfoodLogPath); Effective = 'data' }
        }
        'cache' {
            return [pscustomobject]@{ LogPath = (Get-DogfoodCacheLogPath -CacheRoot $CacheRoot); Effective = 'cache' }
        }
        'checkout' {
            return [pscustomobject]@{ LogPath = (Get-LegacyDogfoodLogPath); Effective = 'checkout' }
        }
        default {
            $data = Get-DogfoodLogPath
            if (Test-DogfoodLogNonEmpty -LogPath $data) {
                return [pscustomobject]@{ LogPath = $data; Effective = 'auto->data' }
            }
            $cache = Get-DogfoodCacheLogPath -CacheRoot $CacheRoot
            if (Test-DogfoodLogNonEmpty -LogPath $cache) {
                return [pscustomobject]@{ LogPath = $cache; Effective = 'auto->cache' }
            }
            return [pscustomobject]@{ LogPath = (Get-LegacyDogfoodLogPath); Effective = 'auto->checkout' }
        }
    }
}

# ===========================================================================
# Compose -- load the log + annotations, then list / summarize / review / write. Separated from
# the entry point so a caller can drive it programmatically.
# ===========================================================================

function Resolve-DogfoodPaths {
    # Resolve the (log, annotations) path pair plus the effective source label. The LOG is chosen by
    # -Source (dispatch 000088): explicit -Path wins, else 'auto' prefers the installed cache log,
    # else 'cache'/'checkout' force one. Annotations default to the sibling file beside the log.
    param([string] $Path = '', [string] $AnnotationsPath = '', [string] $Source = 'auto')
    $resolved = Resolve-DogfoodLogSource -Source $Source -Path $Path
    $logPath = $resolved.LogPath
    $annPath = if (-not [string]::IsNullOrWhiteSpace($AnnotationsPath)) { $AnnotationsPath } else { Get-DogfoodAnnotationsPath -LogPath $logPath }
    return [pscustomobject]@{ LogPath = $logPath; AnnotationsPath = $annPath; Source = $resolved.Effective }
}

function Invoke-DogfoodReview {
    # Interactive verdict loop over pending shapes. GUARDED: on a non-interactive host it does
    # NOT block on input -- it returns $false so the caller falls back to the read-only listing.
    # Each accepted verdict is persisted immediately (resumable: quit anytime, progress is kept).
    # Returns $true when it ran the loop, $false when it declined (non-interactive).
    param([string] $LogPath, [string] $AnnotationsPath, [switch] $Redact)
    if (-not [Environment]::UserInteractive) { return $false }

    $records = Read-DogfoodLog -LogPath $LogPath
    $shapes = Get-DogfoodShapes -Records $records
    $ann = Read-DogfoodAnnotations -AnnotationsPath $AnnotationsPath
    $pending = @(Get-DogfoodPendingShapes -Shapes $shapes -Annotations $ann)
    if ($pending.Count -eq 0) {
        Write-Host 'All captured shapes already have a verdict. Nothing to review.'
        return $true
    }
    Write-Host ('Reviewing ' + $pending.Count + ' pending shape(s). Verdict keys: ' +
        '[u]seful [f]alse-positive [n]oisy [b]ad-fix [?]unsure  |  [s]kip  [q]uit')
    $map = @{ 'u' = 'useful'; 'f' = 'false-positive'; 'n' = 'noisy'; 'b' = 'bad-fix'; '?' = 'unsure' }
    $i = 0
    foreach ($shape in $pending) {
        $i++
        Write-Host ''
        Write-Host ('[' + $i + '/' + $pending.Count + ']')
        Write-Host (Format-DogfoodShape -Shape $shape -Annotations $ann -Redact:$Redact)
        $choice = (Read-Host 'verdict').Trim().ToLowerInvariant()
        if ($choice -eq 'q') { Write-Host 'Stopping; verdicts recorded so far are saved.'; break }
        if ($choice -eq 's' -or [string]::IsNullOrWhiteSpace($choice)) { Write-Host 'skipped.'; continue }
        if (-not $map.ContainsKey($choice)) { Write-Host ('unrecognized "' + $choice + '" -- skipped.'); continue }
        $v = $map[$choice]
        $rat = (Read-Host 'rationale (optional, one line)').Trim()
        $result = Set-DogfoodVerdict -LogPath $LogPath -AnnotationsPath $AnnotationsPath -Hash ([string]$shape.hash) -Verdict $v -Rationale $rat
        Write-Host ('  -> ' + $v + ' (' + $result + ')')
    }
    return $true
}

function Show-DogfoodListing {
    # Read-only render: the summary (with the dispatch 000088 source split), then the pending (or,
    # with -All, every) shape. Returns the joined string so tests can assert on it without capturing
    # host output. $SourceLabel is the effective source ('auto->cache' etc.) echoed in the header.
    param([string] $LogPath, [string] $AnnotationsPath, [switch] $All, [switch] $Redact, [switch] $SummaryOnly, [string] $SourceLabel = '')
    $records = Read-DogfoodLog -LogPath $LogPath
    $shapes = Get-DogfoodShapes -Records $records
    $ann = Read-DogfoodAnnotations -AnnotationsPath $AnnotationsPath
    $summary = Get-DogfoodSummary -Shapes $shapes -Annotations $ann
    $sourceSplit = Get-DogfoodSourceSplit -Records $records

    $blocks = @()
    $blocks += (Format-DogfoodSummary -Summary $summary -LogPath $LogPath -SourceSplit $sourceSplit -SourceLabel $SourceLabel)
    if ($SummaryOnly -or [int]$summary.totalShapes -eq 0) { return ($blocks -join [Environment]::NewLine) }

    $toShow = if ($All) { @($shapes) } else { @(Get-DogfoodPendingShapes -Shapes $shapes -Annotations $ann) }
    $blocks += ''
    if ($toShow.Count -eq 0) {
        $blocks += '  (no pending shapes -- every captured shape has a verdict; re-run with -All to see them.)'
    } else {
        $label = if ($All) { 'all shapes' } else { 'pending shapes' }
        $blocks += ('  ' + $label + ' (' + $toShow.Count + '):')
        foreach ($s in $toShow) {
            $blocks += ''
            $blocks += (Format-DogfoodShape -Shape $s -Annotations $ann -Redact:$Redact)
        }
        if (-not $All) {
            $blocks += ''
            $blocks += '  Record a verdict:  review-dogfood.ps1 -Hash <hash> -Verdict <useful|false-positive|noisy|bad-fix|unsure> [-Rationale "..."]'
            $blocks += '  Or interactively:  review-dogfood.ps1 -Review'
        }
    }
    return ($blocks -join [Environment]::NewLine)
}

# ===========================================================================
# EXPORT SURFACE -- exactly the functions shipped callers invoke, nothing more.
#   scripts/review-dogfood.ps1      : Resolve-DogfoodPaths, Set-DogfoodVerdict,
#                                     Invoke-DogfoodReview, Show-DogfoodListing
#   scripts/rule-efficacy-ledger.ps1: Read-DogfoodLog, Read-DogfoodAnnotations,
#                                     Get-DogfoodSourceBucket, Get-DogfoodAnnotationsPath,
#                                     Get-DogfoodCacheLogPath, Get-DefaultPluginCacheRoot,
#                                     Test-DogfoodVerdict, Get-DogfoodVerdicts
# Every OTHER function here is deliberately PRIVATE. Tests reach them via InModuleScope.
# ===========================================================================
Export-ModuleMember -Function 'Get-DefaultPluginCacheRoot',
'Get-DogfoodAnnotationsPath',
'Get-DogfoodCacheLogPath',
'Get-DogfoodSourceBucket',
'Get-DogfoodVerdicts',
'Invoke-DogfoodReview',
'Read-DogfoodAnnotations',
'Read-DogfoodLog',
'Resolve-DogfoodPaths',
'Set-DogfoodVerdict',
'Show-DogfoodListing',
'Test-DogfoodVerdict'
