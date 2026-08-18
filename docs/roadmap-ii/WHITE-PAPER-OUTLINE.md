# powershell-lsp -- white-paper OUTLINE (structure and citations only, not a draft)

**What this document is.** A section-by-section outline for a technical white paper about this
project, produced by dispatch 000262 under the `technical-whitepaper` skill's default paper
architecture. Every factual claim below carries an inline citation to a file and section that
holds it. It is a structure-and-citations document.

**What this document is not.** It is not the paper, and no section below is drafted prose. The
charter forbade writing white-paper content outside the outline; full drafting is separate, later,
chartered work. Nothing here was published anywhere.

**One gate to note before reading.** A white paper was previously declined --
`review-declined: whitepaper-now` ([docs/decision-ledger.md](../decision-ledger.md), section 9,
"External technical review, round 3") -- on the ground that a paper written then "would restate
`benchmarks.md`, `TRUST.md` and `ARCHITECTURE.md` at greater length", with the condition that "it
becomes worth writing when legs 1 and 2 have produced numbers it can carry". Whether that decline
is discharged is a positioning call reserved to Mike; see finding F4 in
[RELAUNCH-PLAN.md](RELAUNCH-PLAN.md).

---

## 0. Working thesis, audience, and claim discipline

**Working thesis** (the skill's required one-sentence testable form):

> powershell-lsp addresses the absence of trustworthy PowerShell diagnostics in headless and
> automated agent environments through a hook-driven client of PowerShell Editor Services whose
> every result carries an explicit analysis status, enabling an agent to distinguish "clean" from
> "not checked" while accepting that it adds no analysis capability of its own and inherits its
> upstream's limits.

Each clause is anchored: the headless/automated framing is the project's stated North Star
([ROADMAP.md](../../ROADMAP.md), "North Star"); the client-not-reimplementation posture is settled
in the same section; the status discipline is
[ARCHITECTURE.md](../../ARCHITECTURE.md), "The status taxonomy (why a result is never silently
wrong)".

**Audience.** Skeptical engineers, platform and enterprise architects evaluating agent tooling,
and prospective adopters inside managed Windows estates -- the last group because
[TRUST.md](../../TRUST.md), "Allow-listing on managed Windows", already answers questions only
that audience asks.

**Claim labels used throughout this outline**, per the skill's evidence ledger:
**[V]** verified from code/tests/docs, **[M]** measured, **[I]** inferred, **[P]** proposed,
**[U]** unverified. A claim carrying **[U]** may not appear as fact in the paper.

---

## 1. Title

Working title, on the skill's pattern:

> **powershell-lsp: A Status-Honest PowerShell Diagnostics Client for Coding Agents**

"Client" is load-bearing and must survive editing: the project is a client of PowerShell Editor
Services, not a re-implementation ([ROADMAP.md](../../ROADMAP.md), "North Star"). The paper must
not be titled or framed as a language server.

## 2. Abstract

Four beats: problem, contribution, evidence, result.

- **Problem [V]** -- editor-bound PowerShell tooling is unavailable where agents work:
  [ROADMAP.md](../../ROADMAP.md), "North Star".
- **Contribution [V]** -- diagnostics fed back into the agent's own turn, with an explicit
  status: [ARCHITECTURE.md](../../ARCHITECTURE.md), "The lifecycle: edit -> banner".
- **Evidence [M]** -- a 0% false-positive rate, recomputed per CI run rather than asserted:
  [README.md](../../README.md), "Diagnostic-correctness corpus".
- **Result [M]** -- measured baselines exist for five edit-path metrics:
  [SLO-BASELINES.md](SLO-BASELINES.md), section 5.

## 3. Executive Summary

Must be readable without inspecting code, and must state a limitation, not only a result.

- The product in one paragraph: PSES + PSScriptAnalyzer run over the file the agent just edited,
  result returned into the same turn -- [README.md](../../README.md), opening section (lines
  16-22) and "How it works (warm-start daemon)" **[V]**.
