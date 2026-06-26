# Releasing powershell-lsp

The governing rule of this release process is "automate the mechanics, preserve the
decision." The maintainer alone decides when to cut a release and which version number it
carries. A validation pipeline then performs the mechanical steps and refuses to act on
anything that is not safe to release. At no point is a release cut automatically; the
decision remains with the maintainer, and the pipeline simply enforces that the only
commits and circumstances that can be released are ones that satisfy defined safety checks.

Earlier, releases were tagged by hand as a sequence of manual commands. That manual process
is error-prone; on one occasion a mistake placed a version tag on the wrong commit, and the
tag had to be deleted and recreated. The pipeline removes that entire class of error by
cutting the tag itself, on a commit it has already validated, so a tag can never land on an
unvalidated or wrong commit.

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

3. **Open a pull request and merge it.** The PR runs the four-leg CI. Merge to main once it is
   green and reviewed. (Tagging is intentionally NOT done here -- the bump helper prints the
   tag command for reference but never runs it; the pipeline cuts the tag.)

4. **(Optional) Wait for the push CI on main to go green.** After the merge, the
   [`powershell-lsp CI`](../.github/workflows/powershell-lsp-ci.yml) workflow runs on the
   merge commit on all four legs (`windows-pwsh`, `windows-powershell`, `ubuntu-pwsh`,
   `macos-pwsh`). You no longer have to hand-time the next step to the window after CI
   finishes: Gate 4 now **waits** for this run to reach a terminal state (up to a generous
   timeout) before it judges, so triggering the release while CI is still in progress makes the
   release job **wait** for CI rather than refuse. Waiting here yourself is therefore optional --
   it just lets you confirm green before you trigger.

5. **Trigger the release workflow** with the version you just merged:

   - In the GitHub UI: **Actions -> powershell-lsp release -> Run workflow**, enter the
     version (e.g. `1.13.0`), leave **commit** blank to release the current `main` tip, and
     leave **dry_run** unchecked.
   - Or from the CLI:

     ```
     gh workflow run "powershell-lsp release" -f version=1.13.0
     ```

   The pipeline validates every precondition (next section) and, only if all pass, cuts and
   pushes the tag on the validated commit and publishes the GitHub Release.

> **Tip -- rehearse first.** Add `-f dry_run=true` (or check **dry_run** in the UI) to run
> every check and STOP without tagging or releasing. See [Rehearse with a dry run](#rehearse-with-a-dry-run).

## What the pipeline validates (the gates)

The workflow runs four gates before it will tag anything. Each gate that fails stops the run
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

Because the tag is cut by the pipeline only after all four gates pass -- never by a
hand-typed `git tag` -- a tag on an unmerged, red, wrong-version, or wrong commit is
structurally impossible.

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

This is the safest way to confirm a commit is releasable. Once the version is merged and the
main CI is green, a dry run exercises Gates 1 through 4 end to end; when it reports success,
the same trigger with `dry_run=false` will publish.

## Verifying a release

Anyone who downloads the release archive can use GitHub's attestation tooling to confirm that
this repository's release workflow produced that exact archive at that exact commit. The bill
of materials lets a security reviewer see precisely which external components the plugin
fetches at install time, and at which versions, without needing to clone anything.

```
# Verify the build provenance of the release archive:
gh attestation verify powershell-lsp-1.13.0.tar.gz --repo manderse21/claude-powershell-lsp

# Inspect the SBOM attached to the release:
#   powershell-lsp-1.13.0.cdx.json   (CycloneDX 1.5 JSON)
```

The same steps, written for a consumer evaluating a download, are in
[SECURITY.md](../SECURITY.md#verifying-release-integrity).

The release **tag** carries its own keyless Sigstore signature. Verifying it needs
[gitsign](https://github.com/sigstore/gitsign) (a plain `git verify-tag` cannot read the x509 /
Sigstore signature, and even with gitsign configured it checks only cryptographic integrity and
Rekor existence -- not signer identity, so it is not a full verification). Fetch the tags, then
verify against the expected workflow identity and the GitHub OIDC issuer:

```
git fetch --tags
gitsign verify \
  --certificate-identity="https://github.com/manderse21/claude-powershell-lsp/.github/workflows/powershell-lsp-release.yml@refs/heads/main" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  v1.13.0
```

A successful verify confirms the tag was signed by THIS repository's release workflow under
GitHub's OIDC issuer, anchored in Rekor.

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
