# Triggers PSUseDeclaredVarsMoreThanAssignments ($stamp is assigned but never read)
function Get-Marker { $stamp = Get-Date; return 'done' }
