# powershell-lsp -- candidate SLOs and their v1.31.0 baselines

**What this document is.** Five named service-level metrics for the edit path, each with an
exact definition, a named instrument, and a stated exclusion boundary -- plus what each one
measures **today** on the installed v1.31.0 build. It converts Arc E from "make it faster,
someday, on demand" into an instrument: when a scale problem arrives, the program will know what
normal looked like.

**What this document is not.** It adopts no SLO. Section 9 proposes candidate *targets*; every one
of them is **unratified** and awaits Mike's ratification at the Wave A gate review. A benchmark
threshold is not a benchmark result, and the two are derived independently here -- **no target in
section 9 is back-filled from any measurement in sections 6 to 8.**

**How to read a figure here.** Every figure is a **median with spread over a stated N**, taken
against the **installed cache build**, and labelled **daytime-desktop-class**. There are no
single-run figures. Where a run was excluded, the exclusion and its reason are printed. Where a
number is surprising, it is reported as found -- section 8 exists because the ugliest result in
this document is also its most useful one.

---

## 1. The build actually measured

Every measurement below drove the **installed plugin cache build**, never the dev clone, so the
baseline describes what a user runs.

| Fact | Value | Derivation |
|---|---|---|
| Plugin version | **1.31.0** | `.claude-plugin/plugin.json` in the cache tree |
| Cache path | `~/.claude/plugins/cache/claude-powershell-lsp/powershell-lsp/1.31.0` | `~/.claude/plugins/installed_plugins.json`, key `powershell-lsp@claude-powershell-lsp` -> `installPath` |
| Recorded install commit | `e84c44ba0ab06a751672652a10752aca6078b94e` | same manifest, `gitCommitSha` |
| `v1.31.0` **peeled** tag commit | `e84c44ba0ab06a751672652a10752aca6078b94e` | `git rev-parse 'refs/tags/v1.31.0^{}'` |
| Do they agree? | **YES -- byte-identical** | the installed build IS the released tag commit, confirmed rather than assumed |
| Pinned PSES | v4.6.0 | bootstrap marker `pses-v4.6.0.ok` in the plugin data root |
| Pinned PSScriptAnalyzer | 1.25.0 | vendored marker `.pssa-1.25.0.ok` |

**Configuration.** Shipped defaults throughout -- `profile` unset (`safe`), `ruleset`
`pses-default`, `scopeToEdit` true, `formatOnEdit` off, `timeoutMs` 5000, `debounceMs` 150. The
**only** knob changed was `enableStats = true`, which the plugin documents as observe-only and
which never alters the diagnostics surface.

### Host and environment

| Fact | Value |
|---|---|
| OS | Microsoft Windows 11 Pro, 10.0.26200 (build 26200) |
| CPU | AMD Ryzen AI 7 PRO 350 w/ Radeon 860M -- 8 physical / 16 logical cores |
| RAM | 31.14 GB |
| PowerShell 7 host | pwsh **7.6.3** (`C:\Program Files\PowerShell\7\pwsh.exe`) -- the plugin's default `ps_host` |
| Windows PowerShell | **5.1.26100.8875** |
| Measurement date | 2026-08-12 |

**Single machine, single host, single analyzer version.** Everything here is indicative of an
order of magnitude and a shape on one developer laptop. Nothing here is a cross-platform claim, a
CI threshold, or an SLA.

## 2. Load context -- why every figure says "daytime-desktop-class"

The quiescence arc established that this host's true idle is only reachable on a dark machine, and
that a latency measured under load and published as if it were not is worse than no number at all.
This dispatch therefore **does not claim a quiet window and did not attempt one.** It labels
instead.

A coarse CPU-load observation was taken immediately **before and after** every measurement block
(five samples of total machine CPU percent, plus a process census). Observed range across all
blocks:

| Block | CPU median before | CPU median after | Processes |
|---|---:|---:|---:|
| M1 warm settle (run A) | 47% | 33% | 568 |
| M1 warm settle (run B) | 45% | 54% | 576 |
| M2 cold start (small) | 36% | 21% | 570 |
| M3/M5 sustained session | 38% | 36% | 547 -> 568 |
| M4 large-file steady state | 43% | 43% | 571 |
| M4b large-file convergence | 31% - 57% per session | -- | ~575 |

**This is a busy machine, and the census says so plainly:** 547 to 585 live processes, of which
roughly 80 are `statusline.ps1` shells, plus **three concurrent Claude Code sessions each running
their own powershell-lsp daemon and PSES child**. Wave A ran attended-parallel by charter, so that
contention is part of the measured condition, not an accident.

