@{
    RootModule = 'DevPilot.OwnerCapability.psm1'
    ModuleVersion = '0.4.0'
    GUID = '6f6f6f6f-7070-8181-9292-a3a3a3a3a3a3'
    Author = 'DevPilot Agents contributors'
    CompanyName = 'Unknown'
    Copyright = '(c) DevPilot Agents contributors. All rights reserved.'
    Description = 'Preview-only Owner v2 semantic capability adapter for normalized facade evidence.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'ConvertTo-OwnerV2Observation',
        'New-OwnerSemanticRunner',
        'New-OwnerV2CapabilityAdapter',
        'New-OwnerV2CapabilityLimits',
        'Resolve-OwnerV2DiscussionReconciliation'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('copilot', 'agents', 'review', 'owner', 'capability', 'powershell')
            ReleaseNotes = 'Binds Owner reconciliation to the persisted Azure DevOps REST discussion mapping and exact reviewer identity provenance.'
        }
    }
}
