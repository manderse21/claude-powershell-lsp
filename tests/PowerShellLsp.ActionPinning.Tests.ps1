#Requires -Version 5.1

# Immutable-action pinning gate (dispatch 000240).
#
# ID CORRECTED. This block shipped in PR #165 (commit 3aeb415) under dispatch 000240, whose
# outbox lists this exact file -- but it was annotated "000241", an id that did not exist: the
# hub counter still stood at 000240, and 000241 was later minted for unrelated work (the
# lspServers userConfig-defaults defect). Corrected here so the annotation names the dispatch
# that actually carried it.
#
# WHAT THIS ENFORCES. Every EXTERNAL GitHub Action this repository executes must be
# referenced by a full 40-character upstream commit SHA, with the resolved release in a
# trailing comment on the SAME line. A movable ref -- @v4, @main, @master, @latest, a
# branch name, or an abbreviated SHA -- is a supply-chain hole: the upstream owner can
# retag it and change what runs here without a single byte moving in this repository.
# This repository's own release pipeline holds `contents: write`, `id-token: write` and
# `attestations: write`, and its code-scanning workflow holds `security-events: write`,
# so "what actually executes" is not a theoretical concern.
#
# WHY A SCANNER AND NOT A LIST. The predecessor guard
# (PowerShellLsp.SarifScan.Tests.ps1, 'pins upload-sarif by a 40-hex COMMIT SHA') named
# ONE action in ONE file, so it could only ever protect the instance someone remembered
# to write down -- and it protected exactly that one while ten other movable refs sat in
# the same three workflows. This block DISCOVERS the surface instead: every YAML under
# .github/ plus every composite action.yml in the tree, every `uses:` line inside them.
# A new workflow, a new step, or a new composite action is covered the moment it lands,
# with nothing to remember.
#
# WHAT IS EXEMPT, AND WHY. Local actions (`uses: ./...`) resolve inside this repository
# at the commit already being run, so they carry no third-party mutability. Docker refs
# (`uses: docker://...`) are a different addressing scheme with their own digest rules
# and none exist here; they are classified and reported, never silently swallowed.
#
# WHY THE VERSION COMMENT IS REQUIRED, NOT COSMETIC. Dependabot's github-actions
# ecosystem maintains SHA-pinned refs by rewriting the SHA and the adjacent `# vX.Y.Z`
# comment together. Drop the comment and the pin becomes an opaque hex string that no
# human can audit and no bot can bump -- which is how a SHA pin quietly rots into a
# permanently stale dependency. The comment is part of the mechanism.
#
# ANTI-VACUITY. Three independent controls, all EXECUTED rather than described:
#   1. a discovery floor -- if the scan finds no workflow files or no external refs, the
#      block FAILS instead of passing over an empty set;
#   2. mutation controls -- the very same classifier is run over synthetic in-memory YAML
#      carrying each movable form, and must reject each one;
#   3. an acceptance control -- the classifier must ACCEPT a compliant synthetic ref, so
#      a classifier that rejected everything could not pass either.
#
# No network, no daemon: fast and cross-platform. Runs on all four CI legs.

