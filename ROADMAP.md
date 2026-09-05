# Roadmap

The short, public view: the North Star, what is moving, what is waiting and on what, what is
settled against, the top risks, and where the evidence lives.

This page deliberately carries **no version numbers, counts, or shipped-item tallies** -- those go
stale between releases and a stale count reads as a false claim. For the current version see
[CHANGELOG.md](./CHANGELOG.md) and the GitHub Releases page; for the reasoning behind every
decision below -- including the ones that were declined and why -- see the
[decision ledger](docs/decision-ledger.md).

**Per-initiative detail is not on this page.** It lives in
[docs/roadmap-ii/PROGRAM.md](docs/roadmap-ii/PROGRAM.md), with each initiative's classification,
its gate, and the evidence it rests on. This page stays short on purpose. The program's factual
baseline is [docs/roadmap-ii/CURRENT-STATE.md](docs/roadmap-ii/CURRENT-STATE.md); the preceding
program is archived at [docs/ROADMAP-I-ARCHIVE.md](docs/ROADMAP-I-ARCHIVE.md).

## North Star

> Be the PowerShell layer a coding agent can be trusted with -- every diagnostic honest about
> whether analysis ran, every release and policy cryptographically attributable, every
> effectiveness claim measured -- **in headless, automated, and enterprise environments where
> editor-bound tooling is insufficient or unavailable**.

The bolded clause names the environment the work is for. It is what keeps the program from
drifting back into editor-parity framing: this is not a race to match what an editor extension
already does well.

Two consequences of the North Star are settled rather than open. The plugin is a **client** of
PowerShell Editor Services, not a re-implementation of it -- so capability work means surfacing
what PSES already computes in a form an agent can consume, not growing an analysis engine. And a
**custom-rule seam is declined pending demand**; see the declines table below.

## The relaunch -- substance as the pitch

Findability was the right first goal (2026-07-05) and stays exactly true; this is its
completion, not a departure from it. The relaunch's entire pitch is the thing this project
already does that most tooling doesn't: every claim it makes is checkable. The corpus
false-positive rate isn't asserted, it's recomputed on every CI run. Every design decision is
on record with its reasoning and its declines, not just its wins. Every dispatch ships with
re-runnable proof, including RED controls that demonstrate a check can actually fail before
anyone trusts it green. The white paper and the launch content are a presentation of that
evidentiary discipline as the marketing case itself -- no claim goes out that doesn't trace to
something reproducible in the repo.

**The relaunch is no longer waiting on a gate. Mike ruled it directly, and it went.**

The gate this paragraph used to state -- the relaunch triggers when the Next lane is empty and every
Gated and Paced item is either upstream-blocked or demand-paced with no live signal -- was
**superseded by Mike's direct Path-A ruling** rather than met. That is worth stating plainly instead
of quietly rewriting: the condition was a mechanism for deciding *when*, and the person it reserved
that decision for made it himself. A gate passed through by hand is no longer a gate, and a page
still describing it as pending would be describing a deliberation that has already concluded.

What was chartered as findings-only planning (dispatch 000262 -- a channel plan, a white-paper
outline grounded in what actually ships, and a launch sequence) is executed work now: the release is
cut, published and attested, and the white paper landed in this repository at
[`docs/whitepaper.md`](docs/whitepaper.md), which is the URL the launch channels cite.

**External publishing stays Mike's gate always, and that has not changed** -- it is the one rule
this project has never made an exception to, and the ruling above was Mike exercising that gate, not
removing it. Which channels have gone out, and when, is his record rather than this page's; nothing
here should be read as a claim about what has been posted where.

## Now

Work that is chartered and moving.

**Nothing is.** The lane is empty rather than padded, which is a statement about the present and
not a gap to be filled. The work that last held it -- the daemon surviving a client that walked
away -- is root-caused, fixed and shipped, and no successor to it has been chartered. What has
momentum but is not started is under **Next**; the paced lanes further down each name the
specific thing they wait on.