**Where load plausibly shows.** The spread attributable to load is concentrated in process
startup, not in analysis -- see the attribution in section 6.1, which is the strongest evidence in
this document that these figures are not simply noise. **The one result that does appear
load-sensitive is section 8's large-file non-convergence**, and it is flagged there as a candidate
for a quiet-window re-run, which is Mike's call to charter, not this dispatch's.

## 3. The shipped budget chain, and what it lets an SLO promise

Any latency SLO on the edit path is capped by the plugin's own timeout chain, so the chain is
derived here from the installed build rather than recalled.

**Edit path (what four of the five metrics measure):**

| Bound | Value | Where |
|---|---:|---|
| Client hard cap before degrading to log-only | **5000 ms** | `timeoutMs` userConfig default; `lsp-client.ps1:21`, `$HardCapMs = $TimeoutMs` |
| Client pipe connect timeout | **2000 ms** | `lsp-client.ps1:22` |
| Daemon hard cap on any single settled publish | **5000 ms** | `pses-daemon.ps1:33`, `$MaxWaitMs` |
| Daemon quiet period after last publish | **600 ms** | `pses-daemon.ps1:28`, `$SettleMs` |
| Edit coalescing window | **150 ms** | `debounceMs` default |

**Scan path (a different chain entirely):**

| Bound | Value | Where |
|---|---:|---|
| Process cap | 25000 ms | `lsp-scan.ps1:58`, `-TimeoutMs` |
| Client `timeoutMs` | 18000 ms | `lsp-scan-common.ps1:541` |
| Daemon `MaxWaitMs` | 15000 ms | `lsp-scan-common.ps1:467` |

> **Premise nuance, recorded rather than passed over.** This dispatch's charter cited the budget
> chain as "25000 ms process cap -> 18000 ms client timeoutMs -> 15000 ms daemon MaxWaitMs". On
> disk that is the **scan** chain, not the edit chain. The **edit** path -- the path four of these
> five metrics measure -- runs a **5000 ms** client cap over a **5000 ms** daemon settle cap. The
> distinction is not pedantic: it is a **3x** difference in the budget an edit-path SLO may
> promise, and section 8 is a direct consequence of the smaller number. The charter's chain is
> real; it simply governs a different path.

**Integration readiness-gate path (a THIRD chain, dispatch 000236):** the It-time gates that wait
for a warm daemon before an assertion fires. It is neither of the two chains above: it drives the
CLIENT path at raised caps, under a wall-clock ceiling of its own.

| Bound | Value | Where | In force on this path? |
|---|---:|---|---|
| Gate wall-clock budget | **90000 ms** | `Integration.Common.ps1:236`, `Wait-DaemonDiagReady -TimeoutMs` | **YES -- this is the bound that binds** |
| Gate absolute hard cap | **240000 ms** | `Integration.Common.ps1:237`, `$HardCapMs` | YES (ceiling on progress extension) |
| Progress grace per live observation | **45000 ms** | `Integration.Common.ps1:238`, `$ProgressGraceMs` | YES |
| Consecutive dark polls before fast-fail | **3** | `Integration.Common.ps1:239`, `$DarkPollsToFail` | YES |
| Poll backoff ceiling | **4000 ms** | `Integration.Common.ps1:241`, `$MaxPollSleepMs` | YES |
| Per-poll process cap | 25000 ms | `PowerShellLsp.Integration.Tests.ps1:789`, `Get-RulesetDiag -CapMs` | rarely -- 1 of 36 observed polls reached it |
| Client `timeoutMs` | 18000 ms | `PowerShellLsp.Integration.Tests.ps1:789`, `CLAUDE_PLUGIN_OPTION_timeoutMs` | no -- never reached in the observed failures |
| Daemon `MaxWaitMs` | 5000 ms | `pses-daemon.ps1:33` | YES -- it sets the ~5.2 s cost of every poll |
| Daemon `SettleMs` | 600 ms | `pses-daemon.ps1:28` | yes (inside `MaxWaitMs`) |
| BeforeAll daemon launch cap | 60000 ms | `PowerShellLsp.Integration.Tests.ps1:782` | yes, but only at launch |

