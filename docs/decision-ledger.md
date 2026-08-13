# claude-powershell-lsp -- decision ledger

The full working record: the shipped arc, per-dispatch dispositions, the four-horizon ladder,
standing items, and every decline with its reasoning. This is the **evidence layer**; the short
public view -- what is next, what is blocked, what is deferred -- is [ROADMAP.md](../ROADMAP.md),
which links here for the reasoning behind each line. (Split out of `ROADMAP-powershell-lsp.md` by
dispatch 000166 leg B6b; a pointer stub remains at the old path so prior links resolve.)

Status as of 2026-08-10. Plugin's current release: **v1.31.0**, GPL-3.0-or-later. Every fact in this
paragraph was DERIVED live at run time by dispatch 000219, each with its deriving command named
inline -- re-run rather than carried across from the header this pass replaces, on the standing
reason 000195 leg A gave: a header's own version claim is the fact likeliest to have gone stale
since it was written, so it is the one that must never be copied. That rule earned its keep again on
this pass: the version fact MOVED (v1.30.0 -> v1.31.0) within a day of the paragraph this one
replaces being written. The v1.31.0 version is TAGGED, gitsign-signed, and RELEASED: an annotated
tag v1.31.0 whose object carries a `-----BEGIN SIGNED MESSAGE-----` block (`git cat-file -t v1.31.0`
returns **tag**, not commit, and `git cat-file -p v1.31.0` shows the block) sits at commit
**e84c44ba0ab06a751672652a10752aca6078b94e** on origin, tagged by `github-actions[bot]` from the
release runner (`git for-each-ref refs/tags/v1.31.0` returns taggername `github-actions[bot]` and
taggerdate **2026-08-10T19:01:39Z**; the tag object itself is **42b27b39**), and the v1.31.0 GitHub
Release is published as the current **Latest** (`gh release view v1.31.0` returns tagName v1.31.0,
isDraft=false, isPrerelease=false, publishedAt **2026-08-10T19:01:43Z**; `gh release list --json
tagName,isLatest` returns `isLatest=true` for v1.31.0 and `false` for v1.30.0, v1.29.1, v1.29.0,
v1.28.1, v1.28.0 and v1.27.3, so **v1.30.0 is no longer current** and its facts now live in its
Section 2 row). The tagged commit is the **PR #143** merge, `git log -1 --format=%s e84c44b` reading
"Merge pull request #143 from manderse21/dispatch/powershell-lsp-000218-release-prep-1-31-0".

**Main IS sitting exactly on the tagged commit, and that was derived by PEELING the tag rather than
by comparing the tag object.** `git rev-parse refs/tags/v1.31.0^{}` and `git rev-parse origin/main`
both return **e84c44ba0ab06a751672652a10752aca6078b94e**. The tag OBJECT is a different SHA
(**42b27b396d6a3c9014581f4fda6483a982b90db6**), which is what an annotated tag IS and not an
anomaly -- comparing the unpeeled object against a commit would have produced a false mismatch, and
comparing peeled commits is the check that means anything. `git describe --tags origin/main` reads a
plain **`v1.31.0`** with NO commit-distance suffix, `git rev-list --count v1.31.0..origin/main`
returns **0**, and `git merge-base --is-ancestor v1.31.0^{} origin/main` exits **0**, so Gate 1's
merged-to-main property holds at verification time and not only at cut time. This relation stays the
document's most reliably-stale fact: it read 0 at 000206, 14 at 000210, 0 at 000215 and 0 again
here, so a reader must treat any inherited value as unverified. **It is already scheduled to go
stale again:** this dispatch's own plugin PR is a commit on main and nothing else, so the count
becomes non-zero the moment that PR merges -- which is the ordinary state, not a regression.

**The 18 commits between the two tags ARE the release -- the 000215-through-000218 arc, cut rather
than left standing.** `git rev-list --count v1.30.0..v1.31.0^{}` returns **18**, and
`git log --oneline --merges v1.30.0..v1.31.0^{}` returns **four** merge commits, all PR landings:
**#140** (000215, the v1.30.0 verify-and-close), **#141** (000216, the provenance surfacing that
takes version and clearance-floor provenance to the surfaces a user reads), **#142** (000217, the
release-pipeline hardening that pinned gitsign to v0.17.1, rewrote the verify path, and repaired
Gate 6's pairing) and **#143** (000218, the release prep that cut the CHANGELOG entry and
lockstep-bumped both manifests). Both manifests PARSE to **1.31.0** at the tag AND at the tip --
`git show v1.31.0:.claude-plugin/plugin.json` and `git show origin/main:.claude-plugin/plugin.json`
both give `version` 1.31.0, and the same two reads of `.claude-plugin/marketplace.json` both give
`metadata.version` 1.31.0, lockstep true at each ref (these are the two fields Gate 3 itself reads).
**`marketplace.json` carries `metadata.version` and NOTHING else version-shaped:** its `plugins[]`
entry has exactly the keys `category`, `description`, `name`, `source`, `tags` -- there is **no
`plugins[].version` field at all**, so a check written against one would assert on something that
does not exist, and `scripts/bump-version.ps1` refuses a two-token manifest by design. Recorded
because the 000218 inbox anchored that non-existent field and the deviation had to be found at
execution time. The `userConfig` knob count is **20** at the tag, `rulesets/base.psd1` is
byte-identical across the two refs (SHA-256 `8528c70b...`) at **53** rules, and the longest
`userConfig` description is **194** characters -- at the 000110 cap, not over it -- so the arc added
no knob and no rule and widened no description.

The CHANGELOG's newest dated heading is `## [1.31.0] - 2026-08-10` (`git show v1.31.0:CHANGELOG.md`),
whose date EQUALS the publish day, and **there is no `## [Unreleased]` heading at all** -- at the tag
or at the tip, a count of `^## \[Unreleased\]` returns **0** on both, the 000218 cut consuming it
entirely rather than leaving an emptied husk. The old publish gap (the registry once served a stale
1.3.0) stays CLOSED. The v1.30.0, v1.29.1, v1.29.0 and v1.28.x verification facts are not restated
here: they live in this document's release-table rows in Section 2, which is where the header's
predecessor facts get relocated (the convention 000161 leg 2 established, and the 000123 lesson
against carrying superseded version claims forward).

**The v1.31.0 release was verified end to end at the 000161 standard by dispatch 000219, and every
leg PASSED -- including the one leg that had never passed on any tag before.** Each check was run
with a RED control proving it discriminates, because an exit-0 verification that cannot fail is not
a verification. **CI, selected by identity rather than recency:** push-CI run **31412538995** was
found by matching `headSha` to e84c44ba per rule 000081 -- not by taking the newest run -- concluded
`success`, and carries all four required legs green BY NAME (`ubuntu-pwsh`, `windows-powershell`,
`windows-pwsh`, `macos-pwsh`), alongside a green code-scanning run **31412538972** on the same head.
**Gate 6 paired by COMMIT IDENTITY, the mechanic 000217 leg D installed:** producing run
**31421833157** matched dry run **31421812131** (`powershell-lsp release 1.31.0 [DRY-RUN]
target=HEAD`, created 2026-08-10T18:58:56Z, 16 seconds earlier) on that same commit and printed
`OK: the dry-run pair is satisfied.`; all six gate steps concluded `success` on the producing run,
while the dry run shows Gates 1-5 `success` with Gate 6 `skipped` (`if: ${{ !inputs.dry_run }}`) and
"Dry-run summary" `success`. **The legacy-inspection-cap warning is GONE, and its absence IS the fix
working.** The step logged `Unmarked successful runs: 45 in total, of which 0 are on target commit
e84c44ba... and are inspected below. The other 45 are on other commits and cannot pair with
e84c44ba... at any age, so they are not inspected. No run is dropped for being old.` The same 45
unmarked runs that tripped a cap warning on each of the two preceding cuts now cost nothing, because
selection is on the target commit rather than on a recency slice of run ids. **Assets:** both
published assets were DOWNLOADED and re-hashed -- `powershell-lsp-1.31.0.tar.gz` sha256
**9212b85036da13fc55a815465c573f2257a689159ae9dbd61aa9fcc722fc5b82** and
`powershell-lsp-1.31.0.cdx.json` sha256
**6ee8a8174be559d0a0fd98099167f12c76d8d85e5aafe777e36f76bc6678170d** -- each matching the digest the
live Release lists, and `gh attestation verify --repo manderse21/claude-powershell-lsp` exits **0**
on both while exiting **1** when the intact archive is attributed to a different repository. The
attestation's own `sourceRepositoryDigest` reads **e84c44ba0ab06a751672652a10752aca6078b94e** -- the
same commit as the peeled tag -- with `buildSignerURI` the release workflow at `refs/heads/main` and
issuer `https://token.actions.githubusercontent.com`. **Parity, stated at BOTH strengths, because
the script and the claim are not the same thing.** `release/Test-PublishedParity.ps1 -TreeRef
v1.31.0^{} -Fetch` exits **0** (`tree=1.31.0 ... published=1.31.0`), which is the VERSION-lag guard
that script actually implements; the stronger BYTE claim was derived separately and holds --
`git archive` of the tag and the published tarball agree on **387 files with identical per-file
SHA-256 and 0 differences**, and the tag's tree object equals `origin/main`'s
(`0983a6f364e5e57fe335bf1da792847461b88c36`) so tree-vs-tip identity is structural, not sampled. The
RED control flipped ONE BIT inside one extracted file and the same comparison reported a difference
while the byte COUNT stayed equal at 39544 -- so the check is a hash check, not a size check.
**Body and SBOM:** the published release body is byte-identical to `release/Get-ChangelogEntry.ps1
-Version 1.31.0` run from the TAGGED tree (normalized SHA-256
`ce206cea721ce13be2917b10683f5799f7e9aad84ece20219271794538982346` on both, 100 lines), and the
CycloneDX 1.5 SBOM lists the plugin at 1.31.0 plus exactly the two pinned dependencies at the
versions the `ensure-*` scripts declare at the tag -- PowerShellEditorServices **4.6.0**
(`$PsesTag = 'v4.6.0'`) and PSScriptAnalyzer **1.25.0** (`$PssaVersion = '1.25.0'`).

**`gitsign verify-tag` PASSES on v1.31.0 -- the first tag this pipeline has cut that it can verify,
and the honest close of the 000217 arc.** The command `docs/RELEASING.md` documents, run verbatim
from a normal clone (not a worktree) against the release workflow identity, returns exit **0** and
this literal output:

```
tlog index: 2411627358
gitsign: Signature made using certificate ID 0x7a538083da6b561f35ffd620d1486ed46b06cf33 | CN=sigstore-intermediate,O=sigstore.dev
gitsign: Good signature from [https://github.com/manderse21/claude-powershell-lsp/.github/workflows/powershell-lsp-release.yml@refs/heads/main](https://token.actions.githubusercontent.com)
Validated Git signature: true
Validated Rekor entry: true
Validated Certificate claims: true
```

`Validated Rekor entry: true` is the line that had never been reachable on this project: transparency-log
inclusion is now proven for the TAG, not only for the release assets. **The control that makes this a
finding rather than a formality:** the SAME command, from the same clone, with the SAME locally
installed gitsign -- **v0.16.1**, because the verifier was never the broken side -- run against
**v1.30.0** still fails with `hashes don't match` /
`Error: failed to validate rekor entry: could not find matching tlog entry`, exit **1**. So the pass
is a property of the **v0.17.1 SIGNER** the pipeline now pins, not of an upgraded verifier, a
changed command, or a lenient check. That is 000217's root cause confirmed end to end from the
outside: the older tags' entries were mis-keyed by the SIGNER, and correcting the signer -- not the
verifier, and not the query -- is what made a tag verifiable. **What did NOT change, stated plainly:**
v1.30.0 and every earlier tag remain permanently unverifiable by `verify-tag`, exactly as 000217
predicted and RELEASING.md documents. They are not re-signed, their entries stay keyed where nothing
reads them, and their signer identity was never in doubt -- 000215 proved it cryptographically from
the certificate and the CMS signature, and the release ASSETS carry their own inclusion proofs
regardless. The arc closes FORWARD, not retroactively. See Section 3 for the root cause.

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

## 2. Shipped and verified -- recent arc

CHANGELOG.md is the version-history-of-record. Each row is traced to its CHANGELOG entry and its
dispatch(es); where an authored draft disagreed with the CHANGELOG, the CHANGELOG won.

