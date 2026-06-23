#Requires -Version 5.1

# review-dogfood.ps1 -- annotate the dogfood diagnostic capture log (dispatch 000043).
#
# The capture side-channel (dispatch 000039) tees every surfaced diagnostic into a local,
# append-only dogfood/diagnostics.jsonl, each entry carrying an EMPTY `verdict` field reserved
# for exactly this tool. This reviewer FILLS that verdict: it reads the capture log, presents
# each distinct diagnostic SHAPE that still needs a verdict, accepts one verdict from a FROZEN
# small enum (with an optional one-line rationale), and PERSISTS it -- turning raw dogfood data
# into the ranked input the roadmap's quality wave consumes (rule curation -> false-positive
# reduction -> fix-suggestion quality).
#
# DESIGN DECISIONS (dispatch 000043):
#   - PERSISTENCE keys on the capture record's existing shape-hash (rule id + normalized
#     offending-line shape; see Get-DiagnosticShapeHash in lib/lsp-common.ps1). Identical
#     diagnostics share ONE verdict, so re-runs do not re-ask and the same misfire seen 30
#     times is judged once. The verdict lands in a SEPARATE sibling file
#     (dogfood/annotations.jsonl), NOT by rewriting diagnostics.jsonl in place:
#       * NON-DESTRUCTIVE -- a verdict is ADDED; no captured occurrence is ever overwritten,
#         reordered, or lost. The capture log stays the immutable evidence record.
#       * APPEND-ONLY, last-write-wins -- a corrected verdict appends a new line; readers honor
#         the latest annotation per hash. (An identical re-write is a no-op -- no duplicate.)
#       * RESUMABLE -- a re-run skips shapes that already carry a verdict.
#   - READ-ONLY by default. With no write action it only LISTS pending shapes and prints the
#     SUMMARY; writing a verdict is the explicit action (-Hash + -Verdict, or interactive
#     -Review).
#   - The FROZEN verdict enum (do not extend without a deliberate decision -- this is NOT the
#     000027 status taxonomy and adds NO userConfig knob):
#       useful          a true, actionable diagnostic -- the rule earned its keep here.
#       false-positive  wrong / not applicable -- the rule misfired.
#       noisy           technically correct but low value -- clutter, not worth surfacing.
#       bad-fix         the finding is fine but its suggested correction is wrong / harmful.
#       unsure          needs a second look -- parked, not yet judged.
#
# FENCES (dispatch 000043): this is an OFFLINE tool. It changes NOTHING the daemon or hooks run;
# diagnostics + capture are byte-for-byte unchanged. It COLLECTS verdicts only -- acting on them
# (tuning any rule) is the separate quality wave. The capture log holds REAL source snippets and
# stays gitignored; the annotations file lives under the same already-gitignored dogfood/ tree
# and is likewise NEVER committed (its free-text rationale could quote source). Use -Redact to
# mask snippets when sharing a listing.
#
# Usage:
#   pwsh -File scripts/review-dogfood.ps1                       # list pending + summary (read-only)
#   pwsh -File scripts/review-dogfood.ps1 -Summary             # summary only
#   pwsh -File scripts/review-dogfood.ps1 -Redact              # listing with snippets masked
#   pwsh -File scripts/review-dogfood.ps1 -All                 # list every shape (annotated too)
#   pwsh -File scripts/review-dogfood.ps1 -Review              # interactive verdict loop
#   pwsh -File scripts/review-dogfood.ps1 -Hash <h> -Verdict false-positive -Rationale '...'
#   pwsh -File scripts/review-dogfood.ps1 -Path X -AnnotationsPath Y   # explicit files
#
# Exit 0 on success (including an empty log). Throws (non-zero) only on a genuine write failure
# of an explicit annotation. Dot-source safe: dot-sourcing defines the functions without running
# anything, so the unit tests exercise the pure logic in isolation.
#
# Author: Mike Andersen / powershell-lsp plugin.

param(
    # Explicit diagnostics.jsonl to read. Default: Get-DogfoodLogPath (the plugin-tree log,
    # honoring the POWERSHELL_LSP_DOGFOOD_LOG override exactly as capture does).
    [string] $Path = '',

    # Explicit annotations.jsonl to read/write. Default: annotations.jsonl beside the log.
    [string] $AnnotationsPath = '',

    # Write action: the shape-hash to annotate. Requires -Verdict.
    [string] $Hash = '',

    # The verdict to record (frozen enum). Requires -Hash. ValidateSet gives a clean CLI error
    # on a typo; Test-DogfoodVerdict is the in-code single source of the same set.
    [ValidateSet('useful', 'false-positive', 'noisy', 'bad-fix', 'unsure')]
    [string] $Verdict = '',

    # Optional one-line rationale stored with an explicit verdict.
    [string] $Rationale = '',

    # Print only the summary readout (no per-shape listing).
    [switch] $Summary,

    # List every shape including already-annotated ones (default lists only pending shapes).
    [switch] $All,

    # Mask the offending-line snippet in listings (for sharing a review without leaking source).
    [switch] $Redact,

    # Interactive verdict loop over pending shapes. Guarded: a non-interactive host falls back
    # to the read-only listing rather than blocking on input.
    [switch] $Review
)

. (Join-Path $PSScriptRoot 'lib/lsp-common.ps1')

# ===========================================================================
# Frozen verdict vocabulary -- ONE source of truth, mirrored by the param ValidateSet above.
# ===========================================================================

$script:DogfoodVerdicts = @('useful', 'false-positive', 'noisy', 'bad-fix', 'unsure')

