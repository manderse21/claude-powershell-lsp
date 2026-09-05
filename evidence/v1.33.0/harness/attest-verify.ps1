#Requires -Version 5.1
# attest-verify.ps1 -- post-tag published-attestation verification at the 000245
# standard, against the REAL v1.33.0 release assets. Dispatch 000273. ASCII only.
#
# THE ORPHAN PROBLEM, and why the exit code alone is not the verdict here.
#
# The v1.33.0 release split: producing run 32585972425 attested its artifacts and
# then FAILED at release-create, leaving those attestations ORPHANED in the store.
# Run 32588047316 later rebuilt and published. `git archive` of the target commit is
# DETERMINISTIC, so the tarball is BIT-IDENTICAL between the two runs -- and both
# runs' attestations therefore name the SAME subject digest.
#
# Measured consequence: `gh attestation verify <tarball>` returns TWO attestations
# and exits 0. The 000245 rule "treat the EXIT CODE as the verdict" is necessary but
# NOT sufficient once an orphan shares a subject digest: exit 0 says "some trusted
# attestation covers these bytes", not "the attestation from the run that published
# them". So this harness binds explicitly with --source-digest and then ASSERTS the
# returned invocationId, rather than inferring a binding from a zero.
#
# --source-digest binds the SOURCE REPOSITORY commit the workflow ran from -- which
# is MAIN's tip, not the release target. That is recorded as a bound, not papered
# over: see the note the script emits.

