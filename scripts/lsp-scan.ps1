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
#      analyzed (never-silent -- an unanalyzed file must never read as a clean one). Since dispatch
#      000304 a file counts as analyzed ONLY on a validated COMPLETE completion receipt
#      (scripts/lib/lsp-scan-receipt.ps1); every other file is named, with its reason codes.
#      Since dispatch 000305 also: a MANAGED scan (-PolicyMode closed) that is NOT CERTIFIED -- no usable
#      declared policy, or missing / disagreeing evidence that it was applied (reason codes on stderr,
#      in the text report and in the SARIF). The same exit, because both mean the scan cannot vouch
#      for its result.
#
# POLICY (dispatch 000305, B1; owner ruling O03). -OrgPolicyPath now drives the MAIN analysis -- the
# daemon's RequiredRules merge and the per-file client's ExcludeRules / SeverityOverrides /
# ProhibitedSuppressions adjudication -- not only the post-pass, and is resolved ONCE through
# scripts/lib/lsp-policy.ps1. -PolicyMode closed is the managed mode; see Test-ScanPolicyCertification.
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
    [int] $TimeoutMs = 25000,

    # DIAGNOSTIC (dispatch 000132 leg 3): emit a per-file 'lsp-scan diag:' line (name, analyzed, elapsed
    # ms) to stderr for EVERY file, so a measurement run records how long each file's analysis actually
    # ran -- including files that COMPLETE, not only the ones marked INCOMPLETE. This is the instrument
    # that measured the true per-file cost on ubuntu-24.04 (see the 000132 outbox); it changes NO budget
    # and is a diagnostic lever, NOT a userConfig knob. Off by default (no extra output).
    [switch] $DiagnosticTiming,

    # The org policy for THIS scan (P1-5 remainder, dispatch 000294; full main pass since dispatch
    # 000305): the SAME org policy file the in-agent hook reads via the 'orgPolicy' userConfig knob,
    # but a CLI PARAMETER here -- deliberately NOT a userConfig knob, matching -Format/-FailOn's own
    # rationale: a CI invocation names its inputs explicitly. It reaches the daemon and every per-file
    # client (replacing any ambient orgPolicy, under every spelling) and drives the
    # ProhibitedSuppressions post-pass. Empty (the default) changes nothing about the scan.
    [string] $OrgPolicyPath = '',

    # Managed policy mode (dispatch 000305, B1; owner ruling O03, 2026-10-12). 'closed' is the MANAGED
    # mode: the scan is CERTIFIED only when the declared -OrgPolicyPath is usable AND the daemon's and
    # each client's evidence show that exact policy was applied; with no declared policy, or anything
    # less, it is NOT CERTIFIED (exit 4) with reason codes. 'open' is the unmanaged scan -- nothing is
    # certified or refused. Omitted: POWERSHELL_LSP_POLICY_MODE, then open. A CLI parameter, not a
    # userConfig knob.
    [ValidateSet('open', 'closed')]
    [string] $PolicyMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/lsp-common.ps1')
. (Join-Path $PSScriptRoot 'lib/lsp-scan-common.ps1')
# The completion-receipt validator Invoke-ScanFileDiagnostics requires (dispatch 000304, A2).
. (Join-Path $PSScriptRoot 'lib/lsp-scan-receipt.ps1')
# The effective-policy resolver and the managed verdict (dispatch 000305, B1).
. (Join-Path $PSScriptRoot 'lib/lsp-policy.ps1')

function Write-ScanPolicyVerdict {
    # The managed verdict on stderr -- what lands in the CI step log. Silent for an unmanaged scan.
    param($Certification, $ModeInfo, $Declared = $null, [int]$FileCount = 0)
    if ($null -eq $Certification -or -not [bool]$Certification.Managed) { return }
    $how = 'lsp-scan: managed policy mode (-PolicyMode closed, from ' + [string]$ModeInfo.source + ')'
    if ([bool]$Certification.Certified) {
        [Console]::Error.WriteLine($how + ': CERTIFIED -- policy ' + [string]$Declared.identity.sha256 +
            ' was applied to ' + $FileCount + ' file(s), with evidence from the daemon and each client.')
        return
    }
    [Console]::Error.WriteLine($how + ': NOT CERTIFIED (executionSuccessful=false):')
    $table = Get-PolicyReasonTable
    foreach ($code in @($Certification.AllReasons)) {
        $meaning = $(if ($table.Contains([string]$code)) { [string]$table[[string]$code].Meaning } else { '' })
        [Console]::Error.WriteLine('  ' + [string]$code + ': ' + $meaning)
    }
}

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

