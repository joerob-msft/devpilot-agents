@{
    RootModule = 'DevPilot.RuleEvaluation.psm1'
    ModuleVersion = '1.0.0'
    GUID = '56565656-7878-9090-1212-343434343434'
    PowerShellVersion = '7.0'
    FunctionsToExport = @('Invoke-BoundedRuleEvaluation',
        'Assert-BoundedCandidateIntake', 'Invoke-BoundedCandidateParser')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
