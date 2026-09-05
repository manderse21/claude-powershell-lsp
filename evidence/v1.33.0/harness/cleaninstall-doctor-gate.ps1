#Requires -Version 5.1
# cleaninstall-doctor-gate.ps1 -- the clean-install + doctor functional gate at C.
#
# Dispatch 000273 (freeze 1B). ASCII only.
#
# Same scratch-staging mechanism as the cache-based blocks: the plugin tree is the
# staged CLAUDE_PLUGIN_ROOT proven byte-identical to C. What is NEW here is a
# genuinely COLD data root -- no junctions, no version markers -- so the install
# path a first-time user walks is actually exercised rather than skipped.
#
# CLAUDE_PLUGIN_ROOT and CLAUDE_PLUGIN_DATA are set explicitly. Without them the
# doctor's bundle / vendored / daemon / end-to-end checks all go UNKNOWN and a
# healthy plugin reads as indeterminate.
#
# THE ANALYZER IS CORROBORATED, NOT ASSUMED. A zero-finding run and an un-run
# analyzer look identical from outside, so the gate ends by editing a specimen
# that violates a rule on the shipped default surface and requiring the finding
# to come back.

param([string] $Base = 'C:\Users\mande\AppData\Local\Temp\psl-273')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root    = Join-Path $Base 'root'
$Scripts = Join-Path $Root 'scripts'
$Out     = Join-Path $Base 'out'
$Work    = Join-Path $Base 'clean'
New-Item -ItemType Directory -Path $Out -Force | Out-Null
if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $Work -Force | Out-Null

$Data = Join-Path $Work 'data'
New-Item -ItemType Directory -Path $Data -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $Data 'logs') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $Data 'session') -Force | Out-Null
$Enc = New-Object System.Text.UTF8Encoding($false)
$Sid = 'clean-267'

