#Requires -Version 5.1
[CmdletBinding()]
param(
    # Compare the DERIVED table against the shipped rulesets/rule-rationales.psd1 instead of
    # writing it. Exit 0 when they match EXACTLY, 1 (with a diff) on drift.
    [switch] $Check,
    # Explicit PSScriptAnalyzer module root or manifest to derive from. Empty = auto-discover:
    # the vendored module under CLAUDE_PLUGIN_DATA/modules first, then any importable
    # PSScriptAnalyzer at the pinned $PssaVersion (the regen-base-ruleset.ps1 resolution order).
    [string] $PssaPath = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# regen-rule-rationales.ps1 -- REGENERATE (or -Check) the shipped per-rule rationale table
# rulesets/rule-rationales.psd1 (dispatch 000121, I0.1 slice-1). The table attaches a static
# "why this rule matters" string to each rule the plugin can surface, rendered as ADDITIVE prose
# on the existing additionalContext channel. It adds NO userConfig knob and NO status token.
#
# THE SOURCE IS HYBRID (the 000120 survey's evidence-forced verdict):
#   * The PSSA half is AUTO-DERIVED, offline, from the vendored PINNED PSScriptAnalyzer
#     (Get-ScriptAnalyzerRule CommonName + Description) over EXACTLY the rule names enumerated in
#     rulesets/base.psd1 -- the plugin's own opt-in surface, a superset of the PSES-15 live
#     default. Zero maintenance; regenerated on a pin bump and reviewed in a diff.
#   * The 5 PLUGIN-OWNED finders have NO PSScriptAnalyzer metadata (PSSA is blind to them), so
#     their rationales are HAND-AUTHORED in $OwnedRationales below -- an auditable in-script
#     table, the $BaseRuleExclusions discipline of regen-base-ruleset.ps1.
#   * A small idiom-family OVERRIDE layer ($OwnedRationaleOverrides, dispatch 000125) REPLACES the
#     auto-derived text for a few PSSA rules whose derived rationale is circular or pure mechanism.
#     Applied AFTER derivation: an override must key a rule already in the derived surface, must
#     differ from the text it replaces (non-vacuity throw), and records the replaced text so a pin
#     bump that changes it surfaces under -Check. Overrides change GUIDANCE quality, not detection.
#
# THE EXTRACTION RULE (dispatch 000121 OQ2 -- deterministic, ASCII-safe, never mid-word).
# For a PSSA rule, rationale = "<CommonName> -- <Summary>", where:
#   1. CommonName and Description are whitespace-collapsed and trimmed; CommonName additionally
#      has any trailing '.' run stripped (several CommonNames are written as full sentences).
#   2. Description is split into sentences on '.', '!' or '?' followed by a space or end-of-string.
#      A period NOT followed by a space is not a boundary, so '3.0', 'SHA-1' and 'e.g.' are safe;
#      the '..' typo in PSAvoidDefaultValueForMandatoryParameter collapses to one '.' (a sentence's
#      trailing '.' run is normalized to a single '.'; '!' and '?' are left alone).
#   3. Summary = the FIRST sentence, then each following WHOLE sentence is appended while the total
#      stays within $MaxLength. The first sentence is always taken, even alone. Whole sentences,
#      never a partial one.
#   3a. DEGENERATE-SUMMARY RESCUE. A Description whose first sentence is a bare fragment carries no
#      "why" at all. So: if greedy packing took exactly ONE sentence, that sentence is shorter than
#      $MinSummary chars, and sentences remain, the next sentence is appended anyway (step 4 then
#      trims it). Measured at pin 1.25.0 this fires on exactly one rule -- PSAvoidUsingWMICmdlet,
#      whose Description opens 'Deprecated.' (11 chars) and whose 97-char CommonName leaves no room
#      for the sentence that actually explains it. Without this, its whole rationale is the word
#      'Deprecated.' The threshold states a PROPERTY (a summary must be more than a fragment); it is
#      not keyed to a rule name, and a pin bump re-derives it under the -Check diff.
#   4. If the result still exceeds $MaxLength (a long CommonName, a long first sentence, or a 3a
#      rescue), it is cut back to the last WHOLE WORD at or before $MaxLength - 3, stripped of
#      trailing punctuation, and '...' is appended. So the emitted text is never longer than
#      $MaxLength and never ends mid-word.
#   5. The result must be pure ASCII (bytes 0x20-0x7E). A non-ASCII char FAILS CLOSED (throw) --
#      it is never silently stripped, because PS 5.1 mojibakes non-ASCII in a no-BOM file.
# $MaxLength = 180 is the 000120 survey's length budget (measured Description median 135 / max
# 563), adopted AS GIVEN -- deliberately not tuned to make any particular rule fit. It is a budget,
# not a magic number: the rule above is what is frozen, and the shipped table records the cap and
# the pin it was generated at.
#
# THE RUNTIME CONTRACT. The table is a lookup keyed by the diagnostic's `code` (the PSSA rule name,
# or the owned finder's ruleId) -- see Import-RuleRationales / Get-RationaleForCode in
# scripts/lib/lsp-common.ps1. A code with NO entry surfaces its finding with NO rationale line:
# degrade, never fabricate, never block.
#
# The shipped .psd1 is GENERATED, never hand-edited: every change flows through this script.
# To regenerate: pwsh scripts/regen-rule-rationales.ps1 ; to verify: -Check (offline, at the pin).
#
# ASCII-only (PS 5.1 em-dash trap); straight quotes; LF; no BOM.
#
# Author: Mike Andersen / powershell-lsp plugin.

. (Join-Path $PSScriptRoot 'lib/lsp-common.ps1')

# Length budget for a single rendered rationale string (000120 survey guidance).
$script:MaxLength = 180
# Below this, a one-sentence summary is a fragment ('Deprecated.') rather than a rationale, and the
# next sentence is pulled in (step 3a). Chosen from the measured base first-sentence lengths at
# pin 1.25.0: the shortest is 11 chars, the next shortest is 25.
$script:MinSummary = 24

# --- hand-authored rationales for the 5 plugin-owned finders (dispatch 000121 OQ3; 000124) -------
# PSScriptAnalyzer is blind to these: they are the plugin's own AST/byte-level finders in
# scripts/lib/lsp-common.ps1, all emitting source = 'powershell-lsp'. Each entry is keyed by the
# finder's ACTUAL emitted ruleId/code -- NOT the finder's function name -- because the runtime
# lookup keys on the diagnostic's `code` field. Each is written in the why+fix register (what the
# rule catches, then what to do instead) and must stay FACTUALLY CONSISTENT with the finder's real
# predicate, including its suppressions. Adding an entry is a survey-first slice, never a silent
# ride-in here.
$script:OwnedRationales = @{
    # Find-BashIsm. Fires on a bash command NAME used as a command. SUPPRESSED for an explicit
    # '& name' call-operator invocation and for a name the file defines itself, so the rationale
    # says "not recognized as a PowerShell command here" -- it never claims the binary is absent.
    'BashIsm' =
    "Unix/bash command, not recognized as a PowerShell command here: it fails on a clean Windows " +
    "host, or silently relies on Git Bash. Use a PowerShell equivalent, or call it with '&'."

    # Find-Ps7OnlySyntax. Fires on 7-only syntax nodes; SUPPRESSED when the file declares
    # '#Requires -Version 7' (a file that targets 7 is not a portability defect).
    'PS7OnlySyntax' =
    "PowerShell 7-only syntax: a PARSE error under Windows PowerShell 5.1, so the whole file " +
    "fails to load there. Use a 5.1-compatible form, or declare '#Requires -Version 7'."

    # Find-NonAsciiSmuggling. Fires only on a file with NO UTF-8 BOM (a BOM file is always safe),
    # so the rationale names the no-BOM precondition and offers BOTH fixes the finder implies.
    'NonAsciiChar' =
    "Non-ASCII smart punctuation in a file with no UTF-8 BOM: Windows PowerShell 5.1 reads it as " +
    "Windows-1252 and mojibakes the text. Use plain ASCII, or save the file with a BOM."

    # Find-ModuleAwareness. Emitted ruleId is 'ModuleNotInstalled'. Fires only when the command is a
    # positive index hit whose owning module is NOT installed AND not defined, dot-sourced,
    # #Requires-d, or Import-Module'd in scope -- so the rationale names both halves of that
    # predicate rather than claiming the command does not exist.
    'ModuleNotInstalled' =
    "Command comes from a module that is not installed here and is not imported, required, or " +
    "defined in this file, so the call fails at run time. Install or import the module."

    # Test-ManifestConsistency. Emitted ruleId is 'ManifestConsistency' for BOTH of its finding
    # kinds -- orphan-export (a name in FunctionsToExport that no function definition matches) and
    # under-declared-export (a function the module defines AND exports that FunctionsToExport omits)
    # -- so the rationale names both halves. It never claims the module is broken: an indeterminate
    # shape (a '*' wildcard export, an empty/null FunctionsToExport, a dot-source or dynamic export,
    # an unparseable module) DEGRADES to prose before any finding is emitted, so a finding only ever
    # means the two determinate lists genuinely disagree.
    'ManifestConsistency' =
    "Manifest FunctionsToExport disagrees with the module: a listed function is never defined, or " +
    "an exported one is unlisted, so the module exports the wrong commands. Align them."

    # Find-CommandLinePlaceholder. Emitted ruleId is 'CommandLinePlaceholder'. Fires on a literal
    # '<Name>' left on a command line -- the reserved '<' redirection operator abutting a bareword
    # ending in '>' -- so the rationale names the parse-error cause and the two fixes the finder implies.
    'CommandLinePlaceholder' =
    "Unfilled '<...>' placeholder on a command line: angle brackets are reserved redirection " +
    "operators, so this is a parse error, not text. Insert a real value, or quote the literal."
}

# --- hand-authored rationale OVERRIDES for the idiom family (dispatch 000125, N1.1 slice 1) -------
# For a handful of PSScriptAnalyzer rules, the auto-derived "<CommonName> -- <Description prefix>"
# text is weak: circular (the "why" restates the rule name) or pure mechanism (it describes the
# checker, not the idiom, and offers no fix). The 000124 leg-2 survey measured this and recommended
# an OWNED override layer over the coherent idiom family -- rules that already fire, so this changes
# guidance QUALITY, not detection. Each entry REPLACES the derived PSSA text for that code with a
# why+fix rationale. The override is applied in Get-DerivedRationales AFTER derivation, so:
#   * every override key MUST exist in the derived (base.psd1) surface, else it can never render
#     (throws -- the same error class as keying an owned entry on a finder function name);
#   * each override MUST differ from the derived text it replaces (throws on equality -- a
#     no-op override proves nothing and a later pin bump could silently make it vacuous); and
#   * the artifact records each override WITH the derived text it replaced, so a pin bump that
#     changes that derived text surfaces under -Check rather than being masked by the override.
# Anchor is PSShouldProcess: it is the only one of the four inside the PSES v4.6.0 15-rule
# no-settings allow-list (AnalysisService.s_defaultRules, read by reflection 2026-07-10), so its
# override reaches the DEFAULT surface every user gets; the other three are base-only (opt-in).
# CONTENT constraint (load-bearing, 000124): the Write-Host fix must NOT lead with Write-Output --
# that writes to the success pipeline and changes a function's return value. Lead with
# Write-Information / Write-Verbose for messages.
$script:OwnedRationaleOverrides = @{
    # PSShouldProcess (in PSES-15 -> default surface). Bidirectional rule: SupportsShouldProcess
    # declared but ShouldProcess never called, OR the reverse. Derived text is pure mechanism
    # ("Checks that ...") with no fix.
    'PSShouldProcess' =
    "SupportsShouldProcess is declared without a ShouldProcess call, or the reverse, so -WhatIf " +
    "and -Confirm silently do nothing. Call `$PSCmdlet.ShouldProcess() before the change."

    # PSAvoidUsingWriteHost (base-only). Derived text is circular AND its fix menu leads with
    # Write-Output, which is actively hazardous for a flag-not-transform plugin.
    'PSAvoidUsingWriteHost' =
    "Write-Host writes to the host, not the pipeline, so its text is not part of the output. Use " +
    "Write-Information or Write-Verbose for messages, Write-Output only for return values."

    # PSUseSupportsShouldProcess (base-only). Derived text carries a real why but no fix.
    'PSUseSupportsShouldProcess' =
    "Defines its own -WhatIf or -Confirm parameter instead of inheriting them. Declare " +
    "[CmdletBinding(SupportsShouldProcess)] so PowerShell supplies both and honors ConfirmPreference."

    # PSAvoidShouldContinueWithoutForce (base-only; NOT in PSES-15, resolved by reflection 000125).
    # ShouldContinue is not governed by ConfirmPreference the way ShouldProcess is, so the fix is a
    # Force parameter, not -Confirm.
    'PSAvoidShouldContinueWithoutForce' =
    "ShouldContinue always prompts and ignores -Confirm:`$false, so an unattended caller has no way " +
    "past it. Add a Force parameter and skip the prompt when it is set."

    # --- slice 2 (dispatch 000142) -----------------------------------------
    # SHARED EVIDENCE that all five below ALREADY FIRE -- the bar this layer is held to, measured
    # rather than assumed. Each is (a) a rule the shipped corpus SNAPSHOTS actually contain
    # (tests/corpus/expected/**/*.json, DERIVED by Update-CorpusSnapshots.ps1 from real analyzer
    # runs, never hand-authored), and (b) a member of the PSES-15 LIVE DEFAULT surface -- the set a
    # user sees with no opt-in at all. That makes slice 2 the complement of slice 1, which was
    # mostly base-only opt-in rules: these five are what the median user actually reads. No new
    # detection, no new rule, no new owned code -- guidance text only.

    # PSAvoidDefaultValueSwitchParameter (default surface; fires in the corpus). Derived text is
    # PURELY CIRCULAR -- "Switch parameter should not default to true" restates the rule's own
    # CommonName and carries neither a why nor a fix.
    'PSAvoidDefaultValueSwitchParameter' =
    "A switch defaulting to true cannot be turned off by omitting it -- the caller must write " +
    "-Name:`$false. Default it to false and invert the logic."

    # PSAvoidUsingCmdletAliases (default surface; fires in the corpus). Derived text is DEFINITIONAL
    # and truncates mid-sentence ("An alias is an alternate name or nickname for a cmdlet..."), so it
    # explains what an alias IS and never why using one is a problem. The replacement's claim is
    # VERIFIED on this machine, not asserted: Get-Command resolves curl/wget to Invoke-WebRequest
    # aliases under Windows PowerShell 5.1, while under PowerShell 7 curl is curl.exe and wget does
    # not resolve at all -- same script, same box, a different command.
    'PSAvoidUsingCmdletAliases' =
    "curl and wget mean Invoke-WebRequest in Windows PowerShell 5.1 but not in PowerShell 7, and " +
    "any profile can redefine an alias. Spell the full cmdlet name."

    # PSPossibleIncorrectComparisonWithNull (default surface; fires in the corpus). Derived text is
    # PURE MECHANISM ("Checks that `$null is on the left side...") -- it states the rule's own
    # predicate and never names the trap. VERIFIED: @(1, `$null, 2) -eq `$null returns an Object[],
    # not a boolean, so the comparison silently becomes a filter.
    'PSPossibleIncorrectComparisonWithNull' =
    "With an array on the left, -eq filters the array instead of returning a boolean, so " +
    "`$x -eq `$null is not a null test. Put `$null on the left: `$null -eq `$x."

    # PSUseApprovedVerbs (default surface; fires in the corpus). Derived text is CIRCULAR plus an
    # appeal to authority ("This is in line with PowerShell's best practices") -- a reader who did
    # not already agree learns nothing. The replacement names the two concrete consequences.
    'PSUseApprovedVerbs' =
    "An unapproved verb makes the command undiscoverable by Get-Command -Verb and makes " +
    "Import-Module warn on every load. Pick the closest verb from Get-Verb."

    # PSUseDeclaredVarsMoreThanAssignments (default surface; fires in the corpus). Derived text is
    # PURE MECHANISM ("Ensure declared variables are used elsewhere") -- it restates the check and
    # omits the reason the finding is worth reading, which is that it is usually a TYPO.
    'PSUseDeclaredVarsMoreThanAssignments' =
    "A variable assigned and never read is usually a typo in the name meant to read it, or a " +
    "leftover from a refactor. Remove it, or fix the misspelled reader."
}

function Resolve-PssaManifest {
    # The regen-base-ruleset.ps1 resolution order, unchanged: explicit path, then the vendored
    # module under CLAUDE_PLUGIN_DATA/modules, then any importable PSScriptAnalyzer at the pin.
    # NO second acquisition path is introduced here.
    param([string]$Explicit)
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) {
        if (Test-Path -LiteralPath $Explicit -PathType Leaf) { return $Explicit }
        $m = Get-ChildItem -LiteralPath $Explicit -Recurse -Filter 'PSScriptAnalyzer.psd1' -File -ErrorAction SilentlyContinue |
            Sort-Object { $_.FullName.Length } | Select-Object -First 1
        if ($null -ne $m) { return $m.FullName }
    }
    $vendor = Get-PssaModuleDir
    if (Test-Path -LiteralPath $vendor) {
        $m = Get-ChildItem -LiteralPath $vendor -Recurse -Filter 'PSScriptAnalyzer.psd1' -File -ErrorAction SilentlyContinue |
            Sort-Object { $_.FullName.Length } | Select-Object -First 1
        if ($null -ne $m) { return $m.FullName }
    }
    $pin = Get-PinnedPssaVersion
    $mod = Get-Module -ListAvailable PSScriptAnalyzer |
        Where-Object { [string]::IsNullOrWhiteSpace($pin) -or $_.Version.ToString() -eq $pin } |
        Sort-Object Version -Descending | Select-Object -First 1
    if ($null -ne $mod) { return $mod.Path }
    throw 'could not locate a vendored or importable PSScriptAnalyzer to derive from.'
}

