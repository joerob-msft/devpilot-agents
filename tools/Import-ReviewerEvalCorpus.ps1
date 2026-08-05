#Requires -Version 7.0
<#
.SYNOPSIS
    OPERATOR-ONLY tool that freezes a provenance-bound, blind-labeled import
    manifest into a sealed reviewer evaluation corpus.

.DESCRIPTION
    This tool curates; it does not collect, and it does not label. It reads an
    import manifest an operator assembled from genuinely sourced pull requests,
    derives every identity and partition deterministically, verifies the whole
    result against src/Agents/reviewer/evaluation/v1/corpus.schema.json and
    against Test-ReviewerEvalCorpusIntegrity, and seals it under the evaluation
    corpus HMAC domain.

    It refuses to invent anything:

      * A record whose commit/change-set pins are all-zero placeholders cannot
        be marked "qualifying".
      * A record with fewer than two independent human labels is rejected.
      * A record whose labels disagree with no independent adjudicator stays
        "disputed" and contributes to nothing.
      * Any record marked "seed" - or any synthetic pin - requires an explicit
        -AllowSyntheticSeed, and a seed record can never satisfy a rollout
        requirement, however good its numbers look.

    Partition assignment is stratified over GROUPS (repository + changed-file
    path set), not over individual examples, so a revert, a retarget, a rebase,
    or a re-open of the same change cannot land on both sides of the split. The
    partition salt and holdout percentage are frozen INSIDE the sealed corpus,
    never read from policy, so no configuration edit can reshuffle an
    inconvenient example out of the holdout partition.

    It is never invoked by the reviewer agent: no CLI switch, no MCP tool, and
    no config option reaches it, and the agent process never loads the
    evaluation library at all.

.PARAMETER ImportManifest
    Path to the operator-assembled import manifest (plain JSON).

.PARAMETER OutputPath
    Where to write the sealed corpus artifact. Refuses to overwrite an existing
    file unless -Force is supplied: a frozen corpus that can be silently
    rewritten is not frozen.

.PARAMETER StateDir
    Evaluation-only state directory holding evaluation-signing.key. This must
    NOT be the reviewer agent's state directory; the tool refuses a key path
    named artifact-signing.key outright.

.PARAMETER DeficitPath
    Optional path for a machine-readable population/deficit summary. Written
    even when the corpus is entirely seed data, which is the point: an honest
    deficit beats a lowered gate.

.PARAMETER AllowSyntheticSeed
    Required to freeze any record whose status is "seed".

.PARAMETER Force
    Allow overwriting an existing sealed corpus at -OutputPath.

.EXAMPLE
    ./tools/Import-ReviewerEvalCorpus.ps1 `
        -ImportManifest C:\eval\import-2026Q1.json `
        -OutputPath C:\eval\corpus-v1.json `
        -StateDir C:\eval\state `
        -DeficitPath C:\eval\corpus-v1.deficit.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ImportManifest,
    [Parameter(Mandatory)][string]$OutputPath,
    [Parameter(Mandatory)][string]$StateDir,
    [string]$DeficitPath,
    [switch]$AllowSyntheticSeed,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "src\Agents\reviewer\CrossVerification.ps1")
. (Join-Path $repoRoot "src\Agents\reviewer\evaluation\Evaluation.ps1")

$corpusSchemaPath = Join-Path $repoRoot "src\Agents\reviewer\evaluation\v1\corpus.schema.json"

if (-not (Test-Path -LiteralPath $ImportManifest -PathType Leaf)) {
    throw "-ImportManifest '$ImportManifest' does not exist."
}
if ((Test-Path -LiteralPath $OutputPath) -and -not $Force) {
    throw "-OutputPath '$OutputPath' already exists. A frozen corpus is not silently rewritten; pass -Force deliberately."
}

$manifest = Get-Content -LiteralPath $ImportManifest -Raw | ConvertFrom-Json -Depth 64
foreach ($required in @(
        "name", "corpusVersion", "corpusPin", "holdoutPercent", "partitionSalt",
        "adjudicationSalt", "frozenAtEpochSeconds", "records"
    )) {
    if ($null -eq $manifest.PSObject.Properties[$required]) {
        throw "The import manifest is missing '$required'."
    }
}

