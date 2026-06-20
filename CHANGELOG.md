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
