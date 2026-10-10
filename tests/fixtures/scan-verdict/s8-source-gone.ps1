# S8 -- SOURCE DISAPPEARANCE (dispatch 000302, A1 scan-verdict census).
#
# A FAKE scripts/lsp-client.ps1 (see s1-silent-exit-zero.ps1 for how it is driven). The target
# file disappears between the scanner's enumeration and the analysis. To make that race land
# deterministically at the same point at BOTH boundaries -- the helper (Invoke-ScanFileDiagnostics)
# and the relocated CLI, where nothing else can run between enumeration and the child -- the
# child removes the file itself if it is still there, and then mirrors the real client's check
# (scripts/lsp-client.ps1: `if (-not (Test-Path -LiteralPath $path))`): it logs `file gone: <path>`
# in the real client's format and exits 0 with nothing on stdout and no capture record.
#
# The REAL client takes this same path with no daemon at all; the reachability case in
# PowerShellLsp.ScanVerdict.Tests.ps1 drives it over a file the test removed.
#
# ASCII-only (PS 5.1 reads a UTF-8-without-BOM file through Windows-1252).

. (Join-Path $PSScriptRoot 'lib/lsp-common.ps1')
$raw = Get-StdinText   # BOM-tolerant, as the real hooks read it (a 5.1 parent prepends a BOM)
[System.IO.File]::WriteAllText((Join-Path $env:CLAUDE_PLUGIN_DATA 'fake-ran.txt'), 'S8')
$path = [System.IO.Path]::GetFullPath([string]((($raw | ConvertFrom-Json).tool_input).file_path))
if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
$logDir = Get-LogDir
New-ContainedDirectory -Path $logDir
('[' + (Get-Date -Format 'o') + '] file gone: ' + $path) |
    Out-File -FilePath (Join-Path $logDir 'lsp-client.log') -Append -Encoding ascii
exit 0
