#Requires -Version 5.1

# The daemon IPC protocol handshake (dispatch 000282 leg F; ruling R15 of 2026-09-06 =
# ENTERPRISE-PROGRAM-DOCKET P1-4).
#
# WHAT IS UNDER TEST. The IPC between lsp-client.ps1 / doctor.ps1 and pses-daemon.ps1 has never
# carried a version, so two peers from different installs could only discover a mismatch by
# misbehaving. The handshake adds protocolVersion and a capabilities object to every request and
# every response, with two rules that are what make it additive rather than breaking:
#
#   ABSENT MEANS 1. A request with no protocolVersion is version 1 -- the protocol as it stood
#   before anyone announced one -- so every pre-000282 client keeps working and the response it
#   gets is its old response plus a suffix.
#
#   UNKNOWN IS ANSWERED, NOT REFUSED. A request claiming a version the daemon does not know is
#   processed as version 1 and answered with the DAEMON's own version. Refusing would make the
#   first version bump a flag day, which is the failure a version announcement exists to prevent.
#
# The daemon's functions are loaded by extracting their definitions from pses-daemon.ps1's AST and
# defining them here, so what runs is the SHIPPED text verbatim -- dot-sourcing the script itself
# would start a daemon. A test asserts the extraction found real functions rather than silently
# nothing.
#
# RED CONTROL: a mutant Write-DaemonResponse that echoes the CLIENT's version instead of its own.
# That is the single most plausible wrong implementation -- it looks like agreement and it is the
# opposite of one, because a client learns nothing about the daemon from being told what it
# already said. It must fail the assertion the shipped one passes.
#
# Run via tests/run-tests.ps1 (auto-discovered).

BeforeAll {
    $script:PluginRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsDir = Join-Path $script:PluginRoot 'scripts'
    $script:DaemonPath = Join-Path $script:ScriptsDir 'pses-daemon.ps1'
    $script:ClientPath = Join-Path $script:ScriptsDir 'lsp-client.ps1'
    $script:DoctorPath = Join-Path $script:ScriptsDir 'doctor.ps1'
    . (Join-Path $script:ScriptsDir 'lib/lsp-common.ps1')

    $script:DaemonAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:DaemonPath, [ref]$null, [ref]$null)

    function Get-DaemonFunctionText {
        param([string] $Name)
        $fn = $script:DaemonAst.Find({
                param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq $Name }, $true)
        if ($null -eq $fn) { return '' }
        return [string]$fn.Extent.Text
    }

    # Define the SHIPPED functions verbatim in this session. Get-QueryOps FIRST: Get-DaemonCapabilities
    # calls it (000287 -- one source for the op vocabulary, Hub Rule 18), so defining the capabilities
    # function without it would leave every caller below throwing on an unresolved command.
    $script:WriteRespText = Get-DaemonFunctionText -Name 'Write-DaemonResponse'
    $script:CapsText = Get-DaemonFunctionText -Name 'Get-DaemonCapabilities'
    $script:QueryOpsText = Get-DaemonFunctionText -Name 'Get-QueryOps'
    . ([scriptblock]::Create($script:QueryOpsText))
    . ([scriptblock]::Create($script:CapsText))
    . ([scriptblock]::Create($script:WriteRespText))

    function New-CapturingWriter {
        # A StreamWriter over a MemoryStream: Write-DaemonResponse takes whatever exposes
        # WriteLine, and this captures the exact line it emits without a pipe or a process.
        $ms = New-Object System.IO.MemoryStream
        $sw = New-Object System.IO.StreamWriter($ms, (New-Object System.Text.UTF8Encoding($false)))
        $sw.NewLine = "`n"
        $sw.AutoFlush = $true
        return [pscustomobject]@{ Stream = $ms; Writer = $sw }
    }

    function Get-WrittenLine {
        param($Capture)
        $Capture.Writer.Flush()
        return [System.Text.Encoding]::UTF8.GetString($Capture.Stream.ToArray()).TrimEnd("`n")
    }

    # The RED CONTROL: identical to the shipped function except that it reports the version the
    # REQUEST claimed instead of the daemon's own.
    function Write-DaemonResponseEchoMutant {
        param($Writer, $Payload, [int]$Depth = 6, $Request)
        try {
            $Payload['protocolVersion'] = Resolve-RequestProtocolVersion $Request
            $Payload['capabilities'] = Get-DaemonCapabilities
        } catch { }
        $Writer.WriteLine(($Payload | ConvertTo-Json -Depth $Depth -Compress))
    }
}

