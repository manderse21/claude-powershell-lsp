#Requires -Version 5.1

# Native-serve shim tests (Pester 5), dispatch 000103. Two layers:
#   1. PURE UNIT (no process): the byte-exact framing, the initialize patch, the knob
#      canonicalizer, and the server->client intercept answer table (scripts/lib/serve-shim-common.ps1).
#   2. E2E (real PSES over the shim): a scripted CC-shaped LSP client drives the shimmed stack and
#      asserts the shim's contract -- nav serves statically, interceptions are absorbed, off is a
#      transparent pass-through, the lifecycle reaps with zero orphans. The interactive client<->shim
#      driving runs inside a PWSH SUBPROCESS (tests/ServeShim.Driver.ps1) that the leg's Pester spawns
#      and reads a result file from -- because a Windows PowerShell 5.1 HOST's interactive writes to a
#      child's stdin do NOT deliver on the headless windows-powershell CI runner (they arrive only on
#      close; the integration suite never hit this because it write-then-closes one-shot). Driving from
#      pwsh keeps the client<->shim stdio pwsh<->pwsh (the shim host is pwsh too, matching production,
#      whose lspServers command is `pwsh`) on EVERY leg, so the e2e runs on all four. The PURE LIB
#      (framing / init patch / knob / answer table) is separately validated under Windows PowerShell
#      5.1 by the unit Describes above. The ubuntu leg IS the Linux #2300 init-patch validation (the
#      workspaceFolders-bearing initialize completing there is the risk the survey left open, closed).
#
# Each E2E scenario launches EXACTLY ONE shim+PSES in its own Describe/BeforeAll, fully torn down
# before the next, per the 000101 serialization lesson (never N daemons in a shared BeforeAll --
# the constrained 5.1 CI leg flakes on the startup spike).

$script:OnWindows = if (Test-Path 'Variable:\IsWindows') { [bool]$IsWindows } else { $true }
$script:OnLinux = (Test-Path 'Variable:\IsLinux') -and [bool]$IsLinux
$script:OnMacOS = (Test-Path 'Variable:\IsMacOS') -and [bool]$IsMacOS
$script:SkipServe = -not ($script:OnWindows -or $script:OnLinux -or $script:OnMacOS)
# Each E2E BeforeAll spawns the shim under the host running these tests (Core -> pwsh, Desktop ->
# powershell 5.1) so the CI matrix exercises the shim on both hosts; the interpreter is resolved
# INSIDE BeforeAll (run phase), not here (discovery phase), because Pester v5 isolates the two.
# The PSES child stays pwsh (Start-ServeShimClient sets CLAUDE_PLUGIN_OPTION_PS_HOST).

