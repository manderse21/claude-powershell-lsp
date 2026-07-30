#Requires -Version 5.1

# ServeShim lifecycle instrumentation proofs (dispatch 000163 leg 2).
#
# Mirrors the PowerShellLsp.HookInstrumentation.Tests.ps1 shape from 000159 leg 1a: the
# instrumentation gets its OWN proofs file, separate from the suite it instruments, and every
# proof runs in BOTH directions.
#
# These Describes are PURE (no shim, no PSES, so they run on every CI leg including the
# constrained windows-powershell 5.1 one) except the last, which simulates a shim-lifecycle
# failure with a trivial pwsh child.
#
# THE CORPUS IS REAL, AND HASH-PINNED. tests/fixtures/serveshim-run-30472816851-pses-serve-shim.log
# is the VERBATIM psls-test-data/logs/pses-serve-shim.log from CI run 30472816851 (macos-pwsh) --
# the SECOND ServeShim sighting, the one on the d05ec7a docs-only merge. Copied byte-for-byte from
# the downloaded artifact, and the BeforeAll asserts its SHA256, so the discriminator is proven
# against the actual evidence it exists to classify and the corpus cannot drift unnoticed. In that
# run:
#
#   pid 18197 -- the shim-mode nav scenario   (healthy, client-EOF teardown)
#   pid 18217 -- the off-mode pass-through    (healthy, client-EOF teardown)
#   pid 18428 -- the CRASH scenario           (the failing ShimExitedAfterCrash assertion)
#
# 18428 logged NEITHER break marker yet DID log the finally line: the unlogged-exception
# signature. It also logged ZERO 'intercepted server->client' lines where the healthy shim-mode run
# logged two, which is what places the throw on a client->PSES write to the killed child's stdin,
# reached BEFORE the pump's own EOF branch. Naming the FIX is out of scope (OQ1); this leg only
# makes the mechanism observable.
#
# The fixture is read INSIDE BeforeAll, never at file scope: Pester v5 isolates discovery from run,
# so a $script: variable assigned at file top level is NOT visible to a run-phase BeforeAll (the
# same trap the ServeShim suite's own header calls out for the interpreter).
#
# ASCII-only (PS 5.1 em-dash trap). Author: Mike Andersen / powershell-lsp plugin.

