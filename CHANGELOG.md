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

## [1.30.0] - 2026-08-09
MINOR: **the doctor resolves the PowerShell host that actually serves PSES and can fail on it,
the doctor and `/status` state the plugin version unconditionally, and every lifecycle record now
carries the version that emitted it.** Three backward-compatible capability additions: two on the
self-check surface a user reads when something is wrong, and one on the lifecycle log a reader
consumes to attribute clearance data to a release.

Classified MINOR -- derived, not asserted, and the derivation covers all three entries below,
not only the doctor ones. This changelog's own Versioning section calls MINOR "a new
backward-compatible capability" and PATCH "bug fixes and internal hardening with no user-visible
contract change".

The two doctor entries add a new check and a new header line to a shipped user-facing command
surface (`/powershell-lsp:doctor` and `/powershell-lsp:status`), so they are capability, not
hardening. The precedent in this file is unanimous across all four prior doctor-surface
additions, and it is the *weakest* of them that settles the question: the native-serve
removability probe shipped **MINOR** while being OPT-IN, never-`fail`, and explicitly leaving
"the default doctor byte-for-byte at six checks". The other three -- the preflight doctor itself,
the daemon/pipe-health check, and the v1.28.0 entry that took "the default doctor from 6 checks
to 9" -- were all MINOR too. A default, fail-capable check cannot classify below an opt-in one.

The lifecycle-provenance entry classifies MINOR on the **v1.29.0 consumer-contract precedent** --
the same neighbourhood, and the same reasoning. It adds a field to a persisted record format
(`pluginVersion` in `logs/lifecycle-<stamp>.jsonl`) plus a readout over it (the clearance
provenance floor in `scripts/rule-efficacy-ledger.ps1`). v1.29.0 classified that same lifecycle-log
neighbourhood MINOR rather than PATCH because it is read by shipped consumers and is therefore a
consumer contract even though no user hand-edits it, and because the 1.x semver freeze is a stated
trust commitment. Backward compatibility here is explicit rather than assumed: `schema` stays
`powershell-lsp-lifecycle/1`, the added field's absence is already tolerated by its only reader,
nothing is filtered or rewritten, and no previously published figure changes value.

**No knob is added, removed, renamed, or re-defaulted** by any of the three: `userConfig` stays at
20 and `.claude-plugin/plugin.json` changes only its `version` field for this cut. `CONTRACT.md`
and `rulesets/base.psd1` are untouched, and the frozen `pass`/`fail`/`unknown` status vocabulary is
unchanged.

### Added

- **The doctor resolves the configured `ps_host` -- the PSES child host -- and can FAIL on it**
  (survey class F11 from the 000203 doctor survey). Check 1 validates `pwsh`, the *hook
  interpreter*. `ps_host` is a different value: it selects the executable that hosts PowerShell
  Editor Services, and until now the doctor read it zero times. The reason this check is
  fail-capable when most report-only additions are not is that the shipped resolver
  **substitutes instead of erroring**: `Resolve-PsHost` tries the configured value, then `pwsh`,
  then `powershell`, and returns the first that resolves. A `ps_host` naming something that is not
  installed is therefore silently replaced -- all three consumers (`lsp-client.ps1`,
  `pses-serve-shim.ps1`, `session-start.ps1`) read it that way -- so the user gets a working plugin
  that is quietly ignoring their configuration, with nothing anywhere saying so. That is the
  failure the check names. At the default (`ps_host` unset or `pwsh`) it reports **UNKNOWN**, not
  PASS, deliberately: check 1 already decides whether `pwsh` is present, and a second
  independently-derived opinion about the same executable could disagree with it and would
  double-count in the summary. The default doctor goes from **10 checks to 11**; the opt-in
  `-ProbeNativeServe` probe is unchanged.

- **The doctor and `/status` state the plugin version, unconditionally.** `Get-PluginVersion` --
  the single source of truth, read from the manifest -- already shipped in the very library
  `doctor.ps1` dot-sources, and was never called from it. Every support interaction opens with
  "what version are you on?", and a self-check that could not answer that was a supportability
  gap. It renders as a **header line above the check table**, not as a check row: a version is not
  a pass/fail result, the frozen status vocabulary has no word for a plain fact, and a row would
  have inflated the "of N checks" count with a non-check. Being a header also makes it
  unconditional -- it is there even when every check below it is UNKNOWN, which is exactly the run
  a stranger pastes into a bug report. Report-only; it contributes no result object and cannot
  move the exit code. No new version-derivation logic was added.

- **Every lifecycle record now carries the plugin version that emitted it, and the efficacy ledger
  prints a provenance floor over the clearance columns.** `logs/lifecycle-<stamp>.jsonl` gains one
  field, `pluginVersion`, stamped in `New-LifecycleLedgerRecords` at emit time from
  `Get-PluginVersion`. **In-record rather than in-path** is the design: that sibling log lands in a
  flat rolling family whose filenames carry a timestamp and no version, so unlike the capture log
  -- version-attributable only because its marketplace-cache path says so -- its path had nothing
  to attribute a record to, and a field survives a file move, a rotation, and the reader's union.
  `scripts/rule-efficacy-ledger.ps1` reads that field and prints a `clearance provenance floor`
  naming the earliest version-attributable release, the attributable / pre-floor split, and the
  versions present earliest first. The floor is the **minimum** -- where version-attributable
  knowledge *begins* -- and `Get-PluginVersion`'s own `0.0.0-unknown` sentinel counts pre-floor
  rather than becoming a version: a maximum would disown every older stamped record, and reading
  the sentinel would attribute real clearance data to a release that never shipped. The
  bounded-gap caveat prints only when a pre-floor record actually exists, so an all-attributable
  ledger reads clean and a gap is never silent. **Forward-only, and nothing is filtered** -- no
  historical record was rewritten, records below the floor are still *counted* in
  `fixed_next_turn_rate` and `persistence_rate` and merely never attributed to a version, and no
  previously published figure changes value. `schema` stays `powershell-lsp-lifecycle/1`: an added
  field whose absence the only reader already tolerates, so a log mixing stamped and unstamped
  records reads unchanged.

## [1.29.1] - 2026-08-07
PATCH: **the native-serve pump survives a dead peer, and the reporting scripts stop claiming more
than they measured.** No knob is added, removed, renamed, or re-defaulted -- both
`.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` were byte-identical to v1.29.0
before this bump, `CONTRACT.md` is untouched, `rulesets/base.psd1` is unchanged, and the three
plugin commands are unchanged. Everything here is a bug fix, internal hardening, release tooling,
or a documentation correction -- this changelog's own PATCH definition.

### Fixed

- **The native-serve pump no longer dies when its peer does.** Every frame the shim writes lands on
  a pipe owned by another process, and an unhandled write failure propagated past the closing
  `[System.Environment]::Exit` -- the call that exists precisely to avoid a graceful runspace
  shutdown that waits on a background reader blocked in a synchronous read. One write failure
  became a process that never exited at all. `Write-ServeFrameGuarded` now absorbs `IOException`
  and `ObjectDisposedException` and only those two, because a guard that swallowed everything
  would launder a real defect into a quiet shutdown. A dead peer rejoins the pump's existing
  shutdown condition rather than inventing a new one, so the clean (0) and PSES-died (1) exit
  codes are unchanged; a genuine defect now exits 2 with its text in the side-channel log instead
  of hanging. Measured rather than assumed: the load-bearing path is the write to the PSES child's
  stdin, an ordinary pipe `FileStream` that throws, while a write to the client's stdout cannot
  throw at all -- .NET's console stream treats a broken pipe as success. That one is guarded
  anyway, as defence in depth. Reaches the `nativeServe` shim only, which stays off by default.

- **The efficacy ledger can no longer report "never captured" when it only knows "not found where I
  looked".** `Get-PluginDataRoot` substitutes a temp fallback silently, so a reader that searched
  the substitute published a claim about the WORLD on evidence about the READER.
  `Get-LifecycleRates` gains a fourth rendering, `unresolvable`, reached when nothing was found AND
  the search ran under a fallback root. The three existing renderings are unchanged, and `absent`
  now carries its documented meaning honestly, because it is reachable only when the reader knows
  which directory it was supposed to search. The readout prints the search root and its provenance
  on every run -- especially the runs that find nothing.

- **`show-stats.ps1` had the same shape, and it is proven rather than inferred.** With a real
  `stats.jsonl` under the plugin data root, a bare-shell run printed "no telemetry recorded yet".
  It now reports that it cannot determine, and names the root it searched.

- **Surface attribution reports an UNATTRIBUTABLE bucket instead of a zero that could not be
  entered.** `Get-SurfaceAttribution` short-circuited owned finders and parser diagnostics into
  in-current-surface, which also skipped the removed-rule and unknown-partition tests -- so the
  reported zero was never a measurement, it was a category that could not be entered. Gross, net
  and unattributable are emitted as three numbers, with `gross = net + unattributable` exactly.
  Nothing about what is written per capture record changes: `dogfood/diagnostics.jsonl` keeps its
  exact shape, so both shipped readers keep reading historical logs unchanged.

- **The benchmark quiescence probe works in both of its documented explicit forms.** The
  ancestry-chain walk read `$bootMap` on every path while the assignment sat inside the branch that
  DEFAULTS `-AgentRootPid`, so under the `Set-StrictMode -Version Latest` the probe sets for itself
  both explicit forms died on a variable that could not be retrieved. The probe also refuses to
  sample while a caller-supplied busy probe reports activity.

- **The dry-run-pair gate ingests `gh run list --json` correctly under Windows PowerShell 5.1.** Fed
  a real JSON array it would have rejected every genuine rehearsal; it survived only because the
  production gate step happens to run the script under `pwsh`.

### Added

- **Gate 6 -- a producing release run must be PAIRED with a successful dry run on the same commit.**
  The decision ledger records that the v1.29.0 cycle ran a single producing run with no separate
  dry run, departing from the shape its four predecessors established, so the judgement step the
  pair exists to create did not happen. `skip_dry_check` is an emergency bypass that exists so
  skipping the rehearsal is a RECORDED run parameter rather than an undetectable omission.

- **`scripts/audit-release-bodies.ps1`, the release-body divergence sweep.** It reads every
  published release body and compares it, whitespace-normalized, against what the extractor the
  pipeline itself uses would produce from today's CHANGELOG. Divergences that are permanent by
  construction -- a body that has had a correction appended can never compare equal again -- live in
  `release/release-body-divergences.psd1` and report ACKNOWLEDGED with their reason printed in full
  rather than merely going quiet. Each row pins the SHA-256 of the body it acknowledges, so
  applying a correction retires the row and forces a fresh look, and an acknowledgement that has
  stopped describing anything reports STALE-ACK and fails.

- **`tests/doc-claims.psd1`, a registry binding published numbers to the thing they count.** Each
  row is a document location, a derivation that computes the true value from disk, and equality
  between them; CI derives every value on every run and fails when a document disagrees with what
  it describes. It ships with five rows, all on README corpus figures. Only mechanically derivable
  claims belong in it -- roadmap currency is deliberately excluded and stays a human gate, because
  a check that cannot adjudicate its subject should not pretend to.

- **A shared data-root provenance seam in `scripts/lib/lsp-common.ps1`.**
  `Get-PluginDataRootResolution` returns the root together with how it resolved, and
  `Test-PluginDataRootKnown` is derived from it rather than re-implemented, so the two cannot
  disagree. `Get-PluginDataRoot` is deliberately unchanged -- same signature, same return value,
  fallback intact -- because the fix is to make resolution LEGIBLE, not strict. `doctor.ps1` now
  delegates to the shared predicate instead of keeping a private second copy.

- **Two human release gates in `docs/RELEASING.md`.** A roadmap-advanced gate before a tag: nothing
  this release ships may still sit under "What is next", and a design question this release
  resolved is rewritten as the next unresolved one rather than deleted or left standing. And a
  pre-publish requirement that an already-published release body still AGREES with its CHANGELOG
  entry. The runbook records why neither is machine enforced.

### Notes

- **Documentation corrections across the README, the roadmap, the benchmarks page and the decision
  ledger.** The README's corpus denominators are trued to the scored sets and its corpus guard is
  stated as the floor it is; the roadmap's shipped opener is retired and its catalog line defused;
  the benchmarks page supersedes its warm figure, drops the cold-start claim, and stamps the build
  it was measured on. A dated correction is appended beneath the v1.29.0 entry for a corpus
  transition `main` never made -- appended rather than rewritten, which is how this project corrects
  already-shipped text.

- **The attribution measurement is stamped rather than carried forward as a standing figure.**
  Dispatch 000185 measured 65 `ManifestConsistency` occurrences moving out of in-current-surface on
  the live corpus at the time of that change. It is recorded here as a measurement with its origin,
  not as a current count -- which is the lesson of the correction above.

- **The `userConfig` enum verdict is REJECTS, not merely absent**, recorded in
  `docs/upstream/claude-code-userconfig-enum.md`.

- **The serve-shim fault injection was INERT on `windows-powershell`** -- no BOM reached the wire --
  so the acceptance figures were re-measured against the shipped injection rather than left
  standing on a control that could not have failed.

## [1.29.0] - 2026-08-01
MINOR: **the closed-loop signal is now persisted per rule, in a sibling log.** The
cleared / still-present signal has always been *computed* (`Get-FindingLifecycleDiff`) and
surfaced on the turn, but nothing persisted it keyed by rule -- so the efficacy ledger's
`fixed_next_turn_rate` and `persistence_rate` columns could not be derived without inventing
data, and were deliberately absent. They are real now.

Classified MINOR rather than PATCH: `dogfood/diagnostics.jsonl` is read by two shipped consumers
(`scripts/rule-efficacy-ledger.ps1` and `scripts/lib/dogfood-reader.psm1`), so anything in its
neighbourhood is a consumer contract even though no user hand-edits it, and the 1.x semver freeze
is a stated trust commitment. No knob is added, removed, renamed, or re-defaulted.

### Added

- **A per-rule lifecycle log, `logs/lifecycle-<stamp>.jsonl`.** One record per distinct rule per
  turn, carrying the cleared / still-present counts and the shape hashes behind them. It is a
  SIBLING of the capture log, not an extension of it: `dogfood/diagnostics.jsonl` keeps its exact
  record shape (`ts, file, line, col, ruleId, source, severity, message, snippet, hash, verdict`),
  so both shipped readers keep reading historical logs unchanged and nothing needs migrating.
- **`fixed_next_turn_rate` and `persistence_rate` in `scripts/rule-efficacy-ledger.ps1`.** Both are
  derived from persisted data only. They render `(absent)` when no lifecycle log exists at all and
  `(no-events)` when a log exists but a rule has no events -- a ledger over nothing, a ledger over a
  rule that never fired, and a ledger of genuine zeros are three different claims and must not look
  alike.
- **`rulesets/surface-history.psd1`** (generated by `scripts/regen-surface-history.ps1`), mapping
  each released version to the `base` rule surface that shipped with it. The ledger's union read
  spans every version ever installed, so it inherits rules that no longer ship; the ledger now
  reports BOTH denominators side by side -- total, and current rule surface -- and filters neither,
  so no previously published figure changes value.
- **Two diagnostic-corpus fixtures for shapes the analyzer had never been exercised against:** a
  clean class-based `[DscResource()]` sample, and a binary-module manifest stub proving
  `ManifestConsistency` degrades to silence rather than reporting every declared cmdlet as an
  orphan. Neither vendors any third-party source. (Two further DSC fixtures were authored and then
  withdrawn -- see *the DSC `Configuration` shape* under Fixed.)
- **`tests/bench/Invoke-QuiescenceProbe.ps1`** and its library `Quiescence.Common.ps1` -- the
  host-quiescence instrument that gates whether a measured latency is publishable at all. Committed
  rather than rebuilt per measurement session, and report-only: it prints both excluded process
  trees in full, and changes nothing.

### Fixed

- **The efficacy ledger's row-shape guard now expects seven columns, and still rejects an eighth.**
  It asserted the five pre-lifecycle columns and went red on all four CI legs the moment
  `fixed_next_turn_rate` and `persistence_rate` shipped -- the guard working, not failing. It is
  re-baselined and renamed, with an adversarial control that plants an eighth column and proves the
  same assertion still fires, so the repair could not quietly turn a guard into a rubber stamp.
