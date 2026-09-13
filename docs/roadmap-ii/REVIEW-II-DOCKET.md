# Review II docket -- the 2026-09-12 360 review, audited and turned into a hardened roadmap

**Status: LANDED, rulings R23-R31 ratified (section 8); W1-1 and W1-2 BUILT by dispatch 000295, everything
else in the roadmap (section 4) still a PROPOSAL, nothing else built.** Lives at
`docs/roadmap-ii/REVIEW-II-DOCKET.md`, beside `ENTERPRISE-PROGRAM-DOCKET.md`, which did the same job
for the 2026-09-05 review. Same vocabulary, same slice sizing (at most six legs per dispatch), same
freeze accounting against `CONTRACT.md` Tier 1 (the twenty `userConfig` knob names and the
diagnostics status token set).

Author: Strategic-Claude, 2026-09-12. Ground truth: the PK bundle collected 2026-09-12T07:49 (v1.34.0
plugin at commit 61d6118 / dispatch 000294 accepted), memory, and live web where noted. Every claim
below is tagged **[disk]** (read from the bundle), **[web]** (fetched today), or **[inferred]**.

> **Section 1 re-scored against the tip by dispatch 000295 (leg A), 2026-09-12.** Every row was
> re-derived from the files it cites, or its `gh` read re-run; four rows moved (1, 11, 12, 22), each
> marked **MOVED** in place with a one-line note. Everything else re-derived identically to what is
> below -- no other row changed. Section 8 (new) carries rulings R23-R31, ratified by Mike Andersen's
> acceptance of dispatch 000295.

---

## 0. What this docket is, and is not

- It **audits** the review claim by claim before it adopts anything (section 1). The prior review
  audit (dispatch 000278) scored 16 claims; this review makes roughly 30 load-bearing ones.
- It **names where the review re-litigates a ruling** that Mike Andersen already made (section 2).
  A ruling is not reopened by a second reviewer agreeing with the losing option; it is reopened by
  a new argument, and the docket says which items carry one.
- It proposes an **ordered** build queue (section 4), a **rulings block** (section 5), and the
  **information still missing** (section 6). It does not charter anything; charters are dispatches.

The ordering principle, stated once so nothing below has to re-argue it:

1. **Unblock before build.** Anything waiting only on a ruling or a hand action costs nothing to clear and
   is holding finished work.
2. **Ship what is built before building more.** `[Unreleased]` on `main` carries six MINOR entries since
   v1.34.0 (2026-09-07) [disk].
3. **Cheap product-surface fixes before engineering.** The review's most damaging findings (Issues page,
   README fold, temp-dir debris) are each under a day and touch no frozen surface.
4. **Measure before architecture.** The effectiveness benchmark and the latency decomposition decide
   whether the expensive items (modularization, a direct-analyzer path) are warranted, and they produce the
   one artifact the project has never had: proof the plugin changes agent output.
5. **Make the suite cheap before inviting contributors.** Tiering and a Pester 6 lane come before the
   good-first-issue set, or contributors pay a 25-30 minute tax on a one-line PR.

---

## 1. Claim-by-claim scorecard

Vocabulary (from 000278, extended by one term): **TRUE** / **STALE** (was true at the review's snapshot,
`main` has moved) / **REFUTED** / **ALREADY-SHIPPED** / **RE-LITIGATES-RULING** (the item is a decision
Mike already made; adopting it means a re-rule, not a build) / **UNVERIFIABLE-HERE** (needs a `gh` run or a
file not in the bundle).

