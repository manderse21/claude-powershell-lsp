# powershell-lsp -- developer-experience journey audit, install through upgrade

**What this document is.** The plugin's own journey -- install, first diagnostic, prove-it-works,
a config change, upgrade -- walked as a stranger would walk it, using only what ships, against
five failure modes already observed and measured this week. Every divergence between the
documented path and the experienced path is recorded, and every finding is placed in exactly one
of three ratified categories with the classification argued rather than asserted.

**What this document is not.** It fixes nothing. Not one README line, not one code path, not one
config default. A fixed finding is an unrecorded finding, and this audit's product is the record.
It also adopts no target and appends to no ledger.

**Why the taxonomy carries the weight.** A DX audit that converts every measured imperfection
into an engineering ticket is worse than no audit, because it buries the two or three things that
actually block a stranger under a pile of things that are working as designed. The three
categories exist to keep that from happening:

| Category | The test it must pass |
|---|---|
| **USER-VISIBLE DX DEFECT** | A stranger encounters it and cannot interpret or recover from it with shipped means. |
| **OBSERVABILITY DEFECT** | The behavior may be perfectly acceptable, but doctor / log / status cannot explain it. |
| **EXPECTED TRADEOFF** | Real, perhaps unpleasant, and intentionally bounded -- documented, priced, and recoverable. |

The distinction that matters most is the third against the first. A slow cold start that says so
honestly is a tradeoff. A slow cold start that says something the system does not deliver is a
defect, and the difference is not the latency -- it is what the user was told.

---

## 1. The build walked, and why this tree is what a stranger gets

A docs audit is worthless if it audits a tree no user has. Two facts were established before
anything was walked.

| Fact | Value | How it was derived |
|---|---|---|
| Installed build | **1.31.0** | `~/.claude/plugins/installed_plugins.json`, key `powershell-lsp@claude-powershell-lsp` -> `installPath` |
| Install commit | `e84c44ba0ab06a751672652a10752aca6078b94e` | same manifest, `gitCommitSha`; agrees with the peeled `v1.31.0` tag (cited from `SLO-BASELINES.md` section 1, not re-derived) |
| Stranger-facing surface at `v1.31.0` vs `origin/main` | **byte-identical** | `git diff --quiet v1.31.0..origin/main -- <path>` returned 0 for `README.md`, `commands/`, `docs/configuration.md`, `docs/troubleshooting.md`, and `scripts/` |

That last row is the premise this audit rests on: the `v1.31.0..origin/main` delta is
documentation elsewhere in the tree (`docs/roadmap-ii/`, `docs/upstream/`, `ROADMAP.md`,
`docs/decision-ledger.md`, `docs/RELEASING.md`). **No stranger-facing document and no script
changed between the released tag and the branch this audit lands on**, so auditing this tree is
auditing what a stranger installs. Had they differed, every finding below would have needed a
"which tree?" qualifier.

## 2. Method -- the scratch environment, and why it was mandatory

Every live step ran against a **private data root** (`%TEMP%\psl-dx-228`) whose
`PowerShellEditorServices` and `modules` directories are **junctions** to the real bundles, with
the top-level PSES marker copied so `ensure-pses` and `ensure-pssa` no-op exactly as they do on a
warm machine. The private root's `session/` directory starts **empty**.

That last property is the safety proof, not a tidiness preference. `session-start.ps1`'s
`Invoke-Reap` iterates `*.json` in its data root's `session/` directory and kills any recorded
daemon whose heartbeat is at least 90 s stale. Run against the live data root while co-tenant
sessions held daemons, it could have killed them. With an empty private `session/`, reap has
nothing to iterate and **structurally cannot reach a co-tenant daemon.**

The same scoping governed cleanup: every process predicate was filtered on a command line
containing `psl-dx-228` -- a string that appears in the daemon's `-DataRoot` argument and the PSES
child's `-BundledModulesPath`, and that no co-tenant process can carry -- and excluded the
current PID.

**One measurement-hygiene incident is recorded rather than buried.** The teardown's first
"zero processes remain" proof printed `0` from a `Get-CimInstance` call that had itself failed
with an RPC error on the same line: an empty result from a failed query is indistinguishable
from an empty result from a successful one. The proof was re-derived on a query verified to have
run (2279 processes enumerated), and paired with a **non-vacuity control** -- the same predicate
with the private-root tag removed still matched a live co-tenant daemon, establishing that the
predicate can match daemons at all. Only then was the zero recorded. The first reading would have
published an unproven zero that happened to be correct.

