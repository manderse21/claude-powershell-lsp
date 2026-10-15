#Requires -Version 5.1

# measure-policy-main-pass.ps1 -- the policy scenario table for ANY tree's scan CLI (dispatch 000305, B1).
#
# Runs one fixed set of scenarios through the lsp-scan.ps1 it is given and prints one JSON row per
# scenario: the exit code, executionSuccessful, the findings (ruleId:level) and, when the scan reports
# one, its policy verdict. It exists so a RED control and its GREEN result are measured the SAME way:
# point it at the pre-change tree (git archive of the base commit) and at the head tree, and compare.
# Every scenario is invoked identically for both trees -- only -OrgPolicyPath and, for the managed rows,
# POWERSHELL_LSP_POLICY_MODE=closed in the scan's environment, which a pre-change scanner accepts (it has
# no -PolicyMode parameter) -- so a difference between the two tables is a difference in the code.
#
# Every scan runs in a child whose environment has every CLAUDE_PLUGIN_OPTION_* and POWERSHELL_LSP_*
# variable removed: only the explicit policy reaches it. Fixtures live in a fresh temp directory
# (prefix b1m-, never psls-) that is removed afterwards. The data root (-DataRoot, default the suite's
# shared scan data root) must already hold the pinned PSES and PSScriptAnalyzer.
#
# Not a *.Tests.ps1 file: Pester never collects it. ASCII-only.
#
# Author: Mike Andersen / powershell-lsp plugin.

[CmdletBinding()]
param(
    # The lsp-scan.ps1 of the tree under measurement.
    [Parameter(Mandatory = $true)][string] $ScanScript,
    # Where the pinned PSES / PSScriptAnalyzer are vendored.
    [string] $DataRoot = '',
    # The host that RUNS the scanner (the analysis host is the scanner's own default, pwsh).
    [string] $HostExe = 'pwsh',
    # Per-scan cap (ms).
    [int] $CapMs = 300000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($DataRoot)) {
    $DataRoot = if (-not [string]::IsNullOrWhiteSpace($env:PSLS_TEST_DATA_DIR)) { $env:PSLS_TEST_DATA_DIR } else { Join-Path ([System.IO.Path]::GetTempPath()) 'psls-sarifscan-test-data' }
}
if (-not (Test-Path -LiteralPath $ScanScript -PathType Leaf)) { throw ('no scan script at ' + $ScanScript) }
# The INSTRUMENT's own library (this tree's), for Add-ProcessArguments -- never the measured tree's.
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')

