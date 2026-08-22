# Provenance statement -- the powershell-lsp diagnostic-correctness corpus

> **PREPARED, NOT PUBLISHED.** This statement is written to travel with a published corpus package.
> Nothing has been published. See `README.md` in this directory.

## The claim

**Every sample in this corpus was authored in the powershell-lsp repository. No file is derived from
an external source, and no file is of unknown origin. There is no third-party rightsholder to clear
anywhere in the sample surface.**

That is a strong claim, so what follows is the evidence for it and -- just as important -- the
boundary of what that evidence can support.

## The audit

The claim rests on a per-file provenance audit performed on **2026-08-12** against the repository at
`origin/main` = `7f3427762d8a07ede385d52eaadec2d7d9c54f0c`, recorded in full at
[`docs/roadmap-ii/CORPUS-PROVENANCE-AUDIT.md`](../roadmap-ii/CORPUS-PROVENANCE-AUDIT.md) in the
powershell-lsp repository (dispatch 000222, Roadmap II item R2-05).

The audit walked **137 files across 7 trees** -- a deliberately *wider* surface than this package
ships, so that nothing publishable could fall outside it. Its verdict:

| Origin class | Files |
|---|---:|
| Authored in repo | **137** |
| Derived from external | **0** |
| Unknown | **0** |

## The four instruments, and what each cannot establish

The audit's own framing, preserved because a search that missed is a search that missed -- it is not
proof of original authorship.

| # | Instrument | Establishes | Cannot establish |
|---|---|---|---|
| **I1** | `git log --follow --diff-filter=A` per file (137 invocations) | The first-add commit, author, date, and the dispatch id its subject carries | Whether the content existed elsewhere **before** it was committed. Git records entry into this repo, not origination. |
| **I2** | Content marker sweep for `copyright`, `(c) 20`, `licensed under`, `SPDX`, `All rights reserved`, `Author:`, and any URL | That no file carries an attribution, license, or authorship marker pointing outside this repo | That no file was copied from a source carrying no marker. A marker-free copy is invisible to this instrument. |
| **I3** | Comparison against `PowerShell/PSScriptAnalyzer` `Tests/Rules/` (138 entries, live API read) plus the locally installed PSScriptAnalyzer 1.25.0 package | That these samples share **zero** distinctive tokens with the upstream rule samples, and that the installed package is not a content source | Whether some *other* upstream -- a blog, a book, a gist, PowerShellEditorServices -- was a source. Only the two named upstreams were checked. |
| **I4** | Commit-trailer scan of the 13 distinct add-commits | Which commits declare AI co-authorship | Whether a commit **without** a trailer was nonetheless AI-assisted. Absence of a declaration is not evidence of its opposite. |

**I3 deserves emphasis, because it answers the obvious objection.** Upstream PSScriptAnalyzer does
ship its own standalone per-rule sample scripts, so "were these copied from upstream?" is a real
question rather than a rhetorical one. Three of the six rules this corpus exercises have an upstream
counterpart file; all three were fetched and compared, and seven distinctive upstream tokens were
then searched across the entire 137-file surface. Zero matches.

## Authorship declaration (audit Finding 2)

**21 of the 137 audited files were added by commits declaring AI co-authorship** (`Co-authored-by:
Claude ...` trailers). This is recorded rather than elided.

It does not weaken the licensing claim -- the work was performed for this repository, under its
authorship, and introduces no third-party rightsholder -- but a consumer evaluating the corpus for
their own purposes is entitled to know how it was produced, and a provenance statement that reported
only the flattering half of its own audit would not be worth reading.

## License

**Apache-2.0.** See `LICENSE` and `NOTICE` in this directory.

**Derived from disk on 2026-08-21, not assumed.** A scan of the corpus trees for `SPDX`,
`Copyright (c)`, `GPL-3` and `Apache-2.0` returns **zero hits**: no corpus file carries a per-file
license header of any kind. The files therefore take the repository's license. The repository
relicensed to Apache-2.0 **forward-only, effective from v1.32.0**, and `LICENSE` and
`.claude-plugin/plugin.json` both read Apache-2.0 at that release and after.

> **A caution about grepping for this yourself.** A case-insensitive search for `GPL` across the
> corpus returns false positives -- the sample filename and content token `UsingPlainText` contains
> the substring `ngPl`, which matches `GPL` case-insensitively. The zero-hit result above was
> obtained with the specific needles `SPDX`, `Copyright (c)`, `GPL-3` and `Apache-2.0` for exactly
> that reason. A three-letter license needle matched case-insensitively is not a reliable instrument.

**The historical band.** These same files in a **v1.6.1 through v1.31.2** checkout are under
`GPL-3.0-or-later`; releases **v1.0.0 through v1.6.0** were MIT. The relicense is forward-only and
does not reach back into published releases. This package is defined as the **v1.32.0-or-later**
state of the corpus trees.

## Two things this statement does not do

- **It is not legal advice.** It is a mechanical provenance and attribution record. A serious public
  release warrants human review of the license texts and of the authorship declaration above.
- **It does not certify the samples are correct.** Provenance is about *origin*, not *quality*. What
  the samples are worth as a benchmark is the subject of `README.md` and is measured, separately, by
  the scores the corpus produces.
