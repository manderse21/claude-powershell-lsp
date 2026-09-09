# otel-common.ps1 -- render the shipped telemetry instruments as OTLP metrics.
#
# P2-1 (docs/roadmap-ii/ENTERPRISE-PROGRAM-DOCKET.md item 7). This file is a RENDERING of
# measurements that already exist -- the `enableStats` JSONL timing lines written by
# lsp-client.ps1 -- and adds no new measurement layer, no new hot-path work, and nothing the
# per-edit path can see. Nothing here runs during an edit: the exporter is an out-of-band
# reader of logs/stats.jsonl, the same shape scripts/show-stats.ps1 already is.
#
# THE METADATA BOUNDARY IS THE POINT OF THIS FILE, and it is an ALLOWLIST.
# A stats row carries `path` -- the ABSOLUTE path of the edited file. docs/configuration.md
# says so under `enableStats`, and it is why that knob is `false` in every profile. An OTel
# exporter sends off the host, so the row's own shape is exactly what must NOT reach the wire.
# Get-OtelAttributeAllowList names the three fields that may become attributes; every other
# field of every row -- present today or added tomorrow -- is dropped because it was never
# named, not because a denylist happened to catch it.
#
# WHY AN ALLOWLIST AND NOT A DENYLIST, stated where the decision lives: a denylist over `path`
# is a guard that measures a proxy (Hub Rule 35). It is correct exactly until someone adds a
# second field carrying a path -- `settingsPath`, a resolved data root, a repo root -- at which
# point it keeps passing while the thing it protects has already leaked. The allowlist fails the
# other way: a genuinely useful new attribute is invisible until someone adds it deliberately,
# which is a review, not a leak.
#
# LibPurity G1: functions ONLY at top level. No param(), no Set-StrictMode, no assignments --
# this file is dot-sourced into a caller's scope and must not rewrite one variable of it.
#
# ASCII only (Windows PowerShell 5.1 reads UTF-8-without-BOM through Windows-1252).

function Get-OtelAttributeAllowList {
    # THE metadata boundary. The ONLY stats-row fields that may leave the host as attributes.
    #
    #   ext     the edited file's extension (.ps1 / .psm1 / .psd1) -- a type, not a location.
    #   taken   which analysis path ran ('cache-hit', 'daemon-analyze', 'pre-pssa-or-parse') --
    #           a fixed internal vocabulary, bounded cardinality.
    #   cached  whether the daemon served this edit from its cache.
    #
    # DELIBERATELY ABSENT, and each for its own reason rather than by omission:
    #   path    the absolute path of the edited file. This is the field the boundary exists for.
    #   ts      a per-edit wall-clock stamp; as an attribute it would make every point unique
    #           and turn a metric into an event log carrying an edit-by-edit activity trace.
    return @('ext', 'taken', 'cached')
}

function Get-OtelField {
    # One field off a parsed JSONL row, or $null. Self-contained on purpose: this library is
    # dot-sourced by the exporter and by tests, and a dependency on lsp-common.ps1's Get-Prop
    # would make the load ORDER of two libraries a correctness condition of the renderer.
    param([object] $Record, [string] $Name)
    if ($null -eq $Record) { return $null }
    if ($null -eq $Record.PSObject) { return $null }
    if ($Record.PSObject.Properties.Name -notcontains $Name) { return $null }
    return $Record.$Name
}

function Get-OtelNumericField {
    # Every numeric value of one field across rows, dropping nulls and non-numbers. The
    # parser-prepass path writes connect/analysis/codeAction as null, so "absent" is normal
    # and is not an error.
    param([object[]] $Records, [string] $Name)
    $vals = @()
    foreach ($r in @($Records)) {
        $v = Get-OtelField -Record $r -Name $Name
        if ($null -eq $v) { continue }
        $d = 0.0
        if ([double]::TryParse([string]$v, [ref]$d)) { $vals += $d }
    }
    return @($vals)
}

function Get-OtelPercentile {
    # Nearest-rank percentile; $null for an empty set. Same definition scripts/show-stats.ps1
    # uses, so a number read off the collector and a number read off show-stats.ps1 agree.
    param([double[]] $Values, [double] $P)
    $s = @($Values | Sort-Object)
    if ($s.Count -eq 0) { return $null }
    $rank = [int][Math]::Ceiling(($P / 100.0) * $s.Count)
    if ($rank -lt 1) { $rank = 1 }
    if ($rank -gt $s.Count) { $rank = $s.Count }
    return $s[$rank - 1]
}

function New-OtelAttribute {
    # One OTLP KeyValue. Every attribute is rendered as a stringValue, including booleans:
    # the collector side groups on them either way, and one representation keeps the
    # allowlist's output shape independent of what type a row happened to parse to.
    param([string] $Key, [object] $Value)
    $s = ''
    if ($null -ne $Value) { $s = [string]$Value }
    return [ordered]@{ key = $Key; value = [ordered]@{ stringValue = $s } }
}

