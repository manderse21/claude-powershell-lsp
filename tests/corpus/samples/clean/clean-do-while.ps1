function Get-RetryResult {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,
        [int]$MaxAttempt = 3
    )
    $attempt = 0
    $result = $null
    do {
        $attempt++
        $result = & $Action
    } while (($null -eq $result) -and ($attempt -lt $MaxAttempt))
    return $result
}
