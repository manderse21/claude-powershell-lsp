#Requires -Version 5.1

# Get-ChangelogEntry.ps1 -- extract the CHANGELOG section body for one version, so the
# GitHub Release notes are the CHANGELOG entry SINGLE-SOURCED, never hand-retyped (Gap
# C.2 / dispatch 000042). Used by .github/workflows/powershell-lsp-release.yml; runs the
# same way locally and in CI, and is unit-tested by tests/PowerShellLsp.Release.Tests.ps1.
#
# Input  : a MAJOR.MINOR.PATCH version (a leading 'v' is tolerated).
# Output : the text BETWEEN that version's '## [x.y.z] - ...' header and the next '## '
#          heading (or end of file), trimmed -- i.e. the entry body (the PATCH/MINOR
#          summary plus its ### Added/Fixed/... sections). Emitted to stdout, or to
#          -OutFile when given.
# Errors : throws (non-zero) on a malformed version, a missing CHANGELOG, a version with
#          no entry, or an empty entry -- so the release pipeline REFUSES to publish notes
#          it cannot source (you cannot release a version you did not document).
#
# ASCII-only (PS 5.1 em-dash trap). Reads only; writes nothing unless -OutFile is set.
#
# Author: Mike Andersen / powershell-lsp plugin.

[CmdletBinding()]
param(
    # Target version, strict MAJOR.MINOR.PATCH (e.g. 1.13.0); a leading 'v' is stripped.
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $Version,

    # CHANGELOG path. Default: CHANGELOG.md at the repo root (the script's parent dir).
    [string] $Path,

    # Optional output file. Omitted = write the entry to stdout.
    [string] $OutFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Normalize: tolerate a leading 'v', then demand strict MAJOR.MINOR.PATCH.
$v = $Version.Trim()
if ($v.StartsWith('v') -or $v.StartsWith('V')) { $v = $v.Substring(1) }
if ($v -notmatch '^\d+\.\d+\.\d+$') {
    throw "Version must be MAJOR.MINOR.PATCH (e.g. 1.13.0); got '$Version'."
}

if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = Join-Path (Split-Path -Parent $PSScriptRoot) 'CHANGELOG.md'
}
if (-not (Test-Path -LiteralPath $Path)) {
    throw "CHANGELOG not found: $Path"
}

$text = [System.IO.File]::ReadAllText($Path)
$lines = $text -split "`r?`n"

# Locate the '## [<version>] - ...' header for exactly this version.
$headerRx = '^##\s+\[' + [regex]::Escape($v) + '\]'
$startIdx = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match $headerRx) { $startIdx = $i; break }
}
if ($startIdx -lt 0) {
    throw "No CHANGELOG entry for version $v (looked for a '## [$v] - ...' header in $Path)."
}

# Capture every line after the header up to the next '## ' heading (any level-2 section)
# or end of file -- that span is the entry body.
$body = New-Object System.Collections.Generic.List[string]
for ($i = $startIdx + 1; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^##\s') { break }
    $body.Add($lines[$i])
}

$entry = ($body -join "`n").Trim()
if ([string]::IsNullOrWhiteSpace($entry)) {
    throw "CHANGELOG entry for $v is present but empty in $Path."
}

if ([string]::IsNullOrWhiteSpace($OutFile)) {
    Write-Output $entry
} else {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutFile, $entry + "`n", $utf8NoBom)
    Write-Host ("Wrote " + $body.Count + "-line release-notes body for " + $v + " to " + $OutFile)
}
