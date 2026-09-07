#Requires -Version 5.1

# PowerShellLsp.DocClaims.Tests.ps1 -- THE DOC-CLAIMS GUARD (dispatch 000177 leg 7).
#
# Derives every number in tests/doc-claims.psd1 from disk and fails when a document disagrees with
# the thing it describes. The registry carries the claims; this file carries only the machinery, so
# adding a claim is one row in the data file and never an edit here.
#
# The rationale, the derivation kinds, and the "mechanically derivable only" constraint are
# documented in tests/doc-claims.psd1. Read that first.
#
# THREE THINGS THIS FILE ASSERTS, in ascending order of how easily they are faked:
#   1. Every registered claim matches its derivation.                      (the guard)
#   2. The guard REPORTS A MISMATCH when a guarded number is perturbed.    (the RED control)
#   3. The guard FAILS when its pattern matches nothing.                   (the VACUITY control)
#
# (2) and (3) exist because a guard nobody has watched fail is a guard nobody has tested. (3) is
# the more important of the two: without it, deleting the sentence a claim points at would silently
# disarm that claim, and the registry would report green over a document that no longer says
# anything. The zero-sample benchmark defect v1.29.0 fixed is what an unexercised guard looks like
# from the outside, and this file is written not to repeat it.
#
# ASCII-only (PS 5.1 em-dash trap).

# ---------------------------------------------------------------------------
# DISCOVERY PHASE. The registry is read here so each claim becomes its own It,
# named in the output. It reaches the run phase through -ForEach, evaluated at
# discovery -- a discovery-time $script: variable read inside an It body is
# $null, which is precisely how the corpus suite's own selected-count floor
# came to assert nothing (fixed in v1.29.0).
# ---------------------------------------------------------------------------
$DocClaimsCases = @(
    foreach ($c in @((Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'doc-claims.psd1')).Claims)) {
        [pscustomobject]@{
            Name       = [string]$c.Name
            Document   = [string]$c.Document
            Pattern    = [string]$c.Pattern
            Derivation = $c.Derivation
        }
    }
)

