# Pending corrections to published release bodies

Two published GitHub release bodies carry a statement their CHANGELOG entry no longer
supports. This file holds the **drafted correction text** for both.

> **NOTHING IN THIS FILE HAS BEEN APPLIED.** Editing a published release body is publishing to
> an external surface, and that is the maintainer's call alone. No release body was edited,
> amended, deleted or otherwise mutated by the dispatch that wrote this file (000179), and no
> `gh release edit` was run -- not once, not to test.
>
> Both drafts are **APPEND-ONLY**. Each quotes the published sentence and then corrects it
> beneath. Neither deletes, rewrites, reflows or otherwise disturbs a single character of the
> shipped text. That is this project's standing posture on published figures, set by the
> v1.17.0 correction and re-applied by dispatch 000177 leg 6 to the v1.29.0 CHANGELOG entry:
> **shipped history stands, and is corrected by addition.**

**Where these go if approved.** Appended to the **existing release body**, below the original
text, under a dated `### Correction` heading -- the first of the two forms the dispatch charter
pre-authorized. The alternative (carrying the corrections in a future patch release's notes)
was not chosen: a reader who lands on the v1.27.1 notes is exactly the reader being misinformed,
and a correction filed in a different release's notes does not reach them. The correction has to
be where the wrong sentence is.

**How the divergence set was derived.** `scripts/audit-release-bodies.ps1` compares every
published body against what `release/Get-ChangelogEntry.ps1` -- the extractor the release
pipeline itself uses -- produces from today's CHANGELOG. Over all 22 published releases:
**SELECTED 22, MATCH 20, MISMATCH 2, ERROR 0**, the two being `v1.27.1` and `v1.29.0`. The
standing gate that these two are debt against is documented as step 4 of
[docs/RELEASING.md](./RELEASING.md#how-to-cut-a-release).

Both are now carried as rows in `release/release-body-divergences.psd1`, so the shipped sweep
reports **SELECTED 22, MATCH 20, ACKNOWLEDGED 2, MISMATCH 0, STALE-ACK 0** and exits 0. That is
not the debt being written off: each row prints its reason in full on every run, and each pins
the SHA-256 of the body it acknowledges -- so **applying either correction below changes that
body, retires its row, and turns the sweep red until someone re-examines it.** The
acknowledgement exists because neither divergence can ever be resolved by making the two texts
equal, and a guard that can never go green is a guard that gets silenced.

---

## 1. v1.29.0 -- the corpus transition `main` never made

Release published `2026-08-01T21:00:13Z`. The body carries this sentence, in the *DSC
`Configuration` shape is UNREACHABLE* bullet under **Fixed** (quoted verbatim, including its
hard wrap):

> Recorded as a corpus limit in `tests/corpus/Corpus.Common.ps1`, not engineered around. Clean
>   samples move 51 -> 50 and known-bad 37 -> 36 (both were 49 and 36 before this entry's work).

The same sentence is in the CHANGELOG entry, where dispatch 000177 leg 6 already appended a
dated correction (`## [1.29.0]`, under **Notes**). The body was never corrected, which is the
whole finding: the CHANGELOG moved after publication and the body did not follow.

**What is true**, re-derived independently for this dispatch rather than taken from the existing
CHANGELOG note. Walking the corpus counts across **every** commit reachable from `origin/main`
(240 commits; the two sample directories are touched by exactly 8 of them, so those 8 fix the
value at every other commit), the complete set of values `main` has ever held is:

| | values `main` has held, in order |
|---|---|
| clean samples (`tests/corpus/samples/clean`, `*.ps1` + `*.txt`) | 0, 3, 16, 34, 35, 39, 46, 49, **50** |
| known-bad samples (`tests/corpus/samples/bad`, `*.ps1`) | 0, 3, 18, **36** |

`main` has **never** held 51 clean samples and has **never** held 37 known-bad ones. The
known-bad count has stood at 36 continuously since `3718a5b` (2026-06-24) and did not move
across this release at all. Measured at the tags themselves: `v1.28.1` holds clean 49 / bad 36,
and `v1.29.0` holds clean 50 / bad 36.

### Draft correction text (append below the existing body; nothing above it changes)

```markdown
### Correction (2026-08-02)

The bullet above beginning "**The DSC `Configuration` shape is UNREACHABLE in this corpus**"
ends with: "Clean samples move 51 -> 50 and known-bad 37 -> 36 (both were 49 and 36 before this
entry's work)."

The **starting** figures in that transition are wrong. They are intermediate states from inside
PR #119, not states `main` ever held. Verified by walking every commit reachable from `main`:
it has never held 51 clean samples and has never held 37 known-bad ones. What `main` actually
did across this release is **clean 49 -> 50** and **known-bad 36 -> 36** -- no movement at all
in the known-bad count, which has stood at 36 continuously since `3718a5b` (2026-06-24).

The **end states are right** (50 clean and 36 known-bad), as is the sentence's own parenthetical
("both were 49 and 36 before this entry's work"), which states the correct starting values that
the transition it sits beside contradicts. So the published false-positive and true-positive
denominators for v1.29.0 are correct; it is the narrated transition that is wrong, and its
known-bad half narrates a net change that did not happen.

Recorded by appending rather than by editing the sentence above, on the same principle as this
project's correction to the v1.17.0 release notes: shipped history stands. The CHANGELOG entry
for 1.29.0 carries the same correction (dispatch 000177 leg 6).
```

---

## 2. v1.27.1 -- notes that still place the manifests at 1.27.0

Release published `2026-07-25T21:32:51Z`. The body ends:

> no code, no knob, no capture-format change, no other manifest field touched, and **no version
> move**: both manifests stay lockstep at 1.27.0 and a future cut classifies this entry. See dispatch
> 000153 leg 3.

The CHANGELOG entry on `main` today reads, at the same point:

> no code, no knob, no capture-format change, no other manifest field touched, and **no version move
> made by the authoring change itself**: dispatch 000154 classified this entry PATCH and cut it,
> moving both manifests in lockstep to 1.27.1. See dispatch 000153 leg 3.

**This is a post-publication CHANGELOG correction, not an edit to the body**, and the evidence is
mechanical rather than inferred:

- Running the sweep against `git show v1.27.1:CHANGELOG.md` -- the CHANGELOG exactly as it stood
  at the tagged commit -- reports **MATCH** for `v1.27.1`. The published body is therefore
  byte-for-byte (whitespace-normalized) the notes the pipeline generated at publish time. It has
  not been touched since.
- Running the same sweep against the CHANGELOG on `main` today reports **MISMATCH**, diverging at
  the clause above.
- The CHANGELOG-side edit lands in commit `4690cdb` (2026-07-27, PR #107, dispatch 000158 legs
  1-2), whose subject names it: "fix the released v1.27.1 CHANGELOG clause". That is roughly a
  day and a half **after** the release was published.

**What is true.** The claim was accurate about the *authoring* change (dispatch 000153 leg 3
edited one clause in `marketplace.json` and moved no version), and became false the moment
dispatch 000154 classified that entry PATCH and cut it. At the tagged commit `v1.27.1`, both
`.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` read `1.27.1`. The body is
therefore telling a reader of the **v1.27.1** notes that the manifests are at **1.27.0** --
inside the release that moved them off it.

### Draft correction text (append below the existing body; nothing above it changes)

```markdown
### Correction (2026-08-02)

The last sentence above reads: "**no version move**: both manifests stay lockstep at 1.27.0 and
a future cut classifies this entry."

That was true of the authoring change (dispatch 000153 leg 3 edited one clause in
`marketplace.json` and moved no version) and stopped being true before these notes were
published: dispatch 000154 classified the entry PATCH and cut it. **At this tag, both
`.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` read 1.27.1.** The "future
cut" the sentence anticipates is the release these notes belong to.

The CHANGELOG entry for 1.27.1 was corrected to say so on 2026-07-27; this body was cut before
that correction and did not follow it, which is the drift being repaired here. Everything else
in these notes -- the marketplace-description fix, the one-clause-one-file scope, the absence of
any code, knob or capture-format change -- is unaffected and stands as published.
```

---

## Why there is no test guarding this

There is deliberately **no `tests/doc-claims.psd1` row** for either of these, and none can be
added. That registry derives a true value from a file **on disk** and fails CI when a published
number disagrees with it. A published release body is not on disk -- it is external state behind
GitHub's Releases API. A row pointed at one would either never run or silently pass, and a row
that silently passes is worse than no row, because the row itself reads as evidence the surface
is guarded. The asymmetry is recorded in [docs/RELEASING.md](./RELEASING.md#how-to-cut-a-release)
step 4 as a human gate, and `scripts/audit-release-bodies.ps1` makes that gate one command.
