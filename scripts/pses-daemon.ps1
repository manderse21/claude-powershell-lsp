#Requires -Version 5.1

# pses-daemon.ps1 -- long-lived, per-session process that owns ONE warm PSES
# child (over stdio) and serves diagnostics requests over a named pipe
# (powershell-lsp-<sessionid>). Keeping PSES warm removes the per-edit cold-start
# that dominated the loose-hook latency.
#
# Transport: named pipe (client<->daemon) + stdio (daemon<->PSES). The stdio side
# is fixed by contract and never changes.
#
# stdout of THIS process is reserved: the daemon writes nothing to stdout. All
# output goes to files under CLAUDE_PLUGIN_DATA/logs. -NoLogo -NoProfile is set on
# the PSES child launch. State/pids/logs live under CLAUDE_PLUGIN_DATA only.
#
# Author: Mike Andersen / powershell-lsp plugin.

param(
    [Parameter(Mandatory = $true)][string] $SessionId,
    [string] $PsHost = 'pwsh',
    # Explicit data root (set by session-start). Decouples the daemon from env
    # inheritance, which is unreliable across a detached launch.
    [string] $DataRoot = '',
    # Quiet window (ms) with no new publish before a diagnostics pass is "settled".
    # Bridges the early parser publish to the slower PSScriptAnalyzer publish. The
    # settle is adaptive (it resets on each publish), so this is the trailing
    # quiet window, not a fixed wait; 600ms keeps warm-path latency near 2s while
    # still clearing the early publish.
    [int] $SettleMs = 600,
    # Coalesce window (ms): edits landing within this window fold into one pass.
    # (Identical-content requests also coalesce via the content-hash cache.)
    [int] $DebounceMs = 150,
    # Hard cap (ms) on waiting for any single settled publish.
    [int] $MaxWaitMs = 5000,
    # Idle TTL (min): self-terminate after this long with no client request.
    [int] $IdleTtlMin = 30,
    # Diagnostics filtering (Stage 4 userConfig knobs).
    [string] $SeverityThreshold = 'Hint',   # least-severe level to report
    [string] $RuleInclude = '',              # comma-separated; empty = all
    [string] $RuleExclude = '',              # comma-separated rule codes to drop
    [int] $PerFileCap = 20                    # max diagnostics per file (0 = no cap)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/lsp-common.ps1')

# Pin the data root explicitly (a detached launch may not inherit the env var).
if (-not [string]::IsNullOrWhiteSpace($DataRoot)) { $env:CLAUDE_PLUGIN_DATA = $DataRoot }

# Parse rule include/exclude lists once.
$script:RuleIncludeArr = Split-RuleList $RuleInclude
$script:RuleExcludeArr = Split-RuleList $RuleExclude

# --- paths / logging -------------------------------------------------------
$logDir    = Get-LogDir
$sessionDir = Get-SessionDir
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null
$daemonLog = Join-Path $logDir 'pses-daemon.log'
$sessionFile = Join-Path $sessionDir ($SessionId + '.json')

function Write-DLog([string]$m) {
    try { ('[' + (Get-Date -Format 'o') + '] [' + $PID + '] ' + $m) | Out-File -FilePath $daemonLog -Append -Encoding ascii } catch { }
}

# --- shared LSP state ------------------------------------------------------
$script:proc      = $null
$script:stdin     = $null
$script:stdout    = $null
$script:buf       = New-Object System.Collections.Generic.List[byte]
$script:chunk     = New-Object byte[] 16384
$script:pending   = $null
$script:nextId    = 100
$script:initDone  = $false
# Per-URI: latest diagnostics records, last-publish time, a sequence stamp, and
# the content hash that produced them (for coalescing) and open/version state.
$script:diag      = @{}   # uri -> @{ records=@(); at=DateTime; seq=int }
$script:openDocs  = @{}   # uri -> version int
$script:lastHash  = @{}   # uri -> content hash string
$script:respSeen  = @{}   # request id -> $true once a response arrives
$script:respResult = @{}  # request id -> response result body (for codeAction)
$script:reqId     = 1000  # monotonic id for daemon-initiated requests (codeAction)

function Get-ContentHash([string]$text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
        return [System.BitConverter]::ToString($sha.ComputeHash($bytes))
    } finally { $sha.Dispose() }
}

