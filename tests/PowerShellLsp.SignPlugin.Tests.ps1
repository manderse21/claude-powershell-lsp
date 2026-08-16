#Requires -Version 5.1

# PowerShellLsp.SignPlugin.Tests.ps1 -- guards for scripts/sign-plugin.ps1 (dispatch 000248).
#
# WHAT IS BEING GUARDED. sign-plugin.ps1 is the org-signing paved path: an administrator on an
# AllSigned / WDAC estate signs the plugin's executable script surface with the estate's OWN
# code-signing certificate. It is operator tooling -- no hook, no bootstrap and no doctor path
# invokes it -- so nothing else in the suite would notice if it rotted.
#
# THE SPLIT ACROSS LEGS, and why it is drawn where it is:
#
#   EVERY leg (windows-pwsh, windows-powershell, ubuntu-pwsh, macos-pwsh) runs the static
#   guards: the file parses, it is ASCII-only and BOM-free, it declares the parameters its
#   contract promises, it hardcodes no shipped script name, and no runtime entry point
#   references it. None of those need Windows, so none of them are allowed to skip.
#
#   NON-WINDOWS legs additionally run the HOST GATE behaviorally: the script must refuse the
#   host and exit 2 having touched nothing. That is the case a Windows-only test can never
#   cover, so the Linux and macOS legs carry real load here rather than merely skipping.
#
#   WINDOWS legs run the behavioral signing test against a THROWAWAY self-signed certificate,
#   over a scratch COPY of the script surface -- never the repository's own files, which must
#   stay unsigned in git.
#
# WHY THE VERIFY SWEEP IS THE ASSERTION AND THE SIGNING CALL IS NOT. Set-AuthenticodeSignature
# fails open: measured on Windows PowerShell 5.1 it does not raise a terminating error for a
# file it declines to sign, and it returns the same `UnknownError` status for a real signature
# whose root is untrusted on this machine and for a silent no-op. Get-AuthenticodeSignature,
# read back off disk, is the only statement of fact -- so that is what these tests assert on,
# independently of what the helper printed.
#
# TRUST-ROOT GATING. Get-AuthenticodeSignature reports `Valid` only when the signing chain
# builds to a TRUSTED root, and a throwaway self-signed certificate is its own root. Installing
# one into LocalMachine\Root needs elevation. So the Valid assertion runs when the test can
# establish that trust and calls Set-ItResult -Skipped, WITH THE REASON, when it cannot -- and
# a second Windows test that needs no trust at all asserts the signer thumbprint read back off
# disk, so an unelevated Windows leg still proves the helper really signed.
#
# The skip decision is made at RUN time via Set-ItResult, deliberately: -Skip: is evaluated
# during Pester's DISCOVERY phase, where a $script: variable a BeforeAll has not set yet reads
# as $null and would silently skip every leg.
#
# ASCII-only (PS 5.1 em-dash trap); straight quotes; LF.

$script:SpOnWindows = if (Test-Path 'Variable:\IsWindows') { [bool]$IsWindows } else { $true }

BeforeAll {
    $script:SpPluginRoot = Split-Path -Parent $PSScriptRoot
    $script:SpScriptsDir = Join-Path $script:SpPluginRoot 'scripts'
    $script:SpScript     = Join-Path $script:SpScriptsDir 'sign-plugin.ps1'
    # Run the helper under the SAME host the suite is running under, so the windows-powershell
    # leg exercises it on Windows PowerShell 5.1 and the pwsh legs on PowerShell 7.
    $script:SpHost       = (Get-Process -Id $PID).Path

    function Get-SpParseResult {
        param([Parameter(Mandatory)][string] $FilePath)
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($FilePath, [ref]$tokens, [ref]$errors)
        return [pscustomobject]@{ Tokens = @($tokens); Errors = @($errors) }
    }

    function Invoke-SpHelper {
        # Run sign-plugin.ps1 as a CHILD PROCESS and return its exit code with its output as
        # lines. Out-String is given a wide -Width on purpose: at the default console width it
        # wraps, and a wrapped line defeats a per-line needle for reasons that have nothing to
        # do with the behavior under test.
        #
        # $ErrorActionPreference is forced to Continue for the duration of the call. On Windows
        # PowerShell 5.1, `2>&1` on a NATIVE command turns each stderr line into an ErrorRecord
        # rather than a string, and an ErrorRecord arriving while the preference is Stop THROWS
        # in this caller -- so the helper writing a single line to stderr would abort the test
        # instead of being captured and asserted on. PowerShell 7 does not behave that way,
        # which is precisely how a split-stream design can pass three legs and fail only 5.1.
        param([Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Argument)
        $all = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:SpScript) + $Argument
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $raw = (& $script:SpHost @all 2>&1 | Out-String -Width 500)
        } finally {
            $ErrorActionPreference = $prev
        }
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Text     = $raw
            Lines    = @($raw -split "`r?`n")
        }
    }

    function Get-SpSurfaceFile {
        # The .ps1 / .psm1 surface under a root, derived live -- the same definition the helper
        # uses, restated here rather than imported, so the test is an INDEPENDENT statement of
        # the expected set instead of an echo of the implementation.
        param([Parameter(Mandatory)][string] $Root)
        return @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -ieq '.ps1' -or $_.Extension -ieq '.psm1' })
    }
}

