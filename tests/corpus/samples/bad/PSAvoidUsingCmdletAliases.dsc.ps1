#Requires -Version 5.1

<#
.SYNOPSIS
    KNOWN-BAD corpus sample: cmdlet aliases inside a DSC Configuration (dispatch 000171 leg 3).
.DESCRIPTION
    EXPECTED RULE: PSAvoidUsingCmdletAliases (the first dot-segment of this file's name is the
    rule the corpus contract asserts must surface).

    Why this case earns its place next to the five existing PSAvoidUsingCmdletAliases variants:
    the aliases here sit inside a `Script` resource's GetScript/TestScript SCRIPT BLOCKS, nested
    two levels inside Configuration -> Node. It proves the analyzer still descends into DSC
    resource property script blocks rather than treating the Configuration body as opaque.

    Carries NO 'Import-DscResource -ModuleName PSDesiredStateConfiguration' -- 000170 measured
    that as a hard parse error under pwsh 7, which is the analysis host on every CI leg. A parse
    error would make this a PARSER sample, not a rule sample, and it would stop testing the rule.
#>

Configuration BadDscAliasConfiguration {

    Node 'localhost' {

        Script BadDscAliasProbe {
            GetScript  = {
                return @{ Result = (gci -Path $env:TEMP).Count }
            }
            TestScript = {
                $items = gci -Path $env:TEMP
                return (($items | ? { $_.Name -ne '' } | measure).Count -gt 0)
            }
            SetScript  = {
                Write-Verbose -Message 'BadDscAliasProbe: nothing to do.'
            }
        }
    }
}
