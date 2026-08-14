#Requires -Version 5.1

# The daemon survives a client that abandons its reply (dispatch 000237).
#
# WHAT WENT WRONG, AND WHY IT WAS INVISIBLE. The relaunch-thrash remeasurement
# (docs/roadmap-ii/POST-FIX-REMEASUREMENT-relaunch-thrash.md) found that once the client
# stopped relaunching healthy daemons, every remaining relaunch traced 1:1 to a genuine
# daemon death, and every death traced to the same event: the client walked away at its hard
# cap, the daemon's reply write raised "Pipe is broken.", the serve loop's per-request handler
# LOGGED it -- and the daemon exited anyway. Four exits per session, identical across five
# sessions. The open question the charter named was precisely that: the handler logs the
# exception, so why does the loop end?
#
# THE MECHANISM. The failed write moves the NamedPipeServerStream's internal state from
# Connected to BROKEN. `PipeStream.IsConnected` is `State == Connected`, so it reads FALSE --
# and the per-request finally's guard, `if ($server.IsConnected) { $server.Disconnect() }`,
# therefore SKIPPED the disconnect on exactly the path that needed it. The stream stayed
# Broken. The next `WaitForConnectionAsync()` -- which lived OUTSIDE the per-request try --
# threw IOException "Pipe is broken." synchronously, past the handler and into the loop's
# outer finally. That is why the measured log shows the handled error followed IMMEDIATELY by
# "main loop ended; cleanup", with no second handled error between them.
#
# WHAT THIS BLOCK PROVES, AND HOW. Both polarities are MEASURED in the same run against a
# real pipe server and a real abandoning client -- not reasoned about:
#
#   PREMISE  the reply write to a departed client genuinely fails (asserted, never assumed;
#            if it did not, everything below would be vacuous).
#   RED      the SHIPPED PRE-FIX SHAPE, kept verbatim and RUNNABLE in this file, leaves the
#            stream unable to accept -- the next accept throws.
#   GREEN    Reset-PipeServerConnection leaves the stream able to accept.
#   CAUSE    IsConnected is FALSE after the failed write, which is the precise reason the old
#            guard skipped -- so the RED is attributed, not merely observed.
#
# Keeping the pre-fix implementation verbatim in the test is deliberate: deleting the model
# you are replacing destroys your own control, and a RED that cannot be re-run is a claim
# rather than evidence.
#
# No daemon and no network in Describe 1: it builds its own pipe server and its own client, so
# it runs on every leg in about a second. Describe 2 drives the REAL daemon end to end and is
# platform-gated exactly like the other integration blocks.

# Discovery-time platform gate for -Skip (StrictMode-safe; PS 5.1 has no $IsWindows/$IsLinux).
$script:DsOnWindows = if (Test-Path 'Variable:\IsWindows') { [bool]$IsWindows } else { $true }
$script:DsOnLinux = (Test-Path 'Variable:\IsLinux') -and [bool]$IsLinux
$script:DsOnMacOS = (Test-Path 'Variable:\IsMacOS') -and [bool]$IsMacOS
$script:DsSkipIntegration = -not ($script:DsOnWindows -or $script:DsOnLinux -or $script:DsOnMacOS)

