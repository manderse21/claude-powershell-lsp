#Requires -Version 5.1

# Scan VERDICT census -- review finding F1, measured (dispatch 000302, A1). Tests and fixtures only;
# nothing under scripts/ changes.
#
# THE FINDING. The 2026-09-30 enterprise review (F1) read Invoke-ScanFileDiagnostics statically:
# `Analyzed` starts $true and flips only on a cap kill or a 'NOT checked' banner, so a child that
# ends any other way without a usable verdict can still be reported analyzed. A healthy zero-finding
# hook is SILENT by contract, so "silent" cannot simply be made to mean "failed" -- the scanner needs
# positive evidence of completion, which no current protocol carries. This file turns that reading
# into measurements.
#
# FOUR LAYERS, each a separate Describe:
#   1. CENSUS AT THE HELPER BOUNDARY. Nine situations (S1-S9, plus S3b and S5m, the volume and
#      missing halves of S3 and S5), each a fake child from tests/fixtures/scan-verdict/ driven by
#      the PRODUCTION Invoke-ScanFileDiagnostics -> Invoke-ScanHook exactly as the real client is.
#   2. REACHABILITY THROUGH THE REAL CLIENT. The real scripts/lsp-client.ps1, driven into the same
#      child behaviours: a vanished source file (no daemon needed), a client script the host cannot
#      run, and four canned answers from a fake pipe daemon (ok=false, wrong-typed, truncated,
#      clean). This is what makes the fakes trustworthy -- the real client really ends this way.
#   3. THE CLI BOUNDARY. The shipped scripts/lsp-scan.ps1 and its two libraries, copied byte for
#      byte (SHA-256 verified) beside fake hooks, run end to end: exit code + SARIF
#      executionSuccessful per situation. LIMITATION, stated: lsp-scan.ps1 resolves its hooks from
#      its own directory and has no other seam, so this layer proves the shipped CLI's verdict
#      logic against FAKE children only. The full real-hook CLI check belongs to A2.
#   4. THE ORACLE AND THE EXCLUSION GUARD. tests/assert-expected-red.ps1 is proven to accept the
#      declared failures and nothing else, and the RED tags are proven to sit exactly on the tests
#      tests/fixtures/scan-verdict/expected-red.psd1 declares.
#
# CLASSIFICATION. Every contract assertion is its own It, measured at the dispatch head. An It that
# FAILS today carries the tag 'ScanRed-A2' (A2 owns the typed completion receipt that fixes it) and
# is EXCLUDED from tests/run-tests.ps1 by default; tests/assert-expected-red.ps1 re-runs exactly
# those tests in a fresh process and passes only if each fails with its declared assertion. An It
# that PASSES today is an ALREADY-GREEN control and runs in the normal suite. Each RED It re-checks
# its situation first, so it can only fail with its declared message if the situation was really
# reached -- the oracle's message match depends on that.
#
# THE S1/S9 PAIR is the heart of the census: the two children produce byte-identical output at the
# scanner boundary (see s9-clean-complete.ps1), S1 is expected NOT analyzed and S9 analyzed. Absence
# of finding records is not evidence of completion; the pair can only both pass once a completion
# receipt exists and S9 emits it through A2's production producer.
#
# The existing deadline-kill regression (PowerShellLsp.SarifScan.Tests.ps1, dispatch 000132) is
# untouched; S7 is its census twin.
#
# ASCII-only (PS 5.1 Windows-1252 trap); StrictMode-safe. Run via tests/run-tests.ps1.

# Discovery-time gates (StrictMode-safe; PS 5.1 has no $IsWindows/$IsLinux).
$script:SvDesktop = ([string]$PSVersionTable.PSEdition -eq 'Desktop')
$script:SvOnWindows = if (Test-Path 'Variable:\IsWindows') { [bool]$IsWindows } else { $true }
$script:SvOnLinux = (Test-Path 'Variable:\IsLinux') -and [bool]$IsLinux
$script:SvOnMacOS = (Test-Path 'Variable:\IsMacOS') -and [bool]$IsMacOS
$script:SvUnsupported = -not ($script:SvOnWindows -or $script:SvOnLinux -or $script:SvOnMacOS)

