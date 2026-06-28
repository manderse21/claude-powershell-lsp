function Get-DynamicFoo {
    param()
    'foo'
}
$exportList = @('Get-DynamicFoo')
Export-ModuleMember -Function $exportList
