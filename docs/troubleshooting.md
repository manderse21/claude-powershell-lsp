# Troubleshooting

Before chasing a specific symptom, run the preflight **doctor** -- it checks the prerequisites and
bootstrap health in one place and prints a named fix-list. It is summarized in
[README, Troubleshooting](../README.md#troubleshooting):

```
/powershell-lsp:doctor          # inside an enabled session -- preferred, needs no path
pwsh -File scripts/doctor.ps1   # out-of-session, from the root of a local clone
```

The raw path is relative to **the plugin tree**, not your working directory. If you installed with
`/plugin` there is no `scripts/` beside your project and pwsh exits **64** with a usage error before
the doctor runs; point it at the marketplace cache instead, naming the version explicitly:

```
pwsh -File ~/.claude/plugins/cache/claude-powershell-lsp/powershell-lsp/<version>/scripts/doctor.ps1
```

The doctor is **report-only**: it never downloads, repairs, runs the bootstrap, or starts/restarts
the daemon. It also does **not** probe security controls itself -- but when a *bootstrap* failure is
caused by one, the SessionStart banner names the most likely control and the legitimate fix (see
[Security-control blocks on managed Windows](#security-control-blocks-on-managed-windows) below).
If a doctor check fails for a reason its own fix does not resolve, a security control on a managed
machine (an execution or application-control policy) may be the cause -- check that banner and the
section below.

## Symptoms

- **Hooks fail with `'pwsh' is not recognized` / pwsh not found:** as of 1.1.1 the
  hooks launch under PowerShell 7. Install it (`winget install Microsoft.PowerShell`)
  -- Windows PowerShell 5.1 alone cannot launch the hooks. (`ps_host` only selects the
  PSES *child* host, not the hook interpreter.)
- **Bootstrap fails with `integrity check FAILED for the mirror source` (or `bundle`):**
  the artifact that layer served does not match the pinned SHA-256, so it was refused. This
  **fails closed on purpose** and deliberately does **not** fall through to another source --
  a mismatch is a tamper signal, not a reason to retry elsewhere. Usually the mirror or bundle
  is **stale** after a pin bump: re-stage it from the `powershell-lsp-airgap-<version>.zip`
  asset for the version you are running. Check with `/doctor` ("Offline readiness"), which
  hashes staged artifacts against the pins and names the offending file.
- **`Offline readiness` reports the bundle is missing an artifact:** the directory
  `POWERSHELL_LSP_ARTIFACT_BUNDLE_DIR` points at does not hold every pinned file. Filenames are
  version-qualified (`PowerShellEditorServices-v4.6.0.zip`,
  `PSScriptAnalyzer-1.25.0.nupkg`), so a bundle staged for an older pin will not satisfy a newer
  one. Unpack the current release's airgap bundle into that directory.
- **A configured mirror or bundle is ignored entirely:** the value was refused as unusable
  rather than silently used. `POWERSHELL_LSP_ARTIFACT_MIRROR_BASE` must be an `https://` URL;
  `POWERSHELL_LSP_ARTIFACT_BUNDLE_DIR` must be an **absolute** path to a directory that exists.
  `/doctor` names the exact reason. Note these are environment variables, **not** `/plugin`
  config knobs -- setting them in the config panel does nothing.
- **Air-gapped install still reaches for the network:** a layer *miss* (a 404ing mirror, or a
  bundle that lacks the file) legitimately falls through to the default download. Confirm the
  staged filenames match exactly, then re-check `/doctor` -- "Artifact source" reports which
  layer actually produced the installed dependencies.
- **Hooks fail with `File ... cannot be loaded. The file ... is not digitally signed`, or
  `UnauthorizedAccess` / `PSSecurityException` on a `scripts/*.ps1` path:** the machine's
  execution policy is `AllSigned` and the plugin's scripts arrive unsigned over `git clone`, as
  this repository ships them. The `-ExecutionPolicy Bypass` on every hook entry point does not
  help here and is not meant to: when the policy comes from **Group Policy**, PowerShell ignores
  the command-line flag. Confirm with `Get-ExecutionPolicy -List` -- a `MachinePolicy` or
  `UserPolicy` row reading `AllSigned` is the case. **The fix is to sign the scripts with your
  own code-signing certificate**, which your policy already trusts:
  `pwsh -File scripts/sign-plugin.ps1 -Thumbprint <your-thumbprint>` (run by an administrator,
  against the installed copy). The full paved path -- what it covers, what it does not, and the
  air-gapped variant -- is in
  [TRUST.md, "Sign it yourself"](../TRUST.md#sign-it-yourself-the-org-certificate-paved-path).
  Re-run it after every plugin upgrade: an upgrade replaces the files with unsigned copies.
- **Diagnostics worked, then stopped after a plugin upgrade on an AllSigned machine:** expected,
  and it is the signatures rather than the plugin. An upgrade replaces `scripts/` with fresh
  unsigned files, so the signatures you applied are gone.
  `pwsh -File scripts/sign-plugin.ps1 -VerifyOnly` reports the current state per file without
  changing anything; re-sign to restore it.
- **`sign-plugin.ps1` prints `FAILED CLOSED` with every file reporting `UnknownError`:** the
  signing succeeded but **this machine does not trust the certificate's root**, so Windows cannot
  build a chain and refuses to call the signature `Valid`. This is common when signing from a
  build box that is outside the estate. Verify on a machine that trusts your organization root --
  the target estate does. A status of `Unreadable` means something different: Windows could not
  read a signature back at all, which is usually a read-only file, a file held open, or AV
  quarantining it mid-run.
- **`sign-plugin.ps1` exits 2 saying the host is not Windows:** correct behavior, not a fault.
  Authenticode is a Windows construct and the policies it satisfies are Windows policies, so the
  script refuses the host rather than half-running. Run it on the managed Windows machine.
- **A leftover user-level PSES hook fires alongside the plugin (duplicate or
  conflicting diagnostics):** if you previously wired a PowerShell diagnostics hook
  directly in `~/.claude/settings.json` (a pre-plugin setup), remove it -- the plugin
  owns the SessionStart / PostToolUse / SessionEnd hooks now, and a stray user-level
  hook will double up or conflict with them.
- **`/plugin` Errors tab shows `Executable not found in $PATH`** for the
  `powershell` server: `ps_host` points at an executable that is not on PATH.
  Install PowerShell 7 (`pwsh`) or set `ps_host` to `powershell`.
- **Startup reports `Failed to load LSP servers for plugin powershell-lsp: Error:
  Plugin option "profile" isn't set.`** (or the same message naming `ps_host` or
  `nativeServe`): **fixed -- update the plugin.** On Claude Code 2.1.233,
  `${user_config.*}` references inside a plugin's `lspServers` block are resolved
  against the options you have **explicitly set**, ignoring the defaults the
  plugin's `userConfig` schema declares -- and one unset key discards **every** LSP
  server the plugin declares. Opening `/plugin` and pressing Save does not help:
  the panel seeds an unset field **empty** rather than from its declared default,
  and skips blank optional keys when saving, so it writes nothing. The plugin no
  longer declares those references at all, so a fresh install registers its LSP
  server with nothing configured. If you are pinned to an affected build, set the
  three keys explicitly in `~/.claude/settings.json` (note `pluginConfigs`, plural,
  and the marketplace-qualified key):

  ```json
  "pluginConfigs": {
    "powershell-lsp@claude-powershell-lsp": {
      "options": { "profile": "safe", "ps_host": "pwsh", "nativeServe": "off" }
    }
  }
  ```

- **`nativeServe` is set to `shim` but native navigation still does not serve, and
  `/doctor` says `SUSPENDED BY UPSTREAM GATE`:** expected, and not a fault in your
  configuration. Removing the `${user_config.*}` references above (the fix for the
  startup error) also removed the only supported way to carry a configured value
  into the LSP **serve subprocess**, so `profile`, `ps_host` and `nativeServe` are
  currently read there at their shipped defaults (`safe`, `pwsh`, `off`) regardless
  of what you set. The transport itself is correct and proven; what is **SUSPENDED**
  is its use, until Claude Code merges declared `userConfig` defaults on the
  `lspServers` path the way it already does for MCP servers. Concretely:
  **`nativeServe = shim` cannot take effect while this holds.**

  **Diagnostics are unaffected** by either issue -- they run through the hooks,
  which do receive plugin options and resolve them normally, including your
  `profile`. What is affected is only the LSP serve subprocess: hover,
  go-to-definition and find-references stay on the default (`off`) path.

  `scripts/doctor.ps1` reports this explicitly and distinguishes it from a knob
  with genuinely broken transport; the serve log
  (`${CLAUDE_PLUGIN_DATA}/logs/pses-serve-shim.log`) names the gate on every launch
  rather than reporting a bare `provenance: default`. Root cause, the reproducer,
  the suspension record and the upstream report:
  [docs/upstream/claude-code-lspservers-userconfig-defaults.md](upstream/claude-code-lspservers-userconfig-defaults.md).
- **No diagnostics / server never starts:** confirm the bootstrap ran by checking
  that
  `${CLAUDE_PLUGIN_DATA}/PowerShellEditorServices/PowerShellEditorServices/Start-EditorServices.ps1`
  exists. If not, start a fresh session so the `SessionStart` hook can run, and
  inspect `${CLAUDE_PLUGIN_DATA}/logs/ensure-pses.log`.
- **Server starts but handshake fails:** inspect the PSES log under
  `${CLAUDE_PLUGIN_DATA}/logs/pses-lsp.log/StartEditorServices-<pid>.log` for the
  PSES-side error.
- **`PrepareRenameHandler` `NullReferenceException` on initialize:** a PSES
  `v4.6.0` bug -- its rename handler dereferences a null `RenameCapability` when an
  LSP client's `textDocument` capabilities **omit** `rename`. This plugin's daemon
  **declares a minimal `rename` capability on purpose**, which is what *avoids* the
  NRE, so the warm path is unaffected. You would only hit this by driving PSES from
  a client that omits rename (e.g. a hand-rolled minimal client against the cold
  `-Stdio` launcher); if so, pin PSES `v4.5.0` in `scripts/ensure-pses.ps1`
  (`$PsesTag`), which predates the rename handler.

## Security-control blocks on managed Windows

PowerShell developers often work inside locked-down Windows estates, and this plugin does
exactly what those estates gate: it **downloads** executables (PSES, PSScriptAnalyzer),
**runs** PowerShell, and **spawns** a daemon. When a security control blocks one of those
at first start, the bootstrap fails -- and instead of a generic "could not start", the
SessionStart banner now **names the most likely control and the legitimate remediation**.
The status stays `unavailable` (see [Diagnostics status](../README.md#diagnostics-status)); only
the message gets specific.

A control is named **only on positive evidence**, with calibrated confidence -- an
uncertain case gets an honest "here is how to check" pointer, never a guessed control:

| Control | How it is detected | Confidence | Banner names / fix |
|---------|--------------------|------------|--------------------|
| **ExecutionPolicy** (Group Policy) | `Get-ExecutionPolicy -List` shows `MachinePolicy`/`UserPolicy` = `AllSigned`/`RemoteSigned` (a command-line `-Bypass` is ignored when the policy is from GPO) | likely | the policy + scope. Fix: an admin signs the scripts with the org certificate (`scripts/sign-plugin.ps1`; see [TRUST.md](../TRUST.md#sign-it-yourself-the-org-certificate-paved-path)), allow-lists them, or adjusts the policy. |
| **Constrained Language Mode** | the session `LanguageMode` is `ConstrainedLanguage` | likely | CLM. The plugin's .NET-using bootstrap cannot run under it. Fix: sign + policy-trust the plugin (admin). |
| **App Control / WDAC** | a CodeIntegrity Operational event **3077** (enforced) or **3076** (audit) names a plugin component | confirmed / likely | the control + event id. Fix: an admin adds an allow rule. |
| **Microsoft Defender ASR** | a Defender Operational event **1121** (block) or **1122** (audit) names a plugin component | confirmed / likely | the rule family + event id. Fix: an admin reviews / allows the rule. |
| **Smart App Control** | the SAC registry state (`VerifiedAndReputablePolicyState`) is enforced / evaluation | possible | SAC is reputation-gated, so it is only ever *possible*. Fix: it relaxes as reputation accrues, or an admin turns it off. |
| *(none identified)* | no positive evidence | -- | honest pointer: usually network/proxy; if managed, check `Get-ExecutionPolicy -List`, the language mode, and the CodeIntegrity log. |

To investigate a named (or suspected) block yourself, on the affected machine:

```
Get-ExecutionPolicy -List
$ExecutionContext.SessionState.LanguageMode
Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-CodeIntegrity/Operational'; Id = 3076, 3077 } -MaxEvents 20
```

**The plugin only ever detects and explains a block -- it never bypasses, disables, or
modifies a security control.** Every remediation above is something a user or their
administrator does deliberately (sign, allow-list, adjust policy); the plugin itself takes
no such action. A tool that tried to circumvent enterprise security would deserve to be
banned -- honest degradation, telling you exactly what is blocked and how to allow it, is
the whole value. The full Bypass-flag inventory and the rationale for it are in
[TRUST.md](../TRUST.md#why-executionpolicy-bypass-appears-in-every-hook-entry-point).