**Final state, verified:** zero daemon or PSES processes from the private root remain; the
private root is removed from disk; the live bundles are intact (168 files under
`PowerShellEditorServices`, 50 under `modules`, both version markers present); co-tenant daemons
were confirmed still running afterwards. The live data root was never the value of
`CLAUDE_PLUGIN_DATA` at any point in the walk.

### 2.1 HOST CONTAMINATION -- what in this document is timing-dependent, and therefore suspect

**The host was saturated while this walk ran.** The machine carried roughly **2,250 orphaned
`statusline.ps1` shells** until shortly after the walk completed, when they were swept. The
teardown's own process enumeration corroborates it independently: **2,256 to 2,279** live
`pwsh`/`powershell` processes across three successive queries. For comparison,
`SLO-BASELINES.md` section 2 recorded **547 to 585** total live processes on this same host --
so this walk ran at roughly **four times** the process count of the baseline it is read against.

This is disclosed here rather than quietly absorbed, because it changes what parts of this
document may be relied on:

| Evidence class | Status | Why |
|---|---|---|
| **Structural findings** -- a documented path that does not resolve, a quoted string that ships nowhere, an environment variable that is absent, a version that is never reconciled, a rule that does or does not fire, a check that reads UNKNOWN by design | **UNAFFECTED** | None depends on how fast anything ran. Each is a path resolution, a string comparison, a presence test, or a finding count, and each is reproducible on a quiet host. D1, D2, D3, O1, O2, O3, O4, T1, T3 and every anchor-1 count are of this class. |
| **Edit-count observations** -- the 2, 5, 3 and 3 unchecked edits in section 3.2 | **CONTAMINATED, DO NOT RELY ON THE NUMBERS** | The count is a race between edit cadence and PSES initialization, and a saturated host lengthens initialization directly. Under this load the counts are expected to be inflated by an unknown factor. They are retained only as evidence that the count **varies**, never as a measurement, and explicitly **not** as a contradiction of `SLO-BASELINES.md`. |
| **Any elapsed-time figure observed during the walk** | **CONTAMINATED, NOT PUBLISHED** | No latency figure from this walk appears as a result anywhere in this document. Every timing claim here is cited from `SLO-BASELINES.md`, which was measured under its own stated conditions. |

**What this does not touch.** The teardown safety proofs are presence/absence facts, not timings:
zero private-root processes remaining, the private root removed, the live bundles and markers
intact, co-tenant daemons alive. Saturation cannot make a process that exists look absent, and
the zero was re-derived on a query verified to have run and paired with a non-vacuity control.

## 3. The journey, documented against experienced

### 3.1 Install (README steps 1 and 2)

**Documented:** three slash commands (`/plugin marketplace add`, `install`, `enable`), then a new
session whose `SessionStart` hook bootstraps PSES and PSScriptAnalyzer and launches one warm
daemon.

**Experienced:** the three `/plugin` commands were **not walked** -- running them would mutate the
live install, which scope forbids (section 6 records this). The bootstrap they lead to *was*
walked, by feeding real `SessionStart` JSON on stdin to the shipped
`scripts/session-start.ps1` against the private root. It worked exactly as documented, and its
log is clear and useful:

```
[16:01:37] --- SessionStart (session=dx228-walk-a) ---
[16:01:40] ran ensure-pses.ps1 (exit 0)
[16:01:46] ran ensure-pssa.ps1 (exit 0)
[16:01:47] launched daemon (detached) for session dx228-walk-a via pwsh (ok=True)
```

**Divergence: none.** The bootstrap is honest about each stage and its exit code.

### 3.2 First diagnostic (README's own headline promise)

**Documented:** the README promises that asking Claude to write
`function Frobnicate-Thing { Get-Process }` returns, in context, *"The cmdlet 'Frobnicate-Thing'
uses an unapproved verb. (PSUseApprovedVerbs)"*.

**Experienced: the promise is kept, and slightly exceeded.** The specimen returned

```
[Warning] line 1, col 10 -- The cmdlet 'Frobnicate-Thing' uses an unapproved verb.
    (PSScriptAnalyzer/PSUseApprovedVerbs)
    why: An unapproved verb makes the command undiscoverable by Get-Command -Verb and makes
         Import-Module warn on every load. Pick the closest verb from Get-Verb.
```

The rule id renders as `PSScriptAnalyzer/PSUseApprovedVerbs` rather than the README's bare
`(PSUseApprovedVerbs)`, and an explanatory `why:` line is added. Both are supersets of the
promise. **This is the single most important thing the audit confirms: the headline claim is
true.**

**Divergence: the number of edits it took.** The README says the first edit "may briefly read
`incomplete` while PSES finishes starting, **then settles on the next edit**." Across four
independent cold sessions in this walk, the number of edits returning "NOT checked" before the
first settled result was 2, 5, 3 and 3 -- never 1.

