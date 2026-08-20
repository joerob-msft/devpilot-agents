#!/usr/bin/env pwsh
<#
.SYNOPSIS
    One no-model run that drives all twelve shipping stage producers with the
    on-disk contract switched on, and reports what was published.

.DESCRIPTION
    This is the adoption run. It enables the opt-in shadow switch, calls the
    twelve REAL producer functions the coordinator calls - including the capture
    producer, against a genuinely sealed transcript package minted by the
    production acquisition runner - and lets each producer publish and read back
    its own versioned envelope through the shared writer and reader.

    Nothing here simulates a boundary. Every artifact under the output root was
    written by Write-ReviewerStageArtifact from inside the shipping producer's
    own builder and read back by Read-ReviewerStageArtifact before that
    producer returned.

    No model, provider, session, or external write is involved. The capture
    package carries the acquisition's own zero-write telemetry as sealed
    evidence; every other stage is a pure function of its arguments. This script
    starts no process at all, and the suite that drives it checks that claim by
    scanning this file against a fixed denylist of direct provider, model and
    external-write API names - a name check, neither transitive nor behavioural,
    so it catches a direct reintroduction and not an indirect one.

    Three digests are reported per artifact because they answer different
    questions, and the difference between the last two is the point.
    `exactSha256` is the bytes that landed. `structuralSha256` removes map key
    order - a serializer artifact - but KEEPS every array order, so it can still
    see a stage reordering its own output. `orderCompensatedSha256` is the same
    except that the individually named fields in `$script:ShadowRunUnorderedFields`
    are compared as multisets. Exactly two fields are named, both on the capture
    stage: `packageFiles` and `packageDirectories` come out of a PowerShell
    hashtable and .NET randomizes string hashing per process, so two identical runs
    emit the same census in different orders. That is a producer defect in
    src/Agents/reviewer/AcquisitionPackage.ps1 being compensated for here, not a
    property of the data. Capture's third collection, `attemptMarkerStatuses`,
    follows the attempt ledger and keeps its order.

    `runGraphSha256` uses the strongest form each stage can support: structural for
    all twelve, relaxed only on those two named fields. An ordering regression
    anywhere else changes the graph digest instead of vanishing into a sort, and a
    NEW unstable field has to be named here to be tolerated.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),
    [Parameter(Mandatory)][string]$OutputRoot,
    [Parameter(Mandatory)][string]$CapturePackageRoot,
    [Parameter(Mandatory)][string]$CaptureSealKeyPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $RepoRoot 'src/Agents/reviewer/StageContract.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/StageShadow.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/StageProducers.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/SourceTransport.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/CorpusSeal.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/ConventionSpecialist.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/CrossVerification.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/DeliveryGates.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/ChangedConstructs.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/RunReconciliation.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/evaluation/Evaluation.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/AcquisitionPackage.ps1')

$utf8 = [System.Text.UTF8Encoding]::new($false, $true)