- The distinguishing property: a result is never silently wrong; every edit resolves to a
  truthful terminal status -- [ARCHITECTURE.md](../../ARCHITECTURE.md), "The status taxonomy
  (why a result is never silently wrong)" **[V]**.
- The honest counterweight, stated in the summary rather than deferred: the edit path does not
  converge on a large file -- [SLO-BASELINES.md](SLO-BASELINES.md), section 8 **[M]**.
- What is deliberately not claimed: the attestation badges are not Authenticode, assert no
  verified-publisher identity, and are not a third-party security audit --
  [README.md](../../README.md), badge blockquote (lines 10-14), and
  [TRUST.md](../../TRUST.md), "Honest limits" **[V]**.

## 4. Problem and Context

- Agents edit PowerShell in environments where an editor extension is not present; that is the
  environment clause of the North Star, and the paper should quote it --
  [ROADMAP.md](../../ROADMAP.md), "North Star" **[V]**.
- A wrong finding costs more than a missing one, which is why defaults stay narrow --
  [ROADMAP.md](../../ROADMAP.md), "Top risks" **[V]**.
- The default surfaced ruleset is narrower than raw PSScriptAnalyzer: six rules on the fly, with
  others dropped -- [README.md](../../README.md), "Diagnostic-correctness corpus" **[M]**.
