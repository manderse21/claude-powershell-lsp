#Requires -Version 5.1

# The serve subprocess's userConfig transport (dispatch 000233).
#
# THE DEFECT CLASS. `Get-PluginOption` resolves through `Get-RawPluginOption`, which reads ONLY
# the environment variable `CLAUDE_PLUGIN_OPTION_<KEY>`. Claude Code exports those to HOOK
# processes -- and NOT to LSP server subprocesses. So every knob the LSP serve subprocess read
# resolved to its shipped default no matter what the user configured, silently, for the whole
# life of the feature: `nativeServe = "shim"` in settings, `nativeServe=off` in the shim log,
# and native serving failing at init for a user who had opted in.
#
# The supported transport is the server's own `env` block in the manifest, where
# `${user_config.<key>}` DOES expand. The manifest simply never used it.
#
# WHY THIS BLOCK IS STRUCTURAL AND NOT A THREE-KNOB CHECK. Naming today's three affected knobs
# would protect exactly those three and let the next knob added to the shim reintroduce the same
# silent divergence. So the reachable key set is DERIVED: this block parses the serve
# subprocess's entry point and its dot-source closure, walks the call graph from the shim's own
# top-level body, and collects every literal knob key passed to a plugin-option reader inside
# anything actually reachable. Add a knob read to the shim tomorrow and this block covers it on
# the next run, with nothing to remember.
#
# ANTI-VACUITY, EXECUTED. The mapping check is run against an in-memory copy of the manifest
# with one mapping DELETED, and must go RED. Plus a floor on the derived key count, so a broken
# walker that finds nothing cannot pass over an empty set.
#
# No network, no daemon: pure AST + JSON. Runs on all four CI legs.

