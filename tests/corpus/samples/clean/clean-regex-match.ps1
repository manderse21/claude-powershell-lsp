function Get-EmailDomain {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$EmailAddress
    )
    if ($EmailAddress -match '@(?<domain>.+)$') {
        return $Matches['domain']
    }
    return $null
}
