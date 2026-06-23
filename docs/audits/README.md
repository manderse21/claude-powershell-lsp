# Audits / findings ledger

A durable record of audit findings for the `powershell-lsp` plugin -- the
product-side analogue of a `DEV_NOTES` ledger. Each audit gets one dated entry
summarizing its findings and the resulting backlog, so a finding's origin and
disposition survive beyond the dispatch that produced it (the CHANGELOG records
shipped *changes*; this ledger records *findings*).

Scope grades used in entries: an axis is `HANDLED` / `PARTIAL` / `UNHANDLED` (or a
named variant), with a severity tag (`CRITICAL` / `HIGH` / `MEDIUM` / `LOW` / `OBS`)
plus the two non-gradeable tags `NEEDS-DATA` (no repo surface; needs telemetry or a
real run) and `NEEDS-DECISION` (a business/owner call, no code to grade). Findings
are tagged EVIDENCE-BACKED (exercised in-environment) vs READ (graded from a
`file:line` read).

| Date | Audit | Scope | Entry |
|------|-------|-------|-------|
| 2026-06-19 | Launch-readiness (000023) | install / first-run / manifest / docs / diagnosability / semver / licensing | [000023-launch-readiness.md](000023-launch-readiness.md) |
