# claude-powershell-lsp -- Roadmap

Status as of 2026-07-01. Plugin on main: v1.21.1, GPL-3.0-or-later (manifests + CHANGELOG at
1.21.1). The version is TAGGED, gitsign-signed, provenance-attested, and RELEASED: an
annotated, gitsign-signed tag v1.21.1 exists at commit 7df9a3b on origin (the #65
release-bump merge), `git describe --tags` returns v1.21.1, and the marketplace resolves to
1.21.1 (the tree-vs-published divergence guard from 000076 confirms parity -- no
stale-listing gap remains). The v1.21.1 GitHub Release (Latest) confirms the published
release. The old publish gap (the registry once served a stale 1.3.0) is CLOSED.

Provenance: dispatch state, version, tag, and publish claims are verified against the live
`dispatch list --project powershell-lsp`, the dispatch log, `git log origin/main`, `git
describe --tags`, the CHANGELOG, the plugin/marketplace manifests, and (for publish parity)
the 000076 divergence guard run during the v1.21.1 release. Upstream issue/PR identifiers
are confirmed against in-repo citations under docs/upstream/ and the README.

Goal (Mike, confirmed): an open tool that is excellent and findable -- not a paid product,
not adoption-chasing. The old "platform bet" framing (wait for Anthropic to fix LSP
registration) is retired: 000069 proved the registration failure was our own manifest, and
000075 fixed it. What remains gated is end-to-end native serve, not registration.

## 1. The native-LSP story, corrected

For most of this project the native LSP triad (hover / go-to-definition / find-references)
was treated as platform-gated -- built, verified, and parked pending an Anthropic fix.
000069 dissolved that: Claude Code's runtime LSP registrar silently drops any lspServers
entry declaring restartOnCrash or shutdownTimeout (both schema-valid, so plugin.json
validates, but the registrar rejects them with no diagnostic). Our lspServers.powershell
declared both, so .ps1/.psm1/.psd1 -> powershell never registered. 000075 (shipped, 1.18.1)
removed the two fields and added an allowlist guard; registration is re-proven on the fixed
tree (Claude Code 2.1.195, the persisted 000069 probe harness).

