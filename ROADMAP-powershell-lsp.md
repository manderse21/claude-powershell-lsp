# claude-powershell-lsp -- Roadmap

Status as of 2026-07-17. Plugin on main: **v1.24.3**, GPL-3.0-or-later (both manifests + the latest
CHANGELOG release heading at 1.24.3 -- verified-from-disk). The version is TAGGED, gitsign-signed,
and RELEASED (verified-from-web this session): an annotated, gitsign-signed tag v1.24.3 -- cut from
the release runner by `github-actions[bot]` under the gated `workflow_dispatch` pipeline -- sits at
commit 99f2b23 on origin (the #86 merge), `git describe --tags origin/main` returns v1.24.3, and the
v1.24.3 GitHub Release is published as **Latest** (2026-07-17T00:09:43Z). The old publish gap (the
registry once served a stale 1.3.0) stays CLOSED.

The whole **v1.24.x band is closed out**: v1.24.0, v1.24.1, v1.24.2 and v1.24.3 are each tagged on
origin and published as GitHub Releases (verified-from-web: `git ls-remote --tags origin` +
`gh release list`). This matters because the three v1.24.1-3 rows below were, until this refresh,
absent from Section 2 -- the doc claimed a v1.24.0 present that origin had already moved past.

Provenance: every version, feature, and dispatch claim below is verified against live state THIS
session -- `dispatch list --project powershell-lsp`, the dispatch log, `git log origin/main`, `git
describe --tags`, `git ls-remote --tags origin`, `gh release list`, the CHANGELOG, and the
plugin/marketplace manifests. **Each status claim in this document is labelled verified-from-disk
(read out of this tree), verified-from-web (resolved live against origin / GitHub at run time), or
inferred (reasoned, not observed).** Tag and release state is NEVER copied from memory or from a
prior roadmap revision: it is resolved live, because that is exactly the claim that goes stale
fastest -- v1.24.3 was released roughly an hour before this session began.

Goal (Mike, confirmed): an open tool that is excellent and findable -- not a paid product, not
adoption-chasing. That "findable" goal is now acted on: the r/PowerShell and r/ClaudeCode launch
posts are LIVE (2026-07-05), and the in-repo launch draft (docs/launch/reddit-powershell.md, rewritten
to v1.23.0 ground truth) merged via plugin PR #77. The old "platform bet" framing (wait for Anthropic
to fix LSP registration) is retired: 000069 proved the registration failure was our own manifest, 000075
fixed it, and 000103 shipped an opt-in shim that un-gates native serve locally without waiting on the
upstream client fix. What remains upstream-gated is spelled out honestly in Section 1.

## 1. The native-LSP story, corrected

For most of this project the native LSP triad (hover / go-to-definition / find-references) was treated
as platform-gated -- built, verified, and parked pending an Anthropic fix. Two dispatches dissolved
that framing, and a third (v1.23.0) un-gated serve locally:

- **Registration -- restored, v1.18.1 / 000075.** Claude Code's runtime LSP registrar silently drops
  any `lspServers` entry declaring `restartOnCrash` or `shutdownTimeout` (both schema-valid, so
  plugin.json validates, but the registrar rejects them with no diagnostic). Our block declared both,
  so `.ps1/.psm1/.psd1 -> powershell` never registered. 000075 removed the two fields and added an
  allowlist guard; registration is re-proven on the fixed tree (the persisted 000069 probe harness,
  Claude Code 2.1.195).
- **Serve -- un-gated LOCALLY, v1.23.0 / 000103.** Once registered, Claude Code launches PSES but its
  LSP client times out during initialization on the `#1359`-class server->client handshake, so on the
  direct launcher native nav does not complete. The opt-in `nativeServe` knob (default `off`) ships a
  thin stdio proxy (scripts/pses-serve-shim.ps1) that, when set to `shim`, patches the forwarded
  `initialize` (disables `dynamicRegistration` so PSES advertises its nav providers statically and
  sends no `client/registerCapability`; drops the params-level `workspaceFolders` that trips a PSES
  Linux init NRE; ensures a `rename` capability) and answers the residual `workspace/configuration` +
  `window/workDoneProgress/create` locally -- so hover / go-to-def / find-refs / documentSymbol serve
  end-to-end WITHOUT the upstream fix, at ~1-2 ms added framing per round-trip. With the knob `off` the
  proxy is a transparent pass-through and native nav stays gated exactly as before. The shim is a
  workaround for an upstream client bug, so it is off-by-default and removable (point `lspServers` back
  at pses-stdio.ps1).

Two honest boundaries, stated everywhere this is described:

- **Upstream #1359 (serve handshake) is still open.** The shim routes around it locally; it does not
  fix the client. anthropics/claude-plugins-official#1359 is OPEN (verified live this session); our
  refreshed comment on it is posted (2026-07-05), but the upstream client fix has not landed. When it
  does, the shim becomes removable -- the report-only `doctor.ps1 -ProbeNativeServe` check (v1.23.0 /
  000104, off-by-default) automates the static-serving half of that re-probe and today reports "still
  gated -- the shim remains needed."
