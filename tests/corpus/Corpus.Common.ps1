#Requires -Version 5.1

# Corpus.Common.ps1 -- shared derivation helpers for the diagnostic-correctness
# corpus (dispatch 000040). Dot-sourced by BOTH the snapshot generator
# (Update-CorpusSnapshots.ps1) and the corpus test (PowerShellLsp.Corpus.Tests.ps1)
# so the two derive a sample's findings the EXACT same way -- the invariant that
# makes the corpus a real regression guard rather than two drifting code paths.
#
# THE ONE HARD INVARIANT (dispatch 000040): a corpus expected-finding is NEVER
# hand-authored or model-authored. Every expected finding is DERIVED by running the
# REAL tool (the warm PSES daemon + PScriptAnalyzer, or the in-process parser
# pre-pass) over the sample and reading what it actually emits. The derivation
# channel here is the tool's OWN dogfood capture log (dispatch 000039): we redirect
# POWERSHELL_LSP_DOGFOOD_LOG to a throwaway file, run the real lsp-client.ps1 hook,
# and read back the structured records it tees (ruleId / source / severity / line /
# col / message). The committed snapshot is whatever that run produced; the test
# re-derives the same way and asserts the live tool still matches. A hand-edited
# snapshot cannot make the test pass -- it would simply disagree with the real tool.
#
# Defines functions only; no side effects on import. ASCII-only (PS 5.1 em-dash trap).

$script:CorpusCommonDir = $PSScriptRoot
$script:CorpusTestsDir = Split-Path -Parent $script:CorpusCommonDir
$script:CorpusPluginRoot = Split-Path -Parent $script:CorpusTestsDir
$script:CorpusScriptsDir = Join-Path $script:CorpusPluginRoot 'scripts'

# Add-ProcessArguments (cross-version arg quoting) and friends.
. (Join-Path $script:CorpusScriptsDir 'lib/lsp-common.ps1')

function Get-CorpusPaths {
    # Resolve every well-known corpus path from this file's location, so the helper
    # works identically from the test runner and from a hand-run of the generator.
    return [pscustomobject]@{
        Root        = $script:CorpusCommonDir
        PluginRoot  = $script:CorpusPluginRoot
        ScriptsDir  = $script:CorpusScriptsDir
        CleanDir    = (Join-Path $script:CorpusCommonDir 'samples/clean')
        BadDir      = (Join-Path $script:CorpusCommonDir 'samples/bad')
        ParserDir   = (Join-Path $script:CorpusCommonDir 'parser-samples')
        ExpectedDir = (Join-Path $script:CorpusCommonDir 'expected')
    }
}

function Get-CorpusSampleSpec {
    # Enumerate every corpus sample as a flat spec the generator and the test both
    # iterate. Category drives only the expected/<category>/ subdir and the human
    # label; the DERIVATION is identical for all (lsp-client decides parser-pre-pass
    # vs warm-daemon internally, by whether the sample parses). 'parser' samples are
    # stored as .txt (NOT .ps1) so the repo-wide "every shipped .ps1 parses" guard in
    # the unit suite skips them -- a deliberately unparseable .ps1 would fail it.
    $p = Get-CorpusPaths
    $specs = @()
    $sources = @(
        @{ Category = 'clean';  Dir = $p.CleanDir;  Filter = '*.ps1' },
        @{ Category = 'bad';    Dir = $p.BadDir;    Filter = '*.ps1' },
        @{ Category = 'parser'; Dir = $p.ParserDir; Filter = '*.txt' }
    )
    foreach ($s in $sources) {
        if (-not (Test-Path -LiteralPath $s.Dir)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $s.Dir -Filter $s.Filter -File | Sort-Object Name)) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
            # Hashtables (not PSCustomObjects): Pester 5 -ForEach exposes each key as a
            # named variable inside the test; dot access ($spec.Label) still works for the
            # generator's foreach. One spec shape, used by both call sites.
            $specs += @{
                Category     = $s.Category
                Name         = $base
                Label        = ($s.Category + '/' + $base)
                SourcePath   = $f.FullName
                ExpectedPath = (Join-Path (Join-Path $p.ExpectedDir $s.Category) ($base + '.json'))
                ScratchName  = ($s.Category + '__' + $base)
            }
        }
    }
    return $specs
}

