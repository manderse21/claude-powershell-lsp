# r/PowerShell launch post -- claude-powershell-lsp

Status: DRAFT for Mike's review. Read it once for voice before posting -- it is
your name on it. Repo link is filled. Rewritten to v1.23.0 ground truth
(supersedes the abandoned v1.19.0-era 000095 draft): every version, feature,
knob, and count below was verified against disk this session. The plugin is at
v1.23.0 (the latest released tag). The newest surface is native navigation
(hover / go-to-definition / find-references) through the opt-in nativeServe
shim -- stated with the honest Windows launcher-guard caveat, a documented known
issue. The supply-chain lines (pinned + SHA-256 verified, CycloneDX SBOM, SLSA
provenance, keyless-signed tag) are stated as fact -- `gh attestation verify`
works against the published release. POSTING is still your gate: this rewrites
the draft, it does not post anything.

Reminder: the GIF must show one of the SIX surfaced rules (an unapproved verb
like Frobnicate-Thing, or a cmdlet alias like gci) -- NEVER Write-Host, which
produces no diagnostic on the default live path.

---------------------------------------------------------------------------

Title: I built a Claude Code plugin that runs PSScriptAnalyzer on each edit (real-time diagnostics)

I write a lot of PowerShell with Claude Code and got tired of finding lint
issues only after the fact. So I built a plugin that runs PSScriptAnalyzer
through a warm PowerShell Editor Services (PSES) daemon and feeds the result
straight back into the model's context the moment a .ps1/.psm1/.psd1 is edited
-- so the mistake gets caught and corrected in the same turn. One PSES stays
warm for the whole session, so each edit pays a fast pipe round-trip (warm path
~2.2s measured, guarded in CI against regressions), not a cold start.

[GIF here]

What it catches today (on the fly):
- Six PSScriptAnalyzer rules surface live through PSES: unapproved verbs,
  cmdlet aliases, unassigned variables (declared but never read), plaintext
  passwords, $null-on-the-wrong-side comparisons, and default values on switch
  parameters -- each with PSSA's own fix suggestion.
- Plus a few always-on checks I added for the mistakes an AI (or a careless
  paste) drops into PowerShell specifically, run as an AST pass before PSSA so
  they cost no extra parse: non-ASCII characters smuggled into a script (smart
  quotes, en/em dashes -- the ones that mojibake when Windows PowerShell 5.1
  reads a UTF-8-without-BOM file), PowerShell-7-only syntax (&&, ||, ternary,
  ??) in a file that never declares #Requires -Version 7, and Unix/bash command
  names (grep, sed, awk, chmod...) dropped into a .ps1.
- Straight talk on the ruleset: PSES's live analysis set is deliberately
  narrower than the full Invoke-ScriptAnalyzer CLI. Notably, Write-Host
  (PSAvoidUsingWriteHost) is NOT surfaced on the default path. I'd rather give
  you the exact six than claim "the whole ruleset" and have you catch me out.
  If you want more, an opt-in `ruleset = base` (or your own
  PSScriptAnalyzerSettings.psd1) broadens the live surface -- Write-Host and the
  Error-severity security rules included.

The newest piece -- native navigation. Hover, go-to-definition, and
find-references now serve to Claude Code's native LSP client through an opt-in
handshake shim (`nativeServe = shim`, off by default) that works around an
upstream Claude Code LSP-client init-handshake bug locally, without waiting on
the fix.
- Honest caveat, because most of you are on Windows: Claude Code 2.1.196-2.1.200
  currently refuses to start the plugin's LSP server on Windows -- a
  launcher-level guard rejects the bare `pwsh` command before spawn ("unsafe
  location") -- so native nav does NOT start on Windows yet, even with the shim.
  It is an upstream regression (it also breaks the official pyright-lsp plugin),
  filed as anthropics/claude-code#73961; macOS/Linux with the real client is
  untested. The per-edit diagnostics loop runs through a different, unguarded
  path and is unaffected -- it works on every supported host.

Also opt-in, if you want them (details live in the README and its configuration
reference rather than inline here): format-on-edit with a guarded write-back
(`formatOnEdit = apply` -- stale-write compare-and-swap, atomic swap,
BOM/EOL-preserving, and it announces itself so the agent re-reads), a "command
from an uninstalled module" hint (`moduleAwareness = suggest`), and a standalone
SARIF 2.1.0 / CI-scan mode (`scripts/lsp-scan.ps1`) that runs the same engine
over a file or directory for GitHub code scanning -- the same analysis as the
agent path, usable as a CI gate.

Why I think it earns trust (the part I'm actually proud of):
- Measured 0% false-positive rate on a curated correctness corpus: 0 findings
  across 46 clean real-world samples, and 100% true-positive coverage (36/36
  known-bad cases surface their expected rule). These aren't prose numbers --
  they're recomputed from the live tool on every CI run and fail the build if
  the false-positive rate rises above zero or coverage drops below 100%. The
  expected findings are derived by running the real tool and snapshotting what
  it emits, so a hand-edited snapshot can't fake a pass.
- Supply-chain posture, because a plugin that downloads and runs code should
  have to earn it: PSES and PSScriptAnalyzer are version-pinned and SHA-256
  verified before use, and a mismatch fails closed. The release ships a
  CycloneDX SBOM and a SLSA build-provenance attestation, and the release tag
  itself is keyless-signed via Sigstore (gitsign) through GitHub's OIDC -- no
  maintainer-held key in the trust path. You can verify the release yourself
  with `gh attestation verify`.

A few specifics for this sub:
- Requires PowerShell 7 (pwsh) for the hooks. Windows PowerShell 5.1 is
  supported only as the optional analyzer (PSES child) host -- it can't run the
  hooks itself.
- Honors your repo-local PSScriptAnalyzerSettings.psd1 (the nearest one, walked
  up to the project root). Those settings can narrow or broaden what's reported,
  and they win over both the built-in set and the opt-in base ruleset.
- Honest about onboarding: prereqs are PowerShell 7 on your PATH plus internet
  on the first enabled session (PSES + PSScriptAnalyzer self-download, pinned
  and hash-verified). Setup is a few steps -- install pwsh if you don't have it,
  then /plugin marketplace add, install, enable, restart the session, and run
  the bundled doctor to confirm it's healthy. Not a one-liner, but the README
  walks it top to bottom.

Honest status: the inline per-edit diagnostic loop is the working surface today,
on every supported host. Native navigation is the newer, opt-in bonus -- it
serves through the shim on hosts where Claude Code will start the server, with
the Windows launcher-guard caveat above still open upstream. The diagnostic loop
does not depend on the native path at all.

Apache-2.0. Source: https://github.com/manderse21/claude-powershell-lsp
Feedback and false-positive reports welcome -- there's an issue template that
feeds reports straight into the correctness corpus.
