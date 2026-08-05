#Requires -Version 7.0
<#
.SYNOPSIS
    OPERATOR-ONLY evaluation harness: computes reviewer quality metrics and
    executable rollout qualification over a frozen corpus, three arm runs, and
    a blind adjudication, and seals a NON-PROMOTABLE evaluation report.

.DESCRIPTION
    This tool measures. It never delivers, never posts, never votes, never
    calls a model, and never touches the reviewer agent's state directory or
    signing key. Its output authorizes nothing: the report is sealed under an
    evaluation-only HMAC domain and carries a "kind", so both reviewer
    promotion paths reject it structurally - the raw one refuses any manifest
    carrying "kind" and cannot authenticate a derived-domain envelope with the
    raw master key, and the verified one accepts only reviewer-gate-decision.

    What it does:

      * verifies the sealed corpus against its own freeze (record hashes,
        partition assignment, ground-truth reconciliation, correction ordering,
        model-identity-as-labeler, forbidden model-output fields);
      * rejects a run set that is not the same measurement three ways -
        different corpus, binding, model identities, example set, or per-example
        pinned commits are hard rejections, not annotations;
      * reconciles blind claim verdicts deterministically, tracks disagreement,
        and requires an independent adjudicator for every discordant claim;
      * computes unique-claim precision, raw precision, issue-class recall,
        convention recall, duplicate rate, severity accuracy, vote accuracy,
        latency, token use and cost for each arm and partition;
      * evaluates the declared rollout bars with EXACT integer Clopper-Pearson
        tests (no floating-point bound is ever compared against a floor), a
        paired exact bound on recall regression, and Bonferroni adjustment over
        the prespecified qualifiable scopes;
      * emits machine-readable population/deficit state, and a transcription
        block in the layer-6 qualification shape.

    Signing a real gate qualification remains a separate, deliberate human act
    through tools/New-ReviewerGateQualification.ps1. There is deliberately no
    automation from this report to that tool.

.PARAMETER CorpusFile
    Sealed reviewer-evaluation-corpus artifact.

.PARAMETER RunFiles
    Exactly three sealed reviewer-evaluation-run artifacts: one per arm
    (generalistOnly, multiPassDiscovery, verified).

.PARAMETER AdjudicationFile
    Sealed reviewer-evaluation-adjudication artifact.

.PARAMETER StateDir
    Evaluation-only state directory holding evaluation-signing.key. Never the
    reviewer agent's state directory.

.PARAMETER OutputPath
    Where to write the sealed evaluation report.

.PARAMETER PolicyFile
    Evaluation policy. Defaults to the shipped, deliberately non-permissive
    src/Agents/reviewer/evaluation/v1/policy.json.

.PARAMETER ReportVersion
    Monotonic report version, >= 1.

.PARAMETER GeneratedAtEpochSeconds
    Report timestamp. Supply the original value to reproduce a byte-identical
    report from identical inputs, which is what makes replay verification
    meaningful.

.PARAMETER ConfigSha256
    Optional expected reviewer config hash; when supplied, a run set whose
    binding disagrees is rejected.

.PARAMETER ReviewerScriptSha256
    Optional expected Start-ReviewerAgent.ps1 hash. A run manifest RECORDS
    which reviewer build produced it; only an operator-supplied expectation can
    turn that recorded provenance into a live cross-check.

.PARAMETER GateLibrarySha256
    Optional expected DeliveryGates.ps1 hash.

.PARAMETER VerificationLibrarySha256
    Optional expected CrossVerification.ps1 hash.

.PARAMETER VerificationPolicySha256
    Optional expected cross-verification policy hash.

.PARAMETER SealOnly
    Seal a plain-JSON run or adjudication manifest into the corresponding
    evaluation domain and exit. Requires -SealKind, -SealInput and -OutputPath.

.PARAMETER SealKind
    "run" or "adjudication". Only meaningful with -SealOnly.

.PARAMETER SealInput
    Plain-JSON manifest to seal. Only meaningful with -SealOnly.

.EXAMPLE
    ./tools/Invoke-ReviewerEvaluation.ps1 `
        -CorpusFile C:\eval\corpus-v1.json `
        -RunFiles C:\eval\run-baseline.json,C:\eval\run-multipass.json,C:\eval\run-verified.json `
        -AdjudicationFile C:\eval\adjudication-v1.json `
        -StateDir C:\eval\state -OutputPath C:\eval\report-v1.json -ReportVersion 1
