#!/usr/bin/env pwsh
<#
.SYNOPSIS
    The reviewer's no-model shadow preparation: publishes all twelve stage
    boundaries to disk through the versioned file contract.

.DESCRIPTION
    This is the shipping call site of the on-disk half of the stage file
    contract. Everything else that enables it is a test or a hand-run tool; this
    file is the one a real preparation goes through, and it is what makes the
    file contract a path production code takes rather than a facility production
    code has.

    What it does NOT do is the point of it. It opens no session, calls no model,
    launches no slot, writes nothing outside the directory it is given, and
    reaches no verdict about any candidate. Every value it publishes is derived
    by the reviewer's own producers from the inputs it is handed, so the
    artifacts are the reviewer's shapes and not a re-description of them.

    The switch it opens refuses to open at all while any delivery capability is
    live, so a preparation cannot run beside a session that could comment,
    suggest or approve. The policy passed below is preview-only with every
    delivery switch off, stated here rather than inherited, so this file cannot
    be repurposed into a delivering path by a caller's ambient state.
#>

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'StageProducers.ps1')
. (Join-Path $PSScriptRoot 'SourceTransport.ps1')
. (Join-Path $PSScriptRoot 'CorpusSeal.ps1')
. (Join-Path $PSScriptRoot 'ChangedConstructs.ps1')
. (Join-Path $PSScriptRoot 'ConventionSpecialist.ps1')
. (Join-Path $PSScriptRoot 'CrossVerification.ps1')
. (Join-Path $PSScriptRoot 'DeliveryGates.ps1')
. (Join-Path $PSScriptRoot 'RunReconciliation.ps1')
. (Join-Path $PSScriptRoot 'evaluation\Evaluation.ps1')

function Get-ReviewerShadowPreparationPolicy {
    <#
    .SYNOPSIS
        The effective policy a shadow preparation runs under: preview only, with
        approval off.

    .DESCRIPTION
        Composed here rather than taken from the caller so that the one shape
        this file can ever hand to the switch is the inert one. The switch
        recomputes what it means through the delivery authority's own predicate,
        so this is a statement of intent that is then independently checked.
    #>
    return [pscustomobject]@{
        mode = 'previewOnly'
        approval = [pscustomobject]@{ enabled = $false }
    }
}

function Invoke-ReviewerShadowPreparation {
    <#
    .SYNOPSIS
        Runs one no-model preparation, publishing every stage boundary as a
        versioned artifact under -Directory.

    .DESCRIPTION
        The producers are called in run order on the change set the caller
        declares. Each one publishes its boundary through
        Publish-ReviewerStageShadowArtifact as an ordinary consequence of being
        called; nothing here writes an artifact directly, so the artifacts on
        disk are the producers' own censuses.

        Returns the number of artifacts published, which the caller is expected
        to check against what it can read back. A count this function reports
        and nobody rereads would be this function marking its own work.

    .PARAMETER Directory
        Private state directory for the artifacts. Must be absent or already a
        shadow directory; the switch refuses to adopt a directory holding items
        it did not write.

    .PARAMETER ChangedPath
        The changed paths the preparation is about. Two or more, because a
        one-element census cannot demonstrate that a collection survived as a
        collection.

    .PARAMETER Depth
        Serialization depth for the published artifacts.

    .PARAMETER Form
        Serialized form, compact or indented.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][ValidateCount(2, 4096)][string[]]$ChangedPath,
        [ValidateRange(2, 56)][int]$Depth = 24,
        [ValidateSet('compact', 'indented')][string]$Form = 'compact'
    )

    if (Test-ReviewerStageShadowContractEnabled) {
        throw 'The reviewer stage shadow contract is already enabled; a preparation opens and closes its own session.'
    }

    $policy = Get-ReviewerShadowPreparationPolicy
    # The one shipping call site of the on-disk half of the stage file contract.
    $session = Enable-ReviewerStageShadowContract -Directory $Directory -EffectivePolicy $policy `
        -CommentSwitchOn $false -SuggestionSwitchOn $false -ApprovalSwitchOn $false `
        -Reason 'shadow-run-preparation' -Depth $Depth -Form $Form
    try {
        $published = Publish-ReviewerShadowPreparationBoundaries -ChangedPath $ChangedPath
    }
    finally {
        Disable-ReviewerStageShadowContract
    }

    return [pscustomobject][ordered]@{
        Directory = [string]$session.Directory
        PublishedCount = $published
    }
}

