function Get-AcWidget {
    param()
    'ac'
}
# The alias 'gacw' is defined by a literal Set-Alias and exported via the manifest's
# AliasesToExport (no Export-ModuleMember call) -- a fully determinate, consistent surface.
Set-Alias gacw Get-AcWidget
