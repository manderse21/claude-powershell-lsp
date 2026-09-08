# control-map-claims.psd1 -- THE CONTROL-MAP CLAIMS REGISTRY (dispatch 000285, ruling R4).
#
# WHY THIS FILE EXISTS, AND WHY IT IS A SIBLING OF doc-claims.psd1 RATHER THAN ROWS IN IT.
# docs/control-map.html ships as a RELEASE ASSET and had no automated guard of any kind: nothing
# under tests/, scripts/ or release/ referenced it, doc-claims.psd1 guards README.md, ROADMAP.md and
# docs/RELEASING.md only, and the release workflow's sole reference was
# `if [[ -f "docs/control-map.html" ]]` -- a PRESENCE test, which proves the one thing nobody
# doubted. doc-claims.psd1's own header rules its scope: every row there is an INTEGER derived by
# CorpusSpecCount or FileRegexInt. The claims this map makes are not integers -- they are release
# STATES, open/closed decisions and version rails -- so they need their own derivation kinds, and a
# new kind is a code edit either way. A sibling registry keeps that header's promise intact instead
# of quietly widening it.
#
# A DATE COMPARISON IS NOT A CURRENCY GUARD, and this is deliberately not one. docs/RELEASING.md
# step 5 compares the map's internal date stamp against the release's CHANGELOG date. Stamping the
# map satisfies that comparison whether or not a single claim was re-derived, so the act of
# refreshing the artifact DISARMS the only detector that would have caught a bad refresh. Every row
# below asserts a CLAIM against a source the map's author does not write in the same motion.
#
# EVERY DERIVATION READS THIS REPOSITORY'S OWN DISK. No network, no gh, no hub checkout. That is a
# hard constraint, not a preference: this registry runs in CI, where the hub is not present and the
# network is not guaranteed, and a guard that degrades to "skipped" in CI is a guard that is off
# exactly when it matters. Claims that can only be derived from the hub -- the dispatch counter, the
# board state -- are therefore listed as UNGUARDABLE-BY-DESIGN at the bottom of this file rather
# than guarded weakly. A guard that covers most claims and NAMES the rest is honest; one that covers
# all of them by weakening its assertions is not.
#
# DERIVATION KINDS (see the test):
#   ForbiddenWhile   { Phrase; SourcePath; SourcePattern }
#       The map must NOT contain Phrase while SourcePattern matches SourcePath. This is the shape
#       that catches a claim which was TRUE WHEN WRITTEN and has since become FALSE -- the class
#       that actually hurts, because a reader acts on it.
#   ForbiddenIfReleased { PhraseTemplate }
#       The map must not describe version V as unreleased/in-prep while CHANGELOG.md carries a
#       released `## [V]` section for it. V is DERIVED from the map's own text, so the row cannot
#       go stale against a version number nobody updated here.
#   EqualsNewestRelease { Pattern }
#       The version captured from the map must equal the newest released version in CHANGELOG.md
#       (the highest `## [X.Y.Z]` section that is not [Unreleased]).
#
# MATCHING IS NORMALIZED before every comparison: HTML tags stripped, `&middot;` and `&#160;`
# resolved, then whitespace collapsed. The map is hand-authored HTML whose sentences wrap mid-claim
# and whose separators are entities, so a raw substring search reads as ABSENCE on text that plainly
# contains the claim. A pattern that matches NOTHING where the registry says it must match is a
# FAILURE, never a skip.