Describe 'the extraction found real shipped functions (this file cannot pass vacuously)' {
    It 'pulled a non-empty body for both daemon functions' {
        $script:WriteRespText | Should -Not -BeNullOrEmpty
        $script:CapsText | Should -Not -BeNullOrEmpty
        $script:WriteRespText | Should -Match 'Write-DaemonResponse'
    }
    It 'the extracted text is present verbatim in the shipped daemon' {
        $src = [System.IO.File]::ReadAllText($script:DaemonPath)
        $src.Contains($script:WriteRespText) | Should -BeTrue
        $src.Contains($script:CapsText) | Should -BeTrue
    }
}

Describe 'Resolve-RequestProtocolVersion -- absent means 1, and nothing is refused' {
    It 'reads <Label> as <Expected>' -TestCases @(
        @{ Label = 'an absent key'; Request = ([pscustomobject]@{ action = 'diagnostics' }); Expected = 1 }
        @{ Label = 'a null request'; Request = $null; Expected = 1 }
        @{ Label = 'version 1'; Request = ([pscustomobject]@{ protocolVersion = 1 }); Expected = 1 }
        @{ Label = 'version 7 (unknown, still read)'; Request = ([pscustomobject]@{ protocolVersion = 7 }); Expected = 7 }
        @{ Label = 'a numeric string'; Request = ([pscustomobject]@{ protocolVersion = '3' }); Expected = 3 }
        @{ Label = 'nonsense'; Request = ([pscustomobject]@{ protocolVersion = 'banana' }); Expected = 1 }
        @{ Label = 'zero'; Request = ([pscustomobject]@{ protocolVersion = 0 }); Expected = 1 }
        @{ Label = 'a negative'; Request = ([pscustomobject]@{ protocolVersion = -4 }); Expected = 1 }
    ) {
        param($Label, $Request, $Expected)
        (Resolve-RequestProtocolVersion $Request) | Should -Be $Expected
    }

    It 'never throws, whatever it is handed' {
        { Resolve-RequestProtocolVersion ([pscustomobject]@{ protocolVersion = @(1, 2) }) } | Should -Not -Throw
        { Resolve-RequestProtocolVersion 'not an object' } | Should -Not -Throw
    }
}

Describe 'Get-DaemonCapabilities advertises what the daemon actually serves' {
    It 'advertises exactly the actions the request loop handles, read from the AST' {
        # GROUND TRUTH is the switch's own clause labels, not a list copied into this test: add an
        # action to the loop without advertising it and this goes red, which is the whole point of
        # advertising a capability set at all. Same shape as the CONTRACT.md status-token guard.
        $switchAst = $script:DaemonAst.FindAll({
                param($n) $n -is [System.Management.Automation.Language.SwitchStatementAst] }, $true) |
            Where-Object { @($_.Clauses | ForEach-Object { [string]$_.Item1.Value }) -contains 'diagnostics' }
        $labels = @($switchAst.Clauses | ForEach-Object { [string]$_.Item1.Value }) | Sort-Object
        $labels.Count | Should -BeGreaterThan 0 -Because 'the AST walk must find the request loop'

        $advertised = @((Get-DaemonCapabilities).actions) | Sort-Object
        ($advertised -join ',') | Should -BeExactly ($labels -join ',')
    }

    It 'names only flags backed by a field the loop really reads' {
        $caps = Get-DaemonCapabilities
        $src = [System.IO.File]::ReadAllText($script:DaemonPath)
        $caps.diagnosticsTouchedRanges | Should -Be $true
        $src | Should -Match "Get-Prop \`$req 'touchedRanges'"
        $caps.formatApply | Should -Be $true
        $src | Should -Match "Get-Prop \`$req 'apply'"
        # queryOps (000287): the advertised op set must BE the vocabulary the planner validates
        # against, not a copy of it. Both read Get-QueryOps, and this asserts they agree by
        # calling the shipped function rather than by comparing two literals.
        $script:QueryOpsText | Should -Not -BeNullOrEmpty
        @($caps.queryOps) -join ',' | Should -BeExactly (@(Get-QueryOps) -join ',')
        @($caps.queryOps).Count | Should -BeGreaterThan 0
        $src | Should -Match "Get-Prop \`$req 'op'"
    }
}

