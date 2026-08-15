# Post-fix remeasurement -- the daemon-exit on an abandoned reply

**What this document is.** An M4b-class remeasurement of the large-file edit path against the build
that fixes the daemon-exit defect (dispatch 000237). It exists beside
[`POST-FIX-REMEASUREMENT-relaunch-thrash.md`](POST-FIX-REMEASUREMENT-relaunch-thrash.md) rather than
inside it, and beside `SLO-BASELINES.md` rather than over it, under the ratified D3 addendum: a
baseline is not edited to reflect a fix, the fix is measured next to it. **Neither prior document is
modified by this one**; both are byte-identical between `origin/main` and this branch.

**What this document is not.** It is not a new baseline, it adopts no SLO, and it proposes no
target. It does not redefine M4 or M4b -- those are defined in `SLO-BASELINES.md` section 5 and are
used here unchanged, because a remeasurement that redefines its metric measures nothing.

**Measured 2026-08-15.**

---

## 1. What was fixed, and what this therefore predicts

The relaunch-thrash remeasurement closed with a named, unfixed finding (its section 8): *"A departed
client kills the daemon (`Pipe is broken` -> `main loop ended` -> exit) ... the binding reason the
large-file session never converges now that the thrash is gone."* It also named the question a
successor charter would have to answer first: the serve loop's own handler logs that exception, so
why does the loop end?

Dispatch 000237 answers it and fixes it. The failed write moves the pipe server's internal state to
`Broken`; `IsConnected` is `State == Connected`, so the per-request cleanup's
`if ($server.IsConnected) { $server.Disconnect() }` **skipped** on exactly the path that needed it,
leaving the stream `Broken`; the next `WaitForConnectionAsync()` -- outside the per-request `try` --
threw past the handler into the loop's outer `finally`. The cleanup now asks for the disconnect
unconditionally, and the accept region rebuilds a stream it cannot arm instead of ending the
process.

**The prediction going in.** The fix's claim is *daemon survival*. Convergence was the expected but
explicitly unpromised beneficiary: `SLO-BASELINES.md` section 8 identifies **two** compounding
failures on this path, and the 5000 ms settle cap is the other one and is untouched. So survival was
required; convergence was a hypothesis.

---

## 2. The builds measured

Both arms measured on the same host, in the same block, minutes apart -- so the comparison is
same-instrument rather than against a document written on another day.

| Fact | PRE-FIX arm (control) | POST-FIX arm |
|---|---|---|
| Tree | worktree at `origin/main` `3aeb4150` | `dispatch/powershell-lsp-000237-daemon-exit-fix` |
| Carries the defect | yes (`if ($server.IsConnected) { $server.Disconnect() }` present) | no |
| Large fixture | `scripts/lib/lsp-common.ps1`, **224,815 bytes / 3,961 lines** | same file, **229,867 bytes / 4,044 lines** |
| Pinned PSES | v4.6.0 (`pses-v4.6.0.ok`, junctioned from the live data root) | same |
| Pinned PSScriptAnalyzer | 1.25.0 (`.pssa-1.25.0.ok`, same junction) | same |
| PowerShell host | pwsh 7.6.3 (the plugin's default `ps_host`) | same |
| Host | Windows 11 Pro 10.0.26200 | same |

**The pre-fix fixture is byte-identical in size to the relaunch-thrash block's** (224,815 bytes /
3,961 lines), so the control arm is measuring the same file that block did. The post-fix fixture is
**2.2% larger** because the fix added lines to that very file. `SLO-BASELINES.md` section 6.4
finding 5 records that `analysisMs` rises only ~18% for a file 1000x larger, so a 2.2% change is far
below the resolution of anything measured here. It is stated rather than buried, per the prior
block's convention.

## 3. Load context

Labelled, not claimed quiet -- the same discipline both prior documents use.

| | CPU median before | CPU median after | Per-session range |
|---|---:|---:|---|
| **This block, PRE-FIX arm** | **87%** | **80%** | before 83% - 94% |
| **This block, POST-FIX arm** | **73%** | **76%** | before 58% - 80% |
| Relaunch-thrash block | 69% | 74% | before 57% - 88% |
| Baseline M4b (`SLO-BASELINES.md` section 2) | -- | -- | 31% - 57% per session |

