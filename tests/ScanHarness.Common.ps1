#Requires -Version 5.1

# ScanHarness.Common.ps1 -- shared harness for the scan-verdict (F1) and scan read-only (F2)
# suites (dispatch 000302, A1): tests/PowerShellLsp.ScanVerdict.Tests.ps1 and
# tests/PowerShellLsp.ScanReadOnly.Tests.ps1. NOT a *.Tests.ps1 file, so Pester discovery never
# collects it. Defines functions only; no side effects on import. Dot-source it AFTER
# scripts/lib/lsp-common.ps1, scripts/lib/lsp-scan-common.ps1 and tests/Integration.Common.ps1,
# whose helpers it calls.
#
# WHAT IS FAKED, AND WHERE THE REAL CODE RUNS. The production scanner spawns its hooks by PATH:
# Invoke-ScanFileDiagnostics runs <ScriptsDir>/lsp-client.ps1, Start-ScanDaemon runs
# <ScriptsDir>/session-start.ps1, and scripts/lsp-scan.ps1 passes its OWN directory as
# ScriptsDir. That path is the only seam the shipped code has, and this harness uses it in two
# ways without editing anything under scripts/:
#   - New-SvFakeScriptsDir builds a contained scripts directory whose lsp-client.ps1 is a fake
#     from tests/fixtures/scan-verdict/. The REAL Invoke-ScanFileDiagnostics and the REAL
#     Invoke-ScanHook then spawn it exactly as they spawn the real client.
#   - New-SvCliTree builds a RELOCATED COPY of the scan CLI: scripts/lsp-scan.ps1 and the two
#     libraries it dot-sources, byte-for-byte (SHA-256 verified at copy time), beside fake hooks.
#     Running that copy exercises the shipped CLI's exit-code and SARIF code unchanged. What it
#     cannot exercise is the real hooks behind it; that limit is stated where it is used.
#
# THE ONE SPAWNER. Every child process this harness runs and WAITS on goes through
# Invoke-SvChildProcess (Hub Rule 18). It drains stdout AND stderr concurrently, starting both
# reads before any wait, bounds the drain by the caller's cap, and returns a RECORD -- never a
# bare string -- so a cap kill (ExitCode -999, Err 'timeout') can never be mistaken for a clean
# silent exit. tests/PowerShellLsp.HookInstrumentation.Tests.ps1 reads this file and holds it to
# that shape.
#
# ASCII-only (PS 5.1 reads a UTF-8-without-BOM file through the Windows-1252 codepage; keep to
# bytes 0x00-0x7F -- "--" not an em-dash, straight quotes only).
#
# Author: Mike Andersen / powershell-lsp plugin.

function Get-SvTestsDir {
    # tests/ -- $PSScriptRoot inside a function resolves to the file that DEFINES it, on both hosts.
    return $PSScriptRoot
}

function Get-SvRepoRoot {
    return (Split-Path -Parent (Get-SvTestsDir))
}

function Get-SvFixturePath {
    param([Parameter(Mandatory = $true)][string]$Name)
    return (Join-Path (Join-Path (Get-SvTestsDir) 'fixtures/scan-verdict') $Name)
}

