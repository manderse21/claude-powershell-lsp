#Requires -Version 5.1

# measure-policy-b1b-controls.ps1 -- dispatch 000306 (B1b)'s five controls, for ANY tree.
#
# Runs one fixed set of scenarios against the tree it is given and prints one JSON row per scenario, so a
# RED control at the base and its GREEN result at the head are measured the SAME way: point it at a git
# archive of the base commit and at one of the head, and compare. Every scenario is invoked identically for
# both trees; a difference between the two tables is a difference in the code.
#
#   control 1 (B1-Q03)   POWERSHELL_LSP_POLICY_MODE=closed and no -PolicyMode: with no policy, with a
#                        declared one, with a declared one that is missing; and the explicit -PolicyMode
#                        closed control.
#   control 2 (B1-K04)   a repository settings file with Rules and Severity under a RequiredRules policy:
#                        the findings, and the KEYS of the merged file the daemon wrote (found by a rule
#                        name unique to this run in its IncludeRules).
#   control 3 (B1-K04)   a repository settings file holding a rejected key (RuleArguments): managed and
#                        unmanaged under a policy with no RequiredRules, and managed under RequiredRules.
#   control 4 (B1-K05)   a STAGED supervised re-spawn: the tree's own Initialize-PssaSettings and
#                        Reset-PsesState (lifted from its pses-daemon.ps1 by AST, PSES stubbed) activate a
#                        RequiredRules policy, re-spawn, and the new child's settings resolution throws; the
#                        tree's own Test-ScanPolicyCertification then judges the binding that would be sent.
#   control 5 (B1-OOB-I01) doctor on a daemon whose settings resolution threw: staged the same way on the
#                        instrument's host, and LIVE on a Windows PowerShell 5.1 daemon given a settingsPath
#                        holding '|' (.NET Framework's path APIs refuse it; PowerShell 7's accept it).
#
# Every scan and every staged run is a child whose environment has every CLAUDE_PLUGIN_OPTION_* and
# POWERSHELL_LSP_* variable removed; a case adds back exactly what it stages. Fixtures live in a fresh
# temp directory (prefix b1bm-, never psls-) removed afterwards. The data root (-DataRoot, default the
# suite's shared scan data root) must already hold the pinned PSES and PSScriptAnalyzer.
#
# Not a *.Tests.ps1 file: Pester never collects it. ASCII-only.
#
# Author: Mike Andersen / powershell-lsp plugin.

[CmdletBinding()]
param(
    # Root of the tree under measurement (its scripts/ is what runs).
    [Parameter(Mandatory = $true)][string] $Tree,
    # Where the pinned PSES / PSScriptAnalyzer are vendored.
    [string] $DataRoot = '',
    # The host that RUNS the scanner and the staged children (the analysis host is the scanner's own default).
    [string] $HostExe = 'pwsh',
    # Per-scan cap (ms).
    [int] $CapMs = 300000,
    # Skip the live Windows PowerShell 5.1 daemon row of control 5.
    [switch] $SkipLive51
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($DataRoot)) {
    $DataRoot = if (-not [string]::IsNullOrWhiteSpace($env:PSLS_TEST_DATA_DIR)) { $env:PSLS_TEST_DATA_DIR } else { Join-Path ([System.IO.Path]::GetTempPath()) 'psls-sarifscan-test-data' }
}
$scanScript = Join-Path $Tree 'scripts/lsp-scan.ps1'
if (-not (Test-Path -LiteralPath $scanScript -PathType Leaf)) { throw ('no scan script at ' + $scanScript) }
# The INSTRUMENT's own library (this tree's), for Add-ProcessArguments -- never the measured tree's.
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')
$hostPath = (Get-Command $HostExe -ErrorAction Stop).Source

function Invoke-MeasureChild {
    # One child with a cleared plugin environment; both streams drained concurrently.
    param([string[]]$ArgumentList, [hashtable]$ExtraEnv = @{}, [string]$Exe = $hostPath)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe; $psi.UseShellExecute = $false
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
        if (-not $p.WaitForExit($CapMs)) { try { $p.Kill() } catch { }; return @{ ExitCode = -999; Out = ''; Err = 'timeout' } }
        [void]$out.Wait([Math]::Max(1500, $CapMs)); [void]$err.Wait([Math]::Max(1500, $CapMs))
        return @{ ExitCode = $p.ExitCode; Out = $(if ($out.IsCompleted) { [string]$out.Result } else { '' }); Err = $(if ($err.IsCompleted) { [string]$err.Result } else { '' }) }
    } finally { $p.Dispose() }
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('b1bm-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$enc = New-Object System.Text.UTF8Encoding($false)
function New-MeasureFile([string]$Rel, [string]$Text) {
    $p = Join-Path $work $Rel
    New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($p)) | Out-Null
    [System.IO.File]::WriteAllText($p, $Text, $enc)
    return $p
}

