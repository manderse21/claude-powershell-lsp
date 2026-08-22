# Track B findings -- can pull-model LSP features ship on the current surface?

**Status re-derived: 2026-08-21 via gh; live state wins over this file.** `#66987` is now **CLOSED**
(fixed in Claude Code 2.1.205); `#86936` is **OPEN** and maintainer-reproduced. See the second
correction below -- neither changes this page's verdict.

**Dispatch:** powershell-lsp/000015, Track B (read-only gating probe).
**Date:** 2026-06-14. **No code change** -- this note only orders the next dispatch.

## CORRECTION (2026-08-13, gate decision D6): the verdict below is SUPERSEDED

**The technical verdict of this page -- "#66987-gated (NOT buildable-now)", resting on the premise
that plugin LSP-server registration is "empirically inert" -- was overtaken by dispatch 000069 and
is no longer current.** Ratified as gate decision D6, 2026-08-12
(`docs/decision-ledger.md`, "Roadmap II gate decisions D1-D7"). The original text is preserved
below unchanged, because what this record asserted at the time is itself part of the record.

**What actually superseded it.** Registration was never gated on an upstream init-ordering bug. It
was gated on **this project's own manifest**: Claude Code's runtime LSP registrar silently drops
any `lspServers` entry that declares `restartOnCrash` or `shutdownTimeout`, so the plugin's server
never registered. Dispatch 000069 isolated that root cause, and dispatch 000075 removed the two
fields and added an allowlist guard -- **registration was restored in v1.18.1**. See
`docs/upstream/claude-code-lsp-registration.md` (the corrected record, with the 000069 probe
matrix) and the v1.18.1 row of the release table in `docs/decision-ledger.md`.

Mike rewrote [anthropics/claude-code#66987](https://github.com/anthropics/claude-code/issues/66987)
on 2026-07-06 to the registrar silent-drop root cause, which **superseded the init-ordering issue
title this page cites** at evidence item 5 (`docs/upstream/sitting-closeout.md`, live table). It is
no longer the issue this page describes.

> **Second correction (re-derived live 2026-08-21, dispatch 000269): #66987 is now CLOSED.** This
> sentence read "the issue remains OPEN", and that is stale. `gh issue view 66987` returns
> **CLOSED**, last updated 2026-08-13T16:09:48Z; Mike closed it having bisected the fix to Claude
> Code **2.1.205**.
>
> **This does not revive the verdict below.** The "#66987-gated" framing was already superseded for
> a different reason -- see "What survives the correction" immediately after -- and that reasoning is
> untouched by the closure. The pull features remain undeliverable today because **serve** does not
> work on the direct path (a separate `#1359`-class handshake failure), and because `#86936`
> (`${user_config.*}` interpolation) is still **OPEN** and independently suspends the LSP surface.
> Recorded as a status correction; **no roadmap consequence is drawn here, which is Mike's call.**

**What survives the correction.** The pull features are still not deliverable today, for a
*different* reason: registration works, but **serve** does not on the direct path -- a separate
`#1359`-class handshake failure, closed locally by the opt-in `nativeServe = shim`. So the forward
guidance under "Consequence for the roadmap" still holds -- do not build a hook-shaped imitation of
pull features now -- and evidence items 1, 2 and 3 are unaffected. What is wrong is the *named
gate*, at the verdict line and at evidence items 4 and 5.

**Reading rule.** Treat everything below this note as of 2026-06-14. For the live state of native
registration and serve, read `docs/upstream/claude-code-lsp-registration.md` and
`docs/roadmap-ii/CURRENT-STATE.md` section 7.

---

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
