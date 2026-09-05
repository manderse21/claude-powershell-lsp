#Requires -Version 5.1

# Offline / air-gapped bootstrap tests (Pester 5, dispatch 000244). No network, no daemon:
# runs on all four CI legs.
#
# The load-bearing property under test is NEGATIVE -- adding artifact SOURCES must add no
# TRUST -- so most assertions below are about what cannot happen: a layer cannot verify
# itself, a pin mismatch cannot fall through to another layer, and an unset configuration
# cannot touch the network or the disk.

BeforeAll {
    $script:PluginRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsDir = Join-Path $script:PluginRoot 'scripts'
    . (Join-Path $script:ScriptsDir 'lib/lsp-common.ps1')

    # Save the ambient values ONCE. CI sets none of these, but a developer box might, and a
    # suite that clobbered a real value would be a nasty thing to debug.
    $script:AmbientMirror = $env:POWERSHELL_LSP_ARTIFACT_MIRROR_BASE
    $script:AmbientBundle = $env:POWERSHELL_LSP_ARTIFACT_BUNDLE_DIR

    function Reset-ArtifactEnv {
        Remove-Item Env:POWERSHELL_LSP_ARTIFACT_MIRROR_BASE -ErrorAction SilentlyContinue
        Remove-Item Env:POWERSHELL_LSP_ARTIFACT_BUNDLE_DIR -ErrorAction SilentlyContinue
    }
}

AfterAll {
    if ($null -ne $script:AmbientMirror) { $env:POWERSHELL_LSP_ARTIFACT_MIRROR_BASE = $script:AmbientMirror }
    else { Remove-Item Env:POWERSHELL_LSP_ARTIFACT_MIRROR_BASE -ErrorAction SilentlyContinue }
    if ($null -ne $script:AmbientBundle) { $env:POWERSHELL_LSP_ARTIFACT_BUNDLE_DIR = $script:AmbientBundle }
    else { Remove-Item Env:POWERSHELL_LSP_ARTIFACT_BUNDLE_DIR -ErrorAction SilentlyContinue }
}

Describe 'Artifact-source configuration parsing (dispatch 000244)' {
    BeforeEach { Reset-ArtifactEnv }
    AfterEach { Reset-ArtifactEnv }

    It 'reports nothing configured when both variables are unset' {
        $s = Get-ArtifactSourceSettings
        $s.AnyConfigured | Should -BeFalse
        $s.MirrorConfigured | Should -BeFalse
        $s.BundleConfigured | Should -BeFalse
    }
    It 'accepts an https mirror base and strips a trailing slash' {
        $env:POWERSHELL_LSP_ARTIFACT_MIRROR_BASE = 'https://mirror.corp.example/psls/'
        $s = Get-ArtifactSourceSettings
        $s.MirrorValid | Should -BeTrue
        $s.MirrorBase | Should -Be 'https://mirror.corp.example/psls'
    }
    It 'REFUSES a non-https mirror base and says why, rather than ignoring it' {
        # Adversarial control: relax the scheme test in Get-ArtifactSourceSettings -> RED.
        $env:POWERSHELL_LSP_ARTIFACT_MIRROR_BASE = 'http://mirror.corp.example/psls'
        $s = Get-ArtifactSourceSettings
        $s.MirrorConfigured | Should -BeTrue
        $s.MirrorValid | Should -BeFalse
        $s.MirrorReason | Should -Match 'https'
    }
    It 'REFUSES a relative bundle directory (the settingsPath reasoning)' {
        $env:POWERSHELL_LSP_ARTIFACT_BUNDLE_DIR = 'relative/artifacts'
        $s = Get-ArtifactSourceSettings
        $s.BundleConfigured | Should -BeTrue
        $s.BundleValid | Should -BeFalse
        $s.BundleReason | Should -Match 'absolute'
    }
    It 'REFUSES a bundle directory that does not exist' {
        $env:POWERSHELL_LSP_ARTIFACT_BUNDLE_DIR =
            (Join-Path ([System.IO.Path]::GetTempPath()) ('psls-absent-' + [Guid]::NewGuid().ToString('N')))
        $s = Get-ArtifactSourceSettings
        $s.BundleValid | Should -BeFalse
        $s.BundleReason | Should -Match 'does not exist'
    }
}

