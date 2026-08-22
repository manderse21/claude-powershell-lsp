#Requires -Version 5.1
# security-gate.ps1 -- the T5.1 pipe-restriction gate, measured at the cache-staged
# build of release-identity commit C. Dispatch 000273 (freeze 1B). ASCII only.
#
# WHAT THIS PROVES, and how.
#
# THREAT-MODEL.md section 8 records T5.1 as MEASURED-then-FIXED: the daemon's
# diagnostics pipe used to carry the OS default named-pipe DACL, which grants
# Everyone (WD) and Anonymous (AN) FILE_GENERIC_READ. The recorded method is to read
# the KERNEL object's security descriptor off the LIVE pipe handle
# (GetSecurityInfo, SE_KERNEL_OBJECT). This script replays that read at C, so the
# SHIPPED commit carries a shipped-commit measurement rather than inheriting one.
#
# THREE ARMS.
#
#   A. LIVE DAEMON UNDER pwsh. Bring the real daemon up through the real
#      SessionStart hook at the staged C tree, connect a client to its live pipe,
#      and read the SD off that handle. REQUIRE no WD and no AN ACE.
#
#   B. RED CONTROL, paired. The same instrument, same process, against two pipe
#      servers built here: one with C's OWN Get-DaemonPipeOptions (dot-sourced from
#      the staged tree), one with the PRE-FIX options (Asynchronous alone). The
#      pre-fix pipe MUST show WD and AN. Without this arm, "no Everyone found" could
#      be an instrument that cannot see an ACE at all.
#
#   C. PS 5.1 RESIDUAL. Bring the daemon up with ps_host=powershell and confirm the
#      disclosed residual exactly as the release notes state it: the daemon STARTS
#      and SERVES, and its pipe is NOT restricted, because Windows PowerShell's
#      PipeOptions enum has no CurrentUserOnly member to set.
#
# POSIX is deliberately out of scope -- separately chartered, and .NET narrows a
# socket file's mode there rather than writing a DACL, so this instrument does not
# apply.

