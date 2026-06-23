function Test-Value {
    param($InputValue)
    if ($null -eq $InputValue) {
        Write-Output 'empty'
    } else {
        Write-Output $InputValue
    }
}
