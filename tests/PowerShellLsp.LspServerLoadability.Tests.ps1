#Requires -Version 5.1

# The manifest's lspServers block must stay LOADABLE (dispatch 000241).
#
# THE DEFECT CLASS. Claude Code 2.1.233 interpolates `${user_config.<key>}` inside
# `lspServers.<server>.env` against the user's STORED options only -- it does not merge the
# defaults declared in the plugin's own `userConfig` schema, although the sibling MCP path does
# exactly that. A key the user never explicitly set is `undefined`, the interpolator THROWS, and
# the per-plugin catch in the loader discards EVERY server the plugin declares:
#
#     Failed to load LSP servers for plugin powershell-lsp: Error: Plugin option "profile" isn't set.
#
# So each `${user_config.*}` mapping this manifest adds is not free: it silently converts into a
# key the user MUST type by hand before the plugin contributes any LSP server at all. Dispatch
# 000233 added three of them for a good reason and could not have known the cost. This block makes
# the cost VISIBLE and COUNTED, so the fourth one cannot be added by accident.
#
# Full root cause, the decompiled call sites, and the proposed upstream fix:
# docs/upstream/claude-code-lspservers-userconfig-defaults.md
#
# WHY THIS IS NOT SIMPLY "ASSERT THE SET IS EMPTY". The mitigation is still under adjudication --
# removing the mappings would restore loadability but reinstate the divergence 000233 killed. So
# this block asserts PROPERTIES that hold under either outcome, and the one prediction test is
# written to FLIP with its own premise rather than to pin today's answer.
#
# CASE SENSITIVITY IS LOAD-BEARING. The upstream lookup is a JavaScript property read, `t[n]` --
# ordinal. `${user_config.nativeserve}` would NOT resolve against a `nativeServe` schema key, and
# PowerShell's default string comparisons would hide that. Every key comparison here is ordinal.
#
# No network, no daemon, no Claude Code process: pure JSON + a faithful model of the upstream
# interpolator. Runs on all four CI legs.

