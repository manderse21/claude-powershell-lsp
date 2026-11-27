#Requires -Version 5.1

# The test runner's exit code is the suite verdict (dispatch 000313, track T2; ruling ER1-R3;
# enterprise-review finding ER-F08).
#
# THE DEFECT. tests/run-tests.ps1 ended in `exit $result.FailedCount`. Its exit code is the verdict
# for CI, for the hub's smoke_test and for every targeted check, and a count is not a verdict: a
# -FullNameFilter that selected nothing exited 0, a test file that failed at discovery exited 0 (no
# TEST failed), and on Linux and macOS 256 failed tests exited 0 (an exit status is one byte there).
#
# THE CONTRACT UNDER TEST. 0 only when Pester reports the run passed and at least one test was
# executed; 1 for any failed test, block or container; 2 when no test was executed. The existing
# 'Pester: N passed, N failed, N skipped' line is printed exactly as before and ONE line follows it
# (discovered, not run, failed blocks, failed containers, the Pester version, the host edition and
# version). The runner's parameters and defaults do not change.
#
# HOW. Each scenario copies the runner into its own directory beside one small fixture suite and runs
# that copy in a child of the host under test -- the runner runs every *.Tests.ps1 beside itself, so
# the copy sees only its fixture. The runner gains no parameter for this. The child's script path is
# passed RELATIVE to its working directory, so this harness builds no command line that could split.
#
# ASCII-only (PS 5.1 Windows-1252 trap). Run via tests/run-tests.ps1 (auto-discovered).