> **These four counts are CONTAMINATED and are not offered as a measurement.** See section 2.1:
> the host carried roughly 2,250 orphaned shells during this walk, at about four times the
> process count of the baseline. A saturated host lengthens PSES initialization, and the count is
> a race against exactly that window, so these numbers are expected to be inflated by an unknown
> factor. They are retained for one purpose only -- to show the count is **variable** rather than
> fixed -- and they are **not** evidence against `SLO-BASELINES.md`'s measured 1 of 1 in 10 of 10
> sessions, which was taken under a controlled protocol on a far quieter machine.

The structural point survives the contamination, because it comes from the mechanism rather than
from the counts: **nothing in the code bounds this number.** An edit is answered `incomplete`
whenever it arrives before PSES reports ready, so the count is however many edits land inside the
initialization window -- a function of typing speed and machine load, not a promise the plugin
keeps. The mechanism is legible in the daemon's own log:

```
[16:01:52] request action=diagnostics
[16:01:52] diagnostics request while not ready (state=initializing): file:///...build.ps1
[16:01:59] request action=diagnostics
[16:01:59] diagnostics request while not ready (state=initializing): file:///...build.ps1
[16:02:01] PSES initialized
[16:02:07] analyzed file:///...build.ps1 -> 1 record(s); settled=True
```

The count is not a bound the code enforces. It is however many edits happen to land inside the
PSES initialization window, so it scales with how fast the user types, not with anything the
plugin promises. This is treated in section 4, anchor 3, where the tradeoff and the defect in it
are separated.

**Honest bound on that observation.** `SLO-BASELINES.md` measured exactly 1 unchecked edit in 10
of 10 sessions with spread zero, under a protocol with full teardown between iterations. This
walk ran sessions back to back with earlier scratch daemons alive **on a host carrying roughly
2,250 orphaned shells** (section 2.1). That is not a harder-but-representative condition, it is a
pathological one, and it is the more likely explanation of the difference than anything about the
plugin. **The two results are therefore not in conflict, and this document does not treat them as
though they were.** They agree about the mechanism; the count under quiet conditions is
`SLO-BASELINES.md`'s to state, and re-measuring it is out of scope here. What this walk
contributes is the structural observation above -- that no bound exists in the code -- which is
independent of load.

### 3.3 Prove it works (README step 3, the doctor)

**Documented:** two invocations -- `/powershell-lsp:doctor` inside a session, and
`pwsh -File scripts/doctor.ps1` for "the form that still works **outside** a session."

**Experienced:** the out-of-session form **does not run for a stranger.** Invoked verbatim from a
neutral working directory, as someone who installed via `/plugin` and has no clone would:

```
$ pwsh -NoLogo -NoProfile -File 'scripts/doctor.ps1'
The argument 'scripts/doctor.ps1' is not recognized as the name of a script file.
exit 64
```

There is no `scripts/` directory relative to any location a `/plugin` user works in; the script
lives under the plugin cache path, which the README does not give. Recorded as finding **D1**.

**When it does run, it is excellent.** With the path resolved, the doctor's behavior across three
environments:

| Environment | Result |
|---|---|
| `CLAUDE_PLUGIN_ROOT` unset, `CLAUDE_PLUGIN_DATA` unset (a true tool shell) | 5 pass, 0 fail, **6 unknown** of 11 |
| `CLAUDE_PLUGIN_ROOT` set, `CLAUDE_PLUGIN_DATA` unset | 6 pass, 0 fail, **5 unknown** of 11 |
| Both set, data root = the private scratch root (the in-session case) | **10 pass, 0 fail, 1 unknown** of 11 |

Exit code stayed 0 in all three; only a FAIL is non-zero, as documented. In the healthy case the
end-to-end check reported a real diagnostic observed through the same warm daemon and pipe an
edit uses -- the check that distinguishes "analyzed, clean" from "nothing was analyzed", and it
works. (The check prints an elapsed time with its result; that figure is not reproduced here,
per section 2.1, because it was observed under host saturation. What matters for this audit is
that the probe returned its expected finding, which is a presence fact, not a timing.)

### 3.4 A config change (the `ruleset` bump)

**Documented:** `ruleset` defaults to `pses-default` (about 15 rules, `PSAvoidUsingWriteHost` not
among them); setting `base` broadens the surface.

**Experienced: exactly as documented.** The same specimen, carrying both an unapproved verb and a
`Write-Host`, across two sessions:

