#Requires -Version 5.1

# PURPOSE-BUILT CORRECT FIXTURE for the scalar-.Count ratchet (dispatch 000157, leg 3).
#
# Every form below is CORRECT on Windows PowerShell 5.1 and the ratchet must return ZERO hits on
# this file. Without this proof the guard could be trivially always-red and nobody would notice --
# an always-red guard and a working one are indistinguishable from their failures alone.
#
# The forms proven safe here, each measured on 5.1.26100.8875 rather than argued:
#   @(<pipeline>).Count        -- the array subexpression forces an array before .Count is read
#   (<pipeline> | Measure-Object).Count
#                              -- Measure-Object emits ONE GenericMeasureInfo whose .Count is a
#                                 real property, so this idiom is correct and must NOT be flagged.
#                                 This is the guard's one allowlisted terminal.
#   $arrayVariable.Count       -- deliberately NOT attempted by the guard (needs dataflow)
#
# ASCII-only (PS 5.1 Windows-1252 trap).

function Get-ScFixtureCorrect {
    param([object[]] $Items)

    $found = @($Items)

    $a = @($found | Where-Object { $_.Text -match 'ErrorActionPreference' }).Count
    $b = @($found | Where-Object { $null -ne $_ } | Select-Object -First 3).Count
    $c = ($found | Measure-Object).Count
    $d = ($found | Where-Object { $null -ne $_ } | Measure-Object).Count
    $e = $found.Count

    return ($a + $b + $c + $d + $e)
}
