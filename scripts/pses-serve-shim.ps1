#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# pses-serve-shim.ps1 -- the native-serve handshake shim (dispatch 000103). A thin stdio
# proxy that WRAPS (never replaces) pses-stdio.ps1 so Claude Code's native LSP client can
# drive PowerShell Editor Services (hover / definition / references / documentSymbol) past
# the #1359-class server->client init handshake, on the pinned PSES, without waiting on the
# upstream Claude Code fix.
#
# KNOB-GATED (userConfig `nativeServe`, dispatch 000103):
#   off (default) -- TRANSPARENT PASS-THROUGH: the proxy runs but neither patches the
#                    initialize nor intercepts anything -- every frame is relayed byte-exact
#                    in both directions, so the protocol the client and PSES exchange is
#                    indistinguishable from a build without the shim (PSES sees the client's
#                    real capabilities and the #1359 handshake gates exactly as it does today).
#                    (Survey-vs-disk deviation from 000102: the outbox sketched off as delegating
#                    to pses-stdio.ps1; in practice an in-process `& pses-stdio.ps1` two `&`-levels
#                    deep breaks PSES's stdio handoff -- it dies rather than stalling like the
#                    direct launcher -- so off is a transparent RELAY through the same proven
#                    spawn+pump instead. Protocol-level behavior is identical; the full removal
#                    lever is the manifest command swap back to pses-stdio.ps1. See CONTRACT.md.)
#   shim          -- the proxy below runs: spawn PSES as a CHILD, PATCH the forwarded
#                    initialize (dynamicRegistration=false so PSES advertises all nav
#                    providers STATICALLY and sends no client/registerCapability; drop the
#                    params-level workspaceFolders #2300 dodge; ensure a rename capability),
#                    answer the residual workspace/configuration + window/workDoneProgress/
#                    create + client/registerCapability LOCALLY, and forward EVERYTHING else
#                    byte-exact in both directions.
#
# THE TRANSPORT IS WHERE THIS IS WON OR LOST: stdout here is the LSP byte stream, so nothing
# may print to it but framed LSP messages -- all logging goes to a side-channel file, never
# stdout. Non-intercepted frames are spliced RAW (body bytes forwarded verbatim), so a
# multibyte-UTF-8 payload is delivered byte-identical.
#
# LIFECYCLE: a two-source async pump (client stdin + PSES stdout) via Task.WaitAny; on client
# EOF -> shutdown/exit/tree-kill PSES; on PSES death -> propagate EOF to the client PROMPTLY
# (close stdout) and exit -- the shim NEVER re-spawns PSES (the manifest maxRestarts owns
# restart). Orphan guard: on Windows PSES is assigned to a KILL_ON_JOB_CLOSE job object so a
# hard client kill (which skips `finally`) still reaps it.
#
# ASCII-only (PS 5.1 em-dash trap). Author: Mike Andersen / powershell-lsp plugin.

# --- load-silent libs: framing + init-patch + knob reader + resolvers -------
# Both libs are function-definitions-only (no pre-handshake stdout), same contract as
# pses-stdio.ps1's lsp-common import.
. (Join-Path $PSScriptRoot 'lib/lsp-common.ps1')
. (Join-Path $PSScriptRoot 'lib/serve-shim-common.ps1')

# --- side-channel log (NEVER stdout) ----------------------------------------
$script:ShimLogPath = $null
try {
    $ld = $env:CLAUDE_PLUGIN_DATA
    if ([string]::IsNullOrWhiteSpace($ld)) { $ld = $env:TEMP }
    if ([string]::IsNullOrWhiteSpace($ld)) { $ld = [System.IO.Path]::GetTempPath() }
    $ld = Join-Path $ld 'logs'
    New-Item -ItemType Directory -Force -Path $ld | Out-Null
    $script:ShimLogPath = Join-Path $ld 'pses-serve-shim.log'
} catch { $script:ShimLogPath = $null }

function Write-ShimLog([string]$m) {
    try {
        if ([string]::IsNullOrWhiteSpace($script:ShimLogPath)) { return }
        ('[' + (Get-Date -Format 'o') + '] [' + $PID + '] ' + $m) | Out-File -FilePath $script:ShimLogPath -Append -Encoding ascii
    } catch { }
}