- PowerShell-specific difficulty (the skill's specialization list) -- the split between static
  analysis and runtime-dependent semantics, and dual-host support across PowerShell 5.1 and 7 --
  [ARCHITECTURE.md](../../ARCHITECTURE.md), "Cross-platform", and
  [README.md](../../README.md), "Platform support" **[V]**.

## 5. Design Goals and Non-Goals

The non-goals are the more interesting half and are all on record.

Four of the six are settled in one place -- [ROADMAP.md](../../ROADMAP.md), "Declined, and why"
-- and the paper should cite that table rather than restate its rows:

- **Not a PSES re-implementation [V]** -- [ROADMAP.md](../../ROADMAP.md), "North Star".
- **No file watcher / background workspace sweep [V]** -- declines table.
- **No new custom rules; no custom-rule seam pending demand [V]** -- declines table.
- **Broader ruleset stays opt-in, not default [V]** -- declines table.
- **No Authenticode publisher signing of the scripts [V]** -- declines table, and
  [TRUST.md](../../TRUST.md), "Signing posture", which states the reasoning at length.
- **No recurring prompt injection into agent context [V]** --
  [README.md](../../README.md), opening section (line 20).

## 6. Existing Approaches and Tradeoffs

The skill forbids asserting superiority over PSES, and the project's own posture agrees, so this
section compares **integration shapes**, not quality.

- Dimension set to use: coupling to an editor, protocol coverage, runtime dependencies, startup
  behavior, observability, security boundary, maintenance model (the skill's Phase 5 list).
- Where this project sits on registration specifically -- why a hook rather than native
  `.lsp.json` registration -- [README.md](../../README.md), "Why a hook, not native `.lsp.json`
  registration" **[V]**.
- Where the alternative is genuinely stronger, and the paper must say so: the native navigation
  triad (hover / definition / references) does not work on the direct path, and the shipped
  workaround is an opt-in shim -- [ROADMAP.md](../../ROADMAP.md), "Gated and paced" **[V]**.
- Positional queries are declined for agents on a stated reason, not for lack of capability:
  they would be confidently wrong against stale line numbers --
  [docs/decision-ledger.md](../decision-ledger.md), section "Dispatch 000257 leg G" **[V]**.

## 7. System Architecture

- The one-paragraph model, then the component list -- [ARCHITECTURE.md](../../ARCHITECTURE.md),
  "The one-paragraph model" and "The pieces (`scripts/`)" **[V]**.
- Edit-to-banner lifecycle, which is the paper's primary sequence exhibit --
  [ARCHITECTURE.md](../../ARCHITECTURE.md), "The lifecycle: edit -> banner" **[V]**.
- Warm-daemon design: one process serves the whole session, so each edit pays a pipe round-trip
  rather than a cold start -- [README.md](../../README.md), "How it works (warm-start daemon)"
  **[V]**.
- Where state lives, which the security section later depends on --
  [ARCHITECTURE.md](../../ARCHITECTURE.md), "Where state lives" **[V]**.
- The invariants that may not be broken -- [ARCHITECTURE.md](../../ARCHITECTURE.md), "What you
  must not break" **[V]**.

## 8. Key Technical Contributions

The skill caps this at three. Each is stated with problem, mechanism, benefit, tradeoff, evidence.

**C1 -- Status honesty as a protocol property, not a quality goal.**
Mechanism and taxonomy: [ARCHITECTURE.md](../../ARCHITECTURE.md), "The status taxonomy (why a
result is never silently wrong)" **[V]**. Measured cost of the design: exactly one edit per
session returns "NOT checked" on a small file, 10 of 10 sessions, spread zero --
[SLO-BASELINES.md](SLO-BASELINES.md), section 6.2, Finding 4 **[M]**. Tradeoff: that guarantee
does **not** hold on a large file -- section 8, and candidate target T3 in section 9 **[M]**.

**C2 -- A correctness oracle that is recomputed rather than asserted, and cannot be gamed by
shrinking.**
Mechanism: expected findings are derived by running the real tool and snapshotting its output --
never hand-authored, never model-authored -- and CI floors each scored set at 30 fixtures so a
rate cannot be improved by withdrawing cases ([README.md](../../README.md),
"Diagnostic-correctness corpus") **[V]**. Result: 0 of 50 known-good produced a finding; 36 of 36
known-bad surfaced the expected rule, on all four CI legs **[M]**. Tradeoff, in the document's own
words: the claim is measured and defensible, not exhaustive **[V]**. Provenance of the fixtures
themselves is separately audited --
[CORPUS-PROVENANCE-AUDIT.md](CORPUS-PROVENANCE-AUDIT.md), sections 3 and 7 **[V]**, with its
stated boundary in section 8 **[V]**.

**C3 -- A decision record that carries declines with the same weight as ships.**
Mechanism: a public declines table pointing into a full ledger --
[ROADMAP.md](../../ROADMAP.md), "Declined, and why", and
[docs/decision-ledger.md](../decision-ledger.md), header **[V]**. Worked examples the paper should
use rather than summarize: the A/B efficacy experiment declined for lack of pre-registration, and
the white paper itself declined until numbers existed to carry it
([docs/decision-ledger.md](../decision-ledger.md), section 9) **[V]**. Tradeoff to state plainly:
a declines table is only evidence of restraint if the declines are real and revisitable -- the
custom-rule seam is recorded as "declined pending demand", not declined permanently
([ROADMAP.md](../../ROADMAP.md), "Declined, and why") **[V]**.

## 9. Implementation

- Configuration surface and its freeze: the two-tier contract and the mechanically enforced tier
  -- [CONTRACT.md](../../CONTRACT.md), "The two tiers" and "Tier 1 -- Contractual
  (semver-protected, mechanically enforced)" **[V]**.
- Why documentation drift is structurally prevented rather than promised: the knob table, the
  frozen-knob list and the manifest are set-equality guarded in CI --
  [ROADMAP.md](../../ROADMAP.md), "Top risks", and [CONTRACT.md](../../CONTRACT.md), "How this
  contract is enforced (the drift-guard)" **[V]**.
- Pinning of the two downloaded dependencies, by version **and** hash --
  [TRUST.md](../../TRUST.md), "What it downloads (pinned versions AND pinned hashes)" **[V]**.
- Shipped capability inventory, for the "what exists today" boundary the skill requires against
  roadmap intent -- [CURRENT-STATE.md](CURRENT-STATE.md), section 4 **[V]**.

## 10. Evaluation

Titled per the skill's rule as an evaluation of **current evidence**, because one central
question is still unmeasured (see section 12).

- Method and instruments, including the one instrument defect found and fixed mid-measurement --
  [SLO-BASELINES.md](SLO-BASELINES.md), sections 4 and 4.4 **[M]**.
- Environment, build identity, and the fact that the measured build **is** the released tag
  commit -- [SLO-BASELINES.md](SLO-BASELINES.md), section 1 **[M]**.
- The five metrics and their exclusion boundaries, reproduced as the paper's core table --
  [SLO-BASELINES.md](SLO-BASELINES.md), section 5 **[M]**.
- Headline figures, with their spread, exactly as published and not rounded: warm per-edit
  end-to-end wall median 2997 ms over N=30, zero exclusions; daemon `analysisMs` median 1407 ms
  with 37 ms spread; cold start to first settled analysis median 9523 ms over N=10; combined
  steady-state working set about 318 MB -- [SLO-BASELINES.md](SLO-BASELINES.md), sections 6.1,
  6.2 and 6.3 **[M]**.
- The instrument-coverage finding that any latency claim must carry: the shipped stats log
  understates user-visible per-edit latency by 931 ms, 45% of the recorded figure --
  [SLO-BASELINES.md](SLO-BASELINES.md), section 6.1, Finding 1 **[M]**.
- The negative result, reported first rather than buried: on a 3,881-line file, 1 of 5 cold
  sessions converged under a uniform attempt cap, and the mechanism is the daemon's 5000 ms
  settle cap compounding with a client connect timeout that relaunches the daemon doing the work
  -- [SLO-BASELINES.md](SLO-BASELINES.md), section 8 **[M]**.
- Prior latency figures are historical, measured at different versions with different
  definitions, and may not be restated as current -- [SLO-BASELINES.md](SLO-BASELINES.md),
  section 10, and [docs/benchmarks.md](../benchmarks.md), "Method, stated honestly" **[V]**.
- Sustained-session stability confirmed over 120 edits / 6.5 minutes, with the honest bound on
  that claim stated in the same breath -- [SLO-BASELINES.md](SLO-BASELINES.md), section 6.5,
  Finding 6 **[M]**.

> **Discipline note for the drafter.** [SLO-BASELINES.md](SLO-BASELINES.md) adopts no SLO; every
> target in its section 9 is unratified and awaits ratification (stated in its own preamble,
> "What this document is not"). The paper must not promote a candidate target into a promise.

## 11. Security and Operational Considerations

Separate implemented, assumed, environmental, and recommended-future controls -- the skill's
Phase 10 split.

- Implemented: what the plugin executes and what it does not --
  [TRUST.md](../../TRUST.md), "What it executes -- and what it does NOT" **[V]**.
- Implemented: every external GitHub Action pinned to an immutable commit SHA, with three
  independent enforcements (repository policy, a CI gate, Dependabot) --
  [TRUST.md](../../TRUST.md), "Every external GitHub Action is pinned to an immutable commit SHA"
  **[V]**.
- Implemented: per-release CycloneDX 1.5 SBOM plus a SLSA build-provenance attestation over the
  source archive and the SBOM, verifiable with `gh attestation verify` --
  [TRUST.md](../../TRUST.md), "Supply-chain artifacts: SBOM + build provenance" **[V]**.
- Implemented: keyless, transparency-logged Sigstore signing of release tags --
  [TRUST.md](../../TRUST.md), "Signing posture" **[V]**.
- Environmental: AppLocker and WDAC / App Control allow-listing rules for managed estates, and
  the org-certificate paved path for estates that want their own signature --
  [TRUST.md](../../TRUST.md), "Allow-listing on managed Windows" and "Sign it yourself: the
  org-certificate paved path" **[V]**.
- Boundaries and open items, which the paper must include rather than only the controls: trust
  boundaries and the threats walked against them --
  [THREAT-MODEL.md](THREAT-MODEL.md), sections 2 and 3 **[V]**; the model's own coverage limits
  -- section 6 **[V]**; and the OPEN findings register -- section 8 **[V]**.
- Degradation behavior when analysis cannot run -- [TRUST.md](../../TRUST.md), "Honest
  degradation (the L3 behavior)" **[V]**.

## 12. Limitations

The skill requires limitations in the main paper. All of these are already published.

- **[M]** The edit path does not converge on a 219 KB file --
  [SLO-BASELINES.md](SLO-BASELINES.md), section 8.
- **[M]** The baselines are one host, one OS, one PowerShell version and one analyzer pin; they
  are not a quiet-window measurement and are not CI-wired --
  [SLO-BASELINES.md](SLO-BASELINES.md), section 10.
- **[M]** The file-size curve has two points, not a curve -- same section.
- **[V]** Native navigation is upstream-gated and the shipped shim is a workaround --
  [ROADMAP.md](../../ROADMAP.md), "Gated and paced".
- **[U]** Whether the plugin makes an agent write better PowerShell is **unmeasured**, and the
  A/B that would answer it is declined absent pre-registration --
  [docs/decision-ledger.md](../decision-ledger.md), section 9.
- **[V]** Known limitations and measurement gaps, enumerated --
  [CURRENT-STATE.md](CURRENT-STATE.md), sections 6 and 10.
- **[V]** Single-maintainer bus factor --
  [CONTINUITY.md](../../CONTINUITY.md), "The risk, stated plainly".

**The efficacy row is the paper's single most important honesty test.** It is the question a
third external review named as the bottleneck, and the project's answer was to measure rather
than argue and to decline the improvisable version of the experiment
([docs/decision-ledger.md](../decision-ledger.md), section 9). The paper states the gap; it does
not fill it.

## 13. Adoption and Integration

- Install-and-verify path, including the first-session bootstrap that cannot be skipped --
  [README.md](../../README.md), "Quick start" and "Prerequisites" **[V]**.
- What a first-time user actually experiences, walked and classified rather than assumed --
  [DX-AUDIT.md](DX-AUDIT.md), sections 3 and 5 **[M]**, with what was deliberately not walked in
  section 6 **[V]**.
- Enterprise posture: offline / air-gapped bootstrap and the Apache-2.0 relicense, both closing
  named blockers from a 2026-08-15 corporate-IT review --
  [docs/decision-ledger.md](../decision-ledger.md), sections "Dispatch 000247" and "Dispatch
  000257 leg C" **[V]**.
- Enterprise gaps still open, stated in the same section as the wins --
  [CURRENT-STATE.md](CURRENT-STATE.md), section 11 **[V]**.
- Governance and sustainability, stated as adoption risk rather than omitted --
  [TRUST.md](../../TRUST.md), "Governance and sustainability (adoption risk, stated honestly)",
  and [CONTINUITY.md](../../CONTINUITY.md), "What survives without the maintainer" and "The fork
  path (Apache-2.0)" **[V]**.

## 14. Roadmap

Kept strictly separate from implemented state, per the skill's Phase 12 integrity gate.

- The lanes as published, with each paced item naming what it waits on --
  [ROADMAP.md](../../ROADMAP.md), "Now", "Next", "Gated and paced" **[V]**.
- Per-initiative detail, classification, and gates -- [PROGRAM.md](PROGRAM.md) **[V]**.
- The relaunch's own gate and its current derivation -- [ROADMAP.md](../../ROADMAP.md), "The
  relaunch -- substance as the pitch", and [RELAUNCH-PLAN.md](RELAUNCH-PLAN.md), section 1
  **[V]**.
- Upstream dependencies the project cannot close itself --
  [CURRENT-STATE.md](CURRENT-STATE.md), section 7 **[V]**.

## 15. Conclusion

Restates the thesis against what the evidence did and did not establish. It must end on the
unmeasured efficacy question (section 12) rather than on the corpus result, or the paper becomes
the marketing copy the charter set out not to write.

## 16. References

In-repo primary sources, each cited by section above: [ROADMAP.md](../../ROADMAP.md),
[README.md](../../README.md), [ARCHITECTURE.md](../../ARCHITECTURE.md),
[CONTRACT.md](../../CONTRACT.md), [TRUST.md](../../TRUST.md),
[CONTINUITY.md](../../CONTINUITY.md), [docs/decision-ledger.md](../decision-ledger.md),
[docs/benchmarks.md](../benchmarks.md), [SLO-BASELINES.md](SLO-BASELINES.md),
[CORPUS-PROVENANCE-AUDIT.md](CORPUS-PROVENANCE-AUDIT.md), [THREAT-MODEL.md](THREAT-MODEL.md),
[CURRENT-STATE.md](CURRENT-STATE.md), [DX-AUDIT.md](DX-AUDIT.md), [PROGRAM.md](PROGRAM.md).

External sources must be primary and dated at draft time: the upstream issues named in
[ROADMAP.md](../../ROADMAP.md), "Gated and paced", and the LSP and SLSA specifications. **No
external claim may be carried from this outline** -- none is made here.

## 17. Appendices

- Reproduction commands for every measured claim, taken from the source documents rather than
  re-derived: the corpus recomputation is CI-run and guarded
  ([README.md](../../README.md), "Diagnostic-correctness corpus"), and the SLO harness method is
  described in enough detail to rebuild in [SLO-BASELINES.md](SLO-BASELINES.md), section 4, with
  its scratch-artifact status stated in section 10 **[V]**.
- Verification commands a reader can run against a downloaded release --
  [README.md](../../README.md), "Verifying your install and a release", and
  [TRUST.md](../../TRUST.md), "Supply-chain artifacts: SBOM + build provenance" **[V]**.

---

## 18. Exhibit plan (skill Phase 7 -- exhibits designed before prose)

**E1 -- how does an edit become a banner?** Sequence diagram.
Source: [ARCHITECTURE.md](../../ARCHITECTURE.md), "The lifecycle: edit -> banner".

**E2 -- what can a result mean, and can it lie?** Status table.
Source: [ARCHITECTURE.md](../../ARCHITECTURE.md), "The status taxonomy (why a result is never
silently wrong)".

