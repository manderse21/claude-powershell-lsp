# T3 regression survey -- FINDINGS ONLY

> ## NOTHING HERE IS IMPLEMENTED, CHARTERED, OR RE-RATIFIED
>
> No source file was changed. `SLO-BASELINES.md` was not touched and the ratified T3 targets are
> not re-rendered: **the T3 verdict of record for v1.33.0 stands exactly as shipped** -- 1 of 15
> sessions returned two NOT-checked cold-start edits against a target that allows one. Section 6
> **proposes** fix directions with their costs; choosing among them, including choosing none, is
> Mike Andersen's.
>
> Assembled by dispatch **000275** (2026-09-05) against release identity
> **C = `6ab2d24bf254787520ad9449c4e6c17f74ee708d`**, from the shipped evidence bundles at
> `evidence/v1.33.0/results/` and `evidence/v1.32.0/results/`.

---

## 1. The reproduction leg is BLOCKED, and the gate is why

**The charter's first acceptance item -- at least two additional compliant quiet-host m2 runs --
was NOT performed.** The host was not compliant, twice, and the survey's own doctrine says to
refuse rather than measure loud.

Measured with `tests/bench/Invoke-QuiescenceProbe.ps1` in its `-AgentRootPid` form, rooted at the
live agent session (pid `58096`, resolved from the probe's printed ancestry chain rather than
defaulted -- the default root was the launching `pwsh`, which scored the agent's own siblings as
foreign):

| Attempt | Label | Samples | Foreign mean | Foreign max | Agent draw (excluded) | Verdict |
|---|---|---|---|---|---|---|
| 1 | `P1-rooted-at-agent-session` | 20 x 1000 ms | **2.1013 cores** | 6.0025 | 0.4110 | **FAIL** |
| 2 | `P2-second-attempt` | 20 x 1000 ms | **1.1103 cores** | 2.2466 | 0.2729 | **FAIL** |

The bar is **0.15 cores of sustained foreign load**, unchanged since dispatch 000170. Attempt 2 is
half of attempt 1 and still **7.4x the threshold**.

**What the foreign load was, named rather than characterised.** Attempt 1's top foreign consumer
was a `powershell` process at 0.88 cores plus a second `claude` session (pid `57304`) at 0.17
cores; attempt 2's was Chrome (three tabs totalling ~0.50 cores) plus transient processes that had
already exited by the time the sample was scored.

**Nothing was killed to make room, deliberately.** A live co-tenant agent session is expected, not
a casualty (`docs/NIGHT_PROTOCOL.md` section 9), and Chrome is the user's. The
`open_questions_for_cc` pre-authorization for exactly this case governs: *"Record the attempt and
its load record ... and note the shortfall honestly -- do not lower the gate and do not run loud."*

**Consequence, stated plainly:** the frequency-and-margin question -- *how often does the miss
recur?* -- is **not answered by this survey**, and no number in it should be read as answering it.
Everything below is derived from the already-shipped records, which were taken under a passing
gate, and from code reading plus micro-timing that is explicitly bounded rather than published as
latency.

---

## 2. The cold-start delta, C vs v1.32.0

Both blocks are the same 15 sessions the ratified standing was judged on: **m2** (10 sessions, cold
start, small fixture) and **m4b** (5 sessions, large-file convergence). Read from
`t3-rerun-m2.json` / `t3-rerun-m4b.json` at C and `m2.json` / `m4b.json` at v1.32.0.

### 2.1 m2 medians, N=10 on each side

| Metric | v1.32.0 (`af6996f`) | C (`6ab2d24`) | Delta | |
|---|---:|---:|---:|---|
| `sessionstart_hook_wall_ms` | 1627.0 | 1694.0 | **+67.0** | +4.12% |
| `segment_A_pipe_answers_ping_ms` | 2265.0 | 2310.0 | **+45.0** | +1.99% |
| `cold_start_to_first_settled_ms` | 6991.5 | 7026.5 | **+35.0** | +0.50% |
| gap (`cold - segA`), derived | 4581.0 | 4601.0 | **+20.0** | +0.44% |