Describe 'ServeShim unit: the knob canonicalizer (ConvertTo-NativeServeMode)' {
    BeforeAll { . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/serve-shim-common.ps1') }
    It 'blank / unset -> off (the default; opt-in never silently on)' { ConvertTo-NativeServeMode '' | Should -BeExactly 'off' }
    It 'an unexpanded ${user_config...} token -> off' { ConvertTo-NativeServeMode '${user_config.nativeServe}' | Should -BeExactly 'off' }
    It 'an unrecognized value -> off' { ConvertTo-NativeServeMode 'banana' | Should -BeExactly 'off' }
    It 'the literal off -> off' { ConvertTo-NativeServeMode 'off' | Should -BeExactly 'off' }
    It 'shim (any case) -> shim' { ConvertTo-NativeServeMode 'ShIm' | Should -BeExactly 'shim' }
    It 'boolean-truthy aliases -> shim' {
        foreach ($v in @('on', 'true', '1', 'yes')) { ConvertTo-NativeServeMode $v | Should -BeExactly 'shim' }
    }
}

Describe 'ServeShim unit: byte-exact LSP framing (raw splice)' {
    BeforeAll { . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/serve-shim-common.ps1') }
    It 'round-trips a LARGE non-ASCII body byte-for-byte' {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('{"jsonrpc":"2.0","result":"')
        for ($i = 0; $i -lt 5000; $i++) { [void]$sb.Append([char]0x00E9) }   # e-acute x5000
        [void]$sb.Append(' mid '); [void]$sb.Append([char]0x4E2D); [void]$sb.Append([char]0x6587); [void]$sb.Append('"}')
        $body = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
        $ms = New-Object System.IO.MemoryStream
        Write-ServeFrame $ms $body
        $buf = New-Object System.Collections.Generic.List[byte]
        $buf.AddRange($ms.ToArray())
        $out = Read-ServeFrame $buf
        # Assert WITHOUT piping the array (piping a [byte[]] unrolls it into the pipeline).
        $out.GetType().Name | Should -Be 'Byte[]'
        $out.Length | Should -Be $body.Length
        [System.Convert]::ToBase64String($out) | Should -BeExactly ([System.Convert]::ToBase64String($body))
        $buf.Count | Should -Be 0
    }
    It 'returns $null for an incomplete frame (buffer not yet full)' {
        $buf = New-Object System.Collections.Generic.List[byte]
        $buf.AddRange([System.Text.Encoding]::ASCII.GetBytes("Content-Length: 100`r`n`r`ntooshort"))
        Read-ServeFrame $buf | Should -Be $null
    }
    It 'handles a zero-length body as an empty [byte[]] (distinct from $null)' {
        $ms = New-Object System.IO.MemoryStream
        Write-ServeFrame $ms ([byte[]]@())
        $buf = New-Object System.Collections.Generic.List[byte]
        $buf.AddRange($ms.ToArray())
        $out = Read-ServeFrame $buf
        ($null -ne $out) | Should -BeTrue
        $out.Length | Should -Be 0
    }
}

Describe 'ServeShim unit: the initialize patch (Edit-InitializeMessageForServe)' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/serve-shim-common.ps1')
        $rich = @{
            jsonrpc = '2.0'; id = 1; method = 'initialize'
            params  = @{
                processId        = 4242
                workspaceFolders = @(@{ uri = 'file:///tmp/x'; name = 'x' })
                clientInfo       = @{ name = 'cc'; version = '9' }
                capabilities     = @{
                    workspace    = @{ configuration = $true; workspaceFolders = $true; didChangeConfiguration = @{ dynamicRegistration = $true } }
                    textDocument = @{
                        synchronization = @{ dynamicRegistration = $true; didSave = $true }
                        hover           = @{ dynamicRegistration = $true }
                        definition      = @{ dynamicRegistration = $true }
                        references      = @{ dynamicRegistration = $true }
                    }
                }
            }
        } | ConvertTo-Json -Depth 20 -Compress
        $script:Patched = Edit-InitializeMessageForServe $rich
        $script:PP = $script:Patched | ConvertFrom-Json
    }
    It 'disables dynamicRegistration everywhere (none left true)' { $script:Patched | Should -Not -Match '"dynamicRegistration":true' }
    It 'sets dynamicRegistration false (the patch actually fired)' { $script:Patched | Should -Match '"dynamicRegistration":false' }
    It 'drops the params-level workspaceFolders (the #2300 Linux init NRE dodge)' {
        ($script:PP.params.PSObject.Properties.Name -contains 'workspaceFolders') | Should -BeFalse
    }
    It 'keeps the (safe) workspace.workspaceFolders capability boolean' {
        [bool]$script:PP.params.capabilities.workspace.workspaceFolders | Should -BeTrue
    }
    It 'ensures a rename capability (the PrepareRenameHandler NRE dodge)' {
        ($script:PP.params.capabilities.textDocument.PSObject.Properties.Name -contains 'rename') | Should -BeTrue
        $script:PP.params.capabilities.textDocument.rename.prepareSupport | Should -BeTrue
        $script:PP.params.capabilities.textDocument.rename.dynamicRegistration | Should -BeFalse
    }
    It 'preserves id / method / processId untouched' {
        [int]$script:PP.params.processId | Should -Be 4242
        $script:PP.method | Should -BeExactly 'initialize'
        [int]$script:PP.id | Should -Be 1
    }
    It 'passes an unparseable message through unchanged (never corrupts a frame it cannot rewrite)' {
        Edit-InitializeMessageForServe 'not json at all' | Should -BeExactly 'not json at all'
    }
}

