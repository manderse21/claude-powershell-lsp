#Requires -Version 5.1

# PowerShellLsp.ControlMapClaims.Tests.ps1 -- THE CONTROL-MAP CLAIMS GUARD (dispatch 000285, R4).
#
# docs/control-map.html ships as a RELEASE ASSET and had no automated guard of any kind. This file
# is the machinery; tests/control-map-claims.psd1 carries the claims and the whole rationale. Read
# that first -- including why this is a sibling of doc-claims.psd1 rather than rows inside it, and
# why a date comparison is not a currency guard.
#
# FOUR THINGS THIS FILE ASSERTS, in ascending order of how easily they are faked:
#   1. Every registered claim holds against its derived source.        (the guard)
#   2. The guard FAILS on REV 2 restored from git history.             (the RED control)
#   3. Each derivation SOURCE actually matched something.              (the VACUITY control)
#   4. The map is reachable and non-trivial at all.                    (the PAYLOAD FLOOR)
#
# (2) is the control the charter asks for by name and it is not a mutant: rev 2 is the real
# published revision, restored from `docs/control-map.html` at commit 66b9522, and it must fail on
# BOTH claims that were false at the v1.34.0 release -- T5.1 described as an unreleased security fix
# when its Windows arm had shipped in v1.33.0, and an SLO line reading "all six met" against an open
# T3 post-release miss. A guard that has never been watched fail is a guard nobody has tested.
#
# (3) matters more than it looks. Every ForbiddenWhile row is armed by a SourcePattern; if that
# pattern stops matching -- the source sentence is reworded, the file is renamed -- the row silently
# stops forbidding anything and the suite still reads green. So the sources are asserted to match,
# separately from the claims.
#
# ASCII-only (PS 5.1 em-dash trap).

# ---------------------------------------------------------------------------
# DISCOVERY PHASE. The registry is read here so each claim becomes its own It,
# named in the output, and reaches the run phase through -ForEach. A discovery-
# time $script: variable read inside an It body is $null.
# ---------------------------------------------------------------------------
$CmRegistryPath = Join-Path $PSScriptRoot 'control-map-claims.psd1'
$CmRegistry     = Import-PowerShellDataFile -LiteralPath $CmRegistryPath
# HASHTABLES, not [pscustomobject]. Pester's -ForEach binds a HASHTABLE case's keys as
# variables AND expands them in the It title template; a pscustomobject case reaches the body
# only as $_ and leaves '<Name>' unexpanded, so every claim rendered as an unnamed blank line in
# the output. An unnamed failing test is a failing test nobody can act on.
$CmClaimCases   = @(
    foreach ($c in @($CmRegistry.Claims)) {
        @{
            Name          = [string]$c.Name
            Kind          = [string]$c.Kind
            Phrase        = [string]$c.Phrase
            Pattern       = [string]$c.Pattern
            SourcePath    = [string]$c.SourcePath
            SourcePattern = [string]$c.SourcePattern
        }
    }
)
$CmSourceCases = @($CmClaimCases | Where-Object { $_.Kind -eq 'ForbiddenWhile' })

