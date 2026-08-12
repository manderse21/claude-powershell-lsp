# powershell-lsp -- governance surface, derived then extended

**What this document is.** The derived inventory of what this project's governance surface
**already establishes**, with a file citation for every row; the genuine gaps against an
enterprise-adoption bar; and a record of which gap each accompanying addition closes. It is the
derivation behind the four Roadmap II R2-14 proposals, not a second copy of them.

**How to read a claim here.** Every row cites the file and, where the file is not the source of
truth, the code the file describes. Where a shipped document and the code disagree, the code wins
and the disagreement is recorded in section 4 rather than smoothed over.

**Derivation moment.** Repository facts derived 2026-08-12 from the plugin repo at `origin/main`
(`c0e4b51`). The GitHub branch-protection facts in section 4 carry their own query stamp.

**Every addition is a proposal.** Nothing here is ratified by being written. The four additions
are ratified by Mike Andersen merging the pull request that carries them, and by nothing else.

---

## 1. What the governance surface already establishes

Nine questions an adopter asks, and where this repository already answers each. **This is the
inventory the additions extend; none of it is restated in the new files.**

| Question | Already answered | Citation |
|---|---|---|
| Who maintains this? | One person, Mike Andersen (`manderse21`), stated as an adoption risk rather than hidden | `MAINTAINERS.md:5-11`; `CONTINUITY.md:17-23` |
| Who may merge to `main`? | Repository admin. `main` lands via a reviewed, merged PR; a local pre-push hook refuses a direct push | `MAINTAINERS.md:24-26`; `CONTRIBUTING.md:68-73` |
| Who may cut a release? | The maintainer alone decides when and at what version; the pipeline performs the mechanics and cuts the tag | `docs/RELEASING.md:3-8`, `32-38` |
| What validates a release? | **Six** gates, each of which refuses rather than proceeds | `docs/RELEASING.md:171-246`; `.github/workflows/powershell-lsp-release.yml:111-228` |
| What is human-only? | **Five** human gates: accept, merge, the `verified` flip, tag, and the product / positioning / sequencing calls | `ROADMAP.md` "Operating posture"; `docs/roadmap-ii/CURRENT-STATE.md:392-393` |
| How is a vulnerability reported? | GitHub Private Vulnerability Reporting, with public issues explicitly refused; the issue chooser routes to the same place | `SECURITY.md:19-37`; `.github/ISSUE_TEMPLATE/config.yml:3-5` |
| What happens after a report? | Acknowledgement best-effort within **7 days**; coordinated disclosure; credit; no bounty | `SECURITY.md:62-72` |
| Which versions get security fixes? | Latest release only; backporting is not promised | `SECURITY.md:7-17` |
| What if the maintainer disappears? | Per-surface failure and recovery, a keyless-custody story with nothing to hand off, and a guaranteed GPLv3 fork floor | `docs/CONTINUITY.md:23-105`; `CONTINUITY.md:58-92` |

Two further facts that bound anything written about support:

- **Hosts.** As of 1.1.1 the hooks **require `pwsh` (PowerShell 7)**. Windows PowerShell 5.1 is
  supported as the **PSES child host** (`ps_host = powershell`), *not* as the hook interpreter
  (`README.md:350-362`). CI runs four legs -- `windows-pwsh`, `windows-powershell`, `ubuntu-pwsh`,
  `macos-pwsh` (`.github/workflows/powershell-lsp-ci.yml` `matrix.label`).
- **Test framework.** The Pester bootstrap is bounded to the **5.x major**
  (`-MinimumVersion 5.0.0 -MaximumVersion 5.99.99`, `tests/run-tests.ps1:19-26`), with Pester 6
  **deliberately deferred** (`docs/decision-ledger.md:2114-2119`).

**Conclusion of the inventory.** Release authority, tag custody, continuity, and the reporting
channel are already established and already honest. The surface is not thin; it is *incomplete in
four specific places*, listed next.

## 2. The genuine gaps

A gap qualifies here only if no shipped file answers it. Each names the addition that closes it.

