#Requires -Version 5.1

<#
.SYNOPSIS
    Benchmark fixture for the powershell-lsp performance harness (dispatch 000040).
.DESCRIPTION
    Realistic, lint-clean PowerShell used ONLY to time the analyzer's warm path
    (edit -> diagnostic round-trip). It is intentionally PSScriptAnalyzer-clean --
    approved verbs, full cmdlet names (no aliases), correct null comparisons, every
    variable and parameter referenced, non-empty catch -- so the benchmark times a
    normal analysis pass rather than a flood of findings. This file is a timing
    fixture, NOT a corpus sample, and carries no expected-findings snapshot.

    Authored natively: the DeepSeek generation of a ~50-line cohesive script failed
    (its reasoning consumed the entire token budget and emitted no content), so this
    fixture is the recorded native fallback. See the dispatch 000040 outbox survey.
#>

function Get-FileSizeReport {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter()]
        [int]$MinimumBytes = 0
    )

    $items = Get-ChildItem -LiteralPath $Path -File -ErrorAction SilentlyContinue
    $report = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $items) {
        if ($null -eq $item) {
            continue
        }
        if ($item.Length -ge $MinimumBytes) {
            $report.Add([pscustomobject]@{
                    Name      = $item.Name
                    SizeBytes = $item.Length
                })
        }
    }
    Write-Output $report
}

function ConvertTo-TrimmedUpper {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]$Text
    )
    process {
        $trimmed = $Text.Trim()
        try {
            $result = $trimmed.ToUpperInvariant()
        } catch {
            Write-Verbose ("Could not transform '" + $Text + "': " + $_.Exception.Message)
            $result = $trimmed
        }
        Write-Output $result
    }
}