BeforeAll {
    $script:PluginRoot = Split-Path -Parent $PSScriptRoot

    # Directories that are never part of the executable surface: git internals, sibling
    # dispatch worktrees (gitignored, present only on a maintainer's box), dependency
    # trees, and captured CI logs. Matched as PATH SEGMENTS so a legitimate file whose
    # name merely contains one of these words is not dropped.
    $script:ExcludedSegments = @('.git', 'worktrees', '.worktrees', 'node_modules', '.venv')

    function script:Test-ExcludedPath {
        param([string]$Path, [string]$Root)
        $rel = $Path
        if ($Path.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase)) {
            $rel = $Path.Substring($Root.Length)
        }
        $segments = $rel -split '[\\/]+' | Where-Object { $_ -ne '' }
        foreach ($seg in $segments) {
            if ($script:ExcludedSegments -contains $seg) { return $true }
        }
        return $false
    }

    # DISCOVERY. Everything GitHub would treat as a workflow or an action definition.
    function script:Get-ActionYamlFile {
        param([string]$Root)
        $found = New-Object System.Collections.Generic.List[string]

        $ghDir = Join-Path $Root '.github'
        if (Test-Path -LiteralPath $ghDir) {
            Get-ChildItem -LiteralPath $ghDir -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -eq '.yml' -or $_.Extension -eq '.yaml' } |
                ForEach-Object { if (-not (script:Test-ExcludedPath -Path $_.FullName -Root $Root)) { $found.Add($_.FullName) } }
        }

        # Composite / local action definitions can live anywhere in the tree.
        Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'action.yml' -or $_.Name -eq 'action.yaml' } |
            ForEach-Object {
                if (-not (script:Test-ExcludedPath -Path $_.FullName -Root $Root)) {
                    if (-not $found.Contains($_.FullName)) { $found.Add($_.FullName) }
                }
            }

        return , @($found | Sort-Object)
    }

    # THE CLASSIFIER, over TEXT. Both the real scan and the mutation controls call this
    # one function, so a control that passes is exercising the code the gate runs -- not
    # a parallel re-implementation that could drift away from it.
    #
    # A `uses:` key is recognised only when it is the first content on the line (optionally
    # after a YAML sequence dash). That is what keeps a prose mention of `uses: ...` inside
    # a comment from being scanned as an executable reference.
    function script:Get-UsesReferenceFromText {
        param([string]$Text, [string]$Label)
        $refs = New-Object System.Collections.Generic.List[psobject]
        $lines = $Text -split "\r?\n"
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $m = [regex]::Match($lines[$i], '^\s*(?:-\s+)?uses:\s*(\S+)\s*(.*)$')
            if (-not $m.Success) { continue }
            $ref     = $m.Groups[1].Value
            $trailer = $m.Groups[2].Value

            $kind = 'external'
            if ($ref -like './*' -or $ref -like '.\*' -or $ref -eq '.') { $kind = 'local' }
            elseif ($ref -like 'docker://*') { $kind = 'docker' }

            $atIndex = $ref.LastIndexOf('@')
            $repo = if ($atIndex -ge 0) { $ref.Substring(0, $atIndex) } else { $ref }
            $gitRef = if ($atIndex -ge 0) { $ref.Substring($atIndex + 1) } else { '' }

            # Case-SENSITIVE by construction: git object ids are lowercase hex, and an
            # uppercase variant would be a hand-typed value rather than a resolved one.
            $isSha = ($gitRef.Length -eq 40) -and ($gitRef -cmatch '^[0-9a-f]{40}$')
            $hasVersionComment = $trailer -match '#\s*v?\d+(\.\d+)*'

            $refs.Add([pscustomobject]@{
                Source            = $Label
                Line              = $i + 1
                Raw               = $lines[$i].Trim()
                Kind              = $kind
                Repo              = $repo
                Ref               = $gitRef
                IsShaPinned       = $isSha
                HasVersionComment = [bool]$hasVersionComment
                # The single verdict the gate acts on.
                IsCompliant       = ($kind -ne 'external') -or ($isSha -and $hasVersionComment)
            })
        }
        return , @($refs)
    }

    function script:Get-UsesReferenceFromFile {
        param([string[]]$Paths, [string]$Root)
        $all = New-Object System.Collections.Generic.List[psobject]
        foreach ($p in $Paths) {
            $label = $p
            if ($p.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase)) {
                $label = $p.Substring($Root.Length).TrimStart('\', '/') -replace '\\', '/'
            }
            $text = [System.IO.File]::ReadAllText($p)
            foreach ($r in (script:Get-UsesReferenceFromText -Text $text -Label $label)) { $all.Add($r) }
        }
        return , @($all)
    }

    $script:YamlFiles = script:Get-ActionYamlFile -Root $script:PluginRoot
    $script:AllRefs   = script:Get-UsesReferenceFromFile -Paths $script:YamlFiles -Root $script:PluginRoot
    $script:External  = @($script:AllRefs | Where-Object { $_.Kind -eq 'external' })
}

