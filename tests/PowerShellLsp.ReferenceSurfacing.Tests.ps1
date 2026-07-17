#Requires -Version 5.1

# Reference-surfacing tests (Pester 5) -- dispatch 000128, N1.2/N1.3 build.
#
# Three layers:
#   (1) PURE unit tests (no daemon): the ConvertTo-ReferenceSurfacingMode knob parser.
#   (2) Build-ReferenceIndex + Find-ReferenceSurfacing END-TO-END over a controlled fixture workspace:
#       definition facts (referenced-by-N / exported), the cross-file defined-in fact, and EVERY
#       ambiguity guard resolving to SILENCE (duplicate defs, builtin-cmdlet collision, dynamic
#       invocation NOT counted, dynamic dot-source whole-file suppression). Fast, cross-platform.
#   (3) The fixture workspace through the REAL warm daemon with the index root INJECTED at the daemon
#       seam: 'counts' surfaces the Get-DefA fact; knob-off yields NO referenceFindings field
#       (byte-for-byte). This is the load-bearing wiring proof.
#
# ASCII-only (PS 5.1 em-dash trap); straight quotes; LF.
#
# Author: Mike Andersen / powershell-lsp plugin.

BeforeAll {
    $script:PluginRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsDir = Join-Path $script:PluginRoot 'scripts'
    . (Join-Path $script:ScriptsDir 'lib/lsp-common.ps1')
}

# Discovery-time platform gate for -Skip (StrictMode-safe; PS 5.1 has no $IsWindows/$IsLinux).
$script:OnWindows = if (Test-Path 'Variable:\IsWindows') { [bool]$IsWindows } else { $true }
$script:OnLinux = (Test-Path 'Variable:\IsLinux') -and [bool]$IsLinux
$script:OnMacOS = (Test-Path 'Variable:\IsMacOS') -and [bool]$IsMacOS
$script:SkipIntegration = -not ($script:OnWindows -or $script:OnLinux -or $script:OnMacOS)

Describe 'ConvertTo-ReferenceSurfacingMode -- off-by-default knob parse (dispatch 000128)' {
    It 'maps counts (and boolean-truthy aliases) to counts' {
        foreach ($v in @('counts', 'COUNTS', ' Counts ', 'true', 'on', '1', 'yes')) {
            (ConvertTo-ReferenceSurfacingMode $v) | Should -BeExactly 'counts'
        }
    }
    It 'maps off / blank / unexpanded token / unknown to off -- never silently on' {
        # The feature is opt-in: anything not explicitly an ON value is OFF. Adversarial control:
        # make the default branch return 'counts' and these go RED (the knob would default ON).
        foreach ($v in @('off', '', '   ', '${user_config.referenceSurfacing}', 'garbage', 'false', '0', 'no', 'suggest', 'apply')) {
            (ConvertTo-ReferenceSurfacingMode $v) | Should -BeExactly 'off'
        }
    }
}

