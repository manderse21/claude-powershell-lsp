#Requires -Version 5.1

# lsp-common.ps1 -- shared helpers dot-sourced by the daemon, the PostToolUse
# client, the session hooks, and the Pester suite. No side effects on import:
# defines functions only. ASCII-only (PS 5.1 em-dash trap).
#
# Author: Mike Andersen / powershell-lsp plugin.

# --- environment / paths ---------------------------------------------------

function Get-PluginDataRoot {
    # All state, logs, pids, and the vendored PSSA live under CLAUDE_PLUGIN_DATA.
    # Never under CLAUDE_PLUGIN_ROOT (read-only plugin tree). Fall back to a temp
    # subdir only so out-of-band invocations (tests) do not explode.
    $root = $env:CLAUDE_PLUGIN_DATA
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) 'powershell-lsp-data'
    }
    return $root
}

function Get-SessionDir {
    return (Join-Path (Get-PluginDataRoot) 'session')
}

function Get-LogDir {
    return (Join-Path (Get-PluginDataRoot) 'logs')
}

function Get-PssaModuleDir {
    # Vendored PSScriptAnalyzer destination, prepended to the PSES child's
    # PSModulePath so the analyzer pass runs.
    return (Join-Path (Get-PluginDataRoot) 'modules')
}

function Get-PsesBundleRoot {
    # Resolution order: explicit env (set by plugin.json lspServers.env for the
    # parked path), then the canonical CLAUDE_PLUGIN_DATA location.
    $bundle = $env:PSES_BUNDLE_PATH
    if ([string]::IsNullOrWhiteSpace($bundle)) {
        $bundle = Join-Path (Get-PluginDataRoot) 'PowerShellEditorServices'
    }
    return $bundle
}

function Get-PsesStartScript {
    return (Join-Path (Get-PsesBundleRoot) 'PowerShellEditorServices/Start-EditorServices.ps1')
}

# --- host detection (Stage 2 shared helper) --------------------------------

function Resolve-PsHost {
    # D1: prefer pwsh 7; fall back to Windows PowerShell 5.1; $null if neither.
    # An explicit preference (user_config ps_host) is honored first when present.
    param([string]$Preferred)

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($Preferred)) { $candidates += $Preferred }
    foreach ($c in @('pwsh', 'powershell')) {
        if ($candidates -notcontains $c) { $candidates += $c }
    }
    foreach ($exe in $candidates) {
        $cmd = Get-Command $exe -ErrorAction SilentlyContinue
        if ($null -ne $cmd) { return $exe }
    }
    return $null
}

# --- userConfig env fallback (v1.1.1 first-run fix) ------------------------
# Hook commands no longer pass ${user_config.*} (CC v2.1.167 refuses to launch a
# hook when any referenced option is unset -- the schema default is not applied to
# the substitution -- which errored every hook on a clean install). Scripts read
# each knob from the CLAUDE_PLUGIN_OPTION_<key> env vars CC exports to plugin
# subprocesses, each with a fallback default.

function Get-PluginOption {
    # Return the CLAUDE_PLUGIN_OPTION_<key> value, or $Default if absent/blank. The
    # exported name's casing is normalized away (underscores stripped, lower-cased)
    # so 'ps_host' matches CLAUDE_PLUGIN_OPTION_PS_HOST / _ps_host / _psHost alike.
    param([string]$Key, [string]$Default = '')
    $target = ($Key -replace '_', '').ToLowerInvariant()
    $prefix = 'CLAUDE_PLUGIN_OPTION_'
    foreach ($entry in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) {
        $name = [string]$entry.Key
        if ($name.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $k = ($name.Substring($prefix.Length) -replace '_', '').ToLowerInvariant()
            if ($k -eq $target) {
                $val = [string]$entry.Value
                if (-not [string]::IsNullOrWhiteSpace($val)) { return $val }
            }
        }
    }
    return $Default
}

function Get-PluginOptionInt {
    # Integer Get-PluginOption: fall back to $Default on absent / blank / non-numeric
    # (e.g. an unexpanded '${user_config...}' token).
    param([string]$Key, [int]$Default)
    $raw = Get-PluginOption $Key ''
    $n = 0
    if ([int]::TryParse($raw, [ref]$n)) { return $n }
    return $Default
}

