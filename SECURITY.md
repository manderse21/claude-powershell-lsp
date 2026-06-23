# Security Policy

How to report a security vulnerability in `powershell-lsp`, what is in scope, and what to
expect after you report. For the full trust and supply-chain posture (downloads, pinned
hashes, SBOM, provenance, signing status, allow-listing), see [TRUST.md](./TRUST.md).

## Supported versions

Security fixes are issued for the **latest released version only**. This is a
single-maintainer project (see [TRUST.md](./TRUST.md#governance-and-sustainability-adoption-risk-stated-honestly));
backporting to older releases is not promised. Upgrade to the latest release to receive
security fixes.

| Version                         | Supported          |
|---------------------------------|--------------------|
| Latest release (1.x)            | Yes                |
| Any earlier release             | No (please upgrade)|

## Reporting a vulnerability

**Please do NOT open a public GitHub issue for a security vulnerability.** Public issues
disclose the problem before a fix is available.

Report privately through **GitHub Private Vulnerability Reporting**, which is enabled on
this repository:

- Go to **https://github.com/manderse21/claude-powershell-lsp/security/advisories/new**
  (the repository **Security** tab -> **Report a vulnerability**), and file a private
  advisory. Only the maintainer can see it; we can discuss and fix it before any public
  disclosure.

When you report, please include as much as you can:

- a description of the vulnerability and its impact;
- the affected version (and platform / PowerShell host, if relevant);
- step-by-step reproduction, a proof-of-concept, or the offending code path;
- any suggested remediation.

## Scope

**In scope** -- the code in this repository and what it does at runtime:

- the plugin hook scripts (`scripts/*.ps1`) and shared library (`scripts/lib/*.ps1`);
- the first-run bootstrap: the download, **SHA-256 verification**, and vendoring of the
  pinned dependencies (`ensure-pses.ps1`, `ensure-pssa.ps1`);
- the per-session daemon, its named-pipe IPC, and the diagnostics surface;
- the release tooling (SBOM generation, provenance) under `release/`.

**Out of scope** -- report these to their own projects:

- **PowerShell Editor Services** and **PSScriptAnalyzer** themselves (Microsoft
  open-source dependencies this plugin downloads). Report upstream:
  [PowerShellEditorServices](https://github.com/PowerShell/PowerShellEditorServices/security)
  and [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer/security). A flaw in
  how *this plugin downloads, verifies, or invokes* them is in scope; a flaw *inside* them
  is not.
- **Claude Code** itself and its plugin/hook mechanism. Report to the
  [claude-code](https://github.com/anthropics/claude-code/issues) project.
- Findings that require an already-compromised local machine or administrator access (the
  plugin runs with the user's own privileges and trusts the local environment).

## What to expect

- **Acknowledgement:** best-effort within **7 days**. This is a solo-maintained project, so
  response is best-effort, not a contractual SLA.
- **Triage and fix:** once confirmed, a fix is prioritized over feature work. The timeline
  depends on severity and complexity; we will keep you updated in the private advisory.
- **Disclosure:** we prefer **coordinated disclosure** -- we will agree on a disclosure
  date with you, publish the fix in a release, and credit you in the advisory and CHANGELOG
  unless you ask to remain anonymous.
- **No bug bounty:** there is no monetary reward program. Credit and our thanks are what we
  can offer.
