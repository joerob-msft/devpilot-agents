@{
    RootModule = 'OwnerObserver.psm1'
    ModuleVersion = '1.0.0'
    GUID = '11111111-2222-3333-4444-555555555555'
    Author = 'DevPilot Agents contributors'
    CompanyName = 'Unknown'
    Copyright = '(c) DevPilot Agents contributors. All rights reserved.'
    Description = 'Read-only normalization and parity comparison for Owner reviewer artifacts.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'Compare-OwnerObservations',
        'ConvertTo-OwnerObserverCanonicalJson',
        'ConvertTo-OwnerObserverDiagnostic',
        'Get-OwnerObserverHmac',
        'Read-OwnerNormalizedObservation',
        'Read-OwnerV1Observation',
        'Test-OwnerObservation'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
