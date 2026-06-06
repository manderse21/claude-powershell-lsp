#Requires -Version 5.1
# Test runner for the powershell-lsp Pester suite. Ensures Pester 5 is available
# (CurrentUser scope only -- never machine-global), runs every *.Tests.ps1 in
# this directory, and exits non-zero on any failure. Used locally (both hosts)
# and by CI.
param(
    [switch] $CI
)
$ErrorActionPreference = 'Stop'

$p5 = Get-Module -ListAvailable Pester |
    Where-Object { $_.Version.Major -ge 5 } | Sort-Object Version -Descending | Select-Object -First 1
if ($null -eq $p5) {
    Write-Host 'Pester 5 not found; installing to CurrentUser scope...'
    try { Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue } catch { }
    Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck -MinimumVersion 5.0.0 -Repository PSGallery
}
Import-Module Pester -MinimumVersion 5.0.0 -Force

$config = New-PesterConfiguration
$config.Run.Path = $PSScriptRoot
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Detailed'
if ($CI) {
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputFormat = 'NUnitXml'
    $config.TestResult.OutputPath = (Join-Path $PSScriptRoot 'testResults.xml')
}

$result = Invoke-Pester -Configuration $config
Write-Host ('Pester: ' + $result.PassedCount + ' passed, ' + $result.FailedCount + ' failed, ' + $result.SkippedCount + ' skipped')
exit $result.FailedCount
