#Requires -Version 5.1
# prove-guard-fix.ps1 -- falsify the REPLACEMENT guard for the release workflow's
# airgap-bundle step, so the fix is not a false green traded for a false red.
#
# Dispatch 000267. ASCII only.
#
# Runs the step's real logic (the script call, the artifact assertion, the zip
# readback) three ways:
#   GREEN -- bundle written -> both checks pass
#   RED 1 -- artifact removed after the build -> the Test-Path guard throws
#   RED 2 -- an entry emptied -> the readback throws
# A guard that cannot fail is the defect being replaced, so each arm must fire.

param(
    [string] $Fix = 'C:\Users\mande\projects\work\nortam\claude-powershell-lsp\worktrees\pslsp-267-fix',
    [string] $SourceDir = 'C:\Users\mande\AppData\Local\Temp\psl-267\airgap\src',
    [string] $Work = 'C:\Users\mande\AppData\Local\Temp\psl-267\guard'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force }
New-Item -ItemType Directory -Path $Work -Force | Out-Null

$v = '1.32.0'
$bundle = Join-Path $Work ("powershell-lsp-airgap-$v.zip")

function Invoke-StepLogic([string] $bundlePath, [switch] $SkipBuild) {
    # The exact shape of the fixed step: build, assert the artifact, read it back.
    if (-not $SkipBuild) {
        & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $Fix 'release/New-AirgapBundle.ps1') `
            -Version $v -RepoRoot $Fix -OutFile $bundlePath -SourceDir $SourceDir | Out-Null
    }
    if (-not (Test-Path -LiteralPath $bundlePath)) {
        throw "New-AirgapBundle.ps1 returned without writing $bundlePath"
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $bundlePath))
    try {
        $names = @($zip.Entries | ForEach-Object { $_.FullName })
        if ($names -notcontains 'MANIFEST.txt') { throw 'airgap bundle is missing MANIFEST.txt' }
        foreach ($e in $zip.Entries) {
            if ($e.Length -le 0) { throw ('airgap bundle entry is empty: ' + $e.FullName) }
        }
        if ($names.Count -lt 3) { throw ('airgap bundle has too few entries: ' + $names.Count) }
        return $names
    } finally { $zip.Dispose() }
}

$results = [ordered]@{}

# --- GREEN --------------------------------------------------------------------
$green = $false; $greenNames = @()
try { $greenNames = Invoke-StepLogic -bundlePath $bundle; $green = $true }
catch { Write-Host ('GREEN arm threw unexpectedly: ' + $_.Exception.Message) }
Write-Host ('GREEN : step logic passed=' + $green + ' entries=' + ($greenNames -join ', '))
$results['green_passed'] = $green
$results['green_entries'] = $greenNames

# --- RED 1: the artifact is gone ----------------------------------------------
$red1 = $false; $red1msg = ''
$backup = $bundle + '.bak'
Copy-Item -LiteralPath $bundle -Destination $backup -Force
Remove-Item -LiteralPath $bundle -Force
try { Invoke-StepLogic -bundlePath $bundle -SkipBuild | Out-Null }
catch { $red1 = $true; $red1msg = $_.Exception.Message }
Write-Host ('RED 1 : missing artifact threw=' + $red1 + ' :: ' + $red1msg)
$results['red1_threw'] = $red1; $results['red1_message'] = $red1msg
Move-Item -LiteralPath $backup -Destination $bundle -Force

# --- RED 2: an entry is emptied -----------------------------------------------
$red2 = $false; $red2msg = ''
$mutant = Join-Path $Work 'mutant.zip'
Copy-Item -LiteralPath $bundle -Destination $mutant -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem
$z = [System.IO.Compression.ZipFile]::Open($mutant, [System.IO.Compression.ZipArchiveMode]::Update)
try {
    $victim = @($z.Entries | Where-Object { $_.FullName -eq 'MANIFEST.txt' })[0]
    $s = $victim.Open(); $s.SetLength(0); $s.Dispose()
} finally { $z.Dispose() }
try { Invoke-StepLogic -bundlePath $mutant -SkipBuild | Out-Null }
catch { $red2 = $true; $red2msg = $_.Exception.Message }
Write-Host ('RED 2 : emptied entry threw=' + $red2 + ' :: ' + $red2msg)
$results['red2_threw'] = $red2; $results['red2_message'] = $red2msg

# --- the OLD guard, for the record --------------------------------------------
# Re-evaluated here so the outbox can state what the replaced line actually did
# rather than reasoning about it.
$oldGuardFires = $null
& pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -Command @"
`$ErrorActionPreference = 'Stop'
& '$($Fix -replace "\\","/")/release/New-AirgapBundle.ps1' -Version $v -RepoRoot '$($Fix -replace "\\","/")' -OutFile '$($Work -replace "\\","/")/old-guard.zip' -SourceDir '$($SourceDir -replace "\\","/")' | Out-Null
if (`$LASTEXITCODE -ne 0) { Write-Output 'OLD-GUARD-FIRES' } else { Write-Output 'OLD-GUARD-QUIET' }
"@ | ForEach-Object { if ($_ -match 'OLD-GUARD') { $oldGuardFires = $_ } }
Write-Host ('OLD   : the replaced `$LASTEXITCODE -ne 0` guard on a successful build -> ' + $oldGuardFires)
$results['old_guard_on_success'] = $oldGuardFires

$ok = ($green -and $red1 -and $red2 -and ($oldGuardFires -eq 'OLD-GUARD-FIRES'))
$results['verdict'] = $(if ($ok) { 'PASS' } else { 'FAIL' })
($results | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath 'C:\Users\mande\AppData\Local\Temp\psl-267\out\guard-fix-proof.json' -Encoding UTF8
Write-Host ''
Write-Host ('GUARD FIX PROOF: ' + $results['verdict'])
if (-not $green) { throw 'the fixed step logic does not pass on a good bundle' }
if (-not $red1)  { throw 'RED 1 FAILED: a missing artifact did not fail the step -- the new guard is vacuous' }
if (-not $red2)  { throw 'RED 2 FAILED: an emptied entry did not fail the readback' }
if ($oldGuardFires -ne 'OLD-GUARD-FIRES') { throw 'the OLD guard did not fire on a successful build -- the diagnosis is wrong' }
