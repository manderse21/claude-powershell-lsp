function touch {
    param([string]$Path)
    New-Item -Path $Path -ItemType File -Force | Out-Null
}
touch 'newfile.txt'