| # | Review claim | Verdict | Evidence |
| --- | --- | --- | --- |
| 1 | `lsp-common.ps1` >5,000 lines, ~150 functions | **TRUE** | 5,154 lines / 150 `function` declarations [disk], unchanged at `61d6118`. **MOVED:** `ENTERPRISE-PROGRAM-DOCKET.md`'s P3-1 row is corrected to this figure by dispatch 000295 (leg A item 2); its other two occurrences of the stale 4,736/135 count are left untouched, out of that item's stated scope |
| 2 | `doctor.ps1` >2,400 lines; `pses-daemon.ps1` ~2,000 | **TRUE** | 2,403 / 1,986 [disk] |
| 3 | Principal unit test file ~6,000 lines | **TRUE** | `tests/PowerShellLsp.Unit.Tests.ps1` is 5,990 lines / 383,692 bytes at `61d6118` [readout 2026-09-12] |
| 4 | ~56K lines PowerShell, 36 Pester files, ~2,500 tests | **TRUE** | 36 `*.Tests.ps1` files by census; 2,487 tests at 000293 [disk, readout]. Total line count not derived; not load-bearing |
| 5 | Full suite 20-45 min depending on host | **TRUE** | Quiet-host range 1,350-1,790 s across four runs (000292/000293) [disk]; contended runs worse (PSES init 21.8 s under a runaway statusline, since removed at source) |
| 6 | CI green across six jobs incl. both PS generations, Linux, macOS, container, Claude Code compat | **TRUE** | All six legs `success` at `61d6118` (run 34661081902, 2026-09-12T00:16Z), plus `sarif-upload` and CodeQL [readout] |
| 7 | Compat leg tests Claude Code 2.1.263 and 2.1.261 | **TRUE** | `powershell-lsp-ci.yml` pins Current=2.1.263, Current-1=2.1.261 as of 2026-09-08 [disk]. Current-1 is **Advisory** (R13) |
| 8 | Compat leg does not prove a diagnostic reaches Claude | **TRUE, and RULED** | R-H / R14 (2026-09-08): the diagnostic-surfacing half is "not to be bought" as a PR gate; an attended or scheduled check **outside the publishing repo** is the sanctioned shape [disk]. The review's "external scheduled certification" is that shape -- compatible, not a re-rule |
| 9 | Warm edit round-trip 2.2-2.5 s | **TRUE, dated** | median 2,228 ms / p95 2,463 ms, n=30, v1.24.3, 2026-07-17 [disk]. Not re-measured since; a v1.12-era note attributes ~0.7 s to the per-hook `pwsh` spawn Claude Code pays regardless |
| 10 | Diagnostic capture defaults to `full` | **TRUE, and RULED** | R8 (2026-09-05) chose option (a): metadata mode on the env surface, **off by default**. Option (c), "make metadata the default", was on the table and not chosen [disk]. See section 2 |
| 11 | `orgPolicy` can only filter/restamp; no required rules or forbidden suppressions | **STALE in part** | `SeverityOverrides` shipped (000289) [disk]; `requiredRules` / `prohibitedSuppressions` are the P1-5 remainder. **MOVED:** no longer blocked -- **R23 ruled (D) 2026-09-12** (was blocked/unruled three nights running); dispatch 000294 builds the remainder via issue #235 |
| 12 | Review's hybrid for `prohibitedSuppressions` (cheap live AST flag + `-IncludeSuppressed` in the repo scan) | **TRUE, and RULED** | **MOVED:** was NEW ARGUMENT / unruled. **R23 ruled (D) 2026-09-12**, matching this hybrid exactly -- (B) live on the edit path plus (A) inside `lsp-scan.ps1` for the repo/CI path. Consumer: dispatch 000294 via issue #235 |
| 13 | No independent security review; not publisher-Authenticode-signed | **TRUE / RULED** | Review: stated in README [disk]. Authenticode: **declined-final**; `scripts/sign-plugin.ps1` estate-signing is the paved path [disk] |
| 14 | OTel export lives on unreleased `main` | **TRUE** | P2-1 complete (000290/000291), in `[Unreleased]` [disk]. **A v1.35.0 MINOR is waiting to be cut** |
| 15 | Custom-rule seam: change "declined" to "deferred until a validated enterprise consumer" | **ALREADY-SHIPPED** | `ROADMAP.md` already reads "declined pending demand -- real user demand is the only thing that reopens it" [disk]. The review's wording is the current wording |
| 16 | Keep the `powershell-lsp` slug; change display positioning only | **AGREES WITH RULING** | Rename is declined [disk]. Positioning is a HUMAN product call |
| 17 | Anthropic's official LSP catalog has no PowerShell entry | **TRUE** | Eleven languages, none PowerShell [web, code.claude.com]. The official marketplace is curated at Anthropic's discretion; the in-app submission forms feed the **community** marketplace only [web] |
| 18 | "Pursue plugin-directory placement aggressively" | **MISFRAMED** | The community form was submitted twice; submission state is API-invisible and checkable only by hand at the Console. **Do not submit again.** The official catalog has no submission path. Section 4, Wave 0, names the one hand action that remains |
| 19 | Official plugin install counts (TS >200K etc.) | **UNVERIFIABLE-HERE** | Not checked; not load-bearing |
| 20 | 7 stars / 0 forks / 9 open issues; v1.34 archive downloaded 6x, airgap and SBOM 0x | **TRUE, exactly** | 7 / 0 / 9 and 6 / 0 / 0 (control-map also 0) at 2026-09-12T08:44 [readout]. **All nine open issues are night reports**; zero open PRs. Traffic, 14 days: 1,012 clones / 204 unique cloners vs 17 views / 7 unique viewers -- clones include every CI checkout and marketplace install, so the split between humans and runners is not derivable from this readout |
| 21 | Public Issues page is dominated by dispatch night reports | **TRUE, 9 of 9** | #212-#235, all authored by `manderse21` via keyring `gh`, not a bot [readout]. W1-1 is therefore a retarget of one `gh issue create -R`, and `manderse21` is admin on the hub repo, which has Issues enabled |
| 22 | ~1,000 `psls*` temp dirs, ~11 GB, on the dev machine | **STALE** | **MOVED:** re-derived this session via `[IO.Path]::GetTempPath()` + a directory census (the same convention `Get-IntegrationDaemonLeak` uses) -- **37 dirs / 1.77 GB**, sharply down from the 1,048 dirs / 11 GB dispatch 000293 measured the prior evening via `du -sh` in Git Bash, which this docket had carried forward at 08:44 without an independent re-measurement. Cause not established -- no sweep ran under this dispatch; recorded as a finding, not assumed. **R29 ruled (sweep) 2026-09-12** regardless of the count -- still Mike's separate list-then-confirm script [disk] |
| 23 | Pester 6 is GA (July 2026); Pester 5 is in maintenance mode | **TRUE** | Pester 6.0.0 released; 5.9.0 (2026-07-07) declares maintenance mode; 5.9.1 shipped 2026-08 [web]. The project pins 5.x **deliberately** (`run-tests.ps1:18`, "a fresh install must not silently run under Pester 6. Upgrading is a later call") [disk] |
| 24 | No measurement that Claude writes better PowerShell because of the plugin | **TRUE** | The efficacy ledger ships but its input data is the gap (CURRENT-STATE s.10); Arc C is gated on "real efficacy data existing" [disk]. Nothing measures with-plugin vs without |
| 25 | Modularize `lsp-common.ps1` strangler-style, no rewrite | **AGREES WITH DOCKET** | P3-1 is declared-not-costed, "revisit after P1" [disk]. The review adds the strangler shape and a module list; P1 is now mostly built, so the trigger condition is near |
| 26 | Test tiering (fast PR path, full matrix on main/nightly) | **NEW** | No tiering exists; every PR runs the full suite on all legs [disk] |
| 27 | Enterprise deployment recipe, deterministic pinning, MSI/WinGet | **PARTLY MISFIT** | Pinning: `plugin.json` + marketplace already pin; airgap bundle ships. MSI/WinGet do not fit a git-distributed marketplace plugin. A **managed-marketplace + env-policy recipe doc** is the fitting slice |
| 28 | Do not build a SaaS control plane, dashboards, C# rewrite, custom rule packs, AI review | **AGREES WITH ROADMAP** | All already declined or paced [disk] |
| 29 | GitHub ships central AI Controls / agent policy for Copilot | **UNVERIFIABLE-HERE** | Not re-checked; used only as framing |
| 30 | Review did not rerun the suite (no `pwsh` in its environment) | **TRUE by its own statement** | Same limitation applies to this docket |

