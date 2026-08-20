#!/usr/bin/env pwsh
<#
.SYNOPSIS
    The twelve stage producer/consumer boundaries of the reviewer coordinator,
    as registered contracts with a builder each.

.DESCRIPTION
    StageContract.ps1 says how a stage contract is judged. This file says WHICH
    boundaries exist and what each one publishes, so "the contract is adopted"
    becomes a statement a test can check rather than a claim in a document.

    A boundary is one place where a stage hands a structured result to a later
    stage. The reviewer has twelve of them, in run order: capture, source,
    snapshot, corpus, blindResults, candidateUnion, fingerprints, specialistPlan,
    verifierAssignment, verdict, reconciliation, deliveryDecision.

    Each boundary has:

      * a registered kind and contract version, so a persisted artifact never has
        to be identified by guessing;
      * a builder - New-Reviewer<Stage>StageContract - which is the ONLY way its
        payload is assembled, and which returns the judged payload rather than
        setting a flag; and
      * a named real producer that calls the builder on the live path and reads
        its own result back out of the returned payload.

    The builder returning the payload is deliberate. A boundary whose verdict is
    discarded is a boundary that is not in force, so there is nothing to discard:
    the producer's own output IS the validated payload, and deleting the call
    leaves an undefined variable that fails at the first read under
    Set-StrictMode rather than silently reverting to the unchecked shape.

    Nothing here reads a file, opens a session, calls a model, or writes
    anything. Persisting a boundary payload is Write-ReviewerStageArtifact's job
    and stays with the caller that owns the path.
#>

Set-StrictMode -Version Latest

if (-not (Get-Variable -Name 'ReviewerStageContractRegistry' -Scope Script -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'StageContract.ps1')
}

$script:ReviewerStageProducerContractVersion = 1