function Get-BaseRuleNames {
    # The PSSA half derives over EXACTLY the enumerated rulesets/base.psd1 surface (READ-ONLY here).
    $baseFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'rulesets/base.psd1'
    if (-not (Test-Path -LiteralPath $baseFile -PathType Leaf)) { throw ('shipped base file not found: ' + $baseFile) }
    $data = Import-PowerShellDataFile -LiteralPath $baseFile
    if (-not $data.ContainsKey('IncludeRules')) { throw 'shipped base file has no IncludeRules key.' }
    return @(@($data['IncludeRules']) | Sort-Object)
}

function Get-ShippedRationalesPath {
    return (Join-Path (Split-Path -Parent $PSScriptRoot) 'rulesets/rule-rationales.psd1')
}

function Compress-Whitespace {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return (($Text -replace '\s+', ' ').Trim())
}

function Assert-AsciiText {
    # FAIL CLOSED on any byte outside printable ASCII. Never silently strip: a non-ASCII char in a
    # no-BOM .psd1 mojibakes under Windows PowerShell 5.1, which is the whole trap this guards.
    # -AllowNewline permits LF (and ONLY LF) for the whole-file check: a stray CR would mean CRLF
    # slipped in, and a tab is not wanted either, so both still fail.
    param([string]$Text, [string]$Context, [switch]$AllowNewline)
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        if ($AllowNewline -and $code -eq 10) { continue }
        if ($code -lt 32 -or $code -gt 126) {
            throw ('non-ASCII character U+{0:X4} in {1}; the rationale table must be pure ASCII.' -f $code, $Context)
        }
    }
}

