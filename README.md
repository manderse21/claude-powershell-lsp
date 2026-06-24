# PowerShell LSP

[![CI](https://github.com/manderse21/claude-powershell-lsp/actions/workflows/powershell-lsp-ci.yml/badge.svg)](https://github.com/manderse21/claude-powershell-lsp/actions/workflows/powershell-lsp-ci.yml)
[![version](https://img.shields.io/github/v/tag/manderse21/claude-powershell-lsp?sort=semver&label=version&color=blue)](https://github.com/manderse21/claude-powershell-lsp/tags)
[![license: GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-blue)](./LICENSE)
[![SBOM: CycloneDX](https://img.shields.io/badge/SBOM-CycloneDX-brightgreen)](./TRUST.md#supply-chain-artifacts-sbom--build-provenance)
[![corpus false-positive rate: 0%](https://img.shields.io/badge/corpus%20false--positive%20rate-0%25-brightgreen)](#diagnostic-correctness-corpus)
[![code signing: pending](https://img.shields.io/badge/code%20signing-pending-orange)](./TRUST.md#code-signing-status----pending-the-plugin-is-not-signed)

PowerShell code intelligence for [Claude Code](https://claude.com/claude-code),
powered by [PowerShell Editor Services](https://github.com/PowerShell/PowerShellEditorServices)
(PSES). Real-time PowerShell diagnostics and PSScriptAnalyzer fix suggestions
while editing `.ps1`, `.psm1`, and `.psd1` files. Hover, go-to-definition, and
find-references are on the roadmap, pending upstream plugin LSP-server
registration (Claude Code #66987).

This is language tooling, not project tooling: a standalone plugin that carries
~0 always-on model-context token cost. It only spawns a language server when you
open a PowerShell file, and a single warm PSES serves the whole session so each
edit pays a pipe round-trip (~2 s) instead of a cold start (~6 s).

## Prerequisites

Check these before you start; the [Quick start](#quick-start) below runs them in order.

- [ ] **PowerShell 7+ (`pwsh`) on your PATH.** As of 1.1.1 the plugin's hooks launch
  under `pwsh`; Windows PowerShell 5.1 alone cannot bootstrap them. Check with
  `pwsh -v`; if it is missing, step 1 of the Quick start installs it.
- [ ] **Internet access on the first enabled session.** PowerShell Editor Services
  (PSES) and PSScriptAnalyzer are downloaded on first use, not vendored (see
  [Pinned versions](#pinned-versions) for the exact pins). The download is idempotent
  and marker-gated -- it runs once and no-ops every session after. Offline or behind a
  proxy, the first run surfaces an honest `unavailable` banner instead of failing
  silently (see [Diagnostics status](#diagnostics-status)).
- [ ] **On managed / locked-down Windows,** a security control (WDAC / AppLocker /
  ExecutionPolicy / Constrained Language Mode) can block a downloaded component; it
  then reads as `unavailable` rather than crashing. See [Troubleshooting](#troubleshooting).

Windows PowerShell 5.1 can still serve as the PSES *child host* (set `ps_host` to
`powershell`); it simply cannot launch the hooks themselves. See
[Platform support](#platform-support).

## Quick start

Copy-paste, top to bottom:

```text
# 1. Prerequisite (run in a terminal) -- skip if `pwsh -v` already works:
winget install Microsoft.PowerShell

# 2. In Claude Code -- add the marketplace, install, then enable the plugin:
/plugin marketplace add manderse21/claude-powershell-lsp
/plugin install powershell-lsp@claude-powershell-lsp
/plugin enable powershell-lsp

# 3. Start a new session (or run /reload-plugins) so the hooks load,
#    then open a .ps1 / .psm1 / .psd1 file to bring the language server up.
```

The machinery self-bootstraps, so the sequence above is the whole job. Three of its
steps are deliberate -- documented here rather than removed:

- **`/plugin enable` stays an explicit step.** The plugin ships disabled by default
  (`defaultEnabled: false`) because it downloads a bundle and spawns a language server,
  so enabling it is a conscious opt-in.
- **The new session / reload is required** -- Claude Code loads plugin hooks at session
  start, so enabling alone does not load them.
- **The first enabled session does the rest itself.** Its `SessionStart` hook downloads
  PSES and vendors PSScriptAnalyzer (both idempotent and marker-gated), then launches
  one warm daemon for the session. The first edit may briefly read `incomplete` while
  PSES finishes starting, then settles on the next edit (see
  [Diagnostics status](#diagnostics-status)).

## Configuration

Set these via the `/plugin` config UI for `powershell-lsp`, or leave the defaults.

| Key                | Default  | Meaning                                                                              |
|--------------------|----------|--------------------------------------------------------------------------------------|
| `ps_host`          | `pwsh`   | Host executable: `pwsh` (PowerShell 7+, recommended/tested) or `powershell` (Win 5.1) |
| `severityThreshold`| `Hint`   | Least-severe level to report: `Error` > `Warning` > `Information` > `Hint`            |
| `ruleInclude`      | _(empty)_| Comma-separated PSScriptAnalyzer rule codes to report exclusively; empty = all        |
| `ruleExclude`      | _(empty)_| Comma-separated rule codes to suppress (e.g. `PSAvoidUsingWriteHost`)                  |
| `timeoutMs`        | `5000`   | Total hard cap (ms) before the PostToolUse client degrades to log-only                 |
| `debounceMs`       | `150`    | Edits landing within this window (ms) fold into one analysis pass                      |
| `keepLastN`        | `10`     | Newest rolling log files kept per family (swept at SessionStart)                       |
| `idleTtlMin`       | `30`     | Daemon self-terminates after this many minutes with no diagnostics request            |
| `perFileCap`       | `20`     | Max diagnostics reported per file; the rest collapse into an `... and N more` line; `0` = no cap |
| `enableStats`      | `false`  | Append one JSONL timing line per analyzed edit to `logs/stats.jsonl` (rotating, ~5 MB); observe-only, never changes output. View with `scripts/show-stats.ps1`. `0`/`off` disable |
| `settingsPath`     | _(empty)_| Absolute path to a `PSScriptAnalyzerSettings.psd1` to honor, overriding auto-discovery; a relative value is ignored; empty = auto-discover (nearest file walked up to the project root) |
| `scopeToEdit`      | `true`   | Scope surfaced diagnostics to the lines the edit touched (plus `editContextLines`); fails open to whole-file when the range is indeterminate. `0`/`off` report whole-file |
| `editContextLines` | `0`      | Extra context lines kept above and below the touched range when `scopeToEdit` is on; the edit's patch already includes a few, so the default is `0` |

Diagnostics are returned in a stable order (severity, then line, then column),
deduped, threshold- and rule-filtered, then capped per file.

These filters apply on top of whatever **PSES** publishes. PSES runs its own default
PSScriptAnalyzer rule set for live analysis, which is narrower than the
`Invoke-ScriptAnalyzer` CLI default -- for example `PSAvoidUsingWriteHost` is not
surfaced on the fly even though the CLI flags it. The knobs here can *suppress or
narrow* what PSES reports; they cannot add a rule PSES does not run.

> **Privacy note -- `enableStats` logs absolute paths.** When `enableStats` is on (it is
> **off by default**), each timing line in `logs/stats.jsonl` records the **absolute path**
> of the analyzed file. All logs stay under your plugin data directory and are never
> transmitted, but if you share a log for a bug report, sanitize the paths first. (Path
> redaction may arrive as a later option; for now the caveat is the contract.)

## Performance

Measured on `pwsh` 7.6.3, Windows 11, at the v1.12.0 build:

- **Warm-path latency** (edit -> diagnostic round-trip; median of 5 successive
  real edits against an already-warm daemon): **~2.2 s** (median ~2210 ms; range
  ~2154-2236 ms).
- **Cold-start latency** (SessionStart hook -> the per-session PSES daemon reaches
  ready; median of 3): **~3.9 s** (median ~3892 ms; range ~3789-4561 ms).

Roughly 0.7 s of the warm path is the per-hook `pwsh` process spawn that Claude
Code pays regardless of plugin code.

These latencies are **measured and guarded in CI** by a repeatable benchmark
harness (`tests/PowerShellLsp.Benchmark.Tests.ps1`): it times the real daemon/pipe
path on all four CI legs (Windows `pwsh`, Windows PowerShell 5.1, Ubuntu, macOS),
emits structured results (`benchmark-results.json`), and fails if a median
regresses past a generous threshold. The first-pass bounds are deliberately loose
(cold under 20 s, warm under 9 s) -- enough to catch a gross regression without
flaking on slower hosted runners; they tighten as per-leg CI numbers are
characterized.

The acceptance suite also confirms: cold-session bring-up launches exactly one
daemon; a deliberate diagnostic returns over the warm path; the settled
PSScriptAnalyzer pass (not the early parser publish) is reported; file URIs carry
uppercase drive letters; three rapid edits coalesce into one analysis pass;
SessionEnd leaves no daemon/PSES processes; and killing the daemon mid-session
degrades gracefully (no stdout, under the hard cap) while the next SessionStart
reaps the stale session and its orphaned PSES.

## How it works (warm-start daemon)

Diagnostics are delivered through a **PostToolUse hook backed by a warm,
per-session daemon** -- one PSES stays hot for the whole session, so each edit
pays a pipe round-trip instead of a cold PSES start.

```text
SessionStart  -> scripts/session-start.ps1
                   ensure-pses.ps1   (idempotent PSES bootstrap, pinned tag)
                   ensure-pssa.ps1   (idempotent PSScriptAnalyzer vendor, pinned)
                   log sweep (keep-last-10 per family)
                   reap OUR stale daemons (recorded pids only, verified)
                   launch scripts/pses-daemon.ps1  (one warm PSES via -Stdio;
                     named pipe powershell-lsp-<sessionid>; pid/heartbeat in
                     CLAUDE_PLUGIN_DATA/session/<sessionid>.json)

PostToolUse   -> scripts/lsp-client.ps1
                   read hook JSON (session_id, file_path) from stdin
                   connect to the pipe, request diagnostics for the edited file
                   daemon: didOpen/didChange -> wait for the SETTLED PScriptAnalyzer
                     publish (not the early parser publish) -> debounce
                   return deduped, severity-sorted diagnostics to Claude via
                     hookSpecificOutput.additionalContext

SessionEnd    -> scripts/session-end.ps1
                   pipe {shutdown} -> daemon sends LSP shutdown/exit to PSES,
                   removes its session file, exits
```

- **`scripts/lib/lsp-common.ps1`**: shared helpers (host detection, file-URI with
  uppercase drive, LSP framing, diagnostics ordering/dedupe), dot-sourced by the
  daemon, client, hooks, and tests.
- **`scripts/ensure-pses.ps1`**: idempotent PSES bootstrap into
  `${CLAUDE_PLUGIN_DATA}/PowerShellEditorServices`; no-op once present.
- **`scripts/ensure-pssa.ps1`**: idempotent vendor of pinned PSScriptAnalyzer into
  `${CLAUDE_PLUGIN_DATA}/modules`, prepended to the PSES child's `PSModulePath` so
  the analyzer pass runs (PSES emits only parser errors without it).
- **`scripts/pses-stdio.ps1`**: the cold-start `-Stdio` launcher -- the destination
  for native `.lsp.json` registration (see below).

All scripts run `-NoLogo -NoProfile`, write nothing to stdout on the daemon/LSP
path, and keep all state, logs, and pids under `CLAUDE_PLUGIN_DATA` only.

## Why a hook, not native `.lsp.json` registration

Claude Code declares plugin language servers through a per-plugin
[`.lsp.json`](https://code.claude.com/docs/en/plugins-reference#lsp-servers) file
(or an equivalent inline `lspServers` block, which this plugin's `plugin.json`
carries). That is the intended path. In practice it has been unreliable for
plugin-provided servers, for two independent reasons:

1. **Marketplace plugins can install without their `.lsp.json`.** Claude Code
   copies a plugin's source directory into its cache; an `lspServers` block that
   lives only in `marketplace.json` is not written out, so the installed plugin
   registers **0 servers**. Tracked (open) at
   [claude-plugins-official#379](https://github.com/anthropics/claude-plugins-official/issues/379).
   A proposed fix, [PR #378](https://github.com/anthropics/claude-plugins-official/pull/378)
   (add a real `.lsp.json` to each official LSP plugin), was **closed unmerged**
   (2026-02-11), so #379 remains open and unaddressed.
2. **A registration race.** `LspServerManager` can initialize before plugins
   finish loading, registering 0 servers even when a `.lsp.json` is present.
   First reported in
   [claude-code#14803](https://github.com/anthropics/claude-code/issues/14803)
   (fixed) and analyzed in detail in
   [claude-code#29858](https://github.com/anthropics/claude-code/issues/29858);
   the symptom remains open at
   [#15168](https://github.com/anthropics/claude-code/issues/15168) and
   [#15148](https://github.com/anthropics/claude-code/issues/15148).

So rather than depend on native registration, this plugin delivers diagnostics
through a **warm PostToolUse hook** that always works, on every supported host,
today. The hook is the product; native registration is a bonus you can opt into.

### Native registration (`.lsp.json`) -- not active upstream yet

The plugin already declares its server (the `lspServers` block in `plugin.json`), and
a standalone copy ships at [`docs/lsp.json.template`](docs/lsp.json.template). Both are
the *intended* native path -- but **as of Claude Code 2.1.183 neither activates**. The
detailed three-configuration test below was run on 2026-06-06 against Claude Code 2.1.167
(dispatch 000008); the inertness has since been **re-confirmed through 2.1.183
(2026-06-19)**, with no registration fix landing in the 2.1.167 -> 2.1.183 window:

- a clean top-level-map `.lsp.json` with **literal** commands (no `${CLAUDE_PLUGIN_ROOT}`
  / `${user_config.*}` template variables), loaded into a **freshly started** process
  (`--plugin-dir`, a full restart, not `/reload-plugins`) -> `No LSP server available
  for file type: .ps1`;
- that same literal `.lsp.json` shipped inside a throwaway plugin and **installed through
  the real `/plugin` flow**, so the installer placed the file in the plugin cache (the
  exact installed-cache setup some users report working, reached without hand-writing the
  cache) -> still `No LSP server available`, after a full restart;
- the installed real plugin, whose cache already carries a template-var `.lsp.json` ->
  inert the same way.

So the inertness is not a reload-vs-restart, template-variable, or
`--plugin-dir`-vs-installed-cache artifact -- a plugin `.lsp.json` simply does not
register on 2.1.167, and the canonical probe re-confirms it inert through 2.1.183. This
finally tests the installed-cache path a prior re-test had to leave open, **closing** that
caveat rather than narrowing it. Native registration is not
something this plugin can rely on today -- which is why diagnostics ride the PostToolUse
hook, the path that works on every host now. (Methodology and evidence in
[`docs/upstream/claude-code-lsp-registration.md`](docs/upstream/claude-code-lsp-registration.md),
held for review.)

The template ships as `docs/lsp.json.template` (not live at the root) on purpose: a
root `.lsp.json` adds nothing while registration is broken, and would risk duplicate
diagnostics the moment a future release fixes it. When that release lands, copy it in
to opt into the native path:

```
cp docs/lsp.json.template .lsp.json
# then FULLY restart Claude Code -- a new process. /reload-plugins is not enough:
# re-probes confirmed a plugin-root .lsp.json stays inert even after a full restart,
# through 2.1.183 (2026-06-19), so this is for a future release that fixes registration.
```

> **Heads-up once it does activate -- duplicate diagnostics.** If native registration
> ever turns on while the PostToolUse hook is also enabled, each diagnostic arrives
> twice. Use one path or the other.

## Pinned versions

| Component         | Version  | Pinned in                 | Source                                  |
|-------------------|----------|---------------------------|-----------------------------------------|
| PSES              | `v4.6.0` | `scripts/ensure-pses.ps1` (`$PsesTag`)     | GitHub release `PowerShellEditorServices.zip` |
| PSScriptAnalyzer  | `1.25.0` | `scripts/ensure-pssa.ps1` (`$PssaVersion`) | PowerShell Gallery                      |

To bump either, change the single pin variable named above and start a fresh
session (the ensure-step re-vendors at the new version, keyed by a per-version
marker). See [CHANGELOG](./CHANGELOG.md#versioning) for how a bump maps to SemVer.

## Platform support

As of 1.1.1 the **hooks require `pwsh` (PowerShell 7)** -- they launch the bootstrap
under it on every platform. Windows PowerShell 5.1 is supported as the **PSES child
host** (set `ps_host` to `powershell`), not as the hook interpreter.

CI runs the Pester suite on a four-leg matrix: **Windows `pwsh` 7**, **Windows
PowerShell 5.1**, **Ubuntu `pwsh`**, and (as of 1.3.0) **macOS `pwsh`**. The full
warm-daemon **integration suite** (one-daemon bring-up, the settled PSScriptAnalyzer
pass, clean SessionEnd) runs and is **green on all four legs** -- so the **Linux and
macOS daemon paths are CI-verified**, not merely authored. The integration tests drive the daemon under
`pwsh` on every leg, so the Windows-PowerShell-5.1 leg's distinct value is exercising
the **shared-library surface under 5.1** -- file-URI casing, BOM-tolerant stdin, the
`ArgumentList`-vs-quoted-`.Arguments` split, and the config-env fallback -- the code
that must keep working when PSES runs as a 5.1 child.

The scripts are cross-platform: all paths go through `Join-Path`, host detection is
shared, the single Windows-only call (process command-line lookup, used to verify a
pid is ours before any kill) is guarded behind `Test-OnWindows` with Linux `/proc`
and macOS `ps` fallbacks, and the client/daemon transport is `System.IO.Pipes` (Unix
domain socket semantics on *nix). As of 1.3.0 that macOS `ps` fallback is exercised by
the macOS CI integration leg, so **macOS is CI-verified** alongside Linux.

## Diagnostics status

Every analyzed edit resolves to one of four statuses. The clean case is silent; the other
three surface a one-line banner in Claude's context, so a result is never *mistaken* for
"analyzed, clean" when it was not actually analyzed. The wording is owned in one place
(`Get-DiagnosticsStatusBanner` in `scripts/lib/lsp-common.ps1`).

| Status            | When                                                                 | What you see / what to do |
|-------------------|----------------------------------------------------------------------|---------------------------|
| **`ok`**          | The PSScriptAnalyzer pass settled and the analyzer was available.    | Nothing extra -- diagnostics (if any) are shown, no banner. The warm happy path. |
| **`incomplete`**  | The pass did **not** settle for this edit -- PSES timed out, threw, exited, a supervised re-spawn was mid-flight, or PSES is **still starting** (pipe-first opens the request pipe before PSES is ready, dispatch 000028). | `analysis did not complete -- this edit was NOT checked.` Transient: the next edit usually succeeds once PSES is ready. |
| **`degraded`**    | PSES is up and settled, but the vendored **PSScriptAnalyzer is absent**, so only the parser ran. | `parser-only mode -- PSScriptAnalyzer unavailable, lint rules were NOT checked (syntax errors are still reported).` Start a fresh session so `ensure-pssa` re-vendors; see `logs/ensure-pssa.log`. |
| **`unavailable`** | PSES **could not start at all**, for the whole session -- either the bundle **never bootstrapped** (a clean box, offline or behind a proxy) or it is present but **failed to initialize** (a startup failure / init timeout, dispatch 000028). | `PowerShell editor services could not start -- not installed (the bootstrap did not complete), or installed but failed to start. Diagnostics will stay OFF for this whole session until it is fixed and the session is restarted.` Fix the install/startup, then start a fresh session; see `logs/ensure-pses.log` and `logs/pses-daemon.log`. |

`incomplete` (transient -- "not ready/settled this time, the next edit will be") and
`unavailable` (permanent for the session -- "could not start; fix and restart") are
deliberately distinct, with distinct remedies. The install-time `unavailable` arrived in 1.5.0
(dispatch 000024); 1.6.0 (dispatch 000028) made the daemon **pipe-first** -- it opens the
request pipe *before* bringing PSES up -- so a first edit that races startup now gets one of
these honest banners instead of silence, and generalized `unavailable` to also cover a
present-but-failed start (not just a missing install). When the daemon is unreachable entirely --
no pipe at all (the brief daemon-launch window, or a session whose daemon has stopped after idle) --
the PostToolUse client surfaces its own honest "analyzer was not reachable -- this edit was NOT
checked" banner (start a new session to restart the daemon), so even the no-pipe case is never
silent. The mid-session `incomplete`/`degraded` split was introduced earlier (dispatch 000022).

## Dogfood diagnostic capture

Every diagnostic the plugin surfaces is also **teed to a local, append-only log** so the real
diagnostics from real day-to-day editing can drive the roadmap's quality work -- rule curation,
false-positive reduction, fix-suggestion quality -- ranked on evidence instead of guesses. The
companion tool that annotates this log -- filling each `verdict` -- is documented in **Dogfood
review** below.

- **Where:** `dogfood/diagnostics.jsonl` in the plugin tree. Override with the
  `POWERSHELL_LSP_DOGFOOD_LOG` environment variable (a full path to the `.jsonl` file).
- **What:** one JSON object per line, one line per diagnostic **occurrence** -- two identical
  diagnostics make two lines (frequency is the signal; de-duplication is an analysis-time concern,
  never a capture-time one). Each entry carries: `ts` (ISO-8601), `file`, `line`, `col`, `ruleId`
  (the PSScriptAnalyzer rule, or empty for a parser error), `source` (`PSScriptAnalyzer` or
  `parser`), `severity`, `message`, `snippet` (the full offending line), `hash` (a stable key over
  the rule id + the normalized offending-line shape, for analysis-time de-duplication), and
  `verdict` -- written **empty**, reserved for you to annotate later with `scripts/review-dogfood.ps1`
  (see **Dogfood review** below).
- **Invisible side channel:** capture runs *after* the diagnostics are surfaced and is fully
  fail-safe. If the write fails for any reason, the diagnostics you see and the hook's exit code are
  byte-for-byte unchanged; logging never changes, reorders, delays, or gates what is surfaced.

> **Never commit this log.** It holds **real source snippets** from the files you edit. The whole
> `dogfood/` directory is gitignored (see `.gitignore`) and must never be staged, added, or
> committed -- do not weaken that entry.

## Dogfood review

The offline tool `scripts/review-dogfood.ps1` fills the empty `verdict` field that the capture
reserves. It never changes what the daemon or hooks run and never alters the diagnostics surface or
the capture log. Instead, it turns raw captured diagnostics into ranked input for the roadmap's
quality work (rule curation, false-positive reduction, fix quality).

- Collapses captured occurrences into distinct diagnostic **shapes**, keyed by the record's `hash`
  (rule id + normalized offending-line shape). Identical diagnostics share one verdict, so a misfire
  seen many times is judged once; re-runs skip shapes that already have a verdict (resumable).
- Fixed verdict vocabulary (lower-case): `useful` (true, actionable), `false-positive` (the rule
  misfired), `noisy` (correct but low-value / clutter), `bad-fix` (the finding is fine but its
  suggested correction is wrong / harmful), `unsure` (needs a second look). It is a fixed enum, not
  free text; an optional one-line rationale may accompany a verdict.
- **Persistence:** verdicts are written to a **separate sibling file**, `dogfood/annotations.jsonl`,
  keyed by the shape hash. Append-only, last-write-wins (a corrected verdict appends a new line;
  readers honor the latest). The capture log (`diagnostics.jsonl`) is never rewritten -- it stays
  immutable evidence.
- **Read-only by default:** with no write action the tool lists the pending shapes and prints a
  **summary** (counts by verdict, annotation coverage, and the top "actionable" rules -- those
  verdicted false-positive / noisy / bad-fix -- ranked by occurrence count). Writing a verdict is the
  explicit action.
- **Recording a verdict:** non-interactively with `-Hash <hash> -Verdict <verdict> [-Rationale
  "..."]`, or interactively with `-Review` (a guarded prompt loop over pending shapes; on a
  non-interactive host it falls back to the read-only listing instead of blocking).
- Use `-Redact` to mask the offending-line snippet in listings when sharing a review. Other flags:
  `-Summary` (summary only), `-All` (list every shape, not just pending), `-Path` and
  `-AnnotationsPath` (point at explicit files).

```text
pwsh -File scripts/review-dogfood.ps1
pwsh -File scripts/review-dogfood.ps1 -Summary
pwsh -File scripts/review-dogfood.ps1 -Review
pwsh -File scripts/review-dogfood.ps1 -Hash <hash> -Verdict false-positive -Rationale "..."
```

> **Never commit the annotations file either.** It lives under the same already-gitignored
> `dogfood/` directory as the capture log, so the `.gitignore` already covers it -- do not weaken
> that entry. Its free-text rationale could quote source, so it stays local-only like the log.

## Diagnostic-correctness corpus

A curated corpus (`tests/corpus/`) proves the diagnostics the tool *reports* are correct -- not
merely present, and not merely honest when it cannot analyze. Three sample categories:

- **clean** (34 cases) -- expect zero findings (no false positives on clean code); a deliberately
  broad span of real-world idioms (advanced functions with `begin`/`process`/`end`, classes with
  inheritance and static members, `[Flags]` enums, validation attributes, `SecureString` /
  `PSCredential` parameters, splatting, multi-stage pipelines, typed `try`/`catch`/`finally`,
  here-strings, regex, `ShouldProcess`, and more).
- **known-bad** (36 cases) -- six cases per surfaced rule, each tripping a specific PSScriptAnalyzer
  rule the tool surfaces, asserting the exact rule id, line, and severity; the several cases per
  rule exercise varied triggering constructs.
- **parser-error** (3 cases) -- expect parser diagnostics.

**Measured correctness (default config, all four CI legs).** Across those curated cases the tool
posts a **0% false-positive rate** (0 of 34 known-good cases produced any finding) and **100%
true-positive coverage** (36 of 36 known-bad cases surfaced their expected rule), spanning every
rule the default ruleset surfaces. These numbers are not prose -- they are recomputed from the live
tool on every CI run and **guarded** (`tests/PowerShellLsp.Corpus.Tests.ps1`: the report fails CI if
the false-positive rate rises above zero, coverage drops below 100%, the corpus shrinks below 30
known-good or 30 known-bad, or any surfaced default rule loses its known-bad case), and the per-run
report is uploaded as a CI artifact (`logs/corpus-correctness-report.json`). The claim is *measured
and defensible*, not *exhaustive*.

**The invariant that makes it trustworthy:** every expected finding is *derived* by running the
REAL tool over the sample and snapshotting exactly what it emits (through the plugin's own dogfood
capture channel) -- never hand-authored, never model-authored. A generator
(`tests/corpus/Update-CorpusSnapshots.ps1`) writes the committed snapshots; the corpus test
re-derives the same way and asserts the live tool still matches. A future behavior change becomes a
visible, located failure, and a hand-edited snapshot cannot make the test pass -- it would simply
disagree with the real tool.

One fact the corpus surfaced: the tool's effective default ruleset (via PowerShell Editor Services)
is **narrower** than raw PSScriptAnalyzer. Measured against the live daemon, it surfaces **six** rules
on the fly -- `PSAvoidUsingCmdletAliases`, `PSUseApprovedVerbs`,
`PSUseDeclaredVarsMoreThanAssignments`, `PSAvoidUsingPlainTextForPassword`,
`PSPossibleIncorrectComparisonWithNull`, and `PSAvoidDefaultValueSwitchParameter` -- and drops others
the CLI flags (e.g. `PSAvoidUsingEmptyCatchBlock`, `PSReviewUnusedParameter`,
`PSUseShouldProcessForStateChangingFunctions`, `PSAvoidUsingWriteHost`,
`PSAvoidUsingPositionalParameters`, `PSUseSingularNouns`). The corpus records what the tool actually
surfaces; tuning the ruleset is a separate, dogfood-paced quality track. The corpus runs in CI on all
four legs.

## Troubleshooting

### Preflight self-check (the doctor)

Before chasing a specific symptom, run the preflight **doctor** -- it checks the
prerequisites and bootstrap health in one place and prints a named fix-list:

```
pwsh -File scripts/doctor.ps1
```

It verifies, in order: PowerShell 7 (`pwsh`) is present and new enough (see
[Prerequisites](#prerequisites)); the plugin is enabled (see [Quick start](#quick-start)); the PSES
bundle and PSScriptAnalyzer finished bootstrapping (the pinned markers plus
`Start-EditorServices.ps1`, see [Pinned versions](#pinned-versions)); the first-run
download hosts are reachable; and the **warm per-session daemon** is alive and answering on its
named pipe -- the *runtime* check the first five cannot make (they confirm the bundle is
**installed**; this confirms the language server is actually **running**). Each check reports
`PASS`, a specific failure with the fix, or an honest `UNKNOWN` when it genuinely cannot
determine -- for example, run outside a Claude Code session it cannot see the plugin data
directory, so the enable-state, bundle, and daemon checks report `UNKNOWN` (run it from inside
an enabled session for a definitive result).

The daemon check **observes only** -- it never starts, restarts, or kills the daemon -- and it
is honest about the auto-relaunch design (see [Diagnostics status](#diagnostics-status)): **no
daemon running** reports `PASS` (benign -- one auto-relaunches on your next edit), never a scary
failure, while a daemon that is alive but parked `unavailable` / `degraded`, or alive but not
answering its pipe, is a `FAIL` with the restart remedy.

The doctor is **report-only**: it never downloads, repairs, runs the bootstrap, or
starts/restarts the daemon. It also does **not** probe security controls itself -- but when a *bootstrap* failure is
caused by one, the SessionStart banner now names the most likely control and the
legitimate fix (see [Security-control blocks on managed Windows](#security-control-blocks-on-managed-windows)
below). If a doctor check fails for a reason its own fix does not resolve, a security
control on a managed machine (an execution or application-control policy) may be the
cause -- check that banner and the section below.

### Symptoms

- **Hooks fail with `'pwsh' is not recognized` / pwsh not found:** as of 1.1.1 the
  hooks launch under PowerShell 7. Install it (`winget install Microsoft.PowerShell`)
  -- Windows PowerShell 5.1 alone cannot launch the hooks. (`ps_host` only selects the
  PSES *child* host, not the hook interpreter.)
- **A leftover user-level PSES hook fires alongside the plugin (duplicate or
  conflicting diagnostics):** if you previously wired a PowerShell diagnostics hook
  directly in `~/.claude/settings.json` (a pre-plugin setup), remove it -- the plugin
  owns the SessionStart / PostToolUse / SessionEnd hooks now, and a stray user-level
  hook will double up or conflict with them.
- **`/plugin` Errors tab shows `Executable not found in $PATH`** for the
  `powershell` server: `ps_host` points at an executable that is not on PATH.
  Install PowerShell 7 (`pwsh`) or set `ps_host` to `powershell`.
- **No diagnostics / server never starts:** confirm the bootstrap ran by checking
  that
  `${CLAUDE_PLUGIN_DATA}/PowerShellEditorServices/PowerShellEditorServices/Start-EditorServices.ps1`
  exists. If not, start a fresh session so the `SessionStart` hook can run, and
  inspect `${CLAUDE_PLUGIN_DATA}/logs/ensure-pses.log`.
- **Server starts but handshake fails:** inspect the PSES log under
  `${CLAUDE_PLUGIN_DATA}/logs/pses-lsp.log/StartEditorServices-<pid>.log` for the
  PSES-side error.
- **`PrepareRenameHandler` `NullReferenceException` on initialize:** a PSES
  `v4.6.0` bug -- its rename handler dereferences a null `RenameCapability` when an
  LSP client's `textDocument` capabilities **omit** `rename`. This plugin's daemon
  **declares a minimal `rename` capability on purpose**, which is what *avoids* the
  NRE, so the warm path is unaffected. You would only hit this by driving PSES from
  a client that omits rename (e.g. a hand-rolled minimal client against the cold
  `-Stdio` launcher); if so, pin PSES `v4.5.0` in `scripts/ensure-pses.ps1`
  (`$PsesTag`), which predates the rename handler.

### Security-control blocks on managed Windows

PowerShell developers often work inside locked-down Windows estates, and this plugin does
exactly what those estates gate: it **downloads** executables (PSES, PSScriptAnalyzer),
**runs** PowerShell, and **spawns** a daemon. When a security control blocks one of those
at first start, the bootstrap fails -- and instead of a generic "could not start", the
SessionStart banner now **names the most likely control and the legitimate remediation**.
The status stays `unavailable` (see [Diagnostics status](#diagnostics-status)); only the
message gets specific.

A control is named **only on positive evidence**, with calibrated confidence -- an
uncertain case gets an honest "here is how to check" pointer, never a guessed control:

| Control | How it is detected | Confidence | Banner names / fix |
|---------|--------------------|------------|--------------------|
| **ExecutionPolicy** (Group Policy) | `Get-ExecutionPolicy -List` shows `MachinePolicy`/`UserPolicy` = `AllSigned`/`RemoteSigned` (a command-line `-Bypass` is ignored when the policy is from GPO) | likely | the policy + scope. Fix: an admin allow-lists / signs the scripts, or adjusts the policy. |
| **Constrained Language Mode** | the session `LanguageMode` is `ConstrainedLanguage` | likely | CLM. The plugin's .NET-using bootstrap cannot run under it. Fix: sign + policy-trust the plugin (admin). |
| **App Control / WDAC** | a CodeIntegrity Operational event **3077** (enforced) or **3076** (audit) names a plugin component | confirmed / likely | the control + event id. Fix: an admin adds an allow rule. |
| **Microsoft Defender ASR** | a Defender Operational event **1121** (block) or **1122** (audit) names a plugin component | confirmed / likely | the rule family + event id. Fix: an admin reviews / allows the rule. |
| **Smart App Control** | the SAC registry state (`VerifiedAndReputablePolicyState`) is enforced / evaluation | possible | SAC is reputation-gated, so it is only ever *possible*. Fix: it relaxes as reputation accrues, or an admin turns it off. |
| *(none identified)* | no positive evidence | -- | honest pointer: usually network/proxy; if managed, check `Get-ExecutionPolicy -List`, the language mode, and the CodeIntegrity log. |

To investigate a named (or suspected) block yourself, on the affected machine:

```
Get-ExecutionPolicy -List
$ExecutionContext.SessionState.LanguageMode
Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-CodeIntegrity/Operational'; Id = 3076, 3077 } -MaxEvents 20
```

**The plugin only ever detects and explains a block -- it never bypasses, disables, or
modifies a security control.** Every remediation above is something a user or their
administrator does deliberately (sign, allow-list, adjust policy); the plugin itself takes
no such action. A tool that tried to circumvent enterprise security would deserve to be
banned -- honest degradation, telling you exactly what is blocked and how to allow it, is
the whole value.

## Verify your install

You do not have to take this plugin's integrity on trust -- you can check it. The two pinned
dependencies it downloads on first run are each verified against a SHA-256 computed from the real
known-good artifact *before* they are used, and a mismatch **fails closed** (the unverified bundle is
refused and the session reads `unavailable`). The pins and their hashes live in the repo, so you can
confirm the bytes on your machine match what this repo ships:

```
# The pinned versions + SHA-256 hashes are tabulated in TRUST.md; the pins themselves live in
# scripts/ensure-pses.ps1 ($PsesTag / $PsesSha256) and scripts/ensure-pssa.ps1 ($PssaVersion /
# $PssaSha256). Confirm a downloaded component matches the pin this repo ships:
(Get-FileHash -Algorithm SHA256 -LiteralPath .\PowerShellEditorServices.zip).Hash
```

Every release cut by the **gated release pipeline** also ships a **CycloneDX SBOM**
(`powershell-lsp-<version>.cdx.json`, generated straight from those same pins, so it cannot disagree
with what the tool downloads) and a **SLSA build-provenance attestation** over the source archive.
Verify the provenance of a downloaded release artifact with the GitHub CLI:

```
gh attestation verify powershell-lsp-<version>.tar.gz --repo manderse21/claude-powershell-lsp
```

The full pinned-hash table, the SBOM / provenance details, the honest signing status (**pending --
not signed**, not independently audited), and paste-ready WDAC / AppLocker allow-list rules are all
in **[TRUST.md](./TRUST.md)**.

## Security and trust

Evaluating this plugin for a managed or locked-down Windows estate? **[TRUST.md](./TRUST.md)**
is the approve-or-deny reference: what runs locally and what never leaves the machine (no
network service, no telemetry), the **pinned + SHA-256-verified** downloads, the CycloneDX
SBOM and build-provenance attestation, the honest signing status (**pending -- not signed**,
no security audit), paste-ready WDAC / AppLocker allow-list rules, and the governance /
bus-factor posture.

Found a vulnerability? See **[SECURITY.md](./SECURITY.md)** -- report it privately via GitHub
private vulnerability reporting (never a public issue); it covers supported versions, scope,
and what to expect.

## Releasing

Releases are cut by a **maintainer-triggered, gate-validated pipeline** -- never automatically
on push or merge. The pipeline refuses to tag unless the target commit is merged to `main`,
green on every CI leg, and version-matched (`plugin.json` agrees with `marketplace.json`), then
cuts the tag itself on that validated commit and publishes a GitHub Release with
CHANGELOG-sourced notes, a CycloneDX SBOM, and a build-provenance attestation. See
[docs/RELEASING.md](docs/RELEASING.md) for how to trigger a release, what it validates, what it
produces, and the manual fallback.

## License

[GPL-3.0-or-later](https://spdx.org/licenses/GPL-3.0-or-later.html) (GPLv3). See [LICENSE](./LICENSE).

The change to GPLv3 is **forward-only**, effective from **v1.6.1**. Prior releases (v1.0 through
v1.6.0) remain under the MIT license they shipped with -- that grant is irrevocable and is not
affected by this change.

PowerShell Editor Services and PSScriptAnalyzer are **downloaded at install time** (not bundled in
this repository) and remain under their own MIT licenses (Microsoft); MIT is GPL-compatible. See
[THIRD-PARTY-LICENSES.md](./THIRD-PARTY-LICENSES.md).
