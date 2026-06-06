# Upstream draft -- Claude Code: plugin LSP registration (definitive datapoint)

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
(reached through the real `/plugin` install flow, so the installer placed the file in
the cache; no hand-writing of the cache). It is **inert too**. The finding is therefore
definitive for Claude Code 2.1.167, with one important correction to the earlier
framing: native registration is **not globally broken** -- a `.lsp.json` *file* is
inert, but `lspServers` declared in a **marketplace manifest** registers fine. Post only
on Mike's say-so.

---

## Comment body (draft)

A third-party datapoint from outside the official marketplace: **powershell-lsp**, a
PowerShell Editor Services (PSES) plugin for `.ps1/.psm1/.psd1` --
https://github.com/manderse21/claude-powershell-lsp.

**The server itself works.** The PSES stdio handshake, `publishDiagnostics` on a parse
error, hover, and go-to-definition are verified on `pwsh` 7 and Windows PowerShell 5.1,
on Windows and (as of this release) Linux CI.

### A plugin-shipped `.lsp.json` file does not register on 2.1.167 -- in any configuration

I tested every configuration of a plugin-provided `.lsp.json`, including the
installed-plugin-cache path that prior "it works" reports describe. All inert. The
`LSP` tool calls below were confirmed real via `--output-format stream-json` (a single
`LSP` `tool_use` + its `tool_result`, not a prompt echo).

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
   `claude -p`, no `--plugin-dir`), probing a unique extension that only this plugin
   declared:

   ```
   tool_use   : {"operation":"goToDefinition","filePath":"./test.ps1x","line":5,"character":6}
   tool_result: No LSP server available for file type: .ps1x
   ```

3. **The installed real plugin** (its cache already carries a template-var `.lsp.json`)
   is inert the same way: `goToDefinition` on a `.ps1` returns
   `No LSP server available for file type: .ps1`.

So the inertness of a plugin `.lsp.json` file is **not** a reload-vs-restart artifact,
**not** a template-variable artifact, and **not** a `--plugin-dir`-vs-installed-cache
artifact. On 2.1.167 a `.lsp.json` *file* shipped in a plugin does not register a
server.

### What DOES register: `lspServers` in a marketplace manifest

The same harness, run as a control against the official `pyright-lsp` plugin, behaves
**differently**:

```
tool_use   : {"operation":"goToDefinition","filePath":"./test.py","line":5,"character":1}
tool_result: Error performing goToDefinition: ENOENT: no such file or directory, uv_spawn 'pyright-langserver'
```

That is registration **working**: Claude Code found a registered server for `.py` and
tried to spawn `pyright-langserver` (it just is not installed on this box). Note that
`pyright-lsp`'s installed cache contains only `LICENSE` and `README.md` -- no
`.lsp.json`, no `plugin.json` -- yet it registers. Its `lspServers` block lives in the
**marketplace manifest** (`anthropics/claude-plugins-official` `marketplace.json`), which
Claude Code harvests into its plugin catalog (`~/.claude/plugins/plugin-catalog-cache.json`
carries the `pyright-langserver` command). `typescript-lsp` is declared the same way.

So registration is **not** globally broken on 2.1.167. The path Claude Code honors is
**`lspServers` declared in a marketplace manifest and cataloged**, *not* a `.lsp.json`
file shipped inside the plugin (cache or `--plugin-dir`) and *not* an `lspServers` block
in `plugin.json`. A plugin that publishes its server only as a `.lsp.json` file (this
one did) gets `No LSP server available`.

### Relationship to the open issues

- **#15168 / #15148 ("always No LSP server available", "lspServers not processed from
  marketplace.json").** For a plugin relying on a `.lsp.json` file, the "always inert"
  symptom reproduces deterministically here. But marketplace-manifest `lspServers` *are*
  processed (pyright/typescript register), so the title of #15148 is too broad for
  2.1.167 -- the gap is specifically the `.lsp.json`-file path, not all manifest
  `lspServers`.
- **#379 (installing copies only a plugin's source into the cache, dropping a
  marketplace-only `lspServers`).** The packaging copy still drops the file, but it does
  not cause "0 servers" for the official plugins, because Claude Code registers their
  `lspServers` from the **cataloged marketplace manifest**, not from the cache. PR #378
  (add a real `.lsp.json` to each official plugin) was **closed unmerged** (2026-02-11),
  consistent with the `.lsp.json`-file path not being the mechanism that registers.

### Why this matters / the ask

If a plugin-shipped `.lsp.json` is intended to register a server (the
[docs](https://code.claude.com/docs/en/plugins-reference#lsp-servers) describe it as
the per-plugin path), then on 2.1.167 it does not -- only cataloged marketplace-manifest
`lspServers` do. Either the `.lsp.json`-file path should be wired to the same registrar,
or the docs should point plugin authors at the marketplace-manifest path. Happy to share
the throwaway test plugin, the stream-json transcripts, or test a patch build.

### On the "it works" reports

The reports of a `.lsp.json` file in an installed plugin's cache working are most likely
a **Claude Code version difference** -- this datapoint is 2.1.167 specifically; the
registrar behavior may differ in other builds. (If a maintainer can name the build where
the installed-cache `.lsp.json` path registered, that would localize the regression.)

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
