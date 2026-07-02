$name = $env:USERNAME
if ($null -eq $name) {
    $name = 'anonymous'
}
Write-Output $name
