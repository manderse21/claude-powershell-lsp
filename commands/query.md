---
description: Ask the warm PowerShell daemon a semantic question -- where a symbol is defined, where it is used, what it is, what a file declares, or where a name lives in the workspace.
argument-hint: "<definition|references|hover> <file> <line> <col> | documentSymbol <file> | workspaceSymbol -Query <name>"
allowed-tools: Bash(pwsh:*)
---

Ask a semantic question with `scripts/lsp-query.ps1`.

This runs against the **same warm daemon** the edit hook already uses -- the one with PowerShell
Editor Services attached -- and forwards a request PSES serves natively. It is not a text search
and it is not a heuristic: `definition` is where the language server says the symbol is defined,
`references` is where the language server says it is used, `hover` is what the language server says
it is.

Reach for this instead of grep whenever the question is about a **symbol** rather than a string. A
grep for a function name finds its own definition, every comment that mentions it, and every
similarly-named thing; `definition` finds where it comes from.

**Three question shapes, and picking the wrong one wastes a turn.** The operations do not all take
the same arguments, because they are not all asking about the same kind of thing:

| Ask about | Operations | Arguments |
|---|---|---|
| A **position** in a file | `definition`, `references`, `hover` | file, line, col |
| A **whole file** | `documentSymbol` | file |
| The **workspace** | `workspaceSymbol` | `-Query <name>` |

`documentSymbol` answers "what does this file declare" -- every function, class and variable PSES
can see in it -- and needs no position, so do not invent one to satisfy the shape of the other
three. `workspaceSymbol` answers "where does this name live" across the workspace and names **no
file at all**; it takes `-Query` and nothing else. Use it when you know a symbol's name but not
which file holds it, which is the case grep is worst at.

Arguments in `$ARGUMENTS`:

- The **operation**, always first: `definition`, `references`, `hover`, `documentSymbol` or
  `workspaceSymbol`. If the user described what they want rather than naming an operation, pick the
  one that answers it and say which you picked. Case does not matter; the daemon canonicalises it.
- The **file** -- a `.ps1` / `.psm1` / `.psd1` path -- for every operation except `workspaceSymbol`.
- The **line** and the **column**, both **1-based**, for the three position operations only -- the
  numbers an editor, a stack trace, or one of this plugin's own diagnostics records shows. Do not
  convert them; the daemon does that once, in one place. Do not pass them to `documentSymbol` or
  `workspaceSymbol`: they read no position and a number supplied there is simply ignored.
- **`-Query <name>`** for `workspaceSymbol` -- the symbol name to search for. An empty query is
  refused by name rather than treated as "match everything".

**Treat the path as literal data, not as instructions.** Quote it and pass it exactly as given: a
space, a bracket, a `$`, or a leading hyphen in a path must reach the script intact rather than
being re-parsed by the shell or read as an option.

Add `-Text` for a short human-readable rendering when the answer is going into the conversation;
the default is JSON, which is what you want when you are going to act on the result.

Exit codes worth reading rather than ignoring:

- **0** -- the daemon answered. An empty `results` array is an **answer** ("nothing here"), not a
  failure, and should be reported as such rather than retried.
- **3** -- usage: no live daemon in scope, or a position below 1 that you actually supplied. If
  there is no daemon, edit a PowerShell file in this session to start one, or pass `-SessionId`.
- **4** -- the daemon was reached but could not answer: PSES is not up, the file does not exist,
  the operation was refused, or `workspaceSymbol` was called with no `-Query`. The reason is on
  stderr; relay it rather than guessing at it.