$importToolSha256 = Get-ReviewerEvalFileSha256 -Path $PSCommandPath
$records = @($manifest.records)
if ($records.Count -eq 0) { throw "The import manifest contains no records." }

$examples = [System.Collections.Generic.List[object]]::new()
foreach ($record in $records) {
    $status = [string]$record.status
    if ($script:ReviewerEvalExampleStatuses -cnotcontains $status) {
        throw "A record declares an unrecognized status '$status'."
    }
    if ($status -ceq "seed" -and -not $AllowSyntheticSeed) {
        throw ("This import contains seed records. Seed records are synthetic fixtures that can never satisfy a " +
            "rollout requirement; pass -AllowSyntheticSeed to acknowledge that this corpus qualifies nothing.")
    }
    $stratum = [string]$record.stratum
    if ($script:ReviewerEvalStrata -cnotcontains $stratum) {
        throw "A record declares an unrecognized stratum '$stratum'."
    }

    $source = $record.provenance
    $provenance = [ordered]@{
        provider               = [string]$source.provider
        repositoryId           = [string]$source.repositoryId
        prId                   = [string]$source.prId
        sourceCommitSha        = ([string]$source.sourceCommitSha).ToLowerInvariant()
        targetCommitSha        = ([string]$source.targetCommitSha).ToLowerInvariant()
        changeSetSha256        = ([string]$source.changeSetSha256).ToLowerInvariant()
        changedFilePathsSha256 = ([string]$source.changedFilePathsSha256).ToLowerInvariant()
        sourceRef              = [string]$source.sourceRef
        importedAtEpochSeconds = [int64]$source.importedAtEpochSeconds
        importToolSha256       = $importToolSha256
    }
    $isPlaceholder = (
        $provenance.sourceCommitSha -ceq ("0" * 40) -or
        $provenance.targetCommitSha -ceq ("0" * 40) -or
        $provenance.changeSetSha256 -ceq ("0" * 64)
    )
    if ($isPlaceholder -and $status -ceq "qualifying") {
        throw ("A record marked 'qualifying' carries a placeholder commit or change-set pin. This tool will not " +
            "claim an example it cannot bind to a real, pinned change.")
    }
    if ($isPlaceholder -and -not $AllowSyntheticSeed) {
        throw "A record carries a placeholder pin; pass -AllowSyntheticSeed to import it as an explicitly non-qualifying seed."
    }

    $labels = @($record.labels)
    if ($labels.Count -lt 2) {
        throw "A record has fewer than two independent labels. Ground truth here requires at least two blind human labelers."
    }
    $normalizedLabels = [System.Collections.Generic.List[object]]::new()
    foreach ($label in $labels) {
        [void]$normalizedLabels.Add([pscustomobject][ordered]@{
                labelerId             = [string]$label.labelerId
                labelerKind           = [string]$label.labelerKind
                blind                 = [bool]$label.blind
                labeledAtEpochSeconds = [int64]$label.labeledAtEpochSeconds
                issueIds              = @(Get-ReviewerEvalOrdinalSorted -Values @(@($label.issueIds) | ForEach-Object { [string]$_ }))
                decision              = [string]$label.decision
            })
    }
    $adjudication = $null
    if ($null -ne $record.PSObject.Properties["adjudication"] -and $null -ne $record.adjudication) {
        $adjudication = [pscustomobject][ordered]@{
            adjudicatorId             = [string]$record.adjudication.adjudicatorId
            adjudicatorKind           = [string]$record.adjudication.adjudicatorKind
            adjudicatedAtEpochSeconds = [int64]$record.adjudication.adjudicatedAtEpochSeconds
            issueIds                  = @(Get-ReviewerEvalOrdinalSorted -Values @(@($record.adjudication.issueIds) | ForEach-Object { [string]$_ }))
            decision                  = [string]$record.adjudication.decision
        }
    }

    $inventory = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($record.inventory)) {
        [void]$inventory.Add([pscustomobject][ordered]@{
                issueId     = [string]$item.issueId
                issueClass  = [string]$item.issueClass
                severity    = [string]$item.severity
                convention  = [bool]$item.convention
                correctness = [bool]$item.correctness
                path        = [string]$item.path
            })
    }

    $groundTruth = Get-ReviewerEvalGroundTruth -Labels @($normalizedLabels.ToArray()) -Adjudication $adjudication
    $provenanceObject = [pscustomobject]$provenance
    [void]$examples.Add([pscustomobject][ordered]@{
            exampleId     = Get-ReviewerEvalExampleId -Provenance $provenanceObject
            status        = $status
            stratum       = $stratum
            partition     = "calibration"
            groupKey      = Get-ReviewerEvalGroupKey -Provenance $provenanceObject
            provenance    = $provenanceObject
            inventory     = @($inventory.ToArray())
            labels        = @($normalizedLabels.ToArray())
            adjudication  = $adjudication
            groundTruth   = [pscustomobject][ordered]@{
                resolution = [string]$groundTruth.resolution
                issueIds   = @($groundTruth.issueIds)
                decision   = [string]$groundTruth.decision
            }
            recordHash    = ("0" * 64)
        })
}

