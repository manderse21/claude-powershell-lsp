# Doctor-surface docket -- FINDINGS ONLY

> ## NO BUILD IS EXECUTED BY THIS DOCUMENT
>
> Nothing below was implemented. No script changed, no knob was added, no check was written, and
> no status text moved. Every slice in section 4 is a **proposal with a price on it**, and the
> choice among them -- including the choice to build none of them -- is Mike Andersen's.
>
> Assembled by dispatch **000276** (2026-09-05), against the plugin at `v1.33.0`, peeled commit
> `6ab2d24bf254787520ad9449c4e6c17f74ee708d`. The Next lane on `ROADMAP.md` carries "Doctor and
> command surface" as queued with **no open ruling and no chartered work**; this docket exists so
> that a ruling, if one is wanted, is made against a census rather than against an impression.

---

## 0. The bar this docket measures against, stated before anything is measured

The North Star names the environments:

> Be the PowerShell layer a coding agent can be trusted with ... **in headless, automated, and
> enterprise environments where editor-bound tooling is insufficient or unavailable**.

So the question is not "is the doctor a good report?" It is: **can an operator in a terminal, over
SSH, in CI, or inside a container turn what these commands print into the conclusion "it is
working" -- without an editor, and without a human reading prose?**

**This is a different question from the one `DX-AUDIT.md` asked, and the difference is the reason
this docket is not a re-litigation.** That audit walked a *human stranger* through install, first
diagnostic, config change and upgrade, in an editor-adjacent session, and asked whether they could
understand and recover. Its findings are closed and are **not reopened here**: D1-D4 and O1-O4 were
fixed by dispatch 000265 and shipped in v1.32.0 (O2's structural half by dispatch 000269), and
T1-T3 are accepted as priced tradeoffs (ratified G4, 2026-08-21). Nothing below asks for any of
them to be revisited.

---

## 1. Census -- what the three surfaces prove today

Derived from disk at the tag: `commands/doctor.md`, `commands/status.md`, `commands/scan.md`, and
`scripts/doctor.ps1` / `scripts/lsp-scan.ps1`. The doctor's shipped output was read from
`evidence/v1.33.0/results/doctor-output.txt` rather than re-run, so no daemon was started by
assembling this.

### 1.1 `/powershell-lsp:doctor` -- `scripts/doctor.ps1`

**14 checks**, each emitting a `{Status, Component, Detail, Remediation}` object through one
`New-DoctorResult` seam whose `ValidateSet` pins the vocabulary to `pass` / `fail` / `unknown`.
Report-only by contract: it never downloads, repairs, bootstraps, or starts, restarts or stops
anything.

| # | Check (component) | What its evidence actually proves | Survives a headless / CI / container run? |
|---|---|---|---|
| 1 | PowerShell 7 (pwsh) host | `pwsh` on PATH and its resolved version | **Yes** -- host fact, session-independent |
| 2 | Plugin enabled | the plugin environment is present in *this Claude Code session* | **No** -- this is the session gate |
| 3 | PSES bundle bootstrapped | marker present and `Start-EditorServices.ps1` in place | Yes, if the data dir is visible |
| 4 | PSScriptAnalyzer vendored | vendored and importable at the pinned version | Yes, if the data dir is visible |
| 5 | Artifact source | download vs bundle vs mirror provenance | Yes, if the data dir is visible |
| 6 | Offline readiness | whether an offline artifact source is configured | Yes -- config fact |
| 7 | First-run download hosts reachable | TCP 443 to `github.com`, `www.powershellgallery.com` | Yes -- network fact |
| 8 | Warm PSES daemon (runtime) | a live daemon answered on its named pipe | **No** -- needs a session's warm daemon |
| 9 | Active ruleset surface | which rules are really applied, and which config layer won | Partly -- needs the resolved config |
| 10 | Org policy exclusions | whether org-wide exclusions are applied | Yes -- config fact |
| 11 | **Test diagnostic observed end-to-end** | **the only check that proves diagnostics are produced rather than merely installed** -- a synthetic defect returns a real finding through the same pipe an edit uses | **No** -- needs the warm daemon |
| 12 | Native-serve status | whether hover / definition / references serve | Yes -- config fact |
| 13 | PSES child host (`ps_host`) | defers to check 1 unless `ps_host` names something else | Yes (UNKNOWN by design -- DX-AUDIT T3) |
| 14 | Serve-subprocess config transport | configured-vs-effective, so nothing is silently dropped | Yes -- config fact |

### 1.2 `/powershell-lsp:status` -- `scripts/doctor.ps1 -Summary`

**Not a different instrument.** `-Summary` is a *rendering* over the same `Invoke-Doctor` seam:
the checks that run, their statuses and the exit code are identical, and only the per-check detail
and remediation prose are omitted. That matters below -- it is the shipped proof that a second
rendering over this seam is cheap and precedented.

### 1.3 `/powershell-lsp:scan` -- `scripts/lsp-scan.ps1`

The outlier, and the reason the gap is visible at all. Scan already ships everything the doctor
does not: `-Format sarif|text` with **SARIF 2.1.0 as the default**, `-OutputPath` for writing a
file, and `-FailOn note|warning|error` which **exits 2** when findings reach a level. A CI job can
consume scan structurally, gate on it, and upload it to code scanning.

---

## 2. The gap, stated as one finding

> **`exit 0` from the doctor does not mean "it is working". It means "nothing FAILED" -- and in
> exactly the environments the North Star names, the checks that would prove it is working do not
> fail, they go UNKNOWN.**

Both halves are derived from the source, not inferred:

- **UNKNOWN cannot move the exit code.** `scripts/doctor.ps1` computes
  `$doctorFailures = @($doctorResults | Where-Object { $_.Status -eq 'fail' }).Count` and then
  `if ($doctorFailures -gt 0) { exit 1 } else { exit 0 }`. The file's own header says it: *"Exit 0
  when no check FAILED (passes and honest unknowns are not failures)"*.
- **The probative checks are the session-dependent ones.** Checks 2, 8 and 11 are the ones that
  establish the plugin is loaded, the daemon is alive, and a real diagnostic came back through the
  real pipe. All three degrade to UNKNOWN outside a Claude Code session -- `commands/doctor.md`
  says the most common cause of an UNKNOWN is exactly that.

**Therefore a container in which nothing works at all, and a healthy install, are indistinguishable
by exit code.** Both exit 0. The information that separates them exists and is printed correctly --
the doctor is honest, and that is not the defect -- but it exists **only as English prose**, and a
CI job cannot assert on it without grepping human sentences that `CONTRACT.md` explicitly does not
freeze.

**A second, smaller gap follows from the same root:** `scripts/doctor.ps1` has **no
machine-readable output mode**. Its parameters are `-SessionId`, `-ProbeNativeServe` and
`-Summary`; every JSON call inside the file is internal (manifest reads, the pipe protocol, result
files). So the one surface whose whole job is "prove it is working" is the one surface a machine
cannot read, while `lsp-scan.ps1` -- whose job is finding defects -- emits SARIF by default.

**What this docket is NOT claiming.** It is not claiming the doctor is dishonest, that UNKNOWN is
the wrong status, or that DX-AUDIT missed something within its own scope. **T3 priced the
*cosmetic* cost of a permanent UNKNOWN** (a summary line that never reads all-PASS) and priced it
correctly. What was never priced is the *machine-consumability* cost of the same design in the
headless case, because that was not the question DX-AUDIT was asked.

---

## 3. What an operator can and cannot establish today

| Question the North Star implies | Answerable headless today? | By what |
|---|---|---|
| Is a supported PowerShell present? | **Yes** | doctor check 1, prose |
| Are the pinned dependencies vendored at the right versions? | **Yes** | doctor checks 3-5, prose |
| Can this machine bootstrap without egress? | **Yes** | doctor check 6, prose |
| Which rules will actually fire here? | **Yes** | doctor check 9, prose |
| **Are diagnostics actually being produced?** | **No** | check 11 needs a session daemon |
| **Did the health check prove anything at all, or just fail to fail?** | **No** | exit code cannot distinguish |
| Does a given tree have findings, machine-readably? | **Yes** | `lsp-scan.ps1` SARIF + `-FailOn` |

---

## 4. Candidate slices -- at most three, each with its price

None is chartered. Effort estimates are session-hours for a single implementer working to this
project's normal gate (tests plus a RED control per check).

### S1 -- `doctor.ps1 -Json`: a machine-readable rendering over the existing seam

- **Exact gap it closes.** The doctor's per-check verdicts exist only as prose, so a CI job or a
  support bundle cannot consume them structurally. Closes the second gap in section 2 and makes
  the first one *measurable* by anything downstream.
- **Mechanism.** A third rendering beside `Format-DoctorReport` and `Format-DoctorSummary`,
  emitting the `$doctorResults` objects that already exist -- `{status, component, detail,
  remediation}` per check, plus the existing `version:` header and the summary counts. **The
  precedent is shipped:** `-Summary` is already exactly this shape of change, and its own comment
  records the invariant to preserve -- the rendering never changes the verdict or the exit code.
- **Effort.** Small: ~2-4 hours. No new check, no new state, no I/O the script does not already do.
- **CONTRACT.md freeze exposure: ZERO, and here is why.** Tier 1 freezes exactly two enumerable
  surfaces -- the **userConfig knob names** (drift-guarded to `.claude-plugin/plugin.json`) and the
  **diagnostics status token set** (drift-guarded to `Get-DiagnosticsStatusBanner` /
  `Resolve-AnalysisStatus`). A doctor output rendering is **neither**. It adds no userConfig key --
  it is a CLI switch, the same category as `lsp-scan.ps1`'s `-Format`, which `CONTRACT.md` already
  calls "a CLI parameter, deliberately NOT a userConfig knob" -- and it emits no diagnostics status
  token. The doctor's own `pass`/`fail`/`unknown` vocabulary is a *separate* enum pinned by
  `New-DoctorResult`'s `ValidateSet` and is not part of the frozen taxonomy.
- **Test shape.** Assert `-Json` and the text render agree check-for-check on status and component
  (same seam, so disagreement is a real bug); assert the exit code is byte-identical across all
  three renderings for the same inputs. **RED control:** force one check to `fail` in a fixture and
  prove the JSON status changes *and* the exit code moves to 1 -- a renderer that hardcodes
  statuses would pass a naive shape test and fail this one.

### S2 -- `-RequireProven`: let an operator gate on proof rather than on absence-of-failure

- **Exact gap it closes.** The first gap in section 2, directly: makes "everything was actually
  established" expressible as an exit code.
- **Mechanism.** An opt-in switch that exits non-zero when any check is UNKNOWN. **Opt-in is
  load-bearing, not timidity:** changing the *default* exit-code meaning would break every existing
  caller and is a breaking change under the 1.x policy.
- **Effort.** Very small: ~1 hour. It is a second predicate beside the existing `$doctorFailures`
  line.
- **CONTRACT.md freeze exposure: ZERO** by the same reasoning as S1 -- no knob, no status token.
  Worth stating explicitly that exit-code *semantics* are not enumerated in Tier 1 either; what
  protects existing callers here is the opt-in, not the contract.
- **Test shape.** A fixture with one UNKNOWN and zero FAIL exits 0 without the switch and non-zero
  with it. **RED control:** the same fixture with every check PASS must exit 0 *with* the switch --
  otherwise the switch is just "always fail".

### S3 -- make the end-to-end diagnostic check runnable outside a Claude Code session

- **Exact gap it closes.** The capability gap rather than the reporting gap: check 11 is the only
  one that proves diagnostics genuinely work, and it is unavailable in precisely the environments
  the North Star names.
- **Mechanism.** Let the doctor stand up a short-lived daemon of its own when no session daemon is
  discoverable, run the synthetic-defect round trip against it, and tear it down.
- **Effort.** Large and uncertain: ~1-2 days, and it is the only slice here that is **not**
  report-only -- it would have the doctor *start something*, which contradicts the property every
  command surface currently advertises in its own text.
- **CONTRACT.md freeze exposure: ZERO on the enumerated surfaces**, but it changes a **documented
  behavioural promise** ("report-only: it never ... starts, restarts, or stops anything") that
  appears in `commands/doctor.md`, `commands/status.md` and the doctor's own banner. That is a Tier
  2 / aspirational surface, so it is not semver-guarded -- which makes it *easier* to change and
  *more* important to rule on deliberately rather than by implementation.
- **Test shape.** Prove the ephemeral daemon is torn down on every path including failure and
  interrupt; prove a pre-existing session daemon is preferred and never disturbed. **RED control:**
  a fixture where teardown is skipped must fail the test.

---

## 5. Recommendation -- ONE

**Build S1.** Reasons, in order:

1. **It has zero freeze exposure and a shipped precedent.** `-Summary` already proved a second
   rendering over the `Invoke-Doctor` seam is cheap and safe, and its comment already states the
   invariant that makes it safe.
2. **It is the enabling slice.** S2 is more directly aimed at the headline gap, but an exit code is
   one bit. S1 gives the operator the whole verdict set, which serves CI gating, support bundles
   and the "which check is UNKNOWN and why" question at once -- and it makes S2 a trivial follow-on
   rather than a substitute.
3. **It closes the asymmetry that makes this project's own story inconsistent.** `lsp-scan.ps1`
   emits SARIF by default. The surface whose entire purpose is proving the plugin works is the one
   a machine cannot read. For a project whose pitch is that every claim it makes is checkable, that
   is the odd one out.

**S2 is the recommended immediate follow-on** and is roughly an hour on top of S1. **S3 is not
recommended now**: it is the only slice that would make a report-only surface start a process, and
that promise is stated in three shipped places. If the capability is wanted, it deserves its own
charter and its own ruling, not a rider on a reporting change.

**If none is built, the honest consequence is:** the doctor stays a good human report and a poor
machine witness, and "prove it is working" in CI or a container remains something an operator does
by reading, not by asserting.

---

## 6. What this docket deliberately did not do

- **No build.** No script, test, workflow or manifest was touched.
- **No re-litigation of DX-AUDIT.** D1-D4 and O1-O4 are closed; T1-T3 are accepted. Section 0 says
  why the question here is a different one.
- **No new check was proposed.** Every slice above renders, gates on, or relocates information the
  doctor already computes. Adding a *check* is a separate question.
- **No ruling.** Section 5 recommends. It does not choose.
