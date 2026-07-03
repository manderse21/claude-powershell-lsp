#Requires -Version 5.1

# probe-native-serve.ps1 -- the native-serve REMOVABILITY probe driver (dispatch 000104,
# the 000103 OQ4 next_suggested). REPORT-ONLY: it observes and reports; it installs, repairs,
# downloads, and mutates NOTHING (it writes only its own result JSON to -ResultPath and PSES's
# own scratch logs under the data root).
#
# WHAT IT ANSWERS: can the nativeServe shim be removed yet? The shim exists ONLY to route around
# the upstream #1359-class client init-handshake bug (Claude Code's native LSP client not
# answering the server->client requests PSES sends at init). This driver launches PSES via the
# DIRECT launcher (scripts/pses-stdio.ps1, shim BYPASSED -- the removal lever), sends a
# CC-shaped `initialize` (rich caps, dynamicRegistration=true, like Claude Code's native client),
# reads the initialize RESULT, and reports which side of the #1359 gate the current PSES + client
# pair lands on:
#   (a) GATED (today): the init result does NOT advertise the nav providers statically -- PSES
#       defers them to a client/registerCapability handshake, exactly the request Claude Code's
#       client mishandles (#1359). The shim is still needed.
#   (b) SERVED: the init result advertises hover/definition/references STATICALLY, so native serve
#       completes without the broken handshake -- the shim can be removed.
# The discriminator is the RESULT CONTENT (are the nav providers advertised statically?), NOT a
# race against the ~30 s gated stall, so it resolves as soon as the init result arrives -- bounded
# and deterministic on every leg.
#
# SCOPE / limitation (honest): this reproduces the CC-shaped initialize with a SCRIPTED client, so
# it detects the STATIC-serving removability path (PSES advertising nav statically under rich caps
# -- the shim's own dynamicRegistration=false mechanism becoming native). A purely CLIENT-side
# #1359 fix (Claude Code completing the dynamic-registration handshake so nav registers
# DYNAMICALLY) would serve WITHOUT changing the static init result, and is NOT caught here -- that
# case still needs the manual real `claude -p` re-probe
# (docs/upstream/claude-code-lsp-registration.md). The probe never yields a false "removable"; it
# errs conservatively toward keeping the shim.
#
# WHY A PWSH SUBPROCESS: a Windows PowerShell 5.1 host's interactive writes to a child's stdin do
# NOT deliver on the headless windows-powershell CI runner (they arrive only on close; dispatch
# 000103's load-bearing CI lesson). So the doctor spawns THIS driver as a pwsh subprocess and
# reads its result FILE -- the client<->PSES stdio is pwsh<->pwsh on every leg, while the doctor's
# own host may be 5.1.
#
# Reuses the shipped framing lib (Write-LspFrame / Read-LspFrame, scripts/lib/lsp-common.ps1) and
# the shim's server->client answer table (New-ServeInterceptResponseJson,
# scripts/lib/serve-shim-common.ps1) -- no re-derivation.
#
# ASCII-only (PS 5.1 em-dash trap). Author: Mike Andersen / powershell-lsp plugin.

param(
    [Parameter(Mandatory = $true)][string]$DataRoot,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [int]$InitTimeoutMs = 20000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptsDir = $PSScriptRoot
. (Join-Path $scriptsDir 'lib/lsp-common.ps1')
. (Join-Path $scriptsDir 'lib/serve-shim-common.ps1')

$env:CLAUDE_PLUGIN_DATA = $DataRoot

function New-NativeServeProbeCapabilities {
    # A rich, Claude-Code-shaped client capabilities object: dynamicRegistration=true across the
    # nav sections (this is what ELICITS the client/registerCapability the #1359 gate breaks) AND
    # a declared textDocument.rename (the PSES v4.6.0 PrepareRenameHandler NRE dodge -- the direct
    # launcher has no shim to add it). The params-level workspaceFolders is DELIBERATELY OMITTED
    # (the PSES v4.6.0 #2300 Linux OnInitialize NRE), so the probe isolates the #1359 handshake
    # gate from the two unrelated NREs. Mirrors the test harness New-ServeShimRichCapabilities
    # (off-mode branch, rename declared / no workspaceFolders) -- kept here so the SHIPPED driver
    # never depends on a test-only support file.
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
            rename          = @{ dynamicRegistration = $true; prepareSupport = $true }
        }
    }
}

$flat = @{
    Launched         = $false
    InitReceived     = $false
    InitHasStaticNav = $false
    InitElapsedMs    = 0
    InterceptsSeen   = @()
    Exited           = $false
    Error            = ''
}

