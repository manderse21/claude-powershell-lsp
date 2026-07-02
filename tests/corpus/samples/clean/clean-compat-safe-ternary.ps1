function Get-Level {
    param([int]$Count)
    if ($Count -gt 10) {
        $level = 'high'
    } else {
        $level = 'low'
    }
    return $level
}
