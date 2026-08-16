#Requires -Version 5.1

# New-AirgapBundle.ps1 -- build the offline / air-gapped artifact bundle for a release
# (dispatch 000244). Produces powershell-lsp-airgap-<version>.zip containing the two PINNED
# downloaded dependencies -- the PowerShell Editor Services release zip and the
# PSScriptAnalyzer .nupkg -- plus a manifest listing both pins.
#
# WHY THIS EXISTS. The plugin downloads those two artifacts on first use, so a machine with no
# egress can never complete a first bootstrap. An admin stages this bundle once, points
# POWERSHELL_LSP_ARTIFACT_BUNDLE_DIR at the unpacked directory, and every machine behind the
# air gap bootstraps from local disk -- through the SAME SHA-256 pin gate as a download.
#
# WHAT IS DELIBERATELY *NOT* IN IT: the plugin's own source. That is already published as its
# own independently attested release asset (powershell-lsp-<version>.tar.gz), and nesting a
# second copy here would create two attested paths to the same bytes that can disagree, and
# would put inert content -- nothing in the bootstrap reads it -- inside a security artifact.
# The offline install path is therefore TWO independently verifiable artifacts, the source and
# this bundle, each with its own `gh attestation verify`. (Ruled by Mike, dispatch 000244; the
# inbox's own rationale, that /plugin install "covers the source via the signed tag", was
# withdrawn as incorrect -- TRUST.md is explicit that the clone-based install path is NOT
# covered by an artifact signature.)
#
# THE PINS ARE THE TRUST ROOT, HERE TOO. Every artifact is verified against the pin read
# straight out of the ensure-script before it is packed, so this generator cannot ship bytes
# the plugin would refuse -- the same single-sourcing that keeps New-PluginSbom.ps1 from
# disagreeing with what the tool downloads. A mismatch throws; it never packs.
#
# Locally runnable, exactly like the other two release helpers, and exercised by
# tests/PowerShellLsp.Release.Tests.ps1.
#
# ASCII-only (PS 5.1 em-dash trap).
#
# Author: Mike Andersen / powershell-lsp plugin.

[CmdletBinding()]
param(
    # Plugin version, used only to NAME the bundle. Default: read from plugin.json.
    [string] $Version,

    # Repo root. Default: the script's parent directory.
    [string] $RepoRoot,

    # Output zip path. Default: powershell-lsp-airgap-<version>.zip in the current directory.
    [string] $OutFile,

    # Optional directory of already-downloaded artifacts, named as Get-PinnedArtifactFileName
    # names them. Present ones are used as-is (and still pin-verified); missing ones are
    # downloaded. Lets CI and the test suite build a bundle without re-fetching.
    [string] $SourceDir,

    # Verify and report only -- do not write a zip. This is what a release DRY RUN uses to
    # prove the bundle ASSEMBLES (pins resolve, artifacts verify) without publishing anything.
    [switch] $VerifyOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}

# Get-PinnedArtifactFileName is the SINGLE source of truth for what a staged artifact is
# called. The bundle builder, the two ensure-scripts and the doctor all derive names from it,
# so a bundle this script writes is one the ensure-scripts can definitely find.
. (Join-Path $RepoRoot 'scripts/lib/lsp-common.ps1')

function Get-PinnedValue {
    # Parse a single-quoted pin out of a bootstrap script WITHOUT executing it (the ensure-*
    # scripts have side effects). Same reader shape as New-PluginSbom.ps1 and doctor.ps1.
    param([string] $FilePath, [string] $VarName)
    $text = Get-Content -LiteralPath $FilePath -Raw
    $rx = [regex] ('\$' + [regex]::Escape($VarName) + "\s*=\s*'([^']+)'")
    $m = $rx.Match($text)
    if (-not $m.Success) { throw ("could not read `$$VarName from " + $FilePath) }
    return $m.Groups[1].Value
}

$psesScript = Join-Path $RepoRoot 'scripts/ensure-pses.ps1'
$pssaScript = Join-Path $RepoRoot 'scripts/ensure-pssa.ps1'

$psesTag = Get-PinnedValue -FilePath $psesScript -VarName 'PsesTag'
$psesSha = Get-PinnedValue -FilePath $psesScript -VarName 'PsesSha256'
$pssaVersion = Get-PinnedValue -FilePath $pssaScript -VarName 'PssaVersion'
$pssaSha = Get-PinnedValue -FilePath $pssaScript -VarName 'PssaSha256'

