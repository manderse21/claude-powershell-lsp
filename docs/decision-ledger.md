# claude-powershell-lsp -- decision ledger

> **Closed history lives in [decision-ledger-archive.md](decision-ledger-archive.md).**
> That file is append-only and is never edited again; this file carries the live record.
> Split by dispatch 000283 at the v1.33.0 (2026-08-22) MINOR line. The archived spans are
> section 2 (closed per-dispatch dispositions), sections 8 and 9 (two adjudicated external
> reviews), and every dated ruling section older than that MINOR line. Sections 1 and 3-7
> stayed here on purpose: they are the forward plan, the standing items, the operating
> posture and the recorded-check authoring contract, which are current, not history.


The full working record: the shipped arc, per-dispatch dispositions, the four-horizon ladder,
standing items, and every decline with its reasoning. This is the **evidence layer**; the short
public view -- what is next, what is blocked, what is deferred -- is [ROADMAP.md](../ROADMAP.md),
which links here for the reasoning behind each line. (Split out of `ROADMAP-powershell-lsp.md` by
dispatch 000166 leg B6b; a pointer stub remains at the old path so prior links resolve.)

Status as of 2026-08-16. Plugin's current release: **v1.31.2**, GPL-3.0-or-later -- that is the
license v1.31.2 shipped under and it does not change, but the **repository** relicensed forward to
**Apache-2.0** on 2026-08-16 (dispatch 000247, entry at the end of this file), so the next release
ships Apache-2.0. (That clause is 000247's; the 000245 derivation claim that follows covers the rest
of this paragraph.) Every fact in
this paragraph was DERIVED live at run time by dispatch 000245, each with its deriving command
named inline -- re-run rather than carried across from the header this pass replaces, on the
standing reason 000195 leg A gave: a header's own version claim is the fact likeliest to have gone
stale since it was written, so it is the one that must never be copied. That rule has now earned
its keep on four consecutive passes; the version fact MOVED again (v1.31.1 -> v1.31.2) three days
after the paragraph this one replaces was written. The v1.31.2 version is TAGGED, gitsign-signed,
and RELEASED: an annotated tag v1.31.2 whose object carries a `-----BEGIN SIGNED MESSAGE-----`
block (`git cat-file -t v1.31.2` returns **tag**, not commit) sits at commit
**8b331ca6fdd434416dff16a7eb84632af5b013db** on origin, tagged by `github-actions[bot]` from the
release runner (`git for-each-ref refs/tags/v1.31.2` returns taggername `github-actions[bot]` and
taggerdate **2026-08-16T02:42:24Z**; the tag object itself is
**38aef55dbf97c1471406ad8a92ecd28171519a6c**), and the v1.31.2 GitHub Release is published as the
current **Latest** (`gh release view v1.31.2` returns tagName v1.31.2, isDraft=false,
isPrerelease=false, publishedAt **2026-08-16T02:42:29Z**, targetCommitish 8b331ca6; `gh release
list --json tagName,isLatest` returns `isLatest=true` for v1.31.2 and `false` for v1.31.1,
v1.31.0, v1.30.0, v1.29.1, v1.29.0, v1.28.1, v1.28.0 and v1.27.3, so **v1.31.1 is no longer
current** and its facts now live in its Section 2 row). The tagged commit is the **PR #174**
landing, `git log -1 --format=%s 8b331ca6` reading "release: cut 1.31.2 CHANGELOG-first, then
lockstep-bump (dispatch 000243) (#174)" -- a SQUASH landing, as every commit in this arc was.

**The tag commit is MERGED TO MAIN, derived by PEELING the tag rather than by comparing the tag
object -- and main has ALREADY moved past it, by exactly one commit, which was ANTICIPATED rather
than discovered.** `git rev-parse refs/tags/v1.31.2^{}` returns
**8b331ca6fdd434416dff16a7eb84632af5b013db**. The tag OBJECT is a different SHA
(**38aef55dbf97c1471406ad8a92ecd28171519a6c**), which is what an annotated tag IS -- comparing the
unpeeled object against a commit would have produced a false mismatch, and comparing peeled
commits is the check that means anything. **`git merge-base --is-ancestor v1.31.2^{} origin/main`
exits 0**, so Gate 1's merged-to-main property holds at verification time and not only at cut
time. `git rev-list --count v1.31.2^{}..origin/main` returns **1**, and the single commit is
**cf7449f183ac22ba3e42c7c410f0db20fcdb7fe9** (`release: acknowledge v1.18.1 permanent
published-body divergence (#175)`), which `gh pr view 175` reports merged
**2026-08-16T02:55:18Z** -- 12m49s AFTER the Release published. It touches exactly one file,
`release/release-body-divergences.psd1` (+15 lines, `git show --stat`), and nothing the tag
carries: `git rev-parse v1.31.2^{}:CHANGELOG.md` and `git rev-parse origin/main:CHANGELOG.md` are
the SAME BLOB (`727b868082610f5fb310b78a551235e4adb3dc34`), so there is no tag-versus-tip
CHANGELOG drift for any derivation below to fall foul of. The count has now read 0 at 000206, 14
at 000210, 0 at 000215, 0 at 000219, 0-then-1 at 000234 and 1 here -- so a reader must treat ANY
inherited value as unverified. **The durable half of the pair is `merge-base --is-ancestor`**,
which stays true forever once the tag is merged; the count is the half that decays.

**The 18 commits between the two tags ARE the release, and NOT ONE of them is a merge commit.**
`git rev-list --count v1.31.1^{}..v1.31.2^{}` returns **18** and
`git rev-list --count --merges` over the same range returns **0**. The v1.31.1 row recorded that
deriving an arc from the merge list undercounted that cycle by ten PRs once the repo mixed landing
styles; on this arc the same derivation would have returned **zero commits for an eighteen-commit
release** -- the failure is now total rather than partial, because the transition to squash-only
landings is complete. The arc is #156, #157, #159, #160, #161, #162, #163, #164, #165, #166,
#167, #168, #169, #170, #171, #172, #173 and #174: five Dependabot action bumps, the 000234
record true-up, the 000235 roadmap true-up, the 000236 readiness-gate work, the 000237 daemon
survival fix, the 000233 serve-transport routing and its 000241 suspension, the security-posture
canonicalization, three GH-AUDIT items, and the 000243 release prep that carries the bump. Both
manifests PARSE to **1.31.2** at the tag AND at the tip -- `git show
v1.31.2^{}:.claude-plugin/plugin.json` and `git show origin/main:.claude-plugin/plugin.json` both
give `version` 1.31.2, and the same two reads of `.claude-plugin/marketplace.json` both give
`metadata.version` 1.31.2, lockstep true at each ref (these are the two fields Gate 3 itself
reads, and its own log line at the producing run reads `OK: version lockstep holds at the target
commit.`). **`marketplace.json` carries `metadata.version` and NOTHING else version-shaped:**
re-derived at this tag, its `plugins[]` entry has exactly the keys `category`, `description`,
`name`, `source`, `tags` -- there is **no `plugins[].version` field at all**. Recorded for the
FOURTH time; 000245's charter is the second in a row to carry the correction at the source rather
than leave it to be found at execution time, which is what should end the repetition. The
`userConfig` knob count is **20** at the tag and **20** at v1.31.1, `rulesets/base.psd1` is **53**
rules and the SAME GIT BLOB (`2e5bbda8b3ecfe139c2171119ddc3a0a9974614f`) at v1.31.1, at v1.31.2
and at the tip, and the longest `userConfig` description is **194** characters -- at the 000110
cap, not over it -- so the arc added no knob and no rule and widened no description.

**The CHANGELOG's newest dated heading is `## [1.31.2] - 2026-08-15` while the Release published
on 2026-08-16 UTC, and that one-day gap is a TIMEZONE artifact rather than the prepared-then-held
shape v1.28.0 and v1.27.2 have.** The tag commit was authored **2026-08-15T22:16:45-04:00**
(`git log -1 --format=%aI 8b331ca6`), which is 2026-08-16T02:16:45Z -- so the heading carries the
local authoring date and the Release carries the UTC publish instant, and both name the same
evening. Stated precisely because the four preceding rows each assert their heading date "EQUALS
the publish day", and a reader comparing this row against them would otherwise read a departure
where there is only a clock. **`## [Unreleased]` is PRESENT at this tag and at the tip as an EMPTY
SCAFFOLD** -- a count of `^## \[Unreleased\]` returns **1** on both, and at the tag the heading
sits at CHANGELOG line 32 followed by a single blank line and then `## [1.31.2] - 2026-08-15` at
line 34, so the scaffold carries no content. That is a DEPARTURE from the four preceding cuts,
each of which consumed the heading entirely and recorded a count of 0. It is recorded here as
what happened and is deliberately NOT ruled on: whether an empty scaffold or a consumed heading is
the convention going forward is dispatch 000246's to frame, and this pass declines to settle it
by implication. The old publish gap (the registry once served a stale 1.3.0) stays CLOSED. The
v1.31.1, v1.31.0, v1.30.0, v1.29.x and v1.28.x verification facts are not restated here: they
live in this document's release-table rows in Section 2, which is where the header's predecessor
facts get relocated (the convention 000161 leg 2 established, and the 000123 lesson against
carrying superseded version claims forward).

**The v1.31.2 release was verified end to end at the 000161 standard by dispatch 000245, and every
leg PASSED.** Each check was run with a RED control proving it discriminates, because an exit-0
verification that cannot fail is not a verification. **CI, selected by identity rather than
recency:** push-CI run **31921535537** was found by matching `headSha` to 8b331ca6 per rule 000081
-- `gh run list --commit 8b331ca6...` returns six runs at that head and the newest of them is the
producing release run, so taking the newest would have selected the wrong workflow entirely --
concluded `success`, and carries all four required legs green BY NAME (`macos-pwsh`,
`ubuntu-pwsh`, `windows-pwsh`, `windows-powershell`), each appearing exactly once in a 4-job run,
alongside a green code-scanning run **31921535543** on the same head. **Gate 6 paired by COMMIT
IDENTITY:** producing run **31922425544** matched dry run **31921556319**
(`powershell-lsp release 1.31.2 [DRY-RUN] target=HEAD`, created 2026-08-16T02:17:21Z) and printed
`OK: the dry-run pair is satisfied.` The pairing is bound at BOTH ends rather than taken from the
run list: each run's own "Resolve target commit" step echoes `Resolved target commit
8b331ca6fdd434416dff16a7eb84632af5b013db for tag v1.31.2` (`dry_run=true` on the rehearsal,
`dry_run=false` on the producing run), `gh run view` reports `headSha` 8b331ca6 for both, and the
gate's own log names the matched run id, name, creation time and target. All six gates logged OK
on the producing run. The gate again logged `Unmarked successful runs: 45 in total, of which 0 are
on target commit 8b331ca6... and are inspected below.` -- the same 45 as at the three preceding
cuts, still costing nothing, the closed-population prediction holding for a fourth observation.

**The producing run was PINNED with an explicit `-f commit=8b331ca6...`, and the pin's value is
stated precisely rather than overclaimed.** Its run name records the input structurally:
`powershell-lsp release 1.31.2 [PRODUCING] target=8b331ca6fdd434416dff16a7eb84632af5b013db`,
against the rehearsal's `target=HEAD`. PR #175 was ALREADY OPEN when the producing run was
dispatched (`gh pr view 175` reports createdAt **2026-08-16T02:31:07Z**, the run created
**2026-08-16T02:40:08Z**), so a blank-commit resolution would have raced it. What the timeline
shows is that the race had not yet fired: #175 merged at **02:55:18Z**, 15 minutes AFTER the run
resolved its target at 02:40:16Z, so a blank input at that instant would ALSO have resolved to
8b331ca6. The pin therefore CLOSED a live race rather than corrected an already-moved tip -- had
the run been dispatched fifteen minutes later it would have resolved to cf7449f and Gate 6 would
have refused it on the exact same-commit requirement the gate exists to enforce. Recorded at that
precision because "the pin was necessary" and "the pin was correct" are different claims, and only
the second is supported by the clock.

**One mis-triggered producing attempt sits in the run list and produced NOTHING, recorded so a
future reader does not mistake it for a failed cut.** Run **31921960127** (2026-08-16T02:28:12Z,
triggering actor `manderse21`) carries the run name `powershell-lsp release 1.31.2 [PRODUCING]
target=PASTE_MERGE_SHA_HERE` -- the commit input was submitted with the placeholder text
unsubstituted. It was CANCELLED 2m42s later at 02:30:54Z, and `gh api
repos/.../actions/runs/31921960127/jobs` returns `total_count` **0**: not one job started, so no
gate ran, no tag was cut, no release was created and no attestation was signed. It would have
failed at the resolve step regardless, since `git rev-parse "PASTE_MERGE_SHA_HERE^{commit}"`
cannot resolve. The cut that shipped is the one that followed it.

**One timing fact, recorded so a future reader does not misread rehearsal cost as a defect.** The
rehearsal took **21m52s** and the producing run **2m24s**. That asymmetry is Gate 4 working as
designed, and it is arithmetic rather than inference: the rehearsal was dispatched 34 seconds
after the merge commit's push-CI began, so it spent its time WAITING inside Gate 4 for that run to
reach a terminal state -- the rehearsal's own step timings put Gate 4 at 02:17:30Z to 02:39:08Z,
**21m38s of its 21m52s**, with every step from Gate 6 onward `skipped` under `if: ${{
!inputs.dry_run }}` and only "Dry-run summary" running to close it. By the time the producing run
was dispatched, CI was already terminal and there was nothing to wait for.

**Assets:** both published assets were DOWNLOADED and re-hashed --
`powershell-lsp-1.31.2.tar.gz` sha256
**8efcda28a3fb166219d13312c2ecea135207e836e09cc62737034fd85253df63** (2580245 bytes) and
`powershell-lsp-1.31.2.cdx.json` sha256
**4817bd3ead8eb5fb04657c7d098f28dd68cda846a9340c8937cec21b5da281a4** (2524 bytes) -- each matching
the digest the live Release lists (`gh api repos/.../releases/tags/v1.31.2` reports both as a
`digest` field, so the comparison is against GitHub's own record rather than against a value
copied out of a body). ONE SLSA provenance statement (`predicateType`
`https://slsa.dev/provenance/v1`) carries BOTH subjects, and each attestation's `subject[]`
digests equal the two hashes above. `gh attestation verify --repo manderse21/claude-powershell-lsp`
exits **0** on both. The attestation's own `sourceRepositoryDigest` reads
**8b331ca6fdd434416dff16a7eb84632af5b013db** -- the same commit as the peeled tag -- with
`sourceRepositoryRef` `refs/heads/main`, `githubWorkflowSHA` the same commit, issuer
`https://token.actions.githubusercontent.com`, and `runInvocationURI`
`https://github.com/manderse21/claude-powershell-lsp/actions/runs/31922425544/attempts/1`, so the
attestation identifies its own producing run rather than being matched to one by hand. **Four RED
controls were run and all four exit 1**, and they are not four spellings of one control: the
tarball and the SBOM each attributed to a WRONG repository fail at lookup (HTTP 404); a copy of
the SBOM with **one bit flipped at byte 100** fails at lookup against the CORRECT repository
(digest `328f249e...`, no attestation exists for it), which is what proves the attestation binds
this byte-stream and not merely this repository; and the intact tarball with the correct repository
but a WRONG `--signer-workflow` fails at `verifying with issuer "sigstore.dev"` -- the attestation
is FOUND and REJECTED ON IDENTITY, which is the only one of the four that exercises the
attribution check rather than the lookup. *One environment note for the next verifier: at gh
2.95.0 `gh attestation verify` prints its human-readable verdict only to a TTY, so a redirected or
piped invocation yields an EMPTY file at exit 0. The exit code is the verdict; `--format json` is
the way to capture the evidence.*

**Parity, stated at BOTH strengths, because the script and the claim are not the same thing.**
`release/Test-PublishedParity.ps1 -TreeRef 'refs/tags/v1.31.2^{}'` exits **0**
(`tree=1.31.2 ... published=1.31.2`), which is the VERSION-lag guard that script actually
implements -- it compares semver, never bytes, so quoting it alone would claim less than the words
"byte-identical parity" promise (the 000234 lesson, re-applied). The stronger BYTE claim was
derived separately and holds twice over. Structurally: the tag's tree object is
**56d9f7678a8ae68060ff9d045056035f5eb34fd0**, and the same tree id is reached from the ORIGIN side
without touching the tag at all (`git rev-parse origin/main~1^{tree}`), so tree identity is proven
by two independent paths rather than by restating the peel. And independently REPRODUCED: the
released tarball was rebuilt locally with the workflow's own invocation, `git archive
--format=tar.gz --prefix=powershell-lsp-1.31.2/ 8b331ca6`, and the result is bit-identical to the
published asset -- **2580245 bytes and SHA-256
`8efcda28a3fb166219d13312c2ecea135207e836e09cc62737034fd85253df63` on both**, the COMPRESSED
artifact rather than a decompressed tar stream, on Windows git 2.54.0 against a Linux runner's
output. That is a stronger reproduction than the v1.31.1 row's, which compared raw tar streams
because the gzip layer was not shown to be deterministic; here it is.

**Body and SBOM:** the published release body is **byte-identical, with no normalization applied
at all**, to `release/Get-ChangelogEntry.ps1 -Version 1.31.2 -OutFile` run against the CHANGELOG
at the TAGGED commit -- **11712 bytes and SHA-256
`602108eababda9eb76bc1e85de70923dc7c38f63cfef2fa0bba42c7b116afff8` on both**, 160 lines, 0
non-ASCII bytes. Both sides were captured byte-exactly and PROVEN so rather than assumed: the
tag's CHANGELOG was extracted with `git show` through a byte-preserving redirect and its
`git hash-object` re-computed to `727b868082610f5fb310b78a551235e4adb3dc34`, equal to the blob id
the tag's tree carries, and the extractor script itself was run FROM the tag
(`8b331ca6:release/Get-ChangelogEntry.ps1`, blob `f0a9b618...`) rather than from a working tree.
The published body was read out of the JSON field rather than off a pipeline, which matters
concretely: piping `gh release view --json body -q .body` through PowerShell line-splits the
string and rejoins it WITHOUT separators, silently welding word-ends together, and a comparison
against that corrupted capture would have manufactured a diff. The charter pre-authorized counting
a trailing-whitespace or CRLF difference as a match; none was needed. The CycloneDX **1.5** SBOM
lists the plugin at 1.31.2 plus exactly the two pinned dependencies at the versions the `ensure-*`
scripts declare at the tag -- PowerShellEditorServices **4.6.0** (`$PsesTag = 'v4.6.0'`) and
PSScriptAnalyzer **1.25.0** (`$PssaVersion = '1.25.0'`). *Stated exactly, because "SBOM pins" can
be read two ways: these are VERSION pins carrying `purl` coordinates. The SBOM carries no `hashes`
array on either component, so the SHA-256 pins that `ensure-pses.ps1` and `ensure-pssa.ps1`
actually enforce at download time are not readable from the SBOM alone -- the same findings-only
observation 000234 recorded, unchanged at this cut and not a defect of it.*

**The release-body sweep exits 0, and the v1.31.2 body is one of its MATCH rows.**
`scripts/audit-release-bodies.ps1`, run from a CLEAN checkout of `origin/main` rather than from
the shared clone (whose working tree carries another dispatch's uncommitted CHANGELOG edits, which
would have contaminated the expected side), reports `SELECTED 28 release(s); MATCH 25,
ACKNOWLEDGED 3, MISMATCH 0, STALE-ACK 0, ERROR 0` at exit **0**. The three acknowledged rows are
**v1.18.1**, **v1.27.1** and **v1.29.0**, and the v1.18.1 row is NEW this cycle -- added by PR
#175 with `PublishedSha256`
`e3edd3cd08543ecd4e45d3caf21462658595048a9942ef9f6d6b89e15cf68c45`, read from
`release/release-body-divergences.psd1` at `origin/main` rather than from the charter that cited
it. That v1.31.2 reports MATCH is a SECOND and independent confirmation of the body claim above,
taken against the CHANGELOG at the TIP through a whitespace-normalizing comparison, where the
header's claim is a byte comparison against the CHANGELOG at the TAG; the two agree because the
`CHANGELOG.md` blob is the same object at both refs.

**`gitsign verify-tag` PASSES on v1.31.2 -- the 000217 pin's THIRD cut, so the fix is confirmed
repeatable across every tag cut since it landed.** The command `docs/RELEASING.md` documents, run
verbatim from a normal clone (not a worktree; `rev-parse --git-dir` and `--git-common-dir` both
read `.git`) against the release workflow identity, returns exit **0** and this literal output:

```
tlog index: 2483343132
gitsign: Signature made using certificate ID 0x055e9d053dfa8b42e05ae072f98fa00852d086de | CN=sigstore-intermediate,O=sigstore.dev
gitsign: Good signature from [https://github.com/manderse21/claude-powershell-lsp/.github/workflows/powershell-lsp-release.yml@refs/heads/main](https://token.actions.githubusercontent.com)
Validated Git signature: true
Validated Rekor entry: true
Validated Certificate claims: true
```

**The "third cut" framing is DERIVED here rather than inherited.** The pin
(`go install github.com/sigstore/gitsign@v0.17.1`, read from the release workflow at the tag) has
been in force for exactly three tags, and all three were re-run this pass from the same clone with
the same verifier: **v1.31.0** passes at tlog index 2411627358, **v1.31.1** at 2454706139, and
**v1.31.2** at 2483343132. **The control that makes this a finding rather than a formality**,
re-run this pass rather than cited: the SAME command, from the same clone, with the SAME locally
installed gitsign -- still **v0.16.1**, because the verifier was never the broken side -- run
against **v1.30.0** still fails with `hashes don't match` /
`Error: failed to validate rekor entry: could not find matching tlog entry`, exit **1**. So the
discriminator remains the tag's SIGNER, not the verifier, the command, or the query, and a v0.16.1
verifier validating three consecutive v0.17.1-signed tags while rejecting the last v0.16.1-signed
one is the cleanest available statement of where 000217's defect lived. **What did NOT change,
stated plainly:** v1.30.0 and every earlier tag remain permanently unverifiable by `verify-tag`,
exactly as 000217 predicted and RELEASING.md documents. They are not re-signed, their entries stay
keyed where nothing reads them, and their signer identity was never in doubt -- 000215 proved it
cryptographically from the certificate and the CMS signature, and the release ASSETS carry their
own inclusion proofs regardless. The arc closes FORWARD, not retroactively. See Section 3 for the
root cause.

**The v1.28.x measurement record is PREDECESSOR detail and is not restated here.** Everything
dispatch 000169 measured directly for v1.28.0 and v1.28.1 -- each tag object's type, tagger, tagger
time, signed-message block and target commit; the commit distance from each tag to `origin/main`;
both manifest versions at each tag; the `userConfig` knob count and knob ORDER at each tag;
`base.psd1` and `rule-rationales.psd1` counts at each tag; each Release's
tag/draft/prerelease/publishedAt/author and both asset names; the `isLatest` flag across the top six
releases; the push-CI run and its four legs by name, headSha-matched per rule 000081; the full step
list of each release-workflow run separating the dry run from the producing one; and `gh attestation
verify` on all four assets, RED-probed against a tampered copy -- lives in the **v1.28.1 and v1.28.0
rows of the Section 2 release table**, relocated there by this pass per the 000161 leg-2 convention.

**The v1.29.0 cycle ran WITHOUT a separate dry run, and that is a departure from the shape the four
preceding cycles established** (derived by 000195 leg A from the run list and the run STEPS, not from
timing). Exactly ONE release-workflow run sits on the tagged commit: **30717384145**
(2026-08-01T20:37:22Z), and its step list is the PRODUCING shape -- "Build release notes, source
archive, and SBOM", "Attest build provenance", "Install gitsign", "Cut and push the gitsign-signed
tag FROM the pipeline" and "Create the GitHub Release" all `success`, with step 15 "Dry-run summary
(no tag cut, no release created)" **skipped**. Each v1.28.x and v1.27.x cycle showed a dry+producing
PAIR on its tagged commit; this one shows a single producing run, so the dry-run-judged-first
sequence Section 3 describes was NOT exercised on this cut. Recorded as an observed deviation rather
than smoothed over -- no gate was bypassed, but the judgement step the pair exists to create did not
happen.

**That departure is what Gate 6 was built to make impossible, and the v1.29.1 cycle is its FIRST
LIVE FIRING -- recorded by dispatch 000206 leg 2 from the producing run's own gate log.** Producing
run **31225541961** (`powershell-lsp release 1.29.1 [PRODUCING] target=HEAD`, `headSha` 6663dad)
ran the gate and it MATCHED, printing `OK: the dry-run pair is satisfied.` **The matched rehearsal
is run 31225513725**, named `powershell-lsp release 1.29.1 [DRY-RUN] target=HEAD`, created
2026-08-07T22:56:27Z against the same commit. **Two eligible dry runs existed** -- 31225480588
(22:55:49Z) and 31225513725 (22:56:27Z) -- with identical run names, identical `headSha`, and both
`success`. The NEWER one won, and that is a property of the decider rather than an accident:
`release/Test-DryRunPair.ps1` iterates the run list in the newest-first order the GitHub API
returns and `break`s on the first candidate that satisfies all four clauses (success,
discriminable-as-dry, inside the recency window, same target commit). Recorded because a reader
looking for "the" rehearsal will find two and needs to know which one the gate actually consumed.

**Gate 6's legacy-inspection cap fired a warning on this run, and it is decaying toward
IRRELEVANCE rather than toward a false refusal -- classified, findings only, zero workflow edits.**
The gate fetched **67** `workflow_dispatch` runs, dropped itself to leave **66** candidates, and
found **45** successful runs carrying no `[DRY-RUN]`/`[PRODUCING]` run-name marker, which exceeds
`LEGACY_CAP=20`; it announced that (`::warning::45 unmarked runs exceed the inspection cap of 20`),
classified the newest 20 by step-conclusion, and left **25** UNKNOWN. That is loud rather than
silent, which is the design. It cannot decay into a false refusal, for two independent reasons.
(a) **The unmarked population is CLOSED.** The run-name marker shipped in commit **37ce829**
(2026-08-06, 000197 leg 6), so every run created since carries one and no new unmarked run can ever
appear; the residue can only shrink, and the `per_page=100` fetch bound will shrink it further as
marked runs accumulate ahead of it. (b) **The cap is applied AFTER the marker filter, to a
newest-first list**, so in-window unmarked runs occupy a PREFIX of exactly the list the cap takes a
prefix of -- the cap can only exclude an in-window unmarked run if more than 20 of them fell inside
a single 3-day window, and none can be created now. Measured rather than argued: the newest
unmarked successful run is **30717384145 at 2026-08-01T20:37:22Z**, already **outside** the 3-day
window this run computed (cutoff 2026-08-04T22:57:25Z), so **zero** of the 45 could have satisfied
the gate whatever the cap did. The residual cost is real but bounded and self-retiring: 20 extra
`gh api` calls, about **9.7 s** of this gate's wall clock (22:57:15.15Z to 22:57:24.85Z), spent
classifying runs that are all provably out of window.

**The same warning fired again on the 1.30.0 cut, and dispatch 000215 re-derived the mechanism
independently and reached the same verdict -- still findings-only, still zero workflow edits.** The
producing run fetched **69** `workflow_dispatch` runs (up from 67) and again found **45** unmarked
successful runs against `LEGACY_CAP=20`, emitting one warning-level annotation on the `gated-release`
check-run: `45 unmarked runs exceed the inspection cap of 20; only the newest 20 are classified. The
remainder stay UNKNOWN and cannot satisfy this gate.` **The unmarked count did not grow** -- 45 then,
45 now -- which is the closed-population prediction (a) made, confirmed by observation one cut later
rather than argued. Two mechanism facts are worth pinning because a reader could mislocate them:
the cap lives in the **workflow** (`.github/workflows/powershell-lsp-release.yml`, `LEGACY_CAP=20`),
**not** in `release/Test-DryRunPair.ps1`, which merely consumes the `legacyIsDryRun` verdicts the
capped loop produces; and the matched rehearsal was classified by **run-name marker**, never by
legacy inspection, so the cap could not have reached it. Gate 6 matched dry run **31340131690**
(`powershell-lsp release 1.30.0 [DRY-RUN] target=HEAD`, created 2026-08-09T22:43:59Z) against
producing run **31340176181** (22:45:02Z) on the same commit 670646c, printing `OK: the dry-run pair
is satisfied.` The rehearsal was the newest run and 63 seconds old, so it sat far inside both the
3-day window and the cap's prefix. The hardening candidate therefore stands unchanged and
unurgent -- raise the cap, filter to the release workflow, or key on commit identity rather than
recency -- and the honest framing is the one this paragraph already gives: the warning is loud,
bounded, and self-retiring, not a latent refusal.

**The gate chain is nonetheless demonstrably load-bearing on this cycle, by a Gate 3 refusal.**
Release run **30716142017** (2026-08-01T20:03:37Z) was dispatched against commit **e972f33c** -- the
PR #119 merge for 000171, which landed the feature but not the version bump -- and **Gate 3
(version lockstep at the target commit) FAILED**, with Gates 4-5 and all six mutating steps
`skipped`, so no tag was minted and no Release was created against an unbumped tree. The lockstep
bump then landed as PR #120 (**1ed438fc**) and the producing run succeeded there. That is the same
demonstration v1.27.3 supplied at Gate 4, at a different rung.

**Push-CI on the tagged commit is green by name and headSha-matched per rule 000081:** run
**30717379535** (event `push`, head `1ed438fc`) `success` with all four legs -- `ubuntu-pwsh`,
`windows-powershell`, `windows-pwsh`, `macos-pwsh` -- green BY NAME, plus a green `sarif-upload` from
the separate code-scanning workflow (**30717379521**) on the same head. **v1.29.0's release-asset
attestations were deliberately NOT re-run by this pass:** dispatch 000195's `do_not` sanctions
exactly one `gh attestation verify` use, the read-only re-verification of the ALREADY-RELEASED
v1.28.0 assets carried out by its leg C, so no attestation claim for v1.29.0 is made here rather
than one being inferred.

**The install side is now current, and the auto-update decision is what is doing the work**
(verified-from-disk this session, out of `~/.claude/plugins/`). The marketplace-resolved install
reads **1.29.0** at `gitCommitSha 1ed438fc73e2b7556146a52551297b94b88fb5a6` in
`installed_plugins.json`, `lastUpdated` **2026-08-01T21:50:57.197Z** -- **after** the v1.29.0 Release
published at 21:00:13Z, which INVERTS the v1.28.1 observation this paragraph replaces: that clone
tracked the merge commit ahead of its Release, and this one followed the Release. That SHA is
byte-identical to the commit the pipeline tagged, and that identity is what makes the installed
plugin provably the released artifact rather than merely a plausible copy of it: the same commit is
the PR #120 merge and the `v1.29.0` tag target. It is NOT `origin/main`'s tip -- the tip is 30
commits further on -- so the installed clone tracks the released artifact, not the head of
development, which is the correct behaviour and is stated here because the v1.28.1 header could
collapse all three into one SHA and this one cannot. **Auto-update has visibly worked rather than
merely being enabled** (`known_marketplaces.json` -> `claude-powershell-lsp.autoUpdate: true`):
**seven** cached version trees now sit side by side under
`cache/claude-powershell-lsp/powershell-lsp/` (`1.23.1`, `1.27.1`, `1.27.2`, `1.27.3`, `1.28.0`,
`1.28.1`, `1.29.0`), which is the on-disk record of every hop since the freeze -- the clone that once
sat four releases stale at 1.23.1 has now followed six consecutive releases without intervention.

**v1.29.1 is SUPERSEDED as of 2026-08-09** (verified-from-web by dispatch 000215): it is still tagged
over commit 6663dadff9c4dc15026230949187cf7ea044d4f9 and its GitHub Release is still published
(2026-08-07T22:59:29Z, draft=false, prerelease=false), but `gh release list --json tagName,isLatest`
returned `isLatest=true` for **v1.30.0** and `false` for v1.29.1 when 000215 read it -- and that
badge has since moved again, to v1.31.0 on 2026-08-10; v1.29.1 held the Latest badge from
2026-08-07T22:59:29Z until 2026-08-09T22:47:30Z, a two-day tenure, and is now unbadged with tag and
Release both retained. **v1.29.0 is likewise superseded**, still tagged over commit 1ed438fc and
still published (2026-08-01T21:00:13Z), unbadged in the same read.

**v1.28.1 is SUPERSEDED** (verified-from-web): it is still tagged over commit e24439cc and its
GitHub Release is still published (2026-07-31T17:43:39Z), but `gh release list` badges v1.29.0
Latest and reports every earlier tag unbadged. **v1.28.0 is likewise superseded**, still tagged over
commit 57a61c5e and still published (2026-07-31T13:44:45Z, draft=false, prerelease=false). **v1.27.3,
v1.27.2, v1.27.1 and v1.27.0 too**, each still tagged and still published, none badged: v1.27.3 (tag
object 46bc1aac over commit b1a673f, published 2026-07-30T01:01:45Z), v1.27.2
(2026-07-29T16:03:29Z), v1.27.1 (2026-07-25T21:32:51Z), v1.27.0 (2026-07-22T22:30:18Z). **v1.26.0 and v1.25.1 too**: v1.26.0 still tagged (tag object c26e580 over
commit 22bec89) and published (2026-07-22T12:06:42Z), v1.25.1 still tagged (tag object f92ff79 over
commit c9692ca) and published (2026-07-19T00:41:38Z).

The whole **v1.24.x band is closed out**: v1.24.0 through v1.24.3 are each tagged on origin and
published as GitHub Releases (verified-from-web: `git ls-remote --tags origin` lists v1.24.0-v1.24.3
beside v1.25.0, v1.25.1, v1.26.0, v1.27.0 and v1.27.1). Neither v1.25.0 nor any of the v1.24.x band
holds the current-release badge.

**The v1.29.0 cut cycle is CLOSED, and it took three dispatches on one branch to get there.** 000171
ran the round-3 build train and landed per-rule lifecycle persistence as PR **#119** (merge commit
e972f33c), with its own leg 1 a named block on host quiescence; 000172 then fix-forwarded that same
PR clearing both chartered CI blockers and four banked defects; 000173 fix-forwarded it a second
time, repairing the unsound cross-clock killed-at-cap assertion at the test layer. 000174 cut the
release as PR **#120** (merge commit 1ed438fc) -- CHANGELOG first, lockstep bump second, both in one
commit -- and Mike Andersen merged it and triggered the pipeline, which refused once at Gate 3
against the unbumped #119 commit and then published v1.29.0 on 2026-08-01. This document's true-up
of that cycle is dispatch **000195 leg A** -- scheduled rather than remedial, in the 000155 /
000169 shape: no train in the cycle was chartered to edit the ledger, so the staleness was planned.

**The two v1.28.x cut cycles are CLOSED, and they closed back-to-back on one day.** 000166 ran the
review-response build train (legs B1-B12) and cut v1.28.0 as PR **#114** (merge commit 57a61c5e),
riding over PR #113 (000165 legs 2-3, the external-review register) and PR #112 (000163 leg 2, the
serve-shim instrumentation); Mike Andersen merged it and triggered the pipeline, which dry-ran, was
judged, and then cut and published the release on 2026-07-31. 000168 then ran the front-door
correction train (legs B1-B7) and cut v1.28.1 as PR **#116** (merge commit e24439cc), over PR #115
(000167 leg 2, the round-2 review register), and the same sequence published it under four hours
later. This document's true-up of both is dispatch **000169** -- scheduled rather than remedial, in
the 000155 shape: neither cut train was chartered to edit the ledger, so the staleness was planned.