### 2.2 And the tail got BETTER, which the medians hide

| Spread / extreme | v1.32.0 | C | |
|---|---:|---:|---|
| `cold` spread | 1983 | **1234** | C is 38% tighter |
| `cold` max | 8453 | **7953** | C's slowest session is 500 ms FASTER |
| gap spread | 1807 | **988** | C is 45% tighter |

**Where the added time sits: in segment A, before the pipe answers.** The `segA` delta (+45 ms) is
larger than the `cold` delta (+35 ms), and the residual gap delta is +20 ms. So the added work is
front-loaded into daemon bring-up rather than distributed through settling -- which is the shape
that points at exactly one of the four candidates.

### 2.3 Per-session m2 records -- the unit of evidence, not the aggregate

| # | segA | cold | gap | hookWall | edits | unchecked | | | # | segA | cold | gap | hookWall | edits | unchecked |
|---|---:|---:|---:|---:|---:|---:|---|---|---|---:|---:|---:|---:|---:|---:|
| C-1 | 2848 | 7953 | 5105 | 2083 | 2 | 1 | | | B-1 | 2595 | 7215 | 4620 | 1875 | 2 | 1 |
| C-2 | 2375 | 7237 | 4862 | 1718 | 2 | 1 | | | B-2 | 2230 | 6772 | 4542 | 1643 | 2 | 1 |
| C-3 | 2459 | 7039 | 4580 | 1838 | 2 | 1 | | | B-3 | 2422 | 7476 | 5054 | 1611 | 2 | 1 |
| C-4 | 2430 | 7014 | 4584 | 1789 | 2 | 1 | | | B-4 | 2796 | 7234 | 4438 | 2078 | 2 | 1 |
| **C-5** | **2286** | **7777** | **5491** | **1652** | **3** | **2 <- THE MISS** | | | B-5 | 2080 | 6470 | 4390 | 1520 | 2 | 1 |
| C-6 | 2325 | 7147 | 4822 | 1704 | 2 | 1 | | | B-6 | 2089 | 6719 | 4630 | 1526 | 2 | 1 |
| C-7 | 2283 | 6901 | 4618 | 1664 | 2 | 1 | | | B-7 | 2125 | 6551 | 4426 | 1505 | 2 | 1 |
| C-8 | 2295 | 6865 | 4570 | 1684 | 2 | 1 | | | **B-8** | **2256** | **8453** | **6197** | **1564** | **2** | **1** |
| C-9 | 2217 | 6759 | 4542 | 1601 | 2 | 1 | | | B-9 | 2404 | 7203 | 4799 | 1694 | 2 | 1 |
| C-10 | 2216 | 6719 | 4503 | 1617 | 2 | 1 | | | B-10 | 2274 | 6780 | 4506 | 1679 | 2 | 1 |

