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

function Wait-DaemonDiagReady {
    # PROGRESS-AWARE It-time serve-readiness gate (dispatch 000236). The ONE implementation
    # behind Wait-RulesetDiagReady, Wait-HonorDiagReady and Wait-FmtWarm, which were three
    # byte-identical copies of a FIXED 90000 ms wall-clock ceiling and drifted apart the moment
    # any one of them was repaired. It keeps the 000051/000078 rule intact -- the caller supplies
    # its OWN $GetDiag closure, so each scenario still gates on the real request its assertion
    # fires, for its own file and cwd, and no shared probe can lock the wrong settings resolution.
    # Only the BUDGET MODEL changes.
    #
    # WHY the fixed ceiling was wrong (000236 leg 1/2, re-derived from the failing CI job logs):
    # the gate polls a warm, serving daemon whose every reply is the 000022 'incomplete' banner --
    # 278 bytes of "analysis did not complete", byte-identical on every poll. The daemon is alive,
    # PSES is attached, and the settings ARE resolved ('PSSA settings: honoring ...\base.psd1'
    # appears 1.2 s after PSES init); PSES is simply CPU-starved by the other daemons the suite
    # runs concurrently, and cannot produce the first publish for many tens of seconds. Observed
    # first-request -> settled on Windows CI: 8.4 s / 77.1 s / 125.6 s / 174.9 s. The 90 s ceiling
    # sat INSIDE that spread, so equivalent content went red, green, red, green across four runs.
    #
    # WHY polling harder is not the answer: pses-daemon.ps1 CLEARS the prior publish for the uri
    # and re-sends a versioned didChange on EVERY request, so each poll discards the analysis it
    # was waiting for and re-queues the work -- the failing run's daemon emitted nine publishes in
    # a 36 ms burst, one per poll. Each poll also spawns a fresh pwsh that competes with the very
    # PSES it is waiting on (one spawn took 24.8 s under that contention). So this gate BACKS OFF
    # instead of hammering: the sleep grows 1.5x per poll to $MaxPollSleepMs.
    #
    # THE BUDGET MODEL. Three observable outcomes per poll, where the old gate saw only two:
    #   READY  -- the response matches $ReadyPattern. Return it (unchanged).
    #   LIVE   -- a NON-EMPTY response that does not match. This is the progress signal: it proves
    #             the pipe is up, PSES is attached, the settings resolved, and an analysis is
    #             queued. A dead or never-started daemon cannot produce it.
    #   DARK   -- an empty/whitespace response (client killed at its process cap, or unreachable).
    #             When -SessionId is supplied this is corroborated by a cheap DIRECT-PIPE ping
    #             (no pwsh spawn), because a client killed at its cap returns '' while the daemon
    #             is perfectly healthy -- exactly what happened on poll 7 of the red run.
    # The deadline starts at $TimeoutMs and is extended to (last LIVE observation +
    # $ProgressGraceMs) -- extended ONLY by observed liveness, never by the clock -- and is then
    # clamped to $HardCapMs, which is never exceeded for any reason. A daemon that is merely noisy
    # rather than progressing therefore still dies at $HardCapMs.
    #
    # DEAD-DAEMON PROTECTION IS STRICTLY BETTER, NOT WORSE. A larger constant would buy silence:
    # a genuinely dead daemon would take twice as long to say so. Here liveness is what buys time,
    # so a daemon that never answers trips $DarkPollsToFail consecutive dark polls and fails in
    # SECONDS instead of burning the full ceiling, and a PERMANENT PSES start failure
    # ('unavailable') short-circuits immediately instead of timing out with a misleading message.
    #
    # BOUND DERIVATION (000236 acceptance D -- derived from observation, not picked):
    #   $HardCapMs 240000       = 174.9 s worst observed settle (run 31747644193, windows-pwsh)
    #                             + 25 s for one full process-cap-killed poll (observed once)
    #                             + ~20% margin for a runner worse than any yet seen.
    #   $ProgressGraceMs 45000  = ~1.8x the worst observed gap between consecutive LIVE responses
    #                             (25 s, the killed-at-cap poll), so a live daemon is never cut off
    #                             mid-progress; kept well above $MaxPollSleepMs by construction.
    #   $TimeoutMs 90000        = the historical budget, UNCHANGED, so the fast common case
    #                             (settled in 8.4 s) behaves exactly as before.
    #
    # Returns the diagnostics text; THROWS a bounded, classified message on failure -- never a bare
    # $null/'' for an assertion to trip on (the 000078 contract).
    #
    # Requires Get-Prop (scripts/lib/lsp-common.ps1), dot-sourced by every caller.
    param(
        [Parameter(Mandatory = $true)][scriptblock]$GetDiag,
        [Parameter(Mandatory = $true)][string]$ReadyPattern,
        [string]$Scenario = 'daemon',
        [string]$Kind = 'daemon',
        [int]$TimeoutMs = 90000,
        [int]$HardCapMs = 240000,
        [int]$ProgressGraceMs = 45000,
        [int]$DarkPollsToFail = 3,
        [int]$PollSleepMs = 500,
        [int]$MaxPollSleepMs = 4000,
        [string]$SessionId = ''
    )
    # A caller-supplied budget larger than the cap would make the cap the (silent) real budget;
    # raise the cap instead so $TimeoutMs is always honored and the cap is only ever an EXTENSION
    # ceiling. Keeps the adversarial short-budget callers exact.
    if ($HardCapMs -lt $TimeoutMs) { $HardCapMs = $TimeoutMs }
    # INVARIANT: the backoff must stay well inside the grace window, or the gate could expire
    # BETWEEN two polls of a daemon that is still perfectly live -- reintroducing the very
    # false-red this dispatch removes. Self-enforcing so no caller can misconfigure it.
    if ($MaxPollSleepMs -ge $ProgressGraceMs) { $MaxPollSleepMs = [Math]::Max(50, [int]($ProgressGraceMs / 3)) }
    if ($PollSleepMs -gt $MaxPollSleepMs) { $PollSleepMs = $MaxPollSleepMs }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastLen = -1
    $polls = 0
    $liveCount = 0
    $darkCount = 0
    $consecutiveDark = 0
    $lastLiveMs = -1          # -1 = liveness NEVER observed, so no grace has been earned yet
    $sleepMs = $PollSleepMs
    $deadline = $TimeoutMs
    $reason = 'budget exhausted before the daemon returned a matching analysis'

    while ($true) {
        # Deadline recomputed each pass: the base budget, extended ONLY from an actual LIVE
        # observation, then clamped by the absolute cap. With $lastLiveMs -lt 0 (nothing ever
        # answered) the grace is never applied, so a short caller budget stays short.
        $deadline = $TimeoutMs
        if ($lastLiveMs -ge 0) { $deadline = [Math]::Max($deadline, $lastLiveMs + $ProgressGraceMs) }
        if ($deadline -gt $HardCapMs) { $deadline = $HardCapMs }
        if ([int]$sw.ElapsedMilliseconds -ge $deadline) {
            if ($deadline -ge $HardCapMs -and $liveCount -gt 0) {
                $reason = 'HARD CAP reached: the daemon stayed live but never returned a matching analysis'
            } elseif ($liveCount -gt 0) {
                $reason = 'budget exhausted: the daemon was live but progress stopped'
            }
            break
        }

        $polls++
        $out = & $GetDiag
        $text = [string]$out
        if (-not [string]::IsNullOrWhiteSpace($text) -and ($text -match $ReadyPattern)) { return $out }
        $lastLen = $text.Length

        $isLive = -not [string]::IsNullOrWhiteSpace($text)
        if (-not $isLive -and -not [string]::IsNullOrWhiteSpace($SessionId)) {
            # Corroborate darkness over the pipe DIRECTLY (no pwsh spawn, side-effect-free): an
            # empty client return is 'the CLIENT gave up', which is not the same as 'the DAEMON is
            # gone'. Only a failed ping too makes it genuinely dark.
            if (Wait-DaemonPipeReady -SessionId $SessionId -TimeoutMs 1500 -ConnectMs 500) { $isLive = $true }
        }

        if ($isLive) {
            # PERMANENT failure short-circuit: 'unavailable' means PSES could not start AT ALL and
            # will not for this session, so waiting out the budget can only produce a slower, less
            # informative failure (dispatch 000024 wording is the stable marker).
            if ($text -match 'PowerShell editor services could not start') {
                $reason = 'daemon reported PSES UNAVAILABLE (permanent start failure, not a timing condition)'
                break
            }
            $liveCount++
            $consecutiveDark = 0
            $lastLiveMs = [int]$sw.ElapsedMilliseconds
        } else {
            $darkCount++
            $consecutiveDark++
            if ($consecutiveDark -ge $DarkPollsToFail) {
                $reason = ('daemon DARK: ' + $consecutiveDark +
                    ' consecutive empty responses with no pipe ping -- failing fast rather than waiting out the budget')
                break
            }
        }

        Start-Sleep -Milliseconds $sleepMs
        # Back off: each extra poll discards a publish and steals CPU from PSES (see above).
        $sleepMs = [Math]::Min($MaxPollSleepMs, [int]($sleepMs * 1.5))
    }

    throw ($Kind + " daemon '" + $Scenario + "' did not return analysis within " + $deadline + 'ms (' + $reason +
        '); polls=' + $polls + ' live=' + $liveCount + ' dark=' + $darkCount +
        ' elapsed=' + [int]$sw.ElapsedMilliseconds + 'ms budget=' + $TimeoutMs + 'ms cap=' + $HardCapMs +
        'ms; last response length=' + $lastLen)
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

# ===========================================================================
# Flake instrumentation (dispatch 000159 leg 1a -- steps 1 and 2 of the 000156 shape)
# ===========================================================================
# WHY: dispatch 000156 leg 4 FALSIFIED the standing explanation of the honor-block
# flake (the recorded It duration was 3.3167s against a 25000ms cap -- nothing was
# killed at a cap), and then could go no further, because the two things it needed to
# see are both unobservable today:
#
#   (1) THE LOGS. Several Describe blocks mint an ISOLATED data root under the OS temp
#       dir (psls-degraded-*, psls-000024-*, psls-000028-A/B-*, psls-000030-*,
#       psls-df-itg-*, psls-000049-*). CI uploads ONLY psls-test-data/logs/** and
#       psls-test-data/session/** -- the SHARED root pinned by PSLS_TEST_DATA_DIR -- so
#       an isolated root sits outside the uploaded tree to begin with, and several
#       AfterAll blocks then discard it. Two barriers, not one; copying into the
#       uploaded tree at teardown clears both.
#
#   (2) THE OUTCOME. Invoke-PluginHook collapses THREE distinct failures into the same
#       empty string: killed at CapMs, exited normally with empty stdout, and the
#       stdout drain not completing within its 1500ms window. An assertion that trips
#       on '' cannot say which happened -- which is exactly why three dispatches of
#       confident timing reasoning produced nothing.
#
# Both helpers are DIAGNOSABILITY ONLY: no return value, no timing, and no control-flow
# change to anything they instrument. Step 3 of the recorded fix shape (bounded retry /
# widened window) is deliberately NOT implemented -- the evidence needed to choose
# between those two does not exist yet, and producing it is the point of this leg.
# No Start-Sleep is added anywhere.

function Save-IsolatedDataRootLog {
    # Copy an ISOLATED data root's logs/ and session/ into the artifact tree CI uploads,
    # so a failure inside a block that owns its own temp root stays diagnosable after the
    # run. Call from AfterAll BEFORE the root is torn down. No-op (returns 0) when
    # PSLS_TEST_DATA_DIR is unset -- a local run still has the root on disk, so there is
    # nothing to rescue. Never throws: instrumentation must not be able to fail a teardown.
    param(
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$Tag,
        [string]$ArtifactRoot = $env:PSLS_TEST_DATA_DIR
    )
    $copied = 0
    try {
        if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) { return 0 }
        if ([string]::IsNullOrWhiteSpace($DataRoot)) { return 0 }
        if (-not (Test-Path -LiteralPath $DataRoot)) { return 0 }
        $dest = Join-Path $ArtifactRoot ('logs/isolated/' + $Tag)
        foreach ($sub in @('logs', 'session')) {
            $src = Join-Path $DataRoot $sub
            if (-not (Test-Path -LiteralPath $src)) { continue }
            $files = @(Get-ChildItem -LiteralPath $src -File -Recurse -ErrorAction SilentlyContinue)
            if ($files.Count -eq 0) { continue }
            $subDest = Join-Path $dest $sub
            New-Item -ItemType Directory -Force -Path $subDest -ErrorAction SilentlyContinue | Out-Null
            foreach ($f in $files) {
                try {
                    Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $subDest $f.Name) -Force -ErrorAction Stop
                    $copied = $copied + 1
                } catch { }
            }
        }
    } catch { }
    return $copied
}

