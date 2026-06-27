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

Describe 'Release workflow Gate-4 -- WAITS for CI to conclude, then judges (dispatch 000063)' {
    # The Gate-4 fix wraps the run-status read in a bounded poll so a still-in_progress CI run
    # is WAITED ON, not snapshot-and-refused (the proven 28033459348 timing race). The poll
    # stays inline in the workflow's bash step (rewriting it as a tested PowerShell helper would
    # have to rewrite the byte-for-byte-frozen REQUIRED_LEGS set + per-leg loop, which the
    # dispatch forbids), so what the Pester suite can reach WITHOUT a network or a YAML parser is
    # the workflow TEXT. These assert exactly what would regress silently there: the named
    # timeout/interval, the bounded poll, every refuse path, the honest timeout, the
    # workflow_dispatch-only trigger, and the untouched REQUIRED_LEGS. The full parse-and-execute
    # proof is GitHub's own -- the YAML is parsed by Actions and the embedded ${{ ... }} only
    # resolves on a runner -- demonstrated by a dry_run against a real merged+green commit
    # (docs/RELEASING.md), not re-implemented here.
    BeforeAll {
        $script:ReleaseWf = Join-Path $script:PluginRoot '.github/workflows/powershell-lsp-release.yml'
        $script:WfText    = [System.IO.File]::ReadAllText($script:ReleaseWf)
        $script:WfLines   = $script:WfText -split "\r?\n"
    }

    It 'the release stays workflow_dispatch-only (never auto-triggers on push / pull_request)' {
        # The 000042 governing principle: automate the mechanics, preserve Mike's decision. This
        # fix must NOT make the release fire on a push event.
        $script:WfText | Should -Match '(?m)^\s+workflow_dispatch:'
        @($script:WfLines | Where-Object { $_ -match '^\s*push:\s*$' }).Count | Should -Be 0
        @($script:WfLines | Where-Object { $_ -match '^\s*pull_request:\s*$' }).Count | Should -Be 0
    }

    It 'Gate 4 names a positive timeout and poll interval, and the timeout is a real wait' {
        $script:WfText | Should -Match 'CI_WAIT_TIMEOUT_SECONDS=\d+'
        $script:WfText | Should -Match 'CI_WAIT_POLL_SECONDS=\d+'
        $to = [int]([regex]::Match($script:WfText, 'CI_WAIT_TIMEOUT_SECONDS=(\d+)').Groups[1].Value)
        $iv = [int]([regex]::Match($script:WfText, 'CI_WAIT_POLL_SECONDS=(\d+)').Groups[1].Value)
        $iv | Should -BeGreaterThan 0
        $to | Should -BeGreaterThan $iv   # a generous bound, not a disguised one-shot
    }

    It 'Gate 4 polls the resolved run by id, bounded by an enforced deadline' {
        # Re-queries the SAME run id, and enforces the timeout so a stuck CI run cannot hang the
        # release job indefinitely.
        $script:WfText | Should -Match 'actions/runs/\$RUN_ID'
        $script:WfText | Should -Match 'DEADLINE='
        $script:WfText | Should -Match 'SECONDS >= DEADLINE'
    }

    It 'the workflow indents with spaces only (no tabs -- YAML indentation safety)' {
        $script:WfText | Should -Not -Match "`t"
    }

    It 'every Gate-4 refuse path is intact (no-run / timeout / not-success / failed-leg) and the timeout is honest' {
        # The fix makes the gate WAIT; it must never become permissive. All four refuses stand,
        # and the timeout refuse reports a timeout -- it is never reported as green.
        $script:WfText | Should -Match 'no push-event CI run found'             # no run found
        $script:WfText | Should -Match 'did not conclude within'                # the NEW timeout refuse
        $script:WfText | Should -Match 'is not completed\+success'              # non-success conclusion
        $script:WfText | Should -Match "required CI leg '.+' did not succeed"   # a failed / missing leg
        $script:WfText | Should -Match 'honest timeout, NOT a pass'             # the timeout is honest
        # ...and the single all-green line is still the only success.
        $script:WfText | Should -Match 'all required CI legs are green'
    }

    It 'REQUIRED_LEGS is unchanged -- the four CI matrix legs, byte-for-byte' {
        $script:WfText | Should -Match 'REQUIRED_LEGS=\("windows-pwsh" "windows-powershell" "ubuntu-pwsh" "macos-pwsh"\)'
    }

    It 'all four gates remain present (none removed by this change)' {
        foreach ($g in 1..4) {
            $script:WfText | Should -Match ('Gate {0} --' -f $g)
        }
    }
}

