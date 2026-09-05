# Enterprise program docket -- FINDINGS ONLY

> ## NO BUILD IS EXECUTED FROM THIS DOCKET
>
> Nothing in the build queue below was implemented. No script changed, no knob was added, no check
> was written, and no status text moved *for this document*. Every slice in section 4 is a
> **proposal with a price on it**, and the choice among them -- including the choice to build none
> of them -- is Mike Andersen's.
>
> Assembled by dispatch **000278** (2026-09-05), night 2 of the enterprise program, replacing the
> skeleton dispatch 000277 landed when the review file was absent. The provable-health content of
> that skeleton is carried forward, not lost (section 4.1). Its five scored claims are carried
> forward too, re-verified against this tree rather than copied.

---

## 1. Provenance -- what was read, and which tree it was read against

**The review exists and was read end to end.** Recorded before anything else was done:

| | |
| --- | --- |
| Path | `C:\Users\mande\Downloads\enterprise-review-2026-09-05.md` |
| Size | **29,569 bytes** |
| SHA-256 | `380CFA18059EEF598BA867268BD0DEAEF438CFD380F836A44F33E8C2ACB372AD` |
| Lines | 1,078 |
| Modified | 2026-09-05 16:28:49 -04:00 |
| First line | `# External enterprise review of claude-powershell-lsp (2026-09-05)` |

The review's own header states it is "an outside model's read of a repository snapshot" which
"could not run `pwsh` or the Pester suite," so its runtime claims rest on checked-in evidence.

### The snapshot it read is `v1.33.0`, and that is derived rather than assumed

The review's item 8 quotes four line counts. Three match this tree exactly and the fourth does not,
which pins the snapshot:

| File | Review says | At `v1.33.0^{}` (`6ab2d24`) | At this branch |
| --- | ---: | ---: | ---: |
| `scripts/lib/lsp-common.ps1` | ~4,595 lines / **131 functions** | **4,595 / 131** | 4,736 / 135 |
| `scripts/doctor.ps1` | ~2,035 | **2,035** | 2,035 |
| `scripts/pses-daemon.ps1` | ~1,731 | **1,731** | 1,731 |
| `scripts/lsp-client.ps1` | ~858 | **858** | 858 |

Counts are lines-including-the-last (`wc -l` plus one), the convention that makes all four agree.
`lsp-common.ps1` is the only one of the four that 000277's leg C touched, and it is the only one
that disagrees -- so **the review was written against `v1.33.0` and does not see the POSIX
containment fix.** Anything that fix changed is therefore STALE by construction, and this document
says so where it applies rather than treating the review as current.

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
most common shape below. **An audit whose output is largely "this was already decided" is doing its
job; the failure mode is the opposite one.**

**Two claims the review presents as new findings are already adjudicated with reasons**, and this
docket argues for or against **RE-OPENING** them rather than presenting them as discoveries. That
is the correction dispatch 000277 made on derivation and left visible; it is inherited here as a
standing rule, not re-learned. See items 1 and 2.

**No web page was fetched.** Six of the review's claims rest on third-party documentation
(`docs.anthropic.com`, the PSES host-process guide). External network reads were outside this run's
rails, so each is scored **UNVERIFIABLE** with the exact probe named. `gh api` reads against public
repositories were in scope and were used where they settle a claim (item 6).

---

## 3. The claim-by-claim scorecard

### Item 1 -- "The diagnostic source capture is an enterprise blocker"

| # | Claim | Score | Evidence |
| --- | --- | --- | --- |
| 1a | Capture writes to `<data-root>/dogfood/diagnostics.jsonl` | **TRUE** | `scripts/lib/lsp-common.ps1:1138-1166`, `Get-DogfoodLogPath` |
| 1b | The entry can include the absolute file path, the diagnostic, and the offending source line | **TRUE** | `scripts/lib/lsp-common.ps1:1373-1385` -- the ordered entry is `ts / file / line / col / ruleId / source / severity / message / snippet / hash / verdict`; `snippet` is read verbatim off the post-edit file at `:1362,1370` |
| 1c | The capture is "effectively independent of `enableStats`" | **TRUE** | `scripts/lsp-client.ps1:40` reads the knob once; `Add-DiagnosticCaptureEntries` is called at `:419`, `:425`, `:835`, all outside any `$StatsOn` guard, while `Write-StatsLine` sits inside `if ($StatsOn)` at `:429` and `:843` |
| 1d | No `telemetryMode` control exists | **TRUE** | The frozen `userConfig` surface is twenty keys (`.claude-plugin/plugin.json`); none is `telemetryMode`, `enableCapture` or any capture gate |

**Disposition: ALREADY ADJUDICATED as `THREAT-MODEL.md` T6.1, ACCEPTED WITH RECORD.** The register
carries this finding in its own words at `THREAT-MODEL.md:451`, `:763` and `:854`, with the reason:
gating the capture "would strangle the dogfood channel the entire rule-curation lane depends on,
and the log is local-only, never transmitted, and now both bounded (T6.4) and outside every git
tree (T2.3) -- so the exposure it carries is to a local user who already has the source files it
quotes."

**The review supplies a genuinely new argument for RE-OPENING, and it goes to the one clause the
acceptance rests on.** T6.1's reason assumes the reader of the log is "a local user who already has
the source files it quotes." The review names readers for whom that is false: **EDR, backups,
forensic collection, eDiscovery, DLP, disk imaging and endpoint management.** A backup agent
replicates the snippet off the host; the source file's own ACL does not travel with it. This is not
a restatement of T6.1's exposure -- it is a claim that T6.1 mis-scoped the reader set.

**The case against re-opening, stated as fairly:** the acceptance was taken with the dogfood channel
priced, the log is bounded and outside every git tree, and the same argument would apply to any
local artifact a build tool writes -- a compiler's `.pdb`, a test log, an editor's swap file. And
000277's leg C narrowed the exposure materially after the review's snapshot: every plugin-created
POSIX object is now `0700`/`0600`, so the *local* half of the reader set is closed and only the
*management-plane* half the review names remains.

**Recommended: R-A(a) -- a metadata-only mode, opt-in-to-source, as a fleet-deployable environment
variable rather than a `userConfig` knob.** See slice **P0-2**; the freeze answer is what makes it
cheap.

### Item 2 -- "`orgPolicy` isn't yet an enterprise policy system"

| # | Claim | Score | Evidence |
| --- | --- | --- | --- |
| 2a | Policy can primarily subtract/suppress | **TRUE** | `Import-OrgPolicyExcludes` reads exactly one key -- `$data.ContainsKey('ExcludeRules')`, `scripts/lib/lsp-common.ps1:982`; the knob's own description says "whose `ExcludeRules` win over local config" |
| 2b | Organization-*required* rules are not authoritative | **TRUE** | There is no include-side org layer at all: no `requiredRules`, no `severityOverrides`, no `prohibitedSuppressions` anywhere in `scripts/` or `.claude-plugin/` |
| 2c | Missing / unreadable policy can fail open | **TRUE** | Four degrade paths, each returning a reason and applying no exclusions: not-absolute `:965`, not-found `:969`, integrity-failed `:975` -> `Test-OrgPolicyIntegrity` `:875`, read-raised `:995` |
| 2d | Hash checking is optional | **TRUE** | `scripts/lib/lsp-common.ps1:973-975`: "With no `<policy>.sha256` beside the file this returns `''` and the read below is byte-for-byte the pre-gate path; **the gate is pure opt-in**" |
| 2e | A `.sha256` beside the policy is not a trust root if both can be modified | **TRUE** | `THREAT-MODEL.md:852` records exactly this as T4.1's residual: bounded to "an attacker who can rewrite **both** the policy and its `.sha256` companion" |
| 2f | No policy identity / version / expiry, no rollout ring, no signer identity, no machine-readable evidence of the governing policy | **TRUE** | No `policyId`, `policyVersion`, `expires` or policy `signature` field exists in any script or manifest |
| 2g | Claude Code has enterprise managed settings that override user/project settings | **UNVERIFIABLE** | Probe: fetch `https://docs.anthropic.com/en/docs/claude-code/iam` and read the managed-settings precedence table. Not fetched -- external reads were outside this run's rails |

