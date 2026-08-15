<!--
Reviews and security response come from one maintainer. A focused, tested
change turns around fastest -- see CONTRIBUTING.md, "Opening a pull request".
-->

## What this changes

<!-- One or two sentences. What behaviour differs after this merges? -->

## Why

<!-- The problem, not the patch. Link an issue if one exists. -->

## How it was verified

<!--
Name what you actually ran, not what you intended to run. "Windows legs at
least" is the documented floor:

    pwsh -File tests/run-tests.ps1

If you fixed a bug, say what reproduced it before and what does not now.
-->

## Checklist

- [ ] `pwsh -File tests/run-tests.ps1` passes locally (Windows legs at minimum)
- [ ] **ASCII only** in any `.ps1` / `.psm1` / `.psd1` touched -- the PowerShell 5.1
      codepage trap, see DEV_NOTES.md
- [ ] CHANGELOG updated **if observable behaviour changed**
- [ ] CONTRACT.md and README updated **if a knob or token changed** (CI enforces this;
      the four-leg matrix will fail otherwise)
- [ ] Daemon/LSP path stays silent on stdout
- [ ] Commits are focused and staged by explicit pathspec
- [ ] Signed off with `git commit -s` (Developer Certificate of Origin -- there is no CLA)

## Notes for the reviewer

<!--
Anything that would otherwise cost a round trip: a deliberate omission, a
tradeoff you considered and rejected, a follow-up you are not doing here.

Security vulnerability? Do NOT open a public PR or issue -- follow SECURITY.md
and file a private advisory instead.
-->
