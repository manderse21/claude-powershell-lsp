# Corpus licensing and provenance audit (Roadmap II, R2-05)

**Arc B licensing gate: PASS.**

All **137** files in the audited corpus surface are AUTHORED-IN-REPO. **Zero** are
DERIVED-FROM-EXTERNAL. **Zero** are UNKNOWN, so nothing is recorded as
ineligible-pending-clearance. There is no third-party rightsholder to clear anywhere in the
surface, and therefore no blocking ineligibility.

The verdict is rendered against the criterion Arc B states -- provenance eligibility -- and it
follows from the table below, which was built before the verdict was written. Two findings that do
**not** block the gate but do change how a commons publication should be designed are recorded in
"Findings" and are Mike's call at the Wave A gate review, not this audit's.

- **Derived at:** `origin/main` = `7f3427762d8a07ede385d52eaadec2d7d9c54f0c`, 2026-08-12.
- **Audit dispatch:** powershell-lsp/000222 (R2-05), replying to outbox 000221.
- **Scope:** audit only. No corpus file was added, deleted, moved, edited, or relicensed. Nothing
  was published anywhere.

---

## 1. Method, and what each instrument can and cannot establish

Four instruments were run. Each is recorded with its limit, because a search that missed is a
search that missed -- it is not proof of original authorship.

| # | Instrument | What it establishes | What it CANNOT establish |
|---|---|---|---|
| I1 | `git log --follow --diff-filter=A` per file (137 invocations) | The first-add commit, its author, its date, and the dispatch id its subject carries | Whether the content existed elsewhere **before** it was committed. Git records entry into this repo, not origination. |
| I2 | Content marker sweep across all 137 files for `copyright`, `(c) 20`, `licensed under`, `SPDX`, `All rights reserved`, `Author:`, and any `http(s)://` URL | That no file carries an attribution, license, or authorship marker pointing outside this repo | That no file was copied from a source that carries no marker. A marker-free copy is invisible to this instrument. |
| I3 | Upstream comparison against `PowerShell/PSScriptAnalyzer` `Tests/Rules/` (138 entries, live GitHub API read, 2026-08-12) plus a sweep of the locally installed PSScriptAnalyzer 1.25.0 package | That our samples share **zero** distinctive tokens with the upstream rule samples, and that the installed PSSA package is not a possible content source | Whether any other upstream corpus -- PowerShellEditorServices, a blog, a book, a gist -- was a source. Only the two named upstreams were checked. |
| I4 | Commit-trailer scan of the 13 distinct add-commits for `Co-authored-by`, `Claude-Session`, and generation markers | Which commits declare AI co-authorship | Whether a commit **without** a trailer was nonetheless AI-assisted. Absence of a trailer is absence of a declaration, not evidence of its opposite. |

**I3 in detail, because it answers a question the charter asked directly.** Upstream
PSScriptAnalyzer does ship standalone per-rule sample scripts, so the question is real rather than
rhetorical. Three of this plugin's six surfaced rules have an upstream counterpart file
(`AvoidUsingPlainTextForPassword.ps1`, `PossibleIncorrectComparisonWithNull.ps1`,
`UseDeclaredVarsMoreThanAssignments.ps1`). All three were fetched and compared. Seven distinctive
upstream tokens were then searched across the whole 137-file surface:

| Upstream token | Hits in our surface |
|---|---|
| `Declared just for fun` | 0 |
| `randomUninitializedVariable` | 0 |
| `ddfd` | 0 |
| `Verb-Noun` | 0 |
| `Param1 help description` | 0 |
| `CompareWithNull` | 0 |
| `NoViolations` | 0 |

The two corpora are also structurally unlike each other. Upstream files are BOM-prefixed, pack many
violation shapes into one file, and use throwaway identifiers (`dfd`, `eee`, `dd`). Ours are
no-BOM ASCII, carry exactly one shape per file, use real approved-verb function names
(`Get-EmptyFlag`, `Connect-Api`, `New-ServiceAccount`), and **36 of 36** samples under
`tests/corpus/samples/bad/` open with the same house header, `# Triggers RULEID (reason)`. A
uniform header applied without exception across an entire directory is positive evidence of a
single authoring convention rather than of accumulation from mixed sources.

That is a strong negative result, and it is still a negative result. I3 lowers the probability of
undetected upstream copying; it does not reduce it to zero, and this audit does not claim it does.

**A note on length.** Most samples are two to six lines -- `gci -Path $PSScriptRoot` under a
one-line comment is a representative whole file. At that length the expression of "call a cmdlet
alias" is close to the only way to write it, so even an unlikely independent coincidence with
upstream text would carry no practical licensing consequence. This is recorded as context for a
reader weighing residual risk, not as a legal conclusion.

---

## 2. Coverage boundary

The boundary was derived from what the tests and guards actually consume, read out of
`Get-CorpusSampleSpec` and `Get-CorpusPaths` in `tests/corpus/Corpus.Common.ps1` and out of the
fixture paths named by the guard suites. It is stated here so a later reader can attack it rather
than guess at it.

