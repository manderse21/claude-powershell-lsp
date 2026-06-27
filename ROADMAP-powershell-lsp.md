# claude-powershell-lsp -- Roadmap

Status as of 2026-06-27. Plugin on main: v1.18.1, GPL-3.0-or-later (manifests + CHANGELOG at
1.18.1). The version is now TAGGED and pushed: an annotated tag v1.18.1 exists at commit
56f0196 (the 000075 merge) on origin, and `git describe --tags` returns v1.18.1. origin/main
is one commit ahead of the tag (7c3553a, the 000073 CI bump). What is NOT yet done is the
marketplace PUBLISH: the live registry still serves a stale 1.3.0 that false-advertises
hover/goto/find-refs; closing that gap (publish the registration-fixed 1.18.1 + a tree-vs-
published divergence guard) is dispatch 000076 (see Open work).

Provenance: dispatch state, version, and tag claims are verified against the live `dispatch
list --project powershell-lsp`, the dispatch log, `git log origin/main`, `git describe
--tags`, the CHANGELOG, and the plugin/marketplace manifests. Upstream issue/PR identifiers
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
per-file diagnostics over the warm PostToolUse hook -- is byte-for-byte unchanged by 000075.

## 2. Shipped and verified -- recent arc

CHANGELOG.md is the version-history-of-record. Each row below is traced to its CHANGELOG
entry; where the authored draft disagreed with the CHANGELOG, the CHANGELOG won (see the
000077 outbox for the correction list).

| Version | Dispatch | Delivered |
|---|---|---|
| v1.18.1 | 000075 | Native LSP registration restored (drop registrar-hostile fields + allowlist guard); registers-but-serve-gated UX documented. Merged + tagged (annotated v1.18.1 at 56f0196, pushed); awaiting only F2 verify. Marketplace publish still owed (000076) |
| v1.18.0 | 000064 | Supply-chain signing: keyless gitsign-signed release tags (Sigstore via GitHub OIDC, Rekor-logged) + corrected trust posture (cosign judged redundant; Authenticode deliberately not pursued) |
| v1.17.0 | 000063 / 000064 / 000065 (release-prep 000067) | Release-pipeline completion (Gate-4 waits for push-CI to conclude, 000063) + roadmap reconcile (000065); 000067 cut the lockstep version bump + CHANGELOG. First release produced end-to-end by the gated pipeline. (Build-provenance attestation is NOT new here -- it has been live since v1.13.0/000042; the shipped 1.17.0 "first attestation" framing was corrected in the 1.18.0 notes.) |
| v1.16.0 | 000048 | Community-release readiness: corpus to 34/36 with published 0% FP / 100% TP, trust badges, doctor-first quickstart, contributor docs, positioning |
| v1.15.0 | 000046 (incl. 000047) | Enterprise trust-surface + correctness-proof bundle: fail-closed SHA-256 dependency verification (the behavior change), measured 0%-FP corpus, TRUST.md / SECURITY.md. 000047's PSSA Gallery egress hardening (UA + bounded retry + PSGallery fallback) is folded in |

Earlier arc (the v1.5.x through v1.14.x ladder -- launch-readiness, licensing MIT -> GPLv3,
reliability/auto-relaunch, doctor self-check, security-block honesty, dogfood capture, CI
proof-framework + benchmark, release-engineering automation + SBOM + provenance, the PSSA
caching/egress hardening) is in CHANGELOG.md and the 000001-000051 log -- all merged,
F2-verified, and tagged where a version moved. CHANGELOG.md is authoritative for that older
arc; it is not re-transcribed per-version here.

## 3. Open work (live dispatch state)

- 000076 (accepted) -- close the publish gap: the marketplace serves a stale 1.3.0 that
  false-advertises hover/goto/find-refs; publish the registration-fixed 1.18.1 (NOT
  1.18.0-as-is) and add a tree-vs-published divergence guard. The TAG half of the old
  1.18.1 drift is already closed (v1.18.1 is tagged + pushed); what remains here is the
  marketplace publish + the divergence guard. Highest-priority open item.
- 000073 -- CI maintenance (PATCH): the attest actions' Node-20 deprecation. The fix is
  MERGED (PR #45, origin/main commit 7c3553a, attest-build-provenance bumped to v3 / node24),
  but the dispatch state is still `accepted` -- the close-out (in_progress -> complete ->
  verify) has not been run. Code-done, bookkeeping-open.
- 000074 (accepted) -- housekeeping: prune stale worktrees + sweep orphaned claims
  (live-first guards).
- 000075 (inbox + outbox complete) -- merged at 1.18.1 and tagged; awaits only Mike's F2
  verify flip (outbox is `complete`, not yet `verified`).

## 4. Buildable now -- the accepted PL feature queue

Authored and accepted, not yet executed. Several collide on version/CONTRACT and are better
consolidated into one bundle than run as separate dispatches (the 000046/000048 pattern).

| Dispatch | What |
|---|---|
| 000060 | PL-3 build slice 1: non-ASCII smuggling pre-PSSA byte pass (smart-punctuation set, UTF-8-without-BOM-gated); reusable pre-PSSA source category. Read the 000055 outbox. Always-on additive (no knob/token) |
| 000062 | PL-6 build slice 1: deterministic .psd1 static manifest-consistency (orphan/typo export detection), cached per session, degrades honestly on wildcard/dynamic/dot-source. Read 000058 |
| 000061 | PL-4 build slice 1: closed-loop agentic correction -- re-check the touched range after a fix, report cleared/still-present/moved/new over an additive additionalContext field, bounded escalation (K=2), no new status token. Read 000056 |
| 000057 | PL-5: SARIF 2.1.0 + standalone CI mode over the same engine the hook uses (new entry point; new knob = deliberate MINOR + CONTRACT amendment) |
| 000059 | PL-8: format-on-edit, suggest-not-rewrite, behind a new off-by-default knob (deliberate MINOR + CONTRACT amendment) |

PL-track surveys already verified and feeding these: 000055, 000056, 000058.

## 5. Paced by the dogfood log (cannot compress)

The capture engine (000039) and the annotation/review tool (000043) are shipped. 000066
confirmed the hook is path-transparent and the live 0-of-N genuine-repo-path count is an
exercise gap, not a defect. The quality wave (rule curation, false-positive reduction,
fix-suggestion quality) follows real interactive captures; the unblock is behavioral --
dogfood normal edits of the canonical checkout, then re-run the classifier.

## 6. Standing items (Mike-gated)

- gitsign tag-verify is a known client-side failure (000071, verified): the Rekor entry is
  present and valid; gitsign v0.16.1 verify-tag fails on a client-side hash mismatch; `gh
  attestation verify` is the documented primary check. No fix dispatch open; optional, not
  critical-path.
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
