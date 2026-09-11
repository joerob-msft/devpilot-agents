@{
    RootModule = 'DevPilot.OwnerParity.psm1'
    ModuleVersion = '0.2.0'
    GUID = '19191919-2a2a-3b3b-4c4c-5d5d5d5d5d5d'
    Author = 'DevPilot Agents contributors'
    CompanyName = 'Unknown'
    Copyright = '(c) DevPilot Agents contributors. All rights reserved.'
    Description = 'Read-only Owner v1/v2 parity qualification and sanitized aggregate reporting.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'Compare-OwnerParitySnapshots',
        'ConvertTo-OwnerParitySanitizedSummary',
        'Get-OwnerParityStateSnapshot',
        'Invoke-OwnerParityGateEvaluation',
        'Invoke-OwnerParityQualification',
        'Test-OwnerParityPathIsolation'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('copilot', 'agents', 'owner', 'parity', 'qualification', 'powershell')
            ReleaseNotes = 'Adds canonical semantic bindings, exact-byte references, explicit telemetry states, and critical/volatile read-only attestation.'
        }
    }
}
