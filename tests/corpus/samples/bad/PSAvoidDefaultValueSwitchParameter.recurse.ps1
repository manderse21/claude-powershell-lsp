# Triggers PSAvoidDefaultValueSwitchParameter (switch defaulted to $true)
function Get-Tree { param([switch]$Recurse = $true) $Recurse }
