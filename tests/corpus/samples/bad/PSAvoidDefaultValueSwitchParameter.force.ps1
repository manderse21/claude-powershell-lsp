# Triggers PSAvoidDefaultValueSwitchParameter (switch defaulted to $true)
function Test-Force { param([switch]$Force = $true) $Force }
