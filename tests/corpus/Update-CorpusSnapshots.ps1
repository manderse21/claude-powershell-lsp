#Requires -Version 5.1

# Update-CorpusSnapshots.ps1 -- the diagnostic-correctness corpus's GROUND-TRUTH
# generator (dispatch 000040). Runs the REAL powershell-lsp tool (warm PSES daemon +
# PScriptAnalyzer, and the in-process parser pre-pass) over every sample and writes
# tests/corpus/expected/<category>/<name>.json with exactly what the tool emitted.
#
# This is the ONLY sanctioned way an expected-findings snapshot is produced. The
# snapshots are NEVER hand-edited or model-authored -- run this script, review the
# diff, and commit. The corpus test (PowerShellLsp.Corpus.Tests.ps1) re-derives the
# same way and asserts the live tool still matches the committed snapshot, so the
# snapshot is ground truth and a future behavior change becomes a visible test failure.
#
# Usage:  pwsh -NoProfile -File tests/corpus/Update-CorpusSnapshots.ps1
#         pwsh -NoProfile -File tests/corpus/Update-CorpusSnapshots.ps1 -WhatIf   # derive + print, write nothing
#
# Idempotent: a re-run against an unchanged tool is a clean no-op (no snapshot bytes
# change). ASCII-only.

[CmdletBinding(SupportsShouldProcess = $true)]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Corpus.Common.ps1')

$paths = Get-CorpusPaths
$scriptsDir = $paths.ScriptsDir

# Shared data root with the Pester suite when present (so the PSES/PSSA bootstrap is a
# no-op), else a local temp root. CLAUDE_PLUGIN_DATA keys all daemon state/logs.
$dataRoot = if (-not [string]::IsNullOrWhiteSpace($env:PSLS_TEST_DATA_DIR)) {
    $env:PSLS_TEST_DATA_DIR
} else {
    Join-Path ([System.IO.Path]::GetTempPath()) 'psls-corpus-data'
}
New-Item -ItemType Directory -Force -Path $dataRoot | Out-Null
$env:CLAUDE_PLUGIN_DATA = $dataRoot
$scratchDir = Join-Path $dataRoot ('corpus-regen-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null

Write-Host ('Update-CorpusSnapshots -- data root: ' + $dataRoot)

# Idempotent bootstrap of PSES + pinned PSSA (no-op if already vendored).
& pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsDir 'ensure-pses.ps1') 2>&1 | Out-Null
& pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsDir 'ensure-pssa.ps1') 2>&1 | Out-Null

$sid = 'corpus-regen-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
Write-Host ('Bringing up warm daemon (session ' + $sid + ') ...')
$daemon = Start-CorpusDaemon -ScriptsDir $scriptsDir -DataRoot $dataRoot -SessionId $sid
if ($null -eq $daemon) {
    throw 'Daemon did not reach ready state; cannot derive snapshots (the corpus needs the real tool).'
}

$specs = Get-CorpusSampleSpec
$changed = 0; $unchanged = 0; $total = 0
try {
    foreach ($spec in $specs) {
        $total++
        $content = [System.IO.File]::ReadAllText($spec.SourcePath)
        $findings = Invoke-CorpusDerivation -ScriptsDir $scriptsDir -DataRoot $dataRoot -SessionId $sid `
            -ScratchDir $scratchDir -ScratchName $spec.ScratchName -Content $content
        $json = Format-CorpusSnapshotJson -Findings $findings
        $ruleSummary = if (@($findings).Count -eq 0) { '(no findings)' } else { (@($findings) | ForEach-Object { $_.ruleId } | Where-Object { $_ } | Select-Object -Unique) -join ', ' }
        $expectedDir = Split-Path -Parent $spec.ExpectedPath
        New-Item -ItemType Directory -Force -Path $expectedDir | Out-Null

        $old = if (Test-Path -LiteralPath $spec.ExpectedPath) { Get-Content -LiteralPath $spec.ExpectedPath -Raw } else { $null }
        $newText = $json + "`n"
        if ($old -eq $newText) {
            $unchanged++
            Write-Host ('  = ' + $spec.Label.PadRight(48) + ' ' + @($findings).Count + ' finding(s): ' + $ruleSummary)
        } else {
            if ($PSCmdlet.ShouldProcess($spec.ExpectedPath, 'write snapshot')) {
                $enc = New-Object System.Text.UTF8Encoding($false)
                [System.IO.File]::WriteAllText($spec.ExpectedPath, $newText, $enc)
            }
            $changed++
            Write-Host ('  * ' + $spec.Label.PadRight(48) + ' ' + @($findings).Count + ' finding(s): ' + $ruleSummary)
        }
    }
} finally {
    Stop-CorpusDaemon -ScriptsDir $scriptsDir -DataRoot $dataRoot -SessionId $sid -DaemonInfo $daemon
    Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ('Done. ' + $total + ' sample(s): ' + $changed + ' written/changed, ' + $unchanged + ' unchanged.')
