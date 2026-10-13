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
  it emits six rules (see the [corpus section](../README.md#diagnostic-correctness-corpus));
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
  *download failure* (offline/proxy) falls back (PSScriptAnalyzer: direct `.nupkg` download
  first, then the same `.nupkg` over PackageManagement) -- and **both** feed the one
  `Test-PinnedFileHash` gate, so the fallback fails closed exactly as the primary does.
- **The PowerShell Gallery / CDN throws transient 403s on hosted CI** (dispatch 000047).
  The fix already in place is an explicit User-Agent, a bounded 3-try retry on the
  download only, and a fallback that names the Gallery feed explicitly rather than depending
  on a registered `PSRepository`. If you see a
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

## Temporary RED exclusions are bounded, not blanket

Some tests are committed **failing on purpose**: they measure a defect that a later leg fixes
(dispatch 000302 measured the scan-verdict and scan read-only findings this way). Each such `It`
carries an owner tag (`ScanRed-A2`, `ScanRed-A3`) and `tests/run-tests.ps1` excludes those tags
by default, so CI stays green while the failures stay recorded. Three things keep that honest:

- **One list.** `tests/fixtures/scan-verdict/expected-red.psd1` names every excluded test, its
  owner, and the exact assertion message it is expected to fail with.
- **The oracle.** `tests/assert-expected-red.ps1` runs the listed files in full in a fresh
  process and passes only if each listed test fails with its declared assertion and every other
  test in those files passes. A setup crash, zero discovery, an unexpected pass, an unrelated
  failure, or an extra tagged test is a rejection. Run it under **both** hosts.
- **The guard.** `PowerShellLsp.ScanVerdict.Tests.ps1` fails if a RED tag sits on a `Describe` or
  `Context` (that would hide every test inside it), on a test the list does not name, or as a
  computed value -- or if the runner's default and the list disagree.

When a fix lands, its tests turn green and the oracle rejects them as unexpected passes. That is the
signal: remove the tag from the `It`, remove the entry from the list, and drop the tag from the
runner default once it has no entries left. Never widen a declared message to fit a different
failure. Dispatch 000304 (A2) did exactly that for all 39 `ScanRed-A2` tests and retired the tag;
only `ScanRed-A3` remains.

## A scanned file is analyzed only on a COMPLETE receipt

`scripts/lsp-scan.ps1` does not infer "analyzed" from silence -- a clean pass is silent by design, so
silence cannot tell a clean file from a child that never analyzed it (dispatch 000302 measured seven
ways that went wrong). In scan mode the client writes a typed completion receipt
(`scripts/lib/lsp-scan-receipt.ps1`), and `Invoke-ScanFileDiagnostics` reports a file analyzed only
when `Test-ScanReceipt` finds it complete: right request id, right file, the daemon-consumed SHA-256
equal to the bytes on disk before and after, a settled PSScriptAnalyzer pass, and the finding digest
equal to the records read back. Things that bite when you change this path:

- **Scan mode rides the hook PAYLOAD, never the environment** (`powershell_lsp_scan`). An ambient
  variable must never be able to turn an interactive edit into a scan; the client loads the receipt
  library only for a scan-mode payload, so the edit path does not even parse it.
- **The receipt is written in the client's `finally`**, so every exit -- including the fail-safe ones
  -- leaves exactly one receipt. Add a new early exit? Record its reason with `Add-ScanOutcomeReason`
  first, or the scan will read it as a generic `analysis-not-run`.
- **Do not wrap a receipt field read in `@(...)`.** `Get-ScanReceiptField` returns an array as ONE
  object (the comma operator, so a one-element array is not unrolled); `@(Get-ScanReceiptField ...)`
  nests it and a multi-reason list stringifies into one element. Assign first, then wrap.
- **A new reason code is a schema change**: add it to the reason table AND to
  `docs/scan-receipt.schema.json`; `tests/PowerShellLsp.ScanReceipt.Tests.ps1` fails until both agree.
- **Every scan child goes through `Invoke-ScanChildProcess`**, which drains both streams before it
  waits, kills the tree on both Windows hosts (`Kill($true)` does not exist on 5.1; it falls back to
  `taskkill /T`) and contains `formatOnEdit` off under every spelling. The HookInstrumentation guard
  holds it to that by name.
- **A scan child's stdin payload is pure ASCII.** The child decodes stdin with the code page of the
  console it is attached to, and inheriting the scanner's console does not make that UTF-8: a stock
  Windows console sits at the OEM code page (437 on en-US). So `Invoke-ScanChildProcess` writes every
  payload through `ConvertTo-ScanAsciiJson`, which turns each non-ASCII character into a JSON `\uXXXX`
  escape; without it a non-ASCII file path or data root (the default data root is under the user
  profile) arrives mangled and every file reads receipt-missing (dispatch 000304, review A2-F01).
- **Do not set `CreateNoWindow` on a scan child either** -- for the BOM, not the code page. A Windows
  PowerShell 5.1 parent on a UTF-8 console writes a UTF-8 BOM ahead of the payload; a child sharing that
  console strips it (`Get-StdinText`), but a child on a new console (OEM again) reads three characters
  nothing strips, and nothing parses. `tests/PowerShellLsp.ScanReceipt.Tests.ps1` pins a console of its
  own to code page 437 and round-trips a non-ASCII path and data root under it on whichever host runs
  it, beside a raw-UTF-8 control that must arrive mangled -- so the test cannot pass on a UTF-8 console
  alone, which is how the guard it replaced did.

## Policy has one resolver, and evidence is not a verdict

`scripts/lib/lsp-policy.ps1` (dispatch 000305) is the only place an org policy's EFFECTIVE form and
identity are computed; the hook, the daemon and the scan all read the file through `Import-OrgPolicy`
and never parse it a second way. Things that bite when you change this path:

- **`Get-Prop` cannot read a dictionary.** It sees PSObject properties only, and `Import-OrgPolicy`
  returns a `[hashtable]`; a key read through `Get-Prop` comes back `$null` and a policy silently
  reads as empty. Use `Get-PolicyField` (both shapes) in policy code.
- **`Get-PolicyStringList` returns its array through the comma operator.** Assign it, then count it:
  `@(Get-PolicyStringList ...)` nests the array and every count reads 1.
- **A receipt carries evidence; only a managed scan certifies.** `policy.state` is `unbound` or
  `observed`, never `verified`; `Test-ScanPolicyCertification` decides, from evidence, and every code it
  can return must be in `Get-PolicyReasonTable` (a test reads the function body and holds them together).
- **The merged settings file is content-addressed** (`orgpolicy-settings/merged-settings-<sha16>.psd1`)
  because PSES hands PSScriptAnalyzer the settings PATH on every pass: a shared fixed name let one
  daemon rewrite what another enforced. Never write it in place; `Write-MergedPssaSettingsFile` returns a
  path only after re-hashing the bytes on disk.
- **PSScriptAnalyzer rejects an unknown settings key, and then nothing is analyzed.** Its valid keys are
  `CustomRulePath`, `ExcludeRules`, `IncludeRules`, `IncludeDefaultRules`, `RecurseCustomRulePath`,
  `Rules` and `Severity`; a settings file with any other key (`RuleArguments`, `Severities`) makes every
  analysis fail inside PSES, which still publishes an empty, settled result -- zero findings that look
  clean (measured 2026-10-13 against the vendored PSSA). Do not build a test fixture on such a key.

## The public contract has teeth

The `userConfig` knob **names** and the status **token set** are drift-guarded in CI
against `plugin.json` and the banner functions. Add a knob to the manifest or rename a
token, and CI goes red until [CONTRACT.md](../CONTRACT.md) **and** the README are updated to
match (they are guarded by separate tests so the red leg names which doc drifted). Read
CONTRACT.md before touching either source.