function Get-PluginOptionBool {
    # Boolean Get-PluginOption, mirroring Get-PluginOptionInt's fallback shape. The
    # userConfig manifest types every option as a STRING (perFileCap = '20',
    # timeoutMs = '5000'), so a boolean knob arrives as the text 'true'/'false'.
    # 'true'/'1'/'yes'/'on' (case-insensitive) -> $true; 'false'/'0'/'no'/'off' ->
    # $false; absent / blank / an unexpanded '${user_config...}' token -> $Default.
    param([string]$Key, [bool]$Default = $false)
    $raw = (Get-PluginOption $Key '').Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    switch ($raw.ToLowerInvariant()) {
        'true'  { return $true }
        '1'     { return $true }
        'yes'   { return $true }
        'on'    { return $true }
        'false' { return $false }
        '0'     { return $false }
        'no'    { return $false }
        'off'   { return $false }
        default { return $Default }
    }
}

# --- PSScriptAnalyzer settings resolution (dispatch 000018) ----------------
# Honor a repo-local PSScriptAnalyzerSettings.psd1 by resolving its ABSOLUTE path
# and letting PSES READ it (we never parse or execute the user's .psd1 ourselves --
# it is PowerShell data, an arbitrary-code risk; PSES is the trusted consumer).
# Track 1 (cited from PSES v4.6.0 source) pinned the mechanism and the bound:
#   - PSES takes the path via workspace/didChangeConfiguration as
#     Powershell.ScriptAnalysis.SettingsPath (camelCased on the wire) and hands it
#     straight to PSScriptAnalyzer (WithSettingsFile). Granularity is per-SESSION
#     (one analysis engine, rebuilt on a config change) -- not per-file.
#   - WorkspaceService.FindFileInWorkspace returns a ROOTED path AS-IS, BEFORE the
#     WorkspaceFolders loop -- and the daemon deliberately leaves workspaceFolders
#     EMPTY (the #2300 Linux OnInitialize NRE dodge). So an ABSOLUTE path sidesteps
#     that loop entirely (no workspace-root field, no collision); a RELATIVE path
#     would resolve against PSES's process CWD (the daemon's log dir) and miss.
#     Hence: absolute only.

function New-ScriptAnalysisSettings {
    # The PSES `scriptAnalysis` settings object: `enable` always, plus `settingsPath`
    # ONLY when one is resolved. Omitting settingsPath is the no-config path -- PSES
    # then loads its default rules (byte-unchanged from before honoring). Used for
    # BOTH the didChangeConfiguration push and the workspace/configuration pull
    # response so the two config channels never disagree.
    param([string]$SettingsPath = '')
    $sa = @{ enable = $true }
    if (-not [string]::IsNullOrWhiteSpace($SettingsPath)) { $sa['settingsPath'] = $SettingsPath }
    return $sa
}

function Resolve-PssaSettingsPath {
    # Resolve the ABSOLUTE PSScriptAnalyzerSettings.psd1 to honor, or '' if none.
    # Precedence: explicit absolute override > nearest PSScriptAnalyzerSettings.psd1
    # walked up from the edited file's directory, bounded at (and including) the
    # project root > '' (PSES loads default rules). Best-effort and cheap: a path
    # walk-up is a chain of stats, off the hot path (resolved once per session).
    #
    # Adversarial control: drop the `$rootFull` bound (walk to the filesystem root)
    # and the 'settings file ABOVE the project root is not honored' unit test goes
    # RED; return $Override unconditionally and the 'relative override is ignored'
    # test goes RED.
    param(
        [string]$EditedFilePath,
        [string]$ProjectRoot,
        [string]$Override = ''
    )
    # Explicit override -- ABSOLUTE only (Mike's gate; a relative override cannot
    # resolve safely through PSES, so it is ignored and we fall through to
    # discovery). Existence is left to PSES (it logs + loads defaults if the file is
    # missing); we resolve only the path, never read it.
    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        if ([System.IO.Path]::IsPathRooted($Override)) {
            return [System.IO.Path]::GetFullPath($Override)
        }
    }
    if ([string]::IsNullOrWhiteSpace($EditedFilePath)) { return '' }
    $fileFull = [System.IO.Path]::GetFullPath($EditedFilePath)
    $dir = [System.IO.Path]::GetDirectoryName($fileFull)
    if ([string]::IsNullOrWhiteSpace($dir)) { return '' }

    $sep = [System.IO.Path]::DirectorySeparatorChar
    $alt = [System.IO.Path]::AltDirectorySeparatorChar
    $rootFull = ''
    if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
        try { $rootFull = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd($sep, $alt) } catch { $rootFull = '' }
    }

    $cur = $dir
    while (-not [string]::IsNullOrWhiteSpace($cur)) {
        $candidate = Join-Path $cur 'PSScriptAnalyzerSettings.psd1'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
        $curTrim = $cur.TrimEnd($sep, $alt)
        if ($rootFull -ne '' -and $curTrim -eq $rootFull) { break }   # reached the project root: stop (the bound)
        $parent = [System.IO.Path]::GetDirectoryName($cur)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $cur) { break }   # filesystem root
        if ($rootFull -ne '') {
            # If the edited file lives OUTSIDE the project root, do not walk above its
            # own directory -- never escape an out-of-workspace file upward.
            $under = ($curTrim -eq $rootFull) -or $curTrim.StartsWith($rootFull + $sep, [System.StringComparison]::OrdinalIgnoreCase)
            if (-not $under) { break }
        }
        $cur = $parent
    }
    return ''
}

