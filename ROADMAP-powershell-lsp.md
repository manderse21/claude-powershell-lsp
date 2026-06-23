# claude-powershell-lsp -- Roadmap

Status as of 2026-06-22. Plugin on main: **v1.11.0, GPL-3.0-or-later**. The launch-readiness,
licensing, reliability, install-friction, security-block-honesty, and dogfood-capture arcs are all
shipped and verified. The engineering "fast lane" is essentially CLEARED. The project has changed
phase: from building features to (a) feeding two long-pole engines that unlock the next wave, and
(b) closing the delivery gaps that stand between "excellent engineering" and "world-class enterprise
tool." This roadmap is rewritten around that shift, with a senior-reviewer gap analysis (Section 3)
driving the near-term sequence.

Goal (Mike, confirmed): an **open tool** that is **excellent** and **findable** -- NOT a paid
product, NOT adoption-chasing. Platform bet: **the Claude Code LSP-registration fix lands** -- keep
the LSP machinery ready.

---

## Operating posture: how "rapid" actually works here

We move fast. But different work moves at different speeds, and pretending they are one speed is how
a fast project rebuilds the "lots of code, zero validation" problem. The fast lane is now done, which
sharpens the posture rather than retiring it:

1. **Go-fast NOW (engineering, not data-gated).** The original fast lane (reliability, install,
   security-block honesty) is SHIPPED. What remains buildable-today are the DELIVERY-QUALITY gaps a
   reviewer flags (Section 3): test-reliability hardening, release-engineering hardening, a
   performance-benchmark guard, an SBOM, a diagnostic-correctness harness. These are engineering, not
   data-gated -- they go now.

2. **Paced by the dogfood log (cannot compress -- and that is a feature).** Diagnostic QUALITY comes
   from REAL usage surfacing REAL false-positives. The capture engine is now LIVE (000039, v1.10.0);
   the log accumulates on Mike's day-to-day PowerShell work from here. The quality dispatches (rule
   curation, false-positive reduction, fix-suggestion quality) FOLLOW the log; front-running them is
   building on faith. The next dogfood step is the annotation/review tool, worth authoring once the
   log holds real entries.

