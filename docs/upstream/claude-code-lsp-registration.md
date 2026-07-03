# Claude Code plugin LSP registration -- root cause (corrected record)

**What this is:** the corrected internal record of why this plugin's native LSP server did not
register, and what actually fixes it. **Not posted upstream.** Any upstream comment (the
`#66987`-class registrar-field-rejection report) is a separate Mike-gated draft.

**Status (2026-06-27, dispatch 000069 -> 000075) -- root cause ISOLATED; the earlier
"platform-inert" framing is SUPERSEDED.** This document previously argued that a plugin-provided
LSP server "does not register in any configuration" -- a blanket platform-inertness claim drawn
from probes on Claude Code 2.1.167 through 2.1.183. Dispatch 000069 re-probed on **Claude Code
2.1.195** with a controlled single-field matrix and found the real cause is **declaration-specific,
not platform-wide**:

- **Control plugins register and serve.** The official `typescript` LSP plugin registers and
  answers `goToDefinition`; a clean, known-good `lspServers` block placed in a `plugin.json`
  registers too. So the platform-level registration path is **effective** on 2.1.195 -- the
  registration-race symptom this document used to lead with (`claude-code#14803`, fixed) is no
  longer the blocker.
- **Our specific blocker was two manifest fields.** Claude Code's runtime LSP registrar
  **silently drops any `lspServers` server entry that declares `restartOnCrash` or
  `shutdownTimeout`.** Both are accepted by the plugin-manifest JSON schema (our `plugin.json`
  validates in CI), so this is a **schema-permits / registrar-rejects** mismatch with **no
  diagnostic** in the event stream. Our block declared **both**, so `.ps1/.psm1/.psd1 ->
  powershell` was never registered and every probe returned `No LSP server available for file
  type: .ps1`.
- **Removing the two fields restores REGISTRATION.** Proven on the real tree: the shipped tree
  (both fields present) fails; the same tree with both fields removed registers and Claude Code
  launches `plugin:powershell-lsp:powershell`.
