# Upstream draft -- Claude Code: plugin LSP registration (narrowed-gap datapoint)

**Target:** a comment on an open registration thread -- best fits
[`anthropics/claude-code#15168`](https://github.com/anthropics/claude-code/issues/15168)
("LSP plugin system not connecting ... always 'No LSP server available'") or
[`#15148`](https://github.com/anthropics/claude-code/issues/15148)
("lspServers config not being processed from marketplace.json"). The related
`.lsp.json` packaging gap is tracked (open) at
[`anthropics/claude-plugins-official#379`](https://github.com/anthropics/claude-plugins-official/issues/379).

**Status:** DRAFT for Mike's review. **Not posted.** The clean re-test came back INERT
in every configuration tested -- but one configuration (a `.lsp.json` **file** inside an
already-installed plugin's cache directory, the exact setup phpmac reports working on
#15148) was deliberately NOT tested, to avoid writing into the installer-owned plugin
cache; the re-test used `--plugin-dir` session-load instead. So this **narrows** the gap
and strengthens the earlier finding, but does **not** cleanly refute the installed-plugin
"it works" reports. Treat it as a partial datapoint plus an open question, not a verdict.
Post only on Mike's say-so -- and only after the installed-cache path is tested, or with
the post framed to acknowledge it.

---

## Comment body (draft)

A third-party datapoint from outside the official marketplace: **powershell-lsp**, a
PowerShell Editor Services (PSES) plugin for `.ps1/.psm1/.psd1` --
https://github.com/manderse21/claude-powershell-lsp.

**The server itself works.** The PSES stdio handshake, `publishDiagnostics` on a parse
error, hover, and go-to-definition are verified on both `pwsh` 7 and Windows PowerShell
5.1. The plugin declares an `lspServers` block in `plugin.json` and ships a standalone
`.lsp.json` template.

**Native registration is still inert on 2.1.167 -- including with a clean, literal
`.lsp.json` present and a full restart.** I re-tested with the strict methodology
(rather than relying on `/reload-plugins` or template-variable expansion):

- a **clean top-level-map** `.lsp.json` (`{ "powershell": { "command": ..., "args": [...],
  "extensionToLanguage": {...} } }`), matching the shape PR #378 proposed for the
  official plugins;
- **literal** commands only -- no `${CLAUDE_PLUGIN_ROOT}` or `${user_config.*}`
  template variables (absolute `pwsh` + absolute script path + a literal
  `PSES_BUNDLE_PATH`);
- loaded into a **freshly started** Claude Code process via `--plugin-dir` (a real
  restart, not `/reload-plugins`), which sidesteps the install/cache-copy gap below by
  putting the `.lsp.json` directly in a loaded plugin directory.

The builtin `LSP` tool, asked to `goToDefinition` on a `.ps1`, still returned verbatim:

```
No LSP server available for file type: .ps1
```

(`LSP` tool input: `{"operation":"goToDefinition","filePath":"./test.ps1","line":6,"character":6}`;
Claude Code 2.1.167; 2026-06-06; the tool call was confirmed real via
`--output-format stream-json`, not an echo of the prompt.) So the inertness is **not** a
reload-vs-restart artifact and **not** a template-variable-expansion artifact -- at
least not for a plugin loaded via `--plugin-dir`.

**Caveat -- what was NOT tested.** The `--plugin-dir` load path is not identical to an
installed plugin. The setup phpmac reports working on #15148 is a `.lsp.json` **file**
inside an already-*installed* plugin's cache directory; I did not test that, because it
means writing into the installer-owned plugin cache. Plugin load *timing* relative to
`LspServerManager` init (the #15168 / #14803 race) could differ between session-load and
cache-install, so a `--plugin-dir` null does not by itself disprove the installed-plugin
reports. The cleanest next test is a `.lsp.json` file dropped into an installed plugin's
cache directory followed by a full restart.

**Relationship to the packaging gap (#379).** #379 documents that installing a
marketplace LSP plugin copies only the source directory into the cache, so an
`lspServers` block living solely in `marketplace.json` is dropped and the installed
plugin ships with nothing but `README.md` (0 servers). The proposed fix,
[PR #378](https://github.com/anthropics/claude-plugins-official/pull/378) (add a real
`.lsp.json` to each official plugin directory), was **closed unmerged (2026-02-11)**, so
#379 is still open and unaddressed. The `--plugin-dir` re-test puts the `.lsp.json`
physically in a loaded plugin directory and registration *still* fails there -- which,
modulo the load-path caveat above, points past the packaging gap toward the registration
path itself (the `LspServerManager` init-ordering / "0 servers" symptom in #15168 / #15148).

**Open sub-question (not tested here):** whether `${CLAUDE_PLUGIN_ROOT}` /
`${user_config.*}` template variables expand inside `.lsp.json` `command`/`args`/`env`.
This re-test deliberately used literal paths to isolate the registration question; the
substitution question is moot while registration is inert, but it matters the moment
registration is fixed.

**Workaround in shipping use.** Because native registration cannot be relied on, the
plugin delivers diagnostics through a warm, per-session **PostToolUse hook** (one PSES
stays hot for the session; each edit is a pipe round-trip, ~2 s, vs a ~6 s cold start).
That works today on every supported host and is independent of the registration path --
but it is a workaround for this bug, not a replacement for a fix.

### Environment

- Claude Code: 2.1.167 (2026-06-06)
- Plugin: powershell-lsp (standalone repo); `lspServers` in `plugin.json` +
  `docs/lsp.json.template`
- PSES `v4.6.0`, PSScriptAnalyzer `1.25.0`; Windows 11
- Re-test harness: `claude -p --plugin-dir <dir-with-clean-literal-.lsp.json>
  --allowedTools LSP`, builtin `LSP` tool invoked (confirmed via `--output-format
  stream-json`)

Happy to share the test plugin, logs, or test a patch build.
