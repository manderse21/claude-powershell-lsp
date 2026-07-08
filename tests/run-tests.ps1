#Requires -Version 5.1
# Test runner for the powershell-lsp Pester suite. Ensures Pester 5 is available
# (CurrentUser scope only -- never machine-global), runs every *.Tests.ps1 in
# this directory, and exits non-zero on any failure. Used locally (both hosts)
# and by CI.
param(
    [switch] $CI,
    # Optional Pester FullName filter (Describe/It wildcard). Empty = run everything
    # (default, unchanged). Lets a dispatch custom_check re-run just one feature's tests
    # via the same command shape as the smoke_test, e.g. -FullNameFilter '*dispatch 000022*'.
    [string] $FullNameFilter = ''
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
if ($CI) {
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputFormat = 'NUnitXml'
    $config.TestResult.OutputPath = (Join-Path $PSScriptRoot 'testResults.xml')
}

$result = Invoke-Pester -Configuration $config
Write-Host ('Pester: ' + $result.PassedCount + ' passed, ' + $result.FailedCount + ' failed, ' + $result.SkippedCount + ' skipped')
exit $result.FailedCount
