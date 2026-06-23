#Requires -Version 5.1

# Release-engineering regression tests (Pester 5) for the gated release pipeline
# (dispatch 000042, Gap C.2 + Gap B). These prove the TESTABLE logic the release
# workflow depends on -- the CHANGELOG-to-notes extraction, the version lockstep the
# tag gate re-checks, and the CycloneDX SBOM generation -- WITHOUT triggering a real
# release. The parts that only prove out on a live release (the merged/green/tag-cut
# gates running on a GitHub runner) are documented in docs/RELEASING.md, not faked here.
#
# No network, no daemon: fast and cross-platform. Runs on all four CI legs.

BeforeAll {
    $script:PluginRoot = Split-Path -Parent $PSScriptRoot
    $script:ReleaseDir = Join-Path $script:PluginRoot 'release'
    $script:ScriptsDir = Join-Path $script:PluginRoot 'scripts'
    $script:GetEntry   = Join-Path $script:ReleaseDir 'Get-ChangelogEntry.ps1'
    $script:NewSbom    = Join-Path $script:ReleaseDir 'New-PluginSbom.ps1'

    $manifestPath = Join-Path $script:PluginRoot '.claude-plugin/plugin.json'
    $script:ManifestVersion = [string](((Get-Content -LiteralPath $manifestPath -Raw) | ConvertFrom-Json).version)

    # Read the dependency pins the SAME way the generator must -- the single-source
    # ground truth. If these regexes ever stop matching, the SBOM test below fails loud.
    function script:Read-Pin([string]$File, [string]$Var) {
        $src = [System.IO.File]::ReadAllText($File)
        $rx = [regex] ('\$' + [regex]::Escape($Var) + "\s*=\s*'([^']+)'")
        $m = $rx.Match($src)
        if (-not $m.Success) { throw "pin $Var not found in $File" }
        return $m.Groups[1].Value
    }
    $script:PsesTag    = script:Read-Pin (Join-Path $script:ScriptsDir 'ensure-pses.ps1') 'PsesTag'
    $script:PssaPin    = script:Read-Pin (Join-Path $script:ScriptsDir 'ensure-pssa.ps1') 'PssaVersion'

    # A deterministic fixture CHANGELOG for boundary-exact extraction assertions.
    $script:Fixture = Join-Path $TestDrive 'CHANGELOG.fixture.md'
    @(
        '# Changelog'
        ''
        '## Versioning'
        'Preamble that is not a release entry.'
        ''
        '## [2.0.0] - 2026-01-02'
        ''
        'MINOR: the second entry summary line.'
        ''
        '### Added'
        '- second-entry bullet'
        ''
        '## [1.0.0] - 2026-01-01'
        ''
        'PATCH: the first entry summary line.'
        ''
        '### Fixed'
        '- first-entry bullet'
        ''
    ) -join "`n" | Set-Content -LiteralPath $script:Fixture -Encoding ascii
}

Describe 'Get-ChangelogEntry.ps1 -- CHANGELOG-to-notes extraction (dispatch 000042)' {
    It 'extracts a middle entry body and STOPS at the next section header (boundary)' {
        $body = & $script:GetEntry -Version 2.0.0 -Path $script:Fixture
        $body | Should -Match 'the second entry summary line'
        $body | Should -Match 'second-entry bullet'
        # The boundary is the next '## ' heading: the older entry must NOT bleed in.
        $body | Should -Not -Match '1\.0\.0'
        $body | Should -Not -Match 'first-entry bullet'
        $body | Should -Not -Match '(?m)^##\s'
    }
    It 'extracts the LAST entry through end-of-file' {
        $body = & $script:GetEntry -Version 1.0.0 -Path $script:Fixture
        $body | Should -Match 'the first entry summary line'
        $body | Should -Match 'first-entry bullet'
    }
    It 'tolerates a leading v on the version argument' {
        $a = & $script:GetEntry -Version 2.0.0 -Path $script:Fixture
        $b = & $script:GetEntry -Version v2.0.0 -Path $script:Fixture
        $b | Should -BeExactly $a
    }
    It 'trims surrounding blank lines (no leading/trailing whitespace in the notes)' {
        $body = & $script:GetEntry -Version 2.0.0 -Path $script:Fixture
        $body | Should -BeExactly ($body.Trim())
    }
    It 'REFUSES (throws) a version with no entry -- you cannot release what you did not document' {
        { & $script:GetEntry -Version 9.9.9 -Path $script:Fixture } | Should -Throw
    }
    It 'REFUSES (throws) a malformed version' {
        { & $script:GetEntry -Version 'not-a-version' -Path $script:Fixture } | Should -Throw
    }
    It 'extracts the CURRENT manifest version from the REAL CHANGELOG (single-sourced, never stale)' {
        # Coupled to the manifest, not a literal: any future release that bumps the manifest
        # but forgets the CHANGELOG entry turns this RED.
        $body = & $script:GetEntry -Version $script:ManifestVersion
        $body | Should -Not -BeNullOrEmpty
        $body | Should -Match '^(PATCH|MINOR|MAJOR)'
    }
}