function Invoke-MeasureScan {
    # One scan of the measured tree; returns its row facts.
    param([string]$Dir, [string]$Policy = '', [string]$Mode = '', [hashtable]$Env = @{})
    $out = Join-Path $work ('scan-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.sarif')
    $a = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scanScript, (Join-Path $work $Dir), '-Format', 'sarif', '-OutputPath', $out)
    if ($Policy -ne '') { $a += @('-OrgPolicyPath', $Policy) }
    if ($Mode -ne '') { $a += @('-PolicyMode', $Mode) }
    $envx = @{ CLAUDE_PLUGIN_DATA = $DataRoot }
    foreach ($k in @($Env.Keys)) { $envx[$k] = $Env[$k] }
    $run = Invoke-MeasureChild -ArgumentList $a -ExtraEnv $envx
    $results = @(); $exec = $null; $cert = ''; $reasons = @(); $mode = ''; $modeSource = ''; $na = @()
    if (Test-Path -LiteralPath $out) {
        $sarif = [System.IO.File]::ReadAllText($out) | ConvertFrom-Json
        $results = @(@($sarif.runs[0].results) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.ruleId + ':' + [string]$_.level } | Sort-Object -Unique)
        $inv = $sarif.runs[0].invocations[0]
        $exec = [bool]$inv.executionSuccessful
        if ($null -ne $inv.PSObject.Properties['properties']) {
            $pol = $inv.properties.policy
            $cert = [string]$pol.certification; $mode = [string]$pol.mode; $modeSource = [string]$pol.modeSource
            $reasons = @($pol.reasons | ForEach-Object { [string]$_ })
        }
        if ($null -ne $inv.PSObject.Properties['toolExecutionNotifications']) {
            foreach ($n in @($inv.toolExecutionNotifications)) {
                if ($null -ne $n -and $null -ne $n.PSObject.Properties['properties'] -and $null -ne $n.properties.PSObject.Properties['reasons']) {
                    $na += @($n.properties.reasons | ForEach-Object { [string]$_ })
                }
            }
        }
    }
    return [ordered]@{
        exit = [int]$run.ExitCode; executionSuccessful = $exec; certification = $cert; reasons = @($reasons)
        mode = $mode; modeSource = $modeSource; results = @($results); notAnalyzedReasons = @($na | Sort-Object -Unique)
        settingsWarning = ([string]$run.Err -match 'would reject a settings file'); certifiedLine = ([string]$run.Err -match 'CERTIFIED --')
    }
}

function Find-MergedText([string]$Marker) {
    # The text of the merged settings file the daemon wrote for this run (its IncludeRules carries $Marker).
    $dir = Join-Path $DataRoot 'orgpolicy-settings'
    if (-not (Test-Path -LiteralPath $dir)) { return '' }
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'merged-settings-*.psd1' -File | Sort-Object LastWriteTimeUtc -Descending)) {
        $t = [System.IO.File]::ReadAllText($f.FullName)
        if ($t.Contains($Marker)) { return $t }
    }
    return ''
}

function Get-MergedKeys([string]$Text) {
    # The top-level keys of a merged settings text, in order (each '    <Key> = ' line at the first indent).
    if ($Text -eq '') { return '' }
    return ((@([regex]::Matches($Text, '(?m)^    ([A-Za-z]+) = ') | ForEach-Object { $_.Groups[1].Value })) -join ',')
}

