# powershell-lsp -- Public Contract and 1.x Semver Freeze

Status: ACTIVE, from v1.5.3 forward. This plugin is already at 1.x (1.5.x); this
document does **not** ratify a 0.x -> 1.0 launch -- it formalizes, going forward,
which surfaces a 1.x user may depend on and what kind of change is allowed without a
MAJOR bump.

The single sources of truth are the **code**, not this document: the userConfig
manifest (`.claude-plugin/plugin.json`) and the status-banner functions
(`Get-DiagnosticsStatusBanner` / `Resolve-AnalysisStatus` in
`scripts/lib/lsp-common.ps1`). This contract **enumerates** the frozen surface, and a
runnable CI drift-guard validates this document (and the README) **against those
sources** on every push -- so the contract cannot silently drift from what ships.

## The two tiers

The launch surface is split by **enforceability**, because a promise CI can
mechanically check and a promise it cannot must not be presented as the same kind of
thing:

- **Tier 1 -- CONTRACTUAL.** Enumerable surfaces (the userConfig knob names; the
  diagnostics status-token taxonomy). A runnable test pins them; drift fails CI.
  Semver-protected.
- **Tier 2 -- ASPIRATIONAL.** A behavioral goal (install-failure visibility) that
  cannot be string-diffed. Documented and backed by integration tests, but **not** a
  semver guarantee and **not** asserted by the drift-guard.

---

## Tier 1 -- Contractual (semver-protected, mechanically enforced)

### 1.1 Configuration knobs (userConfig)

Frozen: the **set of knob names** below, additive-only. The manifest
(`.claude-plugin/plugin.json` `userConfig`) is the single source of truth; this list
is drift-guarded to equal it **exactly**. Per-knob meaning, defaults, and prose live
in `README.md` (`## Configuration`) -- this contract freezes the **names** and the
change rules, not a second copy of the prose.

<!-- FROZEN-KNOBS:BEGIN -- drift-guarded to equal .claude-plugin/plugin.json userConfig keys EXACTLY (tests/PowerShellLsp.Unit.Tests.ps1). Add a knob to the manifest -> add it here AND to README, or CI goes red. Do not hand-edit to diverge from the manifest. -->

| Knob | Controls |
|------|----------|
| `ps_host` | PSES host executable selection |
| `severityThreshold` | least-severe level surfaced |
| `ruleInclude` | exclusive rule-code allowlist |
| `ruleExclude` | rule-code suppression list |
| `timeoutMs` | client hard cap before log-only degrade |
| `debounceMs` | edit-coalescing window |
| `keepLastN` | rolling log files kept per family |
| `idleTtlMin` | daemon idle self-terminate window |
| `perFileCap` | max diagnostics surfaced per file |
| `enableStats` | opt-in per-edit timing telemetry (default off) |
| `settingsPath` | absolute PSScriptAnalyzerSettings.psd1 override |
| `scopeToEdit` | scope diagnostics to the edited lines |
| `editContextLines` | context lines around the touched range |

<!-- FROZEN-KNOBS:END -->

What is frozen, precisely:

- **The knob NAMES, additive-only.** A 1.x MINOR MAY add a new optional, defaulted
  knob (a config valid today stays valid and behaves identically). Renaming or
  removing a knob is a MAJOR (2.0.0).
- **Knob DEFAULT VALUES are not frozen as immutable.** A behavior-neutral default
  tweak -- one a 1.0-valid config would not observe differently in *result*, only in
  tuning -- is a MINOR or PATCH; a default change that **alters observed behavior** is
  a MAJOR. This makes the existing CHANGELOG semver policy precise on the one axis a
  name-only freeze is silent about: `perFileCap`, `debounceMs`, `timeoutMs`, and
  `idleTtlMin` defaults were tuned empirically and may be re-tuned under MINOR/PATCH so
  long as behavior a user notices does not change.

