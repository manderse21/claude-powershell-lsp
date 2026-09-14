# The powershell-lsp Assurance Pack

**Seven rules this plugin owns, because PowerShell's own analyzer structurally cannot.**

PowerShell diagnostics in this plugin come from two places. The overwhelming majority come from
**PSScriptAnalyzer**, pinned and vendored, and this project neither writes nor modifies them -- the
`ruleset` knob only selects *which* of them apply (see
[configuration.md](configuration.md#ruleset)). The remaining seven are written here. This page
names that set, states the test that decides whether a rule belongs in it, and -- just as
importantly -- states what the pack is not.

## The pack

| Rule ID | Severity | What it catches | Finder |
|---|---|---|---|
| `NonAsciiChar` | Warning | Non-ASCII characters that survive the parse but change meaning -- homoglyphs, invisible separators, smart quotes pasted in from a document | `Find-NonAsciiSmuggling` |
| `PS7OnlySyntax` | Warning | Syntax that is valid PowerShell 7 and a runtime failure on Windows PowerShell 5.1 | `Find-Ps7OnlySyntax` |
| `BashIsm` | Warning | Shell idioms that parse as PowerShell and do not mean what they say | `Find-BashIsm` |
| `CommandLinePlaceholder` | Warning | An unfilled `<...>` placeholder on a command line, where `<` is a redirection operator and the result is a parse error rather than text | `Find-CommandLinePlaceholder` |
| `ModuleNotInstalled` | Information | A command from a module that is not installed here and is not imported, required, or defined in the file | `Find-ModuleAwareness` |
| `ManifestConsistency` | Warning | A module manifest disagreeing with the files beside it | `Find-ModuleManifest` |
| `ProhibitedSuppression` | Warning | A `SuppressMessageAttribute` naming a PSScriptAnalyzer rule the org-wide policy prohibits suppressing | `Find-ProhibitedSuppression` |

All seven are enumerated in `rulesets/rule-rationales.psd1` under `owned`, and each carries a
hand-authored rationale there -- necessarily hand-authored, because PSScriptAnalyzer has no
metadata for a rule it does not have.

**The derived count is seven.** It was re-derived here from the emitters rather than restated: each
of the seven has a `ruleId = '<name>'` assignment in shipped code (`scripts/lib/lsp-common.ps1`,
plus `scripts/pses-daemon.ps1` for `ManifestConsistency`), and `rulesets/rule-rationales.psd1`
records `owned_count = 7`. Six shipped before this page existed (the 000282 count this page
originally named); the seventh, `ProhibitedSuppression`, is dispatch 000294's addition under R23
(see "What this pack is NOT" below).

> **The stale generator-comment count this page once flagged is now fixed.** A prior revision of
> this page found `scripts/regen-rule-rationales.ps1`'s header comment reading *"hand-authored
> rationales for the 5 plugin-owned finders"* while the table beneath it held six --
> `CommandLinePlaceholder` was added later without the comment being updated -- and left it alone
> because that slice was docs-only. Dispatch 000294 touched that exact comment to add the seventh
> entry and corrected the count in the same edit, so the count there now matches the table (7) and
> this callout no longer describes a live discrepancy.

## The eligibility test

A rule belongs to this pack when **the judgment it makes cannot be reached from the file's own
syntax tree.** It needs something the file does not contain:

- **the host it will run on** -- `PS7OnlySyntax` is a judgment about Windows PowerShell 5.1, not
  about the text;
- **the machine it will run on** -- `ModuleNotInstalled` is a judgment about what is installed
  here;
- **a file beside it** -- `ManifestConsistency` compares a manifest to its siblings;
- **the bytes beneath the parse** -- `NonAsciiChar` reads characters the parser accepted and a
  reader cannot see; `BashIsm` and `CommandLinePlaceholder` name intent that parsed cleanly, or
  failed to parse for a reason worth naming;
- **an administrator's own policy** -- `ProhibitedSuppression` judges a `SuppressMessageAttribute`
  against a list PSScriptAnalyzer has no concept of (what THIS organization has decided may never
  be silenced, not what the language or the analyzer forbids). Measured, not assumed (dispatch
  000292): PSSA's settings object carries no suppression-aware property at all, so no settings file
  could express this even in principle -- the judgment needs org policy data the file's own AST
  was never going to contain, the same shape of gap every other row in this table names.

That test is not a preference, it is the reason these seven are not PSScriptAnalyzer rules and
could not become them: a PSScriptAnalyzer rule is by construction a function of one file's AST (or,
for `ProhibitedSuppression`, of settings PSSA's own settings channel cannot carry). It is also why
the pack is small and expected to stay small -- most defects genuinely *are* decidable from the
AST, and those belong upstream, where they get more eyes than this project can give them.

Two consequences worth stating:

- **A finder that emits no finding is not in the pack.** `Find-ReferenceSurfacing` reads the
  workspace and emits counts on the additional-context channel; it makes no judgment and carries no
  rule ID, so it is not a rule and is not listed above.
- **The pack is orthogonal to the `ruleset` knob.** `ruleset` selects among PSScriptAnalyzer rule
  sets. These seven are not PSScriptAnalyzer rules, so they are unaffected by it.
  `ModuleNotInstalled` has its own gate -- the `moduleAwareness` knob; `ProhibitedSuppression` has
  its own gate -- the `orgPolicy` knob's `ProhibitedSuppressions` list, empty (off) by default; the
  others surface on the normal edit path.

## What this pack is NOT

Naming a set that already exists is the whole of this page. Three things it deliberately does not
do, each because a decision was already taken and is not reopened here:

- **Not a custom-rule seam.** There is no mechanism here for you to add a rule of your own, and
  this page does not propose one. That is Pillar H, and it is **declined pending demand** -- a
  plug-in rule interface is a support surface with a compatibility contract, and nothing has yet
  asked for it.
- **Six of the seven are not new; the seventh required an explicit ruling, not a casual decision.**
  The first six shipped before this page existed, and this page described them together for the
  first time under 000282's own ruling (R16) -- naming that set was never a licence to grow it.
  `ProhibitedSuppression` is the one genuine addition since, and it exists only because Mike
  Andersen ruled R23 (2026-09-12, plugin issue #235) = D: a plugin-owned rule flagging a prohibited
  suppression on the edit path, paired with a real `-IncludeSuppressed` re-surfacing pass in
  `lsp-scan.ps1` for the repository/CI path (dispatch 000294). **The freeze still stands for the
  other six and for this one now that it has shipped** -- this page is not reopening any of them,
  and the next addition needs the same thing this one got: a ruling, not a restatement of this
  page.
- **Not an organizational extension mechanism.** The enterprise review's item 12 has two halves.
  This page is the cheap half: give the plugin-owned set a name and an eligibility test. The other
  half -- **signed organizational rule extensions** -- is **not proposed**, here or anywhere else
  in the current program. It needs a trust root the org-policy mechanism does not have, which
  `THREAT-MODEL.md` T4.1 says in its own words.

## Where to look next

- [configuration.md](configuration.md#ruleset) -- the `ruleset` knob, and what it does and does not
  select.
- `rulesets/rule-rationales.psd1` -- the generated rationale table, including the `owned` list this
  page describes. It is generated; do not hand-edit it.
- [corpus.md](corpus.md) -- how rules are evidenced against real code.
