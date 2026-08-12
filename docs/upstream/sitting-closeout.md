# Upstream sitting - closeout record

**Status re-derived: 2026-08-12 via gh; live state wins over this file.**

This page was a point-in-time snapshot taken 2026-06-10 08:56:52 -04:00, and **every row it
recorded has since moved.** The live table is first; the original snapshot is retained below it
as history, because what this record asserted at the time is itself part of the record.

## Live state (re-derived with `gh` on 2026-08-12, query window 14:52-14:56Z)

| Item | Live state | Detail | Link |
| --- | --- | --- | --- |
| PSES PR #2299 | **CLOSED, never merged** | Opened 2026-06-10T12:25:23Z from `manderse21:fix/2297-prepare-rename-null-capability` -> `main`; closed 2026-06-11T14:36:23Z with no merge commit and no merged-at timestamp. Maintainer JustinGrote: "Thanks for your submission! We are going to go with #2296 as the approach is more clear and tested." | https://github.com/PowerShell/PowerShellEditorServices/pull/2299 |
| PSES issue #2297 | **CLOSED / COMPLETED** | Filed 2026-06-06T19:53:48Z by manderse21; closed 2026-06-11T14:43:51Z in favour of #2296. The defect this repository reported IS fixed upstream -- by another contributor's patch, not by ours. | https://github.com/PowerShell/PowerShellEditorServices/issues/2297 |
| PSES PR #2296 | **MERGED** 2026-06-11T14:43:50Z | mgreenegit, "Enhance RenameHandler to handle null capabilities gracefully and add tests for registration options"; merge commit `40cf5e1e`. This is the change that closed #2297. | https://github.com/PowerShell/PowerShellEditorServices/pull/2296 |
| claude-code issue #66987 | **OPEN** | Filed 2026-06-10T12:25:56Z; last updated 2026-07-06T19:15:11Z. Live title: "Plugin lspServers entries declaring restartOnCrash or shutdownTimeout are silently dropped by the LSP registrar (schema-valid, no diagnostic)". Mike rewrote the issue to the registrar-drop root cause on 2026-07-06, which **superseded the init-ordering title** this page recorded. | https://github.com/anthropics/claude-code/issues/66987 |
| PSES issue #2300 -- recorded here as "B2 workspaceFolders, DEFERRED" | **FILED, then CLOSED / COMPLETED** | Filed 2026-06-10T14:50:00Z by manderse21 -- roughly two hours AFTER this page recorded it as deferred with "no body file" -- and closed 2026-06-18T03:08:27Z. Two body files do exist in this directory: `pses-b2-workspacefolders-issue.md` and `pses-b2-post-ready.md`. | https://github.com/PowerShell/PowerShellEditorServices/issues/2300 |

**Live verdict: still closed out, but for materially different reasons than this page gave.**
Nothing on it is outstanding. The rename defect is fixed upstream (through #2296, not through
our #2299); the workspaceFolders defect was filed as #2300 and is closed; only the
registrar-drop report #66987 remains open, and it is tracked in
`claude-code-lsp-registration.md`, not here.

**Nothing further is to be filed from this page.** Every item it names already exists upstream.

---

## Original snapshot, 2026-06-10 08:56:52 -04:00 (HISTORY -- superseded by the table above)

Retained verbatim. Read it as a record of what was true that morning, not as current state:
the #2299 row went stale within 30 hours, the #66987 title within 26 days, and the B2 row
within the same working day.

Verified: 2026-06-10 08:56:52 -04:00

| Status | Item | Detail | Link |
| --- | --- | --- | --- |
| PASS | PR #2297 -> #2299 | state=OPEN; manderse21:fix/2297-prepare-rename-null-capability -> main; tip=7bbde49c | https://github.com/PowerShell/PowerShellEditorServices/pull/2299 |
| PASS | Refutation issue #66987 | state=OPEN; body=7394 chars; title=Plugin-provided LSP servers inert: LspServerManager init-ordering bug (consolidates #14803, #16291, #29858) | https://github.com/anthropics/claude-code/issues/66987 |
| DEFERRED | B2 workspaceFolders issue | optional; no body file. Parked by choice. | - |

Verdict: CLOSED OUT. B2 workspaceFolders issue deferred (optional).
