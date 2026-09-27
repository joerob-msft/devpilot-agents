@{
    RootModule = 'DevPilot.ActiveOwnerEvaluation.psm1'
    ModuleVersion = '1.0.0'
    Author = 'DevPilot Agents contributors'
    Description = 'Read-only, exact-head Owner evaluation through the bounded Owner v2 live orchestrator.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @('New-ActiveOwnerEvaluator', 'Invoke-ActiveOwnerEvaluation')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
