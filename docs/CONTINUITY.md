# Continuity operations -- per-surface failure and recovery

This is the **operational** companion to the top-level [CONTINUITY.md](../CONTINUITY.md).
That document states the posture: the single-maintainer adoption risk, what survives without
the maintainer, the GPLv3 fork guarantee, and the key-custody levers. This document is the
working detail behind it: for **each operational surface**, what actually breaks if the sole
maintainer disappears tomorrow, and the concrete recovery path a qualified stranger would
take. The canonical release procedure lives in exactly one place --
[docs/RELEASING.md](./RELEASING.md) -- and is linked, never restated, here.

Every claim below is labelled `verified-from-disk`, `verified-from-web`, or `inferred`. Nothing
asserts an asset, key, or control the project does not have.

## Scope and relationship to the other continuity docs

- [CONTINUITY.md](../CONTINUITY.md) (repo root) -- posture and succession overview; linked from
  the README and CONTRIBUTING. Read it first.
- This file -- the per-surface failure-and-recovery detail (operations).
- [docs/RELEASING.md](./RELEASING.md) -- the single, canonical release runbook and gate list.
- [MAINTAINERS.md](../MAINTAINERS.md) (repo root) -- the second-maintainer onboarding checklist.
- [TRUST.md](../TRUST.md) -- signing posture and the honest governance/limits section.

## Per-surface failure and recovery

Each surface below names the failure (what stops working, or becomes unowned, if the maintainer
is gone) and the recovery path (what a successor or fork does about it). "Maintainer" throughout
means the sole GitHub account `manderse21` (verified-from-disk: named in
[CONTINUITY.md](../CONTINUITY.md) and [TRUST.md](../TRUST.md)).

### Source and history

- **What breaks:** nothing. The full source and git history are public and under an irrevocable
  open-source license (verified-from-disk: [LICENSE](../LICENSE), GPL-3.0-or-later forward from
  v1.6.1; v1.0-v1.6.0 remain under their irrevocable MIT grant).
- **Recovery:** a successor or fork needs nothing from the maintainer to obtain the code -- clone
  or fork the public repository. This surface has no single point of failure.

### Repository and marketplace ownership

- **What breaks:** the ability to merge to `main`, cut releases from this repo, and update the
  marketplace listing under this name. These are bound to the maintainer's GitHub account
  (verified-from-disk: custody table in [CONTINUITY.md](../CONTINUITY.md)). This is the **one**
  genuinely maintainer-held lever.
- **Recovery, two paths:** (1) transfer of repo admin to a successor account, if one has been
  designated (see the open item on a backup administrator in
  [CONTINUITY.md](../CONTINUITY.md)); or (2) a **GPLv3 fork** that publishes under its own name,
  its own marketplace entry, and its own signing identity. Path (2) is always available and needs
  no cooperation from the original maintainer.

### GitHub Actions and the release pipeline

- **What breaks:** no automated release can be triggered, because the release workflow is
  **manually triggered** and never runs on push or merge (verified-from-disk:
  [docs/RELEASING.md](./RELEASING.md), "the pipeline never runs on push or merge").
- **Recovery:** the pipeline is defined entirely in-repo
  (`.github/workflows/powershell-lsp-release.yml`) and is reproducible by a fork under its own
  GitHub identity with no stored secret. A successor with repo access triggers it exactly as
  documented in [docs/RELEASING.md](./RELEASING.md); a fork runs the identical workflow under its
  own account. A documented manual fallback exists in that same runbook for infrastructure
  failures.

### Release provenance and signing identity

- **What breaks:** nothing that depends on a held secret, because there is **no long-lived signing
  key and no stored signing secret** (verified-from-disk: [TRUST.md](../TRUST.md) "Signing
  posture"; custody table in [CONTINUITY.md](../CONTINUITY.md)). Provenance and the tag signature
  both use the GitHub Actions runner's ambient OIDC identity via Sigstore (Fulcio + Rekor).
- **Recovery:** a fork's pipeline attests and signs under **its own** GitHub identity. There is
  nothing to hand off, rotate, or recover -- the keyless model removes the key-custody surface
  entirely. Consumers verify what they hold against the workflow identity documented in
  [docs/RELEASING.md](./RELEASING.md) and [TRUST.md](../TRUST.md).

### Pinned dependencies

- **What breaks:** nothing immediately; the two external components (PowerShell Editor Services and
  PSScriptAnalyzer) are pinned to exact versions and verified against SHA-256 hashes in-repo
  (verified-from-disk: `scripts/ensure-pses.ps1`, `scripts/ensure-pssa.ps1`). Over time, unpatched
  dependency vulnerabilities would accumulate with no maintainer to bump them.
- **Recovery:** a successor edits a single pin variable per component and re-verifies the hash;
  the ensure-step re-vendors at the new pin (verified-from-disk: CHANGELOG "Pinned dependency
  bumps"). This is self-contained and needs no maintainer knowledge beyond the documented pin
  variables.

### Security disclosure and response

- **What breaks:** vulnerability triage and patch response, which depend on maintainer attention.
- **Recovery:** the private reporting channel and process are documented independently of any one
  inbox (verified-from-disk: [SECURITY.md](../SECURITY.md)). A successor or fork adopts the same
  policy; adopters retain the ability to review the open source and patch a fork themselves.

## What survives unattended

Even with zero maintainer activity, the shipped artifacts stay auditable and reproducible: the
pinned + hash-verified dependencies, the gate-validated reproducible release pipeline, the SBOM and
build-provenance attestation, the keyless-signed tags, and the documented disclosure policy. This
is the same set enumerated in the posture overview ([CONTINUITY.md](../CONTINUITY.md)); it is
restated here only as the backdrop to the per-surface recovery paths above.

## The guaranteed floor: the GPLv3 fork path

Whatever is or is not decided about a successor account, the **GPLv3 fork path is the guaranteed
continuity mechanism** (verified-from-disk: [LICENSE](../LICENSE), fork discussion in
[CONTINUITY.md](../CONTINUITY.md)). The open-source grant cannot be revoked, and no CLA is
collected, so the community's ability to carry the project forward is structurally protected rather
than dependent on goodwill. A fork needs only the repository contents and this documentation.

## Recovery drills a successor can run today

These read-only commands confirm the recovery surfaces are real before they are ever needed. Each
is a single line and parses under the Windows PowerShell 5.1 parser.

Confirm the source and full history are present:

```
git -C . log --oneline -1
```

Confirm the release workflow is present and manually triggered (never on push/merge):

```
Select-String -Path .github/workflows/powershell-lsp-release.yml -Pattern 'workflow_dispatch'
```

Confirm the dependency pins are single-variable and in-repo:

```
Select-String -Path scripts/ensure-pses.ps1, scripts/ensure-pssa.ps1 -Pattern 'PsesTag|PssaVersion'
```

Verify a released tag's keyless signature against the expected workflow identity (needs gitsign;
canonical procedure and the asset-provenance verification are in
[docs/RELEASING.md](./RELEASING.md)). The tag subcommand is `verify-tag` -- `gitsign verify` is the
COMMIT subcommand and cannot verify a tag. This passes only for tags cut after the gitsign v0.17.1
pin (dispatch 000217); for v1.30.0 and earlier it fails at its Rekor step by design, and
RELEASING.md gives the offline identity check that still applies to those:

```
gitsign verify-tag --certificate-identity="https://github.com/manderse21/claude-powershell-lsp/.github/workflows/powershell-lsp-release.yml@refs/heads/main" --certificate-oidc-issuer="https://token.actions.githubusercontent.com" v1.24.0
```
