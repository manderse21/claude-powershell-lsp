# The powershell-lsp diagnostic-correctness corpus -- publication package

> ## PREPARED, NOT PUBLISHED
>
> **Nothing in this directory has been published anywhere, and publishing it is not an agent
> decision.** This is the assembled package for an Arc B "corpus commons" release: what would ship,
> how a consumer would run it, and the provenance statement it would carry. It exists so the
> publication decision can be made against a finished artifact instead of a proposal.
>
> Assembled by dispatch **000269** on **2026-08-21** under Mike's G1 ruling (the corpus goes
> Apache-2.0) and R2 grant (relicense execution, **publication still held**). The act of publishing
> -- pushing to a registry, opening a repository, posting an announcement -- remains Mike's gate.

---

## What this is

A **scored correctness corpus** for PowerShell static analysis. Each sample is a small PowerShell
file paired with a snapshot of the diagnostics a correct analyzer should produce for it. Together
they answer a question that is otherwise argued rather than measured: *does this analyzer report the
right findings, and does it stay quiet on clean code?*

It is used inside powershell-lsp as a merge gate. Published, it would be usable by any PowerShell
analysis tool as an external, independently-authored yardstick.

**Two denominators, deliberately separated:**

- **`clean` samples** measure the **false-positive rate.** A correct analyzer reports nothing on
  them. powershell-lsp measures **0 findings across 50 clean samples** at v1.32.0.
- **`bad` samples** measure the **true-positive rate.** Each is built to trigger exactly one named
  rule. powershell-lsp measures **36 of 36** at v1.32.0.

A corpus with only `bad` samples rewards an analyzer that reports everything. Carrying both, and
reporting both, is the point.

## What ships

Derived from the tree on 2026-08-21, not estimated.

| Path | Files | Bytes | What it is |
|---|---:|---:|---|
| `samples/` | 127 | 22,242 | The scored samples: the input side |
| `parser-samples/` | 3 | 124 | Parse-error samples, stored as `.txt` so a repo-wide "every shipped `.ps1` parses" guard skips them |
| `expected/` | 121 | 21,186 | The expected-findings snapshots: the oracle side. **Derived output** -- regenerated from the samples, never hand-authored |
| `Corpus.Common.ps1` | 1 | -- | The enumerator: turns the trees above into a scored spec |
| `Update-CorpusSnapshots.ps1` | 1 | -- | Regenerates `expected/` from `samples/` |
| `LICENSE`, `NOTICE`, `PROVENANCE.md`, `README.md` | 4 | -- | This package's own paperwork |

**121 scored entries** across seven categories, derived by running the enumerator rather than
counting by hand:

| Category | Entries | What it exercises |
|---|---:|---|
| `clean` | 50 | Must produce **no** findings -- the false-positive denominator |
| `bad` | 36 | Must produce **one named** finding -- the true-positive denominator |
| `bashism` | 11 | Shell habits that are not PowerShell |
| `module` | 10 | Per-directory `.psd1` + `.psm1` pairs -- module-shaped input, not loose scripts |
| `pre-pssa` | 7 | Cases the parser pre-pass must catch before PSScriptAnalyzer runs at all |
| `compat` | 4 | Cross-version compatibility surface |
| `parser` | 3 | Files that must fail to parse |

**Not included, and why.** The plugin's Pester suite, its harness, its benchmark fixtures, and
`demo.ps1` stay in the plugin repository. They were inside the *licensing audit's* surface -- that
audit deliberately swept wider than the publishable artifact -- but they are analyzer-specific test
scaffolding, not corpus material a second tool could consume.

## What the expected-findings snapshots commit you to

**The snapshots encode powershell-lsp's default rule surface, not a universal truth**, and a
consumer needs to know that before scoring another tool against them.

The six rules the shipped default surface reports:

`PSAvoidDefaultValueSwitchParameter`, `PSAvoidUsingCmdletAliases`,
`PSAvoidUsingPlainTextForPassword`, `PSPossibleIncorrectComparisonWithNull`, `PSUseApprovedVerbs`,
`PSUseDeclaredVarsMoreThanAssignments`.

An analyzer with a **wider** default surface will report findings on `clean` samples that are
correct for it and count as false positives here. That is a real limitation of scoring across tools,
and it is stated rather than hidden: the honest use of this corpus against a different analyzer is to
**regenerate the expected snapshots under that analyzer's own default surface** and then check
whether the `clean` set stays empty and the `bad` set stays fully detected. The samples are the
durable contribution; the snapshots are powershell-lsp's answer key to them.

## How a consumer runs it

Requires PowerShell 5.1 or later. The enumerator is pure -- it reads the trees and returns a spec;
it runs no analyzer itself, so a consumer plugs in their own.

```powershell
# 1. Enumerate the corpus. Returns one entry per scored sample. Each entry is a
#    hashtable; the keys a consumer needs are Category, SourcePath, ExpectedPath,
#    RuleId (the single rule a `bad` sample must trigger) and Label.
. ./Corpus.Common.ps1
$spec = Get-CorpusSampleSpec -CorpusRoot (Resolve-Path .).Path
@($spec).Count                                 # 121

# 2. Score your own analyzer against it. For the `module` category SourcePath is the
#    manifest inside ModuleDir, so hand your analyzer the directory if it wants one.
foreach ($entry in $spec) {
    $actual   = Invoke-YourAnalyzer -Path $entry.SourcePath
    $expected = Get-Content -Raw -LiteralPath $entry.ExpectedPath | ConvertFrom-Json
    # compare, and attribute every difference to $entry.Category
}

# 3. The two headline numbers, kept separate.
#    clean : how many of the 50 produced ZERO findings        -> false-positive rate
#    bad   : how many of the 36 produced their $entry.RuleId  -> true-positive rate
$clean = @($spec | Where-Object { $_.Category -eq 'clean' })   # 50
$bad   = @($spec | Where-Object { $_.Category -eq 'bad' })     # 36
```

To regenerate the answer key under a different analyzer's default surface, adapt
`Update-CorpusSnapshots.ps1` -- it is the same derivation powershell-lsp uses, so the snapshots stay
generated rather than hand-maintained in either tool.

## Provenance, in one paragraph

Every sample here was authored in the powershell-lsp repository. A per-file audit
(`PROVENANCE.md`) walked the whole corpus surface with four independent instruments and found
**zero** files derived from an external source and **zero** of unknown origin -- including a direct
comparison against upstream PSScriptAnalyzer's own rule samples, which share no distinctive token
with these. There is no third-party rightsholder to clear. The audit also records, in its own words,
what each instrument **cannot** establish; read that section before treating the result as stronger
than it is.

## License

**Apache-2.0** -- see `LICENSE` and `NOTICE`.

The powershell-lsp repository relicensed to Apache-2.0 **forward-only**, effective from v1.32.0.
These corpus files carry no per-file license header of their own -- verified, not assumed: a scan
for `SPDX`, `Copyright (c)`, `GPL-3` and `Apache-2.0` across the corpus trees returns zero hits --
so they take the repository's license, which is Apache-2.0 at and after v1.32.0. A consumer taking
this package from a v1.32.0-or-later tree receives it under Apache-2.0.

**Note on the historical band.** The same files sitting in a **v1.6.1 through v1.31.2** checkout are
under `GPL-3.0-or-later`, because the relicense is forward-only and does not reach back into
published releases. This package is defined as the v1.32.0-or-later state of those trees.
