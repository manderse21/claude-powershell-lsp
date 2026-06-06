#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Pin resolved at build time against GitHub PowerShell/PowerShellEditorServices
# (latest stable release). Resolved 2026-06-01. Do not invent or hand-edit.
$PsesTag = 'v4.6.0'

$dataRoot = $env:CLAUDE_PLUGIN_DATA
if ([string]::IsNullOrWhiteSpace($dataRoot)) {
    # Hook env not present; nothing to do. Stay silent.
    return
}

$bundleDir = Join-Path $dataRoot 'PowerShellEditorServices'
$marker = Join-Path $dataRoot ('pses-' + $PsesTag + '.ok')
# The launcher (pses-stdio.ps1) starts this exact path; gate the no-op fast path on
# the start script actually being present, not just on the bundle directory existing.
$startScript = Join-Path $bundleDir 'PowerShellEditorServices/Start-EditorServices.ps1'

if ((Test-Path -LiteralPath $startScript) -and (Test-Path -LiteralPath $marker)) {
    return
}

$logDir = Join-Path $dataRoot 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir 'ensure-pses.log'
function Write-Log([string]$m) {
    ('[' + (Get-Date -Format 'o') + '] ' + $m) | Out-File -FilePath $log -Append -Encoding ascii
}

try {
    Write-Log ('Bootstrapping PSES ' + $PsesTag)
    if (Test-Path -LiteralPath $bundleDir) {
        Remove-Item -LiteralPath $bundleDir -Recurse -Force
    }
    $tmpZip = Join-Path $dataRoot ('pses-' + $PsesTag + '.zip')
    $url = 'https://github.com/PowerShell/PowerShellEditorServices/releases/download/' + $PsesTag + '/PowerShellEditorServices.zip'

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $url -OutFile $tmpZip -UseBasicParsing

    $extractRoot = Join-Path $dataRoot ('pses-extract-' + $PsesTag)
    if (Test-Path -LiteralPath $extractRoot) { Remove-Item -LiteralPath $extractRoot -Recurse -Force }
    Expand-Archive -LiteralPath $tmpZip -DestinationPath $extractRoot -Force

    # Normalize the layout regardless of how the archive nests things. The PSES
    # release zip extracts to a top-level 'PowerShellEditorServices' folder that IS
    # the module itself -- Start-EditorServices.ps1 and PowerShellEditorServices.psd1
    # live directly inside it. We want that module to land at
    # $bundleDir/PowerShellEditorServices so that $bundleDir is a valid
    # -BundledModulesPath and the start script resolves at
    # $bundleDir/PowerShellEditorServices/Start-EditorServices.ps1. Locate the module
    # by finding Start-EditorServices.ps1 (shallowest match) rather than assuming a
    # fixed nesting depth.
    New-Item -ItemType Directory -Force -Path $bundleDir | Out-Null
    $startLeaf = Get-ChildItem -LiteralPath $extractRoot -Recurse -Filter 'Start-EditorServices.ps1' -File |
        Sort-Object { $_.FullName.Length } | Select-Object -First 1
    if ($null -eq $startLeaf) {
        throw 'Start-EditorServices.ps1 not found in the extracted PSES archive.'
    }
    Move-Item -LiteralPath $startLeaf.Directory.FullName -Destination (Join-Path $bundleDir 'PowerShellEditorServices')

    Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $extractRoot) { Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue }

    New-Item -ItemType File -Force -Path $marker | Out-Null
    Write-Log 'PSES bootstrap complete.'
}
catch {
    Write-Log ('PSES bootstrap FAILED: ' + $_.Exception.Message)
    # Do not throw to stdout; LSP startup will surface a clear error if the bundle is missing.
}
