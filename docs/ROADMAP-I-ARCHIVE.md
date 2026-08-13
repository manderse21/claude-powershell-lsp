# Roadmap I -- archive

**Immutable snapshot. Written once, by dispatch 000230 (R2-02), 2026-08-13.**

This page is history, not a plan. Nothing on it is open work, and it is not maintained: when it
disagrees with a live document, the live document wins. The archival convention it satisfies --
a closure section in the decision ledger plus this slim immutable snapshot -- is ratified ruling 4
of the five Roadmap II governance rulings
([`decision-ledger.md`](decision-ledger.md), "Roadmap II governance: five rulings,
ratified-by-Mike 2026-08-12").

**Every statement here cites.** Nothing is asserted that is not already recorded somewhere else in
the repository; this page is a set of pointers with just enough prose to make them navigable. For
the reasoning behind any decision, follow the citation.

## What Roadmap I set out to do

Roadmap I ran from the plugin's inception to dispatch 000220. Its structure was the four-horizon
ladder -- Horizon 0 immediate tactical, Horizon 1 near-term tactical, Horizon 2 enterprise
hardening, Horizon 3 strategic what-if -- recorded at
[`decision-ledger.md`](decision-ledger.md) section 4, "Forward plan -- the four-horizon ladder
(tactical -> strategic)", with the arc ladder above it at "The ratified next-wave arc ladder".

An earlier Phase 1-4 launch framing preceded the horizons and was retired. It stays retired: the
Roadmap II program-name ruling (ruling 2, same ledger section) records that the retired framing is
not revived and that no document should reintroduce it as a synonym.

## What shipped, by release line

Roadmap I closed across release line **v1.29.0 through v1.31.0**. Each entry below is the
changelog's own one-line classification, not a re-description; the full entry and its derivation
live in [`CHANGELOG.md`](../CHANGELOG.md) at the cited section.

| Release | Date | What it was, per the changelog |
| --- | --- | --- |
| [v1.29.0](../CHANGELOG.md) | 2026-08-01 | MINOR -- "the closed-loop signal is now persisted per rule, in a sibling log" |
| [v1.29.1](../CHANGELOG.md) | 2026-08-07 | PATCH -- "the native-serve pump survives a dead peer, and the reporting scripts stop claiming more than they measured" |
| [v1.30.0](../CHANGELOG.md) | 2026-08-09 | MINOR -- the doctor resolves the PowerShell host that actually serves PSES and can fail on it; doctor and `/status` state the plugin version unconditionally; every lifecycle record carries the version that emitted it |
| [v1.31.0](../CHANGELOG.md) | 2026-08-10 | MINOR -- the doctor and `/status` state the clearance provenance floor beside the version, and the README answers "what version am I on, and how far back is my data attributable?" |

Published releases and their assets are the GitHub Releases page; the tags `v1.29.0`, `v1.29.1`,
`v1.30.0` and `v1.31.0` are in the repository. The v1.31.0 verify ran at the 000161 standard under
dispatch 000219, and the Rekor tag-entry arc closed under dispatch 000217
([`decision-ledger.md`](decision-ledger.md) section 3, "000217 -- the Rekor tag entries were
MIS-KEYED, not missing").

For the state of the codebase at the close of the arc -- version, commit, architecture, shipped
capability inventory, known limitations, upstream dependencies, technical and documentation debt,
evidence gaps -- see [`docs/roadmap-ii/CURRENT-STATE.md`](roadmap-ii/CURRENT-STATE.md), derived at
the v1.31.0 baseline by dispatch 000221. This page does not restate it.

## The standing declines

These left Roadmap I settled, not as backlog. The table is carried forward verbatim on
[`ROADMAP.md`](../ROADMAP.md) under "Declined, and why"; each entry's reasoning is recorded in
[`decision-ledger.md`](decision-ledger.md).

| Declined | Short reason |
| --- | --- |
| Renaming the plugin | breaks marketplace identity and every published link |
| A file watcher / background workspace sweep | fails the cost and safety bar; `lsp-scan.ps1` already covers explicit whole-repo scanning |
| Loosening the 1.x semver freeze | trades a trust asset for speculative flexibility |
| New custom rules | the rule freeze stands; guidance overrides on rules that already fire are the sanctioned path |
| Flipping the broader ruleset on by default | a missing finding beats a wrong finding; `ruleset = base` is the opt-in |
| Reducing documentation volume | documentation is **restructured**, not reduced |

Two further declines were ratified at the close of the arc, under dispatch 000220, and are
recorded in [`decision-ledger.md`](decision-ledger.md):

- **Gate 6's `WINDOW_DAYS=3` is RETAINED**, on the pipeline-definition-drift guarantee that commit
  identity and Gates 4/5 cannot cover ("Gate 6's window: `WINDOW_DAYS=3` is RETAINED -- ratified,
  on the guarantee it actually makes").
- **Surfacing security-classifier verdicts in the doctor is declined-final**, upholding the 000036
  boundary deliberately rather than by default.

## How Roadmap I closed

Dispatch 000220 closed the arc with the pre-horizon board empty. The closure record -- the arc,
the closing state, the pointer set, and the placement rationale -- is
[`decision-ledger.md`](decision-ledger.md), "Roadmap I -- closure record, ratified-by-Mike
2026-08-12".

Roadmap I carried no open item into Roadmap II. What follows it is a separate program with its own
baseline and its own detail layer.

## Pointers out of this page

| For | See |
| --- | --- |
| The closure record and every decision's reasoning | [`docs/decision-ledger.md`](decision-ledger.md) |
| What changed, and when | [`CHANGELOG.md`](../CHANGELOG.md) |
| What is frozen in 1.x, and what a change costs | [`CONTRACT.md`](../CONTRACT.md) |
| The current public roadmap | [`ROADMAP.md`](../ROADMAP.md) |
| The Roadmap II baseline | [`docs/roadmap-ii/CURRENT-STATE.md`](roadmap-ii/CURRENT-STATE.md) |
| The Roadmap II detail layer | [`docs/roadmap-ii/PROGRAM.md`](roadmap-ii/PROGRAM.md) |
