function Set-LogLevel {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet('Error', 'Warning', 'Information', 'Verbose')]
        [string]$Level
    )
    Write-Output "Log level is now $Level"
}
