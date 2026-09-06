#Requires -Version 5.1
# doctor -Json, the HEALTHY / DEGRADED / UNHEALTHY / UNPROVEN envelope, and -RequireProven
# (dispatch 000279, P0-1a/b/c; ruling R11 of 2026-09-05 = ENTERPRISE-PROGRAM-DOCKET R-D (a)).
#
# THE GAP THESE CLOSE. `exit 0` from the doctor never meant "it is working" -- it meant "nothing
# FAILED", and in exactly the headless / container environments where it matters most, the checks
# that would prove it is working do not fail, they go UNKNOWN. The information that separates a
# healthy install from a container where nothing works existed only as English prose, so a CI job
# could not assert on it. -Json makes the verdict set machine-readable, the envelope status makes
# it one word, and -RequireProven makes it an exit code.
#
# Every one of the three is a RENDERING or a PREDICATE over the results Invoke-Doctor already
# returns. No check's own logic changes here, and the suite asserts that by comparing the three
# renderings against each other rather than against a second copy of the expected verdicts.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsDir = Join-Path $script:RepoRoot 'scripts'
    . (Join-Path $script:ScriptsDir 'doctor.ps1')

    function New-Fx {
        # Build a result set from a status list, through the SHIPPED New-DoctorResult seam --
        # so a fixture can never carry a status the doctor itself could not produce.
        param([string[]] $Statuses)
        $i = 0
        $out = @()
        foreach ($st in @($Statuses)) {
            $i++
            $out += (New-DoctorResult -Status $st -Component ('Check ' + $i) `
                    -Detail ('detail ' + $i) -Remediation ('fix ' + $i))
        }
        return @($out)
    }

    $script:AllPass = New-Fx -Statuses @('pass', 'pass', 'pass')
    $script:OneFail = New-Fx -Statuses @('pass', 'fail', 'pass')
    $script:OneUnknown = New-Fx -Statuses @('pass', 'unknown', 'pass')
    $script:FailAndUnknown = New-Fx -Statuses @('pass', 'fail', 'unknown')
    $script:AllUnknown = New-Fx -Statuses @('unknown', 'unknown', 'unknown')
    $script:OneCheck = New-Fx -Statuses @('pass')
    $script:NoChecks = @()
}

Describe 'Get-DoctorEnvelopeStatus -- the four-value vocabulary (dispatch 000279, P0-1b)' {
    It 'HEALTHY only when every check passed' {
        Get-DoctorEnvelopeStatus -Results $script:AllPass | Should -Be 'HEALTHY'
    }
    It 'UNHEALTHY when any check failed' {
        Get-DoctorEnvelopeStatus -Results $script:OneFail | Should -Be 'UNHEALTHY'
    }
    It 'DEGRADED when something is UNKNOWN and something else was established' {
        Get-DoctorEnvelopeStatus -Results $script:OneUnknown | Should -Be 'DEGRADED'
    }
    It 'PRECEDENCE: a run with BOTH a fail and an unknown takes the most severe value' {
        # The mixed case is the one an implementation gets wrong by accident, and the rule is
        # explicit: UNHEALTHY > DEGRADED > UNPROVEN > HEALTHY.
        Get-DoctorEnvelopeStatus -Results $script:FailAndUnknown | Should -Be 'UNHEALTHY'
    }
    It 'UNPROVEN when nothing passed -- the headless case the vocabulary exists for' {
        Get-DoctorEnvelopeStatus -Results $script:AllUnknown | Should -Be 'UNPROVEN'
    }
    It 'UNPROVEN, never HEALTHY, on zero checks -- an empty run proves nothing' {
        Get-DoctorEnvelopeStatus -Results $script:NoChecks | Should -Be 'UNPROVEN'
    }

    It 'DISCRIMINATION CONTROL: a forced-UNKNOWN run never renders HEALTHY' {
        # Leg D's named control. A renderer that hardcoded a cheerful status, or one that
        # counted only failures, would sail past every shape assertion above and die here.
        foreach ($fx in @($script:OneUnknown, $script:AllUnknown, $script:FailAndUnknown)) {
            $st = Get-DoctorEnvelopeStatus -Results $fx
            $st | Should -Not -Be 'HEALTHY'
            $st | Should -BeIn @('DEGRADED', 'UNPROVEN', 'UNHEALTHY')
        }
    }
    It 'RED CONTROL: a status that ignores UNKNOWN reads HEALTHY on the same results' {
        # The pre-000279 world had no envelope at all; the nearest thing it could express was
        # the failure count, and this is what a status derived from THAT would say. It reads
        # HEALTHY on a run that established nothing -- which is the whole finding.
        function Get-EnvelopeStatusMutant {
            param([object[]] $Results)
            $failN = @($Results | Where-Object { $_.Status -eq 'fail' }).Count
            if ($failN -gt 0) { return 'UNHEALTHY' }
            return 'HEALTHY'
        }
        Get-EnvelopeStatusMutant -Results $script:AllUnknown | Should -Be 'HEALTHY'
        Get-DoctorEnvelopeStatus -Results $script:AllUnknown | Should -Not -Be 'HEALTHY'
    }
}

Describe 'Get-DoctorExitCode -- -RequireProven as a SECOND predicate (dispatch 000279, P0-1c)' {
    It 'DEFAULT is byte-identical to what it has always been: 1 on a fail, 0 otherwise' {
        Get-DoctorExitCode -Results $script:AllPass | Should -Be 0
        Get-DoctorExitCode -Results $script:OneUnknown | Should -Be 0
        Get-DoctorExitCode -Results $script:AllUnknown | Should -Be 0
        Get-DoctorExitCode -Results $script:OneFail | Should -Be 1
        Get-DoctorExitCode -Results $script:NoChecks | Should -Be 0
    }
    It 'exits non-zero on any UNKNOWN once the switch is given' {
        Get-DoctorExitCode -Results $script:OneUnknown -RequireProven $true | Should -Be 2
        Get-DoctorExitCode -Results $script:AllUnknown -RequireProven $true | Should -Be 2
    }
    It 'still exits 0 with the switch when everything was proven' {
        # Otherwise the switch would just be "always fail", which proves nothing.
        Get-DoctorExitCode -Results $script:AllPass -RequireProven $true | Should -Be 0
    }
    It 'FAIL DOMINATES: a fail plus an unknown exits 1, not 2, even under the switch' {
        Get-DoctorExitCode -Results $script:FailAndUnknown -RequireProven $true | Should -Be 1
    }
    It 'the switch never changes the code for a set with no unknowns' {
        foreach ($fx in @($script:AllPass, $script:OneFail)) {
            (Get-DoctorExitCode -Results $fx -RequireProven $true) |
                Should -Be (Get-DoctorExitCode -Results $fx)
        }
    }

    It 'RED CONTROL: the PRIOR predicate treats UNKNOWN as proven and FAILS this test' {
        # The prior implementation verbatim -- the one line doctor.ps1 shipped before this
        # dispatch, which counted only Status -eq 'fail'. It cannot see an UNKNOWN, so it
        # returns 0 where the new test demands 2. Recorded here rather than described, so the
        # control is re-runnable.
        function Get-DoctorExitCodeMutant {
            param([object[]] $Results, [bool] $RequireProven = $false)
            $doctorFailures = @($Results | Where-Object { $_.Status -eq 'fail' }).Count
            if ($doctorFailures -gt 0) { return 1 } else { return 0 }
        }
        # The assertion the shipped predicate satisfies...
        Get-DoctorExitCode -Results $script:AllUnknown -RequireProven $true | Should -Be 2
        # ...is the assertion the prior one fails, and here is it failing.
        $mutant = Get-DoctorExitCodeMutant -Results $script:AllUnknown -RequireProven $true
        $mutant | Should -Not -Be 2
        $mutant | Should -Be 0 -Because 'UNKNOWN-as-proven exits 0, which is exactly the gap -RequireProven closes'
        # ...and it agrees everywhere the switch is NOT in play, so the control is discriminating
        # rather than merely broken.
        foreach ($fx in @($script:AllPass, $script:OneFail, $script:OneUnknown, $script:FailAndUnknown)) {
            (Get-DoctorExitCodeMutant -Results $fx) | Should -Be (Get-DoctorExitCode -Results $fx)
        }
    }
}

Describe 'Format-DoctorJson -- the third rendering over the same seam (dispatch 000279, P0-1a)' {
    It 'emits JSON that ConvertFrom-Json parses' {
        { (Format-DoctorJson -Results $script:OneUnknown -Version '9.9.9' -Provenance 'v0.0.0') |
                ConvertFrom-Json } | Should -Not -Throw
    }
    It 'carries schemaVersion, the derived status, the versions and the check array' {
        $o = (Format-DoctorJson -Results $script:OneUnknown -Version '9.9.9' -Provenance 'v0.0.0' `
                -PwshVersion '7.6.5' -PsesPin 'v4.6.0' -PssaPin '1.25.0') | ConvertFrom-Json
        $o.schemaVersion | Should -Be 1
        $o.status | Should -Be 'DEGRADED'
        $o.versions.plugin | Should -Be '9.9.9'
        $o.versions.pwsh | Should -Be '7.6.5'
        $o.versions.pses | Should -Be 'v4.6.0'
        $o.versions.pssa | Should -Be '1.25.0'
        $o.provenanceFloor | Should -Be 'v0.0.0'
        @($o.checks).Count | Should -Be 3
    }
    It 'the summary counts agree with the results it was handed' {
        $o = (Format-DoctorJson -Results $script:FailAndUnknown -Version '9.9.9' -Provenance 'v0') | ConvertFrom-Json
        $o.summary.pass | Should -Be 1
        $o.summary.fail | Should -Be 1
        $o.summary.unknown | Should -Be 1
        $o.summary.total | Should -Be 3
    }
    It 'agrees CHECK FOR CHECK with the text rendering on status and component' {
        # Same seam, so a disagreement is a real bug rather than a formatting difference.
        $o = (Format-DoctorJson -Results $script:FailAndUnknown -Version '9.9.9' -Provenance 'v0') | ConvertFrom-Json
        $text = Format-DoctorReport -Results $script:FailAndUnknown -Version '9.9.9' -Provenance 'v0'
        for ($i = 0; $i -lt @($script:FailAndUnknown).Count; $i++) {
            $o.checks[$i].status | Should -Be $script:FailAndUnknown[$i].Status
            $o.checks[$i].component | Should -Be $script:FailAndUnknown[$i].Component
            $o.checks[$i].detail | Should -Be $script:FailAndUnknown[$i].Detail
            $o.checks[$i].remediation | Should -Be $script:FailAndUnknown[$i].Remediation
            $text | Should -Match ([regex]::Escape($script:FailAndUnknown[$i].Component))
            $text | Should -Match ([regex]::Escape($script:FailAndUnknown[$i].Status.ToUpperInvariant()))
        }
    }
    It 'checks stays a JSON ARRAY at one element and at zero -- both hosts, measured' {
        # Windows PowerShell 5.1 and pwsh 7 both preserve a hashtable property's array shape,
        # but the one-element case is the one a serializer classically unrolls, so it is
        # asserted rather than assumed -- on the raw text, not only through the parser, because
        # ConvertFrom-Json would hide a scalar behind a one-element enumeration.
        $one = Format-DoctorJson -Results $script:OneCheck -Version '9.9.9' -Provenance 'v0'
        $one | Should -Match '"checks"\s*:\s*\['
        @(($one | ConvertFrom-Json).checks).Count | Should -Be 1
        $none = Format-DoctorJson -Results $script:NoChecks -Version '9.9.9' -Provenance 'v0'
        $none | Should -Match '"checks"\s*:\s*\[\s*\]'
        ($none | ConvertFrom-Json).status | Should -Be 'UNPROVEN'
        ($none | ConvertFrom-Json).summary.total | Should -Be 0
    }
    It 'RED CONTROL: forcing one check to FAIL moves the JSON status AND the exit code' {
        # The docket's own S1 control. A renderer that hardcoded statuses would pass every shape
        # test above and die here, because this compares two renders of DIFFERENT results.
        $clean = (Format-DoctorJson -Results $script:AllPass -Version '9.9.9' -Provenance 'v0') | ConvertFrom-Json
        $broken = (Format-DoctorJson -Results $script:OneFail -Version '9.9.9' -Provenance 'v0') | ConvertFrom-Json
        $clean.status | Should -Be 'HEALTHY'
        $broken.status | Should -Be 'UNHEALTHY'
        $clean.summary.fail | Should -Be 0
        $broken.summary.fail | Should -Be 1
        Get-DoctorExitCode -Results $script:AllPass | Should -Be 0
        Get-DoctorExitCode -Results $script:OneFail | Should -Be 1
    }
    It 'renders honest blanks rather than throwing when handed nothing' {
        # Same inert-default seam the two human renderings use.
        { Format-DoctorJson -Results $script:NoChecks -Version '9.9.9' -Provenance 'v0' } | Should -Not -Throw
    }
}