function Split-DescriptionSentence {
    # Split whitespace-collapsed $Text on '.', '!' or '?' followed by a SPACE or end-of-string.
    # A '.' followed by any other character (a digit, a letter, another '.') is NOT a boundary, so
    # '3.0' / 'SHA-1.' / 'ignored..' behave. Each sentence's trailing '.' RUN is normalized to a
    # single '.'; '!' and '?' terminators are left exactly as written.
    param([string]$Text)
    $out = New-Object System.Collections.ArrayList
    $sb = New-Object System.Text.StringBuilder
    $emit = {
        $s = $sb.ToString().Trim()
        [void]$sb.Clear()
        if ($s.Length -eq 0) { return }
        if ($s.EndsWith('.')) { $s = $s.TrimEnd('.') + '.' }
        if ($s.Length -gt 0) { [void]$out.Add($s) }
    }
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        [void]$sb.Append($ch)
        if ($ch -eq '.' -or $ch -eq '!' -or $ch -eq '?') {
            $atEnd = ($i -eq ($Text.Length - 1))
            $nextIsSpace = (-not $atEnd) -and ($Text[$i + 1] -eq ' ')
            if ($atEnd -or $nextIsSpace) { & $emit }
        }
    }
    & $emit
    return @($out)
}

function Compress-ToWordBoundary {
    # Cut $Text back to the last WHOLE word at or before $Limit chars, then strip trailing
    # punctuation. Never returns a mid-word fragment.
    param([string]$Text, [int]$Limit)
    if ($Text.Length -le $Limit) { return $Text }
    $cut = $Text.Substring(0, $Limit)
    $sp = $cut.LastIndexOf(' ')
    if ($sp -gt 0) { $cut = $cut.Substring(0, $sp) }
    return $cut.TrimEnd(' ', ',', ';', ':', '.', '-')
}