**E3 -- how correct are the diagnostics, and how is that recomputed?** Two-denominator table,
with the CI gate and the 30-fixture floor noted beside it.
Source: [README.md](../../README.md), "Diagnostic-correctness corpus".

**E4 -- what does an edit cost, and what does the instrument miss?** Latency table carrying
spread, with the 931 ms instrument gap called out rather than buried.
Source: [SLO-BASELINES.md](SLO-BASELINES.md), sections 6.1 to 6.5.

**E5 -- where does it fail?** Convergence table plus a failure-mechanism diagram.
Source: [SLO-BASELINES.md](SLO-BASELINES.md), section 8.

**E6 -- what is signed, and what is deliberately not?** Two-column implemented / not-claimed
table.
Source: [TRUST.md](../../TRUST.md), "Signing posture" and "Honest limits".

**E7 -- what was turned down, and why?** The declines table, reproduced as published.
Source: [ROADMAP.md](../../ROADMAP.md), "Declined, and why".

**E8 -- what is still open?** Open-findings and evidence-gap table.
Source: [THREAT-MODEL.md](THREAT-MODEL.md), section 8, and
[CURRENT-STATE.md](CURRENT-STATE.md), section 10.

Every exhibit above answers a question and names its source. No exhibit is proposed for the
efficacy question, because no data exists to draw one from -- see section 12.

## 19. Open evidence gaps this outline could not close

1. **Agent-efficacy evidence does not exist**, and the experiment that would produce it is
   declined absent a written pre-registration
   ([docs/decision-ledger.md](../decision-ledger.md), section 9) **[U]**.
2. **The dogfood channel is nearly empty** -- six canonical-checkout rows lifetime, zero in the
   preceding nine days ([docs/decision-ledger.md](../decision-ledger.md), section "Dispatch
   000257 leg C") **[M]**, so no field-diagnostic evidence can be carried.
3. **No cross-host latency evidence.** The four CI legs cover other platforms functionally, not
   for latency ([SLO-BASELINES.md](SLO-BASELINES.md), section 10) **[V]**.
4. **The large-file failure is uncharacterized between 54 KB and 219 KB**, and it is not
   established that it reproduces on other hosts
   ([SLO-BASELINES.md](SLO-BASELINES.md), section 8, "What it does not establish") **[V]**.
5. **No comparative measurement against any alternative exists**, so section 6 must stay a
   comparison of integration shapes and must not claim superiority -- which is also the
   `technical-whitepaper` skill's explicit instruction for PowerShell LSP projects **[V]**.
