# Post-fix remeasurement -- the busy-vs-unreachable relaunch thrash

**What this document is.** An M4/M4b-class remeasurement of the large-file edit path against the
**fixed** build, using the corrected instrument dispatch 000223 built and documented. It exists
because `docs/roadmap-ii/SLO-BASELINES.md` is frozen pre-fix history under the ratified D3 addendum:
the baseline is not edited to reflect a fix, the fix is measured beside it. Every figure below is
paired with the baseline figure it answers, cited by section.

**What this document is not.** It is not a new baseline, it adopts no SLO, and it proposes no
target. It also does not re-derive the metric definitions -- M4 and M4b are defined in
`SLO-BASELINES.md` section 5 and are used here unchanged, because a remeasurement that redefines
its metric measures nothing.

**The frozen baseline is untouched.** `docs/roadmap-ii/SLO-BASELINES.md` is byte-identical between
`origin/main` and this branch; the check is recorded in this dispatch's outbox.

---

## 1. What was fixed, and what this therefore predicts

Two fixes ship on manderse21/claude-powershell-lsp#153:

- **000225** -- the client no longer treats every failed diagnostics round-trip as "there is no
  daemon". It asks whether the daemon's pipe is present first, and a live daemon is never
  relaunched.
- **000231** -- off-Windows, that presence question is now a **liveness** question, because a unix
  socket file outlives the process that created it. Windows is unaffected by this second fix.

**This block runs on Windows**, so it measures 000225's behavior on the platform where 000225 was
already correct. The unix fix's evidence is CI, not this document, and is recorded in the outbox.

**What the fixes do NOT touch, by charter.** The ratified D3 boundaries exclude daemon redesign,
retry-policy cleanup beyond the misclassification, startup optimization, cold-start work, and any
settle-cap change. `SLO-BASELINES.md` section 8 identifies **two** compounding failures on the
large-file path, and only the second is a misclassification:

1. the daemon's **5000 ms settle cap** expires before PSES publishes a settled analysis of a
   ~220 KB file, so the pass returns `incomplete`;
2. while the daemon is busy, the client concludes it is *unreachable* and relaunches it, discarding
   the work in flight.

Only (2) is in scope. So the prediction going in is: **the thrash should disappear, and
non-convergence should remain.** That is what happened, and the shape of what remains turned out to
be worth reporting.

## 2. The build measured