#>
[CmdletBinding()]
param(
    [string]$CorpusFile,
    [string[]]$RunFiles = @(),
    [string]$AdjudicationFile,
    [Parameter(Mandatory)][string]$StateDir,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$PolicyFile,
    [ValidateRange(1, [int]::MaxValue)][int]$ReportVersion = 1,
    [int64]$GeneratedAtEpochSeconds = -1,
    [ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ConfigSha256,
    [ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ReviewerScriptSha256,
    [ValidatePattern('^[0-9a-fA-F]{64}$')][string]$GateLibrarySha256,
    [ValidatePattern('^[0-9a-fA-F]{64}$')][string]$VerificationLibrarySha256,
    [ValidatePattern('^[0-9a-fA-F]{64}$')][string]$VerificationPolicySha256,
    [switch]$SealOnly,
    [ValidateSet("run", "adjudication")][string]$SealKind,
    [string]$SealInput
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "src\Agents\reviewer\CrossVerification.ps1")
. (Join-Path $repoRoot "src\Agents\reviewer\evaluation\Evaluation.ps1")

$evaluationRoot = Join-Path $repoRoot "src\Agents\reviewer\evaluation"
$libraryPath = Join-Path $evaluationRoot "Evaluation.ps1"
$corpusSchemaPath = Join-Path $evaluationRoot "v1\corpus.schema.json"
$runSchemaPath = Join-Path $evaluationRoot "v1\run.schema.json"
$adjudicationSchemaPath = Join-Path $evaluationRoot "v1\adjudication.schema.json"
$reportSchemaPath = Join-Path $evaluationRoot "v1\report.schema.json"
$policyPath = $(if ($PolicyFile) { $PolicyFile } else { Join-Path $evaluationRoot "v1\policy.json" })
$importToolPath = Join-Path $repoRoot "tools\Import-ReviewerEvalCorpus.ps1"

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
$resolvedStateDir = (Resolve-Path -LiteralPath $StateDir).Path
$masterKey = Get-ReviewerEvalSigningKey -KeyPath (Join-Path $resolvedStateDir "evaluation-signing.key")

function Save-EvaluationOutput {
    param([Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)][ValidateSet("run", "adjudication", "report")][string]$Domain)
    $outputDirectory = Split-Path -Parent $OutputPath
    if (-not $outputDirectory) { $outputDirectory = "." }
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
    $outputDirectory = (Resolve-Path -LiteralPath $outputDirectory).Path
    $baseName = [IO.Path]::GetFileNameWithoutExtension($OutputPath)
    if ($baseName -notmatch '^[A-Za-z0-9._-]+$') {
        throw "-OutputPath's file name ('$baseName') must match [A-Za-z0-9._-]+ once its extension is removed."
    }
    return Save-ReviewerEvalArtifact -Manifest $Manifest -Directory $outputDirectory -BaseName $baseName `
        -MasterKey $masterKey -Domain $Domain
}

if ($SealOnly) {
    if (-not $SealKind -or -not $SealInput) { throw "-SealOnly requires both -SealKind and -SealInput." }
    if (-not (Test-Path -LiteralPath $SealInput -PathType Leaf)) { throw "-SealInput '$SealInput' does not exist." }
    $plain = Get-Content -LiteralPath $SealInput -Raw | ConvertFrom-Json -Depth 64
    $schemaPath = $(if ($SealKind -ceq "run") { $runSchemaPath } else { $adjudicationSchemaPath })
    if (-not (Test-Json -Json ($plain | ConvertTo-Json -Depth 32) -SchemaFile $schemaPath)) {
        throw "The supplied $SealKind manifest does not satisfy $([IO.Path]::GetFileName($schemaPath))."
    }
    $sealedPath = Save-EvaluationOutput -Manifest $plain -Domain $SealKind
    Write-Host "Sealed $SealKind artifact: $sealedPath" -ForegroundColor Green
    exit 0
}

foreach ($pair in @(@("-CorpusFile", $CorpusFile), @("-AdjudicationFile", $AdjudicationFile))) {
    if ([string]::IsNullOrWhiteSpace([string]$pair[1])) { throw "$($pair[0]) is required unless -SealOnly is used." }
}
if (@($RunFiles).Count -ne 3) {
    throw "-RunFiles must list exactly three sealed run artifacts, one per arm."
}

$policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json -Depth 16
$policySchemaPath = Join-Path $evaluationRoot "v1\policy.schema.json"
if (-not (Test-Json -Json ($policy | ConvertTo-Json -Depth 16) -SchemaFile $policySchemaPath)) {
    throw "The evaluation policy at '$policyPath' does not satisfy policy.schema.json."
}
$effectivePolicy = ConvertTo-ReviewerEvalEffectivePolicy -Policy $policy

$corpus = Read-ReviewerEvalArtifact -Path $CorpusFile -MasterKey $masterKey -Domain corpus
$runs = @(@($RunFiles) | ForEach-Object { Read-ReviewerEvalArtifact -Path $_ -MasterKey $masterKey -Domain run })
$adjudication = Read-ReviewerEvalArtifact -Path $AdjudicationFile -MasterKey $masterKey -Domain adjudication

foreach ($pair in @(
        , @($corpus, $corpusSchemaPath)
        , @($adjudication, $adjudicationSchemaPath)
    )) {
    if (-not (Test-Json -Json ($pair[0] | ConvertTo-Json -Depth 32) -SchemaFile $pair[1])) {
        throw "A sealed input failed $([IO.Path]::GetFileName($pair[1]))."
    }
}
foreach ($run in $runs) {
    if (-not (Test-Json -Json ($run | ConvertTo-Json -Depth 32) -SchemaFile $runSchemaPath)) {
        throw "A sealed run artifact failed run.schema.json."
    }
}

$runSet = Test-ReviewerEvalRunSetConsistent -Runs $runs -Corpus $corpus
# The run manifests RECORD which reviewer build produced them; nothing in a
# sealed artifact can prove that on its own. These optional operator inputs are
# the only way to turn recorded provenance into a live cross-check, and they
# are deliberately operator-supplied rather than derived from this checkout,
# because scoring an older reviewer build is a legitimate thing to do.
$expectedBindings = @(
    , @("configSha256", $ConfigSha256)
    , @("reviewerScriptSha256", $ReviewerScriptSha256)
    , @("gateLibrarySha256", $GateLibrarySha256)
    , @("verificationLibrarySha256", $VerificationLibrarySha256)
    , @("verificationPolicySha256", $VerificationPolicySha256)
)
foreach ($arm in $script:ReviewerEvalArms) {
    if (-not $runSet.ByArm.ContainsKey($arm)) { continue }
    $binding = Get-ReviewerVerificationValue (Get-ReviewerVerificationValue $runSet.ByArm[$arm] "derivation") "binding"
    foreach ($pair in $expectedBindings) {
        $expected = [string]$pair[1]
        if (-not $expected) { continue }
        if ([string](Get-ReviewerVerificationValue $binding ([string]$pair[0]) "") -cne $expected.ToLowerInvariant()) {
            throw "A run's $($pair[0]) does not match the expected value; refusing to score a stale pair."
        }
    }
}

$corpusIntegrity = Test-ReviewerEvalCorpusIntegrity -Corpus $corpus `
    -ModelIdentities @($runSet.ModelIdentities) -EarliestRunSequence $runSet.EarliestExecutedAtEpochSeconds
$adjudicationResult = Test-ReviewerEvalAdjudication -Adjudication $adjudication -RunSet $runSet `
    -Corpus $corpus -AdjudicationSalt ([string]$corpusIntegrity.AdjudicationSalt)

$armMetrics = [System.Collections.Generic.List[object]]::new()
$degraded = 0; $unknown = 0; $missing = 0
foreach ($arm in $script:ReviewerEvalArms) {
    if (-not $runSet.ByArm.ContainsKey($arm)) { continue }
    foreach ($partition in @("calibration", "holdout")) {
        $metrics = Get-ReviewerEvalArmMetrics -Run $runSet.ByArm[$arm] -Corpus $corpus `
            -Verdicts $adjudicationResult.Verdicts -Partition $partition
        [void]$armMetrics.Add($metrics)
        $degraded += [int]$metrics.degradedExamples
        $unknown += [int]$metrics.unknownExamples
        $missing += [int]$metrics.missingExamples
    }
}

