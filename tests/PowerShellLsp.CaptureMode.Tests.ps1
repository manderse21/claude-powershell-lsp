#Requires -Version 5.1

# POWERSHELL_LSP_CAPTURE_MODE -- the metadata-only capture mode (dispatch 000282 leg C;
# ruling R8 of 2026-09-05 = ENTERPRISE-PROGRAM-DOCKET R-A option (a)).
#
# WHAT IS UNDER TEST. Add-DiagnosticCaptureEntries tees every surfaced diagnostic to a local
# JSONL log carrying the absolute file path and the verbatim offending source line. THREAT-MODEL
# T6.1 accepts that for a LOCAL reader; the enterprise review's reader set -- EDR, backup,
# eDiscovery, DLP -- is a management plane that reads the disk without being that local user.
# The mode answers it: `metadata` keeps the analysis channel and drops the source text.
#
# THE ASSERTION THAT MATTERS MOST IS HASH EQUALITY. `hash` is computed FROM the snippet
# (Get-DiagnosticShapeHash -RuleId .. -OffendingLine $snippet), and the whole argument for the
# metadata shape is that the dogfood corpus derivation reads ruleId + hash, so dropping the
# snippet keeps the channel. That is true ONLY if metadata mode keeps the READ and suppresses
# the WRITE. An implementation that skipped reading the file to save the write would hash the
# EMPTY line instead, key every metadata row differently from its full-mode twin, and break the
# exact channel the mode exists to preserve -- silently, because the writer swallows everything.
# Two assertions guard it: full-vs-metadata equality, AND equality against the hash independently
# computed from the real source line, so both modes hashing the same WRONG thing cannot pass.
#
# EVERY fixture lives under $TestDrive. The real dogfood logs are never read and never written.
#
# RED CONTROL: tests/fixtures/red-controls/lsp-common-capture.pre-000282.ps1 is the PRIOR
# implementation of the writer, verbatim from the merge base -- not a hand-written mutant. It is
# dot-sourced AFTER the shipped library by the same driver, so it overrides exactly one function
# and every helper resolves to the shipped copy. Run with the mode set to `metadata`, it must
# still EMIT `snippet` and the absolute path, because it has never heard of the variable.
#
# Run via tests/run-tests.ps1 (auto-discovered).

