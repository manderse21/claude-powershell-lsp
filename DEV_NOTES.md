# Developer notes -- the quirks that bite

Hard-won, non-obvious things about this codebase. If you are about to change the
runtime, skim this first: most of these are bugs that already happened once and are now
guarded, and the guard is easy to defeat by accident. Each note says where it is
enforced so you can confirm it is still true rather than trusting this prose.

## ASCII-only in every `.ps1`

Windows PowerShell 5.1 reads a UTF-8-without-BOM file through the Windows-1252 codepage,
so a single em dash, curly quote, or other non-ASCII byte silently corrupts the parse on
the 5.1 CI leg. **Keep every `.ps1`/`.psm1`/`.psd1` byte in ASCII (0x00-0x7F)** -- write
`--` not an em dash, straight quotes only. This is why source comments use `--`
everywhere. The corpus generator even writes its scratch files with `ASCIIEncoding` for
the same reason. When in doubt, grep for non-ASCII before committing:
`grep -rnP '[^\x00-\x7F]' scripts tests`.

## PowerShell 5.1 traps

The shared library (`scripts/lib/lsp-common.ps1`) must keep working under 5.1 as the PSES
child host, so:

- **No `$IsWindows` / `$IsLinux` / `$IsMacOS`** -- those automatic variables do not exist
  in 5.1. Gate platform with `Test-Path 'Variable:\IsWindows'` first (StrictMode-safe), or
  go through the shared `Test-OnWindows` helper.
- **The `ArgumentList`-vs-quoted-`.Arguments` split.** Process launches are built through
  the shared `Add-ProcessArguments` helper because 5.1 and 7 quote process arguments
  differently; do not hand-build a `.Arguments` string.
- **Empty-array -> `$null` collapse.** Returning `@()` from a function or binding it to a
  param can collapse to `$null`. The corpus helpers wrap returns in `@(... )` and filter
  `$null` for exactly this reason; mirror that when a function may return zero items.
- **BOM-tolerant stdin.** Hook stdin may arrive with or without a BOM; the framing code
  tolerates both. Do not assume a clean UTF-8 stream.

## Never write to stdout on the daemon/LSP path

The hooks communicate with Claude Code over stdout (the `additionalContext` JSON). Any
stray `Write-Output` / `Write-Host` on the daemon or client path corrupts that channel.
All scripts run `-NoLogo -NoProfile`, and the daemon's own stdout/stderr are redirected to
files. Related and subtle: on **non-Windows**, a detached daemon launched with a bare
`Start-Process` inherited the hook's standard handles and stalled the session (dispatch
000026). The daemon's three standard streams are redirected to files on non-Windows on
purpose -- do not "simplify" that away.

## The daemon is pipe-first, and that is load-bearing

`pses-daemon.ps1` opens its request pipe **before** bringing PSES up (dispatch 000028).
This is what lets a first edit that races startup receive an honest `incomplete` /
`unavailable` banner instead of silence. **Never reintroduce blocking-before-pipe** (e.g.
"just initialize PSES first, then open the pipe") -- that recreates the no-pipe silent
miss the design exists to prevent. The client (`lsp-client.ps1`) carries a second backstop
for the residual no-pipe window (the ~150 ms launch sliver, or a daemon that stopped after
idle): it surfaces its own "analyzer not reachable" banner on a `$null` result. The
auto-relaunch on that `$null` seam (dispatch 000030) is spin-proof *because* a permanently
failed daemon parks **alive** as `unavailable` (never `$null`), so it is never relaunched
in a loop. Keep that distinction: `$null` = no daemon (relaunch); `unavailable` =
parked-permanent (do not).

## PSES (v4.6.0) quirks

- **`PrepareRenameHandler` NullReferenceException.** PSES v4.6.0 dereferences a null
  `RenameCapability` when a client omits `rename` from its `textDocument` capabilities.
  The daemon declares a **minimal `rename` capability on purpose** to dodge this. If you
  trim the declared capabilities, you can resurrect the NRE.
- **PSES surfaces a narrower default ruleset than the PSScriptAnalyzer CLI.** On the fly
  it emits six rules (see the [corpus section](./README.md#diagnostic-correctness-corpus));
  the CLI default flags more. The plugin's config knobs can suppress or narrow what PSES
  reports; they cannot add a rule PSES does not run.
- **Native `.lsp.json` registration is inert** for plugin-provided servers through Claude
  Code 2.1.183 (re-probed; see the README). The hook is the product; native registration
  is a future bonus, which is why `pses-stdio.ps1` exists but no root `.lsp.json` ships.

## The dependency download fails closed -- and CI egress flakes

`ensure-pses.ps1` / `ensure-pssa.ps1` verify each download against a SHA-256 computed from
the real known-good artifact **before** use; a mismatch is refused (the session reads
`unavailable`, editing keeps working). Two things to know:

- **A hash mismatch never falls back and never retries** -- it fails closed. Only a
  *download failure* (offline/proxy) falls back (PSScriptAnalyzer: verified `.nupkg` first,
  then `Save-Module`).
- **The PowerShell Gallery / CDN throws transient 403s on hosted CI** (dispatch 000047).
  The fix already in place is an explicit User-Agent, a bounded 3-try retry on the
  download only, and registering the default PSGallery repo when it is absent. If you see a
  one-off 403 on a CI leg, it is almost certainly this egress flake, not a 5.1 or
  User-Agent bug -- re-run before assuming a real regression.

## The corpus snapshots are tool-DERIVED, never hand-authored

Every `tests/corpus/expected/*.json` is produced by running the **real tool** over the
sample (`tests/corpus/Update-CorpusSnapshots.ps1`) and recording what it actually emitted,
through the plugin's own dogfood capture channel. The corpus test re-derives the same way
and asserts a match. **A hand-edited snapshot cannot make the test pass** -- it would
simply disagree with the live tool. To add or change a case: write the `.ps1` sample, run
the generator, review the diff, commit. A clean (known-good) sample must derive to `[]`; a
known-bad sample must surface its expected rule (the first dot-segment of its filename). If
a "clean" sample you believe is idiomatic surfaces a finding, that is either an authoring
mistake (fix the sample) or a real false positive (surface it -- do not suppress it to keep
the published 0% rate).

## Pester gotchas

- **`Should -Be` is case-insensitive.** For a case-sensitive assertion (URI drive-letter
  casing, exact tokens) use `Should -BeExactly`, or an adversarial control will pass when
  it should fail. The integration and corpus suites use `-BeExactly` deliberately.
- **Angle brackets in a test title are a `-ForEach` template.** A literal `<plugin-root>`
  in an `It` / `Describe` name is parsed as `$($plugin-root)` and throws at run time. Keep
  `<...>` out of non-`-ForEach` test titles.
- **Discovery-time `$script:` variables do not survive into the run phase** for a
  data-driven `-ForEach` block; re-enumerate inside the `It` if you need the data at run
  time (the corpus test does this).

## The public contract has teeth

The `userConfig` knob **names** and the status **token set** are drift-guarded in CI
against `plugin.json` and the banner functions. Add a knob to the manifest or rename a
token, and CI goes red until [CONTRACT.md](./CONTRACT.md) **and** the README are updated to
match (they are guarded by separate tests so the red leg names which doc drifted). Read
CONTRACT.md before touching either source.