# --- LSP send/handle/pump --------------------------------------------------
function Send-Lsp([object]$obj) {
    Write-LspFrame -Stream $script:stdin -Json ($obj | ConvertTo-Json -Depth 20 -Compress)
}
function Send-LspResponse($id, [string]$resultJson) {
    $idJson = if ($id -is [string]) { ConvertTo-Json $id -Compress } else { [string]$id }
    Write-LspFrame -Stream $script:stdin -Json ('{"jsonrpc":"2.0","id":' + $idJson + ',"result":' + $resultJson + '}')
}

function Invoke-LspMessage([string]$body) {
    $msg = $null
    try { $msg = $body | ConvertFrom-Json } catch { Write-DLog ('bad json frame: ' + $_.Exception.Message); return }
    $hasId = Test-Prop $msg 'id'
    $hasMethod = Test-Prop $msg 'method'

    if ($hasId -and $hasMethod) {
        # server -> client request: must respond or PSES stalls.
        $method = [string](Get-Prop $msg 'method')
        $id = Get-Prop $msg 'id'
        if ($method -eq 'workspace/configuration') {
            $params = Get-Prop $msg 'params'
            $items = @(Get-Prop $params 'items')
            $parts = @()
            foreach ($it in $items) { $parts += '{"scriptAnalysis":{"enable":true}}' }
            $arr = if ($parts.Count -gt 0) { '[' + ($parts -join ',') + ']' } else { '[]' }
            Send-LspResponse $id $arr
        } else {
            Send-LspResponse $id 'null'
        }
        return
    }
    if ($hasMethod) {
        $method = [string](Get-Prop $msg 'method')
        if ($method -eq 'textDocument/publishDiagnostics') {
            $params = Get-Prop $msg 'params'
            $uri = [string](Get-Prop $params 'uri')
            $key = ConvertTo-UriKey $uri
            $rawDiags = @(Get-Prop $params 'diagnostics')
            $records = @()
            foreach ($d in $rawDiags) { $records += (ConvertTo-DiagRecord $d) }
            # Keep the raw diagnostics too: the codeAction enrichment pass replays
            # them as request context to fetch PSSA suggested corrections.
            $script:diag[$key] = @{ records = $records; raw = $rawDiags; at = (Get-Date); seq = ($script:nextId) }
            Write-DLog ('publishDiagnostics ' + $uri + ' count=' + $records.Count)
        }
        return
    }
    if ($hasId) {
        $id = Get-Prop $msg 'id'
        $script:respSeen[[string]$id] = $true
        # Capture the result body so request/response calls (codeAction) can read
        # it; previously a response was acknowledged but its payload discarded.
        $script:respResult[[string]$id] = (Get-Prop $msg 'result')
    }
}

function Invoke-LspPump {
    # Pump available PSES output through the handler. Returns once $Until is true
    # or $MaxMs elapses. Keeps a single outstanding async read so a poll timeout
    # never starts a second concurrent read.
    param([scriptblock]$Until, [int]$MaxMs = 250, [int]$PollMs = 60)
    $deadline = (Get-Date).AddMilliseconds($MaxMs)
    while ($true) {
        $f = Read-LspFrame -Buffer $script:buf
        while ($null -ne $f) { Invoke-LspMessage $f; $f = Read-LspFrame -Buffer $script:buf }
        if (& $Until) { return $true }
        $remMs = [int][Math]::Max(0, ($deadline - (Get-Date)).TotalMilliseconds)
        if ($remMs -le 0) { return (& $Until) }
        if ($script:proc.HasExited) { Write-DLog 'PSES child exited during pump'; return (& $Until) }
        if ($null -eq $script:pending) {
            $script:pending = $script:stdout.ReadAsync($script:chunk, 0, $script:chunk.Length)
        }
        $wait = [Math]::Min($remMs, $PollMs)
        if ($script:pending.Wait($wait)) {
            $count = $script:pending.Result
            $script:pending = $null
            if ($count -le 0) { Write-DLog 'PSES stdout closed'; return (& $Until) }
            $sub = New-Object byte[] $count
            [Array]::Copy($script:chunk, 0, $sub, 0, $count)
            $script:buf.AddRange($sub)
        }
    }
}

