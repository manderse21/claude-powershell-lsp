# Configuration reference

This is the **authoritative reference** for every `powershell-lsp` `userConfig` knob. Each
knob's one-line description in the plugin manifest (`.claude-plugin/plugin.json`, surfaced in
the Claude Code `/plugin` config panel) is a **summary of the section here** -- the manifest
descriptions are deliberately capped so the config panel stays height-stable (see dispatch
000109), and the full semantics live below with one anchored section per knob.

Set these via the `/plugin` config UI for `powershell-lsp`, or leave the defaults.

**Do not want to set nineteen knobs?** Set one: [`profile`](#profile). `safe` (the default) is
exactly today's shipped behavior; `recommended` and `strict` are curated presets over everything
below. Any knob you set explicitly always wins over the profile.

The knobs, in manifest order:

- [`ps_host`](#ps_host) -- PSES host executable
- [`severityThreshold`](#severitythreshold) -- least-severe level surfaced
- [`ruleInclude`](#ruleinclude) -- exclusive rule-code allowlist
- [`ruleExclude`](#ruleexclude) -- rule-code suppression list
- [`timeoutMs`](#timeoutms) -- client hard cap before log-only degrade
- [`debounceMs`](#debouncems) -- edit-coalescing window
- [`keepLastN`](#keeplastn) -- rolling log files kept per family
- [`idleTtlMin`](#idlettlmin) -- daemon idle self-terminate window
- [`perFileCap`](#perfilecap) -- max diagnostics surfaced per file
- [`enableStats`](#enablestats) -- opt-in per-edit timing telemetry
- [`settingsPath`](#settingspath) -- absolute PSScriptAnalyzerSettings.psd1 override
- [`scopeToEdit`](#scopetoedit) -- scope diagnostics to the edited lines
- [`editContextLines`](#editcontextlines) -- context lines around the touched range
- [`formatOnEdit`](#formatonedit) -- format-on-edit suggestion / guarded apply
- [`ruleset`](#ruleset) -- live diagnostics ruleset tier
- [`moduleAwareness`](#moduleawareness) -- uninstalled-module command hint
- [`nativeServe`](#nativeserve) -- native hover / definition / references serve
- [`referenceSurfacing`](#referencesurfacing) -- workspace reference-count facts
- [`orgPolicy`](#orgpolicy) -- org-wide ExcludeRules policy path
- [`profile`](#profile) -- preset over every knob above

### A note on knob types

Every knob is declared `"type": "string"` in the manifest, and Claude Code exports each as a
`CLAUDE_PLUGIN_OPTION_<key>` environment variable -- so numbers and booleans arrive as text such
as `"20"` or `"true"`, and the plugin parses them (`Get-PluginOptionInt`, `Get-PluginOptionBool`),
falling back to the documented default on anything unparseable.

**This is a deliberate choice, not a platform limit.** The plugin-manifest schema this repo
validates against (`https://json.schemastore.org/claude-code-plugin-manifest.json`) permits
`"type"` to be any of `string`, `number`, `boolean`, `directory`, or `file`, and a `number` knob
may additionally declare `min` / `max`. Typing `timeoutMs` as `number` or `enableStats` as
`boolean` is therefore available, and would move range validation into the config panel instead of
into the plugin's fallback logic.

It is recorded here as a **future backward-compatible migration**, deliberately not performed in
this build. Two things make it a considered change rather than a tidy-up: the knob values still
arrive as environment text either way, so the parsing layer stays regardless; and CONTRACT.md's
capstone rule -- when in doubt whether a change is observable to an existing 1.x user, treat it as
observable -- means the migration needs its own dispatch to establish that a saved 1.x config
survives the retype unchanged. Until then, string-typed with parse-and-fall-back is the contract.

One genuine platform gap is worth naming precisely, because it is the reason the values below are
documented in prose rather than picked from a list: the `userConfig` schema has **no `enum`
property**. A knob like `formatOnEdit` cannot advertise `off | suggest | apply` to the config
panel, so the panel renders a free-text field and the plugin validates the value itself.

---

## ps_host

**What it does.** Selects the executable used to host PowerShell Editor Services (PSES).

**Type:** string. **Default:** `pwsh`.

The value is used as-is as the host executable and is resolved on `PATH`; any resolvable
PowerShell host is accepted, so this is not a fixed two-value enum. The two **recommended and
supported** values are `pwsh` (PowerShell 7+, the default, and the only combination tested in
CI) and `powershell` (Windows PowerShell 5.1). If the preferred executable cannot be resolved,
the plugin falls back through `pwsh` then `powershell`.

## severityThreshold

**What it does.** Sets the least-severe diagnostic level to report. More-severe levels are
always included, so a threshold of `Warning` reports Errors and Warnings only.

**Type:** string. **Values:** `Error`, `Warning`, `Information`, `Hint` (default).

Severity ranks are `Error` (1) > `Warning` (2) > `Information` (3) > `Hint` (4); a diagnostic is
kept when its rank is at least as severe as the threshold. `Hint` (the default) keeps every
severity. This filter applies on top of whatever PSES publishes, alongside `ruleInclude` /
`ruleExclude`.

## ruleInclude

**What it does.** When set, reports **only** the listed PSScriptAnalyzer rule codes and drops
everything else -- an exclusive allowlist.

**Type:** string (comma-separated rule codes). **Default:** empty (report all rules).

Example: `PSUseApprovedVerbs,PSAvoidUsingCmdletAliases`. An empty value applies no allowlist.

## ruleExclude

**What it does.** Suppresses the listed PSScriptAnalyzer rule codes from the surfaced
diagnostics.

**Type:** string (comma-separated rule codes). **Default:** empty (suppress nothing).

Example: `PSAvoidUsingWriteHost`. An empty value suppresses no rules.

## timeoutMs

**What it does.** The total time, in milliseconds, the PostToolUse client waits for a
diagnostics round-trip before degrading to log-only (it never blocks the edit).

**Type:** string (integer milliseconds). **Default:** `5000`.

## debounceMs

**What it does.** Edits landing within this many milliseconds of each other fold into a single
analysis pass, so a burst of rapid edits is analyzed once.

**Type:** string (integer milliseconds). **Default:** `150`.

## keepLastN

**What it does.** At SessionStart the plugin sweeps each rolling log family down to this many
newest files, bounding on-disk log growth.

**Type:** string (integer count). **Default:** `10`.

## idleTtlMin

**What it does.** The warm daemon self-terminates after this many minutes with no diagnostics
request, so an idle session does not leave a process running indefinitely.

**Type:** string (integer minutes). **Default:** `30`.

## perFileCap

**What it does.** Caps the number of diagnostics reported per file; any beyond the cap collapse
into a single `... and N more` line.

**Type:** string (integer count). **Default:** `20`. A value of `0` disables the cap (report
every diagnostic).

## enableStats

**What it does.** When enabled, appends one JSONL timing line per analyzed edit to
`logs/stats.jsonl` for observing analysis latency.

**Type:** string (boolean). **Values:** `false` (default), `true`. Boolean aliases are accepted
case-insensitively: `true` / `1` / `yes` / `on` enable; `false` / `0` / `no` / `off` disable.

It is **observe-only**: it never changes the diagnostics output. The log rotates (about 5 MB).
View a summary with `scripts/show-stats.ps1`.

> **Privacy note.** Each timing line records the **absolute path** of the analyzed file. All
> logs stay under your plugin data directory and are never transmitted, but sanitize paths
> before sharing a log for a bug report.

## settingsPath

**What it does.** An **absolute** path to a `PSScriptAnalyzerSettings.psd1` the analyzer should
honor, overriding auto-discovery.

**Type:** string (absolute path). **Default:** empty (auto-discover).

Auto-discovery walks up from the edited file to the nearest `PSScriptAnalyzerSettings.psd1`,
bounded at the project root. The path **must be absolute** -- a relative value is ignored -- and
the plugin never parses or executes the file itself; PSES is the trusted consumer. An empty
value uses auto-discovery.

## scopeToEdit

**What it does.** Filters the surfaced diagnostics to those overlapping the lines the edit
touched (plus `editContextLines` of context), so the feedback is what the edit is responsible
for rather than the whole file.

**Type:** string (boolean). **Values:** `true` (default), `false`. `0` / `false` / `off` report
whole-file.

It **fails open to whole-file** whenever the touched range cannot be determined -- a new-file
`Write`, a failed edit, or an unparseable payload -- so scoping **never hides a diagnostic**; the
worst case is showing more than strictly necessary, never less.

## editContextLines

**What it does.** Extra lines of context kept above and below the touched range when
`scopeToEdit` is on.

**Type:** string (integer count). **Default:** `0`.

The edit's structured patch already includes a few context lines, so the default of `0` is
usually right; raise it to widen the window around each edited region.

## formatOnEdit

**What it does.** After an edit, optionally runs PSScriptAnalyzer's `Invoke-Formatter` over the
edited file -- honoring the repo's own `PSScriptAnalyzerSettings.psd1` formatter rules when
present -- and either suggests the formatted result or writes it back under guard.

**Type:** string. **Values:** `off` (default), `suggest`, `apply`.

- **`off` (default).** Does nothing; the diagnostics surface is unchanged.
- **`suggest`.** Surfaces the formatted result as a **suggestion** -- a compact unified diff,
  clearly labelled and distinct from a diagnostic. In this mode the hook **never rewrites your
  file**; it only suggests, so editing is never disrupted.
- **`apply`.** Additionally **writes the formatted result back** -- the one mode that ever
  touches your file -- behind a deliberately strict guard:
  - **Stale-write compare-and-swap.** The file's bytes are fingerprinted when formatting starts
    and re-checked immediately before the write; if anything changed the file in between, the
    apply **aborts** and your newer content is left untouched (the concurrent edit always wins).
  - **Atomic write.** The formatted bytes are staged and swapped in atomically, so a crashed
    write can never leave a torn or half-written file.
  - **Byte fidelity.** The original BOM state and dominant line-ending style are preserved; the
    only byte difference from your file is the formatting change itself.
  - **Abort to suggestion for risky inputs.** A file with **mixed** line endings, or a non-UTF-8
    (for example UTF-16) file, **aborts to a suggestion** rather than risk a broader rewrite.
  - **Loud, and re-read.** An applied write is **announced loudly**, plainly stating the file
    **was modified** and telling the agent to re-read before its next edit (its in-context copy
    is now stale). Diagnostics for that turn are omitted to avoid stale line numbers.

`apply` is **doubly opt-in**: only the exact value `apply` activates it -- a boolean-truthy value
like `true` maps to the safe `suggest`, never to `apply`. Any failure or ambiguity degrades to a
suggestion or to nothing, the hook always exits 0, and a file that already matches the configured
style is never touched.

## ruleset

**What it does.** Selects which PSScriptAnalyzer rule set applies on the **live edit path** when
no repo-local `PSScriptAnalyzerSettings.psd1` and no `settingsPath` override resolve first.

**Type:** string. **Values:** `pses-default` (default), `base`.

- **`pses-default` (default).** Keeps PowerShell Editor Services' built-in no-settings rule set
  (about 15 rules) -- the live surface is unchanged from prior versions.
- **`base`.** Opts in to the plugin's shipped, **explicitly enumerated** base ruleset
  (`rulesets/base.psd1`): PSScriptAnalyzer's full default-on set **minus** the compatibility-profile
  rules. It is enumerated explicitly so the surfaced set is deterministic and does not drift when
  the pinned analyzer is bumped (regenerate with `scripts/regen-base-ruleset.ps1`). Opting in
  broadens the live surface -- notably `PSAvoidUsingWriteHost` and the three Error-severity
  security rules `PSAvoidUsingComputerNameHardcoded`,
  `PSAvoidUsingConvertToSecureStringWithPlainText`, and `PSAvoidUsingUsernameAndPasswordParams`
  start surfacing where the built-in set omits them.

**Precedence: repo settings always win.** An explicit `settingsPath` and a repo-local
`PSScriptAnalyzerSettings.psd1` **both win over the base** -- the base only fills the gap when
neither is present. The existing noise controls (`scopeToEdit`, `perFileCap`,
`severityThreshold`) still apply on top, and the default is deliberately **not** flipped: the
broadened surface never activates unless you opt in.

## moduleAwareness

**What it does.** When enabled, adds an **Information**-severity hint when a command in the
edited file is exported by a **known** module that is **not installed** on this machine, so the
call would not resolve.

**Type:** string. **Values:** `off` (default), `suggest`.

The hint is driven by a **shipped, offline command-to-module index** (`rulesets/command-module-index.psd1`)
-- a curated map of common first-party and Gallery modules (Az, Microsoft.Graph, Exchange Online,
ActiveDirectory, Pester, and more) to the commands they export -- regenerated offline from a
vendored source snapshot by `scripts/regen-command-module-index.ps1` and refreshed only by a
deliberate release. The message is actionable, for example: *"`Get-MgUser` is exported by module
`Microsoft.Graph.Users`, which is not installed on this machine; Install-Module
Microsoft.Graph.Users or import it."*

It is built to be quiet and correct: it fires **only on positive identification** and degrades to
**silence** on any ambiguity.

- It flags only a **literal command name** that is a hit in the shipped index -- never an unknown
  command (an unknown name is not evidence of a missing module; it could be your own function or
  private tooling).
- It stays silent when the command is a **built-in**, is **defined in the file** (a function or
  alias), is pulled in by a **literal dot-source** the check follows, or when the module is
  **declared** via `#Requires -Modules`, the nearest manifest's `RequiredModules`, or a literal
  `Import-Module`.
- It suppresses the **whole file** on a **dynamic** include it cannot resolve (for example
  `. $path` or `Import-Module $name`) -- it never guesses across something it cannot read.
- Because PowerShell auto-loads an installed module on first use, a command whose module **is**
  installed resolves fine -- so the hint fires **only** when the module is absent. Install-state is
  read **once per session** by a background snapshot taken off the critical path; until that
  snapshot is ready, the check stays **silent**.

It **never rewrites your file** and adds **no** edit-path network or latency (the index is a
shipped artifact; install-state is read once per session). `off` (the default) does nothing and
the diagnostics surface is byte-for-byte unchanged.

## nativeServe

**What it does.** When set to `shim`, serves **hover**, **go-to-definition**, **find-references**,
and **documentSymbol** to Claude Code's **native** LSP client on a `.ps1` / `.psm1` / `.psd1`, so
navigation resolves through PowerShell Editor Services rather than only the diagnostics from the
warm hook.

**Type:** string. **Values:** `off` (default), `shim`.

**Why it needs a shim.** Once the server is registered, Claude Code launches PSES but its LSP
client currently rejects the standard server-to-client requests PSES sends during initialization
(the upstream `#1359`-class handshake gap), so init times out (about 30 s) and nav never serves.
`nativeServe = shim` inserts a thin stdio proxy (`scripts/pses-serve-shim.ps1`) between Claude
Code and PSES that closes the gap locally, **without** waiting on the upstream fix. The proxy:

- **Patches the forwarded `initialize`:** it disables `dynamicRegistration` so PSES advertises its
  providers **statically** in the initialize result (and sends **no** `client/registerCapability`
  at all); it drops the params-level `workspaceFolders` that trips a PSES v4.6.0 Linux
  initialization NRE; and it ensures a `rename` capability (another PSES init NRE dodge).
- **Answers the residual requests locally:** it answers `workspace/configuration` and
  `window/workDoneProgress/create` itself (navigation is symbol-derived and settings-independent,
  so a local answer costs nothing).
- **Forwards everything else on the LSP transport byte-exact**, in both directions. Added latency
  is about 1-2 ms of framing per navigation round-trip (roughly 1% of PSES's own per-operation
  compute).

**`off` (the default) is a byte-exact, transparent pass-through.** The proxy still runs but
neither patches nor intercepts anything -- every LSP frame is relayed unchanged -- so the protocol
behavior is byte-for-byte what it is without the shim (native nav stays gated exactly as it does
today). The warm PostToolUse **diagnostics** hook -- the plugin's primary value -- is wholly
independent of this knob and unaffected in either mode.

**It is a workaround, so it is default-off and removable.** The shim exists only to route around
the upstream Claude Code client bug; when that bug is fixed, native nav will serve without it. To
remove the shim entirely, point the manifest `lspServers` command back at `scripts/pses-stdio.ps1`.
How you will *know* it is removable, and the full removal path, are recorded in
[`docs/upstream/claude-code-lsp-registration.md`](upstream/claude-code-lsp-registration.md).

> **Known issue -- Windows (Claude Code 2.1.196-2.1.200).** On Windows, these Claude Code versions
> refuse to start the plugin's LSP server -- a launcher-level guard rejects the bare `pwsh` command
> pre-spawn (`Command 'pwsh' not found or is in an unsafe location`) -- so the native nav tier does
> **not** start on Windows even with `nativeServe = shim`. This is an upstream Claude Code
> regression (it also breaks the official `pyright-lsp` plugin), filed as
> [`anthropics/claude-code#73961`](https://github.com/anthropics/claude-code/issues/73961). The
> plugin's core **PostToolUse diagnostics are unaffected** -- they run through a different,
> unguarded spawn path and keep working normally. The native-nav status on **macOS and Linux** under
> these Claude Code versions is **untested** with the real client. Full analysis:
> [`docs/upstream/claude-code-lsp-registration.md`](upstream/claude-code-lsp-registration.md)
> (dispatch 000107).

## referenceSurfacing

**What it does.** When enabled, surfaces **bare per-function facts** for the edited file, drawn from a
**session workspace index**: for a function DEFINED in the file, how many OTHER workspace files reference
it and whether it is exported; for a command CALLED in the file whose UNIQUE definition is elsewhere,
where it is defined.

**Type:** string. **Values:** `off` (default), `counts`.

The facts ride the existing `additionalContext` channel in a distinct `References:` section as additive
**Information** -- they are **facts, not diagnostics**. A reference count names nothing wrong, so this
adds **no new diagnostic rule code, no "fix", and no new status token** (the 1.2 diagnostics taxonomy is
untouched); it is the shape `Project intelligence:` (dispatch 000062) and `Correction check:` (dispatch
000061) already use for non-defect signal. Example lines:

- `Get-Widget -- referenced by 3 files, exported`
- `Invoke-Helper -- defined in scripts/lib/helper.ps1`

Like module awareness, it is built to be quiet and correct -- a *wrong* count would teach you to distrust
every count -- so it fires only on **positive, unambiguous identification** and degrades to **silence**
on any ambiguity:

- A **dynamic invocation** (`& $name`), a **string-built** name, or any call with no literal name
  contributes nothing to a count and never surfaces.
- A **dynamic** dot-source or `Import-Module` (`. $path`, `Import-Module $name`) suppresses the **whole
  file** -- a dynamic include could define names the index cannot see, so it never guesses across it.
- A name **defined in more than one** workspace file is silent (a count cannot say WHICH definition is
  referenced); a name that **shadows a builtin cmdlet** is silent (ambiguous at the call site).
- A definition with **no** cross-file references AND no export has nothing positive to say, so it is
  silent; the section only lists functions it has a fact about. Export state is read from a manifest's
  literal `FunctionsToExport` (a wildcard export is treated as indeterminate).

**How the index is built.** Once per session, a **background** parse of the workspace's `.ps1` / `.psm1`
/ `.psd1` files, rooted at the project directory and taken **off the critical path** so it **never
delays your first edit**; until it latches ready the check stays **silent**. It is bounded (noise
directories such as `.git` and `node_modules` are skipped, and the file count is capped) and best-effort
(a per-file parse error is skipped). Each subsequent edit costs only a parse of the edited file --
**shared** with module awareness, never a second parse -- plus a few hashtable lookups (survey-measured
at a few milliseconds; the per-edit budget bar is 150 ms). Because the index is a **session snapshot**,
cross-file counts reflect the workspace as of session start.

It **never rewrites your file** and adds **no** edit-path network. `off` (the default) builds no index,
runs no check, and the diagnostics surface is byte-for-byte unchanged.

## orgPolicy

**What it does.** Points the plugin at a centrally-managed `PSScriptAnalyzerSettings.psd1` -- an
organization's own settings layer -- and **enforces its `ExcludeRules`** over whatever the local
project configures.

**Type:** string (absolute path). **Default:** empty (off).

This is the **outermost** layer in the settings precedence chain, the only one that sits *above*
the repo-local file:

| Layer | Source | Effect |
|-------|--------|--------|
| **org policy** | `orgPolicy` (this knob) | its `ExcludeRules` are **enforced** and cannot be re-enabled locally |
| explicit override | `settingsPath` | wins over discovery for everything below |
| repo-local | nearest `PSScriptAnalyzerSettings.psd1`, walked up from the edited file | wins over the ruleset and the default |
| plugin base ruleset | shipped `rulesets/base.psd1` when `ruleset` = `base` | wins over the default only |
| PSES default | -- | PSES's own no-settings rule set |

**The exclude path: the org wins.** Rules listed in the policy's `ExcludeRules` are applied as a
**final subtractive drop** over the surfaced findings, *after* every other filter has run. A rule
your organization excludes therefore cannot be brought back by a repo-local
`PSScriptAnalyzerSettings.psd1`, by `ruleInclude`, or by any other local setting -- there is no
code path that re-adds a dropped finding.

**The include path: repo-local wins.** The policy's own `IncludeRules` are **advisory** and are not
read. An organization can take a rule **away**; it cannot force one **on**. That asymmetry is the
design, not an omission: central config is useful for suppressing noise fleet-wide, whereas forcing
extra rules onto a project that has deliberately excluded them produces findings nobody acts on.

**It fails open, but never silently.** Every failure -- a missing file, an unreadable file, an
unparseable one, or a **relative** path (only absolute paths are honored, for the same reason as
`settingsPath`: a relative path would resolve against whatever directory Claude Code launched in)
-- applies **no** exclusions and writes exactly **one** warning to `logs/lsp-client.log`. A policy
that cannot be read never blocks your edit, and never quietly stops enforcing without saying so. A
readable policy that simply declares no `ExcludeRules` is a valid no-op and warns about nothing.

**It cannot execute code.** The policy file is read through `Import-PowerShellDataFile`, which
parses in PowerShell's **restricted** language mode -- data only, no commands, no expressions. A
policy file containing a command invocation fails to parse (and degrades as above) rather than
running it.

Parse errors are never dropped: an `ExcludeRules` list names PSScriptAnalyzer rules, and a syntax
error is not a rule. Rule names match **case-insensitively**, as PSScriptAnalyzer's own do. Empty
(the default) reads no file, applies no filter, and leaves the diagnostics surface byte-for-byte
identical to a build without this layer.

Example policy on a share:

```powershell
@{
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
```

## profile

**What it does.** Applies a curated **preset** across the other knobs, so a useful configuration
is one setting rather than nineteen.

**Type:** string. **Values:** `safe` (default), `recommended`, `strict`.

**Precedence -- highest wins:**

```text
an explicitly-set knob   >   the profile's value   >   the shipped default
```

An explicitly-set knob **always** wins. That is not a convenience, it is what keeps the 1.x
contract intact: if a profile could override a value you had set, every existing configuration
would silently change meaning on upgrade, which CONTRACT.md classes as a MAJOR.

**`safe` (default) maps nothing.** It is not a table that restates the defaults -- it is the
absence of a mapping, so with `profile` unset or set to `safe` every knob resolves exactly as it
did before this knob existed and the diagnostics surface is byte-for-byte unchanged. An
unrecognized value (a typo, or a profile a future version adds) degrades to `safe` rather than to
a partial or guessed preset.

| Knob | shipped default | `safe` | `recommended` | `strict` |
|---|---|---|---|---|
| [`editContextLines`](#editcontextlines) | `0` | `0` | `2` | `2` (inert) |
| [`formatOnEdit`](#formatonedit) | `off` | `off` | `suggest` | `suggest` |
| [`ruleset`](#ruleset) | `pses-default` | `pses-default` | `base` | `base` |
| [`moduleAwareness`](#moduleawareness) | `off` | `off` | `suggest` | `suggest` |
| [`referenceSurfacing`](#referencesurfacing) | `off` | `off` | `counts` | `counts` |
| [`keepLastN`](#keeplastn) | `10` | `10` | `10` | `30` |
| [`perFileCap`](#perfilecap) | `20` | `20` | `20` | `0` |
| [`scopeToEdit`](#scopetoedit) | `true` | `true` | `true` | `false` |

Every knob not listed above is identical in all three profiles -- the profiles change only these
eight. `strict` is `recommended` plus the last three rows; `editContextLines` rides along from
`recommended` into `strict` and is **inert** there, because `scopeToEdit = false` already reports
whole-file.

**Why each departure.** `recommended` broadens what you see: `base` surfaces
`PSAvoidUsingWriteHost` and the three Error-severity security rules PSES's built-in set omits;
`suggest` modes surface a diff or a hint and never write; `counts` adds facts, not diagnostics;
two context lines keep the surrounding construct visible when a fix spans the boundary. `strict`
adds an enforcement posture: no per-file cap (a cap **hides** violations from an audit),
whole-file scope (a violation elsewhere is not invisible because the edit missed it), and a longer
log retention where an audit trail matters.

**Four values are deliberately in NO profile.** Each is a decision, not an omission:

- **`nativeServe` stays `off` everywhere.** The shim works around an upstream client bug. A preset
  must not put a workaround in front of more users.
- **`enableStats` stays `false` everywhere.** `logs/stats.jsonl` records absolute file paths
  today; path redaction ships **before** any profile turns telemetry on.
- **`formatOnEdit = apply` appears in no profile.** `apply` is the one mode that rewrites your
  file, and it is deliberately doubly opt-in. A preset goes as far as `suggest`.
- **`orgPolicy` is left empty.** `strict` is its use case, but a profile cannot hardcode a
  site-specific path -- the profile names the slot and your administrator supplies the value.

`timeoutMs` is unchanged in every profile for a **measured** reason rather than a ruling: the warm
edit-to-diagnostic round-trip under `ruleset = base` measured a p95 of 3292 ms over 20 samples on
the build host (median 2678 ms), leaving about 34% headroom under the shipped 5000 ms cap. The
broader rule set did not need a bigger budget, so it did not get one. If your host is
substantially slower, raise `timeoutMs` explicitly -- an explicit value always wins.

**Custom is the fourth option, and it is not a profile value.** Set knobs yourself, with or
without a profile also set; the explicit value wins either way. There is no `profile = custom`.

**Evolution policy.** These mappings are **curated, and MAY change in a MINOR release** -- for
example when stats-path redaction ships and `enableStats` becomes eligible. **An explicitly-set
knob is never affected by such a change.** That is what makes a future re-mapping a documented
curation update rather than a semver argument: the only configurations that move are the ones
that asked for "whatever the current recommendation is".

---

## The config panel and this reference

Claude Code's `/plugin` "Configure options" panel renders the selected knob's **entire**
description with no height cap. Long descriptions can therefore push the panel past the terminal
viewport, and on some terminals a navigation keypress that changes the panel height triggers a
renderer ghost-row corruption (surveyed in dispatch 000109). To keep the panel height-stable, the
manifest descriptions are capped and the full semantics relocated here.

This mitigates but does not fix the underlying Claude Code behavior: on a terminal shorter than
about 28 rows the knob panel can still overflow regardless of description length (the base rows
alone exceed the viewport), and the renderer bug and the absence of an enum picker remain upstream
defects. This reference is the durable home for the details; the panel summaries point here.
