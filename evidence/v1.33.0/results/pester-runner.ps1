param([string] $TestsDir, [string] $FilterName, [string] $PathFile, [string] $JsonOut)
$ErrorActionPreference = 'Stop'
$p5 = Get-Module -ListAvailable Pester | Where-Object { $_.Version.Major -eq 5 } |
    Sort-Object Version -Descending | Select-Object -First 1
if ($null -eq $p5) { throw 'Pester 5 not available' }
Import-Module Pester -MinimumVersion 5.0.0 -MaximumVersion 5.99.99 -Force
$config = New-PesterConfiguration
if ($PathFile) { $config.Run.Path = (Join-Path $TestsDir $PathFile) } else { $config.Run.Path = $TestsDir }
$config.Run.PassThru = $true
$config.Output.Verbosity = 'None'
if ($FilterName -and $FilterName -ne '*') { $config.Filter.FullName = $FilterName }
$r = Invoke-Pester -Configuration $config
$o = [ordered]@{
    passed = $r.PassedCount; failed = $r.FailedCount; skipped = $r.SkippedCount
    total = $r.TotalCount; duration_s = [math]::Round($r.Duration.TotalSeconds, 1)
    failures = @($r.Failed | ForEach-Object { $_.ExpandedPath })
}
($o | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $JsonOut -Encoding UTF8
Write-Host ('passed=' + $r.PassedCount + ' failed=' + $r.FailedCount + ' skipped=' + $r.SkippedCount)
