#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# print-pssa-pin.ps1 -- print the PINNED PSScriptAnalyzer version and SHA-256, read from
# scripts/ensure-pssa.ps1 (the SINGLE source of truth), as GITHUB_OUTPUT-compatible
# `name=value` lines:
#     version=1.25.0
#     sha256=14E634C8...
#
# CI feeds these into the actions/cache key (pssa-<os>-<version>-<sha256>) so the cache KEY
# BINDS to the pin: a pin bump (version or hash) changes the key, and a changed pin can never
# draw a stale cached .nupkg (dispatch 000049, load-bearing invariant 2). This READS -- never
# executes -- ensure-pssa.ps1, so it has NO vendoring side effects. The regex is the same shape
# the release SBOM/tests use to single-source the pins. ASCII-only (PS 5.1 em-dash trap).
#
# Author: Mike Andersen / powershell-lsp plugin.

$ensurePssa = Join-Path $PSScriptRoot 'ensure-pssa.ps1'
$src = [System.IO.File]::ReadAllText($ensurePssa)

function Get-Pin {
    # Match  $<Var> = '<value>'  and return the captured value, or throw if the pin moved.
    param([string]$Var, [string]$ValuePattern)
    $rx = [regex] ('\$' + [regex]::Escape($Var) + "\s*=\s*'(" + $ValuePattern + ")'")
    $m = $rx.Match($src)
    if (-not $m.Success) { throw ('could not resolve $' + $Var + ' from ' + $ensurePssa) }
    return $m.Groups[1].Value
}

$version = Get-Pin 'PssaVersion' '[^'']+'
$sha256 = Get-Pin 'PssaSha256' '[0-9A-Fa-f]{64}'

Write-Output ('version=' + $version)
Write-Output ('sha256=' + $sha256)