Describe 'Artifact-source resolution order and misses (dispatch 000244)' {
    BeforeAll {
        $script:SandBox = Join-Path ([System.IO.Path]::GetTempPath()) ('psls-airgap-' + [Guid]::NewGuid().ToString('N'))
        $script:StageDir = Join-Path $script:SandBox 'bundle'
        $script:OutDir = Join-Path $script:SandBox 'out'
        New-Item -ItemType Directory -Force -Path $script:StageDir | Out-Null
        New-Item -ItemType Directory -Force -Path $script:OutDir | Out-Null
    }
    AfterAll {
        # Scoped to this suite's own GUID-named sandbox under the temp directory.
        if (Test-Path -LiteralPath $script:SandBox) {
            Get-ChildItem -LiteralPath $script:SandBox -Recurse -File | Remove-Item -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $script:SandBox -Recurse -ErrorAction SilentlyContinue
        }
    }
    BeforeEach { Reset-ArtifactEnv }
    AfterEach { Reset-ArtifactEnv }

    It 'with NOTHING configured: resolves nothing, writes nothing, says nothing' {
        # This IS the "byte-identical to current main with no knobs set" acceptance criterion,
        # asserted at the one layer that could break it.
        $dest = Join-Path $script:OutDir 'nothing.bin'
        $r = Resolve-PinnedArtifactSource -FileName 'anything.zip' -Destination $dest
        $r.Resolved | Should -BeFalse
        $r.Layer | Should -Be ''
        @($r.Notes).Count | Should -Be 0
        Test-Path -LiteralPath $dest | Should -BeFalse
    }
    It 'resolves from the bundle when the artifact is staged there' {
        Set-Content -LiteralPath (Join-Path $script:StageDir 'Widget-1.0.zip') -Value 'STAGED' -Encoding ascii
        $env:POWERSHELL_LSP_ARTIFACT_BUNDLE_DIR = $script:StageDir
        $dest = Join-Path $script:OutDir 'hit.bin'
        $r = Resolve-PinnedArtifactSource -FileName 'Widget-1.0.zip' -Destination $dest
        $r.Resolved | Should -BeTrue
        $r.Layer | Should -Be 'bundle'
        (Get-Content -LiteralPath $dest -Raw).Trim() | Should -Be 'STAGED'
    }
    It 'treats a configured-but-absent bundle artifact as a MISS, not a failure, and names it' {
        $env:POWERSHELL_LSP_ARTIFACT_BUNDLE_DIR = $script:StageDir
        $r = Resolve-PinnedArtifactSource -FileName 'NotStaged.nupkg' -Destination (Join-Path $script:OutDir 'miss.bin')
        $r.Resolved | Should -BeFalse
        ($r.Notes -join ' ') | Should -Match 'bundle configured but artifact missing'
    }
    It 'ORDER: an unusable mirror is skipped and the bundle answers (mirror is tried first)' {
        Set-Content -LiteralPath (Join-Path $script:StageDir 'Ordered-2.0.zip') -Value 'FROMBUNDLE' -Encoding ascii
        $env:POWERSHELL_LSP_ARTIFACT_MIRROR_BASE = 'http://not-https.example/x'   # refused -> skipped
        $env:POWERSHELL_LSP_ARTIFACT_BUNDLE_DIR = $script:StageDir
        $r = Resolve-PinnedArtifactSource -FileName 'Ordered-2.0.zip' -Destination (Join-Path $script:OutDir 'ordered.bin')
        $r.Resolved | Should -BeTrue
        $r.Layer | Should -Be 'bundle'
        ($r.Notes -join ' ') | Should -Match 'mirror configured but unusable'
    }
    It 'the resolver NEVER verifies a pin itself -- Resolved means bytes placed, not bytes trusted' {
        # The single-gate invariant. If the resolver grew its own hash check, a layer could
        # acquire a second, weaker gate than the one the ensure-scripts apply.
        $src = Get-Content -LiteralPath (Join-Path $script:ScriptsDir 'lib/lsp-common.ps1') -Raw
        $start = $src.IndexOf('function Resolve-PinnedArtifactSource')
        $start | Should -BeGreaterThan 0
        $end = $src.IndexOf('# --- plugin version', $start)
        $end | Should -BeGreaterThan $start
        # Assert on CODE, not prose: the function's own doc comment legitimately explains that
        # verification stays in the caller, and matching that would make this test vacuous in
        # the wrong direction (it would fail on a correct implementation).
        $body = $src.Substring($start, $end - $start)
        $code = (($body -split "`n") | Where-Object { $_.TrimStart() -notmatch '^#' }) -join "`n"
        $code | Should -Not -Match 'Test-PinnedFileHash'
        $code | Should -Not -Match 'Get-FileHash'
    }
}

