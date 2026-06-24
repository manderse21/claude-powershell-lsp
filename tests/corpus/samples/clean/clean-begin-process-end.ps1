function Get-SquaredNumber {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [int]$Number
    )
    begin {
        $total = 0
    }
    process {
        $squared = $Number * $Number
        $total += $squared
        Write-Output $squared
    }
    end {
        Write-Verbose "Processed running total: $total"
    }
}
