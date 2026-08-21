#Requires -Version 5.1
# airgap-gate.ps1 -- the offline / air-gapped bootstrap functional gate at C.
#
# Dispatch 000267 (freeze 1B). ASCII only.
#
# DERIVED, then EXTENDED. PR #176 (dispatch 000244) ships two things:
#   * tests/PowerShellLsp.AirgapBootstrap.Tests.ps1 -- a resolver/wiring/doctor
#     CONTRACT suite. It is runnable and it is run separately.
#   * release/New-AirgapBundle.ps1 + POWERSHELL_LSP_ARTIFACT_BUNDLE_DIR -- the
#     operator procedure: build a bundle once, point the variable at it, and
#     every air-gapped machine bootstraps from local disk.
# What #176 does NOT prescribe is an END-TO-END run of that procedure with no
# network to the dependency hosts. This script CONSTRUCTS that test, and the
# outbox records it as constructed rather than prescribed.
#
# THE NETWORK BLOCK IS PROVEN, NOT ASSERTED. Every run is bracketed by a RED
# control: the SAME blocked environment with NO bundle configured must FAIL to
# bootstrap. If the RED control succeeds, the block is not real and the GREEN run
# proves nothing.

param(
    [string] $Base = 'C:\Users\mande\AppData\Local\Temp\psl-267'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root    = Join-Path $Base 'root'
$Scripts = Join-Path $Root 'scripts'
$Air     = Join-Path $Base 'airgap'
$Out     = Join-Path $Base 'out'
New-Item -ItemType Directory -Path $Air -Force | Out-Null
New-Item -ItemType Directory -Path $Out -Force | Out-Null

# An unroutable proxy: every outbound HTTP(S) attempt is refused immediately
# rather than hanging. Applied to the bootstrap child process only -- never to
# this machine.
$BlockProxy = 'http://127.0.0.1:1'

function New-ColdDataRoot([string] $tag) {
    # A genuinely COLD machine: no junctions to the real bundles, no version
    # markers. Bootstrap must actually run rather than no-op.
    $d = Join-Path $Air ('cold-' + $tag)
    if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $d 'logs') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $d 'session') -Force | Out-Null
    return $d
}

function Invoke-Bootstrap {
    # Drive the REAL SessionStart hook (ensure-pses -> ensure-pssa -> ... ) with
    # the network blocked, optionally with the air-gap bundle configured.
    param([string] $DataRoot, [string] $BundleDir, [int] $CapMs = 300000)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'pwsh'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($a in @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Scripts 'session-start.ps1'))) {
        $psi.ArgumentList.Add($a)
    }
    $psi.EnvironmentVariables['CLAUDE_PLUGIN_ROOT'] = $Root
    $psi.EnvironmentVariables['CLAUDE_PLUGIN_DATA'] = $DataRoot
    foreach ($v in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy')) {
        $psi.EnvironmentVariables[$v] = $BlockProxy
    }
    $psi.EnvironmentVariables['NO_PROXY'] = ''
    if ($BundleDir) { $psi.EnvironmentVariables['POWERSHELL_LSP_ARTIFACT_BUNDLE_DIR'] = $BundleDir }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = [System.Diagnostics.Process]::Start($psi)
    $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
    $stdin = [Text.Encoding]::UTF8.GetBytes('{"session_id":"airgap-267"}')
    $p.StandardInput.BaseStream.Write($stdin, 0, $stdin.Length)
    $p.StandardInput.Close()
    $exited = $p.WaitForExit($CapMs)
    $sw.Stop()
    if (-not $exited) { try { $p.Kill($true) } catch { } }
    [void]$so.Wait(3000); [void]$se.Wait(3000)
    return [pscustomobject]@{
        WallMs = [int]$sw.ElapsedMilliseconds; Exited = $exited
        Stdout = $(if ($so.IsCompleted) { $so.Result } else { '' })
        Stderr = $(if ($se.IsCompleted) { $se.Result } else { '' })
    }
}

function Get-BootstrapState([string] $DataRoot) {
    $pses = Join-Path $DataRoot 'PowerShellEditorServices/PowerShellEditorServices/Start-EditorServices.ps1'
    $marker = @(Get-ChildItem -LiteralPath $DataRoot -Filter 'pses-*.ok' -File -ErrorAction SilentlyContinue)
    $pssaMarker = @(Get-ChildItem -LiteralPath (Join-Path $DataRoot 'modules') -Filter '.pssa-*.ok' -File -ErrorAction SilentlyContinue)
    $pssaMod = Join-Path $DataRoot 'modules/PSScriptAnalyzer'
    $log = Join-Path $DataRoot 'logs/ensure-pses.log'
    $logText = ''
    if (Test-Path -LiteralPath $log) { $logText = [IO.File]::ReadAllText($log) }
    return [ordered]@{
        pses_installed   = (Test-Path -LiteralPath $pses)
        pses_marker      = $(if ($marker.Count) { $marker[0].Name } else { '' })
        pses_marker_layer = $(if ($marker.Count) { ([IO.File]::ReadAllText($marker[0].FullName)).Trim() } else { '' })
        pssa_marker      = $(if ($pssaMarker.Count) { $pssaMarker[0].Name } else { '' })
        pssa_marker_layer = $(if ($pssaMarker.Count) { ([IO.File]::ReadAllText($pssaMarker[0].FullName)).Trim() } else { '' })
        pssa_installed   = (Test-Path -LiteralPath $pssaMod)
        ensure_pses_log_tail = $(if ($logText) { ($logText -split "`n" | Select-Object -Last 6) -join ' | ' } else { '' })
    }
}

