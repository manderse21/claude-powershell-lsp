# Word comparison operators are '-lt' and '-gt', never the '<' '>' redirection symbols.
if (2 -lt 3 -and 5 -gt 1) {
    Write-Output 'ok'
}
