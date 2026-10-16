#Requires -Version 5.1

# lsp-policy.ps1 -- ONE effective-policy resolver for the hook, the daemon and the scan
# (dispatch 000305, B1; enterprise review finding F3).
#
# THE GAP THIS CLOSES. Before this leg, `scripts/lsp-scan.ps1 -OrgPolicyPath` reached only the
# prohibited-suppression pass that runs AFTER the main analysis: the daemon and the per-file hook
# never saw it, so supplying the flag alone did not make RequiredRules, SeverityOverrides or
# ExcludeRules govern a scan's findings, and nothing a scan reported could say which policy the
# analyzer actually ran under. And a valid policy FILE was the only evidence anyone had: a merged-
# settings write that failed, or a RequiredRules version guard that refused, left no trace a
# managed gate could refuse on.
#
# THREE THINGS, KEPT APART (the dispatch's own scope words):
#   requested  what was asked for -- the path, where it came from (cli | knob | daemon), the bytes
#              on disk as read (SHA-256) and the optional <policy>.sha256 sidecar's verdict;
#   effective  the policy that actually governs analysis, in a CANONICAL form, with a SHA-256 of
#              that form (the policy identity) -- equal effective policies produce the same
#              identity however their files are spelled, ordered, cased or commented;
#   applied    what each party MECHANICALLY did with it, recorded by that party: the daemon's
#              RequiredRules version guard, its merged-settings write (re-read and re-hashed) and
#              the settings file it handed PSES; the client's adjudication of the findings. Never
#              inferred from the policy file: a valid file is not evidence of enforcement.
#
# ONE READER UNDERNEATH (Hub Rule 18). Resolve-EffectivePolicy reads the file through the shipped
# Import-OrgPolicy -- the same absolute-path rule, the same <policy>.sha256 integrity gate, the
# same restricted-language parse, the same single fail-open warning -- and never parses it a second
# way. ConvertTo-EffectivePolicy is pure over Import-OrgPolicy's own return value, so the client can
# name the identity of the very object it applies, and so can the daemon.
#
# THE MANAGED SCAN (owner ruling O03, 2026-10-12: managed mode; refuse in managed only; full main
# pass). `lsp-scan.ps1 -PolicyMode closed`, given EXPLICITLY (owner ruling Q03, 2026-10-14, dispatch
# 000306: POWERSHELL_LSP_POLICY_MODE keeps its interactive fail-closed meaning and never makes a scan
# managed) certifies a scan only when a usable DECLARED policy (-OrgPolicyPath) AND proof that each
# party applied it are present; Test-ScanPolicyCertification is that decision, pure over evidence.
# Since dispatch 000306 that proof includes the daemon's verdict that PSScriptAnalyzer accepts the
# settings files the analysis rests on (Read-PssaSettingsFile, lsp-common.ps1).
# Not-required is not failed: a policy with no RequiredRules needs no merged settings file, and
# that is never an enforcement failure. Unmanaged (open) scans keep every 1.x behavior, including
# the documented severity-threshold boundary; they only gain the full main pass O03 approved.
#
# THE TRUST BOUNDARY, STATED ONCE. Everything here runs as the same user as the analyzer. A same-
# user process can edit the policy file, its .sha256 sidecar, this library and the evidence it
# writes; a checksum beside an editable file is integrity EVIDENCE, not an independent root of
# trust. Enforce a release requirement on a protected CI runner whose policy is controlled by
# someone other than the author of the change.
#
# Load-silent: function definitions only (tests/PowerShellLsp.LibPurity.Tests.ps1). Uses
# Import-OrgPolicy, Test-OrgPolicyIntegrity, New-EmptyOrgPolicy, Resolve-SeverityName,
# Get-Sha256HexFromBytes, Get-DiagnosticRuleCode, Get-PolicyModeInfo, Get-OrgPolicyReportInfo,
# Get-PssaDefaultRulesVerifiedForPsesTag and Format-PssaSettingsText from scripts/lib/lsp-common.ps1
# -- dot-source that library first. ASCII-only; StrictMode-safe.
#
# Author: Mike Andersen / powershell-lsp plugin.

# --- field access over both shapes -------------------------------------------

function Get-PolicyField {
    # One read for every shape a policy value takes here: the [hashtable] Import-OrgPolicy returns,
    # the [ordered] records this file builds, and the PSCustomObject ConvertFrom-Json makes of a
    # receipt or a session record. Get-Prop (lsp-common.ps1) sees only PSObject properties -- a
    # dictionary key reads as $null through it -- so it cannot be used for the first two. $null when
    # absent. The value comes back through the comma operator so an array survives the return; assign
    # the result before wrapping it in @(...), or it nests.
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return , $Object[$Name] }
        return $null
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -ne $p) { return , $p.Value }
    return $null
}

function Get-PolicyStringList {
    # A field read as a list of trimmed, non-blank strings, in the order given. Never @($null): an
    # absent field is an empty list (the @($null).Count -eq 1 trap).
    param($Object, [string]$Name)
    $v = Get-PolicyField -Object $Object -Name $Name
    $out = New-Object 'System.Collections.Generic.List[string]'
    if ($null -eq $v) { return , $out.ToArray() }
    foreach ($e in @($v)) {
        if ($e -isnot [string]) { continue }
        $c = $e.Trim()
        if ($c -ne '') { $out.Add($c) }
    }
    return , $out.ToArray()
}

# --- vocabulary ------------------------------------------------------------

function Get-EffectivePolicySchema {
    # The identity's own name and version, the first line of the canonical text. Bump Version only
    # when the canonical text changes shape: every digest computed under the old shape changes.
    return [ordered]@{ Id = 'powershell-lsp/effective-policy'; Version = 1 }
}

