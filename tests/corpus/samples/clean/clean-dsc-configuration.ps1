#Requires -Version 5.1

<#
.SYNOPSIS
    KNOWN-GOOD corpus sample: a bare DSC Configuration / Node block (dispatch 000171 leg 3).
.DESCRIPTION
    The second of the two DSC shapes 000170 classified as reachable with ZERO third-party
    source vendored. `Configuration` and `Node` parse as ordinary commands taking a name and
    a script block, so the file parses on BOTH analysis hosts with no DSC module installed.

    IT DELIBERATELY CARRIES NO 'Import-DscResource -ModuleName PSDesiredStateConfiguration'.
    That statement is a parse-time dynamic keyword: dispatch 000170 measured it as a HARD
    PARSE ERROR under pwsh 7 ("Could not find the module"), and pwsh is the analysis host on
    every CI leg. Only the built-in `Script` resource is used, for the same reason -- it needs
    nothing imported.

    In samples/clean, so its contribution is to the measured FALSE-POSITIVE rate: the tool
    must stay SILENT on it.
#>

Configuration CleanDscProbeConfiguration {

    Node 'localhost' {

        Script CleanDscProbe {
            GetScript  = {
                return @{ Result = 'probe' }
            }
            TestScript = {
                return $true
            }
            SetScript  = {
                Write-Verbose -Message 'CleanDscProbe: nothing to do.'
            }
        }
    }
}
