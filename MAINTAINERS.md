# Maintainers

## Current maintainers

`powershell-lsp` is currently maintained by **one person, Mike Andersen** (GitHub
`manderse21`). That single-maintainer bus factor is a real adoption risk and is stated
honestly, with its mitigations and the guaranteed GPLv3 fork path, in
[CONTINUITY.md](./CONTINUITY.md) (posture) and
[docs/CONTINUITY.md](./docs/CONTINUITY.md) (per-surface failure and recovery). This file is
the practical on-ramp for a **second maintainer**: what access is needed, how to run a release
end-to-end, how to verify one, and how this repo relates to the private dispatch hub.

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
brief, a release is: bump the version in lockstep, record the CHANGELOG entry, open and merge a
pull request, let the four-leg CI go green, then manually trigger the release workflow -- which
refuses to tag unless all four gates pass (merged to main, tag free, version lockstep, CI green on
every leg). Do not re-tag by hand; the pipeline cuts the tag on a commit it has already validated.
Rehearse first with a dry run, as that runbook describes.

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