$baselineHoldout = @(@($armMetrics.ToArray()) | Where-Object {
        [string]$_.arm -ceq $script:ReviewerEvalBaselineArm -and [string]$_.partition -ceq "holdout"
    } | Select-Object -First 1)
$candidateHoldout = @(@($armMetrics.ToArray()) | Where-Object {
        [string]$_.arm -ceq $script:ReviewerEvalCandidateArm -and [string]$_.partition -ceq "holdout"
    } | Select-Object -First 1)
if (@($baselineHoldout).Count -eq 0 -or @($candidateHoldout).Count -eq 0) {
    throw ("The run set does not contain both a baseline and a verified arm; refusing to report a comparison. " +
        "Run-set reason codes: " + (@($runSet.ReasonCodes) -join ', ') + ".")
}
$baselineHoldout = $baselineHoldout[0]
$candidateHoldout = $candidateHoldout[0]
$comparison = Get-ReviewerEvalRecallComparison -BaselineMetrics $baselineHoldout `
    -CandidateMetrics $candidateHoldout -EffectivePolicy $effectivePolicy

$holdoutScopes = [System.Collections.Generic.List[object]]::new()
if (-not $runSet.ByArm.ContainsKey($script:ReviewerEvalCandidateArm)) {
    throw ("The run set does not contain the verified arm; refusing to score. " +
        "Run-set reason codes: " + (@($runSet.ReasonCodes) -join ', ') + ".")
}
foreach ($scope in @($effectivePolicy.qualifiableScopes)) {
    [void]$holdoutScopes.Add((Get-ReviewerEvalScopeMetrics -Run $runSet.ByArm[$script:ReviewerEvalCandidateArm] `
                -Corpus $corpus -Verdicts $adjudicationResult.Verdicts -Partition holdout `
                -Pack ([string]$scope.pack) -Severity ([string]$scope.severity) -EffectivePolicy $effectivePolicy))
}

$qualification = Test-ReviewerEvalRolloutQualification -EffectivePolicy $effectivePolicy `
    -CorpusIntegrity $corpusIntegrity -RunSetConsistency $runSet -AdjudicationResult $adjudicationResult `
    -CandidateHoldoutMetrics $candidateHoldout -Comparison $comparison `
    -HoldoutScopes @($holdoutScopes.ToArray()) -DegradedExamples $degraded `
    -UnknownExamples $unknown -MissingExamples $missing

$toolBinding = Get-ReviewerEvalToolBinding -FileHashes @{
    evaluationLibrarySha256  = Get-ReviewerEvalFileSha256 -Path $libraryPath
    harnessToolSha256        = Get-ReviewerEvalFileSha256 -Path $PSCommandPath
    importToolSha256         = Get-ReviewerEvalFileSha256 -Path $importToolPath
    evaluationPolicySha256   = Get-ReviewerEvalFileSha256 -Path $policyPath
    corpusSchemaSha256       = Get-ReviewerEvalFileSha256 -Path $corpusSchemaPath
    runSchemaSha256          = Get-ReviewerEvalFileSha256 -Path $runSchemaPath
    adjudicationSchemaSha256 = Get-ReviewerEvalFileSha256 -Path $adjudicationSchemaPath
    reportSchemaSha256       = Get-ReviewerEvalFileSha256 -Path $reportSchemaPath
}

$generatedAt = $GeneratedAtEpochSeconds
if ($generatedAt -lt 0) { $generatedAt = [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

$report = New-ReviewerEvalReport -ReportVersion $ReportVersion -GeneratedAtEpochSeconds $generatedAt `
    -ToolBinding $toolBinding -Corpus $corpus -CorpusIntegrity $corpusIntegrity `
    -RunSetConsistency $runSet -AdjudicationResult $adjudicationResult `
    -ArmMetrics @($armMetrics.ToArray()) -Comparison $comparison -Qualification $qualification `
    -HoldoutScopes @($holdoutScopes.ToArray()) -EffectivePolicy $effectivePolicy

if (-not (Test-Json -Json ($report | ConvertTo-Json -Depth 32) -SchemaFile $reportSchemaPath)) {
    throw "The assembled evaluation report failed report.schema.json; this is a bug in this tool."
}
$savedPath = Save-EvaluationOutput -Manifest $report -Domain report
$roundTrip = Read-ReviewerEvalArtifact -Path $savedPath -MasterKey $masterKey -Domain report
if ([string](Get-ReviewerVerificationValue $roundTrip "kind" "") -cne $script:ReviewerEvalReportKind) {
    throw "The sealed report did not verify after being written."
}

Write-Host "Sealed evaluation report: $savedPath" -ForegroundColor Green
Write-Host ("  corpus: $($report.corpusBinding.name) v$($report.corpusBinding.corpusVersion) " +
    "($($report.corpusPopulation.totalExamples) examples, $($report.corpusPopulation.seedExamples) seed)") -ForegroundColor Cyan
Write-Host ("  evaluationToolSha256: $($toolBinding.evaluationToolSha256)") -ForegroundColor DarkGray
Write-Host ("  boundMethod: $($report.qualification.boundMethod)") -ForegroundColor DarkGray
foreach ($requirement in @($report.qualification.requirements)) {
    $state = $(if ([bool]$requirement.ok) { "QUALIFIES" } else { "does not qualify" })
    $color = $(if ([bool]$requirement.ok) { "Yellow" } else { "Green" })
    Write-Host ("  $($requirement.id): $state" +
        $(if (@($requirement.reasonCodes).Count -gt 0) { " [" + (@($requirement.reasonCodes) -join ', ') + "]" } else { "" })) -ForegroundColor $color
}
Write-Host "This report authorizes nothing. Signing a gate qualification is a separate, deliberate human act." -ForegroundColor Cyan
exit 0
