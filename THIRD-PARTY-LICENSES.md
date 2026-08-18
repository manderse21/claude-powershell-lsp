# Third-Party Licenses

`powershell-lsp` is licensed under **Apache-2.0** (see [LICENSE](./LICENSE), and [NOTICE](./NOTICE)
for the attribution notice Apache-2.0 section 4(d) asks redistributors to carry). It relies on two
external components that it **downloads at install time** -- it does **not** bundle or redistribute
their source in this repository or in its plugin release. On first run they are fetched into the
plugin's data directory (`CLAUDE_PLUGIN_DATA`) from their official sources and remain under their own
licenses; this project does not modify or relicense them.

Both components are **MIT-licensed**, which is compatible with Apache-2.0. Their license/notice
files are preserved intact in the installed bundle (asserted by an integration test).

One further third-party file **is** committed here -- the
[SARIF 2.1.0 JSON Schema](#sarif-210-json-schema), a test fixture under different (OASIS) terms.
It is listed below so this file covers everything third-party in the tree, not only what is
downloaded.

## PowerShell Editor Services (PSES)

| | |
|---|---|
| Copyright | (c) Microsoft Corporation |
| License | MIT |
| Source | <https://github.com/PowerShell/PowerShellEditorServices> |
| License text | <https://github.com/PowerShell/PowerShellEditorServices/blob/main/LICENSE> |
| Fetched by | `scripts/ensure-pses.ps1` (pinned via `$PsesTag`) from the project's GitHub releases |
| Notices in the installed bundle | `LICENSE` + `NOTICE.txt`, copied from the release distribution root into `CLAUDE_PLUGIN_DATA/PowerShellEditorServices/` |

## PSScriptAnalyzer

| | |
|---|---|
| Copyright | (c) Microsoft Corporation |
| License | MIT |
| Source | <https://github.com/PowerShell/PSScriptAnalyzer> |
| License text | <https://github.com/PowerShell/PSScriptAnalyzer/blob/master/LICENSE> |
| Fetched by | `scripts/ensure-pssa.ps1` (pinned via `$PssaVersion`) from the PowerShell Gallery |
| Notices in the installed bundle | `LICENSE` + `ThirdPartyNotices.txt`, retained in the vendored module under `CLAUDE_PLUGIN_DATA/modules/PSScriptAnalyzer/<version>/` |

## SARIF 2.1.0 JSON Schema

**Not downloaded, and not part of the plugin release.** Unlike the two components above, this one
is **committed in this repository** -- so it is the single item here that this project genuinely
redistributes. It is a **test fixture only**: it is never loaded, shipped, or executed by the
plugin runtime.

| | |
|---|---|
| Copyright | OASIS Open |
| License | OASIS IPR Policy, **RF on RAND Terms Mode** |
| License text | <https://www.oasis-open.org/policies-guidelines/ipr> |
| Source | <https://github.com/oasis-tcs/sarif-spec> (SARIF 2.1.0 is an OASIS Standard) |
| Retrieved from | <https://json.schemastore.org/sarif-2.1.0.json> (SchemaStore), 2026-06-28 |
| In-tree location | `tests/sarif/sarif-2.1.0.json`, vendored unmodified |
| Full attribution | [`tests/sarif/NOTICE.md`](./tests/sarif/NOTICE.md) -- authoritative |

It is vendored so that `tests/PowerShellLsp.SarifScan.Tests.ps1` can validate the SARIF this plugin
emits against the official schema **offline**, on every CI leg -- no network egress and no new flake
surface, the same discipline as the pinned, hash-verified dependencies above.

**It is NOT relicensed under this project's Apache-2.0 license**, which covers the plugin's own
source. The schema retains its upstream OASIS terms. `tests/sarif/NOTICE.md` is the authoritative
statement of those terms; this entry surfaces it here rather than restating it.

## Notes

- MIT-licensed components may be combined with Apache-2.0 software (both are permissive licenses,
  and MIT is Apache-2.0-compatible). This file documents that combination and preserves attribution.
- **For its runtime dependencies the plugin is a downloader, not a redistributor:** each install
  fetches PSES and PSScriptAnalyzer from their official sources, where the upstream MIT notices are
  included; `ensure-pses` / `ensure-pssa` preserve those notices in the installed bundle (an
  integration test asserts they survive extraction). The one thing this repository does carry is the
  SARIF schema above, which is a **test fixture** and ships in no release artifact.
- This is the standard mechanical attribution for downloaded dependencies; it is **not legal
  advice**. A human/legal review of the exact license texts and attribution is advisable for a
  serious public release.
