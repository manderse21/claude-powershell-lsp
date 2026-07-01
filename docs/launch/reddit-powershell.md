# r/PowerShell launch post -- claude-powershell-lsp

Status: DRAFT for Mike's review. Read it once for voice before posting -- it is
your name on it. Repo link is filled. Current released version: v1.21.1 (tagged,
gitsign-signed, provenance-attested; `gh attestation verify` works against the
published v1.21.1 release).

Reminder: the GIF must show a diagnostic that fires on the DEFAULT path (an
unapproved verb like Frobnicate-Thing, or a cmdlet alias like gci). Write-Host
produces a diagnostic only under ruleset=base -- demo it only if the GIF shows
that knob being set.

---------------------------------------------------------------------------

Title: I built a Claude Code plugin that runs PSScriptAnalyzer on every edit (real-time PS diagnostics)

I write a lot of PowerShell with Claude Code and got tired of finding lint
issues only after the fact. So I built a plugin that runs PSScriptAnalyzer
through a warm PowerShell Editor Services (PSES) daemon and feeds the result
straight back into the model's context the moment a .ps1/.psm1/.psd1 is edited
-- so the mistake gets caught and corrected in the same turn. One PSES stays
warm for the whole session, so each edit pays a fast pipe round-trip (warm path
~2.2s measured at build time, with a CI regression guard), not a cold start.

[GIF here]

What it catches today (on the fly):

- Out of the box, the live surface is PSES's own built-in no-settings rule set
  (about 15 rules, of which roughly six fire on everyday code) -- unapproved
  verbs, cmdlet aliases, unassigned variables, plaintext passwords,
  $null-on-the-wrong-side comparisons, and default values on switch parameters
  -- each with PSSA's own fix suggestion. Deliberately lean: quiet by default.
- New since launch prep: one config knob (`ruleset = base`) opts into a broader
  plugin-owned ruleset -- PSScriptAnalyzer's default-on rules, explicitly
  enumerated (54 rules at the pinned analyzer), including PSAvoidUsingWriteHost
  and three Error-severity security rules (hardcoded computer names, plaintext
  ConvertTo-SecureString, and username+password parameter pairs) that PSES's
  built-in set never runs.
- Straight talk on how that broadened set was built: the rules are enumerated
  in a checked-in file, not `IncludeDefaultRules = $true`, so an analyzer
  version bump can't silently shift what you see -- any change is a reviewable
  diff. And before shipping it, I ran the whole set over a known-good real-code
  corpus and cut the three rules that were measurably noise (57 down to 54; one
  was ~90% false-positive on a common script shape). Quiet by default,
  deterministic when broadened, and the noisy rules were measured out rather
  than shipped -- and the default (pses-default) surface didn't move.

Also in the box: a standalone SARIF / CI-scan mode (scripts/lsp-scan.ps1) that
runs the same engine over a file or directory and emits SARIF 2.1.0 for GitHub
code scanning -- the same analysis as the agent path, usable as a CI gate.

Why I think it earns trust (the part I'm actually proud of):

- Measured 0% false-positive rate on a curated correctness corpus: 0 findings
  across 34 clean real-world samples, and 100% true-positive coverage (36/36
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
- Your repo-local PSScriptAnalyzerSettings.psd1 (the nearest one, walked up to
  the project root) always wins: when one resolves, it replaces the live rule
  set entirely -- narrow it or broaden it, your repo's call. The ruleset knob
  only applies when no settings file is found.
- Honest about onboarding: prereqs are PowerShell 7 on your PATH plus internet
  on the first enabled session (PSES + PSScriptAnalyzer self-download, pinned
  and hash-verified). Setup is a few steps -- install pwsh if you don't have it,
  then /plugin marketplace add, install, enable, restart the session, and run
  the bundled doctor to confirm it's healthy. Not a one-liner, but the README
  walks it top to bottom.

Honest status: the inline per-edit diagnostic loop is the working surface today,
on every supported host. Hover, go-to-definition, and find-references are not
live yet -- native LSP registration works, but Claude Code's LSP client
currently times out on the server-to-client initialization handshake (an
upstream issue), so end-to-end serve doesn't complete. The diagnostic loop
doesn't depend on that path at all.

GPL-3.0. Source: https://github.com/manderse21/claude-powershell-lsp
Feedback and false-positive reports welcome -- there's an issue template that
feeds reports straight into the correctness corpus.
