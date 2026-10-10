#Requires -Version 5.1

# assert-expected-red.ps1 -- the BOUNDED expected-failure oracle for the suite's temporary RED
# exclusions (dispatch 000302, A1).
#
# WHY IT EXISTS. tests/run-tests.ps1 excludes, by default, the tests that were measured RED at the
# A1 head -- so CI stays green while the failures stay recorded. An exclusion is only honest while
# two things stay true: the excluded tests still FAIL, for the reason they were excluded; and
# nothing else hides behind the same tags. A bare "the tagged run exits nonzero" proves neither: a
# crash in setup, a file that discovers nothing, or an unrelated assertion all exit nonzero too.
# This script is the check that tells those apart.
#
# WHAT IT DOES. It reads tests/fixtures/scan-verdict/expected-red.psd1 -- the ONE list of the
# excluded tests, each with its owner tag, its exact Pester ExpandedPath and a regex for the
# assertion message it is expected to fail with -- runs the manifest's files IN FULL (no tag
# filter) in THIS (fresh) process, and ACCEPTS only when ALL of these hold:
#   - no block or container failed (a BeforeAll/AfterAll crash is a setup failure, not a RED);
#   - the files discovered tests, and at least one carries a manifest tag (zero discovery is never
#     an expected failure);
#   - the tagged set equals the declared set, path for path (nothing missing, nothing extra);
#   - every declared test for THIS host ran and FAILED, and its first error message matches the
#     declared regex (an unexpected pass, a skip, or an unrelated failure is rejected);
#   - every declared test for the OTHER host was skipped (Hosts narrows an entry to Core/Desktop);
#   - every UNTAGGED test in the same files passed or was skipped, and at least one passed -- the
#     green complement, so a failure outside the declared set can never hide in this run either.
# Every rejection is printed on its own line as 'REJECT: <KIND>: <detail>'.
#
# Exit codes:
#   0  ACCEPTED -- the excluded tests fail exactly as declared, and only they are excluded.
#   1  REJECTED -- see the REJECT lines.
#   2  usage error -- no manifest, a malformed manifest, or no Pester 5 to run it with.
#
# It never installs anything (run tests/run-tests.ps1 once to bootstrap Pester 5) and never edits a
# file. Run it under BOTH hosts:
#   pwsh -NoProfile -File tests/assert-expected-red.ps1
#   powershell -NoProfile -File tests/assert-expected-red.ps1
#
# ASCII-only (PS 5.1 Windows-1252 trap); StrictMode-safe.
#
# Author: Mike Andersen / powershell-lsp plugin.

[CmdletBinding()]
param(
    # The manifest. Default: tests/fixtures/scan-verdict/expected-red.psd1.
    [string] $ManifestPath = '',
    # The directory the manifest's Files are relative to. Default: this script's directory (tests/).
    [string] $TestsDir = '',
    # Optional: write a JSON evidence record (host, versions, head sha, counts, per-test outcome).
    [string] $EvidencePath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ManifestPath)) { $ManifestPath = Join-Path $PSScriptRoot 'fixtures/scan-verdict/expected-red.psd1' }
if ([string]::IsNullOrWhiteSpace($TestsDir)) { $TestsDir = $PSScriptRoot }

function Write-OracleUsageError([string]$Message) {
    [Console]::Error.WriteLine('assert-expected-red: ' + $Message)
    exit 2
}

if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { Write-OracleUsageError ('manifest not found: ' + $ManifestPath) }
$manifest = $null
try { $manifest = Import-PowerShellDataFile -LiteralPath $ManifestPath } catch { Write-OracleUsageError ('manifest unreadable: ' + $_.Exception.Message) }
foreach ($key in @('Files', 'Tags', 'Expected')) {
    if (-not $manifest.ContainsKey($key)) { Write-OracleUsageError ('manifest has no ' + $key + ' key') }
}
$tags = @($manifest.Tags.Keys | ForEach-Object { [string]$_ } | Sort-Object)
if ($tags.Count -eq 0) { Write-OracleUsageError 'manifest declares no tags' }
$files = @($manifest.Files | ForEach-Object { Join-Path $TestsDir ([string]$_) })
foreach ($f in $files) { if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { Write-OracleUsageError ('test file not found: ' + $f) } }

