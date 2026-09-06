# Rule-candidate promotion docket -- FINDINGS ONLY

> ## NO PROMOTION IS EXECUTED BY THIS DOCUMENT
>
> Promotion of a rule candidate to a rule is **Mike-gated and standing**. This docket exists so that
> the gate can be exercised against assembled evidence instead of against a list of one-line
> summaries. Every recommendation below is a **recommendation**; none has been acted on, and no
> candidate's status changed anywhere as a result of assembling this.
>
> Chartered by Mike's **G5** ruling of 2026-08-21 -- *"the rule-candidate promotions get a findings
> docket with the promotions kept attended"* -- and assembled by dispatch **000269**.

---

## Premise correction, recorded before anything else

**The charter and `PROGRAM.md` both say there are four candidates. On disk there are five.**

`docs/decision-ledger.md` section *"Tail-failure taxonomy and process findings"* carries a table
titled *"Rule candidates -- NOT promoted"* with rows numbered **1 through 5**. `PROGRAM.md`'s
standing-work row describes it as *"The four candidates recorded in the ledger's tail-failure
section"*.

This is not drift that accumulated: `git log -S` puts **both** the fifth candidate and the
"four candidates" wording in the **same commit**, `d2e929d` (dispatch 000230, PR #154). Candidate 5
was the one that dispatch added itself -- the ledger says the set is *"carried forward from 000229's
`rule_observations`, plus this dispatch's own"* -- and the count in the sibling document was not
updated to match. An off-by-one authored in one sitting.

**This docket covers all five.** `PROGRAM.md`'s count is corrected in the same dispatch's leg G.

## How to read the recommendation column

A candidate is a claim that some failure shape will **recur**. The bar for promotion is therefore
not "was this true once" -- every candidate here was true at least once, which is why it was
recorded -- but **"is a standing rule the right instrument for it"**.

Three things argue for HOLD rather than against the finding:

- **Already structurally closed.** If the mechanism that produced the failure no longer exists, a
  rule adds process cost against a fixed defect.
- **One observation, narrow surface.** A single sighting on a surface the project rarely touches is
  a finding, not a pattern.
- **Better served by a gate than a rule.** A rule a human must remember is weaker than a check that
  fails.

---

## Candidate 1 -- per-platform evidence for a cross-platform discriminator

> A platform-conditional branch added to a cross-platform discriminator must carry per-platform
> evidence before it ships. `Test-DaemonPipePresent` measured the Windows arm and wrote the unix arm
> by analogy, unmeasured -- and the unix arm is the one that is wrong.

**Second observation:** No (ledger).

**Evidence, re-derived from disk 2026-08-21.** Confirmed, and the code now carries the confession in
its own comment. `scripts/lib/lsp-common.ps1`, `Test-DaemonPipePresent`, the Unix arm:

> *"PRESENCE IS NOT LIVENESS OFF-WINDOWS (dispatch 000231). ... The first cut of this arm was written
> by ANALOGY from the Windows measurement above and never measured off-Windows; the two behave
> differently, so this arm now carries its own evidence."*

The failure was real and consequential: on Windows the pipe name vanishes when the owning process
dies because NPFS is kernel-managed, while a unix socket file survives a daemon that dies without
running its exit `finally`. The bare presence test reported a corpse as a live daemon, suppressed
the relaunch, and broke a required recovery property **on ubuntu and macos while both Windows legs
passed**.

**Recommendation: PROMOTE.**

This is the strongest candidate in the set despite having one observation, and the reason is that
its blast radius is structural rather than incidental. The project ships **four CI legs precisely
because platform behaviour diverges**, and this failure mode is invisible to the leg the author is
standing on -- which is what makes "it passed locally" an actively misleading signal. A single
observation of a failure whose detection cost is *two platforms of green CI* is worth more than
several observations of a cheap-to-spot failure.

It is also cheap to comply with: the rule asks for evidence per arm, which the codebase already
demonstrates it can produce, in this very function.

**If held instead:** the fallback worth taking is narrower and mechanical -- require a comment
citing the measurement beside any `$IsWindows`-style branch in the shared library, which a
`custom_check` could enforce without a standing rule.

---

## Candidate 2 -- purity guards that hardcode an allow-list of derived names

> A purity guard that hardcodes an exact allow-list of derived names is a tripwire on every future
> helper; the guard belongs in the same review breath as the helper.

**Second observation:** No (ledger).

**Evidence, re-derived from disk 2026-08-21.** The shape is present -- `PowerShellLsp.LibPurity.Tests.ps1`
carries an `$expected = [ordered]@{...}` enumeration of derived names -- so the tripwire the
candidate describes is real and still live.

**Recommendation: HOLD.**

Two reasons, and the second is the stronger one.

First, this is a **guard-design** observation rather than a process failure: it says a particular
test shape is brittle. Brittleness of that kind announces itself loudly -- the guard goes red on the
next helper, in CI, before merge -- so the cost of *not* having a rule is a rejected build, not a
shipped defect. That is the cheapest possible failure mode.

Second, and decisively: **a rule is the wrong instrument for it.** The remedy the candidate names --
"the guard belongs in the same review breath as the helper" -- is a *convention about editing*, which
no check can enforce and which a reader has no way to apply until they are already inside the failure.
Promoting it would add a rule whose observable effect is approximately zero.

**What would change this:** a second observation on a *different* guard would reclassify it from "one
brittle test" to "a guard-authoring pattern this project keeps reproducing", at which point the
useful artifact is a documented guard-authoring convention rather than a rule.

---

## Candidate 3 -- a foreground-CI claim must cite a run id

> A foreground-CI claim must cite a run id. "Four-leg green observed in the foreground" with no run
> id and no `gh` invocation in the transcript is unfalsifiable at write time and false at read time.

**Second observation: YES.** The only candidate in the set with one -- recorded in the ledger as a
"second observation of the foreground-only violation class".

**Evidence, re-derived from disk 2026-08-21.** The originating falsification stands in the ledger:
dispatch 000225's claim of *"four-leg CI green observed in the foreground"* is **falsified** by run
`31654261705`'s failure. The claim was not merely unproven -- it was **false**, and the only reason
anyone could tell is that a run id existed to check *after the fact*.

**The practice has already converged on this independently**, which is corroboration rather than a
reason to skip it. The v1.32.0 freeze evidence cites run ids throughout: `32272283642` (four-leg CI
at C), `32282389973` (at C'), `32282551617` (the release dry run), each recorded with `headSha` so
the run can be tied to the commit it describes.

**Recommendation: PROMOTE.**

This is the candidate the promotion bar was designed for, and it clears it on every axis:

- **It has the second observation**, which is the project's own stated threshold.
- **It is falsifiable.** A claim citing a run id can be checked by anyone, forever; a claim without
  one cannot be checked even by its author an hour later.
- **The failure it prevents is silent.** An unfalsifiable green claim does not fail loudly like
  candidate 2's guard -- it propagates into an outbox, into a decision, and into the next dispatch's
  premise. It is exactly the class of error that a written rule catches and a CI check cannot,
  because the artifact being checked is a *sentence*, not a build.
- **Compliance is nearly free**, and the project already does it.

**Note on scope for the drafting.** The rule should bind the **citation**, not the observation
method: the defect is an uncheckable claim, not foreground observation as such. Phrasing it as
"cite the run id and the query that produced it" keeps it enforceable without banning a legitimate
way of watching CI.

---

## Candidate 4 -- a merged deliverable whose outbox is never committed

> A dispatch whose deliverable merges but whose outbox is never committed leaves the work done and
> the record absent. The state machine does not catch it: 000228's inbox reached `verified` with no
> outbox in existence.

**Second observation:** No -- first observation (ledger).

**Evidence, re-derived from disk 2026-08-21.** Confirmed on disk in the ledger's own taxonomy row 1,
and it is the one item there marked **CONFIRMED on disk** rather than "recorded as named": PR #152
merged, `DX-AUDIT.md` on `main`, the inbox walked all the way to `verified`, **and no outbox anywhere
-- not in the hub, not on `origin/main`, not on disk.**

**Recommendation: HOLD -- but adopt the gate the ledger already names.**

The finding is real and serious, and this is still a hold, because a **rule is the weaker of the two
available instruments and the stronger one is already written down.**

The ledger records an **origin-evidence gate** in the same section: after minting and pushing, run
`git fetch origin` and confirm the outbox commit appears in `git log origin/main` from the shared
root, recording the command and its output in the outbox itself. That is a *procedure with an
artifact*. It catches this failure mechanically -- a never-committed outbox cannot appear in
`git log origin/main` -- whereas a rule saying "commit your outbox" restates the intention of someone
who already intended it.

**So the recommendation is to promote the gate, not the rule.** The distinction matters: the failure
was not a missing intention, it was a missing *confirmation step*. The gate is currently recorded as
a finding, applied by individual dispatches to themselves (including this one) but binding on none.

**What would change this:** if the gate is adopted and the failure recurs anyway, the candidate
should be promoted as a rule, because that would establish the gate is insufficient.

---

## Candidate 5 -- negative findings about accumulating quantities

> A negative finding about an *accumulating* quantity must state when it was measured, and should be
> re-measured at close-out before it is recorded. One early sweep of a leak is indistinguishable from
> no leak: this dispatch measured zero stale statusline shells at session start and three an hour
> later, and the first number would have shipped as "no leak reproduced".

**Second observation:** No -- first observation (ledger).

**Evidence, re-derived from disk 2026-08-21.** The paired measurement is in the ledger and is what
makes this candidate unusually well-evidenced for a first observation: **0 stale shells at session
start, 3 an hour later**, both sweeps excluding the dispatch's own pids. The ledger is explicit that
the section previously said "no leak reproduced" and that the close-out sweep **falsified its own
document**.

The mechanism is stated and checkable: statusline shells respawn on a two-second refresh interval
(`statusLine.refreshInterval: 2`), so an accumulating population is the *expected* failure mode if
any fail to exit.

**Recommendation: PROMOTE -- with the scope narrowed.**

The reasoning that separates this from the other single-observation candidates is that its failure
mode is **a measurement that is wrong in a specific, predictable direction**. A single early sweep of
an accumulating quantity does not return a noisy answer -- it returns **zero**, confidently, and zero
is the most publishable number there is. The error is systematic, it favours the comfortable
conclusion, and nothing downstream can detect it: a reader sees a clean negative finding with a real
measurement behind it.

That is the same family as the project's already-established "unknown is not zero" discipline in the
threat model, and this dispatch hit an instance of the same shape from a different direction -- a
metric whose true value was `0` was nearly reported as *absent* because an aggregator's filter
discarded falsy values. **The general lesson is that zero and absent are different, in both
directions**, and this candidate is the measurement-time half of it.

**Narrow it to what the evidence supports.** The candidate as written says "must state when it was
measured, and *should* be re-measured at close-out". Promote the first clause and the accumulating-
quantity re-measure; do **not** promote a blanket re-measure-everything obligation, which the single
observation does not support and which would tax every negative finding in the project.

---

## Summary, for the ruling

| # | Candidate | 2nd obs? | Recommendation | The deciding reason |
|---|---|---|---|---|
| 1 | Per-platform evidence for a cross-platform branch | No | **PROMOTE** | Detection cost is two platforms of CI; invisible from the author's own leg |
| 2 | Purity guards hardcoding derived-name allow-lists | No | **HOLD** | Fails loudly in CI; the remedy is an editing convention no rule can enforce |
| 3 | Foreground-CI claims must cite a run id | **Yes** | **PROMOTE** | Meets the stated bar; the failure is silent and propagates into premises |
| 4 | Merged deliverable, uncommitted outbox | No | **HOLD** -- adopt the origin-evidence gate instead | A gate with an artifact beats a rule restating an intention already held |
| 5 | Negative findings about accumulating quantities | No | **PROMOTE**, narrowed | The error is systematic, favours the comfortable answer, and is undetectable downstream |

**Zero promotions executed.** Three promote recommendations, two holds, one of which recommends
adopting a gate that is itself currently only a finding. All of it is Mike's call.
---

## Refresh, 2026-09-06 (dispatch 000282 leg J) -- FINDINGS ONLY

**Nothing below changes any candidate's status, here or anywhere else.** Promotion is Mike's, the
candidate ledger it would be recorded in lives in the hub, and this section is a derivation of what
has accumulated since the docket above was assembled by dispatch 000269. The five candidates above
are untouched.

Derived by reading `rule_observations` in every `projects/powershell-lsp/outbox/` entry from 000270
through 000281 as they stand on disk. **Nine** carry `second_observation: true`.

| # | Candidate, in short | Declared pair | Does the pair hold? |
|---|---|---|---|
| A | At a release cut, diff the `[Unreleased]` band against the merge log, not against itself | **000266 -> 000271** | **Yes.** Two dispatches, the second reproducing the first independently across three PRs |
| B | A latency freeze must record host load at every block boundary and report a load-insensitive comparator | `SLO-BASELINES.md` sections 2 and 10 -> **000273** | **Partly.** The predecessor is a *document* that established the discipline at v1.31.0/v1.32.0, not a second dispatch's independent sighting |
| C | A quiescence probe rooted at its own parent measures the wrong thing when an agent launches it | 000275's own build-time sighting -> **000275** | **No, by the two-dispatch standard.** Both sightings are inside one dispatch's arc; the earlier one is recorded in the probe's own header |
| D | A scriptblock parameter silently captures a same-named outer variable differing only in case | **strategic-dispatch:000251:2 -> 000278** | **Yes.** Two independent dispatches, two different shapes (loop variable, then scriptblock parameter) |
| E | A count written in prose must be recomputed against its own adjacent enumeration | **claude-skills:000004:1 -> 000278** | **Yes**, and unusually well: the 2026-05-27 predecessor names this exact variant and explicitly declines to bank it |
| F | Anchor a structural assertion on the CALL form, never a bare cmdlet or function name | `AirgapBootstrap.Tests.ps1:165` -> **000279** at `f02bbeb` | **Yes on evidence, imprecise on form** -- see below |
| G | Hash a checked-in fixture's CONTENT with EOL normalized, never the bytes git checked out | the standing never-assert-a-worktree-EOL rule -> **000279** | **It is a confirmation, not a crossing** -- see below |
| H | A check naming a local collection and a nearby scalar with the same letters in different case has already broken | cites **000251** -> **000280** | **Yes**, but it is the *same family as D*. Counted separately by the two outboxes; on the family view this is a third sighting, not a second |
| I | A recorded check whose control arm anchors on a mutable ref cannot be falsified | **000280 -> 000281** | **Yes**, and 000281 declares it the family's THIRD sighting with both predecessors cited |

> **000280 and 000281 are filed under `powershell-lsp` and are hub-side work** (the PK collector).
> They are included because the charter's scope is the project's outbox directory, and excluded from
> nothing else; a promoter should know their subject is not the plugin.

### The two 000279 self-declarations, tested rather than accepted

The charter asked specifically whether these two hold. Dispatch 000282's own leg I census swept
`tests/` for both hazards tonight, which is the evidence they were missing.

**F -- anchor on the call form. The self-declaration holds, and tonight it got stronger.** The
declared pair is imprecise in *form*: the predecessor is a correction recorded in a code comment at
`tests/PowerShellLsp.AirgapBootstrap.Tests.ps1:165`, not a second dispatch id, so this is not
strictly two dispatches independently observing one failure. On *evidence* it is stronger than the
bar asks: the leg I census found a **third, live, currently-shipping instance** --
`tests/PowerShellLsp.Unit.Tests.ps1:2272`, where `$src.IndexOf('Test-PinnedFileHash')` resolves to a
header comment on line 5 of `ensure-pses.ps1` rather than to the call. That test claims to prove the
pin gate runs before extraction, and it **passes with the pin-gate call deleted**, which was
verified by mutating the source and re-running the comparison. Its own stated adversarial control is
therefore false. A rule with a live third instance that hides a vacuous security assertion is the
strongest promotion case in this table.

**G -- hash content, not the checkout. It is a confirmation of an already-standing rule, not a
candidate crossing a gate.** Its own reference says so: it is the *"second observation of the
standing never-assert-a-worktree-EOL-property rule, this time in its hash form rather than its
byte-count form."* A standing rule does not get promoted twice. And the leg I census found **zero**
live instances of the hazard under `tests/` -- every hash or byte assertion over a checked-in file
is checkout-invariant by construction (ASCII-only scans, CR-stripped comparisons, or before/after
self-comparisons within one run), and
`tests/PowerShellLsp.SignPlugin.Tests.ps1:110-111` states the correct rule in a comment before
using it. The lesson is absorbed. **Recommendation: record the confirmation, promote nothing.**

### What this refresh recommends

Nothing is promoted here and nothing is ranked against the five candidates above, because those were
argued at length and these have not been. The one finding that deserves a decision rather than a
row is **F**, on the strength of the live instance leg I found. Everything else is recorded so that
a future promoter reads an accumulated set rather than re-deriving it.
