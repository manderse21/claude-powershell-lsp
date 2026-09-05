# Enterprise program docket -- FINDINGS ONLY

> ## NO BUILD IS EXECUTED FROM THIS DOCKET
>
> Nothing in the build queue below was implemented. No script changed, no knob was added, no check
> was written, and no status text moved *for this document*. Every slice in section 4 is a
> **proposal with a price on it**, and the choice among them -- including the choice to build none
> of them -- is Mike Andersen's.
>
> Assembled by dispatch **000277** (2026-09-05), night 1 of the enterprise program, against the
> plugin at `v1.33.0` plus this dispatch's own leg C. Its charter was to audit a supplied external
> review claim by claim and cost what survived. **That review was not on disk** -- see section 1 --
> so this is the reduced docket its pre-authorization provides for, plus the five specific claims
> the charter itself named, which are derivable without it.

---

## 1. Premise correction, recorded before anything else -- the review is MISSING INPUT

**Leg A is BLOCKED-MISSING-INPUT.** The dispatch's first anchor is:

```
C:\Users\mande\Downloads\enterprise-review-2026-09-05.md
```

That path **does not exist**. It was checked directly at 2026-09-05 during leg 0 of the run, and
its directory was then enumerated for a near-miss. What is in `Downloads` from that day is
`enterprise-program-night-1.md` (21,740 bytes, mtime 2026-09-05 12:19) -- which is **this
dispatch's own inbox draft**, opening `id: "PENDING"` / `kind: inbox`, not the external review. No
other file in that directory is a review of this repository.

**Consequently the following parts of leg A were not performed and are not claimed:**

- the claim-by-claim scorecard over the review's numbered items 1-17, its "five things", and each
  row of its phase table -- **there is no item set to score**;
- the case *for* re-ruling the three standing rulings, which the charter specifies is to be built
  from *the review's argument* -- section 5 records the ledger's original reasoning alone and marks
  the opposing case unavailable;
- any phase (P0-P3) assignment that derives from the review's own phasing.

**What was performed instead**, because it is derivable from disk without the review:

- the five claims the **charter itself** names as "known candidates to test rather than assume"
  are scored against disk with file and line (section 3);
- `DOCTOR-SURFACE-DOCKET.md` is folded in as the provable-health slice (section 4.1), as the
  pre-authorization directs;
- the human-only items are enumerated and marked OUT OF RUNNER SCOPE (section 6);
- the rulings block Mike can answer inline is present (section 7).

**This docket is therefore a partial instrument and says so.** When the review file is supplied, a
successor dispatch scores it against this same disk baseline. Nothing here should be read as
"the review was audited and little survived": the review was never read.

---

## 2. The scoring vocabulary

Each claim is scored in one of five ways, with evidence:

| Score | Meaning |
| --- | --- |
| **TRUE** | Holds on disk today, at the cited file and line |
| **STALE** | Held at some commit, changed since -- the commit is cited |
| **REFUTED** | Never held -- the contradicting evidence is cited |
| **ALREADY-SHIPPED** | The claim may hold, but the remedy it implies already exists -- cited |
| **UNVERIFIABLE** | Cannot be settled from disk or live `gh`; the probe that *would* settle it is named |

A claim can be TRUE as a *fact* and still carry no work, because the disposition it implies was
already taken deliberately. Those are marked TRUE with the adjudication cited, and they are the
most common shape below.

---

## 3. The five named claims, scored against disk

### C1 -- "diagnostic capture is independent of `enableStats`"

**TRUE.** The two writers are gated differently, in the same file, a dozen lines apart.

- `scripts/lsp-client.ps1:40` reads the knob once: `$StatsOn = Get-PluginOptionBool 'enableStats' $false`.
- `Write-StatsLine` -- the telemetry writer -- is called **inside** `if ($StatsOn)` at
  `scripts/lsp-client.ps1:429-430` and `:843-844`.
- `Add-DiagnosticCaptureEntries` -- the dogfood capture writer -- is called at
  `scripts/lsp-client.ps1:419`, `:425` and `:835`, all **outside** any `$StatsOn` guard.
- There is **no separate knob** for capture: `.claude-plugin/plugin.json` contains no
  `enableCapture`, no `dogfood` key, and no other capture gate.

**Why this is not merely a tidiness point.** The capture writer's own header in
`scripts/lib/lsp-common.ps1` states that "the log holds REAL source snippets" and describes a
"NEVER-COMMIT FENCE" built to keep it outside every git tree. So the surface that records the
user's actual source lines is on by default, while the surface that records *timings* is opt-in.
That may well be the intended design -- capture is what the rule-curation arc runs on -- but the
asymmetry is not stated in `CONTRACT.md` or in `docs/configuration.md` as a decision, and an
enterprise reviewer will read it as an undeclared data-collection default.

