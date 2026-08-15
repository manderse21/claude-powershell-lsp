# Troubleshooting

Before chasing a specific symptom, run the preflight **doctor** -- it checks the prerequisites and
bootstrap health in one place and prints a named fix-list. It is summarized in
[README, Troubleshooting](../README.md#troubleshooting):

```
pwsh -File scripts/doctor.ps1
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
  `nativeServe`): on Claude Code 2.1.233, `${user_config.*}` references inside a
  plugin's `lspServers` block are resolved against the options you have
  **explicitly set**, ignoring the defaults this plugin's `userConfig` schema
  declares -- and one unset key discards **every** LSP server the plugin declares.
  Until that is fixed upstream, set all three keys explicitly in
  `~/.claude/settings.json`:

  ```json
  "pluginConfigs": {
    "powershell-lsp@claude-powershell-lsp": {
      "options": { "profile": "safe", "ps_host": "pwsh", "nativeServe": "off" }
    }
  }
  ```

  Diagnostics are **not** affected -- they run through the hooks, which resolve
  options normally. What is lost until the keys are set is the LSP server
  registration (hover, go-to-definition, find-references). Root cause, the
  reproducer, and the proposed upstream fix:
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
| **ExecutionPolicy** (Group Policy) | `Get-ExecutionPolicy -List` shows `MachinePolicy`/`UserPolicy` = `AllSigned`/`RemoteSigned` (a command-line `-Bypass` is ignored when the policy is from GPO) | likely | the policy + scope. Fix: an admin allow-lists / signs the scripts, or adjusts the policy. |
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
