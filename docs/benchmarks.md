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

# Per-profile sweep -- what choosing a profile costs, and what it buys

Measured 2026-08-08 at plugin **v1.29.1** (source commit `564afd4`). Host: pwsh 7.6.3 on Windows 11
Pro (10.0.26200), 16 logical cores; PSScriptAnalyzer pinned at 1.25.0. Produced by
`tests/bench/Invoke-ProfileSweep.ps1`, one process per profile.

The section above measures ONE configuration -- whatever the ambient environment resolves to. This
one measures all three shipped profiles (`safe`, `recommended`, `strict`) against the same fixtures
on the same host in the same quiet window, so the columns are comparable to each other rather than
to a remembered number.

## The quiescence gate that licenses every figure below

Five consecutive attempts across the 000170-000204 arc measured this host and FAILED; none had yet
sampled an idle machine, and the standing rail is that a latency measured under load is a wrong
number that is worse than no number because it gets published. **This is the first PASS.** The gate
ran BEFORE the sweep, unchanged in threshold, exclusion semantics and sample protocol.

```
point            : 000207 Gate A v2 attempt 1
started at       : 2026-08-08T04:13:11.1046127Z (UTC)     logical cores : 16
samples          : 30 x 1000 ms
threshold        : 0.15 cores of sustained FOREIGN load (strictly under)
agent root pid   : 33100 (the agent session, read off the probe's own ancestry chain)

---------------- QUIET PRE-FLIGHT ----------------
  busy probe : @(dispatch claims --live --hub '<hub>') -notmatch 'no claims match'
               -notmatch '^\s*$' -notmatch '^ID/PROJECT' -notmatch '^powershell-lsp/000207 '
  exit code  : 0        probe output : (none)        verdict : QUIET

foreign cores, samples 1-30 in order:
  0.0469 0.0156 0.0000 0.0624 0.0155 0.0620 0.0313 0.0313 0.0473 0.0000
  0.0465 0.0312 0.1578 0.0312 0.0475 0.0000 0.0311 0.0628 0.0310 0.0309
  0.0932 0.0156 0.1088 0.0000 0.0630 0.0000 0.0309 0.0157 0.0309 0.0158

exclusion (re-resolved EVERY sample): agent tree 40 pids (root 33100) + probe tree 1 pid
top foreign consumer, final sample: ShellExperienceHost 0.0158 cores

---------------- VERDICT: PASS ----------------
  foreign mean 0.0385 cores   foreign max 0.1578 cores   agent draw 0.1421 cores (excluded)
```

The busy pre-flight is shown with the local hub path elided; the probe itself is hub-agnostic and
takes the check as a parameter. **It is non-vacuous, proven by falsification:** re-running the same
command with the self-exclusion clause dropped emits the live claim row, which is a non-empty output
and therefore a BUSY verdict that would have refused sampling. A pre-flight that cannot report BUSY
is not a pre-flight.

**The sweep is bracketed, and the bracket is reported whole.** A probe taken IMMEDIATELY after the
sweep FAILED at mean 0.7446 cores -- and that FAIL is the sweep's own wake, not the desktop:

- its samples decay monotonically across the run, reaching 0.0156 cores by sample 30;
- the sweep spins up and tears down 33 daemons, and a torn-down daemon's surviving PSES child is
  **reparented out of the agent tree**, so it stops being apparatus and starts scoring as foreign;
- three short probes taken as it drained read 0.0973, 0.0389 and 0.0349 cores (all PASS);
- a full 30-sample probe at the same protocol, taken after the drain, PASSED at **mean 0.0451
  cores, max 0.1399** -- the same window the gate opened.

That is a property of the instrument worth stating plainly: **an immediately-post-sweep quiescence
probe measures the sweep, not the host.** Let it drain first, or the gate reports your own teardown
as ambient load.

## Running it