**The PRE-FIX arm ran at HIGHER load than the post-fix arm** (87% median against 73%), and both ran
at or above the load of the block they answer. That direction matters twice over: the improvement
below was not obtained under easier conditions, and the control's failure was not manufactured by an
easy one -- it reproduced the original block's per-session figures exactly.

## 4. Method

The corrected instrument of `SLO-BASELINES.md` section 4, rebuilt from that section's description
and from the relaunch-thrash block's section 4 -- the same shape, one variable changed:

- **Private data root per session**, with `PowerShellEditorServices` and `modules` **junctioned** to
  the live bundles and the version markers copied, so `ensure-pses` and `ensure-pssa` no-op exactly
  as on a warm machine and bootstrap is excluded from every figure. The harness **fails closed** if
  the junction does not resolve to a real `Start-EditorServices.ps1` and a real PSSA marker.
- **Real hook entry points, end to end.** `scripts/session-start.ps1` fed SessionStart JSON on
  stdin for bring-up; `scripts/lsp-client.ps1` fed PostToolUse JSON on stdin for each edit. No
  internal function is called directly.
- **External wall clock** around each whole client process, start to exit, because
  `SLO-BASELINES.md` section 6.1 finding 1 establishes that the shipped `totalMs` understates
  user-visible latency.
- **The section 4.4 correction, applied.** Each edit is classified by a **`stats.jsonl` line-count
  delta** plus the client's own emitted banner -- never by tailing the last line, because a client
  that gives up writes no stats line at all and a tailing reader silently re-reads the previous
  edit's record.
- **Real content change per iteration** (a unique nonce line), because the daemon caches by content
  hash.
- **Uniform 15-attempt cap across 5 cold sessions per arm**, matching the baseline's M4b block
  exactly -- that block is the baseline's primary figure precisely because its cap is uniform. An
  arm stops early on the attempt that converges; the cap is what bounds a non-converging session.
- **Scoped teardown.** Every process kill filtered on the private root's own path string, which a
  co-tenant daemon cannot carry.

**The harness is a scratch artifact and ships nowhere**, matching both prior blocks' convention.

**One instrument note, recorded because it cost a block.** A first pre-fix control was run against a
tree containing only `scripts/`, and every one of its five sessions reported *"daemon never reached
ready"*. That is the harness's fail-closed guard doing its job, not a measurement: a partial tree has
no `.claude-plugin/plugin.json`, so manifest resolution never completes. **None of its numbers are
used here**; the control was re-run against a complete `git worktree` of `origin/main`, which is the
arm reported below. The general shape is the one `SLO-BASELINES.md` section 10 already records: a
harness that measures a broken rig rather than the product returns numbers that look like results.

---

## 5. Headline result -- convergence

| Measurement | Sessions | Converged | Attempt cap |
|---|---:|---:|---:|
| Baseline M4b (`SLO-BASELINES.md` section 8) | 5 | **1** | 15 |
| Relaunch-thrash block (post-000225, pre-000237) | 5 | **0** | 15 |
| **PRE-FIX control, this block** | 5 | **0** | 15 |
| **POST-FIX, this block** | 5 | **5** | 15 |

**Every post-fix session converged, and every one converged on attempt 2.** Spread zero across five
sessions.

That is a stronger result than the fix promised. The fix's claim was daemon survival; the settle cap
that `SLO-BASELINES.md` names as the *other* compounding failure is untouched by this dispatch. What
changed is that the settle cap now expires **once**, against a daemon that stays alive to finish the
work and publish it on the next request -- where before, the daemon died at that same moment and the
next request found nothing to answer it.

## 6. The mechanism, read from the daemon logs

The post-fix sessions are identical to each other -- exact figures rather than a median with spread:

