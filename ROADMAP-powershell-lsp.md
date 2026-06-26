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

**Targeted reconciliation -- 2026-06-26 (dispatch 000065).** Three roadmap claims went stale this
session and are corrected to ground truth (verified against `git log` + `CHANGELOG.md`) wherever they
appear below: (1) release automation and the performance-benchmark guard already SHIPPED inside
bundles -- 000042 / v1.13.0 (gated release pipeline + SBOM + provenance + RELEASING) and 000040 /
v1.12.0 (benchmark harness) -- so they are NOT open work, and their re-issues 000053 / 000054 were
abandoned as redundant; (2) the signing track is re-stated from "SignPath approval pending" to the
real state (SignPath Foundation DECLINED the application, adoption-gated; Sigstore via GitHub Artifact
Attestations chosen and already wired; paid Authenticode evaluated and declined); (3) 000063 merged,
so the release pipeline now COMPLETES (Gate 4 waits for push-CI) -- the structural unblock for the
first real release and therefore the first attestation. The rest of this doc still reflects its
2026-06-22 baseline and may lag `main` (now past v1.11.0); a fuller refresh is separate work.

---

## Operating posture: how "rapid" actually works here

We move fast. But different work moves at different speeds, and pretending they are one speed is how
a fast project rebuilds the "lots of code, zero validation" problem. The fast lane is now done, which
sharpens the posture rather than retiring it:

1. **Go-fast NOW (engineering, not data-gated).** The original fast lane (reliability, install,
   security-block honesty) is SHIPPED. Release-engineering hardening, the performance-benchmark guard,
   and the SBOM have ALSO since shipped (000042 / v1.13.0; 000040 / v1.12.0 -- see the reconciliation
   note above). What remains buildable-today are the other DELIVERY-QUALITY gaps a reviewer flags
   (Section 3): test-reliability hardening and a diagnostic-correctness harness. These are engineering,
   not data-gated -- they go now.

2. **Paced by the dogfood log (cannot compress -- and that is a feature).** Diagnostic QUALITY comes
   from REAL usage surfacing REAL false-positives. The capture engine is now LIVE (000039, v1.10.0);
   the log accumulates on Mike's day-to-day PowerShell work from here. The quality dispatches (rule
   curation, false-positive reduction, fix-suggestion quality) FOLLOW the log; front-running them is
   building on faith. The next dogfood step is the annotation/review tool, worth authoring once the
   log holds real entries.

