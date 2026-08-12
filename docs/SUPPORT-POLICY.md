# Support and deprecation posture

**What a user of `powershell-lsp` may rely on**, stated at the level the project can actually
back -- which means it is bounded by what CI verifies and by what the release contract freezes,
and by nothing else. Where a thing is untested, this document says untested rather than implying
it works.

Two neighbouring documents answer different questions and are not restated here:
[SECURITY.md](../SECURITY.md) "Supported versions" is the **security-backport** policy (latest
release only); [CONTRACT.md](../CONTRACT.md) freezes the **configuration surface** (knob names,
status tokens) and the 1.x semver rules. This file covers **hosts, runtimes, and deprecation**.

## Supported hosts

Support means **CI-verified on every release**: the four legs below are required status checks on
`main`, so a release cannot be cut with any of them red
(`.github/workflows/powershell-lsp-ci.yml`; Gate 4 in
[docs/RELEASING.md](./RELEASING.md#what-the-pipeline-validates-the-gates)).

| CI leg | Runner image | Interpreter |
|---|---|---|
| `windows-pwsh` | `windows-2025` | `pwsh` (PowerShell 7) |
| `windows-powershell` | `windows-2025` | `powershell` (Windows PowerShell 5.1) |
| `ubuntu-pwsh` | `ubuntu-24.04` | `pwsh` (PowerShell 7) |
| `macos-pwsh` | `macos-15` | `pwsh` (PowerShell 7) |

**The two PowerShell roles are not interchangeable, and the distinction is the whole posture:**

- **Hook interpreter -- `pwsh` (PowerShell 7) is required.** Since 1.1.1 the plugin's hooks run
  under `pwsh` only. Windows PowerShell 5.1 is **not** supported as the hook interpreter
  ([README.md](../README.md), "Platform support").
- **PSES child host -- 5.1 is supported here.** Windows PowerShell 5.1 is a supported host for the
  PowerShell Editor Services child process, selected with the `ps_host` knob set to `powershell`.
- **What the `windows-powershell` CI leg proves.** It exercises the **shared-library surface** under
  5.1 -- file-URI casing, BOM-tolerant stdin, the `ArgumentList`-vs-quoted-`.Arguments` split, and
  the config-env fallback. It is not a claim that the hooks run under 5.1.

**Operating systems.** Windows, Ubuntu, and macOS are CI-verified at the images above, with the
warm-daemon integration suite green on all four legs. Other distributions and other Windows or
macOS versions are **not tested** -- they are neither promised nor ruled out, and no claim is made
about them in either direction.

## Test framework: Pester 5.x, with 6.x deliberately deferred

The test bootstrap is **bounded to the Pester 5.x major**, not pinned to an exact patch:
`tests/run-tests.ps1` installs and imports with `-MinimumVersion 5.0.0 -MaximumVersion 5.99.99`, and
a guard test goes RED if that bound is silently removed. **5.7.1 is what currently resolves inside
that bound** -- an observed value, not a pin.

**Pester 6 is deferred deliberately, and the reason is recorded.** Pester 6.0.0 went GA on the
PowerShell Gallery on 2026-07-07. The bound exists so a breaking new major is absorbed by a
decision rather than by runner-image luck. Pester 6's parallel-execution model has not been
evaluated against the daemon-backed integration tests, which is the first thing an upgrade would
have to establish. Revisit when a forcing function appears; no dispatch is open
([docs/decision-ledger.md](./decision-ledger.md)).

This affects **contributors running the suite**, not consumers of the plugin -- Pester is not a
runtime dependency.

## Claude Code versions

**No minimum or maximum Claude Code version is declared, anywhere in this repository.** That is the
honest state and not an omission to be papered over: the plugin is installed by a Claude Code client
whose version the project does not pin, test a matrix of, or gate on.

What the project *does* track is **specific known-bad versions**, recorded when observed:

- **Claude Code 2.1.196-2.1.200 on Windows.** These versions refuse to start the plugin's LSP
  server -- a launcher-level guard rejects the bare `pwsh` command pre-spawn -- so the **native
  navigation tier does not start on Windows** even with `nativeServe = shim`. This is an upstream
  regression (it also breaks the official `pyright-lsp` plugin), filed as
  [`anthropics/claude-code#73961`](https://github.com/anthropics/claude-code/issues/73961).
- **The core PostToolUse diagnostics are unaffected** by that defect -- they run through a
  different, unguarded spawn path.
- **macOS and Linux under those same Claude Code versions are untested** with the real client. No
  claim is made in either direction.

Full analysis: [docs/upstream/claude-code-lsp-registration.md](./upstream/claude-code-lsp-registration.md)
and [docs/configuration.md](./configuration.md).

## Deprecation: how a removal would be announced

Nothing is deprecated today. This section states the mechanism so a future removal is not the first
time anyone has to ask what the rule is.

**The semver rules are [CONTRACT.md](../CONTRACT.md)'s, and are not restated here.** What that
contract already settles:

- Removing or renaming a `userConfig` knob, removing or renaming a status token, or otherwise
  breaking a config or workflow a 1.x user depends on **requires a MAJOR (2.0.0)**.
- Adding a **newly CI-verified platform** is a MINOR.
- New surface is **adjudicated, not automatic**; when in doubt whether a change is observable to an
  existing 1.x user, it is treated as observable.

**Dropping a supported host is the same class of change as removing a knob** -- it breaks a
workflow a 1.x user depends on -- so it takes the MAJOR path, not a quiet matrix edit.

**Where an announcement appears.** The [CHANGELOG](../CHANGELOG.md) is the announcement surface: a
release's entry becomes its GitHub release body verbatim, so anything stated there reaches the
readers most likely to be relying on it. A deprecation would be recorded in the CHANGELOG entry of
the release that first announces it, carried under its `MAJOR` / `MINOR` / `PATCH` classification,
with the removal itself landing in a later release rather than the same one.

**What this project does not promise.** No calendar-based support window, no long-term-support
branch, and no backports -- security fixes go to the latest release only
([SECURITY.md](../SECURITY.md)). Those are staffing commitments, and this is a
single-maintainer project ([MAINTAINERS.md](../MAINTAINERS.md), [CONTINUITY.md](../CONTINUITY.md)).
Stating a window the project cannot hold would be worse than stating none.