Describe 'every response carries the DAEMON version, and the payload is otherwise untouched' {
    It 'appends protocolVersion and capabilities to a ping payload' {
        $cap = New-CapturingWriter
        Write-DaemonResponse -Writer $cap.Writer -Payload ([ordered]@{ ok = $true; action = 'ping' })
        $o = (Get-WrittenLine -Capture $cap) | ConvertFrom-Json
        $o.protocolVersion | Should -Be (Get-LspProtocolVersion)
        $o.capabilities | Should -Not -BeNullOrEmpty
        @($o.capabilities.actions).Count | Should -BeGreaterThan 0
    }

    It 'ABSENT VERSION IS BYTE-IDENTICAL TO THE MERGE BASE, minus the two new fields' {
        # The additivity claim, measured. The merge-base daemon wrote the payload with
        # ConvertTo-Json -Compress and nothing else, so reproducing that here and comparing against
        # the shipped response with the two new keys removed is exactly the old bytes.
        $payload = [ordered]@{ ok = $true; action = 'ping'; pid = 4242; psesPid = 99 }
        $mergeBaseLine = ([ordered]@{ ok = $true; action = 'ping'; pid = 4242; psesPid = 99 } |
                ConvertTo-Json -Compress)

        $cap = New-CapturingWriter
        Write-DaemonResponse -Writer $cap.Writer -Payload $payload
        $shipped = (Get-WrittenLine -Capture $cap) | ConvertFrom-Json

        $trimmed = [ordered]@{}
        foreach ($prop in $shipped.PSObject.Properties) {
            if ($prop.Name -in @('protocolVersion', 'capabilities')) { continue }
            $trimmed[$prop.Name] = $prop.Value
        }
        ($trimmed | ConvertTo-Json -Compress) | Should -BeExactly $mergeBaseLine
    }

    It 'keeps every original key, in its original order, ahead of the two new ones' {
        $cap = New-CapturingWriter
        Write-DaemonResponse -Writer $cap.Writer -Payload ([ordered]@{ ok = $true; action = 'diagnostics'; file = 'a.ps1' }) -Depth 8
        $names = @(((Get-WrittenLine -Capture $cap) | ConvertFrom-Json).PSObject.Properties.Name)
        ($names -join ',') | Should -BeExactly 'ok,action,file,protocolVersion,capabilities'
    }

    It 'survives the shallowest Depth any call site uses -- capabilities is not truncated' {
        # ping and shutdown wrote with ConvertTo-Json's default depth before this change. A nested
        # capabilities object that silently truncated there would advertise nothing on two paths.
        $cap = New-CapturingWriter
        Write-DaemonResponse -Writer $cap.Writer -Payload ([ordered]@{ ok = $true; action = 'shutdown' }) -Depth 2
        $o = (Get-WrittenLine -Capture $cap) | ConvertFrom-Json
        @($o.capabilities.actions) | Should -Contain 'diagnostics'
    }

    It 'an UNKNOWN client version is ANSWERED with the daemon own version, not refused' {
        # The forward-compatibility rule. A client claiming version 7 gets a real answer carrying
        # the daemon's 1 -- it is not rejected, and it is not told 7 back.
        $req = [pscustomobject]@{ action = 'ping'; protocolVersion = 7 }
        (Resolve-RequestProtocolVersion $req) | Should -Be 7 -Because 'the claim is read, not discarded'

        $cap = New-CapturingWriter
        Write-DaemonResponse -Writer $cap.Writer -Payload ([ordered]@{ ok = $true; action = 'ping' })
        $o = (Get-WrittenLine -Capture $cap) | ConvertFrom-Json
        $o.ok | Should -Be $true -Because 'an unknown version must not be refused'
        $o.protocolVersion | Should -Be (Get-LspProtocolVersion)
        $o.protocolVersion | Should -Not -Be 7
    }
}