| # | Gap | Why it is genuine | Closed by |
|---|---|---|---|
| 1 | **No machine-readable statement of who reviews.** | No `CODEOWNERS` exists at any of the three paths GitHub reads (root, `.github/`, `docs/`) -- swept 2026-08-12, zero hits. Review ownership is prose only. | `.github/CODEOWNERS` |
| 2 | **The security *response* path stops at the reporter.** | `SECURITY.md` tells a reporter what to expect but never says how a fix reaches users: which gates it must clear, that it is not exempt from them, or how advisory / CHANGELOG / release interlock. | `SECURITY.md`, new final section |
| 3 | **Release *authority* is described procedurally, never stated.** | `docs/RELEASING.md` is a runbook and `MAINTAINERS.md` is an access checklist. Neither states who may release as an authority claim -- and `MAINTAINERS.md` miscounts the gates (section 4). | `MAINTAINERS.md`, new section |
| 4 | **No support or deprecation posture.** | `SECURITY.md` "Supported versions" is a *security-backport* policy, not a compatibility one; `CONTRACT.md` freezes config surfaces, not hosts. **The string `deprecat` appears zero times in every `.md` in the repository** (swept 2026-08-12). | `docs/SUPPORT-POLICY.md` |

## 3. The second maintainer -- HUMAN-GATED

**The documents are shipped. The human half is open. Engineering cannot close it.**

`MAINTAINERS.md` already carries a complete second-maintainer on-ramp: the access grants to
confirm, the release procedure to learn, and how to verify a release end to end
(`MAINTAINERS.md:13-68`). `CONTINUITY.md:75-82` records the two open items that need a decision --
whether to designate a backup repository administrator, and whether the marketplace listing should
have a documented fallback owner. `docs/roadmap-ii/CURRENT-STATE.md:394-395` records the bus factor
as single-person.

What is missing is **a second person**. No document, check, or process closes that. Writing more
governance prose about it would make the gap look smaller without making it smaller, which is the
failure mode this whole document exists to avoid. It is recorded here as **HUMAN-GATED**, in the
same register as the other human gates, and it is *not* dressed as a process.

This gap has one concrete downstream consequence, derived in section 4: it is the reason the
`CODEOWNERS` file must ship inert.

## 4. Derivations recorded

### 4.1 Why the security-response process EXTENDS `SECURITY.md` rather than adding a new file

The dispatch asked which shape duplicates less. Derived from what `SECURITY.md` already carries:

A standalone `docs/SECURITY-RESPONSE.md` could not be coherent without restating the **triage
window** (`SECURITY.md:64-65`) and the **disclosure posture** (`SECURITY.md:68-70`) -- a reader
arriving at a response document needs both, and both already have exactly one home. That would put
two load-bearing facts in two files.

This repository has already paid for that mistake once and recorded the bill:
`docs/roadmap-ii/CURRENT-STATE.md:246-250` books **two similarly named trust documents**
(`TRUST.md` and `docs/trust.md`, differing only by case and directory) as technical debt. And
`docs/RELEASING.md:10-13` states the governing convention directly -- the continuity and maintainer
docs "link here rather than restating the procedure, so the steps and the gates live in one place
only."

The genuine gap (gap 2) is the **fix-and-release path**, which is net-new content rather than a
restatement, and which reads as the natural continuation of "What to expect". So it lands **in
`SECURITY.md`, in place**. Duplication added: zero.

### 4.2 The gate count: the pipeline has SIX gates, and `MAINTAINERS.md` says four

`MAINTAINERS.md:45-46` states the pipeline "refuses to tag unless all four gates pass (merged to
main, tag free, version lockstep, CI green on every leg)". The workflow itself declares **six**
(`.github/workflows/powershell-lsp-release.yml:111-228`), and `docs/RELEASING.md:171-246` documents
six. The omitted two are **Gate 5** (tree-vs-published parity) and **Gate 6** (the dry-run pair).

Dated precisely, because the two halves of the drift are not the same kind of error:

- `MAINTAINERS.md` was created **2026-07-19** (`24bbf6e`, dispatch 000136). At that exact commit the
  workflow already declared **five** gates -- Gate 5 landed with dispatch 000076. So the file was
  **understated by one when it was written**; it did not merely age.
- **Gate 6** landed later (`37ce829`, dispatch 000197 leg 6), widening the gap to two.

This is corrected in place as a **cited correction**, not a silent rewrite, because the release
authority statement being added to that same file cites the gates -- leaving "four gates" two
paragraphs above would have made the file contradict itself.