function ConvertTo-OtelRowAttributes {
    # The allowlist applied to ONE row. This is the single seam through which a row's own
    # fields may become attributes -- there is no other path from a stats row to the wire.
    param([object] $Record)
    $attrs = @()
    foreach ($name in (Get-OtelAttributeAllowList)) {
        $v = Get-OtelField -Record $Record -Name $name
        if ($null -eq $v) { continue }
        $attrs += (New-OtelAttribute -Key $name -Value $v)
    }
    return @($attrs)
}

function Get-OtelBucketKey {
    # A stable grouping key for one row over the allowlisted fields only.
    #
    # The separator is US (0x1F) via [char], NOT a `u{001f} escape: that escape is PowerShell 7
    # syntax and is a PARSE ERROR under Windows PowerShell 5.1, which is one of this plugin's
    # six CI legs.
    param([object] $Record)
    $parts = @()
    foreach ($name in (Get-OtelAttributeAllowList)) {
        $v = Get-OtelField -Record $Record -Name $name
        $parts += ($name + '=' + [string]$v)
    }
    return ($parts -join ([char]0x1F))
}

function Get-OtelUnixNano {
    # OTLP timestamps are nanoseconds since the Unix epoch, carried as a STRING because the
    # value overflows a JSON number's exact-integer range.
    param([datetime] $When)
    $utc = $When.ToUniversalTime()
    $epoch = [datetime]::SpecifyKind([datetime]'1970-01-01T00:00:00', [System.DateTimeKind]::Utc)
    $ms = [long][Math]::Floor(($utc - $epoch).TotalMilliseconds)
    return ([string]($ms * 1000000L))
}

function New-OtelSumMetric {
    # A cumulative, monotonic Sum -- a counter. aggregationTemporality 2 is CUMULATIVE.
    param([string] $Name, [string] $Unit, [object[]] $DataPoints)
    return [ordered]@{
        name = $Name
        unit = $Unit
        sum  = [ordered]@{
            dataPoints             = @($DataPoints)
            aggregationTemporality = 2
            isMonotonic            = $true
        }
    }
}

function New-OtelGaugeMetric {
    # A Gauge -- a point-in-time reading. The percentiles are gauges rather than a Histogram
    # because the stats log stores the already-computed per-edit durations, not bucket counts:
    # rendering a Histogram would mean inventing bucket boundaries the instrument never had.
    param([string] $Name, [string] $Unit, [object[]] $DataPoints)
    return [ordered]@{
        name  = $Name
        unit  = $Unit
        gauge = [ordered]@{ dataPoints = @($DataPoints) }
    }
}

function Get-OtelSumOfField {
    # Integer total of one numeric field across rows. Absent everywhere -> 0.
    param([object[]] $Records, [string] $Name)
    $t = 0.0
    foreach ($v in (Get-OtelNumericField -Records $Records -Name $Name)) { $t += $v }
    return [int]$t
}

function New-OtelPlainSumPoints {
    # One attribute-free counter point. Its own function so the three volume counters cannot
    # drift from one another in shape.
    param([int] $Value, [string] $TimeUnixNano, [string] $StartTimeUnixNano)
    return @(
        [ordered]@{
            asInt             = [string]$Value
            timeUnixNano      = $TimeUnixNano
            startTimeUnixNano = $StartTimeUnixNano
            attributes        = @()
        }
    )
}