function Get-PolicyReasonTable {
    # THE FIXED REASON CODES a policy resolution, an application record or a managed certification
    # can carry. Stage says which of the three it belongs to; Meaning is one line for the docs and
    # the SARIF reader. Every code Test-ScanPolicyCertification can return is in this table (a unit
    # test holds them together), and the resolution codes are exactly the ones Import-OrgPolicy sets.
    $t = [ordered]@{}
    # resolution -- the declared policy could not be used (codes set by Import-OrgPolicy itself)
    $t['policy-not-declared'] = [ordered]@{ Stage = 'resolution'; Meaning = 'managed mode, and no policy was declared with -OrgPolicyPath' }
    $t['policy-path-relative'] = [ordered]@{ Stage = 'resolution'; Meaning = 'the declared policy path is not absolute' }
    $t['policy-file-missing'] = [ordered]@{ Stage = 'resolution'; Meaning = 'no policy file exists at the declared path' }
    $t['policy-integrity-unreadable'] = [ordered]@{ Stage = 'resolution'; Meaning = 'the policy''s .sha256 sidecar could not be read' }
    $t['policy-integrity-malformed'] = [ordered]@{ Stage = 'resolution'; Meaning = 'the policy''s .sha256 sidecar declares no SHA-256 digest' }
    $t['policy-integrity-mismatch'] = [ordered]@{ Stage = 'resolution'; Meaning = 'the policy file does not hash to its .sha256 sidecar' }
    $t['policy-unreadable'] = [ordered]@{ Stage = 'resolution'; Meaning = 'the policy file could not be read or parsed as data (corrupt)' }
    # application -- what the daemon or the client did with it
    $t['policy-activation-unsupported'] = [ordered]@{ Stage = 'application'; Meaning = 'RequiredRules could not be activated: the running PSES version is not one the pinned default rule list was verified for' }
    $t['policy-merge-write-failed'] = [ordered]@{ Stage = 'application'; Meaning = 'RequiredRules needed a merged settings file, and it could not be written and read back intact' }
    $t['policy-activation-not-delivered'] = [ordered]@{ Stage = 'application'; Meaning = 'the merged settings were not handed to PSES, or the settings file changed after they were' }
    $t['policy-disagreement'] = [ordered]@{ Stage = 'application'; Meaning = 'a party applied a policy whose identity differs from the declared one' }
    $t['policy-evidence-missing'] = [ordered]@{ Stage = 'application'; Meaning = 'no application evidence for this file, so whether the policy was applied is unprovable' }
    $t['policy-settings-rejected'] = [ordered]@{ Stage = 'application'; Meaning = 'PSScriptAnalyzer would reject or could not read a settings file this analysis rests on (the repository''s, or the merged one), so the analysis did not run on the settings as declared' }
    $t['policy-suppression-pass-failed'] = [ordered]@{ Stage = 'application'; Meaning = 'the ProhibitedSuppressions pass could not run' }
    # certification -- the managed scan's other preconditions (until A3 binds the declared environment)
    $t['config-ambient'] = [ordered]@{ Stage = 'certification'; Meaning = 'an ambient plugin option that changes analysis reached the scan' }
    $t['config-observed-mismatch'] = [ordered]@{ Stage = 'certification'; Meaning = 'the configuration the daemon reports differs from the configuration the scan declared' }
    $t['engine-unknown'] = [ordered]@{ Stage = 'certification'; Meaning = 'the analysis engine versions could not be observed' }
    $t['analysis-incomplete'] = [ordered]@{ Stage = 'certification'; Meaning = 'the file has no complete completion receipt' }
    $t['analysis-empty'] = [ordered]@{ Stage = 'certification'; Meaning = 'the scan analyzed no PowerShell file, so nothing shows the policy was applied' }
    return $t
}

function Get-PolicyRequiredRuleStates {
    # The states the daemon's RequiredRules record can take. Only 'activated' and 'not-required' are
    # enforcement successes, and they mean different things: activated = merged, verified, handed to
    # PSES; not-required = the effective policy names no required rule, so there was nothing to do.
    # Two since dispatch 000306 (B1b):
    #   settings-rejected    the merged settings file was written, but PSScriptAnalyzer would reject it
    #                        (Read-PssaSettingsFile), so it was not handed to PSES (review finding B1-K04);
    #   settings-unresolved  TERMINAL: resolving the session's settings threw, so nothing -- no settings
    #                        file, no required rule -- was handed to this PSES child. Unlike 'pending'
    #                        (not yet), it does not change until the daemon re-spawns PSES or the session
    #                        restarts (review findings B1-K05, B1-OOB-I01).
    return @('not-configured', 'pending', 'policy-unusable', 'not-required', 'activated',
        'activation-unsupported', 'merge-write-failed', 'not-delivered', 'settings-rejected', 'settings-unresolved')
}

function Get-PolicySettingsValidationStates {
    # What the daemon's record says about the settings files its analysis rests on (dispatch 000306,
    # B1b, review finding B1-K04) -- settings.validation, checked BEFORE PSES is handed anything:
    #   pending     not resolved yet (the record a daemon starts with, and returns to on a PSES re-spawn);
    #   none        no settings file was resolved: PSES runs its own default rules;
    #   valid       PSScriptAnalyzer accepts every settings file in play -- the repository's (or the
    #               override or the shipped base ruleset) and, when RequiredRules merged, the merged one;
    #   rejected    one of them holds a key or a value PSScriptAnalyzer refuses;
    #   unparsable  one of them could not be read as a settings table at all;
    #   unresolved  resolving the session's settings threw (with RequiredRules 'settings-unresolved').
    # Only 'valid' and 'none' let a managed scan certify.
    return @('pending', 'none', 'valid', 'rejected', 'unparsable', 'unresolved')
}

# --- the effective policy and its identity ------------------------------------

function ConvertTo-EffectivePolicy {
    # PURE: the policy that GOVERNS analysis, from Import-OrgPolicy's own return value -- never a
    # second read of the file. Every member is trimmed, de-duplicated case-insensitively and sorted
    # (ordinal, case-insensitive), so its order no longer depends on how the file was written.
    # Exclusion is the stronger verb, exactly as it is where the policy is applied: a rule the policy
    # both requires and excludes is not required (Merge-RequiredRulesSettings drops it), and an
    # override on an excluded rule is moot (Select-OrgPolicyFiltered drops the finding before
    # Set-OrgPolicySeverity could re-stamp it) -- so neither survives into the effective form, and
    # two files that enforce the same thing have one identity. Severity names are canonical
    # (Resolve-SeverityName). ProhibitedSuppressions is kept as declared: both of its enforcement
    # points act on the suppression attribute, which an exclusion of the rule does not remove.
    param($Policy)
    $comparer = [System.StringComparer]::OrdinalIgnoreCase
    $excluded = New-Object 'System.Collections.Generic.HashSet[string]' ($comparer)
    $ex = New-Object 'System.Collections.Generic.List[string]'
    foreach ($c in (Get-PolicyStringList -Object $Policy -Name 'ExcludeRules')) { if ($excluded.Add($c)) { $ex.Add($c) } }
    $rq = New-Object 'System.Collections.Generic.List[string]'
    $seenReq = New-Object 'System.Collections.Generic.HashSet[string]' ($comparer)
    foreach ($c in (Get-PolicyStringList -Object $Policy -Name 'RequiredRules')) {
        if ($excluded.Contains($c)) { continue }   # required AND excluded: exclusion wins
        if ($seenReq.Add($c)) { $rq.Add($c) }
    }
    $pr = New-Object 'System.Collections.Generic.List[string]'
    $seenPro = New-Object 'System.Collections.Generic.HashSet[string]' ($comparer)
    foreach ($c in (Get-PolicyStringList -Object $Policy -Name 'ProhibitedSuppressions')) { if ($seenPro.Add($c)) { $pr.Add($c) } }

    $overrides = [ordered]@{}
    $sevTable = Get-PolicyField -Object $Policy -Name 'SeverityOverrides'
    if ($sevTable -is [System.Collections.IDictionary]) {
        $map = New-Object 'System.Collections.Generic.Dictionary[string,string]' ($comparer)
        $keys = New-Object 'System.Collections.Generic.List[string]'
        foreach ($orig in @($sevTable.Keys)) {
            if ($orig -isnot [string]) { continue }
            $k = $orig.Trim()
            if ($k -eq '' -or $excluded.Contains($k) -or $map.ContainsKey($k)) { continue }   # excluded: moot
            $v = $sevTable[$orig]
            if ($v -isnot [string]) { continue }
            $canon = Resolve-SeverityName $v
            if ($canon -eq '') { continue }
            $map[$k] = $canon
            $keys.Add($k)
        }
        $ka = $keys.ToArray()
        [System.Array]::Sort($ka, $comparer)
        foreach ($k in $ka) { $overrides[$k] = $map[$k] }
    }
    $exA = $ex.ToArray(); [System.Array]::Sort($exA, $comparer)
    $rqA = $rq.ToArray(); [System.Array]::Sort($rqA, $comparer)
    $prA = $pr.ToArray(); [System.Array]::Sort($prA, $comparer)
    return [ordered]@{
        ExcludeRules           = $exA
        SeverityOverrides      = $overrides
        RequiredRules          = $rqA
        ProhibitedSuppressions = $prA
    }
}

