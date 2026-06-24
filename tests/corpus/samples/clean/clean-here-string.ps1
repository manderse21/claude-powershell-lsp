function Format-ReportHeader {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Title,
        [datetime]$GeneratedOn = (Get-Date)
    )
    $header = @"
==============================
 $Title
 Generated: $GeneratedOn
==============================
"@
    return $header
}
