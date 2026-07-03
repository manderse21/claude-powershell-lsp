#Requires -Version 5.1
param(
    [Parameter(Mandatory = $true)][ValidateSet('shim', 'off')][string]$Mode,
    [Parameter(Mandatory = $true)][ValidateSet('session', 'crash')][string]$Scenario,
    [Parameter(Mandatory = $true)][string]$DataRoot,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [switch]$RunNav
)

# ServeShim.Driver.ps1 -- runs ONE ServeShim e2e scenario end to end and writes a FLAT result
# object (JSON) to -ResultPath. Meant to be launched as a PWSH subprocess by the Pester e2e
# BeforeAll (dispatch 000103): the interactive client<->shim stdio must be driven by pwsh, because a
# Windows PowerShell 5.1 host's interactive writes to a child's stdin do NOT deliver on the headless
# windows-powershell CI runner (they arrive only on close). Running the driver under pwsh -- on EVERY
# leg -- keeps the driving pwsh<->pwsh (the shim host is pwsh too, matching production) while the
# leg's Pester (pwsh or 5.1) merely spawns this driver and reads the result file. The PURE LIB is
# still validated under 5.1 by the unit Describes.
#
# ASCII-only. Author: Mike Andersen / powershell-lsp plugin.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$testsDir = $PSScriptRoot
$repoRoot = Split-Path -Parent $testsDir
. (Join-Path $repoRoot 'scripts/lib/lsp-common.ps1')
. (Join-Path $repoRoot 'scripts/lib/serve-shim-common.ps1')
. (Join-Path $testsDir 'ServeShim.Common.ps1')
$env:CLAUDE_PLUGIN_DATA = $DataRoot
$scriptsDir = Join-Path $repoRoot 'scripts'

$flat = @{ Launched = $false; Error = '' }
try {
    if ($Scenario -eq 'crash') {
        $c = Invoke-ServeShimCrash -ScriptsDir $scriptsDir -Interpreter 'pwsh' -DataRoot $DataRoot
        $flat = @{
            Launched             = [bool]$c.Launched
            PsesPid              = [int]$c.PsesPid
            ShimExitedAfterCrash = [bool]$c.ShimExitedAfterCrash
            PsesReaped           = [bool]$c.PsesReaped
            Error                = [string]$c.Error
        }
    } else {
        $r = Invoke-ServeShimSession -ScriptsDir $scriptsDir -Interpreter 'pwsh' -Mode $Mode -DataRoot $DataRoot -RunNav:$RunNav
        # Derive flat, JSON-friendly assertions (null results count as 0, not the PS @($null)=1 quirk).
        $hoverResult = Get-Prop $r.Hover 'result'
        $hoverOk = ($null -ne $hoverResult) -and ($null -ne (Get-Prop $hoverResult 'contents'))
        $defResult = Get-Prop $r.Definition 'result'
        $defCount = if ($null -eq $defResult) { 0 } else { @($defResult).Count }
        $refResult = Get-Prop $r.References 'result'
        $refCount = if ($null -eq $refResult) { 0 } else { @($refResult).Count }
        $flat = @{
            Launched         = [bool]$r.Launched
            Error            = [string]$r.Error
            InitNotNull      = ($null -ne $r.InitResult)
            InitHasStaticNav = [bool]$r.InitHasStaticNav
            HoverOk          = [bool]$hoverOk
            DefinitionCount  = [int]$defCount
            ReferencesCount  = [int]$refCount
            LeaksCount       = @($r.Leaks).Count
            Leaks            = @($r.Leaks)
            MaxNavMs         = [int]$r.MaxNavMs
            HoverMs          = [int]$r.Timings['hover']
            DefinitionMs     = [int]$r.Timings['definition']
            ReferencesMs     = [int]$r.Timings['references']
            Exited           = [bool]$r.Exited
            PsesReaped       = [bool]$r.PsesReaped
        }
    }
} catch {
    $flat = @{ Launched = $false; Error = ('driver: ' + [string]$_.Exception.Message) }
}
[System.IO.File]::WriteAllText($ResultPath, ($flat | ConvertTo-Json -Depth 5 -Compress), (New-Object System.Text.UTF8Encoding($false)))