Describe 'Scan verdict census at the helper boundary (dispatch 000302 A1)' -Skip:$script:SvUnsupported {

    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-scan-common.ps1')
        . (Join-Path $PSScriptRoot 'Integration.Common.ps1')
        . (Join-Path $PSScriptRoot 'ScanHarness.Common.ps1')
        $script:SvHost = Resolve-PsHost 'pwsh'
        if ($null -eq $script:SvHost) { throw 'no PowerShell host (pwsh / powershell) to spawn the fake children' }
        $script:SvSavedEnv = Save-SvAmbientEnv
        $script:SvRoots = New-Object System.Collections.ArrayList

        function Assert-SvSituation {
            # The situation preconditions every census It shares: the fake really ran (its own
            # marker) and ended ON ITS OWN, well inside the scanner's 25000 ms cap.
            param($Case, [string]$Id)
            (Read-SvTextFile -Path (Join-Path $Case.DataRoot 'fake-ran.txt')) | Should -BeExactly $Id -Because ($Id + ' situation: the fake child must have run')
            [int]$Case.Result.ElapsedMs | Should -BeLessThan 20000 -Because ($Id + ' situation: the child must have exited on its own, not at the cap')
        }
    }

    AfterAll {
        Restore-SvAmbientEnv -Saved $script:SvSavedEnv
        foreach ($r in @($script:SvRoots)) { Remove-SvTempRoot -Path $r }
    }

    Context 'S1 silent exit 0' {
        BeforeAll {
            $script:S1 = Invoke-SvScanCase -HostExe $script:SvHost -Tag 's1' -ClientFixture 's1-silent-exit-zero.ps1'
            [void]$script:SvRoots.Add($script:S1.Root)
        }
        It 'S1 situation -- the child ran, exited 0 on its own and left no finding' {
            Assert-SvSituation -Case $script:S1 -Id 'S1'
            @($script:S1.Result.Findings).Count | Should -Be 0
        }
        It 'S1 verdict -- a child that ends silently is NOT reported analyzed' -Tag 'ScanRed-A2' {
            Assert-SvSituation -Case $script:S1 -Id 'S1'
            $script:S1.Result.Analyzed | Should -BeFalse -Because 'S1 verdict: a silent exit 0 is not evidence that analysis completed'
        }
    }

    Context 'S2 nonzero exit' {
        BeforeAll {
            $script:S2 = Invoke-SvScanCase -HostExe $script:SvHost -Tag 's2' -ClientFixture 's2-nonzero-exit.ps1'
            [void]$script:SvRoots.Add($script:S2.Root)
        }
        It 'S2 situation -- the child ran and exited on its own' {
            Assert-SvSituation -Case $script:S2 -Id 'S2'
        }
        It 'S2 verdict -- a child that exits nonzero is NOT reported analyzed' -Tag 'ScanRed-A2' {
            Assert-SvSituation -Case $script:S2 -Id 'S2'
            $script:S2.Result.Analyzed | Should -BeFalse -Because 'S2 verdict: a nonzero exit means the analysis host failed'
        }
    }

    Context 'S3 stderr-only error' {
        BeforeAll {
            $script:S3 = Invoke-SvScanCase -HostExe $script:SvHost -Tag 's3' -ClientFixture 's3-stderr-only.ps1'
            [void]$script:SvRoots.Add($script:S3.Root)
        }
        It 'S3 situation -- the child ran and exited on its own' {
            Assert-SvSituation -Case $script:S3 -Id 'S3'
        }
        It 'S3 verdict -- a child that reports a failure only on stderr is NOT reported analyzed' -Tag 'ScanRed-A2' {
            Assert-SvSituation -Case $script:S3 -Id 'S3'
            $script:S3.Result.Analyzed | Should -BeFalse -Because 'S3 verdict: the failure the child reported on stderr was discarded'
        }
    }

    Context 'S3b stderr flood' {
        BeforeAll {
            # A cap of 6000 ms: long enough for any host to start the child and write 1 MiB to a
            # DRAINED pipe, short enough to keep the measured hold cheap.
            $script:S3bCapMs = 6000
            $script:S3b = Invoke-SvScanCase -HostExe $script:SvHost -Tag 's3b' -ClientFixture 's3b-stderr-flood.ps1' -CapMs $script:S3bCapMs
            [void]$script:SvRoots.Add($script:S3b.Root)
            $script:S3bPidSeen = Test-Path -LiteralPath $script:S3b.PidFile
            [void](Stop-SvChildFromPidFile -PidFile $script:S3b.PidFile)
        }
        It 'S3b situation -- the flooding child started (its pid marker exists)' {
            $script:S3bPidSeen | Should -BeTrue -Because 'S3b situation: the child must have started writing'
        }
        It 'S3b verdict -- a child that floods stderr and exits is not held to the cap by an undrained pipe' -Tag 'ScanRed-A2' {
            $script:S3bPidSeen | Should -BeTrue -Because 'S3b situation: the child must have started writing'
            [int]$script:S3b.Result.ElapsedMs | Should -BeLessThan $script:S3bCapMs -Because 'S3b verdict: stderr must be drained concurrently so a finished child can exit'
        }
    }

    Context 'S4 malformed response' {
        BeforeAll {
            $script:S4 = Invoke-SvScanCase -HostExe $script:SvHost -Tag 's4' -ClientFixture 's4-malformed-response.ps1'
            [void]$script:SvRoots.Add($script:S4.Root)
        }
        It 'S4 situation -- the child ran, exited on its own, and its one record was unreadable' {
            Assert-SvSituation -Case $script:S4 -Id 'S4'
            @($script:S4.Result.Findings).Count | Should -Be 0
        }
        It 'S4 verdict -- a child whose response cannot be parsed is NOT reported analyzed' -Tag 'ScanRed-A2' {
            Assert-SvSituation -Case $script:S4 -Id 'S4'
            $script:S4.Result.Analyzed | Should -BeFalse -Because 'S4 verdict: an unparseable response is not a verdict'
        }
    }

    Context 'S5 truncated completion' {
        BeforeAll {
            $script:S5 = Invoke-SvScanCase -HostExe $script:SvHost -Tag 's5' -ClientFixture 's5-truncated-record.ps1'
            [void]$script:SvRoots.Add($script:S5.Root)
        }
        It 'S5 situation -- the scanner kept the one complete record and silently dropped the cut one' {
            Assert-SvSituation -Case $script:S5 -Id 'S5'
            @($script:S5.Result.Findings).Count | Should -Be 1
            [string]@($script:S5.Result.Findings)[0].ruleId | Should -BeExactly 'PSUseApprovedVerbs'
        }
        It 'S5 verdict -- a truncated record stream is NOT reported analyzed' -Tag 'ScanRed-A2' {
            Assert-SvSituation -Case $script:S5 -Id 'S5'
            $script:S5.Result.Analyzed | Should -BeFalse -Because 'S5 verdict: a partial finding set must not read as a complete one'
        }
    }

    Context 'S5m missing completion records' {
        BeforeAll {
            $script:S5m = Invoke-SvScanCase -HostExe $script:SvHost -Tag 's5m' -ClientFixture 's5m-missing-record.ps1'
            [void]$script:SvRoots.Add($script:S5m.Root)
        }
        It 'S5m situation -- the child announced findings and no record reached the scanner' {
            Assert-SvSituation -Case $script:S5m -Id 'S5m'
            @($script:S5m.Result.Findings).Count | Should -Be 0
        }
        It 'S5m verdict -- findings announced but never recorded are NOT reported analyzed' -Tag 'ScanRed-A2' {
            Assert-SvSituation -Case $script:S5m -Id 'S5m'
            $script:S5m.Result.Analyzed | Should -BeFalse -Because 'S5m verdict: a missing record stream must not read as zero findings'
        }
    }

    Context 'S6 daemon ok=false' {
        BeforeAll {
            $script:S6 = Invoke-SvScanCase -HostExe $script:SvHost -Tag 's6' -ClientFixture 's6-daemon-error.ps1'
            [void]$script:SvRoots.Add($script:S6.Root)
        }
        It 'S6 situation -- the child logged the daemon error the real client logs, and exited 0' {
            Assert-SvSituation -Case $script:S6 -Id 'S6'
            $script:S6.ClientLog | Should -Match 'daemon error: file not found'
        }
        It 'S6 verdict -- a daemon ok=false answer is NOT reported analyzed' -Tag 'ScanRed-A2' {
            Assert-SvSituation -Case $script:S6 -Id 'S6'
            $script:S6.Result.Analyzed | Should -BeFalse -Because 'S6 verdict: the daemon refused the analysis'
        }
    }

    Context 'S7 deadline kill' {
        BeforeAll {
            $script:S7CapMs = 6000
            $script:S7 = Invoke-SvScanCase -HostExe $script:SvHost -Tag 's7' -ClientFixture 's7-never-exits.ps1' -CapMs $script:S7CapMs
            [void]$script:SvRoots.Add($script:S7.Root)
            $script:S7PidSeen = Test-Path -LiteralPath $script:S7.PidFile
            $script:S7AliveAfterKill = Test-SvPidAlive -PidFile $script:S7.PidFile -GraceMs 5000
            [void](Stop-SvChildFromPidFile -PidFile $script:S7.PidFile)
        }
        It 'S7 situation -- the child started and the scanner waited out its cap' {
            $script:S7PidSeen | Should -BeTrue
            [int]$script:S7.Result.ElapsedMs | Should -BeGreaterOrEqual ([int]($script:S7CapMs / 2))
        }
        It 'S7 verdict -- a child killed at the deadline is NOT reported analyzed (already green, dispatch 000132)' {
            $script:S7.Result.Analyzed | Should -BeFalse -Because 'S7 verdict: a killed analysis is not a clean one'
        }
        It 'S7b on a Windows PowerShell 5.1 parent -- the cap kill terminates the timed-out child' -Tag 'ScanRed-A2' -Skip:(-not $script:SvDesktop) {
            # Invoke-ScanHook calls $p.Kill($true), the TREE kill, which exists only on .NET Core 3.0+.
            # On .NET Framework the call throws a MethodException that the empty catch swallows, so a
            # scan run by Windows PowerShell 5.1 leaves every timed-out child running.
            $script:S7PidSeen | Should -BeTrue -Because 'S7b situation: the child must have started'
            $script:S7AliveAfterKill | Should -BeFalse -Because 'S7b verdict: a timed-out child must not outlive the cap kill'
        }
        It 'S7b on a PowerShell 7 parent -- the cap kill terminates the timed-out child' -Skip:$script:SvDesktop {
            $script:S7PidSeen | Should -BeTrue -Because 'S7b situation: the child must have started'
            $script:S7AliveAfterKill | Should -BeFalse -Because 'S7b verdict: a timed-out child must not outlive the cap kill'
        }
    }

    Context 'S8 source disappearance' {
        BeforeAll {
            $script:S8 = Invoke-SvScanCase -HostExe $script:SvHost -Tag 's8' -ClientFixture 's8-source-gone.ps1'
            [void]$script:SvRoots.Add($script:S8.Root)
        }
        It 'S8 situation -- the source was gone when the child looked, and the child said so in its log' {
            Assert-SvSituation -Case $script:S8 -Id 'S8'
            (Test-Path -LiteralPath $script:S8.Target) | Should -BeFalse
            $script:S8.ClientLog | Should -Match ([regex]::Escape('file gone: ' + $script:S8.Target))
        }
        It 'S8 verdict -- a source that disappeared before analysis is NOT reported analyzed' -Tag 'ScanRed-A2' {
            Assert-SvSituation -Case $script:S8 -Id 'S8'
            $script:S8.Result.Analyzed | Should -BeFalse -Because 'S8 verdict: a file that was never read was never analyzed'
        }
    }

    Context 'S9 valid completed zero findings' {
        BeforeAll {
            $script:S9 = Invoke-SvScanCase -HostExe $script:SvHost -Tag 's9' -ClientFixture 's9-clean-complete.ps1'
            [void]$script:SvRoots.Add($script:S9.Root)
        }
        It 'S9 situation -- the clean child ran and exited on its own' {
            Assert-SvSituation -Case $script:S9 -Id 'S9'
        }
        It 'S9 verdict -- a clean completed analysis IS reported analyzed with zero findings (the control)' {
            Assert-SvSituation -Case $script:S9 -Id 'S9'
            $script:S9.Result.Analyzed | Should -BeTrue -Because 'S9 verdict: a completed clean analysis must still read as analyzed'
            @($script:S9.Result.Findings).Count | Should -Be 0
        }
    }
}