3. **Approval-gated / time-gated (the enterprise-trust track's slower pieces).** SignPath Foundation
   DECLINED the application (2026-06-21, adoption-gated -- insufficient external visibility signals,
   explicitly NOT a quality judgment; re-apply welcome once there is public traction), so Authenticode
   script signing is gated on PUBLIC ADOPTION, not a pending approval. The chosen build-trust path --
   Sigstore via GitHub Artifact Attestations -- is keyless and ALREADY WIRED in the release pipeline
   (Section 5, L1/L5); it goes live on the first real release with no approval clock. SAC/SmartScreen
   reputation still accrues per-hash over downloads + time -- earned, not bought.

4. **Platform-gated (not ours to accelerate at any speed).** No dispatch velocity moves Anthropic's
   backlog. The native LSP triad (hover / go-to-def / find-references) is built and verified,
   unreachable until registration is fixed. A flip-on milestone, not a build.

**"CC decides" -- calibrated.** Within an accepted dispatch's scope, CC deciding implementation,
design, and ripeness-per-track is the proven model -- lean into it. What stays a HUMAN gate, because
that is where recent value came from: **accept (what gets built), merge, F2 verified flip, tag, and
the product / positioning / sequencing calls.** Going fast means a fast gated path, not a removed
gate. (Note: the tag-before-CI-green reliability bug that pattern named is now FIXED -- the gated
release pipeline plus 000063's Gate-4 wait make tag-before-green structurally impossible; see Gap C
and Section 4.)

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
  reviewer flags (Section 3, buildable now), and (b) the dogfood log accumulating toward the quality
  wave.
- The dogfood log is the one long-pole engine still RUNNING on a clock: it captures from today, and the
  quality wave it gates is downstream. The signing track's clock changed shape this session -- SignPath
  declined (adoption-gated), and Sigstore attestations are already wired to go live on the first real
  release (Section 5) -- so it is no longer an approval-pending engine but an adoption-gated one.
- So the near-term sequence (Section 4) is front-loaded with the buildable-now gap-closers, with the
  dogfood-gated work sequenced behind its engine.

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

**Gap B -- Enterprise TRUST is designed, now partly DELIVERED.** The core audience is developers on
locked-down Windows estates -- exactly the shops with the strictest approval processes. Today the
tool is unsigned in the Authenticode sense, has no enterprise approval document
(TRUST.md), no fail-closed hash-verification on the executables it DOWNLOADS, and an unverified
security-disclosure posture. L3 (honest degradation) ships, which is real and valuable -- but for a
tool that downloads binaries and runs code, the trust SURFACE is the literal approve/ban line in a
managed shop, and it is currently a plan rather than a product. An SBOM and SLSA-style build
provenance -- which a 2026 enterprise due-diligence review treats as table stakes for any tool that
pulls executables -- are now DELIVERED: a CycloneDX SBOM plus an `actions/attest-build-provenance`
attestation over the release archive + SBOM, shipped in the gated release pipeline (000042 / v1.13.0).
-> ACTION: the **SBOM** and **release provenance / build attestation** (SLSA-style) are now SHIPPED
   (000042 / v1.13.0); the remaining trust-track delivery is gated on adoption now, not on SignPath
   (declined -- see Section 5, L1). Plus verify SECURITY.md is a real disclosure policy (contact,
   scope, response expectation), not a stub.

**Gap C -- Release engineering has avoidable reliability smells.** Three concrete tells a reviewer
auditing the repo would catch: (1) a flaky test just shipped a RED main CI run on a release (the
v1.11.0 `N_PssaDir` Linux flake); (2) tags had been applied BEFORE the push-event CI confirms green,
repeatedly -- now CLOSED: the gated release pipeline (000042) cuts the tag from the runner only after
Gate 4 confirms a green push-CI run, and 000063 made Gate 4 WAIT for that run to conclude, so
tag-before-green is structurally impossible; (3) the performance benchmark + regression guard is now
SHIPPED (000040 / v1.12.0), and the version bump stays a manual step but is now guarded by the
pipeline's version-lockstep gate (000042). World-class tools have boring, bulletproof release pipelines
where none of this is possible. None of these threaten a FEATURE -- but collectively they read as
process immaturity, and a reviewer cloning the repo to a red main badge docks stars on sight.
-> ACTION: a **test-reliability hardening** pass (fix the `N_PssaDir` Linux flake, sweep for other
   non-determinism, make the suite deterministic across all four legs); **CI-gated tagging / release
   automation** -- SHIPPED as the gated release pipeline (000042 / v1.13.0): a `workflow_dispatch`
   release that tags only on green push-CI, generates notes from the CHANGELOG, and attaches the
   SBOM + provenance from Gap B, so tag-before-green is structurally impossible; and a **performance
   benchmark harness** -- SHIPPED (000040 / v1.12.0): measures cold-start and warm-path
   edit-to-diagnostic latency, guards regression in CI on all four legs, and publishes the numbers in
   the README.

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
unproven and whose enterprise TRUST surface is now partly delivered. The release pipeline is hardened
(gated, now completing) and the SBOM + build provenance ship with it, with signing reframed to keyless
Sigstore attestations (live on the first real release). Prove the diagnostics are correct and finish
the rest of the trust surface (the adoption-gated reputation arc), and this is a 5-star enterprise
tool. The path is clear and the engineering pedigree says it will get there."

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

2. **CI-gated tagging + release automation** (Gap C.2) -- SHIPPED: 000042 / v1.13.0. The
   `workflow_dispatch`-only gated release pipeline (`.github/workflows/powershell-lsp-release.yml`)
   cuts the tag from the runner ONLY after four gates pass -- merged-to-main, tag-free,
   version-lockstep, and all four push-CI legs green by name -- with CHANGELOG-driven release notes,
   making tag-before-green structurally impossible and retiring the manual-lockstep fragility. 000063
   later made Gate 4 WAIT for the push-CI run to conclude before judging, so the pipeline now completes
   instead of snapshot-refusing. (000053 was the redundant re-issue of this item -- abandoned.)

3. **Performance benchmark harness** (Gap C.3) -- SHIPPED: 000040 / v1.12.0.
   `tests/PowerShellLsp.Benchmark.Tests.ps1` + `tests/bench/` measure cold-start and warm-path
   edit-to-diagnostic latency over the real daemon/pipe path, emit `benchmark-results.json`, guard each
   median against a CI regression threshold on all four legs, and the numbers are published in the
   README. (000054 was the redundant re-issue of this item -- abandoned.)

4. **SBOM + release provenance** (Gap B) -- SHIPPED: 000042 / v1.13.0 (same bundle as item 2). A
   single-sourced CycloneDX SBOM over the plugin + its two pinned downloaded deps, plus an
   `actions/attest-build-provenance@v2` (SLSA-style) attestation over the release archive + SBOM,
   attached to the release behind all four gates. Closes the supply-chain due-diligence gap for a tool
   that downloads executables.

> **Bundle-expansion lesson (000065 reconciliation).** Items 2, 3, and 4 were tracked here as separate
> "buildable now" work, but they had already SHIPPED as COMPONENTS of two bundles: 000040 (v1.12.0)
> delivered the benchmark harness alongside the correctness corpus, and 000042 (v1.13.0) delivered the
> release pipeline alongside the SBOM + provenance. The launch board mis-tracked the bundle components
> as future work, which produced the stale "open" status the re-issues 000053 / 000054 then chased
> before being abandoned as redundant. Re-planning must EXPAND a bundle into its components before
> assuming a gap.

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

**Trust track (adoption-gated; the chosen attestation path is already wired):**

10. **Script signing** (L1) -- REFRAMED. SignPath Foundation declined the application (adoption-gated,
    2026-06-21; see Section 5, L1), so Authenticode script signing is parked until public traction.
    The build-trust path actually wired is Sigstore via GitHub Artifact Attestations
    (`actions/attest-build-provenance@v2`), keyless and already in the release pipeline (item 4) -- it
    goes live, with NO approval clock, on the first real release. (Paid Authenticode was evaluated and
    declined -- see Section 5, L1.)
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

- **L1 -- Build-trust signing: Sigstore attestations now, Authenticode parked (REFRAMED 2026-06-26).**
  The chosen path is **Sigstore via GitHub Artifact Attestations** (`actions/attest-build-provenance@v2`),
  ALREADY WIRED in the release pipeline (000042): the release job carries `id-token: write` +
  `attestations: write`, and the attest step signs the release archive + SBOM behind all four gates. It
  is **keyless / workflow-identity** signing -- no account, no key custody, no email, nothing personal
  published -- and it goes live on the first real release (now unblocked by 000063). Honest boundary:
  this is **build-provenance + integrity** (verifiable with `gh attestation verify`), NOT Windows
  Authenticode -- it does not assert a verified-publisher identity, which is CORRECT here because the
  plugin is distributed by **git clone**, so SmartScreen / SAC never fires on a downloaded installer.
  - **SignPath Foundation (Authenticode for OSS) -- DECLINED, adoption-gated.** The free-for-OSS
    application was DECLINED on 2026-06-21 for insufficient external visibility signals (GitHub
    stars/forks, independent references, sustained engagement) -- explicitly NOT a quality judgment,
    with an open invitation to re-apply once the project has public traction. So Authenticode script
    signing (which would clear ExecutionPolicy outright and underpin WDAC/CLM trust) is gated on PUBLIC
    ADOPTION -- a months-long, different-kind-of-work clock -- not on a pending approval.
  - **Paid Authenticode -- EVALUATED and DECLINED as wrong for this distribution model.** SSL.com EV
    Sole Proprietor (~$359/yr cert) + eSigner cloud (Tier 1 ~$900/yr) ~= $1,259/yr buys a Windows
    verified-publisher badge the git-clone model never surfaces to users. Azure Trusted Signing
    (~$120/yr, the closest paid like-for-like to SignPath) is INELIGIBLE -- it requires a US/Canada
    organization with 3+ years of verifiable history. Recorded so the option is not re-litigated from
    scratch next session.
  - **Follow-on (named, NOT built here).** A short "Verifying a release" doc (README / SECURITY.md)
    showing the `gh attestation verify` command -- best authored AFTER the first real release so it can
    show real verify output -- plus optional **gitsign on tags** (Sigstore-signed git tags) as a
    recorded nice-to-have.
- **L2 -- Pin + hash-verify the downloaded deps.** Fail-closed verification against pinned known-good
  hashes so a tampered bundle is refused, not run. STATUS: planned (Section 4, item 11).
- **L3 -- Honest degradation on a security-control block.** DELIVERED (000038, v1.9.0). Names
  ExecutionPolicy / CLM / WDAC / Defender ASR / SAC on positive evidence; never circumvents; honest
  pointer when uncertain.
- **L4 -- Enterprise-readiness doc (TRUST.md).** What gets the tool APPROVED. STATUS: planned
  (Section 4, item 12); now also carries the Gap E governance posture and the Gap B SBOM/provenance
  pointers.
- **L5 -- Signed, provenance-tracked releases.** SBOM + SLSA-style build provenance + a keyless
  Sigstore attestation are wired into the gated release pipeline so every release is trustworthy by
  construction. STATUS: BUILT (000042 / v1.13.0); 000063's Gate-4 wait made the pipeline complete, so
  it goes live on the first real release. Authenticode script signing would layer on later if SignPath
  re-opens on adoption (L1).
- **L6 -- The reputation play (longer arc).** SAC/SmartScreen reputation accrues per file hash over
  downloads + time; signing starts the clock, adoption advances it. Longer-term: winget (signed,
  reputable channel) and, if ever in scope, the Microsoft Store (Store apps bypass SAC entirely).

**Honest limits (designed around, not hidden):** Authenticode signing (if SignPath ever re-opens on
adoption) is NECESSARY but NOT SUFFICIENT for SAC -- even signed files are blocked until reputation
accrues -- and note SAC/SmartScreen does not even fire on the git-clone install path (L1), so today's
posture is attest (Sigstore) + degrade-honestly + document, with Authenticode + reputation deferred to
adoption, not "sign and done." Constrained Language Mode is the hardest enterprise case. And this is a
strong engineering plan, not a security AUDIT -- a serious public posture benefits from a real
third-party security review (itself a 5-star signal), and the cert/identity choices have
organizational implications.

---

## 6. "Findable" (split by readiness)

- **Write now:** the upstream good-citizen posts (PSES PR #2299, the LSP-registration refutation).
  Build reputation while the tool gets excellent. `gh`-only, no CC.
- **Amplify later (gated on the quality wave + enterprise-trust):** the "here is my tool" write-up +
  community push + polished, attestation-backed, enterprise-documented listing. One first impression --
  spend it after it is earned (excellent AND trustworthy on managed Windows). The measured-latency
  claim (now shipped -- Section 4, item 3) and a real correctness corpus (item 5) are exactly the
  evidence that makes the write-up credible rather than promotional. (Note: the public traction this
  amplification builds is also what could re-open the SignPath Authenticode path -- Section 5, L1.)

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

- **Tags:** the gated release workflow (Section 4, item 2 -- 000042, with 000063's Gate-4 wait) is
  BUILT and now completes, retiring the manual-tag fragility; the first real release will be the first
  cut through the pipeline (and the first Sigstore attestation).
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
        + release pipeline + SBOM + provenance (000042/v1.13.0) + benchmark guard (000040/v1.12.0)
        + Gate-4 wait so the pipeline completes (000063)              [release-engineering SHIPPED]
NOW:   the dogfood log accumulates                                    [the one engine still RUNNING]
GAPS-NOW (buildable, Section 3):  test-reliability hardening -> correctness-corpus harness
        [release automation + perf-benchmark + SBOM/provenance SHIPPED -- see Section 4 notes]
PACED: dogfood annotation tool -> rule curation -> false-positives -> fix-quality   [follows the log]
TRUST: L3 done + SBOM/provenance/Sigstore-attestation WIRED (live on first release, 000042+000063)
        -> hash-verify -> TRUST.md ;  Authenticode parked (SignPath declined, adoption-gated)
        -> reputation/winget                                  [ADOPTION-CRITICAL: managed-Windows core]
LATER: amplify/promote (once excellent AND trusted, with measured latency + a correctness corpus)
HORIZON: => platform fixes registration => LSP triad flips on (MILESTONE) => further LSP surface
         => project-aware analysis (elevated) => rule profiles / custom rules / fix-apply   [validated]
```

**One-liner:** world-class honest-failure ARCHITECTURE is already here; the RELEASE pipeline is now
hardened (gated tags + the benchmark guard shipped, and 000063 made it complete) with the SBOM + build
provenance + a keyless Sigstore attestation riding it. The road to a 5-star ENTERPRISE verdict is now
two deliveries -- prove the diagnostics are CORRECT (dogfood + a correctness corpus) and finish the
rest of the TRUST surface (hash-verify, TRUST.md, and the adoption-gated reputation/Authenticode arc).
The engineering pedigree says it gets there; this roadmap is the sequence.

**The engine to keep fed RIGHT NOW:** the **dogfood log** (running -- the quality wave is only as good
as the data it accumulates). The trust track's old second engine, the SignPath application, is RETIRED
as an approval clock (declined -- Section 5, L1): build-trust is already wired via Sigstore
attestations (live on the first real release), and Authenticode now waits on PUBLIC ADOPTION, the same
clock that gates amplification. Everything else sequences behind the dogfood clock or is buildable
today in the gap-closing lane.
