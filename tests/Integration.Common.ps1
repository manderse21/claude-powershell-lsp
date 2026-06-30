#Requires -Version 5.1

# Integration.Common.ps1 -- shared test-support helpers for the daemon integration
# suite (PowerShellLsp.Integration.Tests.ps1). NOT a *.Tests.ps1 file, so Pester
# discovery (Run.Path = tests/, default *.Tests.ps1 glob) never collects it as a
# test. Dot-sourced from the relevant BeforeAll blocks AFTER scripts/lib/lsp-common.ps1
# (it uses Get-Prop), mirroring the corpus/Corpus.Common.ps1 and bench/Benchmark.Common.ps1
# support-file pattern.
#
# ASCII-only (PS 5.1 reads a UTF-8-without-BOM file through the Windows-1252 codepage;
# keep to bytes 0x00-0x7F -- "--" not an em-dash, straight quotes only).
#
# Author: Mike Andersen / powershell-lsp plugin.

function Wait-DaemonPipeReady {
    # Deterministic readiness wait for the pipe-first daemon (dispatch 000050).
    #
    # WHY: the daemon writes its session-file state ('starting' / 'unavailable' /
    # 'ready') BEFORE its serve loop first reaches WaitForConnectionAsync -- the
    # 'starting' write happens right after the pipe is created, ahead of the loop
    # (pses-daemon.ps1). So "the session file shows state X" does NOT prove the daemon
    # is yet ACCEPTING + ANSWERING requests over the named pipe. A test that fires its
    # first request off the session-file signal alone can race the serve-loop entry on
    # a loaded runner: the client's bounded connect/read returns $null, which sends it
    # down the 000030 auto-relaunch + retry path whose wall-time can exceed
    # Invoke-PluginHook's CapMs -- the client is then killed and the harness returns ''
    # (the intermittent empty result the 000028 sub-case A test red on). That is exactly
    # the wall-clock proxy the 000028 design said to avoid: assert over the pipe / a real
    # readiness signal, never a fixed sleep (the 000026 lesson).
    #
    # SIGNAL: a 'ping' round-trip over the pipe. The serve loop answers 'ping' the
    # instant it is running, in EVERY state (initializing, unavailable, ready), and the
    # ping handler is side-effect-free w.r.t. analysis/init state -- so a ready ping
    # proves "the daemon will answer the request the test is about to send" without
    # perturbing what that request observes. Poll with a generous bound; return $true the
    # instant the pipe answers, $false on timeout (a genuinely not-serving daemon -- a
    # real failure the caller surfaces, never a silent skip).
    #
    # Requires Get-Prop (scripts/lib/lsp-common.ps1), dot-sourced by every caller.
    param(
        [Parameter(Mandatory = $true)][string]$SessionId,
        [int]$TimeoutMs = 20000,
        [int]$ConnectMs = 1000
    )
    $pipeName = 'powershell-lsp-' + $SessionId
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $client = $null
        try {
            $client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipeName,
                [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
            $remaining = [Math]::Max(1, $TimeoutMs - [int]$sw.ElapsedMilliseconds)
            $client.Connect([Math]::Min($ConnectMs, $remaining))
            $writer = New-Object System.IO.StreamWriter($client, (New-Object System.Text.UTF8Encoding($false)), 4096, $true)
            $writer.NewLine = "`n"; $writer.AutoFlush = $true
            $reader = New-Object System.IO.StreamReader($client, [System.Text.Encoding]::UTF8, $false, 4096, $true)
            $writer.WriteLine((@{ action = 'ping' } | ConvertTo-Json -Compress)); $writer.Flush()
            $remaining = [Math]::Max(1, $TimeoutMs - [int]$sw.ElapsedMilliseconds)
            $readTask = $reader.ReadLineAsync()
            if ($readTask.Wait([Math]::Min(2000, $remaining))) {
                $line = $readTask.Result
                if (-not [string]::IsNullOrWhiteSpace($line)) {
                    $obj = $null
                    try { $obj = $line | ConvertFrom-Json } catch { $obj = $null }
                    if ($null -ne $obj -and [string](Get-Prop $obj 'action') -eq 'ping' -and [bool](Get-Prop $obj 'ok')) {
                        return $true
                    }
                }
            }
        } catch {
            # Not serving yet (no pipe instance / connect refused / busy / read timed
            # out) -- swallow and retry within the bound. A persistently-unreachable
            # daemon falls through to the $false return below.
        } finally {
            if ($null -ne $client) { try { $client.Dispose() } catch { } }
        }
        Start-Sleep -Milliseconds 150
    }
    return $false
}