BeforeAll {
    $script:PluginRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsDir = Join-Path $script:PluginRoot 'scripts'
    $script:LibPath = Join-Path $script:ScriptsDir 'lib/lsp-common.ps1'
    $script:PriorWriter = Join-Path $PSScriptRoot 'fixtures/red-controls/lsp-common-capture.pre-000282.ps1'
    . $script:LibPath

    # The SAME host the suite runs under, so the Windows PowerShell 5.1 leg genuinely exercises
    # 5.1 rather than shelling out to pwsh 7 and testing the wrong host.
    $script:HostExe = (Get-Process -Id $PID).Path

    # SHA-256 of the RED-control fixture over its CONTENT with line endings normalized to LF --
    # never over the bytes git checked out. A .ps1 lands CRLF on a Windows checkout and LF on a
    # POSIX one, so Get-FileHash over the working tree measures the CHECKOUT and disagrees across
    # the matrix for a reason that says nothing about whether the fixture drifted (dispatch
    # 000279 hit exactly that, green on both POSIX legs and red on both Windows legs).
    $script:PriorWriterSha = 'e41c525486556376fb4e0a8cf7a695742df08b96e7d577ef77ea71b3c792ff73'

    # The one record every comparison run writes. Held here so the shipped run and the prior-
    # implementation run cannot differ in their INPUT -- the only thing that may differ between
    # them is the writer. The message deliberately carries a source-derived identifier, because
    # that is what the measurement in leg A found PSScriptAnalyzer actually emits.
    $script:ProbeLine = 2
    $script:ProbeRule = 'PSUseDeclaredVarsMoreThanAssignments'
    $script:ProbeMessage = "The variable 'customerRecordZZQ9' is assigned but never used."
    $script:ProbeSnippet = '    $customerRecordZZQ9 = ''acme-secret-value'''

    function New-ProbeSource {
        # The file the writer reads its snippet out of. Its DIRECTORY name is unique per call and
        # is what the no-absolute-path assertions look for: a basename-only row cannot contain it,
        # and a full row must, which is what keeps those assertions from passing vacuously.
        param([string] $Tag)
        $dir = Join-Path $TestDrive ('cm-' + $Tag + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $src = Join-Path $dir 'probe.ps1'
        $body = @(
            'function Test-Probe {'
            $script:ProbeSnippet
            '    Write-Output ''done'''
            '}'
        ) -join "`n"
        [System.IO.File]::WriteAllText($src, $body + "`n", (New-Object System.Text.UTF8Encoding($false)))
        return [pscustomobject]@{ Dir = $dir; Src = $src; DirLeaf = (Split-Path -Leaf $dir) }
    }

    function ConvertTo-PsLiteral {
        # A PowerShell single-quoted literal for an arbitrary string ('' escapes a quote).
        param([string] $Value)
        return ("'" + (([string]$Value) -replace "'", "''") + "'")
    }

    function New-CaptureDriver {
        # A BESPOKE driver per run, with every value EMBEDDED as a single-quoted literal, so the
        # child is launched with exactly one argument: its own path.
        #
        # Nothing is passed on the command line, and that is deliberate rather than tidy. The
        # probe message is "The variable 'customerRecordZZQ9' is assigned but never used." --
        # spaces and quotes. Start-Process flattens an -ArgumentList array by joining on spaces
        # without quoting, so that value would arrive as eight arguments and slide every
        # following switch one place along; an empty value would vanish outright. Embedding
        # sidesteps the whole class.
        #
        # -Prior is the ONLY difference between the shipped run and the prior-implementation run,
        # which is what makes the byte-identity and RED-control comparisons mean what they claim.
        param(
            [string] $SrcFile, [string] $LogPath, [string] $Mode,
            [string] $RuleId, [string] $Message, [int] $LineNum, [switch] $Prior
        )
        $path = Join-Path $TestDrive ('drv-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
        $priorLine = if ($Prior) { '. ' + (ConvertTo-PsLiteral -Value $script:PriorWriter) } else { '# shipped writer only' }
        $modeLine = if ($Mode -eq 'UNSET') {
            'Remove-Item Env:\POWERSHELL_LSP_CAPTURE_MODE -ErrorAction SilentlyContinue'
        } else {
            '$env:POWERSHELL_LSP_CAPTURE_MODE = ' + (ConvertTo-PsLiteral -Value $Mode)
        }
        $text = @(
            '$ErrorActionPreference = ''Stop'''
            '. ' + (ConvertTo-PsLiteral -Value $script:LibPath)
            $priorLine
            '$env:POWERSHELL_LSP_DOGFOOD_LOG = ' + (ConvertTo-PsLiteral -Value $LogPath)
            $modeLine
            '$rec = @{'
            '    line     = ' + [string]$LineNum
            '    col      = 5'
            '    ruleId   = ' + (ConvertTo-PsLiteral -Value $RuleId)
            '    source   = ''PSScriptAnalyzer'''
            '    severity = ''Warning'''
            '    message  = ' + (ConvertTo-PsLiteral -Value $Message)
            '}'
            'Add-DiagnosticCaptureEntries -File ' + (ConvertTo-PsLiteral -Value $SrcFile) + ' -Records @($rec)'
        ) -join "`n"
        [System.IO.File]::WriteAllText($path, $text + "`n", (New-Object System.Text.UTF8Encoding($false)))
        return $path
    }

    function Invoke-CaptureRun {
        # Run one capture in a FRESH child process and return the raw JSONL lines it wrote.
        # A child process is what keeps the ambient session's own POWERSHELL_LSP_* values out of
        # the measurement, and it is the only way to load the prior implementation without its
        # function definition colliding with the shipped one in this session.
        #
        # Start-Process with SEPARATELY redirected stdout and stderr, never `2>&1`: a native
        # child's merged stderr becomes ErrorRecords, and under Windows PowerShell 5.1 with
        # $ErrorActionPreference = 'Stop' in scope (Pester's default) that is a TERMINATING error,
        # so the harness would throw on output it exists to read -- and only the 5.1 leg would go
        # red (dispatch 000279, CI run 34002942820).
        param(
            [string] $SrcFile, [string] $LogPath, [string] $Mode,
            [string] $RuleId = $script:ProbeRule, [string] $Message = $script:ProbeMessage,
            [int] $LineNum = $script:ProbeLine, [switch] $Prior
        )
        $driver = New-CaptureDriver -SrcFile $SrcFile -LogPath $LogPath -Mode $Mode `
            -RuleId $RuleId -Message $Message -LineNum $LineNum -Prior:$Prior
        $stem = Join-Path $TestDrive ('io-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $outFile = $stem + '.out'
        $errFile = $stem + '.err'
        $proc = Start-Process -FilePath $script:HostExe `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $driver) `
            -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        # ReadAllText, not Get-Content -Raw: -Raw over an EMPTY file emits nothing, which is
        # AutomationNull, and [string] of AutomationNull is $null rather than '' -- so the
        # quiet-child assertion below would call .Trim() on null exactly when the child was
        # quiet, which is the case it exists to confirm. (The same hazard dogfood-reader.psm1's
        # 000258 empty-collection guard is written out for.)
        $stderr = ''
        if (Test-Path -LiteralPath $errFile -PathType Leaf) { $stderr = [System.IO.File]::ReadAllText($errFile) }
        $lines = @()
        if (Test-Path -LiteralPath $LogPath -PathType Leaf) {
            $lines = @([System.IO.File]::ReadAllLines($LogPath))
        }
        return [pscustomobject]@{ ExitCode = $proc.ExitCode; Stderr = $stderr; Lines = @($lines) }
    }

    function ConvertTo-TimestampFreeRow {
        # A capture row with ONLY its `ts` value replaced by a constant. Both writers stamp
        # Get-Date at call time, so two runs can never share a timestamp; everything else in the
        # row is compared as raw bytes, which is what "byte-identical" has to mean here.
        param([string] $Row)
        return ($Row -replace '^\{"ts":"[^"]*"', '{"ts":"FIXED"')
    }

    function New-LogPathIn {
        # A log path under a directory that does NOT exist yet, so `off` can be shown to create
        # neither the file nor its parent.
        param([string] $Tag)
        $dir = Join-Path $TestDrive ('log-' + $Tag + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        return [pscustomobject]@{ Dir = $dir; Log = (Join-Path $dir 'diagnostics.jsonl') }
    }
}

Describe 'Get-DiagnosticCaptureModeInfo -- the vocabulary, and what an unrecognized value does' {
    BeforeAll {
        $script:PrevMode = [Environment]::GetEnvironmentVariable('POWERSHELL_LSP_CAPTURE_MODE')
    }
    AfterAll {
        [Environment]::SetEnvironmentVariable('POWERSHELL_LSP_CAPTURE_MODE', $script:PrevMode)
    }

    It 'resolves <Raw> to <Resolved> with recognized=<Recognized>' -TestCases @(
        @{ Raw = 'full'; Resolved = 'full'; Recognized = $true }
        @{ Raw = 'metadata'; Resolved = 'metadata'; Recognized = $true }
        @{ Raw = 'off'; Resolved = 'off'; Recognized = $true }
        @{ Raw = 'Metadata'; Resolved = 'metadata'; Recognized = $true }
        @{ Raw = '  off  '; Resolved = 'off'; Recognized = $true }
        @{ Raw = ''; Resolved = 'full'; Recognized = $false }
        @{ Raw = '   '; Resolved = 'full'; Recognized = $false }
        @{ Raw = 'metadta'; Resolved = 'full'; Recognized = $false }
        @{ Raw = 'none'; Resolved = 'full'; Recognized = $false }
        @{ Raw = 'true'; Resolved = 'full'; Recognized = $false }
    ) {
        param($Raw, $Resolved, $Recognized)
        [Environment]::SetEnvironmentVariable('POWERSHELL_LSP_CAPTURE_MODE', $Raw)
        $info = Get-DiagnosticCaptureModeInfo
        $info.resolved | Should -BeExactly $Resolved
        $info.recognized | Should -Be $Recognized
        # `raw` is echoed verbatim -- never trimmed, never lowercased -- so a fleet reader sees
        # the typo it actually deployed.
        $info.raw | Should -BeExactly $Raw
        (Get-DiagnosticCaptureMode) | Should -BeExactly $Resolved
    }

    It 'reports raw as the empty string, never $null, when the variable is unset' {
        # A JSON envelope field that is sometimes '' and sometimes null is two shapes, not one.
        [Environment]::SetEnvironmentVariable('POWERSHELL_LSP_CAPTURE_MODE', $null)
        $info = Get-DiagnosticCaptureModeInfo
        $info.raw | Should -BeExactly ''
        $info.raw | Should -Not -Be $null
        $info.resolved | Should -BeExactly 'full'
        $info.recognized | Should -Be $false
    }

    It 'AN UNRECOGNIZED VALUE STILL CAPTURES -- the mode logic never gates the channel' {
        # T6.1 is ACCEPTED-WITH-RECORD and Get-CaptureLogRotateBytes states the constraint for
        # this whole family: nothing here may become a gate on the capture channel itself. A typo
        # in a GPO-deployed variable must not silently stop capture.
        $p = New-ProbeSource -Tag 'invalid'
        $lp = New-LogPathIn -Tag 'invalid'
        New-Item -ItemType Directory -Force -Path $lp.Dir | Out-Null
        $run = Invoke-CaptureRun -SrcFile $p.Src -LogPath $lp.Log -Mode 'metadta'
        $run.Lines.Count | Should -Be 1 -Because 'an unrecognized value falls back to full, it does not disable capture'
        $run.Lines[0] | Should -Match '"snippet"'
    }
}

Describe 'full mode is BYTE-IDENTICAL to the prior implementation for the same finding' {
    It 'writes the same row as the merge-base writer, modulo the timestamp' {
        $p = New-ProbeSource -Tag 'ident'
        $lpNew = New-LogPathIn -Tag 'ident-new'
        $lpOld = New-LogPathIn -Tag 'ident-old'
        New-Item -ItemType Directory -Force -Path $lpNew.Dir | Out-Null
        New-Item -ItemType Directory -Force -Path $lpOld.Dir | Out-Null

        # Same driver, same source file, same record. -Prior is the ONLY difference.
        $shipped = Invoke-CaptureRun -SrcFile $p.Src -LogPath $lpNew.Log -Mode 'full'
        $prior = Invoke-CaptureRun -SrcFile $p.Src -LogPath $lpOld.Log -Mode 'full' -Prior

        $shipped.Lines.Count | Should -Be 1
        $prior.Lines.Count | Should -Be 1
        (ConvertTo-TimestampFreeRow -Row $shipped.Lines[0]) |
            Should -BeExactly (ConvertTo-TimestampFreeRow -Row $prior.Lines[0])
    }

    It 'writes the same row as the merge-base writer when the variable is UNSET' {
        # Unset is the shipped default and the case every existing install is in, so it gets its
        # own assertion rather than resting on `full` being spelled out.
        $p = New-ProbeSource -Tag 'unset'
        $lpNew = New-LogPathIn -Tag 'unset-new'
        $lpOld = New-LogPathIn -Tag 'unset-old'
        New-Item -ItemType Directory -Force -Path $lpNew.Dir | Out-Null
        New-Item -ItemType Directory -Force -Path $lpOld.Dir | Out-Null

        $shipped = Invoke-CaptureRun -SrcFile $p.Src -LogPath $lpNew.Log -Mode 'UNSET'
        $prior = Invoke-CaptureRun -SrcFile $p.Src -LogPath $lpOld.Log -Mode 'UNSET' -Prior

        $shipped.Lines.Count | Should -Be 1
        (ConvertTo-TimestampFreeRow -Row $shipped.Lines[0]) |
            Should -BeExactly (ConvertTo-TimestampFreeRow -Row $prior.Lines[0])
    }

    It 'the timestamp normalizer is not what makes those rows match' {
        # Non-vacuity for the comparison itself: two rows differing anywhere OTHER than `ts` must
        # still compare unequal after normalization.
        $a = '{"ts":"2026-01-01T00:00:00.0000000-05:00","file":"a.ps1","snippet":"x"}'
        $b = '{"ts":"2026-09-06T11:22:33.4444444-04:00","file":"a.ps1","snippet":"y"}'
        (ConvertTo-TimestampFreeRow -Row $a) | Should -Not -BeExactly (ConvertTo-TimestampFreeRow -Row $b)
    }
}

Describe 'metadata mode writes no source text and no absolute path' {
    BeforeAll {
        $script:MdProbe = New-ProbeSource -Tag 'md'
        $script:MdLog = New-LogPathIn -Tag 'md'
        New-Item -ItemType Directory -Force -Path $script:MdLog.Dir | Out-Null
        $script:MdRun = Invoke-CaptureRun -SrcFile $script:MdProbe.Src -LogPath $script:MdLog.Log -Mode 'metadata'
        $script:MdRow = if ($script:MdRun.Lines.Count -gt 0) { $script:MdRun.Lines[0] } else { '' }

        $script:FullProbe = New-ProbeSource -Tag 'mdfull'
        $script:FullLog = New-LogPathIn -Tag 'mdfull'
        New-Item -ItemType Directory -Force -Path $script:FullLog.Dir | Out-Null
        $script:FullRun = Invoke-CaptureRun -SrcFile $script:FullProbe.Src -LogPath $script:FullLog.Log -Mode 'full'
        $script:FullRow = if ($script:FullRun.Lines.Count -gt 0) { $script:FullRun.Lines[0] } else { '' }
    }

    It 'still writes one row (metadata suppresses fields, not capture)' {
        $script:MdRun.Lines.Count | Should -Be 1
    }

    It 'carries NO snippet key -- asserted over the RAW JSONL, not a parsed object' {
        # Over the raw text on purpose: ConvertFrom-Json cannot tell "key absent" from "key
        # present and empty" without a second check, and absent is the property under test.
        $script:MdRow | Should -Not -Match '"snippet"'
    }

    It 'carries NO message key -- PSSA quotes source identifiers into it' {
        $script:MdRow | Should -Not -Match '"message"'
        $script:MdRow | Should -Not -Match 'customerRecordZZQ9'
    }

    It 'carries NO absolute path -- the file is a basename' {
        # The probe's parent directory has a unique name, so its absence is a real statement
        # about this row and not a coincidence of the temp path.
        $script:MdRow | Should -Not -Match ([regex]::Escape($script:MdProbe.DirLeaf))
        ($script:MdRow | ConvertFrom-Json).file | Should -BeExactly 'probe.ps1'
    }

    It 'the absent-path assertion is NOT vacuous -- a full row DOES carry that directory' {
        # If the directory name could never appear, the assertion above would pass on an empty
        # file. It appears in full mode, so the metadata assertion is measuring the mode.
        $script:FullRow | Should -Match ([regex]::Escape($script:FullProbe.DirLeaf))
        $script:FullRow | Should -Match '"snippet"'
        $script:FullRow | Should -Match '"message"'
    }

    It 'keeps every field the corpus derivation reads, in the shipped order' {
        $o = $script:MdRow | ConvertFrom-Json
        foreach ($f in @('ts', 'file', 'line', 'col', 'ruleId', 'source', 'severity', 'hash', 'verdict')) {
            ($o.PSObject.Properties.Name -contains $f) | Should -BeTrue -Because "metadata must keep '$f'"
        }
        # Removal from an [ordered] dictionary preserves the order of what remains, so a metadata
        # row is the full row minus two keys -- never a re-shaped object.
        (@($o.PSObject.Properties.Name) -join ',') |
            Should -BeExactly 'ts,file,line,col,ruleId,source,severity,hash,verdict'
        $o.line | Should -Be $script:ProbeLine
        $o.ruleId | Should -BeExactly $script:ProbeRule
        $o.verdict | Should -BeExactly ''
    }
}

Describe 'HASH EQUALITY -- the read is kept in metadata mode, only the write is suppressed' {
    It 'the same finding hashes IDENTICALLY under full and under metadata' {
        # THE ASSERTION THIS WHOLE SLICE RESTS ON. The docket's argument for the metadata shape is
        # that the corpus derivation reads ruleId + hash, so dropping the snippet keeps the
        # channel. That holds only while the two modes agree on the hash.
        $p = New-ProbeSource -Tag 'hash'
        $lpF = New-LogPathIn -Tag 'hash-full'
        $lpM = New-LogPathIn -Tag 'hash-meta'
        New-Item -ItemType Directory -Force -Path $lpF.Dir | Out-Null
        New-Item -ItemType Directory -Force -Path $lpM.Dir | Out-Null

        $full = Invoke-CaptureRun -SrcFile $p.Src -LogPath $lpF.Log -Mode 'full'
        $meta = Invoke-CaptureRun -SrcFile $p.Src -LogPath $lpM.Log -Mode 'metadata'

        $fullHash = ($full.Lines[0] | ConvertFrom-Json).hash
        $metaHash = ($meta.Lines[0] | ConvertFrom-Json).hash
        $fullHash | Should -Match '^[0-9a-f]{64}$'
        $metaHash | Should -BeExactly $fullHash
    }

    It 'and that shared hash is the hash OF THE REAL SOURCE LINE, not of an empty one' {
        # Equality alone would still pass if BOTH modes hashed the wrong thing. This pins the
        # value to the offending line the file actually holds, which is what proves the read
        # survived. An implementation that skipped the read would hash '' and fail here.
        $p = New-ProbeSource -Tag 'hashreal'
        $lpM = New-LogPathIn -Tag 'hashreal-meta'
        New-Item -ItemType Directory -Force -Path $lpM.Dir | Out-Null
        $meta = Invoke-CaptureRun -SrcFile $p.Src -LogPath $lpM.Log -Mode 'metadata'

        $expected = Get-DiagnosticShapeHash -RuleId $script:ProbeRule -OffendingLine $script:ProbeSnippet
        $emptyLine = Get-DiagnosticShapeHash -RuleId $script:ProbeRule -OffendingLine ''
        $expected | Should -Not -BeExactly $emptyLine -Because 'the two must differ or this test proves nothing'

        ($meta.Lines[0] | ConvertFrom-Json).hash | Should -BeExactly $expected
    }
}

Describe 'off mode writes nothing and creates nothing' {
    It 'creates neither the log file nor its parent directory' {
        $p = New-ProbeSource -Tag 'off'
        $lp = New-LogPathIn -Tag 'off'
        # Deliberately NOT created: the mode must return before New-ContainedDirectory runs.
        (Test-Path -LiteralPath $lp.Dir) | Should -BeFalse -Because 'the fixture must start absent'

        $run = Invoke-CaptureRun -SrcFile $p.Src -LogPath $lp.Log -Mode 'off'

        (Test-Path -LiteralPath $lp.Log) | Should -BeFalse
        (Test-Path -LiteralPath $lp.Dir) | Should -BeFalse -Because 'off must not create the dogfood directory either'
    }

    It 'is still fail-safe -- the child exits clean and says nothing' {
        $p = New-ProbeSource -Tag 'offsafe'
        $lp = New-LogPathIn -Tag 'offsafe'
        $run = Invoke-CaptureRun -SrcFile $p.Src -LogPath $lp.Log -Mode 'off'
        $run.ExitCode | Should -Be 0
        $run.Stderr.Trim() | Should -BeExactly ''
    }

    It 'the directory check is NOT vacuous -- full mode DOES create it' {
        $p = New-ProbeSource -Tag 'offctl'
        $lp = New-LogPathIn -Tag 'offctl'
        (Test-Path -LiteralPath $lp.Dir) | Should -BeFalse
        $run = Invoke-CaptureRun -SrcFile $p.Src -LogPath $lp.Log -Mode 'full'
        (Test-Path -LiteralPath $lp.Dir) | Should -BeTrue
        (Test-Path -LiteralPath $lp.Log) | Should -BeTrue
    }
}

Describe 'the shipped readers handle metadata rows and MIXED logs' {
    BeforeAll {
        Import-Module (Join-Path $script:ScriptsDir 'lib/dogfood-reader.psm1') -Force

        # A MIXED log is the upgrade-in-place case: rows written before the mode existed, then
        # rows written after an admin set it. The same finding must remain ONE shape across the
        # seam, which is only true because the hash is mode-independent.
        $p = New-ProbeSource -Tag 'mixed'
        $script:MixLog = New-LogPathIn -Tag 'mixed'
        New-Item -ItemType Directory -Force -Path $script:MixLog.Dir | Out-Null
        [void](Invoke-CaptureRun -SrcFile $p.Src -LogPath $script:MixLog.Log -Mode 'full')
        [void](Invoke-CaptureRun -SrcFile $p.Src -LogPath $script:MixLog.Log -Mode 'full')
        [void](Invoke-CaptureRun -SrcFile $p.Src -LogPath $script:MixLog.Log -Mode 'metadata')
        [void](Invoke-CaptureRun -SrcFile $p.Src -LogPath $script:MixLog.Log -Mode 'metadata')

        $script:MetaOnlyLog = New-LogPathIn -Tag 'metaonly'
        New-Item -ItemType Directory -Force -Path $script:MetaOnlyLog.Dir | Out-Null
        [void](Invoke-CaptureRun -SrcFile $p.Src -LogPath $script:MetaOnlyLog.Log -Mode 'metadata')
        [void](Invoke-CaptureRun -SrcFile $p.Src -LogPath $script:MetaOnlyLog.Log -Mode 'metadata' `
                -RuleId 'PSAvoidUsingWriteHost' -LineNum 3)

        # The same two findings in FULL mode, so the placeholder assertion above has a control.
        $script:FullListingLog = New-LogPathIn -Tag 'fulllisting'
        New-Item -ItemType Directory -Force -Path $script:FullListingLog.Dir | Out-Null
        [void](Invoke-CaptureRun -SrcFile $p.Src -LogPath $script:FullListingLog.Log -Mode 'full')
        [void](Invoke-CaptureRun -SrcFile $p.Src -LogPath $script:FullListingLog.Log -Mode 'full' `
                -RuleId 'PSAvoidUsingWriteHost' -LineNum 3)

        # Dot-sourced HERE, not inside an It: a dot-source inside an It scopes the functions to
        # that It alone and the next one would not see them.
        . (Join-Path $script:ScriptsDir 'rule-efficacy-ledger.ps1')
    }

    It 'Read-DogfoodLog reads a metadata-only log without error' {
        $recs = @(Read-DogfoodLog -LogPath $script:MetaOnlyLog.Log)
        $recs.Count | Should -Be 2
    }

    It 'Read-DogfoodLog reads a MIXED log and sees every row' {
        $recs = @(Read-DogfoodLog -LogPath $script:MixLog.Log)
        $recs.Count | Should -Be 4
    }

    It 'the ledger groups a mixed log into ONE shape -- full and metadata rows key alike' {
        # The statement the whole slice is for: turning the mode on mid-life does not fork the
        # corpus. Four occurrences of one finding, two of each shape, remain one distinct shape.
        $recs = @(Read-DogfoodLog -LogPath $script:MixLog.Log)
        $occ = @(ConvertTo-LedgerOccurrences -Records $recs)
        $occ.Count | Should -Be 4
        $distinct = @($occ | Select-Object -ExpandProperty hash -Unique)
        $distinct.Count | Should -Be 1 -Because 'the same finding must key identically in both row shapes'
        @($occ | Select-Object -ExpandProperty ruleId -Unique).Count | Should -Be 1
    }

    It 'the ledger does not fall back to recomputing a hash it was given' {
        # ConvertTo-LedgerOccurrences recomputes the hash from (ruleId + snippet) when the row
        # carries none. A metadata row has no snippet, so a row that reached that fallback would
        # key on the EMPTY line. It must not: the row carries its hash, and the hash is used.
        $recs = @(Read-DogfoodLog -LogPath $script:MetaOnlyLog.Log)
        $occ = @(ConvertTo-LedgerOccurrences -Records $recs)
        $emptyLineHash = Get-DiagnosticShapeHash -RuleId $script:ProbeRule -OffendingLine ''
        @($occ | Where-Object { $_.hash -eq $emptyLineHash }).Count | Should -Be 0
        @($occ)[0].hash | Should -BeExactly (Get-DiagnosticShapeHash -RuleId $script:ProbeRule -OffendingLine $script:ProbeSnippet)
    }

    It 'the annotation render degrades to the SHIPPED placeholder, and never throws' {
        # review-dogfood.ps1's prompt reaches the snippet through Show-DogfoodListing ->
        # Get-DogfoodShapes -> Format-DogfoodShape (the last two are private to the module, so
        # the exported entry point is both the reachable seam and the faithful one). It already
        # renders '(no snippet)' for an empty snippet, so a metadata row degrades to a STATED
        # placeholder -- no new placeholder had to be invented, and nothing throws.
        $ann = Join-Path $script:MetaOnlyLog.Dir 'annotations.jsonl'
        $text = ''
        { $script:MdListing = Show-DogfoodListing -LogPath $script:MetaOnlyLog.Log -AnnotationsPath $ann -All } |
            Should -Not -Throw
        $text = [string]$script:MdListing
        $text | Should -Match '\(no snippet\)'
        $text | Should -Not -Match 'customerRecordZZQ9'
        # Two distinct findings were written, so two shapes must have collapsed out of them.
        $text | Should -Match 'all shapes \(2\)'
    }

    It 'the placeholder assertion is NOT vacuous -- a full-row listing shows the real line' {
        $ann = Join-Path $script:FullListingLog.Dir 'annotations.jsonl'
        $text = [string](Show-DogfoodListing -LogPath $script:FullListingLog.Log -AnnotationsPath $ann -All)
        $text | Should -Not -Match '\(no snippet\)'
        $text | Should -Match 'customerRecordZZQ9'
    }

    It 'a basename-only file falls to the source classifier''s own conservative default' {
        # Get-DogfoodSourceBucket documents 'other-genuine' as the answer for an ambiguous path
        # and refuses to guess a path INTO canonical. A basename is ambiguous by construction, so
        # the source split degrades exactly the way that function already says it should.
        (Get-DogfoodSourceBucket -File 'probe.ps1') | Should -BeExactly 'other-genuine'
    }
}

Describe 'RED CONTROL -- the prior implementation EMITS the snippet under metadata' {
    It 'the fixture is the prior implementation, pinned by LF-normalized content' {
        $raw = [System.IO.File]::ReadAllText($script:PriorWriter)
        $lf = $raw -replace "`r`n", "`n"
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($lf)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $h = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
        (([System.BitConverter]::ToString($h)) -replace '-', '').ToLowerInvariant() |
            Should -BeExactly $script:PriorWriterSha
    }

    It 'writes snippet AND the absolute path even with the mode set to metadata' {
        # This is what makes the metadata assertions mean the MODE suppressed those fields. The
        # prior writer has never heard of POWERSHELL_LSP_CAPTURE_MODE, so with the variable set
        # it must behave exactly as it always did.
        $p = New-ProbeSource -Tag 'red'
        $lp = New-LogPathIn -Tag 'red'
        New-Item -ItemType Directory -Force -Path $lp.Dir | Out-Null

        $run = Invoke-CaptureRun -SrcFile $p.Src -LogPath $lp.Log -Mode 'metadata' -Prior

        $run.Lines.Count | Should -Be 1 -Because 'the prior writer must have run at all'
        $run.Lines[0] | Should -Match '"snippet"'
        $run.Lines[0] | Should -Match '"message"'
        $run.Lines[0] | Should -Match 'customerRecordZZQ9'
        $run.Lines[0] | Should -Match ([regex]::Escape($p.DirLeaf))
    }

    It 'and it does not honour off either -- it writes when the shipped writer would not' {
        $p = New-ProbeSource -Tag 'redoff'
        $lp = New-LogPathIn -Tag 'redoff'
        New-Item -ItemType Directory -Force -Path $lp.Dir | Out-Null
        $run = Invoke-CaptureRun -SrcFile $p.Src -LogPath $lp.Log -Mode 'off' -Prior
        $run.Lines.Count | Should -Be 1
    }
}
