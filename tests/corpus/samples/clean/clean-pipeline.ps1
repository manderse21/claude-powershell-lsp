$files = Get-ChildItem -Path $PSScriptRoot -Filter '*.txt'
$large = $files | Where-Object { $_.Length -gt 1024 } | Select-Object -First 3
Write-Output $large