function Format-PluginHookOutcome {
    # One-line human rendering for an assertion message. Deliberately DISTINCT per
    # reason -- the RED-proof asserts the killed-at-cap and exited-empty-stdout texts
    # differ, which is the whole deliverable of step 2.
    param($Outcome)
    if ($null -eq $Outcome) { return 'hook outcome: (not recorded)' }
    $exitText = 'n/a'
    if ($null -ne $Outcome.ExitCode) { $exitText = [string]$Outcome.ExitCode }
    $detail = 'completed with output'
    switch ($Outcome.Reason) {
        'killed-at-cap' { $detail = 'KILLED at CapMs -- the process did not exit within the client hard cap' }
        'exited-empty-stdout' { $detail = 'EXITED normally but wrote NOTHING to stdout (NOT a cap overrun)' }
        'stdout-read-timeout' { $detail = 'exited, but the 1500ms stdout drain did not complete' }
    }
    return ('hook outcome: ' + $Outcome.Reason + ' -- ' + $detail +
        ' [elapsedMs=' + $Outcome.ElapsedMs + ' capMs=' + $Outcome.CapMs + ' exit=' + $exitText +
        ' script=' + (Split-Path -Leaf ([string]$Outcome.ScriptPath)) + ']')
}

function New-PluginHookOutcome {
    # Record WHY Invoke-PluginHook returned what it returned. The caller assigns the
    # result to its own $script:PslsHookOutcome; the hook's own return value is
    # untouched. The four reasons are mutually exclusive:
    #   ok                  -- exited within the cap, stdout drained, non-empty
    #   exited-empty-stdout -- exited within the cap, stdout drained, EMPTY
    #   killed-at-cap       -- WaitForExit($CapMs) expired; the process tree was killed
    #   stdout-read-timeout -- exited, but the 1500ms stdout drain did not complete
    # The middle two are the pair that rendered identically before this dispatch.
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('ok', 'exited-empty-stdout', 'killed-at-cap', 'stdout-read-timeout')]
        [string]$Reason,
        [int]$CapMs = 0,
        [int]$ElapsedMs = 0,
        $ExitCode = $null,
        [string]$ScriptPath = '',
        [string]$DataRoot = ''
    )
    $o = [pscustomobject]@{
        Reason     = $Reason
        CapMs      = $CapMs
        ElapsedMs  = $ElapsedMs
        ExitCode   = $ExitCode
        ScriptPath = $ScriptPath
        DataRoot   = $DataRoot
    }
    # Best-effort trace into the uploaded tree, so a CI failure carries the outcome even
    # when nothing in the test happens to print it. Never throws.
    try {
        if (-not [string]::IsNullOrWhiteSpace($env:PSLS_TEST_DATA_DIR)) {
            $logDir = Join-Path $env:PSLS_TEST_DATA_DIR 'logs'
            if (-not (Test-Path -LiteralPath $logDir)) {
                New-Item -ItemType Directory -Force -Path $logDir -ErrorAction SilentlyContinue | Out-Null
            }
            $line = (Get-Date).ToString('o') + ' ' + (Format-PluginHookOutcome $o)
            Add-Content -LiteralPath (Join-Path $logDir 'plugin-hook-outcomes.log') -Value $line -Encoding ascii -ErrorAction SilentlyContinue
        }
    } catch { }
    return $o
}
