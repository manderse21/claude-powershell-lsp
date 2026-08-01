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
        PrePssaDir  = (Join-Path $script:CorpusCommonDir 'samples/pre-pssa')
        CompatDir   = (Join-Path $script:CorpusCommonDir 'samples/compat')
        BashismDir  = (Join-Path $script:CorpusCommonDir 'samples/bashism')
        ModuleDir   = (Join-Path $script:CorpusCommonDir 'samples/module')
        ExpectedDir = (Join-Path $script:CorpusCommonDir 'expected')
    }
}

<#
KNOWN CORPUS LIMIT -- the DSC `Configuration` shape is UNREACHABLE here (dispatch 000172).

Dispatch 000171 leg 3 added three DSC fixtures. Two used the `Configuration` KEYWORD and were
removed by 000172; clean-dsc-class-resource.ps1 stays, because [DscResource()] is an ATTRIBUTE on
a class and parses anywhere.

MEASURED, on both hosts, rather than assumed (000172 leg 2):

    fixture                             WPS 5.1 (Win)   pwsh 7.6.3 (Win)   pwsh (ubuntu/macOS CI)
    clean-dsc-configuration.ps1         0 errors        0 errors           3 errors
    PSAvoidUsingCmdletAliases.dsc.ps1   0 errors        0 errors           3 errors
    clean-dsc-class-resource.ps1        0 errors        0 errors           0 errors

The discriminator is the PLATFORM, not the host. `Configuration` is a dynamic keyword the parser
can only bind when PSDesiredStateConfiguration is discoverable. On Windows it is discoverable from
BOTH hosts -- pwsh 7 finds the inbox Windows PowerShell module through its compatibility entries in
$env:PSModulePath, and `Get-Command Configuration` there resolves to a Function sourced from
PSDesiredStateConfiguration. On Linux and macOS there is no DSC at all, so the parser cannot bind
the keyword and the file yields parse errors.

That is why the two removed fixtures were RED on ubuntu-pwsh and macos-pwsh but GREEN on BOTH
Windows legs -- a 2-of-4 split, not the 4-of-4 a pwsh-vs-5.1 story would predict.

