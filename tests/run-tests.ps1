#Requires -Version 5.1
# Test runner for the powershell-lsp Pester suite. Ensures Pester 5 is available
# (CurrentUser scope only -- never machine-global), runs every *.Tests.ps1 in
# this directory, and exits with a verdict, never a count (dispatch 000313):
#   0  Pester reports the run passed AND at least one test was executed;
#   1  any failed test, failed block (BeforeAll/AfterAll) or failed container;
#   2  no test was executed -- nothing was selected, or everything selected was
#      skipped (or inconclusive).
# Used locally (both hosts) and by CI.
param(
    [switch] $CI,
    # Optional Pester FullName filter (Describe/It wildcard). Empty = run everything
    # (default, unchanged). Lets a dispatch custom_check re-run just one feature's tests
    # via the same command shape as the smoke_test, e.g. -FullNameFilter '*dispatch 000022*'.
    [string] $FullNameFilter = '',
    # TEMPORARY RED EXCLUSIONS (dispatch 000302, A1). A tag here marks ONLY tests that were measured
    # RED and are owned by the leg that fixes them -- never a block, never a guess. There are none:
    # ScanRed-A2 (the typed scan completion receipt and formatter-off containment) was retired by
    # dispatch 000304, and ScanRed-A3 (the scan's declared child configuration) by dispatch 000314,
    # each when its last RED test turned green -- so by default no test is excluded.
    # tests/fixtures/scan-verdict/expected-red.psd1 is the one list of such tests (empty now);
    # tests/assert-expected-red.ps1 proves they still fail exactly as declared, and the guard in
    # PowerShellLsp.ScanVerdict.Tests.ps1 fails if this default and that list ever disagree, or if a
    # ScanRed tag sits on a test the list does not name.
    [string[]] $ExcludeTag = @()
)
$ErrorActionPreference = 'Stop'

# Pester bootstrap bounded to the 5.x major (dispatch 000120): Pester 6.0.0 (GA on the
# PowerShell Gallery 2026-07-07) is a breaking major, so all three resolution points below
# -- detection, Install-Module, Import-Module -- are capped at 5.x; a runner-image change or
# a fresh install must not silently run the suite under Pester 6. Upgrading is a later call.
$p5 = Get-Module -ListAvailable Pester |
    Where-Object { $_.Version.Major -eq 5 } | Sort-Object Version -Descending | Select-Object -First 1
if ($null -eq $p5) {
    Write-Host 'Pester 5 not found; installing to CurrentUser scope...'
    try { Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue } catch { }
    Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck -MinimumVersion 5.0.0 -MaximumVersion 5.99.99 -Repository PSGallery
}
Import-Module Pester -MinimumVersion 5.0.0 -MaximumVersion 5.99.99 -Force

$config = New-PesterConfiguration
$config.Run.Path = $PSScriptRoot
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Detailed'
if (-not [string]::IsNullOrWhiteSpace($FullNameFilter)) { $config.Filter.FullName = $FullNameFilter }
$excluded = @($ExcludeTag | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($excluded.Count -gt 0) {
    $config.Filter.ExcludeTag = $excluded
    Write-Host ('Excluding temporary RED tag(s): ' + ($excluded -join ', ') + ' (see tests/fixtures/scan-verdict/expected-red.psd1)')
}
if ($CI) {
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputFormat = 'NUnitXml'
    $config.TestResult.OutputPath = (Join-Path $PSScriptRoot 'testResults.xml')
}

$result = Invoke-Pester -Configuration $config
Write-Host ('Pester: ' + $result.PassedCount + ' passed, ' + $result.FailedCount + ' failed, ' + $result.SkippedCount + ' skipped')
# What the line above cannot show (dispatch 000313, ruling ER1-R3): how many tests were discovered and
# left unrun by the filter, the BeforeAll/AfterAll blocks and the test files that failed outside any
# test, and which Pester and which host produced the run.
$pesterVersion = [string](Get-Module Pester | Sort-Object Version -Descending | Select-Object -First 1).Version
Write-Host ('Pester run: ' + $result.TotalCount + ' discovered, ' + $result.NotRunCount + ' not run, ' +
    $result.FailedBlocksCount + ' failed blocks, ' + $result.FailedContainersCount + ' failed containers; Pester ' +
    $pesterVersion + ' on PowerShell ' + $PSVersionTable.PSEdition + ' ' + $PSVersionTable.PSVersion)

# THE VERDICT IS THE EXIT CODE, AND IT IS NEVER A COUNT (dispatch 000313, ruling ER1-R3). This runner used
# to exit with the failed-test count, so a -FullNameFilter that selected nothing exited 0, a test file
# that failed at discovery or a BeforeAll that threw exited 0 (neither is a failed TEST), and on Linux
# and macOS 256 failed tests exited 0 (an exit status is one byte there). A test counts as executed when
# it reached a verdict, passed or failed; a skipped or inconclusive test did not.
if ($null -eq $result) { exit 1 }
if (([int]$result.FailedCount + [int]$result.FailedBlocksCount + [int]$result.FailedContainersCount) -gt 0) { exit 1 }
if (([int]$result.PassedCount + [int]$result.FailedCount) -eq 0) { exit 2 }
if ([string]$result.Result -ne 'Passed') { exit 1 }
exit 0
