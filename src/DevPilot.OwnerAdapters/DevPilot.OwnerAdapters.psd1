@{
    RootModule = 'DevPilot.OwnerAdapters.psm1'
    ModuleVersion = '0.2.0'
    GUID = '5e5e5e5e-6060-7171-8282-939393939393'
    Author = 'DevPilot Agents contributors'
    CompanyName = 'Unknown'
    Copyright = '(c) DevPilot Agents contributors. All rights reserved.'
    Description = 'Read-only production and sealed replay acquisition adapters for DevPilot.OwnerPipeline.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'New-OwnerAcquisitionContract',
        'New-OwnerAdapterLimits',
        'New-OwnerDiscussionLimits',
        'New-OwnerReadOnlyProviderAdapter',
        'New-OwnerProductionAcquisitionAdapter',
        'Get-OwnerDiscussionSnapshot',
        'New-OwnerReplayFixture',
        'New-OwnerReplayAcquisitionAdapter'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('copilot', 'agents', 'review', 'adapter', 'replay', 'powershell')
            ReleaseNotes = 'Adds bounded read-only discussion snapshots for wrapper-owned Owner reconciliation. No provider client or write path.'
        }
    }
}