function Get-RationaleText {
    # The OQ2 extraction rule, in one pure function (steps 1-5 of the header block).
    param([string]$CommonName, [string]$Description, [int]$MaxLength = 180, [int]$MinSummary = 24)
    $cn = (Compress-Whitespace $CommonName).TrimEnd('.')
    $ds = Compress-Whitespace $Description
    if ([string]::IsNullOrWhiteSpace($cn) -and [string]::IsNullOrWhiteSpace($ds)) { return '' }
    $sentences = @(Split-DescriptionSentence $ds)
    if ($sentences.Count -eq 0) { return $cn }
    $prefix = if ($cn.Length -gt 0) { $cn + ' -- ' } else { '' }
    # Step 3: greedy WHOLE-sentence packing, measured against the full rendered length.
    $summary = $sentences[0]
    for ($i = 1; $i -lt $sentences.Count; $i++) {
        $cand = $summary + ' ' + $sentences[$i]
        if (($prefix + $cand).Length -le $MaxLength) { $summary = $cand } else { break }
    }
    # Step 3a: degenerate-summary rescue -- a lone fragment ('Deprecated.') is not a rationale.
    if ($sentences.Count -gt 1 -and $summary -eq $sentences[0] -and $summary.Length -lt $MinSummary) {
        $summary = $summary + ' ' + $sentences[1]
    }
    $text = $prefix + $summary
    # Step 4: word-boundary truncation.
    if ($text.Length -gt $MaxLength) {
        $text = (Compress-ToWordBoundary -Text $text -Limit ($MaxLength - 3)) + '...'
    }
    return $text
}

