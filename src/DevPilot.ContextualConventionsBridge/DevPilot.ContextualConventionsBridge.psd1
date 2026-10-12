@{
    RootModule = 'DevPilot.ContextualConventionsBridge.psm1'
    ModuleVersion = '0.1.0'
    GUID = 'a6a6a6a6-b7b7-c8c8-d9d9-e0e0e0e0e0e0'
    Author = 'DevPilot Agents contributors'
    CompanyName = 'Unknown'
    Copyright = '(c) DevPilot Agents contributors. All rights reserved.'
    Description = 'Bridge from shared active PR acquisition to the fixed contextual convention capability.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'Invoke-ContextualConventionsCurrentPrBridge'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