# --- telemetry / stats (Track A) -------------------------------------------
# Observe-only per-edit timing. The writer is best-effort and FAIL-SAFE by
# contract: any failure (locked file, a directory squatting the path, disk full)
# is swallowed so a telemetry hiccup can never affect the diagnostics emit or the
# hook's exit code. JSONL (one object per line) -- not a JSON array -- so the
# readout can stream it and PS 5.1's empty-array-returns-null quirk on read never
# bites. Caller stamps the record (ts, path, ext, stage timings, counts); this
# only serializes + appends with a single-rollover size cap.

function Write-StatsLine {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Record,
        # ~5 MB live-file cap; one rollover to stats.jsonl.1 -> bounded ~2x on disk.
        [int]$CapBytes = 5242880
    )
    try {
        $dir = Get-LogDir
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $statsFile = Join-Path $dir 'stats.jsonl'
        # Rotate BEFORE appending when the live file has reached the cap: move it to
        # .1 (overwriting any prior .1) and start a fresh live file. Single rollover.
        if (Test-Path -LiteralPath $statsFile) {
            $item = Get-Item -LiteralPath $statsFile -ErrorAction Stop
            if ([long]$item.Length -ge $CapBytes) {
                Move-Item -LiteralPath $statsFile -Destination ($statsFile + '.1') -Force -ErrorAction Stop
            }
        }
        $line = ($Record | ConvertTo-Json -Depth 8 -Compress)
        # UTF-8 without BOM, explicit LF. (PS 5.1's ConvertTo-Json escapes non-ASCII
        # to \uXXXX, but pwsh 7 emits it literally -- so UTF-8 keeps a non-ASCII path
        # intact across hosts; this is a data file, not a parsed .ps1.)
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::AppendAllText($statsFile, ($line + "`n"), $enc)
    } catch { }
}

# --- platform helpers (cross-platform forward-compat) ----------------------
# Non-Windows branches below are AUTHORED but CI-verified later (this build runs
# Windows only). They exist so the Windows-only calls are isolated and guarded.

function Test-OnWindows {
    # $IsWindows exists only on PowerShell 6+. Windows PowerShell 5.1 has no such
    # automatic variable and is always Windows. StrictMode-safe existence check.
    if (Test-Path 'Variable:\IsWindows') { return [bool]$IsWindows }
    return $true
}

function Add-ProcessArguments {
    # Set process arguments cross-version. PowerShell 7+ (.NET Core) has
    # ProcessStartInfo.ArgumentList (correct auto-quoting); Windows PowerShell 5.1
    # (.NET Framework) does NOT -- it only has the .Arguments string, which we
    # quote by hand. pwsh keeps using ArgumentList (the proven path), unchanged.
    param([System.Diagnostics.ProcessStartInfo]$Psi, [string[]]$Arguments)
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        foreach ($a in $Arguments) { $Psi.ArgumentList.Add([string]$a) }
    } else {
        $Psi.Arguments = (($Arguments | ForEach-Object {
            if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { [string]$_ }
        }) -join ' ')
    }
}

