#Requires -Version 5.1
# license-gate.ps1 -- the LICENSE / continuity functional gate.
#
# Dispatch 000273 (freeze 1B). ASCII only.
#
# Re-run at C' because PR #188 touched exactly these files. The gate the charter
# names is "(a) LICENSE is Apache-2.0 and CONTINUITY matches a shipped-Apache-2.0
# release", so both halves are asserted -- and the second half is what FAILED at C.
#
# Every assertion runs against the STAGED tree (already proven byte-identical to
# the target commit), so this gate and the equality proof describe the same bytes.

param(
    [string] $Root = 'C:\Users\mande\AppData\Local\Temp\psl-273\root',
    [string] $Commit = '6ab2d24bf254787520ad9449c4e6c17f74ee708d',
    [string] $Out = 'C:\Users\mande\AppData\Local\Temp\psl-273\out',
    # THE APACHE-2.0 START VERSION IS A FIXED HISTORICAL FACT, NOT THE VERSION BEING
    # RELEASED. Dispatch 000273 found this gate asserting `from v<the version being
    # released>`, which was correct only for v1.32.0 -- the one release where the
    # relicense actually happened -- and turns into a false FAIL on every release
    # after it. At C the four documents correctly read "forward-only, effective from
    # v1.32.0"; naming v1.33.0 as the start would be factually WRONG, so the gate was
    # demanding a regression. Both bounds below are now fixed constants, which is what
    # an irrevocable grant boundary is.
    [string] $ApacheStartVersion = '1.32.0',
    [string] $GplBand = 'v1.6.1 through v1.31.2',
    [switch] $RedControl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The documents that carry the relicense statement. Single-sourced so the vacuity
# floor below is derived from this list rather than hardcoded beside it.
$script:RelicenseDocs = @('README.md', 'CONTINUITY.md', 'TRUST.md', 'docs/CONTINUITY.md')

function Get-Text([string] $rel) {
    $p = Join-Path $Root $rel
    if (-not (Test-Path -LiteralPath $p)) { throw ('missing: ' + $rel) }
    return [IO.File]::ReadAllText($p)
}

function Test-Gate {
    $findings = @()
    $checks = @()

    # --- 1. LICENSE is really the Apache-2.0 text, not a file that mentions it ---
    $lic = Get-Text 'LICENSE'
    $isApache = ($lic -match 'Apache License') -and ($lic -match 'Version 2\.0, January 2004') -and
                ($lic -match 'http://www\.apache\.org/licenses/') -and ($lic.Length -gt 10000)
    $checks += @{ name = 'LICENSE is the Apache-2.0 text'; ok = $isApache; detail = ('chars=' + $lic.Length) }
    if (-not $isApache) { $findings += 'LICENSE is not the Apache-2.0 text' }

    # --- 2. the manifests declare Apache-2.0 -----------------------------------
    $pj = (Get-Text '.claude-plugin/plugin.json') | ConvertFrom-Json
    $licOk = ($pj.license -ceq 'Apache-2.0')
    $checks += @{ name = 'plugin.json license == Apache-2.0'; ok = $licOk; detail = ('license=' + $pj.license) }
    if (-not $licOk) { $findings += ('plugin.json declares ' + $pj.license) }

    $ver = [string]$pj.version
    $checks += @{ name = 'plugin.json version is stamped'; ok = ($ver -match '^\d+\.\d+\.\d+$'); detail = ('version=' + $ver) }

    # --- 3. NOTICE names Apache-2.0 --------------------------------------------
    $notice = Get-Text 'NOTICE'
    $nOk = ($notice -match 'Apache License, Version 2\.0')
    $checks += @{ name = 'NOTICE names Apache-2.0'; ok = $nOk; detail = '' }
    if (-not $nOk) { $findings += 'NOTICE does not name Apache-2.0' }

    # --- 4. CONTINUITY matches a SHIPPED Apache-2.0 release --------------------
    # This is the half that failed at C. Two defects are tested for, in the four
    # documents that carry the relicense statement:
    #   (a) deixis that re-points once the tag exists ("the next release")
    #   (b) a GPL band bounded by a moving edge ("through the current release"),
    #       which sweeps this very release into the GPL band
    $docs = @($script:RelicenseDocs)
    foreach ($d in $docs) {
        $t = [regex]::Replace((Get-Text $d), '\s+', ' ')   # normalize wrapping
        $nextRel = ($t -match 'Apache-2\.0[^.]{0,60}from the next release') -or
                   ($t -match 'forward-only[^.]{0,20}from the next release') -or
                   ($t -match 'effective from the next release')
        $curRel  = ($t -match 'v1\.6\.1 through the current release')
        $ok = (-not $nextRel) -and (-not $curRel)
        $checks += @{
            name = ($d + ': no moving-edge relicense deixis')
            ok = $ok
            detail = ('next-release=' + $nextRel + ' current-release=' + $curRel)
        }
        if ($nextRel) { $findings += ($d + ' still says the relicense starts at "the next release"') }
        if ($curRel)  { $findings += ($d + ' still bounds the GPL band at "the current release"') }
    }

    # --- 5. the positive claim, not just the absence of the bad one ------------
    # An absence test alone would pass on a document that dropped the statement
    # entirely, so require each document to name the Apache-2.0 start version and
    # the GPL band's fixed upper bound.
    foreach ($d in $docs) {
        $t = [regex]::Replace((Get-Text $d), '\s+', ' ')
        $namesStart = ($t -match ('from v' + [regex]::Escape($ApacheStartVersion)))
        $namesBand  = ($t -match [regex]::Escape($GplBand))
        $ok = $namesStart -and $namesBand
        $checks += @{
            name = ($d + ': names the Apache-2.0 start version and the fixed GPL band')
            ok = $ok
            detail = ('names-v' + $ApacheStartVersion + '=' + $namesStart + ' names-band=' + $namesBand)
        }
        if (-not $namesStart) { $findings += ($d + ' does not name v' + $ApacheStartVersion + ' as the Apache-2.0 start') }
        if (-not $namesBand)  { $findings += ($d + ' does not bound the GPL band at ' + $GplBand) }
    }

    # --- 6. CHANGELOG agreement ------------------------------------------------
    $cl = [regex]::Replace((Get-Text 'CHANGELOG.md'), '\s+', ' ')
    $clOk = ($cl -match 'From this release forward the project is')
    $checks += @{ name = 'CHANGELOG states the relicense takes effect at this release'; ok = $clOk; detail = '' }
    if (-not $clOk) { $findings += 'the CHANGELOG no longer states the relicense takes effect at this release' }

    return [pscustomobject]@{ checks = $checks; findings = $findings; pass = ($findings.Count -eq 0); version = $ver }
}

$r = Test-Gate
Write-Host ('=== LICENSE / continuity gate at ' + $Commit.Substring(0, 12) + ' (version ' + $r.version + ') ===')
foreach ($c in $r.checks) {
    Write-Host (('  {0,-5}' -f $(if ($c.ok) { 'PASS' } else { 'FAIL' })) + $c.name + $(if ($c.detail) { '  [' + $c.detail + ']' } else { '' }))
}
if ($r.findings.Count -gt 0) { $r.findings | ForEach-Object { Write-Host ('  FINDING: ' + $_) } }

# Vacuity floor: the gate must have actually looked at something.
# Floor DERIVED from the gate's own shape, not guessed: 4 fixed checks (LICENSE
# text, plugin.json license, version stamped, NOTICE) + 2 per relicense document
# (absence of the moving edge, presence of the fixed one) + 1 CHANGELOG check.
$expectedChecks = 4 + (2 * $script:RelicenseDocs.Count) + 1
if ($r.checks.Count -lt $expectedChecks) {
    throw ('the gate ran ' + $r.checks.Count + ' checks, expected at least ' + $expectedChecks +
           ' -- it is not examining the real document set')
}

$report = [ordered]@{
    gate = 'Apache-2.0 LICENSE + continuity'
    commit = $Commit
    version = $r.version
    checks = @($r.checks | ForEach-Object { [ordered]@{ name = $_.name; ok = $_.ok; detail = $_.detail } })
    findings = $r.findings
    verdict = $(if ($r.pass) { 'PASS' } else { 'FAIL' })
}
($report | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $Out 'license-gate.json') -Encoding UTF8

# --- RED control --------------------------------------------------------------
# Restore the C-era sentence into one document and require the gate to go red, so
# a PASS here is a real discrimination rather than a check that cannot fail.
if ($RedControl) {
    $victim = Join-Path $Root 'CONTINUITY.md'
    $orig = [IO.File]::ReadAllText($victim)
    try {
        $mut = $orig.Replace('(forward-only from v1.32.0)', '(forward-only from the next release)')
        if ($mut -ceq $orig) { throw 'RED CONTROL SETUP FAILED: the anchor sentence was not found to mutate' }
        [IO.File]::WriteAllText($victim, $mut)
        $red = Test-Gate
        Write-Host ('[RED control] C-era wording restored in CONTINUITY.md -> pass=' + $red.pass + ' findings=' + $red.findings.Count)
        if ($red.pass) { throw 'RED CONTROL FAILED: the gate still passes with the C-era deixis restored -- it is vacuous' }
    } finally {
        [IO.File]::WriteAllText($victim, $orig)
    }
    $back = Test-Gate
    Write-Host ('[RED control restored] pass=' + $back.pass)
    if (-not $back.pass) { throw 'RED CONTROL FAILED: the tree did not restore' }
}

Write-Host ''
Write-Host ('LICENSE / CONTINUITY GATE: ' + $report['verdict'])
if (-not $r.pass) { throw 'LICENSE / CONTINUITY GATE FAILED' }