function New-SvTempRoot {
    # A transient psls*-leafed root under the OS temp dir, carrying the suite's ownership marker
    # so the janitor can prove it ours (Set-PslsOwnerMarker, dispatch 000295). Remove it with
    # Remove-SvTempRoot.
    param([Parameter(Mandatory = $true)][string]$Tag, [string]$MintingFile = 'tests/ScanHarness.Common.ps1')
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('psls-sv' + $Tag + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    Set-PslsOwnerMarker -DataRoot $root -MintingFile $MintingFile
    return $root
}

function Remove-SvTempRoot {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (Test-Path -LiteralPath $Path) { Remove-PslsRootWithRetry -Path $Path }
}

function Get-SvSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [string](Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Save-SvAmbientEnv {
    # Remove every CLAUDE_PLUGIN_OPTION_* and POWERSHELL_LSP_* variable from THIS process and
    # return them, so the children the scanner spawns -- which inherit this process's environment
    # wholesale -- start from a known-empty configuration. Restore with Restore-SvAmbientEnv.
    # A developer running the suite inside a configured Claude Code session would otherwise leak
    # their real knob values into every case, which is exactly the contamination F2 is about.
    $saved = @{}
    foreach ($entry in @([System.Environment]::GetEnvironmentVariables().GetEnumerator())) {
        $n = [string]$entry.Key
        if ($n.StartsWith('CLAUDE_PLUGIN_OPTION_', [System.StringComparison]::OrdinalIgnoreCase) -or
            $n.StartsWith('POWERSHELL_LSP_', [System.StringComparison]::OrdinalIgnoreCase)) {
            $saved[$n] = [string]$entry.Value
        }
    }
    foreach ($n in @($saved.Keys)) { [System.Environment]::SetEnvironmentVariable($n, $null) }
    return $saved
}

function Restore-SvAmbientEnv {
    # Undo Save-SvAmbientEnv: clear whatever CLAUDE_PLUGIN_OPTION_* / POWERSHELL_LSP_* a test set,
    # then put the saved values back.
    param([hashtable]$Saved)
    foreach ($entry in @([System.Environment]::GetEnvironmentVariables().GetEnumerator())) {
        $n = [string]$entry.Key
        if ($n.StartsWith('CLAUDE_PLUGIN_OPTION_', [System.StringComparison]::OrdinalIgnoreCase) -or
            $n.StartsWith('POWERSHELL_LSP_', [System.StringComparison]::OrdinalIgnoreCase)) {
            [System.Environment]::SetEnvironmentVariable($n, $null)
        }
    }
    if ($null -eq $Saved) { return }
    foreach ($n in @($Saved.Keys)) { [System.Environment]::SetEnvironmentVariable($n, [string]$Saved[$n]) }
}

function Set-SvAmbientOption {
    # Set (or, with an empty value, clear) CLAUDE_PLUGIN_OPTION_<Key> in THIS process, which every
    # child the scanner spawns inherits. Used to stage HOSTILE ambient configuration.
    param([Parameter(Mandatory = $true)][string]$Key, [string]$Value = '')
    $name = 'CLAUDE_PLUGIN_OPTION_' + $Key
    if ([string]::IsNullOrEmpty($Value)) { [System.Environment]::SetEnvironmentVariable($name, $null) }
    else { [System.Environment]::SetEnvironmentVariable($name, $Value) }
}

function New-SvFakeScriptsDir {
    # A contained scripts directory for the REAL scanner functions to spawn into:
    #   <Root>/scripts/lsp-client.ps1    <- tests/fixtures/scan-verdict/<ClientFixture>
    #   <Root>/scripts/session-start.ps1 <- fake-session-start.ps1 (records + reports ready)
    #   <Root>/scripts/session-end.ps1   <- fake-session-end.ps1
    #   <Root>/scripts/lib/lsp-common.ps1 <- the REAL library, so a fake that needs a production
    #                                        helper dot-sources it exactly as the real client does.
    # Returns the scripts directory. -ClientFixture '' leaves lsp-client.ps1 ABSENT on purpose
    # (the missing-client case).
    param([Parameter(Mandatory = $true)][string]$Root, [string]$ClientFixture = '')
    $scripts = Join-Path $Root 'scripts'
    New-Item -ItemType Directory -Force -Path (Join-Path $scripts 'lib') | Out-Null
    $repo = Get-SvRepoRoot
    Copy-Item -LiteralPath (Join-Path $repo 'scripts/lib/lsp-common.ps1') -Destination (Join-Path $scripts 'lib/lsp-common.ps1') -Force
    Copy-Item -LiteralPath (Get-SvFixturePath 'fake-session-start.ps1') -Destination (Join-Path $scripts 'session-start.ps1') -Force
    Copy-Item -LiteralPath (Get-SvFixturePath 'fake-session-end.ps1') -Destination (Join-Path $scripts 'session-end.ps1') -Force
    if (-not [string]::IsNullOrWhiteSpace($ClientFixture)) {
        Copy-Item -LiteralPath (Get-SvFixturePath $ClientFixture) -Destination (Join-Path $scripts 'lsp-client.ps1') -Force
    }
    return $scripts
}

function New-SvCliTree {
    # A RELOCATED COPY of the scan CLI with fake hooks beside it:
    #   <Root>/scripts/lsp-scan.ps1, <Root>/scripts/lib/lsp-common.ps1,
    #   <Root>/scripts/lib/lsp-scan-common.ps1 and <Root>/.claude-plugin/plugin.json are BYTE COPIES
    #   of the shipped files -- each one's SHA-256 is compared with its source and the build throws
    #   on any difference, so the code under test is provably the shipped code;
    #   session-start.ps1 / session-end.ps1 / lsp-client.ps1 are the fakes (New-SvFakeScriptsDir).
    # lsp-scan.ps1 resolves every hook from its OWN directory ($PSScriptRoot), so the copy runs the
    # shipped exit-code + SARIF logic against the fakes. Returns @{ Root; ScanScript; ScriptsDir; Copies }.
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$ClientFixture)
    $scripts = New-SvFakeScriptsDir -Root $Root -ClientFixture $ClientFixture
    $repo = Get-SvRepoRoot
    New-Item -ItemType Directory -Force -Path (Join-Path $Root '.claude-plugin') | Out-Null
    $pairs = @(
        @{ Rel = 'scripts/lsp-scan.ps1' }
        @{ Rel = 'scripts/lib/lsp-common.ps1' }
        @{ Rel = 'scripts/lib/lsp-scan-common.ps1' }
        @{ Rel = '.claude-plugin/plugin.json' }
    )
    $copies = New-Object System.Collections.ArrayList
    foreach ($pair in $pairs) {
        $src = Join-Path $repo $pair.Rel
        $dst = Join-Path $Root $pair.Rel
        Copy-Item -LiteralPath $src -Destination $dst -Force
        $srcHash = Get-SvSha256 -Path $src
        $dstHash = Get-SvSha256 -Path $dst
        if ($srcHash -ne $dstHash) { throw ('New-SvCliTree: copy of ' + $pair.Rel + ' is not byte-identical to the shipped file') }
        [void]$copies.Add([pscustomobject]@{ Rel = $pair.Rel; Sha256 = $srcHash })
    }
    return @{ Root = $Root; ScanScript = (Join-Path $scripts 'lsp-scan.ps1'); ScriptsDir = $scripts; Copies = @($copies) }
}

function Stop-SvProcessTree {
    # Kill a child AND its descendants on either host. Process.Kill($true) -- the tree kill --
    # exists only on .NET Core 3.0+; on Windows PowerShell 5.1 (.NET Framework) that call throws a
    # MethodException, which is the very gap the S7 census case measures in the PRODUCTION
    # Invoke-ScanHook. So fall back to taskkill /T on Windows, then to a single-process Kill().
    param([Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process)
    try { $Process.Kill($true); return } catch { }
    if (Test-OnWindows) {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { & taskkill.exe /PID $Process.Id /T /F *> $null } catch { } finally { $ErrorActionPreference = $prev }
    }
    try { if (-not $Process.HasExited) { $Process.Kill() } } catch { }
}

function Invoke-SvChildProcess {
    # THE spawner for every child this harness runs and waits on (see the file header). Returns
    #   @{ ExitCode; Out; Err; TimedOut; ElapsedMs }
    # A cap kill returns ExitCode = -999, Err = 'timeout', TimedOut = $true -- distinct from every
    # exit a child can make on its own. Both redirected streams are drained CONCURRENTLY: each
    # ReadToEndAsync starts before stdin is written and before any wait, so a child that fills
    # one pipe while the parent waits on the other can never deadlock (the stderr-flood case,
    # S3b, is that deadlock reproduced against the production spawner, which never reads stderr).
    # -RemoveEnvPrefix strips inherited variables (by prefix) from the child's environment block
    # only; this process's own environment is untouched.
    param(
        [Parameter(Mandatory = $true)][string]$HostExe,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [string]$StdinText = '',
        [int]$CapMs = 120000,
        [hashtable]$ExtraEnv,
        [string[]]$RemoveEnvPrefix = @()
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $HostExe; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    Add-ProcessArguments $psi $ArgumentList
    foreach ($prefix in @($RemoveEnvPrefix | Where-Object { $_ })) {
        foreach ($name in @($psi.EnvironmentVariables.Keys)) {
            if (([string]$name).StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $psi.EnvironmentVariables.Remove([string]$name)
            }
        }
    }
    if ($ExtraEnv) { foreach ($k in $ExtraEnv.Keys) { $psi.EnvironmentVariables[$k] = [string]$ExtraEnv[$k] } }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = [System.Diagnostics.Process]::Start($psi)
    try {
        $stdoutTask = $p.StandardOutput.ReadToEndAsync()
        $stderrTask = $p.StandardError.ReadToEndAsync()
        if (-not [string]::IsNullOrEmpty($StdinText)) {
            $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($StdinText)
            $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
            $p.StandardInput.BaseStream.Flush()
        }
        $p.StandardInput.Close()
        if (-not $p.WaitForExit($CapMs)) {
            Stop-SvProcessTree -Process $p
            return @{ ExitCode = -999; Out = ''; Err = 'timeout'; TimedOut = $true; ElapsedMs = [int]$sw.ElapsedMilliseconds }
        }
        # The child has exited, so both drains end at EOF once the pipes empty; bounded by the
        # caller's cap (the 000283 rule), floored at 1500 ms.
        [void]$stdoutTask.Wait([Math]::Max(1500, $CapMs))
        [void]$stderrTask.Wait([Math]::Max(1500, $CapMs))
        $out = if ($stdoutTask.IsCompleted) { [string]$stdoutTask.Result } else { '' }
        $err = if ($stderrTask.IsCompleted) { [string]$stderrTask.Result } else { '' }
        return @{ ExitCode = $p.ExitCode; Out = $out; Err = $err; TimedOut = $false; ElapsedMs = [int]$sw.ElapsedMilliseconds }
    } finally {
        $p.Dispose()
    }
}

function Stop-SvChildFromPidFile {
    # Reap a fake child that recorded its own pid (s3b / s7). Returns $true when it was still
    # alive and had to be killed here -- i.e. the scanner's cap kill had NOT terminated it.
    param([Parameter(Mandatory = $true)][string]$PidFile)
    if (-not (Test-Path -LiteralPath $PidFile)) { return $false }
    $childPid = 0
    try { $childPid = [int]([System.IO.File]::ReadAllText($PidFile).Trim()) } catch { $childPid = 0 }
    if ($childPid -le 0) { return $false }
    $proc = Get-Process -Id $childPid -ErrorAction SilentlyContinue
    if ($null -eq $proc) { return $false }
    try { Stop-Process -Id $childPid -Force -ErrorAction Stop } catch { }
    Wait-Process -Id $childPid -Timeout 10 -ErrorAction SilentlyContinue
    return $true
}

function Test-SvPidAlive {
    # $true when the pid recorded in $PidFile is a running process, allowing up to $GraceMs for a
    # process that was just killed to finish exiting.
    param([Parameter(Mandatory = $true)][string]$PidFile, [int]$GraceMs = 5000)
    if (-not (Test-Path -LiteralPath $PidFile)) { return $false }
    $childPid = 0
    try { $childPid = [int]([System.IO.File]::ReadAllText($PidFile).Trim()) } catch { $childPid = 0 }
    if ($childPid -le 0) { return $false }
    if ($null -eq (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) { return $false }
    Wait-Process -Id $childPid -Timeout ([Math]::Max(1, [int]($GraceMs / 1000))) -ErrorAction SilentlyContinue
    return ($null -ne (Get-Process -Id $childPid -ErrorAction SilentlyContinue))
}

function Set-SvRelaunchCooldown {
    # Stamp the real client's auto-relaunch cooldown for $SessionId (scripts/lsp-client.ps1,
    # Start-DaemonRelaunchIfRecoverable: a stamp younger than 30 s suppresses the relaunch). With
    # it in place the REAL client can never launch a REAL daemon from a reachability case; at
    # worst it renders its could-not-restart banner, which the case then reads in the log.
    param([Parameter(Mandatory = $true)][string]$DataRoot, [Parameter(Mandatory = $true)][string]$SessionId)
    $dir = Join-Path $DataRoot 'session'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Set-Content -LiteralPath (Join-Path $dir ($SessionId + '.relaunch')) -Value ([string]$PID) -Encoding ascii -Force
}

function Start-SvFakePipeDaemon {
    # Start tests/fixtures/scan-verdict/fake-pipe-daemon.ps1 for $SessionId, answering every
    # request with $Response, and wait until its pipe is PRESENT (Test-DaemonPipePresent, the same
    # probe the real client asks). Its stdout/stderr go to files (OS-level redirection), so it can
    # never hold this process's standard handles. Returns @{ Pid; PipeName; RequestLog; ErrFile }.
    # Throws when it does not come up -- a reachability case without its daemon measures nothing.
    param(
        [Parameter(Mandatory = $true)][string]$HostExe,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$WorkDir,
        [Parameter(Mandatory = $true)][string]$Response,
        [int]$LifetimeMs = 120000,
        [int]$ReadyTimeoutMs = 30000
    )
    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    $responseFile = Join-Path $WorkDir 'response.json'
    $readyFile = Join-Path $WorkDir 'ready.pid'
    $requestLog = Join-Path $WorkDir 'requests.log'
    $outFile = Join-Path $WorkDir 'daemon.out'
    $errFile = Join-Path $WorkDir 'daemon.err'
    [System.IO.File]::WriteAllText($responseFile, $Response + "`n", (New-Object System.Text.UTF8Encoding($false)))
    $lib = Join-Path (Get-SvRepoRoot) 'scripts/lib/lsp-common.ps1'
    $proc = Start-Process -FilePath $HostExe -PassThru -NoNewWindow `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
        -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Get-SvFixturePath 'fake-pipe-daemon.ps1'),
            '-SessionId', $SessionId, '-ResponseFile', $responseFile, '-ReadyFile', $readyFile,
            '-RequestLog', $requestLog, '-LibPath', $lib, '-LifetimeMs', [string]$LifetimeMs)
    $pipeName = Get-DaemonPipeName -SessionId $SessionId
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $ReadyTimeoutMs) {
        if ((Test-Path -LiteralPath $readyFile) -and (Test-DaemonPipePresent -PipeName $pipeName)) {
            return @{ Pid = $proc.Id; PipeName = $pipeName; RequestLog = $requestLog; ErrFile = $errFile }
        }
        if ($proc.HasExited) { break }
        Start-Sleep -Milliseconds 100
    }
    $err = if (Test-Path -LiteralPath $errFile) { [System.IO.File]::ReadAllText($errFile) } else { '' }
    try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { }
    throw ('fake pipe daemon for ' + $SessionId + ' did not come up within ' + $ReadyTimeoutMs + ' ms; stderr: ' + $err)
}

function Stop-SvFakePipeDaemon {
    # Kill a fake pipe daemon and, off-Windows, unlink the socket file a killed .NET pipe server
    # leaves behind (Get-DaemonPipeSocketPath; a SIGKILL never runs the server's Dispose).
    param($Daemon)
    if ($null -eq $Daemon) { return }
    try { Stop-Process -Id ([int]$Daemon.Pid) -Force -ErrorAction SilentlyContinue } catch { }
    Wait-Process -Id ([int]$Daemon.Pid) -Timeout 10 -ErrorAction SilentlyContinue
    $sock = Get-DaemonPipeSocketPath -PipeName ([string]$Daemon.PipeName)
    if (-not [string]::IsNullOrWhiteSpace($sock) -and (Test-Path -LiteralPath $sock)) {
        Remove-Item -LiteralPath $sock -Force -ErrorAction SilentlyContinue
    }
}

function Read-SvTextFile {
    # A file's text, or '' when it does not exist (never throws).
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return '' }
    try { return [System.IO.File]::ReadAllText($Path) } catch { return '' }
}

function Get-SvFindingKeys {
    # Order-free identity of a finding set: sorted 'ruleId@line:col' strings, for the shape
    # Invoke-ScanFileDiagnostics returns. Comparing these is what "the same findings" means here.
    param([object[]]$Findings)
    $keys = @(@($Findings) | Where-Object { $null -ne $_ } |
            ForEach-Object { [string](Get-Prop $_ 'ruleId') + '@' + [int](Get-Prop $_ 'line') + ':' + [int](Get-Prop $_ 'col') })
    return @($keys | Sort-Object)
}

function Get-SvSarifKeys {
    # The same identity for a SARIF log's results (ruleId @ startLine : startColumn).
    param($Sarif)
    if ($null -eq $Sarif) { return @() }
    $keys = @(@($Sarif.runs[0].results) | Where-Object { $null -ne $_ } | ForEach-Object {
            $region = $_.locations[0].physicalLocation.region
            [string]$_.ruleId + '@' + [int]$region.startLine + ':' + [int]$region.startColumn
        })
    return @($keys | Sort-Object)
}

function Get-SvFormatMatrix {
    # The read-only census matrix: every interactive profile x every formatOnEdit state a scanner's
    # environment can carry ('unset' = no formatOnEdit variable at all). ClientResolves is the format
    # mode the CURRENT client resolves for the cell: an explicit value always wins, and profiles
    # 'recommended' and 'strict' map formatOnEdit=suggest when it is unset (Get-PluginProfileMap,
    # scripts/lib/lsp-common.ps1; no profile maps apply). It records the classification MEASURED at
    # the A1 head, never the desired behaviour -- the census asserts 'off' for every cell.
    $cells = New-Object System.Collections.ArrayList
    foreach ($p in @('safe', 'recommended', 'strict')) {
        foreach ($m in @('unset', 'off', 'suggest', 'apply')) {
            $resolves = $m
            if ($m -eq 'unset') { $resolves = if ($p -eq 'safe') { 'off' } else { 'suggest' } }
            [void]$cells.Add(@{ Name = ($p + '/' + $m); ProfileName = $p; Mode = $m; ClientResolves = $resolves })
        }
    }
    return @($cells)
}

function Set-SvFormatCellEnv {
    # Stage one matrix cell in THIS process's environment (the scanner's children inherit it):
    # CLAUDE_PLUGIN_OPTION_profile always, CLAUDE_PLUGIN_OPTION_formatOnEdit unless the cell is 'unset'.
    param([Parameter(Mandatory = $true)][string]$ProfileName, [Parameter(Mandatory = $true)][string]$Mode)
    Set-SvAmbientOption -Key 'profile' -Value $ProfileName
    if ($Mode -eq 'unset') { Set-SvAmbientOption -Key 'formatOnEdit' -Value '' }
    else { Set-SvAmbientOption -Key 'formatOnEdit' -Value $Mode }
}

function Invoke-SvScanCase {
    # One census measurement at the HELPER boundary: build a contained fake scripts directory
    # around $ClientFixture, write the target file, optionally REMOVE it again (source
    # disappearance), and run the PRODUCTION Invoke-ScanFileDiagnostics over it. Returns
    #   @{ Root; DataRoot; Target; Result; ClientLog; PidFile }
    # Result is exactly what scripts/lsp-scan.ps1 receives for that file. -ScriptsDir overrides the
    # fake directory (the reachability cases pass the REAL scripts/ directory).
    param(
        [Parameter(Mandatory = $true)][string]$HostExe,
        [Parameter(Mandatory = $true)][string]$Tag,
        [string]$ClientFixture = '',
        [string]$ScriptsDir = '',
        [string]$SessionId = '',
        [string]$TargetContent = "function Get-SvTarget {`n    [CmdletBinding()]`n    param([string]`$Name)`n    Write-Output `$Name`n}`n",
        [switch]$RemoveTarget,
        [int]$CapMs = 25000,
        [string]$Root = ''
    )
    if ([string]::IsNullOrWhiteSpace($Root)) { $Root = New-SvTempRoot -Tag $Tag }
    $dataRoot = Join-Path $Root 'data'
    New-Item -ItemType Directory -Force -Path $dataRoot | Out-Null
    if ([string]::IsNullOrWhiteSpace($ScriptsDir)) { $ScriptsDir = New-SvFakeScriptsDir -Root $Root -ClientFixture $ClientFixture }
    if ([string]::IsNullOrWhiteSpace($SessionId)) { $SessionId = 'sv-' + [guid]::NewGuid().ToString('N').Substring(0, 8) }
    $srcDir = Join-Path $Root 'src'
    New-Item -ItemType Directory -Force -Path $srcDir | Out-Null
    $target = Join-Path $srcDir ('target-' + $Tag + '.ps1')
    [System.IO.File]::WriteAllText($target, $TargetContent, (New-Object System.Text.UTF8Encoding($false)))
    if ($RemoveTarget) { Remove-Item -LiteralPath $target -Force }
    $r = Invoke-ScanFileDiagnostics -ScriptsDir $ScriptsDir -DataRoot $dataRoot -SessionId $SessionId `
        -HostExe $HostExe -FilePath $target -Cwd $srcDir -CapMs $CapMs
    return @{
        Root      = $Root
        DataRoot  = $dataRoot
        Target    = $target
        SessionId = $SessionId
        Result    = $r
        ClientLog = (Read-SvTextFile -Path (Join-Path $dataRoot 'logs/lsp-client.log'))
        PidFile   = (Join-Path $dataRoot 'fake-child.pid')
    }
}