Describe 'Daemon serve loop survives an abandoned reply -- the mechanism (dispatch 000237)' {

    BeforeAll {
        $script:DsPluginRoot = Split-Path -Parent $PSScriptRoot
        . (Join-Path $script:DsPluginRoot 'scripts/lib/lsp-common.ps1')

        # Read PipeStream's private state field, so the RED can be ATTRIBUTED to the state
        # transition rather than merely correlated with it. Best-effort: a runtime that
        # renames the field yields 'unknown' and only the observable assertions carry.
        function script:Get-PipeInternalState {
            param($Server)
            try {
                $t = $Server.GetType()
                $f = $t.GetField('_state', [Reflection.BindingFlags]'NonPublic,Instance')
                while ($null -eq $f -and $null -ne $t.BaseType) { $t = $t.BaseType; $f = $t.GetField('_state', [Reflection.BindingFlags]'NonPublic,Instance') }
                if ($null -ne $f) { return [string]$f.GetValue($Server) }
            } catch { }
            return 'unknown'
        }

        # Drive one whole abandonment: a fresh server, a client that connects and then goes
        # away, and the daemon's reply write into the void. Returns the server left in exactly
        # the state the serve loop's per-request finally would find it in.
        #
        # The reply is deliberately LARGE. A short reply can land entirely in the transport
        # buffer and succeed even though the peer is gone, which would make the premise
        # nondeterministic; a payload far beyond any pipe or socket buffer cannot.
        function script:New-AbandonedReplyScenario {
            $name = 'psl-000237-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
            $server = New-DaemonPipeServer -PipeName $name
            $accept = $server.WaitForConnectionAsync()

            $client = New-Object System.IO.Pipes.NamedPipeClientStream(
                '.', $name, [System.IO.Pipes.PipeDirection]::InOut)
            $client.Connect(10000)
            if (-not $accept.Wait(10000)) { throw 'the probe client never connected' }

            $writer = New-Object System.IO.StreamWriter($server, (New-Object Text.UTF8Encoding($false)), 4096, $true)
            $writer.NewLine = "`n"; $writer.AutoFlush = $true

            # The client abandons at its hard cap: it never reads the reply and it goes away.
            $client.Dispose()

            $writeFailed = $false
            $writeError = ''
            $chunk = ('x' * 8192)
            try {
                for ($i = 0; $i -lt 256; $i++) { $writer.WriteLine($chunk); $writer.Flush() }
            } catch {
                $writeFailed = $true
                $ex = $_.Exception
                if ($ex.InnerException) { $ex = $ex.InnerException }
                $writeError = $ex.GetType().Name + ': ' + $ex.Message
            }

            return [pscustomobject]@{
                PipeName            = $name
                Server              = $server
                WriteFailed         = $writeFailed
                WriteError          = $writeError
                IsConnectedAfter    = $server.IsConnected
                InternalStateAfter  = (script:Get-PipeInternalState -Server $server)
            }
        }

        # Can this server accept another client? Asked the way the serve loop asks it, so a
        # pass here means the loop's next iteration would survive.
        function script:Test-ServerCanAccept {
            param($Server)
            try {
                $t = $Server.WaitForConnectionAsync()
                # Armed without throwing is the whole question; nothing will connect, so do
                # not wait on it beyond confirming it did not fault immediately.
                $null = $t.Wait(50)
                if ($t.IsFaulted) {
                    $ex = $t.Exception.GetBaseException()
                    return @{ CanAccept = $false; Error = ($ex.GetType().Name + ': ' + $ex.Message) }
                }
                return @{ CanAccept = $true; Error = '' }
            } catch {
                $ex = $_.Exception
                if ($ex.InnerException) { $ex = $ex.InnerException }
                return @{ CanAccept = $false; Error = ($ex.GetType().Name + ': ' + $ex.Message) }
            }
        }

        # --- RED: the SHIPPED PRE-FIX per-request finally, verbatim ------------------------
        $script:RedScenario = script:New-AbandonedReplyScenario
        # This next line IS the pre-000237 code, character for character:
        try { if ($script:RedScenario.Server.IsConnected) { $script:RedScenario.Server.Disconnect() } } catch { }
        $script:RedStateAfterFinally = script:Get-PipeInternalState -Server $script:RedScenario.Server
        $script:RedAccept = script:Test-ServerCanAccept -Server $script:RedScenario.Server

        # --- GREEN: the shipped POST-FIX per-request finally ------------------------------
        $script:GreenScenario = script:New-AbandonedReplyScenario
        $script:GreenReset = Reset-PipeServerConnection -Server $script:GreenScenario.Server
        $script:GreenStateAfterFinally = script:Get-PipeInternalState -Server $script:GreenScenario.Server
        $script:GreenAccept = script:Test-ServerCanAccept -Server $script:GreenScenario.Server
    }

    AfterAll {
        foreach ($s in @($script:RedScenario, $script:GreenScenario)) {
            if ($null -ne $s -and $null -ne $s.Server) { try { $s.Server.Dispose() } catch { } }
        }
    }

    Context 'the premise, measured rather than assumed' {

        It 'the reply write to a departed client genuinely FAILS (both scenarios)' {
            # If this were ever false, every assertion below would be passing over a
            # scenario that never happened.
            $script:RedScenario.WriteFailed | Should -BeTrue -Because "the RED scenario's write must fail; it reported: '$($script:RedScenario.WriteError)'"
            $script:GreenScenario.WriteFailed | Should -BeTrue -Because "the GREEN scenario's write must fail; it reported: '$($script:GreenScenario.WriteError)'"
            Write-Host "  RED   write error: $($script:RedScenario.WriteError)"
            Write-Host "  GREEN write error: $($script:GreenScenario.WriteError)"
        }

        It 'the failed write flips IsConnected to FALSE -- which is exactly why the old guard skipped' {
            # The attribution. The pre-fix line was `if ($server.IsConnected) { Disconnect }`;
            # this is the measurement that says the condition was false when it mattered.
            $script:RedScenario.IsConnectedAfter | Should -BeFalse
            $script:GreenScenario.IsConnectedAfter | Should -BeFalse
            Write-Host "  internal state after the failed write: RED=$($script:RedScenario.InternalStateAfter) GREEN=$($script:GreenScenario.InternalStateAfter)"
        }
    }

    Context 'RED -- the pre-fix shape leaves the daemon unable to serve the next client' {

        It 'the IsConnected-guarded Disconnect does NOT return the stream to a usable state' {
            $script:RedStateAfterFinally | Should -Not -BeExactly 'Disconnected' -Because 'the guard skips, so the stream is left exactly as the failed write left it'
            Write-Host "  RED state after the pre-fix finally: $($script:RedStateAfterFinally)"
        }

        It 'and the NEXT accept therefore FAILS -- this is the daemon death, reproduced' {
            $script:RedAccept.CanAccept | Should -BeFalse -Because 'this throw lands outside the per-request handler and ends the serve loop'
            $script:RedAccept.Error | Should -Not -BeNullOrEmpty
            Write-Host "  RED next-accept error: $($script:RedAccept.Error)"
        }
    }

    Context 'GREEN -- the fix returns the stream to a state that can accept' {

        It 'Reset-PipeServerConnection reports OK on a stream broken by an abandoned reply' {
            $script:GreenReset.Ok | Should -BeTrue -Because "it reported: '$($script:GreenReset.Reason)'"
            Write-Host "  GREEN reset reason: $($script:GreenReset.Reason)"
        }

        It 'the stream is Disconnected afterwards, not left Broken' {
            $script:GreenStateAfterFinally | Should -BeExactly 'Disconnected'
        }

        It 'and the NEXT accept SUCCEEDS -- one abandoned reply is one discarded write' {
            $script:GreenAccept.CanAccept | Should -BeTrue -Because "it reported: '$($script:GreenAccept.Error)'"
        }
    }

    Context 'the helper behaves on the paths that are not the defect' {

        It 'reports OK for a never-connected server (the empty-request path must not rebuild)' {
            $name = 'psl-000237-fresh-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            $s = New-DaemonPipeServer -PipeName $name
            try {
                $r = Reset-PipeServerConnection -Server $s
                $r.Ok | Should -BeTrue
                $r.Reason | Should -Match 'not connected'
            } finally { try { $s.Dispose() } catch { } }
        }

        It 'reports NOT-OK for a disposed server, so the caller rebuilds instead of looping on it' {
            $name = 'psl-000237-dead-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            $s = New-DaemonPipeServer -PipeName $name
            $s.Dispose()
            $r = Reset-PipeServerConnection -Server $s
            $r.Ok | Should -BeFalse
            $r.Reason | Should -Not -BeNullOrEmpty
        }

        It 'reports NOT-OK for a null server rather than throwing' {
            $r = Reset-PipeServerConnection -Server $null
            $r.Ok | Should -BeFalse
        }

        It 'New-DaemonPipeServer builds the single-instance async byte pipe the daemon contracts for' {
            # The single-instance property is what Test-DaemonPipePresent's busy-vs-absent
            # discrimination rests on, so a rebuild that quietly widened it would break the
            # 000225 gate rather than this file.
            $name = 'psl-000237-shape-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            $s = New-DaemonPipeServer -PipeName $name
            try {
                $s | Should -BeOfType ([System.IO.Pipes.NamedPipeServerStream])
                $s.CanRead | Should -BeTrue
                $s.CanWrite | Should -BeTrue
                # A second server on the same name must be refused while the first holds it.
                { New-DaemonPipeServer -PipeName $name } | Should -Throw
            } finally { try { $s.Dispose() } catch { } }
        }

        It 'a rebuilt server can take the SAME pipe name after the old one is disposed' {
            # The accept-region backstop depends on this: dispose, rebuild, keep serving.
            $name = 'psl-000237-rebuild-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            $s1 = New-DaemonPipeServer -PipeName $name
            $s1.Dispose()
            $s2 = New-DaemonPipeServer -PipeName $name
            try {
                (script:Test-ServerCanAccept -Server $s2).CanAccept | Should -BeTrue
            } finally { try { $s2.Dispose() } catch { } }
        }
    }
}