BeforeAll {
    $script:SucRoot = Split-Path -Parent $PSScriptRoot
    $script:SucScripts = Join-Path $script:SucRoot 'scripts'
    $script:SucManifestPath = Join-Path $script:SucRoot '.claude-plugin/plugin.json'
    $script:SucManifest = Get-Content -LiteralPath $script:SucManifestPath -Raw | ConvertFrom-Json

    # The readers whose FIRST literal argument is a knob key.
    $script:SucReaders = @('Get-PluginOption', 'Get-PluginOptionInt', 'Get-PluginOptionProvenance', 'Get-RawPluginOption')

    function script:Get-SucAst {
        param([string]$Path)
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        if ($errors -and $errors.Count -gt 0) { throw "parse errors in ${Path}: $($errors[0].Message)" }
        return $ast
    }

    # Resolve the files the serve subprocess dot-sources, from the SOURCE rather than a list:
    # every `. (Join-Path $PSScriptRoot '<rel>')` in the entry point.
    function script:Get-SucDotSourceClosure {
        param([string]$EntryPath)
        $seen = New-Object System.Collections.Generic.List[string]
        $queue = New-Object System.Collections.Generic.Queue[string]
        $queue.Enqueue($EntryPath)
        while ($queue.Count -gt 0) {
            $p = $queue.Dequeue()
            if ($seen.Contains($p)) { continue }
            $seen.Add($p)
            $text = [System.IO.File]::ReadAllText($p)
            $dir = Split-Path -Parent $p
            foreach ($m in [regex]::Matches($text, "(?m)^\s*\.\s+\(Join-Path\s+\`$PSScriptRoot\s+'([^']+)'\)")) {
                $rel = $m.Groups[1].Value -replace '/', [IO.Path]::DirectorySeparatorChar
                $full = Join-Path $dir $rel
                if (Test-Path -LiteralPath $full) { $queue.Enqueue((Resolve-Path -LiteralPath $full).Path) }
            }
        }
        return , @($seen)
    }

    # Build a name -> FunctionDefinitionAst table over the closure.
    function script:Get-SucFunctionTable {
        param([string[]]$Paths)
        $table = @{}
        foreach ($p in $Paths) {
            $ast = script:Get-SucAst -Path $p
            foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
                $table[$f.Name.ToLowerInvariant()] = $f
            }
        }
        return $table
    }

    # Every command NAME invoked anywhere inside an AST node.
    function script:Get-SucInvokedNames {
        param($Node)
        $names = New-Object System.Collections.Generic.List[string]
        foreach ($c in $Node.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $n = $c.GetCommandName()
            if ($n) { $names.Add($n.ToLowerInvariant()) }
        }
        return , @($names)
    }

    # Every literal knob key read by a plugin-option reader inside an AST node.
    function script:Get-SucKnobKeys {
        param($Node)
        $keys = New-Object System.Collections.Generic.List[string]
        foreach ($c in $Node.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $name = $c.GetCommandName()
            if (-not $name) { continue }
            if ($script:SucReaders -notcontains $name) { continue }
            # Positional: Get-PluginOption 'nativeServe' 'off'
            # Named:      Get-PluginOptionProvenance -Key 'nativeServe' -Default 'off'
            $elements = @($c.CommandElements)
            for ($i = 1; $i -lt $elements.Count; $i++) {
                $e = $elements[$i]
                if ($e -is [System.Management.Automation.Language.CommandParameterAst]) {
                    if ($e.ParameterName -ieq 'Key' -and ($i + 1) -lt $elements.Count) {
                        $v = $elements[$i + 1]
                        if ($v -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $keys.Add($v.Value) }
                    }
                    continue
                }
                if ($e -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    # The first bare string argument is the key.
                    $keys.Add($e.Value); break
                }
                break
            }
        }
        return , @($keys)
    }

    # THE DERIVATION: walk the call graph from the shim's own top-level body.
    $script:SucEntry = (Resolve-Path -LiteralPath (Join-Path $script:SucScripts 'pses-serve-shim.ps1')).Path
    $script:SucClosure = script:Get-SucDotSourceClosure -EntryPath $script:SucEntry
    $script:SucFuncs = script:Get-SucFunctionTable -Paths $script:SucClosure

    $entryAst = script:Get-SucAst -Path $script:SucEntry
    $script:SucReachableKeys = New-Object System.Collections.Generic.List[string]
    foreach ($k in (script:Get-SucKnobKeys -Node $entryAst)) { if (-not $script:SucReachableKeys.Contains($k)) { $script:SucReachableKeys.Add($k) } }

    $visited = New-Object System.Collections.Generic.HashSet[string]
    $work = New-Object System.Collections.Generic.Queue[string]
    foreach ($n in (script:Get-SucInvokedNames -Node $entryAst)) { $work.Enqueue($n) }
    while ($work.Count -gt 0) {
        $fn = $work.Dequeue()
        if (-not $visited.Add($fn)) { continue }
        if (-not $script:SucFuncs.ContainsKey($fn)) { continue }
        $body = $script:SucFuncs[$fn]
        foreach ($k in (script:Get-SucKnobKeys -Node $body)) { if (-not $script:SucReachableKeys.Contains($k)) { $script:SucReachableKeys.Add($k) } }
        foreach ($n in (script:Get-SucInvokedNames -Node $body)) { $work.Enqueue($n) }
    }
    $script:SucReachableFunctionCount = $visited.Count

    # The mapping check, as a FUNCTION over a manifest object -- so the anti-vacuity control
    # runs the same code against a mutated copy rather than a re-implementation of it.
    function script:Get-SucMissingMappings {
        param($Manifest, [string[]]$Keys)
        $missing = New-Object System.Collections.Generic.List[string]
        $env = $null
        if ($Manifest.lspServers -and $Manifest.lspServers.powershell) { $env = $Manifest.lspServers.powershell.env }
        foreach ($key in $Keys) {
            $target = ($key -replace '_', '').ToLowerInvariant()
            $found = $false
            if ($null -ne $env) {
                foreach ($prop in $env.PSObject.Properties) {
                    $name = [string]$prop.Name
                    if (-not $name.StartsWith('CLAUDE_PLUGIN_OPTION_', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                    # Match the SAME normalization Get-RawPluginOption applies when reading.
                    $normalized = ($name.Substring('CLAUDE_PLUGIN_OPTION_'.Length) -replace '_', '').ToLowerInvariant()
                    if ($normalized -ne $target) { continue }
                    # And the value must actually be the supported expansion of THAT knob.
                    if ([string]$prop.Value -match ('^\$\{user_config\.' + [regex]::Escape($key) + '\}$')) { $found = $true; break }
                }
            }
            if (-not $found) { $missing.Add($key) }
        }
        return , @($missing)
    }
}

Describe 'Serve-subprocess userConfig transport -- every reachable knob is mapped (dispatch 000233)' {

    Context 'the derivation is real' {

        It 'resolves the serve subprocess dot-source closure from the source, not a list' {
            @($script:SucClosure).Count | Should -BeGreaterOrEqual 3
            $leaves = @($script:SucClosure | ForEach-Object { Split-Path $_ -Leaf })
            $leaves | Should -Contain 'pses-serve-shim.ps1'
            $leaves | Should -Contain 'lsp-common.ps1'
            $leaves | Should -Contain 'serve-shim-common.ps1'
            Write-Host ('  closure: ' + ($leaves -join ', '))
        }

        It 'walks a non-trivial call graph from the shim entry point' {
            # A walker that reached nothing would find no keys and pass everything below.
            $script:SucReachableFunctionCount | Should -BeGreaterOrEqual 5
            Write-Host ("  reachable functions visited: $($script:SucReachableFunctionCount)")
        }

        It 'derives a non-empty reachable knob-key set (the floor that stops a vacuous pass)' {
            @($script:SucReachableKeys).Count | Should -BeGreaterOrEqual 3
            Write-Host ('  reachable knob keys: ' + (@($script:SucReachableKeys) -join ', '))
        }

        It 'derives the three keys the survey proved affected' {
            foreach ($k in @('nativeServe', 'ps_host', 'profile')) {
                @($script:SucReachableKeys) | Should -Contain $k
            }
        }
    }

    Context 'the invariant' {

        It 'EVERY reachable knob has a supported ${user_config.*} mapping in lspServers.powershell.env' {
            $missing = script:Get-SucMissingMappings -Manifest $script:SucManifest -Keys @($script:SucReachableKeys)
            $detail = ($missing -join ', ')
            @($missing).Count | Should -Be 0 -Because "these knobs are read by the serve subprocess but have no transport into it: $detail"
        }

        It 'the mapped env names are the ones Get-RawPluginOption actually reads' {
            # The reader normalizes by stripping underscores and lower-casing, so
            # CLAUDE_PLUGIN_OPTION_PS_HOST and _PSHOST both resolve 'ps_host'. Assert the
            # prefix contract rather than an exact spelling, because the reader does too.
            $env = $script:SucManifest.lspServers.powershell.env
            $mapped = @($env.PSObject.Properties | Where-Object { $_.Name -like 'CLAUDE_PLUGIN_OPTION_*' })
            @($mapped).Count | Should -BeGreaterOrEqual 3
            foreach ($p in $mapped) {
                [string]$p.Value | Should -Match '^\$\{user_config\.[A-Za-z_][A-Za-z0-9_]*\}$'
            }
        }

        It 'PSES_BUNDLE_PATH is untouched (the mapping is ADDITIVE)' {
            [string]$script:SucManifest.lspServers.powershell.env.PSES_BUNDLE_PATH |
                Should -BeExactly '${CLAUDE_PLUGIN_DATA}/PowerShellEditorServices'
        }
    }

    Context 'anti-vacuity: the invariant is DEMONSTRATED RED by deleting one mapping' {

        It 'deleting the nativeServe mapping from an in-memory manifest copy makes the check FAIL' {
            $copy = Get-Content -LiteralPath $script:SucManifestPath -Raw | ConvertFrom-Json
            $copy.lspServers.powershell.env.PSObject.Properties.Remove('CLAUDE_PLUGIN_OPTION_NATIVESERVE')
            $missing = script:Get-SucMissingMappings -Manifest $copy -Keys @($script:SucReachableKeys)
            @($missing) | Should -Contain 'nativeServe'
            Write-Host ('  RED with the mapping deleted: missing = ' + ($missing -join ', '))
        }

        It 'deleting the ps_host mapping makes the check FAIL' {
            $copy = Get-Content -LiteralPath $script:SucManifestPath -Raw | ConvertFrom-Json
            $copy.lspServers.powershell.env.PSObject.Properties.Remove('CLAUDE_PLUGIN_OPTION_PS_HOST')
            $missing = script:Get-SucMissingMappings -Manifest $copy -Keys @($script:SucReachableKeys)
            @($missing) | Should -Contain 'ps_host'
        }

        It 'removing the whole env block makes EVERY reachable knob report missing' {
            $copy = Get-Content -LiteralPath $script:SucManifestPath -Raw | ConvertFrom-Json
            $copy.lspServers.powershell.PSObject.Properties.Remove('env')
            $missing = script:Get-SucMissingMappings -Manifest $copy -Keys @($script:SucReachableKeys)
            @($missing).Count | Should -Be @($script:SucReachableKeys).Count
        }

        It 'a mapping whose VALUE is not the supported expansion does not count as one' {
            # A name-only match would let `"CLAUDE_PLUGIN_OPTION_NATIVESERVE": "shim"` -- a
            # hardcoded value that ignores the user entirely -- satisfy the guard.
            $copy = Get-Content -LiteralPath $script:SucManifestPath -Raw | ConvertFrom-Json
            $copy.lspServers.powershell.env.CLAUDE_PLUGIN_OPTION_NATIVESERVE = 'shim'
            $missing = script:Get-SucMissingMappings -Manifest $copy -Keys @($script:SucReachableKeys)
            @($missing) | Should -Contain 'nativeServe'
        }

        It 'a mapping pointing at the WRONG knob does not count either' {
            $copy = Get-Content -LiteralPath $script:SucManifestPath -Raw | ConvertFrom-Json
            $copy.lspServers.powershell.env.CLAUDE_PLUGIN_OPTION_NATIVESERVE = '${user_config.ps_host}'
            $missing = script:Get-SucMissingMappings -Manifest $copy -Keys @($script:SucReachableKeys)
            @($missing) | Should -Contain 'nativeServe'
        }
    }
}

Describe 'Serve-subprocess knob resolution and provenance (dispatch 000233)' {

    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/serve-shim-common.ps1')

        # Env names are case-insensitive on Windows and case-SENSITIVE elsewhere, and the
        # reader normalizes case -- so clear by WILDCARD sweep, never by one exact spelling.
        function script:Clear-SucOptionEnv {
            foreach ($e in @([System.Environment]::GetEnvironmentVariables().Keys)) {
                if ([string]$e -like 'CLAUDE_PLUGIN_OPTION_*') {
                    [System.Environment]::SetEnvironmentVariable([string]$e, $null)
                }
            }
        }
    }

    AfterEach { script:Clear-SucOptionEnv }

    Context 'nativeServe -- configured maps to effective, and the unsupported cases fail safe' {

        It 'configured shim -> effective shim' {
            script:Clear-SucOptionEnv
            $env:CLAUDE_PLUGIN_OPTION_NATIVESERVE = 'shim'
            $r = Get-PluginOptionProvenance -Key 'nativeServe' -Default 'off'
            $r.Provenance | Should -BeExactly 'env'
            (ConvertTo-NativeServeMode $r.Value) | Should -BeExactly 'shim'
        }

        It 'configured off -> effective off' {
            script:Clear-SucOptionEnv
            $env:CLAUDE_PLUGIN_OPTION_NATIVESERVE = 'off'
            $r = Get-PluginOptionProvenance -Key 'nativeServe' -Default 'off'
            $r.Provenance | Should -BeExactly 'env'
            (ConvertTo-NativeServeMode $r.Value) | Should -BeExactly 'off'
        }

        It 'UNSET -> effective off, and the provenance says DEFAULT rather than reporting a bare value' {
            script:Clear-SucOptionEnv
            $r = Get-PluginOptionProvenance -Key 'nativeServe' -Default 'off'
            $r.Provenance | Should -BeExactly 'default'
            (ConvertTo-NativeServeMode $r.Value) | Should -BeExactly 'off'
            (Format-PluginOptionProvenance $r) | Should -Match 'provenance: default'
        }

        It 'an EMPTY expansion (the unset-knob shape) reads as unset, not as a configured empty' {
            script:Clear-SucOptionEnv
            $env:CLAUDE_PLUGIN_OPTION_NATIVESERVE = ''
            $r = Get-PluginOptionProvenance -Key 'nativeServe' -Default 'off'
            $r.Provenance | Should -BeExactly 'default'
            (ConvertTo-NativeServeMode $r.Value) | Should -BeExactly 'off'
        }

        It 'a LITERAL unexpanded token reads as a value but still lands on off (fail-safe)' {
            # The other empirical possibility for an unset knob. ConvertTo-NativeServeMode maps
            # anything outside shim|true|on|1|yes to off, so both shapes are safe -- proven,
            # not assumed.
            script:Clear-SucOptionEnv
            $env:CLAUDE_PLUGIN_OPTION_NATIVESERVE = '${user_config.nativeServe}'
            $r = Get-PluginOptionProvenance -Key 'nativeServe' -Default 'off'
            (ConvertTo-NativeServeMode $r.Value) | Should -BeExactly 'off'
        }

        It "an unsupported value such as 'auto' -> off; auto is NOT implemented" {
            script:Clear-SucOptionEnv
            $env:CLAUDE_PLUGIN_OPTION_NATIVESERVE = 'auto'
            (ConvertTo-NativeServeMode (Get-PluginOption 'nativeServe' 'off')) | Should -BeExactly 'off'
        }
    }

    Context 'ps_host -- configured maps to the host the shim would launch' {

        It 'configured pwsh -> pwsh' {
            script:Clear-SucOptionEnv
            $env:CLAUDE_PLUGIN_OPTION_PS_HOST = 'pwsh'
            $r = Get-PluginOptionProvenance -Key 'ps_host' -Default 'pwsh'
            $r.Provenance | Should -BeExactly 'env'
            $r.Value | Should -BeExactly 'pwsh'
        }

        It 'configured powershell -> powershell wherever powershell.exe exists' {
            script:Clear-SucOptionEnv
            $env:CLAUDE_PLUGIN_OPTION_PS_HOST = 'powershell'
            $r = Get-PluginOptionProvenance -Key 'ps_host' -Default 'pwsh'
            $r.Value | Should -BeExactly 'powershell'
            $resolved = Resolve-PsHost $r.Value
            if ($null -ne (Get-Command 'powershell' -ErrorAction SilentlyContinue)) {
                $resolved | Should -BeExactly 'powershell' -Because 'the configured host must WIN when it is available'
            } else {
                # Off Windows there is no powershell.exe; the documented fallthrough applies.
                $resolved | Should -BeExactly 'pwsh'
            }
        }

        It 'UNSET -> the documented pwsh default, with DEFAULT provenance' {
            script:Clear-SucOptionEnv
            $r = Get-PluginOptionProvenance -Key 'ps_host' -Default 'pwsh'
            $r.Provenance | Should -BeExactly 'default'
            $r.Value | Should -BeExactly 'pwsh'
        }

        It 'a literal unexpanded token falls through to an available host rather than failing' {
            script:Clear-SucOptionEnv
            $env:CLAUDE_PLUGIN_OPTION_PS_HOST = '${user_config.ps_host}'
            Resolve-PsHost (Get-PluginOption 'ps_host' 'pwsh') | Should -BeIn @('pwsh', 'powershell')
        }
    }

    Context 'profile -- reaches the subprocess and its derived value is proven, not inferred' {

        It 'a configured profile is read back with env provenance' {
            script:Clear-SucOptionEnv
            $env:CLAUDE_PLUGIN_OPTION_PROFILE = 'strict'
            $r = Get-PluginOptionProvenance -Key 'profile' -Default 'safe'
            $r.Provenance | Should -BeExactly 'env'
            $r.Value | Should -BeExactly 'strict'
            $r.ProfileName | Should -BeExactly 'strict'
        }

        It 'a knob the profile MAPS resolves from the profile, and says so' {
            # The proof that the profile actually applies inside this subprocess rather than
            # merely arriving: pick a knob the strict profile maps and show the provenance.
            script:Clear-SucOptionEnv
            $env:CLAUDE_PLUGIN_OPTION_PROFILE = 'strict'
            $map = Get-PluginProfileMap
            $strict = $map['strict']
            $mappedKey = @($strict.Keys)[0]
            $r = Get-PluginOptionProvenance -Key ([string]$mappedKey) -Default 'SENTINEL-NOT-USED'
            $r.Provenance | Should -BeExactly 'profile'
            $r.Value | Should -BeExactly ([string]$strict[$mappedKey])
            $r.Value | Should -Not -BeExactly 'SENTINEL-NOT-USED'
            Write-Host ("  profile 'strict' maps $mappedKey -> $($r.Value) (provenance: $($r.Provenance))")
        }

        It 'an explicit knob still BEATS the profile (precedence is unchanged)' {
            script:Clear-SucOptionEnv
            $env:CLAUDE_PLUGIN_OPTION_PROFILE = 'strict'
            $map = Get-PluginProfileMap
            $mappedKey = [string](@($map['strict'].Keys)[0])
            $envName = 'CLAUDE_PLUGIN_OPTION_' + ($mappedKey -replace '_', '').ToUpperInvariant()
            [System.Environment]::SetEnvironmentVariable($envName, 'EXPLICIT-WINS')
            $r = Get-PluginOptionProvenance -Key $mappedKey -Default 'x'
            $r.Provenance | Should -BeExactly 'env'
            $r.Value | Should -BeExactly 'EXPLICIT-WINS'
        }

        It 'an unrecognized profile degrades to safe rather than guessing a preset' {
            script:Clear-SucOptionEnv
            $env:CLAUDE_PLUGIN_OPTION_PROFILE = '${user_config.profile}'
            (Get-PluginOptionProvenance -Key 'nativeServe' -Default 'off').ProfileName | Should -BeExactly 'safe'
        }
    }

    Context 'Get-PluginOption is a projection of the provenance resolver (no second chain)' {

        It 'agrees with Get-PluginOptionProvenance on every case above' {
            foreach ($case in @(
                    @{ Set = 'shim'; Key = 'nativeServe'; Default = 'off' },
                    @{ Set = $null; Key = 'nativeServe'; Default = 'off' },
                    @{ Set = 'powershell'; Key = 'ps_host'; Default = 'pwsh' },
                    @{ Set = $null; Key = 'ps_host'; Default = 'pwsh' })) {
                script:Clear-SucOptionEnv
                if ($null -ne $case.Set) {
                    $n = 'CLAUDE_PLUGIN_OPTION_' + (($case.Key) -replace '_', '').ToUpperInvariant()
                    [System.Environment]::SetEnvironmentVariable($n, [string]$case.Set)
                }
                $viaOption = Get-PluginOption $case.Key $case.Default
                $viaProv = (Get-PluginOptionProvenance -Key $case.Key -Default $case.Default).Value
                $viaOption | Should -BeExactly $viaProv
            }
        }
    }

    Context 'the shim reports configured-vs-effective on every launch, including the default case' {

        It 'the shim logs a provenance line for each knob it reads' {
            $shim = [System.IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/pses-serve-shim.ps1'))
            $shim | Should -Match 'Get-PluginOptionProvenance -Key ''nativeServe'''
            $shim | Should -Match 'Get-PluginOptionProvenance -Key ''ps_host'''
            $shim | Should -Match 'Get-PluginOptionProvenance -Key ''profile'''
            $shim | Should -Match 'Format-PluginOptionProvenance'
        }

        It 'the shim logs configured AND effective for nativeServe, not a bare value' {
            $shim = [System.IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/pses-serve-shim.ps1'))
            $shim | Should -Match 'configured='
            $shim | Should -Match 'effective='
        }

        It 'the shim logs the effective PSES host, and names a substitution when one happens' {
            $shim = [System.IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/pses-serve-shim.ps1'))
            $shim | Should -Match 'PSES host: configured='
            $shim | Should -Match 'SUBSTITUTED'
        }
    }

    Context 'the #1359 shim surface is byte-identical (scope_out, asserted not assumed)' {

        It 'the intercept set is unchanged' {
            # The three methods read from the SHIPPED serve-shim-common.ps1 before this
            # dispatch touched anything, recorded here so a later widening or narrowing of the
            # #1359 workaround turns this red. This dispatch changes no file in that path --
            # asserted rather than assumed, because "I did not mean to" is not a guard.
            $expected = @('workspace/configuration', 'window/workDoneProgress/create', 'client/registerCapability')
            $actual = @(Get-ServeInterceptMethods)
            # Set equality, order-insensitive: the guard is the SET, not the literal array.
            @($actual | Where-Object { $expected -notcontains $_ }).Count | Should -Be 0
            @($expected | Where-Object { $actual -notcontains $_ }).Count | Should -Be 0
        }

        It 'restartOnCrash and shutdownTimeout are still ABSENT from the manifest' {
            $raw = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) '.claude-plugin/plugin.json') -Raw
            $raw | Should -Not -Match 'restartOnCrash'
            $raw | Should -Not -Match 'shutdownTimeout'
        }
    }
}
