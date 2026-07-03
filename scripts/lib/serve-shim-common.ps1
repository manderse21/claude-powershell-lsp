#Requires -Version 5.1

# serve-shim-common.ps1 -- pure, dot-sourceable helpers for the native-serve
# handshake shim (scripts/pses-serve-shim.ps1, dispatch 000103). Split out from the
# executable so the byte-exact framing, the initialize patch, the knob canonicalizer,
# and the server->client intercept answer table are UNIT-TESTABLE without spawning a
# process. No side effects on import: defines functions only (load-silent by contract,
# because the shim that dot-sources this writes the raw LSP byte stream to stdout and a
# single stray pre-handshake byte corrupts the protocol).
#
# ASCII-only (PS 5.1 reads a UTF-8-without-BOM file through the Windows-1252 codepage;
# keep to bytes 0x00-0x7F -- "--" not an em-dash, straight quotes only).
#
# Author: Mike Andersen / powershell-lsp plugin.

# --- the knob (dispatch 000103) --------------------------------------------

function ConvertTo-NativeServeMode {
    # Map the raw nativeServe knob string to a mode: 'off' | 'shim'. Default-safe: absent /
    # blank / an unexpanded '${user_config...}' token / any unrecognized value -> 'off' (the
    # feature is opt-in and sits on the critical LSP transport; an unparseable knob NEVER
    # silently turns it on -- the 000103 acceptance). Mirrors ConvertTo-ModuleAwarenessMode's
    # boolean-truthy aliases (true/on/1/yes -> the active mode) so a user who reaches for a
    # boolean gets the intended serving behavior; 'off' is the only value that means off.
    param([string]$Raw)
    $v = ([string]$Raw).Trim().ToLowerInvariant()
    switch ($v) {
        'shim' { return 'shim' }
        'true' { return 'shim' }
        'on'   { return 'shim' }
        '1'    { return 'shim' }
        'yes'  { return 'shim' }
        default { return 'off' }
    }
}

# --- the server->client intercept set (the whole answer table) -------------

function Get-ServeInterceptMethods {
    # The EXACT, frozen set of server->client REQUESTS the shim answers locally (dispatch
    # 000102 Track 2). Everything else -- responses, notifications, and any OTHER server->client
    # request -- is forwarded to the client byte-exact. Kept as one list so the shim and its
    # tests read the same source (no second copy to drift).
    #   workspace/configuration       -- PSES pulls scriptAnalysis settings (nav is settings-
    #                                    independent, so null per item costs nothing).
    #   window/workDoneProgress/create-- PSES creates a progress token; null accepts it.
    #   client/registerCapability     -- belt-and-suspenders; the initialize patch
    #                                    (dynamicRegistration=false) already prevents PSES
    #                                    from sending it at all.
    return @('workspace/configuration', 'window/workDoneProgress/create', 'client/registerCapability')
}

function Test-ServeInterceptMethod {
    # $true when $Method is one the shim answers locally (see Get-ServeInterceptMethods).
    param([string]$Method)
    return ((Get-ServeInterceptMethods) -contains $Method)
}

function ConvertTo-ServeIdJson {
    # Serialize a JSON-RPC id (a number or a string) back to its JSON token, so an
    # intercept response echoes the request id in the same shape PSES sent it.
    param($Id)
    if ($Id -is [string]) { return (ConvertTo-Json $Id -Compress) }
    return ([string]$Id)
}

function New-ServeInterceptResultJson {
    # The `result` payload for an intercepted server->client request. For
    # workspace/configuration answer one `null` PER requested item (or `[]` when none) --
    # PSES accepts a null config item and serves nav regardless (proven end-to-end, 000102
    # OQ3). Every other intercepted method answers a bare `null` (LSP "handled OK").
    param([string]$Method, $Params)
    if ($Method -eq 'workspace/configuration') {
        $n = 0
        if ($null -ne $Params -and ($Params.PSObject.Properties.Name -contains 'items')) {
            $items = $Params.items
            if ($null -ne $items) { $n = @($items).Count }
        }
        if ($n -le 0) { return '[]' }
        return ('[' + ((@('null') * $n) -join ',') + ']')
    }
    return 'null'
}

function New-ServeInterceptResponseJson {
    # The full JSON-RPC response frame body for an intercepted server->client request:
    # {"jsonrpc":"2.0","id":<id>,"result":<result>}. Built as a string (never a re-encoded
    # object) so the id token is echoed exactly.
    param($Id, [string]$Method, $Params)
    $result = New-ServeInterceptResultJson -Method $Method -Params $Params
    return ('{"jsonrpc":"2.0","id":' + (ConvertTo-ServeIdJson $Id) + ',"result":' + $result + '}')
}

# --- byte-exact LSP framing (raw splice) -----------------------------------
# The shim forwards non-intercepted frames as RAW BODY BYTES (decode only enough to
# classify) so a multibyte-UTF-8 payload is delivered byte-identical. These mirror
# lsp-common.ps1's Write-LspFrame/Read-LspFrame but carry BYTES, not a decoded string --
# that decode/re-encode is exactly what a byte-exact transport must avoid.

function Read-ServeFrame {
    # Pull one complete frame's raw BODY bytes out of a byte List buffer, or $null if the
    # buffer does not yet hold a full frame. Mutates $Buffer in place (removes the consumed
    # header+body). Returns a [byte[]] (leading-comma wrapped so PowerShell does not unroll
    # the array into the pipeline); a zero-length body returns an empty [byte[]], distinct
    # from the $null "not yet complete" signal.
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
    return , $bodyBytes
}

