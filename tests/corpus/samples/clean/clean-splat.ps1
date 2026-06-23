$params = @{
    Path    = $PSScriptRoot
    Filter  = '*.ps1'
    Recurse = $true
}
Get-ChildItem @params