---

## 2. Where the review re-litigates, and whether it brings a new argument

| Item | Existing ruling | Does the review add a new argument? | Disposition |
| --- | --- | --- | --- |
| Capture default -> `metadata` | R8 = (a), 2026-09-05: metadata mode, off by default | **Yes, one.** "By default no source text and no absolute path are persisted" is a questionnaire answer, and the dogfood channel T6.1 protected is fed by **one machine** today, so the default's cost is a single env var on the maintainer's own host. That cost argument was not on the table on 2026-09-05 | Re-rule offered as **R25**; recommendation: flip |
| Custom-rule seam | Declined pending demand | No -- the review's proposed wording is the current wording | No action |
| Publisher Authenticode | Declined-final; estate signing ships | No -- "would be even stronger" restates the losing side | No action |
| End-to-end Claude proof in CI | R-H / R14: not a PR gate; attended or scheduled, outside the repo | No conflict -- the review asks for exactly the sanctioned shape | Build as **W2-1** (benchmark) and optionally **W3-4** (scheduled certification) |
| PS 5.1 first-class | R14: no re-rule | Not raised by this review | No action |
| Native-LSP gate | R14: no re-rule; #86936 lifts it | Review agrees native LSP is commoditizing, does not ask to un-gate | No action |
| Rename | Declined | Review agrees | No action |

