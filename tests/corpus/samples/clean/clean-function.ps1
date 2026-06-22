function Get-Greeting {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    $greeting = "Hello, $Name"
    Write-Output $greeting
}
