#Requires -Version 5.1

# Native-serve shim tests (Pester 5), dispatch 000103. Two layers:
#   1. PURE UNIT (no process): the byte-exact framing, the initialize patch, the knob
#      canonicalizer, and the server->client intercept answer table (scripts/lib/serve-shim-common.ps1).
#   2. E2E (real PSES over the shim): a scripted CC-shaped LSP client drives the shimmed stack and
#      asserts the shim's contract -- nav serves statically, interceptions are absorbed, off is a
#      transparent pass-through, the lifecycle reaps with zero orphans. Runs on Windows, Linux, and
#      macOS; the shim is spawned under the CURRENT interpreter so the four-leg CI matrix probes it
#      under BOTH pwsh and Windows PowerShell 5.1. The ubuntu leg IS the Linux #2300 init-patch
#      validation (the workspaceFolders-bearing initialize completing there is the closed risk).
#
# Each E2E scenario launches EXACTLY ONE shim+PSES in its own Describe/BeforeAll, fully torn down
# before the next, per the 000101 serialization lesson (never N daemons in a shared BeforeAll --
# the constrained 5.1 CI leg flakes on the startup spike).

$script:OnWindows = if (Test-Path 'Variable:\IsWindows') { [bool]$IsWindows } else { $true }
$script:OnLinux = (Test-Path 'Variable:\IsLinux') -and [bool]$IsLinux
$script:OnMacOS = (Test-Path 'Variable:\IsMacOS') -and [bool]$IsMacOS
$script:SkipServe = -not ($script:OnWindows -or $script:OnLinux -or $script:OnMacOS)
# Each E2E BeforeAll spawns the shim under the host running these tests (Core -> pwsh, Desktop ->
# powershell 5.1) so the CI matrix exercises the shim on both hosts; the interpreter is resolved
# INSIDE BeforeAll (run phase), not here (discovery phase), because Pester v5 isolates the two.
# The PSES child stays pwsh (Start-ServeShimClient sets CLAUDE_PLUGIN_OPTION_PS_HOST).

