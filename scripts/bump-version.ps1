#Requires -Version 5.1

# bump-version.ps1 -- lockstep version bump for the powershell-lsp plugin. Writes one
# target version into BOTH version surfaces: .claude-plugin/plugin.json (the top-level
# "version") and .claude-plugin/marketplace.json (metadata.version). Lockstep by
# construction -- one input, both files, or neither -- so the two can never drift apart
# again (the v1.3.0 marketplace-vs-plugin drift this exists to prevent).
#
# Dry-run by default: it prints what WOULD change and writes nothing. Pass -Apply to
# write. Idempotent: re-running against an already-bumped repo is a clean no-op.
# Surgical: only the version token is rewritten -- indentation, key order, encoding
# (UTF-8 no BOM) and line endings are preserved byte-for-byte everywhere else, so the
# only diff is the intended version change.
#
# Tagging is Mike's gate: the script PRINTS the post-merge git tag command but NEVER
# runs git tag / git push.
#
# Usage:  pwsh -File scripts/bump-version.ps1 1.4.0           # dry run (default)
#         pwsh -File scripts/bump-version.ps1 1.4.0 -Apply    # write both manifests
#
# Exit 0 on success (including a dry run and an idempotent no-op); throws (non-zero)
# on a bad version string or an unexpected manifest shape.
#
# Author: Mike Andersen / powershell-lsp plugin.

param(
    # Target version, strict MAJOR.MINOR.PATCH (e.g. 1.4.0).
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $Version,

    # Write the change. Omitted = dry run (print the plan, touch no files).
    [switch] $Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Version must be MAJOR.MINOR.PATCH (e.g. 1.4.0); got '$Version'."
}

# The two version surfaces that must stay in lockstep. Each carries exactly one
# "version": "X.Y.Z" token; the match count is asserted == 1 per file below, so an
# unexpected manifest shape fails loud instead of writing a partial or garbled bump.
$root = Split-Path -Parent $PSScriptRoot
$targets = @(
    @{ name = 'plugin.json';      path = (Join-Path $root '.claude-plugin/plugin.json') },
    @{ name = 'marketplace.json'; path = (Join-Path $root '.claude-plugin/marketplace.json') }
)

$rx = [regex] '("version"\s*:\s*")(?<ver>[^"]+)(")'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$mode = if ($Apply) { 'APPLY' } else { 'DRY RUN' }
Write-Host ('bump-version -- target ' + $Version + ' (' + $mode + ')')

# --- build the plan (read + locate, write nothing yet) ---------------------
$plan = @()
foreach ($t in $targets) {
    if (-not (Test-Path -LiteralPath $t.path)) {
        throw ('manifest not found: ' + $t.path)
    }
    $text = [System.IO.File]::ReadAllText($t.path)
    $ms = $rx.Matches($text)
    if ($ms.Count -ne 1) {
        throw ('expected exactly one version field in ' + $t.name + ', found ' + $ms.Count + '.')
    }
    $g = $ms[0].Groups['ver']
    $old = $g.Value
    # Splice only the version span; the rest of the file (EOLs, trailing newline,
    # every other byte) is carried through verbatim.
    $newText = $text.Substring(0, $g.Index) + $Version + $text.Substring($g.Index + $g.Length)
    $plan += [pscustomobject]@{
        Name    = $t.name
        Path    = $t.path
        Old     = $old
        NewText = $newText
        Changed = ($old -ne $Version)
    }
}

foreach ($p in $plan) {
    if ($p.Changed) {
        Write-Host ('  {0,-18} {1} -> {2}' -f $p.Name, $p.Old, $Version)
    } else {
        Write-Host ('  {0,-18} already {1}' -f $p.Name, $Version)
    }
}

# --- apply (or report the dry run) -----------------------------------------
if ($Apply) {
    foreach ($p in $plan) {
        if ($p.Changed) {
            [System.IO.File]::WriteAllText($p.Path, $p.NewText, $utf8NoBom)
        }
    }
    # Re-read from disk and assert lockstep -- the helper verifies its own result.
    $onDisk = @()
    foreach ($t in $targets) {
        $text = [System.IO.File]::ReadAllText($t.path)
        $onDisk += $rx.Match($text).Groups['ver'].Value
    }
    $distinct = @($onDisk | Select-Object -Unique)
    if ($distinct.Count -ne 1 -or $distinct[0] -ne $Version) {
        throw ('lockstep check FAILED: on-disk versions = ' + ($onDisk -join ', ') +
            ' (expected both ' + $Version + ').')
    }
    Write-Host ('  lockstep OK: both manifests at ' + $Version)
} else {
    $unchanged = @($plan | Where-Object { -not $_.Changed }).Count
    if ($unchanged -eq $plan.Count) {
        Write-Host ('  lockstep OK: both manifests already at ' + $Version + ' (no change)')
    } else {
        Write-Host '  DRY RUN -- no files written. Re-run with -Apply to write.'
    }
}

# --- print the tag command (Mike's gate; never executed here) --------------
Write-Host ''
Write-Host 'Tagging is a manual gate -- run these AFTER the release merges to main:'
Write-Host ('  git tag v' + $Version)
Write-Host ('  git push origin v' + $Version)

exit 0
