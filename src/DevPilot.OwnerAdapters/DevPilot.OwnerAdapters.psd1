@{
    RootModule = 'DevPilot.OwnerAdapters.psm1'
    ModuleVersion = '0.3.0'
    GUID = '5e5e5e5e-6060-7171-8282-939393939393'
    Author = 'DevPilot Agents contributors'
    CompanyName = 'Unknown'
    Copyright = '(c) DevPilot Agents contributors. All rights reserved.'
    Description = 'Read-only production and sealed replay acquisition adapters for DevPilot.OwnerPipeline.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'ConvertTo-OwnerAzureDevOpsDiscussionPage',
        'Get-OwnerAzureDevOpsDiscussionMappingDigest',
        'New-OwnerAcquisitionContract',
        'New-OwnerAdapterLimits',
        'New-OwnerAzureDevOpsReadOnlyProviderAdapter',
        'New-OwnerAzureDevOpsReviewerIdentity',
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
            ReleaseNotes = 'Adds the persisted Azure DevOps REST discussion normalizer, exact reviewer identity attestation, and stable raw/typed provenance digests. No provider client or write path.'
        }
    }
}
