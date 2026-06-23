# 000023 -- Launch-readiness audit (2026-06-19)

Read-mostly audit of the PRODUCT surface a paid public launch depends on -- the
surface the daemon resilience/integrity work (000021/000022) did not touch. Graded
against live `file:line`; degraded install paths exercised in-environment where cheap
(a throwaway `CLAUDE_PLUGIN_DATA` + a dead-proxy env var). No product code was
changed by the audit. Findings tagged EVIDENCE-BACKED (exercised) vs READ.

## The spine -- a clean-box bootstrap failure is silent end to end

Chase the worst realistic stranger path (corporate proxy / offline / GitHub blocked)
and every link is silent:

1. `ensure-pses.ps1:70-73` -- a blocked PSES download logs and returns WITHOUT
   throwing: exit 0, empty stdout/stderr. **[EVIDENCE-BACKED]**
2. `ensure-pses.ps1:34-35` -- it DESTROYS any existing bundle before the single,
   no-retry download (`:41`), so a failed re-bootstrap leaves NO bundle.
   **[EVIDENCE-BACKED: bundle absent after the probe]**
3. `session-start.ps1:173` -- runs both ensure steps as `& $hostExe ... 2>&1 |
   Out-Null` with no `$LASTEXITCODE` check, swallowing both streams AND the exit
   code. So `ensure-pssa.ps1:113-114`'s deliberate loud failure (stderr + `exit 1`)
   is silenced at the orchestration layer. **[EVIDENCE-BACKED]**
4. `pses-daemon.ps1:212-213,610-614` -- a missing bundle makes the daemon's FIRST
   `Start-Pses` return `$false`, and the daemon then exits 1 BEFORE the pipe server is
   created. The client connect-fails and exits 0 silently
   (`lsp-client.ps1:89,211`). **[CODE-GRADED]**
5. So the first edit of a clean-parsing file surfaces NOTHING -- byte-identical to
   "analyzed, clean." The 000022 `incomplete`/`degraded` banners only render when the
   daemon RESPONDS (`lsp-client.ps1:230,256`); the 000022 stay-up machinery is
   mid-session only (`pses-daemon.ps1:481-488,647`) and has a FIRST-START blind spot.

Mitigation: syntax errors still surface via the client's in-process parser pre-pass
(`lsp-client.ps1:142-183`) even with PSES dead -- only LINT on clean-parsing files
vanishes. Inversion to fix: the MOST critical component (PSES) fails the MOST
invisibly, while the less critical one (PSSA) fails loud then gets silenced anyway.

## Heatmap

| Axis | Grade | Sev | Evidence | Key file:line |
|------|-------|-----|----------|---------------|
| I1 install-on-clean-box | PARTIAL | HIGH | EVIDENCE-BACKED | ensure-pses.ps1:34-35,41,70-73; session-start.ps1:173; ensure-pssa.ps1:113-114 |
| I2 first-run (visibility) | PARTIAL | HIGH | CODE + corroborated | pses-daemon.ps1:212-213,610-614,481-488; lsp-client.ps1:89,211,230,256 |
| I2 first-run RATE | (not gradeable) | NEEDS-DATA | -- | clean-VM matrix / install telemetry / bug reports |
| M1 manifest honesty | HONEST-WITH-GAPS | MEDIUM | READ | plugin.json:91-113; pses-daemon.ps1:51; docs/upstream/claude-code-lsp-registration.md:39-52 |
| D1 docs honesty | GOOD-WITH-GAPS | MEDIUM | READ | README.md:49-59,163-164,250-254 |
| S1 diagnosability | PARTIAL | MEDIUM | READ | lsp-common.ps1:409; pses-daemon.ps1:235; pses-stdio.ps1:40 |
| F1 surface-freeze + semver | PARTIAL | MEDIUM/OBS | READ | CHANGELOG.md:6-30; (no CONTRACT.md); bump-version.ps1 |
| L1 licensing/payment | (not gradeable) | NEEDS-DECISION | READ | LICENSE:1-21 |

Notes:
- **M1**: the `lspServers` block is inert on CC 2.1.167-2.1.183; `userConfig` (13 knobs)
  is fully honored; `maxRestarts=3` is decorative -- mirrored by a hardcoded
  `MaxPsesRestarts=3` (pses-daemon.ps1:51), not wired from the manifest.
- **D1**: README is notably honest, but its config table lists 9 of 13 `userConfig`
  knobs, and its currency line (2.1.167) lags the repo's own upstream doc (2.1.183).
- **S1**: no plugin-version stamp in any log; the only version literals are stale
  hardcoded host-version strings (1.0.0 / 1.1.0) in the LSP handshake; logs leak
  absolute file paths.
- **L1**: a LICENSE exists and is MIT -- it grants the right to resell free of charge,
  so this is MISALIGNMENT with a paid model, not a missing file.

## Prioritized backlog

1. **[HIGH | M]** Surface the silent first-start install failure (I1+I2): session-start
   checks each ensure step's exit code; the daemon, on a first-start `Start-Pses`
   failure, still creates the pipe and serves `status='incomplete'` (extend 000022 to
   first-start) so the client shows the "diagnostics unavailable" banner. *Land first.*
2. **[HIGH->MED | S]** Make `ensure-pses` fail loud + non-destructive (mirror
   `ensure-pssa`; download-to-temp, swap on success; add retry/backoff).
3. **[MED | S]** Diagnosability: stamp the real plugin version into each log; add a
   log-collector for bug reports (S1).
4. **[MED | S]** Docs reconciliation: add the 4 missing `userConfig` knobs to the README
   table; refresh the currency line to 2.1.183 (D1).
5. **[MED | S/M]** Manifest honesty: annotate the inert `lspServers` block; wire (or
   document as fixed) the `maxRestarts` reconciliation owed since 000022 (M1).
6. **[MED | M]** CONTRACT.md surface freeze on the claude-archive-mcp model (F1) -- its
   own dispatch, sequenced AFTER #1 (Mike, 2026-06-19).
7. **[LOW | S]** Log path-privacy option / disclosure (S1).
8. **[NEEDS-DATA]** First-run failure RATE on real clean boxes (I2).
9. **[NEEDS-DECISION]** Licensing / payment / distribution (L1).

## Open decisions (Mike Andersen, 2026-06-19)

- **L1 licensing** -- DEFERRED to a separate business call; recorded NEEDS-DECISION with
  four options open (stay free/OSS-MIT; dual-license; source-available/proprietary +
  payment-key; pick a paid distribution channel). No resolution in this audit.
- **F1 CONTRACT.md** -- approved as its OWN dispatch, sequenced after backlog #1.
- **Findings ledger** -- this `docs/audits/` ledger established as the home for findings
  (Mike's Q5); 000023 is its first entry.

Full audit record: strategic-dispatch outbox 000023 (state `complete`).
