# powershell-lsp -- relaunch channel plan (FINDINGS ONLY, nothing published)

**What this document is.** The channel half of the relaunch planning docket chartered by dispatch
000262: which channels the 2026-07-05 launch actually reached, which channels a relaunch could
reach, what content fits each one and why, and a re-runnable derivation of the relaunch gate
recorded in [ROADMAP.md](../../ROADMAP.md), section "The relaunch -- substance as the pitch".

**What this document is not.** It publishes nothing, submits nothing, and comments nowhere. No
Reddit post, no forum post, no repository submission, no comment on any external issue or thread
was made by the dispatch that wrote this file. **External publishing is Mike's gate, without
exception**, and the gate below being met would not change that -- the trigger is his hand, not
this document's discovery of readiness. That boundary is the project's standing posture
([ROADMAP.md](../../ROADMAP.md), "Operating posture": the product / positioning / sequencing calls
are named human gates).

---

## 1. The gate, derived against the live lanes

The gate has two arms, both of which must hold:

1. The **Next** lane is empty.
2. Every item in **Gated and paced** is either upstream-blocked (naming a real external issue
   number) or demand-paced with no live signal recorded.

**Verdict as of 2026-08-17: the gate is NOT met, and it fails on both arms.** It is recorded here
as a finding; no action follows from it either way.

### Arm 1 -- the Next lane is NOT empty

[ROADMAP.md](../../ROADMAP.md), section "Next", carries **three** items: the doctor and command
surface, agent-facing semantic exposure, and the measured-baseline follow-through. Three is not
zero, so arm 1 fails on the first read. Nothing further is needed to settle the gate; arm 2 is
derived anyway, because a partial derivation would have to be redone rather than re-read.

### Arm 2 -- per item, against "Gated and paced"

| # | Item | Which arm it could satisfy | Holds? |
|---|---|---|---|
| 1 | Native code navigation | upstream-blocked, names `claude-code#86936` | **YES** |
| 2 | Corpus commons | neither -- the gating audit has **passed** | **NO** |
| 3 | Attested diagnostics | demand-paced, re-gated on a verifying consumer | **YES** |
| 4 | Enterprise control plane | demand-paced, but a signal arrived | **NO** |
| 5 | Scale and robustness | demand-paced, activation signal unmet | **YES** |
| 6 | Deeper rule curation | demand-paced by the dogfood log | **YES** |

