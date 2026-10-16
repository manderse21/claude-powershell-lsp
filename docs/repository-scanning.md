# Repository and CI validation

The same diagnostics engine, run as a standalone gate over a path instead of over the file Claude
just edited. Summarized in
[README, Repository and CI validation](../README.md#3-repository-and-ci-validation-opt-in); this
page is the full text.

The same diagnostics engine is also a standalone gate. `scripts/lsp-scan.ps1` runs over a path --
one file or a whole directory -- and emits **SARIF 2.1.0** for GitHub code scanning, or a
human-readable text report.

```powershell
# Scan a directory, emit SARIF for code scanning (the default format):
pwsh -File scripts/lsp-scan.ps1 ./src -OutputPath results.sarif

# Scan a single file, human-readable text:
pwsh -File scripts/lsp-scan.ps1 ./build.ps1 -Format text

# Fail the build (exit 2) if any warning-or-worse finding is present:
pwsh -File scripts/lsp-scan.ps1 ./src -Format text -FailOn warning

# Apply an organization policy to the whole analysis, and certify that it was applied:
pwsh -File scripts/lsp-scan.ps1 ./src -OrgPolicyPath C:\policy\org.psd1 -PolicyMode closed
```

**One engine, in-agent and in-CI.** The scan is a *sibling* invocation of the exact path the
PostToolUse hook uses -- same warm daemon, same `scripts/lsp-client.ps1`, same pinned
SHA-256-verified analyzer -- so a finding is identical whether it surfaces while Claude edits or
in your CI. A test (`tests/PowerShellLsp.SarifScan.Tests.ps1`) runs the whole correctness corpus
through the scan entry point and asserts its findings match the in-agent snapshots exactly.

Only `.ps1` / `.psm1` / `.psd1` are scanned; a directory recurses by default (`-NoRecurse` limits
to the top level). Severity maps honestly to SARIF's four levels (Error -> `error`, Warning ->
`warning`, Information and Hint -> `note`; nothing maps to `none`, and an unknown severity maps to
`warning` so a finding is never silently dropped). Exit codes: `0` completed, `2` `-FailOn`
threshold met, `3` usage error, `4` scan incomplete (an unanalyzed file is never reported clean) --
or, for a managed scan (`-PolicyMode closed`), NOT CERTIFIED: the scan cannot vouch that the declared
policy was applied ([below](#policy-the-full-main-pass-and-managed-scans)).

## Completion receipts: when a file counts as analyzed

A file counts as analyzed **only** when the scan holds positive evidence that its analysis
completed. Silence is not evidence: a healthy clean pass is silent on the edit path by design, so
"the child said nothing" cannot tell a clean file from a child that never ran the analysis.

For each file the scan mints a fresh request id and asks the client, in its hook payload, to write
a **completion receipt** (`scripts/lib/lsp-scan-receipt.ps1`; schema in
[`scan-receipt.schema.json`](scan-receipt.schema.json)). The daemon answers that request with the id
echoed and a binding of what it actually analyzed: the normalized path, the SHA-256 of the exact bytes
it read and handed to PSES, whether the pass settled and whether PSScriptAnalyzer was available. The
scan then validates the receipt:

- the request id and the file are the ones it asked about;
- the bytes the daemon consumed are the file's bytes on disk, read by the scan just before and just
  after the analysis (a file that changed or vanished meanwhile is not certified);
- the receipt's own facts support what it claims (a well-formed receipt that says `degraded` and
  `complete` is refused -- a valid envelope proves nothing on its own);
- the finding records read back match the receipt's count and digest (the digest covers each
  message, so a transport that dropped messages cannot pass);
- the child exited on its own with exit code 0.

A receipt carries two separate fields. **status** is one of the four public tokens
([CONTRACT.md](../CONTRACT.md) 1.2) and means what it means on the edit path. **completeness** is an
additive, scan-only field:

