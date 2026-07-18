#Requires -Version 5.1

# lsp-scan.ps1 -- the standalone, non-agent entry point (dispatch 000057, PL-5). Runs the
# SAME PowerShell diagnostics engine the in-agent PostToolUse hook uses, over a PATH (a file
# or a directory), and emits SARIF 2.1.0 for GitHub code scanning OR a human-readable text
# report. This bridges the in-agent linter to in-CI use WITHOUT forking the analysis logic:
# the findings come from the exact same warm-daemon + PSScriptAnalyzer pass the hook drives
# (see scripts/lib/lsp-scan-common.ps1, the one-engine invariant), so a finding is identical
# whether it surfaces in-agent or in-CI. Additive only -- nothing about the in-agent
# PostToolUse behavior changes.
#
# Output format is a CLI PARAMETER (-Format sarif|text), NOT a new userConfig knob: the CI
# invocation is explicit, so the decision is a parameter (the 000027 contract drift-guard
# freezes userConfig knob NAMES + status tokens, neither of which this touches -- no CONTRACT
# amendment, the guard stays green).
#
# PSScriptAnalyzer is the existing pinned-hash-verified vendor (scripts/ensure-pssa.ps1,
# 000046 L2): the daemon bootstrap is the ONLY acquisition path; this script adds none.
#
# Exit codes:
#   0  scan completed; no -FailOn threshold met (or none was set), or no PowerShell files found.
#   2  scan completed; findings met or exceeded the -FailOn severity threshold (a CI gate fail).
#   3  usage error (no PowerShell host found, or the path does not exist).
#   4  scan incomplete: the analyzer daemon never became ready, or one+ files could not be
#      analyzed (never-silent -- an unanalyzed file must never read as a clean one).
#
# ASCII-only (PS 5.1 em-dash trap); StrictMode-safe.
#
# Author: Mike Andersen / powershell-lsp plugin.

[CmdletBinding()]
param(
    # The path to scan: a single .ps1/.psm1/.psd1 file, or a directory (recursed by default).
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $Path,

    # Output format. 'sarif' (default) emits SARIF 2.1.0 for code scanning; 'text' emits a
    # human-readable report. A CLI parameter, deliberately NOT a userConfig knob.
    [ValidateSet('sarif', 'text')]
    [string] $Format = 'sarif',

    # Write the report to this file (UTF-8, no BOM) instead of stdout.
    [string] $OutputPath = '',

    # Scan only the top level of a directory (default: recurse the whole tree).
    [switch] $NoRecurse,

    # PowerShell host that runs the analysis (pwsh preferred, then Windows PowerShell). The
    # analysis host is always a real PowerShell regardless of who launched the scan.
    [string] $PsHost = 'pwsh',

    # Fail (exit 2) when any finding is at or above this SARIF level. 'none' (default) never
    # gates on findings (the SARIF-upload pattern: emit, let code scanning surface them).
    [ValidateSet('none', 'note', 'warning', 'error')]
    [string] $FailOn = 'none',

    # Per-file client hard cap (ms) for the analysis round-trip.
    [int] $TimeoutMs = 25000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/lsp-common.ps1')
. (Join-Path $PSScriptRoot 'lib/lsp-scan-common.ps1')

function Write-ScanOutput {
    param([string]$Text, [string]$OutFile)
    if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($OutFile, $Text + "`n", $enc)
    } else {
        [Console]::Out.WriteLine($Text)
    }
}

# Get-FailExitCode (the -FailOn policy) lives in lib/lsp-scan-common.ps1, dot-sourced above --
# moved there by dispatch 000127 so the policy is unit-testable as a pure function. Behavior is
# unchanged; this script runs analysis on dot-source, so the matrix could not reach it in place.

# --- resolve host + targets ------------------------------------------------
$hostExe = Resolve-PsHost $PsHost
if ($null -eq $hostExe) {
    [Console]::Error.WriteLine('lsp-scan: no PowerShell host (pwsh / powershell) found.')
    exit 3
}

$full = $Path
try { $full = [System.IO.Path]::GetFullPath($Path) } catch { $full = $Path }
if (-not (Test-Path -LiteralPath $full)) {
    [Console]::Error.WriteLine('lsp-scan: path not found: ' + $full)
    exit 3
}

$targets = Get-ScanTargets -Path $full -Recurse (-not $NoRecurse)
$files = @($targets['Files'])
$root = [string]$targets['Root']
$skipped = [int]$targets['Skipped']