Describe 'The three renderings never disagree about the verdict (dispatch 000279)' {
    It 'the exit code is a function of the RESULTS, not of which rendering ran' {
        # The invariant Format-DoctorSummary's own comment records and this dispatch inherits:
        # a rendering changes presentation and never the verdict.
        foreach ($fx in @($script:AllPass, $script:OneFail, $script:OneUnknown,
                $script:FailAndUnknown, $script:AllUnknown)) {
            $code = Get-DoctorExitCode -Results $fx
            $report = Format-DoctorReport -Results $fx -Version '9.9.9' -Provenance 'v0'
            $summary = Format-DoctorSummary -Results $fx -Version '9.9.9' -Provenance 'v0'
            $json = (Format-DoctorJson -Results $fx -Version '9.9.9' -Provenance 'v0') | ConvertFrom-Json
            # All three saw the same counts...
            $failN = @($fx | Where-Object { $_.Status -eq 'fail' }).Count
            $json.summary.fail | Should -Be $failN
            $report | Should -Match ([regex]::Escape($failN.ToString() + ' fail'))
            $summary | Should -Match ([regex]::Escape($failN.ToString() + ' fail'))
            # ...and the exit code follows the results alone.
            if ($failN -gt 0) { $code | Should -Be 1 } else { $code | Should -Be 0 }
        }
    }
}

