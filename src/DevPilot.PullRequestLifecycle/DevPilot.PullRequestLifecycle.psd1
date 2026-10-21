@{
    RootModule = 'DevPilot.PullRequestLifecycle.psm1'
    ModuleVersion = '1.0.0'
    GUID = 'f5f0a067-cacf-4d99-b18b-b566855808ba'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'Get-StalePrLifecycleConfiguration'
        'Initialize-StalePrLifecycleRoot'
        'Get-StalePrLifecycleKey'
        'New-StalePrLifecyclePolicy'
        'Write-StalePrLifecyclePolicy'
        'Read-StalePrLifecyclePolicy'
        'Assert-StalePrLifecyclePolicy'
        'New-StalePrAzureDevOpsProvider'
        'Invoke-StalePrLifecycle'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
