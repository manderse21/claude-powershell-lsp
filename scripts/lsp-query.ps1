#Requires -Version 5.1

# lsp-query.ps1 -- the first-party semantic query entry point (dispatch 000287,
# ENTERPRISE-PROGRAM-DOCKET P1-2; review items 9 and 10. The two symbol ops: dispatch 000288).
#
# WHAT THIS IS. Ask the warm per-session daemon a semantic question about PowerShell source and
# get PSES's own answer back as JSON. The daemon already runs PowerShell Editor Services and
# already speaks LSP to it; every one of these operations is a request PSES serves today and
# nothing in this repository was asking.
#
# THREE REQUEST SHAPES, because the operations genuinely have three. The daemon's spec table is
# the one authority for which op is which:
#   position  definition, references, hover  -- a file and a 1-based line/col
#   document  documentSymbol                 -- a file, and NO position
#   query     workspaceSymbol                -- a query string, and NO file
# The two symbol ops are NOT given a fabricated position. A well-formed request about a place the
# caller never named gets a confident answer to a question nobody asked.
#
# WHY IT IS NOT ROUTED THROUGH THE CLIENT. The standing GATED arc in ROADMAP-powershell-lsp.md is
# on *serving through the Claude Code client*. This path has no client in it: it is a script the
# agent runs, over the plugin's own daemon, and it returns to the caller. That is the whole reason
# the docket rates this the highest capability-per-freeze slice it carries.
#
# FREEZE EXPOSURE: ZERO on both frozen surfaces. A new command entry point is neither one of
# CONTRACT.md's twenty userConfig knob names nor one of its diagnostics status tokens, and this
# script adds neither. -Op is a CLI parameter, exactly as -Format is on lsp-scan.ps1.
#
# POSITIONS ARE 1-BASED HERE, which is what every editor, stack trace and diagnostics record this
# plugin emits reports. The daemon converts to LSP's 0-based positions in exactly one place
# (Get-QueryRequestPlan). Do not pre-convert here: two conversions is one too many.
#
# Exit codes:
#   0  the daemon answered. A query with no results is an ANSWER (results: []), not a failure.
#   3  usage error: no live daemon in scope, or a position this script can reject up front.
#   4  the daemon was reached but could not answer (PSES down, file not found, op refused).
#
# Fail-loud, deliberately unlike lsp-client.ps1: that one is an edit-path hook that must never
# block a user's flow, so it degrades to silence. This is an explicit question someone asked, and
# a silent empty answer to an explicit question is the worst of the available behaviours.
#
# ASCII-only (PS 5.1 em-dash trap); StrictMode-safe.
#
# Author: Mike Andersen / powershell-lsp plugin.

[CmdletBinding()]
param(
    # The operation. The daemon owns the vocabulary (Get-QueryOps); this set is validated there
    # too, so a value that gets past the ValidateSet is still refused by name rather than guessed.
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('definition', 'references', 'hover', 'documentSymbol', 'workspaceSymbol')]
    [string] $Op,

    # The file to ask about: a .ps1 / .psm1 / .psd1 path. NOT required by workspaceSymbol, which
    # asks the workspace and names no file; the daemon refuses an op whose inputs are missing.
    [Parameter(Position = 1)]
    [string] $File,

    # 1-BASED line and column, for the ops that TAKE a position (definition, references, hover).
    # documentSymbol and workspaceSymbol take none and are not given a fabricated one. See the
    # header: no conversion happens in this script.
    [Parameter(Position = 2)]
    [int] $Line,

    [Parameter(Position = 3)]
    [int] $Col,

    # The symbol query for workspaceSymbol -- the string PSES matches symbol names against.
    [string] $Query = '',

    # Emit the daemon's response as JSON (the machine-readable default) rather than a short
    # human-readable rendering.
    [switch] $Text,

    # Which session's daemon to ask. Defaults to $env:CLAUDE_SESSION_ID; with neither, the
    # script discovers a live daemon and refuses if there is more than one -- an unscoped run
    # that finds several daemons is honestly ambiguous, never a guess.
    [string] $SessionId = '',

    [int] $TimeoutMs = 15000,
    [int] $ConnectTimeoutMs = 2000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/lsp-common.ps1')

function Write-QueryError([string]$Message) {
    [Console]::Error.WriteLine('powershell-lsp query: ' + $Message)
}

function Resolve-QueryPipeName([string]$Sid) {
    # Returns the pipe name, or '' with the reason written to stderr. The rule is the doctor's
    # rule (scripts/doctor.ps1, Get-DoctorDaemonObservation): a live candidate is a parseable
    # session handle whose recorded pid is alive; several live daemons and no session id is
    # UNKNOWN rather than a pick.
    if (-not [string]::IsNullOrWhiteSpace($Sid)) { return ('powershell-lsp-' + $Sid) }

    $sessionDir = ''
    try { $sessionDir = Get-SessionDir } catch { $sessionDir = '' }
    if ([string]::IsNullOrWhiteSpace($sessionDir) -or -not (Test-Path -LiteralPath $sessionDir)) {
        Write-QueryError 'no session directory -- start an edit in this session so the daemon comes up, or pass -SessionId.'
        return ''
    }
    $files = @()
    try { $files = @(Get-ChildItem -LiteralPath $sessionDir -Filter '*.json' -File -ErrorAction SilentlyContinue) } catch { $files = @() }

    $live = @()
    foreach ($f in $files) {
        $obj = $null
        try { $obj = (Get-Content -LiteralPath $f.FullName -Raw) | ConvertFrom-Json } catch { $obj = $null }
        if ($null -eq $obj) { continue }
        $recPid = 0
        $pv = Get-Prop $obj 'pid'
        if ($null -ne $pv) { try { $recPid = [int]$pv } catch { $recPid = 0 } }
        if ($recPid -le 0) { continue }
        $alive = $false
        try { $alive = ($null -ne (Get-Process -Id $recPid -ErrorAction SilentlyContinue)) } catch { $alive = $false }
        if (-not $alive) { continue }
        $pipe = [string](Get-Prop $obj 'pipe')
        if ([string]::IsNullOrWhiteSpace($pipe)) { $pipe = 'powershell-lsp-' + [string](Get-Prop $obj 'sessionId') }
        $live += $pipe
    }
    if (@($live).Count -eq 0) {
        Write-QueryError 'no live daemon found. Edit a PowerShell file in this session to start one, or pass -SessionId.'
        return ''
    }
    if (@($live).Count -gt 1) {
        Write-QueryError ('found ' + @($live).Count + ' live daemons and no -SessionId to choose between them; pass -SessionId.')
        return ''
    }
    return [string]$live[0]
}

