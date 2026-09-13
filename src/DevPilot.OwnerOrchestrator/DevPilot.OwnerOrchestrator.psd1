@{
    RootModule = 'DevPilot.OwnerOrchestrator.psm1'
    ModuleVersion = '0.3.0'
    GUID = '81818181-9292-a3a3-b4b4-c5c5c5c5c5c5'
    Author = 'DevPilot Agents contributors'
    CompanyName = 'Unknown'
    Copyright = '(c) DevPilot Agents contributors. All rights reserved.'
    Description = 'Preview-only Owner v2 cohort orchestrator over acquisition, capability, replay, and explicitly enabled no-tools live runner layers.'
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
            ReleaseNotes = 'Connects the existing bounded no-tools Copilot provider to explicitly enabled live preview runs with persisted zero-write telemetry.'
        }
    }
}