> **Which bound actually binds, and why the arithmetic matters.** The 000236 charter reasoned that
> because each poll may consume its full 25000 ms process cap, a 90000 ms ceiling "buys as few as
> three attempts". The failing job logs say otherwise: polls cost **~5.2 s**, not 25 s, because the
> **daemon's own `MaxWaitMs` (5000 ms)** ends them -- and the gate got **9, 15 and 12** attempts
> across the observed runs, with exactly one poll ever reaching the process cap. So the process cap
> and the client `timeoutMs` are effectively **not in force** here; the gate's own wall-clock
> ceiling is.
>
> **The 278-byte response, identified.** Both red legs reported `last response length=278`. That is
> the 000022 `incomplete` banner in its PostToolUse envelope plus CRLF -- reproduced to the byte.
> It means the daemon was **alive, serving, and had already resolved its settings** (the daemon log
> records `PSSA settings: honoring rulesets\base.psd1` 1.2 s after PSES init, and the same daemon
> returned all 8 broadened findings 26 s after the gate gave up). The broaden was applied; this was
> never a settings-resolution defect.
>
> **Why polling harder is counterproductive.** `pses-daemon.ps1:1194` clears the prior publish for
> the uri and re-sends a versioned `didChange` on **every** request, so each poll discards the
> analysis it is waiting for and re-queues the work -- the failing run's daemon emitted **nine
> publishes in a 36 ms burst**, one per poll. Each poll also spawns a fresh `pwsh` competing with
> the PSES it is waiting on (one spawn took 24.8 s). The gate therefore **backs off** rather than
> hammering.
>
> **Observed first-request-to-settled on Windows CI** (the basis for the bounds above, not a
> guess): **8.4 s** / **77.1 s** / **125.6 s** / **174.9 s**. The old 90 s ceiling sat *inside* that
> spread, which is why equivalent content went red, green, red, green across four runs -- and why
> the surviving green cleared the ceiling by only **12.9 s**. `$HardCapMs` = 174.9 s worst observed
> + 25 s for one process-cap-killed poll + ~20% margin. `$ProgressGraceMs` = ~1.8x the worst
> observed gap between consecutive live responses (25 s), and is held above `$MaxPollSleepMs` by a
> self-enforcing clamp so the gate can never expire between two polls of a live daemon.

## 4. Method

**Instrument selection.** The shipped instruments were preferred wherever they cover the metric:

- **`enableStats` telemetry** (`logs/stats.jsonl`, one JSONL line per analyzed edit, read by
  `scripts/show-stats.ps1`) supplies `connectMs`, `analysisMs`, `codeActionMs`, and `totalMs`.
- **The daemon pipe protocol** supplies process identity: `{"action":"ping"}` returns the daemon's
  own `pid` and `psesPid`, so memory is sampled against pids the daemon itself names rather than a
  process-name guess. `{"action":"shutdown"}` performs teardown through the product's own path.
- **The real hook entry points** are driven end to end: `scripts/session-start.ps1` fed SessionStart
  JSON on stdin for bring-up, and `scripts/lsp-client.ps1` fed PostToolUse JSON on stdin for each
  edit. No internal function is called directly and no code path is simulated.

### 4.1 What the stats log covers, derived rather than assumed

This was an open question in the charter. Answered from what the log actually records:

`totalMs` is a stopwatch started at `lsp-client.ps1:240` -- **inside an already-running client
process**, after `pwsh` has spawned, after `lib/lsp-common.ps1` has been dot-sourced, and after the
plugin-option and org-policy reads. `analysisMs` is measured daemon-side and spans **exactly** the
`didChange`-to-settle window (`pses-daemon.ps1:1210-1218`); the debounce wait is separate and
outside it. `codeActionMs` covers only the correction-enrichment pass, and is 0 when there are no
findings.

**The stats log therefore covers segments of the warm edit path only.** It does not cover process
spawn, module load, cold start, or memory. Those four are instrumented explicitly here:

- **Uncovered startup cost** -- measured as an **external wall time** around the whole client
  process (`System.Diagnostics.Process`, start to exit), reported alongside `totalMs` so the gap is
  visible rather than inferred. This is quantified in section 6.1 and it is **not small**.
- **Cold start** -- wall-clock from invoking the SessionStart hook, in two segments (section 6.2).
- **Memory** -- `WorkingSet64` and `PrivateMemorySize64` on the pids the daemon reports.

### 4.2 Isolation, and why it was mandatory

All measurements ran against a **private data root** (`%TEMP%\psl-slo-223`) whose
`PowerShellEditorServices` and `modules` directories are **junctions** to the real bundles, with
version markers copied so `ensure-pses` and `ensure-pssa` no-op exactly as they do on a warm
machine. Bootstrap is therefore **excluded** from every figure, matching the existing benchmark
convention.

This is a safety property, not a tidiness preference. `session-start.ps1`'s `Invoke-Reap`
(lines 152-182) iterates `*.json` in its data root's `session/` directory and **kills any recorded
daemon whose heartbeat is at least 90 s stale**. Run against the live data root while three
co-tenant sessions held daemons, it could have killed them. With a private root the `session/`
directory starts empty, so reap has nothing to iterate and **structurally cannot reach a co-tenant
daemon**.

The same scoping governs cleanup: every process kill in this dispatch was filtered on a command
line containing `psl-slo-223`, a string a co-tenant daemon cannot carry.

### 4.3 Protocol

- **Repetitions.** N is stated per metric and justified there. Every reported figure is a median
  with spread; **zero single-run figures appear as baselines.**
