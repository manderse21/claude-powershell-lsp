#Requires -Version 5.1

# Module-awareness tests (Pester 5) -- dispatch 000101, PL-6 build slice 1.
#
# Two layers:
#   (1) PURE unit tests (no daemon): the ConvertTo-ModuleAwarenessMode knob parser, the
#       Find-ModuleAwareness rung 0-6 predicate, and the shipped command->module index
#       (offline -Check + no built-in / cross-module collisions). Fast, cross-platform.
#   (2) The kb/kg CORPUS through the REAL warm daemon with the installed-set INJECTED at the
#       daemon cache seam (the 000100 survey's slice-1 corpus): kb1 fires EXACTLY ONE
#       Information hint; kg1-kg8, knob-off, and snapshot-not-ready are all SILENT. This is
#       the load-bearing proof -- design B is deterministic on all four legs regardless of
#       what is really installed on the runner, because the snapshot is injected.
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

Describe 'ConvertTo-ModuleAwarenessMode -- off-by-default knob parse (dispatch 000101)' {
    It 'maps suggest (and boolean-truthy aliases) to suggest' {
        foreach ($v in @('suggest', 'SUGGEST', ' Suggest ', 'true', 'on', '1', 'yes')) {
            (ConvertTo-ModuleAwarenessMode $v) | Should -BeExactly 'suggest'
        }
    }
    It 'maps off / blank / unexpanded token / unknown to off -- never silently on (OQ2 acceptance)' {
        # The feature is opt-in: anything not explicitly an ON value is OFF. Adversarial control:
        # make the default branch return 'suggest' and these go RED (the knob would default ON).
        foreach ($v in @('off', '', '   ', '${user_config.moduleAwareness}', 'garbage', 'false', '0', 'no', 'apply')) {
            (ConvertTo-ModuleAwarenessMode $v) | Should -BeExactly 'off'
        }
    }
}

