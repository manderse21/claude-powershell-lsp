# powershell-lsp -- the adopted v1 SLOs and their v1.32.0 baselines

**What this document is.** Five named service-level metrics for the edit path, each with an
exact definition, a named instrument, and a stated exclusion boundary -- plus what each one
measures on the **v1.32.0** release build. It converts Arc E from "make it faster, someday, on
demand" into an instrument: when a scale problem arrives, the program knows what normal looked
like.

**Section 9 is now in force.** The six targets T1-T6 were proposed here as unratified candidates
against v1.31.0 and were **ratified by Mike on 2026-08-21** as the project's **v1 SLOs**. All six
are met at v1.32.0. That makes this document a **regression bar** rather than a description: a
future release that misses one of them is missing an adopted target, not merely reading differently.
The independence rule that produced them is unchanged and still load-bearing -- **no target in
section 9 is back-filled from any measurement in sections 6 to 8**; each states its own basis, and a
measured value is named there only to show where the build sits against an independently chosen
line.

**What this document still does not do.** It proposes no cold-start target. Section 9 explains why
that gap is deliberate rather than an omission, and ratification did not close it.

**How to read a figure here.** Every figure is a **median with spread over a stated N**, taken
against a staged copy of the **release commit**, and labelled **daytime-desktop-class**. There are
no single-run figures. Where a run was excluded, the exclusion and its reason are printed. Where a
number is surprising, it is reported as found.

> **Every figure below is v1.32.0 unless it says otherwise.** v1.31.0 values appear only in a
> clearly-labelled comparison column, never as a current baseline. Several metrics are marked
> **re-measured and unchanged** -- that is a result, not a copy: the number was taken again on the
> new build and landed where it had been.

---

## 1. The build actually measured

Every measurement below drove a **scratch plugin tree staged from `git archive` of the release
commit**, with a private junction-backed data root, never the dev clone -- so the baseline describes
the bytes a user runs. The staging was proven equal to the commit before and after every block by
computing each staged file's git object id and requiring it to equal the blob id in the commit's own
tree (423 tracked paths, 0 missing, 0 differing, tracked-tree digest
`3307d45f0bb0d0b6db3b395a859bf12f593fa047322b5ec6c59860cdfd50ea69`, stable across all blocks).