- **End-to-end SERVE is now un-gated LOCALLY via an opt-in shim (dispatch 000103).** Once
  registered, Claude Code launches the launcher and PSES reaches "Starting Language Server", but the
  LSP client rejects the standard server->client requests PSES sends at initialization (the
  `#1359`-class handshake), so on the **direct** launcher (`pses-stdio.ps1`) init times out (~30 s).
  The launcher is provably stdout-clean (its first stdout line is a valid `Content-Length:` header),
  so the gap is the **Claude Code LSP client**, not our launcher. Dispatch 000103 ships an **opt-in
  stdio proxy** (`scripts/pses-serve-shim.ps1`, selected by `nativeServe = shim`) that patches the
  forwarded `initialize` (disable `dynamicRegistration` -> PSES advertises its nav providers
  statically and sends no `client/registerCapability`; drop the params-level `workspaceFolders`
  #2300 dodge; ensure a `rename` capability) and answers the residual `workspace/configuration` +
  `window/workDoneProgress/create` locally -- so hover / definition / references / documentSymbol
  serve end-to-end **without** the upstream fix, at ~1-2 ms added framing latency per round-trip.
  Upstream `anthropics/claude-plugins-official#1359` remains **open** (open/unassigned as of
  2026-07-02); the shim is a local workaround, **off by default**, removable when the client is fixed
  (see "Removability, and how to learn the shim is removable" below).

**Fix (shipped under dispatch 000075):** delete `restartOnCrash` and `shutdownTimeout` from
`plugin.json` `lspServers.powershell`; keep `command`, `args`, `extensionToLanguage`, `transport`,
`startupTimeout`, `maxRestarts`, `env` (all proven registrar-clean). A regression guard
(`tests/PowerShellLsp.Unit.Tests.ps1`) fails CI if any `lspServers` entry ever re-declares a field
outside that allowlist.

## The native LSP launcher guard -- a second, independent blocker (Windows; dispatch 000107, upstream `#73961`)

**Status (2026-07-03, dispatch 000107 -- survey verified).** On **Windows**, Claude Code 2.1.200's
native LSP launcher refuses to start this plugin's registered server before any plugin code runs.
Against the installed v1.23.0 -- whose `lspServers.powershell.command` is the bare string `pwsh` -- a
`goToDefinition` driven through Claude Code's builtin LSP tool returns, verbatim:

```
Command 'pwsh' not found or is in an unsafe location (current directory)
```

No `pwsh` process starts. This is a **second blocker, independent of the `#1359` serve handshake** above:
it fires **pre-spawn** in Claude Code's native LSP launcher -- **upstream of the shim, `pses-stdio.ps1`,
and PSES** -- so it is reached whether `nativeServe` is `off` or `shim` (neither the relay nor the proxy
has run yet). Where `#1359` is a serve-layer gap the shim closes once PSES is running, this guard is a
spawn-layer refusal the plugin cannot reach around from inside its own launcher.

**The guard mechanism (per dispatch 000107).** The launcher routes the server `command` through an
unconditional `where.exe`-based safe-resolver that dispatches on the command's **shape**: any command
containing a path separator (`/` or `\`) is passed through and spawned as-is, while a **bare name** (no
separator) is sent to a resolver that returns null -- and null throws the refusal above -- unless a
candidate both exists, sits outside the current directory, and ends in `.com`/`.exe`/`.bat`/`.cmd`. On
the surveyed machine `where.exe pwsh` and `where.exe powershell` both resolve to real executables
(Program Files / System32), yet both bare names are refused in a fresh session -- consistent with the
sibling reports `#67821` / `#42135`, where the launcher's spawn-context PATH is reduced/sanitized and a
failed resolution is cached as null for the session. A separator-bearing command bypasses the resolver
entirely: dispatch 000107 confirmed an absolute path and a `${CLAUDE_PLUGIN_ROOT}`-anchored `.cmd`
wrapper both spawn, while bare `pwsh` and bare `powershell` both refuse.

**Regression window: (2.1.195, 2.1.200].** On Claude Code **2.1.195** (dispatch 000069) the registered
launcher **launched** bare `pwsh` -- PSES reached "Starting Language Server" and init then timed out on
the `#1359` handshake -- so the spawn itself succeeded there. On **2.1.200** the same command is refused
**pre-spawn**. The 2.1.196-2.1.200 changelog records no command-resolution or LSP-launcher change; the
application to the LSP launcher was silent.

**Not plugin-specific; the diagnostics path is unaffected.** Dispatch 000107 reproduced the identical
refusal on the **official `pyright-lsp` plugin** (`command: "pyright-langserver"`, bare) through the
same builtin LSP tool, while `typescript-lsp` served -- so this is a broad Claude-Code-on-Windows
launcher regression, not a powershell-lsp defect. Crucially, the plugin's **PostToolUse diagnostics are
unaffected**: the warm daemon runs bare `pwsh` through a **different, unguarded** shell-spawn path (the
plugin's hooks, not the native LSP launcher), so per-file PSScriptAnalyzer diagnostics -- the plugin's
primary value -- keep working normally on Windows. Only the opt-in `nativeServe` navigation tier is
blocked, and only on Windows.

**macOS and Linux under these Claude Code versions are untested with the real client.** Dispatch 000107
characterized the guard on Windows only. The real-client status of the native nav tier on macOS and
Linux under Claude Code 2.1.196-2.1.200 has **not** been probed, and is **not** claimed here in either
direction.

**Upstream: `anthropics/claude-code#73961` (open).** The guard is filed upstream as
[anthropics/claude-code#73961](https://github.com/anthropics/claude-code/issues/73961) (labeled bug /
platform:windows / area:lsp / area:plugins / has-repro), with the same-root-cause siblings `#67821`
(bare `cmd` in `/desktop`) and `#42135` (bare `git` in marketplace update).

**Verdict: wait for upstream.** Per dispatch 000107 the fix is not the plugin's to make cleanly. A single
`lspServers.command` string cannot be both a Windows `.cmd` wrapper and a cross-platform launcher (Claude
Code offers no per-platform `command` field), and the natural absolute-path workaround
`C:\Program Files\PowerShell\7\pwsh.exe` fails `claude plugin validate` because the manifest validator
rejects a `command` containing a space unless it starts with `/`. Because the same resolver also breaks
an official Anthropic LSP plugin and the git/cmd subsystems, one upstream fix -- resolve via a full PATH,
stop caching null, or add per-platform command support -- resolves it for every affected plugin at once.
The native nav tier is therefore documented as **blocked on Windows Claude Code 2.1.196-2.1.200**, pending
`#73961`.

**Contingent build trigger.** A `${CLAUDE_PLUGIN_ROOT}`-anchored Windows `.cmd` wrapper is the only
launcher-clean, machine-portable local lane (dispatch 000107 proved it spawns), and it becomes the
**recommended build for Windows native nav if and only if** Claude Code ships per-platform
`lspServers.command` support (suggested fix (c) in `#73961`) -- which would let the wrapper be Windows-only
while bare `pwsh` stays the Unix command -- **or** the launcher resolver/guard is fixed so a bare `pwsh`
spawns again. Until one of those lands upstream, no local build is unblocked and none is minted here.

## Removability, and how to learn the shim is removable (dispatch 000103)

The `nativeServe` shim exists **only** to route around the upstream `#1359` client bug. When Claude
Code's LSP client is fixed to answer the standard server->client requests natively, the shim is
obsolete and should be removed. Because the shim withholds the intercepted requests from the client,
it cannot itself observe the client handling them natively -- so removability is learned by a
**re-probe** of the direct launcher: an automated first-line doctor check (dispatch 000104, below)
for the static-serving path, plus a deliberate manual real-`claude -p` re-probe that stays
authoritative for a client-side fix:

- **How Mike learns it is removable (the re-probe).** Re-run the 000069 registration/serve harness
  (a real `claude -p` builtin-`LSP` `goToDefinition`, `raw-probes/` + `harness/run-lsp-probe.ps1`
  under `projects/powershell-lsp/outbox/000069-artifacts/` in the Strategic Dispatch Hub) against the
  **direct** launcher (`pses-stdio.ps1`, shim bypassed -- e.g. temporarily point `lspServers` back at
  it, or set `nativeServe = off` which relays transparently). **Today that returns the ~30 s init
  timeout.** When it instead returns a **served** result (`Defined in ...`), the Claude Code client is
  answering the handshake natively and the shim is no longer needed.
- **Removal path (ranked).** (a) **Manifest command swap (recommended, full removal):** point
  `lspServers.powershell` `args` `-File` back at `scripts/pses-serve-shim.ps1` -> `scripts/pses-stdio.ps1`;
  the shim file may stay dormant, no code deletion. (b) `nativeServe = off` (already the default) is a
  transparent relay -- no serve behavior, but PSES still runs as a shim child. (c) Full deletion of
  `scripts/pses-serve-shim.ps1` + `scripts/lib/serve-shim-common.ps1` + the `nativeServe` knob (a MAJOR,
  since it removes a knob name) once the upstream fix has shipped widely. The shim adds no daemon,
  diagnostics, or corpus coupling, so removal is transport-local.
- **Automated first-line check (shipped, dispatch 000104, v1.23.0): `doctor.ps1 -ProbeNativeServe`.**
  The report-only doctor carries an OPT-IN native-serve removability probe -- run
  `pwsh -File scripts/doctor.ps1 -ProbeNativeServe`. It launches PSES via the **direct** launcher
  (`pses-stdio.ps1`, shim bypassed) through a pwsh subprocess (`scripts/probe-native-serve.ps1`),
  sends a Claude-Code-shaped `initialize` (rich caps, `dynamicRegistration=true`), and inspects the
  initialize **result**: today PSES defers the nav providers to `client/registerCapability` (no
  static nav in the result) and the probe reports **still gated -- the shim remains needed**; the day
  the direct launcher advertises hover / definition / references **statically** it reports **native
  serve now works directly -- the shim can be removed**. The discriminator is the result CONTENT (are
  the nav providers advertised statically?), not a race against the ~30 s stall, so it is bounded (a
  ~20 s init-result cap) and CI-runnable -- unlike the manual re-probe above it needs **no** real
  `claude -p`. It is opt-in (off by default) because it costs a PSES cold-start. **Scope (honest):**
  the scripted client detects the STATIC-serving removability path (PSES advertising nav statically
  under rich caps -- the shim's own `dynamicRegistration=false` mechanism becoming native). A purely
  **client-side** `#1359` fix (Claude Code completing the dynamic-registration handshake so nav
  registers dynamically) serves WITHOUT changing the static init result and is **not** caught here --
  that case still needs the manual real-`claude -p` re-probe above, which stays authoritative. The
  probe never yields a false "removable"; it errs toward keeping the shim. Note that this probe launches
  PSES **directly** (a pwsh subprocess) and so speaks only to the `#1359` serve handshake; it does not
  exercise Claude Code's native LSP launcher, so it cannot detect the separate Windows launcher guard
  documented in "The native LSP launcher guard" above (dispatch 000107, upstream `#73961`). That guard is
  client-side; whether it has been lifted is learned only from the manual real-`claude -p` re-probe, not
  from this check.

---

## Evidence (dispatch 000069, Claude Code 2.1.195)

Every probe drove a single builtin-`LSP` `goToDefinition` through a fresh non-interactive
`claude -p` against an **installed local-dir marketplace plugin** (never `--plugin-dir`). The 23
recorded probes and the harness live under
`projects/powershell-lsp/outbox/000069-artifacts/` in the Strategic Dispatch Hub
(`raw-probes/`, `harness/run-lsp-probe.ps1`, `expected-signals.txt`). Verdict strings:

- `No LSP server available for file type: .ps1` -> the ext->server mapping was **NOT** registered.
- `No definition found` / `Defined in ...` -> **REGISTERED and served** (a known-good command).
- `... timed out after 30000ms during initialization` -> **REGISTERED**; Claude Code launched the
  server, PSES init did not complete (the serve track, not registration).

Single-field isolation in `plugin.json` (known-good block = GJ):

| Variant | Block delta | `.ps1` result |
|---------|-------------|---------------|
| GJ knowngood-in-pluginjson | clean block, no restart/shutdown fields | REGISTER (served) |
| GJ + `transport` / `maxRestarts` / `env` | each added alone | REGISTER (served) |
| GJ + `restartOnCrash` (alone) | **breaker** | FAIL (no server) |
| GJ + `shutdownTimeout` (alone) | **breaker** | FAIL (no server) |
| A baseline (shipped tree) | real block: both breakers present | FAIL (no server) |
| RFX2 real minus `restartOnCrash` | one breaker removed, `shutdownTimeout` remains | FAIL (no server) |
| RFX3 real minus **both** breakers | **the fix** | REGISTER (launch; init timeout) |

So **both** fields must be removed (RFX2 with only one removed still fails), and the dispatch's
original top suspect -- the `env` / `${CLAUDE_PLUGIN_DATA}` block -- is **refuted** (GJ + env
registers).

### Which manifest Claude Code reads

When a plugin ships a `plugin.json`, Claude Code registers `lspServers` from **`plugin.json`** and
**ignores** the `marketplace.json` entry. The `marketplace.json` `lspServers` is consulted only for
plugins that ship **no** `plugin.json` -- which is how the official LSP plugins work (they ship only
`LICENSE` + `README`, and register from the marketplace entry). A plugin that needs a `plugin.json`
(for hooks / userConfig, as this one does) must therefore carry a **registrar-clean** `lspServers`
in `plugin.json`; putting it only in `marketplace.json` is inert while a `plugin.json` exists.

### Relationship to the upstream issues

- **`claude-code#14803` (registration race, fixed) / `#15168` / `#15148`.** The
  `LspServerManager` init-ordering race these track is **not** what blocked this plugin on 2.1.195:
  the control plugins register, so the registrar runs. Our miss was the two-field drop, a distinct
  defect.
- **`claude-plugins-official#379` (marketplace packaging gap).** Still real and still open: a
  marketplace install copies only the source directory, so an `lspServers` block living **solely**
  in `marketplace.json` is dropped. It does not affect us once the `plugin.json` block is
  registrar-clean (we register from `plugin.json`, which the installer does copy).
- **`#1359`-class server->client init handshake.** The remaining **serve** gap after registration
  is restored. Upstream / Claude-Code-side.
- **`#66987`.** The plugin-manifest LSP-registration tracking issue this plugin cites. The accurate
  reframing: the platform registration path is effective; the registrar **silently rejects**
  schema-valid `restartOnCrash` / `shutdownTimeout`, which is the report worth filing (separate,
  Mike-gated, not posted here).

---

## Historical record -- the symptom before the root cause was isolated

The probes below are retained for provenance. They captured the **symptom** (`No LSP server
available`) on Claude Code 2.1.167 through 2.1.183, before the 2.1.195 single-field matrix isolated
the cause. They remain accurate for those builds; they are **not** evidence of blanket platform
inertness, which 000069 refuted. (The probes varied a plugin-provided `.lsp.json` file; the 000069
work later established that with a `plugin.json` present, `plugin.json`'s `lspServers` is
authoritative and the standalone `.lsp.json` path is moot for this plugin.)

The canonical probe -- builtin `LSP` `goToDefinition` on `./test.ps1`, via a fresh `claude -p`
(`--allowedTools LSP --strict-mcp-config --output-format stream-json --verbose`) -- returned, on
2.1.167, 2.1.168, and 2.1.183:

```
tool_use   : {"operation":"goToDefinition","filePath":"./test.ps1","line":5,"character":6}
tool_result: No LSP server available for file type: .ps1
```

across three configurations: a `--plugin-dir` session-load with a literal top-level-map `.lsp.json`;
that same `.lsp.json` shipped inside a throwaway plugin and installed through the real `/plugin`
flow (so the installer placed it in the cache); and the installed real plugin (whose cache carried
a template-var `.lsp.json`). The harness checks **file existence before server availability** -- the
probed `.ps1` must exist on disk to reach the registration check (a missing path short-circuits to
`File does not exist: ...` and never reaches the registrar; confirmed 2026-06-19).

**Good path, unaffected throughout.** In every build, an interactive `.ps1` edit fired the
PostToolUse hook and the warm per-session PSES returned a PSScriptAnalyzer diagnostic
(`PSUseApprovedVerbs`) via `additionalContext`. The plugin's real value -- per-file diagnostics over
the warm hook -- never depended on native registration and is untouched by this fix.

### Environment

- Claude Code: 2.1.167 (2026-06-06) through 2.1.183 (2026-06-19) for the historical symptom record;
  **2.1.195 (2026-06-26) for the 000069 root-cause isolation**.
- Plugin: powershell-lsp (standalone repo); server declared in `plugin.json` `lspServers` (the
  authoritative surface) + a standalone `docs/lsp.json.template`.
- PSES `v4.6.0`, PSScriptAnalyzer `1.25.0`; Windows 11.
- Harness: `claude -p --allowedTools LSP ToolSearch --strict-mcp-config --mcp-config
  '{"mcpServers":{}}' --output-format stream-json --verbose`; builtin `LSP` tool invoked;
  `tool_use` / `tool_result` read from the event stream (not a prompt echo). Installed-plugin cases
  reached via `claude plugin marketplace add <local-dir>` + `claude plugin install` (the installer
  populated the cache), then a fresh `claude -p` with no `--plugin-dir`.
