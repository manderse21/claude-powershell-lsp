[Flags()]
enum FileAccessRight {
    Read = 1
    Write = 2
    Execute = 4
}

function Test-AccessRight {
    [CmdletBinding()]
    param (
        [FileAccessRight]$Granted,
        [FileAccessRight]$Required
    )
    return (($Granted -band $Required) -eq $Required)
}
