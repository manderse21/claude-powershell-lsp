# Pinned versions

The two downloaded components, where each pin lives, and why the CI cache never becomes a trust
shortcut. Summarized in [README, Pinned versions](../README.md#pinned-versions); this page is the
full text. The hash table itself is in [TRUST.md](../TRUST.md).

| Component         | Version  | Pinned in                 | Source                                  |
|-------------------|----------|---------------------------|-----------------------------------------|
| PSES              | `v4.6.0` | `scripts/ensure-pses.ps1` (`$PsesTag`)     | GitHub release `PowerShellEditorServices.zip` |
| PSScriptAnalyzer  | `1.25.0` | `scripts/ensure-pssa.ps1` (`$PssaVersion`) | PowerShell Gallery                      |

To bump either, change the single pin variable named above and start a fresh session (the
ensure-step re-vendors at the new version, keyed by a per-version marker). See
[CHANGELOG](../CHANGELOG.md#versioning) for how a bump maps to SemVer.

In CI the pinned PSScriptAnalyzer `.nupkg` is cached (keyed by the pinned version **and**
SHA-256), but the integrity pin stays load-bearing on every path: a restored `.nupkg` runs through
the same SHA-256 verification as a fresh download, and a poisoned or stale entry fails closed. The
cache is a transport optimization, never a trust shortcut.