**This is a ruling, not a bug** -- see R-A in section 7.

### C2 -- "`orgPolicy` fails open on a missing or unreadable policy"

**TRUE, deliberately, and logged every time.** `Import-OrgPolicyExcludes`
(`scripts/lib/lsp-common.ps1:921`) applies **no** org exclusions and returns a `reason` string on
each of four degrade paths:

| Condition | Line | Reason recorded |
| --- | --- | --- |
| path is not absolute | `:965` | `orgPolicy path is not absolute; no org exclusions applied` |
| file not found | `:969` | `orgPolicy file not found; no org exclusions applied` |
| integrity gate fails | `:975` -> `Test-OrgPolicyIntegrity` (`:875`) | `orgPolicy integrity check FAILED; no org exclusions applied` |
| read raises | `:995` | `orgPolicy could not be read; no org exclusions applied` |

**Which direction "open" points matters here and cuts both ways.** The layer's payload is
`ExcludeRules` -- it *removes* diagnostics. Failing open therefore surfaces **more** findings, not
fewer, which is fail-*safe* from a "did I miss a defect" standpoint and fail-*open* from a "did my
org's policy actually apply" standpoint. An enterprise deploying `orgPolicy` to *suppress* noise
gets more noise; one deploying it as a control gets silence where it expected enforcement. The
degrade is surfaced (doctor check 10, "Org policy exclusions") and never silent, which is the part
that is already right.

**This is a ruling, not a bug** -- see R-B in section 7.

### C3 -- "the acquisition fallback bypasses the hash chain"

**TRUE, and the code already says so in its own words.** `scripts/ensure-pssa.ps1` pins
`$PssaSha256` (`:26`) and runs every layered source through one `Test-PinnedFileHash` gate
(`:194`), failing closed on mismatch (`:202-207`). The `Save-Module` fallback block at `:259-291` (the `Save-Module` call itself at `:274`) is the
exception, and its comment states it exactly:

> `000244: label this path DISTINCTLY, and never as one of the pinned layers. This is the one
> acquisition route in either ensure-script whose bytes the SHA-256 pin does NOT gate -- it rests
> on the Gallery's own publisher/catalog integrity instead (see TRUST.md). ... PRE-EXISTING and
> deliberately NOT changed here: closing that gap is its own dispatch.`

The route is labelled `gallery-fallback` (`:283`), written into the marker (`:303`), and reported
by the doctor's artifact-source check rather than being folded in with the pinned layers.

**So the claim holds and the remedy does not exist.** Unlike C1 and C2, this one has a chartered
shape already written down by the dispatch that created it -- *"closing that gap is its own
dispatch"* -- and that dispatch was never minted. It is the cleanest buildable slice in this
docket; see **P1-1** in section 4.2.

### C4 -- "no minimum or maximum Claude Code version is declared"

**TRUE as a fact, ALREADY-SHIPPED as a decision.** `docs/SUPPORT-POLICY.md:62` states the claim
verbatim and adjudicates it in the next clause:

> "**No minimum or maximum Claude Code version is declared, anywhere in this repository.** That is
> the honest state and not an omission to be papered over: the plugin is installed by a Claude Code
> client whose version the project does not pin, test a matrix of, or gate on."

The same section then records what the project *does* track -- specific known-bad versions
(2.1.196-2.1.200 on Windows), the upstream issue, and an explicit no-claim-in-either-direction for
macOS and Linux on those versions. A reviewer reading only `plugin.json` would not find this;
a reviewer reading `docs/SUPPORT-POLICY.md` would.

**No work is implied.** Declaring a floor the project does not test against would be a claim it
cannot support, which is the failure mode `SUPPORT-POLICY.md` was written to avoid.

### C5 -- "`doctor` exits 0 with UNKNOWN checks"

**TRUE, already assembled as a findings docket, and unruled.** `scripts/doctor.ps1` counts only
`fail` into `$doctorFailures` and exits 0 otherwise -- its own header says "Exit 0 when no check
FAILED (passes and honest unknowns are not failures)". Checks 2, 8 and 11 are the probative ones
and all three degrade to UNKNOWN outside a Claude Code session.

This is section 2 of [`DOCTOR-SURFACE-DOCKET.md`](DOCTOR-SURFACE-DOCKET.md) (dispatch 000276)
verbatim, including its consequence: *"a container in which nothing works at all, and a healthy
install, are indistinguishable by exit code."* That docket carries three costed slices and one
recommendation, and is **unruled**. It is folded in below rather than restated.

---

## 4. The build queue, phase-ordered

