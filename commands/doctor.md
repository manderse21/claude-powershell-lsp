---
description: Run the powershell-lsp preflight doctor -- a report-only health check of the PowerShell diagnostics plugin, with a named fix for anything wrong.
argument-hint: "[--probe-native-serve] [--json] [--require-proven]"
allowed-tools: Bash(pwsh:*)
---

Run the powershell-lsp preflight doctor and report what it found.

The doctor is **report-only**: it never downloads, repairs, runs the bootstrap, or starts,
restarts, or stops anything. Run it exactly as given below and do not "fix" anything on the
user's behalf without asking first.

If `$ARGUMENTS` contains `--probe-native-serve`, append `-ProbeNativeServe` to the command. That
adds the opt-in native-serve **removability** probe, which costs a PSES cold start plus a bounded
init wait -- so only add it when asked.

If `$ARGUMENTS` contains `--json`, append `-Json`; if it contains `--require-proven`, append
`-RequireProven`. Both are described below.

```
pwsh -NoLogo -NoProfile -File "$env:CLAUDE_PLUGIN_ROOT/scripts/doctor.ps1"
```

Then summarize for the user:

- The report opens with a `version:` header line above the check table. It is always present, even
  when every check is UNKNOWN, and it is not a check -- it carries no status and is not in the
  counts. Include it whenever the user is reporting a problem or asking for support.
- Lead with the summary line's counts.
- If any check is **FAIL**, quote its component, its detail, and its `fix:` line. A FAIL is the
  only thing that sets a non-zero exit code, unless `-RequireProven` was asked for.
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

## `-Json` -- the machine rendering

`-Json` is a **third rendering over the same seam**, beside the default fix-list and `-Summary`.
The checks that run, their statuses and the exit code are identical to a normal run; only the
presentation differs. It is a CLI switch, not a `userConfig` knob -- the same category as
`lsp-scan.ps1`'s `-Format`.

```
pwsh -NoLogo -NoProfile -File "$env:CLAUDE_PLUGIN_ROOT/scripts/doctor.ps1" -Json
```

The envelope:

```json
{
  "schemaVersion": 1,
  "status": "DEGRADED",
  "versions": { "plugin": "1.33.1", "pwsh": "7.6.5", "pses": "v4.6.0", "pssa": "1.25.0" },
  "provenanceFloor": "...",
  "captureMode": { "resolved": "full", "raw": "", "recognized": false },
  "summary": { "pass": 6, "fail": 0, "unknown": 8, "total": 14 },
  "checks": [ { "status": "pass", "component": "...", "detail": "...", "remediation": "..." } ]
}
```

- **`schemaVersion`** is the field to branch on. It is not the plugin version and does not move
  with it; the plugin version rides in `versions.plugin`.
- **`versions.pwsh`** is a host fact -- the interpreter actually found on `PATH`.
  **`versions.pses` / `versions.pssa`** are the **pins this build requires**, not a re-probe of
  what is installed. Checks 3 and 4 are what report whether the install matches them.
- **`checks`** is always a JSON array, including at one element and at zero.
- **`captureMode`** reports the diagnostics-capture control
  ([`POWERSHELL_LSP_CAPTURE_MODE`](../docs/configuration.md#powershell_lsp_capture_mode)):
  `resolved` is the mode the capture writer will actually obey, `raw` is the environment value
  verbatim (`""` when unset), and `recognized` says whether that value named a real mode. **All
  three are reported because an unrecognized value resolves to `full`** -- nothing about that
  variable may become a gate on the diagnostics surface -- so without `raw` and `recognized` a
  fleet reader could not tell a host deliberately left at `full` from one whose deployed value is
  misspelled. This is how a management plane confirms the control is active on a host **without
  reading the capture log the control exists to keep it out of**.

### Adding to this envelope -- the schemaVersion policy

**Additive fields do not bump `schemaVersion`. Removals and renames do.** A consumer written
against a given `schemaVersion` may therefore encounter keys it does not know and must ignore
them, but will never find a key it relied on missing or renamed under the same version.

This policy was established by dispatch 000282, which added `captureMode`, **because no policy
existed** -- the envelope shipped in 000279 said what `schemaVersion` was for and not what moves
it. It is recorded here rather than inferred from the one example.

### `status` -- how it is derived

`status` is derived from the per-check `pass` / `fail` / `unknown` results and from nothing else.
Each value has a condition, and when more than one applies the **most severe wins**, in the order
`UNHEALTHY` > `DEGRADED` > `UNPROVEN` > `HEALTHY`:

| Value | Applies when | Means |
|---|---|---|
| `UNHEALTHY` | at least one check FAILED | something the doctor could establish is broken |
| `DEGRADED` | at least one check is UNKNOWN **and** at least one PASSED | part of the picture was established and part was not |
| `UNPROVEN` | **nothing** PASSED | the run established nothing at all, so it proves nothing |
| `HEALTHY` | every check PASSED | everything the doctor checks was established |

So a run with both a fail and an unknown reads `UNHEALTHY`; a run where every check is UNKNOWN
reads `UNPROVEN`; and a render of zero checks reads `UNPROVEN`, never `HEALTHY`.

**This `status` is a DOCTOR ENVELOPE field, not a diagnostics status token.** `CONTRACT.md`
freezes the *diagnostics* status token set -- the words a finding wears -- and none of these four
is one of them. The doctor's own per-check `pass` / `fail` / `unknown` vocabulary is a third,
separate enum, and it is unchanged.

## `-RequireProven` -- gate on proof, not on absence-of-failure

By default the doctor exits 0 whenever nothing FAILED, and an honest `UNKNOWN` is not a failure.
That is correct, and it is also why `exit 0` alone never meant "it is working": in a container or
a CI job the checks that would prove it is working do not fail, they go UNKNOWN.

`-RequireProven` is the opt-in that makes "everything was actually established" expressible as an
exit code:

| Situation | default | with `-RequireProven` |
|---|---|---|
| every check passed | 0 | 0 |
| at least one check FAILED | 1 | 1 |
| nothing failed, at least one UNKNOWN | 0 | **2** |

Exit **2** rather than 1 keeps 1 meaning "something FAILED" for every caller that already exists,
and matches this repo's own convention for an opt-in gate tripping (`lsp-scan.ps1 -FailOn` exits 2
the same way). A run carrying both a fail and an unknown exits **1** -- the failure is the more
actionable fact.

**The opt-in is load-bearing.** Changing what the *default* exit code means would break every
existing caller, so the switch is what protects them, and without it the exit code is exactly what
it has always been.
