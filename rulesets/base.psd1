# base.psd1 -- the plugin-owned "base" PSScriptAnalyzer ruleset (dispatch 000087).
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
# warning without it) and is deferred to the later curated / AI-era rule-pack tier.
#   - "default-on" = a rule PSScriptAnalyzer evaluates with no settings, i.e. either a
#     non-configurable rule or a ConfigurableRule whose default `Enable` is $true. The
#     twelve+ formatting rules (PSPlaceOpenBrace, PSPlaceCloseBrace, PSUseConsistentIndentation,
#     PSUseConsistentWhitespace, PSAlignAssignmentStatement, PSUseCorrectCasing,
#     PSAvoidUsingDoubleQuotesForConstantString, PSAvoidSemicolonsAsLineTerminators,
#     PSAvoidLongLines, ...) are ConfigurableRule with default Enable = $false, so they are
#     NOT default-on and are already absent here; they need per-rule config and land in the
#     later formatting/quality tier, not this base.
#   - Count at PSScriptAnalyzer 1.25.0: 75 total rules; 58 default-on; minus the 1 default-on
#     compatibility rule (PSUseCompatibleCmdlets) = 57 enumerated below.
#   - The THREE Error-severity security rules this base makes surfaceable that the PSES
#     15-rule allow-list omits: PSAvoidUsingComputerNameHardcoded,
#     PSAvoidUsingConvertToSecureStringWithPlainText, PSAvoidUsingUsernameAndPasswordParams.
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
        'PSReviewUnusedParameter'
        'PSShouldProcess'
        'PSUseApprovedVerbs'
        'PSUseBOMForUnicodeEncodedFile'
        'PSUseCmdletCorrectly'
        'PSUseDeclaredVarsMoreThanAssignments'
        'PSUseLiteralInitializerForHashtable'
        'PSUseOutputTypeCorrectly'
        'PSUseProcessBlockForPipelineCommand'
        'PSUsePSCredentialType'
        'PSUseShouldProcessForStateChangingFunctions'
        'PSUseSingularNouns'
        'PSUseSupportsShouldProcess'
        'PSUseToExportFieldsInManifest'
        'PSUseUsingScopeModifierInNewRunspaces'
        'PSUseUTF8EncodingForHelpFile'
    )
}
