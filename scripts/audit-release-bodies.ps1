#Requires -Version 5.1

# audit-release-bodies.ps1 -- compare every PUBLISHED GitHub release body against the
# CHANGELOG entry it was cut from, and report every divergence (dispatch 000179 leg 4).
#
# WHY THIS EXISTS
#   RELEASING.md step 2 says the CHANGELOG entry "becomes the release notes verbatim", and
#   the pipeline enforces that at publish time by generating the notes with
#   release/Get-ChangelogEntry.ps1. Nothing enforced it AFTERWARDS. When a CHANGELOG entry
#   is corrected after its release is published -- which this project does deliberately,
#   by APPENDING a dated correction rather than rewriting shipped text -- the published
#   body does not follow, and a reader of the release notes is left with the superseded
#   text. Dispatch 000177 found two such bodies by hand-sweeping all 22 releases. This
#   script is that sweep, committed, so the next release checks itself instead of waiting
#   for a survey to notice.
#
#   A published release body is EXTERNAL state: it is not a file on disk, so no CI check
#   can derive it and no test can fail on it. That is why the durable gate this script
#   serves is a HUMAN pre-publish step in docs/RELEASING.md rather than a
#   tests/doc-claims.psd1 registry row. This script does not close that gap -- it makes
#   honouring the human gate one command instead of an act of diligence.
#
# WHAT IT COMPARES
#   For each published release tag v<x.y.z>:
#     published : the release body, read via `gh release view <tag> --json body`
#     expected  : release/Get-ChangelogEntry.ps1 -Version <x.y.z> -- the SAME extractor
#                 the release workflow uses, so "expected" is literally what the pipeline
#                 would publish for that version from the CHANGELOG as it stands today.
#   Both sides are whitespace-normalized (CRLF -> LF, runs of whitespace collapsed to one
#   space, trimmed) before comparing, so re-wrapping and trailing-newline noise cannot
#   raise a false divergence.
#
# EXIT CODES
#   0  every published body agrees with its CHANGELOG entry
#   2  at least one divergence (or a release with no CHANGELOG entry at all)
#   1  the sweep could not run (gh missing / not authenticated / bad arguments)
#
# ASCII-only (PS 5.1 em-dash trap). Reads only; never mutates a release.
#
# Author: Mike Andersen / powershell-lsp plugin.

[CmdletBinding()]
param(
    # CHANGELOG to compare against. Default: CHANGELOG.md at the repo root.
    # Point this at a modified COPY to prove the sweep is non-vacuous (see -Help notes).
    [string] $ChangelogPath,

    # Restrict the sweep to these tags (e.g. v1.29.0). Default: every published release.
    [string[]] $Tag,

    # GitHub repository, OWNER/NAME. Default: whatever `gh` resolves for this checkout.
    [string] $Repo,

    # Read bodies from <dir>/<tag>.md instead of calling `gh`. Lets the sweep run offline
    # against a captured snapshot; a tag with no file in the dir is still fetched via gh.
    [string] $BodyDir,

    # Emit the per-tag result as JSON on stdout instead of the human table.
    [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ChangelogPath)) {
    $ChangelogPath = Join-Path $repoRoot 'CHANGELOG.md'
}
if (-not (Test-Path -LiteralPath $ChangelogPath)) {
    Write-Error "CHANGELOG not found: $ChangelogPath"
    exit 1
}
$extractor = Join-Path (Join-Path $repoRoot 'release') 'Get-ChangelogEntry.ps1'
if (-not (Test-Path -LiteralPath $extractor)) {
    Write-Error "Release-notes extractor not found: $extractor"
    exit 1
}

# Collapse everything the comparison must not care about: line endings, hard-wrap
# positions, indentation, trailing blank lines.
function Get-NormalizedText {
    param([string] $Text)
    if ($null -eq $Text) { return '' }
    $t = $Text -replace "`r`n", "`n"
    $t = $t -replace '\s+', ' '
    return $t.Trim()
}

# Where two normalized strings first differ, with a little context from each side, so a
# divergence is actionable rather than merely reported.
function Get-FirstDivergence {
    param([string] $Expected, [string] $Published)
    $n = [Math]::Min($Expected.Length, $Published.Length)
    $i = 0
    while ($i -lt $n -and $Expected[$i] -eq $Published[$i]) { $i++ }
    $from = [Math]::Max(0, $i - 40)
    $take = 140
    $expExcerpt = if ($i -ge $Expected.Length) { '<end of CHANGELOG entry>' }
                  else { $Expected.Substring($from, [Math]::Min($take, $Expected.Length - $from)) }
    $pubExcerpt = if ($i -ge $Published.Length) { '<end of published body>' }
                  else { $Published.Substring($from, [Math]::Min($take, $Published.Length - $from)) }
    return [pscustomobject]@{
        offset            = $i
        expectedExcerpt   = $expExcerpt
        publishedExcerpt  = $pubExcerpt
    }
}

