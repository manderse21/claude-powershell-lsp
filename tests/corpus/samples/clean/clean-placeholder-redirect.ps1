# Output redirection uses '>' legitimately and must not be flagged as a placeholder.
Get-Date > stamp.txt
Get-Process 2>&1 | Out-Null
