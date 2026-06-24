# Continuity and succession

This document states, honestly, what happens to `powershell-lsp` if its sole maintainer
becomes unavailable, and what a handoff would mechanically require. It names a real
**adoption risk** rather than hiding it. It does **not** name a successor -- there is no
designated one today; it describes the **mechanism** by which the project could be
continued or forked, and flags the specifics that still need a decision.

This extends the governance posture in [TRUST.md](./TRUST.md#governance-and-sustainability-adoption-risk-stated-honestly);
read that first for the short version.

## The risk, stated plainly

The project is maintained by **one person** (Mike Andersen). That is a single point of
failure for code review, security response, dependency bumps, and releases. An
organization with a hard bus-factor requirement should weigh this accordingly. The
mitigations below do not eliminate the risk; they make the project **survivable by
others** without the original maintainer.

## What survives without the maintainer

Even with no maintainer activity, the shipped artifacts remain auditable and reproducible:

- **Pinned, hash-verified dependencies.** PSES and PSScriptAnalyzer are pinned to exact
  versions and verified against SHA-256 hashes computed from the real artifacts, in-repo
  (`scripts/ensure-*.ps1`, [TRUST.md](./TRUST.md)). A fork builds the identical bundle.
- **A gate-validated, reproducible release pipeline.** Releases are cut by a
  maintainer-triggered GitHub Actions workflow that refuses to tag unless the commit is
  merged, green on every leg, and version-locked (see [docs/RELEASING.md](./docs/RELEASING.md)).
- **SBOM + build provenance.** Each release publishes a CycloneDX SBOM and a SLSA
  build-provenance attestation, so a downstream consumer can verify what they have.
- **A real disclosure policy.** [SECURITY.md](./SECURITY.md) documents private
  vulnerability reporting independent of any single person's inbox.
- **The full source and history**, under an irrevocable open-source license (below).

## The fork path (GPLv3)

The plugin is **[GPL-3.0-or-later](./LICENSE)** (forward-only from v1.6.1; v1.0-v1.6.0
remain under their original, irrevocable MIT grant). Two consequences for continuity:

- **Anyone may fork and continue the project** under GPLv3 at any time. The open-source
  grant cannot be revoked.
- **No CLA is collected**, so no party -- including the original maintainer -- can
  unilaterally relicense contributions away from GPLv3; that would require the agreement of
  all copyright holders. The community's ability to carry the project forward is therefore
  structurally protected, not dependent on goodwill.

A fork needs only the repository contents and this documentation. It would, of course,
publish under its own name, its own marketplace entry, and its own signing identity.

## Key custody and handoff levers

What a successor (or a fork) would need, and the honest current state of each:

| Asset | Where it lives | Handoff lever |
|-------|----------------|---------------|
| **Source + history** | The public GitHub repository | Already public; a fork needs nothing from the maintainer. |
| **Repo / marketplace ownership** | The maintainer's GitHub account (`manderse21`) | Transfer of repo admin, or a fork that publishes its own marketplace entry. |
| **Release provenance identity** | GitHub Actions **OIDC** (ephemeral) -- there is **no long-lived signing secret** stored for provenance | Nothing to hand off; a fork's pipeline attests under its own GitHub identity. |
| **Code-signing certificate** | **Does not exist yet** -- a SignPath Foundation application is **pending** (the plugin is **not** code-signed today; see [TRUST.md](./TRUST.md#code-signing-status----pending-the-plugin-is-not-signed)) | When/if issued, the certificate becomes a custody item; until then there is no signing key to lose or transfer. |
| **Dependency pins** | `scripts/ensure-pses.ps1` / `scripts/ensure-pssa.ps1` (single pin variables) | Self-contained in-repo; a successor bumps the pin and re-verifies the hash. |

Because there is no signing key and no long-lived release secret today, the **only**
maintainer-held assets are the GitHub repo/marketplace ownership. That is the narrow lever
a handoff or a fork has to deal with -- by design, the trust artifacts (hashes, SBOM,
provenance) are reproducible by anyone from the public source.

## Open items (need the maintainer's decision)

These are deliberately **not** decided here, to avoid inventing facts. They are flagged for
the maintainer to resolve:

- Whether to designate a **backup repository administrator** (a second GitHub account with
  admin rights) to reduce the single-account dependency.
- The **custody plan for the SignPath certificate** once the application is approved (who
  holds it, where it is stored, how it is rotated).
- Whether the marketplace listing should have a **documented fallback owner**.

Until those are decided, the GPLv3 fork path above is the guaranteed continuity mechanism:
the project can always be carried forward by the community, even if no individual handoff
is arranged.
