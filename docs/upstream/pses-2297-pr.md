# Drafted PR -- PSES PrepareRename/Rename null RenameCapability guard (#2297)

**Status re-derived: 2026-09-05 via gh (dispatch 000276); live state wins over this file.**
Re-verified UNCHANGED against live gh: issue #2297 **CLOSED / COMPLETED**, closed and last updated
2026-06-11T14:43:51Z; PR #2299 **CLOSED** with `mergedAt` null and `mergeCommit` null, last updated
2026-06-11T14:36:37Z; PR #2296 **MERGED** 2026-06-11T14:43:50Z, merge commit
`40cf5e1ea4fed40a75af59871cc5c05e9707bab2`. Stated as re-checked, not carried.

## SUBMITTED, and CLOSED UNMERGED -- this is a historical record, not a pending action

**The draft below was opened upstream** as
[PowerShell/PowerShellEditorServices#2299](https://github.com/PowerShell/PowerShellEditorServices/pull/2299)
on 2026-06-10T12:25:23Z, from `manderse21:fix/2297-prepare-rename-null-capability` into
`main`, under the title "Fix #2297: guard PrepareRenameHandler against null rename
capability" -- slightly different from the draft title recorded further down. It was
**closed without merging** on 2026-06-11T14:36:23Z (no merge commit, no merged-at
timestamp), with maintainer JustinGrote commenting: "Thanks for your submission! We are
going to go with #2296 as the approach is more clear and tested."

**The underlying defect is fixed upstream regardless.** Issue
[#2297](https://github.com/PowerShell/PowerShellEditorServices/issues/2297) -- filed
2026-06-06T19:53:48Z by manderse21 -- is **CLOSED / COMPLETED** (2026-06-11T14:43:51Z),
closed by [#2296](https://github.com/PowerShell/PowerShellEditorServices/pull/2296)
(mgreenegit, merged 2026-06-11T14:43:50Z, merge commit `40cf5e1e`), which handles the null
capability and adds registration-option tests. JustinGrote on the issue: "Agreed, closing
in favor of #2296 as I like the approach better."

**Nothing further is to be submitted from this file, by anyone, Mike included.** There is no
open upstream action here. Re-opening or re-filing this fix would duplicate a change
upstream has already merged by another route.

**What this file said until 2026-08-12, and why the draft is retained.** It opened
"**Status:** PR-READY, **NOT SUBMITTED**" and stated that "Nothing has been submitted,
commented, or posted upstream." That was accurate when written and false from
2026-06-10T12:25Z onward -- the fork branch it describes as merely *pushed* became PR #2299
the same day. The draft body below is kept verbatim as the record of what was proposed and
what validation backed it; the fork-branch facts in the next paragraph remain true as
history.

- Fork branch: `manderse21/PowerShellEditorServices` @ `fix/2297-prepare-rename-null-capability`
- Base: `PowerShell/PowerShellEditorServices` @ `main` (which is `v4.6.0`, commit `d2112c21`)
- Commit: `Fix #2297: guard null RenameCapability in rename handlers`

---

## Reference draft (HISTORY -- submitted as #2299, closed unmerged)

## PR title

```
Fix #2297: guard null RenameCapability in rename handlers
```

## PR body (draft)

### Summary

`PrepareRenameHandler` and `RenameHandler` both read `capability.PrepareSupport` in
`GetRegistrationOptions`. The language-server framework passes a **null**
`RenameCapability` when the client's `initialize` omits `textDocument.rename`, so the
dereference throws a `NullReferenceException` during capability registration. The
exception leaves the `initialize` request unanswered, so the handshake **hangs** for
any client that legitimately omits the optional `rename` capability (#2297).

The rename provider is new in `v4.6.0` (#2292), so this affects `v4.6.0`.

### Fix

Guard both handlers with a property pattern, so an absent capability is treated as
"no prepare support" instead of dereferenced:

```csharp
// before
public RenameRegistrationOptions GetRegistrationOptions(RenameCapability capability, ClientCapabilities clientCapabilities)
    => capability.PrepareSupport ? new() { PrepareProvider = true } : new();

// after
public RenameRegistrationOptions GetRegistrationOptions(RenameCapability capability, ClientCapabilities clientCapabilities)
    => capability is { PrepareSupport: true } ? new() { PrepareProvider = true } : new();
```

### Tests

Adds a regression test to each handler's test class asserting
`GetRegistrationOptions(null, ...)` does not throw and reports no prepare provider.

### Validation (performed locally before submission)

- `dotnet build -c Release` is clean (the Release configuration's documentation/analyzer
  gate passes).
- The rename test category is green: **102 tests** including the two new regression tests
  (`Category=PrepareRename|Category=RenameHandlerFunction`, net8.0 Release).
- **Adversarial control:** reverting only the guard makes both new tests fail with the
  exact NRE -- `RenameHandler.GetRegistrationOptions` (`RenameHandler.cs:37`) and
  `PrepareRenameHandler.GetRegistrationOptions` (`RenameHandler.cs:23`) -- and they pass
  again with the guard restored, confirming the tests guard the regression and the fix
  is the cause.
- **End-to-end:** an `initialize` that omits `rename`, sent over `-Stdio`, never returns
  an `initialize` response against a stock `v4.6.0` bundle (hang reproduced); the same
  probe against a bundle in which only `Microsoft.PowerShell.EditorServices.dll` is
  rebuilt from this branch returns the `initialize` response and completes the handshake.
- The full `PowerShellEditorServices.Test` unit project runs **315/320** green on net8.0
  Release. The 5 failures are pre-existing environment dependencies unrelated to this
  change -- `CanLoadPSReadLine`, `CanLoadPSScriptAnalyzerAsync`, and three PSSA-dependent
  tests (parse-error / script-marker / built-in command help) -- which need PSReadLine and
  PSScriptAnalyzer provisioned (this local sandbox does not install them; the project's CI
  does). No rename test fails.

Closes #2297.