Describe 'New-PluginSbom.ps1 -- CycloneDX SBOM over the plugin + pinned deps (dispatch 000042)' {
    BeforeAll {
        $raw = & $script:NewSbom -Version $script:ManifestVersion -Timestamp '2026-01-01T00:00:00Z' -SerialNumber 'urn:uuid:test'
        $script:Sbom = $raw | ConvertFrom-Json
        $script:SbomRaw = $raw
    }
    It 'is a CycloneDX 1.5 document' {
        $script:Sbom.bomFormat | Should -BeExactly 'CycloneDX'
        $script:Sbom.specVersion | Should -BeExactly '1.5'
    }
    It 'names the plugin as the BOM subject, at the manifest version, under GPL-3.0-or-later' {
        $script:Sbom.metadata.component.name | Should -BeExactly 'powershell-lsp'
        $script:Sbom.metadata.component.version | Should -BeExactly $script:ManifestVersion
        $script:Sbom.metadata.component.licenses[0].license.id | Should -BeExactly 'GPL-3.0-or-later'
    }
    It 'inventories BOTH pinned downloaded dependencies' {
        $names = @($script:Sbom.components.name)
        $names | Should -Contain 'PowerShellEditorServices'
        $names | Should -Contain 'PSScriptAnalyzer'
    }
    It 'sources the PSES version from the LIVE ensure-pses.ps1 pin (single-sourced, not a literal)' {
        $pses = $script:Sbom.components | Where-Object { $_.name -eq 'PowerShellEditorServices' }
        # Pin is e.g. v4.6.0; the SBOM version field strips the leading v.
        $pses.version | Should -BeExactly ($script:PsesTag.TrimStart('v', 'V'))
        $pses.licenses[0].license.id | Should -BeExactly 'MIT'
    }
    It 'sources the PSScriptAnalyzer version from the LIVE ensure-pssa.ps1 pin (single-sourced)' {
        $pssa = $script:Sbom.components | Where-Object { $_.name -eq 'PSScriptAnalyzer' }
        $pssa.version | Should -BeExactly $script:PssaPin
        $pssa.licenses[0].license.id | Should -BeExactly 'MIT'
    }
    It 'gives every component a purl and a distribution externalReference' {
        foreach ($c in $script:Sbom.components) {
            $c.purl | Should -Not -BeNullOrEmpty
            @($c.externalReferences | Where-Object { $_.type -eq 'distribution' }).Count | Should -BeGreaterThan 0
        }
    }
    It 'emits ASCII-only JSON (PS 5.1 em-dash trap)' {
        (@([System.Text.Encoding]::UTF8.GetBytes($script:SbomRaw) | Where-Object { $_ -gt 127 }).Count) | Should -Be 0
    }
}

Describe 'Version lockstep -- the invariant the release tag-gate re-checks (dispatch 000042)' {
    # The release workflow refuses to tag unless plugin.json == marketplace.json == the
    # requested version. bump-version.ps1 keeps the two manifests in lockstep at bump time;
    # this guards that they ARE in lockstep on main, so the gate's version-match precondition
    # can hold. Adversarial control: hand-edit one manifest's version and this goes RED.
    It 'plugin.json and marketplace.json carry the SAME version' {
        $pluginV = [string](((Get-Content -LiteralPath (Join-Path $script:PluginRoot '.claude-plugin/plugin.json') -Raw) | ConvertFrom-Json).version)
        $marketV = [string](((Get-Content -LiteralPath (Join-Path $script:PluginRoot '.claude-plugin/marketplace.json') -Raw) | ConvertFrom-Json).metadata.version)
        $marketV | Should -BeExactly $pluginV
    }
}