function Invoke-P {
    param([string] $ScriptPath, [string] $StdinJson, [string[]] $ExtraArgs = @(), [int] $CapMs = 300000, [hashtable] $ExtraEnv)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'pwsh'; $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    foreach ($a in (@('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + @($ExtraArgs))) {
        if ($a) { $psi.ArgumentList.Add([string]$a) }
    }
    $psi.EnvironmentVariables['CLAUDE_PLUGIN_ROOT'] = $Root
    $psi.EnvironmentVariables['CLAUDE_PLUGIN_DATA'] = $Data
    if ($ExtraEnv) { foreach ($k in $ExtraEnv.Keys) { $psi.EnvironmentVariables[$k] = [string]$ExtraEnv[$k] } }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = [System.Diagnostics.Process]::Start($psi)
    $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
    if ($StdinJson) {
        $b = [Text.Encoding]::UTF8.GetBytes($StdinJson)
        $p.StandardInput.BaseStream.Write($b, 0, $b.Length)
    }
    $p.StandardInput.Close()
    $exited = $p.WaitForExit($CapMs); $sw.Stop()
    if (-not $exited) { try { $p.Kill($true) } catch { } }
    [void]$so.Wait(3000); [void]$se.Wait(3000)
    return [pscustomobject]@{
        ExitCode = $(if ($exited) { $p.ExitCode } else { -1 })
        WallMs = [int]$sw.ElapsedMilliseconds; Exited = $exited
        Stdout = $(if ($so.IsCompleted) { $so.Result } else { '' })
        Stderr = $(if ($se.IsCompleted) { $se.Result } else { '' })
    }
}

$res = [ordered]@{
    gate = 'clean install + doctor at C'
    commit = '6ab2d24bf254787520ad9449c4e6c17f74ee708d'
    plugin_root = $Root
    data_root = $Data
}

# --- step 1: clean install (SessionStart bootstraps a cold data root) ----------
Write-Host '--- step 1: clean install via the real SessionStart hook, cold data root ---'
$install = Invoke-P -ScriptPath (Join-Path $Scripts 'session-start.ps1') -StdinJson ('{"session_id":"' + $Sid + '"}')
$psesOk = Test-Path -LiteralPath (Join-Path $Data 'PowerShellEditorServices/PowerShellEditorServices/Start-EditorServices.ps1')
$pssaOk = Test-Path -LiteralPath (Join-Path $Data 'modules/PSScriptAnalyzer')
Write-Host ('install: exit=' + $install.ExitCode + ' wall=' + $install.WallMs + 'ms pses=' + $psesOk + ' pssa=' + $pssaOk)
$res['install'] = [ordered]@{
    exit_code = $install.ExitCode; wall_ms = $install.WallMs
    pses_installed = $psesOk; pssa_vendored = $pssaOk
    stderr_tail = (($install.Stderr -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' | ')
}

# --- step 2: the analyzer actually answers (corroboration, not assumption) -----
Write-Host '--- step 2: corroborate the analyzer with a known-bad specimen ---'
$spec = Join-Path $Work 'specimen.ps1'
[IO.File]::WriteAllText($spec, "function Frobnicate-Thing {`n    Get-Process`n}`n", $Enc)
$edit = $null
for ($i = 1; $i -le 12; $i++) {
    [IO.File]::WriteAllText($spec, ("function Frobnicate-Thing {`n    Get-Process`n}`n# nonce " + $i + "`n"), $Enc)
    $edit = Invoke-P -ScriptPath (Join-Path $Scripts 'lsp-client.ps1') `
        -StdinJson (@{ session_id = $Sid; tool_input = @{ file_path = $spec }; cwd = $Work } | ConvertTo-Json -Compress) `
        -CapMs 40000
    if ($edit.Stdout -match 'PSUseApprovedVerbs') { break }
}
$found = ($edit.Stdout -match 'PSUseApprovedVerbs')
Write-Host ('specimen: PSUseApprovedVerbs surfaced=' + $found + ' after ' + $i + ' edit(s)')
$res['analyzer_corroboration'] = [ordered]@{
    specimen = 'function Frobnicate-Thing { Get-Process }'
    expected_rule = 'PSUseApprovedVerbs'
    surfaced = $found
    edits_needed = $i
    stdout_excerpt = (($edit.Stdout -split "`n" | Where-Object { $_ -match 'PSUseApprovedVerbs' } | Select-Object -First 1))
}

# --- step 3: doctor -----------------------------------------------------------
Write-Host '--- step 3: doctor walkthrough ---'
$doc = Invoke-P -ScriptPath (Join-Path $Scripts 'doctor.ps1') -StdinJson '' -CapMs 300000 `
    -ExtraEnv @{ CLAUDE_SESSION_ID = $Sid }
$plain = ($doc.Stdout -replace "`e\[[0-9;]*m", '')
$lines = @($plain -split "`n")
$fails = @($lines | Where-Object { $_ -match '^\s*(\[)?FAIL' -or $_ -match '\bFAIL\b' })
$unknowns = @($lines | Where-Object { $_ -match '\bUNKNOWN\b' })
$passes = @($lines | Where-Object { $_ -match '\bPASS\b' })
$summary = @($lines | Where-Object { $_ -match 'check|Check' -and $_ -match '\d' } | Select-Object -Last 4)
Write-Host ('doctor: exit=' + $doc.ExitCode + ' PASS lines=' + $passes.Count + ' UNKNOWN lines=' + $unknowns.Count + ' FAIL lines=' + $fails.Count)
$res['doctor'] = [ordered]@{
    exit_code = $doc.ExitCode; wall_ms = $doc.WallMs
    pass_lines = $passes.Count; unknown_lines = $unknowns.Count; fail_lines = $fails.Count
    fail_excerpt = @($fails | Select-Object -First 6)
    unknown_excerpt = @($unknowns | Select-Object -First 8)
    summary_tail = $summary
}
[IO.File]::WriteAllText((Join-Path $Out 'doctor-output.txt'), $plain, $Enc)

# --- verdict ------------------------------------------------------------------
$ok = ($install.ExitCode -eq 0 -and $psesOk -and $pssaOk -and $found -and $doc.ExitCode -eq 0)
$res['verdict'] = $(if ($ok) { 'PASS' } else { 'FAIL' })
($res | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $Out 'cleaninstall-doctor.json') -Encoding UTF8
Write-Host ''
Write-Host ('CLEAN-INSTALL + DOCTOR GATE: ' + $res['verdict'])
if (-not $found) { throw 'the analyzer never surfaced the known-bad specimen -- a clean doctor here would be unproven' }
if (-not $ok) { throw 'CLEAN-INSTALL + DOCTOR GATE FAILED' }
