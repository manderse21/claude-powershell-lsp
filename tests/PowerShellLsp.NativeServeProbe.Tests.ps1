#Requires -Version 5.1

# Native-serve REMOVABILITY probe -- e2e (dispatch 000104, the 000103 OQ4 next_suggested). Drives
# the DIRECT launcher (scripts/pses-stdio.ps1, shim BYPASSED) through the SHIPPED runtime path --
# the doctor's Get-DoctorNativeServeObservation, which spawns scripts/probe-native-serve.ps1 as a
# pwsh subprocess -- and asserts the removability signal. Today's truthful answer is STILL GATED:
# under a Claude-Code-shaped rich-caps client (dynamicRegistration=true) PSES v4.6.0 defers the nav
# providers to a client/registerCapability handshake (the #1359 gate), so the initialize RESULT
# carries no static nav.
#
# ONE PSES at a time, in this Describe's own BeforeAll, torn down before anything else -- the 000101
# serialization lesson (never N daemons concurrently; the constrained Windows PowerShell 5.1 CI leg
# flakes on the startup spike). The interactive client<->PSES stdio is driven INSIDE the pwsh
# subprocess (the driver), so the leg's Pester -- pwsh or 5.1 -- only spawns it and reads a result
# file (the 000103 5.1-stdin lesson: a 5.1 host's interactive writes to a child's stdin do not
# deliver on the headless windows-powershell runner). The pure decision (Test-DoctorNativeServe) is
# separately unit-tested under 5.1 in PowerShellLsp.Unit.Tests.ps1.
#
# ASCII-only (PS 5.1 em-dash trap). Author: Mike Andersen / powershell-lsp plugin.

$script:OnWindows = if (Test-Path 'Variable:\IsWindows') { [bool]$IsWindows } else { $true }
$script:OnLinux = (Test-Path 'Variable:\IsLinux') -and [bool]$IsLinux
$script:OnMacOS = (Test-Path 'Variable:\IsMacOS') -and [bool]$IsMacOS
$script:SkipProbe = -not ($script:OnWindows -or $script:OnLinux -or $script:OnMacOS)

Describe 'Native-serve removability probe e2e: the direct launcher is still #1359-gated today' -Skip:$script:SkipProbe {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        . (Join-Path $repoRoot 'scripts/lib/lsp-common.ps1')
        . (Join-Path $PSScriptRoot 'ServeShim.Common.ps1')   # Initialize-ServeShimEnv: idempotent PSES/PSSA bootstrap + scratch data root
        . (Join-Path $repoRoot 'scripts/doctor.ps1')          # the SHIPPED probe path (dot-source safe: loads funcs, runs no checks)
        # Bootstrap PSES/PSSA into a scratch data root for its SIDE EFFECT: it sets
        # $env:CLAUDE_PLUGIN_DATA, which Get-DoctorNativeServeObservation reads via Get-PluginDataRoot.
        Initialize-ServeShimEnv -TestsDir $PSScriptRoot | Out-Null

        # Report-only proof: the probe must mutate NOTHING in the repo tree. Snapshot the git
        # porcelain before and after; equal == the probe wrote nothing tracked (it writes only to the
        # scratch data root + a temp result file, both OUTSIDE the repo). Robust to a dirty dev tree
        # (assert before == after, not clean); on a clean CI checkout both are empty.
        $script:PorcelainBefore = @(& git -C $repoRoot status --porcelain 2>$null)
        $script:NSObs = Get-DoctorNativeServeObservation -ScriptsDir (Join-Path $repoRoot 'scripts') -InitTimeoutMs 20000
        $script:PorcelainAfter = @(& git -C $repoRoot status --porcelain 2>$null)
        $script:NSResult = Test-DoctorNativeServe -Determinable $script:NSObs.Determinable -Reason $script:NSObs.Reason `
            -InitReceived $script:NSObs.InitReceived -HasStaticNav $script:NSObs.HasStaticNav -ProbeError $script:NSObs.Error `
            -ElapsedMs $script:NSObs.ElapsedMs -TimeoutMs 20000
        Write-Host ('[native-serve probe] determinable=' + $script:NSObs.Determinable + ' initReceived=' + $script:NSObs.InitReceived +
            ' staticNav=' + $script:NSObs.HasStaticNav + ' initMs=' + $script:NSObs.ElapsedMs + " error='" + $script:NSObs.Error + "'")
    }

    It 'the probe could run (data root + bootstrapped PSES + pwsh all present)' {
        $script:NSObs.Determinable | Should -BeTrue -Because ('the e2e bootstraps PSES into a scratch data root; error: ' + $script:NSObs.Error)
    }
    It 'the DIRECT launcher (pses-stdio.ps1) returned an initialize result -- PSES starts and inits under a CC-shaped client' {
        $script:NSObs.InitReceived | Should -BeTrue -Because ('the direct launcher must reach an init result within the bound; error: ' + $script:NSObs.Error)
        $script:NSObs.Error | Should -BeExactly ''
    }
    It 'the init result carries NO static nav -- native serve is STILL GATED on the #1359 handshake (today)' {
        # The load-bearing today assertion: under rich dynamicRegistration=true caps PSES v4.6.0
        # defers the nav providers to client/registerCapability, so the static init result has no
        # hover/definition/references. This is the same signal the ServeShim off-mode e2e asserts,
        # here proven against the DIRECT launcher. Adversarial: were this true, the shim would be
        # removable -- that flip is the whole point of the probe and must not read true on today's
        # pinned PSES + client pair.
        $script:NSObs.HasStaticNav | Should -BeFalse -Because 'pinned PSES v4.6.0 defers nav to the registerCapability handshake the upstream #1359 client bug breaks'
    }
    It 'the doctor decision maps that to PASS "still gated" -- report-only, never a fail' {
        $script:NSResult.Status | Should -Be 'pass'
        $script:NSResult.Status | Should -Not -Be 'fail'
        $script:NSResult.Detail | Should -Match 'still GATED'
    }
    It 'the probe mutated NOTHING in the repo tree (report-only contract)' {
        ($script:PorcelainAfter -join "`n") | Should -BeExactly ($script:PorcelainBefore -join "`n") -Because 'the probe writes only to the scratch data root + a temp result file, both outside the repo'
    }
}
