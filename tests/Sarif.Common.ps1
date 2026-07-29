#Requires -Version 5.1

# Sarif.Common.ps1 -- shared test-support helper for the SARIF suite
# (PowerShellLsp.SarifScan.Tests.ps1). NOT a *.Tests.ps1 file, so Pester discovery
# (Run.Path = tests/, default *.Tests.ps1 glob) never collects it as a test.
# Dot-sourced from the BeforeAll blocks that emit SARIF, mirroring the
# Integration.Common.ps1 / Corpus.Common.ps1 / ServeShim.Common.ps1 pattern.
#
# It lives in a dot-sourced support file rather than at the top of the test file for a
# measured reason: Pester 5 runs DISCOVERY and RUN in separate scopes, so a function
# defined at the top level of a *.Tests.ps1 is visible at discovery but NOT inside
# BeforeAll. The first cut of dispatch 000159 leg 1b did exactly that and every test in
# the block failed with "Save-EmittedSarif is not recognized".
#
# ASCII-only (PS 5.1 reads a UTF-8-without-BOM file through the Windows-1252 codepage;
# keep to bytes 0x00-0x7F -- "--" not an em-dash, straight quotes only).
#
# Author: Mike Andersen / powershell-lsp plugin.

function Save-EmittedSarif {
    # Persist a SARIF payload this suite emitted, so a host that CANNOT validate it
    # in-process can still have it validated afterwards (dispatch 000159 leg 1b).
    #
    # THE GAP THIS CLOSES, recorded by 000157 leg 4. Three schema-validation cases in the
    # SARIF suite skip on `-Skip:($PSVersionTable.PSVersion.Major -lt 6)` because they call
    # `Test-Json -Schema`, measured ABSENT on Windows PowerShell 5.1 and present on pwsh 7.
    # The skip is legitimate and stays -- the test physically cannot run there. What it left
    # behind is real and narrow: SARIF emitted UNDER 5.1 was never schema-validated
    # ANYWHERE, and 5.1's ConvertTo-Json is precisely the serializer most likely to deviate
    # (escaping, empty and single-element array handling). The riskiest host was the
    # unchecked one.
    #
    # The JSON is already produced; only the VALIDATOR needs a modern host. So the 5.1 leg
    # writes what it emitted here and a pwsh CI step (tests/validate-sarif-artifacts.ps1)
    # validates the artifact against the SAME vendored schema. Emission stays put; only
    # validation moves hosts.
    #
    # Gated on POWERSHELL_LSP_SARIF_ARTIFACT_DIR so a local run writes nothing. Never
    # throws: a diagnostics dump must not be able to fail a test.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Json,
        [Parameter(Mandatory = $true)][string]$Name
    )
    try {
        $dir = $env:POWERSHELL_LSP_SARIF_ARTIFACT_DIR
        if ([string]::IsNullOrWhiteSpace($dir)) { return $false }
        if ([string]::IsNullOrWhiteSpace($Json)) { return $false }
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir -ErrorAction SilentlyContinue | Out-Null
        }
        # Tag with the EMITTING host major version, so a schema failure names which
        # serializer produced the offending payload rather than leaving it to be guessed.
        $emitHost = 'ps' + $PSVersionTable.PSVersion.Major
        $out = Join-Path $dir ($emitHost + '-' + $Name + '.sarif')
        Set-Content -LiteralPath $out -Value $Json -Encoding ascii -ErrorAction Stop
        return $true
    } catch { return $false }
}
