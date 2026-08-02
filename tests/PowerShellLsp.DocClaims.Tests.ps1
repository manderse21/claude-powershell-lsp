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
