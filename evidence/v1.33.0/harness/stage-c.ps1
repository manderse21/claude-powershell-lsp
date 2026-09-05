#Requires -Version 5.1
# stage-c.ps1 -- stage release-identity commit C into an isolated scratch plugin
# cache, and build the private data root.
#
# Dispatch 000273 (freeze 1B). ASCII only.
#
#   root\  = CLAUDE_PLUGIN_ROOT  (staged from `git archive C`)
#   ref\   = an INDEPENDENT second extraction of `git archive C`, used as the
#            equality-proof reference so the proof never compares root to itself
#   data\  = CLAUDE_PLUGIN_DATA  (junctions to the real PSES/PSSA bundles +
#            version markers, so ensure-pses / ensure-pssa no-op)

param(
    [string] $Commit = '6ab2d24bf254787520ad9449c4e6c17f74ee708d',
    [string] $Repo   = 'C:\Users\mande\projects\work\nortam\claude-powershell-lsp\worktrees\s000273-freeze',
    [string] $Base   = 'C:\Users\mande\AppData\Local\Temp\psl-273',
    [string] $LiveData = 'C:\Users\mande\.claude\plugins\data\powershell-lsp-claude-powershell-lsp'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = Join-Path $Base 'root'
$Ref  = Join-Path $Base 'ref'
$Data = Join-Path $Base 'data'

function Reset-Dir([string] $p) {
    if (Test-Path -LiteralPath $p) {
        # Junctions must be removed with rmdir, not Remove-Item -Recurse (which
        # would follow into the real bundle and delete it).
        Get-ChildItem -LiteralPath $p -Recurse -Force -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
            ForEach-Object { & cmd.exe /c rmdir ('"' + $_.FullName + '"') 2>&1 | Out-Null }
        Remove-Item -LiteralPath $p -Recurse -Force
    }
    New-Item -ItemType Directory -Path $p -Force | Out-Null
}

function Expand-Archive-At([string] $dest) {
    Reset-Dir $dest
    $tar = Join-Path $Base ('c-' + $Commit.Substring(0,7) + '.tar')
    if (-not (Test-Path -LiteralPath $tar)) {
        & git -C $Repo archive --format=tar -o $tar $Commit
        if ($LASTEXITCODE -ne 0) { throw ('git archive failed: exit ' + $LASTEXITCODE) }
    }
    $winTar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (-not (Test-Path -LiteralPath $winTar)) { throw 'Windows bsdtar not found; MSYS tar cannot read a C:\ path' }
    & $winTar -xf $tar -C $dest
    if ($LASTEXITCODE -ne 0) { throw ('tar -xf failed: exit ' + $LASTEXITCODE) }
}

Write-Output ('staging commit ' + $Commit)
Expand-Archive-At $Root
Expand-Archive-At $Ref

# --- private data root -------------------------------------------------------
Reset-Dir $Data
New-Item -ItemType Directory -Path (Join-Path $Data 'logs')    -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $Data 'session') -Force | Out-Null

foreach ($j in @('PowerShellEditorServices', 'modules')) {
    $src = Join-Path $LiveData $j
    if (-not (Test-Path -LiteralPath $src)) { throw ('live bundle missing: ' + $src) }
    $dst = Join-Path $Data $j
    & cmd.exe /c mklink /J ('"' + $dst + '"') ('"' + $src + '"') | Out-Null
    if (-not (Test-Path -LiteralPath $dst)) { throw ('junction failed: ' + $dst) }
}

# Version markers at the data root itself (the PSSA marker rides inside modules\).
Get-ChildItem -LiteralPath $LiveData -Filter '*.ok' -File | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $Data $_.Name) -Force
}

$markers = @(Get-ChildItem -LiteralPath $Data -Filter '*.ok' -File)
$pssaMarker = @(Get-ChildItem -LiteralPath (Join-Path $Data 'modules') -Filter '.pssa-*.ok' -File)
Write-Output ('data root markers: ' + (($markers | ForEach-Object { $_.Name }) -join ', '))
Write-Output ('pssa marker: ' + (($pssaMarker | ForEach-Object { $_.Name }) -join ', '))
if ($markers.Count -lt 1)    { throw 'no PSES version marker copied -- bootstrap would NOT no-op' }
if ($pssaMarker.Count -lt 1) { throw 'no PSSA version marker visible through the modules junction' }

$n = @(Get-ChildItem -LiteralPath $Root -Recurse -File).Count
Write-Output ('staged files under root: ' + $n)
Write-Output ('CLAUDE_PLUGIN_ROOT = ' + $Root)
Write-Output ('CLAUDE_PLUGIN_DATA = ' + $Data)
