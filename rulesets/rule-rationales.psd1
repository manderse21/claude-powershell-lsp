# rule-rationales.psd1 -- GENERATED per-rule rationale table (do not hand-edit).
#
# A static "why this rule matters" string per rule the plugin can surface, rendered as
# ADDITIVE prose on the existing additionalContext channel -- one line per DISTINCT rule
# surfaced in a file, riding only existing findings. A clean file emits nothing. A rule with
# no entry here surfaces its finding with NO rationale line: degrade, never fabricate.
#
# HYBRID source (dispatch 000120 survey / 000121 build). The PSSA half is auto-derived from
# the vendored PINNED PSScriptAnalyzer (CommonName + a whole-sentence Description prefix,
# capped) over exactly the rulesets/base.psd1 surface; the plugin-owned finders (which
# PSScriptAnalyzer knows nothing about) are hand-authored in the generator.
#
# DERIVED by scripts/regen-rule-rationales.ps1. A pin bump is a DELIBERATE regeneration
# reviewed in a diff, never silent staleness (the -Check drift-guard enforces this).
#
# To regenerate: pwsh scripts/regen-rule-rationales.ps1 ; to verify: -Check (offline, at the pin).

@{
    schema = 'rule-rationales/v1'
    pssa_version = '1.25.0'
    max_length = 180
    pssa_count = 54
    owned_count = 5
    # The plugin-owned finders, hand-authored (PSScriptAnalyzer has no metadata for them).
    # Keyed by the finder ruleId/code as EMITTED, not by its function name.
    owned = @(
        'BashIsm'
        'ManifestConsistency'
        'ModuleNotInstalled'
        'NonAsciiChar'
        'PS7OnlySyntax'
    )
    # rule CODE -> rationale text (the runtime lookup; keyed by the diagnostic `code`).
    entries = @{
        'BashIsm' = 'Unix/bash command, not recognized as a PowerShell command here: it fails on a clean Windows host, or silently relies on Git Bash. Use a PowerShell equivalent, or call it with ''&''.'
        'ManifestConsistency' = 'Manifest FunctionsToExport disagrees with the module: a listed function is never defined, or an exported one is unlisted, so the module exports the wrong commands. Align them.'
        'ModuleNotInstalled' = 'Command comes from a module that is not installed here and is not imported, required, or defined in this file, so the call fails at run time. Install or import the module.'
        'NonAsciiChar' = 'Non-ASCII smart punctuation in a file with no UTF-8 BOM: Windows PowerShell 5.1 reads it as Windows-1252 and mojibakes the text. Use plain ASCII, or save the file with a BOM.'
        'PS7OnlySyntax' = 'PowerShell 7-only syntax: a PARSE error under Windows PowerShell 5.1, so the whole file fails to load there. Use a 5.1-compatible form, or declare ''#Requires -Version 7''.'
        'PSAvoidAssignmentToAutomaticVariable' = 'Changing automatic variables might have undesired side effects -- This automatic variable is built into PowerShell and readonly.'
        'PSAvoidDefaultValueForMandatoryParameter' = 'Avoid Default Value For Mandatory Parameter -- Mandatory parameter should not be initialized with a default value in the param block because this value will be ignored.'
        'PSAvoidDefaultValueSwitchParameter' = 'Switch Parameters Should Not Default To True -- Switch parameter should not default to true.'
        'PSAvoidGlobalAliases' = 'Avoid global aliases -- Checks that global aliases are not used. Global aliases are strongly discouraged as they overwrite desired aliases with name conflicts.'
        'PSAvoidGlobalFunctions' = 'Avoid global functions and aliases -- Checks that global functions and aliases are not used.'
        'PSAvoidGlobalVars' = 'No Global Variables -- Checks that global variables are not used. Global variables are strongly discouraged as they can cause errors across different systems.'
        'PSAvoidInvokingEmptyMembers' = 'Avoid Invoking Empty Members -- Invoking non-constant members would cause potential bugs. Please double check the syntax to make sure members invoked are non-constant.'
        'PSAvoidMultipleTypeAttributes' = 'Avoid multiple type specifiers on parameters -- Parameter should not have more than one type specifier.'
        'PSAvoidNullOrEmptyHelpMessageAttribute' = 'Avoid using null or empty HelpMessage parameter attribute -- Setting the HelpMessage attribute to an empty string or null value causes PowerShell interpreter to throw an error...'
        'PSAvoidOverwritingBuiltInCmdlets' = 'Avoid overwriting built in cmdlets -- Do not overwrite the definition of a cmdlet that is included with PowerShell'
        'PSAvoidReservedWordsAsFunctionNames' = 'Avoid reserved words as function names -- Avoid using reserved words as function names. Using reserved words as function names can cause errors or unexpected behavior in scripts.'
        'PSAvoidShouldContinueWithoutForce' = 'Avoid Using ShouldContinue Without Boolean Force Parameter -- Functions that use ShouldContinue should have a boolean force parameter to allow user to bypass it.'
        'PSAvoidTrailingWhitespace' = 'Avoid trailing whitespace -- Each line should have no trailing whitespace.'
        'PSAvoidUsingAllowUnencryptedAuthentication' = 'Avoid AllowUnencryptedAuthentication Switch -- Avoid sending credentials and secrets over unencrypted connections.'
        'PSAvoidUsingBrokenHashAlgorithms' = 'Avoid Using Broken Hash Algorithms -- Avoid using the broken algorithms MD5 or SHA-1.'
        'PSAvoidUsingCmdletAliases' = 'Avoid Using Cmdlet Aliases or omitting the ''Get-'' prefix -- An alias is an alternate name or nickname for a cmdlet or for a command element, such as a function, script, file...'
        'PSAvoidUsingComputerNameHardcoded' = 'Avoid Using ComputerName Hardcoded -- The ComputerName parameter of a cmdlet should not be hardcoded as this will expose sensitive information about the system.'
        'PSAvoidUsingConvertToSecureStringWithPlainText' = 'Avoid Using SecureString With Plain Text -- Using ConvertTo-SecureString with plain text will expose secure information.'
        'PSAvoidUsingDeprecatedManifestFields' = 'Avoid Using Deprecated Manifest Fields -- "ModuleToProcess" is obsolete in the latest PowerShell version.'
        'PSAvoidUsingEmptyCatchBlock' = 'Avoid Using Empty Catch Block -- Empty catch blocks are considered poor design decisions because if an error occurs in the try block, this error is simply swallowed and not...'
        'PSAvoidUsingInvokeExpression' = 'Avoid Using Invoke-Expression -- The Invoke-Expression cmdlet evaluates or runs a specified string as a command and returns the results of the expression or command.'
        'PSAvoidUsingPlainTextForPassword' = 'Avoid Using Plain Text For Password Parameter -- Password parameters that take in plaintext will expose passwords and compromise the security of your system.'
        'PSAvoidUsingPositionalParameters' = 'Avoid Using Positional Parameters -- Readability and clarity should be the goal of any script we expect to maintain over time.'
        'PSAvoidUsingUsernameAndPasswordParams' = 'Avoid Using Username and Password Parameters -- Functions should take in a Credential parameter of type PSCredential (with a Credential transformation attribute defined after...'
        'PSAvoidUsingWMICmdlet' = 'Avoid Using Get-WMIObject, Remove-WMIObject, Invoke-WmiMethod, Register-WmiEvent, Set-WmiInstance -- Deprecated. Starting in Windows PowerShell 3.0, these cmdlets have been...'
        'PSAvoidUsingWriteHost' = 'Avoid Using Write-Host -- Avoid using the Write-Host cmdlet. Instead, use Write-Output, Write-Verbose, or Write-Information.'
        'PSDSCDscExamplesPresent' = 'DSC examples are present -- Every DSC resource module should contain folder "Examples" with sample configurations for every resource.'
        'PSDSCDscTestsPresent' = 'Dsc tests are present -- Every DSC resource module should contain folder "Tests" with tests for every resource.'
        'PSDSCReturnCorrectTypesForDSCFunctions' = 'Return Correct Types For DSC Functions -- Set function in DSC class and Set-TargetResource in DSC resource must not return anything.'
        'PSDSCStandardDSCFunctionsInResource' = 'Use Standard Get/Set/Test TargetResource functions in DSC Resource -- DSC Resource must implement Get, Set and Test-TargetResource functions.'
        'PSDSCUseIdenticalMandatoryParametersForDSC' = 'Use identical mandatory parameters for DSC Get/Test/Set TargetResource functions -- The Get/Test/Set TargetResource functions of DSC resource must have the same mandatory...'
        'PSDSCUseIdenticalParametersForDSC' = 'Use Identical Parameters For DSC Test and Set Functions -- The Test and Set-TargetResource functions of DSC Resource must have the same parameters.'
        'PSDSCUseVerboseMessageInDSCResource' = 'Use verbose message in DSC resource -- It is a best practice to emit informative, verbose messages in DSC resource functions.'
        'PSMisleadingBacktick' = 'Misleading Backtick -- Ending a line with an escaped whitespace character is misleading. A trailing backtick is usually used for line continuation.'
        'PSMissingModuleManifestField' = 'Module Manifest Fields -- Some fields of the module manifest (such as ModuleVersion) are required.'
        'PSPossibleIncorrectComparisonWithNull' = 'Null Comparison -- Checks that $null is on the left side of any equality comparisons (eq, ne, ceq, cne, ieq, ine).'
        'PSPossibleIncorrectUsageOfAssignmentOperator' = '''='' is not an assignment operator. Did you mean the equality operator ''-eq''? -- ''='' or ''=='' are not comparison operators in the PowerShell language and rarely needed inside...'
        'PSPossibleIncorrectUsageOfRedirectionOperator' = '''>'' is not a comparison operator. Use ''-gt'' (greater than) or ''-ge'' (greater or equal) -- When switching between different languages it is easy to forget that ''>'' does not mean...'
        'PSProvideCommentHelp' = 'Basic Comment Help -- Checks that all cmdlets have a help comment. This rule only checks existence. It does not check the content of the comment.'
        'PSReservedCmdletChar' = 'Reserved Cmdlet Chars -- Checks for reserved characters in cmdlet names. These characters usually cause a parsing error. Otherwise they will generally cause runtime errors.'
        'PSReservedParams' = 'Reserved Parameters -- Checks for reserved parameters in function definitions. If these parameters are defined by the user, an error generally occurs.'
        'PSShouldProcess' = 'Should Process -- Checks that if the SupportsShouldProcess is present, the function calls ShouldProcess/ShouldContinue and vice versa.'
        'PSUseApprovedVerbs' = 'Cmdlet Verbs -- Checks that all defined cmdlets use approved verbs. This is in line with PowerShell''s best practices.'
        'PSUseBOMForUnicodeEncodedFile' = 'Use BOM encoding for non-ASCII files -- For a file encoded with a format other than ASCII, ensure BOM is present to ensure that any application consuming this file can...'
        'PSUseCmdletCorrectly' = 'Use Cmdlet Correctly -- Cmdlet should be called with the mandatory parameters.'
        'PSUseDeclaredVarsMoreThanAssignments' = 'Extra Variables -- Ensure declared variables are used elsewhere in the script and not just during assignment.'
        'PSUseLiteralInitializerForHashtable' = 'Create hashtables with literal initializers -- Use literal initializer, @{}, for creating a hashtable as they are case-insensitive by default'
        'PSUseOutputTypeCorrectly' = 'Use OutputType Correctly -- The return types of a cmdlet should be declared using the OutputType attribute.'
        'PSUseProcessBlockForPipelineCommand' = 'Use process block for command that accepts input from pipeline -- If a command parameter takes its value from the pipeline, the command must use a process block to bind the...'
        'PSUsePSCredentialType' = 'Use PSCredential type -- For PowerShell 4.0 and earlier, a parameter named Credential with type PSCredential must have a credential transformation attribute defined after the...'
        'PSUseSupportsShouldProcess' = 'Use SupportsShouldProcess -- Commands typically provide Confirm and WhatIf parameters to give more control on its execution in an interactive environment.'
        'PSUseToExportFieldsInManifest' = 'Use the *ToExport module manifest fields -- In a module manifest, AliasesToExport, CmdletsToExport, FunctionsToExport and VariablesToExport fields should not use wildcards or...'
        'PSUseUsingScopeModifierInNewRunspaces' = 'Use ''Using:'' scope modifier in RunSpace ScriptBlocks -- If a ScriptBlock is intended to be run as a new RunSpace, variables inside it should use ''Using:'' scope modifier, or be...'
        'PSUseUTF8EncodingForHelpFile' = 'Use UTF8 Encoding For Help File -- PowerShell help file needs to use UTF8 Encoding.'
    }
}
