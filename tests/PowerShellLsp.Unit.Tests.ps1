#Requires -Version 5.1

# Unit regression tests (Pester 5) for the powershell-lsp plugin. No network, no
# daemon: fast and cross-platform. Run via tests/run-tests.ps1.

BeforeAll {
    $script:PluginRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsDir = Join-Path $script:PluginRoot 'scripts'
    . (Join-Path $script:ScriptsDir 'lib/lsp-common.ps1')
    . (Join-Path $script:ScriptsDir 'lib/security-classifier.ps1')
}

# The dogfood reader is a MODULE (dispatch 000156), and its Describes below run inside
# InModuleScope so they can reach the functions no shipped caller invokes without those
# functions being exported. InModuleScope is resolved during Pester's DISCOVERY pass, so the
# module has to be imported HERE at file scope -- a module imported only in BeforeAll (run
# phase) is not loaded yet when discovery evaluates InModuleScope, and discovery fails with
# "No modules named 'dogfood-reader' are currently loaded".
Import-Module (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts') 'lib/dogfood-reader.psd1') `
    -Force -DisableNameChecking

# Drive-letter casing is a Windows concept; on *nix 'c:\x' is not a drive path,
# so these specific assertions are Windows-only (the rest of the suite is not).
$script:OnWindows = if (Test-Path 'Variable:\IsWindows') { [bool]$IsWindows } else { $true }

Describe 'ConvertTo-FileUri -- URI drive-letter casing (regression: lowercased drive mismatch)' -Skip:(-not $script:OnWindows) {
    It 'uppercases a lowercase drive letter' {
        ConvertTo-FileUri 'c:\temp\foo.ps1' | Should -Match '^file:///C:/'
    }
    It 'keeps an already-uppercase drive letter uppercase' {
        ConvertTo-FileUri 'C:\temp\foo.ps1' | Should -Match '^file:///C:/'
    }
    It 'uses forward slashes and the file scheme' {
        ConvertTo-FileUri 'C:\a\b\c.ps1' | Should -Be 'file:///C:/a/b/c.ps1'
    }
    It 'percent-encodes spaces in the path' {
        ConvertTo-FileUri 'C:\a b\c.ps1' | Should -Match 'file:///C:/a%20b/c.ps1'
    }
}

Describe 'ConvertTo-UriKey -- case-insensitive URI matching (regression: PSES lowercases the Windows drive)' {
    # Guard 2b -- the MATCH side of landmine 1 (the construction side is the
    # ConvertTo-FileUri block above). ConvertTo-FileUri emits an UPPERCASE drive,
    # but PSES echoes the drive back LOWERCASED in publishDiagnostics. The daemon
    # keys both the stored publish (Invoke-LspMessage) and the request lookup
    # (Get-Diagnostics) through ConvertTo-UriKey so a lowercased-drive publish still
    # matches the document we opened -- otherwise diagnostics are silently dropped.
    # Adversarial control: make ConvertTo-UriKey return $Uri unchanged and the
    # 'maps ... to the same key' assertion goes RED.
    # NOTE: assertions use -BeExactly (case-SENSITIVE). Pester's plain -Be folds
    # case, which would mask the very mismatch this guards -- with -Be the key
    # equality would pass even if ConvertTo-UriKey did nothing, making the test
    # decorative. -BeExactly is what gives the adversarial control teeth.
    It 'maps an uppercase-drive and a lowercase-drive URI to the same key' {
        $upper = 'file:///C:/temp/foo.ps1'    # what ConvertTo-FileUri emits
        $lower = 'file:///c:/temp/foo.ps1'    # what PSES echoes back
        $upper | Should -Not -BeExactly $lower                # they differ before keying
        (ConvertTo-UriKey $upper) | Should -BeExactly (ConvertTo-UriKey $lower)
    }
    It 'round-trips a real ConvertTo-FileUri result against a lowercased-drive publish' -Skip:(-not $script:OnWindows) {
        $ours = ConvertTo-FileUri 'C:\temp\foo.ps1'           # file:///C:/temp/foo.ps1
        $psesEcho = $ours.Substring(0, 8) + $ours.Substring(8, 1).ToLowerInvariant() + $ours.Substring(9)
        $ours | Should -Not -BeExactly $psesEcho              # raw URIs mismatch on drive case
        (ConvertTo-UriKey $ours) | Should -BeExactly (ConvertTo-UriKey $psesEcho)
    }
}

Describe 'New-InitializeCapabilities -- rename capability (INVERTED from the dispatch text)' {
    # The dispatch frontmatter and the build brief both said "do not advertise
    # rename capability". That is EMPIRICALLY BACKWARDS for PSES v4.6.0: omitting
    # rename makes PrepareRenameHandler dereference a null RenameCapability and the
    # server never answers initialize (probe-verified 2026-06-05). Declaring a
    # minimal rename capability is what AVOIDS the NRE. These tests guard the
    # CORRECT invariant so a future edit cannot silently re-introduce the hang.
    It 'declares textDocument.rename (this is what avoids the v4.6.0 NRE)' {
        (New-InitializeCapabilities).textDocument.rename | Should -Not -BeNullOrEmpty
    }
    It 'declares prepareSupport on rename' {
        (New-InitializeCapabilities).textDocument.rename.prepareSupport | Should -BeTrue
    }
    It 'still declares synchronization and publishDiagnostics' {
        $caps = New-InitializeCapabilities
        $caps.textDocument.synchronization.didOpen | Should -BeTrue
        $caps.textDocument.publishDiagnostics | Should -Not -BeNullOrEmpty
    }
}

Describe 'New-InitializeParams -- omits workspaceFolders (regression: PSES #2300 OnInitialize NRE on Linux)' {
    # Guard 3 -- landmine 3. PSES v4.6.0 throws a NullReferenceException in its own
    # OnInitialize handler (the workspaceFolders add path) on Linux when initialize
    # carries a top-level workspaceFolders member (upstream #2300). The daemon dodges
    # it by OMITTING that member and relying on rootUri alone. This is the client-side
    # workaround being pinned; it does NOT fix the upstream bug. Adversarial control:
    # add a workspaceFolders key to New-InitializeParams and the 'does NOT include'
    # assertion goes RED.
    BeforeAll {
        $script:InitParams = New-InitializeParams -RootUri 'file:///C:/proj' -ProcessId 4242
    }
    It 'does NOT include a top-level workspaceFolders member (the #2300 dodge)' {
        $script:InitParams.ContainsKey('workspaceFolders') | Should -BeFalse
    }
    It 'still carries rootUri, processId, clientInfo, and capabilities' {
        $script:InitParams.rootUri | Should -Be 'file:///C:/proj'
        $script:InitParams.processId | Should -Be 4242
        $script:InitParams.clientInfo | Should -Not -BeNullOrEmpty
        $script:InitParams.capabilities | Should -Not -BeNullOrEmpty
    }
    It 'still declares the workspaceFolders CAPABILITY boolean -- distinct from the params member that trips the NRE' {
        # capabilities.workspace.workspaceFolders = $true is SAFE (it only advertises
        # support); it is the params-level folder list that is omitted. This guards
        # that a future edit does not "fix" #2300 by dropping the capability (which
        # would not help) instead of keeping the params member omitted.
        $script:InitParams.capabilities.workspace.workspaceFolders | Should -BeTrue
    }
}

Describe 'Resolve-PsHost -- shared host detection' {
    It 'returns a usable host (pwsh or powershell) on this machine' {
        Resolve-PsHost 'pwsh' | Should -BeIn @('pwsh', 'powershell')
    }
    It 'honors an explicit available preference first' {
        # powershell.exe exists on Windows CI/dev; on *nix this falls through to pwsh.
        Resolve-PsHost (Resolve-PsHost 'pwsh') | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-PluginOption / Get-PluginOptionInt -- userConfig env fallback (v1.1.1 first-run fix)' {
    # v1.1.1: hooks stopped passing ${user_config.*} (CC v2.1.167 refused to launch a
    # hook when any referenced option was unset). Config now comes from the exported
    # CLAUDE_PLUGIN_OPTION_* env vars with a fallback default, so a stranger with zero
    # saved config never gets a hard error. These guard that fallback.
    BeforeEach {
        Get-ChildItem Env: | Where-Object { $_.Name -like 'CLAUDE_PLUGIN_OPTION_*' } |
            ForEach-Object { Remove-Item -LiteralPath ('Env:' + $_.Name) -ErrorAction SilentlyContinue }
    }
    AfterEach {
        Get-ChildItem Env: | Where-Object { $_.Name -like 'CLAUDE_PLUGIN_OPTION_*' } |
            ForEach-Object { Remove-Item -LiteralPath ('Env:' + $_.Name) -ErrorAction SilentlyContinue }
    }
    It 'returns the default when the option is unset' {
        Get-PluginOption 'ps_host' 'pwsh' | Should -Be 'pwsh'
    }
    It 'returns the default when the value is blank' {
        $env:CLAUDE_PLUGIN_OPTION_ps_host = '   '
        Get-PluginOption 'ps_host' 'pwsh' | Should -Be 'pwsh'
    }
    It 'reads a set value' {
        $env:CLAUDE_PLUGIN_OPTION_ps_host = 'powershell'
        Get-PluginOption 'ps_host' 'pwsh' | Should -Be 'powershell'
    }
    It 'matches regardless of exported-name casing (UPPER_SNAKE)' {
        $env:CLAUDE_PLUGIN_OPTION_PS_HOST = 'powershell'
        Get-PluginOption 'ps_host' 'pwsh' | Should -Be 'powershell'
    }
    It 'Get-PluginOptionInt parses a numeric value' {
        $env:CLAUDE_PLUGIN_OPTION_timeoutMs = '8000'
        Get-PluginOptionInt 'timeoutMs' 5000 | Should -Be 8000
    }
    It 'Get-PluginOptionInt falls back on an unexpanded token' {
        $env:CLAUDE_PLUGIN_OPTION_timeoutMs = '${user_config.timeoutMs}'
        Get-PluginOptionInt 'timeoutMs' 5000 | Should -Be 5000
    }
    It 'Get-PluginOptionInt falls back when unset' {
        Get-PluginOptionInt 'perFileCap' 20 | Should -Be 20
    }
}

Describe 'Get-PluginOptionBool -- boolean userConfig (Track A enableStats)' {
    # The manifest types every option as a STRING, so a boolean knob arrives as the
    # text 'true'/'false'/etc. Get-PluginOptionBool maps the truthy/falsey tokens and
    # falls back (like Get-PluginOptionInt) on absent / blank / unexpanded token.
    BeforeEach {
        Get-ChildItem Env: | Where-Object { $_.Name -like 'CLAUDE_PLUGIN_OPTION_*' } |
            ForEach-Object { Remove-Item -LiteralPath ('Env:' + $_.Name) -ErrorAction SilentlyContinue }
    }
    AfterEach {
        Get-ChildItem Env: | Where-Object { $_.Name -like 'CLAUDE_PLUGIN_OPTION_*' } |
            ForEach-Object { Remove-Item -LiteralPath ('Env:' + $_.Name) -ErrorAction SilentlyContinue }
    }
    It 'defaults to $false when unset' {
        Get-PluginOptionBool 'enableStats' | Should -BeFalse
    }
    It 'honors a non-default fallback when unset' {
        Get-PluginOptionBool 'enableStats' $true | Should -BeTrue
    }
    It 'reads "<_>" as true' -ForEach @('true', '1', 'yes', 'on', 'TRUE', 'On') {
        $env:CLAUDE_PLUGIN_OPTION_enableStats = $_
        Get-PluginOptionBool 'enableStats' | Should -BeTrue
    }
    It 'reads "<_>" as false (overriding a true default)' -ForEach @('false', '0', 'no', 'off', 'FALSE') {
        $env:CLAUDE_PLUGIN_OPTION_enableStats = $_
        Get-PluginOptionBool 'enableStats' $true | Should -BeFalse
    }
    It 'falls back on an unexpanded user_config token' {
        $env:CLAUDE_PLUGIN_OPTION_enableStats = '${user_config.enableStats}'
        Get-PluginOptionBool 'enableStats' $false | Should -BeFalse
    }
    It 'falls back to the default on an unrecognized value' {
        $env:CLAUDE_PLUGIN_OPTION_enableStats = 'maybe'
        Get-PluginOptionBool 'enableStats' $true | Should -BeTrue
    }
}

Describe 'profile meta-knob -- precedence and the ruled constants (dispatch 000166 B8)' {
    # `profile` is a PRESET over the other knobs, resolved BETWEEN an explicitly-set knob and
    # the shipped default: explicit > profile > default. These guards pin the three things the
    # 1.x contract actually rests on.
    #
    # (1) THE BYTE-IDENTITY OBLIGATION. With `profile` unset OR set to `safe`, every knob must
    #     resolve to the value it resolved to before this knob existed. The ground truth is
    #     NOT a literal table copied into this file -- it is the DEFAULT the caller passes,
    #     read back out. So the assertion is "the resolver returned the caller's default,
    #     unchanged", which is the actual property, and a mapping bug under `safe` fails it
    #     regardless of what any table says the defaults are.
    #
    # (2) EXPLICIT BEATS PROFILE. If a profile could override a value a user set, every
    #     existing 1.x config silently changes meaning on upgrade -- CONTRACT.md:178-184 makes
    #     that a MAJOR. Asserted on a knob the profile DOES map, with the explicit value set to
    #     something the profile would otherwise have changed, so the test can only pass by
    #     precedence and never by coincidence.
    #
    # (3) THE RULED CONSTANTS. nativeServe stays `off` (ruling R2), enableStats stays `false`
    #     (R3b), and formatOnEdit `apply` appears in NO profile. These are asserted over EVERY
    #     profile value -- including the unknown-value degrade path -- rather than over a
    #     sampled one, because the failure they guard against is a future re-mapping quietly
    #     adding one of them to a single profile.
    #
    # VACUITY: a positive control asserts that `recommended` DOES change something. Without it
    # a resolver that returned $Default unconditionally -- i.e. a profile knob that does
    # nothing at all -- would satisfy every "safe is unchanged" and "constant stays off"
    # assertion in this Describe.
    BeforeAll {
        # The shipped defaults, as the CALLERS pass them (session-start.ps1 / lsp-client.ps1).
        $script:ShippedDefaults = [ordered]@{
            'ps_host'            = 'pwsh'
            'severityThreshold'  = 'Hint'
            'ruleInclude'        = ''
            'ruleExclude'        = ''
            'timeoutMs'          = '5000'
            'debounceMs'         = '150'
            'keepLastN'          = '10'
            'idleTtlMin'         = '30'
            'perFileCap'         = '20'
            'enableStats'        = 'false'
            'settingsPath'       = ''
            'scopeToEdit'        = 'true'
            'editContextLines'   = '0'
            'formatOnEdit'       = 'off'
            'ruleset'            = 'pses-default'
            'moduleAwareness'    = 'off'
            'nativeServe'        = 'off'
            'referenceSurfacing' = 'off'
            'orgPolicy'          = ''
        }
        $script:AllProfileValues = @('safe', 'recommended', 'strict')
    }
    BeforeEach {
        Get-ChildItem Env: | Where-Object { $_.Name -like 'CLAUDE_PLUGIN_OPTION_*' } |
            ForEach-Object { Remove-Item -LiteralPath ('Env:' + $_.Name) -ErrorAction SilentlyContinue }
    }
    AfterEach {
        Get-ChildItem Env: | Where-Object { $_.Name -like 'CLAUDE_PLUGIN_OPTION_*' } |
            ForEach-Object { Remove-Item -LiteralPath ('Env:' + $_.Name) -ErrorAction SilentlyContinue }
    }

    It 'with profile UNSET, every knob resolves to its shipped default (byte-identical surface)' {
        $script:ShippedDefaults.Keys.Count | Should -BeGreaterThan 15   # vacuity floor
        foreach ($k in $script:ShippedDefaults.Keys) {
            (Get-PluginOption $k $script:ShippedDefaults[$k]) | Should -BeExactly $script:ShippedDefaults[$k] -Because "knob '$k' must be untouched when no profile is set"
        }
    }
    It 'with profile=safe, every knob resolves to its shipped default (byte-identical surface)' {
        $env:CLAUDE_PLUGIN_OPTION_profile = 'safe'
        foreach ($k in $script:ShippedDefaults.Keys) {
            (Get-PluginOption $k $script:ShippedDefaults[$k]) | Should -BeExactly $script:ShippedDefaults[$k] -Because "knob '$k' must be untouched under the safe profile"
        }
    }
    It 'an UNRECOGNIZED profile value degrades to safe rather than to a partial preset' {
        $env:CLAUDE_PLUGIN_OPTION_profile = 'aggressive'
        foreach ($k in $script:ShippedDefaults.Keys) {
            (Get-PluginOption $k $script:ShippedDefaults[$k]) | Should -BeExactly $script:ShippedDefaults[$k]
        }
    }
    It 'POSITIVE CONTROL: recommended actually changes the surface (so the guards above are not vacuous)' {
        $env:CLAUDE_PLUGIN_OPTION_profile = 'recommended'
        $changed = @($script:ShippedDefaults.Keys | Where-Object {
            (Get-PluginOption $_ $script:ShippedDefaults[$_]) -cne $script:ShippedDefaults[$_]
        })
        $changed.Count | Should -BeGreaterThan 0
        # Named, so a mapping that drifted to changing something ELSE is a red, not a pass.
        $changed | Should -Contain 'ruleset'
        (Get-PluginOption 'ruleset' 'pses-default') | Should -BeExactly 'base'
    }
    It 'an explicitly-set knob BEATS the profile value (<_>)' -ForEach @('recommended', 'strict') {
        $env:CLAUDE_PLUGIN_OPTION_profile = $_
        # `ruleset` is mapped to 'base' by both profiles; setting it back explicitly must win.
        (Get-PluginOption 'ruleset' 'pses-default') | Should -BeExactly 'base'   # profile applies first
        $env:CLAUDE_PLUGIN_OPTION_ruleset = 'pses-default'
        (Get-PluginOption 'ruleset' 'pses-default') | Should -BeExactly 'pses-default'
        # ...and an explicit value the profile never mentions is honored too.
        $env:CLAUDE_PLUGIN_OPTION_perFileCap = '7'
        (Get-PluginOptionInt 'perFileCap' 20) | Should -Be 7
    }
    It 'nativeServe reads off under EVERY profile value (ruling R2)' {
        foreach ($p in $script:AllProfileValues) {
            $env:CLAUDE_PLUGIN_OPTION_profile = $p
            (Get-PluginOption 'nativeServe' 'off') | Should -BeExactly 'off' -Because "profile '$p' must not put the shim in front of users"
        }
    }
    It 'enableStats reads false under EVERY profile value (ruling R3b)' {
        foreach ($p in $script:AllProfileValues) {
            $env:CLAUDE_PLUGIN_OPTION_profile = $p
            (Get-PluginOption 'enableStats' 'false') | Should -BeExactly 'false' -Because "profile '$p' must not enable stats before path redaction ships"
            (Get-PluginOptionBool 'enableStats' $false) | Should -BeFalse
        }
    }
    It 'formatOnEdit never resolves to apply under any profile value' {
        foreach ($p in $script:AllProfileValues) {
            $env:CLAUDE_PLUGIN_OPTION_profile = $p
            (Get-PluginOption 'formatOnEdit' 'off') | Should -Not -BeExactly 'apply' -Because "a preset must never silently rewrite a user's file"
        }
    }
    It 'the mapping tables themselves contain no ruled-out value (guards a FUTURE re-mapping)' {
        # Reads the shipped mapping directly rather than only its resolved output: a re-mapping
        # that added nativeServe='shim' to a profile would be caught here even if some future
        # resolver change stopped surfacing it.
        foreach ($p in $script:AllProfileValues) {
            foreach ($k in @('nativeServe', 'enableStats')) {
                (Get-ProfileKnobValue -ProfileName $p -Key $k) | Should -BeExactly '' -Because "profile '$p' must not map '$k' at all"
            }
            (Get-ProfileKnobValue -ProfileName $p -Key 'formatOnEdit') | Should -Not -BeExactly 'apply'
            # orgPolicy is the intended STRICT slot but a profile cannot hardcode a site path.
            (Get-ProfileKnobValue -ProfileName $p -Key 'orgPolicy') | Should -BeExactly ''
        }
    }
    It 'timeoutMs is not a departure in any profile (OQ2: measured p95 leaves headroom under 5000)' {
        foreach ($p in $script:AllProfileValues) {
            $env:CLAUDE_PLUGIN_OPTION_profile = $p
            (Get-PluginOptionInt 'timeoutMs' 5000) | Should -Be 5000
        }
    }
    It 'strict is a SUPERSET of recommended (the charter shape), plus exactly three departures' {
        $rec = @{}; foreach ($k in $script:ShippedDefaults.Keys) { $rec[$k] = (Get-ProfileKnobValue -ProfileName 'recommended' -Key $k) }
        $str = @{}; foreach ($k in $script:ShippedDefaults.Keys) { $str[$k] = (Get-ProfileKnobValue -ProfileName 'strict' -Key $k) }
        foreach ($k in $script:ShippedDefaults.Keys) {
            if (-not [string]::IsNullOrWhiteSpace($rec[$k])) {
                $str[$k] | Should -BeExactly $rec[$k] -Because "strict carries all of recommended; '$k' drifted"
            }
        }
        $extra = @($script:ShippedDefaults.Keys | Where-Object {
            [string]::IsNullOrWhiteSpace($rec[$_]) -and -not [string]::IsNullOrWhiteSpace($str[$_])
        } | Sort-Object)
        ($extra -join ',') | Should -BeExactly 'keepLastN,perFileCap,scopeToEdit'
    }
    It 'the profile knob is never itself profile-resolved (no recursion, no self-selection)' {
        $env:CLAUDE_PLUGIN_OPTION_profile = 'strict'
        (Get-PluginOption 'profile' 'safe') | Should -BeExactly 'strict'
        Remove-Item -LiteralPath 'Env:CLAUDE_PLUGIN_OPTION_profile' -ErrorAction SilentlyContinue
        (Get-PluginOption 'profile' 'safe') | Should -BeExactly 'safe'
    }
}

Describe 'Data-root provenance seam (dispatch 000185 D1-A) -- legible resolution, unchanged behavior' {
    # THE POINT OF THIS SUITE. Get-PluginDataRoot substitutes a temp fallback SILENTLY when
    # CLAUDE_PLUGIN_DATA is unset, and nothing in its return value says which branch was taken.
    # A reader that searches the substituted root then publishes 'absent' -- a claim about the
    # WORLD -- on evidence that only supports 'not found here' -- a claim about the READER. The
    # seam makes the resolution legible WITHOUT changing what Get-PluginDataRoot returns, because
    # out-of-band invocations and this very suite depend on the fallback continuing to exist.
    BeforeEach {
        $script:PrevRootData = $env:CLAUDE_PLUGIN_DATA
    }
    AfterEach {
        if ($null -eq $script:PrevRootData) {
            Remove-Item -LiteralPath 'Env:CLAUDE_PLUGIN_DATA' -ErrorAction SilentlyContinue
        } else {
            $env:CLAUDE_PLUGIN_DATA = $script:PrevRootData
        }
    }

    It 'PINS Get-PluginDataRoot output under a SET CLAUDE_PLUGIN_DATA -- byte-identical, unchanged' {
        $env:CLAUDE_PLUGIN_DATA = 'C:\pinned\data\root'
        (Get-PluginDataRoot) | Should -BeExactly 'C:\pinned\data\root'
    }

    It 'PINS Get-PluginDataRoot output under an UNSET CLAUDE_PLUGIN_DATA -- the temp fallback SURVIVES' {
        # The fallback is deliberately NOT removed, narrowed or made strict (000185 do_not). This
        # asserts the exact prior value, so a change that made resolution strict goes RED here.
        Remove-Item -LiteralPath 'Env:CLAUDE_PLUGIN_DATA' -ErrorAction SilentlyContinue
        $expected = Join-Path ([System.IO.Path]::GetTempPath()) 'powershell-lsp-data'
        (Get-PluginDataRoot) | Should -BeExactly $expected
    }

    It 'the resolution object returns the IDENTICAL root Get-PluginDataRoot returns, both ways' {
        $env:CLAUDE_PLUGIN_DATA = 'C:\pinned\data\root'
        (Get-PluginDataRootResolution).Root | Should -BeExactly (Get-PluginDataRoot)
        Remove-Item -LiteralPath 'Env:CLAUDE_PLUGIN_DATA' -ErrorAction SilentlyContinue
        (Get-PluginDataRootResolution).Root | Should -BeExactly (Get-PluginDataRoot)
    }

    It 'reports Known/Provenance from the env var -- the fact the old return value could not carry' {
        $env:CLAUDE_PLUGIN_DATA = 'C:\pinned\data\root'
        $r = Get-PluginDataRootResolution
        $r.Known | Should -BeTrue
        $r.Provenance | Should -BeExactly 'env:CLAUDE_PLUGIN_DATA'

        Remove-Item -LiteralPath 'Env:CLAUDE_PLUGIN_DATA' -ErrorAction SilentlyContinue
        $r = Get-PluginDataRootResolution
        $r.Known | Should -BeFalse
        $r.Provenance | Should -BeExactly 'fallback:temp'
    }

    It 'RED control: the predicate DISCRIMINATES -- it is not hard-wired to either answer' {
        # A predicate that always returned $true (or always $false) would satisfy a one-direction
        # test. Both directions are asserted in ONE It, plus their inequality, so a constant-return
        # implementation cannot pass.
        $env:CLAUDE_PLUGIN_DATA = 'C:\pinned\data\root'
        $set = Test-PluginDataRootKnown
        Remove-Item -LiteralPath 'Env:CLAUDE_PLUGIN_DATA' -ErrorAction SilentlyContinue
        $unset = Test-PluginDataRootKnown
        $set | Should -BeTrue
        $unset | Should -BeFalse
        $set | Should -Not -Be $unset
    }

    It 'the predicate cannot disagree with the resolution object -- one implementation, two shapes' {
        foreach ($v in @('C:\pinned\data\root', '')) {
            if ([string]::IsNullOrEmpty($v)) { Remove-Item -LiteralPath 'Env:CLAUDE_PLUGIN_DATA' -ErrorAction SilentlyContinue }
            else { $env:CLAUDE_PLUGIN_DATA = $v }
            (Test-PluginDataRootKnown) | Should -Be ([bool](Get-PluginDataRootResolution).Known)
        }
    }
}

Describe 'Write-StatsLine -- telemetry writer (Track A: JSONL, append, rotation, fail-safe)' {
    # Stats land under Get-LogDir, which keys off CLAUDE_PLUGIN_DATA -- so each test
    # points it at a throwaway temp root and cleans up after.
    BeforeEach {
        $script:PrevData = $env:CLAUDE_PLUGIN_DATA
        $script:TmpData = Join-Path ([System.IO.Path]::GetTempPath()) ('psls-stats-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $env:CLAUDE_PLUGIN_DATA = $script:TmpData
        $script:StatsFile = Join-Path (Get-LogDir) 'stats.jsonl'
    }
    AfterEach {
        if (Test-Path -LiteralPath $script:TmpData) { Remove-Item -LiteralPath $script:TmpData -Recurse -Force -ErrorAction SilentlyContinue }
        if ($null -eq $script:PrevData) {
            Remove-Item -LiteralPath 'Env:CLAUDE_PLUGIN_DATA' -ErrorAction SilentlyContinue
        } else {
            $env:CLAUDE_PLUGIN_DATA = $script:PrevData
        }
    }
    It 'writes exactly one JSONL line that round-trips with its fields' {
        Write-StatsLine @{ ts = 'T'; taken = 'daemon-analyze'; totalMs = 42; records = 3 }
        $lines = @(Get-Content -LiteralPath $script:StatsFile)
        $lines.Count | Should -Be 1
        $obj = $lines[0] | ConvertFrom-Json
        $obj.taken | Should -BeExactly 'daemon-analyze'
        $obj.totalMs | Should -Be 42
        $obj.records | Should -Be 3
    }
    It 'appends (does not overwrite) across calls' {
        Write-StatsLine @{ taken = 'a' }
        Write-StatsLine @{ taken = 'b' }
        @(Get-Content -LiteralPath $script:StatsFile).Count | Should -Be 2
    }
    It 'rotates to stats.jsonl.1 once the cap is exceeded (single rollover)' {
        # Tiny cap: the first write creates the file; the second sees it over-cap and
        # rolls it to .1 before writing a fresh live file.
        Write-StatsLine -Record @{ taken = 'first' } -CapBytes 5
        Write-StatsLine -Record @{ taken = 'second' } -CapBytes 5
        (Test-Path -LiteralPath ($script:StatsFile + '.1')) | Should -BeTrue
        $live = @(Get-Content -LiteralPath $script:StatsFile)
        $live.Count | Should -Be 1
        ($live[0] | ConvertFrom-Json).taken | Should -BeExactly 'second'
        (@(Get-Content -LiteralPath ($script:StatsFile + '.1'))[0] | ConvertFrom-Json).taken | Should -BeExactly 'first'
    }
    It 'is fail-safe: a directory squatting the stats path does not throw' {
        # Force a write failure: create a directory where stats.jsonl should be. The
        # writer must swallow it (best-effort) and never throw to its caller.
        New-Item -ItemType Directory -Force -Path $script:StatsFile | Out-Null
        { Write-StatsLine @{ taken = 'blocked' } } | Should -Not -Throw
    }
}

Describe 'Dogfood diagnostic capture (dispatch 000039)' {
    # The capture side-channel mirrors Write-StatsLine's fail-safe contract: append-only
    # JSONL, best-effort, never alters the diagnostics surface or the exit code. The log path
    # is redirected to a throwaway temp file via the POWERSHELL_LSP_DOGFOOD_LOG override so
    # these never touch the real (gitignored) dogfood/ tree.
    BeforeEach {
        $script:PrevDfLog = $env:POWERSHELL_LSP_DOGFOOD_LOG
        $script:DfDir = Join-Path $TestDrive ('df-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $script:DfDir | Out-Null
        $script:DfLog = Join-Path $script:DfDir 'diagnostics.jsonl'
        $env:POWERSHELL_LSP_DOGFOOD_LOG = $script:DfLog
    }
    AfterEach {
        if ($null -eq $script:PrevDfLog) {
            Remove-Item -LiteralPath 'Env:POWERSHELL_LSP_DOGFOOD_LOG' -ErrorAction SilentlyContinue
        } else {
            $env:POWERSHELL_LSP_DOGFOOD_LOG = $script:PrevDfLog
        }
    }

    Context 'Get-DiagnosticShapeHash -- stable analysis-time dedup key (OQ2 normalization)' {
        It 'is identical for identical (rule, line)' {
            (Get-DiagnosticShapeHash -RuleId 'PSUseApprovedVerbs' -OffendingLine 'function Frob-X {') |
                Should -BeExactly (Get-DiagnosticShapeHash -RuleId 'PSUseApprovedVerbs' -OffendingLine 'function Frob-X {')
        }
        It 'collapses interior whitespace and trims (same shape -> same hash)' {
            (Get-DiagnosticShapeHash -RuleId 'R' -OffendingLine '  a   b  ') |
                Should -BeExactly (Get-DiagnosticShapeHash -RuleId 'R' -OffendingLine 'a b')
        }
        It 'differs across distinct rule ids (same line)' {
            (Get-DiagnosticShapeHash -RuleId 'R1' -OffendingLine 'x') |
                Should -Not -BeExactly (Get-DiagnosticShapeHash -RuleId 'R2' -OffendingLine 'x')
        }
        It 'differs across distinct lines (same rule)' {
            (Get-DiagnosticShapeHash -RuleId 'R' -OffendingLine 'x') |
                Should -Not -BeExactly (Get-DiagnosticShapeHash -RuleId 'R' -OffendingLine 'y')
        }
        It 'PRESERVES case -- lines differing only in case do NOT collapse (the conservative OQ2 choice)' {
            # Lowercasing would risk collapsing genuinely distinct lines (e.g. two string
            # literals differing only in case), so case is preserved. Adversarial control:
            # add .ToLowerInvariant() to the normalization and this goes RED.
            (Get-DiagnosticShapeHash -RuleId 'R' -OffendingLine 'Get-Item') |
                Should -Not -BeExactly (Get-DiagnosticShapeHash -RuleId 'R' -OffendingLine 'get-item')
        }
        It 'does not collide across the rule/line boundary (separator works)' {
            (Get-DiagnosticShapeHash -RuleId 'AB' -OffendingLine '') |
                Should -Not -BeExactly (Get-DiagnosticShapeHash -RuleId 'A' -OffendingLine 'B')
        }
        It 'is a 64-char lowercase hex SHA-256 digest' {
            (Get-DiagnosticShapeHash -RuleId 'R' -OffendingLine 'x') | Should -Match '^[0-9a-f]{64}$'
        }
    }

    Context 'record normalizers -- the two emit-site shapes' {
        It 'New-CaptureRecordFromDiag maps a PSSA diagnostic (code -> ruleId, source kept)' {
            $d = [pscustomobject]@{ severity = 'Warning'; line = 9; col = 5; source = 'PSScriptAnalyzer'; code = 'PSUseApprovedVerbs'; message = 'verb' }
            $r = New-CaptureRecordFromDiag $d
            $r.ruleId | Should -BeExactly 'PSUseApprovedVerbs'
            $r.source | Should -BeExactly 'PSScriptAnalyzer'
            $r.severity | Should -BeExactly 'Warning'
            $r.line | Should -Be 9
            $r.col | Should -Be 5
        }
        It 'New-CaptureRecordFromDiag falls back to source=parser and ruleId="" on a no-source/no-code diag' {
            $d = [pscustomobject]@{ severity = 'Error'; line = 1; col = 1; source = ''; code = ''; message = 'm' }
            $r = New-CaptureRecordFromDiag $d
            $r.source | Should -BeExactly 'parser'
            $r.ruleId | Should -BeExactly ''
        }
        It 'New-CaptureRecordFromDiag treats a "0" code as no rule id' {
            $d = [pscustomobject]@{ severity = 'Error'; line = 1; col = 1; source = 'X'; code = '0'; message = 'm' }
            (New-CaptureRecordFromDiag $d).ruleId | Should -BeExactly ''
        }
        It 'New-CaptureRecordFromParseError maps a real ParseError (source=parser, severity=Error, ErrorId)' {
            $t = $null; $e = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput("function X {`n  Get-Process", [ref]$t, [ref]$e)
            $r = New-CaptureRecordFromParseError $e[0]
            $r.source | Should -BeExactly 'parser'
            $r.severity | Should -BeExactly 'Error'
            $r.ruleId | Should -Not -BeNullOrEmpty       # the parser's ErrorId (e.g. MissingEndCurlyBrace)
            $r.line | Should -BeGreaterThan 0
        }
    }

    Context 'Add-DiagnosticCaptureEntries -- append-only JSONL, every occurrence, fail-safe' {
        It 'appends one entry carrying every required field, with verdict present and EMPTY' {
            $src = Join-Path $script:DfDir 'sample.ps1'
            "line one`nfunction Frobnicate-X {`n  Get-Process`n}" | Set-Content -LiteralPath $src -Encoding ascii
            $rec = @{ line = 2; col = 10; ruleId = 'PSUseApprovedVerbs'; source = 'PSScriptAnalyzer'; severity = 'Warning'; message = 'verb' }
            Add-DiagnosticCaptureEntries -File $src -Records @($rec)
            $lines = @(Get-Content -LiteralPath $script:DfLog)
            $lines.Count | Should -Be 1
            $o = $lines[0] | ConvertFrom-Json
            foreach ($field in @('ts', 'file', 'line', 'col', 'ruleId', 'source', 'severity', 'message', 'snippet', 'hash', 'verdict')) {
                ($o.PSObject.Properties.Name -contains $field) | Should -BeTrue -Because "the entry must carry '$field'"
            }
            $o.verdict | Should -BeExactly ''                          # present AND empty (reserved for later annotation)
            $o.ruleId | Should -BeExactly 'PSUseApprovedVerbs'
            $o.source | Should -BeExactly 'PSScriptAnalyzer'
            $o.snippet | Should -BeExactly 'function Frobnicate-X {'   # the offending line at line 2
            $o.hash | Should -Match '^[0-9a-f]{64}$'
        }
        It 'logs EVERY occurrence -- two identical diagnostics yield two entries (no capture-time dedup)' {
            $src = Join-Path $script:DfDir 'sample2.ps1'
            'Write-Host hi' | Set-Content -LiteralPath $src -Encoding ascii
            $rec = @{ line = 1; col = 1; ruleId = 'PSAvoidUsingWriteHost'; source = 'PSScriptAnalyzer'; severity = 'Warning'; message = 'wh' }
            Add-DiagnosticCaptureEntries -File $src -Records @($rec, $rec)
            $lines = @(Get-Content -LiteralPath $script:DfLog)
            $lines.Count | Should -Be 2
            # identical (rule, line shape) -> identical hash, yet both occurrences are kept.
            ($lines[0] | ConvertFrom-Json).hash | Should -BeExactly ($lines[1] | ConvertFrom-Json).hash
        }
        It 'appends across calls (does not overwrite)' {
            $src = Join-Path $script:DfDir 'sample3.ps1'
            'gci' | Set-Content -LiteralPath $src -Encoding ascii
            $rec = @{ line = 1; col = 1; ruleId = 'PSAvoidUsingCmdletAliases'; source = 'PSScriptAnalyzer'; severity = 'Warning'; message = 'a' }
            Add-DiagnosticCaptureEntries -File $src -Records @($rec)
            Add-DiagnosticCaptureEntries -File $src -Records @($rec)
            @(Get-Content -LiteralPath $script:DfLog).Count | Should -Be 2
        }
        It 'is fail-safe: a directory squatting the log path does not throw (mirrors Write-StatsLine)' {
            Remove-Item -LiteralPath $script:DfLog -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Force -Path $script:DfLog | Out-Null   # squat -> every append fails
            $src = Join-Path $script:DfDir 'sample4.ps1'
            'gci' | Set-Content -LiteralPath $src -Encoding ascii
            $rec = @{ line = 1; col = 1; ruleId = 'R'; source = 'PSScriptAnalyzer'; severity = 'Warning'; message = 'm' }
            { Add-DiagnosticCaptureEntries -File $src -Records @($rec) } | Should -Not -Throw
        }
        It 'is a fail-safe no-op when given no records' {
            { Add-DiagnosticCaptureEntries -File 'C:\nope\x.ps1' -Records @() } | Should -Not -Throw
            (Test-Path -LiteralPath $script:DfLog) | Should -BeFalse
        }
        It 'writes an empty snippet when the diagnostic line is out of range (still appends)' {
            $src = Join-Path $script:DfDir 'sample5.ps1'
            'only one line' | Set-Content -LiteralPath $src -Encoding ascii
            $rec = @{ line = 999; col = 1; ruleId = 'R'; source = 'PSScriptAnalyzer'; severity = 'Warning'; message = 'm' }
            Add-DiagnosticCaptureEntries -File $src -Records @($rec)
            $o = @(Get-Content -LiteralPath $script:DfLog)[0] | ConvertFrom-Json
            $o.snippet | Should -BeExactly ''
            $o.line | Should -Be 999
        }
    }

    Context 'Get-DogfoodLogPath -- resolution + override (T2.3 relocation)' {
        It 'honors the POWERSHELL_LSP_DOGFOOD_LOG override verbatim' {
            $env:POWERSHELL_LSP_DOGFOOD_LOG = 'C:\custom\df.jsonl'
            Get-DogfoodLogPath | Should -BeExactly 'C:\custom\df.jsonl'
        }
        It 'defaults to the DATA-ROOT dogfood/diagnostics.jsonl when no override is set' {
            # T2.3: this used to resolve under the PLUGIN ROOT, contradicting ARCHITECTURE.md,
            # TRUST.md and lsp-common.ps1's own header, all of which say state lives under
            # CLAUDE_PLUGIN_DATA and never under the read-only plugin tree.
            Remove-Item -LiteralPath 'Env:POWERSHELL_LSP_DOGFOOD_LOG' -ErrorAction SilentlyContinue
            Get-DogfoodLogPath | Should -BeExactly (Join-Path (Join-Path (Get-PluginDataRoot) 'dogfood') 'diagnostics.jsonl')
        }
        It 'resolves UNDER the data root and NOT under the plugin root' {
            # The assertion the finding is actually about, stated as a relationship rather than a
            # literal so it cannot pass by coincidence on a machine where the two happen to agree.
            Remove-Item -LiteralPath 'Env:POWERSHELL_LSP_DOGFOOD_LOG' -ErrorAction SilentlyContinue
            $env:CLAUDE_PLUGIN_DATA = Join-Path $TestDrive 'dr-t23'
            try {
                $p = Get-DogfoodLogPath
                $p | Should -BeLike ((Join-Path $TestDrive 'dr-t23') + '*')
                $p | Should -Not -BeLike ($script:PluginRoot + '*')
            } finally { Remove-Item -LiteralPath 'Env:CLAUDE_PLUGIN_DATA' -ErrorAction SilentlyContinue }
        }
        It 'Get-LegacyDogfoodLogPath still names the PRE-relocation plugin-root log (read-only)' {
            # Historical captures must stay reachable; the relocation orphans nothing.
            Remove-Item -LiteralPath 'Env:POWERSHELL_LSP_DOGFOOD_LOG' -ErrorAction SilentlyContinue
            Get-LegacyDogfoodLogPath | Should -BeExactly (Join-Path $script:PluginRoot 'dogfood/diagnostics.jsonl')
        }
    }

    Context 'Capture-log bound -- rotation into the stamped family (T6.4)' {
        BeforeEach {
            $script:RotDir = Join-Path $TestDrive ('rot-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Force -Path $script:RotDir | Out-Null
            $script:RotLog = Join-Path $script:RotDir 'diagnostics.jsonl'
            $env:POWERSHELL_LSP_CAPTURE_ROTATE_BYTES = '1000'
        }
        AfterEach {
            Remove-Item -LiteralPath 'Env:POWERSHELL_LSP_CAPTURE_ROTATE_BYTES' -ErrorAction SilentlyContinue
        }

        It 'does NOT rotate a log under the cap' {
            Set-Content -LiteralPath $script:RotLog -Value ('x' * 100) -Encoding ascii
            Invoke-CaptureLogRotation -LogPath $script:RotLog | Should -BeExactly ''
            (Test-Path -LiteralPath $script:RotLog) | Should -BeTrue
            @(Get-ChildItem -LiteralPath $script:RotDir -File).Count | Should -Be 1
        }
        It 'does NOT rotate a log that does not exist' {
            Invoke-CaptureLogRotation -LogPath (Join-Path $script:RotDir 'absent.jsonl') | Should -BeExactly ''
        }
        It 'rotates a log at or over the cap into a name the EXISTING sweep recognises as a family' {
            Set-Content -LiteralPath $script:RotLog -Value ('y' * 4000) -Encoding ascii
            $rotated = Invoke-CaptureLogRotation -LogPath $script:RotLog
            $rotated | Should -Not -BeNullOrEmpty
            (Test-Path -LiteralPath $rotated) | Should -BeTrue
            (Test-Path -LiteralPath $script:RotLog) | Should -BeFalse   # the active log is moved, never copied
            # The bound only works if session-start.ps1's sweep sees this as a stamped family
            # member. That sweep derives a stem by collapsing -\d{8}-\d{6}-\d{3} to -STAMP and
            # SKIPS any name that does not change, so assert exactly that transformation.
            $name = Split-Path -Leaf $rotated
            $name | Should -Match '^diagnostics-\d{8}-\d{6}-\d{3}\.jsonl$'
            $stem = [System.Text.RegularExpressions.Regex]::Replace($name, '-\d{8}-\d{6}-\d{3}', '-STAMP')
            $stem | Should -Not -BeExactly $name
            $stem | Should -BeExactly 'diagnostics-STAMP.jsonl'
        }
        It 'preserves every byte it rotates' {
            $payload = (1..200 | ForEach-Object { '{"n":' + $_ + '}' }) -join "`n"
            Set-Content -LiteralPath $script:RotLog -Value $payload -Encoding ascii
            $before = (Get-FileHash -LiteralPath $script:RotLog -Algorithm SHA256).Hash
            $rotated = Invoke-CaptureLogRotation -LogPath $script:RotLog
            (Get-FileHash -LiteralPath $rotated -Algorithm SHA256).Hash | Should -BeExactly $before
        }
        It 'is fail-safe: a rotation it cannot perform returns "" and leaves the log alone' {
            Set-Content -LiteralPath $script:RotLog -Value ('z' * 4000) -Encoding ascii
            $held = [System.IO.File]::Open($script:RotLog, 'Open', 'Read', 'None')  # deny sharing
            try {
                Invoke-CaptureLogRotation -LogPath $script:RotLog | Should -BeExactly ''
            } finally { $held.Dispose() }
            (Test-Path -LiteralPath $script:RotLog) | Should -BeTrue
        }
        It 'a non-numeric or non-positive cap falls back to the default rather than disabling the bound' {
            $env:POWERSHELL_LSP_CAPTURE_ROTATE_BYTES = 'not-a-number'
            Get-CaptureLogRotateBytes | Should -Be 8MB
            $env:POWERSHELL_LSP_CAPTURE_ROTATE_BYTES = '0'
            Get-CaptureLogRotateBytes | Should -Be 8MB
            $env:POWERSHELL_LSP_CAPTURE_ROTATE_BYTES = '-5'
            Get-CaptureLogRotateBytes | Should -Be 8MB
        }

        It 'Get-CaptureLogFamily returns rotated members OLDEST FIRST, active log LAST' {
            Set-Content -LiteralPath (Join-Path $script:RotDir 'diagnostics-20260101-010101-001.jsonl') -Value 'a' -Encoding ascii
            Set-Content -LiteralPath (Join-Path $script:RotDir 'diagnostics-20260301-010101-001.jsonl') -Value 'c' -Encoding ascii
            Set-Content -LiteralPath (Join-Path $script:RotDir 'diagnostics-20260201-010101-001.jsonl') -Value 'b' -Encoding ascii
            Set-Content -LiteralPath $script:RotLog -Value 'd' -Encoding ascii
            $fam = @(Get-CaptureLogFamily -LogPath $script:RotLog)
            $fam.Count | Should -Be 4
            @($fam | ForEach-Object { Split-Path -Leaf $_ }) | Should -Be @(
                'diagnostics-20260101-010101-001.jsonl',
                'diagnostics-20260201-010101-001.jsonl',
                'diagnostics-20260301-010101-001.jsonl',
                'diagnostics.jsonl')
        }
        It 'Get-CaptureLogFamily ignores unrelated files and unstamped siblings' {
            Set-Content -LiteralPath (Join-Path $script:RotDir 'annotations.jsonl') -Value 'x' -Encoding ascii
            Set-Content -LiteralPath (Join-Path $script:RotDir 'diagnostics-backup.jsonl') -Value 'x' -Encoding ascii
            Set-Content -LiteralPath $script:RotLog -Value 'd' -Encoding ascii
            @(Get-CaptureLogFamily -LogPath $script:RotLog).Count | Should -Be 1
        }
        It 'Get-CaptureLogFamily returns the rotated members even when the active log is absent' {
            Set-Content -LiteralPath (Join-Path $script:RotDir 'diagnostics-20260101-010101-001.jsonl') -Value 'a' -Encoding ascii
            $fam = @(Get-CaptureLogFamily -LogPath $script:RotLog)
            $fam.Count | Should -Be 1
            (Split-Path -Leaf $fam[0]) | Should -BeExactly 'diagnostics-20260101-010101-001.jsonl'
        }
    }

    Context 'Daemon pipe options -- CurrentUserOnly where the host offers it (T5.1)' {
        It 'Test-PipeOptionSupported agrees with the live enum, both ways' {
            # Both arms asserted: a predicate that only ever returns $true would pass a
            # one-armed test and silently make the guard below meaningless.
            Test-PipeOptionSupported -Name 'Asynchronous' | Should -BeTrue
            Test-PipeOptionSupported -Name 'NoSuchPipeOptionEver' | Should -BeFalse
            (Test-PipeOptionSupported -Name 'CurrentUserOnly') |
                Should -Be ([enum]::GetNames([System.IO.Pipes.PipeOptions]) -contains 'CurrentUserOnly')
        }
        It 'always includes Asynchronous -- the serve loop accepts via WaitForConnectionAsync' {
            (([int](Get-DaemonPipeOptions)) -band ([int][System.IO.Pipes.PipeOptions]::Asynchronous)) |
                Should -Be ([int][System.IO.Pipes.PipeOptions]::Asynchronous)
        }
        It 'adds CurrentUserOnly exactly when the host enum carries it, and never throws when it does not' {
            $opts = Get-DaemonPipeOptions
            if ([enum]::GetNames([System.IO.Pipes.PipeOptions]) -contains 'CurrentUserOnly') {
                $cuo = [int]([System.IO.Pipes.PipeOptions]'CurrentUserOnly')
                (([int]$opts) -band $cuo) | Should -Be $cuo
            } else {
                # Windows PowerShell 5.1 (.NET Framework) has no such member. The contract on that
                # host is the SHIPPED options unchanged -- not an exception at daemon start.
                ([int]$opts) | Should -Be ([int][System.IO.Pipes.PipeOptions]::Asynchronous)
            }
        }
        It 'New-DaemonPipeServer still builds a usable single-instance server with these options' {
            $pn = 'psl-t51-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            $srv = New-DaemonPipeServer -PipeName $pn
            try {
                $srv | Should -BeOfType ([System.IO.Pipes.NamedPipeServerStream])
                # A SECOND server on the same name must still fail -- that single-instance property
                # is what Test-DaemonPipePresent's busy-vs-unreachable discriminator rests on, and
                # a change to PipeOptions is exactly the kind of edit that could have moved it.
                { New-DaemonPipeServer -PipeName $pn } | Should -Throw
            } finally { $srv.Dispose() }
        }
        # WHY THE EFFECTIVE DACL IS NOT ASSERTED HERE, recorded so the omission is a decision and
        # not an oversight. Reading a pipe's kernel security descriptor needs P/Invoke on pwsh 7
        # ([System.IO.Pipes.AclExtensions] is a type-forward with no exported type there, and
        # PipeStream.GetAccessControl() exists only on .NET Framework), so the assertion would
        # cost an Add-Type C# compile on every run of all four CI legs -- and a compiler hiccup
        # would surface as a red with nothing to do with the pipe. The DACL was instead MEASURED
        # directly, before and after, and the before/after SDDL pair is recorded in
        # docs/roadmap-ii/THREAT-MODEL.md section 8 with its method. What guards the fix against
        # regression is the option contract above: drop CurrentUserOnly and these go red.
    }
}

# InModuleScope: these exercise reader functions that are deliberately NOT exported by
# lib/dogfood-reader.psm1 (dispatch 000156 boundary B1 -- the export surface is exactly what
# shipped callers invoke, never widened to keep a test green). The Describe body is
# unchanged and unindented on purpose so the diff shows the wrap, not a reflow.
InModuleScope 'dogfood-reader' {
Describe 'Dogfood annotation/review tool (dispatch 000043)' {
    # The reviewer FILLS the empty verdict the 000039 capture reserves. These exercise the pure
    # logic with no I/O beyond TestDrive temp files. Persistence keys on the capture record's
    # shape-hash and lands in a SEPARATE annotations file -- the diagnostics log is never
    # rewritten (the non-destructive fence).
    BeforeAll {
        # Nothing to load: this Describe runs INSIDE the dogfood-reader module, so every reader
        # function -- exported or private -- is already in scope. Paths are derived from the
        # MODULE's own location because the file-level $script:ScriptsDir is not visible here
        # ($script: inside InModuleScope resolves to module scope, where it was never set).
        $script:DfScriptsDir = Split-Path -Parent ((Get-Module dogfood-reader).ModuleBase)

        # Build one capture entry in the EXACT 000039 on-disk shape (ts/file/line/col/ruleId/
        # source/severity/message/snippet/hash/verdict). Defined in BeforeAll so the It blocks
        # (run phase) can see it.
        function New-DfEntry {
            param(
                [string] $Hash,
                [string] $RuleId = 'PSUseApprovedVerbs',
                [string] $Source = 'PSScriptAnalyzer',
                [string] $Severity = 'Warning',
                [string] $Message = 'msg',
                [string] $Snippet = 'function Frob-X {',
                [int] $Line = 1,
                [int] $Col = 10,
                [string] $File = 'C:\proj\a.ps1'
            )
            return [ordered]@{
                ts = '2026-06-23T00:00:00.0000000Z'; file = $File; line = $Line; col = $Col
                ruleId = $RuleId; source = $Source; severity = $Severity; message = $Message
                snippet = $Snippet; hash = $Hash; verdict = ''
            }
        }
        function Write-DfLog {
            param([string] $LogPath, [object[]] $Entries)
            $sb = New-Object System.Text.StringBuilder
            foreach ($e in @($Entries)) { [void]$sb.Append(($e | ConvertTo-Json -Depth 5 -Compress)); [void]$sb.Append("`n") }
            [System.IO.File]::WriteAllText($LogPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
        }
    }

    BeforeEach {
        $script:DfDir = Join-Path $TestDrive ('rev-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $script:DfDir | Out-Null
        $script:DfLog = Join-Path $script:DfDir 'diagnostics.jsonl'
        $script:DfAnn = Join-Path $script:DfDir 'annotations.jsonl'
    }

    Context 'frozen verdict vocabulary (NOT the 000027 taxonomy; no userConfig knob)' {
        It 'accepts each of the five frozen verdicts' {
            foreach ($v in @('useful', 'false-positive', 'noisy', 'bad-fix', 'unsure')) {
                (Test-DogfoodVerdict $v) | Should -BeTrue -Because "$v is frozen-valid"
            }
        }
        It 'rejects an out-of-enum verdict' {
            (Test-DogfoodVerdict 'great') | Should -BeFalse
        }
        It 'is case-sensitive (the enum is lower-case by definition)' {
            # Adversarial control: switch -ccontains to -contains in Test-DogfoodVerdict and this
            # goes RED -- the freeze is exact, not case-folded.
            (Test-DogfoodVerdict 'Useful') | Should -BeFalse
        }
        It 'the -Verdict ValidateSet and $script:DogfoodVerdicts are the SAME frozen set (no drift)' {
            # Both in-code sources of the enum are read FROM THE AST and must equal the frozen
            # five. Adversarial control: add a value to the ValidateSet or the array (not both)
            # and the set-equality goes RED -- the two cannot drift apart silently.
            #
            # The two sources now live in DIFFERENT files (dispatch 000156): the ValidateSet stays
            # on review-dogfood.ps1's param() block because that is the CLI surface, while the
            # array moved into lib/dogfood-reader.psm1 with the functions that read it. Parsing
            # both is what keeps this a cross-file drift check rather than a self-consistency one;
            # each Find() is asserted non-null first, so a source going MISSING fails loudly
            # instead of silently degrading into a vacuous pass.
            $frozen = @('bad-fix', 'false-positive', 'noisy', 'unsure', 'useful')   # sorted

            $scriptPath = Join-Path $script:DfScriptsDir 'review-dogfood.ps1'
            $modulePath = Join-Path (Join-Path $script:DfScriptsDir 'lib') 'dogfood-reader.psm1'
            Test-Path -LiteralPath $scriptPath | Should -BeTrue -Because 'the CLI entry point must exist'
            Test-Path -LiteralPath $modulePath | Should -BeTrue -Because 'the reader module must exist'

            $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
            $vParam = $ast.Find({
                    param($n) $n -is [System.Management.Automation.Language.ParameterAst] -and
                    $n.Name.VariablePath.UserPath -eq 'Verdict' }, $true)
            $vParam | Should -Not -BeNullOrEmpty -Because 'the -Verdict parameter must still be declared'
            $vsAttr = @($vParam.Attributes | Where-Object { $_.TypeName.FullName -match 'ValidateSet' })[0]
            $vsAttr | Should -Not -BeNullOrEmpty -Because 'the -Verdict ValidateSet must still be present'
            $vsValues = @($vsAttr.PositionalArguments | ForEach-Object { [string]$_.Value }) | Sort-Object
            ($vsValues -join ',') | Should -BeExactly ($frozen -join ',')

            $mAst = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$null, [ref]$null)
            $assign = $mAst.Find({
                    param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $n.Left.VariablePath.UserPath -eq 'script:DogfoodVerdicts' }, $true)
            $assign | Should -Not -BeNullOrEmpty -Because 'the frozen vocabulary array must still be defined in the module'
            $arrValues = @($assign.Right.FindAll({
                        param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) |
                    ForEach-Object { [string]$_.Value }) | Sort-Object
            ($arrValues -join ',') | Should -BeExactly ($frozen -join ',')
        }
    }

    Context 'readers -- tolerant JSONL parse (mirrors show-stats)' {
        It 'Read-DogfoodLog returns empty for a missing file (never throws)' {
            @(Read-DogfoodLog -LogPath (Join-Path $script:DfDir 'nope.jsonl')).Count | Should -Be 0
        }
        It 'Read-DogfoodLog parses valid lines and skips blank / malformed ones' {
            Write-DfLog -LogPath $script:DfLog -Entries @((New-DfEntry -Hash 'h-a'), (New-DfEntry -Hash 'h-b'))
            Add-Content -LiteralPath $script:DfLog -Value '' -Encoding ascii
            Add-Content -LiteralPath $script:DfLog -Value '{ not json' -Encoding ascii
            @(Read-DogfoodLog -LogPath $script:DfLog).Count | Should -Be 2
        }
        It 'Read-DogfoodAnnotations returns an empty hashtable for a missing file' {
            (Read-DogfoodAnnotations -AnnotationsPath (Join-Path $script:DfDir 'nope.jsonl')).Count | Should -Be 0
        }
        It 'Read-DogfoodAnnotations is last-write-wins per hash (append-only correction)' {
            Set-DogfoodVerdict -LogPath $script:DfLog -AnnotationsPath $script:DfAnn -Hash 'h-a' -Verdict 'noisy' | Out-Null
            Set-DogfoodVerdict -LogPath $script:DfLog -AnnotationsPath $script:DfAnn -Hash 'h-a' -Verdict 'false-positive' | Out-Null
            $ann = Read-DogfoodAnnotations -AnnotationsPath $script:DfAnn
            $ann['h-a'].verdict | Should -BeExactly 'false-positive'   # the later line wins
            @(Get-Content -LiteralPath $script:DfAnn).Count | Should -Be 2   # both kept (non-destructive)
        }
    }

    Context 'Get-DogfoodShapes -- collapse occurrences to distinct shapes by hash' {
        It 'groups by hash, counts occurrences, and keeps the first representative + order' {
            Write-DfLog -LogPath $script:DfLog -Entries @(
                (New-DfEntry -Hash 'h-x' -RuleId 'PSAvoidUsingCmdletAliases' -Snippet 'gci'),
                (New-DfEntry -Hash 'h-x' -RuleId 'PSAvoidUsingCmdletAliases' -Snippet 'gci'),
                (New-DfEntry -Hash 'h-x' -RuleId 'PSAvoidUsingCmdletAliases' -Snippet 'gci'),
                (New-DfEntry -Hash 'h-y' -RuleId 'PSUseApprovedVerbs' -Snippet 'function Frob-Z {'))
            $shapes = @(Get-DogfoodShapes -Records (Read-DogfoodLog -LogPath $script:DfLog))
            $shapes.Count | Should -Be 2
            $shapes[0].hash | Should -BeExactly 'h-x'      # first-seen order preserved
            $shapes[0].count | Should -Be 3                # all three occurrences counted
            $shapes[0].ruleId | Should -BeExactly 'PSAvoidUsingCmdletAliases'
            $shapes[1].count | Should -Be 1
        }
    }

    Context 'an EMPTY world reads as ZERO shapes (dispatch 000258 phantom-shape regression)' {
        # THE DEFECT (found by dispatch 000257 leg F). A function emitting nothing returns
        # AutomationNull, not an empty array. Read-DogfoodLog honestly returns @() for a missing
        # log; bound to a typed [object[]] parameter that AutomationNull converts to a real $null,
        # and `@($null)` is a ONE-ELEMENT array holding $null. Every reader that looped over the
        # bare `@($Param)` therefore fabricated one '(no-hash)' shape out of an EMPTY world -- a
        # provably missing capture log rendered as `shapes: 1 distinct`, so every accrual figure
        # derived from the reader read exactly one high at the low end, which is the end that
        # matters. The guards live at each [object[]] boundary in lib/dogfood-reader.psm1.
        #
        # RED CONTROL: revert any single guard to the bare `@($Param)` and that function's
        # assertion below goes RED -- measured 1 (or a throw) instead of 0 under pwsh 7.6.3.
        #
        # HOST-DIVERGENCE, stated so a green 5.1 leg is not misread as proof: the unroll fires
        # under pwsh 7 and NOT under Windows PowerShell 5.1. On the 5.1 legs these assertions
        # pass both before and after the fix -- they still pin the contract there, but the defect
        # they guard is only OBSERVABLE on the 7.x legs. A CI board that is green on 5.1 alone
        # has not exercised this regression.

        It 'Get-DogfoodShapes yields ZERO shapes for a NULL Records input' {
            @(Get-DogfoodShapes -Records $null).Count | Should -Be 0
        }
        It 'Get-DogfoodShapes yields ZERO shapes for a MISSING log file' {
            $missing = Join-Path $script:DfDir 'no-such-capture.jsonl'
            Test-Path -LiteralPath $missing | Should -BeFalse -Because 'this case IS a missing file'
            @(Get-DogfoodShapes -Records (Read-DogfoodLog -LogPath $missing)).Count | Should -Be 0
        }
        It 'Get-DogfoodShapes yields ZERO shapes for a ZERO-BYTE log file' {
            $enc = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($script:DfLog, '', $enc)
            (Get-Item -LiteralPath $script:DfLog).Length | Should -Be 0
            $records = Read-DogfoodLog -LogPath $script:DfLog
            @(Get-DogfoodShapes -Records $records).Count | Should -Be 0
        }
        It 'Get-DogfoodShapes yields ZERO shapes for a WHITESPACE-ONLY log file' {
            $enc = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($script:DfLog, "   `n`n  `n", $enc)
            # Non-empty on disk -- so this is genuinely the whitespace case, not the zero-byte one.
            (Get-Item -LiteralPath $script:DfLog).Length | Should -BeGreaterThan 0
            $records = Read-DogfoodLog -LogPath $script:DfLog
            @(Get-DogfoodShapes -Records $records).Count | Should -Be 0
        }

        It 'the whole shaping path reports totalShapes 0 for each empty case' {
            # The acceptance shape: totalShapes 0 AND an empty shapes array, for all four inputs.
            $enc = New-Object System.Text.UTF8Encoding($false)
            $zero = Join-Path $script:DfDir 'zero.jsonl'
            [System.IO.File]::WriteAllText($zero, '', $enc)
            $ws = Join-Path $script:DfDir 'ws.jsonl'
            [System.IO.File]::WriteAllText($ws, "   `n`n  `n", $enc)
            $cases = @{
                'missing'    = (Join-Path $script:DfDir 'no-such-capture.jsonl')
                'zero-byte'  = $zero
                'whitespace' = $ws
            }
            foreach ($name in $cases.Keys) {
                $records = Read-DogfoodLog -LogPath $cases[$name]
                $shapes = Get-DogfoodShapes -Records $records
                $summary = Get-DogfoodSummary -Shapes $shapes -Annotations @{}
                @($shapes).Count | Should -Be 0 -Because "$name must shape to an EMPTY array"
                $summary.totalShapes | Should -Be 0 -Because "$name must summarize to ZERO shapes"
                $summary.totalOccurrences | Should -Be 0 -Because "$name has no occurrences"
            }
            # The null input takes the same path without a file behind it.
            $nullShapes = Get-DogfoodShapes -Records $null
            (Get-DogfoodSummary -Shapes $nullShapes -Annotations @{}).totalShapes |
                Should -Be 0 -Because 'a null Records input must summarize to ZERO shapes'
        }

        It 'every OTHER [object[]] reader boundary also survives a null (the caller-sweep class)' {
            # Same defect class, same file. Before the fix these did not merely miscount: under
            # StrictMode Get-DogfoodSummary and Get-DogfoodPendingShapes THREW on the phantom null
            # element ("The property 'count'/'hash' cannot be found on this object") and
            # Select-DogfoodCacheVersion threw "Index was outside the bounds of the array".
            (Get-DogfoodSourceSplit -Records $null)['other-genuine'].occurrences | Should -Be 0
            (Get-DogfoodSourceSplit -Records $null)['canonical-checkout'].occurrences | Should -Be 0
            (Get-DogfoodSourceSplit -Records $null)['synthetic'].occurrences | Should -Be 0
            (Get-DogfoodSummary -Shapes $null -Annotations @{}).totalShapes | Should -Be 0
            @(Get-DogfoodPendingShapes -Shapes $null -Annotations @{}).Count | Should -Be 0
            Select-DogfoodCacheVersion -Candidates $null | Should -BeExactly ''
        }

        It 'a NON-EMPTY log is UNCHANGED by the guards (the control that keeps this honest)' {
            # Without this control every assertion above is satisfiable by a reader that returns
            # zero for EVERYTHING. It also pins the case-collision trap the guard itself can walk
            # into: PowerShell variable names are case-INSENSITIVE, so writing the guard as
            # `$shapes = @()` inside Get-DogfoodSummary would clobber its own $Shapes PARAMETER
            # and silently summarize every non-empty log as zero. That regression is invisible to
            # the empty cases and shows up only here.
            Write-DfLog -LogPath $script:DfLog -Entries @(
                (New-DfEntry -Hash 'h-x' -RuleId 'PSAvoidUsingCmdletAliases'),
                (New-DfEntry -Hash 'h-y' -RuleId 'PSUseApprovedVerbs'),
                (New-DfEntry -Hash 'h-x' -RuleId 'PSAvoidUsingCmdletAliases'))
            $records = Read-DogfoodLog -LogPath $script:DfLog
            @($records).Count | Should -Be 3 -Because 'the control needs a genuinely non-empty log'
            $shapes = Get-DogfoodShapes -Records $records
            @($shapes).Count | Should -Be 2                       # two distinct hashes
            $summary = Get-DogfoodSummary -Shapes $shapes -Annotations @{}
            $summary.totalShapes | Should -Be 2
            $summary.totalOccurrences | Should -Be 3              # h-x twice, h-y once
            @(Get-DogfoodPendingShapes -Shapes $shapes -Annotations @{}).Count | Should -Be 2
            $split = Get-DogfoodSourceSplit -Records $records
            $occ = 0
            foreach ($b in @('canonical-checkout', 'other-genuine', 'synthetic')) {
                $occ += [int]$split[$b].occurrences
            }
            $occ | Should -Be 3 -Because 'the source split counts every record exactly once'
        }
    }

    Context 'Get-DogfoodPendingShapes -- resumability' {
        It 'excludes shapes whose hash already carries a verdict' {
            Write-DfLog -LogPath $script:DfLog -Entries @((New-DfEntry -Hash 'h-a'), (New-DfEntry -Hash 'h-b'))
            Set-DogfoodVerdict -LogPath $script:DfLog -AnnotationsPath $script:DfAnn -Hash 'h-a' -Verdict 'useful' | Out-Null
            $shapes = Get-DogfoodShapes -Records (Read-DogfoodLog -LogPath $script:DfLog)
            $ann = Read-DogfoodAnnotations -AnnotationsPath $script:DfAnn
            $pending = @(Get-DogfoodPendingShapes -Shapes $shapes -Annotations $ann)
            $pending.Count | Should -Be 1
            $pending[0].hash | Should -BeExactly 'h-b'
        }
    }

    Context 'persistence model -- hash-keyed, sibling file, non-destructive' {
        It 'Get-DogfoodAnnotationsPath is annotations.jsonl beside the log' {
            # Portable base: a hardcoded C:\ literal makes PowerShell resolve a non-existent
            # C: PSDrive off-Windows (DriveNotFoundException) before the assertion runs, so
            # use $TestDrive -- a real per-platform temp dir -- and prove the same beside-the-
            # log derivation on all four CI legs (dispatch 000044).
            $dir = Join-Path $TestDrive 'dogfood'
            Get-DogfoodAnnotationsPath -LogPath (Join-Path $dir 'diagnostics.jsonl') |
                Should -BeExactly (Join-Path $dir 'annotations.jsonl')
        }
        It 'New-DogfoodAnnotation carries hash/ruleId/verdict/rationale/ts and honors a pinned timestamp' {
            $a = New-DogfoodAnnotation -Hash 'h-a' -Verdict 'noisy' -RuleId 'R' -Rationale 'why' -Now '2020-01-01T00:00:00Z'
            $a.hash | Should -BeExactly 'h-a'
            $a.verdict | Should -BeExactly 'noisy'
            $a.ruleId | Should -BeExactly 'R'
            $a.rationale | Should -BeExactly 'why'
            $a.ts | Should -BeExactly '2020-01-01T00:00:00Z'
        }
        It 'New-DogfoodAnnotation throws on an out-of-enum verdict' {
            { New-DogfoodAnnotation -Hash 'h' -Verdict 'bogus' } | Should -Throw
        }
        It 'Set-DogfoodVerdict writes, resolves the ruleId from the log, and is idempotent' {
            Write-DfLog -LogPath $script:DfLog -Entries @((New-DfEntry -Hash 'h-a' -RuleId 'PSUseApprovedVerbs'))
            (Set-DogfoodVerdict -LogPath $script:DfLog -AnnotationsPath $script:DfAnn -Hash 'h-a' -Verdict 'false-positive') | Should -BeExactly 'written'
            (Set-DogfoodVerdict -LogPath $script:DfLog -AnnotationsPath $script:DfAnn -Hash 'h-a' -Verdict 'false-positive') | Should -BeExactly 'unchanged'
            @(Get-Content -LiteralPath $script:DfAnn).Count | Should -Be 1   # idempotent: no duplicate line
            (Read-DogfoodAnnotations -AnnotationsPath $script:DfAnn)['h-a'].ruleId | Should -BeExactly 'PSUseApprovedVerbs'
        }
        It 'annotating NEVER mutates the diagnostics log -- byte-identical (non-destructive fence)' {
            # The load-bearing fence (analog of the 000039 byte-identity capture test): a verdict
            # is ADDED to a separate file; the capture evidence is immutable. Adversarial control:
            # make Set-DogfoodVerdict rewrite the log in place and this goes RED.
            Write-DfLog -LogPath $script:DfLog -Entries @((New-DfEntry -Hash 'h-a'), (New-DfEntry -Hash 'h-b'))
            $before = [System.IO.File]::ReadAllBytes($script:DfLog)
            Set-DogfoodVerdict -LogPath $script:DfLog -AnnotationsPath $script:DfAnn -Hash 'h-a' -Verdict 'useful' | Out-Null
            $after = [System.IO.File]::ReadAllBytes($script:DfLog)
            ([System.Convert]::ToBase64String($after)) | Should -BeExactly ([System.Convert]::ToBase64String($before))
        }
        It 'the annotation file never carries the snippet (only hash/ruleId/verdict/rationale/ts)' {
            Write-DfLog -LogPath $script:DfLog -Entries @((New-DfEntry -Hash 'h-a' -Snippet 'secret-source-token'))
            Set-DogfoodVerdict -LogPath $script:DfLog -AnnotationsPath $script:DfAnn -Hash 'h-a' -Verdict 'useful' | Out-Null
            (Get-Content -LiteralPath $script:DfAnn -Raw) | Should -Not -Match 'secret-source-token'
        }
    }

    Context 'Get-DogfoodSummary -- the ranked readout (occurrence-weighted)' {
        BeforeEach {
            Write-DfLog -LogPath $script:DfLog -Entries @(
                (New-DfEntry -Hash 'h-fp' -RuleId 'PSUseApprovedVerbs'),
                (New-DfEntry -Hash 'h-fp' -RuleId 'PSUseApprovedVerbs'),
                (New-DfEntry -Hash 'h-fp' -RuleId 'PSUseApprovedVerbs'),
                (New-DfEntry -Hash 'h-ok' -RuleId 'PSAvoidUsingCmdletAliases'))
        }
        It 'reports coverage, per-verdict shape/occurrence counts, and excludes useful from top rules' {
            Set-DogfoodVerdict -LogPath $script:DfLog -AnnotationsPath $script:DfAnn -Hash 'h-fp' -Verdict 'false-positive' | Out-Null
            Set-DogfoodVerdict -LogPath $script:DfLog -AnnotationsPath $script:DfAnn -Hash 'h-ok' -Verdict 'useful' | Out-Null
            $shapes = Get-DogfoodShapes -Records (Read-DogfoodLog -LogPath $script:DfLog)
            $ann = Read-DogfoodAnnotations -AnnotationsPath $script:DfAnn
            $sum = Get-DogfoodSummary -Shapes $shapes -Annotations $ann
            $sum.totalShapes | Should -Be 2
            $sum.totalOccurrences | Should -Be 4
            $sum.annotatedShapes | Should -Be 2
            $sum.coveragePct | Should -Be 100
            $sum.byVerdict['false-positive'].shapes | Should -Be 1
            $sum.byVerdict['false-positive'].occurrences | Should -Be 3      # occurrence-weighted
            $sum.byVerdict['useful'].occurrences | Should -Be 1
            # 'useful' is NOT actionable, so only the false-positive rule ranks.
            @($sum.topRules).Count | Should -Be 1
            $sum.topRules[0].ruleId | Should -BeExactly 'PSUseApprovedVerbs'
            $sum.topRules[0].occurrences | Should -Be 3
        }
        It 'an empty log summarizes cleanly (zero shapes, zero coverage)' {
            $sum = Get-DogfoodSummary -Shapes @() -Annotations @{}
            $sum.totalShapes | Should -Be 0
            $sum.coveragePct | Should -Be 0
        }
    }

    Context 'rendering -- snippet redaction is the source fence for sharing' {
        It 'Format-DogfoodSnippet masks to a length placeholder under -Redact' {
            (Format-DogfoodSnippet -Snippet 'gci -Recurse' -Redact) | Should -BeExactly '[redacted 12 chars]'
        }
        It 'Format-DogfoodSnippet returns the snippet verbatim without -Redact' {
            (Format-DogfoodSnippet -Snippet 'gci -Recurse') | Should -BeExactly 'gci -Recurse'
        }
        It 'Format-DogfoodSnippet renders an empty snippet as (no snippet)' {
            (Format-DogfoodSnippet -Snippet '') | Should -BeExactly '(no snippet)'
        }
        It 'Format-DogfoodShape redacts the snippet but still shows rule + hash' {
            # Round-trip through the log (JSON -> PSCustomObject) exactly as real usage does.
            Write-DfLog -LogPath $script:DfLog -Entries @((New-DfEntry -Hash 'h-a' -Snippet 'leak-me' -RuleId 'PSUseApprovedVerbs'))
            $shape = (Get-DogfoodShapes -Records (Read-DogfoodLog -LogPath $script:DfLog))[0]
            $out = Format-DogfoodShape -Shape $shape -Annotations @{} -Redact
            $out | Should -Not -Match 'leak-me'
            $out | Should -Match 'PSUseApprovedVerbs'
            $out | Should -Match 'h-a'
        }
    }
}
}

# InModuleScope: these exercise reader functions that are deliberately NOT exported by
# lib/dogfood-reader.psm1 (dispatch 000156 boundary B1 -- the export surface is exactly what
# shipped callers invoke, never widened to keep a test green). The Describe body is
# unchanged and unindented on purpose so the diff shows the wrap, not a reflow.
InModuleScope 'dogfood-reader' {
Describe 'Dogfood reader: source resolution + source split (dispatch 000088)' {
    # READER-ONLY hardening. Two additive changes, both provable without touching the hook
    # write-side (Get-DogfoodLogPath is byte-for-byte unchanged -- these exercise only the NEW
    # reader helpers): (1) the reader resolves the INSTALLED marketplace-cache log so a run from
    # the dev checkout stops seeing zero real captures; (2) a source-split dimension (canonical-
    # checkout / other-genuine / synthetic) lifted from the 000066/000084 inline path patterns.
    # Env is saved/cleared/restored per-It so cache discovery and the checkout resolver are
    # hermetic (no ambient CLAUDE_PLUGIN_ROOT / POWERSHELL_LSP_DOGFOOD_LOG bleeds in).
    BeforeAll {
        # Runs INSIDE the dogfood-reader module (see the InModuleScope wrap above), so the reader
        # functions -- including the private ones this Describe leans on -- are already in scope.
        $script:DfScriptsDir = Split-Path -Parent ((Get-Module dogfood-reader).ModuleBase)

        # Build a fake installed-cache log at
        # <root>/<marketplace>/powershell-lsp/<version>/dogfood/diagnostics.jsonl. Uses
        # [IO.Path]::Combine (PS 5.1 has no multi-segment Join-Path) with the platform separator,
        # so the tree is correct on all four CI legs. Returns the log path.
        function New-FakeCacheLog {
            param(
                [string] $CacheRoot,
                [string] $Version,
                [string] $Marketplace = 'claude-powershell-lsp',
                [string[]] $Lines = @('{"file":"C:\\proj\\a.ps1","hash":"h1","ruleId":"R"}')
            )
            $dir = [System.IO.Path]::Combine($CacheRoot, $Marketplace, 'powershell-lsp', $Version, 'dogfood')
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            $log = Join-Path $dir 'diagnostics.jsonl'
            Set-Content -LiteralPath $log -Value $Lines -Encoding ascii
            return $log
        }
        # One capture record in the shape Read-DogfoodLog yields (a PSCustomObject with file+hash).
        function New-Rec {
            param([string] $File, [string] $Hash = 'h1')
            return [pscustomobject]@{ file = $File; hash = $Hash }
        }
    }

    BeforeEach {
        $script:PrevPluginRoot = $env:CLAUDE_PLUGIN_ROOT
        $script:PrevDfLog = $env:POWERSHELL_LSP_DOGFOOD_LOG
        Remove-Item -LiteralPath 'Env:CLAUDE_PLUGIN_ROOT' -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath 'Env:POWERSHELL_LSP_DOGFOOD_LOG' -ErrorAction SilentlyContinue
        $script:SrcDir = Join-Path $TestDrive ('src-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $script:SrcDir | Out-Null
    }
    AfterEach {
        if ($null -eq $script:PrevPluginRoot) { Remove-Item -LiteralPath 'Env:CLAUDE_PLUGIN_ROOT' -ErrorAction SilentlyContinue }
        else { $env:CLAUDE_PLUGIN_ROOT = $script:PrevPluginRoot }
        if ($null -eq $script:PrevDfLog) { Remove-Item -LiteralPath 'Env:POWERSHELL_LSP_DOGFOOD_LOG' -ErrorAction SilentlyContinue }
        else { $env:POWERSHELL_LSP_DOGFOOD_LOG = $script:PrevDfLog }
    }

    Context 'Get-DogfoodSourceBucket -- lifted 000066/000084 patterns, conservative default' {
        It 'a canonical-checkout path classifies as canonical-checkout' {
            (Get-DogfoodSourceBucket -File 'C:\Users\m\projects\work\nortam\claude-powershell-lsp\scripts\a.ps1') |
                Should -BeExactly 'canonical-checkout'
        }
        It 'is separator-agnostic -- a forward-slash canonical path also classifies as canonical-checkout' {
            # The '?' single-char wildcard matches '/' as well as '\', so a path built with the
            # POSIX separator (as the CI legs do via Join-Path) still classifies correctly.
            (Get-DogfoodSourceBucket -File '/home/runner/work/nortam/claude-powershell-lsp/scripts/a.ps1') |
                Should -BeExactly 'canonical-checkout'
        }
        It 'a Temp\claude harness path classifies as synthetic' {
            (Get-DogfoodSourceBucket -File 'C:\Users\m\AppData\Local\Temp\claude\sess\scratchpad\a.ps1') |
                Should -BeExactly 'synthetic'
        }
        It 'a psls-pester-data fixture path classifies as synthetic' {
            (Get-DogfoodSourceBucket -File 'C:\x\psls-pester-data\fixture.ps1') | Should -BeExactly 'synthetic'
        }
        It 'synthetic is checked FIRST -- a Temp\claude path embedding the mangled repo slug is synthetic, NOT canonical' {
            # The harness worktree dir name embeds the slug ...nortam-claude-powershell-lsp..., which
            # the canonical pattern would otherwise match. Ordering (synthetic before canonical) is
            # load-bearing. Adversarial control: reorder the checks and this goes RED.
            $slugTemp = 'C:\Users\m\AppData\Local\Temp\claude\C--Users-m-projects-work-nortam-claude-powershell-lsp\s\a.ps1'
            (Get-DogfoodSourceBucket -File $slugTemp) | Should -BeExactly 'synthetic'
        }
        It 'a linked worktree path (pls-wt-000059) classifies as other-genuine, NOT canonical' {
            (Get-DogfoodSourceBucket -File 'C:\Users\m\projects\work\nortam\pls-wt-000059\scripts\lsp-client.ps1') |
                Should -BeExactly 'other-genuine'
        }
        It 'the hub demo recording (demo-take.ps1) classifies as other-genuine, NOT canonical' {
            (Get-DogfoodSourceBucket -File 'C:\Users\m\projects\work\nortam\strategic-dispatch\projects\powershell-lsp\demo-take.ps1') |
                Should -BeExactly 'other-genuine'
        }
        It 'an empty path classifies conservatively as other-genuine (never canonical)' {
            (Get-DogfoodSourceBucket -File '') | Should -BeExactly 'other-genuine'
        }
    }

    Context 'Get-DogfoodSourceSplit -- per-record occurrences + distinct shapes' {
        It 'the known baseline else-bucket entries land as other-genuine (demo-take.ps1 x3 + pls-wt-000059)' {
            # Mirrors the real cache log's non-canonical tail (per 000085): 3 hub-demo records and 1
            # worktree record must bucket as other-genuine, with the canonical edits as canonical-
            # checkout. This is the acceptance's named guard.
            $canon = 'C:\Users\m\projects\work\nortam\claude-powershell-lsp\scripts\show-stats.ps1'
            $demo = 'C:\Users\m\projects\work\nortam\strategic-dispatch\projects\powershell-lsp\demo-take.ps1'
            $wtree = 'C:\Users\m\projects\work\nortam\pls-wt-000059\scripts\lsp-client.ps1'
            $records = @(
                (New-Rec -File $canon -Hash 'c1'), (New-Rec -File $canon -Hash 'c2'),
                (New-Rec -File $demo -Hash 'd1'), (New-Rec -File $demo -Hash 'd1'), (New-Rec -File $demo -Hash 'd2'),
                (New-Rec -File $wtree -Hash 'w1'))
            $split = Get-DogfoodSourceSplit -Records $records
            $split['canonical-checkout'].occurrences | Should -Be 2
            $split['other-genuine'].occurrences | Should -Be 4      # 3 demo + 1 worktree
            $split['synthetic'].occurrences | Should -Be 0
            $split['other-genuine'].shapes | Should -Be 3           # d1, d2, w1 (d1 repeats)
        }
        It 'classifies PER RECORD, not per shape -- one hash across two files counts in both buckets' {
            # hash collision across a canonical and a synthetic file: rule + line-shape can match in
            # two files. A per-shape split would mis-attribute; per-record keeps each occurrence in
            # its own file's bucket.
            $records = @(
                (New-Rec -File 'C:\Users\m\projects\work\nortam\claude-powershell-lsp\a.ps1' -Hash 'same'),
                (New-Rec -File 'C:\Users\m\AppData\Local\Temp\claude\s\a.ps1' -Hash 'same'))
            $split = Get-DogfoodSourceSplit -Records $records
            $split['canonical-checkout'].occurrences | Should -Be 1
            $split['synthetic'].occurrences | Should -Be 1
            $split['canonical-checkout'].shapes | Should -Be 1
            $split['synthetic'].shapes | Should -Be 1
        }
        It 'all three buckets are present even when empty (fixed display order)' {
            $split = Get-DogfoodSourceSplit -Records @()
            @($split.Keys) | Should -Be @('canonical-checkout', 'other-genuine', 'synthetic')
            $split['synthetic'].occurrences | Should -Be 0
        }
    }

    Context 'cache-path resolution -- discovered, never hardcoded' {
        It 'Select-DogfoodCacheVersion picks the highest semantic version' {
            $cands = @(
                [pscustomobject]@{ Version = '1.9.0'; Path = 'p-1-9-0' },
                [pscustomobject]@{ Version = '1.18.1'; Path = 'p-1-18-1' },
                [pscustomobject]@{ Version = '1.10.0'; Path = 'p-1-10-0' })
            # semantic (not lexical) ordering: 1.18.1 > 1.10.0 > 1.9.0.
            (Select-DogfoodCacheVersion -Candidates $cands) | Should -BeExactly 'p-1-18-1'
        }
        It 'Select-DogfoodCacheVersion returns empty for no candidates' {
            (Select-DogfoodCacheVersion -Candidates @()) | Should -BeExactly ''
        }
        It 'Get-DogfoodCacheLogPath rule 1: CLAUDE_PLUGIN_ROOT / -PluginRoot points straight at the log' {
            $root = Join-Path $script:SrcDir 'installed'
            $dir = Join-Path $root 'dogfood'
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            $log = Join-Path $dir 'diagnostics.jsonl'
            Set-Content -LiteralPath $log -Value '{"file":"x","hash":"h"}' -Encoding ascii
            (Get-DogfoodCacheLogPath -PluginRoot $root) | Should -BeExactly $log
        }
        It 'Get-DogfoodCacheLogPath rule 2: discovers the versioned cache log under the cache tree' {
            $cache = Join-Path $script:SrcDir 'cache'
            $log = New-FakeCacheLog -CacheRoot $cache -Version '1.18.1'
            (Get-DogfoodCacheLogPath -CacheRoot $cache) | Should -BeExactly $log
        }
        It 'NO HARDCODED VERSION: an arbitrary future version resolves, and the highest wins over 1.18.1' {
            # The load-bearing proof for the acceptance: resolution is independent of any embedded
            # version segment. A tree whose ONLY version is 9.9.9 resolves; add 1.18.1 and the
            # discovery still returns the highest (2.0.0), never a baked-in 1.18.1.
            $cache = Join-Path $script:SrcDir 'cache-arbitrary'
            $only = New-FakeCacheLog -CacheRoot $cache -Version '9.9.9'
            (Get-DogfoodCacheLogPath -CacheRoot $cache) | Should -BeExactly $only

            $cache2 = Join-Path $script:SrcDir 'cache-multi'
            New-FakeCacheLog -CacheRoot $cache2 -Version '1.18.1' | Out-Null
            $newest = New-FakeCacheLog -CacheRoot $cache2 -Version '2.0.0'
            (Get-DogfoodCacheLogPath -CacheRoot $cache2) | Should -BeExactly $newest
        }
        It 'Get-DogfoodCacheLogPath returns empty when no cache log exists' {
            $empty = Join-Path $script:SrcDir 'no-cache'
            New-Item -ItemType Directory -Force -Path $empty | Out-Null
            (Get-DogfoodCacheLogPath -CacheRoot $empty) | Should -BeExactly ''
        }
        It 'the reader source carries no hardcoded 1.18.1 version literal (regression guard)' {
            # 000084 warned the cache path must not bake in the observed 1.18.1. Adversarial control:
            # hardcode 1.18.1 in the resolver and this goes RED.
            #
            # The resolver moved into lib/dogfood-reader.psm1 (dispatch 000156), so BOTH halves of
            # the reader are checked -- the module that now holds the resolver and the entry point
            # it was split out of. Checking only the .ps1 would have quietly stopped covering the
            # code this guard is actually about.
            $scriptPath = Join-Path $script:DfScriptsDir 'review-dogfood.ps1'
            $modulePath = Join-Path (Join-Path $script:DfScriptsDir 'lib') 'dogfood-reader.psm1'
            Test-Path -LiteralPath $modulePath | Should -BeTrue -Because 'the reader module must exist'
            (Get-Content -LiteralPath $modulePath -Raw) | Should -Not -Match '1\.18\.1'
            (Get-Content -LiteralPath $scriptPath -Raw) | Should -Not -Match '1\.18\.1'
        }
    }

    Context 'Test-DogfoodLogNonEmpty' {
        It 'is false for a missing file' {
            (Test-DogfoodLogNonEmpty -LogPath (Join-Path $script:SrcDir 'nope.jsonl')) | Should -BeFalse
        }
        It 'is false for an empty or whitespace-only file' {
            $e = Join-Path $script:SrcDir 'empty.jsonl'; Set-Content -LiteralPath $e -Value '' -Encoding ascii
            (Test-DogfoodLogNonEmpty -LogPath $e) | Should -BeFalse
        }
        It 'is true once the file has a non-blank line' {
            $f = Join-Path $script:SrcDir 'one.jsonl'; Set-Content -LiteralPath $f -Value '{"hash":"h"}' -Encoding ascii
            (Test-DogfoodLogNonEmpty -LogPath $f) | Should -BeTrue
        }
        It 'is true when the ACTIVE log is empty but a ROTATED member carries records (T6.4)' {
            # The state immediately after a rotation. Testing the active file alone would walk
            # -Source auto straight past a live data root down to a frozen pre-relocation log.
            $d = Join-Path $script:SrcDir 'rotated-nonempty'
            New-Item -ItemType Directory -Force -Path $d | Out-Null
            $active = Join-Path $d 'diagnostics.jsonl'
            Set-Content -LiteralPath $active -Value '' -Encoding ascii
            Set-Content -LiteralPath (Join-Path $d 'diagnostics-20260101-010101-001.jsonl') -Value '{"hash":"h"}' -Encoding ascii
            (Test-DogfoodLogNonEmpty -LogPath $active) | Should -BeTrue
        }
    }

    Context 'Read-DogfoodLog -- unions the rotated family (T6.4)' {
        It 'reads rotated members and the active log, OLDEST FIRST' {
            # Bounding the log must not bound what the reader can see: the whole retained window
            # is the corpus, and its ORDER is the accrual order.
            $d = Join-Path $script:SrcDir 'fam'
            New-Item -ItemType Directory -Force -Path $d | Out-Null
            Set-Content -LiteralPath (Join-Path $d 'diagnostics-20260101-010101-001.jsonl') -Value '{"hash":"old"}' -Encoding ascii
            Set-Content -LiteralPath (Join-Path $d 'diagnostics-20260201-010101-001.jsonl') -Value '{"hash":"mid"}' -Encoding ascii
            $active = Join-Path $d 'diagnostics.jsonl'
            Set-Content -LiteralPath $active -Value '{"hash":"new"}' -Encoding ascii
            $recs = @(Read-DogfoodLog -LogPath $active)
            $recs.Count | Should -Be 3
            @($recs | ForEach-Object { $_.hash }) | Should -Be @('old', 'mid', 'new')
        }
        It 'is byte-for-byte the old behaviour when nothing has rotated' {
            $d = Join-Path $script:SrcDir 'nofam'
            New-Item -ItemType Directory -Force -Path $d | Out-Null
            $active = Join-Path $d 'diagnostics.jsonl'
            Set-Content -LiteralPath $active -Value "{`"hash`":`"a`"}`n{`"hash`":`"b`"}" -Encoding ascii
            @(Read-DogfoodLog -LogPath $active | ForEach-Object { $_.hash }) | Should -Be @('a', 'b')
        }
        It 'still returns an empty array for a missing log' {
            @(Read-DogfoodLog -LogPath (Join-Path $script:SrcDir 'gone.jsonl')).Count | Should -Be 0
        }
    }

    Context 'Resolve-DogfoodLogSource -- -Source semantics + effective label' {
        It '-Path wins over -Source and is honored verbatim' {
            $r = Resolve-DogfoodLogSource -Source 'cache' -Path 'C:\explicit\df.jsonl'
            $r.LogPath | Should -BeExactly 'C:\explicit\df.jsonl'
            $r.Effective | Should -BeExactly 'path'
        }
        It 'checkout resolves the PRE-relocation running-tree log (Get-LegacyDogfoodLogPath) READ-ONLY' {
            # Post-T2.3 the read-side/write-side boundary moved: `checkout` no longer names the
            # hook's write target (that is `data` now) -- it names where captures landed BEFORE
            # the relocation, so history stays reachable. Driven here via the override seam both
            # resolvers honour.
            $env:POWERSHELL_LSP_DOGFOOD_LOG = 'C:\co\df.jsonl'
            $r = Resolve-DogfoodLogSource -Source 'checkout'
            $r.LogPath | Should -BeExactly (Get-LegacyDogfoodLogPath)
            $r.LogPath | Should -BeExactly 'C:\co\df.jsonl'
            $r.Effective | Should -BeExactly 'checkout'
        }
        It 'data resolves the LIVE data-root write target (Get-DogfoodLogPath)' {
            Remove-Item -LiteralPath 'Env:POWERSHELL_LSP_DOGFOOD_LOG' -ErrorAction SilentlyContinue
            $r = Resolve-DogfoodLogSource -Source 'data'
            $r.LogPath | Should -BeExactly (Get-DogfoodLogPath)
            $r.Effective | Should -BeExactly 'data'
        }
        It 'auto prefers a NON-EMPTY DATA-ROOT log over the cache log (Effective auto->data)' {
            # The rung T2.3 added, and the reason it had to be added: after the relocation the
            # cache log is frozen history while the data-root log is what the hook is writing.
            # Had auto kept its old cache-first order it would have gone on reading the frozen
            # one -- silently, and looking exactly like a healthy read.
            $cache = Join-Path $script:SrcDir 'cache-vs-data'
            $null = New-FakeCacheLog -CacheRoot $cache -Version '1.18.1' -Lines @('{"file":"cache","hash":"h"}')
            $dataDir = Join-Path $script:SrcDir 'dataroot'
            New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
            $dataLog = Join-Path $dataDir 'diagnostics.jsonl'
            Set-Content -LiteralPath $dataLog -Value '{"file":"data","hash":"h"}' -Encoding ascii
            $env:POWERSHELL_LSP_DOGFOOD_LOG = $dataLog
            $r = Resolve-DogfoodLogSource -Source 'auto' -CacheRoot $cache
            $r.LogPath | Should -BeExactly $dataLog
            $r.Effective | Should -BeExactly 'auto->data'
        }
        It 'cache resolves the discovered cache log' {
            $cache = Join-Path $script:SrcDir 'cache'
            $log = New-FakeCacheLog -CacheRoot $cache -Version '1.18.1'
            $r = Resolve-DogfoodLogSource -Source 'cache' -CacheRoot $cache
            $r.LogPath | Should -BeExactly $log
            $r.Effective | Should -BeExactly 'cache'
        }
        It 'auto prefers a NON-EMPTY cache log (Effective auto->cache)' {
            $cache = Join-Path $script:SrcDir 'cache'
            $log = New-FakeCacheLog -CacheRoot $cache -Version '1.18.1' -Lines @('{"file":"x","hash":"h"}')
            $env:POWERSHELL_LSP_DOGFOOD_LOG = 'C:\co\df.jsonl'   # checkout would resolve here
            $r = Resolve-DogfoodLogSource -Source 'auto' -CacheRoot $cache
            $r.LogPath | Should -BeExactly $log
            $r.Effective | Should -BeExactly 'auto->cache'
        }
        It 'auto falls back to checkout when the cache log is absent/empty (Effective auto->checkout)' {
            $empty = Join-Path $script:SrcDir 'no-cache'
            New-Item -ItemType Directory -Force -Path $empty | Out-Null
            $env:POWERSHELL_LSP_DOGFOOD_LOG = 'C:\co\df.jsonl'
            $r = Resolve-DogfoodLogSource -Source 'auto' -CacheRoot $empty
            $r.LogPath | Should -BeExactly 'C:\co\df.jsonl'
            $r.Effective | Should -BeExactly 'auto->checkout'
        }
    }

    Context 'Resolve-DogfoodPaths -- annotations beside the resolved log + Source field' {
        It 'surfaces the effective Source and puts annotations beside the resolved log' {
            $log = Join-Path $script:SrcDir 'diagnostics.jsonl'
            $r = Resolve-DogfoodPaths -Path $log
            $r.LogPath | Should -BeExactly $log
            $r.Source | Should -BeExactly 'path'
            $r.AnnotationsPath | Should -BeExactly (Join-Path $script:SrcDir 'annotations.jsonl')
        }
        It 'honors an explicit -AnnotationsPath' {
            $log = Join-Path $script:SrcDir 'diagnostics.jsonl'
            $ann = Join-Path $script:SrcDir 'custom-ann.jsonl'
            (Resolve-DogfoodPaths -Path $log -AnnotationsPath $ann).AnnotationsPath | Should -BeExactly $ann
        }
    }
}
}

Describe 'Diagnostics ordering and dedupe (Select-OrderedDiagnostics)' {
    It 'sorts by severity then line and dedupes identical findings' {
        $recs = @(
            [ordered]@{ severity='Warning'; line=10; col=1; source='PSSA'; code='X'; message='b' },
            [ordered]@{ severity='Error';   line=20; col=1; source='PSSA'; code='Y'; message='a' },
            [ordered]@{ severity='Warning'; line=10; col=1; source='PSSA'; code='X'; message='b' }
        )
        $out = @(Select-OrderedDiagnostics $recs)
        $out.Count | Should -Be 2           # one duplicate removed
        $out[0].severity | Should -Be 'Error'  # error sorts before warning
    }
}

Describe 'ConvertTo-DiagRecord -- correction threading (Track C; the prior drop is fixed)' {
    # ConvertTo-DiagRecord used to drop PSScriptAnalyzer SuggestedCorrection text.
    # It now emits 'correction' + 'correctionCount' so the fix can be carried end
    # to end (publishDiagnostics has no fix, so they default empty; the daemon's
    # codeAction pass enriches them afterward). These guard that contract.
    BeforeAll {
        $script:Diag = [pscustomobject]@{
            range = [pscustomobject]@{
                start = [pscustomobject]@{ line = 4; character = 0 }
                end   = [pscustomobject]@{ line = 4; character = 3 }
            }
            severity = 2
            source = 'PSScriptAnalyzer'
            code = 'PSAvoidUsingCmdletAliases'
            message = "'gci' is an alias of 'Get-ChildItem'."
        }
    }
    It 'emits correction and correctionCount fields' {
        $r = ConvertTo-DiagRecord $script:Diag
        $r.Contains('correction') | Should -BeTrue
        $r.Contains('correctionCount') | Should -BeTrue
    }
    It 'defaults to empty fix and zero count at publish time' {
        $r = ConvertTo-DiagRecord $script:Diag
        $r.correction | Should -Be ''
        $r.correctionCount | Should -Be 0
    }
    It 'carries a supplied correction through (the prior drop is fixed)' {
        $r = ConvertTo-DiagRecord $script:Diag 'Get-ChildItem' 1
        $r.correction | Should -Be 'Get-ChildItem'
        $r.correctionCount | Should -Be 1
        $r.line | Should -Be 5            # 0-based 4 -> 1-based 5
        $r.code | Should -Be 'PSAvoidUsingCmdletAliases'
    }
}

Describe 'Configurability -- rule-list parsing and diagnostics filtering (Stage 4 knobs)' {
    BeforeAll {
        $script:Sample = @(
            [ordered]@{ severity = 'Error';       severityNum = 1; line = 5;  col = 1; source = 'PSSA'; code = 'PSAvoidUsingCmdletAliases'; message = 'alias' },
            [ordered]@{ severity = 'Warning';     severityNum = 2; line = 9;  col = 1; source = 'PSSA'; code = 'PSUseApprovedVerbs';        message = 'verb' },
            [ordered]@{ severity = 'Information'; severityNum = 3; line = 12; col = 1; source = 'PSSA'; code = 'PSReviewUnusedParameter';   message = 'unused' }
        )
    }

    It 'Split-RuleList parses, trims, and drops empties' {
        (Split-RuleList 'A, B ,, C') | Should -Be @('A', 'B', 'C')
        @(Split-RuleList '').Count | Should -Be 0
    }

    It 'severityThreshold=Warning drops Information and below' {
        $out = @(Select-FilteredDiagnostics $script:Sample 'Warning' @() @())
        $out.Count | Should -Be 2
        $out.severity | Should -Not -Contain 'Information'
    }

    It 'severityThreshold=Error keeps only Errors' {
        $out = @(Select-FilteredDiagnostics $script:Sample 'Error' @() @())
        $out.Count | Should -Be 1
        $out[0].severity | Should -Be 'Error'
    }

    It 'ruleExclude suppresses a specific rule code' {
        $out = @(Select-FilteredDiagnostics $script:Sample 'Hint' @() @('PSUseApprovedVerbs'))
        $out.code | Should -Not -Contain 'PSUseApprovedVerbs'
        $out.Count | Should -Be 2
    }

    It 'ruleInclude keeps only listed rule codes' {
        $out = @(Select-FilteredDiagnostics $script:Sample 'Hint' @('PSUseApprovedVerbs') @())
        $out.Count | Should -Be 1
        $out[0].code | Should -Be 'PSUseApprovedVerbs'
    }

    It 'default threshold (Hint) keeps everything' {
        @(Select-FilteredDiagnostics $script:Sample 'Hint' @() @()).Count | Should -Be 3
    }
}

Describe 'Resolve-PssaSettingsPath -- honor PSScriptAnalyzerSettings.psd1 (dispatch 000018)' {
    # Track 1 (PSES v4.6.0 source) proved PSES needs an ABSOLUTE settings path: its
    # WorkspaceService.FindFileInWorkspace returns a rooted path AS-IS, before the
    # WorkspaceFolders loop the daemon leaves EMPTY (#2300 dodge); a relative path
    # would resolve against PSES's process CWD and miss. These guard the resolver:
    # absolute override wins, a RELATIVE override is ignored, discovery walks up to
    # the nearest file, and the project-root bound stops the walk.
    BeforeAll {
        $script:Root = Join-Path $TestDrive 'proj'
        $script:Sub = Join-Path $script:Root 'src'
        New-Item -ItemType Directory -Force -Path $script:Sub | Out-Null
        $script:RootCfg = Join-Path $script:Root 'PSScriptAnalyzerSettings.psd1'
        $script:SubCfg = Join-Path $script:Sub 'PSScriptAnalyzerSettings.psd1'
        $script:EditFile = Join-Path $script:Sub 'edited.ps1'
        Set-Content -LiteralPath $script:EditFile -Value 'Get-Process' -Encoding ascii
    }
    AfterEach {
        Remove-Item -LiteralPath $script:RootCfg -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:SubCfg -Force -ErrorAction SilentlyContinue
    }

    It 'returns an absolute override as-is (resolved to a full path); existence is left to PSES' {
        $override = Join-Path (Join-Path $TestDrive 'elsewhere') 'custom.psd1'
        Resolve-PssaSettingsPath -EditedFilePath $script:EditFile -ProjectRoot $script:Root -Override $override |
            Should -BeExactly ([System.IO.Path]::GetFullPath($override))
    }
    It 'ignores a RELATIVE override and falls through to discovery (absolute only)' {
        Set-Content -LiteralPath $script:RootCfg -Value '@{}' -Encoding ascii
        Resolve-PssaSettingsPath -EditedFilePath $script:EditFile -ProjectRoot $script:Root -Override 'relative-custom.psd1' |
            Should -BeExactly ([System.IO.Path]::GetFullPath($script:RootCfg))
    }
    It 'discovers a settings file at the project root by walking up from a subdir' {
        Set-Content -LiteralPath $script:RootCfg -Value '@{}' -Encoding ascii
        Resolve-PssaSettingsPath -EditedFilePath $script:EditFile -ProjectRoot $script:Root |
            Should -BeExactly ([System.IO.Path]::GetFullPath($script:RootCfg))
    }
    It 'prefers the NEAREST settings file (subdir over root)' {
        Set-Content -LiteralPath $script:RootCfg -Value '@{}' -Encoding ascii
        Set-Content -LiteralPath $script:SubCfg -Value '@{}' -Encoding ascii
        Resolve-PssaSettingsPath -EditedFilePath $script:EditFile -ProjectRoot $script:Root |
            Should -BeExactly ([System.IO.Path]::GetFullPath($script:SubCfg))
    }
    It 'does NOT honor a settings file ABOVE the project root (the bound)' {
        # Settings ONLY in the root's parent; the walk must stop at the root and find
        # nothing. Adversarial control: drop the bound and this returns the parent
        # file -> RED.
        $parentCfg = Join-Path $TestDrive 'PSScriptAnalyzerSettings.psd1'
        Set-Content -LiteralPath $parentCfg -Value '@{}' -Encoding ascii
        try {
            Resolve-PssaSettingsPath -EditedFilePath $script:EditFile -ProjectRoot $script:Root | Should -BeExactly ''
        } finally { Remove-Item -LiteralPath $parentCfg -Force -ErrorAction SilentlyContinue }
    }
    It 'returns empty when no settings file exists and no override is given (no-config path)' {
        Resolve-PssaSettingsPath -EditedFilePath $script:EditFile -ProjectRoot $script:Root | Should -BeExactly ''
    }
    It 'checks the edited file own directory but does not escape upward when the file is outside the project root' {
        $outsideSub = Join-Path (Join-Path $TestDrive 'outside') 'deep'
        New-Item -ItemType Directory -Force -Path $outsideSub | Out-Null
        $ownCfg = Join-Path $outsideSub 'PSScriptAnalyzerSettings.psd1'
        $parentCfg = Join-Path (Join-Path $TestDrive 'outside') 'PSScriptAnalyzerSettings.psd1'
        $f = Join-Path $outsideSub 'x.ps1'; Set-Content -LiteralPath $f -Value 'Get-Process' -Encoding ascii
        Set-Content -LiteralPath $parentCfg -Value '@{}' -Encoding ascii
        try {
            # parent-only settings, file outside the root -> not honored (no upward escape)
            Resolve-PssaSettingsPath -EditedFilePath $f -ProjectRoot $script:Root | Should -BeExactly ''
            # own-dir settings -> honored
            Set-Content -LiteralPath $ownCfg -Value '@{}' -Encoding ascii
            Resolve-PssaSettingsPath -EditedFilePath $f -ProjectRoot $script:Root |
                Should -BeExactly ([System.IO.Path]::GetFullPath($ownCfg))
        } finally { Remove-Item -LiteralPath $ownCfg, $parentCfg -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Resolve-PssaSettingsPath -- opt-in ruleset=base fallback + four precedence levels (dispatch 000087)' {
    # The 'ruleset' knob selects the fallback ONLY when no explicit override and no repo-local
    # PSScriptAnalyzerSettings.psd1 resolve first. These prove all four precedence levels the
    # dispatch requires, at the resolver -- the single place the fallback is decided:
    #   L1 default-unchanged  : pses-default (and the default) -> '' (PSES 15-rule fallback).
    #   L2 base-broadens      : ruleset=base, no repo-local, no override -> the shipped base.
    #   L3 repo-local-wins    : a discovered PSScriptAnalyzerSettings.psd1 wins over the base.
    #   L4 settingsPath-wins  : an explicit absolute override wins over base AND repo-local.
    BeforeAll {
        $script:R87Root = Join-Path $TestDrive 'proj87'
        $script:R87Sub = Join-Path $script:R87Root 'src'
        New-Item -ItemType Directory -Force -Path $script:R87Sub | Out-Null
        $script:R87Edit = Join-Path $script:R87Sub 'edited.ps1'
        Set-Content -LiteralPath $script:R87Edit -Value 'Get-Process' -Encoding ascii
        $script:R87RepoCfg = Join-Path $script:R87Root 'PSScriptAnalyzerSettings.psd1'
        $script:BaseShipped = Get-PluginBaseSettingsPath
    }
    AfterEach {
        Remove-Item -LiteralPath $script:R87RepoCfg -Force -ErrorAction SilentlyContinue
    }

    It 'the shipped base ruleset resolves from the plugin tree (Get-PluginBaseSettingsPath)' {
        $script:BaseShipped | Should -Not -BeNullOrEmpty
        [System.IO.Path]::IsPathRooted($script:BaseShipped) | Should -BeTrue
        (Split-Path -Leaf $script:BaseShipped) | Should -BeExactly 'base.psd1'
        Test-Path -LiteralPath $script:BaseShipped -PathType Leaf | Should -BeTrue
    }
    It 'L1 default-unchanged: pses-default (and the omitted default) returns empty -- the PSES 15-rule path' {
        # Adversarial control: this is the byte-for-byte pre-000087 behavior; if the fallback
        # ever returned the base for pses-default, the default surface would broaden -> RED.
        Resolve-PssaSettingsPath -EditedFilePath $script:R87Edit -ProjectRoot $script:R87Root | Should -BeExactly ''
        Resolve-PssaSettingsPath -EditedFilePath $script:R87Edit -ProjectRoot $script:R87Root -Ruleset 'pses-default' | Should -BeExactly ''
    }
    It 'L2 base-broadens: ruleset=base with no repo-local and no override resolves the shipped base' {
        Resolve-PssaSettingsPath -EditedFilePath $script:R87Edit -ProjectRoot $script:R87Root -Ruleset 'base' |
            Should -BeExactly $script:BaseShipped
    }
    It 'L3 repo-local-wins: a discovered PSScriptAnalyzerSettings.psd1 wins over the base' {
        Set-Content -LiteralPath $script:R87RepoCfg -Value '@{}' -Encoding ascii
        $r = Resolve-PssaSettingsPath -EditedFilePath $script:R87Edit -ProjectRoot $script:R87Root -Ruleset 'base'
        $r | Should -BeExactly ([System.IO.Path]::GetFullPath($script:R87RepoCfg))
        $r | Should -Not -Be $script:BaseShipped
    }
    It 'L4 settingsPath-wins: an explicit absolute override wins over the base AND a repo-local file' {
        Set-Content -LiteralPath $script:R87RepoCfg -Value '@{}' -Encoding ascii
        $ovr = Join-Path (Join-Path $TestDrive 'elsewhere87') 'custom.psd1'
        Resolve-PssaSettingsPath -EditedFilePath $script:R87Edit -ProjectRoot $script:R87Root -Override $ovr -Ruleset 'base' |
            Should -BeExactly ([System.IO.Path]::GetFullPath($ovr))
    }
    It 'an unknown ruleset value degrades to the PSES default (no base, no throw)' {
        Resolve-PssaSettingsPath -EditedFilePath $script:R87Edit -ProjectRoot $script:R87Root -Ruleset 'nonsense' | Should -BeExactly ''
    }
}

Describe 'base.psd1 is NOT auto-discovered as a repo-local settings file (dispatch 000087 guard)' {
    # The shipped base ruleset is named base.psd1, NOT PSScriptAnalyzerSettings.psd1, so the
    # repo-local discovery walk-up (which matches only that exact name) never selects it --
    # shipping it inside the plugin tree cannot change the plugin's own repo lint surface.
    It 'a file literally named base.psd1 in the project tree is ignored by discovery (pses-default -> empty)' {
        $root = Join-Path $TestDrive 'guard1'
        $sub = Join-Path $root 'src'; New-Item -ItemType Directory -Force -Path $sub | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'base.psd1') -Value '@{}' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $sub 'base.psd1') -Value '@{}' -Encoding ascii
        $edit = Join-Path $sub 'x.ps1'; Set-Content -LiteralPath $edit -Value 'Get-Process' -Encoding ascii
        Resolve-PssaSettingsPath -EditedFilePath $edit -ProjectRoot $root | Should -BeExactly ''
    }
    It 'under ruleset=base, a local base.psd1 in the tree is NOT selected as repo-local -- the SHIPPED base is used' {
        $root = Join-Path $TestDrive 'guard2'
        $sub = Join-Path $root 'src'; New-Item -ItemType Directory -Force -Path $sub | Out-Null
        $localBase = Join-Path $sub 'base.psd1'
        Set-Content -LiteralPath $localBase -Value '@{}' -Encoding ascii
        $edit = Join-Path $sub 'x.ps1'; Set-Content -LiteralPath $edit -Value 'Get-Process' -Encoding ascii
        $r = Resolve-PssaSettingsPath -EditedFilePath $edit -ProjectRoot $root -Ruleset 'base'
        $r | Should -BeExactly (Get-PluginBaseSettingsPath)
        $r | Should -Not -Be ([System.IO.Path]::GetFullPath($localBase))
    }
}

Describe 'rulesets/base.psd1 -- enumerated, deterministic base ruleset (dispatch 000087; curated 000092, 000126)' {
    # The base ENUMERATES its rules explicitly (not IncludeDefaultRules=$true) so the surfaced
    # set is pin-independent and a pin bump is a deliberate regeneration. These guard the
    # shipped file's content directly (parse only -- no PSScriptAnalyzer needed, so they run on
    # every leg): the security rules + Write-Host are in, the formatting/compat rules are out, the
    # four survey-evidenced noisy rules (dispatch 000092, 000126) are out, no duplicates.
    BeforeAll {
        $script:BaseFile = Join-Path $script:PluginRoot 'rulesets/base.psd1'
        $script:BaseData = Import-PowerShellDataFile -LiteralPath $script:BaseFile
        $script:BaseRules = @($script:BaseData['IncludeRules'])
    }
    It 'exists and parses as a settings hashtable with a non-empty IncludeRules array' {
        Test-Path -LiteralPath $script:BaseFile -PathType Leaf | Should -BeTrue
        $script:BaseData.ContainsKey('IncludeRules') | Should -BeTrue
        $script:BaseRules.Count | Should -BeGreaterThan 0
    }
    It 'enumerates explicitly -- NOT a bare IncludeDefaultRules (the determinism property)' {
        # Adversarial control: switch base.psd1 to IncludeDefaultRules=$true and this goes RED.
        $script:BaseData.ContainsKey('IncludeDefaultRules') | Should -BeFalse
    }
    It 'ships exactly the derived rule count at the current pin (53 at PSScriptAnalyzer 1.25.0)' {
        # Pin-coupled by design: a pinned-analyzer bump regenerates the base
        # (scripts/regen-base-ruleset.ps1) and updates this count in the same reviewed diff.
        # 53 = 58 default-on minus 1 default-on compat rule (PSUseCompatibleCmdlets) minus the
        # 4 survey-evidenced exclusions (dispatch 000092 x3 + 000126 x1; down from 57 at 000087).
        $script:BaseRules.Count | Should -Be 53
    }
    It 'includes the three Error-severity security rules, Write-Host, and all four override codes (RETAINED through 000126)' {
        # These are load-bearing signal and MUST survive the exclude curation. The four override
        # codes (dispatch 000125) are asserted here too: an override may only key a rule that is
        # in base, so excluding any of them would break the rationale generator's constraint-4
        # throw. This pins that coupling at the base-ruleset end.
        foreach ($r in @(
                'PSAvoidUsingComputerNameHardcoded',
                'PSAvoidUsingConvertToSecureStringWithPlainText',
                'PSAvoidUsingUsernameAndPasswordParams',
                'PSAvoidUsingWriteHost',
                'PSShouldProcess',
                'PSUseSupportsShouldProcess',
                'PSAvoidShouldContinueWithoutForce')) {
            $script:BaseRules | Should -Contain $r
        }
    }
    It 'EXCLUDES the four survey-evidenced noisy rules (dispatch 000092 + 000126, from the 000091 quality wave)' {
        # Removed as measured noise: PSReviewUnusedParameter (~90% FP on the param-block +
        # nested-functions shape), PSUseSingularNouns (0 true-issues; intentional plurals),
        # PSUseShouldProcessForStateChangingFunctions (verb-triggered FP on clean New-*/Set-*
        # builders), and PSUseOutputTypeCorrectly (dispatch 000126: the sole base-54 rule firing
        # on the known-good FP oracle -- 2 pedantic Information [OutputType()] nags on correct
        # functions, 0 true issues). All four are base-only (not in the PSES 15-rule allow-list),
        # so their removal tightens the opt-in base surface alone and leaves pses-default unchanged.
        foreach ($r in @(
                'PSReviewUnusedParameter',
                'PSUseSingularNouns',
                'PSUseShouldProcessForStateChangingFunctions',
                'PSUseOutputTypeCorrectly')) {
            $script:BaseRules | Should -Not -Contain $r
        }
    }
    It 'EXCLUDES the formatting and compatibility rules (Phase 2 item 2, not this base)' {
        foreach ($r in @(
                'PSPlaceOpenBrace', 'PSPlaceCloseBrace', 'PSUseConsistentIndentation',
                'PSUseConsistentWhitespace', 'PSAlignAssignmentStatement', 'PSUseCorrectCasing',
                'PSAvoidUsingDoubleQuotesForConstantString', 'PSAvoidSemicolonsAsLineTerminators',
                'PSAvoidLongLines',
                'PSUseCompatibleCmdlets', 'PSUseCompatibleCommands', 'PSUseCompatibleSyntax', 'PSUseCompatibleTypes')) {
            $script:BaseRules | Should -Not -Contain $r
        }
    }
    It 'has no duplicate entries and every name is a PS-prefixed rule code' {
        (@($script:BaseRules | Sort-Object -Unique)).Count | Should -Be $script:BaseRules.Count
        foreach ($r in $script:BaseRules) { $r | Should -Match '^PS' }
    }
}

# ===========================================================================
# Rule rationales (dispatch 000121, I0.1 slice-1)
# ===========================================================================

Describe 'Find-CommandLinePlaceholder -- angle-bracket placeholder detection (dispatch 000139)' {
    # Pure token-level finder. Tokenizes a snippet exactly as the client pre-pass does and
    # asserts the 0-FP shape: a placeholder '<Name>' fires; legitimate angle-bracket content
    # (output redirection, strings, here-strings, block comments, word operators, and a genuine
    # input redirect '< file') stays silent. RED-provable: mutate the finder and a case flips.
    BeforeAll {
        function Get-PlaceholderHits([string]$code) {
            $tk = $null; $er = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$tk, [ref]$er)
            return @(Find-CommandLinePlaceholder -Tokens $tk)
        }
    }
    It 'fires on a bare command-line placeholder <ModuleName>' {
        $h = Get-PlaceholderHits 'Install-Module <ModuleName>'
        @($h).Count | Should -Be 1
        [string]$h[0].code | Should -BeExactly 'CommandLinePlaceholder'
        [string]$h[0].source | Should -BeExactly 'powershell-lsp'
        [string]$h[0].message | Should -Match '<ModuleName>'
    }
    It 'fires on a placeholder in a parameter position and a hyphenated placeholder' {
        @(Get-PlaceholderHits 'Set-Item -Path <path> -Value 1').Count | Should -Be 1
        @(Get-PlaceholderHits 'Connect-Thing <your-api-key>').Count | Should -Be 1
    }
    It 'is SILENT on legitimate output redirection' {
        @(Get-PlaceholderHits 'Get-Process > out.txt').Count | Should -Be 0
        @(Get-PlaceholderHits 'cmd.exe 2>&1').Count | Should -Be 0
        @(Get-PlaceholderHits 'Get-Date >> log.txt').Count | Should -Be 0
        @(Get-PlaceholderHits 'thing *>&1').Count | Should -Be 0
    }
    It 'is SILENT on angle brackets inside strings, here-strings, and block comments' {
        @(Get-PlaceholderHits '$x = "<b>bold</b>"').Count | Should -Be 0
        @(Get-PlaceholderHits '$t = "System.Collections.Generic.List<string>"').Count | Should -Be 0
        (Get-PlaceholderHits ('$x = @"' + "`n" + '<root><a/></root>' + "`n" + '"@')).Count | Should -Be 0
        @(Get-PlaceholderHits '<# a comment with <tag> #>').Count | Should -Be 0
    }
    It 'is SILENT on word comparison operators and a genuine input redirect' {
        (Get-PlaceholderHits 'if ($a -lt $b -and $c -gt $d) { 1 }').Count | Should -Be 0
        @(Get-PlaceholderHits 'Get-Content < in.txt').Count | Should -Be 0
    }
    It 'returns @() for a null token stream (fail-open)' {
        @(Find-CommandLinePlaceholder -Tokens $null).Count | Should -Be 0
    }
}

Describe 'rulesets/rule-rationales.psd1 -- shipped table invariants (dispatch 000121)' {
    # OFFLINE, parse-only: no PSScriptAnalyzer, no daemon, no network, so this runs on every leg.
    # It pins the table's SHAPE and its coupling to the two things it derives over -- the PSSA pin
    # in scripts/ensure-pssa.ps1 and the enumerated rulesets/base.psd1 surface. A pin bump or a
    # base-ruleset edit therefore goes RED here until the table is regenerated in the same reviewed
    # diff. The full text-level derivation match lives in the -Check Describe below.
    BeforeAll {
        $script:RatFile = Join-Path $script:PluginRoot 'rulesets/rule-rationales.psd1'
        $script:RatData = Import-PowerShellDataFile -LiteralPath $script:RatFile
        $script:RatEntries = $script:RatData['entries']
        $script:RatOwned = @($script:RatData['owned'])
        $script:RatBase = @((Import-PowerShellDataFile -LiteralPath (Join-Path $script:PluginRoot 'rulesets/base.psd1'))['IncludeRules'])
    }
    It 'exists and parses as a v1 table with entries, owned, pin and cap' {
        Test-Path -LiteralPath $script:RatFile -PathType Leaf | Should -BeTrue
        $script:RatData['schema'] | Should -BeExactly 'rule-rationales/v1'
        $script:RatEntries.Count | Should -BeGreaterThan 0
        $script:RatOwned.Count | Should -BeGreaterThan 0
    }
    It 'is PIN-COUPLED: pssa_version equals the pin in scripts/ensure-pssa.ps1' {
        # The load-bearing coupling. Bump $PssaVersion without regenerating and this goes RED.
        # Adversarial control: change pssa_version in the shipped table and this goes RED.
        $pin = Get-PinnedPssaVersion
        $pin | Should -Not -BeNullOrEmpty
        [string]$script:RatData['pssa_version'] | Should -BeExactly $pin
    }
    It 'covers the base ruleset surface EXACTLY: entries = base-53 PSSA rules + the owned finders' {
        $pssaKeys = @($script:RatEntries.Keys | Where-Object { $script:RatOwned -notcontains $_ } | Sort-Object)
        $baseSorted = @($script:RatBase | Sort-Object)
        ($pssaKeys -join ',') | Should -BeExactly ($baseSorted -join ',')
        [int]$script:RatData['pssa_count'] | Should -Be $baseSorted.Count
        [int]$script:RatData['owned_count'] | Should -Be $script:RatOwned.Count
        $script:RatEntries.Count | Should -Be ($baseSorted.Count + $script:RatOwned.Count)
    }
    It 'hand-authors an entry for each of the 6 plugin-owned finders, keyed by the EMITTED ruleId' {
        # NOT the finder FUNCTION names: Find-ModuleAwareness emits code 'ModuleNotInstalled', and
        # Test-ManifestConsistency emits 'ManifestConsistency'; the runtime lookup keys on the
        # diagnostic `code`. An entry keyed 'ModuleAwareness' would silently never match.
        # Adversarial control: rename any key here and this goes RED.
        $owned = @('BashIsm', 'PS7OnlySyntax', 'NonAsciiChar', 'ModuleNotInstalled', 'ManifestConsistency', 'CommandLinePlaceholder')
        foreach ($c in $owned) {
            $script:RatOwned | Should -Contain $c
            [string]$script:RatEntries[$c] | Should -Not -BeNullOrEmpty
        }
        # The owned set is EXACTLY these six -- a seventh entry may not ride in silently (000124, 000139).
        $script:RatOwned.Count | Should -Be $owned.Count
    }
    It 'records the idiom-family OVERRIDE layer and asserts the set from disk (dispatch 000125)' {
        # The artifact is self-describing: override_count + an overrides map (code -> @{derived; text}).
        # This invariant reads the set from disk, never a literal count, so a dropped/added override
        # goes RED. Adversarial controls: change override_count, drop an override key, or repoint one
        # at a non-base rule -- each fails here.
        # Slice 1 (000125): the 4-code idiom family. Slice 2 (000142): the 5 PSES-15 default-surface
        # rules whose derived text is circular or pure mechanism -- each proven to ALREADY fire by its
        # presence in the DERIVED corpus snapshots. Adding an override without recording it here is
        # exactly what this list exists to catch, so it is updated deliberately, never regenerated.
        $expected = @(
            'PSAvoidShouldContinueWithoutForce', 'PSAvoidUsingWriteHost', 'PSShouldProcess', 'PSUseSupportsShouldProcess',
            'PSAvoidDefaultValueSwitchParameter', 'PSAvoidUsingCmdletAliases', 'PSPossibleIncorrectComparisonWithNull',
            'PSUseApprovedVerbs', 'PSUseDeclaredVarsMoreThanAssignments'
        )
        $script:RatData.ContainsKey('overrides') | Should -BeTrue
        $ov = $script:RatData['overrides']
        $ovKeys = @($ov.Keys | Sort-Object)
        ($ovKeys -join ',') | Should -BeExactly (($expected | Sort-Object) -join ',')
        [int]$script:RatData['override_count'] | Should -Be $expected.Count
        $cap = [int]$script:RatData['max_length']
        foreach ($k in $ovKeys) {
            # Constraint 4: an override may only replace an auto-derived base-53 PSSA rule, never an
            # owned finder (which would shadow its hand-authored rationale).
            $script:RatBase | Should -Contain $k
            $script:RatOwned | Should -Not -Contain $k
            $rec = $ov[$k]
            [string]$rec['text'] | Should -Not -BeNullOrEmpty
            [string]$rec['derived'] | Should -Not -BeNullOrEmpty
            # The override text is what entries[] actually serves (the layer landed).
            [string]$script:RatEntries[$k] | Should -BeExactly ([string]$rec['text'])
            # Non-vacuity FROM DISK: the override differs from the derived text it replaced. Mirrors
            # the generator's non-vacuity throw so a vacuous override can never sit in the shipped file.
            ([string]$rec['text']) | Should -Not -BeExactly ([string]$rec['derived'])
            ([string]$rec['text']).Length | Should -BeLessOrEqual $cap
        }
    }
    It 'the Write-Host override leads its fix with Write-Information, never Write-Output (000124 content constraint)' {
        # LOAD-BEARING guidance: Write-Output writes to the success pipeline and changes a function's
        # return value, so it must not be the lead fix for a message-printing Write-Host. The override
        # recommends Write-Information / Write-Verbose. Adversarial control: reword to lead with
        # Write-Output ('Instead, use Write-Output ...' -- the derived phrasing) and this goes RED.
        $wh = [string]$script:RatEntries['PSAvoidUsingWriteHost']
        $wh | Should -Match 'Write-Information'
        $wh | Should -Not -Match 'Instead, use Write-Output'
        $wh | Should -Not -Match 'Use Write-Output'
    }
    It 'every rationale is non-empty, within the declared cap, and never ends mid-word' {
        $cap = [int]$script:RatData['max_length']
        $cap | Should -BeGreaterThan 0
        foreach ($k in @($script:RatEntries.Keys)) {
            $v = [string]$script:RatEntries[$k]
            $v | Should -Not -BeNullOrEmpty
            $v.Length | Should -BeLessOrEqual $cap
            # A truncated rationale ends '...' preceded by a whole word, never a bare fragment.
            if ($v.EndsWith('...')) { $v | Should -Match '\w\.\.\.$' }
        }
    }
    It 'every rationale is pure printable ASCII (the PS 5.1 no-BOM mojibake trap)' {
        # Collect offenders then assert ONCE: a per-character Should is ~17k assertions and
        # dominates the unit suite's runtime. Adversarial control: put an em-dash in any entry.
        $bad = @()
        foreach ($k in @($script:RatEntries.Keys)) {
            foreach ($ch in ([string]$script:RatEntries[$k]).ToCharArray()) {
                if ([int]$ch -lt 32 -or [int]$ch -gt 126) { $bad += ('{0}: U+{1:X4}' -f $k, [int]$ch) }
            }
        }
        ($bad -join '; ') | Should -BeExactly ''
    }
    It 'the shipped file itself is no-BOM UTF-8 with no non-ASCII byte' {
        # Deliberately does NOT assert "no CR". Line endings in the WORKING TREE are a property of the
        # CHECKOUT, not of the artifact: this repo ships no .gitattributes, so a Windows runner with
        # git's default core.autocrlf=true checks LF blobs out as CRLF. Asserting CR==0 here passes on
        # macOS/Linux and can never pass on the Windows CI legs. The invariant that actually matters --
        # the generator emits LF only -- is enforced at the source in regen-rule-rationales.ps1, whose
        # whole-file Assert-AsciiText -AllowNewline permits 0x0A and rejects 0x0D (and every other
        # control byte) before the file is ever written.
        # BOM and non-ASCII bytes ARE checkout-invariant (git normalizes neither), so they are asserted.
        $bytes = [System.IO.File]::ReadAllBytes($script:RatFile)
        $bytes.Length | Should -BeGreaterThan 0
        ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
        @($bytes | Where-Object { $_ -gt 0x7E }).Count | Should -Be 0    # no non-ASCII
    }
}

Describe 'Import-RuleRationales / Get-RationaleForCode -- runtime lookup + per-rule dedup (dispatch 000121)' {
    # The rendering seam, PURE and offline. Adversarial control: drop the $Rendered.Add() guard in
    # Get-RationaleForCode and the 'renders once per distinct rule' assertion goes RED.
    BeforeAll {
        $script:RatTable = Import-RuleRationales
    }
    It 'loads the shipped table keyed by rule code' {
        $script:RatTable.Count | Should -BeGreaterThan 0
        $script:RatTable.ContainsKey('PSAvoidUsingWriteHost') | Should -BeTrue
        $script:RatTable.ContainsKey('BashIsm') | Should -BeTrue
    }
    It 'renders a rule rationale ONCE per file, however many times the rule fires (dedup per rule)' {
        $rendered = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)
        $first = Get-RationaleForCode -Code 'PSUseApprovedVerbs' -Table $script:RatTable -Rendered $rendered
        $second = Get-RationaleForCode -Code 'PSUseApprovedVerbs' -Table $script:RatTable -Rendered $rendered
        $third = Get-RationaleForCode -Code 'PSUseApprovedVerbs' -Table $script:RatTable -Rendered $rendered
        $first | Should -Not -BeNullOrEmpty
        $second | Should -BeExactly ''
        $third | Should -BeExactly ''
    }
    It 'a DIFFERENT rule in the same file still renders its own rationale' {
        $rendered = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)
        (Get-RationaleForCode -Code 'PSUseApprovedVerbs' -Table $script:RatTable -Rendered $rendered) | Should -Not -BeNullOrEmpty
        (Get-RationaleForCode -Code 'PSAvoidUsingWriteHost' -Table $script:RatTable -Rendered $rendered) | Should -Not -BeNullOrEmpty
    }
    It 'DEGRADES GRACEFULLY: a code with no table entry yields no rationale line, never a throw' {
        $rendered = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)
        # LOAD-BEARING EXEMPLAR (000124). PSUseSingularNouns is a REAL PSScriptAnalyzer code that is
        # deliberately entry-less: 000092 excluded it from the base surface as measured-noisy, so
        # the table derives no entry for it, yet a user's own PSScriptAnalyzerSettings.psd1 can still
        # broaden the live surface and make PSES emit it (000085). That makes it the honest
        # real-world degrade case now that all 5 owned codes carry entries. If a future curation
        # slice re-admits it to base.psd1, or a pin bump renames it, THIS TEST is what goes RED --
        # re-anchor it on another real entry-less code, do not delete the assertion.
        (Get-RationaleForCode -Code 'PSUseSingularNouns' -Table $script:RatTable -Rendered $rendered) | Should -BeExactly ''
        # Non-vacuity: the exemplar is only meaningful while it is genuinely absent from the table.
        $script:RatTable.ContainsKey('PSUseSingularNouns') | Should -BeFalse
        # And the purely synthetic case -- a code no analyzer will ever emit.
        (Get-RationaleForCode -Code 'PSTotallyMadeUpRule' -Table $script:RatTable -Rendered $rendered) | Should -BeExactly ''
    }
    It 'an OWNED code that DOES carry an entry renders it (ManifestConsistency; 000124)' {
        # The complement of the degrade test above: the 000121 residual is closed, so the plugin's
        # fifth owned code now resolves to its hand-authored rationale instead of degrading.
        $rendered = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)
        $why = Get-RationaleForCode -Code 'ManifestConsistency' -Table $script:RatTable -Rendered $rendered
        $why | Should -Not -BeNullOrEmpty
        $why | Should -Match 'FunctionsToExport'
    }
    It 'a parser finding (empty or 0 code) never carries a rationale' {
        $rendered = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)
        (Get-RationaleForCode -Code '' -Table $script:RatTable -Rendered $rendered) | Should -BeExactly ''
        (Get-RationaleForCode -Code '0' -Table $script:RatTable -Rendered $rendered) | Should -BeExactly ''
    }
    It 'an EMPTY table degrades to no rationale lines at all (absent/unparseable file)' {
        $rendered = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)
        (Get-RationaleForCode -Code 'PSUseApprovedVerbs' -Table @{} -Rendered $rendered) | Should -BeExactly ''
    }
    It 'a whole-file render pass emits one rationale per distinct rule, in first-appearance order' {
        # Drives the exact sequence lsp-client.ps1's render loop drives: one $Rendered set for the
        # file, one Get-RationaleForCode call per finding, in render order.
        $records = @(
            [pscustomobject]@{ code = 'PSAvoidUsingWriteHost' }
            [pscustomobject]@{ code = 'PSUseApprovedVerbs' }
            [pscustomobject]@{ code = 'PSAvoidUsingWriteHost' }   # repeat -> no second line
            [pscustomobject]@{ code = 'ManifestConsistency' }     # owned, HAS an entry -> renders (000124)
            [pscustomobject]@{ code = 'PSUseSingularNouns' }      # real, entry-less -> degrade (000124)
            [pscustomobject]@{ code = '' }                        # parser -> skipped
        )
        $rendered = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)
        $emitted = @()
        foreach ($r in $records) {
            $why = Get-RationaleForCode -Code ([string]$r.code) -Table $script:RatTable -Rendered $rendered
            if (-not [string]::IsNullOrWhiteSpace($why)) { $emitted += [string]$r.code }
        }
        $emitted.Count | Should -Be 3
        $emitted[0] | Should -BeExactly 'PSAvoidUsingWriteHost'
        $emitted[1] | Should -BeExactly 'PSUseApprovedVerbs'
        $emitted[2] | Should -BeExactly 'ManifestConsistency'
    }
}

Describe 'regen-rule-rationales.ps1 -Check -- the shipped table matches the derivation at the pin (dispatch 000121)' {
    # The pin-coupled DERIVATION guard (the 000087 regen -Check shape). Vendors the pinned
    # PSScriptAnalyzer through the plugin's own ensure-pssa.ps1 -- the SAME BeforeAll bootstrap the
    # Corpus/Integration suites use -- then re-derives the whole table and diffs it against the
    # shipped file. Proven RED in-session: perturbing one rationale text, and dropping one owned
    # entry, each produced exit 1 with a precise diff; restoring produced exit 0 and the identical
    # SHA-256. So the shipped table can never drift silently from the pin.
    BeforeAll {
        & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:ScriptsDir 'ensure-pssa.ps1') 2>&1 | Out-Null
        $script:RegenScript = Join-Path $script:ScriptsDir 'regen-rule-rationales.ps1'
    }
    It 'the regen script ships and carries a -Check switch' {
        Test-Path -LiteralPath $script:RegenScript -PathType Leaf | Should -BeTrue
        (Get-Content -Raw -LiteralPath $script:RegenScript) | Should -Match '\[switch\]\s*\$Check'
    }
    It '-Check exits 0 against the shipped table (derived == shipped, offline at the pin)' {
        $out = & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $script:RegenScript -Check 2>&1
        $code = $LASTEXITCODE
        if ($code -ne 0) { Write-Host ($out | Out-String) }
        $code | Should -Be 0
    }
}

Describe 'New-ScriptAnalysisSettings -- the PSES scriptAnalysis settings object (dispatch 000018)' {
    It 'always enables analysis (with or without a settings path)' {
        (New-ScriptAnalysisSettings).enable | Should -BeTrue
        (New-ScriptAnalysisSettings 'C:\proj\PSScriptAnalyzerSettings.psd1').enable | Should -BeTrue
    }
    It 'omits settingsPath when none is given (no-config -> PSES default rules)' {
        (New-ScriptAnalysisSettings).ContainsKey('settingsPath') | Should -BeFalse
        ((New-ScriptAnalysisSettings '') | ConvertTo-Json -Compress) | Should -Not -Match 'settingsPath'
    }
    It 'includes settingsPath when resolved (the camelCase wire key PSES consumes)' {
        $obj = New-ScriptAnalysisSettings 'C:\proj\PSScriptAnalyzerSettings.psd1'
        $obj.settingsPath | Should -BeExactly 'C:\proj\PSScriptAnalyzerSettings.psd1'
        ($obj | ConvertTo-Json -Compress) | Should -Match '"settingsPath"'
    }
}

# ===========================================================================
# Analysis status: clean vs incomplete vs degraded (dispatch 000022)
# ===========================================================================

Describe 'Resolve-AnalysisStatus -- clean vs incomplete vs degraded (dispatch 000022)' {
    # The pure seam that keeps "could not analyze" from looking identical to "analyzed,
    # found nothing." Maps (settled, pssaAvailable) -> status; the daemon shapes it, the
    # client renders it, so the two cannot drift. Adversarial control: collapse the
    # not-settled branch in Resolve-AnalysisStatus and the 'incomplete beats degraded' and
    # 'distinguishes clean from incomplete' assertions go RED.
    It 'settled + PSSA available -> ok (a genuinely clean pass)' {
        Resolve-AnalysisStatus -Settled $true -PssaAvailable $true | Should -BeExactly 'ok'
    }
    It 'NOT settled -> incomplete (did not settle = we do not know the file is clean)' {
        Resolve-AnalysisStatus -Settled $false -PssaAvailable $true | Should -BeExactly 'incomplete'
    }
    It 'settled but PSSA absent -> degraded (parser-only)' {
        Resolve-AnalysisStatus -Settled $true -PssaAvailable $false | Should -BeExactly 'degraded'
    }
    It 'incomplete OUTRANKS degraded: not settled on a parser-only daemon is still incomplete' {
        # "this edit was not checked at all" beats "checked with fewer rules" (000022 Q(c)).
        Resolve-AnalysisStatus -Settled $false -PssaAvailable $false | Should -BeExactly 'incomplete'
    }
    It 'distinguishes clean (settled, zero records) from incomplete (did not settle) -- they must NOT be equal' {
        # The core acceptance (000022): a clean settled pass and a non-settling pass must
        # map to different statuses, so the client can render one as nothing and the other
        # as a visible "unavailable."
        $clean = Resolve-AnalysisStatus -Settled $true -PssaAvailable $true
        $incomplete = Resolve-AnalysisStatus -Settled $false -PssaAvailable $true
        $clean | Should -Not -BeExactly $incomplete
    }
}

Describe 'Get-DiagnosticsStatusBanner -- the visible, non-clean wording (dispatch 000022)' {
    # The exact user-facing text, owned in one place so daemon + client never disagree.
    # 'ok' MUST render empty -- that is the byte-identical warm-path guard (a clean pass
    # adds nothing to additionalContext). Adversarial control: return a non-empty string
    # for 'ok' and both this and the warm-path additivity integration test go RED.
    It 'renders nothing for ok (clean) -- the byte-identical warm-path guard' {
        Get-DiagnosticsStatusBanner 'ok' 'C:\x\foo.ps1' | Should -BeExactly ''
    }
    It 'renders nothing for an empty/absent status' {
        Get-DiagnosticsStatusBanner '' 'C:\x\foo.ps1' | Should -BeExactly ''
    }
    It 'incomplete: a single visible "analysis did not complete" message naming the file' {
        $b = Get-DiagnosticsStatusBanner 'incomplete' 'C:\x\foo.ps1'
        $b | Should -Match 'unavailable'
        $b | Should -Match 'did not complete'
        $b | Should -Match ([regex]::Escape('C:\x\foo.ps1'))
    }
    It 'degraded: a DISTINCT parser-only / PSScriptAnalyzer-unavailable message' {
        $b = Get-DiagnosticsStatusBanner 'degraded' 'C:\x\foo.ps1'
        $b | Should -Match 'parser-only'
        $b | Should -Match 'PSScriptAnalyzer unavailable'
    }
    It 'incomplete and degraded are DIFFERENT messages (two categories, not one)' {
        (Get-DiagnosticsStatusBanner 'incomplete' 'C:\x\foo.ps1') |
            Should -Not -BeExactly (Get-DiagnosticsStatusBanner 'degraded' 'C:\x\foo.ps1')
    }
    It 'unavailable (dispatch 000024): a DISTINCT install-incomplete message naming the file' {
        # The install-time case -- the PSES bundle never bootstrapped. Its remediation differs
        # from the transient 'incomplete' (fix the install/network, not "retry"), so it must
        # read distinctly: "not installed" / "bootstrap did not complete", not "did not settle."
        $b = Get-DiagnosticsStatusBanner 'unavailable' 'C:\x\foo.ps1'
        $b | Should -Match 'unavailable'
        $b | Should -Match 'not installed'
        $b | Should -Match 'bootstrap'
        $b | Should -Match ([regex]::Escape('C:\x\foo.ps1'))
    }
    It 'unavailable (dispatch 000024) is DIFFERENT from BOTH incomplete and degraded (three categories, not one)' {
        # 000024 extends the 000022 "make failure modes distinct" thesis to install-time: a
        # broken install must never render identically to a transient miss or a parser-only pass.
        $u = Get-DiagnosticsStatusBanner 'unavailable' 'C:\x\foo.ps1'
        $u | Should -Not -BeExactly (Get-DiagnosticsStatusBanner 'incomplete' 'C:\x\foo.ps1')
        $u | Should -Not -BeExactly (Get-DiagnosticsStatusBanner 'degraded' 'C:\x\foo.ps1')
    }
    It 'unavailable (dispatch 000028): the GENERALIZED prose covers BOTH causes AND lands PERMANENCE, distinct from the transient incomplete' {
        # 000028 widened 'unavailable' from install-only to ALSO cover "present but failed to start"
        # (the bundle-present init failure 000024 had left as a silent fail-fast). The token SET is
        # unchanged (still 4) -- only the PROSE generalizes (a PATCH-level refinement per CONTRACT.md).
        # It MUST land PERMANENT-this-session so a user never reads it as the TRANSIENT 'incomplete'
        # ("the next edit will be checked"). Adversarial control: drop the permanence clause from the
        # banner and this goes RED.
        $u = Get-DiagnosticsStatusBanner 'unavailable' 'C:\x\foo.ps1'
        $u | Should -Match 'could not start'                 # one wording for install-missing OR present-but-failed
        $u | Should -Match 'failed to start'                 # the present-but-failed cause (sub-case B)
        $u | Should -Match 'whole session'                   # PERMANENT this session, not a per-edit retry
        $u | Should -Match 'restarted'                       # remediation: fix + restart (not "retry")
        $u | Should -Not -Match 'analysis did not complete'  # must NOT borrow the transient incomplete signature
        # And the transient incomplete must NOT accidentally claim permanence -- the two stay distinct.
        (Get-DiagnosticsStatusBanner 'incomplete' 'C:\x\foo.ps1') | Should -Not -Match 'whole session'
    }
    It 'is ASCII-only (PS 5.1 em-dash trap)' {
        foreach ($s in @('incomplete', 'degraded', 'unavailable')) {
            $b = Get-DiagnosticsStatusBanner $s 'C:\x\foo.ps1'
            (@([System.Text.Encoding]::UTF8.GetBytes($b) | Where-Object { $_ -gt 127 }).Count) | Should -Be 0
        }
    }
}

# --- WS2: downloaded-dependency integrity (dispatch 000046, Gap B L2) -------
Describe 'Test-PinnedFileHash -- downloaded-dependency integrity (dispatch 000046)' {
    BeforeAll {
        $script:GoodFile = Join-Path $TestDrive 'artifact.bin'
        [System.IO.File]::WriteAllText($script:GoodFile, 'pinned-artifact-bytes', (New-Object System.Text.ASCIIEncoding))
        $script:GoodHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $script:GoodFile).Hash
    }
    It 'returns $true when the file matches its pinned SHA-256 (the verified-bundle direction)' {
        Test-PinnedFileHash -Path $script:GoodFile -ExpectedSha256 $script:GoodHash | Should -BeTrue
    }
    It 'matches case-insensitively (Get-FileHash emits upper-case hex)' {
        Test-PinnedFileHash -Path $script:GoodFile -ExpectedSha256 $script:GoodHash.ToLowerInvariant() | Should -BeTrue
    }
    It 'returns $false on a hash MISMATCH (the tampered-artifact direction -> caller fails closed)' {
        Test-PinnedFileHash -Path $script:GoodFile -ExpectedSha256 ('0' * 64) | Should -BeFalse
    }
    It 'detects a single-byte tamper (flipping one byte flips the verdict to $false)' {
        $tampered = Join-Path $TestDrive 'tampered.bin'
        [System.IO.File]::WriteAllText($tampered, 'pinned-artifact-byteS', (New-Object System.Text.ASCIIEncoding))
        Test-PinnedFileHash -Path $tampered -ExpectedSha256 $script:GoodHash | Should -BeFalse
    }
    It 'returns $false when the artifact is missing (absence is never read as verified)' {
        Test-PinnedFileHash -Path (Join-Path $TestDrive 'nope.bin') -ExpectedSha256 $script:GoodHash | Should -BeFalse
    }
    It 'returns $false on a blank pin (an empty pin can never count as verified)' {
        Test-PinnedFileHash -Path $script:GoodFile -ExpectedSha256 '' | Should -BeFalse
    }
}

Describe 'Pinned hash verification is WIRED into the bootstrap (dispatch 000046, Gap B L2)' {
    # The helper is only load-bearing if the ensure scripts actually CALL it against their pin
    # before using the download. These guards read the LIVE source so the wiring cannot silently
    # regress (a refactor that drops the verify, or a pin declared but never checked). Adversarial
    # control: delete the Test-PinnedFileHash call from ensure-pses and the ordering assertion
    # (verify-before-extract) goes RED.
    It 'ensure-pses.ps1 declares a 64-hex SHA-256 pin and verifies BEFORE extracting' {
        $src = Get-Content -LiteralPath (Join-Path $script:ScriptsDir 'ensure-pses.ps1') -Raw
        $src | Should -Match '\$PsesSha256\s*=\s*''[0-9A-Fa-f]{64}'''
        $src | Should -Match 'Test-PinnedFileHash[^\r\n]*\$PsesSha256'
        $verifyIdx = $src.IndexOf('Test-PinnedFileHash')
        $extractIdx = $src.IndexOf('Expand-Archive')
        $verifyIdx | Should -BeGreaterThan 0
        $extractIdx | Should -BeGreaterThan $verifyIdx
    }
    It 'ensure-pssa.ps1 declares a 64-hex SHA-256 pin and verifies the downloaded .nupkg' {
        $src = Get-Content -LiteralPath (Join-Path $script:ScriptsDir 'ensure-pssa.ps1') -Raw
        $src | Should -Match '\$PssaSha256\s*=\s*''[0-9A-Fa-f]{64}'''
        $src | Should -Match 'Test-PinnedFileHash[^\r\n]*\$PssaSha256'
    }
}

# --- 000049: the pinned-.nupkg cache is verify-gated and pin-bound -----------
Describe 'PSSA .nupkg cache is verify-gated and pin-bound (dispatch 000049)' {
    # The cache (the structural cure for the 000047 Gallery / CDN egress flake) is a classic place
    # to accidentally smuggle in a verification bypass. These guards read the LIVE source so the two
    # load-bearing invariants cannot silently regress: (1) a cache HIT is verified against the pin
    # BEFORE use, exactly like a fresh download; (2) the cache key binds to the pin so a bump can
    # never draw a stale artifact. The behavioral fail-closed proof lives in the integration suite
    # ('poisoned PSSA .nupkg cache FAILS CLOSED on restore'); these are the cheap source-level guards.
    BeforeAll {
        $script:EnsurePssaSrc = Get-Content -LiteralPath (Join-Path $script:ScriptsDir 'ensure-pssa.ps1') -Raw
    }
    It 'INVARIANT 1: a cache hit is copied into the verify path BEFORE the pin gate, which precedes any expand' {
        # cache-restore copy  <  Test-PinnedFileHash  <  Expand-Archive : the restored bytes flow
        # through the SAME gate a download does, and nothing is expanded/installed before the verify.
        # Adversarial control: move the cache copy after the verify (or the expand before it) -> RED.
        $restoreIdx = $script:EnsurePssaSrc.IndexOf('cache HIT')
        $verifyIdx = $script:EnsurePssaSrc.IndexOf('Test-PinnedFileHash -Path $nupkg -ExpectedSha256 $PssaSha256')
        $expandIdx = $script:EnsurePssaSrc.IndexOf('Expand-Archive')
        $restoreIdx | Should -BeGreaterThan 0
        $verifyIdx | Should -BeGreaterThan $restoreIdx
        $expandIdx | Should -BeGreaterThan $verifyIdx
    }
    It 'INVARIANT 1: exactly ONE pin-verify gate guards the install, and a mismatch fails closed' {
        # One Test-PinnedFileHash call over $nupkg guards both the cache-hit and download paths; the
        # cache hit does NOT add a second, weaker path. The mismatch branch refuses (fail closed).
        # 000244 added mirror and bundle layers ahead of the cache. The invariant is UNCHANGED and
        # now covers four sources instead of two: still exactly ONE gate over $nupkg, and every
        # layer feeds it. The failure message grew to name the offending layer, so the two
        # load-bearing halves are asserted separately rather than as one brittle sentence.
        @([regex]::Matches($script:EnsurePssaSrc, 'Test-PinnedFileHash -Path \$nupkg')).Count | Should -Be 1
        $script:EnsurePssaSrc | Should -Match 'integrity check failed \(hash mismatch\)'
        $script:EnsurePssaSrc | Should -Match 'refusing unverified package'
    }
    It 'INVARIANT 2: the cache filename binds to BOTH the pinned version and the SHA-256' {
        # A pin bump (version OR hash) yields a different filename -> a guaranteed miss, never a stale
        # draw. Adversarial control: drop $PssaSha256 from the cache filename and this goes RED.
        $script:EnsurePssaSrc | Should -Match '\$PssaVersion\s*\+\s*''-''\s*\+\s*\$PssaSha256'
    }
    It 'is OFF by default: gated on POWERSHELL_LSP_PSSA_CACHE, and the Gallery is reached only on a miss' {
        # When the env var is unset there is no cache and acquisition is byte-identical to 000047.
        $script:EnsurePssaSrc | Should -Match 'POWERSHELL_LSP_PSSA_CACHE'
        # The network fetch is gated behind the cache-miss guard. 000244 WIDENED that guard --
        # the Gallery is now also skipped when a mirror or bundle already resolved the artifact
        # -- so the anchor moved from `if (-not $fromCache)` to the widened condition. The
        # property under test is unchanged and strictly stronger: strictly fewer paths reach the
        # Gallery than before.
        $guardIdx = $script:EnsurePssaSrc.IndexOf('if (-not $sourced.Resolved -and -not $fromCache)')
        $downloadIdx = $script:EnsurePssaSrc.IndexOf('Invoke-WebRequest')
        $guardIdx | Should -BeGreaterThan 0
        $downloadIdx | Should -BeGreaterThan $guardIdx
    }
    It 'print-pssa-pin.ps1 emits the LIVE pin as version + 64-hex sha256 (the CI cache-key source)' {
        # The CI cache key is pssa-<os>-<version>-<sha256>; this script single-sources the pin from
        # ensure-pssa.ps1 so the key binds to it. A drift here would mis-key the cache.
        $lines = @(& (Join-Path $script:ScriptsDir 'print-pssa-pin.ps1'))
        @($lines | Where-Object { $_ -match '^version=\d+\.\d+\.\d+$' }).Count | Should -Be 1
        @($lines | Where-Object { $_ -match '^sha256=[0-9A-Fa-f]{64}$' }).Count | Should -Be 1
        $vp = ([regex]'\$PssaVersion\s*=\s*''([^'']+)''').Match($script:EnsurePssaSrc).Groups[1].Value
        $hp = ([regex]'\$PssaSha256\s*=\s*''([0-9A-Fa-f]{64})''').Match($script:EnsurePssaSrc).Groups[1].Value
        $lines | Should -Contain ('version=' + $vp)
        $lines | Should -Contain ('sha256=' + $hp)
    }
}

Describe 'Pester bootstrap is bounded to the 5.x major (dispatch 000120)' {
    # Pester 6.0.0 went GA on the PowerShell Gallery 2026-07-07. tests/run-tests.ps1 resolves
    # Pester at THREE points that were all unbounded UPWARD, so a runner-image change or a
    # fresh-install path could silently run the whole suite under Pester 6 with nobody deciding
    # to upgrade. All three are now capped at the 5.x major. These text-pin guards read the LIVE
    # source (the 000073 attest-pin Should-Match-on-the-literal pattern) so a future edit cannot
    # silently UNBOUND any one of them -- remove a single cap and its assertion goes RED.
    # Migrating to Pester 6 is a separate, later, Mike-minted decision; when it lands these
    # literals are retargeted DELIBERATELY (as the 000073 pin is), never loosened by accident.
    # Adversarial control: revert the detection filter to '-ge 5' and the first It goes RED.
    BeforeAll {
        $script:RunTestsSrc = Get-Content -LiteralPath (Join-Path (Join-Path $script:PluginRoot 'tests') 'run-tests.ps1') -Raw
    }
    It 'bounds the detection filter to the 5.x major (Version.Major -eq 5, never -ge 5)' {
        $script:RunTestsSrc | Should -Match '\$_\.Version\.Major -eq 5'
        $script:RunTestsSrc | Should -Not -Match '\$_\.Version\.Major -ge 5'
    }
    It 'caps the Install-Module fresh-install path at -MaximumVersion 5.99.99' {
        $script:RunTestsSrc | Should -Match 'Install-Module Pester[^\r\n]*-MaximumVersion 5\.99\.99'
    }
    It 'caps the Import-Module import at -MaximumVersion 5.99.99 (imports by name, not the resolved $p5)' {
        $script:RunTestsSrc | Should -Match 'Import-Module Pester[^\r\n]*-MaximumVersion 5\.99\.99'
    }
}

# ===========================================================================
# Format-on-edit: suggest, never rewrite (dispatch 000059, PL-8) -- pure helpers
# ===========================================================================
# The PSSA-touching parts (real Invoke-Formatter, repo-settings honoring, failure
# degrade, suggest-not-rewrite, knob-off byte-compare) are proven end to end in the
# integration suite (which bootstraps PSSA + a real daemon). These unit tests pin the
# PURE logic: the off-by-default knob parse, the unified-diff shaping, and the surface
# wording -- no PSSA, no daemon, no network.

Describe 'ConvertTo-FormatOnEditMode -- off-by-default knob parse (dispatch 000059)' {
    It 'maps suggest (and boolean-truthy aliases) to suggest' {
        foreach ($v in @('suggest', 'SUGGEST', ' Suggest ', 'true', 'on', '1', 'yes')) {
            (ConvertTo-FormatOnEditMode $v) | Should -BeExactly 'suggest'
        }
    }
    It 'maps off / blank / unexpanded token / unknown to off -- never silently on' {
        # The feature is opt-in: anything not explicitly an ON value is OFF. Adversarial control:
        # make the default branch return 'suggest' and these go RED (the knob would default ON).
        foreach ($v in @('off', '', '   ', '${user_config.formatOnEdit}', 'garbage', 'false', '0')) {
            (ConvertTo-FormatOnEditMode $v) | Should -BeExactly 'off'
        }
    }
    It 'maps the exact value apply to apply -- and ONLY the exact value (000099, doubly opt-in)' {
        # 000099 activated apply -- the write-back mode. It is DOUBLY opt-in: only the exact string
        # 'apply' (case/whitespace-insensitive) reaches it. A boolean-truthy alias must NOT, so a
        # user reaching for a boolean gets the safe suggest, never a file-writing mode. Adversarial
        # control: route a boolean alias to 'apply' and the alias assertions below go RED.
        (ConvertTo-FormatOnEditMode 'apply')    | Should -BeExactly 'apply'
        (ConvertTo-FormatOnEditMode '  APPLY ') | Should -BeExactly 'apply'
        foreach ($v in @('true', 'on', '1', 'yes')) {
            (ConvertTo-FormatOnEditMode $v) | Should -BeExactly 'suggest'   # NOT apply
        }
    }
}

Describe 'Get-FormatDiffResult -- unified diff + counts (dispatch 000059)' {
    It 'reports no change for identical text (the clean-edit-emits-nothing property)' {
        $r = Get-FormatDiffResult -Original "a`nb`n" -Formatted "a`nb`n"
        $r.changed | Should -BeFalse
        $r.diff | Should -BeExactly ''
        $r.removed | Should -Be 0
        $r.added | Should -Be 0
    }
    It 'treats a pure CRLF/LF delta as no change (newline-normalized)' {
        (Get-FormatDiffResult -Original "a`nb`n" -Formatted "a`r`nb`r`n").changed | Should -BeFalse
    }
    It 'produces a unified diff with correct -removed/+added counts and hunk header' {
        $orig = "function T {`nGet-Process`n}`n"
        $fmt = "function T {`n    Get-Process`n}`n"
        $r = Get-FormatDiffResult -Original $orig -Formatted $fmt
        $r.changed | Should -BeTrue
        $r.removed | Should -Be 1
        $r.added | Should -Be 1
        $r.diff | Should -Match '@@ -\d+,\d+ \+\d+,\d+ @@'
        $r.diff | Should -Match '(?m)^-Get-Process$'
        $r.diff | Should -Match '(?m)^\+    Get-Process$'
        # Unchanged lines are context (leading space), never +/-.
        $r.diff | Should -Match '(?m)^ function T \{$'
    }
    It 'flags a casing-only change (case-sensitive line compare)' {
        (Get-FormatDiffResult -Original "get-process`n" -Formatted "Get-Process`n").changed | Should -BeTrue
    }
    It 'caps the diff body and flags truncation for a large reflow' {
        $orig = (1..200 | ForEach-Object { "x$_" }) -join "`n"
        $fmt = (1..200 | ForEach-Object { "    y$_" }) -join "`n"
        $r = Get-FormatDiffResult -Original $orig -Formatted $fmt -MaxLines 20
        $r.changed | Should -BeTrue
        $r.truncated | Should -BeTrue
        (@($r.diff -split "`n").Count) | Should -BeLessOrEqual 21
    }
}

Describe 'Format-FormattingSuggestionBlock -- the suggest-not-rewrite surface (dispatch 000059)' {
    It 'is empty when there is nothing to suggest (no diff)' {
        (Format-FormattingSuggestionBlock -Path 'x.ps1' -Diff '' -Removed 0 -Added 0 -Truncated $false -SettingsPath '') |
            Should -BeExactly ''
    }
    It 'states the file was NOT modified and is visibly distinct from a diagnostic' {
        $b = Format-FormattingSuggestionBlock -Path 'x.ps1' -Diff "@@ -1,1 +1,1 @@`n-a`n+ a" -Removed 1 -Added 1 -Truncated $false -SettingsPath ''
        $b | Should -Match 'formatting suggestion'
        $b | Should -Match 'NOT modified'
        $b | Should -Not -Match 'PowerShell diagnostics \('   # never reads as a correctness finding
        $b | Should -Match 'default PSScriptAnalyzer style'
    }
    It 'names the repo settings file when one was honored' {
        $b = Format-FormattingSuggestionBlock -Path 'x.ps1' -Diff "@@ -1,1 +1,1 @@`n-a`n+ a" -Removed 1 -Added 1 -Truncated $false -SettingsPath 'C:\repo\PSScriptAnalyzerSettings.psd1'
        $b | Should -Match 'repo style \(PSScriptAnalyzerSettings\.psd1\)'
    }
    It 'appends a truncation marker when the diff was capped' {
        $b = Format-FormattingSuggestionBlock -Path 'x.ps1' -Diff "@@ -1,1 +1,1 @@`n-a`n+ a" -Removed 9 -Added 9 -Truncated $true -SettingsPath ''
        $b | Should -Match 'formatting diff truncated'
    }
}

# (d) ASCII-clean + parse over every shipped .ps1 (scripts AND tests).
$script:AllPs1 = Get-ChildItem (Split-Path -Parent $PSScriptRoot) -Recurse -Filter *.ps1 -File

Describe 'Shipped PowerShell is ASCII-clean and parses' {
    # SELECTED-COUNT FLOOR (dispatch 000172). Without it, a broken root path or a -Filter typo
    # makes $script:AllPs1 empty, the two -ForEach blocks below expand to ZERO cases, and the whole
    # Describe reads as a pass while asserting nothing. That is the vacuous-match class: the floor
    # is what makes "every shipped .ps1 parses" a claim rather than a shape.
    #
    # THE COUNT IS CAPTURED VIA -ForEach, ON PURPOSE. $script:AllPs1 is assigned at the top of this
    # file, which runs in Pester's DISCOVERY pass only; by run phase it is $null, and reading it
    # inside an It body yields @($null) -- a one-element array, which sails past a "greater than 0"
    # floor and reports 1 against a real 146. (It did exactly that on the first full-suite run of
    # 000172, which is the argument for running the suite locally before pushing.) -ForEach is
    # evaluated at DISCOVERY time, where the variable is live, so this measures the SAME
    # enumeration that feeds the two data-driven blocks below rather than a re-derived one.
    It 'SELECTED-COUNT FLOOR: the enumeration actually walked the tree' -ForEach @(
        @{ SelectedCount = @($script:AllPs1).Count }
    ) {
        $SelectedCount | Should -BeGreaterThan 0
        $SelectedCount | Should -BeGreaterThan 100 -Because (
            'the shipped tree carries well over a hundred .ps1 files (148 at dispatch 000172); a ' +
            'count that collapses below this means the enumeration broke, not that the repo shrank')
    }

    It '<_.Name> contains no bytes greater than 127' -ForEach $script:AllPs1 {
        $bad = @([System.IO.File]::ReadAllBytes($_.FullName) | Where-Object { $_ -gt 127 })
        $bad.Count | Should -Be 0
    }
    It '<_.Name> parses with zero errors' -ForEach $script:AllPs1 {
        $errs = $null; $tokens = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errs)
        @($errs).Count | Should -Be 0
    }
}

# ===========================================================================
# Edit-range diagnostic scoping (dispatch 000019)
# ===========================================================================

Describe 'ConvertTo-TouchedRanges -- derive touched line ranges from tool_response (dispatch 000019)' {
    # Track 1 finding (confirmed against real PostToolUse payloads): a successful Edit /
    # MultiEdit / Write-update carries structuredPatch hunks with 1-based post-edit
    # newStart/newLines; a FAILED edit reports a STRING tool_response; a Write-create has
    # an EMPTY patch. Derivation is keyed on PATCH STATE, not tool name, and FAILS OPEN
    # (returns $null) on anything indeterminate so scoping can never hide a diagnostic.
    BeforeAll {
        # Defined in BeforeAll (run phase): a function in the Describe body would only
        # exist during Pester's discovery phase and be invisible to the It blocks.
        function New-Resp { param($Hunks) [pscustomobject]@{ structuredPatch = $Hunks } }
        function New-Hunk { param($NewStart, $NewLines) [pscustomobject]@{ newStart = $NewStart; newLines = $NewLines } }
    }

    It 'derives a single hunk span [newStart, newStart+newLines-1]' {
        $r = @(ConvertTo-TouchedRanges -ToolResponse (New-Resp @((New-Hunk 10 3))))
        $r.Count | Should -Be 1
        $r[0].start | Should -Be 10
        $r[0].end | Should -Be 12
    }
    It 'unions multiple hunks (a single Edit can split into several)' {
        $r = @(ConvertTo-TouchedRanges -ToolResponse (New-Resp @((New-Hunk 279 18), (New-Hunk 306 7))))
        $r.Count | Should -Be 2
        $r[0].start | Should -Be 279; $r[0].end | Should -Be 296
        $r[1].start | Should -Be 306; $r[1].end | Should -Be 312
    }
    It 'widens by ContextLines and clamps the low end to line 1' {
        $r = @(ConvertTo-TouchedRanges -ToolResponse (New-Resp @((New-Hunk 2 1))) -ContextLines 3)
        $r[0].start | Should -Be 1     # 2 - 3 = -1 -> clamped to 1
        $r[0].end | Should -Be 5       # (2 + 1 - 1) + 3 = 5
    }
    It 'defaults ContextLines to 0 (the patch already includes diff context; do not stack)' {
        $r = @(ConvertTo-TouchedRanges -ToolResponse (New-Resp @((New-Hunk 10 1))))
        $r[0].start | Should -Be 10
        $r[0].end | Should -Be 10
    }
    It 'treats a 0-line (pure deletion) hunk as the single line at newStart' {
        $r = @(ConvertTo-TouchedRanges -ToolResponse (New-Resp @((New-Hunk 40 0))))
        $r[0].start | Should -Be 40
        $r[0].end | Should -Be 40
    }
    It 'FAILS OPEN ($null) on a string tool_response (a FAILED edit reports a string error)' {
        ConvertTo-TouchedRanges -ToolResponse 'Error: String to replace not found in file.' | Should -BeNullOrEmpty
    }
    It 'FAILS OPEN ($null) on a null tool_response (missing payload field)' {
        ConvertTo-TouchedRanges -ToolResponse $null | Should -BeNullOrEmpty
    }
    It 'FAILS OPEN ($null) when there is no structuredPatch property' {
        ConvertTo-TouchedRanges -ToolResponse ([pscustomobject]@{ filePath = 'x.ps1'; type = 'create' }) | Should -BeNullOrEmpty
    }
    It 'FAILS OPEN ($null) on an EMPTY structuredPatch (a Write that created a new file)' {
        ConvertTo-TouchedRanges -ToolResponse (New-Resp @()) | Should -BeNullOrEmpty
    }
    It 'FAILS OPEN ($null) when hunks carry no usable newStart' {
        ConvertTo-TouchedRanges -ToolResponse (New-Resp @(([pscustomobject]@{ newLines = 3 }))) | Should -BeNullOrEmpty
    }
}

Describe 'Select-DiagnosticsInRange -- overlap not containment, fail-open (dispatch 000019)' {
    BeforeAll {
        function New-Rec { param($Line, $EndLine) [ordered]@{ severity = 'Warning'; line = $Line; endLine = $EndLine; col = 1; source = 'PSSA'; code = 'X'; message = ('m' + $Line) } }
    }
    It 'keeps a diagnostic whose multi-line span STRADDLES the edit boundary (overlap, not containment)' {
        # Diagnostic spans lines 3..7; the edit touched only line 6. Neither endpoint is
        # inside the range, but the span crosses it -> kept (000019 Q4: overlap).
        $recs = @((New-Rec 3 7))
        $range = @([pscustomobject]@{ start = 6; end = 6 })
        @(Select-DiagnosticsInRange $recs $range).Count | Should -Be 1
    }
    It 'drops a diagnostic entirely outside the touched range' {
        @(Select-DiagnosticsInRange @((New-Rec 3 3)) @([pscustomobject]@{ start = 6; end = 6 })).Count | Should -Be 0
    }
    It 'keeps an in-range diagnostic (never over-filters the edited line itself)' {
        @(Select-DiagnosticsInRange @((New-Rec 6 6)) @([pscustomobject]@{ start = 6; end = 6 })).Count | Should -Be 1
    }
    It 'FAILS OPEN: null OR empty ranges return ALL records (an indeterminate range hides nothing)' {
        $recs = @((New-Rec 3 3), (New-Rec 99 99))
        @(Select-DiagnosticsInRange $recs $null).Count | Should -Be 2
        @(Select-DiagnosticsInRange $recs @()).Count | Should -Be 2
    }
    It 'treats a record without endLine as a point at its start line' {
        $recs = @([ordered]@{ severity = 'Warning'; line = 6; col = 1; source = 'PSSA'; code = 'X'; message = 'no-end' })
        @(Select-DiagnosticsInRange $recs @([pscustomobject]@{ start = 6; end = 6 })).Count | Should -Be 1
        @(Select-DiagnosticsInRange $recs @([pscustomobject]@{ start = 8; end = 8 })).Count | Should -Be 0
    }
}

Describe 'Get-ScopedCappedResult -- scope then cap, with telemetry counts (dispatch 000019)' {
    # The load-bearing adversarial control (mirrors 000018's RED/GREEN): with a touched
    # range, the out-of-range diagnostic is filtered; with no range (scoping off /
    # indeterminate), it reappears. Plus: scope runs BEFORE the cap, and the pre-scope
    # (total) / post-scope (surfaced) counts are recorded so the noise reduction is
    # measurable.
    BeforeAll {
        function New-Rec { param($Line, $EndLine) [ordered]@{ severity = 'Warning'; line = $Line; endLine = $EndLine; col = 1; source = 'PSSA'; code = 'X'; message = ('m' + $Line) } }
        $script:Recs = @((New-Rec 5 5), (New-Rec 50 50), (New-Rec 6 8))
        $script:Range = @([pscustomobject]@{ start = 4; end = 6 })
    }
    It 'GREEN: scopes to the touched range (out-of-range dropped, overlap kept)' {
        $r = Get-ScopedCappedResult -Records $script:Recs -Ranges $script:Range -PerFileCap 20
        @($r.shown).Count | Should -Be 2
        $r.shown.line | Should -Not -Contain 50
        $r.scopeApplied | Should -BeTrue
        $r.total | Should -Be 3
        $r.surfaced | Should -Be 2
    }
    It 'RED on revert: no ranges -> NOTHING dropped (whole-file, byte-identical to cap-only)' {
        $r = Get-ScopedCappedResult -Records $script:Recs -Ranges $null -PerFileCap 20
        @($r.shown).Count | Should -Be 3
        $r.shown.line | Should -Contain 50
        $r.scopeApplied | Should -BeFalse
        $r.total | Should -Be 3
        $r.surfaced | Should -Be 3
    }
    It 'scope-then-cap: the cap applies to the SCOPED set (30 in-range, cap 20 -> 20 shown, 10 omitted, 30 surfaced)' {
        $many = @(1..30 | ForEach-Object { New-Rec 5 5 })
        $r = Get-ScopedCappedResult -Records $many -Ranges $script:Range -PerFileCap 20
        $r.surfaced | Should -Be 30
        @($r.shown).Count | Should -Be 20
        $r.omitted | Should -Be 10
    }
    It 'scope-then-cap: scoping below the cap means the cap never fires (5 in-range of 30 -> 5 shown, 0 omitted)' {
        # If the cap ran FIRST (cap-then-scope), it would slice the unscoped 30 down to 20
        # and then scope -- a different result. surfaced=5 + omitted=0 proves scope ran first.
        $mix = @(1..5 | ForEach-Object { New-Rec 5 5 }) + @(1..25 | ForEach-Object { New-Rec 99 99 })
        $r = Get-ScopedCappedResult -Records $mix -Ranges $script:Range -PerFileCap 20
        $r.surfaced | Should -Be 5
        @($r.shown).Count | Should -Be 5
        $r.omitted | Should -Be 0
    }
}

Describe 'ConvertTo-DiagRecord -- endLine for edit-range scoping (dispatch 000019)' {
    It 'emits endLine (1-based); equals the start line for a single-line diagnostic' {
        $d = [pscustomobject]@{
            range = [pscustomobject]@{ start = [pscustomobject]@{ line = 4; character = 0 }; end = [pscustomobject]@{ line = 4; character = 3 } }
            severity = 2; source = 'PSScriptAnalyzer'; code = 'X'; message = 'one line'
        }
        $r = ConvertTo-DiagRecord $d
        $r.Contains('endLine') | Should -BeTrue
        $r.line | Should -Be 5
        $r.endLine | Should -Be 5
    }
    It 'carries a multi-line span end (end line > start line)' {
        $d = [pscustomobject]@{
            range = [pscustomobject]@{ start = [pscustomobject]@{ line = 4; character = 0 }; end = [pscustomobject]@{ line = 9; character = 2 } }
            severity = 2; source = 'PSScriptAnalyzer'; code = 'X'; message = 'spans lines'
        }
        $r = ConvertTo-DiagRecord $d
        $r.line | Should -Be 5
        $r.endLine | Should -Be 10   # 0-based 9 -> 1-based 10
    }
    It 'defaults endLine to the start line when no range end is present' {
        $d = [pscustomobject]@{
            range = [pscustomobject]@{ start = [pscustomobject]@{ line = 7; character = 0 } }
            severity = 2; source = 'PSScriptAnalyzer'; code = 'X'; message = 'no end'
        }
        $r = ConvertTo-DiagRecord $d
        $r.endLine | Should -Be 8
    }
}

# ===========================================================================
# Single-source version stamp + docs honesty (dispatch 000025)
# ===========================================================================

Describe 'Get-PluginVersion -- single source of truth is the manifest (dispatch 000025)' {
    # 000023 audit S1b: three host-version literals (pses-stdio 1.0.0, pses-daemon 1.1.0,
    # lsp-common clientInfo 1.1.0) had drifted from the real plugin version and
    # bump-version.ps1 did not touch them. The fix sources every stamp from
    # .claude-plugin/plugin.json at runtime, so a manifest bump (the only place a version is
    # hand-set) can never leave a stale literal. Adversarial control: hardcode
    # Get-PluginVersion to a literal and the 'matches the manifest' assertion goes RED.
    BeforeAll {
        $manifestPath = Join-Path $script:PluginRoot '.claude-plugin/plugin.json'
        $script:ManifestVersion = [string](((Get-Content -LiteralPath $manifestPath -Raw) | ConvertFrom-Json).version)
    }
    It 'returns the exact version recorded in plugin.json' {
        Get-PluginVersion | Should -BeExactly $script:ManifestVersion
    }
    It 'returns a single, clean MAJOR.MINOR.PATCH string (no stray pipeline output)' {
        $out = @(Get-PluginVersion)
        $out.Count | Should -Be 1
        $out[0] | Should -Match '^\d+\.\d+\.\d+$'
    }
}

Describe 'Version stamps read the single source -- clientInfo + log line (dispatch 000025)' {
    # The warm-path LSP clientInfo.version (lib:409) and the daemon startup log stamp must
    # report the manifest version, not a literal. Proven against Get-PluginVersion (itself
    # proven == manifest above). Adversarial control: revert clientInfo.version to a literal
    # and the 'clientInfo carries the manifest version' assertion goes RED.
    It 'clientInfo.version equals Get-PluginVersion (the warm-path initialize stamp)' {
        (New-InitializeParams -RootUri 'file:///C:/proj' -ProcessId 1).clientInfo.version |
            Should -BeExactly (Get-PluginVersion)
    }
    It 'Get-VersionStamp embeds the plugin version (the daemon startup log surface, S1a)' {
        Get-VersionStamp | Should -BeExactly ('powershell-lsp ' + (Get-PluginVersion))
    }
}

Describe 'lsp-common.ps1 is load-silent -- the -Stdio stdout contract (dispatch 000025)' {
    # pses-stdio.ps1 dot-sources this lib, and its stdout IS the LSP byte stream once -Stdio
    # starts; a single byte emitted at import (or by Get-PluginVersion) would corrupt the
    # protocol. Guard: re-dot-sourcing the lib and calling Get-PluginVersion produce NO
    # success-stream output. Adversarial control: add a bare 'hello' expression at lib top
    # level and the 'emits nothing' assertion goes RED. (End-to-end proof that pses-stdio
    # itself prints nothing pre-handshake lives in the integration suite.)
    It 'dot-sourcing the lib emits nothing to the success stream' {
        $libPath = Join-Path $script:ScriptsDir 'lib/lsp-common.ps1'
        $captured = (. $libPath)
        $captured | Should -BeNullOrEmpty
    }
    It 'Get-PluginVersion emits nothing but its single return value' {
        @(Get-PluginVersion).Count | Should -Be 1
    }
}

Describe 'No hand-maintained host-version literal remains -- single-source guard (dispatch 000025)' {
    # The single-source fix means NONE of the three sites may carry a hardcoded
    # MAJOR.MINOR.PATCH version beside its stamp -- they must call Get-PluginVersion. This is
    # the 'can never go stale' guard: revert any site to a literal and its assertion goes
    # RED. Historical version mentions in COMMENTS (e.g. 'CHANGELOG 1.1.0') are NOT matched:
    # the patterns anchor on the -HostVersion argument and the clientInfo.version assignment.
    BeforeAll {
        $script:StdioSrc  = Get-Content -LiteralPath (Join-Path $script:ScriptsDir 'pses-stdio.ps1') -Raw
        $script:DaemonSrc = Get-Content -LiteralPath (Join-Path $script:ScriptsDir 'pses-daemon.ps1') -Raw
        $script:LibSrc    = Get-Content -LiteralPath (Join-Path $script:ScriptsDir 'lib/lsp-common.ps1') -Raw
    }
    It 'pses-stdio.ps1 stamps -HostVersion from Get-PluginVersion, not a literal' {
        $script:StdioSrc | Should -Match '-HostVersion \(Get-PluginVersion\)'
        $script:StdioSrc | Should -Not -Match "-HostVersion '\d+\.\d+\.\d+'"
    }
    It 'pses-daemon.ps1 stamps -HostVersion from Get-PluginVersion, not a literal' {
        $script:DaemonSrc | Should -Match "'-HostVersion', \(Get-PluginVersion\)"
        $script:DaemonSrc | Should -Not -Match "'-HostVersion', '\d+\.\d+\.\d+'"
    }
    It 'lsp-common.ps1 clientInfo.version is Get-PluginVersion, not a literal' {
        $script:LibSrc | Should -Match 'version = \(Get-PluginVersion\)'
        $script:LibSrc | Should -Not -Match "name = 'cc-pses-daemon'; version = '\d"
    }
    It 'pses-daemon.ps1 start banner emits the version stamp into the log (S1a)' {
        $script:DaemonSrc | Should -Match "daemon start: ' \+ \(Get-VersionStamp\)"
    }
}

Describe 'format-on-edit APPLY helpers -- byte fidelity + stale-write guard (dispatch 000099)' {
    Context 'BOM detection (byte fidelity)' {
        It 'detects a UTF-8 BOM prefix' { (Test-Utf8Bom ([byte[]](0xEF, 0xBB, 0xBF, 0x61))) | Should -BeTrue }
        It 'reports no UTF-8 BOM for plain bytes' { (Test-Utf8Bom ([byte[]](0x61, 0x62, 0x63))) | Should -BeFalse }
        It 'reports no UTF-8 BOM for an empty buffer (StrictMode-safe)' { (Test-Utf8Bom ([byte[]]@())) | Should -BeFalse }
        It 'detects UTF-16 LE and BE BOMs (unsupported for apply)' {
            (Test-Utf16Bom ([byte[]](0xFF, 0xFE, 0x61, 0x00))) | Should -BeTrue
            (Test-Utf16Bom ([byte[]](0xFE, 0xFF, 0x00, 0x61))) | Should -BeTrue
        }
        It 'reports no UTF-16 BOM for a UTF-8 file' { (Test-Utf16Bom ([byte[]](0xEF, 0xBB, 0xBF, 0x61))) | Should -BeFalse }
    }
    Context 'EOL classification (OQ4 -- mixed aborts to suggest)' {
        It 'classifies pure LF' { (Get-DominantEol "a`nb`n") | Should -BeExactly 'lf' }
        It 'classifies pure CRLF' { (Get-DominantEol "a`r`nb`r`n") | Should -BeExactly 'crlf' }
        It 'classifies MIXED CRLF+LF as mixed' { (Get-DominantEol "a`r`nb`n") | Should -BeExactly 'mixed' }
        It 'classifies a lone CR (classic Mac) as mixed/unsupported' { (Get-DominantEol "a`rb") | Should -BeExactly 'mixed' }
        It 'classifies a single line with no terminator as none' { (Get-DominantEol 'abc') | Should -BeExactly 'none' }
    }
    Context 'ConvertTo-Eol -- re-apply the original style' {
        It 're-applies CRLF to LF text' { (ConvertTo-Eol "a`nb`n" 'crlf') | Should -BeExactly "a`r`nb`r`n" }
        It 'normalizes CRLF text to LF' { (ConvertTo-Eol "a`r`nb`r`n" 'lf') | Should -BeExactly "a`nb`n" }
        It 'leaves LF for none' { (ConvertTo-Eol 'abc' 'none') | Should -BeExactly 'abc' }
    }
    Context 'Get-ApplyEncodedBytes -- the byte-fidelity assembler' {
        It 'returns a byte[] (never pipeline-unrolled)' {
            $b = Get-ApplyEncodedBytes -FormattedText "x`n" -Eol 'lf' -HasBom $false
            ($b -is [byte[]]) | Should -BeTrue
        }
        It 'prepends the UTF-8 BOM iff HasBom' {
            $b = Get-ApplyEncodedBytes -FormattedText "x`n" -Eol 'lf' -HasBom $true
            $b[0] | Should -Be 0xEF; $b[1] | Should -Be 0xBB; $b[2] | Should -Be 0xBF
            (Get-ApplyEncodedBytes -FormattedText "x`n" -Eol 'lf' -HasBom $false)[0] | Should -Be 0x78
        }
        It 'applies CRLF at the byte level (dominant-EOL preservation)' {
            $b = Get-ApplyEncodedBytes -FormattedText "a`nb`n" -Eol 'crlf' -HasBom $false
            ([System.Text.Encoding]::UTF8.GetString($b)) | Should -BeExactly "a`r`nb`r`n"
        }
    }
    Context 'Get-Sha256HexFromBytes -- the stale-write fingerprint' {
        It 'is a 64-char lowercase hex digest' {
            (Get-Sha256HexFromBytes ([System.Text.Encoding]::UTF8.GetBytes('x'))) | Should -Match '^[0-9a-f]{64}$'
        }
        It 'matches the known SHA-256 of "hello"' {
            (Get-Sha256HexFromBytes ([System.Text.Encoding]::UTF8.GetBytes('hello'))) |
                Should -BeExactly '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824'
        }
        It 'differs for a one-byte change' {
            (Get-Sha256HexFromBytes ([byte[]](1, 2, 3))) | Should -Not -Be (Get-Sha256HexFromBytes ([byte[]](1, 2, 4)))
        }
    }
    Context 'Write-FormatResultAtomic -- the stale-write compare-and-swap, proven adversarially' {
        BeforeEach {
            $script:AppDir = Join-Path ([System.IO.Path]::GetTempPath()) ('pslsp-apply-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 10))
            New-Item -ItemType Directory -Force -Path $script:AppDir | Out-Null
            $script:AppFile = Join-Path $script:AppDir 'f.ps1'
        }
        AfterEach {
            if (Test-Path -LiteralPath $script:AppDir) { Remove-Item -LiteralPath $script:AppDir -Recurse -Force -ErrorAction SilentlyContinue }
        }
        It 'HAPPY PATH: an unmutated file is written atomically with the formatted bytes' {
            $orig = [System.Text.Encoding]::UTF8.GetBytes("orig`n")
            [System.IO.File]::WriteAllBytes($script:AppFile, $orig)
            $h = Get-Sha256HexFromBytes ([System.IO.File]::ReadAllBytes($script:AppFile))
            $new = [System.Text.Encoding]::UTF8.GetBytes("formatted`n")
            $r = Write-FormatResultAtomic -Full $script:AppFile -InputHash $h -OutBytes $new
            $r.applied | Should -BeTrue
            [System.IO.File]::ReadAllBytes($script:AppFile) | Should -Be $new
        }
        It 'ADVERSARIAL: a file mutated between format-input capture and the write ABORTS, and the mutated bytes survive untouched' {
            $orig = [System.Text.Encoding]::UTF8.GetBytes("orig`n")
            [System.IO.File]::WriteAllBytes($script:AppFile, $orig)
            $h = Get-Sha256HexFromBytes ([System.IO.File]::ReadAllBytes($script:AppFile))   # (input capture)
            $mutated = [System.Text.Encoding]::UTF8.GetBytes("MUTATED-BY-A-NEWER-EDIT`n")
            [System.IO.File]::WriteAllBytes($script:AppFile, $mutated)                       # (concurrent modification)
            $new = [System.Text.Encoding]::UTF8.GetBytes("formatted`n")
            $r = Write-FormatResultAtomic -Full $script:AppFile -InputHash $h -OutBytes $new
            $r.applied | Should -BeFalse                                                     # (a) the apply ABORTED
            $r.reason | Should -Match 'changed on disk'                                      # (c) honest abort reason
            [System.IO.File]::ReadAllBytes($script:AppFile) | Should -Be $mutated            # (b) mutated bytes survive
        }
        It 'leaves NO temp file behind on either the applied or the aborted path' {
            $orig = [System.Text.Encoding]::UTF8.GetBytes("orig`n")
            [System.IO.File]::WriteAllBytes($script:AppFile, $orig)
            $h = Get-Sha256HexFromBytes $orig
            [void](Write-FormatResultAtomic -Full $script:AppFile -InputHash $h -OutBytes ([System.Text.Encoding]::UTF8.GetBytes("z`n")))       # applies
            [void](Write-FormatResultAtomic -Full $script:AppFile -InputHash 'deadbeef' -OutBytes ([System.Text.Encoding]::UTF8.GetBytes("z`n"))) # aborts (bad hash)
            @(Get-ChildItem -LiteralPath $script:AppDir -Filter '.pslsp-fmt-*' -Force).Count | Should -Be 0
        }
    }
    Context 'apply surface renderers -- visibly distinct from suggest and diagnostics' {
        It 'the APPLIED block says WAS MODIFIED and instructs a RE-READ (never "NOT modified")' {
            $b = Format-FormattingAppliedBlock -Path 'x.ps1' -Diff '@@ -1 +1 @@' -Removed 1 -Added 1 -Truncated $false -SettingsPath ''
            $b | Should -Match 'APPLIED'
            $b | Should -Match 'WAS MODIFIED'
            $b | Should -Match 'RE-READ'
            $b | Should -Not -Match 'NOT modified'
        }
        It 'the APPLIED block is empty when there is no diff' {
            (Format-FormattingAppliedBlock -Path 'x.ps1' -Diff '' -Removed 0 -Added 0 -Truncated $false -SettingsPath '') | Should -BeExactly ''
        }
        It 'the ABORTED fallback is suggest-shaped, says NOT modified, and names the reason' {
            $b = Format-FormattingApplyAbortedBlock -Path 'x.ps1' -Diff '@@ -1 +1 @@' -Removed 1 -Added 1 -Truncated $false -SettingsPath '' -Reason 'file has mixed line endings'
            $b | Should -Match 'formatting suggestion'
            $b | Should -Match 'apply did NOT run'
            $b | Should -Match 'NOT modified'
            $b | Should -Match 'mixed line endings'
        }
    }
}

Describe 'README config table documents every userConfig knob (dispatch 000025, 000023 D1 #4)' {
    # 000023 audit: the table documented 9 of 13 knobs (missing enableStats, settingsPath,
    # scopeToEdit, editContextLines). A paid product must not under-document the surface a
    # user pays to configure. Guard: the set of keys in the README Configuration table ==
    # the userConfig keys in plugin.json, exactly. Adversarial control: drop a table row (or
    # a manifest knob) and the set-equality assertion goes RED.
    BeforeAll {
        $manifestPath = Join-Path $script:PluginRoot '.claude-plugin/plugin.json'
        $manifest = (Get-Content -LiteralPath $manifestPath -Raw) | ConvertFrom-Json
        $script:ManifestKeys = @($manifest.userConfig.PSObject.Properties.Name) | Sort-Object

        # Slice the '## Configuration' section and pull the first-column `key` token of each
        # table row (the | Key | header and the |---| separator carry no backticks -> skipped;
        # the privacy blockquote starts with '>' not '|' -> skipped).
        $readmeText = Get-Content -LiteralPath (Join-Path $script:PluginRoot 'README.md') -Raw
        $m = [regex]::Match($readmeText, '(?ms)^##\s+Configuration\s*$(.*?)^##\s')
        $section = if ($m.Success) { $m.Groups[1].Value } else { '' }
        $keys = @()
        foreach ($line in ($section -split "`n")) {
            if ($line -match '^\s*\|\s*`([^`]+)`') { $keys += $Matches[1] }
        }
        $script:DocumentedKeys = @($keys) | Sort-Object
    }
    It 'documents exactly the manifest userConfig keys (none missing, none extra)' {
        ($script:DocumentedKeys -join ',') | Should -BeExactly ($script:ManifestKeys -join ',')
    }
    It 'documents the four knobs the 000023 audit found missing' {
        foreach ($k in @('enableStats', 'settingsPath', 'scopeToEdit', 'editContextLines')) {
            $script:DocumentedKeys | Should -Contain $k
        }
    }
}

Describe 'README documents the full diagnostics-status taxonomy (dispatch 000025)' {
    # Now that 000024 added the install-time 'unavailable', the README must document all four
    # statuses in one place. Guard: every status the code emits a non-empty banner for
    # (incomplete / degraded / unavailable -- the Get-DiagnosticsStatusBanner switch) appears
    # in the README, and the silent 'ok' is described too. Adversarial control: remove the
    # README docs for one banner status and the coverage assertion goes RED.
    BeforeAll {
        $script:ReadmeText = Get-Content -LiteralPath (Join-Path $script:PluginRoot 'README.md') -Raw
    }
    It 'documents every status that has a user-facing banner' {
        foreach ($s in @('incomplete', 'degraded', 'unavailable')) {
            (Get-DiagnosticsStatusBanner -Status $s -Path 'x.ps1') | Should -Not -BeNullOrEmpty
            $script:ReadmeText | Should -Match ('`' + $s + '`')
        }
    }
    It 'documents the silent clean status (ok)' {
        $script:ReadmeText | Should -Match '`ok`'
    }
}

# ===========================================================================
# CONTRACT.md 1.x freeze -- drift-guard (dispatch 000027)
# ===========================================================================
# The 1.x semver freeze (CONTRACT.md) pins two enumerable surfaces: the userConfig knob
# NAMES and the diagnostics status-token taxonomy. These guards give the freeze TEETH by
# validating CONTRACT.md against GROUND TRUTH extracted MECHANICALLY, LIVE FROM SOURCE --
# never against a hand-maintained list in this test:
#   - knob ground truth  = the userConfig keys parsed live from .claude-plugin/plugin.json.
#   - token ground truth = the Get-DiagnosticsStatusBanner switch labels (read from the
#     shipped function's AST) for the non-ok tokens, PLUS the clean token obtained by
#     CALLING Resolve-AnalysisStatus on a clean pass. ('ok' is the one token that is not a
#     banner switch label -- the banner returns '' for it -- so it is read from the resolver
#     that names it, not seeded as a literal here.)
# There is deliberately NO static {ps_host, ...} / {ok, ...} array in this file as the
# comparison anchor: the test reads the manifest and the functions, not a copy of them, so
# adding a knob to the manifest or a token to the banner FAILS CI until BOTH README and
# CONTRACT.md record it. README (above) and CONTRACT (here) are SEPARATE Describes so a red
# leg names WHICH document drifted. (Mike's non-negotiable, dispatch 000027.)

Describe 'CONTRACT.md freezes exactly the manifest userConfig knobs (dispatch 000027)' {
    BeforeAll {
        # GROUND TRUTH: the live manifest keys (read from plugin.json, NOT a copy).
        $manifestPath = Join-Path $script:PluginRoot '.claude-plugin/plugin.json'
        $manifest = (Get-Content -LiteralPath $manifestPath -Raw) | ConvertFrom-Json
        $script:ContractManifestKeys = @($manifest.userConfig.PSObject.Properties.Name) | Sort-Object

        # CONTRACT side: slice the sentinel-delimited FROZEN-KNOBS block and pull the
        # first-column backtick token of each table row. The HTML-comment markers bound the
        # machine-read region so prose backticks elsewhere in the doc cannot leak in; the
        # header (| Knob |) and separator (|---|) rows carry no backtick and are skipped.
        $contractPath = Join-Path $script:PluginRoot 'CONTRACT.md'
        $contractText = Get-Content -LiteralPath $contractPath -Raw
        $m = [regex]::Match($contractText, '(?s)FROZEN-KNOBS:BEGIN(.*?)FROZEN-KNOBS:END')
        $block = if ($m.Success) { $m.Groups[1].Value } else { '' }
        $keys = @()
        foreach ($line in ($block -split "`n")) {
            if ($line -match '^\s*\|\s*`([^`]+)`') { $keys += $Matches[1] }
        }
        $script:ContractKnobs = @($keys) | Sort-Object
    }
    It 'has a non-empty frozen-knobs block (the guard cannot pass vacuously)' {
        $script:ContractKnobs.Count | Should -BeGreaterThan 0
        $script:ContractManifestKeys.Count | Should -BeGreaterThan 0
    }
    It 'freezes exactly the manifest userConfig keys -- none missing, none extra' {
        # Set-equality against the LIVE manifest: add/rename/remove a knob in plugin.json
        # and this goes RED until CONTRACT.md matches. Adversarial control: drop or add a
        # FROZEN-KNOBS row (or a manifest knob) and the exact-match assertion goes RED.
        ($script:ContractKnobs -join ',') | Should -BeExactly ($script:ContractManifestKeys -join ',')
    }
}

Describe 'CONTRACT.md freezes exactly the diagnostics status-token taxonomy (dispatch 000027)' {
    BeforeAll {
        # GROUND TRUTH (live from source, two ways, no literal token list as the anchor):
        #   non-ok tokens <- the Get-DiagnosticsStatusBanner switch CLAUSE LABELS, via AST
        #     (the switch labels are the tokens; the clause BODIES are prose and are ignored).
        #   clean token   <- Resolve-AnalysisStatus on a settled + available pass: it RETURNS
        #     the clean token's name ('ok'), which is not a banner switch label.
        $libPath = Join-Path $script:ScriptsDir 'lib/lsp-common.ps1'
        $libAst = [System.Management.Automation.Language.Parser]::ParseFile($libPath, [ref]$null, [ref]$null)
        $bannerFn = $libAst.Find({
                param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq 'Get-DiagnosticsStatusBanner' }, $true)
        $switchAst = $bannerFn.Find({
                param($n) $n -is [System.Management.Automation.Language.SwitchStatementAst] }, $true)
        $script:NonOkTokens = @($switchAst.Clauses | ForEach-Object { [string]$_.Item1.Value })
        $script:CleanToken = Resolve-AnalysisStatus -Settled $true -PssaAvailable $true
        $script:BannerTokens = @((@($script:CleanToken) + $script:NonOkTokens) | Select-Object -Unique) | Sort-Object

        # CONTRACT side: the sentinel-delimited FROZEN-STATUS-TOKENS block, parsed the same
        # first-column-backtick way as the knob block.
        $contractPath = Join-Path $script:PluginRoot 'CONTRACT.md'
        $contractText = Get-Content -LiteralPath $contractPath -Raw
        $m = [regex]::Match($contractText, '(?s)FROZEN-STATUS-TOKENS:BEGIN(.*?)FROZEN-STATUS-TOKENS:END')
        $block = if ($m.Success) { $m.Groups[1].Value } else { '' }
        $toks = @()
        foreach ($line in ($block -split "`n")) {
            if ($line -match '^\s*\|\s*`([^`]+)`') { $toks += $Matches[1] }
        }
        $script:ContractTokens = @($toks) | Sort-Object
    }
    It 'extracts a non-empty token set from source (the guard cannot pass vacuously)' {
        $script:BannerTokens.Count | Should -BeGreaterThan 0
        $script:ContractTokens.Count | Should -BeGreaterThan 0
    }
    It 'freezes exactly the tokens the code emits -- none missing, none extra' {
        # Set-equality against the AST-derived + resolver-derived token set. Rename a switch
        # label (e.g. 'degraded' -> 'reduced') or add a clause without updating CONTRACT.md
        # and this goes RED. Adversarial control: edit a FROZEN-STATUS-TOKENS row out of sync
        # with the banner switch and the exact-match assertion goes RED.
        ($script:ContractTokens -join ',') | Should -BeExactly ($script:BannerTokens -join ',')
    }
    It 'every non-ok frozen token yields a distinct, non-empty, visible banner (the frozen property)' {
        $banners = @{}
        foreach ($t in $script:NonOkTokens) {
            $b = Get-DiagnosticsStatusBanner -Status $t -Path 'C:\x\foo.ps1'
            $b | Should -Not -BeNullOrEmpty
            $banners[$t] = $b
        }
        $set = New-Object System.Collections.Generic.HashSet[string]
        foreach ($b in $banners.Values) { [void]$set.Add($b) }
        $set.Count | Should -Be $script:NonOkTokens.Count   # all pairwise-distinct
    }
    It 'the clean token renders an empty banner (the byte-identical warm path)' {
        Get-DiagnosticsStatusBanner -Status $script:CleanToken -Path 'C:\x\foo.ps1' | Should -BeExactly ''
    }
}

Describe 'lspServers manifest declares only registrar-supported fields (dispatch 000075)' {
    # 000069 proved (on Claude Code 2.1.195) that the runtime LSP registrar SILENTLY DROPS
    # any lspServers server entry declaring restartOnCrash or shutdownTimeout. Both fields
    # are accepted by the plugin-manifest JSON schema, so the drop has NO diagnostic -- and
    # either field present means .ps1/.psm1/.psd1 -> powershell is never registered ("No LSP
    # server available for file type: .ps1"). This guard turns that silent registrar drop
    # into a LOUD test failure: every lspServers entry may declare ONLY the registrar-
    # supported allowlist, with the two known breakers named explicitly so a re-add is
    # unambiguous, and a future hostile key is caught by the closed allowlist.
    BeforeAll {
        # Single source of truth for "allowed" -- each field proven to REGISTER by the
        # 000069 probe matrix (GJ/GJT1/GJT4/GJenv/Text register; command+args register).
        $script:LspAllowlist = @(
            'command', 'args', 'extensionToLanguage', 'transport',
            'startupTimeout', 'maxRestarts', 'env'
        )
        # The two fields 000069 isolated as registrar-hostile, named per the dispatch so a
        # regression reads as "a known breaker came back", not a generic unknown key.
        $script:LspKnownBreakers = @('restartOnCrash', 'shutdownTimeout')

        # ONE checker, applied to the real manifest AND the adversarial fixtures below:
        # given a parsed lspServers entry, return the keys OUTSIDE the allowlist. No second
        # copy of the rule to drift; the allowlist is passed in (no closure ambiguity).
        $script:GetRegistrarHostileKeys = {
            param($Entry, $Allowlist)
            @($Entry.PSObject.Properties.Name | Where-Object { $Allowlist -notcontains $_ })
        }

        $manifestPath = Join-Path $script:PluginRoot '.claude-plugin/plugin.json'
        $manifest = (Get-Content -LiteralPath $manifestPath -Raw) | ConvertFrom-Json
        $script:LspServers = $manifest.lspServers
        $script:LspEntryNames = @($script:LspServers.PSObject.Properties.Name)
    }

    It 'has at least one lspServers entry and a non-empty allowlist (no vacuous pass)' {
        $script:LspEntryNames.Count | Should -BeGreaterThan 0
        $script:LspAllowlist.Count | Should -BeGreaterThan 0
    }

    It 'every shipped lspServers entry declares ONLY registrar-supported fields' {
        foreach ($name in $script:LspEntryNames) {
            $entry = $script:LspServers.$name
            $hostile = & $script:GetRegistrarHostileKeys $entry $script:LspAllowlist
            $because = "lspServers.$name declares registrar-hostile field(s): $($hostile -join ', ')"
            ($hostile -join ',') | Should -BeExactly '' -Because $because
        }
    }

    It 'declares NEITHER restartOnCrash NOR shutdownTimeout on any entry (the two breakers)' {
        foreach ($name in $script:LspEntryNames) {
            $keys = @($script:LspServers.$name.PSObject.Properties.Name)
            foreach ($breaker in $script:LspKnownBreakers) {
                $keys | Should -Not -Contain $breaker -Because "CC's registrar silently drops $breaker (000069)"
            }
        }
    }

    It 'the powershell entry still declares the working registrar-supported fields (no over-delete)' {
        $ps = $script:LspServers.powershell
        $ps | Should -Not -BeNullOrEmpty
        $keys = @($ps.PSObject.Properties.Name)
        foreach ($want in $script:LspAllowlist) {
            $keys | Should -Contain $want -Because "the fix removed ONLY the two breakers; $want must remain"
        }
    }

    # Adversarial controls -- the guard MUST go red when a breaker (or any future hostile
    # field) is re-introduced. Synthetic entries, not the manifest: this is what makes a
    # green run on the real manifest meaningful rather than vacuous.
    It 'FLAGS a fixture that re-adds restartOnCrash' {
        $fx = [pscustomobject]@{ command = 'pwsh'; args = @('-File', 'x.ps1'); restartOnCrash = $true }
        @(& $script:GetRegistrarHostileKeys $fx $script:LspAllowlist) | Should -Contain 'restartOnCrash'
    }

    It 'FLAGS a fixture that re-adds shutdownTimeout' {
        $fx = [pscustomobject]@{ command = 'pwsh'; args = @('-File', 'x.ps1'); shutdownTimeout = 5000 }
        @(& $script:GetRegistrarHostileKeys $fx $script:LspAllowlist) | Should -Contain 'shutdownTimeout'
    }

    It 'FLAGS a fixture with a future unknown field outside the allowlist (closed allowlist)' {
        $fx = [pscustomobject]@{ command = 'pwsh'; args = @('-File', 'x.ps1'); someFutureKnob = $true }
        @(& $script:GetRegistrarHostileKeys $fx $script:LspAllowlist) | Should -Contain 'someFutureKnob'
    }

    It 'PASSES a fixture declaring only allowlisted fields (no false positive)' {
        $fx = [pscustomobject]@{
            command             = 'pwsh'
            args                = @('-File', 'x.ps1')
            extensionToLanguage = @{ '.ps1' = 'powershell' }
            transport           = 'stdio'
            startupTimeout      = 30000
            maxRestarts         = 3
            env                 = @{ X = 'y' }
        }
        @(& $script:GetRegistrarHostileKeys $fx $script:LspAllowlist) | Should -BeNullOrEmpty
    }
}

Describe 'License metadata is single-sourced and consistent (dispatch 000029)' {
    # The 000027 docs-honesty / single-source discipline applied to the LICENSE: the SPDX id has ONE
    # source of truth -- plugin.json's `license` (the same manifest the version stamp reads, 000025) --
    # and the other declaration sites must agree. The LICENSE body is the Apache-2.0 text the SPDX id
    # names, and the README declares the same id. marketplace.json carries NO license field (the Claude
    # Code marketplace schema has none; an added value is silently ignored), so its ABSENCE is asserted
    # rather than letting a misleading/ignored declaration drift in. Adversarial control: change the
    # README SPDX id (or plugin.json's license) out of sync and the consistency assertions go RED.
    #
    # Dispatch 000247 relicensed the project FORWARD from GPL-3.0-or-later to Apache-2.0 (ruled by Mike
    # 2026-08-16). The id and body assertions moved with it -- this block is the drift-guard that makes
    # the lockstep enforceable rather than a promise. NOTICE is asserted here too: under Apache-2.0 it
    # is part of the license surface (section 4(d) requires redistributors to carry it), not an
    # optional courtesy file, so its ABSENCE would be a licensing defect and not merely a missing doc.
    BeforeAll {
        $script:Lic_Root        = Split-Path -Parent $PSScriptRoot
        $script:Lic_Manifest    = (Get-Content -LiteralPath (Join-Path $script:Lic_Root '.claude-plugin/plugin.json') -Raw | ConvertFrom-Json)
        $script:Lic_Spdx        = [string]$script:Lic_Manifest.license
        $script:Lic_LicenseText = Get-Content -LiteralPath (Join-Path $script:Lic_Root 'LICENSE') -Raw
        $script:Lic_Readme      = Get-Content -LiteralPath (Join-Path $script:Lic_Root 'README.md') -Raw
        $script:Lic_Market      = (Get-Content -LiteralPath (Join-Path $script:Lic_Root '.claude-plugin/marketplace.json') -Raw | ConvertFrom-Json)
        $script:Lic_NoticePath  = Join-Path $script:Lic_Root 'NOTICE'
    }
    It 'plugin.json declares a non-empty SPDX license -- the single source of truth' {
        $script:Lic_Spdx | Should -Not -BeNullOrEmpty
        $script:Lic_Spdx | Should -BeExactly 'Apache-2.0'
    }
    It 'LICENSE is the Apache-2.0 body the SPDX id names' {
        $script:Lic_Spdx | Should -BeExactly 'Apache-2.0'
        $script:Lic_LicenseText | Should -Match 'Apache License'
        $script:Lic_LicenseText | Should -Match 'Version 2\.0, January 2004'
        # The outgoing body must be GONE, not merely joined by the new one -- a LICENSE holding both
        # would satisfy every positive assertion above while declaring two incompatible licenses.
        $script:Lic_LicenseText | Should -Not -Match 'GNU GENERAL PUBLIC LICENSE'
    }
    It 'NOTICE exists and names the project and the copyright holder (Apache-2.0 section 4(d))' {
        Test-Path -LiteralPath $script:Lic_NoticePath -PathType Leaf | Should -BeTrue
        $notice = Get-Content -LiteralPath $script:Lic_NoticePath -Raw
        $notice | Should -Match 'powershell-lsp'
        $notice | Should -Match 'Mike Andersen'
        $notice | Should -Match 'Apache License, Version 2\.0'
    }
    It 'README declares the SAME SPDX id as plugin.json (no drift)' {
        $script:Lic_Readme | Should -Match ([regex]::Escape($script:Lic_Spdx))
    }
    It 'marketplace.json carries NO license field (license lives in plugin.json; the marketplace schema has none)' {
        ($script:Lic_Market.PSObject.Properties.Name -contains 'license') | Should -BeFalse
        foreach ($p in @($script:Lic_Market.plugins)) {
            ($p.PSObject.Properties.Name -contains 'license') | Should -BeFalse
        }
    }
    It 'THIRD-PARTY-LICENSES.md documents both downloaded MIT deps' {
        $tp = Get-Content -LiteralPath (Join-Path $script:Lic_Root 'THIRD-PARTY-LICENSES.md') -Raw
        $tp | Should -Match 'PowerShell Editor Services'
        $tp | Should -Match 'PSScriptAnalyzer'
        $tp | Should -Match 'MIT'
    }
}

# ===========================================================================
# Preflight doctor -- per-check status decisions (dispatch 000036)
# ===========================================================================
# The doctor (scripts/doctor.ps1) is REPORT-ONLY: each check is a pure function over
# already-resolved probe inputs returning a status object, so the decision logic is
# unit-testable WITHOUT a live PSES install or network. These guards assert pass / fail /
# unknown per check with the probes injected. Dot-sourcing doctor.ps1 loads the functions
# without running the live checks (the entry-point guard skips on InvocationName '.').
# The live probes (Get-DoctorPwsh, Test-DoctorHostReachableProbe, ...) are exercised by
# the end-to-end run captured in the dispatch outbox, not here.

Describe 'Preflight doctor -- per-check status decisions (dispatch 000036)' {
    BeforeAll {
        . (Join-Path $script:ScriptsDir 'doctor.ps1')
    }

    Context 'New-DoctorResult -- the status-object shape and frozen vocabulary' {
        It 'carries Status / Component / Detail / Remediation' {
            $r = New-DoctorResult -Status pass -Component 'X' -Detail 'd'
            $r.Status | Should -Be 'pass'
            $r.Component | Should -Be 'X'
            $r.PSObject.Properties.Name | Should -Contain 'Remediation'
        }
        It 'rejects a status outside pass/fail/unknown (the inbox rule: no invented status words)' {
            # Adversarial control: widen or drop the ValidateSet and an invented token stops
            # throwing, so this assertion goes RED -- the vocabulary guard has teeth.
            { New-DoctorResult -Status 'broken' -Component 'X' } | Should -Throw
        }
    }

    Context 'Test-DoctorPwsh -- check 1: PowerShell 7 host' {
        It 'PASS when pwsh 7+ is present' {
            (Test-DoctorPwsh -Found $true -Version ([version]'7.4.2')).Status | Should -Be 'pass'
        }
        It 'FAIL when pwsh is absent (the hooks cannot launch)' {
            $r = Test-DoctorPwsh -Found $false -Version $null
            $r.Status | Should -Be 'fail'
            $r.Remediation | Should -Match 'winget install Microsoft.PowerShell'
        }
        It 'FAIL when pwsh is present but older than 7' {
            # Adversarial control: drop the Major -lt 7 branch and the 5.1 case flips
            # fail -> pass, going RED. (Resolve-PsHost accepts 5.1 as a host; the hooks do not.)
            (Test-DoctorPwsh -Found $true -Version ([version]'5.1.19041')).Status | Should -Be 'fail'
        }
        It 'UNKNOWN when pwsh is present but its version is undeterminable (honest, not a fabricated fail)' {
            (Test-DoctorPwsh -Found $true -Version $null).Status | Should -Be 'unknown'
        }
    }

    Context 'Test-DoctorEnabled -- check 2: plugin enablement' {
        It 'PASS when the plugin subprocess environment is present' {
            (Test-DoctorEnabled -PluginRootResolved $true).Status | Should -Be 'pass'
        }
        It 'UNKNOWN (never a fabricated fail) when enablement cannot be observed' {
            # Adversarial control: return 'fail' from the not-observed branch and this goes RED.
            # Absence of the plugin env does NOT prove the plugin is disabled.
            $r = Test-DoctorEnabled -PluginRootResolved $false
            $r.Status | Should -Be 'unknown'
            $r.Remediation | Should -Match '/plugin enable powershell-lsp'
        }
    }

    Context 'Test-DoctorPses -- check 3: PSES bundle bootstrapped' {
        It 'PASS only when BOTH the pinned marker and Start-EditorServices.ps1 are present' {
            (Test-DoctorPses -DataRootKnown $true -MarkerPresent $true -StartScriptPresent $true -PinTag 'v4.6.0').Status | Should -Be 'pass'
        }
        It 'FAIL when Start-EditorServices.ps1 is missing (bundle did not finish)' {
            $r = Test-DoctorPses -DataRootKnown $true -MarkerPresent $true -StartScriptPresent $false -PinTag 'v4.6.0'
            $r.Status | Should -Be 'fail'
            $r.Detail | Should -Match 'Start-EditorServices\.ps1'
        }
        It 'FAIL when the marker is missing even though the start script exists' {
            # Adversarial control: require only ONE of the two and this case flips to pass -> RED.
            (Test-DoctorPses -DataRootKnown $true -MarkerPresent $false -StartScriptPresent $true -PinTag 'v4.6.0').Status | Should -Be 'fail'
        }
        It 'UNKNOWN when the data root cannot be located (no false "not installed")' {
            # Adversarial control: treat an unknown data root as fail and this goes RED -- the
            # standalone invocation would then slander a healthy install as broken.
            (Test-DoctorPses -DataRootKnown $false -MarkerPresent $false -StartScriptPresent $false).Status | Should -Be 'unknown'
        }
    }

    Context 'Test-DoctorPssa -- check 4: PSScriptAnalyzer vendored + importable' {
        It 'PASS when the marker is present and the module imports' {
            (Test-DoctorPssa -DataRootKnown $true -MarkerPresent $true -Importable $true -PinVersion '1.25.0').Status | Should -Be 'pass'
        }
        It 'FAIL (degraded) when vendored but not importable' {
            $r = Test-DoctorPssa -DataRootKnown $true -MarkerPresent $true -Importable $false -PinVersion '1.25.0'
            $r.Status | Should -Be 'fail'
            $r.Detail | Should -Match 'degraded'
        }
        It 'FAIL when the vendor marker is missing' {
            (Test-DoctorPssa -DataRootKnown $true -MarkerPresent $false -Importable $false -PinVersion '1.25.0').Status | Should -Be 'fail'
        }
        It 'UNKNOWN when the data root cannot be located' {
            (Test-DoctorPssa -DataRootKnown $false -MarkerPresent $false -Importable $false).Status | Should -Be 'unknown'
        }
    }

    Context 'Test-DoctorHosts -- check 5: first-run download hosts reachable' {
        It 'PASS when all hosts are reachable' {
            $probes = @(
                [pscustomobject]@{ Host = 'github.com'; Reachable = $true }
                [pscustomobject]@{ Host = 'www.powershellgallery.com'; Reachable = $true }
            )
            (Test-DoctorHosts -HostProbes $probes).Status | Should -Be 'pass'
        }
        It 'FAIL (naming the host) when any host is unreachable' {
            # Adversarial control: collapse the $false branch into unknown and this fail -> unknown
            # flip goes RED -- a definite "could not reach" must read as a failure, not a maybe.
            $probes = @(
                [pscustomobject]@{ Host = 'github.com'; Reachable = $true }
                [pscustomobject]@{ Host = 'www.powershellgallery.com'; Reachable = $false }
            )
            $r = Test-DoctorHosts -HostProbes $probes
            $r.Status | Should -Be 'fail'
            $r.Detail | Should -Match 'www\.powershellgallery\.com'
        }
        It 'UNKNOWN when a probe could not run and none definitely failed' {
            $probes = @(
                [pscustomobject]@{ Host = 'github.com'; Reachable = $true }
                [pscustomobject]@{ Host = 'www.powershellgallery.com'; Reachable = $null }
            )
            (Test-DoctorHosts -HostProbes $probes).Status | Should -Be 'unknown'
        }
    }

    Context 'Format-DoctorReport -- the generic security pointer (boundary: dispatch 000036)' {
        It 'omits the security pointer when every check passed' {
            $clean = @(New-DoctorResult -Status pass -Component 'A' -Detail 'ok')
            (Format-DoctorReport -Results $clean) | Should -Not -Match 'security control'
        }
        It 'appends a single GENERIC security pointer when a check did not pass -- no control names' {
            # The doctor does not probe security controls (WDAC/AppLocker/ExecutionPolicy/CLM/SAC);
            # it may only point. Adversarial control: name a specific control here and the
            # "no control names" assertion goes RED.
            $dirty = @(
                New-DoctorResult -Status pass -Component 'A' -Detail 'ok'
                New-DoctorResult -Status fail -Component 'B' -Detail 'bad' -Remediation 'do x'
            )
            $report = Format-DoctorReport -Results $dirty
            $report | Should -Match 'security control'
            $report | Should -Not -Match 'WDAC|AppLocker|ExecutionPolicy|Constrained Language|Smart App Control'
        }
    }
}

# ===========================================================================
# Preflight doctor -- daemon/pipe health (dispatch 000037)
# ===========================================================================
# Check 6 (Test-DoctorDaemon) is the RUNTIME bookend to check 3: checks 1-5 confirm the
# bundle is INSTALLED; this confirms the warm per-session daemon is ACTUALLY ALIVE and
# answering on its named pipe. Like the 000036 checks it is a PURE decision over
# already-resolved observations (Get-DoctorDaemonObservation does the discovery + the
# non-disruptive 'ping' round-trip live), so the four-state mapping is asserted here with
# the daemon/pipe state injected -- no live daemon, no pipe. The mapping must stay HONEST
# about the 000028 pipe-first + 000030 auto-relaunch semantics: an absent daemon
# auto-relaunches on the next edit (benign), so it must NOT read as a FAIL.

Describe 'Preflight doctor -- daemon/pipe health (dispatch 000037)' {
    BeforeAll {
        . (Join-Path $script:ScriptsDir 'doctor.ps1')
    }

    Context 'Test-DoctorDaemon -- check 6: warm daemon runtime health' {
        It 'PASS when a daemon is alive and answered its pipe (the round-trip succeeded)' {
            $r = Test-DoctorDaemon -DataRootKnown $true -Determinable $true -DaemonPresent $true -State 'ready' -Reachable $true
            $r.Status | Should -Be 'pass'
            $r.Detail | Should -Match 'answered on its named pipe'
        }
        It 'PASS (still benign) when the daemon answers but PSES is still starting' {
            $r = Test-DoctorDaemon -DataRootKnown $true -Determinable $true -DaemonPresent $true -State 'starting' -Reachable $true
            $r.Status | Should -Be 'pass'
            $r.Detail | Should -Match 'still initializing'
        }
        It 'FAIL (parked unavailable) names the genuine problem and the restart remedy' {
            # Adversarial control: this is the 000030 PERMANENT case (a daemon ALIVE and reachable
            # but parked unavailable). It must FAIL even though the pipe answers -- so the State
            # check MUST precede the Reachable check. Reorder them and this fail -> pass, going RED.
            $r = Test-DoctorDaemon -DataRootKnown $true -Determinable $true -DaemonPresent $true -State 'unavailable' -Reachable $true
            $r.Status | Should -Be 'fail'
            $r.Detail | Should -Match 'unavailable'
            $r.Remediation | Should -Match 'fresh Claude Code session'
        }
        It 'FAIL (degraded) when the daemon is alive but its analyzer re-spawn budget is exhausted' {
            $r = Test-DoctorDaemon -DataRootKnown $true -Determinable $true -DaemonPresent $true -State 'degraded' -Reachable $true
            $r.Status | Should -Be 'fail'
            $r.Detail | Should -Match 'degraded'
        }
        It 'FAIL (wedged) when the daemon process is alive but the pipe did NOT answer' {
            # Adversarial control: pipe-first means a healthy daemon ALWAYS holds its pipe open, so
            # alive-but-silent is a real fault. Collapse this into the benign-absent branch and the
            # fail -> pass flip goes RED -- a wedged daemon must not read as "nothing to fix."
            $r = Test-DoctorDaemon -DataRootKnown $true -Determinable $true -DaemonPresent $true -State 'ready' -Reachable $false
            $r.Status | Should -Be 'fail'
            $r.Detail | Should -Match 'did not answer'
        }
        It 'PASS (benign, never FAIL) when no daemon is present -- it auto-relaunches on the next edit' {
            # Adversarial control: the 000030 recoverable case. A $null/absent daemon is benign (one
            # auto-relaunches on the next edit). Return fail from this branch and BOTH assertions go
            # RED -- a benign self-healing state must never be reported as a scary failure.
            $r = Test-DoctorDaemon -DataRootKnown $true -Determinable $true -DaemonPresent $false
            $r.Status | Should -Be 'pass'
            $r.Status | Should -Not -Be 'fail'
            $r.Detail | Should -Match 'auto-relaunches'
        }
        It 'UNKNOWN (no session context) when the data root cannot be located' {
            # Adversarial control: treat an unknown data root as fail/pass and this goes RED -- a
            # standalone run cannot see the daemon, so the honest answer is UNKNOWN, never a verdict.
            $r = Test-DoctorDaemon -DataRootKnown $false -Determinable $false -DaemonPresent $false
            $r.Status | Should -Be 'unknown'
            # The remedy must NAME the missing input and give an executable instruction.
            $r.Remediation | Should -Match 'CLAUDE_PLUGIN_DATA is unset'
            $r.Remediation | Should -Match 'Set it to the plugin data directory'
            # REGRESSION GUARD for D3 (dispatch 000265). The old remedy read "Run this doctor
            # from inside a Claude Code session (where CLAUDE_PLUGIN_DATA is set)". A tool shell
            # inside a live, plugin-enabled session carries NEITHER CLAUDE_PLUGIN_DATA nor
            # CLAUDE_PLUGIN_ROOT, so that sentence returned the user to the state that produced
            # the message. Asserting its ABSENCE is what stops it being reinstated as a "fix".
            $r.Remediation | Should -Not -Match 'Run this doctor from inside a Claude Code session'
        }
        It 'UNKNOWN (ambiguous) when several daemons are live and no session id disambiguates' {
            # Adversarial control: guessing one of N live daemons would be a misleading PASS/FAIL.
            # The honest answer is UNKNOWN, naming the count and the -SessionId way to scope it.
            $r = Test-DoctorDaemon -DataRootKnown $true -Determinable $false -DaemonPresent $true -LiveCount 2
            $r.Status | Should -Be 'unknown'
            $r.Detail | Should -Match '2 live daemons'
            $r.Remediation | Should -Match 'SessionId'
        }
        It 'keeps its status inside the frozen pass/fail/unknown vocabulary (no invented token)' {
            foreach ($s in @(
                    (Test-DoctorDaemon -DataRootKnown $true -Determinable $true -DaemonPresent $true -State 'ready' -Reachable $true),
                    (Test-DoctorDaemon -DataRootKnown $true -Determinable $true -DaemonPresent $true -State 'unavailable' -Reachable $true),
                    (Test-DoctorDaemon -DataRootKnown $true -Determinable $true -DaemonPresent $false),
                    (Test-DoctorDaemon -DataRootKnown $false -Determinable $false -DaemonPresent $false)
                )) {
                $s.Status | Should -BeIn @('pass', 'fail', 'unknown')
            }
        }
    }
}

# ===========================================================================
# Preflight doctor -- native-serve removability (check 7, dispatch 000104)
# ===========================================================================
# The 000103 OQ4 probe, as a PURE decision over the removability observation
# Get-DoctorNativeServeObservation resolves live (it drives the DIRECT launcher via a pwsh
# subprocess and reads back InitReceived / InitHasStaticNav). The mapping is asserted here with
# the observation INJECTED -- no live PSES, no process. Two invariants are load-bearing: (1) the
# gated-today case (init received, nav NOT static) is a PASS, never a FAIL -- a removability
# diagnostic must NOT move the doctor's exit code; (2) the vocabulary stays the frozen
# pass/fail/unknown. The end-to-end drive (real PSES over the direct launcher) is a separate
# serialized e2e (PowerShellLsp.NativeServeProbe.Tests.ps1), per the 000101 one-server lesson.

Describe 'Preflight doctor -- native-serve removability (check 7, dispatch 000104)' {
    BeforeAll {
        . (Join-Path $script:ScriptsDir 'doctor.ps1')
    }

    Context 'Test-DoctorNativeServe -- check 7: is the nativeServe shim removable yet?' {
        It 'PASS "still gated" when init is received but nav is NOT advertised statically (today)' {
            # The load-bearing today case: PSES defers nav to the client/registerCapability handshake
            # the #1359 client bug breaks, so the init result carries no static nav -> the shim is
            # still needed. This is EXPECTED, so it must be a PASS.
            $r = Test-DoctorNativeServe -Determinable $true -InitReceived $true -HasStaticNav $false -ElapsedMs 1200 -TimeoutMs 20000
            $r.Status | Should -Be 'pass'
            $r.Detail | Should -Match 'still GATED'
            $r.Detail | Should -Match 'shim remains needed'
        }
        It 'PASS "still gated" is NEVER a fail -- a removability diagnostic must not move the exit code' {
            # Adversarial control: flip the gated branch to fail and the doctor would exit 1 on the
            # normal, expected state (the shim correctly still needed). That is the regression this
            # guards -- the probe reports, it never fails the run.
            (Test-DoctorNativeServe -Determinable $true -InitReceived $true -HasStaticNav $false).Status | Should -Not -Be 'fail'
        }
        It 'PASS "removable" when init is received and nav IS advertised statically' {
            # The flip the probe exists to catch: native serve completes statically, so the shim can
            # be removed. Adversarial control: collapse this into the gated branch and the removable
            # message never fires.
            $r = Test-DoctorNativeServe -Determinable $true -InitReceived $true -HasStaticNav $true -ElapsedMs 900 -TimeoutMs 20000
            $r.Status | Should -Be 'pass'
            $r.Detail | Should -Match 'can be REMOVED'
        }
        It 'UNKNOWN (not determinable) surfaces the honest reason and how to enable the probe' {
            # Adversarial control: a context where PSES cannot be launched is UNKNOWN, never a
            # verdict; the reason and the -ProbeNativeServe re-run path must be carried.
            $r = Test-DoctorNativeServe -Determinable $false -Reason 'the PSES bundle is not bootstrapped, so the direct launcher cannot start (see the PSES bundle check).'
            $r.Status | Should -Be 'unknown'
            $r.Detail | Should -Match 'not bootstrapped'
            $r.Remediation | Should -Match 'ProbeNativeServe'
        }
        It 'UNKNOWN when the direct launcher returned no initialize result within the bound' {
            # Determinable but PSES did not init in time (or crashed): indeterminate, never a false
            # "still gated". The bound (seconds) and any probe error are surfaced.
            $r = Test-DoctorNativeServe -Determinable $true -InitReceived $false -ProbeError 'the probe produced no result' -TimeoutMs 20000
            $r.Status | Should -Be 'unknown'
            $r.Detail | Should -Match 'did not return an initialize result'
            $r.Detail | Should -Match '20 s'
        }
        It 'keeps its status inside the frozen pass/fail/unknown vocabulary (no invented token)' {
            foreach ($s in @(
                    (Test-DoctorNativeServe -Determinable $true -InitReceived $true -HasStaticNav $false),
                    (Test-DoctorNativeServe -Determinable $true -InitReceived $true -HasStaticNav $true),
                    (Test-DoctorNativeServe -Determinable $true -InitReceived $false),
                    (Test-DoctorNativeServe -Determinable $false -Reason 'x')
                )) {
                $s.Status | Should -BeIn @('pass', 'fail', 'unknown')
            }
        }
        It 'NEVER returns fail on any input combination (report-only invariant)' {
            foreach ($s in @(
                    (Test-DoctorNativeServe -Determinable $true -InitReceived $true -HasStaticNav $false),
                    (Test-DoctorNativeServe -Determinable $true -InitReceived $true -HasStaticNav $true),
                    (Test-DoctorNativeServe -Determinable $true -InitReceived $false),
                    (Test-DoctorNativeServe -Determinable $false -Reason 'x')
                )) {
                $s.Status | Should -Not -Be 'fail'
            }
        }
    }
}

# ===========================================================================
# Preflight doctor -- the 000166 B9 reshape: items 6, 8, and the item-7 promotion
# ===========================================================================
# Three checks closing the gaps the 000165 S3 survey measured against the reviewer's
# eight-point checklist. Same discipline as the blocks above: the decision half is a PURE
# function over injected observations, asserted here; the live probes
# (Get-DoctorRulesetObservation, Get-DoctorTestDiagnosticObservation) are exercised by the
# end-to-end run recorded in the dispatch outbox, which proved BOTH directions -- honest
# UNKNOWN with no data dir, and a real PSUseApprovedVerbs observed through a live daemon.
#
# THE EXIT-CODE CONTRACT IS THE THING TO PROTECT. `unknown` is never `fail`, so a doctor run
# that could not determine something must not change a caller's exit code. Every
# could-not-determine path below is asserted `unknown` explicitly, and the ONE deliberate
# `fail` (a settled analysis that produced nothing) is asserted to be the ONLY one.

Describe 'Preflight doctor -- active ruleset surface (item 6, dispatch 000166)' {
    BeforeAll { . (Join-Path $script:ScriptsDir 'doctor.ps1') }

    It 'is UNKNOWN, never fail, when the resolver could not be consulted' {
        $r = Test-DoctorRuleset -Determinable $false -Reason 'no plugin root.'
        $r.Status | Should -Be 'unknown'
        $r.Detail | Should -Match 'no plugin root'
    }
    It 'is UNKNOWN when ruleset=base is requested but the shipped ruleset is unresolvable' {
        # The honest half of both-directions: base was ASKED for and silently degraded to the
        # NARROWER PSES set. Reporting that as a pass reading "PSES built-in" would be
        # indistinguishable from a user who chose pses-default -- the misreport this guards.
        $r = Test-DoctorRuleset -Determinable $true -RulesetKnob 'base' -ResolvedPath '' -Source 'unresolved-base' -ProbeDir 'C:\proj'
        $r.Status | Should -Be 'unknown'
        $r.Detail | Should -Match 'NARROWER'
        $r.Remediation | Should -Not -BeNullOrEmpty
    }
    It 'PASSES and names the shipped base ruleset when base resolved' {
        $r = Test-DoctorRuleset -Determinable $true -RulesetKnob 'base' -ResolvedPath 'C:\plugin\rulesets\base.psd1' -Source 'plugin-base' -ProbeDir 'C:\proj'
        $r.Status | Should -Be 'pass'
        $r.Detail | Should -Match 'shipped base ruleset is active'
        $r.Detail | Should -Match ([regex]::Escape('C:\plugin\rulesets\base.psd1'))
    }
    It 'PASSES and says the repo-local file WINS, naming the knob as inert' {
        # The silent-precedence case the check exists for: a user sets ruleset=base, still sees
        # nothing new, and had no way to learn a repo-local file was legitimately winning.
        $r = Test-DoctorRuleset -Determinable $true -RulesetKnob 'base' -ResolvedPath 'C:\proj\PSScriptAnalyzerSettings.psd1' -Source 'repo-local' -ProbeDir 'C:\proj'
        $r.Status | Should -Be 'pass'
        $r.Detail | Should -Match 'repo-local'
        $r.Detail | Should -Match 'inert'
        $r.Detail | Should -Match 'not a fault'
    }
    It 'PASSES and says an explicit settingsPath override wins over both' {
        $r = Test-DoctorRuleset -Determinable $true -RulesetKnob 'base' -ResolvedPath 'C:\org\settings.psd1' -Source 'override' -ProbeDir 'C:\proj'
        $r.Status | Should -Be 'pass'
        $r.Detail | Should -Match 'settingsPath override'
    }
    It 'PASSES and names the PSES built-in set (with the WriteHost caveat) on the default' {
        $r = Test-DoctorRuleset -Determinable $true -RulesetKnob 'pses-default' -ResolvedPath '' -Source 'pses-default' -ProbeDir 'C:\proj'
        $r.Status | Should -Be 'pass'
        $r.Detail | Should -Match 'built-in no-settings rule set'
        $r.Detail | Should -Match 'PSAvoidUsingWriteHost is NOT among them'
    }
    It 'NEVER returns fail on any input shape (a configuration report is not a health gate)' {
        foreach ($src in @('override', 'repo-local', 'plugin-base', 'pses-default', 'unresolved-base', '')) {
            (Test-DoctorRuleset -Determinable $true -RulesetKnob 'base' -ResolvedPath 'x' -Source $src).Status | Should -Not -Be 'fail'
        }
        (Test-DoctorRuleset -Determinable $false).Status | Should -Not -Be 'fail'
    }
}

Describe 'Preflight doctor -- org policy exclusions (000203 survey C2, failure class F12)' {
    BeforeAll { . (Join-Path $script:ScriptsDir 'doctor.ps1') }

    It 'is UNKNOWN, never fail, when the knob values could not be resolved' {
        $r = Test-DoctorOrgPolicy -Determinable $false -Reason 'no plugin root.'
        $r.Status | Should -Be 'unknown'
        $r.Detail | Should -Match 'no plugin root'
    }
    It 'PASSES and says the knob is unset, naming it an opt-in rather than a fault' {
        $r = Test-DoctorOrgPolicy -Determinable $true -KnobSet $false
        $r.Status | Should -Be 'pass'
        $r.Detail | Should -Match 'orgPolicy is not set'
        $r.Detail | Should -Match 'opt-in'
    }
    It 'PASSES and names the path AND the count when the policy is enforcing' {
        $r = Test-DoctorOrgPolicy -Determinable $true -KnobSet $true `
            -PolicyPath 'C:\org\policy.psd1' -ExcludeCount 3
        $r.Status | Should -Be 'pass'
        $r.Detail | Should -Match ([regex]::Escape('C:\org\policy.psd1'))
        $r.Detail | Should -Match 'enforcing 3 excluded rules'
    }
    It 'pluralizes a single excluded rule correctly' {
        # Not cosmetic: the count is the whole payload of this line, so "1 excluded rules"
        # is the kind of wrongness that makes a reader doubt the number itself.
        $r = Test-DoctorOrgPolicy -Determinable $true -KnobSet $true -PolicyPath 'p' -ExcludeCount 1
        $r.Detail | Should -Match 'enforcing 1 excluded rule\.'
    }
    It 'PASSES and calls a zero-exclusion policy a valid no-op, NOT a degrade' {
        # The distinction this check exists to make. Import-OrgPolicyExcludes returns @() for a
        # readable policy declaring nothing AND for every failure; only the warning separates
        # them, so a check that read the count alone would report a broken policy as a clean one.
        $r = Test-DoctorOrgPolicy -Determinable $true -KnobSet $true `
            -PolicyPath 'C:\org\empty.psd1' -ExcludeCount 0
        $r.Status | Should -Be 'pass'
        $r.Detail | Should -Match 'valid no-op policy, not a degrade'
        $r.Detail | Should -Not -Match 'NOT being applied'
    }
    It 'is UNKNOWN and quotes the degrade reason VERBATIM when the policy did not apply' {
        # F12 itself: the exclusions stopped applying and the only record was the client log.
        $reason = 'orgPolicy file not found; no org exclusions applied: C:\org\gone.psd1'
        $r = Test-DoctorOrgPolicy -Determinable $true -KnobSet $true `
            -PolicyPath 'C:\org\gone.psd1' -ExcludeCount 0 -DegradeReason $reason
        $r.Status | Should -Be 'unknown'
        $r.Detail | Should -Match ([regex]::Escape($reason))
        $r.Detail | Should -Match 'NOT being applied'
        $r.Remediation | Should -Not -BeNullOrEmpty
    }
    It 'reports a degrade as a degrade even when rule codes were read before it' {
        # The reader can set a warning and still return codes; the warning WINS, because a
        # partially-applied policy is not an applied policy.
        $r = Test-DoctorOrgPolicy -Determinable $true -KnobSet $true -PolicyPath 'p' `
            -ExcludeCount 2 `
            -DegradeReason 'orgPolicy could not be read; no org exclusions applied: boom'
        $r.Status | Should -Be 'unknown'
        $r.Detail | Should -Match 'boom'
    }
    It 'NEVER returns fail on any input shape (fail-open is the design, not a fault)' {
        foreach ($n in @(0, 1, 5)) {
            foreach ($d in @('', 'some degrade reason')) {
                (Test-DoctorOrgPolicy -Determinable $true -KnobSet $true -PolicyPath 'p' `
                        -ExcludeCount $n -DegradeReason $d).Status | Should -Not -Be 'fail'
            }
        }
        (Test-DoctorOrgPolicy -Determinable $true -KnobSet $false).Status | Should -Not -Be 'fail'
        (Test-DoctorOrgPolicy -Determinable $false).Status | Should -Not -Be 'fail'
    }
}

Describe 'Preflight doctor -- org policy observation reads through the SHIPPED reader' {
    # The observation half. It is testable without a session because the knob is read from the
    # environment and the reader is a pure file read -- so both directions are reachable here:
    # a real policy file that parses, and a missing one that degrades.
    BeforeAll { . (Join-Path $script:ScriptsDir 'doctor.ps1') }

    AfterEach {
        Remove-Item Env:\CLAUDE_PLUGIN_OPTION_ORGPOLICY -ErrorAction SilentlyContinue
    }

    It 'reports KnobSet=false with no degrade when orgPolicy is unset' {
        Remove-Item Env:\CLAUDE_PLUGIN_OPTION_ORGPOLICY -ErrorAction SilentlyContinue
        $o = Get-DoctorOrgPolicyObservation
        $o.Determinable | Should -BeTrue
        $o.KnobSet | Should -BeFalse
        $o.DegradeReason | Should -BeNullOrEmpty
    }
    It 'lifts the real ExcludeRules count out of a real .psd1' {
        $f = Join-Path $TestDrive 'org-policy.psd1'
        Set-Content -LiteralPath $f -Encoding ascii `
            -Value "@{ ExcludeRules = @('PSAvoidUsingWriteHost','PSUseApprovedVerbs') }"
        $env:CLAUDE_PLUGIN_OPTION_ORGPOLICY = $f
        $o = Get-DoctorOrgPolicyObservation
        $o.KnobSet | Should -BeTrue
        $o.ExcludeCount | Should -Be 2
        $o.DegradeReason | Should -BeNullOrEmpty
    }
    It 'counts a ONE-rule policy as 1, not as $null (the 5.1 scalar .Count trap)' {
        # Windows PowerShell 5.1 unrolls a one-element return to a scalar, whose .Count is
        # $null -- which would silently report a one-rule policy as an empty one.
        $f = Join-Path $TestDrive 'org-policy-one.psd1'
        Set-Content -LiteralPath $f -Encoding ascii `
            -Value "@{ ExcludeRules = @('PSAvoidUsingWriteHost') }"
        $env:CLAUDE_PLUGIN_OPTION_ORGPOLICY = $f
        $o = Get-DoctorOrgPolicyObservation
        $o.ExcludeCount | Should -Be 1
    }
    It 'surfaces the shipped reader OWN degrade text for a missing file' {
        $missing = Join-Path $TestDrive 'no-such-policy.psd1'
        $env:CLAUDE_PLUGIN_OPTION_ORGPOLICY = $missing
        $o = Get-DoctorOrgPolicyObservation
        $o.KnobSet | Should -BeTrue
        $o.DegradeReason | Should -Match 'orgPolicy file not found'
        $o.ExcludeCount | Should -Be 0
    }
    It 'surfaces the shipped reader degrade text for a RELATIVE path' {
        $env:CLAUDE_PLUGIN_OPTION_ORGPOLICY = 'relative\policy.psd1'
        $o = Get-DoctorOrgPolicyObservation
        $o.DegradeReason | Should -Match 'not absolute'
    }
}

Describe 'Preflight doctor -- PSES child host resolution (000203 survey F11, dispatch 000208)' {
    BeforeAll { . (Join-Path $script:ScriptsDir 'doctor.ps1') }

    It 'is UNKNOWN, never fail, when the knob value could not be read' {
        $r = Test-DoctorPsHost -Determinable $false -Reason 'no plugin root.'
        $r.Status | Should -Be 'unknown'
        $r.Detail | Should -Match 'no plugin root'
    }
    It 'is UNKNOWN at the default, deferring to the pwsh check rather than deciding it twice' {
        # The contracted default branch: ps_host unset (or explicitly 'pwsh') has nothing of its
        # own to say, and a second opinion about pwsh could disagree with check 1.
        $r = Test-DoctorPsHost -Determinable $true -Value 'pwsh' -IsDefault $true -Found $true
        $r.Status | Should -Be 'unknown'
        $r.Detail | Should -Match 'at its default'
        $r.Detail | Should -Match 'DISTINCT value from the hook interpreter'
    }
    It 'stays UNKNOWN at the default EVEN IF the executable did not resolve' {
        # Guards the deferral itself: at the default this check must not start failing on
        # pwsh's behalf, or a missing pwsh would be reported as two separate faults.
        $r = Test-DoctorPsHost -Determinable $true -Value 'pwsh' -IsDefault $true -Found $false
        $r.Status | Should -Be 'unknown'
    }
    It 'PASSES and names the resolved path when a non-default host resolves' {
        $r = Test-DoctorPsHost -Determinable $true -Value 'powershell' -IsDefault $false `
            -Found $true -ResolvedPath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        $r.Status | Should -Be 'pass'
        $r.Detail | Should -Match 'ps_host = "powershell" resolves on PATH'
        $r.Detail | Should -Match ([regex]::Escape('C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'))
    }
    It 'FAILS -- the fail-capable branch -- when a non-default host does NOT resolve' {
        # F11 itself. This is the one added check that can move the exit code, and it earns that
        # because Resolve-PsHost SUBSTITUTES rather than errors: the detail must say so, or the
        # user reads "not found" and assumes nothing is running.
        $r = Test-DoctorPsHost -Determinable $true -Value 'pwsh-7-preview' -IsDefault $false -Found $false
        $r.Status | Should -Be 'fail'
        $r.Detail | Should -Match 'does NOT resolve on PATH'
        $r.Detail | Should -Match 'falls back to pwsh'
        $r.Remediation | Should -Not -BeNullOrEmpty
    }
    It 'the non-resolving NON-DEFAULT case is the ONLY fail across every input shape' {
        # RED control for the fail-capable claim, in both directions at once: it pins that the
        # FAIL branch really fails (a regression making it UNKNOWN drops the count to 0) AND
        # that no other shape fails (a regression failing the default branch raises it to 2).
        # A bare "it fails" assertion would survive the first of those; this does not.
        $shapes = @(
            @{ D = $false; V = '';        Def = $false; F = $false }
            @{ D = $true;  V = 'pwsh';    Def = $true;  F = $true  }
            @{ D = $true;  V = 'pwsh';    Def = $true;  F = $false }
            @{ D = $true;  V = 'nope';    Def = $false; F = $true  }
            @{ D = $true;  V = 'nope';    Def = $false; F = $false }   # <- the only fail
        )
        $statuses = @($shapes | ForEach-Object {
                (Test-DoctorPsHost -Determinable $_.D -Value $_.V -IsDefault $_.Def -Found $_.F).Status
            })
        $statuses.Count | Should -Be 5                                   # vacuity floor
        @($statuses | Where-Object { $_ -eq 'fail' }).Count | Should -Be 1
        $statuses[-1] | Should -Be 'fail'
    }
    It 'runs as a DEFAULT check, not behind the opt-in probe switch' {
        # The acceptance criterion is about the DEFAULT surface, so the dispatch site is pinned
        # structurally: Test-DoctorPsHost must be invoked in Invoke-Doctor, and must not sit
        # inside the `if ($ProbeNativeServe)` block that gates the opt-in probe.
        $src = Get-Content -LiteralPath (Join-Path $script:ScriptsDir 'doctor.ps1') -Raw
        $src | Should -Match '\$results \+= \(Test-DoctorPsHost '
        $optIn = [regex]::Match($src, '(?s)if \(\$ProbeNativeServe\) \{(.*?)\n    \}')
        $optIn.Success | Should -BeTrue                                  # vacuity floor
        $optIn.Groups[1].Value | Should -Not -Match 'Test-DoctorPsHost'
    }
}

Describe 'Preflight doctor -- ps_host observation reads the knob the SHIPPED consumers read' {
    # The observation half, testable without a session because the knob comes from the
    # environment and resolution is a Get-Command lookup -- so both directions are reachable.
    BeforeAll { . (Join-Path $script:ScriptsDir 'doctor.ps1') }

    # Sweep by WILDCARD, not by one exact name -- the idiom the Get-PluginOption Describe above
    # already uses, and it is load-bearing rather than stylistic here. Get-RawPluginOption
    # normalizes casing and underscores away, so it matches CLAUDE_PLUGIN_OPTION_ps_host just as
    # readily as ..._PS_HOST; but env names are case-SENSITIVE on the ubuntu-24.04 and macos-15
    # CI legs, where removing one spelling would leave the other one live and silently break the
    # "unset" precondition these tests depend on.
    BeforeEach {
        Get-ChildItem Env: | Where-Object { $_.Name -like 'CLAUDE_PLUGIN_OPTION_*' } |
            ForEach-Object { Remove-Item -LiteralPath ('Env:' + $_.Name) -ErrorAction SilentlyContinue }
    }
    AfterEach {
        Get-ChildItem Env: | Where-Object { $_.Name -like 'CLAUDE_PLUGIN_OPTION_*' } |
            ForEach-Object { Remove-Item -LiteralPath ('Env:' + $_.Name) -ErrorAction SilentlyContinue }
    }

    It 'reports IsDefault when ps_host is unset' {
        $o = Get-DoctorPsHostObservation
        $o.Determinable | Should -BeTrue
        $o.IsDefault | Should -BeTrue
        $o.Value | Should -Be 'pwsh'
    }
    It 'treats an explicit "pwsh" as the default (same observable state)' {
        $env:CLAUDE_PLUGIN_OPTION_PS_HOST = 'pwsh'
        (Get-DoctorPsHostObservation).IsDefault | Should -BeTrue
    }
    It 'resolves a real non-default host and reports Found with its path' {
        # The running host's own executable: guaranteed to exist on every leg, and a full path
        # so it is never equal to the 'pwsh' default -- portable across Windows and Linux CI.
        $exe = (Get-Process -Id $PID).Path
        $exe | Should -Not -BeNullOrEmpty                                # vacuity floor
        $env:CLAUDE_PLUGIN_OPTION_PS_HOST = $exe
        $o = Get-DoctorPsHostObservation
        $o.IsDefault | Should -BeFalse
        $o.Found | Should -BeTrue
        $o.ResolvedPath | Should -Not -BeNullOrEmpty
    }
    It 'reports Found=false for a non-default host that is not installed' {
        $env:CLAUDE_PLUGIN_OPTION_PS_HOST = 'no-such-powershell-host-exe'
        $o = Get-DoctorPsHostObservation
        $o.Determinable | Should -BeTrue
        $o.IsDefault | Should -BeFalse
        $o.Found | Should -BeFalse
    }
    It 'drives the pure check to a real FAIL end to end (observation + decision)' {
        # The two halves joined: a bogus knob value must reach a FAIL, which is what makes the
        # check fail-CAPABLE in the shipped wiring rather than only in the pure function.
        $env:CLAUDE_PLUGIN_OPTION_PS_HOST = 'no-such-powershell-host-exe'
        $o = Get-DoctorPsHostObservation
        $r = Test-DoctorPsHost -Determinable $o.Determinable -Reason $o.Reason -Value $o.Value `
            -IsDefault $o.IsDefault -Found $o.Found -ResolvedPath $o.ResolvedPath
        $r.Status | Should -Be 'fail'
    }
}

Describe 'Preflight doctor -- plugin version report (dispatch 000208, report-only header)' {
    # The version report is a HEADER LINE, not a check row (OQ3): a version is not a pass/fail
    # result, the status vocabulary CONTRACT.md freezes has no word for "here is a fact", and a
    # row would inflate the "of N checks" count with a non-check. These guards pin the three
    # properties the acceptance criteria name: it calls the shipped Get-PluginVersion, it never
    # fails, and it renders regardless of what the checks below it say.
    BeforeAll {
        . (Join-Path $script:ScriptsDir 'doctor.ps1')
        $manifestPath = Join-Path $script:PluginRoot '.claude-plugin/plugin.json'
        $script:DoctorManifestVersion = [string](((Get-Content -LiteralPath $manifestPath -Raw) | ConvertFrom-Json).version)
        $script:AllUnknown = @(
            (New-DoctorResult -Status unknown -Component 'Alpha check' -Detail 'a')
            (New-DoctorResult -Status unknown -Component 'Beta check' -Detail 'b')
        )
    }
    It 'the manifest version is non-empty (the guards below cannot pass vacuously)' {
        $script:DoctorManifestVersion | Should -Not -BeNullOrEmpty
    }
    It 'the full report renders the version from Get-PluginVersion, not a literal' {
        $out = Format-DoctorReport -Results $script:AllUnknown
        $out | Should -Match ('version: ' + [regex]::Escape((Get-PluginVersion)))
        (Get-PluginVersion) | Should -BeExactly $script:DoctorManifestVersion
    }
    It 'the compact status renders the same version, from the same source' {
        (Format-DoctorSummary -Results $script:AllUnknown) |
            Should -Match ('version: ' + [regex]::Escape((Get-PluginVersion)))
    }
    It 'renders even when EVERY check is UNKNOWN -- it is not gated on any check state' {
        # The supportability property: "what version are you on?" must be answerable from a run
        # in which nothing else could be determined, which is precisely the run a stranger sends.
        foreach ($r in @($script:AllUnknown)) { $r.Status | Should -Be 'unknown' }   # vacuity floor
        (Format-DoctorReport -Results $script:AllUnknown) | Should -Match 'version: '
        (Format-DoctorSummary -Results $script:AllUnknown) | Should -Match 'version: '
    }
    It 'renders when every check FAILS, and adds no fail of its own' {
        $allFail = @((New-DoctorResult -Status fail -Component 'Gamma check' -Detail 'g' -Remediation 'fix'))
        $out = Format-DoctorReport -Results $allFail
        $out | Should -Match 'version: '
        # Report-only: the version contributes no result object, so the counts are the checks'
        # counts alone and the exit-code input is untouched.
        $out | Should -Match ([regex]::Escape('summary: 0 pass, 1 fail, 0 unknown (of 1 checks)'))
    }
    It 'is NOT a check row -- it never appears in the counts or the check total' {
        # The discriminator between the two placements OQ3 asked about. Were the version a row,
        # a one-check fixture would render "of 2 checks".
        $one = @((New-DoctorResult -Status pass -Component 'Only check' -Detail 'd'))
        foreach ($render in @((Format-DoctorReport -Results $one), (Format-DoctorSummary -Results $one))) {
            $render | Should -Match ([regex]::Escape('(of 1 checks)'))
            $render | Should -Not -Match 'PASS\s+version'
        }
        (Format-DoctorSummary -Results $one) | Should -Match 'status -- 1 checks'
    }
    It 'adds NO second version-derivation path -- doctor.ps1 parses no manifest of its own' {
        # "Call the already-shipped Get-PluginVersion; do NOT add new version-derivation logic."
        # A private re-read of plugin.json here could drift from the single source of truth.
        $src = Get-Content -LiteralPath (Join-Path $script:ScriptsDir 'doctor.ps1') -Raw
        $src | Should -Match '\(Get-PluginVersion\)'
        @([regex]::Matches($src, "ConvertFrom-Json\).version")).Count | Should -Be 0
    }
    It 'the injected-version seam is honored (the renderers stay testable)' {
        (Format-DoctorReport -Results $script:AllUnknown -Version '9.9.9-test') | Should -Match 'version: 9\.9\.9-test'
        (Format-DoctorSummary -Results $script:AllUnknown -Version '9.9.9-test') | Should -Match 'version: 9\.9\.9-test'
    }
}

Describe 'Preflight doctor -- tree-vs-daemon version reconciliation (DX finding O2)' {
    # O2: after an upgrade the doctor reported the TREE's version beside a clean pass while the
    # daemon serving the session was older, and no surface reconciled the two -- so "which version
    # is actually running?", the first question of any support thread, got a confidently wrong
    # answer. Dispatch 000265 closed the honesty half with a caveat; this closes the other half by
    # ANSWERING it from the version the daemon stamps into its own session record.
    BeforeAll {
        . (Join-Path $script:ScriptsDir 'doctor.ps1')
        $script:AllUnknown = @(
            (New-DoctorResult -Status unknown -Component 'Alpha check' -Detail 'a')
            (New-DoctorResult -Status unknown -Component 'Beta check' -Detail 'b')
        )
    }

    Context 'Get-DoctorVersionLine -- the four cases, decided purely' {
        It 'no live daemon -> the tree version stands alone, and says so' {
            $l = Get-DoctorVersionLine -TreeVersion '1.32.0' -DaemonVersion '' -DaemonPresent $false
            $l | Should -Match 'version: 1\.32\.0'
            $l | Should -Match 'no live daemon to reconcile against'
        }
        It 'daemon agrees -> ONE version, stated as agreement rather than as a caveat' {
            $l = Get-DoctorVersionLine -TreeVersion '1.32.0' -DaemonVersion '1.32.0' -DaemonPresent $true
            $l | Should -Match 'this tree AND the live daemon agree'
            # The old hedge must NOT survive where the answer is actually known.
            $l | Should -Not -Match 'may be older'
        }
        It 'daemon differs -> BOTH versions appear, and the difference is explained as expected' {
            $l = Get-DoctorVersionLine -TreeVersion '1.32.0' -DaemonVersion '1.30.0' -DaemonPresent $true
            $l | Should -Match '1\.32\.0'      # the tree
            $l | Should -Match '1\.30\.0'      # the daemon actually serving
            $l | Should -Match 'LIVE DAEMON'
            $l | Should -Match 'expected after an upgrade'
        }
        It 'daemon present but UNVERSIONED -> reported as unknown, never inferred to be a mismatch' {
            # A record written by a daemon older than the pluginVersion field has no version. An
            # ABSENT version is not evidence of disagreement, and saying otherwise would invent a
            # mismatch out of a missing field.
            $l = Get-DoctorVersionLine -TreeVersion '1.32.0' -DaemonVersion '' -DaemonPresent $true
            $l | Should -Match 'predates version stamping'
            $l | Should -Not -Match 'LIVE DAEMON is running'
        }
        It 'reproduces the exact O2 scenario end to end' {
            # The audit recorded: tree 1.31.0, daemon 1.30.0, and a report containing NO occurrence
            # of 1.30, mismatch, stale or older. Assert the opposite now holds.
            $l = Get-DoctorVersionLine -TreeVersion '1.31.0' -DaemonVersion '1.30.0' -DaemonPresent $true
            $l | Should -Match '1\.30'
        }
    }

    Context 'the renderers carry the reconciliation' {
        It 'both surfaces render the differing case, so /status and the full report cannot disagree' {
            foreach ($render in @(
                    (Format-DoctorReport  -Results $script:AllUnknown -Version '1.32.0' -DaemonVersion '1.30.0' -DaemonPresent $true),
                    (Format-DoctorSummary -Results $script:AllUnknown -Version '1.32.0' -DaemonVersion '1.30.0' -DaemonPresent $true))) {
                $render | Should -Match '1\.30\.0'
                $render | Should -Match 'LIVE DAEMON'
            }
        }
        It 'defaults are inert -- an out-of-band render produces the honest no-daemon wording' {
            # Every pre-existing caller passes no daemon arguments. None of them may start
            # claiming agreement it has not established.
            foreach ($render in @(
                    (Format-DoctorReport  -Results $script:AllUnknown),
                    (Format-DoctorSummary -Results $script:AllUnknown))) {
                $render | Should -Match 'no live daemon to reconcile against'
                $render | Should -Not -Match 'agree'
            }
        }
        It 'the version line is still a HEADER, not a check row (dispatch 000208 ruling preserved)' {
            $before = @($script:AllUnknown).Count
            $render = Format-DoctorSummary -Results $script:AllUnknown -Version '1.32.0' -DaemonVersion '1.30.0' -DaemonPresent $true
            $render | Should -Match ('status -- ' + $before + ' checks')
        }
    }

    Context 'the daemon stamps its own version into the session record' {
        It 'Write-SessionFile emits pluginVersion, sourced from the ONE version resolver' {
            $src = Get-Content -LiteralPath (Join-Path $script:ScriptsDir 'pses-daemon.ps1') -Raw
            $src | Should -Match 'pluginVersion\s*=\s*\(Get-PluginVersion\)'
        }
        It 'the doctor reads that field by name from the session record' {
            $src = Get-Content -LiteralPath (Join-Path $script:ScriptsDir 'doctor.ps1') -Raw
            $src | Should -Match "Get-Prop \`$obj 'pluginVersion'"
        }
        It 'no userConfig knob and no status token was added for this (CONTRACT.md stays green)' {
            # The fix had to be contained: an additive JSON field plus a header line, never a new
            # knob or a new status token, both of which CONTRACT.md freezes for 1.x.
            $src = Get-Content -LiteralPath (Join-Path $script:ScriptsDir 'doctor.ps1') -Raw
            @([regex]::Matches($src, 'CLAUDE_PLUGIN_OPTION_daemonVersion')).Count | Should -Be 0
        }
    }
}

Describe 'Preflight doctor -- clearance provenance floor readout (dispatch 000216, report-only header)' {
    # The floor answers the question that follows "what version are you on?" -- "and how far back
    # can that answer be trusted?" It rides as a SECOND header line under the same 000208 ruling
    # the version line was placed by: a fact is not a pass/fail result, so it is never a check row
    # and can never inflate the "of N checks" count or move the exit code.
    #
    # The load-bearing property these guards pin is SINGLE SOURCING: the value the doctor prints
    # must be the value Get-LifecycleProvenanceFloor computes, asked live, over the same log --
    # never a second attributability rule that could disagree with the efficacy ledger.
    BeforeAll {
        . (Join-Path $script:ScriptsDir 'doctor.ps1')
        # The floor's own source, loaded separately HERE so the expectations below are derived
        # from it rather than written as literals. It is the same library doctor.ps1 consults and
        # the same one the efficacy ledger renders from, so a change to its ruling moves every
        # side at once -- which is the property this Describe exists to pin.
        . (Join-Path $script:ScriptsDir 'lib/lifecycle-provenance.ps1')

        $script:ProvFloored = Join-Path $TestDrive 'prov-floored'
        $script:ProvGapOnly = Join-Path $TestDrive 'prov-gap-only'
        $script:ProvNoLog = Join-Path $TestDrive 'prov-no-log'
        foreach ($d in @($script:ProvFloored, $script:ProvGapOnly, $script:ProvNoLog)) {
            New-Item -ItemType Directory -Force -Path $d | Out-Null
        }
        # Two stamped releases plus one unstamped record: the floor must be the EARLIEST stamped
        # one (1.9.0, which also outranks 1.10.0 lexically -- so a string sort would pick wrong)
        # and the unstamped record must land pre-floor rather than becoming a version.
        $lines = @(
            ([ordered]@{ schema = 'powershell-lsp-lifecycle/1'; ruleId = 'PSAvoidUsingCmdletAliases'; cleared = 1; stillPresent = 0; pluginVersion = '1.10.0' } | ConvertTo-Json -Compress)
            ([ordered]@{ schema = 'powershell-lsp-lifecycle/1'; ruleId = 'PSAvoidUsingCmdletAliases'; cleared = 0; stillPresent = 1; pluginVersion = '1.9.0' } | ConvertTo-Json -Compress)
            ([ordered]@{ schema = 'powershell-lsp-lifecycle/1'; ruleId = 'PSUseApprovedVerbs'; cleared = 1; stillPresent = 0 } | ConvertTo-Json -Compress)
        )
        Set-Content -LiteralPath (Join-Path $script:ProvFloored 'lifecycle-20260801-120000-000.jsonl') -Value $lines -Encoding ascii
        Set-Content -LiteralPath (Join-Path $script:ProvGapOnly 'lifecycle-20260801-120000-000.jsonl') `
            -Value @(([ordered]@{ schema = 'powershell-lsp-lifecycle/1'; ruleId = 'PSUseApprovedVerbs'; cleared = 1; stillPresent = 0 } | ConvertTo-Json -Compress)) -Encoding ascii

        # This block's own result fixtures -- deliberately not borrowed from the 000208 Describe
        # above, so a filtered run of this Describe alone still has everything it needs.
        $script:ProvOneCheck = @((New-DoctorResult -Status pass -Component 'Only check' -Detail 'd'))
        $script:ProvAllUnknown = @(
            (New-DoctorResult -Status unknown -Component 'Alpha check' -Detail 'a')
            (New-DoctorResult -Status unknown -Component 'Beta check' -Detail 'b')
        )
    }

    It 'the floored fixture really produces a floor (the guards below cannot pass vacuously)' {
        $o = Get-DoctorProvenanceObservation -LifecyclePath $script:ProvFloored
        $o.Determinable | Should -BeTrue
        $o.State | Should -BeExactly 'floored'
        $o.Floor | Should -Not -BeNullOrEmpty
    }

    It 'the printed floor IS Get-LifecycleProvenanceFloor''s answer, asked live -- not a second derivation' {
        # Derived on both sides from the SAME fixture: the doctor through its own observation, the
        # expectation straight from the ledger function. A private attributability rule in the
        # doctor that ordered differently (or read the 0.0.0-unknown sentinel as a version) would
        # turn this RED rather than quietly publishing a floor the efficacy ledger disagrees with.
        $search = Resolve-LifecycleLogSearch -LifecyclePath $script:ProvFloored
        $life = Read-LifecycleLog -LogPaths @($search.Paths) -Search $search
        $expected = Get-LifecycleProvenanceFloor -Versions $life.Versions -PreFloor ([int]$life.PreFloorRecords)
        [string]$expected.Floor | Should -BeExactly '1.9.0'      # semantic order, not lexical
        (Get-DoctorProvenanceHeader -LifecyclePath $script:ProvFloored) |
            Should -BeExactly ('v' + [string]$expected.Floor + '  (earliest version-attributable release in the ' +
                'RETAINED lifecycle window; ' + [string]$expected.Attributable + ' attributable, ' +
                [string]$expected.PreFloor + ' pre-floor)')
    }

    It 'states RETAINED -- the floor is window-relative, not a permanent fact' {
        # The one semantic that makes the number safe to quote: the lifecycle family is swept to
        # keepLastN, so the floor RISES as records age out. A readout that said "earliest" full
        # stop would be read as history.
        (Get-DoctorProvenanceHeader -LifecyclePath $script:ProvFloored) | Should -Match 'RETAINED'
    }

    It 'renders the honest (absent) state when NO lifecycle log exists' {
        # An explicit -LifecyclePath is always a KNOWN root (the caller named the directory), so a
        # miss there really is a miss -- which is what entitles this branch to the word.
        $o = Get-DoctorProvenanceObservation -LifecyclePath $script:ProvNoLog
        $o.Determinable | Should -BeTrue
        $o.Present | Should -BeFalse
        $o.RootKnown | Should -BeTrue
        (Get-DoctorProvenanceHeader -LifecyclePath $script:ProvNoLog) |
            Should -BeExactly '(absent) -- no lifecycle log has been written yet.'
    }

    It 'a log with records but NO attributable one is a different claim from no log at all' {
        # Three distinct states must not render identically -- the same never-a-silent-skip rule
        # the ledger applies to a zero-row ledger versus a ledger over nothing.
        $gap = Get-DoctorProvenanceHeader -LifecyclePath $script:ProvGapOnly
        $none = Get-DoctorProvenanceHeader -LifecyclePath $script:ProvNoLog
        $floored = Get-DoctorProvenanceHeader -LifecyclePath $script:ProvFloored
        $gap | Should -Match 'none version-attributable'
        $gap | Should -Not -BeExactly $none
        $gap | Should -Not -BeExactly $floored
    }

    It 'a FALLBACK data root never renders as (absent) -- that is a claim about the world' {
        # The 000182 defect, guarded at this surface: 'absent' means nothing was ever captured. A
        # search under a substituted root cannot support it, so this state says so instead.
        $fallback = Format-DoctorProvenanceFloor -Determinable $true -State 'none' -Present $false -RootKnown $false
        $fallback | Should -Not -Match 'absent'
        $fallback | Should -Match 'FALLBACK data root'
        # The paired control: the SAME state with a known root is exactly the one that may say it.
        (Format-DoctorProvenanceFloor -Determinable $true -State 'none' -Present $false -RootKnown $true) |
            Should -Match 'absent'
    }

    It 'is NOT a check row -- it never appears in the counts or the check total' {
        # The discriminator the 000208 header ruling turns on, re-applied: were the floor a row, a
        # one-check fixture would render "of 2 checks" and /status would say "2 checks".
        foreach ($render in @((Format-DoctorReport -Results $script:ProvOneCheck),
                (Format-DoctorSummary -Results $script:ProvOneCheck))) {
            $render | Should -Match 'provenance floor: '
            $render | Should -Match ([regex]::Escape('(of 1 checks)'))
            $render | Should -Not -Match 'PASS\s+provenance'
            $render | Should -Not -Match 'UNKNOWN\s+provenance'
        }
        (Format-DoctorSummary -Results $script:ProvOneCheck) | Should -Match 'status -- 1 checks'
    }

    It 'renders on BOTH surfaces even when every check is UNKNOWN, and adds no fail of its own' {
        foreach ($r in @($script:ProvAllUnknown)) { $r.Status | Should -Be 'unknown' }   # vacuity floor
        (Format-DoctorReport -Results $script:ProvAllUnknown) | Should -Match 'provenance floor: '
        (Format-DoctorSummary -Results $script:ProvAllUnknown) | Should -Match 'provenance floor: '
        $allFail = @((New-DoctorResult -Status fail -Component 'Gamma check' -Detail 'g' -Remediation 'fix'))
        $out = Format-DoctorReport -Results $allFail
        $out | Should -Match 'provenance floor: '
        $out | Should -Match ([regex]::Escape('summary: 0 pass, 1 fail, 0 unknown (of 1 checks)'))
    }

    It 'the injected-provenance seam is honored (the renderers stay testable)' {
        (Format-DoctorReport -Results $script:ProvAllUnknown -Provenance 'v9.9.9-injected') |
            Should -Match 'provenance floor: v9\.9\.9-injected'
        (Format-DoctorSummary -Results $script:ProvAllUnknown -Provenance 'v9.9.9-injected') |
            Should -Match 'provenance floor: v9\.9\.9-injected'
    }

    It 'FAILS OPEN -- an unreachable library yields an honest line, never a throw' {
        $missing = Join-Path $TestDrive 'no-scripts-dir-here'
        { Get-DoctorProvenanceObservation -ScriptsDir $missing } | Should -Not -Throw
        $o = Get-DoctorProvenanceObservation -ScriptsDir $missing
        $o.Determinable | Should -BeFalse
        (Get-DoctorProvenanceHeader -ScriptsDir $missing) | Should -Match 'undetermined'
    }

    It 'adds NO second attributability derivation -- the doctor calls the library, it does not re-rule' {
        # The single-source guard, at the source level: the doctor must not grow its own opinion
        # about what counts as a version. The paired control proves the strings are absent from
        # doctor.ps1 because they live in the shared library, not because they exist nowhere.
        $doctorSrc = Get-Content -LiteralPath (Join-Path $script:ScriptsDir 'doctor.ps1') -Raw
        $libSrc = Get-Content -LiteralPath (Join-Path $script:ScriptsDir 'lib/lifecycle-provenance.ps1') -Raw
        $doctorSrc | Should -Match 'Get-LifecycleProvenanceFloor'
        @([regex]::Matches($doctorSrc, [regex]::Escape('0.0.0-unknown'))).Count | Should -Be 0
        @([regex]::Matches($doctorSrc, [regex]::Escape('[System.Version]::TryParse'))).Count | Should -Be 0
        @([regex]::Matches($libSrc, [regex]::Escape('0.0.0-unknown'))).Count | Should -BeGreaterThan 0
        @([regex]::Matches($libSrc, [regex]::Escape('[System.Version]::TryParse'))).Count | Should -BeGreaterThan 0
    }

    It 'ONE definition serves both readers -- neither file carries a copy of the floor' {
        # The point of the 000216 relocation, pinned. Reaching the floor by dot-sourcing the ledger
        # is not merely untidy, it is forbidden: the ledger is an entry point with a param() block,
        # and dot-sourcing a .ps1 runs that block in the caller's scope (hit live while building
        # this, then refused structurally by the G1 purity guard). So the definition lives in the
        # library and BOTH consumers ask it -- there is no second copy to drift.
        $libSrc = Get-Content -LiteralPath (Join-Path $script:ScriptsDir 'lib/lifecycle-provenance.ps1') -Raw
        @([regex]::Matches($libSrc, '(?m)^function Get-LifecycleProvenanceFloor\b')).Count | Should -Be 1
        foreach ($consumer in @('doctor.ps1', 'rule-efficacy-ledger.ps1')) {
            $src = Get-Content -LiteralPath (Join-Path $script:ScriptsDir $consumer) -Raw
            $src | Should -Match ([regex]::Escape("lib/lifecycle-provenance.ps1"))   # it loads the library
            @([regex]::Matches($src, '(?m)^function Get-LifecycleProvenanceFloor\b')).Count | Should -Be 0
        }
        # ...and the doctor never dot-sources the param()-carrying entry point to get there.
        (Get-Content -LiteralPath (Join-Path $script:ScriptsDir 'doctor.ps1') -Raw) |
            Should -Not -Match ([regex]::Escape("rule-efficacy-ledger.ps1"))
    }

    It 'the -LifecyclePath seam is honored -- two fixtures give two answers' {
        # Re-derived from the CURRENT free-pass risk (the earlier version of this guard pinned the
        # dot-source clobber, whose premise the relocation removed). What can still go wrong is a
        # readout that ignores the path it was handed and reports whatever the default family says
        # -- which is exactly how the clobber presented. Two fixtures, two answers, so a readout
        # that ignored its argument could not pass.
        (Get-DoctorProvenanceHeader -LifecyclePath $script:ProvFloored) |
            Should -Not -BeExactly (Get-DoctorProvenanceHeader -LifecyclePath $script:ProvNoLog)
        (Get-DoctorProvenanceObservation -LifecyclePath $script:ProvFloored).State | Should -BeExactly 'floored'
        (Get-DoctorProvenanceObservation -LifecyclePath $script:ProvNoLog).State | Should -BeExactly 'none'
    }
}

Describe 'README documents the version + provenance-floor support answer (dispatch 000216)' {
    # SINGLE-SOURCED BY CONSTRUCTION is the design claim; these give it teeth. The README does not
    # restate a floor value that could go stale -- it points at the live readout -- so what must be
    # guarded is that the doc and the runtime name the SAME sources and cover the SAME states.
    #
    # Keyed on NAMES and on renderings derived LIVE from the shipped formatter, never on prose: a
    # test coupled to wording would break on a copy-edit and would still not notice a state the
    # formatter can reach but the docs never mention (the 000110 lesson).
    BeforeAll {
        . (Join-Path $script:ScriptsDir 'doctor.ps1')
        $script:ProvReadme = Get-Content -LiteralPath (Join-Path $script:PluginRoot 'README.md') -Raw
        $script:ProvDoctorSrc = Get-Content -LiteralPath (Join-Path $script:ScriptsDir 'doctor.ps1') -Raw
    }
    It 'names the two single sources the readout reads -- doc and runtime cannot drift apart' {
        foreach ($fn in @('Get-PluginVersion', 'Get-LifecycleProvenanceFloor')) {
            $script:ProvReadme | Should -Match $fn
            $script:ProvDoctorSrc | Should -Match $fn      # the paired half: the runtime really reads it
        }
    }
    It 'documents every state token the SHIPPED formatter can render' {
        # Ground truth from the formatter itself. A sixth state added without a doc line turns
        # this RED, instead of shipping a rendering no reader has ever been told how to read.
        $renderings = @(
            (Format-DoctorProvenanceFloor -Determinable $false)
            (Format-DoctorProvenanceFloor -Determinable $true -State 'gap-only' -Records 3 -Present $true)
            (Format-DoctorProvenanceFloor -Determinable $true -State 'none' -Present $false -RootKnown $true)
            (Format-DoctorProvenanceFloor -Determinable $true -State 'none' -Present $true)
            (Format-DoctorProvenanceFloor -Determinable $true -State 'none' -Present $false -RootKnown $false)
        )
        @($renderings).Count | Should -Be 5
        foreach ($r in $renderings) {
            $token = ([regex]::Match($r, '^\((?<t>[a-z]+)\)')).Groups['t'].Value
            $token | Should -Not -BeNullOrEmpty                       # vacuity floor
            $script:ProvReadme | Should -Match ('`\(' + $token + '\)`')
        }
    }
    It 'states the window-relative meaning and points at the live readout' {
        $script:ProvReadme | Should -Match 'window-relative'
        $script:ProvReadme | Should -Match 'keepLastN'
        $script:ProvReadme | Should -Match 'still\s+\*\*retained\*\*|\*\*still\s+retained\*\*'
        $script:ProvReadme | Should -Match '/powershell-lsp:status'
        $script:ProvReadme | Should -Match '/powershell-lsp:doctor'
    }
}

Describe 'Preflight doctor -- test diagnostic observed end-to-end (item 8, dispatch 000166)' {
    BeforeAll { . (Join-Path $script:ScriptsDir 'doctor.ps1') }

    It 'is UNKNOWN when there is no daemon to ask (the doctor never starts one)' {
        $r = Test-DoctorTestDiagnostic -Determinable $false -Reason 'no live warm daemon was identified.'
        $r.Status | Should -Be 'unknown'
        $r.Detail | Should -Match 'no live warm daemon'
    }
    It 'is UNKNOWN when the daemon did not return a well-formed response' {
        $r = Test-DoctorTestDiagnostic -Determinable $true -Responded $false
        $r.Status | Should -Be 'unknown'
    }
    It 'is UNKNOWN (quoting the status) when the analysis did not settle: <_>' -ForEach @('incomplete', 'degraded', 'unavailable') {
        # A non-ok status is the plugin's own honest banner working, not a failure to report.
        $r = Test-DoctorTestDiagnostic -Determinable $true -Responded $true -Status $_ -ExpectedRule 'PSUseApprovedVerbs' -RuleIds @()
        $r.Status | Should -Be 'unknown'
        $r.Detail | Should -Match ([regex]::Escape($_))
    }
    It 'PASSES when the planted defect comes back' {
        $r = Test-DoctorTestDiagnostic -Determinable $true -Responded $true -Status 'ok' -ExpectedRule 'PSUseApprovedVerbs' -RuleIds @('PSUseApprovedVerbs') -ElapsedMs 1234
        $r.Status | Should -Be 'pass'
        $r.Detail | Should -Match 'observed end-to-end'
        $r.Detail | Should -Match '1234 ms'
    }
    It 'PASSES when the expected rule is present ALONGSIDE other findings' {
        $r = Test-DoctorTestDiagnostic -Determinable $true -Responded $true -Status 'ok' -ExpectedRule 'PSUseApprovedVerbs' -RuleIds @('PSAvoidUsingWriteHost', 'PSUseApprovedVerbs')
        $r.Status | Should -Be 'pass'
    }
    It 'FAILS -- the one deliberate fail -- when a SETTLED analysis produced nothing' {
        # This is the silent-failure mode the whole plugin exists to prevent: an edit reading
        # as "analyzed, clean" when the analyzer is not producing findings at all.
        $r = Test-DoctorTestDiagnostic -Determinable $true -Responded $true -Status 'ok' -ExpectedRule 'PSUseApprovedVerbs' -RuleIds @()
        $r.Status | Should -Be 'fail'
        $r.Detail | Should -Match 'no findings at all'
        $r.Detail | Should -Match 'settled-but-empty'
        $r.Remediation | Should -Not -BeNullOrEmpty
    }
    It 'FAILS and NAMES what did come back, when the wrong findings returned' {
        $r = Test-DoctorTestDiagnostic -Determinable $true -Responded $true -Status '' -ExpectedRule 'PSUseApprovedVerbs' -RuleIds @('PSAvoidUsingWriteHost')
        $r.Status | Should -Be 'fail'
        $r.Detail | Should -Match 'PSAvoidUsingWriteHost'
    }
    It 'the SETTLED-but-empty case is the ONLY fail across every input shape' {
        # Guards the exit-code contract from the other side: enumerate the shapes and assert
        # exactly one of them fails. A future edit that turned an indeterminate path into a
        # fail would start moving callers' exit codes, and this goes red.
        $shapes = @(
            @{ D = $false; R = $false; S = ''; Ids = @() }
            @{ D = $true;  R = $false; S = ''; Ids = @() }
            @{ D = $true;  R = $true;  S = 'incomplete';  Ids = @() }
            @{ D = $true;  R = $true;  S = 'degraded';    Ids = @() }
            @{ D = $true;  R = $true;  S = 'unavailable'; Ids = @() }
            @{ D = $true;  R = $true;  S = 'ok'; Ids = @('PSUseApprovedVerbs') }
            @{ D = $true;  R = $true;  S = 'ok'; Ids = @() }          # <- the only fail
        )
        $statuses = @($shapes | ForEach-Object {
            (Test-DoctorTestDiagnostic -Determinable $_.D -Responded $_.R -Status $_.S -ExpectedRule 'PSUseApprovedVerbs' -RuleIds $_.Ids).Status
        })
        $statuses.Count | Should -Be 7                                   # vacuity floor
        @($statuses | Where-Object { $_ -eq 'fail' }).Count | Should -Be 1
        $statuses[-1] | Should -Be 'fail'
    }
}

Describe 'Format-DoctorSummary -- the /status rendering over the Invoke-Doctor seam (000166 B10)' {
    # /powershell-lsp:status is a RENDERING, not a second health check. The property that makes
    # that claim true is that it is a pure function of the SAME result objects Format-DoctorReport
    # consumes -- so it cannot re-decide anything, and it cannot disagree with the full report.
    # These guards pin exactly that, plus the one thing a compact view could get wrong: silently
    # swallowing the remediation for a failing check with no way to reach it.
    BeforeAll {
        . (Join-Path $script:ScriptsDir 'doctor.ps1')
        $script:SummaryFixture = @(
            (New-DoctorResult -Status pass -Component 'Alpha check' -Detail 'alpha detail prose')
            (New-DoctorResult -Status unknown -Component 'Beta check' -Detail 'beta detail prose' -Remediation 'beta fix text')
            (New-DoctorResult -Status fail -Component 'Gamma check' -Detail 'gamma detail prose' -Remediation 'gamma fix text')
        )
    }
    It 'renders one line per check, naming every component' {
        $s = Format-DoctorSummary -Results $script:SummaryFixture
        foreach ($c in @('Alpha check', 'Beta check', 'Gamma check')) { $s | Should -Match ([regex]::Escape($c)) }
    }
    It 'reports the SAME counts the full report does (it cannot disagree)' {
        $summary = Format-DoctorSummary -Results $script:SummaryFixture
        $full = Format-DoctorReport -Results $script:SummaryFixture
        $line = 'summary: 1 pass, 1 fail, 1 unknown (of 3 checks)'
        $summary | Should -Match ([regex]::Escape($line))
        $full | Should -Match ([regex]::Escape($line))
    }
    It 'OMITS the per-check detail prose (that is the whole point of the compact view)' {
        $s = Format-DoctorSummary -Results $script:SummaryFixture
        $s | Should -Not -Match 'alpha detail prose'
        $s | Should -Not -Match 'gamma detail prose'
        # ...and the full report DOES carry it -- otherwise this assertion would pass against a
        # renderer that dropped everything, including the parts it must keep.
        (Format-DoctorReport -Results $script:SummaryFixture) | Should -Match 'gamma detail prose'
    }
    It 'points at the full report when anything is not PASS (never a dead end)' {
        (Format-DoctorSummary -Results $script:SummaryFixture) | Should -Match 'doctor\.ps1'
    }
    It 'stays quiet when everything passes' {
        $allPass = @((New-DoctorResult -Status pass -Component 'Only check' -Detail 'd'))
        $s = Format-DoctorSummary -Results $allPass
        $s | Should -Match 'summary: 1 pass, 0 fail, 0 unknown'
        $s | Should -Not -Match 'For the per-check detail'
    }
}

Describe 'Preflight doctor -- native-serve STATUS, promoted out of opt-in (item 7, dispatch 000166)' {
    BeforeAll { . (Join-Path $script:ScriptsDir 'doctor.ps1') }

    It 'PASSES on the shipped default and says plainly that it is not a fault' {
        $r = Test-DoctorNativeServeStatus -Determinable $true -Value 'off' -ShimPresent $true
        $r.Status | Should -Be 'pass'
        $r.Detail | Should -Match 'not a fault'
        $r.Detail | Should -Match 'do NOT serve'
    }
    It 'treats a BLANK value as the default rather than as an error' {
        (Test-DoctorNativeServeStatus -Determinable $true -Value '' -ShimPresent $true).Status | Should -Be 'pass'
    }
    It 'PASSES and reports navigation ENABLED under shim' {
        $r = Test-DoctorNativeServeStatus -Determinable $true -Value 'shim' -ShimPresent $true
        $r.Status | Should -Be 'pass'
        $r.Detail | Should -Match 'ENABLED'
    }
    It 'is UNKNOWN when shim is configured but the shim script is missing' {
        $r = Test-DoctorNativeServeStatus -Determinable $true -Value 'shim' -ShimPresent $false
        $r.Status | Should -Be 'unknown'
    }
    It 'is UNKNOWN on an unrecognized value, and says what the plugin will actually do' {
        $r = Test-DoctorNativeServeStatus -Determinable $true -Value 'native' -ShimPresent $true
        $r.Status | Should -Be 'unknown'
        $r.Detail | Should -Match 'not a recognized value'
        $r.Detail | Should -Match 'treats anything other than "shim" as "off"'
    }
    It 'points at the opt-in probe ONLY when the probe did not already run' {
        (Test-DoctorNativeServeStatus -Determinable $true -Value 'off' -ShimPresent $true -Probed $false).Detail | Should -Match 'ProbeNativeServe'
        (Test-DoctorNativeServeStatus -Determinable $true -Value 'off' -ShimPresent $true -Probed $true).Detail | Should -Not -Match 'Run with -ProbeNativeServe'
    }
    It 'NEVER returns fail (off by default is a supported configuration)' {
        foreach ($v in @('off', 'shim', '', 'native', 'true')) {
            foreach ($p in @($true, $false)) {
                (Test-DoctorNativeServeStatus -Determinable $true -Value $v -ShimPresent $p).Status | Should -Not -Be 'fail'
            }
        }
        (Test-DoctorNativeServeStatus -Determinable $false).Status | Should -Not -Be 'fail'
    }
}

# ===========================================================================
# Security-block classifier (dispatch 000038, building 000032 L3)
# ===========================================================================
# Honest degradation on a security-control block: attribute a bootstrap failure to the
# control most likely blocking it -- but ONLY on positive evidence. The classifier is a
# PURE function over INJECTED evidence (these tests pass evidence directly, no live
# probes), so the honesty discipline is asserted deterministically per case. The live
# probes are exercised separately with EVERY probe mocked. This ENRICHES the existing
# never-silent surface (000024/000028); it adds NO status token (the 000027-frozen
# taxonomy is untouched -- the Get-DiagnosticsStatusBanner drift-guard above stays green).

Describe 'Resolve-SecurityBlock -- ExecutionPolicy attribution, GPO-scope only (dispatch 000038)' {
    It 'names ExecutionPolicy (likely) when a GROUP-POLICY scope is AllSigned' {
        $r = Resolve-SecurityBlock -Evidence @{ ExecutionPolicies = @{ MachinePolicy = 'AllSigned'; CurrentUser = 'Undefined' } } -Component 'PSES bootstrap'
        $r.Control | Should -BeExactly 'ExecutionPolicy'
        $r.Confidence | Should -BeExactly 'likely'
        $r.Summary | Should -Match 'MachinePolicy'
        $r.Summary | Should -Match 'AllSigned'
        $r.Evidence | Should -Match 'Get-ExecutionPolicy -List'
    }
    It 'names ExecutionPolicy for a UserPolicy RemoteSigned (the other GPO scope)' {
        $r = Resolve-SecurityBlock -Evidence @{ ExecutionPolicies = @{ UserPolicy = 'RemoteSigned' } } -Component 'PSES bootstrap'
        $r.Control | Should -BeExactly 'ExecutionPolicy'
        $r.Summary | Should -Match 'UserPolicy'
    }
    It 'does NOT name ExecutionPolicy for a CurrentUser/LocalMachine policy -- the plugin runs -ExecutionPolicy Bypass, which OVERRIDES those (the honesty boundary)' {
        # The whole correctness of this check: a non-GPO AllSigned is NOT a real block, so
        # naming it would be a false positive. Adversarial control: drop the scope filter and
        # this case starts naming ExecutionPolicy and goes RED.
        $r = Resolve-SecurityBlock -Evidence @{ ExecutionPolicies = @{ CurrentUser = 'AllSigned'; LocalMachine = 'RemoteSigned' } } -Component 'PSES bootstrap'
        $r.Control | Should -BeNullOrEmpty
        $r.Confidence | Should -BeExactly 'none'
    }
}

Describe 'Resolve-SecurityBlock -- Constrained Language Mode (dispatch 000038)' {
    It 'names CLM (likely) when the session LanguageMode is ConstrainedLanguage' {
        $r = Resolve-SecurityBlock -Evidence @{ LanguageMode = 'ConstrainedLanguage' } -Component 'PSES bootstrap'
        $r.Control | Should -BeExactly 'Constrained Language Mode'
        $r.Confidence | Should -BeExactly 'likely'
        $r.Summary | Should -Match 'Constrained Language Mode'
    }
    It 'does NOT name CLM for FullLanguage (no block)' {
        $r = Resolve-SecurityBlock -Evidence @{ LanguageMode = 'FullLanguage' } -Component 'PSES bootstrap'
        $r.Control | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-SecurityBlock -- App Control / WDAC via CodeIntegrity events (dispatch 000038)' {
    It 'names WDAC (confirmed) on a 3077 enforced-block event NAMING a plugin component' {
        $ev = @{ CodeIntegrityEvents = @(@{ Id = 3077; Message = 'Code Integrity blocked C:\data\PowerShellEditorServices\Start-EditorServices.ps1' }) }
        $r = Resolve-SecurityBlock -Evidence $ev -Component 'PSES bootstrap'
        $r.Control | Should -BeExactly 'App Control / WDAC'
        $r.Confidence | Should -BeExactly 'confirmed'
        $r.Summary | Should -Match '3077'
    }
    It 'names WDAC (likely) on a 3076 AUDIT event naming a plugin component -- audit is not enforced' {
        $ev = @{ CodeIntegrityEvents = @(@{ Id = 3076; Message = 'audit: pses-daemon.ps1' }) }
        $r = Resolve-SecurityBlock -Evidence $ev -Component 'PSES bootstrap'
        $r.Control | Should -BeExactly 'App Control / WDAC'
        $r.Confidence | Should -BeExactly 'likely'
        $r.Summary | Should -Match '3076'
    }
    It 'does NOT name WDAC on a 3077 that names some OTHER, unrelated file (no false positive)' {
        # Correlation, not bare presence: a 3077 about an unrelated binary on the box must not
        # be attributed to us. Adversarial control: drop the component-reference test and this
        # starts naming WDAC and goes RED.
        $ev = @{ CodeIntegrityEvents = @(@{ Id = 3077; Message = 'Code Integrity blocked C:\Program Files\Other\thing.exe' }) }
        $r = Resolve-SecurityBlock -Evidence $ev -Component 'PSES bootstrap'
        $r.Control | Should -BeNullOrEmpty
        $r.Confidence | Should -BeExactly 'none'
    }
}

Describe 'Resolve-SecurityBlock -- Defender ASR via events (dispatch 000038)' {
    It 'names Defender ASR (confirmed) on a 1121 block event naming a plugin component' {
        $ev = @{ DefenderAsrEvents = @(@{ Id = 1121; Message = 'ASR blocked process: ensure-pses.ps1' }) }
        $r = Resolve-SecurityBlock -Evidence $ev -Component 'PSES bootstrap'
        $r.Control | Should -BeExactly 'Microsoft Defender ASR'
        $r.Confidence | Should -BeExactly 'confirmed'
        $r.Summary | Should -Match '1121'
    }
    It 'names Defender ASR (likely) on a 1122 audit event naming a plugin component' {
        $ev = @{ DefenderAsrEvents = @(@{ Id = 1122; Message = 'ASR audit: pses-stdio.ps1' }) }
        $r = Resolve-SecurityBlock -Evidence $ev -Component 'PSES bootstrap'
        $r.Control | Should -BeExactly 'Microsoft Defender ASR'
        $r.Confidence | Should -BeExactly 'likely'
    }
}

Describe 'Resolve-SecurityBlock -- Smart App Control is SCOPED, never confirmed (dispatch 000038)' {
    It 'names SAC only as POSSIBLE when enforced (state 1), with hedged "may be" wording' {
        $r = Resolve-SecurityBlock -Evidence @{ SacState = 1 } -Component 'PSES bootstrap'
        $r.Control | Should -BeExactly 'Smart App Control'
        $r.Confidence | Should -BeExactly 'possible'
        $r.Summary | Should -Match 'may be'
    }
    It 'names SAC as POSSIBLE in evaluation mode (state 2)' {
        $r = Resolve-SecurityBlock -Evidence @{ SacState = 2 } -Component 'PSES bootstrap'
        $r.Control | Should -BeExactly 'Smart App Control'
        $r.Confidence | Should -BeExactly 'possible'
    }
    It 'does NOT name SAC when it is off (state 0)' {
        $r = Resolve-SecurityBlock -Evidence @{ SacState = 0 } -Component 'PSES bootstrap'
        $r.Control | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-SecurityBlock -- honest fallback, no fabrication (dispatch 000038)' {
    It 'returns "none" (no control) for empty evidence -- never invents a control' {
        $r = Resolve-SecurityBlock -Evidence @{ } -Component 'PSES bootstrap'
        $r.Control | Should -BeNullOrEmpty
        $r.Confidence | Should -BeExactly 'none'
    }
    It 'returns "none" for $null evidence (defensive)' {
        $r = Resolve-SecurityBlock -Evidence $null -Component 'PSES bootstrap'
        $r.Control | Should -BeNullOrEmpty
        $r.Confidence | Should -BeExactly 'none'
    }
    It 'returns "none" for benign, non-blocking evidence across the board' {
        $ev = @{ ExecutionPolicies = @{ MachinePolicy = 'Undefined'; CurrentUser = 'RemoteSigned' }; LanguageMode = 'FullLanguage'; SacState = 0; CodeIntegrityEvents = @(); DefenderAsrEvents = @() }
        $r = Resolve-SecurityBlock -Evidence $ev -Component 'PSES bootstrap'
        $r.Control | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-SecurityBlock -- precedence: highest-fidelity positive evidence wins (dispatch 000038)' {
    It 'a 3077 event (confirmed) outranks a concurrent CLM signal (likely) -- the event names the root policy' {
        $ev = @{ LanguageMode = 'ConstrainedLanguage'; CodeIntegrityEvents = @(@{ Id = 3077; Message = 'blocked pses-daemon.ps1' }) }
        $r = Resolve-SecurityBlock -Evidence $ev -Component 'PSES bootstrap'
        $r.Control | Should -BeExactly 'App Control / WDAC'
        $r.Confidence | Should -BeExactly 'confirmed'
    }
    It 'CLM (a current in-process fact) outranks an ExecutionPolicy GPO state when both are present' {
        $ev = @{ LanguageMode = 'ConstrainedLanguage'; ExecutionPolicies = @{ MachinePolicy = 'AllSigned' } }
        $r = Resolve-SecurityBlock -Evidence $ev -Component 'PSES bootstrap'
        $r.Control | Should -BeExactly 'Constrained Language Mode'
    }
    It 'an enforced 3077 outranks an audit 3076 in the same log' {
        $ev = @{ CodeIntegrityEvents = @(@{ Id = 3076; Message = 'audit pses-daemon.ps1' }, @{ Id = 3077; Message = 'blocked ensure-pses.ps1' }) }
        $r = Resolve-SecurityBlock -Evidence $ev -Component 'PSES bootstrap'
        $r.Confidence | Should -BeExactly 'confirmed'
    }
}

Describe 'Format-BootstrapFailureBanner -- enriched, never-silent, ASCII (dispatch 000038)' {
    It 'a named classification yields a banner that NAMES the control and keeps bootstrap+unavailable' {
        $c = Resolve-SecurityBlock -Evidence @{ LanguageMode = 'ConstrainedLanguage' } -Component 'PSES bootstrap'
        $b = Format-BootstrapFailureBanner -Classification $c -LogPath 'logs/ensure-pses.log'
        $b | Should -Match 'unavailable'                 # the never-silent surface (000024) holds
        $b | Should -Match 'bootstrap'                   # and the existing surface integration test
        $b | Should -Match 'Constrained Language Mode'   # the new attribution
        $b | Should -Match ([regex]::Escape('logs/ensure-pses.log'))
    }
    It 'the "none" fallback is an honest POINTER (check ExecutionPolicy / language mode / CodeIntegrity), not a fabricated control' {
        $c = Resolve-SecurityBlock -Evidence @{ } -Component 'PSES bootstrap'
        $b = Format-BootstrapFailureBanner -Classification $c -LogPath 'logs/ensure-pses.log'
        $b | Should -Match 'unavailable'
        $b | Should -Match 'bootstrap'
        $b | Should -Match 'Get-ExecutionPolicy -List'
        $b | Should -Match 'CodeIntegrity'
        $b | Should -Not -Match 'Constrained Language Mode is running'   # no asserted control in the fallback
    }
    It 'the confidence lead-in tracks the confidence (Cause / Likely cause / Possible cause)' {
        $confirmed = Format-BootstrapFailureBanner -Classification (Resolve-SecurityBlock -Evidence @{ CodeIntegrityEvents = @(@{ Id = 3077; Message = 'pses-daemon.ps1' }) }) -LogPath 'x'
        $likely = Format-BootstrapFailureBanner -Classification (Resolve-SecurityBlock -Evidence @{ LanguageMode = 'ConstrainedLanguage' }) -LogPath 'x'
        $possible = Format-BootstrapFailureBanner -Classification (Resolve-SecurityBlock -Evidence @{ SacState = 1 }) -LogPath 'x'
        $confirmed | Should -Match 'Cause:'
        $likely | Should -Match 'Likely cause:'
        $possible | Should -Match 'Possible cause:'
    }
    It 'every classification + banner is ASCII-only (PS 5.1 em-dash trap)' {
        $cases = @(
            (Resolve-SecurityBlock -Evidence @{ ExecutionPolicies = @{ MachinePolicy = 'AllSigned' } }),
            (Resolve-SecurityBlock -Evidence @{ LanguageMode = 'ConstrainedLanguage' }),
            (Resolve-SecurityBlock -Evidence @{ CodeIntegrityEvents = @(@{ Id = 3077; Message = 'pses-daemon.ps1' }) }),
            (Resolve-SecurityBlock -Evidence @{ DefenderAsrEvents = @(@{ Id = 1121; Message = 'ensure-pses.ps1' }) }),
            (Resolve-SecurityBlock -Evidence @{ SacState = 1 }),
            (Resolve-SecurityBlock -Evidence @{ })
        )
        foreach ($c in $cases) {
            foreach ($s in @([string]$c.Summary, [string]$c.Remediation, [string]$c.Evidence, (Format-BootstrapFailureBanner -Classification $c -LogPath 'logs/x.log'))) {
                (@([System.Text.Encoding]::UTF8.GetBytes($s) | Where-Object { $_ -gt 127 }).Count) | Should -Be 0
            }
        }
    }
}

Describe 'Security classifier -- the absolute fence: detect, never circumvent (dispatch 000038)' {
    # Every remediation must be INSTRUCTIONS for the user/admin, never an action the plugin
    # takes, and must never emit a control-modifying command. Adversarial control: put a
    # Set-ExecutionPolicy / Add-MpPreference into any remediation and this goes RED.
    It 'no remediation contains a control-MODIFYING command (Set-ExecutionPolicy / *-MpPreference / reg add)' {
        $cases = @(
            (Resolve-SecurityBlock -Evidence @{ ExecutionPolicies = @{ MachinePolicy = 'AllSigned' } }),
            (Resolve-SecurityBlock -Evidence @{ LanguageMode = 'ConstrainedLanguage' }),
            (Resolve-SecurityBlock -Evidence @{ CodeIntegrityEvents = @(@{ Id = 3077; Message = 'pses-daemon.ps1' }) }),
            (Resolve-SecurityBlock -Evidence @{ DefenderAsrEvents = @(@{ Id = 1121; Message = 'ensure-pses.ps1' }) }),
            (Resolve-SecurityBlock -Evidence @{ SacState = 1 })
        )
        foreach ($c in $cases) {
            [string]$c.Remediation | Should -Not -Match 'Set-ExecutionPolicy'
            [string]$c.Remediation | Should -Not -Match 'MpPreference'
            [string]$c.Remediation | Should -Not -Match 'reg(\.exe)?\s+add'
            # Positive framing: each names the plugin's REFUSAL to act ("will not") -- the fence in words.
            [string]$c.Remediation | Should -Match 'will not'
        }
    }
}

Describe 'Get-SecurityBlockEvidence + Resolve-SecurityBlock -- ALL probes mocked (dispatch 000038)' {
    # The live probes are best-effort glue; here EVERY probe is mocked so the gather -> classify
    # path is deterministic and the "all probes mocked" acceptance is met literally.
    It 'a mocked ConstrainedLanguage probe drives a CLM classification end to end' {
        Mock Get-ExecutionPolicyState { @{} }
        Mock Get-SessionLanguageMode { 'ConstrainedLanguage' }
        Mock Get-SmartAppControlState { $null }
        Mock Get-CodeIntegrityBlockEvents { @() }
        Mock Get-DefenderAsrBlockEvents { @() }
        $r = Resolve-SecurityBlock -Evidence (Get-SecurityBlockEvidence) -Component 'PSES bootstrap'
        $r.Control | Should -BeExactly 'Constrained Language Mode'
    }
    It 'a mocked 3077 CodeIntegrity probe drives a WDAC (confirmed) classification end to end' {
        Mock Get-ExecutionPolicyState { @{} }
        Mock Get-SessionLanguageMode { 'FullLanguage' }
        Mock Get-SmartAppControlState { $null }
        Mock Get-CodeIntegrityBlockEvents { @(@{ Id = 3077; Message = 'blocked pses-daemon.ps1' }) }
        Mock Get-DefenderAsrBlockEvents { @() }
        $r = Resolve-SecurityBlock -Evidence (Get-SecurityBlockEvidence) -Component 'PSES bootstrap'
        $r.Control | Should -BeExactly 'App Control / WDAC'
        $r.Confidence | Should -BeExactly 'confirmed'
    }
    It 'all-benign mocked probes yield the honest "none" fallback' {
        Mock Get-ExecutionPolicyState { @{ MachinePolicy = 'Undefined' } }
        Mock Get-SessionLanguageMode { 'FullLanguage' }
        Mock Get-SmartAppControlState { 0 }
        Mock Get-CodeIntegrityBlockEvents { @() }
        Mock Get-DefenderAsrBlockEvents { @() }
        $r = Resolve-SecurityBlock -Evidence (Get-SecurityBlockEvidence) -Component 'PSES bootstrap'
        $r.Control | Should -BeNullOrEmpty
        $r.Confidence | Should -BeExactly 'none'
    }
}

Describe 'Closed-loop agentic correction -- New-LifecycleFinding (dispatch 000061)' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')
        # A diagnostic record the way ConvertTo-DiagRecord builds it (an ordered hashtable).
        function New-Rec { param([int]$Line, [string]$Code, [string]$Msg = 'm')
            [ordered]@{ severity = 'Warning'; line = $Line; endLine = $Line; col = 1; source = 'PSScriptAnalyzer'; code = $Code; message = $Msg } }
    }

    It 'derives the shape-hash from ruleId + the offending file line at the record line' {
        $rec = New-Rec -Line 1 -Code 'PSUseApprovedVerbs'
        $lines = @('function Frob-X {', '    Get-Process', '}')
        $lf = New-LifecycleFinding -Record $rec -Lines $lines
        $lf.ruleId | Should -BeExactly 'PSUseApprovedVerbs'
        $lf.line | Should -Be 1
        $lf.hash | Should -BeExactly (Get-DiagnosticShapeHash -RuleId 'PSUseApprovedVerbs' -OffendingLine 'function Frob-X {')
    }

    It 'is line-position independent: the same offending text at a different line has the SAME hash (MOVED survives a shift)' {
        $top = New-LifecycleFinding -Record (New-Rec -Line 1 -Code 'R') -Lines @('gci', '# pad')
        $shifted = New-LifecycleFinding -Record (New-Rec -Line 2 -Code 'R') -Lines @('# inserted above', 'gci')
        $shifted.line | Should -Be 2                     # the line MOVED
        $shifted.hash | Should -BeExactly $top.hash      # but the identity (hash) is unchanged
    }

    It 'maps an absent/zero rule code to an empty ruleId (mirrors the dogfood derivation)' {
        (New-LifecycleFinding -Record (New-Rec -Line 1 -Code '0') -Lines @('x')).ruleId | Should -BeExactly ''
        (New-LifecycleFinding -Record (New-Rec -Line 1 -Code '') -Lines @('x')).ruleId | Should -BeExactly ''
    }

    It 'tolerates an out-of-range line (offending line empty, never throws)' {
        $lf = New-LifecycleFinding -Record (New-Rec -Line 99 -Code 'R') -Lines @('only one line')
        $lf.hash | Should -BeExactly (Get-DiagnosticShapeHash -RuleId 'R' -OffendingLine '')
    }
}

Describe 'Closed-loop agentic correction -- Get-FindingLifecycleDiff (dispatch 000061)' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')
        # A projected lifecycle finding ({ hash; ruleId; line; message }) with an EXPLICIT hash, so
        # the set logic is exercised in isolation from the hashing (which its own tests cover).
        function LF { param([string]$Hash, [string]$Rule = 'R', [int]$Line = 1, [string]$Msg = 'm')
            [pscustomobject]@{ hash = $Hash; ruleId = $Rule; line = $Line; message = $Msg } }
        # A prior-map entry the way the daemon stores it.
        function PriorEntry { param([string]$Rule = 'R', [int]$Line = 1, [string]$Msg = 'm', [int]$Attempts = 0)
            @{ ruleId = $Rule; line = $Line; message = $Msg; attempts = $Attempts } }
    }

    It 'NEW finding (empty prior): no cleared, no still-present; recorded in memory at attempts 0' {
        $diff = Get-FindingLifecycleDiff -PriorMap @{} -CurrentFull @((LF 'h1')) -CurrentSurfaced @((LF 'h1')) -ScopeApplied $true
        @($diff.Cleared).Count | Should -Be 0
        @($diff.StillPresent).Count | Should -Be 0
        $diff.NewMap.ContainsKey('h1') | Should -BeTrue
        [int]$diff.NewMap['h1']['attempts'] | Should -Be 0
    }

    It 'CLEARED: a prior-surfaced finding absent from the whole-file pass is reported cleared and dropped from memory' {
        $prior = @{ 'h1' = (PriorEntry -Rule 'PSAvoidUsingCmdletAliases' -Msg 'gci alias') }
        $diff = Get-FindingLifecycleDiff -PriorMap $prior -CurrentFull @() -CurrentSurfaced @() -ScopeApplied $true
        @($diff.Cleared).Count | Should -Be 1
        $diff.Cleared[0].ruleId | Should -BeExactly 'PSAvoidUsingCmdletAliases'
        @($diff.StillPresent).Count | Should -Be 0
        $diff.NewMap.ContainsKey('h1') | Should -BeFalse   # cleared -> forgotten
    }

    It 'STILL-PRESENT (attempt 1): a prior finding still surfaced under a determinate R escalates once, not downgraded' {
        $prior = @{ 'h1' = (PriorEntry -Attempts 0) }
        $diff = Get-FindingLifecycleDiff -PriorMap $prior -CurrentFull @((LF 'h1')) -CurrentSurfaced @((LF 'h1')) -ScopeApplied $true
        @($diff.Cleared).Count | Should -Be 0
        @($diff.StillPresent).Count | Should -Be 1
        [int]$diff.StillPresent[0].attempts | Should -Be 1
        [bool]$diff.StillPresent[0].downgraded | Should -BeFalse
        [int]$diff.NewMap['h1']['attempts'] | Should -Be 1
    }

    It 'BOUNDED escalation: attempts 1..2 escalate, attempt 3 downgrades ONCE, attempt 4+ goes silent (K=2)' {
        # attempt 2 (prior 1) -> escalate, not downgraded
        $d2 = Get-FindingLifecycleDiff -PriorMap @{ 'h1' = (PriorEntry -Attempts 1) } -CurrentFull @((LF 'h1')) -CurrentSurfaced @((LF 'h1')) -ScopeApplied $true
        @($d2.StillPresent).Count | Should -Be 1
        [int]$d2.StillPresent[0].attempts | Should -Be 2
        [bool]$d2.StillPresent[0].downgraded | Should -BeFalse
        # attempt 3 (prior 2) -> ONE neutral downgrade
        $d3 = Get-FindingLifecycleDiff -PriorMap @{ 'h1' = (PriorEntry -Attempts 2) } -CurrentFull @((LF 'h1')) -CurrentSurfaced @((LF 'h1')) -ScopeApplied $true
        @($d3.StillPresent).Count | Should -Be 1
        [int]$d3.StillPresent[0].attempts | Should -Be 3
        [bool]$d3.StillPresent[0].downgraded | Should -BeTrue
        # attempt 4 (prior 3) -> SILENCE (no entry), but memory keeps counting
        $d4 = Get-FindingLifecycleDiff -PriorMap @{ 'h1' = (PriorEntry -Attempts 3) } -CurrentFull @((LF 'h1')) -CurrentSurfaced @((LF 'h1')) -ScopeApplied $true
        @($d4.StillPresent).Count | Should -Be 0
        [int]$d4.NewMap['h1']['attempts'] | Should -Be 4
    }

    It 'NO determinate R (ScopeApplied false): a still-present finding is NOT escalated and NOT counted as an attempt' {
        $prior = @{ 'h1' = (PriorEntry -Attempts 0) }
        $diff = Get-FindingLifecycleDiff -PriorMap $prior -CurrentFull @((LF 'h1')) -CurrentSurfaced @((LF 'h1')) -ScopeApplied $false
        @($diff.StillPresent).Count | Should -Be 0
        [int]$diff.NewMap['h1']['attempts'] | Should -Be 0   # unchanged: a whole-file pass is not a counted attempt
    }

    It 'MOVED folds into still-present: the same hash at a new line is still-present (never a false cleared)' {
        # prior recorded the finding at line 5; this turn the same hash surfaces at line 8 (shifted).
        $prior = @{ 'h1' = (PriorEntry -Line 5 -Attempts 0) }
        $diff = Get-FindingLifecycleDiff -PriorMap $prior -CurrentFull @((LF 'h1' 'R' 8)) -CurrentSurfaced @((LF 'h1' 'R' 8)) -ScopeApplied $true
        @($diff.Cleared).Count | Should -Be 0                 # NOT a false cleared
        @($diff.StillPresent).Count | Should -Be 1
        [int]$diff.StillPresent[0].line | Should -Be 8        # reported at the new (moved) line
    }

    It 'CARRY-FORWARD: a prior finding still present but NOT surfaced this turn is kept in memory (so a later clear is still seen)' {
        # h1 present in full but not in the surfaced (touched) set this turn -> carried, attempts unchanged.
        $prior = @{ 'h1' = (PriorEntry -Attempts 1) }
        $diff = Get-FindingLifecycleDiff -PriorMap $prior -CurrentFull @((LF 'h1')) -CurrentSurfaced @() -ScopeApplied $true
        @($diff.Cleared).Count | Should -Be 0
        @($diff.StillPresent).Count | Should -Be 0
        $diff.NewMap.ContainsKey('h1') | Should -BeTrue
        [int]$diff.NewMap['h1']['attempts'] | Should -Be 1
    }

    It 'mixed turn: one finding clears while a new one appears (both signals correct in one pass)' {
        $prior = @{ 'hOld' = (PriorEntry -Rule 'PSUseApprovedVerbs' -Msg 'bad verb') }
        $diff = Get-FindingLifecycleDiff -PriorMap $prior -CurrentFull @((LF 'hNew' 'PSAvoidUsingCmdletAliases')) -CurrentSurfaced @((LF 'hNew' 'PSAvoidUsingCmdletAliases')) -ScopeApplied $true
        @($diff.Cleared).Count | Should -Be 1
        $diff.Cleared[0].ruleId | Should -BeExactly 'PSUseApprovedVerbs'
        @($diff.StillPresent).Count | Should -Be 0          # hNew is NEW, rides the normal surface
        $diff.NewMap.ContainsKey('hNew') | Should -BeTrue
        $diff.NewMap.ContainsKey('hOld') | Should -BeFalse
    }

    It 'StrictMode-safe on empty/null inputs (no read-before-assign, no @($null) phantom -- the 000062 class)' {
        { Get-FindingLifecycleDiff -PriorMap @{} -CurrentFull @() -CurrentSurfaced @() -ScopeApplied $true } | Should -Not -Throw
        $diff = Get-FindingLifecycleDiff -PriorMap @{} -CurrentFull @() -CurrentSurfaced @() -ScopeApplied $true
        @($diff.Cleared).Count | Should -Be 0
        @($diff.StillPresent).Count | Should -Be 0
        $diff.NewMap.Count | Should -Be 0
    }
}

# ===========================================================================
# Per-rule lifecycle persistence -- the sibling log (dispatch 000171 leg 2)
# ===========================================================================
# The cleared/still-present signal was COMPUTED and never persisted per rule, which is why the
# efficacy ledger's fixed_next_turn_rate and persistence_rate could not be derived. It now lands
# in a SIBLING log so dogfood/diagnostics.jsonl stays byte-unchanged for its two shipped readers.
Describe 'Per-rule lifecycle persistence -- sibling log (dispatch 000171 leg 2)' {

    Context 'the join key -- the EXISTING shape hash, identical on both sides by construction' {
        It 'the capture-side hash and the lifecycle-side hash MATCH over the same material' {
            # Add-DiagnosticCaptureEntries hashes (ruleId + snippet); New-LifecycleFinding hashes
            # (ruleId + offending line). Same function, same material -> joinable with no new field.
            $line = '    $x = gci -Path $env:TEMP   '
            $capture = Get-DiagnosticShapeHash -RuleId 'PSAvoidUsingCmdletAliases' -OffendingLine $line
            $lifecycle = (New-LifecycleFinding -Record @{ line = 1; code = 'PSAvoidUsingCmdletAliases'; message = 'm' } -Lines @($line)).hash
            $lifecycle | Should -BeExactly $capture
        }
        It 'the hash is STABLE across turns when the finding MOVES to another line' {
            # The hashed material carries no line NUMBER, which is what makes the join valid turn
            # over turn -- and is the same property that stops a moved finding reading as cleared.
            $line = '$x = gci .'
            $atLine1 = (New-LifecycleFinding -Record @{ line = 1; code = 'R'; message = 'm' } -Lines @($line)).hash
            $atLine3 = (New-LifecycleFinding -Record @{ line = 3; code = 'R'; message = 'm' } -Lines @('a', 'b', $line)).hash
            $atLine3 | Should -BeExactly $atLine1
        }
        It 'RED: a DIFFERENT offending line does NOT collide' {
            $a = Get-DiagnosticShapeHash -RuleId 'R' -OffendingLine '$x = gci .'
            $b = Get-DiagnosticShapeHash -RuleId 'R' -OffendingLine '$y = Get-ChildItem'
            $b | Should -Not -BeExactly $a
        }
    }

    Context 'LedgerKeys is ADDITIVE -- the daemon payload arrays are unchanged' {
        BeforeAll {
            $script:LcPrior = @{
                'h1' = @{ ruleId = 'PSUseApprovedVerbs'; line = 1; message = 'm1'; attempts = 0 }
                'h2' = @{ ruleId = 'PSAvoidUsingCmdletAliases'; line = 2; message = 'm2'; attempts = 1 }
            }
            $script:LcCur = @([pscustomobject]@{ hash = 'h2'; ruleId = 'PSAvoidUsingCmdletAliases'; line = 2; message = 'm2' })
            $script:LcDiff = Get-FindingLifecycleDiff -PriorMap $script:LcPrior -CurrentFull $script:LcCur `
                -CurrentSurfaced $script:LcCur -ScopeApplied $true
        }
        It 'cleared[] still carries exactly ruleId/line/message -- NO hash leaked onto the payload' {
            $json = (@($script:LcDiff.Cleared) | ConvertTo-Json -Depth 5 -Compress)
            $json | Should -Not -Match '"hash"'
        }
        It 'stillPresent[] still carries no hash either' {
            $json = (@($script:LcDiff.StillPresent) | ConvertTo-Json -Depth 5 -Compress)
            $json | Should -Not -Match '"hash"'
        }
        It 'LedgerKeys carries the hashes the sibling log needs' {
            @($script:LcDiff.LedgerKeys['cleared'])[0].hash | Should -BeExactly 'h1'
            @($script:LcDiff.LedgerKeys['stillPresent'])[0].hash | Should -BeExactly 'h2'
        }
    }

    Context 'records are PER RULE -- which is what bounds the per-turn growth rate' {
        It 'two rules produce two records, sorted by ruleId (no ranking)' {
            $keys = @{
                cleared      = @([pscustomobject]@{ hash = 'h1'; ruleId = 'PSUseApprovedVerbs' })
                stillPresent = @([pscustomobject]@{ hash = 'h2'; ruleId = 'PSAvoidUsingCmdletAliases'; attempts = 2; downgraded = $false })
            }
            $recs = @(New-LifecycleLedgerRecords -LedgerKeys $keys -File 'f.ps1' -Timestamp 't' -ScopeApplied $true)
            $recs.Count | Should -Be 2
            [string]$recs[0].ruleId | Should -BeExactly 'PSAvoidUsingCmdletAliases'
            [string]$recs[1].ruleId | Should -BeExactly 'PSUseApprovedVerbs'
        }
        It 'MANY findings of ONE rule collapse to ONE record (the cardinality bound)' {
            $keys = @{ cleared = @(1..40 | ForEach-Object { [pscustomobject]@{ hash = ('h' + $_); ruleId = 'PSUseApprovedVerbs' } }); stillPresent = @() }
            $recs = @(New-LifecycleLedgerRecords -LedgerKeys $keys -File 'f.ps1' -Timestamp 't' -ScopeApplied $true)
            $recs.Count | Should -Be 1
            [int]$recs[0].cleared | Should -Be 40
        }
        It 'a turn with NO lifecycle event writes NOTHING (not an empty record)' {
            $recs = @(New-LifecycleLedgerRecords -LedgerKeys @{ cleared = @(); stillPresent = @() } -File 'f.ps1' -Timestamp 't' -ScopeApplied $true)
            $recs.Count | Should -Be 0
        }
        It 'StrictMode-safe on a null LedgerKeys' {
            { New-LifecycleLedgerRecords -LedgerKeys $null -File 'f.ps1' -Timestamp 't' -ScopeApplied $true } | Should -Not -Throw
        }
    }

    Context 'FAIL OPEN -- proven by fault injection, never by inspection' {
        It 'a normal write succeeds' {
            $p = Join-Path $TestDrive 'lifecycle-20260731-000000-000.jsonl'
            $env:POWERSHELL_LSP_LIFECYCLE_LOG = $p
            try {
                $recs = @(New-LifecycleLedgerRecords -LedgerKeys @{ cleared = @([pscustomobject]@{ hash = 'h'; ruleId = 'R' }); stillPresent = @() } `
                        -File 'f.ps1' -Timestamp 't' -ScopeApplied $true)
                Add-LifecycleLedgerEntries -Records $recs -Stamp 's' | Should -BeTrue
                Test-Path -LiteralPath $p | Should -BeTrue
            } finally { $env:POWERSHELL_LSP_LIFECYCLE_LOG = $null }
        }
        It 'an EXCLUSIVELY-HELD log fails SOFT: returns $false and never throws' {
            $p = Join-Path $TestDrive 'lifecycle-locked.jsonl'
            [System.IO.File]::WriteAllText($p, '')
            $env:POWERSHELL_LSP_LIFECYCLE_LOG = $p
            $fs = [System.IO.File]::Open($p, 'Open', 'ReadWrite', 'None')
            try {
                $recs = @(New-LifecycleLedgerRecords -LedgerKeys @{ cleared = @([pscustomobject]@{ hash = 'h'; ruleId = 'R' }); stillPresent = @() } `
                        -File 'f.ps1' -Timestamp 't' -ScopeApplied $true)
                { Add-LifecycleLedgerEntries -Records $recs -Stamp 's' } | Should -Not -Throw
                Add-LifecycleLedgerEntries -Records $recs -Stamp 's' | Should -BeFalse
            } finally {
                $fs.Close(); $fs.Dispose(); $env:POWERSHELL_LSP_LIFECYCLE_LOG = $null
            }
        }
        It 'an UNRESOLVABLE path fails SOFT rather than throwing' {
            $env:POWERSHELL_LSP_LIFECYCLE_LOG = $null
            # No stamp and no override -> no path can be built. Must degrade, not throw.
            $recs = @(New-LifecycleLedgerRecords -LedgerKeys @{ cleared = @([pscustomobject]@{ hash = 'h'; ruleId = 'R' }); stillPresent = @() } `
                    -File 'f.ps1' -Timestamp 't' -ScopeApplied $true)
            { Add-LifecycleLedgerEntries -Records $recs -Stamp '' } | Should -Not -Throw
            Add-LifecycleLedgerEntries -Records $recs -Stamp '' | Should -BeFalse
        }
        It 'an EMPTY record set is a SUCCESS that writes nothing (a clean turn is not a failure)' {
            Add-LifecycleLedgerEntries -Records @() -Stamp '' | Should -BeTrue
        }
    }

    Context 'BOUNDED retention -- the log joins the EXISTING keepLastN rotation family' {
        It 'a stamped lifecycle name collapses to a family stem under the SHIPPED sweep regex' {
            # Invoke-LogSweep (scripts/session-start.ps1) groups by this exact substitution and keeps
            # the newest keepLastN per stem. Matching it is what makes retention bounded with NO new
            # sweep code.
            $stem = [System.Text.RegularExpressions.Regex]::Replace('lifecycle-20260731-215959-123.jsonl', '-\d{8}-\d{6}-\d{3}', '-STAMP')
            $stem | Should -BeExactly 'lifecycle-STAMP.jsonl'
        }
        It 'RED: an UNSTAMPED name would NOT be swept -- so the stamp is load-bearing' {
            $stem = [System.Text.RegularExpressions.Regex]::Replace('lifecycle.jsonl', '-\d{8}-\d{6}-\d{3}', '-STAMP')
            $stem | Should -BeExactly 'lifecycle.jsonl'
        }
        It 'Get-LifecycleLogPath honors the env override verbatim, and needs a stamp otherwise' {
            $env:POWERSHELL_LSP_LIFECYCLE_LOG = 'C:\explicit\path.jsonl'
            try { Get-LifecycleLogPath -Stamp 'ignored' | Should -BeExactly 'C:\explicit\path.jsonl' }
            finally { $env:POWERSHELL_LSP_LIFECYCLE_LOG = $null }
            Get-LifecycleLogPath -Stamp '' | Should -BeExactly ''
        }
    }

    Context 'the CAPTURE record shape is untouched -- the pre-ruled sibling-log constraint' {
        It 'a capture record still carries EXACTLY the shipped keys, in the shipped order' {
            $log = Join-Path $TestDrive ('cap-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.jsonl')
            $src = Join-Path $TestDrive 'capsrc.ps1'
            [System.IO.File]::WriteAllText($src, "function Frobnicate-X { }`n")
            $env:POWERSHELL_LSP_DOGFOOD_LOG = $log
            try {
                Add-DiagnosticCaptureEntries -File $src -Records @(@{ line = 1; col = 10; ruleId = 'PSUseApprovedVerbs'
                        source = 'PSScriptAnalyzer'; severity = 'Warning'; message = 'm' })
            } finally { $env:POWERSHELL_LSP_DOGFOOD_LOG = $null }
            $keys = @((Get-Content -LiteralPath $log -Raw).Trim() | ConvertFrom-Json |
                    ForEach-Object { $_.PSObject.Properties } | ForEach-Object { $_.Name })
            ($keys -join ',') | Should -BeExactly 'ts,file,line,col,ruleId,source,severity,message,snippet,hash,verdict'
        }
    }
}

# ===========================================================================
# pre-push guard -- refuse a direct push to origin/main (dispatch 000080)
# ===========================================================================
# The guard (scripts/pre-push-guard.ps1) makes the PR-and-HOLD discipline a refusal on the
# developer's machine: a push that UPDATES refs/heads/main on origin is refused; every other
# push (a feature branch, a tag, a delete, a fork remote) passes through; a deliberate
# override (a non-empty reason) is allowed AND audited. The script is dot-source safe (the
# doctor.ps1 pattern), so these drive the PURE decision and the audit writer directly -- no
# git, no network, I/O only into TestDrive. The git hook hooks/pre-push is the thin POSIX sh
# shim that forwards the push refspec (stdin) + remote name/url (argv) into this guard; that
# the hook fires from a LINKED worktree is proven end-to-end outside the suite (it needs a
# real `git push`), and this asserts the decision the shim trusts.

Describe 'pre-push guard refuses a direct push to origin/main (dispatch 000080)' {
    BeforeAll {
        . (Join-Path $script:ScriptsDir 'pre-push-guard.ps1')
        $script:GuardOriginUrl = 'https://github.com/manderse21/claude-powershell-lsp.git'
        $script:GuardZeroSha = '0000000000000000000000000000000000000000'

        # One pre-push stdin line: "<localref> <localsha> <remoteref> <remotesha>".
        function New-PushSpecLine {
            param(
                [string] $RemoteRef,
                [string] $LocalSha = 'aaaa111122223333444455556666777788889999',
                [string] $RemoteSha = '0000000000000000000000000000000000000000',
                [string] $LocalRef = 'refs/heads/work'
            )
            return ('{0} {1} {2} {3}' -f $LocalRef, $LocalSha, $RemoteRef, $RemoteSha)
        }
    }

    Context 'refuse-on-main' {
        It 'refuses a push that updates refs/heads/main on origin (matched by remote NAME)' {
            $r = Resolve-PushToMainGuard -RemoteName 'origin' -RemoteUrl $script:GuardOriginUrl `
                -OriginUrl $script:GuardOriginUrl `
                -PushSpecLines @((New-PushSpecLine -RemoteRef 'refs/heads/main')) -OverrideReason ''
            $r.Decision | Should -BeExactly 'refuse'
            $r.IsOrigin | Should -BeTrue
            $r.TargetsMain | Should -BeTrue
            $r.Blocks | Should -BeTrue
            $r.Sha | Should -BeExactly 'aaaa111122223333444455556666777788889999'
            $r.TargetRef | Should -BeExactly 'refs/heads/main'
        }
        It 'refuses when the remote is named by origin URL even though the NAME is not "origin"' {
            # `git push <origin-url> main` -- name match misses, URL match catches it.
            $r = Resolve-PushToMainGuard -RemoteName $script:GuardOriginUrl -RemoteUrl $script:GuardOriginUrl `
                -OriginUrl $script:GuardOriginUrl `
                -PushSpecLines @((New-PushSpecLine -RemoteRef 'refs/heads/main')) -OverrideReason ''
            $r.Decision | Should -BeExactly 'refuse'
            $r.IsOrigin | Should -BeTrue
        }
    }

    Context 'pass-throughs -- the refusal stays narrow (every other push is untouched)' {
        It 'allows a push to a feature branch on origin (the dispatch own branch is the live example)' {
            $r = Resolve-PushToMainGuard -RemoteName 'origin' -RemoteUrl $script:GuardOriginUrl `
                -OriginUrl $script:GuardOriginUrl `
                -PushSpecLines @((New-PushSpecLine -RemoteRef 'refs/heads/dispatch-000080-pre-push-guard')) -OverrideReason ''
            $r.Decision | Should -BeExactly 'allow'
            $r.TargetsMain | Should -BeFalse
        }
        It 'allows a tag push on origin' {
            $r = Resolve-PushToMainGuard -RemoteName 'origin' -RemoteUrl $script:GuardOriginUrl `
                -OriginUrl $script:GuardOriginUrl `
                -PushSpecLines @((New-PushSpecLine -RemoteRef 'refs/tags/v1.2.3')) -OverrideReason ''
            $r.Decision | Should -BeExactly 'allow'
            $r.TargetsMain | Should -BeFalse
        }
        It 'allows a DELETE of origin/main -- an all-zero local sha is a delete, not an update' {
            $r = Resolve-PushToMainGuard -RemoteName 'origin' -RemoteUrl $script:GuardOriginUrl `
                -OriginUrl $script:GuardOriginUrl `
                -PushSpecLines @((New-PushSpecLine -RemoteRef 'refs/heads/main' -LocalSha $script:GuardZeroSha -LocalRef '(delete)')) `
                -OverrideReason ''
            $r.Decision | Should -BeExactly 'allow'
            $r.TargetsMain | Should -BeFalse
        }
        It 'allows a push of main to a FORK remote (a different NAME and a different URL)' {
            $r = Resolve-PushToMainGuard -RemoteName 'fork' -RemoteUrl 'https://example.com/fork.git' `
                -OriginUrl $script:GuardOriginUrl `
                -PushSpecLines @((New-PushSpecLine -RemoteRef 'refs/heads/main')) -OverrideReason ''
            $r.Decision | Should -BeExactly 'allow'
            $r.IsOrigin | Should -BeFalse
        }
    }

    Context 'allow-with-override (+ audit line written)' {
        It 'allows the push to origin/main when a non-empty reason is set, and marks it overridden' {
            $r = Resolve-PushToMainGuard -RemoteName 'origin' -RemoteUrl $script:GuardOriginUrl `
                -OriginUrl $script:GuardOriginUrl `
                -PushSpecLines @((New-PushSpecLine -RemoteRef 'refs/heads/main')) `
                -OverrideReason 'deliberate one-off: ship the v1.18.1 hotfix'
            $r.Decision | Should -BeExactly 'allow'
            $r.Blocks | Should -BeTrue        # it WOULD refuse...
            $r.Overridden | Should -BeTrue    # ...but the explicit reason flips it to allow
        }
        It 'does NOT override on an unset / empty / whitespace-only reason (the refusal stands)' {
            foreach ($reason in @('', '   ', "`t")) {
                $r = Resolve-PushToMainGuard -RemoteName 'origin' -RemoteUrl $script:GuardOriginUrl `
                    -OriginUrl $script:GuardOriginUrl `
                    -PushSpecLines @((New-PushSpecLine -RemoteRef 'refs/heads/main')) -OverrideReason $reason
                $r.Decision | Should -BeExactly 'refuse' -Because "reason '$reason' is empty-ish and must not override"
            }
        }
        It 'writes an audit line (UTC time, reason, sha, target ref) to the bypass log' {
            $log = Join-Path $TestDrive ('bypass-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.log')
            $line = Add-PushToMainAuditLine -Path $log -Reason 'ship v1.18.1 hotfix' `
                -Sha 'aaaa111122223333' -TargetRef 'refs/heads/main' -RemoteName 'origin'
            Test-Path -LiteralPath $log | Should -BeTrue
            $written = Get-Content -LiteralPath $log -Raw
            $written | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z'   # leading UTC timestamp
            $written | Should -Match 'OVERRIDE'
            $written | Should -Match 'ship v1\.18\.1 hotfix'                   # reason
            $written | Should -Match 'aaaa111122223333'                        # sha
            $written | Should -Match 'origin refs/heads/main'                  # remote + target ref
            $line | Should -BeExactly ($written.TrimEnd("`r", "`n"))           # returns exactly what it wrote
        }
        It 'appends (never overwrites) and flattens a multi-line reason to ONE record (no log forging)' {
            $log = Join-Path $TestDrive ('bypass-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.log')
            Add-PushToMainAuditLine -Path $log -Reason 'first push' -Sha 'sha1' -TargetRef 'refs/heads/main' -RemoteName 'origin' | Out-Null
            # A newline in the reason must NOT forge a second audit record.
            Add-PushToMainAuditLine -Path $log -Reason "second push`ninjected-second-line" -Sha 'sha2' -TargetRef 'refs/heads/main' -RemoteName 'origin' | Out-Null
            $lines = @(Get-Content -LiteralPath $log | Where-Object { $_ -ne '' })
            $lines.Count | Should -Be 2
            $lines[1] | Should -Match 'second push injected-second-line'       # flattened onto one line
        }
    }

    Context 'audit log path resolution' {
        It 'honors the POWERSHELL_LSP_PUSH_AUDIT_LOG override path verbatim' {
            Get-PushAuditLogPath -GitCommonDir '/x/.git' -OverridePath '/tmp/custom-bypass.log' |
                Should -BeExactly '/tmp/custom-bypass.log'
        }
        It 'defaults to the bypass log inside the git common dir when no override is set' {
            Get-PushAuditLogPath -GitCommonDir '/x/.git' -OverridePath '' |
                Should -Match 'powershell-lsp-push-to-main-bypass\.log$'
        }
    }
}

# --- E2.2 org policy layer (dispatch 000142) -------------------------------
# Three families, exactly as the 000135 execution-ready plan specifies:
#   (a) off-byte-identical  -- with the knob unset the layer is the identity function
#   (b) precedence matrix   -- org-exclude WINS on the exclude path, repo-local WINS on
#                              the include path (the asymmetry that IS the design)
#   (c) unreadable-path degrade -- @() plus ONE warning, never a throw (fail open)

Describe 'Org policy -- off is byte-identical (dispatch 000142)' {
    BeforeAll {
        # Every record shape the client's diagnostics stream actually mixes: a JSON-parsed
        # daemon record, a pre-PSSA finding, the [ordered] shape ConvertTo-DiagRecord returns,
        # and a record naming no rule at all.
        $script:MixedRecords = @(
            [pscustomobject]@{ severity = 'Warning'; line = 3; col = 5; source = 'PSScriptAnalyzer'; code = 'PSUseApprovedVerbs'; message = 'verb' }
            [pscustomobject]@{ severity = 'Warning'; line = 1; col = 1; source = 'powershell-lsp'; ruleId = 'NonAsciiChar'; code = 'NonAsciiChar'; message = 'dash' }
            (ConvertTo-DiagRecord ([pscustomobject]@{ range = [pscustomobject]@{ start = [pscustomobject]@{ line = 0; character = 0 }; end = [pscustomobject]@{ line = 0; character = 4 } }; severity = 2; source = 'PSScriptAnalyzer'; code = 'PSAvoidUsingCmdletAliases'; message = 'alias' }))
            [pscustomobject]@{ severity = 'Error'; line = 9; col = 2; source = ''; message = 'unexpected token' }
        )
    }
    It 'the knob unset yields NO org constraint (the client short-circuits before the filter)' {
        # This is the gate that makes every other off-path claim true: with orgPolicy empty the
        # loader returns @(), so lsp-client's $OrgExcludes.Count -gt 0 guard never even calls
        # the filter. Adversarial control: return a non-empty list for '' and this goes RED.
        @(Import-OrgPolicyExcludes -Path '').Count | Should -Be 0
        @(Import-OrgPolicyExcludes -Path '   ').Count | Should -Be 0
    }
    It 'is the identity function over every record shape when no org rules are excluded' {
        $before = ($script:MixedRecords | ConvertTo-Json -Depth 8 -Compress)
        $after = (@(Select-OrgPolicyFiltered -Records $script:MixedRecords -OrgExclude @()) | ConvertTo-Json -Depth 8 -Compress)
        $after | Should -BeExactly $before
    }
    It 'treats a list of blank/empty exclusions as no constraint (identity, not a wipe)' {
        $before = ($script:MixedRecords | ConvertTo-Json -Depth 8 -Compress)
        $after = (@(Select-OrgPolicyFiltered -Records $script:MixedRecords -OrgExclude @('', '   ')) | ConvertTo-Json -Depth 8 -Compress)
        $after | Should -BeExactly $before
    }
    It 'is identity over the REAL corpus expected-records, and provably not vacuously so' {
        # Real data, not a fixture: every expected corpus record the repo ships. The second
        # assertion is the vacuous-pass guard -- if the filter silently matched nothing (e.g. a
        # shape regression in Get-DiagnosticRuleCode), the identity claim above would still pass
        # while enforcement was dead. Excluding a rule the corpus really contains MUST drop it.
        $expectedDir = Join-Path $script:PluginRoot 'tests/corpus/expected'
        $records = @()
        foreach ($f in @(Get-ChildItem -LiteralPath $expectedDir -Recurse -Filter '*.json')) {
            $parsed = (Get-Content -LiteralPath $f.FullName -Raw) | ConvertFrom-Json
            foreach ($r in @($parsed)) { if ($null -ne $r) { $records += $r } }
        }
        $records.Count | Should -BeGreaterThan 0
        $before = ($records | ConvertTo-Json -Depth 8 -Compress)
        (@(Select-OrgPolicyFiltered -Records $records -OrgExclude @()) | ConvertTo-Json -Depth 8 -Compress) |
            Should -BeExactly $before
        # Non-vacuous: pick a rule the corpus actually carries and prove it drops.
        $aRule = @($records | ForEach-Object { Get-DiagnosticRuleCode $_ } | Where-Object { $_ } | Select-Object -First 1)[0]
        $aRule | Should -Not -BeNullOrEmpty
        $dropped = @(Select-OrgPolicyFiltered -Records $records -OrgExclude @($aRule))
        $dropped.Count | Should -BeLessThan $records.Count
        @($dropped | Where-Object { (Get-DiagnosticRuleCode $_) -eq $aRule }).Count | Should -Be 0
    }
}

Describe 'Org policy -- precedence matrix (dispatch 000142)' {
    BeforeAll {
        # The pipeline SHAPE the client really runs: the local filter (repo-local settings and
        # the ruleInclude/ruleExclude knobs, applied by the daemon via Select-FilteredDiagnostics)
        # and THEN the org drop. Composing the two shipped functions -- rather than asserting on
        # a hand-rolled stand-in -- is what makes this a precedence proof and not a tautology.
        function Invoke-OrgPipeline {
            param([object[]]$Records, [string[]]$LocalInclude = @(), [string[]]$LocalExclude = @(), [string[]]$OrgExclude = @())
            $local = @(Select-FilteredDiagnostics -Records $Records -Threshold 'Hint' -Include $LocalInclude -Exclude $LocalExclude)
            return @(Select-OrgPolicyFiltered -Records $local -OrgExclude $OrgExclude)
        }
        $script:Rec = @(
            [pscustomobject]@{ severity = 'Warning'; line = 1; col = 1; source = 'PSScriptAnalyzer'; code = 'PSUseApprovedVerbs'; message = 'a' }
            [pscustomobject]@{ severity = 'Warning'; line = 2; col = 1; source = 'PSScriptAnalyzer'; code = 'PSAvoidUsingCmdletAliases'; message = 'b' }
            [pscustomobject]@{ severity = 'Warning'; line = 3; col = 1; source = 'PSScriptAnalyzer'; code = 'PSAvoidUsingWriteHost'; message = 'c' }
        )
    }

    # --- the EXCLUDE path: org wins, unconditionally -----------------------
    It 'org exclude WINS over an explicit local ruleInclude of the same rule' {
        # The load-bearing case. A repo says "report ONLY PSUseApprovedVerbs"; the org says
        # "never report PSUseApprovedVerbs". The org wins and the surface is empty.
        $out = Invoke-OrgPipeline -Records $script:Rec -LocalInclude @('PSUseApprovedVerbs') -OrgExclude @('PSUseApprovedVerbs')
        $out.Count | Should -Be 0
    }
    It 'org exclude WINS over a repo-local surface that contains the rule' {
        $out = Invoke-OrgPipeline -Records $script:Rec -OrgExclude @('PSAvoidUsingCmdletAliases')
        @($out | ForEach-Object { Get-DiagnosticRuleCode $_ }) | Should -Not -Contain 'PSAvoidUsingCmdletAliases'
        $out.Count | Should -Be 2
    }
    It 'org exclude composes with a local exclude rather than replacing it' {
        $out = Invoke-OrgPipeline -Records $script:Rec -LocalExclude @('PSAvoidUsingWriteHost') -OrgExclude @('PSUseApprovedVerbs')
        @($out | ForEach-Object { Get-DiagnosticRuleCode $_ }) | Should -Be @('PSAvoidUsingCmdletAliases')
    }
    It 'org exclude matches a rule code case-insensitively (as PSScriptAnalyzer does)' {
        $out = Invoke-OrgPipeline -Records $script:Rec -OrgExclude @('psuseapprovedverbs')
        @($out | ForEach-Object { Get-DiagnosticRuleCode $_ }) | Should -Not -Contain 'PSUseApprovedVerbs'
    }
    It 'org exclude drops a rule delivered as an ordered-hashtable record (no shape hole)' {
        # ConvertTo-DiagRecord returns [ordered]@{...}; Get-Prop cannot see dictionary keys, so
        # without the IDictionary branch in Get-DiagnosticRuleCode an org exclusion would
        # SILENTLY stop enforcing on this shape. Non-enforcement must never be silent.
        $ordered = @([ordered]@{ severity = 'Warning'; line = 1; col = 1; source = 'PSScriptAnalyzer'; code = 'PSUseApprovedVerbs'; message = 'a' })
        @(Select-OrgPolicyFiltered -Records $ordered -OrgExclude @('PSUseApprovedVerbs')).Count | Should -Be 0
    }
    It 'org exclude matches on ruleId when that is the only rule field present' {
        $byRuleId = @([pscustomobject]@{ severity = 'Warning'; line = 1; col = 1; source = 'powershell-lsp'; ruleId = 'NonAsciiChar'; message = 'dash' })
        @(Select-OrgPolicyFiltered -Records $byRuleId -OrgExclude @('NonAsciiChar')).Count | Should -Be 0
    }

    # --- the INCLUDE path: repo-local wins, org IncludeRules stay advisory ---
    It 'repo-local WINS the include path: a local ruleInclude survives an org policy with no exclusions' {
        $out = Invoke-OrgPipeline -Records $script:Rec -LocalInclude @('PSUseApprovedVerbs') -OrgExclude @()
        @($out | ForEach-Object { Get-DiagnosticRuleCode $_ }) | Should -Be @('PSUseApprovedVerbs')
    }
    It 'repo-local WINS the include path: an org policy cannot force a locally-excluded rule back on' {
        # The asymmetry, stated as a test: the org can take a rule AWAY, it cannot put one BACK.
        # A policy declaring IncludeRules for a rule the repo excluded leaves it excluded.
        $policy = Join-Path $TestDrive ('orgpol-adv-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.psd1')
        Set-Content -LiteralPath $policy -Encoding ascii -Value "@{ IncludeRules = @('PSAvoidUsingWriteHost'); ExcludeRules = @('PSUseApprovedVerbs') }"
        $orgExcl = @(Import-OrgPolicyExcludes -Path $policy)
        $orgExcl | Should -Be @('PSUseApprovedVerbs')            # ONLY ExcludeRules are lifted
        $out = Invoke-OrgPipeline -Records $script:Rec -LocalExclude @('PSAvoidUsingWriteHost') -OrgExclude $orgExcl
        @($out | ForEach-Object { Get-DiagnosticRuleCode $_ }) | Should -Be @('PSAvoidUsingCmdletAliases')
    }
    It 'never drops a record that carries no rule code (a parser error is not a rule)' {
        $withParser = @([pscustomobject]@{ severity = 'Error'; line = 9; col = 2; source = ''; message = 'unexpected token' })
        @(Select-OrgPolicyFiltered -Records $withParser -OrgExclude @('PSUseApprovedVerbs')).Count | Should -Be 1
    }
    It 'preserves the order of the surviving records' {
        $out = Invoke-OrgPipeline -Records $script:Rec -OrgExclude @('PSAvoidUsingCmdletAliases')
        @($out | ForEach-Object { Get-DiagnosticRuleCode $_ }) | Should -Be @('PSUseApprovedVerbs', 'PSAvoidUsingWriteHost')
    }
}

Describe 'Org policy -- fail-open degrade (dispatch 000142)' {
    It 'lifts ExcludeRules from a well-formed policy, trimmed and de-duplicated' {
        $policy = Join-Path $TestDrive ('orgpol-ok-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.psd1')
        Set-Content -LiteralPath $policy -Encoding ascii -Value "@{ ExcludeRules = @('  PSUseApprovedVerbs  ', 'PSAvoidUsingWriteHost', 'PSUseApprovedVerbs') }"
        $w = ''
        $out = @(Import-OrgPolicyExcludes -Path $policy -WarningOut ([ref]$w))
        $out | Should -Be @('PSUseApprovedVerbs', 'PSAvoidUsingWriteHost')
        $w | Should -BeExactly ''                                 # a good policy warns about nothing
    }
    It 'ignores blank and non-string entries in the rule list' {
        $policy = Join-Path $TestDrive ('orgpol-junk-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.psd1')
        Set-Content -LiteralPath $policy -Encoding ascii -Value "@{ ExcludeRules = @('PSUseApprovedVerbs', '', '   ', 42, @{ nested = 'x' }) }"
        @(Import-OrgPolicyExcludes -Path $policy) | Should -Be @('PSUseApprovedVerbs')
    }
    It 'a readable policy declaring NO ExcludeRules is a valid no-op, not a degrade' {
        $policy = Join-Path $TestDrive ('orgpol-empty-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.psd1')
        Set-Content -LiteralPath $policy -Encoding ascii -Value "@{ IncludeRules = @('PSUseApprovedVerbs') }"
        $w = ''
        @(Import-OrgPolicyExcludes -Path $policy -WarningOut ([ref]$w)).Count | Should -Be 0
        $w | Should -BeExactly ''
    }
    It 'a MISSING policy file degrades to @() with ONE warning and never throws' {
        $missing = Join-Path $TestDrive ('orgpol-missing-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.psd1')
        $w = ''
        { @(Import-OrgPolicyExcludes -Path $missing -WarningOut ([ref]$w)) } | Should -Not -Throw
        @(Import-OrgPolicyExcludes -Path $missing -WarningOut ([ref]$w)).Count | Should -Be 0
        $w | Should -Match 'not found'
        @($w -split "`n").Count | Should -Be 1                    # exactly ONE warning, not a stream
    }
    It 'an UNPARSEABLE policy file degrades to @() with ONE warning and never throws' {
        # The arbitrary-code guard doubles as the malformed guard: Import-PowerShellDataFile
        # parses in RESTRICTED language mode, so a policy containing a command invocation does
        # not execute -- it fails to parse, and that failure lands here as a degrade.
        $policy = Join-Path $TestDrive ('orgpol-bad-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.psd1')
        Set-Content -LiteralPath $policy -Encoding ascii -Value "@{ ExcludeRules = @( this is not valid psd1 <<<"
        $w = ''
        { @(Import-OrgPolicyExcludes -Path $policy -WarningOut ([ref]$w)) } | Should -Not -Throw
        @(Import-OrgPolicyExcludes -Path $policy -WarningOut ([ref]$w)).Count | Should -Be 0
        $w | Should -Match 'could not be read'
    }
    It 'a policy that tries to RUN something is refused by the restricted parser, not executed' {
        # Proves the safety claim in the function header rather than asserting it in prose: the
        # sentinel file the policy would create must NOT exist afterwards.
        $sentinel = Join-Path $TestDrive ('orgpol-sentinel-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
        $policy = Join-Path $TestDrive ('orgpol-exec-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.psd1')
        Set-Content -LiteralPath $policy -Encoding ascii -Value ("@{ ExcludeRules = @( (New-Item -ItemType File -Path '" + $sentinel + "') ) }")
        $w = ''
        { @(Import-OrgPolicyExcludes -Path $policy -WarningOut ([ref]$w)) } | Should -Not -Throw
        Test-Path -LiteralPath $sentinel | Should -BeFalse
    }
    It 'a RELATIVE policy path is a WARNED degrade, never silent' {
        $w = ''
        @(Import-OrgPolicyExcludes -Path 'org/policy.psd1' -WarningOut ([ref]$w)).Count | Should -Be 0
        $w | Should -Match 'not absolute'
    }
    It 'tolerates a caller that passes no warning sink at all' {
        { @(Import-OrgPolicyExcludes -Path 'org/policy.psd1') } | Should -Not -Throw
    }
}

Describe 'Org policy -- integrity gate (dispatch 000259, threat T4.1)' {
    # orgPolicy is the outermost precedence layer and its ExcludeRules are a final subtractive
    # drop no local setting can re-add, so WRITE access to the policy file is control over what
    # the analyzer enforces fleet-wide. The gate closes that: a '<policy>.sha256' artifact
    # DISCOVERED from the policy path (never configured -- no new userConfig key) must be
    # satisfied before any exclusion is lifted.
    #
    # The three chartered cases are the first three Its: satisfied, violated, absent. The rest
    # pin the degrade shape, which is the half an integrity gate gets wrong: a gate that waves
    # through what it cannot check is not a gate.

    BeforeEach {
        $script:OP_Dir = Join-Path $TestDrive `
            ('opi-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:OP_Dir -Force | Out-Null
        $script:OP_Policy = Join-Path $script:OP_Dir 'PSScriptAnalyzerSettings.psd1'
        Set-Content -LiteralPath $script:OP_Policy -Encoding ascii `
            -Value "@{ ExcludeRules = @('PSUseApprovedVerbs') }"
        $script:OP_Sidecar = $script:OP_Policy + '.sha256'
    }

    It 'integrity SATISFIED: the org exclusions are applied exactly as before the gate' {
        Set-Content -LiteralPath $script:OP_Sidecar -Encoding ascii `
            -Value (Get-FileHash -Algorithm SHA256 -LiteralPath $script:OP_Policy).Hash
        $w = ''
        @(Import-OrgPolicyExcludes -Path $script:OP_Policy -WarningOut ([ref]$w)) |
            Should -Be @('PSUseApprovedVerbs')
        $w | Should -BeExactly ''                      # a verified policy warns about nothing
    }

    It 'integrity VIOLATED: NO exclusions, and the ONE warning names the failure in the log' {
        # The acceptance proof reads the warning TEXT rather than merely asserting the exclusion
        # list is empty -- @() is also what a perfectly valid no-op policy returns, so absence of
        # exclusions alone cannot tell enforcement-stopped from nothing-to-enforce.
        Set-Content -LiteralPath $script:OP_Sidecar -Encoding ascii `
            -Value (Get-FileHash -Algorithm SHA256 -LiteralPath $script:OP_Policy).Hash
        Set-Content -LiteralPath $script:OP_Policy -Encoding ascii `
            -Value "@{ ExcludeRules = @('PSUseApprovedVerbs', 'PSAvoidUsingWriteHost') }"
        $w = ''
        @(Import-OrgPolicyExcludes -Path $script:OP_Policy -WarningOut ([ref]$w)).Count |
            Should -Be 0
        $w | Should -Match 'integrity check FAILED'
        $w | Should -Match 'no org exclusions applied'
        @($w -split "`n").Count | Should -Be 1         # exactly ONE warning, not a stream
    }

    It 'integrity artifact ABSENT: behavior is unchanged -- exclusions applied, nothing warned' {
        # Pure opt-in. This is the byte-for-byte pre-slice path, and it is the case that must
        # hold for every existing deployment that never adds a digest.
        Test-Path -LiteralPath $script:OP_Sidecar | Should -BeFalse
        $w = ''
        @(Import-OrgPolicyExcludes -Path $script:OP_Policy -WarningOut ([ref]$w)) |
            Should -Be @('PSUseApprovedVerbs')
        $w | Should -BeExactly ''
    }

    It 'accepts the sha256sum shape (<hash> *<name>), not just a bare digest' {
        $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $script:OP_Policy).Hash
        Set-Content -LiteralPath $script:OP_Sidecar -Encoding ascii `
            -Value ($h + ' *PSScriptAnalyzerSettings.psd1')
        $w = ''
        @(Import-OrgPolicyExcludes -Path $script:OP_Policy -WarningOut ([ref]$w)) |
            Should -Be @('PSUseApprovedVerbs')
        $w | Should -BeExactly ''
    }

    It 'a sidecar declaring NO digest is UNSATISFIABLE and degrades, not treated as absent' {
        Set-Content -LiteralPath $script:OP_Sidecar -Encoding ascii -Value 'not a hash at all'
        $w = ''
        @(Import-OrgPolicyExcludes -Path $script:OP_Policy -WarningOut ([ref]$w)).Count |
            Should -Be 0
        $w | Should -Match 'declares no SHA-256 digest'
    }

    It 'a 65-hex-character run is MALFORMED, not a digest matched on its first 64 characters' {
        # The boundary-guard RED control. Without the (?<!hex)/(?!hex) lookarounds the regex would
        # match the first 64 characters of an over-long run, reporting a malformed expectation as
        # a satisfied one -- the exact direction an integrity gate must never fail in.
        $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $script:OP_Policy).Hash
        Set-Content -LiteralPath $script:OP_Sidecar -Encoding ascii -Value ($h + 'a')
        $w = ''
        @(Import-OrgPolicyExcludes -Path $script:OP_Policy -WarningOut ([ref]$w)).Count |
            Should -Be 0
        $w | Should -Match 'declares no SHA-256 digest'
    }

    It 'the gate NEVER throws -- fail-open survives every sidecar shape' {
        foreach ($v in @('', '   ', 'zz', ('0' * 64), "`0bad")) {
            Set-Content -LiteralPath $script:OP_Sidecar -Encoding ascii -Value $v
            $sink = ''
            { @(Import-OrgPolicyExcludes -Path $script:OP_Policy `
                        -WarningOut ([ref]$sink)) } | Should -Not -Throw
        }
    }

    It 'a digest that is well-formed but WRONG fails the gate (not merely a parse guard)' {
        # Distinguishes "cannot read the expectation" from "read it and it did not match": a
        # gate that only caught malformed sidecars would pass every tampered policy.
        Set-Content -LiteralPath $script:OP_Sidecar -Encoding ascii -Value ('0' * 64)
        $w = ''
        @(Import-OrgPolicyExcludes -Path $script:OP_Policy -WarningOut ([ref]$w)).Count |
            Should -Be 0
        $w | Should -Match 'integrity check FAILED'
    }

    It 'Test-OrgPolicyIntegrity returns EMPTY for absent and satisfied, non-empty otherwise' {
        # The unit-level contract behind the caller-level cases above, asserted directly so a
        # future caller refactor cannot silently invert the sense of the return value.
        (Test-OrgPolicyIntegrity -PolicyPath $script:OP_Policy) | Should -BeExactly ''
        Set-Content -LiteralPath $script:OP_Sidecar -Encoding ascii `
            -Value (Get-FileHash -Algorithm SHA256 -LiteralPath $script:OP_Policy).Hash
        (Test-OrgPolicyIntegrity -PolicyPath $script:OP_Policy) | Should -BeExactly ''
        Set-Content -LiteralPath $script:OP_Sidecar -Encoding ascii -Value ('f' * 64)
        (Test-OrgPolicyIntegrity -PolicyPath $script:OP_Policy) | Should -Not -BeNullOrEmpty
    }
}

Describe 'Test-DaemonPipePresent -- the busy-vs-unreachable discriminator (dispatch 000225)' {
    # The whole 000225 fix rests on one claim: a pipe that EXISTS is distinguishable from one that
    # does not, cheaply and read-only, from inside the client process. These assert that claim
    # directly against a real pipe, on every platform the suite runs on.
    BeforeAll {
        $script:DP_Name = 'powershell-lsp-unit225-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
    }

    It 'reports FALSE for a pipe that does not exist' {
        Test-DaemonPipePresent -PipeName $script:DP_Name | Should -BeFalse
    }

    It 'reports TRUE while a server holds the name, and FALSE again once it is disposed' {
        # Both halves in one It on purpose: a probe stuck at $true and a probe stuck at $false each
        # pass one half, so only the transition proves it actually discriminates.
        $server = New-Object System.IO.Pipes.NamedPipeServerStream(
            $script:DP_Name, [System.IO.Pipes.PipeDirection]::InOut, 1,
            [System.IO.Pipes.PipeTransmissionMode]::Byte, [System.IO.Pipes.PipeOptions]::Asynchronous)
        try {
            Test-DaemonPipePresent -PipeName $script:DP_Name | Should -BeTrue
        } finally {
            $server.Dispose()
        }
        Start-Sleep -Milliseconds 250
        Test-DaemonPipePresent -PipeName $script:DP_Name | Should -BeFalse
    }

    It 'still reports TRUE when the single instance is BUSY -- the case the fix turns on' -Skip:(-not $script:OnWindows) {
        # A busy instance is exactly what a connect attempt cannot tell apart from an absent pipe:
        # measured on Windows, both throw the same TimeoutException after the same elapsed time.
        # Presence is what separates them, so presence must survive the instance being occupied.
        $name = 'powershell-lsp-unit225busy-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
        $server = New-Object System.IO.Pipes.NamedPipeServerStream(
            $name, [System.IO.Pipes.PipeDirection]::InOut, 1,
            [System.IO.Pipes.PipeTransmissionMode]::Byte, [System.IO.Pipes.PipeOptions]::Asynchronous)
        $squatter = $null
        try {
            $null = $server.WaitForConnectionAsync()
            $squatter = New-Object System.IO.Pipes.NamedPipeClientStream('.', $name,
                [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
            $squatter.Connect(2000)
            Start-Sleep -Milliseconds 250
            $server.IsConnected | Should -BeTrue -Because 'the assertion below is vacuous unless the instance is genuinely occupied'
            # A second client cannot get in ...
            $second = New-Object System.IO.Pipes.NamedPipeClientStream('.', $name,
                [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
            try { { $second.Connect(600) } | Should -Throw } finally { $second.Dispose() }
            # ... and yet the daemon is plainly still there.
            Test-DaemonPipePresent -PipeName $name | Should -BeTrue
        } finally {
            try { if ($null -ne $squatter) { $squatter.Dispose() } } catch { }
            $server.Dispose()
        }
    }

    It 'is fail-safe: a malformed or empty name returns FALSE instead of throwing' {
        # FALSE routes the caller down the pre-000225 relaunch path, so a probe that cannot answer
        # is never WORSE than the behavior it replaced -- and it never breaks the edit.
        foreach ($bad in @('', '   ', $null, 'has/slash', 'has\backslash', 'has:colon')) {
            { Test-DaemonPipePresent -PipeName $bad } | Should -Not -Throw
            Test-DaemonPipePresent -PipeName $bad | Should -BeFalse
        }
    }

    It 'never OWNS the name of the pipe it is asked about -- it cannot race a starting daemon' {
        # Non-ownership matters: if the probe took the name even momentarily, it would race a daemon
        # that is legitimately starting -- introducing the failure the fix exists to remove. The unix
        # arm opens a CLIENT connection (dispatch 000231), which is non-owning in exactly this sense:
        # a client can never hold a pipe name against its server. The property under test is
        # ownership, not abstinence from I/O.
        $name = 'powershell-lsp-unit225ro-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
        Test-DaemonPipePresent -PipeName $name | Should -BeFalse
        # If the probe had created it, this server could not be created with max 1 instance.
        $server = New-Object System.IO.Pipes.NamedPipeServerStream(
            $name, [System.IO.Pipes.PipeDirection]::InOut, 1,
            [System.IO.Pipes.PipeTransmissionMode]::Byte, [System.IO.Pipes.PipeOptions]::Asynchronous)
        try {
            Test-DaemonPipePresent -PipeName $name | Should -BeTrue
            # And probing did not consume the name either: a second probe still answers the same.
            Test-DaemonPipePresent -PipeName $name | Should -BeTrue
        } finally { $server.Dispose() }
    }

    It 'off-Windows: a STALE socket file whose owner is gone reads as ABSENT, not present (dispatch 000231)' -Skip:$script:OnWindows {
        # THE UNIX DEFECT, ASSERTED ON UNIX. The first cut of this probe's unix arm was a bare
        # Test-Path on the CoreFxPipe_ file, written by analogy from a Windows measurement. NPFS
        # removes the name when the owner dies; a unix socket file does not -- .NET unlinks it only
        # when the server stream is DISPOSED. So a daemon killed without running its exit finally
        # left the file behind and read as LIVE, the client suppressed the relaunch, and recovery
        # never happened on ubuntu or macos while both Windows legs stayed green.
        #
        # THE OWNER MUST BE KILLED, NOT CLOSED. An in-process reproduction was tried first --
        # bind a raw unix socket, then Dispose it and expect the path to survive, since the KERNEL
        # does not unlink a socket path on close. It does not work: .NET's Socket removes the file
        # itself when a socket bound to a UnixDomainSocketEndPoint is disposed. Measured on both
        # unix legs of run 31679281256, where that step asserted the file was still there and got
        # $false. Managed cleanup is exactly what a killed daemon never runs, so the orphan can
        # only be made by killing the process that owns it.
        #
        # Both halves are in one It on purpose -- a probe stuck at $true and a probe stuck at
        # $false each pass one half, so only the transition proves it discriminates.
        $name = 'powershell-lsp-unit231stale-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
        $sock = Join-Path ([System.IO.Path]::GetTempPath()) ('CoreFxPipe_' + $name)
        $holderSrc = Join-Path ([System.IO.Path]::GetTempPath()) ('psls231-holder-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
        # The daemon's own server shape: max 1 instance, asynchronous, never accepting.
        $body = @'
param([string]$PipeName)
$server = New-Object System.IO.Pipes.NamedPipeServerStream(
    $PipeName, [System.IO.Pipes.PipeDirection]::InOut, 1,
    [System.IO.Pipes.PipeTransmissionMode]::Byte, [System.IO.Pipes.PipeOptions]::Asynchronous)
Write-Host 'READY'
Start-Sleep -Seconds 120
'@
        Set-Content -LiteralPath $holderSrc -Value $body -Encoding ascii
        $holder = $null
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'pwsh'; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            # Add-ProcessArguments (lsp-common.ps1, dot-sourced above) rather than .ArgumentList
            # directly: ArgumentList is PowerShell 6+ only, and the suite's own helper is the
            # cross-version seam. This block is off-Windows, but the file is PARSED under 5.1.
            Add-ProcessArguments $psi @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $holderSrc, '-PipeName', $name)
            $holder = [System.Diagnostics.Process]::Start($psi)
            $null = $holder.StandardError.ReadToEndAsync()
            $ready = $holder.StandardOutput.ReadLine()
            $ready | Should -BeExactly 'READY' -Because 'the scenario requires a real pipe server to be up before it is killed'

            (Test-Path -LiteralPath $sock) | Should -BeTrue -Because 'the scenario requires a real socket file at the derived path'
            # This server NEVER accepts, which is also the BUSY case the 000225 gate exists to
            # protect: a daemon whose serial serve loop is analyzing is not accepting either. The
            # kernel completes the connection into the listen backlog regardless, so present is the
            # right answer and the unix arm must not mistake "not accepting" for "not there".
            Test-DaemonPipePresent -PipeName $name | Should -BeTrue -Because 'a listener that is busy rather than absent is still a live daemon'

            # SIGKILL: no finally, no Dispose, no unlink -- exactly how the daemon dies in the
            # recovery scenario, and the only way to manufacture the orphan.
            $holder.Kill()
            $holder.WaitForExit(15000) | Should -BeTrue
            Start-Sleep -Milliseconds 300

            # Assert the orphan is genuinely there, or the FALSE below would pass for the trivial
            # reason that the file went away -- which is how the first cut of this test failed.
            (Test-Path -LiteralPath $sock) | Should -BeTrue -Because 'a killed owner runs no cleanup, so its socket path survives -- this is the stale artifact'
            Test-DaemonPipePresent -PipeName $name | Should -BeFalse -Because 'nobody is listening: a corpse must not suppress the relaunch'
        } finally {
            if ($null -ne $holder) { try { if (-not $holder.HasExited) { $holder.Kill() } } catch { } }
            if (Test-Path -LiteralPath $sock) { Remove-Item -LiteralPath $sock -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $holderSrc) { Remove-Item -LiteralPath $holderSrc -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'off-Windows: a leftover REGULAR file at the socket path reads as ABSENT' -Skip:$script:OnWindows {
        # The other orphan shape: something that is not a socket at all sitting at the derived path.
        # Presence alone would call it a daemon; a connect cannot be established to it.
        $name = 'powershell-lsp-unit231notasock-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
        $sock = Join-Path ([System.IO.Path]::GetTempPath()) ('CoreFxPipe_' + $name)
        Set-Content -LiteralPath $sock -Value 'not a socket' -Encoding ascii
        try {
            (Test-Path -LiteralPath $sock) | Should -BeTrue
            Test-DaemonPipePresent -PipeName $name | Should -BeFalse
        } finally {
            if (Test-Path -LiteralPath $sock) { Remove-Item -LiteralPath $sock -Force -ErrorAction SilentlyContinue }
        }
    }
}