function Invoke-CorpusHook {
    # Spawn a plugin hook (session-start.ps1 / lsp-client.ps1) under pwsh with the
    # given stdin + env, returning its stdout. Mirrors the integration suite's proven
    # Invoke-PluginHook: pwsh is the analysis host on EVERY leg (named pipes map to
    # Unix domain sockets on .NET), even when the test FILE is interpreted by Windows
    # PowerShell 5.1 -- so derived findings are host-consistent across the CI matrix.
    param(
        [string]$ScriptPath,
        [string]$StdinJson,
        [int]$CapMs,
        [string]$DataRoot,
        [string[]]$ExtraArgs = @(),
        [hashtable]$ExtraEnv
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'pwsh'; $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    Add-ProcessArguments $psi (@(@('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + @($ExtraArgs)) | Where-Object { $_ })
    $psi.EnvironmentVariables['CLAUDE_PLUGIN_DATA'] = $DataRoot
    if ($ExtraEnv) { foreach ($k in $ExtraEnv.Keys) { $psi.EnvironmentVariables[$k] = [string]$ExtraEnv[$k] } }
    $p = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $p.StandardOutput.ReadToEndAsync()
    if ($StdinJson) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($StdinJson)   # no BOM
        $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $p.StandardInput.BaseStream.Flush()
    }
    $p.StandardInput.Close()
    if (-not $p.WaitForExit($CapMs)) { try { $p.Kill($true) } catch { }; return '' }
    [void]$stdoutTask.Wait(1500)
    if ($stdoutTask.IsCompleted) { return $stdoutTask.Result } else { return '' }
}

function Start-CorpusDaemon {
    # Bring up ONE warm daemon for the whole corpus run via the REAL SessionStart hook.
    # Launched with perFileCap=0 (capture every finding, never an "and N more" elision)
    # and severityThreshold=Hint (keep all severities) so the derived set is the tool's
    # full, faithful output. Returns the daemon details object (or $null on timeout).
    param([string]$ScriptsDir, [string]$DataRoot, [string]$SessionId)
    New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null
    Invoke-CorpusHook -ScriptPath (Join-Path $ScriptsDir 'session-start.ps1') `
        -StdinJson (@{ session_id = $SessionId } | ConvertTo-Json -Compress) `
        -ExtraArgs @('-PreferredHost', 'pwsh') -CapMs 60000 -DataRoot $DataRoot `
        -ExtraEnv @{ CLAUDE_PLUGIN_OPTION_perFileCap = '0'; CLAUDE_PLUGIN_OPTION_severityThreshold = 'Hint' } | Out-Null
    $sf = Join-Path $DataRoot ('session/' + $SessionId + '.json')
    for ($i = 0; $i -lt 80; $i++) {
        if (Test-Path -LiteralPath $sf) {
            $o = Get-Content -LiteralPath $sf -Raw | ConvertFrom-Json
            if ($o.state -eq 'ready') { return $o }
        }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

function Stop-CorpusDaemon {
    param([string]$ScriptsDir, [string]$DataRoot, [string]$SessionId, $DaemonInfo)
    try {
        Invoke-CorpusHook -ScriptPath (Join-Path $ScriptsDir 'session-end.ps1') `
            -StdinJson (@{ session_id = $SessionId } | ConvertTo-Json -Compress) `
            -ExtraArgs @() -CapMs 8000 -DataRoot $DataRoot | Out-Null
    } catch { }
    if ($null -ne $DaemonInfo) {
        foreach ($pidVal in @($DaemonInfo.pid, $DaemonInfo.psesPid)) {
            if ($pidVal) { Stop-Process -Id $pidVal -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Invoke-CorpusDerivation {
    # Derive the REAL tool's findings for ONE sample. Materializes the sample content
    # to a scratch .ps1 (so a .txt parser sample is actually analyzed, and so the
    # analysis is hermetic -- cwd = the scratch dir, which holds no
    # PSScriptAnalyzerSettings.psd1, so the default ruleset always applies), runs the
    # real lsp-client.ps1 with the dogfood log redirected to a throwaway file and
    # whole-file scoping, then reads back the structured records the tool teed. Returns
    # an array of finding objects { ruleId; source; severity; line; col; message }.
    param(
        [string]$ScriptsDir,
        [string]$DataRoot,
        [string]$SessionId,
        [string]$ScratchDir,
        [string]$ScratchName,
        [string]$Content,
        [int]$CapMs = 25000
    )
    if (-not (Test-Path -LiteralPath $ScratchDir)) { New-Item -ItemType Directory -Force -Path $ScratchDir | Out-Null }
    $scriptPath = Join-Path $ScratchDir ($ScratchName + '.ps1')
    [System.IO.File]::WriteAllText($scriptPath, $Content, (New-Object System.Text.ASCIIEncoding))
    $log = Join-Path $ScratchDir ($ScratchName + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.jsonl')

    $stdin = (@{ session_id = $SessionId; tool_input = @{ file_path = $scriptPath }; cwd = $ScratchDir } | ConvertTo-Json -Compress)
    # scopeToEdit=false => whole-file (a bare diagnostics request carries no edit patch
    # and already fails open to whole-file, but we set it explicitly); timeoutMs raised
    # so a first cold analysis on a slow CI leg still settles inside the client cap.
    $extraEnv = @{
        POWERSHELL_LSP_DOGFOOD_LOG       = $log
        CLAUDE_PLUGIN_OPTION_scopeToEdit = 'false'
        CLAUDE_PLUGIN_OPTION_timeoutMs   = '18000'
    }
    Invoke-CorpusHook -ScriptPath (Join-Path $ScriptsDir 'lsp-client.ps1') `
        -StdinJson $stdin -CapMs $CapMs -DataRoot $DataRoot -ExtraEnv $extraEnv | Out-Null

    $findings = @()
    if (Test-Path -LiteralPath $log) {
        foreach ($entry in @(Get-Content -LiteralPath $log)) {
            if ([string]::IsNullOrWhiteSpace($entry)) { continue }
            $o = $entry | ConvertFrom-Json
            $findings += [pscustomobject]@{
                ruleId   = [string]$o.ruleId
                source   = [string]$o.source
                severity = [string]$o.severity
                line     = [int]$o.line
                col      = [int]$o.col
                message  = [string]$o.message
            }
        }
    }
    # Filter nulls so an empty set never leaks a spurious all-empty finding through
    # the empty-array -> $null collapse on return/param-binding (PS quirk).
    return @(@($findings) | Where-Object { $null -ne $_ })
}

function Get-CorpusCanonicalString {
    # A stable, order-independent, host-independent serialization of a finding set used
    # for BOTH snapshotting and comparison. Sorting the per-finding lines means capture
    # order never matters; the pipe-joined fields are plain strings/ints so Windows
    # PowerShell 5.1 and pwsh 7 produce byte-identical output (no ConvertTo-Json
    # whitespace/ordering drift across hosts). Empty set -> empty string.
    param([object[]]$Findings)
    $real = @($Findings | Where-Object { $null -ne $_ })
    if ($real.Count -eq 0) { return '' }
    $lines = @($real | ForEach-Object {
            ('{0}|{1}|{2}|{3}|{4}|{5}' -f [string]$_.ruleId, [string]$_.source, [string]$_.severity, [int]$_.line, [int]$_.col, [string]$_.message)
        } | Sort-Object)
    return ($lines -join "`n")
}

function Format-CorpusSnapshotJson {
    # Render a finding set as a pretty JSON ARRAY for the committed snapshot file
    # (human-reviewable). Forces an array even for zero or one finding (PS 5.1
    # ConvertTo-Json unwraps a single-element array). Storage only -- the test compares
    # via Get-CorpusCanonicalString, not by JSON string equality.
    param([object[]]$Findings)
    $arr = @($Findings | Where-Object { $null -ne $_ })
    if ($arr.Count -eq 0) { return '[]' }
    $objs = @($arr | ForEach-Object {
            [ordered]@{
                ruleId = [string]$_.ruleId; source = [string]$_.source; severity = [string]$_.severity
                line = [int]$_.line; col = [int]$_.col; message = [string]$_.message
            }
        })
    if ($objs.Count -eq 1) { return ('[' + ($objs[0] | ConvertTo-Json -Depth 5) + ']') }
    return ($objs | ConvertTo-Json -Depth 5)
}

function Import-CorpusSnapshot {
    # Read a committed snapshot file into an array of finding objects (tolerating the
    # single-object unwrap and an absent/empty file). Returns @() for an empty corpus
    # entry (a clean sample's "[]").
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $raw = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    $parsed = $raw | ConvertFrom-Json
    return @(@($parsed) | Where-Object { $null -ne $_ })
}
