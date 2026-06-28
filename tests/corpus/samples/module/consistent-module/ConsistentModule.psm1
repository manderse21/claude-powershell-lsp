function Get-ConsistentFoo {
    param()
    'foo'
}
function Set-ConsistentBar {
    param()
    'bar'
}
Export-ModuleMember -Function Get-ConsistentFoo, Set-ConsistentBar
