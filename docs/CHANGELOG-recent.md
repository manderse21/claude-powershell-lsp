<!-- GENERATED FILE -- DO NOT EDIT.

     Produced by scripts/gen-changelog-recent.ps1 from CHANGELOG.md, which is the release
     artifact and the only file to edit. This companion is a strict PREFIX of that file:
     the header, the versioning policy, [Unreleased], and every entry down to and including
     the ## [1.32.0] - 2026-08-19 band -- the third-most-recent MINOR line, derived at
     generation time rather than pinned. Nothing is rephrased and nothing is dropped from
     the middle; the file stops.

     It exists so the project-knowledge bundle can carry a recent changelog without carrying
     the whole one, and so CHANGELOG.md itself never has to be truncated to fit a budget
     (dispatch 000283, ruling R6). Regenerate with:

         pwsh -File scripts/gen-changelog-recent.ps1

     Verify it is current with -Check, which exits 1 when this file is stale.
-->

# Changelog

All notable changes to the `powershell-lsp` plugin are documented here.
This project adheres to [Semantic Versioning](https://semver.org/).

## Versioning

Releases follow [Semantic Versioning](https://semver.org/):

- **PATCH** (`1.1.x`) -- bug fixes and internal hardening with no user-visible
  contract change (a portability fix, a log-sweep tweak, a docs correction).
- **MINOR** (`1.x.0`) -- a new backward-compatible capability: a new `userConfig`
  knob, an added diagnostics feature, a newly CI-verified platform.
- **MAJOR** (`x.0.0`) -- a breaking contract change: removing or renaming a knob,
  rewiring the hook/registration contract, or anything that forces users to adjust
  their config or workflow.

### Pinned dependency bumps

Two external components are version-pinned. Bump either by editing a single
variable and starting a fresh session (the ensure-step re-vendors at the new pin,
keyed by a per-version marker):

| Component        | Pin variable   | File                      |
|------------------|----------------|---------------------------|
| PSES             | `$PsesTag`     | `scripts/ensure-pses.ps1` |
| PSScriptAnalyzer | `$PssaVersion` | `scripts/ensure-pssa.ps1` |

A pin bump that changes observable diagnostics behavior ships as a MINOR; a pure
security/patch re-pin with no behavior change ships as a PATCH.

## [Unreleased]
PATCH: **A one-definition test now scopes itself to the git index, not the filesystem**
(test-only; no shipped behaviour changes). `PowerShellLsp.DaemonPipeName.Tests.ps1`'s
*"the definition lives in exactly ONE place"* walked the repository root recursively. It passed
from a worktree and **failed from the repository root** -- `Expected 1, but got 2` -- because
linked worktrees are commonly checked out under the gitignored `worktrees/`, each holding its own
copy of `scripts/lib/lsp-common.ps1`.

**That second copy was never a second definition.** It is the same definition, seen twice by a scan
that was looking at a directory tree when it meant *"this repository"* -- so the test's answer
depended on the machine it ran on rather than on the code. Measured from a root with six linked
worktrees: the old scan returns **3**, the fixed scan returns **1**.

The scan now reads `git ls-files`, which excludes ignored trees by construction rather than by a
path filter somebody has to remember to extend. It carries a non-vacuity floor (the index must
return more than 30 `.ps1` files, so a failed `git` cannot fake a pass) and asserts the exclusion
it relies on. The prior implementation is kept as a **RED control** that reconstructs the nested
copy under `$TestDrive` and asserts the two scopes **disagree** -- rather than asserting a fixed
number on the real tree, which would make the control itself machine-dependent.

Found by `dispatch verify` re-running the suite from the configured `repo_path`, which is the
repository root — the one place the original scan was wrong.

PATCH: **The daemon pipe name now has one definition instead of twenty-three** (internal
hardening; no shipped behaviour changes). `Get-DaemonPipeName` in `scripts/lib/lsp-common.ps1` is
the single source, and the 23 sites across `scripts/` (6) and `tests/` (17) that built the name by
hand now call it.

**Why this was worth doing.** The pipe name is what a client and a daemon must *agree* on to find
each other at all. Twenty-three literals is twenty-three chances for a rename to reach twenty-two
of them, and the failure mode of that miss is not a red test -- it is a client that connects to
nothing and reports the daemon unreachable, which reads as an environment problem rather than as a
typo.

**The four `evidence/` sites are deliberately NOT routed and stay byte-unchanged.** They are frozen
byte-anchored release harnesses for v1.32.0 and v1.33.0; changing them would destroy the evidence
they exist to be. The guard that forbids inline construction scopes itself to `scripts/` and
`tests/` **and asserts those four are still present**, so the exemption cannot quietly become a
hole -- and that arm doubles as the in-band control proving the scanner can see what it looks for
at all.

**Behaviour is unchanged, including at the edges.** A blank session id returns the bare stem, which
is exactly what all 23 concatenations did.

MINOR: **The OTel export now reports diagnostic-shape CARDINALITY, without publishing the shapes**
(enterprise docket **P2-1**, review item 7, the capture half -- which completes the item). A sixth
metric, `powershell_lsp.diagnostics.shapes`, counts **distinct** diagnostic shapes read off the
opt-in capture log (`dogfood/diagnostics.jsonl`), split by `ruleId`, `severity` and `source`.

**It answers a question the volume counters cannot.** `diagnostics.records` says how many findings
a host produced; it cannot tell one rule firing four hundred times from four hundred distinct
problems. This says how many *different* things the analyzer found -- whether the host's diagnostic
surface is widening.

**The `hash` that identifies a shape is what the metric counts, and it never leaves.** One point
per distinct hash would emit one time series per distinct diagnostic -- unbounded cardinality, and
an event log wearing a metric's clothes. It is the same reason `ts` is off the stats allowlist. So
the count is the metric and the shapes are not; `snippet` (the offending source line, verbatim),
`message`, `file`, `line` and `col` are off the capture allowlist for the plainer reason that they
are source code and locations.

**There is still exactly ONE allowlist; it now answers per record kind.**
`Get-OtelAttributeAllowList` gained a `-Kind` that *selects a list rather than adding a door*: the
two record kinds have disjoint vocabularies, so a flat union would have silently permitted a
capture field on a stats row and the reverse -- inert only until one record gained a field named
like the other's. An unrecognized kind publishes **nothing** rather than falling back to another
kind's permissions. The stats rendering is unchanged, asserted byte-for-byte against the pre-change
payload.

**With no capture log, no shapes metric is emitted at all** -- never a zero, which would tell a
fleet dashboard this host produced no distinct diagnostics rather than that the reader was handed
no log. `-CapturePath` reads a specific log; `-Show` reports capture row and distinct-shape counts
and, held to the same boundary as the payload, never a hash.

MINOR: **`doctor -Json` now reports whether this host is exporting metrics, and where to**
(enterprise docket **P2-1**, review item 7, the doctor half). The envelope gains one field,
`otelExport`, carrying `configured` (is export active), `recognized` (did
`POWERSHELL_LSP_OTEL_ENDPOINT` parse as an absolute `http`/`https` URL) and `display` (the
collector address with **userinfo and query redacted**, `""` when export is not active).

**It is `captureMode`'s argument applied to the other fleet control.** A management plane could
already ask a host whether the diagnostics-capture control was active; it could not ask whether
that host was shipping metrics. Answering it required reading the collector's inbox and inferring
which hosts were missing -- which cannot distinguish a host that is not configured from one that
is configured and failing. Now the host answers for itself.

**The published set is an allowlist of three names, not the resolver's output with two fields
removed.** `Get-OtelEndpointReportInfo` owns that boundary as one function, for the same reason
`Get-OtelAttributeAllowList` owns what may leave about a stats row. `endpoint` is the collector
URL verbatim with credentials intact; `raw` is the environment value, and when it did not parse
nothing has inspected it and nothing can promise it holds no secret. A rule written as "drop
`endpoint` and `raw`" would keep passing the day a third credential-bearing field joined the
resolver -- so the test asserts the published key set is exactly `display,configured,recognized`,
not that the known-bad fields are absent.

**`schemaVersion` does not move.** This is the second field added under the additive-fields policy
dispatch 000282 wrote into `commands/doctor.md`, and the first to merely follow it.

PATCH: **A doctor test that could go red on host drift now judges `-RequireProven` by its own
summary** (internal hardening; no shipped behaviour changes). `PowerShellLsp.DoctorJson.Tests.ps1`
ran two live doctor probes and compared the *proven* run's exit code to the *default* run's, so a
host that moved between them -- a daemon finishing warm-up, a pinned artifact arriving -- could
turn the test red for a reason that was not a defect. Its sibling already carried a drift guard;
this one made the same assumption with none.

**Copying the sibling's skip was rejected**: that test exists to prove `-RequireProven` did not
silently drop its switch, and a blanket skip means it proves nothing under exactly the conditions
that make it interesting. The repair removes the coupling instead of tolerating it -- a *default*
run can never exit `2`, so an exit of `2` on a host with an unknown and no failure is itself proof
the switch was carried, with no reference to the other probe. Judging the proven run against its
own summary holds under drift rather than standing down, which is strictly stronger than the skip.

One predicate is shared by the live assertion and its RED control so the two cannot drift apart,
and its signature accepts a summary and an exit code and nothing else -- the repair expressed as a
type. The one genuinely unobservable case (a fully proven host, where both runs exit `0`) is
**stated rather than skipped**. RED control: the observable shape of a dropped switch -- a genuine
unknown, no failure, exit `0`. Mutating the predicate to always-true turns exactly that control red
and nothing else; the live assertion passes under the mutant, which is precisely why the control
exists.

MINOR: **Fleet telemetry can now reach an OpenTelemetry collector, metadata only** (enterprise
docket **P2-1**, review item 7, the timing half). `scripts/export-otel.ps1` renders the existing
opt-in `enableStats` log (`logs/stats.jsonl`) as OTLP/HTTP JSON metrics and POSTs them to
`POWERSHELL_LSP_OTEL_ENDPOINT`. This is a **rendering of instruments that already exist**, not a
new measurement layer: every number it publishes is one `scripts/show-stats.ps1` already prints
from the same file, computed by the same nearest-rank percentile. Five metrics ship --
`powershell_lsp.edits` (Sum, split by `ext`/`taken`/`cached`), `powershell_lsp.edit.duration`
(Gauge, p50/p95 per stage), `powershell_lsp.diagnostics.records`,
`powershell_lsp.diagnostics.corrections` and `powershell_lsp.edit.scope_trimmed`.

**Nothing runs on the edit path.** The exporter is an out-of-band reader, the same shape
`show-stats.ps1` is, so an export can never add latency to a diagnostic or a failure mode to an
edit. **Sending is opt-in twice** -- the variable must be set *and* `-Send` passed -- so
`pwsh -File scripts/export-otel.ps1` prints the exact payload and transmits nothing, which is how
an administrator sees what would leave before any of it does.

**What cannot leave is the point.** A stats row carries the **absolute path** of the edited file,
which is why `enableStats` is `false` in every profile. Attributes are built from an **allowlist**
(`ext`, `taken`, `cached`) and never by copying the row, so no path -- and no path-bearing field
added to the row later -- can reach the wire without being put on that list deliberately. A
denylist over `path` would have passed today's test and leaked the next field; the test suite
asserts the class, not the field, by putting an unknown `settingsPath` on a row and requiring it
absent. `ts` is off the list too: a per-edit timestamp as an attribute would turn a metric into an
edit-by-edit activity trace. Resource attributes are `service.name` and `service.version` only --
no hostname, no `service.instance.id`.

**An unrecognized endpoint turns export OFF**, the opposite of `POWERSHELL_LSP_CAPTURE_MODE`,
which resolves a typo to `full`. That variable may not gate the local capture channel; this one
guards a network egress, so a value that does not parse as an absolute `http`/`https` URL means
*do not send*. Credentials are never printed: userinfo and query string are redacted from every
message, including failures, and a value that failed to parse is not echoed at all.

`POWERSHELL_LSP_OTEL_ENDPOINT` lands on the **admin environment surface**, deployable by GPO or
Intune, so this MINOR adds **no** `userConfig` knob, no diagnostics status token and no
`CONTRACT.md` line -- zero 1.x freeze exposure. `scope_trimmed` is summed over **scoped rows
only**, matching `show-stats.ps1`: an unscoped row's `scopeTotal`/`scopeSurfaced` differ whenever
`perFileCap` truncated, and counting those would report cap truncation as edit-scope noise
reduction. **Still unbuilt and named as the remainder:** the capture-log `hash` half of P2-1
(diagnostic-shape cardinality), and a `doctor -Json` envelope field reporting the resolved
endpoint the way `captureMode` reports its mode.

MINOR: **An organization can now state a requirement, not only a suppression** (enterprise docket
P1-5, review item 2, the include-side payload half -- ruling **R9**). The `orgPolicy` file gains an
optional `SeverityOverrides` table beside its `ExcludeRules`, mapping rule code to severity
(`Error` / `Warning` / `Information` / `Hint`). Until now the org payload was **subtract-only**: an
organization could take a rule away and had no way to say *this one matters here*, which is exactly
the gap the enterprise review named. An override is applied at the **same final position as the
exclude drop and immediately after it**, so it carries the same guarantee -- no repo-local
`PSScriptAnalyzerSettings.psd1` and no `ruleInclude` knob can put the severity back. Exclusion
remains the stronger verb: a rule that appears in both is dropped, not re-stamped.

**No new knob and no new file**: the key lives inside the policy the existing `orgPolicy` path
already points at, is read in the **same single parse behind the same integrity gate** as
`ExcludeRules`, and reports through the same one-warning degrade. A policy with no
`SeverityOverrides` key behaves byte-for-byte as before, so every existing deployment is
unaffected. Malformed entries -- a severity name outside the vocabulary, a non-string value or key,
or a `SeverityOverrides` that is not a table -- are skipped rather than guessed at, because an
override naming a level nothing can rank looks like enforcement while enforcing nothing.

**The boundary is documented and asserted by a test, not merely described**: an override re-stamps
a finding already on the surface and cannot resurrect one the local `severityThreshold` dropped
before the client saw it. At the shipped default (`Hint`) nothing is threshold-dropped and
overrides are fully effective. The signing half of Policy v2 remains unbuilt and waits on a trust
root `docs/roadmap-ii/THREAT-MODEL.md` T4.1 says the mechanism does not have.

PATCH: **`docs/SUPPORT-POLICY.md` states the boundary of the compatibility leg**, and P1-3 is
closed at registration-only. Ruled 2026-09-08 (**R14**, recorded verbatim in
`docs/decision-ledger.md`): **no CI model credential.** The advisory `claude-code-compat` leg
proves that two pinned real clients accept and register this plugin, asserted against the client's
own component inventory; it does **not** prove that a diagnostic surfaces to a user, because that
needs a live agent turn and therefore a model credential in CI. The support policy now says both
halves of that plainly, with the reasoning: a repository secret is reachable by every workflow in a
repository that publishes attested artifacts, a live agent turn is nondeterministic and an advisory
leg that flakes teaches readers to ignore advisory legs, and it bills per pull request forever. If
that end-to-end proof is ever wanted it is an attended or scheduled check **outside** the
publishing repository, never a PR gate. **No `claudeCodeCompatibility` declaration is written** --
the declaration is the output of certification, and what the matrix proves is registration. The
same section also records that two CI legs (`container-pwsh`, `claude-code-compat`) are
deliberately absent from the supported-hosts table, because neither carries a support promise.

PATCH: **An advisory CI leg proves a real Claude Code client registers this plugin** (enterprise
docket P1-3, review item 4, the registration half). `claude-code-compat` installs two PINNED
client versions -- 2.1.263 (Current) and 2.1.261 (Current-1) -- registers this repository as a
local marketplace, installs the plugin from it, and asserts against the client's OWN component
inventory that all three hooks, the LSP server and every shipped command are registered. Reading
our own manifest back to ourselves would prove only that the file we wrote is the file we wrote.
The expected command set is **derived from `commands/*.md`**, so adding a command extends the
assertion with no edit to it. **ADVISORY, not required**, and that is ruling R-G rather than a
preference -- a required leg that cannot obtain an older client blocks every release -- so the job
carries `continue-on-error: true`. It is its **own job with its own name**: the `pester` job is
named `${{ matrix.label }}`, so a new dimension there would rename four existing check contexts
and silently remove required checks. The five existing identities are untouched.

**Two things it deliberately does not do.** It writes no `claudeCodeCompatibility` manifest block:
the docket requires that declaration be written from what the matrix *proved*, and this leg proves
registration only -- asserting that a diagnostic *surfaces* needs a live agent turn and therefore a
credential this repository does not hold. And it does not resolve `latest` at run time, because a
leg pinned to a moving target is not a pin; the runner script refuses a dist-tag by name and
verifies that the client which actually installed reports the version it was asked for, so a
compatibility claim is never attributed to a version that was not the one exercised.

Recorded because it corrects a docket premise: the effort line said P1-3 was "dominated by
obtaining and pinning two client versions in CI". Measured on 2026-09-08, that is not the cost --
npm carries exact versions and installing one is a single line. The real constraint is credentialed
execution, which is why only half of P1-3 is built here and the other half is named.

Also transcribed 000286's per-family `Unguardable` decision into `tests/control-map-claims.psd1`'s
own comment block, where the list lives, so a future dispatch meets the reasoning rather than
having to find the outbox. All four verdicts are NO and none is softened; the held-PR family keeps
its actionable shape (an `audit-release-bodies.ps1`-style maintainer-run sweep, never a CI gate).

MINOR: **A first-party semantic query surface** (enterprise docket P1-2, review items 9 and 10).
`scripts/lsp-query.ps1 <op> <file> <line> <col>` asks the warm per-session daemon a POSITION
question -- `definition`, `references`, `hover` -- and returns PowerShell Editor Services' own
answer as JSON. The daemon has spoken LSP to PSES since the beginning and nothing in this
repository was asking it anything but "what is wrong with this file"; these three operations are
requests PSES already serves. The path has **no Claude Code client in it**, which is the point:
the standing GATED arc is on *serving through the client*, and this is a script the agent runs
against the plugin's own daemon. **Freeze exposure: ZERO on both frozen surfaces** -- a command
entry point is neither one of `CONTRACT.md`'s twenty `userConfig` knob names nor one of its
diagnostics status tokens, and `-Op` is a CLI parameter exactly as `-Format` is on `lsp-scan.ps1`.
Positions are **1-based on the wire** -- what every editor, stack trace and diagnostics record this
plugin emits reports -- and are converted to LSP's 0-based positions in exactly one place. That
conversion is the whole of the slice's risk and it carries the RED control the docket named: a
planner that forwards the request unchanged returns a well-formed, confident answer about the
previous character, and is asserted to fail on every op.

While building it, re-deriving the request-writing sites at the tip found **six, not three**, and
the handshake census that called itself "a census, not a sample" was a hard-coded list of three.
The two it had never named -- `doctor.ps1`'s ping probe and `session-end.ps1`'s shutdown -- write a
bare JSON literal and announce nothing; neither is broken, because ABSENT MEANS 1 is the
handshake's own rule, but the guard could not have noticed if one had started carrying a field that
needed a version to interpret. The census now **derives** its site set from the AST and asserts a
partition: every site either announces both keys or is a bare literal carrying nothing but an
`action`, with the exemption keyed on the literal's own text rather than on a file name. Measured
rather than argued: with the new fourth site's handshake deleted, the prior guard **passes** and
the derived one fails, naming the site.

MINOR: **The query surface answers `documentSymbol` and `workspaceSymbol` too**, completing docket
P1-2's named remainder. Neither op takes a position, so neither is a variation on the three that
shipped: `documentSymbol` names a file and no position, `workspaceSymbol` names a query string and
no file. They are **not** forced into the position shape. Inventing a position for an op that has
none would send PSES a well-formed request about a place the caller never named and get back a
confident answer to a question nobody asked.

The planner now reads **one spec table** that carries each op's method *and* its `kind` --
`position`, `document` or `query` -- and `Get-QueryOps` derives the advertised vocabulary from it
rather than restating it beside it (Hub Rule 18). The daemon's `queryOps` capability and the
client's `-Op` set follow for free, and position validation applies to the position ops only. One
consequence worth naming: the three original ops were all lowercase, so normalising an op with
`ToLowerInvariant` was free; it is not free any more, and `Resolve-QueryOp` canonicalises against
the spec instead -- lowercasing `documentSymbol` would lose the op entirely. `-File`, `-Line` and
`-Col` are no longer `Mandatory` on the client, because they do not apply to every op; `-Op` still
is, and existing positional calls are unchanged.

**A second RED control**, because the first one cannot reach these arms. The pass-through mutant
controls the 1-based-to-0-based conversion, which an op carrying no position never performs -- so
this slice adds a **uniform-position** mutant that pins every op's kind to `position`, which is
exactly the shape this planner had before the symbol ops existed. It is proved to have landed, it
is asserted to send a position where the shipped planner sends none and to *refuse* a
`workspaceSymbol` the shipped planner serves, and it is asserted to leave the three position ops
alone so it controls what it claims to. The kinds are asserted to **partition** the vocabulary --
every op in exactly one arm, no arm empty -- and both mutants' op loops are derived from that
partition rather than from a hard-coded list, which is the lesson the handshake census taught one
slice earlier.

**And a fatal defect in the client, found by building the round-trip test that was missing.**
`scripts/lsp-query.ps1` assigned the daemon's response to `$line` -- which, because PowerShell
variable names are **case-insensitive**, is the same variable as its own `[int] $Line` parameter.
A typed variable coerces on every assignment, so the response JSON threw *"Cannot convert value
... to type System.Int32"* before a single byte was parsed. **Every query exited 4 and no query
ever returned a result.** It shipped green because every test in the file was about the pure
planner and **nothing exercised the round trip**. It is fixed here (`$respLine`), and it **never
reached a release** -- the whole query surface is still under `[Unreleased]`, so no user has been
affected.

The fix carries the tests whose absence allowed it. A **round-trip suite** stands up a minimal
named-pipe server answering one canned response and drives the real client against it for one op
of **each kind**, plus the `-Text` rendering and a daemon refusal; and a **collision assertion**
derives the typed-parameter set and the assigned-variable set from the AST and asserts they do not
intersect, so a future typed parameter is guarded for free. The RED control is the **prior
implementation read from git by SHA** -- 000287's own file -- and it is asserted to carry the
collision on the exact variable. Reintroducing the defect turns all six of those tests red and
nothing else, measured.

Three harness traps were hit and are recorded in the test's own comments, because each one produced
a *passing-looking* failure: probing readiness with `Test-Path` on `\\.\pipe\<name>` **opens** the
pipe and consumes the server's single instance, so the client that follows finds nothing to connect
to; a redirected child's stdout stays buffered while it blocks, so a `READY` line never arrives and
the signal must be a marker **file**; and PowerShell **strips double quotes** from native-process
arguments, so JSON handed over a command line reaches the child unparseable and must go through a
file.

PATCH: **`docs/whitepaper.md` is r3, retracting a claim the code outgrew.** In three body places
(sections 4, 6, 10) r2 said one acquisition route was **not** governed by the project SHA-256 pin
-- the PSScriptAnalyzer Gallery fallback, described as resting on the Gallery's publisher/catalog
integrity and reported by `/doctor` *"rather than as a pinned source"*. That was true when r2 was
written and stopped being true at **PR 204**, which rebuilt the fallback as a pinned layer: it
stages a `.nupkg` via `Save-Package` and hands it to the same `Test-PinnedFileHash` gate every
other route passes, which "runs on the `.nupkg` REGARDLESS of source". So the pin governs every
acquisition path with no exception, and `gallery-fallback` survives as a **provenance** label
rather than a trust distinction. The superseded sentence is recorded in place as a dated
correction rather than silently replaced, and r2's revision note is left intact as history. r3
corrects that one claim and deliberately does **not** re-finalize the paper against a newer
release: every other `[V]` citation remains one verified for v1.32.0, and advancing the version
header without re-deriving them would acquire exactly the class of false claim this removes.

MINOR: **A fifth CI leg runs the whole suite inside the official PowerShell container**
(enterprise docket P2-3, the open half). `container-pwsh` is its OWN job with its OWN name, not a
fifth entry in the existing matrix: that job is named `${{ matrix.label }}`, so adding a dimension
would have re-keyed the four existing legs and renamed their check contexts, which silently removes
a required check. The four identities -- `windows-pwsh`, `windows-powershell`, `ubuntu-pwsh`,
`macos-pwsh` -- are untouched. The leg runs non-root, with no TTY and no profile, with Pester
installed in-job, and pins the image **by digest**: `powershell:latest` is 7.4.2, and the
PSScriptAnalyzer 1.25.0 pin this repository carries refuses to import below 7.4.6, so on `latest`
the analyzer never loads and the corpus tier silently returns EMPTY findings (measured: 41 corpus
and 13 integration failures, every one an artefact of the image). On `7.5-ubuntu-24.04` the same
tree runs those tiers 266/0 and 66/0. The leg also asserts the doctor's **census** rather than
gating on `-RequireProven`, which cannot pass in a container and no change here can make pass: six
of its eight unknowns are unknowable outside a live plugin subprocess, one reports the shipped
offline default, and one is unknown by design while `ps_host` is default. Instead the leg pins the
KNOWN posture -- zero failures, check 1 naming the REAL in-process version, the exact unknown set,
and `-RequireProven` exiting 2 rather than 0 or 1. Restoring the pre-fix probe turns it red on
seven counts, including check 1 reporting `found pwsh 0.0.0.0` on a 7.5.0 host, which is the
defect that blocked this slice. One test needed adjusting for the container and no more: the
native-serve probe's *report-only* "mutated nothing in the repo tree" snapshot shells out to `git`,
which the image does not have, and an unguarded call took the whole `Describe` down with it. It is
now guarded, and the assertion that consumes the snapshot **skips** rather than comparing an absent
porcelain to an absent porcelain -- which would have passed vacuously and reported a mutation check
that never ran. Every host that has `git`, which is all four original legs and every dev clone,
still runs it. Two further constraints came from CI rather than from any local run, and both are
properties of the LEG rather than of the suite: the container runs with `--init`, because otherwise
`pwsh` is PID 1 and a control asserting that an unrelated process is *not* excluded finds its
synthetic foreign pid legitimately inside a subtree rooted at PID 1; and `HOME` sits on a tmpfs
**outside** the mounted workspace, because the CurrentUser Pester install otherwise lands its own
source inside the repository and the repo-wide scans then walk the harness that is scanning them.
No runtime script changed and no existing gate moved.

PATCH: **`audit-release-bodies.ps1` now PINS the repository it sweeps instead of letting `gh`
resolve it.** The repo-identity assertion added previously fired only on an explicit `-Repo`; with
`-Repo` omitted the script passed no `--repo` at all, on the recorded premise that "`gh` resolves
the same remote". Measured at `gh` 2.95.0, it does not: `GH_REPO` overrides the git remote for both
commands the sweep issues, so exporting `GH_REPO` made the sweep read a foreign repository's
published bodies and compare them against THIS repository's `CHANGELOG.md` -- reported in the
vocabulary of a currency finding, with nothing naming which repository was read. The obvious fix
would not have closed it: `gh repo view --json nameWithOwner` reports the git remote and *ignores*
`GH_REPO`, so a guard built on "ask `gh` what it resolved" would have agreed with itself and passed
while the sweep read someone else's releases. The fix is structural rather than another guard --
`scripts/lib/audit-repo-target.ps1` decides the target once and it is passed as `--repo` on every
call, which beats `GH_REPO` (measured) and closes the `gh repo set-default` door with it, at
**zero** added subprocesses. An unpinnable target is now refused rather than guessed, and a
`GH_REPO` that disagrees with the checkout is refused by name unless `-AllowForeignRepo` is given.
No user-visible contract changed.

PATCH: **`docs/control-map.html` now has a real currency guard, and the map is corrected to rev 4.**
The map ships as a release ASSET and had no automated guard of any kind -- nothing under `tests/`,
`scripts/` or `release/` referenced it, and the release workflow's only mention was a
`[[ -f ... ]]` PRESENCE test. `tests/control-map-claims.psd1` plus
`tests/PowerShellLsp.ControlMapClaims.Tests.ps1` assert the map's CLAIMS against sources derived
from this repository's own disk: whether T5.1 is still called unreleased, whether the SLO tally
claims "all six met" while `PROGRAM.md` records an open miss, whether any version is called
"in prep" that `CHANGELOG.md` already carries a release for, and whether the stamp names the newest
released version. **This is deliberately not a date comparison:** `RELEASING.md` step 5 compares
the map's own stamp against the release date, so stamping the map satisfies it whether or not a
single claim was re-derived -- the refresh disarms the only detector. The RED control is **rev 2
restored from git history**, which must fail on both claims that were false at the v1.34.0 release.
Claims that can only be derived from outside this repository are listed in the registry as
**unguardable-by-design** rather than guarded weakly. The new guard immediately found two live
false claims in **rev 3** -- the revision produced by the last currency refresh -- which are fixed
here as rev 4: v1.34.0 was described as "in release prep" after it had published, and the header
stamp still read "released v1.33.0".

PATCH: **the doctor no longer reports `pwsh 0.0.0.0` on Linux and macOS.** Check 1 read the
executable's file-version *resource*, which is a Windows-only artifact -- on Linux and macOS
`pwsh` has none, .NET reports `0.0.0.0`, and the doctor answered *"found pwsh 0.0.0.0 but
PowerShell 7+ is required"* on a host running **7.4.2**. It now prefers `$PSVersionTable.PSVersion`
when the doctor is itself running under PowerShell 7+ **and** the `pwsh` it resolved on PATH is
that same executable, so a *different* `pwsh` install is never reported at this process's version.
A `0.0.0.0` with no in-process answer degrades to **UNKNOWN**, which check 1 already reports
honestly, rather than to a fabricated `fail`: a zero version is the absence of a version, not a
version below the 7.0 floor. Windows behaviour is unchanged, and a genuinely old `pwsh` is still
failed. No `userConfig` key, diagnostics status token or `CONTRACT.md` line is touched.

## [1.34.0] - 2026-09-07
MINOR: **the doctor now answers machine-readably, and will tell you when it cannot prove an
answer.** `doctor -Json` is a third rendering beside the fix-list and `-Summary`, carrying a
four-value `status` vocabulary over the same checks, and the new opt-in **`-RequireProven`** exits
**2** when nothing failed but something is merely UNKNOWN -- so "everything was actually verified"
stops being indistinguishable from "nothing complained". Read the **Security** entries too: the
diagnostics capture can now be told to record a finding **without the source line or the path**
(`POWERSHELL_LSP_CAPTURE_MODE=metadata`, an environment variable rather than a knob, so a fleet can
set it by GPO), and the **last dependency-acquisition route the SHA-256 pin did not gate is now
gated and fails closed**. The daemon IPC also gained a **protocol version and capabilities
handshake**, so a client and a warm daemon from different installs can discover a mismatch instead
of misbehaving; absent means 1, which keeps it additive. **No `userConfig` key is added, removed,
renamed or re-defaulted, no diagnostics status token changed, and no line of `CONTRACT.md` moved** --
the 1.x freeze holds. This is a MINOR because it adds capability, not because it changes any
promise.

**This release also carries the POSIX containment fix written up below under `[1.33.1]`, and
that section is part of these release notes.** `1.33.1` was cut on `main` and superseded
before it was ever tagged, so it has no release of its own and never will -- it is a skipped,
never-published version number. Its change is nevertheless in **this** artifact: on Linux and
macOS the data root, its temp fallback, the daemon's unix-socket endpoint and the files the
shared JSONL writers create are now created `0700` (directories) and `0600` (files) at
creation time, instead of inheriting `755` from the ambient umask. Windows is byte-identical.

The change is commit **`a89fe0c`** (*fix(security): contain every POSIX object the plugin
creates to its owner*), which is in `v1.33.0..v1.34.0`. It is named here rather than left to
the CHANGELOG alone so that a reader of the published release can trace the fix to a commit
without knowing that `1.33.1` was skipped: **a security change that ships in an artifact must
be readable from that artifact's own notes.**

### Added

**A `captureMode` field in the `doctor -Json` envelope** (dispatch 000282, ruling R19 of
2026-09-06).

A control the fleet cannot verify is half a control. The reader the capture mode above exists for
is a management plane, and a management plane learns whether a control is active by asking a
machine-readable surface -- so the envelope now carries `captureMode` with the resolved mode, the
raw environment value and a `recognized` flag. All three, because an unrecognized value resolves to
`full` rather than gating the channel: without `raw` and `recognized`, a host whose deployed value
is misspelled would be indistinguishable from one deliberately left at the default.

It is **additive**, and `schemaVersion` stays 1. `commands/doctor.md` stated no policy on whether an
additive field bumps the schema, so this dispatch wrote one -- additive fields do not bump,
removals and renames do -- and recorded that it established it. No check's logic, the four-value
status vocabulary, the summary counts and the exit code are all unchanged, and both human
renderings are byte-identical to the previous build.

**A protocol version and capabilities handshake on the daemon IPC** (dispatch 000282, ruling R15 of
2026-09-06 = `ENTERPRISE-PROGRAM-DOCKET` P1-4).

The IPC between the client and the warm daemon has never carried a version, so a client and a
daemon from different installs could only discover a mismatch by misbehaving. Every request now
carries `protocolVersion` and a `capabilities` object, and every response carries the **daemon's
own** version and capabilities.

Two rules make it additive rather than breaking. **Absent means 1** -- a request with no
`protocolVersion` is version 1, which is precisely the protocol as it stood before anyone announced
one, so every existing client keeps working and the response it receives is its old response plus a
suffix. **An unknown version is answered, not refused** -- a client claiming a version the daemon
does not know is processed as version 1 and told the daemon's own version, because refusing would
make the first version bump a flag day, which is the failure announcing a version exists to prevent.

The daemon's advertised capabilities are derived from what it actually serves -- the request loop's
own action set and the request fields it really reads -- and a test asserts that action list against
the switch's clause labels read from the AST, so an action added to the loop without being
advertised fails CI rather than shipping a lie.

The docket named one request-building site; a census found **three** (the client's `diagnostics` and
`format` paths, and the doctor's check-11 probe) and all three announce the handshake, because one
present on one path and absent on another is not a handshake. On the daemon side all five response
paths were routed through a single write seam for the same reason.

**Zero freeze exposure**: the daemon IPC is not one of the two enumerable surfaces `CONTRACT.md`
freezes, which a test confirms rather than assumes. No `userConfig` key, no diagnostics status
token, no line of `CONTRACT.md`.

This lands before the query surface (P1-2) deliberately: the handshake costs a few hours now and
materially more once a second consumer exists.

**`doctor -Json`, a status vocabulary, and an opt-in `-RequireProven` gate** (dispatch 000279,
ruling R11 of 2026-09-05 = `ENTERPRISE-PROGRAM-DOCKET` R-D option (a), folding
`DOCTOR-SURFACE-DOCKET` slices S1 and S2 unchanged).

**The gap.** `exit 0` from the doctor never meant "it is working" -- it meant "nothing FAILED",
and in exactly the headless, CI and container environments where that question matters, the checks
that would prove it *is* working do not fail, they go UNKNOWN. The information that separates a
healthy install from a container where nothing works was printed correctly and existed **only as
English prose**, so a CI job could not assert on it without grepping human sentences. Meanwhile
`lsp-scan.ps1` -- whose job is finding defects -- has emitted SARIF by default for releases, while
the one surface whose whole job is proving the plugin works was the one a machine could not read.

**`-Json`** is a third rendering beside the default fix-list and `-Summary`, over the same
`Invoke-Doctor` seam: the checks that run, their statuses and the exit code are identical to a
normal run, and only the presentation differs. The envelope carries `schemaVersion`, the derived
`status`, the resolved plugin / pwsh / PSES / PSSA versions, the provenance floor, the summary
counts and the per-check array (`status`, `component`, `detail`, `remediation`).

**The `status` vocabulary** is `HEALTHY` / `DEGRADED` / `UNHEALTHY` / `UNPROVEN`, derived from the
existing per-check `pass` / `fail` / `unknown` results and from nothing else -- no check's own
logic changed. Most severe applicable value wins: `UNHEALTHY` when anything failed, `DEGRADED`
when something is UNKNOWN and something was established, `UNPROVEN` when nothing was established
at all, `HEALTHY` when everything passed. A render of zero checks reads `UNPROVEN`, never
`HEALTHY`. **This is a doctor envelope field, not a diagnostics status token** -- `CONTRACT.md`
freezes the *diagnostics* token set, the words a finding wears, and none of these four is one of
them.

**`-RequireProven`** is an opt-in second predicate beside the existing failure count: it exits
**2** when nothing failed but at least one check is UNKNOWN, so "everything was actually
established" becomes an exit code instead of a paragraph. Exit 2 rather than 1 keeps 1 meaning
"something FAILED" for every existing caller and matches `lsp-scan.ps1 -FailOn`'s convention; a run
with both a fail and an unknown exits 1. **Without the switch the exit code and both human
renderings are byte-identical to before** -- proven against the merge base, not asserted.

No `userConfig` key, no diagnostics status token, no line of `CONTRACT.md`. Both switches are CLI
parameters, the same category `CONTRACT.md` already records for `lsp-scan.ps1 -Format`.

### Security

**The diagnostics capture can now record a diagnostic without recording the source line or the
path it came from** (dispatch 000282, ruling R8 of 2026-09-05 = `ENTERPRISE-PROGRAM-DOCKET` R-A
option (a)).

**The gap.** Every surfaced diagnostic is teed to a local append-only log carrying the absolute
path of the edited file and the offending source line, verbatim, and nothing gated that.
`THREAT-MODEL.md` accepts it as **T6.1** on stated reasoning: the log never leaves the machine, so
its exposure is to *a local user who already has the source files it quotes*. That reasoning is
sound for the reader it names and **does not reach a management plane** -- an EDR, backup,
eDiscovery or DLP agent reads the log without being the person at the keyboard, and copies what it
reads off the host. The acceptance mis-scoped the reader set rather than mis-stating the exposure.

**`POWERSHELL_LSP_CAPTURE_MODE`** takes `full` (the unchanged default), `metadata` -- `file`
reduced to a basename, `snippet` and `message` not written -- or `off`, which writes nothing and
creates no log directory. `message` is dropped rather than kept because PSScriptAnalyzer quotes
identifiers out of the source into it, which was measured on the pinned 1.25.0 rather than assumed.

**`metadata` costs the analysis nothing, and that is the reason this shape was buildable.** The
rule-curation lane derives from `ruleId` + `hash`, and `hash` is computed from the offending line
in every mode: the read is kept and only the write is suppressed, so the same finding hashes
identically in either mode and a log that changes mode mid-life still reads as one corpus. The
suite proves that equality against the hash of the real source line, so an implementation that
dropped the read to save the write could not pass.

**It is an environment variable, not a knob**, which is what makes it deployable to a fleet by GPO
or Intune -- the reader this control exists for -- and what keeps it off the frozen surface. An
unset, empty or unrecognized value resolves to `full`, following
`POWERSHELL_LSP_CAPTURE_ROTATE_BYTES`: nothing about this variable may become a gate on the
diagnostics surface. A typo is surfaced instead by the new `captureMode` field in the `doctor
-Json` envelope, which reports the resolved mode, the raw value and whether it was recognized, so a
fleet reader can confirm the control is live on a host without reading the log it is avoiding.

`THREAT-MODEL.md` T6.1 is **amended, not withdrawn**: the local-reader acceptance stands as
written, and the management-plane reader is recorded beside it with the mode that answers it.

No `userConfig` key, no diagnostics status token, no line of `CONTRACT.md`.

**The last dependency-acquisition route the SHA-256 pin did not gate is now gated, and fails
closed** (dispatch 000279, ruling R10 of 2026-09-05 = `ENTERPRISE-PROGRAM-DOCKET` R-C option
(a)).

**The gap.** `scripts/ensure-pssa.ps1` vendors PSScriptAnalyzer through several acquisition
layers -- internal mirror, pre-staged bundle, pinned-`.nupkg` cache, direct download -- and
every one of them passed a single `Test-PinnedFileHash` gate and failed closed on a mismatch.
One did not. When the direct download could not complete (offline, proxy, a transient Gallery
403) the script fell back to `Save-Module`, which leaves an **extracted module tree and no
`.nupkg`** -- and the pin is a digest *of the `.nupkg`*, so it could not be computed from what
that route produced. Those bytes were installed on the PowerShell Gallery's own
publisher/catalog integrity alone. The code said so in its own comment, and named closing it as
its own dispatch.

**The fix.** The fallback now acquires the package with `Save-Package` over the NuGet provider,
which retrieves the `.nupkg` itself, and hands those bytes to the **same single gate** every
other layer feeds. A mismatch is refused exactly as a tampered mirror artifact is: nothing is
expanded, nothing is installed, no install marker is written, and the failure banner names the
`gallery-fallback` layer. There is now **no acquisition route in either `ensure-*` script whose
bytes the pin does not verify**, and none after the fail-closed exit at all. `ensure-pses.ps1`
needed no change and did not get one: it has never had a fallback -- one layered acquisition,
one gate, one fail-closed throw.

**What this costs, deliberately.** A fallback whose bytes cannot be verified no longer installs.
That is the point of failing closed, and the session still degrades honestly -- the analyzer
reports `unavailable` and editing keeps working.

**Reported provenance is unchanged in shape and more honest in content.** `/doctor` still names
the `gallery-fallback` layer, so an operator can still tell which transport supplied an install.
Its note inverted with the gate and kept the case it must not lose: a marker records the *layer*
and never the build that wrote it, so a `gallery-fallback` marker left by an install predating
this gate still describes bytes the pin did not verify, and the check says so.

No `userConfig` key, no diagnostics status token, no line of `CONTRACT.md`.

## [1.33.1] - 2026-09-05
> Cut on `main` and superseded before tagging -- a skipped, never-published number.
PATCH: **every filesystem object the plugin creates on Linux and macOS is now created
owner-only.** The data root, its temp fallback, the daemon's unix-socket endpoint and the
files the shared JSONL writers create all landed at `755` under the ambient umask -- readable
by every other local account on the host, and on Linux contained by nothing above them either.
They are now created at `0700` (directories) and `0600` (files) at creation time, in one shared
helper. **Windows is byte-identical**: the mode work short-circuits before it starts, the
creation call is the one that always ran, and the suite asserts the ACL is unchanged. This is a
default, not a knob -- **no `userConfig` key is added, removed, renamed or re-defaulted, no
status token changed, and no line of `CONTRACT.md` moved**, which is why this cut is a PATCH.

### Security

**Everything the plugin creates on Linux and macOS was world-readable, and is not any more**
(threat-model findings **T5.1** and **T6.2**, POSIX arms; dispatch 000277, ruling R4 of
2026-09-05). Windows is unaffected and unchanged.

**The exposure.** Both rows had carried their POSIX arms as *unmeasured* -- the register said so in
its own words, refusing to write platform convention into the table as if it had been observed.
Dispatch 000276 took the measurement on the two POSIX CI legs (run `33949910984`, headSha
`7fbe9ba`), and both arms came back exposed on both platforms:

| Object | ubuntu-pwsh | macos-pwsh |
|---|---|---|
| data-root temp fallback directory | `755` (`/tmp/powershell-lsp-data`) | `755` |
| daemon pipe unix-socket endpoint | `755` (`/tmp/CoreFxPipe_powershell-lsp-<sid>`) | `755` |
| containing temp directory | `/tmp` at `1777` -- world-writable, no containment | per-user temp at `700` |

`755` is `exposed-beyond-user`: any other local account could read the capture log, the stats
log, the daemon logs and the session state, and could reach the socket file. On Linux nothing
above them contained them either. macOS was contained only by where its per-user temp happens to
live, not by anything this plugin did.

`CurrentUserOnly` -- the v1.33.0 fix for the Windows arm of T5.1 -- did not cover this. Off-Windows
.NET enforces it at accept time on the connecting peer's credentials; it does not narrow the socket
file's mode, which lands at `0777` masked by the ambient umask (`0022` on both runners).

**The fix.** Every filesystem object the plugin creates on a POSIX host is now created owner-only:
**`0700` for directories**, and **`0600` for the socket endpoint and for the files the shared
JSONL writers create** (the diagnostic capture log, `stats.jsonl`, the per-rule lifecycle log, and
dogfood annotations). This is a default, not a knob: **no `userConfig` key, no status token, and no
line of `CONTRACT.md` changed.** Containment happens at creation, in one shared helper
(`New-ContainedDirectory` / `Set-OwnerOnlyMode` in `scripts/lib/lsp-common.ps1`), used at all 24
runtime creation sites.

**Measured after the fix**, on this change's own CI run `33979971327` (head `dee89b5`, all four
legs green), by the same record-only measurement step that took the before reading:

| Object | ubuntu-pwsh | macos-pwsh |
|---|---|---|
| data-root temp fallback directory | `755` -> **`700`** | `755` -> **`700`** |
| daemon pipe unix-socket endpoint | `755` -> **`600`** | `755` -> **`600`** |

Both arms now read *user-only -- no group or other access*.

**What is deliberately still permissive, and why.** Only segments the plugin itself creates are
contained. `/tmp` at `1777` on Linux is the platform's, and a data root you point
`CLAUDE_PLUGIN_DATA` at is yours; re-moding either would be this plugin reaching outside its own
objects. Text logs written by the per-script `Write-Log` helpers keep the ambient file mode and are
contained by their `0700` parent directory rather than by their own bits. The socket is contained
on the statement after the constructor binds it, so a window exists in which it carries the umask
default; `CurrentUserOnly` covers that window by rejecting a foreign peer's credentials, which is
why the file mode is defence in depth and not the only thing standing there.

**Windows is byte-identical.** The mode work is short-circuited before it starts on Windows, the
creation call is the one that always ran, and the suite asserts that a directory created through
the new helper carries the same ACL as one created the prior way in the same parent.

## [1.33.0] - 2026-08-22
MINOR: **`doctor` and `status` now answer "which version is actually running?"** -- the report
reconciles the tree's version against the live daemon's own stamp instead of naming the tree and
warning you the number may be wrong. Read the **Security** entry first, though: **the daemon's
diagnostics pipe is now restricted to the invoking user**, closing a local read surface that every
release up to and including v1.32.0 shipped. Two capture-log defects close alongside it -- the log
**leaves the read-only plugin tree** for `CLAUDE_PLUGIN_DATA`, where it also stops fragmenting across
upgrades, and it is **size-bounded** by the sweep that already existed. The **correctness corpus
publishes as a commons under Apache-2.0**, with a consumer-facing page and reproduction steps, and
the project's white paper plus the raw v1.32.0 evidence bundle now ship in the tree. **No
`userConfig` knob is added, removed, renamed or re-defaulted**, and no status token changed.

### Security

**The daemon's diagnostics pipe was readable by every local user, and is not any more**
(threat-model finding **T5.1**, dispatch 000269). The row had stood as *unknown* since the threat
model was written -- not because the risk had been judged low, but because nobody had measured it.
This finding is why this release was cut when it was.

**The exposure.** The daemon created its named pipe with no explicit `PipeSecurity` and no
`CurrentUserOnly`, so the pipe took the OS default DACL. Measured 2026-08-21 on Windows 11
10.0.26200 / pwsh 7.6.5 by reading the kernel object's security descriptor off the live pipe handle
(`GetSecurityInfo`, `SE_KERNEL_OBJECT`), the shipped pipe read:

```
D:(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;<user SID>)(A;;FR;;;WD)(A;;FR;;;AN)
```

`WD` is **Everyone** and `AN` is **Anonymous**, each granted `FILE_GENERIC_READ`. What crosses that
pipe is diagnostics -- **absolute paths and verbatim source lines from the file being edited** --
so any other principal able to run code on that host could read them. This is **local information
disclosure**: the daemon makes no network connection and the pipe is not reachable off the machine.
It is correspondingly low-consequence on a single-user workstation, and real on the hosts this
project explicitly targets -- **multi-user machines, RDP and terminal servers, and shared CI
runners**.

**Affected versions: every release up to and including v1.32.0.** All 44 tagged releases from v1.1.0
create the pipe server with no `PipeSecurity` and no `CurrentUserOnly`. The finding and its remedy
have been public in [`docs/roadmap-ii/THREAT-MODEL.md`](docs/roadmap-ii/THREAT-MODEL.md) on `main`
since 2026-08-22 while the released artifact still carried the permissive DACL; this release closes
that gap.

**The fix.** The server stream now sets `PipeOptions.CurrentUserOnly`, so the pipe is restricted to
the invoking user: the DACL becomes `D:(A;;0x1f019f;;;<user SID>)`, and no other principal appears
in it. The option is resolved by **name at runtime**, not written as a compile-time enum literal:
`CurrentUserOnly` arrived with .NET Core 3.0 and does not exist under Windows PowerShell 5.1, where
a literal would have thrown at daemon start. On such a host the shipped options are used unchanged,
**so a daemon running under Windows PowerShell 5.1 does not get the restriction** -- the guard is on
runtime capability, not on platform name. Client constructions are untouched, and the pipe's
single-instance property -- which the busy-versus-unreachable discriminator depends on -- is
unchanged.

**What was measured, and what was not.** The before and after DACLs above were measured on
**Windows**. The **POSIX arm is unmeasured.** Off-Windows, .NET backs the pipe with a unix domain
socket file and is documented to narrow that file's permissions to the owner, but this project has
not measured it, and an expectation that has not been measured is not a result. Treat the exposure on
Linux and macOS as **unknown**, not as fixed.

### The correctness corpus is a commons: published under Apache-2.0, reproducible from a clean clone

**Documentation and a licensing statement** (dispatch 000251). **PATCH-class by SemVer**: no API,
knob, or behavior change, and every corpus file is byte-identical -- `git diff` over the audited
surface reports no change of any kind.

**The corpus publishes under the project license, Apache-2.0** -- one license across the
repository, no second regime for the fixtures, no per-file headers. This closes the last thing
holding the Arc B corpus-commons gate: the provenance audit (dispatch 000222) had already
established that all 137 files in the audited surface are authored in this repository with zero
external rightsholders, so the relicense (dispatch 000247) was the only remaining input. You can
now vendor cases into a differently-licensed test suite of your own.

New [`docs/corpus.md`](docs/corpus.md) is the consumer-facing page: what the corpus is, where every
file came from, the derivation invariant (expected findings are **never** hand-authored or
model-authored -- they are snapshots of what the real tool emitted), how the false-positive and
true-positive rates are defined, **the exact steps to reproduce those numbers from a clean clone**,
a citation form, and what the corpus deliberately does *not* attest. The AI co-authorship of 21 of
the 137 files is disclosed there rather than left for a consumer to discover.

`README.md` gains the pointer and a link-map row, `TRUST.md` gains an honest-limits entry drawing
the line between what the corpus attests (diagnostics) and what it does not (security), and
`ROADMAP.md` plus `docs/roadmap-ii/PROGRAM.md` record the arc as un-gated.

**Nothing was published externally.** No announcement, no submission to any list or benchmark site,
no new repository -- that is a maintainer action and remains one. Do not infer submission state
from these pages.

The provenance audit's per-file `GPL-3.0-or-later` License column is **deliberately preserved, not
rewritten**: it records what an instrument observed on a dated tree, and a dated note now heads the
document pointing forward to the current license. Historical records stay true.

PATCH: the first hardening slice chartered off `docs/roadmap-ii/THREAT-MODEL.md` -- three findings
close, two of them by measurement.

### Changed

- **The dogfood capture log moved out of the plugin tree** (threat-model finding **T2.3**). It now
  lands at `dogfood/diagnostics.jsonl` under **`CLAUDE_PLUGIN_DATA`**, beside the logs, pids and
  session files, instead of under `CLAUDE_PLUGIN_ROOT`. `ARCHITECTURE.md`, `TRUST.md` and the shared
  library's own header all describe the plugin tree as read-only; the capture was writing to it on
  every surfaced diagnostic, so the code moved to match the documented contract rather than the
  documentation being softened to match the code.

  A second, quieter defect closes with it: the plugin tree is a *versioned* marketplace-cache
  directory, so every upgrade previously started an empty log and stranded the old one. Capture
  history for the rule-curation lane fragmented across version roots by construction. The data root
  carries no version segment, so captures now accrue in one place across upgrades.

  **No log is moved or deleted, and nothing is orphaned.** Pre-relocation logs stay readable:
  `scripts/review-dogfood.ps1` and `scripts/rule-efficacy-ledger.ps1` gain a `-Source data` rung for
  the new location, `auto`/`union` lead with it, and the existing `cache` and `checkout` rungs still
  reach the older locations.

### Added

- **`doctor` and `status` now reconcile the tree's version against the daemon that is actually
  running** (DX-audit finding **O2**). After an upgrade the old daemon keeps serving until the
  session ends -- which is the right behaviour -- but the report named only the tree's version, so
  *"which version is actually running?"*, the first question of any support thread, got a
  confidently wrong answer. v1.32.0 closed the honesty half of this by adding a caveat ("a live
  daemon may be older -- see logs/pses-daemon.log"); that stopped the report being wrong but still
  did not answer the question.

  It is answered now. The daemon stamps a `pluginVersion` field into its own session record at
  startup, and the report renders one of four lines: the two versions **agree**; they **differ**,
  naming both and why that is expected after an upgrade; the daemon **predates version stamping**,
  so its version is unknown; or there is **no live daemon** to reconcile against. An absent version
  is reported as unknown and never inferred to be a mismatch.

  This is an additive JSON field plus a header line: **no `userConfig` knob and no status token
  changed**, and the version line remains a header rather than a check row, so the "of N checks"
  count and the exit code are computed from exactly the same inputs as before.

- **The capture log is now size-bounded** (threat-model finding **T6.4**). It was a single append-only
  file the `keepLastN` sweep never touched, because that sweep bounds only stamped rolling families;
  a live log measured 5,279,427 bytes over 10,161 rows with nothing that would ever have stopped it.
  At session start a log at or past **8 MB** is renamed to `diagnostics-<yyyyMMdd-HHmmss-fff>.jsonl`
  -- which *is* the stamped-family shape the existing sweep already recognises -- so the bound comes
  from the sweep's own `keepLastN` and no second retention policy exists. The ceiling is
  `(keepLastN + 1) x 8 MB`, i.e. **88 MB** at the shipped default.

  Rotation renames rather than truncates, so no byte is lost, and every reader reads the **whole
  retained family** -- bounding the log does not narrow what a review or the efficacy ledger sees.
  `POWERSHELL_LSP_CAPTURE_ROTATE_BYTES` overrides the threshold for testing; a non-numeric or
  non-positive value falls back to the default rather than disabling the bound.

No `userConfig` knob name and no status token changed.

### The white paper and its raw measurement evidence now ship in the tree

**Documentation and published measurement records** (dispatches 000267 and 000268). **PATCH-class by
SemVer**: no API, knob, or behavior change -- these are files added to the repository. Like the other
PATCH-class entries here, they ride the MINOR above without raising it.

[`docs/whitepaper.md`](docs/whitepaper.md) is the whole system in one document -- design rationale,
measured evidence, and stated limits -- finalized against v1.32.0 and carried at revision **r2**, a
corrective revision that narrows claims rather than restating them: the status-honesty claim drops
from "a result is never silently wrong" to the analyzed-and-clean property it actually supports,
`-ExecutionPolicy Bypass` is disclosed, the PSScriptAnalyzer `Save-Module` fallback is stated as
Gallery-verified rather than covered by the project's SHA-256 pin, and "no leak" is narrowed to what
the runs support. Every claim carries a label -- verified, measured, inferred, proposed, unverified
-- and an unverified claim never appears as fact. `README.md` gains the link-map row.

The measurements behind it publish at `evidence/v1.32.0/`: the measurement harness, the result JSONs
every measured figure traces to, the measurement environment down to the host and the timer method,
and `SHA256SUMS.txt` over the set. A new maintainer-triggered `attest evidence bundle` workflow
builds that tree into an archive, attests it with SLSA build provenance, and uploads it as a release
asset -- attesting and uploading the same bytes in one job, because the archive format is not
byte-stable across runs.

**Nothing was published externally.** No submission and no announcement -- that is a maintainer
action and remains one.

## [1.32.0] - 2026-08-19
MINOR: **the `orgPolicy` file can now be integrity-pinned with a `.sha256` companion**, **the two
pinned dependencies can be installed from an internal mirror or a pre-staged bundle** so a machine
with no egress has a first-bootstrap path at all, and **`scripts/sign-plugin.ps1` ships** so an
`AllSigned` / WDAC estate can sign the plugin's script surface with its own certificate. The project
is also **relicensed forward to Apache-2.0** -- forward-only, with every previously published release
keeping the license it shipped under. Two smaller items ride along: an empty dogfood capture log no
longer reads as one phantom shape, and the README was restructured into per-topic `docs/` pages with
every heading and anchor preserved. **No new `userConfig` knob, no knob removed, renamed or
re-defaulted**, and the frozen 1.x knob surface in `CONTRACT.md` is unchanged -- every new capability
is opt-in, and with neither the companion file nor the offline environment variables set, behavior is
byte-for-byte what it was.

### Added: OPTIONAL integrity verification for the `orgPolicy` file

**New capability** (dispatch 000259, chartered by dispatch 000257 leg D; threat T4.1).
**MINOR-class by SemVer**: a new backward-compatible capability. **No new `userConfig` knob**, no
change to the `.strict()` manifest schema, and no change to `CONTRACT.md`'s frozen surface.

`orgPolicy` is the outermost layer of the settings precedence chain, and its `ExcludeRules` are
applied as a final subtractive drop that **no local setting can re-add**. It was read with no
integrity check, so write access to that file was equivalent to control over what the analyzer
enforces fleet-wide -- a named OPEN item in the threat model.

An organization can now pin the file by dropping a **`<policy>.sha256` companion beside it**. The
artifact is **discovered from the existing policy path**, never configured, which is what keeps
this at zero contract exposure -- there is no new knob to add. The companion accepts a bare
64-character hex digest or the `sha256sum` shape (`<hash> *<name>`).

When the companion is present the policy must hash to it **before any exclusion is lifted**. When
it is absent, nothing is checked and behavior is **byte-for-byte** what it was before, so the
feature is purely opt-in and no existing deployment changes.

A failed gate degrades on exactly the road every other `orgPolicy` failure already travels
(**fail open, but never silently**): no exclusions applied, exactly **one** warning to
`logs/lsp-client.log`. A companion that is unreadable or carries no digest degrades the same way
rather than passing -- an expectation that cannot be checked is unmet, not absent, because a gate
that waves through what it cannot verify is not a gate.

### Fixed: the dogfood reader counted an EMPTY capture log as ONE phantom shape

**Bug fix** (dispatch 000258, found by dispatch 000257 leg F). **PATCH-class by SemVer**: no
public API change, no schema change, no `userConfig` knob, and no behavior change for any
non-empty log -- only the empty case stops lying.

`scripts/review-dogfood.ps1 -Summary -Path <NONEXISTENT>` reported `shapes: 1 distinct
occurrences: 1` for a file that provably did not exist. `Read-DogfoodLog` was honest -- it
returned `@()` -- but a function that emits nothing returns **AutomationNull**, and binding that
to a typed `[object[]]` parameter converts it to a real `$null`. Since `@($null)` is a
**one-element array**, every reader that looped over the bare `@($Param)` ran its body once on a
null record and fabricated one `(no-hash)` shape. Guards now normalize at all five `[object[]]`
boundaries in `scripts/lib/dogfood-reader.psm1`: `Get-DogfoodShapes`, `Get-DogfoodPendingShapes`,
`Get-DogfoodSummary`, `Get-DogfoodSourceSplit`, and `Select-DogfoodCacheVersion`. The last three
did not miscount but **threw** under `StrictMode` on the phantom null.

**It was host-divergent**, which is why the suite never caught it: the unroll fires under pwsh 7
and not under Windows PowerShell 5.1, so the 5.1 CI leg structurally could not see it.

**Re-derive any cached accrual figure rather than trusting it.** The reader's empty-log floor was
1 occurrence under pwsh, so an empty log and a genuine one-row log rendered byte-identically, and
every affected reading was inflated by exactly one at the low end -- the end that matters. In the
dispatch 000256 / 000257 leg F accrual survey the `-Source checkout` reading of **1
`other-genuine` occurrence was entirely phantom**; true checkout-source accrual was **0**. The
per-version cache totals in that survey (297 occurrences across seven version directories) were
read per-record and are unaffected.

### README restructured and `DEV_NOTES.md` moved under `docs/` -- documentation RESTRUCTURED, not reduced

**Documentation only** (dispatch 000250). No `.ps1` behavior moved, no knob changed, no test
changed. **PATCH-class by SemVer**: a docs change with no user-visible contract change.

Seven deep-dive sections left the README for per-topic pages under `docs/`, matching the existing
`docs/` convention. **Every heading stays where it was**, now carrying a one-line pointer, so every
anchor written before this change -- in `ARCHITECTURE.md`, `docs/DEV_NOTES.md`, the issue-template
chooser, and any external post -- still resolves:

| Left the README | Now lives in |
|---|---|
| How it works (warm-start daemon) | [`docs/warm-daemon.md`](docs/warm-daemon.md) |
| Why a hook, not native `.lsp.json` registration | [`docs/native-registration.md`](docs/native-registration.md) |
| Repository and CI validation | [`docs/repository-scanning.md`](docs/repository-scanning.md) |
| Performance | [`docs/performance.md`](docs/performance.md) |
| The preflight doctor deep-dive | [`docs/preflight-doctor.md`](docs/preflight-doctor.md) |
| Platform support | [`docs/platform-support.md`](docs/platform-support.md) |
| Pinned versions | [`docs/pinned-versions.md`](docs/pinned-versions.md) |

`DEV_NOTES.md` moved to [`docs/DEV_NOTES.md`](docs/DEV_NOTES.md), leaving a root stub on the
`ROADMAP-powershell-lsp.md` precedent so old links resolve. `MAINTAINERS.md` **stays at root**: it
is a GitHub-recognized root convention and `docs/roadmap-ii/GOVERNANCE-SURFACE.md` cites it by line
range, which a move would silently decay.

A **Where everything lives** link map was added to the README, so every moved deep-dive is one
click from the top level. Nothing was deleted or summarized down: all 111 relocated README lines
are present verbatim in their destination pages, and the four README / doc-claims drift guards are
green with unchanged pass counts.

### Relicensed FORWARD from GPLv3 to Apache-2.0 -- ZERO code or runtime change

**License change only** (dispatch 000247, ruled by Mike Andersen 2026-08-16). No `.ps1` behavior
moved, no knob changed, no dependency was added. **This is a PATCH-class change by SemVer**, on the
v1.6.1 precedent: that entry classed the MIT-to-GPLv3 move as "a PATCH by SemVer (no API or behavior
change) -- the significance is legal, and it is carried in this entry, not in the version digit."
The same holds here. The `1.32.0` band is already MINOR for the air-gapped bootstrap below;
the relicense does not raise that class, it rides it.

#### Why

The 2026-08-15 corporate-IT review ranked GPLv3 as the number-one enterprise-adoption blocker after
the offline path (which dispatch 000244 closed). Three reasons of record:

1. **Enterprise allow-lists are written around Apache-2.0.** Its explicit patent grant (section 3)
   and NOTICE mechanics (section 4(d)) are what those lists key on, and enterprise adoption is the
   active demand signal.
2. **The relicense is uniquely cheap here.** As sole copyright holder, this is a forward-only grant
   change requiring no CLA archaeology -- exactly the mechanics of the MIT-to-GPLv3 move at v1.6.1.
3. **Nothing already granted is taken back.** See the forward-only section below.

#### Changed

- **`LICENSE`** is now the verbatim canonical Apache License 2.0 text, fetched from
  <https://www.apache.org/licenses/LICENSE-2.0.txt> and **byte-verified**: 11,358 bytes, 202 lines,
  LF, no BOM, ASCII-only, SHA-256
  `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30`. Not hand-typed or
  paraphrased, and the appendix boilerplate is left **unfilled** so the file stays byte-identical to
  the canonical source -- the copyright attribution lives in `NOTICE`, which is what Apache-2.0
  section 4(d) is for.
- **`NOTICE`** (new) names the project and the copyright holder, **Mike Andersen**, and states the
  downloader-not-redistributor posture for the two pinned Microsoft dependencies.
- **SPDX id `Apache-2.0`** is declared across the same authoritative sites the v1.6.1 drift-guard
  established: `LICENSE`, `.claude-plugin/plugin.json` (`license`), and the README License section.
  (`marketplace.json` still carries **no** `license` field -- the Claude Code marketplace schema has
  none -- and its absence is still asserted.) The drift-guard suite moved with the id and gained two
  assertions: that the outgoing GPLv3 body is **gone** rather than merely joined by the new one, and
  that `NOTICE` exists and names the project and copyright holder.
- **`THIRD-PARTY-LICENSES.md`** is unchanged in substance: PSES and PSScriptAnalyzer are still MIT
  (Microsoft), still **downloaded at install time** rather than bundled, and still not relicensed by
  this project. Only the compatibility sentence moved (MIT is Apache-2.0-compatible).

#### Forward-only -- prior releases keep the license they shipped under

This license change is **forward-only and does not reach backward**. **Every previously published
release keeps the license it shipped under, and those grants are irrevocable:** v1.0 through v1.6.0
remain **MIT**, and v1.6.1 through v1.31.2 remain **`GPL-3.0-or-later`**. Those grants
are **not** revoked, rescinded, or diminished here -- anyone using one of those releases keeps
exactly the rights it was published with. From this release forward the project is `Apache-2.0`.

#### What genuinely changes for adopters: copyleft is dropped

Stated plainly rather than only in its favourable direction. Under `GPL-3.0-or-later`, anyone who
distributed a modified version had to keep it open under the same terms. **Apache-2.0 is permissive
and does not require that** -- a downstream fork may keep its changes closed. The continuity docs
described the fork path as a *copyleft-backed* guarantee, so they were corrected rather than merely
find-and-replaced: the fork path itself survives intact (the grant is irrevocable and no CLA is
collected), but the obligation for derivatives to come back does not, and now says so. See
[CONTINUITY.md](CONTINUITY.md#the-fork-path-apache-20) and [TRUST.md](TRUST.md).

#### Not legal advice

This is the standard mechanical way to perform a forward license change, not legal advice. A
human/legal sanity check on the exact license text and third-party attribution remains advisable.

### Offline / air-gapped bootstrap

MINOR: **offline / air-gapped bootstrap.** The two pinned dependencies can now be resolved from an
internal HTTPS mirror or a pre-staged local bundle instead of only from their upstream URLs, so a
machine with no egress has a first-bootstrap path at all. **No `userConfig` knob was added** -- the
frozen 1.x knob surface in `CONTRACT.md` is unchanged. Both settings are environment variables,
because they are fleet plumbing an organization deploys by GPO / Intune / machine scope and are read
during bootstrap, before any diagnostics surface exists.

- **Two new environment variables**, tried in order and then falling through to the existing
  download: `POWERSHELL_LSP_ARTIFACT_MIRROR_BASE` (an HTTPS base URL) and
  `POWERSHELL_LSP_ARTIFACT_BUNDLE_DIR` (an absolute path to staged artifacts). See
  [docs/configuration.md](docs/configuration.md#offline-and-air-gapped-installation).
- **Sources are transport; pins are trust.** Whichever layer supplies an artifact, it passes the
  *same* SHA-256 pin check before use, and a mismatch **fails closed and never falls through to
  another layer** -- falling through would let whoever controls one layer force a downgrade onto
  the next. The failure banner names the layer that produced the bad bytes. The pins in the
  `ensure-*` scripts remain the only trust root.
- **With neither variable set, behavior is byte-for-byte unchanged**: no extra network call and no
  extra disk read. The existing `POWERSHELL_LSP_PSSA_CACHE` cache keeps its exact 000049 behavior
  as the innermost layer.
- **New release asset** `powershell-lsp-airgap-<version>.zip` -- the two pinned dependencies plus a
  manifest of their pins -- covered by the same SLSA provenance attestation as the source archive.
  It deliberately does not contain the plugin's own source, which is already its own attested
  asset; the offline path is two independently verifiable artifacts, each with its own
  `gh attestation verify`.
- **`/doctor` gains two checks:** *Artifact source* (which layer produced the installed
  dependencies, read from what the bootstrap recorded at install time) and *Offline readiness*
  (whether a staged bundle holds every pinned artifact and each matches its pin). Offline readiness
  reports an honest `unknown` for a mirror-only setup rather than claiming a verification it did
  not perform -- proving a mirror would mean downloading it.
- TRUST.md now also discloses the pre-existing `POWERSHELL_LSP_PSSA_CACHE` layer, which its
  downloads section had not previously named, and reports the unpinned `Save-Module` fallback
  distinctly (`gallery-fallback`) rather than as a pinned source.

### Authenticode: the publisher certificate stays declined, the org-signing path ships

MINOR: **`scripts/sign-plugin.ps1`** (dispatch 000248) -- one command for an `AllSigned` / WDAC
estate to sign the plugin's executable script surface with **its own** code-signing certificate,
which its policy already trusts. This **records the publisher-Authenticode decline** where
evaluators look for settled decisions (`ROADMAP.md`, the declines table) rather than reversing it:
for a git-distributed plugin the trust boundary remains the keyless-signed tag and the commit it
names.

- **Operator tooling, not a runtime path.** No hook, no bootstrap and no `/doctor` check invokes
  it; an administrator runs it deliberately, and a test asserts no entry point references it. The
  frozen 1.x `userConfig` knob surface is unchanged.
- **The surface is derived live**, never from a list in the script: every `.ps1` and `.psm1` under
  `scripts/`, which is exactly what the four manifest entry points launch, dot-source or import.
  A certificate arrives by `-Thumbprint` (store lookup) or `-PfxPath`; `-TimestampServer` is a
  parameter and `-NoTimestamp` is the air-gapped variant.
- **The verify sweep is the gate, and it fails closed.** After signing it re-reads every file with
  `Get-AuthenticodeSignature` and prints that sweep, exiting non-zero unless every file reports
  `Valid`. That is deliberate: `Set-AuthenticodeSignature` does not raise an error for a file it
  declines to sign and returns the same status for a real signature as for a silent no-op, so
  neither its return value nor a `try`/`catch` can be trusted as the proof.
- **Script signing and artifact pinning stay separate layers.** The downloaded PSES and
  PSScriptAnalyzer components are not signed by this and never will be -- they remain covered by
  their pinned SHA-256 hashes. TRUST.md states the boundary, and `docs/troubleshooting.md` gains
  the `AllSigned` symptoms with their remediation.
- Windows-only by nature: on any other host it names the reason and exits without reading a file.

### Fixed: diagnostics and docs that named a remedy the reader had already tried

**DX and observability fixes** (dispatch 000265 -- findings D1-D4 and O1-O4 of
`docs/roadmap-ii/DX-AUDIT.md` section 5, plus a third-party attribution rider). **PATCH-class by
SemVer**: remedy strings, printed caveats and documentation only -- no runtime behavior, no exit
code, no ruleset default, no `userConfig` knob, and no change to `CONTRACT.md`'s frozen surface.
Like the other PATCH-class entries here, it rides the MINOR above without raising it.

The through-line is that several messages were not merely thin but **actively misdirecting** --
they named a remedy the reader had already tried, or quoted a banner the code does not emit.

- **`scripts/doctor.ps1`'s four `CLAUDE_PLUGIN_DATA`-blind `UNKNOWN` remedies told you to run from
  inside a session** -- the state you were already in. Claude Code exports that variable to the
  plugin's own hooks and **not** to tool shells or a directly-invoked script, so re-running changed
  nothing and the advice read as a defect in the tool. Each now names the missing variable, says why
  being in a session does not set it, and gives an executable instruction: set it to the data
  directory holding `session/` and `logs/`, or run `/powershell-lsp:doctor` so the check runs as the
  plugin. (D3)
- **The multi-daemon remedy pointed at `CLAUDE_SESSION_ID`**, which the file's own comment says
  Claude Code never passes to a directly-invoked script. It now points at the `session/` directory,
  where each live daemon writes `<session-id>.json` carrying its pid, pipe, state and heartbeat --
  the ids the `-SessionId` parameter actually wants. (O4)
- **The README quoted a no-pipe banner that ships nowhere.** It now quotes the two banners
  `scripts/lsp-client.ps1` really emits, verbatim, with the phrase that tells them apart and their
  opposite remedies -- one says wait, the other says act. (D2)
- **The out-of-session `/doctor` invocation is relative to the plugin tree**, so a `/plugin` install
  has no `scripts/` and `pwsh` exits 64. The README and `docs/troubleshooting.md` now say so and
  give the marketplace cache path. (D1)
- **`totalMs` is not end-to-end per-edit latency, and now says so where it is read.** Its stopwatch
  starts inside the already-running client, so it excludes the per-edit `pwsh` spawn, the
  dot-source of the shared library and the option reads before it -- a **931 ms / 45% median**
  understatement (`docs/roadmap-ii/SLO-BASELINES.md`, finding 1). Both
  [docs/configuration.md](docs/configuration.md#enablestats) and `scripts/show-stats.ps1` carry the
  caveat now, the latter printed beneath the table. An SLO written against the old reading
  understated the wait by nearly a second. (O1)
- **The doctor and status version line reports the TREE, not the running daemon**, and now says so;
  the README explains how to read the live version from `logs/pses-daemon.log`. No new persisted
  field was added to get there. (O2)
- **Cold start is bounded honestly** -- no fixed edit count is enforced -- and a new README section
  separates *starting up* from *stalling* from *broken* using the daemon log line that already
  distinguishes them. (D4)
- **The daemon session file is documented in the README**: its fields, and the one case where it
  matters. It had been a single internal line in `ARCHITECTURE.md`. (O3)
- **`THIRD-PARTY-LICENSES.md` now covers everything third-party in the tree**, not only what is
  downloaded. The vendored SARIF 2.1.0 JSON Schema is listed under its OASIS RF-on-RAND terms,
  cross-referencing `tests/sarif/NOTICE.md`. It is the single item in this repository the project
  genuinely redistributes, and it is a **test fixture only** -- never loaded, shipped or executed
  by the plugin runtime.

One unit test pinned the exact D3 string that was removed; its assertion now tracks the corrected
remedy and adds a regression guard against the old text.