Describe 'Integration: the real daemon survives an abandoned reply (dispatch 000237)' -Skip:$script:DsSkipIntegration {
    # The end-to-end half. A real pses-daemon.ps1 process, a real client that sends a request
    # and dies without reading the answer, and then the question that matters: is the daemon
    # still there, and does it still serve?
    #
    # NO PSES BOOTSTRAP IS NEEDED and none is done. The daemon is launched against an empty
    # private data root, so it comes up pipe-first serving the honest 'unavailable' status --
    # which is enough, because the defect lives in the serve loop's connection handling and
    # not in the analyzer. That keeps this block fast and free of the bundle-vendoring
    # apparatus every other integration block carries.
    #
    # The abandoned reply is forced LARGE the same way Describe 1 forces it: the request's
    # `action` is a very long string and the daemon's unknown-action reply echoes it, so the
    # response cannot fit in a transport buffer and the write to the departed client must
    # fail. That uses only the shipped protocol -- no test-only daemon behaviour.

    BeforeAll {
        $script:DsRoot = Split-Path -Parent $PSScriptRoot
        . (Join-Path $script:DsRoot 'scripts/lib/lsp-common.ps1')

        $script:DsDataRoot = Join-Path ([IO.Path]::GetTempPath()) ('psl-000237-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
        New-Item -ItemType Directory -Force -Path $script:DsDataRoot | Out-Null
        $script:DsSid = 'ds' + [guid]::NewGuid().ToString('N').Substring(0, 10)
        $script:DsPipe = 'powershell-lsp-' + $script:DsSid

        $daemon = Join-Path $script:DsRoot 'scripts/pses-daemon.ps1'
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'pwsh'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        foreach ($a in @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $daemon,
                '-SessionId', $script:DsSid, '-PsHost', 'pwsh', '-DataRoot', $script:DsDataRoot,
                '-IdleTtlMin', '5')) {
            [void]$psi.ArgumentList.Add($a)
        }
        $psi.EnvironmentVariables['CLAUDE_PLUGIN_DATA'] = $script:DsDataRoot
        $script:DsProc = [System.Diagnostics.Process]::Start($psi)
        $null = $script:DsProc.StandardOutput.ReadToEndAsync()
        $null = $script:DsProc.StandardError.ReadToEndAsync()

        function script:Invoke-DsRequest {
            param([string]$Json, [int]$TimeoutMs = 8000, [switch]$Abandon)
            $c = New-Object System.IO.Pipes.NamedPipeClientStream('.', $script:DsPipe, [System.IO.Pipes.PipeDirection]::InOut)
            try {
                $c.Connect($TimeoutMs)
                $w = New-Object System.IO.StreamWriter($c, (New-Object Text.UTF8Encoding($false)), 4096, $true)
                $w.NewLine = "`n"; $w.AutoFlush = $true
                $w.WriteLine($Json)
                if ($Abandon) {
                    # The measured client behaviour: reach the hard cap, emit the banner, and
                    # go -- without ever reading the answer.
                    return $null
                }
                $r = New-Object System.IO.StreamReader($c, [Text.Encoding]::UTF8, $false, 4096, $true)
                return $r.ReadLine()
            } finally { try { $c.Dispose() } catch { } }
        }

        # Wait for the pipe rather than for a wall-clock guess (the 000051 at-It-time lesson).
        $script:DsReady = $false
        for ($i = 0; $i -lt 100; $i++) {
            $ping = $null
            try { $ping = script:Invoke-DsRequest -Json '{"action":"ping"}' -TimeoutMs 500 } catch { }
            if ($ping -and $ping -match '"action"\s*:\s*"ping"') { $script:DsReady = $true; break }
            Start-Sleep -Milliseconds 200
        }
    }

    AfterAll {
        if ($null -ne $script:DsProc) {
            try { if (-not $script:DsProc.HasExited) { $script:DsProc.Kill($true) } } catch { }
        }
        try { Remove-Item -LiteralPath $script:DsDataRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }

    It 'the daemon came up and answered a ping (the block cannot pass vacuously)' {
        $script:DsReady | Should -BeTrue -Because 'every assertion below is about a daemon that was serving first'
    }

    It 'survives a client that abandons a LARGE reply, and serves the next request' {
        # 1. Abandon one reply. The oversized action makes the daemon's echo reply far larger
        #    than any transport buffer, so its write to the departed client must fail.
        $bigAction = 'z' * 300000
        $req = '{"action":"' + $bigAction + '"}'
        { script:Invoke-DsRequest -Json $req -Abandon } | Should -Not -Throw

        # 2. Give the daemon a moment to attempt (and fail) the write and run its finally.
        Start-Sleep -Milliseconds 750

        # 3. The two questions the charter asks, in order.
        $script:DsProc.HasExited | Should -BeFalse -Because 'one abandoned reply must be one discarded write, not a process death'

        $after = $null
        for ($i = 0; $i -lt 25; $i++) {
            try { $after = script:Invoke-DsRequest -Json '{"action":"ping"}' -TimeoutMs 1000 } catch { $after = $null }
            if ($after) { break }
            Start-Sleep -Milliseconds 200
        }
        $after | Should -Not -BeNullOrEmpty -Because 'the daemon must still SERVE, not merely still exist'
        $after | Should -Match '"action"\s*:\s*"ping"'
    }

    It 'survives THREE consecutive abandoned replies (the measured cycle was four per session)' {
        for ($n = 1; $n -le 3; $n++) {
            $req = '{"action":"' + ('q' * 300000) + '"}'
            { script:Invoke-DsRequest -Json $req -Abandon } | Should -Not -Throw
            Start-Sleep -Milliseconds 400
            $script:DsProc.HasExited | Should -BeFalse -Because "the daemon must survive abandonment number $n"
        }
        $after = $null
        for ($i = 0; $i -lt 25; $i++) {
            try { $after = script:Invoke-DsRequest -Json '{"action":"ping"}' -TimeoutMs 1000 } catch { $after = $null }
            if ($after) { break }
            Start-Sleep -Milliseconds 200
        }
        $after | Should -Match '"action"\s*:\s*"ping"'
    }

    It 'the daemon log shows the write failure being HANDLED, and no daemon exit' {
        # The never-silent half: the scenario must be visible in the log the remeasurement
        # read, and the two lines that used to be adjacent must no longer be.
        $logPath = Join-Path $script:DsDataRoot 'logs/pses-daemon.log'
        if (-not (Test-Path -LiteralPath $logPath)) {
            $found = Get-ChildItem -LiteralPath $script:DsDataRoot -Recurse -Filter 'pses-daemon.log' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $logPath = $found.FullName }
        }
        Test-Path -LiteralPath $logPath | Should -BeTrue -Because 'the daemon log is the evidence surface the remeasurement used'
        $log = [System.IO.File]::ReadAllText($logPath)
        $log | Should -Match 'request handling error' -Because 'the abandoned reply must still be caught and logged by the handler'
        $log | Should -Not -Match 'main loop ended; cleanup' -Because 'THE regression: that line following the handled error is the daemon death this fixes'
        $log | Should -Not -Match '--- daemon exit ---'
    }
}