function Wait-DaemonRequestReady {
    # Stronger serve-readiness wait (dispatch 000051) -- EXTENDS Wait-DaemonPipeReady, does not
    # replace it. A 'ping' proves the serve loop answers a TRIVIAL round-trip, but NOT that it will
    # service the heavier 'diagnostics' request the test's It actually fires within the client's bound.
    # Right after a ping the daemon can still be contending with its cooperative PSES init pump (and,
    # in the full suite, a concurrent warm-PSES bring-up on a loaded runner), so the FIRST real
    # diagnostics request can race serve-loop entry: the client's bounded connect/read returns $null,
    # which routes into the 000030 auto-relaunch + retry path, whose accumulated wall-time (each retry
    # gets a FRESH per-call read budget) can exceed Invoke-PluginHook's CapMs -- the client is killed
    # and the harness returns '' (empty $out). That is the residual 1-in-8 windows-pwsh flake the ping
    # gate NARROWED but did not CLOSE (dispatch 000050: 5x local + PR + one post-merge run green, then
    # red 1-in-8 on the same test). Ping is a different, lighter, earlier round-trip than the request
    # the It depends on, so a green ping does not prove the It's request will be serviced promptly.
    #
    # CURE: wait until a genuine 'diagnostics' round-trip -- the SAME action the It sends -- has
    # demonstrably COMPLETED over the pipe. In the not-ready states these siblings assert
    # (initializing -> 'incomplete', unavailable -> 'unavailable'), the daemon's serve response is
    # STABLE: once it services one real diagnostics request it services every subsequent one
    # identically fast, so by the time the It fires, the CapMs-bounded relaunch+retry path is never
    # the thing under timing pressure in the assertion. This closes the window (assert over the SAME
    # signal the It depends on) rather than widening a tolerance -- the 000026/000028 design rule.
    #
    # SIGNAL: stage 1 is the 000050 ping gate (kept load-bearing -- the serve loop is running and
    # answering); stage 2 is a real 'diagnostics' request for a UNIQUE throwaway probe file in the
    # data root. The daemon answers with a well-formed { action = 'diagnostics' } in every served
    # state. The probe uses its OWN file (never the It's fixture), so it cannot warm the content-hash
    # cache or open a doc the It observes; in the not-ready states the daemon's serve gate returns
    # before any didOpen, so the probe is side-effect-free w.r.t. analysis state, exactly like ping.
    # It talks to the pipe DIRECTLY (never via lsp-client.ps1), so it NEVER spawns a relaunch or writes
    # a cooldown stamp -- which would pollute the 030-permanent no-stamp / pid-unchanged assertions.
    # Bounded; $true on the first well-formed diagnostics response, $false on timeout (a daemon that
    # never serviced a real request is a genuine failure the caller surfaces loudly, never a silent skip).
    #
    # Requires Get-Prop (scripts/lib/lsp-common.ps1), dot-sourced by every caller.
    param(
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [int]$TimeoutMs = 20000,
        [int]$ConnectMs = 1000
    )
    # Stage 1: keep the 000050 ping gate intact (serve loop running + answering at all).
    if (-not (Wait-DaemonPipeReady -SessionId $SessionId -TimeoutMs $TimeoutMs -ConnectMs $ConnectMs)) { return $false }

    # Stage 2: a real diagnostics round-trip. The probe file must EXIST so the request traverses the
    # same file-check -> serve-gate path the It's existing fixture does. Unique per session; cleaned up.
    $pipeName = 'powershell-lsp-' + $SessionId
    $probeFile = Join-Path $DataRoot ('reqready-' + $SessionId + '.ps1')
    try { Set-Content -LiteralPath $probeFile -Value "function Get-ReqReady { 1 }`n" -Encoding ascii -Force } catch { }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
            $client = $null
            try {
                $client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipeName,
                    [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
                $remaining = [Math]::Max(1, $TimeoutMs - [int]$sw.ElapsedMilliseconds)
                $client.Connect([Math]::Min($ConnectMs, $remaining))
                $writer = New-Object System.IO.StreamWriter($client, (New-Object System.Text.UTF8Encoding($false)), 4096, $true)
                $writer.NewLine = "`n"; $writer.AutoFlush = $true
                $reader = New-Object System.IO.StreamReader($client, [System.Text.Encoding]::UTF8, $false, 4096, $true)
                $writer.WriteLine((@{ action = 'diagnostics'; file = $probeFile; cwd = $DataRoot } | ConvertTo-Json -Compress)); $writer.Flush()
                $remaining = [Math]::Max(1, $TimeoutMs - [int]$sw.ElapsedMilliseconds)
                $readTask = $reader.ReadLineAsync()
                if ($readTask.Wait([Math]::Min(5000, $remaining))) {
                    $line = $readTask.Result
                    if (-not [string]::IsNullOrWhiteSpace($line)) {
                        $obj = $null
                        try { $obj = $line | ConvertFrom-Json } catch { $obj = $null }
                        # A well-formed diagnostics response (any served state) proves the daemon
                        # serviced the heavier request the It is about to send -- the readiness signal.
                        if ($null -ne $obj -and [string](Get-Prop $obj 'action') -eq 'diagnostics') {
                            return $true
                        }
                    }
                }
            } catch {
                # Not servicing the diagnostics request yet (connect refused / busy / read timed out)
                # -- swallow and retry within the bound. A persistently-unserving daemon falls through
                # to the $false return below.
            } finally {
                if ($null -ne $client) { try { $client.Dispose() } catch { } }
            }
            Start-Sleep -Milliseconds 150
        }
        return $false
    } finally {
        try { if (Test-Path -LiteralPath $probeFile) { Remove-Item -LiteralPath $probeFile -Force -ErrorAction SilentlyContinue } } catch { }
    }
}