Honest boundary, stated everywhere this is described: registration is restored, but
end-to-end serve is still upstream-gated. Once registered, Claude Code launches PSES but its
LSP client times out during initialization (the #1359-class server->client handshake), so
native hover / go-to-def / find-refs do not complete yet. The plugin's real surface --
per-file diagnostics over the warm PostToolUse hook -- is unchanged by that gate.

## 2. Shipped and verified -- recent arc

CHANGELOG.md is the version-history-of-record. Each row below is traced to its CHANGELOG
entry; where an authored draft disagreed with the CHANGELOG, the CHANGELOG won.

| Version | Dispatch | Delivered |
|---|---|---|
| v1.21.1 | 000092 (survey 000091; release-prep 000093) | EXCLUDE-ONLY, evidence-gated curation of the opt-in `base` ruleset: 57 -> 54 rules. The 000091 quality wave ran the base ruleset whole-file over a 34-file known-good false-positive oracle and measured three default-on rules as net-noise -- PSReviewUnusedParameter (~90% FP on the param-block + nested-function shape that is every hook script), PSUseSingularNouns (intentional plural collection names), and PSUseShouldProcessForStateChangingFunctions (fires on the state-changing verb, not on real state change) -- all three BASE-ONLY (none in PSES's built-in 15-rule set), removed via a named, documented $BaseRuleExclusions list in scripts/regen-base-ruleset.ps1 so base.psd1 REGENERATES as (default-on minus the compatibility-profile family minus the exclude list) and `regen -Check` stays green (the 000087 deterministic-enumeration property preserved). pses-default is byte-for-byte unchanged; the three Error-severity security rules and PSAvoidUsingWriteHost are RETAINED. A PATCH -- the frozen CONTRACT surface (the `ruleset` knob name, its enum, its default) is unchanged. Tag v1.21.1 gitsign-signed, SBOM + provenance attested, GitHub Release published (Latest) |
| v1.21.0 | 000087 | Opt-in broadened live surface: a new `ruleset` enum knob (values `pses-default` and `base`, default `pses-default`) selecting the fallback ruleset when no repo-local PSScriptAnalyzerSettings.psd1 and no explicit settingsPath resolve. `pses-default` keeps PSES's built-in ~15-rule no-settings surface byte-for-byte; `base` resolves the plugin-owned, explicitly-enumerated rulesets/base.psd1 (PSScriptAnalyzer's default-on set minus the compatibility-profile rules, 57 rules at the pinned analyzer), broadening the live surface to include PSAvoidUsingWriteHost and the three Error-severity security rules. base ENUMERATES its rules rather than using IncludeDefaultRules, so the surfaced set is deterministic and a pinned-analyzer bump is a deliberate regeneration (scripts/regen-base-ruleset.ps1, whose `-Check` mode guards drift), never a silent shift. An explicit settingsPath and a discovered repo-local settings file ALWAYS win over the base. The default is deliberately NOT flipped -- the broadened surface never activates on upgrade unless opted in. A DELIBERATE MINOR with a CONTRACT amendment. Merged as the #63 release-bump at 475aa20; not cut as a standalone tag -- carried into the published v1.21.1 release above |
| v1.20.0 | 000059 | Off-by-default format-on-edit suggestions: a new `formatOnEdit` knob (values `off` and `suggest`, default `off`). When `suggest`, each edit triggers a separate warm-daemon round-trip that runs PSScriptAnalyzer's Invoke-Formatter on the edited file -- honoring the repo's own PSScriptAnalyzerSettings.psd1 formatter rules -- and surfaces the reformatted result as a SUGGESTION (a unified diff) via the existing additionalContext channel; the hook NEVER rewrites the file. Suggest-not-apply is the whole safety posture (`apply` is reserved and treated as `off` today, left to a separate higher-risk dispatch). No cold-start (runs on the already-warm daemon) and the pinned-hash PSScriptAnalyzer (000046 L2) is the only acquisition path. With the knob off the diagnostics surface is byte-for-byte unchanged. A DELIBERATE MINOR with a CONTRACT amendment. Tag v1.20.0 gitsign-signed, SBOM + provenance attested |
| v1.19.0 | 000057 / 000060 / 000061 / 000062 | A four-feature MINOR cut as one release through the fully-gated pipeline. 000057: SARIF 2.1.0 + a standalone CI-mode scan over the SAME engine the hook uses (new entry point, deliberate MINOR + CONTRACT amendment). 000060: AI-era rule pack slice 1 -- a non-ASCII smuggling pre-PSSA byte pass (smart-punctuation set, UTF-8-without-BOM-gated), always-on additive. 000062: project-intelligence slice 1 -- deterministic .psd1 static manifest-consistency (orphan/typo export detection), degrades honestly on wildcard/dynamic. 000061: closed-loop agentic correction slice 1 -- the warm daemon re-checks the touched range on the next edit turn and reports cleared/still-present over an additive additionalContext field, bounded escalation, no new status token. Tag v1.19.0 gitsign-signed, SBOM + provenance attested |
| v1.18.1 | 000075 (publish 000076) | Native LSP registration restored (drop registrar-hostile fields + allowlist guard); registers-but-serve-gated UX documented. 000076 closed the publish gap: the registration-fixed version published + a tree-vs-published divergence guard added |
| v1.18.0 | 000064 | Supply-chain signing: keyless gitsign-signed release tags (Sigstore via GitHub OIDC, Rekor-logged) + corrected trust posture (cosign judged redundant; Authenticode deliberately not pursued) |
| v1.17.0 | 000063 / 000065 (release-prep 000067) | Release-pipeline completion (Gate-4 waits for push-CI to conclude, 000063) + roadmap reconcile (000065); 000067 cut the lockstep version bump + CHANGELOG. First release produced end-to-end by the gated pipeline |
| v1.16.0 | 000048 | Community-release readiness: corpus to 34/36 with published 0% FP / 100% TP, trust badges, doctor-first quickstart, contributor docs, positioning |
| v1.15.0 | 000046 (incl. 000047) | Enterprise trust-surface + correctness-proof bundle: fail-closed SHA-256 dependency verification, measured 0%-FP corpus, TRUST.md / SECURITY.md; 000047's PSSA Gallery egress hardening folded in |

Earlier arc (the v1.5.x through v1.14.x ladder -- launch-readiness, licensing MIT -> GPLv3,
reliability/auto-relaunch, doctor self-check, security-block honesty, dogfood capture, CI
proof-framework + benchmark, release-engineering automation + SBOM + provenance, the PSSA
caching/egress hardening) is in CHANGELOG.md and the 000001-000051 log -- all merged,
F2-verified, and tagged where a version moved. CHANGELOG.md is authoritative for that older
arc; it is not re-transcribed per-version here.

## 3. Release process -- now hardened (the gate is structural, not convention)

The release path is enforced on three layers, all shipped:

- The gated release pipeline (powershell-lsp-release.yml, workflow_dispatch only): refuses
  to tag unless the target commit is merged, tag-free, version-locked (plugin.json ==
  marketplace.json == requested), four-leg push-CI GREEN by name, and tree-vs-published in
  parity (Gate 5, the 000076 guard). It cuts the gitsign-signed tag from the runner. A bad
  tag is structurally impossible.
- 000080 (shipped): a tracked local pre-push guard that refuses a direct push to
  origin/main.
- 000081 (shipped this cut): server-side branch protection on main -- require a PR, require
  the four named CI legs (ubuntu-pwsh / windows-powershell / windows-pwsh / macos-pwsh)
  green and strict, enforce for admins, block force-push and deletion. The required contexts
  were read from a real PR's check-runs, not guessed. An emergency-lift procedure (delete
  then re-PUT the protection via gh api) is the deliberate, logged hatch in place of a
  standing admin exemption.

