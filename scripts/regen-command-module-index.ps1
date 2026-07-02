#Requires -Version 5.1
[CmdletBinding()]
param(
    # Compare the DERIVED index against the shipped rulesets/command-module-index.psd1
    # instead of writing it. Exit 0 when they match EXACTLY, 1 (with a diff) on drift.
    [switch] $Check,
    # Explicit source-snapshot path. Empty = the committed rulesets/command-module-index.source.psd1.
    [string] $SourcePath = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# regen-command-module-index.ps1 -- REGENERATE (or -Check) the shipped command->module index
# rulesets/command-module-index.psd1 from the VENDORED source snapshot
# rulesets/command-module-index.source.psd1 (dispatch 000101, PL-6 module awareness). This
# makes the index's derivation EXECUTABLE and OFFLINE-REPRODUCIBLE: the shipped file is the
# source snapshot's (command -> owning module) pairs, MINUS every name on the source's built-in
# denylist (rung 1), MINUS every name owned by more than one module (the EXCLUSION collision
# policy -- a mis-attribution is itself a false positive, so an ambiguous name is dropped, never
# guessed). It mirrors scripts/regen-base-ruleset.ps1: the artifact ENUMERATES rather than
# computing at load, so a source-snapshot refresh is a DELIBERATE, reviewed regeneration.
#
# The load-bearing property (the 000100 survey's determinism requirement): the derivation reads
# ONLY the committed source snapshot -- never a live module, never the network -- so -Check is
# fully offline and host-independent (green on a box with NONE of the indexed modules installed).
# A source refresh (new module / version bump) is a separate dispatch that re-vendors the
# snapshot on an installed host, then re-runs this generator and reviews the diff.
#
# ASCII-only (PS 5.1 em-dash trap); straight quotes; LF; no BOM.
#
# Author: Mike Andersen / powershell-lsp plugin.

function Get-SourceSnapshotPath {
    param([string]$Explicit)
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) { return $Explicit }
    return (Join-Path (Split-Path -Parent $PSScriptRoot) 'rulesets/command-module-index.source.psd1')
}

function Get-ShippedIndexPath {
    return (Join-Path (Split-Path -Parent $PSScriptRoot) 'rulesets/command-module-index.psd1')
}

function Get-DerivedIndex {
    # The reproducible derivation: (command -> module) pairs from the source snapshot, minus the
    # built-in denylist (rung 1), minus every name owned by >1 module (EXCLUSION). Returns
    # @{ Entries = @{ name -> module }; Modules = @( @{name;version;source} ... sorted ) }.
    param([string]$SourceSnapshotPath)
    if (-not (Test-Path -LiteralPath $SourceSnapshotPath -PathType Leaf)) {
        throw ('source snapshot not found: ' + $SourceSnapshotPath)
    }
    $src = Import-PowerShellDataFile -LiteralPath $SourceSnapshotPath
    # Built-in denylist (case-insensitive).
    $builtins = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($b in @($src['builtins'])) {
        $bn = [string]$b
        if (-not [string]::IsNullOrWhiteSpace($bn)) { [void]$builtins.Add($bn) }
    }
    # name (lowercased) -> @{ display; modules=SortedSet } to detect cross-module collisions.
    $owners = @{}
    $moduleProv = New-Object System.Collections.ArrayList
    foreach ($m in @($src['modules'])) {
        $mn = [string]$m['name']
        if ([string]::IsNullOrWhiteSpace($mn)) { continue }
        [void]$moduleProv.Add([pscustomobject]@{
                name = $mn; version = [string]$m['version']; source = [string]$m['source']
            })
        foreach ($c in @($m['commands'])) {
            $cn = [string]$c
            if ([string]::IsNullOrWhiteSpace($cn)) { continue }
            if ($builtins.Contains($cn)) { continue }   # rung 1: a built-in always wins; never indexed.
            $key = $cn.ToLowerInvariant()
            if (-not $owners.ContainsKey($key)) {
                $owners[$key] = @{ display = $cn; modules = (New-Object System.Collections.Generic.SortedSet[string]([System.StringComparer]::OrdinalIgnoreCase)) }
            }
            [void]$owners[$key].modules.Add($mn)
        }
    }
    # EXCLUSION: keep only names owned by EXACTLY ONE module.
    $entries = @{}
    foreach ($key in $owners.Keys) {
        $rec = $owners[$key]
        if (@($rec.modules).Count -eq 1) { $entries[$rec.display] = @($rec.modules)[0] }
    }
    return @{ Entries = $entries; Modules = @($moduleProv | Sort-Object name) }
}

