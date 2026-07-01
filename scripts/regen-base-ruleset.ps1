#Requires -Version 5.1
[CmdletBinding()]
param(
    # Compare the DERIVED list against the shipped rulesets/base.psd1 instead of
    # printing it. Exit 0 when they match EXACTLY, 1 (with a diff) when they drift.
    [switch] $Check,
    # Explicit PSScriptAnalyzer module root or manifest to derive from. Empty =
    # auto-discover: the vendored module under CLAUDE_PLUGIN_DATA/modules first, then
    # any importable PSScriptAnalyzer at the pinned $PssaVersion.
    [string] $PssaPath = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# regen-base-ruleset.ps1 -- REGENERATE (or -Check) the enumerated rule list in
# rulesets/base.psd1 from the vendored PScriptAnalyzer pin (dispatch 000087). This makes
# the base ruleset's derivation EXECUTABLE and REPRODUCIBLE: the shipped file is the
# default-on rule set of the pinned PScriptAnalyzer MINUS the compatibility-profile family
# (PSUseCompatible*). When the $PssaVersion pin in ensure-pssa.ps1 is bumped, re-run this
# and review the diff -- a DELIBERATE regeneration, never a silent shift (the whole reason
# the base enumerates rather than using IncludeDefaultRules = $true).
#
# "default-on" = a rule PScriptAnalyzer evaluates with no settings file: a non-configurable
# rule, or a ConfigurableRule whose default `Enable` is $true (read here by reflecting the
# rule's ImplementingType). Formatting rules are ConfigurableRule with Enable = $false, so
# they are not default-on and are excluded automatically; the compatibility family is
# default-on-or-not but always dropped (it needs target-profile config).
#
# Silent-friendly: prints ONLY the rule list (default) or a PASS/FAIL line (-Check) so the
# output can be diffed. ASCII-only (PS 5.1 em-dash trap).
#
# Author: Mike Andersen / powershell-lsp plugin.

. (Join-Path $PSScriptRoot 'lib/lsp-common.ps1')

function Resolve-PssaManifest {
    param([string]$Explicit)
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) {
        if (Test-Path -LiteralPath $Explicit -PathType Leaf) { return $Explicit }
        $m = Get-ChildItem -LiteralPath $Explicit -Recurse -Filter 'PSScriptAnalyzer.psd1' -File -ErrorAction SilentlyContinue |
            Sort-Object { $_.FullName.Length } | Select-Object -First 1
        if ($null -ne $m) { return $m.FullName }
    }
    # Vendored copy under CLAUDE_PLUGIN_DATA/modules (the plugin's own acquisition path).
    $vendor = Get-PssaModuleDir
    if (Test-Path -LiteralPath $vendor) {
        $m = Get-ChildItem -LiteralPath $vendor -Recurse -Filter 'PSScriptAnalyzer.psd1' -File -ErrorAction SilentlyContinue |
            Sort-Object { $_.FullName.Length } | Select-Object -First 1
        if ($null -ne $m) { return $m.FullName }
    }
    # Any importable PSScriptAnalyzer at the pinned version.
    $pin = ''
    try {
        $ensure = Join-Path $PSScriptRoot 'ensure-pssa.ps1'
        $src = [System.IO.File]::ReadAllText($ensure)
        $rx = [regex]"\`$PssaVersion\s*=\s*'([^']+)'"
        $mm = $rx.Match($src); if ($mm.Success) { $pin = $mm.Groups[1].Value }
    } catch { }
    $mod = Get-Module -ListAvailable PSScriptAnalyzer |
        Where-Object { [string]::IsNullOrWhiteSpace($pin) -or $_.Version.ToString() -eq $pin } |
        Sort-Object Version -Descending | Select-Object -First 1
    if ($null -ne $mod) { return $mod.Path }
    throw 'could not locate a vendored or importable PSScriptAnalyzer to derive from.'
}

function Get-DerivedBaseRules {
    # The reproducible derivation: default-on rules minus the compatibility family.
    param([string]$ManifestPath)
    Import-Module $ManifestPath -Force -ErrorAction Stop
    $defaultOff = New-Object System.Collections.Generic.HashSet[string]
    foreach ($r in (Get-ScriptAnalyzerRule)) {
        $t = $r.ImplementingType
        $ep = if ($null -ne $t) { $t.GetProperty('Enable') } else { $null }
        if ($null -eq $ep) { continue }   # non-configurable -> always default-on
        try {
            if (-not [bool]$ep.GetValue([Activator]::CreateInstance($t))) { [void]$defaultOff.Add($r.RuleName) }
        } catch { }
    }
    $names = @(Get-ScriptAnalyzerRule | ForEach-Object { $_.RuleName } |
            Where-Object { -not $defaultOff.Contains($_) -and ($_ -notlike 'PSUseCompatible*') })
    return @($names | Sort-Object)
}

function Get-ShippedBaseRules {
    $baseFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'rulesets/base.psd1'
    if (-not (Test-Path -LiteralPath $baseFile -PathType Leaf)) { throw ('shipped base file not found: ' + $baseFile) }
    $data = Import-PowerShellDataFile -LiteralPath $baseFile
    if (-not $data.ContainsKey('IncludeRules')) { throw 'shipped base file has no IncludeRules key.' }
    return @(@($data['IncludeRules']) | Sort-Object)
}

$manifest = Resolve-PssaManifest -Explicit $PssaPath
$derived = Get-DerivedBaseRules -ManifestPath $manifest

if ($Check) {
    $shipped = Get-ShippedBaseRules
    $missing = @($derived | Where-Object { $_ -notin $shipped })   # derived but not shipped
    $extra = @($shipped | Where-Object { $_ -notin $derived })     # shipped but not derived
    if ($missing.Count -eq 0 -and $extra.Count -eq 0) {
        Write-Output ('OK: rulesets/base.psd1 matches the derivation (' + $derived.Count + ' rules) at ' + $manifest)
        exit 0
    }
    if ($missing.Count -gt 0) { Write-Output ('MISSING from shipped (derived, not shipped): ' + ($missing -join ', ')) }
    if ($extra.Count -gt 0) { Write-Output ('EXTRA in shipped (shipped, not derived): ' + ($extra -join ', ')) }
    [Console]::Error.WriteLine('regen-base-ruleset: shipped base.psd1 DRIFTS from the derivation; re-run without -Check and review.')
    exit 1
}

# Default: print the IncludeRules block, copy-paste-ready into rulesets/base.psd1.
Write-Output ('# derived from PSScriptAnalyzer at ' + $manifest + ' -- ' + $derived.Count + ' rules')
Write-Output '    IncludeRules = @('
foreach ($n in $derived) { Write-Output ("        '" + $n + "'") }
Write-Output '    )'
