@{
    RootModule = 'DevPilot.OwnerModelRunner.psm1'
    ModuleVersion = '0.4.0'
    GUID = '70707070-8181-9292-a3a3-b4b4b4b4b4b4'
    Author = 'DevPilot Agents contributors'
    CompanyName = 'Unknown'
    Copyright = '(c) DevPilot Agents contributors. All rights reserved.'
    Description = 'Preview-only bounded process and offline replay runners for the Owner v2 semantic capability.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'Get-OwnerModelRunnerTelemetry',
        'New-OwnerCopilotCliModelProvider',
        'New-OwnerModelFakeProvider',
        'New-OwnerModelProcessRunner',
        'New-OwnerModelReplayFixture',
        'New-OwnerModelReplayRecord',
        'New-OwnerModelReplayRunner',
        'New-OwnerModelRunnerLimits',
        'Test-OwnerModelProviderPreflight'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('copilot', 'agents', 'review', 'owner', 'model', 'replay', 'powershell')
            ReleaseNotes = 'Enables the bounded no-tools runner through supported Copilot CLI prompt mode with explicit local argv exposure provenance.'
        }
    }
}