**`enableStats` carve-out (anticipated, non-breaking).** What is frozen is the knob
**name** and its opt-in / default-off behavior. The internal stats-log **format** --
specifically that `logs/stats.jsonl` currently records **absolute** file paths -- is
**not** a frozen output field. Path redaction (or another stats-format refinement) MAY
ship under PATCH/MINOR without a MAJOR; a maintainer seeing this should treat redaction
as an anticipated, contract-compatible change, **not** a freeze violation.

### 1.2 Diagnostics status taxonomy

Frozen: the **set of status tokens** below, and the **property** that the clean token
renders an **empty** banner (the byte-identical warm path) while each non-ok token
renders a **distinct, non-empty, visible** banner. `Get-DiagnosticsStatusBanner` (the
non-ok tokens) and `Resolve-AnalysisStatus` (the clean token) in
`scripts/lib/lsp-common.ps1` are the single source of truth; this list is drift-guarded
to equal the tokens those functions emit, **exactly**.

<!-- FROZEN-STATUS-TOKENS:BEGIN -- drift-guarded to equal the tokens emitted by Get-DiagnosticsStatusBanner (switch labels, via AST) + Resolve-AnalysisStatus (the clean token) EXACTLY (tests/PowerShellLsp.Unit.Tests.ps1). Rename/remove/merge a token -> update here, or CI goes red. -->

| Token | Banner |
|-------|--------|
| `ok` | none -- clean pass, warm path renders nothing |
| `incomplete` | distinct visible banner -- analysis did not settle (transient) |
| `degraded` | distinct visible banner -- parser-only, PSScriptAnalyzer absent |
| `unavailable` | distinct visible banner -- PSES never bootstrapped (install-time) |

<!-- FROZEN-STATUS-TOKENS:END -->

What is frozen, precisely:

- **The token SET and the clean-empty / non-ok-distinct-visible PROPERTY.** A parser
  keys on the **tokens**; a human reads the prose.
- **The banner MESSAGE PROSE is not frozen.** Refining a banner's human-readable
  wording -- a typo fix, a clearer remediation hint -- is a PATCH. Freezing the prose
  would make a typo fix a MAJOR, which is absurd.
- **Adding a new status token is adjudicated, not automatic** (see the semver policy).
  Removing, renaming, or merging a token is a MAJOR.

---

## Tier 2 -- Aspirational (documented, NOT semver-contractual, NOT drift-guarded)

### Install-failure visibility

**Goal:** a clean-box install failure is always made **visible**, never silent, on all
four supported platforms (macOS pwsh, Linux pwsh, Windows pwsh, Windows PowerShell
5.1). When the PSES bundle cannot bootstrap (offline, proxy, a broken first start), the
user sees an actionable "diagnostics unavailable" banner rather than diagnostics that
silently never appear.

**Why this is Tier 2, not Tier 1:** this is a **behavior** across the daemon, the
hooks, and four platforms -- it cannot be reduced to a string-diffable list, so a
drift-guard cannot assert it. Presenting it as a semver guarantee would claim an
enforcement this project does not have.

**How it is actually enforced:** by integration tests that exercise the failure path
and must keep existing and passing --

- **dispatch 000024** -- the load-bearing daemon-served `unavailable` on the first-edit
  PostToolUse channel (the primary surface).
- **dispatch 000026** -- the SessionStart secondary surface, fixed so the detached
  daemon no longer inherits the hook's standard handles on non-Windows (which had
  dropped the banner).

These tests are this guarantee's living evidence. The Tier-1 drift-guard does **not**
assert this guarantee; its enforcement is those tests continuing to exist and pass on
all four legs.

---

## 1.x semver policy

A configuration valid under any 1.x release stays valid and behaves identically under
every later 1.x release. Concretely:

**MINOR (1.x.0) MAY:**

- add a new optional, defaulted userConfig knob;
- add a new status token (adjudicated -- see below);
- add an additive output field;
- re-tune a knob default in a behavior-neutral way;
- add a newly CI-verified platform.

**PATCH (1.x.y) MAY:**

- fix bugs / harden internals with no surface change;
- refine banner message prose;
- refine the internal stats-log format (e.g. path redaction);
- correct docs.