$ghArgsRepo = @()
if (-not [string]::IsNullOrWhiteSpace($Repo)) { $ghArgsRepo = @('--repo', $Repo) }

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Error "The GitHub CLI (gh) is required to read published release bodies."
    exit 1
}

# The tag set. Native stderr is captured rather than left to throw under EAP=Stop on 5.1.
$ErrorActionPreference = 'Continue'
if ($Tag -and $Tag.Count -gt 0) {
    $tags = @($Tag)
} else {
    $listed = & gh release list @ghArgsRepo --limit 500 --json tagName 2>&1
    if ($LASTEXITCODE -ne 0) {
        $ErrorActionPreference = 'Stop'
        Write-Error ("gh release list failed: " + ($listed -join ' '))
        exit 1
    }
    $tags = @(($listed | Out-String | ConvertFrom-Json) | ForEach-Object { $_.tagName })
}

$results = New-Object System.Collections.Generic.List[object]
$mismatch = 0
$errors = 0

foreach ($t in ($tags | Sort-Object)) {
    $ver = $t
    if ($ver.StartsWith('v') -or $ver.StartsWith('V')) { $ver = $ver.Substring(1) }
    if ($ver -notmatch '^\d+\.\d+\.\d+$') {
        $results.Add([pscustomobject]@{ tag = $t; status = 'SKIPPED'; detail = 'tag is not a MAJOR.MINOR.PATCH release tag'; divergence = $null })
        continue
    }

    # published side
    $body = $null
    $cached = $null
    if (-not [string]::IsNullOrWhiteSpace($BodyDir)) {
        $candidate = Join-Path $BodyDir ($t + '.md')
        if (Test-Path -LiteralPath $candidate) { $cached = $candidate }
    }
    if ($cached) {
        $body = [System.IO.File]::ReadAllText($cached)
    } else {
        $body = & gh release view $t @ghArgsRepo --json body -q .body 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            $errors++
            $results.Add([pscustomobject]@{ tag = $t; status = 'ERROR'; detail = ('could not read the published body: ' + ($body -replace '\s+', ' ').Trim()); divergence = $null })
            continue
        }
    }

    # expected side -- the SAME extractor the release workflow runs
    $expected = & $extractor -Version $ver -Path $ChangelogPath 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($expected)) {
        $errors++
        $results.Add([pscustomobject]@{ tag = $t; status = 'ERROR'; detail = ('no usable CHANGELOG entry for ' + $ver + ': ' + ($expected -replace '\s+', ' ').Trim()); divergence = $null })
        continue
    }

    $ne = Get-NormalizedText $expected
    $nb = Get-NormalizedText $body
    if ($ne -eq $nb) {
        $results.Add([pscustomobject]@{ tag = $t; status = 'MATCH'; detail = ''; divergence = $null })
    } else {
        $mismatch++
        $d = Get-FirstDivergence -Expected $ne -Published $nb
        $results.Add([pscustomobject]@{
            tag        = $t
            status     = 'MISMATCH'
            detail     = ('published body and CHANGELOG entry diverge at normalized offset ' + $d.offset)
            divergence = $d
        })
    }
}
$ErrorActionPreference = 'Stop'

if ($Json) {
    $results | ConvertTo-Json -Depth 5
} else {
    Write-Host ''
    Write-Host 'Published release body vs CHANGELOG entry'
    Write-Host ('CHANGELOG: ' + $ChangelogPath)
    Write-Host ''
    foreach ($r in $results) {
        $line = '{0,-10} {1}' -f $r.status, $r.tag
        Write-Host $line
        if ($r.status -eq 'MISMATCH') {
            Write-Host ('             ' + $r.detail)
            Write-Host ('             CHANGELOG : ...' + $r.divergence.expectedExcerpt + '...')
            Write-Host ('             PUBLISHED : ...' + $r.divergence.publishedExcerpt + '...')
        } elseif ($r.status -ne 'MATCH' -and $r.detail) {
            Write-Host ('             ' + $r.detail)
        }
    }
    $matched = @($results | Where-Object { $_.status -eq 'MATCH' }).Count
    Write-Host ''
    Write-Host ('SELECTED ' + $results.Count + ' release(s); MATCH ' + $matched + ', MISMATCH ' + $mismatch + ', ERROR ' + $errors)
    if ($mismatch -gt 0) {
        Write-Host ''
        Write-Host 'A MISMATCH means the PUBLISHED body no longer says what the CHANGELOG says.'
        Write-Host 'Per docs/RELEASING.md, mirror the CHANGELOG correction into the published body'
        Write-Host 'by APPENDING a dated correction -- never by rewriting the shipped text.'
    }
}

if ($mismatch -gt 0 -or $errors -gt 0) { exit 2 }
exit 0