function Get-DerivedRationales {
    # The reproducible derivation: the base.psd1 PSSA rules from the pin, plus the 5 hand-authored
    # owned finders. Returns @{ Entries = @{ code -> text }; Owned = @(sorted owned codes);
    # PssaRules = @(sorted PSSA codes); PssaVersion = '<pin>' }.
    param([string]$ManifestPath)
    Import-Module $ManifestPath -Force -ErrorAction Stop
    $baseRules = Get-BaseRuleNames
    $byName = @{}
    foreach ($r in (Get-ScriptAnalyzerRule)) { $byName[[string]$r.RuleName] = $r }

    $entries = @{}
    foreach ($name in $baseRules) {
        if (-not $byName.ContainsKey($name)) {
            throw ('base.psd1 names rule "' + $name + '" but the pinned PSScriptAnalyzer does not expose it.')
        }
        $rule = $byName[$name]
        $text = Get-RationaleText -CommonName ([string]$rule.CommonName) -Description ([string]$rule.Description) -MaxLength $script:MaxLength -MinSummary $script:MinSummary
        if ([string]::IsNullOrWhiteSpace($text)) { throw ('empty derived rationale for ' + $name + '.') }
        Assert-AsciiText -Text $text -Context ('the derived rationale for ' + $name)
        if ($text.Length -gt $script:MaxLength) { throw ('derived rationale for ' + $name + ' exceeds the cap.') }
        $entries[$name] = $text
    }
    foreach ($name in @($script:OwnedRationales.Keys)) {
        $text = Compress-Whitespace ([string]$script:OwnedRationales[$name])
        if ([string]::IsNullOrWhiteSpace($text)) { throw ('empty hand-authored rationale for ' + $name + '.') }
        Assert-AsciiText -Text $text -Context ('the hand-authored rationale for ' + $name)
        if ($text.Length -gt $script:MaxLength) {
            throw ('hand-authored rationale for ' + $name + ' is ' + $text.Length + ' chars, over the ' + $script:MaxLength + '-char cap.')
        }
        if ($entries.ContainsKey($name)) { throw ('owned finder ' + $name + ' collides with a PSSA rule name.') }
        $entries[$name] = $text
    }
    # Apply the hand-authored idiom overrides LAST, over the derived surface (dispatch 000125). Each
    # override must key an existing derived rule (else it can never render), must be ASCII within the
    # cap, and must DIFFER from the derived text it replaces (non-vacuity). The derived text it
    # replaced is recorded so a pin bump that changes it surfaces under -Check.
    $overrides = @{}
    foreach ($name in @($script:OwnedRationaleOverrides.Keys)) {
        # Constraint 4: an override may ONLY replace auto-derived PSSA text. Validate against the
        # derived PSSA set ($baseRules), NOT the merged $entries -- otherwise an override keyed on an
        # owned finder code would pass, shadow that owned hand-authored rationale, and record the
        # owned text as its "derived" baseline. Guard the owned collision explicitly for a clear error.
        if ($script:OwnedRationales.ContainsKey($name)) {
            throw ('override keyed "' + $name + '" collides with a plugin-owned hand-authored rationale; overrides may only replace auto-derived PSSA text, not owned entries.')
        }
        if ($baseRules -notcontains $name) {
            throw ('override keyed "' + $name + '" is not in the derived base.psd1 PSSA surface, so it has no derived rationale to replace and can never render.')
        }
        $override = Compress-Whitespace ([string]$script:OwnedRationaleOverrides[$name])
        if ([string]::IsNullOrWhiteSpace($override)) { throw ('empty override rationale for ' + $name + '.') }
        Assert-AsciiText -Text $override -Context ('the override rationale for ' + $name)
        if ($override.Length -gt $script:MaxLength) {
            throw ('override rationale for ' + $name + ' is ' + $override.Length + ' chars, over the ' + $script:MaxLength + '-char cap.')
        }
        $derivedText = [string]$entries[$name]
        if ($override -ceq $derivedText) {
            throw ('override for ' + $name + ' is identical to the derived text it replaces; a vacuous override proves nothing (dispatch 000125 non-vacuity guard).')
        }
        $entries[$name] = $override
        $overrides[$name] = @{ derived = $derivedText; text = $override }
    }
    return @{
        Entries = $entries
        Owned = @(@($script:OwnedRationales.Keys) | Sort-Object)
        Overrides = $overrides
        OverrideKeys = @(@($script:OwnedRationaleOverrides.Keys) | Sort-Object)
        PssaRules = @($baseRules)
        PssaVersion = (Get-PinnedPssaVersion)
    }
}

