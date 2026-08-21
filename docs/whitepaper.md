# powershell-lsp: A Status-Honest PowerShell Diagnostics Client for Coding Agents

> **DRAFT (v1.32.0-final) for Mike Andersen's review -- nothing published.** Full paper from the
> outline ratified by dispatch 000262, finalized against the shipped release **v1.32.0**, tag commit
> **`fb3116c`** (release identity C'). Every figure was measured against that commit by dispatch
> 000267 (freeze 1B) and read from its outbox on 2026-08-19; the runtime was proven byte-identical
> to the measured commit. This version supersedes the earlier v1.31.0-scoped drafts: the release now
> exists, is Apache-2.0, ships an offline bootstrap, and carries verified SBOM/SLSA/Sigstore
> attestation, so the version-boundary caveats are gone and the Evidence Snapshot describes one
> artifact. Nothing here is published; external publishing is the maintainer's gate.
>
> **Claim labels:** **[V]** verified from code/tests/docs, **[M]** measured, **[I]** inferred,
> **[P]** proposed, **[U]** unverified. A **[U]** claim never appears as fact.

## Evidence Snapshot -- one release, one commit, one evidence set

| Claim family | Evidence state |
|---|---|
| Product behavior, architecture, contract | v1.32.0 / `fb3116c` **[V]** |
| Performance / SLO figures | Measured at `fb3116c` by dispatch 000267, one desktop-class Windows host **[M]** |
| Large-file convergence | Measured at `fb3116c`: **5 of 5** sessions converge (the prior non-convergence is resolved) **[M]** |
| Apache-2.0 license | **Shipped in v1.32.0** (first Apache release; earlier tags keep the license they shipped under) **[V]** |
| Offline / air-gapped bootstrap | **Shipped in v1.32.0**, verified at `fb3116c` **[V][M]** |
| Supply-chain attestation | SBOM + SLSA provenance + Sigstore-signed tag, all verified bound to `fb3116c` **[V]** |

---

## Abstract

Editor-bound PowerShell tooling is unavailable in the environments where coding agents increasingly
do their work: headless shells, SSH sessions, CI runners, and containers with no editor process to
host a language server **[V]**. `powershell-lsp` addresses that gap not by re-implementing analysis
but by acting as a **client** of PowerShell Editor Services (PSES): as an agent edits a `.ps1`,
`.psm1`, or `.psd1`, the plugin runs PSES plus PSScriptAnalyzer over that file through a warm
per-session daemon and returns the result -- syntax errors and lint findings with fix suggestions --
into the same agent turn that made the edit **[V]**. Its distinguishing property is that a result is
never silently wrong: every analyzed edit resolves to one of four explicit status tokens, so an
agent can tell "analyzed and clean" from "not actually analyzed" **[V]**. The diagnostics it reports
are checked against a curated corpus rather than asserted -- an observed 0% false-positive rate over
50 known-good cases and 100% coverage over 36 known-bad, recomputed on every CI run and floored so
the rate cannot be improved by shrinking the oracle **[M]**. The plugin adds no analysis capability
of its own and inherits PSES's limits. A large-file edit-path non-convergence documented at v1.31.0
was fixed in the v1.31.1/v1.31.2 daemon-recovery work and verified resolved at the shipped commit
(5 of 5 sessions converging on a 251 KB file) **[M]**; the paper reports that inversion in full, and
states plainly that whether the plugin makes an agent write *better* PowerShell remains unmeasured
**[U]**.

## Executive Summary

The product, in one paragraph. When an agent edits a PowerShell file in Claude Code, a PostToolUse
hook connects to a warm PSES daemon that has stayed hot for the whole session, requests diagnostics
for the edited file, and feeds them back into the agent's context so a mistake can be corrected in
the same turn **[V]** (`ARCHITECTURE.md`, "The lifecycle: edit -> banner"). One PSES process serves
the entire session, so each edit pays a local named-pipe round-trip -- a measured 2503 ms end-to-end
median warm -- rather than a cold start **[M]**.

The distinguishing property is status honesty. Every analyzed edit resolves to exactly one of four
tokens -- `ok`, `incomplete`, `degraded`, `unavailable` -- and only `ok` renders an empty banner
**[V]** (`ARCHITECTURE.md`, "The status taxonomy"). "Analyzed, clean" is therefore never confused
with "not actually analyzed," the failure mode that makes silent tooling dangerous to an agent that
treats silence as a pass.

The honest counterweights, stated here rather than deferred. The shipped attestation -- a CycloneDX
SBOM, SLSA build provenance, and a keyless-signed release tag -- attests build integrity over the
source archive; it is **not** Windows Authenticode, asserts **no** verified-publisher identity, and
is **not** a third-party security audit **[V]** (`TRUST.md`, "Honest limits"). And the one measured
result the paper most expects to be challenged is the one it cannot supply: whether the tool improves
agent-written PowerShell is unmeasured, and the A/B that would answer it was declined for lack of a
written pre-registration rather than run improvisationally **[V][U]**. The paper is written so a
skeptical reader finds these limits stated by the author rather than discovering them unaided.

## 1. Problem and Context

Agents edit PowerShell where an editor extension is not present. That is the environment clause of
the project's stated purpose: to be the PowerShell layer a coding agent can be trusted with **in
headless, automated, and enterprise environments where editor-bound tooling is insufficient or
unavailable** **[V]** (`ROADMAP.md`, "North Star"). The clause settles what the project is *not*: not
a race to match what a VS Code extension already does well at the keyboard. In an editor, a human
reads a squiggle and decides. In an agent loop, nothing reads the squiggle unless it is placed into
the model's context, and nothing distinguishes "no findings" from "analysis never ran" unless the
tooling says which.

A wrong finding costs more than a missing one. The project treats that asymmetry as a design axis:
defaults stay narrow, and every broadening decision is gated on a measured false-positive bar
**[V]** (`ROADMAP.md`, "Top risks"). A concrete consequence is that the effective default surfaced
ruleset is deliberately narrower than raw PSScriptAnalyzer **[V]** (`README.md`,
"Diagnostic-correctness corpus").

**What "six rules" means, since the number recurs.** The paper uses "six" to mean the count of
distinct rules the known-bad corpus observes surfacing on the live edit path under default config
**[M]**; at the shipped commit those six are `PSAvoidDefaultValueSwitchParameter`,
`PSAvoidUsingCmdletAliases`, `PSAvoidUsingPlainTextForPassword`,
`PSPossibleIncorrectComparisonWithNull`, `PSUseApprovedVerbs`, and
`PSUseDeclaredVarsMoreThanAssignments` **[M]** (dispatch 000267 corpus recompute). That is a measured
surfacing count, not a claim about how many rules PSES loads: the README separately describes PSES's
default no-settings set as *about 15 rules* **[V]**. Those six are the rules observed by the current
known-bad corpus to reach the agent live under default configuration; they are not asserted to be the
exhaustive live rule surface. The opt-in `ruleset = base` broadens that surface.

PowerShell poses distinct tooling challenges that shape the design. Much of what an analyzer would
like to know is runtime-dependent -- module membership, exported command surfaces, dynamic scoping --
so a static pass must be honest about the boundary between what it can prove and what it can only
guess **[V]**. And the language spans two hosts still in wide use: Windows PowerShell 5.1 and
PowerShell 7. The plugin supports both, asymmetrically -- `pwsh` (7) is the analysis host on every
platform, while 5.1 is supported only as the PSES child host, never as the hook interpreter **[V]**
(`ARCHITECTURE.md`, "Cross-platform").

## 2. Design Goals and Non-Goals

The non-goals are the more informative half, and all are on record in the published declines table
(`ROADMAP.md`, "Declined, and why") **[V]**:

- **Not a PSES re-implementation.** The project is a client of PSES; capability work means surfacing
  what PSES already computes, not growing an analysis engine **[V]**.
- **No file watcher or background workspace sweep.** Explicit whole-repo scanning is covered by a
  standalone entry point (`scripts/lsp-scan.ps1`); a background sweep fails the cost and safety bar
  **[V]**.
- **No new custom rules, and no custom-rule seam pending demand.** The rule freeze stands; guidance
  overrides on rules that already fire are the sanctioned path **[V]**.
- **The broader ruleset stays opt-in.** A missing finding beats a wrong one, so `ruleset = base` is
  off by default **[V]**.
- **No Authenticode publisher signing.** For a git-distributed plugin the trust boundary is the
  keyless-signed tag, not a Windows publisher identity; the estate-signs-with-its-own-root path ships
  instead **[V]** (`TRUST.md`, "Signing posture").
- **No recurring prompt injection into agent context.** Context is added only when a PowerShell edit
  produces diagnostics or enabled guidance **[V]** (`README.md`).

That a decline is *revisitable* is part of the discipline: the custom-rule seam is recorded as
"declined pending demand," not declined permanently **[V]**.

## 3. Existing Approaches and Tradeoffs

The comparison here is of **integration shapes**, not analysis quality. The project runs PSES, so a
quality comparison would be incoherent, and the drafting discipline for PowerShell LSP work forbids
asserting superiority over PSES without compatible measurements **[V]**. The useful dimensions are
coupling to an editor, registration mechanism, runtime dependencies, startup behavior, observability,
and the security boundary.

Where this project sits on registration is a deliberate choice, and the accurate framing is narrower
than "native registration is unreliable": **native LSP registration works; end-to-end native serve
does not.** The plugin's LSP server registers, but on the direct path Claude Code's LSP client
rejects the server-to-client requests PSES sends during initialization, so the diagnostics path rides
a PostToolUse hook rather than depending on native serve **[V]** (`ROADMAP.md`, "Gated and paced";
`README.md`, "Why a hook, not native registration"). The distinction locates the gap precisely -- at
the initialization handshake, not at registration.

Where an alternative is genuinely stronger, the paper says so. The native navigation triad -- hover,
go-to-definition, find-references -- does **not** work on the direct path for the same
initialization-handshake reason, and the shipped workaround is an opt-in shim whose configuration
transport is currently suspended pending an upstream fix **[V]** (`ROADMAP.md`, "Gated and paced").
Positional queries for agents are declined on a stated reason rather than for lack of capability:
against stale line numbers they would be confidently wrong, which is worse than none **[V]**
(`docs/decision-ledger.md`, "Dispatch 000257 leg G").

## 4. System Architecture

The model is one paragraph. Diagnostics ride a PostToolUse hook backed by a warm, per-session PSES
daemon: one PSES process stays hot for the whole session behind a session-keyed named pipe, so each
edit pays a local pipe round-trip instead of a cold PSES start **[V]** (`ARCHITECTURE.md`, "The
one-paragraph model"). Everything runs on the local machine; the only outbound network is a one-time,
pinned, hash-verified dependency download -- and even that is removable, since v1.32.0 ships an
offline bundle path (section 10) **[V]**.

**Exhibit E1 -- the edit-to-banner lifecycle** (source: `ARCHITECTURE.md`, "The lifecycle").

```text
SessionStart      session-start.ps1: bootstrap deps (pinned + hash-verified, or from an offline
                  bundle; no-op once vendored), sweep old logs, reap OUR stale daemons, launch
                  pses-daemon.ps1 -> daemon opens the request pipe FIRST, then brings PSES up (-Stdio)

PostToolUse       lsp-client.ps1: read {session_id, file_path, edit} from stdin
(Write|Edit|      -> non-PowerShell file? exit 0, nothing surfaced
 MultiEdit)       -> connect pipe, request diagnostics; daemon waits for the SETTLED PSSA publish
                  -> scope to edited lines (fails open to whole-file), order, dedupe, threshold, cap
                  -> return diagnostics + status banner via hookSpecificOutput.additionalContext
                  -> hook ALWAYS exits 0 (editing is never blocked)

SessionEnd        session-end.ps1: pipe {shutdown} -> daemon sends LSP shutdown/exit, exits
```

Two invariants carry the project's character. The daemon is **pipe-first**: it opens the request pipe
before PSES is ready, so a first edit that races startup receives an honest status rather than
silence **[V]**. And the hook **always exits 0**: a timeout, a thrown error, a dead daemon, or a hash
mismatch degrades to a visible banner and never breaks the edit **[V]**.

**Where state lives, stated precisely, because the repo's own documents differ.** *Most* runtime
state -- the vendored PSES and PSScriptAnalyzer, logs, pids, and session files -- lives under
`CLAUDE_PLUGIN_DATA` and never leaves the machine **[V]** (`ARCHITECTURE.md`, "Where state lives").
The documented exceptions matter and are named here: the local diagnostics capture ("dogfood") log is
written under `CLAUDE_PLUGIN_ROOT`, not the data root, and is tracked as an OPEN least-privilege
finding (T2.3); the PowerShell-repository registration writes into the user profile on a fallback
path; and bootstrap uses temp staging that it cleans up **[V]** (`THREAT-MODEL.md`, sections 1.4, 5,
7 -- where the two documents conflict, the threat model and the code are authoritative). There is
**no TCP or network listener and no telemetry**; the only IPC is a local, session-keyed pipe, which
on non-Windows maps to a Unix-domain socket **[V]**. The public contract -- the `userConfig` knob
names and the status token set -- is drift-guarded in CI, so changing either source turns the build
red until the docs match **[V]**.

## 5. Key Technical Contributions

Three contributions, each as problem, mechanism, benefit, tradeoff, evidence.

### C1 -- Status honesty as a protocol property, not a quality goal

**Problem.** An empty result and an unrun analysis look identical, and an agent acts on both as a
pass.

**Mechanism.** Every analyzed edit resolves to exactly one of four tokens, and only the clean token
renders an empty banner **[V]** (`ARCHITECTURE.md`, "The status taxonomy").

**Exhibit E2 -- the status taxonomy** (source: `ARCHITECTURE.md`).

| Token | Meaning |
|---|---|
| `ok` | The PSScriptAnalyzer pass settled; diagnostics (if any) shown, no banner. |
| `incomplete` | Did not settle this edit (PSES starting, timed out, threw, re-spawning). Transient. |
| `degraded` | PSES is up but PSScriptAnalyzer is absent; only the parser ran (syntax errors still reported). |
| `unavailable` | PSES could not start for the session. Permanent until a fresh session. |

**Benefit, and the measured cost, stated as a measurement rather than a guarantee.** The
implementation does not *enforce* a one-edit bound -- any edit arriving before PSES is ready can
return `incomplete`. What was measured is a clean empirical result at the shipped commit: in **10 of
10** small-file cold sessions, exactly one edit per session returned "NOT checked" and the next
settled, spread zero **[M]** (dispatch 000267, M3). This is the pipe-first design behaving as intended
-- an edit racing startup gets an honest status rather than silence -- quantified, not promised.

### C2 -- A curated correctness corpus, recomputed and floored so it cannot be gamed by shrinking

**Problem.** A hand-authored expected-findings snapshot can be edited to fake a pass, and a rate can
be improved by quietly withdrawing hard cases.

**Mechanism, stated to avoid a circularity objection.** The corpus combines two distinct kinds of
check: **known-good and known-bad specifications** define the measured behavior (each known-bad case
names the rule it must surface), and **tool-derived snapshots act as a regression lock** against
drift in what the real tool emits **[V]** (`README.md`, "Diagnostic-correctness corpus"). The snapshot
is a change-detector, not the definition of correctness. CI floors each scored set at 30 fixtures, so
a rate cannot be improved by removing cases **[V]**.

**Result, described as observed corpus performance rather than a universal proof.** Recomputed live at
the shipped commit by the real tool (never hand-authored): 0 of 50 known-good cases produced a
finding, and 36 of 36 known-bad surfaced the expected rule, all six expected default rules covered
**[M]** (dispatch 000267 corpus recompute). The build fails if the false-positive rate rises above
zero or coverage drops below 100%. The floor is a floor, not a ratchet: a deliberate withdrawal (as
in v1.29.0) stays green while above 30 **[V]**. **Tradeoff, in the source's own words:** the claim is
*measured and defensible*, not *exhaustive* **[V]**.

**Provenance of the fixtures, disclosed proactively.** All 137 corpus-surface files are authored
in-repo under a single human rightsholder -- 0 derived from external sources, 0 of unknown origin --
so the licensing gate is PASS **[V]** (`CORPUS-PROVENANCE-AUDIT.md`, sections 3 and 7). Because the
paper makes provenance part of its credibility argument, one further fact is disclosed here rather
than left for a reviewer to find: **21 of those 137 files were added by commits declaring Claude
co-authorship** **[M]**. That is a co-authorship disclosure, not an eligibility defect -- the gate is
still PASS.

### C3 -- A decision record that carries declines with the same weight as ships

**Problem.** A roadmap that lists only wins hides the judgment that produced them.

**Mechanism.** A public declines table points into a full decision ledger, each entry with its
reasoning **[V]** (`ROADMAP.md`, "Declined, and why"; `docs/decision-ledger.md`).

**Benefit, by worked example.** An A/B efficacy experiment was declined for lack of a written
pre-registration rather than run improvisationally, and this paper itself was declined until measured
numbers existed to carry it **[V]** (`docs/decision-ledger.md`, section 9). **Tradeoff:** a declines
table is only evidence of restraint if the declines are real and revisitable, which is why the
custom-rule seam is "declined pending demand" **[V]**.

## 6. Implementation

The configuration surface is a two-tier contract, and the contractual tier is mechanically enforced:
the `userConfig` knob names and the status token set are set-equality guarded in CI against the
manifest and the banner functions, so documentation drift is a red build rather than a stale doc
**[V]** (`CONTRACT.md`; `ARCHITECTURE.md`, "What you must not break"). This is the structural answer
to the documentation-drift risk named in the roadmap -- the guard is the mitigation, not discipline
**[V]**.

The two downloaded dependencies -- PSES and PSScriptAnalyzer -- are pinned by version **and** verified
against SHA-256 hashes computed from the real artifacts before use, failing closed on a mismatch
**[V]** (`TRUST.md`; `THREAT-MODEL.md`, B1). For disconnected estates, v1.32.0 ships an offline bundle
that satisfies the same pinned, hash-verified bootstrap with no network path (section 10) **[V]**. The
shipped capability inventory -- what exists today, as distinct from roadmap intent -- is recorded in
`CURRENT-STATE.md`, section 4 **[V]**.

## 7. Evaluation

Titled an evaluation rather than an evaluation of "current evidence" because the version drift is
gone: every figure below was measured at the shipped commit `fb3116c` by dispatch 000267, on one
desktop-class Windows host, and the runtime was proven byte-identical to that commit. None are adopted
SLOs -- every candidate target remains unratified **[M]**. The measurement is honest about its host:
this machine ran quieter than the v1.31.0 baseline (CPU median 9-32% across blocks versus the
baseline's 31-57%), so the wall-clock *improvements* below are reported but not claimed as the tool
getting faster; the load-insensitive `analysisMs` segment is the trustworthy comparison, and it is
essentially unchanged **[M]**.

**Exhibit E4 -- warm per-edit latency at `fb3116c`** (N=30, 30 kept, 2 priming edits; source: dispatch
000267 M1). Unrounded, with spread and the v1.31.0 baseline for context:

| Segment | median | p95 | spread | v1.31.0 |
|---|---:|---:|---:|---:|
| End-to-end wall (what a user pays) | 2503 ms | 2738 ms | 495 ms | 2997 ms |
| Client `totalMs` (shipped stats log) | 1941 ms | 1998 ms | 173 ms | 2066 ms |
| Daemon `analysisMs` (settle) | 1405 ms | 1427 ms | 44 ms | 1407 ms |
| Client `connectMs` | 30.5 ms | 38 ms | 31 ms | 12 ms |

**Finding 1 -- `analysisMs` is re-measured and unchanged.** 1405 ms at `fb3116c` versus 1407 ms at
v1.31.0, inside a 44 ms spread -- the load-insensitive segment, which is why it is the segment the
paper leans on across hosts **[M]**.

**Finding 2 -- the instrument gap persists.** The end-to-end wall exceeds the shipped stats log's
`totalMs` by 562 ms -- process spawn, dot-source of the shared library, option reads -- real time a
user waits and invisible to the only shipped latency instrument. An SLO written against `totalMs`
would understate user-visible latency by half a second **[M]**.

**Cold start** (N=10 independent cold sessions, 10 kept; source: M2). Cold start to first settled
analysis is 6991.5 ms median (spread 1983 ms), against 9523 ms at v1.31.0 **[M]**.

**Memory** (N=12; source: M6). Combined steady-state working set is ~318 MB (daemon 156.5 MB + PSES
child 161.8 MB), matching the v1.31.0 figure to the megabyte; the pair warms to a plateau rather than
climbing **[M]**.

**Sustained stability** (N=120 consecutive edits, 291.9 s; source: M5). No edit failed to settle, no
leak, no slowdown -- both the wall and `analysisMs` medians drifted slightly *faster* over the run
(-127.5 ms and -4.0 ms, well inside the run's own spread) **[M]**. Honest bound: 291.9 s is not a
multi-hour session and the 30-minute idle TTL was never exercised **[M]**.

Prior latency figures in `docs/benchmarks.md` are historical, measured at different versions with
different definitions, and are not restated as current **[V][M]**.

## 8. The Large-File Result: a v1.31.0 Non-Convergence, Now Resolved

The most load-bearing change from the earlier drafts. At v1.31.0 the edit path did not reliably
converge on a large file -- 1 of 5 sessions -- and that was the paper's headline negative result. At
the shipped commit it is **resolved**, and the paper reports the inversion in full rather than quietly
dropping the old number **[M]** (dispatch 000267, M4b).

The fixture is not a synthetic file: it is `scripts/lib/lsp-common.ps1`, the plugin's own shared
library, and it *grew* to **251,523 bytes / 4,399 lines** at the shipped commit, 14.5% larger than
the 219,682-byte / 3,881-line file measured at v1.31.0. So convergence improved on a larger file
**[M]**.

**Exhibit E5 -- convergence on the large fixture, v1.31.0 vs `fb3116c`** (uniform 15-attempt cap, 5
independent cold sessions; source: dispatch 000267 M4b).

| Measure | v1.31.0 | `fb3116c` |
|---|---:|---:|
| Sessions converged (uniform cap) | 1 of 5 | **5 of 5** |
| Cost of convergence (median) | 13 edits / 89,927 ms | **2 edits / 13,623 ms** |
| Daemons launched per session (median) | 3 | **1** (spread 0) |
| Auto-relaunches per session (median) | 3 | **0** (spread 0) |

**The mechanism, and why this is not just a quieter machine.** Section 8 of `SLO-BASELINES.md`
diagnosed a compounding pair: the daemon's 5000 ms settle cap expires, the client concludes
*unreachable* rather than *busy*, and relaunches the daemon that was doing the work. Two shipped fixes
in the 1.32.0 band name that exact failure -- v1.31.1 stops a live-but-busy daemon being mistaken for
an unreachable one and relaunched, and v1.31.2 (dispatch 000237) stops a client that abandons one
reply from killing the whole daemon, which was the binding reason a large-file session never
converged once the relaunch thrash began **[V]**. The measurement shows exactly the predicted
signature: one daemon, zero relaunches, zero unreachable verdicts **[M]**. The ambient-load
explanation is the weaker one here, and the data rules it out: at v1.31.0 the *lowest*-load session
(31% CPU) failed while a 43% session converged, so load did not separate the cases then either **[M]**.

Once converged, the large file is slower but bounded: end-to-end wall 3741.5 ms median against
2503 ms for a small file, `analysisMs` 1610.5 ms against 1405 ms (n=70 kept of 75; source: M4) **[M]**.

## 9. Security and Operational Considerations

Controls are separated into implemented, environmental, and open, and "secure" is never claimed as a
binary property.

**Implemented.** The plugin runs entirely as the invoking user with no elevation, makes no network
call after the one-time pinned bootstrap (or none at all with the offline bundle), opens no TCP or
network listener, and ships no telemetry -- absences confirmed by search across `scripts/` and
`hooks/` **[V]** (`THREAT-MODEL.md`, sections 1.2, 1.5, 5). Every external GitHub Action is pinned to
an immutable commit SHA with three independent enforcements **[V]** (`TRUST.md`). v1.32.0 publishes a
CycloneDX 1.5 SBOM and a SLSA build-provenance attestation over the source archive and the SBOM,
verifiable with `gh attestation verify`, and the release tag is keyless-signed via
transparency-logged Sigstore with no maintainer-held key in the trust path -- all three were verified
bound to the release commit `fb3116c` at publication **[V]** (dispatch 000267 post-tag verification;
`TRUST.md`, "Supply-chain artifacts").

**Environmental.** For managed Windows estates, the trust document supplies AppLocker and WDAC / App
Control allow-listing rules and an org-certificate paved path for estates that want their own
signature **[V]** (`TRUST.md`, "Allow-listing on managed Windows").

**A designed boundary, recorded so it does not read as a gap.** The doctor deliberately does not
diagnose security-control blocks (WDAC, AppLocker, ExecutionPolicy, CLM, ASR, Smart App Control); the
named-control diagnosis ships in the SessionStart bootstrap-failure banner, which fires only when
there is a live failure to attribute and carries a graded confidence the doctor's three-token status
cannot hold. A doctor report is written to be pasted into a support thread, so an enumerated read of a
machine's security posture would be a disclosure the user did not ask to make **[V]** (`THREAT-MODEL.md`,
section 4).

**Open, stated with the controls rather than apart from them.** The threat model carries an OPEN
findings register and names where least privilege is not clean: the diagnostics capture log writes
into the plugin root (T2.3, OPEN), a PowerShell-repository registration writes into the user profile
on a fallback path, and bootstrap uses temp staging **[V]** (`THREAT-MODEL.md`, sections 5, 6, 7, 8).
Degradation when analysis cannot run is by design visible, not silent **[V]**.

## 10. Adoption and Integration

Install and verify is a documented multi-step path, not a one-liner, and the docs say so: prerequisite
`pwsh` on PATH plus, for a connected install, internet on the first enabled session for the pinned,
hash-verified self-download -- or, for a disconnected estate, the offline bundle **[V]** (`README.md`,
"Quick start"; "Prerequisites").

**Enterprise posture, shipped in v1.32.0.** Two named blockers from a 2026-08-15 corporate-IT review
are closed in the release a reader can download and attest: the plugin is **Apache-2.0** (v1.32.0 is
the first Apache release; earlier tags keep the license they shipped under), and an **offline /
air-gapped bootstrap** ships, verified at the release commit -- a 34.5 MB bundle carrying the pinned
PSES and PSScriptAnalyzer artifacts that completes bootstrap with the network blocked **[V][M]**
(dispatch 000267 functional gates (a) and (b)). The offline gate was run as a constructed air-gap test
and recorded as constructed, not prescribed: the bundle built by the shipped procedure, the network
blocked for the bootstrap process, and a RED control (same block, no bundle) confirmed to fail for the
right reason before the real run passed **[M]**. Enterprise gaps that remain open are stated in the
same section as the wins **[V]** (`CURRENT-STATE.md`, section 11).

What a first-time user experiences was walked in a scratch environment and classified rather than
assumed; its user-visible findings are remediated in the shipped docs and doctor text, and its
observability findings -- the doctor's `CLAUDE_PLUGIN_DATA`-blind checks, the ~562 ms stats-log blind
spot -- are named as the tooling being unable to explain a behavior that may itself be fine **[M]**
(`DX-AUDIT.md`, sections 3 and 5).

## 11. Limitations

The limitations are in the body. With the v1.31.0 large-file non-convergence now resolved, the honesty
weight shifts to the unmeasured efficacy question.

- **[U]** **Whether the plugin makes an agent write better PowerShell is unmeasured**, and the A/B
  that would answer it is declined absent a written pre-registration (`docs/decision-ledger.md`,
  section 9). This is the paper's single most important honesty test, and it names the gap rather than
  filling it.
- **[M]** The baselines are one host, one OS, one PowerShell version, one analyzer pin; not a
  quiet-window measurement and not CI-wired (`SLO-BASELINES.md`, section 10). The measuring host ran
  quieter than the v1.31.0 baseline, so wall-clock improvements are reported, not claimed.
- **[M]** The large-file result is resolved at 251 KB but the file-size curve still has few points;
  behavior is uncharacterized between the small fixtures and 251 KB and is not established on other
  hosts.
- **[V]** Native navigation is upstream-gated at the initialization handshake and the shipped shim is
  a workaround; its configuration transport is currently suspended pending
  `anthropics/claude-code#86936`, so on an affected client the shim cannot take effect. Diagnostics
  are unaffected -- they run through the hook path.
- **[V]** Single-maintainer bus factor: one person reviews, responds, bumps, and releases
  (`CONTINUITY.md`). The mitigation is not a named successor but an irrevocable Apache-2.0 fork path
  plus keyless, key-custody-free release provenance a fork reproduces under its own identity **[V]**.

## 12. Roadmap

Kept strictly separate from implemented state. The published lanes: nothing chartered and moving
("Now" deliberately empty); three queued items under "Next"; and gated-and-paced items each naming
what they wait on -- native navigation on `anthropics/claude-code#86936`, corpus commons on a
licensing decision at activation, attested diagnostics on a verifying consumer, enterprise control
plane demand-paced one slice per adoption signal, scale-and-robustness on a reported scale problem,
deeper rule curation on the dogfood log **[V]** (`ROADMAP.md`; per-initiative detail in `PROGRAM.md`).
Upstream dependencies the project cannot close itself are enumerated in `CURRENT-STATE.md`, section 7
**[V]**.

## 13. Conclusion

`powershell-lsp` demonstrates that an agent-facing PowerShell diagnostics layer can be built as an
honest client of PSES rather than a re-implementation, and that the honesty can be made structural:
four explicit status tokens so a result is never silently wrong, a curated corpus recomputed and
floored so a rate cannot be gamed, and a decision record that carries declines with the weight of
ships. The measured evidence at the shipped commit `fb3116c` supports the diagnostics-correctness and
status-honesty claims, bounds the latency and memory envelope, and shows a prior large-file
non-convergence resolved by the daemon-recovery work. What the evidence does not establish is whether
any of this makes an agent write better PowerShell -- the one question a reader should keep in view,
because the project's answer so far is to measure what it can and decline the experiment it cannot yet
run cleanly, which is the same discipline that produced everything else in this paper.

## References

In-repo primary sources cited above: `ROADMAP.md`, `README.md`, `ARCHITECTURE.md`, `CONTRACT.md`,
`TRUST.md`, `CONTINUITY.md`, `docs/decision-ledger.md`, `docs/benchmarks.md`,
`docs/roadmap-ii/SLO-BASELINES.md`, `docs/roadmap-ii/CORPUS-PROVENANCE-AUDIT.md`,
`docs/roadmap-ii/THREAT-MODEL.md`, `docs/roadmap-ii/CURRENT-STATE.md`, `docs/roadmap-ii/DX-AUDIT.md`,
`docs/roadmap-ii/PROGRAM.md`. Release evidence: dispatch 000267 (freeze 1B) outbox and its measurement
artifacts, keyed to commit `fb3116c`. External sources to be cited at finalization by primary URL and
retrieval date: the upstream issues named in `ROADMAP.md` "Gated and paced," and the LSP and SLSA
specifications.

## Appendix A -- Reproduction

- Corpus correctness is recomputed and guarded on every CI run
  (`tests/PowerShellLsp.Corpus.Tests.ps1`) **[V]**.
- The SLO harness for the shipped-commit measurement is preserved in the dispatch 000267 artifacts
  (`stage-c.ps1`, `prove-equals-c.ps1`, `measure.ps1`, `run-quant.ps1`), including the
  script-tree-equals-commit proof and the constructed air-gap gate **[V]**.
- A reader can verify a downloaded release with `gh attestation verify` against the published SBOM and
  provenance, and confirm the tag with `gitsign verify`; both were verified bound to `fb3116c`
  (`README.md`, "Verifying your install and a release"; `TRUST.md`) **[V]**.

## Appendix B -- Open evidence gaps

1. **Agent-efficacy evidence does not exist**, and the experiment is declined absent a written
   pre-registration **[U]**.
2. **The dogfood channel is nearly empty** as of the measurement window -- to be refreshed at
   publication date, since it is a function of the publish date rather than the release commit **[M]**.
3. **No cross-host latency evidence.** The four CI legs cover other platforms functionally, not for
   latency **[V]**.
4. **The large-file result is resolved at 251 KB** but the size curve between the small fixtures and
   251 KB, and on other hosts, is uncharacterized **[V]**.
5. **No comparative measurement against any alternative exists**, so section 3 stays a comparison of
   integration shapes and claims no superiority **[V]**.