| Fact | Value |
|---|---|
| Tree measured | worktree of `dispatch/powershell-lsp-000225-relaunch-thrash-fix` at this dispatch's head |
| Contains | 000225 (client gate) + 000231 (unix liveness arm, test-only fix (a)) |
| Pinned PSES | v4.6.0 (`pses-v4.6.0.ok`, junctioned from the live data root) |
| Pinned PSScriptAnalyzer | 1.25.0 (`.pssa-1.25.0.ok`, same junction) |
| Host | Windows 11 Pro 10.0.26200, AMD Ryzen AI 7 PRO 350, 8P/16L, 31.14 GB |
| PowerShell host | pwsh 7.6.3 (the plugin's default `ps_host`) |
| Measurement date | 2026-08-13 |
| Large fixture | **224,815 bytes / 3,961 lines** |

**One deliberate difference from the baseline, stated rather than buried.** `SLO-BASELINES.md`
section 1 measured the **installed v1.31.0 cache build**, "so the baseline describes what a user
runs". This block measures the **branch worktree**, because the fix under test is not in any cache
build. Same pinned PSES and PSScriptAnalyzer, same host, same hook entry points, same junction-backed
private-root protocol -- the tree location is the only difference.

**The fixture is 2.3% larger than the baseline's** (224,815 vs 219,682 bytes; 3,961 vs 3,881 lines),
because the fixture *is* `scripts/lib/lsp-common.ps1` and this dispatch added lines to it. This is
noted for completeness and is not a material variable: the baseline's own finding is that
`analysisMs` rises only ~18% for a file 1000x larger (section 6.4, finding 5), so a 2.3% size change
is far below the resolution of anything measured here.

## 3. Load context

Labelled, not claimed quiet -- the same discipline as `SLO-BASELINES.md` section 2.

| | CPU median before | CPU median after | Per-session range |
|---|---:|---:|---|
| **This block (post-fix)** | **69%** | **74%** | before 57% - 88% |
| Baseline M4b (section 2) | -- | -- | 31% - 57% per session |

**This block ran on a busier machine than the baseline did** -- roughly 69% against 31-57%. That
direction matters for how the results are read: it means the post-fix figures below were *not*
obtained under easier conditions than the baseline's, so where they are equal or better the load
difference is not doing the work. Fourteen `statusline.ps1` shells were live throughout (twelve of
them older than five minutes); a sweep was attempted and **denied by this session's permission
classifier**, so the contention is part of the measured condition and is recorded rather than
removed.

## 4. Method

The corrected instrument of `SLO-BASELINES.md` section 4, rebuilt from that section's description:

- **Private data root per session**, with `PowerShellEditorServices` and `modules` **junctioned** to
  the live bundles and the version markers copied, so `ensure-pses` and `ensure-pssa` no-op exactly
  as on a warm machine and bootstrap is excluded from every figure. The harness **fails closed** if
  the junction does not resolve to a real `Start-EditorServices.ps1` and a real PSSA marker (see
  section 8 -- this guard caught a broken predecessor block).
- **Real hook entry points, end to end.** `scripts/session-start.ps1` fed SessionStart JSON on
  stdin for bring-up; `scripts/lsp-client.ps1` fed PostToolUse JSON on stdin for each edit. No
  internal function is called directly.
- **External wall clock** around each whole client process, start to exit
  (`System.Diagnostics.Process`), because section 6.1 finding 1 establishes that the shipped
  `totalMs` understates user-visible latency by ~931 ms.
- **The section 4.4 correction, applied.** Each edit is classified by a **stats.jsonl line-count
  delta** plus the client's own emitted banner -- never by tailing the last line. When the client
  gives up, no stats line is written at all, and a tailing reader silently re-reads the previous
  edit's record.
- **Real content change per iteration** (a unique nonce line), because the daemon caches by content
  hash.
- **Uniform 15-attempt cap across 5 cold sessions**, matching the baseline's M4b block exactly --
  that block is the baseline's primary figure precisely because its cap is uniform.
- **Scoped teardown.** Every process kill filtered on the private root's own path string, which a
  co-tenant daemon cannot carry.

**The harness is a scratch artifact and ships nowhere**, matching the baseline's convention.

## 5. Headline result -- convergence

| Measurement | Sessions | Converged | Attempt cap |
|---|---:|---:|---:|
| Baseline M4b (`SLO-BASELINES.md` section 8) | 5 | **1** | 15 |
| **This block (post-fix)** | 5 | **0** | 15 |

**Convergence did not improve, and was not expected to.** Failure (1) -- the 5000 ms settle cap
against a ~220 KB file -- is untouched by both fixes and is explicitly outside the D3 boundaries.
The daemon logs say so directly and identically in all five sessions: **`settled=True` appears 0
times** and `analysis did not settle (cause=settle-timeout)` appears 4 times per session.

The 1-of-5 to 0-of-5 difference is **not** evidence of a regression. Both blocks are 5 sessions
against a bimodal outcome; the baseline's own section 8 reports the pooled figure as 2 of 11 and
warns that its denominators are weaker than they look. This block also ran at roughly 69% CPU
against the baseline's 31-57%, and the baseline names section 8's result as "the one result that
does appear load-sensitive". **On this evidence the honest statement is that convergence on this
fixture remains the exception under both builds**, not that it got worse.

## 6. What the fix actually changed -- the relaunch behavior

This is where the fix is visible. All five post-fix sessions produced **identical** counts, so the
per-session column below is exact rather than a median with spread.

| Signal | Baseline, non-converging session (section 8) | Post-fix, every session | Normalized: baseline | Normalized: post-fix |
|---|---:|---:|---:|---:|
| Edits in the session | 25 | 15 | -- | -- |
| Client "connect attempt failed" | 32 | 14 | 1.28 /edit | **0.93** /edit |
| Client "daemon unreachable (degrading to log-only)" | 16 | 7 | 0.64 /edit | **0.47** /edit |
| **Live daemon correctly NOT relaunched (the new gate)** | **0 -- the branch did not exist** | **4** | 0 /edit | **0.27** /edit |
| Auto-relaunch fired | 6 | 4 | 0.24 /edit | 0.27 /edit |
| Auto-relaunch suppressed (cooldown) | 15 | 3 | 0.60 /edit | **0.20** /edit |
| Distinct daemons launched | 6 | 4 | 0.24 /edit | 0.27 /edit |
| Stats lines written | 4 of 25 (16%) | 4 of 15 (**27%**) | -- | -- |
| Daemon `settled=True` | 0 | 0 | -- | -- |

Across the block: **5 sessions, 75 edits, median 4 daemons per session (spread 0), median 3
relaunches fired (min 3, max 4).** The baseline reports median 3 daemons (min 3, max 4) and median 3
relaunches (spread 0).

**The load-bearing row is the third one.** Four times per session -- **27% of all edits** -- the
client hit its hard cap against a daemon that was demonstrably alive, asked the new question, and
**did not relaunch it**:

```
response timed out (hard cap)
daemon LIVE but did not answer within the cap (pipe present) -> no relaunch;
emitted honest incomplete banner
```

Pre-fix, every one of those edits would have fired a relaunch against a working daemon. That is not
inferred from the baseline: the suite carries a RED control that drives the same scenario through a
reconstructed pre-000225 client and asserts the relaunch **does** happen, so the counterfactual is
measured rather than assumed.

**Raw relaunch counts per edit are flat (0.24 to 0.27), and that is the honest headline**, not a
suppressed one. What changed is not how often a relaunch happens but **whether it was earned** --
which section 7 settles.

## 7. Every remaining relaunch is earned -- the mechanism, read from the logs

The post-fix session is a perfectly regular four-edit cycle, identical across all five sessions:

| Edit in cycle | What happens | Client outcome |
|---|---|---|
| 1 | Daemon answers within the cap, analysis unsettled | `incomplete` banner, stats line written, **no relaunch** |
| 2 | Client's 5000 ms hard cap expires first; **pipe present** | honest `incomplete` banner, **relaunch correctly suppressed** |
| 3 | No daemon at all -- connect fails twice | genuinely unreachable, **relaunch fires** |
| 4 | Relaunched daemon still coming up | unreachable, relaunch **suppressed by the 30 s cooldown** |

**Why there is no daemon at edit 3.** Not because the client killed it. The daemon log says what
happened, in all five sessions, four times each:

```
analysis did not settle (cause=settle-timeout) -> incomplete: file:///.../large-fixture.ps1
analyzed file:///.../large-fixture.ps1 -> 0 record(s); settled=False
request handling error: Exception calling "WriteLine" with "1" argument(s): "Pipe is broken."
main loop ended; cleanup
PSES stopped
--- daemon exit ---
```

At edit 2 the client reached its own 5000 ms hard cap and exited -- correctly, having emitted the
honest banner and, thanks to the fix, without relaunching anything. The daemon finished a moment
later and tried to write its `incomplete` response to a client that was no longer there. The write
raised **"Pipe is broken"**, and the daemon **exited**. The relaunch at edit 3 is therefore a
correct response to a daemon that genuinely was not there.

**The 1:1 corroboration.** Per session: **4 daemon exits, 4 "Pipe is broken" events, 4 hard-cap
timeouts, 4 gate suppressions.** Daemon deaths and broken pipes match exactly, and every relaunch
follows a real death. Compare the baseline's mechanism table (section 8), where 6 relaunches
accompanied 32 connect failures against daemons that were still working -- one of which was
observed logging `settled=True` **after** the client had given up on it. Post-fix, `settled=True`
never appears, because the daemon never survives long enough to publish one.

**So the fix did exactly what it claimed and nothing more.** The client no longer destroys a working
daemon. What still destroys the daemon is a different mechanism entirely, on the daemon side, and
it was not in scope.

## 8. Newly surfaced, NOT fixed here

Recorded so the absence of a fix reads as a boundary rather than an oversight.

- **A departed client kills the daemon (`Pipe is broken` -> `main loop ended` -> exit).** This is
  daemon lifecycle, explicitly outside the ratified D3 boundaries (no daemon redesign, no
  retry-policy cleanup beyond the misclassification). It is the binding reason the large-file
  session never converges *now that the thrash is gone*, and it is a strong candidate for a
  successor charter. **No fix was attempted.** Note the shape: the exception is raised on the write
  and logged by the serve loop's own handler, yet the loop still ends -- so the surviving question
  for that charter is why the loop exits after handling it, not merely that the write failed.
- **The 30-second relaunch cooldown converts one death into two unchecked edits.** Edit 4 of every
  cycle is refused a relaunch it would have benefited from, and receives the "could not be restarted
  automatically ... Start a new session" banner about an analyzer that a relaunch could have
  restored. Retry policy, also outside D3.
- **Convergence remains untested between 54 KB and 220 KB.** The baseline's section 10 already
  records that the file-size curve has two points; this block adds a third measurement at the same
  p100 point and does not close that gap.

## 9. What this remeasurement does not establish

- **Windows only.** Nothing here is a cross-platform latency claim. The unix arm's evidence is the
  CI legs recorded in this dispatch's outbox, not this document.
- **Not a quiet window**, and at higher load than the baseline (section 3). No quiet-window re-run
  was chartered or attempted.
- **Not a regression gate.** Indicative figures, as the baseline says of its own.
- **5 sessions against a bimodal outcome** is a small denominator on both sides. The convergence row
  in section 5 is reported as found and is explicitly not read as a regression.
- **The fixture differs from the baseline's by 2.3%**, and the tree measured is the branch worktree
  rather than a cache build (section 2).

## 10. One instrument note, recorded because it changed a number

The predecessor 000225 session left an abandoned M4b block on disk (five private roots under
`%TEMP%\psl-fix-225-m4b`, timestamped 2026-08-12). Read read-only, **every edit in all five of those
sessions recorded `taken = daemon-unavailable`** -- the permanent bundle-missing status, not a
latency result. That block was measuring a broken bundle wiring, not the product, which is
consistent with 000225 never writing this document. **None of its numbers are used here.**

This block's harness therefore fails closed on exactly that condition: it refuses to start a session
unless the junctioned bundle resolves to a real `Start-EditorServices.ps1` and a real PSSA marker.
The guard is why this block's edits report `daemon-incomplete` -- a real analyzer that ran out of
time -- rather than `daemon-unavailable`.

A second needle defect was found and corrected **in this dispatch's own aggregation**, and is
recorded for the same reason: the first pass counted client "connect attempt failed" lines with that
exact string and reported **0**, which would have been a striking result. The shipped text is
`connect attempt 1 failed` / `connect attempt 2 failed`. The corrected count is **14 per session**,
and section 6 uses the corrected figure. A needle that matches nothing returns a clean zero, and a
clean zero is indistinguishable from a fixed defect.
