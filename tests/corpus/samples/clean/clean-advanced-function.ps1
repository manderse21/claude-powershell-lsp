function Get-Doubled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int[]]$Number
    )
    process {
        foreach ($n in $Number) {
            Write-Output ($n * 2)
        }
    }
}
