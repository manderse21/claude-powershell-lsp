# Triggers PSPossibleIncorrectComparisonWithNull ($null on the right in a while)
function Test-While { param($Value) while ($Value -eq $null) { break } }
