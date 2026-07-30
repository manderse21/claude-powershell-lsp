# Roadmap

The short, public view: what is next, what is blocked, what is deferred, the top risks, and where
the evidence lives.

This page deliberately carries **no version numbers, counts, or shipped-item tallies** -- those go
stale between releases and a stale count reads as a false claim. For the current version see
[CHANGELOG.md](./CHANGELOG.md) and the GitHub Releases page; for the reasoning behind every
decision below -- including the ones that were declined and why -- see the
[decision ledger](docs/decision-ledger.md).

## What is next

- **Diagnostic efficacy ledger (Arc A).** Per-rule fired / fixed / ignored facts, aggregated
  reader-side from the dogfood capture the plugin already writes. Facts, not scores. This is the
  opener because it is unblocked today and needs no new knob and no capture-format change --
  though whether the closed-loop "cleared" signal must be persisted per-rule is an open design
  question the build dispatch adjudicates, not a settled one.
- **Plugin-catalog submission.** The queued next external action, gated on the maintainer.
- **Doctor and command surface.** Continuing to close the gap between "the plugin is installed"
  and "the user can prove it is working", through the preflight doctor and plugin commands.

## What is blocked

- **Native code navigation, end to end.** Registration works; **serve** does not, on the direct
  path. Claude Code's LSP client rejects the standard server-to-client requests PSES sends during
  initialization (upstream `#1359`-class handshake). The opt-in `nativeServe = shim` closes that
  gap locally and is shipped, so this is un-gated *in practice* -- but the shim is a workaround,
  and removing it waits on the upstream fix. A separate upstream Windows regression
  ([anthropics/claude-code#73961](https://github.com/anthropics/claude-code/issues/73961)) blocks
  the native tier from starting at all on Windows under some Claude Code versions.
- **Corpus commons (Arc B).** Publishing the correctness oracle as a community benchmark is
  contingent on a licensing / provenance audit of the corpus samples passing. Provenance is the
  gate, not an afterthought.
- **Attested diagnostics (Arc C).** Extending the SLSA / Sigstore chain from release assets to
  scan outputs waits on real efficacy data existing and on a real consumer to read it.

## What is deferred

- **Enterprise control plane (Arc D).** Policy distribution and fleet rollup, continuing the
  shipped `orgPolicy` knob. **Demand-paced:** one slice per real adoption signal, never built
  ahead of a consumer.
- **Scale and robustness (Arc E).** A performance harness and characterized very-large-repo
  behavior. **On-demand:** it moves when a real scale problem is reported.
- **Deeper rule curation and fix-suggestion quality.** Paced by the dogfood log and gated on real
  interactive usage, not on machinery -- the machinery already ships.

### Declined, and why

These are settled decisions, not backlog. Each is recorded with its reasoning in the
[decision ledger](docs/decision-ledger.md):

| Declined | Short reason |
|---|---|
| Renaming the plugin | breaks marketplace identity and every published link |
| A file watcher / background workspace sweep | fails the cost and safety bar; `lsp-scan.ps1` already covers explicit whole-repo scanning |
| Loosening the 1.x semver freeze | trades a trust asset for speculative flexibility |
| New custom rules | the rule freeze stands; guidance overrides on rules that already fire are the sanctioned path |
| Flipping the broader ruleset on by default | a missing finding beats a wrong finding; `ruleset = base` is the opt-in |
| Reducing documentation volume | documentation is **restructured**, not reduced |

## Top risks

- **Single-maintainer bus factor.** Stated plainly, with the GPLv3 continuity path, in
  [CONTINUITY.md](./CONTINUITY.md).
- **Upstream dependence.** The native navigation tier depends on Claude Code's LSP client and on
  PSES; both have open upstream issues this project can file against but cannot fix.
- **A wrong finding costs more than a missing one.** Every broadening decision is gated on the
  measured corpus false-positive bar, which is why defaults stay narrow and every new signal
  ships off by default.
- **Documentation drift.** Mitigated structurally, not by discipline: the knob table, the
  contract's frozen-knob list, and the manifest are set-equality guarded in CI, so a drift is a
  red build rather than a stale doc.

## Where the evidence lives

| Question | Answer lives in |
|---|---|
| What changed, and when | [CHANGELOG.md](./CHANGELOG.md) |
| Why a decision was made (or declined) | [decision ledger](docs/decision-ledger.md) |
| What is frozen in 1.x, and what a change costs | [CONTRACT.md](./CONTRACT.md) |
| Whether a claim about diagnostics correctness holds | `tests/corpus/`, recomputed and guarded on every CI run |
| Measured latency | [docs/benchmarks.md](docs/benchmarks.md) |
| What the plugin runs, downloads, and never does | [TRUST.md](./TRUST.md) |
| How a diagnostic flows from edit to banner | [ARCHITECTURE.md](./ARCHITECTURE.md) |
| Upstream issues and their status | [docs/upstream/](docs/upstream/) |

## Operating posture

Fast on a gated path; the gate is fast, not removed. Human gates: accept, merge, the verified
flip, tag, and the product / positioning / sequencing calls. Within an accepted scope,
implementation, design, and ripeness are decided by the implementer. Ground truth -- the live
dispatch log and file inspection -- wins over any document, including this one.
