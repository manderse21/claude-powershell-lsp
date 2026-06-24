function Find-Resource {
    [CmdletBinding(DefaultParameterSetName = 'ByName')]
    param (
        [Parameter(Mandatory = $true, ParameterSetName = 'ByName')]
        [string]$Name,
        [Parameter(Mandatory = $true, ParameterSetName = 'ById')]
        [int]$Id
    )
    if ($PSCmdlet.ParameterSetName -eq 'ByName') {
        Write-Output "Resolving by name: $Name"
    }
    else {
        Write-Output "Resolving by id: $Id"
    }
}