**Which direction "open" points matters and cuts both ways.** The layer's payload *removes*
diagnostics, so failing open surfaces **more** findings -- fail-*safe* against "did I miss a
defect", fail-*open* against "did my org's policy apply". An enterprise deploying `orgPolicy` to
suppress noise gets noise; one deploying it as a control gets silence where it expected
enforcement. The degrade is surfaced by doctor check 10 and is never silent, which is the part that
is already right.

**Disposition: ALREADY ADJUDICATED as T4.2 (fail-open) and T4.1 (integrity), both ACCEPTED WITH
RECORD** (`THREAT-MODEL.md:761-762`, `:852-853`). T4.2's reason: "an unreachable policy that
disabled the plugin's diagnostics would turn an availability problem into a silent loss of linting,
which is the worse failure for a tool whose whole contract is never being silent."

**The review's case for RE-OPENING is not the same claim.** T4.2 adjudicated the *degrade direction*
for a layer whose payload is exclusions. The review argues the **payload is the problem**: a
subtract-only layer cannot express an org requirement at all, so "fail-open" is the wrong axis to
have ruled on. That is a new argument and it is a good one -- but note what it costs: an
include-side, signed, versioned policy is a **new artifact schema plus a trust root the org-policy
mechanism does not have today** (T4.1's own words), which is the largest single slice in this
docket. It is P1, not P0.

**The case against re-opening now:** nothing in the record shows an organization has deployed
`orgPolicy` and been surprised by it. The custom-rule seam precedent (item 13) is that this project
reopens a declined seam on **real user demand and nothing else**. Applying that standard evenly,
Policy v2 is chartered when an enterprise asks, and priced now so the answer is ready.

### Item 3 -- "`doctor` is close, but its semantics are dangerous"

| # | Claim | Score | Evidence |
| --- | --- | --- | --- |
| 3a | Exit 0 means "nothing failed", not "everything required was proven" | **TRUE** | `scripts/doctor.ps1:2032-2033` counts only `Status -eq 'fail'`; the header at `:31` states it: "Exit 0 when no check FAILED (passes and honest unknowns are not failures)" |
| 3b | Some checks can be UNKNOWN | **TRUE** | `DOCTOR-SURFACE-DOCKET.md` section 2: checks 2, 8 and 11 degrade to UNKNOWN outside a Claude Code session |
| 3c | `doctor -Json` and `-RequireProven` do not exist | **TRUE** | No such parameter in `scripts/doctor.ps1` |
| 3d | `status --json` / `selftest --json` do not exist | **TRUE** | `commands/` holds `doctor.md`, `scan.md`, `status.md`; there is no `selftest` anywhere in the tree and no JSON rendering on any of them |
| 3e | "Your own doctor docket has correctly identified this" | **ALREADY-SHIPPED** (as findings) | `DOCTOR-SURFACE-DOCKET.md:101` states the consequence verbatim: "a container in which nothing works at all, and a healthy install, are indistinguishable by exit code" |

**This is the review's single strongest item, because it agrees with a docket this project already
wrote and left unruled.** It is folded in at section 4.1 rather than re-derived. The review adds one
thing that docket does not have: a **status vocabulary** (`HEALTHY / DEGRADED / UNHEALTHY /
UNPROVEN`) and a response envelope. That is a real addition and is priced as **P0-1b**.

### Item 4 -- "You need an explicit Claude Code compatibility contract"

| # | Claim | Score | Evidence |
| --- | --- | --- | --- |
| 4a | No minimum or maximum Claude Code version is declared | **TRUE, and ALREADY-ADJUDICATED** | `docs/SUPPORT-POLICY.md:62` states the claim verbatim and adjudicates it in the next clause: "That is the honest state and not an omission to be papered over: the plugin is installed by a Claude Code client whose version the project does not pin, test a matrix of, or gate on" |
| 4b | No `claudeCodeCompatibility` block in the manifest | **TRUE** | No such key in `.claude-plugin/plugin.json` |
| 4c | The project tracks nothing about client versions | **REFUTED** | `docs/SUPPORT-POLICY.md:66-70` records **specific known-bad versions** (Claude Code 2.1.196-2.1.200 on Windows), the upstream issue, and an explicit no-claim in either direction for macOS and Linux on those versions |
| 4d | Claude Code checks for and installs updates by default | **UNVERIFIABLE** | Probe: `https://docs.anthropic.com/en/docs/claude-code/getting-started`, auto-update section. Not fetched |

**The claim holds and the decision behind it is recorded, but 4c matters:** the review reads only
`plugin.json` and concludes nothing is tracked. `SUPPORT-POLICY.md` tracks the thing that has
actually bitten users. **What is genuinely absent is a *tested* floor** -- and declaring a floor the
project does not test against would be a claim it cannot support, which is the failure mode
`SUPPORT-POLICY.md` exists to avoid. So the buildable slice is the **matrix**, not the declaration:
see **P1-3**, where the declaration is the *output* of certification rather than a promise made
ahead of it.

### Item 5 -- "I would tighten your release gate"

| # | Claim | Score | Evidence |
| --- | --- | --- | --- |
| 5a | v1.33.0 shows 5 of 6 SLOs met, T3 missing the defined target | **TRUE** | `PROGRAM.md:50`: "**STANDING AT v1.33.0: 5 of 6 MET, T3 MISSED.**" Measured at C = `6ab2d24` on a compliant quiet host: 1 of 15 sessions returned two NOT-checked edits against a target of at most one; the cold-start clause holds and the count clause is what is missed |
| 5b | An adopted SLO is not a release gate | **TRUE** | `docs/RELEASING.md:211-243` enumerates six pipeline gates -- merged-to-main, tag-is-free, version lockstep, CI green on every leg, tree-vs-published parity, dry-run-happened. **None reads an SLO** |
| 5c | The system risks "measuring things you routinely waive" | **TRUE as a risk, and already contested on the record** | `SLO-BASELINES.md` section 9 pre-empts it: a T3 or T4 miss "is therefore a **behavioural regression** and should be read as one, not as measurement noise". The miss sits in `PROGRAM.md`'s PENDING-MIKE table as an open decision, not a waiver |

**This is the item the T3 survey is load-bearing on, and the survey changes the recommendation.**
`T3-REGRESSION-SURVEY.md` (dispatch 000275, findings only) reaches a conclusion the review could not
have known: **the delta is attributable, the miss is not.** Its counterexample -- a v1.32.0 session
slower on every axis that did *not* miss, and a C session that missed while not being the slowest at
C on any axis -- means "no monotone timing threshold on `segA`, `cold`, or the gap explains the
miss." Its best-supported reading is possibility 3, *an unlucky draw against a categorical target*,
with the honest limit stated: "N=15 on each side cannot distinguish a low-rate recurring defect from
noise."

**A hard release gate placed on T3 today would gate on a statistic the sample cannot support.** That
is the survey's own P3 finding: "Section 9's spread-zero reading is doing heavy lifting on 15
observations." The right order is the survey's, not the review's: **P1 (quiet-host re-runs) first,
then re-read**. See section 4.3, which folds all four survey proposals into the release-governance
slice.

### Item 6 -- "Eliminate the remaining 'trust me' dependency acquisition paths"

| # | Claim | Score | Evidence |
| --- | --- | --- | --- |
| 6a | The acquisition fallback is not protected by the same artifact hash chain | **TRUE, and the code says so in its own words** | `scripts/ensure-pssa.ps1` pins `$PssaSha256` at `:26` and runs every layered source through one `Test-PinnedFileHash` at `:194`, failing closed at `:202-207`. The `Save-Module` fallback (`:274`, labelled `gallery-fallback` at `:283`) is the exception, and its comment says: "This is the one acquisition route in either ensure-script whose bytes the SHA-256 pin does NOT gate ... PRE-EXISTING and deliberately NOT changed here: closing that gap is its own dispatch" |
| 6b | Supply-chain work is otherwise strong (pins, hashes, SBOM, Action SHA pinning, provenance, Sigstore, air-gap) | **TRUE** | `TRUST.md`; `release/New-PluginSbom.ps1`; `release/New-AirgapBundle.ps1`; `tests/PowerShellLsp.ActionPinning.Tests.ps1` |
| 6c | PSScriptAnalyzer 1.25.0 is currently the latest release | **TRUE** | Live: `gh api repos/PowerShell/PSScriptAnalyzer/releases` -> newest is `1.25.0`, published 2026-03-20, not a prerelease. The pin at `scripts/ensure-pssa.ps1:21` is `1.25.0` -- current, not stale |
| 6d | An `enterpriseMode = true` exists to make the fallback impossible | **REFUTED** | No `enterpriseMode` anywhere in the repository. The review proposes it; it does not describe it |

**This is the cleanest buildable slice in the docket and it already has a charter written by the
dispatch that created it** -- *"closing that gap is its own dispatch"* -- and that dispatch was never
minted. See **P0-3**. It is the one item where the review, the code's own comment, and this docket
all agree without a ruling in between.

### Item 7 -- "Enterprise observability is essentially the next major product"

| # | Claim | Score | Evidence |
| --- | --- | --- | --- |
| 7a | No OpenTelemetry export exists | **TRUE** | A case-insensitive search for `opentelemetry` or `otel` over every tracked file returns nothing |
| 7b | Enormous effort has gone into *local* evidence | **TRUE** | `evidence/`, `SLO-BASELINES.md`, the `enableStats` JSONL instrument, the corpus |
| 7c | Claude Code recommends enterprise usage monitoring through OpenTelemetry | **UNVERIFIABLE** | Probe: `https://docs.anthropic.com/en/docs/claude-code/security`, monitoring section. Not fetched |

**The metrics the review proposes are mostly already computed**, which changes the cost materially:
`enableStats` already writes one JSONL timing line per analyzed edit, and the capture log already
carries a `hash` derived from rule id plus offending line -- a `sourceHash` in all but name
(`scripts/lib/lsp-common.ps1:1383`). An exporter is a *rendering* of instruments that exist, not a
new measurement layer. See **P2-1**.

### Item 8 -- "Graduate from lots of PowerShell scripts into an actual broker"

| # | Claim | Score | Evidence |
| --- | --- | --- | --- |
| 8a | `lsp-common.ps1` ~4,595 lines / 131 functions | **STALE** | Exact at `v1.33.0^{}`; **4,736 lines / 135 functions** on this branch after 000277's containment helpers |
| 8b | `doctor.ps1` ~2,035 / `pses-daemon.ps1` ~1,731 / `lsp-client.ps1` ~858 | **TRUE** | Exact, and unchanged since `v1.33.0` |
| 8c | Roughly 70K+ lines across PowerShell/docs/tests | **TRUE** | 72,227 tracked lines across `.ps1` (46,336 in 193 files), `.psm1` (832 / 10), `.psd1` (2,459 / 18) and `.md` (22,600 / 73) |
| 8d | "Your tests are huge, which is good" | **TRUE** | 28,167 of those 72,227 lines are under `tests/` |
| 8e | PSES warns its internal host protocol details have changed over time | **UNVERIFIABLE** | Probe: the PSES `docs/guide/using_the_host_process.md` page. Not fetched |

**The claim is fair and the direction is right, but the sequencing is wrong for this project.** A
module or `.NET` split is the review's P1; nothing above it depends on it, and everything above it
gets harder while it is in flight. Recorded as **P3-1**, declared and not costed, with the reason
stated: a rewrite that lands during an open policy or telemetry slice pays for both.

### Item 9 -- "Stop allowing native Claude LSP limitations to dictate the product"

| # | Claim | Score | Evidence |
| --- | --- | --- | --- |
| 9a | The strongest path is edited file -> hook -> diagnostics | **TRUE** | The PostToolUse hook path is the shipped warm path |
| 9b | Hover / definition / references are constrained and gated | **TRUE, and it is an explicit standing gate** | `nativeServe` defaults to `off` (`.claude-plugin/plugin.json`); its description names the shim "around upstream #1359"; `docs/configuration.md:120`: "`nativeServe` stays `off` everywhere. The shim works around an upstream client bug" |
| 9c | The gating is caused by Claude Code's LSP behaviour, not by this project | **TRUE** | `PROGRAM.md` standing arc "Native code navigation, end to end" is GATED: "Registration works; serve does not on the direct path ... removing the shim waits on the upstream fix" |

**The review's inference is the valuable part and nothing on disk refutes it:** the gate is on
*serve through the client*, and a first-party query surface does not go through the client at all.
See **P1-2**.

### Item 10 -- "Give the agent PowerShell understanding, not just linting"

| # | Claim | Score | Evidence |
| --- | --- | --- | --- |
| 10a | No `powershell-lsp query ...` surface exists | **TRUE** | `commands/` holds exactly `doctor.md`, `scan.md`, `status.md`; there is no `query` entry point in `scripts/` |
| 10b | PSES already provides navigation, completions and real-time analysis | **TRUE** | PSES is vendored at pin `v4.6.0` (`scripts/ensure-pses.ps1:11`) and the daemon already speaks LSP to it |
| 10c | Current PowerShell tooling recommends 7.x with 5.1 best-effort | **UNVERIFIABLE** | Probe: the vscode-powershell README and the PowerShell support-lifecycle page. Not fetched |

**Priced as the same slice as item 9** -- they are one build with two justifications. See **P1-2**.

### Item 11 -- "Build workspace intelligence"

| # | Claim | Score | Evidence |
| --- | --- | --- | --- |
| 11a | The warm path is scoped around edited files | **TRUE** | `scopeToEdit` defaults to `"true"` (`.claude-plugin/plugin.json`): "Filter surfaced diagnostics to the lines the edit touched; fails open to whole-file when the range is unknown" |
| 11b | Whole-repository analysis is explicit | **TRUE, and ALREADY-SHIPPED as a first-class gate** | `scripts/lsp-scan.ps1` runs over a file or a directory and emits SARIF 2.1.0 or text, with `-FailOn` for CI (`docs/repository-scanning.md`). "One engine, in-agent and in-CI" -- the same warm daemon and the same client |
| 11c | No incremental workspace index / dependency graph / diff-aware analysis exists | **TRUE** | No index beyond the offline-derived `rulesets/command-module-index.psd1`, which is a command-to-module map regenerated by a deliberate dispatch, not a workspace model |

**Recorded as P2, declared and not costed.** It is the largest item in the review and every version
of it depends on P1-2's query surface existing first.

### Item 12 -- "Clarify the boundary around your custom rules"

| # | Claim | Score | Evidence |
| --- | --- | --- | --- |
| 12a | The project describes itself as a client of PSES, not another analyzer | **TRUE** | `ARCHITECTURE.md`; `CONTRACT.md` |
| 12b | Plugin-owned rules exist: `BashIsm`, `CommandLinePlaceholder`, `ManifestConsistency`, `ModuleNotInstalled`, `NonAsciiChar`, `PS7OnlySyntax` | **TRUE, and the list is exact and complete** | `rulesets/rule-rationales.psd1:28-33` -- those six identifiers, in that order, and no seventh |
| 12c | This is treated as an implementation accident rather than a formal pack | **REFUTED in part** | The six are a named, frozen, documented set: `CONTRACT.md:350` reasons about them as a class ("a module-awareness hint rides the existing diagnostics channel as an Information record, exactly as `BashIsm`/`PS7OnlySyntax` do"), each carries a curated rationale string at `rulesets/rule-rationales.psd1:78-83`, and the rule freeze is a contractual position rather than an oversight. What is **absent is the framing** -- no document calls them an assurance pack or says what makes a rule eligible |

**The buildable part of this item is a document, not code**, and it is genuinely cheap. See
**P2-2**.

### Item 13 -- "I would reopen extensible organizational rules"

| # | Claim | Score | Evidence |
| --- | --- | --- | --- |
| 13a | The roadmap has avoided a general custom-rule framework for lack of demand | **TRUE** | `PROGRAM.md:30` (Pillar H): "**DECLINED-pending-demand.** A custom-rule seam would resurrect the already-declined new-custom-rules item under a new name ... Declined *pending demand*, not permanently: real user demand reopens it, and nothing else does." Also `ROADMAP.md:154` |

**The re-open condition is stated and this review does not meet it.** "Real user demand reopens it,
and nothing else does" -- a review is an argument, not demand, and the review's own examples are
hypothetical enterprises ("imagine Microsoft wanting"), not requests. This is recorded, not
recommended; see section 5.

### Item 14 -- "PowerShell 5.1 should probably become compatibility mode"

| # | Claim | Score | Evidence |
| --- | --- | --- | --- |
| 14a | Considerable testing effort goes into 5.1 | **TRUE** | `windows-powershell` is one of the four CI legs (`.github/workflows/powershell-lsp-ci.yml:38`) |
| 14b | 5.1 should be a compatibility tier, not first-class | **ALREADY-SHIPPED** | `docs/platform-support.md:7-8`: "As of 1.1.1 the **hooks require `pwsh` (PowerShell 7)**. Windows PowerShell 5.1 is supported as the **PSES child host** (set `ps_host` to `powershell`), **not as the hook interpreter**." That *is* the tiering the review proposes, shipped since 1.1.1 |
| 14c | 5.1 dictates every architectural decision | **REFUTED as stated** | The 5.1 leg's scope is named and bounded at `docs/platform-support.md:13-16`: "the shared-library surface under 5.1 -- file-URI casing, BOM-tolerant stdin, the `ArgumentList`-vs-quoted-`.Arguments` split, and the config-env fallback." Four named surfaces, not every decision |

**No work.** The review proposes a state the project reached five minor versions ago and did not
advertise loudly enough for an outside reader to find. The only residue is that
`docs/platform-support.md` does not use tier vocabulary -- a wording chore, and not one this docket
recommends spending a slice on.

### Item 15 -- "Enterprise deployment needs to become first-class"

| # | Claim | Score | Evidence |
| --- | --- | --- | --- |
| 15a | Air-gap support is unusually good | **TRUE** | `release/New-AirgapBundle.ps1`; `docs/configuration.md:570+`; the bundle ships as a release asset |
| 15b | No Intune / SCCM / Jamf / Ansible / VDI packages or procedures exist | **TRUE** | `SCCM`, `Jamf` and `VDI` appear nowhere in the tree outside this docket; `Ansible` appears nowhere at all |
| 15c | Machines "improvise" without an admin-distributed artifact | **REFUTED in part** | Two things already exist. The **airgap bundle** is exactly the "one known artifact" shape the review asks for. And there is a deliberate, ruled **fleet-deployable configuration surface**: `docs/configuration.md:580` and `scripts/lib/lsp-common.ps1:141` record that the `POWERSHELL_LSP_*` environment variables are admin plumbing "an organization has to deploy *to a fleet* -- via GPO, Intune, or machine-scope environment -- which a per-user config panel cannot do", ruled by Mike in dispatch 000244, and explicitly **not part of the frozen 1.x knob surface** |

**15c is the most useful finding in this scorecard, and it is a finding about cost rather than about
a gap.** The project already has a ruled, non-frozen, fleet-deployable configuration channel.
Several review proposals -- a telemetry mode, an enterprise mode, a policy path -- can land on that
channel at **zero `CONTRACT.md` freeze exposure**, which is what turns them from MINOR-bearing knob
additions into PATCH-able admin plumbing. Every slice below states its freeze answer on that basis.

### Item 16 -- "Container support should become a major test target"

| # | Claim | Score | Evidence |
| --- | --- | --- | --- |
| 16a | Container/headless operation is "compatible" rather than a first-class product mode | **TRUE** | The CI matrix is four legs -- `windows-pwsh`, `windows-powershell`, `ubuntu-pwsh`, `macos-pwsh` -- and none is a container. `Docker` appears in the tree only inside `tests/PowerShellLsp.ActionPinning.Tests.ps1` |
| 16b | `docker run ... selftest --json` should return a deterministic result | **TRUE as a gap** | There is no `selftest` and no JSON rendering (item 3d) |

**Already named as a gap by this project, in the docket the review agrees with.**
`DOCTOR-SURFACE-DOCKET.md:24,101,224` frames it exactly: "SSH, in CI, or inside a container turn
what these commands print into the conclusion 'it is broken'", and "'prove it is working' in CI or a
container remains something an operator does". Container CI is therefore **downstream of P0-1**, not
parallel to it: a container leg that cannot assert health asserts nothing.

### Item 17 -- "Add an explicit protocol contract now"

| # | Claim | Score | Evidence |
| --- | --- | --- | --- |
| 17a | The daemon's IPC format could accidentally become an API | **TRUE** | The request is built at `scripts/lsp-client.ps1:126-130` as `[ordered]@{ action = 'diagnostics'; file = $filePath; cwd = $cwd }` plus an optional `touchedRanges`, newline-delimited JSON over the pipe |
| 17b | No `protocolVersion`, request id, capabilities handshake, schema version or structured error codes | **TRUE** | No `protocolVersion` token anywhere in `scripts/`; the request carries none of those fields |
| 17c | This blocks supporting other clients without rewriting the engine | **TRUE as an inference** | Nothing on disk contradicts it; the transport is `System.IO.Pipes` with a JSON line protocol, which versions easily but is not versioned |

**Note the ordering consequence the review does not draw:** item 9/10's query surface would be the
*first* new method on this protocol. Adding a `protocolVersion` and a capabilities field **before**
that surface exists costs one line and one test; adding it afterwards means versioning a protocol
that already has two shipped consumers. **P1-4 and P1-2 should be one dispatch, in that order.**

### "The five things I would work on next"

| # | The review's item | Maps to | Verdict here |
| --- | --- | --- | --- |
| 1 | Fix source-capture privacy immediately | Item 1 | **Contested-and-priced.** Already accepted as T6.1; the review's EDR/backup argument is new and material. Slice **P0-2**, gated on ruling **R-A** |
| 2 | Signed, enforceable Enterprise Policy v2 | Item 2 | **Priced, P1.** The largest slice; the payload argument is stronger than the fail-open argument T4.2 already answered. Ruling **R-B** |
| 3 | Machine-readable `doctor` / `status` / `selftest` with provable-health semantics | Item 3 | **Agreed, P0, and already docketed.** Slice **P0-1**; ruling **R-D** was open before this review arrived |
| 4 | Versioned broker + semantic operations exposed to the agent | Items 9, 10, 17 | **Priced, P1**, as one dispatch: protocol version first, query surface second. Slices **P1-4** and **P1-2** |
| 5 | OTel + compatibility/deployment contracts | Items 7, 4, 15 | **Split.** OTel is P2 and cheaper than it looks (the instruments exist). Compatibility certification is **P1-3**. Deployment packaging is largely human-only (section 6) |

### The review's phase table, row by row

The review proposes its own phasing. Scored against what this project's disk actually supports:

| Review phase | Review's work item | Assessment here |
| --- | --- | --- |
| P0 Trust closure | Source capture privacy controls | **Kept at P0 as P0-2**, gated on R-A |
| P0 Trust closure | Strict data-root permissions | **ALREADY-SHIPPED -- STALE.** Built by dispatch 000277 leg C after the review's snapshot: `0700` directories, `0600` files, one shared helper, all 24 runtime creation sites. The review could not have seen it |
| P0 Trust closure | Eliminate unverified enterprise fallback | **Kept at P0 as P0-3.** The cleanest slice in the docket |
| P0 Provable health | `doctor -Json`, `-RequireProven`, `status --json`, `selftest --json` | **Kept at P0 as P0-1**, folded from `DOCTOR-SURFACE-DOCKET.md` |
| P0 Release governance | SLO release gates + exception mechanism | **DEMOTED to P1-1, and re-shaped.** The T3 survey shows a gate placed today would gate on a statistic the N=15 sample cannot support. Quiet-host re-runs come first |
| P0 Compatibility | Claude Code Current/N-1 certification | **DEMOTED to P1-3.** It is a CI-matrix build, not a trust closure, and `SUPPORT-POLICY.md` already tracks the failure mode that has actually bitten |
| P1 Policy v2 | Signed authoritative enterprise policy | **Kept at P1 as P1-5.** Ruling-first |
| P1 Broker API | Versioned protocol + capabilities | **Kept at P1 as P1-4.** Should lead P1-2, not follow it |
| P1 Semantic agent tools | definition / references / hover / symbol / completion / code-action | **Kept at P1 as P1-2** |
| P1 OTel | Privacy-safe fleet health/metrics | **DEMOTED to P2-1.** Cheaper than the review thinks and less urgent than everything at P0 |
| P1 Architecture split | Break common/daemon into modules/core | **DEMOTED to P3-1**, declared not costed. A rewrite in flight taxes every other slice |
| P2 Workspace intelligence | Incremental index / dependency graph / diff-aware | **Kept at P2**, declared not costed. Depends on P1-2 |
| P2 Assurance packs | Formal AI-specific rules + signed org extensions | **SPLIT.** The *naming* half is cheap (**P2-2**). The *signed org extensions* half is Pillar H, **DECLINED-pending-demand**, and this review does not meet the re-open condition (item 13) |
| P2 Deployment matrix | Intune / SCCM / Jamf / Docker / CI / VDI | **SPLIT.** Container CI is **P2-3**. Intune / SCCM / Jamf / VDI validation is **human-only** (section 6) |
| P2 Governance | Second maintainer, CODEOWNERS, LTS window | **HUMAN-ONLY** (section 6) |
| P3 External audit | Independent security / pentest review | **HUMAN-ONLY** (section 6) |

---

## 4. The build queue, phase-ordered

Each slice is sized to **at most six legs** so it can be minted as one pre-adjudicable dispatch.
Effort is session-hours for a single implementer working to this project's normal gate (tests plus a
RED control per check). **Freeze exposure** is stated against `CONTRACT.md` Tier 1, which freezes
exactly two enumerable surfaces: the **twenty `userConfig` knob names** and the **diagnostics status
token set**. Where a slice can land on the ruled `POWERSHELL_LSP_*` environment surface instead
(item 15c), that is stated, because it is the difference between a MINOR and a PATCH.

