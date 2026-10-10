#Requires -Version 5.1

# Scan READ-ONLY census -- review finding F2, measured (dispatch 000302, A1). Tests and fixtures only;
# nothing under scripts/ changes.
#
# THE FINDING. The 2026-09-30 enterprise review (F2) read the scanner statically: it reuses the
# interactive client, its per-child environment overrides only scopeToEdit / timeoutMs / capture,
# and every other CLAUDE_PLUGIN_OPTION_* in the caller's environment is inherited -- including
# formatOnEdit, whose 'apply' mode asks the daemon to WRITE the analysed file and then suppresses the
# pre-write findings. The reviewer established the code path and did not execute the formatter. This
# file measures it.
#
# TWO LAYERS, kept apart on purpose (a stub can never prove a formatter ran):
#   1. DETERMINISTIC TRANSPORT CENSUS (fake children, no PSES). The PRODUCTION Invoke-ScanFileDiagnostics
#      and Start-ScanDaemon spawn recording fakes (tests/fixtures/scan-verdict/env-record-client.ps1,
#      fake-session-start.ps1) that report what configuration reached them and what the real
#      scripts would resolve from it through the PRODUCTION resolver. This proves which REQUEST the
#      real client would make -- never that a file changed.
#   2. INTEGRATION WITH THE REAL DAEMON AND FORMATTER. The real client and a real warm daemon over a
#      file Invoke-Formatter does change: SHA-256 of the source before and after every scan, and the
#      finding set compared with a clean-environment scan of the same bytes. Then four HOSTILE
#      daemon-side configurations (ruleExclude, ruleInclude, perFileCap, profile), each under its own
#      real daemon and each staged under the camelCase spelling only, and one end-to-end run of the
#      shipped scripts/lsp-scan.ps1 with formatOnEdit=apply left in its environment.
#
# THE MATRIX is every interactive profile (safe / recommended / strict) x every formatOnEdit state
# (unset / off / suggest / apply) -- Get-SvFormatMatrix in tests/ScanHarness.Common.ps1, which also
# records the format mode the current client resolves for each cell.
#
# THE SPELLING CHANNEL (review RC01, correction round 2). Every knob is read through
# Get-RawPluginOption (scripts/lib/lsp-common.ps1), which accepts ANY CLAUDE_PLUGIN_OPTION_* name that
# normalizes to the knob -- underscores stripped, lower-cased -- and returns the first non-blank match
# in the child's environment enumeration order, which differs from one process to the next. The
# scanner's per-child overrides (perFileCap / severityThreshold for session-start, scopeToEdit /
# timeoutMs for the client) replace only the variable they name. So a hostile value staged under that
# same camelCase spelling is replaced (the same-spelling controls), while the same value under another
# spelling reaches the child BESIDE the declared one and wins at random. The alias cases stage an
# underscore spelling (PER_FILE_CAP, ...): a separate variable on every OS, where an upper-cased
# spelling is the same variable as the camelCase one on Windows only. Each asserts the deterministic
# half first -- the hostile value reached the child under no spelling -- and only then the resolved
# value. MaxWaitMs arrives only as an argument, and the capture mode and capture log are read by exact
# name, so no other spelling reaches a reader of theirs; they stay controls.
#
# CLASSIFICATION is as in PowerShellLsp.ScanVerdict.Tests.ps1: one It per contract assertion; an It
# measured RED at the A1 head is tagged with its owner and excluded from tests/run-tests.ps1, and
# tests/assert-expected-red.ps1 proves it still fails with its declared assertion. 'ScanRed-A2' marks
# what A2's narrow formatter-off containment fixes (formatting must be OFF in every scan child, under
# every spelling of formatOnEdit); 'ScanRed-A3' marks what A3's declared scan configuration fixes
# (ambient analysis knobs, and an ambient ps_host, must not reach a scan under any spelling). A
# containment that overrides only the spelling the scan names cannot turn the alias cases green.
# Already-green cells are controls and run normally.
#
# ASCII-only (PS 5.1 Windows-1252 trap); StrictMode-safe. Run via tests/run-tests.ps1.

. (Join-Path $PSScriptRoot 'ScanHarness.Common.ps1')   # discovery: Get-SvFormatMatrix for the -ForEach tables

$script:SrOnWindows = if (Test-Path 'Variable:\IsWindows') { [bool]$IsWindows } else { $true }
$script:SrOnLinux = (Test-Path 'Variable:\IsLinux') -and [bool]$IsLinux
$script:SrOnMacOS = (Test-Path 'Variable:\IsMacOS') -and [bool]$IsMacOS
$script:SrUnsupported = -not ($script:SrOnWindows -or $script:SrOnLinux -or $script:SrOnMacOS)

# The measured split of the matrix (see Get-SvFormatMatrix).
$script:SrCellsResolveOff = @(Get-SvFormatMatrix | Where-Object { $_.ClientResolves -eq 'off' })
$script:SrCellsResolveOn = @(Get-SvFormatMatrix | Where-Object { $_.ClientResolves -ne 'off' })
$script:SrCellsNoApply = @(Get-SvFormatMatrix | Where-Object { $_.Mode -ne 'apply' })
$script:SrCellsApply = @(Get-SvFormatMatrix | Where-Object { $_.Mode -eq 'apply' })