BeforeAll {
    $script:LslRoot = Split-Path -Parent $PSScriptRoot
    $script:LslManifestPath = Join-Path $script:LslRoot '.claude-plugin/plugin.json'
    $script:LslManifest = Get-Content -LiteralPath $script:LslManifestPath -Raw | ConvertFrom-Json
    $script:LslTroubleshootingPath = Join-Path $script:LslRoot 'docs/troubleshooting.md'

    # The keys a user must type by hand today for the LSP block to load on Claude Code 2.1.233.
    # THIS LIST IS THE POINT OF THE BLOCK. Changing the manifest's ${user_config.*} mappings must
    # change this list in the same commit, which is the moment to ask whether the new mapping is
    # worth another mandatory hand-configuration step for every user.
    $script:LslExpectedRequiredKeys = @('nativeServe', 'profile', 'ps_host')

    $script:LslUserConfigRefPattern = '\$\{user_config\.([^}]+)\}'

    function script:New-LslOrdinalSet {
        param([string[]]$Items)
        $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($i in $Items) { $null = $set.Add($i) }
        return , $set
    }

    # Every ${user_config.<key>} reference anywhere under lspServers, derived from the manifest
    # rather than listed -- a mapping added to a SECOND server, or to a field other than env, is
    # covered on the next run with nothing to remember.
    function script:Get-LslUserConfigRefs {
        param($Manifest)
        $refs = New-Object System.Collections.Generic.List[string]
        if (-not $Manifest.lspServers) { return , @() }
        $json = $Manifest.lspServers | ConvertTo-Json -Depth 20
        foreach ($m in [regex]::Matches($json, $script:LslUserConfigRefPattern)) {
            $refs.Add($m.Groups[1].Value)
        }
        return , @($refs)
    }

    # An ORDINAL map. PowerShell's @{} literal is case-INSENSITIVE, so a plain hashtable would
    # report ContainsKey('nativeServe') = $true for a map holding only 'nativeserve' and would
    # hide the exact mismatch this block exists to catch.
    function script:New-LslOrdinalMap {
        param([System.Collections.IDictionary]$From)
        $map = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
        if ($From) { foreach ($k in $From.Keys) { $map[[string]$k] = [string]$From[$k] } }
        return , $map
    }

    # A faithful model of the upstream interpolator (2.1.233, minified `zXt`): replace each
    # reference from the supplied option map, and THROW on the first key the map does not carry.
    # It deliberately does NOT consult the schema -- reproducing the missing defaults merge is the
    # entire behavior under test. The key test is spelled out ordinally rather than delegated to
    # the dictionary's comparer, so the model states its own semantics.
    function script:Resolve-LslUserConfigRefs {
        param([string]$Text, [System.Collections.IDictionary]$StoredOptions)
        $evaluator = {
            param($m)
            $key = $m.Groups[1].Value
            foreach ($k in $StoredOptions.Keys) {
                if ([string]::Equals([string]$k, $key, [System.StringComparison]::Ordinal)) {
                    return [string]$StoredOptions[$k]
                }
            }
            throw [System.InvalidOperationException]::new("Plugin option `"$key`" isn't set.")
        }
        return [regex]::Replace($Text, $script:LslUserConfigRefPattern, $evaluator)
    }

    # Model of the upstream defaults merge (minified `$Yd`) -- what the LSP path SHOULD call and
    # the MCP path already does. Used only to prove the forward-compatibility property.
    function script:Merge-LslSchemaDefaults {
        param($UserConfigSchema, [System.Collections.IDictionary]$StoredOptions)
        $merged = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
        if ($UserConfigSchema) {
            foreach ($p in $UserConfigSchema.PSObject.Properties) {
                $spec = $p.Value
                $hasDefault = $spec.PSObject.Properties.Name -ccontains 'default'
                if ($spec.required -and -not $hasDefault) { continue }
                $merged[$p.Name] = if ($hasDefault) { [string]$spec.default } else { '' }
            }
        }
        if ($StoredOptions) { foreach ($k in $StoredOptions.Keys) { $merged[[string]$k] = [string]$StoredOptions[$k] } }
        return , $merged
    }

    # An ordinal-correct schema lookup. $Manifest.userConfig.$key would match case-INSENSITIVELY
    # and hide exactly the mismatch this block exists to catch.
    function script:Get-LslSchemaEntry {
        param($Manifest, [string]$Key)
        if (-not $Manifest.userConfig) { return $null }
        foreach ($p in $Manifest.userConfig.PSObject.Properties) {
            if ([string]::Equals($p.Name, $Key, [System.StringComparison]::Ordinal)) { return $p.Value }
        }
        return $null
    }

    # A deep, mutable copy, so a mutation test cannot leak into the next It.
    function script:Copy-LslManifest {
        param($Manifest)
        return ($Manifest | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
    }

    $script:LslRefs = script:Get-LslUserConfigRefs -Manifest $script:LslManifest
    $script:LslRefSet = script:New-LslOrdinalSet -Items $script:LslRefs
}

Describe 'lspServers userConfig references -- the mandatory-configuration cost is counted (dispatch 000241)' {

    Context 'the harness models upstream faithfully (its own floor -- a broken model proves nothing)' {

        It 'resolves a reference when the stored options carry the key' {
            $out = script:Resolve-LslUserConfigRefs -Text 'x=${user_config.k}' -StoredOptions @{ k = 'v' }
            $out | Should -BeExactly 'x=v'
        }

        It 'THROWS when the stored options do not carry the key -- the upstream behavior under test' {
            { script:Resolve-LslUserConfigRefs -Text 'x=${user_config.k}' -StoredOptions @{} } |
                Should -Throw -ExpectedMessage '*"k" isn''t set*'
        }

        It 'does NOT consult a declared default (that omission IS the upstream defect)' {
            $schema = [pscustomobject]@{ k = [pscustomobject]@{ type = 'string'; default = 'fallback' } }
            # The model is handed stored options only, exactly as `zup` hands them over.
            { script:Resolve-LslUserConfigRefs -Text '${user_config.k}' -StoredOptions @{} } | Should -Throw
            # ...while the defaults merge the MCP path performs WOULD have supplied it.
            $merged = script:Merge-LslSchemaDefaults -UserConfigSchema $schema -StoredOptions @{}
            $merged['k'] | Should -BeExactly 'fallback'
        }

        It 'treats keys ordinally, the way the JavaScript property read does' {
            { script:Resolve-LslUserConfigRefs -Text '${user_config.nativeServe}' -StoredOptions @{ nativeserve = 'shim' } } |
                Should -Throw -ExpectedMessage '*nativeServe*'
        }
    }

    Context 'the reference set is derived from the manifest, not listed' {

        It 'finds a reference that lives in a SECOND server, not just the first' {
            $mutated = script:Copy-LslManifest -Manifest $script:LslManifest
            $mutated.lspServers | Add-Member -NotePropertyName 'probe' -NotePropertyValue ([pscustomobject]@{
                    command = 'probe'
                    env     = [pscustomobject]@{ P = '${user_config.ruleset}' }
                })
            $refs = script:Get-LslUserConfigRefs -Manifest $mutated
            $refs | Should -Contain 'ruleset'
        }

        It 'reports no references at all when the lspServers block carries none' {
            $mutated = script:Copy-LslManifest -Manifest $script:LslManifest
            $mutated.lspServers.powershell.env = [pscustomobject]@{ PSES_BUNDLE_PATH = '${CLAUDE_PLUGIN_DATA}/PowerShellEditorServices' }
            (script:Get-LslUserConfigRefs -Manifest $mutated).Count | Should -Be 0
        }
    }

    Context 'the invariants -- these hold whichever mitigation is adjudicated' {

        It 'every referenced key is DECLARED in userConfig, matched ordinally' {
            foreach ($key in $script:LslRefSet) {
                $entry = script:Get-LslSchemaEntry -Manifest $script:LslManifest -Key $key
                $entry | Should -Not -BeNullOrEmpty -Because "lspServers references `${user_config.$key} but userConfig declares no key spelled exactly '$key'"
            }
        }

        It 'every referenced key declares a DEFAULT, so the upstream fix restores its DOCUMENTED value' {
            # The upstream merge assigns `o.default ?? ""`. A referenced key with no declared
            # default therefore resolves to an EMPTY STRING once the fix lands -- it loads, but
            # silently substitutes empty for the value docs/configuration.md promises.
            foreach ($key in $script:LslRefSet) {
                $entry = script:Get-LslSchemaEntry -Manifest $script:LslManifest -Key $key
                $entry.PSObject.Properties.Name | Should -Contain 'default' -Because "$key is referenced from lspServers; with no declared default the upstream merge would hand the serve subprocess an empty value instead of its documented one"
            }
        }

        It 'no referenced key is REQUIRED-without-a-default -- that pairing stays fatal past the fix' {
            # The upstream merge SKIPS `required` keys that declare no default, so they remain
            # undefined and keep throwing even after the defaults merge is added to the LSP path.
            foreach ($key in $script:LslRefSet) {
                $entry = script:Get-LslSchemaEntry -Manifest $script:LslManifest -Key $key
                $hasDefault = $entry.PSObject.Properties.Name -ccontains 'default'
                if ($entry.required) {
                    $hasDefault | Should -BeTrue -Because "$key is required AND referenced from lspServers; without a default the upstream defaults merge skips it and the whole block still fails to load"
                }
            }
        }

        It 'the mandatory-hand-configuration key set is EXACTLY the set this block accounts for' {
            $actual = @($script:LslRefSet) | Sort-Object
            $expected = @($script:LslExpectedRequiredKeys) | Sort-Object
            ($actual -join ',') | Should -BeExactly ($expected -join ',') -Because 'a new ${user_config.*} mapping makes another knob mandatory for every user until upstream merges schema defaults -- update $LslExpectedRequiredKeys and the troubleshooting entry in the same commit'
        }

        It 'troubleshooting.md names every key a user must set by hand' {
            $doc = Get-Content -LiteralPath $script:LslTroubleshootingPath -Raw
            foreach ($key in $script:LslExpectedRequiredKeys) {
                $doc | Should -BeLike "*$key*" -Because "a user hitting 'Plugin option `"$key`" isn't set' must find $key named in the troubleshooting entry"
            }
        }
    }

    Context 'the zero-configuration prediction -- written to FLIP with its own premise' {

        It 'a fresh install with NO stored options behaves exactly as the derived reference set predicts' {
            $envJson = $script:LslManifest.lspServers | ConvertTo-Json -Depth 20
            $act = { script:Resolve-LslUserConfigRefs -Text $envJson -StoredOptions @{} }

            if ($script:LslRefSet.Count -gt 0) {
                # PREMISE: the manifest still carries mappings -> upstream drops the whole block.
                $act | Should -Throw -Because 'each ${user_config.*} mapping is unresolvable for a user who has set nothing, and one throw discards every server the plugin declares'
            }
            else {
                # PREMISE FLIPPED: the mappings were removed -> a zero-config install must load.
                $act | Should -Not -Throw -Because 'with no ${user_config.*} references left, a zero-configuration install must resolve the block cleanly'
            }
        }

        It 'the same block resolves cleanly once every referenced key IS stored' {
            $envJson = $script:LslManifest.lspServers | ConvertTo-Json -Depth 20
            $stored = @{}
            foreach ($key in $script:LslRefSet) { $stored[$key] = 'x' }
            { script:Resolve-LslUserConfigRefs -Text $envJson -StoredOptions $stored } | Should -Not -Throw
        }

        It 'and would ALSO resolve for a zero-config user if upstream merged schema defaults' {
            $envJson = $script:LslManifest.lspServers | ConvertTo-Json -Depth 20
            $merged = script:Merge-LslSchemaDefaults -UserConfigSchema $script:LslManifest.userConfig -StoredOptions @{}
            { script:Resolve-LslUserConfigRefs -Text $envJson -StoredOptions $merged } | Should -Not -Throw -Because 'this is the one-call upstream fix; if it fails here, a referenced key is missing its declared default'
        }
    }

    Context 'anti-vacuity: each invariant is DEMONSTRATED RED by breaking its premise' {

        It 'adding a FOURTH mapping makes the accounted-set check FAIL' {
            $mutated = script:Copy-LslManifest -Manifest $script:LslManifest
            $mutated.lspServers.powershell.env | Add-Member -NotePropertyName 'CLAUDE_PLUGIN_OPTION_RULESET' -NotePropertyValue '${user_config.ruleset}'
            $actual = @(script:Get-LslUserConfigRefs -Manifest $mutated) | Sort-Object
            $expected = @($script:LslExpectedRequiredKeys) | Sort-Object
            ($actual -join ',') | Should -Not -BeExactly ($expected -join ',')
        }

        It 'referencing an UNDECLARED key makes the declaration check FAIL' {
            $mutated = script:Copy-LslManifest -Manifest $script:LslManifest
            $mutated.lspServers.powershell.env | Add-Member -NotePropertyName 'CLAUDE_PLUGIN_OPTION_NOPE' -NotePropertyValue '${user_config.noSuchKnob}'
            $refs = script:Get-LslUserConfigRefs -Manifest $mutated
            $refs | Should -Contain 'noSuchKnob'
            (script:Get-LslSchemaEntry -Manifest $mutated -Key 'noSuchKnob') | Should -BeNullOrEmpty
        }

        It 'a case-mismatched reference does NOT count as declared' {
            $mutated = script:Copy-LslManifest -Manifest $script:LslManifest
            $mutated.lspServers.powershell.env.CLAUDE_PLUGIN_OPTION_NATIVESERVE = '${user_config.nativeserve}'
            $refs = script:Get-LslUserConfigRefs -Manifest $mutated
            $refs | Should -Contain 'nativeserve'
            (script:Get-LslSchemaEntry -Manifest $mutated -Key 'nativeserve') | Should -BeNullOrEmpty
        }

        It 'a referenced key that loses its DEFAULT resolves EMPTY under the upstream fix, not fatally' {
            # Recorded because it refuted the obvious guess: dropping a default does NOT keep the
            # block failing, it quietly swaps the documented value for an empty one. Different
            # defect, different guard -- which is why the invariant above is worded as it is.
            $mutated = script:Copy-LslManifest -Manifest $script:LslManifest
            $mutated.userConfig.profile.PSObject.Properties.Remove('default')
            $merged = script:Merge-LslSchemaDefaults -UserConfigSchema $mutated.userConfig -StoredOptions @{}
            $merged['profile'] | Should -BeExactly ''
            $envJson = $mutated.lspServers | ConvertTo-Json -Depth 20
            { script:Resolve-LslUserConfigRefs -Text $envJson -StoredOptions $merged } | Should -Not -Throw
        }

        It 'a referenced key marked REQUIRED with no default DOES stay fatal past the upstream fix' {
            $mutated = script:Copy-LslManifest -Manifest $script:LslManifest
            $mutated.userConfig.profile.PSObject.Properties.Remove('default')
            $mutated.userConfig.profile | Add-Member -NotePropertyName 'required' -NotePropertyValue $true
            $merged = script:Merge-LslSchemaDefaults -UserConfigSchema $mutated.userConfig -StoredOptions @{}
            $merged.ContainsKey('profile') | Should -BeFalse
            $envJson = $mutated.lspServers | ConvertTo-Json -Depth 20
            { script:Resolve-LslUserConfigRefs -Text $envJson -StoredOptions $merged } | Should -Throw -ExpectedMessage '*"profile" isn''t set*'
        }
    }
}
