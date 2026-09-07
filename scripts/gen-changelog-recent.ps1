#Requires -Version 5.1

# gen-changelog-recent.ps1 -- generate docs/CHANGELOG-recent.md, the recent-only companion
# of CHANGELOG.md (dispatch 000283, ruling R6).
#
# WHY THIS EXISTS. CHANGELOG.md is a RELEASE ARTIFACT: the release pipeline extracts a
# version's notes from it verbatim, and scripts/audit-release-bodies.ps1 compares every
# published body against it. It is therefore never truncated, never rewritten, and never
# summarised -- doing any of those would silently change what an already-published release
# says it shipped. But it is also 273 KB and growing, and the project-knowledge bundle that
# a planning session reads has a fixed byte budget. Those two facts are only in conflict if
# the SAME file has to satisfy both readers.
#
# So the bundle carries this GENERATED companion instead, and CHANGELOG.md stays byte-for-byte
# what it was. The companion is a strict PREFIX of the source -- the header, the versioning
# policy, [Unreleased], and every entry down to the third-most-recent MINOR line inclusive --
# so every sentence in it is the source's own sentence, at its own byte offset relative to the
# top. Nothing is rephrased and nothing is elided from the middle; the file simply stops.
#
# THE BOUNDARY IS DERIVED, NEVER PINNED. "The last three MINOR lines" is computed from the
# headings present at generation time: find the third `## [X.Y.0]` heading from the top, then
# cut immediately before the next `## [` heading below it. Pinning a version here would go
# stale at the next MINOR and quietly start shipping four bands, then five.
#
# -Check regenerates into memory and compares against the file on disk, exiting 1 when they
# differ. That is what makes a stale companion a test failure rather than a thing someone
# notices later: the committed file is only ever correct because the check says so.
#
# Exit codes:
#   0  wrote the companion (default), or -Check found it current.
#   1  -Check found the committed companion STALE (regenerate and commit it).
#   2  the source CHANGELOG does not have the shape this script requires.
#
# ASCII-only (PS 5.1 em-dash trap); StrictMode-safe.
#
# Author: Mike Andersen / powershell-lsp plugin.

[CmdletBinding()]
param(
    # Compare only: regenerate in memory, exit 1 if the committed companion differs.
    [switch] $Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $root 'CHANGELOG.md'
$dest = Join-Path $root 'docs/CHANGELOG-recent.md'

if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
    Write-Error ('source not found: ' + $source)
    exit 2
}

# Read as BYTES and split on the source's own line ending, so the companion inherits it
# rather than being normalised to whatever this host prefers.
$raw = [System.IO.File]::ReadAllText($source)
$eol = if (([regex]::Matches($raw, "`r`n")).Count * 2 -gt ([regex]::Matches($raw, "`n")).Count) { "`r`n" } else { "`n" }
$lines = $raw -split "`r?`n"

# Every released-version heading, in file order.
$headings = @()
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^## \[\d+\.\d+\.\d+\]') {
        $headings += [pscustomobject]@{ Index = $i; Text = $lines[$i] }
    }
}
if ($headings.Count -lt 4) {
    Write-Error ('CHANGELOG carries only ' + $headings.Count + ' version headings; expected at least 4.')
    exit 2
}

$minors = @($headings | Where-Object { $_.Text -match '^## \[\d+\.\d+\.0\]' })
if ($minors.Count -lt 3) {
    Write-Error ('CHANGELOG carries only ' + $minors.Count + ' MINOR headings; expected at least 3.')
    exit 2
}
$thirdMinor = $minors[2]

# Cut immediately BEFORE the first version heading below the third MINOR -- so that MINOR
# band is carried whole, including any PATCH entries that sit above it.
$below = @($headings | Where-Object { $_.Index -gt $thirdMinor.Index })
if ($below.Count -lt 1) {
    Write-Error 'no version heading below the third MINOR; the companion would be the whole file.'
    exit 2
}
$cut = $below[0].Index

$banner = @(
    '<!-- GENERATED FILE -- DO NOT EDIT.',
    '',
    '     Produced by scripts/gen-changelog-recent.ps1 from CHANGELOG.md, which is the release',
    '     artifact and the only file to edit. This companion is a strict PREFIX of that file:',
    '     the header, the versioning policy, [Unreleased], and every entry down to and including',
    ('     the ' + $thirdMinor.Text.Trim() + ' band -- the third-most-recent MINOR line, derived at'),
    '     generation time rather than pinned. Nothing is rephrased and nothing is dropped from',
    '     the middle; the file stops.',
    '',
    '     It exists so the project-knowledge bundle can carry a recent changelog without carrying',
    '     the whole one, and so CHANGELOG.md itself never has to be truncated to fit a budget',
    '     (dispatch 000283, ruling R6). Regenerate with:',
    '',
    '         pwsh -File scripts/gen-changelog-recent.ps1',
    '',
    '     Verify it is current with -Check, which exits 1 when this file is stale.',
    '-->',
    ''
)

$body = $lines[0..($cut - 1)]
$outText = (($banner + $body) -join $eol)
if (-not $outText.EndsWith($eol)) { $outText += $eol }

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if ($Check) {
    if (-not (Test-Path -LiteralPath $dest -PathType Leaf)) {
        Write-Host ('STALE: ' + $dest + ' does not exist')
        exit 1
    }
    $have = [System.IO.File]::ReadAllText($dest)
    if ($have -eq $outText) {
        Write-Host ('CURRENT: docs/CHANGELOG-recent.md matches CHANGELOG.md through ' + $thirdMinor.Text.Trim() + ' (' + $outText.Length + ' chars)')
        exit 0
    }
    Write-Host ('STALE: docs/CHANGELOG-recent.md is ' + $have.Length + ' chars, regeneration is ' + $outText.Length + ' chars')
    Write-Host 'Run: pwsh -File scripts/gen-changelog-recent.ps1'
    exit 1
}

[System.IO.File]::WriteAllText($dest, $outText, $utf8NoBom)
Write-Host ('wrote docs/CHANGELOG-recent.md -- ' + $outText.Length + ' chars, through ' + $thirdMinor.Text.Trim() + ' (source is ' + $raw.Length + ' chars, unchanged)')
exit 0