### 4.0 P0 -- already built, listed so no later night re-charters it

| Slice | State |
| --- | --- |
| **POSIX containment of every object the plugin creates** (T5.1 / T6.2 POSIX arms) | **BUILT by dispatch 000277, leg C**, after the review's snapshot. `0700` directories and `0600` for the socket endpoint and the shared JSONL writers' files, at creation, in one helper, at all 24 runtime creation sites. No knob, no token, no `CONTRACT.md` line. This closes the review's P0 "strict data-root permissions" row outright |

### 4.1 P0 -- provable health (folded from `DOCTOR-SURFACE-DOCKET.md`, unchanged)

`DOCTOR-SURFACE-DOCKET.md` is **not rebuilt and not re-ruled here.** It is folded in as-is; its own
section 5 recommends **S1**, and this docket does not second-guess that. The review's item 3 agrees
with it and adds one thing -- the status vocabulary -- which is priced separately as P0-1b.

| Slice | Mechanism | Effort | Freeze exposure | Phase |
| --- | --- | --- | --- | --- |
| **P0-1a `doctor.ps1 -Json`** (docket S1) | a third rendering beside `Format-DoctorReport` / `Format-DoctorSummary` over the same `Invoke-Doctor` seam | ~2-4 h | **ZERO** -- a CLI switch, not a `userConfig` key; emits no diagnostics status token | **P0** |
| **P0-1b status vocabulary + envelope** (the review's addition) | `HEALTHY / DEGRADED / UNHEALTHY / UNPROVEN` as the `-Json` envelope's `status`, with `schemaVersion`, the resolved versions and the check array. Derived from the existing per-check `pass` / `fail` / `unknown` -- no check changes | ~2 h on top of P0-1a | **ZERO on the frozen surface**, and the reason is exact: `CONTRACT.md` freezes the **diagnostics** status token set, and this is a doctor envelope, not a diagnostics record. The dispatch's outbox must say so explicitly, because the two words look identical | **P0**, with P0-1a |
| **P0-1c `-RequireProven`** (docket S2) | opt-in switch exiting non-zero on any UNKNOWN; a second predicate beside `$doctorFailures` at `doctor.ps1:2032` | ~1 h | **ZERO** -- the opt-in, not the contract, is what protects existing callers | **P0**, follows P0-1a |
| **ephemeral daemon for check 11** (docket S3) | doctor stands up a short-lived daemon when no session daemon is discoverable | ~1-2 d | ZERO on enumerated surfaces, but **changes a documented behavioural promise** ("report-only ... never starts, restarts or stops anything") stated in three shipped places | **P3** -- deserves its own charter and its own ruling. Unchanged from the docket |

**Legs for P0-1 (a+b+c as one dispatch, four legs):** the `-Json` rendering; the envelope and
vocabulary derivation; `-RequireProven` plus tests with a RED control in which a mutant treating
UNKNOWN as proven fails; the `preflight-doctor.md` / `commands/doctor.md` text.

### 4.2 P0 -- the two trust-closure slices

**P0-2 -- metadata-only capture mode (review item 1; ruling R-A).**

- **Exact gap it closes.** The capture writes the absolute path and the verbatim offending source
  line unconditionally. That is accepted as T6.1 for a *local* reader; the review's EDR / backup /
  eDiscovery / DLP reader set is outside T6.1's stated reasoning.
- **Mechanism (the smallest buildable shape).** One switch with three settings, read at
  `Add-DiagnosticCaptureEntries` (`scripts/lib/lsp-common.ps1:1343`): **`full`** (today's entry,
  unchanged), **`metadata`** (drop `file` to a basename or hash and drop `snippet`; keep `ruleId`,
  `severity`, `line`, `col` and the existing `hash`, which is already derived from rule id plus
  offending line at `:1383` and is a `sourceHash` in all but name), **`off`**. The dogfood lane's own
  corpus derivation reads `ruleId` + `hash`, so `metadata` preserves the channel T6.1 was protecting
  -- **that is the whole argument for this shape** and the dispatch must prove it rather than assert
  it.
- **Freeze exposure.** **ZERO if it lands as `POWERSHELL_LSP_CAPTURE_MODE` on the ruled admin env
  surface** (item 15c) -- fleet-deployable by GPO / Intune, which is exactly the reader this control
  is for, and explicitly outside the frozen twenty. **NON-ZERO (one `userConfig` key, a MINOR) if it
  lands in the config panel.** The env shape is recommended and is *why* this is P0-cheap.
- **Effort.** ~4-6 h for the env shape.
- **Test shape.** Assert `metadata` writes no `snippet` key and no absolute path; assert `full` is
  byte-identical to today's entry; assert the corpus derivation still groups correctly from
  `metadata` rows. **RED control:** the prior implementation -- today's unconditional writer -- must
  emit the snippet under `metadata`, or the mode is not what is suppressing it.
- **Legs.** Four: derive every capture entry field and its consumers; the mode switch; tests plus the
  RED control; the `THREAT-MODEL.md` T6.1 amendment and `docs/dogfood.md`.
- **Blocked on ruling R-A.** If R-A answers "leave T6.1 as accepted", this slice does not exist.

**P0-3 -- close the `gallery-fallback` hash-chain gap (review item 6; ruling R-C).** Carried forward
from the skeleton unchanged, and promoted from P1 to P0 because the review's independent agreement
and the code's own "closing that gap is its own dispatch" now point the same way.

- **Exact gap it closes.** One acquisition route vendors PSScriptAnalyzer bytes that the pinned
  SHA-256 does not gate. Every other route in either ensure-script passes one `Test-PinnedFileHash`
  and fails closed.
- **Mechanism.** After a successful `Save-Module` (`scripts/ensure-pssa.ps1:274`), locate the
  vendored payload and run it through the **same** `Test-PinnedFileHash` gate the pinned layers use
  (`:194`), failing closed exactly as `:202-207` already does. If the Gallery's on-disk shape makes a
  `.nupkg`-equivalent digest unavailable, the honest alternative is to **fail closed on the fallback
  by default** and require an explicit opt-in to accept publisher-integrity-only bytes -- which is a
  control, and therefore a different freeze answer. **Which of those two is wanted is ruling R-C.**
- **Effort.** ~3-5 h if the digest is recoverable; ~1 day for the opt-in shape.
- **Freeze exposure.** **ZERO** for verify-in-place. For the opt-in shape, **ZERO if it lands as
  `POWERSHELL_LSP_*`** -- it is bootstrap plumbing read before the diagnostics surface exists, which
  is dispatch 000244's own stated test for that surface -- and **NON-ZERO** only if it is made a
  `userConfig` knob, which nothing recommends.
- **Test shape.** Prove a fallback install whose bytes do not match the pin is refused and the marker
  records no pinned layer. **RED control:** the prior implementation -- the fallback as it ships
  today -- must ACCEPT the same mismatched bytes.
- **Legs.** Four: derive the fallback's on-disk payload shape; wire the gate; tests plus the RED
  control; `TRUST.md` and the doctor artifact-source text.

### 4.3 P1 -- release governance, with the T3 survey folded in

**P1-1 -- SLO release gates and a signed exception mechanism (review item 5).**

The review asks for a gate. `T3-REGRESSION-SURVEY.md` (dispatch 000275) says what has to happen
first, and its proposals are folded in here as this slice's leg order rather than restated elsewhere:

| Survey proposal | What it is | Placement in this slice |
| --- | --- | --- |
| **P1** Re-run the m2 block on a genuinely quiet host, at least 3 x 10 sessions | "The only thing that separates possibility 1 from possibility 3." ~1 hour wall clock, attended, zero code | **Leg 1, and it is a HUMAN leg** -- it needs a quiet host and an attended trigger. No gate work starts before it reports |
| **P3** Re-ratify T3's spread basis at N=45 rather than N=15 | "Makes 'a miss is a behavioural regression' a statement the sample can actually support" | **Leg 2, and it is a TARGET CHANGE** -- out of scope for any survey, and out of scope for a runner. It is ruling **R-F** |
| **P2** Move O2's `Get-PluginVersion` off the pre-accept path | Recovers the measured ~43 ms of segment A. "On its own this is a tidiness change wearing a fix's clothes" | **Leg 3, conditional** -- only if leg 1 shows the miss recurring. ~2-3 h with a RED control proving the stamp still appears in the session record. **ZERO freeze exposure** |
| **P4** Do nothing; record the miss as a documented single-sample event | Zero cost, "defensible if P1 shows no recurrence" | **The null result of leg 1**, and a legitimate terminal for this slice |

**Only after that** does the gate itself become buildable: a pipeline gate reading the SLO verdicts
beside the existing six (`docs/RELEASING.md:211-243`), plus the review's exception record (SLO,
owner, expiration, risk, reason, approved-by). **Freeze exposure: ZERO** -- it is release machinery,
not a runtime surface. **Effort: ~1 day** for the gate and the exception schema, after legs 1-3.
**The survey's own recommended order is P1, then re-read**, and this slice does not override it.