Each slice is sized to **at most six legs** so it can be minted as one pre-adjudicable dispatch.
Effort is session-hours for a single implementer working to this project's normal gate (tests plus
a RED control per check). **Freeze exposure** is stated for each against `CONTRACT.md` Tier 1,
which freezes exactly two enumerable surfaces: the **userConfig knob names** and the **diagnostics
status token set**.

### 4.0 P0 -- done, in this dispatch, for reference

| Slice | State |
| --- | --- |
| **POSIX containment of every object the plugin creates** (T5.1/T6.2 POSIX arms) | **BUILT in this dispatch, leg C.** `0700` directories and `0600` for the socket endpoint and the shared JSONL writers' files, at creation, in one helper. No knob, no token, no `CONTRACT.md` line. Listed here so the queue's P0 row is not empty and later nights do not re-charter it |

### 4.1 P1 -- the provable-health slice (folded in from DOCTOR-SURFACE-DOCKET)

`DOCTOR-SURFACE-DOCKET.md` is **not rebuilt and not re-ruled here.** It is folded in as-is; its
own section 5 recommends **S1**, and this docket does not second-guess that.

| Slice | Mechanism | Effort | Freeze exposure | Phase |
| --- | --- | --- | --- | --- |
| **S1 `doctor.ps1 -Json`** | a third rendering beside `Format-DoctorReport` / `Format-DoctorSummary` over the same `Invoke-Doctor` seam | ~2-4 h | **ZERO** -- a CLI switch, not a userConfig key; emits no diagnostics status token | **P1** |
| **S2 `-RequireProven`** | opt-in switch exiting non-zero on any UNKNOWN; a second predicate beside `$doctorFailures` | ~1 h | **ZERO** -- same reasoning; the opt-in, not the contract, is what protects existing callers | **P1**, follows S1 |
| **S3 ephemeral daemon for check 11** | doctor stands up a short-lived daemon when no session daemon is discoverable | ~1-2 d | ZERO on enumerated surfaces, but **changes a documented behavioural promise** ("report-only ... never starts, restarts or stops anything") stated in three shipped places | **P3** -- deserves its own charter and its own ruling |

### 4.2 P1 -- the one slice this docket adds

**P1-1 -- close the `gallery-fallback` hash-chain gap (C3).**

- **Exact gap it closes.** One acquisition route vendors PSScriptAnalyzer bytes that the pinned
  SHA-256 does not gate. Every other route in either ensure-script passes one
  `Test-PinnedFileHash` and fails closed.
- **Mechanism (the smallest buildable shape).** After a successful `Save-Module`, locate the
  vendored payload and run it through the **same** `Test-PinnedFileHash` gate the pinned layers
  use, failing closed on mismatch exactly as `:202-207` already does. If the Gallery's on-disk
  shape makes a `.nupkg`-equivalent digest unavailable, the honest alternative is to **fail closed
  on the fallback by default** and require an explicit opt-in to accept publisher-integrity-only
  bytes -- which is a knob, and therefore a different freeze answer. **Which of those two is
  wanted is a ruling** (R-C, section 7).
- **Effort.** Small if the digest is recoverable (~3-5 h). Medium if the opt-in shape is chosen
  (~1 day) because it adds a userConfig key.
- **Freeze exposure.** **ZERO** for the verify-in-place shape -- no key, no token. **NON-ZERO** for
  the opt-in shape: it adds one `userConfig` key, which is a Tier 1 enumerated surface and a MINOR.
- **Test shape.** Prove a fallback install whose bytes do not match the pin is refused and the
  marker records no pinned layer. **RED control:** the prior implementation -- the fallback as it
  ships today -- must ACCEPT the same mismatched bytes, or the gate is not what is producing the
  refusal.
- **Legs.** Four: derive the fallback's on-disk payload shape; wire the gate; tests plus the RED
  control; `TRUST.md` and doctor artifact-source text.

### 4.3 P2 -- declared, not costed

These follow from C1 and C2 and are **ruling-first**: their mechanism depends on which way the
ruling goes, so costing them now would cost a guess. They appear here so night 2 has them in view.

| Item | Blocked on |
| --- | --- |
| Declare (or gate) the capture default | **R-A.** If capture stays on by default, the work is documentation in `CONTRACT.md` / `configuration.md`; if it becomes opt-in, it is a userConfig key and a MINOR |
| Decide `orgPolicy` degrade direction | **R-B.** If fail-open stands, the work is documentation; if an enterprise wants fail-closed, it is a knob and a MINOR |

---

## 5. The three standing rulings R2 opened -- one side only

The charter asks for the case for and against re-ruling each, **with the review's argument** beside
the ledger's original reasoning. The review is missing, so **only the ledger's side exists here.**
These are recorded, not re-argued, and nothing below recommends re-opening anything.