Describe 'Scan verdict reachability through the real client (dispatch 000302 A1)' -Skip:$script:SvUnsupported {

    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-scan-common.ps1')
        . (Join-Path $PSScriptRoot 'Integration.Common.ps1')
        . (Join-Path $PSScriptRoot 'ScanHarness.Common.ps1')
        $script:RvHost = Resolve-PsHost 'pwsh'
        if ($null -eq $script:RvHost) { throw 'no PowerShell host (pwsh / powershell) to spawn the real client' }
        $script:RvSavedEnv = Save-SvAmbientEnv
        $script:RvRoots = New-Object System.Collections.ArrayList
        $script:RvDaemons = New-Object System.Collections.ArrayList
        $script:RvScriptsDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts'

        function Invoke-RvDaemonCase {
            # The REAL client against a fake daemon that answers $Response. The relaunch cooldown is
            # stamped first, so the real client can never start a real daemon from here.
            param([string]$Tag, [string]$Response)
            $root = New-SvTempRoot -Tag $Tag -MintingFile 'tests/PowerShellLsp.ScanVerdict.Tests.ps1'
            [void]$script:RvRoots.Add($root)
            $sid = 'rv' + $Tag + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            Set-SvRelaunchCooldown -DataRoot (Join-Path $root 'data') -SessionId $sid
            $daemon = Start-SvFakePipeDaemon -HostExe $script:RvHost -SessionId $sid -WorkDir (Join-Path $root 'daemon') -Response $Response
            [void]$script:RvDaemons.Add($daemon)
            $case = Invoke-SvScanCase -HostExe $script:RvHost -Tag $Tag -ScriptsDir $script:RvScriptsDir -SessionId $sid -Root $root
            $case['Requests'] = Read-SvTextFile -Path $daemon.RequestLog
            return $case
        }
    }

    AfterAll {
        foreach ($d in @($script:RvDaemons)) { Stop-SvFakePipeDaemon -Daemon $d }
        Restore-SvAmbientEnv -Saved $script:RvSavedEnv
        foreach ($r in @($script:RvRoots)) { Remove-SvTempRoot -Path $r }
    }

    Context 'R8 the real client meets a vanished source file' {
        BeforeAll {
            $script:R8 = Invoke-SvScanCase -HostExe $script:RvHost -Tag 'r8' -ScriptsDir $script:RvScriptsDir -RemoveTarget
            [void]$script:RvRoots.Add($script:R8.Root)
        }
        It 'R8 situation -- the real client logged file gone and exited without analysing' {
            $script:R8.ClientLog | Should -Match ([regex]::Escape('file gone: ' + $script:R8.Target))
        }
        It 'R8 verdict -- the real client on a vanished source is NOT reported analyzed' -Tag 'ScanRed-A2' {
            $script:R8.ClientLog | Should -Match ([regex]::Escape('file gone: ' + $script:R8.Target)) -Because 'R8 situation: the real client must have taken its file-gone exit'
            $script:R8.Result.Analyzed | Should -BeFalse -Because 'R8 verdict: the real client analysed nothing and said so only in its own log'
        }
    }

    Context 'R2 the analysis host cannot run the client script' {
        BeforeAll {
            $root = New-SvTempRoot -Tag 'r2' -MintingFile 'tests/PowerShellLsp.ScanVerdict.Tests.ps1'
            [void]$script:RvRoots.Add($root)
            $missingDir = New-SvFakeScriptsDir -Root $root -ClientFixture ''
            $script:R2Client = Join-Path $missingDir 'lsp-client.ps1'
            # What the host itself does with a client it cannot load -- recorded with the harness's
            # own spawner, because Invoke-ScanHook keeps neither the exit code nor stderr.
            $script:R2Host = Invoke-SvChildProcess -HostExe $script:RvHost -CapMs 60000 `
                -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:R2Client) `
                -RemoveEnvPrefix @('CLAUDE_PLUGIN_OPTION_', 'POWERSHELL_LSP_')
            $script:R2 = Invoke-SvScanCase -HostExe $script:RvHost -Tag 'r2' -ScriptsDir $missingDir -Root $root
        }
        It 'R2 situation -- the host exits nonzero with an error on stderr when the client cannot be loaded' {
            (Test-Path -LiteralPath $script:R2Client) | Should -BeFalse
            $script:R2Host.TimedOut | Should -BeFalse
            [int]$script:R2Host.ExitCode | Should -Not -Be 0
            [string]$script:R2Host.Err | Should -Not -BeNullOrEmpty
        }
        It 'R2 verdict -- a client the host could not even load is NOT reported analyzed' -Tag 'ScanRed-A2' {
            [int]$script:R2Host.ExitCode | Should -Not -Be 0 -Because 'R2 situation: the host must have failed to run the client'
            $script:R2.Result.Analyzed | Should -BeFalse -Because 'R2 verdict: the analysis host failed before the client ran'
        }
    }

    Context 'R6 the real client gets a daemon ok=false answer' {
        BeforeAll {
            $script:R6 = Invoke-RvDaemonCase -Tag 'r6' -Response '{"ok":false,"action":"diagnostics","error":"file not found"}'
        }
        It 'R6 situation -- the fake daemon was asked, and the real client logged its daemon-error exit' {
            $script:R6.Requests | Should -Match '"action":"diagnostics"'
            $script:R6.ClientLog | Should -Match 'daemon error: file not found'
        }
        It 'R6 verdict -- the real client on a daemon ok=false answer is NOT reported analyzed' -Tag 'ScanRed-A2' {
            $script:R6.ClientLog | Should -Match 'daemon error: file not found' -Because 'R6 situation: the real client must have taken its daemon-error exit'
            $script:R6.Result.Analyzed | Should -BeFalse -Because 'R6 verdict: the daemon refused the analysis'
        }
    }

    Context 'R4 the real client gets a wrong-typed daemon answer' {
        BeforeAll {
            # Valid JSON, wrong type: `omitted` is not a number, so the client's [int] cast throws past
            # every inner guard into its outer FATAL fail-safe, which logs and exits 0.
            $script:R4 = Invoke-RvDaemonCase -Tag 'r4' -Response '{"ok":true,"action":"diagnostics","count":0,"omitted":"not-a-number","diagnostics":[]}'
        }
        It 'R4 situation -- the fake daemon was asked, and the real client logged its FATAL fail-safe exit' {
            $script:R4.Requests | Should -Match '"action":"diagnostics"'
            $script:R4.ClientLog | Should -Match ([regex]::Escape('FATAL (fail-safe, exit 0)'))
        }
        It 'R4 verdict -- the real client on a malformed daemon answer is NOT reported analyzed' -Tag 'ScanRed-A2' {
            $script:R4.ClientLog | Should -Match ([regex]::Escape('FATAL (fail-safe, exit 0)')) -Because 'R4 situation: the real client must have taken its FATAL exit'
            $script:R4.Result.Analyzed | Should -BeFalse -Because 'R4 verdict: the client crashed before rendering any verdict'
        }
    }

    Context 'R5 the real client gets a truncated daemon answer' {
        BeforeAll {
            # Cut mid-object: the client's own JSON parse fails, it reads that as no answer, finds the
            # pipe PRESENT, and renders its honest 'incomplete' banner -- which the scanner does read.
            $script:R5 = Invoke-RvDaemonCase -Tag 'r5' -Response '{"ok":true,"action":"diagnos'
        }
        It 'R5 situation -- the real client failed to parse the answer and rendered its incomplete banner' {
            $script:R5.Requests | Should -Match '"action":"diagnostics"'
            $script:R5.ClientLog | Should -Match 'client error: '
            $script:R5.ClientLog | Should -Match 'emitted honest incomplete banner'
        }
        It 'R5 verdict -- the real client on a truncated daemon answer is NOT reported analyzed (already green)' {
            $script:R5.Result.Analyzed | Should -BeFalse -Because 'R5 verdict: the incomplete banner says NOT checked'
        }
    }

    Context 'R9 the real client gets a clean daemon answer' {
        BeforeAll {
            $script:R9 = Invoke-RvDaemonCase -Tag 'r9' -Response '{"ok":true,"action":"diagnostics","file":"","cached":false,"count":0,"omitted":0,"diagnostics":[],"scopeApplied":false,"scopeTotal":0,"scopeSurfaced":0,"path":"analyze","analysisMs":1,"codeActionMs":0,"recordCount":0,"correctionCount":0}'
        }
        It 'R9 situation -- the fake daemon was asked, and the real client rendered nothing' {
            $script:R9.Requests | Should -Match '"action":"diagnostics"'
            $script:R9.ClientLog | Should -Match 'no diagnostics'
        }
        It 'R9 verdict -- the real client on a clean daemon answer IS reported analyzed with zero findings (the control)' {
            $script:R9.Result.Analyzed | Should -BeTrue -Because 'R9 verdict: a clean answer is a completed analysis'
            @($script:R9.Result.Findings).Count | Should -Be 0
        }
    }
}