function ConvertTo-ShadowRunCanonical {
    <#
    .SYNOPSIS
        A payload rewritten so that map key order stops mattering. Array order is
        preserved except under the field names listed in -UnorderedFields.

    .DESCRIPTION
        Two different questions need two different canonical forms, and conflating
        them is how an ordering regression becomes invisible. Map key order is a
        serializer artifact and should never change a digest. ARRAY order usually
        is not: changed source paths, reconciliation sides, an attempt ledger and
        the delivery selection all mean something in the order they are in, so
        sorting them would produce a digest that cannot see a stage reordering its
        own output.

        Unordered treatment is therefore opt-in PER FIELD rather than per stage.
        Only the specific fields whose producer is known to emit them in an
        unstable order are compared as multisets; their siblings inside the very
        same payload keep their order.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()]$Node,
        [string[]]$UnorderedFields = [string[]]@(),
        [string]$FieldName = ''
    )

    if ($null -eq $Node) { return $null }
    if ($Node -is [string] -or $Node -is [bool] -or $Node -is [ValueType]) { return $Node }
    if ($Node -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in (@($Node.Keys) | Sort-Object -CaseSensitive)) {
            $ordered[[string]$key] = ConvertTo-ShadowRunCanonical -Node $Node[$key] `
                -UnorderedFields $UnorderedFields -FieldName ([string]$key)
        }
        return $ordered
    }
    if ($Node -is [System.Collections.IEnumerable]) {
        $elements = [System.Collections.Generic.List[object]]::new()
        foreach ($element in $Node) {
            [void]$elements.Add((ConvertTo-ShadowRunCanonical -Node $element `
                        -UnorderedFields $UnorderedFields -FieldName $FieldName))
        }
        if (-not ($UnorderedFields -ccontains $FieldName)) {
            return , [object[]]@($elements.ToArray())
        }
        $keyed = $elements | Sort-Object -Property @{ Expression = {
                [string](ConvertTo-Json -InputObject $_ -Depth 48 -Compress) } } -CaseSensitive
        return , [object[]]@($keyed)
    }
    if ($Node -is [psobject]) {
        $ordered = [ordered]@{}
        foreach ($property in (@($Node.PSObject.Properties) | Sort-Object -Property Name -CaseSensitive)) {
            $ordered[[string]$property.Name] = ConvertTo-ShadowRunCanonical -Node $property.Value `
                -UnorderedFields $UnorderedFields -FieldName ([string]$property.Name)
        }
        return $ordered
    }
    return $Node
}

# The one stage whose artifact is not byte-reproducible across processes, and the
# exact fields that are. The capture census draws packageFiles and
# packageDirectories from a Hashtable's key order, and .NET randomizes string
# hashing per process, so those two have to be compared as multisets. Its third
# collection, attemptMarkerStatuses, follows the attempt ledger and IS ordered -
# sorting it would hide a reordered attempt ledger, so it is deliberately left
# out. This is compensation for a known producer defect in
# src/Agents/reviewer/AcquisitionPackage.ps1, not a property of the data.
$script:ShadowRunUnorderedFields = [ordered]@{
    capture = [string[]]@('packageFiles', 'packageDirectories')
}

function Get-ShadowRunSha256 {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($utf8.GetBytes($Text))).ToLowerInvariant()
}

# ---------------------------------------------------------------------------
# Private state. The switch refuses a directory holding anything it did not
# write, so a fresh, dedicated artifact directory is part of the contract.
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $OutputRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
}
$artifactDir = Join-Path ((Resolve-Path -LiteralPath $OutputRoot).ProviderPath) 'artifacts'

# The effective policy of a run that may write nothing at all. It is handed to
# the delivery authority rather than interpreted here, so the switch's refusal
# is computed by the same code the delivery path uses.
$previewPolicy = [pscustomobject]@{
    mode = 'previewOnly'
    approval = [pscustomobject]@{ enabled = $false }
}

$session = Enable-ReviewerStageShadowContract -Directory $artifactDir `
    -EffectivePolicy $previewPolicy -CommentSwitchOn $false -SuggestionSwitchOn $false `
    -ApprovalSwitchOn $false -Reason 'stage-contract-adoption-run'

$stageInvocations = [System.Collections.Generic.List[object]]::new()
try {
    # -- capture ----------------------------------------------------------
    # The one stage whose producer authenticates a sealed on-disk package. The
    # package handed in was minted by tools/Invoke-ReviewerBlindedAcquisition.ps1
    # against the offline adapter, so this is the production reader running over
    # production-produced bytes.
    $capturePackage = Assert-ReviewerAcquisitionTranscriptPackage `
        -PackageRoot $CapturePackageRoot -SealKeyPath $CaptureSealKeyPath -RequireCaptured
    [void]$stageInvocations.Add([pscustomobject]@{
            Stage = 'capture'; Producer = 'Assert-ReviewerAcquisitionTranscriptPackage'
            Detail = "attemptMarkerStatuses=$(@($capturePackage.AttemptMarkerStatuses).Count)"
        })

    # -- source -----------------------------------------------------------
    $changeSet = [pscustomobject]@{
        changes = [object[]]@(
            [pscustomobject]@{ item = [pscustomobject]@{ path = '/src/Widget.cs'; isFolder = $false } },
            [pscustomobject]@{ item = [pscustomobject]@{ path = '/src/Gadget.cs'; isFolder = $false } },
            [pscustomobject]@{ item = [pscustomobject]@{ path = '/docs/readme.md'; isFolder = $false } })
    }
    $rawPaths = Get-ReviewerSourceRawChangedPaths -Response $changeSet
    [void]$stageInvocations.Add([pscustomobject]@{
            Stage = 'source'; Producer = 'Get-ReviewerSourceRawChangedPaths'
            Detail = "changedPaths=$(@($rawPaths).Count)"
        })

    # -- snapshot ---------------------------------------------------------
    $spanEvidence = [object[]]@(
        [pscustomobject]@{ path = '/src/Widget.cs'; hunks = @([pscustomobject]@{ newStart = 1; newCount = 4 }) },
        [pscustomobject]@{ path = '/src/Gadget.cs'; hunks = @([pscustomobject]@{ newStart = 9; newCount = 2 }) })
    $spansByPath = Get-ReviewerCorpusSealSpanEvidence -Where 'stage shadow adoption run' -Evidence $spanEvidence
    [void]$stageInvocations.Add([pscustomobject]@{
            Stage = 'snapshot'; Producer = 'Get-ReviewerCorpusSealSpanEvidence'
            Detail = "spanPaths=$(@($spansByPath.Keys).Count)"
        })

    # -- corpus -----------------------------------------------------------
    $labels = [object[]]@(
        [pscustomobject]@{ labelerId = 'labeler-0'; issueIds = [string[]]@('i0', 'i1'); decision = 'block' },
        [pscustomobject]@{ labelerId = 'labeler-1'; issueIds = [string[]]@('i0', 'i1'); decision = 'block' })
    $groundTruth = Get-ReviewerEvalGroundTruth -Labels $labels
    [void]$stageInvocations.Add([pscustomobject]@{
            Stage = 'corpus'; Producer = 'Get-ReviewerEvalGroundTruth'
            Detail = "issueIds=$(@($groundTruth.issueIds).Count)"
        })

    # -- blindResults -----------------------------------------------------
    $constructIds = Expand-ReviewerConventionSpecialistConstructIds -Text 'mi0,mi1,dc0'
    [void]$stageInvocations.Add([pscustomobject]@{
            Stage = 'blindResults'; Producer = 'Expand-ReviewerConventionSpecialistConstructIds'
            Detail = "constructIds=$(@($constructIds.Ids).Count)"
        })

    # -- candidateUnion ---------------------------------------------------
    $generalistCandidates = [object[]]@(0, 1, 2 | ForEach-Object {
            [pscustomobject]@{
                candidateId = "c$_"; originCandidateId = "c$_"; candidateHash = "h$_"
                originKind = 'generalist'; originModel = 'model-a'; anchorKind = 'changedFile'
                filePath = "src/f$_.ps1"; title = "finding $_"; severity = 'important'
            }
        })
    $clusters = Get-ReviewerVerificationClusters -Candidates $generalistCandidates
    [void]$stageInvocations.Add([pscustomobject]@{
            Stage = 'candidateUnion'; Producer = 'Get-ReviewerVerificationClusters'
            Detail = "clusters=$(@($clusters).Count)"
        })

    # -- fingerprints -----------------------------------------------------
    $coverageKeys = [object[]]@('src/f0.ps1|0|important', 'src/f1.ps1|1|important')
    $coverage = Get-ReviewerGateApprovalCoverageKey -Decision ([pscustomobject]@{
            prId = 4242; sourceCommit = 'ABC123'; gateHumanPromotableCount = 0
            gateImportantOrHigherCount = $coverageKeys.Count
            gateImportantOrHigherKeys = $coverageKeys
        }) -ConfirmedImportantOrHigherKeys $coverageKeys
    [void]$stageInvocations.Add([pscustomobject]@{
            Stage = 'fingerprints'; Producer = 'Get-ReviewerGateApprovalCoverageKey'
            Detail = "coverage=$(@($coverage).Count)"
        })

    # -- specialistPlan ---------------------------------------------------
    # Modelled extensions and genuinely multi-line calls, or the construct
    # enumerator publishes an empty invocation census and the stage proves
    # nothing about its own shape.
    $constructFiles = [object[]]@(0, 1 | ForEach-Object {
            @{
                Path = "src/f$_.cs"
                Lines = @(
                    "        // reviewer thing $_",
                    "        var value$_ = Helper.Compute$_(",
                    '            1);')
                ChangedLines = @(1, 2, 3)
            }
        })
    $plan = Get-ReviewerChangedConstructs -Files $constructFiles
    [void]$stageInvocations.Add([pscustomobject]@{
            Stage = 'specialistPlan'; Producer = 'Get-ReviewerChangedConstructs'
            Detail = "constructs=$(@($plan.Constructs).Count)"
        })

    # -- verifierAssignment -----------------------------------------------
    $assignments = Get-ReviewerVerificationAssignments -Clusters ([object[]]@($clusters)) `
        -GeneralistModels ([string[]]@('model-a', 'model-b'))
    [void]$stageInvocations.Add([pscustomobject]@{
            Stage = 'verifierAssignment'; Producer = 'Get-ReviewerVerificationAssignments'
            Detail = "assignments=$(@($assignments).Count)"
        })

    # -- verdict ----------------------------------------------------------
    # A convention-origin set, clustered on its own: the accepted census is
    # judged over the specialist's candidates, not the generalists'.
    $conventionCandidates = [object[]]@(0, 1, 2 | ForEach-Object {
            [pscustomobject]@{
                candidateId = "v$_"; originCandidateId = "v$_"; candidateHash = "g$_"
                originKind = 'convention'; originModel = 'specialist-model'; anchorKind = 'changedFile'
                filePath = "src/g$_.ps1"; title = "convention finding $_"; severity = 'important'
            }
        })
    $conventionClusters = Get-ReviewerVerificationClusters -Candidates $conventionCandidates
    $decisions = [object[]]@(0, 1, 2 | ForEach-Object {
            [pscustomobject]@{
                candidateId = "v$_"; correctedSeverity = 'none'; existingDebtFollowUpRetained = $false
            }
        })
    $accepted = Get-ReviewerVerificationAcceptedConventionCandidates `
        -ConventionCandidates $conventionCandidates -Decisions $decisions `
        -Clusters ([object[]]@($conventionClusters))
    [void]$stageInvocations.Add([pscustomobject]@{
            Stage = 'verdict'; Producer = 'Get-ReviewerVerificationAcceptedConventionCandidates'
            Detail = "acceptedCandidates=$(@($accepted).Count)"
        })

    # -- reconciliation ---------------------------------------------------
    $difference = Get-ReviewerRunReconciliationDifference `
        -Left ([string[]]@('c0', 'c1', 'c2')) -Right ([string[]]@('c1'))
    [void]$stageInvocations.Add([pscustomobject]@{
            Stage = 'reconciliation'; Producer = 'Get-ReviewerRunReconciliationDifference'
            Detail = "onlyLeft=$(@($difference.OnlyLeft).Count)"
        })

    # -- deliveryDecision -------------------------------------------------
    $approved = [object[]]@(0, 1, 2 | ForEach-Object {
            [pscustomobject]@{ candidateHash = "h$_"; path = "src/f$_.ps1"; line = 1; severity = 'important' }
        })
    $selected = Select-ReviewerGateSubset -Approved $approved -Allowed ([object[]]@($approved[0], $approved[2]))
    [void]$stageInvocations.Add([pscustomobject]@{
            Stage = 'deliveryDecision'; Producer = 'Select-ReviewerGateSubset'
            Detail = "selectedEntries=$(@($selected).Count)"
        })
}
finally {
    Disable-ReviewerStageShadowContract
}

# ---------------------------------------------------------------------------
# What was published. Read from the shadow ledger and re-read from disk, so the
# report describes files rather than intentions.
# ---------------------------------------------------------------------------
$records = [object[]]@()
foreach ($entry in (Get-ReviewerStageShadowContractLedger)) { $records += , $entry }
$expectedStages = [string[]]@((Get-ReviewerStageProducerContract) | ForEach-Object { [string]$_.Stage })
$publishedStages = [string[]]@($records | ForEach-Object { [string]$_.Stage } | Sort-Object -Unique)
$missingStages = @($expectedStages | Where-Object { $publishedStages -cnotcontains $_ })
if ($missingStages.Count -gt 0) {
    throw ("The stage shadow run published no artifact for stage(s): $($missingStages -join ', '). " +
        "Ledger held $($records.Count) record(s): $($publishedStages -join ', ').")
}

$inventory = [object[]]@()
foreach ($entry in (Get-ReviewerStageArtifactInventory -Directory $artifactDir)) { $inventory += , $entry }
$unreadable = @($inventory | Where-Object { [string]$_.Status -cne 'envelope' -and
        [string]$_.Name -cne '.reviewer-stage-shadow.json' })
if ($unreadable.Count -gt 0) {
    throw "The stage shadow run left $($unreadable.Count) artifact(s) that do not read as an envelope."
}

$artifacts = [System.Collections.Generic.List[object]]::new()
foreach ($record in ($records | Sort-Object Sequence)) {
    $bytes = [IO.File]::ReadAllBytes([string]$record.Path)
    $exact = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    if ($exact -cne [string]$record.Sha256) {
        throw "Published artifact '$($record.Name)' changed on disk after publication."
    }
    $item = Get-Item -LiteralPath ([string]$record.Path)
    if (-not $item.IsReadOnly) {
        throw "Published artifact '$($record.Name)' is not read-only."
    }
    # Re-read through the strict reader once more, from the report's side of the
    # fence: adoption is a claim about what a CONSUMER can get off disk, not only
    # about what the producer managed to write.
    $reread = Read-ReviewerStageArtifact -Path ([string]$record.Path) -Kind ([string]$record.Kind)
    $unordered = [string[]]@($script:ShadowRunUnorderedFields[[string]$record.Stage])
    $unordered = [string[]]@($unordered | Where-Object { -not [string]::IsNullOrEmpty([string]$_) })
    $structural = ConvertTo-ShadowRunCanonical -Node $reread.Payload
    $compensated = ConvertTo-ShadowRunCanonical -Node $reread.Payload -UnorderedFields $unordered
    [void]$artifacts.Add([pscustomobject][ordered]@{
            sequence = [int]$record.Sequence
            stage = [string]$record.Stage
            name = [string]$record.Name
            kind = [string]$record.Kind
            contractVersion = [int]$record.ContractVersion
            producer = [string]$record.Producer
            form = [string]$record.Form
            depth = [int]$record.Depth
            byteLength = [int]$record.ByteLength
            readOnly = $true
            exactSha256 = $exact
            # Map key order removed, every array order kept. This is the digest a
            # reordering regression cannot hide from, and for eleven of the twelve
            # stages it is also the digest the graph uses.
            structuralSha256 = Get-ShadowRunSha256 -Text (
                ConvertTo-Json -InputObject $structural -Depth 48 -Compress)
            # The same, except the named fields below are compared as multisets to
            # compensate for a producer that emits them in an unstable order. Equal
            # to structuralSha256 wherever no field is named, which is everywhere
            # except capture.
            orderCompensatedSha256 = Get-ShadowRunSha256 -Text (
                ConvertTo-Json -InputObject $compensated -Depth 48 -Compress)
            orderCompensatedFields = $unordered
            observedCounts = $record.ObservedCounts
        })
}

$stageSummary = [ordered]@{}
foreach ($stage in $expectedStages) {
    $rows = @($artifacts | Where-Object { [string]$_.stage -ceq $stage })
    $unordered = [string[]]@($script:ShadowRunUnorderedFields[$stage])
    $unordered = [string[]]@($unordered | Where-Object { -not [string]::IsNullOrEmpty([string]$_) })
    # The graph digest uses the strongest form each stage can support: array order
    # intact everywhere, relaxed only on the individually named fields whose
    # producer emits them unordered.
    $graphField = if ($unordered.Count -eq 0) { 'structuralSha256' } else { 'orderCompensatedSha256' }
    $stageSummary[$stage] = [ordered]@{
        artifactCount = $rows.Count
        kind = [string]$rows[0].kind
        contractVersion = [int]$rows[0].contractVersion
        producer = [string]$rows[0].producer
        orderCompensatedFields = $unordered
        graphDigestBasis = $graphField
        graphSha256 = Get-ShadowRunSha256 -Text (
            ($rows | ForEach-Object { [string]$_.$graphField }) -join "`n")
        structuralSha256 = Get-ShadowRunSha256 -Text (
            ($rows | ForEach-Object { [string]$_.structuralSha256 }) -join "`n")
        orderCompensatedSha256 = Get-ShadowRunSha256 -Text (
            ($rows | ForEach-Object { [string]$_.orderCompensatedSha256 }) -join "`n")
        exactSha256 = Get-ShadowRunSha256 -Text (
            ($rows | ForEach-Object { [string]$_.exactSha256 }) -join "`n")
    }
}

$report = [pscustomobject][ordered]@{
    schemaVersion = 1
    kind = 'reviewer-stage-shadow-run'
    claim = 'on-disk-stage-contract-adoption-not-model-quality'
    sessionReason = [string]$session.Reason
    artifactDirectory = $artifactDir
    stageOrder = $expectedStages
    stageCount = $expectedStages.Count
    artifactCount = $artifacts.Count
    invocations = [object[]]@($stageInvocations)
    stages = $stageSummary
    artifacts = [object[]]@($artifacts)
    runGraphSha256 = Get-ShadowRunSha256 -Text (
        ($expectedStages | ForEach-Object { "$_=$($stageSummary[$_].graphSha256)" }) -join "`n")
    runOrderCompensatedSha256 = Get-ShadowRunSha256 -Text (
        ($expectedStages | ForEach-Object { "$_=$($stageSummary[$_].orderCompensatedSha256)" }) -join "`n")
    orderCompensatedFields = $script:ShadowRunUnorderedFields
    runExactSha256 = Get-ShadowRunSha256 -Text (
        ($expectedStages | ForEach-Object { "$_=$($stageSummary[$_].exactSha256)" }) -join "`n")
    inventoryCount = $inventory.Count
}

$reportPath = Join-Path ((Resolve-Path -LiteralPath $OutputRoot).ProviderPath) 'stage-shadow-run.json'
[IO.File]::WriteAllBytes($reportPath,
    $utf8.GetBytes((ConvertTo-Json -InputObject $report -Depth 48 -Compress:$false) + "`n"))

Write-Host ("PASS: stage shadow run published {0} artifact(s) across {1} stage(s); graph {2}." -f
    $artifacts.Count, $expectedStages.Count, $report.runGraphSha256)