param(
    [string] $Base    = 'C:\Users\mande\AppData\Local\Temp\psl-273',
    [string] $Commit  = '6ab2d24bf254787520ad9449c4e6c17f74ee708d',
    [string] $JsonOut = 'C:\Users\mande\AppData\Local\Temp\psl-273\out\security-gate.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root    = Join-Path $Base 'root'
$Data    = Join-Path $Base 'data'
$Scripts = Join-Path $Root 'scripts'

# ------------------------------------------------------------------ instrument

Add-Type -Namespace PslSec -Name Sd -MemberDefinition @'
[DllImport("advapi32.dll", SetLastError=true)]
public static extern uint GetSecurityInfo(
    IntPtr handle, int objectType, int securityInfo,
    IntPtr owner, IntPtr group, out IntPtr dacl, IntPtr sacl, out IntPtr sd);

[DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
public static extern bool ConvertSecurityDescriptorToStringSecurityDescriptorW(
    IntPtr sd, uint revision, int securityInfo, out IntPtr str, out int len);

[DllImport("kernel32.dll")]
public static extern IntPtr LocalFree(IntPtr p);
'@

function Get-HandleSddl {
    # Read the DACL off a live kernel handle and return it as SDDL.
    #   SE_KERNEL_OBJECT = 6, DACL_SECURITY_INFORMATION = 4, SDDL_REVISION_1 = 1
    param([Parameter(Mandatory)][IntPtr] $Handle)
    $dacl = [IntPtr]::Zero; $sd = [IntPtr]::Zero
    $rc = [PslSec.Sd]::GetSecurityInfo($Handle, 6, 4, [IntPtr]::Zero, [IntPtr]::Zero,
                                       [ref]$dacl, [IntPtr]::Zero, [ref]$sd)
    if ($rc -ne 0) { throw ('GetSecurityInfo failed: win32 ' + $rc) }
    try {
        $str = [IntPtr]::Zero; $len = 0
        if (-not [PslSec.Sd]::ConvertSecurityDescriptorToStringSecurityDescriptorW($sd, 1, 4, [ref]$str, [ref]$len)) {
            throw ('ConvertSecurityDescriptorToStringSecurityDescriptor failed: win32 ' +
                   [Runtime.InteropServices.Marshal]::GetLastWin32Error())
        }
        try { return [Runtime.InteropServices.Marshal]::PtrToStringUni($str) }
        finally { [void][PslSec.Sd]::LocalFree($str) }
    } finally { if ($sd -ne [IntPtr]::Zero) { [void][PslSec.Sd]::LocalFree($sd) } }
}

function Test-SddlAce {
    # Match an ACE by its trustee SID string, anchored to the ACE's own closing
    # field so a substring cannot masquerade: an ACE ends ';<trustee>)'.
    param([Parameter(Mandatory)][string] $Sddl, [Parameter(Mandatory)][string] $Trustee)
    return $Sddl.Contains(';' + $Trustee + ')')
}

function Get-PipeVerdict {
    param([Parameter(Mandatory)][string] $Sddl, [Parameter(Mandatory)][string] $Label)
    $everyone  = Test-SddlAce -Sddl $Sddl -Trustee 'WD'
    $anonymous = Test-SddlAce -Sddl $Sddl -Trustee 'AN'
    return [ordered]@{
        label            = $Label
        sddl             = $Sddl
        everyone_ace     = $everyone
        anonymous_ace    = $anonymous
        restricted       = (-not $everyone -and -not $anonymous)
    }
}

# ------------------------------------------------------------------ daemon arms

function Invoke-Hook {
    param([string] $ScriptPath, [string] $StdinJson, [int] $CapMs, [string] $DataRoot, [string[]] $ExtraArgs = @())
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'pwsh'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($a in (@('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + @($ExtraArgs))) {
        if ($a) { $psi.ArgumentList.Add([string]$a) }
    }
    $psi.EnvironmentVariables['CLAUDE_PLUGIN_ROOT'] = $Root
    $psi.EnvironmentVariables['CLAUDE_PLUGIN_DATA'] = $DataRoot
    $p = [System.Diagnostics.Process]::Start($psi)
    $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
    if ($StdinJson) {
        $b = [System.Text.Encoding]::UTF8.GetBytes($StdinJson)
        $p.StandardInput.BaseStream.Write($b, 0, $b.Length)
        $p.StandardInput.BaseStream.Flush()
    }
    $p.StandardInput.Close()
    $exited = $p.WaitForExit($CapMs)
    if (-not $exited) { try { $p.Kill($true) } catch { } }
    [void]$so.Wait(2000); [void]$se.Wait(2000)
    return [pscustomobject]@{
        Exited = $exited
        Stdout = $(if ($so.IsCompleted) { $so.Result } else { '' })
        Stderr = $(if ($se.IsCompleted) { $se.Result } else { '' })
    }
}

function Invoke-DaemonAction {
    param([string] $SessionId, [string] $Action, [int] $ConnectMs = 2000)
    $pipe = $null
    try {
        $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', ('powershell-lsp-' + $SessionId),
            [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::None)
        $pipe.Connect($ConnectMs)
        $w = New-Object System.IO.StreamWriter($pipe); $w.AutoFlush = $true
        $r = New-Object System.IO.StreamReader($pipe)
        $w.WriteLine((@{ action = $Action } | ConvertTo-Json -Compress))
        $line = $r.ReadLine()
        if ([string]::IsNullOrWhiteSpace($line)) { return $null }
        return ($line | ConvertFrom-Json)
    } catch { return $null } finally { if ($pipe) { try { $pipe.Dispose() } catch { } } }
}

function Read-LivePipeSddl {
    # Connect a CLIENT to the live daemon pipe and read the SD off that handle. The
    # client handle names the same kernel pipe object the daemon created, so this is
    # the shipped pipe's own descriptor, read while the daemon is serving.
    param([string] $SessionId, [int] $ConnectMs = 5000)
    $pipe = $null
    try {
        $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', ('powershell-lsp-' + $SessionId),
            [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::None)
        $pipe.Connect($ConnectMs)
        return (Get-HandleSddl -Handle $pipe.SafePipeHandle.DangerousGetHandle())
    } finally { if ($pipe) { try { $pipe.Dispose() } catch { } } }
}

function New-PrivateDataRoot([string] $tag) {
    $d = Join-Path $Base ('d-' + $tag)
    if (Test-Path -LiteralPath $d) { Remove-PrivateDataRoot $d }
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $d 'logs') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $d 'session') -Force | Out-Null
    foreach ($j in @('PowerShellEditorServices', 'modules')) {
        & cmd.exe /c mklink /J ('"' + (Join-Path $d $j) + '"') ('"' + (Join-Path $Data $j) + '"') | Out-Null
    }
    Get-ChildItem -LiteralPath $Data -Filter '*.ok' -File | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $d $_.Name) -Force
    }
    return $d
}

function Remove-PrivateDataRoot([string] $d) {
    if (-not (Test-Path -LiteralPath $d)) { return }
    foreach ($j in @('PowerShellEditorServices', 'modules')) {
        $p = Join-Path $d $j
        if (Test-Path -LiteralPath $p) { & cmd.exe /c rmdir ('"' + $p + '"') 2>&1 | Out-Null }
    }
    Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
}

