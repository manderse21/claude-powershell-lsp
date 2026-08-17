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
> transmitted** (see [docs/dogfood.md](docs/dogfood.md)). Optional `enableStats`
> (default **off**) appends local timing lines. Neither leaves the machine.

## Why ExecutionPolicy Bypass appears in every hook entry point

Reviewing the manifest, you will find `-ExecutionPolicy Bypass` on **every** entry point Claude
Code launches -- all four of them, and there are no others:

| Entry point | Declared at | What it launches |
|-------------|-------------|------------------|
| `lspServers` (the LSP server command) | `.claude-plugin/plugin.json:140` | `scripts/pses-serve-shim.ps1` |
| `SessionStart` hook | `.claude-plugin/plugin.json:162` | `scripts/session-start.ps1` |
| `PostToolUse` hook | `.claude-plugin/plugin.json:173` | `scripts/lsp-client.ps1` |
| `SessionEnd` hook | `.claude-plugin/plugin.json:183` | `scripts/session-end.ps1` |

(The `lspServers` entry splits the flag across two JSON array elements -- `"-ExecutionPolicy",
"Bypass",` -- so a `-ExecutionPolicy\s+Bypass` search undercounts the manifest at 3. The true
figure is 4.)

**Why it is there.** The flag is a **launcher argument for the plugin's own scripts**, not a
change to your machine. `-ExecutionPolicy Bypass` applies to that one `pwsh` process only: it sets
no policy, writes no registry key, and survives nothing past the process. Without it, the
plugin's own tracked, reviewable scripts -- which arrive unsigned over `git clone`, exactly as
this repository ships them -- would refuse to start on any host whose *user* or *process*
ExecutionPolicy is `Restricted` / `AllSigned` / `RemoteSigned`, which is the common default. The
result would not be "more secure"; it would be a plugin that silently never runs.

**What it is NOT, and cannot be.** Three properties bound it, each independently checkable:

- **It cannot override a machine-level or Group Policy control.** When ExecutionPolicy is set by
  `MachinePolicy` or `UserPolicy` (GPO), a command-line `-Bypass` is **ignored** by PowerShell
  itself. Same for Constrained Language Mode, WDAC / App Control, Defender ASR, and Smart App
  Control: none of them look at this flag. On a genuinely locked-down estate the plugin does not
  quietly win -- it fails, and says so.
- **It is scoped to the plugin's own files.** Every invocation is
  `-File "${CLAUDE_PLUGIN_ROOT}/scripts/<name>.ps1"`. Nothing in this repository runs *your*
  scripts under Bypass, and no `Set-ExecutionPolicy` call exists anywhere in the tree.
- **The one policy-aware component in the plugin exists to explain blocks, never to defeat them.**
  `scripts/lib/security-classifier.ps1` reads control state (execution policy, language mode,
  CodeIntegrity / Defender event logs, the SAC registry value) purely to **name** what blocked a
  bootstrap and print the legitimate admin remediation. Its contract is stated in
  [ARCHITECTURE.md](./ARCHITECTURE.md) as, verbatim, "**Never bypasses a control.**" It is the
  strongest evidence available on this point: the only code that *understands* these controls is
  code written to diagnose them.