# Verdicts that flag a quality problem the wave acts on (ranked in the summary). 'useful' and
# 'unsure' are excluded: the first is the rule working, the second is not yet a judgment.
$script:DogfoodActionableVerdicts = @('false-positive', 'noisy', 'bad-fix')

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
    # Return the capture records (parsed PSCustomObjects) from one diagnostics.jsonl, skipping
    # blank / malformed lines. Missing file -> empty array. Never throws.
    param([string] $LogPath)
    if ([string]::IsNullOrWhiteSpace($LogPath) -or -not (Test-Path -LiteralPath $LogPath)) { return @() }
    $out = @()
    foreach ($line in @(Get-Content -LiteralPath $LogPath -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $out += ($line | ConvertFrom-Json) } catch { }
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

function Get-DogfoodShapes {
    # Collapse capture records to DISTINCT shapes keyed by the shape-hash. Each shape carries a
    # representative occurrence (the FIRST seen: file/line/col/ruleId/source/severity/message/
    # snippet) plus the occurrence count -- frequency is the signal the quality wave ranks on.
    # Records missing a hash are bucketed by a synthetic key so nothing is silently dropped.
    param([object[]] $Records)
    $order = New-Object System.Collections.Generic.List[string]
    $byHash = @{}
    foreach ($r in @($Records)) {
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
    return @(@($Shapes) | Where-Object { -not $ann.ContainsKey([string]$_.hash) })
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
    $shapes = @($Shapes)

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
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $line = ($Annotation | ConvertTo-Json -Depth 5 -Compress)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($AnnotationsPath, ($line + "`n"), $enc)
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
    # The ranked readout (counts by verdict, annotation coverage, top actionable rules) as a
    # joined string, in the show-stats.ps1 idiom. $LogPath is echoed so the readout is self-locating.
    param($Summary, [string] $LogPath = '')
    $lines = @()
    $lines += ('powershell-lsp dogfood review -- ' + $LogPath)
    if ([int]$Summary.totalShapes -eq 0) {
        $lines += '  no diagnostics captured yet (edit some PowerShell with the plugin enabled, then re-run).'
        return ($lines -join [Environment]::NewLine)
    }
    $lines += ('  shapes: ' + $Summary.totalShapes + ' distinct   occurrences: ' + $Summary.totalOccurrences)
    $lines += ('  coverage: ' + $Summary.annotatedShapes + '/' + $Summary.totalShapes +
        ' shapes annotated (' + $Summary.coveragePct + '%)   pending: ' + $Summary.pendingShapes)
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
# Compose -- load the log + annotations, then list / summarize / review / write. Separated from
# the entry point so a caller can drive it programmatically.
# ===========================================================================

function Resolve-DogfoodPaths {
    # Resolve the (log, annotations) path pair from the explicit params, falling back to
    # Get-DogfoodLogPath and the sibling annotations file. Returns a 2-field object.
    param([string] $Path = '', [string] $AnnotationsPath = '')
    $logPath = if (-not [string]::IsNullOrWhiteSpace($Path)) { $Path } else { Get-DogfoodLogPath }
    $annPath = if (-not [string]::IsNullOrWhiteSpace($AnnotationsPath)) { $AnnotationsPath } else { Get-DogfoodAnnotationsPath -LogPath $logPath }
    return [pscustomobject]@{ LogPath = $logPath; AnnotationsPath = $annPath }
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
    # Read-only render: the summary, then the pending (or, with -All, every) shape. Returns the
    # joined string so tests can assert on it without capturing host output.
    param([string] $LogPath, [string] $AnnotationsPath, [switch] $All, [switch] $Redact, [switch] $SummaryOnly)
    $records = Read-DogfoodLog -LogPath $LogPath
    $shapes = Get-DogfoodShapes -Records $records
    $ann = Read-DogfoodAnnotations -AnnotationsPath $AnnotationsPath
    $summary = Get-DogfoodSummary -Shapes $shapes -Annotations $ann

    $blocks = @()
    $blocks += (Format-DogfoodSummary -Summary $summary -LogPath $LogPath)
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
# Entry point -- runs ONLY on direct invocation (pwsh -File ...), not when dot-sourced (so the
# unit tests load the functions without doing any I/O).
# ===========================================================================
if ($MyInvocation.InvocationName -ne '.') {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $paths = Resolve-DogfoodPaths -Path $Path -AnnotationsPath $AnnotationsPath

    # Explicit write action: -Hash + -Verdict.
    if (-not [string]::IsNullOrWhiteSpace($Hash) -or -not [string]::IsNullOrWhiteSpace($Verdict)) {
        if ([string]::IsNullOrWhiteSpace($Hash) -or [string]::IsNullOrWhiteSpace($Verdict)) {
            throw 'Recording a verdict requires BOTH -Hash and -Verdict.'
        }
        $result = Set-DogfoodVerdict -LogPath $paths.LogPath -AnnotationsPath $paths.AnnotationsPath `
            -Hash $Hash -Verdict $Verdict -Rationale $Rationale
        Write-Host ('verdict ' + $Verdict + ' for ' + $Hash + ': ' + $result + ' -> ' + $paths.AnnotationsPath)
        exit 0
    }

    # Interactive review (guarded; falls back to listing on a non-interactive host).
    if ($Review) {
        $ran = Invoke-DogfoodReview -LogPath $paths.LogPath -AnnotationsPath $paths.AnnotationsPath -Redact:$Redact
        if ($ran) { exit 0 }
        Write-Host 'Non-interactive host -- showing the read-only listing instead of an input loop.'
    }

    # Default: read-only listing (+ summary), or summary only.
    Write-Host (Show-DogfoodListing -LogPath $paths.LogPath -AnnotationsPath $paths.AnnotationsPath `
            -All:$All -Redact:$Redact -SummaryOnly:$Summary)
    exit 0
}
