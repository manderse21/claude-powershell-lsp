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
- **End-to-end SERVE is still gated, upstream-side.** Once registered, Claude Code launches the
  PSES launcher and PSES reaches "Starting Language Server", but the LSP client times out at
  initialization (the `#1359`-class server->client init handshake). The launcher is provably
  stdout-clean (its first stdout line is a valid `Content-Length:` header), so the remaining gap
  is the **Claude Code LSP client**, not our launcher. Registration is restored here; serve is
  tracked separately and is not this plugin's to fix.

**Fix (shipped under dispatch 000075):** delete `restartOnCrash` and `shutdownTimeout` from
`plugin.json` `lspServers.powershell`; keep `command`, `args`, `extensionToLanguage`, `transport`,
`startupTimeout`, `maxRestarts`, `env` (all proven registrar-clean). A regression guard
(`tests/PowerShellLsp.Unit.Tests.ps1`) fails CI if any `lspServers` entry ever re-declares a field
outside that allowlist.

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