function Get-ProcessCommandLine {
    # Best-effort process command line by pid, cross-platform. Returns '' when
    # unavailable. Used only to VERIFY a recorded pid is ours before any kill.
    param([int]$ProcessIdValue)
    try {
        if (Test-OnWindows) {
            $cim = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $ProcessIdValue) -ErrorAction SilentlyContinue
            if ($null -ne $cim) { return [string]$cim.CommandLine }
            return ''
        }
        $procFs = "/proc/$ProcessIdValue/cmdline"   # Linux
        if (Test-Path -LiteralPath $procFs) {
            return ((Get-Content -LiteralPath $procFs -Raw -ErrorAction SilentlyContinue) -replace "`0", ' ').Trim()
        }
        # macOS / other: invoke the native ps binary (not the Get-Process alias).
        $psBin = Get-Command 'ps' -CommandType Application -ErrorAction SilentlyContinue
        if ($null -ne $psBin) { return ((& $psBin.Source -o command= -p $ProcessIdValue 2>$null) -join ' ').Trim() }
        return ''
    } catch { return '' }
}

# --- file URIs (landmine 1: uppercase Windows drive letters) ---------------

function ConvertTo-FileUri {
    # Build a file:// URI from a filesystem path, cross-platform.
    # Windows: let .NET convert (handles drive + UNC), then force an UPPERCASE drive
    # letter ([System.Uri].AbsoluteUri lowercases it, a document-match hazard).
    # POSIX: the [System.Uri] STRING CAST yields a null/relative URI for an absolute
    # path like /home/x (no drive, no scheme); .AbsoluteUri on that is null, which
    # then breaks every downstream .ToLowerInvariant()/didOpen call. So build
    # file://<path> explicitly, percent-escaping each segment.
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [System.IO.Path]::GetFullPath($Path)
    if (Test-OnWindows) {
        $uri = ([System.Uri]$full).AbsoluteUri
        if ($uri -match '^file:///[a-z]:') {
            $uri = $uri.Substring(0, 8) + $uri.Substring(8, 1).ToUpperInvariant() + $uri.Substring(9)
        }
        return $uri
    }
    $sb = New-Object System.Text.StringBuilder
    foreach ($seg in ($full -split '/')) {
        if ($seg -eq '') { continue }
        [void]$sb.Append('/')
        [void]$sb.Append([System.Uri]::EscapeDataString($seg))
    }
    return ('file://' + $sb.ToString())
}

function ConvertFrom-FileUri {
    param([Parameter(Mandatory = $true)][string]$Uri)
    try { return [System.IO.Path]::GetFullPath(([System.Uri]$Uri).LocalPath) }
    catch { return $Uri }
}

function ConvertTo-UriKey {
    # Normalize a file URI to a case-insensitive lookup key (landmine 1, match side).
    # ConvertTo-FileUri emits the Windows drive letter UPPERCASED, but PSES echoes
    # it back LOWERCASED in publishDiagnostics. The daemon keys both the stored
    # publish and the request lookup through here so the two still correlate;
    # without the fold the drive-letter case mismatches and diagnostics are
    # silently dropped. Lower-casing the whole URI (not just the drive) preserves
    # the daemon's long-standing keying behavior verbatim.
    param([string]$Uri)
    return $Uri.ToLowerInvariant()
}

# --- stdin (BOM-tolerant) --------------------------------------------------

function Get-StdinText {
    # Read all of stdin and strip a leading UTF-8 BOM if present. Some parent
    # processes (e.g. a Windows PowerShell 5.1 StreamWriter) prepend one, which
    # would otherwise break ConvertFrom-Json on the hook payload.
    $raw = [Console]::In.ReadToEnd()
    if ($null -ne $raw) { $raw = $raw.TrimStart([char]0xFEFF) }
    return $raw
}

# --- JSON property helpers (StrictMode-safe) -------------------------------

function Test-Prop {
    param($Object, [string]$Name)
    return ($null -ne $Object) -and ($Object.PSObject.Properties.Name -contains $Name)
}

function Get-Prop {
    param($Object, [string]$Name)
    if (Test-Prop $Object $Name) { return $Object.$Name } else { return $null }
}

# --- initialize capabilities (landmine 2, INVERTED from the dispatch) ------

