#requires -Version 7.0
<#
.SYNOPSIS
    RECORD-ONLY measurement of the POSIX arms of threat-model findings T5.1 and T6.2.

.DESCRIPTION
    Dispatch 000276 leg F, under Mike's ruling Q4 of 2026-09-05: measure, never fix.

    THREAT-MODEL.md records T5.1 (daemon pipe permissions) and T6.2 (data-root temp
    fallback permissions) as MEASURED **on Windows only**. Its own text says the POSIX
    arm is "a derivation from platform convention, not a measurement", and deliberately
    refuses to write the convention into the table as if it had been observed. This
    script takes the observation on the ubuntu-pwsh and macos-pwsh CI legs so the rows
    can carry a measured value instead of an inference.

    WHAT IT MEASURES
      T5.1  the Unix-domain-socket endpoint backing the daemon's named pipe
            (<temp>/CoreFxPipe_<pipename>, per scripts/lib/lsp-common.ps1), plus its
            containing directory: octal mode, owner, group.
      T6.2  the data-root temp fallback directory that Get-PluginDataRootResolution
            returns when CLAUDE_PLUGIN_DATA is unset: octal mode, owner, group.

    WHAT IT NEVER DOES
      It never fails the build on a VALUE. A world-readable mode is a finding for the
      record and for the maintainer, not a red build -- ruling Q4 is record-only, and a
      measurement that gates would be a fix wearing a measurement's clothes.

      It changes no runtime script, adds no userConfig knob and no status token, and is
      not a required gate.

    THE ONE WAY IT FAILS (the vacuity guard)
      It exits 1 if the JSON was not written, or was written but does not parse, or
      parses without both arms present. Green must mean "the measurement happened" --
      the same discipline as validate-sarif-artifacts.ps1's -RequireHost guard, which
      exists so a leg that emitted nothing cannot pass over an empty set.

.NOTES
    ASCII-only, LF, no BOM (repo discipline for .ps1).