**MAJOR (2.0.0) is REQUIRED to:**

- rename or remove a userConfig knob;
- change a knob's meaning or default in a way that **alters observed behavior**;
- remove, rename, or merge a status token;
- change the clean-empty / non-ok-distinct-visible banner property;
- otherwise break a config or workflow a 1.x user depends on.

**New surface is adjudicated, not automatic.** "It is additive, so it is a MINOR" is
the starting point, not the conclusion: a new knob or token is reviewed for whether it
genuinely preserves every existing 1.x config's meaning and output before it ships as a
MINOR. **Capstone rule:** when in doubt whether a change is observable to an existing
1.x user, treat it as observable -- the freeze protects the user, not the maintainer's
convenience.

---

## How this contract is enforced (the drift-guard)

The freeze has **teeth** because it is checked mechanically on every push, not trusted
as prose:

- **Single source of truth:** the manifest userConfig keys and the status-banner
  functions. This document **and** the README are both validated against them -- never
  the reverse.
- **Live from source:** the drift-guard reads the manifest keys live and derives the
  status tokens from the shipped functions' AST (plus the resolver's clean token).
  There is **no** hand-maintained knob/token list in the test acting as the comparison
  baseline; if there were, it would just be a second copy that could drift while the
  guard stayed green.
- **The effect:** add a knob to the manifest, or rename a token in the banner, and CI
  goes **red** until **both** this contract and the README are updated to match. README
  and CONTRACT are guarded by **separate** tests so a red leg names which document
  drifted.
- **Where:** `tests/PowerShellLsp.Unit.Tests.ps1` --
  *"CONTRACT.md freezes exactly the manifest userConfig knobs"* and *"CONTRACT.md
  freezes exactly the diagnostics status-token taxonomy"* (dispatch 000027), alongside
  the existing README guards (dispatch 000025).

---

## Forward-compatibility notes

Known, anticipated interactions, recorded so a future maintainer does not hit them
cold. None is a contract change; each is banked here deliberately.

- **`enableStats` stats-log format.** As in Tier 1.1: the absolute-path log format is
  not a frozen field; redaction is an anticipated PATCH/MINOR refinement.
- **`settingsPath` relative-path hazard.** Today a **relative** `settingsPath` value is
  deliberately **ignored** (absolute-only; a relative path cannot resolve safely
  through PSES). If relative support is ever added, a value that is currently a no-op
  would **become active** -- a behavior change for an existing config. That requires
  **deliberate handling** (a MAJOR, or an explicit opt-in), not an automatic "it is
  just additive" MINOR. Flagged so the silent no-op-becomes-active trap is not sprung
  by accident.
- **`idleTtlMin` x warm-start (#5).** The roadmap warm-start daemon (pre-warm PSES at
  SessionStart) interacts with `idleTtlMin`'s idle self-termination: the two must be
  reconciled so pre-warming does not fight the idle TTL. This is a known forward
  **interaction** to design for -- not a knob rename or a taxonomy change.

---

## Provenance

This freeze ratifies a surface built and proven over a sequence of dispatches; it does
not edit that surface.

- **000022** -- the clean / incomplete / degraded status split (the taxonomy's origin).
- **000024** -- the install-time `unavailable` status and the load-bearing
  daemon-served surface.
- **000025** -- the single-source version stamp and the README config-table +
  status-taxonomy documentation guards (the seam this drift-guard extends).
- **000026** -- the non-Windows fd-leak fix that restored the SessionStart surface; the
  precondition that `main` is green on all four legs.
- **000027** -- this contract and its drift-guard.

Mike Andersen's locked decisions (dispatch 000027): only the mechanically-enforceable
surfaces (knob names; status tokens) are CONTRACTUAL; the install-failure guarantee is
ASPIRATIONAL; a token-level (not prose) freeze; knob names frozen with behavior-altering
default changes as MAJOR; the drift-guard extracts ground truth live from source with no
static baseline list.
