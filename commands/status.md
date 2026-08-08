---
description: One-screen powershell-lsp health status -- every preflight check as a single line, no fix-list prose.
allowed-tools: Bash(pwsh:*)
---

Show the compact powershell-lsp health status.

This is the same preflight doctor as `/powershell-lsp:doctor`, rendered short: one line per check
plus the summary, with the per-check detail and remediation omitted. It runs the identical checks
and produces the identical statuses and exit code -- only the presentation differs. Like the
doctor, it is **report-only** and changes nothing.

```
pwsh -NoLogo -NoProfile -File "$env:CLAUDE_PLUGIN_ROOT/scripts/doctor.ps1" -Summary
```

The first line is followed by a `version:` header naming the installed plugin build. It always
renders, it is not one of the checks, and it is the line to keep when the output is pasted into a
bug report.

Report the output as-is -- it is already a summary, so do not summarize it further. Add at most
one sentence of interpretation:

- All PASS -- say the plugin is healthy.
- Any UNKNOWN and no FAIL -- say it is healthy as far as it could tell, and name what it could not
  determine. UNKNOWN is never a failure.
- Any FAIL -- name the failing check and point the user at `/powershell-lsp:doctor` for that
  check's detail and its specific fix.