function ConvertTo-OtelResourceMetrics {
    # Render a set of parsed stats rows as one OTLP ExportMetricsServiceRequest body.
    #
    # THE SHAPE IS OTLP/HTTP JSON (opentelemetry.proto.collector.metrics.v1), which is what a
    # collector accepts at /v1/metrics with Content-Type: application/json. No SDK and no
    # dependency: the payload is a nested hashtable that ConvertTo-Json renders, which is the
    # whole reason this slice is cheap.
    #
    # $Now and $Start are PARAMETERS rather than Get-Date calls so a test can pin the
    # timestamps and compare two renderings byte for byte.
    param(
        [object[]] $Records,
        [string]   $ServiceVersion = '0.0.0-unknown',
        [datetime] $Now = [datetime]::UtcNow,
        [datetime] $Start = [datetime]::UtcNow
    )
    $rows = @($Records)
    $tNow = Get-OtelUnixNano -When $Now
    $tStart = Get-OtelUnixNano -When $Start

    # --- powershell_lsp.edits: one counter point per allowlisted bucket ---------------
    $buckets = [ordered]@{}
    foreach ($r in $rows) {
        $k = Get-OtelBucketKey -Record $r
        if (-not $buckets.Contains($k)) {
            $buckets[$k] = [ordered]@{ n = 0; attrs = (ConvertTo-OtelRowAttributes -Record $r) }
        }
        $buckets[$k].n = [int]$buckets[$k].n + 1
    }
    $editPoints = @()
    foreach ($k in $buckets.Keys) {
        $editPoints += [ordered]@{
            asInt             = [string][int]$buckets[$k].n
            timeUnixNano      = $tNow
            startTimeUnixNano = $tStart
            attributes        = @($buckets[$k].attrs)
        }
    }

    # --- powershell_lsp.edit.duration: p50/p95 per stage ------------------------------
    $durPoints = @()
    foreach ($stage in @(
            @{ name = 'connect'; field = 'connectMs' },
            @{ name = 'analysis'; field = 'analysisMs' },
            @{ name = 'code_action'; field = 'codeActionMs' },
            @{ name = 'total'; field = 'totalMs' })) {
        $vals = Get-OtelNumericField -Records $rows -Name $stage.field
        if (@($vals).Count -eq 0) { continue }
        foreach ($q in @(50, 95)) {
            $p = Get-OtelPercentile -Values $vals -P $q
            if ($null -eq $p) { continue }
            $durPoints += [ordered]@{
                asDouble     = [double]$p
                timeUnixNano = $tNow
                attributes   = @(
                    (New-OtelAttribute -Key 'stage' -Value $stage.name),
                    (New-OtelAttribute -Key 'quantile' -Value ('p' + [string]$q))
                )
            }
        }
    }

    # --- the diagnostic-volume counters ------------------------------------------------
    $recTotal = Get-OtelSumOfField -Records $rows -Name 'records'
    $corrTotal = Get-OtelSumOfField -Records $rows -Name 'corrections'

    # SCOPE TRIMMING IS SUMMED OVER THE SCOPED ROWS ONLY, which is scripts/show-stats.ps1's own
    # definition and not a narrowing for tidiness. lsp-client.ps1 writes scopeTotal/scopeSurfaced
    # on EVERY row, scoped or not, and on an unscoped row those two differ whenever perFileCap
    # truncated the list. Summing all rows would therefore report cap truncation as edit-scope
    # noise reduction -- two different mechanisms under one name, with no way to tell from the
    # metric which one moved. Restricting to scopeApplied rows keeps the number meaning the one
    # thing it claims, and keeps it equal to what show-stats.ps1 prints for the same log.
    $scopedRows = @($rows | Where-Object { [bool](Get-OtelField -Record $_ -Name 'scopeApplied') })
    $scopeTotal = Get-OtelSumOfField -Records $scopedRows -Name 'scopeTotal'
    $scopeSurfaced = Get-OtelSumOfField -Records $scopedRows -Name 'scopeSurfaced'
    $trimmed = $scopeTotal - $scopeSurfaced
    if ($trimmed -lt 0) { $trimmed = 0 }

    $metrics = @()
    $metrics += (New-OtelSumMetric -Name 'powershell_lsp.edits' -Unit '1' -DataPoints $editPoints)
    if (@($durPoints).Count -gt 0) {
        $metrics += (New-OtelGaugeMetric -Name 'powershell_lsp.edit.duration' -Unit 'ms' -DataPoints $durPoints)
    }
    $metrics += (New-OtelSumMetric -Name 'powershell_lsp.diagnostics.records' -Unit '1' `
            -DataPoints (New-OtelPlainSumPoints -Value $recTotal -TimeUnixNano $tNow -StartTimeUnixNano $tStart))
    $metrics += (New-OtelSumMetric -Name 'powershell_lsp.diagnostics.corrections' -Unit '1' `
            -DataPoints (New-OtelPlainSumPoints -Value $corrTotal -TimeUnixNano $tNow -StartTimeUnixNano $tStart))
    $metrics += (New-OtelSumMetric -Name 'powershell_lsp.edit.scope_trimmed' -Unit '1' `
            -DataPoints (New-OtelPlainSumPoints -Value $trimmed -TimeUnixNano $tNow -StartTimeUnixNano $tStart))

    # RESOURCE ATTRIBUTES are fixed strings and the plugin version -- never anything derived
    # from the host, the user, or a path. service.instance.id is deliberately NOT set: it would
    # be a per-machine identifier, and nothing in this slice is chartered to identify a host.
    return [ordered]@{
        resourceMetrics = @(
            [ordered]@{
                resource     = [ordered]@{
                    attributes = @(
                        (New-OtelAttribute -Key 'service.name' -Value 'powershell-lsp'),
                        (New-OtelAttribute -Key 'service.version' -Value $ServiceVersion)
                    )
                }
                scopeMetrics = @(
                    [ordered]@{
                        scope   = [ordered]@{ name = 'powershell-lsp/stats'; version = $ServiceVersion }
                        metrics = @($metrics)
                    }
                )
            }
        )
    }
}
