# powershell-lsp evidence bundle -- v1.33.0

Raw measurement evidence for the v1.33.0 release freeze (dispatch 000273, "freeze 1B").
Every figure reported for this release traces to a file here.

## Provenance

- Release: powershell-lsp **v1.33.0**, release identity **C =
  `6ab2d24bf254787520ad9449c4e6c17f74ee708d`** -- the squash merge of plugin PR #194, confirmed as
  `origin/main` at freeze time.
- **One commit, not two.** Unlike the v1.32.0 bundle there is no `C -> C'` carry-forward here: every
  block ran at C, and C is the release identity. No figure is carried from a prior version; a figure
  that did not move is recorded as re-measured-and-unchanged, never transcribed.
- Version stamped at C reads `1.33.0` in **both** manifests (`.claude-plugin/plugin.json`,
  `.claude-plugin/marketplace.json`) and in the dated `## [1.33.0] - 2026-08-22` CHANGELOG section.
- Each result JSON stamps the measured `commit` field (`6ab2d24b...`), and `slo-report.ps1` refuses
  to build the table if any block was measured at a different commit.

## The build that was measured, and the proof it was C

Every cache-based block drove a **scratch plugin tree staged from `git archive` of C** into an
isolated `CLAUDE_PLUGIN_ROOT`, with a private junction-backed `CLAUDE_PLUGIN_DATA`, never the dev
clone. `prove-equals-c.ps1` bracketed **every** block -- before and after -- computing each staged
file's git object id (`git hash-object --no-filters`, literal bytes, no smudge filter) and requiring
it to equal the blob id in C's own tree.

- **483 tracked paths, 0 missing, 0 differing, 0 unexplained extra**, on all 11 proofs.
- Tracked-tree digest `d79b648f5af729c414e86076abb04565c4595d571a2190394630f678b8f03fe9`, **stable
  across every block**.
- `CLAUDE_PLUGIN_DATA` is **excluded** and asserted to resolve outside `CLAUDE_PLUGIN_ROOT`, rather
  than assumed to.
- An extra path is classified by **C's own `.gitignore`, evaluated by `git check-ignore`**, after the
  working tree's `.gitignore` is proven byte-identical to C's. Anything not ignored **fails** the
  proof; it is not waved through as a byproduct.

**The proof is falsifiable, and was falsified on purpose.** `-RedControl` runs two arms: mutate a
tracked file (must report `differing`), and plant an untracked non-ignored file (must report
`unexplained_extra`). Both fired, and the tree restored to C afterwards -- see
`results/equality-baseline.json` and the `[RED 1]` / `[RED 2]` lines in `results/quant-run.log`.
Without those arms "EQUAL" would be a verdict that cannot fail.

## Measurement environment

| Parameter | Value |
|---|---|
| Machine | LENOVO 21TB000BUS, single host |
| CPU | AMD Ryzen AI 7 PRO 350 w/ Radeon 860M -- 8 cores / 16 threads |
| RAM | 31.14 GB |
| OS | Microsoft Windows 11 Pro, 10.0.26200 |
| Measured PowerShell host | pwsh **7.6.5** (hook interpreter and, at default `ps_host=pwsh`, the PSES child host) |
| Windows PowerShell present | **5.1.26100.9168** -- not the measured interpreter, but measured directly by the security gate's residual arm |
| PSES / PSScriptAnalyzer | **v4.6.0** / **1.25.0** (pinned; markers `pses-v4.6.0.ok`, `.pssa-1.25.0.ok`) |
| Configuration | shipped defaults throughout; the only knob changed was `enableStats = true` (observe-only) |
| Claude Code | NOT in the measured path -- the harness invokes the hook scripts directly with synthesized SessionStart / PostToolUse stdin |

### Load context -- read this before comparing any wall-clock figure

**This run was taken on a heavily loaded host.** The harness samples CPU at every block boundary, so
this is evidence rather than an assertion (`load_before` / `load_after` in each result JSON):

| Block | CPU `_Total` median before | after | processes |
|---|---|---|---|
| m1 | 84% | 95% | 619 |
| m2 | 89% | 86% | 677 |
| m35 | 95% | 86% | 672 |
| m4b | 95% | 97% | 666 |

For comparison, the v1.32.0 baseline blocks started at **13-32% CPU with ~385 processes**. The host
carried several concurrent co-tenant agent sessions throughout this run.

`SLO-BASELINES.md` section 10 names **`analysisMs` the load-insensitive comparator** for exactly this
situation, and section 2 is explicit that a latency measured under load and published as if it were
not is worse than no number at all. **Wall-clock figures here are reported, not compared**;
`analysisMs` is the figure to compare across runs. See `results/slo-regression.json`, which carries
both the table and the load context in one file.

## Metric definitions (from `harness/measure.ps1`)

- Timer: .NET `System.Diagnostics.Stopwatch`, `ElapsedMilliseconds`, integer-truncated.
- "spread": max - min, rounded to 1 decimal.
- p95: **nearest-rank, never interpolated.**
- Each edit is classified by a stats **line-count delta** plus the client's own banner, so "the
  client gave up" is distinguishable from "the client got an answer" (the SLO-BASELINES section 4.4
  instrument defect).