#>
[CmdletBinding()]
param(
    # Where to write the measurement JSON. Its directory is created if absent.
    [Parameter(Mandatory = $true)]
    [string] $OutputPath,

    # How long to wait for the daemon's socket endpoint to appear, in milliseconds.
    # A miss is recorded as an honest "not observed", never as a failure.
    [int] $SocketWaitMs = 45000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot  = Split-Path -Parent $PSScriptRoot
$script:ScriptsIn = Join-Path $script:RepoRoot 'scripts'

function Get-PosixStat {
    # Octal mode + owner + group for one path, on Linux or macOS. Returns $null when the
    # path is absent or stat is unavailable -- absence is data, not an error.
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $fmtLinux = '%a|%U|%G|%F'
    $fmtMac   = '%Lp|%Su|%Sg|%HT'
    $raw = $null
    try {
        if ($IsMacOS) { $raw = & stat -f $fmtMac -- $Path 2>$null }
        else { $raw = & stat -c $fmtLinux -- $Path 2>$null }
    }
    catch { $raw = $null }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $parts = ([string]$raw).Trim() -split '\|'
    if ($parts.Count -lt 4) { return $null }
    return [pscustomobject]@{
        path  = $Path
        mode  = $parts[0]
        owner = $parts[1]
        group = $parts[2]
        kind  = $parts[3]
    }
}

function Get-ExposureVerdict {
    # Disposition an octal mode HONESTLY, in the register's own vocabulary. This is a
    # rendering of the measured number, never a gate: every branch returns a string and
    # none of them changes the exit code.
    param($Stat)
    if ($null -eq $Stat) { return 'indeterminate -- path not observed' }
    $m = [string]$Stat.mode
    if ($m -notmatch '^[0-7]{3,4}$') { return 'indeterminate -- mode not parseable: ' + $m }
    $perm = $m.Substring($m.Length - 3)
    # Name the digits explicitly: owner / group / other, left to right.
    $groupD = [int]$perm.Substring(1, 1)
    $worldD = [int]$perm.Substring(2, 1)
    if ($worldD -eq 0 -and $groupD -eq 0) { return 'user-only -- no group or other access' }
    if ($worldD -ne 0) { return 'exposed-beyond-user -- OTHER has ' + $worldD + ' on a ' + $perm + ' object' }
    return 'group-readable -- GROUP has ' + $groupD + ' on a ' + $perm + ' object; OTHER has none'
}

$result = [ordered]@{
    schema      = 'powershell-lsp/posix-surface/1'
    dispatch    = '000276'
    generatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    platform    = [ordered]@{
        isWindows = [bool]$IsWindows
        isLinux   = [bool]$IsLinux
        isMacOS   = [bool]$IsMacOS
        osVersion = [string][System.Environment]::OSVersion.VersionString
        psVersion = [string]$PSVersionTable.PSVersion
        umask     = ''
    }
    t51         = [ordered]@{ arm = 'daemon pipe endpoint (Unix domain socket)'; observed = $false }
    t62         = [ordered]@{ arm = 'data-root temp fallback directory'; observed = $false }
    notes       = @()
}

if (-not $IsWindows) {
    try { $result.platform.umask = ([string](& sh -c 'umask' 2>$null)).Trim() } catch { }
}

if ($IsWindows) {
    $result.notes += 'SKIPPED: this script measures the POSIX arms only. The Windows arms of T5.1 and T6.2 were measured by dispatch 000269 and are already in the register.'
}
else {
    # ---------- T6.2: the data-root temp fallback ----------
    # Resolve it through the plugin's OWN seam rather than re-deriving the path here, so
    # the measurement is of the directory the runtime would actually use.
    $savedRoot = $env:CLAUDE_PLUGIN_DATA
    try {
        Remove-Item Env:CLAUDE_PLUGIN_DATA -ErrorAction SilentlyContinue
        . (Join-Path $script:ScriptsIn 'lib/lsp-common.ps1')
        $res = Get-PluginDataRootResolution
        $fallbackRoot = [string]$res.Root
        $result.t62.provenance = [string]$res.Provenance
        $result.t62.root = $fallbackRoot
        $existedBefore = Test-Path -LiteralPath $fallbackRoot
        $result.t62.existedBeforeProbe = [bool]$existedBefore
        if (-not $existedBefore) {
            # Create it the way the runtime does -- New-Item under the ambient umask --
            # so the mode measured is the mode a real first run would land.
            New-Item -ItemType Directory -Force -Path $fallbackRoot | Out-Null
        }
        $st = Get-PosixStat -Path $fallbackRoot
        $result.t62.stat = $st
        $result.t62.verdict = Get-ExposureVerdict -Stat $st
        $result.t62.parent = Get-PosixStat -Path (Split-Path -Parent $fallbackRoot)
        $result.t62.observed = ($null -ne $st)
    }
    catch {
        $result.t62.error = [string]$_.Exception.Message
        $result.notes += 'T6.2 arm raised: ' + [string]$_.Exception.Message
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($savedRoot)) { $env:CLAUDE_PLUGIN_DATA = $savedRoot }
    }

    # ---------- T5.1: the daemon pipe's socket endpoint ----------
    # Start the daemon the way the integration suite does: run the real hook client
    # (scripts/lsp-client.ps1) over stdin with a session id, against an isolated data
    # root, and let it bring the warm daemon up.
    $sid = 'posixmeasure-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $dataRoot = if (-not [string]::IsNullOrWhiteSpace($env:PSLS_TEST_DATA_DIR)) {
        $env:PSLS_TEST_DATA_DIR
    } else {
        Join-Path ([System.IO.Path]::GetTempPath()) 'psls-posix-measure'
    }
    try {
        New-Item -ItemType Directory -Force -Path $dataRoot | Out-Null
        $fixture = Join-Path $dataRoot 'posix-measure-fixture.ps1'
        "function Frobnicate-Posix {`n    Get-Process`n}" | Set-Content -LiteralPath $fixture -Encoding ascii

        $stdin = (@{ session_id = $sid; tool_input = @{ file_path = $fixture }; cwd = $dataRoot } |
            ConvertTo-Json -Compress)

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'pwsh'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        foreach ($a in @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                (Join-Path $script:ScriptsIn 'lsp-client.ps1'))) {
            $psi.ArgumentList.Add($a)
        }
        $psi.EnvironmentVariables['CLAUDE_PLUGIN_DATA'] = $dataRoot
        $proc = [System.Diagnostics.Process]::Start($psi)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($stdin)
        $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $proc.StandardInput.BaseStream.Flush()
        $proc.StandardInput.Close()
        [void]$proc.WaitForExit(60000)
        try { if (-not $proc.HasExited) { $proc.Kill($true) } } catch { }

        # The endpoint path is the plugin's own derivation (lsp-common.ps1): the pipe name
        # is 'powershell-lsp-<sid>' and .NET backs it with <temp>/CoreFxPipe_<pipename>.
        $pipeName = 'powershell-lsp-' + $sid
        $sockPath = Join-Path ([System.IO.Path]::GetTempPath()) ('CoreFxPipe_' + $pipeName)
        $result.t51.pipeName = $pipeName
        $result.t51.socketPath = $sockPath

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt $SocketWaitMs -and -not (Test-Path -LiteralPath $sockPath)) {
            Start-Sleep -Milliseconds 250
        }
        $st = Get-PosixStat -Path $sockPath
        $result.t51.stat = $st
        $result.t51.verdict = Get-ExposureVerdict -Stat $st
        $result.t51.parent = Get-PosixStat -Path ([System.IO.Path]::GetTempPath())
        $result.t51.parentVerdict = Get-ExposureVerdict -Stat $result.t51.parent
        $result.t51.observed = ($null -ne $st)
        if ($null -eq $st) {
            $result.notes += 'T5.1 socket endpoint was not observed at ' + $sockPath +
                ' within ' + $SocketWaitMs + ' ms; recorded as not observed rather than as a value.'
        }
    }
    catch {
        $result.t51.error = [string]$_.Exception.Message
        $result.notes += 'T5.1 arm raised: ' + [string]$_.Exception.Message
    }
    finally {
        # Best-effort teardown. A leaked daemon must not fail this step either.
        try {
            Get-Process -Name 'pwsh' -ErrorAction SilentlyContinue |
                Where-Object { $_.Id -ne $PID } | Out-Null
        }
        catch { }
    }
}