> **Recorded honestly: this dispatch's charter named three survey proposals; the survey carries
> four.** P4 -- "do nothing; record the miss as a documented single-sample event" -- is the fourth,
> and the survey marks it viable. It is folded in above rather than dropped, because dropping the
> null option would bias the slice toward building a gate.

**P1-2 -- first-party semantic query surface (review items 9 and 10).**

- **Mechanism.** `powershell-lsp query <op> <file> <line> <col> --json` over the existing warm daemon,
  forwarding LSP requests PSES already serves (`definition`, `references`, `hover`,
  `documentSymbol`, `workspaceSymbol`). It does **not** go through the Claude Code client, which is
  the whole point: the standing GATED arc is on *serve through the client*, and this path has no
  client in it.
- **Freeze exposure.** **ZERO on both frozen surfaces** -- a new command entry point is neither a
  `userConfig` knob nor a diagnostics status token. This is the highest capability-per-freeze slice
  in the docket and its outbox should say so.
- **Effort.** ~2-3 days for the first three operations.
- **Test shape.** Corpus fixtures with known symbol positions; assert each operation's JSON against a
  snapshot. **RED control:** a mutant that returns the request unchanged must fail every assertion.
- **Legs.** Six: the protocol extension (P1-4, which must land first); daemon-side dispatch;
  client-side command; the three operations; tests plus RED controls; docs.

