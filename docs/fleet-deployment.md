# Fleet deployment

How an administrator puts this plugin on many machines with a pinned version, configures it
centrally, verifies it landed, and points its telemetry at a collector -- without a dashboard, a
control plane, or platform-specific packaging (dispatch 000299, W3-4; REVIEW-II-DOCKET.md W3-4).

**What this page is not.** No MSI, no WinGet manifest, no hosted control plane, no per-device
enrollment UI. None of those fit a **git-distributed Claude Code marketplace plugin**, and the
roadmap docket declines all of them outright -- see
[REVIEW-II-DOCKET.md, "What the review asked for that this plan declines"](roadmap-ii/REVIEW-II-DOCKET.md).
Every mechanism below is either already shipped and documented elsewhere (this page composes and
points at it, rather than restating it) or is a standard Windows/GitHub administration primitive
this plugin's design happens to compose with. Nothing on this page requires a change to the
plugin to use. See
[REVIEW-II-DOCKET.md, "Declined or not adopted from this review"](roadmap-ii/REVIEW-II-DOCKET.md#declined-or-not-adopted-from-this-review)
for the ruling that MSI/WinGet and a control plane are declined and this page is the fitting slice
in their place.

## 1. Pinning a version through the managed marketplace

The plugin installs today as `owner/repo` -- a git-hosted [Claude Code plugin
marketplace](https://github.com/manderse21/claude-powershell-lsp) (see [README, Quick
start](../README.md#quick-start)):

```text
/plugin marketplace add manderse21/claude-powershell-lsp
/plugin install powershell-lsp@claude-powershell-lsp
/plugin enable powershell-lsp
```

That points a machine at whatever the marketplace's git source currently holds. A fleet that wants
every machine on the **same, chosen** release rather than "whatever is on `main` today" pins by
controlling *which git state* the marketplace add points at, not by a version argument on the
slash command:

1. **Mirror the marketplace at a release tag.** Fork or mirror
   `manderse21/claude-powershell-lsp` into a repository your organization controls, and keep that
   mirror's default branch at a chosen release tag (for example `v1.34.0`) rather than tracking
   upstream `main`. Bump it deliberately, on your own schedule, by fast-forwarding the mirror to a
   later tag after you have reviewed the [CHANGELOG](../CHANGELOG.md) and re-run your own
   validation.
2. **Point the fleet at your mirror**, not at the upstream repository: `/plugin marketplace add
   <your-org>/<your-mirror>`. Every machine that adds *your* marketplace gets the exact commit your
   mirror's default branch holds -- the marketplace source is resolved from git state, so pinning
   the mirror pins every installer downstream of it.
3. **Verify what landed** the same way you would verify any release: the plugin source is an
   independently attested artifact per release (`powershell-lsp-<version>.tar.gz`, verifiable with
   `gh attestation verify`; see [README, Verifying your install and a
   release](../README.md#verifying-your-install-and-a-release)). A mirror that fast-forwards to a
   tag your fleet then installs is verifying the same bytes that attestation covers.

**What this page does not promise.** Claude Code's own enterprise administration surface --
whether it can independently lock which marketplaces or plugin versions a machine is allowed to
install, beyond what a mirrored git source already pins -- is Claude Code's own product surface,
not this plugin's. This page states only what is true of *this plugin's* distribution model (a git
source resolved by the marketplace add), and stops there rather than asserting a Claude Code
administration capability this repository cannot verify.

## 2. Setting `POWERSHELL_LSP_*` via GPO or Intune

Every fleet-facing control this plugin has -- the offline artifact source, the diagnostics capture
mode, managed-mode policy enforcement, the OTLP endpoint -- is an **environment variable**, not a
`userConfig` knob, specifically so it can be set once, machine-wide, by an administrator, rather
than per-user through the `/plugin` config panel. See
[configuration.md](configuration.md#offline-and-air-gapped-installation) for why the split exists
and the full list.

The primitive underneath both delivery mechanisms is the same: a **machine-scope Windows
environment variable**, which configuration.md's own examples already show set directly:

```powershell
[Environment]::SetEnvironmentVariable('POWERSHELL_LSP_POLICY_MODE', 'closed', 'Machine')
```

- **Group Policy** sets this the same way any machine environment variable is deployed: a Group
  Policy Preference (Computer Configuration > Preferences > Windows Settings > Environment) naming
  the variable and value, applied to the OU your fleet lives in.
- **Intune** sets it via a PowerShell script (Devices > Scripts, running as SYSTEM) that calls the
  same `[Environment]::SetEnvironmentVariable(..., 'Machine')` form, or via a Settings
  Catalog / Win32 app deployment that writes the same machine environment block.

Either path lands the identical registry state
(`HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment`); which tool pushes it is a
fleet-management choice this plugin has no opinion about. **A machine that receives none of these
behaves exactly as it does today** -- every variable's default preserves current behavior (see
each variable's own "Default" in configuration.md).

The variables worth setting fleet-wide, and what each does:

| Variable | Purpose | Reference |
|---|---|---|
| `POWERSHELL_LSP_ARTIFACT_MIRROR_BASE` / `POWERSHELL_LSP_ARTIFACT_BUNDLE_DIR` | Offline/air-gapped bootstrap source | [configuration.md](configuration.md#offline-and-air-gapped-installation) |
| `POWERSHELL_LSP_CAPTURE_MODE` | What the local diagnostics capture log records | [configuration.md](configuration.md#diagnostics-capture-and-what-it-records) |
| `POWERSHELL_LSP_POLICY_MODE` | Fail-open (default) vs. fail-closed enforcement of `orgPolicy` | [configuration.md](configuration.md#managed-mode-fail-closed-policy-enforcement) |
| `POWERSHELL_LSP_OTEL_ENDPOINT` | Where `export-otel.ps1` may POST metrics | [configuration.md](configuration.md#telemetry-export-and-what-leaves-the-host) |

(Windows-specific above, matching how this plugin's own docs express it. On macOS an MDM
configuration profile can set the equivalent in a launch daemon's environment; on Linux, a
configuration-management tool such as Ansible or Puppet writing `/etc/environment` or a
`/etc/profile.d/*.sh` drop-in serves the same role. Neither is exercised by this repository's own
CI, which runs Windows, macOS and Linux legs but does not test fleet-management tooling itself.)

`orgPolicy` -- the userConfig knob `POWERSHELL_LSP_POLICY_MODE` governs -- is different: it IS a
`userConfig` knob (Tier 1, frozen), so it cannot be set by machine environment variable the same
way. It is a per-installation setting resolved through the plugin's own config resolution
(`profile`, then an explicit value); deploying the SAME `orgPolicy` path to a fleet means shipping
the same `profile` or the same explicit configuration to every install, which is a Claude Code
configuration-distribution question, not one this plugin's environment-variable surface answers.

## 3. Placing the airgap bundle

Fully covered in
[configuration.md, "Offline and air-gapped installation"](configuration.md#offline-and-air-gapped-installation):
what `POWERSHELL_LSP_ARTIFACT_BUNDLE_DIR` is, how to verify and stage
`powershell-lsp-airgap-<version>.zip`, and what `/doctor` reports about it (**Artifact source** and
**Offline readiness**). Not restated here -- see that page, and set the resulting `Machine`-scope
variable by whichever of GPO or Intune (section 2 above) your fleet already uses.

One fleet-specific point that page does not need to make: **stage the bundle before the first
session on each machine**, not after. The bundle is read once, at bootstrap; setting the variable
after a machine has already bootstrapped from the network does nothing until a bootstrap re-runs
(a fresh plugin data directory, or a version bump that re-triggers `ensure-pses`/`ensure-pssa`).

## 4. `doctor -Json` and exit codes as a fleet health check

`doctor -Json` (see [preflight-doctor.md](preflight-doctor.md) and
[commands/doctor.md](../commands/doctor.md) for the full envelope and exit-code contract) is
designed for exactly this: a machine-readable health surface with an exit code an RMM tool, a
scheduled task, or a login script can branch on without parsing prose.

```powershell
# Run as a scheduled task, an Intune remediation script, or an RMM custom check.
$json = pwsh -NoLogo -NoProfile -File "$env:CLAUDE_PLUGIN_ROOT\scripts\doctor.ps1" -Json -RequireProven
$exit = $LASTEXITCODE
$report = $json | ConvertFrom-Json

switch ($exit) {
    0 { Write-Output "HEALTHY: $($report.status), plugin $($report.versions.plugin)" }
    2 { Write-Output "UNPROVEN/DEGRADED (nothing failed, something unknown): $($report.status)" }
    default { Write-Output "UNHEALTHY: $($report.status)" }
}

# Fleet policy verification (W3-2/W3-3): is orgPolicy actually governing this edit right now?
if ($report.orgPolicy.applied) {
    Write-Output "org policy enforcing: $($report.orgPolicy.path) (sha256 $($report.orgPolicy.sha256))"
} else {
    Write-Output "org policy NOT applied (sidecarMatch=$($report.orgPolicy.sidecarMatch)) -- check POWERSHELL_LSP_POLICY_MODE if this host should fail closed"
}
```

**Exit codes, exactly** (unchanged by `-Json`; identical to the human-readable rendering):
`0` = nothing failed; `1` = at least one check failed; `2` (only with `-RequireProven`) = nothing
failed but at least one check could not be established (the headless/container case the
`UNPROVEN` status exists for). `-RequireProven` never lowers the exit code, only raises it over an
`UNKNOWN`.

This runs **out of a Claude Code session** (a scheduled task, not a hook), so several checks
report `UNKNOWN` there by design -- they need the plugin data directory a live session provides.
That is not a defect in the fleet check: a `HEALTHY`/exit-0 result out-of-session already proves
the checks that do not need a session (prerequisites, bootstrap markers, offline readiness); the
session-scoped checks (the warm daemon, the end-to-end diagnostic) are the ones worth re-running
`/powershell-lsp:doctor` for interactively if a user reports a problem.

## 5. Pointing OTLP at a collector

Fully covered in
[configuration.md, "Telemetry export, and what leaves the host"](configuration.md#telemetry-export-and-what-leaves-the-host):
`POWERSHELL_LSP_OTEL_ENDPOINT`, what `scripts/export-otel.ps1` sends, and the fixed metric/attribute
allowlist. Not restated here. One fleet-scale note that page does not make: `export-otel.ps1` is a
script you run or schedule per machine (it is deliberately **not** on the hook path), so pointing a
fleet at a collector means scheduling that script on each machine -- a scheduled task or cron
entry running `pwsh -File scripts/export-otel.ps1 -Send` on whatever cadence your collector
expects -- in addition to setting the endpoint variable via section 2 above.

`doctor -Json`'s `otelExport` field (`display`, `configured`, `recognized`) is how the health check
in section 4 confirms a host is actually pointed at a collector, without ever reading back the
collector URL's credentials (it is redacted by construction; see
[`Get-OtelEndpointReportInfo`](../scripts/lib/lsp-common.ps1)).
