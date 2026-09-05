#Requires -Version 5.1
# sig-verify.ps1 -- the SIGNATURE half of the 000245 post-tag standard: the
# gitsign/Sigstore signature on the v1.33.0 tag. Dispatch 000273. ASCII only.
#
# WHY gitsign IS INVOKED WITH AN EXPLICIT WorkingDirectory. gitsign is a Go binary
# and has no `-C`; it reads the PROCESS working directory. Set-Location does not
# reliably move that for a native child, so the repo is bound on the
# ProcessStartInfo instead. Run from the wrong directory it fails with "reference
# not found", which is an ENVIRONMENT error that reads exactly like a missing tag.
#
# WHY `gitsign verify-tag` AND NOT `git verify-tag`. `git verify-tag` reports
# "Validated Certificate claims: FALSE" and warns that it does not verify cert
# claims -- so it proves the signature and the Rekor entry but NOT who signed.
# `gitsign verify-tag --certificate-identity/--certificate-oidc-issuer` closes that,
# and the RED control below proves the identity check actually rejects.

param(
    [string] $Repo = 'C:\Users\mande\projects\work\nortam\claude-powershell-lsp',
    [string] $Tag  = 'v1.33.0',
    [string] $Identity = 'https://github.com/manderse21/claude-powershell-lsp/.github/workflows/powershell-lsp-release.yml@refs/heads/main',
    [string] $Issuer = 'https://token.actions.githubusercontent.com',
    [string] $WrongIdentity = 'https://github.com/manderse21/claude-powershell-lsp/.github/workflows/powershell-lsp-ci.yml@refs/heads/main',
    [string] $ControlTag = 'v1.24.3',
    [string] $JsonOut = 'C:\Users\mande\AppData\Local\Temp\psl-273\out\signature-verify.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Gitsign([string[]] $ArgList) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Command gitsign -ErrorAction Stop).Source
    $psi.WorkingDirectory = $Repo
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($a in $ArgList) { $psi.ArgumentList.Add($a) }
    $p = [System.Diagnostics.Process]::Start($psi)
    $so = $p.StandardOutput.ReadToEnd(); $se = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return @{ exit = $p.ExitCode; out = ($so + $se) }
}

# --- tag object facts, independent of any signature check ---------------------
$type  = (& git -C $Repo cat-file -t ("refs/tags/" + $Tag)).Trim()
$peel  = (& git -C $Repo rev-parse ($Tag + '^{}')).Trim()
$body  = @(& git -C $Repo cat-file -p ("refs/tags/" + $Tag))
$tagger = ($body | Where-Object { $_ -like 'tagger *' } | Select-Object -First 1)
$hasSig = [bool](@($body | Select-String -SimpleMatch 'BEGIN SIGNED MESSAGE').Count)

Write-Output ('tag object type : ' + $type)
Write-Output ('peels to        : ' + $peel)
Write-Output ('tagger          : ' + $tagger)
Write-Output ('carries sig     : ' + $hasSig)
if ($type -cne 'tag') { throw ($Tag + ' is not an annotated tag object -- a lightweight tag cannot be signed') }

# --- GREEN: full verification including certificate claims --------------------
$g = Invoke-Gitsign @('verify-tag', $Tag, '--certificate-identity', $Identity, '--certificate-oidc-issuer', $Issuer)
Write-Output ''
Write-Output ('GREEN gitsign verify-tag exit=' + $g.exit)
foreach ($l in ($g.out -split "`n")) { if ($l.Trim()) { Write-Output ('  ' + $l.TrimEnd()) } }
$claims = [bool]($g.out -match 'Validated Certificate claims:\s*true')
$sigOk  = [bool]($g.out -match 'Validated Git signature:\s*true')
$rekOk  = [bool]($g.out -match 'Validated Rekor entry:\s*true')
$tlog   = $null
if ($g.out -match 'tlog index:\s*(\d+)') { $tlog = $Matches[1] }

# --- RED 1: wrong certificate identity must be REJECTED (attribution, not lookup)
$r1 = Invoke-Gitsign @('verify-tag', $Tag, '--certificate-identity', $WrongIdentity, '--certificate-oidc-issuer', $Issuer)
$r1ok = ($r1.exit -ne 0 -and $r1.out -match 'none of the expected identities matched')
Write-Output ''
Write-Output ('RED 1 wrong cert identity  exit=' + $r1.exit + ' -> ' + $(if ($r1ok) { 'PASS' } else { 'FAIL' }))

# --- RED 2: a tag this pipeline did not gitsign must not verify ---------------
$r2 = Invoke-Gitsign @('verify-tag', $ControlTag)
$r2ok = ($r2.exit -ne 0)
Write-Output ('RED 2 pre-gitsign tag ' + $ControlTag + '  exit=' + $r2.exit + ' -> ' + $(if ($r2ok) { 'PASS' } else { 'FAIL' }))

$pass = ($g.exit -eq 0 -and $claims -and $sigOk -and $rekOk -and $r1ok -and $r2ok -and $hasSig)
$out = [ordered]@{
    gate = 'post-tag TAG SIGNATURE verification (000245 standard, signature half)'
    tag = $Tag
    tag_object_type = $type
    peels_to = $peel
    tagger = $tagger
    carries_signature_block = $hasSig
    verifier = 'gitsign verify-tag (NOT git verify-tag, which reports Validated Certificate claims: false)'
    certificate_identity = $Identity
    certificate_oidc_issuer = $Issuer
    green_exit = $g.exit
    validated_git_signature = $sigOk
    validated_rekor_entry = $rekOk
    validated_certificate_claims = $claims
    rekor_tlog_index = $tlog
    red_controls = @(
        [ordered]@{ control = 'wrong certificate identity'; exit = $r1.exit; expected = 'non-zero + identity mismatch'; pass = $r1ok }
        [ordered]@{ control = ('a pre-gitsign tag (' + $ControlTag + ')'); exit = $r2.exit; expected = 'non-zero'; pass = $r2ok }
    )
    verdict = $(if ($pass) { 'PASS' } else { 'FAIL' })
}
($out | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $JsonOut -Encoding UTF8
Write-Output ''
Write-Output ('SIGNATURE GATE: ' + $out.verdict)
if (-not $pass) { throw 'SIGNATURE GATE FAILED' }
