# Contributing to powershell-lsp

Thanks for considering a contribution. This is a small, single-maintainer project (see
[CONTINUITY.md](./CONTINUITY.md) for what that honestly means); clear, well-tested,
narrowly-scoped changes are the easiest to accept.

## Before you start

- Read [ARCHITECTURE.md](./ARCHITECTURE.md) for how a diagnostic flows from edit to
  banner, and [DEV_NOTES.md](./DEV_NOTES.md) for the quirks that bite (ASCII discipline,
  the 5.1 traps, the pipe-first daemon, the tool-derived corpus).
- Read [CONTRACT.md](./CONTRACT.md) if your change touches a `userConfig` knob or a
  diagnostics status token -- those surfaces are frozen and drift-guarded.
- For a security vulnerability, do **not** open a public issue -- follow
  [SECURITY.md](./SECURITY.md) (private reporting).

## Prerequisites

- **PowerShell 7+ (`pwsh`)** on your PATH (`pwsh -v`). This is the test host on every
  platform.
- **git**, and the GitHub CLI (`gh`) if you want to verify release provenance.
- Pester 5 is **not** something you install by hand -- the test runner installs it to the
  `CurrentUser` scope automatically if it is missing (never machine-global).

There is no compile step: the plugin is PowerShell scripts plus a manifest. The two
runtime dependencies (PSES, PSScriptAnalyzer) are downloaded, pinned, and hash-verified on
first use; the test runner reuses a vendored copy via `PSLS_TEST_DATA_DIR` when present.

## Run the test suite

```
# Everything (the same entry point CI uses):
pwsh -File tests/run-tests.ps1

# Just one feature's tests, by Describe/It wildcard:
pwsh -File tests/run-tests.ps1 -FullNameFilter '*dispatch 000028*'
```

The suite has five parts:

| Suite | What it proves |
|-------|----------------|
| `PowerShellLsp.Unit.Tests.ps1` | Pure helpers + the **drift-guards** that keep CONTRACT.md and the README in sync with the manifest and the banner functions. |
| `PowerShellLsp.Integration.Tests.ps1` | The real warm daemon over a named pipe: one-daemon bring-up, the settled PScriptAnalyzer pass, edit-coalescing, clean SessionEnd, graceful degradation. |
| `PowerShellLsp.Corpus.Tests.ps1` | Diagnostic **correctness** -- every curated sample's live output matches a tool-derived snapshot; the measured false-positive / true-positive numbers are recomputed and guarded. |
| `PowerShellLsp.Benchmark.Tests.ps1` | Cold-start / warm-path latency against a generous regression threshold. |
| `PowerShellLsp.Release.Tests.ps1` | Release-artifact invariants (SBOM/provenance generators, version lockstep). |

CI runs all five on a four-leg matrix: Windows `pwsh` 7, Windows PowerShell 5.1, Ubuntu
`pwsh`, macOS `pwsh`. **A PR must be green on all four legs.** The macOS and Linux daemon
paths cannot be reproduced on a Windows dev box, so CI is the cross-platform arbiter --
expect to iterate against it for anything touching process launch or transport.

## Good first issues

- **Report a false positive.** If the tool flags clean, idiomatic PowerShell, open a
  [false-positive report](./.github/ISSUE_TEMPLATE/false_positive_report.yml). A confirmed
  one becomes a new known-good case in `tests/corpus/samples/clean/` (re-derive snapshots
  with `tests/corpus/Update-CorpusSnapshots.ps1`) -- the corpus grows from real misfires.
- **Add a corpus case.** A new idiomatic clean sample, or a new known-bad case for a
  surfaced rule, strengthens the published correctness numbers. Samples are tool-derived;
  never hand-author the expected JSON.
- **Documentation.** Clarifications to the README, this guide, or DEV_NOTES.

## House style

- **ASCII only** in `.ps1`/`.psm1`/`.psd1` (the 5.1 codepage trap -- see DEV_NOTES).
- Match the surrounding code: comment density, `Verb-Noun` naming, the shared helpers in
  `scripts/lib/lsp-common.ps1`. Prefer extending an existing helper over a parallel one.
- Keep the daemon/LSP path silent on stdout.
- Stage changes by explicit pathspec and keep each commit focused.

## Sign-offs and licensing

- The project is **[GPL-3.0-or-later](./LICENSE)**; contributions are accepted under it.
- There is **no CLA** and no copyright assignment. Certify the origin of your work with a
  **Developer Certificate of Origin** sign-off -- commit with `git commit -s`, which adds a
  `Signed-off-by:` line. Because no CLA is collected, the project cannot unilaterally
  relicense your contribution away from GPLv3 -- a deliberate guarantee to adopters.

## Opening a pull request

1. Branch from `main`.
2. Make the change; run `pwsh -File tests/run-tests.ps1` locally (Windows legs at least).
3. If you changed observable behavior, update the CHANGELOG and the relevant docs; if you
   touched a knob or token, update CONTRACT.md and the README (CI enforces this).
4. Open the PR and let the four-leg matrix run. Reviews and security response come from one
   maintainer, so a focused, tested change turns around fastest.
