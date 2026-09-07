<!-- GENERATED FILE -- DO NOT EDIT.

     Produced by scripts/gen-changelog-recent.ps1 from CHANGELOG.md, which is the release
     artifact and the only file to edit. This companion is a strict PREFIX of that file:
     the header, the versioning policy, [Unreleased], and every entry down to and including
     the ## [1.31.0] - 2026-08-10 band -- the third-most-recent MINOR line, derived at
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

## [1.31.2] - 2026-08-15
PATCH: **a client that walks away from a reply no longer kills the analyzer daemon**, and
**`nativeServe` / `ps_host` finally reach the process that acts on them**. Every external GitHub
Action is also pinned to an immutable commit SHA. No new `userConfig` knob, no knob removed or
renamed, no default changed, and no diagnostics change. **Read [Known issues](#known-issues) before
upgrading** -- on Claude Code 2.1.233 the serve-transport mappings are SUSPENDED behind an upstream
defect, so `nativeServe = shim` cannot take effect. No tagged release is affected.

### Fixed

**A client that abandoned one reply killed the whole daemon** (dispatch 000237). When an edit
reached the client's hard cap the client exited -- correctly, having already emitted an honest
banner -- and the daemon, finishing a moment later, wrote its reply into a pipe with nobody on
the other end. The write raised `Pipe is broken.`, the serve loop's per-request handler caught
and logged it, and **the daemon exited anyway**: four deaths per session across five measured
sessions, and the binding reason a large-file session never converged once the relaunch thrash
was gone.

The mechanism, derived from the live loop rather than guessed. The failed write moves the
`NamedPipeServerStream`'s internal state from `Connected` to `Broken`, and `IsConnected` is
`State == Connected` -- so the per-request cleanup, written as
`if ($server.IsConnected) { $server.Disconnect() }`, **skipped the disconnect on exactly the
path that needed it**. The stream stayed `Broken`, and the loop's next
`WaitForConnectionAsync()` -- which sat *outside* the per-request `try` -- threw
`Pipe is broken.` synchronously, past the handler and into the loop's outer `finally`. That is
why the daemon log showed the handled error followed immediately by `main loop ended; cleanup`,
with no second handled error between them.

Two changes, both inside daemon lifecycle. The per-request cleanup now calls the new
`Reset-PipeServerConnection`, which asks for the disconnect **unconditionally** -- `Disconnect()`
is willing to take a `Broken` stream back to `Disconnected`; only the guard stopped it being
asked. And the accept region is now guarded, so a pipe server that cannot be armed for any
reason is rebuilt on the same name (via the new single-source `New-DaemonPipeServer`) instead of
ending the process. One abandoned reply is one discarded write.

Measured red-to-green at the daemon level, same scenario, same host: the pre-fix daemon exits
after ONE abandoned reply and serves no further request (`main loop ended; cleanup` and
`--- daemon exit ---` both present in its log); the fixed daemon survives one and then three
consecutive abandonments, keeps answering, and its log carries the handled error with neither
of those two lines. The controls ship in
`tests/PowerShellLsp.DaemonSurvival.Tests.ps1`, which keeps the pre-fix implementation verbatim
and runnable so the RED can be re-run rather than merely cited.
**Setting `nativeServe` or `ps_host` had no effect on the LSP serve subprocess** (dispatch 000233).
Both knobs resolve through `Get-PluginOption`, which reads the environment variable
`CLAUDE_PLUGIN_OPTION_<KEY>`. Claude Code exports those variables to plugin **hooks** -- which is why
the diagnostics path was never affected -- but **not** to plugin **LSP server subprocesses**. The
manifest had never declared the supported alternative, a `${user_config.*}` expansion inside the
server's own `env` block. So a user could set `nativeServe = "shim"`, the shim would resolve `off`,
and the log would say `nativeServe=off` -- the same line it prints when the knob was never set at
all. Native hover / go-to-definition / find-references consequently failed at init for every user
who opted in, in every release up to and including 1.31.1. `ps_host` was affected identically, and
it matters even at `nativeServe = off`, because the shim launches PSES through it in
transparent-relay mode too: the PSES child host was always `pwsh` regardless of what was configured.
**`ps_host` becoming live is a real behaviour change for anyone who had set it.**

The manifest now maps `nativeServe`, `ps_host` and `profile` into `lspServers.powershell.env`
through `${user_config.*}` -- the supported transport, and the one Claude Code honours.

**The fix carries a generic invariant, not a three-knob patch.** A new structural regression
(`tests/PowerShellLsp.ServeUserConfig.Tests.ps1`) parses the serve subprocess's entry point, walks
its dot-source closure and call graph, **derives** every knob key reachable from it, and asserts each
has a mapping -- so a knob added to the shim tomorrow is covered with nothing to remember. It is
demonstrated RED five ways against mutated in-memory copies of the manifest, including a mapping
whose value is hardcoded rather than an expansion, and one pointing at the wrong knob.

**Observability, so this cannot go silent again.** The serve log now states each knob's effective
value **and its provenance** -- `env`, `profile`, or `default` -- on every launch, including the
default case, which is the case that used to be indistinguishable from a knob that never arrived. It
also logs the effective PSES host and names a substitution when the configured host does not resolve
on PATH. `/doctor` gains a **configured vs effective** check for the serve subprocess that FAILS when
a knob is set but the manifest declares no transport for it -- measured RED against the pre-fix
manifest (`configured=shim effective=off [NO TRANSPORT]`) and GREEN against this one.

**The transport is now PROVEN end-to-end against a real installed plugin** (dispatch 000233's
blocked acceptance criterion, discharged 2026-08-15). A marketplace install carrying the
`${user_config.*}` mappings registered its LSP server, answered `documentSymbol` / `hover` /
`goToDefinition` against `demo.ps1`, produced the expected `PSUseApprovedVerbs` diagnostic, and
logged all three knobs with `provenance: env` and `configured=shim effective=shim`. Details in
[docs/decision-ledger.md](docs/decision-ledger.md).

**A release test encoded the dependency version instead of the invariant** (dispatch 000240).
`tests/PowerShellLsp.Release.Tests.ps1` asserted the literal `actions/attest-build-provenance@v3`,
so a clean Dependabot major bump failed a *structural* release test although nothing structural
had changed -- and bumping the literal would have reproduced the same failure at the next major.
The assertion is now a family invariant (any numbered release, either upstream action name,
pinned by commit SHA) paired with an explicit floating-ref rejection, mirroring the idiom the
same `Describe` already used for gitsign. The `New-PluginSbom.ps1` companion assertion is
unchanged, and the block gained an executable anti-vacuity control that mutates an in-memory
copy of the workflow text rather than claiming in prose that it could.

### Security

**Immutable action pinning is now the repository convention, not a deferred hardening.** All
eleven external action references across the three workflows moved from movable tags to full
40-character upstream commit SHAs with the resolved release in a trailing comment. A tag is a
label its upstream owner can repoint at different code; a commit SHA cannot be repointed.
Dispatches 000042 and 000064 each booked this as a defensible-but-deferred hardening; it is no
longer deferred.

| Action | Was | Now |
|---|---|---|
| `actions/checkout` (x3) | `@v7` | `@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1` |
| `actions/cache` (x2) | `@v6` | `@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0` |
| `actions/upload-artifact` (x5) | `@v7` | `@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1` |
| `github/codeql-action/upload-sarif` | `@5595ccaf...` (v4.37.6) | `@ff2f1c621b7f889edc0d3c761ac2e6a3f8cdb0dd # v4.37.7` |
| `actions/attest-build-provenance` | `@v3` | `actions/attest@1e69f48acb82d1966a394da916b4c1698aa569d6 # v4.2.2` |

**A CI gate that discovers the surface instead of consulting a list.** New
`tests/PowerShellLsp.ActionPinning.Tests.ps1` walks every YAML under `.github/` plus every
composite `action.yml` in the tree, extracts every `uses:` line, and fails on any external
reference that is not a 40-hex commit SHA carrying a version comment. It ships with its own
anti-vacuity controls: discovery floors so an empty scan cannot pass, an acceptance case so a
reject-everything classifier cannot pass, and mutation cases proving each movable form
(`@v7`, `@v7.0.1`, `@main`, `@latest`, an abbreviated SHA, a SHA with no comment) is rejected.
Measured RED against the pre-change workflows: 11 named offenders.

### Changed

**The release pipeline attests provenance through `actions/attest` directly** (this supersedes
Dependabot PR #158, which proposed `actions/attest-build-provenance` v3 -> v4). Upstream made
`attest-build-provenance@v4` a thin composite wrapper whose only step is
`uses: actions/attest@<sha>` with every input forwarded unchanged, and recommends
`actions/attest` for new implementations. The pipeline now calls the wrapped action, preserving
the wrapper's `NODE_OPTIONS=--max-http-header-size=32768` verbatim. Provenance semantics are
unchanged: `actions/attest` auto-generates a SLSA build-provenance predicate whenever no SBOM
and no predicate input is supplied, which is exactly how this pipeline calls it. Same two
subjects (source archive + CycloneDX SBOM), same `id-token: write` / `attestations: write`
grants, same `!inputs.dry_run` gating, same release gates.

### Known issues

**RESOLVED in this release -- a zero-configuration install registers its LSP server again.** For a
window before this release, tracking `main` on Claude Code 2.1.233 required `profile`, `ps_host`
and `nativeServe` to be set by hand or **no LSP server loaded at all**:

```
Failed to load LSP servers for plugin powershell-lsp: Error: Plugin option "profile" isn't set.
```

Claude Code resolves `${user_config.*}` inside `lspServers` against the options a user has
explicitly set, **ignoring the defaults declared in `userConfig`** (the sibling MCP path merges
them), and one unset key discards every LSP server the plugin declares. Opening `/plugin` and
pressing Save did not help: the panel seeds an unset field **empty** rather than from its declared
default, and skips blank optional keys on save, so it wrote nothing. **No tagged release was ever
affected** -- the mappings landed after `v1.31.1` and are not in it.

**What ships in this release (dispatch 000241):** the `${user_config.*}` mappings are
**SUSPENDED** -- removed from the manifest, and recorded in `Get-ServeTransportSuspension`
(`scripts/lib/lsp-common.ps1`) together with the exact condition that restores them, so lifting
the gate is a mechanical edit. Filed upstream as
[`anthropics/claude-code#86936`](https://github.com/anthropics/claude-code/issues/86936).

**The remaining limitation, stated plainly:** while the gate holds, `profile`, `ps_host` and
`nativeServe` are read at their shipped defaults (`safe`, `pwsh`, `off`) **inside the LSP serve
subprocess**, regardless of what you configure -- so **`nativeServe = shim` cannot take effect**.
**Diagnostics are unaffected**: they run through the hooks, which do receive plugin options and
resolve your `profile` normally. `scripts/doctor.ps1` reports this as `SUSPENDED BY UPSTREAM GATE`
and still FAILs for a knob with genuinely broken transport; the serve log names the gate on every
launch rather than reporting a bare `provenance: default`. See
[docs/troubleshooting.md](docs/troubleshooting.md) and
[docs/upstream/claude-code-lspservers-userconfig-defaults.md](docs/upstream/claude-code-lspservers-userconfig-defaults.md).


## [1.31.1] - 2026-08-13
PATCH: **a live-but-busy analyzer daemon is no longer mistaken for an unreachable one, and is no
longer relaunched because of it -- on every supported platform.** Two fixes on a single edit-path
failure mode: the discriminator that tells a busy or still-analyzing daemon apart from a genuinely
absent one (dispatch 000225), and the off-Windows correction that makes its probe prove a daemon is
*listening* rather than merely that a socket file exists (dispatch 000231). No new `userConfig`
knob, no new status token, and no change to the hook registration or fail-safe edit behavior.

### Fixed

**A live-but-busy daemon is no longer mistaken for an unreachable one, and is never relaunched
because of it** (dispatch 000225). On the edit path the client treated *every* failed diagnostics
round-trip as "there is no daemon" and fired an auto-relaunch. `$null` from `Get-Diagnostics`
actually covers three conditions, and only one of them is a missing daemon:

1. the connect timed out because the daemon's single pipe instance was **busy** serving another
   edit (its serve loop is serial, so it does not accept while it analyzes);
2. the connect **succeeded** and the response did not arrive within the hard cap -- the daemon is
   alive and still analyzing (the large-file case, where its 5000 ms settle cap and the client's
   5000 ms hard cap are the same number, so the client can lose the race);
3. there is genuinely no pipe -- a clean idle-TTL self-terminate, a crash, or the ~150 ms pre-pipe
   launch sliver. This is the only condition a relaunch can repair.

In cases 1 and 2 the daemon is alive and holding the pipe, so the replacement could not even take
the name (the server allows one instance) and died before serving, while the user was told the
analyzer *"had stopped (e.g. after idle) and is being restarted"*. Worse, the first such edit burnt
the 30-second relaunch cooldown stamp, so every busy edit for the next 30 seconds fell through to
*"the analyzer was not reachable and could not be restarted automatically ... Start a new session to
restart it"* -- advice to restart a working session, about an analyzer that was fine.

The client now asks whether the daemon's named pipe is **present** before concluding it is absent
(`Test-DaemonPipePresent`, a read-only namespace probe, ~4 ms, and only ever on the failure path).
A failed connect cannot answer that question on its own: measured on Windows, a busy pipe and an
absent pipe raise the *same* `TimeoutException` after the *same* elapsed time. If the pipe is
present the edit resolves through the existing transient `incomplete` status -- "analysis did not
complete -- this edit was NOT checked" -- with no process spawned and the cooldown budget left
intact for a real outage. If the pipe is absent, the 000030 relaunch-and-recover path runs exactly
as before.

**No new `userConfig` knob and no new status token** -- the four-token taxonomy
(`ok` / `incomplete` / `degraded` / `unavailable`) is unchanged and the 000027 drift-guard is
untouched. Reusing the transient `incomplete` here follows the precedent 000030 itself set. The warm
path is unaffected by construction: a healthy pass never reaches the branch, so neither the probe nor
the relaunch runs, verified by comparing the emitted context against pre-fix code byte for byte.

Classified **PATCH**, derived from this changelog's own Versioning section: this is a bug fix with no
user-visible *contract* change -- no knob added or renamed, no status token added, no change to the
hook registration or fail-safe edit behavior. The banner a user sees in the busy case does change,
but from a false statement to a true one, which is the fix rather than a contract change.

Covered by five controls in `tests/` -- a RED reproduction on pre-000225 routing, the GREEN result on
the same scenario, a positive control proving a genuinely unreachable daemon still relaunches, a
warm-path regression control, and a bounded observation showing relaunches in the busy scenario at
**0** -- plus unit coverage of the discriminator itself. `docs/roadmap-ii/POST-FIX-REMEASUREMENT-relaunch-thrash.md`
remeasures the large-file behavior against the frozen v1.31.0 baseline.

**Follow-on correction: off-Windows, the pipe probe now proves liveness rather than file presence**
(dispatch 000231). The paragraphs above describe the discriminator as a namespace probe measured at
~4 ms. That measurement was taken on Windows, and it holds there: NPFS is kernel-managed, so the pipe
name disappears the moment its owner dies, however it dies. The first cut of the **unix** arm was
written by analogy from that same measurement and never measured off-Windows -- and off-Windows the
analogy does not hold. .NET backs a named pipe with a socket file that is unlinked only when the
server stream is *disposed*, so a daemon that dies without running its exit finally -- killed,
crashed, or reaped -- leaves the file behind. A bare presence test read that orphan as a live daemon,
suppressed the relaunch, and left the session with no analyzer at all. CI caught it: the
idle-stopped-recovery test failed on ubuntu and macos while both Windows legs passed.

The unix arm now asks whether anyone is **listening** on that socket, not merely whether the file
exists. The file check remains as a cheap first filter; when the file is present, a short non-owning
client connect settles it, because a connect to a unix socket with no listener is refused by the
kernel. A live-but-*busy* daemon still answers present -- the kernel completes the connection into
the listen backlog even while the serve loop is analyzing and not accepting -- so the property the
fix above exists to protect is preserved. The connect is non-owning: a client can never hold a pipe
name against its server, so the probe still cannot race a daemon that is legitimately starting. The
Windows arm is untouched.

Still **no new `userConfig` knob and no new status token**, and still classified **PATCH**: this
repairs the off-Windows half of the fix above, on the same failure path, with no contract change.
The three required behaviors are each covered by a test that runs on every leg -- a live-but-busy
daemon is not relaunched, a genuinely absent one still recovers, and an idle-stopped one is silently
relaunched and the next edit gets real analysis -- and the unix defect itself is asserted directly by
two off-Windows unit controls that reproduce a stale socket file and a leftover regular file at the
derived path.

## [1.31.0] - 2026-08-10
MINOR: **the doctor and `/status` state the clearance provenance floor beside the version, and the
README answers "what version am I on, and how far back is my data attributable?"** One
backward-compatible capability addition, on the self-check surface a user reads when something is
wrong, plus the user-facing documentation that points at it.

Classified MINOR -- derived, not asserted. This changelog's own Versioning section calls MINOR "a
new backward-compatible capability" and PATCH "bug fixes and internal hardening with no
user-visible contract change". This adds a new header line to two shipped user-facing command
surfaces (`/powershell-lsp:doctor` and `/powershell-lsp:status`), plus the user-facing
documentation for it, so it is a capability rather than hardening.

The precedent settles it without stretching: the v1.30.0 entry directly below classified **the
version header line itself** MINOR on exactly this reasoning, and the doctor-surface precedent in
this file is unanimous -- including one addition that was OPT-IN, never-`fail`, and explicitly
left the default doctor byte-for-byte unchanged. A default, always-rendered line cannot classify
below an opt-in probe.

**Report-only, and nothing else moves.** No knob is added, removed, renamed, or re-defaulted
(no `userConfig` entry in `.claude-plugin/plugin.json` is touched, and the count stays at 20 --
this release changes only that file's `version`); `CONTRACT.md` is untouched;
the frozen `pass`/`fail`/`unknown` status vocabulary is unchanged; the default doctor stays at
**11 checks**; and the exit code is computed from exactly the inputs it was before. The new line
contributes no result object at all.

### Added

- **The doctor and `/status` state the clearance provenance floor beside the version.** Every
  support interaction opens with "what version are you on?", which v1.30.0 answered. The question
  immediately behind it -- *and how far back can that answer be trusted?* -- could until now be
  answered only by running `scripts/rule-efficacy-ledger.ps1`, which is not something a user in a
  support thread is going to do. The floor now prints as a second **header line above the check
  table**, under the same ruling that placed the version there: a floor is a plain fact, the
  frozen status vocabulary has no word for one, and a row would have inflated the "of N checks"
  count with a non-check. Being a header also makes it unconditional -- it is there even when
  every check below it is UNKNOWN, which is exactly the run a stranger pastes into a bug report.

  **Surfaced, never re-derived.** The value comes from `Get-LifecycleProvenanceFloor`, exactly as
  the version line comes from `Get-PluginVersion`. The doctor grows no opinion of its own about
  what counts as an attributable version, so the readout and the ledger cannot disagree about the
  same log. Giving that function a second consumer is what turned it into a shared library: the
  lifecycle **read** side (`Resolve-LifecycleLogSearch`, `Read-LifecycleLog`,
  `Get-LifecycleProvenanceFloor` and their two helpers) moved from
  `scripts/rule-efficacy-ledger.ps1` to a new `scripts/lib/lifecycle-provenance.ps1`, **bodies
  unchanged** -- no computation, ruling, or rendering differs. Reaching into the ledger directly
  was not an option: it is an entry point with a `param()` block, and dot-sourcing a `.ps1` runs
  that block in the caller's scope, which the G1 purity guard refuses as an invariant with no
  baseline.

  **Five states, five renderings, because they are five different claims:** a floor; records with
  none attributable; a log holding no record yet; no lifecycle log at all under a *known* data
  root -- the only case entitled to say `(absent)`; and a search that ran under a *fallback* data
  root, where "nothing was ever captured" and "this run could not find it" cannot be told apart,
  so it reports `(undetermined)` rather than picking the flattering reading.

- **The efficacy ledger's printed provenance-floor caveat states that the floor is
  window-relative.** The floor names the earliest version-attributable release among the records
  **still retained**, and it *rises* as `session-start.ps1`'s `Invoke-LogSweep` trims the
  `lifecycle-*.jsonl` family to `keepLastN`. That was always true and always load-bearing -- read
  as "the earliest release this plugin ever had data for", the number is a claim about history --
  but it lived only in a source comment, where the reader quoting the figure never saw it. It now
  prints directly under the value it qualifies, and only in the floored state: where no floor is
  named there is nothing for it to be relative to.

- **README: "What version am I on, and how far back is my data attributable?"** A support subsection
  under the install-and-release verification material stating both facts, what each means, and
  every rendering the readout can produce. It points at the live doctor/`status` line as *the*
  answer and names the two sources behind it rather than restating a value that would go stale --
  so the docs, the runtime, and the ledger are one fact surfaced in three places rather than three
  copies to keep in sync.

### Fixed

The items below are **PATCH-level and do not move this section's MINOR classification** -- a MINOR
cut already carries them. They are recorded rather than folded into "internal hardening" for one
reason: the first changes what an operator can verify about a released artifact, and the second
corrects a published instruction that could not succeed as written. The Gate 6 and pipeline
mechanics behind them are internal and are deliberately NOT itemized here; they live in the
decision ledger, Section 3.

- **Release tags cut from the next release forward are findable in the Rekor transparency log, and
  the documented way to verify one now runs.** `docs/RELEASING.md` told a reader to run `gitsign
  verify <tag>`, which is the **commit** subcommand -- it resolves the tag to its commit, finds no
  signature block, and dies. The tag subcommand is `gitsign verify-tag`, and correcting that alone
  would not have been enough: it then failed at its transparency-log step for every tag this
  project has ever cut. The pipeline pinned gitsign v0.16.1, whose signer keyed a tag's log entry
  on the hash of the tag reassembled as a *commit* while every verifier looks up the real
  tag-object hash, so the two could never meet. The pin is now v0.17.1, where upstream routes both
  through one helper. Nothing about signing changes otherwise -- same keyless GitHub-OIDC identity,
  same certificate authority and log, same signature format on the tag.

- **Stated plainly, because it affects anyone verifying an existing release: `gitsign verify-tag`
  cannot pass for v1.30.0 or any earlier tag, and never will.** Those tags are not re-signed -- the
  released history stays exactly as cut -- so their log entries remain keyed where no verifier
  reads, and the corrected command will keep failing on them by design rather than because
  something is wrong with the tag. What that costs is transparency-log inclusion *for the tag*
  only. Signer identity and the signature over the tag payload remain fully verifiable offline for
  every release, and the release **assets** carry their own inclusion proofs throughout, which is
  why `gh attestation verify` is now documented as the primary integrity check. `docs/RELEASING.md`
  gives the offline tag procedure that does succeed on those tags.
