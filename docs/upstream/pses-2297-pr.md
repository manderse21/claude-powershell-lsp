# Drafted PR -- PSES PrepareRename/Rename null RenameCapability guard (#2297)

**Status:** PR-READY, **NOT SUBMITTED**. The fix branch is pushed to Mike's fork:

- Fork branch: `manderse21/PowerShellEditorServices` @ `fix/2297-prepare-rename-null-capability`
- Base: `PowerShell/PowerShellEditorServices` @ `main` (which is `v4.6.0`, commit `d2112c21`)
- Commit: `Fix #2297: guard null RenameCapability in rename handlers`

Opening the PR (fork branch -> upstream `main`) is **Mike's explicit action**. Nothing
has been submitted, commented, or posted upstream.

---

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
