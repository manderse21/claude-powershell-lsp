#Requires -Version 5.1

# sign-plugin.ps1 -- sign this plugin's executable PowerShell surface with YOUR
# organization's Authenticode code-signing certificate (dispatch 000248).
#
# WHY THIS EXISTS. The project deliberately does NOT pursue a publisher Authenticode
# signature (TRUST.md, "Signing posture"): powershell-lsp is distributed by `git clone`,
# so its trust boundary is the keyless-signed tag and the commit it names, not a Windows
# publisher identity. That decision leaves one real gap for managed estates -- an
# ExecutionPolicy of `AllSigned`, or a WDAC / AppLocker policy that trusts only signed
# code, will not run unsigned scripts, and a command-line `-ExecutionPolicy Bypass` is
# IGNORED when the policy comes from Group Policy. The enterprise answer is not a
# publisher certificate your estate has no reason to trust; it is your estate signing
# with its OWN code-signing certificate, which its policy already trusts. This script
# is that, in one command.
#
# WHAT IT COVERS. The EXECUTABLE surface: every .ps1 and .psm1 under scripts/, enumerated
# LIVE from the tree it is pointed at and never from a hardcoded list. Those are the only
# files Claude Code launches (the four entry points in .claude-plugin/plugin.json) or that
# those entry points dot-source or import. Pass -Path to widen the surface if your policy
# requires the whole installed tree.
#
# WHAT IT DOES NOT COVER. The downloaded components under CLAUDE_PLUGIN_DATA -- the
# PowerShell Editor Services bundle and the vendored PSScriptAnalyzer. Those are third-party
# artifacts this project does not author and must not re-sign; they are verified by PINNED
# SHA-256 instead (TRUST.md, "What it downloads"). Script signing and artifact pinning are
# different layers and stay different: signing proves who vouched for the bytes, pinning
# proves the bytes are the exact ones this repo vouched for.
#
# WHY .psd1 IS NOT IN THE SURFACE. about_Signing lists .psd1 among the types PowerShell will
# VALIDATE a signature on, which is not the same as the set it REFUSES to load unsigned. Measured
# under process-scope AllSigned on Windows PowerShell 5.1, an unsigned .psd1 loads through every
# path this plugin uses -- Import-PowerShellDataFile (the rulesets), Import-LocalizedData, and
# Import-Module of a manifest. What AllSigned does block is the .psm1 or .ps1 a manifest chains
# to via RootModule / ScriptsToProcess, and those ARE in the surface. So signing .ps1 and .psm1
# is the whole enforcement set here, not a partial pass at it.
#
# IT IS OPERATOR TOOLING. An administrator runs it, deliberately, against an installed copy.
# The plugin never invokes it: no hook, no bootstrap, no doctor path calls this file.
#
# TWO HOST FACTS THIS SCRIPT DEPENDS ON:
#   * -HashAlgorithm defaults to SHA1 on Windows PowerShell 5.1, so SHA256 is passed explicitly
#     rather than left to the host.
#   * Before PowerShell 7.2 a signed script must be saved ASCII or UTF-8-without-BOM. This
#     repository is ASCII-only for an unrelated reason (the 5.1 Windows-1252 trap), so its files
#     already satisfy that; a tree re-encoded to UTF-16 would not.
#
# Windows-only by nature (Authenticode is a Windows construct). On any other host it
# reports that and exits WITHOUT touching a single file.
#
# Usage:
#   pwsh -File scripts/sign-plugin.ps1 -Thumbprint <40-hex-thumbprint>
#   pwsh -File scripts/sign-plugin.ps1 -PfxPath C:\certs\org-signing.pfx -PfxPassword (Read-Host -AsSecureString)
#   pwsh -File scripts/sign-plugin.ps1 -Thumbprint <hex> -PluginRoot "$env:USERPROFILE\.claude\plugins\...\powershell-lsp"
#   pwsh -File scripts/sign-plugin.ps1 -Thumbprint <hex> -NoTimestamp     # air-gapped; see below
#   pwsh -File scripts/sign-plugin.ps1 -VerifyOnly                        # sweep only, sign nothing
#
# Author: Mike Andersen / powershell-lsp plugin.

