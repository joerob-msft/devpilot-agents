@{
    RootModule = 'DevPilot.OwnerOrchestrator.psm1'
    ModuleVersion = '0.1.0'
    GUID = '81818181-9292-a3a3-b4b4-c5c5c5c5c5c5'
    Author = 'DevPilot Agents contributors'
    CompanyName = 'Unknown'
    Copyright = '(c) DevPilot Agents contributors. All rights reserved.'
    Description = 'Preview-only Owner v2 cohort orchestrator over acquisition, capability, and replay runner layers.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'Get-OwnerV2PreviewStatus',
        'Invoke-OwnerV2PreviewPrepare',
        'Invoke-OwnerV2PreviewRun'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('copilot', 'agents', 'owner', 'preview', 'orchestrator', 'powershell')
            ReleaseNotes = 'Adds the layer 5 preview-only Owner v2 cohort orchestrator and state lifecycle.'
        }
    }
}
