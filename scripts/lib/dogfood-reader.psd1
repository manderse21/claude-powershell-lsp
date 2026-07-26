# dogfood-reader.psd1 -- manifest for the dogfood capture/annotation reader module
# (dispatch 000156). Imported by a $PSScriptRoot-relative path from scripts/review-dogfood.ps1
# and scripts/rule-efficacy-ledger.ps1 -- never via PSModulePath, never by absolute path, never
# through an environment variable, because the plugin runs from the marketplace cache rather
# than a checkout or a module directory.
#
# ASCII-only (PS 5.1 reads a UTF-8-without-BOM file through the Windows-1252 codepage).

@{
    RootModule        = 'dogfood-reader.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '6a1f3d0e-4b27-4c9a-9f18-2d7c5e8b41a3'
    Author            = 'Mike Andersen'
    Description       = 'Reader/annotation helpers for the powershell-lsp dogfood diagnostic capture log.'
    PowerShellVersion = '5.1'

    # EXACTLY the functions shipped callers invoke. Every other function in the module is
    # private on purpose; the Pester suite reaches those with InModuleScope rather than by
    # widening this list (dispatch 000156, boundary B1).
    FunctionsToExport = @(
        'Get-DefaultPluginCacheRoot',
        'Get-DogfoodAnnotationsPath',
        'Get-DogfoodCacheLogPath',
        'Get-DogfoodSourceBucket',
        'Get-DogfoodVerdicts',
        'Invoke-DogfoodReview',
        'Read-DogfoodAnnotations',
        'Read-DogfoodLog',
        'Resolve-DogfoodPaths',
        'Set-DogfoodVerdict',
        'Show-DogfoodListing',
        'Test-DogfoodVerdict'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
