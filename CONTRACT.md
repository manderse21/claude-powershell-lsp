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
| `formatOnEdit` | format-on-edit suggestion mode (off by default) |
| `ruleset` | live diagnostics ruleset tier (`pses-default` by default; `base` opt-in) |

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
| `unavailable` | distinct visible banner -- PSES could not start (never bootstrapped, OR present but failed to start), permanent for the session |

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

**Goal:** a clean-box install **or startup** failure is always made **visible**, never
silent, on all four supported platforms (macOS pwsh, Linux pwsh, Windows pwsh, Windows
PowerShell 5.1). When PSES cannot start -- the bundle never bootstrapped (offline, proxy)
OR it is present but fails to initialize, AND even when the first edit races startup
before PSES is ready -- the user sees an actionable banner (`unavailable` if PSES cannot
start, `incomplete` if it is still starting) rather than diagnostics that silently never
appear. Dispatch 000028 made the daemon **pipe-first** (the request pipe opens before
PSES is brought up) so this guarantee holds across the whole startup window, closing the
no-pipe silent miss.

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
- **dispatch 000028** -- pipe-first honest startup: the no-pipe silent miss (a first edit
  racing PSES startup, or a present-but-failed init, getting NOTHING) is closed by opening
  the pipe before PSES and serving an honest `incomplete` (still starting) / `unavailable`
  (could not start) over it. A client-side backstop (`lsp-client.ps1`) covers the residual
  NO-pipe window (the ~150ms daemon-launch sliver, or a session whose daemon has stopped after
  idle) with its own "analyzer not reachable" banner -- so no could-not-analyze case is silent.

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
- **`idleTtlMin` x warm-start (RESOLVED, dispatch 000028).** Warm-start shipped on the
  pipe-first daemon (1.6.0): PSES is pre-warmed once it goes ready. The reconciliation: the
  idle clock starts at daemon launch and resets only on a **real client request** -- the
  internal pre-warm does NOT count as activity -- so a session that never edits still
  self-terminates after `idleTtlMin`, and `idleTtlMin` keeps its frozen meaning. No knob
  rename or taxonomy change; recorded here as closed, not open.
- **`lspServers` manifest block (NOT a Tier-1 frozen surface) -- dispatch 000075.** The native
  LSP-server declaration in `.claude-plugin/plugin.json` (`lspServers.powershell`) is a manifest
  surface but is **not** part of the frozen Tier-1 contract: only the userConfig knob **names**
  (1.1) and the diagnostics status **tokens** (1.2) are enumerated and drift-guarded. Dispatch
  000075 removed two fields -- `restartOnCrash` and `shutdownTimeout` -- that Claude Code's runtime
  LSP registrar silently drops (the fields blocked registration rather than doing anything; their
  removal is **behavior-neutral** and breaks no consumer), and shipped it as a **PATCH (1.18.1)**.
  The block is now held to a registrar-supported allowlist `{command, args, extensionToLanguage,
  transport, startupTimeout, maxRestarts, env}`, guarded by a test
  (`tests/PowerShellLsp.Unit.Tests.ps1`). Recorded here as a **note, not an amendment**: the
  lspServers fields are not a semver-protected surface, so removing two inert ones is not a contract
  change. (If a future change makes native serve a real, user-visible feature, *that* is the
  contract-relevant event to adjudicate -- not this field cleanup.)
- **Closed-loop correction lifecycle fields (NOT a Tier-1 frozen surface) -- dispatch 000061.** The
  daemon's diagnostics response MAY carry two additive output fields, `cleared[]` and `stillPresent[]`,
  reporting whether a previously-surfaced finding cleared or is still present after an edit (the PL-4
  closed loop). Like the `powershell-lsp` source label, these are **output fields, not part of the
  frozen Tier-1 contract**: only the userConfig knob **names** (1.1) and the diagnostics status
  **tokens** (1.2) are enumerated and drift-guarded. They are additive and backward-compatible -- a
  consumer that ignores them is unaffected -- and they deliberately do **not** introduce a new status
  token: finding-lifecycle is a different axis from the analyzer-health taxonomy, so it rides an
  additive field (a drift-guard-green MINOR under the semver policy), never the token set. Recorded
  here as a **note, not an amendment**: an additive output field is not a semver-protected surface.