Describe 'Scan verdict at the CLI boundary with the shipped lsp-scan relocated beside fake hooks (dispatch 000302 A1)' -Skip:$script:SvUnsupported {

    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-scan-common.ps1')
        . (Join-Path $PSScriptRoot 'Integration.Common.ps1')
        . (Join-Path $PSScriptRoot 'ScanHarness.Common.ps1')
        $script:CvHost = Resolve-PsHost 'pwsh'
        if ($null -eq $script:CvHost) { throw 'no PowerShell host (pwsh / powershell) to run the relocated CLI' }
        $script:CvRoots = New-Object System.Collections.ArrayList

        function Invoke-CvCase {
            # One end-to-end run of the RELOCATED shipped CLI over a directory holding one target.
            # The child gets a hermetic environment: no CLAUDE_PLUGIN_OPTION_* / POWERSHELL_LSP_*
            # inherited, and its own data root.
            param([string]$Id, [string]$Fixture, [int]$TimeoutMs = 25000)
            $root = New-SvTempRoot -Tag ('cv' + $Id) -MintingFile 'tests/PowerShellLsp.ScanVerdict.Tests.ps1'
            [void]$script:CvRoots.Add($root)
            $tree = New-SvCliTree -Root $root -ClientFixture $Fixture
            $src = Join-Path $root 'src'
            New-Item -ItemType Directory -Force -Path $src | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $src ('target-' + $Id + '.ps1')),
                "function Get-CvTarget {`n    [CmdletBinding()]`n    param([string]`$Name)`n    Write-Output `$Name`n}`n",
                (New-Object System.Text.UTF8Encoding($false)))
            $data = Join-Path $root 'data'
            New-Item -ItemType Directory -Force -Path $data | Out-Null
            $sarifPath = Join-Path $root 'out.sarif'
            $run = Invoke-SvChildProcess -HostExe $script:CvHost -CapMs 180000 `
                -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $tree.ScanScript, $src,
                    '-Format', 'sarif', '-OutputPath', $sarifPath, '-PsHost', $script:CvHost, '-TimeoutMs', [string]$TimeoutMs) `
                -ExtraEnv @{ CLAUDE_PLUGIN_DATA = $data } -RemoveEnvPrefix @('CLAUDE_PLUGIN_OPTION_', 'POWERSHELL_LSP_')
            [void](Stop-SvChildFromPidFile -PidFile (Join-Path $data 'fake-child.pid'))
            $sarifText = Read-SvTextFile -Path $sarifPath
            $sarif = $null
            if (-not [string]::IsNullOrWhiteSpace($sarifText)) { $sarif = $sarifText | ConvertFrom-Json }
            $es = if ($null -ne $sarif) { [string][bool]$sarif.runs[0].invocations[0].executionSuccessful } else { 'no-sarif' }
            return @{
                Id      = $Id
                Run     = $run
                Tree    = $tree
                Sarif   = $sarif
                Verdict = ('exit=' + [int]$run.ExitCode + ' executionSuccessful=' + $es)
                Marker  = (Read-SvTextFile -Path (Join-Path $data 'fake-ran.txt'))
            }
        }

        function Assert-CvSituation {
            # The CLI ran to its emit stage (a SARIF log exists) and the fake child really ran.
            param($Case)
            $Case.Run.TimedOut | Should -BeFalse -Because ($Case.Id + ' situation: the CLI must finish')
            $Case.Sarif | Should -Not -BeNullOrEmpty -Because ($Case.Id + ' situation: the CLI must have written its SARIF log; stderr: ' + $Case.Run.Err)
            if ($Case.Id -ne 'S7') { $Case.Marker | Should -BeExactly $Case.Id -Because ($Case.Id + ' situation: the fake child must have run') }
        }
    }

    AfterAll {
        foreach ($r in @($script:CvRoots)) { Remove-SvTempRoot -Path $r }
    }

    It 'the relocated CLI is byte-identical to the shipped files it was copied from' {
        $repo = Split-Path -Parent $PSScriptRoot
        $root = New-SvTempRoot -Tag 'cvident' -MintingFile 'tests/PowerShellLsp.ScanVerdict.Tests.ps1'
        [void]$script:CvRoots.Add($root)
        $tree = New-SvCliTree -Root $root -ClientFixture 's9-clean-complete.ps1'
        @($tree.Copies).Count | Should -Be 4
        foreach ($copy in @($tree.Copies)) {
            $shipped = Get-SvSha256 -Path (Join-Path $repo $copy.Rel)
            $shipped | Should -Match '^[0-9A-F]{64}$'
            (Get-SvSha256 -Path (Join-Path $tree.Root $copy.Rel)) | Should -BeExactly $shipped
            [string]$copy.Sha256 | Should -BeExactly $shipped
        }
    }

    It 'C-S1 verdict -- a silent child makes the CLI exit 4 with executionSuccessful=false' -Tag 'ScanRed-A2' {
        $c = Invoke-CvCase -Id 'S1' -Fixture 's1-silent-exit-zero.ps1'
        Assert-CvSituation -Case $c
        $c.Verdict | Should -BeExactly 'exit=4 executionSuccessful=False' -Because 'C-S1 verdict: an unanalyzed file must make the scan INCOMPLETE'
    }
    It 'C-S2 verdict -- a nonzero child makes the CLI exit 4 with executionSuccessful=false' -Tag 'ScanRed-A2' {
        $c = Invoke-CvCase -Id 'S2' -Fixture 's2-nonzero-exit.ps1'
        Assert-CvSituation -Case $c
        $c.Verdict | Should -BeExactly 'exit=4 executionSuccessful=False' -Because 'C-S2 verdict: an unanalyzed file must make the scan INCOMPLETE'
    }
    It 'C-S3 verdict -- a stderr-only child makes the CLI exit 4 with executionSuccessful=false' -Tag 'ScanRed-A2' {
        $c = Invoke-CvCase -Id 'S3' -Fixture 's3-stderr-only.ps1'
        Assert-CvSituation -Case $c
        $c.Verdict | Should -BeExactly 'exit=4 executionSuccessful=False' -Because 'C-S3 verdict: an unanalyzed file must make the scan INCOMPLETE'
    }
    It 'C-S4 verdict -- a malformed child response makes the CLI exit 4 with executionSuccessful=false' -Tag 'ScanRed-A2' {
        $c = Invoke-CvCase -Id 'S4' -Fixture 's4-malformed-response.ps1'
        Assert-CvSituation -Case $c
        $c.Verdict | Should -BeExactly 'exit=4 executionSuccessful=False' -Because 'C-S4 verdict: an unanalyzed file must make the scan INCOMPLETE'
    }
    It 'C-S5 verdict -- a truncated record stream makes the CLI exit 4 with executionSuccessful=false' -Tag 'ScanRed-A2' {
        $c = Invoke-CvCase -Id 'S5' -Fixture 's5-truncated-record.ps1'
        Assert-CvSituation -Case $c
        $c.Verdict | Should -BeExactly 'exit=4 executionSuccessful=False' -Because 'C-S5 verdict: an unanalyzed file must make the scan INCOMPLETE'
    }
    It 'C-S5m verdict -- missing records make the CLI exit 4 with executionSuccessful=false' -Tag 'ScanRed-A2' {
        $c = Invoke-CvCase -Id 'S5m' -Fixture 's5m-missing-record.ps1'
        Assert-CvSituation -Case $c
        $c.Verdict | Should -BeExactly 'exit=4 executionSuccessful=False' -Because 'C-S5m verdict: an unanalyzed file must make the scan INCOMPLETE'
    }
    It 'C-S6 verdict -- a daemon ok=false child makes the CLI exit 4 with executionSuccessful=false' -Tag 'ScanRed-A2' {
        $c = Invoke-CvCase -Id 'S6' -Fixture 's6-daemon-error.ps1'
        Assert-CvSituation -Case $c
        $c.Verdict | Should -BeExactly 'exit=4 executionSuccessful=False' -Because 'C-S6 verdict: an unanalyzed file must make the scan INCOMPLETE'
    }
    It 'C-S7 verdict -- a deadline kill makes the CLI exit 4 with executionSuccessful=false (already green)' {
        $c = Invoke-CvCase -Id 'S7' -Fixture 's7-never-exits.ps1' -TimeoutMs 4000
        Assert-CvSituation -Case $c
        $c.Verdict | Should -BeExactly 'exit=4 executionSuccessful=False' -Because 'C-S7 verdict: an unanalyzed file must make the scan INCOMPLETE'
    }
    It 'C-S8 verdict -- a vanished source makes the CLI exit 4 with executionSuccessful=false' -Tag 'ScanRed-A2' {
        $c = Invoke-CvCase -Id 'S8' -Fixture 's8-source-gone.ps1'
        Assert-CvSituation -Case $c
        $c.Verdict | Should -BeExactly 'exit=4 executionSuccessful=False' -Because 'C-S8 verdict: an unanalyzed file must make the scan INCOMPLETE'
    }
    It 'C-S9 verdict -- a clean completed child makes the CLI exit 0 with executionSuccessful=true and no results (the control)' {
        $c = Invoke-CvCase -Id 'S9' -Fixture 's9-clean-complete.ps1'
        Assert-CvSituation -Case $c
        $c.Verdict | Should -BeExactly 'exit=0 executionSuccessful=True' -Because 'C-S9 verdict: a clean completed scan passes'
        @($c.Sarif.runs[0].results).Count | Should -Be 0
    }
}

