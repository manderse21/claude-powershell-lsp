# Upstream draft -- PowerShell Editor Services: OnInitialize NullReferenceException on Linux when initialize carries workspaceFolders

**Target:** a NEW issue on `PowerShell/PowerShellEditorServices`. Searched the
tracker 2026-06-10 for an `OnInitialize` / `workspaceFolders` `NullReferenceException`
on Linux -- the close hits are unrelated (an AnalysisService code-action NRE in
#1534; old, already-fixed workspace null-marker work) -- so file it fresh.
Re-run the repro against a clean PSES `v4.6.0` checkout to confirm wording before filing.

**Status:** DRAFT for Mike to post. Distinct from the rename-handler NRE (#2297 /
PR #2299): different trigger (workspaceFolders, not an omitted rename capability),
different code path, and Linux-only rather than cross-platform.

---

## Title

NullReferenceException in OnInitialize on Linux when the initialize request includes workspaceFolders (v4.6.0)

## Summary

On PSES `v4.6.0` running on Linux, an LSP `initialize` whose `params` include a
`workspaceFolders` array throws a `NullReferenceException` inside the server's own
`OnInitialize` handler, on the path that adds the workspace folders. The handshake
does not complete -- no `initialize` response is returned -- so the server is unusable
for any client that sends `workspaceFolders` on this platform.

The same `initialize`, byte-for-byte, completes normally on Windows. Dropping
`workspaceFolders` and relying on `rootUri` alone avoids the exception on Linux. The
platform asymmetry is the notable part: a client whose handshake is verified on
Windows silently fails on Linux at exactly this step.

## Environment

- PSES: `v4.6.0` (GitHub release asset `PowerShellEditorServices.zip`)
- Host: PowerShell 7 (`pwsh`)
- OS: Linux (reproduced on the GitHub Actions `ubuntu-latest` runner); **Windows is unaffected**
- Transport: `Start-EditorServices.ps1 -Stdio`

## Steps to reproduce

1. Launch PSES over stdio on Linux with `-NoLogo -NoProfile`, logging to a file.

2. Send an LSP `initialize` whose `params` include a `workspaceFolders` array, e.g.:

   ```json
   {
     "processId": 12345,
     "clientInfo": { "name": "repro", "version": "1.0.0" },
     "rootUri": "file:///home/runner/work/example",
     "workspaceFolders": [
       { "uri": "file:///home/runner/work/example", "name": "workspace" }
     ],
     "capabilities": { "textDocument": { "rename": { "prepareSupport": false } } }
   }
   ```

   (The `rename` capability is declared deliberately, to keep the separate v4.6.0
   PrepareRename NRE -- #2297 -- out of the picture; this report is about
   `workspaceFolders`.)

3. Observe on Linux: no `initialize` **response** is returned, and the PSES log
   records a `NullReferenceException` in the `OnInitialize` handler on the
   workspace-folders add path. The NRE stack captured during debugging points at
   `PsesLanguageServer.cs` around the `OnInitialize` workspaceFolders handling
   (line numbers should be confirmed against the v4.6.0 source by a maintainer).

## The one-line delta that proves the cause

Re-send the same `initialize` with **`workspaceFolders` removed** and nothing else
changed:

   ```json
   {
     "processId": 12345,
     "clientInfo": { "name": "repro", "version": "1.0.0" },
     "rootUri": "file:///home/runner/work/example",
     "capabilities": { "textDocument": { "rename": { "prepareSupport": false } } }
   }
   ```

On Linux the handshake now completes and diagnostics flow. The only difference is the
presence of the `workspaceFolders` array.

## Expected

Sending `workspaceFolders` on `initialize` -- a standard, optional LSP field -- must
not throw inside `OnInitialize`. The workspace-folders add path should null-guard
whatever it dereferences (treat an empty/uninitialized collection as "no folders yet")
rather than throwing, and it must behave the same on Linux as on Windows.

## Context

Found while building a Claude Code plugin that drives PSES over stdio
(https://github.com/manderse21/claude-powershell-lsp). The plugin's Windows CI legs
always passed this handshake; only the Linux leg surfaced the NRE. The plugin now
omits `workspaceFolders` to work around it (it opens each file explicitly via
`didOpen`/`didChange`, so multi-root folders are not needed for diagnostics), but the
root cause should be fixed for any client that legitimately sends `workspaceFolders`
on Linux.
