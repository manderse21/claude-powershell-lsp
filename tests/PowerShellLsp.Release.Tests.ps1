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
    It 'names the plugin as the BOM subject, at the manifest version, under Apache-2.0' {
        $script:Sbom.metadata.component.name | Should -BeExactly 'powershell-lsp'
        $script:Sbom.metadata.component.version | Should -BeExactly $script:ManifestVersion
        # Relicensed forward GPL-3.0-or-later -> Apache-2.0 by dispatch 000247. The SBOM reads the id
        # from plugin.json rather than carrying a literal, so this asserts the manifest is the single
        # source of truth AND that the emitted value is the one the relicense landed.
        $script:Sbom.metadata.component.licenses[0].license.id | Should -BeExactly 'Apache-2.0'
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

Describe 'Test-PublishedParity.ps1 -- tree-vs-published divergence guard (dispatch 000076)' {
    # The guard FAILS when the published version (the .claude-plugin/plugin.json version on the
    # default-branch tip the marketplace resolves -- source "./", no ref pin) LAGS the tree
    # version. It exists to prevent the silent drift that served a stale 1.3.0 while the tree was
    # 1.18.x. Pure version logic: no network, fixtures only (runs on all four CI legs).
    BeforeAll {
        $script:Parity = Join-Path $script:ReleaseDir 'Test-PublishedParity.ps1'

        # Minimal manifests carrying only the "version" the guard reads -- exactly the field the
        # marketplace resolves from the default-branch manifest.
        function script:New-VersionManifest([string]$Version) {
            $p = Join-Path $TestDrive ("plugin-" + $Version + ".json")
            ('{ "version": "' + $Version + '" }') | Set-Content -LiteralPath $p -Encoding ascii
            return $p
        }
        $script:Tree1181 = script:New-VersionManifest '1.18.1'
        $script:Pub130   = script:New-VersionManifest '1.3.0'
        $script:Pub1190  = script:New-VersionManifest '1.19.0'
    }

    It 'PASSES when published == tree (parity -- the post-publish steady state)' {
        { & $script:Parity -TreeManifest $script:Tree1181 -PublishedManifest $script:Tree1181 } | Should -Not -Throw
    }
    It 'PASSES when published is AHEAD of tree (a newer release already out)' {
        { & $script:Parity -TreeManifest $script:Tree1181 -PublishedManifest $script:Pub1190 } | Should -Not -Throw
    }
    It 'FAILS (throws) when published LAGS tree -- the 1.3.0-vs-1.18.x drift this guard exists to catch' {
        { & $script:Parity -TreeManifest $script:Tree1181 -PublishedManifest $script:Pub130 } |
            Should -Throw -ExpectedMessage '*DIVERGENCE*1.3.0*1.18.1*'
    }
    It 'accepts an explicit -PublishedVersion (the CI-passes-a-resolved-value path), both directions' {
        { & $script:Parity -TreeManifest $script:Tree1181 -PublishedVersion '1.18.1' } | Should -Not -Throw
        { & $script:Parity -TreeManifest $script:Tree1181 -PublishedVersion '1.3.0' }  | Should -Throw
    }
    It 'SAFE-FAILS (throws) on a published manifest with no version field -- refuse, never pass' {
        $bad = Join-Path $TestDrive 'no-version.json'
        '{ "name": "x" }' | Set-Content -LiteralPath $bad -Encoding ascii
        { & $script:Parity -TreeManifest $script:Tree1181 -PublishedManifest $bad } | Should -Throw
    }
    It 'SAFE-FAILS (throws) on a non-semver published version -- refuse, never pass' {
        { & $script:Parity -TreeManifest $script:Tree1181 -PublishedVersion 'latest' } | Should -Throw
    }
    It 'holds self-parity on the REAL shipped manifest (couples to the live tree, not a literal)' {
        $real = Join-Path $script:PluginRoot '.claude-plugin/plugin.json'
        { & $script:Parity -TreeManifest $real -PublishedManifest $real } | Should -Not -Throw
    }
    It 'is wired into the release workflow as a parity gate (build on 000042, not a rebuild)' {
        $wf = [System.IO.File]::ReadAllText((Join-Path $script:PluginRoot '.github/workflows/powershell-lsp-release.yml'))
        $wf | Should -Match 'Gate 5 --'
        $wf | Should -Match 'Test-PublishedParity\.ps1'
    }
    It 'is ASCII-only (PS 5.1 em-dash trap)' {
        $bytes = [System.IO.File]::ReadAllBytes($script:Parity)
        (@($bytes | Where-Object { $_ -gt 127 }).Count) | Should -Be 0
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

        # THE PROVENANCE GUARD, AS A FAMILY INVARIANT (dispatch 000240).
        #
        # This assertion used to read `Should -Match 'actions/attest-build-provenance@v3'`.
        # That wrote down today's ANSWER instead of the property: a clean Dependabot major
        # bump (@v3 -> @v4, one file, one line) failed a STRUCTURAL release test although
        # nothing structural had broken, and "fixing" it by typing @v4 would reproduce the
        # same failure the day v5 landed. The job of this guard is to say the provenance
        # action is PINNED, not to say what it is pinned to.
        #
        # The idiom is the one the gitsign It fourteen lines below already established --
        # a version-family positive PLUS an explicit floating-ref negative -- carried across
        # at the granularity this action is actually referenced with.
        #
        # TWO axes are deliberately NOT encoded here:
        #   * the VERSION. Any explicit numbered release satisfies the positive.
        #   * the ACTION NAME. Upstream made attest-build-provenance@v4 a thin composite
        #     wrapper around actions/attest and recommends actions/attest for new work, so
        #     this repository calls actions/attest directly. Hard-coding either name would
        #     be the same defect one level up, so the alternation accepts both.
        #
        # What IS encoded is the property the repository actually commits to: an immutable
        # 40-character upstream commit SHA with a human-readable release comment beside it
        # (the repository-wide rule, mechanically enforced across every workflow by
        # tests/PowerShellLsp.ActionPinning.Tests.ps1).
        $script:ProvenancePositive = 'actions/attest(-build-provenance)?@[0-9a-f]{40}\s+#\s*v\d+(\.\d+)*'

        # WHY THE NEGATIVE IS NOT REDUNDANT WITH THE POSITIVE. The positive proves only that
        # SOME correctly pinned reference exists somewhere in the file. A workflow carrying
        # BOTH a pinned reference and an added floating one would satisfy it and still be
        # exposed to an upstream retag. The negative is what makes the policy total, which
        # is exactly why the gitsign It carries both halves.
        $script:ProvenanceFloating = 'actions/attest(-build-provenance)?@(latest|main|master|HEAD|v\d)'
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

    It 'leaves the SBOM + SLSA provenance path undisturbed, with the provenance action immutably pinned (signing is ADDITIVE)' {
        # The It's purpose is unchanged -- signing did not disturb the SBOM / provenance
        # path -- and both halves are still asserted. Only the provenance half stopped
        # encoding which dependency version happens to be current. The title now says
        # "immutably pinned" because that is what the assertion below actually proves.
        $script:WfText | Should -Match $script:ProvenancePositive
        $script:WfText | Should -Not -Match $script:ProvenanceFloating
        $script:WfText | Should -Match 'New-PluginSbom\.ps1'
    }

    It 'the provenance guard is a VERSION FAMILY, not a value: it accepts any numbered release of either upstream action name' {
        # Acceptance evidence for the repair. Accepting only whichever release is current
        # would prove nothing about the coupling being gone, so this exercises several --
        # spanning the major this repository used to pin, the one it pins now, and one that
        # does not exist yet -- under BOTH upstream action names.
        foreach ($name in @('actions/attest-build-provenance', 'actions/attest')) {
            foreach ($ver in @('v3', 'v3.2.0', 'v4', 'v4.2.2', 'v5.0.0', 'v10.11.12')) {
                $synthetic = "        uses: ${name}@0123456789abcdef0123456789abcdef01234567 # $ver"
                $synthetic | Should -Match $script:ProvenancePositive -Because "a $ver pin of $name must satisfy the family invariant"
                $synthetic | Should -Not -Match $script:ProvenanceFloating -Because "a $ver SHA pin of $name is not a floating ref"
            }
        }
    }

    It 'records the defect this repair removed: the OLD exact-major assertion goes RED on a legitimate bump' {
        # The measured RED, kept executable rather than described. The retired assertion was
        # `Should -Match 'actions/attest-build-provenance@v3'`; a clean v3 -> v4 Dependabot
        # bump does not satisfy it, which is precisely why PR #158 failed a structural test
        # while changing nothing structural.
        $legitimateBump = '        uses: actions/attest-build-provenance@v4'
        $legitimateBump | Should -Not -Match 'actions/attest-build-provenance@v3' -Because 'this is the coupling defect: a clean major bump fails the old literal guard'
        # And the same line is still correctly REJECTED by the replacement, because a major
        # tag is movable -- the repair widened the version family, it did not weaken the pin.
        $legitimateBump | Should -Not -Match $script:ProvenancePositive
        $legitimateBump | Should -Match $script:ProvenanceFloating
    }

    It 'the provenance guard is NOT vacuous: an in-memory copy with the step removed FAILS it' {
        # Anti-vacuity, EXECUTED. Mutate a copy of the workflow text -- never the file -- and
        # prove the positive stops matching. Without this, a guard that had been weakened
        # into something a provenance-free workflow would satisfy could not be told apart
        # from a guard that works.
        $stripped = [regex]::Replace($script:WfText, 'actions/attest(-build-provenance)?@[0-9a-f]{40}\s+#\s*v\d+(\.\d+)*', 'echo no-provenance-step-here')
        $stripped | Should -Not -Match $script:ProvenancePositive -Because 'removing the provenance reference must break the positive guard'

        # The floating-ref negative is independently non-vacuous: swap the pin for a float
        # and the negative must fire.
        $floated = [regex]::Replace($script:WfText, 'actions/attest@[0-9a-f]{40}', 'actions/attest@main')
        $floated | Should -Match $script:ProvenanceFloating -Because 'a floating provenance ref must be caught by the negative'

        # And the SBOM half of the It above is non-vacuous too.
        $sbomless = $script:WfText -replace 'New-PluginSbom\.ps1', 'New-SomeOtherThing.ps1'
        $sbomless | Should -Not -Match 'New-PluginSbom\.ps1'
    }

    It 'keeps id-token: write as the identity permission signing reuses (not a new/widened one)' {
        $script:WfText | Should -Match 'id-token: write'
    }

    It 'signing stays gated on !dry_run (post-gate, never a new trigger)' {
        $script:WfText | Should -Match 'Cut and push the gitsign-signed tag'
    }
}

Describe 'Test-DryRunPair.ps1 -- the dry-run-pair decision (dispatch 000197 leg 6)' {
    # WHAT THIS GUARDS. docs/RELEASING.md always described the release as a PAIR -- rehearse with
    # dry_run=true, then cut -- and nothing refused a producing run that skipped the rehearsal.
    # v1.29.0 shipped with no dry run at all and only a later true-up dispatch noticed. Gate 6
    # makes the pair structural; this block proves the DECISION half of it against synthetic run
    # sets, with no network, so every refuse path is exercised without cutting a release.
    #
    # The live half -- the gate actually running on a GitHub runner -- is PENDING BY CONSTRUCTION:
    # it first exercises on the next real cut, and this train deliberately triggered no release run.

    BeforeAll {
        $script:PairScript = Join-Path $script:ReleaseDir 'Test-DryRunPair.ps1'
        $script:PairWf = Join-Path $script:PluginRoot '.github/workflows/powershell-lsp-release.yml'
        $script:PairWfText = [System.IO.File]::ReadAllText($script:PairWf)
        $script:TargetSha = 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678'
        $script:OtherSha = '00112233445566778899aabbccddeeff00112233'
        $script:NowIso = '2026-08-06T12:00:00Z'

        # The host that runs the script under test. Using the CURRENT host means the 5.1 CI leg
        # exercises the script under 5.1 (it is #Requires -Version 5.1) rather than silently
        # testing pwsh twice. Spawning rather than dot-sourcing is required: the script signals
        # its verdict with `exit`, which would terminate the test host.
        $script:PairHost = try { (Get-Process -Id $PID).Path } catch { '' }
        if ([string]::IsNullOrWhiteSpace($script:PairHost)) { $script:PairHost = 'pwsh' }

        function script:Invoke-Pair {
            param([object[]] $Runs, [string] $Target = $script:TargetSha, [int] $WindowDays = 3)
            $path = Join-Path $TestDrive ('runs-' + [guid]::NewGuid().ToString('N') + '.json')
            # Built by hand rather than with ConvertTo-Json -AsArray: -AsArray is PowerShell 6+ and
            # this suite runs on the windows-powershell 5.1 leg too. This form also yields a real
            # '[]' for the empty case, where an empty pipeline would have written no file at all.
            $json = '[' + ((@($Runs) | ForEach-Object { $_ | ConvertTo-Json -Depth 6 -Compress }) -join ',') + ']'
            [System.IO.File]::WriteAllText($path, $json)
            $out = (& $script:PairHost -NoLogo -NoProfile -File $script:PairScript `
                    -RunsJsonPath $path -TargetCommit $Target -WindowDays $WindowDays `
                    -NowUtc $script:NowIso 2>&1 | Out-String -Width 500)
            return [pscustomobject]@{
                ExitCode = $LASTEXITCODE
                Out      = $out
                Norm     = ([regex]::Replace([string]$out, '\s+', ' ')).Trim()
            }
        }

        function script:New-Run {
            param(
                [string] $Id = '1001',
                [string] $Title = '',
                [string] $HeadSha = $script:TargetSha,
                [string] $Conclusion = 'success',
                [string] $CreatedAt = '2026-08-06T09:00:00Z'
            )
            return [ordered]@{
                id            = $Id
                display_title = $Title
                head_sha      = $HeadSha
                conclusion    = $Conclusion
                created_at    = $CreatedAt
                status        = 'completed'
            }
        }
    }

    It 'PASSES when a successful marked DRY RUN targets the same commit inside the window' {
        $r = Invoke-Pair -Runs @(
            (New-Run -Id '1001' -Title ('powershell-lsp release 1.30.0 [DRY-RUN] target=' + $script:TargetSha))
        )
        $r.ExitCode | Should -Be 0
        $r.Norm | Should -Match 'the dry-run pair is satisfied'
        $r.Norm | Should -Match 'MATCHED a successful dry run'
    }

    It 'REFUSES when the only runs are PRODUCING runs (the v1.29.0 shape)' {
        $r = Invoke-Pair -Runs @(
            (New-Run -Id '1001' -Title ('powershell-lsp release 1.30.0 [PRODUCING] target=' + $script:TargetSha))
        )
        $r.ExitCode | Should -Be 1
        $r.Norm | Should -Match 'was a PRODUCING run, not a dry run'
        $r.Norm | Should -Match 'refusing to produce a release that was never rehearsed'
    }

    It 'REFUSES a dry run aimed at a DIFFERENT commit -- commit identity is the primary guard' {
        $r = Invoke-Pair -Runs @(
            (New-Run -Id '1001' -HeadSha $script:OtherSha `
                    -Title ('powershell-lsp release 1.30.0 [DRY-RUN] target=' + $script:OtherSha))
        )
        $r.ExitCode | Should -Be 1
        $r.Norm | Should -Match 'dry run targeted .* not '
    }

    It 'REFUSES a dry run older than the window' {
        $r = Invoke-Pair -Runs @(
            (New-Run -Id '1001' -CreatedAt '2026-07-20T09:00:00Z' `
                    -Title ('powershell-lsp release 1.30.0 [DRY-RUN] target=' + $script:TargetSha))
        )
        $r.ExitCode | Should -Be 1
        $r.Norm | Should -Match 'OUTSIDE the 3-day window'
    }

    It 'REFUSES a FAILED dry run -- a failed rehearsal is not a rehearsal' {
        $r = Invoke-Pair -Runs @(
            (New-Run -Id '1001' -Conclusion 'failure' `
                    -Title ('powershell-lsp release 1.30.0 [DRY-RUN] target=' + $script:TargetSha))
        )
        $r.ExitCode | Should -Be 1
        $r.Norm | Should -Match 'a failed rehearsal is not a rehearsal'
    }

    It 'REFUSES an UNMARKED run with no legacy verdict -- an unproven rehearsal is not a rehearsal' {
        # The pre-change-history case with no step evidence: it must NOT be assumed to be a dry run.
        $r = Invoke-Pair -Runs @((New-Run -Id '1001' -Title 'powershell-lsp release'))
        $r.ExitCode | Should -Be 1
        $r.Norm | Should -Match 'NOT DISCRIMINABLE'
    }

    It 'LEGACY FALLBACK: an unmarked run classified by step inspection as a dry run PASSES' {
        # The 000169 method: the caller determined dry-ness from the "Dry-run summary" step
        # conclusion and passed the verdict in. This is how pre-marker history stays usable.
        $run = New-Run -Id '1001' -Title 'powershell-lsp release'
        $run['legacyIsDryRun'] = $true
        $r = Invoke-Pair -Runs @($run)
        $r.ExitCode | Should -Be 0
        $r.Norm | Should -Match 'the dry-run pair is satisfied'
    }

    It 'LEGACY FALLBACK: an unmarked run classified as PRODUCING is refused' {
        $run = New-Run -Id '1001' -Title 'powershell-lsp release'
        $run['legacyIsDryRun'] = $false
        $r = Invoke-Pair -Runs @($run)
        $r.ExitCode | Should -Be 1
        $r.Norm | Should -Match 'was a PRODUCING run, not a dry run'
    }

    It 'target=HEAD (a blank commit input) matches on the run head_sha instead' {
        $r = Invoke-Pair -Runs @(
            (New-Run -Id '1001' -HeadSha $script:TargetSha -Title 'powershell-lsp release 1.30.0 [DRY-RUN] target=HEAD')
        )
        $r.ExitCode | Should -Be 0
        $r.Norm | Should -Match 'the dry-run pair is satisfied'
    }

    It 'target=HEAD does NOT match when the run head_sha is a different commit' {
        # The control for the test above: the HEAD path must still be commit-checked, not a wildcard.
        $r = Invoke-Pair -Runs @(
            (New-Run -Id '1001' -HeadSha $script:OtherSha -Title 'powershell-lsp release 1.30.0 [DRY-RUN] target=HEAD')
        )
        $r.ExitCode | Should -Be 1
    }

    It 'picks the matching dry run out of a MIXED set (not merely the newest run)' {
        $r = Invoke-Pair -Runs @(
            (New-Run -Id '1003' -Title ('powershell-lsp release 1.30.0 [PRODUCING] target=' + $script:TargetSha)),
            (New-Run -Id '1002' -HeadSha $script:OtherSha `
                    -Title ('powershell-lsp release 1.30.0 [DRY-RUN] target=' + $script:OtherSha)),
            (New-Run -Id '1001' -Title ('powershell-lsp release 1.30.0 [DRY-RUN] target=' + $script:TargetSha))
        )
        $r.ExitCode | Should -Be 0
        $r.Norm | Should -Match 'run id : 1001'
    }

    It 'pairs a same-commit rehearsal sitting BEYOND the former 20-run window (dispatch 000217)' {
        # THE REGRESSION THIS PINS. Gate 6 used to attach legacy verdicts to only the newest 20
        # unmarked runs, so a genuine rehearsal further back stayed UNKNOWN and could not satisfy
        # the gate -- not because anything was wrong with it, but because unrelated runs had
        # accumulated in front of it. The v1.30.0 cut announced that at 45 unmarked runs. The fix
        # selects what to inspect by TARGET COMMIT, so depth in the list stops mattering.
        #
        # The selection rule is DERIVED FROM THE WORKFLOW rather than assumed, which is what makes
        # this a regression test instead of a restatement: it is RED against the recency-capped
        # workflow and GREEN against commit-identity selection, rather than passing under both.
        $capMatch = [regex]::Match($script:PairWfText, 'LEGACY_CAP=(\d+)')
        $selection = [regex]::Match($script:PairWfText, '(?s)NEEDS_LEGACY="\$\(.*?\)"')
        $selection.Success | Should -BeTrue -Because 'the rule must be findable to be derived from'
        $commitScoped = ($selection.Value -match 'head_sha') -and (-not $capMatch.Success)

        $runs = @()
        for ($i = 0; $i -lt 44; $i++) {
            $runs += (New-Run -Id ('90{0:d2}' -f $i) -Title 'powershell-lsp release' -HeadSha $script:OtherSha)
        }
        $runs += (New-Run -Id '1001' -Title 'powershell-lsp release' -HeadSha $script:TargetSha)
        $runs.Count | Should -Be 45 -Because 'the paired rehearsal must sit beyond the former cap of 20'

        # Attach legacy verdicts exactly as the workflow's CURRENT rule would produce them.
        if ($commitScoped) {
            foreach ($run in $runs) {
                if ($run['head_sha'] -eq $script:TargetSha) { $run['legacyIsDryRun'] = $true }
            }
        } else {
            # The capped rule, granted every benefit of the doubt: classify the newest N as dry
            # runs. It still cannot pair, because those N are all on other commits and the one
            # rehearsal that matches sits at position 45, beyond the cap, forever unclassified.
            $cap = [int]$capMatch.Groups[1].Value
            for ($i = 0; $i -lt [Math]::Min($cap, $runs.Count); $i++) {
                $runs[$i]['legacyIsDryRun'] = $true
            }
        }

        $r = Invoke-Pair -Runs $runs
        $r.ExitCode | Should -Be 0 -Because 'a genuine same-commit rehearsal must pair however many runs came after it'
        $r.Norm | Should -Match 'run id : 1001'
        $r.Norm | Should -Match 'the dry-run pair is satisfied'
    }

    It 'depth alone never pairs an off-commit rehearsal -- the 000217 control' {
        # The control for the test above. Removing the cap must not turn "classify more runs" into
        # "accept more runs": a rehearsal on a DIFFERENT commit stays refused however deep the list
        # is and however generously the caller classified it.
        $all = @()
        for ($i = 0; $i -lt 44; $i++) {
            $run = New-Run -Id ('80{0:d2}' -f $i) -Title 'powershell-lsp release' -HeadSha $script:OtherSha
            $run['legacyIsDryRun'] = $true
            $all += $run
        }
        $r = Invoke-Pair -Runs $all
        $r.ExitCode | Should -Be 1 -Because 'commit identity is the guard the cap removal must not weaken'
        $r.Norm | Should -Match 'dry run targeted .* not '
    }

    It 'SAFE-FAILS on an empty or missing runs file -- refuse, never pass' {
        # "No data" must never read as "no problem".
        # Both refusals below are `throw`s, so their text arrives on STDERR. $ErrorActionPreference is
        # neutralized around the two native calls because Windows PowerShell 5.1 promotes a redirected
        # native stderr line to a TERMINATING error under 'Stop' (pwsh 7 does not), and tests/run-tests.ps1
        # -- the runner CI uses -- sets 'Stop'. Same reason as the SarifScan diag-line test. The captured
        # text and both assertions are unchanged; only the capture is made host-independent.
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $empty = Join-Path $TestDrive 'empty.json'
            [System.IO.File]::WriteAllText($empty, '')
            $out = (& $script:PairHost -NoLogo -NoProfile -File $script:PairScript -RunsJsonPath $empty `
                    -TargetCommit $script:TargetSha 2>&1 | Out-String -Width 500)
            $LASTEXITCODE | Should -Not -Be 0
            $out | Should -Match 'is empty'

            $missing = Join-Path $TestDrive 'does-not-exist.json'
            $out2 = (& $script:PairHost -NoLogo -NoProfile -File $script:PairScript -RunsJsonPath $missing `
                    -TargetCommit $script:TargetSha 2>&1 | Out-String -Width 500)
            $LASTEXITCODE | Should -Not -Be 0
            $out2 | Should -Match 'not found'
        } finally {
            $ErrorActionPreference = $prevEap
        }
    }

    It 'REFUSES an empty run list, and says so rather than passing vacuously' {
        $r = Invoke-Pair -Runs @()
        $r.ExitCode | Should -Be 1
        $r.Norm | Should -Match 'no candidate runs at all'
    }

    It 'is ASCII-only (PS 5.1 em-dash trap)' {
        $bytes = [System.IO.File]::ReadAllBytes($script:PairScript)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
}

Describe 'Release workflow Gate 6 -- the dry-run pair is STRUCTURAL (dispatch 000197 leg 6)' {
    BeforeAll {
        $script:G6Wf = Join-Path $script:PluginRoot '.github/workflows/powershell-lsp-release.yml'
        $script:G6Text = [System.IO.File]::ReadAllText($script:G6Wf)
        $script:G6Pair = Join-Path $script:ReleaseDir 'Test-DryRunPair.ps1'
        $script:G6PairText = [System.IO.File]::ReadAllText($script:G6Pair)
    }

    It 'the run-name encodes dry_run STRUCTURALLY, plus the version and the target commit' {
        # This is the whole mechanism: dry_run is an INPUT and inputs do not appear on a run object,
        # which is why 000161 and 000169 could only recover it from run STEPS. GitHub documents the
        # `inputs` context as available to run-name, so encoding it there makes it a property of the
        # run itself.
        $script:G6Text | Should -Match '(?m)^run-name:'
        $script:G6Text | Should -Match "inputs\.dry_run && '\[DRY-RUN\]' \|\| '\[PRODUCING\]'"
        $script:G6Text | Should -Match "target=\$\{\{ inputs\.commit \|\| 'HEAD' \}\}"
    }

    It 'the workflow run-name markers and the script markers AGREE (they cannot drift silently)' {
        # The cross-file contract. If either side is renamed alone, the gate silently stops
        # recognizing its own dry runs -- which would fail OPEN on the legacy path or refuse every
        # release. Assert both literals in both files.
        foreach ($marker in @('\[DRY-RUN\]', '\[PRODUCING\]')) {
            $script:G6Text | Should -Match $marker
            $script:G6PairText | Should -Match $marker
        }
        $script:G6PairText | Should -Match "DryRunMarker = '\[DRY-RUN\]'"
        $script:G6PairText | Should -Match "ProducingMarker = '\[PRODUCING\]'"
    }

    It 'Gate 6 exists, runs ONLY on producing runs, and delegates to the tested script' {
        $script:G6Text | Should -Match 'Gate 6 --'
        $script:G6Text | Should -Match 'release/Test-DryRunPair\.ps1'
        # The gate step is if-guarded on !inputs.dry_run: a rehearsal must not demand a rehearsal.
        $gateIdx = $script:G6Text.IndexOf('Gate 6 --')
        $gateIdx | Should -BeGreaterThan 0
        $window = $script:G6Text.Substring($gateIdx, [Math]::Min(400, $script:G6Text.Length - $gateIdx))
        $window | Should -Match 'if: \$\{\{ !inputs\.dry_run \}\}'
    }

    It 'the recency window is named, bounded to the chartered 1-7 days, and justified in the echo' {
        $script:G6Text | Should -Match 'WINDOW_DAYS=\d+'
        $w = [int]([regex]::Match($script:G6Text, 'WINDOW_DAYS=(\d+)').Groups[1].Value)
        $w | Should -BeGreaterOrEqual 1
        $w | Should -BeLessOrEqual 7
        # The justification must be IN the gate, not only in a commit message.
        $script:G6Text | Should -Match 'COMMIT IDENTITY'
    }

    It 'skip_dry_check is a declared boolean input defaulting to FALSE' {
        $script:G6Text | Should -Match '(?m)^\s+skip_dry_check:'
        $idx = $script:G6Text.IndexOf('skip_dry_check:')
        $block = $script:G6Text.Substring($idx, [Math]::Min(400, $script:G6Text.Length - $idx))
        $block | Should -Match 'type: boolean'
        $block | Should -Match 'default: false'
        $block | Should -Match 'RECORDED run parameter'
    }

    It 'the skip path is LOUD and passes; it never silently disables the gate' {
        $script:G6Text | Should -Match 'SKIPPED-BY-INPUT'
        $script:G6Text | Should -Match '::warning::Gate 6 SKIPPED-BY-INPUT'
        $script:G6Text | Should -Match 'GATE 6 SKIPPED BY INPUT'
    }

    It 'the legacy fallback selects the REAL Dry-run summary step name, byte-for-byte' {
        # The pre-change-history path (000169's method) matches a step by exact name. If that step
        # is ever renamed, this coupling fails here rather than silently classifying every legacy
        # run as UNKNOWN.
        $stepName = 'Dry-run summary (no tag cut, no release created)'
        $script:G6Text | Should -Match ([regex]::Escape('- name: ' + $stepName))
        $script:G6Text | Should -Match ([regex]::Escape('select(.name == "' + $stepName + '")'))
    }

    It 'the legacy inspection is scoped by COMMIT IDENTITY and carries no recency cap (000217)' {
        # RE-DERIVED, not loosened. The predecessor of this test pinned the opposite invariant --
        # that a truncating cap existed and announced itself -- which was the right guard while the
        # cap was the design. 000217 removed the cap rather than raising it (a bigger number only
        # moves the cliff), so the guard is re-aimed at what now has to hold: the identifier is
        # gone, the truncating loop is gone, and selection is by target commit.
        # Anchored to the bash IDENTIFIERS, not to the word: `Should -Match` is case-insensitive,
        # so a bare 'INSPECTED' also matches the step's own "are inspected below" narration and
        # would fail against correct code.
        $script:G6Text | Should -Not -Match 'LEGACY_CAP'
        $script:G6Text | Should -Not -Match 'INSPECTED\s*='
        $script:G6Text | Should -Not -Match 'INSPECTED\s*>='
        $script:G6Text | Should -Not -Match 'exceed the inspection cap'

        $sel = [regex]::Match($script:G6Text, '(?s)NEEDS_LEGACY="\$\(.*?\)"')
        $sel.Success | Should -BeTrue -Because 'the legacy selection must still be findable to be checked'
        $sel.Value | Should -Match 'head_sha'
        $sel.Value | Should -Match '\$target'

        # No silent truncation: the step must still say what it inspected and what it skipped.
        $script:G6Text | Should -Match 'UNMARKED_TOTAL'
        $script:G6Text | Should -Match 'No run is dropped for being old'
    }

    It 'all SIX gates are present -- Gate 6 is added, none of 1-5 removed' {
        foreach ($g in 1..6) {
            $script:G6Text | Should -Match ('Gate {0} --' -f $g)
        }
    }

    It 'the header enumeration counts the SAME number of gates as there are gate steps' {
        # ANCHORED to the sentence that claims to BE the enumeration, not to the file at large.
        # This header drifted once already: gate 5 shipped with 000076 and the "(1)..(4)" list was
        # never extended, so the file described four gates while running five. Counting both sides
        # is what stops that recurring silently.
        $steps = @([regex]::Matches($script:G6Text, '(?m)^\s+- name: "Gate (\d) --')) |
            ForEach-Object { [int]$_.Groups[1].Value }
        $steps.Count | Should -BeGreaterOrEqual 6 -Because 'a zero/short match here would make this test vacuous'

        $hdr = [regex]::Match($script:G6Text, '(?s)it refuses to tag unless the target commit is.*?`git tag` is in the loop')
        $hdr.Success | Should -BeTrue -Because 'the header enumeration sentence must still be findable'
        $enumerated = @([regex]::Matches($hdr.Value, '\((\d)\)')) | ForEach-Object { [int]$_.Groups[1].Value }

        ($enumerated | Sort-Object -Unique) | Should -Be ($steps | Sort-Object -Unique) -Because (
            'the prose enumeration and the actual gate steps must name the same gates -- a header ' +
            'that undercounts is exactly the doc-vs-enforcement drift Gate 6 exists to end')
    }

    It 'the release still never auto-triggers, and still indents with spaces only' {
        # Gate 6 must not have introduced a trigger or a tab.
        $script:G6Text | Should -Match '(?m)^\s+workflow_dispatch:'
        @(($script:G6Text -split "\r?\n") | Where-Object { $_ -match '^\s*push:\s*$' }).Count | Should -Be 0
        $script:G6Text | Should -Not -Match "`t"
    }
}
