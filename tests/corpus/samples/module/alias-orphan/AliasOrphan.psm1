function Get-AoWidget {
    param()
    'ao'
}
# 'gaow' is defined; 'gaoMissing' (in AliasesToExport) has NO Set-Alias/New-Alias definition
# anywhere in the module -- a genuine AliasesToExport orphan the check must fire on.
Set-Alias gaow Get-AoWidget
