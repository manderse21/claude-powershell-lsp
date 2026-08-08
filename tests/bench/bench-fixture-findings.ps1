#Requires -Version 5.1

<#
.SYNOPSIS
    FINDINGS-PRODUCING benchmark fixture -- the deliberately dirty counterpart to
    bench-fixture.ps1 (dispatch 000197 leg 4b, executed under 000207 leg B).

.DESCRIPTION
    bench-fixture.ps1 is deliberately analyzer-CLEAN, so it produces zero
    additionalContext under every profile. That makes it the right fixture for timing a
    normal analysis pass and the WRONG fixture for answering "how much context does a
    profile actually put in front of the model?" -- measuring bytes against a clean file
    measures zero on all three profiles and reads as "the profiles are identical."

    This file is the other half: violations chosen so that findings fire on BOTH
    surfaces the plugin ships.

      * Under the PSES 15-rule no-settings default set (profile `safe`, ruleset unset):
        the unapproved verb, the cmdlet alias, the assigned-but-never-read variable, the
        right-hand null comparison, the plural noun, and Invoke-Expression.
      * ADDITIONALLY under ruleset `base` (profiles `recommended` and `strict`): rules
        the PSES default set does not carry -- Write-Host and the empty catch block are
        the two this fixture leans on.

    That split is the point. A fixture that only fired on the base ruleset would report
    zero findings under `safe` and make the non-vacuity floor unsatisfiable there; a
    fixture that only fired on the default set would show no delta between profiles.

    IT MUST PARSE WITH ZERO ERRORS. tests/PowerShellLsp.Unit.Tests.ps1 asserts that over
    every .ps1 in the tree, and a parse error would also short-circuit the client's
    pre-PSSA path so the analyzer findings below would never be reached. Dirty is not the
    same as broken: every construct here is legal PowerShell that an analyzer objects to.

    A TIMING/SURFACE FIXTURE, NOT A CORPUS SAMPLE. It carries no expected-findings
    snapshot -- the counts it produces are measured per run and recorded beside the
    numbers they explain, because the finding count is a function of the installed
    analyzer version and the active profile, not of this file alone.

    bench-fixture.ps1 is NEVER edited (a standing rail since 000197). This file sits
    beside it instead.
#>

function Frobnicate-BenchInput {
    # PSUseApprovedVerbs: 'Frobnicate' is not an approved verb.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    # PSAvoidUsingCmdletAliases: 'gci' is an alias for Get-ChildItem.
    $items = gci -LiteralPath $Path -File -ErrorAction SilentlyContinue

    # PSUseDeclaredVarsMoreThanAssignments: assigned once, never read.
    $unusedTally = 0

    foreach ($item in $items) {
        # PSPossibleIncorrectComparisonWithNull: $null belongs on the LEFT.
        if ($item -eq $null) {
            continue
        }
        # PSAvoidUsingWriteHost: fires under ruleset base, not under the PSES default set.
        Write-Host ('bench: ' + $item.Name)
    }
}

function Get-BenchWidgets {
    # PSUseSingularNouns: 'Widgets' is plural.
    [CmdletBinding()]
    param(
        [Parameter()]
        [string] $Name = 'bench'
    )

    $resolved = $null
    $command = 'Get-Variable -Name ' + $Name + ' -ErrorAction SilentlyContinue'
    try {
        # PSAvoidUsingInvokeExpression: string-built command execution.
        $resolved = Invoke-Expression $command
    } catch {
        # PSAvoidUsingEmptyCatchBlock: fires under ruleset base, not under the default set.
    }

    Write-Output $resolved
}