# The staged daemon (controls 4 and 5): the tree's own functions, lifted by AST, run in a child.
$stagedDriver = @'
param([string]$Tree, [string]$Work, [string]$Policy, [string]$Repo, [string]$Mode)
$ErrorActionPreference = 'Stop'
. (Join-Path $Tree 'scripts/lib/lsp-common.ps1')
. (Join-Path $Tree 'scripts/lib/lsp-scan-receipt.ps1')
. (Join-Path $Tree 'scripts/lib/lsp-policy.ps1')
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Tree 'scripts/pses-daemon.ps1'), [ref]$null, [ref]$null)
foreach ($name in @('Initialize-PssaSettings', 'Reset-PsesState')) {
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    . ([scriptblock]::Create([string]$fn.Extent.Text))
}
$top = @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$script:policyApplication' })
$startup = [scriptblock]::Create('param($OrgPolicyPath) ' + $top[0].Right.Extent.Text)
function Write-DLog { param([string]$m) }
function Send-Lsp { param($obj) }
function Get-DaemonPsesVersionTag { return 'v4.6.0' }
$OrgPolicyPath = $Policy
$SettingsPath = ''
$Ruleset = 'pses-default'
$DataRoot = Join-Path $Work 'staged-data'
New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null
$script:settingsResolved = $false
$script:settingsPathInUse = ''
$script:buf = New-Object System.Collections.Generic.List[byte]
$script:policyApplication = & $startup $OrgPolicyPath
$file = Join-Path $Repo 'thing.ps1'
$row = [ordered]@{}
if ($Mode -eq 'respawn') {
    Initialize-PssaSettings -FilePath $file -ProjectRoot $Repo
    $row['firstState'] = [string]$script:policyApplication.requiredRules.state
    Reset-PsesState
    function Resolve-PssaSettingsPath { throw 'staged: settings resolution failed for the re-spawned child' }
    Initialize-PssaSettings -FilePath $file -ProjectRoot $Repo
    $row['afterState'] = [string]$script:policyApplication.requiredRules.state
    $row['settingsPathInUse'] = [string]$script:settingsPathInUse
    $daemon = Copy-PolicyApplicationEvidence -Evidence $script:policyApplication -SettingsSha256 (Get-PolicyFileSha256 -Path ([string]$script:settingsPathInUse))
    $declared = Resolve-EffectivePolicy -Path $Policy -Source 'cli'
    $client = New-PolicyAdjudicationEvidence -Resolution $declared -Path $Policy -Mode 'closed'
    $receipt = [ordered]@{
        engine = [ordered]@{ pses = '4.6.0'; pssa = '1.25.0' }
        config = [ordered]@{ state = 'unbound'; observed = [ordered]@{ severityThreshold = 'Hint'; ruleInclude = ''; ruleExclude = ''; perFileCap = 0 } }
        policy = [ordered]@{ state = 'observed'; client = $client; daemon = $daemon }
    }
    $f = [pscustomobject]@{ File = $file; Completeness = 'complete'; Pass = 'pssa'; Receipt = (($receipt | ConvertTo-Json -Depth 8) | ConvertFrom-Json) }
    $c = Test-ScanPolicyCertification -Mode 'closed' -Declared $declared -Files @($f)
    $row['certified'] = [bool]$c.Certified
    $row['reasons'] = @($c.AllReasons)
} else {
    function Resolve-PssaSettingsPath { throw 'staged: Illegal characters in path.' }
    Initialize-PssaSettings -FilePath $file -ProjectRoot $Repo
    $rec1 = ((([ordered]@{ policy = $script:policyApplication }) | ConvertTo-Json -Depth 6) | ConvertFrom-Json).policy
    Initialize-PssaSettings -FilePath $file -ProjectRoot $Repo
    $rec2 = ((([ordered]@{ policy = $script:policyApplication }) | ConvertTo-Json -Depth 6) | ConvertFrom-Json).policy
    $env:CLAUDE_PLUGIN_OPTION_orgPolicy = $Policy
    $i1 = Get-OrgPolicyEnforcementReportInfo -DaemonObservation @{ DataRootKnown = $true; DaemonPresent = $true; Determinable = $true; Policy = $rec1 }
    $i2 = Get-OrgPolicyEnforcementReportInfo -DaemonObservation @{ DataRootKnown = $true; DaemonPresent = $true; Determinable = $true; Policy = $rec2 }
    $row['recordState'] = [string]$rec1.requiredRules.state
    $row['recordStateAfterSecondCall'] = [string]$rec2.requiredRules.state
    $row['enforcementState'] = [string]$i1.enforcement.state
    $row['enforcementReason'] = [string]$i1.enforcement.reason
    $row['enforcementReasonAfterSecondCall'] = [string]$i2.enforcement.reason
}
$row | ConvertTo-Json -Depth 4 -Compress
'@

