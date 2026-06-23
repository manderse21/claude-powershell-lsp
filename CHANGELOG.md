# Changelog

All notable changes to the `powershell-lsp` plugin are documented here.
This project adheres to [Semantic Versioning](https://semver.org/).

## Versioning

Releases follow [Semantic Versioning](https://semver.org/):

- **PATCH** (`1.1.x`) -- bug fixes and internal hardening with no user-visible
  contract change (a portability fix, a log-sweep tweak, a docs correction).
- **MINOR** (`1.x.0`) -- a new backward-compatible capability: a new `userConfig`
  knob, an added diagnostics feature, a newly CI-verified platform.
- **MAJOR** (`x.0.0`) -- a breaking contract change: removing or renaming a knob,
  rewiring the hook/registration contract, or anything that forces users to adjust
  their config or workflow.

### Pinned dependency bumps

Two external components are version-pinned. Bump either by editing a single
variable and starting a fresh session (the ensure-step re-vendors at the new pin,
keyed by a per-version marker):

| Component        | Pin variable   | File                      |
|------------------|----------------|---------------------------|
| PSES             | `$PsesTag`     | `scripts/ensure-pses.ps1` |
| PSScriptAnalyzer | `$PssaVersion` | `scripts/ensure-pssa.ps1` |

A pin bump that changes observable diagnostics behavior ships as a MINOR; a pure
security/patch re-pin with no behavior change ships as a PATCH.

## [1.14.1] - 2026-06-23

PATCH: **a cross-platform test fix -- the dogfood-review annotations-path test no longer hardcodes a
Windows `C:` drive** (dispatch 000044). The 000043 test `Get-DogfoodAnnotationsPath is annotations.jsonl
beside the log` fed the function a `C:\...` literal; off-Windows there is no `C:` PSDrive, so PowerShell
threw `DriveNotFoundException` before the assertion ran -- a deterministic failure on the `ubuntu-pwsh`
and `macos-pwsh` CI legs (357 passed / 1 failed / 5 skipped each, Windows green). **Test-only change:
nothing under `scripts/` changes** -- the tool (`review-dogfood.ps1`, `Get-DogfoodAnnotationsPath`) was
already portable; the defect was entirely the test's hardcoded input. The diagnostics surface and capture
path are byte-for-byte unchanged and the 000027 contract drift-guard stays green.

### Fixed

- **Portable annotations-path test (`tests/PowerShellLsp.Unit.Tests.ps1`).** The
  `Get-DogfoodAnnotationsPath` beside-the-log assertion now derives its log path from `$TestDrive` (a real
  per-platform temp dir) instead of a hardcoded `C:\d\dogfood\...` literal, so the same beside-the-log
  derivation runs identically on all four CI legs. Same assertion, same proof (`annotations.jsonl` sits
  beside the log) -- portable input, teeth intact, not a no-op.

## [1.14.0] - 2026-06-23

MINOR: **a dogfood review tool that fills the captured `verdict` -- turning raw capture data into the
ranked input the quality wave consumes** (dispatch 000043). The companion to the 000039 capture: it
reads `dogfood/diagnostics.jsonl`, presents each distinct diagnostic shape that still needs a verdict,
accepts one from a frozen enum, and persists it. **Additive offline tool only: nothing under `scripts/`
that the daemon or hooks run changes, and the diagnostics surface + capture path are byte-for-byte
unchanged.** It only COLLECTS verdicts; acting on them (tuning any rule) is the separate quality wave.
The 000027 contract drift-guard stays green (no new `userConfig` knob, no new status token).

### Added

- **Dogfood review/annotation tool (`scripts/review-dogfood.ps1`).** Reads the capture log, collapses
  occurrences into distinct **shapes** keyed by the capture record's existing shape-`hash` (rule id +
  normalized offending-line shape), and lets you record a **verdict** per shape. Identical diagnostics
  share one verdict (the same misfire seen many times is judged once); a re-run skips shapes that
  already carry a verdict (resumable).
- **Frozen verdict vocabulary:** `useful` / `false-positive` / `noisy` / `bad-fix` / `unsure` (a fixed
  enum, not free text; an optional one-line rationale may accompany it). This is NOT the 000027 status
  taxonomy and adds no `userConfig` knob.
- **Non-destructive, hash-keyed persistence.** Verdicts are written to a **separate sibling file,
  `dogfood/annotations.jsonl`** -- append-only, last-write-wins -- and the capture log is **never
  rewritten** (it stays immutable evidence). The annotations file lives under the already-gitignored
  `dogfood/` tree and is never committed (its free-text rationale could quote source).
- **Read-only by default, with a ranked summary.** With no write action the tool lists pending shapes
  and prints a summary -- counts by verdict, annotation coverage, and the top "actionable" rules
  (false-positive / noisy / bad-fix) ranked by occurrence count. Writing a verdict is the explicit
  action: `-Hash <hash> -Verdict <verdict> [-Rationale "..."]`, or the interactive `-Review` loop
  (guarded -- a non-interactive host falls back to the listing). `-Redact` masks snippets when sharing.

## [1.13.0] - 2026-06-22

MINOR: **release-engineering automation -- a gated release pipeline that makes a bad tag structurally
impossible, with CHANGELOG-driven notes, an SBOM, and build provenance** (dispatch 000042). Closes the
roadmap's release-automation gap (Gap C.2) and the buildable-now half of the trust-surface gap (Gap B:
SBOM + provenance). CI/CD + docs only: **nothing under `scripts/` changes**, the plugin runtime and the
diagnostics surface are **byte-for-byte unchanged**, the existing four-leg CI is untouched, and the
000027 contract drift-guard stays green. The governing principle is **automate the mechanics, preserve
the decision** -- the release is maintainer-triggered (Mike chooses when and which version); the pipeline
only makes the mechanical execution safe. Tagging stays Mike's gate.

### Added

- **Gated release pipeline (`.github/workflows/powershell-lsp-release.yml`), Gap C.2.** A new SIBLING of
  the CI workflow (not a rewrite), triggered ONLY by a manual `workflow_dispatch` -- it NEVER auto-fires
  on push or merge. Given a version, it validates four preconditions and **refuses to tag** unless ALL
  hold: (1) the target commit is merged to `main`; (2) the tag `v<version>` is free; (3) `plugin.json`
  and `marketplace.json` BOTH read the requested version at that commit (lockstep); and (4) the
  push-event CI run for that exact commit concluded `success` on every required leg (`windows-pwsh`,
  `windows-powershell`, `ubuntu-pwsh`, `macos-pwsh`). Only then does it cut and push the annotated tag
  **from the pipeline, on the validated commit** -- never a hand-typed `git tag` -- and create the
  GitHub Release. This makes a tag on an unmerged, red, wrong-version, or wrong commit **structurally
  impossible** (the failure mode that, the previous round, put a tag on the wrong tree by a fat-fingered
  manual step). A `dry_run` input validates every gate and stops without tagging, for a safe rehearsal.
  Permissions are least-privilege (`contents: read` by default; the release job adds exactly
  `contents: write` + `actions: read` + `id-token: write` + `attestations: write`); only the ephemeral
  `GITHUB_TOKEN` is used -- no PAT, no secret exposed.
- **CHANGELOG-driven release notes (`release/Get-ChangelogEntry.ps1`).** The Release body is the
  CHANGELOG entry for the released version, **extracted by the pipeline** -- single-sourced, never
  hand-retyped. The extractor refuses a version it cannot find (you cannot release what you did not
  document).
- **CycloneDX 1.5 SBOM (`release/New-PluginSbom.ps1`), Gap B.** Generated over the plugin and its two
  **pinned downloaded dependencies** -- PowerShell Editor Services (`v4.6.0`) and PSScriptAnalyzer
  (`1.25.0`) -- with versions read STRAIGHT from `scripts/ensure-pses.ps1` and `scripts/ensure-pssa.ps1`,
  so the SBOM can never drift from what the tool actually fetches. Attached to the Release. (An
  off-the-shelf directory scanner cannot see these deps, because they are downloaded at install time and
  are not in the repo tree -- hence an authored, single-sourced generator.)
- **Build-provenance attestation (Gap B), with an honest boundary.** `actions/attest-build-provenance`
  produces a verifiable SLSA-style attestation over the release source archive and the SBOM. The honest
  scope, stated rather than glossed: a git-distributed plugin has no compiled binary, so the meaningful
  artifact is the **packaged source archive** -- the attestation covers that downloadable artifact
  (verifiable with `gh attestation verify`), but NOT the `/plugin` clone-based install path, whose
  integrity rests on the git commit and tag themselves. Real provenance over a real artifact, with its
  limits documented -- not attestation theater over a non-artifact.
