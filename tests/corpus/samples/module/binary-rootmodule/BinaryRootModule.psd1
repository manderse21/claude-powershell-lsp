@{
    # KNOWN-SHAPE corpus fixture: a BINARY-module manifest stub (dispatch 000171 leg 3).
    #
    # The third round-3 shape reachable with ZERO third-party source vendored. RootModule
    # names a .dll that is deliberately NOT present, and the exported names are CMDLETS --
    # which, being compiled, can never be found by the AST walk that verifies FunctionsToExport.
    #
    # WHAT THIS FIXTURE IS FOR: proving the ManifestConsistency check DEGRADES TO SILENCE on a
    # binary module instead of reporting every declared cmdlet as an orphan. Resolve-ModuleRootModulePath
    # (scripts/lib/lsp-common.ps1) returns '' for a .dll or .exe root module, which makes the
    # export surface INDETERMINATE -- and an indeterminate surface must never fire.
    #
    # The expected snapshot is DERIVED by running the real tool, never hand-authored, so whatever
    # this file actually produces is what the corpus asserts from here on.
    RootModule        = 'BinaryRootModule.dll'
    ModuleVersion     = '1.0.0'
    GUID              = 'b1a7d0c2-3e4f-4a5b-9c8d-7e6f5a4b3c2d'
    Author            = 'Mike Andersen'
    Description       = 'Binary-module manifest stub for the powershell-lsp diagnostic corpus.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @()
    CmdletsToExport   = @('Get-BinaryThing', 'Set-BinaryThing')
    VariablesToExport = @()
    AliasesToExport   = @()
}