function New-InitializeCapabilities {
    # IMPORTANT: this DECLARES textDocument.rename. The dispatch frontmatter and
    # the overnight brief both say "do not advertise rename", but that is
    # empirically backwards for PSES v4.6.0: omitting rename makes its
    # PrepareRenameHandler dereference a null RenameCapability and the server
    # never answers initialize (verified by probe on 2026-06-05 -- rename omitted
    # => "NO INIT RESPONSE"; rename declared => clean handshake + diagnostics).
    # The shipped v1.0.0 README documents the same direction. Declaring a minimal
    # rename capability is what AVOIDS the NRE. See CHANGELOG 1.1.0 / outbox.
    return @{
        workspace = @{ configuration = $true; workspaceFolders = $true }
        window = @{ workDoneProgress = $true }
        textDocument = @{
            synchronization = @{ didOpen = $true; didChange = $true; didSave = $true }
            publishDiagnostics = @{ relatedInformation = $true }
            rename = @{ dynamicRegistration = $false; prepareSupport = $true }
            hover = @{ contentFormat = @('markdown', 'plaintext') }
            definition = @{ linkSupport = $true }
            completion = @{ completionItem = @{ snippetSupport = $false } }
        }
    }
}

function New-InitializeParams {
    # Build the LSP `initialize` params. CRITICAL (landmine 3): this OMITS the
    # top-level `workspaceFolders` member. PSES v4.6.0 throws a NullReferenceException
    # inside its own OnInitialize handler (PsesLanguageServer.cs:150, the
    # workspaceFolders add path) on Linux when initialize carries workspaceFolders
    # (upstream #2300) -- so the daemon relies on rootUri alone and opens each file
    # explicitly via didOpen/didChange (multi-root folders are not needed for
    # diagnostics). Re-adding a workspaceFolders member here reintroduces the Linux
    # hang. NOTE: the boolean capability workspace.workspaceFolders declared in
    # New-InitializeCapabilities is a DIFFERENT thing -- it only advertises support
    # and is safe; it is the params-level folder list that trips the NRE.
    param(
        [Parameter(Mandatory = $true)][string]$RootUri,
        [Parameter(Mandatory = $true)][int]$ProcessId
    )
    return @{
        processId = $ProcessId
        clientInfo = @{ name = 'cc-pses-daemon'; version = '1.1.0' }
        rootUri = $RootUri
        capabilities = (New-InitializeCapabilities)
    }
}

# --- LSP framing over a byte stream ----------------------------------------

function Write-LspFrame {
    # Content-Length framed JSON-RPC over the child's stdin stream.
    param([System.IO.Stream]$Stream, [string]$Json)
    $body = [System.Text.Encoding]::UTF8.GetBytes($Json)
    $header = [System.Text.Encoding]::ASCII.GetBytes("Content-Length: $($body.Length)`r`n`r`n")
    $Stream.Write($header, 0, $header.Length)
    $Stream.Write($body, 0, $body.Length)
    $Stream.Flush()
}

