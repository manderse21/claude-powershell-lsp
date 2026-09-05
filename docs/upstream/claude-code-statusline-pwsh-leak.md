# Bug report: Windows statusline `pwsh.exe` processes never exit

**Status re-derived: 2026-09-05 via gh (dispatch 000276); live state wins over this file.**
`#86551` re-verified **OPEN**, last updated **2026-08-28T00:55:40Z**, **0 comments**. Labels at
re-derivation: `bug`, `has repro`, `platform:windows`, `area:statusline`, **`stale`**.
**Two things moved since the 2026-08-21 derivation and are corrected here rather than carried:**
the last-updated timestamp advanced from 2026-08-13T23:54:28Z to 2026-08-28T00:55:40Z, and the
issue has acquired a **`stale`** label. Still no maintainer response and still zero comments, so
the timestamp move and the label are the same event -- automated staleness marking, not upstream
engagement. Read the `stale` label as what it is: a bot's clock, not a verdict on the report.

## ALREADY FILED AS #86551 -- DO NOT FILE THIS

**This report is filed upstream as
[`anthropics/claude-code#86551`](https://github.com/anthropics/claude-code/issues/86551)**
-- OPEN, filed 2026-08-13T23:53:22Z, last updated 2026-08-13T23:54:28Z, re-derived live with
`gh` on 2026-08-13. Filing it again -- as a new issue, as a comment, or as any other upstream
transmission -- would duplicate it. If the report needs to advance, it advances **on #86551**;
and any upstream posting at all remains Mike Andersen's gate and his alone, as it is for
everything in this directory.

**This file is the internal record, not a pending submission.** It exists because the leak is
already visible inside this repository's own measurements, and a reader who meets those numbers
needs to be able to find out what caused them.

---

## What the defect is

On Windows, every statusline refresh spawns a `pwsh.exe` host that never exits. The script
itself completes -- its output renders -- but the host process stays alive indefinitely, idle,
occupying the process table. Each invocation appears as:

```
"C:\Program Files\PowerShell\7\pwsh.exe" -NoProfile -ExecutionPolicy Bypass -File C:/Users/<user>/.claude/statusline/statusline.ps1
```

Under normal multi-session use the host accumulates hundreds of orphans per hour. The report
asks that the statusline host exit after producing its output, or be reaped by the spawning
session, so the steady-state count stays at or near the number of live sessions.

## The measured growth, as filed

One working day on the reporting host (2026-08-13), counted with a WMI filter on the command
line and swept with `Stop-Process` between measurements:

| Local time | Orphaned statusline `pwsh.exe` | Note |
|---|---:|---|
| ~13:50 | 33 | swept to 0 |
| ~14:05 | growth restarts | oldest survivor timestamped 14:04:58 |
| ~17:30 | 636 | swept to 0 |
| 19:51 | 1,010 | oldest 14:04:58, newest 19:51:27; swept 1,007 |

That is roughly **175 new orphans per hour sustained**, scaling with the number of concurrent
sessions. Earlier observations on the same host recorded ~19 per minute at peak with four
sessions active, and more than 2,200 accumulated over a multi-day uptime before the cause was
identified.

## Why this repository cares

The cost is not only memory and process-table growth. **Any tooling that enumerates processes
slows in proportion to the orphan count**, and this repository's test suite contains exactly
that shape of work: legs performing a process census went from seconds to **16-22 minutes** at
600+ orphans, and a CI-verification workflow wedged twice on the same day as a result.

It also shows up in this project's own measurement record.
[`docs/roadmap-ii/POST-FIX-REMEASUREMENT-relaunch-thrash.md`](../roadmap-ii/POST-FIX-REMEASUREMENT-relaunch-thrash.md)
section 3 records fourteen live `statusline.ps1` shells during the measured block, twelve of
them older than five minutes, and reports the contention as part of the measured condition
because a sweep was attempted and denied. That is this defect, observed from inside a
measurement that was trying to measure something else.

## Workaround

Periodic manual sweep, filtered on the command line and on an age cutoff so a live session's own
statusline is not killed:

```powershell
$cut=(Get-Date).AddMinutes(-5)
Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" |
  Where-Object { $_.CommandLine -like '*statusline*' -and $_.CreationDate -lt $cut } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
```

## Environment as filed

Claude Code 2.1.231 (also observed on earlier 2.1.x); Windows 11; PowerShell 7 at
`C:\Program Files\PowerShell\7\pwsh.exe`; a custom statusline configured as a PowerShell script
at `~/.claude/statusline/statusline.ps1`; multiple concurrent Claude Code sessions, interactive
and `claude -p`, auto mode on.

## Relationship to the other claude-code items in this directory

Independent of them. This is a statusline process-lifecycle defect on Windows; it has no bearing
on LSP registration (`claude-code-lsp-registration.md`) or on the `userConfig` schema limit
(`claude-code-userconfig-enum.md`), and nothing about it gates the native navigation tier. It is
recorded here because the directory is where this repository keeps upstream items it has filed,
regardless of which surface they touch.
