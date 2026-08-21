# powershell-lsp evidence bundle -- v1.32.0

Raw measurement evidence backing the white paper (`docs/whitepaper.md`, revision r2).
Every `[M]` figure in the paper is traceable to a file here.

## Provenance

- Release: powershell-lsp v1.32.0, tag commit `fb3116c`.
- Quantitative figures measured at commit `af6996f` (dispatch 000267, "freeze 1B") and carried
  forward to `fb3116c` on a runtime tree proven byte-identical. See `results/cprime-verify.json`:
  the `af6996f -> fb3116c` diff touched only `.github/workflows/powershell-lsp-release.yml` and four
  relicense-deixis docs (CONTINUITY.md, README.md, TRUST.md, docs/CONTINUITY.md); `runtime_identical`
  is true and `equality_proof_at_cprime` is PASS.
- Each result JSON stamps the measured `commit` field (`af6996f...`).

## Measurement environment

| Parameter | Value |
|---|---|
| Machine | Lenovo ThinkPad (21TB000BUS), single host |
| CPU | AMD Ryzen AI 7 PRO 350, 8 cores / 16 threads, 2.0 GHz reported base (Win32_Processor.MaxClockSpeed) |
| RAM | 32 GB |
| OS | Windows 11 Pro, 25H2, build 26200.9168 |
| Measured PowerShell host | pwsh 7.6.5 (hook interpreter and, at default ps_host=pwsh, the PSES child host) |
| Windows PowerShell present | 5.1.26100.9168 (not the measured interpreter) |
| PSES / PSScriptAnalyzer | v4.6.0 / 1.25.0 (pinned) |
| Power profile | Balanced |
| Claude Code | target integration client; NOT in the measured path -- the harness invokes the hook scripts directly with synthesized PostToolUse stdin |

## Metric definitions (from harness/measure.ps1)

- Timer: .NET System.Diagnostics.Stopwatch, ElapsedMilliseconds, integer-truncated.
- "spread": max - min, rounded to 1 decimal.
- p95: nearest-rank, never interpolated.

## Contents

- `harness/` -- the measurement harness: `run-quant.ps1` (orchestrator), `measure.ps1` (blocks
  M1-M4b), `stage-c.ps1`, `prove-equals-c.ps1`.
- `results/` -- raw outputs:
  - `m1.json` warm per-edit latency (N=30); `m2.json` cold start (N=10); `m35.json` memory +
    120-edit stability; `m4b.json` / `m4b-firstpass.json` large-file convergence.
  - `equality-*.json` the script-tree-equals-commit proof chain bracketing every block.
  - `cprime-verify.json` the C -> C' carry-forward proof.
  - `cleaninstall-doctor.json`, `airgap-gate.json`, `license-gate.json`, `repo-gates.json`,
    `gate-summary.json`, `doctor-output.txt`, `pester-*.json` release-gate corroboration.
  - `*.log` run transcripts.
- `SHA256SUMS.txt` -- SHA-256 of every file in this bundle.

## Reproduce

The harness drives the plugin hook scripts directly (no editor, no live Claude Code client). From a
staged copy of the tagged tree:

```
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\harness\run-quant.ps1
```

Outputs land under the harness's working base (`out\`), matching the JSONs in `results/`.