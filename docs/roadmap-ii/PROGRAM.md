# Roadmap II -- program detail

**The detail layer.** [`ROADMAP.md`](../../ROADMAP.md) is the short, countless public view; this
page carries the per-initiative detail that ruling 3 moved off it. The factual baseline both rest
on is [`CURRENT-STATE.md`](CURRENT-STATE.md), derived at the v1.31.0 baseline by dispatch 000221 --
this page cites it rather than restating it.

Written by dispatch 000230 (R2-02), 2026-08-13. The authority for every ratified item is the
decision ledger: the five governance rulings and the D1-D7 gate decisions, both
ratified-by-Mike 2026-08-12 ([`decision-ledger.md`](../decision-ledger.md)).

**Nothing on this page decides anything.** Items awaiting Mike's gate review are labelled
**PENDING-MIKE** and are listed in their own section, never inside the ratified tables.

## The pillar set, as ratified

Ruling 1 ratified the disposition of two pillars, and only two:

| Pillar | Ratified disposition |
| --- | --- |
| **A** | **Reshaped to agent-facing semantic EXPOSURE of PSES capability.** The plugin is a client of PowerShell Editor Services, not a re-implementation of it. The pillar is about surfacing what PSES already computes in a form an agent can consume -- not about growing an analysis engine. |
| **H** | **DECLINED-pending-demand.** A custom-rule seam would resurrect the already-declined new-custom-rules item under a new name. Guidance overrides remain the sanctioned seam. Declined *pending demand*, not permanently: real user demand reopens it, and nothing else does. |

**The intermediate pillars are not recorded in any repository artifact.** A search of this
repository and of the dispatch hub at write time returns `Pillar A` and `Pillar H` only -- both
from ruling 1. Whatever B through G were named in planning, that catalog was never carried into a
committed document. It is **not reconstructed here**: inventing the set would manufacture ratified
content, which is the one thing this dispatch must not do. Recorded as a gap for Mike.

## Initiative table

Classifications describe what each initiative needs **next**, not what it was. Delivered work whose
only remaining step is a maintainer decision is **HUMAN-GATED**, which is a true statement about the
present rather than a status badge.