Describe 'ServeShim instrumentation: the exit-path discriminator, on the REAL run-30472816851 log (000163 leg 2)' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'ServeShim.Common.ps1')
        $script:FixturePath = Join-Path $PSScriptRoot 'fixtures/serveshim-run-30472816851-pses-serve-shim.log'
        # Hash the LF-NORMALIZED bytes, never the bytes as checked out. Get-FileHash on the worktree
        # file asserts a CHECKOUT PROPERTY: git converts LF -> CRLF on a Windows checkout, so the raw
        # digest differs per platform. MEASURED -- the first version of this used Get-FileHash directly
        # and went RED on BOTH Windows CI legs while passing on macos-pwsh and ubuntu-pwsh, which is the
        # signature of an EOL-dependent assertion rather than a content problem. Stripping CR keeps the
        # tamper-evidence (any real content drift still fails) while making the claim about the FILE's
        # content instead of about how git happened to materialise it.
        $script:FixtureSha = [System.BitConverter]::ToString(
            [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                [byte[]]@([System.IO.File]::ReadAllBytes($script:FixturePath) | Where-Object { $_ -ne 13 })
            )
        ).Replace('-', '')
        $script:DiscRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('psls-000163-disc-' + ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        New-Item -ItemType Directory -Force -Path (Join-Path $script:DiscRoot 'logs') | Out-Null
        Copy-Item -LiteralPath $script:FixturePath -Destination (Join-Path $script:DiscRoot 'logs/pses-serve-shim.log') -Force
        $script:SliceCrash = @(Get-ServeShimLogSlice -DataRoot $script:DiscRoot -ShimPid 18428)
        $script:SliceNav = @(Get-ServeShimLogSlice -DataRoot $script:DiscRoot -ShimPid 18197)
        $script:SliceOff = @(Get-ServeShimLogSlice -DataRoot $script:DiscRoot -ShimPid 18217)
    }
    AfterAll {
        if ($script:DiscRoot -and (Test-Path -LiteralPath $script:DiscRoot)) { Remove-Item -LiteralPath $script:DiscRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # --- provenance + selected-count floors: the corpus really is the recorded one ----
    It 'the corpus is the hash-pinned artifact from run 30472816851 (LF-normalized, EOL-agnostic)' {
        $script:FixtureSha | Should -BeExactly '09E906891043A37F2EAADC956749A9B3C019082CD147998F914A0DB0229AD20C' -Because 'the fixture is a byte-for-byte copy of the downloaded daemon-logs artifact, hashed with CR stripped so the digest is a property of its CONTENT and not of how git materialised it on this platform; a mismatch means the corpus drifted'
    }
    It 'the corpus hash is genuinely EOL-agnostic (proven on a CRLF copy, both directions)' {
        # Without this, the fix above is only asserted on whatever this platform happens to check out --
        # which is exactly the blind spot that let the CRLF failure reach CI in the first place. Build
        # BOTH materialisations here and require one digest, plus a NEGATIVE arm proving the raw
        # (un-normalized) digests genuinely differ, so this cannot pass by the two copies being identical.
        $lf = [byte[]]@([System.IO.File]::ReadAllBytes($script:FixturePath) | Where-Object { $_ -ne 13 })
        $crlf = [System.Text.Encoding]::ASCII.GetBytes(([System.Text.Encoding]::ASCII.GetString($lf) -replace "`n", "`r`n"))
        $crlf.Count | Should -BeGreaterThan $lf.Count -Because 'the CRLF copy must really carry extra CR bytes, or the comparison is vacuous'
        $sha = { param($b) [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($b)).Replace('-', '') }
        (& $sha $lf) | Should -Not -BeExactly (& $sha $crlf) -Because 'the RAW digests must differ -- that difference is the CI failure this guards'
        $norm = { param($b) & $sha ([byte[]]@($b | Where-Object { $_ -ne 13 })) }
        (& $norm $crlf) | Should -BeExactly (& $norm $lf) -Because 'after CR-stripping, both materialisations must yield ONE digest'
        (& $norm $crlf) | Should -BeExactly '09E906891043A37F2EAADC956749A9B3C019082CD147998F914A0DB0229AD20C'
    }
    It 'the corpus is non-vacuous: three shims, at the recorded per-pid line counts' {
        $script:SliceNav.Count | Should -Be 8 -Because 'pid 18197 wrote 8 lines in run 30472816851'
        $script:SliceOff.Count | Should -Be 5 -Because 'pid 18217 wrote 5 lines in run 30472816851'
        $script:SliceCrash.Count | Should -Be 5 -Because 'pid 18428 wrote 5 lines in run 30472816851'
    }

    # --- FIRES: the crash shim is the unlogged-exception path -------------------
    It 'classifies the CRASH shim (pid 18428) as the unlogged-exception path' {
        Get-ServeShimExitPath -LogSlice $script:SliceCrash | Should -BeExactly 'unlogged-exception-path'
    }
    It 'the crash slice really lacks BOTH break markers (the verdict is not an artifact of an empty slice)' {
        $joined = ($script:SliceCrash -join "`n")
        $joined | Should -Not -BeNullOrEmpty
        $joined | Should -Not -Match 'stdout EOF; propagating EOF'
        $joined | Should -Not -Match 'client stdin EOF'
        $joined | Should -Match 'shim exiting; PSES reaped'
    }
    It 'the crash shim answered ZERO server->client intercepts where the healthy one answered two' {
        # The measurement that places the throw on a client->PSES write: in the shim, Write-ServeFrame
        # to the child's stdin runs BEFORE its Write-ShimLog, so a broken pipe there emits no line.
        @($script:SliceCrash | Where-Object { $_ -match 'intercepted server->client' }).Count | Should -Be 0
        @($script:SliceNav | Where-Object { $_ -match 'intercepted server->client' }).Count | Should -Be 2
    }

    # --- SILENT: the two healthy shims in the SAME run classify differently -----
    It 'classifies the healthy shim-mode shim (pid 18197) as a clean client-EOF teardown' {
        Get-ServeShimExitPath -LogSlice $script:SliceNav | Should -BeExactly 'client-eof'
    }
    It 'classifies the healthy off-mode shim (pid 18217) as a clean client-EOF teardown' {
        Get-ServeShimExitPath -LogSlice $script:SliceOff | Should -BeExactly 'client-eof'
    }
    It 'does NOT classify either healthy shim as the exception path (both directions)' {
        Get-ServeShimExitPath -LogSlice $script:SliceNav | Should -Not -BeExactly 'unlogged-exception-path'
        Get-ServeShimExitPath -LogSlice $script:SliceOff | Should -Not -BeExactly 'unlogged-exception-path'
    }

    # --- the contractual crash path, which run 30472816851 never produced -------
    It 'classifies a CONTRACTUAL PSES-death teardown as pses-eof-propagated' {
        # Synthetic on purpose: NO shim in run 30472816851 took this branch, and that absence is
        # itself the finding. Built FROM the marker constant, so a reword cannot leave it green.
        $slice = @(
            ('[2026-07-29T17:08:09.0000000+00:00] [4242] pump started'),
            ('[2026-07-29T17:08:09.5000000+00:00] [4242] ' + $script:ServeShimMarkerPsesEof),
            ('[2026-07-29T17:08:09.6000000+00:00] [4242] ' + $script:ServeShimMarkerFinally)
        )
        Get-ServeShimExitPath -LogSlice $slice | Should -BeExactly 'pses-eof-propagated'
    }
    It 'returns no-shim-log for a pid that wrote nothing (the discriminator cannot pass vacuously)' {
        $absent = @(Get-ServeShimLogSlice -DataRoot $script:DiscRoot -ShimPid 999999)
        Get-ServeShimExitPath -LogSlice $absent | Should -BeExactly 'no-shim-log'
    }
    It 'returns no-teardown when the pump died mid-flight (not even the finally ran)' {
        Get-ServeShimExitPath -LogSlice @('[2026-07-29T17:08:09.0000000+00:00] [4243] pump started') | Should -BeExactly 'no-teardown'
    }
    It 'the five outcomes are all DISTINCT (the 000159 step-2 lesson: never collapse failures)' {
        $outcomes = @('no-shim-log', 'pses-eof-propagated', 'client-eof', 'unlogged-exception-path', 'no-teardown')
        (@($outcomes | Select-Object -Unique)).Count | Should -Be 5
    }
}

Describe 'ServeShim instrumentation: per-run isolation of the SHARED shim log (000163 leg 2)' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'ServeShim.Common.ps1')
        $script:IsoRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('psls-000163-iso-' + ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        New-Item -ItemType Directory -Force -Path (Join-Path $script:IsoRoot 'logs') | Out-Null
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/serveshim-run-30472816851-pses-serve-shim.log') -Destination (Join-Path $script:IsoRoot 'logs/pses-serve-shim.log') -Force
    }
    AfterAll {
        if ($script:IsoRoot -and (Test-Path -LiteralPath $script:IsoRoot)) { Remove-Item -LiteralPath $script:IsoRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'returns ONLY the target shim pid lines out of a log three shims interleaved into' {
        $slice = @(Get-ServeShimLogSlice -DataRoot $script:IsoRoot -ShimPid 18428)
        $slice.Count | Should -Be 5
        foreach ($line in $slice) { $line | Should -Match '\] \[18428\] ' }
    }
    It 'leaks NO other shim lines (both directions on the same corpus)' {
        $slice = @(Get-ServeShimLogSlice -DataRoot $script:IsoRoot -ShimPid 18428)
        $joined = ($slice -join "`n")
        $joined | Should -Not -Match '18197'
        $joined | Should -Not -Match '18217'
        $joined | Should -Match '18428'
    }
    It 'the three slices PARTITION the log (18 pid-stamped lines, none double-counted, none dropped)' {
        $nNav = @(Get-ServeShimLogSlice -DataRoot $script:IsoRoot -ShimPid 18197).Count
        $nOff = @(Get-ServeShimLogSlice -DataRoot $script:IsoRoot -ShimPid 18217).Count
        $nCrash = @(Get-ServeShimLogSlice -DataRoot $script:IsoRoot -ShimPid 18428).Count
        ($nNav + $nOff + $nCrash) | Should -Be 18 -Because 'run 30472816851 logged 18 pid-stamped lines across exactly three shims'
    }
    It 'returns an EMPTY array (never null) for an absent pid, an absent log, and a zero pid' {
        @(Get-ServeShimLogSlice -DataRoot $script:IsoRoot -ShimPid 424242).Count | Should -Be 0
        @(Get-ServeShimLogSlice -DataRoot (Join-Path $script:IsoRoot 'nope') -ShimPid 18428).Count | Should -Be 0
        @(Get-ServeShimLogSlice -DataRoot $script:IsoRoot -ShimPid 0).Count | Should -Be 0
    }
}

Describe 'ServeShim instrumentation: the markers stay COUPLED to the shipped shim (000163 leg 2)' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'ServeShim.Common.ps1')
        $script:ShimSrcPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/pses-serve-shim.ps1'
        $script:ShimAllLines = @(Get-Content -LiteralPath $script:ShimSrcPath)
        # ACTIVE lines only. The shim's header comment paraphrases the exit contract in prose, so
        # matching the whole file would let a marker survive in a COMMENT while the Write-ShimLog
        # call the discriminator actually depends on was reworded -- a silently-degraded matcher
        # that classifies every future run as 'no-teardown' while the suite stays green.
        $script:ShimActiveLines = @($script:ShimAllLines | Where-Object { $_ -notmatch '^\s*#' })
        # The outer try is identified STRUCTURALLY via the AST, not by a text anchor: the shim has
        # several try blocks (the log-path setup, the job guard, the Marshal alloc) and a regex on
        # '} catch' at column 0 matches the log-path one, which is not the block under study.
        $errs = $null
        $script:ShimAst = [System.Management.Automation.Language.Parser]::ParseFile($script:ShimSrcPath, [ref]$null, [ref]$errs)
        $script:ShimParseErrors = @($errs).Count
        $allTries = @($script:ShimAst.FindAll({ $args[0] -is [System.Management.Automation.Language.TryStatementAst] }, $true))
        $script:ShimOuterTries = @($allTries | Where-Object { $null -ne $_.Finally -and $_.Extent.StartColumnNumber -eq 1 })
    }
    It 'the shipped shim parses cleanly (the AST assertions below are meaningful)' {
        $script:ShimParseErrors | Should -Be 0
    }
    It 'the ACTIVE/COMMENT split is non-vacuous (it really dropped comment lines and kept code)' {
        $script:ShimActiveLines.Count | Should -BeGreaterThan 100
        $script:ShimActiveLines.Count | Should -BeLessThan $script:ShimAllLines.Count -Because 'the shim carries a substantial header comment that must have been dropped'
    }
    It 'every discriminator marker is still emitted by an ACTIVE Write-ShimLog call in the shipped shim' {
        foreach ($marker in @($script:ServeShimMarkerPsesEof, $script:ServeShimMarkerClientEof, $script:ServeShimMarkerFinally)) {
            $hits = @($script:ShimActiveLines | Where-Object { $_.Contains('Write-ShimLog') -and $_.Contains($marker) })
            $hits.Count | Should -BeGreaterThan 0 -Because ('the discriminator keys off this exact string, so a reword must turn RED here rather than degrade silently: ' + $marker)
        }
    }
    It 'a marker that was NEVER in the shim does not match (the guard cannot pass vacuously)' {
        $decoy = 'shim exiting; PSES definitely absolutely reaped'
        @($script:ShimActiveLines | Where-Object { $_.Contains('Write-ShimLog') -and $_.Contains($decoy) }).Count | Should -Be 0
    }
    It 'the outer try/finally is unique and spans the pump (the AST selection is not vacuous)' {
        $script:ShimOuterTries.Count | Should -Be 1
        $outer = $script:ShimOuterTries[0]
        ($outer.Extent.EndLineNumber - $outer.Extent.StartLineNumber) | Should -BeGreaterThan 100 -Because 'the block under study wraps the whole two-source pump'
    }
    It 'the shipped shim still has NO catch on its OUTER try -- the premise this whole leg rests on' {
        # If a `catch` is ever added there, the unhandled exception stops being invisible and this
        # instrumentation should be revisited. Assert the premise rather than assume it.
        @($script:ShimOuterTries[0].CatchClauses).Count | Should -Be 0
    }
    It 'the AST premise check is not vacuous: the shim DOES have catch clauses elsewhere' {
        # Guards the inverse error -- if CatchClauses were always empty for every try (a wrong AST
        # property, say), the assertion above would pass for free.
        $allTries = @($script:ShimAst.FindAll({ $args[0] -is [System.Management.Automation.Language.TryStatementAst] }, $true))
        $withCatch = @($allTries | Where-Object { @($_.CatchClauses).Count -gt 0 })
        $withCatch.Count | Should -BeGreaterThan 0 -Because 'the log-path setup and the job guard both catch, so the property does report catches when present'
    }
    It 'the shim still ends in [System.Environment]::Exit -- the line the exception path SKIPS' {
        @($script:ShimActiveLines | Where-Object { $_ -match '^\[System\.Environment\]::Exit\(' }).Count | Should -Be 1
    }
}

