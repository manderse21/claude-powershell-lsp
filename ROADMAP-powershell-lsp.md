# claude-powershell-lsp -- Roadmap

Status as of 2026-07-05. Plugin on main: v1.23.1, GPL-3.0-or-later (both manifests + the latest
CHANGELOG release heading at 1.23.1). The version is TAGGED, gitsign-signed, provenance-attested,
and RELEASED: an annotated, gitsign-signed tag v1.23.1 -- cut from the release runner by
`github-actions[bot]` under the gated pipeline -- sits at commit 20e14d7 on origin (the #78
release-bump merge), `git describe --tags` returns v1.23.1, the v1.23.1 GitHub Release is published
as Latest (2026-07-04), and the served marketplace listing resolves to 1.23.1 (Gate 5's
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
| v1.23.1 | 000108 (survey 000107); 000110 (survey 000109); release-prep 000114 | PATCH (docs). Two documentation deliverables to installed users: (1) the Windows native-LSP launcher guard recorded as a known issue (docs/upstream/claude-code-lsp-registration.md + the README `nativeServe` section, scoped to Windows, upstream claude-code#73961); (2) every one of the 17 `userConfig` descriptions capped (<= ~200 chars each) for Claude Code config-panel height stability, with the full per-knob semantics relocated -- nothing deleted -- into a new docs/configuration.md, after 000109 found a long description could push the /plugin config panel past the viewport and trip a renderer ghost-row corruption. Behavior byte-for-byte unchanged: no knob key, type, value, default, `CONTRACT.md`, or product-code change. Tag v1.23.1 gitsign-signed; GitHub Release published Latest (2026-07-04) |
| v1.23.0 | 000099; 000101 (survey 000100); 000103 (survey 000102); 000104 | MINOR (four features). 000099: format-on-edit `apply` activated -- `formatOnEdit=apply` becomes a guarded write-back (stale-write compare-and-swap, atomic-or-abort swap, BOM/EOL fidelity, no-change=no-write; a mixed-EOL / non-UTF-8 file aborts to a suggestion), the first feature that ever modifies the user's file; the default stays `off` and `off`/`suggest` are byte-for-byte unchanged. 000101: module awareness (`moduleAwareness` knob, default `off`) -- an Information-severity "command from an uninstalled module" hint from a shipped offline command->module index, design B (install-check-gated), silent on every ambiguity. 000103: the native-serve shim (`nativeServe` knob -- Section 1). 000104: the report-only `doctor.ps1 -ProbeNativeServe` removability probe, plus the v1.23.0 cut itself. Tag v1.23.0 gitsign-signed, provenance-attested |
| v1.22.0 | 000096; 000097 (release-prep 000098) | MINOR -- the AI-era rule pack, slices 2 and 3, which CLOSE the pack. Both are always-on additive pre-PSSA AST passes over the parser AST the pre-pass already produces (no knob, no status token, `CONTRACT.md` unchanged). 000096 `PS7OnlySyntax`: flags PowerShell-7-only syntax an AI drops into a file that may run on 5.1 (`&&`/`||`, ternary `? :`, `??`/`??=`/`?.`/`?[]`), suppressed when the file declares `#Requires -Version 7`. 000097 `BashIsm`: flags Unix command NAMES in a `.ps1` (`grep`, `sed`, `awk`, `export`, `which`, `touch`, `chmod`, `chown`, `ln`), suppressed by an explicit `& name` call or a same-file definition. With slice 3 the 000055 pack is CLOSED (slice 4 was already-covered; slice 5, angle-bracket placeholders, is deferred on irreducible false-positives). The measured 0% FP / 100% TP held on the widened corpus. Tag v1.22.0 gitsign-signed, provenance-attested |
| v1.21.1 | 000092 (survey 000091; release-prep 000093) | PATCH -- EXCLUDE-ONLY curation of the opt-in `base` ruleset, 57 -> 54 rules. The 000091 wave measured three default-on rules as net-noise over a 34-file known-good oracle (`PSReviewUnusedParameter` ~90% FP on the param-block + nested-function shape; `PSUseSingularNouns`; `PSUseShouldProcessForStateChangingFunctions`), all three BASE-ONLY (none in PSES's built-in 15-rule set), removed via a named `$BaseRuleExclusions` list so base.psd1 REGENERATES deterministically. `pses-default` is byte-for-byte unchanged; the three Error-severity security rules and `PSAvoidUsingWriteHost` are retained. The frozen CONTRACT surface (the `ruleset` knob) is untouched |
| v1.21.0 | 000087 | MINOR -- opt-in broadened live surface: a new `ruleset` enum knob (`pses-default` | `base`, default `pses-default`) selecting the fallback ruleset when no repo-local settings and no explicit settingsPath resolve. `base` resolves the plugin-owned, explicitly-enumerated rulesets/base.psd1 (default-on minus the compatibility-profile family, 57 rules at the pin), broadening the live surface to include `PSAvoidUsingWriteHost` and the three Error-severity security rules. An explicit settingsPath and a discovered repo-local settings file ALWAYS win. The default is deliberately NOT flipped. A DELIBERATE MINOR with a CONTRACT amendment |
| v1.20.0 | 000059 | MINOR -- off-by-default format-on-edit SUGGESTIONS: a `formatOnEdit` knob (`off` | `suggest`, default `off`). When `suggest`, each edit triggers a warm-daemon Invoke-Formatter round-trip (honoring the repo's own PSScriptAnalyzerSettings.psd1) and surfaces the result as a unified-diff SUGGESTION via additionalContext; the hook NEVER rewrites the file. `apply` was reserved here and treated as `off` -- later activated as the guarded write-back in v1.23.0. A DELIBERATE MINOR with a CONTRACT amendment |
| v1.19.0 | 000057 / 000060 / 000061 / 000062 | MINOR (four features) cut as one release. 000057: SARIF 2.1.0 + a standalone CI-mode scan over the same engine the hook uses. 000060: AI-era rule pack slice 1 -- the non-ASCII smuggling pre-PSSA byte pass (built the reusable pre-PSSA source category later slices 2/3 reuse). 000062: project-intelligence slice 1 -- deterministic .psd1 static manifest-consistency. 000061: closed-loop agentic correction slice 1 -- the warm daemon re-checks the touched range next turn and reports cleared/still-present, additive |
| v1.18.1 | 000075 (publish 000076) | PATCH -- native LSP registration restored (drop the two registrar-hostile fields + allowlist guard); registers-but-serve-gated UX documented. 000076 closed the publish gap and added the tree-vs-published divergence guard (now Gate 5) |
| v1.18.0 | 000064 | MINOR -- supply-chain signing: keyless gitsign-signed release tags (Sigstore via GitHub OIDC, Rekor-logged) + corrected trust posture (cosign judged redundant; Authenticode deliberately not pursued) |

Earlier arc (v1.5.x through v1.17.0 -- launch-readiness, licensing MIT -> GPLv3, reliability /
auto-relaunch, doctor self-check, dogfood capture + review tooling, the CI proof-framework, the
enterprise trust-surface + measured-0%-FP corpus, community-release readiness, and release-engineering
automation with SBOM + provenance) is in CHANGELOG.md and the 000001-000067 log -- all merged,
F2-verified, and tagged where a version moved. CHANGELOG.md is authoritative for that older band; it
is not re-transcribed per-version here.

## 3. Release process -- hardened (the gate is structural, not convention)

The release path is enforced on three layers, all shipped, and every release from v1.19.0 through the
current v1.23.1 was cut end-to-end by it:

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
path to main. v1.19.0 was the first release cut under all three; v1.23.1 is the latest.

## 4. Open work (live dispatch state)

No build dispatch is queued: the log holds no `accepted` or `drafted` dispatch carrying unstarted build
work. (Two inboxes, 000112 and 000113, still read `accepted` while their outboxes read `verified` --
the F2 inbox-flip lag, not open work; both are done. 000095, an earlier launch-draft refresh, is
`abandoned`, superseded by 000112.) The prior roadmap's three named forward claims have all LANDED and
are reclassified out of the horizon:

- Native navigation tier (hover / go-to-def / find-refs): SHIPPED opt-in via the `nativeServe` shim
  (v1.23.0 / 000103). Not horizon. What remains is upstream, not buildable here: #1359 (serve
  handshake) and, on Windows, #73961 (launcher guard) -- Section 1.
- Format apply-mode: SHIPPED as the guarded `formatOnEdit=apply` write-back (v1.23.0 / 000099). The
  reserved enum value is now real. Not horizon.
- AI-era rule pack: CLOSED (v1.22.0 / 000097). Slices 1-3 shipped; slice 4 was already-covered; slice 5
  (angle-bracket placeholders) and the Compatible-Cmdlet / Compatible-Type checks
  (`PSUseCompatibleCommands` / `PSUseCompatibleTypes`) are deliberately DEFERRED on high false-positive
  rates -- deferred by design, not open backlog.

What genuinely remains is survey-identified but unqueued, or paced by usage (Section 5):

- Deeper rule curation, config-tuning of the kept rules, and fix-suggestion quality -- gated on real
  interactive dogfood captures, not on machinery (Section 5).
- An optional closed-loop latency benchmark. The 000061 correction loop shipped its latency as a
  STRUCTURAL claim (~free next-turn, reusing the warm pass), not a measured number; the measured
  baseline it would cite (PL-2 / 000054) is `abandoned` (verified live). Quantifying the claim would
  need a fresh benchmark dispatch -- optional, not critical-path.

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
- **Upstream posting -- partly done; the rest is Mike's gate.** Posted / filed: the Windows launcher
  guard is filed as anthropics/claude-code#73961 (OPEN), and our refreshed comment on
  anthropics/claude-plugins-official#1359 is posted (2026-07-05, the issue itself stays OPEN). Still
  UNPOSTED and Mike-gated: the registrar-field-rejection report (our corrected LSP-registration record
  lives internally in docs/upstream/claude-code-lsp-registration.md; the related upstream issue #66987
  is open), and the Claude Code config-panel renderer-bug report drafted under 000109 (its manifest-side
  mitigation -- the description cap + configuration.md -- shipped in v1.23.1; the upstream renderer issue
  is drafted, not posted). The PSES rename-capability fix (issue #2297) was submitted as PR #2299 and is
  now CLOSED unmerged (2026-06-11, verified live) -- settled, no longer a pending post; the on-disk notes
  that still call it "not submitted" / "open" (docs/upstream/pses-2297-pr.md, sitting-closeout.md) are
  superseded.
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