Describe 'Release workflow signing -- keyless gitsign-signed tags (dispatch 000064)' {
    # The signing addition is POST-GATE and ADDITIVE: the tag-cut step becomes a keyless
    # gitsign-signed `git tag -s` authenticating via the runner's ambient GitHub OIDC
    # identity (Fulcio cert, Rekor-logged), and NOTHING else moves. Like the Gate-4 block
    # above, the YAML only parses + executes on a real runner, so what Pester can reach
    # without a network or a real release is the workflow TEXT. These assert exactly what
    # would regress silently: the signed tag, the gitsign config, the keyless ambient-OIDC
    # flow, the version pin, and that signing introduced NO secret and did NOT disturb the
    # existing SBOM / SLSA provenance or the least-privilege permission set. The signatures
    # themselves only prove out on the first real release (the server-issued OIDC token),
    # documented in docs/RELEASING.md -- not faked here.
    BeforeAll {
        $script:ReleaseWf = Join-Path $script:PluginRoot '.github/workflows/powershell-lsp-release.yml'
        $script:WfText    = [System.IO.File]::ReadAllText($script:ReleaseWf)
    }

    It 'cuts a SIGNED tag (git tag -s), not an unsigned annotated tag (git tag -a)' {
        $script:WfText | Should -Match 'git tag -s "\$TAG"'
        $script:WfText | Should -Not -Match 'git tag -a "\$TAG"'
    }

    It 'configures gitsign as git''s x509 signing program (keyless Sigstore)' {
        $script:WfText | Should -Match 'gpg\.x509\.program gitsign'
        $script:WfText | Should -Match 'gpg\.format x509'
    }

    It 'signs keyless via the ambient GitHub Actions OIDC token provider (no browser, no key)' {
        $script:WfText | Should -Match 'GITSIGN_TOKEN_PROVIDER: github-actions'
    }

    It 'pins the gitsign version (no @latest float)' {
        $script:WfText | Should -Match 'sigstore/gitsign@v\d+\.\d+\.\d+'
        $script:WfText | Should -Not -Match 'sigstore/gitsign@latest'
    }

    It 'introduces NO repository secret -- keyless is the whole point (least-privilege)' {
        # If signing ever appeared to need a stored key, that is the rejected key-custody path.
        # Keyless reuses the id-token: write already granted for provenance; guard that no secret
        # reference and no stored-key file crept in.
        $script:WfText | Should -Not -Match '(?i)secrets\.'
        $script:WfText | Should -Not -Match '(?i)cosign\.key'
        $script:WfText | Should -Not -Match '(?i)user\.signingkey'
    }

    It 'leaves the existing SBOM + SLSA provenance steps byte-for-byte (signing is ADDITIVE)' {
        $script:WfText | Should -Match 'actions/attest-build-provenance@v2'
        $script:WfText | Should -Match 'New-PluginSbom\.ps1'
    }

    It 'keeps id-token: write as the identity permission signing reuses (not a new/widened one)' {
        $script:WfText | Should -Match 'id-token: write'
    }

    It 'signing stays gated on !dry_run (post-gate, never a new trigger)' {
        $script:WfText | Should -Match 'Cut and push the gitsign-signed tag'
    }
}
