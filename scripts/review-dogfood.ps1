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
#   pwsh -File scripts/review-dogfood.ps1 -Source cache         # force the installed cache log
#   pwsh -File scripts/review-dogfood.ps1 -Source checkout      # force the running-tree log
#
# Exit 0 on success (including an empty log). Throws (non-zero) only on a genuine write failure
# of an explicit annotation.
#
# THIS FILE IS AN ENTRY POINT ONLY (dispatch 000156). Every reader/annotation function it used to
# define now lives in lib/dogfood-reader.psm1; this file keeps its param() block, its CLI contract
# and its entry-point logic, and nothing else. Reuse the functions by importing THAT module --
# never by dot-sourcing this script. Dot-sourcing a .ps1 runs its param() block in the caller's
# scope, so dot-sourcing this file to borrow a function silently reset the caller's own $Path /
# $Source / $AnnotationsPath to the defaults above. scripts/rule-efficacy-ledger.ps1 hit exactly
# that and carried a workaround for it; the module split is what removed the hazard rather than
# working around it.
#
# Author: Mike Andersen / powershell-lsp plugin.

param(
    # Explicit diagnostics.jsonl to read. Overrides -Source entirely (honored verbatim). Default
    # empty -- the log is then chosen by -Source below.
    [string] $Path = '',

    # WHICH dogfood log the reader reads (dispatch 000088; the 'data' rung added by T2.3).
    # READ-SIDE only -- this NEVER decides where the hook WRITES:
    #   auto      (default) the DATA-ROOT log when it exists and is non-empty -- the log the LIVE
    #             hook writes to since the T2.3 relocation -- else the installed marketplace-cache
    #             log, else the running-tree (checkout) log. The two lower rungs are where captures
    #             landed BEFORE the relocation and are retained so that history stays readable.
    #   data      force the data-root log under CLAUDE_PLUGIN_DATA (the live write target).
    #   cache     force the installed marketplace-cache log (the versioned path is DISCOVERED, never
    #             hardcoded; follows CLAUDE_PLUGIN_ROOT when set). PRE-RELOCATION history.
    #   checkout  force the running-tree log (Get-LegacyDogfoodLogPath, READ-ONLY). PRE-RELOCATION
    #             history; nothing writes there any more.
    # -Path always wins over -Source. Whichever log is chosen, its RETAINED ROTATED MEMBERS are
    # read with it (T6.4), so bounding the log is not a bound on what the reader can see.
    [ValidateSet('auto', 'data', 'cache', 'checkout')]
    [string] $Source = 'auto',

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

# The reader/annotation functions live in lib/dogfood-reader.psm1 (dispatch 000156). Import by a
# $PSScriptRoot-relative path: the plugin runs from the marketplace cache, not a checkout and not
# PSModulePath, so no absolute path and no environment variable can be involved. -Force keeps a
# re-run in one session honest; -DisableNameChecking suppresses the unapproved-verb warning that
# the shipped Show-/Add- verbs would otherwise print on every invocation under Windows PowerShell.
Import-Module (Join-Path $PSScriptRoot 'lib/dogfood-reader.psd1') -Force -DisableNameChecking

# ===========================================================================
# Entry point -- runs ONLY on direct invocation (pwsh -File ...). The guard is kept because it is
# this file's shipped behavior; the functions themselves now come from lib/dogfood-reader.psm1, so
# the unit tests import that module rather than loading this script at all.
# ===========================================================================
if ($MyInvocation.InvocationName -ne '.') {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $paths = Resolve-DogfoodPaths -Path $Path -AnnotationsPath $AnnotationsPath -Source $Source

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
            -All:$All -Redact:$Redact -SummaryOnly:$Summary -SourceLabel $paths.Source)
    exit 0
}