- **RELEASING doc (`docs/RELEASING.md`), linked from the README.** How to trigger a release, what the
  pipeline validates, what it produces, the dry-run rehearsal, how to verify a release, the provenance
  boundary, the testability boundary, and the manual fallback if the pipeline ever misbehaves.
- **Release-logic regression tests (`tests/PowerShellLsp.Release.Tests.ps1`).** Cover the CHANGELOG
  extraction (boundary-exact), the CycloneDX SBOM generation and its single-sourcing from the live pins,
  and the version-lockstep invariant the tag-gate re-checks. Run on all four CI legs.

### Notes

- **Testability boundary (stated honestly).** Everything testable WITHOUT a real release was validated:
  YAML parse + least-privilege permissions, the CHANGELOG-to-notes and SBOM logic (unit tests), the
  artifact build (`git archive` + SBOM + notes dry-run), and the green-CI gate query (simulated against
  the real main-tip push run -- job names and per-leg success detection confirmed). What ONLY proves out
  on the first real release is the end-to-end run on GitHub's servers: the attestation step (needs a
  server-issued OIDC token) and the actual tag push + release creation. The manual fallback is documented.
- **Bootstrap irony.** This 1.13.0 release is the LAST one cut the old manual way; the pipeline proves
  out on the NEXT release.

## [1.12.1] - 2026-06-22

PATCH: **test-reliability hardening -- make the 000029 licensing test deterministic** (dispatch 000041).
A flake fix with ZERO tool-behavior change: nothing under `scripts/` is modified, the diagnostics surface
is byte-for-byte unchanged, and the 000027 contract drift-guard stays green. First buildable-now piece of
the roadmap's release-engineering reliability gap (Gap C.1).

### Fixed

- **The `N_PssaDir` CI coin-flip (Gap C.1).** On the v1.11.0 push run the ubuntu-pwsh leg failed the
  000029 licensing test (`PSScriptAnalyzer module retains its MIT LICENSE + ThirdPartyNotices`) with
  `$script:N_PssaDir` resolving null; a re-run went green. Root cause (read from the failing run's log,
  not guessed): PSScriptAnalyzer WAS vendored and fully functional on that run -- every other
  PSSA-dependent test in the same run passed -- so this was never a vendoring failure. The test resolved
  the module dir with a one-shot `Get-ChildItem -Recurse -Filter ... -ErrorAction SilentlyContinue |
  Select -First 1`, and on Linux that enumeration intermittently returned empty (`SilentlyContinue`
  swallowed a transient enumeration error), turning a present, importable module into a cryptic null
  assertion. Resolution is now a bounded retry that absorbs a transient miss, and a null is classified
  honestly via the vendoring marker (`modules/.pssa-*.ok`, written by `ensure-pssa` only after a
  verified-importable install): a legitimately-unvendored environment SKIPS with a clear reason; a
  vendored-but-unresolvable one FAILS LOUD with a precise message -- never a silent coin-flip. The
  notice-preservation assertions are unchanged and keep their full teeth when the bundle is present.
- **Sweep -- a fixed-sleep shutdown assertion (same class).** The warm-start SessionEnd test asserted the
  daemon/PSES were gone after a fixed `Start-Sleep -Seconds 3`; on a slow runner that is the same
  assert-on-timed-state coin-flip. It now polls (bounded) until teardown completes before asserting the
  same final conditions -- deterministic, teeth intact.

The bounded sweep also confirmed the empty-array -> `$null` collapse class (which bit the 000040 corpus
helper) is already correctly guarded across the suite; the remaining environment-dependence (the
integration bundle download) surfaces as a clear failure, not a coin-flip.

## [1.12.0] - 2026-06-22

MINOR: **CI proof-framework -- diagnostic-correctness corpus + performance benchmark harness**
(dispatch 000040). Two CI regression guards that close the roadmap's buildable-now correctness and
release-engineering gaps (Gap A, Gap C): a corpus that proves WHAT the tool reports is correct, and a
benchmark that measures and guards HOW FAST it reports it. This is a PROOF framework: it measures and
asserts current behavior and does not change it. Nothing under `scripts/` is modified, the diagnostics
surface is byte-for-byte unchanged, and the 000027 contract drift-guard stays green.

### Added

- **Diagnostic-correctness corpus (`tests/corpus/`), Gap A.** Curated clean / known-bad-per-rule /
  parser-error PowerShell samples, each with an expected-findings snapshot DERIVED from the real tool
  (the warm PSES daemon + PScriptAnalyzer, or the in-process parser pre-pass) through the dogfood
  capture channel -- never hand-authored, never model-authored. `tests/corpus/Update-CorpusSnapshots.ps1`
  regenerates the snapshots; `tests/PowerShellLsp.Corpus.Tests.ps1` re-derives the same way and asserts
  the live tool still matches, so a behavior change is a visible, located failure. The corpus also
  records the observed fact that the tool's effective PSES default ruleset is narrower than raw
  PSScriptAnalyzer.
- **Performance benchmark harness (`tests/bench/`, `tests/PowerShellLsp.Benchmark.Tests.ps1`), Gap C.**
  Repeatably measures cold-start (SessionStart -> daemon ready) and warm-path (edit -> diagnostic
  round-trip) latency against the real daemon/pipe path, emits structured results
  (`benchmark-results.json`), and guards each median against a generous first-pass threshold (cold under
  20 s, warm under 9 s). Build-time medians: cold ~3.9 s, warm ~2.2 s (`pwsh` 7.6.3, Windows 11).
- **README.** Publishes the measured latency numbers and adds a Diagnostic-correctness corpus section.

Both halves run in CI on all four legs (windows-pwsh, windows-powershell, ubuntu-pwsh, macos-pwsh) via
the existing `tests/run-tests.ps1` auto-discovery; the benchmark numbers upload as a CI artifact.

## [1.11.0] - 2026-06-22

MINOR: **doctor daemon/pipe-health check** -- the preflight doctor (`scripts/doctor.ps1`, dispatch 000036)
gains a sixth, report-only check: is the warm per-session PSES daemon alive and answering on its named pipe
right now (dispatch 000037)? Checks 1-5 confirm the bundle is INSTALLED; this confirms the language server is
actually RUNNING, closing the "installed vs actually working" gap -- a user can pass all five static checks
and still have a dead or wedged daemon. REPORT-ONLY: the probe observes and never launches, relaunches,
repairs, or kills the daemon. No new `userConfig` knob and NO change to the diagnostics status-token taxonomy
(the doctor keeps its own pass/fail/unknown vocabulary), so the 000027 drift-guard greens with no Tier-1 change.

The probe is non-disruptive and honest about the pipe-first + auto-relaunch design. It reuses the daemon's
existing `ping` action over the same named-pipe protocol the PostToolUse client uses -- a round-trip the
daemon answers WITHOUT touching its PSES child (no analysis, no state change), so it cannot wedge the live
daemon or steal its pipe. The four-state mapping respects the 000028/000030 semantics: a daemon answering its
pipe is `PASS`; a daemon alive but parked `unavailable` / `degraded`, or alive but not answering, is a `FAIL`
with the restart remedy; NO daemon present is a benign `PASS` (one auto-relaunches on the next edit -- never a
scary FAIL); and a state that cannot be determined from outside the session (no data dir, or several live
daemons and no session id to disambiguate) is an honest `UNKNOWN`.

### Added

- **Daemon-health check (`scripts/doctor.ps1`), dispatch 000037.** New pure decision `Test-DoctorDaemon`
  (unit-tested over injected observations) plus the live probes `Get-DoctorDaemonObservation` (discovery via
  the daemon's own durable handle -- the `<data>/session/<id>.json` details file and its recorded-pid
  liveness, exactly as the SessionStart reap does) and `Test-DoctorDaemonPingProbe` (the non-disruptive
  `ping` round-trip). An optional `-SessionId` argument scopes the check to a specific session; otherwise it
  resolves `$env:CLAUDE_SESSION_ID`, then discovers the live daemon(s). Nine new unit tests cover the mapping
  (healthy / parked-unavailable / degraded / wedged / absent-but-relaunchable / no-session-context /
  ambiguous), with the daemon and pipe state mocked.