| status | what ran | completeness | counted as analyzed |
|---|---|---|---|
| `ok` | settled PSScriptAnalyzer pass over bound bytes | `complete` | yes |
| `ok` | the file does not parse (parser short-circuit) | `partial` (`parse-errors`) | no -- findings reported, exit 4 |
| `ok` | the byte pre-pass stopped the analysis (smart punctuation) | `partial` (`pre-pssa-short-circuit`) | no -- findings reported, exit 4 |
| `ok` | a per-file cap or an edit-range scope applied | `partial` | no |
| `degraded` | parser-only pass, PSScriptAnalyzer absent | `partial` (`pssa-unavailable`) | no |
| `incomplete` | the pass did not settle | `failed` (`analysis-not-settled`) | no |
| `unavailable` | PSES could not start, or managed policy refused | `failed` | no |
| (none) | no receipt, an unreadable one, or one for another request, file or bytes | `failed` | no |

Every file that is not complete is named in the INCOMPLETE report with machine reason codes -- on
stderr, in text mode, and in the SARIF `invocations[].toolExecutionNotifications[]` entry for the
file (in the message text and in a `properties.reasons` array). The full code list, with what each
means, is the reason table in `scripts/lib/lsp-scan-receipt.ps1`. Findings from a file that is not
complete are still reported; they are simply never presented as a complete result.

**What a receipt does not certify.** The configuration the daemon was launched with is recorded as
*observed* and the receipt marks it **unbound**: binding a declared scan environment is separate,
later work (A3). Since schema version 2 (dispatch 000305) a receipt also carries the policy
application evidence each party recorded -- `policy.state` `observed` -- but that is evidence, never a
verdict: a receipt that claims its policy `verified` or `certified` is malformed, and only a managed
scan certifies, from that evidence (next section). Engine versions are the ones the daemon reads from the PSES and
PSScriptAnalyzer module manifests it launches with, or `unknown` -- never a pinned value standing in
for an observation; the version PSES loaded in-process is not queried. A scan child's output is held
in memory while it is drained, so a pathological child that writes without limit costs memory up to
the per-file cap.

## Policy: the full main pass and managed scans

**`-OrgPolicyPath` governs the whole analysis** (dispatch 000305; owner ruling O03). The scan resolves
the policy once ([`scripts/lib/lsp-policy.ps1`](../scripts/lib/lsp-policy.ps1), through the same reader
the edit hook uses) and hands the declared path to every child it starts, removing any ambient
`orgPolicy` under every spelling first: the daemon merges `RequiredRules` into the rules PSES runs, and
each file's hook applies `ExcludeRules`, `SeverityOverrides` and `ProhibitedSuppressions` -- exactly as
while editing -- before the scan's own suppression re-surfacing pass runs. Before this release the flag
drove only that last pass. A scan given `-OrgPolicyPath` reports the policy in its SARIF
(`runs[0].invocations[0].properties.policy`: the mode, the declared path and file hash, the **policy
identity** `effective.sha256`, member counts, obligations and the verdict) and in the text report's
`Policy:` lines; a scan without it, unmanaged, emits exactly what it always did. The canonical
identity's hashing rules are in [configuration](configuration.md#policy-identity-and-application-evidence-dispatch-000305).

**`-PolicyMode closed` is the managed mode, and only when given explicitly** (owner ruling Q03, dispatch
000306). `POWERSHELL_LSP_POLICY_MODE` keeps its interactive fail-closed meaning and never makes a scan
managed, so `/powershell-lsp:scan` -- which has no policy option -- is always unmanaged. A managed scan
is **CERTIFIED** only when every one of these holds; each failure is named by its code on stderr, in
the text report, and as a SARIF `toolExecutionNotifications` entry with `properties.reason`, and the
scan exits `4` with `executionSuccessful=false`:

| Code | The scan refuses because |
|---|---|
| `policy-not-declared` | no `-OrgPolicyPath` -- a managed scan needs a declared policy (an interactive edit with no policy is still a no-trigger) |
| `policy-file-missing`, `policy-path-relative`, `policy-unreadable`, `policy-integrity-*` | the declared policy cannot be used (the same degrades the edit hook fails closed on) |
| `config-ambient` | a `CLAUDE_PLUGIN_OPTION_*` that changes analysis (rule lists, threshold, cap, settings, ruleset, profile, host, ...) reached the scan from its environment |
| `analysis-incomplete` | a file has no COMPLETE receipt |
| `analysis-empty` | the target holds no PowerShell file, so nothing shows the policy was applied (an unmanaged scan of such a target still exits `0`) |
| `policy-evidence-missing` | a file's receipt carries no application record from the hook or the daemon -- or the daemon's record says it has applied nothing: still `pending`, or `settings-unresolved` (its settings resolution threw, so nothing was handed to PSES), or it carries no settings verdict |
| `policy-disagreement` | the hook or the daemon applied a policy whose identity differs from the declared one |
| `policy-activation-unsupported` | `RequiredRules` could not be activated: the running PSES version is not one the pinned default list was verified for |
| `policy-merge-write-failed` | the merged settings file could not be written and read back intact |
| `policy-activation-not-delivered` | the merged settings were not pushed to PSES, or the settings file changed after they were |
| `policy-settings-rejected` | PSScriptAnalyzer would reject, or could not read, a settings file the analysis rests on -- the repository's, or the merged one ([below](#settings-files-the-analysis-rests-on-dispatch-000306)) |
| `policy-suppression-pass-failed` | the `ProhibitedSuppressions` re-surfacing pass could not run |
| `config-observed-mismatch` | the daemon reports an analysis configuration other than the scan's declared one |
| `engine-unknown` | the engine versions could not be observed |

**Not required is not failed.** A policy with no `RequiredRules` needs no merged settings, one with no
prohibitions needs no suppression pass; the daemon reports `not-required` and the scan certifies.