Describe 'RED CONTROL -- a daemon that echoes the client version fails' {
    It 'the mutant returns the CLIENT version where the shipped one returns its own' {
        $req = [pscustomobject]@{ action = 'ping'; protocolVersion = 7 }

        $mut = New-CapturingWriter
        Write-DaemonResponseEchoMutant -Writer $mut.Writer -Payload ([ordered]@{ ok = $true }) -Request $req
        $mutantOut = (Get-WrittenLine -Capture $mut) | ConvertFrom-Json

        # The mutant fails the shipped assertion...
        $mutantOut.protocolVersion | Should -Be 7
        $mutantOut.protocolVersion | Should -Not -Be (Get-LspProtocolVersion)

        # ...and the shipped implementation passes it on the identical input.
        $ok = New-CapturingWriter
        Write-DaemonResponse -Writer $ok.Writer -Payload ([ordered]@{ ok = $true })
        ((Get-WrittenLine -Capture $ok) | ConvertFrom-Json).protocolVersion |
            Should -Be (Get-LspProtocolVersion)
    }
}

Describe 'every request-building site announces the handshake (census, not a sample)' {
    # WHAT CHANGED HERE, AND WHY (dispatch 000287, while building P1-2).
    #
    # This block used to carry a HARD-CODED list of three sites and call itself a census. It was a
    # sample: a fourth site added tomorrow would not be in the list, so the list would keep passing
    # while the claim in its own title went false. That is the guard shape this program has now
    # found four times -- the guard measures a list the guarded party writes (Hub Rule 35).
    #
    # Re-deriving at the tip found SIX request-writing sites, not three, and the two extra ones had
    # never been named anywhere: doctor.ps1's ping probe and session-end.ps1's shutdown both write a
    # BARE JSON literal. Neither is broken -- ABSENT MEANS 1 is the handshake's own rule, so they are
    # legal version-1 clients -- but the old test did not know they existed, which means it could not
    # have noticed if one had started carrying a field that needed a version to interpret.
    #
    # So the ground truth below is derived from source, and the assertion is a PARTITION: every
    # request-writing site is either an ANNOUNCING site (builds a request hashtable, and must carry
    # both keys) or a BARE VERSION-1 site (writes one of exactly two literals that carry nothing but
    # an action). The exemption is keyed on the LITERAL TEXT, never on a file name, so a site cannot
    # buy its way out by being on a list -- it can only be exempt by sending a request with no field
    # a version could change the meaning of.

    BeforeAll {
        $script:ScriptFiles = @(Get-ChildItem -LiteralPath $script:ScriptsDir -Filter '*.ps1' -File |
                Where-Object { $_.Name -ne 'pses-daemon.ps1' })   # the daemon builds RESPONSES, not requests

        # ANNOUNCING sites: a hashtable literal whose 'action' key is a string, in a non-daemon
        # script. Found through the AST, so a site added in any file is found without being listed.
        $script:AnnouncingSites = @()
        $script:BareSites = @()
        foreach ($f in $script:ScriptFiles) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            $tables = @($ast.FindAll({
                        param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true))
            foreach ($t in $tables) {
                foreach ($pair in $t.KeyValuePairs) {
                    if ([string]$pair.Item1.Extent.Text -ne 'action') { continue }
                    $val = [string]$pair.Item2.Extent.Text
                    if ($val -notmatch "^'[a-z]+'$") { continue }   # a variable action is not a build site
                    $script:AnnouncingSites += [pscustomobject]@{
                        File = $f.Name; Action = $val.Trim("'"); Text = [string]$t.Extent.Text
                        Start = [int]$t.Extent.StartOffset; Source = [string]$ast.Extent.Text }
                }
            }
            # BARE version-1 sites: a single-quoted string literal that IS a whole daemon request.
            $strings = @($ast.FindAll({
                        param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true))
            foreach ($s in $strings) {
                if ([string]$s.Value -notmatch '^\{"action":"[a-z]+"\}$') { continue }
                $script:BareSites += [pscustomobject]@{ File = $f.Name; Literal = [string]$s.Value }
            }
        }
    }

    It 'the derivation found real sites (this block cannot pass vacuously)' {
        # Without this, an AST walk that silently matched nothing would report a clean partition
        # over the empty set -- the exact vacuity this program has banked five times.
        @($script:ScriptFiles).Count | Should -BeGreaterThan 3
        @($script:AnnouncingSites).Count | Should -BeGreaterThan 0
        @($script:BareSites).Count | Should -BeGreaterThan 0
    }

    It 'every announcing site carries both handshake keys, whatever the file' {
        foreach ($s in $script:AnnouncingSites) {
            # Anchor on the VARIABLE this very site assigned to, so the keys must belong to THIS
            # request rather than to some other request in the same file.
            $var = ''
            $before = $s.Source.Substring(0, $s.Start)
            if ($before -match '(?s).*\$([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(\[ordered\])?\s*$') { $var = $Matches[1] }
            $var | Should -Not -BeNullOrEmpty -Because ($s.File + ' site ' + $s.Action + ' must assign its request to a variable')
            $after = $s.Source.Substring($s.Start)
            $after.Contains('$' + $var + "['protocolVersion'] = Get-LspProtocolVersion") |
                Should -BeTrue -Because ($s.File + ':' + $s.Action + ' must announce protocolVersion')
            $after.Contains('$' + $var + "['capabilities'] = Get-LspClientCapabilities") |
                Should -BeTrue -Because ($s.File + ':' + $s.Action + ' must announce capabilities')
        }
    }

    It 'the only sites that do NOT announce are bare action-only version-1 literals' {
        # The exemption is the literal's own CONTENT: an object with exactly one key, 'action'. A
        # request that carries anything else cannot match this pattern and therefore cannot be
        # exempt, which is what keeps this from becoming a list of forgiven file names.
        foreach ($b in $script:BareSites) {
            $b.Literal | Should -Match '^\{"action":"[a-z]+"\}$'
            ($b.Literal -split ':').Count | Should -Be 2 -Because ($b.File + ' may carry no field but action')
        }
        @($script:BareSites | ForEach-Object { $_.File + ' ' + $_.Literal }) | Sort-Object |
            Should -Be @('doctor.ps1 {"action":"ping"}', 'session-end.ps1 {"action":"shutdown"}')
    }

    It 'every action the daemon serves is reachable from some request-writing site' {
        # Closes the partition in the other direction: an advertised action nothing can ask for is
        # as much a lie as an unadvertised one.
        $asked = @(@($script:AnnouncingSites | ForEach-Object { $_.Action }) +
            @($script:BareSites | ForEach-Object { ($_.Literal -replace '^\{"action":"', '') -replace '"\}$', '' })) |
            Sort-Object -Unique
        $served = @((Get-DaemonCapabilities).actions) | Sort-Object -Unique
        ($asked -join ',') | Should -BeExactly ($served -join ',')
    }

    It 'the daemon has no response path that bypasses the one write seam' {
        # Anchor on the CALL form, never a bare name: the file's own comments mention the writer
        # too, and an index over prose would compare comments to code (dispatch 000279's banked
        # rule, corrected at AirgapBootstrap.Tests.ps1:165).
        $src = [System.IO.File]::ReadAllText($script:DaemonPath)
        $loopStart = $src.IndexOf("Write-DLog ('request action=")
        $loopStart | Should -BeGreaterThan 0
        $loopEnd = $src.IndexOf('request handling error:', $loopStart)
        $loopEnd | Should -BeGreaterThan $loopStart
        $loop = $src.Substring($loopStart, $loopEnd - $loopStart)

        ([regex]::Matches($loop, '\$writer\.WriteLine\(')).Count |
            Should -Be 0 -Because 'every response must leave through Write-DaemonResponse'
        ([regex]::Matches($loop, 'Write-DaemonResponse -Writer ')).Count |
            Should -Be 6 -Because 'the request loop has six response paths (query added by 000287)'
    }

    It 'CONTRACT.md is not touched by any of this -- the IPC is not a Tier 1 surface' {
        # CONTRACT.md freezes exactly two enumerable surfaces: the twenty userConfig knob names and
        # the diagnostics status token set. Confirmed here rather than assumed.
        $contract = [System.IO.File]::ReadAllText((Join-Path $script:PluginRoot 'CONTRACT.md'))
        $contract | Should -Not -Match 'protocolVersion'
        $contract | Should -Not -Match 'FROZEN-IPC'
        $manifest = (Get-Content -LiteralPath (Join-Path $script:PluginRoot '.claude-plugin/plugin.json') -Raw) | ConvertFrom-Json
        @($manifest.userConfig.PSObject.Properties.Name) | Should -Not -Contain 'protocolVersion'
    }
}
