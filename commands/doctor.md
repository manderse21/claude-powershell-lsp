---
description: Run the powershell-lsp preflight doctor -- a report-only health check of the PowerShell diagnostics plugin, with a named fix for anything wrong.
argument-hint: "[--probe-native-serve]"
allowed-tools: Bash(pwsh:*)
---

Run the powershell-lsp preflight doctor and report what it found.

The doctor is **report-only**: it never downloads, repairs, runs the bootstrap, or starts,
restarts, or stops anything. Run it exactly as given below and do not "fix" anything on the
user's behalf without asking first.

If `$ARGUMENTS` contains `--probe-native-serve`, append `-ProbeNativeServe` to the command. That
adds the opt-in native-serve **removability** probe, which costs a PSES cold start plus a bounded
init wait -- so only add it when asked.

```
pwsh -NoLogo -NoProfile -File "$env:CLAUDE_PLUGIN_ROOT/scripts/doctor.ps1"
```

Then summarize for the user:

- The report opens with a `version:` header line above the check table. It is always present, even
  when every check is UNKNOWN, and it is not a check -- it carries no status and is not in the
  counts. Include it whenever the user is reporting a problem or asking for support.
- Lead with the summary line's counts.
- If any check is **FAIL**, quote its component, its detail, and its `fix:` line. A FAIL is the
  only thing that sets a non-zero exit code.
- If any check is **UNKNOWN**, say plainly that it could not be determined and why -- an UNKNOWN is
  never a failure, and the most common cause is running outside an enabled Claude Code session, so
  the plugin data directory is not visible.
- If everything passes, say so in one line rather than restating all of it.

Two checks are worth calling out when they are not PASS, because they answer questions the others
structurally cannot:

- **Test diagnostic observed end-to-end** -- the only check that proves diagnostics are actually
  being produced rather than merely installed. A FAIL here means an edit would read as "analyzed,
  clean" when nothing was analyzed.
- **Active ruleset surface** -- which rules are really applied here, and which config layer won.
  This is what explains "I set `ruleset = base` and still see nothing new" (usually a repo-local
  `PSScriptAnalyzerSettings.psd1` legitimately winning).