# --- PSES child lifecycle --------------------------------------------------
function Start-Pses {
    $startScript = Get-PsesStartScript
    if (-not (Test-Path -LiteralPath $startScript)) {
        Write-DLog ('PSES start script missing: ' + $startScript); return $false
    }
    $bundleRoot = Get-PsesBundleRoot
    $hostExe = Resolve-PsHost $PsHost
    if ($null -eq $hostExe) { Write-DLog 'no PowerShell host found (pwsh/powershell)'; return $false }
    if ($hostExe -ne $PsHost) { Write-DLog ('requested host ' + $PsHost + ' unavailable; using ' + $hostExe) }

    $stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff')
    $pseLog = Join-Path $logDir ('pses-server-' + $stamp + '.log')
    $sess = Join-Path $logDir ('pses-server-' + $stamp + '.json')
    $errLog = Join-Path $logDir ('pses-stderr-' + $stamp + '.log')

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $hostExe
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $logDir
    Add-ProcessArguments $psi @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $startScript,
        '-HostName', 'Claude Code PSES Daemon', '-HostProfileId', 'cc-pses-daemon', '-HostVersion', '1.1.0',
        '-BundledModulesPath', $bundleRoot,
        '-LogPath', $pseLog, '-LogLevel', 'Information',
        '-SessionDetailsPath', $sess,
        '-Stdio')
    # Make the vendored PSScriptAnalyzer visible to PSES so the analyzer pass runs.
    $pssaDir = Get-PssaModuleDir
    if (Test-Path -LiteralPath $pssaDir) {
        $psi.EnvironmentVariables['PSModulePath'] = $pssaDir + [System.IO.Path]::PathSeparator + $env:PSModulePath
        Write-DLog ('prepended vendored PSSA to child PSModulePath: ' + $pssaDir)
    } else {
        Write-DLog ('vendored PSSA dir absent (' + $pssaDir + '); analyzer pass may be parser-only')
    }

    Write-DLog ('launching PSES via ' + $hostExe)
    $script:proc = [System.Diagnostics.Process]::Start($psi)
    $script:stdin = $script:proc.StandardInput.BaseStream
    $script:stdout = $script:proc.StandardOutput.BaseStream
    $errFs = [System.IO.File]::Open($errLog, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    $null = $script:proc.StandardError.BaseStream.CopyToAsync($errFs)

    # initialize handshake (declares rename -> avoids PSES v4.6.0 NRE; see lib).
    $rootUri = ConvertTo-FileUri (Get-Location).Path
    $initId = 1
    # [trackA] initialize OMITS workspaceFolders to dodge the PSES v4.6.0 Linux
    # OnInitialize NRE (#2300); the omission and its full rationale live in
    # New-InitializeParams (lib/lsp-common.ps1) and are guarded by the unit suite.
    Send-Lsp @{
        jsonrpc = '2.0'; id = $initId; method = 'initialize'
        params = (New-InitializeParams -RootUri $rootUri -ProcessId $PID)
    }
    if (-not (Invoke-LspPump -Until { $script:respSeen.ContainsKey('1') } -MaxMs 20000)) {
        Write-DLog 'initialize response not received before deadline'
        return $false
    }
    Send-Lsp @{ jsonrpc = '2.0'; method = 'initialized'; params = @{} }
    Send-Lsp @{ jsonrpc = '2.0'; method = 'workspace/didChangeConfiguration'; params = @{ settings = @{ powershell = @{ scriptAnalysis = @{ enable = $true } } } } }
    $script:initDone = $true
    Write-DLog 'PSES initialized'
    return $true
}

function Stop-Pses {
    if ($null -eq $script:proc) { return }
    try { Send-Lsp @{ jsonrpc = '2.0'; id = 999; method = 'shutdown' } } catch { }
    Start-Sleep -Milliseconds 120
    try { Send-Lsp @{ jsonrpc = '2.0'; method = 'exit' } } catch { }
    Start-Sleep -Milliseconds 120
    try { if (-not $script:proc.HasExited) { $script:proc.Kill($true) } } catch {
        try { if (-not $script:proc.HasExited) { $script:proc.Kill() } } catch { }
    }
    Write-DLog 'PSES stopped'
}