Describe 'ServeShim unit: the server->client intercept answer table' {
    BeforeAll { . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/serve-shim-common.ps1') }
    It 'freezes exactly the three intercepted methods' {
        (Get-ServeInterceptMethods | Sort-Object) -join ',' | Should -BeExactly 'client/registerCapability,window/workDoneProgress/create,workspace/configuration'
    }
    It 'classifies the intercepted methods as intercept' {
        foreach ($m in (Get-ServeInterceptMethods)) { Test-ServeInterceptMethod $m | Should -BeTrue }
    }
    It 'classifies OTHER server->client methods as pass-through (adversarial: unknown forwards untouched)' {
        foreach ($m in @('workspace/applyEdit', 'window/showMessageRequest', 'client/unregisterCapability', 'workspace/codeLens/refresh')) {
            Test-ServeInterceptMethod $m | Should -BeFalse
        }
    }
    It 'answers workspace/configuration with one null PER item' {
        $params = @{ items = @(@{ section = 'powershell' }, @{}) } | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        New-ServeInterceptResponseJson -Id 7 -Method 'workspace/configuration' -Params $params | Should -BeExactly '{"jsonrpc":"2.0","id":7,"result":[null,null]}'
    }
    It 'answers workspace/configuration with [] when there are no items' {
        New-ServeInterceptResponseJson -Id 9 -Method 'workspace/configuration' -Params $null | Should -BeExactly '{"jsonrpc":"2.0","id":9,"result":[]}'
    }
    It 'answers the other intercepts with null, echoing a string id verbatim' {
        New-ServeInterceptResponseJson -Id 'abc' -Method 'window/workDoneProgress/create' -Params $null | Should -BeExactly '{"jsonrpc":"2.0","id":"abc","result":null}'
        New-ServeInterceptResponseJson -Id 3 -Method 'client/registerCapability' -Params $null | Should -BeExactly '{"jsonrpc":"2.0","id":3,"result":null}'
    }
}

Describe 'ServeShim: the broken-pipe (EPIPE) guard on the write path (dispatch 000180)' {
    # THE DEFECT THIS PINS. Every frame the shim writes lands on a pipe owned by another
    # process. When that peer dies the write throws, and the shim's outer try had a `finally`
    # and NO `catch` -- so the throw propagated past the closing [System.Environment]::Exit,
    # the line that exists precisely to avoid a graceful runspace shutdown waiting forever on
    # the background client-reader thread blocked in a synchronous Read. Four sightings, a
    # measured 1-in-3 macos-pwsh CI rate, and one 87-minute local wedge that a tree kill
    # answered by terminating three processes and leaving twelve-plus pwsh alive.
    #
    # Two layers, deliberately: the unit Context proves the guard's DISCRIMINATOR (it absorbs
    # a dead peer and nothing else), and the process Context proves the CONSEQUENCE that
    # actually matters -- the real shim script exits rather than wedging.

    Context 'unit: the guard absorbs a dead peer, and ONLY a dead peer' {
        BeforeAll { . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/serve-shim-common.ps1') }

        It 'returns $true and writes the frame byte-exactly on a HEALTHY stream (non-vacuity)' {
            # Without this, every assertion below could pass against a guard that returned
            # $false unconditionally and wrote nothing at all.
            $body = [System.Text.Encoding]::UTF8.GetBytes('{"jsonrpc":"2.0","id":1,"result":null}')
            $ms = New-Object System.IO.MemoryStream
            Write-ServeFrameGuarded $ms $body 'test' | Should -BeTrue
            $buf = New-Object System.Collections.Generic.List[byte]
            $buf.AddRange($ms.ToArray())
            $out = Read-ServeFrame $buf
            [System.Convert]::ToBase64String($out) | Should -BeExactly ([System.Convert]::ToBase64String($body))
        }

        It 'returns $false instead of throwing on a DISPOSED stream (ObjectDisposedException)' {
            $ms = New-Object System.IO.MemoryStream
            $ms.Dispose()
            # The bare call would throw here; the guard must convert it into a $false.
            Write-ServeFrameGuarded $ms ([System.Text.Encoding]::UTF8.GetBytes('{}')) 'test' | Should -BeFalse
        }

        It 'returns $false instead of throwing on a BROKEN PIPE (IOException) -- a real closed pipe, not a mock' {
            # A genuine anonymous pipe whose READ end is disposed: the production shape of a
            # peer that died, reproduced without a peer.
            $server = New-Object System.IO.Pipes.AnonymousPipeServerStream ([System.IO.Pipes.PipeDirection]::Out, [System.IO.HandleInheritability]::None)
            try {
                # No child ever received the read end, so disposing the local copy closes the
                # ONLY read handle: the write end stays open and undisposed, and the pipe is
                # broken. Measured to raise IOException 'Pipe is broken.'
                $server.DisposeLocalCopyOfClientHandle()
                $big = New-Object byte[] 200000    # exceed the pipe buffer so the write must reach the OS
                Write-ServeFrameGuarded $server $big 'test' | Should -BeFalse
            } finally {
                try { $server.Dispose() } catch { }
            }
        }

    }

    Context 'process: the REAL shim exits (not wedges) when the PSES stdin pipe breaks' -Skip:$script:SkipServe {
        # This drives scripts/pses-serve-shim.ps1 ITSELF -- not a copy of its control flow --
        # against a STUB PSES, so no bundle bootstrap is needed.
        #
        # WHY THE PSES-STDIN SIDE AND NOT THE CLIENT SIDE. Measured 2026-08-02, and it is the
        # reason this test targets the peer it does: a write to [Console]::OpenStandardOutput()
        # whose reader has gone away DOES NOT THROW. .NET's console stream treats
        # ERROR_BROKEN_PIPE / EPIPE as success -- 160KB was pushed into a closed pipe in a probe
        # without a single exception. So the client-stdout guard is defence in depth, and the
        # LOAD-BEARING path is the write to the PSES child's stdin, which is an ordinary pipe
        # FileStream and throws IOException 'Pipe is broken.' That is also exactly the path the
        # decision ledger's mechanism hypothesis named, from the preserved macOS crash log.
        #
        # WHY THE CLIENT KEEPS WRITING THROUGHOUT. The pump runs (a) forward-client-frames
        # BEFORE (c) check-exit-conditions on every iteration. Feeding a frame continuously
        # guarantees (a) has work pending on the first iteration after the stub dies, so the
        # broken-pipe write is reached AHEAD of the HasExited branch -- the production ordering.
        # If that race were ever lost the pump would exit via (c) with the SAME exit code, which
        # is why the log-line assertion below (not the exit code) is what proves the guard fired.
        #
        # The shim's stdin is deliberately left OPEN, so the background client-reader thread
        # stays blocked in its synchronous Read -- the exact state that makes a graceful
        # runspace shutdown hang and the forced exit load-bearing.
        BeforeAll {
            . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')

            $script:G = @{ ShimPid = 0; StubPid = 0 }
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('psls-epipe-' + ([guid]::NewGuid().ToString('N').Substring(0, 8)))
            $bundleDir = Join-Path $root 'bundle/PowerShellEditorServices'
            $dataDir = Join-Path $root 'data'
            New-Item -ItemType Directory -Force -Path $bundleDir | Out-Null
            New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
            $script:EpipeRoot = $root
            $script:EpipeStubPidFile = Join-Path $root 'stub.pid'
            $script:EpipeStubRxFile = Join-Path $root 'stub.rx'

            # The stub PSES: accepts the shim's launch arguments, records its pid, and DRAINS
            # its stdin forever, recording the running byte count. Draining matters twice --
            # it keeps the pipe from filling, and the byte count is the positive evidence that
            # the client->PSES write path worked before the injection.
            $stub = @'
param([string]$HostName, [string]$HostProfileId, [string]$HostVersion, [string]$BundledModulesPath,
      [string]$LogPath, [string]$LogLevel, [string]$SessionDetailsPath, [switch]$Stdio)
Set-Content -LiteralPath $env:PSLS_EPIPE_STUB_PIDFILE -Value $PID -Encoding ascii
$in = [Console]::OpenStandardInput()
$buf = New-Object byte[] 65536
$total = 0
while ($true) {
    $n = 0
    try { $n = $in.Read($buf, 0, $buf.Length) } catch { break }
    if ($n -le 0) { break }
    $total += $n
    try { Set-Content -LiteralPath $env:PSLS_EPIPE_STUB_RXFILE -Value $total -Encoding ascii } catch { }
}
Start-Sleep -Seconds 600
'@
            Set-Content -LiteralPath (Join-Path $bundleDir 'Start-EditorServices.ps1') -Value $stub -Encoding ascii

            # Launch the real shim under pwsh (the production host for lspServers).
            $shimPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/pses-serve-shim.ps1'
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'pwsh'
            $psi.UseShellExecute = $false
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true
            Add-ProcessArguments $psi @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $shimPath)
            # Set the environment on the CHILD only -- mutating $env: here would leak into the
            # other Describes in this file.
            $psi.EnvironmentVariables['PSES_BUNDLE_PATH'] = (Join-Path $root 'bundle')
            $psi.EnvironmentVariables['CLAUDE_PLUGIN_DATA'] = $dataDir
            $psi.EnvironmentVariables['PSLS_EPIPE_STUB_PIDFILE'] = $script:EpipeStubPidFile
            $psi.EnvironmentVariables['PSLS_EPIPE_STUB_RXFILE'] = $script:EpipeStubRxFile
            $psi.EnvironmentVariables['CLAUDE_PLUGIN_OPTION_NATIVESERVE'] = 'off'

            $script:EpipeProc = [System.Diagnostics.Process]::Start($psi)
            $script:G.ShimPid = $script:EpipeProc.Id
            $script:EpipeErrTask = $script:EpipeProc.StandardError.ReadToEndAsync()
            $shimLogPath = Join-Path $dataDir 'logs/pses-serve-shim.log'

            # (1) Wait for the shim's pump to be up and the stub to have registered.
            $deadline = (Get-Date).AddSeconds(90)
            while ((Get-Date) -lt $deadline) {
                $pumped = (Test-Path -LiteralPath $shimLogPath) -and ((Get-Content -LiteralPath $shimLogPath -Raw) -match 'pump started')
                if ($pumped -and (Test-Path -LiteralPath $script:EpipeStubPidFile)) { break }
                Start-Sleep -Milliseconds 100
            }
            if (Test-Path -LiteralPath $script:EpipeStubPidFile) {
                try { $script:G.StubPid = [int]((Get-Content -LiteralPath $script:EpipeStubPidFile -Raw).Trim()) } catch { $script:G.StubPid = 0 }
            }

            # (2) Drive client frames through the shim to the stub, and confirm they ARRIVE.
            #     This is the healthy write path working -- without it the test below could
            #     pass having never exercised a write at all.
            $inStream = $script:EpipeProc.StandardInput.BaseStream
            $body = [System.Text.Encoding]::UTF8.GetBytes('{"jsonrpc":"2.0","method":"$/psls-epipe-probe","params":{}}')
            $hdr = [System.Text.Encoding]::ASCII.GetBytes("Content-Length: " + $body.Length + "`r`n`r`n")
            $warmEnd = (Get-Date).AddSeconds(6)
            $script:EpipeStubRx = 0
            while ((Get-Date) -lt $warmEnd) {
                try { $inStream.Write($hdr, 0, $hdr.Length); $inStream.Write($body, 0, $body.Length); $inStream.Flush() } catch { break }
                if (Test-Path -LiteralPath $script:EpipeStubRxFile) {
                    try { $script:EpipeStubRx = [int]((Get-Content -LiteralPath $script:EpipeStubRxFile -Raw).Trim()) } catch { }
                }
                if ($script:EpipeStubRx -gt 0) { break }
                Start-Sleep -Milliseconds 50
            }

            $script:EpipeStubAliveAtInjection = $false
            $stubProc = $null
            if ($script:G.StubPid -gt 0) {
                $stubProc = Get-Process -Id $script:G.StubPid -ErrorAction SilentlyContinue
                $script:EpipeStubAliveAtInjection = ($null -ne $stubProc)
            }

            # (3) THE INJECTION: kill the stub, then KEEP FEEDING frames so the pump's (a)
            #     block has work pending on its next iteration and hits the now-broken pipe.
            $script:EpipeSw = [System.Diagnostics.Stopwatch]::StartNew()
            if ($null -ne $stubProc) { try { $stubProc.Kill() } catch { } }
            $exitDeadline = (Get-Date).AddSeconds(25)
            while ((Get-Date) -lt $exitDeadline) {
                if ($script:EpipeProc.HasExited) { break }
                try { $inStream.Write($hdr, 0, $hdr.Length); $inStream.Write($body, 0, $body.Length); $inStream.Flush() } catch { }
                Start-Sleep -Milliseconds 10
            }
            $script:EpipeExited = $script:EpipeProc.WaitForExit(5000)
            $script:EpipeSw.Stop()
            $script:EpipeElapsedMs = $script:EpipeSw.ElapsedMilliseconds
            $script:EpipeExitCode = if ($script:EpipeExited) { $script:EpipeProc.ExitCode } else { -999 }
            $script:EpipeStderr = ''
            if ($script:EpipeExited) { try { $script:EpipeStderr = [string]$script:EpipeErrTask.Result } catch { $script:EpipeStderr = '<unread>' } }
            $script:EpipeShimLog = ''
            if (Test-Path -LiteralPath $shimLogPath) { $script:EpipeShimLog = Get-Content -LiteralPath $shimLogPath -Raw }
            Write-Host ('[epipe guard] stubRxBytes=' + $script:EpipeStubRx + ' stubAlive=' + $script:EpipeStubAliveAtInjection +
                ' exited=' + $script:EpipeExited + ' exitCode=' + $script:EpipeExitCode +
                ' elapsedMs=' + $script:EpipeElapsedMs + ' shimPid=' + $script:G.ShimPid + ' stubPid=' + $script:G.StubPid)
        }
        AfterAll {
            # Reap ONLY the two processes this Context started, by pid. Never a broad sweep.
            foreach ($pidToKill in @($script:G.ShimPid, $script:G.StubPid)) {
                if ($pidToKill -le 0) { continue }
                try {
                    $doomed = Get-Process -Id $pidToKill -ErrorAction SilentlyContinue
                    if ($null -ne $doomed) { try { $doomed.Kill($true) } catch { try { $doomed.Kill() } catch { } } }
                } catch { }
            }
            try { if (Test-Path -LiteralPath $script:EpipeRoot) { Remove-Item -LiteralPath $script:EpipeRoot -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
        }

        It 'the client->PSES write path WORKED and the stub was ALIVE at injection (the guard cannot pass vacuously)' {
            # Received bytes prove the write under test was really being exercised; a live stub
            # proves the pipe was healthy right up to the injection, so what follows measures
            # the break rather than a shim that had already given up for some other reason.
            $script:G.StubPid | Should -BeGreaterThan 0 -Because 'the stub PSES must have launched and recorded its pid'
            $script:EpipeStubRx | Should -BeGreaterThan 0 -Because 'client frames must have travelled through the shim into the stub before the pipe was broken'
            $script:EpipeStubAliveAtInjection | Should -BeTrue -Because 'the pipe must be healthy at the moment of injection'
        }

        It 'the shim EXITS rather than wedging when the PSES stdin pipe breaks' {
            # THE WHOLE DEFECT IN ONE ASSERTION. Pre-fix this is $false: the unhandled throw
            # skips [System.Environment]::Exit and the graceful shutdown blocks forever on the
            # background reader thread. The 25s budget is generous against an unbounded wedge.
            $script:EpipeExited | Should -BeTrue -Because ('the forced exit must be reachable on the throwing path; shim stderr was: ' + $script:EpipeStderr)
        }

        It 'exits with the intended code -- PSES loss before client EOF is exit 1' {
            $script:EpipeExitCode | Should -Be 1 -Because 'a broken PSES stdin rejoins the existing psEof shutdown, which exits 1 when the client has not closed'
        }

        It 'exits PROMPTLY -- a fix that exits correctly but slowly has not addressed the wedge' {
            $script:EpipeElapsedMs | Should -BeGreaterThan -1
            $script:EpipeElapsedMs | Should -BeLessThan 15000 -Because ('measured ' + $script:EpipeElapsedMs + 'ms from pipe break to process exit')
        }

        It 'logged the guard firing, naming the peer -- this, not the exit code, is what proves the guard did the work' {
            # The exit code alone cannot discriminate: the pump's own HasExited branch produces
            # the same 1. Only this line distinguishes "the guard caught the write" from "the
            # race was lost and the exit came from somewhere else", so it is the assertion that
            # keeps a vacuous pass from reading as a fix.
            $script:EpipeShimLog | Should -Match 'write to PSES stdin failed -- pipe closed'
            $script:EpipeShimLog | Should -Match 'PSES exited / stdout EOF; propagating EOF to the client'
        }

        It 'left NO unhandled-exception error record on stderr (the throw is handled, not merely outrun)' {
            $script:EpipeStderr | Should -Not -Match 'ScriptHalted|Exception'
        }
    }
}

Describe 'ServeShim harness: the PSES-child lookup is scoped to THIS run (dispatch 000127)' -Skip:$script:SkipServe {
    # The 000125 outbox recorded two ServeShim lifecycle tests (process reap + crash-propagation
    # exit) failing intermittently on BOTH hosts, with the failing pair VARYING every run, one
    # isolated run fully green, and all four CI legs green -- and, separately, six leaked PSES
    # hosts aged 19-29h on the local box, named there as "inflating the local ServeShim flake".
    #
    # This Describe pins the mechanism that connected those two observations: the harness's
    # PSES-child lookup used to match ANY pwsh/powershell whose command line contained
    # 'Start-EditorServices.ps1' + 'pses-serve-', scoped to nothing -- so a leaked host from a
    # prior session was returned as "this shim's child". These are the RED-proving guards: each
    # fails against the pre-000127 harness, and no real shim is spawned, so they cost ~2s and run
    # on every leg (a clean CI runner has no orphans, which is exactly why CI never caught this).
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')
        . (Join-Path $PSScriptRoot 'ServeShim.Common.ps1')

        # A DECOY with the shape of a leaked prior-session PSES: its command line matches the
        # lookup predicate, but it is nobody's shim child. Long-lived enough to outlast the Its.
        $script:DecoyArgs = @('-NoLogo', '-NoProfile', '-Command',
            "# Start-EditorServices.ps1 -LogPath pses-serve-decoy.log `nStart-Sleep -Seconds 90")
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'pwsh'; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        Add-ProcessArguments $psi $script:DecoyArgs
        $script:Decoy = [System.Diagnostics.Process]::Start($psi)
        # Let the OS register the command line before any lookup reads it.
        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $deadline) {
            $cl = Get-ProcessCommandLine $script:Decoy.Id
            if (($cl -match 'Start-EditorServices\.ps1') -and ($cl -match 'pses-serve-')) { break }
            Start-Sleep -Milliseconds 100
        }
        $script:DecoyCmdLine = Get-ProcessCommandLine $script:Decoy.Id
    }
    AfterAll {
        try { if ($null -ne $script:Decoy) { $script:Decoy.Kill($true) } } catch {
            try { $script:Decoy.Kill() } catch { }
        }
    }

    It 'the decoy really does match the lookup predicate (the guard cannot pass vacuously)' {
        # Non-vacuity: if the decoy did NOT look like a leaked PSES, the Its below would pass for
        # the wrong reason -- they would be excluding a process nothing would have matched anyway.
        $script:DecoyCmdLine | Should -Match 'Start-EditorServices\.ps1'
        $script:DecoyCmdLine | Should -Match 'pses-serve-'
    }

    It 'does NOT return a look-alike host that started BEFORE the shim (the 000125 orphan class)' {
        # A shim "started" after the decoy: the decoy is older, so it can never be its child.
        # Pre-000127 this returned the decoy's pid -- the whole flake in one assertion.
        $laterStart = (Get-Date).AddSeconds(5)
        Get-ServeShimPsesPid -ShimPid $PID -ShimStart $laterStart | Should -Be 0
    }

    It 'does NOT return a look-alike host that is not a child of THIS shim (parentage factor)' {
        # Same era as the shim, but the wrong parent: an unrelated pid must never be claimed.
        # 99999 is a pid this decoy is definitionally not a child of.
        $earlyStart = (Get-Date).AddSeconds(-600)
        Get-ServeShimPsesPid -ShimPid 99999 -ShimStart $earlyStart | Should -Be 0
    }

    It 'cannot be called unscoped -- both scoping parameters are mandatory' {
        # Structural, not advisory: the unscoped global scan that caused the flake is not an
        # option a future caller can reach for by omitting an argument.
        $cmd = Get-Command Get-ServeShimPsesPid
        [bool]$cmd.Parameters['ShimPid'].Attributes.Mandatory | Should -BeTrue
        [bool]$cmd.Parameters['ShimStart'].Attributes.Mandatory | Should -BeTrue
    }

    It 'Wait-ServeShimProcessGone returns true promptly once a process is gone, and false while it lives' {
        # The reap gate that replaced the fixed Start-Sleep 800 / 500: correct in BOTH directions.
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Wait-ServeShimProcessGone -ProcessIdValue 99999 -TimeoutMs 5000 | Should -BeTrue
        $sw.Stop()
        $sw.ElapsedMilliseconds | Should -BeLessThan 4000 -Because 'an already-gone process must not burn the whole budget'
        # Adversarial: a LIVE process must NOT read as reaped -- else the gate passes vacuously.
        Wait-ServeShimProcessGone -ProcessIdValue $script:Decoy.Id -TimeoutMs 700 | Should -BeFalse
    }
}

Describe 'ServeShim e2e: nativeServe=shim serves navigation end-to-end' -Skip:$script:SkipServe {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')
        . (Join-Path $PSScriptRoot 'ServeShim.Common.ps1')
        $srv = Initialize-ServeShimEnv -TestsDir $PSScriptRoot
        $script:R = Invoke-ServeShimDriver -TestsDir $PSScriptRoot -Mode 'shim' -Scenario 'session' -DataRoot $srv.DataDir -RunNav
        Write-Host ('[serve-shim latency] hover=' + (Get-Prop $script:R 'HoverMs') + 'ms definition=' + (Get-Prop $script:R 'DefinitionMs') + 'ms references=' + (Get-Prop $script:R 'ReferencesMs') + 'ms (end-to-end round-trip; PSES compute dominates, the shim adds ~1%)')
    }
    It 'launched the shim without error' { $script:R.Launched | Should -BeTrue; $script:R.Error | Should -BeExactly '' }
    It 'the patched initialize returns a result advertising the nav providers STATICALLY (dynamicRegistration=false took effect)' {
        $script:R.InitNotNull | Should -BeTrue
        $script:R.InitHasStaticNav | Should -BeTrue -Because 'the shim disables dynamicRegistration so PSES advertises hover/definition/references in the initialize result rather than via client/registerCapability'
    }
    It 'the workspaceFolders-bearing initialize completed -- the PSES #2300 dodge (on the ubuntu leg, the Linux init-patch validation)' {
        # The shim-mode client sends params-level workspaceFolders AND omits rename; only the shim's
        # patch (drop workspaceFolders + ensure rename) lets PSES complete init. A non-null init
        # result here is that dodge holding -- and on the ubuntu CI leg it closes the survey's open risk.
        $script:R.InitNotNull | Should -BeTrue
    }
    It 'hover returns contents' { $script:R.HoverOk | Should -BeTrue }
    It 'definition returns at least one location' { $script:R.DefinitionCount | Should -BeGreaterThan 0 }
    It 'references returns at least one location' { $script:R.ReferencesCount | Should -BeGreaterThan 0 }
    It 'ZERO server->client requests leaked to the client (configuration + workDoneProgress/create + registerCapability all absorbed)' {
        $script:R.LeaksCount | Should -Be 0 -Because ('the shim answers the intercept set locally; leaked: ' + (@($script:R.Leaks) -join ', '))
    }
    It 'a nav round-trip stays within a generous latency ceiling (OQ2 guard; per-leg numbers logged above)' {
        $script:R.MaxNavMs | Should -BeGreaterThan 0
        $script:R.MaxNavMs | Should -BeLessThan 30000 -Because 'an order-of-magnitude sanity ceiling, not a tight timing gate that would flake on shared runners'
    }
    It 'the shim exits cleanly and reaps its PSES child (zero orphans)' {
        $script:R.Exited | Should -BeTrue
        $script:R.PsesReaped | Should -BeTrue -Because ('reap detail: ' + [string](Get-Prop $script:R 'Error'))
    }
    It 'positively identified THIS shim PSES child, so the reap assertion is not vacuous (dispatch 000127)' {
        # PsesReaped defaults to $true when no child is identified -- correct (a child we never
        # saw is not an orphan we leaked), but it means the assertion above can pass having
        # measured nothing. This names that case instead of letting it hide inside a green run.
        [bool](Get-Prop $script:R 'PsesIdentified') | Should -BeTrue
        [int](Get-Prop $script:R 'PsesPid') | Should -BeGreaterThan 0
    }
}

