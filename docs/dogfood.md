# Dogfood capture and review

Every diagnostic the plugin surfaces is also **teed to a local, append-only log** so the real
diagnostics from real day-to-day editing can drive the roadmap's quality work -- rule curation,
false-positive reduction, fix-suggestion quality -- ranked on evidence instead of guesses.

This page is the reference for that capture channel and for the offline tool that annotates it.
Neither changes what the daemon or hooks run, and neither alters the diagnostics surface.

## Capture

- **Where:** `dogfood/diagnostics.jsonl` under **`CLAUDE_PLUGIN_DATA`** -- the same data root that
  holds the logs, pids, session files and the vendored analyzer. Override with the
  `POWERSHELL_LSP_DOGFOOD_LOG` environment variable (a full path to the `.jsonl` file).

  > **Relocated (threat-model finding T2.3).** This log used to live in the **plugin tree**, which
  > `ARCHITECTURE.md`, `TRUST.md` and the shared library's own header all describe as read-only.
  > Writing it there contradicted that in both directions, so the log moved rather than the
  > documentation. A second problem closed with it: because the plugin tree is a *versioned*
  > marketplace-cache directory, every upgrade used to start an empty log and strand the previous
  > one, fragmenting the capture history the rule-curation lane depends on. The data root carries no
  > version segment, so captures now accrue in one place across upgrades.
  >
  > **Nothing was moved or deleted.** Pre-relocation logs stay exactly where they are and stay
  > readable -- `-Source cache` reaches the per-version cache logs and `-Source checkout` reaches a
  > running tree's log. Only the write target changed.

- **Bounded (threat-model finding T6.4):** the capture log is no longer unbounded. At session start,
  a log at or past **8 MB** is renamed to `diagnostics-<yyyyMMdd-HHmmss-fff>.jsonl`, which makes it a
  member of the same **stamped rolling family** the existing `keepLastN` log sweep already trims. The
  ceiling is therefore `(keepLastN + 1) x 8 MB` -- **88 MB** at the shipped default -- with no second
  retention policy to keep in step. Rotation preserves every byte (it renames, never truncates), and
  every reader reads the **whole retained family**, so bounding the log does not narrow what a review
  or the efficacy ledger can see. `POWERSHELL_LSP_CAPTURE_ROTATE_BYTES` overrides the threshold for
  testing; a non-numeric or non-positive value falls back to the default rather than disabling the
  bound.
- **What:** one JSON object per line, one line per diagnostic **occurrence** -- two identical
  diagnostics make two lines (frequency is the signal; de-duplication is an analysis-time concern,
  never a capture-time one). Each entry carries: `ts` (ISO-8601), `file`, `line`, `col`, `ruleId`
  (the PSScriptAnalyzer rule, or empty for a parser error), `source` (`PSScriptAnalyzer` or
  `parser`), `severity`, `message`, `snippet` (the full offending line), `hash` (a stable key over
  the rule id + the normalized offending-line shape, for analysis-time de-duplication), and
  `verdict` -- written **empty**, reserved for you to annotate later with
  `scripts/review-dogfood.ps1` (see [Review](#review) below).
- **Invisible side channel:** capture runs *after* the diagnostics are surfaced and is fully
  fail-safe. If the write fails for any reason, the diagnostics you see and the hook's exit code
  are byte-for-byte unchanged; logging never changes, reorders, delays, or gates what is surfaced.

> **Never commit this log.** It holds **real source snippets** from the files you edit. Since the
> T2.3 relocation it lives under `CLAUDE_PLUGIN_DATA`, outside every git tree, so it is now
> *structurally* uncommittable rather than merely ignored. The `/dogfood/` entry in `.gitignore` is
> retained because pre-relocation logs may still be sitting in a checkout -- do not weaken it.

## Review

The offline tool `scripts/review-dogfood.ps1` fills the empty `verdict` field that the capture
reserves. It never changes what the daemon or hooks run and never alters the diagnostics surface or
the capture log. Instead, it turns raw captured diagnostics into ranked input for the roadmap's
quality work (rule curation, false-positive reduction, fix quality).

- Collapses captured occurrences into distinct diagnostic **shapes**, keyed by the record's `hash`
  (rule id + normalized offending-line shape). Identical diagnostics share one verdict, so a misfire
  seen many times is judged once; re-runs skip shapes that already have a verdict (resumable).
- Fixed verdict vocabulary (lower-case): `useful` (true, actionable), `false-positive` (the rule
  misfired), `noisy` (correct but low-value / clutter), `bad-fix` (the finding is fine but its
  suggested correction is wrong / harmful), `unsure` (needs a second look). It is a fixed enum, not
  free text; an optional one-line rationale may accompany a verdict.
- **Persistence:** verdicts are written to a **separate sibling file**, `dogfood/annotations.jsonl`,
  keyed by the shape hash. Append-only, last-write-wins (a corrected verdict appends a new line;
  readers honor the latest). The capture log (`diagnostics.jsonl`) is never rewritten -- it stays
  immutable evidence.
- **Read-only by default:** with no write action the tool lists the pending shapes and prints a
  **summary** (counts by verdict, annotation coverage, the source split, and the top "actionable"
  rules -- those verdicted false-positive / noisy / bad-fix -- ranked by occurrence count). Writing a
  verdict is the explicit action.
- **Reading the right log (`-Source`):** by default (`-Source auto`) the reviewer reads the
  **data-root** log -- the one the live hook writes to since the T2.3 relocation -- when it exists and
  is non-empty; failing that the **installed marketplace-cache** log; failing that the running-tree
  (checkout) log. The lower two rungs are where captures landed *before* the relocation, and they are
  retained so that history stays readable rather than being orphaned by the move. Force one with
  `-Source data`, `-Source cache` or `-Source checkout`. The versioned cache path is **discovered**
  (it follows `CLAUDE_PLUGIN_ROOT` when set, else picks the current installed version under the plugin
  cache tree) -- never hardcoded. This is a read-side locator only; it never changes where the hook
  writes. Whichever rung is chosen, its **retained rotated members are read with it**, so the T6.4
  bound on the log is not a bound on what you can review.
- **Source split:** the summary also buckets captures **by source** -- `canonical-checkout` (edits of
  the real checkout), `other-genuine` (linked worktrees, the demo recording, other repos), and
  `synthetic` (temp / Pester-fixture paths) -- so the quality wave can tell real canonical source from
  the rest. An ambiguous path is classified conservatively (never as `canonical-checkout`).
- **Recording a verdict:** non-interactively with `-Hash <hash> -Verdict <verdict> [-Rationale
  "..."]`, or interactively with `-Review` (a guarded prompt loop over pending shapes; on a
  non-interactive host it falls back to the read-only listing instead of blocking).
- Use `-Redact` to mask the offending-line snippet in listings when sharing a review. Other flags:
  `-Summary` (summary only), `-All` (list every shape, not just pending), `-Source`
  (`auto` / `data` / `cache` / `checkout`), `-Path` and `-AnnotationsPath` (point at explicit files).

```text
pwsh -File scripts/review-dogfood.ps1
pwsh -File scripts/review-dogfood.ps1 -Summary
pwsh -File scripts/review-dogfood.ps1 -Source cache
pwsh -File scripts/review-dogfood.ps1 -Review
pwsh -File scripts/review-dogfood.ps1 -Hash <hash> -Verdict false-positive -Rationale "..."
```

> **Never commit the annotations file either.** It lives under the same already-gitignored
> `dogfood/` directory as the capture log, so the `.gitignore` already covers it -- do not weaken
> that entry. Its free-text rationale could quote source, so it stays local-only like the log.
