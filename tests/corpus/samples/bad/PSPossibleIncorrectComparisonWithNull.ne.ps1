# Triggers PSPossibleIncorrectComparisonWithNull ($null on the right of -ne)
function Test-Ne { param($Value) if ($Value -ne $null) { 'set' } }
