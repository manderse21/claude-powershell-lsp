# powershell-lsp -- canonical current state

**What this document is.** The factual baseline Roadmap II plans against. It records what is true
on disk and on the live services at the derivation moment, and nothing else. It **proposes no
solutions, recommends no work, and contains no roadmap prose** -- those belong to R2-02 and later.

**How to read a figure here.** Every count, size, and state below carries its derivation reference
and date inline, because a bare number in a planning document ages into a false claim. Where a
figure was expected from the planning side, it was **confirmed or refuted against disk**, never
restated. Nothing in this file is asserted from memory.

**Derivation moment.** This document was first derived 2026-08-12 (dispatch 000221, R2-01) at
`origin/main` = `7f34277`, plugin version `1.31.0`.

> ### SUCCESSOR RE-DERIVATION: 2026-08-21, dispatch 000269, at v1.32.0
>
> **This document moves only when a successor dispatch re-derives it**, which is the rule
> `PROGRAM.md` records for R2-01 and the only sanctioned way its numbers change. Dispatch 000269 is
> that successor. Sections 1, 2, 4, 7, 10, 11 and 13 are re-derived below at
> `origin/main` = `78ddcee`, release **v1.32.0** (peeled `fb3116c`).
>
> Every re-derived figure was taken again from disk or from live `gh` at write time. Where a figure
> is unchanged it is marked **re-derived unchanged** rather than left silent, so a reader can tell a
> checked number from an unrevisited one. Sections not listed above were not re-derived, and say so
> where it matters.

**Line anchors into `ROADMAP.md` are stale throughout this document.** That page was rewritten and
shortened by dispatch 000230 after the original derivation, so every `ROADMAP.md:<n>` citation below
points at the pre-canonicalization line numbering. **Still not repaired at the 2026-08-21
re-derivation, and recorded as a known defect rather than quietly carried:** re-anchoring every
citation was out of this successor's scope, which was the factual figures. Treat any
`ROADMAP.md:<n>` below as a pointer to a section name, not to a line.

---

## 1. Current version

**Re-derived 2026-08-21.** The v1.31.0 figures this section carried are superseded.

| Fact | Value | Derivation |
|---|---|---|
| Latest release tag | **`v1.32.0`** | `git tag --list 'v*' --sort=-v:refname`, 2026-08-21 (`v1.32.0`, then `v1.31.2`, `v1.31.1`) |
| Tag object type | annotated (`tag`), object `072d8818109728301558c7c6707d795f4096c598` | `git rev-parse refs/tags/v1.32.0` + `git cat-file -t`, 2026-08-21 |
| Tag creation date | 2026-08-19 20:31:18 +0000 | `git for-each-ref --format='%(creatordate:iso8601)'`, 2026-08-21 |
| Release published | 2026-08-19T20:31:25Z, not a draft | `gh release view v1.32.0 --json publishedAt,isDraft`, 2026-08-21 |
| `plugin.json` version at `origin/main` | `1.32.0` | `git show origin/main:.claude-plugin/plugin.json`, 2026-08-21 |
| `plugin.json` version at the peeled tag | `1.32.0` | `git show 'refs/tags/v1.32.0^{}:.claude-plugin/plugin.json'`, 2026-08-21 |
| `marketplace.json` version at `origin/main` | `1.32.0` | same command against `marketplace.json`, `.metadata.version`, 2026-08-21 |
| `marketplace.json` version at the peeled tag | `1.32.0` | same, at the peeled tag, 2026-08-21 |
| Declared license | **`Apache-2.0`** | `.claude-plugin/plugin.json` `.license` at `origin/main`, 2026-08-21 -- the forward-only relicense took effect at this release |

The two manifests are **in lockstep at both refs** -- re-derived unchanged as a property, at new
values. No version drift exists between `main` and the released artifact.

## 2. Current commit

**Re-derived 2026-08-21.**

| Fact | Value | Derivation |
|---|---|---|
| `origin/main` tip | **`78ddcee2620b5c5bfcae2755998dfe7685f9900f`** | `git rev-parse origin/main`, 2026-08-21 |
| `v1.32.0` **peeled** commit | **`fb3116cab14cd8afec4e9c64ed0c2e67e76486b3`** | `git rev-parse 'refs/tags/v1.32.0^{}'`, 2026-08-21 |
| `main` relative to the peeled tag | **4 ahead, 0 behind** | `git rev-list --left-right --count 'refs/tags/v1.32.0^{}...origin/main'` -> `0	4`, 2026-08-21 |

The four commits by which `main` leads the release tag, newest first
(`git log 'refs/tags/v1.32.0^{}..origin/main'`, 2026-08-21):

