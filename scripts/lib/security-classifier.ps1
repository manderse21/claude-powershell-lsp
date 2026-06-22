#Requires -Version 5.1

# security-classifier.ps1 -- attribute a component-bring-up failure to the security
# control most likely blocking it, on POSITIVE EVIDENCE ONLY, and turn the existing
# generic "bootstrap did not complete" banner into a NAMED, actionable one.
#
# This EXTENDS the never-silent honest-failure spine (dispatch 000024/000028): the
# SessionStart bootstrap path already surfaces a generic 'unavailable' banner when
# ensure-pses / ensure-pssa exit non-zero. This module enriches THAT banner with the
# WHICH-control attribution. It does NOT add a status token (the 000027-frozen
# diagnostics-status taxonomy is untouched) and it is NOT a new surface.
#
# Two halves, kept apart so the logic is unit-testable:
#   - PURE classifier (Resolve-SecurityBlock / Format-BootstrapFailureBanner): a function
#     over INJECTED evidence. No probes, no machine state -- the tests pass evidence
#     directly and assert the named control / remediation / honest fallback.
#   - THIN live probes (Get-*State / Get-*Events / Get-SecurityBlockEvidence): best-effort,
#     CLM-safe, permission-tolerant reads that GATHER the evidence. Each is independently
#     try/caught so a missing log, denied perm, non-Windows host, or Constrained Language
#     Mode degrades to "no evidence" rather than throwing.
#
# THE HONESTY DISCIPLINE: name a specific control ONLY on positive evidence (a queried
# blocking STATE that matches the failure, or a matching CodeIntegrity / Defender event).
# When the evidence is not there, emit the honest diagnostic POINTER -- richer than a bare
# 'unavailable', but never a fabricated control name. Over-claiming a control is the same
# sin as silent failure.
#
# THE ABSOLUTE FENCE: this module DETECTS and EXPLAINS. It NEVER bypasses, disables,
# weakens, or auto-modifies any control -- no Set-ExecutionPolicy, no CLM/WDAC workaround,
# no registry write, no allow-listing action. Every remediation is INSTRUCTIONS for the
# user or their administrator, never an action the plugin takes.
#
# CLM-SAFE BY CONSTRUCTION: the probe and classifier code must run even when the machine
# IS in Constrained Language Mode (so a CLM block can surface itself). It therefore uses
# only cmdlets, hashtables/arrays, comparison operators, switch, string concatenation, and
# [string]/[int] casts -- no New-Object, no Add-Type, no [type]::Method calls.
#
# LOAD-SILENT: defines functions only; nothing is emitted at dot-source.
#
# Author: Mike Andersen / powershell-lsp plugin.

# Substrings that identify one of OUR components in an event message or blocked-file path.
# Used to decide whether a CodeIntegrity / Defender block event is about THIS plugin
# (positive correlation) rather than some unrelated block on the box.
$script:PluginComponentPatterns = @(
    '*PowerShellEditorServices*',
    '*Start-EditorServices*',
    '*powershell-lsp*',
    '*pses-daemon*',
    '*pses-stdio*',
    '*ensure-pses*',
    '*ensure-pssa*',
    '*PSScriptAnalyzer*'
)

# --- pure helpers ----------------------------------------------------------

function Test-PluginComponentReference {
    # True if $Text references one of our components (or the plugin data root). PURE:
    # a plain string/pattern test, no machine access. Used to correlate a block event to
    # THIS plugin so an unrelated 3077 on the box is never mis-attributed to us.
    param([string]$Text, [string]$DataRoot = '')
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    foreach ($pat in $script:PluginComponentPatterns) {
        if ($Text -like $pat) { return $true }
    }
    if (-not [string]::IsNullOrWhiteSpace($DataRoot)) {
        if ($Text -like ('*' + $DataRoot + '*')) { return $true }
    }
    return $false
}