function Format-RationaleFile {
    # Emit the shipped .psd1 text (deterministic: entries sorted by key). ASCII/LF/no BOM.
    # Single quotes inside a rationale are doubled -- the psd1 single-quoted-string escape.
    param($Derived)
    $entries = $Derived.Entries
    $names = @($entries.Keys | Sort-Object)
    $sb = New-Object System.Text.StringBuilder
    $add = { param([string]$s) [void]$sb.Append($s); [void]$sb.Append("`n") }
    & $add '# rule-rationales.psd1 -- GENERATED per-rule rationale table (do not hand-edit).'
    & $add '#'
    & $add '# A static "why this rule matters" string per rule the plugin can surface, rendered as'
    & $add '# ADDITIVE prose on the existing additionalContext channel -- one line per DISTINCT rule'
    & $add '# surfaced in a file, riding only existing findings. A clean file emits nothing. A rule with'
    & $add '# no entry here surfaces its finding with NO rationale line: degrade, never fabricate.'
    & $add '#'
    & $add '# HYBRID source (dispatch 000120 survey / 000121 build). The PSSA half is auto-derived from'
    & $add '# the vendored PINNED PSScriptAnalyzer (CommonName + a whole-sentence Description prefix,'
    & $add '# capped) over exactly the rulesets/base.psd1 surface; the plugin-owned finders (which'
    & $add '# PSScriptAnalyzer knows nothing about) are hand-authored in the generator.'
    & $add '#'
    & $add '# DERIVED by scripts/regen-rule-rationales.ps1. A pin bump is a DELIBERATE regeneration'
    & $add '# reviewed in a diff, never silent staleness (the -Check drift-guard enforces this).'
    & $add '#'
    & $add '# To regenerate: pwsh scripts/regen-rule-rationales.ps1 ; to verify: -Check (offline, at the pin).'
    & $add ''
    & $add '@{'
    & $add "    schema = 'rule-rationales/v1'"
    & $add ("    pssa_version = '" + $Derived.PssaVersion + "'")
    & $add ("    max_length = " + $script:MaxLength)
    & $add ("    pssa_count = " + @($Derived.PssaRules).Count)
    & $add ("    owned_count = " + @($Derived.Owned).Count)
    & $add ("    override_count = " + @($Derived.OverrideKeys).Count)
    & $add '    # The plugin-owned finders, hand-authored (PSScriptAnalyzer has no metadata for them).'
    & $add '    # Keyed by the finder ruleId/code as EMITTED, not by its function name.'
    & $add '    owned = @('
    foreach ($o in @($Derived.Owned)) { & $add ("        '" + $o + "'") }
    & $add '    )'
    & $add '    # Idiom-family rules whose auto-derived PSSA text is replaced by a hand-authored override'
    & $add '    # (dispatch 000125). derived = the PSSA text that was replaced, recorded so a pin bump that'
    & $add '    # changes it surfaces under -Check; text = the override now in entries[] for that code.'
    & $add '    overrides = @{'
    foreach ($o in @($Derived.OverrideKeys)) {
        $d = [string]$Derived.Overrides[$o].derived -replace "'", "''"
        $t = [string]$Derived.Overrides[$o].text -replace "'", "''"
        & $add ("        '" + $o + "' = @{")
        & $add ("            derived = '" + $d + "'")
        & $add ("            text = '" + $t + "'")
        & $add '        }'
    }
    & $add '    }'
    & $add '    # rule CODE -> rationale text (the runtime lookup; keyed by the diagnostic `code`).'
    & $add '    entries = @{'
    foreach ($n in $names) {
        $val = [string]$entries[$n] -replace "'", "''"
        & $add ("        '" + $n + "' = '" + $val + "'")
    }
    & $add '    }'
    & $add '}'
    return $sb.ToString()
}