| Fact | Value | Derivation |
|---|---|---|
| Plugin version | **1.32.0** | `.claude-plugin/plugin.json` at the release commit |
| `v1.32.0` **peeled** tag commit | `fb3116cab14cd8afec4e9c64ed0c2e67e76486b3` | `git rev-parse 'refs/tags/v1.32.0^{}'` |
| Commit the blocks ran at (**C**) | `af6996f971c8e8629a7d005e83f72865f2a66112` | the squash-merge of PR #187 |
| Release identity (**C'**) | `fb3116cab14cd8afec4e9c64ed0c2e67e76486b3` | the squash-merge of PR #188 -- **this is v1.32.0** |
| Are the two the same runtime? | **YES, proven** | see the carry-forward note below |
| Pinned PSES | v4.6.0 | bootstrap marker `pses-v4.6.0.ok` in the data root |
| Pinned PSScriptAnalyzer | 1.25.0 | vendored marker `.pssa-1.25.0.ok` |
| Evidence bundle | [`evidence/v1.32.0/`](../../evidence/v1.32.0/) | in-repo; every figure below traces to a JSON file there |

> **Two commits appear here, and the distinction is load-bearing rather than pedantic.** The
> quantitative blocks ran at **C**; the release identity is **C'**, the merge of the fix PR that
> unblocked the release pipeline. The figures are **carried** from C to C', and the carry is proven,
> not asserted: the C -> C' diff touches **five paths, none of them under `scripts/` or
> `rulesets/`**, and all 36 tracked runtime blobs are **byte-identical** between the two commits.
> The runtime a user executes is the same bytes, so these figures describe v1.32.0 as measured. Had
> a single runtime blob moved, the honest move would have been to re-measure, and the check that
> would have caught it is recorded in the evidence bundle.

**Where these figures come from.** They were produced by the dispatch 000267 freeze block on
**2026-08-19** (block start/end stamps are recorded in each `evidence/v1.32.0/results/m*.json`), and
this document reproduces them rather than re-deriving them independently. Every table below cites
the file it came from.

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
| Measurement date | **2026-08-19** (the v1.31.0 baseline was 2026-08-12) |

**Single machine, single host, single analyzer version.** Everything here is indicative of an
order of magnitude and a shape on one developer laptop. Nothing here is a cross-platform claim, a
CI threshold, or an SLA.

## 2. Load context -- why every figure says "daytime-desktop-class"

The quiescence arc established that this host's true idle is only reachable on a dark machine, and
that a latency measured under load and published as if it were not is worse than no number at all.
Neither the v1.31.0 baseline nor this re-measurement **claims a quiet window or attempted one.**
Both label instead.

A coarse CPU-load observation was taken immediately **before and after** every measurement block
(five samples of total machine CPU percent, plus a process census). At v1.32.0
(`evidence/v1.32.0/results/m*.json`, `load_before` / `load_after`):

| Block | CPU median before | CPU median after | Processes |
|---|---:|---:|---:|
| M1 warm settle | 32% | 18% | 385 -> 383 |
| M2 cold start (small) | 29% | 11% | 379 -> 384 |
| M3/M5 sustained session | 13% | 9% | 392 -> 376 |
| M4/M4b large file | 14% | 12% | 386 -> 375 |

> ### Read this before reading any wall-clock number
>
> **This machine ran materially quieter than the v1.31.0 baseline did.** CPU medians of **9-32%**
> here against **31-57%** there; **375-392** live processes against **547-585**. The v1.31.0 run was
> deliberately attended-parallel, with three concurrent Claude Code sessions each holding their own
> daemon and PSES child; this one was not.
>
> **So the wall-clock improvements below are reported, not claimed.** Every end-to-end wall figure
> fell, and it would be easy and wrong to present that as the release getting faster. The load
> difference is a sufficient alternative explanation for all of it, and this document will not
> arbitrate between the two on one machine.
>
> **`analysisMs` is the honest comparator, and it did not move.** The v1.31.0 baseline's own
> Finding 2 established that the analyzer segment is the load-insensitive one -- its spread was 37 ms
> against 510 ms for the end-to-end wall, a factor of ~14. At v1.32.0 `analysisMs` medians are
> **1405 ms** warm (against 1407) and **1403 ms** across the 120-edit run (against 1404). That is
> re-measured and unchanged, and it is the strongest statement this pair of runs supports.
>
> **The one result the load reading does NOT explain is section 8**, and section 8 says why.

**For the record, what the v1.31.0 census looked like:** 547 to 585 live processes, of which roughly
80 were `statusline.ps1` shells, plus three concurrent Claude Code sessions each running their own
powershell-lsp daemon and PSES child. Wave A ran attended-parallel by charter, so that contention was
part of the measured condition, not an accident. It is recorded here because it is exactly what makes
the two runs' wall-clock figures non-comparable.

**Where load plausibly shows.** The spread attributable to load is concentrated in process startup,
not in analysis -- see the attribution in section 6.1, which is the strongest evidence in this
document that these figures are not simply noise. That attribution is what licenses treating
`analysisMs` as the cross-release comparator, and it is why a 494 ms fall in the warm wall median
between the two runs is reported without a causal claim attached to it.

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
- **The harness ships.** *(Corrected at v1.32.0 -- this line previously read "the harness is a
  scratch artifact and ships nowhere in this repo", which was true of the v1.31.0 baseline and is no
  longer true.)* The measurement and gate scripts are committed at
  [`evidence/v1.32.0/harness/`](../../evidence/v1.32.0/harness/) -- `stage-c.ps1` (stage the release
  commit), `prove-equals-c.ps1` (the equality proof), `measure.ps1` and `run-quant.ps1` (the
  quantitative blocks), plus the gate scripts. Their raw output is beside them in
  `evidence/v1.32.0/results/`. The method is still described here in enough detail to rebuild it, but
  it no longer has to be rebuilt from prose.

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

## 5. The five metrics

Each metric is defined here independently of what it measures. **"Excludes" is part of the
definition**, not a caveat: a metric that does not say what it leaves out cannot be held to a
target -- and since 2026-08-21 these are held to targets.

| # | Metric | Exact definition | Instrument | Deliberately excludes |
|---|---|---|---|---|
| **M1** | Warm per-edit settle latency | Wall time for one PostToolUse edit on an already-warm daemon, from client process start to client process exit, on a file whose content genuinely changed | External process wall clock, plus `enableStats` `totalMs` / `analysisMs` / `connectMs` / `codeActionMs` | Cold start; bootstrap; the very first post-bring-up edits (priming); any pass that did not settle |
| **M2** | Cold start to first-analysis-ready | Wall time from invoking the SessionStart hook to the first edit that returns a **settled** analysis, split into segment A (to the pipe answering `ping`) and segment B (to the first settled pass) | Wall clock around the real hooks; settled-ness from the stats record's `taken` field | PSES/PSSA bootstrap (pre-provisioned, as in a warm machine); the Claude Code session's own startup |
| **M3** | Daemon steady-state memory | `WorkingSet64` and `PrivateMemorySize64` of the daemon process and its PSES child, sampled every 10 edits across a long run, after first-analysis-ready | `Get-Process` against the pids the daemon reports over its own pipe | The transient bring-up peak before first-ready; the client hook processes (short-lived, one per edit); shared/mapped pages counted per-process by the OS |
| **M4** | Large-file settle latency | M1, measured on a large real PowerShell file instead of a small one | As M1 | As M1 -- **and additionally conditional on the session having converged at all**. At v1.31.0 that precondition was the binding issue; at v1.32.0 it holds in 5 of 5 sessions (section 8) |
| **M5** | Sustained-session stability | Drift in per-edit latency and in daemon/PSES memory across a long uninterrupted run of repeated edits, judged as first-quartile versus last-quartile | As M1 plus M3, over 120 consecutive edits | Idle behavior (the 30-minute idle TTL is never reached); multi-day sessions; multi-file working sets |

### Why this large-file size

The fixture is defined by **what it is** -- the largest shipped runtime file -- and not by a byte
count. At v1.32.0 that file measures **251,523 bytes / 4,398 lines**: the plugin's own
`scripts/lib/lsp-common.ps1`, copied into scratch. At v1.31.0 the same file measured 219,682 bytes /
3,881 lines, so the fixture **grew 14.5%** between the two runs, and section 8's improvement is an
improvement on a *larger* file. Three independent reasons for the choice:

1. It is the **largest shipped runtime file in the plugin** (the only larger files in the repo are
   test files). Across the `.ps1`/`.psm1` surface the median is a few hundred bytes and the p95 is
   ~54 KB, so this file is the p100 of the runtime surface.
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

Source: `evidence/v1.32.0/results/m1.json`.

| Segment | median | p95 | min | max | spread | n | v1.31.0 |
|---|---:|---:|---:|---:|---:|---:|---:|
| **End-to-end wall (what a user pays)** | **2503 ms** | 2738 ms | 2415 ms | 2910 ms | 495 ms | 30 | 2997 ms |
| Client `totalMs` (stats log) | 1941 ms | 1998 ms | 1898 ms | 2071 ms | 173 ms | 30 | 2066 ms |
| Daemon `analysisMs` (settle) | **1405 ms** | 1427 ms | 1389 ms | 1433 ms | **44 ms** | 30 | **1407 ms** |
| Client `connectMs` | 30.5 ms | 38 ms | 9 ms | 40 ms | 31 ms | 30 | 12 ms |
| Daemon `codeActionMs` | 3 ms | 6 ms | 2 ms | 10 ms | 8 ms | 30 | 4 ms |

**`analysisMs` is re-measured and unchanged: 1405 ms against 1407 ms, a 2 ms difference inside a
44 ms spread.** On the comparator this document's own Finding 2 identifies as load-insensitive, the
two releases are indistinguishable. The wall and `totalMs` columns both fell; per section 2 those
falls are reported, not claimed, because this host ran much quieter.

**Finding 1 re-measured -- the instrument gap persists, at 562 ms.** The end-to-end wall median still
exceeds the stats log's `totalMs` median, now by **562 ms** (v1.31.0: 931 ms), or **29% of the
recorded figure**. That gap is `pwsh` process spawn plus the dot-source of a ~250 KB shared library
plus the option reads -- real time a user waits, invisible to the only shipped latency instrument.
**An SLO written against `totalMs` would still understate user-visible per-edit latency by more than
half a second**, which is why T2 is written against the wall and not against `totalMs`. The finding
survives; only its magnitude moved, and it moved on a quieter machine, which is consistent with the
gap being mostly process startup.

**Finding 2 re-measured and unchanged -- the variance is startup, not analysis.** `analysisMs` spread
is **44 ms** while the end-to-end wall spread is **495 ms**, a factor of ~11 (v1.31.0: 37 ms against
510 ms, ~14). PSES's analysis of a small file is strikingly deterministic; essentially all
run-to-run variance lives in process startup. This is the fact that makes `analysisMs` the honest
cross-release comparator, so it is load-bearing for every comparison in this document.

**`connectMs` rose from 12 ms to 30.5 ms**, reported as found. It is a small absolute number against
a 2000 ms connect timeout and against a 2503 ms wall, and no mechanism is claimed for it. Recording
it rather than passing over it is the point: a figure that moved 2.5x deserves to be visible even
when it is immaterial to the metric it sits inside.

**Headroom under the shipped cap.** The daemon round-trip governed by `timeoutMs` is
`analysisMs` + `codeActionMs` + debounce + IPC, roughly **1.6 s** against the **5000 ms** cap, so
better than two-thirds of that budget is unused for a small file -- unchanged from v1.31.0, as it
must be, since `analysisMs` did not move. Note this is *not* the same as the 2503 ms a user waits:
most of that wall sits outside anything `timeoutMs` bounds.

### 6.2 M2 -- cold start to first-analysis-ready

**N = 10** independent cold sessions, each with a fresh data root, a fresh session id, and a full
teardown between iterations. Small fixture. **Kept 10 of 10; zero exclusions.**

Source: `evidence/v1.32.0/results/m2.json`.

| Segment | median | p95 | min | max | spread | n | v1.31.0 |
|---|---:|---:|---:|---:|---:|---:|---:|
| SessionStart hook wall (returns detached) | 1627 ms | 2078 ms | 1505 ms | 2078 ms | 573 ms | 10 | 2716 ms |
| **Segment A** -- to the pipe answering `ping` | 2265 ms | 2796 ms | 2080 ms | 2796 ms | 716 ms | 10 | 3643 ms |
| **COLD START -- to first settled analysis** | **6991.5 ms** | 8453 ms | 6470 ms | 8453 ms | 1983 ms | 10 | 9523 ms |
| Edits until the first settled pass | **2** | 2 | 2 | 2 | **0** | 10 | 2 |
| Edits returned "NOT checked" | **1** | 1 | 1 | 1 | **0** | 10 | 1 |

**Finding 3 re-measured -- cold start is still about 3x longer than the pipe-up figure suggests.**
The existing `docs/benchmarks.md` cold-start figures (3287-3371 ms at v1.29.1) measure "the
per-session daemon reaching ready" -- segment A. Measured through to the moment an edit actually
comes back checked, cold start is **6991.5 ms**, against a 2265 ms segment A. Both numbers are
correct about different events; only the second is what a user experiences as "my edits are being
checked now". The *ratio* is the durable part of this finding and it barely moved (2.6x, now 3.1x);
the absolute figures fell on a quieter host. *(The v1.29.1 figures are cited as the historical,
differently-defined measurement they are -- they carry their own build context and are not a current
baseline.)*

**Finding 4 re-measured and unchanged -- exactly one edit per session comes back unchecked,
deterministically.** In 10 of 10 sessions the first post-bring-up edit returned the honest
`incomplete` banner ("this edit was NOT checked") and the second settled. **Spread zero on both
counts, in both releases.** This is the pipe-first design working exactly as documented -- an edit
racing startup gets an honest status rather than silence -- and the cost of that design is **one
unchecked edit per session**, no more and no less, on a small file. Determinism repeated across two
independent 10-session runs on two builds is a considerably stronger statement than it was when this
document first recorded it, and it is the direct basis on which T3 is met.

### 6.3 M3 -- daemon steady-state memory

Sampled every 10 edits across the 120-edit sustained run, **12 samples over 291.9 seconds**, after
first-analysis-ready. Source: `evidence/v1.32.0/results/m35.json`.

| Process / counter | median | p95 | min | max | spread | n | v1.31.0 |
|---|---:|---:|---:|---:|---:|---:|---:|
| Daemon working set | **156.5 MB** | 162 MB | 139.7 MB | 162 MB | 22.3 MB | 12 | 154 MB |
| PSES child working set | **161.8 MB** | 168 MB | 151.4 MB | 168 MB | 16.6 MB | 12 | 164 MB |
| Daemon private bytes | 73.1 MB | 79.4 MB | 67.7 MB | 79.4 MB | 11.7 MB | 12 | 70 MB |
| PSES child private bytes | 58.7 MB | 64.1 MB | 55.4 MB | 64.1 MB | 8.7 MB | 12 | 60 MB |

**Combined steady-state working set: about 318 MB** for the daemon plus its PSES child --
**re-measured and unchanged to the megabyte** (156.5 + 161.8 = 318.3, against 154 + 164 = 318).
Memory is the metric here least exposed to ambient load, so unlike the wall-clock figures this
agreement is a real like-for-like result rather than a reported one.

At the first-analysis-ready moment the pair measured **128.2 MB + 148.9 MB = 277 MB** (v1.31.0:
274 MB); the daemon then rose to ~156 MB by roughly edit 30 and **plateaued** for the remaining 90
edits. The same warm-up-rise-then-flat shape, characterised further in M5.

### 6.4 M4 -- large-file settle latency

**Read section 8 with this.** The figures below remain **conditional on the session having
converged**. At v1.31.0 that precondition was the story, because convergence was the exception. At
v1.32.0 it holds in **5 of 5** sessions, so the table below is now representative rather than
survivorship-selected -- but the conditional is kept in the metric's definition, because it is what
makes the number honest if the precondition ever stops holding.

Pooled across all five converged sessions: **n = 70 kept of 75**, large fixture (251,523 bytes,
4,398 lines). Load context: CPU median 14% before, 12% after. Source:
`evidence/v1.32.0/results/m4b.json`.

| Segment | median | p95 | min | max | spread | n | v1.31.0 |
|---|---:|---:|---:|---:|---:|---:|---:|
| **End-to-end wall** | **3741.5 ms** | 4090 ms | 3484 ms | 4277 ms | 793 ms | 70 | 5071 ms |
| Client `totalMs` | 3209 ms | 3533 ms | 2973 ms | 3746 ms | 773 ms | 70 | 3814 ms |
| Daemon `analysisMs` | 1610.5 ms | 1717 ms | 1514 ms | 1795 ms | 281 ms | 70 | 1665 ms |
| Daemon `codeActionMs` | **0 ms** | 0 ms | 0 ms | 0 ms | 0 ms | 70 | 4 ms |

The v1.31.0 column came from **one** session's 15 samples; this one pools **70** across five, so the
sample base is materially stronger as well as the result.

> **The `codeActionMs` row nearly shipped as "no data", and the reason is recorded rather than
> quietly fixed.** Every one of its 70 samples is exactly **0**, because `lsp-common.ps1` is
> lint-clean on the default surface and the correction-enrichment pass is a no-op. The aggregator
> filtered its inputs with `Where-Object { $_ }`, which discards `0` as falsy, so the summary block
> in `m4b.json` still records this metric as `n=0, median=null`. The recovered figure above comes
> from the raw per-session `keptCodeAction` arrays in the same file -- 70 values, all zero -- and
> that file is left as it was written rather than edited after the fact. **A metric whose true value
> is zero and whose instrument treats zero as absent is indistinguishable from an unmeasured
> metric**, and the only thing that caught it was an n=0 sitting next to a kept-set of 70.

**Finding 5 re-measured -- once converged, a large file is ~15% slower to analyze but ~49% slower to
edit.** `analysisMs` rises from 1405 ms to 1610.5 ms (+15%) for a file roughly 1150x larger, while
the end-to-end wall rises from 2503 ms to 3741.5 ms (+49%). At v1.31.0 the same comparison read +18%
and +69%. The shape of the finding is intact and its cause is unchanged: the extra ~1.2 s sits in the
client, before the daemon is ever contacted, because the client's own pre-passes -- the non-ASCII
byte scan and the in-process parser pre-pass -- both read and parse the whole ~250 KB file in the
hook process, and neither is bounded by `timeoutMs`. **The analyzer scales far better with file size
than the client does**, and that remains the actionable content of this finding.

### 6.5 M5 -- sustained-session stability

**N = 120** consecutive edits on one daemon over **387 seconds**, memory sampled every 10 edits.
**Kept 120 of 120; zero exclusions -- no edit in the entire run failed to settle.**

Source: `evidence/v1.32.0/results/m35.json`.

| Segment | median | p95 | min | max | spread | n | v1.31.0 |
|---|---:|---:|---:|---:|---:|---:|---:|
| End-to-end wall, whole run | 2398.5 ms | 2646 ms | 2220 ms | 3023 ms | 803 ms | 120 | 3103 ms |
| Daemon `analysisMs`, whole run | **1403 ms** | 1421 ms | 1360 ms | 1433 ms | 73 ms | 120 | **1404 ms** |

**Drift, first 30 edits versus last 30 edits:**

| Window | wall median | analysis median |
|---|---:|---:|
| First quartile (edits 1-30) | 2531.0 ms | 1407.0 ms |
| Last quartile (edits 91-120) | 2403.5 ms | 1403.0 ms |
| **Drift (positive = slower at the end)** | **-127.5 ms** | **-4.0 ms** |

**Memory across the run:** the daemon rose from **128.2 MB** at first-ready to ~156 MB by edit 30,
then stayed between **154.4 and 157.3 MB** for the remaining 90 edits, ending at 155.8 MB. PSES's
working set ended at 162.1 MB having started at 148.9 MB. Front-loaded growth to a plateau, the same
shape as v1.31.0.

**Finding 6 re-measured and unchanged -- stability is confirmed, and that is the reportable answer.**
Over 120 edits and 291.9 seconds: latency did not degrade (both medians again moved slightly
*faster*, well inside the run's own spread), **no edit failed to settle**, and memory reached a
plateau rather than climbing. `analysisMs` over the whole run is **1403 ms** against v1.31.0's
1404 ms -- a 1 ms difference across 240 samples on two builds. **There is no leak and no slowdown on
this path at this duration.** The honest bound on that claim is unchanged and stated in section 10:
120 edits over ~5 minutes is not a multi-hour session, and the 30-minute idle TTL was never
exercised. T6 is met on exactly this evidence, and on nothing broader.

## 7. Anomalies, exclusions, and everything that did not go cleanly

Recorded so that the absence of a problem elsewhere reads as a search rather than a silence.

- **Excluded latency runs: zero, across M1, M2, M3 and M5.** Every timed iteration in those blocks
  produced a settled pass. No outlier was discarded, because none needed to be.
- **M4 kept 70 of 75.** The five not kept are the per-session unchecked first edits -- one each, the
  T3 racing edit -- not slow passes. At v1.31.0 this line read "M4's exclusions are total, not
  partial", because non-converging sessions produced no latency figures at all. That is no longer
  the case; see section 8.
- **A `0`-valued metric was nearly reported as absent** (section 6.4). The aggregator's falsy filter
  discarded `codeActionMs = 0`, and only an `n=0` beside a kept-set of 70 caught it. The evidence
  file is left carrying the uncorrected summary so the defect stays visible.
- **One instrument defect was found and fixed mid-dispatch at v1.31.0** (section 4.4), and it changed
  a conclusion. It is recorded rather than quietly corrected, and every figure in this document --
  including the v1.32.0 ones -- was produced by the corrected instrument.
- **Client-relaunched orphan daemons had to be swept at v1.31.0.** Because the client auto-relaunched
  a daemon it believed unreachable (section 8), a session could end owning more daemons than it
  started. At v1.32.0 the scoped sweep found **zero** strays after M1 and after M3/M5
  (`scoped_strays_swept: 0`), which is the same fix showing up from a second direction. **Co-tenant
  daemons were never a candidate for that sweep**, by construction.
- **The capture log wrote inside the staged plugin tree.** Every equality proof recorded
  `dogfood/diagnostics.jsonl` as an ignored byproduct under the plugin root, which is threat-model
  finding **T2.3** showing up as a measurement artifact. It was classified by the commit's own
  `.gitignore` rather than excluded by name, so the proof stayed able to fail. That finding has since
  been fixed -- the capture log now writes under `CLAUDE_PLUGIN_DATA` -- so a future re-run of this
  block should record **no** byproduct inside the plugin root. If it does, something else is writing
  there.
- **Fixture growth is real but immaterial.** The nonce-per-iteration protocol grows the small
  fixture during a block (219 bytes to about 613 bytes over 30 edits). Fixtures were reset to the
  stated sizes between blocks. Given `analysisMs` spread of 44 ms across the block, this is not a
  measurable contributor.

## 8. The headline finding, RESOLVED: the edit path now converges on a large file

At v1.31.0 this section was titled *"the edit path does not converge on a large file"* and it was the
ugliest number in the document. **That finding does not hold at v1.32.0.** It is recorded as resolved
here, with the same discipline the failure was recorded with -- including what the resolution does
*not* establish.

**On the 4,398-line fixture, 5 of 5 cold sessions converge, each at edit 2.** Source:
`evidence/v1.32.0/results/m4b.json`, uniform 15-attempt cap, five independent cold sessions.

| # | converged | at edit | ms | unchecked | daemons launched | auto-relaunches | daemon `settled=True` | CPU before |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| 1 | **yes** | 2 | 13996 | 1 of 15 | 1 | 0 | 14 | 20% |
| 2 | **yes** | 2 | 13623 | 1 of 15 | 1 | 0 | 15 | 14% |
| 3 | **yes** | 2 | 13785 | 1 of 15 | 1 | 0 | 15 | 6% |
| 4 | **yes** | 2 | 13108 | 1 of 15 | 1 | 0 | 15 | 6% |
| 5 | **yes** | 2 | 13065 | 1 of 15 | 1 | 0 | 15 | 9% |

| Measurement | v1.31.0 | **v1.32.0** |
|---|---:|---:|
| Sessions converged (uniform 15-attempt cap) | **1 of 5** | **5 of 5** |
| Cost of convergence | 13 edits / 89,927 ms | **2 edits / 13,623 ms** (median) |
| Daemons launched per session (median) | 3 (min 3, max 4) | **1** (spread 0) |
| Auto-relaunches per session (median) | 3 (spread 0) | **0** (spread 0) |
| Client "daemon unreachable" verdicts | 16 in one session | **0** across all five |

Every column moves in the same direction, with **spread zero on the three count columns**. The result
is not a marginal shift in a noisy statistic; it is the failure mode being absent.

### The mechanism -- and why this is not just a quieter machine

Section 2 is blunt that this host ran quieter, and that every wall-clock improvement is therefore
reported rather than claimed. **This result is the exception, and the reason is specific.**

The v1.31.0 diagnosis was a compounding pair, read from the plugin's own logs:

1. **The daemon's 5000 ms settle cap expires** before PSES publishes a settled analysis of a ~220 KB
   file, so the pass returns `incomplete`. This is precisely the condition
   `lsp-scan-common.ps1:453-466` documents for this very file, and precisely why the **scan** path
   raised its cap to 15000 ms while the edit path was deliberately left at 5000.
2. **While the daemon is busy analyzing, it is not accepting pipe connections.** The client's 2000 ms
   connect timeout expires, the client concludes the daemon is *unreachable* -- a different condition
   from "busy" -- and **auto-relaunches it**. The replacement starts cold and the previous daemon's
   progress is discarded. Six daemons in one session. Abandoned daemons were observed logging
   `settled=True` **after** the client had given up on them: the work completed, with nobody left to
   receive it.

**Two shipped fixes in the 1.32.0 band name exactly that pair.**

- **v1.31.2** (dispatch 000237) fixed the destructive half: a client that abandoned one reply killed
  the whole daemon. Its own text names *"the binding reason a large-file session never converged once
  the relaunch thrash"* began.
- **v1.31.1** fixed the misclassification that started the thrash: *"a live-but-busy analyzer daemon
  is no longer mistaken for an unreachable one, and is no longer relaunched because of it."* Its text
  names this case -- the connect succeeded, the response did not arrive within the hard cap, and *"the
  daemon is alive and still analyzing (the large-file case ...)"*.

The measurement then shows **precisely the signature those fixes predict**: one daemon, zero
relaunches, zero unreachable verdicts, and the analysis surviving to be received. A causal story that
predicts three specific counts in advance, and finds all three at zero-spread, is a materially
stronger claim than "the number improved".

**And the load reading does not fit this result even on its own terms.** At v1.31.0 the session that
*converged* ran at **43%** CPU while failures occurred at **31%, 42%, 52% and 57%** -- the
*lowest*-load session in that block failed. Load did not separate the cases when the failure was
live, so a lower ambient load is a poor explanation for the failure's disappearance now. **On top of
that, the fixture grew 14.5%** (219,682 -> 251,523 bytes): convergence improved on a *larger* file.

### What this resolution does NOT establish

Recorded with the same care the failure was:

- **One host, one OS, one analyzer pin.** Nothing here says the fix holds on other platforms; the
  four CI legs cover them functionally, not for this behaviour.
- **Five sessions is five sessions.** Zero-spread across five is strong for a failure mode that used
  to fire in four of five, but it is not a proof of impossibility.
- **The file-size curve still has two points.** Nothing bounds behaviour between the ~54 KB p95 and
  this ~250 KB p100, which is exactly where a practical answer for real user repositories would live.
- **The underlying cap is unchanged.** The edit path still runs a 5000 ms daemon settle cap, and PSES
  still needs longer than that on this file -- **one edit per session still comes back unchecked**.
  What changed is that the client no longer destroys the daemon that is doing the work. The design
  tension `lsp-scan-common.ps1` documents is still there; it is no longer *compounding*.

**T3 and T4 both moved on this evidence**, and section 9 records them as met. T3 -- at most one
unchecked edit per session -- was "not met on a large file"; it is now met exactly, 5 of 5, spread 0.
T4 -- every shipped `.ps1`/`.psm1` settles on the edit path -- was "Not met"; the p100 file settles.

## 9. ADOPTED v1 SLOs -- ratified by Mike, 2026-08-21

> **These six are in force.** They were proposed in this document as unratified candidates against
> v1.31.0 and were **ratified by Mike on 2026-08-21** as the project's v1 SLOs. **All six are met at
> v1.32.0.**
>
> **Ratification did not change a single number.** Each target is exactly the line that was proposed,
> with exactly the basis it was proposed on -- which is the whole point of having derived them
> independently before measuring against them. **No target below is derived from any measurement
> above.** Where a measured value is named, it is named to show where the build sits relative to an
> independently-chosen line: a comparison, not a derivation.
>
> **What adoption changes is the consequence of missing one.** These stop being descriptions of a
> build and become a **regression bar**: a future release that misses one is missing an adopted
> target, and that is a release-blocking fact to be surfaced, not a number that reads differently.

| # | Adopted target | Independent basis for the number | Standing at v1.32.0 |
|---|---|---|---|
| **T1** | The `timeoutMs`-governed round-trip completes within the shipped **5000 ms** cap on at least 99% of warm edits | The shipped `timeoutMs` default **is** the product's own declared promise: past it, the client degrades to log-only. The target restates a contract the build already ships. | **MET** with room -- ~1.6 s of a 5000 ms budget on a small file; the large-file round trip is ~1.6 s too (`analysisMs` 1610.5 ms, `codeActionMs` 0) |
| **T2** | User-visible per-edit wall stays under **10 s**, with **1 s** named as the aspiration | Published human-response thresholds, external to this project: ~1 s keeps a user's flow of thought unbroken; ~10 s is the limit of sustained attention. | **MET** -- 2503 ms warm, 3741.5 ms on the p100 file. The **1 s aspiration is still not met**, and the instrument gap in section 6.1 says where the time goes |
| **T3** | At most **one** edit per session returns "NOT checked", and only during cold start | The pipe-first design's own stated intent -- an edit racing startup receives an honest status rather than silence. Bounding it at the single racing edit is what "honest status" is *for*. | **MET** on both fixtures -- exactly 1, spread 0, in 10 of 10 small-file sessions and 5 of 5 large-file sessions. Was "not met on a large file" at v1.31.0 |
| **T4** | Every `.ps1`/`.psm1` **shipped in this repository** settles on the edit path | Dispatch 000133 already ratified that these files need up to ~15000 ms, and raised the *scan* cap to match. The edit path was deliberately left at 5000 ms. The target is that the already-ratified fact apply to both paths. | **MET** -- the p100 runtime file settles, 5 of 5 sessions. Was **"Not met"** at v1.31.0; section 8 is the whole story |
| **T5** | Daemon plus PSES steady-state working set stays under **512 MB** | A policy choice about what a background editor helper may cost: roughly 3% of a 16 GB workstation, the low end of machines this plugin targets. Chosen as a round policy ceiling, not fitted to an observation. | **MET** with wide margin -- ~318 MB, re-measured and unchanged to the megabyte |
| **T6** | Over a session-length run, per-edit latency shows no monotonic upward trend and resident memory reaches a plateau | The `idleTtlMin` design intends the daemon to persist across a working session; a resident process that grew without bound would defeat that design. The target is the design's own precondition. | **MET** over 120 edits / 291.9 s -- both medians drifted *faster*, memory plateaued, no edit failed to settle |

**Two of the six were not met when they were proposed.** T3 and T4 were both failing at v1.31.0, and
they were still proposed -- because a target chosen to be already-passing is not a target. They are
met now because v1.31.1 and v1.31.2 fixed the mechanism section 8 describes, not because the line
moved.

**How to read a future miss.** T1, T2 and T5 are met with margin; T3, T4 and T6 are met with **spread
zero**, meaning the evidence for them is categorical rather than statistical. A T3 or T4 miss is
therefore a *behavioural regression* and should be read as one, not as measurement noise.

**Deliberately not proposed, and still not.** No target is offered for cold start to
first-analysis-ready. A defensible line would have to trade off against bootstrap strategy and
against T3, and no basis was found for one that was not simply the measured value rounded -- which is
exactly the back-fill this document forbids. Ratification did **not** close this gap: the cold-start
figure in section 6.2 is a baseline, not a promise. Adopting a seventh target here would require a
basis that does not yet exist.

## 10. What these baselines do not establish

- **One host, one OS, one PowerShell version, one analyzer pin.** No cross-platform claim. The four
  CI legs cover other platforms functionally, not for latency. **This bound now also carries the
  adopted SLOs**: T1-T6 are ratified as targets for the project, but the evidence that they are met
  is single-host evidence.
- **Not a quiet-window measurement, and the two runs were not equally loaded.** Every figure is
  daytime-desktop-class. The v1.32.0 run was materially quieter than the v1.31.0 baseline (section 2),
  so **wall-clock differences between the two are reported, not claimed**. `analysisMs` is the
  load-insensitive comparator, and it did not move.
- **Not a CI-wired gate.** Ratification made T1-T6 a **regression bar the program holds itself to**;
  it did not wire them to a merge gate, and it should not. Wiring a single-host latency number to CI
  would turn an indicative measurement into a flaky gate, which is the mistake `docs/benchmarks.md`
  already warns against. The bar is enforced by re-measuring at a release and reporting the standing,
  not by a red X on a pull request.
- **Sustained means 120 edits over ~5 minutes**, not a multi-hour or multi-day session. The 30-minute
  idle TTL was never reached, and no multi-file working set was exercised. T6 is met over exactly
  that window and claims nothing beyond it.
- **The file-size curve has two points, not a curve.** 219 bytes and 251,523 bytes. Nothing here
  bounds behavior between the repo's ~54 KB p95 and its ~250 KB p100, which is exactly where a
  practical answer for real user repositories would live -- and, since section 8's resolution rests on
  the p100 case, it is also where a re-emergence would be least visible.
- **Section 8's resolution rests on five sessions.** Zero-spread across five is strong for a failure
  mode that used to fire in four of five, and the mechanism was predicted rather than fitted, but it
  is not a proof of impossibility.
- **Prior figures in `docs/benchmarks.md` remain historical.** They were measured at v1.24.3 and
  v1.29.1 with different harnesses and different definitions, and are not restated here as current
  baselines.
- **The harness ships, in `evidence/v1.32.0/harness/`.** It drives `session-start.ps1` and
  `lsp-client.ps1` over stdin against a junction-backed private data root, classifies each edit by a
  stats line-count delta plus the client's banner, samples memory against daemon-reported pids, and
  tears down through the daemon's own `shutdown` action with a scoped verification sweep. Section 4
  carries the detail; the scripts carry the rest.
