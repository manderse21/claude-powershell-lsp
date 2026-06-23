#Requires -Version 5.1

# New-PluginSbom.ps1 -- generate a CycloneDX 1.5 SBOM for a powershell-lsp release
# (Gap B / dispatch 000042). Covers the plugin itself (the BOM subject) and its two
# PINNED downloaded dependencies -- PowerShell Editor Services and PSScriptAnalyzer --
# which are fetched at install time and are NOT in the repo tree, so an off-the-shelf
# directory scanner cannot see them. This generator reads the pins straight from
# scripts/ensure-pses.ps1 ($PsesTag) and scripts/ensure-pssa.ps1 ($PssaVersion), so the
# SBOM can never disagree with the versions the tool actually downloads (single-sourced).
# It reads those files ONLY; it never modifies anything under scripts/.
#
# Used by .github/workflows/powershell-lsp-release.yml (attached to the GitHub Release)
# and unit-tested / dry-runnable via tests/PowerShellLsp.Release.Tests.ps1.
#
# Output: CycloneDX 1.5 JSON to stdout, or to -OutFile when given.
# ASCII-only (PS 5.1 em-dash trap).
#
# Author: Mike Andersen / powershell-lsp plugin.

[CmdletBinding()]
param(
    # Plugin version for the BOM subject. Default: read from .claude-plugin/plugin.json.
    [string] $Version,

    # Repo root. Default: the script's parent directory.
    [string] $RepoRoot,

    # Optional output file. Omitted = write the JSON to stdout.
    [string] $OutFile,

    # BOM timestamp (ISO-8601). Default: now (UTC). Injectable so tests are deterministic.
    [string] $Timestamp,

    # BOM serial number (urn:uuid:...). Default: a fresh GUID. Injectable for tests.
    [string] $SerialNumber
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$pluginJsonPath = Join-Path $RepoRoot '.claude-plugin/plugin.json'
$psesScript = Join-Path $RepoRoot 'scripts/ensure-pses.ps1'
$pssaScript = Join-Path $RepoRoot 'scripts/ensure-pssa.ps1'
foreach ($p in @($pluginJsonPath, $psesScript, $pssaScript)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Required file not found: $p" }
}

# --- read a single-quoted pin value ($<VarName> = '<value>') from a source file --------
function Get-PinnedValue {
    param([string] $FilePath, [string] $VarName)
    $src = [System.IO.File]::ReadAllText($FilePath)
    $rx = [regex] ('\$' + [regex]::Escape($VarName) + "\s*=\s*'([^']+)'")
    $m = $rx.Match($src)
    if (-not $m.Success) { throw ("Could not find pin `$" + $VarName + " in " + $FilePath) }
    return $m.Groups[1].Value
}

# --- plugin subject -------------------------------------------------------------------
$plugin = (Get-Content -LiteralPath $pluginJsonPath -Raw) | ConvertFrom-Json
$pluginName = [string] $plugin.name
$pluginVersion = if ([string]::IsNullOrWhiteSpace($Version)) { [string] $plugin.version } else { $Version.Trim().TrimStart('v', 'V') }
$pluginLicense = [string] $plugin.license   # SPDX id, e.g. GPL-3.0-or-later

# --- pinned downloaded dependencies (single-sourced from the ensure-* scripts) --------
$psesTag = Get-PinnedValue -FilePath $psesScript -VarName 'PsesTag'        # e.g. v4.6.0
$psesVersion = $psesTag.TrimStart('v', 'V')
$pssaVersion = Get-PinnedValue -FilePath $pssaScript -VarName 'PssaVersion' # e.g. 1.25.0

# --- timestamp / serial ---------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Timestamp)) {
    $Timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}
if ([string]::IsNullOrWhiteSpace($SerialNumber)) {
    $SerialNumber = 'urn:uuid:' + ([guid]::NewGuid().ToString())
}

# --- assemble the CycloneDX 1.5 document ----------------------------------------------
$bom = [ordered] @{
    'bomFormat'    = 'CycloneDX'
    'specVersion'  = '1.5'
    'serialNumber' = $SerialNumber
    'version'      = 1
    'metadata'     = [ordered] @{
        'timestamp' = $Timestamp
        'tools'     = @(
            [ordered] @{
                'vendor'  = 'powershell-lsp'
                'name'    = 'New-PluginSbom.ps1'
                'version' = $pluginVersion
            }
        )
        'component' = [ordered] @{
            'type'      = 'application'
            'bom-ref'   = 'pkg:github/manderse21/claude-powershell-lsp@v' + $pluginVersion
            'name'      = $pluginName
            'version'   = $pluginVersion
            'purl'      = 'pkg:github/manderse21/claude-powershell-lsp@v' + $pluginVersion
            'description' = 'PowerShell diagnostics and PSScriptAnalyzer fix suggestions for Claude Code, via PowerShell Editor Services.'
            'supplier'  = [ordered] @{ 'name' = 'Mike Andersen' }
            'licenses'  = @( [ordered] @{ 'license' = [ordered] @{ 'id' = $pluginLicense } } )
            'externalReferences' = @(
                [ordered] @{ 'type' = 'vcs'; 'url' = 'https://github.com/manderse21/claude-powershell-lsp' }
            )
        }
    }
    'components'   = @(
        [ordered] @{
            'type'     = 'library'
            'bom-ref'  = 'pkg:github/PowerShell/PowerShellEditorServices@' + $psesTag
            'name'     = 'PowerShellEditorServices'
            'version'  = $psesVersion
            'purl'     = 'pkg:github/PowerShell/PowerShellEditorServices@' + $psesTag
            'supplier' = [ordered] @{ 'name' = 'Microsoft Corporation' }
            'licenses' = @( [ordered] @{ 'license' = [ordered] @{ 'id' = 'MIT' } } )
            'externalReferences' = @(
                [ordered] @{ 'type' = 'distribution'; 'url' = 'https://github.com/PowerShell/PowerShellEditorServices/releases/download/' + $psesTag + '/PowerShellEditorServices.zip' }
                [ordered] @{ 'type' = 'vcs'; 'url' = 'https://github.com/PowerShell/PowerShellEditorServices' }
            )
        }
        [ordered] @{
            'type'     = 'library'
            'bom-ref'  = 'pkg:nuget/PSScriptAnalyzer@' + $pssaVersion
            'name'     = 'PSScriptAnalyzer'
            'version'  = $pssaVersion
            'purl'     = 'pkg:nuget/PSScriptAnalyzer@' + $pssaVersion
            'supplier' = [ordered] @{ 'name' = 'Microsoft Corporation' }
            'licenses' = @( [ordered] @{ 'license' = [ordered] @{ 'id' = 'MIT' } } )
            'externalReferences' = @(
                [ordered] @{ 'type' = 'distribution'; 'url' = 'https://www.powershellgallery.com/packages/PSScriptAnalyzer/' + $pssaVersion }
                [ordered] @{ 'type' = 'vcs'; 'url' = 'https://github.com/PowerShell/PSScriptAnalyzer' }
            )
        }
    )
}

$json = $bom | ConvertTo-Json -Depth 12

if ([string]::IsNullOrWhiteSpace($OutFile)) {
    Write-Output $json
} else {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutFile, $json + "`n", $utf8NoBom)
    Write-Host ("Wrote CycloneDX SBOM for " + $pluginName + " " + $pluginVersion +
        " (PSES " + $psesVersion + ", PSScriptAnalyzer " + $pssaVersion + ") to " + $OutFile)
}
