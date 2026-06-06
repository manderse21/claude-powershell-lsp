# Upstream draft -- Claude Code: plugin LSP registration (working datapoint)

**Target:** a comment on an open registration thread. Best fits
`anthropics/claude-code#15168` ("LSP plugin system not connecting ... always 'No LSP
server available'") or `#15148` ("lspServers config not being processed from
marketplace.json"). The related `.lsp.json` packaging gap is tracked (open) at
`anthropics/claude-plugins-official#379` (fix in PR #378).

**Status:** DRAFT for Mike to post. The `.lsp.json` live-test result is PENDING a
clean Claude Code session -- see the TODO marker; fill it before posting (that
result is the fresh evidence this comment is meant to contribute).

---

## Comment body

Adding a third-party datapoint from outside the official marketplace:
**powershell-lsp**, a PowerShell Editor Services (PSES) plugin for
`.ps1/.psm1/.psd1` -- https://github.com/manderse21/claude-powershell-lsp.

The underlying server works: the PSES stdio handshake, `publishDiagnostics` on a
parse error, hover, and go-to-definition are verified on both `pwsh` 7 and Windows
PowerShell 5.1. The plugin declares an `lspServers` block in `plugin.json`. Even so,
the builtin `LSP` tool reports `No LSP server available for file type: .ps1` -- the
plugin-contributed server is never registered, matching this thread.

Because native registration could not be relied on, the plugin delivers diagnostics
through a **PostToolUse hook** backed by a warm, per-session PSES daemon (one PSES
stays hot for the session; each edit is a pipe round-trip, ~2 s, instead of a ~6 s
cold start). That works today and is independent of the registration path -- but it
is a workaround for this bug, not a replacement for a fix.

### `.lsp.json` test result

Tested on **Claude Code 2.1.167** (2026-06-06): from a clean install of the plugin via
its own marketplace, I copied the server declaration to the installed plugin root as
`.lsp.json` and `/reload-plugins`. **Native registration did not activate** -- the
builtin `LSP` tool, asked to `goToDefinition` on a `.ps1`, returned verbatim:

```
No LSP server available for file type: .ps1
```

So a plugin-root `.lsp.json` is **inert** on 2.1.167 -- the registration path is still
not wired for plugin-provided servers, matching this thread. Throughout, the plugin's
diagnostics kept arriving via the PostToolUse hook; a doubling check after the flip
showed the diagnostic exactly **once**, i.e. no native path fired alongside the hook.

### Environment

- Claude Code: <version under test>
- Plugin: powershell-lsp 1.1.0, installed via `/plugin marketplace add manderse21/claude-powershell-lsp`
- PSES `v4.6.0`, PSScriptAnalyzer `1.25.0`; Windows 11

Happy to share logs or test a patch build.