function Format-IndexFile {
    # Emit the shipped index .psd1 text (deterministic: entries + modules sorted). ASCII/LF/no BOM.
    param($Derived)
    $entries = $Derived.Entries
    $modules = @($Derived.Modules)
    $names = @($entries.Keys | Sort-Object)
    $sb = New-Object System.Text.StringBuilder
    $add = { param([string]$s) [void]$sb.Append($s); [void]$sb.Append("`n") }
    & $add '# command-module-index.psd1 -- GENERATED shipped command->module index (do not hand-edit).'
    & $add '#'
    & $add '# Names-only interoperability metadata: each entry maps a command NAME to the NAME of the'
    & $add '# module that exports it. Ships NO module content. DERIVED from the vendored source snapshot'
    & $add '# rulesets/command-module-index.source.psd1 by scripts/regen-command-module-index.ps1 (built-in'
    & $add '# denylist + one-owner EXCLUSION applied). Refreshed ONLY by a deliberate dispatch: re-vendor'
    & $add '# the source snapshot, re-run the generator, review the diff. No network at edit time, ever.'
    & $add '#'
    & $add '# To regenerate: pwsh scripts/regen-command-module-index.ps1 ; to verify: -Check (offline).'
    & $add ''
    & $add '@{'
    & $add "    schema = 'command-module-index/v1'"
    & $add "    generated_from = 'command-module-index.source.psd1'"
    & $add ("    module_count = " + $modules.Count)
    & $add ("    entry_count = " + $names.Count)
    & $add '    modules = @('
    foreach ($m in $modules) {
        & $add ("        @{ name = '" + $m.name + "'; version = '" + $m.version + "'; source = '" + $m.source + "' }")
    }
    & $add '    )'
    & $add '    # command NAME -> owning module NAME (the runtime lookup; O(1) membership per edit).'
    & $add '    entries = @{'
    foreach ($n in $names) {
        & $add ("        '" + $n + "' = '" + $entries[$n] + "'")
    }
    & $add '    }'
    & $add '}'
    return $sb.ToString()
}

function Get-IndexCanonical {
    # Canonical, order-independent string of an index (entries + module provenance) for diffing.
    param($Entries, $Modules)
    $lines = New-Object System.Collections.ArrayList
    foreach ($n in @($Entries.Keys | Sort-Object)) { [void]$lines.Add('E ' + $n + ' -> ' + $Entries[$n]) }
    foreach ($m in @($Modules | Sort-Object name)) { [void]$lines.Add('M ' + $m.name + ' | ' + $m.version + ' | ' + $m.source) }
    return ($lines -join "`n")
}

$sourcePath = Get-SourceSnapshotPath -Explicit $SourcePath
$derived = Get-DerivedIndex -SourceSnapshotPath $sourcePath
$shippedPath = Get-ShippedIndexPath

if ($Check) {
    if (-not (Test-Path -LiteralPath $shippedPath -PathType Leaf)) {
        [Console]::Error.WriteLine('regen-command-module-index: shipped command-module-index.psd1 not found; run without -Check to generate it.')
        exit 1
    }
    $shipped = Import-PowerShellDataFile -LiteralPath $shippedPath
    $shippedEntries = @{}
    foreach ($k in @($shipped['entries'].Keys)) { $shippedEntries[[string]$k] = [string]$shipped['entries'][$k] }
    $shippedModules = @(@($shipped['modules']) | ForEach-Object { [pscustomobject]@{ name = [string]$_['name']; version = [string]$_['version']; source = [string]$_['source'] } })
    $derivedCanon = Get-IndexCanonical -Entries $derived.Entries -Modules $derived.Modules
    $shippedCanon = Get-IndexCanonical -Entries $shippedEntries -Modules $shippedModules
    if ($derivedCanon -eq $shippedCanon) {
        Write-Output ('OK: rulesets/command-module-index.psd1 matches the derivation (' + @($derived.Entries.Keys).Count + ' entries, ' + @($derived.Modules).Count + ' modules) from ' + [System.IO.Path]::GetFileName($sourcePath))
        exit 0
    }
    # Report the drift precisely (entry-level missing/extra + module-list diff).
    $dNames = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $derived.Entries.Keys) { [void]$dNames.Add([string]$n) }
    $sNames = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $shippedEntries.Keys) { [void]$sNames.Add([string]$n) }
    $missing = @($derived.Entries.Keys | Where-Object { -not $sNames.Contains([string]$_) } | Sort-Object)
    $extra = @($shippedEntries.Keys | Where-Object { -not $dNames.Contains([string]$_) } | Sort-Object)
    $remapped = @($derived.Entries.Keys | Where-Object { $sNames.Contains([string]$_) -and $shippedEntries[[string]$_] -ne $derived.Entries[[string]$_] } | Sort-Object)
    if ($missing.Count -gt 0) { Write-Output ('MISSING from shipped (derived, not shipped): ' + ($missing -join ', ')) }
    if ($extra.Count -gt 0) { Write-Output ('EXTRA in shipped (shipped, not derived): ' + ($extra -join ', ')) }
    if ($remapped.Count -gt 0) { Write-Output ('REMAPPED (module differs): ' + ($remapped -join ', ')) }
    if ($missing.Count -eq 0 -and $extra.Count -eq 0 -and $remapped.Count -eq 0) { Write-Output 'MODULE PROVENANCE list drifted (entries identical).' }
    [Console]::Error.WriteLine('regen-command-module-index: shipped command-module-index.psd1 DRIFTS from the derivation; re-run without -Check and review.')
    exit 1
}

# Default: (re)write the shipped index file.
$text = Format-IndexFile -Derived $derived
$enc = New-Object System.Text.UTF8Encoding($false)   # no BOM
[System.IO.File]::WriteAllText($shippedPath, $text, $enc)
Write-Output ('wrote ' + $shippedPath + ' (' + @($derived.Entries.Keys).Count + ' entries, ' + @($derived.Modules).Count + ' modules) from ' + [System.IO.Path]::GetFileName($sourcePath))