# --- policy: the mode, the declared policy, and what reaches the children (dispatch 000305) ---------
# Resolved ONCE through the seam (Resolve-EffectivePolicy -> Import-OrgPolicy: the same reader, the same
# integrity gate and the same warning as before). The children then re-resolve the SAME path themselves
# and report what they applied; a managed scan certifies only when every report agrees with this one.
$policyModeInfo = Resolve-ScanPolicyMode -Explicit $PolicyMode
$managed = ([string]$policyModeInfo.resolved -eq 'closed')
$declaredPolicy = $null
if (-not [string]::IsNullOrWhiteSpace($OrgPolicyPath)) {
    $declaredPolicy = Resolve-EffectivePolicy -Path $OrgPolicyPath -Source 'cli'
    if (-not [bool]$declaredPolicy.usable) { [Console]::Error.WriteLine('lsp-scan: orgPolicy: ' + [string]$declaredPolicy.warning) }
}
# Until A3 binds a declared child configuration, an ambient analysis option is refused in managed mode
# rather than certified around (Get-ScanAmbientAnalysisOptions); an unmanaged scan is unaffected.
$ambientOptions = @()
if ($managed) {
    $ambientOptions = @(Get-ScanAmbientAnalysisOptions -Environment ([System.Environment]::GetEnvironmentVariables()) `
            -PolicyDeclared ($null -ne $declaredPolicy))
}
$childPolicyPath = $(if ($null -ne $declaredPolicy) { $OrgPolicyPath } else { '' })
$childPolicyMode = $(if ([string]$policyModeInfo.source -eq 'cli') { [string]$policyModeInfo.resolved } else { '' })
$policyReported = ($managed -or $null -ne $declaredPolicy)

# No PowerShell files -> a well-formed empty report, exit 0 (nothing to analyze is not a fault). A
# MANAGED scan is never certified here: nothing was analyzed, so nothing shows the policy was applied
# (analysis-empty, from Test-ScanPolicyCertification), and it names whatever else it can refuse without
# a file (no usable declared policy, ambient configuration) -- exit 4, so a managed gate pointed at the
# wrong directory cannot read CERTIFIED.
if ($files.Count -eq 0) {
    $emptyCert = Test-ScanPolicyCertification -Mode ([string]$policyModeInfo.resolved) -Declared $declaredPolicy -Ambient $ambientOptions
    $emptyOk = (-not [bool]$emptyCert.Managed) -or [bool]$emptyCert.Certified
    $emptyPolicy = $null
    if ($policyReported) { $emptyPolicy = New-ScanPolicyReport -ModeInfo $policyModeInfo -Declared $declaredPolicy -Certification $emptyCert -Ambient $ambientOptions }
    if ($Format -eq 'sarif') {
        $report = New-SarifReport -Findings @() -Root $root -ToolVersion (Get-PluginVersion) -ExecutionSuccessful $emptyOk -PolicyReport $emptyPolicy
        Write-ScanOutput -Text ($report | ConvertTo-Json -Depth 16) -OutFile $OutputPath
    } else {
        Write-ScanOutput -Text (Format-ScanTextReport -Findings @() -Root $root -Skipped $skipped -FilesScanned 0 -NotAnalyzed @() -PolicyReport $emptyPolicy) -OutFile $OutputPath
    }
    [Console]::Error.WriteLine('lsp-scan: no PowerShell files (.ps1/.psm1/.psd1) under ' + $full + ' (' + $skipped + ' other file(s) skipped).')
    Write-ScanPolicyVerdict -Certification $emptyCert -ModeInfo $policyModeInfo -Declared $declaredPolicy -FileCount 0
    if (-not $emptyOk) { exit 4 }
    exit 0
}

# --- bring up the warm daemon (the same engine the in-agent hook uses) -----
$dataRoot = if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_PLUGIN_DATA)) {
    $env:CLAUDE_PLUGIN_DATA
} else {
    Join-Path ([System.IO.Path]::GetTempPath()) 'powershell-lsp-scan-data'
}
$sessionId = 'scan-' + [guid]::NewGuid().ToString('N').Substring(0, 12)

$daemon = Start-ScanDaemon -ScriptsDir $PSScriptRoot -DataRoot $dataRoot -SessionId $sessionId -HostExe $hostExe `
    -OrgPolicyPath $childPolicyPath -PolicyMode $childPolicyMode
if ($null -eq $daemon) {
    # Never emit a fake-clean SARIF: a daemon that never came up means NOTHING was analyzed.
    Stop-ScanDaemon -ScriptsDir $PSScriptRoot -DataRoot $dataRoot -SessionId $sessionId -HostExe $hostExe -DaemonInfo $null
    [Console]::Error.WriteLine('lsp-scan: the analyzer daemon did not become ready -- analysis was NOT performed. See ' + (Join-Path $dataRoot 'logs') + '.')
    exit 4
}

$allFindings = New-Object System.Collections.ArrayList
$notAnalyzed = New-Object System.Collections.ArrayList
# What each file's receipt said, for the managed verdict (dispatch 000305): its completeness, the pass
# that ran, and the parsed receipt carrying the client's and the daemon's policy application records.
$fileEvidence = New-Object System.Collections.ArrayList
try {
    foreach ($file in $files) {
        $r = Invoke-ScanFileDiagnostics -ScriptsDir $PSScriptRoot -DataRoot $dataRoot -SessionId $sessionId `
            -HostExe $hostExe -FilePath $file -Cwd $root -CapMs $TimeoutMs `
            -OrgPolicyPath $childPolicyPath -PolicyMode $childPolicyMode
        [void]$fileEvidence.Add([pscustomobject]@{ File = [string]$r.File; Completeness = [string]$r.Completeness; Pass = [string]$r.Pass; Receipt = $r.Receipt })
        foreach ($f in @($r.Findings)) { [void]$allFindings.Add($f) }
        # Carry each unanalyzed file's elapsed ms (dispatch 000132 leg 2) so the INCOMPLETE surfaces
        # can report how long it ran before the budget cut it, not merely that it ran out -- and its
        # receipt reason codes (dispatch 000304), so they say WHY it is not analyzed, and its
        # completeness, so the text report tells a valid PARTIAL receipt from a missing one (A2-Q01).
        if (-not $r.Analyzed) {
            [void]$notAnalyzed.Add([pscustomobject]@{ Path = [string]$r.File; ElapsedMs = [int]$r.ElapsedMs; Reasons = @($r.Reasons); Completeness = [string]$r.Completeness })
        }
        # DIAGNOSTIC timing (dispatch 000132 leg 3): with -DiagnosticTiming, record EVERY file's true
        # elapsed -- including files that COMPLETE when given room -- so a measurement run learns the
        # real per-file cost, not only of the timed-out files the INCOMPLETE surfaces already name.
        if ($DiagnosticTiming) {
            [Console]::Error.WriteLine('lsp-scan diag: ' + (Get-ScanRelativeUri -FilePath ([string]$r.File) -Root $root) +
                ' analyzed=' + $r.Analyzed + ' elapsed=' + [int]$r.ElapsedMs + 'ms completeness=' + [string]$r.Completeness)
        }
    }
} finally {
    Stop-ScanDaemon -ScriptsDir $PSScriptRoot -DataRoot $dataRoot -SessionId $sessionId -HostExe $hostExe -DaemonInfo $daemon
}

# prohibitedSuppressions, repo/CI path (P1-5 remainder, R23=D member A, dispatch 000294), restricted
# to files this scan already resolved. The policy is the one resolved ONCE above (dispatch 000305) --
# lsp-scan.ps1 is a standalone CI entry point with no userConfig context, so it reads only what it was
# given. A degrade (no policy, no ProhibitedSuppressions) costs nothing and drops no other finding; a
# pass that cannot run (vendored PSSA missing) is logged to stderr, never silent -- and, since dispatch
# 000305, recorded as a failed obligation a managed scan refuses to certify.
$suppressionPass = 'not-required'
if ($null -ne $declaredPolicy -and [bool]$declaredPolicy.usable) {
    $prohibitedForScan = Get-PolicyStringList -Object $declaredPolicy.effective -Name 'ProhibitedSuppressions'
    if ($prohibitedForScan.Count -gt 0) {
        $psWarn = ''
        $suppressionFindings = @(Invoke-ProhibitedSuppressionScan -Files $files -ProhibitedRules $prohibitedForScan -WarningOut ([ref]$psWarn))
        $suppressionPass = $(if ($psWarn -ne '') { 'failed' } else { 'ran' })
        if ($psWarn -ne '') { [Console]::Error.WriteLine('lsp-scan: ' + $psWarn) }
        if ($suppressionFindings.Count -gt 0) {
            [Console]::Error.WriteLine('lsp-scan: prohibitedSuppressions (repo/CI path) found ' + $suppressionFindings.Count + ' finding(s).')
            foreach ($sf in $suppressionFindings) { [void]$allFindings.Add($sf) }
        }
    }
}

$findings = @(@($allFindings) | Where-Object { $null -ne $_ })

# --- the managed verdict (dispatch 000305) -----------------------------------------------------------
# Unmanaged: Managed=$false and nothing changes. Managed: certified only on a usable declared policy AND
# agreeing application evidence for every file (Test-ScanPolicyCertification); otherwise the scan is NOT
# CERTIFIED -- executionSuccessful=false and exit 4, with every reason named.
$policyCert = Test-ScanPolicyCertification -Mode ([string]$policyModeInfo.resolved) -Declared $declaredPolicy `
    -Ambient $ambientOptions -SuppressionPass $suppressionPass -Files @($fileEvidence)
$certOk = (-not [bool]$policyCert.Managed) -or [bool]$policyCert.Certified
$policyReport = $null
if ($policyReported) {
    $policyFiles = @(@($policyCert.Files) | ForEach-Object {
            [ordered]@{ uri = (Get-ScanRelativeUri -FilePath ([string]$_.File) -Root $root); reasons = @($_.Reasons) }
        } | Sort-Object { [string]$_['uri'] })
    if ($policyFiles.Count -gt $script:ScanNotAnalyzedNameCap) { $policyFiles = @($policyFiles[0..($script:ScanNotAnalyzedNameCap - 1)]) }
    $policyReport = New-ScanPolicyReport -ModeInfo $policyModeInfo -Declared $declaredPolicy -Certification $policyCert `
        -SuppressionPass $suppressionPass -Ambient $ambientOptions -Files $policyFiles
}
$execOk = (@($notAnalyzed).Count -eq 0) -and $certOk

# --- emit ------------------------------------------------------------------
if ($Format -eq 'sarif') {
    $report = New-SarifReport -Findings $findings -Root $root -ToolVersion (Get-PluginVersion) -ExecutionSuccessful $execOk `
        -NotAnalyzed @($notAnalyzed) -PolicyReport $policyReport
    Write-ScanOutput -Text ($report | ConvertTo-Json -Depth 16) -OutFile $OutputPath
} else {
    Write-ScanOutput -Text (Format-ScanTextReport -Findings $findings -Root $root -Skipped $skipped `
            -FilesScanned $files.Count -NotAnalyzed @($notAnalyzed) -PolicyReport $policyReport) -OutFile $OutputPath
}
Write-ScanPolicyVerdict -Certification $policyCert -ModeInfo $policyModeInfo -Declared $declaredPolicy -FileCount $files.Count

