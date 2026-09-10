#Requires -Version 5.1
# RED CONTROL for dispatch 000291 -- the NAIVE FIRST-CUT shape metric.
#
# RECORDED HONESTLY FOR WHAT IT IS: not a prior implementation. `New-OtelShapeCountPoints` is
# new in 000291 and nothing shipped before it, so there is no earlier version to restore and
# this control is a weaker warrant than one that restores real history. What it IS is the
# implementation the obvious first pass produces: you have hashes, you want to know about
# shapes, so you emit one point per hash and put the hash on as an attribute. It reads as more
# informative than the shipped version, and it is exactly the mistake the design refuses --
# unbounded cardinality, one time series per distinct diagnostic, and the shape identifiers
# themselves published off the host.
#
# IT OVERRIDES EXACTLY ONE FUNCTION, which is what gives the control a SURVIVING ARM. The five
# metrics 000290 shipped -- edits, edit.duration, diagnostics.records, diagnostics.corrections,
# edit.scope_trimmed -- are shipped code in BOTH runs and must come out identical, so a fixture
# that broke the renderer instead of defeating the boundary is caught rather than credited.
#
# ASCII-only (Windows PowerShell 5.1 reads a UTF-8-without-BOM file through Windows-1252).

function New-OtelShapeCountPoints {
    # The naive cut: one point per distinct hash, carrying the hash as an attribute.
    param([object[]] $Records, [string] $TimeUnixNano, [string] $StartTimeUnixNano)
    $byHash = [ordered]@{}
    foreach ($r in @($Records)) {
        $h = Get-OtelField -Record $r -Name 'hash'
        if ($null -eq $h -or [string]::IsNullOrWhiteSpace([string]$h)) { continue }
        $k = [string]$h
        if (-not $byHash.Contains($k)) { $byHash[$k] = [ordered]@{ n = 0; row = $r } }
        $byHash[$k].n = [int]$byHash[$k].n + 1
    }
    $points = @()
    foreach ($k in $byHash.Keys) {
        $points += [ordered]@{
            asInt             = [string][int]$byHash[$k].n
            timeUnixNano      = $TimeUnixNano
            startTimeUnixNano = $StartTimeUnixNano
            attributes        = @(
                (New-OtelAttribute -Key 'hash' -Value $k),
                (New-OtelAttribute -Key 'ruleId' -Value ([string](Get-OtelField -Record $byHash[$k].row -Name 'ruleId')))
            )
        }
    }
    return @($points)
}