**The v1.27.1 cut cycle is CLOSED.** 000153 shipped the Arc A slice-A1 reader and wrote the
marketplace listing correction (PR #103, merge commit 42dedb2); 000154 classified that entry live
from `origin/main`, cut v1.27.1 and HELD the PR (PR #104, merge commit dff1cd4); Mike Andersen
merged it and triggered the pipeline, which cut and published the release; and 000155 -- this
true-up -- swept the post-release residuals, removing the leftover plugin-side worktree and both
merged dispatch branches and bringing this document to ground truth. The preceding **Wave-2 + cut
cycle** is likewise closed: 000142 ran all seven legs and cut v1.27.0 (PR #99, merge commit
fddba38), and 000146 swept its residuals. The **Wave-1 + cut cycle** before that: 000136 / 000137 /
000139 merged (PRs #93 / #94 / #95), 000141 cut v1.26.0 (PR #97, merge commit 22bec89), and 000143
swept that cycle's residuals. Nothing about any of the three is outstanding.

Provenance: every version, feature, and dispatch claim below is verified against live state THIS
session -- `dispatch list --project powershell-lsp`, the dispatch log, `git log origin/main`, `git
describe --tags`, `git ls-remote --tags origin`, `gh release list`, `gh run list`, the CHANGELOG,
and the plugin/marketplace manifests. **Each status claim here is labelled verified-from-disk (read
out of this tree), verified-from-web (resolved live against origin / GitHub at run time), or
inferred (reasoned, not observed).** **A convention for the latest-claim sweep, so a future check can
be mechanical:** exactly one version is ever ASSERTED as current/Latest in this document, and it is
the live Latest -- today **v1.31.0** (this anchor is itself a currency claim and so is re-derived on
every true-up pass; 000219 found it reading v1.29.0, two releases stale, and moved it). Every other
occurrence of "latest" / "Latest" / "current
release" is either NEGATED ("no longer the current release (superseded by X)"), explicitly PAST
("held the Latest badge until X", "the then-current release"), or not a release claim at all (the
`StrictMode Latest` in Section 6 is a PowerShell language mode). A scan that flags a bare positive
assertion naming anything but the live Latest has found a real drift; the negated and past-tense
forms are true by construction and are the record this document exists to keep. Tag and release
state is NEVER copied from memory or from a
prior roadmap revision: it is resolved live, because that is exactly the claim that goes stale
fastest, and it has now gone stale SEVEN times in nineteen days. The 000127 leg-7 revision recorded
v1.24.3 as the then-current release, accurate at write time and stale the moment v1.25.0 published
on 2026-07-17; the 000134 leg-2 revision then recorded v1.25.1 as "PENDING, not released ... no
`v1.25.1` tag exists on origin", accurate at write time and stale the moment v1.25.1 was tagged and
published on 2026-07-19; the 000141 leg-2 revision recorded v1.26.0 as "PENDING, not released",
accurate at write time and stale the moment the pipeline tagged and published it on 2026-07-22; and
the 000142 leg-6 revision recorded the v1.27.0 cut as "staged but UNMERGED and UNRELEASED", accurate
at write time -- it sat behind open PR #99 -- and stale the SAME DAY, once #99 merged and the
pipeline cut and published the tag. The fifth was the one the 000155 revision corrected, and its
shape differed from the other four in a way worth naming: the document was never wrong about a
staged cut. The 000153 leg-2 revision recorded v1.27.0 as the then-current release, accurate when
written at 12:54 EDT on 2026-07-25, and it aged out roughly eight and a half hours later when the
pipeline published v1.27.1 at 21:32:51Z. 000154 deliberately made NO roadmap edit -- its scope_out
forbade one -- so that staleness was SCHEDULED rather than accidental, and 000155 was the planned
true-up rather than a repair.

**The seventh is the one THIS revision corrects, and it is the SCHEDULED shape once more.** The
000169 revision recorded v1.28.1 as the then-current release, accurate when written on 2026-07-31
and stale from **2026-08-01T21:00:13Z**, when the pipeline published v1.29.0. None of 000171, 000172,
000173 or 000174 was chartered to edit this document (three were build/fix-forward trains and the
fourth was release prep whose scope_out excluded the ledger), so the gap was again SCHEDULED, and
dispatch 000195 leg A is its planned true-up. What earns this instance its own sentence is a shape
none of the first six had: **the header went stale in a way that a version string alone does not
capture.** The v1.28.1 header could say "main sits EXACTLY ON the tagged commit" and be right; at
v1.29.0 that sentence is false by 30 commits, so advancing the version WITHOUT re-deriving the
distance would have produced a header that named the right release and still lied about the tree.
That is the argument for deriving every fact in the status paragraph rather than only the one that
obviously rotted -- which is what this pass does, and it is also why the charter that scheduled this
true-up was forbidden from asserting its own version claim onto disk.

**The sixth was corrected by the 000169 revision, and it is the fifth-instance shape again rather than
a new failure mode.** The 000163 leg-1a revision recorded v1.27.3 as the then-current release, accurate
when written on 2026-07-29 and stale from 2026-07-31T13:44:45Z when the pipeline published v1.28.0
-- then doubly stale four hours later at v1.28.1. Neither 000166 nor 000168 was chartered to edit
this document (both were build trains), so the gap was again SCHEDULED, and dispatch 000169 is its
planned true-up. What makes this instance worth its own sentence is that it went stale in **three
places at once and by different amounts**: the header said v1.27.3, Section 2's table stopped at
v1.27.3, and Section 3 still said v1.27.2 -- a drift the header had already outrun before v1.28.0
existed. That is the argument for sweeping the WHOLE file for latest-claims rather than advancing
the header alone. All seven were corrected by re-resolving against
origin, not by editing around the old text.

The fourth instance is the shortest-lived of the first four -- hours, not days -- and it is the one that
justifies the epoch branch 000143 built rather than merely illustrating it. The 000142 leg-5 check
is epoch-aware by construction, so at the moment of release it did not go quietly wrong: it switched
arms and reported MISMATCH against this document (staleStaged=2, relLatest=0), which is precisely
the signal that chartered this sweep. The check was correct and the document was stale; the fix, per
the 000143 lesson, was to true the document and leave the check byte-identical.

That third instance is what dispatch 000143 exists to close, and it carries a lesson the first two
did not surface. The 000141 leg-2 verify check derived every pin from a live artifact -- which is
the right instinct -- but a live-derived check still has an **epoch**. Written during the
cut-to-release window it asserted "the roadmap names the staged version as not-yet-released"; run
after the release it demanded the opposite of what it demanded at authoring time, and reported
MISMATCH against a roadmap that was merely out of date rather than wrong-at-write-time. A
version-agnostic check is not automatically time-agnostic. The fix applied in 000143 is an explicit
epoch branch (released-version == manifest-version selects the post-release assertions), plus this
true-up -- the document was brought to ground truth, and the check was NOT loosened to accept the
stale text.

Goal (Mike, confirmed): an open tool that is excellent and findable -- not a paid product, not
adoption-chasing. That "findable" goal is now acted on: the r/PowerShell and r/ClaudeCode launch
posts are LIVE (2026-07-05), and the in-repo launch draft (docs/launch/reddit-powershell.md, rewritten
to v1.23.0 ground truth) merged via plugin PR #77. The old "platform bet" framing (wait for Anthropic
to fix LSP registration) is retired: 000069 proved the registration failure was our own manifest, 000075
fixed it, and 000103 shipped an opt-in shim that un-gates native serve locally without waiting on the
upstream client fix. What remains upstream-gated is spelled out honestly in Section 1.

## 1. The native-LSP story, corrected

For most of this project the native LSP triad (hover / go-to-definition / find-references) was treated
as platform-gated -- built, verified, and parked pending an Anthropic fix. Two dispatches dissolved
that framing, and a third (v1.23.0) un-gated serve locally:

- **Registration -- restored, v1.18.1 / 000075.** Claude Code's runtime LSP registrar silently drops
  any `lspServers` entry declaring `restartOnCrash` or `shutdownTimeout` (both schema-valid, so
  plugin.json validates, but the registrar rejects them with no diagnostic). Our block declared both,
  so `.ps1/.psm1/.psd1 -> powershell` never registered. 000075 removed the two fields and added an
  allowlist guard; registration is re-proven on the fixed tree (the persisted 000069 probe harness,
  Claude Code 2.1.195).
- **Serve -- un-gated LOCALLY, v1.23.0 / 000103.** Once registered, Claude Code launches PSES but its
  LSP client times out during initialization on the `#1359`-class server->client handshake, so on the
  direct launcher native nav does not complete. The opt-in `nativeServe` knob (default `off`) ships a
  thin stdio proxy (scripts/pses-serve-shim.ps1) that, when set to `shim`, patches the forwarded
  `initialize` (disables `dynamicRegistration` so PSES advertises its nav providers statically and
  sends no `client/registerCapability`; drops the params-level `workspaceFolders` that trips a PSES
  Linux init NRE; ensures a `rename` capability) and answers the residual `workspace/configuration` +
  `window/workDoneProgress/create` locally -- so hover / go-to-def / find-refs / documentSymbol serve
  end-to-end WITHOUT the upstream fix, at ~1-2 ms added framing per round-trip. With the knob `off` the
  proxy is a transparent pass-through and native nav stays gated exactly as before. The shim is a
  workaround for an upstream client bug, so it is off-by-default and removable (point `lspServers` back
  at pses-stdio.ps1).

Two honest boundaries, stated everywhere this is described:

- **Upstream #1359 (serve handshake) is still open.** The shim routes around it locally; it does not
  fix the client. anthropics/claude-plugins-official#1359 is OPEN (verified live this session); our
  refreshed comment on it is posted (2026-07-05), but the upstream client fix has not landed. When it
  does, the shim becomes removable -- the report-only `doctor.ps1 -ProbeNativeServe` check (v1.23.0 /
  000104, off-by-default) automates the static-serving half of that re-probe and today reports "still
  gated -- the shim remains needed."
- **A second, independent Windows blocker (#73961) gates the whole native nav tier there.** On Windows,
  Claude Code 2.1.196-2.1.200's native LSP launcher refuses to spawn the registered server's bare
  `pwsh` command pre-spawn ("Command 'pwsh' not found or is in an unsafe location"), upstream of the
  shim, pses-stdio.ps1, and PSES -- so it is reached whether `nativeServe` is `off` or `shim`. It is
  not a powershell-lsp defect: dispatch 000107 reproduced the identical refusal on the official
  pyright-lsp plugin. It is filed as anthropics/claude-code#73961 (OPEN, verified live), documented as
  a known issue in v1.23.1 (000108), and the verdict is wait-for-upstream (no single
  `lspServers.command` string can be both a Windows `.cmd` wrapper and a cross-platform launcher, and
  the absolute-path workaround fails `claude plugin validate`). macOS/Linux native nav under these
  Claude Code versions is untested with the real client and is not claimed in either direction.

Crucially, none of this touches the plugin's real surface: per-file diagnostics ride the warm
PostToolUse hook over a different, unguarded shell-spawn path, so PSScriptAnalyzer diagnostics keep
working normally on Windows regardless of the native nav gate.

## 3. Release process -- hardened (the gate is structural, not convention)

The release path is enforced on three layers, all shipped, and every release from v1.19.0 through
**v1.28.1** -- the live Latest, re-read by 000169 on 2026-07-31 -- was cut end-to-end by it
(re-derived by 000169 rather than carried: `git for-each-ref refs/tags/*` reports **19** tags at
v1.19.0 or later -- v1.19.0, v1.20.0, v1.21.1, v1.22.0, v1.23.0, v1.23.1, the four v1.24.x, v1.25.0,
v1.25.1, v1.26.0, the four v1.27.x, v1.28.0 and v1.28.1 -- and **every one** is an annotated tag
object tagged by `github-actions[bot]` from the release runner, never a local tag. There is no
`v1.21.0` tag: that version was leapfrogged by v1.21.1 and never cut, which is why the band reads
19 tags and not 20):

- The gated release pipeline (`.github/workflows/powershell-lsp-release.yml`, `workflow_dispatch` only
  -- it never auto-fires on push or merge): five gates make a bad tag structurally impossible -- Gate 1
  target commit merged to main, Gate 2 tag does not already exist, Gate 3 version lockstep
  (plugin.json == marketplace.json == requested), Gate 4 four-leg push-CI GREEN by name (it WAITS for
  the run to reach a terminal state, then judges), Gate 5 tree-vs-published parity (the 000076
  divergence guard, `release/Test-PublishedParity.ps1`). It then builds the source archive + a
  CycloneDX SBOM, attests SLSA build provenance (`actions/attest-build-provenance`), and cuts the
  keyless gitsign-signed tag from the runner.
- 000080 (shipped): a tracked local pre-push guard that refuses a direct push to origin/main.
- 000081 (shipped): server-side branch protection on main -- require a PR, require the four named CI
  legs (`ubuntu-pwsh` / `windows-powershell` / `windows-pwsh` / `macos-pwsh`) green and strict, enforce
  for admins, block force-push and deletion.

Together the gated pipeline + the local guard + server-side protection make the gated flow the ONLY
path to main. v1.19.0 was the first release cut under all three, and **every release since has been
cut the same way, through v1.31.0** (verified-from-web by 000219). The worked example below is
**v1.28.1**, which was the then-current release when 000169 recorded it and has been superseded four
times since -- it is kept because it is the illustration, not because it is current: it went through
this pipeline end-to-end -- five gates green on a dry run (run 30652093671, every mutating step
skipped), then five gates green again on the real run that cut the tag and published the Release
(run 30652160554; Section 2). Since v1.29.1 the chain is **six** gates, Gate 6 having been added
that cycle; see Section 2's rows for each cut's pairing.

**The v1.27.2 cycle is the cleanest live demonstration yet that the gates are load-bearing rather
than ceremonial, and it is worth recording as a shape convention.** THREE release triggers landed on
commit `49ce894`, and the FIRST one FAILED CLOSED. Run **30465192187** was triggered at 15:18:13Z --
four seconds after the PR #108 merge -- and `Gate 4 -- push-CI is GREEN on every leg for the target
commit` refused it, because the push-CI run on that commit had not yet concluded green (its
`macos-pwsh` leg was failing the flake now recorded in Section 6). Nothing downstream ran: no
checkout, no build, no attestation, no tag, no Release. Only after the failed leg was rerun green did
the dry run (30468549931, 15:59:15Z) and then the producing run (30468710698, 16:01:06Z) pass all
five gates. The convention this establishes: **a merge is not a release trigger, and the gate --
not the operator -- is what enforces the wait.** The earlier v1.27.0 cycle demonstrated the same
property from the other direction, when a third trigger arrived two and a half minutes late and Gate
2 refused it because the tag it would have cut already existed.

**The pipeline cuts the tag. Always.** A printed `git tag` / `git push origin <tag>` pair is a
MANUAL FALLBACK for the case where the pipeline itself is unavailable -- never the release path, and
never something to run because a tool printed it. To release, trigger the `powershell-lsp release`
workflow with the target version; it validates, tags, signs, attests, and publishes as one gated
unit. The v1.26.0 cycle is the standing argument: a pre-existing hand tag had to be deleted before
Gate 2 would let the pipeline cut its own (Section 2), and only the pipeline's tag carries the
keyless gitsign signature and the SLSA provenance the trust surface advertises. `docs/RELEASING.md`
is the single-sourced runbook and states the same convention.

### 000217 -- the Rekor tag entries were MIS-KEYED, not missing (root-caused, fixed forward)

**The entry exists. It always did.** 000215 concluded no transparency-log entry existed for any
release tag, having searched Rekor for the SHA-256 of each tag's signed payload and received `[]`
three times. That query was wrong. Searching the same index by the tag's signing CERTIFICATE
(`POST /api/v1/index/retrieve` with `publicKey.format=x509`) returns exactly ONE `hashedrekord` per
tag, each with a full inclusion proof and a signed entry timestamp: v1.29.0 at logIndex
**2314546105**, v1.29.1 at **2374087615**, v1.30.0 at **2400946105**. What is true is narrower and
more specific than "missing": the entries are keyed on a hash **no verifier ever computes.**

**The cause is an internal sign/verify asymmetry in gitsign v0.16.1 -- the version the pipeline
pinned.** For the default `RekorMode=online` path, the signer
(`internal/git/git.go` `LegacySHASign`) reassembled the signed object with `pkg/git.JoinCommit` --
the COMMIT joiner, which writes the signature into a `gpgsig` HEADER -- unconditionally, whatever
the object's type. A real signed tag stores its PEM in the message BODY instead, so for a tag that
reassembly yields a synthetic object hash that is not the tag's hash; gitsign then signed that
synthetic hash string and uploaded a hashedrekord keyed on its SHA-256. The VERIFIER in the very
same version (`pkg/git/verify.go`) already dispatched `JoinTag` for `object `-prefixed data, so it
computes the REAL tag-object hash and looks up a key the signer never wrote. Sign and verify could
never meet for a tag; they meet fine for a commit, which is why only tags are affected.

**Derived, not asserted, and reproduced on all three tags.** Feeding each published tag's real
payload and signature bytes through the actual gitsign library reproduces the observed Rekor key
EXACTLY -- `SHA256(ObjectHash(JoinCommit(payload, sig)))` equals the entry's `data.hash` for
v1.29.0, v1.29.1 and v1.30.0, 3/3. The same inputs through v0.17.1's tag-aware
`git.ObjectHashFromSignature` return each tag's REAL object hash (`81a7b29b`, `75b5602d`,
`8dab6a38`), 3/3 -- which is precisely the key a verifier looks up. Two independent controls fix the
reading: the Rekor entry's certificate is byte-identical to the tag's signing cert (same serial), so
it is unambiguously this tag's entry; and the Rekor entry's signature is NOT the tag's CMS signature
-- it is a second signature over the synthetic hash string, which is what the legacy upload path
makes and what proves the entry is the signer's own artifact rather than a coincidence.

**Disposition: fixable pipeline-config cause, fixed forward -- the pin.** Upstream repaired this in
v0.17.0 by routing the signer through the same `ObjectHashFromSignature` helper the verifier uses,
so the two can no longer disagree. The whole fix here is therefore the version floor in
`.github/workflows/powershell-lsp-release.yml`: `go install github.com/sigstore/gitsign@v0.16.1`
becomes `@v0.17.1` (the current latest). Nothing else in the signing step changes -- same keyless
GitHub-OIDC flow, same Fulcio and Rekor URLs, same on-disk CMS signature format. A tag cut from here
on is keyed on its real tag-object hash and `gitsign verify-tag` can find it.

**What this does NOT do, stated plainly.** The three existing tags are NOT re-signed or re-tagged
and their entries stay keyed where they are, so `gitsign verify-tag` will keep failing on v1.29.0,
v1.29.1 and v1.30.0 permanently -- and it will keep failing under the FIXED gitsign too, because the
fix corrects the lookup to the hash the old signer never wrote. That is the honest cost of not
rewriting released history, and it is why `docs/RELEASING.md` documents the tag check as an identity
and signature proof rather than a transparency-log proof for tags cut before this change. Tag
transparency-log inclusion for those three remains unproven; signer identity for them is not in
doubt and never was, and the release ASSETS carry their own inclusion proofs independently.

**CONFIRMED on the first cut under the pin -- v1.31.0, by dispatch 000219.** This section's central
prediction ("a tag cut from here on is keyed on its real tag-object hash and `gitsign verify-tag`
can find it") was, until that cut, a claim about a code path this project had never exercised: the
keyless signing steps need a server-issued OIDC token and cannot be run locally or in a dry run, so
nothing short of a real release could settle it. `gitsign verify-tag v1.31.0` now exits **0** with
`Validated Rekor entry: true` at tlog index **2411627358** -- the first time that line has ever been
reachable here. **The control is what makes it evidence:** the same command, same clone, same
locally installed gitsign **v0.16.1** binary, run against **v1.30.0**, still fails with
`hashes don't match` / `could not find matching tlog entry` at exit 1. Only the SIGNER changed, so
only the signer can explain the difference -- which is the asymmetry diagnosed above, observed from
the outside rather than inferred from the source read. Note the verifier here is v0.16.1, not
v0.17.1: consistent with the diagnosis, since the verifier was never the broken side and needed no
upgrade. The arc closes forward; the paragraph above still governs everything cut before it.

### Gate 6's window: `WINDOW_DAYS=3` is RETAINED -- ratified, on the guarantee it actually makes

Gate 6's recency window was the **last unsettled control in the release chain**, carried as an open
ruling for Mike Andersen out of 000217 and still open when 000219 verified v1.31.0. **It is now
ratified RETAINED at its current value, unchanged.** No executable moved to record this; the ruling
IS that nothing should. Verified-from-disk at the ratification: the Gate 6 step in
`.github/workflows/powershell-lsp-release.yml` sets `WINDOW_DAYS=3` and passes it as
`-WindowDays "$WINDOW_DAYS"`, and `release/Test-DryRunPair.ps1` declares `[int] $WindowDays = 3` as
its own default, so the value is stated twice and agrees.

**The case for deleting it was strong, which is why it needed a ruling rather than a shrug.** Since
000217 leg D, Gate 6 pairs by COMMIT IDENTITY rather than by recency: the old `LEGACY_CAP=20`
newest-N slice is gone from the workflow -- verified-from-disk, the identifier does not appear in
that file at all, and what stands in its place is a comment recording why selecting on the target
commit *"removes it outright, and removes nothing else"* -- and the legacy fallback now filters
unmarked runs to the target commit, logging *"No run is dropped for being old."* Commit identity
pins the TREE. Gate 4 re-reads the CI runs and Gate
5 re-reads `origin/main`'s published manifest, both FRESH on the producing run rather than trusting
what the rehearsal saw. If the tree is pinned and every external read is re-taken at producing time,
an age bound on top of that looks like a vestige of the recency-matching era it outlived.

**It is not a vestige, because of the one thing neither commit identity nor Gates 4 and 5 covers:
the pipeline definition drifts.** The release workflow checks out `ref: main`, so any run --
rehearsal or producing -- executes the release workflow *as it stands at `main`'s tip when that run
starts*. The commit being tagged does not pin the workflow that tags it. A dry run three days old
therefore rehearsed a possibly older pipeline, and no identity check can see that, because the two
runs agree on exactly the thing that did not change. This is not hypothetical: **dispatch 000217
rewrote this workflow between cuts** -- the gitsign pin v0.16.1 -> v0.17.1, the tag-verify path, and
Gate 6's own pairing logic. A rehearsal from before that landed would have validated a pipeline that
signed tags a verifier could not find. So the window bounds how stale the rehearsal *of the
pipeline* may be, which is a specific, non-redundant guarantee. Three days spans the realistic
rehearse-Friday / cut-Monday pattern without letting a producing run lean on a week-old view of
either `main` or the pipeline.

**One residual is recorded rather than quietly closed.** The workflow's own inline comment at
`WINDOW_DAYS=3` still gives only the external-state half of the rationale, because 000220 was
chartered doc/record-only and may not touch a `.yml`. `docs/RELEASING.md` now carries the full
rationale including pipeline-definition drift, and this entry is its evidence layer; aligning the
workflow comment is a one-line follow-up for the next dispatch that opens that file for a reason of
its own. Recorded so the gap is a known deferral and not a discovery.

### The recorded-check authoring contract -- five points, earned by the 000219 F2

Dispatch 000219's verify pass returned **six MISMATCHes across its recorded checks**, and the
post-mortem found **one root cause in five costumes: the checks were not RE-RUN-SAFE.** They passed
where they were written and failed where they were re-run, which is the only place a recorded check
is ever executed again. A check that only holds in the session that authored it records nothing --
it is a claim wearing a command's clothes. The contract below is that root cause turned into
authoring rules, and it binds every dispatch from 000220 forward.

1. **SELF-ROOTING.** A check `cd`s to an absolute repository path, or passes one (`git -C <abs>`,
   `gh -R <owner>/<repo>`). It never inherits the cwd it happens to be launched in, and never
   depends on an artifact a prior step left behind. The verifier's cwd is not the author's.
2. **RE-RUN-TESTED BEFORE THE MINT.** Every check is executed from a scratch cwd -- not the repo,
   not the hub -- before the outbox is minted, and it is run **twice**, so that a check which
   silently consumes state fails in the author's session rather than at the gate.
3. **NEGATIVE CONTROLS ASSERT ON THE NON-ZERO EXIT.** A control exists to prove the check can fail.
   Asserting that a deliberately-broken input still exits 0 asserts nothing at all; the control must
   demand the failure. This is the polarity error, and it is the one that makes a dead check look
   healthiest.
4. **QUOTE EVERY REVISION AND SHELL METACHARACTER.** Both 000219 F2 classes were quoting: an
   unquoted `^{}` peel suffix, which the shell strips before git ever sees it, and a `gh` filter
   whose quotes broke across the shell boundary. If a revision or a filter expression reaches a
   shell, it is quoted.
5. **POST-MERGE INVARIANTS ARE ASSERTED AS ANCESTRY, NEVER AS TIP-EQUALITY.** `git merge-base
   --is-ancestor <tag>^{} origin/main`, not `<tag>^{} == origin/main`. A tip-equality assertion is
   true exactly until the true-up PR that carries the record merges -- that is, it goes false
   because the dispatch succeeded, which is the worst possible failure signature.

**This dispatch is the first authored under the contract, and it applied it to itself** -- its
recorded checks are self-rooting file-contains assertions, re-run twice from a scratch cwd before
the mint, with the negative control (no executable file in the diff) asserting on a non-zero exit.
The mechanical version of this -- a hub-side mint-time harness that refuses to mint a check it
cannot re-run -- is noted for the hub stream and deliberately not built here: the contract is the
part that belongs in this project's record, and a harness that enforces it belongs where dispatches
are minted.

### PK-staging refresh is a standard release close-out step

The Strategic-Claude **project-knowledge (PK) bundle** stages this repository's own documents for
planning, and it refreshes only when someone runs the collector. Nothing tied that to a release, so
the bundle drifted: the 000220 charter describes its own PK bundle as three releases stale, which is
why its `do_not` had to say *live file wins* and why every claim in this entry is labelled
verified-from-disk. A planning surface that lags the artifact it plans against does not merely go
quiet -- it confidently anchors work on retired facts. The cost is on the record one dispatch back:
the 000218 charter anchored a `plugins[].version` field that does not exist in
`marketplace.json` at all, and the deviation had to be found at execution time rather than at
authoring time.

**Recorded as a standing discipline: PK-staging refresh runs as a leg of every release close-out,**
alongside the CHANGELOG cut, the manifest lockstep bump, and this ledger's own true-up. The
collector is hub-side tooling and the powershell-lsp bundle is already configured there
(verified-from-disk in the hub: `tools/pk/Collect-PK.ps1` with a per-project entry in
`tools/pk/pk-projects.psd1`), so the step costs a command, not a build. **The claude.ai upload stays
manual by design** -- it is user-gated, and this discipline does not automate it or claim it as
done; it makes the staged bundle current so that the manual step has something current to upload.

## 4. Forward plan -- the four-horizon ladder (tactical -> strategic)

Forward work is a ladder, not a set of parked lanes. It climbs Immediate tactical (unblocked now) ->
Near-term tactical (survey-first cadence) -> Enterprise hardening (adoption-gating) -> Strategic /
what-if (the bets). Every build item names its gate and its output. No build dispatch is queued today
(the live `dispatch list` is authoritative on that -- Section 7); every item below is horizon work,
each gated on a future accept. The feedback-derived items come from a prior planning triage of a
10-item external-feedback set -- not a file in this repo -- carried here so they stop living only in
chat.

### The ratified next-wave arc ladder (strategic layer above the horizons)

Ratified by Mike Andersen 2026-07-23. The four horizons below stay the tactical detail -- the shipped
record and every per-item gate are unchanged. This is the strategic layer above them: the next wave,
named as five arcs, each drawing its slices from horizon items already inventoried below. Recording the
arcs sequences the wave; it does not retire or renumber any horizon item.

- **Arc A -- Diagnostic Efficacy Ledger.** Per-rule fired / fixed / ignored facts, mined from the
  shipped dogfood capture and the closed-loop cleared signal (the I0.3 accrual channel over
  `scripts/review-dogfood.ps1`). Facts, not scores (the S3.2 guardrail): reader-side aggregation of what
  the plugin already records, with no capture-format change and no new knob.
  - **Re-scoped by the external review, 2026-07-30 -- `arc-a-demand-signal-2026-07-30`.** The review's
    Priority 4 asks for product-level effectiveness metrics, and its headline -- the percentage of
    findings Claude fixes on the next turn -- is exactly the `fixed_next_turn` metric the 000148 leg 2
    survey proved NOT derivable from what the plugin captures today: deriving it requires the
    closed-loop `cleared[]` signal to be persisted PER-RULE, which nothing currently does. That
    persistence question was parked as an open question for want of a demand signal; this review IS
    the demand signal, so it is re-scoped from deferred to `cleared-persistence: resolve-in-build`
    for the Arc A build dispatch. Recorded here as a scoping decision ONLY: no Arc A build work is
    authorized by this entry, and the persistence design itself remains the build dispatch's to make
    (including whether the signal is persisted at all, if that dispatch's survey finds a cheaper
    derivation). Arc A's "no capture-format change and no new knob" framing above is what this
    re-scope puts back in question, and the build dispatch must adjudicate it rather than assume it.
- **Arc B -- Corpus Commons.** Publish the correctness oracle -- the corpus already used to prove the
  measured 0%-false-positive bar on every CI run (S3.4) -- as a community benchmark. CONTINGENT on the
  findability goal being resolved AND a licensing audit of corpus provenance passing (the oracle mixes
  repo scripts with installed-module scripts, so provenance is the gate, not an afterthought).
- **Arc C -- Attested Diagnostics.** Extend the SLSA / Sigstore chain from release assets (Section 3) to
  scan outputs -- attestable SARIF from the E2.1 code-scanning workflow. Third: it waits on real Arc A
  data and on a real Arc D consumer existing, so the attestation covers evidence a consumer actually
  reads.
- **Arc D -- Enterprise Control Plane.** Continuation of the shipped `orgPolicy` knob (E2.2): policy
  distribution and fleet SARIF / ledger rollup. DEMAND-PACED -- one slice per real adoption signal,
  never built ahead of a consumer.
- **Arc E -- Scale and Robustness.** A performance harness and characterized very-large-repo behavior.
  ON-DEMAND, issue-driven -- it moves only when a real scale problem is reported.

Sequencing, recorded verbatim: A first and unblocked now; D demand-paced; C third; B contingent; E on-demand.

Arc A is the opener because it is unblocked today and needs only reader-side aggregation over data the
plugin already captures; the other four are each held behind an explicit gate named above. E2.3 catalog
submission via the Console form is the queued next external action, deferred by Mike until this roadmap
update lands.

### The 10 feedback items -- disposition

| # | Suggestion | Verdict | Where it lands |
|---|---|---|---|
| 1 | Auto-fix write-back | SHIPPED | `formatOnEdit=apply`, v1.23.0 |
| 2 | Symbol graph | PARTIAL / forward | project-intelligence slice 1 shipped (v1.19.0); reference surfacing -> N1.2 |
| 3 | Cross-file reasoning | FORWARD (survey) | referenced-by-N via the diagnostic channel -> N1.2 |
| 4 | Repository memory | RESIST | persistent learned state; the agent's memory layer, not the plugin -> S3.3 |
| 5 | PS-specific refactoring | SCOPED to flagging | the plugin flags, no refactor engine -> N1.1 |
| 6 | Risk analysis / score | DROP score, keep facts | deterministic graph facts only -> N1.3 |
| 7 | Runtime intelligence | STATIC slice shipped | `moduleAwareness`, v1.23.0; the runtime version left -> S3.5 |
| 8 | Teach PS idioms | STRONGEST fit | rationale/fix-quality slices on shipped rules -> N1.1 |
| 9 | Explain why a rule exists | SHIPPED | rule-rationale strings, v1.24.0; coverage closed v1.24.1 (000124) |
| 10 | Learn from accepted fixes | SPLIT | closed-loop primitive shipped (v1.19.0); learn-team-style resisted -> S3.3 |

### Horizon 0 -- Immediate tactical (unblocked now; gated only on accept)

- **I0.1 Rule-rationale strings (#9) -- SHIPPED (v1.24.0 / 000121); coverage CLOSED (000124).**
  Delivered as a MINOR and, as planned, with no new knob; the `CONTRACT.md` amendment anticipated here
  turned out to be unnecessary, because additive prose on an existing channel leaves the frozen Tier-1
  surface (knob names, status tokens, and the "a clean pass adds nothing" property) untouched. The ship
  detail is in Section 2. Dispatch 000124 then hand-authored the one missing entry, so every
  plugin-owned code -- `BashIsm`, `CommandLinePlaceholder`, `ManifestConsistency`,
  `ModuleNotInstalled`, `NonAsciiChar`, `PS7OnlySyntax` -- carries a rationale, and
  `rulesets/rule-rationales.psd1` covers the plugin's whole surfaceable set (**53 PSSA + 6 owned =
  59 entries**, of which 9 PSSA entries carry hand-authored overrides -- the 4 idiom-family ones
  from 000125 slice 1 plus the 5 default-surface ones from 000142 slice 2) at the pin
  (re-resolved live, verified-from-disk this refresh: `base.psd1` declares 53 `IncludeRules`, and
  the table's own `pssa_count` = 53, `owned_count` = 6, `override_count` = 9, entries = 59; the
  owned count reached 6 when v1.26.0 / 000139 added `CommandLinePlaceholder`, which this line had
  not yet absorbed). The PSSA count dropped by one when v1.24.3 / 000126 excluded
  `PSUseOutputTypeCorrectly` from base; this line still carried the pre-000126 count until this
  refresh -- the residual 000126 recorded and this dispatch closes. (The superseded number is
  deliberately not restated here: quoting a stale count inside the correction is what makes a
  future drift-grep match the very string it is meant to catch -- the 000123 vacuity lesson.)
  Nothing about I0.1 is open. The
  graceful-degrade path itself is unchanged and still load-bearing: a rule outside the `base.psd1`
  surface (one a user's own settings file enables) surfaces its finding with no rationale line, never
  fabricated, never blocking.
- **I0.2 Post the registrar-field-rejection upstream report -- RESOLVED (no code).** The novel
  silent-drop finding (000069) is filed: Mike rewrote `anthropics/claude-code#66987` (OPEN) on
  2026-07-06 into the comprehensive registrar-drop report, re-confirmed on Claude Code 2.1.201. The
  routing question that made this an open item is settled -- do NOT open a fresh issue, since `#66987`
  already is the dedicated, open, has-repro registrar-drop issue and a second would split the signal.
  A drafted plugin-guard follow-up comment is post-ready and still unposted, but it is optional and
  low-priority: 000120 leg 3 recommends holding it for a natural occasion (a maintainer question, or a
  nudge if the issue goes quiet) because it advances nothing toward a fix.
- **I0.3 Begin the dogfood accrual.** Dogfood normal edits of the canonical checkout, then run
  `scripts/review-dogfood.ps1`. This is the only thing that unblocks the quality wave (N1.4);
  behavioral, not a dispatch. Output: the ranking that authorizes the first curation slice.

### Horizon 1 -- Near-term tactical (survey-first, one slice per dispatch)

- **N1.1 Idiom rule-pack slices -- rationale/fix quality (#8; #5 as flagging).** The 000124 survey
  measured the idiom candidates and corrected the premise: none clears a 0%-measured-FP bar as NEW
  detection. Two already ship built-ins -- `PSShouldProcess` (inside the PSES-15 default surface) and
  `PSAvoidUsingWriteHost` (base-only) -- and the verb-triggered
  `PSUseShouldProcessForStateChangingFunctions` was deliberately excluded as noisy (000092). So the
  slices are GUIDANCE quality: hand-authored rationale/fix OVERRIDES on rules that ALREADY fire, riding
  the v1.24.0 rationale channel -- not new rules. Slice 1 (000125): the owned rationale-override layer
  over the 4-code idiom family (`Write-Host` -> `Write-Information`, `PSShouldProcess`,
  `PSUseSupportsShouldProcess`, `PSAvoidShouldContinueWithoutForce`), anchored on `PSShouldProcess` (the
  only one on the default surface). The `ThrowTerminatingError` candidate stays DEFERRED-unmeasurable:
  the plugin's own source has zero `[CmdletBinding()]` advanced functions and the clean oracle no
  `throw`, so no advanced-function rule can be FP-measured until a corpus tier is added. The plugin
  flags; the agent transforms. Output: PATCH per slice (better guidance on findings that already
  render, not a new capability).
  **Slice 2 SHIPPED (000142 leg 2; released in v1.27.0).** Where slice 1 was mostly
  `base`-only opt-in rules, slice 2 covers what the median user actually reads: the **five PSES-15
  live-default-surface** rules whose derived text explained nothing --
  `PSAvoidDefaultValueSwitchParameter`, `PSAvoidUsingCmdletAliases`,
  `PSPossibleIncorrectComparisonWithNull`, `PSUseApprovedVerbs`, and
  `PSUseDeclaredVarsMoreThanAssignments`. The already-fires evidence is **measured, not asserted**
  (verified-from-disk): every one of the five appears in the DERIVED corpus snapshots under
  `tests/corpus/expected`, which `Update-CorpusSnapshots.ps1` produces from real analyzer runs. Each
  derived text was circular (restating the rule's own CommonName), definitional-and-truncated, or
  pure mechanism (restating the check's predicate); each replacement names a concrete consequence
  and a fix. The two most falsifiable claims were **verified on-host rather than reasoned about**:
  `curl`/`wget` resolve to `Invoke-WebRequest` aliases under Windows PowerShell 5.1 but not under
  PowerShell 7, and `@(1, $null, 2) -eq $null` returns an `Object[]`, not a boolean. Override count
  4 -> 9, `-Check` green at pin 1.25.0; the sixth default-surface rule,
  `PSAvoidUsingPlainTextForPassword`, was deliberately LEFT ALONE because its derived text already
  carries a real why. Three Integration assertions that pinned the derived `PSUseApprovedVerbs` text
  now pin the override, which is the live-daemon proof the layer reaches the default surface.
- **N1.2 Cross-file reference surfacing (#2 / #3) -- SHIPPED (v1.25.0 / 000128).** Shipped as the
  `referenceSurfacing` knob (default `off`): a deterministic "referenced by N files" signal via the
  diagnostic channel -- NOT the gated native-nav path. The 000127 survey settled the design, named
  one CONTRACT stop; 000128 made that decision (the frozen-knob amendment) and shipped the knob.
  The design record below is retained, now realized:
  - **Index strategy: SETTLED -- session-start index, not a per-edit scan** (measured this session,
    verified-from-disk, pwsh 7.6.3, 30 iterations per point). A per-edit full workspace scan costs
    **p50 1902 ms** on this repo (130 files), **1618 ms** at 200 files and **5359 ms** at 1000 --
    11x-36x over the 150 ms per-edit budget at every size. It is not viable and no tuning saves it.
    A session-start index costs **1.4-4.8 s ONCE** (130 / 200 / 1000 files) and then makes each edit a
    parse of the EDITED FILE plus hashtable lookups: **p50 5.3 ms at 200 files and 3.9 ms at 1000**.
    The structural point: per-edit cost is O(edited file), NOT O(repo) -- it does not grow with the
    workspace. The one-off index build fits the 000101 session-start seam exactly, which already pays a
    survey-measured ~6.3 s (pwsh) / ~11.7 s (5.1) installed-modules snapshot on a background runspace
    off the critical path; 4.8 s at 1000 files sits inside that established budget.
  - **The one measured caveat, recorded rather than smoothed:** on this repo the per-edit p50 is
    **212 ms** -- over budget -- because the survey deliberately picked the WORST file in the tree
    (`scripts/lib/lsp-common.ps1`, 2655 lines / 88 functions) and re-parsing it dominates. The fix is
    named and cheap: the daemon ALREADY parses the edited file for `moduleAwareness`
    (`Get-ModuleAwarenessFindings`), so the reference pass must SHARE that parse rather than add a
    second one. Budget-met is a design constraint on the build, not an open question.
  - **Ambiguity ledger, every entry resolving to SILENCE** (the 000101 rung discipline, reused
    verbatim): dynamic invocation (`& $name` -- `GetCommandName()` returns `$null`); a dynamic
    dot-source (`. $path`) or any include that does not resolve to a readable, parseable file
    (suppress the file); string-built names; duplicate definitions of one name across files (a
    "referenced by N" that cannot say WHICH definition is referenced is not a fact); and a splatted or
    computed call target. A missing count costs nothing; a WRONG count teaches the user to distrust
    every count.
  - **Shape: BARE FACTS, no new plugin-owned diagnostic code** (000127 OQ1, decided). `owned_count`
    stays **5**; `rulesets/rule-rationales.psd1` and its generator are untouched. All five existing
    owned codes name something WRONG that the user should fix; "referenced by 3 files" names nothing
    wrong -- there is no defect and no fix. A diagnostic code carries an implicit "change this", and
    the rationale layer those codes now attract (000121/000124/000125) answers "why does this rule
    matter" -- a question a fact does not have; satisfying the coverage guard would mean fabricating a
    rationale for a non-rule. The right shape is the one the tree already uses for non-defect signal:
    a distinct labelled section on the existing `additionalContext` channel, as `Project
    intelligence:` (000062) and `Correction check:` (000061) already do. No new status token.
  - **NAMED STOP (why 000127 blocked; RESOLVED at 000128):** the build needs a
    `referenceSurfacing` userConfig knob, and `CONTRACT.md` section 1.1 freezes the knob-name SET
    drift-guarded to equal `.claude-plugin/plugin.json` **exactly**. Adding the knob to the manifest
    was PROVEN to turn BOTH the CONTRACT guard and the README guard RED (run this session, then
    reverted; the guards were re-run green afterwards). So the knob cannot ship without a
    `CONTRACT.md` FROZEN-KNOBS amendment -- which every prior knob got as a deliberate, documented
    MINOR (`formatOnEdit`/000059, `ruleset`/000087, `moduleAwareness`/000101, `nativeServe`/000103).
    That amendment is a frozen-surface decision reserved to Mike, and 000127 ran unattended under
    NIGHT_PROTOCOL, which names a CONTRACT need as a stop. **Nothing was built under 000127.**
    RESOLVED at 000128: Mike made the frozen-knob decision and the MINOR shipped as
    `referenceSurfacing` with the lockstep CONTRACT amendment (v1.25.0).
- **N1.3 Graph-facts surfacing (#6 core) -- SHIPPED with N1.2 (v1.25.0 / 000128).** Reference
  count / is-exported / called-from-N as facts, the score dropped. Folded into N1.2 and shipped
  with it -- the `referenceSurfacing` facts ARE referenced-by-N, exported, and defined-in.
- **N1.4 Quality-wave curation.** Exclude-only curation and config-tuning of the kept base rules, the
  same discipline as v1.21.1; cut a rule only when `review-dogfood.ps1` over accrued genuine captures
  ranks it net-noise. The clock is real usage (Section 5). Output: PATCH.
- **N1.5 Closed-loop latency benchmark -- MERGED to main (000127 leg 3).** Turns the 000061
  correction loop's structural latency claim into a measured median + p95 alongside the warm-hook
  baseline, from a rerunnable on-demand harness (`tests/bench/Invoke-LatencyBench.ps1`, reusing the
  000040 `tests/bench/` primitives -- which is where the placement question was already answered on
  disk). Cold start is excluded and said so; the harness verifies the lifecycle signal ACTUALLY fired
  rather than timing a plain warm turn and labelling it a closed loop. Numbers + method live in
  `docs/benchmarks.md`. Not CI-wired, deliberately: a single-machine number is indicative, not a
  regression gate (`tests/PowerShellLsp.Benchmark.Tests.ps1` still owns the guarded thresholds).
  Both `tests/bench/Invoke-LatencyBench.ps1` and `docs/benchmarks.md` are now ON MAIN
  (verified-from-web).
- **N1.6 Project-intelligence slice 2 -- `AliasesToExport` orphan check SHIPPED**
  **(v1.25.0 / 000128 leg 3).** The 000127 leg-4 survey ranked three candidates by measured FP on a
  known-good oracle (then 72 installed module manifests) rather than by architectural taste; it
  ranked the `AliasesToExport` orphan first, and 000128 shipped it after closing the "qualified"
  oracle gap named below. The survey record:
  - **Ranked first: `AliasesToExport` orphan** -- a name in `AliasesToExport` with no matching alias
    definition. It is the residual the SHIPPED code names itself (`Test-ManifestConsistency` in
    lsp-common.ps1 records "Only FunctionsToExport is checked in slice 1; CmdletsToExport and
    AliasesToExport are recorded but not cross-referenced"), it is exactly symmetric with the
    orphan-export check slice 1 already ships, and the machinery exists
    (`Get-AliasDefinitionNameFromCommand` + the degrade ladder).
  - **The measurement, and the correction it forced:** a naive root-module-only implementation fired on
    **2 of 5** alias-declaring modules (40%). Both hits were FALSE POSITIVES *of the probe*, and each
    named a REQUIRED degrade rung: Pester defines its aliases through an indirection
    (`& $SafeCommands['Set-Alias'] ...`, so `GetCommandName()` is `$null` -- the 000101 rung-0
    predicate already silences this), and BurntToast manages alias export via
    `Export-ModuleMember -Alias`. So the 2 hits are the candidate's REQUIREMENTS SPEC, not evidence
    against it.
  - **FP-measurement path (named, and the reason this is "qualified"):** this box offers only **5**
    alias-declaring script-rooted modules -- far too small a denominator for the 0%-FP bar this project
    holds itself to (000091 measured on 34, 000126 on 44). The path is: enlarge the module oracle to a
    defensible denominator (a pinned, offline-able snapshot of top PSGallery modules), implement the
    two rungs the measurement named plus nested-module and dot-source degrades, then require 0% FP with
    every hit triaged by hand. **This gap is now CLOSED (v1.25.0 / 000128 leg 3):** the oracle was
    enlarged to 79 installed manifests plus four corpus fixtures modeling the two probe shapes the
    survey named, the dynamic-invocation / non-literal / `Export-ModuleMember -Alias` /
    nested-module / dot-source degrades were implemented, and the check measured **0%
    false-positive** -- the evidence
    bar this project holds a new detection to (000091 / 000092 / 000125). It rides the same
    `ManifestConsistency` code (no new owned code, no rationale-table change) and no knob.
  - **Nested-module consistency -- MEASURED, NO-BUILD, now CLOSED (000142 leg 3).** Surveyed under
    the same measure-first bar, and the measurement is decisive against building it
    (verified-from-disk, this box): of **111** parseable installed manifests, **73** declare
    `NestedModules`, but only **17** both name a script (`.psm1`/`.ps1`) nested module AND carry a
    literal `FunctionsToExport` list -- the only shape an AST cross-reference could check. A probe
    built from the SHIPPED helpers (`Resolve-ModuleRootModulePath` + `Get-ModuleDefinedFunctionNames`)
    fired on **17 of 17 (100%)**, and hand-triage of the hits found **no confirmed true positive**:
    `SmbShare` (59 exports; 17 `.cdxml` nested modules beside one 7-function `.psm1`),
    `EventTracingManagement` (20 exports; 3 `.cdxml`), and `AppvClient` (2 exports; a BINARY nested
    module) all export commands that are **CIM-generated or compiled**, which no source parse can
    resolve. The root cause is structural, not fixable by more degrade rungs: `NestedModules` is
    precisely the mechanism by which in-box modules compose CDXML and binary submodules. So this is
    the **same FP-hostile class as `RequiredModules`**, and it fails the 0%-FP bar by the widest
    margin yet measured on this project. The measurement also **positively confirms the existing
    degrade is correct**: silencing the check when `NestedModules` is non-empty (shipped in 000128)
    is exactly right, and lifting that silence would surface ~100% false positives. Recorded
    no-build, in the 000127 shape -- N1.6 is now decided, not parked.
  - Still deferred: `RequiredModules` vs project reality (FP-hostile -- a module legitimately
    required for types/formats/side effects is referenced by no `CommandAst`, and the probe's 0%
    rests on a denominator of **1**, which settles nothing).

### Horizon 2 -- Enterprise hardening (parallel track; adoption-gating)

- **E2.1 SARIF / CI deepening -- CLOSED; the code-scanning workflow is ON MAIN (000127 leg 5), then
  hardened by the 000131/000132 diagnosability work.** This
  item was written as "SARIF upload to code scanning **plus an exit-code policy gate**". Half of it was
  already shipped and the roadmap did not know: **the exit-code policy gate has existed since v1.19.0 /
  000057** as `lsp-scan.ps1 -FailOn none|note|warning|error` (default `none` never gates; exit 2 when a
  finding is at or above the threshold) -- verified-from-disk this session in the script, the README,
  and the CHANGELOG's v1.19.0 entry. What was genuinely missing, and is what 000127 leg 5 built: (a) an
  exit-code MATRIX pinning that policy (it had none, so it could drift silently) plus a wiring test
  proving the CLI flag reaches the exit code; (b) the code-scanning UPLOAD itself
  (`.github/workflows/powershell-lsp-code-scanning.yml`) -- a separate workflow, inert until merged (no
  `pull_request` trigger), `upload-sarif` pinned by commit SHA because it is the only step in the
  repository holding `security-events: write`, scanning `scripts/` rather than the root because
  `tests/corpus/samples/` is deliberately-bad code by construction. The workflow is now ON MAIN and
  its post-000131/000132 diagnosability surfaces -- each unanalyzable file NAMED (SARIF
  `toolExecutionNotification` + stderr + annotation) with the ELAPSED ms it ran -- make a future
  INCOMPLETE attributable from the Actions tab; main's own run flipped RED -> GREEN at the #91 merge
  (run 29661464779 success at 85fb892; see the scan-robustness lineage in Section 2). Output: **not
  the MINOR this item assumed** -- see leg 8's NO-BUMP reasoning; the gate it named was already
  released, and a repo-CI workflow is not a user-visible capability.
- **E2.2 Org policy config -- SHIPPED (000142 leg 1; released in v1.27.0).** The
  centrally-managed settings voice now exists as the `orgPolicy` knob (verified-from-disk): an
  absolute path to an organization's `PSScriptAnalyzerSettings.psd1` whose **`ExcludeRules` are
  enforced** as a final subtractive drop over the surfaced findings, applied at BOTH client surface
  points and before the hook emit and the dogfood capture, so a rule the org excludes cannot be
  re-enabled by a repo-local settings file or by `ruleInclude`. The include path is deliberately
  asymmetric -- the policy's own `IncludeRules` stay advisory and repo-local wins -- which is the
  fork 000135 decided and recorded. Client-side by construction, so the daemon and the Integration
  suite are structurally untouched; every branch is gated on the knob, and with it unset the surface
  is byte-identical (proven over the shipped corpus records, not merely asserted). Fails open with
  exactly one logged warning on a missing / unreadable / unparseable / relative path, and the policy
  is read through `Import-PowerShellDataFile` (restricted, data-only), so it can never execute code.
  One `CONTRACT.md` FROZEN-KNOBS row, proven RED then GREEN against the set-equality guard. Output
  was as forecast: MINOR + a CONTRACT amendment. **Known limitation (verified-from-disk):** the
  per-file-cap overflow count (`... and N more`) is computed daemon-side, before the org drop, so
  with `orgPolicy` set that count can include findings the policy would have dropped; the drop
  itself is exact. 22 unit tests across three families, four of them mutation-proven RED.
- **E2.3 Catalog listing.** Get into `anthropics/claude-plugins-community` (and the official catalog if
  it qualifies). Mike-gated. Output: no code. **Poll re-run 000142 leg 4 (read-only, one GET,
  verified-from-web):** `claude-powershell-lsp` is still **NOT present** in that marketplace --
  HTTP 200, **2262** plugin entries, **zero** entries whose name matches `powershell` at all, polled
  **2026-07-22T20:50:16Z**. The catalog grew by 14 entries since the 000127 leg-6 poll (2248 on
  2026-07-17), so the feed is live and the absence is a real negative, not a stale read. Nothing is
  inferred about Console-side state in either direction; the submission itself stays Mike's gate.
- **E2.4 Bus-factor mitigation -- DOCS SHIPPED (000136; released in v1.26.0).** The single-maintainer
  risk is the real enterprise blocker. The documented half is now in the tree (verified-from-disk):
  `docs/CONTINUITY.md` gives, per surface, what breaks if the sole maintainer disappears and the
  concrete recovery path; `MAINTAINERS.md` is a second-maintainer on-ramp (access grants, running
  and verifying a release, the strategic-dispatch hub relationship stated honestly as external to
  this repo); and the release runbook is single-sourced to `docs/RELEASING.md` so the recovery path
  has one address. Key custody is documented as a NON-issue by construction -- releases are keyless
  (gitsign / Sigstore OIDC), so there is no long-lived signing key or release secret to hand off.
  What remains is the part docs cannot supply: **an actual second maintainer**. Output so far:
  docs; the item stays open on the human half.
- **E2.6 Trust-evidence surface -- SHIPPED (000137; released in v1.26.0).** `docs/trust.md`
  (verified-from-disk) assembles in one evaluator-facing place the release-integrity chain that was
  already true but scattered across TRUST.md / docs/RELEASING.md / SECURITY.md: the keyless
  gitsign-signed tag and SLSA build provenance over both release assets, the CycloneDX SBOM
  generated from the real pins, the pinned and SHA-256-verified PSScriptAnalyzer, the measured 0%
  corpus false-positive bar guarded on every CI run, the measured latency in `docs/benchmarks.md`,
  the SHA-pinned code-scanning workflow, and the generated per-finding rule rationale (E2.5). README
  gains a short "Why trust this release" pointer. Docs-only: every claim links to a file or a
  released artifact, so the page asserts nothing the repo cannot show. Output: docs.
- **E2.5 Rule-rationale as an audit surface -- LIVE.** I0.1 shipped in v1.24.0, so this framing is no
  longer prospective: every surfaced finding already carries a "why" that is generated, not asserted --
  traceable to the pinned analyzer's own metadata and regenerable under `-Check`. No extra build; the
  enterprise framing is now a claim the tree supports.

### Horizon 3 -- Strategic / what-if (the bets; not committed work)

- **S3.1 Retire the native-nav workaround.** Upstream-gated, monitor-only. When the
  `anthropics/claude-plugins-official#1359` (OPEN) client fix lands, `doctor.ps1 -ProbeNativeServe`
  flips to removable and a PATCH drops the shim default; when `anthropics/claude-code#73961` (OPEN)
  lands, the Windows known-issue note clears.
- **S3.2 Positioning held firm (guardrail).** Concede the editor; own headless + in-loop + AI-era
  correctness. Do NOT adopt the "AI Intelligence Layer" / "Architect" identity -- it is unfalsifiable,
  it spends the earned credibility, and it licenses scope creep. This guardrail governs which what-ifs
  move up.
- **S3.3 Agent-layer memory -- deliberately out of plugin scope.** Repository memory (#4),
  learn-team-style (#10), and risk scoring (#6 as a score) introduce persistent / learned /
  unfalsifiable state; if ever wanted they belong in the agent's memory layer consuming the plugin's
  deterministic signal, never in the plugin. Recorded, not backlog.
- **S3.4 Deferred rules -- the placeholder check RE-ENTERED and SHIPPED (000139; released in v1.26.0);
  the compat pair still deferred.** The bar was: re-enter only as a MINOR at a proven 0%
  false-positive rate on the widened corpus, via the 000096 pre-PSSA AST pass. The
  angle-bracket-placeholder check cleared it exactly that way and shipped as the plugin-owned finder
  `CommandLinePlaceholder` -- measured **0% FP on a 281-file oracle** (150 repo scripts + 131
  installed-module scripts, zero hits), token-level detection at the `scripts/lsp-client.ps1` seam,
  always-on additive, owned finders 5 -> 6 (verified-from-disk), no knob and no CONTRACT change.
  This is the measure-first bar working as designed: the check was deferred on suspicion of false
  positives, and it re-entered only once the suspicion was measured and refuted.
  `PSUseCompatibleCommands` / `PSUseCompatibleTypes` remain **unshipped and deferred** -- they are
  blocked on a target-profile decision (which PowerShell editions/versions to compat-check against),
  not on a corpus measurement, so the 0% bar does not by itself clear them.
  **The bar has now also produced its first REFUSAL, which is the same mechanism working in the
  other direction (000159 leg 3).** The scalar-`.Count` finder was chartered to ship only at 0%
  measured false positives on the widened oracle; the re-enumerated 325-file oracle returned 28 hits
  at a **7.14% minimum** false-positive rate, so it is a **recorded NO-BUILD** -- no finder, no
  CHANGELOG entry, no second PR, owned finders unchanged at 6. The failing shape is structural: the
  `Measure-Object` allowlist keys on `CommandAst.GetCommandName()`, which is `$null` for a dynamic
  invocation `& $expr`, so it cannot see Pester's `& $SafeCommands['Measure-Object']`. Section 2
  carries the full record. **The measure-first bar is only credible if it can say no, and this is
  the instance where it did** -- the same bar that RE-ADMITTED the placeholder check above refused
  this one, and the number was not rescued by narrowing the classifier until the counter-example
  disappeared. A finder for this class is not scheduled; if one is ever chartered, the 000159 outbox
  records the two candidate designs and names option (a) -- an explicit degrade whenever ANY pipeline
  element is a dynamic invocation -- as a hypothesis from the data rather than a measurement.
  **The bar has now produced a SECOND refusal, and this one refused a FIX rather than a new finder
  (000161 leg 3).** The `ManifestConsistency` `FunctionsToExport` class was chartered to ship a fix
  only at a measured 0% false-positive rate. Re-measured on a 36-module live oracle it stands at
  **100% FP (911 of 911 under-declared hits, zero true positives)**, and the one candidate narrowing
  -- restrict to modules carrying an explicit `Export-ModuleMember` -- measures **96.15% FP (25 of
  26)**, so no subclass measured clean and the pre-authorized no-build fork applied: no code, no
  CHANGELOG entry, no PR. The distinction worth keeping is that the two refusals differ in kind. The
  000159 refusal declined to ADD a check that would have been wrong. This one declined to CHANGE a
  check whose correct fix turned out to be a **behaviour removal** nobody had authorised -- a bigger
  action than the charter contemplated, and therefore a ruling to surface rather than a change to
  make. Section 6 carries the full measurement and the ruling that is now outstanding.
  **Separately, and not a deferred-rules item at all:** `ManifestConsistency` already ships and is
  measured false-positive-dominated on real-world modules, with the `FunctionsToExport` class accepted
  as a recorded deviation. That is a correctness gap in a shipped check rather
  than a deferral of a new one, so it lives in Section 6, not here.
- **S3.5 Runtime intelligence, full (#7).** Runtime execution capture is a different architecture with
  real privacy / scope questions; the static slice (`moduleAwareness`) is the committed extent, and the
  runtime version is a deliberate leave.

### How each step lands

Every H0-H2 build entry becomes a survey-first dispatch pair under the existing flow: author ->
accept -> CC executes in a worktree -> Mike holds all gates. Ground truth (the live `dispatch list`,
the log, file inspection) stays authoritative over this roadmap.

## 5. Paced by the dogfood log (cannot compress)

The capture engine (000039) and the annotation/review tool (000043) are shipped. 000066 confirmed the
hook is path-transparent and the live 0-of-N genuine-repo-path count is an exercise gap, not a defect.
The quality wave has produced its first shipped output: 000084 and 000090 seeded genuine-repo captures
(the `pses-default` surface, then the broadened `base` surface), 000091 ranked the base surface for
false-positive / noise over the known-good corpus, and 000092 applied that verdict as the EXCLUDE-ONLY
base curation shipped in v1.21.1 (57 -> 54 rules). The remaining wave -- deeper curation, config-tuning
of the kept rules, and fix-suggestion quality -- still follows real interactive captures: the unblock
stays behavioral (dogfood normal edits of the canonical checkout, then re-run the classifier), gated on
real usage, not machinery.

## 6. Standing items (Mike-gated)

- **Launch -- done.** The r/PowerShell and r/ClaudeCode launch posts are live (2026-07-05); the in-repo
  launch draft (docs/launch/reddit-powershell.md) merged via plugin PR #77 (000112). No longer pending,
  no longer horizon.
- **Upstream posting -- filed; only an optional follow-up remains.** Posted / filed: the Windows
  launcher guard is filed as anthropics/claude-code#73961 (OPEN); the Claude Code config-panel renderer
  bug surveyed under 000109 (its manifest-side mitigation -- the description cap + configuration.md --
  shipped in v1.23.1) is filed as anthropics/claude-code#74289 (OPEN); and our refreshed comment on
  anthropics/claude-plugins-official#1359 is posted (2026-07-05, the issue itself stays OPEN). Posted
  (2026-07-06): the registrar-field-drop report was filed as a rewrite of anthropics/claude-code#66987
  (OPEN), re-confirmed on Claude Code 2.1.201; the corrected LSP-registration record -- and the
  post-ready, still-unposted follow-up comment -- both live internally in
  docs/upstream/claude-code-lsp-registration.md. The PSES rename-capability fix (issue #2297) was
  submitted as PR #2299 and is now CLOSED unmerged (2026-06-11, verified live) -- settled, no longer a
  pending post; the on-disk notes that still call it "not submitted" / "open"
  (docs/upstream/pses-2297-pr.md, sitting-closeout.md) are superseded.
- **The daemon-initializing integration flake -- STILL KNOWN-OPEN; surveyed 000156 leg 4, and now
  INSTRUMENTED but not explained (000159 leg 1a, RELEASED in v1.27.2).** The flake itself has not
  recurred and no root cause is known; what changed is that the next occurrence should arrive with
  the evidence attached. `tests/PowerShellLsp.Integration.Tests.ps1` "(A) a request while PSES is still INITIALIZING
  surfaces the TRANSIENT incomplete, never silence" failed on windows-pwsh in CI run **30177250246**
  at 2026-07-25T22:24:23Z (line 1576, `$out | Should -Not -BeNullOrEmpty` -> "Expected a value, but
  got $null or empty"), then passed GREEN on rerun with zero code change; the other three platforms
  were green and the diff was one markdown file. Dispatches 000050 and 000051 were both written to
  kill this exact race and only narrowed it.
  **The test's wait is already a bounded wait, not a fixed sleep:** `Wait-DaemonRequestReady`
  (000051) blocks until a real `diagnostics` round-trip completes, then `Invoke-PluginHook` runs with
  `CapMs` 25000 and `timeoutMs` 18000.
  **The survey falsified the banked explanation.** The code comments attribute the residual flake to
  the 000030 relaunch+retry path accumulating past `CapMs` and the harness returning `''`. But the
  recorded It duration was **3.3167 s** -- nothing was killed at a 25 s cap, so that mechanism cannot
  be what happened here. Whatever produced the empty output did so roughly 7x faster than the
  standing theory allows.
  **What the CI artifact does and does not show.** The daemon-logs artifact was retrieved intact (not
  expired). It shows the shared-root warm daemon logging `analyzer pre-warmed in 4611ms` at
  22:24:24.56Z, against a 1147-1980 ms range across the 32 daemons started in that leg -- a ~3.8x
  outlier, so machine contention in that window is OBSERVED, not inferred. It does NOT show the
  failing daemon: sub-case A runs against its own temp data root, which `AfterAll` deletes and CI
  never uploads, so the one log that would explain the failure does not survive the run.
  **Recommended fix shape, in order.** (1) Close the instrumentation gap FIRST -- copy each per-test
  isolated data root's `logs/` into the uploaded artifact before `AfterAll` removes it. This project's
  own hardest lesson is that three dispatches of confident reasoning about timing produced nothing
  while one instrumentation dispatch produced the fix immediately, and the survey above is a live
  repeat of that: the standing explanation was wrong and nobody could see it. (2) Make
  `Invoke-PluginHook` distinguish "process exited with empty stdout" from "killed at CapMs", because
  today both render as the same assertion message. (3) Only then choose between a bounded retry and a
  widened window, on evidence. **No `Start-Sleep`** -- that lowers the failure probability and hides
  the race rather than closing it.
  **Steps (1) and (2) are BUILT and RELEASED in v1.27.2 (000159 leg 1a); step (3) is untouched and
  remains the named next move.** The recorder is wired into all 12 hooks that collapse distinct
  failures into one empty string -- the set derived by AST rather than hand-listed, with a vacuity
  floor asserting it is non-empty -- and the two spawners left out, `Invoke-CaptureC` and
  `Invoke-CaptureU`, are named and each PROVEN to discriminate already, so the exclusion is measured
  rather than declared. Runner fidelity was proven with the env var CI sets: the rescued logs land at
  `logs/isolated/<tag>/` inside the `daemon-logs` glob, where before this change they lived under the
  OS temp dir, outside the uploaded tree, and were discarded at teardown.
  **Its real proof is still pending BY CONSTRUCTION, and that is the honest status.** Everything is
  proven mechanically, but the flake has not recurred since 000156 leg 4 falsified the standing
  explanation, so nothing has yet exercised the instrumentation in anger. The next observed failure
  is the payoff: it should arrive with the failing sub-case's own data-root logs under
  `daemon-logs-<leg>/logs/isolated/<tag>/` and a `plugin-hook-outcomes.log` line saying whether the
  hook was KILLED at `CapMs` or EXITED with empty stdout -- and only then is there evidence to choose
  between the bounded retry and the widened window, which is exactly why step (3) stays unbuilt.
  **If a failure arrives and the isolated logs are still absent, the rescue is wired to the wrong
  root, and that is the first thing to check.** Note also that the rescue covers the daemon-bearing
  isolated roots only: the 000049 poisoned-cache block and the 000025 absent-root block are excluded
  because both were MEASURED to start no daemon and never to call ensure-pses, so there is nothing to
  rescue -- if either later grows a daemon, the rescue must be extended. All of it is now on main
  and released. No dispatch open for step (3); it is evidence-gated, not scheduled.
  **RECURRED 2026-08-07, THE INSTRUMENTATION FIRED, AND IT FALSIFIES BOTH STANDING THEORIES
  (dispatch 000206 leg 3).** This is the payoff the paragraph above said was pending by
  construction, and it arrived on the v1.29.1 release commit. **It is the SAME test, not a new
  one:** CI run **31213030480** (workflow `powershell-lsp CI`, event `push`, head **6663dad**),
  attempt 1, job **92980058008** on `windows-powershell` failed
  "(A) a request while PSES is still INITIALIZING surfaces the TRANSIENT incomplete, never silence"
  at `tests/PowerShellLsp.Integration.Tests.ps1:1691` on `$out | Should -Not -BeNullOrEmpty` ->
  "Expected a value, but got $null or empty" -- byte-identical assertion, message and It name to the
  2026-07-25 sighting recorded above at line 1576; the line moved because the file grew, and
  `git show` at the earlier tree returns the same five lines. So this is sighting **two**, not a
  first sighting of a distinct test. The other three legs were green, attempt-1 totals were
  **1686 passed, 1 failed, 3 skipped**, and the commit under test carried a CHANGELOG-plus-version
  diff ONLY (`git diff --stat 2617345 6663dad`: `.claude-plugin/marketplace.json`,
  `.claude-plugin/plugin.json`, `CHANGELOG.md`; 3 files, 116 insertions, 2 deletions), so no source
  change can be implicated. The `--failed` rerun (attempt 2, job **93014471826**, started
  2026-08-07T22:29:47Z while the three green legs kept their original 19:47Z start times) passed
  with zero code change. **New fact: the leg MOVED.** The first sighting was `windows-pwsh`
  (PowerShell 7); this one is `windows-powershell` (Windows PowerShell 5.1). Same OS, different
  host, same race -- so the mechanism is not host-version specific.
  **What the recovered evidence says, and it is a THIRD outcome class neither theory named.** Both
  rescued artifacts survived: `logs/isolated/000028-A/` is present in the `daemon-logs` artifact
  (the directory the 000156 survey could not obtain), and so is `logs/plugin-hook-outcomes.log`.
  The recorder line at the failure reads, verbatim:
  `hook outcome: stdout-read-timeout -- exited, but the 1500ms stdout drain did not complete
  [elapsedMs=3235 capMs=25000 exit=0 script=lsp-client.ps1]` (2026-08-07T19:56:55.71Z, one second
  before the assertion error). That is **not** `killed-at-cap` and **not** `exited-empty-stdout`:
  the hook process EXITED CLEANLY (`exit=0`) in **3235 ms** against a **25000 ms** cap, so the
  banked 000030 relaunch-accumulation theory is now falsified by direct measurement as well as by
  the 000156 duration argument, and the empty-stdout theory is falsified by the recorder
  discriminating it and not reporting it. The third class -- the harness's own **1500 ms stdout
  drain window** not completing -- is the one that fired, and `tests/Integration.Common.ps1:307-311`
  names all three as the failures the empty string used to collapse.
  **The PRODUCT did the right thing; the failure is harness-side.** `logs/isolated/000028-A/logs/
  lsp-client.log` shows the client requesting diagnostics at 19:56:53.92Z, choosing whole-file, and
  emitting `0 diagnostic(s) [status=incomplete]` at 19:56:54.10Z -- the TRANSIENT incomplete the
  test asserts, produced correctly and on time. What did not happen is the harness reading it back
  within its drain window.
  **Step (3) is now decidable, and it is NOT the retry-versus-widen choice the fix shape
  anticipated.** The recorded next move assumed the answer would select between a bounded retry and
  a widened `CapMs`; the evidence selects neither, because `CapMs` was never approached. The
  candidate is the 1500 ms stdout drain in `Invoke-PluginHook`. **Deliberately NOT built here:**
  dispatch 000206 `scope_out` forbids any retry or timing change to this test or the PostToolUse
  hook, and the instrumentation-first doctrine (000159) says a mechanism gets fixed once, on
  evidence, in a dispatch chartered to fix it. This entry is the evidence; the fix is Mike's to
  charter.
  **SUPERSEDED 2026-08-07 by the recurrence recorded immediately above, which is the observed
  failure this paragraph was waiting for. Retained, not deleted, because its caution still stands
  and is now demonstrated: two non-firings were indeed weak evidence.** THE INSTRUMENTATION HAD
  THEN RUN TWICE WITHOUT THE FLAKE FIRING -- an OBSERVATION, not a
  resolution (000161 leg 2). Two four-leg CI runs on `49ce894` carried the new recorder --
  **30465192375** attempt 1 and attempt 2 -- and `windows-pwsh` was COMPLETED success on BOTH. So the
  flake did not reproduce under instrumentation, and nothing was learned about its cause. Two
  non-firings are weak evidence: this flake was already intermittent enough that 000156 leg 4 could
  not reproduce it either, so a quiet pair of runs is consistent with the flake still being there.
  **Do not read this as fixed, and do not close this item on it.** The payoff remains the next
  observed failure, which is still pending by construction.
- **SARIF emitted under Windows PowerShell 5.1 is never schema-validated -- CLOSED AND RELEASED
  (surveyed 000157 leg 4; built by 000159 leg 1b; LIVE ON CI in v1.27.2).** The gap below is
  the survey's own record of the problem; the fix it recommended is built, merged, released, and
  measured green on the `windows-powershell` leg of the release-gating push-CI run **30465192375**.
  Three tests validate emitted SARIF against the vendored
  2.1.0 JSON Schema, and all three are guarded by `-Skip:($PSVersionTable.PSVersion.Major -lt 6)`
  because they call `Test-Json -Schema`, which is measured ABSENT on 5.1.26100.8875 and present on
  pwsh 7. They were named from the run's own uploaded artifact rather than inferred.
  **The skip is legitimate, not lazy** -- the test physically cannot run on that host, so skipping is
  the honest outcome. **The gap it leaves is real, and it is the wrong host to be missing:** 5.1's
  `ConvertTo-Json` is the serializer most likely to deviate (different escaping, different empty and
  single-element array handling), so the one host whose output is most at risk is the one host never
  checked against the schema. It is narrow rather than gaping -- 178 of 181 SARIF-scan cases still run
  on the 5.1 leg, covering the shape structurally. **Cheapest fix shape, recorded and not
  implemented:** have the 5.1 leg write its emitted SARIF to a file and validate that artifact in a
  pwsh step -- the JSON is already produced, only the validator needs a modern host.
  **That is exactly what shipped, and it is RELEASED in v1.27.2 (000159 leg 1b).** Windows
  PowerShell 5.1 ran the SARIF suite (40 passed, 0 failed, 2 correctly SKIPPED -- the in-suite
  `Test-Json` cases, which stay skipped for the measured reason above) and emitted its SARIF to
  `POWERSHELL_LSP_SARIF_ARTIFACT_DIR`; pwsh 7.6.3 then validated those artifacts against the same
  vendored 2.1.0 schema and exited 0. **That is the first time 5.1's own serializer output has been
  schema-checked anywhere.** The `-RequireHost 5` flag is load-bearing rather than decorative: a leg
  that silently emitted nothing would otherwise validate zero files and report success, so green has
  to mean "5.1's own SARIF was checked". RED-proven four ways, each exit 1 -- empty directory,
  missing directory, artifacts present but none from host 5, and a non-conformant payload rejected
  naming `/runs` as the offending pointer. **CLOSED:** all of it is on main, released in v1.27.2, and
  green on the `windows-powershell` leg of the release-gating run. No further dispatch needed.
- **The `macos-pwsh` / ServeShim EPIPE flake -- FOUR SIGHTINGS, mechanism CONFIRMED, and FIXED in
  dispatch 000180 (2026-08-02). Still deliberately NOT folded into the windows-pwsh
  daemon-initializing flake above.** The fix, the confirmed mechanism, and the measurements that
  settled it are at the END of this item. What comes first is the investigation record that produced
  them, retained rather than rewritten: a fix is only defensible alongside the evidence that ruled it,
  and the interim statuses below are marked superseded rather than deleted so the reasoning that once
  said "do not fix this yet" stays legible. Originally recorded as:
  **A NEW integration flake species -- `macos-pwsh` / ServeShim, SIGHTED TWICE on 2026-07-29, distinct
  from the windows-pwsh daemon-initializing flake above and deliberately NOT folded into it.**
  `tests/PowerShellLsp.ServeShim.Tests.ps1` around **line 307** failed on the **`macos-pwsh`** leg of
  CI run **30465192375** (the push run on merge commit `49ce894`), attempt 1: the assertion
  `ShimExitedAfterCrash` returned **false at 13ms**, against the expectation that "killing PSES
  mid-session makes the shim EXIT promptly". **One clean rerun of the failed leg** turned the run
  green on attempt 2 with zero code change, which is what makes it a flake sighting rather than a
  break. The daemon-log artifact is preserved by Mike Andersen at
  **`Downloads/ci-30465192375-macos`**.
  **Why it is a separate item.** Different platform (`macos-pwsh`, not `windows-pwsh`), different
  test file (`ServeShim`, not `Integration`), different failure shape (a shim that did NOT exit when
  it should have, at 13ms -- the opposite polarity from an empty-stdout hook that produced nothing),
  and no shared mechanism has been established between them. Folding two unexplained intermittents
  into one item would manufacture a pattern the evidence does not support, and would make either
  one's eventual root cause look like it explained the other.
  **Status as of 2026-07-29 -- SUPERSEDED by the fix record at the end of this item: SIGHTED TWICE,
  now INSTRUMENTED (dispatch 000163 leg 2) and still UNFIXED.** The second
  sighting landed the same day on CI run **30472816851**, `macos-pwsh` leg, over merge commit
  **d05ec7a** -- and that commit is a **DOCS-ONLY merge**, which is what makes the flake reading
  near-certain rather than merely likely: a tree that moves no code cannot regress a test. The
  daemon-log artifact is preserved at **`Downloads/ci-30472816851-macos`**. It failed on the same
  assertion, and `the killed PSES stays reaped` PASSED alongside it -- so PSES did die; the shim
  outlived the 15s wait.
  **The 000161 prediction was half right, and the wrong half is the useful one.** That record predicted
  "a second sighting would arrive with no more evidence, because nothing here is instrumented". In fact
  the shim ALREADY logs its exit path with ISO timestamps (`Write-ShimLog`) and CI ALREADY uploads that
  log (`psls-test-data/logs/pses-serve-shim.log` is inside the `daemon-logs` artifact glob). Three
  things were genuinely missing, and 000163 leg 2 closed all three, tests-only: (1) **the exception** --
  `pses-serve-shim.ps1`'s outer `try` has a `finally` and NO `catch`, so the error record goes to the
  shim's stderr, which the harness drained into a `ReadToEndAsync` Task that **nothing in the repo ever
  read**; (2) **per-run isolation** -- every shim in a leg appends to ONE shared log, interleaved by
  pid; (3) **a discriminator** -- the `finally` line is identical on all exit paths.
  **What the preserved second-sighting log already shows.** The crash shim (pid 18428) logged NEITHER
  break marker -- not the PSES-death branch, not the client-EOF branch -- yet DID log the `finally`
  line, so the pump left via an **unhandled exception**. It also logged **ZERO** `intercepted
  server->client` lines where the same run's healthy shim-mode shim (pid 18197) logged **two**; in the
  shim, `Write-ServeFrame` to the child's stdin runs BEFORE its `Write-ShimLog`, which places the throw
  on a client->PSES write onto the killed child's broken stdin, reached ahead of the pump's own EOF
  branch. An unhandled exception there also SKIPS the closing
  `[System.Environment]::Exit($shimExit)` -- the line whose own comment explains it exists precisely to
  avoid a graceful runspace shutdown waiting on the background client-reader thread blocked in a
  synchronous read on an unclosed client stdin. That is a coherent mechanism for a shim that never
  exits, and it is recorded as a HYPOTHESIS, not a conclusion.
  **Do not theorise from the reported durations.** The first sighting's "13ms" and the second's 42ms are
  `It`-block times; all of the scenario's work happens in the `BeforeAll`, so those numbers measure the
  assertion, not the wait. 000156 leg 4 already burned a dispatch on exactly this class of inference.
  **NOT FIXED, deliberately -- SUPERSEDED 2026-08-02 by dispatch 000180.** 000163 leg 2's charter (OQ1)
  permitted instrumentation only; a
  control-flow change to the shim is a future fix dispatch, to be taken AFTER a third sighting arrives
  with the recorded exception text naming the throwing line. The instrumentation now writes a per-run
  `serveshim-lifecycle-crash-*.json` into the uploaded logs tree carrying the classified exit path, the
  shim's own log slice, its stderr, and the phase timings, and the failing assertion's message now names
  the classified exit path instead of reporting a bare `$false`.
  **FIXED in dispatch 000180, 2026-08-02. The hypothesis above was right, and it is now a conclusion.**
  Four sightings by the time it was taken: the two `macos-pwsh` CI legs recorded above, plus PR #121's
  `macos-pwsh` leg failing twice and then passing on a bare re-run of the identical commit -- a measured
  1-in-3 rate, with an empty commit off main and main-plus-one-test-file both green, ruling out trunk
  and the new file. Alongside them, one 87-minute local wedge: a verify claiming the full suite hung at
  a 4200-second timeout and hung again under f2 at 1200 seconds, the timeout value making no difference,
  and a `taskkill /T` on the verify tree terminating three processes while leaving twelve-plus `pwsh`
  alive, one still accruing CPU.
  **The mechanism, no longer a hypothesis.** 000180 reproduced it deterministically instead of waiting
  for a fifth sighting. Driving the real `pses-serve-shim.ps1` against a stub PSES, killing the stub
  while continuing to feed client frames, and running that against a scratch copy with the guard removed
  produced the exception text the record above said a third sighting would need -- naming the throwing
  line directly: `scripts/lib/serve-shim-common.ps1:142`, `$Stream.Flush()`, *"Exception calling Flush
  with 0 argument(s): The pipe is being closed."* It is a broken-pipe throw on the client->PSES write,
  reached ahead of the pump's own EOF branch, exactly as predicted from the preserved pid-18428 log.
  **One correction to the reasoning, measured rather than argued.** The write that throws is the one to
  the PSES CHILD'S STDIN, and only that one. A write to the CLIENT's stdout cannot throw: .NET's console
  stream treats `ERROR_BROKEN_PIPE` / `EPIPE` as success, and a probe pushed 160KB into a closed pipe
  without a single exception. Any future reading of this species that assumes the client-stdout write is
  a throwing path is wrong; the shim guards it anyway, as defence in depth rather than as the cure.
  **The fix.** `Write-ServeFrameGuarded` wraps every frame write on the shim's pump path, absorbing
  `IOException` and `ObjectDisposedException` -- and ONLY those two, so a real defect is never laundered
  into a quiet shutdown -- and rejoining the pump's existing peer-loss shutdown rather than inventing a
  new one. The outer `try` gained the `catch` it never had, so
  `[System.Environment]::Exit($shimExit)` is now reachable on every path out, including the throwing
  one; an unexpected exception exits 2 and names itself in the log instead of wedging.
  **Held to the adversarial standard.** With the guard bypassed in a scratch copy, 4 of the 10 new
  assertions go RED; with it in place, 10 of 10 pass, the shim exiting in **121-146ms** with exit code
  **1** (10 injections, windows-pwsh). Worth recording precisely because it is a limit on the evidence:
  on a Windows host the
  "does it exit" and "exit code" assertions did NOT discriminate -- the unhandled throw still terminated
  `pwsh` with a coincidental exit 1 in ~193-201ms, and the wedge did not reproduce there. What discriminates
  is the assertion that the guard LOGGED its firing and the one that stderr carries no unhandled-exception
  record. A future reader tempted to simplify those two away should know they are the only reason a
  bypassed guard fails on Windows at all.
  **The injection is deterministic, and was not always.** As first written it killed the stub and then
  fed frames, hoping to catch the pump mid-write; it lost that race about one run in five, exiting 1 via
  the HasExited branch with the guard never firing. Since the exit code cannot tell those two apart, it
  was the guard-logged-its-firing assertion that caught it rather than a green vacuous pass -- the second
  time that assertion has earned its place. The stub now stops DRAINING while staying ALIVE, so a flood
  parks the pump inside the write before the kill. Both figures above are re-measured against that
  injection: 10 consecutive green injections, and the bypassed control reproducing 6-passed/4-RED on
  three consecutive runs with the same four assertions each time.
  **A 5.1 host trap the new test walked straight into, worth knowing for any future one.** As first
  written the injection was INERT on `windows-powershell` -- it failed 2 of 10 there while passing
  under `pwsh`, which reads like a shim defect on one platform and is nothing of the kind. On .NET
  Framework, reading `$proc.StandardInput` builds a `StreamWriter` over `[Console]::InputEncoding` and
  sets `AutoFlush`, and that setter flushes the encoding PREAMBLE immediately -- so against a UTF-8
  console three bytes (`EF BB BF`) land ahead of the first frame. The shim's parser wants
  `Content-Length` at offset 0, so it stalls: 486KB written from a 5.1 host arrived as **0 bytes**, and
  prepending those same three bytes from a `pwsh` host reproduces it exactly. Only this Context is
  exposed, because it pins the shim to `pwsh` while the e2e Describes spawn the shim under the TEST
  host, and a 5.1-hosted shim absorbs the BOM. The cure is on the TEST side and the wire is unchanged:
  a BOM-less `InputEncoding` for the launch, restored afterwards. With it, 55/55 on both hosts and the
  bypassed control goes 6-passed/4-RED on 5.1 too -- so the adversarial evidence now covers the host
  where it previously could not have, having never fired at all.
- **A THIRD flake species -- `killed-at-cap` in the flake-instrumentation suite itself. WATCH ENTRY
  ONLY: recorded, not theorised about, not fixed.** One sighting, 2026-07-29: an elapsed-vs-cap
  assertion in `tests/PowerShellLsp.HookInstrumentation.Tests.ps1` failed and **cleared on rerun**.
  That is the entire record, and it is deliberately the entire record. Dispatch 000163's charter placed
  this under `scope_out` -- "any fix, workaround, or theory for the killed-at-cap species" -- and its
  `do_not` rail forbade touching the test, so no mechanism is proposed here and none should be inferred
  from its neighbours above. The irony is noted without being built on: the suite that instruments other
  flakes produced one of its own. **Second-sighting trigger:** if it recurs, apply the same discipline
  the ServeShim item above just received -- instrument the elapsed/cap measurement so a second sighting
  carries the two numbers and the outcome reason, before any theory is entertained.
- **`ManifestConsistency` under-declared-export: RULED, REMOVED, and RELEASED in v1.27.3.** The cut
  prepared by 000162 leg 1 was merged as PR #111 and released as v1.27.3 (tag over b1a673f, producing
  run 30504336296) -- so this item is CLOSED, not held. This is no longer a correctness gap, an open
  question, or a deviation being carried: the rung was **deleted from the source** on a ruling by Mike
  Andersen, 2026-07-29. What
  follows is retained as the MEASUREMENT RECORD that produced the ruling, not as an open item -- a
  removal is only defensible with the measurement that ruled it, so the history stays. The ruling
  itself, the before/after re-measurement, and the one parked follow-up are at the END of this item.
  Of the **910** `ManifestConsistency` hits on 000159's live oracle after the leg 2 fix,
  **909 are confirmed false positives and 0 are true positives**, each triaged by hand against the
  module's real surface via `Import-Module`. Denominator, re-measured that session: 155 `.psd1`
  manifests enumerated across 6 `PSModulePath` roots, of which 26 carry a resolvable `RootModule`
  `.psm1` -- the real denominator -- and hits fell 1088 -> 910 across the fix.
  **The cause is structural and precisely known.** A manifest's `FunctionsToExport` is the FINAL
  export gate, so a function the module defines but the manifest omits is simply NOT exported -- yet
  the under-declared-export check reports it anyway. Pester is the clean case: 419 functions defined,
  the manifest lists 26, PowerShell exports exactly 26, and all 393 hits name functions it does not
  export. **The fix shape is already indicated by the data:** when a manifest is present with a
  non-wildcard `FunctionsToExport`, the manifest rather than the module's implicit export-all is the
  exported set, so the check should compare against the intersection or degrade to silence.
  **Two things are worth separating.** The class 000159 leg 2 was chartered to fix -- multi-name
  `Export-ModuleMember` lists -- IS fixed, measures clean (0 of the 910 attributable to it), and is
  now **CLOSED AND RELEASED in v1.27.2**. This second class was ruled by Mike Andersen to be out of
  that train's scope and recorded as an accepted deviation, not a shortfall.
  **RE-MEASURED 2026-07-29 by dispatch 000161 leg 3, and the class is now measured at 100% FP, worse
  than the 99.89% recorded above.** Live oracle on that machine-day: **169** `.psd1` manifests across
  6 `PSModulePath` roots plus the repo, of which **36** carry a resolvable `RootModule` `.psm1` -- the
  real denominator. (000159 measured 155 / 26. As with the 281-vs-325 oracle, these are two
  machine-days, not a number and its correction, so the rows above stand as written.) Total hits
  **914** = **911** under-declared + 2 orphan + 1 alias-orphan. Of the 911 under-declared hits,
  **ZERO name a function PowerShell actually exports** -- so the under-declared class measures
  **911/911 = 100% false positive**, with no true positive anywhere in the oracle.
  **000161 leg 3 is a RECORDED NO-BUILD, and the reason is that no narrower subclass measures clean
  either.** The one candidate subclass -- fire only where the `.psm1` carries an EXPLICIT
  `Export-ModuleMember`, so the author demonstrably meant to export the name -- returns **26** hits
  and measures **96.15% FP (25 of 26)**. Twenty-five are PowerShellGet (both installed versions):
  `PSModule.psm1` defines 132/121 functions and explicitly exports 38, while the manifest lists
  26/25, and the difference is the **OneGet provider-interface surface** (`Find-Package`,
  `Install-Package`, `Get-DynamicOptions`, `Initialize-Provider`, ...) which is deliberately exported
  to PackageManagement and deliberately kept out of the manifest's public surface. Verified rather
  than asserted: `Get-Module -ListAvailable PowerShellGet` reports 26 exported functions and does NOT
  contain `Find-Package`. The 26th hit is the plugin's OWN `tests/corpus/samples/module/typo-export`
  fixture, true by construction. So the sound-subclass fork pre-authorized in the 000161 charter
  found nothing to ship, and the no-build fork applied: **no code, no CHANGELOG entry, no PR.**
  **The charter's stated defect shape was FALSIFIED before any of this, and that matters for the next
  charter.** 000161's anchor described this class as "the same single-element-only defect the 000159
  leg 2 fix closed for `Export-ModuleMember`" -- i.e. a multi-name `FunctionsToExport` list being read
  as a single element. It is not. A four-form probe (multi-name `@()`, multi-name bare list, single
  scalar, single-element `@()`) against BOTH read paths -- `Get-ModuleManifestExports` and
  `Get-ManifestExportedFunctionNames` -- returned the correct count on all four forms with zero
  defects. The manifest read path was never broken; the defect is entirely in what
  `Test-ManifestConsistency` DOES with a correctly-read list.
  **The remaining fix was a BEHAVIOUR REMOVAL, which is why 000161 did not take it unilaterally.**
  Since a determinate non-wildcard `FunctionsToExport` IS the export gate, the under-declared rung is
  wrong-by-design in every shape that reaches it -- the same verdict the 000058 survey reached for
  `unused-export`. Degrading it to silence takes 911 hits to 0, but it deletes a shipped check and
  flips the repo's own `typo-export` fixture expectation, and no open question in the 000161 charter
  authorised removing shipped behaviour, so it went to the human as a ruling.
  **RULED SILENCE by Mike Andersen, 2026-07-29, and EXECUTED by dispatch 000162 leg 1.** The rung is
  removed from `Test-ManifestConsistency` in source -- not suppressed by `orgPolicy`, not narrowed,
  not down-severitied. The numbering keeps a deliberate gap (rungs 1 and 3 retain the identities this
  document and the CHANGELOG already cite). Re-measured against the preserved 000161 harness on the
  SAME machine-day, same 169/36 denominator: under-declared **911 -> 0**, with orphan and alias-orphan
  **unchanged at 2 and 1** -- asserted row-for-row (rung + name + manifest), not by count alone, with
  the pre-change count asserted nonzero first as the vacuity floor. The repo's `typo-export` corpus
  expectation was deliberately INVERTED to pin that the rung stays silent, and RED-proven: against the
  pre-change code the flipped expectation fails, and it is the ONLY one of the 119 corpus samples that
  moves. The shipped `ManifestConsistency` rule rationale also lost its "or an exported one is
  unlisted" clause, re-derived through `scripts/regen-rule-rationales.ps1` -- a removal has to reach
  the user-facing text or the plugin documents a check it does not run.
  **PARKED, NOT QUEUED -- the real authoring-error class.** The genuine defect this rung gestured at
  is narrower than what it measured: *a new public function the author forgot to add to
  `FunctionsToExport`*. Nothing in the static surface distinguishes that from a deliberate private
  function, which is exactly why the rung measured 100% FP, so re-entry would need a genuinely sound
  **opt-in** signal (an explicit author declaration, not an inference) rather than a narrowing of the
  old predicate. **This is a future design question, not a queued item, and no dispatch is open on it.**
  **The measurement gap is CLOSED and the ruling has since been MADE, EXECUTED and RELEASED** (SILENCE,
  Mike Andersen 2026-07-29; executed by 000162 leg 1; shipped in v1.27.3) -- the sentence that used to
  stand here said "what remains open is a RULING", which was accurate when 000161 leg 3 wrote it and is
  no longer, so it is trued rather than left to contradict the ruling recorded above. **000159's
  `next_suggested` named id 000160 for this PATCH and 000160 was minted as the close-out train
  instead, so the class went uncharted until 000161 leg 3 measured it under the measure-first bar.
  That leg answered every empirical question -- the shape, the rate, the denominator, the candidate
  subclass and why it fails -- and stopped at the one question it could not answer for itself. Still
  carried forward from the 000159 `next_suggested` block, still NOT fixed, and now a RECORDED NO-BUILD
  with a measured reason: the INERT dot-source degrade in `Get-ModuleDefinedFunctionNames` (it matches
  `CommandElements[0] -eq '.'`, but PowerShell carries the dot as the `CommandAst`
  `InvocationOperator`, so the degrade never fires; a characterization test pins the current
  behaviour). **Dispatch 000162 leg 2 attempted it, measured the blast radius, and took its
  pre-authorized no-build fork (OQ3) rather than expand the train.** The fix itself is small and works
  -- reuse the already-correct `Get-DotSourceClass`, which reads `InvocationOperator` properly for
  rung 3 -- but making the degrade fire converts the plugin's OWN `scripts/lib/dogfood-reader.psm1`
  (which dot-sources `lsp-common.ps1` at line 34) from a determinate, ground-truth-verified 12-export
  cross-reference into `dot-sourced definitions; shape is indeterminate`, and that breaks the 000159
  test `models dogfood-reader's REAL 12-export surface` (measured: *Expected 12, but got 0*) -- a test
  OUTSIDE the characterization test's pinned scope, which is exactly the OQ3 trigger. Both ways
  forward are unchartered design decisions needing their own measurement: (a) accept the blanket
  degrade and give up 000159's ground-truth coverage on a real module, or (b) fire the degrade only
  where there is no explicit `Export-ModuleMember`, which re-opens a rung-1 false-positive path (a
  dot-sourced definition making a manifest name look orphaned) -- trading one FP class for another
  without measuring it. **Whoever charters this should scope that choice explicitly**, because the
  naive "just make the degrade fire" reading silently picks (a). 000161's own
  oracle harness and the 914-row hit CSV are preserved OUTSIDE both repos at
  `C:/tmp/000161/` (`oracle-measure.ps1`, `premise-probe.ps1`, `baseline-hits.csv`), which makes the
  before/after re-measurement of any ruling cheap. They are deliberately not committed: they are
  machine-state measurement scaffolding, not product.
- **Pester 6 -- deferred, deliberately.** Pester 6.0.0 went GA on the PowerShell Gallery 2026-07-07.
  The test bootstrap is pinned to the 5.x major (000120 leg 1) rather than upgraded, because there is
  no forcing function and a breaking new major should be absorbed by a decision, not by runner-image
  luck; the guard test makes silently unbounding the pin go RED. Pester 6's parallel-execution model
  has not been evaluated against the daemon-backed integration tests, which is the first thing an
  upgrade slice would have to establish. Revisit when a forcing function appears. No dispatch open.
- **gitsign tag-verify caveat (unchanged).** Release tags are gitsign-signed (keyless, Rekor-logged); a
  plain `git verify-tag` cannot read the x509 / gitsign signature and reports the Fulcio certificate as
  expired -- normal for keyless, where the short-lived cert is not the proof, the Rekor entry is.
  `gitsign verify` or `gh attestation verify` is the documented path (README, docs/RELEASING.md). No fix
  dispatch open; optional.
- **Dispatch 000149 -- deliberately terminal at complete; a documented one-off.** 000149's work is
  merged and correct: its ledger-append and `dispatch validate` claims both re-verified MATCH against
  merged origin/main, and its entire delta is hub docs (DEV_NOTES.md) plus coordination files -- zero
  plugin-code change. Its single `dispatch verify` MISMATCH was on the plugin Pester smoke_test claim,
  whose recorded command used a repo-relative `-File tests/run-tests.ps1` that resolves only from the
  plugin repo; verify re-ran it from the HUB ROOT, because 000149 is hub-internal, and it exited 64
  "not recognized". The suite itself PASSED when 000149 ran it (1343 passed / 0 failed / 0 skipped,
  1012s), so the MISMATCH is a recorded-command re-runnability defect on a suite that a docs-only
  change cannot affect -- not a defect in the work. Chasing `verified` would mean re-running a
  17-minute suite to satisfy a claim that cannot fail because of that work, or spending a fix-forward
  cycle whose only product is making the ceremony re-runnable; both are motion, not correctness. This
  is a deliberate ONE-OFF, not a new pattern: the every-dispatch-terminal-at-verified norm stands, and
  this entry names the single exception and its cause so a future reader sees a documented exception
  rather than a loophole. Hub Rule 8 held throughout -- no state was self-promoted, and the F2 human
  gate is exactly what left 000149 at complete. The fix, if ever wanted, is to rewrite that command to
  carry `-WorkingDirectory` or an absolute `-File` path -- recorded for the record, not scheduled. No
  fix-forward dispatch open. The two lessons are banked as rule candidates by 000150 (DEV_NOTES
  rule-candidate ledger, 2026-07-23: cwd-independent check commands; claim scope matches blast
  radius).
- **Branch `dispatch-000095-refresh-reddit-launch` -- CLOSED, no restore, no fix-forward.** The
  branch was deleted from the forge at 2026-07-24T19:41:54Z under the manderse21 account, one day
  before dispatch 000152 (whose acceptance 1 asked that it still be PRESENT) was accepted -- so that
  acceptance was already false on arrival, and 000152 recorded a named block rather than restoring
  the ref or leaving a permanently-RED assertion. The disposition is CLOSED, and the work it carried
  is not lost on either count. **Superseded:** dispatch 000112 rewrote the same launch draft to
  v1.23.0 ground truth and merged it as plugin PR #77 (2026-07-04, merge commit b8af118), and the
  merged `docs/launch/reddit-powershell.md` on main says so in its own header -- "supersedes the
  abandoned v1.19.0-era 000095 draft"; dispatch 000095 is itself terminal at `abandoned`. So every
  correction the deleted branch held already lives on main in a later and better form. **Retrievable
  anyway:** its tip `7a6395676d93aeadb778eb03769784806d1668a5` -- exactly the SHA 000149 recorded --
  is still served by the forge at `refs/pull/67/head`, which GitHub retains for the life of PR #67
  independently of the branch ref, and PR #67 remains CLOSED with `mergedAt` and `mergeCommit` both
  null (genuinely never merged, not quietly squashed in). Each of those four facts was re-verified
  against the tree and the forge on 2026-07-25 rather than carried over from the dispatch that
  reported them. No restore was performed and none is scheduled: the deletion was made under Mike
  Andersen's own credential, so it is at least as likely deliberate as accidental, and re-creating
  the ref would make a presence check pass while burying the finding. No fix-forward dispatch is
  open. Recorded so a future reader finds the reasoning instead of an unexplained gap.
- **External technical review (2026-07-30) -- adjudicated; a two-dispatch response launched.** An
  external technical review of the plugin was analyzed by Strategic-Claude and adjudicated by Mike
  Andersen. This entry is the ratified register: what the response adopts, and what it declines and
  why. The adopted direction is `review-adopted-2026-07-30` -- a two-dispatch launch, a
  survey-and-record train (000165) followed by a build train whose inbox is drafted FROM that
  survey's outbox, covering a README restructure to the three-capability story, a profile meta-knob
  layered over the existing userConfig surface, first-class command surfacing for the doctor and the
  scan path, the CONTRACT posture question, and the Arc A re-scope recorded in Section 4. The build
  is deliberately not chartered until the survey lands -- the 000135 -> 000142 precedent, that a
  survey worth running can change the build it was meant to launch.
  **Declined, each with its ratified one-line reason:**
  `review-declined: plugin-rename` -- a rename breaks marketplace identity, the launch posts, the
  installed base, and the contract.
  `review-declined: file-watcher` -- fails cost/safety and the headless-first posture.
  `review-declined: semver-loosening` -- trades a trust asset for speculative flexibility.
  `review-declined: new-custom-rules (freeze standing)` -- new custom rules stay frozen pending the
  efficacy ledger; that freeze predates this review.
  `review-declined: default-on-broader-ruleset` -- loses to the missing-finding-beats-wrong-finding
  principle for an agent consumer.
  `review-declined: doc-volume-reduction (restructure instead)` -- documentation is restructured into
  a hierarchy, not reduced in volume.
  **The decline premises were re-derived from disk, not carried from the review** (000165 leg 1):
  no file-watcher implementation exists anywhere in the tree (the sole `Register-ObjectEvent` hit is
  a data string in the command-module index catalog, not a watcher); the `ruleset` knob still ships
  `pses-default`, which `CONTRACT.md` records as a deliberate non-flip; and N1.1 in Section 4 already
  records that the idiom slices are guidance overrides on rules that ALREADY fire, explicitly not new
  rules. No decline premise was falsified by the survey, so none was reworded.
- **Doctor slice 2 (dispatch 000208) shipped F11 and the version report -- and DECLINED F10 / C1,
  which stays Mike-gated.** What shipped: the `ps_host` child-host resolution check (survey class
  **F11**), fail-capable because `Resolve-PsHost` substitutes rather than errors, so a misconfigured
  host is silently replaced; and a report-only plugin-version header calling the already-shipped
  `Get-PluginVersion`. The default doctor surface went from **10 checks to 11** (derived from
  `scripts/doctor.ps1`, not carried from the charter: the 000203 survey's "9 default checks" was
  true when that survey ran and was superseded by slice 1's `orgPolicy` check in 000206). The
  version line is a header, not a row, because the status vocabulary `CONTRACT.md` freezes has no
  token for a plain fact.
  **`review-declined: doctor-security-classifier (000036 boundary UPHELD -- declined-final)`** --
  survey class **F10** / candidate **C1**, surfacing the security classifier's verdicts in the
  doctor, was NOT built and is recorded here so it is not silently re-litigated. It contradicts the
  boundary **dispatch 000036** recorded and `scripts/doctor.ps1` still states in its own header
  (verified-from-disk, `scripts/doctor.ps1` lines 19-25): *this doctor does NOT detect or diagnose
  security-control blocks (WDAC / App Control / AppLocker / ExecutionPolicy / Smart App Control /
  Constrained Language Mode) ... for an indeterminate failure the doctor emits only a single GENERIC
  pointer ... Zero control-specific probing here.* The 000203 survey flags the contradiction itself.
  000208 recorded the decline as pending an attended ruling by Mike Andersen, and **that ruling has
  now been made: DECLINED-FINAL (dispatch 000220).** It is no longer "the boundary stands until
  someone rules"; the boundary is upheld on stated reasoning, and a reader should treat reopening it
  as arguing against a decision rather than filling a vacancy.

  **The reasoning, and it turns on WHERE a control gets named rather than on whether naming one is
  ever right.** The enterprise-robust argument for surfacing verdicts is real, and this project
  already conceded it -- in the other place. `scripts/lib/security-classifier.ps1` (000038) exists
  precisely to name the blocking control, and it does so on the SessionStart **bootstrap-failure
  banner**: verified-from-disk, its header states it will *attribute a component-bring-up failure to
  the security control most likely blocking it, on POSITIVE EVIDENCE ONLY*, and that naming a
  control without that evidence is *the same sin as silent failure*. That surface has the two
  properties the doctor lacks. (1) **A live failure is in hand** -- the banner fires only when
  bootstrap actually failed, so there is something to attribute. The doctor is a static, pasteable,
  report-only surface that most often runs with nothing blocked at all, where a named control would
  be a guess dressed as a finding. (2) **The verdict is graded and the grading is load-bearing** --
  `New-SecurityClassification` carries a `Confidence` of `confirmed`, `likely`, `possible` or
  `none` (verified-from-disk), and the banner's lead-in switches on it. A doctor row has no such
  channel: a doctor check's status is a `[ValidateSet('pass', 'fail', 'unknown')]` parameter
  (verified-from-disk, `scripts/doctor.ps1` line 88), three tokens with nowhere to put a grade, so a
  `possible`-confidence verdict would land in a table that can only render it as though it were
  determined -- and `unknown`, the only token that could absorb it, is precisely the token the
  doctor uses to mean *I could not check*, which is a different statement. On top of both, a
  doctor report is written to be pasted into a bug report or a support thread, which makes an
  enumerated read of a machine's security posture a disclosure the user did not ask to make. The
  division is therefore deliberate and stated: **the banner does live, evidence-gated, named
  diagnosis; the doctor does generic health and points.** Both halves ship. Neither is a gap.

## 7. Operating posture (unchanged)

Fast on a gated path; the gate is fast, not removed. Human gates: accept, merge, F2 verified flip, tag,
and the product / positioning / sequencing calls. Within an accepted dispatch's scope, CC decides
implementation, design, and ripeness. Ground truth (live `dispatch list`, the log, file inspection)
wins over any doc, including this one -- the log is authoritative.

## Dispatch 000274 -- publishing the roadmap control map: RULED by Mike 2026-08-22 -- PUBLISH it as a derived view, asset-as-record; Pages DECLINED for the first cut

Mike ruled that the roadmap control map is published with every release, so a reader can see where
development is headed without reading the program documents. Two design decisions govern how, and
both are the reason the publication does not create a new drift surface.

### The map is a DERIVED VIEW, not a second plan of record

[ROADMAP.md](../ROADMAP.md) and this ledger remain canonical. `docs/control-map.html` is a visual
view of them, and every piece of prose that introduces it -- the README row, the
[RELEASING.md](RELEASING.md) currency gate, this entry -- says so explicitly rather than leaving the
relationship to be inferred. A published visual that reads as authoritative competes with the plan
of record and then drifts from it silently, which is the same failure class as a stale published
number; the difference is that a number can be machine-derived and a picture cannot. So the defence
here is the stated relationship plus a human gate, not a check pretending to adjudicate content.

### Asset-as-record over GitHub Pages

The map is published two ways, and neither is a website. It is **committed at a stable path**
(`docs/control-map.html` -- the date and rev live inside the document header, never in the filename,
so a revision cannot break the README link), and it is **attached to every release as an asset**.

Attaching it to the release is what makes it version-bound: a reader gets the map as of the version
they downloaded, and a published asset is immutable, on the same release surface that already
carries the gitsign-signed tag, the SBOM, and the provenance-attested source archive. Stated
precisely, because the distinction matters: the map inherits that surface's immutability and version
binding; it is **not** itself a subject of the SLSA provenance attestation -- the attestation
subject list was left unchanged by this cut, and extending it was not chartered.

**GitHub Pages was considered and DECLINED for the first cut.** A Pages site is mutable and
version-unbound -- one deploy silently rewrites what every past release appears to have said -- and
it adds a deploy-drift surface and a public-website posture change, sitting outside the attestation
chain entirely. Everything the release pipeline is built to guarantee (immutable, verifiable,
version-bound artifacts) a Pages deploy gives up. The decline is **reversible**: publishing to Pages
as well may be chartered separately later, and nothing in this landing forecloses it.

### The refresh obligation, and where it is enforced

The map is regenerated by hand and supplied by the maintainer; there is no generation tooling, and
building some was explicitly out of scope. That makes staleness the live risk, so it is caught at
the one moment it matters: [RELEASING.md](RELEASING.md) step 5 confirms, before the tag is cut, that
the map is present at the target commit and that its internal date stamp is not older than the
version's CHANGELOG entry date. A stale map is a STOP. That gate is **not** the roadmap-currency
gate 000230 retired -- it asks nothing of ROADMAP.md and compares two dates, one of which the
runbook itself writes two steps earlier.

## Dispatch 000276 -- the four rulings of 2026-08-22: RULED by Mike 2026-08-22 (SC chat), RECORDED LATE on 2026-09-05

**This entry is dated to the day the rulings were made, 2026-08-22, and was written on 2026-09-05
by dispatch 000276.** The gap is stated rather than hidden: the dispatch chartered to record them
(000272) was parked until the next release tag existed, and was abandoned at the acceptance of
000276, which absorbed it. Nothing here is new; the rulings were in force from the day they were
made.

### 1. The verbatim `RULE_CANDIDATES.md` PK export is DECLINED-FINAL, replaced by a bounded synopsis

Dispatch 000264's chartered filtered export is declined for good, not deferred. The reason is
arithmetic and was measured before it was ruled: the export came to 280,947 bytes against 270,554
bytes of live headroom, so it did not fit and could not be made to fit without moving a budget the
same ruling holds still. **The replacement is a bounded synopsis** -- counts, family titles and
promotion-eligible families, with the full evidence one paste away -- regenerated only on a
promotion event rather than on every observation. A synopsis that moved on every sighting would
just be a smaller copy of the ledger.

That synopsis now exists, authored by this dispatch at
`projects/powershell-lsp/RULE_CANDIDATES_SYNOPSIS.md` in the strategic-dispatch hub: 7,730 bytes
against its 10,240-byte cap.

### 2. The 000270 remainder is closed

Abandoned dispatch 000270 had five legs. Legs B, C and D were found already satisfied -- by
dispatch 000269 and by hub commit `0330991f9` (the SC session-ledger record of the v1.32.0 arc).
**`0330991f9` is a commit in the strategic-dispatch hub, not in this repository**, which is worth
stating in a plugin-repo ledger so a reader does not go looking for it here. Legs A and E were
closed by dispatch 000276: leg A as a read-only gist byte-anchor (PASS -- see the 2026-09-05 entry
below) and leg E as a re-check of `ROADMAP.md` against 000270's own acceptance criteria.

### 3. The v1.33.0 cut was security-motivated, and its version was DERIVED rather than chosen

The accumulated `[Unreleased]` band was cut as a release because it carried a shipped-but-unreleased
security fix -- the T5.1 pipe-DACL restriction, which the cut promoted into its own `### Security`
section with its exposure scope, affected range, and the still-unmeasured POSIX arm named. The
version was **derived from the band's own SemVer self-classifications**, not selected: MINOR
entries present forced `1.32.0 -> 1.33.0`. This is the same discipline the v1.32.0 cut used, and
the point of it is that nobody gets to pick a number that flatters the release.

### 4. The F2 currency-gate source-repo arm is adopted in principle, and handed off

Extending the F2 currency gate to cover the source-repo merge arm -- so a hub dispatch cannot be
promoted to `verified` on the strength of a hub merge alone when its deliverable lives in a sibling
repository -- is **adopted in principle**. It is explicitly **not** this project's to build: it is
hub machinery, and it was handed to the strategic-dispatch program stream to charter. Recorded here
because the ruling was made in this project's sitting, not because the work belongs to it.

---

## Dispatch 000276 -- the overnight omnibus of 2026-09-05: rulings Q1-Q6 RATIFIED by acceptance, and the T3 post-release miss recorded as fact

**Ruled by Mike on 2026-09-05 via SC chat and ratified by his acceptance of the 000276 inbox.**
This entry records what was ruled and what the night found. **It rules nothing itself**, and in one
place below it deliberately declines to.

### The six rulings, as ratified

**Q1 -- a two-dispatch night.** This omnibus absorbs the parked dispatch 000272 and executes its
legs by reference from the abandoned inbox (the 000270 precedent). Dispatch 000275 runs after it,
last, because its measurement is the stall-prone leg and needs the quiet host an overnight run
provides.

**Q2 -- plugin PR #196 merges before launch.** The evidence bundle carries the T3 FAIL verbatim;
holding the PR served the reading, and the reading had landed. Confirmed at pre-flight: #196 is
**MERGED**, 2026-09-05T05:28:08Z, merge commit `6a6a371`.

**Q3 -- the seven gap-fill PK companions are declared and funded by a recency-floor raise** at a
ledger-distilled arc boundary, with the size budget held still. **This is the one ruling the night
could not execute, and the reason is recorded under "What the night found" below.**

**Q4 -- the T5.1 / T6.2 POSIX arms are measured from CI, record-only.** A permissive value is a
finding for the ledger and for Mike, never a fix applied in the same pass.

**Q5 -- the daemon-initializing flake gets instrumentation steps 1 and 2 only.** Step 3, the retry
or any behaviour change, is **not** authorized.

**Q6 -- the charter was minted against a 2026-08-23 snapshot** and says so, which is why it opens
with a pre-flight leg whose whole job is to tell the runner what the charter could not know.

### The T3 post-release miss, recorded as a FACT and NOT ruled on

**v1.33.0 shipped missing an adopted target.** T3 is one of the six v1 SLOs ratified by Mike on
2026-08-21 (G2), and `SLO-BASELINES.md` section 9 states what adoption changes: these stop being
descriptions of a build and become a regression bar, so a release that misses one is missing an
adopted target and that is a release-blocking fact to be surfaced.

Measured at C = `6ab2d24` by dispatch 000273 and confirmed on a **compliant quiet host** -- the
quiescence gate passed at 22% median CPU, 41% p95, zero agent or node processes, 352-376 total
processes over a 7.5-minute span -- **1 of 15 sessions returned two NOT-checked edits** against a
target of at most one. **The cold-start clause HOLDS**: the extra edit is still a cold-start edit,
so what is missed is the count clause alone. The freeze's first table read 6 of 15, but it ran at
84-97% CPU against 619-677 processes; the quiet re-run is the compliant measurement and 1 of 15 is
the figure of record.

Section 9 ratified T3 with **spread zero**, and says so explicitly: "a T3 or T4 miss is therefore a
**behavioural regression** and should be read as one, not as measurement noise." That is what makes
this a decision rather than a footnote.

**The ruling is NOT made here.** Whether this is documented-and-accepted or calls for a corrective
release is Mike's, and it waits on dispatch 000275's survey, which characterizes the marginal miss
and assesses the four release-window runtime changes as candidate contributors. 000275 is
findings-only by charter and changes no target. The row is listed under PENDING-MIKE in
`docs/roadmap-ii/PROGRAM.md`.

### What the night found, recorded because it changes what was ruled

**Q3 could not be executed, and the obstacle is a gate rather than a budget.** The floor raise it
depends on requires two things at once: every dispatch id below the new floor distilled in an SC
session-ledger entry a planner reads, and the new floor sitting at an arc boundary. Checked id by
id against the ledger, **three ids inside the range an existing arc entry declares it covers
(000233-000243) are undistilled: 000238, 000239 and 000242.** The entry's title asserts a coverage
its body does not deliver. So `N = 000244` -- the charter's own named fallback -- fails the
distillation half, while `N = 000238` would pass it but cuts mid-arc, which the PK config's own
stated principle forbids. **No admissible floor exists above the live value.**

Measured with the collector's own arithmetic, the budget picture is independently worse: **at the
live floor the bundle is already 4,650,165 bytes against a 4,500,000-byte budget -- over by
150,165 with nothing added, so the next PK refresh halts today.** The seven companions plus the
synopsis fit only at floor 000244 or higher, which is exactly the floor the distillation gate
refuses. Gate and budget point in opposite directions and **the gate wins**: a floor that strands
undistilled work breaks references, which is the failure the gate exists to prevent.

Per the charter's own pre-authorization the declarations and the raise are recorded as a diff for
Mike rather than committed, the budget was not raised, and no declared companion was dropped. The
distillation of 000238, 000239 and 000242 is the work that would unblock it, and it is not
improvised here.

**The gist byte-anchor: PASS.** The published white-paper gist and `docs/whitepaper.md` at the tag
are byte-identical -- both 42,665 bytes, SHA-256
`5959b1f8301c9c993d45d768511a6340d233b02791e8827dfe0a6d73b3d4752a`, and the gist's own file blob
SHA (`7e7e7b4d`) equals git's blob SHA for the repository file, which is an independent agreement
rather than a second reading of the same number. No gist write was made or needed.

**Two record corrections found by re-deriving rather than reading.** `VERIFICATION_SURFACE.md` had
recorded the test surface growing "19 to 23" files across v1.31.1 to v1.31.2; re-counted with the
same command it is **18 to 22** (its four named new files are correct, so the totals were a
transcription slip). And `docs/upstream/claude-code-lsp-registration.md` still described
`anthropics/claude-code#73961` as **"(open)"**; it is CLOSED / COMPLETED and has been since
2026-08-13T16:08:43Z -- the same day `#66987` closed, which is why the pass that caught the one
missed the other.

### The findings-only outputs this dispatch produced

Each of these assembles evidence and recommends; none of them decides, and none is a charter.

- **`docs/roadmap-ii/DOCTOR-SURFACE-DOCKET.md`** -- a census of what the doctor, status and scan
  surfaces prove today against the North Star's "the user can prove it is working" bar in headless,
  SSH, CI and container environments, with the gaps, at most three costed candidate slices, and one
  recommendation. **No build was executed.**
- **`projects/powershell-lsp/RULE_CANDIDATES_SYNOPSIS.md`** (hub) -- the bounded synopsis ruling 1
  of 2026-08-22 called for.
- **The rule-candidate sweep** found **zero** unbanked observations hub-wide: the mechanical ledger
  writer is current through 000274. Second-observation status was re-derived for four families as
  findings only, with nothing promoted.

### External actions: none, as always

No gist write, no catalog or awesome-list submission, no upstream comment or reply, no post of any
kind. The upstream re-derivation this dispatch performed is entirely read-only `gh` queries. The
external-publishing gate is Mike's and this dispatch did not approach it.

---

## Dispatch 000278 -- enterprise program night 2: rulings R5-R7 of 2026-09-05 RATIFIED by acceptance, the review audited, and v1.33.1 DERIVED

**Third entry recorded on 2026-09-05**, after the two that commit `a060c69` appended (the
2026-08-22 rulings recorded late, and the 000276 omnibus). Appended, never edited into an existing
entry.

### The rulings, recorded as they are attributable on disk

R5-R7 were ruled in the Strategic-Claude chat and **ratified by Mike accepting the 000278 inbox**,
which makes that inbox the artifact of record. Two of the three are attributed to a specific clause
there; one is not, and this entry says so rather than reconstructing it.

| # | What the accepted inbox attributes to it | Where |
| --- | --- | --- |
| **R5** | **Cut v1.33.1 as far as an unattended night can take a release.** "LEG R -- v1.33.1 release-prep 1a (ruling R5) ... derive the version from `[Unreleased]`; lockstep-bump via `bump-version.ps1`; cut CHANGELOG `[1.33.1]` dated today with `[Unreleased]` left empty ... ONE plugin PR HELD." The freeze (1b) and the tag are explicitly `scope_out`: "they need a quiet host and Mike's trigger; a separate night" | 000278 inbox `scope_in` leg R; `scope_out` |
| **R6** | **NOT ATTRIBUTABLE FROM DISK.** The inbox's title and `rule_citations` name "rulings R5-R7 of 2026-09-05 (SC chat, ratified by accepting this inbox)", but no clause in the document attributes anything to R6 specifically. It is recorded here as unattributable rather than inferred; the probe that would settle it is the Strategic-Claude chat transcript of 2026-09-05, which is not on disk | 000278 inbox title, `rule_citations` |
| **R7** | **The night's hard rails do not move.** "Merging, verifying, f2, tagging, triggering any workflow (dry run included), force-pushing or deleting any branch -- NIGHT_PROTOCOL section 3 unchanged tonight (ruling R7)", and `rule_citations`: "NIGHT_PROTOCOL sections 2, 3, 5, 12 -- unchanged tonight (R7)" | 000278 inbox `scope_out`; `rule_citations` |

**A related gap, recorded because it was found and not because it was looked for.** Dispatch
000277's charter anchored this ledger for "one dated 2026-09-05 entry ... recording R1-R4 verbatim".
**No such entry exists.** The newest ledger commit before this one is `a060c69`, which is 000276's,
and the string `000277` appears nowhere in this file. R1-R4 are therefore recorded in the 000277
inbox and nowhere in this ledger. This entry does **not** write that entry -- doing so would mean
reconstructing four rulings whose text is not on disk -- it records the absence so the gap is
visible.

### The enterprise review was audited, and the docket is now the full instrument

`docs/roadmap-ii/ENTERPRISE-PROGRAM-DOCKET.md` replaces the skeleton 000277 landed under its
missing-input pre-authorization. The skeleton's provable-health slice is carried forward verbatim --
S1, S2 and S3 keep their mechanism, effort and freeze-exposure text and are renumbered P0-1a, P0-1c
and P3 in the phase-ordered queue.

**The file exists and its identity is recorded**: `C:\Users\mande\Downloads\enterprise-review-2026-09-05.md`,
**29,569 bytes**, SHA-256 `380CFA18059EEF598BA867268BD0DEAEF438CFD380F836A44F33E8C2ACB372AD`,
1,078 lines.

**The snapshot it read is `v1.33.0`, derived rather than assumed.** The review's item 8 quotes four
line counts. `doctor.ps1` (2,035), `pses-daemon.ps1` (1,731) and `lsp-client.ps1` (858) match this
tree exactly. `lsp-common.ps1` at **4,595 lines / 131 functions** matches `v1.33.0^{}` exactly and
not this branch (4,736 / 135) -- and it is the one file of the four that 000277's leg C touched. So
the review cannot see the POSIX containment fix, and its own P0 row "strict data-root permissions"
is **already shipped**. Everything that fix changed is STALE by construction.

**Every claim is scored** -- all seventeen numbered items, the "five things", and every row of the
review's phase table -- as TRUE, STALE, REFUTED, ALREADY-SHIPPED or UNVERIFIABLE, each with a file
and line, a live `gh` read, or the exact probe that would settle it. Six claims rest on third-party
web documentation; external network reads were outside this night's rails, so those are scored
UNVERIFIABLE with the probe named rather than assumed true.

**Two headline blockers are argued for RE-OPENING, not presented as new.** This is the discipline
000277 established on derivation and it is inherited rather than re-learned:

- **T6.1 (capture on by default) -- ruling R-A.** The acceptance's stated reason is that the
  exposure runs "to a local user who already has the source files it quotes". The review names
  readers for whom that clause is false -- EDR, backups, forensic collection, eDiscovery, DLP, disk
  imaging, endpoint management. That is a claim T6.1 **mis-scoped the reader set**, which is a new
  argument reaching the one clause the acceptance rests on. 000277's leg C already closed the local
  half.
- **T4.2 (`orgPolicy` fail-open) -- ruling R-B.** The review's argument is **not the one T4.2
  answered**. T4.2 ruled on the degrade *direction* for a layer whose payload is `ExcludeRules`; the
  review says the subtract-only payload is itself the defect, because it cannot express an
  organization *requirement* at all. The cost driver is T4.1's own words: a signed policy needs "a
  trust anchor the org policy mechanism does not have".

**The review's own phasing was not adopted wholesale.** Its phase table has **fourteen rows**, and
the `P0 -- Trust closure` row bundles three work items, so the docket dispositions **sixteen** in
all: **nine are placed somewhere other than where the review put them, and seven are kept.** The
nine, each with its reason recorded: "strict data-root permissions" is already shipped; "SLO release
gates" and "Claude Code compatibility" drop from P0 to P1; OTel drops from P1 to P2; the architecture
split drops to P3; the assurance-pack and deployment-matrix rows split, because half of each is
human-only or is Pillar H; and the governance and external-audit rows leave the build queue for the
human-only list.

**The release-governance slice is re-shaped by the T3 survey, and this is the load-bearing change.**
`T3-REGRESSION-SURVEY.md` (000275) found no monotone timing threshold explains the miss -- a
v1.32.0 session slower on every axis did not miss, and the C session that missed was not the
slowest at C on any axis -- and states its own limit: N=15 per side cannot separate a low-rate
defect from noise. **A hard gate on T3 today would gate on a statistic the sample cannot support.**
So the survey's order governs: quiet-host re-runs first (its P1, a human leg), then re-read. Its P3
(re-ratify the spread basis at N=45) is a **change to a ratified target** and is routed to ruling
R-F rather than taken. Its P4 (do nothing, record a single-sample event) is folded in as a
legitimate terminal -- the dispatch charter named three proposals, the survey carries four, and
dropping the null option would have biased the slice toward building a gate.

**The most useful finding is about cost.** The project already has a ruled, non-frozen,
**fleet-deployable** `POWERSHELL_LSP_*` environment surface (dispatch 000244: admin plumbing "an
organization has to deploy *to a fleet* -- via GPO, Intune, or machine-scope environment"). A
capture mode, an enterprise mode and a policy path can land there at **zero `CONTRACT.md` freeze
exposure**, which is the difference between a MINOR and a PATCH. Every slice in the docket states
its freeze answer on that basis.

**Four rulings are appended to `PROGRAM.md`'s PENDING-MIKE table** (R-A, R-B, R-F, R-G); R-C and
R-D already have rows from 000277 and are not duplicated. **One row leaves**: "The enterprise review
audit itself (R-E)" is answered by execution and moves to the rows-that-left table.

### v1.33.1 was DERIVED from the CHANGELOG, not chosen

The `[Unreleased]` band carried **exactly one subheading -- `### Security`** -- the POSIX
containment fix from 000277, whose own text states that "no `userConfig` key, no status token, and
no line of `CONTRACT.md` changed". Against this CHANGELOG's own Versioning section that is *"bug
fixes and internal hardening with no user-visible contract change"*: **PATCH**. A MINOR would
require a new backward-compatible capability in the band and there is none. **`1.33.0 -> 1.33.1`.**

The same discipline the v1.32.0 and v1.33.0 cuts used: the entries present force the number.

- **The cut is additive only** -- 11 lines inserted, 0 removed -- so the carried band is
  line-identical across it, and `[Unreleased]` is left present and empty.
- **The lockstep bump used `scripts/bump-version.ps1 1.33.1 -Apply`**, not hand edits. It rewrote
  exactly the two version surfaces it owns and re-read both from disk to assert lockstep. The
  version-bearing set was re-derived by `git grep` rather than trusted to the tool: every other hit
  is historical prose about past releases and must not move; there is no `VERSION` file; and no test
  pins the tree's own version (every version literal under `tests/` is synthetic fixture data).

**What release-prep 1a deliberately did NOT do, and why.** No dry run, no producing run, no tag, no
control-map edit. **1b -- the freeze measurement at the merged commit C -- and the tag both wait on
a quiet host and Mike's trigger**, per this dispatch's own `scope_out`; the T3 clause is the reason,
and the T3 survey above is why that clause is still open.

**One human gate is recorded rather than approached.** `docs/RELEASING.md` step 5 requires the
control map's internal date stamp to be no older than the version's CHANGELOG entry date.
`docs/control-map.html` is stamped **2026-08-22 rev2**; this cut is dated **2026-09-05**. The map is
therefore **stale for this release**, and the runbook is explicit that "a stale map is a STOP, not a
note. Nothing regenerates the map -- the maintainer supplies a refreshed rev by hand." It was not
edited. It needs a refreshed rev before the tag, and the runbook wants that refresh to ride the
release-prep PR rather than cost a second merge cycle.

### External actions: none

No tag, no workflow trigger of any kind including a dry run, no merge, no promotion to `verified`,
no publish, post or submission, no force-push, no branch deleted, and nothing touched that belongs
to another session. The only network reads were `gh` queries against public repositories.

---

## Dispatch 000279 -- enterprise program night 3: rulings R8-R14 of 2026-09-05 RATIFIED by acceptance, the two P0 slices BUILT, and R1-R7 recorded late

**Fourth entry recorded on 2026-09-05**, after the 2026-08-22 rulings recorded late, the 000276
omnibus, and 000278. Appended, never edited into an existing entry.

**Why this entry quotes rather than cites.** Dispatch 000278 found that a ruling living only in the
Strategic-Claude chat is **unattributable from disk** -- its R6 could not be recorded at all, and
000277's chartered entry for R1-R4 was never written. The 000279 charter fixed the input rather than
the symptom: it carries R8-R14 **verbatim in its own body**, so the accepted inbox is a complete
artifact of record and this entry can quote it word for word.

### R8-R14, verbatim, from the accepted 000279 inbox body

Quoted exactly as the charter body states them. The blockquote marker and the line wrapping are
the container; **no word, emphasis or punctuation of the rulings themselves is added or changed**,
so a reader can diff this block against the inbox and a check can match it as a string.

> R8 (R-A) = (a). Re-open T6.1 narrowly: a metadata-only capture mode on the POWERSHELL_LSP_*
> admin env surface, T6.1 amended to record the management-plane reader the review named (EDR,
> backup, eDiscovery, DLP). NOT built tonight -- chartered for night 4, because the capture's
> consumer set deserves its own derivation.
>
> R9 (R-B) = (b). Charter Policy v2's include-side payload only; the signing half waits until a
> trust root exists, per THREAT-MODEL T4.1's own words. P1, not tonight.
>
> R10 (R-C) = (a). Verify the gallery-fallback bytes against the same pin and fail closed.
> BUILT TONIGHT as legs E and F.
>
> R11 (R-D) = (a). Build P0-1a+b+c as one dispatch. BUILT TONIGHT as legs A through D.
>
> R12 (R-F) = (c). Decide T3's spread basis after the quiet-host re-runs. Not tonight; the
> re-runs are a human leg on a quiet host.
>
> R13 (R-G) = (a). Claude Code Current-1 is Advisory, not Required. Recorded; P1-3 builds later.
>
> R14. No re-rule on the custom-rule seam, the native-LSP gate, or PS 5.1 first-class. The
> docket argued all three both ways and recommended none; the seam's re-open condition is real user
> demand and a review is not demand.

Each of R8-R13 is now written into
[`ENTERPRISE-PROGRAM-DOCKET.md`](roadmap-ii/ENTERPRISE-PROGRAM-DOCKET.md) section 7's "Mike's
answer" column, and no other line of that docket moved. R14 has no row there -- it answers section
5, which argues the three standing rulings both ways -- so it is recorded here and in
[`PROGRAM.md`](roadmap-ii/PROGRAM.md)'s rows-that-left table, and **section 5 is left exactly as
written**, because it is the argument the ruling was made against.

### R1-R7, RECORDED LATE, and only as far as disk attributes them

000277's chartered ledger entry for R1-R4 was never written and 000278 recorded that absence. This
entry closes the record as far as it honestly can. **The verbatim text of R1-R7 is still not on
disk** -- neither the 000277 nor the 000278 inbox quotes any of them -- so what follows is what each
accepted inbox *attributes* to a ruling, with the clause it comes from. Where nothing is attributed,
that is said, and nothing is reconstructed.

| # | What the accepted inbox attributes to it | Where |
| --- | --- | --- |
| **R1** | **A machine-merge amendment to `NIGHT_PROTOCOL.md`, deferred to an attended change.** "the machine-merge amendment (R1) is Mike's attended change tomorrow and is not touched here"; `scope_out`: "R1's amendment is Mike's attended change tomorrow, not this run's" | 000277 inbox anchor for `docs/NIGHT_PROTOCOL.md`; `scope_out`; `rule_citations` |
| **R2** | **NOT ATTRIBUTABLE FROM DISK.** The 000277 title names "rulings R1-R4"; no clause attributes anything to R2. (The unrelated `R2-nn` identifiers in `PROGRAM.md` are Roadmap II wave rows, not this ruling.) The probe that would settle it is the Strategic-Claude chat transcript of 2026-09-05, which is not on disk | 000277 inbox title, `rule_citations` |
| **R3** | **NOT ATTRIBUTABLE FROM DISK**, same as R2 and by the same probe | 000277 inbox title, `rule_citations` |
| **R4** | **Build the POSIX containment fix.** "LEG C -- POSIX containment fix (ruling R4; runs SECOND so its CI cycle overlaps the reading legs) ... Make each creation owner-only (0700 directories, 0600 files where the plugin writes files) at creation time ... with Windows behaviour byte-identical". Delivered by 000277 leg C | 000277 inbox `scope_in` leg C |
| **R5** | **Cut v1.33.1 as far as an unattended night can take a release.** Recorded in full in the 000278 entry above; not restated here | 000278 inbox `scope_in` leg R |
| **R6** | **NOT ATTRIBUTABLE FROM DISK.** Recorded as such by the 000278 entry above and unchanged by anything found tonight | 000278 inbox title, `rule_citations` |
| **R7** | **The night's hard rails do not move.** Recorded in full in the 000278 entry above | 000278 inbox `scope_out`; `rule_citations` |

**The mechanism that fixed this is the charter, not the ledger.** R8-R14 are quotable because the
000279 charter carried them in its body. Nothing in this repository can recover R2, R3 or R6, and no
later entry should try.

### P0-1 -- doctor `-Json`, the status envelope, and `-RequireProven` (R11)

Built as `DOCTOR-SURFACE-DOCKET.md` slices S1 and S2, folded into the program docket unchanged.

**`-Json` is a third rendering over the existing `Invoke-Doctor` seam**, beside
`Format-DoctorReport` and `Format-DoctorSummary` -- not a new code path. The precedent was already
shipped: `-Summary` is exactly this shape of change, and its own comment states the invariant that
makes it safe. **The human renderings are byte-identical without the switch, measured rather than
asserted**: `Format-DoctorReport` and `Format-DoctorSummary` over a fixed three-check fixture hash
identically at the merge base `e6aed1b` and at this tip (SHA-256
`908D6B9A7402EAE7DC3D6ED9DC236C938BA8F250C94449255BFA812DA4167DF6`, 1,225 bytes), and two live
full runs -- the default fix-list and `-Summary` -- are byte-identical with identical exit codes.

**The envelope** carries `schemaVersion` (1), the derived `status`, the resolved plugin / pwsh /
PSES / PSSA versions, the provenance floor, the summary counts, and the per-check array in the
`New-DoctorResult` shape. `versions.pwsh` is a host fact; `versions.pses` and `versions.pssa` are
the **pins this build requires**, not a re-probe of what is installed -- checks 3 and 4 already
report that, and duplicating their verdict would be a second implementation of it.

**The derivation rule**, stated once in `Get-DoctorEnvelopeStatus` and mirrored in
`commands/doctor.md`. Each value has a condition; when several apply the most severe wins, in the
order UNHEALTHY > DEGRADED > UNPROVEN > HEALTHY:

| Value | Applies when |
| --- | --- |
| `UNHEALTHY` | at least one check FAILED |
| `DEGRADED` | at least one check is UNKNOWN **and** at least one PASSED |
| `UNPROVEN` | **nothing** PASSED -- the run established nothing, so it proves nothing |
| `HEALTHY` | every check PASSED |

A run with both a fail and an unknown reads UNHEALTHY. A render of **zero** checks reads UNPROVEN,
never HEALTHY.

**This `status` is a DOCTOR ENVELOPE FIELD, NOT THE FROZEN DIAGNOSTICS STATUS TOKEN SET, and the
distinction is the reason the freeze exposure is zero.** `CONTRACT.md` Tier 1 freezes exactly two
enumerable surfaces: the twenty `userConfig` knob names, and the **diagnostics** status token set --
the words a *finding* wears, drift-guarded to `Get-DiagnosticsStatusBanner` / `Resolve-AnalysisStatus`.
None of `HEALTHY` / `DEGRADED` / `UNHEALTHY` / `UNPROVEN` is one of those words, nothing in this
slice emits or reads a diagnostics record, and the doctor's own per-check `pass` / `fail` /
`unknown` vocabulary is a **third**, separate enum pinned by `New-DoctorResult`'s `ValidateSet`,
untouched. The three look identical in prose and are not the same surface. `git diff` shows
`CONTRACT.md` unchanged.

**`-RequireProven`** is a second predicate beside the existing failure count: **exit 2** when
nothing failed but at least one check is UNKNOWN. Exit 2 rather than 1 keeps 1 meaning "something
FAILED" for every caller that exists, and matches this repo's own convention for an opt-in gate
tripping (`lsp-scan.ps1 -FailOn` exits 2). A fail dominates an unknown. **The opt-in is
load-bearing, not timidity** -- changing what the *default* exit code means would break every
existing caller and is a breaking change under the 1.x policy.

**Controls.** RED for `-RequireProven`: the prior predicate, the single `$doctorFailures` line the
file shipped, returns 0 where the new test demands 2 -- and agrees with the new one on every set
where the switch is not in play, so the control discriminates rather than merely differing. RED for
the envelope: a status derived from the failure count alone reads HEALTHY on a run that established
nothing. Discrimination control: a forced-UNKNOWN run never renders HEALTHY. Renderer control (the
docket's own): forcing one check to FAIL moves both the JSON status and the exit code, which a
renderer with hardcoded statuses would fail.

### P0-3 -- the gallery-fallback pin gate (R10)

**The gap, derived rather than assumed.** `scripts/ensure-pssa.ps1` resolves PSScriptAnalyzer
through mirror, bundle, pinned-`.nupkg` cache and direct download; every one passed the single
`Test-PinnedFileHash` gate and failed closed. The `Save-Module` fallback did not, and the reason is
mechanical: a live `Save-Module -Name PSScriptAnalyzer -RequiredVersion 1.25.0` leaves **49 files
under `PSScriptAnalyzer/1.25.0/`** -- an extracted module tree plus PowerShellGet's own
`PSGetModuleInfo.xml` -- and **no `.nupkg` anywhere**. `$PssaSha256` is a digest *of the `.nupkg`*,
so it was not computable from what that route produced. Those bytes were installed on the Gallery's
publisher/catalog integrity alone, and the code's own comment named closing it as its own dispatch.

**Option (a) is buildable, and this is the measurement that proved it.**
`Save-Package -Name PSScriptAnalyzer -RequiredVersion 1.25.0 -Source https://www.powershellgallery.com/api/v2 -ProviderName NuGet`
saves `PSScriptAnalyzer.1.25.0.nupkg`, 14,658,674 bytes, SHA-256
`14E634C828EB98EFB9F40B2918BA90F139ED5ECCDF663A2A747736D996995D60` -- **exactly `$PssaSha256`**. So
the fallback can hand the gate the same artifact the pinned layers hand it.

**The fix.** The fallback is now a **layer inside the single gate**, not a route after it: when the
direct download fails all three attempts, the script acquires the `.nupkg` over PackageManagement's
transport, stages it into the same `$nupkg` the one `Test-PinnedFileHash -Path $nupkg` call reads,
and fails closed identically on a mismatch -- same banner, same layer name, same `exit 1`, no
expansion, no marker. The unverified `Save-Module` route and the `Register-PSRepository` bootstrap
that existed only to serve it are removed. **No acquisition of any kind survives after the
fail-closed exit**, which is the stronger form of the property the pre-existing suite protected by
asserting that `Save-Module` sat after it.

**`ensure-pses.ps1` needed no change, and the asymmetry is asserted rather than assumed.** It has
never had a fallback -- its own comment says so -- so it carries one layered acquisition, one
`Test-PinnedFileHash`, one fail-closed throw, and the suite asserts it contains no `Save-Module` and
no `Save-Package` to gate.

**What this costs, deliberately.** A fallback whose bytes cannot be verified no longer installs.
That is what failing closed means, and the session still degrades honestly: the analyzer reports
`unavailable` and editing keeps working.

**RED control, and it is the prior implementation rather than a mutant.**
`tests/fixtures/red-controls/ensure-pssa.pre-000279.ps1` is the pre-change file byte for byte
(18,739 bytes, SHA-256 `CE52E3E049F1951B392D3AB215EDFC8C7AE0E06D8AD55909134A4606628FEBFD`), pinned
by hash in the test and asserted to carry the same `$PssaVersion` and `$PssaSha256` as the shipped
script so the comparison is like for like. Driven by the same harness -- direct download forced to
fail, the fallback fed bytes that are not the pinned artifact -- the shipped script **refuses**
(exit 1, banner naming `gallery-fallback`, no marker, nothing vendored) and the prior implementation
**accepts**: it installs an attacker-supplied module tree wearing the pinned version number and
records `gallery-fallback` in its marker.

**The doctor's artifact-source note inverted with the gate and kept the case it must not lose.** A
marker records the *layer*, never the build that wrote it, so a `gallery-fallback` marker left by an
install predating this gate still describes bytes the pin did not verify. `Test-DoctorArtifactSource`
now says both things; silently dropping the note would have upgraded a legacy install's provenance
by implication.

### External actions: none

No merge, no promotion to `verified`, no `dispatch f2`, no tag, no workflow trigger of any kind
including a dry run, no publish, post or submission, no force-push, no branch deleted, and nothing
touched that belongs to another session. A live PowerShell Gallery fetch was performed **twice** --
once to derive the `Save-Module` payload shape and once to derive the `Save-Package` digest -- both
read-only, both into a scratch directory outside every repository, and both are the derivations this
entry reports rather than assumes.
## Dispatch 000282 -- enterprise program night 4: rulings R15-R19 of 2026-09-06 RATIFIED by acceptance, R8 EXECUTED, and P0-2 / P1-4 / P2-2 BUILT

### The rulings, verbatim

Carried verbatim per **R18**, which this entry both records and complies with, so each ruling is
attributable from disk without the chat that produced it.

**R8 (R-A), ruled by Mike 2026-09-05, EXECUTED tonight.** *"R8 (R-A) = (a). Re-open T6.1 narrowly:
a metadata-only capture mode on the POWERSHELL_LSP_* admin env surface, T6.1 amended to record the
management-plane reader the review named (EDR, backup, eDiscovery, DLP). NOT built tonight --
chartered for night 4, because the capture's consumer set deserves its own derivation."*

**R15 -- pull P1-4 forward.** *"Build the protocol handshake now. It is zero freeze exposure on
both frozen surfaces, the docket prices it at 3-4 hours today and materially more once P1-2 ships a
second consumer, and it is the ordering finding the review did not draw: P1-4 must lead P1-2. Build
it as the smallest additive shape -- version and capabilities on request and response, absent
version means 1, unknown version is answered not refused -- and leave P1-2 for its own night."*

**R16 -- pull P2-2 forward.** *"Write the assurance-pack document. No code, zero freeze, and it
names a set that already exists frozen. It must say what it is not: not a custom-rule seam, not a
new rule, not an org extension. Derive the rule set; do not restate the docket's count."*

**R17 -- 000279's gallery-fallback test question, answered.** *"The structural proof plus
Test-PinnedFileHash's own unit coverage is the stopping point. A CI-only test that fetches the
14.6 MB pinned artifact on every run buys one end-to-end assertion at the price of a network
dependency in the suite that proves the plugin works offline. If a live fetch is ever wanted it is
a scheduled job, not a PR gate, and it is not chartered."*

**R18 -- verbatim rulings are a standing convention.** *"Every charter carries every ruling it
executes or establishes verbatim in its own body, in a section titled for it, so the ruling is
attributable from disk without the chat that produced it. Strategic-Claude adopts this as a
drafting rule from this charter forward; the ledger records it once here."*

**R19 -- P0-2 gets a fleet-visible half.** *"A control the fleet cannot verify is half a control.
The doctor -Json envelope carries captureMode -- resolved mode, raw env value, recognized flag --
as an additive field, so the EDR / backup / eDiscovery / DLP reader P0-2 exists for can confirm the
mode is active on a host without reading the log it is trying not to read. No userConfig key, no
diagnostics token, no human-rendering change."*

R17 is recorded and nothing is built for it.

### What was built

**P0-2 -- the metadata-only capture mode (R8).** `POWERSHELL_LSP_CAPTURE_MODE` on the admin env
surface, read at `Add-DiagnosticCaptureEntries`. `full` is today's entry and is byte-identical
*structurally*: the `[ordered]` literal is untouched and `metadata` is expressed as two `Remove()`
calls on it, so byte-identity is a property of the shape rather than something a test restores.
`metadata` demotes `file` to a basename and drops `snippet` and `message`. `off` returns before the
log path resolves, creating neither file nor directory.

**The read is kept and only the write suppressed, and that is the whole correctness argument.**
`hash` is computed from the snippet, and the docket's case for this shape is that the corpus
derivation reads `ruleId` + `hash`. An implementation that skipped the read to save the write would
hash the empty line and key every metadata row differently from its full-mode twin -- silently,
because the writer swallows everything. Two assertions guard it: full-versus-metadata equality, and
equality against the hash of the real source line, first shown to differ from the hash of an empty
one.

**`message` is dropped, on a measurement rather than an argument.** The docket's metadata field list
does not mention `message` at all. Measured on the pinned PSScriptAnalyzer 1.25.0:
`PSUseDeclaredVarsMoreThanAssignments` emits *"The variable 'customerRecordZZQ9' is assigned but
never used."* and `PSReviewUnusedParameter` emits *"The parameter 'InternalTokenABC7' has been
declared but not used."* Both quote a user-chosen identifier verbatim, so the first arm of the
charter's fork applies.

**An unrecognized value resolves to `full`**, following `Get-CaptureLogRotateBytes`, whose own
comment states the constraint for this whole family: T6.1 is ACCEPTED-WITH-RECORD, so nothing here
may become a gate on the capture channel. `docs/dogfood.md` already documents that same fallback for
`POWERSHELL_LSP_CAPTURE_ROTATE_BYTES`, making it the capture channel's written convention rather
than a new one. `docs/configuration.md`'s refuse-and-report policy governs the two **bootstrap**
artifact-source variables, which have a banner to refuse on; this path is inside a writer that must
not emit, so the typo is surfaced by the doctor envelope instead.

**P1-4 -- the protocol handshake (R15).** `protocolVersion` and `capabilities` on request and
response; absent means 1; an unknown version is answered with the daemon's own version, never
refused. The IPC is confirmed against `CONTRACT.md` to be outside both frozen surfaces.

**P2-2 -- the assurance pack (R16).** `docs/assurance-pack.md`, linked from the `ruleset` knob. The
count was derived from the emitters and **the docket's six is correct**. The eligibility test is
derived rather than asserted: a rule belongs to the pack when its judgment cannot be reached from
the file's own AST -- it needs the host, the machine, a sibling file, or the bytes beneath the parse.

**R19 -- `captureMode` in the doctor envelope.** Resolved mode, raw value, recognized flag.
Additive; `schemaVersion` stays 1. `commands/doctor.md` stated no policy on whether an additive
field bumps the schema, so this dispatch wrote one there -- additive does not bump, removals and
renames do -- and recorded that it established it.

### The freeze answers, one per leg

| Leg | Surface touched | Freeze exposure |
|---|---|---|
| B/C/D (P0-2) | an environment variable, not a knob | **ZERO.** `.claude-plugin/plugin.json`, `CONTRACT.md` and `tests/doc-claims.psd1` are byte-unchanged against the merge base |
| E (captureMode) | a doctor **envelope** field, not a diagnostics status token | **ZERO.** The frozen token set is the words a *finding* wears; the four-value envelope vocabulary is unchanged and no check's logic moved |
| F (P1-4) | the daemon IPC | **ZERO.** Not one of the two enumerable Tier 1 surfaces, asserted rather than assumed |
| G (P2-2) | a document naming a set that already exists | **ZERO.** No rule added, renamed or removed |

### Findings that corrected the charter or the docket

- **The docket named one request-building site for P1-4; there are three.** `lsp-client.ps1`'s
  `diagnostics` and `format` paths and the doctor's check-11 probe. All three announce the
  handshake, and all five daemon response paths were routed through one write seam, because a
  handshake present on one path and absent on another is not a handshake.
- **The set-equality guard is not in `tests/doc-claims.psd1`.** The charter placed it there.
  `doc-claims.psd1` guards `README.md` numbers only -- every row is `Document = 'README.md'`. The
  knob guard is in `tests/PowerShellLsp.Unit.Tests.ps1`, comparing `plugin.json`'s `userConfig` keys
  to `CONTRACT.md`'s `FROZEN-KNOBS` block, and it never reads `docs/configuration.md`. The
  instruction was satisfiable either way; the citation was not right.
- **T6.1 appears in five places in `THREAT-MODEL.md`, not the four the charter named.** All five are
  amended. The acceptance is **narrowed, not withdrawn**: its stated reason is kept verbatim and the
  management-plane reader is recorded beside it.
- **`regen-rule-rationales.ps1:85` says "the 5 plugin-owned finders" over a block of six.** Recorded
  in `docs/assurance-pack.md` and deliberately not fixed -- P2-2 is a document and changes no code.
- **A live vacuous security assertion, found by the leg I census.**
  `tests/PowerShellLsp.Unit.Tests.ps1:2272` anchors on the bare name `Test-PinnedFileHash`, which
  resolves to a header **comment** on line 5 of `ensure-pses.ps1` rather than to the call. The test
  claims to prove the pin gate runs before extraction and **passes with the pin-gate call deleted**,
  verified by mutating the source. Its own stated adversarial control is false. Recorded, not fixed:
  the fix night is chartered against the census.

### The two open questions 000279 asked back

Both are answered by ruling rather than by this dispatch: **R17** settles the gallery-fallback test
question (the structural proof is the stopping point), and **R18** settles whether verbatim rulings
should be standing (they are, from this charter forward). Nothing was built for either.

### External actions: none

No merge, no promotion to `verified`, no `dispatch f2`, no tag, no workflow trigger of any kind
including a dry run, no publish, post or submission, no force-push, no branch deleted, no version
bump, and nothing touched that belongs to another session. `v1.33.1` remains cut on `main` and
untagged with PR 204's MINOR-class work above it, exactly as found. One container image was pulled
from a public registry for the leg K feasibility census, which is a read.

## Dispatch 000288 -- R14 (R-H): NO CI MODEL CREDENTIAL. P1-3 is COMPLETE at registration-only

### The ruling, verbatim

Carried verbatim per **R18**, so it is attributable from disk without the chat that produced it.

**R14 (R-H), ruled by Mike Andersen 2026-09-08.** *"NO CI MODEL CREDENTIAL. Take option (b) --
P1-3 stays at registration-only and docs/SUPPORT-POLICY.md says so explicitly, naming what the
registration half does and does not prove. The reasoning, on the record: this is dispatch 000283's
R17 shape -- a live dependency bought for one end-to-end assertion -- and it is worse on three
axes. A repository secret is reachable by every workflow in a repo that publishes attested
artifacts; a live agent turn is nondeterministic and an advisory leg that flakes teaches people to
ignore advisory legs; and it bills per PR forever. If the end-to-end diagnostic proof is ever
wanted it is an attended or scheduled check outside the publishing repository, not a PR gate.
Record the option-(b) choice in the docket where the blocked half is named, and strike the
blocker."*

### What the ruling closes

P1-3's second half -- "one diagnostic surfaces" -- was carried as **BLOCKED on a credential** by
dispatch 000287, which named the obstacle correctly and did not route around it. That block is now
resolved **by ruling rather than by provisioning**, which is a different and better outcome than
the one 000287 was hoping for: the slice is not waiting on anything.

- `docs/SUPPORT-POLICY.md` gains a subsection under **Claude Code versions** that names what the
  registration half proves -- a real client of two pinned versions accepts and registers this
  plugin, asserted against the client's OWN inventory -- and what it does not: that a diagnostic
  surfaces to a user. The three axes above are recorded there as the reason, so a reader meets the
  boundary in the support document rather than inferring it from a CI file.
- `ENTERPRISE-PROGRAM-DOCKET.md` P1-3 is re-headed **COMPLETE at registration-only**, the blocker
  is struck, and the "one diagnostic surfaces" clause is struck from the mechanism. The original
  obstacle text is left in place unchanged so the reasoning that led to the ruling stays legible.
- **No `claudeCodeCompatibility` block is written, and none will be written from this leg.** The
  declaration is the output of certification; a declaration written from a registration-only matrix
  would claim more than the matrix proved, which is the ordering this slice exists to protect.

## Policy v2's payload half, built (P1-5, ruling R9) -- dispatch 000289, 2026-09-09

**What shipped.** The `orgPolicy` file gains an optional `SeverityOverrides` table beside
`ExcludeRules`, mapping rule code to severity, enforced at the same final position as the exclude
drop and immediately after it. R9 (ruled by Mike Andersen 2026-09-05, ratified by acceptance of the
000279 inbox) chartered the include-side payload only and left signing until a trust root exists;
that split is honoured exactly -- **nothing here signs anything, and nothing here trusts what it is
handed.**

**Why this is the include side, and not a cosmetic relabel.** The enterprise review's item 2
argument was that a subtract-only payload cannot express an org REQUIREMENT. It cannot. An
organization could take a rule away and had no vocabulary for *"this one matters here"*. A severity
the org sets and no local layer can undo IS that vocabulary: the load-bearing test is a repo that
narrows its surface to a single rule with `ruleInclude` -- the path where repo-local wins under v1
-- and still sees that rule at the org's severity.

**What was deliberately NOT built, and why the reason is structural.** `requiredRules` and
`prohibitedSuppressions`, the other two members of the docket's payload trio, are not built. The
org layer is a client-side pass over findings that already exist, and a rule the analyzer never ran
produces no record for a post-filter to conjure. Forcing a rule ON means reaching the settings the
daemon hands to PSES, which is the seam `Resolve-PssaSettingsPath` deliberately does not read
itself. That is the same slice as closing the threshold boundary below, and they belong together.
`severityOverrides` is the member of the trio the existing seam can enforce honestly, which is why
it is the one that shipped -- a judgement about what the seam supports, not about what was cheap.

**The boundary is recorded here because it will outlive the memory of it.** An override re-stamps
a finding already on the surface; it cannot resurrect one the daemon's own `severityThreshold`
dropped first. At the shipped default (`Hint`) nothing is threshold-dropped and overrides are fully
effective. BOTH arms are asserted by test -- the raised-threshold miss and the default-threshold
hit -- so this is a measured property of the build and not a caveat in a document that can quietly
stop being true.

**Hub Rule 18 applied to the reader.** `Import-OrgPolicy` is now the single reader returning both
halves from one parse, one integrity gate and one degrade warning; `Import-OrgPolicyExcludes` is a
projection of it, so every existing caller and test is unchanged. Two readers would have been two
places for the absolute-path rule, the `.sha256` gate and the degrade vocabulary to drift.

**Freeze exposure: genuinely zero.** No `userConfig` key, no new file, no CONTRACT line -- the key
lives inside the policy file the existing `orgPolicy` path already points at, and the policy file
schema is not a Tier 1 surface. A v1 policy leaves the override map empty and the applier is then
the identity function, which is asserted rather than assumed.

### The shape this is an instance of

The ruling names it: **000283's R17 shape -- a live dependency bought for one end-to-end
assertion.** R17 declined a live gallery dependency on the ground that the structural proof was the
stopping point. This is the same trade and it loses on three further axes that R17 did not face,
because the dependency here is a *credential* in a repository that publishes attested artifacts,
not merely a network call. Recorded as a second sighting of that shape.
