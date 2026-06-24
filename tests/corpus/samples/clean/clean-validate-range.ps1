function Test-PortNumber {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 65535)]
        [int]$Port
    )
    return ($Port -ge 1024)
}
