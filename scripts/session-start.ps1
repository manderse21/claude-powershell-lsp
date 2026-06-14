#Requires -Version 5.1

# session-start.ps1 -- SessionStart hook. Orchestrates the warm-path bring-up:
#   1. ensure-pses   (idempotent PSES bootstrap, pinned tag)
#   2. ensure-pssa   (idempotent PSScriptAnalyzer vendor, pinned version)
#   3. log sweep     (keep-last-N per rolling log family)
#   4. reap          (kill OUR stale daemons; recorded pids only, verified)
#   5. launch        (exactly one daemon for this session id)
#
# stdout is silent (the hook contract does not want chatter at SessionStart); all
# output goes to CLAUDE_PLUGIN_DATA/logs. Fail-safe: never throw to stdout.
#
# Author: Mike Andersen / powershell-lsp plugin.

param(
    [string] $PreferredHost = 'pwsh',
    [int] $KeepLastN = 10,
    # Forwarded to the daemon (Stage 4 userConfig knobs).
    [string] $SeverityThreshold = 'Hint',
    [string] $RuleInclude = '',
    [string] $RuleExclude = '',
    [int] $DebounceMs = 150,
    [int] $IdleTtlMin = 30,
    [int] $PerFileCap = 20,
    [string] $SettingsPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/lsp-common.ps1')

# v1.1.1: the SessionStart hook no longer passes userConfig as -Args -- the
# ${user_config.*} substitution refused to launch the hook on CC v2.1.167 when any
# option was unset. Self-source each knob from the exported CLAUDE_PLUGIN_OPTION_*
# env var, falling back to the param default above. An explicit arg (e.g. the test
# harness's -PreferredHost) still wins, since it sets the value we fall back to.
$PreferredHost     = Get-PluginOption    'ps_host'           $PreferredHost
$SeverityThreshold = Get-PluginOption    'severityThreshold' $SeverityThreshold
$RuleInclude       = Get-PluginOption    'ruleInclude'       $RuleInclude
$RuleExclude       = Get-PluginOption    'ruleExclude'       $RuleExclude
$KeepLastN         = Get-PluginOptionInt 'keepLastN'         $KeepLastN
$DebounceMs        = Get-PluginOptionInt 'debounceMs'        $DebounceMs
$IdleTtlMin        = Get-PluginOptionInt 'idleTtlMin'        $IdleTtlMin
$PerFileCap        = Get-PluginOptionInt 'perFileCap'        $PerFileCap
$SettingsPath      = Get-PluginOption    'settingsPath'       $SettingsPath

$logDir = Get-LogDir
$sessionDir = Get-SessionDir
try {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null
} catch { }
$startLog = Join-Path $logDir 'session-start.log'
function Write-SLog([string]$m) {
    try { ('[' + (Get-Date -Format 'o') + '] ' + $m) | Out-File -FilePath $startLog -Append -Encoding ascii } catch { }
}

function Get-SessionIdFromStdin {
    try {
        $raw = Get-StdinText
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        $obj = $raw | ConvertFrom-Json
        return [string](Get-Prop $obj 'session_id')
    } catch { return $null }
}

function Invoke-LogSweep([int]$keep) {
    # Rolling families carry a -yyyyMMdd-HHmmss-fff stamp; group by the stem and
    # keep the newest N of each. Single append logs (one file) are untouched.
    try {
        $items = Get-ChildItem -LiteralPath $logDir -Force -ErrorAction SilentlyContinue
        $groups = @{}
        foreach ($it in $items) {
            $stem = [System.Text.RegularExpressions.Regex]::Replace($it.Name, '-\d{8}-\d{6}-\d{3}', '-STAMP')
            if ($stem -eq $it.Name) { continue }  # not a stamped family member
            if (-not $groups.ContainsKey($stem)) { $groups[$stem] = @() }
            $groups[$stem] += $it
        }
        foreach ($stem in $groups.Keys) {
            $sorted = @($groups[$stem] | Sort-Object LastWriteTime -Descending)
            if ($sorted.Count -le $keep) { continue }
            foreach ($old in $sorted[$keep..($sorted.Count - 1)]) {
                try { Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction SilentlyContinue } catch { }
            }
            Write-SLog ('swept family ' + $stem + ': removed ' + ($sorted.Count - $keep))
        }
    } catch { Write-SLog ('log sweep error: ' + $_.Exception.Message) }
}

function Test-IsOurDaemon([int]$daemonPid) {
    # Verify a recorded pid is genuinely one of OUR pses-daemon processes before
    # any kill (R5). Match host process name AND command line referencing the
    # daemon script. Never kill anything that fails both checks.
    try {
        $proc = Get-Process -Id $daemonPid -ErrorAction SilentlyContinue
        if ($null -eq $proc) { return $false }
        if (@('pwsh', 'powershell') -notcontains $proc.ProcessName.ToLowerInvariant()) { return $false }
        return ((Get-ProcessCommandLine $daemonPid) -match 'pses-daemon\.ps1')
    } catch { return $false }
}

function Stop-OrphanPses([int]$psesPid) {
    # Kill an orphaned PSES child by recorded pid -- only if it is verifiably a
    # PowerShell host running Start-EditorServices (R5: never kill foreign procs).
    # PSES does not reliably self-exit when its daemon dies, so a crashed daemon
    # leaves PSES running until this reap catches it.
    if (-not $psesPid) { return }
    try {
        $proc = Get-Process -Id $psesPid -ErrorAction SilentlyContinue
        if ($null -eq $proc) { return }
        if (@('pwsh', 'powershell') -notcontains $proc.ProcessName.ToLowerInvariant()) { return }
        if ((Get-ProcessCommandLine $psesPid) -match 'Start-EditorServices\.ps1') {
            Stop-Process -Id $psesPid -Force -ErrorAction SilentlyContinue
            Write-SLog ('reap: killed orphaned PSES child pid ' + $psesPid)
        }
    } catch { }
}

function Invoke-Reap([string]$currentSessionId) {
    # Kill OUR stale daemons. Stale = recorded pid no longer alive (just clean the
    # file), or alive-and-verified-ours with a heartbeat older than the threshold.
    $staleSec = 90
    try {
        $files = Get-ChildItem -LiteralPath $sessionDir -Filter '*.json' -File -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            $obj = $null
            try { $obj = (Get-Content -LiteralPath $f.FullName -Raw) | ConvertFrom-Json } catch { }
            if ($null -eq $obj) { try { Remove-Item -LiteralPath $f.FullName -Force } catch { }; continue }
            $recPid = [int](Get-Prop $obj 'pid')
            $psesPid = [int](Get-Prop $obj 'psesPid')
            $sid = [string](Get-Prop $obj 'sessionId')
            $hb = Get-Prop $obj 'heartbeat'
            $hbAge = 99999
            try { if ($null -ne $hb) { $hbAge = ((Get-Date) - [DateTime]$hb).TotalSeconds } } catch { }

            $alive = $null -ne (Get-Process -Id $recPid -ErrorAction SilentlyContinue)
            if (-not $alive) {
                Write-SLog ('reap: dead daemon pid ' + $recPid + ' (session ' + $sid + '); cleaning orphaned PSES + file')
                Stop-OrphanPses $psesPid
                try { Remove-Item -LiteralPath $f.FullName -Force } catch { }
                continue
            }
            $isCurrent = ($sid -eq $currentSessionId)
            if (($hbAge -ge $staleSec) -or $isCurrent) {
                if (Test-IsOurDaemon $recPid) {
                    $why = if ($isCurrent) { 'stale-or-superseded current session' } else { 'stale heartbeat ' + [int]$hbAge + 's' }
                    Write-SLog ('reap: killing our daemon pid ' + $recPid + ' (' + $why + ')')
                    try { Stop-Process -Id $recPid -Force -ErrorAction Stop } catch { Write-SLog ('reap kill failed: ' + $_.Exception.Message) }
                    Stop-OrphanPses $psesPid
                    try { Remove-Item -LiteralPath $f.FullName -Force } catch { }
                } else {
                    Write-SLog ('reap: pid ' + $recPid + ' not verifiably ours; leaving it, removing only the stale file')
                    if ($hbAge -ge $staleSec) { try { Remove-Item -LiteralPath $f.FullName -Force } catch { } }
                }
            }
        }
    } catch { Write-SLog ('reap error: ' + $_.Exception.Message) }
}

