# TRUST.md -- powershell-lsp security and trust posture

This document is the approve-or-deny reference for a security team evaluating
`powershell-lsp` on a managed Windows estate. It states plainly what the tool runs,
what it downloads, how those downloads are integrity-checked, what is signed (release
tags, via keyless Sigstore) and what is deliberately not (Authenticode), how to
allow-list it under application-control policy, and the governance risks of adopting it.
It claims nothing that is not true: the plugin's installed scripts are **not
Authenticode-signed** -- a deliberate choice for a git-distributed plugin (see [Signing
posture](#signing-posture)) -- and the project has **not had a third-party security audit**
(see [Honest limits](#honest-limits)).

The authoritative sources are the code and the release artifacts, not this prose. Where a
claim is mechanically enforced, the enforcing file is named.

## What it is

`powershell-lsp` is a Claude Code plugin that delivers PowerShell diagnostics
(PSScriptAnalyzer findings and parser errors) while you edit `.ps1` / `.psm1` / `.psd1`
files. It drives [PowerShell Editor Services](https://github.com/PowerShell/PowerShellEditorServices)
(PSES) as a language server behind a per-session daemon. See [README.md](./README.md)
for how it works.

## What it executes -- and what it does NOT

**Runs, entirely on the local machine:**

- PowerShell hook scripts (`scripts/*.ps1`) under `pwsh -NoProfile`, invoked by Claude
  Code at SessionStart / PostToolUse / SessionEnd.
- One PSES language-server child process per session, talking LSP over a local **named
  pipe** (Unix domain socket semantics on non-Windows). No TCP port is opened.
- PSScriptAnalyzer, in-process inside that PSES child, over the file you are editing.

**Does NOT do, by design:**

- **No network service.** Nothing listens on a socket; the only IPC is a local named pipe
  keyed to the session id.
- **No telemetry, no exfiltration.** The plugin sends **nothing** off the machine. There
  is no analytics endpoint, no phone-home, no crash reporter. All state, logs, pids, and
  the vendored analyzer live under `CLAUDE_PLUGIN_DATA` and stay there.
- **No network access at all after first-run bootstrap.** The ONLY outbound network the
  plugin makes is the one-time download of its two pinned dependencies (below). Once those
  are vendored and marker-gated, every later session is fully offline.
- **No security-control circumvention.** The plugin never disables, weakens, or works
  around ExecutionPolicy, Constrained Language Mode, WDAC/App Control, Defender ASR, or
  Smart App Control. When one of those blocks a component, the plugin **detects and
  explains** it (see [Honest degradation](#honest-degradation-the-l3-behavior)); it never
  bypasses it.

> A local data-capture log (`dogfood/diagnostics.jsonl`) records the diagnostics the tool
> surfaces, for offline quality work. It is **local-only, gitignored, and never
> transmitted** (see README "Dogfood diagnostic capture"). Optional `enableStats`
> (default **off**) appends local timing lines. Neither leaves the machine.

## What it downloads (pinned versions AND pinned hashes)

Two third-party components are **downloaded on first use**, not bundled in this repo. Each
is pinned to an exact version AND verified against a SHA-256 computed from the real
known-good artifact **before it is used**. A mismatch **fails closed** -- the bundle is
refused, any prior working bundle is left intact, and the session surfaces an honest
`unavailable` banner while editing keeps working (the analyzer is simply off until a
verified bundle lands). This is enforced in `scripts/ensure-pses.ps1` and
`scripts/ensure-pssa.ps1` via `Test-PinnedFileHash` (`scripts/lib/lsp-common.ps1`).

| Component | Version | Source (exact URL) | SHA-256 of the pinned artifact |
|-----------|---------|--------------------|--------------------------------|
| PowerShell Editor Services | `v4.6.0` | `https://github.com/PowerShell/PowerShellEditorServices/releases/download/v4.6.0/PowerShellEditorServices.zip` | `0D91898F73D4FAEB64291336F6386F0C890A933DF012827571ADF7008480A04A` |
| PSScriptAnalyzer | `1.25.0` | `https://www.powershellgallery.com/api/v2/package/PSScriptAnalyzer/1.25.0` | `14E634C828EB98EFB9F40B2918BA90F139ED5ECCDF663A2A747736D996995D60` |

Both are Microsoft open-source projects under the MIT license (MIT is GPL-compatible; see
[THIRD-PARTY-LICENSES.md](./THIRD-PARTY-LICENSES.md)). The pins live in single variables
(`$PsesTag` / `$PsesSha256` in `ensure-pses.ps1`; `$PssaVersion` / `$PssaSha256` in
`ensure-pssa.ps1`); a bump recomputes the hash with `Get-FileHash`. To verify a pin
yourself:

```
# Confirm a download matches the pin this repo ships:
(Get-FileHash -Algorithm SHA256 -LiteralPath .\PowerShellEditorServices.zip).Hash
```

The PSScriptAnalyzer acquisition path is **verified `.nupkg` download first**; only if that
download cannot complete (offline / proxy) does it fall back to `Save-Module`, which relies
on the PowerShell Gallery's own publisher/catalog integrity. A hash **mismatch** never
falls back -- it fails closed.

## Supply-chain artifacts: SBOM + build provenance

Every tagged release publishes, on the GitHub Release:

- A **CycloneDX 1.5 SBOM** (`powershell-lsp-<version>.cdx.json`), covering the plugin and
  both pinned downloaded dependencies. It is generated by `release/New-PluginSbom.ps1`,
  which reads the pins straight from the `ensure-*` scripts, so the SBOM can never disagree
  with what the tool actually downloads.
- A **SLSA build-provenance attestation** over both the source archive
  (`powershell-lsp-<version>.tar.gz`, a `git archive` of the exact tagged tree) and the
  SBOM, produced by `actions/attest-build-provenance` with GitHub OIDC.

Verify the provenance of a downloaded artifact:

```
gh attestation verify powershell-lsp-<version>.tar.gz --repo manderse21/claude-powershell-lsp
```

The release pipeline is **maintainer-triggered and gate-validated** (merged to `main`,
green on every CI leg, version-locked) and cuts the tag itself on the validated commit.
See [docs/RELEASING.md](./docs/RELEASING.md). This document does not modify any of those
generators; it points at what they already produce.

## Signing posture

The project uses **Sigstore** -- keyless, transparency-logged supply-chain signing -- for its
release artifacts, and **deliberately does not pursue Authenticode** publisher signing of the
scripts. Those are two different things, and this section is precise about which is which, so you
can approve on what is true rather than on a badge.

**What IS signed.** Every tag the release pipeline cuts is a **keyless gitsign-signed tag**: the
GitHub Actions runner authenticates with its **ambient GitHub OIDC identity**, Sigstore's Fulcio
issues a short-lived certificate, the tag is signed with `git tag -s`, and the signature is logged
in the public **Rekor** transparency log. There is **no long-lived signing key and no stored
secret** -- the same keyless model as the build-provenance attestation, which already covers the
source archive and SBOM (see
[Supply-chain artifacts](#supply-chain-artifacts-sbom--build-provenance)). That provenance
attestation is itself Sigstore-backed (Fulcio + Rekor), so the source archive is already covered by
a claim STRONGER than a bare signature -- it attests who built the artifact, from what source, via
which workflow. A separate `cosign` signature over that same archive was evaluated and **judged
redundant** (its only edge, Rekor-direct verification, the provenance bundle already provides), so
it was not added.

**What is NOT signed, and what the tag signature does NOT cover:**

- **The installed scripts are not Authenticode-signed**, by design. `powershell-lsp` is distributed
  as a **git-cloned plugin**, not a Windows `.exe` or installer, so a Windows Trusted-Root publisher
  signature is **moot** for this distribution model. On a machine that requires signed scripts (GPO
  `AllSigned`, or WDAC / AppLocker that trusts only signed code), the plugin is **blocked** until you
  allow-list it by path or hash (below); it tells you which control blocked it (see
  [Honest degradation](#honest-degradation-the-l3-behavior)) and never tries to get around it.
- **The `/plugin` clone-based install path is not covered by an artifact signature.** Claude Code
  installs the plugin by copying its **source from git**, not by downloading the signed release
  archive, so neither the tag signature nor the archive provenance attests *that* path directly. Its
  integrity rests on the **signed tag and the commit it points at** -- verify the tag (below), then
  trust the tree it names.
- **A gitsign signature needs gitsign-aware tooling to verify.** A plain `git verify-tag` without
  gitsign cannot interpret the x509 / Sigstore signature, and even with gitsign configured it checks
  only cryptographic integrity and Rekor existence -- **not who signed**. Use `gitsign verify` with
  the expected identity (below) for a real verification.

**Verify a release tag's signature** (needs [gitsign](https://github.com/sigstore/gitsign)
installed; fetch tags first with `git fetch --tags`):

```
gitsign verify \
  --certificate-identity="https://github.com/manderse21/claude-powershell-lsp/.github/workflows/powershell-lsp-release.yml@refs/heads/main" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  v<version>
```

This confirms the tag was signed by **this repository's release workflow** running under GitHub's
OIDC issuer, with the signature anchored in Rekor. (The **SignPath Foundation** free-OSS Authenticode
path was **declined / adoption-gated**; the keyless Sigstore approach above is the comparable the
project adopted instead. The paid like-for-like, **Azure Trusted Signing**, is gated on a qualifying
US / CA legal entity and is not pursued today.)

## Allow-listing on managed Windows

Because the plugin's scripts are deliberately not Authenticode-signed (see
[Signing posture](#signing-posture)), allow-list it by **path** or by **hash**. Its two
trust surfaces are (1) the plugin scripts in the Claude Code plugin cache
(`%USERPROFILE%\.claude\plugins\...\powershell-lsp\`, exposed to the scripts as
`CLAUDE_PLUGIN_ROOT`) and (2) the downloaded components under `CLAUDE_PLUGIN_DATA`
(the PSES bundle and the vendored PSScriptAnalyzer). Resolve the real paths on the target
machine first:

```
# From inside an enabled Claude Code session:
$env:CLAUDE_PLUGIN_ROOT   # plugin scripts
$env:CLAUDE_PLUGIN_DATA   # downloaded PSES + PSScriptAnalyzer, logs, pids
```

### AppLocker (paste-ready Script rule)

AppLocker path conditions do not expand `%LOCALAPPDATA%`, so substitute the resolved
absolute paths for the two placeholders below (keep the trailing `\*`). This XML is a
**Script** collection allow rule for the Everyone group; merge it into your AppLocker
policy and deploy via GPO or `Set-AppLockerPolicy`.

```xml
<RuleCollection Type="Script" EnforcementMode="Enabled">
  <FilePathRule Id="b8e2a3c1-0000-4a00-9000-powershelllsp01"
                Name="powershell-lsp plugin scripts"
                Description="Allow Claude Code powershell-lsp plugin scripts"
                UserOrGroupSid="S-1-1-0" Action="Allow">
    <Conditions>
      <FilePathCondition Path="%OSDRIVE%\Users\*\.claude\plugins\*\powershell-lsp\*" />
    </Conditions>
  </FilePathRule>
  <FilePathRule Id="b8e2a3c1-0000-4a00-9000-powershelllsp02"
                Name="powershell-lsp downloaded components"
                Description="Allow vendored PSES + PSScriptAnalyzer under CLAUDE_PLUGIN_DATA"
                UserOrGroupSid="S-1-1-0" Action="Allow">
    <Conditions>
      <FilePathCondition Path="REPLACE_WITH_RESOLVED_CLAUDE_PLUGIN_DATA\*" />
    </Conditions>
  </FilePathRule>
</RuleCollection>
```

A user-writeable path rule is a deliberate trade-off (a user could drop other scripts
there). If your policy forbids user-writeable path rules, prefer **hash** rules: the two
pinned downloads are hash-verified above, so generate publisher-independent hash rules from
them with `New-AppLockerPolicy -RuleType Hash`.

### WDAC / App Control (paste-ready rule generation)

WDAC `FilePath` rules against a user-writeable directory carry the same caveat, so for WDAC
prefer **hash** rules generated from the actual on-disk components, then merge into your
base policy:

```powershell
# Generate hash-based allow rules for the plugin's components, then merge into your policy.
$scan = @($env:CLAUDE_PLUGIN_ROOT, $env:CLAUDE_PLUGIN_DATA) | Where-Object { $_ }
$rules = $scan | ForEach-Object {
    New-CIPolicyRule -DriverFilePath (Get-ChildItem -LiteralPath $_ -Recurse -File) -Level Hash
}
New-CIPolicy -FilePath .\powershell-lsp-allow.xml -Rules $rules -UserPEs
# Then: Merge-CIPolicy / ConvertFrom-CIPolicy and deploy per your WDAC workflow.
```

Hash rules must be regenerated when the pinned versions are bumped (the SHA-256 changes).
The pinned-download hashes in the table above let you confirm the bytes you are allow-listing.

### Reading App Control / Defender block events

If a component is blocked, the relevant Windows event tells you which control and whether
it was enforced or audit-only:

```powershell
Get-ExecutionPolicy -List
$ExecutionContext.SessionState.LanguageMode
# App Control / WDAC: 3077 = enforced block, 3076 = audit-mode flag
Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-CodeIntegrity/Operational'; Id = 3076, 3077 } -MaxEvents 20
# Defender ASR: 1121 = block, 1122 = audit
Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Windows Defender/Operational'; Id = 1121, 1122 } -MaxEvents 20
```

## Honest degradation (the L3 behavior)

When a security control blocks bootstrap, the plugin does not crash silently and does not
try to circumvent the control. Its SessionStart banner **names the most likely control on
positive evidence only** -- ExecutionPolicy (Group Policy scope), Constrained Language
Mode, App Control / WDAC (CodeIntegrity 3076/3077 naming a plugin component), Defender ASR
(1121/1122), or Smart App Control -- with calibrated confidence and an admin-facing
remediation, and an honest "here is how to check" pointer when nothing is positively
identified. The classifier (`scripts/lib/security-classifier.ps1`) **detects and explains
only**; it never bypasses, disables, or modifies any control. See README
"Security-control blocks on managed Windows" for the full detection table.

## Governance and sustainability (adoption risk, stated honestly)

- **Single-maintainer bus factor.** This project is currently maintained by **one person**
  (Mike Andersen). That is a real **adoption risk**: a single point of failure for
  reviews, security response, and dependency bumps. It is named here rather than hidden.
  Mitigations in place: the pinned + hash-verified dependencies, the gate-validated release
  pipeline, the SBOM + provenance, and a documented disclosure policy
  ([SECURITY.md](./SECURITY.md)) keep the project auditable and reproducible by others even
  with one maintainer. Organizations with a hard bus-factor bar should weigh this
  accordingly.
- **License: GPLv3.** The plugin is [GPL-3.0-or-later](https://spdx.org/licenses/GPL-3.0-or-later.html),
  forward-only from v1.6.1; prior releases (v1.0 through v1.6.0) remain under their original
  MIT grant, which is irrevocable. See [LICENSE](./LICENSE) and [README.md](./README.md#license).
- **Contributions / DCO-CLA.** There is no CLA. Contributions are accepted under the
  project's GPLv3 license; contributors are asked to certify origin via a **Developer
  Certificate of Origin** sign-off (`git commit -s`). No copyright assignment is requested
  or required.
- **Relicensing.** The maintainer does not collect a CLA and therefore **cannot
  unilaterally relicense third-party contributions** away from GPLv3; any relicensing would
  require the agreement of all copyright holders. This is a deliberate guarantee to
  adopters that the open-source grant cannot be quietly revoked.

## Honest limits

- **Scripts are NOT Authenticode-signed** -- a deliberate choice for a git-distributed plugin;
  release tags ARE keyless-signed via Sigstore (see [Signing posture](#signing-posture)).
- **NOT independently security-audited.** No third party has performed a security audit of
  this code. Treat this document and the open source as the basis for your own review.
- Claims in this document are verifiable against the named files and the published release
  artifacts; nothing here asserts a control, signature, or audit the project does not have.
