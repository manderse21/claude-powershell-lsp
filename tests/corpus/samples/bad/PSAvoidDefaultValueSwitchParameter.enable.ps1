# Triggers PSAvoidDefaultValueSwitchParameter (switch defaulted to $true)
function Test-Enable { param([switch]$Enable = $true) $Enable }