$liveDriver = @'
param([string]$Tree, [string]$DataRoot, [string]$Policy, [string]$Repo)
$ErrorActionPreference = 'Stop'
. (Join-Path $Tree 'scripts/lib/lsp-common.ps1')
. (Join-Path $Tree 'scripts/lib/lsp-scan-common.ps1')
. (Join-Path $Tree 'scripts/lib/lsp-scan-receipt.ps1')
. (Join-Path $Tree 'scripts/lib/lsp-policy.ps1')
$scripts = Join-Path $Tree 'scripts'
$wps = (Get-Command powershell.exe).Source
$sid = 'b1bm-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$env:CLAUDE_PLUGIN_DATA = $DataRoot
$env:CLAUDE_PLUGIN_OPTION_settingsPath = 'C:\b1b|bad\PSScriptAnalyzerSettings.psd1'
$row = [ordered]@{ daemon = $false; recordState = ''; enforcementState = ''; enforcementReason = '' }
$d = $null
# A Windows PowerShell 5.1 child started from PowerShell 7 inherits PowerShell 7's PSModulePath and cannot
# load its own modules (no Import-PowerShellDataFile; PSES never starts): with the variable absent, 5.1
# computes its own default. This process loads the two modules it needs FIRST, since without the
# variable it could not autoload them either; the variable comes back before doctor runs.
Import-Module Microsoft.PowerShell.Utility, Microsoft.PowerShell.Management
$prevPsmp = $env:PSModulePath
Remove-Item Env:\PSModulePath -ErrorAction SilentlyContinue
try {
    $d = Start-ScanDaemon -ScriptsDir $scripts -DataRoot $DataRoot -SessionId $sid -HostExe $wps -OrgPolicyPath $Policy
    if ($null -ne $d) {
        $row['daemon'] = $true
        [void](Invoke-ScanFileDiagnostics -ScriptsDir $scripts -DataRoot $DataRoot -SessionId $sid -HostExe $wps -FilePath (Join-Path $Repo 'thing.ps1') -Cwd $Repo -OrgPolicyPath $Policy)
        # The daemon rewrites its record on a 10 s heartbeat; 45 s spans several (the out-of-band review read it 30 s after).
        $sf = Join-Path $DataRoot ('session/' + $sid + '.json')
        $rec = $null
        for ($i = 0; $i -lt 90; $i++) {
            try { $rec = (Get-Content -LiteralPath $sf -Raw) | ConvertFrom-Json } catch { $rec = $null }
            if ($null -ne $rec -and $null -ne $rec.PSObject.Properties['policy'] -and [string]$rec.policy.requiredRules.state -ne 'pending') { break }
            Start-Sleep -Milliseconds 500
        }
        if ($null -ne $rec -and $null -ne $rec.PSObject.Properties['policy']) { $row['recordState'] = [string]$rec.policy.requiredRules.state }
        Remove-Item Env:\CLAUDE_PLUGIN_OPTION_settingsPath -ErrorAction SilentlyContinue
        $env:PSModulePath = $prevPsmp
        . (Join-Path $scripts 'doctor.ps1')
        $env:CLAUDE_PLUGIN_OPTION_orgPolicy = $Policy
        $info = Get-OrgPolicyEnforcementReportInfo -DaemonObservation (Get-DoctorDaemonObservation -SessionId $sid)
        $row['enforcementState'] = [string]$info.enforcement.state
        $row['enforcementReason'] = [string]$info.enforcement.reason
    }
} finally {
    Remove-Item Env:\PSModulePath -ErrorAction SilentlyContinue
    Stop-ScanDaemon -ScriptsDir $scripts -DataRoot $DataRoot -SessionId $sid -HostExe $wps -DaemonInfo $d
    $env:PSModulePath = $prevPsmp
}
$row | ConvertTo-Json -Compress
'@

