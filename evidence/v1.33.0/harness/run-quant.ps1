#Requires -Version 5.1
# run-quant.ps1 -- the cache-based quantitative suite for dispatch 000273.
# Each block is bracketed by the equality proof, so "the build measured was C"
# is asserted immediately before and immediately after every block rather than
# once at the start. ASCII only.

param([string] $Base = 'C:\Users\mande\AppData\Local\Temp\psl-273')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$bin = Join-Path $Base 'bin'
$out = Join-Path $Base 'out'

function Assert-EqualsC([string] $label, [string] $tag) {
    Write-Host ('--- equality proof: ' + $label + ' ---')
    & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'prove-equals-c.ps1') `
        -Label $label -JsonOut (Join-Path $out ('equality-' + $tag + '.json'))
    if ($LASTEXITCODE -ne 0) { throw ('EQUALITY PROOF FAILED at ' + $label) }
}

function Get-DataWitness {
    # The exclusion is only meaningful if the data root actually MOVED while the
    # script tree did not. Count files under the data root as the witness.
    $d = Join-Path $Base 'data'
    $logs = Join-Path $d 'logs'
    $n = 0
    if (Test-Path -LiteralPath $logs) { $n = @(Get-ChildItem -LiteralPath $logs -Recurse -File -ErrorAction SilentlyContinue).Count }
    return $n
}

$blocks = @(
    @{ name = 'm1';  label = 'M1 warm per-edit latency' },
    @{ name = 'm2';  label = 'M2 cold start' },
    @{ name = 'm35'; label = 'M3/M5 memory + 120-edit stability' },
    @{ name = 'm4b'; label = 'M4b large-file convergence' }
)

Assert-EqualsC 'pre-suite' 'pre-suite'
$witnessStart = Get-DataWitness

foreach ($b in $blocks) {
    Write-Host ''
    Write-Host ('================ BLOCK ' + $b.name + ' : ' + $b.label + ' ================')
    Assert-EqualsC ('before ' + $b.name) ('before-' + $b.name)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'measure.ps1') -Block $b.name
    $rc = $LASTEXITCODE
    $sw.Stop()
    Write-Host ('block ' + $b.name + ' exit=' + $rc + ' elapsed=' + [math]::Round($sw.Elapsed.TotalSeconds, 1) + 's')
    if ($rc -ne 0) { throw ('block ' + $b.name + ' FAILED with exit ' + $rc) }
    Assert-EqualsC ('after ' + $b.name) ('after-' + $b.name)
}

Assert-EqualsC 'post-suite' 'post-suite'
$witnessEnd = Get-DataWitness
Write-Host ('data-root witness: logs files before=' + $witnessStart + ' after=' + $witnessEnd)
Write-Host 'QUANT SUITE DONE'
