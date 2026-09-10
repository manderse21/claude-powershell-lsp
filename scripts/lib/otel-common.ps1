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
    # THE metadata boundary, for EVERY record kind this exporter reads. There is no second
    # allowlist and no other path from a record's own fields to the wire.
    #
    # `-Kind` SELECTS A LIST; IT DOES NOT ADD A DOOR. The two record kinds have disjoint
    # vocabularies, so a single flat union would silently permit a capture field on a stats row
    # and vice versa -- inert today only because neither record happens to carry the other's
    # names, which is precisely the "safe until someone adds a field" shape an allowlist exists
    # to refuse. One function still owns the whole boundary; it just answers per kind.
    #
    # ---- Kind 'stats' -- rows from logs/stats.jsonl (dispatch 000290) --------------------
    #   ext     the edited file's extension (.ps1 / .psm1 / .psd1) -- a type, not a location.
    #   taken   which analysis path ran ('cache-hit', 'daemon-analyze', 'pre-pssa-or-parse') --
    #           a fixed internal vocabulary, bounded cardinality.
    #   cached  whether the daemon served this edit from its cache.
    #
    # DELIBERATELY ABSENT from 'stats', each for its own reason rather than by omission:
    #   path    the absolute path of the edited file. This is the field the boundary exists for.
    #   ts      a per-edit wall-clock stamp; as an attribute it would make every point unique
    #           and turn a metric into an event log carrying an edit-by-edit activity trace.
    #
    # ---- Kind 'capture' -- rows from dogfood/diagnostics.jsonl (dispatch 000291) ---------
    #   ruleId    the analyzer rule that fired (PSAvoidUsingCmdletAliases, ...). A fixed
    #             vocabulary shipped with the analyzer -- bounded, and the axis the shape
    #             count is worth slicing by at all.
    #   severity  Error / Warning / Information. A three-value vocabulary.
    #   source    which analyzer produced it ('PSScriptAnalyzer', the plugin's own pre-pass).
    #             A two-value internal vocabulary.
    #
    # DELIBERATELY ABSENT from 'capture', and this list is the point of the slice:
    #   hash      the diagnostic SHAPE hash. It is what the metric COUNTS, and it must never
    #             become an attribute: one point per distinct hash is unbounded cardinality,
    #             and it would turn a metric into an event log -- the same reason `ts` is off
    #             the stats list. A COUNT of distinct shapes is a metric; the shapes are not.
    #   snippet   the offending SOURCE LINE, verbatim. The single most sensitive field in the
    #             record; it is why `metadata` capture mode removes it from the log at all.
    #   message   the analyzer's text, which quotes identifiers out of the source.
    #   file      a location. Basenamed in `metadata` mode and still a filename either way.
    #   line/col  a location within that file.
    #   ts        as above.
    #   verdict   bounded, but it is dogfooding bookkeeping about a human's triage of a
    #             finding, not a property of the host's diagnostic surface. Off by scope, not
    #             by cardinality -- recorded here so a later reader does not read the omission
    #             as an oversight and "fix" it.
    param([string] $Kind = 'stats')
    switch ($Kind) {
        'capture' { return @('ruleId', 'severity', 'source') }
        'stats' { return @('ext', 'taken', 'cached') }
        default {
            # An unrecognized kind yields NO attributes rather than the stats list. Failing
            # closed is the only safe direction for a boundary: a typo must publish nothing,
            # never fall back to some other record kind's permissions.
            return @()
        }
    }
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
    # fields may become attributes -- there is no other path from any record to the wire.
    # `-Kind` is forwarded to the allowlist and defaults to 'stats', so every pre-000291
    # caller keeps its exact behaviour without being touched.
    param([object] $Record, [string] $Kind = 'stats')
    $attrs = @()
    foreach ($name in (Get-OtelAttributeAllowList -Kind $Kind)) {
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
    param([object] $Record, [string] $Kind = 'stats')
    $parts = @()
    foreach ($name in (Get-OtelAttributeAllowList -Kind $Kind)) {
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

function New-OtelShapeCountPoints {
    # DIAGNOSTIC-SHAPE CARDINALITY: how many DISTINCT diagnostic shapes this host produced,
    # sliced by the 'capture' allowlist (dispatch 000291, P2-1's capture-`hash` half).
    #
    # THE VALUE IS A COUNT OF DISTINCT HASHES. THE HASHES THEMSELVES NEVER LEAVE. That is the
    # whole design: `hash` is a per-shape identifier with unbounded cardinality, so exporting it
    # as an attribute would emit one time series per distinct diagnostic and turn a metric into
    # an event log -- the same failure `ts` is kept off the stats list to avoid. A count answers
    # the question the metric exists for ("is this host's diagnostic surface widening?") without
    # publishing anything about WHICH shapes those are.
    #
    # De-duplication is over the hash within each bucket, so the same finding recurring on every
    # edit counts once, which is what makes the number a cardinality rather than a volume. The
    # volume question is already answered by powershell_lsp.diagnostics.records.
    #
    # A row with no `hash` is SKIPPED rather than counted as a distinct empty shape: capture
    # rows written before the hash existed, and any malformed row, would otherwise all collapse
    # into one phantom shape and inflate every bucket by exactly one.
    param([object[]] $Records, [string] $TimeUnixNano, [string] $StartTimeUnixNano)
    $buckets = [ordered]@{}
    foreach ($r in @($Records)) {
        $h = Get-OtelField -Record $r -Name 'hash'
        if ($null -eq $h -or [string]::IsNullOrWhiteSpace([string]$h)) { continue }
        $k = Get-OtelBucketKey -Record $r -Kind 'capture'
        if (-not $buckets.Contains($k)) {
            $buckets[$k] = [ordered]@{
                seen  = (New-Object 'System.Collections.Generic.HashSet[string]')
                attrs = (ConvertTo-OtelRowAttributes -Record $r -Kind 'capture')
            }
        }
        [void]$buckets[$k].seen.Add([string]$h)
    }
    $points = @()
    foreach ($k in $buckets.Keys) {
        $points += [ordered]@{
            asInt             = [string][int]$buckets[$k].seen.Count
            timeUnixNano      = $TimeUnixNano
            startTimeUnixNano = $StartTimeUnixNano
            attributes        = @($buckets[$k].attrs)
        }
    }
    return @($points)
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
    #
    # $CaptureRecords is OPTIONAL and defaults to empty (dispatch 000291). When it is empty the
    # payload is byte-identical to what 000290 shipped: no shapes metric is emitted at all,
    # rather than one emitted with a zero. A zero here would be a claim to a fleet dashboard
    # that this host produced no distinct diagnostics, which is a different statement from "this
    # reader was given no capture log", and the exporter already refuses to conflate those.
    param(
        [object[]] $Records,
        [string]   $ServiceVersion = '0.0.0-unknown',
        [datetime] $Now = [datetime]::UtcNow,
        [datetime] $Start = [datetime]::UtcNow,
        [object[]] $CaptureRecords = @()
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

    # --- powershell_lsp.diagnostics.shapes: DISTINCT shapes, never the shapes themselves -----
    $shapePoints = New-OtelShapeCountPoints -Records @($CaptureRecords) -TimeUnixNano $tNow -StartTimeUnixNano $tStart
    if (@($shapePoints).Count -gt 0) {
        $metrics += (New-OtelSumMetric -Name 'powershell_lsp.diagnostics.shapes' -Unit '1' -DataPoints $shapePoints)
    }

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
