#Requires -Version 5.1

# POWERSHELL_LSP_OTEL_ENDPOINT and the OTLP rendering of the Track A telemetry log
# (dispatch 000290; P2-1, docs/roadmap-ii/ENTERPRISE-PROGRAM-DOCKET.md item 7).
#
# WHAT IS UNDER TEST. scripts/lib/otel-common.ps1 renders logs/stats.jsonl as OTLP metrics and
# scripts/export-otel.ps1 optionally POSTs them. A stats row carries the ABSOLUTE path of the
# edited file -- docs/configuration.md says so under `enableStats`, and it is why that knob is
# `false` in every profile. This exporter is the first thing in the plugin that would send any
# of it off the host, so the assertion that matters most is that the path does not go.
#
# THE BOUNDARY IS AN ALLOWLIST, AND THE TESTS ASSERT IT AS ONE. It is not enough to show that
# `path` is absent from a payload: a denylist over `path` would pass that test and still leak
# the next path-bearing field somebody adds to the row. So there is a test that puts an
# UNKNOWN field on the row and requires it to be absent too. That is the difference between
# testing the fix and testing the class, and it is the whole reason the allowlist was chosen.
#
# RED CONTROL: tests/fixtures/red-controls/otel-common-render.naive-p21.ps1. Recorded honestly
# as what it is -- the NAIVE FIRST-CUT renderer, not a prior implementation, because P2-1 is a
# new file and no prior implementation exists. It overrides exactly ONE function, which gives
# the control a SURVIVING ARM: the duration gauges and volume counters are shipped code in both
# runs and must come out identical, so a fixture that broke the renderer instead of defeating
# the boundary would be caught rather than credited.
#
# EVERY fixture lives under $TestDrive. The real stats log is never read and never written, and
# no test here opens a socket.
#
# ASCII-only (PS 5.1 Windows-1252 trap). Run via tests/run-tests.ps1 (auto-discovered).

