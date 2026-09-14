#Requires -Version 5.1
# RED CONTROL for dispatch 000301 N6 -- the PRIOR IMPLEMENTATION of Invoke-ScanFileDiagnostics,
# verbatim, as it stood at fc525c90c78a0aff8ca77a009575a3da6ddea8eb (before this dispatch's Q1 fix).
#
# WHAT IT IS FOR. R25 (dispatch 000301) made POWERSHELL_LSP_CAPTURE_MODE default to `metadata`,
# which drops the dogfood capture log's `message` field. Invoke-ScanFileDiagnostics -- the scan
# entry point's (scripts/lsp-scan.ps1) OWN derivation engine -- reads that log back to recover each
# finding's message, and never set CAPTURE_MODE itself, so a default (no-env-var) scan inherited
# `metadata` and silently emitted an EMPTY message for every finding. New-SarifResult's existing
# rule-key fallback then papered over it with the bare rule id instead of a schema violation, which
# is exactly why nothing caught it: the SARIF stayed well-formed, just wrong.
#
# This file is that PRIOR function, unpatched: run it with POWERSHELL_LSP_CAPTURE_MODE unset (or
# `metadata`) and it must reproduce an EMPTY `message` on the returned finding, because it has never
# heard of forcing the mode for its own private transport. If it does not reproduce that, the
# shipped test proves nothing.
#
# IT IS THE PRIOR IMPLEMENTATION, NOT A HAND-WRITTEN MUTANT. The function body below was taken with
# `git show <sha>:scripts/lib/lsp-scan-common.ps1` and sliced at the function boundary; nothing in
# it was retyped or adjusted.
#
# WHY ONLY THE FUNCTION, AND WHY THAT IS STILL FAITHFUL. This fixture is dot-sourced AFTER the
# shipped lsp-common.ps1 and lsp-scan-common.ps1, so it OVERRIDES only Invoke-ScanFileDiagnostics --
# every helper it calls (Invoke-ScanHook, Get-Prop, New-ContainedDirectory) resolves to the shipped
# copy. Invoke-ScanHook in particular is UNCHANGED by this dispatch's fix (the fix is entirely the
# one -ExtraEnv line added to Invoke-ScanFileDiagnostics itself), so the two runs differ in exactly
# one thing: whether the scan's own ephemeral transport forces `full` regardless of the caller's
# ambient CAPTURE_MODE.
#
# RE-DERIVE THE BODY BELOW WITH:
#   git show fc525c90c78a0aff8ca77a009575a3da6ddea8eb:scripts/lib/lsp-scan-common.ps1 |
#     awk '/^function Invoke-ScanFileDiagnostics \{/,/^}/'