**P1-3 -- Claude Code compatibility certification (review item 4).**

- **Mechanism.** A CI job that installs the plugin under Claude Code Current and Current-1 and
  asserts the hook registers and one diagnostic surfaces. The **declaration is the output**: a
  `claudeCodeCompatibility` block written from what the matrix proved, never ahead of it. That
  ordering is what keeps it consistent with `SUPPORT-POLICY.md:62`'s refusal to declare an untested
  floor.
- **Freeze exposure.** ZERO on the frozen surfaces. A manifest block is not a `userConfig` key -- but
  the dispatch must confirm that against `CONTRACT.md`'s manifest-drift guard rather than assume it.
- **Effort.** ~1-2 days, dominated by obtaining and pinning two client versions in CI.
- **Open sub-question, folded into ruling R-G:** whether Current-1 is *Required* or *Advisory*, since
  a Required leg that cannot obtain an older client blocks every release.

**P1-4 -- protocol version and capabilities handshake (review item 17).**

- **Mechanism.** Add `protocolVersion` and a `capabilities` object to the request built at
  `scripts/lsp-client.ps1:126-130` and to the daemon's response; the daemon accepts a request with no
  `protocolVersion` as version 1, so nothing existing breaks.
- **Freeze exposure.** **ZERO.** The daemon IPC is not a Tier 1 enumerable surface.
- **Effort.** ~3-4 h **now**; materially more after P1-2 ships a second consumer.
- **This must lead P1-2**, and that is the ordering finding the review does not draw. One dispatch,
  P1-4 first.