This is the same posture as the "No security-control circumvention" bullet above, stated where the
flag itself is what alarms a reviewer. If your estate requires signed scripts, the allow-listing
path -- paste-ready WDAC / AppLocker rules -- is in
[Allow-listing on managed Windows](#allow-listing-on-managed-windows) below; that is a deliberate
administrator action, which is the only way this plugin ever runs under such a control.

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

Both are Microsoft open-source projects under the MIT license (MIT is Apache-2.0-compatible; see
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

### Where the bytes may come from (sources are transport, pins are trust)

The URLs above are the **default** source, not the only permitted one. An administrator may
point the plugin at an internal mirror or at artifacts pre-staged on local disk, and one
source has always existed for CI: a pinned-`.nupkg` cache directory
(`POWERSHELL_LSP_PSSA_CACHE`). Full resolution order, per artifact, first hit wins:

| Order | Layer | Configured by |
|---|---|---|
| 1 | Internal HTTPS mirror | `POWERSHELL_LSP_ARTIFACT_MIRROR_BASE` |
| 2 | Pre-staged local bundle | `POWERSHELL_LSP_ARTIFACT_BUNDLE_DIR` |
| 3 | The default download in the table above (for PSScriptAnalyzer, via the `POWERSHELL_LSP_PSSA_CACHE` cache when set) | -- |

**This adds no trust and removes none.** Whichever layer supplies an artifact, it is verified
against the **same SHA-256 pin** by the same `Test-PinnedFileHash` call before it is used. The
pins in the two `ensure-*` scripts remain the **only trust root**; a mirror, a bundle, and a
cache are transport, and none of them can become a trust root. Three properties make that
checkable rather than merely asserted:

- **A pin mismatch on any layer fails closed, and never falls through to another layer.** A
  tampered mirror artifact fails exactly as a tampered download does. Falling through would let
  anyone controlling one layer force a downgrade onto the next, and would turn a tamper signal
  into a retry. The failure banner **names the layer** that produced the bad bytes.
- **Nothing in a bundle is a trust input.** The bundle's `MANIFEST.txt` documents the pins for a
  human; the bootstrap verifies against its own copy of them and never reads the manifest to
  decide anything. A manifest that could override a pin would be precisely the shortcut this
  design refuses.
- **With no source configured, behavior is byte-for-byte unchanged** -- no extra network call
  and no extra disk read. The "no network access at all after first-run bootstrap" property
  above is unaffected in every configuration: these layers change *where* the one-time
  first-run fetch may be satisfied from, never *whether* later sessions reach the network.

The one acquisition route these pins do **not** gate is the `Save-Module` fallback named just
above, which rests on the Gallery's publisher/catalog integrity instead. It is reported
distinctly by `/doctor` (as `gallery-fallback`) rather than being presented as a pinned source.

**Offline installation is two independently verifiable artifacts, not one.** Every release
publishes `powershell-lsp-airgap-<version>.zip` -- the two pinned dependencies plus a manifest of
their pins -- covered by the same SLSA provenance attestation as the source archive. It
deliberately does **not** contain the plugin's own source, which is already published as its own
attested asset; bundling a second copy would create two attested paths to the same bytes. An
air-gapped administrator therefore transfers **the plugin source** (a clone, or
`powershell-lsp-<version>.tar.gz`) **and this bundle**, verifying each:

```
gh attestation verify powershell-lsp-airgap-<version>.zip --repo manderse21/claude-powershell-lsp
```

Setup, including how to stage a bundle fleet-wide, is in
[docs/configuration.md](docs/configuration.md#offline-and-air-gapped-installation).

## Supply-chain artifacts: SBOM + build provenance

Every tagged release publishes, on the GitHub Release:

- A **CycloneDX 1.5 SBOM** (`powershell-lsp-<version>.cdx.json`), covering the plugin and
  both pinned downloaded dependencies. It is generated by `release/New-PluginSbom.ps1`,
  which reads the pins straight from the `ensure-*` scripts, so the SBOM can never disagree
  with what the tool actually downloads.
- A **SLSA build-provenance attestation** over both the source archive
  (`powershell-lsp-<version>.tar.gz`, a `git archive` of the exact tagged tree) and the
  SBOM, produced by `actions/attest` with GitHub OIDC. (Through v1.31.1 this used
  `actions/attest-build-provenance`; upstream turned that into a thin composite wrapper
  around `actions/attest` and recommends the wrapped action for new work, so the pipeline
  now calls it directly. The predicate, the subjects and the OIDC identity are unchanged --
  `actions/attest` auto-generates SLSA build provenance whenever no SBOM or predicate input
  is supplied, which is exactly how this pipeline calls it.)

Verify the provenance of a downloaded artifact:

```
gh attestation verify powershell-lsp-<version>.tar.gz --repo manderse21/claude-powershell-lsp
```

The release pipeline is **maintainer-triggered and gate-validated** (merged to `main`,
green on every CI leg, version-locked) and cuts the tag itself on the validated commit.
See [docs/RELEASING.md](./docs/RELEASING.md). This document does not modify any of those
generators; it points at what they already produce.

## Every external GitHub Action is pinned to an immutable commit SHA

The workflows that build, scan and release this project are themselves a supply chain, and
they are pinned the same way the downloaded dependencies above are: to something an
upstream owner cannot move.

**The rule.** Every external action reference in every workflow is written as a full
40-character upstream **commit SHA**, with the release it resolves to in a comment on the
same line:

```yaml
      - name: Checkout
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
```

A tag -- `@v7`, or even `@v7.0.1` -- is a *label*, and the upstream owner can repoint it at
different code without anything changing in this repository. A commit SHA cannot be
repointed. The trailing comment is not decoration: Dependabot's `github-actions` ecosystem
rewrites the SHA and that comment together, so it is what keeps a pin auditable by a human
and bumpable by a bot instead of rotting into an opaque, permanently stale hex string.

**Three independent enforcements, so this cannot quietly regress:**

| Layer | What it does | Where |
|---|---|---|
| Repository policy | GitHub itself refuses to run a workflow step whose action is not SHA-pinned (`sha_pinning_required = true` on the repository's Actions permissions) | repository settings |
| CI gate | A Pester block **discovers** every workflow and composite-action YAML in the tree, extracts every `uses:` line, and fails on any external reference that is not a 40-hex SHA with a version comment | `tests/PowerShellLsp.ActionPinning.Tests.ps1` |
| Dependency updates | Dependabot proposes SHA bumps weekly, labelled `dependencies` / `github-actions` | `.github/dependabot.yml` |

Local actions (`uses: ./...`) are exempt -- they resolve inside this repository at the
commit already being run, so there is no third-party mutability to pin.

**This supersedes the project's earlier convention.** Until 2026-08-14 the workflows pinned
by major-version tag and only the SARIF upload -- the one step holding a write scope -- was
SHA-pinned as a deliberate exception. Two earlier records (dispatches 000042 and 000064)
booked full SHA pinning as a defensible-but-deferred hardening. It is no longer deferred;
it is the convention, and the exception now runs the other way: nothing may use a movable
ref.

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
  either allow-list it by path or hash (below) or sign it with your own code-signing certificate
  (see [Sign it yourself](#sign-it-yourself-the-org-certificate-paved-path), which is the path this
  project recommends for such an estate); it tells you which control blocked it (see
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

## Sign it yourself: the org-certificate paved path

The decline above is a decision about **who signs**, not a dead end. A managed estate whose
ExecutionPolicy is `AllSigned`, or whose WDAC / AppLocker policy trusts only signed code, will
not run unsigned scripts -- and a command-line `-ExecutionPolicy Bypass` is **ignored** when the
policy comes from Group Policy, so nothing in the plugin gets around it (see
[Why ExecutionPolicy Bypass appears in every hook entry point](#why-executionpolicy-bypass-appears-in-every-hook-entry-point)).
The answer for such an estate is not a publisher certificate it has no reason to trust. It is the
estate signing with **its own** code-signing certificate, which its policy already trusts. The
plugin ships that as one command:

```
# By thumbprint, from Cert:\CurrentUser\My or Cert:\LocalMachine\My:
pwsh -File scripts/sign-plugin.ps1 -Thumbprint <your-code-signing-thumbprint>

# Or from a PFX:
pwsh -File scripts/sign-plugin.ps1 -PfxPath C:\certs\org-signing.pfx -PfxPassword (Read-Host -AsSecureString)

# Report the current state and change nothing:
pwsh -File scripts/sign-plugin.ps1 -VerifyOnly
```

Point it at an **installed** copy with `-PluginRoot` (the plugin cache path `CLAUDE_PLUGIN_ROOT`
resolves to) when you are signing from an admin workstation rather than in place.

**What it covers.** Every `.ps1` and `.psm1` under `scripts/`, **enumerated live from the tree it
is run against** rather than from a list in the script -- the executable surface, which is exactly
the set the four manifest entry points launch or that those entry points dot-source and import. It
signs, then **re-reads every file with `Get-AuthenticodeSignature` and prints that sweep**, and it
**fails closed** on anything that does not come back `Valid`. The read-back is the proof and the
signing call is not: `Set-AuthenticodeSignature` does not raise an error for a file it declines to
sign, and returns the same status for a real signature as for a silent no-op.

**What it does NOT cover, and must not be read as covering:**

- **The downloaded components under `CLAUDE_PLUGIN_DATA`** -- the PSES bundle and the vendored
  PSScriptAnalyzer. Those are third-party artifacts this project does not author and will not
  re-sign; they are covered by the **pinned SHA-256 hashes** described in
  [What it downloads](#what-it-downloads-pinned-versions-and-pinned-hashes). Script signing and
  artifact pinning are **different layers and stay different**: a signature says who vouched for
  the bytes, a pin says the bytes are the exact ones this repository vouched for. Signing the
  scripts changes neither the pins nor what they guarantee.
- **`.psd1` data files.** `about_Signing` lists `.psd1` among the types PowerShell will *validate*
  a signature on, which is not the same as the set it *refuses to load unsigned*. Measured under
  process-scope `AllSigned` on Windows PowerShell 5.1, an unsigned `.psd1` loads through every
  path this plugin uses -- `Import-PowerShellDataFile` (the shipped rulesets),
  `Import-LocalizedData`, and `Import-Module` of a manifest. What `AllSigned` blocks is the
  `.psm1` or `.ps1` a manifest chains to through `RootModule` / `ScriptsToProcess`, and those
  **are** in the covered surface.
- **The plugin after its next upgrade.** An upgrade replaces these files with unsigned copies.
  Re-run the command after every upgrade; `-VerifyOnly` is the check.

**Two operational notes.** An air-gapped estate signs with `-NoTimestamp`; the trade-off is real
and worth stating -- without a countersignature the signatures become invalid the day the signing
certificate expires, so the estate re-signs on certificate renewal rather than only on upgrade.
And signing **changes the files' bytes**, so any hash-based allow rule you generated below must be
regenerated afterwards -- or replaced with a publisher rule, which is the simpler policy once the
files carry your own signature.

## Allow-listing on managed Windows

Because the plugin's scripts are deliberately not Authenticode-signed as shipped (see
[Signing posture](#signing-posture)), allow-list it by **path** or by **hash** -- or sign it with
your own certificate first (see
[Sign it yourself](#sign-it-yourself-the-org-certificate-paved-path)) and allow-list by publisher.
Its two
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
- **License: Apache-2.0.** The plugin is [Apache-2.0](https://spdx.org/licenses/Apache-2.0.html),
  forward-only from v1.32.0. **Every previously published release keeps the license it
  shipped under, and those grants are irrevocable:** v1.6.1 through v1.31.2 remain
  `GPL-3.0-or-later`, and v1.0 through v1.6.0 remain under their original MIT grant. See
  [LICENSE](./LICENSE), [NOTICE](./NOTICE), and [README.md](./README.md#license).
- **What the move to Apache-2.0 changes.** It adds an **explicit patent grant** (section 3) and
  the NOTICE-propagation mechanics (section 4(d)) that enterprise license allow-lists are written
  around. It also drops copyleft: a downstream fork is no longer obliged to publish its changes.
  Both directions are stated so an adopter can weigh them, rather than only the favourable one.
- **Contributions / DCO-CLA.** There is no CLA. Contributions are accepted under the
  project's Apache-2.0 license; contributors are asked to certify origin via a **Developer
  Certificate of Origin** sign-off (`git commit -s`). No copyright assignment is requested
  or required.
- **Relicensing.** The maintainer does not collect a CLA and therefore **cannot
  unilaterally relicense third-party contributions**; any such relicensing would require the
  agreement of all copyright holders. The 2026-08-16 move from `GPL-3.0-or-later` to Apache-2.0
  was made by the **sole copyright holder** over work he authored, which is why it needed no
  such agreement -- the same mechanics as the MIT-to-GPLv3 move at v1.6.1. It is a
  forward-only grant change: it adds a new grant for future releases and revokes none of the
  grants already made.

## Honest limits

- **Scripts are NOT Authenticode-signed as shipped** -- a deliberate choice for a git-distributed
  plugin; release tags ARE keyless-signed via Sigstore (see [Signing posture](#signing-posture)).
  An estate that requires signed scripts signs them with its own certificate in one command (see
  [Sign it yourself](#sign-it-yourself-the-org-certificate-paved-path)); that is your signature on
  your machines, and this project still asserts no publisher identity of its own.
- **NOT independently security-audited.** No third party has performed a security audit of
  this code. Treat this document and the open source as the basis for your own review.
- **The published correctness corpus attests to diagnostics, not to security.** The corpus
  ([docs/corpus.md](docs/corpus.md)) is a measured, reproducible claim that the findings this tool
  *reports* are correct on a curated sample -- nothing more. It does **not** attest that the plugin
  is safe to run, that its supply chain is sound, or that any rule set is complete; those are the
  subject of this document and of the [threat model](docs/roadmap-ii/THREAT-MODEL.md). Its own
  provenance audit is mechanical, not legal advice, and its stated limits travel with it rather
  than being summarized away.
- Claims in this document are verifiable against the named files and the published release
  artifacts; nothing here asserts a control, signature, or audit the project does not have.
