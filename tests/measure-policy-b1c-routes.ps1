#Requires -Version 5.1

# measure-policy-b1c-routes.ps1 -- dispatch 000307 (B1c): the routes B1b's out-of-band review found, where a
# managed scan certified while a rule the organization requires, or one the repository declared, did not
# run -- measured end to end through the REAL daemon, for ANY tree.
#
# A sibling of measure-policy-b1b-corrections.ps1 (whose rows it leaves alone): one fixed set of scans run
# against the tree it is given, one JSON row per scenario, so the base's wrong answers and the corrected
# head's are measured the SAME way. Point it at a git archive of each tree and compare.
#
#   B1b-OOB2-R01  a pattern in the repository's ExcludeRules ('PSAvoidGlobal*', '*', one beside the
#                 repository's own IncludeRules, one over a required configurable rule) that matches a
#                 required rule; and the same pattern beside a CustomRulePath, the case the merge cannot
#                 narrow without the owner's ruling (dispatch 000307, open question R01).
#   B1b-OOB2-R02  a required custom rule named as its findings name it (Module\Measure-Name): where the
#                 merged file names IncludeRules (with and without IncludeDefaultRules), and where the
#                 repository excludes its bare name; and the bare spelling, a control.
#   B1b-OOB2-R03  IncludeRules = @() (no IncludeRules, to PSScriptAnalyzer) beside Rules, managed; and the
#                 same repository unmanaged, a control.
#   B1b-OOB2-R04  a required code with no rule behind it: a misspelled built-in name and a custom rule no
#                 CustomRulePath supplies, managed; and the misspelled name unmanaged.
#
# Correction round 1 (review 6656dadf4a4b; owner rulings 2026-10-17) adds, and flips nothing above but the
# expected head outcome of the R04 rows and of R01 beside a CustomRulePath (now refused):
#   B1c-RV-01     a PSScriptAnalyzerSettings.psd1 nested below the scan root: under lib\, which sorts before
#                 the root's own file, managed and unmanaged; under zz\, which sorts after it; a HIDDEN one
#                 under lib\, which the target list omits; and one in a hidden directory the scan does not
#                 enter (the boundary: nothing in it is analyzed, so it governs nothing).
#   B1c-RV-04     a padded ExcludeRules entry: an exact name and a pattern, each naming no rule as written.
#
# Every scan is a child whose environment has every CLAUDE_PLUGIN_OPTION_* and POWERSHELL_LSP_* variable
# removed, on a PRIVATE data root: a fresh directory seeded (copied) with the pinned PSES and
# PSScriptAnalyzer from -SeedRoot, so no other session's daemon, merged file or session record is in it
# and nothing is downloaded. Its merged settings directory is emptied before each scan, so the merged file
# a row reports is that scan's own. Fixtures and the data root live in a fresh temp directory (prefix
# b1cm-, never psls-) removed afterwards.
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
    # The host that RUNS the scanner and the daemon.
    [string] $HostExe = 'pwsh',
    # The host PSES runs under (lsp-scan.ps1 -PsHost); '' leaves the scanner's own default (pwsh).
    [string] $PsHost = '',
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
# The INSTRUMENT's own library (this tree's), for Add-ProcessArguments and Read-PssaSettingsFile -- never
# the measured tree's.
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

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('b1cm-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
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
$mergedDir = Join-Path $dataRoot 'orgpolicy-settings'

function Get-MeasureMergedFacts {
    # The merged settings file this scan's daemon wrote (the directory was emptied before the scan), read
    # by the instrument's own reader: its top-level keys in the order written, and its IncludeRules and
    # ExcludeRules entry counts (-1 when the key is absent).
    $facts = [ordered]@{ mergedKeys = ''; mergedInclude = -1; mergedExclude = -1; mergedExcludeEntries = '' }
    if (-not (Test-Path -LiteralPath $mergedDir)) { return $facts }
    $files = @(Get-ChildItem -LiteralPath $mergedDir -Filter 'merged-settings-*.psd1' -File)
    if ($files.Count -ne 1) { $facts.mergedKeys = ('(' + $files.Count + ' merged files)'); return $facts }
    $text = [System.IO.File]::ReadAllText($files[0].FullName)
    $facts.mergedKeys = ((@([regex]::Matches($text, '(?m)^    ([A-Za-z]+) = ') | ForEach-Object { $_.Groups[1].Value })) -join ',')
    $read = Read-PssaSettingsFile -Path $files[0].FullName
    if ($read.Entries.Contains('IncludeRules')) { $facts.mergedInclude = @($read.Entries['IncludeRules']).Count }
    if ($read.Entries.Contains('ExcludeRules')) {
        $ex = @($read.Entries['ExcludeRules'])
        $facts.mergedExclude = $ex.Count
        $shown = ($ex -join ',')
        if ($shown.Length -gt 120) { $shown = $shown.Substring(0, 120) + '...' }
        $facts.mergedExcludeEntries = $shown
    }
    return $facts
}

function Invoke-MeasureScan {
    # One scan of the measured tree; returns its row facts.
    param([string]$Dir, [string]$Policy = '', [string]$Mode = '')
    if (Test-Path -LiteralPath $mergedDir) { Get-ChildItem -LiteralPath $mergedDir -File | Remove-Item -Force }
    $out = Join-Path $work ('scan-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.sarif')
    $a = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scanScript, (Join-Path $work $Dir), '-Format', 'sarif', '-OutputPath', $out)
    if ($PsHost -ne '') { $a += @('-PsHost', $PsHost) }
    if ($Policy -ne '') { $a += @('-OrgPolicyPath', $Policy) }
    if ($Mode -ne '') { $a += @('-PolicyMode', $Mode) }
    $run = Invoke-MeasureChild -ArgumentList $a -ExtraEnv @{ CLAUDE_PLUGIN_DATA = $dataRoot }
    $results = @(); $fileResults = @(); $exec = $null; $cert = ''; $reasons = @(); $mode = ''; $na = @()
    if (Test-Path -LiteralPath $out) {
        $sarif = [System.IO.File]::ReadAllText($out) | ConvertFrom-Json
        $res = @(@($sarif.runs[0].results) | Where-Object { $null -ne $_ })
        $results = @($res | ForEach-Object { [string]$_.ruleId + ':' + [string]$_.level } | Sort-Object -Unique)
        # Per file ('<uri>|<ruleId>'), so a row over a nested settings file shows which file governed which file.
        $fileResults = @($res | ForEach-Object { [string]$_.locations[0].physicalLocation.artifactLocation.uri + '|' + [string]$_.ruleId } | Sort-Object -Unique)
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
    $row = [ordered]@{
        exit = [int]$run.ExitCode; executionSuccessful = $exec; certification = $cert; reasons = @($reasons); mode = $mode
        results = @($results); fileResults = @($fileResults); notAnalyzedReasons = @($na | Sort-Object -Unique)
        settingsWarning = ([string]$run.Err -match 'would reject a settings file')
        cannotRunWarning = ([string]$run.Err -match 'a rule the policy requires cannot run')
    }
    $mf = Get-MeasureMergedFacts
    foreach ($k in @($mf.Keys)) { $row[$k] = $mf[$k] }
    return $row
}

try {
    $q = [string][char]39
    # One sample for every row: a plural noun, Write-Host, an alias, a global, a 62-column line.
    $sample = "function Get-Items { param() Write-Host 'x' }`ngci`n`$global:B1cmGlobal = 1`n# " + ('x' * 60) + "`n"
    $long = "gci`n`$global:B1cmGlobal = 1`n# " + ('x' * 130) + "`n"
    # A custom rule that REPORTS (one finding per file): its findings read 'B1cm.Rules\Measure-B1cmReports'.
    $module = New-MeasureFile 'rules/B1cm.Rules.psm1' ((@(
                'function Measure-B1cmReports {'
                '    [CmdletBinding()]'
                '    [OutputType([Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord[]])]'
                '    param([Parameter(Mandatory = $true)][System.Management.Automation.Language.ScriptBlockAst]$ScriptBlockAst)'
                '    if ($null -ne $ScriptBlockAst.Parent) { return @() }'
                '    return @([Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]@{ Message = ''the custom rule ran''; Extent = $ScriptBlockAst.Extent; RuleName = $PSCmdlet.MyInvocation.InvocationName; Severity = ''Warning'' })'
                '}'
                'Export-ModuleMember -Function Measure-B1cmReports') -join "`n") + "`n")
    $cpath = 'CustomRulePath = @(' + $q + $module + $q + ')'
    function New-MeasureRepo([string]$Dir, [string]$Settings, [string]$Code = $sample) {
        [void](New-MeasureFile ($Dir + '/thing.ps1') $Code)
        if ($Settings -ne '') { [void](New-MeasureFile ($Dir + '/PSScriptAnalyzerSettings.psd1') ($Settings + "`n")) }
    }
    # B1b-OOB2-R01
    New-MeasureRepo 'r01-prefix' "@{ ExcludeRules = @('PSAvoidGlobal*') }"
    New-MeasureRepo 'r01-star' "@{ ExcludeRules = @('*') }"
    New-MeasureRepo 'r01-own-include' "@{ IncludeRules = @('PSAvoidUsingCmdletAliases'); ExcludeRules = @('PSAvoidGlobal*') }"
    New-MeasureRepo 'r01-configurable' "@{ ExcludeRules = @('PSAvoidLong*') }" $long
    New-MeasureRepo 'r01-custom-path' ("@{ " + $cpath + "; ExcludeRules = @('PSAvoidGlobal*') }")
    # B1b-OOB2-R02
    New-MeasureRepo 'r02-own-include' ("@{ IncludeRules = @('PSAvoidUsingCmdletAliases'); " + $cpath + '; IncludeDefaultRules = $true }')
    New-MeasureRepo 'r02-own-include-no-default' ("@{ IncludeRules = @('PSAvoidUsingCmdletAliases'); " + $cpath + ' }')
    New-MeasureRepo 'r02-bare-excluded' ("@{ " + $cpath + "; ExcludeRules = @('Measure-B1cmReports') }")
    # B1b-OOB2-R03
    New-MeasureRepo 'r03-empty-include' "@{ IncludeRules = @(); Rules = @{ PSAvoidLongLines = @{ Enable = `$true; MaximumLineLength = 40 } } }"
    # B1b-OOB2-R04: no repository settings file.
    New-MeasureRepo 'r04-none' ''
    # B1c-RV-01: the root's file excludes PSAvoidUsingWriteHost, a nested one PSAvoidUsingCmdletAliases, and both
    # directories hold the same sample -- so each file's findings show which settings file governed it.
    $rootSet = "@{ ExcludeRules = @('PSAvoidUsingWriteHost') }`n"
    $subSet = "@{ ExcludeRules = @('PSAvoidUsingCmdletAliases') }`n"
    foreach ($t in @(@('rv01-first', 'z.ps1', 'lib'), @('rv01-last', 'a.ps1', 'zz'), @('rv01-hidden', 'z.ps1', 'lib'), @('rv01-hidden-dir', 'z.ps1', 'hid'))) {
        [void](New-MeasureFile ($t[0] + '/PSScriptAnalyzerSettings.psd1') $rootSet)
        [void](New-MeasureFile ($t[0] + '/' + $t[1]) $sample)
        [void](New-MeasureFile ($t[0] + '/' + $t[2] + '/PSScriptAnalyzerSettings.psd1') $subSet)
        [void](New-MeasureFile ($t[0] + '/' + $t[2] + '/b.ps1') $sample)
    }
    foreach ($h in @('rv01-hidden/lib/PSScriptAnalyzerSettings.psd1', 'rv01-hidden-dir/hid')) {
        $p = Join-Path $work $h
        [System.IO.File]::SetAttributes($p, ([System.IO.File]::GetAttributes($p) -bor [System.IO.FileAttributes]::Hidden))
    }
    # B1c-RV-04: padded ExcludeRules entries, which name no rule to PSScriptAnalyzer.
    New-MeasureRepo 'rv04-padded-exact' "@{ ExcludeRules = @(' PSAvoidUsingWriteHost ') }"
    New-MeasureRepo 'rv04-padded-pattern' "@{ ExcludeRules = @(' PSAvoid* ') }"
    $pGlobal = New-MeasureFile 'policy-global.psd1' "@{ RequiredRules = @('PSAvoidGlobalVars') }`n"
    $pLong = New-MeasureFile 'policy-longlines.psd1' "@{ RequiredRules = @('PSAvoidLongLines') }`n"
    $pQualified = New-MeasureFile 'policy-qualified.psd1' "@{ RequiredRules = @('B1cm.Rules\Measure-B1cmReports') }`n"
    $pQualifiedGlobal = New-MeasureFile 'policy-qualified-global.psd1' "@{ RequiredRules = @('B1cm.Rules\Measure-B1cmReports', 'PSAvoidGlobalVars') }`n"
    $pBare = New-MeasureFile 'policy-bare.psd1' "@{ RequiredRules = @('Measure-B1cmReports') }`n"
    $pTypo = New-MeasureFile 'policy-typo.psd1' "@{ RequiredRules = @('PSAvoidGlobalVarz') }`n"

    $rows = New-Object System.Collections.ArrayList
    function Add-Row([string]$Finding, [string]$Name, $Facts) {
        $r = [ordered]@{ finding = $Finding; name = $Name }
        foreach ($k in @($Facts.Keys)) { $r[$k] = $Facts[$k] }
        [void]$rows.Add($r)
    }
    Add-Row 'B1b-OOB2-R01' 'r01-prefix-managed' (Invoke-MeasureScan -Dir 'r01-prefix' -Policy $pGlobal -Mode 'closed')
    Add-Row 'B1b-OOB2-R01' 'r01-star-managed' (Invoke-MeasureScan -Dir 'r01-star' -Policy $pGlobal -Mode 'closed')
    Add-Row 'B1b-OOB2-R01' 'r01-own-include-managed' (Invoke-MeasureScan -Dir 'r01-own-include' -Policy $pGlobal -Mode 'closed')
    Add-Row 'B1b-OOB2-R01' 'r01-configurable-managed' (Invoke-MeasureScan -Dir 'r01-configurable' -Policy $pLong -Mode 'closed')
    Add-Row 'B1b-OOB2-R01' 'r01-custom-path-managed' (Invoke-MeasureScan -Dir 'r01-custom-path' -Policy $pGlobal -Mode 'closed')
    Add-Row 'B1b-OOB2-R02' 'r02-qualified-own-include-managed' (Invoke-MeasureScan -Dir 'r02-own-include' -Policy $pQualified -Mode 'closed')
    Add-Row 'B1b-OOB2-R02' 'r02-qualified-own-include-no-default-managed' (Invoke-MeasureScan -Dir 'r02-own-include-no-default' -Policy $pQualifiedGlobal -Mode 'closed')
    Add-Row 'B1b-OOB2-R02' 'r02-qualified-bare-excluded-managed' (Invoke-MeasureScan -Dir 'r02-bare-excluded' -Policy $pQualified -Mode 'closed')
    Add-Row 'B1b-OOB2-R02' 'r02-bare-own-include-managed' (Invoke-MeasureScan -Dir 'r02-own-include' -Policy $pBare -Mode 'closed')
    Add-Row 'B1b-OOB2-R03' 'r03-empty-include-managed' (Invoke-MeasureScan -Dir 'r03-empty-include' -Policy $pGlobal -Mode 'closed')
    Add-Row 'B1b-OOB2-R03' 'r03-empty-include-unmanaged' (Invoke-MeasureScan -Dir 'r03-empty-include')
    Add-Row 'B1b-OOB2-R04' 'r04-unknown-builtin-managed' (Invoke-MeasureScan -Dir 'r04-none' -Policy $pTypo -Mode 'closed')
    Add-Row 'B1b-OOB2-R04' 'r04-custom-not-supplied-managed' (Invoke-MeasureScan -Dir 'r04-none' -Policy $pQualified -Mode 'closed')
    Add-Row 'B1b-OOB2-R04' 'r04-unknown-builtin-unmanaged' (Invoke-MeasureScan -Dir 'r04-none' -Policy $pTypo)
    Add-Row 'B1c-RV-01' 'rv01-nested-first-managed' (Invoke-MeasureScan -Dir 'rv01-first' -Policy $pGlobal -Mode 'closed')
    Add-Row 'B1c-RV-01' 'rv01-nested-last-managed' (Invoke-MeasureScan -Dir 'rv01-last' -Policy $pGlobal -Mode 'closed')
    Add-Row 'B1c-RV-01' 'rv01-nested-first-unmanaged' (Invoke-MeasureScan -Dir 'rv01-first' -Policy $pGlobal)
    Add-Row 'B1c-RV-01' 'rv01-hidden-nested-managed' (Invoke-MeasureScan -Dir 'rv01-hidden' -Policy $pGlobal -Mode 'closed')
    Add-Row 'B1c-RV-01' 'rv01-hidden-dir-managed' (Invoke-MeasureScan -Dir 'rv01-hidden-dir' -Policy $pGlobal -Mode 'closed')
    Add-Row 'B1c-RV-04' 'rv04-padded-exact-managed' (Invoke-MeasureScan -Dir 'rv04-padded-exact' -Policy $pGlobal -Mode 'closed')
    Add-Row 'B1c-RV-04' 'rv04-padded-pattern-managed' (Invoke-MeasureScan -Dir 'rv04-padded-pattern' -Policy $pGlobal -Mode 'closed')
    ConvertTo-Json -InputObject @($rows) -Depth 5 -Compress
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
