function Join-PathSegment {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$Segment
    )
    $builder = [System.Text.StringBuilder]::new()
    foreach ($part in $Segment) {
        [void]$builder.Append($part).Append('/')
    }
    return $builder.ToString().TrimEnd('/')
}
