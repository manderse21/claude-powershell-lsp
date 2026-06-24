# Triggers PSPossibleIncorrectComparisonWithNull ($null on the right of -eq)
function Get-EmptyFlag { param($Item) $isEmpty = $Item -eq $null; return $isEmpty }
