#Requires -Version 5.1

# Argument boundaries for every command line the plugin builds (dispatch 000313, track T1;
# ruling ER1-R2; enterprise-review finding ER-F05).
#
# THE DEFECT. Start-PsesDaemonDetached handed Start-Process an ARRAY. Start-Process joins an
# -ArgumentList array with single spaces and quotes nothing (measured on Windows PowerShell 5.1 and
# on PowerShell 7.6), so a plugin install path, data root or host path holding a space arrived as two
# or more arguments: the child host reported that the first half of the path is not a script file,
# the daemon never started, and the launcher still returned $true. Windows PowerShell 5.1 also
# refuses an -ArgumentList array that holds an empty element. The Windows PowerShell 5.1 arm of
# Add-ProcessArguments quoted by hand and lost a value ending in a backslash inside quotes, a
# backslash run before a double quote, and an empty value.
#
# THE FIX UNDER TEST. ConvertTo-ProcessArgumentString (scripts/lib/lsp-common.ps1) is the ONE routine
# that builds a command line string, by the Windows command line rules ER1-R2 names: a value is quoted
# when it is empty or holds white space or a double quote; a backslash run is doubled before a double
# quote and before the closing quote; a double quote is escaped. Both arms of Start-PsesDaemonDetached
# and the Windows PowerShell 5.1 arm of Add-ProcessArguments use it. The PowerShell 7 ArgumentList arm
# is unchanged, and a value with no white space and no double quote is emitted verbatim, so the default
# launch's command line is byte-identical to the base.
#
# THE ORACLE is the argument vector the child actually received, never a string comparison of a
# command line. A stand-in pses-daemon.ps1 records $args and [Environment]::GetCommandLineArgs() to a
# file beside itself, and each case compares both, value for value, with the vector the launcher
# intended. The launch goes through the product's own path: a launcher child dot-sources a COPY of
# scripts/lib/lsp-common.ps1 placed inside the shaped plugin tree -- so $script:LspCommonDir resolves
# there exactly as it does under session-start.ps1 -- and calls Start-PsesDaemonDetached. One real
# daemon is then started from a spaced install path with a spaced data root and shown to have started
# by its own log under that data root.
#
# CLEANUP. Every grandchild this file causes carries a run-unique marker (the session id) on its
# command line. Each case waits for its stand-in to exit and stops it only if it is still running and
# still carries the marker; the final It stops any process that still carries the marker and proves
# none is left. Nothing else is ever stopped. Every directory lives under $TestDrive.
#
# ASCII-only (PS 5.1 Windows-1252 trap). Run via tests/run-tests.ps1 (auto-discovered).

