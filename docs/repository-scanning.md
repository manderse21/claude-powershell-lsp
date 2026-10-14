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

**`-PolicyMode closed` is the managed mode.** Precedence: an explicit `-PolicyMode`, then
`POWERSHELL_LSP_POLICY_MODE`, then `open`. A managed scan is **CERTIFIED** only when every one of these
holds; each failure is named by its code on stderr, in the text report, and as a SARIF
`toolExecutionNotifications` entry with `properties.reason`, and the scan exits `4` with
`executionSuccessful=false`:

| Code | The scan refuses because |
|---|---|
| `policy-not-declared` | no `-OrgPolicyPath` -- a managed scan needs a declared policy (an interactive edit with no policy is still a no-trigger) |
| `policy-file-missing`, `policy-path-relative`, `policy-unreadable`, `policy-integrity-*` | the declared policy cannot be used (the same degrades the edit hook fails closed on) |
| `config-ambient` | a `CLAUDE_PLUGIN_OPTION_*` that changes analysis (rule lists, threshold, cap, settings, ruleset, profile, host, ...) reached the scan from its environment |
| `analysis-incomplete` | a file has no COMPLETE receipt |
| `analysis-empty` | the target holds no PowerShell file, so nothing shows the policy was applied (an unmanaged scan of such a target still exits `0`) |
| `policy-evidence-missing` | a file's receipt carries no application record from the hook or the daemon |
| `policy-disagreement` | the hook or the daemon applied a policy whose identity differs from the declared one |
| `policy-activation-unsupported` | `RequiredRules` could not be activated: the running PSES version is not one the pinned default list was verified for |
| `policy-merge-write-failed` | the merged settings file could not be written and read back intact |
| `policy-activation-not-delivered` | the merged settings were not pushed to PSES, or the settings file changed after they were |
| `policy-suppression-pass-failed` | the `ProhibitedSuppressions` re-surfacing pass could not run |
| `config-observed-mismatch` | the daemon reports an analysis configuration other than the scan's declared one |
| `engine-unknown` | the engine versions could not be observed |

**Not required is not failed.** A policy with no `RequiredRules` needs no merged settings, one with no
prohibitions needs no suppression pass; the daemon reports `not-required` and the scan certifies.

**Unmanaged stays unmanaged.** Without `-PolicyMode closed` nothing is certified or refused: an unusable
`-OrgPolicyPath` is a warning on stderr and the findings are reported without it (fail-open, as
before), and a failed merged-settings write simply leaves the required rule inactive. The local
severity-threshold boundary ([configuration](configuration.md#severityoverrides----how-an-organization-states-a-requirement))
applies to developer assistance only; a managed scan declares `Hint` and refuses anything else.

**What certification does and does not prove.** It proves that, at each file's analysis, the hook and
the daemon both applied the policy whose identity the scan resolved, that a required rule's merged
settings were written, verified and handed to PSES, and that the settings file PSES reads still hashed
to what was written. It does NOT prove that PSScriptAnalyzer accepted that settings file: a settings
file with a key PSScriptAnalyzer rejects (its valid keys are `CustomRulePath`, `ExcludeRules`,
`IncludeRules`, `IncludeDefaultRules`, `RecurseCustomRulePath`, `Rules`, `Severity`) makes PSES analyze
nothing while still publishing a settled, empty result -- measured, pre-existing, and true of an
unmanaged scan over such a repository too. It does not make the plugin tamper-proof: a process running as the same user can
edit the policy, its sidecar, the plugin and its evidence. Run release gates on a protected runner
whose policy someone other than the change's author controls. Until the declared child configuration
lands (leg A3), a managed scan run with ambient plugin options set is refused rather than certified
around them.

**A scan never formats.** Every scan child gets `formatOnEdit=off` under exactly one spelling --
every other spelling the option resolver accepts is removed from its environment first -- so a
`formatOnEdit=apply` inherited from the caller cannot rewrite the files being scanned.

**This repository scans itself.** `.github/workflows/powershell-lsp-code-scanning.yml` uploads
SARIF to GitHub code scanning on every push to `main`, weekly, and on demand -- a separate
workflow from the CI legs, so it can never turn a merge gate red. Copy it as a starting point;
two details are deliberate: it scans `scripts/` rather than the repo root (because
`tests/corpus/samples/` is deliberately-bad code), and it pins `upload-sarif` by **commit SHA**,
not by tag.