**m4b, both sides: all five sessions returned `unchecked = 1`.** So the single miss across all 15
sessions is **m2 session 5, and nothing else**. (C's m4b `daemon_analysisMs` min is 712 ms against
v1.32.0's 1514 -- a faster outlier, not a slower one.)

---

## 3. The four release-window candidates, each dispositioned

Micro-timing was taken at C with `Set-StrictMode -Version Latest`, 400 iterations per operation
after an untimed warm-up. **These are UPPER BOUNDS, not latency figures**: they were taken on the
same non-compliant host section 1 documents, and a loud host inflates them -- which is the
direction that makes them usable for *"could this account for +45 ms?"* and unusable as published
timings.

| Candidate | What it adds on the cold path | Measured | Disposition |
|---|---|---:|---|
| **T5.1** `CurrentUserOnly` resolution | `[enum]::GetNames` on a 4-member enum, once, at pipe construction (`Get-DaemonPipeOptions`) | median **0.04 ms**, p95 0.05 | **DOES NOT CONTRIBUTE** |
| **T2.3** data-root path move | string path resolution; no I/O (`Get-DogfoodLogPath`) | median **0.12 ms**, p95 0.24 | **DOES NOT CONTRIBUTE** |
| **T6.4** rotation size check | one `Get-Item` + length compare at session start (`Invoke-CaptureLogRotation`, no-rotate path) | median **0.28 ms**, p95 0.62 | **DOES NOT CONTRIBUTE** |
| **O2** `pluginVersion` stamping | `Get-PluginVersion` -> manifest path resolution + `Get-Content -Raw` + `ConvertFrom-Json`, on the FIRST call in the daemon process | **34.5-69.3 ms** first call (see below) | **CONTRIBUTES -- and accounts for the whole delta** |

The three sub-millisecond candidates sum to a p95 of **0.91 ms**. They cannot produce a 45 ms
segment-A delta and are excluded by measurement, not by argument.

### 3.1 O2, measured properly -- the cache makes the naive number wrong

`Get-PluginVersion` caches per process (`$script:PluginVersionCache`), so timing it in a loop
reports the *cached* cost (median 0.02 ms) and understates the shipped cold cost to nothing. The
number that matters is the **first call in a fresh process**, measured five times each way:

| Fresh-process condition | first-call `Get-PluginVersion` |
|---|---|
| no JSON warm-up (as shipped) | 44.8, 48.3, 59.5, 59.7, 69.3 ms -- **median 59.5** |
| `ConvertFrom-Json` warmed first on an unrelated payload | 34.7, 41.9, 43.1, 47.4, 50.9 ms -- **median 43.1** |
| the warm-up itself | 12.2-16.8 ms |

So roughly **13-16 ms is the runtime's first-`ConvertFrom-Json` cost** and the remaining **~43 ms
is O2's own work** -- manifest location, raw read and parse. Warming JSON does not make it cheap.

### 3.2 It is new at C, and it sits inside segment A

`git diff v1.32.0..6ab2d24 -- scripts/pses-daemon.ps1` adds `pluginVersion = (Get-PluginVersion)`
inside `Write-SessionFile`. The daemon's bring-up order is:

```
1471  $server = New-DaemonPipeServer -PipeName $pipeName     # pipe instance exists
1472  Write-SessionFile $pipeName 'starting'                 # <-- O2's first Get-PluginVersion
1474  Start-PsesProcess
...
1549  $connectTask = $server.WaitForConnectionAsync()        # the server first ACCEPTS here
```

`segment_A_pipe_answers_ping_ms` measures the pipe **answering a ping**, not merely existing -- so
O2's ~43 ms lands squarely between pipe construction and the first accept, i.e. **inside segment
A**. Measured segA delta: **+45.0 ms**. Bounded O2 cost: **~43 ms**. That is as close an
attribution as this evidence can support, and it is the only one of the four that survives.

---

## 4. The second-edit race: BOUNDED, and the window NARROWED

The freeze run's confound note hypothesized a second edit racing startup.

**The shape is confirmed present** -- it is the only mechanism by which a miss can occur at all.
Session C-5 is the sole session on either side with `edits_until_first_settled = 3`; every other
session on both sides converged at 2. An extra edit was issued before the daemon settled, and that
extra edit is the second NOT-checked return.

**But the race window did not widen at C. It narrowed.** The window is the gap between segment A
completing and PSES settling:

- gap median: 4581 -> 4601 ms (**+20 ms, +0.44%**)
- gap **spread**: 1807 -> 988 ms (**45% tighter**)
- gap max: 6197 -> 5491 ms (**706 ms smaller**)

A hypothesis that the release window widened the race is **refuted by its own metric**.

---

## 5. What the evidence actually supports -- and the counterexample that decides it

**The delta is attributable. The miss is not.** These are different questions and the survey
separates them.

> ### The counterexample
>
> | | segA | cold | gap | edits | unchecked |
> |---|---:|---:|---:|---:|---:|
> | **v1.32.0 session 8** | 2256 | **8453** | **6197** | 2 | **1** |
> | **C session 5 (the miss)** | 2286 | 7777 | 5491 | 3 | **2** |
>
> The v1.32.0 session was **slower on every axis** -- 676 ms longer cold, 706 ms wider race window,
> comparable segment A -- and it **did not miss**. The C session that missed was **not the slowest
> session at C on any axis**: C-1 was slower on both `segA` (2848 vs 2286) and `cold` (7953 vs
> 7777), and returned one unchecked edit.

**Therefore no monotone timing threshold on `segA`, `cold`, or the gap explains the miss**, and the
+45 ms that O2 demonstrably adds cannot be what flipped it: a uniform shift of that size does not
select a session that was faster than several that did not flip, while leaving a slower baseline
session unflipped.

**What is left, stated with its uncertainty.** The charter named three possibilities. On this
evidence:

1. **A real regression caused by the four changes** -- *not supported.* Three are sub-millisecond;
   the fourth's +43 ms is real but does not order the sessions the way a threshold effect would.
2. **A widened race window** -- *refuted.* The window narrowed on median, spread and max.
3. **An unlucky draw against a categorical target** -- *the reading the evidence best supports.*
   T3's count clause is binary per session, ratified at N=15 with spread zero. A spread-zero sample
   at N=15 is *consistent with* an underlying miss rate anywhere from 0 to roughly 1-in-5 at
   ordinary confidence; observing 1-in-15 afterwards is not, by itself, evidence that anything
   changed. **The ratification's spread zero may simply have been a fortunate draw** -- which the
   charter itself raised as a candidate, and which this survey cannot exclude.

**The honest limit: N=15 on each side cannot distinguish a low-rate recurring defect from noise.**
That is exactly what the blocked reproduction runs existed to settle, and they did not run. **No
conclusion here should be read as clearing the code.**

---

## 6. Proposals for ruling -- costed, none chartered

| # | Proposal | What it buys | Cost | Recommended? |
|---|---|---|---|---|
| **P1** | **Re-run the m2 block on a genuinely quiet host** (no agent sessions, no browser), at least 3 x 10 sessions | The only thing that separates possibility 1 from possibility 3. Everything else in this docket is bounded by N | ~1 hour wall clock, attended, zero code | **Yes -- before any fix.** A fix chartered against an unlucky draw is a fix for nothing |
| **P2** | **Move O2's `Get-PluginVersion` off the pre-accept path** -- stamp `pluginVersion` on the FIRST session-file write that happens after the serve loop is accepting, or pre-resolve it before the pipe is constructed so the cost lands where it is not measured | Recovers the measured ~43 ms of segment A. Honest framing: it recovers a 2% median, not a fix for the miss | ~2-3 h including a RED control that proves the stamp still appears in the session record | **Only if P1 shows the miss recurring.** On its own this is a tidiness change wearing a fix's clothes |
| **P3** | **Widen the ratification sample** -- re-ratify T3's spread basis at N=45 rather than N=15 | Makes "a miss is a behavioural regression" a statement the sample can actually support. Section 9's spread-zero reading is doing heavy lifting on 15 observations | ~2 h measurement, plus a ruling to re-open a ratified target | **Consider after P1.** Note this is a TARGET change and is out of scope for any survey to take |
| **P4** | **Do nothing; record the miss as a documented single-sample event** | Costs nothing and is defensible if P1 shows no recurrence | Zero | **Viable.** The record already ships honestly |

**The recommended order is P1, then re-read this section.** P2, P3 and P4 all depend on what P1
finds, and none of them should be chartered before it.

---

## 7. What this survey deliberately did not do

- **No code changed.** Not one line, including the O2 path it attributes the delta to.
- **`SLO-BASELINES.md` untouched**, and the T3 verdict of record is not re-rendered.
- **The shipped v1.33.0 release, its notes and its merged evidence bundle stand as published.**
- **No reproduction run was performed on a loud host** -- the two refusals are recorded in section
  1 rather than worked around, and no gate was lowered.
- **No aggregate was allowed to hide a session.** Every one of the 15 sessions on each side appears
  individually in section 2.3, which is how the counterexample in section 5 was found at all.
- **No figure was carried from prose or memory.** Every number here was read from the evidence
  JSONs or measured at C during this dispatch.