# ===========================================================================
try {
    $sessionId = Get-SessionIdFromStdin
    Write-SLog ('--- SessionStart (session=' + $sessionId + ') ---')

    $scriptDir = $PSScriptRoot
    $hostExe = Resolve-PsHost $PreferredHost
    if ($null -eq $hostExe) { Write-SLog 'no PowerShell host (pwsh/powershell) found; aborting bring-up'; exit 0 }

    # 1) ensure PSES (existing bootstrap) and 2) ensure PSSA -- both idempotent.
    foreach ($step in @('ensure-pses.ps1', 'ensure-pssa.ps1')) {
        try {
            & $hostExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptDir $step) 2>&1 | Out-Null
            Write-SLog ('ran ' + $step)
        } catch { Write-SLog ($step + ' error: ' + $_.Exception.Message) }
    }

    # 3) log sweep
    Invoke-LogSweep $KeepLastN

    # 4) reap stale daemons (and supersede any prior daemon for this session)
    Invoke-Reap $sessionId

    # 5) launch exactly one daemon for this session
    if ([string]::IsNullOrWhiteSpace($sessionId)) {
        Write-SLog 'no session_id on stdin; cannot key the pipe to match the client; skipping daemon launch'
        exit 0
    }
    $daemon = Join-Path $scriptDir 'pses-daemon.ps1'
    $daemonArgs = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $daemon,
        '-SessionId', $sessionId, '-PsHost', $hostExe, '-DataRoot', (Get-PluginDataRoot),
        '-SeverityThreshold', $SeverityThreshold, '-DebounceMs', [string]$DebounceMs,
        '-IdleTtlMin', [string]$IdleTtlMin, '-PerFileCap', [string]$PerFileCap)
    # Rule lists are optional; only pass when non-empty (an empty -ArgumentList
    # element would misalign the daemon's positional binding).
    if (-not [string]::IsNullOrWhiteSpace($RuleInclude)) { $daemonArgs += @('-RuleInclude', $RuleInclude) }
    if (-not [string]::IsNullOrWhiteSpace($RuleExclude)) { $daemonArgs += @('-RuleExclude', $RuleExclude) }
    # PSScriptAnalyzerSettings.psd1 override (absolute); only pass when set, else the
    # daemon auto-discovers the nearest settings file from the edited file (000018).
    if (-not [string]::IsNullOrWhiteSpace($SettingsPath)) { $daemonArgs += @('-SettingsPath', $SettingsPath) }
    # Launch DETACHED. Must NOT inherit this hook's stdout/stderr handles: if it
    # did, Claude Code's SessionStart hook would block on its own output pipe
    # until the daemon exits (the whole session). On Windows, Start-Process with
    # no redirection uses ShellExecute, which does not pass inheritable handles to
    # the child; the daemon writes nothing to stdout and logs to files itself.
    # (Non-Windows branch authored, CI-verified later.)
    if (Test-OnWindows) {
        Start-Process -FilePath $hostExe -ArgumentList $daemonArgs -WindowStyle Hidden | Out-Null
    } else {
        Start-Process -FilePath $hostExe -ArgumentList $daemonArgs | Out-Null
    }
    Write-SLog ('launched daemon (detached) for session ' + $sessionId + ' via ' + $hostExe)
    exit 0
}
catch {
    Write-SLog ('FATAL (fail-safe, exit 0): ' + $_.Exception.Message)
    exit 0
}
