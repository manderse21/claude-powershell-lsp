#Requires -Version 5.1

# ServeShim.Common.ps1 -- scripted-LSP-client harness for the native-serve shim
# (PowerShellLsp.ServeShim.Tests.ps1, dispatch 000103). NOT a *.Tests.ps1 file, so Pester
# discovery never collects it; dot-sourced from the relevant BeforeAll blocks AFTER
# scripts/lib/lsp-common.ps1 (framing + Get-Prop) and scripts/lib/serve-shim-common.ps1
# (New-ServeInterceptResponseJson -- a real client must ANSWER PSES's server->client requests
# or PSES blocks its init result), mirroring the Integration.Common.ps1 support-file pattern.
#
# WHY a scripted client: Claude Code's real LSP client is ABSENT in CI (the 000069 probes
# needed a live `claude -p`), so these tests drive the shimmed PSES stack directly over stdio
# with a CC-shaped client and assert the shim's contract. Each caller launches EXACTLY ONE
# shim+PSES at a time (its own Context/BeforeAll), per the 000101 serialization lesson -- never
# N daemons in a shared BeforeAll, which flakes the constrained 5.1 CI leg on the startup spike.
#
# ASCII-only (PS 5.1 em-dash trap). Author: Mike Andersen / powershell-lsp plugin.

# The standard nav fixture. Line/char are 0-based (LSP). Layout is load-bearing for the
# probe positions below: the function DEFINITION name is on line 0, and a CALL is on line 4.
$script:ServeShimFixtureText = "function Get-ShimNavTarget {`n    'shim probe'`n}`n`nGet-ShimNavTarget`n"
$script:ServeShimDefLine = 0; $script:ServeShimDefChar = 12   # inside 'Get-ShimNavTarget' in the def
$script:ServeShimCallLine = 4; $script:ServeShimCallChar = 5  # inside 'Get-ShimNavTarget' in the call

function Initialize-ServeShimEnv {
    # Idempotent PSES + pinned-PSSA bootstrap (no-op if already vendored, marker-gated) + the
    # scratch data root. Returns @{ ScriptsDir; DataDir }. Shares PSLS_TEST_DATA_DIR with the
    # integration suite when set (CI) so PSES is vendored once; the shim writes distinct
    # pses-serve-*.log names and guid-unique fixtures, so it never collides with the daemon.
    param([string]$TestsDir)
    $scriptsDir = Join-Path (Split-Path -Parent $TestsDir) 'scripts'
    $dataDir = if (-not [string]::IsNullOrWhiteSpace($env:PSLS_TEST_DATA_DIR)) {
        $env:PSLS_TEST_DATA_DIR
    } else {
        Join-Path ([System.IO.Path]::GetTempPath()) 'psls-serveshim-data'
    }
    New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
    $env:CLAUDE_PLUGIN_DATA = $dataDir
    & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsDir 'ensure-pses.ps1') 2>&1 | Out-Null
    & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsDir 'ensure-pssa.ps1') 2>&1 | Out-Null
    return @{ ScriptsDir = $scriptsDir; DataDir = $dataDir }
}

function New-ServeShimRichCapabilities {
    # A rich, CC-shaped client capabilities object with dynamicRegistration=true across the
    # sections that matter -- this is what ELICITS client/registerCapability from PSES on the
    # direct path, so the shim's dynamicRegistration=false patch is the thing under test. Rename
    # is DELIBERATELY OMITTED here so that a shim-mode run also proves the shim's rename-NRE dodge
    # (the caller adds rename only for the transparent/off scenario, mimicking a well-formed CC
    # client that would otherwise trip the direct-path NRE the shim exists to dodge).
    return @{
        workspace    = @{ configuration = $true; workspaceFolders = $true; didChangeConfiguration = @{ dynamicRegistration = $true } }
        window       = @{ workDoneProgress = $true }
        textDocument = @{
            synchronization = @{ dynamicRegistration = $true; didSave = $true }
            hover           = @{ dynamicRegistration = $true; contentFormat = @('markdown', 'plaintext') }
            definition      = @{ dynamicRegistration = $true; linkSupport = $true }
            references      = @{ dynamicRegistration = $true }
            documentSymbol  = @{ dynamicRegistration = $true }
            completion      = @{ dynamicRegistration = $true }
        }
    }
}

function Receive-ServeShimResponse {
    # Pump the shim's stdout ($St.From) until the response with id $TargetId arrives (returned),
    # or $TimeoutMs elapses / the stream EOFs ($null). Any server->client REQUEST that reaches us
    # is a shim-transparency LEAK: it is RECORDED ($St.Leaks) AND ANSWERED back to $St.To (a real
    # client must answer or PSES stalls its init) using the shim's own answer table. Single
    # outstanding async read (the daemon's Invoke-LspPump discipline); StrictMode-safe.
    param([hashtable]$St, [int]$TargetId, [int]$TimeoutMs)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ($true) {
        $frame = Read-LspFrame -Buffer $St.Buf
        while ($null -ne $frame) {
            $msg = $null; try { $msg = $frame | ConvertFrom-Json } catch { $msg = $null }
            if ($null -ne $msg) {
                $hasId = Test-Prop $msg 'id'; $hasMethod = Test-Prop $msg 'method'
                if ($hasId -and $hasMethod) {
                    $sm = [string](Get-Prop $msg 'method')
                    [void]$St.Leaks.Add($sm)
                    $ans = New-ServeInterceptResponseJson -Id (Get-Prop $msg 'id') -Method $sm -Params (Get-Prop $msg 'params')
                    try { Write-LspFrame -Stream $St.To -Json $ans } catch { }
                } elseif ($hasId -and -not $hasMethod) {
                    if (([string](Get-Prop $msg 'id')) -eq ([string]$TargetId)) { return $msg }
                }
            }
            $frame = Read-LspFrame -Buffer $St.Buf
        }
        if ((Get-Date) -ge $deadline) { return $null }
        if ($null -eq $St.Pending) { $St.Pending = $St.From.ReadAsync($St.Chunk, 0, $St.Chunk.Length) }
        if ($St.Pending.Wait(200)) {
            $c = -1; try { $c = $St.Pending.Result } catch { $c = -1 }
            $St.Pending = $null
            if ($c -le 0) { $St.Eof = $true; return $null }
            $sub = New-Object byte[] $c; [System.Array]::Copy($St.Chunk, 0, $sub, 0, $c); $St.Buf.AddRange($sub)
        }
    }
}

