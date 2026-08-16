# Vendored third-party component -- SARIF 2.1.0 JSON Schema

## File

`sarif-2.1.0.json` -- the Static Analysis Results Interchange Format (SARIF)
Version 2.1.0 JSON Schema.

## Why it is vendored

`tests/PowerShellLsp.SarifScan.Tests.ps1` validates the SARIF this plugin emits
(`scripts/lsp-scan.ps1`) against the official SARIF 2.1.0 schema with
`Test-Json -Schema`. The schema is committed so that validation runs OFFLINE on every
CI leg (no network egress, no new flake surface -- the same discipline as the pinned,
hash-verified PSScriptAnalyzer). It is a TEST FIXTURE only: it is never loaded, shipped,
or executed by the plugin runtime.

## Provenance

- Canonical source: the schema published by the OASIS SARIF Technical Committee at
  <https://github.com/oasis-tcs/sarif-spec>. The schema's own `$id` is
  `https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json`.
- This copy was retrieved on 2026-06-28 from SchemaStore
  (<https://json.schemastore.org/sarif-2.1.0.json>), which republishes the OASIS SARIF
  2.1.0 schema. It is vendored unmodified.

## Upstream terms

Content in the OASIS `sarif-spec` repository is contributed by OASIS TC Members and
governed by the OASIS Intellectual Property Rights (IPR) Policy under RF on RAND Terms
Mode -- see <https://www.oasis-open.org/policies-guidelines/ipr>. SARIF 2.1.0 is an
OASIS Standard. This schema retains those upstream OASIS terms; it is NOT relicensed
under this project's Apache-2.0 license, which covers the plugin's own source.
