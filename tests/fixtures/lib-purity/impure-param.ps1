#Requires -Version 5.1

# PURPOSE-BUILT IMPURE FIXTURE -- this file is DELIBERATELY broken and is never shipped, never
# dot-sourced by any shipped script, and never loaded outside tests/PowerShellLsp.LibPurity.Tests.ps1.
#
# It exists so both structural guards can be RED-PROVEN. A guard that has never been shown to fail
# is not a guard, and the alternative -- temporarily corrupting a real library to watch the guard
# fire -- risks committing the corruption. This fixture makes the failure permanent and safe.
#
# THE DEFECT IT ENCODES: a file that is both an entry point and a library. Dot-sourcing it to
# borrow Get-FixtureAnswer also RUNS this param() block in the CALLER's scope, silently resetting
# the caller's own $Path / $Source / $AnnotationsPath / $Verdict / $Hash to these defaults. The
# parameter NAMES deliberately match the sentinel names the behavioral guard (G2) sets, because
# that collision IS the bug being detected -- not a proxy for it.
#
# ASCII-only, straight quotes (PS 5.1 Windows-1252 trap).

param(
    [string] $Path = 'CLOBBERED-BY-PARAM-BLOCK',
    [string] $Source = 'CLOBBERED-BY-PARAM-BLOCK',
    [string] $AnnotationsPath = 'CLOBBERED-BY-PARAM-BLOCK',
    [string] $Verdict = 'CLOBBERED-BY-PARAM-BLOCK',
    [string] $Hash = 'CLOBBERED-BY-PARAM-BLOCK'
)

function Get-FixtureAnswer {
    # The function a caller would dot-source this file to obtain -- the reason the hazard happens.
    return 42
}