[CmdletBinding()]
param(
    # Thumbprint of a code-signing certificate in Cert:\CurrentUser\My or Cert:\LocalMachine\My.
    # Spaces and separators are tolerated (the MMC "Thumbprint" field pastes with spaces).
    [string] $Thumbprint,

    # Path to a PFX / PKCS#12 file holding the signing certificate and its private key.
    [string] $PfxPath,

    # Password for -PfxPath, as a SecureString. Windows PowerShell 5.1 has no -Password on
    # Get-PfxCertificate (it was added in PowerShell 6 and 5.1 would PROMPT), so the PFX is
    # loaded through the .NET constructor, which takes the SecureString on both hosts.
    [System.Security.SecureString] $PfxPassword,

    # Root of the plugin copy to sign. Defaults to the copy this script belongs to, so an
    # admin can run the installed copy's own script against itself.
    [string] $PluginRoot,

    # Explicit files or directories to sign, REPLACING the default scripts/ surface. Use
    # when policy requires signing more of the installed tree than the executable surface.
    [string[]] $Path,

    # RFC 3161 timestamp server. A countersignature keeps signatures valid after the signing
    # certificate expires; without one, every signature dies with the certificate.
    [string] $TimestampServer = 'http://timestamp.digicert.com',

    # Sign without contacting a timestamp server -- the air-gapped case. Trade-off: the
    # signatures become invalid the day the signing certificate expires, so the estate must
    # re-sign on every certificate renewal rather than only on plugin upgrade.
    [switch] $NoTimestamp,

    [ValidateSet('SHA256', 'SHA384', 'SHA512')]
    [string] $HashAlgorithm = 'SHA256',

    # Report the current signature status of the surface and change nothing.
    [switch] $VerifyOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- exit codes ------------------------------------------------------------
#   0  every file in the surface reports Valid
#   1  fail-closed: a file did not sign, or did not verify Valid, or inputs were unusable
#   2  wrong host (not Windows) -- nothing was read, nothing was written

function Test-SignOnWindows {
    # $IsWindows exists only on PowerShell 6+. Windows PowerShell 5.1 has no such automatic
    # variable and is always Windows. StrictMode-safe existence check (same shape as
    # Test-OnWindows in scripts/lib/lsp-common.ps1, duplicated deliberately: this file is
    # standalone operator tooling and must not drag the runtime library into an admin session).
    if (Test-Path 'Variable:\IsWindows') { return [bool]$IsWindows }
    return $true
}

function Write-Line {
    param([string] $Message = '')
    Write-Host $Message
}

function Write-FatalError {
    # EVERY operator-facing message -- including the failures -- goes to the SAME stream as the
    # report, and the EXIT CODE is the contract. Two reasons, both learned the hard way:
    #
    #   1. This script sets $ErrorActionPreference = 'Stop', which makes Write-Error TERMINATING.
    #      An `exit 1` written after one is dead code: the script dies through the error path
    #      instead, so the exit code it meant to return was never the one it actually returned.
    #   2. On Windows PowerShell 5.1 a caller that captures this script's stderr with `2>&1` gets
    #      an ErrorRecord, not a line of text, and that record THROWS in the caller when its own
    #      preference is Stop. PowerShell 7 does not behave that way, so the split-stream design
    #      passed three legs and failed only 5.1 -- exactly the asymmetry this repository exists
    #      to catch.
    param([Parameter(Mandatory)][string] $Message)
    Write-Line
    Write-Line ('  ERROR: ' + $Message)
    Write-Line
    exit 1
}

function Get-SigningSurfaceFile {
    # DERIVE the surface from the live tree. Walks each root recursively and keeps .ps1 and
    # .psm1. Returns objects carrying the absolute path and a display path relative to the
    # plugin root, so the printed report reads the way the repository does.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Root,
        [Parameter(Mandatory)][string] $RelativeTo
    )
    $sink = New-Object 'System.Collections.Generic.List[object]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($r in $Root) {
        if ([string]::IsNullOrWhiteSpace($r)) { continue }
        if (-not (Test-Path -LiteralPath $r)) { continue }
        $item = Get-Item -LiteralPath $r
        $candidates = @()
        if ($item.PSIsContainer) {
            $candidates = @(Get-ChildItem -LiteralPath $item.FullName -Recurse -File -ErrorAction SilentlyContinue)
        } else {
            $candidates = @($item)
        }
        foreach ($f in $candidates) {
            if ($f.Extension -ine '.ps1' -and $f.Extension -ine '.psm1') { continue }
            if (-not $seen.Add($f.FullName)) { continue }
            $rel = $f.FullName
            if ($rel.StartsWith($RelativeTo, [System.StringComparison]::OrdinalIgnoreCase)) {
                $rel = $rel.Substring($RelativeTo.Length).TrimStart('\', '/')
            }
            $sink.Add([pscustomobject]@{
                Full = $f.FullName
                Rel  = $rel.Replace('\', '/')
            })
        }
    }
    # .ToArray() rather than @(): the array subexpression operator throws "Argument types do
    # not match" on a generic List[T].
    return $sink.ToArray()
}

function Resolve-SigningCertificate {
    # Resolve exactly one usable code-signing certificate, or throw with a named reason.
    param([string] $Thumbprint, [string] $PfxPath, [System.Security.SecureString] $PfxPassword)

    if (-not [string]::IsNullOrWhiteSpace($PfxPath)) {
        if (-not (Test-Path -LiteralPath $PfxPath -PathType Leaf)) {
            throw ("-PfxPath does not name a file: " + $PfxPath)
        }
        $full = (Resolve-Path -LiteralPath $PfxPath).ProviderPath
        $pw = $PfxPassword
        if ($null -eq $pw) { $pw = (New-Object System.Security.SecureString) }
        $flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::DefaultKeySet
        try {
            $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($full, $pw, $flags)
        } catch {
            throw ("could not load the PFX at " + $full + " -- " + $_.Exception.Message +
                   " (a wrong or missing -PfxPassword is the usual cause)")
        }
        return [pscustomobject]@{ Certificate = $cert; Source = ('PFX ' + $full) }
    }

    if ([string]::IsNullOrWhiteSpace($Thumbprint)) {
        throw 'supply either -Thumbprint (a certificate in Cert:\CurrentUser\My or Cert:\LocalMachine\My) or -PfxPath.'
    }

    # MMC copies a thumbprint with spaces, and sometimes with a leading invisible mark that
    # pastes as a stray character; keep hex only.
    $normalized = ((($Thumbprint -replace '[^0-9a-fA-F]', '')).ToUpperInvariant())
    if ($normalized.Length -eq 0) {
        throw ("-Thumbprint contained no hexadecimal characters: " + $Thumbprint)
    }

    $hits = @()
    foreach ($store in @('Cert:\CurrentUser\My', 'Cert:\LocalMachine\My')) {
        if (-not (Test-Path -LiteralPath $store)) { continue }
        $found = @(Get-ChildItem -LiteralPath $store -ErrorAction SilentlyContinue |
            Where-Object { $_.Thumbprint -eq $normalized })
        foreach ($c in $found) { $hits += [pscustomobject]@{ Certificate = $c; Source = ('store ' + $store) } }
    }
    if (@($hits).Count -eq 0) {
        throw ("no certificate with thumbprint " + $normalized +
               " was found in Cert:\CurrentUser\My or Cert:\LocalMachine\My.")
    }
    return @($hits)[0]
}

function Test-CodeSigningEku {
    # $true when the certificate carries the code-signing EKU (1.3.6.1.5.5.7.3.3), or carries
    # no EKU extension at all (which means "no restriction", not "not allowed").
    param([Parameter(Mandatory)] $Certificate)
    $ekus = @($Certificate.Extensions | Where-Object {
        $_ -is [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] })
    if (@($ekus).Count -eq 0) { return $true }
    foreach ($e in $ekus) {
        foreach ($oid in @($e.EnhancedKeyUsages)) {
            if ($oid.Value -eq '1.3.6.1.5.5.7.3.3') { return $true }
        }
    }
    return $false
}

function Get-SignatureRow {
    # One verification row per file, always via Get-AuthenticodeSignature so the report says
    # what WINDOWS thinks, not what this script hoped.
    #
    # THIS IS THE ONLY RELIABLE PROOF, and the reason the fail-closed gate is here rather than
    # on the signing call. Set-AuthenticodeSignature FAILS OPEN: measured across sixteen
    # extensions on Windows PowerShell 5.1 it never threw -- not even for file types with no
    # Subject Interface Package, where it wrote zero bytes -- and it returned the same
    # `UnknownError` status for genuinely-signed files and silent no-ops alike. Neither a
    # try/catch nor its return value distinguishes the two. Re-reading the file does.
    #
    # Get-AuthenticodeSignature itself THROWS on a file type Windows cannot sign, so the throw
    # is caught and recorded as a failing row rather than allowed to abort the sweep: a report
    # that stops at the first unsignable file is exactly the report an operator cannot act on.
    param([Parameter(Mandatory)] $File)
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $File.Full -ErrorAction Stop
    } catch {
        return [pscustomobject]@{
            Rel        = $File.Rel
            Full       = $File.Full
            Status     = 'Unreadable'
            Message    = ('Get-AuthenticodeSignature could not read a signature from this file: ' + $_.Exception.Message)
            Signer     = ''
            Thumbprint = ''
        }
    }
    $subject = ''
    $thumb = ''
    if ($null -ne $sig.SignerCertificate) {
        $subject = [string]$sig.SignerCertificate.Subject
        $thumb = [string]$sig.SignerCertificate.Thumbprint
    }
    return [pscustomobject]@{
        Rel        = $File.Rel
        Full       = $File.Full
        Status     = [string]$sig.Status
        Message    = [string]$sig.StatusMessage
        Signer     = $subject
        Thumbprint = $thumb
    }
}