function Start-ServeShimClient {
    # Launch ONE shim ($Interpreter -File pses-serve-shim.ps1) in the given $Mode and return a
    # state hashtable holding the process + streams + pump buffers. The caller MUST call
    # Stop-ServeShimClient in an AfterAll (verify-before-kill teardown; leak-safe -- we hold the
    # Process handle, so $p.Kill($true) reaps the shim + its PSES child, the 000078 discipline).
    param([string]$ScriptsDir, [string]$Interpreter, [string]$Mode, [string]$DataRoot)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Interpreter
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    Add-ProcessArguments $psi @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $ScriptsDir 'pses-serve-shim.ps1'))
    $psi.EnvironmentVariables['CLAUDE_PLUGIN_DATA'] = $DataRoot
    $psi.EnvironmentVariables['CLAUDE_PLUGIN_OPTION_NATIVESERVE'] = $Mode
    $psi.EnvironmentVariables['CLAUDE_PLUGIN_OPTION_PS_HOST'] = 'pwsh'
    $p = [System.Diagnostics.Process]::Start($psi)
    # ShimStart is load-bearing, not diagnostic: Get-ServeShimPsesPid scopes candidate PSES hosts
    # to those that started at/after this shim, which is what excludes a host leaked by a prior
    # session (the 000125 flake). Read once here, from the live handle, so the scope is exact.
    $shimStart = [datetime]::MinValue
    try { $shimStart = $p.StartTime } catch { $shimStart = (Get-Date).AddSeconds(-5) }
    # Shim STDERR to a per-run FILE, not a never-read Task (dispatch 000163 leg 2). The old
    # ErrTask = ReadToEndAsync() was assigned here and read NOWHERE in the repo, so an unhandled
    # shim exception -- the exact evidence the 000161 record predicted a second sighting would
    # lack -- was drained and discarded. Two reasons a file beats the Task: (1) ReadToEndAsync
    # completes only when the stderr pipe CLOSES, so a shim that HANGS (the failing shape) never
    # completes it and .Result would block forever; CopyToAsync lands the bytes as they arrive.
    # (2) A file under $DataRoot/logs is inside the tree CI uploads. FileShare::ReadWrite so the
    # recorder can read it while the handle is open -- mirrors the shim's own PSES-stderr drain.
    # Inert: stderr is still drained exactly as before (an undrained pipe can block a chatty
    # child), and no existing caller read ErrTask, so no consumer changes.
    $sink = New-ServeShimStderrSink -Process $p -DataRoot $DataRoot -Mode $Mode
    $errPath = [string]$sink.Path
    $errFs = $sink.Fs
    $st = @{
        Proc = $p
        ShimStart = $shimStart
        To   = $p.StandardInput.BaseStream
        From = $p.StandardOutput.BaseStream
        Buf  = New-Object System.Collections.Generic.List[byte]
        Chunk = New-Object byte[] 65536
        Pending = $null
        Leaks = New-Object System.Collections.Generic.List[string]
        Eof  = $false
        ErrPath = $errPath
        ErrFs = $errFs
        DataRoot = $DataRoot
        Mode = $Mode
    }
    return $st
}

function Stop-ServeShimClient {
    # Tree-kill the shim (reaps its PSES child). Idempotent + swallow-all (teardown must never throw).
    param([hashtable]$St)
    if ($null -eq $St) { return }
    try { if ($null -ne $St.To) { $St.To.Close() } } catch { }
    try {
        if ($null -ne $St.Proc) {
            if (-not $St.Proc.WaitForExit(3000)) { try { $St.Proc.Kill($true) } catch { try { $St.Proc.Kill() } catch { } } }
        }
    } catch { }
    # Close the stderr sink AFTER the shim is down (dispatch 000163 leg 2), so the CopyToAsync has
    # seen EOF and every byte the shim wrote -- including an unhandled exception's error record --
    # is on disk before any reader opens the file. Swallow-all: teardown must never throw.
    try { if ($null -ne $St.ErrFs) { $St.ErrFs.Flush(); $St.ErrFs.Dispose(); $St.ErrFs = $null } } catch { }
}

