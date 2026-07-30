# Dogfood capture and review

Every diagnostic the plugin surfaces is also **teed to a local, append-only log** so the real
diagnostics from real day-to-day editing can drive the roadmap's quality work -- rule curation,
false-positive reduction, fix-suggestion quality -- ranked on evidence instead of guesses.

This page is the reference for that capture channel and for the offline tool that annotates it.
Neither changes what the daemon or hooks run, and neither alters the diagnostics surface.

## Capture

- **Where:** `dogfood/diagnostics.jsonl` in the plugin tree. Override with the
  `POWERSHELL_LSP_DOGFOOD_LOG` environment variable (a full path to the `.jsonl` file).
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

> **Never commit this log.** It holds **real source snippets** from the files you edit. The whole
> `dogfood/` directory is gitignored (see `.gitignore`) and must never be staged, added, or
> committed -- do not weaken that entry.

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
  **installed marketplace-cache** log -- the one the live hook writes to under normal installed use --
  when it exists and is non-empty, so a review run from the dev checkout is not blind to the real
  captures; otherwise it falls back to the running-tree (checkout) log. Force one with `-Source cache`
  or `-Source checkout`. The versioned cache path is **discovered** (it follows `CLAUDE_PLUGIN_ROOT`
  when set, else picks the current installed version under the plugin cache tree) -- never hardcoded.
  This is a read-side locator only; it never changes where the hook writes.
- **Source split:** the summary also buckets captures **by source** -- `canonical-checkout` (edits of
  the real checkout), `other-genuine` (linked worktrees, the demo recording, other repos), and
  `synthetic` (temp / Pester-fixture paths) -- so the quality wave can tell real canonical source from
  the rest. An ambiguous path is classified conservatively (never as `canonical-checkout`).
- **Recording a verdict:** non-interactively with `-Hash <hash> -Verdict <verdict> [-Rationale
  "..."]`, or interactively with `-Review` (a guarded prompt loop over pending shapes; on a
  non-interactive host it falls back to the read-only listing instead of blocking).
- Use `-Redact` to mask the offending-line snippet in listings when sharing a review. Other flags:
  `-Summary` (summary only), `-All` (list every shape, not just pending), `-Source`
  (`auto` / `cache` / `checkout`), `-Path` and `-AnnotationsPath` (point at explicit files).

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
