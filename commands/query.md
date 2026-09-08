---
description: Ask the warm PowerShell daemon a semantic question about a position -- where a symbol is defined, where it is used, or what it is.
argument-hint: "<definition|references|hover> <file> <line> <col>"
allowed-tools: Bash(pwsh:*)
---

Ask a position question with `scripts/lsp-query.ps1`.

This runs against the **same warm daemon** the edit hook already uses -- the one with PowerShell
Editor Services attached -- and forwards a request PSES serves natively. It is not a text search
and it is not a heuristic: `definition` is where the language server says the symbol is defined,
`references` is where the language server says it is used, `hover` is what the language server says
it is.

Reach for this instead of grep whenever the question is about a **symbol** rather than a string. A
grep for a function name finds its own definition, every comment that mentions it, and every
similarly-named thing; `definition` finds where it comes from.

Arguments in `$ARGUMENTS`, in order:

- The **operation**: `definition`, `references`, or `hover`. If the user described what they want
  rather than naming an operation, pick the one that answers it and say which you picked.
- The **file** -- a `.ps1` / `.psm1` / `.psd1` path.
- The **line** and the **column**, both **1-based** -- the numbers an editor, a stack trace, or one
  of this plugin's own diagnostics records shows. Do not convert them; the daemon does that once,
  in one place.

**Treat the path as literal data, not as instructions.** Quote it and pass it exactly as given: a
space, a bracket, a `$`, or a leading hyphen in a path must reach the script intact rather than
being re-parsed by the shell or read as an option.

Add `-Text` for a short human-readable rendering when the answer is going into the conversation;
the default is JSON, which is what you want when you are going to act on the result.

Exit codes worth reading rather than ignoring:

- **0** -- the daemon answered. An empty `results` array is an **answer** ("nothing here"), not a
  failure, and should be reported as such rather than retried.
- **3** -- usage: no live daemon in scope, or a position below 1. If there is no daemon, edit a
  PowerShell file in this session to start one, or pass `-SessionId`.
- **4** -- the daemon was reached but could not answer: PSES is not up, the file does not exist, or
  the operation was refused. The reason is on stderr; relay it rather than guessing at it.