function Get-RationaleCanonical {
    # Canonical, order-independent string of a table for diffing. $Overrides is code -> @{derived;
    # text}. The E-line already carries an override's FINAL text, so an override edited only in the
    # artifact drifts there; the OV line pins its presence/key (a dropped or retargeted override
    # drifts); the OD line pins the DERIVED text it replaced, so a pin bump that changes that text
    # surfaces here rather than being masked by the override (dispatch 000125 constraint 2).
    param($Entries, $Owned, $Overrides, [string]$PssaVersion, [int]$MaxLength)
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('V ' + $PssaVersion)
    [void]$lines.Add('L ' + $MaxLength)
    foreach ($o in @($Owned | Sort-Object)) { [void]$lines.Add('O ' + $o) }
    if ($null -ne $Overrides) {
        foreach ($o in @($Overrides.Keys | Sort-Object)) {
            [void]$lines.Add('OV ' + $o)
            [void]$lines.Add('OD ' + $o + ' -> ' + [string]$Overrides[$o].derived)
        }
    }
    foreach ($n in @($Entries.Keys | Sort-Object)) { [void]$lines.Add('E ' + $n + ' -> ' + $Entries[$n]) }
    return ($lines -join "`n")
}

$manifest = Resolve-PssaManifest -Explicit $PssaPath
$derived = Get-DerivedRationales -ManifestPath $manifest
$shippedPath = Get-ShippedRationalesPath