function Invoke-MeasureChild {
    # One scan in a child with a cleared plugin environment; both streams drained concurrently.
    param([string[]]$ArgumentList, [hashtable]$ExtraEnv)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $HostExe; $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    Add-ProcessArguments $psi $ArgumentList
    foreach ($name in @($psi.EnvironmentVariables.Keys)) {
        $n = [string]$name
        if ($n.StartsWith('CLAUDE_PLUGIN_OPTION_', [System.StringComparison]::OrdinalIgnoreCase) -or
            $n.StartsWith('POWERSHELL_LSP_', [System.StringComparison]::OrdinalIgnoreCase)) {
            $psi.EnvironmentVariables.Remove($n)
        }
    }
    foreach ($k in @($ExtraEnv.Keys)) { $psi.EnvironmentVariables[$k] = [string]$ExtraEnv[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)
    try {
        $out = $p.StandardOutput.ReadToEndAsync()
        $err = $p.StandardError.ReadToEndAsync()
        $p.StandardInput.Close()
        if (-not $p.WaitForExit($CapMs)) { try { $p.Kill() } catch { }; return @{ ExitCode = -999; Err = 'timeout' } }
        [void]$out.Wait([Math]::Max(1500, $CapMs)); [void]$err.Wait([Math]::Max(1500, $CapMs))
        return @{ ExitCode = $p.ExitCode; Err = $(if ($err.IsCompleted) { [string]$err.Result } else { '' }) }
    } finally { $p.Dispose() }
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('b1m-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$enc = New-Object System.Text.UTF8Encoding($false)
function New-MeasureFile([string]$Rel, [string]$Text) {
    $p = Join-Path $work $Rel
    New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($p)) | Out-Null
    [System.IO.File]::WriteAllText($p, $Text, $enc)
    return $p
}
try {
    $alias = "function Get-B1mThing {`n    gci`n}`n"
    [void](New-MeasureFile 'src-req/thing.ps1' "function Set-B1mGlobal {`n    gci`n    `$global:B1mThing = 1`n}`n")
    [void](New-MeasureFile 'src-ovr/thing.ps1' $alias)
    [void](New-MeasureFile 'src-exc/thing.ps1' $alias)
    [void](New-MeasureFile 'src-sup/suppressed.ps1' "function Test-B1mSuppressed {`n    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '')]`n    param(`$Password)`n    Write-Output `$Password`n}`n")
    $pReq = New-MeasureFile 'required.psd1' "@{ RequiredRules = @('PSAvoidGlobalVars') }`n"
    $pOvr = New-MeasureFile 'override.psd1' "@{ SeverityOverrides = @{ PSAvoidUsingCmdletAliases = 'Error' } }`n"
    $pExc = New-MeasureFile 'exclude.psd1' "@{ ExcludeRules = @('PSAvoidUsingCmdletAliases') }`n"
    $pSup = New-MeasureFile 'suppress.psd1' "@{ ProhibitedSuppressions = @('PSAvoidUsingPlainTextForPassword') }`n"
    $pCor = New-MeasureFile 'corrupt.psd1' "@{ ExcludeRules = @( this is not data`n"
    $pMis = Join-Path $work 'missing.psd1'

    $closed = @{ POWERSHELL_LSP_POLICY_MODE = 'closed' }
    $scenarios = @(
        @{ Name = 'baseline-req'; Dir = 'src-req'; Policy = ''; Env = @{} }
        @{ Name = 'required'; Dir = 'src-req'; Policy = $pReq; Env = @{} }
        @{ Name = 'override'; Dir = 'src-ovr'; Policy = $pOvr; Env = @{} }
        @{ Name = 'exclude'; Dir = 'src-exc'; Policy = $pExc; Env = @{} }
        @{ Name = 'suppress'; Dir = 'src-sup'; Policy = $pSup; Env = @{} }
        @{ Name = 'managed-required'; Dir = 'src-req'; Policy = $pReq; Env = $closed }
        @{ Name = 'managed-missing'; Dir = 'src-ovr'; Policy = $pMis; Env = $closed }
        @{ Name = 'managed-corrupt'; Dir = 'src-ovr'; Policy = $pCor; Env = $closed }
        @{ Name = 'managed-undeclared'; Dir = 'src-ovr'; Policy = ''; Env = $closed }
    )
    $rows = New-Object System.Collections.ArrayList
    foreach ($s in $scenarios) {
        $out = Join-Path $work ($s.Name + '.sarif')
        $a = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScanScript, (Join-Path $work $s.Dir), '-Format', 'sarif', '-OutputPath', $out)
        if (-not [string]::IsNullOrWhiteSpace($s.Policy)) { $a += @('-OrgPolicyPath', $s.Policy) }
        $envx = @{ CLAUDE_PLUGIN_DATA = $DataRoot }
        foreach ($k in @($s.Env.Keys)) { $envx[$k] = $s.Env[$k] }
        $run = Invoke-MeasureChild -ArgumentList $a -ExtraEnv $envx
        $results = @(); $exec = $null; $cert = ''; $reasons = @()
        if (Test-Path -LiteralPath $out) {
            $sarif = [System.IO.File]::ReadAllText($out) | ConvertFrom-Json
            $results = @(@($sarif.runs[0].results) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.ruleId + ':' + [string]$_.level } | Sort-Object)
            $inv = $sarif.runs[0].invocations[0]
            $exec = [bool]$inv.executionSuccessful
            if ($null -ne $inv.PSObject.Properties['properties']) { $cert = [string]$inv.properties.policy.certification; $reasons = @($inv.properties.policy.reasons | ForEach-Object { [string]$_ }) }
        }
        [void]$rows.Add([ordered]@{ name = $s.Name; exit = [int]$run.ExitCode; executionSuccessful = $exec; results = @($results); certification = $cert; reasons = @($reasons) })
    }
    ConvertTo-Json -InputObject @($rows) -Depth 5 -Compress
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
