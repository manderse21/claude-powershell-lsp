#Requires -Version 5.1

# A scan names a directory it could not list (dispatch 000313, track T3; ruling ER1-R4;
# enterprise-review finding ER-F07).
#
# THE DEFECT. Get-ScanTargets listed the scan tree with errors silenced and returned only what it
# could read, so a directory the current user cannot list vanished from coverage: a scan over a tree
# holding one read with its files reported clean, exited 0 with executionSuccessful=true, and a
# managed scan certified the files it happened to see.
#
# THE CONTRACT UNDER TEST. Every directory below the scan root that the listing could not read is
# NOT analyzed and travels the existing not-analyzed channel -- named on stderr, in the text report
# and in a SARIF not-analyzed notification, executionSuccessful=false, exit 4 -- with the one new
# display reason directory-unreadable beside it, and a managed scan refuses with the existing
# analysis-incomplete. The same tree with the directory readable scans exactly as before (control).
#
# A REAL DENIAL. On Windows an access rule denies the current user ListDirectory on the directory;
# elsewhere the directory is chmod 000. A process running as root lists a mode-000 directory anyway,
# so there the Describe is skipped with that reason. The fixture captures the directory's access rule
# (or mode) first, restores it before anything is removed and proves it restored; every file lives
# under $TestDrive.
#
# Every scan runs scripts/lsp-scan.ps1 itself, under the host under test (the host that runs this
# file), against the suite's provisioned data root, with every CLAUDE_PLUGIN_OPTION_* and
# POWERSHELL_LSP_* variable removed from its environment.
#
# ASCII-only (PS 5.1 Windows-1252 trap); StrictMode-safe. Run via tests/run-tests.ps1 (auto-discovered).