BeforeAll {
    $script:AbRepoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:AbRepoRoot 'scripts/lib/lsp-common.ps1')
    $script:AbLibSource = Join-Path $script:AbRepoRoot 'scripts/lib/lsp-common.ps1'
    # The host under test runs every child: the same host that runs this file.
    $script:AbHostPath = (Get-Process -Id $PID).Path
    # The host the product names on its own command line: the bare command name, exactly as
    # Resolve-PsHost returns it to session-start.ps1 and lsp-client.ps1 in production.
    $script:AbHostName = if ($PSVersionTable.PSVersion.Major -ge 6) { 'pwsh' } else { 'powershell' }
    $script:AbRunMarker = 'ab313x' + [guid]::NewGuid().ToString('N').Substring(0, 12)
    $script:AbUtf8 = New-Object System.Text.UTF8Encoding($false)
    # Generated launchers embed shaped paths (a non-ASCII letter among them) as literals, and Windows
    # PowerShell 5.1 reads a BOM-less script through the ANSI code page, so launchers carry a BOM.
    $script:AbUtf8Bom = New-Object System.Text.UTF8Encoding($true)
    $script:AbCaseNo = 0
    $script:AbWaitSec = 45

    $script:AbStandIn = @(
        '# Stand-in for pses-daemon.ps1 (dispatch 000313 T1 oracle): records the argument vector it received.'
        '$rec = [ordered]@{'
        '    pid  = $PID'
        '    args = @($args | ForEach-Object { [string]$_ })'
        '    argv = @([Environment]::GetCommandLineArgs() | Select-Object -Skip 1 | ForEach-Object { [string]$_ })'
        '}'
        '$json = ConvertTo-Json -InputObject $rec -Depth 4 -Compress'
        '[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot ''received.json''), $json, (New-Object System.Text.UTF8Encoding($false)))'
    ) -join "`n"

    function ConvertTo-AbLiteral {
        param([AllowEmptyString()][string] $Value)
        return ("'" + ($Value -replace "'", "''") + "'")
    }

    function Format-AbVector {
        # One unambiguous string for a vector: compare two of these, never two joined command lines.
        param([AllowEmptyCollection()][object[]] $Vector)
        return (ConvertTo-Json -InputObject @($Vector | ForEach-Object { [string]$_ }) -Compress)
    }

    function Get-AbMarkedProcess {
        # Every live process whose command line carries this run's marker. Only this file's
        # grandchildren can: the marker is minted fresh per run.
        if (Test-OnWindows) {
            return @(Get-CimInstance -ClassName Win32_Process -Filter ("CommandLine LIKE '%" + $script:AbRunMarker + "%'") `
                    -ErrorAction SilentlyContinue | Where-Object { [int]$_.ProcessId -ne $PID } |
                    ForEach-Object { [pscustomobject]@{ Id = [int]$_.ProcessId; CommandLine = [string]$_.CommandLine } })
        }
        return @(Get-Process -Name 'pwsh', 'powershell' -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID } |
                ForEach-Object { [pscustomobject]@{ Id = $_.Id; CommandLine = (Get-ProcessCommandLine $_.Id) } } |
                Where-Object { $_.CommandLine -like ('*' + $script:AbRunMarker + '*') })
    }

    function Stop-AbOwnedProcess {
        # Stop ONE process this file caused, only while it still carries $Marker on its command line,
        # and report whether it is gone. Returns 'exited', 'stopped' or 'alive'.
        param([int] $ProcessIdValue, [string] $Marker, [int] $GraceMs = 15000)
        $deadline = [DateTime]::UtcNow.AddMilliseconds($GraceMs)
        while ([DateTime]::UtcNow -lt $deadline) {
            if ($null -eq (Get-Process -Id $ProcessIdValue -ErrorAction SilentlyContinue)) { return 'exited' }
            Start-Sleep -Milliseconds 100
        }
        $cl = Get-ProcessCommandLine $ProcessIdValue
        if ($cl -like ('*' + $Marker + '*')) {
            try { Stop-Process -Id $ProcessIdValue -Force -ErrorAction Stop } catch { }
            $deadline = [DateTime]::UtcNow.AddSeconds(10)
            while ([DateTime]::UtcNow -lt $deadline) {
                if ($null -eq (Get-Process -Id $ProcessIdValue -ErrorAction SilentlyContinue)) { return 'stopped' }
                Start-Sleep -Milliseconds 100
            }
            return 'alive'
        }
        if ($null -eq (Get-Process -Id $ProcessIdValue -ErrorAction SilentlyContinue)) { return 'exited' }
        # Alive but no longer ours (the pid was reused): it is not this file's to stop.
        return 'exited'
    }

    function Invoke-AbLauncher {
        # Run a generated launcher in a fresh child of the host under test and wait for it. The
        # launcher's path is passed RELATIVE to its working directory, so this harness builds no
        # command line that could itself split.
        param([string] $WorkDir, [string] $LauncherText)
        [System.IO.File]::WriteAllText((Join-Path $WorkDir 'launch.ps1'), $LauncherText + "`n", $script:AbUtf8Bom)
        $p = Start-Process -FilePath $script:AbHostPath -ArgumentList '-NoLogo -NoProfile -ExecutionPolicy Bypass -File launch.ps1' `
            -WorkingDirectory $WorkDir -RedirectStandardOutput (Join-Path $WorkDir 'launch.out') `
            -RedirectStandardError (Join-Path $WorkDir 'launch.err') -PassThru -NoNewWindow
        $null = $p.Handle
        if (-not $p.WaitForExit(90000)) {
            try { $p.Kill() } catch { }
            throw ('launcher did not exit within 90 s (' + $WorkDir + ')')
        }
        $err = ''
        $errFile = Join-Path $WorkDir 'launch.err'
        if (Test-Path -LiteralPath $errFile) { $err = [System.IO.File]::ReadAllText($errFile) }
        return $err
    }

    function Read-AbJsonFile {
        # Poll for a JSON file a child writes, tolerating the window in which it exists but is still
        # being written. $null when it never appears.
        param([string] $Path, [int] $TimeoutSec)
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
        while ([DateTime]::UtcNow -lt $deadline) {
            if (Test-Path -LiteralPath $Path) {
                try { return ([System.IO.File]::ReadAllText($Path) | ConvertFrom-Json) } catch { }
            }
            Start-Sleep -Milliseconds 100
        }
        return $null
    }

    function Invoke-AbLaunchCase {
        # One launch through the product's own path. Builds the shaped plugin tree (a copy of the
        # library under test plus the stand-in daemon) and the data root, launches, and returns
        # what the stand-in received beside the vector the launcher intended.
        param(
            [Parameter(Mandatory = $true)][string] $TreeDir,
            [Parameter(Mandatory = $true)][string] $DataRoot,
            [Parameter(Mandatory = $true)][string] $HostExe,
            [System.Collections.Specialized.OrderedDictionary] $Extra = $null
        )
        $script:AbCaseNo++
        $sid = $script:AbRunMarker + '-c' + $script:AbCaseNo
        $scriptsDir = Join-Path $TreeDir 'scripts'
        $libDir = Join-Path $scriptsDir 'lib'
        New-Item -ItemType Directory -Force -Path $libDir | Out-Null
        Copy-Item -LiteralPath $script:AbLibSource -Destination (Join-Path $libDir 'lsp-common.ps1') -Force
        [System.IO.File]::WriteAllText((Join-Path $scriptsDir 'pses-daemon.ps1'), $script:AbStandIn + "`n", $script:AbUtf8)
        New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null
        $work = Join-Path $TestDrive ('w' + $script:AbCaseNo)
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        $report = Join-Path $work 'report.json'
        $extraText = ''
        if ($null -ne $Extra) {
            foreach ($k in $Extra.Keys) { $extraText += (' -' + $k + ' ' + (ConvertTo-AbLiteral ([string]$Extra[$k]))) }
        }
        $launcher = @(
            '$ErrorActionPreference = ''Stop'''
            '$env:CLAUDE_PLUGIN_DATA = ' + (ConvertTo-AbLiteral $DataRoot)
            '. ' + (ConvertTo-AbLiteral (Join-Path $libDir 'lsp-common.ps1'))
            '$ok = Start-PsesDaemonDetached -SessionId ' + (ConvertTo-AbLiteral $sid) + ' -HostExe ' + (ConvertTo-AbLiteral $HostExe) + $extraText
            '$rep = [ordered]@{ libDir = [string]$script:LspCommonDir; launched = [bool]$ok }'
            '[System.IO.File]::WriteAllText(' + (ConvertTo-AbLiteral $report) + ', (ConvertTo-Json -InputObject $rep -Compress), (New-Object System.Text.UTF8Encoding($false)))'
        ) -join "`n"
        $launchErr = Invoke-AbLauncher -WorkDir $work -LauncherText $launcher
        $rep = Read-AbJsonFile -Path $report -TimeoutSec 5
        $received = Read-AbJsonFile -Path (Join-Path $scriptsDir 'received.json') -TimeoutSec $script:AbWaitSec
        $expected = $null
        if ($null -ne $rep) {
            # The vector Start-PsesDaemonDetached builds for these inputs, in its own order.
            $expected = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                (Join-Path (Split-Path -Parent ([string]$rep.libDir)) 'pses-daemon.ps1'),
                '-SessionId', $sid, '-PsHost', $HostExe, '-DataRoot', $DataRoot,
                '-SeverityThreshold', 'Hint', '-DebounceMs', '150', '-IdleTtlMin', '30', '-PerFileCap', '20')
            if ($null -ne $Extra) {
                foreach ($k in @('RuleInclude', 'RuleExclude', 'SettingsPath', 'OrgPolicyPath')) {
                    if ($Extra.Contains($k)) { $expected += @(('-' + $k), [string]$Extra[$k]) }
                }
            }
        }
        $fate = 'never-ran'
        if ($null -ne $received) { $fate = Stop-AbOwnedProcess -ProcessIdValue ([int]$received.pid) -Marker $sid }
        return [pscustomobject]@{
            SessionId = $sid
            Launched  = $(if ($null -ne $rep) { [bool]$rep.launched } else { $null })
            Received  = $received
            Expected  = $expected
            LaunchErr = $launchErr
            Fate      = $fate
        }
    }

    function Assert-AbVectorArrived {
        param([Parameter(Mandatory = $true)] $Case)
        $Case.Expected | Should -Not -BeNullOrEmpty -Because ('the launcher must report what it launched; stderr: ' + $Case.LaunchErr)
        $Case.Launched | Should -BeTrue -Because 'Start-PsesDaemonDetached reports the launch fired'
        $Case.Received | Should -Not -BeNullOrEmpty -Because ('the stand-in daemon must start and record what it received within ' +
            $script:AbWaitSec + ' s; a split -File path never starts it')
        (Format-AbVector @($Case.Received.argv)) | Should -BeExactly (Format-AbVector $Case.Expected) -Because 'the child process must receive exactly the vector the launcher intended'
        (Format-AbVector @($Case.Received.args)) | Should -BeExactly (Format-AbVector @($Case.Expected | Select-Object -Skip 6)) -Because 'the daemon script must be handed exactly the intended arguments'
        $Case.Fate | Should -Not -Be 'alive' -Because 'the stand-in this case started must be gone'
    }
}