| `ruleset` | Findings returned |
|---|---|
| `pses-default` | 1 -- `PSUseApprovedVerbs` only |
| `base` | 2 -- `PSUseApprovedVerbs` **and** `PSAvoidUsingWriteHost` |

And the doctor's `Active ruleset surface` check narrates the change in both states, naming the
excluded rule explicitly:

> `ruleset = "pses-default"` -- PowerShell Editor Services' own built-in no-settings rule set is
> active ... (about 15 rules; narrower than the PSScriptAnalyzer CLI default --
> **PSAvoidUsingWriteHost is NOT among them**). Set `ruleset = "base"` ... to broaden it

> `ruleset = "base"` -- the shipped base ruleset is active ... **No repo-local settings file or
> override was found above** `<cwd>`.

**Divergence: none in behavior.** The gap is that the config change is only discoverable by
running the doctor; the silence at the point of use carries no pointer to it. Treated as anchor 2.

### 3.5 Upgrade

**Documented:** the README's "What version am I on" section promises that `version:` and
`provenance floor:` print as header lines above the check table, present even when every check
below is UNKNOWN.

**Experienced:** both header lines were present in **all** doctor runs, including the tool-shell
run where 6 of 11 checks were UNKNOWN. The provenance floor rendered `(undetermined)` under a
fallback data root with an explicit explanation, and `(absent)` under a fresh root. That is the
promise kept precisely.

The upgrade itself was walked by simulation, which is how it really lands: the cache gains a new
version directory beside the old one (this machine holds nine, 1.23.1 through 1.31.0), the data
root is shared and version-independent, and a session already running keeps serving from the old
tree. A session was brought up on **1.30.0**, driven to a settled diagnostic, and then the
**1.31.0** doctor was run against the same data root.

| Question | Answer |
|---|---|
| Does config and data carry forward? | **Yes, structurally.** The data root (`~/.claude/plugins/data/powershell-lsp-claude-powershell-lsp`) is not version-keyed, so the PSES bundle, vendored analyzer, logs and session records carry forward with no migration step and no re-download. |
| Can a stranger tell which version is actually serving? | **No.** |

Scoped to the running session, the 1.31.0 doctor reported:

```
version: 1.31.0
PASS   Warm PSES daemon (runtime)
       the warm per-session daemon is alive and answered on its named pipe (round-trip ok).
summary: 10 pass, 0 fail, 1 unknown (of 11 checks)
```

while the daemon actually serving that session logged itself as
`--- daemon start: powershell-lsp 1.30.0 session=dx228-upgrade ---`. The report contains no
occurrence of `1.30`, `mismatch`, `stale`, or `older`. The session record
(`session/<id>.json`) carries `sessionId, pid, pipe, host, state, started, heartbeat, psesPid`
and **no version field**. Recorded as finding **O2**.

### 3.6 Where the docs send you when something is quiet or wrong

Three paths were followed. Two are good and one is broken:

- **A quiet result.** README -> `Diagnostics status` table -> four statuses with distinct
  remedies. Correct and well-written, with one wording gap recorded as **D2**.
- **A confusing ruleset.** README -> `docs/configuration.md#ruleset` -> the doctor's active-ruleset
  check. This chain works, and the doctor closes it by naming the rule.
- **A latency question.** README `Performance` -> `enableStats` -> `show-stats.ps1`. This chain
  leads to a number that understates what the user waits, with no caveat anywhere along it.
  Recorded as **O1**.

## 4. The five anchor verdicts

Each anchor answers one question: **can a stranger, using only shipped docs and commands,
understand and correctly interpret the behavior?**

### Anchor 1 -- the doctor's five `CLAUDE_PLUGIN_DATA`-blind UNKNOWNs

**Verdict: INTERPRETABLE where it counts, with the remedy text pointing somewhere it should not.**

The observation reproduces exactly. With `CLAUDE_PLUGIN_ROOT` set and `CLAUDE_PLUGIN_DATA` unset,
the summary line reads `6 pass, 0 fail, 5 unknown (of 11 checks)`.

**Premise nuance, recorded rather than passed over.** Of those five UNKNOWNs, **four** are
`CLAUDE_PLUGIN_DATA`-blind: *PSES bundle bootstrapped*, *PSScriptAnalyzer vendored*, *Warm PSES
daemon (runtime)*, and *Test diagnostic observed end-to-end*. The fifth, *PSES child host
(ps_host)*, is not data-blind at all -- it is a deliberate deferral that reads UNKNOWN even in a
fully healthy in-session run, which is why the healthy case is `10 pass, 0 fail, 1 unknown` and
not `11 pass`. With **both** variables unset the count rises to six, adding *Plugin enabled*. The
anchor's count of five is right; the attribution is right for four of the five.

