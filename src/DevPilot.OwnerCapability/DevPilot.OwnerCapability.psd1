@{
    RootModule = 'DevPilot.OwnerCapability.psm1'
    ModuleVersion = '0.5.0'
    GUID = '6f6f6f6f-7070-8181-9292-a3a3a3a3a3a3'
    Author = 'DevPilot Agents contributors'
    CompanyName = 'Unknown'
    Copyright = '(c) DevPilot Agents contributors. All rights reserved.'
    Description = 'Owner v2 semantic capability adapter with preview reconciliation and the exact V1-compatible writer formatter.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'ConvertTo-OwnerV2Observation',
        'Format-OwnerV1WriterComment',
        'Get-OwnerV1WriterMarkerKey',
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
            ReleaseNotes = 'Exports the exact marker and body formatter for the separate human-approved v2 writer while keeping semantic execution preview-only.'
        }
    }
}