function Read-LspFrame {
    # Pull one complete frame body out of a byte List buffer, or $null if the
    # buffer does not yet hold a full frame. Mutates $Buffer in place.
    param([System.Collections.Generic.List[byte]]$Buffer)

    $n = $Buffer.Count
    if ($n -lt 4) { return $null }
    $sep = -1
    for ($i = 0; $i -le $n - 4; $i++) {
        if ($Buffer[$i] -eq 13 -and $Buffer[$i + 1] -eq 10 -and `
                $Buffer[$i + 2] -eq 13 -and $Buffer[$i + 3] -eq 10) { $sep = $i; break }
    }
    if ($sep -lt 0) { return $null }
    $headerBytes = $Buffer.GetRange(0, $sep).ToArray()
    $header = [System.Text.Encoding]::ASCII.GetString($headerBytes)
    $len = -1
    foreach ($line in ($header -split "`r`n")) {
        if ($line -match '(?i)^\s*Content-Length:\s*(\d+)\s*$') { $len = [int]$Matches[1] }
    }
    if ($len -lt 0) {
        $Buffer.RemoveRange(0, $sep + 4)
        return $null
    }
    $bodyStart = $sep + 4
    if ($Buffer.Count -lt $bodyStart + $len) { return $null }
    $bodyBytes = $Buffer.GetRange($bodyStart, $len).ToArray()
    $Buffer.RemoveRange(0, $bodyStart + $len)
    return [System.Text.Encoding]::UTF8.GetString($bodyBytes)
}

# --- diagnostics normalization + ordering ----------------------------------

function ConvertTo-DiagRecord {
    # Map an LSP diagnostic object to a flat ordered hashtable. Line/Col 1-based.
    #
    # Correction text is THREADED THROUGH here (it used to be dropped). LSP
    # publishDiagnostics does not carry PSScriptAnalyzer SuggestedCorrections, so
    # at publish time there is no fix yet: 'correction' defaults to '' and
    # 'correctionCount' to 0, and the daemon enriches the record afterward from a
    # textDocument/codeAction pass (see Add-CodeActionCorrections in the daemon).
    # A caller that already has the fix (e.g. a test) may pass it in directly.
    param(
        $Diagnostic,
        [string]$Correction = '',
        [int]$CorrectionCount = 0
    )
    $range = Get-Prop $Diagnostic 'range'
    $startPos = Get-Prop $range 'start'
    $line = 1; $col = 1
    $lv = Get-Prop $startPos 'line'; if ($null -ne $lv) { $line = [int]$lv + 1 }
    $cv = Get-Prop $startPos 'character'; if ($null -ne $cv) { $col = [int]$cv + 1 }
    $sevNum = Get-Prop $Diagnostic 'severity'
    $sev = switch ([int]$sevNum) { 1 { 'Error' } 2 { 'Warning' } 3 { 'Information' } 4 { 'Hint' } default { 'Warning' } }
    $src = [string](Get-Prop $Diagnostic 'source')
    $codeVal = Get-Prop $Diagnostic 'code'
    $code = if ($null -ne $codeVal) { [string]$codeVal } else { '' }
    $msg = [string](Get-Prop $Diagnostic 'message')
    $msg = ($msg -replace "[`r`n`t]", ' ').Trim()
    return [ordered]@{
        severity = $sev; severityNum = [int]$sevNum
        line = $line; col = $col; source = $src; code = $code; message = $msg
        correction = [string]$Correction; correctionCount = [int]$CorrectionCount
    }
}

function Get-SeverityRank {
    param([string]$Severity)
    switch ($Severity) { 'Error' { 1 } 'Warning' { 2 } 'Information' { 3 } 'Hint' { 4 } default { 5 } }
}

function Split-RuleList {
    # Parse a comma-separated rule-name list (from userConfig) into a trimmed,
    # non-empty array. Empty input -> empty array (no constraint).
    param([string]$Csv)
    if ([string]::IsNullOrWhiteSpace($Csv)) { return @() }
    return @($Csv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Select-FilteredDiagnostics {
    # Apply a severity threshold and rule include/exclude. $Threshold names the
    # LEAST severe level to report (Error > Warning > Information > Hint). Empty
    # include/exclude means no constraint; an explicit include keeps only listed
    # rule codes. Returns the surviving records (order preserved).
    param(
        [object[]]$Records,
        [string]$Threshold = 'Hint',
        [string[]]$Include = @(),
        [string[]]$Exclude = @()
    )
    if ($null -eq $Records) { return @() }
    $thRank = Get-SeverityRank $Threshold
    $inc = @($Include | Where-Object { $_ })
    $exc = @($Exclude | Where-Object { $_ })
    $out = @()
    foreach ($r in $Records) {
        if ((Get-SeverityRank $r.severity) -gt $thRank) { continue }
        if ($exc.Count -gt 0 -and ($exc -contains $r.code)) { continue }
        if ($inc.Count -gt 0 -and ($inc -notcontains $r.code)) { continue }
        $out += $r
    }
    return @($out)
}

function Select-OrderedDiagnostics {
    # Stable order (severity asc, then line, then col) + dedupe on the tuple that
    # identifies a finding. Returns an array of diag-record hashtables.
    param([object[]]$Records)
    if ($null -eq $Records) { return @() }
    $seen = New-Object System.Collections.Generic.HashSet[string]
    $unique = @()
    foreach ($r in $Records) {
        $key = ('{0}|{1}|{2}|{3}|{4}' -f $r.severity, $r.line, $r.col, $r.code, $r.message)
        if ($seen.Add($key)) { $unique += $r }
    }
    return @($unique | Sort-Object `
        @{ Expression = { Get-SeverityRank $_.severity } }, `
        @{ Expression = { [int]$_.line } }, `
        @{ Expression = { [int]$_.col } })
}