# Pester bounded to the 5.x major, exactly as tests/run-tests.ps1 bounds it (dispatch 000120).
$p5 = Get-Module -ListAvailable Pester | Where-Object { $_.Version.Major -eq 5 } | Sort-Object Version -Descending | Select-Object -First 1
if ($null -eq $p5) { Write-OracleUsageError 'Pester 5 is not installed (run tests/run-tests.ps1 once to bootstrap it)' }
Import-Module Pester -MinimumVersion 5.0.0 -MaximumVersion 5.99.99 -Force

$edition = [string]$PSVersionTable.PSEdition
$headSha = 'unknown'
if ($null -ne (Get-Command git -ErrorAction SilentlyContinue)) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $s = [string](& git -C $TestsDir rev-parse HEAD 2>$null)
        if ($s -match '^[0-9a-f]{40}$') { $headSha = $s }
    } catch { } finally { $ErrorActionPreference = $prev }
}

$config = New-PesterConfiguration
$config.Run.Path = $files
$config.Run.PassThru = $true
$config.Run.Exit = $false
$config.Output.Verbosity = 'Detailed'
$result = Invoke-Pester -Configuration $config

$rejects = New-Object System.Collections.ArrayList
function Add-OracleReject([string]$Kind, [string]$Detail) {
    [void]$rejects.Add('REJECT: ' + $Kind + ': ' + $Detail)
}
function Get-OracleFirstError($Test) {
    $records = @($Test.ErrorRecord)
    if ($records.Count -eq 0 -or $null -eq $records[0]) { return '' }
    return (([string]$records[0].Exception.Message) -replace "[`r`n]+", ' ')
}

# 1. Setup crashes: a failed container (the file itself) or block (a BeforeAll/AfterAll).
foreach ($c in @($result.Containers | Where-Object { [string]$_.Result -eq 'Failed' -and @($_.ErrorRecord).Count -gt 0 })) {
    Add-OracleReject 'CONTAINER FAILED' ([string]$c.Item + ' -- ' + [string]@($c.ErrorRecord)[0].Exception.Message)
}
foreach ($b in @($result.FailedBlocks)) {
    $msg = if (@($b.ErrorRecord).Count -gt 0) { [string]@($b.ErrorRecord)[0].Exception.Message } else { '' }
    Add-OracleReject 'BLOCK FAILED' ([string]$b.ExpandedPath + ' -- ' + ($msg -replace "[`r`n]+", ' '))
}

# 2. Discovery: everything the files hold, split by whether a test carries a manifest tag.
$all = @($result.Tests)
$selected = @($all | Where-Object { $t = $_; @(@($t.Tag) | Where-Object { $tags -contains [string]$_ }).Count -gt 0 })
$untagged = @($all | Where-Object { $t = $_; @(@($t.Tag) | Where-Object { $tags -contains [string]$_ }).Count -eq 0 })
if ($all.Count -eq 0) { Add-OracleReject 'ZERO DISCOVERY' ('no test was discovered in ' + ($manifest.Files -join ', ')) }
if ($selected.Count -eq 0) { Add-OracleReject 'ZERO DISCOVERY' ('no test in ' + ($manifest.Files -join ', ') + ' carries a tag in ' + ($tags -join ', ')) }

# 3. Identity: the tagged set must equal the declared set.
$declared = @($manifest.Expected)
$declaredPaths = @($declared | ForEach-Object { [string]$_.Path })
$selectedPaths = @($selected | ForEach-Object { [string]$_.ExpandedPath })
foreach ($p in $declaredPaths) { if ($selectedPaths -notcontains $p) { Add-OracleReject 'MISSING' $p } }
foreach ($p in $selectedPaths) { if ($declaredPaths -notcontains $p) { Add-OracleReject 'UNDECLARED' $p } }

# 3b. The green complement: every untagged test must pass (or be skipped), and one must pass.
foreach ($u in $untagged) {
    $r = [string]$u.Result
    if ($r -eq 'Passed' -or $r -eq 'Skipped') { continue }
    $um = Get-OracleFirstError $u
    Add-OracleReject 'UNRELATED FAILURE' ([string]$u.ExpandedPath + ' -- an UNTAGGED test ended ' + $r + $(if ($um) { ': ' + $um } else { '' }))
}
if ($all.Count -gt 0 -and @($untagged | Where-Object { [string]$_.Result -eq 'Passed' }).Count -eq 0) {
    Add-OracleReject 'ZERO DISCOVERY' 'no untagged test passed -- the green complement is empty'
}