Describe 'Artifact naming is single-sourced (dispatch 000244)' {
    It 'produces version-qualified names for both components' {
        Get-PinnedArtifactFileName -Component 'pses' -Version 'v4.6.0' | Should -Be 'PowerShellEditorServices-v4.6.0.zip'
        Get-PinnedArtifactFileName -Component 'pssa' -Version '1.25.0' | Should -Be 'PSScriptAnalyzer-1.25.0.nupkg'
    }
    It 'changes the filename when the pin changes, so a stale bundle cannot satisfy a new pin' {
        (Get-PinnedArtifactFileName -Component 'pses' -Version 'v4.6.0') |
            Should -Not -Be (Get-PinnedArtifactFileName -Component 'pses' -Version 'v4.7.0')
    }
    It 'rejects an unknown component rather than inventing a name' {
        { Get-PinnedArtifactFileName -Component 'nope' -Version '1.0' } | Should -Throw
    }
}

Describe 'Layered sources are WIRED into both bootstrap scripts, one pin gate each (dispatch 000244)' {
    BeforeAll {
        $script:PsesSrc = Get-Content -LiteralPath (Join-Path $script:ScriptsDir 'ensure-pses.ps1') -Raw
        $script:PssaSrc = Get-Content -LiteralPath (Join-Path $script:ScriptsDir 'ensure-pssa.ps1') -Raw
    }

    It 'ensure-pses resolves layers BEFORE its download, and keeps exactly one pin gate' {
        # Anchor on the CALL (`Test-PinnedFileHash -Path`), not the bare name: the file's header
        # comment names the helper too, and an index over that would compare prose to code.
        $resolveIdx = $script:PsesSrc.IndexOf('$sourced = Resolve-PinnedArtifactSource')
        $downloadIdx = $script:PsesSrc.IndexOf('Invoke-WebRequest')
        $verifyIdx = $script:PsesSrc.IndexOf('Test-PinnedFileHash -Path')
        $resolveIdx | Should -BeGreaterThan 0
        $downloadIdx | Should -BeGreaterThan $resolveIdx
        $verifyIdx | Should -BeGreaterThan $downloadIdx
        @([regex]::Matches($script:PsesSrc, 'Test-PinnedFileHash -Path')).Count | Should -Be 1
    }
    It 'ensure-pssa resolves layers BEFORE the 000049 cache lookup, and keeps exactly one pin gate' {
        # The new layers sit OUTSIDE the cache, so the cache and its bounded retry keep their
        # exact 000049 behavior as the innermost layer.
        $resolveIdx = $script:PssaSrc.IndexOf('Resolve-PinnedArtifactSource')
        $cacheIdx = $script:PssaSrc.IndexOf('$cachedNupkg = Get-PssaCachedNupkgPath')
        $resolveIdx | Should -BeGreaterThan 0
        $cacheIdx | Should -BeGreaterThan $resolveIdx
        @([regex]::Matches($script:PssaSrc, 'Test-PinnedFileHash -Path \$nupkg')).Count | Should -Be 1
    }
    It 'the 000049 cache and the download are both skipped once a 000244 layer resolved' {
        $script:PssaSrc | Should -Match 'if \(-not \$sourced\.Resolved -and -not \[string\]::IsNullOrWhiteSpace\(\$cachedNupkg\)'
        $script:PssaSrc | Should -Match 'if \(-not \$sourced\.Resolved -and -not \$fromCache\)'
    }
    It 'the cache POPULATE is gated on a real download, never on mirror/bundle bytes' {
        # Adversarial control: revert to `-not $fromCache` and mirror/bundle bytes would be
        # written into a CI cache 000049 defined as holding only self-downloaded artifacts.
        $script:PssaSrc | Should -Match "\`$sourceLayer -eq 'download' -and -not \[string\]::IsNullOrWhiteSpace\(\`$cachedNupkg\)"
    }
    It 'BOTH scripts name the failing LAYER in their integrity-failure output' {
        $script:PsesSrc | Should -Match 'integrity check FAILED for the'
        $script:PsesSrc | Should -Match '\$sourceLayer'
        $script:PssaSrc | Should -Match 'integrity check FAILED \(. \+ \$sourceLayer|\$sourceLayer'
    }
    It 'a pin mismatch NEVER falls through to another source -- it terminates, in both scripts' {
        # "A tampered local artifact must fail exactly like a tampered download": ONE gate, and
        # its failure branch terminates. If a mismatch could reach the next layer, whoever
        # controls one layer could force a downgrade onto another.
        $psesFail = $script:PsesSrc.IndexOf('if (-not (Test-PinnedFileHash')
        $psesFail | Should -BeGreaterThan 0
        $psesThrow = $script:PsesSrc.IndexOf('integrity check FAILED for the', $psesFail)
        $psesThrow | Should -BeGreaterThan $psesFail

        $pssaFail = $script:PssaSrc.IndexOf('if (-not (Test-PinnedFileHash -Path $nupkg')
        $pssaFail | Should -BeGreaterThan 0
        $pssaExit = $script:PssaSrc.IndexOf('exit 1', $pssaFail)
        $pssaExit | Should -BeGreaterThan $pssaFail
        # ...and NO acquisition of any kind is reachable from that branch. Before dispatch
        # 000279 this asserted that the unverified Save-Module fallback sat after the exit;
        # that route no longer exists, so the assertion is now the stronger one -- nothing
        # after the fail-closed exit can acquire bytes at all.
        $pssaTail = $script:PssaSrc.Substring($pssaExit)
        $pssaTail | Should -Not -Match 'Save-Module -Name'
        $pssaTail | Should -Not -Match 'Save-Package -Name'
        $pssaTail | Should -Not -Match 'Invoke-WebRequest'
    }
    It 'both scripts record the resolved layer in their install marker' {
        $script:PsesSrc | Should -Match 'Set-Content -LiteralPath \$marker -Value \$sourceLayer'
        $script:PssaSrc | Should -Match 'Set-Content -LiteralPath \$marker -Value \$sourceLayer'
    }
    It 'the gallery fallback labels itself distinctly AND feeds the one pin gate (000279)' {
        # The label survives 000279 unchanged -- an operator still wants to know which transport
        # supplied an install, and old markers still parse. What changed is that the layer is now
        # acquired as a .nupkg BEFORE the gate rather than installed after it.
        $script:PssaSrc | Should -Match "\`$sourceLayer = 'gallery-fallback'"
        $fallbackIdx = $script:PssaSrc.IndexOf('$sourceLayer = ''gallery-fallback''')
        $gateIdx = $script:PssaSrc.IndexOf('if (-not (Test-PinnedFileHash -Path $nupkg')
        $fallbackIdx | Should -BeGreaterThan 0
        $gateIdx | Should -BeGreaterThan $fallbackIdx
    }
    It 'ensure-pses uses $installDir for the INSTALL destination (000244 collision rename)' {
        $script:PsesSrc | Should -Match '\$installDir = Join-Path \$dataRoot'
        # The only surviving mention of the old name is the note explaining the rename.
        @([regex]::Matches($script:PsesSrc, '\$bundleDir')).Count | Should -Be 1
    }
}