---

## 3. Two things the review missed that change the plan

1. **The direct-PSSA latency lane collides with a shipped invariant.** "One engine, in-agent and in-CI"
   is guarded by `PowerShellLsp.SarifScan.Tests.ps1`, and every corpus snapshot is derived from **PSES's**
   publish, whose default rule set is narrower than the `Invoke-ScriptAnalyzer` CLI default (six rules
   surface on the fly) [disk]. A direct `Invoke-ScriptAnalyzer` path therefore has to reproduce PSES's rule
   selection byte-for-byte or it changes what the corpus asserts. That is why W2-2 is **findings-only** with
   a byte-equivalence gate, not a build. It also **couples to R23**: option (A) for `prohibitedSuppressions`
   would load PSSA into the daemon, which is the same mechanism the latency lane would need. Rule them
   together.
2. **The hook path has a floor the daemon cannot lower.** Each `PostToolUse` fires a fresh `pwsh` process
   (the ~0.7 s attributed in v1.12) before the client touches the pipe. The review's "warm p50 < 1 s"
   target may be unreachable on the hook path regardless of analyzer choice. W2-2's first leg is a segment
   decomposition so the target is set against a measured floor, not a wish.

---

## 4. The roadmap, in order

Effort is session-hours for one implementer at this project's normal gate (tests plus a RED control per
check). Freeze exposure is stated against `CONTRACT.md` Tier 1. **HUMAN** marks legs only Mike can do.

### Wave 0 -- unblock and ship (zero new code)

| Slice | What | Owner | Cost |
| --- | --- | --- | --- |
| **W0-1 Rulings R23-R31** | Section 5. R23 alone has held P1-5's remainder for three nights | HUMAN | one sitting |
| **W0-2 Cut v1.35.0** | `[Unreleased]` carries six MINOR entries: OTel export, doctor `otelExport`, `SeverityOverrides`, the query surface (two entries), the container leg, plus patches. Dry-run-judged-first, tag after four named legs green on `main` | HUMAN gate, runner prep | ~2 h prep |
| **W0-3 P1-1 leg 1** | The quiet-host m2 re-run, 3 x 10 sessions. Nothing in P1-1 starts until it reports | HUMAN | ~1 h attended |
| **W0-4 Console check** | Read the community-marketplace submission state at `platform.claude.com/plugins` by hand. Do **not** resubmit. Record the answer in the ledger so no session infers it again | HUMAN | minutes |
| **W0-5 Live-number readout** | `gh repo view --json stargazerCount,forkCount,openIssues`, `gh release view v1.34.0 --json assets`, `gh issue list --limit 50 --json number,title,labels`. Pins the review's adoption claims to a date | HUMAN | minutes |

### Wave 1 -- product surface, cheap, zero freeze

| Slice | Mechanism | Effort | Freeze | Notes |
| --- | --- | --- | --- | --- |
| **W1-1 Night reports off the plugin Issues page** | Hub change, not plugin: the runner's morning-report `gh issue create` targets `manderse-dispatch/strategic-dispatch` (or hub Discussions). Retro: label existing report issues `dispatch-report`, close them with a one-line pointer. Enable Discussions on the plugin repo; keep the false-positive form as the Issues front door | ~3-4 h, hub + one PR | ZERO | The single highest buyer-experience return per hour in the review. Needs R26. RED control: a synthetic morning report must land in the hub and NOT in the plugin repo |
| **W1-2 Test data-root ownership + teardown + janitor** | Every test-minted `psls*` root gets a `.psls-owner.json` marker (suite pid, run id, created-at) at mint; `AfterAll`/`finally` teardown in every fixture that mints one; a janitor that deletes only `temp root AND psls leaf AND marker present AND owner pid dead AND age > 24 h`. Never a bare `psls*` glob | ~1 d | ZERO (test-only) | Reuses 000293's structural-property recognition. The **existing** 1,048 dirs predate the marker, so the janitor cannot prove ownership of them: the one-time sweep is a HUMAN action off a confirm list (R29). RED control: a root without a marker survives the janitor |
| **W1-3 README top fold** | Three questions in the first screen (what pain, what it does, why not another LSP plugin), then the GIF, then the five-minute install, then "why not generic LSP", then the enterprise evidence. Everything below the fold is **restructured, not reduced** (the decline stands) | ~4-6 h, docs only | ZERO | `doc-claims.psd1` and the knob-table set-equality guards already stop drift; keep them |
| **W1-4 Display positioning** | `plugin.json` description, GitHub About, README H1 -- slug unchanged. Candidates: "PowerShell quality gate for coding agents"; "Real PowerShell analysis after every AI edit -- with proof it ran" | HUMAN product call, then ~1 h | ZERO | Needs R30. The `description` field is on the marketplace surface; check the marketplace schema before editing |
| **W1-5 P1-5 remainder built to R23** | `requiredRules`, `prohibitedSuppressions`, the `severityThreshold` boundary, one slice. 000292's phase records carry the seam, the pinned-analyzer facts and the `IncludeRules` trap | ~1-2 d | ZERO (policy file schema is not Tier 1) | Blocked on R23. If R23 = hybrid, the scan half lands in `lsp-scan.ps1` with `-IncludeSuppressed` / `-SuppressedOnly` restricted to the prohibited set |