BeforeAll {
    $script:PluginRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsDir = Join-Path $script:PluginRoot 'scripts'
    $script:LibPath = Join-Path $script:ScriptsDir 'lib/lsp-common.ps1'
    $script:OtelLib = Join-Path $script:ScriptsDir 'lib/otel-common.ps1'
    $script:Exporter = Join-Path $script:ScriptsDir 'export-otel.ps1'
    $script:NaiveRenderer = Join-Path $PSScriptRoot 'fixtures/red-controls/otel-common-render.naive-p21.ps1'
    . $script:LibPath
    . $script:OtelLib

    # The SAME host the suite runs under, so the Windows PowerShell 5.1 leg genuinely exercises
    # 5.1 rather than shelling out to pwsh 7 and testing the wrong host.
    $script:HostExe = (Get-Process -Id $PID).Path

    # SHA-256 of the RED-control fixture over its CONTENT with line endings normalized to LF --
    # never over the bytes git checked out. A .ps1 lands CRLF on a Windows checkout and LF on a
    # POSIX one, so a hash over the working tree measures the CHECKOUT and disagrees across the
    # matrix for a reason that says nothing about whether the fixture drifted (dispatch 000279).
    $script:NaiveRendererSha = '58d323f79e9abe728c5db7b7720caab1a42694fa4dd212905118a9ff2c0ada26'

    # Timestamps are pinned so two renderings can be compared field for field. The renderer
    # takes them as parameters for exactly this reason.
    $script:PinNow = [datetime]::SpecifyKind([datetime]'2026-09-09T12:00:00', [System.DateTimeKind]::Utc)
    $script:PinStart = [datetime]::SpecifyKind([datetime]'2026-09-09T00:00:00', [System.DateTimeKind]::Utc)

    function Get-LfSha256 {
        param([string] $FilePath)
        $txt = [System.IO.File]::ReadAllText($FilePath)
        $lf = ($txt -replace "`r`n", "`n")
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($lf)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $h = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
        return (([System.BitConverter]::ToString($h)) -replace '-', '').ToLowerInvariant()
    }

    function New-StatsRow {
        # One stats row shaped exactly as scripts/lsp-client.ps1 writes one. $Extra adds fields
        # the shipped writer does NOT write today, which is how the allowlist is tested as a
        # class rather than as a fix for one field name.
        param(
            [string] $Path, [string] $Ext = '.ps1', [string] $Taken = 'daemon-analyze',
            [object] $ConnectMs = 10, [object] $AnalysisMs = 100, [object] $CodeActionMs = 5,
            [int] $TotalMs = 200, [int] $Records = 1, [int] $Corrections = 0, [bool] $Cached = $false,
            [bool] $ScopeApplied = $false, [int] $ScopeTotal = 1, [int] $ScopeSurfaced = 1,
            [hashtable] $Extra = $null
        )
        $row = [ordered]@{
            ts = '2026-09-09T10:00:00.0000000-04:00'; path = $Path; ext = $Ext; taken = $Taken
            connectMs = $ConnectMs; analysisMs = $AnalysisMs; codeActionMs = $CodeActionMs
            totalMs = $TotalMs; records = $Records; corrections = $Corrections; cached = $Cached
            scopeApplied = $ScopeApplied; scopeTotal = $ScopeTotal; scopeSurfaced = $ScopeSurfaced
        }
        if ($null -ne $Extra) { foreach ($k in $Extra.Keys) { $row[$k] = $Extra[$k] } }
        # Round-trip through JSON so the object under test is a PSCustomObject parsed off a
        # JSONL line -- what the exporter actually gets -- and not a hashtable the test built.
        return (($row | ConvertTo-Json -Depth 8 -Compress) | ConvertFrom-Json)
    }

    function New-SecretPath {
        # A path whose DIRECTORY component is unique per call. The no-leak assertions look for
        # that leaf, so they cannot pass vacuously against a payload that merely omits some
        # other string: a leaked path MUST contain it.
        param([string] $Tag = 'x')
        $leaf = 'ZZSECRET-' + $Tag + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        return [pscustomobject]@{
            Leaf = $leaf
            Path = ('C:' + [char]92 + 'Users' + [char]92 + 'mande' + [char]92 + $leaf + [char]92 + 'billing.ps1')
        }
    }

    function Get-MetricByName {
        param([object] $Payload, [string] $Name)
        foreach ($m in $Payload.resourceMetrics[0].scopeMetrics[0].metrics) {
            if ($m.name -eq $Name) { return $m }
        }
        return $null
    }

    function Get-SumValue {
        param([object] $Payload, [string] $Name)
        $m = Get-MetricByName -Payload $Payload -Name $Name
        if ($null -eq $m) { return $null }
        return [int]$m.sum.dataPoints[0].asInt
    }

    function Get-GaugePoint {
        param([object] $Payload, [string] $Name, [string] $Stage, [string] $Quantile)
        $m = Get-MetricByName -Payload $Payload -Name $Name
        if ($null -eq $m) { return $null }
        foreach ($p in $m.gauge.dataPoints) {
            $at = @{}
            foreach ($a in $p.attributes) { $at[$a.key] = $a.value.stringValue }
            if ($at['stage'] -eq $Stage -and $at['quantile'] -eq $Quantile) { return [double]$p.asDouble }
        }
        return $null
    }

    function ConvertTo-PsLiteral {
        param([string] $Value)
        return ("'" + (([string]$Value) -replace "'", "''") + "'")
    }

    function Invoke-RenderInChild {
        # Render one JSONL file in a FRESH child process and return the payload JSON it printed.
        # A child process is the only way to load the naive renderer without its function
        # definition colliding with the shipped one in this session, and it keeps the ambient
        # session's POWERSHELL_LSP_* values out of the measurement.
        #
        # -Naive is the ONLY difference between the shipped run and the mutant run, which is
        # what makes the surviving-arm comparison mean what it claims.
        #
        # Start-Process with SEPARATELY redirected stdout and stderr, never `2>&1`: a native
        # child's merged stderr becomes ErrorRecords, and under Windows PowerShell 5.1 with
        # $ErrorActionPreference = 'Stop' in scope (Pester's default) that is a TERMINATING
        # error, so the harness would throw on the output it exists to read.
        param([string] $JsonlPath, [switch] $Naive)
        $driver = Join-Path $TestDrive ('drv-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
        $naiveLine = if ($Naive) { '. ' + (ConvertTo-PsLiteral -Value $script:NaiveRenderer) } else { '# shipped renderer only' }
        $text = @(
            '$ErrorActionPreference = ''Stop'''
            '. ' + (ConvertTo-PsLiteral -Value $script:OtelLib)
            $naiveLine
            '$rows = @()'
            'foreach ($l in [System.IO.File]::ReadAllLines(' + (ConvertTo-PsLiteral -Value $JsonlPath) + ')) {'
            '    if ([string]::IsNullOrWhiteSpace($l)) { continue }'
            '    $rows += ($l | ConvertFrom-Json)'
            '}'
            '$now = [datetime]::SpecifyKind([datetime]''2026-09-09T12:00:00'', [System.DateTimeKind]::Utc)'
            '$start = [datetime]::SpecifyKind([datetime]''2026-09-09T00:00:00'', [System.DateTimeKind]::Utc)'
            '$p = ConvertTo-OtelResourceMetrics -Records $rows -ServiceVersion ''9.9.9-test'' -Now $now -Start $start'
            '[Console]::Out.Write(($p | ConvertTo-Json -Depth 12 -Compress))'
        ) -join "`n"
        [System.IO.File]::WriteAllText($driver, $text + "`n", (New-Object System.Text.UTF8Encoding($false)))
        $stem = Join-Path $TestDrive ('io-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $outFile = $stem + '.out'
        $errFile = $stem + '.err'
        $proc = Start-Process -FilePath $script:HostExe `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $driver) `
            -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        # ReadAllText, not Get-Content -Raw: -Raw over an EMPTY file emits AutomationNull, and
        # [string] of that is $null rather than '', so .Trim() would throw exactly when the
        # child was quiet -- the case these assertions exist to confirm.
        $stdout = ''
        if (Test-Path -LiteralPath $outFile -PathType Leaf) { $stdout = [System.IO.File]::ReadAllText($outFile) }
        $stderr = ''
        if (Test-Path -LiteralPath $errFile -PathType Leaf) { $stderr = [System.IO.File]::ReadAllText($errFile) }
        return [pscustomobject]@{ ExitCode = $proc.ExitCode; Stdout = $stdout; Stderr = $stderr }
    }

    function Write-Jsonl {
        param([object[]] $Rows, [string] $Tag = 'log')
        $file = Join-Path $TestDrive ('stats-' + $Tag + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.jsonl')
        $lines = @()
        foreach ($r in @($Rows)) { $lines += ($r | ConvertTo-Json -Depth 8 -Compress) }
        [System.IO.File]::WriteAllText($file, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
        return $file
    }

    function Invoke-Exporter {
        # Run scripts/export-otel.ps1 in a child process with POWERSHELL_LSP_OTEL_ENDPOINT set
        # to an exact value (or removed). Returns exit code and both streams.
        #
        # $ArgLine IS EMITTED VERBATIM INTO THE DRIVER, and parameter NAMES must be bare there.
        # A quoted '-Path' is a positional VALUE, not a parameter name: the first version of
        # this helper quoted every token, so `-Path <log>` bound $Path='-Path' and $OutFile=<log>
        # -- which silently overwrote the fixture with the payload and reported "0 samples".
        # Only VALUES go through ConvertTo-PsLiteral; the switch names stay bare.
        param([string] $JsonlPath, [string] $Endpoint = 'UNSET', [string] $ArgLine = '')
        $driver = Join-Path $TestDrive ('exp-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
        $envLine = if ($Endpoint -eq 'UNSET') {
            'Remove-Item Env:\POWERSHELL_LSP_OTEL_ENDPOINT -ErrorAction SilentlyContinue'
        } else {
            '$env:POWERSHELL_LSP_OTEL_ENDPOINT = ' + (ConvertTo-PsLiteral -Value $Endpoint)
        }
        $invoke = '& ' + (ConvertTo-PsLiteral -Value $script:Exporter) +
            ' -Path ' + (ConvertTo-PsLiteral -Value $JsonlPath)
        if (-not [string]::IsNullOrWhiteSpace($ArgLine)) { $invoke += ' ' + $ArgLine }
        $text = @(
            $envLine
            $invoke
            'exit $LASTEXITCODE'
        ) -join "`n"
        [System.IO.File]::WriteAllText($driver, $text + "`n", (New-Object System.Text.UTF8Encoding($false)))
        $stem = Join-Path $TestDrive ('eio-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $outFile = $stem + '.out'
        $errFile = $stem + '.err'
        $proc = Start-Process -FilePath $script:HostExe `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $driver) `
            -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $stdout = ''
        if (Test-Path -LiteralPath $outFile -PathType Leaf) { $stdout = [System.IO.File]::ReadAllText($outFile) }
        $stderr = ''
        if (Test-Path -LiteralPath $errFile -PathType Leaf) { $stderr = [System.IO.File]::ReadAllText($errFile) }
        return [pscustomobject]@{ ExitCode = $proc.ExitCode; Stdout = $stdout; Stderr = $stderr }
    }
}

Describe 'Get-OtelEndpointInfo -- the vocabulary, and the INVERTED fallback direction' {
    BeforeAll {
        $script:PrevEndpoint = [Environment]::GetEnvironmentVariable('POWERSHELL_LSP_OTEL_ENDPOINT')
    }
    AfterAll {
        [Environment]::SetEnvironmentVariable('POWERSHELL_LSP_OTEL_ENDPOINT', $script:PrevEndpoint)
    }

    It 'resolves <Label> to configured=<Configured> recognized=<Recognized>' -TestCases @(
        @{ Label = 'unset'; Raw = $null; Configured = $false; Recognized = $false }
        @{ Label = 'empty'; Raw = ''; Configured = $false; Recognized = $false }
        @{ Label = 'whitespace'; Raw = '   '; Configured = $false; Recognized = $false }
        @{ Label = 'http'; Raw = 'http://localhost:4318/v1/metrics'; Configured = $true; Recognized = $true }
        @{ Label = 'https'; Raw = 'https://otel.example.com/v1/metrics'; Configured = $true; Recognized = $true }
        @{ Label = 'padded'; Raw = '  https://otel.example.com/v1/metrics  '; Configured = $true; Recognized = $true }
        @{ Label = 'file scheme'; Raw = 'file:///tmp/x'; Configured = $false; Recognized = $false }
        @{ Label = 'grpc scheme'; Raw = 'grpc://otel:4317'; Configured = $false; Recognized = $false }
        @{ Label = 'host:port only'; Raw = 'localhost:4318'; Configured = $false; Recognized = $false }
        @{ Label = 'junk'; Raw = 'not a url'; Configured = $false; Recognized = $false }
    ) {
        if ($null -eq $Raw) {
            Remove-Item Env:\POWERSHELL_LSP_OTEL_ENDPOINT -ErrorAction SilentlyContinue
        } else {
            $env:POWERSHELL_LSP_OTEL_ENDPOINT = $Raw
        }
        $info = Get-OtelEndpointInfo
        [bool]$info.configured | Should -Be $Configured
        [bool]$info.recognized | Should -Be $Recognized
    }

    It 'an UNRECOGNIZED value turns export OFF -- the opposite of the capture-mode fallback' {
        # This is the assertion that pins the deliberate divergence. Get-DiagnosticCaptureModeInfo
        # resolves a typo to `full` (permissive) because nothing may gate the capture channel.
        # Here the permissive direction would be a network egress to a destination nobody named,
        # so a typo must resolve to OFF. If someone later "harmonises" the two, this fails.
        $env:POWERSHELL_LSP_OTEL_ENDPOINT = 'htp://typo.example.com/v1/metrics'
        $info = Get-OtelEndpointInfo
        [bool]$info.configured | Should -BeFalse -Because 'a malformed endpoint must not be sent to'
        [bool]$info.recognized | Should -BeFalse
        $info.endpoint | Should -BeExactly '' -Because 'there is no URL to POST to'
        $info.raw | Should -BeExactly 'htp://typo.example.com/v1/metrics' -Because 'the raw value is preserved so the typo is reportable'
    }

    It 'redacts userinfo out of the display form' {
        $env:POWERSHELL_LSP_OTEL_ENDPOINT = 'https://svcacct:s3cr3t-token@otel.example.com/v1/metrics'
        $info = Get-OtelEndpointInfo
        $info.display | Should -Not -Match 's3cr3t'
        $info.display | Should -Not -Match 'svcacct'
        $info.display | Should -BeExactly 'https://otel.example.com/v1/metrics'
        # ...while the value actually POSTed keeps the credential, because the collector needs it.
        $info.endpoint | Should -Match 's3cr3t'
    }

    It 'redacts the query string out of the display form' {
        $env:POWERSHELL_LSP_OTEL_ENDPOINT = 'https://otel.example.com/v1/metrics?api-key=AKIAHUNTME'
        $info = Get-OtelEndpointInfo
        $info.display | Should -Not -Match 'AKIAHUNTME'
        $info.display | Should -BeExactly 'https://otel.example.com/v1/metrics?<redacted>'
    }

    It 'keeps a non-default port in the display form' {
        $env:POWERSHELL_LSP_OTEL_ENDPOINT = 'http://collector.internal:4318/v1/metrics'
        (Get-OtelEndpointInfo).display | Should -BeExactly 'http://collector.internal:4318/v1/metrics'
    }
}

Describe 'The metadata boundary -- an ALLOWLIST, tested as a class and not as one field name' {
    It 'names exactly ext, taken and cached' {
        # The list itself is the control surface. Pinned so widening it is a deliberate edit
        # that shows up in a diff and in review, never a drive-by.
        (Get-OtelAttributeAllowList) | Should -Be @('ext', 'taken', 'cached')
    }

    It 'never emits the absolute path of the edited file' {
        $s = New-SecretPath -Tag 'basic'
        $rows = @((New-StatsRow -Path $s.Path))
        $payload = ConvertTo-OtelResourceMetrics -Records $rows -ServiceVersion '9.9.9-test' `
            -Now $script:PinNow -Start $script:PinStart
        $json = ($payload | ConvertTo-Json -Depth 12 -Compress)
        $json | Should -Not -Match ([regex]::Escape($s.Leaf)) -Because 'the edited file path must not leave the host'
        $json | Should -Not -Match 'billing'
        # Non-vacuity: the sentinel really is in the input, so its absence in the output is the
        # renderer's doing and not a fixture that never carried it.
        (($rows[0] | ConvertTo-Json -Compress)) | Should -Match ([regex]::Escape($s.Leaf))
    }

    It 'drops a field the writer does not write today -- the allowlist covers the CLASS' {
        # THE POINT OF THE WHOLE DESIGN. A denylist over `path` passes the test above and fails
        # this one. If someone adds a second path-bearing field to the stats row tomorrow, this
        # is the test that keeps it off the wire.
        $s = New-SecretPath -Tag 'future'
        $future = 'C:' + [char]92 + 'Users' + [char]92 + 'mande' + [char]92 + 'ZZFUTURE-LEAK' + [char]92 + 'settings.psd1'
        $rows = @((New-StatsRow -Path $s.Path -Extra @{ settingsPath = $future; repoRoot = 'D:\ZZREPO-LEAK' }))
        $payload = ConvertTo-OtelResourceMetrics -Records $rows -ServiceVersion '9.9.9-test' `
            -Now $script:PinNow -Start $script:PinStart
        $json = ($payload | ConvertTo-Json -Depth 12 -Compress)
        $json | Should -Not -Match 'ZZFUTURE-LEAK' -Because 'an unlisted field is not exported, whatever it is called'
        $json | Should -Not -Match 'ZZREPO-LEAK'
        $json | Should -Not -Match 'settingsPath'
        $json | Should -Not -Match 'repoRoot'
        # Non-vacuity: those fields really were on the input row.
        (($rows[0] | ConvertTo-Json -Compress)) | Should -Match 'ZZFUTURE-LEAK'
    }

    It 'does emit the three allowlisted attributes, with their values' {
        # The suppression assertions above would all pass against a renderer that emitted
        # nothing at all. This is the arm that must stay green for them to mean anything.
        $s = New-SecretPath -Tag 'present'
        $rows = @((New-StatsRow -Path $s.Path -Ext '.psm1' -Taken 'cache-hit' -Cached $true))
        $payload = ConvertTo-OtelResourceMetrics -Records $rows -ServiceVersion '9.9.9-test' `
            -Now $script:PinNow -Start $script:PinStart
        $m = Get-MetricByName -Payload $payload -Name 'powershell_lsp.edits'
        $m | Should -Not -BeNullOrEmpty
        $at = @{}
        foreach ($a in $m.sum.dataPoints[0].attributes) { $at[$a.key] = $a.value.stringValue }
        $at.Keys.Count | Should -Be 3
        $at['ext'] | Should -BeExactly '.psm1'
        $at['taken'] | Should -BeExactly 'cache-hit'
        $at['cached'] | Should -BeExactly 'True'
    }

    It 'never emits the per-edit timestamp as an attribute' {
        # `ts` is deliberately absent from the allowlist: as an attribute it would make every
        # point unique and turn a metric into an edit-by-edit activity trace.
        $s = New-SecretPath -Tag 'ts'
        $rows = @((New-StatsRow -Path $s.Path))
        $payload = ConvertTo-OtelResourceMetrics -Records $rows -ServiceVersion '9.9.9-test' `
            -Now $script:PinNow -Start $script:PinStart
        ($payload | ConvertTo-Json -Depth 12 -Compress) | Should -Not -Match '2026-09-09T10:00:00'
    }

    It 'carries no host identifier in the resource attributes' {
        $rows = @((New-StatsRow -Path (New-SecretPath -Tag 'res').Path))
        $payload = ConvertTo-OtelResourceMetrics -Records $rows -ServiceVersion '9.9.9-test' `
            -Now $script:PinNow -Start $script:PinStart
        $keys = @($payload.resourceMetrics[0].resource.attributes | ForEach-Object { $_.key })
        $keys | Should -Be @('service.name', 'service.version')
        $keys | Should -Not -Contain 'service.instance.id'
        $keys | Should -Not -Contain 'host.name'
    }
}

Describe 'The metric arithmetic -- and scope_trimmed means scope, not per-file cap' {
    It 'counts one edits point per distinct allowlisted bucket' {
        $p = New-SecretPath -Tag 'bkt'
        $rows = @(
            (New-StatsRow -Path $p.Path -Ext '.ps1' -Taken 'daemon-analyze' -Cached $false),
            (New-StatsRow -Path $p.Path -Ext '.ps1' -Taken 'daemon-analyze' -Cached $false),
            (New-StatsRow -Path $p.Path -Ext '.psm1' -Taken 'cache-hit' -Cached $true)
        )
        $payload = ConvertTo-OtelResourceMetrics -Records $rows -ServiceVersion '9.9.9-test' `
            -Now $script:PinNow -Start $script:PinStart
        $m = Get-MetricByName -Payload $payload -Name 'powershell_lsp.edits'
        @($m.sum.dataPoints).Count | Should -Be 2 -Because 'two rows share a bucket, one does not'
        $counts = @($m.sum.dataPoints | ForEach-Object { [int]$_.asInt } | Sort-Object)
        $counts | Should -Be @(1, 2)
        [int]$m.sum.aggregationTemporality | Should -Be 2 -Because 'CUMULATIVE'
        [bool]$m.sum.isMonotonic | Should -BeTrue
    }

    It 'computes nearest-rank p50/p95 per stage, matching show-stats.ps1' {
        $p = New-SecretPath -Tag 'pct'
        $rows = @(
            (New-StatsRow -Path $p.Path -TotalMs 30),
            (New-StatsRow -Path $p.Path -TotalMs 95),
            (New-StatsRow -Path $p.Path -TotalMs 420)
        )
        $payload = ConvertTo-OtelResourceMetrics -Records $rows -ServiceVersion '9.9.9-test' `
            -Now $script:PinNow -Start $script:PinStart
        (Get-GaugePoint -Payload $payload -Name 'powershell_lsp.edit.duration' -Stage 'total' -Quantile 'p50') |
            Should -Be 95
        (Get-GaugePoint -Payload $payload -Name 'powershell_lsp.edit.duration' -Stage 'total' -Quantile 'p95') |
            Should -Be 420
    }

    It 'ignores the null timings the parser-prepass path writes' {
        $p = New-SecretPath -Tag 'null'
        $rows = @(
            (New-StatsRow -Path $p.Path -ConnectMs $null -AnalysisMs $null -CodeActionMs $null -TotalMs 50),
            (New-StatsRow -Path $p.Path -ConnectMs 10 -AnalysisMs 100 -CodeActionMs 5 -TotalMs 200)
        )
        $payload = ConvertTo-OtelResourceMetrics -Records $rows -ServiceVersion '9.9.9-test' `
            -Now $script:PinNow -Start $script:PinStart
        # One real analysis sample -> p50 and p95 are both it, and no null was coerced to zero.
        (Get-GaugePoint -Payload $payload -Name 'powershell_lsp.edit.duration' -Stage 'analysis' -Quantile 'p50') |
            Should -Be 100
        (Get-GaugePoint -Payload $payload -Name 'powershell_lsp.edit.duration' -Stage 'analysis' -Quantile 'p95') |
            Should -Be 100
    }

    It 'totals records and corrections across every row' {
        $p = New-SecretPath -Tag 'vol'
        $rows = @(
            (New-StatsRow -Path $p.Path -Records 3 -Corrections 1),
            (New-StatsRow -Path $p.Path -Records 4 -Corrections 0)
        )
        $payload = ConvertTo-OtelResourceMetrics -Records $rows -ServiceVersion '9.9.9-test' `
            -Now $script:PinNow -Start $script:PinStart
        (Get-SumValue -Payload $payload -Name 'powershell_lsp.diagnostics.records') | Should -Be 7
        (Get-SumValue -Payload $payload -Name 'powershell_lsp.diagnostics.corrections') | Should -Be 1
    }

    It 'sums scope trimming over SCOPED rows only, not over per-file-cap truncation' {
        # THE DISCRIMINATING FIXTURE. lsp-client.ps1 writes scopeTotal/scopeSurfaced on every
        # row, and on an UNSCOPED row those two differ whenever perFileCap truncated the list.
        # Summing all rows would report cap truncation as edit-scope noise reduction -- two
        # mechanisms under one name. Row 1 is scoped and trims 9 -> 3 (six). Row 2 is NOT
        # scoped and its cap truncated 50 -> 20 (thirty). The answer is 6; the all-rows bug
        # says 36, so this fixture tells the two implementations apart.
        $p = New-SecretPath -Tag 'scope'
        $rows = @(
            (New-StatsRow -Path $p.Path -ScopeApplied $true -ScopeTotal 9 -ScopeSurfaced 3),
            (New-StatsRow -Path $p.Path -ScopeApplied $false -ScopeTotal 50 -ScopeSurfaced 20)
        )
        $payload = ConvertTo-OtelResourceMetrics -Records $rows -ServiceVersion '9.9.9-test' `
            -Now $script:PinNow -Start $script:PinStart
        (Get-SumValue -Payload $payload -Name 'powershell_lsp.edit.scope_trimmed') |
            Should -Be 6 -Because '36 would mean per-file-cap truncation was counted as scope trimming'
    }

    It 'renders an empty log as a well-formed payload with zero counters' {
        $payload = ConvertTo-OtelResourceMetrics -Records @() -ServiceVersion '9.9.9-test' `
            -Now $script:PinNow -Start $script:PinStart
        $payload.resourceMetrics[0].scopeMetrics[0].scope.name | Should -BeExactly 'powershell-lsp/stats'
        (Get-SumValue -Payload $payload -Name 'powershell_lsp.diagnostics.records') | Should -Be 0
        # No duration gauge at all rather than a gauge full of invented zeroes.
        (Get-MetricByName -Payload $payload -Name 'powershell_lsp.edit.duration') | Should -BeNullOrEmpty
    }

    It 'carries OTLP timestamps as nanosecond STRINGS' {
        $rows = @((New-StatsRow -Path (New-SecretPath -Tag 'ts2').Path))
        $payload = ConvertTo-OtelResourceMetrics -Records $rows -ServiceVersion '9.9.9-test' `
            -Now $script:PinNow -Start $script:PinStart
        $pt = (Get-MetricByName -Payload $payload -Name 'powershell_lsp.edits').sum.dataPoints[0]
        $pt.timeUnixNano | Should -BeOfType [string]
        # 2026-09-09T12:00:00Z = 1788955200 s -> 1788955200000000000 ns (cross-checked below).
        $pt.timeUnixNano | Should -BeExactly '1788955200000000000'
    }
}

Describe 'RED CONTROL -- the naive renderer leaks the path the allowlist suppresses' {
    It 'the fixture on disk is the one this control was written against' {
        # Proves the mutant LANDED and has not drifted. Hashed over LF-normalized content so
        # the Windows and POSIX legs agree.
        (Get-LfSha256 -FilePath $script:NaiveRenderer) | Should -BeExactly $script:NaiveRendererSha
    }

    It 'leaks the absolute path, where the shipped renderer does not' {
        $s = New-SecretPath -Tag 'red'
        $log = Write-Jsonl -Rows @((New-StatsRow -Path $s.Path)) -Tag 'red'

        $shipped = Invoke-RenderInChild -JsonlPath $log
        $mutant = Invoke-RenderInChild -JsonlPath $log -Naive

        $shipped.ExitCode | Should -Be 0 -Because 'the shipped run must have rendered at all'
        $mutant.ExitCode | Should -Be 0 -Because 'the mutant must RUN -- a crash is not a red control'
        $shipped.Stdout | Should -Not -BeNullOrEmpty
        $mutant.Stdout | Should -Not -BeNullOrEmpty

        $shipped.Stdout | Should -Not -Match ([regex]::Escape($s.Leaf))
        $mutant.Stdout | Should -Match ([regex]::Escape($s.Leaf)) -Because 'without the allowlist the path goes on the wire'
    }

    It 'SURVIVING ARM: the mutant changes ONLY the attributes, never the measurements' {
        # Without this the leak assertion above would credit a fixture that simply broke the
        # renderer. The duration gauges and the volume counters are shipped code in both runs,
        # so they must be identical; only the edits metric's attributes may differ.
        $s = New-SecretPath -Tag 'arm'
        $rows = @(
            (New-StatsRow -Path $s.Path -TotalMs 30 -Records 3 -Corrections 1 -ScopeApplied $true -ScopeTotal 9 -ScopeSurfaced 3),
            (New-StatsRow -Path $s.Path -TotalMs 420 -Records 4 -Corrections 0)
        )
        $log = Write-Jsonl -Rows $rows -Tag 'arm'

        $shipped = ($shippedRaw = Invoke-RenderInChild -JsonlPath $log).Stdout | ConvertFrom-Json
        $mutant = ($mutantRaw = Invoke-RenderInChild -JsonlPath $log -Naive).Stdout | ConvertFrom-Json
        $shippedRaw.ExitCode | Should -Be 0
        $mutantRaw.ExitCode | Should -Be 0

        foreach ($name in @('powershell_lsp.diagnostics.records',
                'powershell_lsp.diagnostics.corrections',
                'powershell_lsp.edit.scope_trimmed')) {
            (Get-SumValue -Payload $mutant -Name $name) |
                Should -Be (Get-SumValue -Payload $shipped -Name $name) -Because ($name + ' is shipped code in both runs')
        }
        foreach ($q in @('p50', 'p95')) {
            (Get-GaugePoint -Payload $mutant -Name 'powershell_lsp.edit.duration' -Stage 'total' -Quantile $q) |
                Should -Be (Get-GaugePoint -Payload $shipped -Name 'powershell_lsp.edit.duration' -Stage 'total' -Quantile $q)
        }
        # And the arm that must DIFFER, so the comparison above is not just two identical runs.
        $mutantRaw.Stdout | Should -Not -BeExactly $shippedRaw.Stdout
    }
}

Describe 'export-otel.ps1 -- sending is opt-in twice, and refusal is loud' {
    It 'reports the endpoint as OFF when nothing is set, and sends nothing' {
        $log = Write-Jsonl -Rows @((New-StatsRow -Path (New-SecretPath -Tag 'show').Path)) -Tag 'show'
        $r = Invoke-Exporter -JsonlPath $log -Endpoint 'UNSET' -ArgLine '-Show'
        $r.ExitCode | Should -Be 0
        $r.Stdout | Should -Match 'configured: NO'
        $r.Stdout | Should -Match 'samples available: 1'
    }

    It 'reports a configured endpoint by its REDACTED display form' {
        $log = Write-Jsonl -Rows @((New-StatsRow -Path (New-SecretPath -Tag 'show2').Path)) -Tag 'show2'
        $r = Invoke-Exporter -JsonlPath $log -Endpoint 'https://svcacct:s3cr3t@otel.example.com/v1/metrics' -ArgLine '-Show'
        $r.ExitCode | Should -Be 0
        $r.Stdout | Should -Match 'configured: YES'
        $r.Stdout | Should -Not -Match 's3cr3t' -Because 'a report must not print the credential it read'
        $r.Stdout | Should -Match 'otel\.example\.com'
    }

    It 'does NOT echo an unparseable value back, and says export is off' {
        $log = Write-Jsonl -Rows @((New-StatsRow -Path (New-SecretPath -Tag 'show3').Path)) -Tag 'show3'
        # A value that failed to parse could be anything -- including a pasted credential -- so
        # the one thing the report may not do is print it.
        $r = Invoke-Exporter -JsonlPath $log -Endpoint 'ZZBADVALUE-s3cr3t' -ArgLine '-Show'
        $r.ExitCode | Should -Be 0
        $r.Stdout | Should -Match 'configured: NO'
        $r.Stdout | Should -Not -Match 'ZZBADVALUE'
    }

    It 'renders the payload to stdout with no endpoint set, opening no socket' {
        $s = New-SecretPath -Tag 'render'
        $log = Write-Jsonl -Rows @((New-StatsRow -Path $s.Path)) -Tag 'render'
        $r = Invoke-Exporter -JsonlPath $log -Endpoint 'UNSET'
        $r.ExitCode | Should -Be 0
        $r.Stdout | Should -Match 'resourceMetrics'
        $r.Stdout | Should -Match 'powershell_lsp\.edits'
        $r.Stdout | Should -Not -Match ([regex]::Escape($s.Leaf))
    }

    It 'REFUSES -Send when no endpoint is configured' {
        $log = Write-Jsonl -Rows @((New-StatsRow -Path (New-SecretPath -Tag 'send').Path)) -Tag 'send'
        $r = Invoke-Exporter -JsonlPath $log -Endpoint 'UNSET' -ArgLine '-Send'
        $r.ExitCode | Should -Be 1
        $r.Stdout | Should -Match 'REFUSED to send'
    }

    It 'REFUSES -Send when the endpoint is set but unparseable' {
        # The inverted fallback, end to end: a typo does not become a POST somewhere unintended.
        $log = Write-Jsonl -Rows @((New-StatsRow -Path (New-SecretPath -Tag 'send2').Path)) -Tag 'send2'
        $r = Invoke-Exporter -JsonlPath $log -Endpoint 'htp://typo.example.com/v1/metrics' -ArgLine '-Send'
        $r.ExitCode | Should -Be 1
        $r.Stdout | Should -Match 'REFUSED to send'
    }

    It 'writes the payload to -OutFile without a path in it' {
        $s = New-SecretPath -Tag 'out'
        $log = Write-Jsonl -Rows @((New-StatsRow -Path $s.Path)) -Tag 'out'
        $outFile = Join-Path $TestDrive ('payload-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
        $r = Invoke-Exporter -JsonlPath $log -Endpoint 'UNSET' -ArgLine ('-OutFile ' + (ConvertTo-PsLiteral -Value $outFile))
        $r.ExitCode | Should -Be 0
        Test-Path -LiteralPath $outFile | Should -BeTrue
        $body = [System.IO.File]::ReadAllText($outFile)
        $body | Should -Match 'resourceMetrics'
        $body | Should -Not -Match ([regex]::Escape($s.Leaf))
    }
}

Describe 'P2-1 capture half -- diagnostic-shape CARDINALITY, never the shapes (dispatch 000291)' {
    BeforeAll {
        $script:NaiveShapes = Join-Path $PSScriptRoot 'fixtures/red-controls/otel-common-shapes.naive-000291.ps1'
        $script:NaiveShapesSha = 'd050b46ea383dacb2298d6ad0e8d8da2b50a295d1a17493eddd60c73d8ff79a5'

        function New-CaptureRow {
            # One capture row shaped as scripts/lib/lsp-common.ps1's Add-DiagnosticCaptureEntries
            # writes one. $Extra adds fields the shipped writer does NOT write today, which is how
            # the boundary is tested as a CLASS rather than as a fix for one field name.
            param(
                [string] $Hash = 'aaaa1111',
                [string] $RuleId = 'PSAvoidUsingCmdletAliases',
                [string] $Severity = 'Warning',
                [string] $Source = 'PSScriptAnalyzer',
                [string] $File = 'billing.ps1',
                [string] $Snippet = 'gci . | ? { $_.Length -gt 0 }',
                [string] $Message = 'alias gci used',
                [int] $Line = 12, [int] $Col = 3,
                [hashtable] $Extra = $null
            )
            $row = [ordered]@{
                ts = '2026-09-10T10:00:00.0000000-04:00'; file = $File; line = $Line; col = $Col
                ruleId = $RuleId; source = $Source; severity = $Severity; message = $Message
                snippet = $Snippet; hash = $Hash; verdict = ''
            }
            if ($null -ne $Extra) { foreach ($k in $Extra.Keys) { $row[$k] = $Extra[$k] } }
            # Round-trip through JSON so the object under test is a PSCustomObject parsed off a
            # JSONL line -- what the exporter actually gets -- and not a hashtable the test built.
            return (($row | ConvertTo-Json -Depth 8 -Compress) | ConvertFrom-Json)
        }

        function Get-ShapePayload {
            param([object[]] $CaptureRows, [object[]] $StatsRows = @())
            if (@($StatsRows).Count -eq 0) { $StatsRows = @((New-StatsRow -Path 'C:\t\a.ps1')) }
            return (ConvertTo-OtelResourceMetrics -Records $StatsRows -ServiceVersion '9.9.9' `
                    -Now $script:PinNow -Start $script:PinStart -CaptureRecords $CaptureRows)
        }
    }

    It 'counts DISTINCT shapes, not occurrences' {
        # Four rows, two distinct hashes, all in one allowlisted bucket. The volume question is
        # already answered by diagnostics.records; this metric answers a different one, and the
        # difference between 2 and 4 is the whole of it.
        $rows = @(
            (New-CaptureRow -Hash 'h-alpha'), (New-CaptureRow -Hash 'h-alpha'),
            (New-CaptureRow -Hash 'h-beta'), (New-CaptureRow -Hash 'h-alpha')
        )
        $m = Get-MetricByName -Payload (Get-ShapePayload -CaptureRows $rows) -Name 'powershell_lsp.diagnostics.shapes'
        $m | Should -Not -BeNullOrEmpty
        @($m.sum.dataPoints).Count | Should -Be 1
        $m.sum.dataPoints[0].asInt | Should -BeExactly '2'
    }

    It 'buckets by the allowlisted axes, so two rules do not collapse into one number' {
        $rows = @(
            (New-CaptureRow -Hash 'h1' -RuleId 'PSAvoidUsingCmdletAliases'),
            (New-CaptureRow -Hash 'h2' -RuleId 'PSAvoidUsingCmdletAliases'),
            (New-CaptureRow -Hash 'h3' -RuleId 'PSUseApprovedVerbs')
        )
        $m = Get-MetricByName -Payload (Get-ShapePayload -CaptureRows $rows) -Name 'powershell_lsp.diagnostics.shapes'
        @($m.sum.dataPoints).Count | Should -Be 2
        $byRule = @{}
        foreach ($p in $m.sum.dataPoints) {
            $rid = ($p.attributes | Where-Object { $_.key -eq 'ruleId' }).value.stringValue
            $byRule[$rid] = $p.asInt
        }
        $byRule['PSAvoidUsingCmdletAliases'] | Should -BeExactly '2'
        $byRule['PSUseApprovedVerbs'] | Should -BeExactly '1'
    }

    It 'THE HASH ITSELF NEVER LEAVES -- it is what the metric counts, not what it publishes' {
        # The vacuity arm comes first: the rows must really carry the hash, or a clean payload
        # would prove nothing. Scoped to the whole payload text, not to the shapes metric,
        # because a hash smuggled into any other field is still published.
        $h = 'ZZHASH-' + [guid]::NewGuid().ToString('N').Substring(0, 10)
        $rows = @((New-CaptureRow -Hash $h), (New-CaptureRow -Hash ($h + '-two')))
        ([string]$rows[0].hash) | Should -Match ([regex]::Escape($h)) -Because 'the fixture must really carry the hash'

        $json = (Get-ShapePayload -CaptureRows $rows) | ConvertTo-Json -Depth 12 -Compress
        $json | Should -Match 'powershell_lsp.diagnostics.shapes' -Because 'the metric must have been emitted at all'
        $json | Should -Not -Match ([regex]::Escape($h))
    }

    It 'an UNKNOWN capture field is dropped -- the boundary is a CLASS, not a list of known-bad names' {
        # The property the allowlist exists for. A field nobody has thought of yet must be absent
        # WITHOUT anyone adding it to a denylist. `settingsPath` is the same probe 000290 used on
        # the stats side, which keeps the two halves testing the same property.
        $secret = 'ZZUNKNOWN-' + [guid]::NewGuid().ToString('N').Substring(0, 10)
        $rows = @((New-CaptureRow -Hash 'h1' -Extra @{ settingsPath = $secret; futureField = $secret }))
        $json = (Get-ShapePayload -CaptureRows $rows) | ConvertTo-Json -Depth 12 -Compress
        $json | Should -Match 'powershell_lsp.diagnostics.shapes'
        $json | Should -Not -Match ([regex]::Escape($secret))
    }

    It 'the published attribute key set IS the capture allowlist, exactly' {
        $rows = @((New-CaptureRow -Hash 'h1'))
        $m = Get-MetricByName -Payload (Get-ShapePayload -CaptureRows $rows) -Name 'powershell_lsp.diagnostics.shapes'
        $keys = @($m.sum.dataPoints[0].attributes | ForEach-Object { $_.key }) | Sort-Object
        ($keys -join ',') | Should -BeExactly 'ruleId,severity,source'
        ($keys -join ',') | Should -BeExactly ((@(Get-OtelAttributeAllowList -Kind 'capture') | Sort-Object) -join ',')
    }

    It 'the SOURCE LINE, the message and the file never leave' {
        # snippet is the single most sensitive field in the record -- it is verbatim source, and
        # it is why `metadata` capture mode removes it from the log at all.
        $mark = 'ZZSNIP-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $rows = @((New-CaptureRow -Hash 'h1' -Snippet ('$x = ' + $mark) -Message ('bad thing near ' + $mark) -File ($mark + '.ps1')))
        ([string]$rows[0].snippet) | Should -Match ([regex]::Escape($mark)) -Because 'the fixture must really carry the source line'
        $json = (Get-ShapePayload -CaptureRows $rows) | ConvertTo-Json -Depth 12 -Compress
        $json | Should -Not -Match ([regex]::Escape($mark))
    }

    It 'a row with NO hash is skipped, not counted as one phantom empty shape' {
        $rows = @(
            (New-CaptureRow -Hash 'h1'), (New-CaptureRow -Hash ''),
            (New-CaptureRow -Hash '   '), (New-CaptureRow -Hash 'h2')
        )
        $m = Get-MetricByName -Payload (Get-ShapePayload -CaptureRows $rows) -Name 'powershell_lsp.diagnostics.shapes'
        $m.sum.dataPoints[0].asInt | Should -BeExactly '2' -Because 'the two blank-hash rows must not add a third shape'
    }

    It 'NO capture rows means NO shapes metric -- never a zero' {
        # A zero published to a fleet dashboard reads as "this host produced no distinct
        # diagnostics". That is a different statement from "this reader was given no capture
        # log", and the exporter already refuses to conflate the two on the stats side.
        $payload = Get-ShapePayload -CaptureRows @()
        (Get-MetricByName -Payload $payload -Name 'powershell_lsp.diagnostics.shapes') | Should -BeNullOrEmpty
    }

    It 'REGRESSION: with no capture rows the payload is IDENTICAL to the pre-000291 rendering' {
        # The refactor that gave the allowlist a -Kind must not have moved the stats half by a
        # byte. Both renderings are produced here from the same pinned timestamps, so a
        # difference could only come from the change under test.
        $stats = @(
            (New-StatsRow -Path 'C:\t\a.ps1' -TotalMs 30 -Records 3 -Corrections 1 -ScopeApplied $true -ScopeTotal 9 -ScopeSurfaced 3),
            (New-StatsRow -Path 'C:\t\b.psm1' -Ext '.psm1' -TotalMs 420 -Records 4)
        )
        $withoutParam = (ConvertTo-OtelResourceMetrics -Records $stats -ServiceVersion '9.9.9' `
                -Now $script:PinNow -Start $script:PinStart) | ConvertTo-Json -Depth 12 -Compress
        $withEmpty = (ConvertTo-OtelResourceMetrics -Records $stats -ServiceVersion '9.9.9' `
                -Now $script:PinNow -Start $script:PinStart -CaptureRecords @()) | ConvertTo-Json -Depth 12 -Compress
        $withEmpty | Should -BeExactly $withoutParam
        $withoutParam | Should -Match 'powershell_lsp.edits' -Because 'the comparison must be over a real payload'
    }

    It 'an UNRECOGNIZED -Kind publishes NOTHING, rather than falling back to another kind' {
        # A boundary must fail closed. A typo'd kind that silently returned the stats list would
        # let a capture row be rendered under stats permissions, which is the one direction an
        # allowlist may never take.
        @(Get-OtelAttributeAllowList -Kind 'captrue').Count | Should -Be 0
        @(Get-OtelAttributeAllowList -Kind '').Count | Should -Be 0
        @(ConvertTo-OtelRowAttributes -Record (New-CaptureRow -Hash 'h1') -Kind 'captrue').Count | Should -Be 0
        # ...and the two real kinds still answer.
        (@(Get-OtelAttributeAllowList -Kind 'stats') -join ',') | Should -BeExactly 'ext,taken,cached'
        (@(Get-OtelAttributeAllowList) -join ',') | Should -BeExactly 'ext,taken,cached' -Because 'the default must stay stats for every pre-000291 caller'
    }

    It 'RED CONTROL: the fixture on disk is the one this control was written against' {
        (Get-LfSha256 -FilePath $script:NaiveShapes) | Should -BeExactly $script:NaiveShapesSha
    }

    It 'RED CONTROL: the naive per-hash metric publishes the shapes, where the shipped one does not' {
        # NOT a prior implementation -- New-OtelShapeCountPoints is new here and none exists. It
        # is the obvious first pass: one point per hash, hash as an attribute. It reads as MORE
        # informative than the shipped version, which is what makes it the right mutant.
        $h = 'ZZRED-' + [guid]::NewGuid().ToString('N').Substring(0, 10)
        $rows = @((New-CaptureRow -Hash $h), (New-CaptureRow -Hash ($h + '-two')))

        $shipped = (Get-ShapePayload -CaptureRows $rows) | ConvertTo-Json -Depth 12 -Compress

        . $script:NaiveShapes    # shadows exactly ONE function, for this It only
        $mutant = (Get-ShapePayload -CaptureRows $rows) | ConvertTo-Json -Depth 12 -Compress

        $shipped | Should -Not -BeNullOrEmpty
        $mutant | Should -Not -BeNullOrEmpty -Because 'the mutant must RUN -- a crash is not a red control'
        $mutant | Should -Not -BeExactly $shipped -Because 'the override must actually have taken effect'

        $shipped | Should -Not -Match ([regex]::Escape($h))
        $mutant | Should -Match ([regex]::Escape($h)) -Because 'the naive cut puts the shape hash on the wire'
    }

    It 'RED CONTROL SURVIVING ARM: the mutant changes ONLY the shapes metric' {
        # Without this the leak assertion above would credit a fixture that simply broke the
        # renderer. The five metrics 000290 shipped are shipped code in BOTH runs.
        $stats = @(
            (New-StatsRow -Path 'C:\t\a.ps1' -TotalMs 30 -Records 3 -Corrections 1 -ScopeApplied $true -ScopeTotal 9 -ScopeSurfaced 3),
            (New-StatsRow -Path 'C:\t\b.ps1' -TotalMs 420 -Records 4)
        )
        $rows = @((New-CaptureRow -Hash 'h1'), (New-CaptureRow -Hash 'h2'))
        $shipped = Get-ShapePayload -CaptureRows $rows -StatsRows $stats

        . $script:NaiveShapes
        $mutant = Get-ShapePayload -CaptureRows $rows -StatsRows $stats

        foreach ($name in @('powershell_lsp.diagnostics.records',
                'powershell_lsp.diagnostics.corrections',
                'powershell_lsp.edit.scope_trimmed')) {
            (Get-SumValue -Payload $mutant -Name $name) |
                Should -Be (Get-SumValue -Payload $shipped -Name $name) -Because ($name + ' is shipped code in both runs')
        }
        foreach ($q in @('p50', 'p95')) {
            (Get-GaugePoint -Payload $mutant -Name 'powershell_lsp.edit.duration' -Stage 'total' -Quantile $q) |
                Should -Be (Get-GaugePoint -Payload $shipped -Name 'powershell_lsp.edit.duration' -Stage 'total' -Quantile $q)
        }
        @((Get-MetricByName -Payload $mutant -Name 'powershell_lsp.edits').sum.dataPoints).Count |
            Should -Be @((Get-MetricByName -Payload $shipped -Name 'powershell_lsp.edits').sum.dataPoints).Count
        # ...and the one thing it MAY change, it did.
        @((Get-MetricByName -Payload $mutant -Name 'powershell_lsp.diagnostics.shapes').sum.dataPoints).Count |
            Should -Not -Be @((Get-MetricByName -Payload $shipped -Name 'powershell_lsp.diagnostics.shapes').sum.dataPoints).Count
    }
}
