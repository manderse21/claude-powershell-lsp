# Triggers PSUseDeclaredVarsMoreThanAssignments ($unused is assigned but never read)
function Get-Number { $unused = 42; return 1 }