A corpus sample must derive IDENTICALLY on every scoring leg, or the published false-positive and
true-positive denominators become platform-dependent. A Windows-only fixture is therefore worse
than an absent one. Covering the `Configuration` shape needs a second, Windows-only execution host
for the corpus -- a design change, deliberately NOT chartered in 000172. Recorded, not solved.
#>
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
        @{ Category = 'clean';  Dir = $p.CleanDir;  Filter = '*.txt' },
        @{ Category = 'bad';    Dir = $p.BadDir;    Filter = '*.ps1' },
        @{ Category = 'parser'; Dir = $p.ParserDir; Filter = '*.txt' },
        @{ Category = 'pre-pssa'; Dir = $p.PrePssaDir; Filter = '*.txt' },
        @{ Category = 'compat'; Dir = $p.CompatDir; Filter = '*.txt' },
        @{ Category = 'bashism'; Dir = $p.BashismDir; Filter = '*.txt' }
    )
    <#
    Multi-file module fixtures (PL-6, dispatch 000062): each fixture is a DIRECTORY
    containing a .psd1 manifest and a .psm1 root module (and optionally function .ps1
    files). The SourcePath points to the .psd1; the derivation copies the ENTIRE module
    directory to scratch so the daemon's module surface cache can walk up and find the
    .psm1. The expected snapshot records the ManifestConsistency findings or empty for
    indeterminate/consistent cases.
    #>
    $moduleDir = $p.ModuleDir
    if (Test-Path -LiteralPath $moduleDir) {
        foreach ($sub in (Get-ChildItem -LiteralPath $moduleDir -Directory | Sort-Object Name)) {
            $psd1 = Get-ChildItem -LiteralPath $sub.FullName -Filter '*.psd1' -File | Select-Object -First 1
            if ($null -eq $psd1) { continue }
            $base = $sub.Name
            $specs += @{
                Category     = 'module'
                Name         = $base
                RuleId       = 'ManifestConsistency'
                Label        = ('module/' + $base)
                SourcePath   = $psd1.FullName
                ExpectedPath = (Join-Path (Join-Path $p.ExpectedDir 'module') ($base + '.json'))
                ScratchName  = ('module__' + $base)
                ModuleDir    = $sub.FullName    # the directory to copy to scratch
            }
        }
    }
    foreach ($s in $sources) {
        if (-not (Test-Path -LiteralPath $s.Dir)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $s.Dir -Filter $s.Filter -File | Sort-Object Name)) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
            # RuleId -- the EXPECTED PSScriptAnalyzer rule a known-bad sample must surface,
            # decoupled from the filename so MORE THAN ONE case can exist per rule (dispatch
            # 000046). PSES surfaces a NARROW default rule set on the fly (6 rules, measured),
            # so a one-rule-per-file scheme cannot reach a meaningful known-bad count; instead
            # a 'bad' file is named <RuleId>.<variant>.ps1 (e.g. PSUseApprovedVerbs.wibble.ps1)
            # and the expected rule is the FIRST dot-segment of the base. A legacy single-segment
            # name (PSUseApprovedVerbs.ps1) yields RuleId == base unchanged, so existing samples
            # keep working. Only 'bad' uses RuleId; 'clean'/'parser' carry the base for symmetry.
            $ruleId = if ($s.Category -eq 'bad' -or $s.Category -eq 'pre-pssa' -or $s.Category -eq 'compat' -or $s.Category -eq 'bashism') { ($base -split '\.')[0] } else { $base }
            # Hashtables (not PSCustomObjects): Pester 5 -ForEach exposes each key as a
            # named variable inside the test; dot access ($spec.Label) still works for the
            # generator's foreach. One spec shape, used by both call sites.
            $specs += @{
                Category     = $s.Category
                Name         = $base
                RuleId       = $ruleId
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
    #
    # For multi-file MODULE fixtures (PL-6, dispatch 000062), pass an optional $ModuleDir
    # -- the ENTIRE directory is copied to scratch (preserving .psd1 + .psm1 structure)
    # and the analysis runs on the .psd1 within it.
    param(
        [string]$ScriptsDir,
        [string]$DataRoot,
        [string]$SessionId,
        [string]$ScratchDir,
        [string]$ScratchName,
        [byte[]]$Bytes,
        [int]$CapMs = 25000,
        [string]$ModuleDir = ''       # optional: copy entire module dir to scratch
    )
    if (-not (Test-Path -LiteralPath $ScratchDir)) { New-Item -ItemType Directory -Force -Path $ScratchDir | Out-Null }
    $scratchNameBase = $ScratchName
    if (-not [string]::IsNullOrWhiteSpace($ModuleDir) -and (Test-Path -LiteralPath $ModuleDir)) {
        # Multi-file module fixture: copy the entire directory to scratch.
        $moduleScratch = Join-Path $ScratchDir $scratchNameBase
        New-Item -ItemType Directory -Force -Path $moduleScratch | Out-Null
        Get-ChildItem -LiteralPath $ModuleDir -File | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $moduleScratch $_.Name) -Force
        }
        $scriptPath = Join-Path $moduleScratch ($scratchNameBase + '.psd1')
        # Overwrite the .psd1 with the exact bytes (preserves encoding).
        [System.IO.File]::WriteAllBytes($scriptPath, $Bytes)
    } else {
        $scriptPath = Join-Path $ScratchDir ($scratchNameBase + '.ps1')
        # Write the exact source bytes verbatim. Using raw bytes preserves BOM markers
        # and non-ASCII content that a text round-trip (ReadAllText/WriteAllText) would
        # strip or corrupt (dispatch 000060, Byte-order-mark regression).
        [System.IO.File]::WriteAllBytes($scriptPath, $Bytes)
    }
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
    #
    # DETERMINISTIC BY CONSTRUCTION (dispatch 000172, D3). The previous implementation was
    # HOST-DEPENDENT in two ways, and a re-run of the generator on a different host than the one
    # that committed a snapshot rewrote it with no content change at all -- measured at exactly
    # 17 files while working 000172, which is how 17 unrelated snapshots churned during 000171:
    #
    #   1. LINE ENDINGS. ConvertTo-Json -Depth N indents with [Environment]::NewLine, so it emits
    #      CRLF on Windows and LF on Linux/macOS. The generator then appended a hard "`n", so a
    #      Windows-written snapshot was a MIXED file (CRLF body, LF final byte).
    #   2. INDENTATION. The one-finding case wrapped a bare object in literal brackets, so its
    #      fields sat at 2 spaces and the object braces at column 0, while the multi-finding case
    #      produced a real array with the object braces at 2 and its fields at 4. Two shapes for
    #      what is the same document structure.
    #
    # Both are removed here: every object is serialized on its own, its endings normalized to LF,
    # and it is indented into the array by hand. One shape for one finding and for many, byte
    # identical on every host.
    param([object[]]$Findings)
    $arr = @($Findings | Where-Object { $null -ne $_ })
    if ($arr.Count -eq 0) { return '[]' }
    $items = @($arr | ForEach-Object {
            $obj = [ordered]@{
                ruleId = [string]$_.ruleId; source = [string]$_.source; severity = [string]$_.severity
                line = [int]$_.line; col = [int]$_.col; message = [string]$_.message
            }
            $json = ($obj | ConvertTo-Json -Depth 5) -replace "`r`n", "`n"
            (@($json -split "`n") | ForEach-Object { '  ' + $_ }) -join "`n"
        })
    return ("[`n" + ($items -join ",`n") + "`n]")
}

