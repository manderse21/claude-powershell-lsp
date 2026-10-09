# FAKE scripts/lsp-client.ps1 that RECORDS the configuration it was handed (dispatch 000302, A1;
# the deterministic half of the read-only census).
#
# Driven by the REAL Invoke-ScanFileDiagnostics exactly as the real client is (see
# s1-silent-exit-zero.ps1). It records:
#   - every CLAUDE_PLUGIN_OPTION_* and POWERSHELL_LSP_* variable in its environment, i.e. what the
#     scanner's per-child env block actually delivered, ambient values included;
#   - through the PRODUCTION resolver (Get-PluginOption* from the lib copy beside it), the value
#     the real client would resolve for every knob it reads, with the real client's own default
#     and the provenance (env / profile / default). The key table mirrors scripts/lsp-client.ps1
#     knob for knob -- the relaunch knobs included -- and PowerShellLsp.ScanReadOnly.Tests.ps1
#     fails if the two key sets drift apart;
#   - formatMode: ConvertTo-FormatOnEditMode over the resolved formatOnEdit, the exact expression
#     that selects the real client's format path (off / suggest / apply).
# Written to <CLAUDE_PLUGIN_DATA>/env-client-<id>.json. Then it ends like a clean pass (silent,
# exit 0) -- it analyses nothing and writes no capture record.
#
# WHAT THIS CANNOT PROVE: that a formatter ran, or that a file changed. It proves which REQUEST
# the real client would make. Whether the daemon then writes the file is measured only by the
# real-daemon integration Describe in PowerShellLsp.ScanReadOnly.Tests.ps1.
#
# ASCII-only (PS 5.1 reads a UTF-8-without-BOM file through Windows-1252).

param(
    [int] $TimeoutMs = 5000,
    [int] $ConnectTimeoutMs = 2000
)

. (Join-Path $PSScriptRoot 'lib/lsp-common.ps1')
$raw = Get-StdinText   # BOM-tolerant, as the real hooks read it (a 5.1 parent prepends a BOM)
$payload = $raw | ConvertFrom-Json
$sid = [string]$payload.session_id

# scripts/lsp-client.ps1 resolves these knobs, with these defaults.
$table = @(
    @{ Key = 'timeoutMs'; Kind = 'int'; Default = $TimeoutMs }
    @{ Key = 'enableStats'; Kind = 'bool'; Default = $false }
    @{ Key = 'scopeToEdit'; Kind = 'bool'; Default = $true }
    @{ Key = 'editContextLines'; Kind = 'int'; Default = 0 }
    @{ Key = 'formatOnEdit'; Kind = 'str'; Default = 'off' }
    @{ Key = 'orgPolicy'; Kind = 'str'; Default = '' }
    @{ Key = 'ps_host'; Kind = 'str'; Default = 'pwsh' }
    @{ Key = 'severityThreshold'; Kind = 'str'; Default = 'Hint' }
    @{ Key = 'ruleInclude'; Kind = 'str'; Default = '' }
    @{ Key = 'ruleExclude'; Kind = 'str'; Default = '' }
    @{ Key = 'debounceMs'; Kind = 'int'; Default = 150 }
    @{ Key = 'idleTtlMin'; Kind = 'int'; Default = 30 }
    @{ Key = 'perFileCap'; Kind = 'int'; Default = 20 }
    @{ Key = 'settingsPath'; Kind = 'str'; Default = '' }
    @{ Key = 'ruleset'; Kind = 'str'; Default = 'pses-default' }
    @{ Key = 'moduleAwareness'; Kind = 'str'; Default = 'off' }
    @{ Key = 'referenceSurfacing'; Kind = 'str'; Default = 'off' }
)
$resolved = [ordered]@{}
foreach ($row in $table) {
    $value = switch ($row.Kind) {
        'int' { Get-PluginOptionInt ([string]$row.Key) ([int]$row.Default) }
        'bool' { Get-PluginOptionBool ([string]$row.Key) ([bool]$row.Default) }
        default { Get-PluginOption ([string]$row.Key) ([string]$row.Default) }
    }
    $prov = Get-PluginOptionProvenance -Key ([string]$row.Key) -Default ([string]$row.Default)
    $resolved[[string]$row.Key] = [ordered]@{ value = [string]$value; provenance = [string]$prov.Provenance }
}
$envSeen = [ordered]@{}
foreach ($entry in @([System.Environment]::GetEnvironmentVariables().GetEnumerator() | Sort-Object Key)) {
    $n = [string]$entry.Key
    if ($n.StartsWith('CLAUDE_PLUGIN_OPTION_', [System.StringComparison]::OrdinalIgnoreCase) -or
        $n.StartsWith('POWERSHELL_LSP_', [System.StringComparison]::OrdinalIgnoreCase)) {
        $envSeen[$n] = [string]$entry.Value
    }
}
$record = [ordered]@{
    role       = 'client'
    sessionId  = $sid
    formatMode = (ConvertTo-FormatOnEditMode (Get-PluginOption 'formatOnEdit' 'off'))
    resolved   = $resolved
    env        = $envSeen
}
$dataRoot = Get-PluginDataRoot
$name = 'env-client-' + [guid]::NewGuid().ToString('N').Substring(0, 12) + '.json'
[System.IO.File]::WriteAllText((Join-Path $dataRoot $name), ($record | ConvertTo-Json -Depth 6))
exit 0
