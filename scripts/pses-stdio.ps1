#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Resolve bundle path. env var set by plugin.json lspServers.env, with a fallback.
$bundle = $env:PSES_BUNDLE_PATH
if ([string]::IsNullOrWhiteSpace($bundle)) {
    $dataRoot = $env:CLAUDE_PLUGIN_DATA
    if (-not [string]::IsNullOrWhiteSpace($dataRoot)) {
        $bundle = Join-Path $dataRoot 'PowerShellEditorServices'
    }
}

$startScript = Join-Path $bundle 'PowerShellEditorServices/Start-EditorServices.ps1'
if (-not (Test-Path -LiteralPath $startScript)) {
    # Emit to STDERR only. stdout is reserved for the LSP stream.
    [Console]::Error.WriteLine('PSES not found at: ' + $startScript + '. Run a new session so ensure-pses.ps1 can bootstrap it, or check the logs.')
    exit 1
}

$logDir = $env:CLAUDE_PLUGIN_DATA
if ([string]::IsNullOrWhiteSpace($logDir)) { $logDir = $env:TEMP }
$logDir = Join-Path $logDir 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logPath = Join-Path $logDir 'pses-lsp.log'
$sessionDetails = Join-Path $logDir 'pses-session.json'

# -Stdio routes LSP over stdout. No -EnableConsoleRepl (mutually exclusive with stdio LSP).
# -SessionDetailsPath is set so PSES writes its session-details JSON into the plugin data
# dir instead of dropping a PowerShellEditorServices.json into the LSP process working
# directory (which would litter the user's project). The client does not read it back in
# stdio mode; it is purely informational here.
& $startScript `
    -BundledModulesPath $bundle `
    -LogPath $logPath `
    -LogLevel Information `
    -SessionDetailsPath $sessionDetails `
    -HostName 'Claude Code' `
    -HostProfileId 'claude-code' `
    -HostVersion '1.0.0' `
    -FeatureFlags @() `
    -AdditionalModules @() `
    -Stdio
