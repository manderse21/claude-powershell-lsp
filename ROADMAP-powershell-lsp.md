# claude-powershell-lsp -- Roadmap

Status as of 2026-07-09. Plugin on main: v1.24.0, GPL-3.0-or-later (both manifests + the latest
CHANGELOG release heading at 1.24.0). The version is TAGGED, gitsign-signed, provenance-attested,
and RELEASED: an annotated, gitsign-signed tag v1.24.0 -- cut from the release runner by
`github-actions[bot]` under the gated `workflow_dispatch` pipeline -- sits at commit 05c6182 on
origin (the #82 merge), `git describe --tags` returns v1.24.0, the v1.24.0 GitHub Release is
published as Latest (2026-07-09), and the served marketplace listing resolves to 1.24.0 (Gate 5's
tree-vs-published parity guard held at cut time). The old publish gap (the registry once served a
stale 1.3.0) stays CLOSED.

Provenance: every version, feature, and dispatch claim below is verified against live state THIS
session -- `dispatch list --project powershell-lsp`, the dispatch log, `git log origin/main`, `git
describe --tags`, the git tags + GitHub Releases, the CHANGELOG, and the plugin/marketplace
manifests. Upstream issue/PR identifiers are confirmed against the in-repo citations under
docs/upstream/ and the README AND re-checked against live GitHub this session, because two on-disk
upstream notes had gone stale (the PSES PR #2299 state and the docs/upstream/sitting-closeout.md
ledger); where a doc and live GitHub disagreed, live won.

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

Earlier arc (v1.5.x through v1.17.0 -- launch-readiness, licensing MIT -> GPLv3, reliability /
auto-relaunch, doctor self-check, dogfood capture + review tooling, the CI proof-framework, the
enterprise trust-surface + measured-0%-FP corpus, community-release readiness, and release-engineering
automation with SBOM + provenance) is in CHANGELOG.md and the 000001-000067 log -- all merged,
F2-verified, and tagged where a version moved. CHANGELOG.md is authoritative for that older band; it
is not re-transcribed per-version here.

## 3. Release process -- hardened (the gate is structural, not convention)

The release path is enforced on three layers, all shipped, and every release from v1.19.0 through the
current v1.24.0 was cut end-to-end by it:

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
path to main. v1.19.0 was the first release cut under all three; v1.24.0 is the latest.

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
| 8 | Teach PS idioms | STRONGEST fit | new rule-pack idiom slices -> N1.1 |
| 9 | Explain why a rule exists | SHIPPED | rule-rationale strings, v1.24.0; one-entry residual -> I0.1 |
| 10 | Learn from accepted fixes | SPLIT | closed-loop primitive shipped (v1.19.0); learn-team-style resisted -> S3.3 |

### Horizon 0 -- Immediate tactical (unblocked now; gated only on accept)

- **I0.1 Rule-rationale strings (#9) -- SHIPPED (v1.24.0 / 000121).** Delivered as a MINOR and, as
  planned, with no new knob; the `CONTRACT.md` amendment anticipated here turned out to be unnecessary,
  because additive prose on an existing channel leaves the frozen Tier-1 surface (knob names, status
  tokens, and the "a clean pass adds nothing" property) untouched. The ship detail is in Section 2.
  **Residual (the only I0.1 work left):** the plugin's fifth owned code, `ManifestConsistency`, has no
  entry in `rulesets/rule-rationales.psd1` and rides the graceful-degrade path -- its finding surfaces
  with no rationale line, never fabricated, never blocking. A future micro-slice hand-authors that
  single entry in `scripts/regen-rule-rationales.ps1` and regenerates the table under `-Check`.
  Output: PATCH.
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

- **N1.1 Idiom rule-pack slices (#8; #5 as flagging).** Re-open the AI-era rule-pack pattern -- closed
  at v1.22.0 -- with additive idiom rules (ShouldProcess, `Write-Host` -> `Write-Information`,
  `ThrowTerminatingError`), survey-first, exclude-noisy, a measured 0% false-positive rate proven per
  slice. The plugin flags; the agent transforms. A deliberate re-open of the v1.22.0 closure with new
  slices. Output: MINOR per slice.
- **N1.2 Cross-file reference surfacing (#2 / #3).** A deterministic "referenced by N files" signal via
  the diagnostic channel -- NOT the gated native-nav path -- strengthening the headless story. Output:
  MINOR + a dedicated opt-in enum knob.
- **N1.3 Graph-facts surfacing (#6 core).** Reference count / is-exported / called-from-N as facts, the
  score dropped. Folds into the N1.2 survey.
- **N1.4 Quality-wave curation.** Exclude-only curation and config-tuning of the kept base rules, the
  same discipline as v1.21.1; cut a rule only when `review-dogfood.ps1` over accrued genuine captures
  ranks it net-noise. The clock is real usage (Section 5). Output: PATCH.
- **N1.5 Closed-loop latency benchmark.** Turn the 000061 correction loop's structural latency claim
  into a measured number; it needs a fresh baseline (the PL-2 / 000054 benchmark is `abandoned`,
  verified live). Output: docs + a harness.
- **N1.6 Project-intelligence slice 2.** The next deterministic manifest / cross-file slice beyond the
  v1.19.0 slice 1, scoped to feeding signal. Survey -> build. Output: MINOR.

### Horizon 2 -- Enterprise hardening (parallel track; adoption-gating)

- **E2.1 SARIF / CI deepening.** SARIF upload to GitHub code scanning plus an exit-code policy gate,
  building on the v1.19.0 standalone scan mode. Output: MINOR.
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
