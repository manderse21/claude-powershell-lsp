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
threshold met, `3` usage error, `4` scan incomplete (an unanalyzed file is never reported clean).

**This repository scans itself.** `.github/workflows/powershell-lsp-code-scanning.yml` uploads
SARIF to GitHub code scanning on every push to `main`, weekly, and on demand -- a separate
workflow from the CI legs, so it can never turn a merge gate red. Copy it as a starting point;
two details are deliberate: it scans `scripts/` rather than the repo root (because
`tests/corpus/samples/` is deliberately-bad code), and it pins `upload-sarif` by **commit SHA**,
not by tag.
