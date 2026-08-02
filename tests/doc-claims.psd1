# doc-claims.psd1 -- THE DOC-CLAIMS REGISTRY (dispatch 000177 leg 7).
#
# WHY THIS FILE EXISTS. The 000176 survey found the README's clean-fixture count stale by 16. The
# number was CORRECT when written (v1.16.0, disk held 34) and drifted across five corpus-growth
# commits -- including one that restructured that very section while disk already held 49 and
# carried the stale 34 through verbatim. So the defect was never a typo or one careless edit:
# NOTHING IN THE REPOSITORY CONNECTED A PUBLISHED NUMBER TO THE THING IT COUNTS. Correcting the
# number without correcting that leaves the same failure armed.
#
# Each row is a guarded claim: a DOCUMENT location, a DERIVATION that computes the true value from
# disk, and the relationship between them (equality). PowerShellLsp.DocClaims.Tests.ps1 derives
# every value on every CI run and FAILS when a document disagrees with the thing it describes.
# This is Hub Rule 18 -- one source for a value duplicated where files cannot import each other --
# with disk as the source and CI as the enforcement.
#
# ADDING A CLAIM IS ONE ROW, NOT A CODE EDIT. That is the property that makes this scale past the
# five claims it ships with. The honest limit: one row buys you a claim in an EXISTING derivation
# kind. A genuinely new kind of derivation is a code edit, and there is no way around that.
#
# ONLY MECHANICALLY DERIVABLE CLAIMS BELONG HERE. Every row must be computable from disk by code,
# with no human judgement anywhere in the loop. A claim that needs judgement will eventually be
# wrong in a way the guard cannot adjudicate; someone will then silence the guard, and one silenced
# guard teaches that guards are advisory -- at which point the registry is worse than nothing.
# Roadmap currency, for instance, is deliberately NOT here: it is a human release gate in
# docs/RELEASING.md, because a check that cannot adjudicate its subject should not pretend to.
#
# DERIVATION KINDS (see Get-DocClaimDerivedInt in the test):
#   CorpusSpecCount  { Category }        Count of Get-CorpusSampleSpec specs in a category. This is
#                                        THE scoring derivation -- the same enumeration
#                                        Get-CorpusCorrectnessReport builds its denominators from,
#                                        not a re-implementation of it.
#   FileRegexInt     { Path; Pattern }   Integer captured from another file in the repo. The
#                                        capture must resolve to exactly ONE distinct value or the
#                                        derivation throws.
#
# MATCHING IS WHITESPACE-NORMALIZED. Documents are read whole and every whitespace run collapsed to
# a single space before matching, so a claim that WRAPS across lines still matches. The 000176
# survey hit this on ROADMAP.md: a single-line grep for a phrase that was demonstrably present came
# back empty and read as absence. A pattern that matches NOTHING is a FAILURE here, never a skip --
# a guard that silently matches nothing is the vacuous-match defect wearing a green tick.

@{
    Claims = @(

        @{
            Name       = 'README clean-fixture count equals the scored clean denominator'
            Document   = 'README.md'
            Pattern    = '\*\*clean\*\* \((\d+) cases'
            Derivation = @{ Kind = 'CorpusSpecCount'; Category = 'clean' }
            Note       = 'The number that went stale by 16. This is the row that would have caught it.'
        }

        @{
            Name       = 'README known-bad count equals the scored known-bad denominator'
            Document   = 'README.md'
            Pattern    = '\*\*known-bad\*\* \((\d+) cases'
            Derivation = @{ Kind = 'CorpusSpecCount'; Category = 'bad' }
            Note       = 'Reconciled at 36 only because samples/bad has not moved since 2026-06-24 -- luck, not tracking.'
        }

        @{
            Name       = 'README parser-error count equals the scored parser denominator'
            Document   = 'README.md'
            Pattern    = '\*\*parser-error\*\* \((\d+) cases\)'
            Derivation = @{ Kind = 'CorpusSpecCount'; Category = 'parser' }
        }

        @{
            Name       = 'README false-positive denominator equals the scored known-good denominator'
            Document   = 'README.md'
            Pattern    = '\(0 of (\d+) known-good cases produced any finding\)'
            Derivation = @{ Kind = 'CorpusSpecCount'; Category = 'clean' }
            Note       = 'The headline trust number. Same derivation as the clean count, stated in a second place -- which is exactly why it needs its own row.'
        }

        @{
            Name       = 'README corpus-size floor equals the floor the corpus test enforces'
            Document   = 'README.md'
            Pattern    = '\*\*floors\*\* each scored set at \*\*(\d+) fixtures\*\*'
            Derivation = @{
                Kind    = 'FileRegexInt'
                Path    = 'tests/PowerShellLsp.Corpus.Tests.ps1'
                Pattern = 'CorpusReport\.known(?:Good|Bad) \| Should -BeGreaterOrEqual (\d+)'
            }
            Note       = 'Leg 2 put this number into the README. Guarding it immediately is the point: an unguarded published number is how this whole class starts. The derivation captures both the knownGood and knownBad floors and requires them to agree, so a future divergence fails loudly instead of picking one silently.'
        }

    )
}