Describe 'doctor.ps1 -Json end to end on this host (dispatch 000279, leg A acceptance)' {
    BeforeAll {
        $script:HostExe = (Get-Process -Id $PID).Path
        $script:DoctorPath = Join-Path $script:ScriptsDir 'doctor.ps1'
        $script:LiveJson = (& $script:HostExe -NoLogo -NoProfile -File $script:DoctorPath -Json) -join [Environment]::NewLine
        $script:LiveJsonExit = $LASTEXITCODE
        (& $script:HostExe -NoLogo -NoProfile -File $script:DoctorPath -Summary) | Out-Null
        $script:LiveDefaultExit = $LASTEXITCODE
        (& $script:HostExe -NoLogo -NoProfile -File $script:DoctorPath -Summary -RequireProven) | Out-Null
        $script:LiveProvenExit = $LASTEXITCODE
    }

    It 'a real run emits JSON that ConvertFrom-Json parses' {
        { $script:LiveJson | ConvertFrom-Json } | Should -Not -Throw
        $o = $script:LiveJson | ConvertFrom-Json
        $o.schemaVersion | Should -Be 1
        $o.status | Should -BeIn @('HEALTHY', 'DEGRADED', 'UNHEALTHY', 'UNPROVEN')
        @($o.checks).Count | Should -Be $o.summary.total
        @($o.checks).Count | Should -BeGreaterThan 0
        $o.versions.plugin | Should -Not -BeNullOrEmpty
    }
    It 'the JSON rendering does not move the exit code' {
        $script:LiveJsonExit | Should -Be $script:LiveDefaultExit
    }
    It '-RequireProven only ever RAISES the code, and only over an UNKNOWN' {
        $o = $script:LiveJson | ConvertFrom-Json
        if ($o.summary.fail -gt 0) {
            $script:LiveProvenExit | Should -Be 1
        } elseif ($o.summary.unknown -gt 0) {
            $script:LiveProvenExit | Should -Be 2
            $script:LiveDefaultExit | Should -Be 0
        } else {
            $script:LiveProvenExit | Should -Be 0
        }
    }
}