function Measure-DaemonArm {
    # Bring the real daemon up on $HostExe, prove it SERVES, read its live pipe SD.
    param([string] $HostExe, [string] $Sid, [string] $Tag, [int] $TimeoutMs = 90000)
    $dr = New-PrivateDataRoot $Tag
    $served = $false; $ping = $null; $sddl = $null; $err = $null
    try {
        Invoke-Hook -ScriptPath (Join-Path $Scripts 'session-start.ps1') `
            -StdinJson (@{ session_id = $Sid } | ConvertTo-Json -Compress) `
            -CapMs $TimeoutMs -DataRoot $dr -ExtraArgs @('-PreferredHost', $HostExe) | Out-Null
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
            $ping = Invoke-DaemonAction -SessionId $Sid -Action 'ping' -ConnectMs 300
            if ($null -ne $ping) { $served = $true; break }
            Start-Sleep -Milliseconds 100
        }
        $sw.Stop()
        if ($served) { $sddl = Read-LivePipeSddl -SessionId $Sid }
    } catch {
        $err = $_.Exception.Message
    } finally {
        try { Invoke-DaemonAction -SessionId $Sid -Action 'shutdown' -ConnectMs 2000 | Out-Null } catch { }
        Start-Sleep -Milliseconds 500
        Remove-PrivateDataRoot $dr
    }
    $daemonPid = $null; $psesPid = $null
    if ($ping) {
        $pp = $ping.PSObject.Properties['pid'];      if ($pp) { $daemonPid = $pp.Value }
        $sp = $ping.PSObject.Properties['psesPid'];  if ($sp) { $psesPid  = $sp.Value }
    }
    $v = $null
    if ($sddl) { $v = Get-PipeVerdict -Sddl $sddl -Label ('live daemon pipe, ps_host=' + $HostExe) }
    return [ordered]@{
        ps_host      = $HostExe
        session_id   = $Sid
        daemon_served = $served
        daemon_pid   = $daemonPid
        pses_pid     = $psesPid
        pipe         = $v
        error        = $err
    }
}

function Get-HostPipeOptionSupport([string] $Exe) {
    # Does THIS host's PipeOptions enum carry CurrentUserOnly? The guard the fix
    # turns on is a runtime-capability probe, so read the capability per host.
    $script = '$n=[enum]::GetNames([System.IO.Pipes.PipeOptions]); ' +
              '[pscustomobject]@{host=$PSVersionTable.PSVersion.ToString(); edition=$PSVersionTable.PSEdition; ' +
              'members=($n -join ","); supported=($n -contains "CurrentUserOnly")} | ConvertTo-Json -Compress'
    $out = & $Exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command $script
    return ($out | ConvertFrom-Json)
}

# ------------------------------------------------------------------ run

$result = [ordered]@{
    gate       = 'T5.1 pipe restriction at C'
    commit     = $Commit
    measured_at = (Get-Date).ToString('o')
    os         = [string](Get-CimInstance Win32_OperatingSystem).Caption + ' ' + [string](Get-CimInstance Win32_OperatingSystem).Version
    method     = 'GetSecurityInfo(SE_KERNEL_OBJECT, DACL_SECURITY_INFORMATION) off a live pipe handle, rendered as SDDL'
}

Write-Output '=== host capability probe ==='
$result['host_pwsh']      = Get-HostPipeOptionSupport 'pwsh'
$result['host_powershell'] = Get-HostPipeOptionSupport 'powershell'
Write-Output ('pwsh       ' + $result['host_pwsh'].host + ' (' + $result['host_pwsh'].edition + ') CurrentUserOnly=' + $result['host_pwsh'].supported)
Write-Output ('powershell ' + $result['host_powershell'].host + ' (' + $result['host_powershell'].edition + ') CurrentUserOnly=' + $result['host_powershell'].supported)

# --- ARM B first: the RED control. Establish the instrument CAN see WD/AN before
#     any arm is allowed to report their absence as a pass.
Write-Output ''
Write-Output '=== RED control: paired pipe constructors, same instrument, this process ==='
. (Join-Path $Root 'scripts/lib/lsp-common.ps1')

$redPre = $null; $redShipped = $null
$sPre = New-Object System.IO.Pipes.NamedPipeServerStream(
    'psl273-redcontrol-prefix', [System.IO.Pipes.PipeDirection]::InOut, 1,
    [System.IO.Pipes.PipeTransmissionMode]::Byte, [System.IO.Pipes.PipeOptions]::Asynchronous)