- **Real content change per iteration.** The daemon caches by content hash, so each iteration
  appends a unique nonce line. An unmutated re-edit would time a dictionary lookup and report it as
  an analysis.
- **Priming is untimed and reported.** Cold bring-up answers the pipe before PSES can analyze, so
  timing starts only after a settled `daemon-analyze` pass has been observed. The number of priming
  edits consumed is reported per block.
- **Percentiles are nearest-rank, never interpolated.** At these sample counts interpolation
  invents precision the data does not carry.
- **Discard-and-report.** No run is silently dropped. Any iteration that did not produce a settled
  pass is counted, printed with its reason, and excluded from the latency medians only.
- **Scripts live in scratch.** The harness is a scratch artifact and ships nowhere in this repo.
  Its method is described here in enough detail to reproduce; section 10 lists what it does.

### 4.4 One instrument defect found and fixed mid-dispatch

Recorded because it changed a conclusion. The first large-file pass classified each edit by tailing
the last line of `stats.jsonl`. That is wrong: `lsp-client.ps1` writes a stats line **only** when it
received a usable response, so when the client gives up -- connect timeout, hard-cap timeout, daemon
declared unreachable -- **no line is written at all**, and a tailing reader silently re-reads the
*previous* edit's record and attributes it to this one.

The corrected instrument classifies each edit by a **stats line-count delta** plus the client's own
emitted banner, so "the client gave up" is distinguishable from "the client got an answer". Every
figure in this document was produced by the corrected instrument. The defect's practical effect was
to make a non-converging large-file session look as though it were merely returning `incomplete`;
section 8 is written from the corrected reading.

## 5. The five candidate metrics

Each metric is defined here independently of what it measures. **"Excludes" is part of the
definition**, not a caveat: a metric that does not say what it leaves out cannot be held to a
target.

| # | Metric | Exact definition | Instrument | Deliberately excludes |
|---|---|---|---|---|
| **M1** | Warm per-edit settle latency | Wall time for one PostToolUse edit on an already-warm daemon, from client process start to client process exit, on a file whose content genuinely changed | External process wall clock, plus `enableStats` `totalMs` / `analysisMs` / `connectMs` / `codeActionMs` | Cold start; bootstrap; the very first post-bring-up edits (priming); any pass that did not settle |
| **M2** | Cold start to first-analysis-ready | Wall time from invoking the SessionStart hook to the first edit that returns a **settled** analysis, split into segment A (to the pipe answering `ping`) and segment B (to the first settled pass) | Wall clock around the real hooks; settled-ness from the stats record's `taken` field | PSES/PSSA bootstrap (pre-provisioned, as in a warm machine); the Claude Code session's own startup |
| **M3** | Daemon steady-state memory | `WorkingSet64` and `PrivateMemorySize64` of the daemon process and its PSES child, sampled every 10 edits across a long run, after first-analysis-ready | `Get-Process` against the pids the daemon reports over its own pipe | The transient bring-up peak before first-ready; the client hook processes (short-lived, one per edit); shared/mapped pages counted per-process by the OS |
| **M4** | Large-file settle latency | M1, measured on a large real PowerShell file instead of a small one | As M1 | As M1 -- **and additionally conditional on the session having converged at all**, which section 8 shows is the binding issue |
| **M5** | Sustained-session stability | Drift in per-edit latency and in daemon/PSES memory across a long uninterrupted run of repeated edits, judged as first-quartile versus last-quartile | As M1 plus M3, over 120 consecutive edits | Idle behavior (the 30-minute idle TTL is never reached); multi-day sessions; multi-file working sets |

### Why this large-file size

The charter asked for a defensible size rather than a round number. **219,682 bytes / 3,881 lines**
-- the plugin's own `scripts/lib/lsp-common.ps1`, copied into scratch. Three independent reasons:

1. It is the **largest shipped runtime file in the plugin** (the only larger files in the repo are
   test files: `PowerShellLsp.Unit.Tests.ps1` at 4,746 lines is the repo maximum). Across all 164
   `.ps1`/`.psm1` files, the median is 319 bytes and the p95 is 54,102 bytes, so this file is the
   p100 of the runtime surface.
2. It is **real PowerShell the analyzer must genuinely parse**, not synthetic filler.
3. Decisively: **the plugin's own source names this exact file as the binding case.**
   `lsp-scan-common.ps1:453-466` records that "the largest scripts (`lib/lsp-common.ps1`,
   `ensure-pssa.ps1`) need ~6-7 s of PSSA analysis ... and **were reported INCOMPLETE at 5000**",
   which is why the scan path raised its settle cap to 15000 ms while "the in-agent daemon keeps
   5000, so edit latency is untouched."