# ===========================================================================
# Process-leak reap (dispatch 000078)
# ===========================================================================
# WHY: the integration daemon fixtures that launch DETACHED via session-start.ps1
# (Start-PsesDaemonDetached -- no OS Process handle ever returned to the test) reap
# their daemon ONLY by reading the session file's recorded pid AFTER a bounded
# readiness wait, behind a `if ($null -ne $info)` guard. Under process-leak
# contention (the dispatch 000078 evidence: 7 leaked PSES/daemon processes from
# prior runs slowed a verify to ~2x and fast-failed the 000018 GREEN test), the
# daemon's warm-start exceeds that bounded wait, the wait returns $null, the guard
# SKIPS, and the daemon -- which comes up moments later -- is never reaped. Each
# leaked daemon then contends the next run, a vicious cycle. (The raw-launch
# fixtures that hold a [Diagnostics.Process] and call $p.Kill($true) on the tree are
# already leak-safe; so is the benchmark, which routes teardown through the
# production session-end.ps1 hook. Only the detached session-start fixtures leak.)
#
# CURE: reap the daemon by reading the session file FRESH at teardown (so it works
# even when the test's readiness wait timed out and never captured $info -- the leak
# vector), keyed on the suite's OWN recorded session id, and VERIFY-BEFORE-KILL.
# This mirrors the production reap discipline EXACTLY (session-start.ps1 Invoke-Reap
# / session-end.ps1 Test-IsOurDaemon + Stop-OrphanPses): never a broad pwsh match,
# never a name-only kill -- the host is multi-tenant (a co-developer's editor host,
# the operator's interactive shell, other pwsh work must all survive). The signature
# here is even TIGHTER than production's: the daemon's command line must reference
# BOTH pses-daemon.ps1 AND the suite's own -SessionId <sid> (guid-unique, suite-owned),
# which is immune to PID reuse and can never match a co-tenant process.
#
# Requires Get-ProcessCommandLine (scripts/lib/lsp-common.ps1), dot-sourced by every caller.

function Test-IsOurIntegrationDaemon {
    # Verify-before-kill predicate for a recorded daemon pid: a PowerShell host whose
    # command line references pses-daemon.ps1 AND carries this suite's own -SessionId
    # <sid>. The sid is guid-unique and suite-owned, so a match is unambiguously OUR
    # daemon -- never a co-tenant editor host / operator shell, and immune to PID reuse
    # (a reused pid would carry a different command line). Returns $false on any doubt.
    param([Parameter(Mandatory = $true)][int]$ProcessIdValue, [Parameter(Mandatory = $true)][string]$SessionId)
    try {
        $proc = Get-Process -Id $ProcessIdValue -ErrorAction SilentlyContinue
        if ($null -eq $proc) { return $false }
        if (@('pwsh', 'powershell') -notcontains $proc.ProcessName.ToLowerInvariant()) { return $false }
        $cl = Get-ProcessCommandLine $ProcessIdValue
        if ([string]::IsNullOrWhiteSpace($cl)) { return $false }
        return (($cl -match 'pses-daemon\.ps1') -and ($cl -match ('-SessionId\s+' + [regex]::Escape($SessionId) + '(\s|"|$)')))
    } catch { return $false }
}