function Invoke-ScanFileDiagnostics {
    # Derive the REAL tool's findings for ONE file by running the REAL lsp-client.ps1 hook over
    # it (the same engine the in-agent edit path uses), with the dogfood capture log redirected
    # to a hermetic throwaway file and whole-file scoping (scopeToEdit=false -- a scan has no
    # edit range). Reads back the structured records the tool teed and returns:
    #   @{ File; Findings = @({ file; ruleId; source; severity; line; col; message }); Analyzed; ElapsedMs }
    # ElapsedMs (dispatch 000132 leg 2) is the wall-clock the per-file hook round-trip took -- for a
    # timed-out or cap-killed file this is ~the budget it hit, the "how long did it run" a bare count
    # lacked, so an INCOMPLETE can name the file AND how long it ran before the budget cut it.
    # Analyzed=$false when the hook output signals the analyzer was not reachable for this file
    # (a 'NOT checked' banner) -- surfaced by the caller so a degraded analysis is never reported
    # as a clean file (the project's never-silent rule). The file is analyzed IN PLACE so SARIF
    # carries its real path and the repo's own PSScriptAnalyzerSettings.psd1 is honored, exactly
    # as the in-agent hook honors it (000018).
    param(
        [string]$ScriptsDir,
        [string]$DataRoot,
        [string]$SessionId,
        [string]$HostExe,
        [string]$FilePath,
        [string]$Cwd = '',
        [int]$CapMs = 25000,
        [string]$CaptureDir = ''
    )
    $full = $FilePath
    try { $full = [System.IO.Path]::GetFullPath($FilePath) } catch { $full = $FilePath }
    if ([string]::IsNullOrWhiteSpace($Cwd)) { $Cwd = [System.IO.Path]::GetDirectoryName($full) }
    if ([string]::IsNullOrWhiteSpace($CaptureDir)) { $CaptureDir = Join-Path $DataRoot 'scan-capture' }
    if (-not (Test-Path -LiteralPath $CaptureDir)) { New-ContainedDirectory -Path $CaptureDir }
    $log = Join-Path $CaptureDir ('scan-' + [guid]::NewGuid().ToString('N').Substring(0, 12) + '.jsonl')

    $stdin = (@{ session_id = $SessionId; tool_input = @{ file_path = $full }; cwd = $Cwd } | ConvertTo-Json -Compress)
    # scopeToEdit=false => whole-file (a scan carries no edit patch); timeoutMs raised so a first
    # cold analysis on a slow leg still settles inside the client cap. NOTE (dispatch 000132): this
    # client-side cap is NOT the binding per-file budget -- the daemon's own settle cap (MaxWaitMs,
    # pses-daemon.ps1, default 5000) is; see the 000132 outbox and the 000133 charter. The dogfood log
    # is the SAME structured-finding channel the corpus reads, pointed at a throwaway file (never the repo log).
    $extraEnv = @{
        POWERSHELL_LSP_DOGFOOD_LOG       = $log
        CLAUDE_PLUGIN_OPTION_scopeToEdit = 'false'
        CLAUDE_PLUGIN_OPTION_timeoutMs   = '18000'
    }
    $killed = $false
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $stdout = Invoke-ScanHook -HostExe $HostExe -ScriptPath (Join-Path $ScriptsDir 'lsp-client.ps1') `
        -StdinJson $stdin -CapMs $CapMs -DataRoot $DataRoot -ExtraEnv $extraEnv -Killed ([ref]$killed)
    $sw.Stop()
    $elapsedMs = [int]$sw.Elapsed.TotalMilliseconds

    $findings = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $log) {
        foreach ($entry in @(Get-Content -LiteralPath $log)) {
            if ([string]::IsNullOrWhiteSpace($entry)) { continue }
            $o = $null
            try { $o = $entry | ConvertFrom-Json } catch { $o = $null }
            if ($null -eq $o) { continue }
            [void]$findings.Add([pscustomobject]@{
                file     = $full
                ruleId   = [string](Get-Prop $o 'ruleId')
                source   = [string](Get-Prop $o 'source')
                severity = [string](Get-Prop $o 'severity')
                line     = [int](Get-Prop $o 'line')
                col      = [int](Get-Prop $o 'col')
                message  = [string](Get-Prop $o 'message')
            })
        }
        try { Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue } catch { }
    }
    # Never-silent: a file is "analyzed" only with POSITIVE evidence the analysis reached a verdict.
    # It did NOT in two cases: (1) the client cap KILLED the process (dispatch 000132 leg 1) -- an
    # empty stdout that must not read as clean; or (2) a 'NOT checked' banner (the daemon per-file
    # budget was exhausted). Either way the file is NOT analyzed, so the caller drops it into
    # $notAnalyzed -- it is NAMED by 000131 and the scan exits 4 -- never reporting a killed or
    # degraded file as a clean one.
    $analyzed = $true
    if ($killed) {
        $analyzed = $false
    } elseif (-not [string]::IsNullOrWhiteSpace($stdout) -and $stdout -match 'NOT checked') {
        $analyzed = $false
    }
    return [pscustomobject]@{
        File      = $full
        Findings  = @(@($findings) | Where-Object { $null -ne $_ })
        Analyzed  = $analyzed
        ElapsedMs = $elapsedMs
    }
}