**P1-5 -- Enterprise Policy v2 (review item 2; ruling R-B).** Declared with its shape and its cost
driver, not costed to a number, because the mechanism depends on R-B:

- The payload change (include-side `requiredRules`, `severityOverrides`, `prohibitedSuppressions`) is
  the part the review is right about, and T4.2 never addressed it.
- The signing half needs **a trust root the org-policy mechanism does not have** -- `THREAT-MODEL.md`
  T4.1's own words. That is the cost driver, and it is not small.
- Freeze exposure: the policy *file schema* is not a Tier 1 surface, so a v2 schema is free; a new
  `userConfig` key would not be, and the `orgPolicy` key already exists and can carry a v2 file.

### 4.4 P2 -- declared, and costed where cheap

| Slice | Mechanism | Effort | Freeze exposure | Notes |
| --- | --- | --- | --- | --- |
| **P2-1 OTel export** (item 7) | Render existing instruments -- the `enableStats` JSONL timing lines and the capture `hash` -- as OTel metrics behind a `POWERSHELL_LSP_OTEL_ENDPOINT` env var, metadata only | ~2-3 d | **ZERO** on the ruled env surface | Cheaper than the review assumes: the measurements exist. Do **not** ship before P0-2 rules on what may leave the host |
| **P2-2 name the assurance pack** (item 12) | A document: the six plugin-owned rules as a named pack, with the eligibility test that makes a rule belong to it | ~3-4 h, no code | **ZERO** -- naming a set that already exists frozen | The genuinely cheap half of item 12. The *signed org extensions* half is Pillar H and is not proposed |
| **P2-3 container CI leg** (item 16) | A fifth CI leg: Ubuntu container, non-root, no TTY, no profile, running the suite plus `doctor -RequireProven` | ~1-2 d | ZERO | **Downstream of P0-1.** A container leg that cannot assert health asserts nothing |
| **Workspace intelligence** (item 11) | Incremental index, dependency graph, diff-aware analysis | **Not costed** | Unknown until P1-2 exists | Largest item in the review; depends entirely on the query surface |