```powershell
pwsh -NoProfile -File tests/bench/Invoke-ProfileSweep.ps1 -ProfileName safe
pwsh -NoProfile -File tests/bench/Invoke-ProfileSweep.ps1 -ProfileName strict -JsonPath s.json
```

One profile per process, deliberately: a profile is read from the process environment by every hook
the harness spawns, so sweeping all three in one process would mean mutating that environment
between phases and hoping no daemon outlived the change.

## Results

**Cold start** -- SessionStart hook invoked to the per-session daemon reaching `ready`, a fresh
daemon per iteration, torn down after each.

| profile | median | p95 | min | max | n |
|---|---|---|---|---|---|
| safe | **3352 ms** | 3464 ms | 3061 ms | 3464 ms | 10 |
| recommended | **3371 ms** | 4372 ms | 3087 ms | 4372 ms | 10 |
| strict | **3287 ms** | 3597 ms | 3090 ms | 3597 ms | 10 |

**Warm path** -- one edit to diagnostic round-trip against an already-warm daemon, a real content
change per iteration. Cold start excluded by construction.

| profile | median | p95 | min | max | n |
|---|---|---|---|---|---|
| safe | **2215 ms** | 2237 ms | 2195 ms | 2254 ms | 20 |
| recommended | **2316 ms** | 2337 ms | 2274 ms | 2347 ms | 20 |
| strict | **2306 ms** | 2336 ms | 2282 ms | 2340 ms | 20 |

**Surface** -- the dirty fixture `tests/bench/bench-fixture-findings.ps1` analyzed to a settled
pass, with the rendered `additionalContext` measured as the model receives it.

| profile | ruleset | findings | context bytes | diagnostics | formatting block |
|---|---|---|---|---|---|
| safe | (PSES default set) | **4** | **1492** | 1492 | none |
| recommended | base | **7** | **3293** | 2740 | 553 |
| strict | base | **7** | **3293** | 2740 | 553 |

Zero findings would have made every byte figure a measurement of the empty string -- equally small
under all three profiles, and a comparison built on it would look clean and mean nothing. The
harness therefore **exits 5 rather than reporting** when the finding count is not greater than zero.
It did not trip: 4, 7 and 7.

## What the numbers say