function Test-IsOurIntegrationPses {
    # Verify-before-kill predicate for a recorded PSES child pid (mirrors the
    # production session-end.ps1 Stop-OrphanPses check). The pid is read from OUR
    # session file (written by OUR daemon for OUR sid), so it is our PSES; the
    # command-line check that it is a Start-EditorServices.ps1 host guards PID reuse.
    # PSES's command line does not carry the sid (it is launched by the daemon), so
    # the daemon-side sid match above is what scopes the pair to us.
    param([Parameter(Mandatory = $true)][int]$ProcessIdValue)
    try {
        $proc = Get-Process -Id $ProcessIdValue -ErrorAction SilentlyContinue
        if ($null -eq $proc) { return $false }
        if (@('pwsh', 'powershell') -notcontains $proc.ProcessName.ToLowerInvariant()) { return $false }
        return ((Get-ProcessCommandLine $ProcessIdValue) -match 'Start-EditorServices\.ps1')
    } catch { return $false }
}

function Stop-IntegrationDaemon {
    # Robust, info-INDEPENDENT teardown of ONE detached daemon the suite spawned,
    # keyed on the suite's OWN recorded session id. Reads <DataRoot>/session/<sid>.json
    # FRESH (the daemon writes its pid there at 'starting', before serve-loop entry, so
    # the pid is resolvable even when the test's readiness wait timed out -- the dispatch
    # 000078 leak vector that the old `if ($null -ne $info)` reap missed), resolves the
    # daemon pid + the PSES child pid, and kills ONLY processes that VERIFY as ours
    # (Test-IsOurIntegrationDaemon / Test-IsOurIntegrationPses). Never a broad/name kill.
    # Returns the array of pids actually killed (for the leak-scan assertion).
    param([Parameter(Mandatory = $true)][string]$SessionId, [Parameter(Mandatory = $true)][string]$DataRoot)
    $killed = New-Object System.Collections.ArrayList
    $sf = Join-Path $DataRoot ('session/' + $SessionId + '.json')
    $recPid = 0; $psesPid = 0
    if (Test-Path -LiteralPath $sf) {
        try {
            $obj = (Get-Content -LiteralPath $sf -Raw) | ConvertFrom-Json
            $recPid = [int](Get-Prop $obj 'pid')
            $psesPid = [int](Get-Prop $obj 'psesPid')
        } catch { }
    }
    if ($recPid -gt 0 -and (Test-IsOurIntegrationDaemon -ProcessIdValue $recPid -SessionId $SessionId)) {
        try { Stop-Process -Id $recPid -Force -ErrorAction Stop; [void]$killed.Add($recPid) } catch { }
    }
    if ($psesPid -gt 0 -and (Test-IsOurIntegrationPses -ProcessIdValue $psesPid)) {
        try { Stop-Process -Id $psesPid -Force -ErrorAction Stop; [void]$killed.Add($psesPid) } catch { }
    }
    return $killed.ToArray()
}

function Get-IntegrationDaemonLeak {
    # READ-ONLY census of LIVE suite-owned daemons: PowerShell hosts whose command line
    # references pses-daemon.ps1 AND carries a -SessionId matching the suite's own naming
    # scheme (the prefixes the fixtures mint their sids from). Never kills -- used by the
    # suite-start guard (report a contaminated environment) and the suite-final backstop
    # (PROVE zero suite daemons survived). The pses-daemon.ps1 + sid-prefix signature can
    # never match a co-tenant editor host or the operator's shell. Returns objects with
    # .Id and .SessionId so a caller can verify-before-kill a straggler if it chooses.
    param(
        [string]$SessionIdPattern = '^(pester|honor|scope|restart|incomplete|degraded|exhaust|unavail|ss-surface|pf|rl|loop|bench|no-daemon|fmt)-'
    )
    $leaks = New-Object System.Collections.ArrayList
    try {
        $procs = @(Get-Process -Name 'pwsh', 'powershell' -ErrorAction SilentlyContinue)
        foreach ($p in $procs) {
            $cl = Get-ProcessCommandLine $p.Id
            if ([string]::IsNullOrWhiteSpace($cl)) { continue }
            if ($cl -notmatch 'pses-daemon\.ps1') { continue }
            $m = [regex]::Match($cl, '-SessionId\s+(\S+)')
            if (-not $m.Success) { continue }
            $sid = $m.Groups[1].Value.Trim('"')
            if ($sid -notmatch $SessionIdPattern) { continue }
            [void]$leaks.Add([pscustomobject]@{ Id = $p.Id; SessionId = $sid })
        }
    } catch { }
    return $leaks.ToArray()
}