# --- ServeShim lifecycle instrumentation (dispatch 000163 leg 2) --------------
# ============================================================================
# WHY: the ShimExitedAfterCrash assertion has now failed TWICE (run 30375... and run
# 30472816851, macos-pwsh, on the d05ec7a DOCS-ONLY merge -- a docs-only tree cannot
# regress a test, which is what made the second sighting read as a flake). The 000161
# record predicted the second sighting would "arrive with no more evidence, because
# nothing here is instrumented". That prediction was HALF right, and the half that was
# wrong is the interesting half:
#
#   The shim DOES already log its exit path with timestamps (Write-ShimLog), and CI DOES
#   already upload it ($DataRoot/logs/pses-serve-shim.log is in the daemon-logs artifact).
#   What was missing is not the log -- it is (1) any record of the EXCEPTION, because
#   pses-serve-shim.ps1's outer try has a `finally` and NO `catch`, so the error record
#   goes to the shim's stderr, which Start-ServeShimClient drained into a Task that
#   nothing ever read; (2) per-run ISOLATION, because every shim in the leg appends to
#   ONE shared log file, interleaved by pid; and (3) any discriminator distinguishing the
#   two `break` exits from the exception path, since the `finally` line is identical on all
#   three.
#
# The run-30472816851 slice for the crash shim (pid 18428) shows the signature this
# instrumentation makes machine-readable: NEITHER break marker, yet the finally marker
# present -- i.e. the pump left via an unhandled exception, which also SKIPS the
# [System.Environment]::Exit($shimExit) on the last line of the shim (the line whose own
# comment explains it exists to avoid a graceful runspace shutdown waiting on the
# background client-reader thread blocked in a synchronous Read on an unclosed client
# stdin). That is the mechanism a third sighting needs to CONFIRM, with the exception
# text naming the throwing line.
#
# DIAGNOSABILITY ONLY, on the 000159 leg-1a contract: no return value anything asserts on,
# no timing change to the PASSING path, no control-flow change to the shim (which this leg
# does not touch at all -- it is tests-only, so leg 5 is a recorded no-cut), and never
# throws. Choosing the FIX is explicitly out of scope (OQ1): that is a future dispatch,
# after instrumented evidence exists.

# The exit-path markers, quoted from pses-serve-shim.ps1's ACTIVE Write-ShimLog calls. ONE
# source for both the discriminator and its coupling guard -- the guard asserts each string
# is still present in a Write-ShimLog call in the shipped script, so a reword turns into a
# RED test rather than a silently-degraded matcher that reports 'no-teardown' forever.
$script:ServeShimMarkerPsesEof = 'PSES exited / stdout EOF; propagating EOF to the client'
$script:ServeShimMarkerClientEof = 'client stdin EOF; tearing down PSES'
$script:ServeShimMarkerFinally = 'shim exiting; PSES reaped'

function New-ServeShimStderrSink {
    # Drain a child's stderr into a per-run FILE under $DataRoot/logs and return @{ Path; Fs }.
    # Factored out of Start-ServeShimClient so the RED proof can exercise THIS code against a
    # simulated shim rather than a copy of it. Returns Path='' / Fs=$null when the filesystem
    # refuses, after falling back to a plain async drain -- an UNDRAINED stderr pipe can block a
    # chatty child, so draining must happen either way. Never throws.
    param([System.Diagnostics.Process]$Process, [string]$DataRoot, [string]$Mode)
    $errPath = ''
    $errFs = $null
    try {
        $logDir = Join-Path $DataRoot 'logs'
        New-Item -ItemType Directory -Force -Path $logDir -ErrorAction SilentlyContinue | Out-Null
        $errPath = Join-Path $logDir ('serve-shim-stderr-' + $Mode + '-' + ([datetime]::Now.ToString('yyyyMMdd-HHmmss-fff')) + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 8)) + '.log')
        # bufferSize 1 + WriteThrough, NOT [System.IO.File]::Open (which buffers 4096 by default).
        # MEASURED: with the default buffer, CopyToAsync moves the child's stderr into the
        # FileStream's MANAGED buffer and the file stays 0 bytes on disk until the buffer fills or
        # the stream is closed -- so a shim that HANGS (the failing shape, which never closes)
        # yields an empty file exactly when the evidence is wanted. Unbuffered makes "the bytes
        # land as they arrive" true rather than aspirational; stderr volume is trivial, so the
        # per-write cost does not matter.
        $errFs = New-Object System.IO.FileStream($errPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite, 1, [System.IO.FileOptions]::WriteThrough)
        $null = $Process.StandardError.BaseStream.CopyToAsync($errFs)
    } catch {
        if ($null -ne $errFs) { try { $errFs.Dispose() } catch { } }
        $errPath = ''
        $errFs = $null
        try { $null = $Process.StandardError.ReadToEndAsync() } catch { }
    }
    return @{ Path = $errPath; Fs = $errFs }
}

function Read-ServeShimTextFile {
    # Read a file that another process may still hold open for append (the shared shim log) or
    # that a CopyToAsync still has a write handle on (the per-run stderr sink). FileShare
    # ReadWrite is the point. Returns '' on any failure -- instrumentation never throws.
    param([string]$Path, [int]$MaxBytes = 262144)
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
        if (-not (Test-Path -LiteralPath $Path)) { return '' }
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            if ($fs.Length -gt $MaxBytes) { [void]$fs.Seek(($fs.Length - $MaxBytes), [System.IO.SeekOrigin]::Begin) }
            $sr = New-Object System.IO.StreamReader($fs)
            try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
        } finally { $fs.Dispose() }
    } catch { return '' }
}

