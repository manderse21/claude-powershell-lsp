# Roadmap

The short, public view: what is next, what is blocked, what is deferred, the top risks, and where
the evidence lives.

This page deliberately carries **no version numbers, counts, or shipped-item tallies** -- those go
stale between releases and a stale count reads as a false claim. For the current version see
[CHANGELOG.md](./CHANGELOG.md) and the GitHub Releases page; for the reasoning behind every
decision below -- including the ones that were declined and why -- see the
[decision ledger](docs/decision-ledger.md).

## Recently completed

Deliberately short: this records only what has *left* "What is next", so that list stays a list of
open work. What shipped and when is [CHANGELOG.md](./CHANGELOG.md); why is the
[decision ledger](docs/decision-ledger.md).

- **Diagnostic efficacy ledger (Arc A) -- opener shipped.** Per-rule fired / fixed / ignored facts,
  aggregated reader-side from the dogfood capture the plugin already writes. Facts, not scores. The
  design question this arc carried -- whether the closed-loop "cleared" signal must be persisted
  per rule -- has been **adjudicated and built**: it is persisted, in a sibling log, and the derived
  clearance columns read from it. That question is settled, not open.

  **The union-filter question is now CLOSED: it never filters.** The reader unions every
  per-version capture log it discovers, deliberately, so that an upgrade does not reset the
  denominator -- which means the union permanently includes occurrences produced by rules that no
  longer ship. That much is *visible*: the ledger reports both denominators side by side, total and
  current-rule-surface, and names the out-of-surface rules. It **filters neither**, on purpose, so
  that no previously published figure changes value. The question was whether it ever should; the
  answer is no, and it is a ruling rather than a deferral. Retroactively filtering the union would
  move figures that have already been published, which is the cardinal metrics anti-pattern -- and
  the dual view without mutation already answers the need that a filter was reaching for.

  The **clearance columns had no equivalent**, and that was the sharper half. The attribution above
  works because a committed surface history maps releases to the rule surface that shipped with
  them; the sibling lifecycle log had no counterpart, so for those columns the provenance was not
  merely unfiltered but unrecoverable. **Resolved forward, not retroactively:** each lifecycle
  record now carries the plugin version stamped in-record at emit time, and the ledger prints a
  **provenance floor** -- the earliest version-attributable point -- with anything below it labelled
  a bounded, known gap rather than a silent one. Pre-instrumentation records are still *counted* in
  every rate (the union stays non-filtering) and simply never *attributed* to a version. An
  un-instrumented past cannot be recovered; it can be bounded and named, and now is. Recorded in the
  [decision ledger](docs/decision-ledger.md).

  **Both design questions that work carried are now adjudicated; neither is left standing as open.**

  *Is the floor absolute, or relative to what the reader still holds?* It is
  **retained-window-relative by design.** The floor names the earliest version-attributable release
  among the records *currently retained*, and it RISES as the family rolls --
  `logs/lifecycle-<stamp>.jsonl` is a stamped rolling family that `session-start.ps1`'s
  `Invoke-LogSweep` trims to the `keepLastN` newest. That is the intended reading rather than a
  defect: the ledger reports what it can still see, and a floor pinned to a release whose records
  have aged out would claim knowledge the reader no longer holds. One **wording** follow-up is
  carried and is deliberately not release-blocking -- the shipped caveat states the floor and the
  bounded gap, but the printed text does not yet say *window-relative*; that meaning currently lives
  only in a source comment, so a reader has to infer it.

  *Do version and provenance belong in user-facing documentation?* **Yes** -- version plus provenance
  is a supportability surface, not an internal diagnostic. It is scheduled as the next slice rather
  than closed here; see "What is next".

## What is next

- **Doctor and command surface.** Continuing to close the gap between "the plugin is installed"
  and "the user can prove it is working", through the preflight doctor and plugin commands.
  Slice 2 (000208) closed the last two boundary-clean gaps the 000203 survey evidenced: the
  `ps_host` child-host resolution check (fail-capable) and a report-only version header, taking the
  default doctor to 11 checks. The lane stays open rather than moving to "Recently completed":
  the survey's remaining candidate -- surfacing security-classifier verdicts -- is **declined
  while the 000036 boundary stands**, and reopening that boundary is an attended ruling, not a
  slice. See the [decision ledger](docs/decision-ledger.md).

- **Surface the version stamp and the provenance floor where a user will actually read them.** The
  adjudicated successor to Arc A's provenance work, and the doctor lane's next concrete slice.
  Version and provenance are a supportability surface, so they belong in user-facing documentation
  and not only in a reader-side ledger. Two places: the README's support / trust section, and a
  doctor / `status` line -- so that "what version am I on, and how far back can that answer be
  trusted?" is answerable without running the efficacy ledger. The in-record stamp and the floor
  already ship; this item is the **surfacing**, and it carries the one wording follow-up noted
  above (say *window-relative* in the printed caveat, not only in a source comment).

> **Plugin-catalog submission is not an item on this list.** It is maintainer-owned and is not
> tracked on this page as an open action. It previously appeared under "What is next" as "the queued
> next external action", and that framing is an operational hazard rather than a cosmetic staleness:
> a prior session read it as evidence that submission had not happened and caused a duplicate.
> **Do not infer submission state from this page, and do not try to establish it by querying the
> catalog** -- submission goes through a Console form that is invisible to the API, so a query
> cannot answer the question, and acting on one has already gone wrong once. Ask the maintainer.

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