function Write-SignatureReport {
    # The sweep the operator is entitled to see: one line per file, Windows' own verdict.
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Row)
    Write-Line
    Write-Line '  STATUS        FILE'
    Write-Line '  ------        ----'
    foreach ($r in $Row) {
        Write-Line ('  ' + $r.Status.PadRight(13) + ' ' + $r.Rel)
    }
}

# --- host gate -------------------------------------------------------------

if (-not (Test-SignOnWindows)) {
    Write-Line
    Write-Line 'powershell-lsp sign-plugin: this host is not Windows.'
    Write-Line
    Write-Line '  Authenticode is a Windows code-signing construct: Set-AuthenticodeSignature and'
    Write-Line '  Get-AuthenticodeSignature exist only on Windows, and the AllSigned / WDAC policies'
    Write-Line '  this script exists to satisfy are Windows policies. Nothing was read and nothing'
    Write-Line '  was written. Run it on the managed Windows machine that needs the signatures.'
    Write-Line
    exit 2
}

# --- resolve the surface ---------------------------------------------------

if ([string]::IsNullOrWhiteSpace($PluginRoot)) { $PluginRoot = (Split-Path -Parent $PSScriptRoot) }
if (-not (Test-Path -LiteralPath $PluginRoot -PathType Container)) {
    Write-FatalError ('-PluginRoot does not name a directory: ' + $PluginRoot)
}
$PluginRoot = (Resolve-Path -LiteralPath $PluginRoot).ProviderPath

