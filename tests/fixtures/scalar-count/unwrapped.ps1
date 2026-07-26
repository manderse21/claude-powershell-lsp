#Requires -Version 5.1

# PURPOSE-BUILT BROKEN FIXTURE for the scalar-.Count ratchet (dispatch 000157, leg 3).
#
# DELIBERATELY DEFECTIVE. Never dot-sourced, never imported, never shipped, and EXCLUDED from the
# ratchet's own repo scan -- a guard whose proof material sits inside the set it scans is
# permanently red, so the exclusion is load-bearing and is itself asserted by the test file.
#
# THE DEFECT IT ENCODES: `.Count` read straight off a parenthesised pipeline. Under Windows
# PowerShell 5.1 a pipeline that yields exactly ONE object IS that object -- a scalar -- and a
# scalar has no .Count, so the read is $null (or throws under StrictMode). pwsh 7 wraps the single
# object and returns 1. That asymmetry is why the defect passes three CI legs and fails only
# windows-powershell.
#
# The first assertion below is the VERBATIM shape that failed CI run 30183490005.
# ASCII-only (PS 5.1 Windows-1252 trap).

function Get-ScFixtureBroken {
    param([object[]] $Items)

    $found = @($Items)

    # rung 1 -- the exact CI failure: a Where-Object pipeline read for .Count
    $a = ($found | Where-Object { $_.Text -match 'ErrorActionPreference' }).Count

    # rung 2 -- a longer pipeline, same trap, different terminal cmdlet
    $b = ($found | Where-Object { $null -ne $_ } | Select-Object -First 3).Count

    return ($a + $b)
}
