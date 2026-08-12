# powershell-lsp -- canonical current state

**What this document is.** The factual baseline Roadmap II plans against. It records what is true
on disk and on the live services at the derivation moment, and nothing else. It **proposes no
solutions, recommends no work, and contains no roadmap prose** -- those belong to R2-02 and later.

**How to read a figure here.** Every count, size, and state below carries its derivation reference
and date inline, because a bare number in a planning document ages into a false claim. Where a
figure was expected from the planning side, it was **confirmed or refuted against disk**, never
restated. Nothing in this file is asserted from memory.

**Derivation moment.** Repository facts derived 2026-08-12 from the plugin repo at
`origin/main`; live-service facts carry their own query timestamps.

---

## 1. Current version

| Fact | Value | Derivation |
|---|---|---|
| Latest release tag | `v1.31.0` | `git tag --list 'v*' --sort=-v:refname` and `git for-each-ref --sort=-creatordate refs/tags`, 2026-08-12 -- both agree |
| Tag object type | annotated (`tag`), object `42b27b396d6a3c9014581f4fda6483a982b90db6` | `git rev-parse refs/tags/v1.31.0`, 2026-08-12 |
| Tag creation date | 2026-08-10T19:01:39+0000 | `git for-each-ref --format='%(creatordate:iso8601)'`, 2026-08-12 |
| `plugin.json` version at `origin/main` | `1.31.0` | `git show origin/main:.claude-plugin/plugin.json`, 2026-08-12 |
| `plugin.json` version at the peeled tag | `1.31.0` | `git show e84c44ba...:.claude-plugin/plugin.json`, 2026-08-12 |
| `marketplace.json` version at `origin/main` | `1.31.0` | `git show origin/main:.claude-plugin/marketplace.json`, 2026-08-12 |
| `marketplace.json` version at the peeled tag | `1.31.0` | `git show e84c44ba...:.claude-plugin/marketplace.json`, 2026-08-12 |

The two manifests are in lockstep at both refs. No version drift exists between `main` and the
released artifact as of the derivation moment.

## 2. Current commit

| Fact | Value | Derivation |
|---|---|---|
| `origin/main` tip | `a82716d2bbfe9545e2daf3a39b74ead3242e0209` | `git rev-parse origin/main`, 2026-08-12 |
| `v1.31.0` **peeled** commit | `e84c44ba0ab06a751672652a10752aca6078b94e` | `git rev-parse 'refs/tags/v1.31.0^{}'`, 2026-08-12 |
| `main` relative to the peeled tag | **5 ahead, 0 behind** | `git rev-list --left-right --count 'refs/tags/v1.31.0^{}...origin/main'` -> `0	5`, 2026-08-12 |

**Both planning-side expectations were CONFIRMED, not restated.** The planning session's reads on
2026-08-12 recorded `main` at `a82716d2` and `v1.31.0` peeling to `e84c44ba`; both re-derive
identically here.

The five commits by which `main` leads the release tag, oldest last
(`git log 'refs/tags/v1.31.0^{}..origin/main'`, 2026-08-12):

| Commit | Subject |
|---|---|
| `a82716d` | Merge pull request #145 from manderse21/dispatch/000220-final-pre-horizon-close-out |
| `fef0048` | 000220: correct the LEGACY_CAP claim -- the identifier is gone entirely |
| `5b441aa` | 000220: ratify both open rulings, record the check contract |
| `831d82e` | Merge pull request #144 from manderse21/dispatch/powershell-lsp-000219-verify-v1-31-0 |
| `69f2ce3` | 000219: true the ledger to v1.31.0, verified at the 000161 standard |

All five are documentation and decision-ledger commits. No executable change separates `main` from
the released artifact.

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

All figures derived at `origin/main` (`a82716d2`), 2026-08-12.

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

### v1.31.0 release assets

Queried via `gh api repos/manderse21/claude-powershell-lsp/releases/tags/v1.31.0`,
2026-08-12T13:05Z. Release published 2026-08-10T19:01:43Z; not a draft, not a prerelease.

| Asset | Size (bytes) | Digest listed by the API |
|---|---:|---|
| `powershell-lsp-1.31.0.cdx.json` | 2,524 | `sha256:6ee8a8174be559d0a0fd98099167f12c76d8d85e5aafe777e36f76bc6678170d` |
| `powershell-lsp-1.31.0.tar.gz` | 2,372,358 | `sha256:9212b85036da13fc55a815465c573f2257a689159ae9dbd61aa9fcc722fc5b82` |

**Digest confirmation pass: both assets MATCH.** Both were downloaded fresh and re-hashed with
`Get-FileHash -Algorithm SHA256` on 2026-08-12; each re-hash equals the digest above, byte for
byte. Recorded as a confirmation, and no repair was attempted or needed.

Two facts about *where* those digests live, recorded because they differ from the usual assumption:
the digests are carried in the **GitHub release API asset `digest` field**, and the release
**body** contains no digest listing at all (checked by scanning the full body text for `sha256`,
`digest`, and any 64-hex run, 2026-08-12 -- zero matches).

## 5. Capability maturity assessment

Stated as measured facts about each capability's evidence, not as scores or grades.