### 4.5 P3 -- declared, not costed

| Slice | Why it is P3 |
| --- | --- |
| **P3-1 module / `.NET` broker split** (item 8) | The claim is fair -- `lsp-common.ps1` is 4,736 lines and 135 functions, an internal platform inside a `.ps1`. But a rewrite in flight taxes every slice above it, and none of them needs it. Revisit after P1 |
| **Ephemeral daemon for doctor check 11** (docket S3) | Changes a documented behavioural promise in three shipped places; needs its own charter and its own ruling. Unchanged from `DOCTOR-SURFACE-DOCKET.md` |

### 4.6 Hub hygiene -- a cross-repo slice, recorded because it is a control and not a memory

**Not a plugin change.** Recorded here because dispatch 000277 surfaced it and it has no other
docket.

The rule *"no embedded double quotes inside a `--jq` expression"* has **five banked sightings across
three projects and 2.5 months**, and dispatch 000276 still shipped a recorded check that violated it
-- one that fails under the very shell its own `shell: powershell` field names. **Banking is a
memory, not a control.** The finding 000277 banked is not the quoting rule (which would be a sixth
restatement of the family's oldest member) but the shape: *a rule that is banked does not stop
recurring.*

- **Mechanism.** A validate-time lint in the hub's `dispatch validate`, over every recorded
  `custom_checks[].command` field, refusing a double quote inside a native argument. One regex, on a
  seam that already exists -- `dispatch validate` already WARNs on `show-toplevel` and on a bare
  `git <verb>`.
- **Effort.** ~2-3 h including a RED control: a synthetic outbox carrying the 000276 command must be
  refused, and the corrected 000277 form must pass.
- **Freeze exposure.** None -- different repository, no plugin surface.
- **Recorded, not chartered.** It belongs to `strategic-dispatch`, not to this program.

---

## 5. The three standing rulings R2 opened -- now argued both ways

Dispatch 000277 could record only the ledger's side, because the review was absent. Both sides exist
now. **Nothing below recommends re-opening anything**; the cases are laid out so Mike rules once.

| Standing ruling | The ledger's original reasoning | The review's argument for re-ruling | Assessment |
| --- | --- | --- | --- |
| **Custom-rule seam (Pillar H) -- DECLINED** | `PROGRAM.md:30`: "A custom-rule seam would resurrect the already-declined new-custom-rules item under a new name. Guidance overrides remain the sanctioned seam. Declined *pending demand*, not permanently: **real user demand reopens it, and nothing else does**" | Item 13: for enterprise software a general seam "eventually becomes necessary"; allow **signed organizational assurance packs** (`corp.rules.psm1` + manifest + signature) with policy deciding which are trusted -- explicitly *not* a giant plugin SDK | **The re-open condition is not met.** The ledger names one trigger -- real user demand -- and the review supplies an argument plus hypothetical enterprises ("imagine Microsoft wanting"), not a request. The signed-pack shape is a better proposal than the seam that was declined, and it is worth recording *for when demand arrives*, which is what this row does. **Recommend: no re-rule** |
| **Native-LSP gating** | Standing arc "Native code navigation, end to end" is **GATED**: "Registration works; serve does not on the direct path. The opt-in `nativeServe = shim` closes it locally; removing the shim waits on the upstream fix" | Item 9: "Stop allowing native Claude LSP limitations to dictate the product" -- build a first-party agent-facing interface to PSES instead of waiting | **The review is right, and the gate is not what needs re-ruling.** The gate is on *serve through the client*; a first-party `query` surface does not touch the client, so it is **not blocked by this gate at all** and needs no re-rule to proceed. That is slice **P1-2**. The gate itself still waits on the upstream fix, correctly. **Recommend: no re-rule; charter P1-2 instead** |
| **PS 5.1 first-class** | `ps_host` ships `pwsh` as default with `powershell` (5.1) documented and CI-covered as its own leg (`windows-powershell`); DX-AUDIT **T3** is an accepted priced tradeoff (ratified G4, 2026-08-21) | Item 14: define Tier 1 (PowerShell 7 current/LTS), Tier 2 (5.1 compatibility), Tier 3 (unsupported); "not letting a 2016-era runtime dictate every architectural decision" | **The review is describing a state the project already occupies.** `docs/platform-support.md:7-8` has required `pwsh` for hooks since 1.1.1, with 5.1 supported only as the PSES child host, and `:13-16` bounds the 5.1 leg to four named surfaces. There is nothing to re-rule; at most there is tier *vocabulary* to adopt, which is a wording chore. **Recommend: no re-rule** |

---

## 6. OUT OF RUNNER SCOPE -- human-only, explicitly

None of these can be done by an overnight runner, and none is proposed as work here. They are listed
so a later night does not silently pick one up.

- **A second maintainer.** `TRUST.md:467` and `MAINTAINERS.md:6` both record the single-maintainer bus
  factor; the review's organizational section is **TRUE** and cites the project's own words. Only
  Mike can add a maintainer.
- **Enabling CODEOWNERS enforcement.** `.github/CODEOWNERS` ships **inert** by design
  (`GOVERNANCE-SURFACE.md`): enabling `require_code_owner_reviews` would deadlock the repository
  until a second maintainer exists. A repository-settings change.
- **Signing-key succession and backup release authority.** A custody decision, not a build.
- **Documented support lifecycle, supported-release window, deprecation policy, emergency release
  procedure.** Commitments only the maintainer can make.
- **An external security audit or pentest.** Procurement.
- **Intune / SCCM / Jamf / Ansible / VDI validation.** Requires managed estates this project does not
  have. Note the *configuration channel* for them already exists and is ruled (item 15c); what is
  human-only is the validation, not the plumbing.
- **Marketplace or registry submission.** An external publishing action, on the same rail that keeps
  the corpus commons "prepared-not-published".
- **The T3 quiet-host re-run (survey P1) and the T3 spread-basis re-ratification (survey P3).** The
  first needs a quiet host and an attended trigger; the second is a change to a ratified target.

---

## 7. Rulings block -- answer inline

Each row is a question this docket surfaced and did **not** answer. The recommended default is a
recommendation.

| # | Question | Options | Recommended default | Mike's answer |
| --- | --- | --- | --- | --- |
| **R-A** | **RE-OPEN T6.1?** The review's EDR / backup / eDiscovery / DLP reader set falls outside T6.1's stated reason ("a local user who already has the source files it quotes"). 000277's leg C already closed the local half | (a) re-open narrowly and build **P0-2** as a metadata-only mode on the admin env surface, T6.1 amended to record the management-plane reader; (b) leave T6.1 accepted as written and restate the acceptance in `CONTRACT.md` / `docs/configuration.md`; (c) re-open fully and make metadata the default | **(a)** -- it answers the one clause the new argument reaches, keeps the dogfood channel T6.1 was protecting, and costs zero freeze exposure on the env surface | |
| **R-B** | **RE-OPEN T4.2?** The review's argument is not the one T4.2 answered: it says a subtract-only payload cannot express an org requirement, so the degrade *direction* was the wrong axis to rule on | (a) charter **P1-5** Policy v2 whole (include-side payload first, signing second); (b) charter the payload half only and defer signing until a trust root exists; (c) leave T4.2 as accepted and record the payload gap in `docs/configuration.md` | **(b)** -- the payload argument stands on its own, and the signing half needs a trust root `THREAT-MODEL.md` T4.1 says the mechanism does not have. Splitting keeps the cheap half from waiting on the expensive one | |
| **R-C** | For **P0-3**, which shape closes the `gallery-fallback` hash gap? | (a) verify the fallback's bytes against the same pin, fail closed; (b) fail closed on the fallback by default with an explicit opt-in to accept publisher-integrity-only bytes | **(a)** -- zero freeze exposure, and it makes the one unpinned route match the other four. Carried unchanged from the 000277 skeleton | |
| **R-D** | `DOCTOR-SURFACE-DOCKET.md` has been unruled since 000276. Build **P0-1**? | (a) P0-1a+b+c as one dispatch; (b) P0-1a only; (c) none | **(a)** -- that docket's own section 5 recommends S1, the review independently reaches the same item, and the vocabulary (P0-1b) is what makes the JSON usable by a fleet tool | |
| **R-E** | Was the enterprise review audited? | **ANSWERED BY EXECUTION -- this dispatch.** The file exists (section 1), was read end to end, and every numbered item, the five things and every phase-table row are scored in section 3. The row moves out of PENDING-MIKE into the rows-that-left table | -- | ANSWERED |
| **R-F** | Survey **P3**: re-ratify T3's spread basis at N=45 rather than N=15? This is a **change to a ratified target**, and no survey or runner may take it | (a) re-ratify at N=45 after the quiet-host re-runs; (b) keep N=15 and treat the miss as a documented single-sample event (survey P4); (c) decide after the re-runs | **(c)** -- the survey's own order is "P1, then re-read", and both (a) and (b) are answers to a question the re-runs are what settle | |
| **R-G** | For **P1-3**, is Claude Code Current-1 a **Required** or **Advisory** CI leg? | (a) Advisory; (b) Required | **(a)** -- a Required leg that cannot obtain an older client blocks every release, which trades one enterprise risk for a worse one | |

---

## 8. What this docket deliberately did not do

- **No build.** Every slice in section 4 is a proposal. The one P0 row marked BUILT was built by
  dispatch 000277 under its own separate ruling and is listed for continuity.
- **No claim taken on faith.** Every factual claim in section 3 carries a file and line, a live `gh`
  read, or an explicit UNVERIFIABLE with the probe that would settle it. Six claims rest on
  third-party web documentation and are scored UNVERIFIABLE rather than assumed true.
- **No re-litigation of `DOCTOR-SURFACE-DOCKET.md`.** It is folded in whole, with its own
  recommendation intact, and only *added to*.
- **No re-ruling.** Section 5 argues both sides of all three standing rulings and recommends
  re-opening none of them.
- **No target changed.** `SLO-BASELINES.md` is untouched, the T3 verdict of record is not
  re-rendered, and the survey's P3 is routed to a ruling rather than taken.
- **No re-banking of the `--jq` quoting rule.** Section 4.6 records the control that would
  mechanically refuse it, which is what the fifth banked sighting proved is missing.
- **No phase kept unexamined, and the arithmetic is stated rather than rounded.** The review's
  phase table has **fourteen rows**, and its `P0 -- Trust closure` row bundles three work items,
  so section 3 dispositions **sixteen** work items in all. **Nine** are placed somewhere other
  than where the review put them -- demoted, split, marked already-shipped, or routed to the
  human-only list -- and **seven** are kept where they are, each with the reason stated.
