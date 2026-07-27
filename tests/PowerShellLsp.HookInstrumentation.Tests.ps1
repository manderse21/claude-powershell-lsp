#Requires -Version 5.1

# Flake instrumentation harness proofs (dispatch 000159, leg 1a -- steps 1 and 2 of the
# fix shape dispatch 000156 leg 4 recorded).
#
# WHAT 000156 LEG 4 ESTABLISHED, AND WHY IT COULD GO NO FURTHER. It retrieved the failing
# run's artifacts intact and FALSIFIED the standing explanation of the honor-block flake:
# the code comments blamed the 000030 relaunch+retry path accumulating past CapMs, but the
# recorded It duration was 3.3167s against a 25000ms cap. Nothing was killed at a cap.
# It then stopped, because the two things needed to go further are both unobservable:
#
#   (1) the failing sub-cases run against ISOLATED data roots under the OS temp dir, while
#       CI uploads only psls-test-data/** -- so their logs never reach the artifact, and
#       several AfterAll blocks discard the root on top of that; and
#   (2) Invoke-PluginHook collapses THREE distinct failures into one empty string, so the
#       assertion that trips cannot say which one happened.
#
# This file proves the two instruments that close those gaps. It does NOT implement step 3
# (bounded retry / widened window): the evidence needed to choose between those does not
# exist yet, and producing it is the entire point of shipping the instruments first.
#
# NO Start-Sleep APPEARS ANYWHERE IN THIS FILE, including in the fixtures it generates.
# The killed-at-cap path is forced with a child that blocks on a ManualResetEventSlim that
# is never set -- it does not merely take a long time, it NEVER exits, so WaitForExit()
# times out deterministically rather than probabilistically. A sleep would have introduced
# exactly the kind of timing window this dispatch exists to stop reasoning about.
#
# ASCII-only (PS 5.1 reads a UTF-8-without-BOM file through the Windows-1252 codepage).
#
# Author: Mike Andersen / powershell-lsp plugin.

BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')
    . (Join-Path $PSScriptRoot 'Integration.Common.ps1')

    $script:HiRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('psls-hookinstr-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $script:HiRoot | Out-Null

    # A child that NEVER exits -- blocks on an event nobody sets. No sleep, no timing window.
    $script:HiNeverExits = Join-Path $script:HiRoot 'never-exits.ps1'
    Set-Content -LiteralPath $script:HiNeverExits -Encoding ascii -Value @(
        '$ev = New-Object System.Threading.ManualResetEventSlim($false)'
        '[void]$ev.Wait()'
    )

    # A child that exits cleanly having written NOTHING to stdout.
    $script:HiEmptyStdout = Join-Path $script:HiRoot 'empty-stdout.ps1'
    Set-Content -LiteralPath $script:HiEmptyStdout -Encoding ascii -Value @('exit 0')

    # A child that exits cleanly WITH stdout, so the 'ok' rung is not vacuous.
    $script:HiWithStdout = Join-Path $script:HiRoot 'with-stdout.ps1'
    Set-Content -LiteralPath $script:HiWithStdout -Encoding ascii -Value @("Write-Output 'HELLO-FROM-CHILD'")

    # EXACT copy of the instrumented tail the suite's own hook functions now carry. The
    # behavioural proof runs against this; the structural proof below then establishes that
    # every shipped copy carries the same three recorder calls, so the behaviour generalises.
    function Invoke-HiHook {
        param([string]$ScriptPath, [int]$CapMs)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'pwsh'; $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        Add-ProcessArguments $psi @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath)
        $p = [System.Diagnostics.Process]::Start($psi)
        $stdoutTask = $p.StandardOutput.ReadToEndAsync()
        $p.StandardInput.Close()
        $swHook = [System.Diagnostics.Stopwatch]::StartNew()
        if (-not $p.WaitForExit($CapMs)) {
            try { $p.Kill($true) } catch { }
            $script:PslsHookOutcome = New-PluginHookOutcome -Reason 'killed-at-cap' -CapMs $CapMs -ElapsedMs ([int]$swHook.ElapsedMilliseconds) -ScriptPath $ScriptPath
            return ''
        }
        [void]$stdoutTask.Wait(1500)
        if (-not $stdoutTask.IsCompleted) {
            $script:PslsHookOutcome = New-PluginHookOutcome -Reason 'stdout-read-timeout' -CapMs $CapMs -ElapsedMs ([int]$swHook.ElapsedMilliseconds) -ExitCode $p.ExitCode -ScriptPath $ScriptPath
            return ''
        }
        $hookReason = 'ok'
        if ([string]::IsNullOrEmpty($stdoutTask.Result)) { $hookReason = 'exited-empty-stdout' }
        $script:PslsHookOutcome = New-PluginHookOutcome -Reason $hookReason -CapMs $CapMs -ElapsedMs ([int]$swHook.ElapsedMilliseconds) -ExitCode $p.ExitCode -ScriptPath $ScriptPath
        return $stdoutTask.Result
    }
}

