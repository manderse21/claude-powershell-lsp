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