if ([string]::IsNullOrWhiteSpace($Version)) {
    $manifestPath = Join-Path $RepoRoot '.claude-plugin/plugin.json'
    $Version = (Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json).version
}
if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $OutFile = Join-Path (Get-Location).Path ('powershell-lsp-airgap-' + $Version + '.zip')
}

# The two artifacts, each with the URL it comes from and the pin it must match. The URLs are
# the same ones the ensure-scripts use; they are stated here rather than parsed out because a
# URL is built from the pin in those scripts and re-deriving it is what the pin check guards.
$artifacts = @(
    [pscustomobject]@{
        Name = (Get-PinnedArtifactFileName -Component 'pses' -Version $psesTag)
        Url  = ('https://github.com/PowerShell/PowerShellEditorServices/releases/download/' + $psesTag + '/PowerShellEditorServices.zip')
        Sha  = $psesSha
        Component = 'PowerShellEditorServices'
        Pin  = $psesTag
    }
    [pscustomobject]@{
        Name = (Get-PinnedArtifactFileName -Component 'pssa' -Version $pssaVersion)
        Url  = ('https://www.powershellgallery.com/api/v2/package/PSScriptAnalyzer/' + $pssaVersion)
        Sha  = $pssaSha
        Component = 'PSScriptAnalyzer'
        Pin  = $pssaVersion
    }
)

$staging = Join-Path ([System.IO.Path]::GetTempPath()) ('psls-airgap-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $staging | Out-Null

try {
    foreach ($a in $artifacts) {
        $dest = Join-Path $staging $a.Name
        $reused = $false
        if (-not [string]::IsNullOrWhiteSpace($SourceDir)) {
            $pre = Join-Path $SourceDir $a.Name
            if (Test-Path -LiteralPath $pre -PathType Leaf) {
                Copy-Item -LiteralPath $pre -Destination $dest -Force
                $reused = $true
            }
        }
        if (-not $reused) {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $a.Url -OutFile $dest -UseBasicParsing
        }

        # FAIL CLOSED before packing. A bundle is a security artifact: shipping one byte the
        # plugin would refuse turns an offline install into an unexplainable bootstrap failure
        # at every machine behind the air gap, far from the build that caused it.
        if (-not (Test-PinnedFileHash -Path $dest -ExpectedSha256 $a.Sha)) {
            $actual = ''
            try { $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $dest -ErrorAction Stop).Hash } catch { }
            throw ($a.Component + ' artifact does NOT match its pin -- refusing to pack. Expected ' +
                $a.Sha + ' but got ' + $actual + ' for ' + $a.Name + '.')
        }
        Write-Host ('verified ' + $a.Name + ' against the ' + $a.Component + ' pin (' + $a.Pin + ')')
    }

    # The manifest records what an admin is holding, in a form a human can read and a check can
    # parse. It is documentation of the pins, NOT a trust input: nothing in the bootstrap reads
    # it to decide anything, because the ensure-scripts carry their own pins and a manifest that
    # could override them would be exactly the trust shortcut this design forbids.
    $manifestLines = @(
        '# powershell-lsp airgap bundle',
        ('plugin_version=' + $Version),
        ('generated_for=powershell-lsp-airgap-' + $Version + '.zip')
        ''
        '# component<TAB>pinned-version<TAB>sha256<TAB>filename'
    )
    foreach ($a in $artifacts) {
        $manifestLines += ($a.Component + "`t" + $a.Pin + "`t" + $a.Sha + "`t" + $a.Name)
    }
    $manifestLines += ''
    $manifestLines += '# The SHA-256 values above are the pins in scripts/ensure-pses.ps1 and'
    $manifestLines += '# scripts/ensure-pssa.ps1. The bootstrap verifies against ITS OWN copy of'
    $manifestLines += '# these pins, never against this file -- a manifest that could override a'
    $manifestLines += '# pin would make the bundle a trust root, which it deliberately is not.'
    Set-Content -LiteralPath (Join-Path $staging 'MANIFEST.txt') -Value $manifestLines -Encoding ascii

    if ($VerifyOnly) {
        Write-Host ('VERIFY-ONLY: bundle for ' + $Version + ' assembles; ' + $artifacts.Count +
            ' artifacts verified against their pins and the manifest was generated. No zip written.')
        return
    }

    if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($staging, $OutFile)
    Write-Host ('wrote ' + $OutFile)
} finally {
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
}