if ($Check) {
    if (-not (Test-Path -LiteralPath $shippedPath -PathType Leaf)) {
        [Console]::Error.WriteLine('regen-rule-rationales: shipped rule-rationales.psd1 not found; run without -Check to generate it.')
        exit 1
    }
    $shipped = Import-PowerShellDataFile -LiteralPath $shippedPath
    $shippedEntries = @{}
    foreach ($k in @($shipped['entries'].Keys)) { $shippedEntries[[string]$k] = [string]$shipped['entries'][$k] }
    $shippedOwned = @(@($shipped['owned']) | ForEach-Object { [string]$_ })
    $shippedVersion = [string]$shipped['pssa_version']
    $shippedMax = [int]$shipped['max_length']
    # Rebuild the shipped override map (code -> @{derived; text}); tolerate an absent key so a
    # pre-000125 table drifts loudly (via the OV/OD canonical lines) rather than throwing here.
    $shippedOverrides = @{}
    if ($shipped.ContainsKey('overrides') -and $null -ne $shipped['overrides']) {
        foreach ($k in @($shipped['overrides'].Keys)) {
            $ov = $shipped['overrides'][$k]
            $shippedOverrides[[string]$k] = @{ derived = [string]$ov['derived']; text = [string]$ov['text'] }
        }
    }

    $derivedCanon = Get-RationaleCanonical -Entries $derived.Entries -Owned $derived.Owned -Overrides $derived.Overrides -PssaVersion $derived.PssaVersion -MaxLength $script:MaxLength
    $shippedCanon = Get-RationaleCanonical -Entries $shippedEntries -Owned $shippedOwned -Overrides $shippedOverrides -PssaVersion $shippedVersion -MaxLength $shippedMax
    if ($derivedCanon -eq $shippedCanon) {
        Write-Output ('OK: rulesets/rule-rationales.psd1 matches the derivation (' + @($derived.Entries.Keys).Count +
            ' entries = ' + @($derived.PssaRules).Count + ' PSSA + ' + @($derived.Owned).Count + ' owned; ' +
            @($derived.OverrideKeys).Count + ' overrides applied) at ' + $manifest)
        exit 0
    }
    # Report the drift precisely (entry-level missing/extra/changed + the pin/cap/owned headers).
    if ($shippedVersion -ne $derived.PssaVersion) { Write-Output ('PIN DRIFT: shipped pssa_version=' + $shippedVersion + ', derivation=' + $derived.PssaVersion) }
    if ($shippedMax -ne $script:MaxLength) { Write-Output ('CAP DRIFT: shipped max_length=' + $shippedMax + ', generator=' + $script:MaxLength) }
    $dNames = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)
    foreach ($n in $derived.Entries.Keys) { [void]$dNames.Add([string]$n) }
    $sNames = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)
    foreach ($n in $shippedEntries.Keys) { [void]$sNames.Add([string]$n) }
    $missing = @($derived.Entries.Keys | Where-Object { -not $sNames.Contains([string]$_) } | Sort-Object)
    $extra = @($shippedEntries.Keys | Where-Object { -not $dNames.Contains([string]$_) } | Sort-Object)
    $changed = @($derived.Entries.Keys | Where-Object { $sNames.Contains([string]$_) -and $shippedEntries[[string]$_] -ne $derived.Entries[[string]$_] } | Sort-Object)
    $ownedDiff = (($derived.Owned -join ',') -ne ((@($shippedOwned) | Sort-Object) -join ','))
    if ($missing.Count -gt 0) { Write-Output ('MISSING from shipped (derived, not shipped): ' + ($missing -join ', ')) }
    if ($extra.Count -gt 0) { Write-Output ('EXTRA in shipped (shipped, not derived): ' + ($extra -join ', ')) }
    if ($changed.Count -gt 0) {
        Write-Output ('CHANGED (rationale text differs): ' + ($changed -join ', '))
        foreach ($n in $changed) {
            Write-Output ('  - ' + $n)
            Write-Output ('      shipped: ' + $shippedEntries[$n])
            Write-Output ('      derived: ' + $derived.Entries[$n])
        }
    }
    if ($ownedDiff) { Write-Output ('OWNED LIST drifted: shipped=' + (($shippedOwned | Sort-Object) -join ',') + ' derived=' + ($derived.Owned -join ',')) }
    $overrideDiff = ((@($derived.OverrideKeys) -join ',') -ne ((@($shippedOverrides.Keys) | Sort-Object) -join ','))
    if ($overrideDiff) { Write-Output ('OVERRIDE SET drifted: shipped=' + ((@($shippedOverrides.Keys) | Sort-Object) -join ',') + ' derived=' + (@($derived.OverrideKeys) -join ',')) }
    foreach ($o in @($derived.OverrideKeys)) {
        if ($shippedOverrides.ContainsKey($o) -and ([string]$shippedOverrides[$o].derived -ne [string]$derived.Overrides[$o].derived)) {
            Write-Output ('OVERRIDE BASE drifted for ' + $o + ' (a pin bump changed the derived text under the override):')
            Write-Output ('      shipped derived: ' + $shippedOverrides[$o].derived)
            Write-Output ('      current derived: ' + $derived.Overrides[$o].derived)
        }
    }
    [Console]::Error.WriteLine('regen-rule-rationales: shipped rule-rationales.psd1 DRIFTS from the derivation; re-run without -Check and review.')
    exit 1
}

# Default: (re)write the shipped table.
$text = Format-RationaleFile -Derived $derived
Assert-AsciiText -Text $text -Context 'the generated rule-rationales.psd1' -AllowNewline
$enc = New-Object System.Text.UTF8Encoding($false)   # no BOM
[System.IO.File]::WriteAllText($shippedPath, $text, $enc)
Write-Output ('wrote ' + $shippedPath + ' (' + @($derived.Entries.Keys).Count + ' entries = ' +
    @($derived.PssaRules).Count + ' PSSA + ' + @($derived.Owned).Count + ' owned) at PSScriptAnalyzer ' + $derived.PssaVersion)