Describe 'Immutable action pinning -- every external action is SHA-pinned (dispatch 000240)' {

    Context 'the scan itself is not vacuous' {

        It 'discovers the workflow/action YAML surface by scanning, not from a hand-maintained list' {
            # Three workflows exist today. A floor rather than an equality: adding a
            # fourth workflow must not fail this, but LOSING the surface must.
            @($script:YamlFiles).Count | Should -BeGreaterOrEqual 3
        }

        It 'discovers the three named workflow files among them' {
            $names = @($script:YamlFiles | ForEach-Object { Split-Path $_ -Leaf })
            foreach ($expected in @(
                'powershell-lsp-ci.yml',
                'powershell-lsp-code-scanning.yml',
                'powershell-lsp-release.yml')) {
                $names | Should -Contain $expected
            }
        }

        It 'extracts a non-empty set of EXTERNAL action references' {
            # If this ever reads zero, every assertion below would pass over an empty set.
            # The floor is deliberately below today's count so ordinary churn does not trip
            # it, and far enough above zero that a broken extractor cannot hide.
            @($script:External).Count | Should -BeGreaterOrEqual 8
        }
    }

    Context 'the executable surface' {

        It 'pins EVERY external action to a full 40-character commit SHA' {
            $offenders = @($script:External | Where-Object { -not $_.IsShaPinned })
            $detail = ($offenders | ForEach-Object { "$($_.Source):$($_.Line) -> $($_.Raw)" }) -join "; "
            $offenders.Count | Should -Be 0 -Because "these external actions are on a MOVABLE ref: $detail"
        }

        It 'carries a human-readable release comment on the same line as every pinned ref' {
            # Dependabot rewrites the SHA and this comment together; without it the pin
            # cannot be audited by a human or bumped by the bot.
            $offenders = @($script:External | Where-Object { $_.IsShaPinned -and -not $_.HasVersionComment })
            $detail = ($offenders | ForEach-Object { "$($_.Source):$($_.Line) -> $($_.Raw)" }) -join "; "
            $offenders.Count | Should -Be 0 -Because "these SHA pins have no adjacent version comment: $detail"
        }

        It 'contains ZERO external references on a movable ref of any recognised form' {
            # Belt and braces over the classifier: a direct textual sweep for the movable
            # shapes, so a classifier bug cannot make the surface look clean.
            $movable = @($script:External | Where-Object {
                $_.Ref -match '^(v\d|latest$|main$|master$|HEAD$)' -or ($_.Ref.Length -ne 40)
            })
            $detail = ($movable | ForEach-Object { "$($_.Source):$($_.Line) -> $($_.Raw)" }) -join "; "
            $movable.Count | Should -Be 0 -Because "movable external refs found: $detail"
        }

        It 'reports every reference it classified, so the gate is auditable from the log' {
            foreach ($r in $script:AllRefs) {
                Write-Host ("  [{0}] {1}:{2}  {3}" -f $r.Kind, $r.Source, $r.Line, $r.Raw)
            }
            @($script:AllRefs).Count | Should -BeGreaterOrEqual @($script:External).Count
        }
    }

    Context 'anti-vacuity: the classifier is run over synthetic text and must REJECT movable forms' {
        # Each case mutates an in-memory copy of a compliant step. If the gate above were
        # vacuous -- a classifier that marks everything compliant -- every case here fails.

        BeforeAll {
            $script:GoodYaml = @'
jobs:
  build:
    steps:
      - name: Checkout
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
'@
        }

        It 'ACCEPTS a full-SHA ref that carries a version comment' {
            # The acceptance half: a classifier that rejected everything would fail here,
            # so the rejection cases below cannot be passing for the wrong reason.
            $refs = script:Get-UsesReferenceFromText -Text $script:GoodYaml -Label 'synthetic-good'
            @($refs).Count | Should -Be 1
            $refs[0].Kind | Should -BeExactly 'external'
            $refs[0].IsCompliant | Should -BeTrue
        }

        It 'REJECTS a major-version tag ref' {
            $refs = script:Get-UsesReferenceFromText -Text ($script:GoodYaml -replace '@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7\.0\.1', '@v7') -Label 'synthetic-major'
            @($refs).Count | Should -Be 1
            $refs[0].IsCompliant | Should -BeFalse
        }

        It 'REJECTS an exact-semver tag ref (a tag is movable even when it looks precise)' {
            $refs = script:Get-UsesReferenceFromText -Text ($script:GoodYaml -replace '@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7\.0\.1', '@v7.0.1') -Label 'synthetic-semver'
            $refs[0].IsCompliant | Should -BeFalse
        }

        It 'REJECTS a branch ref (main)' {
            $refs = script:Get-UsesReferenceFromText -Text ($script:GoodYaml -replace '@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7\.0\.1', '@main') -Label 'synthetic-main'
            $refs[0].IsCompliant | Should -BeFalse
        }

        It 'REJECTS a floating latest ref' {
            $refs = script:Get-UsesReferenceFromText -Text ($script:GoodYaml -replace '@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7\.0\.1', '@latest') -Label 'synthetic-latest'
            $refs[0].IsCompliant | Should -BeFalse
        }

        It 'REJECTS an abbreviated SHA (7 hex characters is not immutable addressing)' {
            $refs = script:Get-UsesReferenceFromText -Text ($script:GoodYaml -replace '@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7\.0\.1', '@3d3c42e # v7.0.1') -Label 'synthetic-short'
            $refs[0].IsShaPinned | Should -BeFalse
            $refs[0].IsCompliant | Should -BeFalse
        }

        It 'REJECTS a full SHA with NO version comment' {
            $refs = script:Get-UsesReferenceFromText -Text ($script:GoodYaml -replace ' # v7\.0\.1', '') -Label 'synthetic-nocomment'
            $refs[0].IsShaPinned | Should -BeTrue
            $refs[0].HasVersionComment | Should -BeFalse
            $refs[0].IsCompliant | Should -BeFalse
        }

        It 'EXEMPTS a local action reference (it resolves inside this repository)' {
            $refs = script:Get-UsesReferenceFromText -Text ($script:GoodYaml -replace 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7\.0\.1', './.github/actions/local-thing') -Label 'synthetic-local'
            $refs[0].Kind | Should -BeExactly 'local'
            $refs[0].IsCompliant | Should -BeTrue
        }

        It 'does NOT scan a uses: mention that is inside a comment' {
            $commented = "jobs:`n  build:`n    steps:`n      # uses: actions/checkout@v7 -- prose, not a step`n      - name: Nothing`n        run: echo hi"
            $refs = script:Get-UsesReferenceFromText -Text $commented -Label 'synthetic-comment'
            @($refs).Count | Should -Be 0
        }
    }
}
