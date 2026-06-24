function Get-DiskFreeSpace {
    <#
    .SYNOPSIS
        Returns free space in gigabytes for a PowerShell drive.
    .PARAMETER Name
        The drive name to inspect (for example, C).
    .EXAMPLE
        Get-DiskFreeSpace -Name C
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    $drive = Get-PSDrive -Name $Name
    return [math]::Round($drive.Free / 1GB, 2)
}