try {
    $redPre = Get-PipeVerdict -Sddl (Get-HandleSddl -Handle $sPre.SafePipeHandle.DangerousGetHandle()) `
                              -Label 'RED control: PRE-FIX constructor (Asynchronous only)'
} finally { $sPre.Dispose() }

$sShip = New-DaemonPipeServer -PipeName 'psl273-redcontrol-shipped'
try {
    $redShipped = Get-PipeVerdict -Sddl (Get-HandleSddl -Handle $sShip.SafePipeHandle.DangerousGetHandle()) `
                                  -Label "RED control: C's own New-DaemonPipeServer"
} finally { $sShip.Dispose() }

$result['red_control_prefix']  = $redPre
$result['red_control_shipped'] = $redShipped
Write-Output ('  PRE-FIX  ' + $redPre.sddl)
Write-Output ('           everyone=' + $redPre.everyone_ace + ' anonymous=' + $redPre.anonymous_ace)
Write-Output ('  SHIPPED  ' + $redShipped.sddl)
Write-Output ('           everyone=' + $redShipped.everyone_ace + ' anonymous=' + $redShipped.anonymous_ace)

if (-not ($redPre.everyone_ace -and $redPre.anonymous_ace)) {
    throw 'RED CONTROL FAILED: the pre-fix constructor did NOT show Everyone+Anonymous -- the instrument cannot see the ACEs it is asked to rule out, so any PASS below would be vacuous'
}
if (-not $redShipped.restricted) {
    throw "RED CONTROL FAILED: C's own New-DaemonPipeServer produced an UNRESTRICTED pipe in-process"
}
Write-Output '  RED control PASS -- the instrument discriminates: pre-fix shows WD+AN, shipped does not.'

# --- ARM A: the live daemon under pwsh (the gate proper)
Write-Output ''
Write-Output '=== ARM A: live daemon, ps_host=pwsh ==='
$armA = Measure-DaemonArm -HostExe 'pwsh' -Sid 'psl273seca' -Tag 'seca'
$result['arm_pwsh'] = $armA
Write-Output ('  served=' + $armA.daemon_served + ' daemon_pid=' + $armA.daemon_pid + ' pses_pid=' + $armA.pses_pid)
if ($armA.pipe) {
    Write-Output ('  SDDL: ' + $armA.pipe.sddl)
    Write-Output ('  everyone=' + $armA.pipe.everyone_ace + ' anonymous=' + $armA.pipe.anonymous_ace + ' RESTRICTED=' + $armA.pipe.restricted)
}
if ($armA.error) { Write-Output ('  error: ' + $armA.error) }

# --- ARM C: the disclosed Windows PowerShell 5.1 residual
Write-Output ''
Write-Output '=== ARM C: live daemon, ps_host=powershell (Windows PowerShell 5.1 residual) ==='
$armC = Measure-DaemonArm -HostExe 'powershell' -Sid 'psl273secc' -Tag 'secc'
$result['arm_powershell'] = $armC
Write-Output ('  served=' + $armC.daemon_served + ' daemon_pid=' + $armC.daemon_pid + ' pses_pid=' + $armC.pses_pid)
if ($armC.pipe) {
    Write-Output ('  SDDL: ' + $armC.pipe.sddl)
    Write-Output ('  everyone=' + $armC.pipe.everyone_ace + ' anonymous=' + $armC.pipe.anonymous_ace + ' RESTRICTED=' + $armC.pipe.restricted)
}
if ($armC.error) { Write-Output ('  error: ' + $armC.error) }

# ------------------------------------------------------------------ verdicts

$gateA = ($armA.daemon_served -and $null -ne $armA.pipe -and $armA.pipe.restricted)
# The residual is CONFIRMED-AS-DISCLOSED when 5.1 starts and serves AND its pipe is
# NOT restricted. A 5.1 daemon that failed to start would be a different defect, and
# a 5.1 pipe that WAS restricted would mean the release notes overstate the residual.
$residualConfirmed = ($armC.daemon_served -and $null -ne $armC.pipe -and -not $armC.pipe.restricted)

$result['verdict_pwsh_restricted']  = $gateA
$result['verdict_residual_as_disclosed'] = $residualConfirmed
$result['verdict'] = $(if ($gateA -and $residualConfirmed) { 'PASS' } else { 'FAIL' })

Write-Output ''
Write-Output '=== VERDICT ==='
Write-Output ('  pwsh pipe restricted (no Everyone, no Anonymous) : ' + $gateA)
Write-Output ('  PS 5.1 residual confirmed as disclosed           : ' + $residualConfirmed)
Write-Output ('  GATE: ' + $result['verdict'])

if ($JsonOut) { ($result | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $JsonOut -Encoding UTF8 }
if ($result['verdict'] -ne 'PASS') { throw ('SECURITY GATE FAILED at ' + $Commit) }