### Included -- 137 files across 7 trees

| Tree | Files | Why it is corpus-class |
|---|---|---|
| `tests/corpus/samples/` | 127 | The scored guard corpus. `Get-CorpusSampleSpec` enumerates `clean` (`*.ps1` + `*.txt`), `bad` (`*.ps1`), `pre-pssa`, `compat`, `bashism` (`*.txt`), and `module` (per-directory `.psd1` + `.psm1`). |
| `tests/corpus/parser-samples/` | 3 | Enumerated by the same spec as category `parser`. Stored as `.txt` so the repo-wide "every shipped `.ps1` parses" guard skips them. |
| `tests/fixtures/lib-purity/` | 2 | AST-parsed by `PowerShellLsp.LibPurity.Tests.ps1`. Self-described "PURPOSE-BUILT IMPURE FIXTURE". Sample PowerShell consumed as analysis input. |
| `tests/fixtures/scalar-count/` | 2 | Scanned by the scalar-`.Count` ratchet in `PowerShellLsp.ScalarCount.Tests.ps1`, which explicitly exempts this path from its own repo sweep so it can analyse it as proof material. |
| `tests/bench/bench-fixture.ps1` | 1 | Fed to the analyzer by `Benchmark.Common.ps1` to time the warm path. Analysis input. |
| `tests/bench/bench-fixture-findings.ps1` | 1 | Same, as the deliberately-dirty counterpart used by `Invoke-ProfileSweep.ps1`. |
| `demo.ps1` | 1 | A three-line deliberately-bad sample (`function Frobnicate-Thing`) at the repo root. |

Two inclusions are judgment calls and are flagged as such:

- **The bench fixtures.** `bench-fixture.ps1` states in its own synopsis that it is "a timing
  fixture, NOT a corpus sample". That self-description is true in the *scoring* sense -- it carries
  no expected-findings snapshot and enters no correctness denominator. It is not true in the
  *licensing* sense, which is what this audit measures: it is purpose-built sample PowerShell that
  would travel with any published corpus. Included on the licensing test, with the scoring
  distinction recorded so the two senses are not conflated.
- **`demo.ps1`.** A repo-wide grep finds **zero** references to it in any test, workflow, or
  document, so it fails the consumption test and passes the content test. Included, because
  excluding a deliberately-bad PowerShell sample from a corpus licensing audit on a technicality is
  precisely the narrow sweep the 000221 near-miss warns against. Its orphan status is itself worth
  reporting.

### Excluded, with reasons

| Tree | Files | Why it is not corpus-class |
|---|---|---|
| `tests/corpus/expected/` | 121 | **Derived output, not input.** Regenerated by `tests/corpus/Update-CorpusSnapshots.ps1` and never hand-authored. Provenance follows the samples it is derived from; it originates no new material. |
| `tests/corpus/Corpus.Common.ps1`, `tests/corpus/Update-CorpusSnapshots.ps1` | 2 | Harness code that enumerates and derives the corpus. Plugin source, not sample material. |
| `tests/*.Tests.ps1`, `tests/*.Common.ps1`, `tests/run-tests.ps1`, `tests/bench/Invoke-*.ps1` | 20 | Test and harness source. Plugin source. |
| `tests/sarif/` (`sarif-2.1.0.json`, `NOTICE.md`) | 2 | Not PowerShell and not analysis input -- it is the schema the plugin's SARIF output is validated *against*. Excluded from the surface, but it is the repository's one committed third-party artifact and is reported in Finding 3. |
| `tests/fixtures/serveshim-run-30472816851-pses-serve-shim.log` | 1 | A captured run log, not sample PowerShell. |
| `rulesets/*.psd1` | 5 | Configuration data consumed as settings, not as analysis input. `base.psd1` and `surface-history.psd1` are additionally generated, never hand-edited. |
| The ad-hoc survey oracle | 0 committed | Discussed in Finding 1. It is machine state and has never been committed, so it contributes no file to any tree. |

`tests/` holds **293** tracked files in total (`git ls-files tests`, 2026-08-12); 137 of the audited
surface's files come from it, plus `demo.ps1` from the repo root.

---

## 3. Origin-class summary

| Origin class | Files | Share |
|---|---|---|
| AUTHORED-IN-REPO | **137** | 100% |
| DERIVED-FROM-EXTERNAL | **0** | 0% |
| UNKNOWN (ineligible-pending-clearance) | **0** | 0% |

**Every UNKNOWN listed by name: there are none.** The list is empty because every one of the 137
files resolved to a first-add commit whose subject carries a dispatch id, not because unknowns were
folded into a neighbouring class. Had any file failed to resolve, it would appear here by name and
be marked ineligible-pending-clearance.

---

## 4. Add-commit provenance

