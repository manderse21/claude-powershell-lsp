# claude-powershell-lsp -- Roadmap

Status as of 2026-07-22. Plugin on main: **v1.26.0**, GPL-3.0-or-later. **A v1.27.0 cut is staged
but UNMERGED and UNRELEASED** (dispatch 000142): both manifests read 1.27.0 on the
`dispatch/000142-org-policy` branch behind an open PR, with a dated `## [1.27.0] - 2026-07-22`
CHANGELOG heading over one MINOR entry (E2.2 org policy) and two PATCH entries (N1.1 slice 2, and
000143's release-docs correction). Nothing about that cut is tagged, released, or merged -- merging
the PR and triggering the release pipeline are Mike's gates. Everything below about v1.26.0 remains
the state of `origin/main`. The v1.26.0 version is TAGGED,
gitsign-signed, and RELEASED (verified-from-web this session): an annotated, gitsign-signed tag
v1.26.0 sits at commit 22bec89 on origin (tag object c26e580, tagged by `github-actions[bot]` from
the release runner), `git describe --tags origin/main` returns `v1.26.0` exactly -- the tip IS the
tagged commit -- and the v1.26.0 GitHub Release is published as the current **Latest**
(2026-07-22T12:06:42Z; `gh api repos/manderse21/claude-powershell-lsp/releases/latest` returns
v1.26.0, draft=false, prerelease=false). The old publish gap (the registry once served a stale
1.3.0) stays CLOSED.

**The cut was made by the PIPELINE, not by hand** (verified-from-web, and the distinction is the
whole point of Section 3): the tag's Sigstore certificate names
`.github/workflows/powershell-lsp-release.yml@refs/heads/main` as its build signer on a
`workflow_dispatch` trigger (release run **29918156282**), and both published assets --
`powershell-lsp-1.26.0.tar.gz` and `powershell-lsp-1.26.0.cdx.json` -- pass `gh attestation verify`
(exit 0) against SLSA build provenance issued by that same workflow over source digest 22bec89.
Both push workflows are GREEN on that exact tip, headSha-matched per rule 000081: CI run
**29882589709** and code-scanning run **29882589757**.

**v1.25.1 is SUPERSEDED** (verified-from-web): it is still tagged (tag object f92ff79 over commit
c9692ca) and its GitHub Release is still published (2026-07-19T00:41:38Z), but it no longer carries
the current-release badge -- `gh release list` marks exactly one Latest, and that is now v1.26.0.

The whole **v1.24.x band is closed out**: v1.24.0 through v1.24.3 are each tagged on origin and
published as GitHub Releases (verified-from-web: `git ls-remote --tags origin` lists v1.24.0-v1.24.3
beside v1.25.0, v1.25.1 and v1.26.0). Neither v1.25.0 nor any of the v1.24.x band holds the
current-release badge.

**The Wave-1 + cut cycle is CLOSED.** 000136 / 000137 / 000139 merged (PRs #93 / #94 / #95), 000141
cut v1.26.0 and trued this roadmap (PR #97, merge commit 22bec89), the pipeline tagged and published
the release, and 000143 swept the post-release residuals -- including this true-up. Nothing about
the v1.26.0 cycle is outstanding.

Provenance: every version, feature, and dispatch claim below is verified against live state THIS
session -- `dispatch list --project powershell-lsp`, the dispatch log, `git log origin/main`, `git
describe --tags`, `git ls-remote --tags origin`, `gh release list`, `gh run list`, the CHANGELOG,
and the plugin/marketplace manifests. **Each status claim here is labelled verified-from-disk (read
out of this tree), verified-from-web (resolved live against origin / GitHub at run time), or
inferred (reasoned, not observed).** Tag and release state is NEVER copied from memory or from a
prior roadmap revision: it is resolved live, because that is exactly the claim that goes stale
fastest, and it has now gone stale THREE times in five days. The 000127 leg-7 revision recorded
v1.24.3 as the then-current release, accurate at write time and stale the moment v1.25.0 published
on 2026-07-17; the 000134 leg-2 revision then recorded v1.25.1 as "PENDING, not released ... no
`v1.25.1` tag exists on origin", accurate at write time and stale the moment v1.25.1 was tagged and
published on 2026-07-19; and the 000141 leg-2 revision recorded v1.26.0 as "PENDING, not released",
accurate at write time and stale the moment the pipeline tagged and published it on 2026-07-22. All
three were corrected by re-resolving against origin, not by editing around the old text.

That third instance is what dispatch 000143 exists to close, and it carries a lesson the first two
did not surface. The 000141 leg-2 verify check derived every pin from a live artifact -- which is
the right instinct -- but a live-derived check still has an **epoch**. Written during the
cut-to-release window it asserted "the roadmap names the staged version as not-yet-released"; run
after the release it demanded the opposite of what it demanded at authoring time, and reported
MISMATCH against a roadmap that was merely out of date rather than wrong-at-write-time. A
version-agnostic check is not automatically time-agnostic. The fix applied in 000143 is an explicit
epoch branch (released-version == manifest-version selects the post-release assertions), plus this
true-up -- the document was brought to ground truth, and the check was NOT loosened to accept the
stale text.

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
| v1.27.0 | 000142 legs 1-2 + 000143; cut by 000142 leg 5 | MINOR -- **STAGED, NOT RELEASED.** Both manifests read 1.27.0 on the `dispatch/000142-org-policy` branch behind an open PR; there is **no v1.27.0 tag and no GitHub Release**, and merging plus triggering the pipeline are Mike's gates (this row exists so the ledger does not silently omit a staged cut -- it is NOT a claim of release). Classification is highest-wins over the live `[Unreleased]` entries: 000142 leg 1's MINOR governs a cut whose other two entries are PATCH. **000142 leg 1 (MINOR)** ships E2.2 org policy as the `orgPolicy` knob -- an absolute path to a central `PSScriptAnalyzerSettings.psd1` whose `ExcludeRules` are ENFORCED as a final subtractive drop at both `scripts/lsp-client.ps1` surface points, before the hook emit and the dogfood capture, so one rule covers the live surface, the capture, and the SARIF scan. Org wins the exclude path (no local include can re-enable a dropped rule); repo-local wins the include path (the policy's own `IncludeRules` stay advisory). Fails open with exactly one logged warning on a missing / unreadable / unparseable / relative path, and the policy is read through `Import-PowerShellDataFile` (restricted, data-only) so it can never execute code. Knobs **18 -> 19** with one `CONTRACT.md` FROZEN-KNOBS row proven RED-then-GREEN against the set-equality guard; no `base.psd1` change (still 53), no new owned finder (still 6), no status token. Off is byte-identical, proven over the shipped corpus records. **000142 leg 2 (PATCH)** is N1.1 idiom-guidance slice 2: hand-authored rationale overrides on the five PSES-15 default-surface rules whose derived text was circular or pure mechanism, each proven to already fire by the derived corpus snapshots; `override_count` **4 -> 9**, `-Check` green at pin 1.25.0. **000143 (PATCH, docs)** documents release Gate 5 and corrects the tag-command convention. Cut lockstep to 1.27.0 in both manifests + a dated `## [1.27.0] - 2026-07-22` CHANGELOG heading |
| v1.26.0 | 000139 / 000137 / 000136; cut by 000141 leg 1 | MINOR -- **the Wave-1 band**, RELEASED 2026-07-22. Classification is highest-wins over the live `[Unreleased]` entries, so 000139's MINOR governs a cut whose other two entries are PATCH. **000139 (MINOR)** adds the plugin-owned pre-PSSA finder `CommandLinePlaceholder` (`Find-CommandLinePlaceholder` in `scripts/lib/lsp-common.ps1`, wired at the `scripts/lsp-client.ps1` seam): a literal `<Name>` left on a command line is schema-valid to the eye but a redirection-operator parse error at run time. Detection is token-level -- the reserved `<` input-redirection operator immediately abutting a bareword ending in `>` -- and deliberately precision-first: legitimate output redirection (`>`, `>>`, `2>&1`), angle brackets inside strings / here-strings / comments, C#-style generics in strings, and the word operators `-lt` / `-gt` never fire. Re-entered under the S3.4 measure-first bar and shipped only at a measured **0% false-positive rate on a 281-file oracle** (150 repo scripts + 131 installed-module scripts, zero hits). Owned finders **5 -> 6** (verified-from-disk: `rule-rationales.psd1` `owned_count` = 6); no new knob (still 18), no `base.psd1` change (still 53), no CONTRACT change. **000137 (PATCH)** adds `docs/trust.md`, assembling in one evaluator-facing place the release-integrity chain that was already true but scattered (keyless gitsign-signed tag + SLSA provenance over both release assets, CycloneDX SBOM generated from the real pins, the pinned and SHA-256-verified PSScriptAnalyzer, the 0% corpus FP bar guarded on every CI run, measured latency, the SHA-pinned code-scanning workflow, the generated rule rationales), plus a README pointer. **000136 (PATCH)** adds `docs/CONTINUITY.md` (per-surface failure/recovery if the sole maintainer disappears) and `MAINTAINERS.md` (second-maintainer on-ramp), and reconciles the docs so the release runbook lives in exactly one place (`docs/RELEASING.md`). Cut lockstep to 1.26.0 in both manifests + a dated CHANGELOG heading. Tag v1.26.0 gitsign-signed and cut BY THE PIPELINE (tag object c26e580 -> commit 22bec89, tagger `github-actions[bot]`, build signer `powershell-lsp-release.yml@refs/heads/main`, run 29918156282); GitHub Release published as the current **Latest** (2026-07-22T12:06:42Z, verified-from-web), with both assets SLSA-attested and `gh attestation verify`-clean at exit 0 |
| v1.25.1 | 000131 / 000132 / 000133; cut by 000134 leg 1 | PATCH -- the scan-robustness lineage. 000131 NAMES the file(s) an INCOMPLETE (exit 4) code-scanning scan could not analyze (SARIF `toolExecutionNotification` + stderr + workflow annotation; per-file budgets left unchanged). 000132 fixes an INCOMPLETE-scan correctness gap (a client-cap-KILLED file was passing as clean; now recorded NOT analyzed via the 000024 never-silent branch) and its measurement corrects the true per-file budget a THIRD time -- to the daemon's OWN settle cap `MaxWaitMs` (default 5000 ms), not the client `timeoutMs`. 000133 raises the SCAN daemon's `MaxWaitMs` 5000 -> 15000 (scan-only; the in-agent daemon keeps 5000; INTERNAL, no knob, no CONTRACT change), and main's own code-scanning flipped RED -> GREEN at the #91 merge. All three self-describe PATCH; no knob, detection, ruleset, rationale, or CONTRACT surface moved. Cut lockstep to 1.25.1 in both manifests + a dated CHANGELOG heading. Tag v1.25.1 gitsign-signed (tag object f92ff79 -> commit c9692ca, tagged by `github-actions[bot]` from the release runner); GitHub Release published 2026-07-19T00:41:38Z (verified-from-web), no longer the current release (superseded by v1.26.0). Full narrative in "Scan-robustness lineage" below |
| v1.25.0 | 000128 (survey 000127 leg 1) | MINOR -- **reference surfacing**: a new off-by-default `userConfig` knob `referenceSurfacing`, the **18th** knob (verified-from-disk: `plugin.json` declares 18 `userConfig` keys), surfaces BARE per-function facts (referenced-by-N, exported, defined-in) from a session workspace index the daemon builds ONCE, as additive Information on the existing `additionalContext` channel -- no new diagnostic code, no status token, `rulesets/rule-rationales.psd1` byte-for-byte unchanged, and the diagnostics surface byte-identical when `off` (the default). It ships the design 000127 leg 1 surveyed-and-BLOCKED on a frozen-knob CONTRACT decision, so 000128 carried that amendment in lockstep (manifest + `CONTRACT.md` + `README.md`; the 000087/000101 knob precedent). The same release also lands the **`AliasesToExport` orphan check** on the always-on `ManifestConsistency` finder (PL-6 slice 2: a name in `AliasesToExport` with no matching alias definition) -- the symmetric completion of slice 1's export check. Tag v1.25.0 gitsign-signed; GitHub Release published 2026-07-17T18:06:13Z (verified-from-web), no longer the current release (superseded by v1.25.1) |
| v1.24.3 | 000126 (ranking 000125 leg 3) | PATCH -- **base-ruleset curation slice 2, and the slice that CLOSES curation**. `PSUseOutputTypeCorrectly` was the sole rule of the base-54 still firing on the 44-file known-good oracle (2 pedantic Information hits, 0 own-source hits, base-only -- not in the PSES-15 set), so excluding it via the existing named `$BaseRuleExclusions` list takes base **54 -> 53** and makes the ENTIRE opt-in `base` surface **0% measured false-positive** on that oracle. `pses-default` is byte-for-byte unchanged; `rulesets/base.psd1` REGENERATED through `scripts/regen-base-ruleset.ps1` (never hand-edited) and the rationale table regenerated to `pssa_count` 53 with all four 000125 overrides intact. With a 0% measured FP rate there is no evidence for a further exclude slice, so **base curation is COMPLETE** and 000126 deliberately recorded `next_suggested: null`. Tag v1.24.3 gitsign-signed; GitHub Release published 2026-07-17 (verified-from-web), no longer the current release (superseded by v1.25.0) |
| v1.24.2 | 000125 leg 1 (N1.1 slice 1) | PATCH -- **the rule-rationale OVERRIDE layer**: four idiom-family codes (`PSShouldProcess`, `PSUseSupportsShouldProcess`, `PSAvoidUsingWriteHost`, `PSAvoidShouldContinueWithoutForce`) now render hand-authored why+fix guidance instead of the weak text auto-derived from PSScriptAnalyzer's own CommonName + Description, which for idiom rules is circular (the "why" restates the rule name) or pure mechanism (it describes the checker, not the idiom, and offers no fix). The layer records each override's PRE-override `derived` text so a pin bump that changes the replaced text goes RED rather than being silently masked by the override -- drift-visible by construction. This is **N1.1 slice 1**: guidance quality on rules that already fire, not new detection. Tag v1.24.2 gitsign-signed; GitHub Release published (verified-from-web) |
| v1.24.1 | 000124 | PATCH -- **rule-rationale coverage CLOSED**: the plugin's fifth owned code, `ManifestConsistency`, gained its hand-authored rationale. v1.24.0 shipped the feature with a recorded gap -- four of five owned finders had an entry and `ManifestConsistency` rode the graceful-degrade path with none, surfacing its finding with no `why:` line. Hand-authored through `scripts/regen-rule-rationales.ps1` and the table regenerated (never hand-edited). The 000124 survey also corrected the N1.1 premise: no NEW-detection idiom slice clears a 0%-measured-FP bar, which is what re-scoped N1.1 to guidance quality and produced v1.24.2. Tag v1.24.1 gitsign-signed; GitHub Release published (verified-from-web) |
| v1.24.0 | 000121 (survey 000120 leg 2) | MINOR -- **rule-rationale strings** (feedback #9; horizon item I0.1). Every surfaced rule now carries a short static "why this rule matters" line on the EXISTING `additionalContext` channel, so a finding arrives with the reasoning attached, not just the verdict. The table `rulesets/rule-rationales.psd1` is HYBRID and GENERATED, never hand-edited: 58 entries = the 54 rationales for the `rulesets/base.psd1` PSScriptAnalyzer surface, auto-derived offline from the vendored pinned PSScriptAnalyzer 1.25.0 (`CommonName` + a whole-sentence `Description` prefix, 180-char budget, cut at a word boundary), plus 4 hand-authored entries for the plugin-owned finders PSScriptAnalyzer knows nothing about (`BashIsm`, `ModuleNotInstalled`, `NonAsciiChar`, `PS7OnlySyntax`). `scripts/regen-rule-rationales.ps1` writes it and its `-Check` drift guard re-derives and diffs it (exit 0 match / 1 drift), mirroring `regen-base-ruleset.ps1`; a pin-coupled unit guard goes RED unless a pin bump or a base-ruleset edit regenerates the table in the same reviewed diff. Rendering is deduplicated per RULE, not per finding -- a rule firing eight times in a file renders its rationale once -- bounding the added context to roughly (distinct rules in the file) x 180 chars. Two properties hold by construction: a clean file still emits NOTHING (byte-identical, integration-proven), and a rule with no entry degrades gracefully, surfaced with no rationale line, never fabricated. NO knob, NO `CONTRACT.md` change, NO new status token, and NO change to which rules run. Tag v1.24.0 gitsign-signed, provenance-attested; GitHub Release published 2026-07-09 (no longer current) |
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

### Wave-1 merge outcomes (000136 / 000137 / 000139) plus the 000141 cut -- the whole cycle on main

The three Wave-1 dispatches merged to main in dependency order on 2026-07-21, and the 000141 cut
train merged behind them on 2026-07-22 (all verified-from-web via `gh pr list --state merged`):

| PR | Dispatch | Merge commit | Merged (UTC) |
|---|---|---|---|
| #93 | 000136 continuity + governance docs | `fbb857c` | 2026-07-21T13:30:47Z |
| #94 | 000137 docs/trust.md | `303c714` | 2026-07-21T14:02:30Z |
| #95 | 000139 CommandLinePlaceholder finder (MINOR) | `771866c` | 2026-07-21T15:34:55Z |
| #97 | 000141 v1.26.0 lockstep cut + roadmap true-up | `22bec89` | 2026-07-22T01:15:10Z |

`22bec89` is the current origin/main tip AND the commit the v1.26.0 tag points at, so `git describe
--tags origin/main` returns a bare `v1.26.0` with no commit offset (verified-from-web). Both push
workflows are GREEN on that exact tip, headSha-matched per rule 000081: CI run **29882589709** and
code-scanning run **29882589757**. No plugin PR is open (verified-from-web).

**PR #95 carried two post-completion test-fix commits for a real Windows PowerShell 5.1 divergence**
(`f0d604c`, `1982f32`). On PS 5.1 a scalar `PSCustomObject` and `$null` both return `$null` from
`.Count` -- the member does not exist on a scalar and strict mode does not save you -- so a counted
expression must be wrapped in `@()` before `.Count` is read. The `windows-powershell` CI leg failed
twice on this, at `4f17c43` (run 29837521908) and again at `f0d604c` (run 29840467411), with the
signature `Expected 1, but got $null.` **Only the test assertions were affected: the finder itself
detects correctly on 5.1**, which is why the fix is confined to `tests/PowerShellLsp.Unit.Tests.ps1`
(9 assertions wrapped, product code untouched). This is recorded as a rule observation in the 000141
outbox -- the two independent CI failures are its second observation.

### Scan-robustness lineage (000129-000133) -- the blocked pair, the budget chain, the flip

The persistent ubuntu-24.04 code-scanning RED on main -- an INCOMPLETE scan (exit 4), the 000024
never-silent discipline firing CORRECTLY, not a findings-induced false red -- drove a
five-dispatch lineage. It is recorded here because two of its dispatches are BLOCKED (no CHANGELOG
row of their own) and the rest shipped as v1.25.1, and because the budget it chased was
mis-identified twice before the tree settled it.

- **The refuted-premise blocked pair (000129, 000130) -- the SPEC_AMENDMENTS-A3 precedent.** Both
  were fix-forward dispatches premised on an "overloaded exit 4" that does not exist on the tree,
  and both ended `blocked` + `deviations`, never `blocked -> complete` (A3: no partial state;
  refuted work is recorded as blocked plus its deviations). **000129 (CC stop-and-record;
  verified-from-disk):** a whole-file enumeration found all six `exit` sites; BOTH `exit 4` sites
  mean INCOMPLETE and the `-FailOn` gate is `exit 2` via `Get-FailExitCode` (returns only 0 or 2)
  -- there is no second meaning on 4 to split, so the prescribed disambiguation would invent a
  distinction and leave the RED untouched. **000130 (a re-issue, refuted a SECOND way, then a human
  ruling):** its new premise -- that `CONTRACT.md` freezes an exit-code table E2.1 violated -- is
  also false; that file freezes only `userConfig` knob NAMES and the diagnostics status taxonomy (a
  grep over it for exit / sarif / code-scanning / 0-2-3-4 returns ZERO hits), so there is nothing to
  amend, and adding an exit 5 would have to move exit 2 (the inbox's own named stop). Mike Andersen
  ruled interactively (2026-07-17): block and charter, do not touch any exit-code surface -- which
  chartered 000131 for the real fix.
- **The three-budget correction chain -- a disk-governs case study.** What binds a per-file
  analysis was mis-named twice before the tree settled it. 000129 / 000130 / 000131 and 000132's
  own charter all named a CLIENT budget: first the **25000 ms** process cap (`lsp-scan.ps1
  -TimeoutMs`), then the **18000 ms** client `timeoutMs`. 000132's measurement corrected it a THIRD
  time to the actual binding cap -- the daemon's OWN settle cap **`MaxWaitMs` (default 5000 ms)** in
  `scripts/pses-daemon.ps1`, which no client budget reaches -- so raising a client budget could
  never have turned the RED green. Each step overrode the prior on evidence read from the live tree,
  not from the charter: disk governs.
- **The fix and the flip (000131 -> 000132 -> 000133; verified-from-web).** 000131 made the
  INCOMPLETE diagnosable by NAMING the unanalyzable file(s) across three surfaces, budgets
  untouched. 000132 fixed the correctness gap (a client-cap-KILLED file had passed as clean; now
  recorded NOT analyzed) and identified `MaxWaitMs` as the true cap. 000133 raised the SCAN daemon's
  `MaxWaitMs` 5000 -> 15000 (scan-only; the in-agent daemon byte-identical at 5000; INTERNAL, no
  knob, no CONTRACT change). main's own code-scanning workflow
  (`.github/workflows/powershell-lsp-code-scanning.yml`, the 000127 leg-5 upload,
  inert-until-merged by construction) then flipped RED -> GREEN at the #91 merge -- headSha matched
  per rule 000081: run **29643752601** RED at `aeeb42d` (#89), run **29657184770** RED at `73dacdb`
  (#90), run **29661464779** completed/**success** at `85fb892` (#91, the origin/main tip). The
  settle-cap fix holds on main itself, not just on a branch. These three PATCH entries shipped as
  **v1.25.1**, released 2026-07-19 (Section 2).

### The 000141 cut train -- MERGED and RELEASED; disposition closed

**Disposition resolved (verified-from-web this session):** the 000141 train merged as plugin PR
**#97** (merge commit `22bec89`, 2026-07-22T01:15:10Z), Mike then ran the release pipeline, and
v1.26.0 is the current Latest Release. At write time that train held every gate open; all of them
have since been taken, in the correct order and by the correct actor. The record of the train as it
ran: Leg 1, the v1.26.0 MINOR cut (both manifests + the dated CHANGELOG heading;
`PowerShellLsp.Release.Tests.ps1` 39/39 green on the cut tree, the version lockstep RED-proven
in-session by mutation, then restored). Leg 2: the roadmap refresh this section sat in. Leg 3: a
read-only community-catalog poll (boolean + timestamp recorded in the outbox). Leg 4: a fresh PK
bundle. No product code moved; no knob, ruleset, rationale, exit-code, budget, or CONTRACT surface
changed.

The classification was version-agnostic by construction: it reads the current version off disk,
scans the live `[Unreleased]` entry lines for their leading PATCH/MINOR/MAJOR token, and takes the
highest. Wave 1 stacked MINOR (000139) over PATCH (000137) over PATCH (000136), so the cut was
`1.25.1 -> 1.26.0`. Had `[Unreleased]` been empty the leg would have asserted the NO-BUMP invariant
instead (the 000127 leg-8 shape) -- never a bump by default.

**One process deviation is recorded here rather than smoothed over, because the runbook now turns on
it.** A `v1.26.0` tag existed on origin ahead of the release and was **deleted** so the pipeline
could cut its own (verified-from-web: a `DeleteEvent` for `refType=tag`, `ref=v1.26.0`, actor
`manderse21`, at 2026-07-22T12:03:51Z -- three seconds before the dry run). The gated pipeline then
ran clean twice: a dry run at 12:03:54Z that passed all five gates and cut nothing, and the real run
(29918156282) at 12:04:27Z that cut the gitsign-signed tag at 12:06:36Z and published the Release at
12:06:42Z. **Gate 2 -- "tag does not already exist" -- passed in both runs**, which is precisely why
the pre-existing tag had to be removed first.

Nothing shipped from the deleted tag: the published v1.26.0 tag, both assets, and their SLSA
provenance all trace to run 29918156282 under `github-actions[bot]`. But a hand tag racing the
pipeline is exactly the failure class Section 3 exists to prevent, and it was invited by
documentation that printed runnable `git tag` commands as though they were the release path -- the
000141 outbox closes with exactly such a pair. Dispatch 000143 corrected every such surface: the
pipeline cuts the tag, and printed commands survive only as an explicitly-labelled manual fallback.

### HELD in PR (000134) -- snapshot retained; disposition since resolved

**Disposition since resolved (verified-from-web this session):** the 000134 train merged as plugin
PR **#92** (merge commit `c9692ca`, 2026-07-19) and its staged cut was tagged and published --
**v1.25.1** is the current Latest Release (2026-07-19T00:41:38Z), gitsign-signed at tag object
`f92ff79` over `c9692ca`. The snapshot below is retained as the historical record of the train as it
ran; it is no longer the current held PR (that is 000141, above).

That train's legs sat on ONE plugin PR (the v1.25.1 cut + that roadmap refresh) plus its paired hub
PR; at write time nothing was merged, tagged, triggered, verified, F2-flipped, or published -- every
gate stayed Mike Andersen's, and he has since taken them. Leg 1: the v1.25.1 PATCH cut (both
manifests + the dated CHANGELOG heading; `PowerShellLsp.Release.Tests.ps1` green on the cut tree,
the version lockstep RED-proven in-session by mutation, then restored). Leg 2: that refresh. Leg 3:
a read-only community-catalog poll (boolean + timestamp recorded in the outbox). Leg 4: a fresh PK
bundle. No product code moved; no knob, ruleset, rationale, exit-code, budget, or CONTRACT surface
changed.

### HELD in PR (this dispatch, 000127) -- snapshot retained; disposition since resolved

**Disposition since resolved (verified-from-disk/web this session):** leg 1's reference-surfacing
design shipped as **v1.25.0** (000128, carrying the frozen-knob CONTRACT amendment it was blocked
on), and leg 5's code-scanning UPLOAD workflow is now on main -- it is the workflow whose RED ->
GREEN flip the scan-robustness lineage above records. The snapshot below is retained as the
historical record of the train as it ran; it is no longer the current held PR (that is 000134,
above).

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
current v1.26.0 was cut end-to-end by it (verified-from-web: the v1.24.1/v1.24.2/v1.24.3, v1.25.0,
v1.25.1 and v1.26.0 tags are all `github-actions[bot]`-tagged from the release runner, never a local
tag):

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
path to main. v1.19.0 was the first release cut under all three; **v1.26.0 is the latest**
(verified-from-web, published as the current Latest 2026-07-22T12:06:42Z), and it went through this
pipeline end-to-end -- five gates green on a dry run, then five gates green again on the real run
that cut the tag and published the Release (Section 2).

**The pipeline cuts the tag. Always.** A printed `git tag` / `git push origin <tag>` pair is a
MANUAL FALLBACK for the case where the pipeline itself is unavailable -- never the release path, and
never something to run because a tool printed it. To release, trigger the `powershell-lsp release`
workflow with the target version; it validates, tags, signs, attests, and publishes as one gated
unit. The v1.26.0 cycle is the standing argument: a pre-existing hand tag had to be deleted before
Gate 2 would let the pipeline cut its own (Section 2), and only the pipeline's tag carries the
keyless gitsign signature and the SLSA provenance the trust surface advertises. `docs/RELEASING.md`
is the single-sourced runbook and states the same convention.

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
  detail is in Section 2. Dispatch 000124 then hand-authored the one missing entry, so every
  plugin-owned code -- `BashIsm`, `CommandLinePlaceholder`, `ManifestConsistency`,
  `ModuleNotInstalled`, `NonAsciiChar`, `PS7OnlySyntax` -- carries a rationale, and
  `rulesets/rule-rationales.psd1` covers the plugin's whole surfaceable set (**53 PSSA + 6 owned =
  59 entries**, of which 9 PSSA entries carry hand-authored overrides -- the 4 idiom-family ones
  from 000125 slice 1 plus the 5 default-surface ones from 000142 slice 2) at the pin
  (re-resolved live, verified-from-disk this refresh: `base.psd1` declares 53 `IncludeRules`, and
  the table's own `pssa_count` = 53, `owned_count` = 6, `override_count` = 9, entries = 59; the
  owned count reached 6 when v1.26.0 / 000139 added `CommandLinePlaceholder`, which this line had
  not yet absorbed). The PSSA count dropped by one when v1.24.3 / 000126 excluded
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
  **Slice 2 SHIPPED (000142 leg 2; cut into v1.27.0, unreleased).** Where slice 1 was mostly
  `base`-only opt-in rules, slice 2 covers what the median user actually reads: the **five PSES-15
  live-default-surface** rules whose derived text explained nothing --
  `PSAvoidDefaultValueSwitchParameter`, `PSAvoidUsingCmdletAliases`,
  `PSPossibleIncorrectComparisonWithNull`, `PSUseApprovedVerbs`, and
  `PSUseDeclaredVarsMoreThanAssignments`. The already-fires evidence is **measured, not asserted**
  (verified-from-disk): every one of the five appears in the DERIVED corpus snapshots under
  `tests/corpus/expected`, which `Update-CorpusSnapshots.ps1` produces from real analyzer runs. Each
  derived text was circular (restating the rule's own CommonName), definitional-and-truncated, or
  pure mechanism (restating the check's predicate); each replacement names a concrete consequence
  and a fix. The two most falsifiable claims were **verified on-host rather than reasoned about**:
  `curl`/`wget` resolve to `Invoke-WebRequest` aliases under Windows PowerShell 5.1 but not under
  PowerShell 7, and `@(1, $null, 2) -eq $null` returns an `Object[]`, not a boolean. Override count
  4 -> 9, `-Check` green at pin 1.25.0; the sixth default-surface rule,
  `PSAvoidUsingPlainTextForPassword`, was deliberately LEFT ALONE because its derived text already
  carries a real why. Three Integration assertions that pinned the derived `PSUseApprovedVerbs` text
  now pin the override, which is the live-daemon proof the layer reaches the default surface.
- **N1.2 Cross-file reference surfacing (#2 / #3) -- SHIPPED (v1.25.0 / 000128).** Shipped as the
  `referenceSurfacing` knob (default `off`): a deterministic "referenced by N files" signal via the
  diagnostic channel -- NOT the gated native-nav path. The 000127 survey settled the design, named
  one CONTRACT stop; 000128 made that decision (the frozen-knob amendment) and shipped the knob.
  The design record below is retained, now realized:
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
  - **NAMED STOP (why 000127 blocked; RESOLVED at 000128):** the build needs a
    `referenceSurfacing` userConfig knob, and `CONTRACT.md` section 1.1 freezes the knob-name SET
    drift-guarded to equal `.claude-plugin/plugin.json` **exactly**. Adding the knob to the manifest
    was PROVEN to turn BOTH the CONTRACT guard and the README guard RED (run this session, then
    reverted; the guards were re-run green afterwards). So the knob cannot ship without a
    `CONTRACT.md` FROZEN-KNOBS amendment -- which every prior knob got as a deliberate, documented
    MINOR (`formatOnEdit`/000059, `ruleset`/000087, `moduleAwareness`/000101, `nativeServe`/000103).
    That amendment is a frozen-surface decision reserved to Mike, and 000127 ran unattended under
    NIGHT_PROTOCOL, which names a CONTRACT need as a stop. **Nothing was built under 000127.**
    RESOLVED at 000128: Mike made the frozen-knob decision and the MINOR shipped as
    `referenceSurfacing` with the lockstep CONTRACT amendment (v1.25.0).
- **N1.3 Graph-facts surfacing (#6 core) -- SHIPPED with N1.2 (v1.25.0 / 000128).** Reference
  count / is-exported / called-from-N as facts, the score dropped. Folded into N1.2 and shipped
  with it -- the `referenceSurfacing` facts ARE referenced-by-N, exported, and defined-in.
- **N1.4 Quality-wave curation.** Exclude-only curation and config-tuning of the kept base rules, the
  same discipline as v1.21.1; cut a rule only when `review-dogfood.ps1` over accrued genuine captures
  ranks it net-noise. The clock is real usage (Section 5). Output: PATCH.
- **N1.5 Closed-loop latency benchmark -- MERGED to main (000127 leg 3).** Turns the 000061
  correction loop's structural latency claim into a measured median + p95 alongside the warm-hook
  baseline, from a rerunnable on-demand harness (`tests/bench/Invoke-LatencyBench.ps1`, reusing the
  000040 `tests/bench/` primitives -- which is where the placement question was already answered on
  disk). Cold start is excluded and said so; the harness verifies the lifecycle signal ACTUALLY fired
  rather than timing a plain warm turn and labelling it a closed loop. Numbers + method live in
  `docs/benchmarks.md`. Not CI-wired, deliberately: a single-machine number is indicative, not a
  regression gate (`tests/PowerShellLsp.Benchmark.Tests.ps1` still owns the guarded thresholds).
  Both `tests/bench/Invoke-LatencyBench.ps1` and `docs/benchmarks.md` are now ON MAIN
  (verified-from-web).
- **N1.6 Project-intelligence slice 2 -- `AliasesToExport` orphan check SHIPPED**
  **(v1.25.0 / 000128 leg 3).** The 000127 leg-4 survey ranked three candidates by measured FP on a
  known-good oracle (then 72 installed module manifests) rather than by architectural taste; it
  ranked the `AliasesToExport` orphan first, and 000128 shipped it after closing the "qualified"
  oracle gap named below. The survey record:
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
    every hit triaged by hand. **This gap is now CLOSED (v1.25.0 / 000128 leg 3):** the oracle was
    enlarged to 79 installed manifests plus four corpus fixtures modeling the two probe shapes the
    survey named, the dynamic-invocation / non-literal / `Export-ModuleMember -Alias` /
    nested-module / dot-source degrades were implemented, and the check measured **0%
    false-positive** -- the evidence
    bar this project holds a new detection to (000091 / 000092 / 000125). It rides the same
    `ManifestConsistency` code (no new owned code, no rationale-table change) and no knob.
  - **Nested-module consistency -- MEASURED, NO-BUILD, now CLOSED (000142 leg 3).** Surveyed under
    the same measure-first bar, and the measurement is decisive against building it
    (verified-from-disk, this box): of **111** parseable installed manifests, **73** declare
    `NestedModules`, but only **17** both name a script (`.psm1`/`.ps1`) nested module AND carry a
    literal `FunctionsToExport` list -- the only shape an AST cross-reference could check. A probe
    built from the SHIPPED helpers (`Resolve-ModuleRootModulePath` + `Get-ModuleDefinedFunctionNames`)
    fired on **17 of 17 (100%)**, and hand-triage of the hits found **no confirmed true positive**:
    `SmbShare` (59 exports; 17 `.cdxml` nested modules beside one 7-function `.psm1`),
    `EventTracingManagement` (20 exports; 3 `.cdxml`), and `AppvClient` (2 exports; a BINARY nested
    module) all export commands that are **CIM-generated or compiled**, which no source parse can
    resolve. The root cause is structural, not fixable by more degrade rungs: `NestedModules` is
    precisely the mechanism by which in-box modules compose CDXML and binary submodules. So this is
    the **same FP-hostile class as `RequiredModules`**, and it fails the 0%-FP bar by the widest
    margin yet measured on this project. The measurement also **positively confirms the existing
    degrade is correct**: silencing the check when `NestedModules` is non-empty (shipped in 000128)
    is exactly right, and lifting that silence would surface ~100% false positives. Recorded
    no-build, in the 000127 shape -- N1.6 is now decided, not parked.
  - Still deferred: `RequiredModules` vs project reality (FP-hostile -- a module legitimately
    required for types/formats/side effects is referenced by no `CommandAst`, and the probe's 0%
    rests on a denominator of **1**, which settles nothing).

### Horizon 2 -- Enterprise hardening (parallel track; adoption-gating)

- **E2.1 SARIF / CI deepening -- CLOSED; the code-scanning workflow is ON MAIN (000127 leg 5), then
  hardened by the 000131/000132 diagnosability work.** This
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
  `tests/corpus/samples/` is deliberately-bad code by construction. The workflow is now ON MAIN and
  its post-000131/000132 diagnosability surfaces -- each unanalyzable file NAMED (SARIF
  `toolExecutionNotification` + stderr + annotation) with the ELAPSED ms it ran -- make a future
  INCOMPLETE attributable from the Actions tab; main's own run flipped RED -> GREEN at the #91 merge
  (run 29661464779 success at 85fb892; see the scan-robustness lineage in Section 2). Output: **not
  the MINOR this item assumed** -- see leg 8's NO-BUMP reasoning; the gate it named was already
  released, and a repo-CI workflow is not a user-visible capability.
- **E2.2 Org policy config -- SHIPPED (000142 leg 1; cut into v1.27.0, unreleased).** The
  centrally-managed settings voice now exists as the `orgPolicy` knob (verified-from-disk): an
  absolute path to an organization's `PSScriptAnalyzerSettings.psd1` whose **`ExcludeRules` are
  enforced** as a final subtractive drop over the surfaced findings, applied at BOTH client surface
  points and before the hook emit and the dogfood capture, so a rule the org excludes cannot be
  re-enabled by a repo-local settings file or by `ruleInclude`. The include path is deliberately
  asymmetric -- the policy's own `IncludeRules` stay advisory and repo-local wins -- which is the
  fork 000135 decided and recorded. Client-side by construction, so the daemon and the Integration
  suite are structurally untouched; every branch is gated on the knob, and with it unset the surface
  is byte-identical (proven over the shipped corpus records, not merely asserted). Fails open with
  exactly one logged warning on a missing / unreadable / unparseable / relative path, and the policy
  is read through `Import-PowerShellDataFile` (restricted, data-only), so it can never execute code.
  One `CONTRACT.md` FROZEN-KNOBS row, proven RED then GREEN against the set-equality guard. Output
  was as forecast: MINOR + a CONTRACT amendment. **Known limitation (verified-from-disk):** the
  per-file-cap overflow count (`... and N more`) is computed daemon-side, before the org drop, so
  with `orgPolicy` set that count can include findings the policy would have dropped; the drop
  itself is exact. 22 unit tests across three families, four of them mutation-proven RED.
- **E2.3 Catalog listing.** Get into `anthropics/claude-plugins-community` (and the official catalog if
  it qualifies). Mike-gated. Output: no code. **Poll re-run 000142 leg 4 (read-only, one GET,
  verified-from-web):** `claude-powershell-lsp` is still **NOT present** in that marketplace --
  HTTP 200, **2262** plugin entries, **zero** entries whose name matches `powershell` at all, polled
  **2026-07-22T20:50:16Z**. The catalog grew by 14 entries since the 000127 leg-6 poll (2248 on
  2026-07-17), so the feed is live and the absence is a real negative, not a stale read. Nothing is
  inferred about Console-side state in either direction; the submission itself stays Mike's gate.
- **E2.4 Bus-factor mitigation -- DOCS SHIPPED (000136; released in v1.26.0).** The single-maintainer
  risk is the real enterprise blocker. The documented half is now in the tree (verified-from-disk):
  `docs/CONTINUITY.md` gives, per surface, what breaks if the sole maintainer disappears and the
  concrete recovery path; `MAINTAINERS.md` is a second-maintainer on-ramp (access grants, running
  and verifying a release, the strategic-dispatch hub relationship stated honestly as external to
  this repo); and the release runbook is single-sourced to `docs/RELEASING.md` so the recovery path
  has one address. Key custody is documented as a NON-issue by construction -- releases are keyless
  (gitsign / Sigstore OIDC), so there is no long-lived signing key or release secret to hand off.
  What remains is the part docs cannot supply: **an actual second maintainer**. Output so far:
  docs; the item stays open on the human half.
- **E2.6 Trust-evidence surface -- SHIPPED (000137; released in v1.26.0).** `docs/trust.md`
  (verified-from-disk) assembles in one evaluator-facing place the release-integrity chain that was
  already true but scattered across TRUST.md / docs/RELEASING.md / SECURITY.md: the keyless
  gitsign-signed tag and SLSA build provenance over both release assets, the CycloneDX SBOM
  generated from the real pins, the pinned and SHA-256-verified PSScriptAnalyzer, the measured 0%
  corpus false-positive bar guarded on every CI run, the measured latency in `docs/benchmarks.md`,
  the SHA-pinned code-scanning workflow, and the generated per-finding rule rationale (E2.5). README
  gains a short "Why trust this release" pointer. Docs-only: every claim links to a file or a
  released artifact, so the page asserts nothing the repo cannot show. Output: docs.
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
- **S3.4 Deferred rules -- the placeholder check RE-ENTERED and SHIPPED (000139; released in v1.26.0);
  the compat pair still deferred.** The bar was: re-enter only as a MINOR at a proven 0%
  false-positive rate on the widened corpus, via the 000096 pre-PSSA AST pass. The
  angle-bracket-placeholder check cleared it exactly that way and shipped as the plugin-owned finder
  `CommandLinePlaceholder` -- measured **0% FP on a 281-file oracle** (150 repo scripts + 131
  installed-module scripts, zero hits), token-level detection at the `scripts/lsp-client.ps1` seam,
  always-on additive, owned finders 5 -> 6 (verified-from-disk), no knob and no CONTRACT change.
  This is the measure-first bar working as designed: the check was deferred on suspicion of false
  positives, and it re-entered only once the suspicion was measured and refuted.
  `PSUseCompatibleCommands` / `PSUseCompatibleTypes` remain **unshipped and deferred** -- they are
  blocked on a target-profile decision (which PowerShell editions/versions to compat-check against),
  not on a corpus measurement, so the 0% bar does not by itself clear them.
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