| Initiative | Scope | Dispatch | Classification | Gate | Evidence |
| --- | --- | --- | --- | --- | --- |
| **R2-01** | Canonical current state at the release baseline | 000221 | **HUMAN-GATED** | Delivered and merged; the document is the program's baseline and moves only when a successor dispatch re-derives it | [`CURRENT-STATE.md`](CURRENT-STATE.md); manderse21/claude-powershell-lsp#146, merge `7f34277` |
| **R2-02** | Roadmap I archived, `ROADMAP.md` canonicalized, deferred ledger record landed | 000230 | **HUMAN-GATED** | Delivered and merged. The canonicalization it established -- no version numbers, counts, or shipped tallies on `ROADMAP.md` -- is the standing constraint every later true-up of that page works under | [`decision-ledger.md`](../decision-ledger.md) tail sections; [`ROADMAP-I-ARCHIVE.md`](../ROADMAP-I-ARCHIVE.md); this page; manderse21/claude-powershell-lsp#154, merge `d2e929d` |
| **R2-04** | Threat model and least-privilege statement | 000226 | **TRIAGED -- 3 fixed, 2 measured, 6 accepted** | Delivered and merged. The ten OPEN/unknown findings routed to the gate were **triaged by Mike on 2026-08-21 (G3)** and executed by dispatch 000269: T2.3, T5.1 and T6.4 FIXED, T6.2 MEASURED, six ACCEPTED-WITH-RECORD. Both `unknown` rows are now measured -- T5.1 resolved against the project (the pipe DACL granted Everyone and Anonymous read) | [`THREAT-MODEL.md`](THREAT-MODEL.md); manderse21/claude-powershell-lsp#151, merge `98eb027` |
| **R2-05** | Corpus licensing and provenance audit, then the corpus commons un-gate | 000222, 000251 | **HUMAN-GATED -- external publishing only** | **Un-gated.** The audit passed the licensing gate (D1) and the deferred relicensing decision is made: the corpus publishes under the project's **Apache-2.0** (G1, ruled 2026-08-21), one license repo-wide, documented in-repo for outside use and reproduction. Re-derived 2026-08-21 rather than assumed: no corpus file carries a per-file license header of any kind, so each takes the repository LICENSE. What remains is **maintainer-owned external publishing**; this row claims no submission | [`CORPUS-PROVENANCE-AUDIT.md`](CORPUS-PROVENANCE-AUDIT.md); manderse21/claude-powershell-lsp#147, merge `c0e4b51`; D1; [`corpus.md`](../corpus.md) and the 000251 entry in [`decision-ledger.md`](../decision-ledger.md), manderse21/claude-powershell-lsp#192, merge **`78ddcee`**; plus the detachable package at [`corpus-commons/`](../corpus-commons/), prepared-not-published |
| **R2-06** | Candidate SLOs and their baselines | 000223 | **RATIFIED -- adopted v1 SLOs** | The six targets T1-T6 were **ratified by Mike on 2026-08-21 (G2)** and are in force. All six are met at v1.32.0, re-measured by dispatch 000269; two of them (T3, T4) were failing when they were proposed. The baseline is now a regression bar. No cold-start target was adopted -- deliberately, and ratification did not close that gap | [`SLO-BASELINES.md`](SLO-BASELINES.md); manderse21/claude-powershell-lsp#149, merge `776ea07`; D2 |
| **R2-07** | Stop the busy-vs-unreachable relaunch thrash on the edit path | 000225 | **HUMAN-GATED** | Chartered under D3 against the T4 red. Delivered, merged, released in v1.31.1, and remeasured against the fixed build: the thrash is gone and every remaining relaunch now follows a real daemon death. The successor the remeasurement isolated -- a departed client killing the daemon -- is no longer outstanding: it was chartered as dispatch 000237, fixed, and released, and its row has moved out of PENDING-MIKE into the resolved list below | [`POST-FIX-REMEASUREMENT-relaunch-thrash.md`](POST-FIX-REMEASUREMENT-relaunch-thrash.md); manderse21/claude-powershell-lsp#153, merge `bdd78f1`; dispatches 000229 and 000231; D3 |
| **R2-08** | Developer-experience journey audit, install through upgrade | 000228 | **TRIAGED -- 8 fixed, 3 accepted** | Delivered and merged as findings only. **Ratified by Mike on 2026-08-21 (G4):** D1-D4 and O1-O4 were fixed by dispatch 000265 and shipped in v1.32.0; T1-T3 are accepted as priced tradeoffs. O2's structural half -- a surface that reconciles the running daemon's version against the tree -- was still open after 000265 (which fixed its remedy text) and was closed by dispatch 000269 | [`DX-AUDIT.md`](DX-AUDIT.md); manderse21/claude-powershell-lsp#152, merge `c4fc5ce`; D7 |
| **R2-14** | Governance surface | 000227 | **HUMAN-GATED** | Delivered and merged, which ratified the four proposals. CODEOWNERS ships **inert** by design: enabling `require_code_owner_reviews` would deadlock the repository until a second maintainer exists | [`GOVERNANCE-SURFACE.md`](GOVERNANCE-SURFACE.md); manderse21/claude-powershell-lsp#150, merge `5d8ac83` |
| **R2-15** | Offline / air-gapped bootstrap: layered artifact sources + attested airgap bundle | 000244 | **DELIVERED -- rode v1.32.0** | A slice of the Arc D lane below, whose gate -- one slice per real adoption signal -- is satisfied by the corporate-IT review of 2026-08-15 that ranked no-offline-path as the top tractable adoption blocker. The maintainer's call on when it rides a release **has been made: it shipped in v1.32.0** | [`TRUST.md`](../../TRUST.md) trust-model section; [`configuration.md`](../configuration.md#offline-and-air-gapped-installation); `release/New-AirgapBundle.ps1`; manderse21/claude-powershell-lsp#176, merge **`48c9e5d`** (2026-08-16), verified live and confirmed an ancestor of `v1.32.0^{}` |