Describe 'The expected-RED oracle accepts only the declared failures (dispatch 000302 A1)' {
    # tests/assert-expected-red.ps1 is the custom check that keeps the temporary exclusions honest.
    # It is proven here against SYNTHETIC suites written into a temp root (a committed *.Tests.ps1
    # would be discovered by the normal runner), each defective in exactly one way. The oracle runs in
    # a FRESH process every time -- the way the custom check runs it -- through the harness spawner.

    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')
        . (Join-Path $PSScriptRoot 'Integration.Common.ps1')
        . (Join-Path $PSScriptRoot 'ScanHarness.Common.ps1')
        $script:OrHost = Resolve-PsHost 'pwsh'
        $script:OrOracle = Join-Path $PSScriptRoot 'assert-expected-red.ps1'
        $script:OrRoot = New-SvTempRoot -Tag 'oracle' -MintingFile 'tests/PowerShellLsp.ScanVerdict.Tests.ps1'

        function Invoke-OrScenario {
            # Write one synthetic suite + manifest and run the oracle over it. $Body is the Describe
            # text; $Expected the manifest's Expected entries, as psd1 source text.
            param([string]$Name, [string]$Body, [string]$Expected, [string]$Tags = "@{ 'SynthRed' = 'synthetic owner' }")
            $dir = Join-Path $script:OrRoot $Name
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $dir 'Synthetic.Tests.ps1'), $Body, (New-Object System.Text.UTF8Encoding($false)))
            $manifest = "@{`n    Files = @('Synthetic.Tests.ps1')`n    Tags = " + $Tags + "`n    Expected = @(" + $Expected + ")`n}`n"
            $mPath = Join-Path $dir 'expected-red.psd1'
            [System.IO.File]::WriteAllText($mPath, $manifest, (New-Object System.Text.UTF8Encoding($false)))
            return (Invoke-SvChildProcess -HostExe $script:OrHost -CapMs 300000 `
                    -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:OrOracle,
                        '-ManifestPath', $mPath, '-TestsDir', $dir))
        }

        $script:OrRedBody = @'
Describe 'Synth' {
    It 'declared red' -Tag 'SynthRed' { $true | Should -BeFalse -Because 'synthetic declared red' }
    It 'declared red two' -Tag 'SynthRed' { 1 | Should -Be 2 -Because 'synthetic second red' }
    It 'plain green' { 1 | Should -Be 1 }
}
'@
        $script:OrExpected = @'

        @{ Path = 'Synth.declared red'; Name = 'declared red'; Tag = 'SynthRed'; Message = 'because synthetic declared red, but got \$true' }
        @{ Path = 'Synth.declared red two'; Name = 'declared red two'; Tag = 'SynthRed'; Message = 'because synthetic second red, but got 1' }

'@
    }

    AfterAll {
        Remove-SvTempRoot -Path $script:OrRoot
    }

    It 'ACCEPTS a suite whose tagged tests fail exactly as declared (the positive control)' {
        $r = Invoke-OrScenario -Name 'accept' -Body $script:OrRedBody -Expected $script:OrExpected
        $r.ExitCode | Should -Be 0 -Because ('oracle output: ' + $r.Out + $r.Err)
        $r.Out | Should -Match 'ACCEPTED'
    }

    It 'REJECTS an unexpected pass' {
        $body = $script:OrRedBody -replace '\$true \| Should -BeFalse', '$true | Should -BeTrue'
        $r = Invoke-OrScenario -Name 'pass' -Body $body -Expected $script:OrExpected
        $r.ExitCode | Should -Be 1 -Because ('oracle output: ' + $r.Out + $r.Err)
        $r.Out | Should -Match 'REJECT: UNEXPECTED PASSED: Synth\.declared red'
    }

    It 'REJECTS zero discovery (no test carries a manifest tag)' {
        $body = $script:OrRedBody -replace "-Tag 'SynthRed'", ''
        $r = Invoke-OrScenario -Name 'zero' -Body $body -Expected $script:OrExpected
        $r.ExitCode | Should -Be 1 -Because ('oracle output: ' + $r.Out + $r.Err)
        $r.Out | Should -Match 'REJECT: ZERO DISCOVERY'
    }

    It 'REJECTS a setup crash, even though every declared test then reads Failed' {
        $body = $script:OrRedBody -replace "Describe 'Synth' \{", "Describe 'Synth' {`n    BeforeAll { throw 'synthetic setup crash' }"
        $r = Invoke-OrScenario -Name 'crash' -Body $body -Expected $script:OrExpected
        $r.ExitCode | Should -Be 1 -Because ('oracle output: ' + $r.Out + $r.Err)
        $r.Out | Should -Match 'REJECT: BLOCK FAILED: Synth'
    }

    It 'REJECTS an unrelated failure (the right test failing on the wrong assertion)' {
        $body = $script:OrRedBody -replace '\$true \| Should -BeFalse -Because ''synthetic declared red''', 'throw ''some other failure'''
        $r = Invoke-OrScenario -Name 'unrelated' -Body $body -Expected $script:OrExpected
        $r.ExitCode | Should -Be 1 -Because ('oracle output: ' + $r.Out + $r.Err)
        $r.Out | Should -Match 'REJECT: UNRELATED FAILURE: Synth\.declared red'
    }

    It 'REJECTS a failing UNTAGGED test in the same files (a failure outside the exclusion)' {
        $body = $script:OrRedBody -replace "It 'plain green' \{ 1 \| Should -Be 1 \}", "It 'plain green' { 1 | Should -Be 3 }"
        $r = Invoke-OrScenario -Name 'untaggedfail' -Body $body -Expected $script:OrExpected
        $r.ExitCode | Should -Be 1 -Because ('oracle output: ' + $r.Out + $r.Err)
        $r.Out | Should -Match 'REJECT: UNRELATED FAILURE: Synth\.plain green -- an UNTAGGED test ended Failed'
    }

    It 'REJECTS a tagged test the manifest does not declare (a wider exclusion)' {
        $body = $script:OrRedBody -replace "It 'plain green' \{", "It 'plain green' -Tag 'SynthRed' {"
        $r = Invoke-OrScenario -Name 'undeclared' -Body $body -Expected $script:OrExpected
        $r.ExitCode | Should -Be 1 -Because ('oracle output: ' + $r.Out + $r.Err)
        $r.Out | Should -Match 'REJECT: UNDECLARED: Synth\.plain green'
    }

    It 'REJECTS a declared test that no longer exists' {
        $extra = $script:OrExpected + "        @{ Path = 'Synth.gone'; Name = 'gone'; Tag = 'SynthRed'; Message = 'x' }`n"
        $r = Invoke-OrScenario -Name 'missing' -Body $script:OrRedBody -Expected $extra
        $r.ExitCode | Should -Be 1 -Because ('oracle output: ' + $r.Out + $r.Err)
        $r.Out | Should -Match 'REJECT: MISSING: Synth\.gone'
    }
}

