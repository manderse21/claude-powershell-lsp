$value = Get-Date
if ($null -eq $value) {
    Write-Output 'Value is null'
} else {
    Write-Output "Current date: $value"
}