# --- the knob: off (default) = transparent relay; shim = the patching proxy --
$mode = ConvertTo-NativeServeMode (Get-PluginOption 'nativeServe' 'off')
$transparent = ($mode -ne 'shim')
if ($transparent) {
    Write-ShimLog 'nativeServe=off: transparent relay (no init patch, no interception; today behavior)'
} else {
    Write-ShimLog 'nativeServe=shim: native-serve handshake proxy (init patch + local intercepts)'
}

# --- resolve the PSES child launch (mirrors the daemon's Start-PsesProcess) --
$startScript = Get-PsesStartScript
if (-not (Test-Path -LiteralPath $startScript)) {
    [Console]::Error.WriteLine('PSES not found at: ' + $startScript + '. Run a new session so ensure-pses.ps1 can bootstrap it, or check the logs.')
    Write-ShimLog ('PSES start script missing: ' + $startScript)
    exit 1
}
$bundleRoot = Get-PsesBundleRoot
$hostExe = Resolve-PsHost (Get-PluginOption 'ps_host' 'pwsh')
if ($null -eq $hostExe) {
    [Console]::Error.WriteLine('No PowerShell host (pwsh/powershell) found to launch PSES.')
    Write-ShimLog 'no PowerShell host found (pwsh/powershell)'
    exit 1
}

$logBase = Split-Path -Parent $script:ShimLogPath
if ([string]::IsNullOrWhiteSpace($logBase)) { $logBase = [System.IO.Path]::GetTempPath() }
$stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff')
$pseLog = Join-Path $logBase ('pses-serve-' + $stamp + '.log')
$sess = Join-Path $logBase ('pses-serve-' + $stamp + '.json')
$errLog = Join-Path $logBase ('pses-serve-stderr-' + $stamp + '.log')

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $hostExe
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true
$psi.WorkingDirectory = $logBase
Add-ProcessArguments $psi @(
    '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $startScript,
    '-HostName', 'Claude Code', '-HostProfileId', 'claude-code', '-HostVersion', (Get-PluginVersion),
    '-BundledModulesPath', $bundleRoot,
    '-LogPath', $pseLog, '-LogLevel', 'Information',
    '-SessionDetailsPath', $sess,
    '-Stdio')
# Make the vendored PSScriptAnalyzer visible to the PSES child (mirrors the daemon). Harmless
# when absent: nav is AST/symbol-derived and settings-independent, so it never blocks serve.
$pssaDir = Get-PssaModuleDir
if (Test-Path -LiteralPath $pssaDir) {
    $psi.EnvironmentVariables['PSModulePath'] = $pssaDir + [System.IO.Path]::PathSeparator + $env:PSModulePath
}