## Next

Queued, not started.

- **Doctor and command surface.** Closing the gap between "the plugin is installed" and "the user
  can prove it is working". Queued rather than moving: the lane carries no open ruling and no
  chartered work.
- **Agent-facing semantic exposure.** Making more of what PSES already computes reachable by an
  agent, on the surfaces this project already ships.
- **The measured-baseline follow-through.** The six candidate service-level targets are no longer
  candidates: they were **ratified as the project's v1 SLOs on 2026-08-21** and are in force as a
  regression bar, so a release that misses one is missing an adopted target. This bullet previously
  said the targets were not ratified; that was true when it was written and is recorded here rather
  than quietly dropped. What remains open is the part ratification deliberately did **not** close --
  no target is offered for cold start to first-analysis-ready, because no basis for one exists that
  is not simply the measured value rounded back into a promise.

## Gated and paced

Real work that is deliberately not moving, each waiting on a named thing rather than on attention.

- **Native code navigation, end to end.** Registration works. **Serve** does not, on the direct
  path: Claude Code's LSP client rejects the standard server-to-client requests PSES sends during
  initialization. The opt-in `nativeServe = shim` closes that gap locally and is shipped -- but
  the shim is a workaround, and removing it waits on the upstream fix. **The shim's own
  configuration transport is currently suspended**, so this lane is gated twice over rather than
  un-gated in practice: on an affected client the `${user_config.*}` mappings that carry
  `nativeServe` into the serve subprocess are withdrawn, because one unset declared key makes the
  client discard *every* server the plugin declares, and a zero-configuration install must keep
  working. The suspension is deliberate, mechanical to reverse, and its un-gate condition is
  recorded with the removed mappings in `Get-ServeTransportSuspension`
  (`scripts/lib/lsp-common.ps1`); it lifts on
  [anthropics/claude-code#86936](https://github.com/anthropics/claude-code/issues/86936). A
  separate upstream Windows regression
  ([anthropics/claude-code#73961](https://github.com/anthropics/claude-code/issues/73961)), which
  had blocked the native tier from starting at all on Windows, is fixed and closed upstream, so
  what still gates this item is the client's handling of those initialization requests and the
  interpolation defect above, rather than that regression.
- **Corpus commons.** The licensing and provenance audit that gated publishing the correctness
  oracle as a community benchmark has **passed**, and the licensing decision it left open has now
  been made: the corpus publishes under the project's own Apache-2.0 license, one license across
  the repository. It is documented for outside use, reproduction, and citation in
  [docs/corpus.md](docs/corpus.md). What remains is external publishing, and that is
  maintainer-owned -- do not infer from this page that it has happened.
- **Attested diagnostics.** Extending the SLSA / Sigstore chain from release assets to scan
  outputs waits on real efficacy data existing and on a real consumer to read it.
- **Enterprise control plane.** Policy distribution and fleet rollup, continuing the shipped
  `orgPolicy` knob. **Demand-paced:** one slice per real adoption signal, never built ahead of a
  consumer. An adoption signal arrived -- a corporate-IT review ranked runtime dependency
  downloads with no offline path as the top tractable adoption blocker -- and the offline /
  air-gapped bootstrap slice answers it: layered artifact sources feeding the existing pin check,
  and an attested airgap bundle. The lane stays demand-paced; the next slice waits on the next
  signal, as this one did.
- **Scale and robustness.** A performance harness and characterized very-large-repo behavior.
  **On-demand:** it moves when a real scale problem is reported.
- **Deeper rule curation and fix-suggestion quality.** Paced by the dogfood log and gated on real
  interactive usage, not on machinery -- the machinery already ships.

> **Plugin-catalog submission is not an item on this list.** It is maintainer-owned and is not
> tracked on this page as an open action. It previously appeared under "What is next" as "the queued
> next external action", and that framing is an operational hazard rather than a cosmetic staleness:
> a prior session read it as evidence that submission had not happened and caused a duplicate.
> **Do not infer submission state from this page, and do not try to establish it by querying the
> catalog** -- submission goes through a Console form that is invisible to the API, so a query
> cannot answer the question, and acting on one has already gone wrong once. Ask the maintainer.

## Declined, and why

These are settled decisions, not backlog. Each is recorded with its reasoning in the
[decision ledger](docs/decision-ledger.md):

| Declined | Short reason |
|---|---|
| Renaming the plugin | breaks marketplace identity and every published link |
| A file watcher / background workspace sweep | fails the cost and safety bar; `lsp-scan.ps1` already covers explicit whole-repo scanning |
| Loosening the 1.x semver freeze | trades a trust asset for speculative flexibility |
| New custom rules | the rule freeze stands; guidance overrides on rules that already fire are the sanctioned path |
| A custom-rule seam | **declined pending demand** -- it resurrects the declined new-custom-rules item under a new name; guidance overrides remain the sanctioned seam, and real user demand is the only thing that reopens it |
| Flipping the broader ruleset on by default | a missing finding beats a wrong finding; `ruleset = base` is the opt-in |
| Reducing documentation volume | documentation is **restructured**, not reduced |
| Surfacing security-classifier verdicts in the doctor | declined-final; the live named diagnosis it reached for already ships on the bootstrap-failure banner, at the moment of failure |
| Publisher Authenticode signing of the scripts | for a git-distributed plugin the trust boundary is the keyless-signed tag and the commit it names, not a Windows publisher identity; the enterprise-preferred answer is the estate signing with **its own** root, which its policy already trusts, so `scripts/sign-plugin.ps1` ships that paved path instead |

## Top risks

- **Single-maintainer bus factor.** Stated plainly, with the Apache-2.0 continuity path, in
  [CONTINUITY.md](./CONTINUITY.md).
- **Upstream dependence.** The native navigation tier depends on Claude Code's LSP client and on
  PSES; both have open upstream issues this project can file against but cannot fix.
- **A wrong finding costs more than a missing one.** Every broadening decision is gated on the
  measured corpus false-positive bar, which is why defaults stay narrow and every new signal
  ships off by default.
- **Documentation drift.** Mitigated structurally, not by discipline: the knob table, the
  contract's frozen-knob list, and the manifest are set-equality guarded in CI, so a drift is a
  red build rather than a stale doc.

## Where the evidence lives

| Question | Answer lives in |
|---|---|
| What changed, and when | [CHANGELOG.md](./CHANGELOG.md) |
| Why a decision was made (or declined) | [decision ledger](docs/decision-ledger.md) |
| What each initiative is, and what gates it | [docs/roadmap-ii/PROGRAM.md](docs/roadmap-ii/PROGRAM.md) |
| What is true of the codebase today | [docs/roadmap-ii/CURRENT-STATE.md](docs/roadmap-ii/CURRENT-STATE.md) |
| What the preceding program did | [docs/ROADMAP-I-ARCHIVE.md](docs/ROADMAP-I-ARCHIVE.md) |
| What is frozen in 1.x, and what a change costs | [CONTRACT.md](./CONTRACT.md) |
| Whether a claim about diagnostics correctness holds | `tests/corpus/`, recomputed and guarded on every CI run |
| Measured latency | [docs/benchmarks.md](docs/benchmarks.md) |
| What the plugin runs, downloads, and never does | [TRUST.md](./TRUST.md) |
| How a diagnostic flows from edit to banner | [ARCHITECTURE.md](./ARCHITECTURE.md) |
| Upstream issues and their status | [docs/upstream/](docs/upstream/) |

## Operating posture

Fast on a gated path; the gate is fast, not removed. Human gates: accept, merge, the verified
flip, tag, and the product / positioning / sequencing calls. Within an accepted scope,
implementation, design, and ripeness are decided by the implementer. Ground truth -- the live
dispatch log and file inspection -- wins over any document, including this one.