# --- code-action correction enrichment (Track C) ---------------------------
function Add-CodeActionCorrections {
    # Best-effort: ask PSES for quickfix code actions covering every current
    # diagnostic in ONE textDocument/codeAction request, then thread each
    # suggested correction (replacement text) onto the matching diag record by
    # range-start. Reuses the warm PSES's already-computed markers (no second
    # analyzer pass). Surface-only -- never writes files. Any failure or timeout
    # leaves records unchanged (corrections simply absent), so diagnostics still
    # return: this is purely additive to the warm path.
    param([string]$Uri, [object[]]$RawDiags, [object[]]$Records, [int]$WaitMs = 1500)
    if (@($Records).Count -eq 0 -or @($RawDiags).Count -eq 0) { return }
    try {
        # Full-document range covering every diagnostic (LSP line is 0-based).
        $maxLine = 0
        foreach ($d in $RawDiags) {
            $endLine = [int](Get-Prop (Get-Prop (Get-Prop $d 'range') 'end') 'line')
            if ($endLine -gt $maxLine) { $maxLine = $endLine }
        }
        $docRange = @{ start = @{ line = 0; character = 0 }; end = @{ line = ($maxLine + 1); character = 0 } }

        $script:reqId++
        $id = $script:reqId
        $idKey = [string]$id
        if ($script:respResult.ContainsKey($idKey)) { $script:respResult.Remove($idKey) | Out-Null }
        Send-Lsp @{ jsonrpc = '2.0'; id = $id; method = 'textDocument/codeAction'
            params = @{ textDocument = @{ uri = $Uri }; range = $docRange
                context = @{ diagnostics = @($RawDiags) } } }

        Invoke-LspPump -Until { $script:respResult.ContainsKey($idKey) } -MaxMs $WaitMs | Out-Null
        if (-not $script:respResult.ContainsKey($idKey)) { Write-DLog ('codeAction: no response (id=' + $idKey + ')'); return }
        $result = $script:respResult[$idKey]
        $script:respResult.Remove($idKey) | Out-Null
        if ($null -eq $result) { return }

        # Group correction text by 0-based "line,character" start position. A
        # diagnostic offering several alternative fixes yields several edits at the
        # same start -> primary (first) + count (Q3: primary plus a count).
        $byPos = @{}
        foreach ($action in @($result)) {
            $edit = Get-Prop $action 'edit'
            if ($null -eq $edit) { continue }   # command-only action (e.g. show docs)
            $textEdits = @()
            $docChanges = Get-Prop $edit 'documentChanges'
            if ($null -ne $docChanges) {
                foreach ($dc in @($docChanges)) { $textEdits += @(Get-Prop $dc 'edits') }
            } else {
                $changes = Get-Prop $edit 'changes'
                if ($null -ne $changes) {
                    foreach ($p in $changes.PSObject.Properties) { $textEdits += @($p.Value) }
                }
            }
            foreach ($te in $textEdits) {
                if ($null -eq $te) { continue }
                $start = Get-Prop (Get-Prop $te 'range') 'start'
                $posKey = ([int](Get-Prop $start 'line')).ToString() + ',' + ([int](Get-Prop $start 'character')).ToString()
                if (-not $byPos.ContainsKey($posKey)) { $byPos[$posKey] = New-Object System.Collections.Generic.List[string] }
                [void]$byPos[$posKey].Add([string](Get-Prop $te 'newText'))
            }
        }
        if ($byPos.Count -eq 0) { return }

        $enriched = 0
        foreach ($rec in $Records) {
            $posKey = ([int]$rec.line - 1).ToString() + ',' + ([int]$rec.col - 1).ToString()
            if ($byPos.ContainsKey($posKey)) {
                $list = $byPos[$posKey]
                $rec.correction = [string]$list[0]
                $rec.correctionCount = $list.Count
                $enriched++
            }
        }
        Write-DLog ('codeAction: enriched ' + $enriched + ' of ' + @($Records).Count + ' record(s) for ' + $Uri)
    } catch {
        Write-DLog ('codeAction enrich error (ignored): ' + $_.Exception.Message)
    }
}

