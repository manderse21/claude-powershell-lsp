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
    $st = @{
        Proc = $p
        To   = $p.StandardInput.BaseStream
        From = $p.StandardOutput.BaseStream
        Buf  = New-Object System.Collections.Generic.List[byte]
        Chunk = New-Object byte[] 65536
        Pending = $null
        Leaks = New-Object System.Collections.Generic.List[string]
        Eof  = $false
        ErrTask = $p.StandardError.ReadToEndAsync()
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
}

function Get-ServeShimPsesPid {
    # Best-effort: the PSES child pid the shim spawned (a Start-EditorServices host launched with
    # a pses-serve- log path). Returns 0 if not found. Used only to PROVE the orphan reap.
    try {
        foreach ($proc in @(Get-Process -Name 'pwsh', 'powershell' -ErrorAction SilentlyContinue)) {
            $cl = Get-ProcessCommandLine $proc.Id
            if (($cl -match 'Start-EditorServices\.ps1') -and ($cl -match 'pses-serve-')) { return $proc.Id }
        }
    } catch { }
    return 0
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
        Timings = @{}; MaxNavMs = 0; Exited = $false; ExitCode = -999; PsesPid = 0; PsesReaped = $false; Error = ''
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

        $result.PsesPid = Get-ServeShimPsesPid

        Write-LspFrame -Stream $st.To -Json (@{ jsonrpc = '2.0'; id = 9; method = 'shutdown' } | ConvertTo-Json -Depth 5 -Compress)
        Receive-ServeShimResponse -St $st -TargetId 9 -TimeoutMs 8000 | Out-Null
        Write-LspFrame -Stream $st.To -Json (@{ jsonrpc = '2.0'; method = 'exit'; params = @{} } | ConvertTo-Json -Depth 5 -Compress)
        $st.To.Close()
        $result.Exited = $st.Proc.WaitForExit(15000)
        if ($result.Exited) { $result.ExitCode = $st.Proc.ExitCode } else { try { $st.Proc.Kill($true) } catch { } }

        Start-Sleep -Milliseconds 800
        if ($result.PsesPid -gt 0) {
            $result.PsesReaped = -not [bool](Get-Process -Id $result.PsesPid -ErrorAction SilentlyContinue)
        } else {
            $result.PsesReaped = $true   # could not identify a child (e.g. very fast teardown); not a leak signal
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
    $result = @{ Launched = $false; PsesPid = 0; ShimExitedAfterCrash = $false; PsesReaped = $false; Error = '' }
    $st = $null
    try {
        $st = Start-ServeShimClient -ScriptsDir $ScriptsDir -Interpreter $Interpreter -Mode 'shim' -DataRoot $DataRoot
        $result.Launched = $true
        $caps = New-ServeShimRichCapabilities
        $initParams = @{ processId = $PID; clientInfo = @{ name = 'serve-shim-crash'; version = '1' }; rootUri = (ConvertTo-FileUri $DataRoot); workspaceFolders = @(@{ uri = (ConvertTo-FileUri $DataRoot); name = 'root' }); capabilities = $caps }
        Write-LspFrame -Stream $st.To -Json (@{ jsonrpc = '2.0'; id = 1; method = 'initialize'; params = $initParams } | ConvertTo-Json -Depth 30 -Compress)
        $null = Receive-ServeShimResponse -St $st -TargetId 1 -TimeoutMs $CapMs
        Write-LspFrame -Stream $st.To -Json (@{ jsonrpc = '2.0'; method = 'initialized'; params = @{} } | ConvertTo-Json -Depth 5 -Compress)
        Start-Sleep -Milliseconds 500
        $result.PsesPid = Get-ServeShimPsesPid
        if ($result.PsesPid -gt 0) {
            try { Stop-Process -Id $result.PsesPid -Force -ErrorAction Stop } catch { }
        }
        # The shim must notice PSES's stdout EOF and exit promptly (bounded).
        $result.ShimExitedAfterCrash = $st.Proc.WaitForExit(15000)
        Start-Sleep -Milliseconds 500
        if ($result.PsesPid -gt 0) { $result.PsesReaped = -not [bool](Get-Process -Id $result.PsesPid -ErrorAction SilentlyContinue) } else { $result.PsesReaped = $true }
    } catch {
        $result.Error = [string]$_.Exception.Message
    } finally {
        Stop-ServeShimClient -St $st
    }
    return $result
}