# 4. Outcome per declared test.
$rows = New-Object System.Collections.ArrayList
foreach ($e in $declared) {
    $path = [string]$e.Path
    $test = @($selected | Where-Object { [string]$_.ExpandedPath -eq $path }) | Select-Object -First 1
    if ($null -eq $test) { continue }
    $hosts = if ($e.ContainsKey('Hosts')) { @($e.Hosts | ForEach-Object { [string]$_ }) } else { @('Core', 'Desktop') }
    $outcome = [string]$test.Result
    $message = Get-OracleFirstError $test
    if (@($test.Tag) -notcontains [string]$e.Tag) { Add-OracleReject 'WRONG TAG' ($path + ' -- declared ' + [string]$e.Tag + ', carries ' + (@($test.Tag) -join ',')) }
    if ($hosts -contains $edition) {
        if ($outcome -ne 'Failed') {
            Add-OracleReject ('UNEXPECTED ' + $outcome.ToUpperInvariant()) $path
        } elseif (-not [bool]$test.Executed) {
            Add-OracleReject 'NOT EXECUTED' ($path + ' -- failed without running (its setup failed)')
        } elseif ($message -notmatch [string]$e.Message) {
            Add-OracleReject 'UNRELATED FAILURE' ($path + ' -- expected /' + [string]$e.Message + '/, got: ' + $message)
        }
    } elseif ($outcome -ne 'Skipped') {
        Add-OracleReject 'OTHER-HOST TEST NOT SKIPPED' ($path + ' -- declared for ' + ($hosts -join '/') + ', ' + $outcome + ' on ' + $edition)
    }
    [void]$rows.Add([ordered]@{ path = $path; tag = [string]$e.Tag; hosts = $hosts; outcome = $outcome; message = $message })
}

# 5. Report.
$verdict = if ($rejects.Count -eq 0) { 'ACCEPTED' } else { 'REJECTED' }
Write-Host ''
Write-Host ('assert-expected-red: ' + $verdict)
Write-Host ('  host        : ' + $edition + ' ' + [string]$PSVersionTable.PSVersion + ' (Pester ' + [string]$p5.Version + ')')
Write-Host ('  head sha    : ' + $headSha)
Write-Host ('  manifest    : ' + $ManifestPath)
Write-Host ('  tags        : ' + ($tags -join ', '))
Write-Host ('  discovered  : ' + $all.Count + ' test(s) in ' + $files.Count + ' file(s)')
Write-Host ('  tagged      : ' + $selected.Count + ' (declared ' + $declared.Count + ') -- failed ' +
    @($selected | Where-Object { [string]$_.Result -eq 'Failed' }).Count +
    ', passed ' + @($selected | Where-Object { [string]$_.Result -eq 'Passed' }).Count +
    ', skipped ' + @($selected | Where-Object { [string]$_.Result -eq 'Skipped' }).Count)
Write-Host ('  untagged    : ' + $untagged.Count + ' -- passed ' + @($untagged | Where-Object { [string]$_.Result -eq 'Passed' }).Count +
    ', skipped ' + @($untagged | Where-Object { [string]$_.Result -eq 'Skipped' }).Count +
    ', failed ' + @($untagged | Where-Object { [string]$_.Result -eq 'Failed' }).Count)
foreach ($r in $rows) { Write-Host ('  ' + [string]$r.outcome + ' :: ' + [string]$r.path) }
foreach ($line in $rejects) { Write-Host $line }

if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
    $evidence = [ordered]@{
        verdict    = $verdict
        edition    = $edition
        psVersion  = [string]$PSVersionTable.PSVersion
        pester     = [string]$p5.Version
        headSha    = $headSha
        tags       = $tags
        discovered = $all.Count
        tagged     = $selected.Count
        declared   = $declared.Count
        untagged   = $untagged.Count
        untaggedPassed  = @($untagged | Where-Object { [string]$_.Result -eq 'Passed' }).Count
        untaggedSkipped = @($untagged | Where-Object { [string]$_.Result -eq 'Skipped' }).Count
        tests      = @($rows)
        rejects    = @($rejects)
    }
    [System.IO.File]::WriteAllText($EvidencePath, ($evidence | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
}

if ($rejects.Count -gt 0) { exit 1 }
exit 0