- **A second, independent Windows blocker (#73961) gates the whole native nav tier there.** On Windows,
  Claude Code 2.1.196-2.1.200's native LSP launcher refuses to spawn the registered server's bare
  `pwsh` command pre-spawn ("Command 'pwsh' not found or is in an unsafe location"), upstream of the
  shim, pses-stdio.ps1, and PSES -- so it is reached whether `nativeServe` is `off` or `shim`. It is
  not a powershell-lsp defect: dispatch 000107 reproduced the identical refusal on the official
  pyright-lsp plugin. It is filed as anthropics/claude-code#73961 (OPEN, verified live), documented as
  a known issue in v1.23.1 (000108), and the verdict is wait-for-upstream (no single
  `lspServers.command` string can be both a Windows `.cmd` wrapper and a cross-platform launcher, and
  the absolute-path workaround fails `claude plugin validate`). macOS/Linux native nav under these
  Claude Code versions is untested with the real client and is not claimed in either direction.

Crucially, none of this touches the plugin's real surface: per-file diagnostics ride the warm
PostToolUse hook over a different, unguarded shell-spawn path, so PSScriptAnalyzer diagnostics keep
working normally on Windows regardless of the native nav gate.

## 2. Shipped and verified -- recent arc

CHANGELOG.md is the version-history-of-record. Each row is traced to its CHANGELOG entry and its
dispatch(es); where an authored draft disagreed with the CHANGELOG, the CHANGELOG won.

| Version | Dispatch | Delivered |
|---|---|---|
| v1.24.3 | 000126 (ranking 000125 leg 3) | PATCH -- **base-ruleset curation slice 2, and the slice that CLOSES curation**. `PSUseOutputTypeCorrectly` was the sole rule of the base-54 still firing on the 44-file known-good oracle (2 pedantic Information hits, 0 own-source hits, base-only -- not in the PSES-15 set), so excluding it via the existing named `$BaseRuleExclusions` list takes base **54 -> 53** and makes the ENTIRE opt-in `base` surface **0% measured false-positive** on that oracle. `pses-default` is byte-for-byte unchanged; `rulesets/base.psd1` REGENERATED through `scripts/regen-base-ruleset.ps1` (never hand-edited) and the rationale table regenerated to `pssa_count` 53 with all four 000125 overrides intact. With a 0% measured FP rate there is no evidence for a further exclude slice, so **base curation is COMPLETE** and 000126 deliberately recorded `next_suggested: null`. Tag v1.24.3 gitsign-signed; GitHub Release published **Latest** (2026-07-17, verified-from-web) |
| v1.24.2 | 000125 leg 1 (N1.1 slice 1) | PATCH -- **the rule-rationale OVERRIDE layer**: four idiom-family codes (`PSShouldProcess`, `PSUseSupportsShouldProcess`, `PSAvoidUsingWriteHost`, `PSAvoidShouldContinueWithoutForce`) now render hand-authored why+fix guidance instead of the weak text auto-derived from PSScriptAnalyzer's own CommonName + Description, which for idiom rules is circular (the "why" restates the rule name) or pure mechanism (it describes the checker, not the idiom, and offers no fix). The layer records each override's PRE-override `derived` text so a pin bump that changes the replaced text goes RED rather than being silently masked by the override -- drift-visible by construction. This is **N1.1 slice 1**: guidance quality on rules that already fire, not new detection. Tag v1.24.2 gitsign-signed; GitHub Release published (verified-from-web) |
| v1.24.1 | 000124 | PATCH -- **rule-rationale coverage CLOSED**: the plugin's fifth owned code, `ManifestConsistency`, gained its hand-authored rationale. v1.24.0 shipped the feature with a recorded gap -- four of five owned finders had an entry and `ManifestConsistency` rode the graceful-degrade path with none, surfacing its finding with no `why:` line. Hand-authored through `scripts/regen-rule-rationales.ps1` and the table regenerated (never hand-edited). The 000124 survey also corrected the N1.1 premise: no NEW-detection idiom slice clears a 0%-measured-FP bar, which is what re-scoped N1.1 to guidance quality and produced v1.24.2. Tag v1.24.1 gitsign-signed; GitHub Release published (verified-from-web) |
| v1.24.0 | 000121 (survey 000120 leg 2) | MINOR -- **rule-rationale strings** (feedback #9; horizon item I0.1). Every surfaced rule now carries a short static "why this rule matters" line on the EXISTING `additionalContext` channel, so a finding arrives with the reasoning attached, not just the verdict. The table `rulesets/rule-rationales.psd1` is HYBRID and GENERATED, never hand-edited: 58 entries = the 54 rationales for the `rulesets/base.psd1` PSScriptAnalyzer surface, auto-derived offline from the vendored pinned PSScriptAnalyzer 1.25.0 (`CommonName` + a whole-sentence `Description` prefix, 180-char budget, cut at a word boundary), plus 4 hand-authored entries for the plugin-owned finders PSScriptAnalyzer knows nothing about (`BashIsm`, `ModuleNotInstalled`, `NonAsciiChar`, `PS7OnlySyntax`). `scripts/regen-rule-rationales.ps1` writes it and its `-Check` drift guard re-derives and diffs it (exit 0 match / 1 drift), mirroring `regen-base-ruleset.ps1`; a pin-coupled unit guard goes RED unless a pin bump or a base-ruleset edit regenerates the table in the same reviewed diff. Rendering is deduplicated per RULE, not per finding -- a rule firing eight times in a file renders its rationale once -- bounding the added context to roughly (distinct rules in the file) x 180 chars. Two properties hold by construction: a clean file still emits NOTHING (byte-identical, integration-proven), and a rule with no entry degrades gracefully, surfaced with no rationale line, never fabricated. NO knob, NO `CONTRACT.md` change, NO new status token, and NO change to which rules run. Tag v1.24.0 gitsign-signed, provenance-attested; GitHub Release published Latest (2026-07-09) |
| v1.23.1 | 000108 (survey 000107); 000110 (survey 000109); release-prep 000114 | PATCH (docs). Two documentation deliverables to installed users: (1) the Windows native-LSP launcher guard recorded as a known issue (docs/upstream/claude-code-lsp-registration.md + the README `nativeServe` section, scoped to Windows, upstream claude-code#73961); (2) every one of the 17 `userConfig` descriptions capped (<= ~200 chars each) for Claude Code config-panel height stability, with the full per-knob semantics relocated -- nothing deleted -- into a new docs/configuration.md, after 000109 found a long description could push the /plugin config panel past the viewport and trip a renderer ghost-row corruption. Behavior byte-for-byte unchanged: no knob key, type, value, default, `CONTRACT.md`, or product-code change. Tag v1.23.1 gitsign-signed; GitHub Release published Latest (2026-07-04) |
| v1.23.0 | 000099; 000101 (survey 000100); 000103 (survey 000102); 000104 | MINOR (four features). 000099: format-on-edit `apply` activated -- `formatOnEdit=apply` becomes a guarded write-back (stale-write compare-and-swap, atomic-or-abort swap, BOM/EOL fidelity, no-change=no-write; a mixed-EOL / non-UTF-8 file aborts to a suggestion), the first feature that ever modifies the user's file; the default stays `off` and `off`/`suggest` are byte-for-byte unchanged. 000101: module awareness (`moduleAwareness` knob, default `off`) -- an Information-severity "command from an uninstalled module" hint from a shipped offline command->module index, design B (install-check-gated), silent on every ambiguity. 000103: the native-serve shim (`nativeServe` knob -- Section 1). 000104: the report-only `doctor.ps1 -ProbeNativeServe` removability probe, plus the v1.23.0 cut itself. Tag v1.23.0 gitsign-signed, provenance-attested |
| v1.22.0 | 000096; 000097 (release-prep 000098) | MINOR -- the AI-era rule pack, slices 2 and 3, which CLOSE the pack. Both are always-on additive pre-PSSA AST passes over the parser AST the pre-pass already produces (no knob, no status token, `CONTRACT.md` unchanged). 000096 `PS7OnlySyntax`: flags PowerShell-7-only syntax an AI drops into a file that may run on 5.1 (`&&`/`||`, ternary `? :`, `??`/`??=`/`?.`/`?[]`), suppressed when the file declares `#Requires -Version 7`. 000097 `BashIsm`: flags Unix command NAMES in a `.ps1` (`grep`, `sed`, `awk`, `export`, `which`, `touch`, `chmod`, `chown`, `ln`), suppressed by an explicit `& name` call or a same-file definition. With slice 3 the 000055 pack is CLOSED (slice 4 was already-covered; slice 5, angle-bracket placeholders, is deferred on irreducible false-positives). The measured 0% FP / 100% TP held on the widened corpus. Tag v1.22.0 gitsign-signed, provenance-attested |
| v1.21.1 | 000092 (survey 000091; release-prep 000093) | PATCH -- EXCLUDE-ONLY curation of the opt-in `base` ruleset, 57 -> 54 rules. The 000091 wave measured three default-on rules as net-noise over a 34-file known-good oracle (`PSReviewUnusedParameter` ~90% FP on the param-block + nested-function shape; `PSUseSingularNouns`; `PSUseShouldProcessForStateChangingFunctions`), all three BASE-ONLY (none in PSES's built-in 15-rule set), removed via a named `$BaseRuleExclusions` list so base.psd1 REGENERATES deterministically. `pses-default` is byte-for-byte unchanged; the three Error-severity security rules and `PSAvoidUsingWriteHost` are retained. The frozen CONTRACT surface (the `ruleset` knob) is untouched |
| v1.21.0 | 000087 | MINOR -- opt-in broadened live surface: a new `ruleset` enum knob (`pses-default` | `base`, default `pses-default`) selecting the fallback ruleset when no repo-local settings and no explicit settingsPath resolve. `base` resolves the plugin-owned, explicitly-enumerated rulesets/base.psd1 (default-on minus the compatibility-profile family, 57 rules at the pin), broadening the live surface to include `PSAvoidUsingWriteHost` and the three Error-severity security rules. An explicit settingsPath and a discovered repo-local settings file ALWAYS win. The default is deliberately NOT flipped. A DELIBERATE MINOR with a CONTRACT amendment |
| v1.20.0 | 000059 | MINOR -- off-by-default format-on-edit SUGGESTIONS: a `formatOnEdit` knob (`off` | `suggest`, default `off`). When `suggest`, each edit triggers a warm-daemon Invoke-Formatter round-trip (honoring the repo's own PSScriptAnalyzerSettings.psd1) and surfaces the result as a unified-diff SUGGESTION via additionalContext; the hook NEVER rewrites the file. `apply` was reserved here and treated as `off` -- later activated as the guarded write-back in v1.23.0. A DELIBERATE MINOR with a CONTRACT amendment |
| v1.19.0 | 000057 / 000060 / 000061 / 000062 | MINOR (four features) cut as one release. 000057: SARIF 2.1.0 + a standalone CI-mode scan over the same engine the hook uses. 000060: AI-era rule pack slice 1 -- the non-ASCII smuggling pre-PSSA byte pass (built the reusable pre-PSSA source category later slices 2/3 reuse). 000062: project-intelligence slice 1 -- deterministic .psd1 static manifest-consistency. 000061: closed-loop agentic correction slice 1 -- the warm daemon re-checks the touched range next turn and reports cleared/still-present, additive |
| v1.18.1 | 000075 (publish 000076) | PATCH -- native LSP registration restored (drop the two registrar-hostile fields + allowlist guard); registers-but-serve-gated UX documented. 000076 closed the publish gap and added the tree-vs-published divergence guard (now Gate 5) |
| v1.18.0 | 000064 | MINOR -- supply-chain signing: keyless gitsign-signed release tags (Sigstore via GitHub OIDC, Rekor-logged) + corrected trust posture (cosign judged redundant; Authenticode deliberately not pursued) |

One no-version-bump train landed between v1.23.1 and v1.24.0 and so has no row: **000120** (plugin PR
#81). Its build leg bounded the Pester bootstrap in `tests/run-tests.ps1` to the **5.x major** at all
three resolution points (the detection filter, `Install-Module`, and `Import-Module`, the latter two
carrying `-MaximumVersion 5.99.99`) and added a text-pin guard test, so the Pester 6.0.0 GA
(2026-07-07) cannot ride a runner-image change into the suite with nobody deciding to upgrade
(Section 6). Its docs leg refreshed `docs/upstream/claude-code-lsp-registration.md` to the
post-rewrite `#66987` record (Section 6). Its third leg was the rule-rationale SURVEY that specified
the v1.24.0 slice above -- it built nothing. Test-infra and docs only; no version moved.

### HELD in PR (this dispatch, 000127) -- NOT merged, NOT released

Everything in this subsection sits in ONE open plugin PR on `dispatch/000127-overnight-train`. It is
**not on main, not tagged, not released**, and no version moved. It is listed here so the roadmap is
not silently stale for a reader who pulls the branch -- never as shipped work. Merge, and any release,
are Mike Andersen's gates. **Leg 8 classified this train NO-BUMP** (reasoning below).

- **Leg 1 -- N1.2/N1.3 reference surfacing: BLOCKED, survey delivered, ZERO product edits.** The
  design is settled and the single blocking decision is named (the `CONTRACT.md` FROZEN-KNOBS
  amendment); see N1.2 in Horizon 1. Nothing was built and no workaround was attempted -- a
  frozen-surface amendment is not an unattended decision. The survey is the leg's deliverable.
- **Leg 2 -- the ServeShim lifecycle flake: ROOT-CAUSED and FIXED (test-infra only).** The 000125
  outbox recorded two lifecycle tests (process reap + crash-propagation exit) failing intermittently
  on BOTH hosts, the failing pair VARYING per run, one isolated run fully green, and all four CI legs
  green. Root cause: the test harness's PSES-child lookup matched ANY `pwsh`/`powershell` whose
  command line contained `Start-EditorServices.ps1` + `pses-serve-`, scoped to nothing -- so a PSES
  leaked by a PRIOR session (000125 recorded six, aged 19-29h, and already suspected them of
  "inflating the local ServeShim flake") was returned as "this shim's child". The reap assertion then
  measured a foreign process, and the crash scenario KILLED one. That explains every recorded symptom,
  including why CI never saw it: a clean runner has no orphans. The lookup is now scoped to the run
  under test (start-time + parentage, both parameters mandatory so the unscoped scan is
  unexpressible), and three fixed sleeps became bounded readiness gates. **Shim product code is
  untouched** -- the semantics were never at fault.
- **Leg 3 -- N1.5 latency harness + measured numbers (see N1.5, and `docs/benchmarks.md`).**
- **Leg 4 -- N1.6 slice-2 survey: verdict recorded, ZERO product edits** (see N1.6).
- **Leg 5 -- E2.1: exit-code policy matrix tests + the code-scanning upload workflow** (see E2.1). The
  workflow is inert until merged by construction (no `pull_request` trigger), and the four named CI
  legs plus the release pipeline are diff-proven byte-identical.
- **Leg 6 -- catalog poll (read-only): `claude-powershell-lsp` is NOT present** in
  `anthropics/claude-plugins-community`'s `marketplace.json` (HTTP 200, 2248 plugin entries, polled
  2026-07-17T01:05:03Z, verified-from-web). Nothing is inferred about Console-side state in either
  direction; see E2.3, which is Mike-gated and unchanged.
- **Leg 7 -- this refresh.**
- **Leg 8 -- NO-BUMP (recorded, unilateral).** Classified from the CHANGELOG's own on-disk policy over
  what actually landed: MINOR requires "a new backward-compatible capability -- a new `userConfig`
  knob, an added diagnostics feature, a newly CI-verified platform", and **none of those landed**. Leg
  1 blocked, so there is no knob; leg 5's exit-code gate turned out to have shipped in v1.19.0 already,
  so what it landed is tests, a repo-CI workflow, and one behavior-neutral internal refactor (the
  `-FailOn` policy function moved into the scan library so it could be unit-tested at all). The
  plugin's runtime behavior is byte-identical. That is exactly the **000120 precedent** -- a
  test-infra-and-docs train that moved no version and took no Section 2 row. The docs improvements ride
  the next release that has a real reason to cut.

Earlier arc (v1.5.x through v1.17.0 -- launch-readiness, licensing MIT -> GPLv3, reliability /
auto-relaunch, doctor self-check, dogfood capture + review tooling, the CI proof-framework, the
enterprise trust-surface + measured-0%-FP corpus, community-release readiness, and release-engineering
automation with SBOM + provenance) is in CHANGELOG.md and the 000001-000067 log -- all merged,
F2-verified, and tagged where a version moved. CHANGELOG.md is authoritative for that older band; it
is not re-transcribed per-version here.

## 3. Release process -- hardened (the gate is structural, not convention)

The release path is enforced on three layers, all shipped, and every release from v1.19.0 through the
current v1.24.3 was cut end-to-end by it (verified-from-web: the v1.24.1/v1.24.2/v1.24.3 tags are all
`github-actions[bot]`-tagged from the release runner, never a local tag):

- The gated release pipeline (`.github/workflows/powershell-lsp-release.yml`, `workflow_dispatch` only
  -- it never auto-fires on push or merge): five gates make a bad tag structurally impossible -- Gate 1
  target commit merged to main, Gate 2 tag does not already exist, Gate 3 version lockstep
  (plugin.json == marketplace.json == requested), Gate 4 four-leg push-CI GREEN by name (it WAITS for
  the run to reach a terminal state, then judges), Gate 5 tree-vs-published parity (the 000076
  divergence guard, `release/Test-PublishedParity.ps1`). It then builds the source archive + a
  CycloneDX SBOM, attests SLSA build provenance (`actions/attest-build-provenance`), and cuts the
  keyless gitsign-signed tag from the runner.
- 000080 (shipped): a tracked local pre-push guard that refuses a direct push to origin/main.
- 000081 (shipped): server-side branch protection on main -- require a PR, require the four named CI
  legs (`ubuntu-pwsh` / `windows-powershell` / `windows-pwsh` / `macos-pwsh`) green and strict, enforce
  for admins, block force-push and deletion.

Together the gated pipeline + the local guard + server-side protection make the gated flow the ONLY
path to main. v1.19.0 was the first release cut under all three; **v1.24.3 is the latest**
(verified-from-web, published Latest 2026-07-17T00:09:43Z).

## 4. Forward plan -- the four-horizon ladder (tactical -> strategic)

Forward work is a ladder, not a set of parked lanes. It climbs Immediate tactical (unblocked now) ->
Near-term tactical (survey-first cadence) -> Enterprise hardening (adoption-gating) -> Strategic /
what-if (the bets). Every build item names its gate and its output. No build dispatch is queued today
(the live `dispatch list` is authoritative on that -- Section 7); every item below is horizon work,
each gated on a future accept. The feedback-derived items come from a prior planning triage of a
10-item external-feedback set -- not a file in this repo -- carried here so they stop living only in
chat.

### The 10 feedback items -- disposition

| # | Suggestion | Verdict | Where it lands |
|---|---|---|---|
| 1 | Auto-fix write-back | SHIPPED | `formatOnEdit=apply`, v1.23.0 |
| 2 | Symbol graph | PARTIAL / forward | project-intelligence slice 1 shipped (v1.19.0); reference surfacing -> N1.2 |
| 3 | Cross-file reasoning | FORWARD (survey) | referenced-by-N via the diagnostic channel -> N1.2 |
| 4 | Repository memory | RESIST | persistent learned state; the agent's memory layer, not the plugin -> S3.3 |
| 5 | PS-specific refactoring | SCOPED to flagging | the plugin flags, no refactor engine -> N1.1 |
| 6 | Risk analysis / score | DROP score, keep facts | deterministic graph facts only -> N1.3 |
| 7 | Runtime intelligence | STATIC slice shipped | `moduleAwareness`, v1.23.0; the runtime version left -> S3.5 |
| 8 | Teach PS idioms | STRONGEST fit | rationale/fix-quality slices on shipped rules -> N1.1 |
| 9 | Explain why a rule exists | SHIPPED | rule-rationale strings, v1.24.0; coverage closed v1.24.1 (000124) |
| 10 | Learn from accepted fixes | SPLIT | closed-loop primitive shipped (v1.19.0); learn-team-style resisted -> S3.3 |

### Horizon 0 -- Immediate tactical (unblocked now; gated only on accept)

- **I0.1 Rule-rationale strings (#9) -- SHIPPED (v1.24.0 / 000121); coverage CLOSED (000124).**
  Delivered as a MINOR and, as planned, with no new knob; the `CONTRACT.md` amendment anticipated here
  turned out to be unnecessary, because additive prose on an existing channel leaves the frozen Tier-1
  surface (knob names, status tokens, and the "a clean pass adds nothing" property) untouched. The ship
  detail is in Section 2. Dispatch 000124 then hand-authored the one missing entry, so all **five**
  plugin-owned codes -- `BashIsm`, `ManifestConsistency`, `ModuleNotInstalled`, `NonAsciiChar`,
  `PS7OnlySyntax` -- now carry a rationale, and `rulesets/rule-rationales.psd1` covers the plugin's
  whole surfaceable set (**53 PSSA + 5 owned = 58 entries**) at the pin (verified-from-disk this
  session: `base.psd1` declares 53 `IncludeRules`, and the table's own `pssa_count` = 53,
  `owned_count` = 5, entries = 58). The PSSA count dropped by one when v1.24.3 / 000126 excluded
  `PSUseOutputTypeCorrectly` from base; this line still carried the pre-000126 count until this
  refresh -- the residual 000126 recorded and this dispatch closes. (The superseded number is
  deliberately not restated here: quoting a stale count inside the correction is what makes a
  future drift-grep match the very string it is meant to catch -- the 000123 vacuity lesson.)
  Nothing about I0.1 is open. The
  graceful-degrade path itself is unchanged and still load-bearing: a rule outside the `base.psd1`
  surface (one a user's own settings file enables) surfaces its finding with no rationale line, never
  fabricated, never blocking.
- **I0.2 Post the registrar-field-rejection upstream report -- RESOLVED (no code).** The novel
  silent-drop finding (000069) is filed: Mike rewrote `anthropics/claude-code#66987` (OPEN) on
  2026-07-06 into the comprehensive registrar-drop report, re-confirmed on Claude Code 2.1.201. The
  routing question that made this an open item is settled -- do NOT open a fresh issue, since `#66987`
  already is the dedicated, open, has-repro registrar-drop issue and a second would split the signal.
  A drafted plugin-guard follow-up comment is post-ready and still unposted, but it is optional and
  low-priority: 000120 leg 3 recommends holding it for a natural occasion (a maintainer question, or a
  nudge if the issue goes quiet) because it advances nothing toward a fix.
- **I0.3 Begin the dogfood accrual.** Dogfood normal edits of the canonical checkout, then run
  `scripts/review-dogfood.ps1`. This is the only thing that unblocks the quality wave (N1.4);
  behavioral, not a dispatch. Output: the ranking that authorizes the first curation slice.

### Horizon 1 -- Near-term tactical (survey-first, one slice per dispatch)

- **N1.1 Idiom rule-pack slices -- rationale/fix quality (#8; #5 as flagging).** The 000124 survey
  measured the idiom candidates and corrected the premise: none clears a 0%-measured-FP bar as NEW
  detection. Two already ship built-ins -- `PSShouldProcess` (inside the PSES-15 default surface) and
  `PSAvoidUsingWriteHost` (base-only) -- and the verb-triggered
  `PSUseShouldProcessForStateChangingFunctions` was deliberately excluded as noisy (000092). So the
  slices are GUIDANCE quality: hand-authored rationale/fix OVERRIDES on rules that ALREADY fire, riding
  the v1.24.0 rationale channel -- not new rules. Slice 1 (000125): the owned rationale-override layer
  over the 4-code idiom family (`Write-Host` -> `Write-Information`, `PSShouldProcess`,
  `PSUseSupportsShouldProcess`, `PSAvoidShouldContinueWithoutForce`), anchored on `PSShouldProcess` (the
  only one on the default surface). The `ThrowTerminatingError` candidate stays DEFERRED-unmeasurable:
  the plugin's own source has zero `[CmdletBinding()]` advanced functions and the clean oracle no
  `throw`, so no advanced-function rule can be FP-measured until a corpus tier is added. The plugin
  flags; the agent transforms. Output: PATCH per slice (better guidance on findings that already
  render, not a new capability).
- **N1.2 Cross-file reference surfacing (#2 / #3) -- SURVEYED (000127 leg 1); BUILD BLOCKED on ONE
  Mike decision.** A deterministic "referenced by N files" signal via the diagnostic channel -- NOT the
  gated native-nav path. The 000127 survey settled the design and then hit a named stop, so the design
  is now specified and the gate is a decision, not more work:
  - **Index strategy: SETTLED -- session-start index, not a per-edit scan** (measured this session,
    verified-from-disk, pwsh 7.6.3, 30 iterations per point). A per-edit full workspace scan costs
    **p50 1902 ms** on this repo (130 files), **1618 ms** at 200 files and **5359 ms** at 1000 --
    11x-36x over the 150 ms per-edit budget at every size. It is not viable and no tuning saves it.
    A session-start index costs **1.4-4.8 s ONCE** (130 / 200 / 1000 files) and then makes each edit a
    parse of the EDITED FILE plus hashtable lookups: **p50 5.3 ms at 200 files and 3.9 ms at 1000**.
    The structural point: per-edit cost is O(edited file), NOT O(repo) -- it does not grow with the
    workspace. The one-off index build fits the 000101 session-start seam exactly, which already pays a
    survey-measured ~6.3 s (pwsh) / ~11.7 s (5.1) installed-modules snapshot on a background runspace
    off the critical path; 4.8 s at 1000 files sits inside that established budget.
  - **The one measured caveat, recorded rather than smoothed:** on this repo the per-edit p50 is
    **212 ms** -- over budget -- because the survey deliberately picked the WORST file in the tree
    (`scripts/lib/lsp-common.ps1`, 2655 lines / 88 functions) and re-parsing it dominates. The fix is
    named and cheap: the daemon ALREADY parses the edited file for `moduleAwareness`
    (`Get-ModuleAwarenessFindings`), so the reference pass must SHARE that parse rather than add a
    second one. Budget-met is a design constraint on the build, not an open question.
  - **Ambiguity ledger, every entry resolving to SILENCE** (the 000101 rung discipline, reused
    verbatim): dynamic invocation (`& $name` -- `GetCommandName()` returns `$null`); a dynamic
    dot-source (`. $path`) or any include that does not resolve to a readable, parseable file
    (suppress the file); string-built names; duplicate definitions of one name across files (a
    "referenced by N" that cannot say WHICH definition is referenced is not a fact); and a splatted or
    computed call target. A missing count costs nothing; a WRONG count teaches the user to distrust
    every count.
  - **Shape: BARE FACTS, no new plugin-owned diagnostic code** (000127 OQ1, decided). `owned_count`
    stays **5**; `rulesets/rule-rationales.psd1` and its generator are untouched. All five existing
    owned codes name something WRONG that the user should fix; "referenced by 3 files" names nothing
    wrong -- there is no defect and no fix. A diagnostic code carries an implicit "change this", and
    the rationale layer those codes now attract (000121/000124/000125) answers "why does this rule
    matter" -- a question a fact does not have; satisfying the coverage guard would mean fabricating a
    rationale for a non-rule. The right shape is the one the tree already uses for non-defect signal:
    a distinct labelled section on the existing `additionalContext` channel, as `Project
    intelligence:` (000062) and `Correction check:` (000061) already do. No new status token.
  - **NAMED STOP (the reason this is blocked, verified this session, not asserted):** the build needs a
    `referenceSurfacing` userConfig knob, and `CONTRACT.md` section 1.1 freezes the knob-name SET
    drift-guarded to equal `.claude-plugin/plugin.json` **exactly**. Adding the knob to the manifest
    was PROVEN to turn BOTH the CONTRACT guard and the README guard RED (run this session, then
    reverted; the guards were re-run green afterwards). So the knob cannot ship without a
    `CONTRACT.md` FROZEN-KNOBS amendment -- which every prior knob got as a deliberate, documented
    MINOR (`formatOnEdit`/000059, `ruleset`/000087, `moduleAwareness`/000101, `nativeServe`/000103).
    That amendment is a frozen-surface decision reserved to Mike, and 000127 ran unattended under
    NIGHT_PROTOCOL, which names a CONTRACT need as a stop. **Nothing was built; nothing was worked
    around.** Output when unblocked: MINOR + a dedicated opt-in enum knob + the CONTRACT amendment.
- **N1.3 Graph-facts surfacing (#6 core).** Reference count / is-exported / called-from-N as facts, the
  score dropped. Folded into the N1.2 survey above (000127 leg 1) and blocked with it on the same
  single CONTRACT decision.
- **N1.4 Quality-wave curation.** Exclude-only curation and config-tuning of the kept base rules, the
  same discipline as v1.21.1; cut a rule only when `review-dogfood.ps1` over accrued genuine captures
  ranks it net-noise. The clock is real usage (Section 5). Output: PATCH.
- **N1.5 Closed-loop latency benchmark -- BUILT, HELD in PR (000127 leg 3).** Turns the 000061
  correction loop's structural latency claim into a measured median + p95 alongside the warm-hook
  baseline, from a rerunnable on-demand harness (`tests/bench/Invoke-LatencyBench.ps1`, reusing the
  000040 `tests/bench/` primitives -- which is where the placement question was already answered on
  disk). Cold start is excluded and said so; the harness verifies the lifecycle signal ACTUALLY fired
  rather than timing a plain warm turn and labelling it a closed loop. Numbers + method live in
  `docs/benchmarks.md`. Not CI-wired, deliberately: a single-machine number is indicative, not a
  regression gate (`tests/PowerShellLsp.Benchmark.Tests.ps1` still owns the guarded thresholds).
  See the HELD subsection below -- not merged.
- **N1.6 Project-intelligence slice 2 -- SURVEYED (000127 leg 4); verdict BUILD (qualified), oracle
  first.** The survey ranked three candidates by measured FP on a known-good oracle (the machine's 72
  installed, shipping, working module manifests) rather than by architectural taste -- and the
  measurement overturned the prior:
  - **Ranked first: `AliasesToExport` orphan** -- a name in `AliasesToExport` with no matching alias
    definition. It is the residual the SHIPPED code names itself (`Test-ManifestConsistency` in
    lsp-common.ps1 records "Only FunctionsToExport is checked in slice 1; CmdletsToExport and
    AliasesToExport are recorded but not cross-referenced"), it is exactly symmetric with the
    orphan-export check slice 1 already ships, and the machinery exists
    (`Get-AliasDefinitionNameFromCommand` + the degrade ladder).
  - **The measurement, and the correction it forced:** a naive root-module-only implementation fired on
    **2 of 5** alias-declaring modules (40%). Both hits were FALSE POSITIVES *of the probe*, and each
    named a REQUIRED degrade rung: Pester defines its aliases through an indirection
    (`& $SafeCommands['Set-Alias'] ...`, so `GetCommandName()` is `$null` -- the 000101 rung-0
    predicate already silences this), and BurntToast manages alias export via
    `Export-ModuleMember -Alias`. So the 2 hits are the candidate's REQUIREMENTS SPEC, not evidence
    against it.
  - **FP-measurement path (named, and the reason this is "qualified"):** this box offers only **5**
    alias-declaring script-rooted modules -- far too small a denominator for the 0%-FP bar this project
    holds itself to (000091 measured on 34, 000126 on 44). The path is: enlarge the module oracle to a
    defensible denominator (a pinned, offline-able snapshot of top PSGallery modules), implement the
    two rungs the measurement named plus nested-module and dot-source degrades, then require 0% FP with
    every hit triaged by hand. **Do not build this slice until the oracle exists** -- otherwise the
    0%-FP claim is unmeasurable, which is precisely the trap the 000124 N1.1 survey caught.
  - Deferred behind it: nested-module consistency (medium value, more machinery); `RequiredModules`
    vs project reality (FP-hostile -- a module legitimately required for types/formats/side effects is
    referenced by no `CommandAst`, and the probe's 0% rests on a denominator of **1**, which settles
    nothing). Output when built: MINOR.

### Horizon 2 -- Enterprise hardening (parallel track; adoption-gating)

- **E2.1 SARIF / CI deepening -- LARGELY CLOSED; the remainder is HELD in PR (000127 leg 5).** This
  item was written as "SARIF upload to code scanning **plus an exit-code policy gate**". Half of it was
  already shipped and the roadmap did not know: **the exit-code policy gate has existed since v1.19.0 /
  000057** as `lsp-scan.ps1 -FailOn none|note|warning|error` (default `none` never gates; exit 2 when a
  finding is at or above the threshold) -- verified-from-disk this session in the script, the README,
  and the CHANGELOG's v1.19.0 entry. What was genuinely missing, and is what 000127 leg 5 built: (a) an
  exit-code MATRIX pinning that policy (it had none, so it could drift silently) plus a wiring test
  proving the CLI flag reaches the exit code; (b) the code-scanning UPLOAD itself
  (`.github/workflows/powershell-lsp-code-scanning.yml`) -- a separate workflow, inert until merged (no
  `pull_request` trigger), `upload-sarif` pinned by commit SHA because it is the only step in the
  repository holding `security-events: write`, scanning `scripts/` rather than the root because
  `tests/corpus/samples/` is deliberately-bad code by construction. See the HELD subsection below --
  not merged. Output: **not the MINOR this item assumed** -- see leg 8's NO-BUMP reasoning; the gate
  it named was already released, and a repo-CI workflow is not a user-visible capability.
- **E2.2 Org policy config.** Centrally-managed ruleset / settings precedence, extending the `ruleset`
  knob under the existing knob doctrine. Output: MINOR + a `CONTRACT.md` amendment.
- **E2.3 Catalog listing.** Get into `anthropics/claude-plugins-community` (and the official catalog if
  it qualifies). Mike-gated. Output: no code.
- **E2.4 Bus-factor mitigation.** The single-maintainer risk is the real enterprise blocker; the
  CONTINUITY plan exists (000048), and the mitigation is a documented governance / key-custody path and
  ideally a second maintainer. Output: docs / governance.
- **E2.5 Rule-rationale as an audit surface -- LIVE.** I0.1 shipped in v1.24.0, so this framing is no
  longer prospective: every surfaced finding already carries a "why" that is generated, not asserted --
  traceable to the pinned analyzer's own metadata and regenerable under `-Check`. No extra build; the
  enterprise framing is now a claim the tree supports.

### Horizon 3 -- Strategic / what-if (the bets; not committed work)

- **S3.1 Retire the native-nav workaround.** Upstream-gated, monitor-only. When the
  `anthropics/claude-plugins-official#1359` (OPEN) client fix lands, `doctor.ps1 -ProbeNativeServe`
  flips to removable and a PATCH drops the shim default; when `anthropics/claude-code#73961` (OPEN)
  lands, the Windows known-issue note clears.
- **S3.2 Positioning held firm (guardrail).** Concede the editor; own headless + in-loop + AI-era
  correctness. Do NOT adopt the "AI Intelligence Layer" / "Architect" identity -- it is unfalsifiable,
  it spends the earned credibility, and it licenses scope creep. This guardrail governs which what-ifs
  move up.
- **S3.3 Agent-layer memory -- deliberately out of plugin scope.** Repository memory (#4),
  learn-team-style (#10), and risk scoring (#6 as a score) introduce persistent / learned /
  unfalsifiable state; if ever wanted they belong in the agent's memory layer consuming the plugin's
  deterministic signal, never in the plugin. Recorded, not backlog.
- **S3.4 Deferred rules.** `PSUseCompatibleCommands` / `PSUseCompatibleTypes` and the
  angle-bracket-placeholder check re-enter only as a MINOR at a proven 0% false-positive rate on the
  widened corpus; the 000096 pre-PSSA AST pass is the mechanism.
- **S3.5 Runtime intelligence, full (#7).** Runtime execution capture is a different architecture with
  real privacy / scope questions; the static slice (`moduleAwareness`) is the committed extent, and the
  runtime version is a deliberate leave.

### How each step lands

Every H0-H2 build entry becomes a survey-first dispatch pair under the existing flow: author ->
accept -> CC executes in a worktree -> Mike holds all gates. Ground truth (the live `dispatch list`,
the log, file inspection) stays authoritative over this roadmap.

## 5. Paced by the dogfood log (cannot compress)

The capture engine (000039) and the annotation/review tool (000043) are shipped. 000066 confirmed the
hook is path-transparent and the live 0-of-N genuine-repo-path count is an exercise gap, not a defect.
The quality wave has produced its first shipped output: 000084 and 000090 seeded genuine-repo captures
(the `pses-default` surface, then the broadened `base` surface), 000091 ranked the base surface for
false-positive / noise over the known-good corpus, and 000092 applied that verdict as the EXCLUDE-ONLY
base curation shipped in v1.21.1 (57 -> 54 rules). The remaining wave -- deeper curation, config-tuning
of the kept rules, and fix-suggestion quality -- still follows real interactive captures: the unblock
stays behavioral (dogfood normal edits of the canonical checkout, then re-run the classifier), gated on
real usage, not machinery.

## 6. Standing items (Mike-gated)

- **Launch -- done.** The r/PowerShell and r/ClaudeCode launch posts are live (2026-07-05); the in-repo
  launch draft (docs/launch/reddit-powershell.md) merged via plugin PR #77 (000112). No longer pending,
  no longer horizon.
- **Upstream posting -- filed; only an optional follow-up remains.** Posted / filed: the Windows
  launcher guard is filed as anthropics/claude-code#73961 (OPEN); the Claude Code config-panel renderer
  bug surveyed under 000109 (its manifest-side mitigation -- the description cap + configuration.md --
  shipped in v1.23.1) is filed as anthropics/claude-code#74289 (OPEN); and our refreshed comment on
  anthropics/claude-plugins-official#1359 is posted (2026-07-05, the issue itself stays OPEN). Posted
  (2026-07-06): the registrar-field-drop report was filed as a rewrite of anthropics/claude-code#66987
  (OPEN), re-confirmed on Claude Code 2.1.201; the corrected LSP-registration record -- and the
  post-ready, still-unposted follow-up comment -- both live internally in
  docs/upstream/claude-code-lsp-registration.md. The PSES rename-capability fix (issue #2297) was
  submitted as PR #2299 and is now CLOSED unmerged (2026-06-11, verified live) -- settled, no longer a
  pending post; the on-disk notes that still call it "not submitted" / "open"
  (docs/upstream/pses-2297-pr.md, sitting-closeout.md) are superseded.
- **Pester 6 -- deferred, deliberately.** Pester 6.0.0 went GA on the PowerShell Gallery 2026-07-07.
  The test bootstrap is pinned to the 5.x major (000120 leg 1) rather than upgraded, because there is
  no forcing function and a breaking new major should be absorbed by a decision, not by runner-image
  luck; the guard test makes silently unbounding the pin go RED. Pester 6's parallel-execution model
  has not been evaluated against the daemon-backed integration tests, which is the first thing an
  upgrade slice would have to establish. Revisit when a forcing function appears. No dispatch open.
- **gitsign tag-verify caveat (unchanged).** Release tags are gitsign-signed (keyless, Rekor-logged); a
  plain `git verify-tag` cannot read the x509 / gitsign signature and reports the Fulcio certificate as
  expired -- normal for keyless, where the short-lived cert is not the proof, the Rekor entry is.
  `gitsign verify` or `gh attestation verify` is the documented path (README, docs/RELEASING.md). No fix
  dispatch open; optional.

## 7. Operating posture (unchanged)

Fast on a gated path; the gate is fast, not removed. Human gates: accept, merge, F2 verified flip, tag,
and the product / positioning / sequencing calls. Within an accepted dispatch's scope, CC decides
implementation, design, and ripeness. Ground truth (live `dispatch list`, the log, file inspection)
wins over any doc, including this one -- the log is authoritative.
