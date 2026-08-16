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

## Git hooks

This repo ships its git hooks **tracked** under `hooks/`, wired by pointing `core.hooksPath` at
that directory. Enable them once per clone:

```
pwsh -File scripts/install-git-hooks.ps1
```

That is the only manual step -- git does not run tracked hooks until you point it at them. The
installer is idempotent and resolves the **primary** working tree, so the hooks also fire from a
linked worktree (`git worktree add ...`), not only the primary checkout. Uninstall with
`git config --unset core.hooksPath`.

### pre-push: no direct push to `origin/main`

The hook shipped today (`hooks/pre-push`, a POSIX sh shim over `scripts/pre-push-guard.ps1`)
**refuses a push that updates `refs/heads/main` on origin.** `main` lands via a reviewed, merged PR
-- the PR-and-HOLD discipline -- never a direct local push. Every other push is untouched: feature
branches, tags, branch deletes, and pushes to a fork remote all pass through.

**Deliberate one-off override (audited).** For the genuine exception, set a non-empty reason:

```
POWERSHELL_LSP_ALLOW_PUSH_TO_MAIN="why this push is intentional" git push origin <ref>
```

The push is then allowed **and** an audit line -- UTC timestamp, reason, pushed sha, target ref --
is appended to a bypass log. An unset, empty, or whitespace-only reason does **not** override. The
log defaults to `<git-common-dir>/powershell-lsp-push-to-main-bypass.log` (inside `.git`, so it is
never committed and is shared across every linked worktree of the clone); relocate it with
`POWERSHELL_LSP_PUSH_AUDIT_LOG=<absolute path>`.

The guard is **local** -- it protects a checkout that has installed it. The machine-independent
complement is GitHub branch protection on `main` (require a PR, forbid direct pushes); that is
recommended but is a separate repo-settings change, not part of the hook.

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

- The project is **[Apache-2.0](./LICENSE)**; contributions are accepted under it. Under
  Apache-2.0 section 5, a contribution you deliberately submit for inclusion is submitted under
  the terms of the License -- so a DCO sign-off is all that is asked, exactly as before.
- There is **no CLA** and no copyright assignment. Certify the origin of your work with a
  **Developer Certificate of Origin** sign-off -- commit with `git commit -s`, which adds a
  `Signed-off-by:` line. Because no CLA is collected, the project cannot unilaterally
  relicense your contribution away from Apache-2.0 -- a deliberate guarantee to adopters.

## Opening a pull request

1. Branch from `main`.
2. Make the change; run `pwsh -File tests/run-tests.ps1` locally (Windows legs at least).
3. If you changed observable behavior, update the CHANGELOG and the relevant docs; if you
   touched a knob or token, update CONTRACT.md and the README (CI enforces this).
4. Open the PR and let the four-leg matrix run. Reviews and security response come from one
   maintainer, so a focused, tested change turns around fastest.