# --- exit ------------------------------------------------------------------
if (@($notAnalyzed).Count -gt 0) {
    # Name the files, not just the count (dispatch 000131): the SARIF carries them too, but the
    # stderr is what lands in the CI step log, so a future INCOMPLETE is diagnosable from the run
    # output alone. Bounded to the shared cap (the leading count line is preserved verbatim so
    # anything grepping "file(s) could NOT be analyzed" keeps working).
    $na = Get-ScanNotAnalyzedNames -NotAnalyzed @($notAnalyzed) -Root $root
    [Console]::Error.WriteLine('lsp-scan: ' + $na.Total + ' file(s) could NOT be analyzed -- scan is INCOMPLETE (executionSuccessful=false):')
    foreach ($it in $na.Items) {
        $line = '  ' + [string]$it.Name
        $bits = @()
        if ($null -ne $it.ElapsedMs) { $bits += ([string][int]$it.ElapsedMs + 'ms') }
        if (@($it.Reasons).Count -gt 0) { $bits += ('reasons: ' + (@($it.Reasons) -join ', ')) }
        if ($bits.Count -gt 0) { $line = $line + ' (' + ($bits -join '; ') + ')' }
        [Console]::Error.WriteLine($line)
    }
    if ($na.Overflow -gt 0) { [Console]::Error.WriteLine('  ... and ' + $na.Overflow + ' more (' + $na.Total + ' total).') }
    exit 4
}
# A managed scan that is not certified cannot vouch for its result either (dispatch 000305).
if (-not $certOk) { exit 4 }
exit (Get-FailExitCode -Findings $findings -FailOn $FailOn)