### Wave 2 -- measure before architecture

| Slice | Mechanism | Effort | Freeze | Notes |
| --- | --- | --- | --- | --- |
| **W2-1 Effectiveness benchmark** | Three arms: Claude alone; Claude + a generic PSES LSP plugin (the Piebald one is the natural comparator); Claude + this plugin. 50-100 PowerShell tasks sampled from a **published, seeded** task list. **Pre-registered** metrics: escaped PSSA findings in final output (scored by the PSSA CLI, not by the plugin), parse errors, repair turns, tool calls, tokens, wall time, final Pester pass rate. Report n, host, Claude Code version, plugin version. Publish a negative result as readily as a positive one | ~3-5 d design + attended runs; model credits | ZERO | Needs R27. Design doc in the plugin repo (`docs/effectiveness/DESIGN.md`); harness and raw results **outside** it (hub, or a sibling `-bench` repo) per R-H. Feeds Arc C's gate and the README's one honest headline. **Hardening:** freeze the task list and metrics before the first run; hash the task file into the report |
| **W2-2 Latency decomposition + direct-analyzer probe** | Leg 1: instrument the warm path into segments (hook `pwsh` spawn; client connect; `didOpen` to settled publish; debounce; render) with n >= 30, publish beside the v1.24.3 figure. Leg 2: **findings-only** probe of `Invoke-ScriptAnalyzer` in a warm runspace inside the existing daemon, gated on byte-equivalence with every corpus snapshot. Leg 3: recommendation with numbers, building nothing | ~2-3 d | ZERO (nothing ships) | Needs R31. Success is a decision, not a speedup. If equivalence fails, the lane closes with the number that closed it. Couples to R23 option (A) |
| **W2-3 Suite tiering** | Pester tags per tier (pure/unit, client-config-protocol, PSES component, critical e2e, full cross-platform, mutation/RED certification). `run-tests.ps1 -Mode pr` runs the first four on every leg; `-Mode full` on `main` push, nightly, and as a release precondition. **The six job identities are not renamed**; mode is an input, not a matrix change. Publish the measured per-tier wall clock | ~2 d + a census leg first | ZERO (test-only) | Do not lower any assurance: `full` still gates release. RED control: a test with no tier tag fails the census, so nothing slips out of every mode silently |
| **W2-4 Pester 6 experimental lane** | A **seventh** job, own name, `continue-on-error: true`, `Install-Module Pester -MinimumVersion 6.0.0` on one leg (ubuntu is cheapest). Track the failure list as a doc, not a fix list | ~4-6 h | ZERO | Needs R28. The 5.x pin stays; this only measures the migration distance. Removed-in-6 assertions are not in the carried test files [disk], but `-ForEach $null` discovery and per-file discovery may bite |

### Wave 3 -- enterprise closure that needs no trust root

