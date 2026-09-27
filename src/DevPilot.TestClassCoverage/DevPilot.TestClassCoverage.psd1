@{
    RootModule = 'DevPilot.TestClassCoverage.psm1'
    ModuleVersion = '1.0.0'
    GUID = '34343434-4545-5656-6767-787878787878'
    Author = 'DevPilot Agents contributors'
    CompanyName = 'Unknown'
    Copyright = '(c) DevPilot Agents contributors. All rights reserved.'
    Description = 'Bounded, conservative extraction of changed C# class and method coverage constructs.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @('Get-TestClassCoverageConstructs', 'Get-RedundantMethodCoverageConstructs', 'Get-NamedAreEqualConstructs')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