Describe 'Doc claims -- every published number matches what it describes' {

    BeforeAll {
        $script:DcRoot = Split-Path -Parent $PSScriptRoot
        $script:DcClaims = @((Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'doc-claims.psd1')).Claims)

        # The corpus derivation is THE scoring enumeration, dot-sourced rather than
        # re-implemented: Get-CorpusCorrectnessReport builds its denominators from exactly this
        # spec list, so a registry row and the published rate cannot drift apart.
        . (Join-Path $script:DcRoot 'tests/corpus/Corpus.Common.ps1')

        function Get-DcNormalizedText {
            # Collapse every whitespace run to one space, so a claim that WRAPS across lines still
            # matches. A single-line regex returning nothing on a phrase which is demonstrably
            # present reads as absence -- the 000176 survey hit exactly that on ROADMAP.md.
            param([string] $Path)
            if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
            return ([System.IO.File]::ReadAllText($Path) -replace '\s+', ' ')
        }

        function Get-DcCapturedInts {
            # Every capture-group-1 integer the pattern finds, plus the distinct set. Returning
            # BOTH lets a caller tell "matched nothing" from "matched contradictory values" --
            # two different failures that must not render alike.
            param([string] $Text, [string] $Pattern)
            $m = @([regex]::Matches($Text, $Pattern))
            $vals = @($m | ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object -Unique)
            return @{ MatchCount = $m.Count; Distinct = $vals }
        }

        function Get-DocClaimDerivedInt {
            # The TRUE value, computed from disk. Always reads the real tree: only the DOCUMENT
            # side is ever redirected (by the controls), never the derivation.
            param($Derivation)
            switch ([string]$Derivation.Kind) {
                'CorpusSpecCount' {
                    $cat = [string]$Derivation.Category
                    return @(@(Get-CorpusSampleSpec) | Where-Object { $_.Category -eq $cat }).Count
                }
                'FileRegexInt' {
                    $p = Join-Path $script:DcRoot ([string]$Derivation.Path)
                    $t = Get-DcNormalizedText -Path $p
                    if ($null -eq $t) { throw "derivation source not found: $p" }
                    $r = Get-DcCapturedInts -Text $t -Pattern ([string]$Derivation.Pattern)
                    if ($r.MatchCount -lt 1) { throw "derivation pattern matched NOTHING in $p" }
                    if (@($r.Distinct).Count -ne 1) {
                        throw ('derivation pattern matched conflicting values in ' + $p + ': ' + (@($r.Distinct) -join ', '))
                    }
                    return [int]@($r.Distinct)[0]
                }
                default { throw "unknown derivation kind '$($Derivation.Kind)'" }
            }
        }

        function Get-DocClaimVerdict {
            # ONE claim, adjudicated. -DocText exists so the controls can feed a PERTURBED document
            # through this exact function while the derivation still reads the real tree -- the
            # control therefore exercises the shipped comparison, not a parallel copy of it.
            param($Claim, [string] $DocText = $null, [switch] $UseDocText)
            $docPath = Join-Path $script:DcRoot ([string]$Claim.Document)
            $verdict = [ordered]@{
                Name    = [string]$Claim.Name; Document = $docPath
                Claimed = $null; Derived = $null; Match = $false; Reason = ''
            }
            $verdict.Derived = Get-DocClaimDerivedInt -Derivation $Claim.Derivation
            $text = if ($UseDocText) { $DocText } else { Get-DcNormalizedText -Path $docPath }
            if ($null -eq $text) { $verdict.Reason = "document not found: $docPath"; return $verdict }
            $r = Get-DcCapturedInts -Text $text -Pattern ([string]$Claim.Pattern)
            if ($r.MatchCount -lt 1) {
                # NOT a pass. A pattern that finds nothing means the claim it guards was reworded
                # or deleted, and the guard must say so rather than wave it through.
                $verdict.Reason = "pattern matched NOTHING in $docPath -- the claim it guards is gone or reworded"
                return $verdict
            }
            if (@($r.Distinct).Count -ne 1) {
                $verdict.Reason = ('document states conflicting values: ' + (@($r.Distinct) -join ', '))
                return $verdict
            }
            $verdict.Claimed = [int]@($r.Distinct)[0]
            $verdict.Match = ($verdict.Claimed -eq $verdict.Derived)
            if (-not $verdict.Match) {
                $verdict.Reason = ('document says ' + $verdict.Claimed + ', disk says ' + $verdict.Derived)
            }
            return $verdict
        }
    }

    It 'the registry is non-empty and every row is well-formed' {
        # The selected-count floor. A registry that failed to load would otherwise produce zero
        # per-claim Its and a green run -- a suite asserting nothing, reported as success.
        @($script:DcClaims).Count | Should -BeGreaterThan 0 -Because 'an empty doc-claims registry guards nothing and must not read as a pass'
        foreach ($c in @($script:DcClaims)) {
            [string]$c.Name | Should -Not -BeNullOrEmpty
            [string]$c.Document | Should -Not -BeNullOrEmpty
            [string]$c.Pattern | Should -Not -BeNullOrEmpty
            [string]$c.Derivation.Kind | Should -BeIn @('CorpusSpecCount', 'FileRegexInt')
        }
    }

    # '<_.Name>' and not '<Name>': key-name expansion is the hashtable form, and these cases are
    # PSCustomObjects on purpose (a hashtable -ForEach splats its keys into the block, which would
    # collide with the local names below). A test that cannot name the claim it checks is far
    # weaker at the moment it goes red, which is the only moment it matters.
    It 'claim holds: <_.Name>' -ForEach $DocClaimsCases {
        $v = Get-DocClaimVerdict -Claim $_
        $because = if ($v.Reason) { $v.Reason } else { 'claimed ' + $v.Claimed + ' vs derived ' + $v.Derived }
        $v.Match | Should -BeTrue -Because ("'" + $_.Name + "' -- " + $because)
    }

    It 'RED CONTROL: a perturbed document is REPORTED as a mismatch, not waved through' {
        # Perturb a guarded number and prove the guard reports it. A guard nobody has watched fail
        # has not been tested. The derivation still reads the real tree, so what is exercised here
        # is the comparison itself.
        $claim = @($script:DcClaims)[0]
        $expected = Get-DocClaimDerivedInt -Derivation $claim.Derivation
        $norm = Get-DcNormalizedText -Path (Join-Path $script:DcRoot ([string]$claim.Document))

        # Baseline FIRST: the unperturbed text must still MATCH, so any failure below is
        # attributable to the perturbation rather than to the harness.
        (Get-DocClaimVerdict -Claim $claim -DocText $norm -UseDocText).Match |
            Should -BeTrue -Because 'the unperturbed text must pass, or the control proves nothing about the perturbation'

        # Splice a deliberately wrong number over capture group 1, by index -- exact, and immune
        # to the digits appearing elsewhere in the match.
        $bad = $expected + 1
        $m = [regex]::Match($norm, [string]$claim.Pattern)
        $m.Success | Should -BeTrue -Because 'the control cannot perturb what it cannot find'
        $g = $m.Groups[1]
        $perturbed = $norm.Substring(0, $g.Index) + [string]$bad + $norm.Substring($g.Index + $g.Length)
        $perturbed | Should -Not -Be $norm -Because 'the perturbation must actually change the document'

        $v = Get-DocClaimVerdict -Claim $claim -DocText $perturbed -UseDocText
        $v.Match | Should -BeFalse -Because 'a document stating the wrong number MUST fail this guard'
        $v.Claimed | Should -Be $bad
        $v.Derived | Should -Be $expected
        $v.Reason | Should -Match 'document says'
    }

    It 'VACUITY CONTROL: a claim whose pattern matches nothing FAILS, it does not pass' {
        # Without this, deleting the sentence a claim points at would silently disarm the claim and
        # the registry would report green over a document that no longer says anything.
        $claim = @($script:DcClaims)[0]
        $v = Get-DocClaimVerdict -Claim $claim -DocText 'nothing here states any guarded number' -UseDocText
        $v.Match | Should -BeFalse -Because 'a pattern matching nothing is a missing claim, not a satisfied one'
        $v.Reason | Should -Match 'matched NOTHING'
    }
}

