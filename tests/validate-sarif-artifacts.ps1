#Requires -Version 6.0

<#
.SYNOPSIS
    Validate SARIF the test suite EMITTED against the vendored SARIF 2.1.0 JSON Schema.

.DESCRIPTION
    Dispatch 000159, leg 1b -- closing the gap dispatch 000157 leg 4 recorded.

    THE GAP. Three schema-validation cases in PowerShellLsp.SarifScan.Tests.ps1 skip on
    `-Skip:($PSVersionTable.PSVersion.Major -lt 6)` because they call `Test-Json -Schema`,
    which is measured ABSENT on Windows PowerShell 5.1 and present on pwsh 7. The skip is
    legitimate and stays -- the test physically cannot run on 5.1. What it left behind is a
    real, narrow hole: SARIF emitted UNDER 5.1 was never schema-validated ANYWHERE, and
    5.1's ConvertTo-Json is precisely the serializer most likely to deviate (escaping,
    empty and single-element array handling). The one host most at risk was the one host
    never checked.

    THE CHEAPEST FIX, which is what this is. The JSON is already produced; only the
    VALIDATOR needs a modern host. So the 5.1 leg writes what it emitted to an artifact
    directory (Save-EmittedSarif in the test file), and this script -- run from a `shell:
    pwsh` CI step on the SAME leg -- validates those artifacts against the SAME vendored
    schema the in-suite cases use. The validation moves hosts; the emission does not.

    #Requires -Version 6.0 is deliberate and load-bearing: this script exists precisely
    BECAUSE Test-Json -Schema is unavailable on 5.1, so it must refuse to run there rather
    than silently degrade into a pass.

.PARAMETER Path
    Directory holding the emitted *.sarif artifacts.

.PARAMETER Schema
    Path to the vendored SARIF 2.1.0 JSON Schema.

.PARAMETER RequireHost
    Require at least one artifact emitted by this PowerShell major version (e.g. 5). This is
    the vacuity guard: without it, a leg that silently wrote NOTHING would validate zero
    files and report success -- which is exactly the failure mode this dispatch exists to
    stop. Green here must mean "5.1's own SARIF was checked", not "nothing was checked".

.OUTPUTS
    Exit 0 when every artifact validates AND the vacuity guard is satisfied; 1 otherwise.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Schema,
    [int]$RequireHost = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Schema)) {
    Write-Host ('FAIL: vendored schema not found: ' + $Schema)
    exit 1
}
if (-not (Test-Path -LiteralPath $Path)) {
    Write-Host ('FAIL: SARIF artifact directory not found: ' + $Path)
    Write-Host '      (the emitting leg wrote nothing -- that is a real failure, not an empty pass)'
    exit 1
}

$schemaText = Get-Content -LiteralPath $Schema -Raw
$files = @(Get-ChildItem -LiteralPath $Path -Filter '*.sarif' -File -ErrorAction SilentlyContinue | Sort-Object Name)

Write-Host ('SARIF artifact validation -- ' + $files.Count + ' file(s) in ' + $Path)
Write-Host ('  validator host : PowerShell ' + $PSVersionTable.PSVersion.ToString())
Write-Host ('  schema         : ' + $Schema)

if ($files.Count -eq 0) {
    Write-Host 'FAIL: no *.sarif artifacts were emitted -- nothing was validated.'
    exit 1
}

$failed = 0
$hostsSeen = New-Object System.Collections.Generic.HashSet[int]

foreach ($f in $files) {
    # Artifacts are named '<host>-<name>.sarif', e.g. 'ps5-entry-point.sarif'.
    $emitHost = 0
    $m = [regex]::Match($f.Name, '^ps(\d+)-')
    if ($m.Success) { $emitHost = [int]$m.Groups[1].Value; [void]$hostsSeen.Add($emitHost) }

    $json = Get-Content -LiteralPath $f.FullName -Raw
    $ok = $false
    $err = ''
    try {
        $ok = Test-Json -Json $json -Schema $schemaText -ErrorAction Stop
    } catch {
        $ok = $false
        $err = $_.Exception.Message
    }
    if ($ok) {
        Write-Host ('  PASS  ' + $f.Name + '  (emitted by PowerShell ' + $emitHost + ', ' + $json.Length + ' chars)')
    } else {
        $failed = $failed + 1
        Write-Host ('  FAIL  ' + $f.Name + '  (emitted by PowerShell ' + $emitHost + ')')
        if ($err) { Write-Host ('        ' + $err) }
    }
}

# Vacuity guard: prove the host this step exists for actually contributed an artifact.
if ($RequireHost -gt 0 -and -not $hostsSeen.Contains($RequireHost)) {
    Write-Host ('FAIL: no artifact was emitted by PowerShell ' + $RequireHost +
        ' -- the gap this step closes would still be open, so a pass here would be a lie.')
    Write-Host ('      hosts seen: ' + (($hostsSeen | Sort-Object) -join ', '))
    exit 1
}

if ($failed -gt 0) {
    Write-Host ('FAIL: ' + $failed + ' of ' + $files.Count + ' emitted SARIF artifact(s) do not conform to SARIF 2.1.0.')
    exit 1
}

Write-Host ('OK: all ' + $files.Count + ' emitted SARIF artifact(s) conform to SARIF 2.1.0.')
exit 0