$partitionPolicy = [pscustomobject][ordered]@{
    method           = $script:ReviewerEvalPartitionMethod
    holdoutPercent   = [int]$manifest.holdoutPercent
    partitionSalt    = [string]$manifest.partitionSalt
    adjudicationSalt = [string]$manifest.adjudicationSalt
}

$assignment = Get-ReviewerEvalPartitionAssignment -Examples @($examples.ToArray()) `
    -PartitionSalt ([string]$partitionPolicy.partitionSalt) -HoldoutPercent ([int]$partitionPolicy.holdoutPercent)
foreach ($example in $examples) {
    $example.partition = [string]$assignment.Assignment[[string]$example.exampleId]
}
# The record hash covers everything except itself, so it has to be computed
# only after the partition is final - otherwise the freeze would certify a
# partition that was never actually stored.
$recordHashes = [System.Collections.Generic.List[string]]::new()
foreach ($example in $examples) {
    $example.recordHash = Get-ReviewerEvalRecordHash -Example $example
    [void]$recordHashes.Add([string]$example.recordHash)
}

$corpus = [pscustomobject][ordered]@{
    kind                 = $script:ReviewerEvalCorpusKind
    artifactVersion      = $script:ReviewerEvalArtifactVersion
    schemaVersion        = $script:ReviewerEvalSchemaVersion
    corpusVersion        = [int]$manifest.corpusVersion
    name                 = [string]$manifest.name
    corpusPin            = [pscustomobject][ordered]@{
        repositoryId = [string]$manifest.corpusPin.repositoryId
        commitSha    = ([string]$manifest.corpusPin.commitSha).ToLowerInvariant()
    }
    frozenAtEpochSeconds = [int64]$manifest.frozenAtEpochSeconds
    partitionPolicy      = $partitionPolicy
    strata               = @($script:ReviewerEvalStrata)
    examples             = @($examples.ToArray())
    corrections          = @()
    freeze               = [pscustomobject][ordered]@{
        partitionAssignmentSha256 = [string]$assignment.AssignmentSha256
        corpusSha256              = ""
        exampleCount              = $examples.Count
    }
}
$corpus.freeze.corpusSha256 = Get-ReviewerEvalCorpusSha256 -Name ([string]$corpus.name) `
    -CorpusVersion ([int]$corpus.corpusVersion) -CorpusPin $corpus.corpusPin `
    -FrozenAtEpochSeconds ([int64]$corpus.frozenAtEpochSeconds) `
    -PartitionPolicy $partitionPolicy -Strata @($corpus.strata) -Corrections @($corpus.corrections) `
    -RecordHashes $recordHashes.ToArray()

$corpusJson = $corpus | ConvertTo-Json -Depth 32
if (-not (Test-Json -Json $corpusJson -SchemaFile $corpusSchemaPath)) {
    throw "The assembled corpus failed its own versioned JSON schema; this is a bug in this tool, not an operator input error."
}
$integrity = Test-ReviewerEvalCorpusIntegrity -Corpus ($corpusJson | ConvertFrom-Json -Depth 64)
if (-not $integrity.Ok) {
    throw "The assembled corpus failed its own integrity check: $($integrity.ReasonCodes -join ', ')."
}

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
$resolvedStateDir = (Resolve-Path -LiteralPath $StateDir).Path
$masterKey = Get-ReviewerEvalSigningKey -KeyPath (Join-Path $resolvedStateDir "evaluation-signing.key")

$outputDirectory = Split-Path -Parent $OutputPath
if (-not $outputDirectory) { $outputDirectory = "." }
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
$outputDirectory = (Resolve-Path -LiteralPath $outputDirectory).Path
$baseName = [IO.Path]::GetFileNameWithoutExtension($OutputPath)
if ($baseName -notmatch '^[A-Za-z0-9._-]+$') {
    throw "-OutputPath's file name ('$baseName') must match [A-Za-z0-9._-]+ once its extension is removed."
}
$savedPath = Save-ReviewerEvalArtifact -Manifest $corpus -Directory $outputDirectory -BaseName $baseName `
    -MasterKey $masterKey -Domain corpus