### Notes

- Claude Code passes the session id to hooks on stdin, not as an environment variable, so a standalone
  `pwsh -File scripts/doctor.ps1` cannot key the check to its own session: it discovers the live daemon(s) by
  the durable handle and is honestly `UNKNOWN` when more than one is live and none is named. Run with
  `-SessionId` (or from inside the session) for a definitive scoped check.
- A `--fix` / repair mode stays out of scope (the doctor is report-only); it is deferred to a later slice,
  gated on evidence that "restart your session" is insufficient.

## [1.10.0] - 2026-06-22

MINOR: **dogfood diagnostic capture** -- every diagnostic the plugin surfaces is now also teed to a
local, append-only JSONL log (`dogfood/diagnostics.jsonl`), one entry per occurrence, each with an EMPTY
`verdict` field reserved for later manual annotation (dispatch 000039). This starts the accumulation clock
the roadmap's quality wave (rule curation, false-positive reduction, fix-suggestion quality) needs to rank
work on REAL diagnostics from REAL usage instead of guesses. It is CAPTURE ONLY: the annotation/review tool
that consumes the verdict field is a deliberate fast-follow (next_suggested). No new `userConfig` knob and
NO change to the diagnostics status-token taxonomy, so the 000027 drift-guard greens with no Tier-1 change.

Capture is a pure, INVISIBLE side channel: it runs AFTER the diagnostics are surfaced, is fully fail-safe
(any write failure is swallowed), and writes nothing to stdout -- so what is surfaced, its order, the
timing, and the hook's exit code are byte-for-byte unchanged whether capture succeeds, fails, or is absent.
The 000026 fail-safe spine and the 000024/000028 never-silent guarantee are preserved unchanged. The log
holds REAL source snippets and is gitignored -- it must NEVER be committed.

### Added

- **Diagnostic capture tap (`scripts/lib/lsp-common.ps1`, `scripts/lsp-client.ps1`), dispatch 000039.** At
  BOTH per-diagnostic emit sites in the PostToolUse client -- the in-process parser pre-pass and the
  warm-daemon PSScriptAnalyzer path -- the surfaced occurrences are appended to the dogfood log. Each entry
  carries: ISO-8601 `ts`, `file`, `line`, `col`, `ruleId` (the PSSA rule, or empty for a parser error),
  `source` (`PSScriptAnalyzer` or `parser`), `severity`, `message`, `snippet` (the full offending line), a
  stable `hash` over the rule id + the normalized offending-line shape (analysis-time de-duplication only:
  trim + collapse interior whitespace, case preserved), and an empty `verdict`. Every occurrence is logged
  (two identical diagnostics -> two entries); there is no dedup, sampling, or rate-limiting at capture. New
  helpers `Get-DogfoodLogPath`, `Get-DiagnosticShapeHash`, `New-CaptureRecordFromDiag`,
  `New-CaptureRecordFromParseError`, and the fail-safe `Add-DiagnosticCaptureEntries`, with new unit +
  integration tests -- including the load-bearing guard: a forced capture-write failure leaves the surfaced
  block byte-for-byte unchanged and the hook still exits 0.
- **`.gitignore` (new) + README "Dogfood diagnostic capture".** The whole `dogfood/` directory is gitignored
  so no captured source snippet is ever staged, and the README documents what is captured, that it is
  local-only and never committed, that it holds real source snippets, and how the `verdict` field is used
  later.

### Notes

- The log path defaults to `dogfood/diagnostics.jsonl` in the plugin tree and can be relocated with the
  `POWERSHELL_LSP_DOGFOOD_LOG` environment variable (also the test seam). It is NOT a `userConfig` knob.
- Capture only: the annotation/review tool that walks unannotated entries and lets you tag verdicts is the
  planned fast-follow.

## [1.9.0] - 2026-06-22

MINOR: **honest degradation on a security-control block** -- when the PSES / PSScriptAnalyzer
bootstrap fails on a managed Windows estate, the SessionStart banner now NAMES the most likely
blocking security control and the legitimate remediation instead of a generic "could not complete
(network/proxy?)" (dispatch 000038, building the 000032 L3 survey). It ENRICHES the existing
never-silent surface (000024/000028): the status stays `unavailable`, the message gets specific.
No new `userConfig` knob and NO new status token -- the four-token taxonomy is unchanged, so the
000027 drift-guard greens with no Tier-1 change (banner prose is not a frozen surface, CONTRACT.md
1.2).

The discipline is calibrated honesty: a control is NAMED only on POSITIVE EVIDENCE, never guessed.
ExecutionPolicy (Group-Policy scope) and Constrained Language Mode are cheaply and directly
queryable, so a coincident failure names them with `likely` confidence; App Control / WDAC and
Defender ASR are named `confirmed` only when a matching CodeIntegrity (3077 enforced / 3076 audit)
or Defender (1121 block / 1122 audit) event references a plugin component; Smart App Control is
reputation-gated, so it is only ever `possible` ("may be blocking ... until reputation accrues").
With no positive evidence the banner falls back to an honest diagnostic POINTER (network/proxy is
still the usual cause; here is how to check ExecutionPolicy, the language mode, and the CodeIntegrity
log) -- richer than a bare `unavailable`, never a fabricated control.

THE ABSOLUTE FENCE: the plugin DETECTS and EXPLAINS; it NEVER bypasses, disables, weakens, or
auto-modifies any control. Every remediation is INSTRUCTIONS for the user or their administrator
(allow-list, sign, adjust policy), never an action the plugin takes -- circumventing enterprise
security is exactly what gets a tool banned, so honest degradation is the entire value.

### Added

- **Security-block classifier (`scripts/lib/security-classifier.ps1`).** A pure, CLM-safe, mockable
  module: `Resolve-SecurityBlock` maps INJECTED evidence (ExecutionPolicy state, session language
  mode, Smart App Control state, CodeIntegrity / Defender block events) to the most likely control
  plus an actionable, instructions-only remediation, or an honest fallback when nothing is
  positively identified. Thin best-effort live probes gather the evidence, each independently
  fail-safe: a denied event-log permission, an absent log, a non-Windows host, or Constrained
  Language Mode degrades to "no evidence", never an exception. 27 new unit tests cover every path
  with the probes mocked.
- **Named security-block banner at SessionStart.** `scripts/session-start.ps1` now enriches the
  bootstrap-failure `additionalContext` line via the classifier. Fail-safe by construction: any
  classifier error (or a missing module) falls back to the prior generic banner, and the hook still
  exits 0 and never blocks editing (the 000026 spine is preserved).

### Notes

- Scope is L3 only (honest degradation on a block). Signing (L1), hash-verify (L2), the enterprise
  TRUST.md doc (L4), and the signed release pipeline (L5/L6) remain separate, later work.
- Wiring the 000036 doctor's generic security pointer to call this classifier is a natural follow-up
  (it depends on dispatch 000037 landing) and is intentionally NOT included here; the doctor's
  on-demand generic pointer and this SessionStart named banner remain distinct surfaces.

## [1.8.0] - 2026-06-21

MINOR: **preflight `doctor` self-check** -- a new report-only `scripts/doctor.ps1` that turns the worst
onboarding failure mode (the plugin is enabled but a prerequisite is missing, so diagnostics silently do
nothing) into a named, actionable fix-list (dispatch 000036). It is the on-demand bookend to the
000024/000028 never-silent spine: same honesty, a new entry point. Report-only by design -- it never
downloads, repairs, or runs the bootstrap. It deliberately does NOT detect security-control blocks
(WDAC / AppLocker / ExecutionPolicy / Smart App Control / Constrained Language Mode); that surface is the
separate ROADMAP L3 security track (survey 000032), so an indeterminate failure gets only one generic
pointer, with zero control-specific probing. No new `userConfig` knob and no change to the diagnostics
status-token taxonomy, so the 000027 drift-guard greens with no Tier-1 change.

### Added

