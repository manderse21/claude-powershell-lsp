# Upstream draft -- PowerShell Editor Services: PrepareRename NullReferenceException

**Status re-derived: 2026-09-05 via gh (dispatch 000276); live state wins over this file.**
Re-verified UNCHANGED: issue #2297 **CLOSED / COMPLETED** 2026-06-11T14:43:51Z; PR #2296 **MERGED**; PR #2299 **CLOSED**,
never merged.

## ALREADY FILED AS #2297 -- DO NOT FILE THIS

**This draft was filed** as
[PowerShell/PowerShellEditorServices#2297](https://github.com/PowerShell/PowerShellEditorServices/issues/2297)
(manderse21, 2026-06-06T19:53:48Z), under this document's exact title -- "PrepareRename
throws NullReferenceException when an LSP client omits the `rename` capability (v4.6.0)".
It is **CLOSED / COMPLETED** (2026-06-11T14:43:51Z), fixed upstream by
[#2296](https://github.com/PowerShell/PowerShellEditorServices/pull/2296) (mgreenegit,
merged 2026-06-11T14:43:50Z, merge commit `40cf5e1e`). This repository's own fix PR
[#2299](https://github.com/PowerShell/PowerShellEditorServices/pull/2299) was closed
unmerged in favour of it; see `pses-2297-pr.md`.

**No action remains, and filing this fresh would duplicate a closed, fixed issue.** The
"**Status:** DRAFT for Mike to post" line and the "no existing issue covers this, so file it
fresh" instruction this file carried until 2026-08-12 were true on 2026-06-06 and false from
2026-06-06T19:53Z that same evening -- the tracker search they describe is the search that
immediately preceded filing #2297. Left uncorrected they read as an instruction to duplicate.

**Retained as reference material:** the title, repro, and environment below are the source
text of #2297.

---

## Title

PrepareRename throws NullReferenceException when an LSP client omits the `rename` capability (v4.6.0)

## Summary

In PSES `v4.6.0`, an LSP `initialize` whose `capabilities.textDocument` **omits**
`rename` leaves the prepare-rename handler dereferencing a null client
`RenameCapability`. Observed effect: the server never returns an `initialize`
response (the handshake hangs) and the PSES log records a `NullReferenceException`
on the rename-handler path.

Declaring even a **minimal** `rename` capability avoids it and the handshake
completes normally. This inverts the usual expectation that omitting an optional
client capability is always safe, so it is easy to hit from a minimal or hand-rolled
LSP client.

## Environment

- PSES: `v4.6.0` (GitHub release asset `PowerShellEditorServices.zip`)
- Host: PowerShell 7.6.2 (`pwsh`) and Windows PowerShell 5.1 -- reproduced on both
- OS: Windows 11
- Transport: `Start-EditorServices.ps1 -Stdio`

## Steps to reproduce

1. Launch PSES over stdio (paths trimmed for readability):

   ```
   pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File <PSES>/Start-EditorServices.ps1 \
     -HostName repro -HostProfileId repro -HostVersion 1.0.0 -Stdio \
     -BundledModulesPath <bundle> -LogPath <log> -LogLevel Diagnostic \
     -SessionDetailsPath <session.json>
   ```

2. Send an LSP `initialize` whose `textDocument` capabilities cover the usual
   entries but **omit** `rename`:

   ```json
   {
     "capabilities": {
       "textDocument": {
         "synchronization": { "didSave": true },
         "publishDiagnostics": { "relatedInformation": true },
         "hover": {},
         "definition": {}
       }
     }
   }
   ```

3. Observe: no `initialize` **response** is returned (the handshake hangs), and the
   PSES log shows a `NullReferenceException` in the rename-handler path.

## The one-line delta that proves the cause

Re-send `initialize` with a minimal `rename` capability declared and nothing else
changed:

```json
{
  "capabilities": {
    "textDocument": {
      "synchronization": { "didSave": true },
      "publishDiagnostics": { "relatedInformation": true },
      "hover": {},
      "definition": {},
      "rename": { "prepareSupport": false }
    }
  }
}
```

The handshake now completes and diagnostics flow. The only difference is the
presence of the `rename` capability object.

## Expected

Omitting the optional `rename` capability must not break `initialize`. The
prepare-rename handler should null-guard the client `RenameCapability` (treat absent
as "client does not support rename") rather than dereferencing it.

## Context

Found while building a Claude Code plugin that drives PSES over stdio
(https://github.com/manderse21/claude-powershell-lsp). The plugin now declares a
minimal `rename` capability specifically to dodge this, but the root cause should be
fixed for any client that legitimately omits it.
