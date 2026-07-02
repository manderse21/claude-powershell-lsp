$exists = Test-Path -LiteralPath 'a.txt'
if ($exists) {
    Write-Output 'exists'
}