Describe 'Temporary RED exclusions are exactly the manifest (dispatch 000302 A1)' {
    # The normal runner excludes the RED tags (tests/run-tests.ps1 -ExcludeTag default). This guard
    # keeps that exclusion NARROW: the tags may sit only on It blocks (a Describe or Context tag would
    # silently exclude every test inside it), only on the tests the manifest declares, only as
    # literals, and the runner must exclude exactly the manifest's tags. The oracle proves the
    # declared tests still FAIL; this proves nothing else is hiding behind the same tags.

    BeforeAll {
        $script:ExManifestPath = Join-Path $PSScriptRoot 'fixtures/scan-verdict/expected-red.psd1'
        $script:ExManifest = Import-PowerShellDataFile -LiteralPath $script:ExManifestPath
        $script:ExTags = @($script:ExManifest.Tags.Keys | ForEach-Object { [string]$_ } | Sort-Object)

        # Every tag use under tests/, recursively -- a *.Tests.ps1 anywhere below tests/ is discovered.
        $script:ExUses = New-Object System.Collections.ArrayList
        $script:ExParseErrors = New-Object System.Collections.ArrayList
        foreach ($f in @(Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File -Filter '*.Tests.ps1')) {
            $tok = $null; $errs = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tok, [ref]$errs)
            foreach ($e in @($errs)) { [void]$script:ExParseErrors.Add($f.Name + ': ' + $e.Message) }
            $cmds = @($ast.FindAll({
                        param($n)
                        $n -is [System.Management.Automation.Language.CommandAst] -and
                        (@('Describe', 'Context', 'It') -contains [string]$n.GetCommandName())
                    }, $true))
            foreach ($c in $cmds) {
                $els = $c.CommandElements
                for ($i = 1; $i -lt $els.Count; $i++) {
                    $el = $els[$i]
                    if (-not ($el -is [System.Management.Automation.Language.CommandParameterAst])) { continue }
                    if ([string]$el.ParameterName -ne 'Tag') { continue }
                    $valueAst = if ($null -ne $el.Argument) { $el.Argument } elseif (($i + 1) -lt $els.Count) { $els[$i + 1] } else { $null }
                    $strings = @()
                    $dynamic = $true
                    if ($null -ne $valueAst) {
                        $consts = @($valueAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true))
                        $vars = @($valueAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true))
                        $strings = @($consts | ForEach-Object { [string]$_.Value })
                        $dynamic = ($vars.Count -gt 0 -or $consts.Count -eq 0)
                    }
                    $title = ''
                    for ($j = 1; $j -lt $els.Count; $j++) {
                        if ($els[$j] -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $title = [string]$els[$j].Value; break }
                    }
                    [void]$script:ExUses.Add([pscustomobject]@{
                            File    = $f.Name
                            Kind    = [string]$c.GetCommandName()
                            Title   = $title
                            Tags    = $strings
                            Dynamic = $dynamic
                            Line    = $c.Extent.StartLineNumber
                        })
                }
            }
        }
    }

    It 'the manifest declares the two owner tags and a non-empty expected set' {
        ($script:ExTags -join ',') | Should -BeExactly 'ScanRed-A2,ScanRed-A3'
        @($script:ExManifest.Expected).Count | Should -BeGreaterThan 0
        foreach ($t in $script:ExTags) { [string]$script:ExManifest.Tags[$t] | Should -Match '^A[23] -- ' }
    }

    It 'every test file parses (the census reads real code)' {
        ($script:ExParseErrors.ToArray() -join '; ') | Should -BeExactly ''
        @($script:ExUses).Count | Should -BeGreaterThan 0 -Because 'the census must find the RED tags it guards'
    }

    It 'no tag anywhere is computed at run time -- an exclusion must be readable from the source' {
        $dyn = @($script:ExUses | Where-Object { $_.Dynamic } | ForEach-Object { $_.File + ':' + $_.Line })
        ($dyn -join '; ') | Should -BeExactly ''
    }

    It 'a RED tag sits only on It blocks, never on a Describe or Context' {
        $bad = @($script:ExUses | Where-Object {
                $u = $_
                $_.Kind -ne 'It' -and @($u.Tags | Where-Object { $script:ExTags -contains $_ }).Count -gt 0
            } | ForEach-Object { $_.File + ':' + $_.Line + ' ' + $_.Kind })
        ($bad -join '; ') | Should -BeExactly ''
    }

    It 'every RED-tagged It is declared in the manifest, and every declared It exists with its tag' {
        $inSource = @($script:ExUses | ForEach-Object {
                $u = $_
                foreach ($t in @($u.Tags | Where-Object { $script:ExTags -contains $_ })) { $u.File + '|' + $t + '|' + $u.Title }
            } | Sort-Object -Unique)
        $declared = @($script:ExManifest.Expected | ForEach-Object { [string]$_.File + '|' + [string]$_.Tag + '|' + [string]$_.Name } | Sort-Object -Unique)
        $extra = @($inSource | Where-Object { $declared -notcontains $_ })
        $missing = @($declared | Where-Object { $inSource -notcontains $_ })
        ('undeclared: ' + ($extra -join '; ')) | Should -BeExactly 'undeclared: '
        ('missing: ' + ($missing -join '; ')) | Should -BeExactly 'missing: '
    }

    It 'tests/run-tests.ps1 excludes exactly the manifest tags by default' {
        $tok = $null; $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'run-tests.ps1'), [ref]$tok, [ref]$errs)
        @($errs).Count | Should -Be 0
        $param = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'ExcludeTag' })
        $param.Count | Should -Be 1
        $defaults = @($param[0].DefaultValue.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) |
                ForEach-Object { [string]$_.Value } | Sort-Object)
        ($defaults -join ',') | Should -BeExactly ($script:ExTags -join ',')
    }
}
