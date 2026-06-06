# Upstream draft -- Claude Code: plugin LSP registration (definitive negative datapoint)

**Target:** a comment on an open registration thread -- best fits
[`anthropics/claude-code#15168`](https://github.com/anthropics/claude-code/issues/15168)
("LSP plugin system not connecting ... always 'No LSP server available'") or
[`#15148`](https://github.com/anthropics/claude-code/issues/15148)
("lspServers config not being processed from marketplace.json"). The related
`.lsp.json` packaging gap is tracked (open) at
[`anthropics/claude-plugins-official#379`](https://github.com/anthropics/claude-plugins-official/issues/379).

**Status:** DRAFT for Mike's review. **Not posted.** This supersedes the earlier
"narrowed-gap" draft: the one configuration that draft left untested -- a `.lsp.json`
**file** inside an already-*installed* plugin's cache directory -- has now been tested
(reached through the real `/plugin` install flow, so the installer placed the file in the
cache; no hand-writing of the cache). It is **inert too**. The finding is therefore a
definitive refutation, for Claude Code 2.1.167, of the reports that a plugin `.lsp.json`
registers a server -- including the installed-cache configuration. Post only on Mike's
say-so.

---

## Comment body (draft)

A third-party datapoint from outside the official marketplace: **powershell-lsp**, a
PowerShell Editor Services (PSES) plugin for `.ps1/.psm1/.psd1` --
https://github.com/manderse21/claude-powershell-lsp.

**The server itself works.** The PSES stdio handshake, `publishDiagnostics` on a parse
error, hover, and go-to-definition are verified on `pwsh` 7 and Windows PowerShell 5.1,
on Windows and (as of this release) Linux CI.

**A plugin-provided `.lsp.json` does not register on 2.1.167 -- in any configuration I
could test, including the installed-plugin-cache path.** Every `LSP` tool call below was
confirmed real via `--output-format stream-json` (a single `LSP` `tool_use` + its
`tool_result`, not a prompt echo).

1. **`--plugin-dir` session-load, literal `.lsp.json`** (clean top-level map; literal
   `pwsh` + absolute script path + literal `PSES_BUNDLE_PATH`; no
   `${CLAUDE_PLUGIN_ROOT}`/`${user_config.*}` variables; full restart, not
   `/reload-plugins`):

   ```
   tool_use   : {"operation":"goToDefinition","filePath":"./test.ps1","line":5,"character":6}
   tool_result: No LSP server available for file type: .ps1
   ```

2. **Installed-cache, literal `.lsp.json` (the previously-untested path).** A throwaway
   plugin whose *source* ships the same clean literal `.lsp.json` was installed through
   the real `/plugin` flow (`claude plugin marketplace add` + `claude plugin install`),
   so the **installer** copied the file into the cache --
   `~/.claude/plugins/cache/<marketplace>/<plugin>/0.0.1/.lsp.json` -- reaching the exact
   reported-working setup with zero hand-writes. After a full restart (a fresh
   `claude -p`, no `--plugin-dir`), probing a unique extension only this plugin declared:

   ```
   tool_use   : {"operation":"goToDefinition","filePath":"./test.ps1x","line":5,"character":6}
   tool_result: No LSP server available for file type: .ps1x
   ```

3. **The installed real plugin** (its cache already carries a template-var `.lsp.json`)
   is inert the same way: `goToDefinition` on a `.ps1` returns
   `No LSP server available for file type: .ps1`.

So the inertness of a plugin `.lsp.json` file is **not** a reload-vs-restart artifact,
**not** a template-variable artifact, and **not** a `--plugin-dir`-vs-installed-cache
artifact. On 2.1.167 a `.lsp.json` file shipped in a plugin does not register a server,
in any configuration I could reach.

**Relationship to the packaging gap (#379).** #379 documents that installing a
marketplace LSP plugin copies only the source directory into the cache, so an
`lspServers` block living solely in `marketplace.json` is dropped and the installed
plugin ships with nothing but `README.md` (0 servers). The proposed fix,
[PR #378](https://github.com/anthropics/claude-plugins-official/pull/378) (add a real
`.lsp.json` to each official plugin directory), was **closed unmerged (2026-02-11)**, so
#379 is still open and unaddressed. The installed-cache re-test above puts a real
`.lsp.json` physically in the installed plugin's cache and registration *still* fails --
which points past the packaging gap toward the registration path itself (the
`LspServerManager` init-ordering / "0 servers" symptom in #15168 / #15148).

**Open sub-question (not tested here):** whether `${CLAUDE_PLUGIN_ROOT}` /
`${user_config.*}` template variables expand inside `.lsp.json` `command`/`args`/`env`.
This testing deliberately used literal paths to isolate the registration question; the
substitution question is moot while registration is inert, but it matters the moment
registration is fixed.

**Workaround in shipping use.** Because native registration cannot be relied on, the
plugin delivers diagnostics through a warm, per-session **PostToolUse hook** (one PSES
stays hot for the session; each edit is a pipe round-trip, ~2 s, vs a ~6 s cold start).
That works today on every supported host and is independent of the registration path --
but it is a workaround for this bug, not a replacement for a fix.

**On the "it works" reports.** Reports of a `.lsp.json` file in an installed plugin's
cache working are most likely a **Claude Code version difference** -- this datapoint is
2.1.167 specifically; the registrar behavior may differ in other builds. If a maintainer
can name the build where the installed-cache `.lsp.json` path registered, that would
localize the regression.

### Environment

- Claude Code: 2.1.167 (2026-06-06)
- Plugin: powershell-lsp (standalone repo); server declared in `plugin.json` `lspServers`
  + `docs/lsp.json.template`
- PSES `v4.6.0`, PSScriptAnalyzer `1.25.0`; Windows 11
- Harness: `claude -p --allowedTools LSP --strict-mcp-config --mcp-config '{"mcpServers":{}}'
  --output-format stream-json`; builtin `LSP` tool invoked; `tool_use`/`tool_result`
  read from the event stream (not a prompt echo). Installed-cache case reached via
  `claude plugin marketplace add` + `claude plugin install` (the installer populated the
  cache), then a fresh `claude -p` with no `--plugin-dir`.
