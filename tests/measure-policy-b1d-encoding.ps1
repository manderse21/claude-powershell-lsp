#Requires -Version 5.1

# measure-policy-b1d-encoding.ps1 -- dispatch 000308 (B1d): how each host reads the merged settings file when
# it holds a character outside ASCII, measured end to end through the REAL daemon, for ANY tree.
#
# A sibling of measure-policy-b1c-routes.ps1 (whose rows it leaves alone): one fixed set of scans run against
# the tree it is given, one JSON row per scenario, so the base's answers and the corrected head's are measured
# the SAME way. Point it at a git archive of each tree, once per host, and compare.
#
#   B1c-RR-02   a repository IncludeRules entry spelling PSMisleadingBacktick with the KELVIN SIGN (U+212A, which
#               PSScriptAnalyzer folds to k), managed under RequiredRules; and the same repository with no
#               policy, a control (no merge).
#   B1c-RX-12   the same spelling in the repository's ExcludeRules, managed; and with no policy, a control.
#   B1c enc 1/3 a repository CustomRulePath whose directory is named r + U+00E8 + gles, managed and unmanaged
#               (the merge runs in both); and the same with an ASCII directory name, a control.
#   controls    an all-ASCII repository file, and no repository file at all, managed: the merged file must be
#               byte for byte what it was.
#   boundary    the Kelvin IncludeRules entry in a repository file saved WITHOUT a BOM, managed and with no
#               policy: Windows PowerShell 5.1 reads such a file itself as Windows-1252, merged or not.
#
# Repository settings files are saved WITH a UTF-8 BOM unless the row says otherwise, so each host reads the
# repository's own file the same way and any difference between hosts is the merged file's.
#
# Each row reports the scan's exit, certification, reasons, findings and stderr warnings, and the merged file the
# scan's daemon wrote: its name, whether it opens with a BOM, the SHA-256 of its bytes, its rule-list entries
# decoded as UTF-8 ('utf8'), and the same entries as THIS host's parser reads the file ('hostRead') -- the
# instrument runs on the host given as -HostExe, so with -HostExe powershell -PsHost powershell that is how the
# 5.1 daemon and PSES read it. Characters outside printable ASCII are shown as \uXXXX.
#
# Every scan is a child whose environment has every CLAUDE_PLUGIN_OPTION_* and POWERSHELL_LSP_* variable
# removed, on a PRIVATE data root: a fresh directory seeded (copied) with the pinned PSES and PSScriptAnalyzer
# from -SeedRoot, so no other session's daemon, merged file or session record is in it and nothing is
# downloaded. Its merged settings directory is emptied before each scan, so the merged file a row reports is
# that scan's own. Fixtures and the data root live in a fresh temp directory (prefix b1dm-, never psls-)
# removed afterwards.
#
# Not a *.Tests.ps1 file: Pester never collects it. ASCII-only (each non-ASCII character is built with [char]).
#
# Author: Mike Andersen / powershell-lsp plugin.

