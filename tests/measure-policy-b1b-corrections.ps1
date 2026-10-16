#Requires -Version 5.1

# measure-policy-b1b-corrections.ps1 -- dispatch 000306 (B1b), correction rounds 1 and 2: the findings of
# reviews 656a3e78 and 2bd58763 measured end to end through the REAL daemon, for ANY tree.
#
# A sibling of measure-policy-b1b-controls.ps1 (whose rows it leaves alone): one fixed set of scans run
# against the tree it is given, one JSON row per scenario, so the reviewed candidate's wrong answers and
# the corrected head's are measured the SAME way. Point it at a git archive of each tree and compare.
#
#   B1b-R01  a REQUIRED rule a repository switches off (Rules.PSUseSingularNouns.Enable = $false), and a
#            required configurable rule that is off by default (PSAvoidLongLines, no repository file):
#            managed scans that certify must report the rule.
#   B1b-K01  a repository CustomRulePath that reaches no rule source ('~/*.<nothing>'): a managed scan
#            must refuse (policy-settings-rejected) rather than certify an empty result -- with a
#            RequiredRules policy and with an ExcludeRules-only one.
#   B1b-K02  a repository CustomRulePath naming a real rule module, beside a required BUILT-IN rule: a
#            managed scan that certifies must report the required rule.
#   B1b-R02  (unmanaged) a parenthesized ExcludeRules list: honored, with no settings warning.
#   B1b-I01  (managed) a [uint32] rule argument under a RequiredRules merge: the merged file is valid and
#            the configured rule runs.
#   B1b-R03  (round 2, managed) repository files that name no IncludeRules, under a RequiredRules merge:
#            the ExcludeRules-plus-Rules shape (its ExcludeRules also names the required rule) and a
#            CustomRulePath whose rule reports. A scan that certifies must report the repository's own
#            rules beside the required one.
#
# Every scan is a child whose environment has every CLAUDE_PLUGIN_OPTION_* and POWERSHELL_LSP_* variable
# removed, on a PRIVATE data root: a fresh directory seeded (copied) with the pinned PSES and
# PSScriptAnalyzer from -SeedRoot, so no other session's daemon, merged file or session record is in it
# and nothing is downloaded. Fixtures and the data root live in a fresh temp directory (prefix b1bm-,
# never psls-) removed afterwards.
#
# Not a *.Tests.ps1 file: Pester never collects it. ASCII-only.
#
# Author: Mike Andersen / powershell-lsp plugin.

[CmdletBinding()]
param(
    # Root of the tree under measurement (its scripts/ is what runs).
    [Parameter(Mandatory = $true)][string] $Tree,
    # A provisioned data root to seed the private one from (default: the suite's shared scan data root).
    [string] $SeedRoot = '',
    # The host that RUNS the scanner (the analysis host is the scanner's own default).
    [string] $HostExe = 'pwsh',
    # Per-scan cap (ms).
    [int] $CapMs = 300000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($SeedRoot)) {
    $SeedRoot = if (-not [string]::IsNullOrWhiteSpace($env:PSLS_TEST_DATA_DIR)) { $env:PSLS_TEST_DATA_DIR } else { Join-Path ([System.IO.Path]::GetTempPath()) 'psls-sarifscan-test-data' }
}
$scanScript = Join-Path $Tree 'scripts/lsp-scan.ps1'
if (-not (Test-Path -LiteralPath $scanScript -PathType Leaf)) { throw ('no scan script at ' + $scanScript) }
$seedItems = @('PowerShellEditorServices', 'pses-v4.6.0.ok', 'modules/PSScriptAnalyzer/1.25.0', 'modules/.pssa-1.25.0.ok')
foreach ($s in $seedItems) {
    if (-not (Test-Path -LiteralPath (Join-Path $SeedRoot $s))) { throw ('the seed data root lacks ' + $s + ': ' + $SeedRoot) }
}
# The INSTRUMENT's own library (this tree's), for Add-ProcessArguments -- never the measured tree's.
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')
$hostPath = (Get-Command $HostExe -ErrorAction Stop).Source