function Get-ServeShimLogSlice {
    # PER-RUN ISOLATION of a SHARED log: return only the lines the given shim pid wrote to
    # $DataRoot/logs/pses-serve-shim.log. The shim stamps every line '[<iso>] [<pid>] <msg>', so
    # the pid token is exact -- matching '] [<pid>] ' cannot collide with the timestamp field.
    # Returns an EMPTY array when the log or the pid's lines are absent (never $null, so callers
    # and .Count are safe on 5.1 where a scalar's .Count is $null).
    param([string]$DataRoot, [int]$ShimPid)
    $out = New-Object System.Collections.Generic.List[string]
    try {
        if ($ShimPid -le 0) { return @() }
        $text = Read-ServeShimTextFile -Path (Join-Path $DataRoot 'logs/pses-serve-shim.log')
        if ([string]::IsNullOrEmpty($text)) { return @() }
        $token = '] [' + $ShimPid + '] '
        foreach ($line in ($text -split "`r?`n")) {
            if ($line.Contains($token)) { [void]$out.Add($line) }
        }
    } catch { }
    # PLAIN return, no comma-wrap. `return , $arr` guards a single-element array against unrolling
    # when the caller assigns bare, but every caller here wraps in @(...) -- and the two combined
    # DOUBLE-wrap, so @(Get-ServeShimLogSlice ...) came back as one String[] element instead of N
    # lines. Emitting the elements and letting @(...) re-collect is correct for 0, 1, and N.
    return $out.ToArray()
}

function Get-ServeShimExitPath {
    # THE DISCRIMINATOR. Classify how the shim's pump left, from that shim's own log slice.
    # Pure (no process, no filesystem) so it is unit-testable in both directions against the
    # REAL recorded slices from run 30472816851. The four outcomes are deliberately distinct
    # strings -- the 000159 step-2 lesson was that collapsing distinct failures into one value
    # is exactly what made three dispatches of confident reasoning produce nothing.
    #
    #   no-shim-log             -- nothing recorded for this pid (the shim never started, or the
    #                              log was unwritable); the scenario proves nothing.
    #   pses-eof-propagated     -- branch (c) PSES-death break: the CONTRACTUAL crash path.
    #   client-eof              -- branch (c) client-EOF break: normal teardown.
    #   unlogged-exception-path -- the finally ran but NEITHER break logged: the pump left via an
    #                              unhandled exception, so [System.Environment]::Exit was skipped.
    #                              This is the run-30472816851 crash-shim signature.
    #   no-teardown             -- not even the finally marker: the shim died mid-pump (hard kill).
    param([string[]]$LogSlice)
    $lines = @($LogSlice)
    if ($lines.Count -eq 0) { return 'no-shim-log' }
    $joined = ($lines -join "`n")
    if ($joined.Contains($script:ServeShimMarkerPsesEof)) { return 'pses-eof-propagated' }
    if ($joined.Contains($script:ServeShimMarkerClientEof)) { return 'client-eof' }
    if ($joined.Contains($script:ServeShimMarkerFinally)) { return 'unlogged-exception-path' }
    return 'no-teardown'
}

function Save-ServeShimLifecycleRecord {
    # Write ONE per-run isolated JSON record under $DataRoot/logs (the tree CI uploads), holding
    # the shim's own log slice, its stderr (the exception record), and the phase observations the
    # harness alone can see. Returns the path written, or '' -- never throws, and nothing asserts
    # on the return value beyond its existence (that existence IS the leg's RED proof).
    param([hashtable]$St, [string]$DataRoot, [string]$Tag, [hashtable]$Phase)
    try {
        if ([string]::IsNullOrWhiteSpace($DataRoot)) { return '' }
        $shimPid = 0
        try { if ($null -ne $St -and $null -ne $St.Proc) { $shimPid = [int]$St.Proc.Id } } catch { $shimPid = 0 }
        $slice = @(Get-ServeShimLogSlice -DataRoot $DataRoot -ShimPid $shimPid)
        $errText = ''
        if ($null -ne $St) { $errText = Read-ServeShimTextFile -Path ([string]$St.ErrPath) }
        $rec = @{
            Dispatch      = '000163'
            Tag           = [string]$Tag
            ShimPid       = $shimPid
            ExitPath      = (Get-ServeShimExitPath -LogSlice $slice)
            ShimLogSlice  = $slice
            ShimLogLines  = $slice.Count
            ShimStderr    = $errText
            ShimStderrLen = $errText.Length
            ShimStderrPath = if ($null -ne $St) { [string]$St.ErrPath } else { '' }
        }
        if ($null -ne $Phase) { foreach ($k in $Phase.Keys) { $rec[[string]$k] = $Phase[$k] } }
        $logDir = Join-Path $DataRoot 'logs'
        New-Item -ItemType Directory -Force -Path $logDir -ErrorAction SilentlyContinue | Out-Null
        $path = Join-Path $logDir ('serveshim-lifecycle-' + $Tag + '-' + ([datetime]::Now.ToString('yyyyMMdd-HHmmss-fff')) + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 8)) + '.json')
        [System.IO.File]::WriteAllText($path, ($rec | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
        return $path
    } catch { return '' }
}