# One row per boundary. This table is the single source of truth: the registry is
# built from it, the checked-in schema is compared against it, and the coverage
# matrix binds every inventoried field to the row for its stage.
$script:ReviewerStageProducerContracts = [object[]]@(
    [pscustomobject][ordered]@{
        Stage = 'capture'
        Kind = 'reviewer.stage.capture.v1'
        Builder = 'New-ReviewerCaptureStageContract'
        Producer = 'Assert-ReviewerAcquisitionTranscriptPackage'
        ProducerFile = 'src/Agents/reviewer/AcquisitionPackage.ps1'
        Summary = 'The authenticated transcript package, as the set of bound files, bound directories, and per-attempt marker statuses the capture published.'
        RequiredFields = [string[]]@('packageFiles', 'packageDirectories', 'attemptMarkerStatuses')
        CollectionFields = [string[]]@('packageFiles', 'packageDirectories', 'attemptMarkerStatuses')
        MapFields = [string[]]@()
        CollectionSlot = 'packageFiles'
        MapSlot = ''
    },
    [pscustomobject][ordered]@{
        Stage = 'source'
        Kind = 'reviewer.stage.source.v1'
        Builder = 'New-ReviewerSourceStageContract'
        Producer = 'Get-ReviewerSourceRawChangedPaths'
        ProducerFile = 'src/Agents/reviewer/SourceTransport.ps1'
        Summary = 'The raw changed-path census a change set named, before normalization, so a rejected path stays in the denominator.'
        RequiredFields = [string[]]@('changedPaths')
        CollectionFields = [string[]]@('changedPaths')
        MapFields = [string[]]@()
        CollectionSlot = 'changedPaths'
        MapSlot = ''
    },
    [pscustomobject][ordered]@{
        Stage = 'snapshot'
        Kind = 'reviewer.stage.snapshot.v1'
        Builder = 'New-ReviewerSnapshotStageContract'
        Producer = 'Get-ReviewerCorpusSealSpanEvidence'
        ProducerFile = 'src/Agents/reviewer/CorpusSeal.ps1'
        Summary = 'The authoritative right-hand span census derived from captured evidence: the ordered path list and the keyed path-to-spans map.'
        RequiredFields = [string[]]@('spanPaths', 'spansByPath')
        CollectionFields = [string[]]@('spanPaths')
        MapFields = [string[]]@('spansByPath')
        CollectionSlot = 'spanPaths'
        MapSlot = 'spansByPath'
    },
    [pscustomobject][ordered]@{
        Stage = 'corpus'
        Kind = 'reviewer.stage.corpus.v1'
        Builder = 'New-ReviewerCorpusStageContract'
        Producer = 'Get-ReviewerEvalGroundTruth'
        ProducerFile = 'src/Agents/reviewer/evaluation/Evaluation.ps1'
        Summary = 'The reconciled ground truth for one corpus example: the resolved issue set and the reason codes that explain a refusal to resolve.'
        RequiredFields = [string[]]@('issueIds', 'reasonCodes')
        CollectionFields = [string[]]@('issueIds', 'reasonCodes')
        MapFields = [string[]]@()
        CollectionSlot = 'issueIds'
        MapSlot = ''
    },
    [pscustomobject][ordered]@{
        Stage = 'blindResults'
        Kind = 'reviewer.stage.blindresults.v1'
        Builder = 'New-ReviewerBlindResultsStageContract'
        Producer = 'Expand-ReviewerConventionSpecialistConstructIds'
        ProducerFile = 'src/Agents/reviewer/ConventionSpecialist.ps1'
        Summary = 'The construct ids a blind specialist row accounted for, and the ids it named more than once.'
        RequiredFields = [string[]]@('constructIds', 'duplicatedConstructIds')
        CollectionFields = [string[]]@('constructIds', 'duplicatedConstructIds')
        MapFields = [string[]]@()
        CollectionSlot = 'constructIds'
        MapSlot = ''
    },
    [pscustomobject][ordered]@{
        Stage = 'candidateUnion'
        Kind = 'reviewer.stage.candidateunion.v1'
        Builder = 'New-ReviewerCandidateUnionStageContract'
        Producer = 'Get-ReviewerVerificationClusters'
        ProducerFile = 'src/Agents/reviewer/CrossVerification.ps1'
        Summary = 'The clustered union of discovered candidates, plus the candidate hashes pushed past the active cap.'
        RequiredFields = [string[]]@('clusters', 'overflowCandidateHashes')
        CollectionFields = [string[]]@('clusters', 'overflowCandidateHashes')
        MapFields = [string[]]@()
        CollectionSlot = 'clusters'
        MapSlot = ''
    },
    [pscustomobject][ordered]@{
        Stage = 'fingerprints'
        Kind = 'reviewer.stage.fingerprints.v1'
        Builder = 'New-ReviewerFingerprintsStageContract'
        Producer = 'Get-ReviewerGateApprovalCoverageKey'
        ProducerFile = 'src/Agents/reviewer/DeliveryGates.ps1'
        Summary = 'The two important-or-higher key sets an approval grant is bound to: the sealed gate set and the freshly confirmed set.'
        RequiredFields = [string[]]@('gateImportantOrHigherKeys', 'confirmedImportantOrHigherKeys')
        CollectionFields = [string[]]@('gateImportantOrHigherKeys', 'confirmedImportantOrHigherKeys')
        MapFields = [string[]]@()
        CollectionSlot = 'gateImportantOrHigherKeys'
        MapSlot = ''
    },
    [pscustomobject][ordered]@{
        Stage = 'specialistPlan'
        Kind = 'reviewer.stage.specialistplan.v1'
        Builder = 'New-ReviewerSpecialistPlanStageContract'
        Producer = 'Get-ReviewerChangedConstructs'
        ProducerFile = 'src/Agents/reviewer/ChangedConstructs.ps1'
        Summary = 'The deterministic construct census the specialist plan is anchored to, and the files it could only partially model.'
        RequiredFields = [string[]]@('invocations', 'declarations', 'comments', 'assignments', 'partialFiles', 'fileSummaries')
        CollectionFields = [string[]]@('invocations', 'declarations', 'comments', 'assignments', 'partialFiles', 'fileSummaries')
        MapFields = [string[]]@()
        CollectionSlot = 'invocations'
        MapSlot = ''
    },
    [pscustomobject][ordered]@{
        Stage = 'verifierAssignment'
        Kind = 'reviewer.stage.verifierassignment.v1'
        Builder = 'New-ReviewerVerifierAssignmentStageContract'
        Producer = 'Get-ReviewerVerificationAssignments'
        ProducerFile = 'src/Agents/reviewer/CrossVerification.ps1'
        Summary = 'The sealed verifier assignment plan: one row per candidate and verifier model, and the model pair it was cut against.'
        RequiredFields = [string[]]@('assignments', 'verifierModels')
        CollectionFields = [string[]]@('assignments', 'verifierModels')
        MapFields = [string[]]@()
        CollectionSlot = 'assignments'
        MapSlot = ''
    },
    [pscustomobject][ordered]@{
        Stage = 'verdict'
        Kind = 'reviewer.stage.verdict.v1'
        Builder = 'New-ReviewerVerdictStageContract'
        Producer = 'Get-ReviewerVerificationAcceptedConventionCandidates'
        ProducerFile = 'src/Agents/reviewer/CrossVerification.ps1'
        Summary = 'The candidates the verifiers accepted, after severity correction and debt follow-up resolution.'
        RequiredFields = [string[]]@('acceptedCandidates')
        CollectionFields = [string[]]@('acceptedCandidates')
        MapFields = [string[]]@()
        CollectionSlot = 'acceptedCandidates'
        MapSlot = ''
    },
    [pscustomobject][ordered]@{
        Stage = 'reconciliation'
        Kind = 'reviewer.stage.reconciliation.v1'
        Builder = 'New-ReviewerReconciliationStageContract'
        Producer = 'Get-ReviewerRunReconciliationDifference'
        ProducerFile = 'src/Agents/reviewer/RunReconciliation.ps1'
        Summary = 'The exact-key difference between two runs of the same frozen input, kept as two ordered sides rather than one merged set.'
        RequiredFields = [string[]]@('onlyLeft', 'onlyRight')
        CollectionFields = [string[]]@('onlyLeft', 'onlyRight')
        MapFields = [string[]]@()
        CollectionSlot = 'onlyLeft'
        MapSlot = ''
    },
    [pscustomobject][ordered]@{
        Stage = 'deliveryDecision'
        Kind = 'reviewer.stage.deliverydecision.v1'
        Builder = 'New-ReviewerDeliveryDecisionStageContract'
        Producer = 'Select-ReviewerGateSubset'
        ProducerFile = 'src/Agents/reviewer/DeliveryGates.ps1'
        Summary = 'The remove-only delivery subset: the approved entries whose key survived the allow-list, in the approved order.'
        RequiredFields = [string[]]@('selectedEntries')
        CollectionFields = [string[]]@('selectedEntries')
        MapFields = [string[]]@()
        CollectionSlot = 'selectedEntries'
        MapSlot = ''
    }
)

