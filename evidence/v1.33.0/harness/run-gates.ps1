#Requires -Version 5.1
# run-gates.ps1 -- the repo/CI and functional gates at C, after the load-sensitive
# quantitative suite has finished. Dispatch 000273 (freeze 1B). ASCII only.

param([string] $Base = 'C:\Users\mande\AppData\Local\Temp\psl-273')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'   # run every gate; report each verdict

$bin = Join-Path $Base 'bin'
$out = Join-Path $Base 'out'
$results = @()

function Invoke-Gate([string] $name, [string] $script) {
    Write-Host ''
    Write-Host ('################ GATE: ' + $name + ' ################')
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin $script)
    $rc = $LASTEXITCODE
    $sw.Stop()
    Write-Host ('GATE ' + $name + ' exit=' + $rc + ' elapsed=' + [math]::Round($sw.Elapsed.TotalSeconds, 1) + 's')
    return [pscustomobject]@{ gate = $name; script = $script; exit = $rc; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
}

$results += Invoke-Gate 'repo gates (corpus + trust/signing/provenance config suites)' 'repo-gates.ps1'
$results += Invoke-Gate 'LICENSE is Apache-2.0 and CONTINUITY matches' 'license-gate.ps1'
$results += Invoke-Gate 'offline / air-gapped bootstrap' 'airgap-gate.ps1'
$results += Invoke-Gate 'clean install + doctor' 'cleaninstall-doctor-gate.ps1'

# The frozen tree must still be C after every gate.
& pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $bin 'prove-equals-c.ps1') `
    -Label 'post-gates' -JsonOut (Join-Path $out 'equality-post-gates.json')
$eq = $LASTEXITCODE

Write-Host ''
Write-Host '================ GATE SUMMARY ================'
foreach ($r in $results) {
    Write-Host (('{0,-6}' -f $(if ($r.exit -eq 0) { 'PASS' } else { 'FAIL' })) + $r.gate + '  (' + $r.seconds + 's)')
}
Write-Host (('{0,-6}' -f $(if ($eq -eq 0) { 'PASS' } else { 'FAIL' })) + 'equality proof after all gates')
($results | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath (Join-Path $out 'gate-summary.json') -Encoding UTF8
Write-Host 'GATES DONE'
