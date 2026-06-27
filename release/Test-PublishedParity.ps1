#Requires -Version 5.1

# Test-PublishedParity.ps1 -- tree-vs-published divergence guard (dispatch 000076).
#
# FAILS (throws) when the PUBLISHED plugin version LAGS the working-tree version. The
# "published" version is what a fresh marketplace resolve installs: the
# .claude-plugin/plugin.json "version" on the remote DEFAULT BRANCH the marketplace
# clones. The marketplace entry is source "./" with no ref pin, so it resolves the
# default-branch tip -- NOT a git tag and NOT a GitHub Release. This guard exists to
# prevent the silent drift where the tree advances (1.4.0 ... 1.18.x) while the
# installable artifact is left behind -- the published-1.3.0-vs-tree-1.18.x gap that
# dispatch 000076 closed (the served 1.3.0 was a stale marketplace clone of an old
# default-branch tip).
#
# Tree version source:
#   -TreeRef <ref>        read "version" from <ref>:.claude-plugin/plugin.json (git)
#   -TreeManifest <path>  read "version" from a manifest file
#   (default)             .claude-plugin/plugin.json at the repo root (the working tree)
#
# Published version source (the first one set wins):
#   -PublishedVersion X.Y.Z    explicit (CI may pass a value it already resolved)
#   -PublishedManifest <path>  read "version" from a manifest file (a fixture, or a local
#                              marketplace clone's manifest)
#   (default)                  git show <Ref>:.claude-plugin/plugin.json (Ref = origin/main);
#                              pass -Fetch to refresh origin first.
#
# Throws when published < tree (the installable artifact lags the tree) or on a structural
# error (a missing / garbled / non-semver manifest is the SAFE-FAIL direction: refuse,
# never pass). Completes OK when published >= tree (parity, or published ahead).
#
# ASCII-only (PS 5.1 em-dash trap). Reads only; never writes, tags, or pushes. Run it
# standalone (pwsh -File release/Test-PublishedParity.ps1) or from the release workflow's
# parity gate; unit-tested by tests/PowerShellLsp.Release.Tests.ps1.
#
# Author: Mike Andersen / powershell-lsp plugin.

[CmdletBinding()]
param(
    # Working-tree manifest file. Default: .claude-plugin/plugin.json at the repo root.
    [string] $TreeManifest,

    # Read the tree version from a git ref's manifest instead of a file (CI: the release target).
    [string] $TreeRef,

    # Published version, explicit (highest precedence). Strict MAJOR.MINOR.PATCH.
    [string] $PublishedVersion,

    # Published manifest file to read "version" from (a fixture, or a clone's manifest).
    [string] $PublishedManifest,

    # Git ref whose .claude-plugin/plugin.json IS the published manifest (the default source).
    [string] $Ref = 'origin/main',

    # Refresh origin before reading $Ref (only used by the default git source).
    [switch] $Fetch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Confirm-Semver {
    param([string] $Value, [string] $Source)
    if ($Value -notmatch '^\d+\.\d+\.\d+$') {
        throw "version '$Value' from $Source is not MAJOR.MINOR.PATCH."
    }
    return $Value
}

function Get-JsonVersion {
    param([string] $Json, [string] $Source)
    try { $obj = $Json | ConvertFrom-Json } catch {
        throw "cannot parse JSON from ${Source}: $($_.Exception.Message)"
    }
    if (($null -eq $obj) -or ($obj.PSObject.Properties.Name -notcontains 'version')) {
        throw "no 'version' field in $Source."
    }
    return (Confirm-Semver ([string]$obj.version) $Source)
}

function Get-RefManifestVersion {
    param([string] $GitRef)
    $spec = $GitRef + ':.claude-plugin/plugin.json'
    $json = (& git show $spec 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "git show $spec failed -- cannot read the manifest at '$GitRef'. $json"
    }
    return (Get-JsonVersion $json $spec)
}

function Compare-Semver {
    # Returns <0 if A<B, 0 if A==B, >0 if A>B. Inputs are pre-validated MAJOR.MINOR.PATCH.
    param([string] $A, [string] $B)
    $pa = $A.Split('.'); $pb = $B.Split('.')
    for ($i = 0; $i -lt 3; $i++) {
        $d = [int]$pa[$i] - [int]$pb[$i]
        if ($d -ne 0) { return $d }
    }
    return 0
}

# --- tree version --------------------------------------------------------------
if (-not [string]::IsNullOrWhiteSpace($TreeRef)) {
    $treeVer = Get-RefManifestVersion $TreeRef
    $treeSrc = "git ${TreeRef}:.claude-plugin/plugin.json"
} else {
    if ([string]::IsNullOrWhiteSpace($TreeManifest)) {
        $TreeManifest = Join-Path (Split-Path -Parent $PSScriptRoot) '.claude-plugin/plugin.json'
    }
    if (-not (Test-Path -LiteralPath $TreeManifest)) {
        throw "tree manifest not found: $TreeManifest"
    }
    $treeVer = Get-JsonVersion ([System.IO.File]::ReadAllText($TreeManifest)) $TreeManifest
    $treeSrc = $TreeManifest
}

# --- published version ---------------------------------------------------------
if (-not [string]::IsNullOrWhiteSpace($PublishedVersion)) {
    $pubVer = Confirm-Semver ($PublishedVersion.Trim()) 'explicit -PublishedVersion'
    $pubSrc = "explicit ($pubVer)"
} elseif (-not [string]::IsNullOrWhiteSpace($PublishedManifest)) {
    if (-not (Test-Path -LiteralPath $PublishedManifest)) {
        throw "published manifest not found: $PublishedManifest"
    }
    $pubVer = Get-JsonVersion ([System.IO.File]::ReadAllText($PublishedManifest)) $PublishedManifest
    $pubSrc = "manifest $PublishedManifest"
} else {
    if ($Fetch) {
        & git fetch --quiet origin 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git fetch origin failed ($LASTEXITCODE)." }
    }
    $pubVer = Get-RefManifestVersion $Ref
    $pubSrc = "git ${Ref}:.claude-plugin/plugin.json"
}

# --- verdict -------------------------------------------------------------------
Write-Host ("published-parity guard -- tree=$treeVer ($treeSrc)  published=$pubVer ($pubSrc)")
if ((Compare-Semver $pubVer $treeVer) -lt 0) {
    throw ("DIVERGENCE: published version $pubVer LAGS tree version $treeVer -- the installable " +
        "(marketplace-resolved) artifact is behind the tree. Lockstep-bump and land the tree version " +
        "on the default branch the marketplace resolves, then re-run. (dispatch 000076 guard)")
}
Write-Host ("OK: published ($pubVer) is in parity with or ahead of tree ($treeVer) -- no divergence.")
