# Third-Party Licenses

`powershell-lsp` is licensed under **Apache-2.0** (see [LICENSE](./LICENSE), and [NOTICE](./NOTICE)
for the attribution notice Apache-2.0 section 4(d) asks redistributors to carry). It relies on two
external components that it **downloads at install time** -- it does **not** bundle or redistribute
their source in this repository or in its plugin release. On first run they are fetched into the
plugin's data directory (`CLAUDE_PLUGIN_DATA`) from their official sources and remain under their own
licenses; this project does not modify or relicense them.

Both components are **MIT-licensed**, which is compatible with Apache-2.0. Their license/notice
files are preserved intact in the installed bundle (asserted by an integration test).

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

## Notes

- MIT-licensed components may be combined with Apache-2.0 software (both are permissive licenses,
  and MIT is Apache-2.0-compatible). This file documents that combination and preserves attribution.
- The plugin is a **downloader**, not a redistributor: each install fetches these components from
  their official sources, where the upstream MIT notices are included; `ensure-pses` / `ensure-pssa`
  preserve those notices in the installed bundle (an integration test asserts they survive
  extraction).
- This is the standard mechanical attribution for downloaded dependencies; it is **not legal
  advice**. A human/legal review of the exact license texts and attribution is advisable for a
  serious public release.
