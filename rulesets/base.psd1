# base.psd1 -- the plugin-owned "base" PSScriptAnalyzer ruleset (dispatch 000087; curated 000092).
#
# WHAT THIS IS. An OPT-IN, EXPLICITLY ENUMERATED PSScriptAnalyzerSettings file selected
# ONLY when the userConfig knob `ruleset` = 'base' AND no repo-local
# PSScriptAnalyzerSettings.psd1 and no explicit `settingsPath` override resolve first
# (see Resolve-PssaSettingsPath / Get-PluginBaseSettingsPath in scripts/lib/lsp-common.ps1).
# With the default `ruleset` = 'pses-default' this file is NEVER selected and the live
# surface is byte-for-byte unchanged. Repo-local settings and an explicit settingsPath
# ALWAYS win over this file.
#
# WHY IT EXISTS. On the live PostToolUse path PSES applies its OWN hardcoded no-settings
# rule set -- a 15-rule -IncludeRule allow-list (PSES v4.6.0 AnalysisService.s_defaultRules;
# dispatch 000085) -- so any default-on PSScriptAnalyzer rule outside those 15 (e.g.
# PSAvoidUsingWriteHost, and the THREE Error-severity security rules named below) is never
# evaluated. A RESOLVED settings file REPLACES that allow-list, broadening the live surface
# to the enumerated set here.
#
# DETERMINISM (the load-bearing property). The rules are ENUMERATED EXPLICITLY, NOT
# `IncludeDefaultRules = $true`. A bare IncludeDefaultRules silently tracks whatever the
# vendored PSScriptAnalyzer pin considers default-on, so a pin bump would shift the live
# surface with no diff to review. Enumerating pins the surfaced set to this file: a pin bump
# is then a DELIBERATE regeneration, reviewed in a diff, never a silent shift.
#
# DERIVATION (reproducible; regenerate with scripts/regen-base-ruleset.ps1). The list is the
# DEFAULT-ON rule set of the vendored PSScriptAnalyzer pin (PSScriptAnalyzer 1.25.0, the
# $PssaVersion in scripts/ensure-pssa.ps1) MINUS the compatibility-profile family
# (PSUseCompatible*), which needs target-profile configuration (and emits a configuration
# warning without it) and is deferred to the later curated / AI-era rule-pack tier, MINUS a
# named, survey-evidenced exclude list ($BaseRuleExclusions in regen-base-ruleset.ps1;
# dispatch 000092) -- three default-on rules the 000091 quality wave MEASURED noisy or
# false-positive on real code (see the CURATION bullet below).
#   - "default-on" = a rule PSScriptAnalyzer evaluates with no settings, i.e. either a
#     non-configurable rule or a ConfigurableRule whose default `Enable` is $true. The
#     twelve+ formatting rules (PSPlaceOpenBrace, PSPlaceCloseBrace, PSUseConsistentIndentation,
#     PSUseConsistentWhitespace, PSAlignAssignmentStatement, PSUseCorrectCasing,
#     PSAvoidUsingDoubleQuotesForConstantString, PSAvoidSemicolonsAsLineTerminators,
#     PSAvoidLongLines, ...) are ConfigurableRule with default Enable = $false, so they are
#     NOT default-on and are already absent here; they need per-rule config and land in the
#     later formatting/quality tier, not this base.
#   - Count at PSScriptAnalyzer 1.25.0: 75 total rules; 58 default-on; minus the 1 default-on
#     compatibility rule (PSUseCompatibleCmdlets) minus the 3 survey-excluded rules (below)
#     = 54 enumerated below.
#   - CURATION (dispatch 000092; EXCLUDE-ONLY, evidence-gated from the 000091 survey). Three
#     default-on, BASE-ONLY rules are removed as measured noise. Each is reachable ONLY under
#     ruleset=base (none is in the PSES 15-rule allow-list), so removing it tightens the opt-in
#     base surface alone and does NOT move pses-default (which never evaluates them):
#       * PSReviewUnusedParameter -- ~90% false-positive: PSSA's per-scriptblock scope analysis
#         misses a script-level param consumed by a nested function, which is every hook script.
#       * PSUseSingularNouns -- 0 true-issues; intentional plural collection-returning names.
#       * PSUseShouldProcessForStateChangingFunctions -- fires on the state-changing VERB, not
#         real state change; 4 false-positives on clean New-*/Set-* builders in the FP oracle.
#   - The THREE Error-severity security rules this base makes surfaceable that the PSES
#     15-rule allow-list omits: PSAvoidUsingComputerNameHardcoded,
#     PSAvoidUsingConvertToSecureStringWithPlainText, PSAvoidUsingUsernameAndPasswordParams.
#     These, and PSAvoidUsingWriteHost, are RETAINED (never excluded).
#
# ASCII-only (PS 5.1 em-dash trap); no-BOM UTF-8.
@{
    IncludeRules = @(
        'PSAvoidAssignmentToAutomaticVariable'
        'PSAvoidDefaultValueForMandatoryParameter'
        'PSAvoidDefaultValueSwitchParameter'
        'PSAvoidGlobalAliases'
        'PSAvoidGlobalFunctions'
        'PSAvoidGlobalVars'
        'PSAvoidInvokingEmptyMembers'
        'PSAvoidMultipleTypeAttributes'
        'PSAvoidNullOrEmptyHelpMessageAttribute'
        'PSAvoidOverwritingBuiltInCmdlets'
        'PSAvoidReservedWordsAsFunctionNames'
        'PSAvoidShouldContinueWithoutForce'
        'PSAvoidTrailingWhitespace'
        'PSAvoidUsingAllowUnencryptedAuthentication'
        'PSAvoidUsingBrokenHashAlgorithms'
        'PSAvoidUsingCmdletAliases'
        'PSAvoidUsingComputerNameHardcoded'
        'PSAvoidUsingConvertToSecureStringWithPlainText'
        'PSAvoidUsingDeprecatedManifestFields'
        'PSAvoidUsingEmptyCatchBlock'
        'PSAvoidUsingInvokeExpression'
        'PSAvoidUsingPlainTextForPassword'
        'PSAvoidUsingPositionalParameters'
        'PSAvoidUsingUsernameAndPasswordParams'
        'PSAvoidUsingWMICmdlet'
        'PSAvoidUsingWriteHost'
        'PSDSCDscExamplesPresent'
        'PSDSCDscTestsPresent'
        'PSDSCReturnCorrectTypesForDSCFunctions'
        'PSDSCStandardDSCFunctionsInResource'
        'PSDSCUseIdenticalMandatoryParametersForDSC'
        'PSDSCUseIdenticalParametersForDSC'
        'PSDSCUseVerboseMessageInDSCResource'
        'PSMisleadingBacktick'
        'PSMissingModuleManifestField'
        'PSPossibleIncorrectComparisonWithNull'
        'PSPossibleIncorrectUsageOfAssignmentOperator'
        'PSPossibleIncorrectUsageOfRedirectionOperator'
        'PSProvideCommentHelp'
        'PSReservedCmdletChar'
        'PSReservedParams'
        'PSShouldProcess'
        'PSUseApprovedVerbs'
        'PSUseBOMForUnicodeEncodedFile'
        'PSUseCmdletCorrectly'
        'PSUseDeclaredVarsMoreThanAssignments'
        'PSUseLiteralInitializerForHashtable'
        'PSUseOutputTypeCorrectly'
        'PSUseProcessBlockForPipelineCommand'
        'PSUsePSCredentialType'
        'PSUseSupportsShouldProcess'
        'PSUseToExportFieldsInManifest'
        'PSUseUsingScopeModifierInNewRunspaces'
        'PSUseUTF8EncodingForHelpFile'
    )
}