Describe 'ServeShim unit: the knob canonicalizer (ConvertTo-NativeServeMode)' {
    BeforeAll { . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/serve-shim-common.ps1') }
    It 'blank / unset -> off (the default; opt-in never silently on)' { ConvertTo-NativeServeMode '' | Should -BeExactly 'off' }
    It 'an unexpanded ${user_config...} token -> off' { ConvertTo-NativeServeMode '${user_config.nativeServe}' | Should -BeExactly 'off' }
    It 'an unrecognized value -> off' { ConvertTo-NativeServeMode 'banana' | Should -BeExactly 'off' }
    It 'the literal off -> off' { ConvertTo-NativeServeMode 'off' | Should -BeExactly 'off' }
    It 'shim (any case) -> shim' { ConvertTo-NativeServeMode 'ShIm' | Should -BeExactly 'shim' }
    It 'boolean-truthy aliases -> shim' {
        foreach ($v in @('on', 'true', '1', 'yes')) { ConvertTo-NativeServeMode $v | Should -BeExactly 'shim' }
    }
}

Describe 'ServeShim unit: byte-exact LSP framing (raw splice)' {
    BeforeAll { . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/serve-shim-common.ps1') }
    It 'round-trips a LARGE non-ASCII body byte-for-byte' {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('{"jsonrpc":"2.0","result":"')
        for ($i = 0; $i -lt 5000; $i++) { [void]$sb.Append([char]0x00E9) }   # e-acute x5000
        [void]$sb.Append(' mid '); [void]$sb.Append([char]0x4E2D); [void]$sb.Append([char]0x6587); [void]$sb.Append('"}')
        $body = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
        $ms = New-Object System.IO.MemoryStream
        Write-ServeFrame $ms $body
        $buf = New-Object System.Collections.Generic.List[byte]
        $buf.AddRange($ms.ToArray())
        $out = Read-ServeFrame $buf
        # Assert WITHOUT piping the array (piping a [byte[]] unrolls it into the pipeline).
        $out.GetType().Name | Should -Be 'Byte[]'
        $out.Length | Should -Be $body.Length
        [System.Convert]::ToBase64String($out) | Should -BeExactly ([System.Convert]::ToBase64String($body))
        $buf.Count | Should -Be 0
    }
    It 'returns $null for an incomplete frame (buffer not yet full)' {
        $buf = New-Object System.Collections.Generic.List[byte]
        $buf.AddRange([System.Text.Encoding]::ASCII.GetBytes("Content-Length: 100`r`n`r`ntooshort"))
        Read-ServeFrame $buf | Should -Be $null
    }
    It 'handles a zero-length body as an empty [byte[]] (distinct from $null)' {
        $ms = New-Object System.IO.MemoryStream
        Write-ServeFrame $ms ([byte[]]@())
        $buf = New-Object System.Collections.Generic.List[byte]
        $buf.AddRange($ms.ToArray())
        $out = Read-ServeFrame $buf
        ($null -ne $out) | Should -BeTrue
        $out.Length | Should -Be 0
    }
}

Describe 'ServeShim unit: the initialize patch (Edit-InitializeMessageForServe)' {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/serve-shim-common.ps1')
        $rich = @{
            jsonrpc = '2.0'; id = 1; method = 'initialize'
            params  = @{
                processId        = 4242
                workspaceFolders = @(@{ uri = 'file:///tmp/x'; name = 'x' })
                clientInfo       = @{ name = 'cc'; version = '9' }
                capabilities     = @{
                    workspace    = @{ configuration = $true; workspaceFolders = $true; didChangeConfiguration = @{ dynamicRegistration = $true } }
                    textDocument = @{
                        synchronization = @{ dynamicRegistration = $true; didSave = $true }
                        hover           = @{ dynamicRegistration = $true }
                        definition      = @{ dynamicRegistration = $true }
                        references      = @{ dynamicRegistration = $true }
                    }
                }
            }
        } | ConvertTo-Json -Depth 20 -Compress
        $script:Patched = Edit-InitializeMessageForServe $rich
        $script:PP = $script:Patched | ConvertFrom-Json
    }
    It 'disables dynamicRegistration everywhere (none left true)' { $script:Patched | Should -Not -Match '"dynamicRegistration":true' }
    It 'sets dynamicRegistration false (the patch actually fired)' { $script:Patched | Should -Match '"dynamicRegistration":false' }
    It 'drops the params-level workspaceFolders (the #2300 Linux init NRE dodge)' {
        ($script:PP.params.PSObject.Properties.Name -contains 'workspaceFolders') | Should -BeFalse
    }
    It 'keeps the (safe) workspace.workspaceFolders capability boolean' {
        [bool]$script:PP.params.capabilities.workspace.workspaceFolders | Should -BeTrue
    }
    It 'ensures a rename capability (the PrepareRenameHandler NRE dodge)' {
        ($script:PP.params.capabilities.textDocument.PSObject.Properties.Name -contains 'rename') | Should -BeTrue
        $script:PP.params.capabilities.textDocument.rename.prepareSupport | Should -BeTrue
        $script:PP.params.capabilities.textDocument.rename.dynamicRegistration | Should -BeFalse
    }
    It 'preserves id / method / processId untouched' {
        [int]$script:PP.params.processId | Should -Be 4242
        $script:PP.method | Should -BeExactly 'initialize'
        [int]$script:PP.id | Should -Be 1
    }
    It 'passes an unparseable message through unchanged (never corrupts a frame it cannot rewrite)' {
        Edit-InitializeMessageForServe 'not json at all' | Should -BeExactly 'not json at all'
    }
}

Describe 'ServeShim unit: the server->client intercept answer table' {
    BeforeAll { . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/serve-shim-common.ps1') }
    It 'freezes exactly the three intercepted methods' {
        (Get-ServeInterceptMethods | Sort-Object) -join ',' | Should -BeExactly 'client/registerCapability,window/workDoneProgress/create,workspace/configuration'
    }
    It 'classifies the intercepted methods as intercept' {
        foreach ($m in (Get-ServeInterceptMethods)) { Test-ServeInterceptMethod $m | Should -BeTrue }
    }
    It 'classifies OTHER server->client methods as pass-through (adversarial: unknown forwards untouched)' {
        foreach ($m in @('workspace/applyEdit', 'window/showMessageRequest', 'client/unregisterCapability', 'workspace/codeLens/refresh')) {
            Test-ServeInterceptMethod $m | Should -BeFalse
        }
    }
    It 'answers workspace/configuration with one null PER item' {
        $params = @{ items = @(@{ section = 'powershell' }, @{}) } | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        New-ServeInterceptResponseJson -Id 7 -Method 'workspace/configuration' -Params $params | Should -BeExactly '{"jsonrpc":"2.0","id":7,"result":[null,null]}'
    }
    It 'answers workspace/configuration with [] when there are no items' {
        New-ServeInterceptResponseJson -Id 9 -Method 'workspace/configuration' -Params $null | Should -BeExactly '{"jsonrpc":"2.0","id":9,"result":[]}'
    }
    It 'answers the other intercepts with null, echoing a string id verbatim' {
        New-ServeInterceptResponseJson -Id 'abc' -Method 'window/workDoneProgress/create' -Params $null | Should -BeExactly '{"jsonrpc":"2.0","id":"abc","result":null}'
        New-ServeInterceptResponseJson -Id 3 -Method 'client/registerCapability' -Params $null | Should -BeExactly '{"jsonrpc":"2.0","id":3,"result":null}'
    }
}

Describe 'ServeShim e2e: nativeServe=shim serves navigation end-to-end' -Skip:$script:SkipServe {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/serve-shim-common.ps1')
        . (Join-Path $PSScriptRoot 'ServeShim.Common.ps1')
        $srv = Initialize-ServeShimEnv -TestsDir $PSScriptRoot
        $serveInterp = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
        $script:R = Invoke-ServeShimSession -ScriptsDir $srv.ScriptsDir -Interpreter $serveInterp -Mode 'shim' -DataRoot $srv.DataDir -RunNav
        Write-Host ('[serve-shim latency, host=' + $serveInterp + '] hover=' + $script:R.Timings['hover'] + 'ms definition=' + $script:R.Timings['definition'] + 'ms references=' + $script:R.Timings['references'] + 'ms (end-to-end round-trip; PSES compute dominates, the shim adds ~1%)')
    }
    It 'launched the shim without error' { $script:R.Launched | Should -BeTrue; $script:R.Error | Should -BeExactly '' }
    It 'the patched initialize returns a result advertising the nav providers STATICALLY (dynamicRegistration=false took effect)' {
        $script:R.InitResult | Should -Not -Be $null
        $script:R.InitHasStaticNav | Should -BeTrue -Because 'the shim disables dynamicRegistration so PSES advertises hover/definition/references in the initialize result rather than via client/registerCapability'
    }
    It 'the workspaceFolders-bearing initialize completed -- the PSES #2300 dodge (on the ubuntu leg, the Linux init-patch validation)' {
        # The shim-mode client sends params-level workspaceFolders AND omits rename; only the shim's
        # patch (drop workspaceFolders + ensure rename) lets PSES complete init. A non-null init
        # result here is that dodge holding -- and on the ubuntu CI leg it closes the survey's open risk.
        $script:R.InitResult | Should -Not -Be $null
    }
    It 'hover returns contents' {
        $script:R.Hover | Should -Not -Be $null
        (Get-Prop (Get-Prop $script:R.Hover 'result') 'contents') | Should -Not -Be $null
    }
    It 'definition returns at least one location' {
        $arr = @(Get-Prop $script:R.Definition 'result')
        $arr.Count | Should -BeGreaterThan 0
        $arr[0] | Should -Not -Be $null
    }
    It 'references returns at least one location' {
        @(Get-Prop $script:R.References 'result').Count | Should -BeGreaterThan 0
    }
    It 'ZERO server->client requests leaked to the client (configuration + workDoneProgress/create + registerCapability all absorbed)' {
        $script:R.Leaks.Count | Should -Be 0 -Because ('the shim answers the intercept set locally; leaked: ' + ($script:R.Leaks -join ', '))
    }
    It 'a nav round-trip stays within a generous latency ceiling (OQ2 guard; per-leg numbers logged above)' {
        $script:R.MaxNavMs | Should -BeGreaterThan 0
        $script:R.MaxNavMs | Should -BeLessThan 30000 -Because 'an order-of-magnitude sanity ceiling, not a tight timing gate that would flake on shared runners'
    }
    It 'the shim exits cleanly and reaps its PSES child (zero orphans)' {
        $script:R.Exited | Should -BeTrue
        $script:R.PsesReaped | Should -BeTrue
    }
}

Describe 'ServeShim e2e: nativeServe=off is a transparent pass-through' -Skip:$script:SkipServe {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/serve-shim-common.ps1')
        . (Join-Path $PSScriptRoot 'ServeShim.Common.ps1')
        $srv = Initialize-ServeShimEnv -TestsDir $PSScriptRoot
        $serveInterp = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
        $script:OR = Invoke-ServeShimSession -ScriptsDir $srv.ScriptsDir -Interpreter $serveInterp -Mode 'off' -DataRoot $srv.DataDir
    }
    It 'launched the shim without error' { $script:OR.Launched | Should -BeTrue; $script:OR.Error | Should -BeExactly '' }
    It 'does NOT patch the initialize: nav providers are not statically advertised (transparent)' {
        $script:OR.InitResult | Should -Not -Be $null
        $script:OR.InitHasStaticNav | Should -BeFalse -Because 'off relays the raw dynamicRegistration=true caps, so PSES keeps the providers dynamic (not in the static init result)'
    }
    It 'does NOT intercept: server->client request(s) LEAK to the client (transparent -- byte-for-byte today behavior)' {
        $script:OR.Leaks.Count | Should -BeGreaterThan 0 -Because 'a transparent relay forwards PSES workspace/configuration + client/registerCapability to the client rather than answering them'
    }
    It 'the off-mode shim also exits cleanly and reaps its PSES child' {
        $script:OR.Exited | Should -BeTrue
        $script:OR.PsesReaped | Should -BeTrue
    }
}

Describe 'ServeShim e2e: lifecycle -- crash propagation, no orphans, no in-shim re-spawn' -Skip:$script:SkipServe {
    BeforeAll {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/lsp-common.ps1')
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/lib/serve-shim-common.ps1')
        . (Join-Path $PSScriptRoot 'ServeShim.Common.ps1')
        $srv = Initialize-ServeShimEnv -TestsDir $PSScriptRoot
        $serveInterp = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
        $script:C = Invoke-ServeShimCrash -ScriptsDir $srv.ScriptsDir -Interpreter $serveInterp -DataRoot $srv.DataDir
    }
    It 'launched and identified the PSES child' { $script:C.Launched | Should -BeTrue; $script:C.PsesPid | Should -BeGreaterThan 0 }
    It 'killing PSES mid-session makes the shim EXIT promptly (EOF propagated to the client; no in-shim re-spawn)' {
        $script:C.ShimExitedAfterCrash | Should -BeTrue -Because 'on PSES death the shim closes the client stdout and exits -- the manifest maxRestarts owns restart, so the shim must not re-spawn'
    }
    It 'the killed PSES stays reaped (zero orphan)' { $script:C.PsesReaped | Should -BeTrue }
}
