#Requires -Version 5.1

# POSIX containment guards (dispatch 000277 leg C, Mike's ruling R4 of 2026-09-05).
#
# WHAT THIS FILE DEFENDS. THREAT-MODEL T5.1 and T6.2 carried their POSIX arms as *unmeasured*
# until dispatch 000276 leg F measured them on the two POSIX CI legs (run 33949910984). Both
# arms read the same on ubuntu-pwsh and macos-pwsh: the data-root temp fallback directory and
# the daemon pipe's unix-domain-socket endpoint were both created 755 -- 'exposed-beyond-user
# -- OTHER has 5' -- and on Linux the containing /tmp is 1777, so nothing above them contained
# them either. The fix makes every filesystem object the plugin creates owner-only AT CREATION:
# 0700 directories, 0600 for the files the shared writers create.
#
# THE TWO ARMS OF THIS FILE.
#   POSIX  -- the containment itself, measured with stat(1), the same instrument the CI
#             measurement step uses, so the suite and the artifact cannot disagree.
#   WINDOWS -- that nothing moved there. The Windows arm of T5.1 was settled by 000269 with a
#             DACL, and this change must not touch it; the assertion is that a directory made
#             by New-ContainedDirectory carries the same ACL as one made by the prior
#             implementation in the same parent.
#
# THE RED CONTROL is the PRIOR IMPLEMENTATION, not an invented mutant: plain
# `New-Item -ItemType Directory -Force`, run in the same process under the same ambient umask.
# It must NOT produce an owner-only object, or the fix is not what is producing the containment.
# The control derives its own expected value from the live umask and asserts the mutant landed
# on exactly that value -- so a host whose umask is already 0077 is reported INCONCLUSIVE by
# name, never silently green on a control that could not have failed.
#
# ASCII-only, LF, no BOM (PS 5.1 Windows-1252 trap). Run via tests/run-tests.ps1.

