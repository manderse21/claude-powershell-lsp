# The diagnostic-correctness corpus, as a commons

The curated PowerShell corpus this plugin scores itself against, published for outside use.
Summarized in [README, Diagnostic-correctness corpus](../README.md#diagnostic-correctness-corpus);
this page is the full text -- what the corpus is, where every file came from, how the expected
findings are derived, how the false-positive and true-positive numbers are measured, and how to
reproduce those numbers yourself from a clean clone.

**This page does not announce anything.** It makes the corpus consumable where it already lives.
Whether this benchmark is ever submitted anywhere is a maintainer decision, and no such submission
is claimed here.

## License: one license, repository-wide

The corpus fixtures and every corpus-surface file publish under the **project license,
[Apache-2.0](https://spdx.org/licenses/Apache-2.0.html)** -- the same license as the rest of the
repository. See [LICENSE](../LICENSE) and [NOTICE](../NOTICE).

**There is no second licensing regime to explain.** The corpus is not dual-licensed, not carved
out under CC0 or MIT, and carries no per-file license header. Across all 190 tracked `.ps1`,
`.psm1`, and `.psd1` files in this repository, **zero** declare an SPDX license identifier of
their own, so each corpus file is covered by the repository `LICENSE` and by nothing else:

```powershell
# Expect 0. (Scoped to source files on purpose -- prose pages, including this one,
# mention the identifier while discussing its absence, and would inflate a naive count.)
git grep -l SPDX-License-Identifier -- '*.ps1' '*.psm1' '*.psd1' | Measure-Object -Line
```

You vendor a fixture the same way you vendor any other file from this project, under one set of
terms.

Apache-2.0 is a permissive license with an explicit patent grant, which is the property that
matters for a benchmark corpus: you can copy cases into a differently-licensed test suite of your
own without that suite inheriting a copyleft obligation.

The relicense is **forward-only**, and the corpus inherits that. Every previously published
release keeps the license it shipped under, and those grants are irrevocable -- see
[README, License](../README.md#license) and the [decision ledger](decision-ledger.md) entries for
dispatches 000247 and 000251.

## What the corpus is

Seven trees of purpose-built sample PowerShell, plus the derived snapshots of what the real tool
emits for each one. Samples are the **input**; snapshots under `tests/corpus/expected/` are
**derived output** and originate no new material.

| Tree | What it holds | Scored? |
|---|---|---|
| `samples/clean/` | Known-good code that must surface nothing | FP denominator |
| `samples/bad/` | Known-bad code, asserting an exact rule id, line, severity | TP denominator |
| `samples/bashism/` | Shell idioms that do not belong in PowerShell | separate |
| `samples/compat/` | PowerShell-7-only syntax, for the cross-host pre-pass | separate |
| `samples/pre-pssa/` | Cases the in-process pre-pass catches first | separate |
| `samples/module/` | `.psd1` + `.psm1` pairs for module-aware checks | separate |
| `parser-samples/` | Deliberately unparseable code, stored as `.txt` | separate |

Paths are relative to `tests/corpus/`. **Scored** marks the two sets the headline rates are taken
over; the rest are separately asserted and enter neither denominator. `samples/bad/` carries
several cases per surfaced rule. `parser-samples/` is stored as `.txt` so the repo-wide "every
shipped `.ps1` parses" guard skips it.

Four more groups of sample PowerShell live outside `tests/corpus/`. None of them is scored, and
they travel with the corpus for licensing purposes rather than for measurement:
`tests/fixtures/lib-purity/`, `tests/fixtures/scalar-count/`, the two
`tests/bench/bench-fixture*.ps1` timing fixtures, and `demo.ps1` at the repository root.

**The scored denominators are not restated on this page.** They are published once, in the README
section this page expands, where the [doc-claims registry](../tests/doc-claims.psd1) derives them
from disk on every CI run and fails the build if the prose and the corpus disagree. Copying those
integers here would create a second, unguarded copy -- which is precisely the defect that registry
exists to prevent. Read them from the README, or derive them live with the command in
[Reproducing the measurement](#reproducing-the-measurement) below.

## Provenance: where every file came from

The corpus surface was audited file by file before any of this was published. The full instrument
list, per-file table, coverage boundary, and stated limits are in
[`roadmap-ii/CORPUS-PROVENANCE-AUDIT.md`](roadmap-ii/CORPUS-PROVENANCE-AUDIT.md). The result, in
short:

- **137 files across 7 trees**, every one **authored in this repository**.
- **Zero** derived from an external source. **Zero** unresolved. No third-party rightsholder
  appears anywhere in the surface, so there is nothing to clear and no attribution owed out.
- Every file resolves to a first-add commit whose subject carries a dispatch id.

That surface count is a **provenance fact tied to a commit**, not a guarded claim -- the doc-claims
registry covers the scored denominators, not this number. It is stated with its derivation so you
can re-run it rather than trust it:

```powershell
# The audited surface, enumerated the way the audit's coverage boundary defines it.
git ls-files -- tests/corpus/samples tests/corpus/parser-samples `
                tests/fixtures/lib-purity tests/fixtures/scalar-count `
                tests/bench/bench-fixture.ps1 tests/bench/bench-fixture-findings.ps1 demo.ps1 |
    Measure-Object | Select-Object -ExpandProperty Count
```

Derived at `origin/main` = `7f34277` (2026-08-12) by the audit; re-verified file-for-file against
the audit's per-file table on 2026-08-17, with zero drift -- no surface file added, removed,
renamed, or edited in between.

### AI co-authorship, disclosed

**21 of the 137 files were added by commits that declare `Co-authored-by: Claude Opus 4.8`**, and
four more carry a session link with no co-authorship trailer. This is a disclosure, not a defect:
nothing was copied from an outside source and there is no external rightsholder.

It is stated here because a downstream consumer should not have to assume uniform human authorship.
Two honest qualifications travel with it:

- **The declaration is commit-level, not line-level.** The trailer does not apportion which lines
  came from where, and no apportionment is invented.
- **A commit without a trailer is not thereby established as unassisted.** Absence of a declaration
  is absence of a declaration.

Copyright in purely machine-generated expression is unsettled, and in the United States the
Copyright Office's position is that it is not protectable while human-authored contribution is. The
practical consequence for redistribution is benign in both directions -- protectable material is
the maintainer's to license under Apache-2.0, and unprotectable material is free to copy -- so this
constrains nothing about your use. It is recorded so you can weigh it yourself.

## How the expected findings are derived

**The one hard invariant: a corpus expected-finding is NEVER hand-authored or model-authored.**

Every expected finding is *derived* by running the **real tool** over the sample and snapshotting
exactly what it emits. The derivation channel is the tool's own dogfood capture log: the generator
redirects the capture log to a throwaway file, runs the real `scripts/lsp-client.ps1` hook against
the sample through the warm PSES daemon, and reads back the structured records it tees -- rule id,
source, severity, line, column, message. The committed snapshot is whatever that run produced.

`tests/corpus/Corpus.Common.ps1` is dot-sourced by **both** the generator
(`tests/corpus/Update-CorpusSnapshots.ps1`) and the test
(`tests/PowerShellLsp.Corpus.Tests.ps1`), so the two derive a sample's findings the same way. That
shared path is what makes the corpus a regression guard rather than two drifting code paths.

**A hand-edited snapshot cannot make the test pass.** It would simply disagree with the live tool
on the next run. This is the property that makes an outside reader's trust in the numbers
recoverable from the repository instead of from the maintainer's word.

## How the guarantees are measured

`Get-CorpusCorrectnessReport` in `tests/corpus/Corpus.Common.ps1` computes two numbers from the
same live findings the snapshot tests assert:

- **False-positive rate** -- the percentage of known-good (`clean`) samples that wrongly produced
  *any* finding. A clean sample counts against the tool if it surfaces anything at all.
- **True-positive rate** -- the percentage of known-bad samples whose *expected rule* actually
  surfaced. A known-bad case counts only when the specific rule the spec names appears, not when
  some other rule happens to fire.

Both are measured under the tool's **default configuration**, on all four CI legs (Windows `pwsh`
7, Windows PowerShell 5.1, Ubuntu `pwsh`, macOS `pwsh`).

Four assertions in `tests/PowerShellLsp.Corpus.Tests.ps1` turn the report into a build gate: the
false-positive rate must be zero, true-positive coverage must be total, every expected rule must be
proven by at least one known-bad case, and **each scored set is floored at a minimum fixture
count** so a rate can never be made defensible by shrinking the oracle.

That floor is a floor, **not a ratchet.** It does not pin the corpus at its present size, so a
deliberate withdrawal of a fixture stays green while the set stays above the floor.

## Reproducing the measurement

From a clean clone, on Windows, Linux, or macOS. The first run bootstraps PowerShell Editor
Services and the pinned PSScriptAnalyzer exactly as a real session does; that bootstrap is not part
of the measurement and can take several minutes.

```powershell
git clone https://github.com/manderse21/claude-powershell-lsp.git
cd claude-powershell-lsp

# Put the report somewhere you can find it, then run the corpus suite.
$env:PSLS_TEST_DATA_DIR = Join-Path $PWD '.corpus-run'
pwsh -NoProfile -File tests/run-tests.ps1 -FullNameFilter '*Diagnostic-correctness corpus*'
```

The runner installs Pester 5 to the **CurrentUser** scope if it is missing -- never machine-global
-- and exits with the number of failed tests.

**Check the selected count, not just the exit code.** The runner exits on the *failure* count, so a
`-FullNameFilter` that matches nothing exits `0` and reads like a pass. Pester prints
`Filters selected N tests to run` near the top of the output: confirm `N` is non-zero before you
believe the result. Dropping the filter entirely runs the whole suite, which takes considerably
longer but cannot be vacuous.

The measured report is written as JSON:

```powershell
Get-Content (Join-Path $env:PSLS_TEST_DATA_DIR 'logs/corpus-correctness-report.json')
```

The report's schema, with the values deliberately left for your run to fill in -- the denominators
are published once, in the guarded README section, and are not copied here:

```json
{
  "knownGood": "<count of scored clean samples>",
  "knownBad": "<count of scored known-bad samples>",
  "falsePositives": "<clean samples that wrongly surfaced anything>",
  "falsePositiveRate": "<percent, 0..100>",
  "truePositives": "<known-bad samples whose expected rule surfaced>",
  "truePositiveRate": "<percent, 0..100>",
  "rulesExpected": ["<every distinct expected rule in the corpus>"],
  "rulesCovered": ["<those a known-bad case actually proved>"]
}
```

Treat your own run's output as the measurement -- that is the entire point of publishing the method
rather than only the result. The suite passing is itself the assertion that the rate is zero and
coverage is total; the JSON tells you the denominators those rates were taken over.

**If the numbers differ on your machine, that is a finding worth reporting**, not a
misconfiguration to hide: the
[false-positive report form](../.github/ISSUE_TEMPLATE/false_positive_report.yml) feeds a case
straight into this corpus.

### Scanning your own code with the same engine

The corpus is scored through the same analyzer path that runs in-agent. To point that engine at
your own tree instead:

```powershell
pwsh -File scripts/lsp-scan.ps1 ./src -Format text -FailOn warning
```

Full details -- SARIF output, exit codes, the self-scan workflow -- are in
[repository-scanning.md](repository-scanning.md).

## How to cite it

There is no DOI and no published paper. Cite the repository, the corpus path, and the commit you
measured at, so a reader can reproduce exactly what you saw:

```
powershell-lsp diagnostic-correctness corpus, tests/corpus/,
https://github.com/manderse21/claude-powershell-lsp, commit <sha>, Apache-2.0.
```

Pin the commit rather than a branch. The corpus grows deliberately, and a rate quoted against
"main" is a rate against a moving denominator.

## What this corpus does NOT attest

Stated plainly, so the coverage can be attacked rather than assumed. The corpus is a **measured and
defensible** claim about diagnostic correctness, not an exhaustive one.

- **It is not a general PowerShell benchmark.** It scores *this plugin's* default rule surface. The
  effective default ruleset via PSES is deliberately narrower than raw PSScriptAnalyzer, so a
  finding absent here may simply be a rule the default configuration does not surface.
- **A 0% false-positive rate is a rate over this corpus**, not a guarantee that no clean PowerShell
  anywhere produces a false positive. It is a floor on a curated, idiom-diverse sample, and it is
  only as strong as that sample is representative.
- **Not all fixtures are scored.** The `bashism`, `compat`, `pre-pssa`, and `module` fixtures are
  separately asserted and enter neither headline denominator.
- **The provenance audit is a mechanical audit, not legal advice.** It establishes that no file
  carries an external attribution marker and that none matches the two upstream corpora it checked;
  it cannot establish that nothing was ever copied from a source it did not check. A public release
  with real downstream consumers warrants your own legal read.
- **The plugin is not independently security-audited**, and publishing this corpus does not change
  that. See [TRUST.md, Honest limits](../TRUST.md#honest-limits).