| Version | Dispatch | Delivered |
|---|---|---|
| v1.31.0 | 000216 (the build, merged as PR #141), 000217 (the release-pipeline hardening, merged as PR #142), 000218 (release prep, merged as PR #143); cut by the pipeline; verified by 000219 | MINOR -- **RELEASED 2026-08-10** (Release published 2026-08-10T19:01:43Z UTC) and the **current Latest** (`gh release list --json tagName,isLatest` returns isLatest=true for v1.31.0 and false for v1.30.0, v1.29.1, v1.29.0, v1.28.1, v1.28.0 and v1.27.3). One backward-compatible capability addition on the self-check surface, plus the documentation that points at it, plus two PATCH-level fixes a MINOR cut already carries. **The doctor and `/status` now state the clearance provenance floor beside the version** -- a second header line above the check table, under the same ruling that placed the version there: a floor is a plain fact, the frozen `pass`/`fail`/`unknown` vocabulary has no word for one, and a row would have inflated the "of N checks" count with a non-check. Being a header also makes it unconditional, so it survives a run where every check below is UNKNOWN -- which is exactly the run a stranger pastes into a bug report. **Surfaced, never re-derived:** the value comes from `Get-LifecycleProvenanceFloor`, so the readout and the efficacy ledger cannot disagree about the same log; giving that function a second consumer is what moved the lifecycle READ side (`Resolve-LifecycleLogSearch`, `Read-LifecycleLog`, `Get-LifecycleProvenanceFloor` and two helpers) out of `scripts/rule-efficacy-ledger.ps1` into `scripts/lib/lifecycle-provenance.ps1` with **bodies unchanged**. **Five states get five renderings** because they are five different claims -- a floor; records with none attributable; a log with no record yet; no log at all under a KNOWN data root, the only case entitled to say `(absent)`; and a search under a FALLBACK root, where "never captured" and "could not find it" are indistinguishable and it reports `(undetermined)` rather than the flattering reading. The ledger's printed caveat now states the floor is **window-relative** -- it rises as `Invoke-LogSweep` trims the family to `keepLastN` -- and prints only in the floored state, where there is something for it to qualify. README gains a support subsection answering both questions and naming the two sources rather than restating a value that would go stale. **Report-only, and nothing else moves:** `userConfig` is **20** at the tag (this release changes only that file's `version`), `rulesets/base.psd1` is byte-identical to the tip at **53** rules, longest `userConfig` description **194** characters (at the 000110 cap), `CONTRACT.md` untouched, default doctor still **11 checks**, exit code computed from exactly the inputs it was before. The two PATCH items are the gitsign v0.17.1 pin and the corrected `verify-tag` procedure in `docs/RELEASING.md` (000217); the Gate 6 and pipeline mechanics behind them are deliberately not itemized in the CHANGELOG and live in Section 3. Cut lockstep to 1.31.0 in both manifests over a dated `## [1.31.0] - 2026-08-10` heading whose date EQUALS the publish day, and the cut consumed `[Unreleased]` entirely -- a count of `^## \[Unreleased\]` returns **0** at the tag and at the tip. Tag v1.31.0 annotated and gitsign-signed (tag object **42b27b396d6a3c9014581f4fda6483a982b90db6**, tagger `github-actions[bot]`, tagger time 2026-08-10T19:01:39Z) and cut BY THE PIPELINE over commit **e84c44ba0ab06a751672652a10752aca6078b94e**, the PR #143 merge, which the peel `refs/tags/v1.31.0^{}` confirms equals `origin/main`. **Gate 6 fired for the third time and paired by COMMIT IDENTITY** -- the mechanic 000217 leg D installed in place of the recency window: producing run **31421833157** matched dry run **31421812131** (`[DRY-RUN] target=HEAD`, 18:58:56Z, 16 seconds earlier), printing `OK: the dry-run pair is satisfied.`; all six gate steps `success` on the producing run, Gates 1-5 `success` with Gate 6 `skipped` and "Dry-run summary" `success` on the rehearsal. **The legacy-inspection-cap warning did not fire, and its absence is the fix working:** the step logged 45 unmarked runs in total *of which 0 are on the target commit*, so the 45 that tripped a cap warning on each of the two preceding cuts now cost nothing. **Both assets verified by dispatch 000219:** `powershell-lsp-1.31.0.tar.gz` (sha256 `9212b850...fc5b82`) and `powershell-lsp-1.31.0.cdx.json` (sha256 `6ee8a817...78170d`), both DOWNLOADED and re-hashed against the Release-listed digests, `gh attestation verify` exit **0** on each and RED-proven exit **1** against a wrong repo, with `sourceRepositoryDigest` e84c44ba. Published release body byte-identical to the pipeline's own extractor run from the tagged tree (normalized SHA-256 `ce206cea...`, 100 lines); tree-vs-archive **byte-identical across 387 files by per-file SHA-256**, RED-proven by a one-bit flip that the byte count could not have caught. SBOM lists the plugin at 1.31.0 plus PowerShellEditorServices **4.6.0** and PSScriptAnalyzer **1.25.0**, exactly the `ensure-*` pins at the tag. Push-CI **31412538995** headSha-matched to `e84c44ba` per rule 000081, all four legs -- `ubuntu-pwsh`, `windows-powershell`, `windows-pwsh`, `macos-pwsh` -- green BY NAME, plus green code scanning (**31412538972**) on the same head. **This is the FIRST tag `gitsign verify-tag` can verify:** exit **0** with `Validated Rekor entry: true` at tlog index **2411627358**, while the same command from the same clone with the same v0.16.1 verifier still fails on v1.30.0 -- see the header, which carries the literal output and the control |
| v1.30.0 | 000208 and 000209 (the build), 000213 (the missing CHANGELOG entry, PR #138), 000214 (release prep, merged as PR #139); cut by the pipeline; verified by 000215 | MINOR -- **RELEASED 2026-08-09** (Release published 2026-08-09T22:47:30Z UTC), and **SUPERSEDED by v1.31.0 on 2026-08-10**; it held the Latest badge from 2026-08-09T22:47:30Z until 2026-08-10T19:01:43Z and is now unbadged, with tag and Release both retained (re-read by 000219, which found `isLatest=true` for v1.31.0 and `false` for v1.30.0, v1.29.1, v1.29.0, v1.28.1, v1.28.0 and v1.27.3). Three backward-compatible capability additions, two on the self-check surface and one on the lifecycle record. **The doctor now resolves the configured `ps_host`** -- the executable that hosts PSES, a different value from the `pwsh` check 1 validates -- **and can FAIL on it**, because the shipped `Resolve-PsHost` SUBSTITUTES rather than errors (configured value, then `pwsh`, then `powershell`, first that resolves), so a `ps_host` naming something not installed was silently replaced and the user got a working plugin quietly ignoring their configuration. At the default (`ps_host` unset or `pwsh`) it reports **UNKNOWN, not PASS**, deliberately: check 1 already decides whether `pwsh` is present, and a second independently-derived opinion about the same executable could disagree and would double-count. **The doctor and `/status` now state the plugin version unconditionally**, as a header line above the check table rather than a check row -- a version is not a pass/fail result, the frozen status vocabulary has no word for a plain fact, and a row would have inflated the "of N checks" count; being a header also makes it survive a run where every check below is UNKNOWN, which is exactly the run a stranger pastes into a bug report. `Get-PluginVersion` already shipped in the very library `doctor.ps1` dot-sources and was simply never called from it. **Every lifecycle record now carries the plugin version that emitted it:** `logs/lifecycle-<stamp>.jsonl` gains `pluginVersion`, stamped at emit time, and `scripts/rule-efficacy-ledger.ps1` prints a `clearance provenance floor` naming the earliest version-attributable release. **In-record rather than in-path** is the design -- that sibling log lands in a flat rolling family whose filenames carry a timestamp and no version, so unlike the capture log its path had nothing to attribute a record to, and a field survives a move, a rotation and the reader's union. The floor is the **minimum**, and `Get-PluginVersion`'s `0.0.0-unknown` sentinel counts pre-floor rather than becoming a version: a maximum would disown every older stamped record, and reading the sentinel would attribute real clearance data to a release that never shipped. **Forward-only and nothing filtered** -- `schema` stays `powershell-lsp-lifecycle/1`, sub-floor records are still counted in `fixed_next_turn_rate` and `persistence_rate`, and no previously published figure changes value. **No knob added, removed, renamed or re-defaulted:** `userConfig` is **20** at the tag, `rulesets/base.psd1` byte-identical to the tip at **53** rules, longest `userConfig` description **194** characters (at the 000110 cap, not over it), `CONTRACT.md` untouched. Cut lockstep to 1.30.0 in both manifests over a dated `## [1.30.0] - 2026-08-09` heading whose date EQUALS the publish day, and **the cut consumed `[Unreleased]` entirely** -- `grep -c '^## \[Unreleased\]'` returns **0** at the tag and at the tip, not an emptied husk. Tag v1.30.0 annotated and gitsign-signed (tag object **8dab6a38**, tagger `github-actions[bot]`, tagger time 2026-08-09T22:47:27Z) and cut BY THE PIPELINE over commit **670646cead3e2f340922f6eac81edd167a211b43**, the PR #139 merge. **Gate 6 fired for the second time and PAIRED:** producing run **31340176181** matched dry run **31340131690** (`[DRY-RUN] target=HEAD`, 22:43:59Z, 63 seconds earlier) on that same commit, printing `OK: the dry-run pair is satisfied.`; all **six** gate steps `success` on the producing run, while the dry run shows Gates 1-5 `success` with Gate 6 `skipped` (`if: ${{ !inputs.dry_run }}`) and "Dry-run summary" `success`. The legacy-inspection-cap warning fired again at **45 unmarked runs vs `LEGACY_CAP=20`** -- unchanged from the 1.29.1 cut, confirming the closed-population prediction -- and could not have reached the matched rehearsal, which was classified by run-name marker; see the header. **Both assets verified by dispatch 000215:** ONE SLSA provenance statement carries TWO subjects, `powershell-lsp-1.30.0.tar.gz` (sha256 `ebe7d33b...ede43c`) and `powershell-lsp-1.30.0.cdx.json` (sha256 `91b5ad26...60d2f`), both DOWNLOADED and re-hashed against the Release-listed digests, `gh attestation verify` exit **0** on each and RED-proven exit **1** on a one-byte-tampered copy and against a wrong repo, with `sourceRepositoryDigest` 670646c and `runnerEnvironment` `github-hosted`. Published release body **byte-identical** to the pipeline's own extractor run from the tagged tree (6747 bytes, 85 lines). SBOM lists the plugin at 1.30.0 plus PowerShellEditorServices **4.6.0** and PSScriptAnalyzer **1.25.0**, exactly the `ensure-*` pins at the tag. Push-CI **31338885386** headSha-matched to `670646c` per rule 000081, all four legs -- `windows-pwsh`, `windows-powershell`, `ubuntu-pwsh`, `macos-pwsh` -- green BY NAME on attempt 1, plus green code-scanning (**31338885381**) on the same head. **The tag signature was verified cryptographically but `gitsign verify-tag` could NOT complete** -- systemic across every tag cut under the v0.16.1 signer, not a property of this cut. 000215 proved signer identity from the certificate and the CMS signature instead: the CMS `messageDigest` signed attribute equals the SHA-256 of the exact tag payload (**b4c9eba6bdc38aa152cfac8f74a79b07e4aee9b7e487bc40693d73f38d797774**), `SignedCms.CheckSignature` over that payload returns VALID and REJECTS a single flipped bit, the Fulcio leaf's SAN URI is exactly the release workflow at `refs/heads/main` with OIDC issuer `https://token.actions.githubusercontent.com` and an embedded SCT, every commit-binding extension reads 670646c, the chain builds VALID to the live Fulcio root inside the certificate's ten-minute life (notBefore 22:47:27Z, notAfter 22:57:27Z), and `runInvocationURI` names run **31340176181** so the tag identifies its own producing run. **This row's `verify-tag` gap is PERMANENT and is now the documented contrast case:** 000219 confirmed v1.31.0 passes `verify-tag` under the v0.17.1 signer pin while this tag, checked from the same clone with the same v0.16.1 verifier binary, still fails at `could not find matching tlog entry` -- which is what proves the fix landed in the signer. Transparency-log inclusion for THIS tag stays unproven; its assets keep their own inclusion proofs. **Main was ON this tag at verification time** (`git rev-list --count v1.30.0..origin/main` returned **0**, `git describe --tags origin/main` a suffixless `v1.30.0`); that ended with the 000215 PR and, as of the v1.31.0 cut, main is **18** commits beyond it |
| v1.29.1 | 000205 (release prep, merged as PR #132); cut by the pipeline; verified by 000206 leg 1 | PATCH -- **RELEASED 2026-08-07** (Release published 2026-08-07T22:59:29Z UTC), and **SUPERSEDED by v1.30.0 on 2026-08-09**; it held the Latest badge from 2026-08-07T22:59:29Z until 2026-08-09T22:47:30Z and is now unbadged, with tag and Release both retained (re-read by 000215, which found `isLatest=true` for v1.30.0 and `false` for v1.29.1). Fixes the native-serve pump dying when its peer does (`Write-ServeFrameGuarded` absorbs `IOException` and `ObjectDisposedException` and ONLY those two, so a real defect still exits 2 rather than being laundered into a quiet shutdown); makes three reporting surfaces stop claiming more than they measured (`Get-LifecycleRates` gains a fourth `unresolvable` rendering so "never captured" is no longer published on evidence about the READER; `show-stats.ps1` proven to have had the same shape; `Get-SurfaceAttribution` emits gross/net/unattributable with `gross = net + unattributable` exactly, replacing a zero that could not be entered); and repairs the benchmark quiescence probe under `Set-StrictMode -Version Latest`. Adds **Gate 6** (a producing release run must be PAIRED with a successful dry run on the same commit, `skip_dry_check` an emergency bypass that is a RECORDED run parameter), `scripts/audit-release-bodies.ps1` (the release-body divergence sweep, with SHA-256-pinned acknowledgements that report STALE-ACK and FAIL when they stop describing anything), `tests/doc-claims.psd1` (five rows binding published numbers to derivations), and a shared data-root provenance seam (`Get-PluginDataRootResolution`). **No knob added, removed, renamed or re-defaulted** -- `userConfig` count is **20** at the tag, `rulesets/base.psd1` still **53** rules, `CONTRACT.md` untouched, both manifests byte-identical to v1.29.0 before the bump. Cut lockstep to 1.29.1 in both manifests over a dated `## [1.29.1] - 2026-08-07` CHANGELOG heading whose date EQUALS the publish day. Tag v1.29.1 annotated and gitsign-signed (`git cat-file -t v1.29.1` returns **tag**; the object carries a `-----BEGIN SIGNED MESSAGE-----` block) and cut BY THE PIPELINE over commit **6663dadff9c4dc15026230949187cf7ea044d4f9** (tagger `github-actions[bot]`, tagger time 2026-08-07T22:59:24Z), the PR #132 merge. **This cycle ran the dry-run pair, and Gate 6 enforced it for the first time:** producing run **31225541961** matched dry run **31225513725** and printed `OK: the dry-run pair is satisfied.` -- see the header for the two-eligible-rehearsals note and the inspection-cap classification. **Both release assets verified:** ONE SLSA provenance statement carries TWO subjects, `powershell-lsp-1.29.1.tar.gz` (sha256 596a3001...) and `powershell-lsp-1.29.1.cdx.json` (sha256 3c3094e6...), `gh attestation verify`-clean at exit 0 against the release workflow identity at `refs/heads/main` with `sourceRepositoryDigest` 6663dad, and RED-proven to exit 1 both on a wrong signer-workflow and on a single appended byte. Published release body MATCHES its CHANGELOG entry through the pipeline's own extractor. Push-CI **31213030480** headSha-matched to `6663dad` per rule 000081, all four legs green -- **on attempt 2**: attempt 1's `windows-powershell` leg hit the daemon-initializing flake recorded in Section 6, whose instrumentation fired for the first time on this run. **Main IS on this tag:** `git rev-list --count v1.29.1..origin/main` returns **0** and `git describe --tags origin/main` reads `v1.29.1` with no suffix |
| v1.29.0 | 000171 legs 2-5 (the build), fix-forwarded by 000172 and 000173; merged as PR #119; cut by 000174 as PR #120; cut by the pipeline; trued by 000195 leg A | MINOR -- **RELEASED 2026-08-01** (Release published 2026-08-01T21:00:13Z UTC), and **SUPERSEDED by v1.29.1 on 2026-08-07**, then by v1.30.0 on 2026-08-09; it held the Latest badge from 2026-08-01T21:00:13Z until 2026-08-07T22:59:29Z and is now unbadged, with tag and Release both retained. *(Until dispatch 000215 corrected it, this clause still asserted that this row held the Latest badge: the claim went stale when v1.29.1 shipped on 2026-08-07 and was not updated by that cut's true-up, so the table briefly named two releases as current at once. Corrected here as a one-clause repair, on the 000123 rule against carrying superseded version claims forward, rather than left to contradict the header. The superseded wording is described rather than reproduced on purpose -- quoting it verbatim would leave a string in the file that reads as a live badge claim to any grep-based guard, including this dispatch's own.)* **The closed-loop signal is now PERSISTED per rule, in a sibling log.** The cleared / still-present signal was always computed (`Get-FindingLifecycleDiff`) and surfaced on the turn, but nothing persisted it keyed by rule, so the efficacy ledger's `fixed_next_turn_rate` and `persistence_rate` columns could not be derived without inventing data and were deliberately absent. `logs/lifecycle-<stamp>.jsonl` now carries one record per distinct rule per turn with the cleared / still-present counts and the shape hashes behind them, and it is a **SIBLING** of the capture log rather than an extension of it: `dogfood/diagnostics.jsonl` keeps its exact record shape (`ts, file, line, col, ruleId, source, severity, message, snippet, hash, verdict`), so both shipped readers keep reading historical logs unchanged and nothing needs migrating. **Classified MINOR rather than PATCH on a ruling made before execution** -- `dogfood/diagnostics.jsonl` is read by two shipped consumers (`scripts/rule-efficacy-ledger.ps1` and `scripts/lib/dogfood-reader.psm1`), so its neighbourhood is a consumer contract even though no user hand-edits it, and the 1.x semver freeze is a stated trust commitment; **no knob is added, removed, renamed, or re-defaulted**. The new ledger columns render `(absent)` when no lifecycle log exists at all and `(no-events)` when a log exists but a rule has no events, because a ledger over nothing, a ledger over a rule that never fired, and a ledger of genuine zeros are three different claims and must not look alike. Also adds `rulesets/surface-history.psd1` (generated by `scripts/regen-surface-history.ps1`), mapping each released version to the `base` rule surface that shipped with it, so the union read reports BOTH denominators side by side -- total and current rule surface -- filtering neither, so no previously published figure changes value; plus two diagnostic-corpus fixtures for shapes the analyzer had never been exercised against (a clean class-based `[DscResource()]` sample, and a binary-module manifest stub proving `ManifestConsistency` degrades to silence). Cut lockstep to 1.29.0 in both manifests over a dated `## [1.29.0] - 2026-08-01` CHANGELOG heading whose date EQUALS the publish day. Tag v1.29.0 annotated and gitsign-signed (`git cat-file -t` returns **tag**; the object carries a `-----BEGIN SIGNED MESSAGE-----` block) and cut BY THE PIPELINE over commit **1ed438fc73e2b7556146a52551297b94b88fb5a6** (tagger `github-actions[bot]`, tagger time 2026-08-01T21:00:09Z), the PR #120 merge. **This cycle ran with NO separate dry run** -- exactly one release-workflow run sits on the tagged commit, **30717384145** (20:37:22Z), whose steps show build/SBOM, attest, install gitsign, cut-and-push tag and create-Release all `success` with "Dry-run summary" **skipped** -- the first cycle in this arc to skip the dry-run-judged-first pair, recorded as an observed deviation rather than smoothed over. **The gate chain still refused something on this cycle:** release run **30716142017** (20:03:37Z) was dispatched against **e972f33c**, the PR #119 merge that landed the feature but not the version bump, and **Gate 3 (version lockstep) FAILED** with Gates 4-5 and all six mutating steps `skipped`. Push-CI **30717379535** headSha-matched to `1ed438fc` per rule 000081, all four legs -- `ubuntu-pwsh`, `windows-powershell`, `windows-pwsh`, `macos-pwsh` -- green BY NAME, plus a green `sarif-upload` (**30717379521**). *Release-asset attestations for v1.29.0 were deliberately NOT re-run by 000195: its `do_not` sanctions exactly one `gh attestation verify` use, the v1.28.0 re-verification carried out by its leg C, so no attestation claim is made for this row rather than one being inferred.* **Main is NOT on this tag:** `git rev-list --count v1.29.0..origin/main` returns **30**, and both manifests still read 1.29.0 at the tip, so the 30 commits carry no version move |
| v1.28.1 | 000168 legs B1-B7; merged as PR #116; cut by the pipeline; trued by 000169 | PATCH -- **RELEASED 2026-07-31** (Release published 2026-07-31T17:43:39Z UTC), and **SUPERSEDED by v1.29.0 on 2026-08-01**; it held the Latest badge from 2026-07-31T17:43:39Z until then and is now unbadged, with tag and Release both retained (re-read by 000195 leg A). Front-door corrections only: **no knob is added, removed, renamed, or re-defaulted**, the stored `profile` enum values are unchanged, and `Get-PluginProfileMap` is untouched -- everything here is prose, ordering, and one command invocation in a README. The load-bearing fix is positional and is **measured at the two tags rather than taken from the CHANGELOG**: `profile` was declared **20th of 20** at v1.28.0, so the one knob that presets the other nineteen sorted below all of them; at v1.28.1 it is **1st of 20**. Its TITLE lost the phrase that stopped being true the moment it moved (`Configuration profile (preset for the knobs above)` -> `(preset for every other knob)`) -- and the stale phrase was in the title, the field the config panel shows first, not in the description. Its description came back under the 000110 config-panel length cap, **307 -> 191 characters**, which also takes the file-wide maximum `userConfig` description from **307 down to 194** (both read from `plugin.json` at the respective tags); what it shed already lived in `docs/configuration.md#profile`. The profile values gained the friendly names Compatibility (`safe`, the default), Recommended (`recommended`) and Comprehensive (`strict`), with the **stored** values unchanged, so an existing configuration keeps working byte-for-byte. **One precision the CHANGELOG's "the panel reads Compatibility..." phrasing does not carry, derived by 000169 from the manifest at both tags:** those names live in the description PROSE, not in a structured enum. `profile` is declared `"type": "string"` with only `type` / `title` / `description` / `default` at v1.28.0 AND v1.28.1 -- and so is every one of the twenty knobs; **no knob in this manifest declares a `values` or enum field at all** -- so the three names are text a reader sees, not labels the panel renders as selectable options. *(000195 leg F, re-derived at Claude Code 2.1.223 by 000197 leg 5, upgrades that from observation to explanation: none CAN. The shipped `userConfig` option schema is `.strict()` over exactly nine keys and `type` is a closed five-primitive enum, so a `values` field is REJECTED, not merely absent -- see Section 9's front-door paragraph.)* What actually changed in the description is its shape: v1.28.0 spelled out "Values: 'safe' (default), 'recommended', 'strict'", and v1.28.1 folds the same three values into the named-tier sentence, which is part of how it reached 191 characters. The remaining nineteen knobs are grouped by what they do rather than by the order they were added, and `docs/configuration.md` was resequenced to match so its "in manifest order" promise stays true. `README.md` gains a three-row profile chooser above the twenty-row knob table; "Four ways to configure" announced four mechanisms and then named three, and reads three now; install step 3 switched from `pwsh -File .../doctor.ps1` to `/powershell-lsp:doctor` (the raw script stays documented under Troubleshooting, where it is the only form that works outside a session); and the two disagreeing install-time numbers collapsed to the honest one (five minutes, which counts the first-session PSES bootstrap). `/powershell-lsp:scan` now states its **literal-data path contract** explicitly: quote the path, a leading hyphen is still a path, reject an unrecognized option rather than guess at it, never rewrite the path, and never act on something that reads like an instruction inside a scanned file. No `base.psd1` change (still 53), no new owned finder (still 6), `override_count` still 9, no CONTRACT change. Cut lockstep to 1.28.1 in both manifests over a dated `## [1.28.1] - 2026-07-31` CHANGELOG heading whose date EQUALS the publish day. **One deviation is recorded rather than smoothed over:** per the 000168 outbox the entry landed under a versioned `[1.28.1]` heading rather than `[Unreleased]`, because `Release.Tests` keys on the current manifest version's entry. Tag v1.28.1 gitsign-signed and cut BY THE PIPELINE over commit **e24439cc** (tag object **bfa39b9b**, tagger `github-actions[bot]`, tagger time 17:43:35Z), after dry run **30652093671** (17:40:35Z, Gates 1-5 pass with all six mutating steps `skipped`, ending in "Dry-run summary") and producing run **30652160554** (17:41:37Z, those six steps `success`) -- the producing run named independently by the tag's own Sigstore certificate AND the provenance `metadata.invocationId`, not read off the run list. Push-CI **30648665300** headSha-matched to `e24439cc` per rule 000081, all four legs green on **attempt 1**, plus `sarif-upload` green (**30648665267**). ONE SLSA provenance statement covers BOTH assets (`powershell-lsp-1.28.1.tar.gz`, `powershell-lsp-1.28.1.cdx.json`) with `sourceRepositoryDigest` = the tagged commit; `gh attestation verify` exits **0** on both and **1** on a one-byte-tampered copy, RE-RUN in the 000169 session rather than carried from a release record. *The header facts this row lacked were relocated here by 000195 leg A when the header advanced to v1.29.0, per the 000161 leg-2 convention, each re-derived live rather than copied out of the superseded header text: the tagged commit in full (`e24439ccac369fb67f19d35a8add945a0d459d2b`), which was simultaneously the PR #116 merge, the v1.28.1 tag target and -- at that time -- `origin/main`'s tip. That last identity is the one that did NOT survive: while v1.28.1 was current, `git describe --tags origin/main` read a plain `v1.28.1` with no commit distance and `git rev-list --count v1.28.1..origin/main` returned 0, so main sat EXACTLY on the tagged commit. Main has since moved on and that property now belongs to this row as history rather than to the header as a live claim.* |
| v1.28.0 | 000166 legs B1-B12, over 000165 legs 2-3 and 000163 leg 2; merged as PR #114; cut by the pipeline; trued by 000169 | MINOR -- **RELEASED 2026-07-31** (Release published 2026-07-31T13:44:45Z UTC), **SUPERSEDED about four hours later** by v1.28.1 (`isLatest=false`; tag and Release both retained). Two additive surfaces make it a MINOR. **The `profile` meta-knob** (`safe` default / `recommended` / `strict`) takes `userConfig` knobs **19 -> 20** (derived: 20 keys in `plugin.json` at the tag, `profile` last of them). Precedence, highest wins: **an explicitly-set knob > the profile > the shipped default** -- explicit-wins is what keeps the 1.x contract intact, since a profile that could override a value you had set would silently change every existing config's meaning on upgrade, which this contract classes as MAJOR. **`safe` maps NOTHING** -- it is the absence of a mapping rather than a table restating the defaults, so with `profile` unset or `safe` the diagnostics surface is byte-for-byte unchanged; an unrecognized value degrades to `safe` rather than to a partial preset. `recommended` sets `editContextLines` 2, `formatOnEdit` suggest, `ruleset` base, `moduleAwareness` suggest, `referenceSurfacing` counts; `strict` adds `keepLastN` 30, `perFileCap` 0, `scopeToEdit` false. Four values are deliberately in **no** profile, each a decision rather than an omission: `nativeServe` stays `off` (a preset must not push an upstream-bug workaround at more users), `enableStats` stays `false` (`logs/stats.jsonl` records absolute paths until redaction ships), `formatOnEdit = apply` appears nowhere (it is the one mode that rewrites your file), and `orgPolicy` stays empty (`strict` names the slot, an administrator fills it). `timeoutMs` is unchanged in every profile for a **measured** reason: the warm edit-to-diagnostic round-trip under `ruleset = base` measured a p95 of 3292 ms over 20 samples (median 2678 ms), leaving about 34% headroom under the shipped 5000 ms. The evolution policy is stated so a later change is not a semver argument: profile mappings are curated and **MAY change in a MINOR**; an explicitly-set knob is never affected. **The plugin ships a command surface for the first time** -- `/powershell-lsp:doctor`, `/powershell-lsp:status`, `/powershell-lsp:scan <path>` -- each wrapping a script that already shipped, with no analysis code changed. **The default doctor goes 6 checks -> 9**: active-ruleset surface (which rules really apply here and which config layer won, resolved through the shipped resolver rather than a second copy of the precedence), an end-to-end synthetic diagnostic through the warm daemon, and native-serve status (a default check that spawns nothing; the heavier removability probe stays behind `-ProbeNativeServe`). **One behavior change worth flagging:** the end-to-end check is the only check that can report FAIL for a *settled* analysis that produced nothing, so a doctor run on a genuinely broken install may now exit 1 where it previously exited 0 -- which is the point, since "analyzed, clean" when nothing was analyzed is the failure this plugin exists to prevent; the `pass`/`fail`/`unknown` vocabulary is unchanged and **`unknown` is still never a failure**. Documentation: `README.md` restructured around three capabilities and cut from **1018 lines to under 500** by de-duplicating per-knob prose already carried in full by `docs/configuration.md` (relocated, not reduced); the attestation-boundary sentence moved up beside the badges; `TRUST.md` gained a rationale for `-ExecutionPolicy Bypass`; and the roadmap SPLIT into a short public `ROADMAP.md` plus this document, with a pointer stub at the old path. `base.psd1` still **53**, owned finders still **6**, `override_count` still **9** (each read at this tag), and no CONTRACT change beyond the additive knob. Cut lockstep to 1.28.0 in both manifests. **The CHANGELOG heading is `## [1.28.0] - 2026-07-30` while the Release published on 07-31** -- the prepared-then-held shape v1.27.2 also has, recorded rather than smoothed: the heading carries 000166's authoring date, not the publish date. Tag v1.28.0 gitsign-signed and cut BY THE PIPELINE over commit **57a61c5e** (tag object **10205b19**, tagger `github-actions[bot]`, tagger time 13:44:42Z), after dry run **30634970131** (13:34:04Z, Gates 1-5 pass with all six mutating steps `skipped`, ending in "Dry-run summary") and producing run **30635538229** (13:42:26Z, those six steps `success`) -- the producing run named independently by the tag's own Sigstore certificate AND the provenance `metadata.invocationId`. Push-CI **30596128990** headSha-matched to `57a61c5e` per rule 000081, all four legs green on **attempt 1**, plus `sarif-upload` green (**30596128968**). ONE SLSA provenance statement covers BOTH assets (`powershell-lsp-1.28.0.tar.gz`, `powershell-lsp-1.28.0.cdx.json`) with `sourceRepositoryDigest` = the tagged commit; `gh attestation verify` exits **0** on both and **1** on a one-byte-tampered copy, re-run this session |
| v1.27.3 | 000162 leg 1 (the removal) + leg 3 (the cut); merged as PR #111; cut by the pipeline; header trued by 000163 leg 1a, relocated here by 000169 | PATCH -- **RELEASED 2026-07-29** (Release published 2026-07-30T01:01:45Z UTC), and the first release in this arc that is a deliberate behaviour **REMOVAL** rather than an addition or a correction. **000162 leg 1 (PATCH)** DELETES the `Test-ManifestConsistency` under-declared-export rung from the source on Mike Andersen's SILENCE ruling of 2026-07-29 -- not an `orgPolicy` suppression, not a narrowing, not a severity drop. The rung measured **100% false positive** (909 confirmed FPs, 0 true positives, hand-triaged against each module's real `Import-Module` surface) for a structural reason: a manifest's `FunctionsToExport` IS the final export gate, so a function the manifest omits simply is not exported, and the rung was wrong-by-design in every shape that reached it. Re-measured on the same machine-day against the same 169/36 denominator: under-declared **911 -> 0**, orphan and alias-orphan **unchanged at 2 and 1**, asserted row-for-row (rung + name + manifest) rather than by count, with the pre-change count floored nonzero first. The repo's `typo-export` corpus expectation was deliberately INVERTED to pin the rung silent and RED-proven: against the pre-change code the flipped expectation fails, and it is the ONLY one of 119 corpus samples that moves. The shipped `ManifestConsistency` rationale also lost its "or an exported one is unlisted" clause, re-derived through `scripts/regen-rule-rationales.ps1` -- a removal has to reach the user-facing text or the plugin documents a check it does not run. Rung numbering keeps a deliberate GAP (rungs 1 and 3 retain the identities this document and the CHANGELOG already cite). No knob (still 19), no `base.psd1` change (still 53), no new owned finder (still 6), no CONTRACT change. Cut lockstep to 1.27.3 in both manifests over a dated `## [1.27.3] - 2026-07-29` heading -- the date EQUALS the publish day here, unlike v1.27.2's prepared-then-held shape. Tag v1.27.3 gitsign-signed and cut BY THE PIPELINE over commit **b1a673f** (tag object **46bc1aac**, tagger `github-actions[bot]`, tagger time 01:01:41Z), producing run **30504336296**. **The gate chain is demonstrably load-bearing on this cycle:** push-CI **30500633289** attempt 1 FAILED, a release dispatch **30502935547** was then REFUSED at Gate 4 on the red main, the failed leg was rerun green on attempt 2, and only then did a **dry run (30504277713, 00:58:15Z)** precede the producing run (00:59:27Z) -- the tag's 01:01:41Z tagger time proves the dry run minted no tag. Per the 2026-07-29 session record, both assets are covered by one SLSA provenance statement, `gh attestation verify`-clean at exit 0 and RED-probed against a tampered copy -- **that one line is carried from the release session record and was NOT re-verified**, unlike the v1.28.x rows above. *Relocated here by 000169 when the header advanced to v1.28.1, per the 000161 leg-2 convention: only the header facts this row lacked were folded in, each re-derived live rather than copied out of the superseded header text -- the tagged commit in full (`b1a673f36521c19c7521e38a3baa0a087d69323c`), the Release's `draft=false` / `prerelease=false` / author `github-actions[bot]`, and both asset names (`powershell-lsp-1.27.3.tar.gz` and `powershell-lsp-1.27.3.cdx.json`). v1.27.3 held the Latest badge from 2026-07-30T01:01:45Z until v1.28.0 published on 2026-07-31; it now reports `isLatest=false`, with tag and Release both retained. The full measurement record for the removal is in Section 6.* |
| v1.27.2 | 000159 legs 1a/1b/2; merged as PR #108; cut by the pipeline; verified by 000161 leg 1 | PATCH -- **RELEASED 2026-07-29**, and the first release in this arc whose verification was run as its own chartered leg rather than asserted at write time. **000159 leg 2 (PATCH)** teaches `ManifestConsistency` to read multi-name `Export-ModuleMember` lists in both idiomatic forms -- `-Function 'A', 'B'` (one `ArrayLiteralAst`) and `-Function @('A','B')` (one `ArrayExpressionAst`) -- which the export-name collector previously skipped whole; an empty collected set reads as "no explicit `Export-ModuleMember`" and answers export-all, so every private function was reported as an under-declared export. Measured on the plugin's own `scripts/lib/dogfood-reader.psm1`: **13 false warnings before, 0 after**, with the modelled surface matching `Import-Module` ground truth exactly. `-Cmdlet` was measured to share the collection path and is fixed with it; `-Alias` is deliberately NOT folded into the function set (the BurntToast shape, v1.24.x); a list carrying any non-literal element DEGRADES to silence rather than resolving the literal half. **000159 leg 1a (test-infra, no bump)** instruments the daemon-initializing flake: an outcome recorder wired into all 12 collapsing hooks, derived by AST with a vacuity floor, plus a rescue that copies each isolated data root's `logs/` inside the glob CI actually uploads. **000159 leg 1b (CI, no bump)** closes the 5.1 SARIF schema-validation gap at the artifact level. No knob (still 19), no `base.psd1` change (still 53), no new owned finder (still 6), no CONTRACT change. Cut lockstep to 1.27.2 in both manifests over a dated `## [1.27.2] - 2026-07-27` CHANGELOG heading (the heading carries 000159's authoring date, not the 07-29 publish date -- the expected shape for a prepared-then-held cut). Tag v1.27.2 gitsign-signed and cut BY THE PIPELINE over commit 49ce894 (tag object de60bd2, tagger `github-actions[bot]`, build signer `powershell-lsp-release.yml@refs/heads/main`, producing run **30468710698** read from the tag's own Sigstore certificate and corroborated by the attestation's `metadata.invocationId`); GitHub Release published 2026-07-29T16:03:29Z (verified-from-web), held the Latest badge until v1.27.3 published the following day and now reports `isLatest=false` (re-read by 000169), with both assets covered by ONE SLSA provenance statement naming both subjects and `gh attestation verify`-clean at exit 0, RED-proven to exit 1 on a single tampered byte. Push-CI **30465192375** headSha-matched to the tagged commit, all four legs green on attempt 2 |
| v1.27.1 | 000153 leg 3 (authored); classified and cut by 000154 | PATCH -- **RELEASED 2026-07-25**, a listing correction rather than code. The marketplace listing was corrected -- native nav is SHIPPED, not roadmap -- a one-clause fix to the embedded `description` in `marketplace.json`. No code, no knob, no contract, no capture-format change. That is the entire release, and it was cut precisely because a listing is what a prospective installer reads before becoming one. Tag v1.27.1 gitsign-signed and cut BY THE PIPELINE (tag object d6d2376 -> commit dff1cd4, tagger `github-actions[bot]`; dry run **30174870685** then producing run **30175779060**); GitHub Release published 2026-07-25T21:32:51Z (verified-from-web), no longer the current release (superseded by v1.27.2). Push-CI **30174864694** headSha-matched to dff1cd4 per rule 000081. *This row consolidates the v1.27.1 facts that used to live in this document's header, relocated here by 000161 leg 2 when the header advanced to v1.27.2 -- the values are the ones already verified-from-web at v1.27.1's own close-out, not re-derived here.* |
| v1.27.0 | 000142 legs 1-2 + 000143; cut by 000142 leg 5 | MINOR -- **RELEASED 2026-07-22.** Both manifests read 1.27.0 at the origin/main tip fddba38, which PR #99 merged. Classification is highest-wins over the live `[Unreleased]` entries: 000142 leg 1's MINOR governs a cut whose other two entries are PATCH. **000142 leg 1 (MINOR)** ships E2.2 org policy as the `orgPolicy` knob -- an absolute path to a central `PSScriptAnalyzerSettings.psd1` whose `ExcludeRules` are ENFORCED as a final subtractive drop at both `scripts/lsp-client.ps1` surface points, before the hook emit and the dogfood capture, so one rule covers the live surface, the capture, and the SARIF scan. Org wins the exclude path (no local include can re-enable a dropped rule); repo-local wins the include path (the policy's own `IncludeRules` stay advisory). Fails open with exactly one logged warning on a missing / unreadable / unparseable / relative path, and the policy is read through `Import-PowerShellDataFile` (restricted, data-only) so it can never execute code. Knobs **18 -> 19** with one `CONTRACT.md` FROZEN-KNOBS row proven RED-then-GREEN against the set-equality guard; no `base.psd1` change (still 53), no new owned finder (still 6), no status token. Off is byte-identical, proven over the shipped corpus records. **000142 leg 2 (PATCH)** is N1.1 idiom-guidance slice 2: hand-authored rationale overrides on the five PSES-15 default-surface rules whose derived text was circular or pure mechanism, each proven to already fire by the derived corpus snapshots; `override_count` **4 -> 9**, `-Check` green at pin 1.25.0. **000143 (PATCH, docs)** documents release Gate 5 and corrects the tag-command convention. Cut lockstep to 1.27.0 in both manifests + a dated `## [1.27.0] - 2026-07-22` CHANGELOG heading. Tag v1.27.0 gitsign-signed and cut BY THE PIPELINE over commit fddba38 (tagger `github-actions[bot]`, build signer `powershell-lsp-release.yml@refs/heads/main`, producing run **29962928958** read from the tag's own Sigstore certificate and corroborated by the attestation's `metadata.invocationId`); GitHub Release published 2026-07-22T22:30:18Z (verified-from-web), no longer badged -- `isLatest=false` (re-read by 000169) -- with both assets SLSA-attested and `gh attestation verify`-clean at exit 0 |
| v1.26.0 | 000139 / 000137 / 000136; cut by 000141 leg 1 | MINOR -- **the Wave-1 band**, RELEASED 2026-07-22. Classification is highest-wins over the live `[Unreleased]` entries, so 000139's MINOR governs a cut whose other two entries are PATCH. **000139 (MINOR)** adds the plugin-owned pre-PSSA finder `CommandLinePlaceholder` (`Find-CommandLinePlaceholder` in `scripts/lib/lsp-common.ps1`, wired at the `scripts/lsp-client.ps1` seam): a literal `<Name>` left on a command line is schema-valid to the eye but a redirection-operator parse error at run time. Detection is token-level -- the reserved `<` input-redirection operator immediately abutting a bareword ending in `>` -- and deliberately precision-first: legitimate output redirection (`>`, `>>`, `2>&1`), angle brackets inside strings / here-strings / comments, C#-style generics in strings, and the word operators `-lt` / `-gt` never fire. Re-entered under the S3.4 measure-first bar and shipped only at a measured **0% false-positive rate on a 281-file oracle** (150 repo scripts + 131 installed-module scripts, zero hits). Owned finders **5 -> 6** (verified-from-disk: `rule-rationales.psd1` `owned_count` = 6); no new knob (still 18), no `base.psd1` change (still 53), no CONTRACT change. **000137 (PATCH)** adds `docs/trust.md`, assembling in one evaluator-facing place the release-integrity chain that was already true but scattered (keyless gitsign-signed tag + SLSA provenance over both release assets, CycloneDX SBOM generated from the real pins, the pinned and SHA-256-verified PSScriptAnalyzer, the 0% corpus FP bar guarded on every CI run, measured latency, the SHA-pinned code-scanning workflow, the generated rule rationales), plus a README pointer. **000136 (PATCH)** adds `docs/CONTINUITY.md` (per-surface failure/recovery if the sole maintainer disappears) and `MAINTAINERS.md` (second-maintainer on-ramp), and reconciles the docs so the release runbook lives in exactly one place (`docs/RELEASING.md`). Cut lockstep to 1.26.0 in both manifests + a dated CHANGELOG heading. Tag v1.26.0 gitsign-signed and cut BY THE PIPELINE (tag object c26e580 -> commit 22bec89, tagger `github-actions[bot]`, build signer `powershell-lsp-release.yml@refs/heads/main`, run 29918156282); GitHub Release published 2026-07-22T12:06:42Z with both assets SLSA-attested and `gh attestation verify`-clean at exit 0, and superseded the same day (verified-from-web) -- tag and Release both retained, the badge passing to v1.27.0 that day and, six releases later, sitting on v1.28.1 (re-read by 000169) |
| v1.25.1 | 000131 / 000132 / 000133; cut by 000134 leg 1 | PATCH -- the scan-robustness lineage. 000131 NAMES the file(s) an INCOMPLETE (exit 4) code-scanning scan could not analyze (SARIF `toolExecutionNotification` + stderr + workflow annotation; per-file budgets left unchanged). 000132 fixes an INCOMPLETE-scan correctness gap (a client-cap-KILLED file was passing as clean; now recorded NOT analyzed via the 000024 never-silent branch) and its measurement corrects the true per-file budget a THIRD time -- to the daemon's OWN settle cap `MaxWaitMs` (default 5000 ms), not the client `timeoutMs`. 000133 raises the SCAN daemon's `MaxWaitMs` 5000 -> 15000 (scan-only; the in-agent daemon keeps 5000; INTERNAL, no knob, no CONTRACT change), and main's own code-scanning flipped RED -> GREEN at the #91 merge. All three self-describe PATCH; no knob, detection, ruleset, rationale, or CONTRACT surface moved. Cut lockstep to 1.25.1 in both manifests + a dated CHANGELOG heading. Tag v1.25.1 gitsign-signed (tag object f92ff79 -> commit c9692ca, tagged by `github-actions[bot]` from the release runner); GitHub Release published 2026-07-19T00:41:38Z (verified-from-web), no longer the current release (superseded by v1.26.0). Full narrative in "Scan-robustness lineage" below |
| v1.25.0 | 000128 (survey 000127 leg 1) | MINOR -- **reference surfacing**: a new off-by-default `userConfig` knob `referenceSurfacing`, the **18th** knob (verified-from-disk: `plugin.json` declares 18 `userConfig` keys), surfaces BARE per-function facts (referenced-by-N, exported, defined-in) from a session workspace index the daemon builds ONCE, as additive Information on the existing `additionalContext` channel -- no new diagnostic code, no status token, `rulesets/rule-rationales.psd1` byte-for-byte unchanged, and the diagnostics surface byte-identical when `off` (the default). It ships the design 000127 leg 1 surveyed-and-BLOCKED on a frozen-knob CONTRACT decision, so 000128 carried that amendment in lockstep (manifest + `CONTRACT.md` + `README.md`; the 000087/000101 knob precedent). The same release also lands the **`AliasesToExport` orphan check** on the always-on `ManifestConsistency` finder (PL-6 slice 2: a name in `AliasesToExport` with no matching alias definition) -- the symmetric completion of slice 1's export check. Tag v1.25.0 gitsign-signed; GitHub Release published 2026-07-17T18:06:13Z (verified-from-web), no longer the current release (superseded by v1.25.1) |
| v1.24.3 | 000126 (ranking 000125 leg 3) | PATCH -- **base-ruleset curation slice 2, and the slice that CLOSES curation**. `PSUseOutputTypeCorrectly` was the sole rule of the base-54 still firing on the 44-file known-good oracle (2 pedantic Information hits, 0 own-source hits, base-only -- not in the PSES-15 set), so excluding it via the existing named `$BaseRuleExclusions` list takes base **54 -> 53** and makes the ENTIRE opt-in `base` surface **0% measured false-positive** on that oracle. `pses-default` is byte-for-byte unchanged; `rulesets/base.psd1` REGENERATED through `scripts/regen-base-ruleset.ps1` (never hand-edited) and the rationale table regenerated to `pssa_count` 53 with all four 000125 overrides intact. With a 0% measured FP rate there is no evidence for a further exclude slice, so **base curation is COMPLETE** and 000126 deliberately recorded `next_suggested: null`. Tag v1.24.3 gitsign-signed; GitHub Release published 2026-07-17 (verified-from-web), no longer the current release (superseded by v1.25.0) |
| v1.24.2 | 000125 leg 1 (N1.1 slice 1) | PATCH -- **the rule-rationale OVERRIDE layer**: four idiom-family codes (`PSShouldProcess`, `PSUseSupportsShouldProcess`, `PSAvoidUsingWriteHost`, `PSAvoidShouldContinueWithoutForce`) now render hand-authored why+fix guidance instead of the weak text auto-derived from PSScriptAnalyzer's own CommonName + Description, which for idiom rules is circular (the "why" restates the rule name) or pure mechanism (it describes the checker, not the idiom, and offers no fix). The layer records each override's PRE-override `derived` text so a pin bump that changes the replaced text goes RED rather than being silently masked by the override -- drift-visible by construction. This is **N1.1 slice 1**: guidance quality on rules that already fire, not new detection. Tag v1.24.2 gitsign-signed; GitHub Release published (verified-from-web) |
| v1.24.1 | 000124 | PATCH -- **rule-rationale coverage CLOSED**: the plugin's fifth owned code, `ManifestConsistency`, gained its hand-authored rationale. v1.24.0 shipped the feature with a recorded gap -- four of five owned finders had an entry and `ManifestConsistency` rode the graceful-degrade path with none, surfacing its finding with no `why:` line. Hand-authored through `scripts/regen-rule-rationales.ps1` and the table regenerated (never hand-edited). The 000124 survey also corrected the N1.1 premise: no NEW-detection idiom slice clears a 0%-measured-FP bar, which is what re-scoped N1.1 to guidance quality and produced v1.24.2. Tag v1.24.1 gitsign-signed; GitHub Release published (verified-from-web) |
| v1.24.0 | 000121 (survey 000120 leg 2) | MINOR -- **rule-rationale strings** (feedback #9; horizon item I0.1). Every surfaced rule now carries a short static "why this rule matters" line on the EXISTING `additionalContext` channel, so a finding arrives with the reasoning attached, not just the verdict. The table `rulesets/rule-rationales.psd1` is HYBRID and GENERATED, never hand-edited: 58 entries = the 54 rationales for the `rulesets/base.psd1` PSScriptAnalyzer surface, auto-derived offline from the vendored pinned PSScriptAnalyzer 1.25.0 (`CommonName` + a whole-sentence `Description` prefix, 180-char budget, cut at a word boundary), plus 4 hand-authored entries for the plugin-owned finders PSScriptAnalyzer knows nothing about (`BashIsm`, `ModuleNotInstalled`, `NonAsciiChar`, `PS7OnlySyntax`). `scripts/regen-rule-rationales.ps1` writes it and its `-Check` drift guard re-derives and diffs it (exit 0 match / 1 drift), mirroring `regen-base-ruleset.ps1`; a pin-coupled unit guard goes RED unless a pin bump or a base-ruleset edit regenerates the table in the same reviewed diff. Rendering is deduplicated per RULE, not per finding -- a rule firing eight times in a file renders its rationale once -- bounding the added context to roughly (distinct rules in the file) x 180 chars. Two properties hold by construction: a clean file still emits NOTHING (byte-identical, integration-proven), and a rule with no entry degrades gracefully, surfaced with no rationale line, never fabricated. NO knob, NO `CONTRACT.md` change, NO new status token, and NO change to which rules run. Tag v1.24.0 gitsign-signed, provenance-attested; GitHub Release published 2026-07-09 (no longer current) |
| v1.23.1 | 000108 (survey 000107); 000110 (survey 000109); release-prep 000114 | PATCH (docs). Two documentation deliverables to installed users: (1) the Windows native-LSP launcher guard recorded as a known issue (docs/upstream/claude-code-lsp-registration.md + the README `nativeServe` section, scoped to Windows, upstream claude-code#73961); (2) every one of the 17 `userConfig` descriptions capped (<= ~200 chars each) for Claude Code config-panel height stability, with the full per-knob semantics relocated -- nothing deleted -- into a new docs/configuration.md, after 000109 found a long description could push the /plugin config panel past the viewport and trip a renderer ghost-row corruption. Behavior byte-for-byte unchanged: no knob key, type, value, default, `CONTRACT.md`, or product-code change. Tag v1.23.1 gitsign-signed; GitHub Release published 2026-07-04, no longer the current release (superseded by v1.24.0) |
| v1.23.0 | 000099; 000101 (survey 000100); 000103 (survey 000102); 000104 | MINOR (four features). 000099: format-on-edit `apply` activated -- `formatOnEdit=apply` becomes a guarded write-back (stale-write compare-and-swap, atomic-or-abort swap, BOM/EOL fidelity, no-change=no-write; a mixed-EOL / non-UTF-8 file aborts to a suggestion), the first feature that ever modifies the user's file; the default stays `off` and `off`/`suggest` are byte-for-byte unchanged. 000101: module awareness (`moduleAwareness` knob, default `off`) -- an Information-severity "command from an uninstalled module" hint from a shipped offline command->module index, design B (install-check-gated), silent on every ambiguity. 000103: the native-serve shim (`nativeServe` knob -- Section 1). 000104: the report-only `doctor.ps1 -ProbeNativeServe` removability probe, plus the v1.23.0 cut itself. Tag v1.23.0 gitsign-signed, provenance-attested |
| v1.22.0 | 000096; 000097 (release-prep 000098) | MINOR -- the AI-era rule pack, slices 2 and 3, which CLOSE the pack. Both are always-on additive pre-PSSA AST passes over the parser AST the pre-pass already produces (no knob, no status token, `CONTRACT.md` unchanged). 000096 `PS7OnlySyntax`: flags PowerShell-7-only syntax an AI drops into a file that may run on 5.1 (`&&`/`||`, ternary `? :`, `??`/`??=`/`?.`/`?[]`), suppressed when the file declares `#Requires -Version 7`. 000097 `BashIsm`: flags Unix command NAMES in a `.ps1` (`grep`, `sed`, `awk`, `export`, `which`, `touch`, `chmod`, `chown`, `ln`), suppressed by an explicit `& name` call or a same-file definition. With slice 3 the 000055 pack is CLOSED (slice 4 was already-covered; slice 5, angle-bracket placeholders, is deferred on irreducible false-positives). The measured 0% FP / 100% TP held on the widened corpus. Tag v1.22.0 gitsign-signed, provenance-attested |
| v1.21.1 | 000092 (survey 000091; release-prep 000093) | PATCH -- EXCLUDE-ONLY curation of the opt-in `base` ruleset, 57 -> 54 rules. The 000091 wave measured three default-on rules as net-noise over a 34-file known-good oracle (`PSReviewUnusedParameter` ~90% FP on the param-block + nested-function shape; `PSUseSingularNouns`; `PSUseShouldProcessForStateChangingFunctions`), all three BASE-ONLY (none in PSES's built-in 15-rule set), removed via a named `$BaseRuleExclusions` list so base.psd1 REGENERATES deterministically. `pses-default` is byte-for-byte unchanged; the three Error-severity security rules and `PSAvoidUsingWriteHost` are retained. The frozen CONTRACT surface (the `ruleset` knob) is untouched |
| v1.21.0 | 000087 | MINOR -- opt-in broadened live surface: a new `ruleset` enum knob (`pses-default` | `base`, default `pses-default`) selecting the fallback ruleset when no repo-local settings and no explicit settingsPath resolve. `base` resolves the plugin-owned, explicitly-enumerated rulesets/base.psd1 (default-on minus the compatibility-profile family, 57 rules at the pin), broadening the live surface to include `PSAvoidUsingWriteHost` and the three Error-severity security rules. An explicit settingsPath and a discovered repo-local settings file ALWAYS win. The default is deliberately NOT flipped. A DELIBERATE MINOR with a CONTRACT amendment |
| v1.20.0 | 000059 | MINOR -- off-by-default format-on-edit SUGGESTIONS: a `formatOnEdit` knob (`off` | `suggest`, default `off`). When `suggest`, each edit triggers a warm-daemon Invoke-Formatter round-trip (honoring the repo's own PSScriptAnalyzerSettings.psd1) and surfaces the result as a unified-diff SUGGESTION via additionalContext; the hook NEVER rewrites the file. `apply` was reserved here and treated as `off` -- later activated as the guarded write-back in v1.23.0. A DELIBERATE MINOR with a CONTRACT amendment |
| v1.19.0 | 000057 / 000060 / 000061 / 000062 | MINOR (four features) cut as one release. 000057: SARIF 2.1.0 + a standalone CI-mode scan over the same engine the hook uses. 000060: AI-era rule pack slice 1 -- the non-ASCII smuggling pre-PSSA byte pass (built the reusable pre-PSSA source category later slices 2/3 reuse). 000062: project-intelligence slice 1 -- deterministic .psd1 static manifest-consistency. 000061: closed-loop agentic correction slice 1 -- the warm daemon re-checks the touched range next turn and reports cleared/still-present, additive |
| v1.18.1 | 000075 (publish 000076) | PATCH -- native LSP registration restored (drop the two registrar-hostile fields + allowlist guard); registers-but-serve-gated UX documented. 000076 closed the publish gap and added the tree-vs-published divergence guard (now Gate 5) |
| v1.18.0 | 000064 | MINOR -- supply-chain signing: keyless gitsign-signed release tags (Sigstore via GitHub OIDC, Rekor-logged) + corrected trust posture (cosign judged redundant; Authenticode deliberately not pursued) |

One no-version-bump train landed between v1.23.1 and v1.24.0 and so has no row: **000120** (plugin PR
#81). Its build leg bounded the Pester bootstrap in `tests/run-tests.ps1` to the **5.x major** at all
three resolution points (the detection filter, `Install-Module`, and `Import-Module`, the latter two
carrying `-MaximumVersion 5.99.99`) and added a text-pin guard test, so the Pester 6.0.0 GA
(2026-07-07) cannot ride a runner-image change into the suite with nobody deciding to upgrade
(Section 6). Its docs leg refreshed `docs/upstream/claude-code-lsp-registration.md` to the
post-rewrite `#66987` record (Section 6). Its third leg was the rule-rationale SURVEY that specified
the v1.24.0 slice above -- it built nothing. Test-infra and docs only; no version moved.

A second no-version-bump train landed after v1.27.1 and likewise has no row: **000156**, which closed
the dot-source hazard as a class. `scripts/rule-efficacy-ledger.ps1` had been dot-sourcing
`scripts/review-dogfood.ps1` to reuse its readers, and because dot-sourcing a `.ps1` runs its
`param()` block in the CALLER's scope, that silently reset the ledger's own `-Path` / `-Source` /
`-AnnotationsPath` to review-dogfood's defaults; the ledger shipped a defensive
capture-the-arguments-first workaround to survive it. The 24 reader functions moved into
`scripts/lib/dogfood-reader.psm1` and both entry points now import that module by a
`$PSScriptRoot`-relative path, which removes the tree's only instance of the hazard.

**The module conversion was chosen on three pre-stated boundaries, each measured** rather than argued.
**B1 (encapsulation honesty) PASS:** exactly 1 shared-lib function is reached only by tests and never
by a shipped caller (`Get-ProjectIntelligenceFindings`); 14 are invoked directly by tests but not by
shipped callers. Keeping them green forces **zero** exports, because Pester 5.7.1 `InModuleScope`
reaches module-private functions -- established live, not assumed. **B2 (latency) PASS:** the hook
spawns a fresh `pwsh` per edit, and `Import-Module` costs **+20.9 ms** on pwsh 7 and **+9.6 ms** on
Windows PowerShell 5.1 against dot-source (medians of 15 fresh-process runs). The recorded warm-path
threshold is 9000 ms, so the added cost is **0.23%** of that budget; no shipped threshold is breached.
**B3 (resolution) PASS:** a `$PSScriptRoot`-relative `Import-Module` resolves under BOTH hosts from a
simulated marketplace-cache tree that is neither a checkout nor on `PSModulePath`, proven from a third
directory with no absolute path and no environment variable.

**The conversion is deliberately PARTIAL, and that is an evidence-based split, not an aesthetic one.**
The four pre-existing `scripts/lib/*.ps1` shared libraries stay dot-sourced. None of them carries a
`param()` block, so none violates the invariant; converting them would touch 76 dot-source sites
(59 for `lsp-common.ps1` alone) plus 15 `Mock` sites needing `-ModuleName`, against a suite whose
recorded wall-clock is 1012-2851 s per verification run. What the measurement did surface is a real
limit: of the 7 top-level statements those files carry, five are constants that convert mechanically,
but `$script:PluginVersionCache` and `$script:RuleRationaleCache` are MUTABLE lazy caches that a
functions-only file cannot express at all -- initialize them inside a function and StrictMode throws
on first read. That is the pure-lib contract meeting its own ceiling, and it is the concrete argument
for converting `lsp-common.ps1` to a module in a scoped follow-up.

**Two structural guards ship regardless of which option won** (`tests/PowerShellLsp.LibPurity.Tests.ps1`),
because they are what closes the class rather than the instance. **G1** parses every file a shipped
script dot-sources and refuses a top-level `param()` block or any top-level statement that is not a
function definition -- a bare `Set-StrictMode` or an `$ErrorActionPreference` assignment leaks into
the caller's scope exactly as a param block does. **G2** sets distinctly-named sentinels, dot-sources
each library the way callers actually load it, and asserts every sentinel survives byte-identical.
Both are RED-proven against `tests/fixtures/lib-purity/`, two files built for the purpose rather than
by corrupting a shipped file, and both are proven to PASS a pure library so neither is merely
always-red. The covered set is DERIVED from the tree, so a new shared library is covered automatically
and one converted to a module leaves the set automatically. The 7 legacy statements are recorded as an
exact, shrink-only baseline whose entries must keep matching on disk; a `param()` block is never
baseline-able. No source, knob, `CONTRACT.md`, ruleset, daemon-protocol, hook-wiring or
capture-format change; no version moved.

**A third no-version-bump train, 000157, has no row either -- and it did not land in a PR of its own.**
It was a fix-forward on 000156's *own branch*, by ADDING two commits (`8b65a0d8`, then `a2c84220`):
no rebase, no force-push, no amend, no squash, so all four of 000156's commits stayed reachable and
the push was a pure fast-forward `83685c6..a2c8422`, verified with `merge-base --is-ancestor` *before*
pushing rather than hoped for afterwards.

**What it fixed.** CI on the 000156 branch had failed on `windows-powershell` alone. Two assertions in
the G1 RED-proof read `($found | Where-Object { ... }).Count`, and under Windows PowerShell 5.1 a
pipeline yielding exactly one object **is** that object -- a scalar -- so `.Count` is `$null`; pwsh 7
wraps it and returns 1. The assertion was correct on every host but the one it ran against. Three
`.Count` sites were wrapped and proven RED-then-GREEN on the same host and the same Pester 5.7.1: base
`83685c63` gave **13 passed / 1 failed, exit 1**, and the fixed tree **14 passed / 0 failed, exit 0**.

**The third site's stated premise was FALSIFIED by measurement, and the site was wrapped anyway.** The
charter called it a latent defect that "breaks the moment a fixture yields one". It does not: `$found`
is assigned `@(Get-LpTopLevelImpurities ...)` on the line above, so it is already an array before
`.Count` is ever read. Measured on 5.1.26100.8875, `$a = @( (1) ); $a.Count` returns **1**, while a bare
parenthesised pipeline `.Count` throws `PropertyNotFoundStrict`; the sweep's independent dataflow pass
reached the same verdict from the other direction, classifying that site `SAFE-VariableProvablyArray`.
It was wrapped because the instruction was explicit and the change costs nothing, and it is recorded as
a zero-cost **defensive edit, not a repair**. The same measurement clears the adjacent identical-shape
line that was deliberately left untouched, so leaving it is not an instance-not-class lapse.

**The census, and the number that changed the design.** All **498** `.Count` property reads across the
tree's **146** PowerShell files (136 `.ps1` + 10 `.psm1`, enumerated and filtered by extension rather
than by a convention-shaped glob) were classified by PowerShell's own AST. The full table is in the
000157 outbox, and the finding is **not** the two sites that broke CI. It is that
**`(<command>).Count` cannot be flagged soundly**: of the 13 instances in the tree, 12 are genuine
traps -- a function's `return @(...)` is unrolled on the way out, so a one-element result arrives at the
caller as a scalar -- but `(Read-DogfoodAnnotations ...).Count` returns a **hashtable**, whose `.Count`
is a real property that reads 0 correctly. **One false positive in thirteen** (7.7%), against a repo
that holds a 0% standard.

**The scalar-`.Count` ratchet therefore shipped NARROWED on that measurement rather than on preference**
(`tests/PowerShellLsp.ScalarCount.Tests.ps1`). The charter and its own pre-authorized option both named
parenthesised pipelines **and** command invocations as the soundly-classifiable set; one counter-example
in the tree refuted that, so the guard flags parenthesised **pipelines** only, allowlisting
`(<pipeline> | Measure-Object).Count` because `Measure-Object` emits a single `GenericMeasureInfo` whose
`.Count` is real. What the guard deliberately does not attempt -- command invocations, `$var.Count`,
chained access -- is stated in its own header with the measured reason, so the next reader inherits the
evidence rather than the conclusion. **The baseline ships EMPTY, and that is a measurement rather than a
weakness:** after the wrap there are zero in-scope instances left, which is the strongest ratchet
position, not a weak one -- the class is fully closed today and any new instance fails immediately.
Widening the scope to manufacture baseline entries would have meant re-admitting the very shape whose
false-positive rate had just been measured. All three required behaviours were proven against the
**production repo-scan arm**, not merely the classifier, using purpose-built fixtures plus a
self-restoring probe file, so no shipped file was ever edited to watch a guard fire. Green on both
hosts, 10/10. No source, knob, `CONTRACT.md`, ruleset, daemon-protocol, hook-wiring or capture-format
change; no version moved.

**PR #106 is MERGED, and these facts were read live on 2026-07-27 rather than transcribed**
(`gh pr view 106 --json state,mergedAt,headRefOid,mergeCommit`): state **MERGED**, merged
**2026-07-26T03:49:08Z**, head **a2c84220** -- byte-identical to the SHA 000157 pushed, so nothing
rewrote the branch between push and merge -- into merge commit **ea3434db**, which is `origin/main`'s
second-newest commit (re-measured 2026-07-29: the PR #107 merge `4690cdb` has since landed on top of
it, and the header states the current tip).
CI is green **by name and on the matching head SHA**, per rule 000081: run **30186041265** on head
`a2c84220` completed *success* with all four legs green -- `ubuntu-pwsh`, `macos-pwsh`, `windows-pwsh`,
and `windows-powershell`, the leg that had been red. `sarif-upload` is **not** a fifth leg of that run:
it is the sole job of a separate workflow (`.github/workflows/powershell-lsp-code-scanning.yml`) that
does not fire on the pull-request event, and it ran green on the merge commit's own push, alongside a
second green four-leg CI run (runs **30186769853** and **30186769851**, both on `ea3434db`).

### 000197 and 000200 -- dispositions

One entry each, sourced by dispatch 000201 leg 2 from the outboxes in the strategic-dispatch hub and
cross-checked against the merged diffs on `origin/main`; 000197 runs to several paragraphs because
it carries six legs. Together they are the whole of PR **#130**, the no-version-bump train that
landed between the v1.29.0 true-up and this pass. The merge facts were read live rather than
transcribed, per rule 000081: `gh pr view 130` returns state **MERGED**, mergedAt
**2026-08-07T01:39:43Z**, head **41eaac6b0689ef73958d61941aafe5b7eb3d5e7b** and merge commit
**384e4fa1ffa64e82d8e0297300e02061c7346b49**, which is `origin/main`'s current tip. The whole arc is
`git diff --stat 9522e4d 384e4fa`: **8 files changed, 1329 insertions(+), 21 deletions(-)** --
`CHANGELOG.md` deliberately not among them, for the reason leg 4 of this pass derived and the close
of this section records.

**The held PR this arc opened is NOT the one that merged, and that is recorded rather than smoothed
over.** 000197's outbox names PR **#129** on branch `dispatch/000197-lege-recharter`; `gh pr view
129` returns state **CLOSED** with `mergeCommit` **null**, so it never merged. The work landed from
a re-cut branch, `dispatch/000197-lege-recharter-b`, as #130. Main carries the commits that bracket
the re-cut -- `e3b5111` "retrigger PR CI", `c1d9d26` "bisect: temporarily revert release.yml to main
to test CI triggering", `8684744` reverting that bisect, then `1307111` and `b1987a1` "retrigger
after Actions incident" -- so the branch change was a CI-triggering incident worked around in the
open, with the bisect probe reverted rather than left in the tree. **Two further dispatches sit in
this arc and are hub-side only, cross-referenced here by id alone because neither moved anything in
this repository: 000198** (the hub-only re-mint of 000195 legs G/H/I) **and 000199** (the hub
doc-set trim merge train).

**000197 -- the Leg-E re-charter. Legs 1, 2, 5 and 6 LANDED; legs 3 and 4 a NAMED BLOCK, the third
consecutive train to be stopped by the quiescence gate.** **Leg 1** hoisted the quiescence probe's
`$bootMap` assignment out of the branch that DEFAULTS `-AgentRootPid`. The ancestry-chain walk read
that variable on every path, so under the `Set-StrictMode -Version Latest` the probe sets for
itself, **both** documented explicit forms died on "The variable '$bootMap' cannot be retrieved
because it has not been set" before taking a single sample -- the instrument's documented interface
was unusable while its default path worked. The hoist is semantically neutral by construction rather
than by assertion: `Measure-QuiescenceSample` builds its own fresh parent map per sample, so
`$bootMap` never reaches scoring at all; it only picks the root pid and prints the auditable chain.
The class-closing regression test does not hand-list forms. It enumerates parameter names from the
probe's own `param()` block by AST **and** the `.PARAMETER` entries of its comment-based help,
requires the two sets to agree **in both directions**, requires every documented parameter to carry
a smoke-run value (a documented parameter with no value is a RED test, not a skip), and executes one
probe per documented parameter -- **7 distinct invocations**, asserted distinct so a value equal to
the base cannot collapse a form onto the default one. A separate assertion pins that the probe still
sets `Set-StrictMode -Version Latest`, without which the entire block would be vacuous, since an
unset variable would silently read `$null` and every execution assertion would pass against the very
defect it guards. Its RED control is **per-property**: against the pre-fix probe the two
fix-sensitive tests fail while the four precondition/floor tests correctly stay green (4 passed, 2
failed). The class-closer then proved itself immediately -- adding `-BusyProbeCommand` in leg 2
turned it RED until that new parameter was given a smoke-run value. **One deviation is recorded
rather than smoothed over:** the charter said to enumerate the probe's documented parameter SETS
with a floor of `>= 2`, but the probe declares no PowerShell parameter sets at all -- every
parameter sits in `__AllParameterSets` -- so a literal reading enumerates exactly 1 and the floor
could never be met. Documented parameter FORMS were enumerated instead, which closes the same class
non-vacuously and satisfies a real floor.

**Leg 2** put the quiet pre-flight in the INSTRUMENT rather than in the charter that drives it, as a
new optional `-BusyProbeCommand`. The contract: **quiet** is exit 0 *and* no output; **busy** is a
non-zero exit code OR any output. On busy the probe refuses with exit **3**, names the refusal, and
takes no samples; either way the command and its raw output are recorded beside the samples, and
absent the parameter the behaviour is what it was. Two findings are worth keeping, both caught by
the tests rather than by review. **The busy probe must run in a CHILD process:** the first
implementation invoked it in-process via `[scriptblock]::Create`, and the unit test "BUSY by EXIT
CODE alone" supplied `exit 7`, whereupon the probe exited **7** instead of 3 -- an in-process `exit`
terminates the probe and makes it report the busy check's exit code as its own verdict. The command
is now parse-validated in-process, so an unrunnable command is refused without spawning anything,
and executed in a child. **And the guard is fail-closed:** a pre-flight that cannot run counts as
BUSY, because a guard that silently permits sampling when it breaks is worse than no guard -- the
report then claims a check that never happened. Hub-agnosticism is asserted rather than trusted: a
scan over every `.ps1` in `tests/bench/` with the comment-help block and comment lines stripped
requires **zero** dispatch-CLI invocations, hub repo names or local paths in executable code, and it
was **mutant-RED-proven** by injecting a real `dispatch claims --live` call and confirming exactly
one anchor selected. The needle deliberately requires a subcommand word so the repo's many
legitimate `dispatch = '000127'` provenance fields are not false positives, and a companion test
asserts the hub example IS present in comment-help, so "zero references" cannot be satisfied by
never documenting the local usage.

**Leg 3 ran Gate A v2 exactly as pre-committed and it FAILED, so leg 4 was never attempted.** The
protocol was byte-identical to the pre-commitment -- 30 samples at 1000 ms, threshold 0.15 cores
strictly under, agent tree and probe tree excluded and re-resolved per sample -- and the verdict was
a foreign mean of **0.2219 cores** against that 0.15 bar, foreign max **2.6971**, with the agent's
own **0.3403 cores** held out of the figures and 57 agent pids excluded per sample. **This is a
different FAIL from 000170's and 000171's, and the difference is the whole point:** those failed
partly on their own apparatus, whereas here the exclusion is demonstrably correct and the load is
real foreign desktop software -- chrome 0.8477, AMDRSServ 0.6165, ms-teams 0.3082, explorer 0.2620
and LogiOverlay 0.1695 cores in the final-sample table. Samples 1-22 were largely quiet and the
spike over 23-30 carried the mean over the bar. The instrument is finally measuring what it claims
to measure; what it measured is a workstation running Chrome, Teams and the AMD Radeon service. **No
relaxation was applied or considered.** Leg 4 was pre-ruled blocked on exactly this outcome, so
`docs/benchmarks.md` is untouched, no findings fixture was authored, and the analyzer-clean
`bench-fixture.ps1` was never opened -- publishing a millisecond figure measured under 0.2219 cores
of foreign load is precisely what the gate exists to prevent. A custom_check asserted both forbidden
paths absent from the diff, floored on the total changed-file count so an empty or wrong ref could
not fake the assertion.

**Leg 5 upgraded this document's `userConfig` enum sentence from OBSERVATION to EXPLANATION.** The
v1.28.1 row had recorded that no knob in the manifest declares a `values` or enum field; leg 5
established that none **CAN**. Re-derived at write time from the installed binary -- and the
re-derivation was substantive rather than ceremonial, because Claude Code had moved to **2.1.223**
where 000195 leg F read **2.1.221**, with two `.describe()` strings differing between the builds and
the load-bearing shape identical. The shipped `userConfig` option schema is `.strict()` over exactly
**nine** top-level keys (`type`, `title`, `description`, `required`, `default`, `multiple`,
`sensitive`, `min`, `max`) with `type` a closed five-primitive enum and the anchor **unique** in the
binary, so a `values` field is REJECTED rather than merely absent. The ledger diff was exactly
**two hunks** -- the Section 9 front-door paragraph and the v1.28.1 row -- with no header re-truing
and no other content moved. It also authored `docs/upstream/claude-code-userconfig-enum.md` as a
POST-READY DRAFT naming two concrete asks (an optional `values` field on `string`, or a sixth `enum`
type) with a compatibility note that `.strict()` makes the field a hard error on older clients. Its
header states plainly that filing is Mike Andersen's gate; **nothing was posted.**

**Leg 6 made the dry-run pair STRUCTURAL, closing the gap v1.29.0 had proved by shipping with no
rehearsal at all.** The discriminability problem was solved at the run object rather than in its
logs: `dry_run` is an input and inputs do not appear on a run, which is why 000161 and 000169 could
only recover it by step forensics, so the workflow's `run-name` now encodes it and every run carries
`[DRY-RUN]` or `[PRODUCING]` and `target=<commit-or-HEAD>` in its own name. **Gate 6** runs only
when `!inputs.dry_run` and refuses unless a SUCCESSFUL `dry_run=true` run exists for the **same
resolved target commit** within **3 days** -- the window bounding drift in the external state a
rehearsal validated but the commit does not pin (Gate 5 reads `origin/main`'s published manifest,
Gate 4 reads CI runs), with commit identity the primary guard and the window explicitly not the main
protection. `skip_dry_check` (boolean, default false) is the recorded bypass: when true the gate
logs `SKIPPED-BY-INPUT` as both a workflow warning and a banner, and passes -- so skipping the
rehearsal is a run parameter visible forever rather than an undetectable omission. The decision
logic was factored into `release/Test-DryRunPair.ps1` and unit-tested with **14** tests covering
every refuse path, then retroactively validated against real release history rather than fixtures:
the v1.28.1 producing run PASSES (through the pre-marker legacy fallback, since those runs carry the
bare title `powershell-lsp release`) and the v1.29.0 producing run is REFUSED. That second result
also CONFIRMED from GitHub, rather than inherited from the charter, that v1.29.0 shipped with no dry
run. **The live proof is PENDING BY CONSTRUCTION and is stated exactly that way:** Gate 6 has never
executed on a GitHub runner and first will on the next real cut; this train triggered no release
workflow run at all, asserted by a custom_check. **A second deviation is recorded here too:** leg 6
also edited the workflow's own header comment, which the charter did not name, because that
enumeration read "(1)..(4)" and had ALREADY drifted -- Gate 5 shipped with dispatch 000076 without
extending it, so the file described four gates while running five. A test now anchors the prose
enumeration to the actual gate steps and fails if they diverge. **No version bump** (the 000159 leg
1b shape: CI plus docs). Verification: `tests/PowerShellLsp.Release.Tests.ps1` in full at **64
passed, 0 failed**, including all 40 pre-existing tests, and the `D4`/`E1`/`E2` benchmark blocks at
**21 passed, 0 failed**, both filtered runs carrying an executed-count floor so a zero-selection run
exits 3 rather than reporting success. The full ~1029-test suite was deliberately NOT run locally --
the host was under the load leg 3 had just measured -- and was left to CI on all four legs.

**000200 -- fix-forward on PR #130. The eleven `windows-powershell` failures were TWO independent
5.1 divergences, not one; both fixed at their own layers, and the arithmetic closes exactly.** The
reproduction came first and came through the repo's OWN entry point, which is what made it faithful:
`tests/run-tests.ps1` under `5.1.26100.8875` with Pester 5.7.1 reproduced **3 passed / 11 failed**,
an exact match for the CI job. **Divergence A (10 of the 11) is that Windows PowerShell 5.1's
`ConvertFrom-Json` does not enumerate a top-level JSON array.** At `release/Test-DryRunPair.ps1:125`
the idiom was `$runs = @(ConvertFrom-Json $rawJson)`; instrumented side by side on the same input,
`@(ConvertFrom-Json '[{a},{b}]')` gives Count **1** on 5.1 against 2 on pwsh 7.6.3, and the type of
element `[0]` is **`System.Object[]`** rather than `PSCustomObject`. 5.1 writes the deserialized
array to the pipeline as ONE item, so `@(...)` wraps the whole run list in a 1-element array; every
downstream lookup then runs against an `Object[]`, and because the accessor guards with
`PSObject.Properties.Name -contains`, the missing `id` and `conclusion` came back `$null` instead of
throwing -- which is exactly why the defect presented as *empty strings* rather than an error, and
why every single fixture emitted the same `conclusion= (a failed rehearsal is not a rehearsal)`.
That also explains the two cases that "passed": both passed **vacuously**, one asserting the very
message the bug emits for everything and the other asserting only exit code 1. The fix is assign
first, wrap second, guard `$null` -- and the guard is load-bearing on **7**, not on 5.1, because
there `'[]'` yields nothing and `@($null)` would manufacture one phantom run; verified for N = 0, 1,
2, 3 on both hosts. **Divergence B (the 11th) has nothing to do with JSON ingestion:** the case
"SAFE-FAILS on an empty or missing runs file" exercises two `throw`s whose text arrives on stderr
and is captured with `2>&1`, and under the `$ErrorActionPreference = 'Stop'` that
`tests/run-tests.ps1` sets, 5.1 promotes that redirected native stderr line to a **terminating**
error where pwsh 7 does not. It was fixed at the TEST layer with a save/neutralize/restore of EAP in
a `try/finally`, matching the idiom `tests/PowerShellLsp.SarifScan.Tests.ps1:673-676` already
documented and applied -- so leg 6's new test had simply not inherited it. **The strongest single
piece of evidence is the arithmetic, and it is recorded as a count rather than a conclusion:** the
`windows-powershell` leg went **1676 passed / 11 failed / 3 skipped** (run 31131137394) to **1687
passed / 0 failed / 3 skipped** (run 31134173407), and `1676 + 11 = 1687` -- precisely the eleven
originally-failing cases flipped to green with the passed count moving by exactly that amount, so
nothing else in the suite was silently skipped, renamed or disturbed. All four legs are green on
that run, headSha-matched to `41eaac6b0689ef73958d61941aafe5b7eb3d5e7b` per rule 000081, and a
separate check confirmed all 30 `Should` assertions in the target Describe are byte-identical before
and after, so the green was earned by the fix rather than by weakening the test. **Three deviations
are recorded.** The inbox chartered ONE defect and STEP 3 anticipated one mechanism; two were found,
with different mechanisms and different correct layers, and fixing only the named signature would
have left CI red. The inbox stated the Describe holds 13 cases (11 failing, 2 passing) and it holds
**14** (11 failing, 3 passing) -- the third passer being "is ASCII-only", which byte-scans the file
and never exercises the decision path, so it could not have failed; recorded because the count feeds
the assertions-unchanged claim, which is therefore asserted over all 30 `Should` lines rather than
over a case count. And the scan for the same `ConvertFrom-Json` trap elsewhere in `release/`,
`scripts/` and `tests/` found nothing affected and **fixed nothing** -- `audit-release-bodies.ps1`
and the JSONL readers either parse one object per line or have an intervening pipeline stage that
enumerates -- recorded so the negative result is not re-derived next train. **The residual this
dispatch flagged is the reason leg 3 of dispatch 000201 exists:** `Test-DryRunPair.ps1` was
defective under 5.1 in the SHIPPED gate and not merely under test, since fed a real `gh run list
--json` array it would have rejected every genuine rehearsal. It survived only because the
production gate step happens to run the script under `pwsh`. Of its two rule candidates, the
stderr-promotion one is the confirmed **second** observation and the one that earned promotion; the
`ConvertFrom-Json` one is a **first** observation in this repository, derived rather than assumed by
the scan that found no other affected call site.

**Leg 4 of dispatch 000201 changed `CHANGELOG.md` NOTHING, and the convention is DERIVED rather than
assumed.** Two hypotheses were tested against this repository's own git history. The first --
that `[Unreleased]` is authored at release-prep time by `scripts/bump-version.ps1` -- is FALSIFIED:
the string "changelog" appears nowhere in that script, whose only write targets are
`.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`. The second -- that
`[Unreleased]` is populated per-merge and re-headed at the cut -- is CONFIRMED: at commit `d9e8889`
(000153 legs 3+5) it carries a full PATCH entry ending "both manifests stay lockstep at 1.27.0 and a
future cut classifies this entry", and at `06fec64` (000154, the very next commit to touch the file)
that same entry sits under `## [1.27.1] - 2026-07-25` with `[Unreleased]` emptied; two merge commits
`4f17c43` and `82cee3b` are named "stack CHANGELOG Unreleased entries" outright. **But the per-merge
rule is scoped by what the file says it records** -- `CHANGELOG.md` line 3: "All notable changes to
the `powershell-lsp` plugin are documented here" -- and every no-version-bump train in this
document's own record wrote NO entry: `git log --all -- CHANGELOG.md` returns no commit from 000120,
000156, 000157 or 000159 legs 1a/1b. (The one commit whose message names 000157, `4690cdb`, is
000158 correcting the already-released `[1.27.1]` clause at 3 insertions / 3 deletions, not an
`[Unreleased]` entry.) The 000197/000200 arc is exactly that shape -- a release workflow, release
tooling, repository docs and tests, with no plugin behaviour among its 8 files, and 000197's own
outbox classifying it "No version bump (000159 leg 1b: CI + docs)" -- so an entry would have been
the departure from the convention, not the observance of it. `[Unreleased]` is therefore empty at
`origin/main` on purpose, and this paragraph is the record that the question was asked and answered
rather than skipped.

### 000169 through 000174 -- dispositions

One paragraph each, sourced from the outboxes in the strategic-dispatch hub by dispatch 000195 leg A.
Together they are the whole of the v1.29.0 cycle plus the ledger true-up that preceded it.

**000169 -- docs-only decision-ledger true-up. CLOSED.** It advanced this document's header to the
then-live Latest (v1.28.1) and added the missing v1.28.0 and v1.28.1 rows to the Section 2 table,
measuring both releases directly rather than the Latest alone -- tag objects, taggers, manifest
versions, knob counts and order, Release metadata, `isLatest` across the top six, headSha-matched
push-CI, the full step list separating each dry run from its producing run, and `gh attestation
verify` on all four assets RED-probed against a tampered copy. It is the direct predecessor of THIS
pass, and it established the shape this one repeats: a scheduled true-up, not a repair.

**000170 -- round-3 evidence train. Leg 1 BLOCKED; legs 2-5 delivered (PR #118 HELD).** Leg 1 was to
publish per-profile telemetry numbers and did not: the host would not hold quiescence, so NO numbers
were published rather than numbers published without their gate evidence. That refusal is the
precedent the Gate A v2 protocol was written from. Legs 2-5 landed regardless -- the Arc A gap
RED-proven, the union-read denominator finding raised, the vendor-corpus ask found EMPTY rather than
blocked, and Section 9 appended.

**000171 -- round-3 build train. Leg 1 BLOCKED AGAIN; legs 2-5 all DELIVERED (PR #119).** The
quiescence gate failed a second time, at **3 of 5 pre-committed gate points**, and again no numbers
were published. Everything else shipped: per-rule lifecycle persistence landed in a SIBLING log with
the capture format proven byte-unchanged, four corpus shapes were authored and scoring, the
union-denominator question was decided with its cost and its measured limit stated, and a MINOR
`[Unreleased]` entry was written. It also raised two Section 9 corrections and a two-defect pattern
in the benchmark suite. This is the build that v1.29.0 released.

**000172 -- fix-forward on PR #119. Nine legs delivered; the four-green criterion a NAMED BLOCK.**
Both chartered CI blockers were cleared and all four banked defects closed, with the original
failure reproduced first in every case. It stopped short of its own acceptance honestly:
`windows-powershell` stayed red on a THIRD, pre-existing unsound timing assertion the train was
forbidden to touch, measured at 3-in-10 on 5.1 and 1-in-10 on pwsh **with no plugin code in the
path**. Two premises were corrected BY MEASUREMENT rather than argued -- the DSC split is by
PLATFORM, not by host, and the pre-authorized D1 null-sentinel fork was REFUTED.

**000173 -- fix-forward #2 on PR #119. The cross-clock assertion repaired at the right layer.** It
settled from the documents that no internal-consistency guarantee exists and that the record is a
TEST-HARNESS construct with zero product consumers, so the defect was in the test rather than in the
product, and it was fixed there. It corrected the story going in: the sub-cap rate is a property of
the WAIT SHAPE, not of the host, at 16.7% on BOTH hosts -- so the pwsh legs had been passing on luck.
Its leg 5 corrected its OWN inbox: a one-sided cross-clock bound is not unsound at any width, and the
discriminator is MARGIN, not shape.

**000174 -- release prep for v1.29.0 (MINOR), and a corrected ritual. CLOSED; released.** The cut
landed in ONE commit -- CHANGELOG first, lockstep bump second -- so the 000168 window has no commit
to bisect into, and the `[Unreleased]` body moved byte-identical (2 insertions, 0 deletions, same
SHA-256, same 9907 bytes). Its leg 1 CORRECTED ITS OWN INBOX on the release ritual itself: the inbox
instructed a hand-cut tag in three places and `docs/RELEASING.md` forbids exactly that, so following
the instruction would have made Gate 2 refuse the run AND produced an unsigned, unattested tag. The
shipped artifacts settled it -- 21 of 22 annotated tags are cut by `github-actions[bot]` and gitsign.
The pipeline cut v1.29.0 from PR #120 the same day.

### 000159 -- legs 1a / 1b / 2 RELEASED in v1.27.2; leg 3 a recorded NO-BUILD

**A fourth train now has its own row above.** 000159 prepared **v1.27.2**, PR #108 merged
2026-07-29T15:18:09Z as merge commit **49ce894**, and the pipeline cut and published the release the
same afternoon. Read every claim in this block as *shipped*, and see the header for the five-read
verification.

| Leg | Outcome | Bump |
|---|---|---|
| 1a flake instrumentation | RELEASED in v1.27.2, steps 1-2 only | none (test-infra) |
| 1b 5.1 SARIF validation gap | RELEASED in v1.27.2, closed at the artifact level | none (CI) |
| 2 multi-name export lists | RELEASED in v1.27.2 | PATCH |
| 3 scalar-`.Count` finder | **NO-BUILD** at 7.14% measured FP | none |

**Leg 3 is the load-bearing outcome, and it is a no-build proven by absence in the 000127 shape.**
The charter demanded the oracle measurement BEFORE any finder was built, and demanded the live count
rather than the remembered one. **The live oracle is 325 files** -- 153 repo `.ps1`/`.psm1` plus 172
installed-module scripts across 6 `PSModulePath` roots -- **not the 281** (150 + 131) the charter
carried forward. No attempt was made to reconcile the two and none should be: the installed-module
set is machine state, so 281 and 325 are two different machine-days rather than a number and its
correction, which is why the rows above that cite a 281-file oracle (000139, and S3.4) stand as
written. Impact on the fork: none -- a wider oracle can only surface more counter-examples, and it
surfaced one. The classifier -- the 000157 guard's logic verbatim -- returned **28 hits**, and
hand-triage put the measured false-positive rate at **7.14% MINIMUM (2 of 28)** against a **0%**
bar, so the pre-adjudicated fork resolved to NO-BUILD: no finder, no CHANGELOG entry, no second PR,
and owned finders stay at **6**.

The two failing hits are Pester's `($help | & $SafeCommands['Measure-Object']).Count`, and the
failure is structural rather than a tuning miss. The allowlist keys on
`CommandAst.GetCommandName()`, which returns **`$null`** for a dynamic invocation `& $expr`, so it
cannot see a `Measure-Object` that is genuinely there; the identical DIRECT call resolves
`GetCommandName()` to `Measure-Object` and is correctly silent. Measured under Windows PowerShell
5.1.26100.8875 with StrictMode Latest, the expression returns **3** for a three-element input and
**1** for a single-element input and **never throws** -- a real `GenericMeasureInfo` count -- so
flagging it is simply wrong. The number was NOT rescued: allowlisting the dynamic form, or dropping
the 22 `Get-Member` membership probes whose exclusion would move the rate to 85.71%, would each have
produced a passing measurement and a finder nobody agreed to. The lower and less flattering rate is
the one reported, because the fork is decided by the 2 unambiguous hits alone.

**This is the third static check in this repo the same idiom has defeated** -- it beat the alias
check in 000127 leg 4, it is named in 000159 leg 2's own degrade language, and it has now killed
this finder's allowlist. That recurrence, rather than the no-build, is the finding worth carrying
forward, and the full 28-hit evidence table lives in the 000159 outbox so the next charter starts
from data instead of from this dispatch's conclusion.

**What the three built legs staged.** Leg 1a instruments the daemon-initializing flake: an outcome
recorder wired into all 12 hooks that collapse distinct failures into one empty string, derived by
AST rather than hand-listed and carrying a vacuity floor that asserts the derived set is non-empty,
plus a rescue that copies each isolated data root's `logs/` inside the glob CI actually uploads --
proven by running the real thing with the env var CI sets, not by reading the YAML. Leg 1b closes
the 5.1 SARIF gap at the artifact level: Windows PowerShell 5.1 emits its SARIF, pwsh 7.6.3
validates those artifacts against the vendored 2.1.0 schema, and `-RequireHost 5` is the point
rather than a nicety, since a leg that silently emitted nothing would otherwise validate zero files
and report success. RED-proven four ways, each exit 1. Leg 2 teaches `ManifestConsistency` to read
multi-name `Export-ModuleMember` lists: `-Cmdlet` was measured to share the collection path and is
fixed with it, `-Alias` was measured NOT to, and mixed literal/variable lists now DEGRADE rather
than half-resolving -- pre-fix they silently assumed export-all, and a partial set reading as
complete is the worse defect.

**Three of the four commits were ADOPTED from a session that died, and every recorded proof was
RE-RUN rather than trusted** (Hub Rule 7): `c5ee43dc` (leg 1a), `2068b2b2` (leg 1b) and `4dd979ae`
(leg 2), with `8aa812e4` the release prep authored in-session. All proofs reproduced exactly. The
re-run also resolved the handover's one unknown -- an unexplained detached worktree turned out to be
the pinned pre-fix baseline the leg 2 RED proof required, after which it was removed rather than
left as stray state.

**The accepted deviation rides with the cut, and it is large.** Mike Andersen ruled mid-session that
the 0%-FP bar is scoped to the CHARTERED class, and that ruling's premise was checked rather than
assumed: **0 of the 910** `ManifestConsistency` hits remaining on the live oracle after the fix are
attributable to a multi-name export list. But of those same 910, **909 are confirmed false positives
with 0 true positives**, all belonging to a SECOND class -- `FunctionsToExport` -- that this train
did not fix and that Section 6 now carries as a standing item. That limitation is stated in the
1.27.2 CHANGELOG entry itself rather than only here, because `docs/RELEASING.md` says the entry
becomes the release notes verbatim and a reader deserves to know the check is not yet trustworthy on
their own tree.

### Wave-1 merge outcomes (000136 / 000137 / 000139) plus the 000141 cut -- the whole cycle on main

The three Wave-1 dispatches merged to main in dependency order on 2026-07-21, and the 000141 cut
train merged behind them on 2026-07-22 (all verified-from-web via `gh pr list --state merged`):

| PR | Dispatch | Merge commit | Merged (UTC) |
|---|---|---|---|
| #93 | 000136 continuity + governance docs | `fbb857c` | 2026-07-21T13:30:47Z |
| #94 | 000137 docs/trust.md | `303c714` | 2026-07-21T14:02:30Z |
| #95 | 000139 CommandLinePlaceholder finder (MINOR) | `771866c` | 2026-07-21T15:34:55Z |
| #97 | 000141 v1.26.0 lockstep cut + roadmap true-up | `22bec89` | 2026-07-22T01:15:10Z |

`22bec89` is the current origin/main tip AND the commit the v1.26.0 tag points at, so `git describe
--tags origin/main` returns a bare `v1.26.0` with no commit offset (verified-from-web). Both push
workflows are GREEN on that exact tip, headSha-matched per rule 000081: CI run **29882589709** and
code-scanning run **29882589757**. No plugin PR is open (verified-from-web).

**PR #95 carried two post-completion test-fix commits for a real Windows PowerShell 5.1 divergence**
(`f0d604c`, `1982f32`). On PS 5.1 a scalar `PSCustomObject` and `$null` both return `$null` from
`.Count` -- the member does not exist on a scalar and strict mode does not save you -- so a counted
expression must be wrapped in `@()` before `.Count` is read. The `windows-powershell` CI leg failed
twice on this, at `4f17c43` (run 29837521908) and again at `f0d604c` (run 29840467411), with the
signature `Expected 1, but got $null.` **Only the test assertions were affected: the finder itself
detects correctly on 5.1**, which is why the fix is confined to `tests/PowerShellLsp.Unit.Tests.ps1`
(9 assertions wrapped, product code untouched). This is recorded as a rule observation in the 000141
outbox -- the two independent CI failures are its second observation.

### Scan-robustness lineage (000129-000133) -- the blocked pair, the budget chain, the flip

The persistent ubuntu-24.04 code-scanning RED on main -- an INCOMPLETE scan (exit 4), the 000024
never-silent discipline firing CORRECTLY, not a findings-induced false red -- drove a
five-dispatch lineage. It is recorded here because two of its dispatches are BLOCKED (no CHANGELOG
row of their own) and the rest shipped as v1.25.1, and because the budget it chased was
mis-identified twice before the tree settled it.

- **The refuted-premise blocked pair (000129, 000130) -- the SPEC_AMENDMENTS-A3 precedent.** Both
  were fix-forward dispatches premised on an "overloaded exit 4" that does not exist on the tree,
  and both ended `blocked` + `deviations`, never `blocked -> complete` (A3: no partial state;
  refuted work is recorded as blocked plus its deviations). **000129 (CC stop-and-record;
  verified-from-disk):** a whole-file enumeration found all six `exit` sites; BOTH `exit 4` sites
  mean INCOMPLETE and the `-FailOn` gate is `exit 2` via `Get-FailExitCode` (returns only 0 or 2)
  -- there is no second meaning on 4 to split, so the prescribed disambiguation would invent a
  distinction and leave the RED untouched. **000130 (a re-issue, refuted a SECOND way, then a human
  ruling):** its new premise -- that `CONTRACT.md` freezes an exit-code table E2.1 violated -- is
  also false; that file freezes only `userConfig` knob NAMES and the diagnostics status taxonomy (a
  grep over it for exit / sarif / code-scanning / 0-2-3-4 returns ZERO hits), so there is nothing to
  amend, and adding an exit 5 would have to move exit 2 (the inbox's own named stop). Mike Andersen
  ruled interactively (2026-07-17): block and charter, do not touch any exit-code surface -- which
  chartered 000131 for the real fix.
- **The three-budget correction chain -- a disk-governs case study.** What binds a per-file
  analysis was mis-named twice before the tree settled it. 000129 / 000130 / 000131 and 000132's
  own charter all named a CLIENT budget: first the **25000 ms** process cap (`lsp-scan.ps1
  -TimeoutMs`), then the **18000 ms** client `timeoutMs`. 000132's measurement corrected it a THIRD
  time to the actual binding cap -- the daemon's OWN settle cap **`MaxWaitMs` (default 5000 ms)** in
  `scripts/pses-daemon.ps1`, which no client budget reaches -- so raising a client budget could
  never have turned the RED green. Each step overrode the prior on evidence read from the live tree,
  not from the charter: disk governs.
- **The fix and the flip (000131 -> 000132 -> 000133; verified-from-web).** 000131 made the
  INCOMPLETE diagnosable by NAMING the unanalyzable file(s) across three surfaces, budgets
  untouched. 000132 fixed the correctness gap (a client-cap-KILLED file had passed as clean; now
  recorded NOT analyzed) and identified `MaxWaitMs` as the true cap. 000133 raised the SCAN daemon's
  `MaxWaitMs` 5000 -> 15000 (scan-only; the in-agent daemon byte-identical at 5000; INTERNAL, no
  knob, no CONTRACT change). main's own code-scanning workflow
  (`.github/workflows/powershell-lsp-code-scanning.yml`, the 000127 leg-5 upload,
  inert-until-merged by construction) then flipped RED -> GREEN at the #91 merge -- headSha matched
  per rule 000081: run **29643752601** RED at `aeeb42d` (#89), run **29657184770** RED at `73dacdb`
  (#90), run **29661464779** completed/**success** at `85fb892` (#91, the origin/main tip). The
  settle-cap fix holds on main itself, not just on a branch. These three PATCH entries shipped as
  **v1.25.1**, released 2026-07-19 (Section 2).

### The 000141 cut train -- MERGED and RELEASED; disposition closed

**Disposition resolved (verified-from-web this session):** the 000141 train merged as plugin PR
**#97** (merge commit `22bec89`, 2026-07-22T01:15:10Z), Mike then ran the release pipeline, and
v1.26.0 became the Latest Release -- a badge it has long since handed on, and which 000169 re-read
as sitting on v1.28.1. At write time that train held every gate open; all of them
have since been taken, in the correct order and by the correct actor. The record of the train as it
ran: Leg 1, the v1.26.0 MINOR cut (both manifests + the dated CHANGELOG heading;
`PowerShellLsp.Release.Tests.ps1` 39/39 green on the cut tree, the version lockstep RED-proven
in-session by mutation, then restored). Leg 2: the roadmap refresh this section sat in. Leg 3: a
read-only community-catalog poll (boolean + timestamp recorded in the outbox). Leg 4: a fresh PK
bundle. No product code moved; no knob, ruleset, rationale, exit-code, budget, or CONTRACT surface
changed.

The classification was version-agnostic by construction: it reads the current version off disk,
scans the live `[Unreleased]` entry lines for their leading PATCH/MINOR/MAJOR token, and takes the
highest. Wave 1 stacked MINOR (000139) over PATCH (000137) over PATCH (000136), so the cut was
`1.25.1 -> 1.26.0`. Had `[Unreleased]` been empty the leg would have asserted the NO-BUMP invariant
instead (the 000127 leg-8 shape) -- never a bump by default.

**One process deviation is recorded here rather than smoothed over, because the runbook now turns on
it.** A `v1.26.0` tag existed on origin ahead of the release and was **deleted** so the pipeline
could cut its own (verified-from-web: a `DeleteEvent` for `refType=tag`, `ref=v1.26.0`, actor
`manderse21`, at 2026-07-22T12:03:51Z -- three seconds before the dry run). The gated pipeline then
ran clean twice: a dry run at 12:03:54Z that passed all five gates and cut nothing, and the real run
(29918156282) at 12:04:27Z that cut the gitsign-signed tag at 12:06:36Z and published the Release at
12:06:42Z. **Gate 2 -- "tag does not already exist" -- passed in both runs**, which is precisely why
the pre-existing tag had to be removed first.

Nothing shipped from the deleted tag: the published v1.26.0 tag, both assets, and their SLSA
provenance all trace to run 29918156282 under `github-actions[bot]`. But a hand tag racing the
pipeline is exactly the failure class Section 3 exists to prevent, and it was invited by
documentation that printed runnable `git tag` commands as though they were the release path -- the
000141 outbox closes with exactly such a pair. Dispatch 000143 corrected every such surface: the
pipeline cuts the tag, and printed commands survive only as an explicitly-labelled manual fallback.

### HELD in PR (000134) -- snapshot retained; disposition since resolved

**Disposition since resolved (verified-from-web this session):** the 000134 train merged as plugin
PR **#92** (merge commit `c9692ca`, 2026-07-19) and its staged cut was tagged and published --
**v1.25.1** became the Latest Release (2026-07-19T00:41:38Z), gitsign-signed at tag object
`f92ff79` over `c9692ca`, and has since been superseded seven times over (000169 re-read the badge
as sitting on v1.28.1). The snapshot below is retained as the historical record of the train as it
ran; it is no longer the current held PR (that is 000141, above).

That train's legs sat on ONE plugin PR (the v1.25.1 cut + that roadmap refresh) plus its paired hub
PR; at write time nothing was merged, tagged, triggered, verified, F2-flipped, or published -- every
gate stayed Mike Andersen's, and he has since taken them. Leg 1: the v1.25.1 PATCH cut (both
manifests + the dated CHANGELOG heading; `PowerShellLsp.Release.Tests.ps1` green on the cut tree,
the version lockstep RED-proven in-session by mutation, then restored). Leg 2: that refresh. Leg 3:
a read-only community-catalog poll (boolean + timestamp recorded in the outbox). Leg 4: a fresh PK
bundle. No product code moved; no knob, ruleset, rationale, exit-code, budget, or CONTRACT surface
changed.

### HELD in PR (this dispatch, 000127) -- snapshot retained; disposition since resolved

**Disposition since resolved (verified-from-disk/web this session):** leg 1's reference-surfacing
design shipped as **v1.25.0** (000128, carrying the frozen-knob CONTRACT amendment it was blocked
on), and leg 5's code-scanning UPLOAD workflow is now on main -- it is the workflow whose RED ->
GREEN flip the scan-robustness lineage above records. The snapshot below is retained as the
historical record of the train as it ran; it is no longer the current held PR (that is 000134,
above).

Everything in this subsection sits in ONE open plugin PR on `dispatch/000127-overnight-train`. It is
**not on main, not tagged, not released**, and no version moved. It is listed here so the roadmap is
not silently stale for a reader who pulls the branch -- never as shipped work. Merge, and any release,
are Mike Andersen's gates. **Leg 8 classified this train NO-BUMP** (reasoning below).

- **Leg 1 -- N1.2/N1.3 reference surfacing: BLOCKED, survey delivered, ZERO product edits.** The
  design is settled and the single blocking decision is named (the `CONTRACT.md` FROZEN-KNOBS
  amendment); see N1.2 in Horizon 1. Nothing was built and no workaround was attempted -- a
  frozen-surface amendment is not an unattended decision. The survey is the leg's deliverable.
- **Leg 2 -- the ServeShim lifecycle flake: ROOT-CAUSED and FIXED (test-infra only).** The 000125
  outbox recorded two lifecycle tests (process reap + crash-propagation exit) failing intermittently
  on BOTH hosts, the failing pair VARYING per run, one isolated run fully green, and all four CI legs
  green. Root cause: the test harness's PSES-child lookup matched ANY `pwsh`/`powershell` whose
  command line contained `Start-EditorServices.ps1` + `pses-serve-`, scoped to nothing -- so a PSES
  leaked by a PRIOR session (000125 recorded six, aged 19-29h, and already suspected them of
  "inflating the local ServeShim flake") was returned as "this shim's child". The reap assertion then
  measured a foreign process, and the crash scenario KILLED one. That explains every recorded symptom,
  including why CI never saw it: a clean runner has no orphans. The lookup is now scoped to the run
  under test (start-time + parentage, both parameters mandatory so the unscoped scan is
  unexpressible), and three fixed sleeps became bounded readiness gates. **Shim product code is
  untouched** -- the semantics were never at fault.
- **Leg 3 -- N1.5 latency harness + measured numbers (see N1.5, and `docs/benchmarks.md`).**
- **Leg 4 -- N1.6 slice-2 survey: verdict recorded, ZERO product edits** (see N1.6).
- **Leg 5 -- E2.1: exit-code policy matrix tests + the code-scanning upload workflow** (see E2.1). The
  workflow is inert until merged by construction (no `pull_request` trigger), and the four named CI
  legs plus the release pipeline are diff-proven byte-identical.
- **Leg 6 -- catalog poll (read-only): `claude-powershell-lsp` is NOT present** in
  `anthropics/claude-plugins-community`'s `marketplace.json` (HTTP 200, 2248 plugin entries, polled
  2026-07-17T01:05:03Z, verified-from-web). Nothing is inferred about Console-side state in either
  direction; see E2.3, which is Mike-gated and unchanged.
- **Leg 7 -- this refresh.**
- **Leg 8 -- NO-BUMP (recorded, unilateral).** Classified from the CHANGELOG's own on-disk policy over
  what actually landed: MINOR requires "a new backward-compatible capability -- a new `userConfig`
  knob, an added diagnostics feature, a newly CI-verified platform", and **none of those landed**. Leg
  1 blocked, so there is no knob; leg 5's exit-code gate turned out to have shipped in v1.19.0 already,
  so what it landed is tests, a repo-CI workflow, and one behavior-neutral internal refactor (the
  `-FailOn` policy function moved into the scan library so it could be unit-tested at all). The
  plugin's runtime behavior is byte-identical. That is exactly the **000120 precedent** -- a
  test-infra-and-docs train that moved no version and took no Section 2 row. The docs improvements ride
  the next release that has a real reason to cut.

Earlier arc (v1.5.x through v1.17.0 -- launch-readiness, licensing MIT -> GPLv3, reliability /
auto-relaunch, doctor self-check, dogfood capture + review tooling, the CI proof-framework, the
enterprise trust-surface + measured-0%-FP corpus, community-release readiness, and release-engineering
automation with SBOM + provenance) is in CHANGELOG.md and the 000001-000067 log -- all merged,
F2-verified, and tagged where a version moved. CHANGELOG.md is authoritative for that older band; it
is not re-transcribed per-version here.

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

## 8. External technical review, round 2 (2026-07-31) -- adjudicated

A second external technical review, assessing v1.28.0 and scoring it 8.4 -> 8.8 after the round-1
response, was analyzed by Strategic-Claude and adjudicated by Mike Andersen on 2026-07-31. Rulings
R1-R5 were made before any execution began, and dispatch 000167 re-derived the review's nine
verifiable claims from the v1.28.0 tag (commit `57a61c5`) before anything was chartered on them.
This entry is the ratified register. The round-1 register -- the last bullet of Section 6 above --
is unchanged and still stands.

**Adopted -- `review-adopted-2026-07-31`.** A v1.28.1 PATCH front-door train, chartered from the
000167 survey rather than from the review's own snapshot of the tree:

`review-adopted: profile-first-ordering` (review P1) -- `profile` is declared LAST of the twenty
`userConfig` knobs and its title reads "preset for the knobs above", so both the manifest and the
README present nineteen individual knobs before the one knob that presets them. The knob moves
first and the knobs behind it are categorized.

`review-adopted: profile-label-rewording` (P2, ruling R2) -- human-facing labels become
Compatibility / Recommended / Comprehensive. The STORED enum values `safe` / `recommended` /
`strict` are FROZEN by this ruling; only description prose changes, so no config valid today
changes meaning.

`review-adopted: slash-command-quick-start` (P3) -- the README's primary install block ends on a
raw `pwsh -File "$env:CLAUDE_PLUGIN_ROOT/scripts/doctor.ps1"` even though `/powershell-lsp:doctor`
ships and is documented 91 lines further down. The command leads; the raw script is retained under
troubleshooting for the out-of-session case.

`review-adopted: install-time-wording` (P4) -- "Install and verify in under a minute" and "from
install to a real caught diagnostic in about five minutes" describe the same path 132 lines apart.
One of the two numbers goes.

`review-adopted: scan-literal-data-contract` (P5a) -- `commands/scan.md` carries no
treat-the-path-as-literal-data contract (quoting, unknown-option rejection, a leading hyphen still
being a path) and its usage example shows an unquoted `<path>` placeholder. The contract text is
added and the example is quoted.

`review-adopted: literalpath-hardening` (P5b, ruling R5) -- adopted as survey-then-build, and the
survey found NOTHING LEFT TO BUILD. See the derived-from-disk paragraph below; the conversion leg
is dropped from the v1.28.1 charter as already-satisfied rather than carried as busywork.

**Recorded measure-first -- ratified as questions, deliberately not as builds:**

`review-measure-first: status-doctor-split` (P6, ruling R4) -- no split this round. 000167 leg 1
measured both warm, and the split's premise does not survive: `status` is `doctor -Summary`, which
runs the identical check set and differs only in the formatter, so it cannot be cheaper. A split
would have to REMOVE checks, which is a different decision on different evidence.

`review-measure-first: per-profile-context-volume` (P7) -- how much context each profile adds per
edit is unmeasured. Recorded, not built; a later dispatch measures it.

`review-measure-first: per-profile-latency` (P8) -- per-profile edit-path latency is unmeasured at
`recommended` and `strict`. Recorded, not built. The existing measurement is the warm-path p95
under `ruleset = base` (3292 ms, n=20, the 000166 leg), which is one cell of the question.

**Declined, each with its ratified one-line reason:**

`review-declined: scan-json-args-wrapper` (ruling R3) -- the reviewer's JSON-args wrapper for the
scan command is more machinery than the problem needs, as the reviewer's own hedge conceded; the
literal-data contract text plus `-LiteralPath` is the proportionate boundary.

`review-declined: keeplastn-strict-removal` (ruling R1) -- declined FOR NOW, not on the merits: a
profile-mapping change is MINOR-classed by the evolution policy recorded above
`Get-PluginProfileMap`, so it cannot ride a PATCH train. Re-evaluate at the next MINOR.

**Already planned, and not new:**

`review-already-planned: arc-a-next` (P9) -- the diagnostic efficacy ledger was already the ratified
next arc, arrived at independently. The reviewer's seven-state finding taxonomy --
`arc-a-finding-taxonomy-2026-07-31`: fired / persisted / cleared-after-change / suppressed /
removed / replaced / unknown -- is a genuine improvement and folds into the Arc A build inbox's
open questions rather than into this train.

`review-already-planned: external-user-testing` (P10) -- off-hub and Mike Andersen's, sequenced
AFTER the v1.28.1 release so strangers test the corrected front door rather than the current one.

**The claims were re-derived from disk, and the survey corrected two of them** (000167 leg 1, read
at the v1.28.0 tag rather than carried from the review):

- **P5b is moot as stated.** Every path-taking cmdlet call site in `scripts/lsp-scan.ps1` (5 active
  lines) and in the helper the user path actually flows into, `scripts/lib/lsp-scan-common.ps1`
  (17 active lines), was enumerated over a 35-cmdlet vocabulary, RED-proven by planting a known
  site, with alias-shaped calls ruled out at zero in both files.
  Every call whose cmdlet HAS a `-LiteralPath` parameter already uses it; the only
  `-Path` uses are `Join-Path` and `New-Item`, neither of which has a `-LiteralPath` on Windows
  PowerShell 5.1 or on PowerShell 7 (checked live on both hosts). The user-supplied path reaches
  `[System.IO.Path]::GetFullPath`, then `Test-Path -LiteralPath`, then `Get-ChildItem -LiteralPath`
  -- it never touches a globbing parameter. Zero convertible sites remain, so the hardening leg is
  recorded as already-satisfied.
- **P1's defect is in the title, not the description.** The self-referential phrase "the knobs
  above" is in the `profile` knob's `title`, and its `description` says "Preset for the other
  knobs", which is position-independent. The reorder must fix the title; a description-only edit
  would leave the stale phrase on the surface a user actually reads first.
- **Whether the reorder changes what the config panel shows first is NOT derivable locally.** No
  document on this machine states how Claude Code orders `userConfig` rows, and no manifest schema
  is cached; the one adjacent local datum (dispatch 000109, filed upstream as
  anthropics/claude-code#74289) establishes that the panel renders a row per knob, not the order of
  those rows. The reorder ships anyway: it is decisive if the panel follows declaration order and
  harmless if it does not, and it is unconditionally correct on the two surfaces this project does
  control, since `docs/configuration.md` states "The knobs, in manifest order" and the README table
  follows the same order.

## 9. External technical review, round 3 (2026-07-31) -- adjudicated

A third external technical review, scoring v1.28.x at 9.2, moved the bottleneck it names: not
architecture and not documentation, but **evidence**. Its single unanswered question is whether
Claude actually writes better PowerShell because this plugin exists. Dispatch 000170 responded by
**measuring and deriving rather than arguing**, and this entry is the ratified register. Section 8
(round 2, same day) is unchanged and still stands; this section continues its token vocabulary.

Two things this train did NOT do, deliberately: it built nothing, and it bumped no version. The
build is chartered from what 000170 found, not from what the review claims.

**Recorded measure-first -- ratified as questions, deliberately not as builds:**

`review-measure-first: per-profile-telemetry` (round-3 Priority 3) -- round 2 already recorded
this, twice, as `review-measure-first: per-profile-latency` (P8) and
`review-measure-first: per-profile-context-volume` (P7). A second, independent external observer
asking for the same two numbers is the **second observation** that promotes them from question to
work. 000170 leg 1 attempted the sweep and **BLOCKED on host quiescence** -- see the named block
below. The promotion stands; the numbers do not exist yet.

`review-measure-first: annotation-throughput-not-persistence` (000170 leg 2, NEW -- not a review
item) -- of the four columns the shipped ledger derives, `verdict_distribution` has **never
received a single input**: annotations measured 0 at both the 2026-07-23 and 2026-07-31 vintages.
That column is empty for want of **human annotation**, not for want of persistence. Whether
annotation throughput rather than persistence is the binding constraint on Arc A is recorded here
as a question and resolved in neither direction.

**Declined, each with its ratified one-line reason:**

`review-declined: ab-experiment-without-preregistration` -- the review's most quotable suggestion,
a fixed-percentage before/after claim, is a self-run, self-scored comparison of one's own tool
against a nondeterministic model at whatever n a solo maintainer can afford. It is not chartered,
and it must not be improvised. If it is ever built the pre-registration comes first and separately:
corpus, rubric, sample size, who scores, and a written commitment to publish a null or negative
result. A number produced before that document exists cannot be published whatever it says.

`review-declined: whitepaper-now` -- written today it would restate `benchmarks.md`, `TRUST.md` and
`ARCHITECTURE.md` at greater length, which is on the review's own list of things not to build. It
becomes worth writing when legs 1 and 2 have produced numbers it can carry.

`review-declined-as-EMPTY: vendor-module-corpus` (000170 leg 3) -- **declined on a different
ground than the roadmap's**, and the difference matters. See the corrected disposition below.

**Already planned, and not new:**

`review-already-planned: arc-a-closed-loop` (round-3 Priority 1) -- the diagnostic efficacy ledger
was already the ratified next arc. 000170 leg 2 located the gap precisely and states it more
narrowly than the review does; see correction (b).

`review-already-planned: feature-freeze` -- the review's top recommendation is to freeze feature
development for a release or two. v1.28.1 was already a corrections-only PATCH train and this train
builds nothing, so the freeze is in force rather than newly adopted.

**Adopted, and chartered rather than built:**

`review-adopted: corpus-authorable-shapes` (000170 leg 3) -- of the ten shapes the review names,
three are reachable today with **zero third-party source vendored**, and one is already covered.
The classification is derived from the fixture files, not from prose about them; it is recorded in
the 000170 outbox and chartered into dispatch B.

### The named block -- leg 1 produced NO numbers, and that is reported rather than papered over

Leg 1's per-profile sweep is **BLOCKED**. Two successive quiescence gates failed on this host:

- **Gate A v1** (absolute CPU, mean < 10 pct): FAIL at **mean 26.60 pct**. The gate itself was
  defective -- it was calibrated against an idle box while the sweep requires an agent host to
  drive it, so **the apparatus could not be excluded from its own measurement**. Unreachable by
  construction.
- **Gate A v2** (foreign load only, agent host and sweep tree excluded by process tree, mean
  < 0.15 cores): FAIL at **mean 0.6294 cores**, max 1.5316, with browser processes still resident
  at the same PIDs across both probes. Agent-host draw, reported separately as the stated
  unavoidable constant: 0.577 cores mean.

Both gates were **pre-committed in writing before sampling**, precisely so the verdict could not be
judged after the fact, and the relaxation from v1 to v2 was Mike Andersen's single authorized
change on stated reasoning. **No latency, cold-start or context-volume figure is published, and the
ceiling verdict against the shipped 5000 ms `timeoutMs` default is recorded UNMET** -- it requires a
p95 that does not exist. A wrong latency number is worse than none, because it would be published.

What leg 1 DID establish, none of it timing-sensitive and all of it standing:

- **The profile-effect guard PASSES and can go RED.** `Get-PluginProfileMap` re-derived live:
  `safe` maps 0 knobs, `recommended` 5, `strict` 8. All three resolved twenty-knob sets are
  pairwise distinct and every mapped knob moved. Handed three identical sets, the same check
  **failed at exit 7** -- so its GREEN means something.
- **The shipped warm fixture cannot measure context volume at all.**
  `tests/bench/bench-fixture.ps1` is deliberately PSScriptAnalyzer-clean, so
  `additionalContext` is **zero bytes under every profile**. Any future context-volume measurement
  needs a findings-producing fixture; the existing harness cannot answer P7 as written.
- **The harness needs no code change to be pointed at a profile.** `Invoke-BenchHook` seeds its
  child environment from the parent, so `CLAUDE_PLUGIN_OPTION_profile` reaches every hook child.
  `tests/bench/` is byte-identical to `origin/main` (verified by git object id), and leg 1 landed
  **no commit at all**.

### Correcting the round-3 review, derived from disk

**(a) No rule was deleted, and no measurement recorded 100 pct false positives.** The review
credits the project with deleting a rule after measuring a 100 pct false-positive rate. What disk
says: **four** rules are EXCLUDED from the opt-in `base` ruleset by a named, comment-cited list
(`$BaseRuleExclusions`, `scripts/regen-base-ruleset.ps1`), and `rulesets/base.psd1` carries **53**
rules as a result. The recorded measurements are `PSReviewUnusedParameter` **~90 pct** (9 of 10),
`PSUseSingularNouns` **0 true-issues of 35**, `PSUseShouldProcessForStateChangingFunctions` 4 of 4
on the known-good oracle, and `PSUseOutputTypeCorrectly` 2 pedantic Information hits. **None is
recorded as 100 pct.** All four still ship in the pinned PSScriptAnalyzer and still fire wherever a
user's own settings select them; they are absent only from this plugin's generated `base` list, and
`pses-default` is byte-for-byte unaffected because none is in the PSES 15-rule allow-list. The
mechanism is a reversible one-line exclusion, not a deletion -- and the real story is the better one.

**(b) The project knows considerably more than "it produced diagnostics", and the missing half is
narrower than stated.** The shipped ledger already derives **four** columns -- `fired_count`,
`distinct_shapes`, `source_split`, `verdict_distribution`. Two are deliberately absent,
`fixed_next_turn_rate` and `persistence_rate`, and the reason is nameable: the closed-loop cleared
signal **is computed** (`Get-FindingLifecycleDiff`) and **is not persisted per rule**. 000170 leg 2
re-derived that rather than inheriting it, enumerating **10 write sites across 26 files** and
RED-proving the absence by planting a persisted rule-keyed write, catching it, and reverting. Zero
sites are both persisted and rule-keyed: the payload is ephemeral, the client prose is rule-keyed
but not persisted, and the daemon's debug line is persisted but carries only counts and a path.
The correction to the review is that this is a **narrow persistence gap, not an absence of
measurement** -- and, per the measure-first item above, one of the four shipped columns is empty
for a completely different reason.

**SHIPPED in v1.29.0** (annotated by dispatch 000195 leg A; the release id is DERIVED from the
CHANGELOG rather than asserted). The `## [1.29.0] - 2026-08-01` entry's "### Added" section carries
"**A per-rule lifecycle log, `logs/lifecycle-<stamp>.jsonl`** -- one record per distinct rule per
turn, carrying the cleared / still-present counts and the shape hashes behind them", and with it
"**`fixed_next_turn_rate` and `persistence_rate` in `scripts/rule-efficacy-ledger.ps1`**", both
derived from persisted data only. So the gap named above is CLOSED: the signal is now persisted AND
rule-keyed, and the two deliberately-absent columns are real. The log is a SIBLING of the capture
log, so `dogfood/diagnostics.jsonl` keeps its exact record shape and both shipped readers keep
reading historical logs unchanged. The three-way rendering the entry specifies -- `(absent)` when no
lifecycle log exists at all, `(no-events)` when a log exists but a rule has no events, and genuine
zeros as zeros -- is what keeps the closed gap from re-opening as a silent one.

**(c) Per-profile telemetry is not a new recommendation.** Round 2's register already carried it
under two tokens, `review-measure-first: per-profile-latency` (P8) and
`review-measure-first: per-profile-context-volume` (P7). Round 3 restating it is the second
independent observation, which is what promotes it -- but it is recorded as a promotion, not as a
new idea, and the register says so.

### The front-door intersection, re-derived at HEAD

Round 3's "the product is finally approachable" finding rests on Install / Doctor / PICK A PROFILE.
Re-derived at HEAD (v1.28.1, commit `dc5ddf6`) rather than carried from 000169's outbox: the
manifest declares **twenty** `userConfig` knobs and **every one of them declares exactly
`type`, `title`, `description`, `default`**. **No knob declares a `values` or an `enum` field.**
The v1.28.1 CHANGELOG's "the panel reads Compatibility / Recommended / Comprehensive" therefore
describes **description prose**, not a declared manifest shape.

**That observation is now an EXPLANATION, and this front-door item is CLOSED (dispatch 000195 leg
F).** 000167 recorded the question as **not locally derivable** -- whether the `userConfig` schema
even ACCEPTS a `values` field -- because no manifest schema is cached on this machine. It IS
derivable: the installed Claude Code bundled binary carries the shipped Zod schema. The verdict is
**REJECTS**. A `userConfig` option object is `.strict()` over exactly **nine** keys (`type`,
`title`, `description`, `required`, `default`, `multiple`, `sensitive`, `min`, `max`); `values`,
`enum`, `choices` and `options` are none of them, and `.strict()` makes an unknown key a validation
**error** rather than an ignored extra. Beyond that, `type` is itself a **closed enum of five
primitives** (`string`, `number`, `boolean`, `directory`, `file`), so there is no enum/select type
to declare in the first place. So the sentence above -- no knob declares a `values` or `enum` field
-- holds for a structural reason: **none can.** The ask is upstream rather than local, and a
post-ready DRAFT feature request lives at `docs/upstream/claude-code-userconfig-enum.md` (filing is
Mike Andersen's gate). The manifest and the CHANGELOG stay untouched, because there is nothing to
declare. *Re-derived from the installed binary at write time by 000197 leg 5 -- Claude Code
**2.1.223**, 2026-08-06; 000195 leg F first derived it at 2.1.221, and the nine-key `.strict()`
boundary and the five-primitive `type` enum are identical across both builds.*

### Arc A accrual -- the load-bearing figure is the NET one

**Genuine accrual moved from 16 occurrences / 13 shapes (dispatch 000148, measured 2026-07-23) to
55 occurrences across 12 rules (dispatch 000170, measured 2026-07-31), net of a removed rung.**

The gross figure is 120 occurrences / 47 shapes / 13 rules, and it must never be quoted alone.
**65 of those 120 -- 54 pct -- are `ManifestConsistency` firing on the UNDER-DECLARED-EXPORT rung
that dispatch 000162 REMOVED on 2026-07-29** as wrong by design, after measuring it at **911 hits,
0 true positives, 100 pct false positive**. All 65 sit in the `1.27.1` cache partition, timestamped
2026-07-25 20:42 to 21:13 -- a single 31-minute editing episode four days before the removal, 13
functions re-fired five times across one module pair, which is why their `distinct_shapes` is only
**2**. They are historical captures of a rung that no longer ships.

The same attribution applies to the canonical-checkout figure, which is why it too is never quoted
alone: **canonical-checkout moved 0 -> 69 gross, but 0 -> 4 net** of the removed rung. The
000148 baseline of 16 contained no `ManifestConsistency` at all, so the net comparison is
like-for-like.

### The union-read denominator inherits rules that no longer ship

**This is the most consequential thing 000170 leg 2 found, and it is not a footnote.**

`scripts/rule-efficacy-ledger.ps1` unions every per-version cache log it discovers, deliberately, so
that a plugin upgrade does not reset the denominator. The consequence, unnoticed until now: **the
union permanently includes occurrences produced by rules and rungs that have since been removed,
and no field in the capture record distinguishes them.** The record schema is
`ts, file, line, col, ruleId, source, severity, message, snippet, hash, verdict` -- it carries no
plugin version, no rule-surface version, and no rung identity. A removed rung is therefore
indistinguishable from a live one at read time except by matching message prose, which is what
000170 had to do by hand to attribute the 65.

Every future efficacy figure inherits this. It is recorded here and **deliberately not decided**:
whether the union should filter to the current rule surface, and what such a filter would do to
historical comparability, goes to the dispatch-B charter as a named open question.

### The vendor-corpus ask is EMPTY, not blocked -- correcting this project's own rationale

The roadmap places a real-world vendor corpus (Azure, Exchange, Active Directory, SharePoint, AWS,
PowerCLI) behind Arc B's licensing and provenance audit. **The factual half holds and the rationale
does not.** Covering those shapes as the review means them does require third-party source. But
Arc B is **not** what blocks them, and clearing Arc B would **not** unblock them:

- `pses-default`, the DEFAULT surface, reflected live from the vendored
  `Microsoft.PowerShell.EditorServices.dll` v4.6.0 (`AnalysisService.s_defaultRules`): exactly
  **15** rules, **0** matching `PSUseCompatible*`. All fifteen are generic PowerShell hygiene.
  **Not one is module- or vendor-aware.**
- `base`, the opt-in surface: **53** rules, **0** matching `PSUseCompatible*`, excluded **by
  construction** in `scripts/regen-base-ruleset.ps1` and documented there as always dropped because
  the family needs target-profile configuration.
- `PSUseCompatibleCommands` and `PSUseCompatibleTypes` are recorded unshipped.
- Corroborated empirically: a fixture calling `Get-AzVM`, `Get-Mailbox`, `Get-ADUser`,
  `Get-PnPTenantSite`, `Get-S3Bucket` and `Get-VMHost`, with **none** of those six modules
  installed, scanned to `"results": []` and exit 0.

**Vendoring vendor module source would therefore exercise NO SHIPPED RULE.** The ask is empty, not
gated. A vendor corpus becomes worth acquiring only AFTER a vendor-aware rule ships, which is a
MINOR rule-surface decision on its own evidence -- not a licensing one.

### Two Strategic-Claude corrections, recorded as corrections

This train corrected its own instructions twice, and both are recorded as corrections rather than
absorbed into the work:

- **The 000170 inbox's Arc B rationale for the vendor corpus is wrong** (the section immediately
  above). It was authored by Strategic-Claude and ratified before the rule surface was derived.
- **A mid-train Strategic-Claude amendment attributed the 65 `ManifestConsistency` captures to
  rungs 1 and 3, "the rungs 000162 left standing".** They are on the REMOVED rung 2. The
  attribution was inferred rather than derived; the message text settles it, since rung 1 emits the
  inverse wording and rung 3 emits an alias message. Corrected above.

The standing method holds: derive from disk, and record what disk says even when it contradicts the
instruction that asked for the derivation.

### A per-rule lifecycle persistence change classifies MINOR -- ruled, not open

Ruled by Mike Andersen before execution: **a per-rule lifecycle persistence change is MINOR, not
PATCH.** `dogfood/diagnostics.jsonl` is read by two shipped consumers,
`scripts/rule-efficacy-ledger.ps1` and `scripts/lib/dogfood-reader.psm1`, so its format is a
**consumer contract** even though no user hand-edits it, and the 1.x semver freeze is a stated
trust commitment. The ruling is carried into the dispatch-B charter as **pre-made**, not as an open
question. This train did not build the persistence change.

**The ruling was then HONOURED by the build that shipped it** (annotated by dispatch 000195 leg A).
000171 built the persistence change and the v1.29.0 CHANGELOG entry classifies itself "MINOR rather
than PATCH", giving the same reason this ruling gave -- two shipped consumers, a consumer contract,
the 1.x semver freeze -- and recording that no knob was added, removed, renamed, or re-defaulted.
The pipeline cut it as **v1.29.0** on 2026-08-01. So this item is closed as ruled-and-followed
rather than merely ruled: the classification a human made before execution is the classification the
release carries.

## The Arc A provenance ruling: never destructively filter, and fix the clearance gap FORWARD

Dispatch 000209. Two halves of one question -- "the union read includes rules that no longer ship,
and the clearance columns cannot say which release produced them" -- ruled together, because the
tempting fix for the second half is the thing the first half forbids.

### Half one: the union read NEVER filters. Closed as a ruling, not deferred.

`scripts/rule-efficacy-ledger.ps1` unions every per-version capture log it discovers, so that a
plugin upgrade does not reset the denominator. The consequence is that the union permanently
includes occurrences from rules that have since left the surface, and the standing open question
was whether it should ever filter them out.

**It should not, and this closes the question.** A retroactive filter would move figures that have
already been published -- the cardinal metrics anti-pattern, and the one an efficacy ledger exists
to refuse. The need a filter was reaching for is already met without mutation: the ledger prints
**both denominators side by side** (gross and current-rule-surface), names the out-of-surface rules,
and prints the unattributable remainder beside them rather than folding it into either side. A
reader who wants the filtered view can compute it from what is printed; a reader handed only the
filtered view can never recover what was dropped. The dual view is the scalable answer.

This is now enforced, not merely intended. `Read-LifecycleLog` tallies version provenance
**alongside** the counts and never selects on it, and
`tests/PowerShellLsp.RuleLedger.Tests.ps1` pins it in both directions: a golden comparison against
the pre-000209 rendering of the same fixture (the only delta is the added block -- every prior line
and figure is byte-identical), plus a RED control asserting that a mixed old/new log still reports
`n=9` and not the `5` a stamped-records-only filter would produce.

### Half two: the clearance-columns provenance gap, resolved FORWARD

`fired_count` and `distinct_shapes` are version-attributable because the capture log's
marketplace-cache **path** carries the plugin version, and a committed surface history maps a
version to the rule surface that shipped with it. The sibling lifecycle log (dispatch 000171 leg 2)
that feeds `fixed_next_turn_rate` and `persistence_rate` had neither: no version field, and a flat
stamped rolling family under `Get-LogDir` for a path. Its history was therefore not merely
unfiltered but **unrecoverable**.

**You cannot recover an un-instrumented past. You can stop the bleed and say where the knowable part
starts.** Two changes, both forward-only:

- **In-record provenance at emit.** `New-LifecycleLedgerRecords` (`scripts/lib/lsp-common.ps1`)
  stamps `pluginVersion` from `Get-PluginVersion` at emit time. In-record rather than in-path is the
  design: a field survives a file move, a rotation, and the reader's union, none of which a path
  segment survives. It is one additive field on a telemetry record, resolved after the
  zero-event early return so a clean turn still costs no manifest read, and fail-open like every
  other step on that path.
- **A printed provenance floor.** `Get-LifecycleProvenanceFloor` names the earliest
  version-attributable point; records below it are labelled a bounded, known gap. The floor is an
  **honesty marker, not a filter**: pre-floor records are still counted in every rate and simply
  never attributed to a version. No figure in the ledger is derived from the floor.

**No historical record was rewritten, and none may be.** Back-filling a version onto a record
emitted before the stamp existed would be inventing provenance -- a worse defect than the gap,
because it would be invisible.

### Three sub-rulings, derived from disk rather than assumed

- **The emit site is `New-LifecycleLedgerRecords` in `scripts/lib/lsp-common.ps1`, not the daemon.**
  `scripts/pses-daemon.ps1` only *calls* it. Stamping in the record builder means the daemon call
  site needs no change at all, so the persisted-format change touches exactly one write path.
- **The reader's cache-dir version derivation is NOT reused, and the reason is the sort direction.**
  `ConvertTo-CacheVersionKey` (`scripts/lib/dogfood-reader.psm1`) maps an unparseable name to
  `0.0.0` so any real version *outranks* it. That is correct for picking a **maximum** -- the
  current cache dir -- and inverts for picking a **minimum**: junk would become the floor of every
  ledger that saw it. The lifecycle path is not version-partitioned in the first place, so there is
  no directory name to parse; the in-record stamp is the sole source and the floor derives from the
  earliest stamped record. Same `[System.Version]::TryParse` primitive, opposite tie-handling,
  written out rather than imported so the wrong default cannot arrive silently.
- **`0.0.0-unknown` is not a version.** It is `Get-PluginVersion`'s own sentinel for "the manifest
  would not resolve", and it is stamped honestly, so it must be read honestly: a record carrying it
  counts as **pre-floor**, not as a release. Treating it as attributable would attribute real
  clearance data to a version that never shipped.

### The floor line always prints; the gap caveat prints only when there is a gap

The positive fact -- where version-attributable knowledge begins -- prints on every run that read a
lifecycle record, because a reader who cannot see it has to re-derive it. The **bounded-gap caveat**
prints only when a pre-floor record actually exists. Once the rolling family ages past the
un-instrumented window there is no gap, and a ledger that kept reciting an empty caveat would train
its reader to skip the section that will matter again after the next format change. An
all-attributable ledger reads clean; a gap is never silent.

## Roadmap II governance: five rulings, ratified-by-Mike 2026-08-12

Dispatch 000221 (R2-01), the Roadmap II opener. Roadmap I closed at 000220 with the pre-horizon
board empty. These five rulings are the authority the rest of the program cites; R2-02 and later
dispatches cite this section rather than re-deriving them. Recorded here as ratified, not proposed.

### 1. The North Star, and what Pillars A and H become

The North Star is approved with this wording: be the PowerShell layer a coding agent can be trusted
with -- every diagnostic honest about whether analysis ran, every release and policy
cryptographically attributable, every effectiveness claim measured -- **"in headless, automated, and
enterprise environments where editor-bound tooling is insufficient or unavailable"**. The quoted
clause is the ratified half: it names the environment the work is for, which is what keeps the
program from drifting back into editor-parity framing.

**Pillar A is reshaped to agent-facing semantic EXPOSURE of PSES capability.** The plugin is a
client of PowerShell Editor Services, not a re-implementation of it; the pillar is about surfacing
what PSES already computes in a form an agent can consume, not about growing an analysis engine.

**Pillar H is recorded DECLINED-pending-demand.** A custom-rule seam would resurrect the
already-declined new-custom-rules item under a new name. Guidance overrides remain the sanctioned
seam. Declined pending demand, not declined permanently: real user demand reopens it, and nothing
else does.

### 2. The program name

The program is named **Roadmap II**, everywhere and without exception. The roman-numeral phase form
of the name is not used in any authored file. The retired Phase 1-4 launch framing stays retired --
this ruling does not revive it, and no document should reintroduce it as a synonym.

### 3. ROADMAP.md stays short, and stays countless

`ROADMAP.md` keeps the short / no-counts public-view ruling it already carries. Per-initiative
detail lives in a **separate program document**, not in the public roadmap. The reason is the one
the no-counts ruling already rests on: a public roadmap carrying live counts is a stale-count
hazard on the most-read surface in the repository.

### 4. How Roadmap I is archived

The archival convention is two artifacts: a **closure section in this ledger**, plus a **slim
immutable snapshot at `docs/ROADMAP-I-ARCHIVE.md`**. Both are built by **R2-02**, not by this
dispatch. Recording the convention here is what gives R2-02 something to cite; building it here
would have pre-empted the dispatch chartered for it.

### 5. The re-audit / V10 verification is an acceptance criterion of R2-01

The eleven doc-set re-audit verdicts and the V10 stamp are folded into this dispatch as an
acceptance criterion rather than left as a standing unknown: R2-01 cannot close until every
previously unknown state is classified. The classification is carried in the 000221 outbox as a
twelve-row table, each row citing the outbox or log line it was derived from.

## Roadmap I -- closure record, ratified-by-Mike 2026-08-12

Written by dispatch 000230 (R2-02), the sanctioned scribe for the deferred ledger appends. Eight
dispatches ran with their ledger writes deferred so parallel work could stay file-disjoint; this
section and the three that follow are that deferred record landing at once.

**On placement.** Ruling 4 (above) called for "a closure section in this ledger" without fixing
where. This document's own convention answers it: the numbered sections `## 1`-`## 9` are the
standing structure, and everything since has been appended at the tail as an un-numbered `##`
section with a descriptive, dated title -- "## The Arc A provenance ruling...", "## Roadmap II
governance: five rulings, ratified-by-Mike 2026-08-12". Interleaving Roadmap I's closure into the
numbered spine would have rewritten sections that other documents cite by number. So: **pure
append, as a bounded top-level section**, following the convention the last two entries already
set. Recorded here because ruling 4 asked for the choice to be recorded.

### The arc, inception to 000220

Roadmap I ran from the plugin's inception to dispatch 000220, which closed it with the pre-horizon
board empty (`SC_SESSION_LEDGER.md`, 2026-08-06/07 entry: "the pre-horizon board emptied"; the
000220 outbox, state `verified`). Its shape was the four-horizon ladder recorded at section 4 of
this ledger, above -- Horizon 0 immediate tactical through Horizon 3 strategic what-if -- with the
retired Phase 1-4 launch framing preceding it.

**Closing state.** The program closed across release line v1.29.0 through v1.31.0. The two rulings
000220 carried are recorded above at "Gate 6's window: `WINDOW_DAYS=3` is RETAINED" and, for the
doctor security-verdict candidate, declined-final under the 000036 boundary. The v1.31.0 verify
ran at the 000161 standard under dispatch 000219, and the Rekor arc closed under dispatch 000217.

**Standing declines carried out of Roadmap I** are the table in `ROADMAP.md` under "Declined, and
why", each with its reasoning already recorded in this ledger: renaming the plugin, a file watcher
or background workspace sweep, loosening the 1.x semver freeze, new custom rules, flipping the
broader ruleset on by default, and reducing documentation volume.

**Pointer set** (per ruling 4 -- pointers, not restatement):

| For | See |
| --- | --- |
| The slim immutable snapshot | [`docs/ROADMAP-I-ARCHIVE.md`](ROADMAP-I-ARCHIVE.md) |
| What shipped, and when | [`CHANGELOG.md`](../CHANGELOG.md) and the GitHub Releases page |
| The reasoning behind each decision | this ledger, sections 1-9 and the appended tail sections |
| What is frozen in 1.x | [`CONTRACT.md`](../CONTRACT.md) |
| The Roadmap II baseline | [`docs/roadmap-ii/CURRENT-STATE.md`](roadmap-ii/CURRENT-STATE.md) |
| The Roadmap II detail layer | [`docs/roadmap-ii/PROGRAM.md`](roadmap-ii/PROGRAM.md) |

Roadmap I is closed. It is not a source of open work, and no item on it is pending.

## Roadmap II gate decisions D1-D7, ratified-by-Mike 2026-08-12

Companions to the five governance rulings recorded in the preceding section. Same ratification
date, same authority: recorded here as ratified, not proposed. Dispatch 000230 is their scribe,
not their author.

**Reader warning on identifier collision.** These gate decisions are D1-D7. The DX audit
(`docs/roadmap-ii/DX-AUDIT.md`) independently numbers its user-visible-DX-defect findings D1-D4.
They are unrelated namespaces. In this ledger, a bare D-number means a gate decision.

### D1 -- the Arc B gate, re-derived

The Arc B licensing gate is **PASS**, re-derived rather than assumed. All **137** files in the
audited corpus surface classify AUTHORED-IN-REPO, with zero DERIVED-FROM-EXTERNAL and zero unknown
(dispatch 000222, `docs/roadmap-ii/CORPUS-PROVENANCE-AUDIT.md`; PR
manderse21/claude-powershell-lsp#147, merged 2026-08-12).

Three riders ride with the PASS:

- **The licensing risk attaches to the never-published FP-survey oracle, not to the corpus.** This
  ledger's own prior Arc B wording named a population -- installed-module scripts mixed into the
  ad-hoc survey oracle -- that is *machine state and was never committed*. The gate's risk
  language therefore described something outside the repository. The committed corpus is clean;
  the ad-hoc oracle is what the caution was ever about, and it has never been published.
- **GPL-vs-permissive relicensing is deferred to Arc B activation.** Every one of the 137 files is
  authored in-repo under a single human rightsholder and takes GPL-3.0-or-later by repo-wide
  inheritance, with no per-file header anywhere in the set. That single-rightsholder fact is what
  makes relicensing *possible* later; whether to relicense for a community benchmark is not
  decided now and is not implied by the PASS.
- **A small rider: the SARIF attribution gap.** `tests/sarif/sarif-2.1.0.json` is committed
  third-party content under OASIS RF-on-RAND terms. Attribution is preserved thoroughly in a
  co-located `tests/sarif/NOTICE.md`, but `THIRD-PARTY-LICENSES.md` returns zero hits for SARIF,
  OASIS and SchemaStore and frames the project as "a downloader, not a redistributor". Recorded as
  a rider on the gate, not as a blocker of it.

### D2 -- SLO targets: measured, proposed, and not back-filled

Dispatch 000223 measured five metrics against the installed v1.31.0 cache build and proposed six
targets, T1-T6, *independently of* the measurements (`docs/roadmap-ii/SLO-BASELINES.md`; PR
manderse21/claude-powershell-lsp#149, merged 2026-08-12). The separation is the point: a target
back-filled from one run is not a target.

**The candidate targets remain UNRATIFIED as targets.** What is ratified at D2 is the *status*:
the measurements stand as the v1.31.0 baseline, and **T4 is red as engineering input, not as a
failure to be argued away**. T4 -- that every `.ps1`/`.psm1` shipped in this repository settles on
the edit path -- is not met: the edit path does not converge on the 3,881-line
`lib/lsp-common.ps1`, via a settle-cap-then-relaunch-thrash the plugin's own source already
documents on the scan path. Dispatch 000133 had already ratified that these files need up to
~15000 ms and raised the *scan* cap to match; the edit path was deliberately left at 5000 ms.
D2 records the red as the input that chartered D3, rather than as a target to be loosened.

### D3 -- the fix slice, chartered, with the frozen-baseline addendum

A fix slice is chartered against the T4 red: a live-but-busy daemon must never be classified
unreachable or relaunched; a genuinely unreachable daemon must still recover; every edit must
still resolve to a truthful terminal status. RED repro before the fix, GREEN after, with
unreachable-recovery and warm-path regression controls and a bounded relaunch-count observation.

**Hard boundaries, ratified verbatim:** no daemon redesign, no retry-policy cleanup beyond the
misclassification, no startup optimization, no cold-start work, no settle-cap change, no
status-token change.

**The addendum, ratified with the charter:** the v1.31.0 SLO baseline is **FROZEN pre-fix
history**. `docs/roadmap-ii/SLO-BASELINES.md` stays byte-identical, and the post-fix remeasurement
lands as a *separate new document*. The reason is the one the no-counts ruling rests on in a
different key: a baseline edited to reflect the fix stops being a baseline, and a before/after
claim whose "before" was rewritten after the fact cannot be checked.

Chartered as dispatch 000225. Its execution state is recorded in the Wave B section below.

### D4 -- the quiet-window rerun, declined

A rerun of the measurement set in a quiet window is **declined**. The baseline was taken on the
machine and under the conditions the plugin actually runs on; a quiet-window figure would measure
a machine no user has. Declined, not deferred.

### D5 -- cross-repository reference convention, ratified

Cross-repository references are fully qualified **`owner/repo#n`**, everywhere and without
exception. A bare `#n` is ambiguous the moment a document is read beside another repository's
issue tracker, and this program cites several repositories routinely. Ratified at D5 and already
binding on the Wave B dispatches (000227 inbox, acceptance criteria).

### D6 -- the pull-feature gating probe, corrected

`docs/upstream/pull-feature-gating-probe.md` (2026-06-14, dispatch 000015 Track B) recorded the
verdict **"#66987-gated (NOT buildable-now)"** on the premise that plugin LSP-server registration
is "empirically inert". That technical verdict has been **overtaken by dispatch 000069**, and D6
rules that the file is corrected in this pass rather than left to read as current.

What actually superseded it: 000069 proved the registration failure was *this project's own
manifest*, not an upstream init-ordering bug -- Claude Code's registrar silently drops any
`lspServers` entry declaring `restartOnCrash` or `shutdownTimeout`. Dispatch 000075 removed the
two fields and added an allowlist guard, and **registration was restored in v1.18.1** (this
ledger, the "Registration -- restored, v1.18.1 / 000075" entry and the v1.18.1 row of the release
table; `docs/upstream/claude-code-lsp-registration.md`). Mike rewrote
anthropics/claude-code#66987 on 2026-07-06 to the registrar-drop root cause, superseding the
init-ordering title the probe cited (`docs/upstream/sitting-closeout.md`, live table).

**The probe's forward guidance survives its verdict.** What remains blocked is *serve* on the
direct path -- a separate `#1359`-class handshake issue, closed locally by the opt-in
`nativeServe = shim` -- so "do not build a hook-shaped imitation of pull features now" still
holds, for a reason the probe did not have. The correction is dated and additive; the historical
text is preserved, per the re-derivation header convention dispatch 000224 established.

### D7 -- Wave B proceeds, with the DX taxonomy ratified

Wave B proceeds. The three-category taxonomy governing the DX audit is ratified **in advance of
the findings**, which is what keeps it a classification rather than a rationalization:

| Category | Meaning |
| --- | --- |
| **USER-VISIBLE DX DEFECT** | A stranger encounters it and cannot interpret or recover from it with shipped means. |
| **OBSERVABILITY DEFECT** | The behavior may be perfectly acceptable, but doctor / log / status cannot explain it. |
| **EXPECTED TRADEOFF** | Real, perhaps unpleasant, and intentionally bounded -- documented, priced, and recoverable. |

The taxonomy carries the weight because a DX audit that converts every measured imperfection into
a ticket is not an audit. Findings only; nothing is fixed by the audit itself, and triage of the
findings is not decided here.

## Wave A and Wave B -- completion records, derived 2026-08-13

State as of this dispatch's derivation, from `dispatch list`, the project log's GATE lines, and
live `gh` against manderse21/claude-powershell-lsp. Every row is the state at write time, not a
forecast. Where the record diverges from the charter's expectation, the divergence is recorded.

### Wave A -- 000221 through 000224

| Dispatch | Scope | Outbox state | PR | Merge commit |
| --- | --- | --- | --- | --- |
| 000221 | R2-01, canonical current state | `verified` | manderse21/claude-powershell-lsp#146 | `7f34277` |
| 000222 | R2-05, corpus licensing and provenance | `verified` | manderse21/claude-powershell-lsp#147 | `c0e4b51` |
| 000223 | R2-06, candidate SLOs and baselines | `verified` | manderse21/claude-powershell-lsp#149 | `776ea07` |
| 000224 | Wave A, `docs/upstream` true-up | `verified` | manderse21/claude-powershell-lsp#148 | `cfd2409` |

Wave A is complete: four dispatches, four outboxes at `verified`, four PRs merged.

### Wave B -- 000225 through 000228

| Dispatch | Scope | State at derivation | PR | Merge commit |
| --- | --- | --- | --- | --- |
| 000226 | R2-04, threat model | outbox `verified` | manderse21/claude-powershell-lsp#151 | `98eb027` |
| 000227 | R2-14, governance surface | outbox `verified` | manderse21/claude-powershell-lsp#150 | `5d8ac83` |
| 000228 | R2-08, DX audit | inbox `verified`; **no outbox document exists** | manderse21/claude-powershell-lsp#152 | `c4fc5ce` |
| 000225 | D3 fix slice | inbox `in_progress` | manderse21/claude-powershell-lsp#153 | **OPEN, red** |

**Two divergences from the "000221-000228 all verified" expectation, recorded rather than
smoothed:**

1. **000228 has no outbox.** Its deliverable shipped -- `docs/roadmap-ii/DX-AUDIT.md` is on `main`
   via PR #152, merged 2026-08-13T00:43:44Z -- and its *inbox* was walked to `verified` by Mike at
   2026-08-12T20:22:47-04:00. But the project log carries no `000228 | outbox` line at any state,
   and no such file exists in the hub, on `origin/main`, or anywhere on disk. The work landed; the
   record of the work did not. This is the "never-committed" entry of the taxonomy below, observed
   in its own right rather than inferred.

2. **000225 is still open and red.** PR #153 has had **three** CI runs on its branch and **none**
   has been green: `31654261705` (head `6a6d368`), `31654292071` (head `da1d6df`), and
   `31655416504` (head `7ce3c4b`, 2026-08-13T00:44:01Z) -- every one `failure`.

**The 000225 fix-forward, cited because its outbox is on origin.** Dispatch 000229 (N1) ran the
diagnostic, and its outbox is present on `origin/main` at write time, so its outcome is cited here
rather than left open:
`projects/powershell-lsp/outbox/000229-n1-fix-forward-diagnostic-for-pr-153-no-missing-delta-psl.md`,
state `complete`. Its findings, as recorded there:

- **No missing delta.** The 000225 worktree is clean and fully pushed; all five changed files are
  blob-identical between fix commit `6a6d368` and PR head `7ce3c4b`.
- **Both reds are PR-introduced regressions, separately root-caused.** An all-four-leg test-guard
  collision on the new `Invoke-ThEdit` helper, and a unix-only pipe-presence misclassification
  proven from CI artifacts.
- **The repair gate did not fire.** Leg 4 was missing-delta-only, so both fixes defer to Mike.
- **N1 asks whether repairing the unix arm of `Test-DaemonPipePresent` falls inside the D3
  boundaries** or needs a fresh charter. That question is open and is not answered here.

D3's charter therefore stands and its addendum still binds: `SLO-BASELINES.md` remains
byte-identical, and no post-fix remeasurement has been written.

## Tail-failure taxonomy and process findings -- FINDINGS AND CANDIDATES ONLY, 2026-08-13

**Status: none of this is a rule.** Every item below is recorded as a finding or a rule
*candidate*. Promotion of a candidate to a rule is Mike-gated (standing), and nothing here has
been promoted. A future reader should treat this section as evidence for a decision not yet made.

### The tail-failure taxonomy

Five failure shapes named at the tail of the Wave A/B run -- the close-out phase, after the
deliverable is already good. Recorded with what the disk actually supports, which is not the same
for every item.

| # | Shape | Status at derivation |
| --- | --- | --- |
| 1 | **Never-committed** -- the deliverable ships but its outbox is never written or committed | **CONFIRMED on disk.** 000228: PR #152 merged, `DX-AUDIT.md` on `main`, inbox walked to `verified`, and no outbox anywhere -- not in the hub, not on `origin/main`, not on disk. |
| 2 | **Sibling-dirt block** -- a close-out commit is blocked by unrelated dirt in a sibling path | Recorded as named by the 000230 charter. **Not independently reproduced by this dispatch:** no dirty sibling path was present in the shared hub root at write time (`git status` clean before and after the claim). |
| 3 | **Wrong-remote worktree push** -- a push lands somewhere other than the intended origin | Recorded as named. **Not supported by disk evidence here:** the hub's only remote is `https://github.com/manderse-dispatch/strategic-dispatch.git` for both fetch and push, and 000229 found no repository anywhere with a local-path origin. |
| 4 | **Unvalidated hand-mint** -- a dispatch file authored by hand, bypassing the CLI's schema validation | Recorded as named. Adjacent confirmed fact: a pre-mint draft fails the id regex by design, so hand-authoring is exactly the path that skips validation. Not independently reproduced in this run. |
| 5 | **Phantom-topology observations** -- close-out evidence read from a tree that is not the one being shipped | **REFUTED as a per-session-hub-copy mechanism.** See below; this is the item the record most needs to state carefully. |

### On item 5, stated plainly

The 000229 charter expected a per-session hub-copy topology and asked N1 to name the mechanism
that created it. **N1 could not, because it does not exist**: no per-session hub copies on this
machine, no repository anywhere with a local-path origin, no prunable or deleted hub-worktree
admin entries, and all five of that night's sessions recorded `cwd` = the shared root. This
dispatch re-derived the same fact independently: `git worktree list` in the shared hub root shows
only real hub worktrees, and no `strategic-dispatch-worktrees` or `hub-0002xx` path exists on
disk.

**What the symptoms actually had.** N1 found a simpler proven explanation, and two real
regressions in PR #153, neither of which needs a phantom tree. The errata it recorded stands:
000225's claim of "four-leg CI green observed in the foreground" is **falsified** by run
`31654261705`'s failure. N1 classifies 000225's other claims as unaffected -- its recorded checks
re-ran locally at verify and stand.

The finding worth carrying forward is therefore *not* "sessions work in phantom hub copies". It is
that **a foreground-CI claim with no run id is unfalsifiable at write time and false at read
time**. That is candidate 3 below, and it is the one with a second observation.

### The origin-evidence gate

The gate -- after minting and pushing, run `git fetch origin` and confirm the outbox commit
appears in `git log origin/main` from the shared root, recording the command and its output in the
outbox itself -- is recorded here as the countermeasure the tail failures point at. Items 1 and 5
are both shapes it catches: a never-committed outbox cannot appear in `git log origin/main`, and a
claim read from the wrong tree cannot be confirmed against the real origin. It is applied by this
dispatch to itself. **Recorded as a finding, not promoted to a rule.**

### The statusline-leak finding

Statusline shells are spawned on a two-second refresh interval (`~/.claude/settings.json`,
`statusLine.refreshInterval: 2`), which makes an accumulating population the expected failure mode
if any fail to exit. **Measured at this dispatch's sweep: zero stale shells** -- no `pwsh` process
running `statusline.ps1` exceeded five minutes of age, excluding this session's own pids. The
finding is recorded with its measurement, and the measurement did not reproduce a leak on this
run.

### Rule candidates -- NOT promoted

Carried forward from 000229's `rule_observations`, plus this dispatch's own. Each is a candidate;
none is a rule.

| # | Candidate | Second observation? |
| --- | --- | --- |
| 1 | A platform-conditional branch added to a cross-platform discriminator must carry per-platform evidence before it ships. `Test-DaemonPipePresent` measured the Windows arm and wrote the unix arm by analogy, unmeasured -- and the unix arm is the one that is wrong. | No |
| 2 | A purity guard that hardcodes an exact allow-list of derived names is a tripwire on every future helper; the guard belongs in the same review breath as the helper. | No |
| 3 | A foreground-CI claim must cite a run id. "Four-leg green observed in the foreground" with no run id and no `gh` invocation in the transcript is unfalsifiable at write time and false at read time. | **Yes** -- second observation of the foreground-only violation class |
| 4 | A dispatch whose deliverable merges but whose outbox is never committed leaves the work done and the record absent. The state machine does not catch it: 000228's inbox reached `verified` with no outbox in existence. | No -- first observation |

Promotion of any of these is Mike's call and has not been made.