Describe 'ConvertTo-ProcessArgumentString builds a command line by the Windows rules (dispatch 000313, ruling ER1-R2, T1)' {
    It 'emits a value with no white space and no double quote verbatim' {
        ConvertTo-ProcessArgumentString -Arguments @('-NoLogo', 'C:\plain\path\', '/tmp/x', "it's", 'a\b\\c') |
            Should -BeExactly "-NoLogo C:\plain\path\ /tmp/x it's a\b\\c"
    }
    It 'quotes an empty value' {
        ConvertTo-ProcessArgumentString -Arguments @('a', '', 'b') | Should -BeExactly 'a "" b'
    }
    It 'quotes a value holding white space' {
        ConvertTo-ProcessArgumentString -Arguments @('C:\Program Files (x86)\x', "tab`there") |
            Should -BeExactly ('"C:\Program Files (x86)\x" "tab' + "`t" + 'here"')
    }
    It 'escapes a double quote and doubles the backslash run before it' {
        ConvertTo-ProcessArgumentString -Arguments @('say "hi"') | Should -BeExactly '"say \"hi\""'
        ConvertTo-ProcessArgumentString -Arguments @('a\"b') | Should -BeExactly '"a\\\"b"'
        ConvertTo-ProcessArgumentString -Arguments @('a\\"b') | Should -BeExactly '"a\\\\\"b"'
    }
    It 'doubles a backslash run before the closing quote and only there' {
        ConvertTo-ProcessArgumentString -Arguments @('C:\data dir\') | Should -BeExactly '"C:\data dir\\"'
        ConvertTo-ProcessArgumentString -Arguments @('C:\a b\\') | Should -BeExactly '"C:\a b\\\\"'
        ConvertTo-ProcessArgumentString -Arguments @('C:\a b\c') | Should -BeExactly '"C:\a b\c"'
    }
    It 'returns the empty string for an empty vector' {
        ConvertTo-ProcessArgumentString -Arguments @() | Should -BeExactly ''
    }
    It 'leaves the default launch command line byte-identical to the space-joined vector' {
        # The default daemon launch carries no value that needs quoting, so its command line is
        # exactly what Start-Process made of the array at the base commit.
        $v = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'C:\p\scripts\pses-daemon.ps1',
            '-SessionId', '0f8fad5b-d9cb-469f-a165-70867728950e', '-PsHost', 'pwsh', '-DataRoot', 'C:\d',
            '-SeverityThreshold', 'Hint', '-DebounceMs', '150', '-IdleTtlMin', '30', '-PerFileCap', '20')
        ConvertTo-ProcessArgumentString -Arguments $v | Should -BeExactly ($v -join ' ')
    }
}

Describe 'Start-PsesDaemonDetached delivers every argument intact (dispatch 000313, T1)' {
    BeforeAll {
        $script:AbShapeRoot = Join-Path $TestDrive 'shapes'
        New-Item -ItemType Directory -Force -Path $script:AbShapeRoot | Out-Null
        $nonAscii = [string][char]0x0142   # LATIN SMALL LETTER L WITH STROKE: outside every ANSI code page this suite runs under
        # Directory names, one per shape. 'plain' is the control. The bare apostrophe and the bare
        # non-ASCII letter hold no white space, so no correct routine quotes them and the base passed
        # them through intact (measured: GREEN at the base commit on both hosts); they guard that the
        # fix leaves them alone. The two 'in a spaced name' shapes put the same characters INSIDE a
        # quoted value, which is where a routine that quoted wrongly would lose them.
        $script:AbShapes = [ordered]@{
            'control'                             = 'plain'
            'one space'                           = 'one space'
            'several spaces with parentheses'     = 'several  spaces (x86) here'
            'an apostrophe'                       = "it's"
            'a non-ASCII letter'                  = ('w' + $nonAscii + 'asny')
            'an apostrophe in a spaced name'      = "it's here"
            'a non-ASCII letter in a spaced name' = ('w' + $nonAscii + 'asny katalog')
        }
        $script:AbPlainTree = Join-Path $script:AbShapeRoot 'tree-plain'
        $script:AbPlainData = Join-Path $script:AbShapeRoot 'data-plain'
    }

    Context 'the plugin tree in each shape (data root: control)' {
        It 'plugin tree, <Name>' -ForEach @(
            @{ Name = 'control' }, @{ Name = 'one space' }, @{ Name = 'several spaces with parentheses' },
            @{ Name = 'an apostrophe' }, @{ Name = 'a non-ASCII letter' },
            @{ Name = 'an apostrophe in a spaced name' }, @{ Name = 'a non-ASCII letter in a spaced name' }
        ) {
            $tree = Join-Path (Join-Path $script:AbShapeRoot 'trees') $script:AbShapes[$Name]
            $case = Invoke-AbLaunchCase -TreeDir $tree -DataRoot (Join-Path $script:AbShapeRoot ('data-for-tree-' + $script:AbCaseNo)) -HostExe $script:AbHostName
            Assert-AbVectorArrived -Case $case
        }
    }

    Context 'the data root in each shape (plugin tree: control)' {
        It 'data root, <Name>' -ForEach @(
            @{ Name = 'control' }, @{ Name = 'one space' }, @{ Name = 'several spaces with parentheses' },
            @{ Name = 'an apostrophe' }, @{ Name = 'a non-ASCII letter' },
            @{ Name = 'an apostrophe in a spaced name' }, @{ Name = 'a non-ASCII letter in a spaced name' }
        ) {
            $data = Join-Path (Join-Path $script:AbShapeRoot 'datas') $script:AbShapes[$Name]
            $tree = Join-Path $script:AbShapeRoot ('tree-for-data-' + $script:AbCaseNo)
            $case = Invoke-AbLaunchCase -TreeDir $tree -DataRoot $data -HostExe $script:AbHostName
            Assert-AbVectorArrived -Case $case
        }

        It 'data root that ends in a directory separator, <Name>' -ForEach @(
            @{ Name = 'with a space'; Leaf = 'data root' },
            @{ Name = 'without a space'; Leaf = 'dataroot' }
        ) {
            $data = (Join-Path (Join-Path $script:AbShapeRoot 'sep') $Leaf) + [System.IO.Path]::DirectorySeparatorChar
            $tree = Join-Path $script:AbShapeRoot ('tree-for-sep-' + $script:AbCaseNo)
            $case = Invoke-AbLaunchCase -TreeDir $tree -DataRoot $data -HostExe $script:AbHostName
            Assert-AbVectorArrived -Case $case
        }
    }

    Context 'the other values on the launch command line' {
        It 'the host given by its full path' {
            # On Windows PowerShell 7 this is C:\Program Files\PowerShell\7\pwsh.exe: a host path
            # holding a space. Elsewhere it holds none and the case is a control.
            $tree = Join-Path $script:AbShapeRoot ('tree-host-' + $script:AbCaseNo)
            $case = Invoke-AbLaunchCase -TreeDir $tree -DataRoot (Join-Path $script:AbShapeRoot ('data-host-' + $script:AbCaseNo)) -HostExe $script:AbHostPath
            Assert-AbVectorArrived -Case $case
        }

        It 'optional values holding spaces (rule list, settings path, org policy path)' {
            $tree = Join-Path $script:AbShapeRoot ('tree-opt-' + $script:AbCaseNo)
            $extra = [ordered]@{
                RuleInclude   = 'PSAvoidUsingCmdletAliases, PSUseApprovedVerbs'
                SettingsPath  = (Join-Path (Join-Path $script:AbShapeRoot 'my settings') 'PSScriptAnalyzerSettings.psd1')
                OrgPolicyPath = (Join-Path (Join-Path $script:AbShapeRoot 'org policy') 'policy file.json')
            }
            $case = Invoke-AbLaunchCase -TreeDir $tree -DataRoot (Join-Path $script:AbShapeRoot ('data-opt-' + $script:AbCaseNo)) -HostExe $script:AbHostName -Extra $extra
            Assert-AbVectorArrived -Case $case
        }
    }
}

Describe 'Add-ProcessArguments round-trips every value through a real child (dispatch 000313, T1)' {
    # On Windows PowerShell 5.1 this exercises the hand-built .Arguments string; on PowerShell 7 the
    # ArgumentList arm, which is unchanged and serves as the control.
    BeforeAll {
        $script:AbEchoDir = Join-Path $TestDrive 'echo'
        New-Item -ItemType Directory -Force -Path $script:AbEchoDir | Out-Null
        $script:AbEcho = Join-Path $script:AbEchoDir 'echo.ps1'
        $echoText = @(
            '$rec = [ordered]@{ args = @($args | ForEach-Object { [string]$_ }) }'
            '[System.IO.File]::WriteAllText($env:PSLS_AB_ECHO_OUT, (ConvertTo-Json -InputObject $rec -Depth 4 -Compress), (New-Object System.Text.UTF8Encoding($false)))'
        ) -join "`n"
        [System.IO.File]::WriteAllText($script:AbEcho, $echoText + "`n", $script:AbUtf8)

        function Invoke-AbEcho {
            param([AllowEmptyString()][string[]] $Values)
            $out = Join-Path $script:AbEchoDir ('out-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $script:AbHostPath
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.EnvironmentVariables['PSLS_AB_ECHO_OUT'] = $out
            Add-ProcessArguments $psi (@('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:AbEcho) + $Values)
            $p = [System.Diagnostics.Process]::Start($psi)
            if (-not $p.WaitForExit(60000)) { try { $p.Kill() } catch { }; throw 'echo child did not exit within 60 s' }
            return (Read-AbJsonFile -Path $out -TimeoutSec 5)
        }
    }

    It 'round-trips <Name>' -ForEach @(
        @{ Name = 'a value ending in a backslash, holding a space'; Value = 'C:\data dir\' }
        @{ Name = 'a value ending in a backslash, no space'; Value = 'C:\data\' }
        @{ Name = 'a value holding a double quote'; Value = 'say "hi"' }
        @{ Name = 'a value holding a backslash before a double quote'; Value = 'a\"b' }
        @{ Name = 'an empty value'; Value = '' }
    ) {
        $got = Invoke-AbEcho -Values @('before', $Value, 'after')
        $got | Should -Not -BeNullOrEmpty -Because 'the echo child must run and record its arguments'
        (Format-AbVector @($got.args)) | Should -BeExactly (Format-AbVector @('before', $Value, 'after'))
    }
}

Describe 'A real daemon starts from a spaced install path with a spaced data root (dispatch 000313, T1)' {
    BeforeAll {
        $script:AbRdInstall = Join-Path (Join-Path $TestDrive 'real install (x86)') 'power shell-lsp'
        New-Item -ItemType Directory -Force -Path $script:AbRdInstall | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:AbRepoRoot 'scripts') -Destination $script:AbRdInstall -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $script:AbRepoRoot '.claude-plugin') -Destination $script:AbRdInstall -Recurse -Force
        $script:AbRdData = Join-Path $TestDrive 'real data root'
        New-Item -ItemType Directory -Force -Path $script:AbRdData | Out-Null
        $script:AbRdSid = $script:AbRunMarker + '-real'
        $work = Join-Path $TestDrive 'w-real'
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        $launcher = @(
            '$ErrorActionPreference = ''Stop'''
            '$env:CLAUDE_PLUGIN_DATA = ' + (ConvertTo-AbLiteral $script:AbRdData)
            '. ' + (ConvertTo-AbLiteral (Join-Path $script:AbRdInstall 'scripts/lib/lsp-common.ps1'))
            '[void](Start-PsesDaemonDetached -SessionId ' + (ConvertTo-AbLiteral $script:AbRdSid) + ' -HostExe ' + (ConvertTo-AbLiteral $script:AbHostName) + ')'
        ) -join "`n"
        $script:AbRdLaunchErr = Invoke-AbLauncher -WorkDir $work -LauncherText $launcher
        $script:AbRdLog = Join-Path $script:AbRdData 'logs/pses-daemon.log'
        $script:AbRdSessionFile = Join-Path $script:AbRdData ('session/' + $script:AbRdSid + '.json')
        $script:AbRdStartLine = ''
        $script:AbRdRecord = $null
        $deadline = [DateTime]::UtcNow.AddSeconds(90)
        while ([DateTime]::UtcNow -lt $deadline) {
            if ([string]::IsNullOrEmpty($script:AbRdStartLine) -and (Test-Path -LiteralPath $script:AbRdLog)) {
                try {
                    $hit = @([System.IO.File]::ReadAllLines($script:AbRdLog) |
                            Where-Object { $_ -like ('*--- daemon start:*session=' + $script:AbRdSid + ' *') })
                    if ($hit.Count -gt 0) { $script:AbRdStartLine = $hit[0] }
                } catch { }
            }
            if ($null -eq $script:AbRdRecord -and (Test-Path -LiteralPath $script:AbRdSessionFile)) {
                try { $script:AbRdRecord = [System.IO.File]::ReadAllText($script:AbRdSessionFile) | ConvertFrom-Json } catch { }
            }
            if (-not [string]::IsNullOrEmpty($script:AbRdStartLine) -and $null -ne $script:AbRdRecord) { break }
            Start-Sleep -Milliseconds 200
        }
    }

    It 'the daemon logs its own start under the spaced data root' {
        $script:AbRdStartLine | Should -Not -BeNullOrEmpty -Because ('the daemon must start from ' + $script:AbRdInstall +
            ' and log under ' + $script:AbRdData + '; launcher stderr: ' + $script:AbRdLaunchErr)
        $script:AbRdRecord | Should -Not -BeNullOrEmpty -Because 'the daemon writes its session record (with its pid) once its pipe is up'
        [string]$script:AbRdRecord.sessionId | Should -BeExactly $script:AbRdSid
    }

    It 'stops exactly the daemon it started and proves it is gone' {
        if ($null -eq $script:AbRdRecord) { throw 'no daemon record: the daemon never started, so there is nothing of ours to stop' }
        $daemonPid = [int]$script:AbRdRecord.pid
        $daemonPid | Should -BeGreaterThan 0
        (Get-ProcessCommandLine $daemonPid) | Should -BeLike ('*pses-daemon.ps1*' + $script:AbRdSid + '*') -Because 'the recorded pid must be the daemon this test started'
        Stop-Process -Id $daemonPid -Force -ErrorAction SilentlyContinue
        $psesPid = 0
        if ($null -ne $script:AbRdRecord.psesPid) { $psesPid = [int]$script:AbRdRecord.psesPid }
        if ($psesPid -gt 0 -and ((Get-ProcessCommandLine $psesPid) -match 'Start-EditorServices\.ps1')) {
            Stop-Process -Id $psesPid -Force -ErrorAction SilentlyContinue
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while ([DateTime]::UtcNow -lt $deadline -and $null -ne (Get-Process -Id $daemonPid -ErrorAction SilentlyContinue)) {
            Start-Sleep -Milliseconds 100
        }
        Get-Process -Id $daemonPid -ErrorAction SilentlyContinue | Should -BeNullOrEmpty -Because 'the daemon this test started must be gone'
        # Off Windows the stopped daemon cannot unlink the socket file backing its pipe; it is this test's to remove.
        if (-not (Test-OnWindows)) {
            $sock = Get-DaemonPipeSocketPath -PipeName (Get-DaemonPipeName -SessionId $script:AbRdSid)
            if (Test-Path -LiteralPath $sock) { Remove-Item -LiteralPath $sock -Force -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'Every process this file caused is gone (dispatch 000313, T1)' {
    It 'leaves no live process carrying this run''s marker' {
        $left = @(Get-AbMarkedProcess)
        foreach ($p in $left) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { } }
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while ([DateTime]::UtcNow -lt $deadline -and @(Get-AbMarkedProcess).Count -gt 0) { Start-Sleep -Milliseconds 250 }
        $still = @(Get-AbMarkedProcess)
        ('still alive: ' + (($still | ForEach-Object { [string]$_.Id }) -join ',')) | Should -BeExactly 'still alive: '
    }
}
