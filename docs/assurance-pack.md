# The powershell-lsp Assurance Pack

**Six rules this plugin owns, because PowerShell's own analyzer structurally cannot.**

PowerShell diagnostics in this plugin come from two places. The overwhelming majority come from
**PSScriptAnalyzer**, pinned and vendored, and this project neither writes nor modifies them -- the
`ruleset` knob only selects *which* of them apply (see
[configuration.md](configuration.md#ruleset)). The remaining six are written here. This page names
that set, states the test that decides whether a rule belongs in it, and -- just as importantly --
states what the pack is not.

## The pack

| Rule ID | Severity | What it catches | Finder |
|---|---|---|---|
| `NonAsciiChar` | Warning | Non-ASCII characters that survive the parse but change meaning -- homoglyphs, invisible separators, smart quotes pasted in from a document | `Find-NonAsciiSmuggling` |
| `PS7OnlySyntax` | Warning | Syntax that is valid PowerShell 7 and a runtime failure on Windows PowerShell 5.1 | `Find-Ps7OnlySyntax` |
| `BashIsm` | Warning | Shell idioms that parse as PowerShell and do not mean what they say | `Find-BashIsm` |
| `CommandLinePlaceholder` | Warning | An unfilled `<...>` placeholder on a command line, where `<` is a redirection operator and the result is a parse error rather than text | `Find-CommandLinePlaceholder` |
| `ModuleNotInstalled` | Information | A command from a module that is not installed here and is not imported, required, or defined in the file | `Find-ModuleAwareness` |
| `ManifestConsistency` | Warning | A module manifest disagreeing with the files beside it | `Find-ModuleManifest` |

All six are enumerated in `rulesets/rule-rationales.psd1` under `owned`, and each carries a
hand-authored rationale there -- necessarily hand-authored, because PSScriptAnalyzer has no
metadata for a rule it does not have.

**The derived count is six, and the docket's count of six is correct.** It was re-derived here from
the emitters rather than restated: each of the six has a `ruleId = '<name>'` assignment in shipped
code (`scripts/lib/lsp-common.ps1`, plus `scripts/pses-daemon.ps1` for `ManifestConsistency`), and
`rulesets/rule-rationales.psd1` records `owned_count = 6`.

> **One stale count found while deriving, recorded and not fixed.** The generator's header comment
> at `scripts/regen-rule-rationales.ps1:85` reads *"hand-authored rationales for the 5 plugin-owned
> finders"*, while the block beneath it holds six -- `CommandLinePlaceholder` was added later
> without the comment being updated. The generated table and the emitters both say six, so nothing
> downstream is wrong; the comment is. It is left alone here because this slice is a document and
> changes no code.

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
  failed to parse for a reason worth naming.

That test is not a preference, it is the reason these six are not PSScriptAnalyzer rules and could
not become them: a PSScriptAnalyzer rule is by construction a function of one file's AST. It is
also why the pack is small and expected to stay small -- most defects genuinely *are* decidable
from the AST, and those belong upstream, where they get more eyes than this project can give them.

Two consequences worth stating:

- **A finder that emits no finding is not in the pack.** `Find-ReferenceSurfacing` reads the
  workspace and emits counts on the additional-context channel; it makes no judgment and carries no
  rule ID, so it is not a rule and is not listed above.
- **The pack is orthogonal to the `ruleset` knob.** `ruleset` selects among PSScriptAnalyzer rule
  sets. These six are not PSScriptAnalyzer rules, so they are unaffected by it. `ModuleNotInstalled`
  has its own gate -- the `moduleAwareness` knob -- and the others surface on the normal edit path.

## What this pack is NOT

Naming a set that already exists is the whole of this page. Three things it deliberately does not
do, each because a decision was already taken and is not reopened here:

- **Not a custom-rule seam.** There is no mechanism here for you to add a rule of your own, and
  this page does not propose one. That is Pillar H, and it is **declined pending demand** -- a
  plug-in rule interface is a support surface with a compatibility contract, and nothing has yet
  asked for it.
- **Not a new rule.** Nothing above is new. Every one of the six ships today and has shipped for
  some time; this page describes them together for the first time. **The rule freeze stands** --
  naming a set is not a licence to grow it.
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
