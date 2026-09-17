@{
    RootModule = 'DevPilot.RelationEvidence.psm1'
    ModuleVersion = '0.1.0'
    GUID = '82828282-9393-a4a4-b5b5-c6c6c6c6c6c6'
    Author = 'DevPilot Agents contributors'
    CompanyName = 'Unknown'
    Copyright = '(c) DevPilot Agents contributors. All rights reserved.'
    Description = 'Preview-only bounded relation-evidence assessment capability over the generic Owner v2 facade.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'ConvertTo-RelationEvidenceCanonicalJson',
        'ConvertTo-RelationEvidenceObservation',
        'New-RelationEvidenceAcquisitionAdapter',
        'New-RelationEvidenceCapabilityAdapter',
        'New-RelationEvidenceLimits',
        'New-RelationEvidenceRequest'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('copilot', 'agents', 'review', 'relation', 'evidence', 'powershell')
            ReleaseNotes = 'Adds one bounded contextual assessment contract with wrapper-owned evidence, anchors, budgets, findings, and zero-write observations.'
        }
    }
}
