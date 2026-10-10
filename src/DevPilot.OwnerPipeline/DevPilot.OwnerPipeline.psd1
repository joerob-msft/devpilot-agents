@{
    RootModule = 'DevPilot.OwnerPipeline.psm1'
    ModuleVersion = '0.1.0'
    GUID = '4d4d4d4d-5050-5151-5252-535353535353'
    Author = 'DevPilot Agents contributors'
    CompanyName = 'Unknown'
    Copyright = '(c) DevPilot Agents contributors. All rights reserved.'
    Description = 'Generic, zero-write-by-default facade for staged owner review pipelines.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'New-OwnerPipelineBinding',
        'New-OwnerPipelineAdapter',
        'Invoke-OwnerReviewPipeline'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('copilot', 'agents', 'review', 'pipeline', 'powershell')
            ReleaseNotes = 'Initial generic facade and adapter seam. No deployment or live provider integration.'
        }
    }
}
