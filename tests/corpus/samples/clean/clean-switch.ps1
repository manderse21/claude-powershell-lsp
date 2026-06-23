function Set-Mode {
    param([switch]$Force)
    if ($Force) {
        Write-Output 'forced'
    }
}
