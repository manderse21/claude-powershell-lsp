# Platform support

Which hosts run the hooks, which host can serve as the PSES child, and what CI actually proves.
Summarized in [README, Platform support](../README.md#platform-support); this page is the full
text. For the support window and version policy see [SUPPORT-POLICY.md](SUPPORT-POLICY.md).

As of 1.1.1 the **hooks require `pwsh` (PowerShell 7)**. Windows PowerShell 5.1 is supported as
the **PSES child host** (set `ps_host` to `powershell`), not as the hook interpreter.

CI runs the Pester suite on a four-leg matrix: **Windows `pwsh` 7**, **Windows PowerShell 5.1**,
**Ubuntu `pwsh`**, and (as of 1.3.0) **macOS `pwsh`**. The full warm-daemon **integration suite**
runs and is **green on all four legs**, so the Linux and macOS daemon paths are CI-verified, not
merely authored. The 5.1 leg's distinct value is exercising the **shared-library surface under
5.1** -- file-URI casing, BOM-tolerant stdin, the `ArgumentList`-vs-quoted-`.Arguments` split, and
the config-env fallback. The scripts are cross-platform: paths go through `Join-Path`, the single
Windows-only call is guarded behind `Test-OnWindows` with Linux `/proc` and macOS `ps` fallbacks,
and the transport is `System.IO.Pipes`.