**Identifier gaps.** R2-03 and R2-09 through R2-13 do not appear in this repository or in the
dispatch hub at write time. They are recorded as absent, not as unstarted: nothing is known about
whether those identifiers were ever assigned. The `Wave A` docs/upstream true-up (dispatch 000224,
manderse21/claude-powershell-lsp#148, merge `cfd2409`) carries no R2 number in any artifact and is
listed here for completeness rather than given one.

**R2-15 was minted fresh rather than filling a gap** (dispatch 000244). Reusing R2-03 or any of
R2-09 through R2-13 would assert that the identifier was free, which is exactly the thing the
paragraph above records as unknown. A new identifier costs nothing and claims nothing.

### Standing arcs, carried forward

These predate Roadmap II and keep their pacing. `ROADMAP.md` states them at headline level.

| Arc | Classification | Gate |
| --- | --- | --- |
| Native code navigation, end to end | **GATED** | Registration works; serve does not on the direct path. The opt-in `nativeServe = shim` closes it locally; removing the shim waits on the upstream fix ([`CURRENT-STATE.md`](CURRENT-STATE.md) section 7) |
| Corpus commons (Arc B) | **HUMAN-GATED -- external publishing only** | **The gate is open.** See R2-05: the audit passed and the relicensing decision has been made (G1, Apache-2.0) -- the corpus publishes under the project's Apache-2.0, documented for outside use in [`corpus.md`](../corpus.md), with a detachable package held at [`corpus-commons/`](../corpus-commons/) marked prepared-not-published. Only external publishing remains, and that is a maintainer action, never an autonomous one |
| Attested diagnostics (Arc C) | **GATED** | Waits on real efficacy data existing and on a real consumer to read it |
| Enterprise control plane (Arc D) | **DEMAND-PACED** | One slice per real adoption signal, never built ahead of a consumer. The gate has been met once and the lane keeps its pacing: the 2026-08-15 corporate-IT review was the signal, and R2-15 above is the slice built against it |
| Scale and robustness (Arc E) | **DEMAND-PACED** | Moves when a real scale problem is reported |
| Deeper rule curation and fix-suggestion quality | **DEMAND-PACED** | Paced by the dogfood log and gated on real interactive usage; the machinery already ships |
| A custom-rule seam (Pillar H) | **DECLINED** | Declined pending demand. Real user demand reopens it; nothing else does |
| Quiet-window remeasurement of the SLO set | **DECLINED** | Declined at D4: the baseline was taken under the conditions the plugin actually runs on, and a quiet-window figure would measure a machine no user has |

## PENDING-MIKE

**None of these is decided.** Each is listed because it is awaiting the gate review, and listing it
here is not a recommendation.

| Item | What is waiting |
| --- | --- |
| Rule-candidate promotions | The **five** candidates recorded in the ledger's tail-failure section; promotion is Mike-gated and standing. A findings docket assembling the evidence and a per-candidate recommendation is at [`RULE-PROMOTION-DOCKET.md`](RULE-PROMOTION-DOCKET.md) (G5) -- **it executes no promotion**, and the gate is unchanged |
| Corpus publication | The Apache-2.0 relicensing decision is made (G1) and a package is assembled and held at [`corpus-commons/`](../corpus-commons/). Publishing it -- to a registry, a repository, or any channel -- is Mike's and has not been done |

> **Count correction (2026-08-21).** The rule-candidate row said "the four candidates". The ledger's
> tail-failure section carries **five**, numbered 1-5. `git log -S` places the fifth candidate and
> the "four" wording in the **same commit** (`d2e929d`, PR #154): candidate 5 was the one that
> dispatch added itself, and this count was never updated to match. An off-by-one authored in one
> sitting rather than drift that accumulated.

**Rows that have left this table since it was written**, each because the decision was taken
rather than deferred. Recorded so their absence reads as resolution rather than omission. The
list is deliberately not counted in prose: a running tally in a table that grows is a claim that
goes stale on the next edit.

| Row that left | How it was decided |
| --- | --- |
| **A second fix slice arising from D1** | **Not needed.** Ruled G8 (2026-08-21): the SARIF attribution rider folds into Arc B activation rather than taking its own slice. Verified 2026-08-21 as **already closed** -- `THIRD-PARTY-LICENSES.md` carries a full SARIF section naming OASIS, the IPR terms and the retrieval route, and points at `tests/sarif/NOTICE.md` as authoritative. The audit's Finding 3 rested on "zero hits" for SARIF/OASIS/SchemaStore in that register; it now returns 9/6/1 |
| **DX findings triage** | **Ratified G4** (2026-08-21) as already-done-in-substance: D1-D4 and O1-O4 were fixed by dispatch 000265 and shipped in v1.32.0; T1-T3 are accepted as priced tradeoffs. The one genuine remainder -- O2's version reconciliation, which 000265 addressed only in remedy text -- was built by dispatch 000269 |
| **Quarantine disposal** | **Ruled G6 retained-archived** (2026-08-21), following the 000261 archive-never-delete precedent. The 000225 / 000229 trees and failed-run evidence are kept, not disposed of |
| **The missing pillar catalog** | **Ruled G7 retired, never reused** (2026-08-21). B through G are neither restated nor renamed, and their identifiers are not reassigned -- the same identifier-gap precedent this page already applies to R2-03 and R2-09..R2-13 |
| **The daemon-exit successor** | **Answered, not deferred.** It was chartered as dispatch 000237, delivered, and released. The remeasurement's open question -- the serve loop's own handler logs the broken-pipe exception, so why does the loop end? -- has a derived answer: the failed write moves the pipe server from `Connected` to `Broken`, the per-request cleanup guarded on `IsConnected` therefore skipped the disconnect on exactly that path, and the loop's next accept threw outside the handler. Recorded here as an already-made decision; it charters nothing further |
| A v1.31.1 release cut | Cut and released 2026-08-13, carrying the 000225 + 000231 pair |
| Statusline upstream filing | Filed as [`anthropics/claude-code#86551`](https://github.com/anthropics/claude-code/issues/86551); the internal record is [`docs/upstream/claude-code-statusline-pwsh-leak.md`](../upstream/claude-code-statusline-pwsh-leak.md) |
| The unix-arm question from 000229 | Ratified 2026-08-13 and shipped inside manderse21/claude-powershell-lsp#153 as dispatch 000231, which made the off-Windows presence check a liveness check |

## Wave process notes

How Wave A and Wave B were actually run. Recorded because the pattern worked and because two of
its steps exist to catch failures that have really happened.

**Attended-parallel, two waves.** Dispatches run in parallel within a wave, kept **file-disjoint**
so their deliverables cannot collide -- which is precisely why the ledger writes were *deferred*
to this dispatch rather than done by each. A shared append-only file is the one thing parallel
sessions cannot safely share. Wave A ran 000221-000224; Wave B ran 000225-000228.

**Merge-as-you-verify.** A dispatch's PR merges when its outbox verifies, rather than batching
merges at the end of a wave. It keeps `main` moving and keeps each merge's blast radius to one
dispatch. Dispatch 000227 recorded the pattern working in its sharpest form: its PR was merged by
Mike *during* close-out, which ratified its four proposals in the same motion.

**Update-branch / fresh-run-id discipline.** When a branch is updated, the CI observation must
name the **new** run id. An observation carried forward from a previous head is an observation of
something else. This is the discipline behind rule candidate 3 in the ledger's tail-failure
section -- a foreground-CI claim with no run id is unfalsifiable at write time and false at read
time, and that candidate has a second observation.

**The origin-evidence gate.** After minting and pushing, run `git fetch origin` and confirm the
outbox commit appears in `git log origin/main` **from the shared root**, recording the command and
its output in the outbox itself. It exists because a deliverable can merge while its record never
lands: dispatch 000228's inbox reached `verified` with no outbox in existence anywhere. Recorded
in the ledger as a finding, not promoted to a rule.

**All hub operations run from the shared hub root.** No per-session hub copy is created or used.
The topology this rule was written against was investigated by dispatch 000229 and **found not to
exist on disk**; the rule stands on its own merits rather than on that premise, and the ledger
records the refutation plainly.
