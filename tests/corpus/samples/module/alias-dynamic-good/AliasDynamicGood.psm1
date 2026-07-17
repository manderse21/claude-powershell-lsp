$SafeCommands = @{ 'Set-Alias' = Get-Command -Name Set-Alias -CommandType Cmdlet }
function Get-AdgWidget {
    param()
    'adg'
}
# Pester 5.7.1 shape: the alias is defined by a DYNAMIC invocation the static check cannot see
# (GetCommandName() is $null for '& $SafeCommands[...]'), so the alias check must degrade to SILENCE
# rather than false-fire on 'Add-AdgOperator' (a known-good the 000127 leg-4 probe hit).
& $SafeCommands['Set-Alias'] 'Add-AdgOperator' 'Get-AdgWidget'
