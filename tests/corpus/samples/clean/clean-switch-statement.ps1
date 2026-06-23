function Get-Label {
    param([int]$Code)
    switch ($Code) {
        1 { 'one' }
        2 { 'two' }
        default { 'other' }
    }
}