Describe 'sign-plugin.ps1 -- the file itself (every leg)' {

    It 'exists in scripts/ and parses with zero errors' {
        Test-Path -LiteralPath $script:SpScript -PathType Leaf | Should -BeTrue
        $parsed = Get-SpParseResult -FilePath $script:SpScript
        @($parsed.Errors).Count | Should -Be 0
    }

    It 'is BOM-free and ASCII-only (the PS 5.1 Windows-1252 trap)' {
        # BOM and non-ASCII bytes are checkout-invariant -- git normalizes neither -- so they are
        # safe to assert on. Line endings are NOT, and are deliberately not asserted here.
        $bytes = [System.IO.File]::ReadAllBytes($script:SpScript)
        @($bytes).Count | Should -BeGreaterThan 0
        $hasBom = (@($bytes).Count -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $hasBom | Should -BeFalse
        @($bytes | Where-Object { $_ -gt 0x7E }).Count | Should -Be 0
    }

    It 'declares every parameter its documented contract promises' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:SpScript, [ref]$null, [ref]$null)
        $ast | Should -Not -BeNullOrEmpty
        $declared = @($ast.ParamBlock.Parameters | ForEach-Object { [string]$_.Name.VariablePath.UserPath })
        foreach ($expected in @('Thumbprint', 'PfxPath', 'PfxPassword', 'PluginRoot', 'Path',
                                'TimestampServer', 'NoTimestamp', 'HashAlgorithm', 'VerifyOnly')) {
            $declared | Should -Contain $expected
        }
    }

    It 'passes an explicit HashAlgorithm rather than inheriting the 5.1 SHA1 default' {
        # -HashAlgorithm defaults to SHA1 on Windows PowerShell 5.1. A helper that omits it
        # would quietly produce SHA1 signatures on the one host most likely to be the estate's.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:SpScript, [ref]$null, [ref]$null)
        $hashParam = @($ast.ParamBlock.Parameters |
            Where-Object { [string]$_.Name.VariablePath.UserPath -eq 'HashAlgorithm' })
        @($hashParam).Count | Should -Be 1
        [string]$hashParam[0].DefaultValue.Value | Should -BeExactly 'SHA256'
    }

    It 'derives its surface live and hardcodes no shipped script name' {
        # The needle set is DERIVED from the tree, never spelled here -- a literal list would rot
        # the moment a script is added or renamed, and would quietly stop covering it.
        #
        # Only STRING LITERALS are scanned. The file names other scripts in its prose (it explains
        # where the surface definition comes from), and a raw text scan would fail on its own
        # documentation rather than on a hardcoded list.
        $shipped = @(Get-SpSurfaceFile -Root $script:SpScriptsDir |
            Where-Object { $_.Name -ine 'sign-plugin.ps1' } |
            ForEach-Object { $_.Name })
        @($shipped).Count | Should -BeGreaterThan 1 -Because 'a needle set of zero would make this assertion vacuous'

        $parsed = Get-SpParseResult -FilePath $script:SpScript
        $literals = @($parsed.Tokens |
            Where-Object {
                $_.Kind -eq [System.Management.Automation.Language.TokenKind]::StringLiteral -or
                $_.Kind -eq [System.Management.Automation.Language.TokenKind]::StringExpandable
            } | ForEach-Object { [string]$_.Text })

        $hits = @()
        foreach ($name in $shipped) {
            foreach ($lit in $literals) {
                if ($lit.IndexOf($name, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $hits += ($name + ' in ' + $lit)
                }
            }
        }
        @($hits) -join '; ' | Should -BeExactly ''

        # The other half of the same claim: it must actually walk the tree.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:SpScript, [ref]$null, [ref]$null)
        $recursiveWalks = @($ast.FindAll({
            param($n)
            ($n -is [System.Management.Automation.Language.CommandAst]) -and
            (([string]$n.GetCommandName()) -ieq 'Get-ChildItem') -and
            (@($n.CommandElements | Where-Object {
                $_ -is [System.Management.Automation.Language.CommandParameterAst] -and
                $_.ParameterName -ieq 'Recurse' }).Count -gt 0)
        }, $true))
        @($recursiveWalks).Count | Should -BeGreaterThan 0
    }

    It 'routes every failure through the exit code, never through a terminating Write-Error' {
        # The helper sets $ErrorActionPreference = 'Stop', which makes Write-Error TERMINATING --
        # so an `exit <n>` written after one is dead code and the intended exit status is never
        # the one returned. It also splits the report across stdout and stderr, which on Windows
        # PowerShell 5.1 turns a captured line into a throwing ErrorRecord in the caller. Both
        # are structural, so this is asserted structurally rather than left to a behavior test
        # that only fires on one leg.
        $parsed = Get-SpParseResult -FilePath $script:SpScript
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:SpScript, [ref]$null, [ref]$null)
        @($parsed.Errors).Count | Should -Be 0
        $writeErrors = @($ast.FindAll({
            param($n)
            ($n -is [System.Management.Automation.Language.CommandAst]) -and
            (([string]$n.GetCommandName()) -ieq 'Write-Error')
        }, $true))
        @($writeErrors).Count | Should -Be 0

        # And the exits it does take are a bounded, documented set: 0 success, 1 fail-closed,
        # 2 wrong host. A payload floor keeps this from passing over a script with no exits.
        $exits = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExitStatementAst] }, $true))
        @($exits).Count | Should -BeGreaterThan 3
        $codes = @($exits | ForEach-Object { [string]$_.Pipeline.Extent.Text } | Select-Object -Unique | Sort-Object)
        $codes -join ',' | Should -BeExactly '0,1,2'
    }

    It 'is wired into no runtime entry point (it is operator tooling, invoked by an admin)' {
        # scope_out for dispatch 000248: no change to bootstrap, doctor, or any runtime path.
        $manifest = Get-Content -LiteralPath (Join-Path $script:SpPluginRoot '.claude-plugin/plugin.json') -Raw
        $manifest | Should -Not -Match 'sign-plugin'
        foreach ($entry in @('session-start.ps1', 'session-end.ps1', 'lsp-client.ps1', 'pses-serve-shim.ps1', 'doctor.ps1')) {
            $body = Get-Content -LiteralPath (Join-Path $script:SpScriptsDir $entry) -Raw
            $body | Should -Not -Match 'sign-plugin'
        }
    }
}

