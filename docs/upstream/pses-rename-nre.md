# Upstream draft -- PowerShell Editor Services: PrepareRename NullReferenceException

**Target:** a NEW issue on `PowerShell/PowerShellEditorServices`. Searched the
tracker 2026-06-06 for `PrepareRenameHandler`, `RenameCapability`, and a rename
`NullReferenceException` on initialize -- no existing issue covers this, so file it
fresh.

**Status:** DRAFT for Mike to post. Re-run the repro against a clean PSES `v4.6.0`
checkout to confirm wording before filing.

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