Thirteen distinct commits introduced the 137 files. Every one carries a dispatch id in its subject.
The two author identities are both Mike Andersen: `manderse21 (5mwzj9kkhs@privaterelay.appleid.com)`
is the identity GitHub's squash-merge assigns, and `Mike Andersen (manderse21@gmail.com)` is the
direct-commit identity. Counts sum to 137.

| Add-commit | Dispatch | Date | Files | AI declaration in the commit message |
|---|---|---|---|---|
| `8ba1ea0c4b9785d6ceddbe584c1f1dddb763af82` | 000040 | 2026-06-22 | 11 | **`Co-authored-by: Claude Opus 4.8`** + `Claude-Session` |
| `d3a78443b7ff0c8dadc1cdbdfaa7a28a322bdc2c` | 000046 | 2026-06-23 | 35 | none |
| `3718a5b7f315841bb0c1480d124f675dd1dcdf7b` | 000048 | 2026-06-24 | 29 | none |
| `673a863301b871446cf98af1b83808ced2d0553c` | 000060 | 2026-06-27 | 6 | none |
| `ba73b3a0117e7a7ac1ef8b9cde301d0debd32701` | 000062 | 2026-06-28 | 10 | **`Co-Authored-By: Claude Opus 4.8`** + `Claude-Session` |
| `202506538ea598607058404a199d5e3e9d36e55d` | 000096 | 2026-07-01 | 8 | none |
| `d16735102a28fbb9d126c5c02b5eb7e3dfc715c0` | 000097 | 2026-07-01 | 18 | none |
| `cb89e39e997d89eb211a672a5d6fc64001534ed3` | 000128 | 2026-07-17 | 8 | none |
| `4aaeddc12e98ee2480e55257055e0146ce619153` | 000139 | 2026-07-19 | 5 | none |
| `7c7ecae9482621151c63b578294747c966260fa4` | 000156 | 2026-07-25 | 2 | none |
| `a2c84220fffe350861ef7b307fd1b40bae860ace` | 000157 | 2026-07-25 | 2 | `Claude-Session` link only |
| `e972f33c6fc9c334ea0c031cb7b4cd4065ad2463` | 000171 | 2026-08-01 | 2 | `Claude-Session` link only |
| `4c6535d70a49bd44cc5537edb25a2e70e3710205` | 000207 | 2026-08-08 | 1 | none |

---

## 5. Per-file table

137 rows, one per file, sorted by path. Generated from the `git log --follow` output rather than
transcribed by hand.

**Evidence column legend.** `SHA dNNNNNN DATE` is the first-add commit, the dispatch id its subject
carries, and its author date. **`+AI`** marks a file whose add-commit declares
`Co-authored-by: Claude Opus 4.8` (21 files). *`+S`* marks a file whose add-commit carries a
`Claude-Session` link but no co-authorship trailer (4 files). Both markers describe the **commit**,
which is the granularity the declaration exists at; neither asserts a per-line split.

**License column.** `GPL-3.0-or-later (repo-wide)` for every row. No corpus file carries a per-file
license header -- instrument I2 found zero across all 137 -- so each is covered by the repository
`LICENSE` (GNU GPL v3, 674 lines) and by nothing else.

