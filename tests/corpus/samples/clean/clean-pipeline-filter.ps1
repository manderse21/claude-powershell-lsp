function Get-LargeFile {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Directory,
        [int]$MinimumSizeMB = 100
    )
    $threshold = $MinimumSizeMB * 1MB
    Get-ChildItem -LiteralPath $Directory -File |
        Where-Object { $_.Length -gt $threshold } |
        Sort-Object -Property Length -Descending |
        Select-Object -Property Name, Length
}
