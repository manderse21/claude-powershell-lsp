# command-module-index.psd1 -- GENERATED shipped command->module index (do not hand-edit).
#
# Names-only interoperability metadata: each entry maps a command NAME to the NAME of the
# module that exports it. Ships NO module content. DERIVED from the vendored source snapshot
# rulesets/command-module-index.source.psd1 by scripts/regen-command-module-index.ps1 (built-in
# denylist + one-owner EXCLUSION applied). Refreshed ONLY by a deliberate dispatch: re-vendor
# the source snapshot, re-run the generator, review the diff. No network at edit time, ever.
#
# To regenerate: pwsh scripts/regen-command-module-index.ps1 ; to verify: -Check (offline).

@{
    schema = 'command-module-index/v1'
    generated_from = 'command-module-index.source.psd1'
    module_count = 14
    entry_count = 104
    modules = @(
        @{ name = 'ActiveDirectory'; version = ''; source = 'curated' }
        @{ name = 'Az.Accounts'; version = ''; source = 'curated' }
        @{ name = 'Az.Compute'; version = ''; source = 'curated' }
        @{ name = 'Az.KeyVault'; version = ''; source = 'curated' }
        @{ name = 'Az.Resources'; version = ''; source = 'curated' }
        @{ name = 'Az.Storage'; version = ''; source = 'curated' }
        @{ name = 'dbatools'; version = ''; source = 'curated' }
        @{ name = 'ExchangeOnlineManagement'; version = ''; source = 'curated' }
        @{ name = 'ImportExcel'; version = ''; source = 'curated' }
        @{ name = 'Microsoft.Graph.Authentication'; version = ''; source = 'curated' }
        @{ name = 'Microsoft.Graph.Groups'; version = ''; source = 'curated' }
        @{ name = 'Microsoft.Graph.Users'; version = ''; source = 'curated' }
        @{ name = 'Pester'; version = '5.7.1'; source = 'machine-derived' }
        @{ name = 'PnP.PowerShell'; version = ''; source = 'curated' }
    )
    # command NAME -> owning module NAME (the runtime lookup; O(1) membership per edit).
    entries = @{
        'Add-ADGroupMember' = 'ActiveDirectory'
        'Add-ExcelChart' = 'ImportExcel'
        'Add-PnPListItem' = 'PnP.PowerShell'
        'Add-ShouldOperator' = 'Pester'
        'AfterAll' = 'Pester'
        'AfterEach' = 'Pester'
        'Assert-MockCalled' = 'Pester'
        'Assert-VerifiableMock' = 'Pester'
        'Backup-DbaDatabase' = 'dbatools'
        'BeforeAll' = 'Pester'
        'BeforeDiscovery' = 'Pester'
        'BeforeEach' = 'Pester'
        'Close-ExcelPackage' = 'ImportExcel'
        'Connect-AzAccount' = 'Az.Accounts'
        'Connect-DbaInstance' = 'dbatools'
        'Connect-ExchangeOnline' = 'ExchangeOnlineManagement'
        'Connect-MgGraph' = 'Microsoft.Graph.Authentication'
        'Connect-PnPOnline' = 'PnP.PowerShell'
        'Context' = 'Pester'
        'ConvertTo-JUnitReport' = 'Pester'
        'ConvertTo-NUnitReport' = 'Pester'
        'ConvertTo-Pester4Result' = 'Pester'
        'Copy-DbaDatabase' = 'dbatools'
        'Describe' = 'Pester'
        'Disconnect-AzAccount' = 'Az.Accounts'
        'Disconnect-ExchangeOnline' = 'ExchangeOnlineManagement'
        'Disconnect-MgGraph' = 'Microsoft.Graph.Authentication'
        'Disconnect-PnPOnline' = 'PnP.PowerShell'
        'Export-Excel' = 'ImportExcel'
        'Export-JUnitReport' = 'Pester'
        'Export-NUnitReport' = 'Pester'
        'Get-ADComputer' = 'ActiveDirectory'
        'Get-ADDomain' = 'ActiveDirectory'
        'Get-ADGroup' = 'ActiveDirectory'
        'Get-ADGroupMember' = 'ActiveDirectory'
        'Get-ADUser' = 'ActiveDirectory'
        'Get-AzAccessToken' = 'Az.Accounts'
        'Get-AzContext' = 'Az.Accounts'
        'Get-AzKeyVault' = 'Az.KeyVault'
        'Get-AzKeyVaultKey' = 'Az.KeyVault'
        'Get-AzKeyVaultSecret' = 'Az.KeyVault'
        'Get-AzResource' = 'Az.Resources'
        'Get-AzResourceGroup' = 'Az.Resources'
        'Get-AzRoleAssignment' = 'Az.Resources'
        'Get-AzStorageAccount' = 'Az.Storage'
        'Get-AzStorageBlob' = 'Az.Storage'
        'Get-AzStorageContainer' = 'Az.Storage'
        'Get-AzSubscription' = 'Az.Accounts'
        'Get-AzVM' = 'Az.Compute'
        'Get-ConnectionInformation' = 'ExchangeOnlineManagement'
        'Get-DbaAgentJob' = 'dbatools'
        'Get-DbaDatabase' = 'dbatools'
        'Get-EXOMailbox' = 'ExchangeOnlineManagement'
        'Get-EXOMailboxStatistics' = 'ExchangeOnlineManagement'
        'Get-EXORecipient' = 'ExchangeOnlineManagement'
        'Get-MgContext' = 'Microsoft.Graph.Authentication'
        'Get-MgGroup' = 'Microsoft.Graph.Groups'
        'Get-MgGroupMember' = 'Microsoft.Graph.Groups'
        'Get-MgUser' = 'Microsoft.Graph.Users'
        'Get-MgUserMessage' = 'Microsoft.Graph.Users'
        'Get-PnPList' = 'PnP.PowerShell'
        'Get-PnPListItem' = 'PnP.PowerShell'
        'Get-PnPSite' = 'PnP.PowerShell'
        'Get-PnPWeb' = 'PnP.PowerShell'
        'Get-ShouldOperator' = 'Pester'
        'Import-Excel' = 'ImportExcel'
        'InModuleScope' = 'Pester'
        'Invoke-DbaQuery' = 'dbatools'
        'Invoke-MgGraphRequest' = 'Microsoft.Graph.Authentication'
        'Invoke-Pester' = 'Pester'
        'It' = 'Pester'
        'Mock' = 'Pester'
        'New-ADGroup' = 'ActiveDirectory'
        'New-ADUser' = 'ActiveDirectory'
        'New-AzResourceGroup' = 'Az.Resources'
        'New-AzRoleAssignment' = 'Az.Resources'
        'New-AzStorageAccount' = 'Az.Storage'
        'New-AzStorageContext' = 'Az.Storage'
        'New-AzVM' = 'Az.Compute'
        'New-Fixture' = 'Pester'
        'New-MgGroup' = 'Microsoft.Graph.Groups'
        'New-MgUser' = 'Microsoft.Graph.Users'
        'New-MockObject' = 'Pester'
        'New-PesterConfiguration' = 'Pester'
        'New-PesterContainer' = 'Pester'
        'Open-ExcelPackage' = 'ImportExcel'
        'Remove-ADUser' = 'ActiveDirectory'
        'Remove-AzResourceGroup' = 'Az.Resources'
        'Remove-AzVM' = 'Az.Compute'
        'Remove-MgGroup' = 'Microsoft.Graph.Groups'
        'Remove-MgUser' = 'Microsoft.Graph.Users'
        'Restart-AzVM' = 'Az.Compute'
        'Restore-DbaDatabase' = 'dbatools'
        'Set-ADUser' = 'ActiveDirectory'
        'Set-AzContext' = 'Az.Accounts'
        'Set-AzKeyVaultSecret' = 'Az.KeyVault'
        'Set-AzStorageBlobContent' = 'Az.Storage'
        'Set-ExcelRange' = 'ImportExcel'
        'Set-ItResult' = 'Pester'
        'Should' = 'Pester'
        'Start-AzVM' = 'Az.Compute'
        'Stop-AzVM' = 'Az.Compute'
        'Update-MgGroup' = 'Microsoft.Graph.Groups'
        'Update-MgUser' = 'Microsoft.Graph.Users'
    }
}