Describe 'Doctor: artifact-source check (dispatch 000244)' {
    BeforeAll { . (Join-Path $script:ScriptsDir 'doctor.ps1') }

    It 'is UNKNOWN when the data root is not known' {
        (Test-DoctorArtifactSource -DataRootKnown $false).Status | Should -Be 'unknown'
    }
    It 'is UNKNOWN -- never a fabricated pass -- when no marker records a layer' {
        $r = Test-DoctorArtifactSource -DataRootKnown $true -PsesLayer '' -PssaLayer ''
        $r.Status | Should -Be 'unknown'
        $r.Detail | Should -Match 'no install marker records'
    }
    It 'PASSES on any layer, naming each component' {
        $r = Test-DoctorArtifactSource -DataRootKnown $true -PsesLayer 'bundle' -PssaLayer 'cache'
        $r.Status | Should -Be 'pass'
        $r.Detail | Should -Match 'PSES from bundle'
        $r.Detail | Should -Match 'PSScriptAnalyzer from cache'
    }
    It 'PASSES on the gallery fallback, now saying the pin DOES gate it (000279)' {
        # The NOTE inverted with the gate. What it must NOT do is drop the legacy caveat: a
        # marker records the LAYER, never the build that wrote it, so a gallery-fallback marker
        # left by an install predating the gate still describes bytes the pin did not verify.
        $r = Test-DoctorArtifactSource -DataRootKnown $true -PsesLayer 'download' -PssaLayer 'gallery-fallback'
        $r.Status | Should -Be 'pass'
        $r.Detail | Should -Match 'is SHA-256 pin-gated'
        $r.Detail | Should -Match 'predating that gate'
        $r.Detail | Should -Not -Match 'is not SHA-256 pin-gated'
    }
    It 'Get-DoctorMarkerLayer returns only known layer words, never arbitrary marker content' {
        # A marker lives under a user-writable data dir; echoing its content into the report
        # would let that file dictate what the diagnostic says.
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('psls-marker-' + [Guid]::NewGuid().ToString('N') + '.ok')
        try {
            Set-Content -LiteralPath $tmp -Value 'bundle' -Encoding ascii
            Get-DoctorMarkerLayer -MarkerPath $tmp | Should -Be 'bundle'
            Set-Content -LiteralPath $tmp -Value 'totally-made-up' -Encoding ascii
            Get-DoctorMarkerLayer -MarkerPath $tmp | Should -Be ''
            Set-Content -LiteralPath $tmp -Value '' -Encoding ascii
            Get-DoctorMarkerLayer -MarkerPath $tmp | Should -Be ''
        } finally {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        }
    }
    It 'Get-DoctorMarkerLayer returns empty for an absent marker (pre-000244 installs)' {
        Get-DoctorMarkerLayer -MarkerPath (Join-Path ([System.IO.Path]::GetTempPath()) 'psls-no-such-marker.ok') |
            Should -Be ''
    }
}