function Get-EffectivePolicyOverrides {
    # The effective SeverityOverrides as [ordered] name -> severity, from either shape (a fresh
    # [ordered] table, or the PSCustomObject a JSON round trip makes of one).
    param($Effective)
    $out = [ordered]@{}
    $ov = Get-PolicyField -Object $Effective -Name 'SeverityOverrides'
    if ($ov -is [System.Collections.IDictionary]) {
        foreach ($k in @($ov.Keys)) { $out[[string]$k] = [string]$ov[$k] }
    } elseif ($null -ne $ov) {
        foreach ($p in @($ov.PSObject.Properties)) { $out[[string]$p.Name] = [string]$p.Value }
    }
    return $out
}

function ConvertTo-AsciiLowerCase {
    # $Text with ASCII 'A'-'Z' folded to 'a'-'z' and every other character left exactly as it is: the
    # rule-code fold of the canonical text, computed the same way on every host (dispatch 000305, B1,
    # review finding B1-R01). Never ToLowerInvariant -- it folds U+212A KELVIN SIGN to 'k' on
    # PowerShell 7 and not on Windows PowerShell 5.1 (measured on 7.6.6 and 5.1.26100), so one policy
    # file had two identities, and on PowerShell 7 a code that OrdinalIgnoreCase does not match to a
    # rule shared that rule's line.
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return [string]$Text }
    $chars = $Text.ToCharArray()
    for ($i = 0; $i -lt $chars.Length; $i++) {
        $n = [int]$chars[$i]
        if ($n -ge 65 -and $n -le 90) { $chars[$i] = [char]($n + 32) }
    }
    return (-join $chars)
}

function ConvertTo-EffectivePolicyText {
    # THE CANONICAL HASHING RULES, as one function. The identity is the SHA-256 of this text:
    #   - the first line is '<schema id> <version>' (Get-EffectivePolicySchema);
    #   - then one line per member, in four sections in this fixed order: exclude, override,
    #     prohibit, require;
    #   - a line is the verb, a TAB, the rule code with ASCII A-Z folded to a-z and nothing else
    #     folded (ConvertTo-AsciiLowerCase), and for an override a TAB and the canonical severity
    #     name (Error / Warning / Information / Hint);
    #   - within a section, lines are sorted ordinally;
    #   - lines end in LF, including the last; the text is encoded as UTF-8 without a BOM.
    # Rule codes are folded because they match case-insensitively everywhere the policy is applied
    # (the client drop and re-stamp, the merge, and PSScriptAnalyzer's own rule selection), so two
    # spellings of one code are one policy. Built by concatenation, never ConvertTo-Json: Windows
    # PowerShell 5.1 and PowerShell 7 serialize JSON differently, and the daemon, the client and the
    # scan may run under different hosts.
    # INJECTIVE AND HOST-INDEPENDENT (review finding B1-R01). Every code here is a rule name --
    # Import-OrgPolicy refuses a policy naming anything else as unreadable (Test-OrgPolicyRuleCode,
    # lsp-common.ps1) -- so no code holds the TAB or LF that separate fields and lines, and two
    # different effective policies always render two different texts. And every code is ASCII, so
    # folding A-Z alone is exactly the OrdinalIgnoreCase equality the enforcement points use, and
    # every host computes the same text from the same policy.
    param($Effective)
    $schema = Get-EffectivePolicySchema
    $tab = [string][char]9
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add([string]$schema.Id + ' ' + [string]$schema.Version)
    $ov = Get-EffectivePolicyOverrides -Effective $Effective
    $exclude = New-Object 'System.Collections.Generic.List[string]'
    foreach ($c in (Get-PolicyStringList -Object $Effective -Name 'ExcludeRules')) { $exclude.Add('exclude' + $tab + (ConvertTo-AsciiLowerCase $c)) }
    $override = New-Object 'System.Collections.Generic.List[string]'
    foreach ($k in @($ov.Keys)) {
        $code = ([string]$k).Trim()
        $override.Add('override' + $tab + (ConvertTo-AsciiLowerCase $code) + $tab + [string]$ov[$k])
    }
    $prohibit = New-Object 'System.Collections.Generic.List[string]'
    foreach ($c in (Get-PolicyStringList -Object $Effective -Name 'ProhibitedSuppressions')) { $prohibit.Add('prohibit' + $tab + (ConvertTo-AsciiLowerCase $c)) }
    $require = New-Object 'System.Collections.Generic.List[string]'
    foreach ($c in (Get-PolicyStringList -Object $Effective -Name 'RequiredRules')) { $require.Add('require' + $tab + (ConvertTo-AsciiLowerCase $c)) }
    foreach ($section in @($exclude, $override, $prohibit, $require)) {
        $arr = $section.ToArray()
        [System.Array]::Sort($arr, [System.StringComparer]::Ordinal)
        foreach ($l in $arr) { $lines.Add($l) }
    }
    return (($lines.ToArray()) -join "`n") + "`n"
}

function Get-EffectivePolicyDigest {
    # The policy identity: lower-case hex SHA-256 of ConvertTo-EffectivePolicyText's UTF-8 bytes.
    param($Effective)
    $text = ConvertTo-EffectivePolicyText -Effective $Effective
    return (Get-Sha256HexFromBytes -Bytes ((New-Object System.Text.UTF8Encoding($false)).GetBytes($text)))
}

function Get-PolicyObligations {
    # What applying an effective policy REQUIRES, so evidence can say "not required" without that
    # ever reading as "failed" (the dispatch's not-required/failed distinction):
    #   mergedSettings      'required' only when the effective policy names a required rule -- the one
    #                       member that needs the daemon to write and hand PSES a merged settings file;
    #   clientAdjudication  'required' when it excludes, overrides or prohibits anything -- the members
    #                       the per-file client applies to the findings;
    #   suppressionPass     'required' when it prohibits a suppression -- the scan's restricted
    #                       -IncludeSuppressed pass.
    # A usable policy with none of these -- a valid no-op file -- requires nothing and fails nothing.
    param($Effective, [bool]$Usable = $true)
    # Each list is ASSIGNED before it is counted: Get-PolicyStringList returns its array through the
    # comma operator, and @(Get-PolicyStringList ...) would nest it -- a Count of 1 for every list.
    $reqList = Get-PolicyStringList -Object $Effective -Name 'RequiredRules'
    $excList = Get-PolicyStringList -Object $Effective -Name 'ExcludeRules'
    $proList = Get-PolicyStringList -Object $Effective -Name 'ProhibitedSuppressions'
    $req = $reqList.Count
    $exc = $excList.Count
    $pro = $proList.Count
    $ov = @((Get-EffectivePolicyOverrides -Effective $Effective).Keys).Count
    return [ordered]@{
        mergedSettings     = $(if ($Usable -and $req -gt 0) { 'required' } else { 'not-required' })
        clientAdjudication = $(if ($Usable -and ($exc + $ov + $pro) -gt 0) { 'required' } else { 'not-required' })
        suppressionPass    = $(if ($Usable -and $pro -gt 0) { 'required' } else { 'not-required' })
    }
}