Together: the gated pipeline + the local guard + server-side protection make the gated flow
the ONLY path to main. v1.19.0 was the first release cut under all three.

## 4. Open work (live dispatch state)

No dispatch is currently queued: the log holds no `accepted` or `drafted` dispatch. The prior
roadmap's single named next-buildable -- 000059 (PL-8 format-on-edit) -- SHIPPED in v1.20.0
(verified), and the ruleset-broadening arc that followed shipped too: 000087 (the `ruleset`
knob + the plugin-owned base ruleset, v1.21.0) and 000092 (the EXCLUDE-ONLY base curation,
v1.21.1). Every other non-terminal dispatch in the log sits at `complete`, not open: its work
is done -- surveys delivered, features merged and shipped -- with only Mike's F2 verified flip
outstanding.

What remains is survey-identified but unqueued -- horizon slices with no build dispatch cut
yet, each traceable to its survey outbox:

- AI-era rule pack, remaining slices (000055 survey). Slice 1 -- the non-ASCII smuggling
  pre-PSSA byte pass (000060) -- SHIPPED in v1.19.0. The survey's other candidates remain open
  and unbuilt: 5.1-vs-7 compatibility (PSUseCompatibleSyntax as a config-enable), bash-isms in
  .ps1 via an AST CommandAst pass, and here-string / BOM encoding traps. Literal angle-bracket
  placeholders were flagged high-false-positive and deferred. No build dispatch is queued for
  any of these.
- Format apply-mode. The `formatOnEdit` knob's `apply` value is reserved and treated as `off`
  today (000059 / v1.20.0); an actual apply mode -- the higher-risk fork that writes the file
  -- is deliberately left to a separate, unqueued dispatch.
- Project intelligence beyond slice 1 (000058 survey). Slice 1 -- deterministic .psd1
  manifest-consistency (000062) -- SHIPPED in v1.19.0. unused-export was ranked down as
  wrong-by-design (a public export's purpose is external callers); no further slice is queued.
- Native navigation tier (hover / go-to-def / find-refs). Built and registration-fixed (000075)
  but end-to-end serve is upstream-gated on Claude Code #1359 (Section 1). Not buildable here;
  horizon.

The broader quality wave that produced the v1.21.1 curation is paced by the dogfood log
(Section 5), not by a queued dispatch.

## 5. Paced by the dogfood log (cannot compress)

The capture engine (000039) and the annotation/review tool (000043) are shipped. 000066
confirmed the hook is path-transparent and the live 0-of-N genuine-repo-path count is an
exercise gap, not a defect. The quality wave has since produced its first shipped output:
000084 and 000090 seeded genuine-repo captures (the pses-default surface, then the broadened
`base` surface), 000091 ranked the base surface for false-positive / noise over the known-good
corpus, and 000092 applied that verdict as the EXCLUDE-ONLY base curation shipped in v1.21.1
(57 -> 54 rules). The remaining wave -- deeper curation, config-tuning of the kept rules, and
fix-suggestion quality -- still follows real interactive captures: the unblock stays behavioral
(dogfood normal edits of the canonical checkout, then re-run the classifier), gated on real
usage, not machinery.

## 6. Standing items (Mike-gated)

- The 000061 closed-loop latency claim shipped as a STRUCTURAL claim (~free next-turn,
  reusing the warm pass), not a measured number: the measured baseline (PL-2 / 000054) was
  abandoned. If the claim should be quantified, a fresh benchmark dispatch is the path
  (the 000054 inbox body is a usable template; drop its "before feature work lands" framing,
  that window has closed). Optional, not critical-path.
- gitsign tag-verify is a known client-side failure (000071, verified): the Rekor entry is
  present and valid; gitsign v0.16.1 verify-tag fails on a client-side hash mismatch; `gh
  attestation verify` is the documented primary check. No fix dispatch open; optional.
- Upstream posting remains Mike's gate. Drafts exist in-repo but nothing is posted: the
  Claude Code LSP-registration registrar-field-rejection report (issue #66987, drafted under
  docs/upstream/claude-code-lsp-registration.md, NOT posted) and the PSES rename-capability
  fix (issue #2297 / PR #2299, fix branch pushed to Mike's fork, NOT submitted; see
  docs/upstream/pses-2297-pr.md). The serve-gate handshake the native path waits on is
  upstream #1359 (cited in the README and CHANGELOG). All are postable via `gh` only.

## 7. Operating posture (unchanged)

Fast on a gated path; the gate is fast, not removed. Human gates: accept, merge, F2 verified
flip, tag, and the product / positioning / sequencing calls. Within an accepted dispatch's
scope, CC decides implementation, design, and ripeness. Ground truth (live `dispatch list`,
the log, file inspection) wins over any doc, including this one -- the log is authoritative.
