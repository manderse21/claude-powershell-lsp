# powershell-lsp -- threat model and least-privilege statement

**What this document is.** The Roadmap II consolidation of a trust posture that is already shipped
and already true, but scattered across four documents and the code. It walks the plugin's trust
boundaries, states what crosses each one, and names the threats the evidence supports. It is
**derived from disk**, not restated from the documents it consolidates.

**What this document does not do.** It **proposes no fix, no mitigation, and no roadmap item.**
Where a boundary has no mitigation, that is recorded as an `OPEN` finding and routed to the gate
review unchanged. A threat model that repairs what it finds stops being a description of the
system and becomes a description of the author's intentions.

**How to read a claim here.** Every trust claim carries a `path` citation, and a `path:line`
citation where the line is load-bearing. A claim that cannot be traced to disk is labelled
**OPEN** (a real gap, evidenced) or **unknown** (not measured -- and *unknown is not zero*). There
are no uncited assertions. Where a figure or a quote comes from another document rather than from
code, that document is named as the source and is **linked, never copied**.

**Consolidation by reference.** [`TRUST.md`](../../TRUST.md) (security and trust posture, including
the paste-ready AppLocker and WDAC allow-listing policy), [`SECURITY.md`](../../SECURITY.md)
(vulnerability reporting and scope), and [`docs/trust.md`](../trust.md) (the release-provenance
chain) are the authorities for their own subjects. This model links to them and duplicates none of
them. In particular the **allow-listing policy is not reproduced here**: it is paste-ready content a
reader must copy exactly, so it lives in one place --
[TRUST.md, "Allow-listing on managed Windows"](../../TRUST.md#allow-listing-on-managed-windows).
Where those documents disagree with each other or with the code, the disagreement is recorded in
section 7 as a finding.

**Derivation moment.** All facts derived 2026-08-12 from the plugin repository at `origin/main`
(`c0e4b51`), plugin version `1.31.0` (`.claude-plugin/plugin.json:5`).

---

## 1. Asset inventory, derived from disk

### 1.1 What it downloads

Two third-party components, both on first run only.

| Component | Pin | Pin declared at | Integrity gate |
|---|---|---|---|
| PowerShell Editor Services | `v4.6.0` | `scripts/ensure-pses.ps1:11` | SHA-256 `scripts/ensure-pses.ps1:17`, enforced `:69-74` |
| PSScriptAnalyzer | `1.25.0` | `scripts/ensure-pssa.ps1:21` | SHA-256 `scripts/ensure-pssa.ps1:26`, enforced `:168-180` |

Both gates call the same predicate, `Test-PinnedFileHash` (`scripts/lib/lsp-common.ps1:100-113`),
which returns `$true` **only** on an exact SHA-256 match and `$false` on every other outcome --
blank pin, unreadable file, uncomputable hash, genuine mismatch (`:101-106`). The caller fails
closed on `$false`, so an unreadable artifact cannot be mistaken for a verified one.

Transport is forced to TLS 1.2 before each fetch (`scripts/ensure-pses.ps1:59`,
`scripts/ensure-pssa.ps1:118`).

Both acquisitions are marker-gated and therefore run **once**: `scripts/ensure-pses.ps1:26,31-33`
returns early when the version marker and the start script are both present;
`scripts/ensure-pssa.ps1:62` is the equivalent PSScriptAnalyzer marker.

**One acquisition path is not hash-pinned.** `scripts/ensure-pssa.ps1:221-245` is a `Save-Module`
fallback, reached only when the verified `.nupkg` path could not *complete* (network or expand
failure) -- never on a hash mismatch, which exits before it (`:175-179`). The fallback rests on the
PowerShell Gallery's own publisher and catalog integrity, not on the pin. This is stated honestly in
[TRUST.md, "What it downloads"](../../TRUST.md#what-it-downloads-pinned-versions-and-pinned-hashes)
and is not drift; it is carried into section 3 as threat **T1.2** because it is a second, weaker
trust path into the same asset.

**An optional cache sits in front of the download.** When `POWERSHELL_LSP_PSSA_CACHE` names a
directory, the pinned `.nupkg` is restored from it (`scripts/ensure-pssa.ps1:49-53,128-139`). The
restored bytes pass through the identical `Test-PinnedFileHash` gate before use (`:163-180`), and
the cached filename embeds both the version and the SHA-256 (`:52`), so a pin bump is a guaranteed
miss rather than a stale draw. Only verified bytes are written back (`:182-197`).

### 1.2 What it executes, and when

**Four entry points are declared in the manifest**, each launched by Claude Code with
`-NoProfile -ExecutionPolicy Bypass`:

| Trigger | Declared at | Launches |
|---|---|---|
| `lspServers` | `.claude-plugin/plugin.json:140` | `scripts/pses-serve-shim.ps1` |
| `SessionStart` | `.claude-plugin/plugin.json:162` | `scripts/session-start.ps1` |
| `PostToolUse` (matcher `Write\|Edit\|MultiEdit`) | `.claude-plugin/plugin.json:169,173` | `scripts/lsp-client.ps1` |
| `SessionEnd` | `.claude-plugin/plugin.json:183` | `scripts/session-end.ps1` |

This confirms the count and the four line numbers recorded in
[TRUST.md, "Why ExecutionPolicy Bypass appears in every hook entry point"](../../TRUST.md#why-executionpolicy-bypass-appears-in-every-hook-entry-point).
The rationale for the flag belongs to that section and is not restated here.

**Three further entry points exist as slash commands**, and they are launched differently:
`commands/doctor.md`, `commands/status.md`, and `commands/scan.md` each declare
`allowed-tools: Bash(pwsh:*)` and invoke `pwsh -NoLogo -NoProfile -File ...` with **no
`-ExecutionPolicy Bypass`**. The asymmetry is more restrictive, not less, but it means the command
surface is blocked on a host whose ExecutionPolicy is `Restricted` or `AllSigned` where the hook
surface is not. Recorded as finding **D3** in section 7 for precision, not as a weakness.

**Process chain and privilege.** `SessionStart` runs the two bootstrap scripts as child processes
(`scripts/session-start.ps1:208-210`). The per-session daemon is launched detached by
`Start-PsesDaemonDetached` (`scripts/lib/lsp-common.ps1:1135-1204`) via `Start-Process` with
`-WindowStyle Hidden` on Windows (`:1191`) and explicit stream redirection elsewhere (`:1200-1203`).
That `Start-Process` call carries **no `-Credential` and no `-Verb RunAs`**, so the daemon inherits
the launching user's token. The daemon in turn starts one PowerShell Editor Services child, which
hosts PSScriptAnalyzer in-process.

**No elevation and no policy mutation exist anywhere in the runtime tree.** A scan of `scripts/` and
`hooks/` for `RunAs`, `-Verb Runas`, `requireAdministrator`, and `Set-ExecutionPolicy` returns
exactly one hit: a comment in `scripts/lib/security-classifier.ps1:29` stating that the classifier
performs none of them. This independently confirms the claim at
[TRUST.md](../../TRUST.md#why-executionpolicy-bypass-appears-in-every-hook-entry-point) that no
`Set-ExecutionPolicy` call exists in the tree.

### 1.3 What it reads

| Input | Read at | Trust status of the source |
|---|---|---|
| Hook payload JSON on stdin (`session_id`, `tool_input.file_path`, `cwd`) | `scripts/lsp-client.ps1:243,245,248-249,255` | Claude Code |
| The edited source file | analyzed by PSES/PSScriptAnalyzer; re-read for capture at `scripts/lib/lsp-common.ps1:869` | **untrusted repository content** |
| Repo-local `PSScriptAnalyzerSettings.psd1` | resolved by `Resolve-PssaSettingsPath` (`scripts/lib/lsp-common.ps1:500-568`); the path is handed to PSES, **not read by the plugin** (`:527-528`) | **untrusted repository content** |
| Org policy `.psd1` | `scripts/lsp-client.ps1:81` -> `Import-OrgPolicyExcludes` (`scripts/lib/lsp-common.ps1:585-649`) | site-managed share |
| Module manifests for module awareness | `scripts/lib/lsp-common.ps1:2799,2850,2879` | **untrusted repository content** |
| Machine security-control state | `scripts/lib/security-classifier.ps1:269-335` | local machine |

**Settings precedence** (`scripts/lib/lsp-common.ps1:501-510`): explicit absolute override >
nearest `PSScriptAnalyzerSettings.psd1` walked up from the edited file and **bounded at the project
root** (`:553`) > the shipped base ruleset when `ruleset = base` > PSES's own default. A relative
override is ignored rather than resolved (`:529-533`). A file living outside the project root is
never walked upward past its own directory (`:556-561`).

**Org policy is the outermost layer and is subtractive only** (`scripts/lib/lsp-common.ps1:570-578`):
its `ExcludeRules` are enforced client-side as a final drop over surfaced findings, after every
local include, so a repo-local settings file cannot re-enable what the org excluded; its
`IncludeRules` stay advisory. The include/exclude asymmetry is recorded there as the design.

**Untrusted `.psd1` input is parsed data-only.** `Import-OrgPolicyExcludes` uses
`Import-PowerShellDataFile` (`scripts/lib/lsp-common.ps1:627`), which evaluates in PowerShell's
restricted language mode -- data only, no command invocation, no expressions -- and the rationale
for reading *this* file directly where the settings path deliberately is not read is stated at
`:598-604`.

### 1.4 What it writes

| Artifact | Location | Written at | Gate |
|---|---|---|---|
| Bootstrap and daemon logs | the data root, `logs/` | `scripts/lib/lsp-common.ps1:66` | always |
| Vendored PSES bundle and PSScriptAnalyzer | the data root | `scripts/ensure-pses.ps1:110`, `scripts/ensure-pssa.ps1:206-212` | first run |
| Per-session state files | the data root, session dir | `scripts/pses-daemon.ps1:1431` | always |
| Diagnostics capture (`dogfood/diagnostics.jsonl`) | **`CLAUDE_PLUGIN_ROOT`**, not the data root | `scripts/lib/lsp-common.ps1:771-794`, appended `:895-897` | **ungated** |
| Timing telemetry (`logs/stats.jsonl`) | the data root, `logs/` | gated by `enableStats` (`scripts/lsp-client.ps1:40`) | opt-in, default off |
| **The user's own source file** | in place | `scripts/pses-daemon.ps1:1403`, via `Write-FormatResultAtomic` (`scripts/lib/lsp-common.ps1:3801`) | `formatOnEdit = apply`, default `off` |
| PowerShell repository registration | user profile, **outside the data root** | `scripts/ensure-pssa.ps1:233-237` | fallback path only, and only when PSGallery is absent |
| Temp staging | system temp | `scripts/ensure-pssa.ps1:119`, cleaned `:213` | first run |

**The data root itself has a silent fallback.** `Get-PluginDataRoot`
(`scripts/lib/lsp-common.ps1:11-20`) substitutes a `powershell-lsp-data` subdirectory of the system temp path when
`CLAUDE_PLUGIN_DATA` is unset. The permissions of that fallback directory are platform-dependent and
were **not measured** -- recorded as **unknown**, and carried as **T6.2**. The project already
treats this fallback as a legibility hazard and ships a provenance-carrying variant,
`Get-PluginDataRootResolution` (`:22-50`), which distinguishes the real root from the substitution.

**The diagnostics capture is the highest-value asset the plugin creates.** Each surfaced diagnostic
appends one JSONL record containing `ts, file, line, col, ruleId, source, severity, message,
snippet, hash, verdict` (`scripts/lib/lsp-common.ps1:880-891`), where `file` is the absolute path of
the edited file and `snippet` is **the offending source line, verbatim**
(`:876-878`). It is protected from commit by `.gitignore:7`, which ignores the whole `dogfood/`
directory, and the capture is fail-safe: any failure is swallowed and nothing reaches stdout
(`:851-853`, `:898`).

Two properties of that capture are carried into section 3. It is written under the **plugin root**,
not the data root (`:794`), which contradicts a claim made in two places -- see finding **D1**. And
it is **not gated by any knob**: the three call sites (`scripts/lsp-client.ps1:412,418,802`) are
unconditional.

**The stats log records absolute paths and is known to need redaction.** `scripts/lib/lsp-common.ps1:238-239`
records the ruling that `enableStats` stays `false` in every profile precisely because
`logs/stats.jsonl` records absolute paths today and redaction must land before any flip. The knob is
default-off (`docs/configuration.md`, `enableStats`), so this is a latent property of an opt-in
surface, not a live exposure.

**Writing the user's file is doubly opt-in by design.** `scripts/lib/lsp-common.ps1:240-241` records
that `formatOnEdit=apply` appears in no profile because it is the one mode that writes a user's
file. The write itself is guarded: a compare-and-swap against the SHA-256 the formatter consumed,
then `[IO.File]::Replace` (`scripts/lib/lsp-common.ps1:3801-3812`), which is atomic on NTFS,
**preserves the destination's ACLs and attributes**, and either fully replaces or leaves the
original intact. A concurrent modification always wins (`:3806-3807`). UTF-16 files and mixed-EOL
files abort rather than write (`scripts/pses-daemon.ps1:1395-1399`).

### 1.5 Network surface -- the recorded search

The dispatch asks whether any network surface exists beyond the pinned bootstrap download, and asks
that the search establishing the answer be recorded either way. Two searches were run over the
runtime surface (`scripts/`, `hooks/`, `commands/`, `rulesets/`, `.claude-plugin/`) for
`Invoke-WebRequest`, `Invoke-RestMethod`, `Start-BitsTransfer`, `System.Net.WebClient`,
`System.Net.Http`, `Net.Sockets`, `Save-Module`, `Install-Module`, `Find-Module`, `Update-Module`,
`Register-PSRepository`, `Publish-Module`, `Send-MailMessage`, `New-WebServiceProxy`,
`Test-NetConnection`, `Test-Connection`, and `Resolve-DnsName`.

**The answer is: yes, there is one network path outside the bootstrap.** Four call sites exist, in
three files:

| # | Site | Path | Reached when |
|---|---|---|---|
| 1 | `scripts/ensure-pses.ps1:60` | `Invoke-WebRequest` to `github.com` | first run only (marker-gated) |
| 2 | `scripts/ensure-pssa.ps1:151` | `Invoke-WebRequest` to `www.powershellgallery.com` | first run only, cache miss only |
| 3 | `scripts/ensure-pssa.ps1:235,239` | `Register-PSRepository` + `Save-Module` to PSGallery | first run, primary path failed |
| 4 | `scripts/doctor.ps1:777` | `System.Net.Sockets.TcpClient` connect, port 443 | **every** doctor or status run |

Site 4 is doctor check 5 (`scripts/doctor.ps1:1389-1400`): it extracts hostnames from the two
bootstrap scripts' URL literals (`Get-DoctorHostsFromScript`, `:737-751`) and TCP-connects to each
with a 3-second timeout (`Test-DoctorHostReachableProbe`, `:770-790`). It is **not** behind a flag
-- `-ProbeNativeServe` gates check 7, not this one -- so it runs on every `/powershell-lsp:doctor`
and every `/powershell-lsp:status` (`commands/status.md`), regardless of bootstrap state. It opens
no listener and sends no payload: it connects, observes reachability, and closes (`:781-788`).

**The per-edit path is provably network-free.** The same search restricted to the eight files that
constitute the PostToolUse, daemon, and serve chain -- `scripts/lsp-client.ps1`,
`scripts/pses-daemon.ps1`, `scripts/pses-stdio.ps1`, `scripts/pses-serve-shim.ps1`,
`scripts/session-end.ps1`, `scripts/lib/lsp-common.ps1`, `scripts/lib/security-classifier.ps1`,
`scripts/lib/lsp-scan-common.ps1` -- returns **zero matches** (grep exit 1). Editing makes no
network call.

**A note on false positives, so the search can be replayed honestly.** The unrestricted search also
returns `Find-ModuleAwareness`, `Find-ModuleManifest`, and `Update-ModuleSurfaceCache` (local
function names sharing a prefix with `Find-Module` / `Update-Module`) and
`scripts/lib/lsp-common.ps1:2423` (a *message string* advising the user to run `Install-Module`).
None is a network call. A replay that counts raw hits without this discrimination will overcount.

Finding **D2** in section 7 records what site 4 means for a claim in `TRUST.md`.

---

## 2. Trust boundaries

| ID | Boundary | Crosses it |
|---|---|---|
| **B1** | Upstream artifact -> local disk | The two pinned downloads |
| **B2** | Plugin tree -> executing process | Plugin scripts, under Bypass at four entry points |
| **B3** | Repository content -> analyzer | Edited source, repo-local settings, module manifests |
| **B4** | Site policy -> enforcement layer | The `orgPolicy` `.psd1` |
| **B5** | Client -> daemon | The per-session named pipe |
| **B6** | Runtime -> data at rest | Capture log, stats log, daemon logs, session files |
| **B7** | Release pipeline -> consumer | Tags, source archive, SBOM, provenance |

---

## 3. Threats, walked boundary by boundary

Each threat carries its existing mitigation with a citation, or an honest **OPEN** with no proposed
fix.

### B1 -- upstream artifact to local disk

**T1.1 Tampered bundle (MITM, poisoned mirror, truncation).** *Mitigated.* Both artifacts are
verified against a pinned SHA-256 after download and before use, and a mismatch fails closed:
`scripts/ensure-pses.ps1:69-74` and `scripts/ensure-pssa.ps1:168-180`. The PSES path additionally
stages and verifies in a temp area and only then swaps, so a failed re-bootstrap leaves the prior
working bundle intact (`scripts/ensure-pses.ps1:52-57,94-122`).

**T1.2 Acquisition via the unpinned fallback.** *Partially mitigated; the residual is documented.*
`Save-Module` (`scripts/ensure-pssa.ps1:239`) pins the *version* but not the *bytes*; integrity
rests on the Gallery's publisher and catalog controls. It is unreachable on a hash mismatch
(`:175-179`), so it cannot be used to launder a detected tamper -- only to acquire when the verified
path could not complete.

**T1.3 Poisoned `.nupkg` cache.** *Mitigated.* A cache hit is re-verified through the identical gate
before use (`scripts/ensure-pssa.ps1:163-180`), and the cache filename binds to both the version and
the hash (`:52`), so a stale entry cannot be drawn after a pin bump.

**T1.4 Repository registration side effect.** **OPEN.** On the fallback path, when PSGallery is not
registered, the plugin calls `Register-PSRepository -Default` and sets the repository's
`InstallationPolicy` to `Trusted` (`scripts/ensure-pssa.ps1:233-237`). That is a write to the user's
PowerShell profile state, **outside `CLAUDE_PLUGIN_DATA`**, and it persists after the plugin is
removed. It is narrowly gated (fallback only, absent-repository only) and its stated purpose is to
stop a non-interactive `Save-Module` stalling on a trust prompt (`:230`). No fix is proposed here.

**T1.5 First-run downgrade by denial.** **OPEN.** An adversary who can block only the primary
`.nupkg` fetch -- without corrupting it -- steers acquisition onto the weaker T1.2 path. The bounded
retry (`scripts/ensure-pssa.ps1:141-161`) raises the cost but does not remove the reachability. No
fix is proposed here.

### B2 -- plugin tree to executing process

**T2.1 Modified plugin script executes under Bypass.** *Mitigated by scope, not by signature.* The
Bypass flag applies to one `pwsh` process, sets no policy and writes no registry key, and every
invocation targets a named script under `${CLAUDE_PLUGIN_ROOT}/scripts/` -- reasoning and the three bounding
properties are at
[TRUST.md](../../TRUST.md#why-executionpolicy-bypass-appears-in-every-hook-entry-point). The scripts
are deliberately not Authenticode-signed, and the answer for an estate that requires signed code is
the allow-listing policy in
[TRUST.md, "Allow-listing on managed Windows"](../../TRUST.md#allow-listing-on-managed-windows) --
referenced, not reproduced.

**T2.2 Machine-level control cannot be overridden by the plugin.** *Structurally true.* A
command-line `-Bypass` is ignored when ExecutionPolicy is set by `MachinePolicy` or `UserPolicy`,
and Constrained Language Mode, WDAC, Defender ASR, and Smart App Control do not consult the flag at
all. The tree contains no elevation and no `Set-ExecutionPolicy` (section 1.2). The one
control-aware component exists to *explain* blocks: `scripts/lib/security-classifier.ps1:28-31`
states the fence -- it never bypasses, disables, weakens, or auto-modifies any control, and every
remediation is instructions rather than an action.

**T2.3 Plugin tree writability.** **OPEN.** The plugin root is documented as a read-only tree
(`scripts/lib/lsp-common.ps1:13`), but the capture log is written into it
(`scripts/lib/lsp-common.ps1:794`). A tree that is written at runtime cannot also be assumed
immutable by a reviewer allow-listing it by path. See finding **D1**.

### B3 -- repository content to analyzer

**T3.1 Malicious source reaching the analyzer.** *Mitigated by construction.* PSScriptAnalyzer and
the parser pre-pass **parse** the edited file; the plugin never invokes it. The edit path is also
network-free (section 1.5), so analysis of hostile code has no outbound channel.

**T3.2 Hostile repo-local `PSScriptAnalyzerSettings.psd1`.** **OPEN.** `Resolve-PssaSettingsPath`
deliberately resolves the path and does not read the file (`scripts/lib/lsp-common.ps1:527-528`);
the file is handed to PowerShell Editor Services to consume as full settings. What that upstream
consumer does with a hostile settings file was **not derived** and is **unknown** here -- it is
upstream behavior, and `SECURITY.md` places flaws *inside* PSES and PSScriptAnalyzer out of scope
while keeping *how this plugin invokes them* in scope. The plugin-side bounds that do exist are
real: the walk-up stops at the project root (`:553`) and never ascends past the directory of an
out-of-workspace file (`:556-561`), so the settings file honored is one already inside the tree the
user opened. No fix is proposed here.

**T3.3 Hostile module manifest.** *Mitigated.* Manifests are read with `Import-PowerShellDataFile`
(`scripts/lib/lsp-common.ps1:2799,2850,2879`), the restricted-language data-only parser. This path
is reached only when `moduleAwareness = suggest`, which is default `off`
(`docs/configuration.md`, `moduleAwareness`).

**T3.4 Analyzer output is written back into the user's file.** *Mitigated, and doubly opt-in.* Only
`formatOnEdit = apply` writes; default is `off` and the mode appears in no profile
(`scripts/lib/lsp-common.ps1:240-241`). The write is compare-and-swap guarded and atomic, preserves
destination ACLs, and aborts rather than tearing (`scripts/lib/lsp-common.ps1:3801-3812`;
`scripts/pses-daemon.ps1:1395-1410`).

### B4 -- site policy to enforcement layer

**T4.1 Tampered or substituted org policy.** **OPEN.** The policy file is read from an absolute path
with no integrity check -- no hash, no signature, no ACL assertion
(`scripts/lib/lsp-common.ps1:619-641`). Anyone who can write the file can alter which findings the
organization suppresses. The absolute-path requirement (`:620-621`) removes the
resolve-against-current-directory hijack, and restricted-mode parsing (`:627`) removes code
execution, but the *contents* are trusted as delivered. No fix is proposed here.

**T4.2 Silent non-enforcement.** *Mitigated to a warning, and fail-open by design.* Every degrade --
relative path, missing file, unreadable file, unparseable data -- yields `@()`, meaning no
exclusions, and sets a single human-readable warning that the client logs
(`scripts/lib/lsp-common.ps1:591-596,647`; `scripts/lsp-client.ps1:81-84`). The fail-open direction
is the stated invariant: an unreadable policy must never break the user's edit. The security
consequence is the flip side and is recorded plainly -- **an adversary who merely makes the policy
unreachable disables the exclusions**, and the only signal is a log line. `scripts/doctor.ps1:486-561`
surfaces the same condition as a doctor check.

**T4.3 Policy cannot compel, only subtract.** *By design, and load-bearing.* Org `IncludeRules` are
advisory; only `ExcludeRules` are enforced (`scripts/lib/lsp-common.ps1:570-578`). An organization
cannot force a rule on through this layer. Recorded so a reviewer does not read `orgPolicy` as a
mandatory-control mechanism.

**T4.4 Exclusion is post-analysis, not pre-analysis.** *Recorded.* Filtering happens client-side over
already-computed findings (`scripts/lsp-client.ps1:369,561`). Excluded findings are computed before
they are dropped, so an org exclusion suppresses *surfacing*, not *analysis*.

### B5 -- client to daemon

**T5.1 Local access to the diagnostics pipe.** **unknown.** The daemon creates
`NamedPipeServerStream` with name `powershell-lsp-` suffixed with the session id
(`scripts/pses-daemon.ps1:1436,1451-1453`). The constructor overload used takes no `PipeSecurity`
argument, and `PipeOptions.CurrentUserOnly` is not passed. The effective DACL therefore falls to the
platform default, **which was not measured** -- so the set of local principals that can connect is
recorded as unknown, not as zero. Two bounds are on disk: `maxNumberOfServerInstances` is `1`
(`:1452`), so only one client is connected at a time, and the pipe name is keyed to the session id.
No fix is proposed here.

**T5.2 What an attacker on the pipe would obtain.** *Scoped by the protocol.* The request surface is
one-line JSON with `action` of `diagnostics`, `format`, or `ping` (`scripts/lsp-client.ps1:126,166`;
`scripts/doctor.ps1:813`). A `diagnostics` request names an arbitrary file path and returns findings
for it; a `format` request with apply can write it (T3.4, gated). This is the reason T5.1 is
recorded as unknown rather than dismissed.

**T5.3 No listening socket.** *Confirmed.* The only outbound socket use in the tree is the doctor's
TCP *client* probe (section 1.5); no `TcpListener` or bind exists. `TRUST.md`'s "No network service"
claim is accurate.

### B6 -- runtime to data at rest

**T6.1 Capture log discloses source code.** *Recorded; local-only and gitignored, but ungated.* The
log stores absolute paths and verbatim offending source lines
(`scripts/lib/lsp-common.ps1:876-891`). It never leaves the machine -- the edit path has no network
(section 1.5) -- and `.gitignore:7` prevents commit. But it is written **unconditionally**
(`scripts/lsp-client.ps1:412,418,802`), so a user who has enabled no data-collection knob is still
accumulating snippets of every file with a finding. The relevant knob, `enableStats`, gates a
*different* log.

**T6.2 Data-root fallback permissions.** **unknown.** When `CLAUDE_PLUGIN_DATA` is unset, logs and
session files land under a `powershell-lsp-data` subdirectory of the system temp path (`scripts/lib/lsp-common.ps1:17`). The
permissions of that directory are platform-dependent and were not measured.

**T6.3 Stats log absolute paths.** *Latent, opt-in, and already ruled on.* `logs/stats.jsonl`
records absolute paths; the project's recorded ruling keeps `enableStats` false in every profile
until redaction ships (`scripts/lib/lsp-common.ps1:238-239`).

**T6.4 Log retention.** *Bounded.* SessionStart sweeps each rolling log family down to `keepLastN`
newest files, default 10 (`scripts/session-start.ps1:6,57,116`;
`.claude-plugin/plugin.json:124`). The capture log is a single appended file, not a rolling family,
so the sweep does not bound it -- recorded as an observation, with no fix proposed.

### B7 -- release pipeline to consumer

**T7.1 Tampered release artifact.** *Mitigated.* Signed tags, SLSA build provenance over the source
archive and SBOM, and a CycloneDX SBOM generated from the real pins. This chain is
[`docs/trust.md`](../trust.md)'s subject and
[TRUST.md, "Supply-chain artifacts"](../../TRUST.md#supply-chain-artifacts-sbom--build-provenance)'s;
it is linked, not restated.

**T7.2 The install path is not the signed path.** *Recorded upstream, not here.* Claude Code installs
by git clone, so neither the tag signature nor the archive provenance attests that path directly;
integrity rests on the signed tag and the commit it names. Both
[TRUST.md, "Signing posture"](../../TRUST.md#signing-posture) and
[SECURITY.md](../../SECURITY.md#verifying-release-integrity) state this boundary.

**T7.3 Build-time privilege.** *Least-privilege, confirmed from disk.* Workflow-level permissions are
`contents: read` in all three workflows (`.github/workflows/powershell-lsp-ci.yml:17-18`,
`powershell-lsp-code-scanning.yml:44-45`, `powershell-lsp-release.yml:61-62`). Elevated grants are
job-scoped and enumerated: `security-events: write` for the SARIF upload, annotated in the file as
the single highest-privilege action in the repository (`powershell-lsp-code-scanning.yml:51-55`),
and `contents: write` + `actions: read` + `id-token: write` + `attestations: write` for the release
job, each with an inline reason (`powershell-lsp-release.yml:73-77`). The SARIF upload action is
pinned by full commit SHA rather than a movable tag
(`powershell-lsp-code-scanning.yml:131`), which matches the SHA recorded in
[`docs/trust.md`](../trust.md) item 7 exactly.

---

## 4. The 000036 boundary -- a designed decision, not a gap

`scripts/doctor.ps1` deliberately does **not** detect or diagnose security-control blocks. Its own
header states the fence (`scripts/doctor.ps1:19-25`): the doctor does not diagnose WDAC, App
Control, AppLocker, ExecutionPolicy, Smart App Control, or Constrained Language Mode; for an
indeterminate failure it emits a single generic pointer; there is zero control-specific probing.
`scripts/doctor.ps1:1481` marks the pointer site itself.

A reviewer reading only the doctor could mistake this for a missing capability. It is not. The
project ruled on it, and the ruling is **declined-final** (dispatch 000220), recorded at
[`docs/decision-ledger.md:2199-2233`](../decision-ledger.md) and summarized at
[`ROADMAP.md:78-82`](../../ROADMAP.md). The rationale, as recorded there, turns on *where* a control
gets named rather than on whether naming one is ever right:

1. **The capability ships -- in the other place.** `scripts/lib/security-classifier.ps1` (dispatch
   000038) exists precisely to name the blocking control, on the SessionStart bootstrap-failure
   banner. Its header commits to positive evidence only and states that naming a control without
   that evidence is the same sin as silent failure (`scripts/lib/security-classifier.ps1:22-26`).
   It is invoked from exactly one place, `scripts/session-start.ps1:46`.
2. **A live failure is in hand there, and is not in the doctor.** The banner fires only when
   bootstrap actually failed, so there is something to attribute. The doctor is a static, report-only
   surface that most often runs with nothing blocked, where a named control would be a guess dressed
   as a finding.
3. **The verdict is graded, and the doctor has nowhere to put a grade.** The classifier carries a
   `Confidence` of `confirmed`, `likely`, `possible`, or `none`, and the banner's lead-in switches on
   it. A doctor check's status is a three-token `[ValidateSet('pass','fail','unknown')]` parameter
   (`scripts/doctor.ps1:88`) -- and `unknown`, the only token that could absorb a graded verdict,
   already means *I could not check*, which is a different statement.
4. **Disclosure.** A doctor report is written to be pasted into a bug report or support thread, which
   would make an enumerated read of a machine's security posture a disclosure the user did not ask
   to make.

That fourth strand is itself a threat-model judgement, and it is why this boundary belongs in this
document as a decision rather than as an omission: **the banner does live, evidence-gated, named
diagnosis; the doctor does generic health and points.** Both halves ship. Neither is a gap.

The classifier's own read surface is consistent with that framing: `Get-ExecutionPolicy -List`
(`scripts/lib/security-classifier.ps1:269-280`), the session language mode (`:282-286`), the Smart
App Control registry value (`:288-297`), and CodeIntegrity 3076/3077 and Defender ASR 1121/1122
event records (`:299-322`). Each probe is independently try/caught so a missing log, denied
permission, non-Windows host, or Constrained Language Mode degrades to "no evidence" rather than
throwing (`:17-20`), and the module is constrained-language-safe by construction (`:32-36`). Event
correlation to this plugin is by component-name pattern (`:43-55`).

---

## 5. Least privilege, as it actually is

| Component | Runs as | Needs | Would work with less | Never needs |
|---|---|---|---|---|
| Hook scripts (SessionStart, PostToolUse, SessionEnd) | the user, no elevation (section 1.2) | read the edited file; read/write the data root; connect the session pipe | -- | admin; write to any tree but its own data root and, for the capture log, the plugin root |
| PSES daemon | the user, inherited token (`scripts/lib/lsp-common.ps1:1191,1200`) | create the session pipe; spawn one child; write logs and session files | **unknown** -- whether a tighter pipe DACL would still serve the client was not tested (T5.1) | network: it makes none (section 1.5) |
| PSES + PSScriptAnalyzer child | the user | read the analyzed file and its settings file | -- | network; write access to the analyzed file except under `formatOnEdit = apply` |
| Bootstrap (`ensure-*`) | the user | outbound HTTPS on first run; write the data root | after the marker gate it needs **no network at all** (`scripts/ensure-pses.ps1:31-33`) | admin; a machine-wide module install -- it vendors into the data root |
| Doctor / status | the user | read-only checks | it would work with **no network**: only check 5 uses it | write access anywhere -- it is report-only by design (`scripts/doctor.ps1:7-9`) |
| CI and release workflows | GitHub Actions | see T7.3 | -- | a long-lived signing key: there is none (keyless Sigstore, per [`docs/trust.md`](../trust.md)) |

**What the plugin never asks for, confirmed by absence.** No elevation primitive, no
`Set-ExecutionPolicy`, no listening socket, no telemetry endpoint, and no credential access appears
anywhere in `scripts/` or `hooks/` (searches in sections 1.2 and 1.5).

**Where least privilege is not clean, stated plainly.** Three writes leave the data root: the
capture log into the plugin root (T2.3 / D1), the PowerShell repository registration into the user
profile on the fallback path (T1.4), and temp staging during bootstrap
(`scripts/ensure-pssa.ps1:119`, cleaned at `:213`). The first two are the ones a reviewer
allow-listing by path should know about.

---

## 6. Coverage and limits of this model

- **Upstream internals are out of scope**, matching [`SECURITY.md`](../../SECURITY.md#scope): a flaw
  in how this plugin downloads, verifies, or invokes PSES and PSScriptAnalyzer is in scope; a flaw
  inside them is not. T3.2 is bounded by exactly that line.
- **No dynamic testing was performed.** Every claim here is derived by reading the tree at
  `origin/main`. Nothing was executed, no daemon was started, and no ACL was queried. The two
  `unknown` labels (T5.1, T6.2) are unknown for that reason, and each names the measurement that
  would resolve it.
- **The threat list is bounded by the evidence**, as instructed. Threats that would require
  assumptions about deployment, adversary position, or upstream behavior are labelled unknown rather
  than enumerated speculatively.
- **No third-party security audit exists.** Stated at
  [TRUST.md, "Honest limits"](../../TRUST.md#honest-limits); this document does not change that and
  is not one.

---

## 7. Drift found between the trust documents and the code

The dispatch asks whether `TRUST.md`, `SECURITY.md`, and `docs/trust.md` agree with each other and
with the code everywhere they overlap, and records that any drift is a finding. Four were found.
None is repaired here.

**D1 -- "all state stays under `CLAUDE_PLUGIN_DATA`" is contradicted by the capture log.**
[`TRUST.md`](../../TRUST.md#what-it-executes----and-what-it-does-not) states that all state, logs,
pids, and the vendored analyzer live under `CLAUDE_PLUGIN_DATA` and stay there. The same claim is
made more strongly inside the code: `scripts/lib/lsp-common.ps1:12-13` says state lives under
`CLAUDE_PLUGIN_DATA` and "**Never under CLAUDE_PLUGIN_ROOT (read-only plugin tree)**". But
`Get-DogfoodLogPath` in that same file resolves the capture log under the **plugin root**
(`:775-777,794`), and the capture is unconditional (`scripts/lsp-client.ps1:412,418,802`). The
plugin tree is therefore written at runtime. Severity is meaningful for two audiences: a reviewer
allow-listing the plugin root by path is told it is read-only, and a reader of the data-root claim
will not look in the plugin tree for captured source snippets.

**D2 -- "no network access at all after first-run bootstrap" is broader than the code supports.**
[`TRUST.md`](../../TRUST.md#what-it-executes----and-what-it-does-not) states that the only outbound
network the plugin makes is the one-time download of its two pinned dependencies, and that every
later session is fully offline. `scripts/doctor.ps1:777` makes an outbound TCP connection on every
`/powershell-lsp:doctor` and `/powershell-lsp:status` run, at any time, bootstrapped or not
(section 1.5). The narrower claims in the same document survive intact -- no listener, no telemetry,
no exfiltration, and a network-free *edit* path are all confirmed here -- but the "at all" and "only"
phrasing does not cover the doctor's reachability probe.

**D3 -- "all four of them, and there are no others" is true of the manifest and not of the launch
surface.** [`TRUST.md`](../../TRUST.md#why-executionpolicy-bypass-appears-in-every-hook-entry-point)
scopes the sentence with "Reviewing the manifest", and within that scope it is exact: four
occurrences at `.claude-plugin/plugin.json:140,162,173,183`, verified. Read as a statement about
entry points Claude Code launches, it undercounts: the three slash commands also launch `pwsh`
(section 1.2). They carry no Bypass, so the omission is conservative rather than dangerous, but a
reviewer enumerating launch surfaces from that sentence will find three more.

**D4 -- `SECURITY.md` describes code-signing as "pending" where `TRUST.md` records it as declined,
and points at the wrong section.** [`SECURITY.md:126-127`](../../SECURITY.md) refers the reader to
`TRUST.md` for "the current (**pending -- not signed**) code-signing status", linking to the
`#supply-chain-artifacts-sbom--build-provenance` anchor. Two problems. First, that section
(`TRUST.md:134-156`) covers the SBOM and provenance and says nothing about code-signing status; the
subject lives in `#signing-posture` (`TRUST.md:157-209`). Second, `TRUST.md` does not describe the
status as pending: it records Authenticode as **deliberately not pursued** for a git-distributed
plugin (`TRUST.md:159-162`), the SignPath Foundation path as **declined / adoption-gated**, and
Azure Trusted Signing as not pursued (`TRUST.md:207-209`) -- a decision, not a queue position.
"Pending" tells an evaluator to expect a signature that the project has decided not to seek.

**Checked and found consistent.** The pinned versions and SHA-256 values tabulated in
[TRUST.md](../../TRUST.md#what-it-downloads-pinned-versions-and-pinned-hashes) match
`scripts/ensure-pses.ps1:11,17` and `scripts/ensure-pssa.ps1:21,26` exactly. The four manifest line
numbers match. The `Test-PinnedFileHash` attribution to `scripts/lib/lsp-common.ps1` is correct
(`:100`). The `upload-sarif` commit SHA in [`docs/trust.md`](../trust.md) item 7 matches
`.github/workflows/powershell-lsp-code-scanning.yml:131`. The "no network service" and "no
telemetry" claims are confirmed by the section 1.5 search. `SECURITY.md`'s in-scope list matches the
files that actually implement each named surface.

**A staleness note that is not counted as drift.** [`SECURITY.md`](../../SECURITY.md#verifying-release-integrity)
and [`docs/trust.md`](../trust.md) both use `v1.17.0` in worked examples while the current version is
`1.31.0` (`.claude-plugin/plugin.json:5`). Both are explicitly illustrative -- `SECURITY.md` labels
its sample output "abbreviated and illustrative" -- and the commands generalize, so this is recorded
as an observation rather than a finding.

---

## 8. OPEN findings register

Consolidated for the gate review. Each is stated as observed; none carries a proposed remedy.

| ID | Boundary | Finding | Status |
|---|---|---|---|
| T1.4 | B1 | Fallback path registers PSGallery and sets it Trusted -- a persistent write outside the data root | OPEN |
| T1.5 | B1 | Blocking the primary fetch without corrupting it steers acquisition to the unpinned fallback | OPEN |
| T2.3 | B2 | The plugin tree, documented as read-only, is written at runtime by the capture log | OPEN |
| T3.2 | B3 | Repo-local settings file is handed to PSES unread; upstream handling of a hostile settings file not derived | OPEN / unknown |
| T4.1 | B4 | Org policy file is read with no integrity check -- write access to it is control over enforcement | OPEN |
| T4.2 | B4 | Fail-open by design: making the policy unreachable disables exclusions, signalled only in a log line | OPEN (designed trade-off) |
| T5.1 | B5 | Daemon pipe is created with no explicit `PipeSecurity` and no `CurrentUserOnly`; effective DACL not measured | unknown |
| T6.1 | B6 | Capture log records absolute paths and verbatim source lines, ungated by any knob | OPEN |
| T6.2 | B6 | Data-root temp fallback permissions not measured | unknown |
| T6.4 | B6 | The `keepLastN` sweep does not bound the capture log | OPEN |
| D1-D4 | -- | Documentation drift, section 7 | OPEN |

Two entries are marked **unknown** rather than OPEN because no measurement was taken. Unknown is not
zero: T5.1 and T6.2 each name the measurement that would settle them, and neither should be read as
"no exposure".