**Why interpretable:** each data-blind UNKNOWN names its own cause and gives a fix, for example

> cannot locate the plugin data directory (CLAUDE_PLUGIN_DATA is not set), so the bundle state is
> indeterminate.
> **fix:** Run this doctor from inside a Claude Code session (where CLAUDE_PLUGIN_DATA is set) for
> a definitive check.

and the provenance-floor line says the same thing in its own words. A stranger is told exactly
what is indeterminate, why, and what to do. This is the four-state honesty model applied to the
doctor itself, and it is the right design.

**Where it breaks:** the fix says "run from inside a Claude Code session." Inside this live,
plugin-enabled Claude Code session, a tool shell was found to carry **neither**
`CLAUDE_PLUGIN_ROOT` nor `CLAUDE_PLUGIN_DATA` -- only `CLAUDE_CODE_SESSION_ID`, `CLAUDE_PID`,
`CLAUDECODE` and friends. So a user who follows the remedy from the most obvious place lands back
where they started. Recorded as **D3**, with its unestablished half stated plainly in section 6.

### Anchor 2 -- the quiet `pses-default` ruleset making a healthy install look inert

**Verdict: INTERPRETABLE, but only through the doctor.**

The effect is real and was reproduced (section 3.4): a file whose only problem is a `Write-Host`
returns nothing at all under the shipped default, and by design a clean result is **silent**, so
"analyzed and clean under 15 rules" and "not analyzed" look identical at the point of use.

