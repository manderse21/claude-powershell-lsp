#Requires -Version 5.1

# PURPOSE-BUILT IMPURE FIXTURE -- deliberately broken, never shipped, never dot-sourced by any
# shipped script. Loaded only by tests/PowerShellLsp.LibPurity.Tests.ps1.
#
# THE DEFECT IT ENCODES: the half of the class that is NOT a param() block. A bare Set-StrictMode,
# a preference-variable assignment, or any other executable top-level statement leaks into the
# caller's scope exactly as a param block does -- it just does it quietly, and it changes how the
# CALLER's own code behaves rather than only what its variables hold. A guard that catches only
# param() would pass this file while it silently reconfigured every caller.
#
# Each statement below is a distinct rung of the class, so the guard is proven against the whole
# class rather than one instance of it.
#
# ASCII-only, straight quotes (PS 5.1 Windows-1252 trap).

# rung 1: a preference variable -- changes the caller's error handling.
$ErrorActionPreference = 'SilentlyContinue'

# rung 2: a bare cmdlet invocation -- changes the caller's language strictness.
Set-StrictMode -Version 1.0

# rung 3: a plain assignment -- writes a variable the caller may already own.
$FixtureLeakedVariable = 'leaked-into-caller-scope'

# rung 4: a statement with an observable side effect at load time.
Write-Verbose 'impure fixture executed a statement at dot-source time'

function Get-FixtureStatementAnswer {
    # The function a caller would dot-source this file to obtain.
    return 'answer'
}