function Get-CorpusSnapshotText {
    # The EXACT text of a committed snapshot file: the rendered JSON plus its single trailing
    # newline. One definition, so the generator and its idempotence test cannot disagree about
    # what "the file contents" means.
    param([object[]]$Findings)
    return ((Format-CorpusSnapshotJson -Findings $Findings) + "`n")
}

function Test-CorpusSnapshotCurrent {
    # Does the committed file already record EXACTLY these findings? Compared by CANONICAL
    # CONTENT (Get-CorpusCanonicalString), NOT by bytes (dispatch 000172, D3).
    #
    # WHY CONTENT AND NOT BYTES: the corpus test asserts equality through
    # Get-CorpusCanonicalString, so a snapshot's byte form is genuinely not load-bearing -- only
    # the finding tuples are. A byte comparison therefore rewrites files whose MEANING is
    # unchanged the moment the serializer or the host differs, which is exactly the churn that
    # buried a real 000171 diff under 17 cosmetic ones. Content comparison makes "a re-run
    # against an unchanged tool changes no snapshot bytes" true rather than aspirational.
    #
    # KNOWN RESIDUE, recorded rather than papered over: snapshots committed BEFORE this fix keep
    # whatever endings their authoring host produced (47 carry Windows CRLF, measured at 000172).
    # They are content-correct and the corpus test passes on them; each converges to the
    # deterministic LF form the next time its CONTENT genuinely changes. Normalizing all of them
    # now would itself be the 47-file churn this function exists to prevent.
    param([string]$Path, [object[]]$Findings)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $committed = Import-CorpusSnapshot -Path $Path
    return ((Get-CorpusCanonicalString -Findings $committed) -ceq (Get-CorpusCanonicalString -Findings $Findings))
}

function Write-CorpusSnapshotFile {
    # Write a snapshot file: UTF-8 without BOM, LF endings, exactly Get-CorpusSnapshotText.
    # The ONE write path, so the idempotence test exercises what the generator actually runs.
    param([string]$Path, [object[]]$Findings)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, (Get-CorpusSnapshotText -Findings $Findings), $enc)
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

function Get-CorpusCorrectnessReport {
    # THE MEASURED CORRECTNESS REPORT (dispatch 000046, Gap A). Compute the tool's
    # diagnostic correctness numbers from a DERIVED corpus result set -- the same live
    # findings the snapshot test asserts, never hand-authored. PURE over injected data.
    #
    #   $Derived  : a hashtable  Label -> array of finding objects (the test's $script:Derived
    #               map, or the generator's per-sample derivation).
    #
    # Two measured numbers under the tool's DEFAULT config:
    #   falsePositiveRate  -- % of KNOWN-GOOD (clean) samples that WRONGLY produced any
    #                         finding. The headline trust number: clean code must stay silent.
    #   truePositiveRate   -- % of KNOWN-BAD samples whose EXPECTED rule (spec.RuleId) actually
    #                         surfaced. Coverage of the curated defect set.
    # Plus rulesCovered (the distinct expected rules a known-bad case proved) and
    # rulesExpected (every distinct expected rule in the corpus) so a caller can assert the
    # whole surfaced default set is exercised. Counts are plain ints; rates are 0..100.
    param([hashtable]$Derived)
    $specs = @(Get-CorpusSampleSpec)
    $clean = @($specs | Where-Object { $_.Category -eq 'clean' })
    $bad = @($specs | Where-Object { $_.Category -eq 'bad' })

    $fpCount = 0
    foreach ($s in $clean) {
        if (@($Derived[$s.Label]).Count -gt 0) { $fpCount++ }
    }

    $tpCount = 0
    $covered = @{}
    $expected = @{}
    foreach ($s in $bad) {
        $expected[$s.RuleId] = $true
        $ids = @(@($Derived[$s.Label]) | ForEach-Object { $_.ruleId })
        if ($ids -contains $s.RuleId) {
            $tpCount++
            $covered[$s.RuleId] = $true
        }
    }

    $cleanN = $clean.Count
    $badN = $bad.Count
    $fpRate = if ($cleanN -gt 0) { [math]::Round((100.0 * $fpCount / $cleanN), 2) } else { 0 }
    $tpRate = if ($badN -gt 0) { [math]::Round((100.0 * $tpCount / $badN), 2) } else { 0 }
    return [ordered]@{
        knownGood         = $cleanN
        knownBad          = $badN
        falsePositives    = $fpCount
        falsePositiveRate = $fpRate
        truePositives     = $tpCount
        truePositiveRate  = $tpRate
        rulesExpected     = @($expected.Keys | Sort-Object)
        rulesCovered      = @($covered.Keys | Sort-Object)
    }
}