Describe 'ServeShim instrumentation: a SIMULATED shim-lifecycle failure produces the isolated artifact (000163 leg 2)' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')
        . (Join-Path $PSScriptRoot 'ServeShim.Common.ps1')
        $script:SimRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('psls-000163-sim-' + ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        New-Item -ItemType Directory -Force -Path (Join-Path $script:SimRoot 'logs') | Out-Null

        # The sentinel is generated into a VARIABLE, then used BOTH in the child's command and in
        # the assertion -- so a corrupted or absent payload cannot pass. Never a literal retyped twice.
        $script:SimSentinel = 'SIMULATED-UNHANDLED-EXCEPTION-000163-' + ([guid]::NewGuid().ToString('N').Substring(0, 12))

        # Simulate the FAILING shape faithfully: write an error record to stderr, then BLOCK FOREVER
        # on a synchronous read of an unclosed stdin. That is the real hazard -- an unhandled
        # exception in pses-serve-shim.ps1 skips its [System.Environment]::Exit, and the graceful
        # runspace shutdown then waits on exactly such a blocked reader. No Start-Sleep in the child:
        # the block is a genuine stdin read, which is the mechanism under study.
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'pwsh'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        Add-ProcessArguments $psi @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command',
            ('[Console]::Error.WriteLine("' + $script:SimSentinel + '"); [Console]::Error.Flush(); $null = [Console]::In.ReadLine()'))
        $script:SimProc = [System.Diagnostics.Process]::Start($psi)

        # THE PRODUCTION SINK, not a copy of it -- New-ServeShimStderrSink was factored out of
        # Start-ServeShimClient precisely so this proof exercises the shipped code path.
        $script:SimSink = New-ServeShimStderrSink -Process $script:SimProc -DataRoot $script:SimRoot -Mode 'sim'

        # Bounded poll for the CopyToAsync to land the bytes. Test-side polling, not instrumentation.
        $script:SimStderrWhileAlive = ''
        for ($i = 0; $i -lt 100; $i++) {
            $script:SimStderrWhileAlive = Read-ServeShimTextFile -Path $script:SimSink.Path
            if ($script:SimStderrWhileAlive.Contains($script:SimSentinel)) { break }
            Start-Sleep -Milliseconds 50
        }
        $script:SimAliveAtRead = -not $script:SimProc.HasExited

        # A shim-log slice for THIS pid carrying the unlogged-exception signature: the pump started,
        # then the finally ran with NEITHER break marker. Built as an array FIRST and joined in a
        # separate statement: MEASURED -- '@(a + b, c) -join "<LF>"' silently joins with a SPACE
        # instead (a '+' element re-binds the operator), which quietly collapses this to one line.
        $simLines = @(
            ('[2026-07-29T18:00:00.0000000+00:00] [' + $script:SimProc.Id + '] pump started'),
            ('[2026-07-29T18:00:00.9000000+00:00] [' + $script:SimProc.Id + '] ' + $script:ServeShimMarkerFinally)
        )
        $simLog = $simLines -join "`n"
        [System.IO.File]::WriteAllText((Join-Path $script:SimRoot 'logs/pses-serve-shim.log'), ($simLog + "`n"), (New-Object System.Text.UTF8Encoding($false)))

        # Tear the child down through the PRODUCTION teardown, then record.
        $script:SimSt = @{ Proc = $script:SimProc; To = $script:SimProc.StandardInput.BaseStream; ErrPath = $script:SimSink.Path; ErrFs = $script:SimSink.Fs }
        Stop-ServeShimClient -St $script:SimSt
        $script:SimRecordPath = Save-ServeShimLifecycleRecord -St $script:SimSt -DataRoot $script:SimRoot -Tag 'sim-crash' -Phase @{ PsesKillRequested = $true; SecondChanceWaited = $true; SecondChanceExited = $false }
    }
    AfterAll {
        try { if ($script:SimProc -and -not $script:SimProc.HasExited) { $script:SimProc.Kill() } } catch { }
        if ($script:SimRoot -and (Test-Path -LiteralPath $script:SimRoot)) { Remove-Item -LiteralPath $script:SimRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'the simulated log really is TWO lines (guards the -join precedence trap that collapses it)' {
        @(Get-ServeShimLogSlice -DataRoot $script:SimRoot -ShimPid ([int]$script:SimProc.Id)).Count | Should -Be 2
    }
    It 'captured the stderr while the child was STILL RUNNING (a ReadToEndAsync would not have completed)' {
        # The whole reason the never-read ErrTask was replaced by an UNBUFFERED file sink: the failing
        # shape does not exit, so a task completing only on pipe-close yields nothing at all -- and a
        # default-buffered FileStream leaves the file 0 bytes on disk for the same window.
        $script:SimAliveAtRead | Should -BeTrue -Because 'the simulated child blocks on an unclosed stdin, so it must still be alive at read time'
        $script:SimStderrWhileAlive | Should -Match ([regex]::Escape($script:SimSentinel))
    }
    It 'wrote the per-run isolated artifact under the CI-uploaded logs tree' {
        $script:SimRecordPath | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $script:SimRecordPath | Should -BeTrue
        (Split-Path -Parent $script:SimRecordPath) | Should -BeExactly (Join-Path $script:SimRoot 'logs')
        (Split-Path -Leaf $script:SimRecordPath) | Should -Match '^serveshim-lifecycle-sim-crash-'
    }
    It 'the artifact carries the classified exit path, the stderr sentinel, and the phase fields' {
        $rec = Get-Content -LiteralPath $script:SimRecordPath -Raw | ConvertFrom-Json
        [string]$rec.ExitPath | Should -BeExactly 'unlogged-exception-path'
        [int]$rec.ShimPid | Should -Be ([int]$script:SimProc.Id)
        [int]$rec.ShimLogLines | Should -Be 2
        [string]$rec.ShimStderr | Should -Match ([regex]::Escape($script:SimSentinel))
        [int]$rec.ShimStderrLen | Should -BeGreaterThan 0
        [bool]$rec.SecondChanceWaited | Should -BeTrue
        [bool]$rec.SecondChanceExited | Should -BeFalse
        [string]$rec.Dispatch | Should -BeExactly '000163'
    }
    It 'the recorder returns the empty string rather than throwing when the data root is unusable' {
        # Instrumentation must never be able to fail a scenario it is only observing.
        Save-ServeShimLifecycleRecord -St $script:SimSt -DataRoot '' -Tag 'sim-crash' -Phase @{} | Should -BeExactly ''
    }
}