Describe 'sign-plugin.ps1 -- host gate (non-Windows legs carry this one)' -Skip:$script:SpOnWindows {

    It 'refuses a non-Windows host, exits 2, and says why' {
        $r = Invoke-SpHelper -Argument @('-Thumbprint', '0000000000000000000000000000000000000000')
        $r.ExitCode | Should -Be 2
        $r.Text | Should -Match 'not Windows'
        # It must not have started work before deciding: no surface line, no signing line.
        $r.Text | Should -Not -Match 'signing\.\.\.'
    }
}

Describe 'sign-plugin.ps1 -- surface and fail-closed controls (Windows legs)' -Skip:(-not $script:SpOnWindows) {

    BeforeAll {
        $script:SpEmptyDir = Join-Path ([System.IO.Path]::GetTempPath()) ('psls-signempty-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
        [void](New-Item -ItemType Directory -Path (Join-Path $script:SpEmptyDir 'scripts') -Force)
    }

    AfterAll {
        if ($script:SpEmptyDir -and (Test-Path -LiteralPath $script:SpEmptyDir)) {
            Remove-Item -LiteralPath $script:SpEmptyDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'treats an EMPTY surface as a failure, not as "everything is signed"' {
        # The payload floor. Without it, "every file reports Valid" is trivially true over
        # nothing at all -- which is the exact shape of a green gate that guards no bytes.
        $r = Invoke-SpHelper -Argument @('-PluginRoot', $script:SpEmptyDir, '-VerifyOnly')
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match 'EMPTY'
    }

    It 'runs -VerifyOnly over the real surface without signing anything' {
        $before = @(Get-SpSurfaceFile -Root $script:SpScriptsDir |
            ForEach-Object { [pscustomobject]@{ P = $_.FullName; H = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } })
        @($before).Count | Should -BeGreaterThan 1

        $r = Invoke-SpHelper -Argument @('-VerifyOnly')
        $r.Text | Should -Match 'VERIFY ONLY'
        # The repository's own files are unsigned by design, so the sweep must report that and
        # fail closed rather than pretend.
        $r.ExitCode | Should -Be 1

        foreach ($b in $before) {
            (Get-FileHash -LiteralPath $b.P -Algorithm SHA256).Hash | Should -BeExactly $b.H -Because 'a verify sweep must not write'
        }
    }
}

Describe 'sign-plugin.ps1 -- behavioral signing with a throwaway certificate (Windows legs)' -Skip:(-not $script:SpOnWindows) {

    BeforeAll {
        $script:SpSandbox   = Join-Path ([System.IO.Path]::GetTempPath()) ('psls-signplugin-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
        $script:SpCopyRoot  = Join-Path $script:SpSandbox 'plugin'
        $script:SpThumb     = ''
        $script:SpCertError = ''
        $script:SpTrustStores = @()
        $script:SpTrustError  = ''
        $script:SpOriginal    = @{}

        # A COPY of the surface. The repository's own scripts must stay unsigned in git; signing
        # them here would leave a modified working tree behind and would change bytes that other
        # guards hash.
        [void](New-Item -ItemType Directory -Path $script:SpCopyRoot -Force)
        Copy-Item -LiteralPath $script:SpScriptsDir -Destination (Join-Path $script:SpCopyRoot 'scripts') -Recurse -Force
        foreach ($f in @(Get-SpSurfaceFile -Root (Join-Path $script:SpCopyRoot 'scripts'))) {
            $script:SpOriginal[$f.FullName] = [System.IO.File]::ReadAllBytes($f.FullName)
        }

        # Throwaway code-signing certificate, one day of life, in the CURRENT USER store (no
        # elevation needed). Only its thumbprint is kept: under PowerShell 7 on Windows the PKI
        # module loads through the Windows PowerShell compatibility layer and hands back a
        # DESERIALIZED certificate that cannot sign -- the helper re-reads the live object from
        # the store by thumbprint, which is the shape that works on both hosts.
        try {
            $made = New-SelfSignedCertificate -Type CodeSigningCert `
                -Subject 'CN=powershell-lsp throwaway test signing (dispatch 000248)' `
                -CertStoreLocation 'Cert:\CurrentUser\My' `
                -KeyExportPolicy Exportable `
                -NotAfter (Get-Date).AddDays(1) -ErrorAction Stop
            $script:SpThumb = [string]$made.Thumbprint
        } catch {
            $script:SpCertError = $_.Exception.Message
        }

        # Establish chain trust so Get-AuthenticodeSignature can report Valid. LocalMachine needs
        # elevation; CurrentUser\Root is NOT attempted, because adding to it can raise a modal
        # CryptoAPI confirmation that would hang an unattended run.
        if ($script:SpThumb) {
            $identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
            $elevated  = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $elevated) {
                $script:SpTrustError = 'not elevated: a test root can only be installed into LocalMachine\Root by an administrator'
            } else {
                try {
                    $live = @(Get-ChildItem -LiteralPath 'Cert:\CurrentUser\My' |
                        Where-Object { $_.Thumbprint -eq $script:SpThumb })
                    $pub = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(, @($live)[0].RawData)
                    foreach ($name in @('Root', 'TrustedPublisher')) {
                        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($name, 'LocalMachine')
                        $store.Open('ReadWrite')
                        $store.Add($pub)
                        $store.Close()
                        $script:SpTrustStores += $name
                    }
                } catch {
                    $script:SpTrustError = $_.Exception.Message
                }
            }
        }

        # Sign the COPY. -NoTimestamp keeps the run hermetic: a timestamp server is a network
        # dependency and this test is about signing, not about reaching digicert.
        $script:SpRun = $null
        if ($script:SpThumb) {
            $script:SpRun = Invoke-SpHelper -Argument @('-PluginRoot', $script:SpCopyRoot, '-Thumbprint', $script:SpThumb, '-NoTimestamp')
        }
    }

    AfterAll {
        foreach ($name in @($script:SpTrustStores)) {
            try {
                $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($name, 'LocalMachine')
                $store.Open('ReadWrite')
                foreach ($c in @($store.Certificates | Where-Object { $_.Thumbprint -eq $script:SpThumb })) { $store.Remove($c) }
                $store.Close()
            } catch {
                Write-Verbose ('sign-plugin test cleanup: could not remove the test certificate from LocalMachine\' + $name + ': ' + $_.Exception.Message)
            }
        }
        if ($script:SpThumb) {
            Get-ChildItem -LiteralPath 'Cert:\CurrentUser\My' -ErrorAction SilentlyContinue |
                Where-Object { $_.Thumbprint -eq $script:SpThumb } |
                ForEach-Object { Remove-Item -LiteralPath $_.PSPath -Force -ErrorAction SilentlyContinue }
        }
        if ($script:SpSandbox -and (Test-Path -LiteralPath $script:SpSandbox)) {
            Remove-Item -LiteralPath $script:SpSandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'signs every .ps1 and .psm1 in the copied surface, proven by reading the signer back off disk' {
        if (-not $script:SpThumb) {
            Set-ItResult -Skipped -Because ('a throwaway code-signing certificate could not be created: ' + $script:SpCertError)
            return
        }
        $files = @(Get-SpSurfaceFile -Root (Join-Path $script:SpCopyRoot 'scripts'))
        @($files).Count | Should -BeGreaterThan 1 -Because 'signing an empty surface would prove nothing'

        $unsigned = @()
        foreach ($f in $files) {
            $sig = Get-AuthenticodeSignature -LiteralPath $f.FullName
            if ($null -eq $sig.SignerCertificate -or [string]$sig.SignerCertificate.Thumbprint -ne $script:SpThumb) {
                $unsigned += ($f.Name + ' -> ' + [string]$sig.Status)
            }
        }
        # This is the acceptance claim "zero unsigned shipped .ps1/.psm1 files", asserted from
        # Windows' own read-back rather than from the helper's stdout.
        @($unsigned) -join '; ' | Should -BeExactly ''
    }

    It 'never alters file content beyond the appended signature block' {
        if (-not $script:SpThumb) {
            Set-ItResult -Skipped -Because ('a throwaway code-signing certificate could not be created: ' + $script:SpCertError)
            return
        }
        # The claim is byte-exact: the ORIGINAL bytes must still be a PREFIX of the signed file,
        # so nothing ahead of the appended block moved, was re-encoded, or had its line endings
        # rewritten. Compared by hashing the prefix rather than by walking it element by element --
        # a per-byte loop that re-evaluates the array's length each iteration is quadratic on a
        # 200 KB script and hangs the leg rather than failing it.
        $checked = 0
        $violations = @()
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            foreach ($path in @($script:SpOriginal.Keys)) {
                $before = $script:SpOriginal[$path]
                $after = [System.IO.File]::ReadAllBytes($path)
                $checked++
                if ($after.Length -le $before.Length) {
                    $violations += ($path + ': did not grow, so no signature block was appended')
                    continue
                }
                $prefix = New-Object 'byte[]' $before.Length
                [System.Array]::Copy($after, 0, $prefix, 0, $before.Length)
                $hBefore = [System.BitConverter]::ToString($sha.ComputeHash($before))
                $hPrefix = [System.BitConverter]::ToString($sha.ComputeHash($prefix))
                if ($hBefore -ne $hPrefix) { $violations += ($path + ': content before the appended block changed') }
            }
        } finally {
            $sha.Dispose()
        }
        $checked | Should -BeGreaterThan 1
        @($violations) -join '; ' | Should -BeExactly ''
    }

    It 'prints its own Get-AuthenticodeSignature sweep, one row per file' {
        if (-not $script:SpThumb) {
            Set-ItResult -Skipped -Because ('a throwaway code-signing certificate could not be created: ' + $script:SpCertError)
            return
        }
        $files = @(Get-SpSurfaceFile -Root (Join-Path $script:SpCopyRoot 'scripts'))
        $script:SpRun.Text | Should -Match 'STATUS'
        $missing = @()
        foreach ($f in $files) {
            $needle = $f.FullName.Substring($script:SpCopyRoot.Length).TrimStart('\', '/').Replace('\', '/')
            if (@($script:SpRun.Lines | Where-Object { $_ -like ('*' + $needle) }).Count -eq 0) { $missing += $needle }
        }
        @($missing) -join '; ' | Should -BeExactly ''
    }

    It 'reports Valid for every file, and exits 0, once the signing root is trusted' {
        if (-not $script:SpThumb) {
            Set-ItResult -Skipped -Because ('a throwaway code-signing certificate could not be created: ' + $script:SpCertError)
            return
        }
        if (@($script:SpTrustStores).Count -eq 0) {
            Set-ItResult -Skipped -Because ('chain trust for the throwaway certificate could not be established: ' + $script:SpTrustError)
            return
        }
        $files = @(Get-SpSurfaceFile -Root (Join-Path $script:SpCopyRoot 'scripts'))
        @($files).Count | Should -BeGreaterThan 1
        $notValid = @()
        foreach ($f in $files) {
            $sig = Get-AuthenticodeSignature -LiteralPath $f.FullName
            if ([string]$sig.Status -ne 'Valid') { $notValid += ($f.Name + ' -> ' + [string]$sig.Status) }
        }
        @($notValid) -join '; ' | Should -BeExactly ''
        $script:SpRun.ExitCode | Should -Be 0
    }

    It 'FAILS CLOSED and names the file when one signature is broken (the red control)' {
        # A gate nobody has watched fail is a gate nobody has tested. Corrupt exactly one signed
        # file's signature block and re-sweep: the helper must exit non-zero AND name that file.
        if (-not $script:SpThumb) {
            Set-ItResult -Skipped -Because ('a throwaway code-signing certificate could not be created: ' + $script:SpCertError)
            return
        }
        $victim = @(Get-SpSurfaceFile -Root (Join-Path $script:SpCopyRoot 'scripts') | Sort-Object Name)[0]
        $victim | Should -Not -BeNullOrEmpty
        $lines = @([System.IO.File]::ReadAllLines($victim.FullName))
        $beginAt = -1
        for ($i = 0; $i -lt @($lines).Count; $i++) {
            if ($lines[$i] -match 'SIG # Begin signature block') { $beginAt = $i; break }
        }
        $beginAt | Should -BeGreaterThan -1 -Because 'the corruption must act on a real signature block'
        ($beginAt + 1) | Should -BeLessThan @($lines).Count

        # Flip ONE base64 character to a value it demonstrably was not. Picking the replacement
        # by comparison rather than by a fixed letter is what stops the mutation from being a
        # no-op on the one run where the original character happened to be that letter -- an
        # unmutated "red control" is green for the wrong reason and proves nothing.
        $victimLine = [string]$lines[$beginAt + 1]
        $victimLine.Length | Should -BeGreaterThan 4
        $at = $victimLine.Length - 1
        $replacement = if ($victimLine[$at] -ceq 'A') { 'B' } else { 'A' }
        $lines[$beginAt + 1] = $victimLine.Substring(0, $at) + $replacement
        [System.IO.File]::WriteAllLines($victim.FullName, $lines, (New-Object System.Text.ASCIIEncoding))

        $r = Invoke-SpHelper -Argument @('-PluginRoot', $script:SpCopyRoot, '-VerifyOnly')
        $r.ExitCode | Should -Be 1
        $r.Text | Should -Match ([regex]::Escape($victim.Name))
        $r.Text | Should -Match 'not Valid'
    }
}
