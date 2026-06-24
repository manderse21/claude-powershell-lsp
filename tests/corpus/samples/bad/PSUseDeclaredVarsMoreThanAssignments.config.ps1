# Triggers PSUseDeclaredVarsMoreThanAssignments ($config is assigned but never read)
function Initialize-State { $config = @{ Enabled = $true }; Write-Output 'ok' }
