function Invoke-Safe {
    param([scriptblock]$Action)
    try {
        & $Action
    } catch {
        Write-Output ('error: ' + $_.Exception.Message)
    }
}
