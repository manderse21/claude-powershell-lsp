# The preflight doctor -- what it checks, and what it refuses to do

What `/powershell-lsp:doctor` verifies, why three of its checks exist, and why it is report-only.
Summarized in [README, Troubleshooting](../README.md#troubleshooting); this page is the full text.
For symptom-by-symptom fixes see [troubleshooting.md](troubleshooting.md).

**Start with the preflight doctor.** It checks prerequisites and bootstrap health in one place and
prints a named fix-list. Inside an enabled session use the slash command; the raw script is the
form that still works **outside** a session, where the slash command does not exist:

```
/powershell-lsp:doctor          # inside an enabled Claude Code session
pwsh -File scripts/doctor.ps1   # out-of-session (several checks then report UNKNOWN)
```

Two switches exist for machines rather than people. `-Json` renders the same run as a structured
envelope -- a `schemaVersion`, a one-word `status` from `HEALTHY` / `DEGRADED` / `UNHEALTHY` /
`UNPROVEN`, the resolved versions, the summary counts and the check array -- over the same seam,
so the verdicts and the exit code are identical to a normal run. `-RequireProven` is an **opt-in**
second predicate that exits **2** when nothing failed but at least one check is UNKNOWN, which is
how a CI job asserts "everything was actually established" rather than "nothing failed". Without
the switch the exit code is unchanged: **exit 0 when no check FAILED** (passes and honest unknowns
are not failures), exit 1 when at least one check failed. The derivation rule for `status` and the
full exit-code table live in [`commands/doctor.md`](../commands/doctor.md).

It verifies, in order: PowerShell 7 (`pwsh`) is present and new enough; the plugin is enabled; the
PSES bundle and PSScriptAnalyzer finished bootstrapping; the first-run download hosts are
reachable; the **warm per-session daemon** is alive and answering on its named pipe; **which rule
set is actually active** here and which config layer won it; whether a **real diagnostic is
observed end-to-end**; and whether **native navigation** is on. Each check reports `PASS`, a
specific failure with the fix, or an honest `UNKNOWN` when it genuinely cannot determine (run
outside a Claude Code session it cannot see the plugin data directory, so several checks report
`UNKNOWN`; run it from inside an enabled session for a definitive result).

The last three answer questions the others structurally cannot. The daemon check's liveness ping is
answered *without* touching the language server, so a daemon can be alive, answering, and analyzing
nothing -- the **end-to-end check** closes that by sending a synthetic file with a deliberate defect
through the same warm daemon your edits use and requiring the expected finding back. It is the one
check that can report a `FAIL` for a *settled* analysis that produced nothing, because "analyzed,
clean" when nothing was analyzed is the failure this plugin exists to prevent. The probe writes only
to a temp directory, never starts a daemon, and leaves nothing behind. The **active ruleset** check
explains the most common confusion -- you set `ruleset = base`, see nothing new, and a repo-local
`PSScriptAnalyzerSettings.psd1` was legitimately winning all along.

The daemon check **observes only** -- it never starts, restarts, or kills the daemon -- and it is
honest about the auto-relaunch design: **no daemon running** reports `PASS` (one auto-relaunches
on your next edit), while a daemon that is alive but parked `unavailable` / `degraded`, or alive
but not answering its pipe, is a `FAIL` with the restart remedy. The doctor is **report-only**: it
never downloads, repairs, runs the bootstrap, or starts/restarts anything.