| Standing ruling | The ledger's original reasoning (`PROGRAM.md`, ruling 1 / standing arcs) | The case for re-ruling |
| --- | --- | --- |
| **Custom-rule seam (Pillar H) -- DECLINED** | "A custom-rule seam would resurrect the already-declined new-custom-rules item under a new name. Guidance overrides remain the sanctioned seam. Declined *pending demand*, not permanently: **real user demand reopens it, and nothing else does**" | **UNAVAILABLE -- MISSING INPUT.** Note that the ledger's own re-open condition is *real user demand*; a review is not demand, so even a supplied review would have had to carry evidence of a user asking, not an argument that the seam is good |
| **Native-LSP gating** | Standing arc "Native code navigation, end to end" is **GATED**: "Registration works; serve does not on the direct path. The opt-in `nativeServe = shim` closes it locally; removing the shim waits on the upstream fix" | **UNAVAILABLE -- MISSING INPUT.** The gate is on an *upstream* fix, so the re-open condition is an external event, not an argument |
| **PS 5.1 first-class** | `ps_host` ships `pwsh` as default with `powershell` (5.1) documented and CI-covered as its own leg (`windows-powershell`); DX-AUDIT **T3** is an accepted priced tradeoff (ratified G4, 2026-08-21) | **UNAVAILABLE -- MISSING INPUT** |

---

## 6. OUT OF RUNNER SCOPE -- human-only, explicitly

None of these can be done by an overnight runner, and none is proposed as work here. They are
listed so a later night does not silently pick one up:

- **A second maintainer.** `GOVERNANCE-SURFACE.md` records that CODEOWNERS ships **inert** by
  design, because enabling `require_code_owner_reviews` would deadlock the repository until a
  second maintainer exists. Only Mike can add one.
- **Enabling CODEOWNERS enforcement.** Follows from the above; a repository-settings change.
- **Signing-key succession.** A custody decision, not a build.
- **An external security audit.** Procurement.
- **Intune / SCCM / Jamf / VDI validation.** Requires managed estates this project does not have.
- **Marketplace / registry submission.** An external publishing action; the same rail that keeps
  the corpus commons "prepared-not-published".

---

## 7. Rulings block -- answer inline

Each row is a question this docket surfaced and did **not** answer. The recommended default is a
recommendation.

| # | Question | Options | Recommended default | Mike's answer |
| --- | --- | --- | --- | --- |
| **R-A** | Diagnostic capture writes real source snippets and is **on by default**, while `enableStats` (timings only) is opt-in. Is that the intended posture? | (a) keep on by default and **declare it** in `CONTRACT.md` + `configuration.md`; (b) put capture behind a knob defaulting **on**; (c) put capture behind a knob defaulting **off** | **(a)** -- the rule-curation arc runs on this data, the never-commit fence already keeps it outside every git tree, and a knob defaulting on adds a Tier 1 surface for no behaviour change | |
| **R-B** | `orgPolicy` degrades **open** on a missing, non-absolute, unreadable or integrity-failed policy: no exclusions applied, reason logged, doctor check 10 surfaces it. Enforcement or visibility? | (a) keep fail-open, document the direction explicitly; (b) add an opt-in strict mode that refuses to serve diagnostics when a configured `orgPolicy` cannot be applied | **(a)** -- the payload only *removes* diagnostics, so failing open cannot hide a defect, and (b) adds a knob to Tier 1 | |
| **R-C** | For **P1-1**, which shape closes the `gallery-fallback` hash gap? | (a) verify the fallback's bytes against the same pin, fail closed; (b) fail closed on the fallback by default with an explicit opt-in to accept publisher-integrity-only bytes | **(a)** -- zero freeze exposure, and it makes the one unpinned route match the other four | |
| **R-D** | `DOCTOR-SURFACE-DOCKET.md` has been unruled since 000276. Build **S1**? | (a) S1 now, S2 as the follow-on; (b) S1 only; (c) none | **(a)** -- that docket's own section 5 recommendation, unchanged | |
| **R-E** | Should a successor dispatch be minted to audit the enterprise review once the file is supplied? | (a) yes, against this same disk baseline; (b) no | **(a)** -- section 1 is a gap, not a verdict | |

---

## 8. What this docket deliberately did not do

- **No build.** Leg C is a *separate* leg of the same dispatch, chartered independently by ruling
  R4; it is listed in section 4.0 for continuity and was not derived from any review.
- **No review audit.** Section 1 says why. Nothing here is scored from a document that was not read.
- **No re-litigation of `DOCTOR-SURFACE-DOCKET.md`.** It is folded in whole, with its own
  recommendation intact.
- **No ruling.** Section 7 recommends. It does not choose.
- **No phase assignment that pretends to a source it does not have.** P0-P3 above are assigned from
  what is on disk; the review's own phase table was never read.