| Commit | Subject |
|---|---|
| `78ddcee` | docs(000251): land the corpus commons un-gate -- publish the audited surface under Apache-2.0 (#192) |
| `220149f` | docs: correct v1.32.0 whitepaper (r2) and cite evidence bundle (#191) |
| `84fda97` | Evidence bundle + attestation workflow for v1.32.0 (#190) |
| `b44c1ff` | docs(000268): land the finalized v1.32.0 white paper at docs/whitepaper.md (#189) |

**All four are documentation, evidence and workflow commits. No change under `scripts/` or
`rulesets/` separates `main` from the released artifact** -- so the runtime a user executes at
`main` is the runtime that shipped. The same property held at the previous derivation, and it is
re-derived here rather than assumed to persist.

> **The release identity has a second commit worth knowing.** The quantitative evidence for
> v1.32.0 was measured at `af6996f` (the merge of PR #187) and carried to the release identity
> `fb3116c` (the merge of PR #188, the fix that unblocked the release pipeline). The carry is proven
> rather than asserted: the `af6996f -> fb3116c` diff touches five paths, none under `scripts/` or
> `rulesets/`, and every tracked runtime blob is byte-identical between them. See
> [`SLO-BASELINES.md`](SLO-BASELINES.md) section 1 and `evidence/v1.32.0/`.

## 3. Architecture summary

**The plugin is a CLIENT of PowerShell Editor Services. It is not a fork of PSES, not a
re-implementation of it, and it contains no analysis engine of its own.** Diagnostics are produced
by PSES and by PSScriptAnalyzer running inside PSES; the plugin's own code is transport,
lifecycle, policy, and presentation around that. This posture is stated here plainly because it is
the single fact that most often gets mis-stated in planning.

Derived from `ARCHITECTURE.md` (111 lines, 7,594 bytes, last commit `3718a5b` 2026-06-24) and the
script inventory at `origin/main`, 2026-08-12:

- **Warm daemon.** `scripts/pses-daemon.ps1` (1,669 lines) hosts one PSES process via `-Stdio` and
  exposes a named pipe `powershell-lsp-<sessionid>`. It is **pipe-first**: the request pipe opens
  *before* PSES is ready, so an edit racing startup receives an honest status rather than silence.
- **Edit path.** `scripts/lsp-client.ps1` (824 lines) is the `PostToolUse` hook. It reads hook JSON
  from stdin, connects to the pipe, requests diagnostics for the edited file, and returns them via
  `hookSpecificOutput.additionalContext`.
- **Session end.** `scripts/session-end.ps1` (113 lines) tells the daemon to shut PSES down cleanly.
- **Bootstrap.** `scripts/ensure-pses.ps1` (142 lines) and `scripts/ensure-pssa.ps1` (254 lines) are
  idempotent, pinned, and SHA-256-verified before use.
- **Shared core.** `scripts/lib/lsp-common.ps1` holds host detection, file-URI construction, LSP
  framing, diagnostics ordering/dedupe/threshold/cap, and the status-banner functions. It is
  dot-sourced by daemon, client, hooks, and tests.
- **Cold-start launcher.** `scripts/pses-stdio.ps1` (52 lines) is the destination a native
  `.lsp.json` registration would target.

Everything runs on the local machine. Timing is in section 5.

## 4. Shipped capability inventory

**The four surface tables below were derived at `origin/main` (`a82716d2`), 2026-08-12, and were NOT
re-derived by the 2026-08-21 successor pass.** Only the release-assets subsection at the end of this
section was. Treat every count and size in them as **as-of 2026-08-12**, not as current: they are
recorded rather than refreshed, because refreshing the whole inventory was outside the successor's
scope -- and a half-refreshed table, where the reader cannot tell which rows moved, is worse than a
plainly dated one.

### Distribution surface

| Item | Value | Derivation |
|---|---|---|
| Shipped commands | 3 -- `doctor.md` (42 lines), `scan.md` (59), `status.md` (28) | `commands/` directory listing |
| `userConfig` knobs | **20** | parsed `.claude-plugin/plugin.json` `userConfig` key count |
| Declared LSP servers | 1 (`powershell`) | `.claude-plugin/plugin.json` `lspServers` |
| `hooks` key present | yes | `.claude-plugin/plugin.json` |
| Default doctor checks | 11 | `ROADMAP.md:76` ("taking the default doctor to 11 checks"), corroborated by `README.md:495` describing header lines that "contribute nothing to the `of N checks` count" |

The 20 knobs, with their declared types and defaults, are `profile` (safe), `ps_host` (pwsh),
`ruleset` (pses-default), `settingsPath` (empty), `orgPolicy` (empty), `severityThreshold` (Hint),
`ruleInclude` (empty), `ruleExclude` (empty), `perFileCap` (20), `scopeToEdit` (true),
`editContextLines` (0), `formatOnEdit` (off), `moduleAwareness` (off), `referenceSurfacing` (off),
`nativeServe` (off), `timeoutMs` (5000), `debounceMs` (150), `idleTtlMin` (30), `keepLastN` (10),
`enableStats` (false).

**Every one of the 20 is declared `type: "string"`** -- including the booleans (`scopeToEdit`,
`enableStats`), the numerics (`perFileCap`, `editContextLines`, `timeoutMs`, `debounceMs`,
`idleTtlMin`, `keepLastN`), and the enumerations (`profile`, `severityThreshold`, `formatOnEdit`,
`moduleAwareness`, `referenceSurfacing`, `nativeServe`). This is a recorded consequence of the
upstream manifest-schema limit in section 7, not a local authoring choice.

### Analysis surface

| Item | Value | Derivation |
|---|---|---|
| Rules in the generated base ruleset | **53** | count of `'PS`-prefixed entries in `rulesets/base.psd1` (120 lines total), 2026-08-12 |
| Pinned PSES | v4.6.0 | `projects/powershell-lsp/VERIFICATION_SURFACE.md`, derived at the tag by dispatch 000219 |
| Pinned PSScriptAnalyzer | 1.25.0 | same source |

`rulesets/base.psd1` is generated by `scripts/regen-base-ruleset.ps1`, never hand-edited.

### Test and evidence surface

| Item | Value | Derivation |
|---|---|---|
| Files under `tests/` | **293** | recursive file count, 2026-08-12 |
| Pester test files (`*.Tests.ps1`) | **18** | same sweep |
| Largest test file | `PowerShellLsp.Unit.Tests.ps1`, 4,746 lines | line count |
| Corpus files | **253** total -- 127 `samples/`, 121 `expected/`, 3 `parser-samples/` | `tests/corpus/` recursive count, 2026-08-12 |
| Benchmark fixtures | 7 files under `tests/bench/` | directory count |

### Release and CI surface

| Item | Value | Derivation |
|---|---|---|
| CI legs | **4** -- `windows-pwsh`, `windows-powershell`, `ubuntu-pwsh`, `macos-pwsh` | `.github/workflows/powershell-lsp-ci.yml` matrix `include` block, lines 33-46 |
| CI runners | windows-2025 (x2), ubuntu-24.04, macos-15 | same block |
| Release workflow | `.github/workflows/powershell-lsp-release.yml`, 441 lines | file, last commit `335098c` 2026-08-10 |
| Code-scanning workflow | `.github/workflows/powershell-lsp-code-scanning.yml`, 153 lines, weekly `cron: '0 6 * * 1'`, ubuntu-24.04, SARIF upload, never fails the job | file header and `on:` block |
| Release gates | 6, all shipped by v1.29.1 and all green cutting v1.31.0 | `VERIFICATION_SURFACE.md` "Release gates", derived by dispatch 000219 at the tag |

### v1.32.0 release assets

**Re-derived 2026-08-21** via `gh api repos/manderse21/claude-powershell-lsp/releases/tags/v1.32.0`.
Release published 2026-08-19T20:31:25Z; not a draft, not a prerelease. The v1.31.0 table this
section carried is superseded.

| Asset | Size (bytes) | Digest listed by the API |
|---|---:|---|
| `powershell-lsp-1.32.0.cdx.json` | 2,518 | `sha256:52a3fe814de7c25be00f68dc5e6abdab9f15faa795adac5762f5ba77676ffb4a` |
| `powershell-lsp-1.32.0.tar.gz` | 2,668,407 | `sha256:1972d7a2867544dc782d87dabaec5d8d196072d17e853a9688da41e6271a7ba0` |
| `powershell-lsp-airgap-1.32.0.zip` | 34,573,424 | `sha256:3f9a76e311010ed9622bfd5305812f7d745586e83dc346d844f8786f034db101` |
| `powershell-lsp-evidence-1.32.0.zip` | 64,962 | `sha256:9b38de54e8245888ffbdd3a2736c1c18e6f8814d1f9f19f48e1bfc385e85de92` |

**Two new asset classes ship at this release**, and both are substantive rather than packaging
churn: the **airgap bundle** (R2-15's deliverable -- the offline bootstrap path) and the **evidence
bundle** (the freeze measurements and gate outputs, which is what makes the release's quantitative
claims checkable by a reader).

**The digest-location fact is re-derived and still holds:** the digests live in the GitHub release
API asset `digest` field, and the release **body carries no asset-digest listing**.

> A naive re-check of the body for `sha256` / `digest` / any 64-hex run returns **5 hits at this
> release where the previous derivation found zero** -- and every one of them is a **false
> positive**. They are prose about the new `orgPolicy` `<policy>.sha256` integrity-pinning feature,
> plus one example hash inside that prose. None is an asset digest. Recorded because the naive
> count *looks* like the finding changed and it did not: a needle that matches a feature's
> documentation cannot distinguish it from the feature's output.
>
> **The digest confirmation pass was NOT re-run at this derivation.** The 2026-08-12 pass
> downloaded both v1.31.0 assets and re-hashed them; nothing equivalent was done for the four
> v1.32.0 assets here. The digests above are what the API reports, not what this dispatch verified
> by re-hashing, and they are recorded as the former.

## 5. Capability maturity assessment

Stated as measured facts about each capability's evidence, not as scores or grades.

| Capability | Maturity signal | Derivation |
|---|---|---|
| Warm-hook diagnostics round-trip | Measured: **median 2,228 ms, p95 2,463 ms, min 2,090, max 2,633, n=30** | `docs/benchmarks.md:36`, file last commit `4c6535d` 2026-08-08 |
| Closed-loop re-check turn | Measured: median 2,256 ms, p95 2,398 ms, n=30 -- median 28 ms (1.3%) above warm baseline while p95 is 65 ms *lower*, which the source reads as below run-to-run noise | `docs/benchmarks.md:36-47` |
| False-positive bar | Measured 0% false-positive / 100% true-positive under the default config, guarded on all four CI legs; snapshots are tool-derived, never hand-authored | `VERIFICATION_SURFACE.md` "Corpus false-positive guard" |
| Cross-platform coverage | 4 CI legs green as a release gate precondition | CI matrix; release gate 4 |
| Release provenance | Keyless signed tags, SLSA build provenance on both assets, CycloneDX 1.5 SBOM generated from the real pins | `docs/trust.md` section headings; `VERIFICATION_SURFACE.md` "Dependency pins + SBOM" |
| Native code navigation | Registration works; **serve does not on the direct path**; the opt-in `nativeServe = shim` closes it locally and ships, but its `${user_config.*}` transport is **suspended** on an affected client, so the knob is shipped-and-configured yet not in effect there | `ROADMAP.md` "Gated and paced", native code navigation; `Get-ServeTransportSuspension` in `scripts/lib/lsp-common.ps1` |
| Per-rule efficacy ledger | Machinery ships (`scripts/rule-efficacy-ledger.ps1`, 897 lines, last commit `e24b09b` 2026-08-09); **its input data is the gap in section 10** | file; section 10 |
| Enterprise policy distribution | One knob ships (`orgPolicy`); no distribution or rollup mechanism exists | `plugin.json` userConfig; `ROADMAP.md:109-111` |

## 6. Known limitations

Recorded from the repository's own statements and from the derivations above.

- **Serve on the direct native path does not work.** Claude Code's LSP client rejects the
  server-to-client requests PSES sends during initialization. The shipped `nativeServe = shim`
  is a workaround, not a fix (`ROADMAP.md`, "Gated and paced").
- **The shim's configuration transport is separately suspended.** On an affected client the
  `${user_config.*}` mappings that carry `nativeServe` into the serve subprocess are withdrawn,
  because one unset declared key makes the client discard every server the plugin declares. The
  knob is therefore shipped and settable yet not in effect on that client. The removed mappings
  and the exact un-gate condition are recorded in `Get-ServeTransportSuspension`
  (`scripts/lib/lsp-common.ps1`); the upstream defect is tracked in section 7.
- **A second upstream Windows defect had blocked the native tier from starting at all** under some
  Claude Code versions. It is **fixed and closed upstream** as of the write-time re-check recorded
  in section 7, so it is history rather than a current limitation.
- **Analysis depth is bounded by PSES and PSScriptAnalyzer.** The plugin adds no analysis engine
  (section 3), so any capability PSES does not expose is not available to surface.
- **The default rule surface is deliberately narrow.** 53 rules in the generated base set, with the
  broader ruleset opt-in rather than default (`ROADMAP.md:128`).
- **Every `userConfig` knob is a free-text string** (section 4), so enum-valued and boolean knobs
  are validated by the plugin at run time rather than by the config dialog.
- **Single maintainer.** Stated in `ROADMAP.md:133-134` and `docs/CONTINUITY.md` (139 lines, last
  commit `a4e3455` 2026-08-10).

## 7. Active upstream dependencies

**Every state below was re-derived with `gh` at execution time. No status was read from
`docs/upstream/`, whose labels are known to drift and are recorded as findings in section 13.**

Query timestamp: **2026-08-12T13:05:01Z**, `gh issue view --repo <repo> <n> --json
number,title,state,stateReason,createdAt,updatedAt,closedAt,comments,labels`.

| Issue | State | Created | Last activity | Comments | Labels | Resolution signal |
|---|---|---|---|---|---|---|
| `anthropics/claude-plugins-official#1359` | **OPEN** | 2026-04-11T19:27:25Z | 2026-07-04T21:21:39Z | 3 | (none) | **None.** Last comment is the maintainer's own (`manderse21`, 2026-07-04) confirming the defect reproduces for PSES v4.6.0 |
| `anthropics/claude-code#66987` | **OPEN** | 2026-06-10T12:25:56Z | 2026-07-06T19:15:11Z | 1 | bug, has repro, platform:windows, area:lsp, area:plugins | **None.** Sole comment is `manderse21`'s own 2026-07-06 rewrite note |
| `anthropics/claude-code#73961` | **OPEN** | 2026-07-03T19:22:38Z | 2026-07-03T19:23:44Z | 0 | bug, has repro, platform:windows, area:lsp, area:plugins | **None.** Zero comments since filing |
| `anthropics/claude-code#74289` | **OPEN** | 2026-07-04T22:17:56Z | 2026-07-04T22:19:04Z | 0 | bug, platform:windows, area:tui, area:plugins | **None.** Zero comments since filing |

**All four were open at the derivation moment, and none carried any upstream-side response.** Every
"last activity" timestamp in the table is the maintainer's own edit or comment, not an upstream
reply. The most recent activity of any kind across all four was 2026-07-06 -- **37 days before this
derivation**.

### Write-time re-check, 2026-08-21 (dispatch 000269) -- the successor re-derivation

Re-derived live with `gh issue view --json state,updatedAt,comments,labels`. **Three of the six
tracked issues moved since the last re-check, and two of them moved to CLOSED.**

| Issue | State 2026-08-21 | Last activity | Comments | What changed |
|---|---|---|---|---|
| `anthropics/claude-code#66987` | **CLOSED** | 2026-08-13T16:09:48Z | 2 | **Fixed upstream.** Mike closed it having re-run the controlled matrix on Claude Code 2.1.231 and **bisected the fix to 2.1.205**. It was OPEN at every prior derivation |
| `anthropics/claude-code#73961` | **CLOSED** | 2026-08-13T16:08:43Z | 1 | **Fixed upstream.** The Windows regression that had blocked the native tier from starting at all. It was OPEN with zero comments at the 2026-08-12 derivation |
| `anthropics/claude-code#86936` | **OPEN** | 2026-08-18T18:12:08Z | 2 | **MAINTAINER-REPRODUCED.** `bcherny` confirmed it 2026-08-18 on Claude Code 2.1.234 **on Linux** -- so the defect is **not Windows-specific**, which corrects this project's own Windows-derived report |
| `anthropics/claude-plugins-official#1359` | **OPEN** | 2026-08-13T16:10:59Z | 4 | Still open. Comment count rose from 3 to 4 |
| `anthropics/claude-code#74289` | **OPEN** | 2026-08-13T18:32:37Z | 2 | Still open. Both comments are the maintainer's own current-version re-test and its correction |
| `anthropics/claude-code#86551` | **OPEN** | 2026-08-13T23:54:28Z | 0 | Still open, **zero comments** -- no upstream response since filing |

**The upstream picture is materially better than at any prior derivation, and it is still not
clear.** Two of the gating defects are fixed. But the native-serve lane is **not** un-gated by
that: `#86936` is a different registrar defect, it is still open, and it independently suspends the
`${user_config.*}` configuration transport the shim depends on. A reader should not conclude from
the two closures that the lane has moved.

**What upstream responsiveness now looks like, stated plainly.** At the 2026-08-12 derivation the
honest summary was that **no** issue had ever drawn an upstream reply. That is no longer true:
`#86936` drew a maintainer reproduction within three days of filing. It remains true of the other
five.

### Write-time re-check, 2026-08-17 (dispatch 000257)

**No upstream state changed since the 2026-08-13 re-check below, and a sixth item now belongs on
this list.** The tables above and below are left as the derivations they were; this is the newer
state recorded beside them, not an edit to either. Re-derived with `gh issue view <n> --repo
<repo> --json state,title,updatedAt`, query timestamp **2026-08-17T15:13:32Z**:

| Issue | State at re-check | Last activity | Change since 2026-08-13 |
|---|---|---|---|
| `anthropics/claude-plugins-official#1359` | **OPEN** | 2026-08-13T16:10:59Z | none |
| `anthropics/claude-code#66987` | **CLOSED** | 2026-08-13T16:09:48Z | none |
| `anthropics/claude-code#73961` | **CLOSED** | 2026-08-13T16:08:43Z | none |
| `anthropics/claude-code#74289` | **OPEN** | 2026-08-13T18:32:37Z | none |
| `anthropics/claude-code#86551` | **OPEN** | 2026-08-13T23:54:28Z | none |
| `anthropics/claude-code#86936` | **OPEN** | 2026-08-15T15:54:30Z | **new to this list** |

**#86936 is the sixth**, filed 2026-08-15 and not present in either table above: Claude Code's
LSP loader interpolates `${user_config.*}` against stored options only, so one unset declared key
makes it discard every server the plugin declares. It is the gate on the serve-transport
suspension recorded in section 6 and in `Get-ServeTransportSuspension`; its internal record is
[`docs/upstream/claude-code-lspservers-userconfig-defaults.md`](../upstream/claude-code-lspservers-userconfig-defaults.md).

**#1359 still gates native serve**, unchanged: it remains open with no upstream-side movement
since 2026-08-13, so the `nativeServe = shim` workaround stays load-bearing -- and, per section 6,
that shim's own configuration transport is now separately suspended behind #86936.

### Write-time re-check, 2026-08-13 (dispatch 000235)

**Two of the four have since closed, and every one of them moved on 2026-08-13.** The table above
is left as the derivation it was; this is the newer state recorded beside it, not an edit to it.
Re-derived with `gh issue view <n> --repo <repo> --json
number,state,stateReason,createdAt,updatedAt,closedAt,title,comments`, query timestamp
**2026-08-14T01:33:51Z**:

| Issue | State at re-check | Last activity | Comments | Change since 2026-08-12 |
|---|---|---|---|---:|
| `anthropics/claude-plugins-official#1359` | **OPEN** | 2026-08-13T16:10:59Z | 4 | still open; one new comment |
| `anthropics/claude-code#66987` | **CLOSED** (`COMPLETED`) | 2026-08-13T16:09:48Z | 2 | **closed** |
| `anthropics/claude-code#73961` | **CLOSED** (`COMPLETED`) | 2026-08-13T16:08:43Z | 1 | **closed** |
| `anthropics/claude-code#74289` | **OPEN** | 2026-08-13T18:32:37Z | 2 | still open; two new comments |

**#1359 is the one that still gates native serve.** It is the client-side handling of the
server-to-client requests PSES sends during initialization, and it remains open, so the
`nativeServe = shim` workaround stays load-bearing. The two that closed are the registration-side
defects: #66987 (the registrar silently dropping `lspServers` entries) and #73961 (a bare command
refused pre-spawn on Windows).

**A fifth item was filed on 2026-08-13 and is recorded here for completeness**, since it is not in
the table above: `anthropics/claude-code#86551` -- **OPEN**, filed 2026-08-13T23:53:22Z, last
updated 2026-08-13T23:54:28Z, 0 comments; Windows statusline `pwsh.exe` processes never exit. Its
internal record is [`docs/upstream/claude-code-statusline-pwsh-leak.md`](../upstream/claude-code-statusline-pwsh-leak.md).

What each blocks, from the issue titles as returned by the live query:

- **#1359** -- the Claude Code LSP client does not handle three server-to-client requests, which
  breaks solution loading; the maintainer's comment records that the same defect and the same
  proxy-shim workaround generalize to PSES.
- **#66987** -- plugin `lspServers` entries declaring `restartOnCrash` or `shutdownTimeout` are
  silently dropped by the LSP registrar; schema-valid, no diagnostic emitted.
- **#73961** -- on Windows, a plugin `lspServers` bare command is refused pre-spawn as "not found
  or is in an unsafe location (current directory)".
- **#74289** -- the `/plugins` "Configure options" panel corrupts on Windows on first navigation
  keypress; **and** enum-style options have no picker. The issue body carries the enum/select
  `userConfig` request as an explicit "Second, separate defect" section plus suggested fix (c).
  This is what section 4's all-strings finding traces to.

### Adjacent upstream item (PowerShell Editor Services)

Re-derived live 2026-08-12 for completeness, since `docs/upstream/` carries claims about it:

| Item | Live state | Derivation |
|---|---|---|
| `PowerShell/PowerShellEditorServices#2297` | **CLOSED** (`stateReason: COMPLETED`), updated 2026-06-11T14:43:51Z | `gh issue view 2297 --repo PowerShell/PowerShellEditorServices` |
| `PowerShell/PowerShellEditorServices#2299` (the PR) | **CLOSED, never merged** (`mergedAt: null`), closed 2026-06-11T14:36:23Z | `gh pr view 2299 --repo PowerShell/PowerShellEditorServices` |

### Repository issue and PR surface

| Item | Value | Derivation |
|---|---|---|
| Open issues on `manderse21/claude-powershell-lsp` | **0** | `gh issue list --state open --limit 30`, 2026-08-12 |
| Open pull requests | **0** | `gh pr list --state open --limit 20`, 2026-08-12 |

## 8. Technical debt

- **Two similarly named trust documents exist.** `TRUST.md` at the repository root (334 lines,
  19,994 bytes, 4 commits all-time, last `a6c129d` 2026-07-30) is the security and trust *posture*.
  `docs/trust.md` (106 lines, 5,821 bytes, 2 commits all-time, last `9eab1b4` 2026-07-30) is the
  release-provenance chain, "Why trust this release". Both are tracked at `origin/main`. The names
  differ only by case and directory.
- **The shim is load-bearing for native serve.** `nativeServe = shim` is the only working native
  path (section 6), and its removal is contingent on an upstream fix. The "no movement in 37 days"
  reading this entry carried at derivation no longer holds -- the write-time re-check in section 7
  records movement on every one of those issues on 2026-08-13, two of them closing -- but the issue
  that actually gates serve, `#1359`, is still open, so the shim stays load-bearing.
- **Knob type validation lives in plugin code rather than in the manifest.** All 20 knobs are
  strings (section 4), so type and enum enforcement is run-time and local.
- **`docs/paper/` ships two binary Office documents** -- `Stated_Shipped_Violated_Repaired.docx`
  (210,407 bytes) and `Evidence_and_Revision_Audit_Supplement.docx` (15,318 bytes), both last
  committed `9522e4d` 2026-08-05. Binary artifacts in a text repository are not diffable by any
  gate in the tree. **Not edited by this dispatch.**

## 9. Documentation debt

Sizes derived 2026-08-12 at `origin/main`.

| Document | Lines | Bytes | Last commit |
|---|---:|---:|---|
| `docs/decision-ledger.md` | 2,678 | 279,042 | `fef0048` 2026-08-10 |
| `CHANGELOG.md` | 2,834 | 213,471 | `3a72412` 2026-08-10 |
| `README.md` | 563 | 39,544 | `6d8ca0d` 2026-08-09 |
| `CONTRACT.md` | 439 | 31,727 | `4eabd7c` 2026-07-30 |
| `docs/RELEASING.md` | 476 | 31,008 | `5b441aa` 2026-08-10 |
| `docs/configuration.md` | 525 | 30,260 | `43cb2b3` 2026-07-31 |
| `TRUST.md` | 334 | 19,994 | `a6c129d` 2026-07-30 |
| `docs/benchmarks.md` | 291 | 17,796 | `4c6535d` 2026-08-08 |
| `ROADMAP.md` | 162 | 10,929 | `5b441aa` 2026-08-10 |
| `docs/CONTINUITY.md` | 139 | 8,027 | `a4e3455` 2026-08-10 |
| `ARCHITECTURE.md` | 111 | 7,594 | `3718a5b` 2026-06-24 |
| `CONTRIBUTING.md` | 125 | 6,731 | `a84654d` 2026-06-28 |
| `SECURITY.md` | 127 | 6,456 | `9c7df9c` 2026-06-26 |
| `docs/trust.md` | 106 | 5,821 | `9eab1b4` 2026-07-30 |
| `MAINTAINERS.md` | 88 | 4,882 | `24bbf6e` 2026-07-19 |

Recorded facts about this set:

- The decision ledger and the CHANGELOG together are **492,513 bytes**, which is 84% of the
  combined size of every document in the table.
- **`ARCHITECTURE.md` is the oldest document in the set** at 2026-06-24, 49 days before this
  derivation, and the only one predating July.
- **`docs/upstream/` carries nine files whose status text is not gate-guarded** -- the eight
  present at this derivation, plus the `claude-code#86551` record added 2026-08-13. The four
  contradictions section 13 itemized have since been corrected (dispatch 000224,
  manderse21/claude-powershell-lsp#148, merge `cfd2409`); what remains true is that no gate stops
  the next one.

## 10. Evidence and measurement gaps

**Dogfood accrual state, derived from the local logs on this machine, as of
2026-08-12T09:19:35-04:00.** Every path below was enumerated and read successfully; **nothing in
this section is a could-not-read**. Where a file is reported absent, it was searched for and does
not exist -- which is a different fact from a file that exists and is empty, and is labelled as
such.

### Capture log (`diagnostics.jsonl`)

**Re-derived 2026-08-21**, by enumerating every `dogfood` directory under
`~/.claude/plugins/cache` plus the dev clone.

| Data root | Rows | Bytes | Last written |
|---|---:|---:|---|
| `claude-powershell-lsp/dogfood/` (dev clone) | **10,161** | 5,279,427 | 2026-08-18 15:07 |
| `~/.claude/plugins/cache/.../powershell-lsp/1.23.1/dogfood/` | 34 | 18,364 | 2026-07-25 12:34 |
| `.../1.29.0/dogfood/` | 15 | 7,154 | 2026-08-07 13:45 |
| `.../1.29.1/dogfood/` | 6 | 3,069 | 2026-08-08 14:00 |
| `.../1.30.0/dogfood/` | 5 | 6,801 | 2026-08-12 16:53 |
| `.../1.31.0/dogfood/` | 234 | 123,647 | 2026-08-12 16:42 |
| `.../1.31.1/dogfood/` | 1 | 544 | 2026-08-15 21:34 |
| `.../1.31.2/dogfood/` | 7 | 3,644 | 2026-08-19 12:56 |
| `.../1.32.0/dogfood/` | 1 | 515 | 2026-08-21 21:04 |
| **Installed-cache subtotal (8 version roots)** | **303** | | |

A `1.31.0` cache root now **does** exist (234 rows) -- the previous derivation recorded its absence,
and that has resolved simply by the release being installed and used.

> ### FOUR CACHE ROOTS FROM THE PREVIOUS TABLE ARE GONE, AND 150 ROWS WITH THEM
>
> The 2026-08-12 table listed roots for `1.27.1` (81 rows), `1.27.3` (25), `1.28.0` (9) and
> `1.28.1` (35). **None of those directories exists on 2026-08-21.** The plugin cache evicts old
> version directories, and the capture log lived inside them.
>
> **150 rows of real captured diagnostics were destroyed by a routine cache eviction**, and nothing
> recorded that it happened. The subtotal still went *up* -- 209 to 303 -- which is exactly why this
> is worth stating: a rising total concealed a permanent loss, and only comparing against a dated
> prior enumeration reveals it. This is the accrual-fragmentation hazard that has been noted
> repeatedly as "captures fragment across upgrades", now measured as **captures are LOST across
> upgrades**, which is a materially worse claim.
>
> **This is the defect that threat-model finding T2.3's fix closes as a side effect.** The capture
> log now writes under `CLAUDE_PLUGIN_DATA`, which carries no version segment and is not evicted
> with a cache directory. The relocation was chartered to stop the plugin tree being written at
> runtime; preserving the rule-curation corpus across upgrades is the larger practical benefit, and
> it was not the stated reason for the change.
>
> **The data-root log does not exist yet** (checked 2026-08-21: no `dogfood/` under the plugin data
> root). That is expected and is not a defect -- the fix is on a branch and has not shipped to an
> installed build. The next derivation should find it, and should find the cache roots frozen at
> the row counts above.

### Annotations (`annotations.jsonl`)

**ABSENT at every root searched -- zero files found.** Searched: all nine `dogfood` directories
above, plus a recursive sweep of `claude-powershell-lsp/`, `~/.claude/plugins/`, and the plugin
data root. This is absence, not emptiness: no annotations file exists anywhere on this machine.

### Lifecycle family (`lifecycle-*.jsonl`)

Data root: `~/.claude/plugins/data/powershell-lsp-claude-powershell-lsp/logs/`. **Note this is a
different root from the capture log** -- a recursive search was required to find it, and a sweep of
the `dogfood` directories alone reports zero.

| Fact | Value |
|---|---:|
| Files | **8** |
| Total rows | **12** |
| Earliest | `lifecycle-20260802-070007-318.jsonl` |
| Latest | `lifecycle-20260810-122748-134.jsonl` |

Per-file rows: 2, 1, 3, 1, 1, 1, 2, 1.

### What this means for the derived metrics

`scripts/rule-efficacy-ledger.ps1:10-18` names which log each derived metric reads. Cross-referencing
that header against the accrual above:

| Metric | Source log | Input available |
|---|---|---|
| `fired_count` | `diagnostics.jsonl` | 8,809 rows total across all roots |
| `distinct_shapes` | `diagnostics.jsonl` | same |
| `verdict_distribution` | `annotations.jsonl` | **none -- the file does not exist anywhere** |
| `fixed_next_turn_rate` | `lifecycle-*.jsonl` | **12 rows** |
| `persistence_rate` | `lifecycle-*.jsonl` | **12 rows** |

The measurement machinery ships and runs; three of its five derived metrics rest on either zero
rows or twelve.

### Other evidence facts

- The efficacy ledger's provenance floor is **retained-window-relative** and rises as
  `session-start.ps1`'s `Invoke-LogSweep` trims the lifecycle family to `keepLastN` (default 10).
  Recorded in `ROADMAP.md:47-55` and in the decision ledger's Arc A section.
- The corpus false-positive bar (section 5) is recomputed on every CI run, so it is the one
  evidence claim in this document that cannot silently age.

## 11. Enterprise-readiness gaps

Recorded as observed state, with no remedy proposed.

- **Policy distribution has a knob and no mechanism.** `orgPolicy` ships as one of the 20
  `userConfig` strings; `ROADMAP.md:109-111` records fleet rollup and policy distribution as
  deferred and demand-paced. Nothing in the tree distributes or aggregates policy.
- **Allow-listing guidance ships but is not carried into the planning bundle.** `TRUST.md` sections
  "Allow-listing on managed Windows", "AppLocker (paste-ready Script rule)", "WDAC / App Control
  (paste-ready rule generation)", and "Reading App Control / Defender block events" exist at the
  repository root. Until this dispatch, the hub's PK configuration declared `docs\trust.md` and not
  root `TRUST.md`, so none of that reached a planning bundle (closed in the hub by this dispatch;
  see section 13).
- **Scale behavior is uncharacterized.** `ROADMAP.md` records the performance harness and
  very-large-repo behavior as deferred and on-demand. No large-repo measurement exists in
  `docs/benchmarks.md`, whose measurements are per-edit round-trips at n=30. **Re-derived unchanged
  2026-08-21** in substance -- but [`SLO-BASELINES.md`](SLO-BASELINES.md) now carries a two-point
  file-size curve (219 bytes and 251,523 bytes) with adopted SLOs over it, so "uncharacterized" is
  narrower than it was: what is missing is the *repository* scale dimension, not the per-file one.
- **Windows is the platform with the most open upstream defects.** **Re-derived and now QUALIFIED,
  2026-08-21.** Of the issues still open in section 7, `#74289` and `#86551` carry
  `platform:windows`. The headline claim is weaker than it was for two reasons: both
  Windows-labelled defects that gated the native tier (`#66987`, `#73961`) are now **closed**, and
  the one live registrar defect (`#86936`) was **reproduced by a maintainer on Linux**, which
  establishes it is not Windows-specific despite carrying that label. The label set now overstates
  the Windows concentration rather than understating it.
- **Offline / air-gapped installation is no longer a gap.** Added 2026-08-21. The previous
  derivation predates R2-15: an airgap bundle now ships as a release asset
  (`powershell-lsp-airgap-1.32.0.zip`, 34,573,424 bytes, section 4) with layered artifact sources
  feeding the existing pin check. This closed the item a corporate-IT review had ranked as the top
  tractable adoption blocker, and is recorded here so the gap list does not carry a resolved item.
- **Single-maintainer disclosure and support model.** Security fixes are provided for the latest
  release only; disclosure runs through GitHub private vulnerability reporting
  (`VERIFICATION_SURFACE.md` "Trust / legal leaves", sourced from `SECURITY.md`).

## 12. Human and governance gaps

- **Catalog submission state is not derivable by any query, and is not recorded in this document.**
  `ROADMAP.md:84-90` states the rule directly: submission goes through a Console form invisible to
  the API, a query cannot answer the question, and acting on one has already produced a duplicate
  once. **No catalog or API query was run for this dispatch**, and no submission state is asserted
  here. This is maintainer-held knowledge.
- **Five gates are human-only:** accept, merge, the `verified` flip, tag, and the
  product/positioning/sequencing calls (`ROADMAP.md:159-162`).
- **Bus factor is single-person**, with the Apache-2.0 continuity path documented in
  `docs/CONTINUITY.md` (`ROADMAP.md:133-134`).
- **Upstream posting is maintainer-gated.** `docs/upstream/claude-code-userconfig-enum.md` states
  that filing is Mike Andersen's gate and that no agent files, comments on, or transmits anything
  upstream.

## 13. Items current documents describe incorrectly

**This section is the result of a search that was actually run, not an assumption.** Every claim in
`docs/upstream/` that names a state was compared against the live queries in section 7 on
2026-08-12. Four discrepancies were found. **Per that dispatch's scope, `docs/upstream/` was NOT
edited; they were recorded for a later true-up.** That true-up has since landed: dispatch 000224
(manderse21/claude-powershell-lsp#148, merge `cfd2409`) corrected all four, and each of those files
now opens with a dated "Status re-derived ... via `gh`; live state wins over this file" line. The
table below is retained as the finding it was, not as a live defect list.

| # | Document | What it says | What is true (derivation) |
|---|---|---|---|
| 1 | `docs/upstream/sitting-closeout.md:7` | PR #2299 `state=OPEN` (verified 2026-06-10) | **CLOSED, never merged**, closed 2026-06-11T14:36:23Z (`gh pr view 2299`, 2026-08-12) |
| 2 | `docs/upstream/sitting-closeout.md:8` | #66987 title is "Plugin-provided LSP servers inert: LspServerManager init-ordering bug (consolidates #14803, #16291, #29858)" | The issue was **rewritten 2026-07-06**; its live title is the registrar-drop title in section 7 (`gh issue view 66987`, 2026-08-12) |
| 3 | `docs/upstream/pses-2297-pr.md:3` | "**Status:** PR-READY, **NOT SUBMITTED**" and "Nothing has been submitted, commented, or posted upstream" | It **was** submitted as PR #2299 and is now closed unmerged; issue #2297 is CLOSED/COMPLETED (live queries, 2026-08-12) |
| 4 | `docs/upstream/claude-code-userconfig-enum.md:3` | "**What this is: a POST-READY DRAFT, UNPOSTED**" | The **substance is already filed**: `#74289`'s body carries the enum/select `userConfig` ask as an explicit "Second, separate defect" section and as suggested fix (c). The file carries **zero cross-reference to #74289** (`git grep 74289` at `origin/main` returns hits only in `docs/decision-ledger.md`, lines 1737 and 2337) |

Two of these are partially recorded elsewhere already: `docs/decision-ledger.md:1737-1744` states
that #2297/#2299 is settled and explicitly names `docs/upstream/pses-2297-pr.md` and
`sitting-closeout.md` as superseded. That supersession note covers discrepancy 3 but **not**
discrepancy 2 (the stale #66987 title), which is recorded here for the first time.

### Re-run 2026-08-21 (dispatch 000269): the same search, and it found two more

The 2026-08-12 pass is preserved above as the finding it was. **The search was re-run at this
derivation rather than assumed to still hold**, because the whole point of the section is that
`docs/upstream/` labels drift -- and a drift register that is not itself re-derived becomes the
thing it warns about.

**Two live discrepancies were found, and both were corrected in the same dispatch** (unlike the
2026-08-12 pass, whose scope forbade editing those files):

| # | Document | What it said | What is true (live `gh`, 2026-08-21) |
|---|---|---|---|
| 5 | `claude-code-lsp-registration.md`, `pull-feature-gating-probe.md`, `sitting-closeout.md` -- **three files** | `#66987` is **OPEN** ("the issue remains OPEN"; live-table row `**OPEN**`) | **CLOSED.** Fixed upstream, bisected to Claude Code **2.1.205**, closed 2026-08-13T16:09:48Z |
| 6 | `claude-code-lspservers-userconfig-defaults.md` | `#86936` OPEN, "last updated 2026-08-15T15:54:30Z", no comments recorded | Still **OPEN**, but last updated **2026-08-18T18:12:08Z** with **2 comments**, including a **maintainer reproduction on Linux** that establishes the defect is not Windows-specific |

**Discrepancy 5 is the shape this section exists to catch.** Three separate documents carried the
same stale status, because each had copied it from the others rather than from `gh`. The correction
had to be made in three places, and the "live state wins over this file" header that dispatch
000224 added to each is what made them findable.

**Every one of the ten `docs/upstream/` notes now carries a `2026-08-21` re-derivation stamp**, so
the eight that were unchanged say *checked and unchanged* rather than being silently older than the
two that moved. The four PSES items were re-verified against live `gh` and are unchanged: #2297 and
#2300 CLOSED/COMPLETED, PR #2296 MERGED (merge commit `40cf5e1e...`), PR #2299 CLOSED with a null
`mergedAt`.

> **One check-design note, recorded because it cost a false positive.** The gate that verifies no
> file still claims `#66987` is open initially flagged `sitting-closeout.md` -- and the hit was the
> **quoted before-text inside the correction that fixed it**. A scan for stale wording will always
> trip over the record of its own repair, so the exemption requires two markers. The retained
> 2026-06-10 historical snapshot in that same file, which legitimately records `state=OPEN` as
> history, is deliberately left untouched.

### One hub-side correction, and one premise nuance

- **The PK carry gap for root `TRUST.md` was real and is now closed.** The hub's
  `tools/pk/pk-projects.psd1` declared `docs\trust.md` and not root `TRUST.md`, so the security
  posture document never reached a planning bundle. Root `TRUST.md` is now a declared companion
  (`plugin--TRUST.md`); the companion count moved 33 -> 34, verified by re-parsing the file under
  Windows PowerShell 5.1 with `Import-PowerShellDataFile`.
- **Premise nuance, recorded rather than passed over.** The charter's stated reason for the gap was
  that `projects/powershell-lsp/VERIFICATION_SURFACE.md` references root `TRUST.md`. On disk it
  does **not**: its "Trust / legal leaves" section names `SECURITY.md`, `THIRD-PARTY-LICENSES.md`,
  and `LICENSE` as its sources, and no section cites root `TRUST.md`. The **omission itself** was
  independently confirmed, so the gap and its closure stand; only that supporting clause was
  imprecise. Root `TRUST.md` *is* named as a load-bearing evidence surface by `ROADMAP.md:153`
  ("What the plugin runs, downloads, and never does").

### Documents checked and found accurate at derivation

Recorded so that absence of a finding is a search rather than a silence:
`docs/upstream/claude-code-lsp-registration.md` states #1359 open, #66987 OPEN with the post-rewrite
framing, and #73961 open -- all three matched the live queries in section 7 on 2026-08-12.

**Two of those three have gone stale since.** The write-time re-check in section 7 finds #66987 and
#73961 both **CLOSED**, so that file's open-state text for both is now wrong. It was deliberately
**not** edited here -- dispatch 000235's `docs/upstream/` scope was the `#86551` addition only -- and
is recorded as the finding it is. It is the same silent-drift class section 9 names: a file found
accurate on one date is not a file that stays accurate.

## 14. Old-horizon items already overtaken

- **The catalog-submission framing on `ROADMAP.md` is already corrected.** It previously appeared
  under "What is next" as "the queued next external action"; it now appears as an explicit
  non-item with the do-not-infer rule attached (`ROADMAP.md:84-90`).
- **Both Arc A design questions are adjudicated, not open.** Whether the closed-loop "cleared"
  signal must be persisted per rule (answer: it is, in a sibling log), and whether the union read
  should ever filter (answer: it never does) -- both closed as rulings rather than deferrals
  (`ROADMAP.md:24-45`).
- **The provenance-floor wording follow-up is closed**, having shipped with the surfacing work in
  the 000216 span (`ROADMAP.md:53-55`, commit `fcfbf31` 2026-08-09).
- **The doctor lane carries no open ruling.** Its last survey candidate -- surfacing
  security-classifier verdicts in the doctor -- is declined-final as of dispatch 000220
  (`ROADMAP.md:76-82`).
- **Eleven doc-set re-audit verdicts and the V10 stamp are all classified.** None remains unknown.
  Seven are shipped, four declined, one superseded; the twelve-row table with per-row sources is
  carried in the 000221 outbox in the strategic-dispatch hub. Of these, four were executed by the
  parallel hub stream after the powershell-lsp-side audit: V2 by dispatch 000295, and V5, V10, and
  the V4 cite correction by dispatch 000293.
- **`ROADMAP.md` points at `docs/upstream/` as the answer to "Upstream issues and their
  status".** On 2026-08-12 that surface carried the four discrepancies in section 13, so the
  pointer resolved to text that disagreed with the live queries in section 7. Both ends have moved
  since: dispatch 000224 corrected the four files, and dispatch 000230 rewrote `ROADMAP.md` -- which
  is why the line anchor this bullet used to carry has been dropped rather than renumbered.