$roundTrip = Read-ReviewerEvalArtifact -Path $savedPath -MasterKey $masterKey -Domain corpus
$roundTripIntegrity = Test-ReviewerEvalCorpusIntegrity -Corpus $roundTrip
if (-not $roundTripIntegrity.Ok) {
    throw "The sealed corpus did not verify after being written: $($roundTripIntegrity.ReasonCodes -join ', ')."
}

$population = $roundTripIntegrity.Population
$deficits = [System.Collections.Generic.List[string]]::new()
if ([int]$population.totalExamples -lt $script:ReviewerEvalMinExamples) { [void]$deficits.Add("belowMinimumExamples") }
if ([int]$population.calibrationExamples -lt $script:ReviewerEvalMinCalibrationExamples) { [void]$deficits.Add("belowMinimumCalibrationExamples") }
if ([int]$population.holdoutExamples -lt $script:ReviewerEvalMinHoldoutExamples) { [void]$deficits.Add("belowMinimumHoldoutExamples") }
if ([int]$population.seedExamples -gt 0) { [void]$deficits.Add("seedRecordsPresent") }
if ([int]$population.qualifyingExamples -lt 1) { [void]$deficits.Add("zeroQualifyingExamples") }
foreach ($entry in @($population.byStratum)) {
    if ([int]$entry.total -lt $script:ReviewerEvalMinPerStratumExamples) { [void]$deficits.Add("stratumUnpopulated") }
}

$deficitReport = [pscustomobject][ordered]@{
    corpusName         = [string]$corpus.name
    corpusVersion      = [int]$corpus.corpusVersion
    corpusSha256       = [string]$corpus.freeze.corpusSha256
    population         = $population
    required           = [pscustomobject][ordered]@{
        minExamples            = $script:ReviewerEvalMinExamples
        minCalibrationExamples = $script:ReviewerEvalMinCalibrationExamples
        minHoldoutExamples     = $script:ReviewerEvalMinHoldoutExamples
        minPerStratumExamples  = $script:ReviewerEvalMinPerStratumExamples
    }
    deficits           = @(Get-ReviewerEvalUniqueReasonCodes -Reasons @(Get-ReviewerEvalOrdinalSorted -Values $deficits.ToArray()))
    qualifiesAnything  = $false
}
if ($DeficitPath) {
    $deficitDirectory = Split-Path -Parent $DeficitPath
    if ($deficitDirectory) { New-Item -ItemType Directory -Force -Path $deficitDirectory | Out-Null }
    Set-Content -LiteralPath $DeficitPath -Value ($deficitReport | ConvertTo-Json -Depth 16) -Encoding utf8NoBOM
}

Write-Host "Sealed evaluation corpus: $savedPath" -ForegroundColor Green
Write-Host ("  examples: $($population.totalExamples) (qualifying $($population.qualifyingExamples), seed $($population.seedExamples))") -ForegroundColor Cyan
Write-Host ("  partitions: calibration $($population.calibrationExamples), holdout $($population.holdoutExamples)") -ForegroundColor Cyan
Write-Host ("  corpusSha256: $($corpus.freeze.corpusSha256)") -ForegroundColor DarkGray
if ($deficitReport.deficits.Count -gt 0) {
    Write-Warning ("This corpus qualifies nothing. Deficits: " + ($deficitReport.deficits -join ', '))
}
exit 0