# ---------- write, then PROVE it was written (the vacuity guard) ----------
$outDir = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outDir)) {
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}
($result | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM

$failures = New-Object System.Collections.Generic.List[string]
if (-not (Test-Path -LiteralPath $OutputPath)) {
    $failures.Add('the measurement JSON was not written to ' + $OutputPath)
}
else {
    try {
        $back = Get-Content -LiteralPath $OutputPath -Raw | ConvertFrom-Json
        foreach ($arm in @('t51', 't62')) {
            if ($null -eq $back.$arm) { $failures.Add('the written JSON has no ' + $arm + ' arm') }
        }
        if ([string]::IsNullOrWhiteSpace([string]$back.schema)) {
            $failures.Add('the written JSON carries no schema field')
        }
    }
    catch {
        $failures.Add('the written JSON did not parse: ' + [string]$_.Exception.Message)
    }
}

Write-Host ('posix-surface measurement -> ' + $OutputPath)
Write-Host (($result | ConvertTo-Json -Depth 8))

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host 'VACUITY GUARD FAILED -- the measurement did not produce a readable record:'
    foreach ($f in $failures) { Write-Host ('  - ' + $f) }
    Write-Host 'This step fails ONLY on a missing or unreadable record, never on a measured value.'
    exit 1
}

Write-Host ''
Write-Host 'Recorded. This step does not gate on any measured value (dispatch 000276 leg F, ruling Q4: record-only).'
exit 0