function Get-EventMatchingPlugin {
    # Return the FIRST event in $Events whose Id is in $Ids AND whose Message/Path
    # references a plugin component, or $null. PURE over the injected event list. Each
    # event is a hashtable @{ Id; Message; Path? }.
    param($Events, [int[]]$Ids, [string]$DataRoot = '')
    foreach ($e in @($Events)) {
        if ($null -eq $e) { continue }
        $id = 0
        try { $id = [int]$e.Id } catch { $id = 0 }
        if ($Ids -notcontains $id) { continue }
        $txt = [string]$e.Message
        if ($e -is [hashtable] -and $e.ContainsKey('Path')) { $txt = $txt + ' ' + [string]$e.Path }
        if (Test-PluginComponentReference -Text $txt -DataRoot $DataRoot) { return $e }
    }
    return $null
}

function New-SecurityClassification {
    # Build the classification hashtable in one place so every branch returns the same
    # shape. Control = $null means "no control positively identified".
    param(
        [string]$Control,
        [string]$Confidence,
        [string]$Summary,
        [string]$Remediation,
        [string]$Evidence
    )
    return @{
        Control     = $Control
        Confidence  = $Confidence
        Summary     = $Summary
        Remediation = $Remediation
        Evidence    = $Evidence
    }
}

function Resolve-SecurityBlock {
    # THE PURE CLASSIFIER. Given INJECTED evidence and the failing component label, return
    # the single most-likely blocking control with calibrated confidence and an actionable,
    # instructions-only remediation -- OR the honest "none" fallback when nothing is
    # positively identified.
    #
    # $Evidence is a hashtable (any key may be absent):
    #   ExecutionPolicies   @{ <Scope> = <Policy> }   from Get-ExecutionPolicy -List
    #   LanguageMode        'ConstrainedLanguage' | 'FullLanguage' | ...
    #   SacState            0 (off) | 1 (enforced) | 2 (evaluation) | $null
    #   CodeIntegrityEvents @( @{ Id; Message; Path? } )   3076 (audit) / 3077 (enforced)
    #   DefenderAsrEvents   @( @{ Id; Message; Path? } )   1121 (block) / 1122 (audit)
    #   DataRoot            plugin data path (extra correlation hint)
    #
    # PRECEDENCE (highest-fidelity positive evidence first): a block event that NAMES our
    # file is the strongest signal, so confirmed events (3077 / 1121) rank above audit
    # events (3076 / 1122), which rank above the cheap direct state probes (CLM, then GPO
    # ExecutionPolicy), with the reputation-gated SAC last because it can only ever be
    # "possible". An event wins over CLM/ExecutionPolicy because WDAC enforce commonly
    # FORCES CLM as a side effect -- the event names the root policy, not the symptom.
    param($Evidence, [string]$Component = 'PowerShell editor services')

    if ($null -eq $Evidence) {
        return (New-SecurityClassification -Control $null -Confidence 'none' `
                -Summary 'no specific security control was positively identified.' -Remediation '' -Evidence '')
    }

    $dataRoot = [string]$Evidence.DataRoot

    # 1) CodeIntegrity 3077 -- ENFORCED App Control / WDAC block naming our file (confirmed).
    $ev = Get-EventMatchingPlugin -Events $Evidence.CodeIntegrityEvents -Ids @(3077) -DataRoot $dataRoot
    if ($null -ne $ev) {
        return (New-SecurityClassification -Control 'App Control / WDAC' -Confidence 'confirmed' `
                -Summary ('App Control / WDAC blocked ' + $Component + ' (CodeIntegrity Operational event 3077, enforced).') `
                -Remediation ('A Windows Defender Application Control policy is refusing the plugin''s PowerShell components. Ask your administrator to add an allow rule for them, or run on an unmanaged machine. The plugin will not and cannot bypass the policy.') `
                -Evidence 'CodeIntegrity Operational event 3077 (enforced block) naming a plugin component.')
    }

    # 2) Defender ASR 1121 -- BLOCK event naming our file (confirmed).
    $ev = Get-EventMatchingPlugin -Events $Evidence.DefenderAsrEvents -Ids @(1121) -DataRoot $dataRoot
    if ($null -ne $ev) {
        return (New-SecurityClassification -Control 'Microsoft Defender ASR' -Confidence 'confirmed' `
                -Summary ('Microsoft Defender Attack Surface Reduction blocked ' + $Component + ' (Defender event 1121).') `
                -Remediation ('An ASR rule is blocking the plugin (commonly the child-process-creation or obfuscated-script rules). Ask your administrator to review the rule or allow-list the plugin. The plugin will not modify the rule.') `
                -Evidence 'Microsoft-Windows-Windows Defender Operational event 1121 (block) naming a plugin component.')
    }

    # 3) CodeIntegrity 3076 -- AUDIT-mode flag naming our file (likely, not enforced).
    $ev = Get-EventMatchingPlugin -Events $Evidence.CodeIntegrityEvents -Ids @(3076) -DataRoot $dataRoot
    if ($null -ne $ev) {
        return (New-SecurityClassification -Control 'App Control / WDAC' -Confidence 'likely' `
                -Summary ('App Control / WDAC may be blocking ' + $Component + ' (CodeIntegrity Operational event 3076, audit mode).') `
                -Remediation ('An Application Control policy in audit mode flagged a plugin component; in enforce mode it would block it. Ask your administrator to add an allow rule. The plugin will not change the policy.') `
                -Evidence 'CodeIntegrity Operational event 3076 (audit) naming a plugin component.')
    }

    # 4) Defender ASR 1122 -- AUDIT-mode flag naming our file (likely, not blocking yet).
    $ev = Get-EventMatchingPlugin -Events $Evidence.DefenderAsrEvents -Ids @(1122) -DataRoot $dataRoot
    if ($null -ne $ev) {
        return (New-SecurityClassification -Control 'Microsoft Defender ASR' -Confidence 'likely' `
                -Summary ('Microsoft Defender ASR may be blocking ' + $Component + ' (Defender event 1122, audit mode).') `
                -Remediation ('An ASR rule in audit mode flagged a plugin component; in block mode it would block it. Ask your administrator to review the rule. The plugin will not modify the rule.') `
                -Evidence 'Microsoft-Windows-Windows Defender Operational event 1122 (audit) naming a plugin component.')
    }

    # 5) Constrained Language Mode -- a CURRENT, directly-queried in-process fact. The
    #    plugin's .NET-heavy bootstrap (TLS setup, ProcessStartInfo spawn) throws under CLM
    #    (likely). Ranked above ExecutionPolicy: under GPO AllSigned the hook script itself
    #    would be refused (nothing runs), so if this code IS running, CLM is the more
    #    proximate, higher-confidence cause when both are present.
    $lang = [string]$Evidence.LanguageMode
    if ($lang -eq 'ConstrainedLanguage') {
        return (New-SecurityClassification -Control 'Constrained Language Mode' -Confidence 'likely' `
                -Summary ('PowerShell is running in Constrained Language Mode, so ' + $Component + ' cannot use the .NET APIs it needs and could not start.') `
                -Remediation ('Constrained Language Mode is enforced by a WDAC or AppLocker policy. Until the plugin is signed and policy-trusted (roadmap), ask your administrator to allow it. The plugin will not and cannot leave Constrained Language Mode.') `
                -Evidence 'the session language mode is ConstrainedLanguage.')
    }

    # 6) ExecutionPolicy -- only a GROUP-POLICY scope (MachinePolicy / UserPolicy) set to
    #    AllSigned or RemoteSigned is a real block: the plugin runs everything with
    #    -ExecutionPolicy Bypass, which OVERRIDES a CurrentUser/LocalMachine policy but is
    #    IGNORED when the policy comes from Group Policy. A CurrentUser AllSigned alone is
    #    therefore NOT named (Bypass overrides it) -- naming it would be a false positive.
    $policyScope = $null
    $policyValue = $null
    $eps = $Evidence.ExecutionPolicies
    if ($null -ne $eps) {
        foreach ($scope in @('MachinePolicy', 'UserPolicy')) {
            $val = ''
            if ($eps -is [hashtable]) {
                if ($eps.ContainsKey($scope)) { $val = [string]$eps[$scope] }
            } else {
                try { $val = [string]$eps.$scope } catch { $val = '' }
            }
            if (@('AllSigned', 'RemoteSigned') -contains $val) { $policyScope = $scope; $policyValue = $val; break }
        }
    }
    if ($null -ne $policyScope) {
        return (New-SecurityClassification -Control 'ExecutionPolicy' -Confidence 'likely' `
                -Summary ('ExecutionPolicy ' + $policyValue + ' (set by ' + $policyScope + ') is blocking unsigned plugin scripts, and a command-line -ExecutionPolicy Bypass is ignored when the policy comes from Group Policy.') `
                -Remediation ('Until the plugin scripts are Authenticode-signed (roadmap), ask your administrator to allow them or adjust the policy scope. The plugin will not change the execution policy.') `
                -Evidence ('Get-ExecutionPolicy -List shows ' + $policyScope + ' = ' + $policyValue + '.'))
    }

    # 7) Smart App Control -- reputation-gated, so it can only ever be POSSIBLE: detecting
    #    SAC is ON is not proof it blocked THIS file. Always hedged, never confirmed.
    $sac = $Evidence.SacState
    if ($null -ne $sac) {
        $sacInt = -1
        try { $sacInt = [int]$sac } catch { $sacInt = -1 }
        if ($sacInt -eq 1 -or $sacInt -eq 2) {
            $mode = if ($sacInt -eq 1) { 'enforced' } else { 'in evaluation mode' }
            return (New-SecurityClassification -Control 'Smart App Control' -Confidence 'possible' `
                    -Summary ('Smart App Control is ' + $mode + ' and may be blocking the downloaded analyzer until its publisher reputation accrues; ' + $Component + ' could not start.') `
                    -Remediation ('Smart App Control cannot be allow-listed per file; it relaxes as reputation accrues or when an administrator turns it off. The plugin will not change Smart App Control.') `
                    -Evidence ('Smart App Control state (registry VerifiedAndReputablePolicyState) is ' + $sacInt + '.'))
        }
    }

    # 8) Nothing positively identified -- the honest fallback (the formatter renders the
    #    diagnostic pointer; we do NOT fabricate a control).
    return (New-SecurityClassification -Control $null -Confidence 'none' `
            -Summary 'no specific security control was positively identified.' -Remediation '' -Evidence '')
}

function Format-BootstrapFailureBanner {
    # PURE: render the enriched SessionStart bootstrap-failure banner from a classification.
    # ALWAYS contains the words 'unavailable' and 'bootstrap' so it keeps reading as the
    # honest never-silent failure (and so the existing surface integration test holds). On a
    # positive classification it NAMES the control + remediation; on 'none' it emits the
    # honest diagnostic pointer (network/proxy is still the common cause; the security check
    # is offered, not asserted).
    param($Classification, [string]$LogPath = '')

    $see = ''
    if (-not [string]::IsNullOrWhiteSpace($LogPath)) { $see = ' See ' + $LogPath + '.' }

    $base = 'PowerShell diagnostics unavailable: the PowerShell editor services bootstrap did not complete.'
    $tail = ' Edits will NOT be linted until this is resolved.' + $see

    if ($null -eq $Classification -or [string]::IsNullOrWhiteSpace([string]$Classification.Control)) {
        $pointer = ' This is usually a network or proxy issue. If you are on a managed or locked-down machine,' +
                   ' a security control may be blocking it -- check ExecutionPolicy (Get-ExecutionPolicy -List),' +
                   ' the PowerShell language mode, and the CodeIntegrity Operational event log.'
        return ($base + $pointer + $tail)
    }

    $lead = switch ([string]$Classification.Confidence) {
        'confirmed' { ' Cause: ' }
        'likely'    { ' Likely cause: ' }
        'possible'  { ' Possible cause: ' }
        default     { ' Possible cause: ' }
    }
    $rem = [string]$Classification.Remediation
    if (-not [string]::IsNullOrWhiteSpace($rem)) { $rem = ' ' + $rem }
    return ($base + $lead + [string]$Classification.Summary + $rem + $tail)
}

# --- thin live probes (best-effort, CLM-safe, permission-tolerant) ---------

function Get-ExecutionPolicyState {
    # @{ <Scope> = <Policy> } from Get-ExecutionPolicy -List. Cheap, CLM-safe, and reading
    # the policy never changes it. Returns @{} if unavailable.
    $out = @{}
    try {
        foreach ($row in @(Get-ExecutionPolicy -List -ErrorAction Stop)) {
            $scope = [string]$row.Scope
            if (-not [string]::IsNullOrWhiteSpace($scope)) { $out[$scope] = [string]$row.ExecutionPolicy }
        }
    } catch { $out = @{} }
    return $out
}

function Get-SessionLanguageMode {
    # The current session language mode as a string ('' if it cannot be read). Property
    # read only -- allowed even under Constrained Language Mode.
    try { return [string]$ExecutionContext.SessionState.LanguageMode } catch { return '' }
}

function Get-SmartAppControlState {
    # SAC state from the registry (0 off / 1 enforced / 2 evaluation), or $null when the
    # key is absent (older Windows), unreadable, or off-platform. Read-only.
    try {
        $p = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy'
        $n = 'VerifiedAndReputablePolicyState'
        $v = (Get-ItemProperty -Path $p -Name $n -ErrorAction Stop).$n
        return [int]$v
    } catch { return $null }
}

function Get-WinEventBlockRecords {
    # Best-effort Get-WinEvent over one operational log for a set of ids; return a list of
    # @{ Id; Message } (capped). Returns @() on any failure -- denied event-log perms, a
    # log that is off/empty/absent, a non-Windows host, or CLM limiting Get-WinEvent -- so
    # the absence of event evidence degrades to "no evidence", never an exception.
    param([string]$LogName, [int[]]$Ids, [int]$Max = 25)
    $recs = @()
    try {
        $filter = @{ LogName = $LogName; Id = $Ids }
        foreach ($e in @(Get-WinEvent -FilterHashtable $filter -MaxEvents $Max -ErrorAction Stop)) {
            $recs += @{ Id = [int]$e.Id; Message = [string]$e.Message }
        }
    } catch { $recs = @() }
    return $recs
}

function Get-CodeIntegrityBlockEvents {
    # Recent CodeIntegrity audit (3076) / enforced-block (3077) events. Best-effort.
    return (Get-WinEventBlockRecords -LogName 'Microsoft-Windows-CodeIntegrity/Operational' -Ids @(3076, 3077))
}

function Get-DefenderAsrBlockEvents {
    # Recent Defender ASR block (1121) / audit (1122) events. Best-effort.
    return (Get-WinEventBlockRecords -LogName 'Microsoft-Windows-Windows Defender/Operational' -Ids @(1121, 1122))
}

function Get-SecurityBlockEvidence {
    # Gather all probes into the evidence hashtable Resolve-SecurityBlock consumes. Each
    # probe is independently fail-safe, so a denied perm or off-platform host yields partial
    # (or empty) evidence rather than throwing. Self-contained: reads the data root from the
    # env directly so the classifier does not depend on lsp-common being dot-sourced.
    param([string]$DataRoot = '')
    if ([string]::IsNullOrWhiteSpace($DataRoot)) { $DataRoot = [string]$env:CLAUDE_PLUGIN_DATA }
    return @{
        ExecutionPolicies   = (Get-ExecutionPolicyState)
        LanguageMode        = (Get-SessionLanguageMode)
        SacState            = (Get-SmartAppControlState)
        CodeIntegrityEvents = (Get-CodeIntegrityBlockEvents)
        DefenderAsrEvents   = (Get-DefenderAsrBlockEvents)
        DataRoot            = $DataRoot
    }
}

function Get-BootstrapSecurityBanner {
    # The one call the SessionStart hook makes: gather evidence, classify, render. Fail-safe
    # -- on ANY error it returns '' so the caller falls back to its existing generic banner
    # and bring-up continues (the 000026 exit-0 spine is never put at risk by this module).
    param([string]$LogPath = '', [string]$Component = 'PowerShell editor services')
    try {
        $ev = Get-SecurityBlockEvidence
        $c = Resolve-SecurityBlock -Evidence $ev -Component $Component
        return (Format-BootstrapFailureBanner -Classification $c -LogPath $LogPath)
    } catch { return '' }
}