**A premise nuance, recorded per Hub Rule 6.** The 000227 inbox describes "the five-gate release
pipeline". Two distinct five/six counts exist in this project and the phrase collapses them: the
**release pipeline has six machine gates**, while **five gates are human-only** (accept, merge, the
`verified` flip, tag, and the product calls -- `ROADMAP.md` "Operating posture", recorded at
`docs/roadmap-ii/CURRENT-STATE.md:392-393`). Nothing about the work changes; the release-authority
statement is *better* for naming both, since the two sets are exactly what divides what the pipeline
enforces from what only a human can pass.

### 4.3 `CODEOWNERS` ships INERT -- and the exact settings action that would activate it

**No settings change was made anywhere by this dispatch.** The live protection state was read only.

Live state, queried **2026-08-12** via
`gh api repos/manderse21/claude-powershell-lsp/branches/main/protection`:

| Setting | Live value |
|---|---|
| `required_status_checks.contexts` | `ubuntu-pwsh`, `windows-powershell`, `windows-pwsh`, `macos-pwsh` -- the four CI legs, `strict: true` |
| `required_pull_request_reviews.require_code_owner_reviews` | **`false`** |
| `required_pull_request_reviews.required_approving_review_count` | **`0`** |
| `enforce_admins.enabled` | **`true`** |
| `allow_force_pushes` / `allow_deletions` | `false` / `false` |
| repository rulesets | none (`gh api .../rulesets` returns `[]`) |

So branch protection **is** configured, and it already requires all four CI legs. What it does not
do is consult a code-owners file.

**The exact unperformed action that would activate `.github/CODEOWNERS`:** in
**Settings -> Branches -> Branch protection rules -> `main`**, under *Require a pull request before
merging*, tick **"Require review from Code Owners"** -- equivalently, set
`required_pull_request_reviews.require_code_owner_reviews` to `true` on that rule. **This dispatch
did not perform it, and recommends against performing it today**, for a derived reason:

**Enabling it today would deadlock the repository.** A code-owner requirement is satisfied only by
an approving review *from a code owner*. GitHub does not permit a user to approve their own pull
request; `manderse21` is the sole code owner and the author of effectively every pull request; and
`enforce_admins` is **`true`**, so the admin bypass that would otherwise absorb this is closed. The
three facts together mean no pull request could be merged.

That is not an argument against the file -- it is the argument for shipping it as **content now,
settings later**. The file states review ownership in the place tooling looks for it, and it becomes
enforceable the moment the gap in section 3 closes. It is the one addition here whose activation is
gated on a *second human*, not on a decision.

This also matches an existing recorded posture rather than inventing one: `CONTRIBUTING.md:87-89`
already draws the same line, noting that the local pre-push guard's machine-independent complement
is branch protection, "a separate repo-settings change, not part of the hook."

### 4.4 Why the support posture is a new file, and why it is not named `SUPPORT.md`

No existing document owns the host-and-compatibility axis: `SECURITY.md` "Supported versions" is
security backports only; `CONTRACT.md` freezes *config surfaces* (knob names, status tokens) and
their semver rules; `README.md` "Platform support" states host facts without making them a
commitment. Folding hosts into `CONTRACT.md` would also put un-guarded prose inside a document that
is CI drift-guarded against `plugin.json` and `lsp-common.ps1` (`CONTRACT.md:196-219`) -- a stale
copy is most dangerous exactly there.

The file is `docs/SUPPORT-POLICY.md` and **not** `docs/SUPPORT.md` deliberately. GitHub treats a
`SUPPORT.md` in the root, `.github/`, or `docs/` as a special file and surfaces it as a
*where-to-get-help* link in the new-issue flow. This repository already routes that need through
`.github/ISSUE_TEMPLATE/config.yml`, whose `contact_links` point at the security advisory form and
at the README troubleshooting section. Naming the file `SUPPORT.md` would have hijacked that
routing with a compatibility policy, which is a different question than "where do I get help". The
explicit name avoids the collision and says what the file is.

## 5. What was deliberately not done

- **No settings were changed** -- no branch-protection edit, no required-review toggle, no
  repository-settings change of any kind. Section 4.3 is a read.
- **No ledger row anywhere** (ratified Roadmap II ruling 3; appends deferred to R2-02).
  `docs/decision-ledger.md` and `ROADMAP.md` are untouched.
- **No recruitment action** for a second maintainer, and no external posting of any kind.
- **No contradiction of `MAINTAINERS.md` or `CONTINUITY.md`.** The single correction is the gate
  count in section 4.2, cited and dated, applied in place.