# No PowerShell files -> a well-formed empty report, exit 0 (nothing to analyze is not a fault).
if ($files.Count -eq 0) {
    if ($Format -eq 'sarif') {
        $report = New-SarifReport -Findings @() -Root $root -ToolVersion (Get-PluginVersion) -ExecutionSuccessful $true
        Write-ScanOutput -Text ($report | ConvertTo-Json -Depth 16) -OutFile $OutputPath
    } else {
        Write-ScanOutput -Text (Format-ScanTextReport -Findings @() -Root $root -Skipped $skipped -FilesScanned 0 -NotAnalyzed @()) -OutFile $OutputPath
    }
    [Console]::Error.WriteLine('lsp-scan: no PowerShell files (.ps1/.psm1/.psd1) under ' + $full + ' (' + $skipped + ' other file(s) skipped).')
    exit 0
}

# --- bring up the warm daemon (the same engine the in-agent hook uses) -----
$dataRoot = if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_PLUGIN_DATA)) {
    $env:CLAUDE_PLUGIN_DATA
} else {
    Join-Path ([System.IO.Path]::GetTempPath()) 'powershell-lsp-scan-data'
}
$sessionId = 'scan-' + [guid]::NewGuid().ToString('N').Substring(0, 12)

$daemon = Start-ScanDaemon -ScriptsDir $PSScriptRoot -DataRoot $dataRoot -SessionId $sessionId -HostExe $hostExe
if ($null -eq $daemon) {
    # Never emit a fake-clean SARIF: a daemon that never came up means NOTHING was analyzed.
    Stop-ScanDaemon -ScriptsDir $PSScriptRoot -DataRoot $dataRoot -SessionId $sessionId -HostExe $hostExe -DaemonInfo $null
    [Console]::Error.WriteLine('lsp-scan: the analyzer daemon did not become ready -- analysis was NOT performed. See ' + (Join-Path $dataRoot 'logs') + '.')
    exit 4
}

$allFindings = New-Object System.Collections.ArrayList
$notAnalyzed = New-Object System.Collections.ArrayList
try {
    foreach ($file in $files) {
        $r = Invoke-ScanFileDiagnostics -ScriptsDir $PSScriptRoot -DataRoot $dataRoot -SessionId $sessionId `
            -HostExe $hostExe -FilePath $file -Cwd $root -CapMs $TimeoutMs
        foreach ($f in @($r.Findings)) { [void]$allFindings.Add($f) }
        if (-not $r.Analyzed) { [void]$notAnalyzed.Add([string]$r.File) }
    }
} finally {
    Stop-ScanDaemon -ScriptsDir $PSScriptRoot -DataRoot $dataRoot -SessionId $sessionId -HostExe $hostExe -DaemonInfo $daemon
}

$findings = @(@($allFindings) | Where-Object { $null -ne $_ })
$execOk = (@($notAnalyzed).Count -eq 0)

# --- emit ------------------------------------------------------------------
if ($Format -eq 'sarif') {
    $report = New-SarifReport -Findings $findings -Root $root -ToolVersion (Get-PluginVersion) -ExecutionSuccessful $execOk -NotAnalyzed @($notAnalyzed)
    Write-ScanOutput -Text ($report | ConvertTo-Json -Depth 16) -OutFile $OutputPath
} else {
    Write-ScanOutput -Text (Format-ScanTextReport -Findings $findings -Root $root -Skipped $skipped `
            -FilesScanned $files.Count -NotAnalyzed @($notAnalyzed)) -OutFile $OutputPath
}

# --- exit ------------------------------------------------------------------
if (@($notAnalyzed).Count -gt 0) {
    # Name the files, not just the count (dispatch 000131): the SARIF carries them too, but the
    # stderr is what lands in the CI step log, so a future INCOMPLETE is diagnosable from the run
    # output alone. Bounded to the shared cap (the leading count line is preserved verbatim so
    # anything grepping "file(s) could NOT be analyzed" keeps working).
    $na = Get-ScanNotAnalyzedNames -NotAnalyzed @($notAnalyzed) -Root $root
    [Console]::Error.WriteLine('lsp-scan: ' + $na.Total + ' file(s) could NOT be analyzed -- scan is INCOMPLETE (executionSuccessful=false):')
    foreach ($rel in $na.Names) { [Console]::Error.WriteLine('  ' + $rel) }
    if ($na.Overflow -gt 0) { [Console]::Error.WriteLine('  ... and ' + $na.Overflow + ' more (' + $na.Total + ' total).') }
    exit 4
}
exit (Get-FailExitCode -Findings $findings -FailOn $FailOn)