# --- diagnostics request (didOpen/didChange + settle) ----------------------
function Get-Diagnostics([string]$filePath) {
    $full = [System.IO.Path]::GetFullPath($filePath)
    if (-not (Test-Path -LiteralPath $full)) { return @{ ok = $false; error = 'file not found' } }
    $uri = ConvertTo-FileUri $full
    $key = ConvertTo-UriKey $uri

    $text = [System.IO.File]::ReadAllText($full)
    $hash = Get-ContentHash $text

    # Coalesce: identical content already analyzed -> return cached set.
    if ($script:lastHash.ContainsKey($key) -and $script:lastHash[$key] -eq $hash -and $script:diag.ContainsKey($key)) {
        Write-DLog ('cache-hit ' + $uri)
        return @{ ok = $true; cached = $true; records = $script:diag[$key].records }
    }

    # Debounce: let edits landing within the window fold into one pass, then
    # re-read so we analyze the freshest content exactly once.
    if ($DebounceMs -gt 0) {
        Invoke-LspPump -Until { $false } -MaxMs $DebounceMs | Out-Null
        $text2 = [System.IO.File]::ReadAllText($full)
        if ($text2 -ne $text) { $text = $text2; $hash = Get-ContentHash $text }
    }

    # Clear the prior publish for this uri so the settle waits for a NEW one.
    if ($script:diag.ContainsKey($key)) { $script:diag.Remove($key) | Out-Null }

    if ($script:openDocs.ContainsKey($key)) {
        $ver = [int]$script:openDocs[$key] + 1
        $script:openDocs[$key] = $ver
        Send-Lsp @{ jsonrpc = '2.0'; method = 'textDocument/didChange'
            params = @{ textDocument = @{ uri = $uri; version = $ver }
                contentChanges = @(@{ text = $text }) } }
    } else {
        $script:openDocs[$key] = 0
        Send-Lsp @{ jsonrpc = '2.0'; method = 'textDocument/didOpen'
            params = @{ textDocument = @{ uri = $uri; languageId = 'powershell'; version = 0; text = $text } } }
    }

    # Settle: wait for a publish, then for SettleMs of quiet after the LAST one,
    # capped at MaxWaitMs. This skips the early (often empty) parser publish in
    # favor of the settled PSScriptAnalyzer pass.
    Invoke-LspPump -Until {
        if (-not $script:diag.ContainsKey($key)) { return $false }
        $age = ((Get-Date) - $script:diag[$key].at).TotalMilliseconds
        return ($age -ge $SettleMs)
    } -MaxMs $MaxWaitMs | Out-Null

    $entry = if ($script:diag.ContainsKey($key)) { $script:diag[$key] } else { $null }
    $records = if ($null -ne $entry) { $entry.records } else { @() }
    $rawDiags = if ($null -ne $entry -and $entry.Contains('raw')) { @($entry.raw) } else { @() }
    # Track C: thread PSSA suggested corrections onto the records (in place) via a
    # single codeAction pass -- only when there are findings, so a clean file does
    # no codeAction work and the warm fast path (and the cache-hit path above)
    # stay untouched.
    if (@($records).Count -gt 0) { Add-CodeActionCorrections $uri $rawDiags $records }
    $script:lastHash[$key] = $hash
    if (-not $script:diag.ContainsKey($key)) { $script:diag[$key] = @{ records = @(); raw = @(); at = (Get-Date); seq = 0 } }
    Write-DLog ('analyzed ' + $uri + ' -> ' + @($records).Count + ' record(s)')
    return @{ ok = $true; cached = $false; records = @($records) }
}

# --- session file / heartbeat ----------------------------------------------
function Write-SessionFile([string]$pipeName, [string]$state) {
    $obj = [ordered]@{
        sessionId = $SessionId
        pid = $PID
        pipe = $pipeName
        host = $PsHost
        state = $state
        started = $script:startedIso
        heartbeat = (Get-Date -Format 'o')
        psesPid = if ($null -ne $script:proc) { $script:proc.Id } else { $null }
    }
    try { ($obj | ConvertTo-Json -Depth 5) | Out-File -FilePath $sessionFile -Encoding ascii -Force } catch { }
}

# ===========================================================================
$script:startedIso = (Get-Date -Format 'o')
$pipeName = 'powershell-lsp-' + $SessionId
Write-DLog ('--- daemon start: session=' + $SessionId + ' pipe=' + $pipeName + ' host=' + $PsHost + ' ---')

if (-not (Start-Pses)) {
    Write-DLog 'PSES launch failed; daemon exiting'
    Write-SessionFile $pipeName 'failed'
    exit 1
}

