@{
    RootModule = 'DevPilot.ContextualConventions.psm1'
    ModuleVersion = '0.1.0'
    GUID = '95959595-a6a6-b7b7-c8c8-d9d9d9d9d9d9'
    Author = 'DevPilot Agents contributors'
    CompanyName = 'Unknown'
    Copyright = '(c) DevPilot Agents contributors. All rights reserved.'
    Description = 'Bounded Roslyn-backed contextual convention analysis for changed AzureUX-BPM code.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'Get-ContextualConventionOutcomes',
        'Get-ContextualConventionRuleIds'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
