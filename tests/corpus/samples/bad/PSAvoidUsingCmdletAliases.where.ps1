# Triggers PSAvoidUsingCmdletAliases (? is an alias for Where-Object)
Get-Process | ? { $_.Id -gt 0 }