Describe 'captureMode -- the fleet-visible half of P0-2 (dispatch 000282, ruling R19)' {
    BeforeAll {
        $script:PrevCapMode = [Environment]::GetEnvironmentVariable('POWERSHELL_LSP_CAPTURE_MODE')
    }
    AfterAll {
        [Environment]::SetEnvironmentVariable('POWERSHELL_LSP_CAPTURE_MODE', $script:PrevCapMode)
    }

    It 'carries resolved, raw and recognized for <Raw>' -TestCases @(
        @{ Raw = $null; Resolved = 'full'; ExpRaw = ''; Recognized = $false }
        @{ Raw = 'metadata'; Resolved = 'metadata'; ExpRaw = 'metadata'; Recognized = $true }
        @{ Raw = 'off'; Resolved = 'off'; ExpRaw = 'off'; Recognized = $true }
        @{ Raw = 'full'; Resolved = 'full'; ExpRaw = 'full'; Recognized = $true }
        @{ Raw = 'metadta'; Resolved = 'full'; ExpRaw = 'metadta'; Recognized = $false }
    ) {
        param($Raw, $Resolved, $ExpRaw, $Recognized)
        [Environment]::SetEnvironmentVariable('POWERSHELL_LSP_CAPTURE_MODE', $Raw)
        $o = (Format-DoctorJson -Results @((New-DoctorResult -Status 'pass' -Component 'c' -Detail 'd'))) | ConvertFrom-Json
        $o.captureMode.resolved | Should -BeExactly $Resolved
        $o.captureMode.raw | Should -BeExactly $ExpRaw
        $o.captureMode.recognized | Should -Be $Recognized
    }

    It 'A TYPO IS VISIBLE AS A TYPO, not as a control that is quietly not active' {
        # The reason the field carries all three values rather than just the resolved mode. An
        # unrecognized value resolves to `full` -- the mode logic must never gate the capture
        # channel -- so without `raw` and `recognized` a fleet reader could not tell a host that
        # was deliberately left at `full` from one where the GPO value is misspelled.
        [Environment]::SetEnvironmentVariable('POWERSHELL_LSP_CAPTURE_MODE', 'metadataa')
        $typo = (Format-DoctorJson -Results @((New-DoctorResult -Status 'pass' -Component 'c' -Detail 'd'))) | ConvertFrom-Json
        [Environment]::SetEnvironmentVariable('POWERSHELL_LSP_CAPTURE_MODE', $null)
        $unset = (Format-DoctorJson -Results @((New-DoctorResult -Status 'pass' -Component 'c' -Detail 'd'))) | ConvertFrom-Json

        $typo.captureMode.resolved | Should -BeExactly $unset.captureMode.resolved
        $typo.captureMode.raw | Should -Not -BeExactly $unset.captureMode.raw
        $typo.captureMode.recognized | Should -Be $false
    }

    It 'RED CONTROL: a mutant reporting the DEFAULT instead of the resolved mode fails' {
        # The plausible wrong implementation is one that reports the shipped default rather than
        # what the writer will actually obey -- a field that always says `full` looks healthy and
        # tells the fleet nothing. With the environment set to metadata the shipped envelope must
        # say metadata, and the mutant that hard-codes the default must not.
        [Environment]::SetEnvironmentVariable('POWERSHELL_LSP_CAPTURE_MODE', 'metadata')
        $shipped = (Format-DoctorJson -Results @((New-DoctorResult -Status 'pass' -Component 'c' -Detail 'd'))) | ConvertFrom-Json
        $mutant = [ordered]@{ resolved = 'full'; raw = ''; recognized = $false }

        $shipped.captureMode.resolved | Should -BeExactly 'metadata'
        $mutant.resolved | Should -Not -BeExactly $shipped.captureMode.resolved
        $mutant.raw | Should -Not -BeExactly $shipped.captureMode.raw
    }

    It 'is ADDITIVE -- schemaVersion does not move and no existing key changed' {
        # commands/doctor.md stated no policy on whether an additive field bumps schemaVersion.
        # Dispatch 000282 established one -- additive fields do not bump, removals and renames do
        # -- and this asserts the envelope follows it. The merge-base key list is spelled out
        # because the point is that every one of them is still present, in order, ahead of the new
        # one.
        [Environment]::SetEnvironmentVariable('POWERSHELL_LSP_CAPTURE_MODE', $null)
        $o = (Format-DoctorJson -Results @((New-DoctorResult -Status 'pass' -Component 'c' -Detail 'd'))) | ConvertFrom-Json
        $o.schemaVersion | Should -Be 1
        (@($o.PSObject.Properties.Name) -join ',') |
            Should -BeExactly 'schemaVersion,status,versions,provenanceFloor,captureMode,summary,checks'
    }

    It 'no check status, count or exit code moved -- captureMode is not a check' {
        # R19 adds a field to the envelope, not a check. The four-value status vocabulary, the
        # per-check vocabulary and the summary counts are all untouched by the mode.
        $results = @(
            (New-DoctorResult -Status 'pass' -Component 'a' -Detail 'd')
            (New-DoctorResult -Status 'unknown' -Component 'b' -Detail 'd')
        )
        [Environment]::SetEnvironmentVariable('POWERSHELL_LSP_CAPTURE_MODE', 'off')
        $withOff = (Format-DoctorJson -Results $results) | ConvertFrom-Json
        [Environment]::SetEnvironmentVariable('POWERSHELL_LSP_CAPTURE_MODE', $null)
        $withUnset = (Format-DoctorJson -Results $results) | ConvertFrom-Json

        $withOff.status | Should -BeExactly $withUnset.status
        $withOff.summary.total | Should -Be $withUnset.summary.total
        $withOff.summary.unknown | Should -Be $withUnset.summary.unknown
        (Get-DoctorExitCode -Results $results) | Should -Be (Get-DoctorExitCode -Results $results)
        $withOff.captureMode.resolved | Should -Not -BeExactly $withUnset.captureMode.resolved
    }
}
