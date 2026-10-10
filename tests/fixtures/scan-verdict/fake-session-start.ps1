# FAKE scripts/session-start.ps1 for the scan harness (dispatch 000302, A1).
#
# Copied beside a fake (or relocated) scanner as session-start.ps1, so the REAL Start-ScanDaemon
# (scripts/lib/lsp-scan-common.ps1) drives it exactly as it drives the real hook: stdin carries
# the session id, and -PreferredHost / -MaxWaitMs arrive as arguments. It does two things and
# starts no daemon:
#
#   1. TRANSPORT CENSUS. It records which configuration reached it: every CLAUDE_PLUGIN_OPTION_*
#      and POWERSHELL_LSP_* variable in its environment, and -- through the PRODUCTION resolver
#      (Get-PluginOption* from the lib copy beside it) -- the value the real session-start would
#      resolve for each knob it reads, with the real script's own default and the provenance
#      (env / profile / default). The key table mirrors scripts/session-start.ps1 knob for knob;
#      PowerShellLsp.ScanReadOnly.Tests.ps1 fails if the two key sets drift apart. Written to
#      <CLAUDE_PLUGIN_DATA>/env-session-start-<id>.json.
#
#   2. READINESS. It writes <CLAUDE_PLUGIN_DATA>/session/<id>.json with state 'ready' so
#      Start-ScanDaemon returns at once. The record carries NO pid and NO psesPid on purpose:
#      Stop-ScanDaemon kills whatever pids the record names, and this fake owns no process.
#
# ASCII-only (PS 5.1 reads a UTF-8-without-BOM file through Windows-1252).

param(
    [string] $PreferredHost = 'pwsh',
    [int] $MaxWaitMs = 0
)

. (Join-Path $PSScriptRoot 'lib/lsp-common.ps1')
$raw = Get-StdinText   # BOM-tolerant, as the real hooks read it (a 5.1 parent prepends a BOM)
$sid = [string](($raw | ConvertFrom-Json).session_id)

# scripts/session-start.ps1 resolves these knobs, with these defaults (its param defaults; the
# ps_host default is the -PreferredHost the scanner passed).
$table = @(
    @{ Key = 'ps_host'; Kind = 'str'; Default = $PreferredHost }
    @{ Key = 'severityThreshold'; Kind = 'str'; Default = 'Hint' }
    @{ Key = 'ruleInclude'; Kind = 'str'; Default = '' }
    @{ Key = 'ruleExclude'; Kind = 'str'; Default = '' }
    @{ Key = 'keepLastN'; Kind = 'int'; Default = 10 }
    @{ Key = 'debounceMs'; Kind = 'int'; Default = 150 }
    @{ Key = 'idleTtlMin'; Kind = 'int'; Default = 30 }
    @{ Key = 'perFileCap'; Kind = 'int'; Default = 20 }
    @{ Key = 'settingsPath'; Kind = 'str'; Default = '' }
    @{ Key = 'ruleset'; Kind = 'str'; Default = 'pses-default' }
    @{ Key = 'orgPolicy'; Kind = 'str'; Default = '' }
    @{ Key = 'moduleAwareness'; Kind = 'str'; Default = 'off' }
    @{ Key = 'referenceSurfacing'; Kind = 'str'; Default = 'off' }
)
$resolved = [ordered]@{}
foreach ($row in $table) {
    $value = switch ($row.Kind) {
        'int' { Get-PluginOptionInt ([string]$row.Key) ([int]$row.Default) }
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
    role          = 'session-start'
    sessionId     = $sid
    preferredHost = $PreferredHost
    maxWaitMs     = $MaxWaitMs
    resolved      = $resolved
    env           = $envSeen
}
$dataRoot = Get-PluginDataRoot
[System.IO.File]::WriteAllText((Join-Path $dataRoot ('env-session-start-' + $sid + '.json')), ($record | ConvertTo-Json -Depth 6))

$sessionDir = Get-SessionDir
New-ContainedDirectory -Path $sessionDir
$ready = [ordered]@{ state = 'ready'; sessionId = $sid; fake = 'tests/fixtures/scan-verdict/fake-session-start.ps1' }
[System.IO.File]::WriteAllText((Join-Path $sessionDir ($sid + '.json')), ($ready | ConvertTo-Json -Compress))
exit 0