Describe 'A scan names a directory it could not list (dispatch 000313, T3)' {
    BeforeAll {
        $repo = Split-Path -Parent $PSScriptRoot
        . (Join-Path $repo 'scripts/lib/lsp-common.ps1')
        . (Join-Path $repo 'scripts/lib/lsp-scan-common.ps1')
        . (Join-Path $PSScriptRoot 'Integration.Common.ps1')
        . (Join-Path $PSScriptRoot 'ScanHarness.Common.ps1')
        $script:UlSkipWhy = ''
        if (-not (Test-OnWindows)) {
            $uid = ''
            try { $uid = [string](& id -u 2>$null) } catch { $uid = '' }
            if ($uid.Trim() -eq '0') { $script:UlSkipWhy = 'running as root: a mode-000 directory is still listable, so no real denial can be staged' }
        }
        $script:UlRun = @{}
        $script:UlDenied = $false
        function Skip-UlUnlessStaged {
            # Every It below calls this first: as root it reports the reason and skips, never passes.
            if ($script:UlSkipWhy -ne '') { Set-ItResult -Skipped -Because $script:UlSkipWhy; return $true }
            return $false
        }
        if ($script:UlSkipWhy -ne '') { return }
        $script:UlScan = Join-Path $repo 'scripts/lsp-scan.ps1'
        # lsp-scan.ps1 itself runs under the host under test: the listing is that host's.
        $script:UlHost = (Get-Process -Id $PID).Path
        $script:UlData = if (-not [string]::IsNullOrWhiteSpace($env:PSLS_TEST_DATA_DIR)) { $env:PSLS_TEST_DATA_DIR } else { Join-Path ([System.IO.Path]::GetTempPath()) 'psls-sarifscan-test-data' }
        New-Item -ItemType Directory -Force -Path $script:UlData | Out-Null
        $ensureHost = Resolve-PsHost 'pwsh'
        $prevData = $env:CLAUDE_PLUGIN_DATA
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $env:CLAUDE_PLUGIN_DATA = $script:UlData
            & $ensureHost -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts/ensure-pses.ps1') 2>&1 | Out-Null
            & $ensureHost -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts/ensure-pssa.ps1') 2>&1 | Out-Null
        } finally { $ErrorActionPreference = $prevEap; $env:CLAUDE_PLUGIN_DATA = $prevData }

        $script:UlOnWin = Test-OnWindows
        $script:UlTree = Join-Path $TestDrive 'tree'
        $script:UlLocked = Join-Path $script:UlTree 'locked'
        New-Item -ItemType Directory -Force -Path $script:UlLocked | Out-Null
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText((Join-Path $script:UlTree 'a.ps1'), "`$global:UlReadable = 1`ngci`n", $utf8)
        [System.IO.File]::WriteAllText((Join-Path $script:UlLocked 'b.ps1'), "`$global:UlUnlisted = 1`ngci`n", $utf8)
        $script:UlPolicy = Join-Path $TestDrive 'required.psd1'
        [System.IO.File]::WriteAllText($script:UlPolicy, "@{ RequiredRules = @('PSAvoidGlobalVars') }`n", $utf8)

        function Invoke-UlScan {
            param([string]$Format = 'sarif', [switch]$Managed)
            $out = Join-Path $TestDrive ('out-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.' + $Format)
            $a = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:UlScan, $script:UlTree, '-Format', $Format, '-OutputPath', $out)
            if ($Managed) { $a += @('-OrgPolicyPath', $script:UlPolicy, '-PolicyMode', 'closed') }
            $run = Invoke-SvChildProcess -HostExe $script:UlHost -CapMs 300000 -ArgumentList $a -ExtraEnv @{ CLAUDE_PLUGIN_DATA = $script:UlData } `
                -RemoveEnvPrefix @('CLAUDE_PLUGIN_OPTION_', 'POWERSHELL_LSP_')
            $text = Read-SvTextFile -Path $out
            $sarif = $null; $uris = @(); $notes = @(); $exec = $null; $pol = $null
            if ($Format -eq 'sarif' -and -not [string]::IsNullOrWhiteSpace($text)) {
                $sarif = $text | ConvertFrom-Json
                $uris = @(@($sarif.runs[0].results) | Where-Object { $null -ne $_ } |
                        ForEach-Object { [string]$_.locations[0].physicalLocation.artifactLocation.uri + '|' + [string]$_.ruleId } | Sort-Object -Unique)
                $inv = $sarif.runs[0].invocations[0]
                $exec = [bool]$inv.executionSuccessful
                if ($null -ne $inv.PSObject.Properties['toolExecutionNotifications']) { $notes = @($inv.toolExecutionNotifications) }
                if ($null -ne $inv.PSObject.Properties['properties']) { $pol = $inv.properties.policy }
            }
            return @{ Exit = [int]$run.ExitCode; Err = [string]$run.Err; Text = $text; Sarif = $sarif; Results = $uris; Notes = $notes; Exec = $exec; Policy = $pol; TimedOut = [bool]$run.TimedOut }
        }

        function Get-UlAccessRules {
            # The directory's access rules as text, one per rule. Compared before and after rather than the
            # whole SDDL: Set-Acl may write the DACL back with the auto-inherited flag set where the parent's
            # lacked it, though no rule changed (independent review finding R3, measured).
            $acl = Get-Acl -LiteralPath $script:UlLocked
            return (@($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object {
                        [string]$_.IdentityReference + '|' + [string]$_.AccessControlType + '|' + [string]$_.FileSystemRights + '|' +
                        [string]$_.IsInherited + '|' + [string]$_.InheritanceFlags + '|' + [string]$_.PropagationFlags }) -join ';')
        }

        function Set-UlDenied {
            # Deny the current user listing the directory -- a real denial, not a simulated one.
            if ($script:UlOnWin) {
                $script:UlAclBefore = Get-UlAccessRules
                $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
                $script:UlSid = $sid.Value
                $script:UlRule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid,
                    [System.Security.AccessControl.FileSystemRights]::ListDirectory, [System.Security.AccessControl.AccessControlType]::Deny)
                $acl = Get-Acl -LiteralPath $script:UlLocked
                $acl.AddAccessRule($script:UlRule)
                Set-Acl -LiteralPath $script:UlLocked -AclObject $acl
            } else {
                $script:UlModeBefore = [System.IO.File]::GetUnixFileMode($script:UlLocked)
                [System.IO.File]::SetUnixFileMode($script:UlLocked, [System.IO.UnixFileMode]::None)
            }
            $script:UlDenied = $true
        }

        function Restore-UlAccess {
            if (-not $script:UlDenied) { return }
            if ($script:UlOnWin) {
                $acl = Get-Acl -LiteralPath $script:UlLocked
                [void]$acl.RemoveAccessRule($script:UlRule)
                Set-Acl -LiteralPath $script:UlLocked -AclObject $acl
                $script:UlAclAfter = Get-UlAccessRules
                $script:UlDenyLeft = @((Get-Acl -LiteralPath $script:UlLocked).GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) |
                        Where-Object { [string]$_.AccessControlType -eq 'Deny' -and [string]$_.IdentityReference -eq $script:UlSid }).Count
            } else {
                [System.IO.File]::SetUnixFileMode($script:UlLocked, $script:UlModeBefore)
            }
            $script:UlDenied = $false
        }

        $script:UlDenied = $false
        $script:UlRun = @{}
        # CONTROLS first, with the directory readable: the scan this tree gave at the base commit.
        $script:UlRun.Control = Invoke-UlScan
        $script:UlRun.ManagedControl = Invoke-UlScan -Managed
        try {
            Set-UlDenied
            $probeErr = $null
            $null = @(Get-ChildItem -LiteralPath $script:UlLocked -ErrorAction SilentlyContinue -ErrorVariable probeErr)
            $script:UlDenialErrors = @($probeErr).Count
            $script:UlRun.Sarif = Invoke-UlScan
            $script:UlRun.Text = Invoke-UlScan -Format 'text'
            $script:UlRun.Managed = Invoke-UlScan -Managed
            # Review finding R6: with no readable PowerShell file left, the managed verdict names analysis-empty beside
            # the directory's analysis-incomplete. a.ps1 is renamed out of the scan's file types for this one scan.
            Rename-Item -LiteralPath (Join-Path $script:UlTree 'a.ps1') -NewName 'a.txt'
            try { $script:UlRun.ManagedEmpty = Invoke-UlScan -Managed }
            finally { Rename-Item -LiteralPath (Join-Path $script:UlTree 'a.txt') -NewName 'a.ps1' }
        } finally {
            Restore-UlAccess
        }
    }

    AfterAll {
        if (Get-Command Restore-UlAccess -ErrorAction SilentlyContinue) { Restore-UlAccess }
    }

    It 'every scan ran to its report (this Describe cannot pass vacuously)' {
        if (Skip-UlUnlessStaged) { return }
        foreach ($k in @($script:UlRun.Keys)) {
            $script:UlRun[$k].TimedOut | Should -BeFalse -Because ($k + ' must finish')
            $script:UlRun[$k].Text | Should -Not -BeNullOrEmpty -Because ($k + ' must write its report; stderr: ' + $script:UlRun[$k].Err)
        }
    }

    It 'the denial is real: listing the directory fails for this user, and the access rule is restored afterwards' {
        if (Skip-UlUnlessStaged) { return }
        $script:UlDenialErrors | Should -BeGreaterThan 0 -Because 'a directory the user can still list proves nothing'
        if ($script:UlOnWin) {
            $script:UlAclAfter | Should -BeExactly $script:UlAclBefore -Because 'the fixture restores the access rules it found'
            $script:UlDenyLeft | Should -Be 0 -Because 'no deny rule for this user may remain'
        } else { [System.IO.File]::GetUnixFileMode($script:UlLocked) | Should -Be $script:UlModeBefore }
        @(Get-ChildItem -LiteralPath $script:UlLocked -File).Count | Should -Be 1 -Because 'the directory is listable again'
    }

    It 'CONTROL: with the directory readable the scan analyzes both files, exits 0, executionSuccessful=true and names nothing' {
        if (Skip-UlUnlessStaged) { return }
        $c = $script:UlRun.Control
        $c.Exit | Should -Be 0 -Because ('stderr: ' + $c.Err)
        $c.Exec | Should -BeTrue
        @($c.Notes).Count | Should -Be 0
        @($c.Results | Where-Object { $_ -like 'a.ps1|*' }).Count | Should -BeGreaterThan 0
        @($c.Results | Where-Object { $_ -like 'locked/b.ps1|*' }).Count | Should -BeGreaterThan 0
    }

    It 'CONTROL: with the directory readable a managed scan of the same tree is CERTIFIED' {
        if (Skip-UlUnlessStaged) { return }
        $m = $script:UlRun.ManagedControl
        $m.Exit | Should -Be 0 -Because ('stderr: ' + $m.Err)
        [string]$m.Policy.certification | Should -BeExactly 'certified'
    }

    It 'SARIF: exit 4, executionSuccessful=false, and a not-analyzed notification names the directory with directory-unreadable' {
        if (Skip-UlUnlessStaged) { return }
        $s = $script:UlRun.Sarif
        $s.Exit | Should -Be 4 -Because ('a directory the scan could not list must not read clean; stderr: ' + $s.Err)
        $s.Exec | Should -BeFalse
        $hit = @($s.Notes | Where-Object { [string]$_.message.text -match 'locked/' -and [string]$_.message.text -match 'directory-unreadable' })
        $hit.Count | Should -Be 1 -Because ('notifications: ' + ((@($s.Notes) | ForEach-Object { [string]$_.message.text }) -join ' / '))
        [string]$hit[0].locations[0].physicalLocation.artifactLocation.uri | Should -BeExactly 'locked/'
        (@($hit[0].properties.reasons) -join ',') | Should -BeExactly 'directory-unreadable'
    }

    It 'SARIF: the readable file is still analyzed and reported; nothing under the directory is' {
        if (Skip-UlUnlessStaged) { return }
        $s = $script:UlRun.Sarif
        @($s.Results | Where-Object { $_ -like 'a.ps1|*' }).Count | Should -BeGreaterThan 0
        @($s.Results | Where-Object { $_ -like 'locked/*' }).Count | Should -Be 0
        (@($s.Results | Where-Object { $_ -like 'a.ps1|*' }) -join ',') | Should -BeExactly (@($script:UlRun.Control.Results | Where-Object { $_ -like 'a.ps1|*' }) -join ',')
    }

    It 'stderr names the directory with directory-unreadable' {
        if (Skip-UlUnlessStaged) { return }
        $script:UlRun.Sarif.Err | Should -Match '(?m)^  locked/ \(directory could not be listed; reasons: directory-unreadable\)\r?$'
        $script:UlRun.Sarif.Err | Should -Match 'could NOT be listed -- scan is INCOMPLETE \(executionSuccessful=false\)'
    }

    It 'the text report names the directory with directory-unreadable, and the scan exits 4' {
        if (Skip-UlUnlessStaged) { return }
        $t = $script:UlRun.Text
        $t.Exit | Should -Be 4 -Because ('stderr: ' + $t.Err)
        $t.Text | Should -Match '(?m)^  locked/ \(directory could not be listed; reasons: directory-unreadable\)\r?$'
    }

    It 'a managed scan of the same tree is NOT CERTIFIED with analysis-incomplete' {
        if (Skip-UlUnlessStaged) { return }
        $m = $script:UlRun.Managed
        $m.Exit | Should -Be 4 -Because ('stderr: ' + $m.Err)
        [string]$m.Policy.certification | Should -BeExactly 'not-certified'
        @($m.Policy.reasons) | Should -Contain 'analysis-incomplete'
        $entry = @(@($m.Policy.files) | Where-Object { [string]$_.uri -eq 'locked/' })
        $entry.Count | Should -Be 1
        @($entry[0].reasons) | Should -Contain 'analysis-incomplete'
    }

    It 'a managed scan that finds no readable PowerShell file names analysis-empty beside the directory''s analysis-incomplete (review finding R6)' {
        if (Skip-UlUnlessStaged) { return }
        $m = $script:UlRun.ManagedEmpty
        $m.Exit | Should -Be 4 -Because ('stderr: ' + $m.Err)
        $m.Exec | Should -BeFalse
        [string]$m.Policy.certification | Should -BeExactly 'not-certified'
        @($m.Policy.reasons) | Should -Contain 'analysis-empty'
        @($m.Policy.reasons) | Should -Contain 'analysis-incomplete'
        @(@($m.Policy.files) | Where-Object { [string]$_.uri -eq 'locked/' }).Count | Should -Be 1
        @($m.Notes | Where-Object { (@($_.properties.reasons) -join ',') -eq 'directory-unreadable' }).Count | Should -Be 1
    }
}

Describe 'A scan names a directory the host cannot address (dispatch 000313, T3; independent review finding R1)' {
    # Under Windows PowerShell 5.1 a directory whose path is longer than MAX_PATH cannot be enumerated: the listing
    # reports it (DirIOError, with the directory as its target) while Test-Path says it is not there, so a check that
    # asked Test-Path dropped it and the scan read clean over the file inside (measured by the independent review).
    # It is a directory the scan could not list, and is named like any other. PowerShell 7 lists the same tree in
    # full, and Linux and macOS have no MAX_PATH, so there the same test is a control: nothing is named.
    # The tree is built and removed by a PowerShell 7 child, which can address it on every host.
    BeforeAll {
        $repo = Split-Path -Parent $PSScriptRoot
        . (Join-Path $repo 'scripts/lib/lsp-common.ps1')
        . (Join-Path $repo 'scripts/lib/lsp-scan-common.ps1')
        . (Join-Path $PSScriptRoot 'Integration.Common.ps1')
        . (Join-Path $PSScriptRoot 'ScanHarness.Common.ps1')
        $script:DpScan = Join-Path $repo 'scripts/lsp-scan.ps1'
        $script:DpHost = (Get-Process -Id $PID).Path
        $script:DpPwsh = @(Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue)
        $script:DpData = if (-not [string]::IsNullOrWhiteSpace($env:PSLS_TEST_DATA_DIR)) { $env:PSLS_TEST_DATA_DIR } else { Join-Path ([System.IO.Path]::GetTempPath()) 'psls-sarifscan-test-data' }
        New-Item -ItemType Directory -Force -Path $script:DpData | Out-Null
        $script:DpRoot = Join-Path $TestDrive 'deep'
        # Only Windows PowerShell 5.1 cannot address a path past MAX_PATH; every other host here lists it.
        $script:DpUnaddressable = ((Test-OnWindows) -and $PSVersionTable.PSVersion.Major -lt 6)
        $script:DpBuilt = $null
        $script:DpRun = $null
        if ($script:DpPwsh.Count -gt 0) {
            $pwshExe = $script:DpPwsh[0].Source
            $prevData = $env:CLAUDE_PLUGIN_DATA
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $env:CLAUDE_PLUGIN_DATA = $script:DpData
                & $pwshExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts/ensure-pses.ps1') 2>&1 | Out-Null
                & $pwshExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts/ensure-pssa.ps1') 2>&1 | Out-Null
            } finally { $ErrorActionPreference = $prevEap; $env:CLAUDE_PLUGIN_DATA = $prevData }
            # Six nested 41-character directory names under the test drive put the deepest path past MAX_PATH.
            $build = '$r = $env:PSLS_UL_DEEP; $d = $r; foreach ($i in 0..5) { $d = Join-Path $d (''d'' + $i + (''x'' * 40)) }; ' +
                'New-Item -ItemType Directory -Path $d -Force | Out-Null; Set-Content -LiteralPath (Join-Path $r ''a.ps1'') -Value ''gci'' -Encoding ascii; ' +
                'Set-Content -LiteralPath (Join-Path $d ''b.ps1'') -Value ''gci'' -Encoding ascii; Write-Output $d.Length'
            $b = Invoke-SvChildProcess -HostExe $pwshExe -CapMs 60000 -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $build) `
                -ExtraEnv @{ PSLS_UL_DEEP = $script:DpRoot }
            $script:DpBuilt = [string]$b.Out
            $out = Join-Path $TestDrive 'deep-out.sarif'
            $a = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:DpScan, $script:DpRoot, '-Format', 'sarif', '-OutputPath', $out)
            $run = Invoke-SvChildProcess -HostExe $script:DpHost -CapMs 300000 -ArgumentList $a -ExtraEnv @{ CLAUDE_PLUGIN_DATA = $script:DpData } `
                -RemoveEnvPrefix @('CLAUDE_PLUGIN_OPTION_', 'POWERSHELL_LSP_')
            $text = Read-SvTextFile -Path $out
            $notes = @(); $uris = @(); $exec = $null
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $sarif = $text | ConvertFrom-Json
                $inv = $sarif.runs[0].invocations[0]
                $exec = [bool]$inv.executionSuccessful
                if ($null -ne $inv.PSObject.Properties['toolExecutionNotifications']) { $notes = @($inv.toolExecutionNotifications) }
                $uris = @(@($sarif.runs[0].results) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.locations[0].physicalLocation.artifactLocation.uri })
            }
            $script:DpRun = @{ Exit = [int]$run.ExitCode; Err = [string]$run.Err; Exec = $exec; Notes = $notes; Uris = $uris; Text = $text }
        }
    }

    AfterAll {
        if ($script:DpPwsh.Count -gt 0 -and (Test-Path -LiteralPath $script:DpRoot)) {
            # Removed by PowerShell 7, which can address every path in it -- before the test drive is removed.
            [void](Invoke-SvChildProcess -HostExe $script:DpPwsh[0].Source -CapMs 60000 `
                    -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'Remove-Item -LiteralPath $env:PSLS_UL_DEEP -Recurse -Force') `
                    -ExtraEnv @{ PSLS_UL_DEEP = $script:DpRoot })
        }
    }

    It 'names the directory exactly when this host could not list it' {
        if ($script:DpPwsh.Count -eq 0) { Set-ItResult -Skipped -Because 'no PowerShell 7 on this host to build the tree'; return }
        $r = $script:DpRun
        $r.Text | Should -Not -BeNullOrEmpty -Because ('the scan must write its report; built: ' + $script:DpBuilt + '; stderr: ' + $r.Err)
        if (Test-OnWindows) { [int]($script:DpBuilt.Trim()) | Should -BeGreaterThan 260 -Because 'the deepest directory path must pass MAX_PATH for the case to be real' }
        $named = @($r.Notes | Where-Object { (@($_.properties.reasons) -join ',') -eq 'directory-unreadable' })
        @($r.Uris | Where-Object { $_ -eq 'a.ps1' }).Count | Should -Be 1 -Because 'the readable file is analyzed either way'
        if ($script:DpUnaddressable) {
            $r.Exit | Should -Be 4 -Because ('a directory Windows PowerShell 5.1 could not list must not read clean; stderr: ' + $r.Err)
            $r.Exec | Should -BeFalse
            $named.Count | Should -Be 1 -Because ('notifications: ' + ((@($r.Notes) | ForEach-Object { [string]$_.message.text }) -join ' / '))
            [string]$named[0].locations[0].physicalLocation.artifactLocation.uri | Should -BeLike ('d0' + ('x' * 40) + '/*/')
            $r.Err | Should -Match 'directory\(ies\) could NOT be listed'
            @($r.Uris | Where-Object { $_ -like '*b.ps1' }).Count | Should -Be 0
        } else {
            $named.Count | Should -Be 0 -Because 'this host lists the whole tree, so no directory is unread'
            $listed = @($r.Uris | Where-Object { $_ -like '*/b.ps1' }).Count + @($r.Notes | Where-Object { [string]$_.message.text -like '*b.ps1*' }).Count
            $listed | Should -BeGreaterThan 0 -Because 'the deepest file was listed: analyzed, or named as a file not analyzed'
        }
    }
}