Describe 'Doctor: offline-readiness check (dispatch 000244)' {
    BeforeAll { . (Join-Path $script:ScriptsDir 'doctor.ps1') }

    It 'is UNKNOWN when no offline source is configured (the default)' {
        $r = Test-DoctorOfflineReadiness -MirrorConfigured $false -MirrorValid $false `
            -BundleConfigured $false -BundleValid $false
        $r.Status | Should -Be 'unknown'
        $r.Detail | Should -Match 'no offline artifact source is configured'
    }
    It 'FAILS a configured-but-unusable bundle, quoting the reason' {
        $r = Test-DoctorOfflineReadiness -MirrorConfigured $false -MirrorValid $false `
            -BundleConfigured $true -BundleValid $false -BundleReason 'directory does not exist'
        $r.Status | Should -Be 'fail'
        $r.Detail | Should -Match 'directory does not exist'
    }
    It 'FAILS a configured-but-unusable mirror, quoting the reason' {
        $r = Test-DoctorOfflineReadiness -MirrorConfigured $true -MirrorValid $false -MirrorReason 'not an https:// URL' `
            -BundleConfigured $false -BundleValid $false
        $r.Status | Should -Be 'fail'
        $r.Detail | Should -Match 'https'
    }
    It 'PASSES when the bundle holds every pinned artifact and each matches its pin' {
        $ok = @(
            [pscustomobject]@{ Name = 'a.zip'; Present = $true; PinValid = $true }
            [pscustomobject]@{ Name = 'b.nupkg'; Present = $true; PinValid = $true }
        )
        $r = Test-DoctorOfflineReadiness -MirrorConfigured $false -MirrorValid $false `
            -BundleConfigured $true -BundleValid $true -BundleArtifacts $ok
        $r.Status | Should -Be 'pass'
        $r.Detail | Should -Match 'no network access'
    }
    It 'FAILS loudly on a staged artifact that does not match its pin (stale or tampered)' {
        $bad = @(
            [pscustomobject]@{ Name = 'a.zip'; Present = $true; PinValid = $false }
            [pscustomobject]@{ Name = 'b.nupkg'; Present = $true; PinValid = $true }
        )
        $r = Test-DoctorOfflineReadiness -MirrorConfigured $false -MirrorValid $false `
            -BundleConfigured $true -BundleValid $true -BundleArtifacts $bad
        $r.Status | Should -Be 'fail'
        $r.Detail | Should -Match 'does NOT match its SHA-256 pin'
        $r.Detail | Should -Match 'a\.zip'
    }
    It 'FAILS a bundle that is missing an artifact, naming it' {
        $missing = @(
            [pscustomobject]@{ Name = 'a.zip'; Present = $false; PinValid = $false }
            [pscustomobject]@{ Name = 'b.nupkg'; Present = $true; PinValid = $true }
        )
        $r = Test-DoctorOfflineReadiness -MirrorConfigured $false -MirrorValid $false `
            -BundleConfigured $true -BundleValid $true -BundleArtifacts $missing
        $r.Status | Should -Be 'fail'
        $r.Detail | Should -Match 'missing: a\.zip'
    }
    It 'is UNKNOWN for a mirror-only setup: it will not claim a verification it did not perform' {
        # Proving a mirror means hashing its artifacts, which means downloading them. A doctor
        # that pulled tens of megabytes is not a doctor, and a PASS here would be a lie.
        $r = Test-DoctorOfflineReadiness -MirrorConfigured $true -MirrorValid $true `
            -BundleConfigured $false -BundleValid $false
        $r.Status | Should -Be 'unknown'
        $r.Detail | Should -Match 'cannot be PROVEN here'
    }
}

Describe 'Airgap bundle builder (dispatch 000244)' {
    BeforeAll {
        $script:BuilderPath = Join-Path $script:PluginRoot 'release/New-AirgapBundle.ps1'
        $script:BuilderSrc = Get-Content -LiteralPath $script:BuilderPath -Raw
    }

    It 'exists and parses' {
        Test-Path -LiteralPath $script:BuilderPath | Should -BeTrue
        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:BuilderPath, [ref]$null, [ref]$errs) | Out-Null
        @($errs).Count | Should -Be 0
    }
    It 'single-sources every pin from the ensure-scripts, never a second copy of a hash' {
        $script:BuilderSrc | Should -Match "VarName 'PsesTag'"
        $script:BuilderSrc | Should -Match "VarName 'PsesSha256'"
        $script:BuilderSrc | Should -Match "VarName 'PssaVersion'"
        $script:BuilderSrc | Should -Match "VarName 'PssaSha256'"
        # No literal 64-hex hash may appear in the builder itself.
        $script:BuilderSrc | Should -Not -Match '[0-9A-F]{64}'
    }
    It 'REFUSES to pack an artifact that does not match its pin' {
        # The behavioral proof, run offline: stage artifacts with the right NAMES and wrong
        # BYTES, and the builder must refuse rather than ship them. A bundle is a security
        # artifact; one bad byte here becomes an unexplainable failure at every air-gapped
        # machine, far from the build that caused it.
        $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('psls-bad-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
        try {
            $psesTag = ([regex]"\`$PsesTag\s*=\s*'([^']+)'").Match(
                (Get-Content -LiteralPath (Join-Path $script:ScriptsDir 'ensure-pses.ps1') -Raw)).Groups[1].Value
            $pssaVer = ([regex]"\`$PssaVersion\s*=\s*'([^']+)'").Match(
                (Get-Content -LiteralPath (Join-Path $script:ScriptsDir 'ensure-pssa.ps1') -Raw)).Groups[1].Value
            Set-Content -Encoding ascii -Value 'NOT THE REAL BYTES' `
                -LiteralPath (Join-Path $sandbox (Get-PinnedArtifactFileName -Component 'pses' -Version $psesTag))
            Set-Content -Encoding ascii -Value 'NOT THE REAL BYTES' `
                -LiteralPath (Join-Path $sandbox (Get-PinnedArtifactFileName -Component 'pssa' -Version $pssaVer))

            { & $script:BuilderPath -RepoRoot $script:PluginRoot -SourceDir $sandbox -VerifyOnly } |
                Should -Throw -ExpectedMessage '*does NOT match its pin*'
        } finally {
            if (Test-Path -LiteralPath $sandbox) {
                Get-ChildItem -LiteralPath $sandbox -File | Remove-Item -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $sandbox -ErrorAction SilentlyContinue
            }
        }
    }
    It 'states that the manifest is documentation, not a trust input' {
        $script:BuilderSrc | Should -Match 'NOT a trust input'
    }
    It 'excludes the plugin source, and records why' {
        $script:BuilderSrc | Should -Match 'two attested paths to the same bytes'
    }
}

Describe 'Release pipeline publishes and attests the airgap bundle (dispatch 000244)' {
    BeforeAll {
        $script:RelWf = Get-Content -LiteralPath (Join-Path $script:PluginRoot '.github/workflows/powershell-lsp-release.yml') -Raw
    }

    It 'builds the bundle' {
        $script:RelWf | Should -Match 'New-AirgapBundle\.ps1'
    }
    It 'ATTESTS the bundle: it is a subject of the provenance attestation' {
        # This is the workflow-TEXT assertion that stands in for a live `gh attestation verify`
        # on a dry run -- the attestation needs a server-issued OIDC token and cannot be
        # exercised in a rehearsal (RELEASING.md, "What only proves out on the first real
        # release"). Dropping the bundle from subject-path fails CI here instead of shipping
        # an unattested asset.
        $idx = $script:RelWf.IndexOf('subject-path:')
        $idx | Should -BeGreaterThan 0
        $block = $script:RelWf.Substring($idx, [Math]::Min(400, $script:RelWf.Length - $idx))
        $block | Should -Match 'powershell-lsp-airgap-\$\{\{ steps\.resolve\.outputs\.version \}\}\.zip'
    }
    It 'UPLOADS the bundle to the GitHub Release' {
        $script:RelWf | Should -Match '"powershell-lsp-airgap-\$V\.zip"'
    }
    It 'builds the bundle on a DRY RUN too -- the assembly proof the rehearsal rests on' {
        # Every other asset step is gated `if: ${{ !inputs.dry_run }}`. This one must not be,
        # or a rehearsal proves nothing about the bundle and a broken one is discovered only
        # on the producing run.
        $idx = $script:RelWf.IndexOf('- name: Build the airgap bundle')
        $idx | Should -BeGreaterThan 0
        $step = $script:RelWf.Substring($idx, [Math]::Min(300, $script:RelWf.Length - $idx))
        $step | Should -Not -Match 'if:\s*\$\{\{\s*!inputs\.dry_run\s*\}\}'
    }
    It 'reads the built zip back and refuses an empty or short archive' {
        $script:RelWf | Should -Match 'missing MANIFEST\.txt|MANIFEST\.txt'
        $script:RelWf | Should -Match 'airgap bundle entry is empty'
    }
}