[CmdletBinding(PositionalBinding = $false)]
param(
    # Root of the tree under measurement (its scripts/ is what runs).
    [Parameter(Mandatory = $true)][string] $Tree,
    # A provisioned data root to seed the private one from (default: the suite's shared scan data root).
    [string] $SeedRoot = '',
    # The host that RUNS the instrument's children: the scanner and the daemon.
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
# The INSTRUMENT's own library (this tree's), for Add-ProcessArguments and Get-Sha256HexFromBytes -- never the
# measured tree's.
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

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('b1dm-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$enc = New-Object System.Text.UTF8Encoding($false)
$encBom = New-Object System.Text.UTF8Encoding($true)
function New-MeasureFile([string]$Rel, [string]$Text, [switch]$Bom) {
    $p = Join-Path $work $Rel
    New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($p)) | Out-Null
    [System.IO.File]::WriteAllText($p, $Text, $(if ($Bom) { $encBom } else { $enc }))
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

function ConvertTo-MeasureShown([string]$Text) {
    # $Text with every character outside printable ASCII shown as \uXXXX, so a row is ASCII and a decode shows.
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        if ([int]$ch -lt 0x20 -or [int]$ch -gt 0x7E) { [void]$sb.Append(('\u{0:X4}' -f [int]$ch)) } else { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}

function Get-MeasureListEntries($Ast) {
    # IncludeRules, ExcludeRules and CustomRulePath of the first table in $Ast, each entry shown (above) and
    # joined by '|', or '-' when the key is absent; '(no table)' when there is none.
    $facts = [ordered]@{ include = '-'; exclude = '-'; customRulePath = '-' }
    $tables = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $false))
    if ($tables.Count -eq 0) { $facts.include = '(no table)'; return $facts }
    $data = $tables[0].SafeGetValue()
    foreach ($pair in @(@('IncludeRules', 'include'), @('ExcludeRules', 'exclude'), @('CustomRulePath', 'customRulePath'))) {
        foreach ($k in @($data.Keys)) {
            if ([string]::Equals([string]$k, $pair[0], [System.StringComparison]::OrdinalIgnoreCase)) {
                $facts[$pair[1]] = ((@($data[$k]) | ForEach-Object { ConvertTo-MeasureShown ([string]$_) }) -join '|')
            }
        }
    }
    return $facts
}

function Get-MeasureMergedFacts {
    # The merged settings file this scan's daemon wrote (the directory was emptied before the scan): its name,
    # whether it opens with the UTF-8 BOM, the SHA-256 of its bytes, its entries decoded as UTF-8, and its
    # entries as this host's parser reads the file.
    $facts = [ordered]@{ mergedName = ''; mergedBom = $null; mergedSha256 = ''; utf8 = $null; hostRead = $null }
    if (-not (Test-Path -LiteralPath $mergedDir)) { return $facts }
    $files = @(Get-ChildItem -LiteralPath $mergedDir -Filter 'merged-settings-*.psd1' -File)
    if ($files.Count -ne 1) { $facts.mergedName = ('(' + $files.Count + ' merged files)'); return $facts }
    $path = $files[0].FullName
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $facts.mergedName = $files[0].Name
    $facts.mergedBom = $bom
    $facts.mergedSha256 = Get-Sha256HexFromBytes -Bytes $bytes
    $skip = $(if ($bom) { 3 } else { 0 })
    $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes, $skip, $bytes.Length - $skip)
    $t = $null; $e = $null
    $facts.utf8 = Get-MeasureListEntries ([System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$t, [ref]$e))
    $facts.hostRead = Get-MeasureListEntries ([System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$t, [ref]$e))
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
    $results = @(); $exec = $null; $cert = ''; $reasons = @(); $mode = ''
    if (Test-Path -LiteralPath $out) {
        $sarif = [System.IO.File]::ReadAllText($out) | ConvertFrom-Json
        $res = @(@($sarif.runs[0].results) | Where-Object { $null -ne $_ })
        $results = @($res | ForEach-Object { [string]$_.ruleId + ':' + [string]$_.level } | Sort-Object -Unique)
        $inv = $sarif.runs[0].invocations[0]
        $exec = [bool]$inv.executionSuccessful
        if ($null -ne $inv.PSObject.Properties['properties']) {
            $pol = $inv.properties.policy
            $cert = [string]$pol.certification; $mode = [string]$pol.mode
            $reasons = @($pol.reasons | ForEach-Object { [string]$_ })
        }
    }
    $row = [ordered]@{
        exit = [int]$run.ExitCode; executionSuccessful = $exec; certification = $cert; reasons = @($reasons); mode = $mode
        results = @($results)
        settingsWarning = ([string]$run.Err -match 'would reject a settings file')
        cannotRunWarning = ([string]$run.Err -match 'a rule the policy requires cannot run')
    }
    $mf = Get-MeasureMergedFacts
    foreach ($k in @($mf.Keys)) { $row[$k] = $mf[$k] }
    return $row
}