**Unmanaged stays unmanaged.** Without `-PolicyMode closed` nothing is certified or refused: an unusable
`-OrgPolicyPath` is a warning on stderr and the findings are reported without it (fail-open, as
before), a failed merged-settings write simply leaves the required rule inactive, and a settings file
PSScriptAnalyzer would reject is a warning on stderr while the findings come from PSES's default rules
instead ([below](#settings-files-the-analysis-rests-on-dispatch-000306)). The local
severity-threshold boundary ([configuration](configuration.md#severityoverrides----how-an-organization-states-a-requirement))
applies to developer assistance only; a managed scan declares `Hint` and refuses anything else.

**What certification does and does not prove.** It proves that, at each file's analysis, the hook and
the daemon both applied the policy whose identity the scan resolved, that a required rule's merged
settings were written, verified and handed to PSES (running every required rule -- named in
`IncludeRules` when the merged file has one, taken out of a repository's `ExcludeRules`, and switched
on when it is configurable, so a repository's `Enable = $false` cannot keep one off: review finding
B1b-R01 -- while every rule the repository's own settings file runs still runs: a file PSScriptAnalyzer
accepts that names no `IncludeRules` gets none in the merged file either, where the merge used to narrow
it to PSES's 15 defaults plus the required rules, and certify: owner ruling R03, review finding B1b-R03),
that the settings file PSES reads still hashed to
what was written, and -- since dispatch 000306 -- that the daemon found every settings file the analysis
rests on, the repository's and the merged one, to be one PSScriptAnalyzer accepts, by the checks
[below](#settings-files-the-analysis-rests-on-dispatch-000306). Beside a repository's `CustomRulePath`
the merged settings also set `IncludeDefaultRules = $true` whenever a required rule is a built-in one
(review finding B1b-K02): without it PSScriptAnalyzer loads only the custom rules, and a required
built-in rule never ran while the scan certified; in a file that names no `IncludeRules` it runs every
enabled built-in rule beside the custom ones, more than that file runs alone. It does NOT prove that a rule module
or assembly a `CustomRulePath` reaches holds a rule (the one boundary that check leaves, described there
and left to leg A3's runtime signal), nor that a required rule that needs settings the repository does
not give it could run (`PSUseCompatibleCommands` and `PSUseCompatibleTypes` need `TargetProfiles`, and
without them find nothing -- [configuration](configuration.md#requiredrules----forcing-a-rule-onto-the-analysis-surface-dispatch-000294)), and it does
not make the plugin tamper-proof: a process running as the same user can edit the policy, its sidecar,
the plugin and its evidence. Run release gates on a protected runner whose policy someone other than the
change's author controls. Until the declared child configuration lands (leg A3), a managed scan run with
ambient plugin options set is refused rather than certified around them.

**A scan never formats.** Every scan child gets `formatOnEdit=off` under exactly one spelling --
every other spelling the option resolver accepts is removed from its environment first -- so a
`formatOnEdit=apply` inherited from the caller cannot rewrite the files being scanned.

**This repository scans itself.** `.github/workflows/powershell-lsp-code-scanning.yml` uploads
SARIF to GitHub code scanning on every push to `main`, weekly, and on demand -- a separate
workflow from the CI legs, so it can never turn a merge gate red. Copy it as a starting point;
two details are deliberate: it scans `scripts/` rather than the repo root (because
`tests/corpus/samples/` is deliberately-bad code), and it pins `upload-sarif` by **commit SHA**,
not by tag.

## Settings files the analysis rests on (dispatch 000306)

A `PSScriptAnalyzerSettings.psd1` that PSScriptAnalyzer rejects does not make PSES fail visibly: PSES
analyzes **nothing** and still publishes a settled, empty result, so a scan over such a repository
used to read complete and clean -- unmanaged and managed alike. So before PSES is handed any settings
file, the daemon reads it the way PSScriptAnalyzer does, as data (parsed, never run:
`Read-PssaSettingsFile`), and checks what PSScriptAnalyzer 1.25.0 was **measured** to require, on
Windows PowerShell 5.1 and PowerShell 7 alike:

- the file holds a settings table, and every value in it is data: a constant, `$true`/`$false`/`$null`,
  an array, a table, a cast, or one of those in parentheses or behind a sign (`('A', 'B')`, `($true)`,
  `-(5)`) -- no command, no variable but `$true`/`$false`/`$null`, no expandable string;
- every key is one PSScriptAnalyzer accepts -- `CustomRulePath`, `ExcludeRules`, `IncludeRules`,
  `IncludeDefaultRules`, `RecurseCustomRulePath`, `Rules`, `Severity`, in any case;
- `Severity`, `IncludeRules`, `ExcludeRules` and `CustomRulePath` are a string or an array of strings;
  every `Severity` entry names a PSScriptAnalyzer severity (`Hint` does not); `IncludeDefaultRules` and
  `RecurseCustomRulePath` are booleans; `Rules` is a table of tables; no value anywhere in a table is
  `$null`;
- `CustomRulePath` is not empty, and every entry is a path that means the same thing from any directory
  -- a full path (`C:\rules`, `\\server\share\rules`, `/opt/rules`), a `~` path, or either behind
  `FileSystem::` -- that PowerShell's own path resolver, the call PSScriptAnalyzer makes for each entry,
  resolves without error (a wildcard that matches is used; one that matches nothing is no error by
  itself -- but see the next point). PSES
  runs from the daemon's own working directory, not the repository's, so through the real daemon a
  relative entry made PSES analyze nothing, `IncludeDefaultRules` or not; a drive-relative entry
  (`C:rules`) or a root-relative one (`\rules`) depends on the current directory too and is refused the
  same way;
- unless `IncludeDefaultRules = $true`, the `CustomRulePath` entries together reach a rule source
  PSScriptAnalyzer loads (review finding B1b-K01): a `.psm1`, `.psd1` or `.dll` file, a module directory
  (one holding a module named for it, itself or in a version folder), or a directory holding
  assemblies -- and, with `RecurseCustomRulePath = $true`, any such directory below it. A wildcard that
  matches nothing, an empty directory, a `.txt` or `.ps1`, or a directory whose module is named
  otherwise reaches none; PSScriptAnalyzer then finds no rules ("Cannot find ScriptAnalyzer rules in the
  specified path") and PSES analyzes nothing. One entry that reaches nothing beside one that does is
  fine, as it is to PSScriptAnalyzer.

The verdict -- `valid`, `rejected`, `unparsable`, or `none` when no settings file was resolved -- is
recorded in the daemon's application evidence (`policy.daemon.settings.validation`, with a one-line
`validationDetail`), which every scan receipt carries. A file that fails is **not handed to PSES**: an
unmanaged scan says so on stderr and its findings come from PSES's default rules; a managed scan is NOT
CERTIFIED with `policy-settings-rejected`. **The settings file is validated when a PSES session starts**
-- the daemon resolves and checks it once per PSES session, at that session's first analyzed file -- and
**an edit to it during a session is validated at the next session** (owner ruling K08, review finding
B1b-K08). Until then PSES re-reads the edited file on every pass, unchecked, and the session's evidence
still carries the verdict it recorded when the session started; rechecking the file at analysis time is
left to leg B2.

When `RequiredRules` merges, the merged file carries exactly the repository file's **accepted** entries
-- its `Rules` (each rule's `Enable` flag and arguments, every number keeping its type: `[uint32]`,
`[byte]`, `[single]`, a decimal and the rest -- review finding B1b-I01) and `Severity` included -- and
never a rejected one, and it is checked the same way before PSES sees it. Before this release the merge dropped `Rules`
and `Severity` and carried `Severities`, `RuleArguments` and `FilePath`, which PSScriptAnalyzer rejects:
a repository's configurable rules (`PSAvoidLongLines` switched on through `Rules`, say) went silent, and
a repository file already holding one of those keys produced a merged file PSES analyzed nothing with.
(`Severity` in a settings file has no observable effect under PSES, which passes its own `-Severity`
beside it -- measured -- so carrying it changes nothing you can see; `Rules` is the one that matters.)
And the merge narrows nothing the repository runs (owner ruling R03, review finding B1b-R03): when the
repository's file is one PSScriptAnalyzer accepts and names no `IncludeRules`, the merged file names none
either, so every rule that file runs -- those its `Rules` entries switch on and its `CustomRulePath`
rules included -- still runs beside the required ones. Before, the merge wrote PSES's 15 defaults plus
the required rules as `IncludeRules` there: carrying `Rules` did not make `PSAvoidLongLines` run unless
the file also named it in its own `IncludeRules`, and a managed scan certified without the repository's
other rules (measured through the real daemon, both hosts). With no settings file, or one that names its
own `IncludeRules`, the merged file is byte-for-byte what it was. A
managed scan over a repository file with a rejected key is refused even though the merged file, without
that key, was valid and was used: the analysis did not run on the settings the repository declared.
One entry of `Rules` is not the repository's to keep: every configurable rule `RequiredRules` names is
written with `Enable = $true` (owner ruling R01, review finding B1b-R01) -- before, a repository's
`Enable = $false` switched a required rule off while a managed scan certified, and a required rule that
is off by default never ran ([configuration](configuration.md#requiredrules----forcing-a-rule-onto-the-analysis-surface-dispatch-000294)).

**What the check cannot see.** It reads the settings file and lists the directories a `CustomRulePath`
reaches, but loads nothing: a rule source that resolves but holds no rule -- a module that exports no
rule function, a `.dll` that is no rule assembly -- passes the check, and unless the file also sets
`IncludeDefaultRules = $true` PSScriptAnalyzer then refuses the settings ("Cannot find ScriptAnalyzer
rules in the specified path") and PSES analyzes nothing. That one boundary is left to a runtime signal
(leg A3); it is measured and kept visible by a test. Every other way a `CustomRulePath` reaches no rule is
refused as above (since review finding B1b-K01; before it, `CustomRulePath = @('~/*.nomatch')` alone read
valid and a managed scan certified an empty result).

**Where the check is stricter than PSScriptAnalyzer.** A few forms PSScriptAnalyzer accepts are refused
by design -- the safe direction: a managed scan refuses, an unmanaged one warns and uses PSES's default
rules. A root-relative `CustomRulePath` entry (`\rules`, which follows PSES's current drive) or one on
another PowerShell drive (`Temp:\` exists under PowerShell 7 only); and a value built with a
sub-expression (`$('Warning')`) or with `-not`, `!` or `-bnot`. Each is measured and kept visible by a
test.
