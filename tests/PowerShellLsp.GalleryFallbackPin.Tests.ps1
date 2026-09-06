#Requires -Version 5.1
# The gallery-fallback acquisition route is SHA-256 pin-gated and fails closed
# (dispatch 000279, ruling R10 = ENTERPRISE-PROGRAM-DOCKET R-C option (a)).
#
# WHAT THIS PROVES, and how. ensure-pssa.ps1 vendors PSScriptAnalyzer through several
# acquisition layers -- mirror, bundle, cache, direct download -- every one of which feeds a
# SINGLE Test-PinnedFileHash gate and fails closed on a mismatch. One layer did not: when the
# direct download could not complete, the script fell back to Save-Module, which leaves an
# EXTRACTED module tree and no .nupkg, so the pinned SHA-256 -- a digest OF THE .nupkg -- could
# not be computed from what it produced. Those bytes were installed on the PowerShell Gallery's
# publisher/catalog integrity alone. This dispatch replaced that acquisition with Save-Package
# over the NuGet provider, which retrieves the .nupkg ITSELF, and routed it into the same one
# gate.
#
# The tests below drive the REAL script in a CHILD PROCESS of this host, with the network calls
# stubbed: the direct download is forced to fail so the fallback is the only route left, and the
# fallback is fed bytes that are NOT the pinned artifact. A stub is the only way to reach this
# branch without a live network partition, and it is faithful -- everything after the stub is
# the shipped code.
#
# RED CONTROL (tests/fixtures/red-controls/ensure-pssa.pre-000279.ps1) is the PRIOR
# IMPLEMENTATION verbatim, not a hand-written mutant: the same driver, the same forced download
# failure, and a Save-Module stub that lays down an attacker-supplied module tree carrying the
# pinned version number. It must ACCEPT those bytes -- install them and record the install --
# which is exactly the gap this dispatch closes.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsDir = Join-Path $script:RepoRoot 'scripts'
    $script:ShippedEnsure = Join-Path $script:ScriptsDir 'ensure-pssa.ps1'
    $script:PriorEnsure = Join-Path $PSScriptRoot 'fixtures/red-controls/ensure-pssa.pre-000279.ps1'

    # SHA-256 of the prior implementation as this dispatch branched from it, over the file's
    # CONTENT with line endings normalized to LF -- never over the bytes git happened to check
    # out. A .ps1 lands CRLF on a Windows checkout and LF on a POSIX one, so Get-FileHash over
    # the working tree measures the CHECKOUT, not the fixture: it agreed on the two POSIX CI legs
    # and disagreed on both Windows legs, which is a property of git's eol handling and says
    # nothing about whether the fixture drifted. Re-derive with:
    #   git show <the commit this dispatch branched from>:scripts/ensure-pssa.ps1
    # (git hands out the blob, which is LF) piped through Get-FileHash.
    # A fixture that drifts stops being the prior implementation, and the RED control below
    # would then be measuring an arbitrary mutant instead.
    $script:PriorEnsureSha256 = 'CE52E3E049F1951B392D3AB215EDFC8C7AE0E06D8AD55909134A4606628FEBFD'

    function Get-ContentSha256 {
        # Hash the CONTENT, not the checkout. The fixture is ASCII, so its UTF-8 encoding is its
        # bytes; the only thing normalized away is the line terminator git chose.
        param([string] $Path)
        $text = [System.IO.File]::ReadAllText($Path) -replace "`r`n", "`n"
        $bytes = [Text.Encoding]::UTF8.GetBytes($text)
        return [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-', '')
    }

    # The child host is THIS host, so the suite proves the branch on whichever interpreter the
    # CI leg runs (windows-powershell 5.1 as well as the three pwsh legs).
    $script:HostExe = (Get-Process -Id $PID).Path

    function Read-EnsurePin {
        # Read a pinned literal out of an ensure-script WITHOUT executing it, the same way the
        # doctor's Get-DoctorPin does. Returns '' when the variable is absent.
        param([string] $Path, [string] $VarName)
        $src = Get-Content -LiteralPath $Path -Raw
        $m = [regex]::Match($src, ('(?m)^\$' + [regex]::Escape($VarName) + "\s*=\s*'([^']+)'"))
        if ($m.Success) { return $m.Groups[1].Value }
        return ''
    }

    function New-FallbackDriver {
        # Write the child-process driver. It shadows the network entry points the acquisition
        # can take -- Invoke-WebRequest (the direct download), Save-Package (the gallery
        # fallback as it ships now) and Save-Module (the gallery fallback as it shipped before)
        # -- so no test ever reaches the network. A function beats a cmdlet in PowerShell's
        # command precedence, and functions defined here are visible inside the script this
        # driver calls with '&'.
        param([string] $DriverPath)
        $lines = @(
            '$ProgressPreference = ''SilentlyContinue''',
            '',
            '# No sleeping between the forced download retries -- the retry BOUND belongs to the',
            '# script under test; wall-clock is not what this test measures.',
            'function Start-Sleep { [CmdletBinding()] param([int]$Seconds, [int]$Milliseconds) }',
            '',
            'function Invoke-WebRequest {',
            '    [CmdletBinding()]',
            '    param([string]$Uri, [string]$OutFile, [switch]$UseBasicParsing, [string]$UserAgent)',
            '    throw ''forced download failure (test stub)''',
            '}',
            '',
            '# PSGallery is present, so the prior implementation skips its registration branch',
            '# and reaches Save-Module -- the branch the RED control is about.',
            'function Get-PSRepository {',
            '    [CmdletBinding()] param([string]$Name)',
            '    return ([pscustomobject]@{ Name = ''PSGallery''; InstallationPolicy = ''Trusted'' })',
            '}',
            '',
            '# THE FALLBACK AS IT SHIPS NOW: hand back a .nupkg that is NOT the pinned artifact.',
            'function Save-Package {',
            '    [CmdletBinding()]',
            '    param([string]$Name, [string]$RequiredVersion, [string]$Source,',
            '          [string]$ProviderName, [string]$Path, [switch]$Force)',
            '    $f = Join-Path $Path ($Name + ''.'' + $RequiredVersion + ''.nupkg'')',
            '    [System.IO.File]::WriteAllBytes($f, [byte[]](0x50, 0x4B, 0x03, 0x04, 0x00, 0x00, 0x00, 0x00))',
            '    Write-Output ([pscustomobject]@{ Name = $Name; Version = $RequiredVersion })',
            '}',
            '',
            '# THE FALLBACK AS IT SHIPPED BEFORE: hand back an attacker-supplied module tree that',
            '# wears the pinned version number and exports the one command the importability probe',
            '# looks for. Nothing about these bytes is the pinned artifact.',
            'function Save-Module {',
            '    [CmdletBinding()]',
            '    param([string]$Name, [string]$RequiredVersion, [string]$Path, [string]$Repository, [switch]$Force)',
            '    $dir = Join-Path (Join-Path $Path $Name) $RequiredVersion',
            '    New-Item -ItemType Directory -Force -Path $dir | Out-Null',
            '    Set-Content -LiteralPath (Join-Path $dir ''PSScriptAnalyzer.psm1'') -Encoding ascii -Value ''function Invoke-ScriptAnalyzer { param() }''',
            '    Set-Content -LiteralPath (Join-Path $dir ''PSScriptAnalyzer.psd1'') -Encoding ascii -Value @(',
            '        ''@{'',',
            '        ("    ModuleVersion = ''" + $RequiredVersion + "''"),',
            '        "    RootModule = ''PSScriptAnalyzer.psm1''",',
            '        "    GUID = ''6d3f8a12-9c1e-4f77-bb90-2f0a5c7d1e34''",',
            '        "    Author = ''not-the-pinned-publisher''",',
            '        "    FunctionsToExport = @(''Invoke-ScriptAnalyzer'')",',
            '        ''}'')',
            '}',
            '',
            '$global:LASTEXITCODE = 0',
            '& $env:PSLSP_TEST_ENSURE_SCRIPT',
            'exit $global:LASTEXITCODE'
        )
        Set-Content -LiteralPath $DriverPath -Value $lines -Encoding ascii
    }

    function New-StagedEnsure {
        # Stage an ensure-script into its own directory beside a copy of the shared library it
        # dot-sources from $PSScriptRoot. BOTH the shipped script and the RED-control fixture go
        # through this, so the two runs differ in exactly one thing -- the implementation -- and
        # not in where they happen to sit on disk.
        param([string] $EnsureScript, [string] $StageDir)
        New-Item -ItemType Directory -Force -Path (Join-Path $StageDir 'lib') | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:ScriptsDir 'lib/lsp-common.ps1') `
            -Destination (Join-Path $StageDir 'lib/lsp-common.ps1') -Force
        $staged = Join-Path $StageDir 'ensure-pssa.ps1'
        Copy-Item -LiteralPath $EnsureScript -Destination $staged -Force
        return $staged
    }

    function Invoke-FallbackRun {
        # Run one ensure-script under the driver against a FRESH data root, and return
        # everything an assertion needs: the exit code, the merged output, the log the script
        # wrote, and the on-disk facts (marker, vendored module).
        param([string] $EnsureScript, [string] $DataRoot, [string] $DriverPath)
        New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null
        $EnsureScript = New-StagedEnsure -EnsureScript $EnsureScript -StageDir (Join-Path $DataRoot '_stage')
        $names = @('CLAUDE_PLUGIN_DATA', 'POWERSHELL_LSP_ARTIFACT_MIRROR_BASE',
            'POWERSHELL_LSP_ARTIFACT_BUNDLE_DIR', 'POWERSHELL_LSP_PSSA_CACHE',
            'PSLSP_TEST_ENSURE_SCRIPT')
        $saved = @{}
        foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
        try {
            [Environment]::SetEnvironmentVariable('CLAUDE_PLUGIN_DATA', $DataRoot)
            # Every OTHER layer off, so the fallback is the only route the run can take.
            [Environment]::SetEnvironmentVariable('POWERSHELL_LSP_ARTIFACT_MIRROR_BASE', '')
            [Environment]::SetEnvironmentVariable('POWERSHELL_LSP_ARTIFACT_BUNDLE_DIR', '')
            [Environment]::SetEnvironmentVariable('POWERSHELL_LSP_PSSA_CACHE', '')
            [Environment]::SetEnvironmentVariable('PSLSP_TEST_ENSURE_SCRIPT', $EnsureScript)
            $out = & $script:HostExe -NoProfile -File $DriverPath 2>&1
            $code = $LASTEXITCODE
        } finally {
            foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) }
        }
        $logPath = Join-Path (Join-Path $DataRoot 'logs') 'ensure-pssa.log'
        $log = ''
        if (Test-Path -LiteralPath $logPath -PathType Leaf) { $log = (Get-Content -LiteralPath $logPath -Raw) }
        $vendorDir = Join-Path $DataRoot 'modules'
        $markerPath = Join-Path $vendorDir '.pssa-1.25.0.ok'
        $marker = ''
        if (Test-Path -LiteralPath $markerPath -PathType Leaf) { $marker = (Get-Content -LiteralPath $markerPath -Raw).Trim() }
        return ([pscustomobject]@{
                ExitCode     = $code
                Output       = (@($out) -join [Environment]::NewLine)
                Log          = $log
                MarkerExists = (Test-Path -LiteralPath $markerPath -PathType Leaf)
                Marker       = $marker
                Vendored     = (Test-Path -LiteralPath (Join-Path $vendorDir 'PSScriptAnalyzer'))
            })
    }
}

Describe 'RED-control fixture is the PRIOR implementation, not a mutant (dispatch 000279)' {
    # Read the FIXTURE'S OWN BYTES. Nothing here routes through the changed script, so a bug in
    # the change cannot make its own control look valid.
    It 'exists and is content-pinned to the implementation this dispatch replaced' {
        Test-Path -LiteralPath $script:PriorEnsure -PathType Leaf | Should -BeTrue
        Get-ContentSha256 -Path $script:PriorEnsure | Should -Be $script:PriorEnsureSha256
        # Anti-vacuity: the normalizer must not be able to hash anything to the pin.
        $decoy = Join-Path $TestDrive 'decoy.ps1'
        Set-Content -LiteralPath $decoy -Value 'not the prior implementation' -Encoding ascii
        Get-ContentSha256 -Path $decoy | Should -Not -Be $script:PriorEnsureSha256
    }
    It 'carries the UNVERIFIED Save-Module fallback and no pinned gallery acquisition' {
        $prior = Get-Content -LiteralPath $script:PriorEnsure -Raw
        $prior | Should -Match 'Save-Module -Name PSScriptAnalyzer -RequiredVersion \$PssaVersion'
        $prior | Should -Not -Match 'Save-Package'
    }
    It 'tests the SAME pin as the shipped script, so the control is comparable' {
        # A fixture pinned to a different version or hash would fail for a reason that has
        # nothing to do with the gate.
        (Read-EnsurePin -Path $script:PriorEnsure -VarName 'PssaVersion') |
            Should -Be (Read-EnsurePin -Path $script:ShippedEnsure -VarName 'PssaVersion')
        (Read-EnsurePin -Path $script:PriorEnsure -VarName 'PssaSha256') |
            Should -Be (Read-EnsurePin -Path $script:ShippedEnsure -VarName 'PssaSha256')
        (Read-EnsurePin -Path $script:ShippedEnsure -VarName 'PssaSha256').Length | Should -Be 64
    }
}

Describe 'The gallery fallback fails closed on bytes that do not match the pin (dispatch 000279)' {
    BeforeAll {
        $script:Driver = Join-Path $TestDrive 'fallback-driver.ps1'
        New-FallbackDriver -DriverPath $script:Driver
        $script:Now = Invoke-FallbackRun -EnsureScript $script:ShippedEnsure `
            -DataRoot (Join-Path $TestDrive 'now') -DriverPath $script:Driver
        $script:Then = Invoke-FallbackRun -EnsureScript $script:PriorEnsure `
            -DataRoot (Join-Path $TestDrive 'then') -DriverPath $script:Driver
    }

    It 'REFUSES the mismatched fallback bytes and exits non-zero' {
        $script:Now.ExitCode | Should -Be 1
        $script:Now.Output | Should -Match 'integrity check failed'
    }
    It 'names the gallery-fallback LAYER as the source of the bad bytes' {
        # Layer attribution is what makes the banner actionable, and it discriminates: a gate
        # that fired on the download layer would mean the fallback was never reached.
        $script:Now.Output | Should -Match 'gallery-fallback'
        $script:Now.Log | Should -Match 'integrity check FAILED \(gallery-fallback\)'
    }
    It 'installs NOTHING and records NO pinned layer in the marker' {
        $script:Now.MarkerExists | Should -BeFalse
        $script:Now.Vendored | Should -BeFalse
    }
    It 'reached the fallback only after the direct download had failed' {
        # Proves the run exercised the branch under test rather than short-circuiting.
        $script:Now.Log | Should -Match 'direct download failed after 3 attempts'
        $script:Now.Log | Should -Match 'trying the gallery fallback'
    }

    It 'RED CONTROL: the PRIOR implementation ACCEPTS the same unpinned bytes' {
        # The gap, demonstrated: arbitrary module bytes wearing the pinned version number are
        # installed and recorded as a real install. If this ever passes by REFUSING, the fixture
        # is no longer the prior implementation and the control above is worthless.
        $script:Then.ExitCode | Should -Be 0
        $script:Then.Vendored | Should -BeTrue
        $script:Then.MarkerExists | Should -BeTrue
        $script:Then.Marker | Should -Be 'gallery-fallback'
    }
    It 'RED CONTROL: the prior run never applied a pin to those bytes' {
        $script:Then.Log | Should -Match 'Save-Module fallback succeeded'
        $script:Then.Log | Should -Not -Match 'integrity check FAILED'
    }
}

Describe 'The gallery fallback is wired into the ONE pin gate, not a second one (dispatch 000279)' {
    BeforeAll { $script:PssaSrc = Get-Content -LiteralPath $script:ShippedEnsure -Raw }

    It 'the fallback acquisition sits BEFORE the single gate, so the gate sees its bytes' {
        $acquire = $script:PssaSrc.IndexOf('Save-Package -Name PSScriptAnalyzer')
        $gate = $script:PssaSrc.IndexOf('if (-not (Test-PinnedFileHash -Path $nupkg')
        $acquire | Should -BeGreaterThan 0
        $gate | Should -BeGreaterThan $acquire
        @([regex]::Matches($script:PssaSrc, 'Test-PinnedFileHash -Path \$nupkg')).Count | Should -Be 1
    }
    It 'the fallback stages its bytes into the SAME $nupkg the gate hashes' {
        $script:PssaSrc | Should -Match 'Copy-Item -LiteralPath \$galleryNupkg\.FullName -Destination \$nupkg'
    }
    It 'no acquisition of any kind survives after the fail-closed exit' {
        # The property the pre-change suite protected by naming Save-Module: a mismatch must
        # never fall through to another source. It is now protected by there being no
        # acquisition left to fall through TO.
        $gate = $script:PssaSrc.IndexOf('if (-not (Test-PinnedFileHash -Path $nupkg')
        $exit = $script:PssaSrc.IndexOf('exit 1', $gate)
        $exit | Should -BeGreaterThan $gate
        $tail = $script:PssaSrc.Substring($exit)
        $tail | Should -Not -Match 'Save-Module'
        $tail | Should -Not -Match 'Save-Package'
        $tail | Should -Not -Match 'Invoke-WebRequest'
    }
    It 'the unverified Save-Module route is gone from the shipped script' {
        $script:PssaSrc | Should -Not -Match 'Save-Module -Name PSScriptAnalyzer'
    }
}

Describe 'ensure-pses.ps1 does not carry the same fallback shape (dispatch 000279, derived)' {
    # The charter asked whether the sibling ensure-script needs the same gate. It does not, and
    # saying so by name beats assuming symmetry: ensure-pses has NO fallback at all -- one
    # layered acquisition, one Test-PinnedFileHash, one fail-closed throw.
    BeforeAll { $script:PsesSrc = Get-Content -LiteralPath (Join-Path $script:ScriptsDir 'ensure-pses.ps1') -Raw }

    It 'has no Save-Module / Save-Package acquisition to gate' {
        $script:PsesSrc | Should -Not -Match 'Save-Module'
        $script:PsesSrc | Should -Not -Match 'Save-Package'
    }
    It 'gates its one acquisition and fails closed' {
        @([regex]::Matches($script:PsesSrc, 'Test-PinnedFileHash -Path')).Count | Should -Be 1
        $script:PsesSrc | Should -Match 'integrity check FAILED for the'
    }
}