try {
    $q = [string][char]39
    $kelvinTick = 'PSMisleadingBac' + [string][char]0x212A + 'tick'
    # One sample for every row: a plural noun, Write-Host, an alias, a global, a misleading backtick.
    $sample = "function Get-Items { param() Write-Host 'x' }`ngci`n`$global:B1dmGlobal = 1`nWrite-Output 'a' `` `n'b'`n"
    # A custom rule that REPORTS (one finding per file), under a non-ASCII directory and under an ASCII one.
    $ruleText = ((@(
                'function Measure-B1dmReports {'
                '    [CmdletBinding()]'
                '    [OutputType([Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord[]])]'
                '    param([Parameter(Mandatory = $true)][System.Management.Automation.Language.ScriptBlockAst]$ScriptBlockAst)'
                '    if ($null -ne $ScriptBlockAst.Parent) { return @() }'
                '    return @([Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]@{ Message = ''the custom rule ran''; Extent = $ScriptBlockAst.Extent; RuleName = $PSCmdlet.MyInvocation.InvocationName; Severity = ''Warning'' })'
                '}'
                'Export-ModuleMember -Function Measure-B1dmReports') -join "`n") + "`n")
    $moduleNonAscii = New-MeasureFile ('r' + [string][char]0x00E8 + 'gles/B1dm.Rules.psm1') $ruleText
    $moduleAscii = New-MeasureFile 'regles/B1dm.Rules.psm1' $ruleText
    function New-MeasureRepo([string]$Dir, [string]$Settings, [switch]$NoBom) {
        [void](New-MeasureFile ($Dir + '/thing.ps1') $sample)
        if ($Settings -ne '') { [void](New-MeasureFile ($Dir + '/PSScriptAnalyzerSettings.psd1') ($Settings + "`n") -Bom:(-not $NoBom)) }
    }
    New-MeasureRepo 'kelvin-include' ("@{ IncludeRules = @('PSAvoidUsingCmdletAliases', " + $q + $kelvinTick + $q + ') }')
    New-MeasureRepo 'kelvin-exclude' ('@{ ExcludeRules = @(' + $q + $kelvinTick + $q + ') }')
    New-MeasureRepo 'nonascii-custom-path' ('@{ CustomRulePath = @(' + $q + $moduleNonAscii + $q + '); IncludeDefaultRules = $true }')
    New-MeasureRepo 'ascii-custom-path' ('@{ CustomRulePath = @(' + $q + $moduleAscii + $q + '); IncludeDefaultRules = $true }') -NoBom
    New-MeasureRepo 'ascii' "@{ IncludeRules = @('PSAvoidUsingCmdletAliases', 'PSMisleadingBacktick'); ExcludeRules = @('PSAvoidUsingWriteHost') }" -NoBom
    New-MeasureRepo 'none' ''
    New-MeasureRepo 'kelvin-include-nobom' ("@{ IncludeRules = @('PSAvoidUsingCmdletAliases', " + $q + $kelvinTick + $q + ') }') -NoBom
    $pGlobal = New-MeasureFile 'policy-global.psd1' "@{ RequiredRules = @('PSAvoidGlobalVars') }`n"

    $rows = New-Object System.Collections.ArrayList
    function Add-Row([string]$Finding, [string]$Name, $Facts) {
        $r = [ordered]@{ finding = $Finding; name = $Name }
        foreach ($k in @($Facts.Keys)) { $r[$k] = $Facts[$k] }
        [void]$rows.Add($r)
    }
    Add-Row 'B1c-RR-02' 'rr02-kelvin-include-managed' (Invoke-MeasureScan -Dir 'kelvin-include' -Policy $pGlobal -Mode 'closed')
    Add-Row 'B1c-RR-02' 'rr02-kelvin-include-no-policy' (Invoke-MeasureScan -Dir 'kelvin-include')
    Add-Row 'B1c-RX-12' 'rx12-kelvin-exclude-managed' (Invoke-MeasureScan -Dir 'kelvin-exclude' -Policy $pGlobal -Mode 'closed')
    Add-Row 'B1c-RX-12' 'rx12-kelvin-exclude-no-policy' (Invoke-MeasureScan -Dir 'kelvin-exclude')
    Add-Row 'B1c-enc-1' 'enc1-nonascii-custom-path-managed' (Invoke-MeasureScan -Dir 'nonascii-custom-path' -Policy $pGlobal -Mode 'closed')
    Add-Row 'B1c-enc-1' 'enc1-nonascii-custom-path-unmanaged' (Invoke-MeasureScan -Dir 'nonascii-custom-path' -Policy $pGlobal)
    Add-Row 'control' 'ctl-ascii-custom-path-managed' (Invoke-MeasureScan -Dir 'ascii-custom-path' -Policy $pGlobal -Mode 'closed')
    Add-Row 'control' 'ctl-ascii-managed' (Invoke-MeasureScan -Dir 'ascii' -Policy $pGlobal -Mode 'closed')
    Add-Row 'control' 'ctl-no-settings-managed' (Invoke-MeasureScan -Dir 'none' -Policy $pGlobal -Mode 'closed')
    Add-Row 'boundary' 'bnd-kelvin-include-nobom-managed' (Invoke-MeasureScan -Dir 'kelvin-include-nobom' -Policy $pGlobal -Mode 'closed')
    Add-Row 'boundary' 'bnd-kelvin-include-nobom-no-policy' (Invoke-MeasureScan -Dir 'kelvin-include-nobom')
    ConvertTo-Json -InputObject @($rows) -Depth 5 -Compress
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
