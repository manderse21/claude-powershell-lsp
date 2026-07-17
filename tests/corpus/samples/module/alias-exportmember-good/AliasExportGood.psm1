function Get-AegWidget {
    param()
    'aeg'
}
# BurntToast 1.1.0 shape: the module manages its own alias exports via Export-ModuleMember -Alias, and
# binds the alias name through a splat the static check cannot read as a literal. Both signals make the
# alias surface INDETERMINATE, so the check must degrade to SILENCE (a known-good the 000127 leg-4 probe hit).
$aliasSpec = @{ Name = 'aeg'; Value = 'Get-AegWidget' }
Set-Alias @aliasSpec
Export-ModuleMember -Function Get-AegWidget -Alias aeg