- **`formatOnEdit` knob (DELIBERATE MINOR amendment) -- dispatch 000059.** A new optional, defaulted
  userConfig knob, `formatOnEdit`, was added to the manifest (and so to the FROZEN-KNOBS table above,
  which the drift-guard validates). This is the contract-relevant event the freeze exists to record:
  a new knob is a **deliberate, documented MINOR**, not a silent drift -- the table row IS the
  amendment, and the guard passes **because** the contract was updated, not bypassed. The knob's
  **default is `off`**, and with it **off the diagnostics surface and all behavior are byte-for-byte
  unchanged** (the format path is never invoked; no `format` request is sent). When `suggest`, the
  warm daemon runs Invoke-Formatter on the edited file -- honoring the repo's `PSScriptAnalyzerSettings.psd1`
  formatter rules (the 000018 precedent) -- and surfaces the result as a **suggestion** via the existing
  `additionalContext` channel; the hook **never rewrites the user's file** (suggest-not-apply is the
  whole safety posture). The knob is an **enum** (`off` | `suggest`, default `off`), shaped so a future
  **`apply`** mode could be added as an additive enum value **without** a breaking knob change; no apply
  path ships today, and `apply` is treated as `off`. No new status token and no second PSSA acquisition
  path: the suggestion rides the existing surface, and the vendored pinned-hash PSSA is reused.
- **`ruleset` knob (DELIBERATE MINOR amendment) -- dispatch 000087.** A new optional, defaulted
  userConfig knob, `ruleset`, was added to the manifest (and so to the FROZEN-KNOBS table above, which
  the drift-guard validates). This is the contract-relevant event the freeze exists to record: a new knob
  is a **deliberate, documented MINOR**, not a silent drift -- the table row IS the amendment, and the
  guard passes **because** the contract was updated, not bypassed. The knob's **default is `pses-default`**,
  and with it at the default the diagnostics surface and all behavior are **byte-for-byte unchanged**: the
  live path keeps PSES's own built-in no-settings rule set (the ~15-rule allow-list) and no plugin base
  ruleset is ever resolved. When `base`, and ONLY when no repo-local `PSScriptAnalyzerSettings.psd1` and no
  explicit `settingsPath` resolve first, the plugin's shipped, **explicitly enumerated** base ruleset
  (`rulesets/base.psd1`) is applied, broadening the live surface to PSScriptAnalyzer's default-on set minus
  the compatibility-profile rules (surfacing e.g. `PSAvoidUsingWriteHost` and the three Error-severity
  security rules). **Precedence (authoritative for the user), highest wins:** explicit `settingsPath` >
  discovered repo-local `PSScriptAnalyzerSettings.psd1` (000018) > the plugin base (only when
  `ruleset=base`) > PSES's 15-rule no-settings default (when `ruleset=pses-default`). A repo-local settings
  file or an explicit override ALWAYS wins over the base -- the base only fills the gap. The knob is an
  **enum** (`pses-default` | `base`, default `pses-default`), shaped so future curated / AI-era rule tiers
  can be added as additive enum values **without** a breaking knob change. **The default is not flipped in
  this dispatch** (the broadened surface must not activate on upgrade for anyone who does not opt in -- an
  evidence-backed default-flip is a later dispatch). No new status token and no second PSSA acquisition
  path: the base is resolved through the existing settings-path channel, and the vendored pinned-hash PSSA
  (000046 L2) is reused unchanged. Because the base **enumerates** its rules rather than using
  `IncludeDefaultRules = $true`, a vendored-PSSA pin bump is a deliberate, reviewed regeneration
  (`scripts/regen-base-ruleset.ps1`), never a silent shift of the surfaced set.

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
- **000028** -- pipe-first honest startup: closed the no-pipe silent miss and generalized
  `unavailable` to also cover a present-but-failed start (prose-only -- the token SET stays
  four); warm-start shipped as the latency win riding free on the same change. First
  post-freeze exercise: a MINOR (1.6.0) with no knob and no token added, so the drift-guard
  greened without a Tier-1 change.

Mike Andersen's locked decisions (dispatch 000027): only the mechanically-enforceable
surfaces (knob names; status tokens) are CONTRACTUAL; the install-failure guarantee is
ASPIRATIONAL; a token-level (not prose) freeze; knob names frozen with behavior-altering
default changes as MAJOR; the drift-guard extracts ground truth live from source with no
static baseline list.