param(
    [string] $Repo    = 'manderse21/claude-powershell-lsp',
    [string] $Tag     = 'v1.33.0',
    [string] $Dir     = 'C:\Users\mande\AppData\Local\Temp\psl-273\rel',
    [string] $GoodRun = '32588047316',
    [string] $OrphanRun = '32585972425',
    [string] $GoodSourceDigest   = 'b3faaf1206831d217ce185adab6708a092afe982',
    [string] $OrphanSourceDigest = '66b9522433a102b103421dcac40b7aea26a8491e',
    [string] $SignerWorkflow = 'manderse21/claude-powershell-lsp/.github/workflows/powershell-lsp-release.yml',
    [string] $JsonOut = 'C:\Users\mande\AppData\Local\Temp\psl-273\out\attestation-verify.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Sha256([string] $p) { return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower() }

function Get-Statements([string[]] $ghArgs) {
    # Returns @{ exit = <int>; statements = @(...) }. --format json ONLY; the human
    # output is empty when redirected (000245 rule) so it is never read.
    $raw = & gh @ghArgs 2>&1
    $rc = $LASTEXITCODE
    $st = @()
    if ($rc -eq 0) {
        try { $st = @(($raw | ConvertFrom-Json) | ForEach-Object { $_.verificationResult.statement }) } catch { $st = @() }
    }
    return @{ exit = $rc; statements = $st; raw = ($raw -join "`n") }
}

# ---- the release's own reported digests, from the REST API (not from the file) ----
$rel = & gh release view $Tag --repo $Repo --json assets,targetCommitish | ConvertFrom-Json
$apiDigest = @{}
foreach ($a in $rel.assets) {
    $d = $null
    if ($a.PSObject.Properties['digest']) { $d = [string]$a.digest }
    $apiDigest[$a.name] = $d
}

$results = @()
$failures = @()

foreach ($f in (Get-ChildItem -LiteralPath $Dir -File | Sort-Object Name)) {
    Write-Output ''
    Write-Output ('================ ' + $f.Name + ' ================')
    $sha = Get-Sha256 $f.FullName
    Write-Output ('  sha256            : ' + $sha)
    Write-Output ('  bytes             : ' + $f.Length)

    # (1) the file we verify is the file the Release serves
    $api = $apiDigest[$f.Name]
    $apiMatch = $null
    if ($api) {
        $apiMatch = ($api.ToLower().Replace('sha256:', '') -ceq $sha)
        Write-Output ('  Release API digest: ' + $api + '  match=' + $apiMatch)
    } else {
        Write-Output '  Release API digest: (not reported by this gh version)'
    }

    # (2) baseline verify -- the 000245 exit-code verdict
    $base = Get-Statements @('attestation', 'verify', $f.FullName, '--repo', $Repo, '--format', 'json')
    $baseIds = @($base.statements | ForEach-Object { $_.predicate.runDetails.metadata.invocationId })
    Write-Output ('  verify exit       : ' + $base.exit + '   attestations returned: ' + $base.statements.Count)
    foreach ($id in $baseIds) { Write-Output ('     <- ' + $id) }
    $orphanAlsoMatches = @($baseIds | Where-Object { $_ -like ('*/runs/' + $OrphanRun + '/*') }).Count -gt 0
    if ($orphanAlsoMatches) {
        Write-Output ('  NOTE: the ORPHAN run ' + $OrphanRun + ' also attests this exact digest -- exit 0 alone does NOT bind to the publishing run.')
    }

    # (3) THE BINDING: constrain to the publishing run's source commit
    $bound = Get-Statements @('attestation', 'verify', $f.FullName, '--repo', $Repo,
        '--source-digest', $GoodSourceDigest, '--signer-workflow', $SignerWorkflow, '--format', 'json')
    $boundIds = @($bound.statements | ForEach-Object { $_.predicate.runDetails.metadata.invocationId })
    $boundToGood = ($bound.exit -eq 0 -and $boundIds.Count -eq 1 -and $boundIds[0] -like ('*/runs/' + $GoodRun + '/*'))
    Write-Output ('  BOUND verify exit : ' + $bound.exit + '   returned: ' + $boundIds.Count + '   binds-to-' + $GoodRun + '=' + $boundToGood)
    foreach ($id in $boundIds) { Write-Output ('     -> ' + $id) }

    # (4) subject coverage inside the bound statement
    $subjOk = $false
    if ($bound.statements.Count -ge 1) {
        $subs = @($bound.statements[0].subject | Where-Object { $_.digest.sha256 -ceq $sha })
        $subjOk = ($subs.Count -eq 1)
        Write-Output ('  subject covers this digest exactly once: ' + $subjOk +
                      '   (statement carries ' + $bound.statements[0].subject.Count + ' subjects)')
    }

    $pass = ($base.exit -eq 0 -and $boundToGood -and $subjOk -and ($null -eq $apiMatch -or $apiMatch))
    if (-not $pass) { $failures += ($f.Name + ': baseline=' + $base.exit + ' bound=' + $boundToGood + ' subject=' + $subjOk + ' api=' + $apiMatch) }
    Write-Output ('  VERDICT           : ' + $(if ($pass) { 'PASS' } else { 'FAIL' }))

    $results += [ordered]@{
        asset = $f.Name
        bytes = $f.Length
        sha256 = $sha
        release_api_digest = $api
        release_api_digest_matches = $apiMatch
        baseline_verify_exit = $base.exit
        baseline_attestations_returned = $base.statements.Count
        baseline_invocation_ids = $baseIds
        orphan_also_attests_this_digest = $orphanAlsoMatches
        bound_verify_exit = $bound.exit
        bound_invocation_ids = $boundIds
        binds_to_publishing_run = $boundToGood
        subject_covers_digest_once = $subjOk
        verdict = $(if ($pass) { 'PASS' } else { 'FAIL' })
    }
}

# ---------------------------------------------------------------- RED controls
Write-Output ''
Write-Output '================ RED CONTROLS ================'
$tar = Join-Path $Dir 'powershell-lsp-1.33.0.tar.gz'
$reds = @()

# R1 -- wrong repository: the lookup must fail.
$r = Get-Statements @('attestation', 'verify', $tar, '--repo', 'manderse21/claude-skills', '--format', 'json')
$ok = ($r.exit -ne 0)
Write-Output ('  R1 wrong repo                      exit=' + $r.exit + '  -> ' + $(if ($ok) { 'PASS' } else { 'FAIL' }))
$reds += [ordered]@{ control = 'wrong repository'; exit = $r.exit; expected = 'non-zero'; pass = $ok }

# R2 -- one bit flipped: the attestation must bind THESE bytes, not merely this repo.
$mut = Join-Path $Dir 'MUTANT.tar.gz'
$bytes = [IO.File]::ReadAllBytes($tar)
$bytes[100] = $bytes[100] -bxor 0x01
[IO.File]::WriteAllBytes($mut, $bytes)
try {
    $r = Get-Statements @('attestation', 'verify', $mut, '--repo', $Repo, '--format', 'json')
    $ok = ($r.exit -ne 0)
    Write-Output ('  R2 one bit flipped at byte 100     exit=' + $r.exit + '  -> ' + $(if ($ok) { 'PASS' } else { 'FAIL' }) +
                  '   (mutant sha256 ' + (Get-Sha256 $mut).Substring(0, 16) + '...)')
    $reds += [ordered]@{ control = 'one bit flipped at byte 100'; exit = $r.exit; expected = 'non-zero'; pass = $ok }
} finally { Remove-Item -LiteralPath $mut -Force -ErrorAction SilentlyContinue }

# R3 -- correct repo, WRONG signer workflow: exercises attribution, not lookup.
$r = Get-Statements @('attestation', 'verify', $tar, '--repo', $Repo,
    '--signer-workflow', 'manderse21/claude-powershell-lsp/.github/workflows/powershell-lsp-ci.yml', '--format', 'json')
$ok = ($r.exit -ne 0)
Write-Output ('  R3 wrong signer-workflow           exit=' + $r.exit + '  -> ' + $(if ($ok) { 'PASS' } else { 'FAIL' }))
$reds += [ordered]@{ control = 'wrong signer-workflow'; exit = $r.exit; expected = 'non-zero'; pass = $ok }

# R4 -- THE DISCRIMINATOR CONTROL. If --source-digest did not actually select, the
# positive binding above would be decoration. Pin it to the ORPHAN's source commit:
# it must succeed AND return ONLY the orphan. That proves the flag discriminates in
# both directions on the very digest that carries two attestations.
$r = Get-Statements @('attestation', 'verify', $tar, '--repo', $Repo,
    '--source-digest', $OrphanSourceDigest, '--format', 'json')
$ids = @($r.statements | ForEach-Object { $_.predicate.runDetails.metadata.invocationId })
$ok = ($r.exit -eq 0 -and $ids.Count -eq 1 -and $ids[0] -like ('*/runs/' + $OrphanRun + '/*'))
Write-Output ('  R4 --source-digest = ORPHAN commit  exit=' + $r.exit + '  returned=' + $ids.Count + '  -> ' + $(if ($ok) { 'PASS' } else { 'FAIL' }))
foreach ($id in $ids) { Write-Output ('       ' + $id) }
$reds += [ordered]@{ control = '--source-digest pinned to the ORPHAN source commit selects ONLY the orphan'
                     exit = $r.exit; returned = $ids.Count; invocation_ids = $ids; expected = 'exit 0, exactly the orphan'; pass = $ok }

$redFail = @($reds | Where-Object { -not $_.pass })

# ---------------------------------------------------------------- summary
$verdict = $(if ($failures.Count -eq 0 -and $redFail.Count -eq 0) { 'PASS' } else { 'FAIL' })
$out = [ordered]@{
    gate = 'post-tag published-attestation verification at the 000245 standard'
    tag = $Tag
    repo = $Repo
    release_target = $(if ($rel.PSObject.Properties['targetCommitish']) { $rel.targetCommitish } else { $null })
    publishing_run = $GoodRun
    orphaned_run = $OrphanRun
    publishing_run_source_digest = $GoodSourceDigest
    orphaned_run_source_digest = $OrphanSourceDigest
    method = 'gh attestation verify --format json; EXIT CODE is the verdict (000245), but exit 0 is NOT sufficient where an orphan shares a subject digest, so each asset is additionally BOUND with --source-digest + --signer-workflow and the returned invocationId is asserted.'
    bound_by = '--source-digest (the SOURCE REPOSITORY commit the workflow ran from) + --signer-workflow'
    known_bound = 'SLSA provenance records the WORKFLOW source commit (main tip), NOT the release target commit. The attestation therefore does not, by itself, bind the artifact to the release target; that binding comes from the Release object and the signed tag.'
    assets = $results
    red_controls = $reds
    verdict = $verdict
}
($out | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $JsonOut -Encoding UTF8

Write-Output ''
Write-Output '================ SUMMARY ================'
foreach ($r in $results) { Write-Output (('  {0,-6}' -f $r.verdict) + $r.asset) }
Write-Output ('  RED controls: ' + ($reds.Count - $redFail.Count) + ' of ' + $reds.Count + ' PASS')
Write-Output ('  GATE: ' + $verdict)
if ($verdict -ne 'PASS') { throw 'ATTESTATION GATE FAILED' }