function Invoke-MeasureChild {
    # One child with a cleared plugin environment; both streams drained concurrently.
    param([string[]]$ArgumentList, [hashtable]$ExtraEnv = @{})
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $hostPath; $psi.UseShellExecute = $false
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

# The private data root: the pinned PSES and PSScriptAnalyzer, copied, and nothing else.
$dataRoot = Join-Path $work 'data'
New-Item -ItemType Directory -Force -Path (Join-Path $dataRoot 'modules/PSScriptAnalyzer') | Out-Null
Copy-Item -LiteralPath (Join-Path $SeedRoot 'PowerShellEditorServices') -Destination (Join-Path $dataRoot 'PowerShellEditorServices') -Recurse
Copy-Item -LiteralPath (Join-Path $SeedRoot 'pses-v4.6.0.ok') -Destination (Join-Path $dataRoot 'pses-v4.6.0.ok')
Copy-Item -LiteralPath (Join-Path $SeedRoot 'modules/PSScriptAnalyzer/1.25.0') -Destination (Join-Path $dataRoot 'modules/PSScriptAnalyzer/1.25.0') -Recurse
Copy-Item -LiteralPath (Join-Path $SeedRoot 'modules/.pssa-1.25.0.ok') -Destination (Join-Path $dataRoot 'modules/.pssa-1.25.0.ok')

function Invoke-MeasureScan {
    # One scan of the measured tree; returns its row facts.
    param([string]$Dir, [string]$Policy = '', [string]$Mode = '')
    $out = Join-Path $work ('scan-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.sarif')
    $a = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scanScript, (Join-Path $work $Dir), '-Format', 'sarif', '-OutputPath', $out)
    if ($Policy -ne '') { $a += @('-OrgPolicyPath', $Policy) }
    if ($Mode -ne '') { $a += @('-PolicyMode', $Mode) }
    $run = Invoke-MeasureChild -ArgumentList $a -ExtraEnv @{ CLAUDE_PLUGIN_DATA = $dataRoot }
    $results = @(); $exec = $null; $cert = ''; $reasons = @(); $mode = ''; $na = @()
    if (Test-Path -LiteralPath $out) {
        $sarif = [System.IO.File]::ReadAllText($out) | ConvertFrom-Json
        $results = @(@($sarif.runs[0].results) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.ruleId + ':' + [string]$_.level } | Sort-Object -Unique)
        $inv = $sarif.runs[0].invocations[0]
        $exec = [bool]$inv.executionSuccessful
        if ($null -ne $inv.PSObject.Properties['properties']) {
            $pol = $inv.properties.policy
            $cert = [string]$pol.certification; $mode = [string]$pol.mode
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
        exit = [int]$run.ExitCode; executionSuccessful = $exec; certification = $cert; reasons = @($reasons); mode = $mode
        results = @($results); notAnalyzedReasons = @($na | Sort-Object -Unique)
        settingsWarning = ([string]$run.Err -match 'would reject a settings file')
    }
}

