# Releasing powershell-lsp

The governing rule of this release process is "automate the mechanics, preserve the
decision." The maintainer alone decides when to cut a release and which version number it
carries. A validation pipeline then performs the mechanical steps and refuses to act on
anything that is not safe to release. At no point is a release cut automatically; the
decision remains with the maintainer, and the pipeline simply enforces that the only
commits and circumstances that can be released are ones that satisfy defined safety checks.

> **This document is the single, canonical release runbook.** The continuity and maintainer docs
> ([CONTINUITY.md](../CONTINUITY.md), [docs/CONTINUITY.md](./CONTINUITY.md),
> [MAINTAINERS.md](../MAINTAINERS.md)) link here rather than restating the procedure, so the steps
> and the gates live in one place only.

Earlier, releases were tagged by hand as a sequence of manual commands. That manual process
is error-prone; on one occasion a mistake placed a version tag on the wrong commit, and the
tag had to be deleted and recreated. The pipeline removes that entire class of error by
cutting the tag itself, on a commit it has already validated, so a tag can never land on an
unvalidated or wrong commit.

> **The pipeline cuts the tag. Printed `git tag` commands are a FALLBACK, not the release path.**
> Several tools and documents print a `git tag` / `git push origin v<version>` pair for reference.
> They exist for the [manual fallback](#manual-fallback-if-the-pipeline-misbehaves) -- the case
> where the pipeline itself is unavailable -- and running one as part of a normal release is a
> process error, not a shortcut. A hand-cut tag is **unsigned and unattested** (the keyless gitsign
> signature and the SLSA provenance both require the workflow's server-issued OIDC identity), and
> because Gate 2 refuses a tag that already exists, it also *blocks* the pipeline until someone
> deletes it. This is not hypothetical: it happened on the v1.26.0 release, where a pre-existing
> `v1.26.0` tag had to be deleted before the pipeline could cut its own. **To release, trigger the
> workflow with the target version** (step 7 below) -- never a printed command.

The pipeline is the GitHub Actions workflow [`powershell-lsp release`](../.github/workflows/powershell-lsp-release.yml)
that the maintainer triggers manually; it never runs on push or merge. At a high level,
cutting a release means opening a pull request that bumps the version and records the change,
merging that pull request to main, waiting for the main branch CI to pass on every platform,
and then triggering the release workflow and providing the version number. The pipeline
checks its preconditions and, only if all of them hold, creates the tag and the GitHub
release. The exact steps and the exact checks follow below.

## How to cut a release

1. **Bump the version (lockstep).** Run the bump helper -- it writes the one target version
   into BOTH `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` so they can
   never drift:

   ```
   pwsh -File scripts/bump-version.ps1 1.13.0 -Apply
   ```

2. **Record the change in the CHANGELOG.** Add a new entry at the top of the entry list, in
   the existing format, headed exactly `## [1.13.0] - YYYY-MM-DD`, with a leading
   `PATCH:` / `MINOR:` / `MAJOR:` summary line (see [the SemVer policy](../CHANGELOG.md#versioning)).
   This entry becomes the release notes verbatim, so write it for the reader of the release.

3. **Do NOT edit the roadmap. A release cut does not touch it.**
   [ROADMAP.md](../ROADMAP.md) was **canonicalized version-free and count-free** by dispatch
   000230, and the per-release "move the shipped item" step this document used to carry is
   **RETIRED**. The page states the rule in its own header: it deliberately carries *no version
   numbers, counts, or shipped-item tallies*, because those go stale between releases and a stale
   count reads as a false claim. Its sections are thematic lanes -- "Now", "Next", "Gated and
   paced", "Declined, and why" -- not a shipped-item ledger, and there is no "Recently completed"
   destination to move anything into. A lane legitimately stays under "Now" while a slice of it
   ships; that is the page working as designed, not drift to be repaired at cut time.

   **So there is nothing here to do, and doing something is the error.** Editing ROADMAP.md during
   a release cut re-adds exactly the per-release state 000230 removed, which is why this step now
   forbids the edit rather than requesting it.

   Where the currency obligation actually lives now:

   - **What shipped** is recorded by the CHANGELOG entry from step 2 and by the release itself --
     one place, not two.
   - **Per-initiative detail, classification, gates and evidence** live in
     [docs/roadmap-ii/PROGRAM.md](roadmap-ii/PROGRAM.md), with the factual baseline in
     [docs/roadmap-ii/CURRENT-STATE.md](roadmap-ii/CURRENT-STATE.md). Those move when the
     *program* moves, which is not the same event as a version being cut.
   - **Resolved design questions and their successors** are recorded in the
     [decision ledger](decision-ledger.md), which is the evidence layer ROADMAP.md links to.

   Numbers published elsewhere ARE machine-enforced: see `tests/doc-claims.psd1`, which fails CI
   when a published number disagrees with the thing it counts.

   *History, so the change is legible.* A roadmap-currency gate was introduced by dispatch 000177
   leg 8, after v1.29.0 shipped Arc A's opener while the roadmap still listed it under "What is
   next". 000230 removed the state that gate policed, which retired the gate with it. Two
   consecutive release preps -- 000218 and 000232 -- had to override this step by charter to avoid
   regressing the canonicalization, and 000232 raised the contradiction as a finding; dispatch
   000234 fixed the document rather than the page.

4. **Confirm every already-published release body still AGREES with its CHANGELOG entry.**
   Run the sweep:

   ```
   pwsh -File scripts/audit-release-bodies.ps1
   ```

   It reads every published release body with `gh` and compares it, whitespace-normalized,
   against what `release/Get-ChangelogEntry.ps1` -- the extractor the pipeline itself uses --
   would produce from today's CHANGELOG. **Do not add a release on top of an unresolved
   MISMATCH.**

   Some divergences are permanent by construction -- once a correction is APPENDED to a
   published body, that body is longer than the entry it was cut from and can never compare
   equal again. Those live in `release/release-body-divergences.psd1` and report ACKNOWLEDGED
   rather than MISMATCH, with their reason printed in full so they stay visible rather than
   merely quiet. Each row pins the SHA-256 of the body it acknowledges, so applying a
   correction retires the row and forces a fresh look; an acknowledgement that stops
   describing anything reports STALE-ACK and fails. Adding a row is a deliberate statement
   that a reader is not being misled -- it is not a way to quiet a red sweep.

   Exit codes: **0** all agree or diverge only in an acknowledged, still-true way; **2** an
   unacknowledged divergence, a stale acknowledgement, or a release with no CHANGELOG entry;
   **1** the sweep could not run.

   Two duties, and the second is the one that creates the drift:

   - **Before publishing**, the sweep must be clean, or every outstanding divergence must be a
     known one you are choosing to carry. At publish time the new release's body cannot disagree
     with its entry -- the pipeline generates the notes from the CHANGELOG at the target commit,
     so they agree by construction. The sweep is therefore not checking the release you are about
     to cut; it is checking that no EARLIER release has drifted since it was published.
   - **Whenever a CHANGELOG entry for an already-released version is corrected, mirror that
     correction into the published release body in the same change.** The body was cut from that
     entry and is not regenerated; correcting the entry alone leaves the published notes saying
     the superseded thing, to the readers most likely to be relying on them. Mirror it the way
     this project corrects any shipped text: **APPEND a dated correction beneath the original,
     never rewrite or delete the published sentence** (the v1.17.0 and v1.29.0 corrections are
     the precedent). Editing a published release body is a deliberate act of publishing to an
     external surface; it is the maintainer's call and no automation performs it.

   **This gate is HUMAN, and it could not be machine-enforced even if we wanted it to be.** (Step 3
   above used to carry the other human gate in this runbook; it was retired with the state it
   policed, so this is now the only one -- and it is human for a stronger reason than that one
   was.) A published release body is **external state** -- it lives in
   GitHub's Releases API, not in the working tree. `tests/doc-claims.psd1` works because it
   derives the true value from a file ON DISK and fails CI when a published number disagrees with
   the thing it counts; there is nothing on disk for it to derive a release body from. A registry
   row pointed at one would either never run or silently pass, which is strictly worse than no
   row, because the row itself would read as evidence the surface is guarded. So the asymmetry is
   recorded here instead of papered over with a check that cannot exist. `scripts/audit-release-bodies.ps1`
   does not close that gap -- it makes honouring this gate one command instead of an act of
   diligence.

   Introduced by dispatch 000179, after a hand sweep of all 22 published bodies found two carrying
   a statement their CHANGELOG entry no longer supports: **v1.29.0** (a corpus transition `main`
   never made) and **v1.27.1** (whose notes still tell the reader both manifests stay at 1.27.0).
   Both are the same shape -- a CHANGELOG corrected after publication, and a body that did not
   follow.

5. **Open a pull request and merge it.** The PR runs the four-leg CI. Merge to main once it is
   green and reviewed. **Do not tag here, and do not run the tag commands the bump helper
   prints.** Those are a manual FALLBACK for a broken pipeline (see
   [Manual fallback](#manual-fallback-if-the-pipeline-misbehaves)), never the release path --
   the pipeline cuts the tag in step 7. A hand-cut tag is unsigned and unattested, and it will
   make Gate 2 refuse the pipeline run until someone deletes it.

6. **(Optional) Wait for the push CI on main to go green.** After the merge, the
   [`powershell-lsp CI`](../.github/workflows/powershell-lsp-ci.yml) workflow runs on the
   merge commit on all four legs (`windows-pwsh`, `windows-powershell`, `ubuntu-pwsh`,
   `macos-pwsh`). You no longer have to hand-time the next step to the window after CI
   finishes: Gate 4 now **waits** for this run to reach a terminal state (up to a generous
   timeout) before it judges, so triggering the release while CI is still in progress makes the
   release job **wait** for CI rather than refuse. Waiting here yourself is therefore optional --
   it just lets you confirm green before you trigger.

7. **Trigger the release workflow** with the version you just merged:

   - In the GitHub UI: **Actions -> powershell-lsp release -> Run workflow**, enter the
     version (e.g. `1.13.0`), leave **commit** blank to release the current `main` tip, and
     leave **dry_run** unchecked.
   - Or from the CLI:

     ```
     gh workflow run "powershell-lsp release" -f version=1.13.0
     ```

   The pipeline validates every precondition (next section) and, only if all pass, cuts and
   pushes the tag on the validated commit and publishes the GitHub Release.

> **Required -- rehearse first.** Run the workflow once with `-f dry_run=true` (or check
> **dry_run** in the UI) on this exact commit BEFORE the producing run. This is no longer a
> suggestion: **Gate 6 refuses a producing run that has no successful dry run on the same commit
> within 3 days.** See [Rehearse with a dry run](#rehearse-with-a-dry-run).

## What the pipeline validates (the gates)

The workflow runs six gates before it will tag anything. Each gate that fails stops the run
with a clear error and **tags nothing** -- the safe direction is always to refuse.

- **Gate 1 -- merged to main.** The target commit must be an ancestor of (or equal to)
  `origin/main`. An unmerged commit is refused.
- **Gate 2 -- the tag is free.** `v<version>` must not already exist. An existing tag is
  refused (so a release can never silently clobber or re-cut an earlier one).
- **Gate 3 -- version lockstep.** At the target commit, `plugin.json` and
  `marketplace.json` must BOTH read exactly the requested version. Any drift between the two
  manifests, or between either manifest and the requested version, is refused.
- **Gate 4 -- CI is green on every leg (waits for CI to finish).** The pipeline finds the
  push-event run of the CI workflow for the exact target commit and **waits for that run to
  reach a terminal state** -- it polls the run every 20 seconds until it is `completed`, up to a
  generous 30-minute timeout -- and only THEN judges it: the run must have concluded `success`
  and every required leg (`windows-pwsh`, `windows-powershell`, `ubuntu-pwsh`, `macos-pwsh`)
  must have concluded `success`. A still-running run is **waited on, not refused**; but no run
  found, a non-`success` conclusion, a failed or missing leg, or the timeout elapsing (CI did
  not conclude within 30 minutes) each still refuses -- the timeout refuses **honestly** (it is
  reported as a timeout, never as green). This wait removes the old timing race in which
  triggering the release before CI had finished refused a run that was about to pass. (The two
  values are set as `CI_WAIT_TIMEOUT_SECONDS` and `CI_WAIT_POLL_SECONDS` in the release
  workflow's Gate 4 step.)
- **Gate 5 -- tree-vs-published parity.** The version being released must not be BEHIND the
  version the marketplace actually resolves. The marketplace entry has source `"./"` with no ref
  pin, so it serves whatever `.claude-plugin/plugin.json` says at the `origin/main` tip; this gate
  compares the target commit's manifest against that published tip via
  [`release/Test-PublishedParity.ps1`](../release/Test-PublishedParity.ps1) and refuses a release
  that would leave the two diverged. It is the divergence guard added by dispatch 000076, after the
  registry silently served a stale `1.3.0` while the tree was already at `1.18.x` -- that class of
  drift is a structural refusal here rather than a surprise discovered weeks later.
- **Gate 6 -- the dry run actually happened, on this commit.** A producing run
  (`dry_run=false`) is refused unless a **successful `dry_run=true` run of this workflow exists
  for the SAME resolved target commit, within the last 3 days.** The rehearsal is no longer a
  tip in this document -- it is **required and enforced**. This gate runs only on producing runs
  (a rehearsal does not demand a rehearsal), and its decision logic lives in
  [`release/Test-DryRunPair.ps1`](../release/Test-DryRunPair.ps1), which is unit-tested against
  synthetic run sets in `tests/PowerShellLsp.Release.Tests.ps1`.

  **How a dry run is identified.** `dry_run` is a workflow input, and inputs do not appear on a
  workflow-run object -- which is why past dispatches could only recover "which run was the dry
  run?" from run steps. The workflow's `run-name` now encodes it, so every run carries
  `[DRY-RUN]` or `[PRODUCING]` and `target=<commit-or-HEAD>` in its own name. For runs created
  before that marker shipped, the gate falls back to step-conclusion inspection (a dry run's
  "Dry-run summary" step concluded `success`). A run that can be classified **neither** way is
  treated as UNKNOWN and never satisfies the gate.

  **Why 3 days -- and why the window is RETAINED.** The primary guard is commit identity: the
  rehearsal must have run against the exact commit being tagged. The window bounds what commit
  identity cannot pin, and there are two such things. The first is **external state** -- Gate 5
  reads `origin/main`'s published manifest and Gate 4 reads CI runs, both of which move while the
  target commit stands still. The second is the one that makes the window non-redundant, because
  Gates 4 and 5 re-read that external state fresh on the producing run anyway: **the pipeline
  definition itself drifts.** This workflow checks out `ref: main`, so a run executes whatever the
  release workflow *was at `main`'s tip at run time* -- not what it was when the target commit was
  authored. A dry run from three days ago therefore rehearsed a possibly older pipeline, and no
  amount of commit identity detects that, because the commit being tagged does not pin the workflow
  that tags it. Dispatch 000217 is the worked example: it changed the gitsign pin, the tag-verify
  path, and Gate 6's own pairing logic -- all in this workflow -- between cuts. So the window bounds
  how stale the rehearsal *of the pipeline* may be. Three days spans a rehearse-Friday /
  cut-Monday pattern without letting a producing run lean on a week-old view of either `main` or
  the pipeline. **Ratified retained (dispatch 000220):** this was the last unsettled control in
  Gate 6, and it is now a settled decision resting on that specific guarantee rather than an
  unexamined recency vestige. The reasoning is recorded in the
  [decision ledger](decision-ledger.md).

  **The recorded exception.** `skip_dry_check=true` bypasses this gate. It exists so that skipping
  the rehearsal is a **recorded run parameter**, visible on the run forever, rather than an
  omission nothing can detect afterwards. When set, the gate logs `SKIPPED-BY-INPUT` loudly (as a
  workflow warning and a banner in the step log) and passes. Use it for a genuine emergency; the
  record is the point.

Because the tag is cut by the pipeline only after all six gates pass -- never by a
hand-typed `git tag` -- a tag on an unmerged, red, wrong-version, wrong-commit,
behind-the-published-tip, or **unrehearsed** release is structurally impossible.

> **If the CI matrix changes legs,** update the `REQUIRED_LEGS` list in the release workflow
> to match `powershell-lsp-ci.yml`'s `matrix.label` set. A leg that is required but missing
> from a run is treated as not-green (refuse).

## What the pipeline produces

When all checks pass, the release pipeline produces several artifacts from the validated
commit: a **keyless gitsign-signed** annotated git tag (a Sigstore signature made with the
runner's ambient GitHub OIDC identity -- a Fulcio certificate, logged in the public Rekor
transparency log, no stored key); a GitHub release whose body is taken verbatim from the
changelog entry for that version, without retyping; a source archive that contains the exact
released tree; a Software Bill of Materials in CycloneDX format listing the plugin together
with its two pinned downloaded dependencies, PowerShell Editor Services and PSScriptAnalyzer;
and a build-provenance attestation that covers the archive and the bill of materials.

A `cosign` signature over the source archive was evaluated and deliberately not added: the
build-provenance attestation already covers that archive with a Sigstore-backed claim STRONGER
than a bare signature (it attests who built it, from what source, via which workflow), so a
separate signature over the same bytes would be redundant. The net-new signature is on the tag,
which nothing previously signed. Authenticode / Windows publisher signing of the scripts is
deliberately out of scope for a git-distributed plugin (see TRUST.md, "Signing posture").

The two release helpers are single-sourced and locally runnable:

- [`release/Get-ChangelogEntry.ps1`](../release/Get-ChangelogEntry.ps1) extracts the release
  notes from the CHANGELOG (the same body the pipeline publishes).
- [`release/New-PluginSbom.ps1`](../release/New-PluginSbom.ps1) generates the CycloneDX SBOM,
  reading the dependency versions straight from `scripts/ensure-pses.ps1` and
  `scripts/ensure-pssa.ps1` so the SBOM can never disagree with what the tool downloads.

## Rehearse with a dry run

A dry run validates every gate against a real commit and then stops -- it cuts no tag and
creates no release:

```
gh workflow run "powershell-lsp release" -f version=1.13.0 -f dry_run=true
```

**The dry run is a required step of every release, not an optional safety check.** Gate 6
refuses a producing run unless a successful `dry_run=true` run exists for the same resolved
target commit within the last 3 days. Before that gate existed the pair was described here and
enforced nowhere, and v1.29.0 duly shipped with no dry run at all -- caught only afterwards, by a
true-up dispatch.

Once the version is merged and the main CI is green, a dry run exercises Gates 1 through 5 end to
end (Gate 6 is skipped on a rehearsal -- a dry run does not require a prior dry run). When it
reports success, re-run the SAME version and commit with `dry_run=false` to publish.

Two things to keep in mind:

- **Rehearse the commit you intend to tag.** The gate matches on the resolved target commit, so a
  dry run against an earlier commit does not license a producing run against a newer one. If `main`
  moves after your rehearsal and you leave **commit** blank, the producing run resolves to the new
  tip and the gate will refuse -- rehearse again, or pin **commit** explicitly in both runs.
- **The bypass is recorded, not hidden.** If you genuinely must release without a rehearsal, pass
  `-f skip_dry_check=true`. The gate then logs `SKIPPED-BY-INPUT` loudly and passes, and the
  bypass is visible on the run's own parameters forever.

## Verifying a release

Two independent things can be verified: the released **assets**, and the release **tag**. Do the
asset check first -- it is the stronger of the two, it covers the bytes a consumer actually
downloads, and it works today with no caveats.

### 1. The assets (primary check)

GitHub's attestation tooling confirms that this repository's release workflow produced that exact
archive at that exact commit, and the attestation carries a Rekor transparency-log inclusion proof.

```
gh release download v1.30.0 --repo manderse21/claude-powershell-lsp \
  --pattern 'powershell-lsp-1.30.0.tar.gz'

gh attestation verify powershell-lsp-1.30.0.tar.gz --repo manderse21/claude-powershell-lsp
```

Exit status **0** is the pass. The check is load-bearing rather than decorative: it exits **1** on a
copy with a single byte flipped, and **1** when asked to attribute the intact archive to a different
repository. The SBOM published alongside it (`powershell-lsp-1.30.0.cdx.json`, CycloneDX 1.5 JSON)
lets a reviewer see exactly which external components the plugin fetches at install time, and at
which versions, without cloning anything.

The same steps, written for a consumer evaluating a download, are in
[SECURITY.md](../SECURITY.md#verifying-release-integrity).

### 2. The tag

The release tag carries its own keyless Sigstore signature. The tag subcommand is
**`gitsign verify-tag`** -- `gitsign verify` is the COMMIT subcommand, and pointing it at a tag
resolves the tag to its commit, finds no CMS block there, and dies with `unsupported signature
type: not a PEM block`. Run it from a normal clone: `verify-tag` cannot resolve refs inside a git
**worktree** and exits with `reference not found` there.

```
git fetch --tags
gitsign verify-tag \
  --certificate-identity="https://github.com/manderse21/claude-powershell-lsp/.github/workflows/powershell-lsp-release.yml@refs/heads/main" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  <tag>
```

**This command passes only for tags cut after the gitsign v0.17.1 pin landed (dispatch 000217).**
For **v1.30.0 and every earlier tag** it fails at its Rekor step with `hashes don't match` /
`could not find matching tlog entry`, and that is expected, permanent, and not a sign of a bad tag.
Those tags were cut by gitsign v0.16.1, whose signer keyed the transparency-log entry on the hash of
the tag reassembled as a COMMIT while every verifier looks up the real tag-object hash. The entries
exist and carry full inclusion proofs; nothing reads them at that key. They are deliberately not
re-signed, so the mismatch is permanent for those tags -- see the decision ledger, Section 3.

What still verifies for those tags, fully offline and without gitsign, is the part that carries the
trust: that the signature covers the tag payload, and who signed it. From a clone, with `$TAG` set:

```powershell
$ErrorActionPreference = 'Stop'   # a failed check must STOP, not print VALID anyway

# Windows PowerShell 5.1 does not load the assembly holding the Pkcs types; without
# this the block dies on New-Object with "cannot find type ... ContentInfo". PowerShell
# 7 already has them and has no such assembly to load, hence the guard.
if ($PSVersionTable.PSVersion.Major -lt 6) { Add-Type -AssemblyName System.Security }

$raw  = [System.Text.Encoding]::ASCII.GetBytes((((git cat-file tag $TAG) -join "`n") + "`n"))
$text = [System.Text.Encoding]::ASCII.GetString($raw)
$cut  = $text.IndexOf('-----BEGIN SIGNED MESSAGE-----')
$payload = $raw[0..($cut - 1)]
$armor = $text.Substring($cut) -replace '-----(BEGIN|END) SIGNED MESSAGE-----', ''
$der   = [Convert]::FromBase64String(($armor -replace '\s', ''))

# The signature is DETACHED: the signed content is the tag payload, so it must be
# supplied at construction or CheckSignature would verify nothing at all.
$ci  = New-Object System.Security.Cryptography.Pkcs.ContentInfo (, $payload)
$cms = New-Object System.Security.Cryptography.Pkcs.SignedCms ($ci, $true)
$cms.Decode($der)
$cms.CheckSignature($true)        # throws unless the signature covers the payload

$leaf = $cms.Certificates[0]
"signer  : " + (($leaf.Extensions['2.5.29.17'].Format($false)) -replace '^URL=', '')
"commit  : " + ([System.Text.Encoding]::ASCII.GetString(
    $leaf.Extensions['1.3.6.1.4.1.57264.1.13'].RawData) -replace '[^0-9a-f]', '')
"git says: " + (git rev-list -n 1 $TAG)
```

A pass means the signature is valid over the tag payload; the printed signer must equal the
workflow identity above, and the certificate's commit-binding extension must equal the commit git
says the tag points at. Flipping one bit of `$payload` makes `CheckSignature` throw `The hash value
is not correct.`, which is what keeps the check from being vacuous.

**Coverage, stated exactly.** For every released tag this proves signer identity and that the
signature covers the tag payload. Transparency-log inclusion is proven for the release **assets**
via `gh attestation verify` on all releases, and for the **tag** only on tags cut after the v0.17.1
pin. For v1.30.0 and earlier, tag transparency-log inclusion is not provable -- signer identity for
them is not in doubt, and the assets keep their own inclusion proofs regardless.

## Provenance: what it covers (and what it does not)

The plugin is normally installed when Claude Code copies the plugin's source from git, not by
downloading the release archive. For this reason the provenance attestation covers the
downloadable archive, which is a real and verifiable artifact for anyone who fetches it, but
it does not cover the clone-based install path. The integrity of that path rests on the git
commit and tag themselves. The intent is to attest a real artifact and be explicit about what
it does and does not cover, rather than to imply the attestation guards an install path it
does not.

This is the honest boundary for a git-distributed plugin: there is no compiled binary to
attest, so the meaningful artifact is the packaged source archive. The clone-based install path
itself is anchored not by an artifact signature but by the **keyless gitsign-signed tag** and the
commit it points at -- verify the tag (as shown above), then trust the tree it names. Authenticode
signing of the scripts proper -- the only thing that would give the install path a Windows
publisher signature -- is **deliberately not pursued** for this distribution model: a git-cloned
plugin is not a Windows `.exe` or installer, so publisher trust is moot, and the honest posture is
to allow-list by path or hash (see TRUST.md) rather than imply a trust the project does not have.

## What only proves out on the first real release

Most of the pipeline's logic is exercised before any release happens: changelog extraction,
bill-of-materials generation, version checks, the query that confirms the main CI was green, and
the signing-step configuration (asserted as workflow text in `tests/PowerShellLsp.Release.Tests.ps1`)
were all tested directly. What can only be confirmed on the first real release is the end-to-end run
on GitHub's own servers -- everything that needs a **server-issued OIDC identity token**: the
build-provenance attestation, the **keyless gitsign signature on the tag**, and the actual tag push
and release creation. These keyless steps cannot be exercised locally or in a dry run; they prove out
only when GitHub issues the runner a real OIDC token on a genuine release.

So the first real release is the first complete exercise of the pipeline, and it retires three
residuals at once: the provenance attestation (dispatch 000042), the Gate-4 wait-for-CI path
(dispatch 000063), and the keyless tag signature (dispatch 000064) all have their first live proof
on that one run. A manual fallback is documented below in case it misbehaves.

## Manual fallback (if the pipeline misbehaves)

If the pipeline ever fails for an infrastructure reason, a release can still be cut by hand --
but the gates must then be checked MANUALLY, in the same order, before tagging:

1. **Confirm merged + green.** On the Actions tab, confirm the target commit is on `main` and
   its push CI is green on all four legs.
2. **Confirm version lockstep.** Confirm `plugin.json` and `marketplace.json` both read the
   target version at that commit.
3. **Tag the validated commit and push it:**

   ```
   git tag -a v1.13.0 -m "powershell-lsp v1.13.0" <validated-sha>
   git push origin v1.13.0
   ```

4. **Create the release with the CHANGELOG notes (and, optionally, the SBOM):**

   ```
   pwsh -File release/Get-ChangelogEntry.ps1 -Version 1.13.0 -OutFile notes.md
   pwsh -File release/New-PluginSbom.ps1   -Version 1.13.0 -OutFile powershell-lsp-1.13.0.cdx.json
   gh release create v1.13.0 --title "powershell-lsp v1.13.0" --notes-file notes.md powershell-lsp-1.13.0.cdx.json
   ```

The manual path **cannot** produce the keyless artifacts that need the workflow's server-issued
OIDC identity: neither the build-provenance attestation nor the gitsign signature on the tag. A
hand-cut `git tag -a` (above) is therefore **unsigned**, and a manual release carries no
provenance. Prefer the pipeline for a fully attested, signed release; use the manual fallback only
to unblock, and re-run the pipeline path on the next release.

## Least-privilege and secrets

The workflow's default permission is `contents: read`; the release job is granted exactly
what it needs and nothing more: `contents: write` (cut the tag, create the release, upload
assets), `actions: read` (read the CI run status for the green gate), and `id-token: write` +
`attestations: write` (the build-provenance attestation). The **keyless gitsign tag signing reuses
that same `id-token: write`** -- it is the runner's ambient GitHub OIDC identity that gitsign
presents to Fulcio -- so signing added **no new permission and no new secret**. (Keyless is the
whole point: if signing ever appeared to need a stored signing key, that would be the rejected
key-custody path, not this one.) The workflow uses only the ephemeral, job-scoped `GITHUB_TOKEN`
-- no personal access token and no repository secret is referenced or exposed.
