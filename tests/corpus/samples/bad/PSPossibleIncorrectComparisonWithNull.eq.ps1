# Triggers PSPossibleIncorrectComparisonWithNull ($null on the right of -eq)
function Test-Eq { param($Value) if ($Value -eq $null) { 'null' } }
