@{
    RootModule = 'OwnerObservationContract.psm1'
    ModuleVersion = '1.0.0'
    GUID = '29292929-3a3a-4b4b-5c5c-6d6d6d6d6d6d'
    Author = 'DevPilot Agents contributors'
    CompanyName = 'Unknown'
    Copyright = '(c) DevPilot Agents contributors. All rights reserved.'
    Description = 'Versioned canonical Owner observation binding and measurement contract.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'Assert-OwnerRepositoryPathSet',
        'ConvertTo-OwnerContractCanonicalJson',
        'ConvertTo-OwnerRepositoryPath',
        'Get-OwnerSemanticFindingKey',
        'New-OwnerCanonicalAnchor',
        'New-OwnerMeasurement',
        'New-OwnerProviderMarker'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            ReleaseNotes = 'Defines the versioned canonical Owner path, span, semantic key, provider marker, and measurement contract.'
        }
    }
}
