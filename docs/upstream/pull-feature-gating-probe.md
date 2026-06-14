# Track B findings -- can pull-model LSP features ship on the current surface?

**Dispatch:** powershell-lsp/000015, Track B (read-only gating probe).
**Date:** 2026-06-14. **No code change** -- this note only orders the next dispatch.

## Question

Can the four pull-model LSP features -- **hover, go-to-definition, find-references,
document-symbols** -- be delivered to Claude / the user through the surface this plugin
ships today, or are they gated on native plugin LSP-server registration (Claude Code
issue [#66987](https://github.com/anthropics/claude-code/issues/66987))?

## Verdict: **#66987-gated** (NOT buildable-now)

Pull-model features cannot be delivered through the current surface today. The block is
the Claude-Code-side plugin LSP-server **registration** path, which is empirically inert.
It is **not** a PSES capability gap and **not** a hook-surface gap.

## Evidence (from source, not inference)

1. **The only request-shaped home for pull features is Claude Code's built-in `LSP`
   tool** (`goToDefinition`, `findReferences`, `hover`, `documentSymbol`,
   `workspaceSymbol`, `incomingCalls`/`outgoingCalls`). The plugin's own architecture
   survey states this directly: `docs/hook-surface-proposal.md:31-37` ("The
   pull/positional features already have a correct home: Claude Code's built-in `LSP`
   tool ... For PowerShell it is inert today only because plugin LSP-server
   **registration** is broken upstream").

2. **The PostToolUse hook -- the one delivery channel that works today -- structurally
   cannot carry a pull request.** A hook fires on "a file was just edited"; it carries
   no cursor position and no "the model wants this now" trigger
   (`docs/hook-surface-proposal.md:17-44`). The shipped client only ever emits
   push/whole-file diagnostics via `hookSpecificOutput.additionalContext`
   (`scripts/lsp-client.ps1`, `Write-HookContext`). There is no positional-request path
   in the hook surface, by design.

3. **The server is not the gate -- PSES already speaks these features.** Hover and
   go-to-definition are verified working against the warm PSES over `pwsh` 7 and Windows
   PowerShell 5.1 on Windows and Linux CI
   (`docs/upstream/claude-code-lsp-registration.md:47-49`). The warm daemon already does
   LSP request/response over the pipe (codeAction enrichment since dispatch 000012,
   `scripts/pses-daemon.ps1` `Add-CodeActionCorrections`). So PSES capability is present;
   only the delivery-to-Claude path is missing.

4. **Native registration is empirically inert, verified via the real `LSP` tool.** The
   plugin declares its server in `.claude-plugin/plugin.json:67-89` (`lspServers.powershell`
   -> `scripts/pses-stdio.ps1`, stdio transport). But a real `LSP` `tool_use` for
   `goToDefinition` on a `.ps1` returns `tool_result: No LSP server available for file
   type: .ps1`, confirmed real (not a prompt echo) via `--output-format stream-json` on
   Claude Code **2.1.167 and re-confirmed 2.1.168**, across every registration
   configuration tested -- `--plugin-dir` session-load, installed-plugin cache, and
   template-variable forms (`docs/upstream/claude-code-lsp-registration.md:27-37, 56-97`).

5. **The gate is tracked and OPEN: Claude Code [#66987](https://github.com/anthropics/claude-code/issues/66987)**
   -- "Plugin-provided LSP servers inert: LspServerManager init-ordering bug (consolidates
   #14803, #16291, #29858)" (`docs/upstream/sitting-closeout.md:8`). The older
   pre-consolidation trackers (`claude-code#15168` / `#15148`,
   `claude-plugins-official#379`) referenced throughout the repo are the same gate;
   #66987 is the consolidated issue the dispatch names.

## Consequence for the roadmap

- **Do not build a hook-shaped imitation of pull features now.** It would be a second,
  competing surface that has to be retired the day native registration works -- the
  "workaround calcifying into architecture" risk the architecture survey exists to avoid
  (`docs/hook-surface-proposal.md:39-44, 58-73`).
- **The next dispatch for pull features is the native-registration flip**, triggered when
  #66987 is fixed upstream -- with its own review (doubling-diagnostics guard,
  `${CLAUDE_PLUGIN_ROOT}`/`${user_config.*}` template-variable expansion inside the
  registration block, hook-vs-native ownership). That is the moment to revisit hover /
  definition / references / symbols, through the tool surface built for them.

## Adjacent observation (out of scope -- noted, not changed)

`.claude-plugin/plugin.json:6` describes the plugin as providing "diagnostics, hover,
go-to-definition, find-references." Per the verdict above, the three pull features are
inert through the native tool today (only diagnostics ship, via the hook). The README
carries the registration caveat, but the one-line manifest `description` reads as an
end-to-end capability claim. Worth reconciling when #66987 resolves (or softening the
description sooner) -- flagged here, not touched, since it is outside this dispatch's
Track C scope (the two stale CI/test comments).
