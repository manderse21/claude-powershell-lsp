# Why a hook, not native `.lsp.json` registration

Why this plugin ships diagnostics over a PostToolUse hook even though native registration works.
Summarized in [README, Why a hook](../README.md#why-a-hook-not-native-lspjson-registration); this
page is the full text.

Claude Code declares plugin language servers through an inline `lspServers` block in
`plugin.json`. This plugin carries that block, and as of v1.18.1 the manifest-side blocker that
kept it from registering is removed -- so native **registration** is no longer the obstacle. The
plugin still ships diagnostics over a **warm PostToolUse hook** for one reason: **registration is
restored, but end-to-end serve is not.** Claude Code's LSP client rejects the standard
server-to-client requests PSES sends during initialization (the `#1359`-class handshake), so on
the **direct** path init times out and native nav does not serve -- gated upstream, not on this
plugin's launcher. The opt-in
[`nativeServe = shim`](../README.md#2-native-code-navigation-opt-in) closes that gap locally.

The full history -- the marketplace packaging gap, the registration race, and the two manifest
fields (`restartOnCrash`, `shutdownTimeout`) that Claude Code's registrar silently drops (now
CI-guarded) -- plus the 23-probe methodology matrix and the standalone
[`docs/lsp.json.template`](lsp.json.template), are in
[`docs/upstream/claude-code-lsp-registration.md`](upstream/claude-code-lsp-registration.md).

> **Heads-up for when serve lands -- duplicate diagnostics.** If native serving ever completes
> (the upstream init handshake is fixed) while the PostToolUse hook is also enabled, each
> diagnostic could arrive twice. Use one path or the other.