| Capability | Maturity signal | Derivation |
|---|---|---|
| Warm-hook diagnostics round-trip | Measured: **median 2,228 ms, p95 2,463 ms, min 2,090, max 2,633, n=30** | `docs/benchmarks.md:36`, file last commit `4c6535d` 2026-08-08 |
| Closed-loop re-check turn | Measured: median 2,256 ms, p95 2,398 ms, n=30 -- median 28 ms (1.3%) above warm baseline while p95 is 65 ms *lower*, which the source reads as below run-to-run noise | `docs/benchmarks.md:36-47` |
| False-positive bar | Measured 0% false-positive / 100% true-positive under the default config, guarded on all four CI legs; snapshots are tool-derived, never hand-authored | `VERIFICATION_SURFACE.md` "Corpus false-positive guard" |
| Cross-platform coverage | 4 CI legs green as a release gate precondition | CI matrix; release gate 4 |
| Release provenance | Keyless signed tags, SLSA build provenance on both assets, CycloneDX 1.5 SBOM generated from the real pins | `docs/trust.md` section headings; `VERIFICATION_SURFACE.md` "Dependency pins + SBOM" |
| Native code navigation | Registration works; **serve does not on the direct path**; the opt-in `nativeServe = shim` closes it locally and ships | `ROADMAP.md:94-100` |
| Per-rule efficacy ledger | Machinery ships (`scripts/rule-efficacy-ledger.ps1`, 897 lines, last commit `e24b09b` 2026-08-09); **its input data is the gap in section 10** | file; section 10 |
| Enterprise policy distribution | One knob ships (`orgPolicy`); no distribution or rollup mechanism exists | `plugin.json` userConfig; `ROADMAP.md:109-111` |

## 6. Known limitations

Recorded from the repository's own statements and from the derivations above.

- **Serve on the direct native path does not work.** Claude Code's LSP client rejects the
  server-to-client requests PSES sends during initialization. The shipped `nativeServe = shim`
  is a workaround, not a fix (`ROADMAP.md:94-100`).
- **A second upstream Windows defect blocks the native tier from starting at all** under some
  Claude Code versions (`ROADMAP.md:98-100`; live state in section 7).
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

**All four are open. None carries any upstream-side response.** Every "last activity" timestamp
above is the maintainer's own edit or comment, not an upstream reply. The most recent activity of
any kind across all four is 2026-07-06 -- **37 days before this derivation**.

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
  path (section 6), and its removal is contingent on an upstream fix that shows no movement in 37
  days (section 7).
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
- **`docs/upstream/` carries eight files whose status text is not gate-guarded.** Three carry text
  contradicted by the live queries in section 7; those are itemized in section 13.

## 10. Evidence and measurement gaps

**Dogfood accrual state, derived from the local logs on this machine, as of
2026-08-12T09:19:35-04:00.** Every path below was enumerated and read successfully; **nothing in
this section is a could-not-read**. Where a file is reported absent, it was searched for and does
not exist -- which is a different fact from a file that exists and is empty, and is labelled as
such.

### Capture log (`diagnostics.jsonl`)

| Data root | Rows | Bytes | Last written |
|---|---:|---:|---|
| `claude-powershell-lsp/dogfood/` (dev clone) | **8,600** | 4,481,991 | 2026-08-11 10:04 |
| `~/.claude/plugins/cache/.../powershell-lsp/1.23.1/dogfood/` | 34 | 18,364 | 2026-07-25 12:34 |
| `.../1.27.1/dogfood/` | 81 | 43,660 | 2026-07-28 12:26 |
| `.../1.27.3/dogfood/` | 25 | 10,829 | 2026-07-31 09:07 |
| `.../1.28.0/dogfood/` | 9 | 5,421 | 2026-07-31 11:57 |
| `.../1.28.1/dogfood/` | 35 | 20,048 | 2026-08-01 08:12 |
| `.../1.29.0/dogfood/` | 15 | 7,154 | 2026-08-07 13:45 |
| `.../1.29.1/dogfood/` | 6 | 3,069 | 2026-08-08 14:00 |
| `.../1.30.0/dogfood/` | 4 | 6,368 | 2026-08-10 12:43 |
| **Installed-cache subtotal (8 version roots)** | **209** | | |

**No `1.31.0` cache root exists** -- the installed cache has no directory for the current release.
Derived by enumerating every `dogfood` directory under `~/.claude/plugins/cache`, 2026-08-12.

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
- **Scale behavior is uncharacterized.** `ROADMAP.md:112-113` records the performance harness and
  very-large-repo behavior as deferred and on-demand. No large-repo measurement exists in
  `docs/benchmarks.md`, whose measurements are per-edit round-trips at n=30.
- **Windows is the platform with the most open upstream defects.** Three of the four issues in
  section 7 carry the `platform:windows` label.
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
- **Bus factor is single-person**, with the GPLv3 continuity path documented in
  `docs/CONTINUITY.md` (`ROADMAP.md:133-134`).
- **Upstream posting is maintainer-gated.** `docs/upstream/claude-code-userconfig-enum.md` states
  that filing is Mike Andersen's gate and that no agent files, comments on, or transmits anything
  upstream.

## 13. Items current documents describe incorrectly

**This section is the result of a search that was actually run, not an assumption.** Every claim in
`docs/upstream/` that names a state was compared against the live queries in section 7 on
2026-08-12. Four discrepancies were found. **Per this dispatch's scope, `docs/upstream/` was NOT
edited; these are recorded for a later true-up.**

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

### Documents checked and found accurate

Recorded so that absence of a finding is a search rather than a silence:
`docs/upstream/claude-code-lsp-registration.md` states #1359 open, #66987 OPEN with the post-rewrite
framing, and #73961 open -- all three match the live queries in section 7.

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
- **`ROADMAP.md:155` points at `docs/upstream/` as the answer to "Upstream issues and their
  status".** As of 2026-08-12 that surface carries the four discrepancies in section 13, so the
  pointer resolves to text that disagrees with the live queries in section 7.