- **Preflight doctor (`scripts/doctor.ps1`), dispatch 000036.** Runs an ordered set of checks and prints,
  per check, PASS / a specific failure naming the blocked component plus the remediation (tied to the
  README Requirements / Install / Troubleshooting) / an honest UNKNOWN when it genuinely cannot determine
  (for example when run outside a Claude Code session, where it cannot see the plugin data directory). The
  checks: (1) PowerShell 7 (`pwsh`) present and new enough for the hooks; (2) the plugin enabled
  (`defaultEnabled` is false); (3) the PSES bundle bootstrapped (the per-pin marker AND
  `Start-EditorServices.ps1`, the exact pair `ensure-pses.ps1` gates on); (4) PSScriptAnalyzer vendored AND
  importable; (5) the first-run download hosts reachable. Every pin, marker name, install path, and host is
  read single-source from `ensure-pses.ps1` / `ensure-pssa.ps1` (never hardcoded). Each check is a pure,
  mockable function returning a status object, unit-tested for pass / fail / unknown with the probes
  injected. Documented under README Troubleshooting. Report-only; exits non-zero only when a check FAILED.

## [1.7.0] - 2026-06-21

MINOR: **auto-relaunch the idle-stopped daemon** -- the next edit after a clean idle-stop now SILENTLY
relaunches the per-session daemon and recovers, instead of bannering "analyzer not reachable" on every
edit until the session is manually restarted (dispatch 000030). This converts the *recoverable* subset of
the 000028 no-daemon state into silent recovery, while keeping every 000028 honest banner as the fallback
for the cases that genuinely cannot recover. It builds directly on the 000028 pipe-first daemon + client
connect-fail backstop. No new `userConfig` knob; the four status tokens are unchanged (recovery reuses the
transient `incomplete` during the relaunched daemon's init window), so the 000027 drift-guard greens with
no Tier-1 change. `idleTtlMin`'s frozen meaning is unchanged -- auto-relaunch COMPLEMENTS it (free the
daemon when truly idle, bring it back exactly when active again).

### Added

- **Silent recovery of a cleanly idle-stopped daemon (dispatch 000030).** When a PostToolUse edit finds
  the daemon unreachable AND the condition is the recoverable no-daemon case, the client now silently
  relaunches the daemon -- via the EXACT pipe-first launch path SessionStart uses (extracted into a shared
  `Start-PsesDaemonDetached`) -- then reconnects within the existing hard cap. The relaunched daemon comes
  up pipe-first, so the first edit during its ~init window honestly gets the transient `incomplete`
  ("re-warming -- this edit was NOT checked"); the next edit gets real analysis. Resource hygiene is
  preserved: the daemon still self-terminates after `idleTtlMin`; it simply comes back on the next edit.

### The recoverable-vs-permanent gate (why it cannot spin)

- **The gate is structural at the pipe, not a heuristic.** The client's unreachable (`$null`) response IS
  the recoverable condition -- it means there is no daemon process at all (a clean idle-TTL self-terminate,
  a crash, or the ~150ms pre-pipe launch sliver). A PERMANENT init failure never reaches it: the 000028
  pipe-first daemon stays UP serving the reachable `unavailable` status (never `$null`), so a broken bundle
  is never relaunched. Even the edge where a broken-bundle daemon ALSO idle-stopped relaunches exactly ONCE
  and then re-parks alive serving `unavailable` (pipe-first daemons park, they do not exit-and-bounce) --
  so there is no relaunch loop, by construction.
- **Bounded: at most one relaunch per cooldown window** (a per-session stamp, ~the daemon init deadline).
  A relaunch that is suppressed by the cooldown, finds no host, or whose spawn fails ALWAYS falls back to
  the honest banner -- so the bound can only ever cost a banner, never a missed check.

### Changed

- **Backstop banner wording refined (prose-only, no token change).** After an auto-restart the client no
  longer tells the user to "start a new session" -- a relaunch in progress reads "the analyzer had stopped
  and is being restarted -- this edit was NOT checked; your next edit should be," and "could not be
  restarted automatically" appears ONLY when the relaunch genuinely failed or was suppressed. A clean pass
  still renders nothing (the byte-identical warm path).

### Invariants held

- **Never-silent (the 000022->000028 spine).** Recovery is SILENT only when it actually succeeds (and even
  then the first init-window edit honestly says "not checked yet"); a failed or suppressed recovery
  surfaces the honest banner. The only new silence is a SUCCESSFUL recovery -- correct, because the edit
  then gets analyzed.
- **The 000028 surfaces are intact.** Sub-case A (transient `incomplete`) and sub-case B (permanent
  `unavailable`, never relaunched) are unchanged; SessionStart's launch is byte-equivalent (the extracted
  `Start-PsesDaemonDetached` carries the same args + the 000026 cross-platform detachment). All prior
  suites (000022/024/025/026/027/028) stay green on all four CI legs.

## [1.6.1] - 2026-06-20

**License change only -- relicensed FORWARD from MIT to GPLv3 (`GPL-3.0-or-later`), with ZERO code
or runtime change** (dispatch 000029). Every shipped `.ps1` is byte-identical to 1.6.0; the daemon,
the diagnostics output, the four status tokens, and all four install-failure surfaces behave exactly
as before. This is a PATCH by SemVer (no API or behavior change) -- the significance is legal, and it
is carried in this entry, not in the version digit.

### Why

Publish-readiness, not monetization. GPLv3 is copyleft: anyone who distributes a modified version
must keep it open under the same terms. Plain GPLv3 (not AGPL -- the tool is 100% local) is the
deliberate fit for an open release.

### Changed

- **`LICENSE`** is now the verbatim canonical GPLv3 text, fetched from
  <https://www.gnu.org/licenses/gpl-3.0.txt> and **byte-verified** (35,149 bytes, LF, no BOM;
  SHA-256 `3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986` -- the canonical FSF
  hash). Not hand-typed or paraphrased.
- **SPDX id `GPL-3.0-or-later`** is declared consistently across the three authoritative sites:
  `LICENSE`, `.claude-plugin/plugin.json` (`license`), and this README's License section.
  (`marketplace.json` has **no** `license` field in the Claude Code marketplace schema -- the
  per-plugin license lives in `plugin.json` -- so it carries none.) A new CI **drift-guard** fails
  the build if these sites ever disagree.
- **`THIRD-PARTY-LICENSES.md`** (new) documents the two components the plugin **downloads at install
  time** (it does not bundle or redistribute them): PowerShell Editor Services and PSScriptAnalyzer,
  both MIT (Microsoft), pinned in `ensure-pses.ps1` / `ensure-pssa.ps1`. MIT is GPL-compatible; their
  notices travel inside the downloaded bundles and are neither modified nor relicensed.

### Forward-only -- prior releases stay MIT

This license change is **forward-only and does not reach backward**. **Releases v1.0 through v1.6.0
remain under the MIT license they were published with** -- that grant is irrevocable and is **not**
revoked, rescinded, or diminished here. Anyone using a v1.0-v1.6.0 release keeps their MIT rights.
This is normal and expected for a license change, not a problem. From **v1.6.1 forward** the project
is `GPL-3.0-or-later`.

### Not legal advice

This is the standard mechanical way to perform a forward license change, not legal advice. For a
serious public release, a human/legal sanity check on the exact license text and the third-party
attribution is advisable.

## [1.6.0] - 2026-06-20

MINOR: **pipe-first daemon** -- close the no-pipe silent first-edit miss, with warm-start as the
latency win riding free on the same change (dispatch 000028). This dispatch began as "warm-start"
and was reshaped under its own survey (the 000026 (A)->(B) pattern): the survey measured that the
costly PSES init is **already** eager, so warm-start's standalone win was small (~0.75s typical),
while it exposed a higher-severity correctness gap -- a first edit that raced PSES startup got
**nothing, not even a banner** (the honesty banner rides the daemon's pipe, and the pipe did not
exist until after init). The primary deliverable is now the correctness fix; warm-start is the
documented side effect. No new `userConfig` knob; the four status tokens are unchanged (the
`unavailable` **prose** is generalized -- a PATCH-level refinement per CONTRACT.md -- not a new
token).

### Fixed

- **The no-pipe silent miss (the headline -- a never-silent / could-not-X spine gap).** The daemon
  now creates its named pipe **before** bringing PSES up, then finishes PSES init **cooperatively**
  in the serve loop. A first edit that arrives while PSES is still starting -- or after PSES fails
  to start -- always reaches a daemon that answers with an **honest banner**, never the old silent
  connect-fail (`return $null` -> `exit 0`, no banner). Two cases, both previously silent:
  - **Still starting (transient):** a request during init is served `incomplete`
    ("analysis did not complete -- this edit was NOT checked"); the next edit succeeds once ready.
  - **Present but failed to start (permanent):** a bundle present but unable to initialize (startup
    failure / init timeout) -- which 000024 had deliberately left as a silent `exit 1` before the
    pipe -- now keeps the daemon **up** serving the permanent `unavailable`, never exit.
