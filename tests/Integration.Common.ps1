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
