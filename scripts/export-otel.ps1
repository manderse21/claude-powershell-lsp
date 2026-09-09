#Requires -Version 5.1

# export-otel.ps1 -- render the Track A telemetry log (stats.jsonl) as OTLP metrics, and
# optionally POST them to the collector named by POWERSHELL_LSP_OTEL_ENDPOINT.
#
# P2-1 (docs/roadmap-ii/ENTERPRISE-PROGRAM-DOCKET.md item 7). This is a READER, out of band
# with every edit: it is the same shape as scripts/show-stats.ps1 and shares its log, its
# percentile definition and its data-root provenance handling. NOTHING in the per-edit hook
# path calls it, which is the design decision that keeps an export from ever adding latency
# to a diagnostic or a failure mode to an edit.
#
# WHAT LEAVES THE HOST is decided by scripts/lib/otel-common.ps1's allowlist, not here. A stats
# row carries the ABSOLUTE path of the edited file; the renderer never copies a row's fields
# wholesale, so no path, and no field added to the row later, can reach the wire without
# somebody putting it on that list on purpose.
#
# SENDING IS OPT-IN TWICE. The endpoint must be set AND -Send must be passed. With no -Send
# this prints the payload and exits, which is how an administrator sees exactly what would be
# transmitted before anything is.
#
# Usage:
#   pwsh -File scripts/export-otel.ps1 -Show          # what is configured; sends nothing
#   pwsh -File scripts/export-otel.ps1                # render the payload to stdout
#   pwsh -File scripts/export-otel.ps1 -OutFile x.json
#   pwsh -File scripts/export-otel.ps1 -Send          # render AND POST to the collector
#
# Exit codes: 0 rendered (and sent, if asked); 1 refused (nothing was sent and why is printed);
#             2 the POST itself failed.
#
# Author: Mike Andersen / powershell-lsp plugin.

param(
    # Explicit stats.jsonl to read. Default: the live log dir's stats.jsonl. Its rolled
    # sibling (<path>.1) is included automatically when present.
    [string] $Path = '',

    # Report the endpoint resolution and the sample count, then exit. Sends nothing, renders
    # nothing. This is the "is the control actually active on this host" question.
    [switch] $Show,

    # POST the payload to the configured collector. Without it this script never opens a socket.
    [switch] $Send,

    # Write the payload here instead of stdout.
    [string] $OutFile = '',

    # Seconds to wait on the POST before giving up.
    [int] $TimeoutSec = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/lsp-common.ps1')
. (Join-Path $PSScriptRoot 'lib/otel-common.ps1')

# DATA-ROOT PROVENANCE (dispatch 000185, D1-C), handled exactly as show-stats.ps1 handles it:
# only the DEFAULT path is exposed to the silent fallback, because an explicit -Path is a
# directory the caller named and a miss there is a real miss. The distinction matters more here
# than in the viewer -- "no telemetry" rendered as an empty export is a claim to a collector.
$script:RootKnown = $true
$script:Provenance = 'explicit:-Path'
if ([string]::IsNullOrWhiteSpace($Path)) {
    $res = Get-PluginDataRootResolution
    $script:RootKnown = [bool]$res.Known
    $script:Provenance = [string]$res.Provenance
    $Path = Join-Path (Get-LogDir) 'stats.jsonl'
}

function Read-StatsLines {
    # Parsed rows from one JSONL file, skipping blank / malformed lines. Missing file -> empty.
    # JSONL, not a JSON array, so a partial last line never breaks the read.
    param([string] $File)
    if (-not (Test-Path -LiteralPath $File)) { return @() }
    $out = @()
    foreach ($line in @(Get-Content -LiteralPath $File -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $out += ($line | ConvertFrom-Json) } catch { }
    }
    return @($out)
}

$info = Get-OtelEndpointInfo

if ($Show) {
    Write-Host ('powershell-lsp OTel export -- ' + $Path)
    Write-Host ('  data root resolved via: ' + $script:Provenance +
        '   data-root known: ' + $(if ($script:RootKnown) { 'YES' } else { 'NO' }))
    Write-Host ('  POWERSHELL_LSP_OTEL_ENDPOINT configured: ' + $(if ($info.configured) { 'YES' } else { 'NO' }))
    Write-Host ('  value recognized as an http/https URL:   ' + $(if ($info.recognized) { 'YES' } else { 'NO' }))
    if ($info.configured) {
        Write-Host ('  collector: ' + $info.display)
    } elseif (-not [string]::IsNullOrWhiteSpace($info.raw)) {
        # The raw value is NOT echoed. It failed to parse as a URL, so nothing here can
        # promise it is not a credential, and printing it is the one irreversible act
        # available to a report that exists to avoid exactly that.
        Write-Host '  a value IS set but did not parse as an absolute http/https URL -- export is OFF.'
        Write-Host '    (the value is not echoed here; it did not parse, so it cannot be shown safely)'
    } else {
        Write-Host '  no value set -- export is OFF.'
    }
    $n = @(@(Read-StatsLines -File $Path) + @(Read-StatsLines -File ($Path + '.1'))).Count
    Write-Host ('  samples available: ' + $n)
    exit 0
}

$records = @(@(Read-StatsLines -File $Path) + @(Read-StatsLines -File ($Path + '.1')))

if (@($records).Count -eq 0 -and -not $script:RootKnown) {
    # A FALLBACK ROOT CANNOT SUPPORT "no telemetry recorded yet" (dispatch 000185, D1-C). In a
    # viewer that is a misleading sentence; in an EXPORTER it would be a zero published to a
    # fleet dashboard, which reads as "this host is idle" rather than "this reader looked in a
    # directory nobody told it about". Refuse rather than export a number that means neither.
    Write-Host 'REFUSED: no telemetry found under a FALLBACK data root -- cannot tell "none recorded"'
    Write-Host '  from "not here". Set CLAUDE_PLUGIN_DATA to the real data root, or pass -Path.'
    exit 1
}

$payload = ConvertTo-OtelResourceMetrics -Records $records -ServiceVersion (Get-PluginVersion)
$json = ($payload | ConvertTo-Json -Depth 12 -Compress)

if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutFile, $json + "`n", $enc)
    Write-Host ('wrote ' + $json.Length + ' bytes to ' + $OutFile + ' (' + @($records).Count + ' samples)')
} else {
    Write-Output $json
}

if (-not $Send) { exit 0 }

if (-not $info.configured) {
    Write-Host 'REFUSED to send: POWERSHELL_LSP_OTEL_ENDPOINT is not set to an absolute http/https URL.'
    exit 1
}

try {
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        # Windows PowerShell 5.1 negotiates whatever ServicePointManager was left holding, which
        # on an unconfigured host still includes TLS 1.0. A collector that (correctly) refuses
        # it fails with a connection reset that says nothing about the cause, so ask for 1.2
        # explicitly rather than let the default decide.
        [Net.ServicePointManager]::SecurityProtocol = `
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($json)
    $resp = Invoke-WebRequest -Uri $info.endpoint -Method Post -Body $bytes `
        -ContentType 'application/json' -TimeoutSec $TimeoutSec -UseBasicParsing
    Write-Host ('sent ' + $bytes.Length + ' bytes to ' + $info.display + ' -- HTTP ' + [int]$resp.StatusCode)
    exit 0
} catch {
    # The endpoint is reported by its REDACTED display form even in the failure path: an error
    # message is the most-copied string a tool produces.
    Write-Host ('SEND FAILED to ' + $info.display + ': ' + $_.Exception.Message)
    exit 2
}
