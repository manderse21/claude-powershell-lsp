function Get-Sum {
    param (
        [int]$FirstNumber,
        [int]$SecondNumber
    )
    $sum = $FirstNumber + $SecondNumber
    Write-Output $sum
}

function ConvertTo-Label {
    param (
        [string]$Prefix,
        [int]$Total
    )
    $label = $Prefix + ': ' + $Total
    Write-Output $label
}
