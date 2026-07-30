---
description: Scan a path with the PowerShell diagnostics engine -- the same analyzer the edit hook uses, over a whole file or directory, as text or SARIF.
argument-hint: "<path> [text|sarif] [--fail-on warning] [--no-recurse]"
allowed-tools: Bash(pwsh:*)
---

Run an explicit whole-path PowerShell scan with `scripts/lsp-scan.ps1`.

This is the **same** diagnostics engine the PostToolUse edit hook uses -- same warm daemon, same
pinned PSScriptAnalyzer -- run over a path you choose instead of the file being edited. Use it when
the user wants findings for code nobody is currently editing: the live hook only analyzes files
Claude edits, and there is no background workspace sweep.

Arguments in `$ARGUMENTS`:

- The **first** argument is the path -- a single `.ps1` / `.psm1` / `.psd1`, or a directory. If the
  user did not give one, ask before scanning anything; do not guess a path and do not default to
  the repository root.
- `text` or `sarif` selects the format. Default to **`text`** here, because the output is being read
  in conversation. Use `sarif` only when asked, and then write it to a file with `-OutputPath`
  rather than dumping the JSON into the transcript.
- `--fail-on <level>` maps to `-FailOn <level>` (`note` / `warning` / `error`).
- `--no-recurse` maps to `-NoRecurse` (top level of a directory only).

```
pwsh -NoLogo -NoProfile -File "$env:CLAUDE_PLUGIN_ROOT/scripts/lsp-scan.ps1" <path> -Format text
```

The first run in a fresh environment bootstraps PSES and the pinned analyzer, so it can take
noticeably longer than later runs. A directory recurses by default; non-PowerShell files are
skipped and counted.

Read the exit code and say what it means -- do not report a scan as clean without checking it:

- `0` -- completed (clean, or under the `-FailOn` threshold).
- `2` -- the `-FailOn` threshold was met. Findings exist at or above that level.
- `3` -- usage error: no PowerShell host, or the path does not exist.
- `4` -- **scan incomplete**: the analyzer was not reachable. This is the important one. An
  unanalyzed file is never reported as a clean one, so do NOT tell the user their code is clean on
  a `4` -- say the scan could not complete, and suggest `/powershell-lsp:doctor`.

Then summarize the findings by rule and severity, and offer to fix them -- but do not edit files
unless the user asks.