function Get-ServeShimProcessParentId {
    # Best-effort PARENT pid by pid, cross-platform. Mirrors Get-ProcessCommandLine's platform
    # ladder in scripts/lib/lsp-common.ps1 (CIM on Windows, /proc on Linux, the native ps binary
    # elsewhere) so it behaves on all four CI legs. Returns 0 when unavailable -- every caller
    # treats 0 as "unknown" and falls back to the start-time factor rather than guessing.
    param([int]$ProcessIdValue)
    try {
        if (Test-OnWindows) {
            $cim = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $ProcessIdValue) -ErrorAction SilentlyContinue
            if ($null -ne $cim) { return [int]$cim.ParentProcessId }
            return 0
        }
        $statFs = "/proc/$ProcessIdValue/stat"   # Linux: field 4 is the ppid
        if (Test-Path -LiteralPath $statFs) {
            $raw = [string](Get-Content -LiteralPath $statFs -Raw -ErrorAction SilentlyContinue)
            # comm (field 2) is parenthesized and MAY contain spaces or parens, so anchor the
            # split on the LAST ')' rather than splitting the whole line on whitespace.
            $idx = $raw.LastIndexOf(')')
            if ($idx -ge 0) {
                $rest = @(($raw.Substring($idx + 1).Trim()) -split '\s+')
                if ($rest.Count -ge 2) {
                    $n = 0
                    if ([int]::TryParse($rest[1], [ref]$n)) { return $n }
                }
            }
            return 0
        }
        $psBin = Get-Command 'ps' -CommandType Application -ErrorAction SilentlyContinue
        if ($null -ne $psBin) {
            $out = ((& $psBin.Source -o ppid= -p $ProcessIdValue 2>$null) -join ' ').Trim()
            $n = 0
            if ([int]::TryParse($out, [ref]$n)) { return $n }
        }
        return 0
    } catch { return 0 }
}

function Get-ServeShimPsesPid {
    # The PSES child pid THIS shim spawned. Returns 0 if not found.
    #
    # SCOPED TO THIS RUN (dispatch 000127). The pre-000127 implementation scanned EVERY
    # pwsh/powershell process on the machine and returned the first whose command line contained
    # 'Start-EditorServices.ps1' + 'pses-serve-' -- scoped to nothing: not this shim, not this
    # run, not even this hour. A PSES leaked by a PRIOR session (dispatch 000125 recorded six
    # lingering hosts aged 19-29h, and named them as "inflating the local ServeShim flake")
    # matches that predicate exactly, so the harness returned a FOREIGN pid and the lifecycle
    # assertions then measured the wrong process:
    #   - Invoke-ServeShimSession: PsesReaped tested the leaked host (still alive) -> $false.
    #   - Invoke-ServeShimCrash:   Stop-Process killed the leaked host, this shim's real PSES
    #                              lived on, no EOF propagated, WaitForExit(15000) -> $false.
    # Which of the pair failed depended on process enumeration order, which is why the 000125
    # evidence recorded the failing pair as VARYING per run, host-independent, green in an
    # isolated run, and green on all four CI legs (clean runners carry no orphans).
    #
    # Both parameters are MANDATORY so the unscoped global scan is not merely discouraged but
    # unexpressible: there is no overload that can return a process this shim did not spawn.
    param(
        [Parameter(Mandatory = $true)][int]$ShimPid,
        [Parameter(Mandatory = $true)][datetime]$ShimStart
    )
    try {
        foreach ($proc in @(Get-Process -Name 'pwsh', 'powershell' -ErrorAction SilentlyContinue)) {
            # FACTOR 1 -- start time (always available, and alone enough to exclude every
            # leaked host from a prior session): a process that started BEFORE this shim did
            # cannot be a child this shim spawned.
            $st = $null
            try { $st = $proc.StartTime } catch { $st = $null }
            if ($null -eq $st -or $st -lt $ShimStart) { continue }
            $cl = Get-ProcessCommandLine $proc.Id
            if (-not (($cl -match 'Start-EditorServices\.ps1') -and ($cl -match 'pses-serve-'))) { continue }
            # FACTOR 2 -- parentage (authoritative where the platform answers): this shim spawns
            # PSES directly, so the child's parent IS the shim. An unknown ppid (0) does not veto,
            # so a platform that cannot answer degrades to factor 1 rather than finding nothing.
            $pp = Get-ServeShimProcessParentId $proc.Id
            if ($pp -gt 0 -and $pp -ne $ShimPid) { continue }
            return $proc.Id
        }
    } catch { }
    return 0
}

function Wait-ServeShimPsesPid {
    # READINESS GATE (replaces a fixed Start-Sleep): poll until THIS shim's PSES child is
    # identifiable, or $TimeoutMs elapses. Returns the pid, or 0 on timeout. A fixed sleep
    # encodes a guess about spawn latency that a loaded CI runner is free to violate; this
    # returns the instant the child is visible and only spends the full budget when it never is.
    param(
        [Parameter(Mandatory = $true)][int]$ShimPid,
        [Parameter(Mandatory = $true)][datetime]$ShimStart,
        [int]$TimeoutMs = 15000,
        [int]$PollMs = 100
    )
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ($true) {
        $found = Get-ServeShimPsesPid -ShimPid $ShimPid -ShimStart $ShimStart
        if ($found -gt 0) { return $found }
        if ((Get-Date) -ge $deadline) { return 0 }
        Start-Sleep -Milliseconds $PollMs
    }
}

