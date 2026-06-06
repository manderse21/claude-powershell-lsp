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