function Get-ReviewerStageProducerContract {
    <#
    .SYNOPSIS
        The twelve boundary descriptors, in run order, as a real collection.
    #>
    param([string]$Stage = '')

    if ([string]::IsNullOrEmpty($Stage)) {
        Write-Output -NoEnumerate ([object[]]$script:ReviewerStageProducerContracts)
        return
    }
    $matched = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $script:ReviewerStageProducerContracts) {
        if ([string]$row.Stage -ceq $Stage) { [void]$matched.Add($row) }
    }
    if ($matched.Count -ne 1) {
        throw "There is no single stage producer contract for stage '$Stage'."
    }
    return $matched[0]
}

function Register-ReviewerStageProducerContract {
    <#
    .SYNOPSIS
        Registers all twelve boundary kinds with the shared stage contract
        registry. Idempotent: re-registering restates the same declaration.
    #>
    foreach ($row in $script:ReviewerStageProducerContracts) {
        Register-ReviewerStageContract `
            -Kind ([string]$row.Kind) `
            -ContractVersion $script:ReviewerStageProducerContractVersion `
            -RequiredFields ([string[]]$row.RequiredFields) `
            -CollectionFields ([string[]]$row.CollectionFields) `
            -MapFields ([string[]]$row.MapFields) | Out-Null
    }
}

Register-ReviewerStageProducerContract

# ---------------------------------------------------------------------------
# Builders. One per boundary; each returns the judged payload.
# ---------------------------------------------------------------------------

function New-ReviewerCaptureStageContract {
    param(
        [Parameter(Mandatory)][AllowNull()]$PackageFiles,
        [Parameter(Mandatory)][AllowNull()]$PackageDirectories,
        [Parameter(Mandatory)][AllowNull()]$AttemptMarkerStatuses,
        [string]$Producer = 'Assert-ReviewerAcquisitionTranscriptPackage'
    )

    return Assert-ReviewerStageContract -Kind 'reviewer.stage.capture.v1' -Producer $Producer -Payload ([ordered]@{
            packageFiles = $PackageFiles
            packageDirectories = $PackageDirectories
            attemptMarkerStatuses = $AttemptMarkerStatuses
        })
}

function New-ReviewerSourceStageContract {
    param(
        [Parameter(Mandatory)][AllowNull()]$ChangedPaths,
        [string]$Producer = 'Get-ReviewerSourceRawChangedPaths'
    )

    return Assert-ReviewerStageContract -Kind 'reviewer.stage.source.v1' -Producer $Producer -Payload ([ordered]@{
            changedPaths = $ChangedPaths
        })
}

function New-ReviewerSnapshotStageContract {
    param(
        [Parameter(Mandatory)][AllowNull()]$SpanPaths,
        [Parameter(Mandatory)][AllowNull()]$SpansByPath,
        [string]$Producer = 'Get-ReviewerCorpusSealSpanEvidence'
    )

    return Assert-ReviewerStageContract -Kind 'reviewer.stage.snapshot.v1' -Producer $Producer -Payload ([ordered]@{
            spanPaths = $SpanPaths
            spansByPath = $SpansByPath
        })
}

function New-ReviewerCorpusStageContract {
    param(
        [Parameter(Mandatory)][AllowNull()]$IssueIds,
        [Parameter(Mandatory)][AllowNull()]$ReasonCodes,
        [string]$Producer = 'Get-ReviewerEvalGroundTruth'
    )

    return Assert-ReviewerStageContract -Kind 'reviewer.stage.corpus.v1' -Producer $Producer -Payload ([ordered]@{
            issueIds = $IssueIds
            reasonCodes = $ReasonCodes
        })
}

function New-ReviewerBlindResultsStageContract {
    param(
        [Parameter(Mandatory)][AllowNull()]$ConstructIds,
        [Parameter(Mandatory)][AllowNull()]$DuplicatedConstructIds,
        [string]$Producer = 'Expand-ReviewerConventionSpecialistConstructIds'
    )

    return Assert-ReviewerStageContract -Kind 'reviewer.stage.blindresults.v1' -Producer $Producer -Payload ([ordered]@{
            constructIds = $ConstructIds
            duplicatedConstructIds = $DuplicatedConstructIds
        })
}

function New-ReviewerCandidateUnionStageContract {
    param(
        [Parameter(Mandatory)][AllowNull()]$Clusters,
        [Parameter(Mandatory)][AllowNull()]$OverflowCandidateHashes,
        [string]$Producer = 'Get-ReviewerVerificationClusters'
    )

    return Assert-ReviewerStageContract -Kind 'reviewer.stage.candidateunion.v1' -Producer $Producer -Payload ([ordered]@{
            clusters = $Clusters
            overflowCandidateHashes = $OverflowCandidateHashes
        })
}

function New-ReviewerFingerprintsStageContract {
    param(
        [Parameter(Mandatory)][AllowNull()]$GateImportantOrHigherKeys,
        [Parameter(Mandatory)][AllowNull()]$ConfirmedImportantOrHigherKeys,
        [string]$Producer = 'Get-ReviewerGateApprovalCoverageKey'
    )

    return Assert-ReviewerStageContract -Kind 'reviewer.stage.fingerprints.v1' -Producer $Producer -Payload ([ordered]@{
            gateImportantOrHigherKeys = $GateImportantOrHigherKeys
            confirmedImportantOrHigherKeys = $ConfirmedImportantOrHigherKeys
        })
}

function New-ReviewerSpecialistPlanStageContract {
    param(
        [Parameter(Mandatory)][AllowNull()]$Invocations,
        [Parameter(Mandatory)][AllowNull()]$Declarations,
        [Parameter(Mandatory)][AllowNull()]$Comments,
        [Parameter(Mandatory)][AllowNull()]$Assignments,
        [Parameter(Mandatory)][AllowNull()]$PartialFiles,
        [Parameter(Mandatory)][AllowNull()]$FileSummaries,
        [string]$Producer = 'Get-ReviewerChangedConstructs'
    )

    return Assert-ReviewerStageContract -Kind 'reviewer.stage.specialistplan.v1' -Producer $Producer -Payload ([ordered]@{
            invocations = $Invocations
            declarations = $Declarations
            comments = $Comments
            assignments = $Assignments
            partialFiles = $PartialFiles
            fileSummaries = $FileSummaries
        })
}

function New-ReviewerVerifierAssignmentStageContract {
    param(
        [Parameter(Mandatory)][AllowNull()]$Assignments,
        [Parameter(Mandatory)][AllowNull()]$VerifierModels,
        [string]$Producer = 'Get-ReviewerVerificationAssignments'
    )

    return Assert-ReviewerStageContract -Kind 'reviewer.stage.verifierassignment.v1' -Producer $Producer -Payload ([ordered]@{
            assignments = $Assignments
            verifierModels = $VerifierModels
        })
}

function New-ReviewerVerdictStageContract {
    param(
        [Parameter(Mandatory)][AllowNull()]$AcceptedCandidates,
        [string]$Producer = 'Get-ReviewerVerificationAcceptedConventionCandidates'
    )

    return Assert-ReviewerStageContract -Kind 'reviewer.stage.verdict.v1' -Producer $Producer -Payload ([ordered]@{
            acceptedCandidates = $AcceptedCandidates
        })
}

function New-ReviewerReconciliationStageContract {
    param(
        [Parameter(Mandatory)][AllowNull()]$OnlyLeft,
        [Parameter(Mandatory)][AllowNull()]$OnlyRight,
        [string]$Producer = 'Get-ReviewerRunReconciliationDifference'
    )

    return Assert-ReviewerStageContract -Kind 'reviewer.stage.reconciliation.v1' -Producer $Producer -Payload ([ordered]@{
            onlyLeft = $OnlyLeft
            onlyRight = $OnlyRight
        })
}

function New-ReviewerDeliveryDecisionStageContract {
    param(
        [Parameter(Mandatory)][AllowNull()]$SelectedEntries,
        [string]$Producer = 'Select-ReviewerGateSubset'
    )

    return Assert-ReviewerStageContract -Kind 'reviewer.stage.deliverydecision.v1' -Producer $Producer -Payload ([ordered]@{
            selectedEntries = $SelectedEntries
        })
}

function Invoke-ReviewerStageProducerBuilder {
    <#
    .SYNOPSIS
        Calls one boundary's builder with a caller-supplied value in its declared
        collection or map slot and every other declared field held at a
        well-formed empty value.

    .DESCRIPTION
        This is how the cardinality corpus drives a real boundary rather than a
        stand-in: the value under test goes into the slot the stage actually
        publishes, and the builder that the live producer calls is the one that
        judges it. It exists in production code, not in the test, so a boundary
        cannot be exercised by a copy that has drifted from the one in force.
    #>
    param(
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][AllowNull()]$Value,
        [Parameter(Mandatory)][ValidateSet('collection', 'map')][string]$Slot,
        [string]$Producer = ''
    )

    $row = Get-ReviewerStageProducerContract -Stage $Stage
    $slotName = if ($Slot -ceq 'map') { [string]$row.MapSlot } else { [string]$row.CollectionSlot }
    if ([string]::IsNullOrEmpty($slotName)) {
        throw "Stage '$Stage' declares no $Slot slot."
    }
    $arguments = @{}
    foreach ($field in [string[]]$row.CollectionFields) {
        $arguments[(ConvertTo-ReviewerStageProducerParameterName -Field $field)] = [object[]]@()
    }
    foreach ($field in [string[]]$row.MapFields) {
        $arguments[(ConvertTo-ReviewerStageProducerParameterName -Field $field)] = [ordered]@{}
    }
    # Assigned, not spliced in place: the slot under test must carry exactly what
    # the caller handed over, including $null and a bare scalar, which is the
    # whole point of driving it.
    $arguments[(ConvertTo-ReviewerStageProducerParameterName -Field $slotName)] = $Value
    if (-not [string]::IsNullOrEmpty($Producer)) { $arguments['Producer'] = $Producer }
    return & ([string]$row.Builder) @arguments
}

function ConvertTo-ReviewerStageProducerParameterName {
    <#
    .SYNOPSIS
        The builder parameter name for a declared payload field. Payload fields
        are camelCase because they are JSON; parameters are PascalCase because
        they are PowerShell, and the mapping is mechanical rather than a second
        table that could disagree with the first.
    #>
    param([Parameter(Mandatory)][string]$Field)

    if ($Field.Length -eq 0) { throw 'A stage contract field name cannot be empty.' }
    return $Field.Substring(0, 1).ToUpperInvariant() + $Field.Substring(1)
}