Describe 'Control-map claims -- every claim the map makes, against its derived source (dispatch 000285)' {

    BeforeAll {
        $script:RepoRoot = Split-Path -Parent $PSScriptRoot
        $script:Registry = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'control-map-claims.psd1')
        $script:MapPath  = Join-Path $script:RepoRoot ([string]$script:Registry.Document)

        function script:ConvertTo-CmText {
            # Normalize hand-authored HTML to comparable prose. The map's sentences wrap mid-claim
            # and its separators are entities, so a raw substring search reads as ABSENCE on text
            # that plainly contains the claim -- the failure mode this helper exists to remove.
            param([string] $Html)
            $t = $Html -replace '(?s)<script.*?</script>', ' '
            $t = $t -replace '(?s)<style.*?</style>', ' '
            $t = $t -replace '<[^>]*>', ' '
            $t = $t -replace '&middot;', '.'
            $t = $t -replace '&#160;', ' '
            $t = $t -replace '&nbsp;', ' '
            $t = $t -replace '&amp;', '&'
            $t = $t -replace '&quot;', '"'
            $t = $t -replace '&#8594;', '->'
            return ($t -replace '\s+', ' ')
        }

        function script:Get-CmNewestReleasedVersion {
            # The newest RELEASED version, from CHANGELOG.md -- the highest `## [X.Y.Z]` section
            # that is not [Unreleased]. Deliberately NOT plugin.json: that moves at the version
            # bump, BEFORE the release exists, and would bless an in-prep claim one commit early.
            param([string] $Root)
            $cl = Get-Content -LiteralPath (Join-Path $Root 'CHANGELOG.md') -Raw
            $vs = @([regex]::Matches($cl, '(?m)^##\s*\[(\d+)\.(\d+)\.(\d+)\]') |
                ForEach-Object { [version]("{0}.{1}.{2}" -f $_.Groups[1].Value, $_.Groups[2].Value, $_.Groups[3].Value) })
            if ($vs.Count -eq 0) { throw 'CHANGELOG.md yielded no released version sections' }
            return (@($vs | Sort-Object)[-1])
        }

        function script:Test-CmReleasedInChangelog {
            param([string] $Root, [string] $Version)
            $cl = Get-Content -LiteralPath (Join-Path $Root 'CHANGELOG.md') -Raw
            return ($cl -match ('(?m)^##\s*\[' + [regex]::Escape($Version) + '\]'))
        }

        function script:Invoke-CmClaim {
            # Evaluate ONE registry row against a given map text. Returns @{ Ok; Detail }.
            # Takes the map text as an argument rather than reading it, so the RED control can
            # feed it rev 2 through the identical code path the live claim uses. A control that
            # routed around the evaluator would prove nothing about the evaluator.
            param([hashtable] $Claim, [string] $MapText, [string] $Root)
            switch ([string]$Claim.Kind) {
                'ForbiddenWhile' {
                    $srcFull = Join-Path $Root ([string]$Claim.SourcePath)
                    if (-not (Test-Path -LiteralPath $srcFull -PathType Leaf)) {
                        return @{ Ok = $false; Detail = "source missing: $($Claim.SourcePath)" }
                    }
                    $src = Get-Content -LiteralPath $srcFull -Raw
                    $armed = ($src -match [string]$Claim.SourcePattern)
                    if (-not $armed) { return @{ Ok = $true; Detail = 'not armed (source condition absent)' } }
                    $present = ($MapText -match [regex]::Escape([string]$Claim.Phrase))
                    if ($present) {
                        return @{ Ok = $false; Detail = "the map still says '$($Claim.Phrase)' while $($Claim.SourcePath) refutes it" }
                    }
                    return @{ Ok = $true; Detail = "armed by $($Claim.SourcePath); phrase absent" }
                }
                'ForbiddenIfReleased' {
                    $ms = [regex]::Matches($MapText, [string]$Claim.Pattern)
                    $bad = @()
                    foreach ($m in $ms) {
                        $v = [string]$m.Groups[1].Value
                        if (script:Test-CmReleasedInChangelog -Root $Root -Version $v) { $bad += $v }
                    }
                    if ($bad.Count -gt 0) {
                        return @{ Ok = $false; Detail = ("in-prep claimed for RELEASED version(s): " + (@($bad | Sort-Object -Unique) -join ', ')) }
                    }
                    return @{ Ok = $true; Detail = ("in-prep mentions: " + $ms.Count) }
                }
                'EqualsNewestRelease' {
                    $m = [regex]::Match($MapText, [string]$Claim.Pattern)
                    if (-not $m.Success) { return @{ Ok = $false; Detail = 'the map states no released version at all' } }
                    $claimed = [version]$m.Groups[1].Value
                    $newest  = script:Get-CmNewestReleasedVersion -Root $Root
                    if ($claimed -ne $newest) {
                        return @{ Ok = $false; Detail = "map says released $claimed; CHANGELOG's newest release is $newest" }
                    }
                    return @{ Ok = $true; Detail = "released $claimed" }
                }
            }
            throw ("unknown control-map claim kind '{0}' -- an unknown kind must THROW, never pass" -f $Claim.Kind)
        }
    }

    Context 'the map itself' {
        It 'PAYLOAD FLOOR: the registered document exists and is substantial' {
            Test-Path -LiteralPath $script:MapPath -PathType Leaf | Should -BeTrue
            $raw = Get-Content -LiteralPath $script:MapPath -Raw
            $raw.Length | Should -BeGreaterThan 5000
            (script:ConvertTo-CmText -Html $raw).Length | Should -BeGreaterThan 2000
        }

        It 'the registry declares at least one claim and names what it cannot guard' {
            @($script:Registry.Claims).Count | Should -BeGreaterOrEqual 4
            @($script:Registry.Unguardable).Count | Should -BeGreaterOrEqual 1
        }
    }

    Context 'each registered claim holds' {
        It '<Name>' -ForEach $CmClaimCases {
            # $_ rather than the auto-bound property variables: Pester's -ForEach exposes the
            # current case as $_ reliably, while per-property binding depends on the case shape
            # and silently yields EMPTY strings when it does not apply -- which read here as
            # "unknown claim kind ''" over four correctly-loaded rows.
            $claim = @{
                Kind = $Kind; Phrase = $Phrase; Pattern = $Pattern
                SourcePath = $SourcePath; SourcePattern = $SourcePattern
            }
            $text = script:ConvertTo-CmText -Html (Get-Content -LiteralPath $script:MapPath -Raw)
            $r = script:Invoke-CmClaim -Claim $claim -MapText $text -Root $script:RepoRoot
            $r.Ok | Should -BeTrue -Because $r.Detail
        }
    }

    Context 'VACUITY CONTROL -- every ForbiddenWhile row is actually armed' {
        It 'the source condition for "<Name>" matches its source file' -ForEach $CmSourceCases {
            # A ForbiddenWhile row forbids NOTHING when its SourcePattern stops matching. Reword
            # the source sentence and the row silently disarms while the suite stays green. This
            # asserts the arming separately from the claim.
            $full = Join-Path $script:RepoRoot $SourcePath
            Test-Path -LiteralPath $full -PathType Leaf | Should -BeTrue -Because "source $SourcePath must exist"
            $src = Get-Content -LiteralPath $full -Raw
            $src -match $SourcePattern | Should -BeTrue -Because "SourcePattern for '$Name' matched nothing in $SourcePath, so the row forbids nothing"
        }
    }

    Context 'RED CONTROL -- rev 2, restored from git history, must FAIL' {
        BeforeAll {
            # REV 2 IS A COMMITTED FIXTURE, NOT A `git show` (dispatch 000285, after CI).
            #
            # It was first read straight from history -- `git show 66b9522:docs/control-map.html`
            # -- and that is exactly what the charter asks for. CI proved it unportable: the
            # workflow checks out SHALLOW, so commit 66b9522 is not present on the runner,
            # `git show` returned nothing, and the RED control then "passed" against an EMPTY
            # document, because a document with no text trivially satisfies every
            # forbidden-phrase assertion. The retrievability guard below is what caught it --
            # ubuntu-pwsh and macos-pwsh failed with "got 0" before the two controls could report
            # a vacuous green.
            #
            # A RED CONTROL MUST BE HERMETIC. Reading it from history makes the control's
            # existence depend on clone depth, on history never being rewritten, and on the
            # commit never being GC'd -- three ways for a control to disappear silently. The
            # fixture is the same bytes, committed once, and its PROVENANCE is asserted
            # separately below wherever the history is actually available.
            $script:Rev2Path = Join-Path $PSScriptRoot 'fixtures/control-map-rev2.html'
            $script:Rev2Raw  = ''
            if (Test-Path -LiteralPath $script:Rev2Path -PathType Leaf) {
                $script:Rev2Raw = Get-Content -LiteralPath $script:Rev2Path -Raw
            }
            $script:Rev2Commit = '66b9522433a102b103421dcac40b7aea26a8491e'
        }

        It 'rev 2 is retrievable and is a different document from the tip' {
            # If this ever fails the two assertions below become vacuous, so it is asserted first
            # and separately rather than folded into them. This is not hypothetical: it is the
            # assertion that caught the shallow-clone defect described above.
            $script:Rev2Raw.Length | Should -BeGreaterThan 5000 -Because 'the rev 2 fixture must be present and whole'
            $script:Rev2Raw | Should -Not -Be (Get-Content -LiteralPath $script:MapPath -Raw)
        }

        It 'the rev 2 fixture is byte-identical to the commit it claims to be' {
            # PROVENANCE. A fixture is only a faithful RED control while it still matches the
            # revision it names, and nothing else would notice it drifting. This runs wherever
            # the history is present -- which is every developer clone and every full checkout --
            # and reports honestly rather than passing when it is not. It is deliberately NOT
            # folded into the control above: the control must run everywhere, and this cannot.
            $have = $false
            try {
                & git -C $script:RepoRoot cat-file -e ($script:Rev2Commit + '^{commit}') 2>$null
                $have = ($LASTEXITCODE -eq 0)
            } catch { $have = $false }

            if (-not $have) {
                Set-ItResult -Skipped -Because 'this checkout is shallow, so commit 66b9522 is absent and provenance cannot be checked here; the RED control itself still ran against the fixture'
                return
            }
            $fromGit = (& git -C $script:RepoRoot show ($script:Rev2Commit + ':docs/control-map.html') | Out-String)
            $fromGit.Length | Should -BeGreaterThan 5000
            ($script:Rev2Raw -replace "`r`n", "`n").TrimEnd() |
                Should -Be (($fromGit -replace "`r`n", "`n").TrimEnd()) -Because 'the fixture must still BE rev 2'
        }

        It 'rev 2 FAILS the T5.1 claim -- it called a shipped security fix unreleased' {
            $claim = @{
                Kind = 'ForbiddenWhile'; Phrase = 'T5.1 fixed-unreleased'
                SourcePath = 'CHANGELOG.md'; SourcePattern = '(?s)##\s*\[1\.33\.0\].*?pipe'
            }
            $text = script:ConvertTo-CmText -Html $script:Rev2Raw
            $r = script:Invoke-CmClaim -Claim $claim -MapText $text -Root $script:RepoRoot
            $r.Ok | Should -BeFalse -Because 'rev 2 carried a FALSE claim and the guard must say so'
        }

        It 'rev 2 FAILS the SLO claim -- "all six met" against an open T3 miss' {
            $claim = @{
                Kind = 'ForbiddenWhile'; Phrase = 'ADOPTED 08-21, all six met'
                SourcePath = 'docs/roadmap-ii/PROGRAM.md'
                SourcePattern = 'STANDING AT v1\.33\.0: 5 of 6 MET, T3 MISSED'
            }
            $text = script:ConvertTo-CmText -Html $script:Rev2Raw
            $r = script:Invoke-CmClaim -Claim $claim -MapText $text -Root $script:RepoRoot
            $r.Ok | Should -BeFalse -Because 'rev 2 carried a claim that had decayed from true to misleading'
        }

        It 'the CURRENT map passes both of those same two claims (the other direction)' {
            # Without this, "rev 2 fails" would be satisfied by a guard that fails on everything.
            $text = script:ConvertTo-CmText -Html (Get-Content -LiteralPath $script:MapPath -Raw)
            foreach ($c in @(
                @{ Kind = 'ForbiddenWhile'; Phrase = 'T5.1 fixed-unreleased'
                   SourcePath = 'CHANGELOG.md'; SourcePattern = '(?s)##\s*\[1\.33\.0\].*?pipe' },
                @{ Kind = 'ForbiddenWhile'; Phrase = 'ADOPTED 08-21, all six met'
                   SourcePath = 'docs/roadmap-ii/PROGRAM.md'
                   SourcePattern = 'STANDING AT v1\.33\.0: 5 of 6 MET, T3 MISSED' }
            )) {
                (script:Invoke-CmClaim -Claim $c -MapText $text -Root $script:RepoRoot).Ok |
                    Should -BeTrue -Because "the tip must pass '$($c.Phrase)'"
            }
        }
    }

    Context 'the evaluator refuses what it does not understand' {
        It 'an unknown derivation kind THROWS rather than passing' {
            # An unknown kind returning $true would let a typo'd row read as a satisfied claim,
            # which is the exact failure a registry exists to remove.
            { script:Invoke-CmClaim -Claim @{ Kind = 'NoSuchKind' } -MapText 'x' -Root $script:RepoRoot } |
                Should -Throw
        }
    }
}
