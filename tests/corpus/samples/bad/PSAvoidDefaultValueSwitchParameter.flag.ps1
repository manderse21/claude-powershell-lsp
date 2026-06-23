# Triggers PSAvoidDefaultValueSwitchParameter (switch defaulted to $true)
function Test-Flag { param([switch]$Flag = $true) $Flag }
