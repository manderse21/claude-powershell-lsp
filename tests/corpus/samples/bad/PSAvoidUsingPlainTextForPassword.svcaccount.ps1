# Triggers PSAvoidUsingPlainTextForPassword (plain [string] password param)
function New-ServiceAccount { param([string]$ServicePassword) $ServicePassword }