- **Client-side never-silent backstop (closes the residual no-pipe window -- so the silence fix has
  NO silence window).** Pipe-first closes the dominant ~4-13.5s PSES-init window from the daemon
  side, but the honesty banners ride the pipe -- so any case with NO pipe still had no channel: the
  brief (~150ms) sliver between the daemon process launching and it creating the pipe, and any
  session whose daemon has stopped (idle-TTL self-terminate, or the daemon process died). The
  PostToolUse client (`lsp-client.ps1`) now surfaces its OWN honest banner ("the analyzer was not
  reachable -- this edit was NOT checked ... start a new session to restart it") whenever the daemon
  is unreachable, instead of the old silent `exit 0`. Every could-not-analyze case is now visible --
  startup race, present-but-failed init, an idle-stopped daemon (previously silent), or a
  connect/read failure. Gated on the unreachable (`$null`) response, which a healthy clean pass is
  **never** (a clean result returns an ok object and still renders nothing), so the byte-identical
  warm/clean path is untouched.

### Added

- **Warm-start (the latency win, riding free).** Once PSES goes ready, the daemon drives one
  synthetic in-memory analysis so PSScriptAnalyzer loads + compiles its rule engine in the idle gap
  **before** the user's first real edit -- so that edit pays only the per-file cost, not the
  analyzer cold-start (measured ~0.77s warm / ~2.2s cold-box removed from the first edit). Always
  on, best-effort, off the request path; a failed warm just means the first edit self-warms as
  before. Proven at the state level (PSES ready + pre-warmed before the first request); timing is
  logged informationally and is **not** a CI gate (the 000026 "no flaky wall-clock proxy" lesson).

### Changed

- **`unavailable` banner prose generalized (token set unchanged).** It now covers BOTH "never
  installed (the bootstrap did not complete)" AND "installed but failed to start," and lands the
  **permanence** explicitly ("OFF for this whole session until it is fixed and the session is
  restarted") -- kept distinct from the transient `incomplete`. Per the CONTRACT.md freeze this is a
  prose refinement, not a taxonomy change: the four-token set `{ok, incomplete, degraded,
  unavailable}` is untouched and the drift-guard greens without a Tier-1 change.
- **`idleTtlMin` x warm-start reconciled** (the forward-compat note banked in CONTRACT.md, now
  closed): the idle clock starts at daemon launch and resets only on a real client request -- the
  internal pre-warm does not count -- so a never-edited session still self-terminates after
  `idleTtlMin`, whose meaning is unchanged.

### Invariants held

- The SessionStart hook stays non-blocking (000026): pipe-first only reorders what the **detached**
  daemon does, reaching "pipe open" sooner, never blocking the hook. The 000024/000026 surfacing
  tests stay green on all four legs.
- Warm vs cold diagnostics are byte-identical (latency-only): the warm happy path still renders no
  banner; the existing diagnostics tests + the 000027 drift-guard stay green.
- Supervised re-spawn (000022) is preserved: the mid-session crash path is unchanged; pipe-first
  only adds the cooperative FIRST-init path alongside it.

## [1.5.3] - 2026-06-20

PATCH: formalize the plugin's public surface as a 1.x semver contract and add a runnable CI
drift-guard. This ships a new document (`CONTRACT.md`) and a new test only -- **zero runtime
change**: every shipped script is byte-identical to 1.5.2, and the warm path, the diagnostics
output, and all four install-failure surfaces behave exactly as before. No `userConfig` knob is
added, removed, or renamed; no status token changes.

### Added

- **`CONTRACT.md` -- a two-tier 1.x semver freeze (dispatch 000027).** Tier 1 (CONTRACTUAL,
  drift-guarded): the 13 `userConfig` knob names (additive-only) and the four-token diagnostics
  status taxonomy `{ok, incomplete, degraded, unavailable}`, plus the property that `ok` renders
  an empty banner (the byte-identical warm path) while each non-ok token renders a distinct,
  non-empty, visible banner. Tier 2 (ASPIRATIONAL -- documented but **not** semver-contractual
  and **not** drift-guarded): the install-failure visibility guarantee, with the 000024/000026
  integration tests cited as its living evidence. The freeze is token-level, not prose-level
  (banner wording stays refinable under PATCH); knob names are frozen while behavior-neutral
  default re-tuning stays MINOR/PATCH and a behavior-altering default change is a MAJOR; and the
  `enableStats` stats-log format (absolute vs redacted paths) is explicitly **not** a frozen
  output field.
- **A CONTRACT.md drift-guard (extends the dispatch 000025 README Describes).** Two new Pester
  Describes assert `CONTRACT.md` freezes **exactly** the manifest `userConfig` keys and
  **exactly** the status tokens the code emits. Ground truth is extracted mechanically, live from
  source -- the manifest keys are parsed from `plugin.json`, and the status tokens are read from
  the `Get-DiagnosticsStatusBanner` switch via AST plus the clean token from calling
  `Resolve-AnalysisStatus` -- with **no** hand-maintained baseline list in the test. Adding a knob
  to the manifest or renaming a status token turns a CI leg red until both `CONTRACT.md` and the
  README record it. The README and CONTRACT guards are separate Describes, so a red leg names
  which document drifted.

## [1.5.2] - 2026-06-20

PATCH: fix a non-Windows session-startup defect (dispatch powershell-lsp/000026). On macOS and
Linux the SessionStart hook leaked its stdin/stdout/stderr handles to the detached PowerShell
Editor Services daemon, so the daemon held Claude Code's hook pipes open for the whole session.
Windows was never affected. No `userConfig` knob is added, removed, or renamed; diagnostics
output is byte-for-byte unchanged.

### Fixed

- **The detached daemon no longer inherits the SessionStart hook's standard handles on
  macOS/Linux (dispatch 000026).** On non-Windows the daemon was launched with a bare
  `Start-Process`; with no ShellExecute equivalent there, it inherited the hook's
  stdin/stdout/stderr by normal POSIX file-descriptor inheritance and held those pipes open for
  its entire lifetime. Because Claude Code's read of a SessionStart hook's stdout does not reach
  EOF while a child holds the write-end, this could **stall session startup** until the global
  hook timeout (cf. upstream claude-code #43123, affecting >= v2.1.87) -- on *every* non-Windows
  session, since the daemon launches every time -- and, in the clean-box install-failure case,
  it dropped the `additionalContext` "diagnostics unavailable" banner that dispatch 000024 added.
  The daemon's three standard streams are now redirected to per-launch files (stamped, retired by
  the existing log sweep) so it no longer holds the hook pipes. Windows is unchanged: there
  `-WindowStyle Hidden` routes the launch through ShellExecute, which structurally does not pass
  inheritable handles to the child. The load-bearing first-edit surface (the daemon-served
  `unavailable` on the PostToolUse channel) was never affected and stayed green on all platforms.
- **The dispatch 000024 SessionStart-surfacing integration test now passes on all four CI legs**
  (macos-pwsh, ubuntu-pwsh, windows-pwsh, windows-powershell). It had been correctly red on the
  two non-Windows legs since 000024 -- it was catching this defect, not a fixture flake.

## [1.5.1] - 2026-06-20

PATCH: docs-honesty and diagnosability hardening with no user-visible behavior change
(dispatch powershell-lsp/000025, closes the 000023 launch-readiness audit's backlog #3,
#4, and #7). Diagnostics output is byte-for-byte unchanged; the only value that moves on
the wire is a stale version label, now corrected. No `userConfig` knob is added, removed,
or renamed.

### Fixed

- **Three stale, drifted host-version literals now read the real plugin version from one
  source (dispatch 000025, 000023 audit S1b).** `pses-stdio.ps1` (was `1.0.0`),
  `pses-daemon.ps1` (was `1.1.0`), and the LSP `clientInfo.version` in `lsp-common.ps1`
  (was `1.1.0`) reported versions that had not tracked the plugin since early releases, and
  `bump-version.ps1` did not touch them. A new `Get-PluginVersion` reads
  `.claude-plugin/plugin.json` at runtime (cached, off the hot path), so every stamp now
  reflects the manifest and can never go stale again -- not even on a hand-edit that
  bypasses the bump helper. The same one-place-for-one-fact principle as the 000023 M1
  decorative-constant finding.

### Added

- **Plugin version in the daemon startup log (dispatch 000025, 000023 audit S1a).** The
  daemon start banner now reads `powershell-lsp <version>`, so a stranger's bug report can
  be tied to a specific plugin version from the log alone -- the highest-leverage support
  fix for a paid product. It is logged before the PSES launch, so even a failed or
  `unavailable` first start still records its version.
- **README documents the full analysis-status taxonomy (dispatch 000025).** A new
  "Diagnostics status" section explains all four statuses a user can see -- `ok` (silent),
  `incomplete` (transient; this edit was not checked), `degraded` (parser-only;
  PSScriptAnalyzer unavailable), and `unavailable` (install/bootstrap failure) -- with what
  each means and how to act, now that 000024 completed the set.
- **README notes that `stats.jsonl` records absolute file paths (dispatch 000025, 000023
  audit S1c, closes backlog #7).** Opt-in telemetry (`enableStats`, default off) writes the
  full path of each analyzed file; the README now documents this so a user can sanitize a
  log before sharing. Path redaction is deferred as a later enhancement.

### Changed

- **README config table now documents every `userConfig` knob (dispatch 000025, 000023
  audit D1, closes backlog #4).** The four knobs the table omitted -- `enableStats`,
  `settingsPath`, `scopeToEdit`, `editContextLines` -- are now documented, so the table
  matches the manifest exactly (asserted by a unit test).
- **README currency refreshed to Claude Code 2.1.183 (dispatch 000025, 000023 audit D1,
  closes backlog #3).** Native `.lsp.json` registration was re-confirmed inert through
  2.1.183 (2026-06-19); the "Why a hook" section now reflects that span rather than lagging
  at 2.1.167. The honesty that native registration is inert and the hook is the production
  path is unchanged.

## [1.5.0] - 2026-06-20

MINOR: extends the 000022 "never report clean when it could not analyze" guarantee from
mid-session to install-time. A clean-box bootstrap failure (offline, behind a corporate
proxy, or with GitHub blocked) is now VISIBLE -- the first edit on a clean-parsing file
shows an explicit "diagnostics unavailable -- PowerShell editor services not installed"
banner instead of silence that looked identical to "analyzed, clean." Entirely additive:
the surface appears only on a broken install; the healthy warm path is byte-for-byte
unchanged, and no `userConfig` knob is added, removed, or renamed.

### Added

- **Surface a silent first-start install failure (dispatch powershell-lsp/000024, closes
  the 000023 launch-readiness audit's backlog #1).** When the PowerShell Editor Services
  bundle never bootstrapped (a clean box with no network), the daemon now comes up far
  enough to serve an explicit `unavailable` status over its named pipe instead of exiting
  before the pipe exists -- so the first edit renders a visible "not installed -- the
  bootstrap did not complete (network/proxy?)" banner rather than nothing. `session-start`
  also surfaces the failure immediately via SessionStart `additionalContext`. The new
  `unavailable` status is deliberately distinct from the transient `incomplete` (000022) --
  a broken install needs a different remedy than a retryable miss -- and its wording is
  owned in one place (`Get-DiagnosticsStatusBanner`), so the daemon and client cannot drift.

### Fixed

- **`ensure-pses` now fails loud and non-destructively (dispatch powershell-lsp/000024,
  closes the 000023 audit's backlog #2).** A bootstrap failure now writes a clear stderr
  message and exits non-zero (mirroring `ensure-pssa`), so the orchestration layer can see
  and surface it instead of swallowing a silent, log-only miss. The bootstrap also stages
  and verifies the download in a temp area before touching the live bundle (renaming any
  existing bundle aside and restoring it on a swap failure), so a failed re-run leaves the
  previously working bundle intact rather than deleting it before a single-attempt download.

## [1.4.0] - 2026-06-15

MINOR: marks two capabilities that shipped since 1.3.0 -- repo-local
`PSScriptAnalyzerSettings.psd1` honoring (000018) and edit-range diagnostic scoping
(000019) -- alongside the telemetry foundation and manifest-honesty work that supported
them, and adds a lockstep version-bump helper so the two version surfaces can never drift
apart again. Entirely additive: new `userConfig` knobs and new opt-out-able behavior, with
no knob removed or renamed and no change to the hook/registration contract.

### Added

- **Honor a repo-local `PSScriptAnalyzerSettings.psd1` (dispatch powershell-lsp/000018).**
  The analyzer now discovers and applies the nearest `PSScriptAnalyzerSettings.psd1`,
  walked up from the edited file and bounded at the project root, so a repo's own analyzer
  configuration (custom rule set, severities, suppressions) is honored instead of ignored.
  A new `settingsPath` knob overrides discovery with an explicit **absolute** path (a
  relative value is ignored); empty = auto-discover. The settings file is resolved per
  edit and applied to the warm PSES analyzer pass.
- **Scope diagnostics to the edited lines (dispatch powershell-lsp/000019).** A new
  `scopeToEdit` knob (**default on**) filters the surfaced diagnostics to those overlapping
  the lines the edit actually touched, so the feedback is what the edit is responsible for
  rather than the whole file. It **fails open** to whole-file whenever the touched range
  cannot be determined -- a new-file `Write`, a failed edit, or an unparseable payload --
  so scoping never hides a diagnostic. A companion `editContextLines` knob (default `0`,
  because the edit's structured patch already carries a few context lines) widens the kept
  window. Overlap, not containment: a multi-line diagnostic straddling the edit boundary is
  kept. The syntax-error parser pre-pass is always surfaced unscoped (syntax errors cascade
  off-edit).
- **Per-edit telemetry foundation and readout (dispatch powershell-lsp/000015, Track A).**
  An opt-in `enableStats` knob appends one JSONL timing line per analyzed edit to
  `logs/stats.jsonl` (rotating, ~5 MB) -- observe-only, it never changes diagnostics output
  -- and `scripts/show-stats.ps1` summarizes per-stage p50/p95 (connect, analysis,
  code-action, total), cache-hit rate, path-taken breakdown, and sample count. The
  edit-scope feature (000019) rides this foundation: the daemon reports the pre-scope total
  and post-scope surfaced counts, and `show-stats.ps1` prints the resulting noise
  reduction, so the trimming is measured rather than assumed.
- **`scripts/bump-version.ps1` -- lockstep version-bump helper (this release).** Writes one
  target version into both `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`
  from a single input -- lockstep by construction, so a future release physically cannot
  bump one surface and forget the other (the 1.3.0 drift reconciled below). Dry-run by
  default (it prints the plan and writes nothing without `-Apply`), idempotent, surgical
  (only the version token changes; encoding and line endings are preserved verbatim), and
  ASCII-clean. It prints the `git tag v<version>` command for the post-merge step but never
  runs `git tag` / `git push` -- tagging stays a manual gate.

### Changed

- **`scopeToEdit` defaults to on.** After an edit, surfaced diagnostics are scoped to the
  edited lines by default. This is a default-behavior change, but additive and fully
  reversible: set `scopeToEdit` to `0` / `false` / `off` to restore the prior whole-file
  behavior, which remains byte-identical to pre-1.4.0. Because scoping fails open, it can
  only surface a superset of what it would otherwise suppress -- it never hides a diagnostic
  it cannot place -- so the change forces no config or workflow adjustment (MINOR, not
  MAJOR).

### Docs

- **Manifest description reconciled with what ships (dispatch powershell-lsp/000016).** The
  `plugin.json` / `marketplace.json` description now states diagnostics and PSScriptAnalyzer
  fix suggestions as the shipped capability, with hover, go-to-definition, and
  find-references named as roadmap items pending Claude Code plugin LSP-server registration
  ([#66987](https://github.com/anthropics/claude-code/issues/66987)), rather than implying
  they are present today.
- **Marketplace version reconciled to the shipped release (dispatch powershell-lsp/000017).**
  `marketplace.json` `metadata.version` had drifted behind `plugin.json` at 1.3.0 and was
  realigned. This release makes that lockstep automatic via the bump helper above, so the
  drift cannot reopen.
- **Pull-model LSP features remain registration-gated (dispatch powershell-lsp/000015,
  Track B).** `docs/upstream/pull-feature-gating-probe.md` records the read-only verdict:
  the four pull-model features (hover, go-to-definition, find-references, document-symbols)
  cannot be delivered through the surface this plugin ships today -- the block is the
  empirically inert Claude Code plugin LSP-server registration path (#66987), not a PSES
  capability gap and not a hook-surface gap. PSES already speaks these features over the
  warm daemon; only the registration channel is missing.

## [1.3.0] - 2026-06-07

MINOR: the macOS (`macos-pwsh`) warm-daemon path is now CI-verified -- a newly
verified platform (dispatch powershell-lsp/000009, Track A).

### Added

- **macOS warm-daemon path is now CI-verified.** A `macos-pwsh` (`macos-latest`,
  `pwsh`) leg was added to the CI matrix with the same daemon-log artifact capture as
  the other legs, and the warm-daemon integration suite (one-daemon bring-up, the
  settled PSScriptAnalyzer pass, clean SessionEnd) is **un-skipped on macOS and green**
  alongside the two Windows legs and Linux. README "Platform support" now claims macOS
  to exactly what CI proves. macOS needed no code changes: the 1.2.0 generic-POSIX
  fixes (omit `workspaceFolders`, POSIX `ConvertTo-FileUri`) and the already-authored
  `ps`-based process-probe fallback (no `/proc` on BSD) carried over as-is, so the
  integration suite passed on the first CI attempt.

### Docs

- **Registration watch: no upstream movement (Track C).** Re-checked since 1.2.0 --
  Claude Code 2.1.168 shipped (changelog: bug-fixes / reliability only, no plugin-LSP
  registration change); claude-code#15168 / #15148 and claude-plugins-official#379
  remain open and untouched; PR #378 stays closed-unmerged. The held
  `docs/upstream/claude-code-lsp-registration.md` refutation is unchanged in substance
  and verified postable, with a dated note that the 2.1.167 datapoint still stands as
  of 2.1.168.
- **Hook-surface expansion proposal (Track D).** Added `docs/hook-surface-proposal.md`
  -- a survey of whether PSES capabilities beyond diagnostics (rename, code actions,
  formatting, workspace symbols, hover) should ride the hook architecture. Conclusion:
  decline all; those are pull/positional features that belong to Claude Code's native
  `LSP` tool (blocked only by the registration bug above), not the event-driven hook
  surface. Diagnostics stays the one capability whose shape fits.

## [1.2.0] - 2026-06-06

MINOR: the Linux (`ubuntu-pwsh`) warm-daemon path is now CI-verified -- a newly
verified platform. Closes both open unknowns from 000007 (dispatch
powershell-lsp/000008).

### Added

- **Linux warm-daemon path is now CI-verified.** The `ubuntu-pwsh` CI leg now runs the
  full warm-daemon integration suite (one-daemon bring-up, the settled
  PSScriptAnalyzer pass, and clean SessionEnd) and is green alongside both Windows
  legs. README "Platform support" now claims Linux to exactly what CI proves; macOS
  stays authored but unverified.

### Fixed

- **PSES v4.6.0 `NullReferenceException` on `initialize` (Linux only).** PSES throws an
  NRE inside its own `OnInitialize` handler (`PsesLanguageServer.cs:150`, the
  workspace-folder add path) when the client's `initialize` carries `workspaceFolders`
  -- on Linux; Windows is unaffected, which is why the Windows legs always passed this
  handshake. The daemon now omits `workspaceFolders` and relies on `rootUri` alone (the
  warm path opens each file explicitly via `didOpen`/`didChange`, so multi-root folders
  are not needed for diagnostics).
- **`ConvertTo-FileUri` returned a null URI on POSIX.** The `[System.Uri]` string cast
  yields a null/relative URI for a POSIX absolute path (`/home/x` -- no drive, no
  scheme); `.AbsoluteUri` on that is null, so the first diagnostics request broke at
  `$uri.ToLowerInvariant()`. The builder now constructs `file://<path>` explicitly on
  POSIX (percent-escaping each segment); the Windows branch (uppercase drive letter) is
  unchanged.

### CI / diagnostics

- **Daemon logs are uploaded as a per-leg CI artifact.** The integration test's data
  root is overridable via `PSLS_TEST_DATA_DIR` (default unchanged locally); CI pins it
  to a workspace path and always-uploads `pses-daemon.log` / `pses-server-*.log` /
  `pses-stderr-*.log` as `daemon-logs-<leg>`, so a bring-up failure is diagnosable
  instead of opaque. This is what made the two Linux fixes above findable.

### Docs (installed-cache `.lsp.json` registration: tested, still inert)

- **Closed the 000007 "installed-cache `.lsp.json`" caveat.** A throwaway plugin whose
  source ships a clean top-level-map `.lsp.json` with **literal** commands was installed
  through the real `/plugin` flow (the installer copies it into the cache -- the exact
  installed-cache configuration the caveat had left untested, reached with zero
  hand-writes), then the builtin `LSP` tool was probed after a full restart:
  `No LSP server available`. The installed real plugin (template-var `.lsp.json` in its
  cache) is inert the same way. So the `.lsp.json`-**file** path is **inert on Claude
  Code 2.1.167**, with literal commands and template variables alike -- a definitive
  refutation of the installed-cache "it works" reports (most likely a CC version
  difference). README and the held `docs/upstream/` draft updated to the definitive INERT
  framing; the draft stays a DRAFT (not posted).

## [1.1.2] - 2026-06-06

PATCH: a documentation correction (no code change). Survey-then-ship dispatch
(powershell-lsp/000007) across three maintenance tracks -- only the Track A docs
correction was ripe to ship.

### Docs

- **Corrected the native `.lsp.json` / registration framing.** Re-tested plugin LSP
  registration on Claude Code 2.1.167 with the strict methodology -- a clean
  top-level-map `.lsp.json` carrying **literal** commands (no `${CLAUDE_PLUGIN_ROOT}` /
  `${user_config.*}` template variables), loaded into a **freshly started** process
  (`--plugin-dir`, a full restart, not `/reload-plugins`). The builtin `LSP` tool
  still returned `No LSP server available for file type: .ps1`, so the inertness is
  not a reload-vs-restart or template-variable artifact. (One path was not tested -- a
  `.lsp.json` file inside an installed plugin's cache dir, to avoid writing the
  installer-owned cache -- so this narrows the gap rather than closing it.)
- **Corrected the upstream citation.** claude-plugins-official PR #378 (the proposed
  `.lsp.json` packaging fix) was **closed unmerged** (2026-02-11); issue #379 remains
  open and unaddressed. README and the held `docs/upstream/` draft updated to match.

### Notes (surveyed, nothing else shipped)

- **Pins already current.** PSES `v4.6.0` and PSScriptAnalyzer `1.25.0` are the newest
  published releases -- no bump available; the PSES `PrepareRenameHandler` NRE remains
  unfixed upstream.
- **Cross-platform still unverified.** Enabling the warm-daemon integration tests on
  the ubuntu-pwsh CI leg showed the daemon does not reach `ready` on Linux (bring-up
  fails; both Windows legs stayed green). The non-Windows path stays
  authored-but-unverified; no platform claim changed.

## [1.1.1] - 2026-06-06

### Fixed

- **First-run failure on Claude Code v2.1.167.** On a clean install with no saved
  config, all three hooks (SessionStart, PostToolUse, SessionEnd) errored before
  running -- `Failed to run: Plugin option 'ps_host' isn't set` -- so a stranger got
  zero diagnostics and three red errors. Root cause: Claude Code did not apply the
  `userConfig` schema defaults to `${user_config.*}` substitution in hook commands,
  and the hooks used `${user_config.ps_host}` as the **interpreter**, so the very
  first reference was unset and the command could not launch.

### Changed

- **Hook commands no longer use `${user_config.*}` substitution.** The interpreter is
  now a literal `pwsh`, and every knob is self-sourced inside the scripts from the
  `CLAUDE_PLUGIN_OPTION_<key>` environment variables Claude Code exports, each with a
  fallback to its prior default (`Get-PluginOption` / `Get-PluginOptionInt`). This is
  immune to the substitution/persistence behavior above: zero saved config yields
  working defaults, and saved config still applies. The inline `lspServers` block and
  `docs/lsp.json.template` were moved to a literal `pwsh` command for the same reason.
- **`pwsh` (PowerShell 7) is now required to launch the hooks.** Windows PowerShell
  5.1 alone can no longer bootstrap them; it remains supported as the PSES *child*
  host via `ps_host`. See README "Requirements" and "Troubleshooting".

### Deviation from 1.1.0 (forced, field-evidence-backed)

This breaks byte-identity with the mande-tooling 1.1.0 source for `plugin.json`,
`scripts/session-start.ps1`, `scripts/lsp-client.ps1`, and `scripts/lib/lsp-common.ps1`.
The change is mandatory -- 1.1.0 is unusable on a clean install on CC v2.1.167
(evidence: the 000005 fresh-install proof, 2026-06-06). Same class of forced,
field-evidence deviation as the v4.6.0 rename-capability inversion in 1.1.0.

## [1.1.0] - 2026-06-05

### Added

- **Warm-start PSES daemon.** A long-lived, per-session process
  (`scripts/pses-daemon.ps1`) now owns one warm PowerShell Editor Services child
  (over stdio) and serves diagnostics over a named pipe
  (`powershell-lsp-<sessionid>`). This removes the per-edit cold-start that
  dominated the loose-hook latency.
- **PostToolUse client** (`scripts/lsp-client.ps1`): connects to the warm daemon,
  requests diagnostics for the edited `.ps1`/`.psm1`/`.psd1`, and returns them to
  Claude via `hookSpecificOutput.additionalContext`. Connect timeout 2s with one
  retry, 5s hard cap, and graceful degradation to log-only if the daemon is down.
- **SessionStart orchestration** (`scripts/session-start.ps1`): runs `ensure-pses`
  and `ensure-pssa`, sweeps rolling logs (keep-last-10 per family), reaps OUR
  stale daemons (recorded pids only, verified by command line), and launches
  exactly one daemon for the session.
- **SessionEnd teardown** (`scripts/session-end.ps1`): sends a graceful shutdown
  over the pipe (daemon issues LSP `shutdown`/`exit` to PSES, then exits), with a
  verified-pid fallback.
- **Pinned PSScriptAnalyzer** (`scripts/ensure-pssa.ps1`): vendors PSSA `1.25.0`
  into `${CLAUDE_PLUGIN_DATA}/modules`, prepended to the PSES child's
  `PSModulePath` so the analyzer pass runs (PSES emits only parser errors
  without it).
- **Shared library** (`scripts/lib/lsp-common.ps1`): host detection, file-URI
  construction, LSP framing, and diagnostics ordering/dedupe, dot-sourced by the
  daemon, client, hooks, and tests.
- Hooks declared as first-class plugin components (SessionStart, PostToolUse,
  SessionEnd) in `plugin.json`. `-NoLogo -NoProfile` on every host launch; all
  state, logs, and pids under `CLAUDE_PLUGIN_DATA` only.

### Encoded landmines

- **File URIs use UPPERCASE drive letters.** `[System.Uri].AbsoluteUri`
  lowercases the drive on .NET; the builder now fixes it back to uppercase.
- **Wait for the settled publish.** PSES publishes an early (often empty) parser
  pass before the PScriptAnalyzer pass; the daemon waits for a quiet window after
  the last publish rather than reporting the first.
- **Rename capability IS declared (deviation -- see below).**

### Portability and self-bootstrap hardening

- Zero hardcoded user paths in shipped scripts (verified by grep): every path is
  built from `CLAUDE_PLUGIN_DATA`/`CLAUDE_PLUGIN_ROOT` + `Join-Path`.
- Single shared host-detection helper `Resolve-PsHost` (prefer `pwsh`, fall back
  to `powershell`, log a clear message and abort bring-up if neither is found).
- Both bootstrap pins are documented with a one-variable bump path
  (`$PsesTag` in `ensure-pses.ps1`, `$PssaVersion` in `ensure-pssa.ps1`); see the
  README "Pinned versions" table.
- **Cross-platform forward-compat AUTHORED but not CI-verified here** (this build
  ran Windows only): `Test-OnWindows` guards isolate the one Windows-only call
  (`Win32_Process` command-line lookup) behind a cross-platform
  `Get-ProcessCommandLine` (Linux `/proc`, macOS `ps`); named pipes use
  `System.IO.Pipes` (Unix domain socket semantics on *nix are acceptable); no
  backslash path literals; the detached daemon launch is guarded per platform.
  Marked for CI verification in a later stage.
- Fresh-machine simulation passes: pointed at an empty `CLAUDE_PLUGIN_DATA`,
  SessionStart bootstraps PSES (`v4.6.0`) and PSScriptAnalyzer (`1.25.0`) from
  their pins and a diagnostics edit round-trips end to end.

### Testing and CI

- Pester 5 regression suite under `tests/`:
  - unit: file-URI drive-letter casing (Windows-gated), the rename-capability
    invariant (asserts it IS declared -- see the deviation below), shared host
    detection, diagnostics ordering/dedupe, and an ASCII-clean + parse check over
    every shipped `.ps1`;
  - integration (Windows): one-daemon bring-up, the settled PSScriptAnalyzer pass
    (an unapproved-verb fixture must yield `PSUseApprovedVerbs`, proving the
    early-publish wait), and clean SessionEnd with no orphaned daemon/PSES.
- `tests/run-tests.ps1` bootstraps Pester 5 to CurrentUser scope only and runs
  the suite. Green on BOTH local hosts: `pwsh` 7.6.2 and Windows PowerShell 5.1
  (35/35 each).
- `.github/workflows/powershell-lsp-ci.yml`: matrix `windows-latest` (`pwsh` +
  `powershell`) and `ubuntu-latest` (`pwsh`), triggered on pushes/PRs touching the
  plugin tree. Integration tests self-skip on Ubuntu (cross-platform daemon path
  is CI-verified later); the unit surface runs everywhere.
- Two real portability bugs surfaced by the dual-host requirement and fixed:
  - `ProcessStartInfo.ArgumentList` does not exist on .NET Framework (Windows
    PowerShell 5.1). Added `Add-ProcessArguments` (uses `ArgumentList` on pwsh --
    the proven path, unchanged -- and a hand-quoted `.Arguments` string on 5.1).
  - A Windows PowerShell 5.1 `StreamWriter` prepends a UTF-8 BOM to a child's
    stdin, which broke `ConvertFrom-Json` on the hook payload. Added BOM-tolerant
    `Get-StdinText`, now used by every stdin reader.

### Configurability and diagnostics polish

- Eight `userConfig` knobs (all with defaults), wired from `plugin.json` through
  the SessionStart/PostToolUse commands into the daemon and client:
  `severityThreshold`, `ruleInclude`, `ruleExclude`, `timeoutMs`, `debounceMs`,
  `keepLastN`, `idleTtlMin`, `perFileCap`. Each is documented in the README.
- Diagnostics output is now: stable-sorted (severity, then line, then column),
  deduped, filtered by severity threshold and rule include/exclude, then capped
  per file with an `... and N more (per-file cap)` line.
- Pester unit tests for the filtering knobs (threshold, include, exclude, cap,
  and rule-list parsing); green on both hosts. Manual end-to-end check confirms a
  non-default `severityThreshold`, a `ruleExclude`, and a `perFileCap` are all
  honored over the warm path.

### Deviation from the dispatch (rename capability, inverted)

The dispatch frontmatter and the build brief both said *"do not advertise rename
capability on initialize (PSES v4.6.0 NRE)."* This is **empirically backwards**
for PSES v4.6.0. Probe evidence (2026-06-05): initialize with `rename` **omitted**
=> PSES never answers initialize (`NO INIT RESPONSE`); initialize with a minimal
`rename` capability **declared** => clean handshake + diagnostics. The shipped
v1.0.0 README documents the same direction (the NRE fires when a client *omits*
rename). The daemon therefore declares a minimal rename capability, which is what
*avoids* the NRE. Reported in dispatch outbox 000001.

## [1.0.0] - 2026-06-01

### Added

- Initial release.
- PowerShell code intelligence via PowerShell Editor Services (PSES) as a Claude
  Code LSP server: diagnostics, hover, go-to-definition, and find-references for
  `.ps1`, `.psm1`, and `.psd1` files.
- `scripts/ensure-pses.ps1`: idempotent SessionStart bootstrap that downloads and
  expands the pinned PSES release (`v4.6.0`) into
  `${CLAUDE_PLUGIN_DATA}/PowerShellEditorServices`. Silent on stdout; logs to file.
- `scripts/pses-stdio.ps1`: silent stdio launcher that runs
  `Start-EditorServices.ps1 -Stdio` with `-NoLogo -NoProfile`, reserving stdout
  for the LSP stream.
- `ps_host` user config (`pwsh` default, `powershell` fallback).
- Ships disabled by default (`defaultEnabled: false`); opt-in enable.
