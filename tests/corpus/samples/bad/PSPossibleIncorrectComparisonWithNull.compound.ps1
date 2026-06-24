# Triggers PSPossibleIncorrectComparisonWithNull ($null on the right of -eq)
function Test-AllNull {
    param($First, $Second)
    return (($First -eq $null) -and ($Second -eq $null))
}