$server = New-Object System.IO.Pipes.NamedPipeServerStream(
    $pipeName, [System.IO.Pipes.PipeDirection]::InOut, 1,
    [System.IO.Pipes.PipeTransmissionMode]::Byte, [System.IO.Pipes.PipeOptions]::Asynchronous)

Write-SessionFile $pipeName 'ready'
Write-DLog 'pipe server ready'

$lastActivity = Get-Date
$lastHeartbeat = [DateTime]::MinValue
$connectTask = $null
$running = $true

try {
    while ($running) {
        $now = Get-Date
        if (($now - $lastHeartbeat).TotalSeconds -ge 10) {
            Write-SessionFile $pipeName 'ready'
            $lastHeartbeat = $now
        }
        if (($now - $lastActivity).TotalMinutes -ge $IdleTtlMin) {
            Write-DLog ('idle TTL (' + $IdleTtlMin + ' min) reached; shutting down')
            break
        }
        if ($script:proc.HasExited) { Write-DLog 'PSES child gone; shutting down'; break }

        # brief idle drain so PSES server requests get answered between clients
        Invoke-LspPump -Until { $false } -MaxMs 40 | Out-Null

        if ($null -eq $connectTask) { $connectTask = $server.WaitForConnectionAsync() }
        if (-not $connectTask.Wait(500)) { continue }
        $connectTask = $null
        $lastActivity = Get-Date

        try {
            $reader = New-Object System.IO.StreamReader($server, [System.Text.Encoding]::UTF8, $false, 4096, $true)
            $writer = New-Object System.IO.StreamWriter($server, (New-Object System.Text.UTF8Encoding($false)), 4096, $true)
            $writer.NewLine = "`n"; $writer.AutoFlush = $true
            $line = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($line)) { Write-DLog 'empty request'; }
            else {
                $req = $null
                try { $req = $line | ConvertFrom-Json } catch { }
                $action = [string](Get-Prop $req 'action')
                Write-DLog ('request action=' + $action)
                switch ($action) {
                    'diagnostics' {
                        $file = [string](Get-Prop $req 'file')
                        $res = Get-Diagnostics $file
                        if ($res.ok) {
                            # Stable order + dedupe, then apply the configured
                            # severity threshold + rule include/exclude, then cap
                            # per file (surfacing an "omitted" count for the client).
                            $ordered = Select-OrderedDiagnostics @($res.records)
                            $filtered = @(Select-FilteredDiagnostics $ordered $SeverityThreshold $script:RuleIncludeArr $script:RuleExcludeArr)
                            $total = $filtered.Count
                            if ($PerFileCap -gt 0 -and $total -gt $PerFileCap) {
                                $shown = @($filtered[0..($PerFileCap - 1)]); $omitted = $total - $PerFileCap
                            } else {
                                $shown = $filtered; $omitted = 0
                            }
                            $payload = [ordered]@{ ok = $true; action = 'diagnostics'; file = $file
                                cached = [bool]$res.cached; count = @($shown).Count; omitted = $omitted; diagnostics = @($shown) }
                        } else {
                            $payload = [ordered]@{ ok = $false; action = 'diagnostics'; error = $res.error }
                        }
                        $writer.WriteLine(($payload | ConvertTo-Json -Depth 8 -Compress))
                    }
                    'ping' {
                        $writer.WriteLine(([ordered]@{ ok = $true; action = 'ping'; pid = $PID; psesPid = $script:proc.Id } | ConvertTo-Json -Compress))
                    }
                    'shutdown' {
                        $writer.WriteLine(([ordered]@{ ok = $true; action = 'shutdown' } | ConvertTo-Json -Compress))
                        $running = $false
                    }
                    default {
                        $writer.WriteLine(([ordered]@{ ok = $false; error = ('unknown action: ' + $action) } | ConvertTo-Json -Compress))
                    }
                }
            }
            try { $writer.Flush() } catch { }
        } catch {
            Write-DLog ('request handling error: ' + $_.Exception.Message)
        } finally {
            try { if ($server.IsConnected) { $server.Disconnect() } } catch { }
        }
    }
} finally {
    Write-DLog 'main loop ended; cleanup'
    try { $server.Dispose() } catch { }
    Stop-Pses
    try { if (Test-Path -LiteralPath $sessionFile) { Remove-Item -LiteralPath $sessionFile -Force } } catch { }
    Write-DLog '--- daemon exit ---'
}