3. **Approval-gated / time-gated (the enterprise-trust track's slower pieces).** SignPath Foundation
   application is SUBMITTED (the long pole, now off the critical path -- the signing dispatch queues
   on approval). SAC/SmartScreen reputation accrues per-hash over downloads + time -- earned, not
   bought.

4. **Platform-gated (not ours to accelerate at any speed).** No dispatch velocity moves Anthropic's
   backlog. The native LSP triad (hover / go-to-def / find-references) is built and verified,
   unreachable until registration is fixed. A flip-on milestone, not a build.

**"CC decides" -- calibrated.** Within an accepted dispatch's scope, CC deciding implementation,
design, and ripeness-per-track is the proven model -- lean into it. What stays a HUMAN gate, because
that is where recent value came from: **accept (what gets built), merge, F2 verified flip, tag, and
the product / positioning / sequencing calls.** Going fast means a fast gated path, not a removed
gate. (Note: the gated path itself has a reliability bug -- see Gap C / the tag-before-CI-green
pattern in Section 3 -- which is now a near-term fix.)

---

## 1. Shipped & verified

The full arc through v1.11.0. Every row is merged, F2-verified, and (where a version moved) tagged.

| Arc | Dispatch | Delivered | Version | State |
|---|---|---|---|---|
| Launch-readiness | 000024 | Honest install-failure surfacing | -- | verified |
| | 000026 | Non-Windows fd-leak fix | -- | verified |
| | 000025 | Full surface documented | -- | verified |
| | 000027 | 1.x CONTRACT freeze + drift-guard | -- | verified |
| | 000028 | Pipe-first daemon: no silence window (+ warm-start) | v1.6.0 | verified |
| Licensing | 000029 | Relicense MIT -> GPLv3 (+ real MIT-notice fix) | v1.6.1 | verified |
| Hub tooling | 000130 | Interactive `dispatch ship --pr` cuts a worktree off origin/main | -- | verified |
| Reliability | 000030 | Auto-relaunch the idle-stopped daemon (silent recovery, bounded) | v1.7.0 | verified |
| Install-friction | 000035 | README quick-start + prerequisites checklist | -- | verified |
| | 000036 | Preflight `doctor` self-check (5 report-only checks, named fixes) | v1.8.0 | verified |
| | 000037 | Doctor daemon/pipe-health probe (check 6, runtime liveness, report-only) | v1.11.0 | verified |
| Enterprise-trust (L3) | 000038 | Honest degradation on a security-control block (named control + remediation, never circumvents) | v1.9.0 | verified |
| Quality engine | 000039 | Dogfood diagnostic auto-capture (append-only JSONL, empty verdict, never-committed, fail-safe) | v1.10.0 | verified |

**Product today.** Honest on all four platform legs with no silent-miss window. Surface frozen under
a CI-enforced contract. Auto-recovers a stopped daemon silently. Ships a six-check preflight doctor
(install + runtime liveness) that names the fix for each failure. Names the blocking security control
on a managed-Windows estate (ExecutionPolicy / CLM / WDAC / Defender ASR / Smart App Control) on
positive evidence only, and NEVER circumvents one. Captures every diagnostic to a local dogfood log
so the quality wave can be evidence-ranked. GPLv3, cold-start trimmed. This is a genuinely dependable
open tool with best-in-class honest-failure architecture.

**Note on v1.11.0.** Shipped, verified, and tagged at the dispatch level. The push-event CI hit a
transient failure on the Linux (ubuntu-pwsh) leg only -- a PRE-EXISTING 000029 licensing test
(`PSScriptAnalyzer module retains its MIT LICENSE`, `N_PssaDir` resolved null during bundle setup),
unrelated to the daemon-health change; the other three legs passed 266/266 and the PR's four legs all
passed on identical content. A re-run was requested. This is a transient setup flake, not a
regression -- but it is exhibit A for Gap C (test reliability) in Section 3 and is now a near-term
fix, not a footnote.

---

## 2. Current phase: the inflection

The powershell-lsp build queue is now EMPTY of fast-lane feature work -- by design, not by neglect.
That is the correct state after clearing the engineering lane, and it changes what "next" means:

- There is no obvious "next feature to launch." The next moves are (a) the delivery-quality gaps a
  reviewer flags (Section 3, buildable now), and (b) the reactive engines (dogfood log accumulating,
  SignPath approval pending).
- The two long-pole engines are both RUNNING: the dogfood log captures from today, and the SignPath
  application is in. Their clocks started; the work they gate (quality wave, signing) is downstream.
- So the near-term sequence (Section 4) is front-loaded with the buildable-now gap-closers, with the
  dogfood- and approval-gated work sequenced behind its engine.

---

## 3. The five-star gap analysis (senior-reviewer lens)

The brief: review this as a senior dev-tools reviewer for a leading industry publication would, and
incorporate every gap that stands between the current state and a 5-star "world-class enterprise
tool" verdict.

### The honest verdict

**Engineering and architecture: a strong 4 / 4.5 stars.** The never-silent / honest-failure spine is
genuinely best-in-class -- most linter integrations fail silently; this one is architecturally
incapable of it, with CI-enforced contracts proving it. The security-block honest degradation (name
the control on positive evidence, never circumvent) is sophisticated and exactly right for the
audience. The fail-safe discipline (the hook always exits 0, never breaks editing) is rigorous.
Building the dogfood capture BEFORE the quality wave -- instead of faking validation -- is
methodologically honest. This is better plumbing than most commercial tools ship.

**As a complete enterprise PRODUCT today: ~3.5 stars**, held there by five delivery gaps below. The
good news: the path from 3.5 to 5 is clear, credible, and unusually honest. It is exactly the work in
Section 4.

### The five blockers (each mapped to a roadmap action)

**Gap A -- Diagnostic CORRECTNESS is unproven (the linter's core job).** Everything is honest WHEN it
cannot analyze. But is what it REPORTS correct -- not just present, not just honest-when-absent, but
RIGHT? By the project's own (admirable) admission, the default rule set is unjustified, the
false-positive rate is unmeasured, and there is no correctness corpus. A reviewer's single biggest
question for any linter is "are its findings correct?" -- and that is the one thing the tool cannot
yet demonstrate. The honesty machinery is 5-star; the diagnostic quality is, today, unproven.
-> ACTION: the dogfood-paced quality wave (rule curation, false-positive reduction), PLUS a
   first-class **diagnostic-correctness corpus** (a curated set of known-good / known-bad PowerShell
   with asserted expected findings) -- elevated from a buried bullet to a named track that proves
   correctness, not just honesty-when-absent. The corpus harness is buildable NOW, even before the
   dogfood log ranks the defaults; it is the proof framework the quality wave fills.

**Gap B -- Enterprise TRUST is designed, not DELIVERED.** The core audience is developers on
locked-down Windows estates -- exactly the shops with the strictest approval processes. Today the
tool is unsigned, has no SBOM, no release provenance/attestation, no enterprise approval document
(TRUST.md), no fail-closed hash-verification on the executables it DOWNLOADS, and an unverified
security-disclosure posture. L3 (honest degradation) ships, which is real and valuable -- but for a
tool that downloads binaries and runs code, the trust SURFACE is the literal approve/ban line in a
managed shop, and it is currently a plan rather than a product. The current roadmap's L2/L4/L5 cover
signing and hash-verify but DO NOT mention an SBOM or SLSA-style build provenance, which a 2026
enterprise due-diligence review now treats as table stakes for any tool that pulls executables.
-> ACTION: move the trust track from "planned" to "delivered" once SignPath lands, AND add two items
   the current roadmap lacks -- a published **SBOM** (CycloneDX or SPDX) and **release provenance /
   build attestation** (SLSA-style). Plus verify SECURITY.md is a real disclosure policy (contact,
   scope, response expectation), not a stub.

**Gap C -- Release engineering has avoidable reliability smells.** Three concrete tells a reviewer
auditing the repo would catch: (1) a flaky test just shipped a RED main CI run on a release (the
v1.11.0 `N_PssaDir` Linux flake); (2) tags have been applied BEFORE the push-event CI confirms green,
repeatedly (the tag-after-verify rule exists precisely because this keeps happening, and this round
it caught a genuine red run); (3) there is no performance benchmark or regression guard, and the
version bump is a manual lockstep step. World-class tools have boring, bulletproof release pipelines
where none of this is possible. None of these threaten a FEATURE -- but collectively they read as
process immaturity, and a reviewer cloning the repo to a red main badge docks stars on sight.
-> ACTION: a **test-reliability hardening** pass (fix the `N_PssaDir` Linux flake, sweep for other
   non-determinism, make the suite deterministic across all four legs); **CI-gated tagging / release
   automation** (a release workflow that tags only on green push-CI, generates notes, attaches the
   provenance from Gap B) so tag-before-green is structurally impossible; and a **performance
   benchmark harness** (measure cold-start and warm-path edit-to-diagnostic latency, guard against
   regression in CI, and publish the numbers -- a claim a reviewer wants measured and defended).

**Gap D -- "LSP" in the name vs. single-file reality.** The tool calls itself an LSP and targets
enterprise, but analysis today is edit-scoped and effectively single-file. A real language server
understands the PROJECT -- cross-file symbols, module context, workspace-wide analysis. Project-aware
analysis sits in the roadmap as a dogfood-validated CANDIDATE, but for a tool with "-lsp" in the name
it is closer to table stakes than a nice-to-have. (Genuinely mitigated by the native LSP triad being
upstream-registration-gated, which explains part of the gap and is not the project's fault -- but the
gap is still what a reviewer sees.)
-> ACTION: elevate **project-aware analysis** (honor `PSScriptAnalyzerSettings.psd1` repo-wide,
   module/multi-file context) from a candidate to a named near-horizon track; and keep the native
   triad flip-on ready so the name becomes literally true the moment registration lands.

**Gap E -- Bus-factor / governance (the enterprise adoption question).** It is a solo project.
Enterprise adoption explicitly weighs "what happens if the sole maintainer disappears?" This is not a
code fix, but a 5-star enterprise verdict requires a credible sustainability story: contribution
health (CONTRIBUTING.md exists; a real DCO/CLA posture if outside contributions start), a clear
relicensing/governance position, and ideally a path to a second maintainer or an org home. A reviewer
will note the single point of failure even when the code is excellent.
-> ACTION: acknowledge explicitly as an adoption RISK (not a defect), document the governance /
   sustainability posture in TRUST.md, and treat contributor-readiness (DCO/CLA, a "good first issue"
   surface) as the lever if/when amplification brings contributors.

### The one-line review

"World-class honest-failure ARCHITECTURE attached to a linter whose diagnostic QUALITY is still
unproven and whose enterprise TRUST surface is designed but not yet delivered. Prove the diagnostics
are correct, deliver the signing/SBOM/approval surface, and harden the release pipeline, and this is
a 5-star enterprise tool. The path is clear and the engineering pedigree says it will get there."

---

## 4. Near-term dispatch sequence

Re-ordered around Section 3: front-load the buildable-now gap-closers, sequence the gated work behind
its engine. CC decides implementation within each; Mike gates accept / merge / F2 / tag.

**Buildable now (Gap C and Gap B engineering -- not data- or approval-gated):**

1. **Test-reliability hardening** (Gap C.1). Fix the v1.11.0 `N_PssaDir` Linux flake (robustly resolve
   the vendored PSSA dir, or skip-with-reason when the bundle genuinely is not vendored in that
   environment rather than asserting null), sweep the integration suite for other non-determinism,
   and make all four legs deterministic. FIRST -- a red main on a release is the most visible ding,
   and it is freshly evidenced. (Bounded, mechanical -- a reasonable DeepSeek R1-class candidate.)

2. **CI-gated tagging + release automation** (Gap C.2). A release workflow that tags ONLY on a green
   push-event run, generates release notes from the CHANGELOG, and is the single place a version is
   cut -- making tag-before-green structurally impossible and retiring the manual-lockstep fragility.

3. **Performance benchmark harness** (Gap C.3). Measure cold-start and warm-path edit-to-diagnostic
   latency as a repeatable harness; guard against regression in CI; publish the numbers in the README.
   A measured, defended latency claim is a 5-star differentiator.

4. **SBOM + release provenance** (Gap B, new). Generate a CycloneDX/SPDX SBOM and SLSA-style build
   provenance, attached to releases (folds into item 2's release workflow). Closes the supply-chain
   due-diligence gap for a tool that downloads executables.

5. **Diagnostic-correctness corpus harness** (Gap A, the proof framework). A curated known-good /
   known-bad PowerShell corpus with asserted expected findings, run in CI. Buildable now as the
   FRAMEWORK; the dogfood wave fills and ranks it. This is what lets the tool finally CLAIM
   correctness, not just honesty-when-absent.

**Dogfood-gated (the quality wave -- the log is the engine, now running):**

6. **Dogfood annotation/review tool** (000039's `next_suggested`). Walks unannotated log entries so
   Mike can tag verdicts (false-positive / noisy / useful / bad-fix). Author once the log holds real
   entries -- reviewing an empty log is pointless. (Mechanical/bounded -- a strong DeepSeek candidate.)
7. **Rule curation** -- the default PSSA rule set, justified by the ranked log.
8. **False-positive reduction** -- driven by the annotated log. After 7.
9. **Fix-suggestion quality** -- raise the ceiling on the corrections the tool surfaces.

**Approval-gated (trust track, behind SignPath):**

10. **Authenticode signing pipeline** (L1) -- once SignPath approves; wired into the release workflow
    from item 2 so every release is signed by construction.
11. **Hash-verify the downloaded deps** (L2) -- fail-closed verification of PSES/PSSA against pinned
    known-good hashes.
12. **TRUST.md / enterprise-readiness doc** (L4) -- the approve-or-deny document: what it executes
    (and does NOT -- 100% local, no network service), download provenance + pinned hashes, signing
    provenance, ready-to-paste WDAC/AppLocker allow-list rules, CodeIntegrity 3076/3077 reading, AND
    the governance/sustainability posture (Gap E).

**Parallel, non-blocking:** the upstream good-citizen posts (PSES PR #2299, the LSP-registration
refutation doc) -- findable-now, `gh`-only, no CC.

---

## 5. Enterprise-trust & security track (ADOPTION-CRITICAL)

This is a first-class track, not a checkbox -- the adoption path for the core audience and an
enterprise-quality solution end to end.

**Why it is adoption-critical.** The plugin DOWNLOADS executables (PSES, PSScriptAnalyzer), RUNS
PowerShell, and SPAWNS a daemon -- exactly what locked-down Windows gates: Smart App Control, WDAC /
App Control + AppLocker, ExecutionPolicy, Constrained Language Mode, Defender ASR. PowerShell
developers disproportionately work inside those managed estates. L3 (honest degradation) now ships,
so the tool already tells a blocked user WHAT is blocked and HOW to allow it instead of silently doing
nothing -- the single highest-value piece, delivered. The rest of the track converts "I can see what
is blocked" into "my security team approved it."

**The six layers -- current state:**

- **L1 -- Sign the plugin's PowerShell scripts (foundational).** Authenticode-sign every shipped
  `.ps1`/`.psm1`/`.psd1` via **SignPath Foundation (FREE for qualifying OSS)**. Clears ExecutionPolicy
  outright; prerequisite for WDAC/CLM trust. STATUS: application SUBMITTED; the signing dispatch
  queues on approval and wires into the release workflow (Section 4, item 2). (Alt: Azure Trusted
  Signing ~$9.99/mo. Do NOT buy EV -- it lost SmartScreen instant-bypass in 2024.)
- **L2 -- Pin + hash-verify the downloaded deps.** Fail-closed verification against pinned known-good
  hashes so a tampered bundle is refused, not run. STATUS: planned (Section 4, item 11).
- **L3 -- Honest degradation on a security-control block.** DELIVERED (000038, v1.9.0). Names
  ExecutionPolicy / CLM / WDAC / Defender ASR / SAC on positive evidence; never circumvents; honest
  pointer when uncertain.
- **L4 -- Enterprise-readiness doc (TRUST.md).** What gets the tool APPROVED. STATUS: planned
  (Section 4, item 12); now also carries the Gap E governance posture and the Gap B SBOM/provenance
  pointers.
- **L5 -- Signed, provenance-tracked releases.** Signing + SBOM + SLSA provenance wired into the
  release pipeline so every release is trustworthy by construction. STATUS: the release-automation
  scaffold (Section 4, item 2/4) is built first, then signing (item 10) drops into it.
- **L6 -- The reputation play (longer arc).** SAC/SmartScreen reputation accrues per file hash over
  downloads + time; signing starts the clock, adoption advances it. Longer-term: winget (signed,
  reputable channel) and, if ever in scope, the Microsoft Store (Store apps bypass SAC entirely).

**Honest limits (designed around, not hidden):** signing is NECESSARY but NOT SUFFICIENT for SAC --
even signed files are blocked until reputation accrues, so the posture is sign + build-reputation +
degrade-honestly + document, not "sign and done." Constrained Language Mode is the hardest enterprise
case. And this is a strong engineering plan, not a security AUDIT -- a serious public posture benefits
from a real third-party security review (itself a 5-star signal), and the cert/identity choices have
organizational implications.

---

## 6. "Findable" (split by readiness)

- **Write now:** the upstream good-citizen posts (PSES PR #2299, the LSP-registration refutation).
  Build reputation while the tool gets excellent. `gh`-only, no CC.
- **Amplify later (gated on the quality wave + enterprise-trust):** the "here is my tool" write-up +
  community push + polished, signed, enterprise-documented listing. One first impression -- spend it
  after it is earned (excellent AND trustworthy on managed Windows). A measured-latency claim
  (Section 4, item 3) and a real correctness corpus (item 5) are exactly the evidence that makes the
  write-up credible rather than promotional.

---

## 7. Horizon features (the future surface)

### Gated on the LSP-registration fix (upstream #66987 / #15168 / #15148 / #379)
- **Native LSP triad: hover, go-to-definition, find-references.** Built + verified, currently
  unreachable. The flip is a milestone -- when registration lands, these activate, the full
  language-server surface appears, and the `-lsp` name becomes literally true. A switch-flip, not a
  build.
- **Further LSP surface:** rename, document outline/symbols, signature help, formatting, applied
  code-actions. Build-as-warranted once the triad lands.
- **Manifest reconciliation tripwire:** flips native LSP on when the bug clears. Parked, watching
  upstream.

### Near-horizon, elevated by the reviewer lens
- **Project-aware analysis (Gap D).** Honor `PSScriptAnalyzerSettings.psd1` repo-wide; module /
  multi-file context; workspace-level findings. Elevated from candidate to named track -- it is what
  makes "LSP" honest before the upstream triad even lands.

### Candidates (dogfood-VALIDATED, not pre-committed)
- **Rule profiles / presets** -- strict vs lenient vs project-specific; pick a posture, not 60 toggles.
- **Custom rule support** -- users add their own PSSA rules.
- **Fix auto-apply** -- from suggesting fixes to applying them (agentic-edit-native: Claude applies
  the fix it is told about).
- **Performance deepening** -- incremental analysis; further cold-start reduction (seeded by the
  benchmark harness, Section 4 item 3).

Hold these as candidates real usage ranks or kills -- do NOT scope them before the dogfood log says
which matter.

---

## 8. Parked / conditional / cleanup

- **Tags:** caught up through v1.11.0. The CI-gated release workflow (Section 4, item 2) retires the
  manual-tag fragility going forward.
- **Option B -- cross-repo plugin-code `dispatch ship --pr`.** 000130 fixed the HUB's own ship; making
  `dispatch ship --pr` target the external plugin repo was deferred, so every plugin-code PR is still
  hand-rolled (worktree off origin/main -> commit -> push -> `gh pr create`). A recurring tax now
  named -- worth a dispatch eventually; the manual recipe works.
- **Auto-prune cross-project aliasing (hub substrate).** A verified flip on `powershell-lsp/000036`
  once reaped a same-numbered worktree in another project (prune keyed on bare dispatch-id without
  project scope; no data loss, worktree only). A real substrate correctness bug -- candidate for a
  strategic-dispatch dispatch (possibly folded into 000143). Check the in-flight
  `release-autoprune` work before authoring.
- **SAC vs hub hooks (infra):** Smart App Control On blocks the hub pre-commit hooks; `--no-verify`
  works now; the 2026 SAC toggle makes it reversible if present. Decide deliberately when not
  mid-flight.
- **DCO/CLA:** only if/when outside contributions start, to preserve relicensing flexibility (also a
  Gap E lever). Nothing now (solo).
- **Commoditization watch:** if Anthropic/Microsoft ship a first-party PowerShell LSP. Low-threat for
  an open tool.

---

## The shape

```
DONE:  launch-readiness + licensing (GPLv3) + hub ship-tax + reliability + install-friction
        + security-block honesty (L3) + dogfood capture engine        [v1.7.0 -> v1.11.0, all verified]
NOW:   the dogfood log accumulates  ||  the SignPath application is in        [both engines RUNNING]
GAPS-NOW (buildable, Section 3):
        test-reliability hardening -> CI-gated tagging + release automation
        -> perf-benchmark guard -> SBOM + provenance -> correctness-corpus harness
PACED: dogfood annotation tool -> rule curation -> false-positives -> fix-quality   [follows the log]
TRUST: L3 done -> [SignPath approval] -> sign scripts -> hash-verify -> TRUST.md (+ SBOM, governance)
        -> reputation/winget                                  [ADOPTION-CRITICAL: managed-Windows core]
LATER: amplify/promote (once excellent AND trusted, with measured latency + a correctness corpus)
HORIZON: => platform fixes registration => LSP triad flips on (MILESTONE) => further LSP surface
         => project-aware analysis (elevated) => rule profiles / custom rules / fix-apply   [validated]
```

**One-liner:** world-class honest-failure ARCHITECTURE is already here; the road to a 5-star
ENTERPRISE verdict is three deliveries -- prove the diagnostics are CORRECT (dogfood + a correctness
corpus), deliver the TRUST surface (sign + SBOM + TRUST.md + hash-verify), and harden the RELEASE
pipeline (kill the flakes, gate the tags, benchmark the latency). The engineering pedigree says it
gets there; this roadmap is the sequence.

**The two engines to keep fed RIGHT NOW:** the **dogfood log** (running -- the quality wave is only as
good as the data it accumulates) and the **SignPath application** (in -- the trust track's long pole).
Everything else sequences behind one of those two clocks or is buildable today in the gap-closing
lane.
