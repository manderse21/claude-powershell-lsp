#Requires -Version 5.1
# measure.ps1 -- publication evidence set for dispatch 000273 (freeze 1B),
# measured against the staged cache build of release-identity commit C.
#
# Method follows docs/roadmap-ii/SLO-BASELINES.md section 4 at C:
#   * the REAL hook entry points are driven end to end over stdin; no internal
#     function is called directly and no code path is simulated
#   * a private junction-backed data root (bootstrap excluded, reap structurally
#     unable to reach a co-tenant daemon)
#   * each edit classified by a stats LINE-COUNT DELTA plus the client's own
#     banner, so "the client gave up" is distinguishable from "the client got an
#     answer" (the section 4.4 instrument defect)
#   * a unique nonce line per iteration, so no iteration times a cache hit
#   * medians with spread; nearest-rank percentiles, never interpolated
#   * discard-and-report: no run is silently dropped
#
# ASCII only.

param(
    [Parameter(Mandatory)][string] $Block,
    [string] $Base = 'C:\Users\mande\AppData\Local\Temp\psl-273',
    [int]    $N = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root    = Join-Path $Base 'root'
$Data    = Join-Path $Base 'data'
$Scratch = Join-Path $Base 'fx'
$Out     = Join-Path $Base 'out'
$Scripts = Join-Path $Root 'scripts'
New-Item -ItemType Directory -Path $Scratch -Force | Out-Null
New-Item -ItemType Directory -Path $Out -Force | Out-Null

$Enc = New-Object System.Text.UTF8Encoding($false)

# ---------------------------------------------------------------- primitives

function Invoke-Hook {
    # Spawn a plugin hook exactly as Claude Code does, and time the WHOLE external
    # process (start to exit). That external wall is what a user pays; the stats
    # log's totalMs starts inside an already-running client and cannot see it.
    param(
        [string] $ScriptPath, [string] $StdinJson, [int] $CapMs,
        [string] $DataRoot, [string[]] $ExtraArgs = @(), [hashtable] $ExtraEnv
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'pwsh'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($a in (@('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + @($ExtraArgs))) {
        if ($a) { $psi.ArgumentList.Add([string]$a) }
    }
    $psi.EnvironmentVariables['CLAUDE_PLUGIN_ROOT'] = $Root
    $psi.EnvironmentVariables['CLAUDE_PLUGIN_DATA'] = $DataRoot
    $psi.EnvironmentVariables['CLAUDE_PLUGIN_OPTION_enableStats'] = 'true'
    if ($ExtraEnv) { foreach ($k in $ExtraEnv.Keys) { $psi.EnvironmentVariables[$k] = [string]$ExtraEnv[$k] } }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = [System.Diagnostics.Process]::Start($psi)
    $so = $p.StandardOutput.ReadToEndAsync()
    $se = $p.StandardError.ReadToEndAsync()
    if ($StdinJson) {
        $b = [System.Text.Encoding]::UTF8.GetBytes($StdinJson)
        $p.StandardInput.BaseStream.Write($b, 0, $b.Length)
        $p.StandardInput.BaseStream.Flush()
    }
    $p.StandardInput.Close()
    $exited = $p.WaitForExit($CapMs)
    $sw.Stop()
    if (-not $exited) { try { $p.Kill($true) } catch { } }
    [void]$so.Wait(2000); [void]$se.Wait(2000)
    return [pscustomobject]@{
        WallMs = [int]$sw.ElapsedMilliseconds
        Exited = $exited
        Stdout = $(if ($so.IsCompleted) { $so.Result } else { '' })
        Stderr = $(if ($se.IsCompleted) { $se.Result } else { '' })
    }
}

function Get-StatsPath([string] $DataRoot) { return (Join-Path $DataRoot 'logs/stats.jsonl') }

function Get-StatsLines([string] $DataRoot) {
    $p = Get-StatsPath $DataRoot
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    try { return @([IO.File]::ReadAllLines($p) | Where-Object { $_.Trim() -ne '' }) } catch { return @() }
}

function Invoke-DaemonAction {
    # Speak the daemon's own pipe protocol. Returns the parsed response or $null.
    param([string] $SessionId, [string] $Action, [int] $ConnectMs = 2000)
    $pipe = $null
    try {
        $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', ('powershell-lsp-' + $SessionId),
            [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::None)
        $pipe.Connect($ConnectMs)
        $w = New-Object System.IO.StreamWriter($pipe); $w.AutoFlush = $true
        $r = New-Object System.IO.StreamReader($pipe)
        $w.WriteLine((@{ action = $Action } | ConvertTo-Json -Compress))
        $line = $r.ReadLine()
        if ([string]::IsNullOrWhiteSpace($line)) { return $null }
        return ($line | ConvertFrom-Json)
    } catch { return $null } finally { if ($pipe) { try { $pipe.Dispose() } catch { } } }
}

function Get-Prop($o, [string] $n) {
    if ($null -eq $o) { return $null }
    if ($o -is [System.Collections.IDictionary]) { if ($o.Contains($n)) { return $o[$n] } return $null }
    $p = $o.PSObject.Properties[$n]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Get-Median([double[]] $v) {
    $s = @($v | Sort-Object); $n = $s.Count
    if ($n -eq 0) { return $null }
    if ($n % 2 -eq 1) { return [double]$s[[int][math]::Floor($n / 2)] }
    return (([double]$s[$n / 2 - 1] + [double]$s[$n / 2]) / 2.0)
}

function Get-NearestRank([double[]] $v, [double] $p) {
    $s = @($v | Sort-Object); $n = $s.Count
    if ($n -eq 0) { return $null }
    $r = [int][math]::Ceiling($p * $n) - 1
    if ($r -lt 0) { $r = 0 }; if ($r -ge $n) { $r = $n - 1 }
    return [double]$s[$r]
}

function Get-Summary([double[]] $v, [string] $label) {
    $c = @($v)
    if ($c.Count -eq 0) { return [ordered]@{ metric = $label; n = 0; median = $null; p95 = $null; min = $null; max = $null; spread = $null } }
    $mn = ($c | Measure-Object -Minimum).Minimum
    $mx = ($c | Measure-Object -Maximum).Maximum
    return [ordered]@{
        metric = $label; n = $c.Count
        median = [math]::Round((Get-Median $c), 1)
        p95    = [math]::Round((Get-NearestRank $c 0.95), 1)
        min    = [math]::Round($mn, 1); max = [math]::Round($mx, 1)
        spread = [math]::Round(($mx - $mn), 1)
    }
}

function Get-LoadSample {
    # Coarse machine-load observation, taken before and after every block, so the
    # "daytime-desktop-class" label is evidence rather than an assertion.
    $cpu = @()
    for ($i = 0; $i -lt 5; $i++) {
        try {
            $v = (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop).PercentProcessorTime
            $cpu += [double]$v
        } catch { }
        Start-Sleep -Milliseconds 200
    }
    return [ordered]@{
        cpu_samples = $cpu
        cpu_median  = $(if ($cpu.Count) { Get-Median $cpu } else { $null })
        processes   = @(Get-Process).Count
    }
}

function Get-HeadStamp {
    # The concurrent-checkout guard: stamp the frozen tree's identity around every
    # long block, so a tree that moved mid-measurement cannot pass unnoticed.
    $h = & git -C 'C:\Users\mande\projects\work\nortam\claude-powershell-lsp\worktrees\s000273-freeze' rev-parse origin/main
    $client = Join-Path $Root 'scripts/lsp-client.ps1'
    $hash = (Get-FileHash -LiteralPath $client -Algorithm SHA256).Hash.ToLower()
    return [ordered]@{ origin_main = ([string]$h).Trim(); staged_client_sha256 = $hash; at = (Get-Date).ToString('o') }
}

function New-DataRoot([string] $tag) {
    # A per-session private data root, junction-backed exactly like the shared one,
    # so bootstrap no-ops and reap cannot reach a co-tenant daemon.
    $d = Join-Path $Base ('d-' + $tag)
    if (Test-Path -LiteralPath $d) { Remove-DataRoot $d }
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $d 'logs') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $d 'session') -Force | Out-Null
    foreach ($j in @('PowerShellEditorServices', 'modules')) {
        & cmd.exe /c mklink /J ('"' + (Join-Path $d $j) + '"') ('"' + (Join-Path $Data $j) + '"') | Out-Null
    }
    Get-ChildItem -LiteralPath $Data -Filter '*.ok' -File | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $d $_.Name) -Force
    }
    return $d
}

function Remove-DataRoot([string] $d) {
    if (-not (Test-Path -LiteralPath $d)) { return }
    foreach ($j in @('PowerShellEditorServices', 'modules')) {
        $p = Join-Path $d $j
        if (Test-Path -LiteralPath $p) { & cmd.exe /c rmdir ('"' + $p + '"') 2>&1 | Out-Null }
    }
    Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
}

function Stop-ScopedStrays([string] $marker) {
    # Every kill is filtered on the private data-root path -- a string a co-tenant
    # daemon structurally cannot carry.
    $killed = 0
    try {
        Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction Stop | ForEach-Object {
            if ($_.CommandLine -and $_.CommandLine.Contains($marker)) {
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; $killed++
            }
        }
    } catch { }
    return $killed
}

function Start-Session {
    # Drive the real SessionStart hook and wait for the pipe to answer ping.
    param([string] $DataRoot, [string] $Sid, [int] $TimeoutMs = 60000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-Hook -ScriptPath (Join-Path $Scripts 'session-start.ps1') `
        -StdinJson (@{ session_id = $Sid } | ConvertTo-Json -Compress) `
        -CapMs $TimeoutMs -DataRoot $DataRoot -ExtraArgs @('-PreferredHost', 'pwsh')
    $hookWall = $r.WallMs
    $pingMs = -1; $ping = $null
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $ping = Invoke-DaemonAction -SessionId $Sid -Action 'ping' -ConnectMs 300
        if ($null -ne $ping) { $pingMs = [int]$sw.ElapsedMilliseconds; break }
        Start-Sleep -Milliseconds 50
    }
    $sw.Stop()
    return [pscustomobject]@{ HookWallMs = $hookWall; PingMs = $pingMs; Ping = $ping }
}

function Stop-Session {
    param([string] $DataRoot, [string] $Sid)
    $r = Invoke-DaemonAction -SessionId $Sid -Action 'shutdown' -ConnectMs 2000
    Invoke-Hook -ScriptPath (Join-Path $Scripts 'session-end.ps1') `
        -StdinJson (@{ session_id = $Sid } | ConvertTo-Json -Compress) `
        -CapMs 10000 -DataRoot $DataRoot | Out-Null
    return $r
}

function Invoke-Edit {
    # ONE edit through the real PostToolUse client, classified by a stats
    # line-count DELTA plus the client's own banner. A tailing reader would
    # silently re-attribute the previous edit's record when the client gave up.
    param([string] $DataRoot, [string] $Sid, [string] $File, [string] $Body, [int] $Nonce, [int] $CapMs = 30000)
    [IO.File]::WriteAllText($File, ($Body + "`n# nonce " + $Nonce + "`n"), $Enc)
    $before = @(Get-StatsLines $DataRoot).Count
    $r = Invoke-Hook -ScriptPath (Join-Path $Scripts 'lsp-client.ps1') `
        -StdinJson (@{ session_id = $Sid; tool_input = @{ file_path = $File }; cwd = (Split-Path -Parent $File) } | ConvertTo-Json -Compress) `
        -CapMs $CapMs -DataRoot $DataRoot
    # @() at the CALL SITE: a PowerShell function returning a one-element array
    # unrolls it to a scalar, and $lines[-1] would then index a STRING by character.
    $lines = @(Get-StatsLines $DataRoot)
    $after = $lines.Count
    $rec = $null
    if ($after -gt $before) { try { $rec = ($lines[-1] | ConvertFrom-Json) } catch { $rec = $null } }
    $banner = [string]$r.Stdout
    return [pscustomobject]@{
        WallMs      = $r.WallMs
        Exited      = $r.Exited
        StatsDelta  = ($after - $before)
        Checked     = (($after -gt $before) -and ($banner -notmatch 'NOT checked'))
        NotChecked  = ($banner -match 'NOT checked')
        TotalMs     = [double](Get-Prop $rec 'totalMs')
        AnalysisMs  = [double](Get-Prop $rec 'analysisMs')
        ConnectMs   = [double](Get-Prop $rec 'connectMs')
        CodeActionMs = [double](Get-Prop $rec 'codeActionMs')
        Taken       = (Get-Prop $rec 'taken')
        Banner      = $banner
    }
}

function Get-MemSample {
    param([string] $Sid)
    $p = Invoke-DaemonAction -SessionId $Sid -Action 'ping' -ConnectMs 2000
    if ($null -eq $p) { return $null }
    $dpid = Get-Prop $p 'pid'; $spid = Get-Prop $p 'psesPid'
    $o = [ordered]@{ daemon_pid = $dpid; pses_pid = $spid }
    foreach ($pair in @(@('daemon', $dpid), @('pses', $spid))) {
        $ws = $null; $pb = $null
        if ($pair[1]) {
            try {
                $proc = Get-Process -Id $pair[1] -ErrorAction Stop
                $ws = [math]::Round($proc.WorkingSet64 / 1MB, 1)
                $pb = [math]::Round($proc.PrivateMemorySize64 / 1MB, 1)
            } catch { }
        }
        $o[($pair[0] + '_ws_mb')] = $ws
        $o[($pair[0] + '_priv_mb')] = $pb
    }
    return $o
}

# ---------------------------------------------------------------- fixtures

# Small fixture matched to the v1.31.0 baseline's stated shape -- 219 bytes,
# 7 lines by newline-split, exactly one PSUseApprovedVerbs finding -- so a
# re-measured figure is comparable to the figure it replaces.
$SmallBody = @'
function Fetch-Thing {
    param([string]$Name)
    # warm-path timing fixture -- one PSUseApprovedVerbs finding, nothing else (dispatch 000273, freeze 1B)
    $items = Get-Process -Name $Name
    Write-Output $items
}
'@

function New-SmallFixture([string] $path) {
    [IO.File]::WriteAllText($path, ($SmallBody + "`n"), $Enc)
    return $path
}

function New-LargeFixture([string] $path) {
    # The plugin's own scripts/lib/lsp-common.ps1 AT C -- still the largest shipped
    # runtime file at C, and the file the plugin's own source names as the binding
    # case. Its size is a MEASURED property of C, recorded by the caller.
    Copy-Item -LiteralPath (Join-Path $Root 'scripts/lib/lsp-common.ps1') -Destination $path -Force
    return $path
}

function Get-FileFacts([string] $path) {
    $b = [IO.File]::ReadAllBytes($path)
    $text = [IO.File]::ReadAllText($path)
    return [ordered]@{ bytes = $b.Length; lines = @($text -split "`n").Count }
}

# ---------------------------------------------------------------- blocks

function Save-Result($obj, [string] $name) {
    $p = Join-Path $Out ($name + '.json')
    ($obj | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $p -Encoding UTF8
    Write-Host ('wrote ' + $p)
}

function Invoke-M1 {
    param([int] $Reps = 30)
    $loadBefore = Get-LoadSample
    $headBefore = Get-HeadStamp
    $sid = 'm1-267'
    $d = New-DataRoot $sid
    $fx = New-SmallFixture (Join-Path $Scratch 'm1.ps1')
    $facts = Get-FileFacts $fx
    $s = Start-Session -DataRoot $d -Sid $sid
    Write-Host ('M1 bring-up: hookWall=' + $s.HookWallMs + ' pingMs=' + $s.PingMs)

    # Priming is untimed and REPORTED: cold bring-up answers the pipe before PSES
    # can analyze, so timing starts only after a settled pass has been observed.
    $prime = 0; $n = 0
    while ($prime -lt 8) {
        $n++; $prime++
        $e = Invoke-Edit -DataRoot $d -Sid $sid -File $fx -Body $SmallBody -Nonce $n
        Write-Host ('  prime ' + $prime + ': wall=' + $e.WallMs + ' checked=' + $e.Checked + ' delta=' + $e.StatsDelta)
        if ($e.Checked) { break }
    }

    $rows = @()
    for ($i = 1; $i -le $Reps; $i++) {
        $n++
        $e = Invoke-Edit -DataRoot $d -Sid $sid -File $fx -Body $SmallBody -Nonce $n
        $rows += $e
        Write-Host ('  edit ' + $i + '/' + $Reps + ': wall=' + $e.WallMs + ' total=' + $e.TotalMs + ' analysis=' + $e.AnalysisMs + ' checked=' + $e.Checked)
    }
    Stop-Session -DataRoot $d -Sid $sid | Out-Null
    $strays = Stop-ScopedStrays $d
    $loadAfter = Get-LoadSample
    $headAfter = Get-HeadStamp

    $kept = @($rows | Where-Object { $_.Checked })
    $res = [ordered]@{
        block = 'M1 warm per-edit settle latency'
        commit = '6ab2d24bf254787520ad9449c4e6c17f74ee708d'
        fixture = $facts
        priming_edits = $prime
        attempted = $rows.Count
        kept = $kept.Count
        excluded = ($rows.Count - $kept.Count)
        exclusions = @($rows | Where-Object { -not $_.Checked } | ForEach-Object { @{ wallMs = $_.WallMs; statsDelta = $_.StatsDelta; notChecked = $_.NotChecked } })
        summaries = @(
            (Get-Summary ([double[]]@($kept | ForEach-Object { [double]$_.WallMs })) 'end_to_end_wall_ms'),
            (Get-Summary ([double[]]@($kept | ForEach-Object { $_.TotalMs })) 'client_totalMs'),
            (Get-Summary ([double[]]@($kept | ForEach-Object { $_.AnalysisMs })) 'daemon_analysisMs'),
            (Get-Summary ([double[]]@($kept | ForEach-Object { $_.ConnectMs })) 'client_connectMs'),
            (Get-Summary ([double[]]@($kept | ForEach-Object { $_.CodeActionMs })) 'daemon_codeActionMs')
        )
        load_before = $loadBefore; load_after = $loadAfter
        head_before = $headBefore; head_after = $headAfter
        scoped_strays_swept = $strays
    }
    Remove-DataRoot $d
    Save-Result $res 'm1'
    return $res
}

function Invoke-M2 {
    param([int] $Reps = 10)
    $loadBefore = Get-LoadSample
    $headBefore = Get-HeadStamp
    $sessions = @()
    for ($i = 1; $i -le $Reps; $i++) {
        $sid = 'm2-267-' + $i
        $d = New-DataRoot $sid
        $fx = New-SmallFixture (Join-Path $Scratch ('m2-' + $i + '.ps1'))
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $s = Start-Session -DataRoot $d -Sid $sid
        $segA = $s.PingMs
        $edits = 0; $unchecked = 0; $coldMs = -1; $n = 0
        while ($edits -lt 15) {
            $n++; $edits++
            $e = Invoke-Edit -DataRoot $d -Sid $sid -File $fx -Body $SmallBody -Nonce $n
            if ($e.NotChecked -or -not $e.Checked) { $unchecked++ }
            if ($e.Checked) { $coldMs = [int]$sw.ElapsedMilliseconds; break }
        }
        $sw.Stop()
        Stop-Session -DataRoot $d -Sid $sid | Out-Null
        Stop-ScopedStrays $d | Out-Null
        Remove-DataRoot $d
        $sessions += [pscustomobject]@{ i = $i; hookWallMs = $s.HookWallMs; segAMs = $segA; coldMs = $coldMs; edits = $edits; unchecked = $unchecked }
        Write-Host ('  M2 session ' + $i + '/' + $Reps + ': segA=' + $segA + ' cold=' + $coldMs + ' edits=' + $edits + ' unchecked=' + $unchecked)
    }
    $loadAfter = Get-LoadSample
    $headAfter = Get-HeadStamp
    $ok = @($sessions | Where-Object { $_.coldMs -ge 0 })
    $res = [ordered]@{
        block = 'M2 cold start to first-analysis-ready'
        commit = '6ab2d24bf254787520ad9449c4e6c17f74ee708d'
        attempted = $sessions.Count
        converged = $ok.Count
        summaries = @(
            (Get-Summary ([double[]]@($sessions | ForEach-Object { [double]$_.hookWallMs })) 'sessionstart_hook_wall_ms'),
            (Get-Summary ([double[]]@($ok | ForEach-Object { [double]$_.segAMs })) 'segment_A_pipe_answers_ping_ms'),
            (Get-Summary ([double[]]@($ok | ForEach-Object { [double]$_.coldMs })) 'cold_start_to_first_settled_ms'),
            (Get-Summary ([double[]]@($ok | ForEach-Object { [double]$_.edits })) 'edits_until_first_settled'),
            (Get-Summary ([double[]]@($ok | ForEach-Object { [double]$_.unchecked })) 'edits_returned_not_checked')
        )
        sessions = $sessions
        load_before = $loadBefore; load_after = $loadAfter
        head_before = $headBefore; head_after = $headAfter
    }
    Save-Result $res 'm2'
    return $res
}

function Invoke-M35 {
    param([int] $Reps = 120)
    $loadBefore = Get-LoadSample
    $headBefore = Get-HeadStamp
    $sid = 'm35-267'
    $d = New-DataRoot $sid
    $fx = New-SmallFixture (Join-Path $Scratch 'm35.ps1')
    $s = Start-Session -DataRoot $d -Sid $sid
    Write-Host ('M3/M5 bring-up: hookWall=' + $s.HookWallMs + ' pingMs=' + $s.PingMs)
    $prime = 0; $n = 0
    while ($prime -lt 8) {
        $n++; $prime++
        $e = Invoke-Edit -DataRoot $d -Sid $sid -File $fx -Body $SmallBody -Nonce $n
        if ($e.Checked) { break }
    }
    $firstReady = Get-MemSample -Sid $sid
    $rows = @(); $mem = @()
    $runSw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 1; $i -le $Reps; $i++) {
        $n++
        $e = Invoke-Edit -DataRoot $d -Sid $sid -File $fx -Body $SmallBody -Nonce $n
        $rows += $e
        if ($i % 10 -eq 0) {
            $m = Get-MemSample -Sid $sid
            if ($m) { $m['edit'] = $i; $mem += $m }
            Write-Host ('  M5 edit ' + $i + '/' + $Reps + ': wall=' + $e.WallMs + ' analysis=' + $e.AnalysisMs + ' checked=' + $e.Checked + ' daemonWS=' + $(if ($m) { $m['daemon_ws_mb'] } else { 'n/a' }))
        }
    }
    $runSw.Stop()
    Stop-Session -DataRoot $d -Sid $sid | Out-Null
    $strays = Stop-ScopedStrays $d
    $loadAfter = Get-LoadSample
    $headAfter = Get-HeadStamp

    $kept = @($rows | Where-Object { $_.Checked })
    $q1 = @($kept | Select-Object -First 30)
    $q4 = @($kept | Select-Object -Last 30)
    $res = [ordered]@{
        block = 'M3 daemon steady-state memory + M5 sustained-session stability'
        commit = '6ab2d24bf254787520ad9449c4e6c17f74ee708d'
        priming_edits = $prime
        attempted = $rows.Count
        kept = $kept.Count
        excluded = ($rows.Count - $kept.Count)
        run_seconds = [math]::Round($runSw.Elapsed.TotalSeconds, 1)
        first_ready_mem = $firstReady
        mem_samples = $mem
        mem_summaries = @(
            (Get-Summary ([double[]]@($mem | Where-Object { $_['daemon_ws_mb'] } | ForEach-Object { [double]$_['daemon_ws_mb'] })) 'daemon_working_set_mb'),
            (Get-Summary ([double[]]@($mem | Where-Object { $_['pses_ws_mb'] } | ForEach-Object { [double]$_['pses_ws_mb'] })) 'pses_working_set_mb'),
            (Get-Summary ([double[]]@($mem | Where-Object { $_['daemon_priv_mb'] } | ForEach-Object { [double]$_['daemon_priv_mb'] })) 'daemon_private_mb'),
            (Get-Summary ([double[]]@($mem | Where-Object { $_['pses_priv_mb'] } | ForEach-Object { [double]$_['pses_priv_mb'] })) 'pses_private_mb')
        )
        summaries = @(
            (Get-Summary ([double[]]@($kept | ForEach-Object { [double]$_.WallMs })) 'end_to_end_wall_ms_whole_run'),
            (Get-Summary ([double[]]@($kept | ForEach-Object { $_.AnalysisMs })) 'daemon_analysisMs_whole_run')
        )
        drift = [ordered]@{
            first_quartile_wall_median    = $(if ($q1.Count) { [math]::Round((Get-Median ([double[]]@($q1 | ForEach-Object { [double]$_.WallMs }))), 1) } else { $null })
            last_quartile_wall_median     = $(if ($q4.Count) { [math]::Round((Get-Median ([double[]]@($q4 | ForEach-Object { [double]$_.WallMs }))), 1) } else { $null })
            first_quartile_analysis_median = $(if ($q1.Count) { [math]::Round((Get-Median ([double[]]@($q1 | ForEach-Object { $_.AnalysisMs }))), 1) } else { $null })
            last_quartile_analysis_median  = $(if ($q4.Count) { [math]::Round((Get-Median ([double[]]@($q4 | ForEach-Object { $_.AnalysisMs }))), 1) } else { $null })
        }
        load_before = $loadBefore; load_after = $loadAfter
        head_before = $headBefore; head_after = $headAfter
        scoped_strays_swept = $strays
    }
    Remove-DataRoot $d
    Save-Result $res 'm35'
    return $res
}

function Invoke-M4b {
    # The large-file convergence block. UNIFORM attempt cap across sessions -- the
    # only reason M4b, not the pooled row, is the primary figure.
    param([int] $Sessions = 5, [int] $Cap = 15)
    $loadBefore = Get-LoadSample
    $headBefore = Get-HeadStamp
    $facts = $null
    $rows = @()
    for ($i = 1; $i -le $Sessions; $i++) {
        $sid = 'm4b-267-' + $i
        $d = New-DataRoot $sid
        $fx = New-LargeFixture (Join-Path $Scratch ('m4b-' + $i + '.ps1'))
        if (-not $facts) { $facts = Get-FileFacts $fx }
        $body = [IO.File]::ReadAllText($fx)
        $loadS = Get-LoadSample
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $s = Start-Session -DataRoot $d -Sid $sid
        $converged = $false; $convergeAt = -1; $convergeMs = -1; $unchecked = 0
        $edits = @()
        for ($k = 1; $k -le $Cap; $k++) {
            $e = Invoke-Edit -DataRoot $d -Sid $sid -File $fx -Body $body -Nonce $k -CapMs 40000
            $edits += $e
            if (-not $e.Checked) { $unchecked++ }
            if ($e.Checked -and -not $converged) {
                $converged = $true; $convergeAt = $k; $convergeMs = [int]$sw.ElapsedMilliseconds
            }
        }
        $sw.Stop()
        # Per-session daemon / relaunch behavior, read from the plugin's own logs.
        # pses-server-<stamp>.json is written by the daemon into logs/, NOT session/
        # (pses-daemon.ps1:379). Reading session/ returned a vacuous 0.
        $daemons = @(Get-ChildItem -LiteralPath (Join-Path $d 'logs') -Filter 'pses-server-*.json' -File -ErrorAction SilentlyContinue).Count
        $clientLog = Join-Path $d 'logs/lsp-client.log'
        $relaunch = 0; $unreachable = 0; $connFail = 0
        if (Test-Path -LiteralPath $clientLog) {
            $t = [IO.File]::ReadAllText($clientLog)
            $relaunch    = ([regex]::Matches($t, 'auto-relaunch: daemon launch fired')).Count
            $unreachable = ([regex]::Matches($t, 'daemon unreachable')).Count
            $connFail    = ([regex]::Matches($t, 'connect attempt failed')).Count
        }
        $dlog = Join-Path $d 'logs/pses-daemon.log'
        $settledTrue = 0; $notSettle = 0
        if (Test-Path -LiteralPath $dlog) {
            $t2 = [IO.File]::ReadAllText($dlog)
            $settledTrue = ([regex]::Matches($t2, 'settled=True')).Count
            $notSettle   = ([regex]::Matches($t2, 'analysis did not settle')).Count
        }
        $kept = @($edits | Where-Object { $_.Checked })
        $rows += [pscustomobject]@{
            i = $i; converged = $converged; convergeAtEdit = $convergeAt; convergeMs = $convergeMs
            bringupHookWallMs = $s.HookWallMs; bringupPingMs = $s.PingMs
            attempts = $Cap; unchecked = $unchecked; statsLines = @(Get-StatsLines $d).Count
            daemonsLaunched = $daemons; autoRelaunches = $relaunch
            clientUnreachable = $unreachable; clientConnectFail = $connFail
            daemonSettledTrue = $settledTrue; daemonNotSettle = $notSettle
            cpuMedianBefore = $loadS['cpu_median']
            keptWall = @($kept | ForEach-Object { [double]$_.WallMs })
            keptTotal = @($kept | ForEach-Object { $_.TotalMs })
            keptAnalysis = @($kept | ForEach-Object { $_.AnalysisMs })
            keptCodeAction = @($kept | ForEach-Object { $_.CodeActionMs })
        }
        Write-Host ('  M4b session ' + $i + '/' + $Sessions + ': converged=' + $converged + ' atEdit=' + $convergeAt +
                      ' ms=' + $convergeMs + ' unchecked=' + $unchecked + '/' + $Cap + ' daemons=' + $daemons + ' relaunch=' + $relaunch)
        Stop-Session -DataRoot $d -Sid $sid | Out-Null
        Stop-ScopedStrays $d | Out-Null
        Remove-DataRoot $d
    }
    $loadAfter = Get-LoadSample
    $headAfter = Get-HeadStamp
    $conv = @($rows | Where-Object { $_.converged })
    $allKeptWall = @($rows | ForEach-Object { $_.keptWall } | Where-Object { $_ })
    $allKeptTotal = @($rows | ForEach-Object { $_.keptTotal } | Where-Object { $_ })
    $allKeptAnalysis = @($rows | ForEach-Object { $_.keptAnalysis } | Where-Object { $_ })
    $allKeptCA = @($rows | ForEach-Object { $_.keptCodeAction } | Where-Object { $_ })
    $res = [ordered]@{
        block = 'M4b large-file convergence (primary figure) + M4 large-file settle latency'
        commit = '6ab2d24bf254787520ad9449c4e6c17f74ee708d'
        fixture = $facts
        fixture_source = 'scripts/lib/lsp-common.ps1 at C'
        sessions = $rows.Count
        converged = $conv.Count
        attempt_cap_each = $Cap
        per_session = $rows
        daemons_per_session = (Get-Summary ([double[]]@($rows | ForEach-Object { [double]$_.daemonsLaunched })) 'daemons_launched_per_session')
        relaunch_per_session = (Get-Summary ([double[]]@($rows | ForEach-Object { [double]$_.autoRelaunches })) 'auto_relaunches_per_session')
        m4_conditional_summaries = @(
            (Get-Summary ([double[]]$allKeptWall) 'end_to_end_wall_ms'),
            (Get-Summary ([double[]]$allKeptTotal) 'client_totalMs'),
            (Get-Summary ([double[]]$allKeptAnalysis) 'daemon_analysisMs'),
            (Get-Summary ([double[]]$allKeptCA) 'daemon_codeActionMs')
        )
        load_before = $loadBefore; load_after = $loadAfter
        head_before = $headBefore; head_after = $headAfter
    }
    Save-Result $res 'm4b'
    return $res
}

# ---------------------------------------------------------------- dispatch

switch ($Block) {
    'm1'   { Invoke-M1   -Reps $(if ($N) { $N } else { 30 })  | Out-Null }
    'm2'   { Invoke-M2   -Reps $(if ($N) { $N } else { 10 })  | Out-Null }
    'm35'  { Invoke-M35  -Reps $(if ($N) { $N } else { 120 }) | Out-Null }
    'm4b'  { Invoke-M4b  -Sessions $(if ($N) { $N } else { 5 }) | Out-Null }
    default { throw ('unknown block: ' + $Block) }
}
Write-Output ('BLOCK ' + $Block + ' DONE')
