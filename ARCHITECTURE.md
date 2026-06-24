# Architecture

How `powershell-lsp` turns an edit to a `.ps1` / `.psm1` / `.psd1` file into a
PowerShell diagnostic in Claude Code's context. This is the map a contributor needs
before touching the runtime. The user-facing summary lives in
[README.md](./README.md#how-it-works-warm-start-daemon); the frozen public surface (the
things a change must not break without a MAJOR bump) is in [CONTRACT.md](./CONTRACT.md).

## The one-paragraph model

Claude Code can declare a plugin language server through native LSP registration, but
that path has been unreliable for plugin-provided servers (the full story is in the
README, [Why a hook, not native registration](./README.md#why-a-hook-not-native-lspjson-registration)).
So this plugin does **not** depend on it. Diagnostics ride a **PostToolUse hook backed
by a warm, per-session PSES daemon**: one PowerShell Editor Services process stays hot
for the whole Claude Code session, so each edit pays a local named-pipe round-trip
(~2 s) instead of a cold PSES start (~6 s). Everything runs on the local machine; the
only outbound network is the one-time, pinned, hash-verified dependency download.

## The pieces (`scripts/`)

| File | Role |
|------|------|
| `session-start.ps1` | **SessionStart hook.** Bootstraps the dependencies (idempotent), sweeps old logs, reaps our own stale daemons, and launches the warm daemon. |
| `pses-daemon.ps1` | **The warm daemon.** Hosts one PSES via `-Stdio`, exposes a named pipe (`powershell-lsp-<sessionid>`), and answers diagnostics requests. **Pipe-first**: it opens the request pipe *before* PSES is ready, so a first edit that races startup gets an honest status, never silence. |
| `lsp-client.ps1` | **PostToolUse hook.** Reads the hook JSON from stdin, connects to the pipe, requests diagnostics for the edited file, and returns them to Claude via `hookSpecificOutput.additionalContext`. Carries the never-silent backstop when the daemon is unreachable. |
| `session-end.ps1` | **SessionEnd hook.** Tells the daemon to shut PSES down cleanly and remove its session file. |
| `ensure-pses.ps1` | Idempotent, pinned + SHA-256-verified bootstrap of PowerShell Editor Services into `${CLAUDE_PLUGIN_DATA}`. |
| `ensure-pssa.ps1` | Idempotent, pinned + SHA-256-verified vendor of PSScriptAnalyzer, prepended to the PSES child's `PSModulePath`. |
| `pses-stdio.ps1` | The cold-start `-Stdio` launcher -- the destination a future native `.lsp.json` registration would target. |
| `lib/lsp-common.ps1` | **Shared core.** Host detection, file-URI construction (uppercase drive letter), LSP framing, diagnostics ordering/dedupe/threshold/cap, and the status-banner functions (`Get-DiagnosticsStatusBanner`, `Resolve-AnalysisStatus`). Dot-sourced by the daemon, client, hooks, and tests. |
| `lib/security-classifier.ps1` | Detect-and-explain-only classifier for managed-Windows security-control blocks (WDAC / AppLocker / ExecutionPolicy / CLM / ASR / SAC). Never bypasses a control. |
| `doctor.ps1` | Report-only preflight self-check (prerequisites + bootstrap + warm-daemon liveness). |
| `review-dogfood.ps1` | Offline annotator for the local dogfood capture log (fills each diagnostic's `verdict`). |
| `show-stats.ps1` | Viewer for the opt-in `enableStats` timing log. |
| `bump-version.ps1` | Lockstep version stamp helper (`plugin.json` + `marketplace.json`). |

## The lifecycle: edit -> banner

```text
SessionStart
   session-start.ps1
     ensure-pses.ps1 / ensure-pssa.ps1   (pinned + hash-verified; no-op once vendored)
     sweep logs (keepLastN per family); reap OUR stale daemons (recorded pids, verified)
     launch pses-daemon.ps1 -> opens pipe FIRST, then brings PSES up (-Stdio)
                               writes pid/heartbeat to CLAUDE_PLUGIN_DATA/session/<id>.json

PostToolUse (matcher: Write | Edit | MultiEdit)
   lsp-client.ps1
     read {session_id, file_path, edit patch} from stdin
     non-PowerShell file?  -> exit 0, nothing surfaced
     connect to the pipe, send a diagnostics request
        daemon: didOpen / didChange -> wait for the SETTLED PScriptAnalyzer publish
                (NOT the early parser-only publish) -> debounce (debounceMs)
     receive findings; scope to the edited lines (scopeToEdit, fails open to whole-file);
        order (severity, line, col), dedupe, threshold- and rule-filter, cap (perFileCap)
     tee every surfaced finding to the local dogfood log (invisible, fail-safe side channel)
     return diagnostics + a status banner via hookSpecificOutput.additionalContext
     hook ALWAYS exits 0 -- editing is never blocked, even on total failure

SessionEnd
   session-end.ps1 -> pipe {shutdown} -> daemon sends LSP shutdown/exit to PSES, exits
```

The hook **always exits 0**. A timeout, a thrown error, a dead daemon, or a hash
mismatch degrades to a visible banner (below) -- it never breaks the edit and never
writes to stdout on the daemon/LSP path.

## The status taxonomy (why a result is never silently wrong)

Every analyzed edit resolves to exactly one of four tokens. The clean token renders an
**empty** banner (the byte-identical warm happy path); each non-clean token renders a
**distinct, visible** one, so "analyzed, clean" can never be confused with "not actually
analyzed". This token set is **frozen** -- see [CONTRACT.md](./CONTRACT.md#12-diagnostics-status-taxonomy).

| Token | Meaning |
|-------|---------|
| `ok` | The PScriptAnalyzer pass settled; diagnostics (if any) are shown, no banner. |
| `incomplete` | Did not settle this edit (PSES still starting, timed out, threw, re-spawning). Transient -- the next edit usually succeeds. |
| `degraded` | PSES is up but PSScriptAnalyzer is absent, so only the parser ran (syntax errors still reported). |
| `unavailable` | PSES could not start at all for the session (never bootstrapped, or present but failed init). Permanent until a fresh session. |

The wording of these banners is owned in one place (`Get-DiagnosticsStatusBanner`); the
prose is not frozen (a clearer message is a PATCH), only the token set and the
empty-vs-visible property are.

## Cross-platform

`pwsh` (PowerShell 7) is the analysis host on **every** platform, including the hook
interpreter. The daemon/client transport is `System.IO.Pipes`, which maps to Unix domain
sockets on .NET, so the warm-daemon path runs and is CI-verified on Windows `pwsh`,
Ubuntu `pwsh`, and macOS `pwsh`. Windows PowerShell 5.1 is supported only as the PSES
**child host** (`ps_host = powershell`), never as the hook interpreter; its distinct CI
value is exercising the shared-library surface (file-URI casing, BOM-tolerant stdin, the
`ArgumentList`-vs-quoted-`.Arguments` split, the config-env fallback) under 5.1.

## Where state lives

All runtime state -- the vendored PSES + PSScriptAnalyzer, logs, pids, session files, the
dogfood capture log -- lives under `CLAUDE_PLUGIN_DATA` and never leaves the machine. The
plugin scripts themselves live under `CLAUDE_PLUGIN_ROOT` (the Claude Code plugin cache).
There is no network service, no telemetry, and no listening socket (the only IPC is the
session-keyed local pipe). See [TRUST.md](./TRUST.md) for the full security posture.

## What you must not break

The public contract -- the `userConfig` knob **names** and the status **token set** -- is
drift-guarded in CI against the manifest and the banner functions
(`tests/PowerShellLsp.Unit.Tests.ps1`). Change one of those sources and CI goes red until
[CONTRACT.md](./CONTRACT.md) and the README are updated to match. Read CONTRACT.md before
touching `plugin.json`'s `userConfig` or the status tokens.
