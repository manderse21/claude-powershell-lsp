# Triggers PSAvoidDefaultValueSwitchParameter (switch defaulted to $true)
function Get-Report { param([switch]$Detailed = $true) $Detailed }
