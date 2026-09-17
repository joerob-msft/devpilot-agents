@{
    RootModule = 'OwnerObserver.psm1'
    ModuleVersion = '2.0.0'
    GUID = '11111111-2222-3333-4444-555555555555'
    Author = 'DevPilot Agents contributors'
    CompanyName = 'Unknown'
    Copyright = '(c) DevPilot Agents contributors. All rights reserved.'
    Description = 'Read-only normalization and parity comparison for Owner reviewer artifacts.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'Compare-OwnerObservations',
        'ConvertFrom-OwnerNormalizedObservationBytes',
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
    PrivateData = @{
        PSData = @{
            ReleaseNotes = 'Adds canonical repository bindings, semantic finding keys, provider marker integrity, and measured/unavailable/notMeasured telemetry.'
        }
    }
}