try {
    $marker = 'PSB1bMeasure' + [guid]::NewGuid().ToString('N')
    $thing = "function Set-B1bmGlobal {`n    gci`n    `$global:B1bmThing = 1`n}`n# " + ('x' * 60) + "`n"
    [void](New-MeasureFile 'src-alias/thing.ps1' "function Get-B1bmThing {`n    gci`n}`n")
    [void](New-MeasureFile 'src-bare/thing.ps1' $thing)
    [void](New-MeasureFile 'src-rules/thing.ps1' $thing)
    [void](New-MeasureFile 'src-rules/PSScriptAnalyzerSettings.psd1' ("@{ IncludeRules = @('PSAvoidUsingCmdletAliases', 'PSAvoidLongLines', '" + $marker + "'); Severity = @('Warning', 'Error');" +
            " Rules = @{ PSAvoidLongLines = @{ Enable = `$true; MaximumLineLength = 40 } } }`n"))
    [void](New-MeasureFile 'src-rejected/thing.ps1' $thing)
    [void](New-MeasureFile 'src-rejected/PSScriptAnalyzerSettings.psd1' ("@{ IncludeRules = @('PSAvoidUsingCmdletAliases', '" + $marker + "R'); RuleArguments = @{ PSAvoidUsingCmdletAliases = @{ Enable = `$true } } }`n"))
    $pReq = New-MeasureFile 'required.psd1' "@{ RequiredRules = @('PSAvoidGlobalVars') }`n"
    $pExc = New-MeasureFile 'exclude.psd1' "@{ ExcludeRules = @('PSUseApprovedVerbs') }`n"
    $pMis = Join-Path $work 'missing.psd1'
    $closed = @{ POWERSHELL_LSP_POLICY_MODE = 'closed' }

    $rows = New-Object System.Collections.ArrayList
    function Add-Row([string]$Control, [string]$Name, $Facts) {
        $r = [ordered]@{ control = $Control; name = $Name }
        foreach ($k in @($Facts.Keys)) { $r[$k] = $Facts[$k] }
        [void]$rows.Add($r)
    }

    # control 1 -- the environment variable and the scan's mode (B1-Q03)
    Add-Row 'c1' 'env-closed-undeclared' (Invoke-MeasureScan -Dir 'src-alias' -Env $closed)
    Add-Row 'c1' 'env-closed-declared' (Invoke-MeasureScan -Dir 'src-alias' -Policy $pExc -Env $closed)
    Add-Row 'c1' 'env-closed-missing' (Invoke-MeasureScan -Dir 'src-alias' -Policy $pMis -Env $closed)
    Add-Row 'c1' 'cli-closed-declared' (Invoke-MeasureScan -Dir 'src-alias' -Policy $pExc -Mode 'closed')

    # control 2 -- Rules and Severity through a RequiredRules merge (B1-K04)
    Add-Row 'c2' 'rules-no-policy' (Invoke-MeasureScan -Dir 'src-rules')
    $c2 = Invoke-MeasureScan -Dir 'src-rules' -Policy $pReq -Mode 'closed'
    $c2['mergedKeys'] = Get-MergedKeys (Find-MergedText $marker)
    Add-Row 'c2' 'rules-required-managed' $c2

    # control 3 -- a repository settings file holding a rejected key (B1-K04)
    Add-Row 'c3' 'rejected-managed' (Invoke-MeasureScan -Dir 'src-rejected' -Policy $pExc -Mode 'closed')
    Add-Row 'c3' 'rejected-unmanaged' (Invoke-MeasureScan -Dir 'src-rejected' -Policy $pExc)
    $c3 = Invoke-MeasureScan -Dir 'src-rejected' -Policy $pReq -Mode 'closed'
    $c3['mergedKeys'] = Get-MergedKeys (Find-MergedText ($marker + 'R'))
    Add-Row 'c3' 'rejected-required-managed' $c3

    # controls 4 and 5 -- the staged daemon (B1-K05, B1-OOB-I01)
    $driver = New-MeasureFile 'staged-driver.ps1' $stagedDriver
    foreach ($m in @('respawn', 'doctor')) {
        $run = Invoke-MeasureChild -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $driver, '-Tree', $Tree, '-Work', $work, '-Policy', $pReq, '-Repo', (Join-Path $work 'src-bare'), '-Mode', $m)
        $facts = [ordered]@{ exit = [int]$run.ExitCode }
        $line = @(([string]$run.Out) -split "`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
        if ($line.Count -eq 1) { $o = $line[0] | ConvertFrom-Json; foreach ($p in @($o.PSObject.Properties)) { $facts[$p.Name] = $p.Value } }
        else { $facts['error'] = ([string]$run.Err).Trim() }
        Add-Row $(if ($m -eq 'respawn') { 'c4' } else { 'c5' }) ('staged-' + $m) $facts
    }
    $onWindows = if (Test-Path 'Variable:\IsWindows') { [bool]$IsWindows } else { $true }
    if (-not $SkipLive51 -and $onWindows -and $null -ne (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
        $live = New-MeasureFile 'live-driver.ps1' $liveDriver
        $run = Invoke-MeasureChild -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $live, '-Tree', $Tree, '-DataRoot', $DataRoot, '-Policy', $pReq, '-Repo', (Join-Path $work 'src-bare'))
        $facts = [ordered]@{ exit = [int]$run.ExitCode }
        $line = @(([string]$run.Out) -split "`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
        if ($line.Count -eq 1) { $o = $line[0] | ConvertFrom-Json; foreach ($p in @($o.PSObject.Properties)) { $facts[$p.Name] = $p.Value } }
        else { $facts['error'] = ([string]$run.Err).Trim() }
        Add-Row 'c5' 'live-51-doctor' $facts
    }
    ConvertTo-Json -InputObject @($rows) -Depth 5 -Compress
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