Describe 'The generated CHANGELOG companion is CURRENT, and the ledger archive stays closed (dispatch 000283)' {
    # docs/CHANGELOG-recent.md is a GENERATED strict prefix of CHANGELOG.md (ruling R6), carried in
    # the project-knowledge bundle so the release artifact itself never has to be truncated to fit a
    # byte budget. A generated file that nothing verifies is a file that goes stale silently, and a
    # stale one is worse than none: it reads as the changelog while describing an older program.
    BeforeAll {
        $script:CgRoot = Split-Path -Parent $PSScriptRoot
        $script:CgGen = Join-Path $script:CgRoot 'scripts/gen-changelog-recent.ps1'
        $script:CgOut = Join-Path $script:CgRoot 'docs/CHANGELOG-recent.md'
        $script:CgSrc = Join-Path $script:CgRoot 'CHANGELOG.md'
        $script:CgArchive = Join-Path $script:CgRoot 'docs/decision-ledger-archive.md'
        $script:CgLedger = Join-Path $script:CgRoot 'docs/decision-ledger.md'
    }

    It 'the committed companion is current -- the generator -Check agrees with the file on disk' {
        # Runs the generator's own comparison rather than re-implementing it here: two
        # implementations of "what should this file contain" would drift apart, and the one in the
        # test would be the one nobody notices is wrong.
        $host_ = (Get-Process -Id $PID).Path
        & $host_ -NoLogo -NoProfile -File $script:CgGen -Check | Out-Null
        $LASTEXITCODE | Should -Be 0 -Because 'docs/CHANGELOG-recent.md is stale; run scripts/gen-changelog-recent.ps1'
    }

    It 'RED CONTROL: -Check FAILS on a companion that has drifted from its source' {
        # The control for the test above. Without it, a -Check that always exited 0 would make that
        # test read as evidence while proving nothing -- the exact failure this dispatch is fixing
        # elsewhere in this suite.
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('cgctl' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.md')
        $orig = [System.IO.File]::ReadAllText($script:CgOut)
        try {
            [System.IO.File]::Copy($script:CgOut, $tmp)
            [System.IO.File]::WriteAllText($script:CgOut, $orig.Substring(0, $orig.Length - 200))
            $host_ = (Get-Process -Id $PID).Path
            & $host_ -NoLogo -NoProfile -File $script:CgGen -Check | Out-Null
            $LASTEXITCODE | Should -Be 1 -Because 'a drifted companion MUST be caught, not tolerated'
        } finally {
            [System.IO.File]::WriteAllText($script:CgOut, $orig)
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
        }
        # And the restore really restored, or every later test in this run is measuring a mutant.
        & (Get-Process -Id $PID).Path -NoLogo -NoProfile -File $script:CgGen -Check | Out-Null
        $LASTEXITCODE | Should -Be 0
    }

    It 'the companion is a strict PREFIX of CHANGELOG.md, so every sentence in it is the source''s own' {
        # The property that makes truncation safe. If the companion ever became a SUMMARY, a reader
        # could be told something CHANGELOG.md does not say -- and the release pipeline extracts its
        # notes from CHANGELOG.md, so the two would disagree about what shipped.
        $comp = [System.IO.File]::ReadAllText($script:CgOut)
        $src = [System.IO.File]::ReadAllText($script:CgSrc)
        $marker = '<!-- GENERATED FILE -- DO NOT EDIT.'
        $comp.StartsWith($marker) | Should -BeTrue -Because 'the companion must announce that it is generated'
        $bodyStart = $comp.IndexOf('-->')
        $bodyStart | Should -BeGreaterThan 0
        $body = $comp.Substring($comp.IndexOf("`n", $bodyStart) + 1).TrimStart("`r", "`n")
        $body.Length | Should -BeGreaterThan 1000 -Because 'a companion with no body would pass a prefix test vacuously'
        $src.StartsWith($body.TrimEnd("`r", "`n")) | Should -BeTrue -Because 'the companion body must be a byte-exact prefix of CHANGELOG.md'
    }

    It 'CHANGELOG.md is NEVER truncated -- it still carries every released version heading' {
        # The half the companion exists to protect. The bundle got smaller; the release artifact
        # did not change at all.
        $src = [System.IO.File]::ReadAllText($script:CgSrc)
        $all = @([regex]::Matches($src, '(?m)^## \[\d+\.\d+\.\d+\]'))
        $all.Count | Should -BeGreaterThan 25 -Because 'the full history must still be in the release artifact'
        $src | Should -Match '(?m)^## \[1\.0\.0\]' -Because 'the first release must still be present'
    }

    It 'the decision-ledger archive is present, non-trivial, and the live ledger points at it' {
        (Test-Path -LiteralPath $script:CgArchive -PathType Leaf) | Should -BeTrue
        $arch = [System.IO.File]::ReadAllText($script:CgArchive)
        $arch.Length | Should -BeGreaterThan 100000 -Because 'an empty archive would make the pointer a lie'
        $arch | Should -Match 'APPEND-ONLY, AND NEVER EDITED AGAIN'
        $live = [System.IO.File]::ReadAllText($script:CgLedger)
        $live | Should -Match 'decision-ledger-archive\.md' -Because 'the live ledger must name where the rest went'
    }

    It 'the split moved text, it did not lose or duplicate it' {
        # Both directions. A split that dropped a section would shrink the live file exactly as a
        # correct one does, and a split that copied instead of moving would leave the same heading
        # in both files -- neither is visible from a size check alone.
        $live = [System.IO.File]::ReadAllText($script:CgLedger)
        $arch = [System.IO.File]::ReadAllText($script:CgArchive)
        foreach ($h in @('## 2. Shipped and verified -- recent arc',
                         '## 8. External technical review, round 2',
                         '## Dispatch 000269 -- the gate-clearance sitting')) {
            $arch.Contains($h) | Should -BeTrue -Because "the archive must carry '$h'"
            $live.Contains($h) | Should -BeFalse -Because "'$h' must have MOVED, not been copied"
        }
        foreach ($h in @('## 4. Forward plan', '## 6. Standing items (Mike-gated)',
                         '## 7. Operating posture', '## Dispatch 000282')) {
            $live.Contains($h) | Should -BeTrue -Because "'$h' is live planning record and must NOT be archived"
            $arch.Contains($h) | Should -BeFalse -Because "'$h' must not have been copied into the archive"
        }
    }
}