Describe 'ServeShim e2e: nativeServe=off is a transparent pass-through' -Skip:$script:SkipServe {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')
        . (Join-Path $PSScriptRoot 'ServeShim.Common.ps1')
        $srv = Initialize-ServeShimEnv -TestsDir $PSScriptRoot
        $script:OR = Invoke-ServeShimDriver -TestsDir $PSScriptRoot -Mode 'off' -Scenario 'session' -DataRoot $srv.DataDir
    }
    It 'launched the shim without error' { $script:OR.Launched | Should -BeTrue; $script:OR.Error | Should -BeExactly '' }
    It 'does NOT patch the initialize: nav providers are not statically advertised (transparent)' {
        $script:OR.InitNotNull | Should -BeTrue
        $script:OR.InitHasStaticNav | Should -BeFalse -Because 'off relays the raw dynamicRegistration=true caps, so PSES keeps the providers dynamic (not in the static init result)'
    }
    It 'does NOT intercept: server->client request(s) LEAK to the client (transparent -- byte-for-byte today behavior)' {
        $script:OR.LeaksCount | Should -BeGreaterThan 0 -Because 'a transparent relay forwards PSES workspace/configuration + client/registerCapability to the client rather than answering them'
    }
    It 'the off-mode shim also exits cleanly and reaps its PSES child' {
        $script:OR.Exited | Should -BeTrue
        $script:OR.PsesReaped | Should -BeTrue
    }
}