What rescues it is that the recovery path is short, shipped, and unusually well written. The
doctor's `Active ruleset surface` check names the active set, names `PSAvoidUsingWriteHost` as
the specific rule a user will notice missing, states which config layer won, and gives the exact
knob to change. Three shipped documents (README `What you get`, `docs/configuration.md#ruleset`,
and the README's corpus section) say the same thing in prose beforehand. A stranger who wonders
"is this thing even running?" has a one-command answer that addresses their actual confusion.

Classified **EXPECTED TRADEOFF** (T1), argued below.

### Anchor 3 -- 9523 ms cold start with exactly one unchecked edit

**Verdict: the cost is interpretable; the documented bound is not.**

The measured figures are cited from `SLO-BASELINES.md` and were not remeasured: cold start to
first settled analysis is **9523 ms** (n=10, spread 1538), of which segment A -- the pipe
answering -- is 3643 ms; and the design costs **exactly one** unchecked edit per session, 10 of
10, spread zero.

Walking it, two different things turned out to be bundled inside "one unchecked edit", and they
classify differently:

1. **That a cold session returns unchecked edits at all** is the pipe-first design working as
   documented. The user gets an honest banner rather than silence, which is the entire point.
   Classified **EXPECTED TRADEOFF** (T2).
2. **That the README states the bound as "then settles on the next edit"** is a different claim,
   and the code enforces no such bound -- an edit is answered `incomplete` whenever it arrives
   before PSES reports ready, however many that turns out to be. Worse, the banner text is
   byte-identical on every one of those edits **and** identical to the banner a *large file* gets
   when it will never settle at all (`SLO-BASELINES.md` section 8: 1 of 5 sessions converged on a
   3,881-line file). So a stranger watching repeated identical "analysis did not complete" lines
   has no shipped means to distinguish *starting up*, *this file is too big*, and *broken*.
   Classified **USER-VISIBLE DX DEFECT** (D4).

   **D4 rests on the two structural facts above -- the absent bound and the indistinguishable
   banner -- not on this walk's edit counts, which section 2.1 flags as contaminated by host
   saturation.** Both structural facts are reproducible on a quiet host, and neither depends on
   how many edits any particular session lost.

The information needed to tell them apart exists and is precise -- the daemon logs
`diagnostics request while not ready (state=initializing)` -- it simply never reaches the user.

### Anchor 4 -- the 931 ms stats-log blind spot

**Verdict: NOT INTERPRETABLE.**

Cited, not remeasured: `totalMs`'s stopwatch starts at `lsp-client.ps1:240`, inside an
already-running client process, after `pwsh` spawn, after the dot-source of a 219 KB shared
library, and after the option reads. The end-to-end wall exceeds it by **931 ms -- 45% of the
figure the instrument reports**.

The walk's contribution is the documentation half. `docs/configuration.md#enableStats` describes
the log as being "for observing analysis latency" and points at `scripts/show-stats.ps1`; that
script prints a stage table ending in a `total` row with p50/p95/n. **Neither the knob's
documentation nor the tool's output states what `total` excludes.** A stranger asking "why do my
edits feel slow?" reaches the only shipped latency instrument, gets a number that is 45% short of
what they are actually waiting, and has nothing to tell them so.

This is the cleanest observability case in the audit: nothing needs to get faster. Classified
**OBSERVABILITY DEFECT** (O1).

The contrast within the same script is instructive and is why this is a defect rather than an
omission: `show-stats.ps1` already carries *exemplary* honesty about a different uncertainty,
printing `NO TELEMETRY FOUND, under a FALLBACK data root -- CANNOT DETERMINE whether none was
ever recorded or it simply is not here.` The discipline exists in the file. It has not been
applied to what the numbers cover.

### Anchor 5 -- daemon session files as the only unconditional liveness instrument

**Verdict: NOT INTERPRETABLE from shipped docs -- and needed exactly when the doctor stops
answering.**

`<data>/session/<id>.json` is written by the daemon and heartbeated, carrying
`sessionId, pid, pipe, host, state, started, heartbeat, psesPid`. It is the discovery source the
doctor itself uses, and it is unconditional: it exists whether or not anything else is working.

Its entire user-facing documentation is **one line in `ARCHITECTURE.md`** (`writes pid/heartbeat
to CLAUDE_PLUGIN_DATA/session/<id>.json`), inside an internal flow diagram. It appears nowhere in
`README.md`, `docs/configuration.md`, `docs/troubleshooting.md`, or any of the three command
documents.

For most users that is fine, because the doctor reads it on their behalf and reports PASS. It
stops being fine at exactly one moment, and that moment is common: with **more than one live
daemon** -- any user running two Claude Code sessions -- the daemon check reports

> found 3 live daemons but no session id, so which one serves THIS session cannot be determined
> from outside it.
> **fix:** Re-run with `-SessionId <session-id>` (or from a context that sets
> `CLAUDE_SESSION_ID`) to scope the check to this session.

The UNKNOWN is honest and correct. The remedy is the problem: `CLAUDE_SESSION_ID` is not set in a
Claude Code tool shell (observed), and `doctor.ps1`'s own comment states the reason -- *"Claude
Code does not expose the session id to a directly-invoked doctor (it arrives only on hook
stdin)"*. So the fix line names a variable the plugin's own source says will never be there, and
does not point at the session directory that would let a user find the id to pass. Classified
**OBSERVABILITY DEFECT** (O3, with the remedy text as O4).

## 5. Classified findings

Ten findings, each in exactly one category. **Zero unclassified.**

### USER-VISIBLE DX DEFECT -- encountered, and not interpretable or recoverable with shipped means

| # | Finding | Why this category and not another |
|---|---|---|
| **D1** | The README's out-of-session doctor invocation, `pwsh -File scripts/doctor.ps1`, exits 64 for anyone who installed via `/plugin`. There is no `scripts/` directory relative to a user's working directory, and the README never gives the cache path. | Not observability: nothing needs explaining, the command simply does not run. Not a tradeoff: nothing is being bought. It is the documented escape hatch for the out-of-session case, and it is the one path a user reaches for precisely when the in-session path is unavailable. |
| **D2** | The README quotes the no-pipe banner as *"analyzer was not reachable -- this edit was NOT checked"*. That string **ships nowhere**. The client ships two distinct banners for this condition, with opposite remedies: *"the analyzer had stopped (e.g. after idle) and is being restarted ... your next edit should be"* (wait) and *"...could not be restarted automatically ... Start a new session to restart it"* (act). | The README collapses two states into one and quotes a third string for both. A user searching their transcript for the documented text finds nothing, and a user told "your next edit should be" who instead needs to restart has been given the wrong instruction. That is misdirection at the point of failure, not a gap in explanation. |
| **D3** | The doctor's data-blind UNKNOWNs advise "run this doctor from inside a Claude Code session (where CLAUDE_PLUGIN_DATA is set)". In this live, plugin-enabled session, tool shells carry neither `CLAUDE_PLUGIN_DATA` nor `CLAUDE_PLUGIN_ROOT`. | The diagnosis is excellent (see anchor 1); the remedy returns the user to the state they are already in. A remedy that cannot be executed from the context that produced the message is a defect in the user's path, not a missing observation -- the observation is already there and is correct. |
| **D4** | The README states the cold-start bound as "then settles on the next edit", but the code enforces no bound -- an edit reads `incomplete` whenever it arrives before PSES reports ready. The banner is byte-identical across every such edit **and** identical to the never-settles large-file case. | The unchecked edits themselves are a tradeoff (T2). This entry is only the **stated bound** and the **indistinguishability**: the user was told one edit, may see several, and has no shipped means to tell startup from a file that will never settle. Recovery requires knowing which case they are in, and nothing tells them. Rests on the two structural facts, **not** on this walk's contaminated counts (section 2.1). |

### OBSERVABILITY DEFECT -- the behavior may be fine; the tooling cannot explain it

| # | Finding | Why this category and not another |
|---|---|---|
| **O1** | `totalMs` -- the only shipped latency instrument -- understates user-visible per-edit wall by 931 ms (45%), and neither `docs/configuration.md#enableStats` nor `show-stats.ps1` says what it excludes. | Not a DX defect: no user is blocked, and the latency itself is largely Claude Code's per-hook `pwsh` spawn, which the README already attributes at roughly 0.7 s. Not a tradeoff: nothing is bought by the instrument being silent about its own boundary. The fix is a sentence, not a speedup. |
| **O2** | After an upgrade, the doctor reports the **tree's** version (`1.31.0`) with a clean `10 pass, 0 fail`, while the daemon serving the session is `1.30.0`. The session record carries no version field; only `pses-daemon.log` stamps it, and nothing points there. | The behavior is arguably correct -- the old daemon keeps working until the session ends, which is better than a mid-session restart. What fails is that no surface reconciles the two, so "which version is actually running?" -- the first question of any support thread, and one the README explicitly promises to answer -- gets a confidently wrong answer. |
| **O3** | The session record is the unconditional liveness instrument and is named in no user-facing document (one internal line in `ARCHITECTURE.md`). | Not a DX defect, because in the single-session case the doctor reads it for the user and answers correctly. It becomes load-bearing only when the doctor cannot answer, which is why it is an explanatory gap rather than a blocked path. |
| **O4** | When multiple daemons are live, the daemon check's remedy names `-SessionId` / `CLAUDE_SESSION_ID`, but `doctor.ps1`'s own comment records that Claude Code never exposes the session id to a directly-invoked doctor. The remedy does not point at `session/` where the id could be found. | Kept distinct from O3 because it is a different surface with a different fix: O3 is documentation that does not exist, O4 is remediation text that exists and misdirects. The UNKNOWN itself is correct and honest -- it is a model of not guessing. |

### EXPECTED TRADEOFF -- real, bounded, documented, priced

| # | Finding | Why this clears the tradeoff bar |
|---|---|---|
| **T1** | The default `pses-default` ruleset surfaces about 15 rules; `PSAvoidUsingWriteHost` and three Error-severity security rules stay quiet until `ruleset = base`. A clean result is silent, so a healthy install can look inert. | Deliberate and stated in three shipped places before the user hits it. One knob broadens it. The doctor names the exact excluded rule and the exact fix. Silence-on-clean is the design choice that keeps always-on context cost at zero -- a real purchase, not an oversight. A stranger can fully resolve the confusion with shipped means, which is precisely the line between this category and a defect. |
| **T2** | A cold session returns unchecked edits while PSES initializes. | The pipe-first design's stated intent: an edit racing startup gets an honest status rather than silence. It is documented in the status table, quantified in `SLO-BASELINES.md`, and the banner is truthful about what happened. The design is bounded (it ends when PSES is ready) and the cost is disclosed. Only the *stated size* of the bound fails, and that is filed separately as D4 rather than being allowed to contaminate this one. |
| **T3** | The doctor can never report all-PASS: `PSES child host (ps_host)` reads UNKNOWN by design even on a perfectly healthy install, so the best case is `10 pass, 0 fail, 1 unknown`. | Deliberate -- it defers rather than deciding the same executable twice -- and self-explaining, with `fix: Nothing to do.` in its own output. The README pre-warns that "benign UNKNOWNs are fine". It cannot move the exit code. The cost is a permanently imperfect-looking summary line, which is the price of not double-counting a check, honestly paid. |

## 6. What was NOT walked, and why

Recorded so coverage is falsifiable rather than assumed. Unknown is not zero.

| Not walked | Reason |
|---|---|
| `/plugin marketplace add`, `/plugin install`, `/plugin enable` | Each mutates the live install, which scope forbids. The bootstrap they lead to was walked directly against the private root. |
| **`/powershell-lsp:doctor`, `:status`, `:scan` as slash commands** | The doctor's end-to-end check drives a real diagnostics request through the live warm daemon. `SLO-BASELINES.md` section 8 established that a busy daemon does not accept pipe connections and that the client responds by declaring it unreachable and auto-relaunching it -- so probing the live daemon could have triggered a co-tenant's relaunch thrash. **Consequence, stated plainly: whether Claude Code injects `CLAUDE_PLUGIN_ROOT` when dispatching a plugin slash command is NOT ESTABLISHED by this audit.** D3 rests only on what was observed -- that tool shells lack both variables, and that the command body fails when they are absent. |
| A genuinely clean-box first install | The private root junctions the real bundles, so the PSES and PSScriptAnalyzer **downloads** never ran. The offline, proxy, and security-control-block paths are therefore unwalked, and the `unavailable` and `degraded` statuses were never observed live -- only `ok` and `incomplete`. |
| Windows PowerShell 5.1 as `ps_host`; macOS and Linux | One host, one OS, one PowerShell (pwsh 7.6.3, Windows 11 Pro). No cross-platform claim. |
| `nativeServe = shim` | Off by default and gated on the upstream client init-handshake bug; exercising it needs the native LSP client, not a hook. |
| `formatOnEdit`, `moduleAwareness`, `referenceSurfacing`, `orgPolicy`, `settingsPath`, `profile` | Only `ruleset` was exercised as the config change, per the charter's single-config-change journey step. |
| The `/plugin` config panel itself | Knobs were set through the `CLAUDE_PLUGIN_OPTION_*` environment seam that the hooks actually read. The panel's own UX -- discoverability, validation, error text -- is unwalked. |
| Large-file non-convergence | Cited from `SLO-BASELINES.md` section 8, not re-walked; re-walking it would have been the remeasurement scope forbids. |
| Any latency figure | No new latency number is published here. Every timing claim is cited from `SLO-BASELINES.md`. |
| **A quiet-host walk** | The host carried roughly 2,250 orphaned shells throughout (section 2.1), swept only after the walk finished. Every timing-dependent observation is therefore withdrawn, and the structural findings -- which is all ten -- are reported on evidence that does not depend on load. A re-walk on the swept host would settle the edit-count question, and is offered rather than assumed. |

## 7. Questions this audit raises but does not answer

- **Does `/powershell-lsp:doctor` work when Claude Code dispatches it?** The command body depends
  on `$env:CLAUDE_PLUGIN_ROOT` and declares `allowed-tools: Bash(pwsh:*)`; tool shells were
  observed to lack that variable. Resolving this needs one run against a live install, which this
  dispatch declined for co-tenant safety. It is the highest-value single question here, because
  D1 and D3 together would mean a stranger has **no** working doctor invocation.
- **How many edits does a cold session really lose, and can "at most one" be ratified?** The
  count question itself is **unanswerable from this walk** -- its observations are contaminated
  by host saturation (section 2.1) and are withdrawn as evidence about magnitude. What stands is
  structural and load-independent: **the code enforces no bound**, so candidate target T3 in
  `SLO-BASELINES.md` ("at most one edit per session returns NOT checked") would be ratifying a
  property nothing currently guarantees. Whether that gap matters in practice needs one clean
  re-run on the now-swept host, which this dispatch did not have and does not attempt.
- **Should the four-state model extend to the client's own banners?** The status table owns four
  daemon-side states in one place (`Get-DiagnosticsStatusBanner`), which is why they are
  consistent. The two client-side no-pipe banners live at `lsp-client.ps1:484` and `:487` and are
  not in that table, which is how D2 arose.

## 8. What works, said plainly

An audit that reports only defects misrepresents the thing it audited.

- **The headline promise is true.** The README's example file returns the README's example
  diagnostic, with an added explanation.
- **The end-to-end check earns its place.** It proved a real diagnostic through the real warm
  daemon, returning the expected finding. It is the check that separates "analyzed, clean" from
  "nothing ran", and it is the reason a silent result can be trusted once it passes.
- **The active-ruleset check is the best piece of DX in the plugin.** It anticipates the exact
  confusion a narrow default creates, names the missing rule, states which layer won, and gives
  the fix.
- **UNKNOWN means unknown.** The doctor refuses to guess which of several daemons serves a
  session, and says why. Most tools would have guessed.
- **Data-root provenance honesty is already solved here.** `(undetermined) -- the lifecycle log
  was searched under a FALLBACK data root, so this run cannot tell an uncaptured signal from one
  it failed to locate` is exactly the discipline O1 asks for, already shipping a few lines away.
- **Upgrades carry state forward with no migration step**, because the data root is not
  version-keyed.
- **The version and provenance-floor header lines are always present**, including when every
  check below them is UNKNOWN -- exactly as the README promises.

## 9. Scope discipline

Nothing was fixed. No README line, no banner string, no doctor remedy, no default. Ten findings
are recorded and none is repaired, because a fixed finding is an unrecorded finding and the gate,
not the auditor, decides which of these ten is worth an engineering ticket.

No ledger was appended. `ROADMAP.md` is untouched. The sibling Wave B and fix-slice dispatches'
files were not read or written. This PR adds exactly one file.