try {
    $q = [char]39
    $globalCode = "`$global:B1bmGlobal = 1`ngci`n"
    # B1b-R01: the review's own scenario -- a plural noun the required PSUseSingularNouns reports.
    [void](New-MeasureFile 'r01-disabled/thing.ps1' "function Get-Items { param() 'x' }`n")
    [void](New-MeasureFile 'r01-disabled/PSScriptAnalyzerSettings.psd1' "@{ Rules = @{ PSUseSingularNouns = @{ Enable = `$false } } }`n")
    # B1b-R01 (the ruling): a required configurable rule that is off by default; no repository file.
    [void](New-MeasureFile 'r01-off-by-default/thing.ps1' ("gci`n# " + ('x' * 130) + "`n"))
    # B1b-K01: the review's one-line repository file.
    [void](New-MeasureFile 'k01-ruleless/thing.ps1' $globalCode)
    [void](New-MeasureFile 'k01-ruleless/PSScriptAnalyzerSettings.psd1' "@{ CustomRulePath = @('~/*.b1bm-review-nomatch') }`n")
    # B1b-K02: a real rule module the repository names, beside a required built-in rule.
    $module = New-MeasureFile 'rules/B1bm.Rules.psm1' ("function Measure-B1bmNothing {`n    param([Parameter(Mandatory = `$true)][System.Management.Automation.Language.ScriptBlockAst]`$ScriptBlockAst)`n    return @()`n}`n" +
        "Export-ModuleMember -Function Measure-B1bmNothing`n")
    [void](New-MeasureFile 'k02-custom/thing.ps1' $globalCode)
    [void](New-MeasureFile 'k02-custom/PSScriptAnalyzerSettings.psd1' ("@{ CustomRulePath = @(" + $q + $module + $q + ") }`n"))
    # B1b-R02: a parenthesized ExcludeRules list.
    [void](New-MeasureFile 'r02-paren/thing.ps1' "gci`nWrite-Host 'x'`n")
    [void](New-MeasureFile 'r02-paren/PSScriptAnalyzerSettings.psd1' "@{ ExcludeRules = ('PSAvoidUsingCmdletAliases', 'PSAvoidUsingWriteHost') }`n")
    # B1b-I01: a [uint32] line length under a RequiredRules merge.
    [void](New-MeasureFile 'i01-numeric/thing.ps1' ("gci`n`$global:B1bmGlobal = 1`n# " + ('x' * 60) + "`n"))
    [void](New-MeasureFile 'i01-numeric/PSScriptAnalyzerSettings.psd1' "@{ IncludeRules = @('PSAvoidLongLines', 'PSAvoidUsingCmdletAliases'); Rules = @{ PSAvoidLongLines = @{ Enable = `$true; MaximumLineLength = [uint32]40 } } }`n")
    # B1b-R03 (correction round 2): repository files that name no IncludeRules. The ExcludeRules-plus-Rules
    # shape -- its ExcludeRules also names the required rule -- over a plural noun, Write-Host and a 62-column
    # line; and a CustomRulePath whose rule REPORTS (one finding per file).
    [void](New-MeasureFile 'r03-exclude-rules/thing.ps1' ("function Get-Items { param() Write-Host 'x' }`ngci`n`$global:B1bmGlobal = 1`n# " + ('x' * 60) + "`n"))
    [void](New-MeasureFile 'r03-exclude-rules/PSScriptAnalyzerSettings.psd1' "@{ ExcludeRules = @('PSAvoidUsingCmdletAliases', 'PSAvoidGlobalVars'); Rules = @{ PSAvoidLongLines = @{ Enable = `$true; MaximumLineLength = 40 } } }`n")
    $reporting = New-MeasureFile 'rules-r03/B1bmR03.Rules.psm1' ((@(
                'function Measure-B1bmR03Reports {'
                '    [CmdletBinding()]'
                '    [OutputType([Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord[]])]'
                '    param([Parameter(Mandatory = $true)][System.Management.Automation.Language.ScriptBlockAst]$ScriptBlockAst)'
                '    if ($null -ne $ScriptBlockAst.Parent) { return @() }'
                '    return @([Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]@{ Message = ''the repository rule ran''; Extent = $ScriptBlockAst.Extent; RuleName = $PSCmdlet.MyInvocation.InvocationName; Severity = ''Warning'' })'
                '}'
                'Export-ModuleMember -Function Measure-B1bmR03Reports') -join "`n") + "`n")
    [void](New-MeasureFile 'r03-custom/thing.ps1' $globalCode)
    [void](New-MeasureFile 'r03-custom/PSScriptAnalyzerSettings.psd1' ("@{ CustomRulePath = @(" + $q + $reporting + $q + ") }`n"))
    $pSingular = New-MeasureFile 'policy-singular.psd1' "@{ RequiredRules = @('PSUseSingularNouns') }`n"
    $pLong = New-MeasureFile 'policy-longlines.psd1' "@{ RequiredRules = @('PSAvoidLongLines') }`n"
    $pGlobal = New-MeasureFile 'policy-global.psd1' "@{ RequiredRules = @('PSAvoidGlobalVars') }`n"
    $pExclude = New-MeasureFile 'policy-exclude.psd1' "@{ ExcludeRules = @('PSUseApprovedVerbs') }`n"

    $rows = New-Object System.Collections.ArrayList
    function Add-Row([string]$Finding, [string]$Name, $Facts) {
        $r = [ordered]@{ finding = $Finding; name = $Name }
        foreach ($k in @($Facts.Keys)) { $r[$k] = $Facts[$k] }
        [void]$rows.Add($r)
    }
    Add-Row 'B1b-R01' 'r01-required-disabled-managed' (Invoke-MeasureScan -Dir 'r01-disabled' -Policy $pSingular -Mode 'closed')
    Add-Row 'B1b-R01' 'r01-required-off-by-default-managed' (Invoke-MeasureScan -Dir 'r01-off-by-default' -Policy $pLong -Mode 'closed')
    Add-Row 'B1b-K01' 'k01-ruleless-required-managed' (Invoke-MeasureScan -Dir 'k01-ruleless' -Policy $pGlobal -Mode 'closed')
    Add-Row 'B1b-K01' 'k01-ruleless-exclude-managed' (Invoke-MeasureScan -Dir 'k01-ruleless' -Policy $pExclude -Mode 'closed')
    Add-Row 'B1b-K02' 'k02-custom-required-managed' (Invoke-MeasureScan -Dir 'k02-custom' -Policy $pGlobal -Mode 'closed')
    Add-Row 'B1b-R02' 'r02-parenthesized-unmanaged' (Invoke-MeasureScan -Dir 'r02-paren')
    Add-Row 'B1b-I01' 'i01-numeric-required-managed' (Invoke-MeasureScan -Dir 'i01-numeric' -Policy $pGlobal -Mode 'closed')
    Add-Row 'B1b-R03' 'r03-exclude-rules-required-managed' (Invoke-MeasureScan -Dir 'r03-exclude-rules' -Policy $pGlobal -Mode 'closed')
    Add-Row 'B1b-R03' 'r03-custom-rule-required-managed' (Invoke-MeasureScan -Dir 'r03-custom' -Policy $pGlobal -Mode 'closed')
    ConvertTo-Json -InputObject @($rows) -Depth 5 -Compress
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