| Signal, per session | Relaunch-thrash block | PRE-FIX control (this block) | **POST-FIX (this block)** |
|---|---:|---:|---:|
| Daemon exits (`main loop ended; cleanup`) | 4 | **4** | **0** |
| Broken-pipe events handled (`request handling error`) | 4 | **4** | **1** |
| `settled=True` published | **0** | **0** | **1** |
| Distinct daemons launched | 4 | **5** | **1** |
| Pipe-server rebuilds (the 000237 backstop) | n/a | n/a | **0** |
| Edits to convergence | never | **never (15, the cap)** | **2** |

**Three rows carry the whole story.**

**`settled=True` appears.** The relaunch-thrash block records it appearing **zero** times in all five
of its sessions, and says why in its section 7: *"Post-fix, `settled=True` never appears, because the
daemon never survives long enough to publish one."* It now appears once per session. The daemon
survives long enough to publish.

**Daemon exits go to zero while broken-pipe events do not.** The abandonment still happens -- the
client still reaches its hard cap on the first edit against a ~220 KB file, still walks away, and the
daemon's reply write still raises `Pipe is broken.` exactly once per session. What changed is only
what follows it. One abandoned reply is now one discarded write.

**The rebuild backstop never fired.** Zero rebuilds across five sessions means the primary cure --
asking for the disconnect unconditionally -- was sufficient on every occurrence, and the accept-region
guard is doing what a backstop should: nothing, until something the primary cure does not cover.

### 6.1 The raw per-session rows

Recorded because the aggregate figures above have spread zero, which is unusual enough that the
reader should be able to see it is not a rounding artifact.

| Arm | Session | Converged at | Daemon exits | Pipe errors | `settled=True` | Daemons | Rebuilds |
|---|---|---:|---:|---:|---:|---:|---:|
| PRE-FIX | s1 | never | 4 | 4 | 0 | 5 | 0 |
| PRE-FIX | s2 | never | 4 | 4 | 0 | 5 | 0 |
| PRE-FIX | s3 | never | 4 | 4 | 0 | 5 | 0 |
| PRE-FIX | s4 | never | 4 | 4 | 0 | 5 | 0 |
| PRE-FIX | s5 | never | 4 | 4 | 0 | 5 | 0 |
| POST-FIX | s1 | **2** | **0** | 1 | **1** | 1 | 0 |
| POST-FIX | s2 | **2** | **0** | 1 | **1** | 1 | 0 |
| POST-FIX | s3 | **2** | **0** | 1 | **1** | 1 | 0 |
| POST-FIX | s4 | **2** | **0** | 1 | **1** | 1 | 0 |
| POST-FIX | s5 | **2** | **0** | 1 | **1** | 1 | 0 |

**Edits performed: 75 pre-fix** (5 sessions x the full 15-attempt cap, none converging) **against 10
post-fix** (5 x 2). Median external wall-clock per edit: **9,238 ms pre-fix, 10,562 ms post-fix** --
the post-fix figure is higher because its two edits are both cold-ish work against an unsettled
analysis, whereas the pre-fix median is dominated by 75 edits most of which the client abandoned at
its cap. **This block makes no latency claim**; the numbers are recorded so nobody has to infer one.

**The control validates the instrument.** Its per-session figures -- 4 daemon exits, 4 broken-pipe
events, `settled=True` zero times, 0 of 5 converged -- are exactly what the relaunch-thrash block
reported for the same scenario on a different day. A control that reproduces the known failure is
what makes the treatment arm's result readable as an effect rather than as a difference in
conditions.

## 7. What this remeasurement does not establish

- **Windows only.** Nothing here is a cross-platform claim. The unix arm's evidence is the four CI
  legs recorded in this dispatch's outbox, not this document.
- **Not a quiet window**, and at the same elevated load as the block it answers (section 3). No
  quiet-window re-run was chartered or attempted.
- **Not a regression gate.** Indicative figures, as both prior documents say of their own.
- **5 sessions per arm** is a small denominator. The convergence row is unusually clean (5 of 5, all
  at attempt 2, spread zero), but the honest reading is that this fixture and this host now converge
  reliably -- not that every large-file scenario everywhere does.
- **The settle cap is unchanged and still expires once per session.** This block does not measure a
  file large enough to expire it twice, and does not claim convergence would survive that.
- **The fixture differs between the arms by 2.2%** (section 2), and the post-fix tree is a branch
  worktree rather than a cache build.