**A profile costs about 100 ms on the warm path and nothing on cold start.** `recommended` and
`strict` sit 101 ms and 91 ms above `safe` at the median -- about 4.5%, and cleanly outside the
run-to-run noise (each profile's own 20-sample spread is 59-73 ms). The cost is attributable:
`formatOnEdit=suggest` adds a SECOND warm round-trip that `safe` never makes. Cold start shows no
profile ordering at all; its 3287-3371 ms medians sit inside a single profile's own min-max band, so
the differences there are noise, not signal.

**The reproducibility is the load evidence.** Two independent full sweeps ~25 minutes apart, each
re-bootstrapping its own daemons, agree to within 7 / 11 / 0 ms on the three warm medians (2208 vs
2215, 2305 vs 2316, 2306 vs 2306). Numbers taken across foreign load scatter; these do not.

**`strict` renders byte-identical output to `recommended` HERE, and that is a fixture property, not
a profile property.** Verified by ordinal string comparison, not by eye. `strict` differs from
`recommended` in exactly three resolved knobs -- `perFileCap` 20 -> 0, `scopeToEdit` true -> false,
`keepLastN` 30 -- and on this fixture all three are inert:

- `perFileCap` cannot bind at 7 findings (0 omitted under every profile);
- `scopeToEdit` is already failing open to whole-file, because the benchmark payload carries no
  `tool_response` and so no derivable touched range -- a real PostToolUse edit DOES carry one, and
  that is where `strict` would diverge;
- `keepLastN` is a retention knob and never reaches the rendered surface.

So the honest reading is: **the strict departures do not show up on a 7-finding file edited without
a patch payload.** A larger or more heavily-scoped file would separate the columns. This measurement
does not bound how far.

**The byte delta is the base ruleset plus the formatter, and it splits cleanly.** `base` adds three
rules the PSES 15-rule default set does not carry -- `PSAvoidUsingWriteHost`,
`PSAvoidUsingInvokeExpression`, `PSAvoidUsingEmptyCatchBlock` -- worth 1248 bytes of diagnostics
with their rationale lines, and `formatOnEdit=suggest` adds a 553-byte formatting block. No
`References:` section appeared under any profile, so the `referenceSurfacing=counts` mapping
contributed zero bytes on this fixture; that is a measured absence, not an assertion that the knob
does nothing.

## The timeoutMs ceiling, stated only as far as the p95 carries it

The shipped `timeoutMs` default is **5000 ms**. Against it:

- the worst per-profile warm p95 measured here is **2337 ms** (`recommended`, n=20, nearest-rank),
  which is **53.3% headroom**;
- the worst SINGLE observation across all 60 warm samples is **2347 ms**, or 53.1% headroom;
- the measured wall time is the **whole hook invocation** -- pwsh spawn, module load, round trip --
  while `timeoutMs` bounds only the client's internal cap on the daemon round-trip, a strict subset.
  The real margin under the knob is therefore larger than the figures above, not smaller.

**What this supports:** the shipped 5000 ms default is comfortable, with better than half its budget
unused, on this host, at all three profiles, on these fixtures, under a passing quiescence gate.

**What this does NOT support, and is recorded as still unmet:**

- *No claim that 5000 ms is sufficient anywhere else.* One laptop, 16 cores, one analyzer version.
  A hosted CI runner is slower and noisier.
- *No observation at the boundary.* The harness raises `timeoutMs` to 18000 ms for the measured
  round-trips, so nothing here exercises the 5000 ms cap or shows what truncation looks like.
- *No basis for LOWERING the ceiling.* A lower default would have to be justified on the SLOWEST
  supported host, and this is not that host. The 5000 ms default stands unchanged.
- *No claim for large files.* The fixtures are ~60 and ~85 lines. Analysis time scales with input;
  nothing here bounds a 2000-line module.

One number this supersedes on this host only: the profile map in `scripts/lib/lsp-common.ps1`
records "the warm-path p95 under ruleset=base measured 3292 ms on the build host (n=20), 34.2 pct
headroom." Re-measured at v1.29.1 under a passing gate, the same configuration reads **2337 ms and
53.3%**. Both are single-host figures taken at different builds, and only the newer one was
quiescence-gated; the older comment is left untouched here because this sweep's write surface is
`tests/bench/` and this page, and re-truing a source comment belongs to the dispatch that owns it.

## Method notes specific to this sweep

- **Path bytes are held constant across profiles.** The rendered context embeds the analyzed file's
  absolute path, so a per-run temp scratch directory would make the byte totals differ by the length
  of a GUID rather than by anything about the profile. The scratch directory is a fixed,
  deterministic path shared by all three runs.
- **The dirty fixture is written once and never mutated** during the surface measurement, so every
  attempt analyzes identical bytes. The retry loop exists only because the first pass after a file
  appears can settle as `incomplete`; all three profiles settled on attempt 1.
- **At n=10 a nearest-rank p95 IS the observed maximum,** which is why the cold-start p95 column
  repeats its max column and why the warm path -- the number that feeds the ceiling statement above
  -- runs at n=20 instead, where p95 is the 19th of 20 ordered samples.
- **`recommended`'s 4372 ms cold-start p95 is one outlier,** not a profile effect: its other nine
  samples span 3087-3537 ms. At n=10 a single slow spin-up owns the p95 outright.
- **The profile really was applied.** Each run prints the knobs it resolved through the same
  `Get-PluginOption` the hooks call, and the three runs resolved measurably different sets. A sweep
  whose profile silently failed to resolve would otherwise report three identical columns and read
  as "the profiles do not differ" rather than "the profile was never applied."