Describe 'Build-ReferenceIndex + Find-ReferenceSurfacing -- facts and silence-on-ambiguity (dispatch 000128)' {
    BeforeAll {
        $script:RsFix = Join-Path ([System.IO.Path]::GetTempPath()) ('rs-fix-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
        New-Item -ItemType Directory -Force -Path $script:RsFix | Out-Null
        function New-RsFile { param([string]$Name, [string]$Content) $p = Join-Path $script:RsFix $Name; Set-Content -LiteralPath $p -Value $Content -Encoding ascii; return $p }

        # Scenario 1 -- definition facts: Get-DefA is defined once, referenced by TWO files, exported.
        $script:F_defA = New-RsFile 'def_a.ps1'  "function Get-DefA { }`n"
        New-RsFile 'use_a1.ps1' "Get-DefA`n"                | Out-Null
        New-RsFile 'use_a2.ps1' "Get-DefA`n"                | Out-Null
        New-RsFile 'mod_a.psd1' "@{ ModuleVersion = '1.0.0'; FunctionsToExport = @('Get-DefA') }`n" | Out-Null
        # dynamic invocation of Get-DefA -- must NOT be counted (the ambiguity ledger).
        New-RsFile 'dyn.ps1'    "`$c = 'Get-DefA'`n& `$c`n" | Out-Null
        $script:F_dyn = Join-Path $script:RsFix 'dyn.ps1'

        # Scenario 2 -- defined, never referenced, never exported -> SILENCE.
        $script:F_defB = New-RsFile 'def_b.ps1' "function Get-DefB { }`n"

        # Scenario 3 -- exported but not referenced -> the 'exported' fact alone.
        $script:F_defC = New-RsFile 'def_c.ps1' "function Get-DefC { }`n"
        New-RsFile 'mod_c.psd1' "@{ ModuleVersion = '1.0.0'; FunctionsToExport = @('Get-DefC') }`n" | Out-Null

        # Scenario 4/5 -- cross-file defined-in reference (unique definition elsewhere).
        $script:F_defD  = New-RsFile 'def_d.ps1'  "function Invoke-DefD { }`n"
        $script:F_callD = New-RsFile 'call_d.ps1' "Invoke-DefD`n"

        # Scenario 6/7 -- duplicate definitions across files -> ambiguous -> SILENCE (def AND call).
        $script:F_dup1    = New-RsFile 'dup1.ps1'     "function Get-Dup { }`n"
        New-RsFile 'dup2.ps1' "function Get-Dup { }`n" | Out-Null
        $script:F_callDup = New-RsFile 'call_dup.ps1' "Get-Dup`n"

        # Scenario 8 -- a workspace function that shadows a real cmdlet -> collision -> SILENCE.
        $script:F_shadow = New-RsFile 'shadow.ps1' "function Get-Content { }`n"

        # Scenario 9 -- dynamic dot-source suppresses the WHOLE file (would otherwise fire defined-in).
        New-RsFile 'dyntarget.ps1' "function Invoke-DynTarget { }`n" | Out-Null
        $script:F_dynsrc = New-RsFile 'dynsrc.ps1' ". `$helper`nInvoke-DynTarget`n"

        $script:RsIndex = Build-ReferenceIndex -Root $script:RsFix

        function AstOf([string]$Path) { return [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null) }
        function RsFind([string]$Path) { return @(Find-ReferenceSurfacing -Ast (AstOf $Path) -Index $script:RsIndex -EditedFilePath $Path) }
        function MsgList($records) { return @(@($records) | ForEach-Object { [string]$_.message }) }
    }
    AfterAll {
        if (Test-Path -LiteralPath $script:RsFix) { Remove-Item -LiteralPath $script:RsFix -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'the built index records defs, cross-file refs (dynamic NOT counted), and exports' {
        $script:RsIndex['Defs'].ContainsKey('Get-DefA') | Should -BeTrue
        @($script:RsIndex['Defs']['Get-DefA']).Count     | Should -Be 1
        @($script:RsIndex['Defs']['Get-Dup']).Count      | Should -Be 2   # duplicate across two files
        @($script:RsIndex['Refs']['Get-DefA']).Count     | Should -Be 2   # use_a1 + use_a2; the dynamic '& $c' is NOT counted
        $script:RsIndex['Exported'].Contains('Get-DefA') | Should -BeTrue
        $script:RsIndex['Exported'].Contains('Get-DefC') | Should -BeTrue
        $script:RsIndex['Builtins'].Contains('Get-Content') | Should -BeTrue   # the collision-guard set is populated
    }
    It 'definition fact: referenced-by-N counts OTHER files and appends exported' {
        $r = RsFind $script:F_defA
        @($r).Count | Should -Be 1
        $r[0].kind     | Should -BeExactly 'definition'
        $r[0].name     | Should -BeExactly 'Get-DefA'
        $r[0].refCount | Should -Be 2
        $r[0].exported | Should -BeTrue
        $r[0].message  | Should -BeExactly 'Get-DefA -- referenced by 2 files, exported'
    }
    It 'a defined function with no cross-file refs and no export is SILENT' {
        (RsFind $script:F_defB).Count | Should -Be 0
    }
    It 'an exported-but-unreferenced function surfaces the exported fact alone' {
        $r = RsFind $script:F_defC
        @($r).Count | Should -Be 1
        $r[0].refCount | Should -Be 0
        $r[0].exported | Should -BeTrue
        $r[0].message  | Should -BeExactly 'Get-DefC -- exported'
    }
    It 'reference fact: a call to a unique cross-file definition surfaces defined-in' {
        $r = RsFind $script:F_callD
        @($r).Count | Should -Be 1
        $r[0].kind      | Should -BeExactly 'reference'
        $r[0].name      | Should -BeExactly 'Invoke-DefD'
        $r[0].definedIn | Should -BeExactly 'def_d.ps1'
        $r[0].message   | Should -BeExactly 'Invoke-DefD -- defined in def_d.ps1'
    }
    It 'definition fact uses the singular "file" for a count of one' {
        $r = RsFind $script:F_defD
        @($r).Count | Should -Be 1
        $r[0].message | Should -BeExactly 'Invoke-DefD -- referenced by 1 file'
    }
    It 'duplicate definitions across the workspace -> SILENCE (cannot say which is referenced)' {
        (RsFind $script:F_dup1).Count | Should -Be 0
    }
    It 'a call to an ambiguously-defined name -> no defined-in fact' {
        (RsFind $script:F_callDup).Count | Should -Be 0
    }
    It 'a workspace function that shadows a builtin cmdlet -> SILENCE' {
        (RsFind $script:F_shadow).Count | Should -Be 0
    }
    It 'a dynamic dot-source suppresses the whole file (defined-in would otherwise fire)' {
        (RsFind $script:F_dynsrc).Count | Should -Be 0
    }
    It 'a file whose only workspace reference is a dynamic invocation is SILENT' {
        (RsFind $script:F_dyn).Count | Should -Be 0
    }
    It 'a null AST or null index is silent (never throws)' {
        @(Find-ReferenceSurfacing -Ast $null -Index $script:RsIndex -EditedFilePath 'x.ps1').Count | Should -Be 0
        @(Find-ReferenceSurfacing -Ast (AstOf $script:F_defA) -Index $null -EditedFilePath $script:F_defA).Count | Should -Be 0
    }
}

Describe 'Integration: reference surfacing through the REAL warm daemon (dispatch 000128)' -Skip:$script:SkipIntegration {
    # The fixture workspace with the index root INJECTED at the daemon seam (synchronous, deterministic
    # build at load -- no background timing). Two scenarios, each a SEPARATE Context launching ONE daemon
    # (mirrors the 000101 serialization that avoids the 5.1 CI concurrent-startup spike):
    #   A (counts, root injected) -- editing def_a.ps1 surfaces the Get-DefA reference fact.
    #   B (off / no -ReferenceSurfacing) -- the SAME edit yields NO referenceFindings field (byte-for-byte).
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')
        . (Join-Path $PSScriptRoot 'Integration.Common.ps1')   # Wait-DaemonRequestReady, Stop-IntegrationDaemon

        $script:RsScriptsDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts'
        $script:RsData = if (-not [string]::IsNullOrWhiteSpace($env:PSLS_TEST_DATA_DIR)) { $env:PSLS_TEST_DATA_DIR } else { Join-Path ([System.IO.Path]::GetTempPath()) 'psls-pester-data' }
        New-Item -ItemType Directory -Force -Path $script:RsData | Out-Null
        $env:CLAUDE_PLUGIN_DATA = $script:RsData
        $script:RsBundle = Join-Path $script:RsData 'PowerShellEditorServices'
        & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:RsScriptsDir 'ensure-pses.ps1') 2>&1 | Out-Null
        & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:RsScriptsDir 'ensure-pssa.ps1') 2>&1 | Out-Null

        # Fixture workspace (a small, clean subset of the pure-test corpus).
        $script:RsWs = Join-Path $script:RsData ('rs-ws-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $script:RsWs | Out-Null
        Set-Content -LiteralPath (Join-Path $script:RsWs 'def_a.ps1')  -Encoding ascii -Value "function Get-DefA { }`n"
        Set-Content -LiteralPath (Join-Path $script:RsWs 'use_a1.ps1') -Encoding ascii -Value "Get-DefA`n"
        Set-Content -LiteralPath (Join-Path $script:RsWs 'use_a2.ps1') -Encoding ascii -Value "Get-DefA`n"
        Set-Content -LiteralPath (Join-Path $script:RsWs 'mod_a.psd1') -Encoding ascii -Value "@{ ModuleVersion = '1.0.0'; FunctionsToExport = @('Get-DefA') }`n"
        $script:RsEdited = Join-Path $script:RsWs 'def_a.ps1'

        function Start-RsDaemon {
            param([string]$Sid, [string[]]$ExtraArgs)
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'pwsh'; $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
            $daemon = Join-Path $script:RsScriptsDir 'pses-daemon.ps1'
            $argList = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $daemon,
                '-SessionId', $Sid, '-PsHost', 'pwsh', '-DataRoot', $script:RsData) + @($ExtraArgs)
            Add-ProcessArguments $psi ($argList | Where-Object { $_ })
            $psi.EnvironmentVariables['CLAUDE_PLUGIN_DATA'] = $script:RsData
            $psi.EnvironmentVariables['PSES_BUNDLE_PATH'] = $script:RsBundle
            $p = [System.Diagnostics.Process]::Start($psi)
            $null = $p.StandardOutput.ReadToEndAsync(); $null = $p.StandardError.ReadToEndAsync()
            return $p
        }
        function Wait-RsReady { param([string]$Sid)
            $sf = Join-Path $script:RsData ('session/' + $Sid + '.json')
            for ($i = 0; $i -lt 150; $i++) {
                if (Test-Path -LiteralPath $sf) { $o = Get-Content -LiteralPath $sf -Raw | ConvertFrom-Json; if ($o.state -eq 'ready') { return $true } }
                Start-Sleep -Milliseconds 400
            }
            return $false
        }
        function Start-RsScenario { param([string]$Label, [string[]]$ExtraArgs)
            $sid = 'rs-' + $Label + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
            $proc = Start-RsDaemon -Sid $sid -ExtraArgs $ExtraArgs
            $ready = (Wait-RsReady -Sid $sid) -and (Wait-DaemonRequestReady -SessionId $sid -DataRoot $script:RsData -TimeoutMs 60000)
            return @{ Sid = $sid; Proc = $proc; Ready = $ready }
        }
        function Stop-RsScenario { param($Scn)
            if ($null -eq $Scn) { return }
            try { [void](Stop-IntegrationDaemon -SessionId $Scn.Sid -DataRoot $script:RsData) } catch { }
            try { if ($null -ne $Scn.Proc -and -not $Scn.Proc.HasExited) { $Scn.Proc.Kill($true) } } catch { }
        }
        # Request diagnostics for $File, retrying until a CLEAN settled pass (no 'status'); returns the
        # response object so a test can inspect the referenceFindings field (present or absent). $null on timeout.
        function Get-RsResponse { param([string]$Sid, [string]$File)
            $pipeName = 'powershell-lsp-' + $Sid
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            while ($sw.ElapsedMilliseconds -lt 45000) {
                $client = $null
                try {
                    $client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
                    $client.Connect(2000)
                    $writer = New-Object System.IO.StreamWriter($client, (New-Object System.Text.UTF8Encoding($false)), 4096, $true)
                    $writer.NewLine = "`n"; $writer.AutoFlush = $true
                    $reader = New-Object System.IO.StreamReader($client, [System.Text.Encoding]::UTF8, $false, 4096, $true)
                    $writer.WriteLine((@{ action = 'diagnostics'; file = $File; cwd = $script:RsWs } | ConvertTo-Json -Compress)); $writer.Flush()
                    $rt = $reader.ReadLineAsync()
                    if ($rt.Wait(9000)) {
                        $line = $rt.Result
                        if (-not [string]::IsNullOrWhiteSpace($line)) {
                            $o = $line | ConvertFrom-Json
                            $status = [string](Get-Prop $o 'status')
                            if ([string]::IsNullOrWhiteSpace($status)) { return $o }
                        }
                    }
                } catch { } finally { if ($null -ne $client) { try { $client.Dispose() } catch { } } }
                Start-Sleep -Milliseconds 400
            }
            return $null
        }
        function Get-RsRefMessages { param($Resp)
            return @(@(Get-Prop $Resp 'referenceFindings') | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.message })
        }
    }
    AfterAll {
        if (Test-Path -LiteralPath $script:RsWs) { Remove-Item -LiteralPath $script:RsWs -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Context 'daemon A -- counts, index root injected: the Get-DefA fact surfaces' {
        BeforeAll { $script:RsScnA = Start-RsScenario -Label 'counts' -ExtraArgs @('-ReferenceSurfacing', 'counts', '-ReferenceSurfacingRootInject', $script:RsWs) }
        AfterAll { Stop-RsScenario $script:RsScnA }
        It 'came up ready' { $script:RsScnA.Ready | Should -BeTrue -Because 'daemon A must serve or the corpus is meaningless' }
        It 'editing def_a.ps1 surfaces the reference fact for Get-DefA' {
            $resp = Get-RsResponse -Sid $script:RsScnA.Sid -File $script:RsEdited
            $resp | Should -Not -BeNullOrEmpty
            $msgs = Get-RsRefMessages $resp
            @($msgs) | Should -Contain 'Get-DefA -- referenced by 2 files, exported'
        }
    }
    Context 'daemon B -- knob OFF: byte-for-byte surface (NO referenceFindings field)' {
        BeforeAll { $script:RsScnB = Start-RsScenario -Label 'off' -ExtraArgs @() }
        AfterAll { Stop-RsScenario $script:RsScnB }
        It 'came up ready' { $script:RsScnB.Ready | Should -BeTrue }
        It 'the SAME edit yields no referenceFindings field at all' {
            $resp = Get-RsResponse -Sid $script:RsScnB.Sid -File $script:RsEdited
            $resp | Should -Not -BeNullOrEmpty
            (Test-Prop $resp 'referenceFindings') | Should -BeFalse
        }
    }
}