**Item 2 fails because the thing gating it is gone, not because it is waiting.** ROADMAP.md's own
line says the licensing and provenance audit "has **passed**", and that "what remains is a
licensing decision at activation, not an audit". A decision awaiting a human is neither an
upstream block with an issue number nor an absence of demand, so it satisfies neither arm.
[docs/roadmap-ii/CORPUS-PROVENANCE-AUDIT.md](CORPUS-PROVENANCE-AUDIT.md), section 7 ("The gate
verdict, derived"), is the audit this line refers to.

**Item 4 fails on the "no live signal recorded" clause specifically.** The lane is demand-paced,
which is the right half; but ROADMAP.md records in the same bullet that "an adoption signal
arrived -- a corporate-IT review ranked runtime dependency downloads with no offline path as the
top tractable adoption blocker", and
[docs/decision-ledger.md](../decision-ledger.md), section "Dispatch 000257 leg D", chartered the
policy-integrity verification slice off a second, in-repo signal. A recorded live signal is
exactly what the clause excludes.

Items 1, 3, 5 and 6 hold, each for a reason that is on disk rather than asserted:

- **Item 1** names a live external issue. ROADMAP.md cites
  `anthropics/claude-code#86936` as the un-gate condition for the suspended serve-transport
  mappings, and [docs/decision-ledger.md](../decision-ledger.md), section "Dispatch 000257 leg G",
  records it as OPEN as of 2026-08-17.
- **Item 3** was re-gated on 2026-08-17 to "a named consumer that actually verifies"
  ([docs/decision-ledger.md](../decision-ledger.md), section "Dispatch 000257 leg C"). No such
  consumer is recorded, and that entry states there is no in-repo demand row at all.
- **Item 5** was parked on 2026-08-17 with an explicit activation signal -- a real repository
  reporting an edit past the 5000 ms cap ([docs/decision-ledger.md](../decision-ledger.md),
  section "Dispatch 000257 leg A"). No such report is recorded.
- **Item 6** is paced by the dogfood log, and the log is close to empty: leg F measured the
  efficacy channel at six canonical-checkout rows lifetime and zero in the preceding nine days
  ([docs/decision-ledger.md](../decision-ledger.md), section "Dispatch 000257 leg C", which cites
  that measurement).

### How to re-run this derivation

Read [ROADMAP.md](../../ROADMAP.md)'s "Next" and "Gated and paced" sections directly and answer
the two arms. The table above is a snapshot with its date stated; the lanes are the authority. A
future dispatch should re-derive rather than cite this table, on the project's own standing rule
that ground truth wins over any document ([ROADMAP.md](../../ROADMAP.md), "Operating posture").

---

## 2. Channels the 2026-07-05 launch reached

Both are recorded in [docs/decision-ledger.md](../decision-ledger.md), section 6 ("Standing items
(Mike-gated)"), under the bullet "**Launch -- done.**": "The r/PowerShell and r/ClaudeCode launch
posts are live (2026-07-05)".

| Channel | Reached | In-repo artifact |
|---|---|---|
| r/PowerShell | 2026-07-05 | [docs/launch/reddit-powershell.md](../launch/reddit-powershell.md) |
| r/ClaudeCode | 2026-07-05 | **none** -- see the finding below |

**Finding R1 -- only one of the two reached channels has an in-repo draft.** `docs/launch/`
contains exactly one file, `reddit-powershell.md`, whose own title line reads "r/PowerShell launch
post -- claude-powershell-lsp". The r/ClaudeCode post is recorded as live in the ledger but has no
artifact in the repository, so its text cannot be reviewed, diffed, or reused as a relaunch
starting point. For a project whose pitch is that every claim traces to something reproducible,
that is a gap worth closing before the relaunch rather than during it.

**What the existing draft is worth to a relaunch.** It is v1.23.0-era ground truth by its own
header, and the current release is v1.31.2 ([docs/decision-ledger.md](../decision-ledger.md),
header paragraph). Eight minor and patch versions of drift means it is a **voice** reference, not
a content reference: reusable for tone and structure, not for any version, knob, or count.

---

## 3. Candidate channels not reached, each with its rationale

Two groups, kept separate on purpose. Group A channels are grounded in an on-disk record. Group B
channels were named by the 000262 charter and have **no on-disk record** -- they are carried here
with that stated plainly rather than dressed up with evidence the repository does not contain.

### Group A -- grounded on disk

**A1. `anthropics/claude-plugins-community` (the community marketplace).**
*Content that fits:* a marketplace entry, not a post -- name, one-line description, install path.
*Rationale, on disk:* [docs/decision-ledger.md](../decision-ledger.md), section 4 ("Forward plan
-- the four-horizon ladder"), bullet "**E2.3 Catalog listing.**" records a read-only poll on
**2026-07-22T20:50:16Z**: `claude-powershell-lsp` is **not present**, across **2262** plugin
entries, with **zero** entries whose name matches `powershell` at all. That last number is the
argument: the marketplace's PowerShell shelf is empty, so this is not a crowded channel to enter.
The same bullet notes the catalog grew by 14 entries since the prior poll, so the absence is a
live negative rather than a stale read. *Boundary:* the submission itself is recorded there as
Mike's gate.

**A2. The official Claude Code plugin catalog (Console form).**
*Content that fits:* the same catalog entry, through the Console.
*Rationale, on disk:* the E2.3 bullet above names it -- "and the official catalog if it
qualifies". *Boundary, and it is a hard one:* [ROADMAP.md](../../ROADMAP.md) carries an explicit
blockquote in "Gated and paced" -- submission is maintainer-owned, is **not** tracked as an open
action, goes through a Console form invisible to the API, and **a prior session already caused a
duplicate submission by inferring state from a stale page**. So this channel's plan is one line:
ask the maintainer. Do not query, and do not infer.

**A3. `anthropics/claude-plugins-official#1359` (a follow-up comment on an open upstream issue).**
*Content that fits:* a short factual comment when something material changes -- not a relaunch
announcement.
*Rationale, on disk:* [docs/decision-ledger.md](../decision-ledger.md), section 6, records that
"our refreshed comment on anthropics/claude-plugins-official#1359 is posted (2026-07-05, the issue
itself stays OPEN)", and section "Dispatch 000257 leg G" records it still OPEN as of 2026-08-17
and names it as the gate on the interactive-editor surfaces. A channel already used once, with a
standing thread, is the cheapest of these to reach and the easiest to misuse.

**A4. The corporate-IT reviewer who filed the 2026-08-15 review (a direct return).**
*Content that fits:* not launch copy at all -- a two-line "both of your blockers are closed"
follow-up, plus the offline path and the licence text.
*Rationale, on disk:* [docs/decision-ledger.md](../decision-ledger.md), section "Dispatch 000247",
records that the **2026-08-15 corporate-IT review ranked GPLv3 as adoption-blocker number one**
once offline bootstrap -- blocker zero -- was closed by dispatch 000244; the relicence to
Apache-2.0 closed the first. Section "Dispatch 000257 leg C" states both blockers are "since
answered (000244, 000247)". This is the only candidate channel where a named external party
already stated its objections **and** the repository can show both are closed -- which is the
evidentiary-discipline pitch in its most concentrated form.

**A5. `PowerShell/PowerShellEditorServices` -- a channel the project has CLOSED to itself.**
Recorded so that its absence reads as a decision rather than an oversight.
*Rationale, on disk:* [docs/upstream/pses-2297-pr.md](../upstream/pses-2297-pr.md) records PR
#2299 as closed unmerged and states, in the file's own words, "**Nothing further is to be
submitted from this file, by anyone, Mike included.**" Upstream PSES is not a relaunch channel.

**Not a channel, recorded to prevent a category error.** The `anthropics/claude-code` issue
tracker (`#73961`, `#86936`, `#74289`, `#66987`) is a defect channel this project already uses
correctly. Posting relaunch content there would be a misuse of a working relationship.

### Group B -- named by the charter, no on-disk record

Both are listed because dispatch 000262 named them. Neither carries repository evidence, and
neither should be described as though it does.

**B1. `awesome-claude-code` (and comparable Claude-ecosystem lists).**
*Status:* **no on-disk record of any kind.** A repository-wide search of all Markdown files for
`awesome-claude-code` returns zero matches, so there is no submission, no pending submission, and
no prior contact recorded here. The 000262 charter's phrase "once its pending submissions
resolve" describes something this repository cannot corroborate; it is repeated here only as the
charter's own wording, not as a finding.
*Content that would fit, if it is pursued:* a one-line entry, which is the same artifact as A1.
*Rationale:* list inclusion is durable in a way a dated post is not -- a Reddit thread's value
decays in days, a list entry keeps returning traffic. That reasoning is general, not measured
here.
*Required first step:* establish the actual state from the maintainer, exactly as A2 requires.

**B2. Hacker News.**
*Status:* **no on-disk record.** No prior HN post, submission, or discussion appears anywhere in
this repository.
*Content that fits, and why this channel is the best match for the relaunch's own thesis:* HN's
comment section is adversarial by design, and the repository is unusually well-equipped for it --
a false-positive rate that is recomputed rather than asserted
([README.md](../../README.md), "Diagnostic-correctness corpus"), five SLO metrics that publish
their own exclusion boundaries and their ugliest result
([docs/roadmap-ii/SLO-BASELINES.md](SLO-BASELINES.md), sections 5 and 8), and a declines table
that says what was turned down and why ([ROADMAP.md](../../ROADMAP.md), "Declined, and why").
A channel that punishes unsupported claims is the one where "every claim is checkable" is a real
advantage rather than a slogan.
*The risk, stated because it is the real one:* the same section 8 that makes the project credible
also documents an edit path that fails to converge on a 219 KB file. That finding will be read.
The plan is that it is quoted first by the author rather than found first by a commenter.

---

## 4. Findings from building this plan

**F1 -- the roadmap gate's own wording points the wrong way, and was preserved anyway.** The gate
sentence reads "the Next lane **above** is empty", but dispatch 000262 also specified the
section's placement as immediately after North Star and before Now -- which puts **Next below it,
not above**. The charter required the approved text be copied exactly and explicitly forbade
paraphrasing or improving it, so it was copied exactly and the discrepancy is recorded here
instead. It is directional wording only: both lanes are named unambiguously by heading, so the
gate remains checkable as written. A one-word fix ("below") is available whenever Mike wants it.

**F2 -- the gate's second arm names "Gated and Paced"; the live heading is "Gated and paced".**
Recorded so a future automated check matches on the real heading rather than the gate's casing.

**F3 -- the corpus anchor cited in 000262 is one character off.** The dispatch anchors
README.md section "Diagnostic correctness corpus"; the live heading is
"**Diagnostic-correctness corpus**", hyphenated. The section exists and carries exactly the
claims the charter expected (0% false-positive rate over 50 known-good cases, 100% true-positive
coverage over 36 known-bad, recomputed on every CI run), so this is a citation-form defect and
not premise drift.

**F4 -- the white paper's own decline gate now reads as satisfied, and that is Mike's call to
make, not this dispatch's.** [docs/decision-ledger.md](../decision-ledger.md), section 9
("External technical review, round 3"), carries `review-declined: whitepaper-now` with the
reason that a paper written then "would restate `benchmarks.md`, `TRUST.md` and `ARCHITECTURE.md`
at greater length", and the condition that "it becomes worth writing when legs 1 and 2 have
produced numbers it can carry". Numbers now exist that did not then --
[SLO-BASELINES.md](SLO-BASELINES.md) publishes five metrics with medians, spread and exclusion
boundaries. Whether that discharges the decline is a positioning call and is not decided here;
[WHITE-PAPER-OUTLINE.md](WHITE-PAPER-OUTLINE.md) is an outline under the same findings-only
boundary, not a draft.
