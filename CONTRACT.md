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
| `moduleAwareness` | uninstalled-module command hint (off by default; `suggest` opt-in) |
| `nativeServe` | native hover/definition/references serve via the handshake shim (off by default; `shim` opt-in) |
| `referenceSurfacing` | workspace reference-count facts for the edited file (off by default; `counts` opt-in) |
| `orgPolicy` | org settings psd1 path whose `ExcludeRules` win over local config (empty by default = off) |

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
  whole safety posture). The knob is an **enum** (`off` | `suggest` | `apply`, default `off`), shaped so
  the **`apply`** mode could be added as an additive enum value **without** a breaking knob change. That
  activation is now done -- see the next note (dispatch 000099); 000059 itself shipped **suggest-only**,
  with no new status token and no second PSSA acquisition path (the suggestion rides the existing surface,
  and the vendored pinned-hash PSSA is reused).
- **`formatOnEdit=apply` activated (DELIBERATE MINOR amendment) -- dispatch 000099.** The `apply` enum
  value 000059 reserved is now **active**: when `formatOnEdit=apply` and the formatter produces a change,
  the warm daemon **writes the formatted result back**. This is the anticipated additive MINOR the 000059
  note foresaw -- the knob **NAME is unchanged** (the FROZEN-KNOBS table does not move), so the drift-guard
  passes **because** the knob surface is stable and this note records the activation, not because anything
  was bypassed. The **default stays `off`**, and **`off` and `suggest` are byte-for-byte unchanged**
  (regression-proven): `off` sends no `format` request; `suggest` sends the same request with no `apply`
  flag and never writes. `apply` is **doubly opt-in** -- only the exact value `apply` reaches it (a boolean
  alias maps to `suggest`), so no config is upgraded into file writes by accident. The write is the whole
  risk and is guarded by ALL of: a **stale-write compare-and-swap** (the file's bytes are hashed at
  format-input time and re-checked immediately before the write, in the same daemon process that writes --
  any concurrent modification ABORTS and the newer file wins); an **atomic-or-abort** swap (temp file +
  atomic replace, never a torn/partial file); **byte fidelity** (the original BOM state and dominant EOL
  style are re-applied to the formatter's LF-normalized output, so the only byte delta is the formatting
  change itself); **no-change = no write** (an already-formatted file is never touched); and **conservative
  aborts to suggest** for mixed-line-ending or non-UTF-8 (UTF-16) files. An applied write surfaces a
  **visibly distinct WAS-MODIFIED block** instructing the agent to re-read, and that turn's diagnostics
  (derived from the pre-apply bytes) are omitted to avoid stale line numbers. Two **additive** daemon->client
  `formatStatus` values -- `applied` and `apply-aborted` -- carry the outcome. Like the 000061 closed-loop
  fields, `formatStatus` is an **output field, NOT part of the frozen Tier-1 contract**: the drift-guarded
  status taxonomy (1.2) is specifically the *diagnostics* tokens from `Get-DiagnosticsStatusBanner` /
  `Resolve-AnalysisStatus`, which this dispatch leaves untouched. So **no new frozen status token** and no
  second PSSA acquisition path -- the apply reuses the 000059 formatter, settings resolution, diff engine,
  and vendored pinned-hash PSSA.
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
- **`moduleAwareness` knob (DELIBERATE MINOR amendment) -- dispatch 000101.** A new optional, defaulted
  userConfig knob, `moduleAwareness`, was added to the manifest (and so to the FROZEN-KNOBS table above,
  which the drift-guard validates). This is the contract-relevant event the freeze exists to record: a
  new knob is a **deliberate, documented MINOR**, not a silent drift -- the table row IS the amendment,
  and the guard passes **because** the contract was updated, not bypassed. The knob's **default is
  `off`**, and with it off the diagnostics surface and all behavior are **byte-for-byte unchanged**: the
  daemon loads no index and takes no installed-modules snapshot, and the check never runs. When
  `suggest`, the warm daemon adds an **Information**-severity hint when a command in the edited file is a
  positive hit in a shipped, offline command->module index whose owning module is **not installed** on
  this machine (design B: the install-check is what earns an actionable message, because PowerShell
  auto-loads an installed module). It fires only on positive identification and degrades to **silence**
  on every ambiguity (a not-yet-ready snapshot, a dynamic include); it **never writes** a file and adds
  **no edit-path network or latency** (the index is a shipped artifact; install-state is a once-per-
  session background snapshot). The knob is an **enum** (`off` | `suggest`, default `off`), shaped like
  `formatOnEdit` so a future additive value could be added **without** a breaking knob change; it is
  never a boolean.
  - **Recorded design decision (Mike, dispatch 000101):** this is a **dedicated, orthogonal knob**, a
    deliberate **deviation from the 000100 survey's OQ3 first pick**, which recommended folding module
    awareness into the existing `ruleset` enum as an additive AI-era tier value. The survey named this
    dedicated-knob path as its explicit alternative; Mike chose it for **orthogonality** -- module
    awareness is about machine state (is a module installed?), a different axis from which rule *set*
    runs, and tier cross-products (`base` x awareness) do not scale. The cost the survey noted -- **+1
    frozen knob name** and the three-way manifest + CONTRACT-table + README drift-guard lockstep -- is
    paid here deliberately (this amendment + the README knob row + the manifest key). No new status
    token (a module-awareness hint rides the existing diagnostics channel as an Information record,
    exactly as BashIsm/PS7OnlySyntax do) and no second index/network acquisition path (the shipped
    `rulesets/command-module-index.psd1` is derived offline from a vendored source snapshot by
    `scripts/regen-command-module-index.ps1`, refreshed only by a deliberate dispatch).
