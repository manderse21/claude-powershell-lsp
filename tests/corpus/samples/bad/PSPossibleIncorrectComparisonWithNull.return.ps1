# Triggers PSPossibleIncorrectComparisonWithNull ($null on the right of -eq)
function Test-IsNull { param($Value) return ($Value -eq $null) }