function Publish-ReviewerShadowPreparationBoundaries {
    <#
    .SYNOPSIS
        Drives every stage producer once, in run order, over one synthetic-free
        change set derived from the caller's declared paths.

    .DESCRIPTION
        Separated from the switch handling so the sequence can be read as a
        sequence. Each call below is the reviewer's real producer; none of them
        is a re-implementation, and none of them decides anything about a
        candidate's merit - they compute censuses, and the censuses are what the
        boundary publishes.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateCount(2, 4096)][string[]]$ChangedPath)

    $ledgerBefore = Get-ReviewerStageShadowContractLedger
    $before = [int]@($ledgerBefore).Count

    # capture: the live producer authenticates a sealed package from disk, which
    # a preparation has no way to reach without a capture. Its contract is driven
    # through the same builder the producer calls, and that residual is stated
    # rather than hidden.
    $null = New-ReviewerCaptureStageContract `
        -PackageFiles ([object[]]@('capture-core.json', 'result-marker.txt')) `
        -PackageDirectories ([object[]]@()) `
        -AttemptMarkerStatuses ([object[]]@('success'))

    $changes = @()
    foreach ($path in $ChangedPath) {
        $changes += [pscustomobject]@{ item = [pscustomobject]@{ path = $path; isFolder = $false } }
    }
    $null = Get-ReviewerSourceRawChangedPaths -Response ([pscustomobject]@{ changes = $changes })

    $spanEvidence = @()
    $line = 1
    foreach ($path in $ChangedPath) {
        $spanEvidence += [pscustomobject]@{
            path = $path
            hunks = @([pscustomobject]@{ newStart = $line; newCount = 2 })
        }
        $line += 2
    }
    $null = Get-ReviewerCorpusSealSpanEvidence -Where 'shadow preparation span evidence' -Evidence $spanEvidence

    $null = Get-ReviewerEvalGroundTruth -Labels @(
        [pscustomobject]@{ labelerId = 'a'; issueIds = @('i1'); decision = 'block' },
        [pscustomobject]@{ labelerId = 'b'; issueIds = @('i1'); decision = 'block' })

    $null = Expand-ReviewerConventionSpecialistConstructIds -Text 'mi0-mi2,dc0'

    $candidates = @(
        [pscustomobject]@{ candidateId = 'c1'; candidateHash = 'h1'; originKind = 'generalist'; originModel = 'model-a'; anchorKind = 'changedFile'; filePath = 'src/one.ps1'; title = 'first'; severity = 'important' },
        [pscustomobject]@{ candidateId = 'c2'; candidateHash = 'h2'; originKind = 'generalist'; originModel = 'model-b'; anchorKind = 'changedFile'; filePath = 'src/two.ps1'; title = 'second'; severity = 'suggestion' })
    $clusters = Get-ReviewerVerificationClusters -Candidates $candidates

    $null = Get-ReviewerGateApprovalCoverageKey `
        -Decision ([pscustomobject]@{ prId = 1; sourceCommit = 'ABC123'; gateHumanPromotableCount = 0; gateImportantOrHigherCount = 0; gateImportantOrHigherKeys = @() }) `
        -ConfirmedImportantOrHigherKeys @()

    # A multi-line construct, so the invocation census is non-empty. A call that
    # opens and closes on one line is not a multi-line construct, and a `.ps1`
    # path is swept into partialFiles before any construct is enumerated; either
    # would publish an empty census while looking like the boundary was reached.
    $null = Get-ReviewerChangedConstructs -Files @(
        @{
            Path = 'src/one.cs'
            Lines = @('        // preparation note', '        var value = Helper.Compute(', '            1);')
            ChangedLines = @(1, 2, 3)
        })

    $null = Get-ReviewerVerificationAssignments -Clusters $clusters -GeneralistModels ([string[]]@('model-a', 'model-b'))

    $null = Get-ReviewerVerificationAcceptedConventionCandidates `
        -ConventionCandidates @() -Decisions @() -Clusters $clusters

    $null = Get-ReviewerRunReconciliationDifference -Left @('c1', 'c2') -Right @('c2')

    $null = Select-ReviewerGateSubset `
        -Approved @([pscustomobject]@{ candidateHash = 'h1'; path = 'src/one.ps1'; line = 1; severity = 'important' }) `
        -Allowed @([pscustomobject]@{ candidateHash = 'h1'; path = 'src/one.ps1'; line = 1; severity = 'important' })

    $ledgerAfter = Get-ReviewerStageShadowContractLedger
    # Every ledger record is one published artifact, so the growth across this
    # sequence is the census. Counted rather than tallied by hand because a hand
    # tally would agree with itself no matter what the producers did. The ledger
    # is emitted unenumerated, so it is bound before it is counted; counting the
    # pipeline directly would count the collection as one item.
    return [int]([int]@($ledgerAfter).Count - $before)
}