$proc = $null
$psesIn = $null
$ccOut = $null
$jobHandle = [IntPtr]::Zero
$shimExit = 0
try {
    Write-ShimLog ('launching PSES via ' + $hostExe)
    $proc = [System.Diagnostics.Process]::Start($psi)
    $psesIn = $proc.StandardInput.BaseStream
    $psesOut = $proc.StandardOutput.BaseStream
    # Drain PSES stderr to a file so a diagnostic line can NEVER reach the LSP stream.
    $errFs = [System.IO.File]::Open($errLog, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    $null = $proc.StandardError.BaseStream.CopyToAsync($errFs)

    # Orphan guard (Windows): a KILL_ON_JOB_CLOSE job object reaps PSES when the OS closes our
    # handles -- covering a hard client kill that skips `finally`. Best-effort: any failure
    # (locked-down host) logs and continues; the finally tree-kill + PSES stdin-EOF still cover
    # the normal paths. On non-Windows there is no job object; the finally reap + PSES's own
    # exit-on-stdin-EOF are the reap path (documented in docs/upstream).
    if (Test-OnWindows) {
        try {
            if (-not ('PsesServeShim.JobGuard' -as [type])) {
                Add-Type -Namespace 'PsesServeShim' -Name 'JobGuard' -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct IO_COUNTERS { public ulong Rd; public ulong Wr; public ulong Ot; public ulong RdT; public ulong WrT; public ulong OtT; }
[StructLayout(LayoutKind.Sequential)] public struct JOBOBJECT_BASIC_LIMIT_INFORMATION { public long PerProcessUserTimeLimit; public long PerJobUserTimeLimit; public uint LimitFlags; public UIntPtr MinimumWorkingSetSize; public UIntPtr MaximumWorkingSetSize; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass; public uint SchedulingClass; }
[StructLayout(LayoutKind.Sequential)] public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION { public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation; public IO_COUNTERS IoInfo; public UIntPtr ProcessMemoryLimit; public UIntPtr JobMemoryLimit; public UIntPtr PeakProcessMemoryUsed; public UIntPtr PeakJobMemoryUsed; }
[DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr a, string lpName);
[DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr hJob, int infoClass, IntPtr lpJobObjectInfo, uint cb);
[DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);
[DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr hObject);
public static IntPtr CreateKillOnCloseJob() {
    IntPtr h = CreateJobObject(IntPtr.Zero, null);
    if (h == IntPtr.Zero) { return IntPtr.Zero; }
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
    info.BasicLimitInformation.LimitFlags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    int len = Marshal.SizeOf(info);
    IntPtr p = Marshal.AllocHGlobal(len);
    try {
        Marshal.StructureToPtr(info, p, false);
        if (!SetInformationJobObject(h, 9, p, (uint)len)) { CloseHandle(h); return IntPtr.Zero; }
    } finally { Marshal.FreeHGlobal(p); }
    return h;
}
public static bool AssignProcess(IntPtr hJob, IntPtr hProcess) { return AssignProcessToJobObject(hJob, hProcess); }
'@ -ErrorAction Stop
            }
            $jobHandle = [PsesServeShim.JobGuard]::CreateKillOnCloseJob()
            if ($jobHandle -ne [IntPtr]::Zero) {
                [void][PsesServeShim.JobGuard]::AssignProcess($jobHandle, $proc.Handle)
                Write-ShimLog 'orphan guard: PSES assigned to a KILL_ON_JOB_CLOSE job object'
            } else {
                Write-ShimLog 'orphan guard: job object unavailable; relying on the finally reap'
            }
        } catch {
            Write-ShimLog ('orphan guard unavailable (continuing without it): ' + $_.Exception.Message)
        }
    }

    # Raw byte streams to/from the client (Claude Code). The RAW streams -- never
    # [Console]::In/Out text writers -- keep the transport byte-exact (no CRLF translation,
    # no encoding mangling).
    $ccIn = [Console]::OpenStandardInput()
    $ccOut = [Console]::OpenStandardOutput()

    # --- the two-source pump ------------------------------------------------
    $ccBuf = New-Object System.Collections.Generic.List[byte]
    $psBuf = New-Object System.Collections.Generic.List[byte]
    $ccChunk = New-Object byte[] 65536
    $psChunk = New-Object byte[] 65536
    $ccPending = $null
    $psPending = $null
    $ccEof = $false
    $psEof = $false
    $initPatched = $false

    while ($true) {
        # (a) client -> PSES: patch the initialize ONCE (shim mode only); forward everything
        #     else byte-exact. In transparent (off) mode nothing is patched -- pure relay.
        $cf = Read-ServeFrame $ccBuf
        while ($null -ne $cf) {
            if ((-not $transparent) -and (-not $initPatched)) {
                $cMethod = ''
                try { $cMethod = [string](Get-Prop ([System.Text.Encoding]::UTF8.GetString($cf) | ConvertFrom-Json) 'method') } catch { $cMethod = '' }
                if ($cMethod -eq 'initialize') {
                    $patched = Edit-InitializeMessageForServe ([System.Text.Encoding]::UTF8.GetString($cf))
                    Write-ServeFrame $psesIn ([System.Text.Encoding]::UTF8.GetBytes($patched))
                    $initPatched = $true
                    Write-ShimLog 'initialize patched (dynamicRegistration=false; workspaceFolders dropped; rename ensured) and forwarded'
                    $cf = Read-ServeFrame $ccBuf
                    continue
                }
            }
            Write-ServeFrame $psesIn $cf
            $cf = Read-ServeFrame $ccBuf
        }

        # (b) PSES -> client: in shim mode answer the intercepted server->client requests
        #     locally; forward everything else (responses, notifications, other requests)
        #     byte-exact. In transparent (off) mode nothing is intercepted -- pure relay.
        $pf = Read-ServeFrame $psBuf
        while ($null -ne $pf) {
            $forward = $true
            if (-not $transparent) {
                try {
                    $m = [System.Text.Encoding]::UTF8.GetString($pf) | ConvertFrom-Json
                    if ((Test-Prop $m 'id') -and (Test-Prop $m 'method')) {
                        $sMethod = [string](Get-Prop $m 'method')
                        if (Test-ServeInterceptMethod $sMethod) {
                            $resp = New-ServeInterceptResponseJson -Id (Get-Prop $m 'id') -Method $sMethod -Params (Get-Prop $m 'params')
                            Write-ServeFrame $psesIn ([System.Text.Encoding]::UTF8.GetBytes($resp))
                            Write-ShimLog ('intercepted server->client ' + $sMethod + ' (answered locally)')
                            $forward = $false
                        }
                    }
                } catch { $forward = $true }
            }
            if ($forward) { Write-ServeFrame $ccOut $pf }
            $pf = Read-ServeFrame $psBuf
        }

        # (c) exit conditions.
        if ($psEof -or $proc.HasExited) {
            Write-ShimLog 'PSES exited / stdout EOF; propagating EOF to the client (CC owns restart via maxRestarts)'
            if (-not $ccEof) { $shimExit = 1 }
            break
        }
        if ($ccEof) {
            Write-ShimLog 'client stdin EOF; tearing down PSES'
            break
        }

        # (d) keep one outstanding async read per live source.
        if ((-not $ccEof) -and ($null -eq $ccPending)) { $ccPending = $ccIn.ReadAsync($ccChunk, 0, $ccChunk.Length) }
        if ((-not $psEof) -and ($null -eq $psPending)) { $psPending = $psesOut.ReadAsync($psChunk, 0, $psChunk.Length) }

        $waitList = New-Object System.Collections.Generic.List[System.Threading.Tasks.Task]
        if ($null -ne $ccPending) { [void]$waitList.Add($ccPending) }
        if ($null -ne $psPending) { [void]$waitList.Add($psPending) }
        if ($waitList.Count -eq 0) { break }
        $idx = [System.Threading.Tasks.Task]::WaitAny($waitList.ToArray(), 1000)
        if ($idx -lt 0) { continue }   # 1s poll timeout -> re-check HasExited and re-drain

        # (e) harvest whichever read(s) completed.
        if (($null -ne $ccPending) -and $ccPending.IsCompleted) {
            $c = -1; try { $c = $ccPending.Result } catch { $c = -1 }
            $ccPending = $null
            if ($c -le 0) { $ccEof = $true } else { $sub = New-Object byte[] $c; [System.Array]::Copy($ccChunk, 0, $sub, 0, $c); $ccBuf.AddRange($sub) }
        }
        if (($null -ne $psPending) -and $psPending.IsCompleted) {
            $c = -1; try { $c = $psPending.Result } catch { $c = -1 }
            $psPending = $null
            if ($c -le 0) { $psEof = $true } else { $sub = New-Object byte[] $c; [System.Array]::Copy($psChunk, 0, $sub, 0, $c); $psBuf.AddRange($sub) }
        }
    }
} finally {
    # Graceful PSES shutdown (the daemon's Stop-Pses sequence), then tree-kill. On PS 5.1 the
    # Kill($true) tree overload is absent -> fall back to Kill() (the Windows job object still
    # reaps the tree). Zero-orphan.
    try {
        if (($null -ne $proc) -and (-not $proc.HasExited)) {
            try { Write-ServeFrame $psesIn ([System.Text.Encoding]::UTF8.GetBytes('{"jsonrpc":"2.0","id":999,"method":"shutdown"}')) } catch { }
            Start-Sleep -Milliseconds 120
            try { Write-ServeFrame $psesIn ([System.Text.Encoding]::UTF8.GetBytes('{"jsonrpc":"2.0","method":"exit"}')) } catch { }
            Start-Sleep -Milliseconds 120
            try { if (-not $proc.HasExited) { $proc.Kill($true) } } catch {
                try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
            }
        }
    } catch { }
    # Propagate EOF to the client if the pump did not already.
    try { if ($null -ne $ccOut) { $ccOut.Flush(); $ccOut.Close() } } catch { }
    Write-ShimLog 'shim exiting; PSES reaped'
}

exit $shimExit