# Reject up front only what this script can know without the daemon. Everything else -- whether
# the file exists, whether the position is inside it, whether PSES is up -- is the daemon's to
# answer, and answering it twice is how two answers come to disagree.
# Only what the CALLER SUPPLIED is checked here. An op that takes no position leaves -Line and
# -Col unbound at their 0 default, and rejecting that would refuse documentSymbol for failing a
# rule that does not apply to it. Which ops take a position is the daemon's spec to know.
if ($PSBoundParameters.ContainsKey('Line') -and $Line -lt 1) {
    Write-QueryError ('line must be 1-based (got ' + $Line + ')'); exit 3
}
if ($PSBoundParameters.ContainsKey('Col') -and $Col -lt 1) {
    Write-QueryError ('col must be 1-based (got ' + $Col + ')'); exit 3
}

$sid = $SessionId
if ([string]::IsNullOrWhiteSpace($sid)) { $sid = [string]$env:CLAUDE_SESSION_ID }
$pipeName = Resolve-QueryPipeName $sid
if ([string]::IsNullOrWhiteSpace($pipeName)) { exit 3 }

# Send the file as an ABSOLUTE path: the daemon's working directory is its own, not the caller's,
# so a relative path would resolve against the wrong root and report "file not found" about a file
# that is plainly there.
$fileArg = $File
if (-not [string]::IsNullOrWhiteSpace($File)) {
    try { $fileArg = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $File)) } catch { $fileArg = $File }
} else {
    # No file named. Resolving '' against the cwd would send the daemon the DIRECTORY, and
    # "file not found" about a path the caller never typed is a confusing way to be refused.
    $fileArg = ''
}

$client = $null
try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipeName,
        [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
    $client.Connect([Math]::Min($ConnectTimeoutMs, $TimeoutMs))
    $writer = New-Object System.IO.StreamWriter($client, (New-Object System.Text.UTF8Encoding($false)), 4096, $true)
    $writer.NewLine = "`n"; $writer.AutoFlush = $true
    $reader = New-Object System.IO.StreamReader($client, [System.Text.Encoding]::UTF8, $false, 4096, $true)

    $reqObj = [ordered]@{ action = 'query'; op = $Op; file = $fileArg; line = $Line; col = $Col
        query = $Query }
    # Protocol handshake (dispatch 000282, P1-4). This is the FOURTH request-building site in the
    # tree and it announces itself exactly like the other three -- a handshake present on the hook
    # path and absent on this one would tell a daemon nothing it could rely on. The census test in
    # tests/PowerShellLsp.ProtocolHandshake.Tests.ps1 DERIVES the site set from source, so a fifth
    # site that forgets these two lines fails CI rather than shipping quietly.
    $reqObj['protocolVersion'] = Get-LspProtocolVersion
    $reqObj['capabilities'] = Get-LspClientCapabilities
    $writer.WriteLine(($reqObj | ConvertTo-Json -Compress))
    $writer.Flush()

    $remaining = [Math]::Max(1, $TimeoutMs - [int]$sw.ElapsedMilliseconds)
    $readTask = $reader.ReadLineAsync()
    if (-not $readTask.Wait($remaining)) { Write-QueryError ('no response within ' + $TimeoutMs + 'ms'); exit 4 }
    $line = $readTask.Result
    if ([string]::IsNullOrWhiteSpace($line)) { Write-QueryError 'empty response from the daemon'; exit 4 }

    $resp = $line | ConvertFrom-Json
    if (-not [bool](Get-Prop $resp 'ok')) {
        Write-QueryError ([string](Get-Prop $resp 'error'))
        exit 4
    }

    if ($Text) {
        $count = [int](Get-Prop $resp 'count')
        # The subject line is rendered from the KIND the daemon reports, not from a second copy
        # of the op table kept here. Each kind names what the caller actually asked about: a
        # position query names the position, a document query names the file, and a workspace
        # query names the string it searched for. An unrecognised kind renders the op alone
        # rather than inventing a position it was never given.
        $kind = [string](Get-Prop $resp 'kind')
        $subject = switch ($kind) {
            'position' { $Op + ' at ' + $File + ':' + $Line + ':' + $Col }
            'document' { $Op + ' ' + $File }
            'query' { $Op + " '" + $Query + "'" }
            default { $Op }
        }
        Write-Output ($subject + ' -- ' + $count + ' result(s)')
        foreach ($r in @(Get-Prop $resp 'results')) {
            Write-Output ('  ' + ($r | ConvertTo-Json -Depth 12 -Compress))
        }
    } else {
        Write-Output ($resp | ConvertTo-Json -Depth 12)
    }
    exit 0
} catch {
    Write-QueryError $_.Exception.Message
    exit 4
} finally {
    try { if ($null -ne $client) { $client.Dispose() } } catch { }
}