- A unique nonce line per iteration, so no iteration times a content-hash cache hit.
- Discard-and-report: no run is silently dropped.

## The convergence fixture at C

The fixture is defined by **what it is** -- the largest shipped runtime `.ps1`/`.psm1` -- and not by
a byte count (SLO-BASELINES section 5). At C that file is `scripts/lib/lsp-common.ps1` at
**263,073 bytes / 4,595 lines**, still the p100 of the runtime surface (the only larger `.ps1` files
in the repo are test files). It measured 251,523 bytes at v1.32.0, so the fixture **grew 4.6%**
between the two runs. The harness copies it out of the staged C tree, so it always measures the file
as defined rather than a remembered size.

## Contents

- `harness/` -- **only the scripts that actually ran in this freeze.** `run-quant.ps1`
  (orchestrator), `measure.ps1` (blocks M1-M4b), `stage-c.ps1`, `prove-equals-c.ps1`,
  `security-gate.ps1` (T5.1), `slo-report.ps1` (the T1-T6 table), `replay-checks.ps1` (re-runs the outbox's own recorded checks), `run-gates.ps1` and the four gate
  scripts it drives.
- `results/` -- raw outputs:
  - `m1.json` warm per-edit latency (N=30); `m2.json` cold start (N=10); `m35.json` memory +
    120-edit stability (N=120); `m4b.json` large-file convergence (5 sessions, cap 15).
  - `slo-regression.json` the derived T1-T6 table, the per-session T3 detail, and the load context.
  - `security-gate.json` / `security-gate.log` the T5.1 live-pipe descriptor read at C, both daemon
    arms and the paired RED control.
  - `equality-*.json` the script-tree-equals-C proof chain bracketing every block.
  - `gate-summary.json`, `repo-gates.json`, `license-gate.json`, `airgap-gate.json`,
    `cleaninstall-doctor.json`, `doctor-output.txt`, `pester-*.json` gate corroboration.
  - `ci-at-C.json` the four CI legs with `headSha` matched to C.
  - `replay-checks.log` every `custom_check` recorded in the paired outbox, parsed OUT of that
    outbox and re-run in its own shell, so what ran is what is claimed. 6 of 6 MATCH.
  - `*.log` run transcripts.
- `SHA256SUMS.txt` -- SHA-256 of every file in this bundle.

## Reproduce

The harness drives the plugin hook scripts directly (no editor, no live Claude Code client):

```
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\harness\stage-c.ps1
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\harness\run-quant.ps1
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\harness\security-gate.ps1
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\harness\run-gates.ps1
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\harness\slo-report.ps1
```

Outputs land under the harness's working base (`out\`), matching the JSONs in `results/`.

## Post-tag verification (added after the release published)

The freeze itself claimed nothing about published artifacts, because no tag existed when it ran.
After the v1.33.0 release published -- following the release SPLIT and the re-run described in the
paired outbox -- the 000245 post-tag gate ran against the REAL release assets, and lands here:

- `results/attestation-verify.json` / `.log` -- per-asset provenance. All three published assets
  PASS: the downloaded bytes re-hash to the digest the Release REST API itself reports, and each
  binds to publishing run **32588047316**.
- `results/signature-verify.json` / `.log` -- the tag signature. `gitsign verify-tag` with
  certificate identity and issuer: Git signature, Rekor entry (tlog 2567774015) and **certificate
  claims** all validated.

**The orphan hazard, and why exit 0 was not accepted as the verdict.** The first producing run
(32585972425) attested its artifacts and then failed at release-create, leaving those attestations
ORPHANED in the store. `git archive` of the target is deterministic, so the tarball is
BIT-IDENTICAL between the two runs -- and, measured rather than assumed, `gh attestation verify` on
the published tarball returns **TWO** attestations and exits **0**. Exit code alone therefore says
"some trusted attestation covers these bytes", not "the attestation from the run that published
them". Each asset is additionally bound with `--source-digest` + `--signer-workflow`, and the
returned `invocationId` is asserted. A RED control pins `--source-digest` to the ORPHAN's source
commit and gets back exactly the orphan -- proving the flag discriminates in both directions on the
one digest that carries two attestations, so the positive binding is not decoration.

**Known bound.** SLSA provenance records the WORKFLOW's source commit (main's tip), not the release
target. The attestation does not by itself bind an artifact to the release target commit; that
binding comes from the Release object and the signed tag.

## What this bundle does NOT establish
- **Single host, single OS, single analyzer pin.** No cross-platform latency claim. The four CI legs
  cover other platforms functionally, not for latency.
- **The POSIX arm of the pipe measurement is out of scope** and separately chartered. `CurrentUserOnly`
  narrows a unix socket file's permissions rather than writing a DACL, so this instrument does not
  apply there.
- **Wall-clock figures are not comparable to the v1.32.0 bundle** -- see the load context above.
