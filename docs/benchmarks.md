# Benchmarks -- measured latency

Two numbers describe how this plugin feels in a session, and both are measured here rather than
asserted: the **warm-hook per-edit diagnostic round-trip** (what a user pays on every edit) and the
**closed-loop re-check turn** (dispatch 000061 -- the turn where the daemon reports that your last
edit cleared a finding, or did not).

Produced by `tests/bench/Invoke-LatencyBench.ps1` (dispatch 000127, roadmap item N1.5).

## Running it

From a clean clone. The first run bootstraps PowerShell Editor Services and the pinned
PSScriptAnalyzer exactly as a real session does; that bootstrap is **not** timed.

```powershell
pwsh -NoProfile -File tests/bench/Invoke-LatencyBench.ps1
pwsh -NoProfile -File tests/bench/Invoke-LatencyBench.ps1 -Iterations 50 -JsonPath bench.json
```

It brings up its own throwaway daemon under a temp data root, so it never touches a live session's
state, and tears it down when done.

## Results

Measured 2026-07-17 at plugin **v1.24.3**. Host: pwsh 7.6.3 on Windows 11 Pro (10.0.26200),
AMD Ryzen AI 7 PRO 350, 16 logical cores, 31 GB. **30 iterations per path. Cold start excluded.**
Idle machine.

The build stamp is not decoration: a date and a host do not tell a reader which build produced the
numbers, and this page previously carried none. It is derived, not recalled -- `a3f6973` is the
only commit in this file's history and is the one that recorded these figures, and both manifests
(`.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`) read `1.24.3` at that commit.

| path | median | p95 | min | max | n |
|---|---|---|---|---|---|
| (a) warm-hook per-edit round-trip | **2228 ms** | 2463 ms | 2090 ms | 2633 ms | 30 |
| (b) 000061 closed-loop re-check turn | **2256 ms** | 2398 ms | 2104 ms | 2482 ms | 30 |

Lifecycle signal fired on **30/30 (100%)** of the (b) iterations -- so (b) really is a closed-loop
turn, not a warm turn wearing the wrong label.

### What the numbers say

**The closed loop is effectively free.** Its median sits **28 ms (1.3%)** above the warm baseline --
and its **p95 is 65 ms LOWER**. A path cannot genuinely be both slower at the median and faster at
the p95; the only consistent reading is that the difference is **below run-to-run noise**. For scale,
the warm path's own spread is 543 ms (2090-2633), so the 28 ms median delta is ~5% of the noise floor
it is measured against. The two distributions overlap almost entirely.

That is the substantive result for N1.5: the 000061 correction loop's structural-latency claim, which
until now was an argument from design (a diff of two in-memory finding sets on a pass the daemon was
already making), is now **measured** -- it costs nothing detectable on top of the edit you were
already paying for. There is no latency case against the closed loop.

**The warm path is ~2.2 s, and that is PSES, not the hook.** This is consistent with the independent
figure recorded when the benchmark suite was built (dispatch 000040 measured a ~2.2 s local warm
median), which is a useful cross-check: two harnesses, built for different purposes a dispatch apart,
agree. The time is dominated by the PowerShell Editor Services analysis round-trip; the hook's own
work is a small fraction of it. Optimizing the plugin's PowerShell would move this very little.

## What was measured, exactly

**(a) Warm-hook per-edit round-trip.** One `scripts/lsp-client.ps1` invocation against an
already-warm daemon: the same PostToolUse path Claude Code drives after an edit. Each iteration makes
a **real content change** to the fixture first, so a fresh analysis is timed rather than a cache hit.

**(b) The 000061 closed-loop re-check turn.** The closed loop only fires on a fresh, settled, ok,
**non-cached** pass, so a re-check turn is inherently **two** edits: turn 1 (untimed) surfaces a
finding; turn 2 (**timed**) presents the file with that finding fixed, which is what makes the daemon
diff against the prior surfaced set and emit `cleared[]`. Timing a single edit would measure the warm
path and mislabel it as the closed loop.

The harness **verifies the lifecycle signal actually fired** on each iteration and reports the rate.
That is not decoration: if the loop never fires, (b) is a plain warm turn wearing the wrong label, and
the harness says so rather than publishing the number. The fixture uses an unapproved verb
(`PSUseApprovedVerbs`) rather than `Write-Host`, because `Write-Host` is **not** in the PSES 15-rule
no-settings default set and would have surfaced nothing to clear.

## Method, stated honestly

- **Cold start is EXCLUDED, deliberately.** The daemon is started and primed before any timing begins,
  so these numbers describe the steady state a session feels *after* its first edit -- not the
  once-per-session spin-up. Cold start is measured and threshold-guarded separately in
  `tests/PowerShellLsp.Benchmark.Tests.ps1` (dispatch 000040). **No number on this page includes it.**
- **p95 is nearest-rank, not interpolated.** At 30 samples, interpolating between two neighbours
  invents precision the data does not carry. Every p95 here is an **observed sample**.
- **Deterministic.** Fixed iteration count, fixed fixture content, fixed order, a monotonic nonce per
  iteration. No RNG and no clock-derived input, so two runs differ only by machine noise.
- **Single-machine and INDICATIVE, not comparative.** These are one developer laptop's numbers. They
  characterize an order of magnitude and a shape; they are not a cross-platform claim, not an SLA, and
  not a regression gate. A hosted CI runner is slower and noisier, which is exactly why nothing here
  is used as a threshold.
- **Not CI-wired, deliberately.** The harness runs on demand. `tests/PowerShellLsp.Benchmark.Tests.ps1`
  owns the *guarded* thresholds and keeps them deliberately generous; this page owns the *measurement*.
  Conflating the two would turn an indicative number into a flaky merge gate.
- **Never fabricated.** If the daemon does not reach ready, the harness exits non-zero having measured
  nothing rather than reporting a passing number (the 000040 invariant).
