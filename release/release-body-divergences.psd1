# release-body-divergences.psd1 -- the KNOWN, deliberately-carried divergences between a
# published GitHub release body and its CHANGELOG entry (dispatch 000179 leg 4).
#
# WHY THIS FILE EXISTS
#   scripts/audit-release-bodies.ps1 compares every published body to the CHANGELOG entry it
#   was cut from. Some divergences are permanent BY CONSTRUCTION and can never be resolved:
#
#     - Once a correction is APPENDED to a published body (this project's standing posture --
#       shipped text is corrected by addition, never by rewriting), that body is by definition
#       longer than the CHANGELOG entry it was cut from. It will never compare equal again.
#     - Where a CHANGELOG entry was corrected by revision BEFORE this posture was formalised
#       (v1.27.1, corrected in 4690cdb), the published body can never be made to match it
#       without rewriting shipped text, which this project does not do.
#
#   Without this file the sweep is red on day one and stays red forever, and a guard that can
#   never go green is a guard that gets silenced -- the exact failure mode tests/doc-claims.psd1
#   warns about in its own header. So a divergence listed here reports ACKNOWLEDGED instead of
#   MISMATCH and does not fail the sweep. Only UNKNOWN drift fails.
#
# THE ANTI-VACUITY RULES -- an acknowledgement is held to its own premise, three ways:
#   1. An acknowledged tag whose body and entry turn out to AGREE is reported STALE and FAILS.
#   2. An acknowledged tag that no published release matches is reported STALE and FAILS.
#   3. `PublishedSha256` pins the NORMALIZED published body this row was written against, and
#      is REQUIRED. If the body changes -- including when the correction drafted in
#      docs/release-body-corrections.md is finally applied -- the row is reported STALE and
#      FAILS until someone re-examines it. Without the pin, a row would go on excusing its tag
#      forever, suppressing exactly the later drift the sweep exists to find.
#   A stale entry is worse than no entry: it would silently excuse the next real divergence
#   while itself reading as evidence somebody looked.
#
# ADDING A ROW IS A DELIBERATE ACT. It means "this body and this entry will never agree, and a
# reader is not being misled." It is NOT a way to make a red sweep quiet. If the divergence is
# ordinary post-publication drift, the fix is to mirror the correction into the body (see
# docs/RELEASING.md step 4), not to add a row here.

@{
    Acknowledged = @(

        @{
            Tag             = 'v1.29.0'
            Since           = '2026-08-02'
            PublishedSha256 = 'f10ce3efd8107aeea5fd668578b2a63fdbfec5b49cb4258627832c42174ce245'
            Reason = @'
The CHANGELOG entry carries a dated correction appended by dispatch 000177 leg 6 (the corpus
transition "51 -> 50 / 37 -> 36" that main never made). The published body does not, and the
correction drafted for it in docs/release-body-corrections.md is written for a release-notes
reader rather than a CHANGELOG reader, so the two texts are deliberately not identical. This
body and this entry will not compare equal again in either state -- before the correction is
applied or after it. Tracked as debt in docs/release-body-corrections.md section 1, NOT as
something the sweep can close.
'@
        }

        @{
            Tag             = 'v1.27.1'
            Since           = '2026-08-02'
            PublishedSha256 = 'ad03d935f76896eb21c64817965db37323cb1b0f8f11548c98ca26c22a5790ce'
            Reason = @'
The CHANGELOG entry was corrected by REVISION in 4690cdb (2026-07-27), two days after the
release was published, replacing the "both manifests stay lockstep at 1.27.0" clause outright.
The published body still carries the superseded clause. It cannot be made to match without
rewriting shipped text; the repair is an APPENDED correction, which leaves the two permanently
unequal. Tracked as debt in docs/release-body-corrections.md section 2. This row exists because
the divergence is permanent, not because it is acceptable -- the body is still wrong until the
correction is applied, and that is the maintainer's gate.
'@
        }

    )
}