$proc = $null
try {
    $psesLauncher = Join-Path $scriptsDir 'pses-stdio.ps1'
    if (-not (Test-Path -LiteralPath $psesLauncher)) { throw ('direct launcher not found: ' + $psesLauncher) }

    # Launch the DIRECT launcher under pwsh (matching the shipped lspServers command host and
    # keeping client<->PSES stdio pwsh<->pwsh). pses-stdio.ps1 becomes PSES in-process, so the
    # child process handle IS PSES -- Kill($true) reaps it (no orphan).
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'pwsh'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    Add-ProcessArguments $psi @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $psesLauncher)
    $psi.EnvironmentVariables['CLAUDE_PLUGIN_DATA'] = $DataRoot
    $proc = [System.Diagnostics.Process]::Start($psi)
    $flat.Launched = $true
    $null = $proc.StandardError.ReadToEndAsync()

    $to = $proc.StandardInput.BaseStream
    $from = $proc.StandardOutput.BaseStream
    $buf = New-Object System.Collections.Generic.List[byte]
    $chunk = New-Object byte[] 65536
    $pending = $null
    $seen = New-Object System.Collections.Generic.List[string]

    $initParams = @{
        processId    = $PID
        clientInfo   = @{ name = 'native-serve-probe'; version = '1' }
        rootUri      = (ConvertTo-FileUri $DataRoot)
        capabilities = (New-NativeServeProbeCapabilities)
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-LspFrame -Stream $to -Json (@{ jsonrpc = '2.0'; id = 1; method = 'initialize'; params = $initParams } | ConvertTo-Json -Depth 30 -Compress)

    # Pump PSES stdout until the id=1 initialize RESPONSE arrives or the bound elapses. A
    # server->client REQUEST (has id AND method) is answered locally with the shim's own answer
    # table so PSES is never blocked returning the init result, and its method is recorded;
    # notifications (method, no id) are ignored. Single outstanding async read (StrictMode-safe).
    $initResult = $null
    $deadline = (Get-Date).AddMilliseconds($InitTimeoutMs)
    while ($true) {
        $frame = Read-LspFrame -Buffer $buf
        while ($null -ne $frame) {
            $msg = $null; try { $msg = $frame | ConvertFrom-Json } catch { $msg = $null }
            if ($null -ne $msg) {
                $hasId = Test-Prop $msg 'id'; $hasMethod = Test-Prop $msg 'method'
                if ($hasId -and $hasMethod) {
                    $sm = [string](Get-Prop $msg 'method')
                    [void]$seen.Add($sm)
                    $ans = New-ServeInterceptResponseJson -Id (Get-Prop $msg 'id') -Method $sm -Params (Get-Prop $msg 'params')
                    try { Write-LspFrame -Stream $to -Json $ans } catch { }
                } elseif ($hasId -and -not $hasMethod) {
                    if (([string](Get-Prop $msg 'id')) -eq '1') { $initResult = $msg; break }
                }
            }
            $frame = Read-LspFrame -Buffer $buf
        }
        if ($null -ne $initResult) { break }
        if ((Get-Date) -ge $deadline) { break }
        if ($null -eq $pending) { $pending = $from.ReadAsync($chunk, 0, $chunk.Length) }
        if ($pending.Wait(200)) {
            $c = -1; try { $c = $pending.Result } catch { $c = -1 }
            $pending = $null
            if ($c -le 0) { break }   # EOF: PSES exited / closed stdout
            $sub = New-Object byte[] $c; [System.Array]::Copy($chunk, 0, $sub, 0, $c); $buf.AddRange($sub)
        }
    }
    $sw.Stop()

    if ($null -ne $initResult) {
        $flat.InitReceived = $true
        $flat.InitElapsedMs = [int]$sw.ElapsedMilliseconds
        # Static-serving discriminator: does the init RESULT advertise the nav providers itself?
        # (definitionProvider + hoverProvider + referencesProvider in result.capabilities). Under a
        # CC-shaped rich-caps client PSES v4.6.0 defers these to client/registerCapability, so today
        # this is FALSE (gated); it flips TRUE only when native serve completes statically.
        $rcaps = Get-Prop (Get-Prop $initResult 'result') 'capabilities'
        $flat.InitHasStaticNav = ($null -ne $rcaps) -and `
            ($rcaps.PSObject.Properties.Name -contains 'definitionProvider') -and `
            ($rcaps.PSObject.Properties.Name -contains 'hoverProvider') -and `
            ($rcaps.PSObject.Properties.Name -contains 'referencesProvider')
    }
    $flat.InterceptsSeen = @($seen | Select-Object -Unique)

    # Best-effort clean shutdown, then tree-kill to reap PSES (report-only: leave no orphan).
    try { Write-LspFrame -Stream $to -Json (@{ jsonrpc = '2.0'; id = 99; method = 'shutdown' } | ConvertTo-Json -Compress) } catch { }
    try { Write-LspFrame -Stream $to -Json (@{ jsonrpc = '2.0'; method = 'exit'; params = @{} } | ConvertTo-Json -Compress) } catch { }
    try { $to.Close() } catch { }
    if (-not $proc.WaitForExit(4000)) { try { $proc.Kill($true) } catch { try { $proc.Kill() } catch { } } }
    $flat.Exited = $proc.HasExited
} catch {
    $flat.Error = ('probe: ' + [string]$_.Exception.Message)
} finally {
    if ($null -ne $proc) {
        try { if (-not $proc.HasExited) { $proc.Kill($true) } } catch { }
    }
}

[System.IO.File]::WriteAllText($ResultPath, ($flat | ConvertTo-Json -Depth 5 -Compress), (New-Object System.Text.UTF8Encoding($false)))