That third point makes the choice more than defensible -- it means section 8 is measuring a
consequence the codebase already anticipated on one path and deliberately left standing on the
other.

## 6. Results

### 6.1 M1 -- warm per-edit settle latency

**N = 30**, chosen to match the repetition count the existing `docs/benchmarks.md` uses, so the
sample size is not a new variable. Small fixture: 219 bytes, 7 lines, one `PSUseApprovedVerbs`
finding. Priming consumed 2 untimed edits. **Kept 30 of 30; zero exclusions.**

| Segment | median | p95 | min | max | spread | n |
|---|---:|---:|---:|---:|---:|---:|
| **End-to-end wall (what a user pays)** | **2997 ms** | 3246 ms | 2838 ms | 3348 ms | 510 ms | 30 |
| Client `totalMs` (stats log) | 2066 ms | 2162 ms | 1987 ms | 2214 ms | 227 ms | 30 |
| Daemon `analysisMs` (settle) | **1407 ms** | 1424 ms | 1390 ms | 1427 ms | **37 ms** | 30 |
| Client `connectMs` | 12 ms | 15 ms | 10 ms | 17 ms | 7 ms | 30 |
| Daemon `codeActionMs` | 4 ms | 9 ms | 3 ms | 9 ms | 6 ms | 30 |

**Finding 1 -- the instrument gap is 931 ms.** The end-to-end wall median exceeds the stats log's
`totalMs` median by **931 ms**, or **45% of the recorded figure**. That is `pwsh` process spawn plus
the dot-source of a 219 KB shared library plus the option reads -- real time a user waits, invisible
to the only shipped latency instrument. **An SLO written against `totalMs` would understate
user-visible per-edit latency by nearly a second.** This is the single most consequential
measurement-coverage fact in this document.

**Finding 2 -- the variance is startup, not analysis.** `analysisMs` spread is **37 ms** while the
end-to-end wall spread is **510 ms**, a factor of ~14. PSES's analysis of a small file is
strikingly deterministic even on a loaded desktop; essentially all run-to-run variance lives in
process startup. This also bounds how much the load labelling matters: the part of the measurement
most exposed to contention is the part that is not the analyzer.

**Reproducibility.** Two independent N=30 runs, taken about 25 minutes apart with separate daemons
and separate data roots, agree closely: end-to-end wall medians **2926 ms** and **2997 ms** (2.4%
apart), and `analysisMs` medians **1407 ms** and **1407 ms** -- **identical**. Numbers taken across
uncontrolled foreign load scatter; these do not.

**Headroom under the shipped cap.** The daemon round-trip governed by `timeoutMs` is
`analysisMs` + `codeActionMs` + debounce + IPC, roughly **1.6 s** against the **5000 ms** cap, so
better than two-thirds of that budget is unused for a small file. Note this is *not* the same as the
2997 ms a user waits: most of that wall sits outside anything `timeoutMs` bounds.

### 6.2 M2 -- cold start to first-analysis-ready

**N = 10** independent cold sessions, each with a fresh data root, a fresh session id, and a full
teardown between iterations. Small fixture. **Kept 10 of 10; zero exclusions.**

| Segment | median | p95 | min | max | spread | n |
|---|---:|---:|---:|---:|---:|---:|
| SessionStart hook wall (returns detached) | 2716 ms | 3140 ms | 2429 ms | 3140 ms | 711 ms | 10 |
| **Segment A** -- to the pipe answering `ping` | 3643 ms | 4196 ms | 3315 ms | 4196 ms | 881 ms | 10 |
| **COLD START -- to first settled analysis** | **9523 ms** | 10069 ms | 8531 ms | 10069 ms | 1538 ms | 10 |
| Edits until the first settled pass | **2** | 2 | 2 | 2 | **0** | 10 |
| Edits returned "NOT checked" | **1** | 1 | 1 | 1 | **0** | 10 |

**Finding 3 -- cold start is about 2.6x longer than the pipe-up figure suggests.** The existing
`docs/benchmarks.md` cold-start figures (3287-3371 ms at v1.29.1) measure "the per-session daemon
reaching ready" -- segment A. Measured through to the moment an edit actually comes back checked,
cold start is **9523 ms**. Both numbers are correct about different events; only the second is what
a user experiences as "my edits are being checked now". *(The v1.29.1 figures are cited here as the
historical, differently-defined measurement they are -- they carry their own build context and are
not a current baseline.)*