Describe 'Find-ModuleAwareness -- rung 0-6 positive-identification predicate (dispatch 000101)' {
    BeforeAll {
        $idxPath = Join-Path $script:PluginRoot 'rulesets/command-module-index.psd1'
        $script:MaIndex = (Import-PowerShellDataFile -LiteralPath $idxPath)['entries']
        $script:MaTmp = Join-Path ([System.IO.Path]::GetTempPath()) ('ma-unit-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $script:MaTmp | Out-Null
        function Ast([string]$src) { return [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null) }
        function MaCount($findings) { return @(@($findings) | Where-Object { $null -ne $_ }).Count }
    }
    AfterAll {
        if (Test-Path -LiteralPath $script:MaTmp) { Remove-Item -LiteralPath $script:MaTmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'kb1: an indexed command whose module is ABSENT fires exactly one Information hint of the right shape' {
        $r = @(Find-ModuleAwareness -Ast (Ast "Get-MgUser -UserId 'a@b.com'`n") -Index $script:MaIndex -InstalledModules @())
        (MaCount $r) | Should -Be 1
        $r[0].ruleId   | Should -BeExactly 'ModuleNotInstalled'
        $r[0].code     | Should -BeExactly 'ModuleNotInstalled'
        $r[0].source   | Should -BeExactly 'powershell-lsp'
        $r[0].severity | Should -BeExactly 'Information'
        $r[0].message  | Should -Match 'Microsoft\.Graph\.Users'
        $r[0].message  | Should -Match 'Install-Module'
    }
    It 'kg1: a literal Import-Module of the owning module suppresses (rung 5)' {
        (MaCount (Find-ModuleAwareness -Ast (Ast "Import-Module Microsoft.Graph.Users`nGet-MgUser`n") -Index $script:MaIndex -InstalledModules @())) | Should -Be 0
    }
    It 'kg2: #Requires -Modules suppresses (rung 4)' {
        (MaCount (Find-ModuleAwareness -Ast (Ast "#Requires -Modules Microsoft.Graph.Users`nGet-MgUser`n") -Index $script:MaIndex -InstalledModules @())) | Should -Be 0
    }
    It 'kg3: a same-file function definition shadows the index name (rung 2)' {
        (MaCount (Find-ModuleAwareness -Ast (Ast "function Get-MgUser { }`nGet-MgUser`n") -Index $script:MaIndex -InstalledModules @())) | Should -Be 0
    }
    It 'kg4: a dynamic invocation is not a literal name (rung 0)' {
        (MaCount (Find-ModuleAwareness -Ast (Ast "`$c = 'Get-MgUser'`n& `$c`n") -Index $script:MaIndex -InstalledModules @())) | Should -Be 0
    }
    It 'kg5: the module PRESENT in the installed-set suppresses (rung 6, the design-B discriminator)' {
        (MaCount (Find-ModuleAwareness -Ast (Ast "Get-MgUser`n") -Index $script:MaIndex -InstalledModules @('Microsoft.Graph.Users'))) | Should -Be 0
    }
    It 'kg6: a dynamic dot-source suppresses the whole file (rung 3 degrade)' {
        (MaCount (Find-ModuleAwareness -Ast (Ast ". `$helper`nGet-MgUser`n") -Index $script:MaIndex -InstalledModules @())) | Should -Be 0
    }
    It 'kg7: a built-in is never indexed (rung 1)' {
        (MaCount (Find-ModuleAwareness -Ast (Ast "Get-ChildItem`n") -Index $script:MaIndex -InstalledModules @())) | Should -Be 0
    }
    It 'kg8: the nearest manifest RequiredModules suppresses (rung 4 via manifest)' {
        (MaCount (Find-ModuleAwareness -Ast (Ast "Get-MgUser`n") -Index $script:MaIndex -InstalledModules @() -ManifestRequiredModules @('Microsoft.Graph.Users'))) | Should -Be 0
    }
    It 'literal dot-source that DEFINES the name is followed and suppresses (rung 3 follow)' {
        Set-Content -LiteralPath (Join-Path $script:MaTmp 'helpers.ps1') -Value "function Get-MgUser { }`n" -Encoding ascii
        $main = Join-Path $script:MaTmp 'usesdef.ps1'
        Set-Content -LiteralPath $main -Value ". ./helpers.ps1`nGet-MgUser`n" -Encoding ascii
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($main, [ref]$null, [ref]$null)
        (MaCount (Find-ModuleAwareness -Ast $ast -Index $script:MaIndex -InstalledModules @() -FilePath $main)) | Should -Be 0
    }
    It 'literal dot-source to an UNRESOLVABLE file suppresses the whole file (fail-safe)' {
        $main = Join-Path $script:MaTmp 'usesmissing.ps1'
        Set-Content -LiteralPath $main -Value ". ./nope-missing.ps1`nGet-MgUser`n" -Encoding ascii
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($main, [ref]$null, [ref]$null)
        (MaCount (Find-ModuleAwareness -Ast $ast -Index $script:MaIndex -InstalledModules @() -FilePath $main)) | Should -Be 0
    }
    It 'literal dot-source that does NOT define the name still fires (followed, name absent)' {
        Set-Content -LiteralPath (Join-Path $script:MaTmp 'other.ps1') -Value "function Get-Other { }`n" -Encoding ascii
        $main = Join-Path $script:MaTmp 'usesother.ps1'
        Set-Content -LiteralPath $main -Value ". ./other.ps1`nGet-MgUser`n" -Encoding ascii
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($main, [ref]$null, [ref]$null)
        (MaCount (Find-ModuleAwareness -Ast $ast -Index $script:MaIndex -InstalledModules @() -FilePath $main)) | Should -Be 1
    }
    It 'a dynamic Import-Module suppresses the whole file (rung 5 degrade)' {
        (MaCount (Find-ModuleAwareness -Ast (Ast "Import-Module `$m`nGet-MgUser`n") -Index $script:MaIndex -InstalledModules @())) | Should -Be 0
    }
    It 'an unknown command (not indexed) never fires' {
        (MaCount (Find-ModuleAwareness -Ast (Ast "Get-TotallyUnknownThing`n") -Index $script:MaIndex -InstalledModules @())) | Should -Be 0
    }
    It 'a null AST is silent (never throws)' {
        (MaCount (Find-ModuleAwareness -Ast $null -Index $script:MaIndex -InstalledModules @())) | Should -Be 0
    }
}

Describe 'rulesets/command-module-index.psd1 -- shipped index derives offline + no collisions (dispatch 000101)' {
    BeforeAll {
        $script:MaIdxPath = Join-Path $script:PluginRoot 'rulesets/command-module-index.psd1'
        $script:MaSrcPath = Join-Path $script:PluginRoot 'rulesets/command-module-index.source.psd1'
        $script:MaIdxData = Import-PowerShellDataFile -LiteralPath $script:MaIdxPath
        $script:MaSrcData = Import-PowerShellDataFile -LiteralPath $script:MaSrcPath
    }
    It 'is well-formed: schema, non-empty entries, and self-consistent counts' {
        $script:MaIdxData['schema'] | Should -BeExactly 'command-module-index/v1'
        @($script:MaIdxData['entries'].Keys).Count | Should -BeGreaterThan 0
        [int]$script:MaIdxData['entry_count'] | Should -Be @($script:MaIdxData['entries'].Keys).Count
        [int]$script:MaIdxData['module_count'] | Should -Be @($script:MaIdxData['modules']).Count
    }
    It 'anchors the corpus: Get-MgUser -> Microsoft.Graph.Users' {
        [string]$script:MaIdxData['entries']['Get-MgUser'] | Should -BeExactly 'Microsoft.Graph.Users'
    }
    It 'no entry name collides with a built-in on the source denylist (rung 1 by construction)' {
        $builtins = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($b in @($script:MaSrcData['builtins'])) { [void]$builtins.Add([string]$b) }
        $collisions = @($script:MaIdxData['entries'].Keys | Where-Object { $builtins.Contains([string]$_) })
        $collisions | Should -BeNullOrEmpty
    }
    It 'no entry name is owned by more than one module in the source (EXCLUSION collision policy)' {
        # Re-derive ownership from the SOURCE snapshot: every shipped entry must be owned by EXACTLY
        # ONE module -- a name any two source modules both export must have been EXCLUDED, not shipped.
        $owners = @{}
        foreach ($m in @($script:MaSrcData['modules'])) {
            $mn = [string]$m['name']
            foreach ($c in @($m['commands'])) {
                $key = ([string]$c).ToLowerInvariant()
                if (-not $owners.ContainsKey($key)) { $owners[$key] = New-Object 'System.Collections.Generic.SortedSet[string]' ([System.StringComparer]::OrdinalIgnoreCase) }
                [void]$owners[$key].Add($mn)
            }
        }
        foreach ($name in @($script:MaIdxData['entries'].Keys)) {
            @($owners[([string]$name).ToLowerInvariant()]).Count | Should -Be 1 -Because "$name must have exactly one owning module to ship"
        }
    }
    It 'regen-command-module-index.ps1 -Check re-derives OFFLINE and exits 0 on the shipped artifact' {
        $regen = Join-Path $script:ScriptsDir 'regen-command-module-index.ps1'
        & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $regen -Check | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'Integration: module-awareness corpus through the REAL warm daemon (dispatch 000101)' -Skip:$script:SkipIntegration {
    # The kb/kg corpus with the installed-set INJECTED at the daemon cache seam. Each scenario is a
    # SEPARATE Context that launches ONE daemon in its own BeforeAll and tears it down in its AfterAll,
    # so only ONE daemon (+ its PSES child) is ever alive at a time. That is deliberate: launching all
    # four daemons at once overwhelmed the constrained Windows PowerShell 5.1 CI leg's startup (one
    # daemon lost the bootstrap race and never went ready), a pure test-harness contention issue -- the
    # product path is identical. Serializing the scenarios removes the concurrent-startup spike.
    #   A (suggest, __empty__ injected)    -- nothing installed: kb1 fires; kg1-4,6-8 stay silent by rung.
    #   B (suggest, Microsoft.Graph.Users) -- present: kg5 stays silent (the design-B discriminator).
    #   C (off / no -ModuleAwareness)      -- knob off: the kb1 fixture yields NO hint (byte-for-byte).
    #   D (suggest, __defer__ injected)    -- snapshot never ready: the kb1 fixture stays SILENT.
    # 0-FP / 100-TP is the conjunction of these Its: kb1 fires (the one known-bad) and every kg / off /
    # defer is silent (the known-goods). The 000101 outbox custom_check runs the whole suite as the guard.
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')
        . (Join-Path $PSScriptRoot 'Integration.Common.ps1')   # Wait-DaemonRequestReady, Stop-IntegrationDaemon

        function Start-MaDaemon {
            param([string]$Sid, [string[]]$ExtraArgs)
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'pwsh'; $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
            $daemon = Join-Path $script:MaScriptsDir 'pses-daemon.ps1'
            $argList = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $daemon,
                '-SessionId', $Sid, '-PsHost', 'pwsh', '-DataRoot', $script:MaData) + @($ExtraArgs)
            Add-ProcessArguments $psi ($argList | Where-Object { $_ })
            $psi.EnvironmentVariables['CLAUDE_PLUGIN_DATA'] = $script:MaData
            $psi.EnvironmentVariables['PSES_BUNDLE_PATH'] = $script:MaBundle
            $p = [System.Diagnostics.Process]::Start($psi)
            $null = $p.StandardOutput.ReadToEndAsync(); $null = $p.StandardError.ReadToEndAsync()
            return $p
        }
        function Wait-MaReady { param([string]$Sid)
            $sf = Join-Path $script:MaData ('session/' + $Sid + '.json')
            for ($i = 0; $i -lt 150; $i++) {
                if (Test-Path -LiteralPath $sf) { $o = Get-Content -LiteralPath $sf -Raw | ConvertFrom-Json; if ($o.state -eq 'ready') { return $true } }
                Start-Sleep -Milliseconds 400
            }
            return $false
        }
        # Launch ONE daemon + wait until it services a real diagnostics round-trip; returns a scenario
        # handle. With only one daemon alive there is no startup contention, so a single daemon comes up
        # well within the wait even on the slow 5.1 CI leg.
        function Start-MaScenario { param([string]$Label, [string[]]$ExtraArgs)
            $sid = 'ma-' + $Label + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
            $proc = Start-MaDaemon -Sid $sid -ExtraArgs $ExtraArgs
            $ready = (Wait-MaReady -Sid $sid) -and (Wait-DaemonRequestReady -SessionId $sid -DataRoot $script:MaData -TimeoutMs 60000)
            return @{ Sid = $sid; Proc = $proc; Ready = $ready }
        }
        function Stop-MaScenario { param($Scn)
            if ($null -eq $Scn) { return }
            try { [void](Stop-IntegrationDaemon -SessionId $Scn.Sid -DataRoot $script:MaData) } catch { }
            try { if ($null -ne $Scn.Proc -and -not $Scn.Proc.HasExited) { $Scn.Proc.Kill($true) } } catch { }
        }
        # Send a diagnostics request over the pipe, retrying until a CLEAN settled pass (no 'status'
        # token) -- so a silent case is proven silent on a REAL analysis, never trivially on an
        # unsettled/incomplete pass. Returns the count of ModuleNotInstalled findings, or -1 on timeout.
        function Get-MaCount { param([string]$Sid, [string]$File)
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
                    $writer.WriteLine((@{ action = 'diagnostics'; file = $File; cwd = (Split-Path -Parent $File) } | ConvertTo-Json -Compress)); $writer.Flush()
                    $rt = $reader.ReadLineAsync()
                    if ($rt.Wait(9000)) {
                        $line = $rt.Result
                        if (-not [string]::IsNullOrWhiteSpace($line)) {
                            $o = $line | ConvertFrom-Json
                            $status = [string](Get-Prop $o 'status')
                            if ([string]::IsNullOrWhiteSpace($status)) {
                                $diags = @(@(Get-Prop $o 'diagnostics') | Where-Object { $null -ne $_ })
                                return @($diags | Where-Object { [string]$_.ruleId -eq 'ModuleNotInstalled' }).Count
                            }
                        }
                    }
                } catch { } finally { if ($null -ne $client) { try { $client.Dispose() } catch { } } }
                Start-Sleep -Milliseconds 400
            }
            return -1
        }

        $script:MaScriptsDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts'
        $script:MaData = if (-not [string]::IsNullOrWhiteSpace($env:PSLS_TEST_DATA_DIR)) { $env:PSLS_TEST_DATA_DIR } else { Join-Path ([System.IO.Path]::GetTempPath()) 'psls-pester-data' }
        New-Item -ItemType Directory -Force -Path $script:MaData | Out-Null
        $env:CLAUDE_PLUGIN_DATA = $script:MaData
        $script:MaBundle = Join-Path $script:MaData 'PowerShellEditorServices'
        # Idempotent PSES + PSSA bootstrap (no-op if the shared data root already has them) -- done ONCE,
        # before any daemon launches, so each scenario's daemon starts from a present bundle.
        & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:MaScriptsDir 'ensure-pses.ps1') 2>&1 | Out-Null
        & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:MaScriptsDir 'ensure-pssa.ps1') 2>&1 | Out-Null

        # Fixtures.
        $script:MaFix = Join-Path $script:MaData ('ma-corpus-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $script:MaFix | Out-Null
        function New-Fix { param([string]$Name, [string]$Content) $p = Join-Path $script:MaFix $Name; Set-Content -LiteralPath $p -Value $Content -Encoding ascii; return $p }
        $script:F_kb1 = New-Fix 'kb1.ps1' "Get-MgUser -UserId 'a@b.com'`n"
        $script:F_kg1 = New-Fix 'kg1.ps1' "Import-Module Microsoft.Graph.Users`nGet-MgUser`n"
        $script:F_kg2 = New-Fix 'kg2.ps1' "#Requires -Modules Microsoft.Graph.Users`nGet-MgUser`n"
        $script:F_kg3 = New-Fix 'kg3.ps1' "function Get-MgUser { 'stub' }`nGet-MgUser`n"
        $script:F_kg4 = New-Fix 'kg4.ps1' "`$c = 'Get-MgUser'`n& `$c`n"
        $script:F_kg5 = New-Fix 'kg5.ps1' "Get-MgUser`n"
        $script:F_kg6 = New-Fix 'kg6.ps1' ". `$helper`nGet-MgUser`n"
        $script:F_kg7 = New-Fix 'kg7.ps1' "function Do-Local { }`nGet-ChildItem`nDo-Local`n"
        # kg8: a module dir -- nearest manifest RequiredModules names the module, used in the root module file.
        $script:MaKg8Dir = Join-Path $script:MaFix 'kg8mod'
        New-Item -ItemType Directory -Force -Path $script:MaKg8Dir | Out-Null
        Set-Content -LiteralPath (Join-Path $script:MaKg8Dir 'kg8mod.psd1') -Encoding ascii -Value "@{`n    RootModule = 'kg8mod.psm1'`n    ModuleVersion = '1.0.0'`n    FunctionsToExport = @('Invoke-Kg8')`n    RequiredModules = @('Microsoft.Graph.Users')`n}`n"
        $script:F_kg8 = Join-Path $script:MaKg8Dir 'kg8mod.psm1'
        Set-Content -LiteralPath $script:F_kg8 -Encoding ascii -Value "function Invoke-Kg8 { Get-MgUser }`n"
    }
    AfterAll {
        if (Test-Path -LiteralPath $script:MaFix) { Remove-Item -LiteralPath $script:MaFix -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Context 'daemon A -- nothing installed (__empty__ injected): kb1 fires, kg1-4,6-8 silent' {
        BeforeAll { $script:ScnA = Start-MaScenario -Label 'empty' -ExtraArgs @('-ModuleAwareness', 'suggest', '-ModuleAwarenessInstalledInject', '__empty__') }
        AfterAll { Stop-MaScenario $script:ScnA }
        It 'came up ready' { $script:ScnA.Ready | Should -BeTrue -Because 'daemon A must serve or the corpus is meaningless' }
        It 'kb1: Get-MgUser with the module ABSENT fires EXACTLY ONE ModuleNotInstalled hint' {
            (Get-MaCount -Sid $script:ScnA.Sid -File $script:F_kb1) | Should -Be 1
        }
        It 'kg1: literal Import-Module -> SILENT' { (Get-MaCount -Sid $script:ScnA.Sid -File $script:F_kg1) | Should -Be 0 }
        It 'kg2: #Requires -Modules -> SILENT' { (Get-MaCount -Sid $script:ScnA.Sid -File $script:F_kg2) | Should -Be 0 }
        It 'kg3: same-file function definition -> SILENT' { (Get-MaCount -Sid $script:ScnA.Sid -File $script:F_kg3) | Should -Be 0 }
        It 'kg4: dynamic invocation -> SILENT' { (Get-MaCount -Sid $script:ScnA.Sid -File $script:F_kg4) | Should -Be 0 }
        It 'kg6: dynamic dot-source -> SILENT' { (Get-MaCount -Sid $script:ScnA.Sid -File $script:F_kg6) | Should -Be 0 }
        It 'kg7: built-in (never indexed) -> SILENT' { (Get-MaCount -Sid $script:ScnA.Sid -File $script:F_kg7) | Should -Be 0 }
        It 'kg8: nearest-manifest RequiredModules in a module file -> SILENT' { (Get-MaCount -Sid $script:ScnA.Sid -File $script:F_kg8) | Should -Be 0 }
    }
    Context 'daemon B -- module PRESENT (injected): kg5 silent (the design-B discriminator)' {
        BeforeAll { $script:ScnB = Start-MaScenario -Label 'present' -ExtraArgs @('-ModuleAwareness', 'suggest', '-ModuleAwarenessInstalledInject', 'Microsoft.Graph.Users') }
        AfterAll { Stop-MaScenario $script:ScnB }
        It 'came up ready' { $script:ScnB.Ready | Should -BeTrue }
        It 'kg5: Get-MgUser with the module PRESENT -> SILENT (design A would FAIL this)' {
            (Get-MaCount -Sid $script:ScnB.Sid -File $script:F_kg5) | Should -Be 0
        }
    }
    Context 'daemon C -- knob OFF: byte-for-byte surface (no ModuleNotInstalled record)' {
        BeforeAll { $script:ScnC = Start-MaScenario -Label 'off' -ExtraArgs @() }
        AfterAll { Stop-MaScenario $script:ScnC }
        It 'came up ready' { $script:ScnC.Ready | Should -BeTrue }
        It 'knob OFF: the kb1 fixture yields NO ModuleNotInstalled hint' {
            (Get-MaCount -Sid $script:ScnC.Sid -File $script:F_kb1) | Should -Be 0
        }
    }
    Context 'daemon D -- snapshot DEFERRED: the fail-safe direction (silent while not ready)' {
        BeforeAll { $script:ScnD = Start-MaScenario -Label 'defer' -ExtraArgs @('-ModuleAwareness', 'suggest', '-ModuleAwarenessInstalledInject', '__defer__') }
        AfterAll { Stop-MaScenario $script:ScnD }
        It 'came up ready' { $script:ScnD.Ready | Should -BeTrue }
        It 'snapshot NOT READY: the kb1 fixture stays SILENT' {
            (Get-MaCount -Sid $script:ScnD.Sid -File $script:F_kb1) | Should -Be 0
        }
    }
}