function Wait-ServeShimProcessGone {
    # READINESS GATE (replaces a fixed Start-Sleep): poll until pid $ProcessIdValue is gone, or
    # $TimeoutMs elapses. Returns $true when reaped. A reap is near-instant in the good case, so
    # this returns immediately then; the budget only funds a genuinely slow teardown instead of
    # a fixed sleep that is simultaneously too long (in the good case) and too short (on a
    # loaded runner) -- the shape that makes a lifecycle assertion flake.
    param(
        [Parameter(Mandatory = $true)][int]$ProcessIdValue,
        [int]$TimeoutMs = 10000,
        [int]$PollMs = 100
    )
    if ($ProcessIdValue -le 0) { return $true }
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ($true) {
        if (-not [bool](Get-Process -Id $ProcessIdValue -ErrorAction SilentlyContinue)) { return $true }
        if ((Get-Date) -ge $deadline) { return $false }
        Start-Sleep -Milliseconds $PollMs
    }
}

function Invoke-ServeShimSession {
    # Drive one full shim session and return a rich result hashtable the Its assert on. Contains
    # ONE shim+PSES lifetime end to end (spawn -> initialize -> [nav] -> shutdown -> reap), so the
    # whole scenario is a single BeforeAll with no cross-It process state. In 'shim' mode the client
    # sends workspaceFolders + OMITS rename (proving the #2300 + rename dodges) and, if -RunNav, runs
    # hover/definition/references. In 'off' mode the client sends a well-formed CC-shaped initialize
    # (rename declared, no workspaceFolders) so PSES inits and its server->client requests LEAK
    # (proving no interception).
    param(
        [string]$ScriptsDir, [string]$Interpreter, [string]$Mode, [string]$DataRoot,
        [int]$CapMs = 60000, [switch]$RunNav
    )
    $result = @{
        Launched = $false; InitResult = $null; InitHasStaticNav = $false; Leaks = @();
        Hover = $null; Definition = $null; References = $null;
        Timings = @{}; MaxNavMs = 0; Exited = $false; ExitCode = -999; PsesPid = 0; PsesReaped = $false
        PsesIdentified = $true; Error = ''
    }
    $st = $null
    try {
        $fixture = Join-Path $DataRoot ('serve-nav-' + ([guid]::NewGuid().ToString('N').Substring(0, 8)) + '.ps1')
        [System.IO.File]::WriteAllText($fixture, $script:ServeShimFixtureText, (New-Object System.Text.UTF8Encoding($false)))
        $uri = ConvertTo-FileUri $fixture

        $st = Start-ServeShimClient -ScriptsDir $ScriptsDir -Interpreter $Interpreter -Mode $Mode -DataRoot $DataRoot
        $result.Launched = $true

        $caps = New-ServeShimRichCapabilities
        $initParams = @{ processId = $PID; clientInfo = @{ name = 'serve-shim-harness'; version = '1' }; rootUri = (ConvertTo-FileUri $DataRoot); capabilities = $caps }
        if ($Mode -eq 'shim') {
            # workspaceFolders present + rename ABSENT: only the shim's patch lets this init.
            $initParams['workspaceFolders'] = @(@{ uri = (ConvertTo-FileUri $DataRoot); name = 'root' })
        } else {
            # transparent relay: a well-formed CC client declares rename (else PSES's direct-path NRE).
            $caps['textDocument']['rename'] = @{ dynamicRegistration = $true; prepareSupport = $true }
        }
        Write-LspFrame -Stream $st.To -Json (@{ jsonrpc = '2.0'; id = 1; method = 'initialize'; params = $initParams } | ConvertTo-Json -Depth 30 -Compress)
        $result.InitResult = Receive-ServeShimResponse -St $st -TargetId 1 -TimeoutMs $CapMs
        if ($null -ne $result.InitResult) {
            $rcaps = Get-Prop (Get-Prop $result.InitResult 'result') 'capabilities'
            $result.InitHasStaticNav = ($null -ne $rcaps) -and ($rcaps.PSObject.Properties.Name -contains 'definitionProvider') -and `
                ($rcaps.PSObject.Properties.Name -contains 'hoverProvider') -and ($rcaps.PSObject.Properties.Name -contains 'referencesProvider')
        }

        Write-LspFrame -Stream $st.To -Json (@{ jsonrpc = '2.0'; method = 'initialized'; params = @{} } | ConvertTo-Json -Depth 5 -Compress)
        Write-LspFrame -Stream $st.To -Json (@{ jsonrpc = '2.0'; method = 'textDocument/didOpen'; params = @{ textDocument = @{ uri = $uri; languageId = 'powershell'; version = 0; text = $script:ServeShimFixtureText } } } | ConvertTo-Json -Depth 20 -Compress)

        if ($RunNav) {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            Write-LspFrame -Stream $st.To -Json (@{ jsonrpc = '2.0'; id = 2; method = 'textDocument/hover'; params = @{ textDocument = @{ uri = $uri }; position = @{ line = $script:ServeShimDefLine; character = $script:ServeShimDefChar } } } | ConvertTo-Json -Depth 20 -Compress)
            $result.Hover = Receive-ServeShimResponse -St $st -TargetId 2 -TimeoutMs 30000
            $result.Timings['hover'] = [int]$sw.ElapsedMilliseconds

            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            Write-LspFrame -Stream $st.To -Json (@{ jsonrpc = '2.0'; id = 3; method = 'textDocument/definition'; params = @{ textDocument = @{ uri = $uri }; position = @{ line = $script:ServeShimCallLine; character = $script:ServeShimCallChar } } } | ConvertTo-Json -Depth 20 -Compress)
            $result.Definition = Receive-ServeShimResponse -St $st -TargetId 3 -TimeoutMs 30000
            $result.Timings['definition'] = [int]$sw.ElapsedMilliseconds

            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            Write-LspFrame -Stream $st.To -Json (@{ jsonrpc = '2.0'; id = 4; method = 'textDocument/references'; params = @{ textDocument = @{ uri = $uri }; position = @{ line = $script:ServeShimDefLine; character = $script:ServeShimDefChar }; context = @{ includeDeclaration = $true } } } | ConvertTo-Json -Depth 20 -Compress)
            $result.References = Receive-ServeShimResponse -St $st -TargetId 4 -TimeoutMs 30000
            $result.Timings['references'] = [int]$sw.ElapsedMilliseconds

            $m = 0; foreach ($v in $result.Timings.Values) { if ([int]$v -gt $m) { $m = [int]$v } }
            $result.MaxNavMs = $m
        } else {
            # transparent (off): give PSES the beat to emit its server->client requests (which leak),
            # bounded; the config leak already lands during init, so this is a short top-up only.
            Receive-ServeShimResponse -St $st -TargetId 999999 -TimeoutMs 3000 | Out-Null
        }

        # Identify THIS shim's PSES child while the session is still live (scoped: pid + start time).
        $result.PsesPid = Get-ServeShimPsesPid -ShimPid $st.Proc.Id -ShimStart $st.ShimStart

        Write-LspFrame -Stream $st.To -Json (@{ jsonrpc = '2.0'; id = 9; method = 'shutdown' } | ConvertTo-Json -Depth 5 -Compress)
        Receive-ServeShimResponse -St $st -TargetId 9 -TimeoutMs 8000 | Out-Null
        Write-LspFrame -Stream $st.To -Json (@{ jsonrpc = '2.0'; method = 'exit'; params = @{} } | ConvertTo-Json -Depth 5 -Compress)
        $st.To.Close()
        $result.Exited = $st.Proc.WaitForExit(15000)
        if ($result.Exited) { $result.ExitCode = $st.Proc.ExitCode } else { try { $st.Proc.Kill($true) } catch { } }

        # Readiness gate, not a fixed sleep: wait (bounded) for the identified child to actually
        # go away. Returns the instant it does.
        if ($result.PsesPid -gt 0) {
            $result.PsesReaped = Wait-ServeShimProcessGone -ProcessIdValue $result.PsesPid -TimeoutMs 10000
            if (-not $result.PsesReaped) {
                $result.Error = 'PSES child pid ' + $result.PsesPid + ' was still alive 10000ms after the shim exited (orphan leak)'
            }
        } else {
            # Non-vacuity: the scoped lookup found no child for THIS shim. Pre-000127 this
            # silently reported "reaped" and the assertion passed having measured nothing.
            $result.PsesReaped = $true
            $result.PsesIdentified = $false
        }
        $result.Leaks = @($st.Leaks | Select-Object -Unique)
    } catch {
        $result.Error = [string]$_.Exception.Message
    } finally {
        Stop-ServeShimClient -St $st
    }
    return $result
}

function Invoke-ServeShimCrash {
    # Lifecycle: init the shim, then KILL PSES mid-session and assert the shim propagates EOF and
    # EXITS promptly (it must NOT re-spawn PSES -- the manifest maxRestarts owns restart). Returns
    # @{ Launched; PsesPid; ShimExitedAfterCrash; PsesReaped }.
    param([string]$ScriptsDir, [string]$Interpreter, [string]$DataRoot, [int]$CapMs = 60000)
    $result = @{ Launched = $false; PsesPid = 0; ShimExitedAfterCrash = $false; PsesReaped = $false; Error = ''; LifecycleRecordPath = ''; ShimPid = 0; ExitPath = 'no-shim-log' }
    $st = $null
    # Phase observations for the lifecycle record (dispatch 000163 leg 2). Declared BEFORE the try
    # so the finally can still write a record on the early-return and exception paths.
    $phase = @{
        PsesKillRequested = $false; PsesKillError = ''
        PsesKilledAtUtc = ''; FirstWaitReturnedAtUtc = ''
        SecondChanceWaited = $false; SecondChanceExited = $false
        ShimHasExited = $false; ShimExitCode = $null
    }
    try {
        $st = Start-ServeShimClient -ScriptsDir $ScriptsDir -Interpreter $Interpreter -Mode 'shim' -DataRoot $DataRoot
        $result.Launched = $true
        $caps = New-ServeShimRichCapabilities
        $initParams = @{ processId = $PID; clientInfo = @{ name = 'serve-shim-crash'; version = '1' }; rootUri = (ConvertTo-FileUri $DataRoot); workspaceFolders = @(@{ uri = (ConvertTo-FileUri $DataRoot); name = 'root' }); capabilities = $caps }
        Write-LspFrame -Stream $st.To -Json (@{ jsonrpc = '2.0'; id = 1; method = 'initialize'; params = $initParams } | ConvertTo-Json -Depth 30 -Compress)
        $null = Receive-ServeShimResponse -St $st -TargetId 1 -TimeoutMs $CapMs
        Write-LspFrame -Stream $st.To -Json (@{ jsonrpc = '2.0'; method = 'initialized'; params = @{} } | ConvertTo-Json -Depth 5 -Compress)
        # Readiness gate, not a fixed sleep: wait (bounded) for THIS shim's PSES child to become
        # identifiable. The old fixed 500ms both guessed at spawn latency AND, because the lookup
        # was unscoped, could return a foreign host -- and this scenario KILLS what it finds, so a
        # misidentification killed an unrelated process while the real PSES lived on and the shim
        # never saw the EOF the assertion below is about.
        $result.PsesPid = Wait-ServeShimPsesPid -ShimPid $st.Proc.Id -ShimStart $st.ShimStart -TimeoutMs 15000
        if ($result.PsesPid -le 0) {
            # Explicit, non-vacuous failure text: without a positively identified child there is
            # nothing to crash, so the scenario proves nothing and must say so rather than pass.
            $result.Error = 'could not identify this shim (pid ' + $st.Proc.Id + ') PSES child within 15000ms; the crash scenario was not exercised'
            return $result
        }
        # Record WHETHER the kill was even accepted (dispatch 000163 leg 2). The empty catch here
        # used to swallow a Stop-Process failure outright, so a scenario that never actually killed
        # PSES was indistinguishable from one that did -- and the assertion below would then be
        # measuring nothing. Observability only: the catch stays swallow-all, as before.
        $phase.PsesKilledAtUtc = ([datetime]::UtcNow.ToString('o'))
        try { Stop-Process -Id $result.PsesPid -Force -ErrorAction Stop; $phase.PsesKillRequested = $true } catch { $phase.PsesKillError = [string]$_.Exception.Message }
        # The shim must notice PSES's stdout EOF and exit promptly (bounded).
        $result.ShimExitedAfterCrash = $st.Proc.WaitForExit(15000)
        $phase.FirstWaitReturnedAtUtc = ([datetime]::UtcNow.ToString('o'))
        if (-not $result.ShimExitedAfterCrash) {
            # FAILING PATH ONLY -- so the passing path keeps its exact timing (the 000159 contract).
            # Distinguishes a shim that exits LATE from one that never exits at all; both prior
            # sightings reported the same bare $false and could not tell them apart.
            $phase.SecondChanceWaited = $true
            $phase.SecondChanceExited = $st.Proc.WaitForExit(15000)
        }
        try { $phase.ShimHasExited = [bool]$st.Proc.HasExited } catch { $phase.ShimHasExited = $false }
        # Read the exit code only when it EXISTS -- touching ExitCode on a live process throws, and
        # reading it after Stop-ServeShimClient's kill would report the kill, not the shim's own exit.
        if ($phase.ShimHasExited) { try { $phase.ShimExitCode = [int]$st.Proc.ExitCode } catch { $phase.ShimExitCode = $null } }
        $result.PsesReaped = Wait-ServeShimProcessGone -ProcessIdValue $result.PsesPid -TimeoutMs 10000
    } catch {
        $result.Error = [string]$_.Exception.Message
    } finally {
        Stop-ServeShimClient -St $st
        # Diagnosability only (dispatch 000163 leg 2): AFTER the shim is down, so its stderr sink is
        # flushed and closed and the exception record -- if any -- is on disk. Runs on every path,
        # including the PsesPid<=0 early return, because a scenario that proved nothing should say so
        # in the artifact too. Cannot fail the scenario: Save-* swallows all and returns ''.
        try { $result.LifecycleRecordPath = Save-ServeShimLifecycleRecord -St $st -DataRoot $DataRoot -Tag 'crash' -Phase $phase } catch { }
        # Classify here, where $st (and so the shim pid) is in scope, and carry it out on the result
        # so the failure text can NAME the mechanism instead of reporting a bare $false.
        try {
            if ($null -ne $st -and $null -ne $st.Proc) { $result.ShimPid = [int]$st.Proc.Id }
            $result.ExitPath = Get-ServeShimExitPath -LogSlice (Get-ServeShimLogSlice -DataRoot $DataRoot -ShimPid ([int]$result.ShimPid))
        } catch { }
    }
    return $result
}

function Invoke-ServeShimDriver {
    # Run ONE e2e scenario in a PWSH SUBPROCESS (ServeShim.Driver.ps1) and return the parsed flat
    # result. This is how the e2e BeforeAll drives the scenario on EVERY leg: the interactive
    # client<->shim stdio is done by pwsh (pwsh<->pwsh), NOT by the Pester host -- because a 5.1 host's
    # interactive writes to a child's stdin do not deliver on the headless windows-powershell CI
    # runner. The leg's Pester (pwsh or 5.1) only spawns this pwsh driver and reads its result file.
    param(
        [Parameter(Mandatory = $true)][string]$TestsDir,
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][string]$Scenario,
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [switch]$RunNav,
        [int]$CapMs = 120000
    )
    $resultPath = Join-Path $DataRoot ('serve-driver-' + ([guid]::NewGuid().ToString('N').Substring(0, 8)) + '.json')
    $driver = Join-Path $TestsDir 'ServeShim.Driver.ps1'
    $driverArgs = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $driver,
        '-Mode', $Mode, '-Scenario', $Scenario, '-DataRoot', $DataRoot, '-ResultPath', $resultPath)
    if ($RunNav) { $driverArgs += '-RunNav' }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'pwsh'; $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    Add-ProcessArguments $psi $driverArgs
    $p = [System.Diagnostics.Process]::Start($psi)
    $null = $p.StandardOutput.ReadToEndAsync()
    $null = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($CapMs)) {
        try { $p.Kill($true) } catch { }
        return ([pscustomobject]@{ Launched = $false; Error = 'driver timed out' })
    }
    if (-not (Test-Path -LiteralPath $resultPath)) {
        return ([pscustomobject]@{ Launched = $false; Error = ('driver produced no result (exit ' + $p.ExitCode + ')') })
    }
    $json = Get-Content -LiteralPath $resultPath -Raw
    try { Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue } catch { }
    return ($json | ConvertFrom-Json)
}