| Slice | Mechanism | Effort | Freeze | Notes |
| --- | --- | --- | --- | --- |
| **W3-1 P1-1 gate + exception record** | After W0-3 reports: the SLO verdict gate beside the release pipeline's existing six, plus the exception schema (SLO, owner, expiry, risk, reason, approved-by) | ~1 d | ZERO (release machinery) | Unchanged from the enterprise docket |
| **W3-2 Policy identity in the doctor envelope** | `doctor -Json` gains `orgPolicy`: `path`, `sha256` (of the file as read), `sidecarMatch` (the existing `<policy>.sha256` check from 000259), `applied`. Same additive-field discipline as `captureMode` / `otelExport`; `schemaVersion` does not move | ~4-6 h | ZERO | Answers "this exact policy was active on this device" without a trust root. Signing stays deferred (R9) |
| **W3-3 Managed mode: fail-closed on policy** | `POWERSHELL_LSP_POLICY_MODE = open \| closed` on the env surface: `closed` makes a missing or hash-mismatched `orgPolicy` file resolve every edit to a **new banner under the existing `unavailable` token** rather than fail-open. Default `open` (today's behaviour) | ~1 d | ZERO if the env surface; **NON-ZERO** if it adds a status token -- it must not | The review's "failure to validate policy means analysis is noncompliant". The banner reuses `unavailable`; the reason text is new, the token is not |
| **W3-4 Deployment recipe doc** | One page: managed marketplace pin, `POWERSHELL_LSP_*` via GPO/Intune, airgap bundle placement, `doctor -Json` + exit codes for a fleet check, OTLP endpoint. No dashboard | ~4-6 h, docs only | ZERO | Replaces the review's MSI/WinGet ask with what fits a git-distributed plugin |
| **W3-5 OpenSSF Scorecard + badge** | Free, automated, recognised by security reviewers; likely already scores well (SHA-pinned actions, SBOM, attested releases). Findings first, then fix what is cheap | ~2-4 h | ZERO | The cheapest partial answer to "no independent review"; a paid audit stays a HUMAN funding call |
| **W3-6 Scheduled Claude certification (optional)** | Nightly or pre-release, outside the publishing repo: Claude Code Current and Current-1 on Windows and Linux, one deliberately broken script, assert the repair happens | ~1-2 d after W2-1's harness exists | ZERO | R-H's sanctioned shape. Reuses W2-1's harness, which is why it is after it |

### Wave 4 -- architecture debt, strangler only

| Slice | Mechanism | Effort | Freeze | Notes |
| --- | --- | --- | --- | --- |
| **W4-1 First extraction from `lsp-common.ps1`** | Move one bounded subsystem behind a `.psm1` with its existing tests, on the next dispatch that touches it. Candidates by lowest coupling: `Paths`, `Security` (pinned-hash and sidecar), `ProcessLifecycle`. `PowerShellLsp_LibPurity_Tests.ps1` already polices the library's purity and is the seam to extend | ~1 d per module, opportunistic | ZERO | P3-1's trigger ("after P1") is near. **After W2-3**, so each extraction validates on the PR path in minutes. RED control: the one-definition guards (pipe name, `Invoke-PluginHook`) must still find the moved definition |
| **W4-2 `doctor.ps1` check-per-file** | One file per `Test-Doctor*` check, `Invoke-Doctor` unchanged | ~1 d | ZERO | Same shape; lower risk than W4-1 |

### Wave 5 -- community and continuity

| Slice | Mechanism | Effort | Notes |
| --- | --- | --- | --- |
| **W5-1 Good-first-issue set** | Five to eight contribution-sized issues cut from W4's extraction list and W2-3's tier census, labelled, each with the RED-control expectation stated | ~3 h | After W1-1 (clean Issues) and W2-3 (fast PR path) or contributors bounce |
| **W5-2 Design partners** | Three to five people who write PowerShell with Claude Code, recruited to run W2-1's task list on their own work | HUMAN outreach | External publishing is Mike's gate always |
| **W5-3 Maintainer #2** | `CONTINUITY.md` leaves the successor account undecided [disk]. The review is right that this is the next real enterprise milestone. Precondition: W1-1, W2-3, W4-1 -- a second maintainer needs a repo they can read and a suite they can run | HUMAN | No engineering slice; a decision and an invitation |
| **W5-4 Case study** | The first design partner's before/after, published under the same evidence discipline as the white paper | after W2-1 / W5-2 | HUMAN gate |

### Declined or not adopted from this review

| Review item | Why not |
| --- | --- |
| Publisher Authenticode signing | Declined-final; estate signing ships |
| Resubmit to the plugin catalog / "pursue the directory aggressively" | Submitted twice; state is API-invisible; official catalog has no submission path. W0-4 is the whole action |
| Change the custom-rule-seam wording | Already the wording |
| MSI / WinGet packaging | Does not fit a git-distributed marketplace plugin; W3-4 is the fitting slice |
| Warm p50 < 1 s as a target | Not adopted **until W2-2 reports**; the hook spawn floor may make it unreachable on the hook path |
| Custom rule packs, SaaS control plane, dashboards, C# rewrite, AI code review, more languages | Review and roadmap agree |

---

## 5. Rulings block -- answer inline

Each row: the question, the options, the recommendation, and what it unblocks. R21/R22/R24 are 000294's
numbers; R23 is reserved there for the `prohibitedSuppressions` answer and is used for that here.

| # | Question | Options | Recommendation | Unblocks |
| --- | --- | --- | --- | --- |
| **R23** | How is `prohibitedSuppressions` enforced? (three nights unanswered; issue #233) | (A) second `-IncludeSuppressed` pass in the daemon per edit; (B) plugin-owned rule flagging a `SuppressMessageAttribute` naming a prohibited rule, on the edit path; (C) drop it; **(D) hybrid**: (B) live plus (A) inside `lsp-scan.ps1` for the repo/CI path | **(D).** (B) is deterministic and costs no daemon change; the scan already runs PSSA over whole trees, so `-IncludeSuppressed` restricted to the prohibited set is where true enforcement is cheap. (A) on the edit path is deferred to W2-2's finding, since loading PSSA in-daemon is the same mechanism | W1-5 |
| **R24** | PK ratchet -- 000293's three costed options | as costed in 000293's phase records | Not re-argued here; 000293's table is the record | PK budget |
| **R25** | Flip the capture default to `metadata` for new installs? | (a) keep `full` (R8 as ruled); (b) flip to `metadata`, `full` explicit opt-in, MINOR, `doctor -Json` already exposes `captureMode` (R19) | **(b).** New argument: the dogfood channel is fed by one host today; the maintainer sets `POWERSHELL_LSP_CAPTURE_MODE=full` locally and I0.3 accrual continues unchanged. The questionnaire line "no source text or absolute path is persisted by default" is worth more than the default dogfood data from installs that do not yet exist | W1-3 (README line), `TRUST.md`, `THREAT-MODEL.md` T6.1 amendment |
| **R26** | Move night-report issues to the hub repo? | (a) yes, hub Issues; (b) hub Discussions; (c) leave | **(a).** Hub Issues keep `issue-sync`'s shape; Discussions on the hub are a second-best. Retro-close the existing report issues on the plugin repo with a pointer | W1-1 |
| **R27** | Authorise the effectiveness benchmark (model credits, attended, outside the publishing repo)? | (a) yes as W2-1; (b) design doc only; (c) no | **(a).** It is the one artifact the North Star promises ("every effectiveness claim measured") and does not have. Consistent with R-H: not a PR gate, not a credential in CI | W2-1, Arc C, W5-4 |
| **R28** | Add a Pester 6 allowed-to-fail lane? | (a) yes, seventh job, own name; (b) no | **(a).** The 5.x pin stands; the lane measures distance only | W2-4 |
| **R29** | The 1,048 leftover `psls*` dirs | (a) hand sweep off a confirm list, now; (b) leave until W1-2's janitor exists (it will not touch them either -- no marker); (c) leave | **(a)** for the existing debris, with the confirm list printed first; **W1-2** for everything minted after | disk, W1-2 |
| **R30** | Display positioning line | HUMAN product call; two candidates in W1-4 | No recommendation beyond: keep the slug; keep "honest about whether analysis ran" in the first sentence, since it is the differentiator every comparator lacks | W1-4 |
| **R31** | Authorise the direct-analyzer latency probe as findings-only? | (a) yes, byte-equivalence-gated, nothing ships; (b) segment decomposition only (leg 1); (c) no | **(a).** It costs nothing on the frozen surface and either closes the lane with a number or opens it with one. The North Star's "client of PSES" is not breached by a probe that builds nothing | W2-2, informs R23 (A) |

---

## 6. Section 6 as originally asked, and what the 2026-09-12 readout settled

Collected by `Collect-ReviewII-Evidence.ps1` at 2026-09-12T08:44-04:00 against `61d6118`.

| Asked | Settled | Answer |
| --- | --- | --- |
| `gh` readout | yes | Rows 3, 4, 6, 20, 21 above. v1.33.1 was **never a release** -- `gh release view v1.33.1` returns not found; the line is v1.32.0 -> v1.33.0 -> v1.34.0. The overview memory's "v1.33.1 is the current release" was wrong and is corrected in this session |
| `docs/benchmarks.md` and the Benchmark test | yes | The published warm figure times the **whole hook invocation** (pwsh spawn, module load, round trip), so W2-2 leg 1's decomposition is new work, not a re-read. `tests/bench/` already carries `Invoke-LatencyBench.ps1`, `Invoke-ProfileSweep.ps1` and a quiescence gate (`Invoke-QuiescenceProbe.ps1`); the sweep measures cold start at n=10 but publication excludes it. The harness is the seam W2-2 extends |
| Largest test file | yes | `PowerShellLsp.Unit.Tests.ps1`, 5,990 lines. Not carried into PK; distil into `VERIFICATION_SURFACE.md` if needed |
| R21 answered anywhere? | yes: **NO** | #233's five comments are all Mike's close-out narration (f2 run 1, f2 run 2, the statusline addendum, verify run 3, the PK notch); #235 has zero comments; the hub search returns only issue-sync tracking issues; `RULE_CANDIDATES.md` has no hit; the decision ledger's one hit says "not built". **R23 is open and is the ruling** |
| Runner identity on the hub | yes | The reports are posted as `manderse21` (keyring token, `repo` scope). `manderse21` is admin/push on `manderse-dispatch/strategic-dispatch`; the hub has Issues on and Discussions off; the plugin repo has Discussions off. No bot permission question exists |
| Console submission state | **still HUMAN** | W0-4 |
| Spend appetite | **still HUMAN** | benchmark credits; paid security review |

## 7. What this docket deliberately did not do

- It did not re-derive the enterprise docket's P-rows; it references them by name and marks one row
  (P3-1's line/function count) STALE for the next docket touch.
- It did not draft dispatches. Each slice above is sized to be one; the first three candidates, in order,
  are **W1-1**, **W1-2**, and **W1-5** (once R23 lands), because they are the cheapest and each is ready.
- It did not re-open R14's three standing rulings. Nothing in the review carries a new argument for any of
  them.

## 8. Rulings, ratified by acceptance of dispatch 000295

Carried verbatim from the accepted inbox body (Hub Rule 18: every charter carries the rulings it executes
or establishes verbatim, in a section titled for it, so the ruling is attributable from disk without the
chat that produced it).

- **R23** (prohibitedSuppressions enforcement) = **D**. A = second -IncludeSuppressed pass in the daemon per edit; B = plugin-owned rule flagging a SuppressMessageAttribute that names a prohibited rule, on the edit path; C = drop; D = B on the edit path plus A inside lsp-scan.ps1 for the repository and CI path. Consumer: dispatch 000294, P1-5 remainder, via issue #235.
- **R24** (PK ratchet) = **option 1**, KeepDispatchCount floor 15. Options as costed in 000293-PHASE-RECORDS.md. Consumer: the next PK collection.
- **R25** (capture default) = **flip**. keep = R8 stands, full remains the default; flip = metadata becomes the default for new installs, full is explicit opt-in, MINOR, with THREAT-MODEL T6.1, TRUST.md and README amended and doctor -Json captureMode (R19) as the fleet check. Consumer: its own charter; not built by Review II night 1.
- **R26** (night reports) = **a**. a = hub repo Issues; b = hub Discussions; c = leave. Consumer: leg B of this dispatch if a; the nine existing plugin-repo report issues are retro-closed by Mike by hand in every case.
- **R27** (effectiveness benchmark) = **yes**, harness in hub. Three arms, pre-registered metrics, PSSA-CLI-scored, outside the publishing repo per R-H. Consumer: W2-1, its own charter.
- **R28** (Pester 6 lane) = **yes**. A seventh job with its own name, continue-on-error, Pester 6 on one leg; the 5.x pin stands. Consumer: W2-4, its own charter.
- **R29** (existing psls* debris) = **sweep**. sweep = Mike runs a separate list-then-confirm script; wait = leave until further notice; never = leave. In every case leg C of this dispatch refuses roots without a marker. Consumer: Mike, and leg C.
- **R30** (display positioning, slug unchanged) = **Real PowerShell analysis after every AI edit -- with proof it ran**. Consumer: W1-4, its own small charter (plugin.json description, GitHub About, README H1).
- **R31** (direct-analyzer probe) = **yes**. yes = segment decomposition plus a byte-equivalence-gated in-daemon Invoke-ScriptAnalyzer probe, nothing ships; segments-only = leg 1 only. Consumer: W2-2, its own charter; informs R23 option A.

Ratified by Mike Andersen's acceptance of dispatch `powershell-lsp/000295`
(`projects/powershell-lsp/inbox/000295-review-ii-night-1-rulings-r23-r31-ratified-by-acceptance.md`
in the strategic-dispatch hub), 2026-09-12. The tenth item the same inbox section carries -- **Spend**
(benchmark credits yes; paid security review later) -- is not R-numbered and is out of the R23-R31 span
this section is chartered to carry; it is not reproduced here.