**Finding 4 -- exactly one edit per session comes back unchecked, deterministically.** In 10 of 10
sessions the first post-bring-up edit returned the honest `incomplete` banner ("this edit was NOT
checked") and the second settled. Spread zero on both counts. This is the pipe-first design working
exactly as documented -- an edit racing startup gets an honest status rather than silence -- and it
is quantified here for the first time: **the cost of that design is one unchecked edit per
session**, no more and no less, on a small file.

### 6.3 M3 -- daemon steady-state memory

Sampled every 10 edits across the 120-edit sustained run, **12 samples over 387 seconds**, after
first-analysis-ready.

| Process / counter | median | p95 | min | max | spread | n |
|---|---:|---:|---:|---:|---:|---:|
| Daemon working set | **154 MB** | 157 MB | 140 MB | 157 MB | 17 MB | 12 |
| PSES child working set | **164 MB** | 170 MB | 161 MB | 170 MB | 10 MB | 12 |
| PSES child private bytes | 60 MB | 66 MB | 57 MB | 66 MB | 8 MB | 12 |
| Daemon private bytes | 70 MB | 75 MB | 60 MB | 75 MB | 15 MB | 12 |

**Combined steady-state working set: about 318 MB** for the daemon plus its PSES child.

At the first-analysis-ready moment the pair measured **126.3 MB + 147.9 MB = 274 MB**; the daemon
then rose to ~154 MB by roughly edit 30 and **plateaued** for the remaining 90 edits. That shape --
a warm-up rise to a plateau -- is characterised further in M5.

### 6.4 M4 -- large-file settle latency

**Read section 8 first.** The figures below are **conditional on the session having converged**,
and section 8 establishes that convergence on this file is the exception rather than the rule.
Presenting this table without that precondition would be the most misleading thing in the document.

From the one session that did converge: **N = 15**, large fixture (219,682 bytes, 3,881 lines).
**Kept 15 of 15** within that session; zero exclusions. Load context: CPU median 43% before and
after.

| Segment | median | p95 | min | max | spread | n |
|---|---:|---:|---:|---:|---:|---:|
| **End-to-end wall** | **5071 ms** | 5748 ms | 4477 ms | 5748 ms | 1271 ms | 15 |
| Client `totalMs` | 3814 ms | 4079 ms | 3496 ms | 4079 ms | 583 ms | 15 |
| Daemon `analysisMs` | 1665 ms | 1762 ms | 1564 ms | 1762 ms | 198 ms | 15 |
| Daemon `codeActionMs` | 4 ms | 22 ms | 3 ms | 22 ms | 19 ms | 15 |

**Finding 5 -- once converged, a large file is only ~18% slower to analyze, but ~69% slower to
edit.** `analysisMs` rises from 1407 ms to 1665 ms (+18%) for a file roughly 1000x larger, while the
end-to-end wall rises from 2997 ms to 5071 ms (+69%). The extra ~1.1 s sits in the client, before
the daemon is ever contacted: the client's own pre-passes -- the non-ASCII byte scan and the
in-process parser pre-pass -- both read and parse the whole 219 KB file in the hook process, and
neither is bounded by `timeoutMs`.

### 6.5 M5 -- sustained-session stability

**N = 120** consecutive edits on one daemon over **387 seconds**, memory sampled every 10 edits.
**Kept 120 of 120; zero exclusions -- no edit in the entire run failed to settle.**

| Segment | median | p95 | min | max | spread | n |
|---|---:|---:|---:|---:|---:|---:|
| End-to-end wall, whole run | 3103 ms | 3821 ms | 2618 ms | 4167 ms | 1549 ms | 120 |
| Daemon `analysisMs`, whole run | 1404 ms | 1418 ms | 1362 ms | 1436 ms | 74 ms | 120 |

**Drift, first 30 edits versus last 30 edits:**

| Window | wall median | analysis median |
|---|---:|---:|
| First quartile (edits 1-30) | 3179 ms | 1406 ms |
| Last quartile (edits 91-120) | 3017 ms | 1395 ms |
| **Drift (positive = slower at the end)** | **-162 ms** | **-11 ms** |

**Memory across the run:** daemon working set **+14.1 MB**, PSES working set **+2.3 MB**, PSES
private bytes **-3.4 MB**. The daemon's growth is front-loaded -- 126 MB at first-ready, ~154 MB by
edit 30, then flat between 152 and 157 MB for the remaining 90 edits.

**Finding 6 -- stability is confirmed, and that is the reportable answer.** The charter asked
whether sustained use reveals drift, and noted that stability confirmed is as much a finding as
drift found. Over 120 edits and 6.5 minutes: latency did not degrade (both medians moved slightly
*faster*, well inside the run's own spread), no edit failed to settle, and memory reached a plateau
rather than climbing. **There is no leak and no slowdown on this path at this duration.** The
honest bound on that claim is in section 10: 120 edits over 6.5 minutes is not a multi-hour session,
and the 30-minute idle TTL was never exercised.

## 7. Anomalies, exclusions, and everything that did not go cleanly

Recorded so that the absence of a problem elsewhere reads as a search rather than a silence.

- **Excluded latency runs: zero, across M1, M2, M3 and M5.** Every timed iteration in those blocks
  produced a settled pass. No outlier was discarded, because none needed to be.
- **M4's exclusions are total, not partial** -- see section 8. Non-converging sessions produced no
  latency figures at all rather than slow ones.
- **One instrument defect was found and fixed mid-dispatch** (section 4.4), and it changed a
  conclusion. It is recorded rather than quietly corrected.
- **The first large-file cold-start block crashed after measuring**, when its summary step tried to
  compute a median over an empty kept-set. The measurement itself completed and its data is used;
  only the reporting step failed.
- **Client-relaunched orphan daemons had to be swept.** Because the client auto-relaunches a daemon
  it believes unreachable (section 8), a session can end owning more daemons than it started. Each
  block's teardown was verified, and a scoped sweep filtered on the private data-root path removed
  the strays. **Co-tenant daemons were never a candidate for that sweep**, by construction.
- **Fixture growth is real but immaterial.** The nonce-per-iteration protocol grows the small
  fixture during a block (219 bytes to about 613 bytes over 30 edits). Fixtures were reset to the
  stated sizes between blocks. Given `analysisMs` spread of 37 ms across the block, this is not a
  measurable contributor.

## 8. The headline finding: the edit path does not converge on a large file

This is the ugliest number in the document and the most useful one. It is reported as found.

**On the 3,881-line fixture, a cold session repeatedly fails to ever return a checked edit.** Not
"slowly" -- at all. Across independently measured cold sessions with a uniform 15-attempt cap:

| Measurement | Sessions | Converged | Attempt cap each |
|---|---:|---:|---:|
| **M4b controlled block** (uniform cap, primary figure) | **5** | **1** | 15 |
| M2 large-file cold block | 4 | 0 | 27-29 over ~183 s each |
| M4 first retry (corrected instrument) | 1 | 0 | 25 |
| M4 original block | 1 | 1 | converged, then 15 of 15 settled |
| **Pooled across all cold sessions** | **11** | **2** | (caps differ -- see note) |

The primary figure is **M4b: 1 of 5 cold sessions converged**, because it is the only block with a
uniform attempt cap across sessions. The pooled 2-of-11 row is offered as corroboration only; its
sessions used different caps, so it is a weaker statistic than its larger denominator suggests.

In the single M4b session that did converge, convergence cost **13 edits and 89,927 ms** -- about
**90 seconds** of editing, with 12 edits returned unchecked, before the first checked result. Across
all five sessions the client launched a median of **3 daemons per session** (min 3, max 4) and fired
a median of **3 auto-relaunches per session** (spread 0).

### The mechanism, read from the plugin's own logs

Two failures compound, and neither is visible from the edit's return value alone. From one
non-converging 25-edit session:

| Signal | Count | Source |
|---|---:|---|
| Stats lines written (of 25 edits) | **4** | `logs/stats.jsonl` -- 21 edits produced no record at all |
| Daemon `settled=True` | **0** | `logs/pses-daemon.log` |
| Daemon "analysis did not settle" | 5 | same |
| Client "connect attempt failed" | 32 | `logs/lsp-client.log` |
| Client "daemon unreachable (degrading to log-only)" | 16 | same |
| Client "auto-relaunch: daemon launch fired" | **6** | same |
| Client "auto-relaunch suppressed (cooldown)" | 15 | same |
| Distinct daemons launched in one session | **6** | `pses-server-*.json` count |

1. **The daemon's 5000 ms settle cap expires** before PSES publishes a settled analysis of a 219 KB
   file, so the pass returns `incomplete`. This is precisely the condition
   `lsp-scan-common.ps1:453-466` documents for this very file, and precisely why the **scan** path
   raised its cap to 15000 ms.
2. **While the daemon is busy analyzing, it is not accepting pipe connections.** The client's
   2000 ms connect timeout expires, the client concludes the daemon is *unreachable* -- a different
   condition from "busy" -- and **auto-relaunches it**. The replacement daemon starts cold, and any
   progress the previous one made is discarded. Six daemons in one session.

The two failures reinforce each other: the analysis is slow enough to trip the connect timeout, and
tripping the connect timeout destroys the daemon that was doing the analysis. In one earlier session
the abandoned daemons were observed logging `settled=True` **after** the client had already given up
on them -- the work completed, with nobody left to receive it.

**Why this is a finding and not a re-run.** It would have been easy to keep re-running until a
converging session appeared and publish its tidy 5071 ms. That session exists (section 6.4) and is
reported -- with its precondition stated, because the precondition is the story.

**What it does not establish.** It is not established that this reproduces on other hosts or on
files between the 54 KB p95 and this 219 KB p100.

**Ambient load does not explain it, on this evidence.** The tempting reading is that the machine was
simply busy. The per-session CPU medians refuse that reading: the session that **converged** ran at
**43%**, while failures occurred at **31%, 42%, 52% and 57%** -- the *lowest*-load session in the
block failed. Load may still matter, but it does not separate the cases here, and saying so is more
honest than implying the desktop is the cause. **A quiet-window re-run of M4/M4b would test it
properly, and is offered as a Mike option; this dispatch neither chartered nor attempted one, per
charter.**

## 9. CANDIDATE TARGETS -- UNRATIFIED PROPOSALS, NOT ADOPTED SLOs

> **Nothing in this section is in force.** These are proposals for Mike to ratify, amend, or reject
> at the Wave A gate review. **No target below is derived from any measurement above.** Each states
> its independent basis. Where a measured value is named, it is named only to show where today's
> build sits relative to an independently-chosen line -- which is a comparison, not a derivation.

| # | Candidate target | Independent basis for the number | Where v1.31.0 sits |
|---|---|---|---|
| **T1** | The `timeoutMs`-governed round-trip completes within the shipped **5000 ms** cap on at least 99% of warm edits | The shipped `timeoutMs` default **is** the product's own declared promise: past it, the client degrades to log-only. The target restates a contract the build already ships. | Met with room on a small file (~1.6 s of a 5000 ms budget) |
| **T2** | User-visible per-edit wall stays under **10 s**, with **1 s** named as the aspiration | Published human-response thresholds, external to this project: ~1 s keeps a user's flow of thought unbroken; ~10 s is the limit of sustained attention. | 10 s met (2997 ms); 1 s aspiration not met |
| **T3** | At most **one** edit per session returns "NOT checked", and only during cold start | The pipe-first design's own stated intent -- an edit racing startup receives an honest status rather than silence. Bounding it at the single racing edit is what "honest status" is *for*. | Met exactly on a small file (1 of 1, 10 of 10 sessions); **not met on a large file** |
| **T4** | Every `.ps1`/`.psm1` **shipped in this repository** settles on the edit path | Dispatch 000133 already ratified that these files need up to ~15000 ms, and raised the *scan* cap to match. The edit path was deliberately left at 5000 ms. The target is that the already-ratified fact apply to both paths. | **Not met** -- see section 8 |
| **T5** | Daemon plus PSES steady-state working set stays under **512 MB** | A policy choice about what a background editor helper may cost: roughly 3% of a 16 GB workstation, the low end of machines this plugin targets. Chosen as a round policy ceiling, not fitted to an observation. | Met (~318 MB) |
| **T6** | Over a session-length run, per-edit latency shows no monotonic upward trend and resident memory reaches a plateau | The `idleTtlMin` design intends the daemon to persist across a working session; a resident process that grew without bound would defeat that design. The target is the design's own precondition. | Met over 120 edits / 6.5 minutes |

**Deliberately not proposed.** No target is offered for cold start to first-analysis-ready. A
defensible line would have to trade off against bootstrap strategy and against T3, and this
dispatch found no basis for one that was not simply the measured value rounded -- which is exactly
the back-fill the charter forbids. It is left open for the gate review.

## 10. What these baselines do not establish

- **One host, one OS, one PowerShell version, one analyzer pin.** No cross-platform claim. The four
  CI legs cover other platforms functionally, not for latency.
- **Not a quiet-window measurement.** Every figure is daytime-desktop-class, with three co-tenant
  Claude Code sessions live. Section 8's result is the one plausibly load-sensitive finding.
- **Not a regression gate, and not CI-wired.** These are indicative baselines. Wiring any of them to
  a merge gate would turn an indicative number into a flaky gate, which is the mistake
  `docs/benchmarks.md` already warns against.
- **Sustained means 120 edits over 6.5 minutes**, not a multi-hour or multi-day session. The
  30-minute idle TTL was never reached, and no multi-file working set was exercised.
- **The file-size curve has two points, not a curve.** 219 bytes and 219,682 bytes. Nothing here
  bounds behavior between the repo's 54 KB p95 and its 219 KB p100, which is exactly where a
  practical answer for real user repositories would live.
- **Prior figures in `docs/benchmarks.md` remain historical.** They were measured at v1.24.3 and
  v1.29.1 with different harnesses and different definitions, and are not restated here as current
  baselines.
- **The harness is a scratch artifact and ships nowhere.** It drives `session-start.ps1` and
  `lsp-client.ps1` over stdin against a junction-backed private data root, classifies each edit by a
  stats line-count delta plus the client's banner, samples memory against daemon-reported pids, and
  tears down through the daemon's own `shutdown` action with a scoped verification sweep. Section 4
  carries the detail needed to rebuild it.
