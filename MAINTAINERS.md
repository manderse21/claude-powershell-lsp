# Maintainers

## Current maintainers

`powershell-lsp` is currently maintained by **one person, Mike Andersen** (GitHub
`manderse21`). That single-maintainer bus factor is a real adoption risk and is stated
honestly, with its mitigations and the guaranteed GPLv3 fork path, in
[CONTINUITY.md](./CONTINUITY.md) (posture) and
[docs/CONTINUITY.md](./docs/CONTINUITY.md) (per-surface failure and recovery). This file is
the practical on-ramp for a **second maintainer**: what access is needed, how to run a release
end-to-end, how to verify one, and how this repo relates to the private dispatch hub.

## Release authority

**Who may release: any account holding repository admin on
`manderse21/claude-powershell-lsp` plus the ability to run GitHub Actions. Today that is exactly one
account, `manderse21`.** There is no second holder, and no secret or key that could be delegated
separately -- signing is keyless (see [Access grants](#access-grants) below).

Authority here is split, and the split is the point:

- **The pipeline decides whether a commit MAY be released.** Six gates, each of which refuses
  rather than proceeds: merged to main, tag free, version lockstep, CI green on every leg,
  tree-vs-published parity, and a rehearsal dry run on the same commit. They are enumerated in
  [docs/RELEASING.md](./docs/RELEASING.md#what-the-pipeline-validates-the-gates), and they are the
  reason a tag on an unmerged, red, wrong-version or unrehearsed commit is structurally impossible.
- **A human decides whether it SHOULD be.** Five gates are human-only and no automation passes
  them: **accept, merge, the `verified` flip, tag, and the product / positioning / sequencing
  calls** (`ROADMAP.md`, "Operating posture"). Choosing the moment and the version number is a
  judgement the pipeline deliberately does not make -- "automate the mechanics, preserve the
  decision" ([docs/RELEASING.md](./docs/RELEASING.md)).

Two consequences worth stating plainly:

- **The pipeline cuts the tag; a maintainer does not.** A hand-cut tag is unsigned, unattested, and
  blocks Gate 2 until it is deleted. The printed `git tag` commands are an unblock-only fallback.
- **Both halves rest on one person today.** The pipeline half is delegable the moment a second
  admin exists; the human half is not delegable to anything but another human. That open item is
  tracked in [CONTINUITY.md](./CONTINUITY.md) and is the subject of the on-ramp below.

## Second-maintainer onboarding

Work top to bottom. Every command here is ASCII and parses under Windows PowerShell 5.1. The
release procedure itself is **not** reproduced below -- it lives in exactly one place,
[docs/RELEASING.md](./docs/RELEASING.md), and is linked from each step so there is a single
source of truth.

### Access grants

A second maintainer needs, and should confirm they hold, each of:

- **Repository admin** on `manderse21/claude-powershell-lsp` -- to review and merge pull
  requests to `main`. (Ownership is the one genuinely maintainer-held lever; see the ownership
  surface in [docs/CONTINUITY.md](./docs/CONTINUITY.md).)
- **GitHub Actions** enabled and usable -- to trigger the manually-run release workflow. No
  repository secret or personal access token is required: the pipeline uses only the ephemeral,
  job-scoped `GITHUB_TOKEN` (verified-from-disk: [docs/RELEASING.md](./docs/RELEASING.md),
  "Least-privilege and secrets").
- **Marketplace listing** awareness -- the community marketplace entry publishes under this
  repo's name; a fork would publish its own entry. There is no separate marketplace credential to
  hold.

There is **no signing key, certificate, or stored release secret to grant or hold** -- signing and
provenance are keyless via Sigstore under the runner's ambient GitHub OIDC identity
(verified-from-disk: [TRUST.md](./TRUST.md), "Signing posture"). If onboarding ever seems to
require a stored signing key, that is the rejected key-custody path, not this one.

### Learn the release process

The canonical runbook is [docs/RELEASING.md](./docs/RELEASING.md). Read it end to end once. In
brief, a release is: bump the version in lockstep, record the CHANGELOG entry, advance the roadmap,
confirm published release bodies still agree with the CHANGELOG, open and merge a pull request, let
the four-leg CI go green, then manually trigger the release workflow -- which refuses to tag unless
all **six** gates pass (merged to main; tag free; version lockstep; CI green on every leg;
tree-vs-published parity; and a rehearsal dry run on the same commit within 3 days). Do not re-tag
by hand; the pipeline cuts the tag on a commit it has already validated. Rehearse first with a dry
run -- Gate 6 makes the rehearsal required, not advisory.

> **Corrected 2026-08-12 (dispatch 000227).** This paragraph previously said "all four gates",
> naming only Gates 1-4. That understated the pipeline in both directions: **Gate 5**
> (tree-vs-published parity, dispatch 000076) already existed when this file was created on
> 2026-07-19, and **Gate 6** (the dry-run pair, dispatch 000197) landed afterwards. The gate list
> above is now the one the workflow actually declares; `docs/RELEASING.md` remains canonical.

### Verify a release end-to-end

Anyone -- including a new maintainer confirming their first release -- can verify the two release
assets with GitHub's attestation tooling. The release publishes a source archive and a CycloneDX
SBOM, and the build-provenance attestation covers **both** (verified-from-disk:
[docs/RELEASING.md](./docs/RELEASING.md), "What the pipeline produces" and "Verifying a release").
Run `gh attestation verify` against **each** asset:

```
gh attestation verify powershell-lsp-1.24.0.tar.gz --repo manderse21/claude-powershell-lsp
```

```
gh attestation verify powershell-lsp-1.24.0.cdx.json --repo manderse21/claude-powershell-lsp
```

The release **tag** carries its own keyless Sigstore signature; verify it with `gitsign` against
the expected workflow identity, exactly as shown in
[docs/RELEASING.md](./docs/RELEASING.md), "Verifying a release". (Substitute the real released
version for `1.24.0` above.)

## The strategic-dispatch hub relationship

This repository's day-to-day work is coordinated through a **private "strategic-dispatch" hub**
that is **external to this repository** and is **not required to build, run, release, or fork the
plugin**. The hub holds work-order records (dispatches) that plan and track changes; the
authoritative history of what shipped lives in **this** repo's git history, CHANGELOG, and release
artifacts -- never in the hub. A second maintainer, a successor, or a fork can operate the project
end to end using only this repository and the docs it contains. The hub is a private convenience of
the current maintainer, not a dependency of the project; if it disappeared, nothing about building,
releasing, or forking `powershell-lsp` would change.

## What a maintainer must never do

- Never hand-cut a release tag as the normal path; let the validated pipeline cut it
  (see [docs/RELEASING.md](./docs/RELEASING.md), manual fallback is unblock-only).
- Never introduce a stored signing key or long-lived release secret -- keyless Sigstore is
  deliberate (see [TRUST.md](./TRUST.md)).
- Never claim a control, signature, or audit the project does not have; every trust claim in the
  docs is labelled and verifiable.