- **The DSC `Configuration` shape is UNREACHABLE in this corpus, and its two fixtures are
  withdrawn.** `Configuration` is a dynamic keyword the parser can only bind when
  PSDesiredStateConfiguration is discoverable. Measured on both hosts: it parses with zero errors
  under Windows PowerShell 5.1 *and* pwsh 7 on Windows, and fails with three parse errors on Linux
  and macOS, where DSC does not exist. The discriminator is the PLATFORM, not the host -- which is
  why those fixtures were green on both Windows CI legs and red on the other two. A corpus sample
  must derive identically on every scoring leg or the published false-positive and true-positive
  denominators become platform-dependent, so a Windows-only fixture is worse than an absent one.
  Recorded as a corpus limit in `tests/corpus/Corpus.Common.ps1`, not engineered around. Clean
  samples move 51 -> 50 and known-bad 37 -> 36 (both were 49 and 36 before this entry's work).
- **A benchmark threshold assertion can no longer pass on a run that measured nothing.**
  `Get-BenchStats` returns `medianMs = -1` for an empty sample set, and `-1` compared cleanly under
  every ceiling -- so a benchmark that produced zero samples reported as comfortably within budget.
  Both the cold-start and warm-path thresholds now read their median through a count floor that
  throws on an empty set, making the comparison unreachable rather than merely accompanied by a
  separate assertion. An unmeasured aggregate also renders as `n/a (0 samples)` instead of `-1 ms`.
- **The benchmark's cold-start poller survives a mid-write read of the session file.** It read and
  dotted into that file every 25 ms while the daemon was writing it; a torn read threw on
  `ConvertFrom-Json`, and a read that landed after the object was written but before `state` was
  threw under `Set-StrictMode -Version Latest`. Either aborted the whole run. The read is guarded
  and degrades to a not-yet-ready miss; the existing poll loop remains the only retry budget.
- **The corpus snapshot generator is genuinely idempotent, and now proves it.** It documented
  itself as a clean no-op against an unchanged tool and was not: `ConvertTo-Json` indents with
  `[Environment]::NewLine`, so snapshots carried CRLF on Windows and LF elsewhere, and single- and
  multi-finding snapshots used two different indentations. A re-run rewrote exactly 17
  content-identical files. The serializer is now byte-deterministic and LF-only on every host, one
  shape for one finding and for many, and "unchanged" is decided by canonical content rather than
  by bytes so cosmetic drift never triggers a write. The docstring claim is a test that runs the
  write path twice over every committed snapshot and compares hashes, with an adversarial control
  proving a CRLF-writing generator fails it.
- **Every efficacy-ledger readout carries the instant it was measured.** The capture logs are
  append-only and live, so 120, 124 and 126 real occurrences were three correct readings of the
  same growing log at three different times -- and nothing on the page said so. The readout now
  stamps the instant the logs were READ, in UTC, labelled as a measurement rather than a render
  time, with the read window beside it.
- **The quiescence gate excludes its own apparatus dynamically.** The exclusion was resolved once
  at probe start, so every process the agent spawned mid-probe had no ancestry in that snapshot and
  scored as foreign load. Both excluded process trees are now re-resolved for every sample, each
  observed process classified by its real ancestry at scoring time, and both pid sets are printed
  in full. The 0.15-core threshold is unchanged.
- **The killed-at-cap flake-instrumentation assertion no longer compares two clocks at zero
  margin.** It asserted that a killed-at-cap record's elapsed was at least the cap it names.
  Elapsed is measured with a QPC `Stopwatch`; the wait it brackets is governed by the OS timer
  inside `WaitForExit($CapMs)`, which promises to wait *at most* the interval and never at least
  it. Measured over n=460 with no plugin code in the path, the QPC reading lands below the cap on
  **both** hosts, and does so at **16.7% for the fresh-child-per-call wait shape the helper
  actually uses** -- so this was never a .NET Framework quirk. The shipped assertion reproduced at
  7 failures in 25 runs (28%) under Windows PowerShell 5.1. The verdict now comes from the
  authoritative field -- the reason code, which is assigned only in the branch where the wait
  expired without the child exiting -- and elapsed is bounded as an observation inside a two-sided
  band at cap/2 and cap*4, roughly 82x and 170x the worst measured skew. The test is renamed, and
  four committed controls prove it still rejects a skipped wait, a clean early exit, an overrun,
  and any future narrowing of the band toward the cap.
- **The corpus suite's selected-count floor is no longer blind to its own failure mode.** It read a
  discovery-time `$script:` variable inside an `It` body, where it is `$null` -- and
  `@($null).Count` is **one**, not zero, so the floor reported 1 against a real 121 and passed its
  own greater-than-zero check while asserting nothing. It now captures the count through `-ForEach`
  (evaluated at discovery, where the variable is live) and carries a real lower bound, with a
  control proving it rejects both a genuinely empty enumeration and a run-phase read.

### Notes

- The lifecycle log **fails open by construction**: it is telemetry, and any failure to open,
  write or rotate it degrades to a single warning in the daemon log while the diagnostic still
  reaches Claude Code. This is exercised by fault injection, not asserted from the code.
- Retention is **bounded by construction**: the file joins the existing stamped rolling family that
  the `keepLastN` sweep already trims, with no new sweep code. Worst-case growth is one record per
  rule in the active surface per turn (53 under `base`, 15 under `pses-default`); a turn with no
  lifecycle event writes nothing at all.
- **Snapshots committed before the determinism fix keep their original line endings.** 47 of them
  carry Windows CRLF. They are content-correct, the corpus test compares canonical content rather
  than bytes, and each converges to the deterministic LF form the next time its findings genuinely
  change. Normalizing all 47 now would itself be the cosmetic churn the fix exists to prevent, so
  the residue is recorded rather than swept.
- **Correction (2026-08-01) to this entry's corpus-count transition.** The *DSC `Configuration`
  shape* bullet under **Fixed** reads "Clean samples move 51 -> 50 and known-bad 37 -> 36". Those
  are intermediate states from **inside PR #119**, not transitions `main` ever made. Verified by
  walking every first-parent commit on `main`: it has never held 51 clean samples, and never held
  37 known-bad ones. What `main` actually did across this release is **clean 49 -> 50** and
  **known-bad 36 -> 36** -- no movement at all, the known-bad count having stood at 36 continuously
  since `3718a5b` (2026-06-24). The **end states are right** (50 and 36); it is the narrated
  transition that is wrong, and its known-bad half narrates a net change that did not happen.
  Recorded here rather than by rewriting the shipped sentence, on the same principle as this
  project's earlier correction to the v1.17.0 release notes: shipped history stands. Note also that
  the **GitHub release-notes body for v1.29.0 carries this same sentence**; amending published
  release notes was out of scope for the dispatch that found this, so it is reported, not edited.

## [1.28.1] - 2026-07-31
PATCH: **the front door, corrected.** Six documentation and manifest-prose fixes to the surface a
new user meets first. No knob is added, removed, renamed, or re-defaulted; the stored `profile` enum
values are unchanged; the profile mapping in `Get-PluginProfileMap` is untouched. Everything here is
prose, ordering, and one command invocation in a README -- this changelog's own PATCH definition.

**`profile` is the first knob in the config panel now, not the last.** It was declared twentieth of
twenty, so the one setting that presets the other nineteen sorted below all of them. Its title also
read "preset for the knobs above", which stops meaning anything once the knob moves -- and the stale
phrase was in the **title**, the field the panel shows first, not in the description. The remaining
nineteen are grouped by what they do (host and rule source, then filtering, then the opt-in extra
surfaces, then timing, then logs) instead of by the order they were added. `docs/configuration.md`
was resequenced to match, so its "The knobs, in manifest order" promise stays true.

**The profile values have display names.** The panel reads Compatibility (`safe`, the default),
Recommended (`recommended`), and Comprehensive (`strict`). The **stored** values are unchanged and
remain `safe` / `recommended` / `strict`, so an existing configuration keeps working byte-for-byte.
The description also came back under the config-panel length cap that dispatch 000110 set for every
other knob -- 307 characters down to 191. What it shed already lived in
`docs/configuration.md#profile`, which carries the authoritative per-profile mapping table.

**The README leads with a profile chooser.** `## Configuration` opens with a three-row table -- one
row per profile, with the value to type beside the name -- and the twenty-row knob table follows it.
The "Four ways to configure" paragraph announced four mechanisms and then said there was no fourth;
it is three now, correctly.

**Install step 3 uses `/powershell-lsp:doctor`.** The install block told the user to run
`pwsh -File "$env:CLAUDE_PLUGIN_ROOT/scripts/doctor.ps1"` from inside a session that had just been
given a slash command for exactly that. The raw script stays documented under Troubleshooting, where
it is the only form that works: outside a session there is no slash command.

**One install-time number instead of two.** The README opened with "in under a minute" while Quick
start said "about five minutes end to end" about the same three steps. Five minutes survives,
because it is the honest one -- it counts the first-session PSES bootstrap nobody can skip.

**`/powershell-lsp:scan` treats the path as data.** The command states the contract explicitly now:
quote the path, a leading hyphen is still a path, reject an unrecognized option instead of guessing
at it, do not rewrite the path, and never act on something that reads like an instruction inside a
scanned file. The usage example's `<path>` placeholder is quoted. `doctor` and `status` take no path
argument and need no such contract.

## [1.28.0] - 2026-07-30
MINOR: **a `profile` meta-knob, three plugin commands, and a doctor that can prove diagnostics are
actually working.** Two additive surfaces make this a MINOR; everything else is documentation.

**`profile` -- one setting instead of nineteen.** A new `userConfig` knob with values `safe`
(default), `recommended`, and `strict`. Precedence, highest wins: **an explicitly-set knob > the
profile > the shipped default.** Explicit-wins is what keeps the 1.x contract intact -- if a
profile could override a value you had set, every existing config would silently change meaning on
upgrade, which this contract classes as MAJOR.

`safe` maps **nothing**. It is not a table restating the defaults; it is the absence of a mapping,
so with `profile` unset or `safe` every knob resolves on exactly the path it did before this knob
existed and the diagnostics surface is byte-for-byte unchanged. An unrecognized value degrades to
`safe` rather than to a partial preset. `recommended` sets `editContextLines` 2, `formatOnEdit`
suggest, `ruleset` base, `moduleAwareness` suggest, `referenceSurfacing` counts; `strict` adds
`keepLastN` 30, `perFileCap` 0, `scopeToEdit` false.

Four values are deliberately in **no** profile, each a decision rather than an omission:
`nativeServe` stays `off` (it is a workaround for an upstream client bug -- a preset must not put
that in front of more users); `enableStats` stays `false` (`logs/stats.jsonl` records absolute
paths today, and redaction ships before any profile turns telemetry on); `formatOnEdit = apply`
appears nowhere (it is the one mode that rewrites your file); and `orgPolicy` stays empty (a
profile cannot hardcode a site path -- `strict` names the slot, an administrator fills it).
`timeoutMs` is unchanged in every profile for a **measured** reason: the warm edit-to-diagnostic
round-trip under `ruleset = base` measured a p95 of 3292 ms over 20 samples (median 2678 ms),
leaving about 34% headroom under the shipped 5000 ms, so the broader rule set did not need a
bigger budget.

**Evolution policy, stated so a later change is not a semver argument:** profile mappings are
curated and **MAY change in a MINOR**; an explicitly-set knob is never affected by such a change.

**Commands.** The plugin ships a command surface for the first time: `/powershell-lsp:doctor` (the
full preflight report), `/powershell-lsp:status` (the same checks, one line each), and
`/powershell-lsp:scan <path>` (an explicit whole-path scan with the same engine the edit hook
uses). Each wraps a script that already shipped; no analysis code changed.

**The doctor answers three questions it could not before.** *Active ruleset surface* reports which
rules are really applied here and which config layer won -- resolved through the shipped resolver,
not a second copy of the precedence -- which is what explains "I set `ruleset = base` and still see
nothing new" (usually a repo-local settings file legitimately winning). *Test diagnostic observed
end-to-end* sends a synthetic temp file with a deliberate defect through the warm daemon and
requires the expected finding back; the existing liveness ping is answered **without** touching the
language server, so a daemon can be alive, answering, and analyzing nothing. *Native-serve status*
reports whether navigation is on, as a default check that spawns nothing (the heavier removability
probe stays opt-in behind `-ProbeNativeServe`). The default doctor goes from 6 checks to 9.

**One behavior change worth flagging.** The end-to-end check is the only check that can report
`FAIL` for a *settled* analysis that produced nothing -- so a doctor run on a genuinely broken
install may now exit 1 where it previously exited 0. That is the point: "analyzed, clean" when
nothing was analyzed is the failure this plugin exists to prevent. The `pass` / `fail` / `unknown`
vocabulary is unchanged and **`unknown` is still never a failure**; every could-not-determine path
in the new checks reports `unknown`.

**Documentation.** The README is restructured around three capabilities -- live edit diagnostics,
native code navigation, repository/CI validation -- and drops from 1018 to under 500 lines by
de-duplicating per-knob prose that already existed in full in `docs/configuration.md`; nothing was
reduced, only relocated. A sentence beside the badges now names what the attestation does **not**
cover (the boundary text was 936 lines below them). The live surface's PostToolUse-only coverage is
stated where a reader meets it. `TRUST.md` gains a rationale for `-ExecutionPolicy Bypass` beside
the posture it alarms readers about, naming all four hook entry points. `docs/configuration.md`
now indexes every knob (its own table of contents had listed 17 while documenting all of them).
The roadmap splits into a short public `ROADMAP.md` and the full `docs/decision-ledger.md`, with a
pointer stub at the old path so existing links resolve.

## [1.27.3] - 2026-07-29
PATCH: **the `ManifestConsistency` under-declared-export check was REMOVED.** Rung 2 of
`Test-ManifestConsistency` -- which reported every function a module defines and exports that its
manifest's `FunctionsToExport` omits -- no longer exists. This is a **removal**: not a narrowing,
not a severity change, and not an `orgPolicy` default. No configuration brings it back.

**Why: it was wrong by design, not buggy.** For a determinate non-wildcard `FunctionsToExport`, the
manifest **is** the export gate -- it *determines* the exported surface rather than describing it --
so "defined by the module but absent from the manifest" is the normal, correct state of every
well-formed module that keeps private functions. The rung reported correctness as a defect.

**Measured before removal, on a 36-module live oracle** (169 `.psd1` manifests across six
`PSModulePath` roots plus this repo; the denominator is the 36 with a resolvable `RootModule`):
**911 hits, of which ZERO named a function PowerShell actually exports -- 100% false positive, 0
true positives.** The one candidate narrowing -- fire only where the `.psm1` carries an explicit
`Export-ModuleMember` -- still measured **96.15% FP** (25 of its 26 hits being PowerShellGet's
deliberately-non-manifest OneGet provider surface), so there was no sound subclass to narrow *to*.
The removal was re-measured against the same oracle before and after: **911 -> 0**, with the
orphan-export and alias-orphan rungs unchanged at **2** and **1** hits, asserted identical
row-for-row rather than by count alone.

A known-100%-false-positive rung retained in a shipping ruleset teaches users to ignore the
diagnostic surface entirely, which costs the *sound* rungs their signal. That, not the 911 lines of
noise, is why it is gone.

Removal was a **ruled decision by Mike Andersen, 2026-07-29**, taken on the dispatch 000161
measurement; that dispatch deliberately refused to delete shipped behaviour on its own authority and
surfaced the decision instead.

Two consequences ship with it. The user-facing `ManifestConsistency` rule rationale drops its "or an
exported one is unlisted" clause, which described the removed rung -- a removal has to reach the
rationale, not just the emitter, or the plugin documents a check it does not run. And this repo's own
`tests/corpus/samples/module/typo-export` fixture expectation is deliberately **inverted**: it was
the only true positive in the entire oracle, true by construction, and it now pins that the rung
**stays** silent.

**Unchanged:** the orphan-export and alias-orphan rungs; the manifest read paths (proven sound on
four `FunctionsToExport` forms by 000161 -- they were never broken); all **19** `userConfig` knobs;
the **53**-rule PSSA base surface; the **6** plugin-owned finders (`ManifestConsistency` still exists
and still fires on its other two rungs); and the hook/registration contract. No `orgPolicy` entry was
added or changed -- papering a source defect with config would make the ruleset's honesty conditional
on deployment.

## [1.27.2] - 2026-07-27
PATCH: **`ManifestConsistency` reads multi-name `Export-ModuleMember` lists.** The export-name
collector accepted only individual string constants, so a multi-name export list -- in either
idiomatic form, `-Function 'A', 'B'` (one `ArrayLiteralAst`) or `-Function @('A','B')` (one
`ArrayExpressionAst`) -- was skipped whole. The collected set stayed empty, which the caller reads
as "no explicit `Export-ModuleMember`" and answers with export-all, so every **private** function
was reported as an under-declared export. Measured on the plugin's own
`scripts/lib/dogfood-reader.psm1`: **13 false warnings, one per private function**, against a real
surface of 12 exports; now **0**, with the modelled surface matching `Import-Module` ground truth
exactly. `-Cmdlet` was measured to share the same collection path and is fixed with it; `-Alias`
names are still deliberately not folded into the function set (the BurntToast shape, v1.24.x).
A list carrying any non-literal element degrades to silence rather than resolving the literal half
-- a partial set read as complete would be a worse defect than the silence it replaced.

> **Known limitation, measured this cycle and deliberately NOT fixed here.** On a live 26-module
> oracle the `ManifestConsistency` under-declared-export check remains dominated by a *second,
> unrelated* false-positive class: a manifest's `FunctionsToExport` is the final export gate, so a
> function the module defines but the manifest omits is simply **not exported** -- yet it is still
> reported as under-declared. After the fix above, **909 of 910** remaining hits are confirmed false
> positives (**0** true positives), each verified against the module's real surface via
> `Import-Module`. This fix removes 178 of the original 1088 hits; it does not on its own make the
> check trustworthy on real-world modules. Full per-module triage is recorded in the dispatch
> 000159 outbox.

## [1.27.1] - 2026-07-25
PATCH: **marketplace listing corrected -- native nav is SHIPPED, not roadmap.** The embedded plugin
`description` in `.claude-plugin/marketplace.json` still told a prospective installer that
"Hover/definition/references are on the roadmap". That has been false since **v1.23.0** shipped the
opt-in `nativeServe` handshake shim, so the listing understated the plugin to exactly the audience
deciding whether to install it. Corrected to the shipped reality already stated in
`.claude-plugin/plugin.json`: hover, go-to-definition and find-references serve natively through an
opt-in handshake shim (`userConfig nativeServe`, **off by default**). **One clause, one file** --
no code, no knob, no capture-format change, no other manifest field touched, and **no version move
made by the authoring change itself**: dispatch 000154 classified this entry PATCH and cut it,
moving both manifests in lockstep to 1.27.1. See dispatch 000153 leg 3.

## [1.27.0] - 2026-07-22
MINOR: **org policy layer -- a centrally-managed settings voice above the repo-local file
(`orgPolicy`).** A new `userConfig` knob takes an **absolute** path to an organization's
`PSScriptAnalyzerSettings.psd1` and **enforces its `ExcludeRules`**: they are applied client-side
as a **final subtractive drop** over the surfaced findings, *after* every local filter, at BOTH
client surface points (the pre-PSSA early exit and the daemon-response path) and before the hook
emit and the dogfood capture -- so one rule covers the live surface, the capture, and the SARIF
scan. A rule the organization excludes therefore **cannot be re-enabled** by a repo-local
`PSScriptAnalyzerSettings.psd1` or by `ruleInclude`. The policy's own `IncludeRules` stay
**advisory** and repo-local wins the include path: an org can take a rule away, it cannot force one
on. **Fails open, never silently** -- a missing, unreadable, unparseable, or relative policy path
applies no exclusions and logs exactly one warning rather than blocking the edit; the file is read
through `Import-PowerShellDataFile` (PowerShell's **restricted**, data-only parser), so a policy
can never execute code. Parse errors are never dropped (a syntax error is not a rule) and rule
names match case-insensitively. The knob is **off by default (empty)**, every branch is gated on it
being set, and the daemon is structurally untouched -- with `orgPolicy` unset the surfaced output
is **byte-identical** to the previous build, proven over the shipped corpus records. Adds
`Import-OrgPolicyExcludes`, `Select-OrgPolicyFiltered`, and `Get-DiagnosticRuleCode` to
`scripts/lib/lsp-common.ps1`; `CONTRACT.md` gains one FROZEN-KNOBS row (proven RED then GREEN
against the set-equality guard), with matching README and `docs/configuration.md#orgpolicy`
entries. 22 new unit tests across three families (off-identity, a 10-case precedence matrix,
fail-open degrade), four of them mutation-proven RED. See dispatch 000142 (design recorded in
000135).

PATCH: **idiom guidance slice 2 -- hand-authored rationale overrides on the five default-surface
rules whose derived text explained nothing.** Guidance quality only: **no new detection, no new
rule, no new owned code, no knob**, riding the existing v1.24.0 rationale channel. Slice 1 (000125)
covered a 4-code idiom family that was mostly **opt-in** (`base`-only); slice 2 covers the rules the
median user actually reads -- five members of the **PSES-15 live default surface**, each proven to
already fire by its presence in the **derived** corpus snapshots (`tests/corpus/expected`, produced
by `Update-CorpusSnapshots.ps1` from real analyzer runs, never hand-authored). Replaced because the
auto-derived PSScriptAnalyzer text is circular or pure mechanism: `PSAvoidDefaultValueSwitchParameter`
("Switch parameter should not default to true" restates the rule name), `PSAvoidUsingCmdletAliases`
(defines what an alias *is*, and truncates mid-sentence), `PSPossibleIncorrectComparisonWithNull`
(states the rule's own predicate, never the trap), `PSUseApprovedVerbs` (circular plus "in line with
best practices"), and `PSUseDeclaredVarsMoreThanAssignments` (restates the check). Each replacement
names a concrete consequence and a fix, and the two most falsifiable claims were **verified on-host
rather than asserted**: `curl`/`wget` resolve to `Invoke-WebRequest` aliases under Windows PowerShell
5.1 but not under PowerShell 7, and `@(1, $null, 2) -eq $null` returns an `Object[]`, not a boolean.
Override count 4 -> 9; `regen-rule-rationales.ps1 -Check` green at pin 1.25.0 (59 entries = 53 PSSA +
6 owned). Three Integration assertions that pinned the *derived* `PSUseApprovedVerbs` text now pin
the override and assert the derived text is gone -- the live-daemon proof that the layer reaches the
default surface. See dispatch 000142.

PATCH (docs): **documented release Gate 5 and corrected the tag-command convention.** The release
runbook described four pipeline gates while the shipped workflow runs five: `docs/RELEASING.md` now
documents **Gate 5 -- tree-vs-published parity** (the dispatch 000076 divergence guard,
`release/Test-PublishedParity.ps1`, which refuses a release that is behind the version the
marketplace actually resolves from the `origin/main` tip) and every "four gates" count is corrected
to five. Separately, printed `git tag` / `git push origin v<version>` commands are no longer
presented anywhere as the release path: the pipeline cuts the tag (gitsign-signed, SLSA-attested),
and the printed pair is labelled a MANUAL FALLBACK for an unavailable pipeline. Corrected in
`docs/RELEASING.md` (a new standing callout plus step 3) and in `scripts/bump-version.ps1`, whose
post-bump output now prints the workflow trigger first and the fallback second, with the warning
that a hand-cut tag is unsigned, unattested, and blocks the pipeline via Gate 2 until deleted. The
v1.26.0 release proved the hazard: a pre-existing `v1.26.0` tag had to be deleted before the
pipeline could cut its own. `ROADMAP-powershell-lsp.md` is trued to v1.26.0-released ground truth in
the same change. Docs and printed text only -- no product code, knob, ruleset, rationale,
exit-code, `CONTRACT.md`, or version change; `bump-version.ps1`'s logic and exit codes are
untouched. See dispatch 000143.

## [1.26.0] - 2026-07-21
MINOR: **Flag an unfilled angle-bracket placeholder left on a command line (dispatch 000139, S3.4)**.
A new plugin-owned pre-PSSA finder, `CommandLinePlaceholder`, flags a literal `<Name>` left on a
command line -- a signature AI-era defect that is schema-valid to a human eye but a redirection-operator
parse error at run time. Detection is token-level over the tokens the parser pre-pass already produces
(`Find-CommandLinePlaceholder` in `scripts/lib/lsp-common.ps1`, wired at the `scripts/lsp-client.ps1`
seam): the reserved `<` input-redirection operator immediately abutting a bareword ending in `>`. It is
deliberately conservative (precision over recall): legitimate output redirection (`>`, `>>`, `2>&1`),
angle brackets inside strings / here-strings / comments, C#-style generics in strings, and the word
operators `-lt` / `-gt` never fire; a composite like `<owner>/<repo>` is not flagged. Re-entered under
the S3.4 measure-first bar and shipped only at a **measured 0% false-positive rate on a 281-file oracle**
(150 repo scripts + 131 installed-module scripts, zero hits). Adds an owned hand-authored rationale
(owned finders 5 -> 6), positive + negative corpus fixtures, and always-on additive behavior -- **no new
knob, no CONTRACT change, no `base.psd1` change**. The companion compatibility rules
(`PSUseCompatibleCommands` / `PSUseCompatibleTypes`) remain unshipped pending a target-profile decision.
PATCH: **Trust-evidence surface -- docs/trust.md assembles the verifiable-trust chain (dispatch 000137)**.
A new `docs/trust.md` gathers, in one evaluator-facing place, the release-integrity chain that was
already true but scattered: the keyless gitsign-signed tag and SLSA build-provenance over both release
assets (TRUST.md, docs/RELEASING.md, SECURITY.md), the CycloneDX SBOM generated from the real pins
(`release/New-PluginSbom.ps1`), the pinned and SHA-256-verified PSScriptAnalyzer, the measured 0% corpus
false-positive bar guarded on every CI run (`tests/PowerShellLsp.Corpus.Tests.ps1`; evidence bar
000091 / 000092 / 000125), the measured latency in `docs/benchmarks.md`, the SHA-pinned code-scanning
workflow, and the generated per-finding rule rationale (E2.5). README gains a short "Why trust this
release" pointer to it. Docs-only: no code, no version cut; every claim links to a file in the tree or a
released artifact.
PATCH: **Continuity and governance docs -- operational per-surface failure/recovery and a
second-maintainer on-ramp (dispatch 000136)**. Adds `docs/CONTINUITY.md` (the operational companion
to the root `CONTINUITY.md`: for each surface, what breaks if the sole maintainer disappears and the
concrete recovery path) and `MAINTAINERS.md` (a second-maintainer onboarding checklist: access
grants, running and verifying a release, and the strategic-dispatch hub relationship stated honestly
as external to this repo). Reconciles the docs so the release runbook lives in exactly one place
(`docs/RELEASING.md`) and the continuity/maintainer docs link to it. Documents the keyless custody
story explicitly: there is no long-lived signing key or stored release secret to hand off. Docs only;
zero code, workflow, or contract change. Classified PATCH by the 000141 classification pass: the docs
are a user-visible addition with no contract change, which the versioning policy above places at PATCH
rather than no-bump. It rides the v1.26.0 cut, whose MINOR classification is set by the 000139 entry
above under highest-wins.

## [1.25.1] - 2026-07-18
PATCH: **Raise the SCAN daemon's settle cap so the largest scripts settle on ubuntu (dispatch 000133)**.
Chartered by 000132, which identified the true binding per-file budget as the daemon's own settle cap
`MaxWaitMs` (`scripts/pses-daemon.ps1`, default 5000 ms) -- NOT the client `timeoutMs`. On a loaded ubuntu-24.04
runner the largest scripts (`lib/lsp-common.ps1`, `ensure-pssa.ps1`, ~6-7 s of PSScriptAnalyzer analysis)
settle right at that 5000 ms boundary and were intermittently reported INCOMPLETE, reddening the code-scanning
run. The fix gives the SCAN's daemon a larger settle cap while the in-agent daemon keeps 5000, so scan
completeness is fixed with ZERO in-agent edit-latency cost (option B). `MaxWaitMs` is now plumbed additively
through the launch path (`session-start.ps1` -> `Start-PsesDaemonDetached` -> the daemon) and forwarded ONLY
by `Start-ScanDaemon`, at **15000 ms**; the in-agent launch emits no `-MaxWaitMs` arg, so its daemon is
byte-identical to before (the 5000 default stands). It is an INTERNAL daemon-level setting, NOT a userConfig
knob -- never sourced from `CLAUDE_PLUGIN_OPTION_*`, absent from `plugin.json`, no CONTRACT surface change.

15000 ms is sized from measurement, not a round number: across four `diagnostic_timing` runs on ubuntu-24.04
the binding file `lib/lsp-common.ps1` settled at 5643-8784 ms client round-trip (a 1.56x run-to-run swing;
~1.5 s of that is spawn/connect/read overhead, so ~7.3 s worst-case daemon settle). 15000 is ~2.05x that
worst settle / 1.71x the worst round-trip -- above the observed variance envelope with a further safety
factor for an unobserved heavier-load tail, and ~2x the typical ~7.3 s settle so a variance spike stays under
the ceiling rather than crossing it. The client caps are UNCHANGED and stay strictly above the settle cap
(`Invoke-ScanFileDiagnostics` `timeoutMs` 18000 < `lsp-scan.ps1` `-TimeoutMs` 25000; both > 15000), and were
proven non-truncating at this cap in the measurement runs. No exit code changed (000130 stop). The 000024
never-silent red is retained: a file whose analysis genuinely cannot settle within the cap is still reported
NOT analyzed AFTER upload -- no retry, no backoff, no excluded file.

PATCH: **INCOMPLETE-scan correctness + the true per-file budget identified (dispatch 000132)**.
Chartered by 000131. Two fixes and a measurement, and NO budget moved. (1) Never-silent (000024): a file whose
analysis the client process cap KILLS (`Invoke-ScanHook`'s `WaitForExit`) is now recorded NOT analyzed instead of
reading as clean -- previously the kill returned empty stdout and left the file marked analyzed, so a cap-killed file
passed as a clean one. It now flows into the same not-analyzed naming path 000131 built and the scan takes the
INCOMPLETE (exit 4) branch. No exit code changed. (2) Each named unanalyzed file now carries the ELAPSED ms it ran
before the budget cut it, across all three 000131 surfaces (stderr line, SARIF `toolExecutionNotification`, workflow
annotation -- the elapsed rides in the notification text, so the annotation surfaces it for free); a COMPLETE scan
still grows no notifications. (3) An off-by-default `-DiagnosticTiming` instrument (an opt-in `workflow_dispatch`
input on the code-scanning workflow) emits how long each file's analysis ran, for every file; it changes NO budget.

The measurement corrected the budget-identification a THIRD time, and is why NO budget moved. 000129/000130/000131
and this dispatch's own charter all named the CLIENT budget (`timeoutMs` 18000 ms / the 25000 ms cap); the actual
binding per-file budget is the daemon's OWN settle cap `MaxWaitMs` (`scripts/pses-daemon.ps1`, default 5000 ms) --
the hard cap on waiting for a settled publish, which no client-side budget reaches (nothing wires `timeoutMs` to it).
On ubuntu-24.04 `ensure-pssa.ps1` (~5.9 s) and `lib/lsp-common.ps1` (~6.0 s, the largest script) settle right at that
5000 ms boundary, so they intermittently fail to settle and are reported INCOMPLETE. Raising a client budget cannot
fix this; the fix is to raise `MaxWaitMs` (a daemon-wide setting that also governs in-agent edit latency), chartered
as dispatch 000133. The 000024 never-silent red stays honest until the real cause is fixed -- no retry, no backoff,
no excluded file.

PATCH: **INCOMPLETE-scan diagnosability -- name the file(s) a scan could not analyze (dispatch 000131)**.
When `scripts/lsp-scan.ps1` reports an INCOMPLETE scan (exit 4: one or more files could not be analyzed),
it now NAMES those files instead of emitting only a count. In SARIF mode each unanalyzed file becomes a
`runs[].invocations[].toolExecutionNotifications[]` entry -- a tool-status notification, NOT a result, so
the finding set stays byte-identical and GitHub code scanning still ingests the SARIF (no spurious alert)
-- carrying the file's `SRCROOT`-relative navigable location. The incomplete-scan stderr line and the
`powershell-lsp-code-scanning.yml` workflow annotation also list the names, so a future INCOMPLETE is
diagnosable from the Actions tab without a local repro. The enumeration is bounded (first 50 sorted
names, then a stated total) so a pathological large-tree scan cannot flood the log; text mode continues
to list every name. A COMPLETE scan grows no notifications, so its SARIF is unchanged.

This closes the count-without-names gap that made the persistent ubuntu-24.04 code-scanning INCOMPLETE
impossible to attribute to a file. The 000024 never-silent red is retained unchanged -- a genuine
INCOMPLETE still fails the run AFTER the SARIF is uploaded and archived, with no retry and no backoff --
and no exit code changed. The per-file analysis budgets are deliberately UNCHANGED (daemon `timeoutMs`
18000 ms, client per-file cap `-TimeoutMs` 25000 ms, daemon warm-up 180000 ms): the slowest local corpus
file measured 6237 ms (35 percent of the budget) and both in-hand evidence bases (the cap/budget ratio
and the measured local worst case) show the budget generous, not tight, so the evidence does not support
a specific new value. The newly-surfaced names are the prerequisite for an evidence-based budget change
in a follow-up.

## [1.25.0] - 2026-07-17
MINOR: **reference surfacing -- a knob-gated "who references this function" fact layer (`referenceSurfacing`
knob)**. A new off-by-default `userConfig` knob, `referenceSurfacing`, surfaces **bare per-function facts**
for the edited file, drawn from a **session workspace index** the daemon builds ONCE in the background: for a
function you DEFINE, how many OTHER workspace files reference it and whether it is exported; for a command you
CALL whose UNIQUE definition is elsewhere, where it is defined. The facts ride the existing
`additionalContext` channel in a distinct `References:` section as additive **Information** -- they are
FACTS, not diagnostics (a reference count names nothing wrong), so there is **no new diagnostic rule code, no
"fix", and no new status token** (the 1.2 taxonomy is untouched) and `rulesets/rule-rationales.psd1` is
byte-for-byte unchanged. It fires only on positive, unambiguous identification and stays **silent** on every
ambiguity (a dynamic invocation, a dynamic dot-source or import, a string-built name, a name defined in more
than one workspace file, a name that shadows a builtin cmdlet). The design is settled by the 000127 leg-1
survey: a per-edit full workspace scan measured 11x-36x over the 150 ms budget, so the daemon builds a
**session-start-style index** instead (per-edit cost is O(edited file) -- ~3.9 ms p50 at 1000 files, because
repo size is not in the per-edit path -- re-measured here at p50 ~44 ms on a representative file and ~144 ms
on the plugin's own largest file, both under the 150 ms bar), and the edited file's parse is **shared** with
module awareness rather than duplicated. When `off` (the default) the daemon builds no index and the
diagnostics surface is byte-for-byte unchanged. Shipped as a **deliberate MINOR** (a new frozen knob name,
amended in lockstep into the manifest, `CONTRACT.md`, and `README.md`); the 000087/000101 knob precedent.
Dispatch 000128 leg 1.

MINOR: **AliasesToExport orphan detection -- the always-on ManifestConsistency check now cross-references
exported ALIASES (PL-6 slice 2)**. The existing, always-on `ManifestConsistency` finder gains a third check:
an alias listed in a manifest's `AliasesToExport` with no matching literal `Set-Alias` / `New-Alias`
definition in the module surfaces a Warning under the **same `ManifestConsistency` rule code** -- **no new
owned diagnostic code and no rationale-table change**. Like the slice-1 function-export checks it is
deterministic static `.psd1` / `.psm1` analysis and rides **no knob**. It fires only when the alias surface
is fully determinate and degrades to **silence** on every shape that could define or export an alias
invisibly -- a dynamic invocation (Pester's `& $SafeCommands['Set-Alias']`), a non-literal alias name, an
`Export-ModuleMember -Alias` (the BurntToast shape), a nested module, or a dot-source -- so it never
false-fires on a known-good module. Measured **0% false-positive** on an enlarged oracle (the machine's 79
installed manifests plus four new corpus fixtures modeling the two probe shapes the 000127 leg-4 survey
named), which is the evidence bar this project holds a new detection to (000091 / 000092 / 000125). Also
corrects a latent slice-1 false positive: an `Export-ModuleMember -Alias` name is no longer folded into the
exported-**function** set (where it wrongly read as an under-declared function). Dispatch 000128 leg 3.

## [1.24.3] - 2026-07-16
PATCH: **Base-ruleset curation slice 2 -- `PSUseOutputTypeCorrectly` excluded, so the opt-in `base`
surface is now 0% measured false-positive on the known-good oracle, with the default `pses-default`
surface byte-for-byte unchanged.** The 000125 leg-3 ranking re-ran the 000091 quality wave's method
against the live v1.24.x surface and returned a single verdict: `PSUseOutputTypeCorrectly` was the
SOLE rule in the base-54 set that fired on the known-good false-positive oracle -- two pedantic
Information hits (`New-ServerConfig` -> `OrderedDictionary`, `Format-ReportHeader` -> `String`), both
on correct functions the rule simply wants an `[OutputType()]` attribute on, plus zero hits on the
plugin's own source. The rule never checks that the code is wrong, so on correct code it is pure
pedantry with no defect behind it and no per-rule config that fixes the misfire. Excluding it takes
`rulesets/base.psd1` from **54 -> 53** rules and makes the ENTIRE `base` surface 0% measured
false-positive on that oracle. This is the second independent observation of the same wave method
(000091 -> 000092 was the first), which is the evidence bar 000092 set for an exclude-only slice;
000092 had deferred this rule once on volume grounds.

EXCLUDE-ONLY, on the existing 000092 mechanism: the rule is added as a named, evidence-citing entry to
`$BaseRuleExclusions` in `scripts/regen-base-ruleset.ps1`, and `rulesets/base.psd1` is REGENERATED from
the generator (default-on minus the compatibility-profile family minus the exclude list), never
hand-edited; `regen -Check` stays green, preserving the 000087 deterministic-enumeration property. The
rationale table derives its PSSA half from `base.psd1`, so `rulesets/rule-rationales.psd1` is
regenerated in the same reviewed diff: **58** entries (**53** auto-derived + **5** hand-authored owned
finders), `pssa_count` 54 -> 53, with all **4** overrides from the v1.24.2 layer intact. No rule is
added, no knob, no `CONTRACT.md` change, no pin change.

`pses-default` is byte-for-byte unchanged. `PSUseOutputTypeCorrectly` is BASE-ONLY: it is not in PSES's
built-in 15-rule no-settings allow-list (dispatch 000085 `AnalysisService.s_defaultRules`, re-resolved
from disk by reflection on the vendored PSES 4.6.0 for this slice), so the default surface never
evaluates it and cannot move. All four exclusions are now base-only by the same probe. The three
Error-severity security rules (`PSAvoidUsingComputerNameHardcoded` /
`PSAvoidUsingConvertToSecureStringWithPlainText` / `PSAvoidUsingUsernameAndPasswordParams`),
`PSAvoidUsingWriteHost`, and all four override codes are RETAINED.

Classified PATCH on the direct [1.21.1] precedent -- the same exclude-only curation of the same opt-in
ruleset by the same mechanism. The frozen CONTRACT surface (the `ruleset` knob name, its enum values,
its default) is untouched: `base`'s rule content is a regenerable implementation detail, not part of
the frozen surface. Under the on-disk policy this adds no new capability (no `userConfig` knob, no
added diagnostics feature, no newly CI-verified platform), so MINOR does not apply; it is a
noise-reduction refinement of an opt-in ruleset with the default untouched. Unlike the [1.24.2]
override layer -- which deliberately did NOT lean on [1.21.1] because its `PSShouldProcess` override
changed rendered text on the default surface -- this slice rests on exactly the default-surface
invariance [1.21.1] rests on. See dispatch 000126.

### Changed

- **`rulesets/base.psd1` -- 54 -> 53 rules.** Regenerated (not hand-edited) from the fourth
  `$BaseRuleExclusions` entry in `scripts/regen-base-ruleset.ps1` -- still the pinned analyzer's
  default-on set minus `PSUseCompatible*`, now also minus `PSUseOutputTypeCorrectly`.
- **`rulesets/rule-rationales.psd1` -- 59 -> 58 entries** (`pssa_count` 54 -> 53). Regenerated through
  `scripts/regen-rule-rationales.ps1`, which derives its PSSA half from `base.psd1`. The
  `PSUseOutputTypeCorrectly` entry is gone; `owned_count` (5) and `override_count` (4) are unchanged.
  A code with no entry surfaces its finding with no `why:` line -- degrade, never fabricate -- so a
  user who broadens the live surface with their own `PSScriptAnalyzerSettings.psd1` and makes this
  rule fire now sees the finding without a rationale line, the same designed path
  `PSUseSingularNouns` has taken since v1.21.1.

## [1.24.2] - 2026-07-10
PATCH: **rule-rationale override layer -- four idiom-family rules now render hand-authored guidance
instead of their weak auto-derived text.** The v1.24.0 rationale table derives each PSScriptAnalyzer
rule's "why" line from the analyzer's own CommonName + Description. For a few idiom rules that text is
circular (the why restates the rule name) or pure mechanism (it describes the checker, not the idiom,
and offers no fix). This adds an owned OVERRIDE layer (dispatch 000125, N1.1 slice 1) that replaces the
derived text for four codes -- `PSShouldProcess`, `PSUseSupportsShouldProcess`, `PSAvoidUsingWriteHost`,
and `PSAvoidShouldContinueWithoutForce` -- with a why+fix rationale. `PSShouldProcess` is inside the
PSES-15 default surface, so its improved line reaches every user; the other three are base-only (opt-in).
The `Write-Host` guidance leads with `Write-Information` / `Write-Verbose`, never `Write-Output` (which
writes to the success pipeline and would change a function's return value).

The overrides are hand-authored in `scripts/regen-rule-rationales.ps1` and the table regenerated, never
hand-edited; the artifact records the layer (`overrides`, `override_count = 4`) and the derived text each
override replaced, so a `-Check` run goes RED if an override is dropped, retargeted, edited only in the
artifact, or if a pin bump changes the derived text under an override. The generator throws if any
override equals the text it replaces (a vacuous override). Every override key is a base-54 PSSA rule,
never an owned finder, so an override can never shadow a plugin-owned rationale.

Classified PATCH: a wording-quality improvement to rationale lines that already render, not a new
capability -- **no `userConfig` knob**, **no `CONTRACT.md` change**, **no new detection rule**, and **no
change to which rules run** (`base.psd1`, the PSES-15 default surface, and the pinned analyzer are all
unchanged). Same content-fix class as the [1.23.1] wording PATCH and the [1.24.1] rationale-coverage
PATCH. This deliberately does NOT lean on the [1.21.1] precedent: that PATCH rested on the *default*
`pses-default` surface being byte-for-byte unchanged, whereas the `PSShouldProcess` override here does
change rendered text on the default surface -- so PATCH is justified by "no new capability, better wording
on findings that already render," not by default-surface invariance. See dispatch 000125.

## [1.24.1] - 2026-07-09
PATCH: **rule-rationale coverage completed -- the plugin's fifth owned code, `ManifestConsistency`,
now carries a rationale line.** v1.24.0 shipped the rationale feature with a recorded gap: four of the
five plugin-owned finders had a hand-authored entry, and `ManifestConsistency` rode the
graceful-degrade path with none, so its finding surfaced with no `why:` line. That entry is now
hand-authored in `scripts/regen-rule-rationales.ps1` and the table regenerated, so
`rulesets/rule-rationales.psd1` carries **59** entries -- the **54** auto-derived `rulesets/base.psd1`
PSScriptAnalyzer rationales at the pinned 1.25.0, plus the **5** hand-authored owned finders
(`BashIsm`, `ManifestConsistency`, `ModuleNotInstalled`, `NonAsciiChar`, `PS7OnlySyntax`). The plugin's
whole surfaceable rule set is now covered.

The rationale names **both halves** of what the finder actually detects -- a manifest that lists a
function the module never defines, and a function the module defines and exports that
`FunctionsToExport` omits -- because one code carries both findings. It deliberately does not claim the
module is broken: an **indeterminate** manifest (a `'*'` wildcard export, an empty `FunctionsToExport`,
a dot-sourced or dynamic export, an unparseable module) degrades to a prose note *before* any finding
is emitted, and `lsp-client.ps1` routes that note away from the diagnostics stream, so it never
acquires a rationale. An integration guard now pins that separation: were it ever removed, the
"the lists disagree" text would render on a note that says the opposite, and the test goes RED.

Nothing else moves. The **graceful-degrade path is unchanged** and still load-bearing -- a rule with no
entry (any PSScriptAnalyzer rule outside the `base.psd1` surface, such as one a user's own
`PSScriptAnalyzerSettings.psd1` enables) surfaces its finding with no rationale line, never fabricated,
never blocking. A **clean file still emits nothing**, and per-rule dedup is untouched. There is **no
`userConfig` knob**, **no `CONTRACT.md` change**, and **no change to which rules run**. Classified
PATCH: the diagnostics capability shipped at v1.24.0, and this completes the coverage of its generated
data table rather than adding a capability -- the same reading under which v1.21.1 shipped a change to
the `base` rule surface as a PATCH. See dispatch 000124.

## [1.24.0] - 2026-07-08
MINOR: **rule-rationale strings -- each surfaced rule now carries a short "why this rule matters"
line on the existing `additionalContext` channel.** A finding used to arrive as
code/message/severity/line plus an optional `fix:`; it now also carries a `why:` line explaining what
the rule catches and what to do instead, so the agent reading the feedback has the reasoning, not just
the verdict. The rationale is **additive prose** on the channel that already exists.

The table (`rulesets/rule-rationales.psd1`) is **HYBRID** by evidence (dispatch 000120 survey):
the **54** rationales for the `rulesets/base.psd1` PSScriptAnalyzer surface are **auto-derived offline**
from the vendored pinned PSScriptAnalyzer 1.25.0 (`CommonName` + a whole-sentence prefix of
`Description`, 180-char budget, cut at a word boundary and never mid-word), while the **4**
plugin-owned finders -- which PSScriptAnalyzer knows nothing about -- are **hand-authored**, keyed by
the ruleId each finder actually emits (`BashIsm`, `PS7OnlySyntax`, `NonAsciiChar`,
`ModuleNotInstalled`). So the large analyzer surface stays zero-maintenance and pin-regenerable, and
the hand-maintained surface is exactly four entries.

Rendering is **deduplicated per RULE, not per finding**: if `PSUseApprovedVerbs` fires eight times in a
file its rationale renders **once**, at the first finding. That bounds the added context to roughly
(distinct rules in the file) x 180 chars rather than (findings) x 180.

The table is **GENERATED, never hand-edited**: `scripts/regen-rule-rationales.ps1` writes it, and
`-Check` re-derives and diffs it against the shipped file (exit 0 match / 1 drift), mirroring
`regen-base-ruleset.ps1`. A pin-coupled unit guard asserts the shipped table's recorded pin equals the
pin in `scripts/ensure-pssa.ps1` and that its PSSA half is exactly the enumerated base surface, so a
pin bump or a base-ruleset edit goes RED until the table is regenerated in the same reviewed diff --
never silent staleness.

Two properties are preserved by construction. A **clean file still emits nothing**: rationales ride
only existing findings, and the table is not even loaded when a file has none, so a clean pass is
byte-identical to before (integration-proven). And a rule with **no entry degrades gracefully** -- its
finding is surfaced with no rationale line, never fabricated, never blocking (the plugin's fifth owned
code, `ManifestConsistency`, has no entry today and exercises exactly this path).

**No `userConfig` knob** (default-on, additive prose; length is handled by the cap and the per-rule
dedup, not by a toggle), **no `CONTRACT.md` change** (Tier-1 1.1 knob names and 1.2 status tokens are
untouched, and the frozen "a clean pass adds nothing to `additionalContext`" property still holds), **no
new status token**, and **no change to which rules run** (`base.psd1`, the PSES-15 default surface, the
pinned analyzer, and the settings-precedence ladder are all unchanged). Rationales describe the surface;
they do not alter it. See dispatch 000121.

## [1.23.1] - 2026-07-04
PATCH (docs): **documented the Windows native-LSP launcher guard as a known issue.** On
Windows, Claude Code 2.1.196-2.1.200 refuses to start the plugin's registered LSP server -- a
launcher-level `where.exe` guard rejects the bare `pwsh` command pre-spawn -- so the opt-in
`nativeServe` navigation tier does not start there even with `nativeServe = shim`. The plugin's core
PostToolUse diagnostics are **unaffected** (a different, unguarded spawn path). Recorded in
`docs/upstream/claude-code-lsp-registration.md` and the README `nativeServe` section, scoped to Windows,
with the macOS/Linux real-client status noted as untested. This is an upstream Claude Code regression
(it also breaks the official `pyright-lsp` plugin), filed as `anthropics/claude-code#73961`; see dispatch
000107 for the survey. No product code, knob, `CONTRACT.md`, or version change.

PATCH (docs + manifest metadata): **capped every `userConfig` description for Claude Code
config-panel height stability, and relocated the full per-knob semantics into a new
`docs/configuration.md` reference.** Per verified dispatch 000109, the Claude Code `/plugin` config
panel renders the selected knob's entire description with no height cap, so a long description (up to
1295 chars) could push the panel past the terminal viewport on navigation and trip a renderer ghost-row
corruption. All 17 manifest descriptions are trimmed to a height-stable cap (<= 200 chars each -- stating
what the knob does, its allowed values with the default marked, and a pointer to its anchored section),
and the full semantics are relocated -- **nothing deleted** -- into `docs/configuration.md`, one anchored
section per knob, linked from the README. Behavior is byte-for-byte unchanged: no knob key, type, allowed
value, default, or runtime change (a non-description manifest-invariance check proves plugin.json is
unchanged outside the description fields). No product code, knob, `CONTRACT.md`, or version change.

## [1.23.0] - 2026-07-03
MINOR: **native-serve removability probe -- an opt-in, report-only `doctor.ps1 -ProbeNativeServe` check
that reports whether the `nativeServe` shim can be removed yet**. The report-only preflight doctor
(`scripts/doctor.ps1`) gains a seventh, OFF-BY-DEFAULT check (`-ProbeNativeServe`) that automates the
manual removability re-probe the 000103 shim documented as deferred. It launches PSES via the **direct**
launcher (`scripts/pses-stdio.ps1`, shim bypassed -- the removal lever) through a pwsh subprocess
(`scripts/probe-native-serve.ps1`), sends a Claude-Code-shaped `initialize` (rich caps,
`dynamicRegistration=true`), and inspects the initialize **result**: today PSES v4.6.0 defers the nav
providers to the `client/registerCapability` handshake the upstream `#1359` client bug breaks, so the
static result carries no hover / definition / references and the probe truthfully reports **"still
gated -- the shim remains needed"**; the day the direct launcher advertises those providers
**statically** it reports **"native serve now works directly -- the shim can be removed."** The
discriminator is the result CONTENT (are the nav providers advertised statically?), not a race against
the ~30 s stall, so it resolves as soon as the init result arrives (~1-2 s measured) within a bounded
~20 s init-result cap -- and, unlike the manual re-probe, it needs **no** real `claude -p`, so it runs
on every CI leg. It is **report-only** (like every doctor check) and NEVER `fail` -- a removability
diagnostic must not move the doctor's exit code: "still gated" (the expected state) is a PASS,
"removable" is a PASS, an indeterminate probe is UNKNOWN. **Decisions:** OQ1 -- switch-gated (a PSES
cold-start is too heavy for every doctor run, so the default doctor stays byte-for-byte at six checks
and the probe appears only when requested); OQ2 -- a 20 s init-result bound (~2.5x the 000102-measured
+7.8 s `registerCapability` landmark, ~10x the ~2 s observed init, half the 30 s gated stall; exceeding
it reports UNKNOWN, never a false "gated"); OQ3 -- MINOR (an added, opt-in diagnostics capability).
**Additive:** no new `userConfig` knob and no new status token (the 000027 drift-guards stay green), no
`CONTRACT.md` change, and the shim / launcher / diagnostics surface are byte-for-byte unchanged (the
probe only READS). Reuses the shipped framing lib (`Write-LspFrame` / `Read-LspFrame`) and the shim's
server->client answer table; the interactive stdio runs in a pwsh subprocess (the 000103 5.1-stdin
lesson). **Scope (honest):** the scripted client detects the STATIC-serving removability path; a purely
client-side `#1359` fix (Claude Code completing the dynamic-registration handshake) would not show here
and still needs the manual real-`claude -p` re-probe, which stays authoritative
(`docs/upstream/claude-code-lsp-registration.md`). Dispatch 000104.

MINOR: **native serve -- an opt-in handshake shim un-gates hover / go-to-definition / find-references
(`nativeServe` knob)**. A new off-by-default `userConfig` knob, `nativeServe`, ships a thin stdio proxy
(`scripts/pses-serve-shim.ps1`) that wraps the PSES launcher so Claude Code's **native** LSP client can serve
hover, go-to-definition, find-references, and documentSymbol on a `.ps1`/`.psm1`/`.psd1` -- un-gating the
navigation tier past the upstream `#1359`-class client init-handshake bug **without** waiting on the fix. When
`shim`, the proxy **patches** the forwarded `initialize` (disables `dynamicRegistration` so PSES advertises its
nav providers statically and sends no `client/registerCapability`; drops the params-level `workspaceFolders`
that trips a PSES v4.6.0 Linux init NRE; ensures a `rename` capability) and answers the residual
`workspace/configuration` + `window/workDoneProgress/create` locally, forwarding everything else on the LSP
transport **byte-exact** in both directions -- adding ~1-2 ms of framing per navigation round-trip (about 1% of
PSES's own per-op compute, measured). When `off` (default) the proxy is a **transparent pass-through**: every
LSP frame is relayed unchanged, no patch, no interception, so native nav stays gated exactly as before and the
diagnostics surface is byte-for-byte unchanged (the warm PostToolUse diagnostics hook is wholly independent of
this knob). Shipped as a **deliberate MINOR** (a new frozen knob name, amended in lockstep into the manifest,
`CONTRACT.md`, and `README.md`); no new status token (native nav rides the LSP transport, not the diagnostics
taxonomy) and no second PSES acquisition path. This is the contract-relevant event the 000075 forward-compat
note flagged (native serve becoming real), adjudicated here as a MINOR. The shim is a workaround for an upstream
client bug, so it is **default-off** and removable by pointing the `lspServers` command back at
`pses-stdio.ps1` (see `docs/upstream/claude-code-lsp-registration.md`). Recorded deviation (dispatch 000103):
the 000102 survey sketched `off` as delegating to `pses-stdio.ps1`; an in-process `& pses-stdio.ps1` breaks
PSES's stdio handoff, so `off` is a transparent **relay** instead (protocol-identical). Validated end-to-end by
a scripted-LSP-client Pester harness across the four-leg CI matrix (the ubuntu leg is the Linux #2300 init-patch
validation).

MINOR: **module awareness -- a knob-gated "command from an uninstalled module" hint (PL-6 slice 1)**.
A new off-by-default `userConfig` knob, `moduleAwareness`, adds an **Information**-severity diagnostic
when a command in the edited file is a positive hit in a **shipped, offline command->module index**
whose owning module is **not installed** on this machine -- so the call would fail to resolve. The
message is actionable (`'Get-MgUser' is exported by module 'Microsoft.Graph.Users', which is not
installed on this machine; Install-Module Microsoft.Graph.Users or import it`). This is **design B**
from the 000100 survey: the install-check is what earns an actionable message, because PowerShell
auto-loads an installed module, so an index-only design would be noise on any box that has the module.
The check is deterministic in exactly one direction -- **positive identification** -- and degrades to
**silence** on every ambiguity: it fires only on a literal index hit that is not a built-in, not
defined or literally dot-sourced or `#Requires`/manifest-`RequiredModules`/`Import-Module`-declared in
the file, and whose module is absent from a **once-per-session installed-modules snapshot** the daemon
takes on a background runspace **off the critical path** (it never delays first-edit diagnostics, and
the check stays silent until it is ready). A dynamic include (`. $path`, `Import-Module $name`)
suppresses the whole file -- it never guesses across something it cannot read. It **never writes** your
file and adds **no edit-path network or latency** (the index is a shipped artifact,
`rulesets/command-module-index.psd1`, derived offline from a vendored source snapshot by
`scripts/regen-command-module-index.ps1` and refreshed only by a deliberate release). The knob is an
**enum** (`off` | `suggest`, default `off`); with it **off the diagnostics surface is byte-for-byte
unchanged** (no index load, no snapshot, the check never runs). Shipped as a **deliberate MINOR** (a
new frozen knob name, amended in lockstep into the manifest, `CONTRACT.md`, and `README.md`); no new
status token and no second index/network path. Recorded design decision (dispatch 000101): the
dedicated, orthogonal knob is a considered deviation from the survey's OQ3 first pick (folding into the
`ruleset` enum) -- module awareness is about machine state, a different axis from which rule set runs.

MINOR: **format-on-edit `apply` activated -- the reserved enum value becomes a guarded write-back
(PL-8 slice 2)**. `formatOnEdit=apply` now WRITES the formatter's result back to the edited file --
the first feature that ever modifies the user's file. The entire risk lives in the write path, so it
is guarded by ALL of: a **stale-write compare-and-swap** (the file's bytes are hashed at format-input
time and re-checked immediately before the write, in the same daemon process that writes; any
concurrent modification ABORTS and the newer file always wins), an **atomic-or-abort** swap (temp file
+ `[IO.File]::Replace`, never a torn/partial file), **byte fidelity** (the original BOM state and
dominant EOL style are preserved -- the only byte delta is the formatting change itself), and
**no-change = no write** (an already-formatted file is never touched). A **mixed-line-ending** or
**non-UTF-8 (UTF-16)** file **aborts to a suggestion** rather than risk a broader rewrite (OQ4). An
applied write surfaces a **visibly distinct WAS-MODIFIED block** telling the agent to re-read before
its next edit; that turn's diagnostics, derived from the pre-apply bytes, are omitted to avoid stale
line numbers (OQ2). The **default stays `off`**, and **`off` and `suggest` are byte-for-byte unchanged**
(regression-proven); `apply` is **doubly opt-in** (only the exact value `apply`, never a boolean). Two
additive daemon->client `formatStatus` values (`applied`, `apply-aborted`) carry the outcome;
`formatStatus` is an output field, not a frozen status token, so no taxonomy amendment is needed.
`CONTRACT.md`, the README knob table + prose, and the `plugin.json` knob description are amended in
lockstep -- the 000027 drift-guards stay green because the knob NAME and diagnostics taxonomy are
unchanged. Reuses the 000059 formatter, settings resolution, diff engine, and vendored pinned-hash
PSSA -- no second acquisition path. Dispatch 000099.

## [1.22.0] - 2026-07-01
MINOR: **the AI-era rule pack, slice 2 -- 5.1-vs-7 syntax compatibility as a pre-PSSA AST
pass, always-on additive, no knob/token**. A new pre-PSSA check on the `powershell-lsp` source
flags PowerShell-7-only SYNTAX an AI commonly emits into a file that may still run on Windows
PowerShell 5.1: pipeline chains (`&&` / `||`), the ternary operator (`a ? b : c`), and the
null-coalescing / null-conditional family (`??` / `??=` / `?.` / `?[]`). It runs over the parser
AST the pre-pass already produces (reusing the 000060 seam in `scripts/lsp-client.ps1`), so it
costs no second parse. The load-bearing 0-FP: a finding is SUPPRESSED when the file honestly
declares `#Requires -Version 7` (or higher) via `ScriptRequirements.RequiredPSVersion` -- a file
that genuinely targets 7 is not a portability defect. MECHANISM: dispatch 000055's survey named
the settings channel (`PSUseCompatibleSyntax`) as its primary mechanism, but that predates
dispatch 000087 -- `rulesets/base.psd1` now deliberately EXCLUDES the whole `PSUseCompatible*`
family and the `ruleset` knob is a frozen CONTRACT surface, so the settings path collides; the
infrastructure-independent pre-PSSA AST pass is the clean path. Always-on additive: **no new
`userConfig` knob, no new status token** (the 000027 drift-guard stays green); the `powershell-lsp`
source label is reused with a distinct check id `PS7OnlySyntax` and is not a frozen surface, so
CONTRACT.md is byte-for-byte unchanged. PSSA acquisition and the pinned hash are untouched (a
pre-PSSA pass needs none of that). Compatible-CMDLET / -TYPE checks (`PSUseCompatibleCommands` /
`PSUseCompatibleTypes`) remain deferred (survey-ranked high-FP): this slice is SYNTAX-only. The
corpus grows by 4 known-bad (one per construct family) and 4 known-good (three 5.1-safe
equivalents plus the load-bearing `#Requires -Version 7` file using `&&` that must NOT flag); the
measured **0% false-positive rate and 100% true-positive coverage** hold on the wider set.

MINOR: **the AI-era rule pack, slice 3 (closes the pack) -- bash-isms in `.ps1` as a command-name
pre-PSSA AST pass, always-on additive, no knob/token**. A new pre-PSSA check on the `powershell-lsp`
source flags Unix/bash command NAMES an AI commonly drops into a `.ps1` -- `grep`, `sed`, `awk`,
`export`, `which`, `touch`, `chmod`, `chown`, `ln` -- which fail at runtime on a clean Windows host or
silently depend on Git Bash being on PATH. It walks the SAME parser AST the pre-pass already produces
(reusing the 000060/000096 seam in `scripts/lsp-client.ps1`), so it costs no second parse.
Command-NAME matching over `CommandAst` only: a `grep` inside a string literal or a comment never
flags. Two suppressions keep deliberate use silent (the load-bearing 0-FP design): an explicit
call-operator invocation (`& grep`, InvocationOperator Ampersand -- the "I mean the external binary"
signal, the analog of slice 2's `#Requires -Version 7` escape) and a same-file definition of the name
(a `function`, `Set-Alias`, or `New-Alias`). Severity is `Warning`, never `Error`: the residual
legitimate case is a genuinely-installed Unix tool on PATH. OWNERSHIP BOUNDARIES: `&&` / `||` belong
to slice 2's `PS7OnlySyntax`, and the PowerShell alias subset (`ls`, `cat`, `cp`, `mv`, `rm`, `echo`)
belongs to PSScriptAnalyzer's `PSAvoidUsingCmdletAliases` -- confirmed against the pinned PSSA 1.25.0
(zero `PSAvoidUsingCmdletAliases` hits on every name shipped here, on both hosts), so there is no
double-report; that alias subset is deliberately EXCLUDED. Always-on additive: **no new `userConfig`
knob, no new status token** (the 000027 drift-guard stays green); the `powershell-lsp` source label is
reused with a distinct check id `BashIsm` and is not a frozen surface, so CONTRACT.md is byte-for-byte
unchanged, and PSSA acquisition / the pinned hash are untouched (a pre-PSSA pass needs none of that).
Bash-ism findings ride the daemon MERGE path (not the parser-error early-exit), so a file carrying a
bash-ism still gets full PSScriptAnalyzer analysis. **With this slice merged the 000055 AI-era rule
pack is CLOSED**: slice 4 was already-covered (its BOM half is slice 1's non-ASCII rule; the indented
here-string closer is an existing parser error) and slice 5 (angle-bracket placeholders) stays
deferred on irreducible false-positives. The corpus grows by 11 known-bad `.txt` (one per shipped
name, a pipe-to-`grep`, and a bash-ism-plus-PSSA-issue merge-path case) and 7 known-good `clean`
samples (string-literal / comment mentions, idiomatic `Select-String` / `Get-ChildItem`, and the
load-bearing `& grep`, `function touch`, and `Set-Alias grep` suppression proofs -- all silent); the
measured **0% false-positive rate and 100% true-positive coverage** hold on the wider set.

### Added

- **PS7-only syntax compatibility check (`PS7OnlySyntax`).** A new pre-PSSA AST pass in
  `scripts/lib/lsp-common.ps1` (`Find-Ps7OnlySyntax`), seamed into `scripts/lsp-client.ps1` at the
  same point as the 000060 non-ASCII pass and over the same AST the parser pre-pass already
  produces. Detects `PipelineChainAst` (`&&` / `||`), `TernaryExpressionAst` (`a ? b : c`), the
  null-coalescing operator `??` (`BinaryExpressionAst` operator `QuestionQuestion`) and assignment
  `??=` (`AssignmentStatementAst` operator `QuestionQuestionEquals`), and the null-conditional
  `?.` / `?[]` (the `NullConditional` member / index forms). Findings carry source `powershell-lsp`,
  ruleId `PS7OnlySyntax`, severity `Warning`, and are SUPPRESSED for a file declaring
  `#Requires -Version 7`+. Detection is Windows PowerShell 5.1- and StrictMode-safe (type-name
  string checks, an enum-to-string operator compare, and a guarded `NullConditional` probe -- never
  a PS7 type/enum literal that would throw on 5.1). Unlike the non-ASCII pass, compat findings do
  NOT gate the parser-error early-exit: a 7-only-syntax file parses cleanly under the pwsh-7 daemon
  and still gets full PSScriptAnalyzer analysis. The standalone SARIF / CI scan (dispatch 000057)
  surfaces the finding automatically via its one-engine derivation (it runs the real
  `lsp-client.ps1`), needing no separate wiring.
- **Corpus coverage extended.** A new `compat` category with 4 known-bad `.txt` samples (pipeline
  chain, ternary, null-coalescing, null-conditional) and its own It-block asserting the
  `powershell-lsp` / `PS7OnlySyntax` source+rule, plus 4 known-good `clean` samples (three 5.1-safe
  equivalents and a `#Requires -Version 7` file using `&&` -- the host-awareness 0-FP proof,
  silent). The 0%-FP / 100%-TP guards hold on the wider set.
- **Bash-ism command-name check (`BashIsm`).** A new pre-PSSA AST pass in
  `scripts/lib/lsp-common.ps1` (`Find-BashIsm`, plus the `Get-AliasDefinitionNameFromCommand` helper),
  seamed into `scripts/lsp-client.ps1` at the same point as the 000060 non-ASCII and 000096 compat
  passes and over the same AST the parser pre-pass already produces. Flags `CommandAst` nodes whose
  command NAME is one of `grep`, `sed`, `awk`, `export`, `which`, `touch`, `chmod`, `chown`, `ln`.
  Findings carry source `powershell-lsp`, ruleId `BashIsm`, severity `Warning`, and are SUPPRESSED for
  an explicit `& name` call-operator invocation or a same-file definition of the name (function /
  `Set-Alias` / `New-Alias`). Detection is Windows PowerShell 5.1- and StrictMode-safe -- every AST
  type and member it touches (`CommandAst`, `FunctionDefinitionAst`, `GetCommandName()`,
  `InvocationOperator`) is core to both hosts, and it uses type-name string checks and an
  enum-to-string operator compare, never a type/enum literal. Unlike the non-ASCII pass, bash-ism
  findings do NOT gate the parser-error early-exit: a bash-ism file parses cleanly under the daemon and
  still gets full PSScriptAnalyzer analysis, so these ride the daemon merge path. The standalone SARIF
  / CI scan (dispatch 000057) surfaces the finding automatically via its one-engine derivation.
- **Corpus coverage extended (bash-isms).** A new `bashism` category with 11 known-bad `.txt` samples
  (one per shipped command name, a pipe-to-`grep`, and a bash-ism-plus-`PSPossibleIncorrectComparisonWithNull`
  file proving both findings surface on the merge path) and its own It-block asserting the
  `powershell-lsp` / `BashIsm` source+rule, plus a dedicated merge-path It-block and 7 known-good
  `clean` samples (string-literal and comment mentions, idiomatic `Select-String` / `Get-ChildItem`,
  and the load-bearing `& grep`, `function touch`, and `Set-Alias grep` suppression proofs -- all
  silent). The 0%-FP / 100%-TP guards hold on the wider set.
- **000055 AI-era rule pack CLOSED.** With slices 1 (non-ASCII smuggling, 000060), 2 (PS7-only syntax,
  000096), and 3 (bash-isms, 000097) shipped, the survey's build pack is complete: slice 4 was
  characterized as already-covered (BOM half = the slice-1 non-ASCII rule; the indented here-string
  closer is an existing parser error) and slice 5 (angle-bracket placeholders) stays deferred on
  irreducible false-positives.

## [1.21.1] - 2026-07-01
PATCH: **Curate the opt-in `base` ruleset -- remove three survey-measured noisy rules so `base` is
quieter on real code, with the default `pses-default` surface byte-for-byte unchanged**. The 000091
quality wave ran the base ruleset whole-file over a 34-file known-good false-positive oracle plus the
plugin's own source and measured three default-on rules as net-noise: `PSReviewUnusedParameter`
(~90% false-positive -- PSScriptAnalyzer's per-scriptblock scope analysis misses a script-level
parameter consumed by a nested function, which is every hook script), `PSUseSingularNouns` (zero
true-issues; intentional plural collection-returning names), and
`PSUseShouldProcessForStateChangingFunctions` (fires on the state-changing VERB, not on real state
change -- four false-positives on clean `New-*` / `Set-*` builders in the oracle). All three are
BASE-ONLY: none is in PSES's built-in 15-rule no-settings allow-list (dispatch 000085
`AnalysisService.s_defaultRules`), so removing them tightens the opt-in `base` surface alone and
CANNOT move `pses-default` -- the default never resolves `base.psd1` and never evaluates these rules,
so its live surface is byte-for-byte unchanged. The exclusions live as a named, documented exclude
list (`$BaseRuleExclusions`) in `scripts/regen-base-ruleset.ps1` -- each entry comment-citing the
000091 evidence -- and `rulesets/base.psd1` is REGENERATED as (default-on minus the
compatibility-profile family minus the exclude list), dropping 57 -> 54 rules; `regen -Check` stays
green, preserving the 000087 deterministic-enumeration property. The three Error-severity security
rules (`PSAvoidUsingComputerNameHardcoded` / `PSAvoidUsingConvertToSecureStringWithPlainText` /
`PSAvoidUsingUsernameAndPasswordParams`) and `PSAvoidUsingWriteHost` are RETAINED. EXCLUDE-ONLY: no
rule is added (additions are a separate survey-first slice). A PATCH, not a MINOR: the frozen CONTRACT
surface (the `ruleset` knob name, its enum values, its default) is unchanged -- base's rule content is
a regenerable implementation detail, not part of the frozen surface -- and this is a noise-reduction
refinement of an opt-in ruleset with the default untouched (dispatch 000092).

### Changed

- **`rulesets/base.psd1` -- 57 -> 54 rules.** Regenerated (not hand-edited) from the new
  `$BaseRuleExclusions` list in `scripts/regen-base-ruleset.ps1` -- still the pinned analyzer's
  default-on set minus `PSUseCompatible*`, now also minus the three survey-measured noisy rules below.
  The three Error-severity security rules and `PSAvoidUsingWriteHost` remain present; `regen -Check`
  confirms the file still matches the derivation.
- **`scripts/regen-base-ruleset.ps1` -- named, documented exclude list.** A new `$BaseRuleExclusions`
  array (each entry comment-citing the 000091 finding and its false-positive rationale) is subtracted
  in `Get-DerivedBaseRules`, so every removal is auditable and reproducible and the `-Check`
  determinism guard covers it.

### Removed

- **Three base-only rules removed from `rulesets/base.psd1` as measured noise (dispatch 000091):**
  `PSReviewUnusedParameter` (~90% false-positive on the param-block + nested-functions shape),
  `PSUseSingularNouns` (zero true-issues; intentional plural names), and
  `PSUseShouldProcessForStateChangingFunctions` (verb-triggered false-positive on clean `New-*` /
  `Set-*` builders). Each is reachable only under `ruleset=base`; `pses-default` is unaffected.

## [1.21.0] - 2026-06-30
MINOR: **Opt-in broadened live surface -- a new `ruleset` knob and a plugin-owned, explicitly
enumerated base ruleset that surfaces PSScriptAnalyzer's default-on rules (including three
Error-severity security rules) on the live edit path, with the default surface byte-for-byte
unchanged**. On the live PostToolUse path PowerShell Editor Services applies its OWN built-in
no-settings rule set -- a ~15-rule allow-list -- so most default-on PSScriptAnalyzer rules
(`PSAvoidUsingWriteHost` and the three Error-severity security rules
`PSAvoidUsingComputerNameHardcoded` / `PSAvoidUsingConvertToSecureStringWithPlainText` /
`PSAvoidUsingUsernameAndPasswordParams`) never fire live. A new opt-in `ruleset` enum knob
(`pses-default` | `base`, default `pses-default`) selects the fallback ruleset when no repo-local
`PSScriptAnalyzerSettings.psd1` and no explicit `settingsPath` resolve: `pses-default` keeps today's
15-rule surface exactly (byte-for-byte unchanged -- no plugin ruleset is resolved), and `base`
resolves the shipped `rulesets/base.psd1`, broadening the live surface to PSScriptAnalyzer's default-on
set minus the compatibility-profile rules (57 rules at the pinned analyzer). The base **enumerates**
its rules explicitly rather than using `IncludeDefaultRules = $true`, so the surfaced set is
deterministic and a pinned-analyzer bump is a deliberate regeneration
(`scripts/regen-base-ruleset.ps1`), never a silent shift. Precedence stays authoritative for the user:
an explicit `settingsPath` and a discovered repo-local `PSScriptAnalyzerSettings.psd1` ALWAYS win over
the base -- the base only fills the gap. The default is deliberately **not** flipped: the broadened
surface never activates on upgrade unless opted in (an evidence-backed default-flip is a later
dispatch). No new status token and no second PSSA acquisition path: the base is resolved through the
existing settings-path channel and the vendored pinned-hash PSScriptAnalyzer (000046 L2) is reused. A
DELIBERATE MINOR with a CONTRACT amendment for the new knob (the 000027 drift-guard passes because the
contract was updated, not bypassed); dispatch 000087.

### Added

- **`ruleset` userConfig knob (opt-in, default `pses-default`).** An enum (`pses-default` | `base`,
  default `pses-default`). `base` broadens the live surface to the plugin's shipped enumerated base
  ruleset; `pses-default` keeps PSES's built-in 15-rule no-settings set. The enum shape lets future
  curated / AI-era rule tiers be added as additive values without a breaking knob change. Declared in
  `.claude-plugin/plugin.json`, frozen in `CONTRACT.md` (FROZEN-KNOBS), and documented in `README.md`
  (`## Configuration` + a Ruleset tiers subsection).
- **`rulesets/base.psd1` -- the plugin-owned base ruleset.** PSScriptAnalyzer's default-on set minus
  the compatibility-profile rules, enumerated explicitly (57 rules at PSScriptAnalyzer 1.25.0),
  including the three Error-severity security rules. Selected ONLY when `ruleset=base` and no repo-local
  settings / explicit override resolve; named `base.psd1` (not `PSScriptAnalyzerSettings.psd1`) so it is
  never auto-discovered as a repo-local settings file.
- **`scripts/regen-base-ruleset.ps1` -- reproducible regeneration.** Derives the base rule list from the
  vendored pinned PSScriptAnalyzer (default-on minus `PSUseCompatible*`) and prints it, or `-Check`
  compares the shipped `rulesets/base.psd1` against the derivation and fails on drift.

## [1.20.0] - 2026-06-30
MINOR: **Off-by-default format-on-edit suggestions -- the warm daemon runs PSScriptAnalyzer's
Invoke-Formatter on the edited file (honoring the repo's PSScriptAnalyzerSettings.psd1) and
surfaces the formatted result as a SUGGESTION (a unified diff) via additionalContext; the hook
NEVER rewrites your file**. A new off-by-default `userConfig` knob, `formatOnEdit`, closes the
ROADMAP "format-on-edit" gap WITHOUT giving up the never-break-editing spine: when set to
`suggest`, each edit triggers a SEPARATE warm-daemon round-trip that runs Invoke-Formatter --
honoring the repo's own `PSScriptAnalyzerSettings.psd1` formatter rules when present (the 000018
repo-local-settings precedent) -- and the reformatted result is surfaced as a suggestion, clearly
labelled and distinct from a diagnostic, stating that the file was NOT modified. Suggest-not-apply
is the WHOLE safety posture: the hook only suggests and never writes the user's file (an actual
apply mode is left to a separate, higher-risk dispatch). The formatter runs on the already-warm
daemon, so NO cold-start is added, and the existing pinned-hash-verified PSScriptAnalyzer (000046
L2) is the ONLY acquisition path -- it is imported once into the daemon process; no second path, no
hash change. A formatting failure (no settings, a malformed settings file, a formatter error)
degrades honestly: no suggestion is surfaced and the hook still exits 0 -- editing is never broken.
With the knob OFF (the default) NOTHING changes: no `format` request is sent and the diagnostics
surface is byte-for-byte unchanged. This is a DELIBERATE MINOR with a CONTRACT amendment for the new
knob (the 000027 drift-guard passes because the contract was updated, not bypassed); no new status
token (dispatch 000059).

### Added

- **`formatOnEdit` userConfig knob (off by default).** An enum (`off` | `suggest`, default `off`).
  `suggest` surfaces a unified-diff formatting suggestion via the existing `additionalContext`
  channel; `off` does nothing. `apply` is reserved for a possible future release and is treated as
  `off` today -- the enum shape lets a future apply mode be added as an additive value without a
  breaking knob change. Declared in `.claude-plugin/plugin.json`, frozen in `CONTRACT.md`
  (FROZEN-KNOBS), and documented in `README.md` (`## Configuration` + a Format-on-edit subsection).
- **Warm-daemon `format` action.** A new request action on the per-session daemon runs
  Invoke-Formatter (honoring the resolved repo settings path) and returns a capped unified-diff
  SUGGESTION; it is independent of PSES (formatting is pure PSScriptAnalyzer), so it works even when
  the analyzer is degraded/unavailable, and it NEVER writes the file.

## [1.19.0] - 2026-06-29
MINOR: **SARIF + standalone CI mode -- run the SAME engine over a path, emit SARIF
2.1.0 for GitHub code scanning, additive (no knob, no token)**. A new non-agent entry
point, `scripts/lsp-scan.ps1`, runs the diagnostics engine over a file or directory and
emits SARIF 2.1.0 (for GitHub code scanning) or a human-readable text report. It bridges
the in-agent linter to in-CI use WITHOUT forking the analysis logic: the entry point is a
SIBLING invocation that brings up the same warm PSES daemon and runs the same
`scripts/lsp-client.ps1` per file, so a finding is identical whether it surfaces in-agent
or in-CI. The output format is a CLI PARAMETER (`-Format sarif|text`), deliberately NOT a
new `userConfig` knob -- so the 000027 contract drift-guard is untouched and stays green
(no CONTRACT amendment). The existing pinned-hash-verified PSScriptAnalyzer (000046 L2) is
the ONLY acquisition path; no second path, no hash change. The in-agent PostToolUse surface
is byte-for-byte unchanged (additive only).

### Added

- **Standalone scan entry point (`scripts/lsp-scan.ps1`).** Runs over a PATH: a single
  `.ps1`/`.psm1`/`.psd1` file, or a directory (recursed by default; `-NoRecurse` limits to
  the top level). Only the PowerShell file types the tool already handles are analyzed;
  every other file is skipped (counted in text mode). `-Format sarif` (default) emits SARIF
  2.1.0 for code scanning; `-Format text` emits a human-readable report mirroring the
  in-agent rendering. `-OutputPath` writes to a file (UTF-8, no BOM); `-FailOn
  note|warning|error` gates the exit code for CI use. Exit codes: 0 = completed (clean or
  under the `-FailOn` threshold), 2 = `-FailOn` threshold met, 3 = usage error, 4 = scan
  incomplete (the analyzer was not reachable -- an unanalyzed file never reads as a clean
  one).
- **One-engine derivation library (`scripts/lib/lsp-scan-common.ps1`).** Target
  enumeration, the honest severity-to-SARIF-level mapping, SARIF 2.1.0 assembly + text
  rendering, and the per-file derivation that drives the real `lsp-client.ps1` and reads
  back the structured records the tool tees -- the SAME derivation channel the
  diagnostic-correctness corpus uses, redirected to a hermetic throwaway file (never the
  repo dogfood log).
- **Finding-identity test + SARIF schema validation
  (`tests/PowerShellLsp.SarifScan.Tests.ps1`).** Runs every committed corpus sample through
  the SCAN entry point and asserts its findings match the in-agent corpus snapshot exactly
  -- the same measured 0% false-positive rate / 100% true-positive coverage via the CI path
  -- proving the CI and in-agent paths share one engine (a divergence goes RED). The emitted
  SARIF is validated against the vendored official SARIF 2.1.0 JSON Schema
  (`tests/sarif/sarif-2.1.0.json`) on every pwsh leg.

### Notes

- **Honest severity-to-SARIF-level mapping.** `Error -> error`, `Warning -> warning`,
  `Information -> note`, `Hint -> note`. SARIF 2.1.0 defines exactly four result levels
  (error, warning, note, none); the only fold is Information AND Hint -> note, because SARIF
  has no separate "info"/"hint" level below warning -- note is its least-alarming
  non-suppressed level. Nothing maps to `none` (which suppresses a result) and an unknown
  severity maps to `warning`, so a finding is never silently dropped: no inflation, no
  deflation.
- **Additive, no contract change.** No new `userConfig` knob and no new status token (the
  output format is a CLI parameter -- decisions as parameters). The 000027 drift-guard is
  unchanged (the existing 13 knobs and 4 tokens are untouched) and CONTRACT.md needs no
  amendment; a new entry point is additive surface the contract does not freeze. The
  in-agent PostToolUse diagnostics surface is byte-for-byte unchanged -- the CI mode is
  purely additive.
- **Same PSScriptAnalyzer, one acquisition path.** The scan brings up the daemon via the
  existing `session-start.ps1` -> `ensure-pssa.ps1` bootstrap (the pinned, SHA-256-verified
  vendor, 000046 L2); it adds no second acquisition path and does not touch the pinned hash.

MINOR: **the AI-era rule pack, slice 1 -- non-ASCII smuggling pre-PSSA byte pass,
always-on additive, no knob/token**. A new pre-PSSA diagnostic source (`powershell-lsp`)
scans for smart-punctuation characters (em/en dash, curly quotes, arrow glyphs) that
would mojibake under Windows PowerShell 5.1 reading a UTF-8-without-BOM file as
Windows-1252 -- the project's own signature pain. Gated to fire ONLY on files without
a UTF-8 BOM (a BOM'd file is safe). This is the first slice of the PL-3 rule pack
characterized by dispatch 000055's survey; it builds the reusable pre-PSSA source
category (its own source label + corpus It-block, mirroring the existing `parser`
category) that later slices 2 (5.1-vs-7 via the settings channel) and 3 (bash-isms
AST pass) will reuse. Always-on additive: **no new `userConfig` knob, no new status
token** (the 000027 drift-guard stays green). PSSA acquisition and the pinned hash
are untouched (this is a pre-PSSA pass and needs none of that). The corpus is extended
with 5 known-bad (smart-punctuation cases) and 1 known-good (a UTF-8-with-BOM file
containing non-ASCII that must NOT flag); the measured **0% false-positive rate and
100% true-positive coverage** hold on the wider set.

### Added

- **Pre-PSSA source category (`source = 'powershell-lsp'`).** A new in-process,
  pre-PSSA byte/text pass in `scripts/lib/lsp-common.ps1` (`Find-NonAsciiSmuggling`)
  and `scripts/lsp-client.ps1` that scans for non-ASCII smart-punctuation characters
  BEFORE the PSES/PSSA analyzer pass. The scan fires on every `.ps1`/`.psm1`/`.psd1`
  edit; findings carry the distinct source label `powershell-lsp`, analogous to how
  parser errors carry `parser` and PSSA diagnostics carry `PSScriptAnalyzer`. The
  corpus test has a new `pre-pssa` category It-block asserting the source label,
  mirroring the `parser` assertion.
- **Non-ASCII smuggling rule (`NonAsciiChar`).** Detects em-dashes (U+2014), en-dashes
  (U+2013), smart single quotes (U+2018/2019), smart double quotes (U+201C/201D), and
  right-arrow glyphs (U+2192) in files that have NO UTF-8 BOM. A file with a UTF-8 BOM
  is treated as encoding-safe and never flags. Severity `Warning`. Smart-punctuation
  scoping means an intentional CJK / Unicode literal (which uses different byte
  sequences) is never flagged.
- **Corpus coverage extended.** 5 known-bad `pre-pssa` samples (one per smart-
  punctuation character type) and 1 known-good `clean` sample (a UTF-8-with-BOM file
  containing an em-dash that must NOT flag). Every sample is tool-derived and never
  hand-authored. The measured 0% FP / 100% TP holds on the wider corpus.

### Notes

- **Always-on additive discipline.** No `userConfig` knob exposes or suppresses this
  rule -- it is always active. No new status token is added. The 000027 drift-guard
  is unchanged (the existing 13 knobs and 4 tokens are untouched). CONTRACT.md is
  unchanged (the source label `powershell-lsp` is an output field, not a frozen
  userConfig knob or status token).
- **No PSSA pin or acquisition touched.** The pre-PSSA pass is pure byte-level code
  in the existing scripts; it does not load PSScriptAnalyzer, install a custom rule,
  or touch `ensure-pssa.ps1` / the pinned hash. The 000046 L2 integrity story is
  preserved unchanged.

MINOR: **project-intelligence, slice 1 -- deterministic .psd1 static manifest-consistency
(orphan/typo export detection), always-on additive, no knob/token**. The daemon caches
the module surface ONCE per session (walks up from the edited file to find the nearest
`.psd1`, parses FunctionsToExport/CmdletsToExport/AliasesToExport with
Import-PowerShellDataFile, AST-enumerates the RootModule for defined function names),
then per-edit is a cheap cache lookup + cross-reference that flags two classes of
manifest inconsistency: (1) an ORPHAN export -- a name in FunctionsToExport that has
no matching function definition in the module (e.g. a typo'd name), and (2) an
UNDER-DECLARED export -- a function defined AND exported by the module but absent from
the manifest's export list. The check surfaces ONLY when the edited file is the manifest
(.psd1) or the root module (.psm1), so unrelated edits never spam project findings (the
000058 touch-triggered discipline). On a wildcard '&#42;' export, a runtime/dynamic
Export-ModuleMember, or dot-sourcing the static pass cannot follow, the tool honestly
says 'cannot determine the module export surface' rather than guessing -- **never a false
positive from an indeterminable shape**. This is the first slice of PL-6, characterized
by the 000058 survey. **unused-export detection is explicitly NOT in slice 1** (the
survey ranked it down as wrong-by-design: a public export's purpose IS external callers,
so "unused within the module" is the normal state). The corpus is extended with **5
multi-file module fixtures** (3 good/indeterminate + 2 bad) in a new `module` category;
the measured **0% false-positive rate** holds on the wider set. Always-on additive: **no
new `userConfig` knob, no new status token** (the 000027 drift-guard stays green). PSSA
acquisition and the pinned hash are untouched.

### Added

- **Daemon-side module surface cache (`scripts/pses-daemon.ps1`).** New
  `Update-ModuleSurfaceCache` function that resolves the nearest `.psd1` (walked up from
  the edited file, bounded at the filesystem root), parses it with
  `Import-PowerShellDataFile`, AST-enumerates the RootModule (`.psm1`) for
  `FunctionDefinitionAst` + explicit `Export-ModuleMember`, and caches the result keyed
  by manifest path + content hash. Per-edit invalidation is a SHA-256 content-hash
  compare -- a no-op when the manifest is unchanged. The cache stores both the manifest
  export lists and the module's defined function names, plus a degrade reason when the
  shape is indeterminate.
- **Manifest-consistency helpers (`scripts/lib/lsp-common.ps1`).** New pure-data
  extraction functions: `Find-ModuleManifest` (walk-up to locate a .psd1),
  `Get-ModuleManifestExports` (safe Import-PowerShellDataFile wrapper),
  `Get-ModuleDefinedFunctionNames` (AST enumeration with dynamic Export-ModuleMember
  detection), `Test-ManifestConsistency` (the cross-reference that finds orphan and
  under-declared exports), and `Get-ProjectIntelligenceFindings` (the top-level entry
  point). Honest degrade: degrades on wildcard `'*'`, runtime/dynamic
  Export-ModuleMember, dot-sourcing, and missing/`$null` FunctionsToExport (which means
  "export all" in some PS versions).
- **Project-finding surface (`scripts/lsp-client.ps1`).** The diagnostics client now
  requests and renders manifest-consistency findings from the daemon's module surface
  cache. Deterministic findings appear as `powershell-lsp`/`ManifestConsistency`
  diagnostics; indeterminate shapes render a "cannot determine" prose note. Both appear
  alongside the existing PSSA/parser diagnostics and carry no new status token.
- **Multi-file corpus fixtures (new `module` category).** 5 module fixtures under
  `tests/corpus/samples/module/`, each a directory with a `.psd1` + `.psm1`:
  `consistent-module` (a well-formed module -- must surface NOTHING), `orphan-export`
  (a name in FunctionsToExport with no matching function -- must surface
  ManifestConsistency), `typo-export` (a mis-spelled exported name -- must surface
  ManifestConsistency), `wildcard-export` (FunctionsToExport=`'*'` -- must NOT produce
  a false orphan), and `dynamic-export` (Export-ModuleMember with a variable argument --
  must NOT produce a false orphan). The corpus harness is extended to copy multi-file
  fixture directories to scratch during derivation. Expected snapshots are committed and
  a new `module` assertion `It` block guards them. The measured 0% FP holds on the wider
  set.

### Notes

- **Always-on additive discipline.** No `userConfig` knob exposes or suppresses this
  project-intelligence check -- it is always active. No new status token is added. The
  000027 drift-guard is unchanged (the existing 13 knobs and 4 tokens are untouched).
  CONTRACT.md is unchanged (the new `powershell-lsp`/`ManifestConsistency` finding uses
  an existing source label and is an output field, not a frozen userConfig knob or status
  token).
- **No PSSA pin or acquisition touched.** The module surface cache is pure AST-level
  code in the existing scripts; it does not load PSScriptAnalyzer, install a custom rule,
  or touch `ensure-pssa.ps1` / the pinned hash. The 000046 L2 integrity story is
  preserved unchanged.
- **unused-export detection is NOT in slice 1.** The 000058 survey ranked it down as
  wrong-by-design: a public export's purpose IS external callers, so "unused within the
  module" is the normal state, and flagging it would be HIGH FP. Slice 1 is only the
  deterministic manifest-consistency check. The broader workspace-awareness phase
  (cross-file symbol resolution, dead-private-function detection) is named as roadmap
  and not scoped here.

MINOR: **closed-loop agentic correction, slice 1 -- the daemon re-checks the touched range on
the next edit turn and confirms whether a prior finding CLEARED or is STILL-PRESENT, additive,
no knob/token**. This is the bet only a server inside the agent can make (PL-4, characterized by
the 000056 survey): instead of passively handing diagnostics back, after Claude applies a fix the
warm daemon re-checks the SAME range on the next edit and tells the agent whether the finding it
just tried to fix actually went away. The prior-finding-for-range memory lives in the daemon (the
only per-session-persistent component); range identity reuses the existing `Get-DiagnosticShapeHash`
(rule id + normalized offending line), so a line-shifting edit never mistakes a MOVED finding for a
cleared one. The signal rides the EXISTING surface as additive output fields (`cleared[]` /
`stillPresent[]`) plus a distinct client "Correction check" note -- **no new status token**, because
finding-lifecycle is a different axis from the analyzer-health taxonomy (`ok` / `incomplete` /
`degraded` / `unavailable`); folding it into a token would muddy the frozen clean-empty property.
Escalation is BOUNDED (the 000056 K=2 rule): a still-present finding the edit touched escalates at
most twice, then a single neutral "unchanged after N edits" downgrade, then silence -- never an
indefinite nag. The next-turn re-check is **~free** (an in-memory diff plus one file read; it rides
the diagnostics pass the next edit already pays for -- no second settled-publish wait, no cold
start). Always-on additive: **no new `userConfig` knob, no new status token** (the 000027 drift-guard
stays green).

### Added

- **Daemon-resident prior-finding memory (`scripts/pses-daemon.ps1`).** A per-URI
  `$script:lastSurfaced` map holds the shape-hashes surfaced last turn (with rule id / line /
  message / a per-finding attempt count). `Add-LifecycleSignal` diffs each fresh, settled, ok pass
  against it and attaches the additive `cleared[]` / `stillPresent[]` fields to the response. It runs
  ONLY on a fresh settled ok pass (never a cache-hit, never `incomplete` / `degraded` / `unavailable`
  -- on any other pass "absent" does not mean "cleared", so it is skipped and the memory is
  preserved), and it is wrapped fail-open so any failure leaves the core diagnostics byte-identical.
- **Pure lifecycle-diff helpers (`scripts/lib/lsp-common.ps1`).** `Get-FindingLifecycleDiff` (the
  unit-testable set logic: CLEARED = a prior-surfaced shape-hash absent from the whole-file pass;
  STILL-PRESENT = a prior-surfaced shape-hash still in the touched-range surfaced set, bounded at
  K=2; NEW = an unseen surfaced hash that rides the normal surface; plus carry-forward of a
  still-present-but-untouched finding so a later clear is still seen) and `New-LifecycleFinding`
  (projects a diagnostic record to its `{ hash; ruleId; line; message }` shape via the existing
  `Get-DiagnosticShapeHash`).
- **Client "Correction check" note (`scripts/lsp-client.ps1`).** The PostToolUse client renders the
  additive `cleared[]` / `stillPresent[]` fields as their own labelled section, kept visibly distinct
  from the diagnostics block so a lifecycle signal is never confused with a correctness finding. A
  CLEARED confirmation can fire on a now-clean file (with no diagnostics block at all); a
  STILL-PRESENT note escalates a finding the edit did not clear.
- **Deterministic loop coverage.** New integration `It` blocks (`tests/PowerShellLsp.Integration.Tests.ps1`)
  drive the real warm daemon turn-by-turn -- cleared, still-present, moved (folds into still-present),
  new, the K=2 escalation bound, and a wire-level assertion that the response carries `cleared[]`
  with NO status token -- gated on a real diagnostics round-trip (`Wait-DaemonRequestReady`), never a
  wall-clock sleep (the 000028/000050/000051 lesson). New unit `It` blocks
  (`tests/PowerShellLsp.Unit.Tests.ps1`) cover the pure diff and the shape-hash projection, including
  StrictMode-safety on empty/null inputs.

### Notes

- **MOVED folds into still-present for slice 1.** The 000061 inbox summarized the signal as
  CLEARED / STILL-PRESENT / MOVED / NEW, but the authoritative 000056 outbox (which governs where the
  two differ) folds MOVED into still-present for the first slice, and the inbox's own pre-authorization
  prefers the conservative signal over a confident-but-wrong MOVED label. A moved finding keeps the
  same shape-hash at a new line, so it reads as still-present (at the new line), never as a false
  cleared -- the robustness the shape-hash buys. A distinct MOVED signal is a documented follow-on.
- **Latency claim HELD on the PL-2 dependency.** The re-check's latency is meant to be measured
  against PL-2's published baseline (000054), which has NOT landed. Per the inbox pre-authorization,
  the loop is measured against the documented warm-path expectation instead and the hard latency
  claim is HELD: structurally the re-check adds only an O(findings) in-memory diff plus one file read
  and reuses the warm pass (no second settle, no cold start), so it is ~free next-turn -- to be
  restated as measured once 000054 lands.
- **Always-on additive discipline.** No `userConfig` knob exposes or suppresses the loop -- it is
  always active. No new status token is added; the 000027 drift-guard is unchanged (the existing 13
  knobs and 4 tokens are untouched). CONTRACT.md gains only a forward-compatibility note: `cleared[]`
  / `stillPresent[]` are additive, backward-compatible output fields, not a frozen Tier-1 surface.
- **Single-file edit-range scope (slice 1).** The loop is per-edit-range and single-file; it does
  not drive Claude's in-agent fix prompting (the tool surfaces the honest signal; how the agent
  consumes it is out of scope) and does not fold in project-wide analysis (PL-6 territory).

## [1.18.1] - 2026-06-27

PATCH: **native LSP registration restored -- the two registrar-hostile manifest fields are removed**
(dispatch 000075, fixing what 000069 isolated). Claude Code's runtime LSP registrar silently drops
any `lspServers` entry that declares `restartOnCrash` or `shutdownTimeout` -- both are accepted by
the plugin-manifest JSON schema (so `plugin.json` validates), but the registrar rejects them with no
diagnostic. Our `lspServers.powershell` block declared both, so `.ps1/.psm1/.psd1 -> powershell` was
never registered ("No LSP server available for file type: .ps1"). Removing the two fields restores
**registration** (re-proven on the fixed tree via the persisted 000069 probe harness on Claude Code
2.1.195). **End-to-end serve is still gated upstream**: once registered, Claude Code launches PSES
but its LSP client times out during initialization (the #1359-class server->client handshake), so
native hover / go-to-definition / find-references do not complete yet. The plugin's real surface --
per-file diagnostics over the warm PostToolUse hook -- is **byte-for-byte unchanged**: nothing under
`scripts/` changed, and no daemon/diagnostics behavior moved. The 000027 contract drift-guard stays
green (**no new userConfig knob, no new status token**).

### Changed

- **`lspServers.powershell` no longer declares `restartOnCrash` or `shutdownTimeout`.** The two
  fields are optional restart/shutdown tuning the registrar refuses; PSES manages its own lifecycle,
  and their absence does not affect the diagnostics path. The block keeps `command`, `args`,
  `extensionToLanguage`, `transport`, `startupTimeout`, `maxRestarts`, and `env` -- all proven
  registrar-clean by the 000069 single-field probe matrix.
- **Docs corrected to the accurate framing.** `README.md` and
  `docs/upstream/claude-code-lsp-registration.md` no longer call native registration
  "platform-inert": the platform path is effective on 2.1.195, our blocker was the two manifest
  fields, registration is restored, and end-to-end serve remains gated on the upstream Claude Code
  init handshake. No hover/goto/find-references-as-working claim.

### Added

- **A registrar-field-allowlist guard.** `tests/PowerShellLsp.Unit.Tests.ps1` parses `plugin.json`
  and fails CI if any `lspServers` entry declares a field outside `{command, args,
  extensionToLanguage, transport, startupTimeout, maxRestarts, env}`, naming `restartOnCrash` and
  `shutdownTimeout` as known-hostile. A silent registrar drop becomes a loud test failure if either
  field (or a future hostile one) is ever re-added; adversarial fixtures demonstrate the guard goes
  red on a re-add.

### Notes

- **Registration is restored; native serve is not enabled as a working feature.** Native LSP
  operations on `.ps1` do not complete until the upstream init handshake (#1359-class) is fixed
  Claude-Code-side -- tracked separately and out of scope here. Diagnostics continue to ride the
  warm PostToolUse hook, unchanged.

## [1.18.0] - 2026-06-26

MINOR: **supply-chain signing -- the release tag itself is now cryptographically signed** (dispatch
000064). The gated release pipeline now cuts a **keyless gitsign-signed tag** -- a Sigstore signature
made with a Fulcio certificate from the runner's ambient GitHub OIDC identity and logged in the public
Rekor transparency log -- in place of the previous unsigned annotated tag. That is the genuine net-new
trust surface, and it drops into the exact post-gate tag-cut step. **Tool behavior is byte-for-byte
unchanged from v1.17.0**: this is a CI-workflow + documentation change only -- nothing under
`scripts/`; the daemon, hooks, diagnostics surface, acquisition path, and pinned hashes are identical.
The 000027 contract drift-guard stays green: **no new `userConfig` knob and no new status token**. Like
the build-provenance attestation, the tag signature only proves out on the first real release (the
server-issued OIDC token); see [docs/RELEASING.md](./docs/RELEASING.md).

### Added

- **Keyless gitsign-signed release tags.** The pipeline cuts the release tag with `git tag -s` using
  gitsign as git's x509 signing program, authenticating via the runner's ambient GitHub OIDC identity
  -- **keyless: no stored key, no secret, no widened permission** (it reuses the `id-token: write`
  already present for provenance). WHEN the tag is cut is unchanged -- only on a merged +
  all-legs-green + version-matched commit, after Gates 1-4 -- the tag now simply carries a Sigstore
  signature, logged in Rekor.
- **A user-facing verify path for the signature.** TRUST.md, README, and docs/RELEASING.md document how
  to verify a gitsign-signed tag (`gitsign verify` with the workflow's certificate identity and the
  GitHub OIDC issuer) alongside the existing `gh attestation verify` for the source-archive provenance
  -- honest that this needs gitsign-aware tooling: a plain `git verify-tag` checks only cryptographic
  integrity and Rekor existence, not signer identity.

### Changed

- **Trust docs corrected to the real signing posture.** TRUST.md, README, and CONTINUITY no longer say
  "signing pending / not signed." They state the truth: release tags are gitsign-signed (keyless,
  Rekor-logged); the source archive carries the existing SLSA build provenance; **Authenticode is
  deliberately NOT pursued** -- a git-cloned plugin is not a Windows `.exe` / installer, so Windows
  publisher-trust is moot -- and **SignPath Foundation is declined / adoption-gated**. The docs are
  explicit about what the signature does NOT cover: the `/plugin` clone-based install path (Claude Code
  copies source from git, not the release archive; that path's integrity rests on the signed tag +
  commit), and the gitsign verification-tooling requirement. CONTINUITY's SignPath certificate-custody
  governance item is retired -- keyless means there is no certificate to hold. No security audit is
  claimed.

### Not done (recorded, not built)

- **cosign over the source archive -- judged redundant.** The existing `actions/attest-build-provenance`
  already covers the archive with a Sigstore-backed SLSA provenance -- a STRONGER claim than a bare
  signature, since it attests who built the artifact, from what source, via what workflow. A `cosign
  sign-blob` over the same bytes would be a weaker, largely redundant signature; its only edge
  (Rekor-direct verification) the provenance bundle already provides. Adding it would be surface without
  a real gain, so it was deliberately not built. The net-new signature is the tag, which nothing
  previously signed.
- **Authenticode / Windows publisher signing -- deliberately not pursued** (above), not omitted. The
  paid like-for-like, Azure Trusted Signing, is gated on a qualifying US / CA legal entity; not pursued
  today.

### Notes

- **Correction to the v1.17.0 release notes.** The shipped 1.17.0 entry credits dispatch 000064 with a
  "Live Sigstore build-provenance attestation" and calls 1.17.0 the project's "first verifiable Sigstore
  build-provenance attestation." That framing is mistaken, and is corrected here rather than by
  rewriting the dated 1.17.0 entry (shipped history stands): the **build-provenance attestation has been
  live since v1.13.0** (dispatch 000042), so it was neither new in 1.17.0 nor 000064's deliverable.
  000064's actual deliverable is the **keyless gitsign-signed git tag**, which did not ship in 1.17.0.
  **v1.18.0 is the first release whose git tag itself is cryptographically signed** (keyless
  gitsign/Sigstore: a Fulcio certificate via GitHub OIDC, Rekor-logged). The 1.17.0 tag, like every tag
  before it, is an unsigned annotated tag.
- **The MINOR is the additive trust surface, not a runtime change.** A verifiable signature on the
  release tag plus the user-facing verify path is a new backward-compatible capability; as with the
  build-provenance attestation, it is produced by the server-issued OIDC token and proves out on the
  first real release cut after this change. No plugin runtime or diagnostics behavior changed.

## [1.17.0] - 2026-06-26

MINOR: **release-pipeline completion and live supply-chain provenance** (dispatches 000063,
000064, 000065). The gated release pipeline introduced in v1.13.0 now **completes a real release
reliably**, and every release now carries a **verifiable Sigstore build-provenance attestation**
(`gh attestation verify`). This is a CI/release-machinery and docs release: **nothing under
`scripts/` changes**, the plugin runtime and the diagnostics surface are **byte-for-byte unchanged
from v1.16.0** (the daemon, hooks, diagnostics output, status taxonomy, and pinned dependency
hashes are identical), and the 000027 contract drift-guard stays green -- **no new `userConfig`
knob and no new status token**. No plugin runtime or diagnostics behavior changed in 1.17.0; the
headline is trust and release mechanics, not features.

### Added

- **Live Sigstore build-provenance attestation on every release (dispatch 000064).** The release
  job's provenance wiring is finalized: `actions/attest-build-provenance@v2` produces a **keyless**
  (GitHub OIDC -- no maintainer-held signing key) build-provenance attestation over the release
  source archive and the CycloneDX SBOM, **live starting with this release** and verifiable with
  `gh attestation verify`. The honest boundary from v1.13.0 still holds: the attestation covers the
  downloadable source archive, not the `/plugin` clone-based install path, whose integrity rests on
  the git commit and tag themselves.

### Fixed

- **Release pipeline Gate 4 waits for the push-CI run to conclude before judging (dispatch 000063).**
  Gate 4 (the green-CI precondition) previously took a single snapshot of the push-event CI run for
  the target commit and refused unless it was already `success` -- so triggering a release before
  that run reached a terminal state failed the gate even when CI went green moments later
  (snapshot-and-refuse, the common case right after a merge). Gate 4 now **waits for the run to
  reach a terminal state** (bounded poll, honest timeout) before judging its per-leg result, so the
  gated pipeline completes a real release instead of racing CI. The gate's safety is unchanged: a
  non-success run, any non-success required leg, or a wait timeout still refuses (never a false
  green).

### Docs

- **Roadmap ground-truth reconciliation (dispatch 000065).** Docs-only: corrected stale `ROADMAP`
  entries (release-engineering status, the signing posture, and the 000063 Gate-4 item) to match
  what actually shipped. No code, workflow, or behavior change.

### Notes

- **First release produced by the pipeline.** v1.13.0 was the last release cut the old manual way;
  1.17.0 is the first produced by the gated pipeline end-to-end -- the proof-out the v1.13.0 notes
  anticipated -- and it carries the project's first verifiable Sigstore build-provenance
  attestation. The MINOR is warranted by that additive, consumer-facing trust surface (a verifiable
  attestation on every release), consistent with shipping additive CI/trust capability as MINOR
  (v1.12.0, v1.13.0) -- not by any runtime change.

## [1.16.0] - 2026-06-24

MINOR: **a community-release readiness bundle** (dispatch 000048) -- five additive workstreams in
one release. **Tool behavior is byte-for-byte unchanged from v1.15.0**: the daemon, hooks,
diagnostics surface, acquisition path, pinned hashes, and status taxonomy are identical -- the diff
is test **inputs** and **documentation** only (`scripts/**` and `plugin.json`'s hooks/lspServers are
an empty diff vs the prior release). The MINOR is warranted by the strengthened, *published*
correctness claim over a roughly 2x-larger corpus and the new community / trust surface, not by any
runtime change. The 000027 contract drift-guard stays green: **no new `userConfig` knob and no new
status token**.

### Added

- **Broadened diagnostic-correctness corpus (Gap A breadth).** The corpus grows from 16/18 to **34
  known-good and 36 known-bad** cases (six per surfaced rule) spanning a deliberately diverse range
  of real-world idioms (`begin`/`process`/`end`, classes with inheritance and static members,
  `[Flags]` enums, validation attributes, `SecureString` / `PSCredential` parameters, splatting,
  multi-stage pipelines, typed `try`/`catch`/`finally`, here-strings, regex, `ShouldProcess`). Every
  snapshot remains **tool-derived** (never hand-authored). The measured **0% false-positive rate and
  100% true-positive coverage** now stand on the wider surface; the CI guard floor rises from 15 to
  **30** known-good / 30 known-bad, and the README numbers are updated. (WS1)
- **Honest trust badge row + verify-your-install (Gap B, visible trust).** The README opens with a
  badge row (CI, version, GPL-3.0-or-later, CycloneDX SBOM, the measured 0% corpus false-positive
  rate, and the honest **signing-pending** status -- nothing claims signed or audited), plus a new
  **Verify your install** section showing how to confirm the pinned-hash verification and read the
  SBOM / build-provenance. (WS2)
- **Doctor-first quickstart (time-to-value).** The Quick start now takes a new user from install to
  a real caught diagnostic quickly, with the report-only preflight **doctor** as the explicit
  confidence step. (WS3)
- **Contributor on-ramp + continuity (Gap E, bus-factor).** New **`ARCHITECTURE.md`** (the
  warm-daemon model, edit-to-banner flow), **`DEV_NOTES.md`** (the hard-won quirks), **`CONTRIBUTING.md`**
  (build, run the suite, the test story, DCO sign-off), an honest **`CONTINUITY.md`** (the
  single-maintainer risk, key custody, and the GPLv3 fork path -- no fabricated successor), and
  **GitHub issue templates** including a **report-a-false-positive** path that feeds the corpus. (WS4)
- **Right-sized positioning (Gap D).** The README lead now opens with what the tool genuinely is
  today -- **per-file** PowerShell diagnostics inside Claude Code -- and frames workspace-wide /
  multi-file analysis (and hover / go-to-definition / find-references) as **roadmap**, gated on the
  upstream plugin LSP-registration fix, rather than present tense. (WS5)

## [1.15.0] - 2026-06-23

MINOR: **an enterprise trust-surface and correctness-proof bundle** (dispatch 000046) -- four
isolated workstreams in one release. The behavior change that warrants MINOR is **fail-closed
hash verification of the downloaded dependencies** (WS2); the rest is additive (a measured
correctness proof, plus trust/disclosure docs). The 000027 contract drift-guard stays green:
**no new `userConfig` knob and no new diagnostics status token** -- a hash mismatch reuses the
existing honest `unavailable` surface.

### Added

- **Fail-closed dependency integrity (Gap B L2).** PowerShell Editor Services (the GitHub
  release zip) and PSScriptAnalyzer (the PowerShell Gallery `.nupkg`) are now verified against
  a SHA-256 pin **computed from the real known-good artifact** before they are used
  (`Test-PinnedFileHash` in `scripts/lib/lsp-common.ps1`, wired into `scripts/ensure-pses.ps1`
  and `scripts/ensure-pssa.ps1`). A match proceeds exactly as before; a **mismatch fails
  closed** -- the unverified bundle is refused, any prior working bundle is left intact, the
  session surfaces the existing honest `unavailable` banner, and the hook still exits 0 (editing
  is never broken). PSScriptAnalyzer now acquires via the **verified `.nupkg` download first**,
  falling back to `Save-Module` only on a download failure (never on a hash mismatch). The Gallery
  download is hardened for CI egress (dispatch 000047): an explicit User-Agent, a bounded 3-try
  retry so a transient PowerShell Gallery / CDN 403 self-recovers, and registration of the default
  PSGallery repository when it is absent so the `Save-Module` fallback is reachable. The pin stays
  load-bearing -- the retry re-attempts the download only, and a hash mismatch still fails closed
  without any retry or fallback.
- **Measured diagnostic-correctness proof (Gap A).** The 000040 corpus is filled to 16
  known-good and 18 known-bad cases spanning every rule the default ruleset surfaces, with a
  **measured 0% false-positive rate and 100% true-positive coverage** under the default config,
  recomputed from the live tool and **guarded in CI on all four legs**
  (`tests/PowerShellLsp.Corpus.Tests.ps1`; report artifact `corpus-correctness-report.json`).
  Numbers are published in the README. Correcting an earlier undercount: the daemon surfaces
  **six** rules on the fly, not three.
- **`TRUST.md`** (Gap B L4 + Gap E) -- the enterprise approve-or-deny reference: local-only /
  no-telemetry posture, the pinned versions AND hashes, pointers to the CycloneDX SBOM and
  build-provenance attestation, the honest signing status (SignPath application **pending -- not
  signed**, no security audit), paste-ready WDAC / AppLocker rules, CodeIntegrity 3076/3077
  guidance, and the governance / single-maintainer bus-factor posture.
- **`SECURITY.md`** -- a real disclosure policy: supported versions, a **private** report
  channel (GitHub private vulnerability reporting), scope, and response expectations.

## [1.14.1] - 2026-06-23

PATCH: **a cross-platform test fix -- the dogfood-review annotations-path test no longer hardcodes a
Windows `C:` drive** (dispatch 000044). The 000043 test `Get-DogfoodAnnotationsPath is annotations.jsonl
beside the log` fed the function a `C:\...` literal; off-Windows there is no `C:` PSDrive, so PowerShell
threw `DriveNotFoundException` before the assertion ran -- a deterministic failure on the `ubuntu-pwsh`
and `macos-pwsh` CI legs (357 passed / 1 failed / 5 skipped each, Windows green). **Test-only change:
nothing under `scripts/` changes** -- the tool (`review-dogfood.ps1`, `Get-DogfoodAnnotationsPath`) was
already portable; the defect was entirely the test's hardcoded input. The diagnostics surface and capture
path are byte-for-byte unchanged and the 000027 contract drift-guard stays green.

### Fixed

- **Portable annotations-path test (`tests/PowerShellLsp.Unit.Tests.ps1`).** The
  `Get-DogfoodAnnotationsPath` beside-the-log assertion now derives its log path from `$TestDrive` (a real
  per-platform temp dir) instead of a hardcoded `C:\d\dogfood\...` literal, so the same beside-the-log
  derivation runs identically on all four CI legs. Same assertion, same proof (`annotations.jsonl` sits
  beside the log) -- portable input, teeth intact, not a no-op.

## [1.14.0] - 2026-06-23

MINOR: **a dogfood review tool that fills the captured `verdict` -- turning raw capture data into the
ranked input the quality wave consumes** (dispatch 000043). The companion to the 000039 capture: it
reads `dogfood/diagnostics.jsonl`, presents each distinct diagnostic shape that still needs a verdict,
accepts one from a frozen enum, and persists it. **Additive offline tool only: nothing under `scripts/`
that the daemon or hooks run changes, and the diagnostics surface + capture path are byte-for-byte
unchanged.** It only COLLECTS verdicts; acting on them (tuning any rule) is the separate quality wave.
The 000027 contract drift-guard stays green (no new `userConfig` knob, no new status token).

### Added

- **Dogfood review/annotation tool (`scripts/review-dogfood.ps1`).** Reads the capture log, collapses
  occurrences into distinct **shapes** keyed by the capture record's existing shape-`hash` (rule id +
  normalized offending-line shape), and lets you record a **verdict** per shape. Identical diagnostics
  share one verdict (the same misfire seen many times is judged once); a re-run skips shapes that
  already carry a verdict (resumable).
- **Frozen verdict vocabulary:** `useful` / `false-positive` / `noisy` / `bad-fix` / `unsure` (a fixed
  enum, not free text; an optional one-line rationale may accompany it). This is NOT the 000027 status
  taxonomy and adds no `userConfig` knob.
- **Non-destructive, hash-keyed persistence.** Verdicts are written to a **separate sibling file,
  `dogfood/annotations.jsonl`** -- append-only, last-write-wins -- and the capture log is **never
  rewritten** (it stays immutable evidence). The annotations file lives under the already-gitignored
  `dogfood/` tree and is never committed (its free-text rationale could quote source).
- **Read-only by default, with a ranked summary.** With no write action the tool lists pending shapes
  and prints a summary -- counts by verdict, annotation coverage, and the top "actionable" rules
  (false-positive / noisy / bad-fix) ranked by occurrence count. Writing a verdict is the explicit
  action: `-Hash <hash> -Verdict <verdict> [-Rationale "..."]`, or the interactive `-Review` loop
  (guarded -- a non-interactive host falls back to the listing). `-Redact` masks snippets when sharing.

## [1.13.0] - 2026-06-22

MINOR: **release-engineering automation -- a gated release pipeline that makes a bad tag structurally
impossible, with CHANGELOG-driven notes, an SBOM, and build provenance** (dispatch 000042). Closes the
roadmap's release-automation gap (Gap C.2) and the buildable-now half of the trust-surface gap (Gap B:
SBOM + provenance). CI/CD + docs only: **nothing under `scripts/` changes**, the plugin runtime and the
diagnostics surface are **byte-for-byte unchanged**, the existing four-leg CI is untouched, and the
000027 contract drift-guard stays green. The governing principle is **automate the mechanics, preserve
the decision** -- the release is maintainer-triggered (Mike chooses when and which version); the pipeline
only makes the mechanical execution safe. Tagging stays Mike's gate.

### Added

- **Gated release pipeline (`.github/workflows/powershell-lsp-release.yml`), Gap C.2.** A new SIBLING of
  the CI workflow (not a rewrite), triggered ONLY by a manual `workflow_dispatch` -- it NEVER auto-fires
  on push or merge. Given a version, it validates four preconditions and **refuses to tag** unless ALL
  hold: (1) the target commit is merged to `main`; (2) the tag `v<version>` is free; (3) `plugin.json`
  and `marketplace.json` BOTH read the requested version at that commit (lockstep); and (4) the
  push-event CI run for that exact commit concluded `success` on every required leg (`windows-pwsh`,
  `windows-powershell`, `ubuntu-pwsh`, `macos-pwsh`). Only then does it cut and push the annotated tag
  **from the pipeline, on the validated commit** -- never a hand-typed `git tag` -- and create the
  GitHub Release. This makes a tag on an unmerged, red, wrong-version, or wrong commit **structurally
  impossible** (the failure mode that, the previous round, put a tag on the wrong tree by a fat-fingered
  manual step). A `dry_run` input validates every gate and stops without tagging, for a safe rehearsal.
  Permissions are least-privilege (`contents: read` by default; the release job adds exactly
  `contents: write` + `actions: read` + `id-token: write` + `attestations: write`); only the ephemeral
  `GITHUB_TOKEN` is used -- no PAT, no secret exposed.
- **CHANGELOG-driven release notes (`release/Get-ChangelogEntry.ps1`).** The Release body is the
  CHANGELOG entry for the released version, **extracted by the pipeline** -- single-sourced, never
  hand-retyped. The extractor refuses a version it cannot find (you cannot release what you did not
  document).
- **CycloneDX 1.5 SBOM (`release/New-PluginSbom.ps1`), Gap B.** Generated over the plugin and its two
  **pinned downloaded dependencies** -- PowerShell Editor Services (`v4.6.0`) and PSScriptAnalyzer
  (`1.25.0`) -- with versions read STRAIGHT from `scripts/ensure-pses.ps1` and `scripts/ensure-pssa.ps1`,
  so the SBOM can never drift from what the tool actually fetches. Attached to the Release. (An
  off-the-shelf directory scanner cannot see these deps, because they are downloaded at install time and
  are not in the repo tree -- hence an authored, single-sourced generator.)
- **Build-provenance attestation (Gap B), with an honest boundary.** `actions/attest-build-provenance`
  produces a verifiable SLSA-style attestation over the release source archive and the SBOM. The honest
  scope, stated rather than glossed: a git-distributed plugin has no compiled binary, so the meaningful
  artifact is the **packaged source archive** -- the attestation covers that downloadable artifact
  (verifiable with `gh attestation verify`), but NOT the `/plugin` clone-based install path, whose
  integrity rests on the git commit and tag themselves. Real provenance over a real artifact, with its
  limits documented -- not attestation theater over a non-artifact.
- **RELEASING doc (`docs/RELEASING.md`), linked from the README.** How to trigger a release, what the
  pipeline validates, what it produces, the dry-run rehearsal, how to verify a release, the provenance
  boundary, the testability boundary, and the manual fallback if the pipeline ever misbehaves.
- **Release-logic regression tests (`tests/PowerShellLsp.Release.Tests.ps1`).** Cover the CHANGELOG
  extraction (boundary-exact), the CycloneDX SBOM generation and its single-sourcing from the live pins,
  and the version-lockstep invariant the tag-gate re-checks. Run on all four CI legs.

### Notes

- **Testability boundary (stated honestly).** Everything testable WITHOUT a real release was validated:
  YAML parse + least-privilege permissions, the CHANGELOG-to-notes and SBOM logic (unit tests), the
  artifact build (`git archive` + SBOM + notes dry-run), and the green-CI gate query (simulated against
  the real main-tip push run -- job names and per-leg success detection confirmed). What ONLY proves out
  on the first real release is the end-to-end run on GitHub's servers: the attestation step (needs a
  server-issued OIDC token) and the actual tag push + release creation. The manual fallback is documented.
- **Bootstrap irony.** This 1.13.0 release is the LAST one cut the old manual way; the pipeline proves
  out on the NEXT release.

## [1.12.1] - 2026-06-22

PATCH: **test-reliability hardening -- make the 000029 licensing test deterministic** (dispatch 000041).
A flake fix with ZERO tool-behavior change: nothing under `scripts/` is modified, the diagnostics surface
is byte-for-byte unchanged, and the 000027 contract drift-guard stays green. First buildable-now piece of
the roadmap's release-engineering reliability gap (Gap C.1).

### Fixed

- **The `N_PssaDir` CI coin-flip (Gap C.1).** On the v1.11.0 push run the ubuntu-pwsh leg failed the
  000029 licensing test (`PSScriptAnalyzer module retains its MIT LICENSE + ThirdPartyNotices`) with
  `$script:N_PssaDir` resolving null; a re-run went green. Root cause (read from the failing run's log,
  not guessed): PSScriptAnalyzer WAS vendored and fully functional on that run -- every other
  PSSA-dependent test in the same run passed -- so this was never a vendoring failure. The test resolved
  the module dir with a one-shot `Get-ChildItem -Recurse -Filter ... -ErrorAction SilentlyContinue |
  Select -First 1`, and on Linux that enumeration intermittently returned empty (`SilentlyContinue`
  swallowed a transient enumeration error), turning a present, importable module into a cryptic null
  assertion. Resolution is now a bounded retry that absorbs a transient miss, and a null is classified
  honestly via the vendoring marker (`modules/.pssa-*.ok`, written by `ensure-pssa` only after a
  verified-importable install): a legitimately-unvendored environment SKIPS with a clear reason; a
  vendored-but-unresolvable one FAILS LOUD with a precise message -- never a silent coin-flip. The
  notice-preservation assertions are unchanged and keep their full teeth when the bundle is present.
- **Sweep -- a fixed-sleep shutdown assertion (same class).** The warm-start SessionEnd test asserted the
  daemon/PSES were gone after a fixed `Start-Sleep -Seconds 3`; on a slow runner that is the same
  assert-on-timed-state coin-flip. It now polls (bounded) until teardown completes before asserting the
  same final conditions -- deterministic, teeth intact.

The bounded sweep also confirmed the empty-array -> `$null` collapse class (which bit the 000040 corpus
helper) is already correctly guarded across the suite; the remaining environment-dependence (the
integration bundle download) surfaces as a clear failure, not a coin-flip.

## [1.12.0] - 2026-06-22

MINOR: **CI proof-framework -- diagnostic-correctness corpus + performance benchmark harness**
(dispatch 000040). Two CI regression guards that close the roadmap's buildable-now correctness and
release-engineering gaps (Gap A, Gap C): a corpus that proves WHAT the tool reports is correct, and a
benchmark that measures and guards HOW FAST it reports it. This is a PROOF framework: it measures and
asserts current behavior and does not change it. Nothing under `scripts/` is modified, the diagnostics
surface is byte-for-byte unchanged, and the 000027 contract drift-guard stays green.

### Added

- **Diagnostic-correctness corpus (`tests/corpus/`), Gap A.** Curated clean / known-bad-per-rule /
  parser-error PowerShell samples, each with an expected-findings snapshot DERIVED from the real tool
  (the warm PSES daemon + PScriptAnalyzer, or the in-process parser pre-pass) through the dogfood
  capture channel -- never hand-authored, never model-authored. `tests/corpus/Update-CorpusSnapshots.ps1`
  regenerates the snapshots; `tests/PowerShellLsp.Corpus.Tests.ps1` re-derives the same way and asserts
  the live tool still matches, so a behavior change is a visible, located failure. The corpus also
  records the observed fact that the tool's effective PSES default ruleset is narrower than raw
  PSScriptAnalyzer.
- **Performance benchmark harness (`tests/bench/`, `tests/PowerShellLsp.Benchmark.Tests.ps1`), Gap C.**
  Repeatably measures cold-start (SessionStart -> daemon ready) and warm-path (edit -> diagnostic
  round-trip) latency against the real daemon/pipe path, emits structured results
  (`benchmark-results.json`), and guards each median against a generous first-pass threshold (cold under
  20 s, warm under 9 s). Build-time medians: cold ~3.9 s, warm ~2.2 s (`pwsh` 7.6.3, Windows 11).
- **README.** Publishes the measured latency numbers and adds a Diagnostic-correctness corpus section.

Both halves run in CI on all four legs (windows-pwsh, windows-powershell, ubuntu-pwsh, macos-pwsh) via
the existing `tests/run-tests.ps1` auto-discovery; the benchmark numbers upload as a CI artifact.

## [1.11.0] - 2026-06-22

MINOR: **doctor daemon/pipe-health check** -- the preflight doctor (`scripts/doctor.ps1`, dispatch 000036)
gains a sixth, report-only check: is the warm per-session PSES daemon alive and answering on its named pipe
right now (dispatch 000037)? Checks 1-5 confirm the bundle is INSTALLED; this confirms the language server is
actually RUNNING, closing the "installed vs actually working" gap -- a user can pass all five static checks
and still have a dead or wedged daemon. REPORT-ONLY: the probe observes and never launches, relaunches,
repairs, or kills the daemon. No new `userConfig` knob and NO change to the diagnostics status-token taxonomy
(the doctor keeps its own pass/fail/unknown vocabulary), so the 000027 drift-guard greens with no Tier-1 change.

The probe is non-disruptive and honest about the pipe-first + auto-relaunch design. It reuses the daemon's
existing `ping` action over the same named-pipe protocol the PostToolUse client uses -- a round-trip the
daemon answers WITHOUT touching its PSES child (no analysis, no state change), so it cannot wedge the live
daemon or steal its pipe. The four-state mapping respects the 000028/000030 semantics: a daemon answering its
pipe is `PASS`; a daemon alive but parked `unavailable` / `degraded`, or alive but not answering, is a `FAIL`
with the restart remedy; NO daemon present is a benign `PASS` (one auto-relaunches on the next edit -- never a
scary FAIL); and a state that cannot be determined from outside the session (no data dir, or several live
daemons and no session id to disambiguate) is an honest `UNKNOWN`.

### Added

- **Daemon-health check (`scripts/doctor.ps1`), dispatch 000037.** New pure decision `Test-DoctorDaemon`
  (unit-tested over injected observations) plus the live probes `Get-DoctorDaemonObservation` (discovery via
  the daemon's own durable handle -- the `<data>/session/<id>.json` details file and its recorded-pid
  liveness, exactly as the SessionStart reap does) and `Test-DoctorDaemonPingProbe` (the non-disruptive
  `ping` round-trip). An optional `-SessionId` argument scopes the check to a specific session; otherwise it
  resolves `$env:CLAUDE_SESSION_ID`, then discovers the live daemon(s). Nine new unit tests cover the mapping
  (healthy / parked-unavailable / degraded / wedged / absent-but-relaunchable / no-session-context /
  ambiguous), with the daemon and pipe state mocked.

### Notes

- Claude Code passes the session id to hooks on stdin, not as an environment variable, so a standalone
  `pwsh -File scripts/doctor.ps1` cannot key the check to its own session: it discovers the live daemon(s) by
  the durable handle and is honestly `UNKNOWN` when more than one is live and none is named. Run with
  `-SessionId` (or from inside the session) for a definitive scoped check.
- A `--fix` / repair mode stays out of scope (the doctor is report-only); it is deferred to a later slice,
  gated on evidence that "restart your session" is insufficient.

## [1.10.0] - 2026-06-22

MINOR: **dogfood diagnostic capture** -- every diagnostic the plugin surfaces is now also teed to a
local, append-only JSONL log (`dogfood/diagnostics.jsonl`), one entry per occurrence, each with an EMPTY
`verdict` field reserved for later manual annotation (dispatch 000039). This starts the accumulation clock
the roadmap's quality wave (rule curation, false-positive reduction, fix-suggestion quality) needs to rank
work on REAL diagnostics from REAL usage instead of guesses. It is CAPTURE ONLY: the annotation/review tool
that consumes the verdict field is a deliberate fast-follow (next_suggested). No new `userConfig` knob and
NO change to the diagnostics status-token taxonomy, so the 000027 drift-guard greens with no Tier-1 change.

Capture is a pure, INVISIBLE side channel: it runs AFTER the diagnostics are surfaced, is fully fail-safe
(any write failure is swallowed), and writes nothing to stdout -- so what is surfaced, its order, the
timing, and the hook's exit code are byte-for-byte unchanged whether capture succeeds, fails, or is absent.
The 000026 fail-safe spine and the 000024/000028 never-silent guarantee are preserved unchanged. The log
holds REAL source snippets and is gitignored -- it must NEVER be committed.

### Added

- **Diagnostic capture tap (`scripts/lib/lsp-common.ps1`, `scripts/lsp-client.ps1`), dispatch 000039.** At
  BOTH per-diagnostic emit sites in the PostToolUse client -- the in-process parser pre-pass and the
  warm-daemon PSScriptAnalyzer path -- the surfaced occurrences are appended to the dogfood log. Each entry
  carries: ISO-8601 `ts`, `file`, `line`, `col`, `ruleId` (the PSSA rule, or empty for a parser error),
  `source` (`PSScriptAnalyzer` or `parser`), `severity`, `message`, `snippet` (the full offending line), a
  stable `hash` over the rule id + the normalized offending-line shape (analysis-time de-duplication only:
  trim + collapse interior whitespace, case preserved), and an empty `verdict`. Every occurrence is logged
  (two identical diagnostics -> two entries); there is no dedup, sampling, or rate-limiting at capture. New
  helpers `Get-DogfoodLogPath`, `Get-DiagnosticShapeHash`, `New-CaptureRecordFromDiag`,
  `New-CaptureRecordFromParseError`, and the fail-safe `Add-DiagnosticCaptureEntries`, with new unit +
  integration tests -- including the load-bearing guard: a forced capture-write failure leaves the surfaced
  block byte-for-byte unchanged and the hook still exits 0.
- **`.gitignore` (new) + README "Dogfood diagnostic capture".** The whole `dogfood/` directory is gitignored
  so no captured source snippet is ever staged, and the README documents what is captured, that it is
  local-only and never committed, that it holds real source snippets, and how the `verdict` field is used
  later.

### Notes

- The log path defaults to `dogfood/diagnostics.jsonl` in the plugin tree and can be relocated with the
  `POWERSHELL_LSP_DOGFOOD_LOG` environment variable (also the test seam). It is NOT a `userConfig` knob.
- Capture only: the annotation/review tool that walks unannotated entries and lets you tag verdicts is the
  planned fast-follow.

## [1.9.0] - 2026-06-22

MINOR: **honest degradation on a security-control block** -- when the PSES / PSScriptAnalyzer
bootstrap fails on a managed Windows estate, the SessionStart banner now NAMES the most likely
blocking security control and the legitimate remediation instead of a generic "could not complete
(network/proxy?)" (dispatch 000038, building the 000032 L3 survey). It ENRICHES the existing
never-silent surface (000024/000028): the status stays `unavailable`, the message gets specific.
No new `userConfig` knob and NO new status token -- the four-token taxonomy is unchanged, so the
000027 drift-guard greens with no Tier-1 change (banner prose is not a frozen surface, CONTRACT.md
1.2).

The discipline is calibrated honesty: a control is NAMED only on POSITIVE EVIDENCE, never guessed.
ExecutionPolicy (Group-Policy scope) and Constrained Language Mode are cheaply and directly
queryable, so a coincident failure names them with `likely` confidence; App Control / WDAC and
Defender ASR are named `confirmed` only when a matching CodeIntegrity (3077 enforced / 3076 audit)
or Defender (1121 block / 1122 audit) event references a plugin component; Smart App Control is
reputation-gated, so it is only ever `possible` ("may be blocking ... until reputation accrues").
With no positive evidence the banner falls back to an honest diagnostic POINTER (network/proxy is
still the usual cause; here is how to check ExecutionPolicy, the language mode, and the CodeIntegrity
log) -- richer than a bare `unavailable`, never a fabricated control.

THE ABSOLUTE FENCE: the plugin DETECTS and EXPLAINS; it NEVER bypasses, disables, weakens, or
auto-modifies any control. Every remediation is INSTRUCTIONS for the user or their administrator
(allow-list, sign, adjust policy), never an action the plugin takes -- circumventing enterprise
security is exactly what gets a tool banned, so honest degradation is the entire value.

### Added

- **Security-block classifier (`scripts/lib/security-classifier.ps1`).** A pure, CLM-safe, mockable
  module: `Resolve-SecurityBlock` maps INJECTED evidence (ExecutionPolicy state, session language
  mode, Smart App Control state, CodeIntegrity / Defender block events) to the most likely control
  plus an actionable, instructions-only remediation, or an honest fallback when nothing is
  positively identified. Thin best-effort live probes gather the evidence, each independently
  fail-safe: a denied event-log permission, an absent log, a non-Windows host, or Constrained
  Language Mode degrades to "no evidence", never an exception. 27 new unit tests cover every path
  with the probes mocked.
- **Named security-block banner at SessionStart.** `scripts/session-start.ps1` now enriches the
  bootstrap-failure `additionalContext` line via the classifier. Fail-safe by construction: any
  classifier error (or a missing module) falls back to the prior generic banner, and the hook still
  exits 0 and never blocks editing (the 000026 spine is preserved).

### Notes

- Scope is L3 only (honest degradation on a block). Signing (L1), hash-verify (L2), the enterprise
  TRUST.md doc (L4), and the signed release pipeline (L5/L6) remain separate, later work.
- Wiring the 000036 doctor's generic security pointer to call this classifier is a natural follow-up
  (it depends on dispatch 000037 landing) and is intentionally NOT included here; the doctor's
  on-demand generic pointer and this SessionStart named banner remain distinct surfaces.

## [1.8.0] - 2026-06-21

MINOR: **preflight `doctor` self-check** -- a new report-only `scripts/doctor.ps1` that turns the worst
onboarding failure mode (the plugin is enabled but a prerequisite is missing, so diagnostics silently do
nothing) into a named, actionable fix-list (dispatch 000036). It is the on-demand bookend to the
000024/000028 never-silent spine: same honesty, a new entry point. Report-only by design -- it never
downloads, repairs, or runs the bootstrap. It deliberately does NOT detect security-control blocks
(WDAC / AppLocker / ExecutionPolicy / Smart App Control / Constrained Language Mode); that surface is the
separate ROADMAP L3 security track (survey 000032), so an indeterminate failure gets only one generic
pointer, with zero control-specific probing. No new `userConfig` knob and no change to the diagnostics
status-token taxonomy, so the 000027 drift-guard greens with no Tier-1 change.

### Added

- **Preflight doctor (`scripts/doctor.ps1`), dispatch 000036.** Runs an ordered set of checks and prints,
  per check, PASS / a specific failure naming the blocked component plus the remediation (tied to the
  README Requirements / Install / Troubleshooting) / an honest UNKNOWN when it genuinely cannot determine
  (for example when run outside a Claude Code session, where it cannot see the plugin data directory). The
  checks: (1) PowerShell 7 (`pwsh`) present and new enough for the hooks; (2) the plugin enabled
  (`defaultEnabled` is false); (3) the PSES bundle bootstrapped (the per-pin marker AND
  `Start-EditorServices.ps1`, the exact pair `ensure-pses.ps1` gates on); (4) PSScriptAnalyzer vendored AND
  importable; (5) the first-run download hosts reachable. Every pin, marker name, install path, and host is
  read single-source from `ensure-pses.ps1` / `ensure-pssa.ps1` (never hardcoded). Each check is a pure,
  mockable function returning a status object, unit-tested for pass / fail / unknown with the probes
  injected. Documented under README Troubleshooting. Report-only; exits non-zero only when a check FAILED.

## [1.7.0] - 2026-06-21

MINOR: **auto-relaunch the idle-stopped daemon** -- the next edit after a clean idle-stop now SILENTLY
relaunches the per-session daemon and recovers, instead of bannering "analyzer not reachable" on every
edit until the session is manually restarted (dispatch 000030). This converts the *recoverable* subset of
the 000028 no-daemon state into silent recovery, while keeping every 000028 honest banner as the fallback
for the cases that genuinely cannot recover. It builds directly on the 000028 pipe-first daemon + client
connect-fail backstop. No new `userConfig` knob; the four status tokens are unchanged (recovery reuses the
transient `incomplete` during the relaunched daemon's init window), so the 000027 drift-guard greens with
no Tier-1 change. `idleTtlMin`'s frozen meaning is unchanged -- auto-relaunch COMPLEMENTS it (free the
daemon when truly idle, bring it back exactly when active again).

### Added

- **Silent recovery of a cleanly idle-stopped daemon (dispatch 000030).** When a PostToolUse edit finds
  the daemon unreachable AND the condition is the recoverable no-daemon case, the client now silently
  relaunches the daemon -- via the EXACT pipe-first launch path SessionStart uses (extracted into a shared
  `Start-PsesDaemonDetached`) -- then reconnects within the existing hard cap. The relaunched daemon comes
  up pipe-first, so the first edit during its ~init window honestly gets the transient `incomplete`
  ("re-warming -- this edit was NOT checked"); the next edit gets real analysis. Resource hygiene is
  preserved: the daemon still self-terminates after `idleTtlMin`; it simply comes back on the next edit.

### The recoverable-vs-permanent gate (why it cannot spin)

- **The gate is structural at the pipe, not a heuristic.** The client's unreachable (`$null`) response IS
  the recoverable condition -- it means there is no daemon process at all (a clean idle-TTL self-terminate,
  a crash, or the ~150ms pre-pipe launch sliver). A PERMANENT init failure never reaches it: the 000028
  pipe-first daemon stays UP serving the reachable `unavailable` status (never `$null`), so a broken bundle
  is never relaunched. Even the edge where a broken-bundle daemon ALSO idle-stopped relaunches exactly ONCE
  and then re-parks alive serving `unavailable` (pipe-first daemons park, they do not exit-and-bounce) --
  so there is no relaunch loop, by construction.
- **Bounded: at most one relaunch per cooldown window** (a per-session stamp, ~the daemon init deadline).
  A relaunch that is suppressed by the cooldown, finds no host, or whose spawn fails ALWAYS falls back to
  the honest banner -- so the bound can only ever cost a banner, never a missed check.

### Changed

- **Backstop banner wording refined (prose-only, no token change).** After an auto-restart the client no
  longer tells the user to "start a new session" -- a relaunch in progress reads "the analyzer had stopped
  and is being restarted -- this edit was NOT checked; your next edit should be," and "could not be
  restarted automatically" appears ONLY when the relaunch genuinely failed or was suppressed. A clean pass
  still renders nothing (the byte-identical warm path).

### Invariants held

- **Never-silent (the 000022->000028 spine).** Recovery is SILENT only when it actually succeeds (and even
  then the first init-window edit honestly says "not checked yet"); a failed or suppressed recovery
  surfaces the honest banner. The only new silence is a SUCCESSFUL recovery -- correct, because the edit
  then gets analyzed.
- **The 000028 surfaces are intact.** Sub-case A (transient `incomplete`) and sub-case B (permanent
  `unavailable`, never relaunched) are unchanged; SessionStart's launch is byte-equivalent (the extracted
  `Start-PsesDaemonDetached` carries the same args + the 000026 cross-platform detachment). All prior
  suites (000022/024/025/026/027/028) stay green on all four CI legs.

## [1.6.1] - 2026-06-20

**License change only -- relicensed FORWARD from MIT to GPLv3 (`GPL-3.0-or-later`), with ZERO code
or runtime change** (dispatch 000029). Every shipped `.ps1` is byte-identical to 1.6.0; the daemon,
the diagnostics output, the four status tokens, and all four install-failure surfaces behave exactly
as before. This is a PATCH by SemVer (no API or behavior change) -- the significance is legal, and it
is carried in this entry, not in the version digit.

### Why

Publish-readiness, not monetization. GPLv3 is copyleft: anyone who distributes a modified version
must keep it open under the same terms. Plain GPLv3 (not AGPL -- the tool is 100% local) is the
deliberate fit for an open release.

### Changed

- **`LICENSE`** is now the verbatim canonical GPLv3 text, fetched from
  <https://www.gnu.org/licenses/gpl-3.0.txt> and **byte-verified** (35,149 bytes, LF, no BOM;
  SHA-256 `3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986` -- the canonical FSF
  hash). Not hand-typed or paraphrased.
- **SPDX id `GPL-3.0-or-later`** is declared consistently across the three authoritative sites:
  `LICENSE`, `.claude-plugin/plugin.json` (`license`), and this README's License section.
  (`marketplace.json` has **no** `license` field in the Claude Code marketplace schema -- the
  per-plugin license lives in `plugin.json` -- so it carries none.) A new CI **drift-guard** fails
  the build if these sites ever disagree.
- **`THIRD-PARTY-LICENSES.md`** (new) documents the two components the plugin **downloads at install
  time** (it does not bundle or redistribute them): PowerShell Editor Services and PSScriptAnalyzer,
  both MIT (Microsoft), pinned in `ensure-pses.ps1` / `ensure-pssa.ps1`. MIT is GPL-compatible; their
  notices travel inside the downloaded bundles and are neither modified nor relicensed.

### Forward-only -- prior releases stay MIT

This license change is **forward-only and does not reach backward**. **Releases v1.0 through v1.6.0
remain under the MIT license they were published with** -- that grant is irrevocable and is **not**
revoked, rescinded, or diminished here. Anyone using a v1.0-v1.6.0 release keeps their MIT rights.
This is normal and expected for a license change, not a problem. From **v1.6.1 forward** the project
is `GPL-3.0-or-later`.

### Not legal advice

This is the standard mechanical way to perform a forward license change, not legal advice. For a
serious public release, a human/legal sanity check on the exact license text and the third-party
attribution is advisable.

## [1.6.0] - 2026-06-20

MINOR: **pipe-first daemon** -- close the no-pipe silent first-edit miss, with warm-start as the
latency win riding free on the same change (dispatch 000028). This dispatch began as "warm-start"
and was reshaped under its own survey (the 000026 (A)->(B) pattern): the survey measured that the
costly PSES init is **already** eager, so warm-start's standalone win was small (~0.75s typical),
while it exposed a higher-severity correctness gap -- a first edit that raced PSES startup got
**nothing, not even a banner** (the honesty banner rides the daemon's pipe, and the pipe did not
exist until after init). The primary deliverable is now the correctness fix; warm-start is the
documented side effect. No new `userConfig` knob; the four status tokens are unchanged (the
`unavailable` **prose** is generalized -- a PATCH-level refinement per CONTRACT.md -- not a new
token).

### Fixed

- **The no-pipe silent miss (the headline -- a never-silent / could-not-X spine gap).** The daemon
  now creates its named pipe **before** bringing PSES up, then finishes PSES init **cooperatively**
  in the serve loop. A first edit that arrives while PSES is still starting -- or after PSES fails
  to start -- always reaches a daemon that answers with an **honest banner**, never the old silent
  connect-fail (`return $null` -> `exit 0`, no banner). Two cases, both previously silent:
  - **Still starting (transient):** a request during init is served `incomplete`
    ("analysis did not complete -- this edit was NOT checked"); the next edit succeeds once ready.
  - **Present but failed to start (permanent):** a bundle present but unable to initialize (startup
    failure / init timeout) -- which 000024 had deliberately left as a silent `exit 1` before the
    pipe -- now keeps the daemon **up** serving the permanent `unavailable`, never exit.
- **Client-side never-silent backstop (closes the residual no-pipe window -- so the silence fix has
  NO silence window).** Pipe-first closes the dominant ~4-13.5s PSES-init window from the daemon
  side, but the honesty banners ride the pipe -- so any case with NO pipe still had no channel: the
  brief (~150ms) sliver between the daemon process launching and it creating the pipe, and any
  session whose daemon has stopped (idle-TTL self-terminate, or the daemon process died). The
  PostToolUse client (`lsp-client.ps1`) now surfaces its OWN honest banner ("the analyzer was not
  reachable -- this edit was NOT checked ... start a new session to restart it") whenever the daemon
  is unreachable, instead of the old silent `exit 0`. Every could-not-analyze case is now visible --
  startup race, present-but-failed init, an idle-stopped daemon (previously silent), or a
  connect/read failure. Gated on the unreachable (`$null`) response, which a healthy clean pass is
  **never** (a clean result returns an ok object and still renders nothing), so the byte-identical
  warm/clean path is untouched.

### Added

- **Warm-start (the latency win, riding free).** Once PSES goes ready, the daemon drives one
  synthetic in-memory analysis so PSScriptAnalyzer loads + compiles its rule engine in the idle gap
  **before** the user's first real edit -- so that edit pays only the per-file cost, not the
  analyzer cold-start (measured ~0.77s warm / ~2.2s cold-box removed from the first edit). Always
  on, best-effort, off the request path; a failed warm just means the first edit self-warms as
  before. Proven at the state level (PSES ready + pre-warmed before the first request); timing is
  logged informationally and is **not** a CI gate (the 000026 "no flaky wall-clock proxy" lesson).

### Changed

- **`unavailable` banner prose generalized (token set unchanged).** It now covers BOTH "never
  installed (the bootstrap did not complete)" AND "installed but failed to start," and lands the
  **permanence** explicitly ("OFF for this whole session until it is fixed and the session is
  restarted") -- kept distinct from the transient `incomplete`. Per the CONTRACT.md freeze this is a
  prose refinement, not a taxonomy change: the four-token set `{ok, incomplete, degraded,
  unavailable}` is untouched and the drift-guard greens without a Tier-1 change.
- **`idleTtlMin` x warm-start reconciled** (the forward-compat note banked in CONTRACT.md, now
  closed): the idle clock starts at daemon launch and resets only on a real client request -- the
  internal pre-warm does not count -- so a never-edited session still self-terminates after
  `idleTtlMin`, whose meaning is unchanged.

### Invariants held

- The SessionStart hook stays non-blocking (000026): pipe-first only reorders what the **detached**
  daemon does, reaching "pipe open" sooner, never blocking the hook. The 000024/000026 surfacing
  tests stay green on all four legs.
- Warm vs cold diagnostics are byte-identical (latency-only): the warm happy path still renders no
  banner; the existing diagnostics tests + the 000027 drift-guard stay green.
- Supervised re-spawn (000022) is preserved: the mid-session crash path is unchanged; pipe-first
  only adds the cooperative FIRST-init path alongside it.

## [1.5.3] - 2026-06-20

PATCH: formalize the plugin's public surface as a 1.x semver contract and add a runnable CI
drift-guard. This ships a new document (`CONTRACT.md`) and a new test only -- **zero runtime
change**: every shipped script is byte-identical to 1.5.2, and the warm path, the diagnostics
output, and all four install-failure surfaces behave exactly as before. No `userConfig` knob is
added, removed, or renamed; no status token changes.

### Added

- **`CONTRACT.md` -- a two-tier 1.x semver freeze (dispatch 000027).** Tier 1 (CONTRACTUAL,
  drift-guarded): the 13 `userConfig` knob names (additive-only) and the four-token diagnostics
  status taxonomy `{ok, incomplete, degraded, unavailable}`, plus the property that `ok` renders
  an empty banner (the byte-identical warm path) while each non-ok token renders a distinct,
  non-empty, visible banner. Tier 2 (ASPIRATIONAL -- documented but **not** semver-contractual
  and **not** drift-guarded): the install-failure visibility guarantee, with the 000024/000026
  integration tests cited as its living evidence. The freeze is token-level, not prose-level
  (banner wording stays refinable under PATCH); knob names are frozen while behavior-neutral
  default re-tuning stays MINOR/PATCH and a behavior-altering default change is a MAJOR; and the
  `enableStats` stats-log format (absolute vs redacted paths) is explicitly **not** a frozen
  output field.
- **A CONTRACT.md drift-guard (extends the dispatch 000025 README Describes).** Two new Pester
  Describes assert `CONTRACT.md` freezes **exactly** the manifest `userConfig` keys and
  **exactly** the status tokens the code emits. Ground truth is extracted mechanically, live from
  source -- the manifest keys are parsed from `plugin.json`, and the status tokens are read from
  the `Get-DiagnosticsStatusBanner` switch via AST plus the clean token from calling
  `Resolve-AnalysisStatus` -- with **no** hand-maintained baseline list in the test. Adding a knob
  to the manifest or renaming a status token turns a CI leg red until both `CONTRACT.md` and the
  README record it. The README and CONTRACT guards are separate Describes, so a red leg names
  which document drifted.

## [1.5.2] - 2026-06-20

PATCH: fix a non-Windows session-startup defect (dispatch powershell-lsp/000026). On macOS and
Linux the SessionStart hook leaked its stdin/stdout/stderr handles to the detached PowerShell
Editor Services daemon, so the daemon held Claude Code's hook pipes open for the whole session.
Windows was never affected. No `userConfig` knob is added, removed, or renamed; diagnostics
output is byte-for-byte unchanged.

### Fixed

- **The detached daemon no longer inherits the SessionStart hook's standard handles on
  macOS/Linux (dispatch 000026).** On non-Windows the daemon was launched with a bare
  `Start-Process`; with no ShellExecute equivalent there, it inherited the hook's
  stdin/stdout/stderr by normal POSIX file-descriptor inheritance and held those pipes open for
  its entire lifetime. Because Claude Code's read of a SessionStart hook's stdout does not reach
  EOF while a child holds the write-end, this could **stall session startup** until the global
  hook timeout (cf. upstream claude-code #43123, affecting >= v2.1.87) -- on *every* non-Windows
  session, since the daemon launches every time -- and, in the clean-box install-failure case,
  it dropped the `additionalContext` "diagnostics unavailable" banner that dispatch 000024 added.
  The daemon's three standard streams are now redirected to per-launch files (stamped, retired by
  the existing log sweep) so it no longer holds the hook pipes. Windows is unchanged: there
  `-WindowStyle Hidden` routes the launch through ShellExecute, which structurally does not pass
  inheritable handles to the child. The load-bearing first-edit surface (the daemon-served
  `unavailable` on the PostToolUse channel) was never affected and stayed green on all platforms.
- **The dispatch 000024 SessionStart-surfacing integration test now passes on all four CI legs**
  (macos-pwsh, ubuntu-pwsh, windows-pwsh, windows-powershell). It had been correctly red on the
  two non-Windows legs since 000024 -- it was catching this defect, not a fixture flake.

## [1.5.1] - 2026-06-20

PATCH: docs-honesty and diagnosability hardening with no user-visible behavior change
(dispatch powershell-lsp/000025, closes the 000023 launch-readiness audit's backlog #3,
#4, and #7). Diagnostics output is byte-for-byte unchanged; the only value that moves on
the wire is a stale version label, now corrected. No `userConfig` knob is added, removed,
or renamed.

### Fixed

- **Three stale, drifted host-version literals now read the real plugin version from one
  source (dispatch 000025, 000023 audit S1b).** `pses-stdio.ps1` (was `1.0.0`),
  `pses-daemon.ps1` (was `1.1.0`), and the LSP `clientInfo.version` in `lsp-common.ps1`
  (was `1.1.0`) reported versions that had not tracked the plugin since early releases, and
  `bump-version.ps1` did not touch them. A new `Get-PluginVersion` reads
  `.claude-plugin/plugin.json` at runtime (cached, off the hot path), so every stamp now
  reflects the manifest and can never go stale again -- not even on a hand-edit that
  bypasses the bump helper. The same one-place-for-one-fact principle as the 000023 M1
  decorative-constant finding.

### Added

- **Plugin version in the daemon startup log (dispatch 000025, 000023 audit S1a).** The
  daemon start banner now reads `powershell-lsp <version>`, so a stranger's bug report can
  be tied to a specific plugin version from the log alone -- the highest-leverage support
  fix for a paid product. It is logged before the PSES launch, so even a failed or
  `unavailable` first start still records its version.
- **README documents the full analysis-status taxonomy (dispatch 000025).** A new
  "Diagnostics status" section explains all four statuses a user can see -- `ok` (silent),
  `incomplete` (transient; this edit was not checked), `degraded` (parser-only;
  PSScriptAnalyzer unavailable), and `unavailable` (install/bootstrap failure) -- with what
  each means and how to act, now that 000024 completed the set.
- **README notes that `stats.jsonl` records absolute file paths (dispatch 000025, 000023
  audit S1c, closes backlog #7).** Opt-in telemetry (`enableStats`, default off) writes the
  full path of each analyzed file; the README now documents this so a user can sanitize a
  log before sharing. Path redaction is deferred as a later enhancement.

### Changed

- **README config table now documents every `userConfig` knob (dispatch 000025, 000023
  audit D1, closes backlog #4).** The four knobs the table omitted -- `enableStats`,
  `settingsPath`, `scopeToEdit`, `editContextLines` -- are now documented, so the table
  matches the manifest exactly (asserted by a unit test).
- **README currency refreshed to Claude Code 2.1.183 (dispatch 000025, 000023 audit D1,
  closes backlog #3).** Native `.lsp.json` registration was re-confirmed inert through
  2.1.183 (2026-06-19); the "Why a hook" section now reflects that span rather than lagging
  at 2.1.167. The honesty that native registration is inert and the hook is the production
  path is unchanged.

## [1.5.0] - 2026-06-20

MINOR: extends the 000022 "never report clean when it could not analyze" guarantee from
mid-session to install-time. A clean-box bootstrap failure (offline, behind a corporate
proxy, or with GitHub blocked) is now VISIBLE -- the first edit on a clean-parsing file
shows an explicit "diagnostics unavailable -- PowerShell editor services not installed"
banner instead of silence that looked identical to "analyzed, clean." Entirely additive:
the surface appears only on a broken install; the healthy warm path is byte-for-byte
unchanged, and no `userConfig` knob is added, removed, or renamed.

### Added

- **Surface a silent first-start install failure (dispatch powershell-lsp/000024, closes
  the 000023 launch-readiness audit's backlog #1).** When the PowerShell Editor Services
  bundle never bootstrapped (a clean box with no network), the daemon now comes up far
  enough to serve an explicit `unavailable` status over its named pipe instead of exiting
  before the pipe exists -- so the first edit renders a visible "not installed -- the
  bootstrap did not complete (network/proxy?)" banner rather than nothing. `session-start`
  also surfaces the failure immediately via SessionStart `additionalContext`. The new
  `unavailable` status is deliberately distinct from the transient `incomplete` (000022) --
  a broken install needs a different remedy than a retryable miss -- and its wording is
  owned in one place (`Get-DiagnosticsStatusBanner`), so the daemon and client cannot drift.

### Fixed

- **`ensure-pses` now fails loud and non-destructively (dispatch powershell-lsp/000024,
  closes the 000023 audit's backlog #2).** A bootstrap failure now writes a clear stderr
  message and exits non-zero (mirroring `ensure-pssa`), so the orchestration layer can see
  and surface it instead of swallowing a silent, log-only miss. The bootstrap also stages
  and verifies the download in a temp area before touching the live bundle (renaming any
  existing bundle aside and restoring it on a swap failure), so a failed re-run leaves the
  previously working bundle intact rather than deleting it before a single-attempt download.

## [1.4.0] - 2026-06-15

MINOR: marks two capabilities that shipped since 1.3.0 -- repo-local
`PSScriptAnalyzerSettings.psd1` honoring (000018) and edit-range diagnostic scoping
(000019) -- alongside the telemetry foundation and manifest-honesty work that supported
them, and adds a lockstep version-bump helper so the two version surfaces can never drift
apart again. Entirely additive: new `userConfig` knobs and new opt-out-able behavior, with
no knob removed or renamed and no change to the hook/registration contract.

### Added

- **Honor a repo-local `PSScriptAnalyzerSettings.psd1` (dispatch powershell-lsp/000018).**
  The analyzer now discovers and applies the nearest `PSScriptAnalyzerSettings.psd1`,
  walked up from the edited file and bounded at the project root, so a repo's own analyzer
  configuration (custom rule set, severities, suppressions) is honored instead of ignored.
  A new `settingsPath` knob overrides discovery with an explicit **absolute** path (a
  relative value is ignored); empty = auto-discover. The settings file is resolved per
  edit and applied to the warm PSES analyzer pass.
- **Scope diagnostics to the edited lines (dispatch powershell-lsp/000019).** A new
  `scopeToEdit` knob (**default on**) filters the surfaced diagnostics to those overlapping
  the lines the edit actually touched, so the feedback is what the edit is responsible for
  rather than the whole file. It **fails open** to whole-file whenever the touched range
  cannot be determined -- a new-file `Write`, a failed edit, or an unparseable payload --
  so scoping never hides a diagnostic. A companion `editContextLines` knob (default `0`,
  because the edit's structured patch already carries a few context lines) widens the kept
  window. Overlap, not containment: a multi-line diagnostic straddling the edit boundary is
  kept. The syntax-error parser pre-pass is always surfaced unscoped (syntax errors cascade
  off-edit).
- **Per-edit telemetry foundation and readout (dispatch powershell-lsp/000015, Track A).**
  An opt-in `enableStats` knob appends one JSONL timing line per analyzed edit to
  `logs/stats.jsonl` (rotating, ~5 MB) -- observe-only, it never changes diagnostics output
  -- and `scripts/show-stats.ps1` summarizes per-stage p50/p95 (connect, analysis,
  code-action, total), cache-hit rate, path-taken breakdown, and sample count. The
  edit-scope feature (000019) rides this foundation: the daemon reports the pre-scope total
  and post-scope surfaced counts, and `show-stats.ps1` prints the resulting noise
  reduction, so the trimming is measured rather than assumed.
- **`scripts/bump-version.ps1` -- lockstep version-bump helper (this release).** Writes one
  target version into both `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`
  from a single input -- lockstep by construction, so a future release physically cannot
  bump one surface and forget the other (the 1.3.0 drift reconciled below). Dry-run by
  default (it prints the plan and writes nothing without `-Apply`), idempotent, surgical
  (only the version token changes; encoding and line endings are preserved verbatim), and
  ASCII-clean. It prints the `git tag v<version>` command for the post-merge step but never
  runs `git tag` / `git push` -- tagging stays a manual gate.

### Changed

- **`scopeToEdit` defaults to on.** After an edit, surfaced diagnostics are scoped to the
  edited lines by default. This is a default-behavior change, but additive and fully
  reversible: set `scopeToEdit` to `0` / `false` / `off` to restore the prior whole-file
  behavior, which remains byte-identical to pre-1.4.0. Because scoping fails open, it can
  only surface a superset of what it would otherwise suppress -- it never hides a diagnostic
  it cannot place -- so the change forces no config or workflow adjustment (MINOR, not
  MAJOR).

### Docs

- **Manifest description reconciled with what ships (dispatch powershell-lsp/000016).** The
  `plugin.json` / `marketplace.json` description now states diagnostics and PSScriptAnalyzer
  fix suggestions as the shipped capability, with hover, go-to-definition, and
  find-references named as roadmap items pending Claude Code plugin LSP-server registration
  ([#66987](https://github.com/anthropics/claude-code/issues/66987)), rather than implying
  they are present today.
- **Marketplace version reconciled to the shipped release (dispatch powershell-lsp/000017).**
  `marketplace.json` `metadata.version` had drifted behind `plugin.json` at 1.3.0 and was
  realigned. This release makes that lockstep automatic via the bump helper above, so the
  drift cannot reopen.
- **Pull-model LSP features remain registration-gated (dispatch powershell-lsp/000015,
  Track B).** `docs/upstream/pull-feature-gating-probe.md` records the read-only verdict:
  the four pull-model features (hover, go-to-definition, find-references, document-symbols)
  cannot be delivered through the surface this plugin ships today -- the block is the
  empirically inert Claude Code plugin LSP-server registration path (#66987), not a PSES
  capability gap and not a hook-surface gap. PSES already speaks these features over the
  warm daemon; only the registration channel is missing.

## [1.3.0] - 2026-06-07

MINOR: the macOS (`macos-pwsh`) warm-daemon path is now CI-verified -- a newly
verified platform (dispatch powershell-lsp/000009, Track A).

### Added

- **macOS warm-daemon path is now CI-verified.** A `macos-pwsh` (`macos-latest`,
  `pwsh`) leg was added to the CI matrix with the same daemon-log artifact capture as
  the other legs, and the warm-daemon integration suite (one-daemon bring-up, the
  settled PSScriptAnalyzer pass, clean SessionEnd) is **un-skipped on macOS and green**
  alongside the two Windows legs and Linux. README "Platform support" now claims macOS
  to exactly what CI proves. macOS needed no code changes: the 1.2.0 generic-POSIX
  fixes (omit `workspaceFolders`, POSIX `ConvertTo-FileUri`) and the already-authored
  `ps`-based process-probe fallback (no `/proc` on BSD) carried over as-is, so the
  integration suite passed on the first CI attempt.

### Docs

- **Registration watch: no upstream movement (Track C).** Re-checked since 1.2.0 --
  Claude Code 2.1.168 shipped (changelog: bug-fixes / reliability only, no plugin-LSP
  registration change); claude-code#15168 / #15148 and claude-plugins-official#379
  remain open and untouched; PR #378 stays closed-unmerged. The held
  `docs/upstream/claude-code-lsp-registration.md` refutation is unchanged in substance
  and verified postable, with a dated note that the 2.1.167 datapoint still stands as
  of 2.1.168.
- **Hook-surface expansion proposal (Track D).** Added `docs/hook-surface-proposal.md`
  -- a survey of whether PSES capabilities beyond diagnostics (rename, code actions,
  formatting, workspace symbols, hover) should ride the hook architecture. Conclusion:
  decline all; those are pull/positional features that belong to Claude Code's native
  `LSP` tool (blocked only by the registration bug above), not the event-driven hook
  surface. Diagnostics stays the one capability whose shape fits.

## [1.2.0] - 2026-06-06

MINOR: the Linux (`ubuntu-pwsh`) warm-daemon path is now CI-verified -- a newly
verified platform. Closes both open unknowns from 000007 (dispatch
powershell-lsp/000008).

### Added

- **Linux warm-daemon path is now CI-verified.** The `ubuntu-pwsh` CI leg now runs the
  full warm-daemon integration suite (one-daemon bring-up, the settled
  PSScriptAnalyzer pass, and clean SessionEnd) and is green alongside both Windows
  legs. README "Platform support" now claims Linux to exactly what CI proves; macOS
  stays authored but unverified.

### Fixed

- **PSES v4.6.0 `NullReferenceException` on `initialize` (Linux only).** PSES throws an
  NRE inside its own `OnInitialize` handler (`PsesLanguageServer.cs:150`, the
  workspace-folder add path) when the client's `initialize` carries `workspaceFolders`
  -- on Linux; Windows is unaffected, which is why the Windows legs always passed this
  handshake. The daemon now omits `workspaceFolders` and relies on `rootUri` alone (the
  warm path opens each file explicitly via `didOpen`/`didChange`, so multi-root folders
  are not needed for diagnostics).
- **`ConvertTo-FileUri` returned a null URI on POSIX.** The `[System.Uri]` string cast
  yields a null/relative URI for a POSIX absolute path (`/home/x` -- no drive, no
  scheme); `.AbsoluteUri` on that is null, so the first diagnostics request broke at
  `$uri.ToLowerInvariant()`. The builder now constructs `file://<path>` explicitly on
  POSIX (percent-escaping each segment); the Windows branch (uppercase drive letter) is
  unchanged.

### CI / diagnostics

- **Daemon logs are uploaded as a per-leg CI artifact.** The integration test's data
  root is overridable via `PSLS_TEST_DATA_DIR` (default unchanged locally); CI pins it
  to a workspace path and always-uploads `pses-daemon.log` / `pses-server-*.log` /
  `pses-stderr-*.log` as `daemon-logs-<leg>`, so a bring-up failure is diagnosable
  instead of opaque. This is what made the two Linux fixes above findable.

### Docs (installed-cache `.lsp.json` registration: tested, still inert)

- **Closed the 000007 "installed-cache `.lsp.json`" caveat.** A throwaway plugin whose
  source ships a clean top-level-map `.lsp.json` with **literal** commands was installed
  through the real `/plugin` flow (the installer copies it into the cache -- the exact
  installed-cache configuration the caveat had left untested, reached with zero
  hand-writes), then the builtin `LSP` tool was probed after a full restart:
  `No LSP server available`. The installed real plugin (template-var `.lsp.json` in its
  cache) is inert the same way. So the `.lsp.json`-**file** path is **inert on Claude
  Code 2.1.167**, with literal commands and template variables alike -- a definitive
  refutation of the installed-cache "it works" reports (most likely a CC version
  difference). README and the held `docs/upstream/` draft updated to the definitive INERT
  framing; the draft stays a DRAFT (not posted).

## [1.1.2] - 2026-06-06

PATCH: a documentation correction (no code change). Survey-then-ship dispatch
(powershell-lsp/000007) across three maintenance tracks -- only the Track A docs
correction was ripe to ship.

### Docs

- **Corrected the native `.lsp.json` / registration framing.** Re-tested plugin LSP
  registration on Claude Code 2.1.167 with the strict methodology -- a clean
  top-level-map `.lsp.json` carrying **literal** commands (no `${CLAUDE_PLUGIN_ROOT}` /
  `${user_config.*}` template variables), loaded into a **freshly started** process
  (`--plugin-dir`, a full restart, not `/reload-plugins`). The builtin `LSP` tool
  still returned `No LSP server available for file type: .ps1`, so the inertness is
  not a reload-vs-restart or template-variable artifact. (One path was not tested -- a
  `.lsp.json` file inside an installed plugin's cache dir, to avoid writing the
  installer-owned cache -- so this narrows the gap rather than closing it.)
- **Corrected the upstream citation.** claude-plugins-official PR #378 (the proposed
  `.lsp.json` packaging fix) was **closed unmerged** (2026-02-11); issue #379 remains
  open and unaddressed. README and the held `docs/upstream/` draft updated to match.

### Notes (surveyed, nothing else shipped)

- **Pins already current.** PSES `v4.6.0` and PSScriptAnalyzer `1.25.0` are the newest
  published releases -- no bump available; the PSES `PrepareRenameHandler` NRE remains
  unfixed upstream.
- **Cross-platform still unverified.** Enabling the warm-daemon integration tests on
  the ubuntu-pwsh CI leg showed the daemon does not reach `ready` on Linux (bring-up
  fails; both Windows legs stayed green). The non-Windows path stays
  authored-but-unverified; no platform claim changed.

## [1.1.1] - 2026-06-06

### Fixed

- **First-run failure on Claude Code v2.1.167.** On a clean install with no saved
  config, all three hooks (SessionStart, PostToolUse, SessionEnd) errored before
  running -- `Failed to run: Plugin option 'ps_host' isn't set` -- so a stranger got
  zero diagnostics and three red errors. Root cause: Claude Code did not apply the
  `userConfig` schema defaults to `${user_config.*}` substitution in hook commands,
  and the hooks used `${user_config.ps_host}` as the **interpreter**, so the very
  first reference was unset and the command could not launch.

### Changed

- **Hook commands no longer use `${user_config.*}` substitution.** The interpreter is
  now a literal `pwsh`, and every knob is self-sourced inside the scripts from the
  `CLAUDE_PLUGIN_OPTION_<key>` environment variables Claude Code exports, each with a
  fallback to its prior default (`Get-PluginOption` / `Get-PluginOptionInt`). This is
  immune to the substitution/persistence behavior above: zero saved config yields
  working defaults, and saved config still applies. The inline `lspServers` block and
  `docs/lsp.json.template` were moved to a literal `pwsh` command for the same reason.
- **`pwsh` (PowerShell 7) is now required to launch the hooks.** Windows PowerShell
  5.1 alone can no longer bootstrap them; it remains supported as the PSES *child*
  host via `ps_host`. See README "Requirements" and "Troubleshooting".

### Deviation from 1.1.0 (forced, field-evidence-backed)

This breaks byte-identity with the mande-tooling 1.1.0 source for `plugin.json`,
`scripts/session-start.ps1`, `scripts/lsp-client.ps1`, and `scripts/lib/lsp-common.ps1`.
The change is mandatory -- 1.1.0 is unusable on a clean install on CC v2.1.167
(evidence: the 000005 fresh-install proof, 2026-06-06). Same class of forced,
field-evidence deviation as the v4.6.0 rename-capability inversion in 1.1.0.

## [1.1.0] - 2026-06-05

### Added

- **Warm-start PSES daemon.** A long-lived, per-session process
  (`scripts/pses-daemon.ps1`) now owns one warm PowerShell Editor Services child
  (over stdio) and serves diagnostics over a named pipe
  (`powershell-lsp-<sessionid>`). This removes the per-edit cold-start that
  dominated the loose-hook latency.
- **PostToolUse client** (`scripts/lsp-client.ps1`): connects to the warm daemon,
  requests diagnostics for the edited `.ps1`/`.psm1`/`.psd1`, and returns them to
  Claude via `hookSpecificOutput.additionalContext`. Connect timeout 2s with one
  retry, 5s hard cap, and graceful degradation to log-only if the daemon is down.
- **SessionStart orchestration** (`scripts/session-start.ps1`): runs `ensure-pses`
  and `ensure-pssa`, sweeps rolling logs (keep-last-10 per family), reaps OUR
  stale daemons (recorded pids only, verified by command line), and launches
  exactly one daemon for the session.
- **SessionEnd teardown** (`scripts/session-end.ps1`): sends a graceful shutdown
  over the pipe (daemon issues LSP `shutdown`/`exit` to PSES, then exits), with a
  verified-pid fallback.
- **Pinned PSScriptAnalyzer** (`scripts/ensure-pssa.ps1`): vendors PSSA `1.25.0`
  into `${CLAUDE_PLUGIN_DATA}/modules`, prepended to the PSES child's
  `PSModulePath` so the analyzer pass runs (PSES emits only parser errors
  without it).
- **Shared library** (`scripts/lib/lsp-common.ps1`): host detection, file-URI
  construction, LSP framing, and diagnostics ordering/dedupe, dot-sourced by the
  daemon, client, hooks, and tests.
- Hooks declared as first-class plugin components (SessionStart, PostToolUse,
  SessionEnd) in `plugin.json`. `-NoLogo -NoProfile` on every host launch; all
  state, logs, and pids under `CLAUDE_PLUGIN_DATA` only.

### Encoded landmines

- **File URIs use UPPERCASE drive letters.** `[System.Uri].AbsoluteUri`
  lowercases the drive on .NET; the builder now fixes it back to uppercase.
- **Wait for the settled publish.** PSES publishes an early (often empty) parser
  pass before the PScriptAnalyzer pass; the daemon waits for a quiet window after
  the last publish rather than reporting the first.
- **Rename capability IS declared (deviation -- see below).**

### Portability and self-bootstrap hardening

- Zero hardcoded user paths in shipped scripts (verified by grep): every path is
  built from `CLAUDE_PLUGIN_DATA`/`CLAUDE_PLUGIN_ROOT` + `Join-Path`.
- Single shared host-detection helper `Resolve-PsHost` (prefer `pwsh`, fall back
  to `powershell`, log a clear message and abort bring-up if neither is found).
- Both bootstrap pins are documented with a one-variable bump path
  (`$PsesTag` in `ensure-pses.ps1`, `$PssaVersion` in `ensure-pssa.ps1`); see the
  README "Pinned versions" table.
- **Cross-platform forward-compat AUTHORED but not CI-verified here** (this build
  ran Windows only): `Test-OnWindows` guards isolate the one Windows-only call
  (`Win32_Process` command-line lookup) behind a cross-platform
  `Get-ProcessCommandLine` (Linux `/proc`, macOS `ps`); named pipes use
  `System.IO.Pipes` (Unix domain socket semantics on *nix are acceptable); no
  backslash path literals; the detached daemon launch is guarded per platform.
  Marked for CI verification in a later stage.
- Fresh-machine simulation passes: pointed at an empty `CLAUDE_PLUGIN_DATA`,
  SessionStart bootstraps PSES (`v4.6.0`) and PSScriptAnalyzer (`1.25.0`) from
  their pins and a diagnostics edit round-trips end to end.

### Testing and CI

- Pester 5 regression suite under `tests/`:
  - unit: file-URI drive-letter casing (Windows-gated), the rename-capability
    invariant (asserts it IS declared -- see the deviation below), shared host
    detection, diagnostics ordering/dedupe, and an ASCII-clean + parse check over
    every shipped `.ps1`;
  - integration (Windows): one-daemon bring-up, the settled PSScriptAnalyzer pass
    (an unapproved-verb fixture must yield `PSUseApprovedVerbs`, proving the
    early-publish wait), and clean SessionEnd with no orphaned daemon/PSES.
- `tests/run-tests.ps1` bootstraps Pester 5 to CurrentUser scope only and runs
  the suite. Green on BOTH local hosts: `pwsh` 7.6.2 and Windows PowerShell 5.1
  (35/35 each).
- `.github/workflows/powershell-lsp-ci.yml`: matrix `windows-latest` (`pwsh` +
  `powershell`) and `ubuntu-latest` (`pwsh`), triggered on pushes/PRs touching the
  plugin tree. Integration tests self-skip on Ubuntu (cross-platform daemon path
  is CI-verified later); the unit surface runs everywhere.
- Two real portability bugs surfaced by the dual-host requirement and fixed:
  - `ProcessStartInfo.ArgumentList` does not exist on .NET Framework (Windows
    PowerShell 5.1). Added `Add-ProcessArguments` (uses `ArgumentList` on pwsh --
    the proven path, unchanged -- and a hand-quoted `.Arguments` string on 5.1).
  - A Windows PowerShell 5.1 `StreamWriter` prepends a UTF-8 BOM to a child's
    stdin, which broke `ConvertFrom-Json` on the hook payload. Added BOM-tolerant
    `Get-StdinText`, now used by every stdin reader.

### Configurability and diagnostics polish

- Eight `userConfig` knobs (all with defaults), wired from `plugin.json` through
  the SessionStart/PostToolUse commands into the daemon and client:
  `severityThreshold`, `ruleInclude`, `ruleExclude`, `timeoutMs`, `debounceMs`,
  `keepLastN`, `idleTtlMin`, `perFileCap`. Each is documented in the README.
- Diagnostics output is now: stable-sorted (severity, then line, then column),
  deduped, filtered by severity threshold and rule include/exclude, then capped
  per file with an `... and N more (per-file cap)` line.
- Pester unit tests for the filtering knobs (threshold, include, exclude, cap,
  and rule-list parsing); green on both hosts. Manual end-to-end check confirms a
  non-default `severityThreshold`, a `ruleExclude`, and a `perFileCap` are all
  honored over the warm path.

### Deviation from the dispatch (rename capability, inverted)

The dispatch frontmatter and the build brief both said *"do not advertise rename
capability on initialize (PSES v4.6.0 NRE)."* This is **empirically backwards**
for PSES v4.6.0. Probe evidence (2026-06-05): initialize with `rename` **omitted**
=> PSES never answers initialize (`NO INIT RESPONSE`); initialize with a minimal
`rename` capability **declared** => clean handshake + diagnostics. The shipped
v1.0.0 README documents the same direction (the NRE fires when a client *omits*
rename). The daemon therefore declares a minimal rename capability, which is what
*avoids* the NRE. Reported in dispatch outbox 000001.

## [1.0.0] - 2026-06-01

### Added

- Initial release.
- PowerShell code intelligence via PowerShell Editor Services (PSES) as a Claude
  Code LSP server: diagnostics, hover, go-to-definition, and find-references for
  `.ps1`, `.psm1`, and `.psd1` files.
- `scripts/ensure-pses.ps1`: idempotent SessionStart bootstrap that downloads and
  expands the pinned PSES release (`v4.6.0`) into
  `${CLAUDE_PLUGIN_DATA}/PowerShellEditorServices`. Silent on stdout; logs to file.
- `scripts/pses-stdio.ps1`: silent stdio launcher that runs
  `Start-EditorServices.ps1 -Stdio` with `-NoLogo -NoProfile`, reserving stdout
  for the LSP stream.
- `ps_host` user config (`pwsh` default, `powershell` fallback).
- Ships disabled by default (`defaultEnabled: false`); opt-in enable.
