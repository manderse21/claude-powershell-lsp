#Requires -Version 5.1
# repo-gates.ps1 -- the repo-side gates at C: corpus recompute, trust /
# signing / provenance CONFIGURATION suites.
#
# Dispatch 000273 (freeze 1B). ASCII only.
#
# Runs against a DETACHED worktree checked out at C, never the shared repo root.
#
# THE SELECTED-COUNT FLOOR. run-tests.ps1 exits with FailedCount, so a
# -FullNameFilter that matches NOTHING exits 0 and reads as a pass. Every
# filtered run below therefore asserts PassedCount > 0 as well; a filter that
# selected nothing is a FAILED gate, not a green one.

param(
    [string] $Worktree = 'C:\Users\mande\projects\work\nortam\claude-powershell-lsp\worktrees\s000273-freeze',
    [string] $Out = 'C:\Users\mande\AppData\Local\Temp\psl-273\out',
    [string[]] $Only = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $Out -Force | Out-Null

# Guard: the worktree must actually be at C.
$head = (& git -C $Worktree rev-parse HEAD).Trim()
$C = '6ab2d24bf254787520ad9449c4e6c17f74ee708d'
if ($head -cne $C) { throw ('worktree HEAD is ' + $head + ', not C (' + $C + ')') }
Write-Host ('worktree HEAD confirmed at C: ' + $head)

$suites = @(
    @{ key = 'corpus';    filter = '*Diagnostic-correctness corpus*'; label = 'corpus recompute (0-of-N known-good, N-of-N known-bad, expected-rule coverage)' },
    @{ key = 'release';   filter = '*';  path = 'PowerShellLsp.Release.Tests.ps1';       label = 'release workflow + SBOM + provenance CONFIGURATION' },
    @{ key = 'signplugin'; filter = '*'; path = 'PowerShellLsp.SignPlugin.Tests.ps1';    label = 'signing (Authenticode org-signing path)' },
    @{ key = 'pinning';   filter = '*';  path = 'PowerShellLsp.ActionPinning.Tests.ps1'; label = 'supply chain: GitHub Actions pinned by 40-char SHA' },
    @{ key = 'airgap';    filter = '*';  path = 'PowerShellLsp.AirgapBootstrap.Tests.ps1'; label = 'offline / air-gapped bootstrap CONTRACT suite (PR #176)' }
)

$runner = @'
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
'@
$runnerPath = Join-Path $Out 'pester-runner.ps1'
Set-Content -LiteralPath $runnerPath -Value $runner -Encoding ASCII

$testsDir = Join-Path $Worktree 'tests'
$all = [ordered]@{ commit = $C; worktree = $Worktree; suites = @() }

foreach ($s in $suites) {
    if ($Only.Count -gt 0 -and ($Only -notcontains $s.key)) { continue }
    Write-Host ''
    Write-Host ('=== ' + $s.key + ' :: ' + $s.label + ' ===')
    $json = Join-Path $Out ('pester-' + $s.key + '.json')
    if (Test-Path -LiteralPath $json) { Remove-Item -LiteralPath $json -Force }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $pathFile = ''
    if ($s.ContainsKey('path')) { $pathFile = [string]$s['path'] }
    & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $runnerPath `
        -TestsDir $testsDir -FilterName ([string]$s['filter']) -PathFile $pathFile -JsonOut $json
    $sw.Stop()
    if (-not (Test-Path -LiteralPath $json)) { throw ('suite ' + $s.key + ' produced no result file') }
    $r = Get-Content -LiteralPath $json -Raw | ConvertFrom-Json
    # THE FLOOR: a filter that selected nothing is not a pass.
    if ([int]$r.passed -le 0) {
        throw ('SELECTED-COUNT FLOOR: suite ' + $s.key + ' passed=' + $r.passed +
               ' -- the filter selected nothing, so a 0-failure exit proves nothing')
    }
    Write-Host ('  -> passed=' + $r.passed + ' failed=' + $r.failed + ' skipped=' + $r.skipped +
                ' in ' + [math]::Round($sw.Elapsed.TotalSeconds, 1) + 's')
    $all.suites += [ordered]@{
        key = $s.key; label = $s.label; filter = [string]$s['filter']; path = $pathFile
        passed = [int]$r.passed; failed = [int]$r.failed; skipped = [int]$r.skipped
        total = [int]$r.total; wall_s = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        failures = @($r.failures)
        verdict = $(if ([int]$r.failed -eq 0) { 'PASS' } else { 'FAIL' })
    }
}

$headAfter = (& git -C $Worktree rev-parse HEAD).Trim()
$all['head_after'] = $headAfter
if ($headAfter -cne $C) { throw ('worktree moved off C during the run: ' + $headAfter) }
($all | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $Out 'repo-gates.json') -Encoding UTF8

Write-Host ''
foreach ($s in $all.suites) { Write-Host ($s.verdict + '  ' + $s.key + '  ' + $s.passed + ' passed / ' + $s.failed + ' failed') }
$bad = @($all.suites | Where-Object { $_.verdict -ne 'PASS' })
if ($bad.Count -gt 0) { throw ('REPO GATES FAILED: ' + (($bad | ForEach-Object { $_.key }) -join ', ')) }
Write-Host 'REPO GATES: ALL PASS'
