# Performance -- what is measured, and what is deliberately not

The published latency figures and, just as importantly, the figure this project refuses to
publish. Summarized in [README, Performance](../README.md#performance); this page is the full
text. For the harness, the method, and the full numbers see [benchmarks.md](benchmarks.md).

Measured on `pwsh` 7.6.3, Windows 11 Pro, at the **v1.24.3** build, on 2026-07-17:
**warm-path latency** (edit -> diagnostic round-trip) has a **median of 2228 ms** and a **p95 of
2463 ms** over **30 iterations**. A figure without its sample size is not evidence, which is why
the n travels with it.

**Cold-start latency is not published here, because it is not currently measured to publication
standard.** The benchmark harness excludes cold start deliberately, so the repository holds no
cold-start measurement to quote. Cold start *is* threshold-guarded in
`tests/PowerShellLsp.Benchmark.Tests.ps1`, but a guard threshold is chosen to be generous and is
not a measurement; publishing it as one would render *not currently measured* as a measurement --
precisely the failure the plugin's own four-state diagnostic model exists to prevent, applied here
to the README. Publishing a cold-start number would require a cold-start path in the harness,
reported with its sample size, host, and build on the same footing as the warm figure above.

A v1.12.0-era note attributed roughly 0.7 s of the warm path to the per-hook `pwsh` process spawn
that Claude Code pays regardless of plugin code. That attribution has **not** been re-measured
against the figures above, so it is recorded with its original vintage rather than restated as
current.

These latencies are **measured and guarded in CI** by a repeatable benchmark harness
(`tests/PowerShellLsp.Benchmark.Tests.ps1`) on all four CI legs, which emits structured results
and fails if a median regresses past a threshold. Full numbers and method:
[docs/benchmarks.md](benchmarks.md).