Describe 'Scan read-only census of the configuration a scan child receives (dispatch 000302 A1)' -Skip:$script:SrUnsupported {

    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-scan-common.ps1')
        . (Join-Path $PSScriptRoot 'Integration.Common.ps1')
        . (Join-Path $PSScriptRoot 'ScanHarness.Common.ps1')
        $script:RcHost = Resolve-PsHost 'pwsh'
        if ($null -eq $script:RcHost) { throw 'no PowerShell host (pwsh / powershell) to spawn the recording fakes' }
        $script:RcSavedEnv = Save-SvAmbientEnv
        $script:RcRoots = New-Object System.Collections.ArrayList

        function Read-RcRecord {
            # The one env-<role>-*.json a recording fake left in $DataRoot.
            param([string]$DataRoot, [string]$Role)
            $files = @(Get-ChildItem -LiteralPath $DataRoot -File -Filter ('env-' + $Role + '-*.json'))
            if ($files.Count -ne 1) { throw ('expected exactly one ' + $Role + ' record in ' + $DataRoot + ', found ' + $files.Count) }
            return ([System.IO.File]::ReadAllText($files[0].FullName) | ConvertFrom-Json)
        }

        function Measure-RcClient {
            # What the scan CLIENT child receives when the ambient environment holds $Ambient
            # (option key -> value), driven by the production Invoke-ScanFileDiagnostics.
            param([string]$Tag, [hashtable]$Ambient, [hashtable]$AmbientRaw = @{})
            Restore-SvAmbientEnv -Saved @{}
            foreach ($k in $Ambient.Keys) { Set-SvAmbientOption -Key $k -Value ([string]$Ambient[$k]) }
            foreach ($k in $AmbientRaw.Keys) { [System.Environment]::SetEnvironmentVariable($k, [string]$AmbientRaw[$k]) }
            try {
                $case = Invoke-SvScanCase -HostExe $script:RcHost -Tag $Tag -ClientFixture 'env-record-client.ps1'
            } finally {
                Restore-SvAmbientEnv -Saved @{}
            }
            [void]$script:RcRoots.Add($case.Root)
            return @{ Case = $case; Record = (Read-RcRecord -DataRoot $case.DataRoot -Role 'client') }
        }

        function Measure-RcSessionStart {
            # What the scan SESSION-START child receives when the ambient environment holds $Ambient,
            # driven by the production Start-ScanDaemon (and torn down by Stop-ScanDaemon).
            param([string]$Tag, [hashtable]$Ambient)
            $root = New-SvTempRoot -Tag $Tag -MintingFile 'tests/PowerShellLsp.ScanReadOnly.Tests.ps1'
            [void]$script:RcRoots.Add($root)
            $scripts = New-SvFakeScriptsDir -Root $root -ClientFixture 'env-record-client.ps1'
            $data = Join-Path $root 'data'
            $sid = 'rc' + $Tag + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            Restore-SvAmbientEnv -Saved @{}
            foreach ($k in $Ambient.Keys) { Set-SvAmbientOption -Key $k -Value ([string]$Ambient[$k]) }
            try {
                $info = Start-ScanDaemon -ScriptsDir $scripts -DataRoot $data -SessionId $sid -HostExe $script:RcHost
                Stop-ScanDaemon -ScriptsDir $scripts -DataRoot $data -SessionId $sid -HostExe $script:RcHost -DaemonInfo $info
            } finally {
                Restore-SvAmbientEnv -Saved @{}
            }
            if ($null -eq $info) { throw ('the fake session-start never reported ready for ' + $sid) }
            return ([System.IO.File]::ReadAllText((Join-Path $data ('env-session-start-' + $sid + '.json'))) | ConvertFrom-Json)
        }

        function Get-RcSpellingLeak {
            # The entries of a child's recorded environment that hold $Value under ANY spelling the
            # production resolver maps to $Key -- Get-RawPluginOption's rule: the CLAUDE_PLUGIN_OPTION_
            # prefix matched case-insensitively, the rest with underscores stripped and lower-cased --
            # as sorted 'NAME=value' text. '' means the value reached the child under no spelling.
            param($Record, [string]$Key, [string]$Value)
            $prefix = 'CLAUDE_PLUGIN_OPTION_'
            $target = ($Key -replace '_', '').ToLowerInvariant()
            $hits = @(@($Record.env.PSObject.Properties) | Where-Object {
                    $n = [string]$_.Name
                    $n.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) -and
                    (($n.Substring($prefix.Length) -replace '_', '').ToLowerInvariant() -eq $target) -and
                    ([string]$_.Value -eq $Value)
                } | ForEach-Object { [string]$_.Name + '=' + [string]$_.Value })
            return (@($hits | Sort-Object) -join ',')
        }
    }

    AfterAll {
        Restore-SvAmbientEnv -Saved $script:RcSavedEnv
        foreach ($r in @($script:RcRoots)) { Remove-SvTempRoot -Path $r }
    }

    Context 'formatOnEdit and profile reach the scan client' {
        It 'formatOnEdit=<Mode> under profile <ProfileName> -- the scan client resolves formatting off' -ForEach $script:SrCellsResolveOff {
            $m = Measure-RcClient -Tag ('fm' + $ProfileName.Substring(0, 2) + $Mode.Substring(0, 2)) `
                -Ambient (@{ profile = $ProfileName } + $(if ($Mode -eq 'unset') { @{} } else { @{ formatOnEdit = $Mode } }))
            [string]$m.Record.formatMode | Should -BeExactly 'off' -Because ('F2 format ' + $Name + ': a scan child must never format')
        }
        It 'formatOnEdit=<Mode> under profile <ProfileName> -- the scan client resolves formatting off' -Tag 'ScanRed-A2' -ForEach $script:SrCellsResolveOn {
            $m = Measure-RcClient -Tag ('fm' + $ProfileName.Substring(0, 2) + $Mode.Substring(0, 2)) `
                -Ambient (@{ profile = $ProfileName } + $(if ($Mode -eq 'unset') { @{} } else { @{ formatOnEdit = $Mode } }))
            [string]$m.Record.formatMode | Should -BeExactly 'off' -Because ('F2 format ' + $Name + ': a scan child must never format')
        }
    }

    Context 'daemon-side knobs reach the scan session-start' {
        It 'an ambient ruleInclude does not reach the scan session-start' -Tag 'ScanRed-A3' {
            $rec = Measure-RcSessionStart -Tag 'ri' -Ambient @{ ruleInclude = 'PSAvoidUsingCmdletAliases' }
            [string]$rec.resolved.ruleInclude.value | Should -BeExactly '' -Because 'F2 ruleInclude: an ambient include list must not narrow a scan'
        }
        It 'an ambient ruleExclude does not reach the scan session-start' -Tag 'ScanRed-A3' {
            $rec = Measure-RcSessionStart -Tag 'rx' -Ambient @{ ruleExclude = 'PSUseApprovedVerbs' }
            [string]$rec.resolved.ruleExclude.value | Should -BeExactly '' -Because 'F2 ruleExclude: an ambient exclude list must not narrow a scan'
        }
        # Staged under the scan override's own spelling only. Another spelling is the alias case in the
        # Context 'other spellings of a knob reach the scan child' below, and is RED.
        It 'an ambient CLAUDE_PLUGIN_OPTION_perFileCap is replaced by the declared scan cap of 0 (same-spelling control)' {
            $rec = Measure-RcSessionStart -Tag 'pc' -Ambient @{ perFileCap = '1' }
            (Get-RcSpellingLeak -Record $rec -Key 'perFileCap' -Value '1') | Should -BeExactly '' -Because 'F2 perFileCap: the same-spelled override replaces the ambient value'
            [string]$rec.resolved.perFileCap.value | Should -BeExactly '0' -Because 'F2 perFileCap: the scan declares perFileCap=0'
        }
        It 'an ambient profile does not change the analysis defaults the scan session-start resolves' -Tag 'ScanRed-A3' {
            $rec = Measure-RcSessionStart -Tag 'pf' -Ambient @{ profile = 'strict' }
            ('ruleset=' + [string]$rec.resolved.ruleset.value + ' moduleAwareness=' + [string]$rec.resolved.moduleAwareness.value +
                ' referenceSurfacing=' + [string]$rec.resolved.referenceSurfacing.value) |
                Should -BeExactly 'ruleset=pses-default moduleAwareness=off referenceSurfacing=off' -Because 'F2 profile: an ambient profile must not change what a scan analyses'
        }
        # The scan passes its host as -PreferredHost, but session-start resolves ps_host through
        # Get-PluginOption with that argument only as the FALLBACK, so an ambient ps_host wins.
        It 'an ambient ps_host does not override the analysis host the scan declares' -Tag 'ScanRed-A3' {
            $rec = Measure-RcSessionStart -Tag 'ph' -Ambient @{ ps_host = 'powershell' }
            [string]$rec.preferredHost | Should -BeExactly 'pwsh' -Because 'F2 ps_host situation: the scan must have declared pwsh, a host other than the ambient one'
            [string]$rec.resolved.ps_host.value | Should -BeExactly 'pwsh' -Because 'F2 ps_host: an ambient ps_host must not move a scan onto another analysis host'
        }
        # Staged under the scan override's own spelling only; another spelling is RED (the alias case).
        It 'an ambient CLAUDE_PLUGIN_OPTION_severityThreshold is replaced by the declared Hint (same-spelling control)' {
            $rec = Measure-RcSessionStart -Tag 'ct' -Ambient @{ severityThreshold = 'Error' }
            (Get-RcSpellingLeak -Record $rec -Key 'severityThreshold' -Value 'Error') | Should -BeExactly '' -Because 'F2 severityThreshold: the same-spelled override replaces the ambient value'
            [string]$rec.resolved.severityThreshold.value | Should -BeExactly 'Hint'
            [string]$rec.resolved.severityThreshold.provenance | Should -BeExactly 'env'
        }
        # MaxWaitMs is not a userConfig knob and session-start does not self-source it (the knob-set
        # guard below pins that): it arrives only as the -MaxWaitMs argument, so an ambient
        # CLAUDE_PLUGIN_OPTION_ variable of its name has no reader under ANY spelling. Two spellings
        # are staged and asserted present in the child, so 15000 is earned for both.
        It 'the declared MaxWaitMs reaches the scan session-start over hostile CLAUDE_PLUGIN_OPTION_maxWaitMs and CLAUDE_PLUGIN_OPTION_MAX_WAIT_MS values (control)' {
            $rec = Measure-RcSessionStart -Tag 'mw' -Ambient @{ maxWaitMs = '1'; MAX_WAIT_MS = '1' }
            [string]$rec.env.CLAUDE_PLUGIN_OPTION_maxWaitMs | Should -BeExactly '1' -Because 'the hostile maxWaitMs must have reached the scan session-start'
            [string]$rec.env.CLAUDE_PLUGIN_OPTION_MAX_WAIT_MS | Should -BeExactly '1' -Because 'the hostile MAX_WAIT_MS must have reached the scan session-start'
            [int]$rec.maxWaitMs | Should -Be 15000
        }
    }

    Context 'declared client overrides reach the scan client' {
        # Staged under the scan overrides' own spellings only; another spelling of either knob is RED
        # (the alias cases).
        It 'ambient CLAUDE_PLUGIN_OPTION_scopeToEdit and CLAUDE_PLUGIN_OPTION_timeoutMs are replaced by the declared false and 18000 (same-spelling control)' {
            $m = Measure-RcClient -Tag 'co' -Ambient @{ scopeToEdit = 'true'; timeoutMs = '1' }
            (Get-RcSpellingLeak -Record $m.Record -Key 'scopeToEdit' -Value 'true') | Should -BeExactly '' -Because 'F2 scopeToEdit: the same-spelled override replaces the ambient value'
            (Get-RcSpellingLeak -Record $m.Record -Key 'timeoutMs' -Value '1') | Should -BeExactly '' -Because 'F2 timeoutMs: the same-spelled override replaces the ambient value'
            [string]$m.Record.resolved.scopeToEdit.value | Should -BeExactly 'False'
            [string]$m.Record.resolved.timeoutMs.value | Should -BeExactly '18000'
        }
        # The capture mode and the capture log are read by EXACT name ($env:POWERSHELL_LSP_CAPTURE_MODE
        # and $env:POWERSHELL_LSP_DOGFOOD_LOG, scripts/lib/lsp-common.ps1), never through the
        # normalizing resolver: on Windows any casing of either name is the one variable the override
        # replaces, and on Linux/macOS another casing is a separate variable nothing reads. So these two
        # have no other spelling to stage.
        It 'ambient POWERSHELL_LSP_CAPTURE_MODE and POWERSHELL_LSP_DOGFOOD_LOG are replaced by capture mode full and a private capture log (control)' {
            $m = Measure-RcClient -Tag 'cc' -Ambient @{} `
                -AmbientRaw @{ POWERSHELL_LSP_CAPTURE_MODE = 'off'; POWERSHELL_LSP_DOGFOOD_LOG = (Join-Path ([System.IO.Path]::GetTempPath()) 'psls-not-the-scan-log.jsonl') }
            [string]$m.Record.env.POWERSHELL_LSP_CAPTURE_MODE | Should -BeExactly 'full'
            [string]$m.Record.env.POWERSHELL_LSP_DOGFOOD_LOG | Should -Match 'scan-capture'
        }
        It 'with no ambient configuration at all, the scan client resolves formatting off (control)' {
            $m = Measure-RcClient -Tag 'cl' -Ambient @{}
            [string]$m.Record.formatMode | Should -BeExactly 'off'
            [string]$m.Record.resolved.formatOnEdit.provenance | Should -BeExactly 'default'
        }
    }

    # THE SPELLING CHANNEL, measured (review RC01; see the file header). Each case stages ONE hostile
    # value under an underscore spelling the resolver maps to the knob, and nothing else. Its first
    # assertion is deterministic: the hostile value must reach the child under no spelling at all. The
    # resolved value is asserted only after it, because at this head it is decided by the child's
    # environment enumeration order and on its own would pass or fail at random. Where the scan
    # declares the knob, the case first re-checks that the declared value is in force under its own
    # spelling (the situation). 'profile' is one word, so its only spelling the resolver accepts that
    # is a separate variable on every OS is one with an underscore inside it (PRO_FILE).
    Context 'other spellings of a knob reach the scan child' {
        It 'an ambient CLAUDE_PLUGIN_OPTION_PER_FILE_CAP does not reach the scan session-start beside the declared cap of 0' -Tag 'ScanRed-A3' {
            $rec = Measure-RcSessionStart -Tag 'apc' -Ambient @{ PER_FILE_CAP = '1' }
            [string]$rec.env.CLAUDE_PLUGIN_OPTION_perFileCap | Should -BeExactly '0' -Because 'F2 perFileCap alias situation: the scan must have declared its cap under its own spelling'
            (Get-RcSpellingLeak -Record $rec -Key 'perFileCap' -Value '1') | Should -BeExactly '' -Because 'F2 perFileCap alias: an ambient cap must not reach a scan child under any spelling'
            [string]$rec.resolved.perFileCap.value | Should -BeExactly '0' -Because 'F2 perFileCap alias: the scan declares perFileCap=0'
        }
        It 'an ambient CLAUDE_PLUGIN_OPTION_SEVERITY_THRESHOLD does not reach the scan session-start beside the declared Hint' -Tag 'ScanRed-A3' {
            $rec = Measure-RcSessionStart -Tag 'ast' -Ambient @{ SEVERITY_THRESHOLD = 'Error' }
            [string]$rec.env.CLAUDE_PLUGIN_OPTION_severityThreshold | Should -BeExactly 'Hint' -Because 'F2 severityThreshold alias situation: the scan must have declared Hint under its own spelling'
            (Get-RcSpellingLeak -Record $rec -Key 'severityThreshold' -Value 'Error') | Should -BeExactly '' -Because 'F2 severityThreshold alias: an ambient threshold must not reach a scan child under any spelling'
            [string]$rec.resolved.severityThreshold.value | Should -BeExactly 'Hint' -Because 'F2 severityThreshold alias: the scan declares severityThreshold=Hint'
        }
        It 'an ambient CLAUDE_PLUGIN_OPTION_RULE_INCLUDE does not reach the scan session-start' -Tag 'ScanRed-A3' {
            $rec = Measure-RcSessionStart -Tag 'ari' -Ambient @{ RULE_INCLUDE = 'PSAvoidUsingCmdletAliases' }
            (Get-RcSpellingLeak -Record $rec -Key 'ruleInclude' -Value 'PSAvoidUsingCmdletAliases') | Should -BeExactly '' -Because 'F2 ruleInclude alias: an ambient include list must not reach a scan child under any spelling'
            [string]$rec.resolved.ruleInclude.value | Should -BeExactly '' -Because 'F2 ruleInclude alias: an ambient include list must not narrow a scan'
        }
        It 'an ambient CLAUDE_PLUGIN_OPTION_RULE_EXCLUDE does not reach the scan session-start' -Tag 'ScanRed-A3' {
            $rec = Measure-RcSessionStart -Tag 'arx' -Ambient @{ RULE_EXCLUDE = 'PSUseApprovedVerbs' }
            (Get-RcSpellingLeak -Record $rec -Key 'ruleExclude' -Value 'PSUseApprovedVerbs') | Should -BeExactly '' -Because 'F2 ruleExclude alias: an ambient exclude list must not reach a scan child under any spelling'
            [string]$rec.resolved.ruleExclude.value | Should -BeExactly '' -Because 'F2 ruleExclude alias: an ambient exclude list must not narrow a scan'
        }
        It 'an ambient CLAUDE_PLUGIN_OPTION_PRO_FILE does not reach the scan session-start' -Tag 'ScanRed-A3' {
            $rec = Measure-RcSessionStart -Tag 'apf' -Ambient @{ PRO_FILE = 'strict' }
            (Get-RcSpellingLeak -Record $rec -Key 'profile' -Value 'strict') | Should -BeExactly '' -Because 'F2 profile alias: an ambient profile must not reach a scan child under any spelling'
            ('ruleset=' + [string]$rec.resolved.ruleset.value + ' moduleAwareness=' + [string]$rec.resolved.moduleAwareness.value +
                ' referenceSurfacing=' + [string]$rec.resolved.referenceSurfacing.value) |
                Should -BeExactly 'ruleset=pses-default moduleAwareness=off referenceSurfacing=off' -Because 'F2 profile alias: an ambient profile must not change what a scan analyses'
        }
        It 'an ambient CLAUDE_PLUGIN_OPTION_psHost does not reach the scan session-start' -Tag 'ScanRed-A3' {
            $rec = Measure-RcSessionStart -Tag 'aph' -Ambient @{ psHost = 'powershell' }
            [string]$rec.preferredHost | Should -BeExactly 'pwsh' -Because 'F2 ps_host alias situation: the scan must have declared pwsh, a host other than the ambient one'
            (Get-RcSpellingLeak -Record $rec -Key 'ps_host' -Value 'powershell') | Should -BeExactly '' -Because 'F2 ps_host alias: an ambient analysis host must not reach a scan child under any spelling'
            [string]$rec.resolved.ps_host.value | Should -BeExactly 'pwsh' -Because 'F2 ps_host alias: an ambient ps_host must not move a scan onto another analysis host'
        }
        It 'an ambient CLAUDE_PLUGIN_OPTION_SCOPE_TO_EDIT does not reach the scan client beside the declared false' -Tag 'ScanRed-A3' {
            $m = Measure-RcClient -Tag 'ase' -Ambient @{ SCOPE_TO_EDIT = 'true' }
            [string]$m.Record.env.CLAUDE_PLUGIN_OPTION_scopeToEdit | Should -BeExactly 'false' -Because 'F2 scopeToEdit alias situation: the scan must have declared whole-file scoping under its own spelling'
            (Get-RcSpellingLeak -Record $m.Record -Key 'scopeToEdit' -Value 'true') | Should -BeExactly '' -Because 'F2 scopeToEdit alias: an ambient scoping value must not reach a scan child under any spelling'
            [string]$m.Record.resolved.scopeToEdit.value | Should -BeExactly 'False' -Because 'F2 scopeToEdit alias: the scan declares scopeToEdit=false'
        }
        It 'an ambient CLAUDE_PLUGIN_OPTION_TIMEOUT_MS does not reach the scan client beside the declared 18000' -Tag 'ScanRed-A3' {
            $m = Measure-RcClient -Tag 'ato' -Ambient @{ TIMEOUT_MS = '1' }
            [string]$m.Record.env.CLAUDE_PLUGIN_OPTION_timeoutMs | Should -BeExactly '18000' -Because 'F2 timeoutMs alias situation: the scan must have declared its client timeout under its own spelling'
            (Get-RcSpellingLeak -Record $m.Record -Key 'timeoutMs' -Value '1') | Should -BeExactly '' -Because 'F2 timeoutMs alias: an ambient client timeout must not reach a scan child under any spelling'
            [string]$m.Record.resolved.timeoutMs.value | Should -BeExactly '18000' -Because 'F2 timeoutMs alias: the scan declares timeoutMs=18000'
        }
        It 'an ambient CLAUDE_PLUGIN_OPTION_FORMAT_ON_EDIT does not reach the scan client' -Tag 'ScanRed-A2' {
            $m = Measure-RcClient -Tag 'afo' -Ambient @{ FORMAT_ON_EDIT = 'apply' }
            (Get-RcSpellingLeak -Record $m.Record -Key 'formatOnEdit' -Value 'apply') | Should -BeExactly '' -Because 'F2 formatOnEdit alias: an ambient format mode must not reach a scan child under any spelling'
            [string]$m.Record.formatMode | Should -BeExactly 'off' -Because 'F2 formatOnEdit alias: a scan child must never format'
        }
    }

    Context 'the recording fakes resolve exactly the knobs the real scripts read' {
        BeforeAll {
            function Get-RcScriptKeys {
                param([string]$Path)
                $text = [System.IO.File]::ReadAllText($Path)
                return @([regex]::Matches($text, "Get-PluginOption(?:Int|Bool)?\s+'([A-Za-z_]+)'") |
                        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
            }
            function Get-RcFakeKeys {
                param([string]$Path)
                $text = [System.IO.File]::ReadAllText($Path)
                return @([regex]::Matches($text, "@\{ Key = '([A-Za-z_]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
            }
            $script:RcRepo = Split-Path -Parent $PSScriptRoot
        }
        It 'fake-session-start resolves the same knob set as scripts/session-start.ps1' {
            $real = Get-RcScriptKeys -Path (Join-Path $script:RcRepo 'scripts/session-start.ps1')
            $fake = Get-RcFakeKeys -Path (Get-SvFixturePath 'fake-session-start.ps1')
            $real.Count | Should -BeGreaterThan 10 -Because 'the census must find the real script''s knob reads'
            ($fake -join ',') | Should -BeExactly ($real -join ',')
        }
        It 'env-record-client resolves the same knob set as scripts/lsp-client.ps1' {
            $real = Get-RcScriptKeys -Path (Join-Path $script:RcRepo 'scripts/lsp-client.ps1')
            $fake = Get-RcFakeKeys -Path (Get-SvFixturePath 'env-record-client.ps1')
            $real.Count | Should -BeGreaterThan 10 -Because 'the census must find the real script''s knob reads'
            ($fake -join ',') | Should -BeExactly ($real -join ',')
        }
    }
}

Describe 'Scan read-only integration with the real daemon and formatter (dispatch 000302 A1)' -Skip:$script:SrUnsupported {

    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-scan-common.ps1')
        . (Join-Path $PSScriptRoot 'Integration.Common.ps1')
        . (Join-Path $PSScriptRoot 'ScanHarness.Common.ps1')
        $script:RiHost = Resolve-PsHost 'pwsh'
        if ($null -eq $script:RiHost) { throw 'no PowerShell host (pwsh / powershell) to run the real daemon' }
        $script:RiScriptsDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts'
        $script:RiScanScript = Join-Path $script:RiScriptsDir 'lsp-scan.ps1'

        # The shared, long-lived vendored data root (PSES + pinned PSSA), the same one the SARIF suite
        # uses: CI pins it with PSLS_TEST_DATA_DIR, locally it is a reusable temp cache. Never marked
        # for the janitor and never removed here; only this run's transient files go in $RiRoot.
        $script:RiData = if (-not [string]::IsNullOrWhiteSpace($env:PSLS_TEST_DATA_DIR)) {
            $env:PSLS_TEST_DATA_DIR
        } else {
            Join-Path ([System.IO.Path]::GetTempPath()) 'psls-sarifscan-test-data'
        }
        New-Item -ItemType Directory -Force -Path $script:RiData | Out-Null
        $script:RiPrevData = $env:CLAUDE_PLUGIN_DATA
        $env:CLAUDE_PLUGIN_DATA = $script:RiData
        $script:RiSavedEnv = Save-SvAmbientEnv
        $script:RiRoot = New-SvTempRoot -Tag 'ri' -MintingFile 'tests/PowerShellLsp.ScanReadOnly.Tests.ps1'

        # Idempotent bootstrap (a no-op when already vendored). EAP is relaxed around the native calls:
        # Windows PowerShell 5.1 turns a redirected native stderr line into a terminating error under Stop.
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $script:RiHost -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:RiScriptsDir 'ensure-pses.ps1') 2>&1 | Out-Null
            & $script:RiHost -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:RiScriptsDir 'ensure-pssa.ps1') 2>&1 | Out-Null
        } finally { $ErrorActionPreference = $prevEap }

        # Mis-indented on purpose (Invoke-Formatter re-indents both bodies -- the 000099 apply
        # fixture's shape), two unapproved verbs (PSUseApprovedVerbs, in the PSES default rule set),
        # and one Write-Host (PSAvoidUsingWriteHost, which only the 'base' ruleset evaluates).
        $script:RiText = "function Frobnicate-Thing {`nGet-Process`n}`nfunction Mangle-Other {`nWrite-Host 'hello'`n}`n"

        function New-RiTarget {
            # A fresh copy of the target in its own directory (so no repo settings file applies and
            # an apply in one cell can never touch another's input). Returns the file path.
            param([string]$Name)
            $dir = Join-Path $script:RiRoot ($Name -replace '[^A-Za-z0-9-]', '-')
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            $file = Join-Path $dir 'fmt-target.ps1'
            [System.IO.File]::WriteAllText($file, $script:RiText, (New-Object System.Text.UTF8Encoding($false)))
            return $file
        }

        function Invoke-RiScan {
            # One production Invoke-ScanFileDiagnostics against the given daemon session, recording the
            # source SHA-256 before and after and the finding identity.
            param([string]$SessionId, [string]$File)
            $before = Get-SvSha256 -Path $File
            $r = Invoke-ScanFileDiagnostics -ScriptsDir $script:RiScriptsDir -DataRoot $script:RiData -SessionId $SessionId `
                -HostExe $script:RiHost -FilePath $File -Cwd (Split-Path -Parent $File)
            $after = Get-SvSha256 -Path $File
            return @{ Before = $before; After = $after; Analyzed = [bool]$r.Analyzed; Keys = @(Get-SvFindingKeys -Findings @($r.Findings)); Text = (Read-SvTextFile -Path $File) }
        }

        # ONE warm daemon for the clean baseline and the whole formatter matrix, launched with a CLEAN
        # environment. formatOnEdit and the profile's format mapping are read by the CLIENT per call, so
        # each cell stages its ambient values only around its own client run.
        $script:RiSid = 'sriro-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $script:RiDaemon = Start-ScanDaemon -ScriptsDir $script:RiScriptsDir -DataRoot $script:RiData -SessionId $script:RiSid -HostExe $script:RiHost
        if ($null -eq $script:RiDaemon) { throw 'the scan daemon did not become ready (PSES bootstrap or start-up failed)' }
        [void](Wait-DaemonRequestReady -SessionId $script:RiSid -DataRoot $script:RiData -TimeoutMs 60000)

        # Warm the formatter (imported lazily on the first format request) with a suggest pass that
        # never writes, so the first apply cell is not also the formatter's cold start.
        Set-SvFormatCellEnv -ProfileName 'safe' -Mode 'suggest'
        try { [void](Invoke-RiScan -SessionId $script:RiSid -File (New-RiTarget -Name 'warmup')) } finally { Restore-SvAmbientEnv -Saved @{} }

        $script:RiBase = Invoke-RiScan -SessionId $script:RiSid -File (New-RiTarget -Name 'baseline')

        $script:RiCells = @{}
        foreach ($cell in @(Get-SvFormatMatrix)) {
            $file = New-RiTarget -Name ('cell-' + $cell.Name)
            Set-SvFormatCellEnv -ProfileName $cell.ProfileName -Mode $cell.Mode
            try { $script:RiCells[$cell.Name] = Invoke-RiScan -SessionId $script:RiSid -File $file } finally { Restore-SvAmbientEnv -Saved @{} }
        }
    }

    AfterAll {
        if ($script:RiSid) {
            Stop-ScanDaemon -ScriptsDir $script:RiScriptsDir -DataRoot $script:RiData -SessionId $script:RiSid -HostExe $script:RiHost -DaemonInfo $script:RiDaemon
        }
        Restore-SvAmbientEnv -Saved $script:RiSavedEnv
        $env:CLAUDE_PLUGIN_DATA = $script:RiPrevData
        Remove-SvTempRoot -Path $script:RiRoot
    }

    It 'the clean-environment baseline is non-vacuous -- analysed, both unapproved verbs found, source untouched' {
        $script:RiBase.Analyzed | Should -BeTrue
        @($script:RiBase.Keys | Where-Object { $_ -like 'PSUseApprovedVerbs@*' }).Count | Should -Be 2
        $script:RiBase.After | Should -BeExactly $script:RiBase.Before
    }

    It 'formatOnEdit=<Mode> under profile <ProfileName> -- the scan leaves the source bytes unchanged' -ForEach $script:SrCellsNoApply {
        $c = $script:RiCells[$Name]
        $c.Analyzed | Should -BeTrue -Because ('F2 bytes ' + $Name + ' situation: the cell must have been analysed')
        $c.After | Should -BeExactly $c.Before -Because ('F2 bytes ' + $Name + ': a scan must never write a source file')
    }
    It 'formatOnEdit=<Mode> under profile <ProfileName> -- the scan leaves the source bytes unchanged' -Tag 'ScanRed-A2' -ForEach $script:SrCellsApply {
        $c = $script:RiCells[$Name]
        $c.Analyzed | Should -BeTrue -Because ('F2 bytes ' + $Name + ' situation: the cell must have been analysed')
        $c.After | Should -BeExactly $c.Before -Because ('F2 bytes ' + $Name + ': a scan must never write a source file')
    }

    It 'formatOnEdit=<Mode> under profile <ProfileName> -- the scan reports the clean-environment finding set' -ForEach $script:SrCellsNoApply {
        $c = $script:RiCells[$Name]
        $c.Analyzed | Should -BeTrue -Because ('F2 findings ' + $Name + ' situation: the cell must have been analysed')
        ($c.Keys -join ',') | Should -BeExactly ($script:RiBase.Keys -join ',') -Because ('F2 findings ' + $Name + ': equivalent declared inputs must give the same findings')
    }
    It 'formatOnEdit=<Mode> under profile <ProfileName> -- the scan reports the clean-environment finding set' -Tag 'ScanRed-A2' -ForEach $script:SrCellsApply {
        $c = $script:RiCells[$Name]
        $c.Analyzed | Should -BeTrue -Because ('F2 findings ' + $Name + ' situation: the cell must have been analysed')
        ($c.Keys -join ',') | Should -BeExactly ($script:RiBase.Keys -join ',') -Because ('F2 findings ' + $Name + ': equivalent declared inputs must give the same findings')
    }

    Context 'hostile daemon-side configuration, each under its own real daemon' {
        BeforeAll {
            function Measure-RiHostile {
                # Launch a real scan daemon with $Ambient in the environment (the real session-start
                # reads it), scan a fresh copy with the same environment, tear the daemon down.
                param([string]$Tag, [hashtable]$Ambient)
                $sid = 'srh' + $Tag + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
                $info = $null
                Restore-SvAmbientEnv -Saved @{}
                foreach ($k in $Ambient.Keys) { Set-SvAmbientOption -Key $k -Value ([string]$Ambient[$k]) }
                try {
                    $info = Start-ScanDaemon -ScriptsDir $script:RiScriptsDir -DataRoot $script:RiData -SessionId $sid -HostExe $script:RiHost
                    if ($null -eq $info) { throw ('the hostile scan daemon (' + $Tag + ') did not become ready') }
                    [void](Wait-DaemonRequestReady -SessionId $sid -DataRoot $script:RiData -TimeoutMs 60000)
                    return (Invoke-RiScan -SessionId $sid -File (New-RiTarget -Name ('hostile-' + $Tag)))
                } finally {
                    Stop-ScanDaemon -ScriptsDir $script:RiScriptsDir -DataRoot $script:RiData -SessionId $sid -HostExe $script:RiHost -DaemonInfo $info
                    Restore-SvAmbientEnv -Saved @{}
                }
            }
        }
        It 'an ambient ruleExclude does not change the scan finding set' -Tag 'ScanRed-A3' {
            $h = Measure-RiHostile -Tag 'rx' -Ambient @{ ruleExclude = 'PSUseApprovedVerbs' }
            $h.Analyzed | Should -BeTrue -Because 'F2 hostile ruleExclude situation: the file must have been analysed'
            ($h.Keys -join ',') | Should -BeExactly ($script:RiBase.Keys -join ',') -Because 'F2 hostile ruleExclude: an ambient exclude list must not narrow a scan'
        }
        It 'an ambient ruleInclude does not change the scan finding set' -Tag 'ScanRed-A3' {
            $h = Measure-RiHostile -Tag 'ri' -Ambient @{ ruleInclude = 'PSAvoidUsingCmdletAliases' }
            $h.Analyzed | Should -BeTrue -Because 'F2 hostile ruleInclude situation: the file must have been analysed'
            ($h.Keys -join ',') | Should -BeExactly ($script:RiBase.Keys -join ',') -Because 'F2 hostile ruleInclude: an ambient include list must not narrow a scan'
        }
        # Staged under the scan override's own spelling only, which the override replaces. The same cap
        # under another spelling (CLAUDE_PLUGIN_OPTION_PER_FILE_CAP) reaches the real session-start
        # beside the declared 0 and wins at random: some real daemons then launch with -PerFileCap 1 and
        # the scan reports one finding of two while the file still reads analysed, others launch with 0.
        # An outcome that varies from run to run cannot be bounded by the oracle, so that case is not an
        # It here; its deterministic half is the RED transport case 'an ambient
        # CLAUDE_PLUGIN_OPTION_PER_FILE_CAP does not reach the scan session-start beside the declared cap
        # of 0' in the census above, and the real-daemon runs are recorded in the dispatch 000302 outbox.
        It 'an ambient CLAUDE_PLUGIN_OPTION_perFileCap does not change the scan finding set (same-spelling control)' {
            $h = Measure-RiHostile -Tag 'pc' -Ambient @{ perFileCap = '1' }
            $h.Analyzed | Should -BeTrue -Because 'F2 hostile perFileCap situation: the file must have been analysed'
            ($h.Keys -join ',') | Should -BeExactly ($script:RiBase.Keys -join ',') -Because 'F2 hostile perFileCap: an ambient cap of the same spelling as the scan override must not narrow a scan'
        }
        It 'an ambient profile does not change the scan finding set' -Tag 'ScanRed-A3' {
            $h = Measure-RiHostile -Tag 'pf' -Ambient @{ profile = 'strict' }
            $h.Analyzed | Should -BeTrue -Because 'F2 hostile profile situation: the file must have been analysed'
            ($h.Keys -join ',') | Should -BeExactly ($script:RiBase.Keys -join ',') -Because 'F2 hostile profile: an ambient profile must not change what a scan reports'
        }
    }

    Context 'the shipped CLI end to end with formatOnEdit=apply left in its environment' {
        BeforeAll {
            $script:RiCliFile = New-RiTarget -Name 'cli-apply'
            $script:RiCliBefore = Get-SvSha256 -Path $script:RiCliFile
            $sarifPath = Join-Path $script:RiRoot 'cli-apply.sarif'
            $script:RiCliRun = Invoke-SvChildProcess -HostExe $script:RiHost -CapMs 300000 `
                -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:RiScanScript,
                    (Split-Path -Parent $script:RiCliFile), '-Format', 'sarif', '-OutputPath', $sarifPath, '-PsHost', $script:RiHost) `
                -RemoveEnvPrefix @('CLAUDE_PLUGIN_OPTION_', 'POWERSHELL_LSP_') `
                -ExtraEnv @{ CLAUDE_PLUGIN_DATA = $script:RiData; CLAUDE_PLUGIN_OPTION_formatOnEdit = 'apply' }
            $script:RiCliAfter = Get-SvSha256 -Path $script:RiCliFile
            $text = Read-SvTextFile -Path $sarifPath
            $script:RiCliSarif = if (-not [string]::IsNullOrWhiteSpace($text)) { $text | ConvertFrom-Json } else { $null }
            $script:RiCliKeys = @(Get-SvSarifKeys -Sarif $script:RiCliSarif)
            # What the CLI itself reported, carried into each failure message as evidence: a scan that
            # rewrote the file and lost its findings, and still called itself complete, says so here.
            $es = if ($null -ne $script:RiCliSarif) { [string][bool]$script:RiCliSarif.runs[0].invocations[0].executionSuccessful } else { 'no-sarif' }
            $script:RiCliReport = '(the CLI reported exit=' + [int]$script:RiCliRun.ExitCode + ' executionSuccessful=' + $es + ')'
        }
        # No standalone situation It here on purpose: the CLI run exists only for these two RED cases,
        # so keeping every It in this Context tagged keeps the run out of the normal suite. Each case
        # re-checks the situation first.
        It 'the CLI scan leaves the source bytes unchanged with formatOnEdit=apply in its environment' -Tag 'ScanRed-A2' {
            $script:RiCliRun.TimedOut | Should -BeFalse -Because 'F2 CLI situation: the CLI must finish'
            $script:RiCliSarif | Should -Not -BeNullOrEmpty -Because ('F2 CLI situation: the CLI must have written its SARIF log; stderr: ' + $script:RiCliRun.Err)
            $script:RiCliAfter | Should -BeExactly $script:RiCliBefore -Because ('F2 CLI bytes: a scan must never write a source file ' + $script:RiCliReport)
        }
        It 'the CLI scan reports the clean-environment finding set with formatOnEdit=apply in its environment' -Tag 'ScanRed-A2' {
            $script:RiCliRun.TimedOut | Should -BeFalse -Because 'F2 CLI situation: the CLI must finish'
            $script:RiCliSarif | Should -Not -BeNullOrEmpty -Because ('F2 CLI situation: the CLI must have written its SARIF log; stderr: ' + $script:RiCliRun.Err)
            ($script:RiCliKeys -join ',') | Should -BeExactly ($script:RiBase.Keys -join ',') -Because ('F2 CLI findings: an ambient formatOnEdit must not change what a scan reports ' + $script:RiCliReport)
        }
    }
}