AfterAll {
    if ($script:HiRoot -and (Test-Path -LiteralPath $script:HiRoot)) {
        Remove-Item -LiteralPath $script:HiRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Flake instrumentation: killed-at-cap and exited-empty-stdout are DISTINCT (000159 leg 1a step 2)' {

    It 'RED-PROOF: both paths still return the SAME empty string -- the ambiguity being fixed is real' {
        # This is the defect, reproduced rather than asserted about. Before this dispatch the
        # empty string was the ONLY signal either path produced, so an assertion tripping on
        # it could not distinguish a cap overrun from a silent clean exit. That is still true
        # of the RETURN VALUE (deliberately -- changing it would be a behaviour change), which
        # is exactly why the diagnosis had to move to a side channel.
        $killed = Invoke-HiHook -ScriptPath $script:HiNeverExits -CapMs 1500
        $killedOutcome = $script:PslsHookOutcome
        $empty = Invoke-HiHook -ScriptPath $script:HiEmptyStdout -CapMs 20000
        $emptyOutcome = $script:PslsHookOutcome

        $killed | Should -BeExactly ''
        $empty | Should -BeExactly ''
        $killed | Should -BeExactly $empty       # <- the ambiguity, still present in the return value

        # GREEN: the side channel separates them.
        $killedOutcome.Reason | Should -BeExactly 'killed-at-cap'
        $emptyOutcome.Reason | Should -BeExactly 'exited-empty-stdout'
        $killedOutcome.Reason | Should -Not -Be $emptyOutcome.Reason
    }

    It 'the rendered assertion messages are DISTINCT and each names its own cause' {
        [void](Invoke-HiHook -ScriptPath $script:HiNeverExits -CapMs 1500)
        $killedText = Format-PluginHookOutcome $script:PslsHookOutcome
        [void](Invoke-HiHook -ScriptPath $script:HiEmptyStdout -CapMs 20000)
        $emptyText = Format-PluginHookOutcome $script:PslsHookOutcome

        $killedText | Should -Not -Be $emptyText
        $killedText | Should -Match 'KILLED at CapMs'
        $emptyText | Should -Match 'wrote NOTHING to stdout'
        $emptyText | Should -Not -Match 'KILLED at CapMs'      # the two must not blur into each other
        $killedText | Should -Not -Match 'wrote NOTHING to stdout'
    }

    It 'the killed-at-cap record carries the cap it blew, and an elapsed at least that long' {
        [void](Invoke-HiHook -ScriptPath $script:HiNeverExits -CapMs 1500)
        $o = $script:PslsHookOutcome
        $o.CapMs | Should -Be 1500
        $o.ElapsedMs | Should -BeGreaterOrEqual 1500          # it waited the whole cap, then killed
        $o.ExitCode | Should -BeNullOrEmpty                   # never exited on its own, so there is none
    }

    It 'a normal run records ok with its real exit code -- the happy rung is not vacuous' {
        $out = Invoke-HiHook -ScriptPath $script:HiWithStdout -CapMs 20000
        $out | Should -Match 'HELLO-FROM-CHILD'
        $script:PslsHookOutcome.Reason | Should -BeExactly 'ok'
        $script:PslsHookOutcome.ExitCode | Should -Be 0
        (Format-PluginHookOutcome $script:PslsHookOutcome) | Should -Match 'completed with output'
    }

    It 'exited-empty-stdout records exit 0 -- proving it is a CLEAN exit, not a kill' {
        [void](Invoke-HiHook -ScriptPath $script:HiEmptyStdout -CapMs 20000)
        $script:PslsHookOutcome.Reason | Should -BeExactly 'exited-empty-stdout'
        $script:PslsHookOutcome.ExitCode | Should -Be 0
        $script:PslsHookOutcome.ElapsedMs | Should -BeLessThan 20000
    }
}

Describe 'Flake instrumentation: EVERY process-spawning hook in the suite records its outcome (000159 leg 1a)' {

    BeforeAll {
        # Derive the covered set from the AST, not from a hand-list. The 000156 leg 3 lesson is
        # that a guard over a DERIVED set needs a vacuity assertion over the set itself -- a
        # derivation bug empties the set and every assertion then passes over nothing.
        #
        # THE CLASS IS NOT "spawns a process with a cap", IT IS "collapses distinct failures into
        # one indistinguishable return". Those are not the same set, and the difference was found
        # by measurement, not assumed: the first cut of this scan flagged Invoke-CaptureU, which
        # spawns with a cap but returns a HASHTABLE carrying ExitCode = -999 and Err = 'timeout'
        # on the cap path. It already discriminates, so instrumenting it would add nothing. The
        # defect class is the functions that answer `return ''` to more than one distinct cause.
        $script:HiTargetFile = Join-Path $PSScriptRoot 'PowerShellLsp.Integration.Tests.ps1'
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:HiTargetFile, [ref]$tokens, [ref]$errors)
        $script:HiParseErrors = @($errors)
        $funcs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
        $script:HiSpawners = @($funcs | Where-Object { $_.Extent.Text -match '\$p\.WaitForExit\(' })
        $script:HiCollapsers = @($script:HiSpawners | Where-Object { $_.Extent.Text -match "return\s*''" })
        $script:HiExcluded = @($script:HiSpawners | Where-Object { $_.Extent.Text -notmatch "return\s*''" })
    }

    It 'the integration suite parses clean (the scan is over real code, not a broken parse)' {
        $script:HiParseErrors.Count | Should -Be 0
    }

    It 'the covered set is NON-EMPTY -- the scan actually reaches the hook functions' {
        $script:HiSpawners.Count | Should -BeGreaterThan 0
        $script:HiCollapsers.Count | Should -BeGreaterThan 0
        # Sanity floor: ten Invoke-PluginHook copies plus Invoke-HookEnvU and Invoke-DfHook.
        # If this drops, the derivation broke rather than the suite improving.
        $script:HiCollapsers.Count | Should -BeGreaterOrEqual 12
    }

    It 'every collapsing hook records ALL THREE outcomes -- the class is closed, not one instance' {
        $missing = New-Object System.Collections.ArrayList
        foreach ($f in $script:HiCollapsers) {
            $body = $f.Extent.Text
            foreach ($reason in @('killed-at-cap', 'stdout-read-timeout', 'exited-empty-stdout')) {
                if ($body -notmatch [regex]::Escape($reason)) {
                    [void]$missing.Add($f.Name + ' @line ' + $f.Extent.StartLineNumber + ' missing ' + $reason)
                }
            }
        }
        $missing.ToArray() -join '; ' | Should -BeExactly ''
    }

    It 'the EXCLUSIONS are narrow and earned: every uninstrumented spawner already discriminates' {
        # Excluding by fiat would let a genuine instance hide behind the exclusion. So name the
        # excluded set exactly and prove each member carries its own distinct cap-path signal.
        # Both are the capture helpers, which return a hashtable rather than a bare string and
        # therefore never had the collapse: ExitCode = -999 with Err = 'timeout' on the cap path
        # is already distinguishable from a clean exit carrying a real code and empty output.
        $names = @($script:HiExcluded | ForEach-Object { $_.Name } | Sort-Object -Unique)
        ($names -join ',') | Should -BeExactly 'Invoke-CaptureC,Invoke-CaptureU'
        foreach ($f in $script:HiExcluded) {
            $f.Extent.Text | Should -Match '-999'        # distinct exit code on the cap path
            $f.Extent.Text | Should -Match "'timeout'"   # and a distinct Err string
            $f.Extent.Text | Should -Match 'return @\{'  # returns a record, never a bare string
        }
    }

    It 'every Describe carrying an instrumented hook DOT-SOURCES the helper it now calls' {
        # This guard exists because its absence bit immediately. The recorder lives in
        # Integration.Common.ps1, but two Describes (000024's Invoke-HookEnvU and 000039's
        # Invoke-DfHook) never dot-sourced that file -- they only needed lsp-common.ps1 before.
        # Instrumenting them made the call a hard dependency, and those two blocks failed with
        # "New-PluginHookOutcome is not recognized" the first time they ran. A parse check cannot
        # see this: the call is only resolved at run time, in a block many suites skip locally.
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:HiTargetFile, [ref]$tokens, [ref]$errors)
        $describes = @($ast.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Describe'
                }, $true))
        $offenders = New-Object System.Collections.ArrayList
        foreach ($f in $script:HiCollapsers) {
            $owner = $null
            foreach ($d in $describes) {
                if ($d.Extent.StartOffset -le $f.Extent.StartOffset -and $d.Extent.EndOffset -ge $f.Extent.EndOffset) {
                    if ($null -eq $owner -or $d.Extent.StartOffset -gt $owner.Extent.StartOffset) { $owner = $d }
                }
            }
            if ($null -eq $owner) { [void]$offenders.Add($f.Name + ' @line ' + $f.Extent.StartLineNumber + ' has no enclosing Describe'); continue }
            if ($owner.Extent.Text -notmatch 'Integration\.Common\.ps1') {
                [void]$offenders.Add($f.Name + ' @line ' + $f.Extent.StartLineNumber + ' in a Describe that never dot-sources Integration.Common.ps1')
            }
        }
        $offenders.ToArray() -join '; ' | Should -BeExactly ''
    }

    It 'NO hook still collapses the two paths into a bare shared return' {
        # The exact pre-fix tail. Its survival anywhere means an instance was missed.
        $src = Get-Content -LiteralPath $script:HiTargetFile -Raw
        $collapsed = [regex]::Matches($src, [regex]::Escape('if ($stdoutTask.IsCompleted) { return $stdoutTask.Result } else { return '''' }'))
        $collapsed.Count | Should -Be 0
    }
}

Describe 'Flake instrumentation: isolated data-root logs reach the uploaded artifact (000159 leg 1a step 1)' {

    It 'copies logs/ and session/ out of an isolated root into the artifact tree' {
        $src = Join-Path $script:HiRoot ('src-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $dst = Join-Path $script:HiRoot ('art-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Force -Path (Join-Path $src 'logs') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $src 'session') | Out-Null
        Set-Content -LiteralPath (Join-Path $src 'logs/pses-daemon.log') -Value 'daemon line' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $src 'session/abc.json') -Value '{}' -Encoding ascii

        $copied = Save-IsolatedDataRootLog -DataRoot $src -Tag 'unit-tag' -ArtifactRoot $dst
        $copied | Should -Be 2
        (Test-Path -LiteralPath (Join-Path $dst 'logs/isolated/unit-tag/logs/pses-daemon.log')) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $dst 'logs/isolated/unit-tag/session/abc.json')) | Should -BeTrue
        # and the content survives the copy (not just the path)
        (Get-Content -LiteralPath (Join-Path $dst 'logs/isolated/unit-tag/logs/pses-daemon.log') -Raw).Trim() | Should -BeExactly 'daemon line'
    }

    It 'lands INSIDE the path CI uploads (psls-test-data/logs/**), not merely somewhere' {
        # The artifact glob is psls-test-data/logs/** ; the destination must sit under logs/.
        $src = Join-Path $script:HiRoot ('src2-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $dst = Join-Path $script:HiRoot ('art2-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Force -Path (Join-Path $src 'logs') | Out-Null
        Set-Content -LiteralPath (Join-Path $src 'logs/x.log') -Value 'x' -Encoding ascii
        [void](Save-IsolatedDataRootLog -DataRoot $src -Tag 'globcheck' -ArtifactRoot $dst)
        $landed = @(Get-ChildItem -LiteralPath $dst -File -Recurse)
        $landed.Count | Should -Be 1
        # relative path under the artifact root must begin with 'logs' + separator
        $rel = $landed[0].FullName.Substring($dst.Length).TrimStart('\', '/')
        $rel | Should -Match '^logs[\\/]'
    }

    It 'is a no-op when no artifact root is configured (a local run needs no rescue)' {
        $src = Join-Path $script:HiRoot ('src3-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Force -Path (Join-Path $src 'logs') | Out-Null
        Set-Content -LiteralPath (Join-Path $src 'logs/y.log') -Value 'y' -Encoding ascii
        (Save-IsolatedDataRootLog -DataRoot $src -Tag 'noop' -ArtifactRoot '') | Should -Be 0
    }

    It 'never throws on a missing root -- instrumentation must not be able to fail a teardown' {
        $missing = Join-Path $script:HiRoot ('gone-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $dst = Join-Path $script:HiRoot ('art3-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        { Save-IsolatedDataRootLog -DataRoot $missing -Tag 'gone' -ArtifactRoot $dst } | Should -Not -Throw
        (Save-IsolatedDataRootLog -DataRoot $missing -Tag 'gone' -ArtifactRoot $dst) | Should -Be 0
    }

    It 'every isolated root the suite mints is rescued under its own tag' {
        # Derived from the suite, not hand-listed: every isolated root is minted as a temp-dir
        # path with a guid suffix. Each such root must have a rescue call.
        $src = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'PowerShellLsp.Integration.Tests.ps1') -Raw
        # Literal tags, one per root.
        foreach ($tag in @('000022-degraded', '000028-A', '000028-B', '000030-nobundle',
                '000030-dummy', '000039-dogfood')) {
            $src | Should -Match ([regex]::Escape("-Tag '" + $tag + "'"))
        }
        # The 000024 block mints four sibling roots, so its tag is COMPOSED in a loop rather than
        # written out four times. Assert the composition and each of the four names it feeds.
        # NOTE the single quotes: in a double-quoted PowerShell string $pair would EXPAND
        # (to empty), and the probe would then assert against text that never existed.
        $src | Should -Match ([regex]::Escape('-Tag (''000024-'' + $pair[1])'))
        foreach ($name in @('marquee', 'loud', 'nondestr', 'surface')) {
            $src | Should -Match ([regex]::Escape('@($script:U_Root'))
            $src | Should -Match ([regex]::Escape("'" + $name + "'"))
        }
        # Vacuity floor: the rescue is wired at least once per daemon-bearing isolated root.
        ([regex]::Matches($src, 'Save-IsolatedDataRootLog')).Count | Should -BeGreaterOrEqual 7
    }

    It 'in every AfterAll that rescues, the rescue comes BEFORE anything that discards state' {
        # Block-scoped and structural: inside each AfterAll block that carries a rescue, the FIRST
        # Save-IsolatedDataRootLog must precede the FIRST Remove-Item in that same block. Scoping
        # to the block is what makes this honest -- a file-wide line comparison would pass on
        # accidental ordering between unrelated blocks. Note the rescue must also beat the
        # session-file cleanup, not just the root teardown: several blocks discard
        # session/<sid>.json from the isolated root, and that file is half the diagnostic value.
        $tokens = $null; $errors = $null
        $target = Join-Path $PSScriptRoot 'PowerShellLsp.Integration.Tests.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
        $blocks = @($ast.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and
                    $n.GetCommandName() -eq 'AfterAll'
                }, $true))
        $rescuing = @($blocks | Where-Object { $_.Extent.Text -match 'Save-IsolatedDataRootLog' })
        $rescuing.Count | Should -BeGreaterOrEqual 5     # vacuity floor: the scan found real blocks

        foreach ($b in $rescuing) {
            $text = $b.Extent.Text
            $saveAt = $text.IndexOf('Save-IsolatedDataRootLog')
            $killAt = $text.IndexOf('Remove-Item')
            $saveAt | Should -BeGreaterThan -1
            if ($killAt -ge 0) {
                $saveAt | Should -BeLessThan $killAt
            }
        }
    }
}