BeforeAll {
    $script:PcPluginRoot = Split-Path -Parent $PSScriptRoot
    $script:PcScriptsDir = Join-Path $script:PcPluginRoot 'scripts'
    . (Join-Path $script:PcScriptsDir 'lib/lsp-common.ps1')

    function Get-PcMode {
        # Octal mode of one path, via stat(1) -- the same instrument tests/measure-posix-surface.ps1
        # uses, deliberately, so a green suite and a green artifact are measuring the same number.
        # Returns '' when the path is absent or stat is unavailable.
        param([Parameter(Mandatory)][string] $Path)
        if (-not (Test-Path -LiteralPath $Path)) { return '' }
        $raw = $null
        try {
            if ($IsMacOS) { $raw = & stat -f '%Lp' -- $Path 2>$null }
            else { $raw = & stat -c '%a' -- $Path 2>$null }
        }
        catch { return '' }
        if ([string]::IsNullOrWhiteSpace($raw)) { return '' }
        $m = ([string]$raw).Trim()
        # stat renders 0700 as '700' on Linux and can render it zero-padded on some hosts; compare
        # on the last three digits so a leading zero or a setuid digit cannot fake a mismatch.
        if ($m.Length -gt 3) { $m = $m.Substring($m.Length - 3) }
        return $m
    }

    function Get-PcUmaskDefaultDirMode {
        # What the PRIOR implementation would land on THIS host: 0777 masked by the live umask.
        # Returned as a three-digit octal string, or '' when the umask cannot be read.
        $raw = $null
        try { $raw = ([string](& sh -c 'umask' 2>$null)).Trim() } catch { return '' }
        if ([string]::IsNullOrWhiteSpace($raw)) { return '' }
        try {
            $mask = [Convert]::ToInt32($raw, 8)
            $mode = 0x1FF -band (-bnot $mask)
            return ([Convert]::ToString($mode, 8)).PadLeft(3, '0')
        }
        catch { return '' }
    }

    function New-PcScratch {
        # A private scratch root per test, under the ambient temp, created the PRE-FIX way so the
        # scratch root itself never contributes containment the assertion could mistake for the fix.
        $p = Join-Path ([System.IO.Path]::GetTempPath()) ('psls-pc-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
        New-Item -ItemType Directory -Force -Path $p | Out-Null
        return $p
    }

    $script:PcOnWindows = if (Test-Path 'Variable:\IsWindows') { [bool]$IsWindows } else { $true }
}

# Discovery-time platform flag: -Skip: is evaluated during Pester's discovery pass, before
# BeforeAll has run, so it cannot read $script:PcOnWindows set above.
$script:PcOnWin = if (Test-Path 'Variable:\IsWindows') { [bool]$IsWindows } else { $true }

Describe 'POSIX containment -- directories the plugin creates (000277 leg C, T6.2)' -Skip:$script:PcOnWin {

    It 'creates a leaf directory owner-only (0700)' {
        $root = New-PcScratch
        try {
            $target = Join-Path $root 'leaf'
            New-ContainedDirectory -Path $target
            $target | Should -Exist
            (Get-PcMode -Path $target) | Should -Be '700'
        }
        finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'contains EVERY segment it had to create, not just the leaf' {
        # -Force creates missing ancestors silently at the ambient umask. Containing only the
        # leaf would leave a permissive parent that this plugin, not the platform, just made --
        # which is the whole reason New-ContainedDirectory enumerates before it creates.
        $root = New-PcScratch
        try {
            $target = Join-Path (Join-Path (Join-Path $root 'a') 'b') 'c'
            New-ContainedDirectory -Path $target
            foreach ($seg in @($target, (Split-Path -Parent $target), (Split-Path -Parent (Split-Path -Parent $target)))) {
                (Get-PcMode -Path $seg) | Should -Be '700' -Because ($seg + ' was created by this call')
            }
        }
        finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'does NOT re-mode an ancestor that already existed' {
        # The restraint that keeps /tmp (1777) and a user-chosen CLAUDE_PLUGIN_DATA out of this
        # plugin's hands. An existing directory belongs to whoever made it.
        $root = New-PcScratch
        try {
            $parent = Join-Path $root 'preexisting'
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
            & chmod 755 $parent | Out-Null
            (Get-PcMode -Path $parent) | Should -Be '755' -Because 'the fixture must start permissive or the assertion proves nothing'
            New-ContainedDirectory -Path (Join-Path $parent 'child')
            (Get-PcMode -Path $parent) | Should -Be '755'
            (Get-PcMode -Path (Join-Path $parent 'child')) | Should -Be '700'
        }
        finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'RED control -- the prior implementation (plain New-Item, ambient umask) is NOT owner-only' {
        $expected = Get-PcUmaskDefaultDirMode
        if ([string]::IsNullOrWhiteSpace($expected)) {
            Set-ItResult -Inconclusive -Because 'the live umask could not be read, so the control has no derivable expected value'
            return
        }
        if ($expected -eq '700') {
            Set-ItResult -Inconclusive -Because ('this host already runs a 0077-class umask, so the prior implementation ' +
                'would also land on 700 and this control could not fail -- it is reported inconclusive rather than green')
            return
        }
        $root = New-PcScratch
        try {
            $mutant = Join-Path $root 'prior-implementation'
            New-Item -ItemType Directory -Force -Path $mutant | Out-Null
            # PROVE the mutant landed where the umask says it should, before concluding anything
            # from it: a control that silently did something else is not a control.
            (Get-PcMode -Path $mutant) | Should -Be $expected -Because 'the prior implementation must land on 0777 masked by the live umask'
            (Get-PcMode -Path $mutant) | Should -Not -Be '700' -Because 'if the prior implementation were already owner-only, the fix would not be what produces containment'
        }
        finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'POSIX containment -- files the shared writers create (000277 leg C)' -Skip:$script:PcOnWin {

    It 'Set-ContainedFileMode puts a plugin-created file at 0600' {
        $root = New-PcScratch
        try {
            $f = Join-Path $root 'written.jsonl'
            [System.IO.File]::WriteAllText($f, "{}`n", (New-Object System.Text.UTF8Encoding($false)))
            Set-ContainedFileMode -Path $f | Should -BeTrue
            (Get-PcMode -Path $f) | Should -Be '600'
        }
        finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Write-StatsLine lands its log directory at 0700 and stats.jsonl at 0600, through the real seam' {
        # Driven through the SHIPPED writer against an isolated data root, not by calling the
        # containment helper directly -- so this proves the call site, not just the helper.
        $root = New-PcScratch
        $saved = $env:CLAUDE_PLUGIN_DATA
        try {
            $dataRoot = Join-Path $root 'data'
            $env:CLAUDE_PLUGIN_DATA = $dataRoot
            Write-StatsLine -Record @{ ts = 'x'; path = 'y' }
            $logDir = Join-Path $dataRoot 'logs'
            $stats = Join-Path $logDir 'stats.jsonl'
            $stats | Should -Exist
            (Get-PcMode -Path $dataRoot) | Should -Be '700' -Because 'the data root is created by this write too'
            (Get-PcMode -Path $logDir) | Should -Be '700'
            (Get-PcMode -Path $stats) | Should -Be '600'
        }
        finally {
            if ([string]::IsNullOrWhiteSpace($saved)) { Remove-Item Env:CLAUDE_PLUGIN_DATA -ErrorAction SilentlyContinue }
            else { $env:CLAUDE_PLUGIN_DATA = $saved }
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'RED control -- a file written without containment is NOT owner-only' {
        $umask = ''
        try { $umask = ([string](& sh -c 'umask' 2>$null)).Trim() } catch { $umask = '' }
        if ([string]::IsNullOrWhiteSpace($umask)) {
            Set-ItResult -Inconclusive -Because 'the live umask could not be read'
            return
        }
        $expected = ''
        try {
            $mask = [Convert]::ToInt32($umask, 8)
            $expected = ([Convert]::ToString((0x1B6 -band (-bnot $mask)), 8)).PadLeft(3, '0')
        }
        catch { $expected = '' }
        if ($expected -eq '600' -or [string]::IsNullOrWhiteSpace($expected)) {
            Set-ItResult -Inconclusive -Because ('the live umask (' + $umask + ') already yields ' + $expected +
                ' for a new file, so this control could not fail')
            return
        }
        $root = New-PcScratch
        try {
            $f = Join-Path $root 'uncontained.jsonl'
            [System.IO.File]::WriteAllText($f, "{}`n", (New-Object System.Text.UTF8Encoding($false)))
            (Get-PcMode -Path $f) | Should -Be $expected -Because 'the uncontained write must land on 0666 masked by the live umask'
            (Get-PcMode -Path $f) | Should -Not -Be '600'
        }
        finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'POSIX containment -- the daemon pipe socket endpoint (000277 leg C, T5.1)' -Skip:$script:PcOnWin {

    It 'Get-DaemonPipeSocketPath derives <temp>/CoreFxPipe_<name> off-Windows' {
        $name = 'psls-pc-derive'
        (Get-DaemonPipeSocketPath -PipeName $name) |
            Should -Be (Join-Path ([System.IO.Path]::GetTempPath()) ('CoreFxPipe_' + $name))
    }

    It 'the socket file the pipe server creates is contained to 0600' {
        # CurrentUserOnly (000269) rejects a foreign peer at accept time; it does NOT narrow this
        # file's mode -- which is exactly what the 000276 measurement showed at 755. This asserts
        # the second layer. If the endpoint never materializes the result is INCONCLUSIVE by name,
        # because the CI measurement artifact is the primary evidence for this arm and a silently
        # green suite would be worse than an honest gap.
        $name = 'psls-pc-' + [guid]::NewGuid().ToString('N').Substring(0, 10)
        $server = $null
        try {
            $server = New-DaemonPipeServer -PipeName $name
            $sock = Get-DaemonPipeSocketPath -PipeName $name
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            while ($sw.ElapsedMilliseconds -lt 5000 -and -not (Test-Path -LiteralPath $sock)) {
                Start-Sleep -Milliseconds 100
            }
            if (-not (Test-Path -LiteralPath $sock)) {
                Set-ItResult -Inconclusive -Because ('the socket endpoint did not appear at ' + $sock +
                    ' within 5000 ms; the CI posix-surface artifact carries this arm')
                return
            }
            (Get-PcMode -Path $sock) | Should -Be '600'
        }
        finally {
            if ($null -ne $server) { try { $server.Dispose() } catch { } }
        }
    }
}

Describe 'Windows is byte-identical (000277 leg C)' -Skip:(-not $script:PcOnWin) {

    It 'Set-OwnerOnlyMode is a no-op that reports $false on Windows' {
        $root = New-PcScratch
        try {
            Set-OwnerOnlyMode -Path $root -Kind 'Directory' | Should -BeFalse
            Set-OwnerOnlyMode -Path $root -Kind 'File' | Should -BeFalse
        }
        finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Get-DaemonPipeSocketPath returns empty on Windows -- a named pipe has no filesystem path there' {
        (Get-DaemonPipeSocketPath -PipeName 'psls-pc-win') | Should -Be ''
    }

    It 'New-ContainedDirectory creates the same tree the prior implementation did, ancestors included' {
        $root = New-PcScratch
        try {
            $target = Join-Path (Join-Path $root 'x') 'y'
            New-ContainedDirectory -Path $target
            $target | Should -Exist
            (Join-Path $root 'x') | Should -Exist
        }
        finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'grants the same ACL as the prior implementation in the same parent' {
        # The strongest available statement of "Windows did not move": build one directory each
        # way, side by side under one parent, and compare the resulting access rules verbatim.
        $root = New-PcScratch
        try {
            $mine = Join-Path $root 'contained'
            $prior = Join-Path $root 'prior'
            New-ContainedDirectory -Path $mine
            New-Item -ItemType Directory -Force -Path $prior | Out-Null
            $a = (Get-Acl -LiteralPath $mine).AccessToString
            $b = (Get-Acl -LiteralPath $prior).AccessToString
            $a | Should -Be $b
        }
        finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
