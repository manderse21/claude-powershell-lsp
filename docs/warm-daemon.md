# How it works -- the warm-start daemon

The mechanics behind the live diagnostics loop: what starts, what stays hot, and what shuts down.
Summarized in [README, How it works](../README.md#how-it-works-warm-start-daemon); this page is the
full text.

Diagnostics are delivered through a **PostToolUse hook backed by a warm, per-session daemon** --
one PSES stays hot for the whole session, so each edit pays a pipe round-trip instead of a cold
PSES start.

```text
SessionStart  -> scripts/session-start.ps1
                   ensure-pses.ps1   (idempotent PSES bootstrap, pinned tag)
                   ensure-pssa.ps1   (idempotent PSScriptAnalyzer vendor, pinned)
                   log sweep, reap OUR stale daemons (recorded pids only, verified)
                   launch scripts/pses-daemon.ps1  (one warm PSES via -Stdio;
                     named pipe powershell-lsp-<sessionid>)

PostToolUse   -> scripts/lsp-client.ps1
                   read hook JSON (session_id, file_path) from stdin
                   connect to the pipe, request diagnostics for the edited file
                   daemon: didOpen/didChange -> wait for the SETTLED PSScriptAnalyzer
                     publish (not the early parser publish) -> debounce
                   return deduped, severity-sorted diagnostics via additionalContext

SessionEnd    -> scripts/session-end.ps1
                   pipe {shutdown} -> daemon sends LSP shutdown/exit to PSES, exits
```

All scripts run `-NoLogo -NoProfile`, write nothing to stdout on the daemon/LSP path, and keep all
state, logs, and pids under `CLAUDE_PLUGIN_DATA` only. The full flow from edit to banner is in
[ARCHITECTURE.md](../ARCHITECTURE.md).