function Get-PolicyFileSha256 {
    # Lower-case hex SHA-256 of a file's bytes as read now, or '' when there is no readable file at
    # an absolute path. Never throws.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    try {
        if (-not [System.IO.Path]::IsPathRooted($Path)) { return '' }
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
        return (Get-Sha256HexFromBytes -Bytes ([System.IO.File]::ReadAllBytes($Path)))
    } catch { return '' }
}

function New-PolicyResolution {
    # The resolution record, from a policy value ALREADY read by Import-OrgPolicy plus that read's
    # warning and reason code. Shared by Resolve-EffectivePolicy (which does the read) and the client
    # (which already did it once per hook process and must name the identity of the object it
    # applies, not of a second read). A configured but unusable policy has NO identity: a managed
    # gate must never be able to certify "the empty policy" in place of one that failed to load.
    param($Policy, [string]$Path = '', [string]$Source = 'knob', [string]$Warning = '', [string]$Reason = '',
        [string]$FileSha256 = '', [string]$Sidecar = 'not-present')
    $configured = -not [string]::IsNullOrWhiteSpace($Path)
    $usable = $configured -and [string]::IsNullOrWhiteSpace($Warning)
    $effective = ConvertTo-EffectivePolicy -Policy $(if ($usable) { $Policy } else { New-EmptyOrgPolicy })
    $schema = Get-EffectivePolicySchema
    $r = ''
    if ($configured -and -not $usable) { $r = $(if (-not [string]::IsNullOrWhiteSpace($Reason)) { $Reason } else { 'policy-unreadable' }) }
    return [ordered]@{
        requested   = [ordered]@{ source = [string]$Source; path = [string]$Path; configured = $configured; fileSha256 = [string]$FileSha256; sidecar = [string]$Sidecar }
        usable      = $usable
        reason      = $r
        warning     = [string]$Warning
        effective   = $effective
        identity    = [ordered]@{ schema = [string]$schema.Id; version = [int]$schema.Version; sha256 = $(if ($usable) { Get-EffectivePolicyDigest -Effective $effective } else { '' }) }
        obligations = (Get-PolicyObligations -Effective $effective -Usable $usable)
    }
}