| Path | Origin class | Evidence | License status | Commons-eligible |
|---|---|---|---|---|
| `demo.ps1` | AUTHORED-IN-REPO | `8ba1ea0` d000040 2026-06-22 **+AI** | GPL-3.0-or-later (repo-wide) | YES |
| `tests/bench/bench-fixture-findings.ps1` | AUTHORED-IN-REPO | `4c6535d` d000207 2026-08-08 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/bench/bench-fixture.ps1` | AUTHORED-IN-REPO | `8ba1ea0` d000040 2026-06-22 **+AI** | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/parser-samples/missing-paren.txt` | AUTHORED-IN-REPO | `8ba1ea0` d000040 2026-06-22 **+AI** | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/parser-samples/unclosed-brace.txt` | AUTHORED-IN-REPO | `8ba1ea0` d000040 2026-06-22 **+AI** | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/parser-samples/unterminated-string.txt` | AUTHORED-IN-REPO | `8ba1ea0` d000040 2026-06-22 **+AI** | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSAvoidDefaultValueSwitchParameter.detailed.ps1` | AUTHORED-IN-REPO | `d3a7844` d000046 2026-06-23 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSAvoidDefaultValueSwitchParameter.enable.ps1` | AUTHORED-IN-REPO | `d3a7844` d000046 2026-06-23 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSAvoidDefaultValueSwitchParameter.flag.ps1` | AUTHORED-IN-REPO | `d3a7844` d000046 2026-06-23 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSAvoidDefaultValueSwitchParameter.force.ps1` | AUTHORED-IN-REPO | `d3a7844` d000046 2026-06-23 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSAvoidDefaultValueSwitchParameter.passthru.ps1` | AUTHORED-IN-REPO | `d3a7844` d000046 2026-06-23 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSAvoidDefaultValueSwitchParameter.recurse.ps1` | AUTHORED-IN-REPO | `d3a7844` d000046 2026-06-23 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSAvoidUsingCmdletAliases.foreach.ps1` | AUTHORED-IN-REPO | `d3a7844` d000046 2026-06-23 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSAvoidUsingCmdletAliases.gci.ps1` | AUTHORED-IN-REPO | `3718a5b` d000048 2026-06-24 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSAvoidUsingCmdletAliases.percent.ps1` | AUTHORED-IN-REPO | `d3a7844` d000046 2026-06-23 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSAvoidUsingCmdletAliases.ps1` | AUTHORED-IN-REPO | `8ba1ea0` d000040 2026-06-22 **+AI** | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSAvoidUsingCmdletAliases.select.ps1` | AUTHORED-IN-REPO | `3718a5b` d000048 2026-06-24 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSAvoidUsingCmdletAliases.where.ps1` | AUTHORED-IN-REPO | `d3a7844` d000046 2026-06-23 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSAvoidUsingPlainTextForPassword.admin.ps1` | AUTHORED-IN-REPO | `d3a7844` d000046 2026-06-23 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSAvoidUsingPlainTextForPassword.apipassword.ps1` | AUTHORED-IN-REPO | `d3a7844` d000046 2026-06-23 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSAvoidUsingPlainTextForPassword.dbpassword.ps1` | AUTHORED-IN-REPO | `d3a7844` d000046 2026-06-23 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSAvoidUsingPlainTextForPassword.passphrase.ps1` | AUTHORED-IN-REPO | `d3a7844` d000046 2026-06-23 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSAvoidUsingPlainTextForPassword.password.ps1` | AUTHORED-IN-REPO | `d3a7844` d000046 2026-06-23 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSAvoidUsingPlainTextForPassword.svcaccount.ps1` | AUTHORED-IN-REPO | `3718a5b` d000048 2026-06-24 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSPossibleIncorrectComparisonWithNull.assign.ps1` | AUTHORED-IN-REPO | `3718a5b` d000048 2026-06-24 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSPossibleIncorrectComparisonWithNull.compound.ps1` | AUTHORED-IN-REPO | `3718a5b` d000048 2026-06-24 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSPossibleIncorrectComparisonWithNull.eq.ps1` | AUTHORED-IN-REPO | `d3a7844` d000046 2026-06-23 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSPossibleIncorrectComparisonWithNull.ne.ps1` | AUTHORED-IN-REPO | `d3a7844` d000046 2026-06-23 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSPossibleIncorrectComparisonWithNull.return.ps1` | AUTHORED-IN-REPO | `d3a7844` d000046 2026-06-23 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSPossibleIncorrectComparisonWithNull.while.ps1` | AUTHORED-IN-REPO | `d3a7844` d000046 2026-06-23 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSUseApprovedVerbs.flarb.ps1` | AUTHORED-IN-REPO | `3718a5b` d000048 2026-06-24 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSUseApprovedVerbs.gronk.ps1` | AUTHORED-IN-REPO | `3718a5b` d000048 2026-06-24 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSUseApprovedVerbs.ps1` | AUTHORED-IN-REPO | `8ba1ea0` d000040 2026-06-22 **+AI** | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSUseApprovedVerbs.snarf.ps1` | AUTHORED-IN-REPO | `d3a7844` d000046 2026-06-23 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSUseApprovedVerbs.wibble.ps1` | AUTHORED-IN-REPO | `d3a7844` d000046 2026-06-23 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSUseApprovedVerbs.zizzle.ps1` | AUTHORED-IN-REPO | `3718a5b` d000048 2026-06-24 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSUseDeclaredVarsMoreThanAssignments.calc.ps1` | AUTHORED-IN-REPO | `d3a7844` d000046 2026-06-23 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSUseDeclaredVarsMoreThanAssignments.config.ps1` | AUTHORED-IN-REPO | `3718a5b` d000048 2026-06-24 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSUseDeclaredVarsMoreThanAssignments.ps1` | AUTHORED-IN-REPO | `8ba1ea0` d000040 2026-06-22 **+AI** | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSUseDeclaredVarsMoreThanAssignments.string.ps1` | AUTHORED-IN-REPO | `d3a7844` d000046 2026-06-23 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSUseDeclaredVarsMoreThanAssignments.timestamp.ps1` | AUTHORED-IN-REPO | `3718a5b` d000048 2026-06-24 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bad/PSUseDeclaredVarsMoreThanAssignments.unused.ps1` | AUTHORED-IN-REPO | `3718a5b` d000048 2026-06-24 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bashism/BashIsm.awk.txt` | AUTHORED-IN-REPO | `d167351` d000097 2026-07-01 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bashism/BashIsm.chmod.txt` | AUTHORED-IN-REPO | `d167351` d000097 2026-07-01 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bashism/BashIsm.chown.txt` | AUTHORED-IN-REPO | `d167351` d000097 2026-07-01 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bashism/BashIsm.export.txt` | AUTHORED-IN-REPO | `d167351` d000097 2026-07-01 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bashism/BashIsm.grep.txt` | AUTHORED-IN-REPO | `d167351` d000097 2026-07-01 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bashism/BashIsm.grepPipe.txt` | AUTHORED-IN-REPO | `d167351` d000097 2026-07-01 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bashism/BashIsm.ln.txt` | AUTHORED-IN-REPO | `d167351` d000097 2026-07-01 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bashism/BashIsm.sed.txt` | AUTHORED-IN-REPO | `d167351` d000097 2026-07-01 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bashism/BashIsm.touch.txt` | AUTHORED-IN-REPO | `d167351` d000097 2026-07-01 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bashism/BashIsm.which.txt` | AUTHORED-IN-REPO | `d167351` d000097 2026-07-01 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/bashism/BashIsm.withPssaIssue.txt` | AUTHORED-IN-REPO | `d167351` d000097 2026-07-01 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/NonAsciiChar.withBom.txt` | AUTHORED-IN-REPO | `673a863` d000060 2026-06-27 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/PS7OnlySyntax.requires7.txt` | AUTHORED-IN-REPO | `2025065` d000096 2026-07-01 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-advanced-function.ps1` | AUTHORED-IN-REPO | `d3a7844` d000046 2026-06-23 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-bashism-call-operator.ps1` | AUTHORED-IN-REPO | `d167351` d000097 2026-07-01 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-bashism-comment.ps1` | AUTHORED-IN-REPO | `d167351` d000097 2026-07-01 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-bashism-function-def.ps1` | AUTHORED-IN-REPO | `d167351` d000097 2026-07-01 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-bashism-get-childitem.ps1` | AUTHORED-IN-REPO | `d167351` d000097 2026-07-01 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-bashism-select-string.ps1` | AUTHORED-IN-REPO | `d167351` d000097 2026-07-01 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-bashism-set-alias.ps1` | AUTHORED-IN-REPO | `d167351` d000097 2026-07-01 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-bashism-string-literal.ps1` | AUTHORED-IN-REPO | `d167351` d000097 2026-07-01 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-begin-process-end.ps1` | AUTHORED-IN-REPO | `3718a5b` d000048 2026-06-24 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-calculated-property.ps1` | AUTHORED-IN-REPO | `3718a5b` d000048 2026-06-24 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-class-inheritance.ps1` | AUTHORED-IN-REPO | `3718a5b` d000048 2026-06-24 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-class-static.ps1` | AUTHORED-IN-REPO | `3718a5b` d000048 2026-06-24 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-class.ps1` | AUTHORED-IN-REPO | `d3a7844` d000046 2026-06-23 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-comment-based-help.ps1` | AUTHORED-IN-REPO | `3718a5b` d000048 2026-06-24 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-compat-safe-null.ps1` | AUTHORED-IN-REPO | `2025065` d000096 2026-07-01 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-compat-safe-pipeline.ps1` | AUTHORED-IN-REPO | `2025065` d000096 2026-07-01 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-compat-safe-ternary.ps1` | AUTHORED-IN-REPO | `2025065` d000096 2026-07-01 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-credential.ps1` | AUTHORED-IN-REPO | `d3a7844` d000046 2026-06-23 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-do-while.ps1` | AUTHORED-IN-REPO | `3718a5b` d000048 2026-06-24 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-dsc-class-resource.ps1` | AUTHORED-IN-REPO | `e972f33` d000171 2026-08-01 *+S* | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-enum-flags.ps1` | AUTHORED-IN-REPO | `3718a5b` d000048 2026-06-24 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-enum.ps1` | AUTHORED-IN-REPO | `d3a7844` d000046 2026-06-23 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-foreach.ps1` | AUTHORED-IN-REPO | `d3a7844` d000046 2026-06-23 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-function.ps1` | AUTHORED-IN-REPO | `8ba1ea0` d000040 2026-06-22 **+AI** | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-hashtable-ordered.ps1` | AUTHORED-IN-REPO | `3718a5b` d000048 2026-06-24 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-hashtable.ps1` | AUTHORED-IN-REPO | `d3a7844` d000046 2026-06-23 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-here-string.ps1` | AUTHORED-IN-REPO | `3718a5b` d000048 2026-06-24 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-module.ps1` | AUTHORED-IN-REPO | `8ba1ea0` d000040 2026-06-22 **+AI** | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-null-check.ps1` | AUTHORED-IN-REPO | `d3a7844` d000046 2026-06-23 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-parameter-set.ps1` | AUTHORED-IN-REPO | `3718a5b` d000048 2026-06-24 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-pipeline-filter.ps1` | AUTHORED-IN-REPO | `3718a5b` d000048 2026-06-24 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-pipeline.ps1` | AUTHORED-IN-REPO | `d3a7844` d000046 2026-06-23 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-placeholder-compare.ps1` | AUTHORED-IN-REPO | `4aaeddc` d000139 2026-07-19 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-placeholder-redirect.ps1` | AUTHORED-IN-REPO | `4aaeddc` d000139 2026-07-19 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-placeholder-strings.ps1` | AUTHORED-IN-REPO | `4aaeddc` d000139 2026-07-19 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-regex-match.ps1` | AUTHORED-IN-REPO | `3718a5b` d000048 2026-06-24 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-script.ps1` | AUTHORED-IN-REPO | `8ba1ea0` d000040 2026-06-22 **+AI** | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-securestring-param.ps1` | AUTHORED-IN-REPO | `3718a5b` d000048 2026-06-24 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-shouldprocess.ps1` | AUTHORED-IN-REPO | `3718a5b` d000048 2026-06-24 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-splat.ps1` | AUTHORED-IN-REPO | `d3a7844` d000046 2026-06-23 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-string-builder.ps1` | AUTHORED-IN-REPO | `3718a5b` d000048 2026-06-24 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-string-format.ps1` | AUTHORED-IN-REPO | `d3a7844` d000046 2026-06-23 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-switch-statement.ps1` | AUTHORED-IN-REPO | `d3a7844` d000046 2026-06-23 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-switch.ps1` | AUTHORED-IN-REPO | `d3a7844` d000046 2026-06-23 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-try-catch-finally.ps1` | AUTHORED-IN-REPO | `3718a5b` d000048 2026-06-24 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-try-catch.ps1` | AUTHORED-IN-REPO | `d3a7844` d000046 2026-06-23 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-validate-range.ps1` | AUTHORED-IN-REPO | `3718a5b` d000048 2026-06-24 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/clean/clean-validate-set.ps1` | AUTHORED-IN-REPO | `3718a5b` d000048 2026-06-24 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/compat/PS7OnlySyntax.nullCoalesce.txt` | AUTHORED-IN-REPO | `2025065` d000096 2026-07-01 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/compat/PS7OnlySyntax.nullConditional.txt` | AUTHORED-IN-REPO | `2025065` d000096 2026-07-01 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/compat/PS7OnlySyntax.pipelineChain.txt` | AUTHORED-IN-REPO | `2025065` d000096 2026-07-01 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/compat/PS7OnlySyntax.ternary.txt` | AUTHORED-IN-REPO | `2025065` d000096 2026-07-01 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/module/alias-consistent/AliasConsistent.psd1` | AUTHORED-IN-REPO | `cb89e39` d000128 2026-07-17 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/module/alias-consistent/AliasConsistent.psm1` | AUTHORED-IN-REPO | `cb89e39` d000128 2026-07-17 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/module/alias-dynamic-good/AliasDynamicGood.psd1` | AUTHORED-IN-REPO | `cb89e39` d000128 2026-07-17 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/module/alias-dynamic-good/AliasDynamicGood.psm1` | AUTHORED-IN-REPO | `cb89e39` d000128 2026-07-17 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/module/alias-exportmember-good/AliasExportGood.psd1` | AUTHORED-IN-REPO | `cb89e39` d000128 2026-07-17 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/module/alias-exportmember-good/AliasExportGood.psm1` | AUTHORED-IN-REPO | `cb89e39` d000128 2026-07-17 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/module/alias-orphan/AliasOrphan.psd1` | AUTHORED-IN-REPO | `cb89e39` d000128 2026-07-17 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/module/alias-orphan/AliasOrphan.psm1` | AUTHORED-IN-REPO | `cb89e39` d000128 2026-07-17 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/module/binary-rootmodule/BinaryRootModule.psd1` | AUTHORED-IN-REPO | `e972f33` d000171 2026-08-01 *+S* | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/module/consistent-module/ConsistentModule.psd1` | AUTHORED-IN-REPO | `ba73b3a` d000062 2026-06-28 **+AI** | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/module/consistent-module/ConsistentModule.psm1` | AUTHORED-IN-REPO | `ba73b3a` d000062 2026-06-28 **+AI** | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/module/dynamic-export/DynamicModule.psd1` | AUTHORED-IN-REPO | `ba73b3a` d000062 2026-06-28 **+AI** | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/module/dynamic-export/DynamicModule.psm1` | AUTHORED-IN-REPO | `ba73b3a` d000062 2026-06-28 **+AI** | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/module/orphan-export/OrphanModule.psd1` | AUTHORED-IN-REPO | `ba73b3a` d000062 2026-06-28 **+AI** | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/module/orphan-export/OrphanModule.psm1` | AUTHORED-IN-REPO | `ba73b3a` d000062 2026-06-28 **+AI** | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/module/typo-export/TypoModule.psd1` | AUTHORED-IN-REPO | `ba73b3a` d000062 2026-06-28 **+AI** | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/module/typo-export/TypoModule.psm1` | AUTHORED-IN-REPO | `ba73b3a` d000062 2026-06-28 **+AI** | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/module/wildcard-export/WildcardModule.psd1` | AUTHORED-IN-REPO | `ba73b3a` d000062 2026-06-28 **+AI** | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/module/wildcard-export/WildcardModule.psm1` | AUTHORED-IN-REPO | `ba73b3a` d000062 2026-06-28 **+AI** | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/pre-pssa/CommandLinePlaceholder.moduleName.txt` | AUTHORED-IN-REPO | `4aaeddc` d000139 2026-07-19 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/pre-pssa/CommandLinePlaceholder.paramValue.txt` | AUTHORED-IN-REPO | `4aaeddc` d000139 2026-07-19 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/pre-pssa/NonAsciiChar.arrow.txt` | AUTHORED-IN-REPO | `673a863` d000060 2026-06-27 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/pre-pssa/NonAsciiChar.emDash.txt` | AUTHORED-IN-REPO | `673a863` d000060 2026-06-27 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/pre-pssa/NonAsciiChar.enDash.txt` | AUTHORED-IN-REPO | `673a863` d000060 2026-06-27 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/pre-pssa/NonAsciiChar.smartDoubleQuote.txt` | AUTHORED-IN-REPO | `673a863` d000060 2026-06-27 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/corpus/samples/pre-pssa/NonAsciiChar.smartSingleQuote.txt` | AUTHORED-IN-REPO | `673a863` d000060 2026-06-27 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/fixtures/lib-purity/impure-param.ps1` | AUTHORED-IN-REPO | `7c7ecae` d000156 2026-07-25 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/fixtures/lib-purity/impure-statements.ps1` | AUTHORED-IN-REPO | `7c7ecae` d000156 2026-07-25 | GPL-3.0-or-later (repo-wide) | YES |
| `tests/fixtures/scalar-count/unwrapped.ps1` | AUTHORED-IN-REPO | `a2c8422` d000157 2026-07-25 *+S* | GPL-3.0-or-later (repo-wide) | YES |
| `tests/fixtures/scalar-count/wrapped.ps1` | AUTHORED-IN-REPO | `a2c8422` d000157 2026-07-25 *+S* | GPL-3.0-or-later (repo-wide) | YES |

---

## 6. Findings

Three findings. The first two change how Arc B should be planned; the third is adjacent to the
surface rather than inside it, and is reported because smoothing it would be the same error the
charter warns about.

### Finding 1 -- the gate's own wording points at a population that is not in the repository

`docs/decision-ledger.md:1366-1367` states the Arc B contingency as a licensing audit passing,
parenthesised: *"the oracle mixes repo scripts with installed-module scripts, so provenance is the
gate, not an afterthought."*

That parenthetical is about a **different population** from `tests/corpus/`. The "oracle" it names
is the ad-hoc false-positive survey set used in measure-first slices -- 281 files for dispatch
000139 (150 repo scripts plus 131 installed-module scripts), later 325 files for the 000157 re-run
(153 repo scripts plus 172 installed-module scripts across 6 `PSModulePath` roots). The ledger
itself settles what that set is at line 875-876: **"the installed-module set is machine state"**.
It is read in place from `$env:PSModulePath` at survey time and has never been committed. This
audit confirms that independently: instrument I2 found no third-party attribution marker anywhere
in the surface, and every one of the 137 files resolves to a dispatch add-commit.

`ROADMAP.md:101-103` states the same gate without the parenthetical, as "a licensing / provenance
audit of the corpus samples passing".

So the two statements of one gate name two different scopes, and only the ROADMAP wording matches
the population that could actually be published. **The committed corpus never contained the
third-party material the ledger's parenthetical worries about.** The concern was real for the
survey practice and is inapplicable to the artifact.

This is the finding most likely to change a downstream plan, in the helpful direction: the
licensing risk Arc B has carried since it was deferred does not attach to the thing Arc B proposed
to publish. It is recorded here; **acting on it -- reconciling the two gate statements -- is not in
this dispatch's scope**, which is audit-only and forbids editing `ROADMAP.md`.

### Finding 2 -- 21 of 137 files were added by commits declaring AI co-authorship

Instrument I4 found `Co-authored-by: Claude Opus 4.8 (noreply@anthropic.com)` on two of the
thirteen add-commits, covering **21 files** (15.3% of the surface): all 11 from dispatch 000040
(`8ba1ea0`) and all 10 from dispatch 000062 (`ba73b3a`). Four further files carry a
`Claude-Session` link with no co-authorship trailer (dispatches 000157 and 000171).

This is **not** a DERIVED-FROM-EXTERNAL condition. Nothing was copied from an outside source and
there is no external rightsholder. It is a disclosure fact, and it matters to a commons for two
reasons:

1. **Copyright in AI-generated material is unsettled**, and in the United States the Copyright
   Office's position is that purely machine-generated expression is not protectable while
   human-authored contributions are. The practical consequence for redistribution is benign in both
   directions -- protectable material is Mike's to license, and unprotectable material is free to
   copy -- so this is not an obstruction. A published benchmark should nevertheless say so rather
   than let a downstream user assume uniform human authorship.
2. **The declaration is commit-level, not line-level.** Two commits declare co-authorship; the
   trailer does not apportion which lines came from where, and this audit does not invent an
   apportionment it cannot derive. Equally, a commit *without* a trailer is not thereby established
   as un-assisted -- that is I4's stated limit, and it is why the marker in the table is described
   as a property of the commit.

One file carries a finer-grained record already, and it is worth surfacing because it shows the
practice was being documented at the time: `tests/bench/bench-fixture.ps1` states in its synopsis
that "the DeepSeek generation of a ~50-line cohesive script failed (its reasoning consumed the
entire token budget and emitted no content), so this fixture is the recorded native fallback". A
third-party model was attempted for that one file, produced nothing, and the file was authored
without it. No corpus file is recorded anywhere as the output of a non-Anthropic model.

### Finding 3 -- adjacent, outside the surface: the one committed third-party artifact is not in the central license register

`tests/sarif/sarif-2.1.0.json` is vendored third-party content -- the OASIS SARIF 2.1.0 JSON
Schema, retrieved 2026-06-28 from SchemaStore and committed unmodified. It is **excluded from this
audit's surface** (not PowerShell, not analysis input) and it does not affect the gate verdict.

It is reported because of a documentation mismatch a commons publication would run into.
Attribution for it **is** preserved, thoroughly, in a co-located `tests/sarif/NOTICE.md` that names
the OASIS source, the retrieval date and route, and the upstream IPR terms (RF on RAND Terms Mode),
and states the schema is not relicensed under the project's GPL-3.0-or-later. But
`THIRD-PARTY-LICENSES.md`, the central register, does not mention SARIF, OASIS, or SchemaStore --
zero hits -- and frames the project as "a **downloader**, not a redistributor", declaring exactly
two external components (PSES and PSScriptAnalyzer) that it "downloads at install time" and does
"not bundle or redistribute ... in this repository".

The vendored schema is a genuine exception to that framing. Attribution is not missing; it is
recorded in a place the central register does not point to. Recorded only -- **no file was edited**.

---

## 7. The gate verdict, derived

The verdict is read off Section 3 and Section 5, in the order the criterion defines.

1. **Is any file DERIVED-FROM-EXTERNAL?** No -- 0 of 137. So no source license needs to be recorded,
   and no compatibility question with public redistribution arises from third-party terms.
2. **Is any file UNKNOWN?** No -- 0 of 137. So there is nothing to mark
   ineligible-pending-clearance. Every file resolved to a dispatch add-commit under instrument I1.
3. **Is any file otherwise ineligible?** No. Every file is covered by the repository's own
   `LICENSE` and by a single human rightsholder, with no per-file header claiming otherwise.

Every file is eligible. By the criterion's own definition -- PASS is "every file eligible" -- the
outcome is:

> ### Arc B licensing gate: **PASS**

**What PASS does and does not mean here.** It means provenance is clear and there is no
clearance work outstanding: no permission to seek, no attribution owed to a third party, no file
held back. It does **not** mean "publish as-is". Two design decisions remain, and both are Mike's:

- **Which license the commons ships under.** The corpus is currently GPL-3.0-or-later, inherited
  repo-wide. That is a copyleft license, whereas benchmark corpora are conventionally permissive
  (MIT, Apache-2.0, CC0) so that consumers can vendor cases into their own differently-licensed
  test suites. Because every file is authored in-repo with a single human rightsholder, Mike can
  relicense the corpus for publication without clearing anything with anyone -- the strongest
  possible position, and the reason this is a decision rather than an obstruction.
- **Whether and how to disclose the AI co-authorship of the 21 files** in Finding 2.

Neither is an eligibility defect, so neither reduces the verdict to PARTIAL. PARTIAL was considered
and rejected: it is defined as "an eligible subset exists", which presupposes an ineligible
remainder, and there is none. Recording a hedge the evidence does not support would be an error in
the same family as smoothing an inconvenient one.

---

## 8. What this audit does not establish

Stated plainly so the coverage can be attacked rather than assumed:

- It does not establish that no file was ever copied from a source outside the two upstreams
  checked in I3. It establishes that no such copy left a marker (I2), matched the PSScriptAnalyzer
  rule samples (I3), or broke the uniform house conventions the surface otherwise shows.
- It does not apportion authorship within a commit between Mike Andersen and a declared AI
  co-author. The trailer is commit-level and the audit reports it at that granularity.
- It does not establish that trailer-free commits were un-assisted.
- It is a mechanical provenance audit, not legal advice -- the same caveat
  `THIRD-PARTY-LICENSES.md` already carries for its own attribution. A public corpus release with
  real downstream consumers warrants a human legal read of the license choice.
- It does not act on any finding. Whether Arc B proceeds, reshapes, or stops on these findings is
  Mike's call at the Wave A gate review.
