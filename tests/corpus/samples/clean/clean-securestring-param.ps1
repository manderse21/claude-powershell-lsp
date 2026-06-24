function New-ApiSession {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$UserName,
        [Parameter(Mandatory = $true)]
        [SecureString]$Token
    )
    $session = [pscustomobject]@{
        UserName = $UserName
        HasToken = ($null -ne $Token)
    }
    return $session
}