BeforeAll {
    $script:RvRunner = Join-Path $PSScriptRoot 'run-tests.ps1'
    $script:RvHostPath = (Get-Process -Id $PID).Path
    $script:RvUtf8 = New-Object System.Text.UTF8Encoding($false)
    $script:RvPesterVersion = [string](Get-Module Pester | Sort-Object Version -Descending | Select-Object -First 1).Version
    $script:RvHostText = 'PowerShell ' + $PSVersionTable.PSEdition + ' ' + $PSVersionTable.PSVersion
    $script:RvEsc = [string][char]27

    # One fixture suite per scenario. Each is a complete *.Tests.ps1 file.
    $script:RvFixtures = @{
        'one passing test'           = "Describe 'fixture' {`n    It 'passes' { 1 | Should -Be 1 }`n}"
        'one failing test'           = "Describe 'fixture' {`n    It 'fails' { 1 | Should -Be 2 }`n}"
        'a filter that matches nothing' = "Describe 'fixture' {`n    It 'passes' { 1 | Should -Be 1 }`n}"
        'a container that fails at discovery' = "Describe 'fixture' {`n    throw 'fixture: this container fails at discovery'`n    It 'never discovered' { 1 | Should -Be 1 }`n}"
        'a BeforeAll that throws'    = "Describe 'fixture' {`n    BeforeAll { throw 'fixture: BeforeAll throws' }`n    It 'a' { 1 | Should -Be 1 }`n}"
        'every selected test skipped' = "Describe 'fixture' {`n    It 'skipped by switch' -Skip { 1 | Should -Be 2 }`n    It 'skipped inside' { Set-ItResult -Skipped -Because 'fixture'; 1 | Should -Be 2 }`n}"
        '256 failing tests'          = "Describe 'fixture' {`n    It 'fails <_>' -ForEach (1..256) { 1 | Should -Be 2 }`n}"
    }
    $script:RvArgs = @{ 'a filter that matches nothing' = ' -FullNameFilter *matches-nothing-er1*' }

    function Invoke-RvScenario {
        param([Parameter(Mandatory = $true)][string] $Name)
        $dir = Join-Path $TestDrive ('rv-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Copy-Item -LiteralPath $script:RvRunner -Destination (Join-Path $dir 'run-tests.ps1') -Force
        [System.IO.File]::WriteAllText((Join-Path $dir 'Fixture.Tests.ps1'), $script:RvFixtures[$Name] + "`n", $script:RvUtf8)
        $extra = ''
        if ($script:RvArgs.ContainsKey($Name)) { $extra = $script:RvArgs[$Name] }
        $outFile = Join-Path $dir 'runner.out'
        $p = Start-Process -FilePath $script:RvHostPath -ArgumentList ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File run-tests.ps1' + $extra) `
            -WorkingDirectory $dir -RedirectStandardOutput $outFile -RedirectStandardError (Join-Path $dir 'runner.err') -PassThru -NoNewWindow
        $null = $p.Handle
        if (-not $p.WaitForExit(300000)) {
            try { $p.Kill() } catch { }
            throw ('runner copy for "' + $Name + '" did not exit within 300 s')
        }
        $text = ''
        if (Test-Path -LiteralPath $outFile) { $text = [System.IO.File]::ReadAllText($outFile) }
        $lines = @(($text -replace ($script:RvEsc + '\[[0-9;]*[A-Za-z]'), '') -split "`r?`n")
        return [pscustomobject]@{
            ExitCode = $p.ExitCode
            Summary  = @($lines | Where-Object { $_ -like 'Pester: *' })
            Detail   = @($lines | Where-Object { $_ -like 'Pester run: *' })
            Output   = $text
        }
    }

    $script:RvResults = @{}
    foreach ($name in $script:RvFixtures.Keys) { $script:RvResults[$name] = Invoke-RvScenario -Name $name }
}

Describe 'tests/run-tests.ps1 exits with a verdict, never a count (dispatch 000313, T2)' {
    It 'exit code <Expected> for <Name>' -ForEach @(
        @{ Name = 'one passing test'; Expected = 0 }
        @{ Name = 'one failing test'; Expected = 1 }
        @{ Name = 'a filter that matches nothing'; Expected = 2 }
        @{ Name = 'a container that fails at discovery'; Expected = 1 }
        @{ Name = 'a BeforeAll that throws'; Expected = 1 }
        @{ Name = 'every selected test skipped'; Expected = 2 }
        @{ Name = '256 failing tests'; Expected = 1 }
    ) {
        $r = $script:RvResults[$Name]
        $r.ExitCode | Should -Be $Expected -Because ('the runner copy printed: ' + (($r.Summary + $r.Detail) -join ' / '))
    }
}

Describe 'tests/run-tests.ps1 prints the existing summary line and one detail line (dispatch 000313, T2)' {
    It 'summary lines for <Name>' -ForEach @(
        @{ Name = 'one passing test'; Summary = 'Pester: 1 passed, 0 failed, 0 skipped'; Counts = '1 discovered, 0 not run, 0 failed blocks, 0 failed containers' }
        @{ Name = 'one failing test'; Summary = 'Pester: 0 passed, 1 failed, 0 skipped'; Counts = '1 discovered, 0 not run, 0 failed blocks, 0 failed containers' }
        @{ Name = 'a filter that matches nothing'; Summary = 'Pester: 0 passed, 0 failed, 0 skipped'; Counts = '1 discovered, 1 not run, 0 failed blocks, 0 failed containers' }
        @{ Name = 'a container that fails at discovery'; Summary = 'Pester: 0 passed, 0 failed, 0 skipped'; Counts = '0 discovered, 0 not run, 0 failed blocks, 1 failed containers' }
        @{ Name = 'every selected test skipped'; Summary = 'Pester: 0 passed, 0 failed, 2 skipped'; Counts = '2 discovered, 0 not run, 0 failed blocks, 0 failed containers' }
        @{ Name = '256 failing tests'; Summary = 'Pester: 0 passed, 256 failed, 0 skipped'; Counts = '256 discovered, 0 not run, 0 failed blocks, 0 failed containers' }
    ) {
        $r = $script:RvResults[$Name]
        @($r.Summary).Count | Should -Be 1 -Because 'the runner prints its summary line once'
        $r.Summary[0] | Should -BeExactly $Summary
        @($r.Detail).Count | Should -Be 1 -Because 'the runner prints one detail line after the summary line'
        $r.Detail[0] | Should -BeExactly ('Pester run: ' + $Counts + '; Pester ' + $script:RvPesterVersion + ' on ' + $script:RvHostText)
        $all = @($r.Output -split "`r?`n")
        $si = [array]::IndexOf($all, ($all | Where-Object { $_ -like 'Pester: *' } | Select-Object -First 1))
        ($all[$si + 1]) | Should -BeLike 'Pester run: *' -Because 'the detail line follows the summary line directly'
    }

    It 'summary lines for a BeforeAll that throws (counts as measured by this Pester)' {
        # How Pester 5 counts the tests under a failed BeforeAll is Pester's business; the contract is
        # that the failed block is reported and the verdict is 1. So this asserts the block, and that
        # the two lines are present in their forms.
        $r = $script:RvResults['a BeforeAll that throws']
        @($r.Summary).Count | Should -Be 1
        $r.Summary[0] | Should -Match '^Pester: \d+ passed, \d+ failed, \d+ skipped$'
        @($r.Detail).Count | Should -Be 1
        $r.Detail[0] | Should -Match ('^Pester run: 1 discovered, 0 not run, 1 failed blocks, 0 failed containers; Pester ' +
            [regex]::Escape($script:RvPesterVersion) + ' on ' + [regex]::Escape($script:RvHostText) + '$')
    }
}

Describe 'tests/run-tests.ps1 keeps its parameters and their defaults (dispatch 000313, T2)' {
    It 'declares exactly -CI, -FullNameFilter and -ExcludeTag, with the base defaults' {
        $tok = $null; $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:RvRunner, [ref]$tok, [ref]$errs)
        @($errs).Count | Should -Be 0
        $shape = @($ast.ParamBlock.Parameters | ForEach-Object {
                $default = ''
                if ($null -ne $_.DefaultValue) { $default = $_.DefaultValue.Extent.Text }
                $_.Name.VariablePath.UserPath + ':' + $_.StaticType.Name + ':' + $default
            })
        ($shape -join ' | ') | Should -BeExactly "CI:SwitchParameter: | FullNameFilter:String:'' | ExcludeTag:String[]:@('ScanRed-A3')"
    }
}