$result = [ordered]@{
    gate = 'offline / air-gapped bootstrap at C'
    commit = 'af6996f971c8e8629a7d005e83f72865f2a66112'
    prescribed_by_176 = 'tests/PowerShellLsp.AirgapBootstrap.Tests.ps1 (resolver/wiring/doctor contract suite) and the operator procedure release/New-AirgapBundle.ps1 + POWERSHELL_LSP_ARTIFACT_BUNDLE_DIR'
    end_to_end_test_origin = 'CONSTRUCTED by dispatch 000267 -- #176 prescribes no end-to-end no-network bootstrap run'
    block_mechanism = ('HTTP_PROXY/HTTPS_PROXY/ALL_PROXY -> ' + $BlockProxy + ' on the bootstrap process only')
}

# --- step 1: build the bundle by the SHIPPED procedure (network allowed) -------
Write-Host '--- step 1: build the airgap bundle with release/New-AirgapBundle.ps1 ---'
$srcDir = Join-Path $Air 'src'
New-Item -ItemType Directory -Path $srcDir -Force | Out-Null
$zip = Join-Path $Air 'powershell-lsp-airgap.zip'
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
& pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'release/New-AirgapBundle.ps1') `
    -RepoRoot $Root -OutFile $zip -SourceDir $srcDir
if ($LASTEXITCODE -ne 0) { throw ('New-AirgapBundle.ps1 failed: exit ' + $LASTEXITCODE) }
if (-not (Test-Path -LiteralPath $zip)) { throw 'the bundle zip was not produced' }
$bundleDir = Join-Path $Air 'bundle'
if (Test-Path -LiteralPath $bundleDir) { Remove-Item -LiteralPath $bundleDir -Recurse -Force }
Expand-Archive -LiteralPath $zip -DestinationPath $bundleDir -Force
$staged = @(Get-ChildItem -LiteralPath $bundleDir -File | ForEach-Object { $_.Name })
Write-Host ('bundle staged: ' + ($staged -join ', '))
$result['bundle_zip_bytes'] = (Get-Item -LiteralPath $zip).Length
$result['bundle_contents'] = $staged

# --- step 2: RED control -- blocked, NO bundle -> must FAIL --------------------
Write-Host '--- step 2: RED control (network blocked, no bundle configured) ---'
$redRoot = New-ColdDataRoot 'red'
$red = Invoke-Bootstrap -DataRoot $redRoot -BundleDir ''
$redState = Get-BootstrapState $redRoot
$result['red_control'] = [ordered]@{
    wall_ms = $red.WallMs; exited = $red.Exited
    state = $redState
    stderr_tail = (($red.Stderr -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' | ')
    bootstrapped = $redState['pses_installed']
}
Write-Host ('RED control: pses_installed=' + $redState['pses_installed'] + ' wall=' + $red.WallMs + 'ms')
Write-Host ('RED stderr: ' + $result['red_control']['stderr_tail'])

# --- step 3: GREEN -- blocked, bundle configured -> must SUCCEED ---------------
Write-Host '--- step 3: GREEN (network blocked, bundle configured) ---'
$greenRoot = New-ColdDataRoot 'green'
$green = Invoke-Bootstrap -DataRoot $greenRoot -BundleDir $bundleDir
$greenState = Get-BootstrapState $greenRoot
$result['green_run'] = [ordered]@{
    wall_ms = $green.WallMs; exited = $green.Exited
    state = $greenState
    stderr_tail = (($green.Stderr -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' | ')
    bootstrapped = $greenState['pses_installed']
}
Write-Host ('GREEN: pses_installed=' + $greenState['pses_installed'] +
            ' pses_layer=' + $greenState['pses_marker_layer'] +
            ' pssa_installed=' + $greenState['pssa_installed'] +
            ' pssa_layer=' + $greenState['pssa_marker_layer'] +
            ' wall=' + $green.WallMs + 'ms')

# --- verdict ------------------------------------------------------------------
$redFailedAsRequired = (-not $redState['pses_installed'])
$greenOk = ($greenState['pses_installed'] -and $greenState['pssa_installed'])
$layersFromBundle = (($greenState['pses_marker_layer'] -eq 'bundle') -and ($greenState['pssa_marker_layer'] -eq 'bundle'))

$result['red_control_valid'] = $redFailedAsRequired
$result['green_bootstrapped_offline'] = $greenOk
$result['both_layers_recorded_bundle'] = $layersFromBundle
$result['verdict'] = $(if ($redFailedAsRequired -and $greenOk -and $layersFromBundle) { 'PASS' } else { 'FAIL' })

($result | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $Out 'airgap-gate.json') -Encoding UTF8
Write-Host ''
Write-Host ('AIRGAP GATE: ' + $result['verdict'] +
            ' (red_control_valid=' + $redFailedAsRequired +
            ' green_bootstrapped=' + $greenOk +
            ' layers_bundle=' + $layersFromBundle + ')')
if (-not $redFailedAsRequired) {
    throw 'RED CONTROL INVALID: bootstrap SUCCEEDED with the network blocked and no bundle -- the block is not real, so the GREEN run proves nothing'
}
if ($result['verdict'] -ne 'PASS') { throw 'AIRGAP GATE FAILED' }