@{
    Document = 'docs/control-map.html'

    Claims = @(

        @{
            Name       = 'T5.1 is not described as an unreleased security fix once it has shipped'
            Kind       = 'ForbiddenWhile'
            Phrase     = 'T5.1 fixed-unreleased'
            SourcePath = 'CHANGELOG.md'
            # The Windows arm shipped in v1.33.0. Any RELEASED CHANGELOG section naming the pipe
            # DACL fix refutes "fixed-unreleased" -- so the condition is the release, not a date.
            SourcePattern = '(?s)##\s*\[1\.33\.0\].*?pipe'
            Note       = 'RED-CONTROL TARGET 1. Rev 2 carried this and it was FALSE, not merely stale: the fix shipped in v1.33.0 on the very day rev 2 was stamped. A shipped security fix still described as unreleased is worse than an omitted one, because a reader acts on it.'
        }

        @{
            Name       = 'the SLO tally does not claim "all six met" while an SLO miss is open'
            Kind       = 'ForbiddenWhile'
            # THE PHRASE IS THE ASSERTION, NOT THE WORDS. A bare 'all six met' also matches the
            # map's OWN PROSE, which narrates what rev 2 got wrong -- so the tip failed its own
            # guard on a sentence that exists precisely because the claim was corrected. That is
            # the self-documentation hazard: a needle that cannot tell a claim from a description
            # of that claim. Anchoring on the SLO row's own wording separates them.
            Phrase     = 'ADOPTED 08-21, all six met'
            SourcePath = 'docs/roadmap-ii/PROGRAM.md'
            # PROGRAM.md states the standing in terms, and separately carries an open PENDING-MIKE
            # row. Either is enough to refute "all six met"; the standing line is the tighter one.
            SourcePattern = 'STANDING AT v1\.33\.0: 5 of 6 MET, T3 MISSED'
            Note       = 'RED-CONTROL TARGET 2. Rev 2 carried this and it had decayed from true to misleading -- true at v1.32.0, false at v1.33.0. This is the row that makes the guard a CURRENCY guard rather than a spell-check.'
        }

        @{
            Name       = 'no version is described as in-prep once CHANGELOG carries its release'
            Kind       = 'ForbiddenIfReleased'
            # The version is derived FROM THE MAP: whatever it calls in-prep is checked against
            # CHANGELOG.md. The row therefore cannot go stale against a hard-coded version.
            Pattern    = 'v(\d+\.\d+\.\d+)\s*(?:--)?\s*in (?:release )?prep'
            Note       = 'Rev 3 -- the revision produced BY the currency refresh and shipped as a release asset -- carried "v1.34.0 in release prep" and "v1.34.0 -- in release prep" while v1.34.0 was published. The corrected artifact acquired a new false claim of exactly the class it was corrected for, within hours, and nothing noticed. This row is that fourth instance made mechanical.'
        }

        @{
            Name       = 'the stamp names the newest RELEASED version'
            Kind       = 'EqualsNewestRelease'
            Pattern    = 'released v(\d+\.\d+\.\d+)'
            Note       = 'The header stamp asserts what is released. It is checked against CHANGELOG.md rather than against plugin.json, because plugin.json moves at the version bump -- BEFORE the release exists -- and would bless the claim one commit early.'
        }

    )

    # UNGUARDABLE BY DESIGN, and named rather than guarded weakly. Each of these is a real claim the
    # map makes whose only source lives outside this repository, so a CI-time derivation would have
    # to either reach the network or fabricate a local stand-in. Listed so a reader knows the guard's
    # edge, and so a future dispatch can move a row up if the source ever lands in-repo.
    #
    #   `counter NNNNNN` in the stamp -- the hub's projects/powershell-lsp/.counter. Hub-only.
    #   `the dispatch board is NOT: NNNNNN in progress` -- hub dispatch state. Hub-only.
    #   held-PR references and PR-state chips -- gh, i.e. network.
    #   the North Star prose, the declines table's REASONS, and the risk narrative -- prose, not
    #     facts. Judgement belongs to the maintainer; a guard that adjudicated it would eventually
    #     be wrong in a way it could not settle, someone would silence it, and one silenced guard
    #     teaches that guards are advisory.
    #
    # THE DECISION, PER FAMILY: NONE OF THE FOUR SHOULD MOVE IN-REPO. Taken in writing by dispatch
    # 000286 phase 3(b) and transcribed here by 000287 so a future dispatch meets it where the list
    # lives rather than having to find the outbox. No claim was weakened to make it guardable, and
    # no family's verdict is softened in the transcription. The full reasoning is in
    # projects/powershell-lsp/000286-PHASE-RECORDS.md section 3(b); one line each:
    #
    #   `stamp: counter NNNNNN (hub .counter)` -- NO. An in-repo copy is a duplicated value with no
    #     importable single source (Hub Rule 18's exact failure mode). It would go stale silently
    #     and the guard would then bless a stale number, which is strictly worse than naming it
    #     unguardable.
    #
    #   `chip: dispatch board in-progress state (hub)` -- NO, most clearly of the four. Board state
    #     is LIVE and changes many times a day, so any in-repo snapshot is stale before the release
    #     asset carrying it is even built: a guard over it would assert a fact with a shelf life
    #     shorter than its own build.
    #
    #   `held-PR references and PR-state chips (network)` -- NO, but this one is DIFFERENT and the
    #     difference is the actionable half. It is not underivable: gh can read it, and this
    #     repository already reads published GitHub state that way in
    #     scripts/audit-release-bodies.ps1. It is deliberately not derived AT CI TIME, because a
    #     network-dependent required check goes red for reasons its owner cannot fix, and a gate
    #     that reddens for reasons no one can fix is a gate that gets silenced. IF IT IS EVER
    #     GUARDED, it should take the audit-release-bodies.ps1 shape -- a maintainer-run sweep,
    #     NEVER a CI gate. That is not "guard it later": it is the only shape under which guarding
    #     it would be correct at all.
    #
    #   `North Star prose, decline reasons, risk narrative` -- NO, categorically rather than
    #     practically. These are judgements, not facts, and the paragraph above already says what
    #     follows from that. This decision confirms it and adds nothing.
    Unguardable = @(
        'stamp: counter NNNNNN (hub .counter)'
        'chip: dispatch board in-progress state (hub)'
        'held-PR references and PR-state chips (network)'
        'North Star prose, decline reasons, risk narrative (prose, not facts)'
    )
}