- **`nativeServe` knob + native SERVE becomes real (DELIBERATE MINOR amendment) -- dispatch 000103.**
  This is precisely the contract-relevant event the 000075 note above flagged and deferred: *"If a
  future change makes native serve a real, user-visible feature, that is the contract-relevant event to
  adjudicate."* It is adjudicated here as a **MINOR** -- a new user-facing capability tier (hover /
  go-to-definition / find-references / documentSymbol served over Claude Code's NATIVE LSP client),
  additive and opt-in. A new optional, defaulted `userConfig` knob, `nativeServe`, was added to the
  manifest (and so to the FROZEN-KNOBS table above, which the drift-guard validates) -- the table row IS
  the amendment; the guard passes **because** the contract was updated, not bypassed. The knob's
  **default is `off`**, and with it off the protocol behavior is **byte-for-byte** what it is without the
  shim (the proxy relays every LSP frame unchanged -- no init patch, no interception -- so native nav
  stays gated exactly as it does today, and the warm PostToolUse diagnostics hook is wholly independent
  and unaffected in either mode). When `shim`, a thin stdio proxy (`scripts/pses-serve-shim.ps1`) wraps
  the launcher, patches the forwarded `initialize` (dynamicRegistration off, so PSES advertises its nav
  providers statically and sends no `client/registerCapability`; the params-level `workspaceFolders`
  #2300 dodge; a rename capability), and answers the residual `workspace/configuration` +
  `window/workDoneProgress/create` locally -- un-gating the built nav tier past the upstream
  `#1359`-class handshake WITHOUT waiting on the Claude Code fix. **No new status token** (native nav
  rides the LSP transport, a different axis from the diagnostics analyzer-health taxonomy of 1.2, which
  is untouched) and **no second PSES acquisition path** (the shim spawns the same pinned PSES the daemon
  vendors). The `lspServers` command now launches `pses-serve-shim.ps1` instead of `pses-stdio.ps1`, a
  change WITHIN the 000075 registrar-clean allowlist `{command, args, extensionToLanguage, transport,
  startupTimeout, maxRestarts, env}` (only an `args` value changed; no field added), so that guard stays
  green unmodified.
  - **Recorded deviation (survey-vs-disk, dispatch 000103):** the 000102 survey sketched `off` as
    *selecting* `pses-stdio.ps1` (the direct launcher). In practice an in-process `& pses-stdio.ps1`
    invoked from the shim two `&`-levels deep breaks PSES's stdio handoff (PSES dies rather than stalling
    like the direct launcher), so `off` is instead a **transparent byte relay** through the same proven
    spawn+pump machinery -- protocol-level behavior is identical (byte-for-byte pass-through), and the
    **full removal lever** is the manifest command swap back to `pses-stdio.ps1` (the survey's ranked
    option (a), unchanged). The shim is a workaround for an upstream Claude Code client bug, so it stays
    default-off with a documented removal path (see `docs/upstream/claude-code-lsp-registration.md`);
    flipping the default on is a later, evidence-backed dispatch.
- **`referenceSurfacing` knob (DELIBERATE MINOR amendment) -- dispatch 000128.** A new optional, defaulted
  userConfig knob, `referenceSurfacing`, was added to the manifest (and so to the FROZEN-KNOBS table above,
  which the drift-guard validates). This is the contract-relevant event the freeze exists to record: a new
  knob is a **deliberate, documented MINOR**, not a silent drift -- the table row IS the amendment, and the
  guard passes **because** the contract was updated, not bypassed. The knob's **default is `off`**, and with
  it off the diagnostics surface and all behavior are **byte-for-byte unchanged**: the daemon builds no
  workspace index and the check never runs. When `counts`, the daemon builds a **session workspace reference
  index** ONCE (a background, off-the-critical-path parse of the workspace's `.ps1` / `.psm1` / `.psd1`, so
  the first edit is never blocked) and each edit adds bare, additive **Information** facts on the existing
  `additionalContext` channel: for a function DEFINED in the edited file, how many OTHER workspace files
  reference it and whether it is exported; for a command CALLED in the edited file whose UNIQUE definition is
  elsewhere, where it is defined -- deduplicated per function. It fires only on positive, unambiguous
  identification and degrades to **silence** on every ambiguity (dynamic invocation, dynamic dot-source or
  import, string-built names, duplicate definitions across the workspace, a name that shadows a builtin
  cmdlet); it **never writes** a file and adds **no** edit-path network. The knob is an **enum** (`off` |
  `counts`, default `off`), shaped like `moduleAwareness` so a future additive value could be added
  **without** a breaking knob change; it is never a boolean.
  - **Recorded design (dispatch 000127 survey -> 000128 build):** **NO new owned diagnostic code and NO
    rationale-table change** -- a reference count names nothing WRONG (there is no defect and no fix), so it
    rides a distinct labelled `References:` section exactly as `Project intelligence:` (000062) and
    `Correction check:` (000061) do, and introduces **no new status token** (the 1.2 diagnostics taxonomy is
    untouched -- reference facts are a different axis from analyzer health). The session-start **index** was
    chosen over a per-edit workspace scan from MEASUREMENT (a per-edit full scan measured 11x-36x over the
    150 ms budget; the index makes per-edit cost O(edited file) -- ~3.9 ms p50 at 1000 files -- because repo
    size is not in the per-edit path), and the edited file's parse is **shared** with module awareness
    rather than duplicated (the survey's budget constraint). `moduleAwareness` and `referenceSurfacing` are
    **independent knobs on independent axes** (machine install-state vs workspace reference shape) and do
    not interact; there is no precedence between them.

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