function Resolve-EffectivePolicy {
    # THE RESOLVER. Reads the policy at $Path through the shipped Import-OrgPolicy (every safety and
    # integrity behavior unchanged) and returns, as one [ordered] value:
    #   requested   source ($Source verbatim: cli | knob | daemon), path (verbatim), configured, the
    #               SHA-256 of the file as read ('' when there is none) and the sidecar verdict
    #               (not-present | match | mismatch -- Test-OrgPolicyIntegrity's own, never re-derived);
    #   usable      configured and read without a degrade;
    #   reason      '' or the fixed code Import-OrgPolicy set (Get-PolicyReasonTable); '' when the
    #               policy is simply not configured -- "not declared" is the managed scan's verdict,
    #               not a property of an empty path;
    #   warning     Import-OrgPolicy's own prose, '' when it did not degrade;
    #   effective   ConvertTo-EffectivePolicy over what was read (empty when not usable);
    #   identity    schema, version and sha256 -- the policy identity, '' when not usable;
    #   obligations Get-PolicyObligations.
    param([string]$Path, [string]$Source = 'knob')
    $warning = ''
    $code = ''
    $pol = Import-OrgPolicy -Path $Path -WarningOut ([ref]$warning) -ReasonOut ([ref]$code)
    $fileSha = ''
    $sidecar = 'not-present'
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $full = ''
        try { if ([System.IO.Path]::IsPathRooted($Path)) { $full = [System.IO.Path]::GetFullPath($Path) } } catch { $full = '' }
        if ($full -ne '') {
            $fileSha = Get-PolicyFileSha256 -Path $full
            if (Test-Path -LiteralPath ($full + '.sha256') -PathType Leaf) {
                $sidecar = $(if ((Test-OrgPolicyIntegrity -PolicyPath $full) -eq '') { 'match' } else { 'mismatch' })
            }
        }
    }
    return (New-PolicyResolution -Policy $pol -Path $Path -Source $Source -Warning $warning -Reason $code `
            -FileSha256 $fileSha -Sidecar $sidecar)
}

function New-PolicyResolutionSummary {
    # The compact form of a resolution every evidence record carries: the path, configured, usable,
    # reason and the effective identity. One builder, so the daemon, the client and the scan can
    # never spell it three ways.
    param($Resolution = $null, [string]$Path = '')
    if ($null -eq $Resolution) {
        return [ordered]@{ path = [string]$Path; configured = $false; usable = $false; reason = ''; effectiveSha256 = '' }
    }
    return [ordered]@{
        path            = [string]$Resolution.requested.path
        configured      = [bool]$Resolution.requested.configured
        usable          = [bool]$Resolution.usable
        reason          = [string]$Resolution.reason
        effectiveSha256 = [string]$Resolution.identity.sha256
    }
}

# --- application evidence ---------------------------------------------------

function New-PolicyApplicationEvidence {
    # DAEMON SIDE, pure: the record of what the daemon did with the policy it was launched with --
    # carried in a scan-mode diagnostics binding and in the daemon's session file (doctor reads it).
    #   resolution     New-PolicyResolutionSummary of the daemon's OWN read of the policy;
    #   requiredRules  state (Get-PolicyRequiredRuleStates), the effective count, the version guard
    #                  (verifiedFor = the tag the pinned default list was verified against, observed =
    #                  the PSES version the daemon read from the manifest it launches, result = pass |
    #                  refused | not-needed, '' when not evaluated), and the merged settings file it
    #                  wrote and verified (path, SHA-256 as re-read);
    #   settings       the settings file PSES was told to use (path; source = merged | resolved |
    #                  none; SHA-256 as read when this record was made) and whether the push to PSES
    #                  was sent (delivered); and, since dispatch 000306, validation -- what the daemon
    #                  found when it checked the settings files in play against what PSScriptAnalyzer
    #                  accepts, before PSES saw any (Get-PolicySettingsValidationStates) -- with
    #                  validationDetail, '' or one ASCII line naming which file and its first problem.
    # Every value is passed in; nothing here reads a file, so the record says only what the daemon
    # observed. An omitted validation reads 'pending' -- not checked -- never 'valid' or 'none'.
    param(
        $Resolution = $null,
        [string]$Path = '',
        [string]$RequiredState = 'not-configured',
        [int]$RequiredCount = 0,
        [string]$GuardVerifiedFor = '',
        [string]$GuardObserved = '',
        [string]$GuardResult = '',
        [string]$MergedPath = '',
        [string]$MergedSha256 = '',
        [string]$SettingsPath = '',
        [string]$SettingsSource = 'none',
        [string]$SettingsSha256 = '',
        [bool]$Delivered = $false,
        [string]$SettingsValidation = 'pending',
        [string]$SettingsValidationDetail = ''
    )
    if ((Get-PolicyRequiredRuleStates) -notcontains $RequiredState) { $RequiredState = 'pending' }
    if ((Get-PolicySettingsValidationStates) -cnotcontains $SettingsValidation) { $SettingsValidation = 'pending' }
    return [ordered]@{
        resolution    = (New-PolicyResolutionSummary -Resolution $Resolution -Path $Path)
        requiredRules = [ordered]@{
            state                = $RequiredState
            count                = [Math]::Max(0, $RequiredCount)
            guard                = [ordered]@{ verifiedFor = [string]$GuardVerifiedFor; observed = [string]$GuardObserved; result = [string]$GuardResult }
            mergedSettingsPath   = [string]$MergedPath
            mergedSettingsSha256 = [string]$MergedSha256
        }
        settings      = [ordered]@{ path = [string]$SettingsPath; source = [string]$SettingsSource; sha256 = [string]$SettingsSha256; delivered = $Delivered
            validation = $SettingsValidation; validationDetail = (Format-PssaSettingsText $SettingsValidationDetail 200)
        }
    }
}

function New-PolicyStartupEvidence {
    # The record a daemon holds before it has resolved anything: from startup, and again after every
    # supervised PSES re-spawn (Reset-PsesState, dispatch 000306, review finding B1-K05) -- 'pending', or
    # 'not-configured' for a daemon launched with no policy, carrying no resolution and settings
    # validation 'pending'. ONE builder for both, so a re-spawned PSES child can never inherit the
    # previous child's agreeing evidence: until Initialize-PssaSettings runs again for the new child,
    # every reader sees not-yet-applied (policy-evidence-missing to a managed scan, pending to doctor).
    param([string]$Path = '')
    return (New-PolicyApplicationEvidence -Path $Path `
            -RequiredState $(if ([string]::IsNullOrWhiteSpace($Path)) { 'not-configured' } else { 'pending' }) `
            -GuardVerifiedFor (Get-PssaDefaultRulesVerifiedForPsesTag) -SettingsValidation 'pending')
}

function Copy-PolicyApplicationEvidence {
    # A copy of a daemon record with the settings file's SHA-256 replaced by $SettingsSha256 -- what a
    # scan-mode answer carries, so the identity it reports is of the file PSScriptAnalyzer reads at
    # THAT analysis (PSES hands it the settings path on every pass), not of the file as it was when
    # the session's settings were first resolved. The settings validation verdict rides unchanged.
    param($Evidence, [string]$SettingsSha256 = '')
    if ($null -eq $Evidence) { return $null }
    $st = Get-PolicyField -Object $Evidence -Name 'settings'
    $settings = [ordered]@{
        path             = [string](Get-PolicyField -Object $st -Name 'path')
        source           = [string](Get-PolicyField -Object $st -Name 'source')
        sha256           = [string]$SettingsSha256
        delivered        = [bool](Get-PolicyField -Object $st -Name 'delivered')
        validation       = [string](Get-PolicyField -Object $st -Name 'validation')
        validationDetail = [string](Get-PolicyField -Object $st -Name 'validationDetail')
    }
    return [ordered]@{
        resolution    = (Get-PolicyField -Object $Evidence -Name 'resolution')
        requiredRules = (Get-PolicyField -Object $Evidence -Name 'requiredRules')
        settings      = $settings
    }
}

function New-PolicyAdjudicationEvidence {
    # CLIENT SIDE, pure: what the per-file client did with the policy it read -- the identity of the
    # object it applied (computed from that object, never a second read), the policy mode it ran
    # under, whether that mode failed this request closed, and how many findings the policy actually
    # touched on this file: dropped (ExcludeRules), restamped (SeverityOverrides) and the
    # ProhibitedSuppression findings it raised. Counts are of THIS request's findings; zero is a
    # valid observation (the file simply had nothing the policy acts on).
    param(
        $Resolution = $null,
        [string]$Path = '',
        [string]$Mode = 'open',
        [bool]$FailClosed = $false,
        [int]$Dropped = 0,
        [int]$Restamped = 0,
        [int]$ProhibitedFlagged = 0
    )
    return [ordered]@{
        resolution        = (New-PolicyResolutionSummary -Resolution $Resolution -Path $Path)
        mode              = [string]$Mode
        failClosed        = $FailClosed
        dropped           = [Math]::Max(0, $Dropped)
        restamped         = [Math]::Max(0, $Restamped)
        prohibitedFlagged = [Math]::Max(0, $ProhibitedFlagged)
    }
}

function Measure-PolicyOverrideHits {
    # How many of $Records carry a rule code $OrgSeverity overrides -- the records
    # Set-OrgPolicySeverity re-stamps. Same accessor and the same case-insensitive match.
    param([object[]]$Records, [hashtable]$OrgSeverity = @{})
    if ($null -eq $Records -or $null -eq $OrgSeverity -or $OrgSeverity.Count -eq 0) { return 0 }
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($k in @($OrgSeverity.Keys)) {
        if ($null -eq $k) { continue }
        if ((Resolve-SeverityName ([string]$OrgSeverity[$k])) -eq '') { continue }
        $rule = ([string]$k).Trim()
        if ($rule -ne '') { [void]$set.Add($rule) }
    }
    $n = 0
    foreach ($r in @($Records)) {
        if ($null -eq $r) { continue }
        $code = Get-DiagnosticRuleCode $r
        if (-not [string]::IsNullOrWhiteSpace($code) -and $set.Contains($code)) { $n++ }
    }
    return $n
}

# --- the managed scan ------------------------------------------------------------

function Resolve-ScanPolicyMode {
    # The scan's policy mode: an EXPLICIT -PolicyMode, else open. closed is the MANAGED mode. Returns
    # resolved (open | closed), source (cli | default) and the raw POWERSHELL_LSP_POLICY_MODE value,
    # reported for the record only. The CLI parameter is validated by its own ValidateSet; an
    # unrecognized value reaching here falls back to open.
    #
    # EXPLICIT ONLY (owner ruling Q03, 2026-10-14; dispatch 000306, review finding B1-Q03). B1 first
    # took the mode from POWERSHELL_LSP_POLICY_MODE when -PolicyMode was absent, so a host that set it
    # for interactive fail-closed enforcement -- the variable docs/fleet-deployment.md points fleets at
    # -- ran every scan managed, /powershell-lsp:scan included, and every such scan without
    # -OrgPolicyPath read NOT CERTIFIED. The variable keeps its interactive meaning (the hook fails an
    # edit closed over a configured policy that does not validate) and never selects a managed scan; a
    # gate that wants a certified result says so on its own command line.
    param([string]$Explicit = '')
    $raw = [string](Get-PolicyModeInfo).raw
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) {
        $n = $Explicit.Trim().ToLowerInvariant()
        if ($n -eq 'open' -or $n -eq 'closed') {
            return [ordered]@{ resolved = $n; source = 'cli'; raw = $raw }
        }
    }
    return [ordered]@{ resolved = 'open'; source = 'default'; raw = $raw }
}

function Get-ScanAmbientAnalysisOptions {
    # PURE over an environment dictionary: the CLAUDE_PLUGIN_OPTION_* variables present that would
    # change what a scan analyses, by NAME (never value -- a value can be a path), sorted. This is the
    # managed scan's refusal for "ambient-narrowed" results until A3 replaces inheritance with a
    # declared child configuration: a scan's children inherit this process's environment, and the
    # option resolver (Get-RawPluginOption) accepts any spelling that normalizes to a knob --
    # underscores stripped, case ignored -- so every spelling is matched here the same way.
    #
    # Analysis-affecting knobs are the ones that change the finding set, the rule set or the host:
    # ps_host, severityThreshold, ruleInclude, ruleExclude, perFileCap, settingsPath, scopeToEdit,
    # editContextLines, ruleset, moduleAwareness, referenceSurfacing, profile, timeoutMs and orgPolicy.
    # Exempt: formatOnEdit, contained off in every scan child under every spelling (dispatch 000304);
    # orgPolicy when the scan DECLARES a policy, because then every spelling is removed and the
    # declared path set in each child (Set-ScanChildPolicy). A value equal to the one the scan itself
    # declares (severityThreshold Hint, perFileCap 0, scopeToEdit false, timeoutMs 18000, profile
    # safe) changes nothing, whichever spelling wins, and is not reported.
    param([System.Collections.IDictionary]$Environment, [bool]$PolicyDeclared = $false)
    $affecting = @('pshost', 'severitythreshold', 'ruleinclude', 'ruleexclude', 'perfilecap', 'settingspath',
        'scopetoedit', 'editcontextlines', 'ruleset', 'moduleawareness', 'referencesurfacing', 'profile',
        'timeoutms', 'orgpolicy')
    $declared = @{ severitythreshold = 'hint'; perfilecap = '0'; scopetoedit = 'false'; timeoutms = '18000'; profile = 'safe' }
    $prefix = 'CLAUDE_PLUGIN_OPTION_'
    $out = New-Object 'System.Collections.Generic.List[string]'
    if ($null -ne $Environment) {
        foreach ($k in @($Environment.Keys)) {
            $name = [string]$k
            if (-not $name.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $knob = ($name.Substring($prefix.Length) -replace '_', '').ToLowerInvariant()
            if ($affecting -notcontains $knob) { continue }
            if ($knob -eq 'orgpolicy' -and $PolicyDeclared) { continue }
            $val = [string]$Environment[$k]
            if ([string]::IsNullOrWhiteSpace($val)) { continue }
            if ($declared.ContainsKey($knob) -and $val.Trim().ToLowerInvariant() -eq $declared[$knob]) { continue }
            $out.Add($name)
        }
    }
    $arr = $out.ToArray()
    [System.Array]::Sort($arr, [System.StringComparer]::Ordinal)
    return $arr   # an ordinary pipeline return: wrap the call in @(...) -- an empty result is $null
}

function Get-ScanDeclaredAnalysisConfiguration {
    # The analysis configuration the scan DECLARES to its daemon (Start-ScanDaemon's own overrides),
    # keyed as the daemon reports its launch configuration. A managed scan compares the two per file.
    return [ordered]@{ severityThreshold = 'Hint'; ruleInclude = ''; ruleExclude = ''; perFileCap = '0' }
}

function Test-ScanPolicyCertification {
    # THE MANAGED VERDICT, pure over evidence the scan already holds. Returns
    #   @{ Mode; Managed; Certified ($true | $false, $null when not managed); Reasons (run level,
    #      sorted); Files (one @{ File; Reasons } per file with any reason); AllReasons }.
    #
    # Not managed (open): nothing is certified or refused -- the 1.x contract. Managed (closed): the
    # scan is certified only when every one of these holds, each failure its own code:
    #   run level   a policy was declared (policy-not-declared); it is usable (its resolution code);
    #               no ambient analysis option reached the scan (config-ambient); a required
    #               suppression pass ran (policy-suppression-pass-failed); at least one file was
    #               analyzed (analysis-empty) -- with no file there is no evidence the policy was
    #               applied, and O03 certifies only on that proof, so a managed gate pointed at a
    #               directory with no PowerShell in it never reads CERTIFIED;
    #   per file    the file's receipt is complete (analysis-incomplete); it carries application
    #               evidence (policy-evidence-missing -- also when the daemon's record is still the
    #               'pending' one it starts with, which has resolved nothing yet and so cannot
    #               disagree, or the terminal 'settings-unresolved' one a daemon whose settings
    #               resolution threw now records, or carries no settings verdict); the client
    #               adjudicated, and the daemon
    #               applied, the DECLARED identity (policy-disagreement); when the policy requires a
    #               merged settings file, the daemon activated it -- guard passed, written and
    #               verified, delivered, and the file PSES reads still hashes to what was written
    #               (policy-activation-unsupported / policy-merge-write-failed /
    #               policy-activation-not-delivered); PSScriptAnalyzer accepts every settings file the
    #               analysis rests on, the repository's and the merged one, by the daemon's own check
    #               before PSES saw them (policy-settings-rejected, dispatch 000306); the daemon's
    #               observed analysis configuration is the declared one (config-observed-mismatch); the
    #               engine versions were observed (engine-unknown).
    # When the policy needs no merged settings, the daemon reporting 'not-required' is a pass: an
    # empty RequiredRules set is not an enforcement failure.
    #
    # $Files entries carry File, Completeness, Pass and Receipt (the parsed receipt, $null when none).
    param(
        [string]$Mode = 'open',
        $Declared = $null,
        [string[]]$Ambient = @(),
        [string]$SuppressionPass = 'not-required',
        [object[]]$Files = @()
    )
    if ($Mode -ne 'closed') {
        return [pscustomobject]@{ Mode = $Mode; Managed = $false; Certified = $null; Reasons = @(); Files = @(); AllReasons = @() }
    }
    $run = New-Object 'System.Collections.Generic.List[string]'
    $usable = $false
    $declaredSha = ''
    $needsMerge = $false
    if ($null -eq $Declared -or -not [bool]$Declared.requested.configured) {
        $run.Add('policy-not-declared')
    } elseif (-not [bool]$Declared.usable) {
        $run.Add($(if ([string]::IsNullOrWhiteSpace([string]$Declared.reason)) { 'policy-unreadable' } else { [string]$Declared.reason }))
    } else {
        $usable = $true
        $declaredSha = [string]$Declared.identity.sha256
        $needsMerge = ([string]$Declared.obligations.mergedSettings -eq 'required')
    }
    if (@($Ambient | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) { $run.Add('config-ambient') }
    if ($SuppressionPass -eq 'failed') { $run.Add('policy-suppression-pass-failed') }
    if (@($Files | Where-Object { $null -ne $_ }).Count -eq 0) { $run.Add('analysis-empty') }
    $want = Get-ScanDeclaredAnalysisConfiguration

    $fileOut = New-Object System.Collections.ArrayList
    foreach ($f in @($Files)) {
        if ($null -eq $f) { continue }
        $r = New-Object 'System.Collections.Generic.List[string]'
        $pass = [string](Get-PolicyField -Object $f -Name 'Pass')
        if ([string](Get-PolicyField -Object $f -Name 'Completeness') -ne 'complete') { $r.Add('analysis-incomplete') }
        $receipt = Get-PolicyField -Object $f -Name 'Receipt'
        $pol = Get-PolicyField -Object $receipt -Name 'policy'
        $client = $null
        $daemon = $null
        if ([string](Get-PolicyField -Object $pol -Name 'state') -eq 'observed') {
            $client = Get-PolicyField -Object $pol -Name 'client'
            $daemon = Get-PolicyField -Object $pol -Name 'daemon'
        }
        if ($usable) {
            if ($null -eq $client) {
                $r.Add('policy-evidence-missing')
            } else {
                $cr = Get-PolicyField -Object $client -Name 'resolution'
                if ((Get-PolicyField -Object $cr -Name 'usable') -ne $true -or
                    [string](Get-PolicyField -Object $cr -Name 'effectiveSha256') -cne $declaredSha) { $r.Add('policy-disagreement') }
            }
            if ($pass -eq 'pssa') {
                $rr = Get-PolicyField -Object $daemon -Name 'requiredRules'
                $state = [string](Get-PolicyField -Object $rr -Name 'state')
                if ($null -eq $daemon -or $state -eq 'pending' -or $state -eq 'settings-unresolved') {
                    # pending: nothing resolved YET. settings-unresolved (dispatch 000306): resolving the
                    # session's settings threw, so NOTHING was handed to this PSES child -- terminal, and
                    # what a re-spawned child whose resolution throws now records instead of keeping the
                    # previous child's agreeing evidence (review findings B1-K05, B1-OOB-I01). Neither
                    # record carries a resolution, so neither can disagree: both are missing evidence.
                    $r.Add('policy-evidence-missing')
                } else {
                    $dr = Get-PolicyField -Object $daemon -Name 'resolution'
                    if ((Get-PolicyField -Object $dr -Name 'usable') -ne $true -or
                        [string](Get-PolicyField -Object $dr -Name 'effectiveSha256') -cne $declaredSha) { $r.Add('policy-disagreement') }
                    if ($needsMerge) {
                        switch ($state) {
                            'activated' {
                                $st = Get-PolicyField -Object $daemon -Name 'settings'
                                $merged = [string](Get-PolicyField -Object $rr -Name 'mergedSettingsSha256')
                                if ([string](Get-PolicyField -Object $st -Name 'source') -ne 'merged' -or
                                    (Get-PolicyField -Object $st -Name 'delivered') -ne $true -or
                                    [string]::IsNullOrWhiteSpace($merged) -or
                                    [string](Get-PolicyField -Object $st -Name 'sha256') -cne $merged) {
                                    $r.Add('policy-activation-not-delivered')
                                }
                            }
                            'activation-unsupported' { $r.Add('policy-activation-unsupported') }
                            'merge-write-failed' { $r.Add('policy-merge-write-failed') }
                            'not-delivered' { $r.Add('policy-activation-not-delivered') }
                            'settings-rejected' { $r.Add('policy-settings-rejected') }
                            default { $r.Add('policy-evidence-missing') }
                        }
                    } elseif ($state -ne 'not-required') {
                        $r.Add('policy-disagreement')
                    }
                    # The settings files this analysis rests on (dispatch 000306, review finding B1-K04):
                    # a settings file PSScriptAnalyzer refuses makes PSES analyze nothing and still publish
                    # a settled, empty result, and one whose rejected entries a merge dropped is not the
                    # configuration the repository declared -- so only the daemon's own verdict that every
                    # settings file in play is accepted ('valid'), or that there was none ('none'),
                    # certifies. Anything else -- including a record that carries no verdict -- does not.
                    switch -CaseSensitive ([string](Get-PolicyField -Object (Get-PolicyField -Object $daemon -Name 'settings') -Name 'validation')) {
                        'valid' { }
                        'none' { }
                        'rejected' { $r.Add('policy-settings-rejected') }
                        'unparsable' { $r.Add('policy-settings-rejected') }
                        default { $r.Add('policy-evidence-missing') }
                    }
                }
            }
        }
        if ($null -ne $receipt -and $pass -eq 'pssa') {
            $cfg = Get-PolicyField -Object (Get-PolicyField -Object $receipt -Name 'config') -Name 'observed'
            if ($null -eq $cfg) {
                $r.Add('config-observed-mismatch')
            } else {
                foreach ($k in @($want.Keys)) {
                    if ([string](Get-PolicyField -Object $cfg -Name $k) -cne [string]$want[$k]) { $r.Add('config-observed-mismatch'); break }
                }
            }
            $eng = Get-PolicyField -Object $receipt -Name 'engine'
            $pses = [string](Get-PolicyField -Object $eng -Name 'pses')
            $pssa = [string](Get-PolicyField -Object $eng -Name 'pssa')
            if ($pses -eq '' -or $pses -eq 'unknown' -or $pssa -eq '' -or $pssa -eq 'unknown') { $r.Add('engine-unknown') }
        }
        if ($r.Count -gt 0) {
            [void]$fileOut.Add([pscustomobject]@{ File = [string](Get-PolicyField -Object $f -Name 'File'); Reasons = @($r.ToArray() | Sort-Object -Unique) })
        }
    }
    $runArr = @($run.ToArray() | Sort-Object -Unique)
    $all = New-Object 'System.Collections.Generic.List[string]'
    foreach ($x in $runArr) { $all.Add([string]$x) }
    foreach ($fo in @($fileOut)) { foreach ($x in @($fo.Reasons)) { $all.Add([string]$x) } }
    $allArr = @($all.ToArray() | Sort-Object -Unique)
    return [pscustomobject]@{
        Mode       = $Mode
        Managed    = $true
        Certified  = ($allArr.Count -eq 0)
        Reasons    = $runArr
        Files      = @($fileOut)
        AllReasons = $allArr
    }
}

function New-ScanPolicyReport {
    # The policy facts a scan publishes -- SARIF invocations[0].properties.policy and the text
    # report's Policy section. lsp-scan.ps1 builds it only when a policy was declared or the scan is
    # managed, so an unmanaged scan without a policy emits exactly what it always has. Effective
    # MEMBERS are counted, not listed: the identity names the policy; the counts say what it asks for.
    # notes = one { code; meaning } per reason (Get-PolicyReasonTable); files = the caller's per-file
    # reasons, already named relative to the scan root and bounded by the caller's cap.
    param($ModeInfo, $Declared = $null, $Certification = $null, [string]$SuppressionPass = 'not-required',
        [string[]]$Ambient = @(), [object[]]$Files = @())
    $cert = 'not-requested'
    if ($null -ne $Certification -and [bool]$Certification.Managed) { $cert = $(if ([bool]$Certification.Certified) { 'certified' } else { 'not-certified' }) }
    $decl = $null
    $eff = $null
    $obl = $null
    if ($null -ne $Declared) {
        $decl = [ordered]@{
            source     = [string]$Declared.requested.source
            path       = [string]$Declared.requested.path
            fileSha256 = [string]$Declared.requested.fileSha256
            sidecar    = [string]$Declared.requested.sidecar
            usable     = [bool]$Declared.usable
            reason     = [string]$Declared.reason
        }
        $e = $Declared.effective
        # Assigned before counting (see Get-PolicyObligations): @(Get-PolicyStringList ...) nests.
        $excList = Get-PolicyStringList -Object $e -Name 'ExcludeRules'
        $reqList = Get-PolicyStringList -Object $e -Name 'RequiredRules'
        $proList = Get-PolicyStringList -Object $e -Name 'ProhibitedSuppressions'
        $eff = [ordered]@{
            schema   = [string]$Declared.identity.schema
            version  = [int]$Declared.identity.version
            sha256   = [string]$Declared.identity.sha256
            exclude  = $excList.Count
            override = @((Get-EffectivePolicyOverrides -Effective $e).Keys).Count
            require  = $reqList.Count
            prohibit = $proList.Count
        }
        $obl = $Declared.obligations
    }
    $reasons = @()
    if ($null -ne $Certification) { $reasons = @($Certification.AllReasons) }
    $table = Get-PolicyReasonTable
    $notes = @(foreach ($code in $reasons) {
            $meaning = $(if ($table.Contains([string]$code)) { [string]$table[[string]$code].Meaning } else { 'undeclared reason' })
            [ordered]@{ code = [string]$code; meaning = $meaning }
        })
    return [ordered]@{
        mode            = [string]$ModeInfo.resolved
        modeSource      = [string]$ModeInfo.source
        certification   = $cert
        reasons         = @($reasons)
        notes           = @($notes)
        declared        = $decl
        effective       = $eff
        obligations     = $obl
        suppressionPass = [string]$SuppressionPass
        ambient         = @($Ambient | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        files           = @($Files | Where-Object { $null -ne $_ })
    }
}

function Get-ScanSettingsRejection {
    # What an UNMANAGED scan warns about (dispatch 000306, review finding B1-K04: a rejected settings
    # file "refuses in managed mode; an unmanaged session warns and falls back"): the first daemon record
    # among $Files whose settings verdict is rejected or unparsable, as one ASCII line -- the verdict and
    # the daemon's own detail -- or '' when there is none. Pure over the receipts the scan already holds;
    # a managed scan reports the same records as policy-settings-rejected instead.
    param([object[]]$Files = @())
    foreach ($f in @($Files)) {
        if ($null -eq $f) { continue }
        $pol = Get-PolicyField -Object (Get-PolicyField -Object $f -Name 'Receipt') -Name 'policy'
        $st = Get-PolicyField -Object (Get-PolicyField -Object $pol -Name 'daemon') -Name 'settings'
        $v = [string](Get-PolicyField -Object $st -Name 'validation')
        if ($v -ceq 'rejected' -or $v -ceq 'unparsable') {
            $d = [string](Get-PolicyField -Object $st -Name 'validationDetail')
            return (Format-PssaSettingsText ($v + $(if ($d -ne '') { ' -- ' + $d } else { '' })) 240)
        }
    }
    return ''
}

# --- doctor ----------------------------------------------------------------------

function Get-OrgPolicyEnforcementReportInfo {
    # doctor -Json's orgPolicy object (dispatch 000305, B1): the four existing keys EXACTLY as
    # Get-OrgPolicyReportInfo has always produced them -- path, sha256, sidecarMatch and applied, the
    # same names, types and meaning (applied = the configured policy PARSES and passes its integrity
    # gate; that is all it ever meant) -- followed by two separately named additions that tell
    # parsing apart from enforcement:
    #   effectiveSha256  the policy identity (Resolve-EffectivePolicy) of the policy as parsed HERE,
    #                    '' unless it is usable -- equal effective policies give equal values;
    #   enforcement      what a RUNNING daemon reports it applied, from the record it writes itself:
    #                    state = not-configured | not-observed | observed | unknown; a reason when not
    #                    observed (no-daemon | several-daemons | data-root-unknown | pending |
    #                    settings-unresolved) or unknown (no-policy-record); and when observed, the
    #                    daemon's own identity, whether it matches the parsed one, its RequiredRules
    #                    state and the SHA-256 of the settings file it handed PSES.
    # PENDING IS NOT YET APPLIED (review finding B1-I02). Every daemon writes its record from startup,
    # and it stays 'pending' -- with no resolution -- until the daemon analyzes its first PowerShell
    # file (pses-daemon.ps1), and returns to it when PSES is re-spawned. Such a daemon has applied
    # nothing yet, so it reads not-observed with reason pending and matchesParsed $null, never as a
    # mismatch; the managed verdict reads the same record as missing evidence
    # (Test-ScanPolicyCertification), not as a disagreement.
    # SETTINGS-UNRESOLVED IS NEVER APPLIED (dispatch 000306, review finding B1-OOB-I01). A daemon whose
    # settings resolution threw used to keep that 'pending' record for its whole life, so doctor said
    # "not yet" before and after every analysis. It now records the TERMINAL 'settings-unresolved': it
    # reads not-observed with reason settings-unresolved -- nothing was applied, and nothing will be
    # until PSES is re-spawned or the session restarts -- again with matchesParsed $null, because the
    # record carries no resolution to compare.
    # $DaemonObservation is Get-DoctorDaemonObservation's result ($null = not resolved).
    param($DaemonObservation = $null)
    $info = Get-OrgPolicyReportInfo
    $path = [string]$info.path
    $parsedSha = ''
    if ([bool]$info.applied) {
        $res = Resolve-EffectivePolicy -Path $path -Source 'knob'
        if ([bool]$res.usable) { $parsedSha = [string]$res.identity.sha256 }
    }
    $info['effectiveSha256'] = $parsedSha
    $enf = [ordered]@{ state = 'not-configured'; reason = ''; daemonEffectiveSha256 = ''; matchesParsed = $null; requiredRules = ''; settingsSha256 = '' }
    if (-not [string]::IsNullOrWhiteSpace($path)) {
        $enf.state = 'not-observed'
        $obs = $DaemonObservation
        if ($null -eq $obs) { $enf.reason = 'no-daemon' }
        elseif ((Get-PolicyField -Object $obs -Name 'DataRootKnown') -ne $true) { $enf.reason = 'data-root-unknown' }
        elseif ((Get-PolicyField -Object $obs -Name 'DaemonPresent') -ne $true) { $enf.reason = 'no-daemon' }
        elseif ((Get-PolicyField -Object $obs -Name 'Determinable') -ne $true) { $enf.reason = 'several-daemons' }
        else {
            $dp = Get-PolicyField -Object $obs -Name 'Policy'
            if ($null -eq $dp) {
                $enf.state = 'unknown'
                $enf.reason = 'no-policy-record'
            } else {
                $rr = Get-PolicyField -Object $dp -Name 'requiredRules'
                $rrState = [string](Get-PolicyField -Object $rr -Name 'state')
                if ($rrState -eq 'pending') {
                    $enf.reason = 'pending'   # the startup record: nothing applied yet (state stays not-observed)
                } elseif ($rrState -eq 'settings-unresolved') {
                    $enf.reason = 'settings-unresolved'   # terminal: settings resolution threw, nothing was applied
                } else {
                    $dSha = [string](Get-PolicyField -Object (Get-PolicyField -Object $dp -Name 'resolution') -Name 'effectiveSha256')
                    $enf.state = 'observed'
                    $enf.daemonEffectiveSha256 = $dSha
                    $enf.matchesParsed = ($dSha -ne '' -and $dSha -ceq $parsedSha)
                    $enf.requiredRules = $rrState
                    $enf.settingsSha256 = [string](Get-PolicyField -Object (Get-PolicyField -Object $dp -Name 'settings') -Name 'sha256')
                }
            }
        }
    }
    $info['enforcement'] = $enf
    return $info
}
