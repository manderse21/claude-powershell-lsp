# PowerShell LSP

PowerShell code intelligence for [Claude Code](https://claude.com/claude-code),
powered by [PowerShell Editor Services](https://github.com/PowerShell/PowerShellEditorServices)
(PSES). Real-time diagnostics, hover, go-to-definition, and find-references while
editing `.ps1`, `.psm1`, and `.psd1` files.

This is language tooling, not project tooling: a standalone plugin that carries
~0 always-on model-context token cost. It only spawns a language server when you
open a PowerShell file, and a single warm PSES serves the whole session so each
edit pays a pipe round-trip (~2 s) instead of a cold start (~6 s).

## Requirements

- **PowerShell 7+ (`pwsh`) is required.** As of 1.1.1 the plugin's hooks launch under
  `pwsh`; Windows PowerShell 5.1 alone cannot bootstrap them. Install pwsh from
  <https://aka.ms/powershell> or via `winget install Microsoft.PowerShell`.
- Windows PowerShell 5.1 (`powershell`) is still supported as the **PSES child host**:
  set `ps_host` to `powershell` to run the language server under 5.1 (the hooks
  themselves still require `pwsh`).
- Internet access on first run: PSES is downloaded on first use (not vendored).

## Install

Add this repository as a marketplace, then install the plugin:

```
/plugin marketplace add manderse21/claude-powershell-lsp
/plugin install powershell-lsp@claude-powershell-lsp
```

The plugin ships **disabled by default** (`defaultEnabled: false`) because it
downloads a bundle and spawns a language server. Enable it explicitly:

```
/plugin enable powershell-lsp
```

Then start a new session (or `/reload-plugins`). On the first session with the
plugin enabled, the `SessionStart` hook bootstraps PSES into your plugin data
directory. Open a `.ps1` file to bring the language server up.

## Configuration

Set these via the `/plugin` config UI for `powershell-lsp`, or leave the defaults.

| Key                | Default  | Meaning                                                                              |
|--------------------|----------|--------------------------------------------------------------------------------------|
| `ps_host`          | `pwsh`   | Host executable: `pwsh` (PowerShell 7+, recommended/tested) or `powershell` (Win 5.1) |
| `severityThreshold`| `Hint`   | Least-severe level to report: `Error` > `Warning` > `Information` > `Hint`            |
| `ruleInclude`      | _(empty)_| Comma-separated PSScriptAnalyzer rule codes to report exclusively; empty = all        |
| `ruleExclude`      | _(empty)_| Comma-separated rule codes to suppress (e.g. `PSAvoidUsingWriteHost`)                  |
| `timeoutMs`        | `5000`   | Total hard cap (ms) before the PostToolUse client degrades to log-only                 |
| `debounceMs`       | `150`    | Edits landing within this window (ms) fold into one analysis pass                      |
| `keepLastN`        | `10`     | Newest rolling log files kept per family (swept at SessionStart)                       |
| `idleTtlMin`       | `30`     | Daemon self-terminates after this many minutes with no diagnostics request            |
| `perFileCap`       | `20`     | Max diagnostics reported per file; the rest collapse into an `... and N more` line; `0` = no cap |

Diagnostics are returned in a stable order (severity, then line, then column),
deduped, threshold- and rule-filtered, then capped per file.

These filters apply on top of whatever **PSES** publishes. PSES runs its own default
PSScriptAnalyzer rule set for live analysis, which is narrower than the
`Invoke-ScriptAnalyzer` CLI default -- for example `PSAvoidUsingWriteHost` is not
surfaced on the fly even though the CLI flags it. The knobs here can *suppress or
narrow* what PSES reports; they cannot add a rule PSES does not run.

## Performance

**Warm-path daemon (v1.1.0), `pwsh` 7.6.2, Windows 11.** Measured warm-path
latency (median of 5 successive edits): **~2.0 s wall clock** per edit
(`~1998 ms`), versus the ~6 s cold start of a per-edit-spawn predecessor. Roughly
0.7 s of that is the per-hook `pwsh` process spawn that Claude Code pays
regardless of plugin code.

The acceptance suite confirms: cold-session bring-up launches exactly one daemon;
a deliberate diagnostic returns over the warm path; the settled PSScriptAnalyzer
pass (not the early parser publish) is reported; file URIs carry uppercase drive
letters; three rapid edits coalesce into one analysis pass; SessionEnd leaves no
daemon/PSES processes; and killing the daemon mid-session degrades gracefully
(no stdout, under the hard cap) while the next SessionStart reaps the stale
session and its orphaned PSES.

## How it works (warm-start daemon)

Diagnostics are delivered through a **PostToolUse hook backed by a warm,
per-session daemon** -- one PSES stays hot for the whole session, so each edit
pays a pipe round-trip instead of a cold PSES start.

```text
SessionStart  -> scripts/session-start.ps1
                   ensure-pses.ps1   (idempotent PSES bootstrap, pinned tag)
                   ensure-pssa.ps1   (idempotent PSScriptAnalyzer vendor, pinned)
                   log sweep (keep-last-10 per family)
                   reap OUR stale daemons (recorded pids only, verified)
                   launch scripts/pses-daemon.ps1  (one warm PSES via -Stdio;
                     named pipe powershell-lsp-<sessionid>; pid/heartbeat in
                     CLAUDE_PLUGIN_DATA/session/<sessionid>.json)

PostToolUse   -> scripts/lsp-client.ps1
                   read hook JSON (session_id, file_path) from stdin
                   connect to the pipe, request diagnostics for the edited file
                   daemon: didOpen/didChange -> wait for the SETTLED PScriptAnalyzer
                     publish (not the early parser publish) -> debounce
                   return deduped, severity-sorted diagnostics to Claude via
                     hookSpecificOutput.additionalContext

SessionEnd    -> scripts/session-end.ps1
                   pipe {shutdown} -> daemon sends LSP shutdown/exit to PSES,
                   removes its session file, exits
```

- **`scripts/lib/lsp-common.ps1`**: shared helpers (host detection, file-URI with
  uppercase drive, LSP framing, diagnostics ordering/dedupe), dot-sourced by the
  daemon, client, hooks, and tests.
- **`scripts/ensure-pses.ps1`**: idempotent PSES bootstrap into
  `${CLAUDE_PLUGIN_DATA}/PowerShellEditorServices`; no-op once present.
- **`scripts/ensure-pssa.ps1`**: idempotent vendor of pinned PSScriptAnalyzer into
  `${CLAUDE_PLUGIN_DATA}/modules`, prepended to the PSES child's `PSModulePath` so
  the analyzer pass runs (PSES emits only parser errors without it).
- **`scripts/pses-stdio.ps1`**: the cold-start `-Stdio` launcher -- the destination
  for native `.lsp.json` registration (see below).

All scripts run `-NoLogo -NoProfile`, write nothing to stdout on the daemon/LSP
path, and keep all state, logs, and pids under `CLAUDE_PLUGIN_DATA` only.

## Why a hook, not native `.lsp.json` registration

Claude Code declares plugin language servers through a per-plugin
[`.lsp.json`](https://code.claude.com/docs/en/plugins-reference#lsp-servers) file
(or an equivalent inline `lspServers` block, which this plugin's `plugin.json`
carries). That is the intended path. In practice it has been unreliable for
plugin-provided servers, for two independent reasons:

1. **A plugin-shipped `.lsp.json` file does not register.** On 2.1.167 a `.lsp.json`
   placed in a plugin (its installed cache, or loaded via `--plugin-dir`) does not
   register a server -- verified across every configuration in dispatch 000008 (detail
   under "Native registration" below). What *does* register is `lspServers` declared in
   a **marketplace manifest** and harvested into Claude Code's plugin catalog -- how the
   official `pyright`/`typescript` plugins register. This plugin's server lives in
   `plugin.json` + a `.lsp.json` file, not the cataloged manifest, so it stays inert.
   (Related packaging gap -- installing copies only a plugin's source into the cache --
   tracked at
   [claude-plugins-official#379](https://github.com/anthropics/claude-plugins-official/issues/379);
   [PR #378](https://github.com/anthropics/claude-plugins-official/pull/378) to add
   `.lsp.json` files to the official plugins was **closed unmerged** (2026-02-11), #379
   still open.)
2. **A registration race.** `LspServerManager` can initialize before plugins
   finish loading, registering 0 servers even when a `.lsp.json` is present.
   First reported in
   [claude-code#14803](https://github.com/anthropics/claude-code/issues/14803)
   (fixed) and analyzed in detail in
   [claude-code#29858](https://github.com/anthropics/claude-code/issues/29858);
   the symptom remains open at
   [#15168](https://github.com/anthropics/claude-code/issues/15168) and
   [#15148](https://github.com/anthropics/claude-code/issues/15148).

So rather than depend on native registration, this plugin delivers diagnostics
through a **warm PostToolUse hook** that always works, on every supported host,
today. The hook is the product; native registration is a bonus you can opt into.

### Native registration (`.lsp.json`) -- not active for this plugin on 2.1.167

The plugin declares its server two ways -- an `lspServers` block in `plugin.json` and a
standalone [`docs/lsp.json.template`](docs/lsp.json.template) -- and **neither activates
on Claude Code 2.1.167**. This was pinned down on 2026-06-06 (dispatch 000008) across
every configuration, including the one a prior test had left open:

- a clean top-level-map `.lsp.json` with **literal** commands (no `${CLAUDE_PLUGIN_ROOT}`
  / `${user_config.*}` variables), loaded via `--plugin-dir` into a freshly started
  process -> `No LSP server available for file type: .ps1`;
- that same literal `.lsp.json` shipped in a throwaway plugin and **installed through the
  real `/plugin` flow**, so the installer placed it in the plugin cache (the exact
  installed-cache setup some users report working) -> still `No LSP server available`,
  after a full restart;
- the installed real plugin, whose cache already carries a template-var `.lsp.json` ->
  inert the same way.

So a `.lsp.json` **file** is inert here regardless of literal-vs-template commands or
`--plugin-dir`-vs-installed-cache. **What does register is `lspServers` declared in a
marketplace manifest:** the official `pyright`/`typescript` plugins -- whose `lspServers`
lives in `marketplace.json` (harvested into Claude Code's plugin catalog), with no
`.lsp.json` in their installed caches at all -- register fine (the `LSP` tool finds the
server and tries to spawn it). This plugin ships its server in `plugin.json` + a
`.lsp.json` file, not in the cataloged marketplace manifest, so it does not register.
That is why diagnostics ride the **PostToolUse hook** -- the path that works on every
supported host today. (Methodology and evidence in
[`docs/upstream/claude-code-lsp-registration.md`](docs/upstream/claude-code-lsp-registration.md),
held for review.)

The template ships as `docs/lsp.json.template` (not live at the root) on purpose: a
root `.lsp.json` adds nothing while registration is broken, and would risk duplicate
diagnostics the moment a future release fixes it. When that release lands, copy it in
to opt into the native path:

```
cp docs/lsp.json.template .lsp.json
# then FULLY restart Claude Code -- a new process. /reload-plugins is not enough:
# the 2026-06-06 re-test confirmed a plugin-root .lsp.json stays inert even after a
# full restart on 2.1.167, so this is for a future release that fixes registration.
```

> **Heads-up once it does activate -- duplicate diagnostics.** If native registration
> ever turns on while the PostToolUse hook is also enabled, each diagnostic arrives
> twice. Use one path or the other.

## Pinned versions

| Component         | Version  | Pinned in                 | Source                                  |
|-------------------|----------|---------------------------|-----------------------------------------|
| PSES              | `v4.6.0` | `scripts/ensure-pses.ps1` (`$PsesTag`)     | GitHub release `PowerShellEditorServices.zip` |
| PSScriptAnalyzer  | `1.25.0` | `scripts/ensure-pssa.ps1` (`$PssaVersion`) | PowerShell Gallery                      |

To bump either, change the single pin variable named above and start a fresh
session (the ensure-step re-vendors at the new version, keyed by a per-version
marker). See [CHANGELOG](./CHANGELOG.md#versioning) for how a bump maps to SemVer.

## Platform support

As of 1.1.1 the **hooks require `pwsh` (PowerShell 7)** -- they launch the bootstrap
under it on every platform. Windows PowerShell 5.1 is supported as the **PSES child
host** (set `ps_host` to `powershell`), not as the hook interpreter.

CI runs the Pester suite on a three-leg matrix: **Windows `pwsh` 7**, **Windows
PowerShell 5.1**, and **Ubuntu `pwsh`**. As of 1.2.0 the full warm-daemon
**integration suite** (one-daemon bring-up, the settled PSScriptAnalyzer pass, clean
SessionEnd) runs and is **green on all three legs** -- so the **Linux daemon path is
CI-verified**, not merely authored. The integration tests drive the daemon under
`pwsh` on every leg, so the Windows-PowerShell-5.1 leg's distinct value is exercising
the **shared-library surface under 5.1** -- file-URI casing, BOM-tolerant stdin, the
`ArgumentList`-vs-quoted-`.Arguments` split, and the config-env fallback -- the code
that must keep working when PSES runs as a 5.1 child.

The scripts are cross-platform: all paths go through `Join-Path`, host detection is
shared, the single Windows-only call (process command-line lookup, used to verify a
pid is ours before any kill) is guarded behind `Test-OnWindows` with Linux `/proc`
and macOS `ps` fallbacks, and the client/daemon transport is `System.IO.Pipes` (Unix
domain socket semantics on *nix). **macOS** stays authored but not yet CI-verified.

## Troubleshooting

- **Hooks fail with `'pwsh' is not recognized` / pwsh not found:** as of 1.1.1 the
  hooks launch under PowerShell 7. Install it (`winget install Microsoft.PowerShell`)
  -- Windows PowerShell 5.1 alone cannot launch the hooks. (`ps_host` only selects the
  PSES *child* host, not the hook interpreter.)
- **A leftover user-level PSES hook fires alongside the plugin (duplicate or
  conflicting diagnostics):** if you previously wired a PowerShell diagnostics hook
  directly in `~/.claude/settings.json` (a pre-plugin setup), remove it -- the plugin
  owns the SessionStart / PostToolUse / SessionEnd hooks now, and a stray user-level
  hook will double up or conflict with them.
- **`/plugin` Errors tab shows `Executable not found in $PATH`** for the
  `powershell` server: `ps_host` points at an executable that is not on PATH.
  Install PowerShell 7 (`pwsh`) or set `ps_host` to `powershell`.
- **No diagnostics / server never starts:** confirm the bootstrap ran by checking
  that
  `${CLAUDE_PLUGIN_DATA}/PowerShellEditorServices/PowerShellEditorServices/Start-EditorServices.ps1`
  exists. If not, start a fresh session so the `SessionStart` hook can run, and
  inspect `${CLAUDE_PLUGIN_DATA}/logs/ensure-pses.log`.
- **Server starts but handshake fails:** inspect the PSES log under
  `${CLAUDE_PLUGIN_DATA}/logs/pses-lsp.log/StartEditorServices-<pid>.log` for the
  PSES-side error.
- **`PrepareRenameHandler` `NullReferenceException` on initialize:** a PSES
  `v4.6.0` bug -- its rename handler dereferences a null `RenameCapability` when an
  LSP client's `textDocument` capabilities **omit** `rename`. This plugin's daemon
  **declares a minimal `rename` capability on purpose**, which is what *avoids* the
  NRE, so the warm path is unaffected. You would only hit this by driving PSES from
  a client that omits rename (e.g. a hand-rolled minimal client against the cold
  `-Stdio` launcher); if so, pin PSES `v4.5.0` in `scripts/ensure-pses.ps1`
  (`$PsesTag`), which predates the rename handler.

## License

MIT. See [LICENSE](./LICENSE).