$roots = @()
$surfaceLabel = ''
# @($Path).Count is 1 -- not 0 -- when -Path is unbound, because @($null) is a one-element
# array holding $null. Filtering for real values is the only test that distinguishes
# "no -Path given" from "-Path given", and getting it wrong hands the enumerator an empty
# string and takes down the run before a single file is read.
$explicitPath = @($Path | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if (@($explicitPath).Count -gt 0) {
    $roots = $explicitPath
    $surfaceLabel = (@($explicitPath) -join '; ') + '  (-Path override; recursive; .ps1, .psm1)'
} else {
    $roots = @((Join-Path $PluginRoot 'scripts'))
    $surfaceLabel = 'scripts/  (recursive; .ps1, .psm1 -- the executable surface)'
}

$files = @(Get-SigningSurfaceFile -Root $roots -RelativeTo $PluginRoot)

Write-Line
Write-Line 'powershell-lsp sign-plugin -- Authenticode signing with YOUR organization certificate'
Write-Line
Write-Line ('  plugin root : ' + $PluginRoot)
Write-Line ('  surface     : ' + $surfaceLabel)
Write-Line ('  files found : ' + @($files).Count)

if (@($files).Count -eq 0) {
    # A zero-file surface must never report success: an empty sweep is the shape in which
    # "every file is signed" is true and meaningless.
    Write-FatalError ('the surface is EMPTY -- no .ps1 or .psm1 found under ' +
                    (@($roots) -join '; ') + '. Point -PluginRoot at an installed plugin copy, or pass -Path.')
}

# --- verify-only path ------------------------------------------------------

if ($VerifyOnly) {
    Write-Line '  mode        : VERIFY ONLY (nothing is signed, nothing is written)'
    $rows = @(foreach ($f in $files) { Get-SignatureRow -File $f })
    Write-SignatureReport -Row $rows
    $bad = @($rows | Where-Object { $_.Status -ne 'Valid' })
    Write-Line
    Write-Line ('  ' + @($rows).Count + ' checked, ' + (@($rows).Count - @($bad).Count) + ' Valid, ' + @($bad).Count + ' not Valid.')
    Write-Line
    if (@($bad).Count -gt 0) {
        foreach ($b in @($bad)) { Write-Line ('  not Valid: ' + $b.Rel + ' -- ' + $b.Status + ': ' + $b.Message) }
        Write-Line
        exit 1
    }
    exit 0
}

# --- resolve the certificate ----------------------------------------------

try {
    $resolved = Resolve-SigningCertificate -Thumbprint $Thumbprint -PfxPath $PfxPath -PfxPassword $PfxPassword
} catch {
    Write-FatalError ($_.Exception.Message)
}
$cert = $resolved.Certificate

if (-not $cert.HasPrivateKey) {
    Write-FatalError ('the certificate ' + $cert.Thumbprint + ' has no accessible private key, so it cannot sign. ' +
                    'Import the PFX (private key included) into your certificate store, or pass -PfxPath.')
}
if (-not (Test-CodeSigningEku -Certificate $cert)) {
    Write-FatalError ('the certificate ' + $cert.Thumbprint + ' does not carry the Code Signing EKU ' +
                    '(1.3.6.1.5.5.7.3.3). Windows will refuse signatures made with it. Use your organization''s ' +
                    'code-signing certificate.')
}

Write-Line ('  certificate : ' + $cert.Subject)
Write-Line ('                thumbprint ' + $cert.Thumbprint + '  (' + $resolved.Source + ')')
Write-Line ('                not after  ' + $cert.NotAfter.ToString('yyyy-MM-dd'))
if ($NoTimestamp) {
    Write-Line '  timestamp   : NONE (-NoTimestamp) -- signatures expire with the certificate'
} else {
    Write-Line ('  timestamp   : ' + $TimestampServer)
}
Write-Line ('  hash        : ' + $HashAlgorithm)

# --- sign ------------------------------------------------------------------

Write-Line
Write-Line '  signing...'
$failures = New-Object 'System.Collections.Generic.List[object]'
foreach ($f in $files) {
    $signArgs = @{
        LiteralPath   = $f.Full
        Certificate   = $cert
        HashAlgorithm = $HashAlgorithm
        ErrorAction   = 'Stop'
    }
    if (-not $NoTimestamp) { $signArgs['TimestampServer'] = $TimestampServer }
    # The catch is defensive only. Set-AuthenticodeSignature does not raise a terminating error
    # for a file it declines to sign, and its returned Status is `UnknownError` for both a real
    # signature made with an untrusted-on-this-machine root and a silent no-op -- so nothing
    # here can be the gate. The Get-AuthenticodeSignature sweep below is the gate. See the
    # comment on Get-SignatureRow.
    try {
        [void](Set-AuthenticodeSignature @signArgs)
    } catch {
        $failures.Add([pscustomobject]@{ Rel = $f.Rel; Reason = $_.Exception.Message })
    }
}

# --- verify (the sweep the acceptance rests on) ----------------------------

$rows = @(foreach ($f in $files) { Get-SignatureRow -File $f })
Write-SignatureReport -Row $rows

$bad = @($rows | Where-Object { $_.Status -ne 'Valid' })
Write-Line
Write-Line ('  ' + @($files).Count + ' files, ' + (@($rows).Count - @($bad).Count) + ' Valid, ' + @($bad).Count + ' not Valid.')

# $failures is a generic List[object]: the array subexpression operator throws "Argument types
# do not match" on one, so its own .Count (always an int, never the scalar trap) is used instead.
if ($failures.Count -gt 0) {
    Write-Line
    Write-Line '  SIGNING ERRORS:'
    foreach ($x in $failures.ToArray()) { Write-Line ('    ' + $x.Rel + ' -- ' + $x.Reason) }
}

if (@($bad).Count -gt 0 -or $failures.Count -gt 0) {
    Write-Line
    Write-Line '  FAILED CLOSED. Not every file in the surface reports Valid:'
    foreach ($b in @($bad)) { Write-Line ('    ' + $b.Rel + ' -- ' + $b.Status + ': ' + $b.Message) }
    Write-Line
    Write-Line '  The usual causes, in order of likelihood:'
    Write-Line '    * The signing certificate''s root is not trusted ON THIS MACHINE. Signing succeeded,'
    Write-Line '      but verification cannot build a trusted chain, so Windows reports UnknownError.'
    Write-Line '      Verify again on a machine that trusts your organization root -- the target estate does.'
    Write-Line '    * The certificate expired, was revoked, or lacks the Code Signing EKU.'
    Write-Line '    * A file was read-only, held open by another process, or quarantined by AV'
    Write-Line '      mid-run (status Unreadable means Windows could not read a signature back).'
    Write-Line
    exit 1
}

Write-Line
Write-Line '  Every file in the surface is Authenticode-signed and reports Valid.'
Write-Line '  Re-run after every plugin upgrade: an upgrade replaces these files with unsigned copies.'
Write-Line
exit 0