Describe 'ServeShim e2e: lifecycle -- crash propagation, no orphans, no in-shim re-spawn' -Skip:$script:SkipServe {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')
        . (Join-Path $PSScriptRoot 'ServeShim.Common.ps1')
        $srv = Initialize-ServeShimEnv -TestsDir $PSScriptRoot
        $script:C = Invoke-ServeShimDriver -TestsDir $PSScriptRoot -Mode 'shim' -Scenario 'crash' -DataRoot $srv.DataDir
    }
    It 'launched and identified the PSES child' {
        # Non-vacuity gate for the whole Describe: without a positively identified child there is
        # nothing to crash, so the two assertions below would prove nothing. The driver reports WHY.
        $script:C.Launched | Should -BeTrue
        $script:C.PsesPid | Should -BeGreaterThan 0 -Because ('the scoped lookup must find THIS shim child; driver said: ' + [string](Get-Prop $script:C 'Error'))
    }
    It 'killing PSES mid-session makes the shim EXIT promptly (EOF propagated to the client; no in-shim re-spawn)' {
        # The -Because now NAMES the classified exit path and points at the uploaded per-run record
        # (dispatch 000163 leg 2). Message-only: the assertion is unchanged. Two prior sightings
        # reported a bare $false; a third reports its own mechanism.
        $script:C.ShimExitedAfterCrash | Should -BeTrue -Because (
            'on PSES death the shim closes the client stdout and exits -- the manifest maxRestarts owns restart, so the shim must not re-spawn.' +
            ' exit path classified as: ' + [string](Get-Prop $script:C 'ExitPath') +
            '; lifecycle record: ' + [string](Get-Prop $script:C 'LifecycleRecordPath'))
    }
    It 'the killed PSES stays reaped (zero orphan)' { $script:C.PsesReaped | Should -BeTrue }
    It 'recorded a per-run lifecycle artifact for this crash run (the 000163 leg-2 recorder fired)' {
        # Non-vacuity gate for the instrumentation itself: if the recorder silently returned '' the
        # two assertions above would still read the same, and a third sighting would again arrive
        # with nothing. Asserting the artifact EXISTS is what makes the evidence channel load-bearing.
        $recPath = [string](Get-Prop $script:C 'LifecycleRecordPath')
        $recPath | Should -Not -BeNullOrEmpty -Because 'Save-ServeShimLifecycleRecord must write a per-run record under the CI-uploaded logs tree'
        Test-Path -LiteralPath $recPath | Should -BeTrue -Because ('the recorder reported ' + $recPath)
        $rec = Get-Content -LiteralPath $recPath -Raw | ConvertFrom-Json
        [string]$rec.ExitPath | Should -BeIn @('pses-eof-propagated', 'client-eof', 'unlogged-exception-path', 'no-teardown', 'no-shim-log')
        [int]$rec.ShimPid | Should -Be ([int](Get-Prop $script:C 'ShimPid'))
    }
}