function Write-ServeFrame {
    # Content-Length framed raw-byte body over a stream. The header is reconstructed
    # canonically (ASCII "Content-Length: N\r\n\r\n") and the BODY bytes are written verbatim
    # -- so the JSON-RPC payload the peer receives is byte-identical to the payload sent.
    param([System.IO.Stream]$Stream, [byte[]]$BodyBytes)
    $len = 0
    if ($null -ne $BodyBytes) { $len = $BodyBytes.Length }
    $header = [System.Text.Encoding]::ASCII.GetBytes("Content-Length: $len`r`n`r`n")
    $Stream.Write($header, 0, $header.Length)
    if ($len -gt 0) { $Stream.Write($BodyBytes, 0, $len) }
    $Stream.Flush()
}

# --- the initialize patch (the whole client->server intervention) ----------
# Under a rich (CC-like) client PSES v4.6.0 sends client/registerCapability ONLY because
# the client declared dynamicRegistration=true; under dynamicRegistration=false it advertises
# every provider STATICALLY in the initialize result and sends none (probe-proven, 000102
# OQ1). So the shim patches the forwarded `initialize`:
#   (1) set every dynamicRegistration to false  -> PSES advertises nav statically, no
#       registerCapability, and the REAL client learns the providers from the static result;
#   (2) drop the params-level `workspaceFolders` -> the PSES v4.6.0 #2300 Linux OnInitialize
#       NRE dodge the daemon already relies on (New-InitializeParams in lsp-common.ps1);
#   (3) ensure a minimal textDocument.rename capability -> the rename PrepareRenameHandler
#       null-deref NRE dodge (New-InitializeCapabilities in lsp-common.ps1).

function ConvertTo-MutableTree {
    # Convert a ConvertFrom-Json result (PSCustomObject / Object[] / primitives) into a freely
    # mutable tree of ordered hashtables + arrays, so the initialize patch can add/remove/set
    # members and re-serialize -- without PS 5.1's ConvertFrom-Json -AsHashtable (pwsh-6+ only).
    param($Node)
    if ($null -eq $Node) { return $null }
    if ($Node -is [string] -or $Node -is [bool] -or $Node -is [System.ValueType]) { return $Node }
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        $ht = [ordered]@{}
        foreach ($p in $Node.PSObject.Properties) { $ht[[string]$p.Name] = (ConvertTo-MutableTree $p.Value) }
        return $ht
    }
    if ($Node -is [System.Collections.IEnumerable]) {
        $list = New-Object System.Collections.ArrayList
        foreach ($el in $Node) { [void]$list.Add((ConvertTo-MutableTree $el)) }
        return , ($list.ToArray())
    }
    return $Node
}

function Set-ServeDynamicRegistrationFalse {
    # Recursively set EVERY `dynamicRegistration` member to $false anywhere in the tree.
    # Dictionaries and arrays are reference types, so the mutation persists in the caller's tree.
    param($Tree)
    if ($Tree -is [System.Collections.IDictionary]) {
        foreach ($k in @($Tree.Keys)) {
            if ($k -eq 'dynamicRegistration') { $Tree[$k] = $false }
            else { Set-ServeDynamicRegistrationFalse $Tree[$k] }
        }
    } elseif ($Tree -is [System.Collections.IList]) {
        foreach ($el in $Tree) { Set-ServeDynamicRegistrationFalse $el }
    }
}

function Edit-InitializeMessageForServe {
    # Patch a forwarded `initialize` request (JSON string in -> patched JSON string out) per
    # the three dodges above. Fail-safe: an unparseable message, a message with no params, or
    # any error returns the ORIGINAL string unchanged -- the shim never corrupts a frame it
    # cannot confidently rewrite.
    param([string]$Json)
    $obj = $null
    try { $obj = $Json | ConvertFrom-Json } catch { return $Json }
    $tree = ConvertTo-MutableTree $obj
    if (-not ($tree -is [System.Collections.IDictionary])) { return $Json }
    if (-not ($tree.Contains('params'))) { return $Json }
    $params = $tree['params']
    if (-not ($params -is [System.Collections.IDictionary])) { return $Json }

    # (1) dynamicRegistration -> false across every capability section.
    $caps = $null
    if ($params.Contains('capabilities')) { $caps = $params['capabilities'] }
    if ($caps -is [System.Collections.IDictionary]) { Set-ServeDynamicRegistrationFalse $caps }

    # (2) drop the params-level workspaceFolders member (the #2300 Linux NRE dodge). The
    #     boolean capability workspace.workspaceFolders is a DIFFERENT, safe thing (advertises
    #     support only) and is intentionally left alone -- it is the params-level folder LIST
    #     that trips the NRE.
    if ($params.Contains('workspaceFolders')) { [void]$params.Remove('workspaceFolders') }

    # (3) ensure a minimal textDocument.rename capability (the rename NRE dodge), creating any
    #     missing container along the way.
    if (-not ($caps -is [System.Collections.IDictionary])) { $caps = [ordered]@{}; $params['capabilities'] = $caps }
    $td = $null
    if ($caps.Contains('textDocument')) { $td = $caps['textDocument'] }
    if (-not ($td -is [System.Collections.IDictionary])) { $td = [ordered]@{}; $caps['textDocument'] = $td }
    $rename = $null
    if ($td.Contains('rename')) { $rename = $td['rename'] }
    if (-not ($rename -is [System.Collections.IDictionary])) { $rename = [ordered]@{}; $td['rename'] = $rename }
    $rename['dynamicRegistration'] = $false
    if (-not $rename.Contains('prepareSupport')) { $rename['prepareSupport'] = $true }

    return ($tree | ConvertTo-Json -Depth 64 -Compress)
}
