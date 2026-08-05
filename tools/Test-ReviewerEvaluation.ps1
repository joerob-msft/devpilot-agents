#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Offline safety tests for the layer-7 evaluation harness
    (src/Agents/reviewer/evaluation/Evaluation.ps1 plus its two tools).

.DESCRIPTION
    No network, no ADO/GitHub, no Copilot process, no model, and no reviewer
    state directory. Everything here is a pure function of sealed inputs, so
    the library is exercised directly: canonicalization and tamper detection,
    HMAC domain separation, corpus freeze and partition-leakage checks,
    duplicate examples, stale/mismatched run pairs, blind adjudication
    reconciliation and conflicts, metric denominators, exact confidence-bound
    boundaries and zero-event cases, sample-size and threshold boundaries, the
    false-critical and false-approval vetoes, paired recall regression,
    unknown/degraded inputs, and non-promotability.

    The single most important assertion in this file is
    "a seed corpus qualifies nothing": a synthetic corpus with perfect
    precision at an absurd sample size must still fail every rollout
    requirement, because a layer that can grade its own homework is worth
    nothing regardless of how carefully the rest of it is built.

.EXAMPLE
    ./tools/Test-ReviewerEvaluation.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "src\Agents\reviewer\CrossVerification.ps1")
. (Join-Path $repoRoot "src\Agents\reviewer\DeliveryGates.ps1")
. (Join-Path $repoRoot "src\Agents\reviewer\evaluation\Evaluation.ps1")

$evaluationRoot = Join-Path $repoRoot "src\Agents\reviewer\evaluation"
$libraryPath = Join-Path $evaluationRoot "Evaluation.ps1"
$policyPath = Join-Path $evaluationRoot "v1\policy.json"
$policySchemaPath = Join-Path $evaluationRoot "v1\policy.schema.json"
$corpusSchemaPath = Join-Path $evaluationRoot "v1\corpus.schema.json"
$runSchemaPath = Join-Path $evaluationRoot "v1\run.schema.json"
$adjudicationSchemaPath = Join-Path $evaluationRoot "v1\adjudication.schema.json"
$reportSchemaPath = Join-Path $evaluationRoot "v1\report.schema.json"
$importToolPath = Join-Path $repoRoot "tools\Import-ReviewerEvalCorpus.ps1"
$harnessToolPath = Join-Path $repoRoot "tools\Invoke-ReviewerEvaluation.ps1"
$wrapperPath = Join-Path $repoRoot "src\Agents\reviewer\Start-ReviewerAgent.ps1"
$importFixturePath = Join-Path $repoRoot "src\Agents\reviewer\testdata\evaluation-import-v1.seed.json"
$armsFixturePath = Join-Path $repoRoot "src\Agents\reviewer\testdata\evaluation-arms-v1.seed.json"

$failures = [System.Collections.Generic.List[string]]::new()
$checks = 0

function Assert-Eval {
    param([bool]$Condition, [Parameter(Mandatory)][string]$Message)
    $script:checks++
    if (-not $Condition) { [void]$script:failures.Add($Message) }
}

function Assert-EvalThrows {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Message,
        [string]$ExpectedMessageLike
    )
    $script:checks++
    $thrown = $null
    try { & $Action | Out-Null } catch { $thrown = $_ }
    if ($null -eq $thrown) { [void]$script:failures.Add($Message); return }
    # A bare catch-anything assertion passes when a typo or a StrictMode
    # violation throws, which would silently retire the guarantee it claims to
    # protect. Callers that care pin a substring of the expected message.
    if ($ExpectedMessageLike -and [string]$thrown.Exception.Message -notlike "*$ExpectedMessageLike*") {
        [void]$script:failures.Add("$Message (threw, but not for the expected reason: $($thrown.Exception.Message))")
    }
}

function Copy-EvalObject {
    param([Parameter(Mandatory)]$Value)
    return ($Value | ConvertTo-Json -Depth 64 | ConvertFrom-Json -Depth 64)
}

function New-EvalTestKey {
    $key = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Fill($key)
    return , $key
}

$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("devpilot-eval-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
$stateDir = Join-Path $sandbox "state"
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

try {
    # -----------------------------------------------------------------------
    # 1. Shipped assets parse, validate, and are deliberately non-permissive.
    # -----------------------------------------------------------------------
    $policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json -Depth 16
    foreach ($schemaPath in @($policySchemaPath, $corpusSchemaPath, $runSchemaPath, $adjudicationSchemaPath, $reportSchemaPath)) {
        $null = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json -Depth 64
    }
    Assert-Eval ([bool](Test-Json -Json ($policy | ConvertTo-Json -Depth 16) -SchemaFile $policySchemaPath)) `
        "The shipped evaluation policy does not satisfy its own schema."
    $effectivePolicy = ConvertTo-ReviewerEvalEffectivePolicy -Policy $policy
    Assert-Eval (-not [bool]$effectivePolicy.suggestionQualificationEnabled) `
        "The shipped policy enables suggestion qualification; suggestions must ship preview-only."
    Assert-Eval ([int]$effectivePolicy.minEligibleHoldoutFindings -ge 200) `
        "The shipped policy weakens the 200 eligible-holdout-finding floor."
    Assert-Eval ([double]$effectivePolicy.minCommentPrecision -ge 0.98) `
        "The shipped policy weakens the 98% precision floor."
    Assert-Eval ([double]$effectivePolicy.minCommentPrecisionLowerBound95 -ge 0.95) `
        "The shipped policy weakens the 95% lower-bound floor."
    Assert-Eval ([int]$effectivePolicy.minApprovalDecisions -ge 300) `
        "The shipped policy weakens the 300 labeled-decision floor."
    Assert-Eval ([double]$effectivePolicy.maxRecallRegression -le 0.02) `
        "The shipped policy widens the 2 percentage-point recall-regression ceiling."

    # Policy may only narrow a cap and only raise a floor.
    $permissive = Copy-EvalObject -Value $policy
    $permissive.minEligibleHoldoutFindings = 1
    $permissive.minCommentPrecision = 0.1
    $permissive.minCommentPrecisionLowerBound95 = 0.1
    $permissive.minApprovalDecisions = 1
    $permissive.maxRecallRegression = 0.9
    $permissive.maxCriticalFalsePositiveRate = 0.9
    $clamped = ConvertTo-ReviewerEvalEffectivePolicy -Policy $permissive
    Assert-Eval ([int]$clamped.minEligibleHoldoutFindings -eq 200) "A permissive policy lowered the eligible-finding floor."
    Assert-Eval ([double]$clamped.minCommentPrecision -eq 0.98) "A permissive policy lowered the precision floor."
    Assert-Eval ([double]$clamped.minCommentPrecisionLowerBound95 -eq 0.95) "A permissive policy lowered the lower-bound floor."
    Assert-Eval ([int]$clamped.minApprovalDecisions -eq 300) "A permissive policy lowered the approval-decision floor."
    Assert-Eval ([double]$clamped.maxRecallRegression -eq 0.02) "A permissive policy widened the recall-regression ceiling."
    Assert-Eval ([double]$clamped.maxCriticalFalsePositiveRate -eq 0.01) "A permissive policy widened the critical false-positive ceiling."
    $stricter = Copy-EvalObject -Value $policy
    $stricter.minEligibleHoldoutFindings = 500
    $stricter.maxRecallRegression = 0.005
    $tightened = ConvertTo-ReviewerEvalEffectivePolicy -Policy $stricter
    Assert-Eval ([int]$tightened.minEligibleHoldoutFindings -eq 500) "A stricter policy failed to raise the eligible-finding floor."
    Assert-Eval ([double]$tightened.maxRecallRegression -eq 0.005) "A stricter policy failed to narrow the regression ceiling."

    # The freeze-owned values must not be settable from policy at all.
    foreach ($frozenKey in @("partitionSalt", "adjudicationSalt", "holdoutPercent")) {
        $smuggled = Copy-EvalObject -Value $policy
        $smuggled | Add-Member -NotePropertyName $frozenKey -NotePropertyValue "x" -Force
        Assert-EvalThrows { ConvertTo-ReviewerEvalEffectivePolicy -Policy $smuggled } `
            -Message "Evaluation policy accepted '$frozenKey', which belongs only to the sealed corpus freeze." `
            -ExpectedMessageLike "unexpected or missing top-level keys"
    }
    # An empty scope list would delete the per-scope evidence requirement AND
    # drop the Bonferroni penalty to k=1, both in the permissive direction.
    $noScopes = Copy-EvalObject -Value $policy
    $noScopes.qualifiableScopes = @()
    $noScopesValid = $false
    try {
        $noScopesValid = [bool](Test-Json -Json ($noScopes | ConvertTo-Json -Depth 16) `
                -SchemaFile $policySchemaPath -ErrorAction SilentlyContinue)
    }
    catch { $noScopesValid = $false }
    Assert-Eval (-not $noScopesValid) "policy.schema.json accepts an empty qualifiableScopes list."
    Assert-Eval ([string]$effectivePolicy.boundMethod -clike "clopper-pearson-1sided-95-bonferroni-k*") `
        "The bound method string does not record the interval family and multiplicity correction."
    Assert-Eval ([int]$effectivePolicy.alphaDenominator -eq (20 * [int]$effectivePolicy.scopeCount)) `
        "Bonferroni adjustment is not applied to the qualification alpha."

    # -----------------------------------------------------------------------
    # 2. Exact interval arithmetic: boundaries, zero events, and conservatism.
    # -----------------------------------------------------------------------
    # x = n has the closed form L = alpha^(1/n); grid search must land at or
    # just below it, never above.
    $lowerAtAll = Get-ReviewerEvalLowerBoundGrid -Successes 100 -Trials 100
    Assert-Eval ($lowerAtAll -le [Math]::Pow(0.05, 1.0 / 100) -and $lowerAtAll -gt 0.97) `
        "The exact lower bound for 100/100 is not conservative against its closed form."
    # x = 0 is the rule-of-three case; the upper bound is 1 - alpha^(1/n).
    $upperAtZero = Get-ReviewerEvalUpperBoundGrid -Successes 0 -Trials 300
    Assert-Eval ($upperAtZero -ge (1.0 - [Math]::Pow(0.05, 1.0 / 300)) -and $upperAtZero -lt 0.011) `
        "The exact upper bound for 0/300 is not conservative against its closed form."
    Assert-Eval ((Get-ReviewerEvalLowerBoundGrid -Successes 0 -Trials 50) -eq 0.0) `
        "A zero-success lower bound is not 0."
    Assert-Eval ((Get-ReviewerEvalUpperBoundGrid -Successes 50 -Trials 50) -eq 1.0) `
        "An all-success upper bound is not 1."
    Assert-Eval ($null -eq (Get-ReviewerEvalLowerBoundGrid -Successes 0 -Trials 0)) `
        "A zero denominator produced a bound instead of null."
    Assert-Eval ($null -eq (Get-ReviewerEvalLowerBoundGrid -Successes 10 -Trials 10 -MaxExactTrials 5)) `
        "A sample above the exact ceiling produced a bound instead of refusing."

    # Threshold boundary: 196/200 clears a 0.95 lower bound; 195/200 does not.
    Assert-Eval (Test-ReviewerEvalLowerBoundAtLeast -Successes 196 -Trials 200 -ThresholdNumerator 9500 -ThresholdDenominator 10000) `
        "196/200 failed the exact 0.95 lower-bound test."
    Assert-Eval (-not (Test-ReviewerEvalLowerBoundAtLeast -Successes 195 -Trials 200 -ThresholdNumerator 9500 -ThresholdDenominator 10000)) `
        "195/200 passed the exact 0.95 lower-bound test."
    Assert-Eval (-not (Test-ReviewerEvalLowerBoundAtLeast -Successes 0 -Trials 0 -ThresholdNumerator 1 -ThresholdDenominator 2)) `
        "A zero denominator satisfied a lower-bound test instead of failing closed."
    Assert-Eval (-not (Test-ReviewerEvalUpperBoundAtMost -Successes 0 -Trials 0 -ThresholdNumerator 1 -ThresholdDenominator 2)) `
        "A zero denominator satisfied an upper-bound test instead of failing closed."
    # Zero events with a small denominator must NOT clear a 1% ceiling; the
    # same zero events with a large denominator must.
    Assert-Eval (-not (Test-ReviewerEvalUpperBoundAtMost -Successes 0 -Trials 30 -ThresholdNumerator 100 -ThresholdDenominator 10000)) `
        "Zero events out of 30 cleared a 1% upper-bound ceiling; 'zero' without a denominator is not evidence."
    Assert-Eval (Test-ReviewerEvalUpperBoundAtMost -Successes 0 -Trials 400 -ThresholdNumerator 100 -ThresholdDenominator 10000) `
        "Zero events out of 400 failed a 1% upper-bound ceiling."
    # A tighter alpha must never make a bound easier to satisfy.
    Assert-Eval ((Get-ReviewerEvalLowerBoundGrid -Successes 196 -Trials 200 -AlphaDenominator 100) -le
        (Get-ReviewerEvalLowerBoundGrid -Successes 196 -Trials 200 -AlphaDenominator 20)) `
        "A Bonferroni-tightened alpha produced a HIGHER lower bound."
    # Determinism: identical inputs, identical output, twice.
    Assert-Eval ((Get-ReviewerEvalLowerBoundGrid -Successes 137 -Trials 150) -eq
        (Get-ReviewerEvalLowerBoundGrid -Successes 137 -Trials 150)) `
        "The exact bound search is not deterministic."
    # Grid conversion rounds thresholds in the strict direction only.
    Assert-Eval ((ConvertTo-ReviewerEvalGridNumerator -Value 0.98 -Role floor) -eq 9800) "A floor threshold did not round up onto the grid."
    Assert-Eval ((ConvertTo-ReviewerEvalGridNumerator -Value 0.01 -Role ceiling) -eq 100) "A ceiling threshold did not round down onto the grid."

    # Paired recall regression.
    Assert-Eval (Test-ReviewerEvalPairedRegressionWithinCeiling -InventoryCount 500 -BaselineOnly 0 -CandidateOnly 0 -MaxRegressionNumerator 200) `
        "Zero discordant pairs failed the recall-regression ceiling."
    Assert-Eval (-not (Test-ReviewerEvalPairedRegressionWithinCeiling -InventoryCount 0 -BaselineOnly 0 -CandidateOnly 0 -MaxRegressionNumerator 200)) `
        "An empty inventory satisfied the recall-regression ceiling instead of failing closed."
    Assert-Eval (-not (Test-ReviewerEvalPairedRegressionWithinCeiling -InventoryCount 100 -BaselineOnly 40 -CandidateOnly 0 -MaxRegressionNumerator 200)) `
        "A 40-point recall regression cleared a 2 percentage-point ceiling."
    Assert-Eval (Test-ReviewerEvalPairedRegressionWithinCeiling -InventoryCount 1000 -BaselineOnly 0 -CandidateOnly 40 -MaxRegressionNumerator 200) `
        "A recall IMPROVEMENT failed the regression ceiling."

    # -----------------------------------------------------------------------
    # 3. Fleiss' kappa and adjudication coverage arithmetic.
    # -----------------------------------------------------------------------
    Assert-Eval ($null -eq (Get-ReviewerEvalFleissKappa -RatingVectors @(, @("truePositive", "truePositive")))) `
        "Kappa was defined from a single item."
    $perfect = Get-ReviewerEvalFleissKappa -RatingVectors @(
        @("truePositive", "truePositive"), @("falsePositive", "falsePositive"),
        @("truePositive", "truePositive"), @("falsePositive", "falsePositive"))
    Assert-Eval ($null -ne $perfect -and $perfect -gt 0.99) "Perfect agreement did not produce a kappa near 1."
    $degenerate = Get-ReviewerEvalFleissKappa -RatingVectors @(
        @("truePositive", "truePositive"), @("truePositive", "truePositive"))
    Assert-Eval ($null -eq $degenerate) "A degenerate single-category distribution produced a kappa instead of null."
    Assert-Eval ($null -eq (Get-ReviewerEvalRatio -Numerator 3 -Denominator 0)) "A zero denominator produced a ratio instead of null."

    # -----------------------------------------------------------------------
    # 4. Import the shipped seed corpus through the real operator tool.
    # -----------------------------------------------------------------------
    $corpusPath = Join-Path $sandbox "corpus.json"
    $deficitPath = Join-Path $sandbox "corpus.deficit.json"
    & $importToolPath -ImportManifest $importFixturePath -OutputPath $corpusPath `
        -StateDir $stateDir -DeficitPath $deficitPath -AllowSyntheticSeed | Out-Null
    Assert-Eval (Test-Path -LiteralPath $corpusPath) "The import tool did not produce a sealed corpus."
    $masterKey = Get-ReviewerEvalSigningKey -KeyPath (Join-Path $stateDir "evaluation-signing.key")
    $corpus = Read-ReviewerEvalArtifact -Path $corpusPath -MasterKey $masterKey -Domain corpus
    Assert-Eval ([bool](Test-Json -Json ($corpus | ConvertTo-Json -Depth 32) -SchemaFile $corpusSchemaPath)) `
        "The imported corpus does not satisfy corpus.schema.json."
    $integrity = Test-ReviewerEvalCorpusIntegrity -Corpus $corpus
    Assert-Eval ([bool]$integrity.Ok) "The imported seed corpus failed its own integrity check: $($integrity.ReasonCodes -join ', ')."
    Assert-Eval ([int]$integrity.Population.seedExamples -eq [int]$integrity.Population.totalExamples) `
        "The shipped fixture is not entirely seed data."
    Assert-Eval ([int]$integrity.Population.holdoutExamples -gt 0 -and [int]$integrity.Population.calibrationExamples -gt 0) `
        "Stratified partitioning left one side of the split empty."
    $deficit = Get-Content -LiteralPath $deficitPath -Raw | ConvertFrom-Json -Depth 16
    Assert-Eval (@($deficit.deficits) -contains "seedRecordsPresent" -and @($deficit.deficits) -contains "zeroQualifyingExamples") `
        "The deficit report does not state the corpus population truth."
    Assert-Eval (-not [bool]$deficit.qualifiesAnything) "The deficit report claims a seed corpus qualifies something."

    # The import tool must refuse seed data without an explicit acknowledgement.
    Assert-EvalThrows -Action {
        & $importToolPath -ImportManifest $importFixturePath -OutputPath (Join-Path $sandbox "refused.json") `
            -StateDir $stateDir
    } -Message "The import tool accepted seed records without -AllowSyntheticSeed." `
        -ExpectedMessageLike "AllowSyntheticSeed"
    # And it must refuse to silently rewrite a frozen corpus.
    Assert-EvalThrows -Action {
        & $importToolPath -ImportManifest $importFixturePath -OutputPath $corpusPath `
            -StateDir $stateDir -AllowSyntheticSeed
    } -Message "The import tool overwrote an existing frozen corpus without -Force." `
        -ExpectedMessageLike "already exists"
    # A qualifying record with a placeholder pin is a fabricated example.
    $fabricated = Copy-EvalObject -Value (Get-Content -LiteralPath $importFixturePath -Raw | ConvertFrom-Json -Depth 64)
    $fabricated.records[0].status = "qualifying"
    $fabricated.records[0].provenance.sourceCommitSha = "0" * 40
    $fabricatedPath = Join-Path $sandbox "fabricated-import.json"
    Set-Content -LiteralPath $fabricatedPath -Value ($fabricated | ConvertTo-Json -Depth 64) -Encoding utf8NoBOM
    Assert-EvalThrows -Action {
        & $importToolPath -ImportManifest $fabricatedPath -OutputPath (Join-Path $sandbox "fabricated.json") `
            -StateDir $stateDir -AllowSyntheticSeed
    } -Message "The import tool accepted a 'qualifying' record with a placeholder commit pin." `
        -ExpectedMessageLike "placeholder commit or change-set pin"
    # A single labeler is not ground truth.
    $singleLabel = Copy-EvalObject -Value (Get-Content -LiteralPath $importFixturePath -Raw | ConvertFrom-Json -Depth 64)
    $singleLabel.records[0].labels = @($singleLabel.records[0].labels[0])
    $singleLabelPath = Join-Path $sandbox "single-label-import.json"
    Set-Content -LiteralPath $singleLabelPath -Value ($singleLabel | ConvertTo-Json -Depth 64) -Encoding utf8NoBOM
    Assert-EvalThrows -Action {
        & $importToolPath -ImportManifest $singleLabelPath -OutputPath (Join-Path $sandbox "single.json") `
            -StateDir $stateDir -AllowSyntheticSeed
    } -Message "The import tool accepted a record with a single labeler." `
        -ExpectedMessageLike "fewer than two independent labels"

    # -----------------------------------------------------------------------
    # 5. Build the three arm runs and the blind adjudication from the fixture.
    # -----------------------------------------------------------------------
    $arms = Get-Content -LiteralPath $armsFixturePath -Raw | ConvertFrom-Json -Depth 64
    $corpusSha = [string]$corpus.freeze.corpusSha256
    $exampleByPr = @{}
    foreach ($example in @($corpus.examples)) { $exampleByPr[[string]$example.provenance.prId] = $example }

    $binding = [pscustomobject][ordered]@{
        evaluationLibrarySha256  = Get-ReviewerEvalFileSha256 -Path $libraryPath
        harnessToolSha256        = Get-ReviewerEvalFileSha256 -Path $harnessToolPath
        importToolSha256         = Get-ReviewerEvalFileSha256 -Path $importToolPath
        evaluationPolicySha256   = Get-ReviewerEvalFileSha256 -Path $policyPath
        corpusSchemaSha256       = Get-ReviewerEvalFileSha256 -Path $corpusSchemaPath
        runSchemaSha256          = Get-ReviewerEvalFileSha256 -Path $runSchemaPath
        adjudicationSchemaSha256 = Get-ReviewerEvalFileSha256 -Path $adjudicationSchemaPath
        reportSchemaSha256       = Get-ReviewerEvalFileSha256 -Path $reportSchemaPath
        reviewerScriptSha256     = Get-ReviewerEvalFileSha256 -Path $wrapperPath
        gateLibrarySha256        = Get-ReviewerEvalFileSha256 -Path (Join-Path $repoRoot "src\Agents\reviewer\DeliveryGates.ps1")
        verificationLibrarySha256 = Get-ReviewerEvalFileSha256 -Path (Join-Path $repoRoot "src\Agents\reviewer\CrossVerification.ps1")
        verificationPromptSha256 = Get-ReviewerEvalFileSha256 -Path (Join-Path $repoRoot "src\Agents\reviewer\cross-verify.prompt.md")
        verificationPolicySha256 = Get-ReviewerEvalFileSha256 -Path (Join-Path $repoRoot "src\Agents\reviewer\verification\v1\policy.json")
        verificationSchemaSha256 = Get-ReviewerEvalFileSha256 -Path (Join-Path $repoRoot "src\Agents\reviewer\verification\v1\schema.json")
        configSha256             = "0" * 64
    }
    $script:claimRefByKey = @{}

    function New-SeedRun {
        param([Parameter(Mandatory)]$ArmSpec)
        $arm = [string]$ArmSpec.arm
        $results = [System.Collections.Generic.List[object]]::new()
        foreach ($result in @($ArmSpec.results)) {
            $prId = [string]$result.prId
            $example = $exampleByPr[$prId]
            $claims = [System.Collections.Generic.List[object]]::new()
            $index = 0
            foreach ($claimRef in @($result.claimRefs)) {
                $spec = $arms.claims.$claimRef
                $contentSha = Get-ReviewerEvalClaimContentSha256 -Text ([string]$spec.text)
                $key = Get-ReviewerEvalBlindClaimKey -CorpusSha256 $corpusSha `
                    -ExampleId ([string]$example.exampleId) -Path ([string]$spec.path) `
                    -Severity ([string]$spec.severity) -ClaimContentSha256 $contentSha
                $script:claimRefByKey[$key] = $claimRef
                [void]$claims.Add([pscustomobject][ordered]@{
                        claimId            = "$arm-$prId-$index"
                        blindClaimKey      = $key
                        claimContentSha256 = $contentSha
                        issueClass         = [string]$spec.issueClass
                        severity           = [string]$spec.severity
                        path               = [string]$spec.path
                        pack               = [string]$spec.pack
                        clusterId          = ""
                        text               = [string]$spec.text
                    })
                $index++
            }
            [void]$results.Add([pscustomobject][ordered]@{
                    exampleId        = [string]$example.exampleId
                    sourceCommitSha  = [string]$example.provenance.sourceCommitSha
                    targetCommitSha  = [string]$example.provenance.targetCommitSha
                    changeSetSha256  = [string]$example.provenance.changeSetSha256
                    commitResolution = "resolved"
                    status           = [string]$result.status
                    vote             = [string]$result.vote
                    claims           = @($claims.ToArray())
                })
        }
        $perExample = [System.Collections.Generic.List[object]]::new()
        foreach ($result in @($ArmSpec.results)) {
            $example = $exampleByPr[[string]$result.prId]
            [void]$perExample.Add([pscustomobject][ordered]@{
                    exampleId    = [string]$example.exampleId
                    latencyMs    = [int]$result.observation.latencyMs
                    inputTokens  = [int]$result.observation.inputTokens
                    outputTokens = [int]$result.observation.outputTokens
                    costMicroUsd = [int]$result.observation.costMicroUsd
                })
        }
        return [pscustomobject][ordered]@{
            kind            = "reviewer-evaluation-run"
            artifactVersion = 1
            schemaVersion   = 1
            runId           = "seed-$arm"
            arm             = $arm
            derivation      = [pscustomobject][ordered]@{
                executedAtEpochSeconds = 1767312000
                corpus                 = [pscustomobject][ordered]@{
                    name          = [string]$corpus.name
                    corpusVersion = [int]$corpus.corpusVersion
                    corpusSha256  = $corpusSha
                    exampleCount  = @($corpus.examples).Count
                }
                binding                = $binding
                models                 = [pscustomobject][ordered]@{
                    generalists          = @($arms.models.generalists | ForEach-Object { [string]$_ })
                    conventionSpecialist = [string]$arms.models.conventionSpecialist
                    conventionVerifier   = [string]$arms.models.conventionVerifier
                }
                results                = @($results.ToArray())
            }
            observations    = [pscustomobject][ordered]@{
                pricingTableVersion = [string]$arms.pricingTableVersion
                rates               = @(@($arms.rates) | ForEach-Object {
                        [pscustomobject][ordered]@{
                            model                      = [string]$_.model
                            inputMicroUsdPerKiloToken  = [int]$_.inputMicroUsdPerKiloToken
                            outputMicroUsdPerKiloToken = [int]$_.outputMicroUsdPerKiloToken
                        }
                    })
                perExample          = @($perExample.ToArray())
            }
        }
    }

    $runs = @(@($arms.arms) | ForEach-Object { New-SeedRun -ArmSpec $_ })
    foreach ($run in $runs) {
        Assert-Eval ([bool](Test-Json -Json ($run | ConvertTo-Json -Depth 32) -SchemaFile $runSchemaPath)) `
            "A built run manifest does not satisfy run.schema.json."
    }

    function New-SeedAdjudication {
        param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Runs, [string]$CorpusHash = $corpusSha)
        $verdictSpecByRef = @{}
        foreach ($verdict in @($arms.verdicts)) { $verdictSpecByRef[[string]$verdict.claimRef] = $verdict }
        $claimByKey = @{}
        foreach ($run in @($Runs)) {
            foreach ($result in @($run.derivation.results)) {
                foreach ($claim in @($result.claims)) { $claimByKey[[string]$claim.blindClaimKey] = $claim }
            }
        }
        $verdicts = [System.Collections.Generic.List[object]]::new()
        foreach ($key in (Get-ReviewerEvalOrdinalSorted -Values @($claimByKey.Keys))) {
            $claimRef = [string]$script:claimRefByKey[$key]
            $spec = $verdictSpecByRef[$claimRef]
            $labels = [System.Collections.Generic.List[object]]::new()
            $stamp = 1767398400
            foreach ($label in @($spec.labels)) {
                [void]$labels.Add([pscustomobject][ordered]@{
                        labelerId             = [string]$label.labelerId
                        labelerKind           = "human"
                        verdict               = [string]$label.verdict
                        matchedIssueIds       = @(@($label.matchedIssueIds) | ForEach-Object { [string]$_ })
                        verdictAtEpochSeconds = $stamp
                    })
                $stamp++
            }
            $claimAdjudication = $null
            if ($null -ne $spec.adjudication) {
                $claimAdjudication = [pscustomobject][ordered]@{
                    adjudicatorId             = [string]$spec.adjudication.adjudicatorId
                    adjudicatorKind           = "human"
                    verdict                   = [string]$spec.adjudication.verdict
                    matchedIssueIds           = @(@($spec.adjudication.matchedIssueIds) | ForEach-Object { [string]$_ })
                    adjudicatedAtEpochSeconds = 1767398500
                }
            }
            [void]$verdicts.Add([pscustomobject][ordered]@{
                    blindClaimKey   = $key
                    presentedSha256 = Get-ReviewerEvalPresentedSha256 -Claim $claimByKey[$key]
                    labels          = @($labels.ToArray())
                    adjudication    = $claimAdjudication
                })
        }
        return [pscustomobject][ordered]@{
            kind                    = "reviewer-evaluation-adjudication"
            artifactVersion         = 1
            schemaVersion           = 1
            adjudicationVersion     = 1
            corpusSha256            = $CorpusHash
            presentationOrderSha256 = Get-ReviewerEvalPresentationOrderSha256 `
                -AdjudicationSalt ([string]$corpus.partitionPolicy.adjudicationSalt) `
                -BlindClaimKeys @($claimByKey.Keys)
            verdicts                = @($verdicts.ToArray())
        }
    }

    $adjudication = New-SeedAdjudication -Runs $runs
    Assert-Eval ([bool](Test-Json -Json ($adjudication | ConvertTo-Json -Depth 32) -SchemaFile $adjudicationSchemaPath)) `
        "The built adjudication does not satisfy adjudication.schema.json."

    # -----------------------------------------------------------------------
    # 6. Run-set consistency: stale, mismatched, duplicated, and missing arms.
    # -----------------------------------------------------------------------
    $runSet = Test-ReviewerEvalRunSetConsistent -Runs $runs -Corpus $corpus
    Assert-Eval ([bool]$runSet.Ok) "A consistent three-arm run set was rejected: $($runSet.ReasonCodes -join ', ')."
    Assert-Eval (@($runSet.ModelIdentities).Count -ge 3) "The run set did not surface the configured model identities."

    $staleRuns = @($runs | ForEach-Object { Copy-EvalObject -Value $_ })
    $staleRuns[0].derivation.results[0].sourceCommitSha = "f" * 40
    $stale = Test-ReviewerEvalRunSetConsistent -Runs $staleRuns -Corpus $corpus
    Assert-Eval ((-not $stale.Ok) -and ($stale.ReasonCodes -ccontains "runStaleCommit")) `
        "A run pinned to a different source commit than the corpus was accepted."

    $unresolvedRuns = @($runs | ForEach-Object { Copy-EvalObject -Value $_ })
    $unresolvedRuns[1].derivation.results[0].commitResolution = "unresolved"
    $unresolved = Test-ReviewerEvalRunSetConsistent -Runs $unresolvedRuns -Corpus $corpus
    Assert-Eval ((-not $unresolved.Ok) -and ($unresolved.ReasonCodes -ccontains "runCommitUnresolved")) `
        "A run whose commit does not resolve was accepted as evidence."

    $bindingRuns = @($runs | ForEach-Object { Copy-EvalObject -Value $_ })
    $bindingRuns[2].derivation.binding.configSha256 = "1" * 64
    $mismatched = Test-ReviewerEvalRunSetConsistent -Runs $bindingRuns -Corpus $corpus
    Assert-Eval ((-not $mismatched.Ok) -and ($mismatched.ReasonCodes -ccontains "runBindingMismatch")) `
        "Arms with different code/config bindings were compared as if they were one measurement."

    $modelRuns = @($runs | ForEach-Object { Copy-EvalObject -Value $_ })
    $modelRuns[0].derivation.models.conventionVerifier = "some-other-model"
    $modelMismatch = Test-ReviewerEvalRunSetConsistent -Runs $modelRuns -Corpus $corpus
    Assert-Eval (-not $modelMismatch.Ok) "Arms run with different model identities were compared without objection."

    $duplicateArm = Test-ReviewerEvalRunSetConsistent -Runs @($runs[0], $runs[0], $runs[1]) -Corpus $corpus
    Assert-Eval ((-not $duplicateArm.Ok) -and ($duplicateArm.ReasonCodes -ccontains "runArmDuplicated")) `
        "A duplicated arm was accepted as a distinct measurement."
    $missingArm = Test-ReviewerEvalRunSetConsistent -Runs @($runs[0], $runs[1]) -Corpus $corpus
    Assert-Eval ((-not $missingArm.Ok) -and ($missingArm.ReasonCodes -ccontains "runArmMissing")) `
        "A two-arm run set was accepted for a three-arm comparison."

    $shortRuns = @($runs | ForEach-Object { Copy-EvalObject -Value $_ })
    $shortRuns[0].derivation.results = @(@($shortRuns[0].derivation.results)[0..2])
    $shortSet = Test-ReviewerEvalRunSetConsistent -Runs $shortRuns -Corpus $corpus
    Assert-Eval ((-not $shortSet.Ok) -and ($shortSet.ReasonCodes -ccontains "runExampleSetMismatch")) `
        "Arms covering different example sets were compared."

    $renamedCorpusRuns = @($runs | ForEach-Object { Copy-EvalObject -Value $_ })
    $renamedCorpusRuns[0].derivation.corpus.name = "production-corpus-v3"
    $renamedCorpusSet = Test-ReviewerEvalRunSetConsistent -Runs $renamedCorpusRuns -Corpus $corpus
    Assert-Eval ((-not $renamedCorpusSet.Ok) -and ($renamedCorpusSet.ReasonCodes -ccontains "runCorpusMismatch")) `
        "A run that self-describes as a differently-named corpus was accepted."

    $forgedKeyRuns = @($runs | ForEach-Object { Copy-EvalObject -Value $_ })
    $forgedKeyRuns[2].derivation.results[0].claims[0].blindClaimKey = "a" * 64
    $forgedKey = Test-ReviewerEvalRunSetConsistent -Runs $forgedKeyRuns -Corpus $corpus
    Assert-Eval ((-not $forgedKey.Ok) -and ($forgedKey.ReasonCodes -ccontains "runBlindClaimKeyMismatch")) `
        "A claim whose blind key does not match its own content was accepted."
    $unratedRuns = @($runs | ForEach-Object { Copy-EvalObject -Value $_ })
    $unratedRuns[2].observations.rates = @(@($unratedRuns[2].observations.rates)[0])
    $unrated = Test-ReviewerEvalRunSetConsistent -Runs $unratedRuns -Corpus $corpus
    Assert-Eval ((-not $unrated.Ok) -and ($unrated.ReasonCodes -ccontains "runObservationsMissing")) `
        "A run whose pricing table does not cover every declared model was accepted."

    $forgedTextRuns = @($runs | ForEach-Object { Copy-EvalObject -Value $_ })
    $forgedTextRuns[2].derivation.results[0].claims[0].text = "Something an adjudicator never saw."
    $forgedText = Test-ReviewerEvalRunSetConsistent -Runs $forgedTextRuns -Corpus $corpus
    Assert-Eval (-not $forgedText.Ok) "A claim whose text was changed after adjudication was accepted."

    # -----------------------------------------------------------------------
    # 7. Corpus integrity: freeze, partitions, leakage, duplicates, ground
    #    truth, labeler independence, and corrections.
    # -----------------------------------------------------------------------
    $tamperedRecord = Copy-EvalObject -Value $corpus
    $tamperedRecord.examples[0].inventory[0].severity = "suggestion"
    $tampered = Test-ReviewerEvalCorpusIntegrity -Corpus $tamperedRecord
    Assert-Eval ((-not $tampered.Ok) -and ($tampered.ReasonCodes -ccontains "corpusRecordHashMismatch")) `
        "A post-freeze edit to a record was not detected."

    $tamperedFreeze = Copy-EvalObject -Value $corpus
    $tamperedFreeze.freeze.corpusSha256 = "b" * 64
    $freezeResult = Test-ReviewerEvalCorpusIntegrity -Corpus $tamperedFreeze
    Assert-Eval ((-not $freezeResult.Ok) -and ($freezeResult.ReasonCodes -ccontains "corpusFreezeHashMismatch")) `
        "A rewritten freeze hash was not detected."

    $movedPartition = Copy-EvalObject -Value $corpus
    $target = @($movedPartition.examples | Where-Object { $_.partition -ceq "holdout" })[0]
    $target.partition = "calibration"
    $target.recordHash = Get-ReviewerEvalRecordHash -Example $target
    $moved = Test-ReviewerEvalCorpusIntegrity -Corpus $movedPartition
    Assert-Eval ((-not $moved.Ok) -and ($moved.ReasonCodes -ccontains "corpusPartitionMismatch")) `
        "An example moved out of the holdout partition was not detected."

    $duplicated = Copy-EvalObject -Value $corpus
    $duplicated.examples = @(@($duplicated.examples) + @($duplicated.examples[0]))
    $duplicateResult = Test-ReviewerEvalCorpusIntegrity -Corpus $duplicated
    Assert-Eval ((-not $duplicateResult.Ok) -and ($duplicateResult.ReasonCodes -ccontains "corpusDuplicateExample")) `
        "A duplicated example was not detected."

    $leaked = Copy-EvalObject -Value $corpus
    $calibrationExample = @($leaked.examples | Where-Object { $_.partition -ceq "calibration" })[0]
    $holdoutExample = @($leaked.examples | Where-Object { $_.partition -ceq "holdout" })[0]
    $twin = Copy-EvalObject -Value $calibrationExample
    $twin.provenance.prId = "999"
    $twin.provenance.changedFilePathsSha256 = [string]$holdoutExample.provenance.changedFilePathsSha256
    $twin.exampleId = Get-ReviewerEvalExampleId -Provenance $twin.provenance
    $twin.groupKey = Get-ReviewerEvalGroupKey -Provenance $twin.provenance
    $twin.recordHash = Get-ReviewerEvalRecordHash -Example $twin
    $leaked.examples = @(@($leaked.examples) + @($twin))
    $leakResult = Test-ReviewerEvalCorpusIntegrity -Corpus $leaked
    Assert-Eval ((-not $leakResult.Ok) -and
        (($leakResult.ReasonCodes -ccontains "corpusGroupLeakage") -or ($leakResult.ReasonCodes -ccontains "corpusPartitionMismatch"))) `
        "A near-twin change sharing a changed-file set was allowed to straddle the calibration/holdout split."

    $forgedTruth = Copy-EvalObject -Value $corpus
    $forgedTruth.examples[0].groundTruth.decision = "approve"
    $forgedTruth.examples[0].recordHash = Get-ReviewerEvalRecordHash -Example $forgedTruth.examples[0]
    $truthResult = Test-ReviewerEvalCorpusIntegrity -Corpus $forgedTruth
    Assert-Eval ((-not $truthResult.Ok) -and ($truthResult.ReasonCodes -ccontains "corpusGroundTruthMismatch")) `
        "Ground truth that disagrees with its own labels was accepted."

    $modelLabeler = Test-ReviewerEvalCorpusIntegrity -Corpus $corpus -ModelIdentities @("seed-labeler-a")
    Assert-Eval ((-not $modelLabeler.Ok) -and ($modelLabeler.ReasonCodes -ccontains "corpusModelIdentityAsLabeler")) `
        "A model identity was accepted as a ground-truth labeler."

    $leakedField = Copy-EvalObject -Value $corpus
    $leakedField.examples[0].inventory[0] | Add-Member -NotePropertyName "blindClaimKey" -NotePropertyValue ("c" * 64) -Force
    $leakedFieldResult = Test-ReviewerEvalCorpusIntegrity -Corpus $leakedField
    Assert-Eval ((-not $leakedFieldResult.Ok) -and ($leakedFieldResult.ReasonCodes -ccontains "corpusForbiddenField")) `
        "Model output was allowed into the ground-truth corpus."

    $isoCorpus = Copy-EvalObject -Value $corpus
    Assert-Eval (Test-ReviewerEvalNoRehydratedDateTime -Value $isoCorpus) `
        "The shipped corpus carries an ISO-8601 timestamp that ConvertFrom-Json rehydrates as a DateTime."
    $isoProbe = '{"a":"2026-08-04T22:28:53.0640000Z"}' | ConvertFrom-Json
    Assert-Eval (-not (Test-ReviewerEvalNoRehydratedDateTime -Value $isoProbe)) `
        "The DateTime rehydration guard does not detect an ISO-8601 string."

    $lateCorrection = Copy-EvalObject -Value $corpus
    $lateCorrection.corpusVersion = 2
    $lateCorrection.corrections = @([pscustomobject][ordered]@{
            sequence              = 1
            correctionVersion     = 2
            exampleId             = [string]$corpus.examples[0].exampleId
            supersedesRecordHash  = [string]$corpus.examples[0].recordHash
            reasonCode            = "labelError"
            authorId              = "seed-corrector"
            authorKind            = "human"
            appliedAtEpochSeconds = 1767398400
        })
    # A correction is inside the freeze digest, so appending one re-freezes the
    # corpus - which is exactly why every prior run then reports a mismatch.
    $lateCorrection.freeze.corpusSha256 = Get-ReviewerEvalCorpusSha256 `
        -Name ([string]$lateCorrection.name) -CorpusVersion ([int]$lateCorrection.corpusVersion) `
        -CorpusPin $lateCorrection.corpusPin `
        -FrozenAtEpochSeconds ([int64]$lateCorrection.frozenAtEpochSeconds) `
        -PartitionPolicy $lateCorrection.partitionPolicy `
        -Strata @($lateCorrection.strata) -Corrections @($lateCorrection.corrections) `
        -RecordHashes @(@($lateCorrection.examples) | ForEach-Object { [string]$_.recordHash })
    Assert-Eval ([string]$lateCorrection.freeze.corpusSha256 -cne [string]$corpus.freeze.corpusSha256) `
        "Appending a correction did not change the corpus freeze digest."
    $lateResult = Test-ReviewerEvalCorpusIntegrity -Corpus $lateCorrection -EarliestRunSequence 1767312000
    Assert-Eval ((-not $lateResult.Ok) -and ($lateResult.ReasonCodes -ccontains "postRunCorrection")) `
        "A ground-truth correction authored AFTER the arms ran was accepted."
    $earlyResult = Test-ReviewerEvalCorpusIntegrity -Corpus $lateCorrection -EarliestRunSequence 1767484800
    Assert-Eval ([bool]$earlyResult.Ok) `
        "A pre-registered correction was rejected: $($earlyResult.ReasonCodes -join ', ')."
    # The corpus pin and name are inside the freeze digest, so a re-seal under a
    # different pin cannot leave prior runs verifying clean.
    $repinned = Copy-EvalObject -Value $corpus
    $repinned.corpusPin.commitSha = "2" * 40
    $repinnedResult = Test-ReviewerEvalCorpusIntegrity -Corpus $repinned
    Assert-Eval ((-not $repinnedResult.Ok) -and ($repinnedResult.ReasonCodes -ccontains "corpusFreezeHashMismatch")) `
        "The corpus pin an operator eventually transcribes is outside the freeze digest."
    $renamed = Copy-EvalObject -Value $corpus
    $renamed.name = "production-corpus-v3"
    $renamedResult = Test-ReviewerEvalCorpusIntegrity -Corpus $renamed
    Assert-Eval ((-not $renamedResult.Ok) -and ($renamedResult.ReasonCodes -ccontains "corpusFreezeHashMismatch")) `
        "The corpus name is outside the freeze digest."
    $refrozen = Copy-EvalObject -Value $corpus
    $refrozen.frozenAtEpochSeconds = [int64]$refrozen.frozenAtEpochSeconds + 86400
    $refrozenResult = Test-ReviewerEvalCorpusIntegrity -Corpus $refrozen
    Assert-Eval ((-not $refrozenResult.Ok) -and ($refrozenResult.ReasonCodes -ccontains "corpusFreezeHashMismatch")) `
        "The freeze time is outside the freeze digest."

    # A zero-example corpus must not skip freeze verification entirely.
    $emptyCorpus = Copy-EvalObject -Value $corpus
    $emptyCorpus.examples = @()
    $emptyCorpus.freeze.exampleCount = 4242
    $emptyCorpus.freeze.corpusSha256 = "e" * 64
    $emptyCorpus.freeze.partitionAssignmentSha256 = "f" * 64
    $emptyResult = Test-ReviewerEvalCorpusIntegrity -Corpus $emptyCorpus
    Assert-Eval (-not $emptyResult.Ok) "A zero-example corpus with a fabricated freeze block verified clean."
    Assert-Eval ($emptyResult.ReasonCodes -ccontains "corpusFreezeHashMismatch") `
        "A zero-example corpus skipped freeze-digest verification."
    $emptyValid = $false
    try {
        $emptyValid = [bool](Test-Json -Json ($emptyCorpus | ConvertTo-Json -Depth 32) `
                -SchemaFile $corpusSchemaPath -ErrorAction SilentlyContinue)
    }
    catch { $emptyValid = $false }
    Assert-Eval (-not $emptyValid) "corpus.schema.json accepts a corpus with no examples."

    # -----------------------------------------------------------------------
    # 8. Blind adjudication: structure, blindness, independence, conflicts.
    # -----------------------------------------------------------------------
    $salt = [string]$corpus.partitionPolicy.adjudicationSalt
    $adjudicationResult = Test-ReviewerEvalAdjudication -Adjudication $adjudication -RunSet $runSet -Corpus $corpus -AdjudicationSalt $salt
    Assert-Eval ([bool]$adjudicationResult.Ok) "A well-formed adjudication was rejected: $($adjudicationResult.ReasonCodes -join ', ')."
    Assert-Eval ([int]$adjudicationResult.Presented -gt 0) "The adjudication presented no claims."
    Assert-Eval ([int]$adjudicationResult.Abstained -ge 1) "The seed fixture no longer exercises an abstention."
    Assert-Eval ($null -ne $adjudicationResult.Coverage -and [double]$adjudicationResult.Coverage -lt 1.0) `
        "Abstentions did not reduce adjudication coverage; abstaining on hard claims must cost coverage, not raise precision."

    $orderTampered = Copy-EvalObject -Value $adjudication
    $orderTampered.presentationOrderSha256 = "d" * 64
    $orderResult = Test-ReviewerEvalAdjudication -Adjudication $orderTampered -RunSet $runSet -Corpus $corpus -AdjudicationSalt $salt
    Assert-Eval ((-not $orderResult.Ok) -and ($orderResult.ReasonCodes -ccontains "adjudicationPresentationOrderMismatch")) `
        "A presentation order that was not derived from the frozen salt was accepted."

    $presentedTampered = Copy-EvalObject -Value $adjudication
    $presentedTampered.verdicts[0].presentedSha256 = "e" * 64
    $presentedResult = Test-ReviewerEvalAdjudication -Adjudication $presentedTampered -RunSet $runSet -Corpus $corpus -AdjudicationSalt $salt
    Assert-Eval ((-not $presentedResult.Ok) -and ($presentedResult.ReasonCodes -ccontains "adjudicationPresentedHashMismatch")) `
        "A verdict filed against a payload the adjudicator never saw was accepted."

    $armLeak = Copy-EvalObject -Value $adjudication
    $armLeak.verdicts[0] | Add-Member -NotePropertyName "arm" -NotePropertyValue "verified" -Force
    $armLeakResult = Test-ReviewerEvalAdjudication -Adjudication $armLeak -RunSet $runSet -Corpus $corpus -AdjudicationSalt $salt
    Assert-Eval ((-not $armLeakResult.Ok) -and ($armLeakResult.ReasonCodes -ccontains "adjudicationForbiddenField")) `
        "An adjudication carrying the producing arm was accepted as blind."

    $modelVerdict = Copy-EvalObject -Value $adjudication
    $modelVerdict.verdicts[0].labels[0].labelerId = "seed-generalist-one"
    $modelVerdictResult = Test-ReviewerEvalAdjudication -Adjudication $modelVerdict -RunSet $runSet -Corpus $corpus -AdjudicationSalt $salt
    Assert-Eval ((-not $modelVerdictResult.Ok) -and ($modelVerdictResult.ReasonCodes -ccontains "adjudicationModelIdentityAsLabeler")) `
        "A model identity was accepted as a claim adjudicator."

    $unknownIssue = Copy-EvalObject -Value $adjudication
    $unknownIssue.verdicts[0].labels[0].matchedIssueIds = @("no-such-issue")
    $unknownIssueResult = Test-ReviewerEvalAdjudication -Adjudication $unknownIssue -RunSet $runSet -Corpus $corpus -AdjudicationSalt $salt
    Assert-Eval ((-not $unknownIssueResult.Ok) -and ($unknownIssueResult.ReasonCodes -ccontains "adjudicationMatchedIssueUnknown")) `
        "A verdict matched a claim to an issue that is not in the corpus inventory."

    $missingVerdict = Copy-EvalObject -Value $adjudication
    $missingVerdict.verdicts = @(@($missingVerdict.verdicts)[1..(@($missingVerdict.verdicts).Count - 1)])
    $missingVerdictResult = Test-ReviewerEvalAdjudication -Adjudication $missingVerdict -RunSet $runSet -Corpus $corpus -AdjudicationSalt $salt
    Assert-Eval ((-not $missingVerdictResult.Ok) -and ($missingVerdictResult.ReasonCodes -ccontains "adjudicationMissingClaim")) `
        "A presented claim with no verdict at all was accepted."

    $duplicateVerdict = Copy-EvalObject -Value $adjudication
    $duplicateVerdict.verdicts = @(@($duplicateVerdict.verdicts) + @($duplicateVerdict.verdicts[0]))
    $duplicateVerdictResult = Test-ReviewerEvalAdjudication -Adjudication $duplicateVerdict -RunSet $runSet -Corpus $corpus -AdjudicationSalt $salt
    Assert-Eval ((-not $duplicateVerdictResult.Ok) -and ($duplicateVerdictResult.ReasonCodes -ccontains "adjudicationDuplicateClaim")) `
        "Two verdicts for the same blind claim were accepted."

    $corpusMismatch = Copy-EvalObject -Value $adjudication
    $corpusMismatch.corpusSha256 = "f" * 64
    $corpusMismatchResult = Test-ReviewerEvalAdjudication -Adjudication $corpusMismatch -RunSet $runSet -Corpus $corpus -AdjudicationSalt $salt
    Assert-Eval ((-not $corpusMismatchResult.Ok) -and ($corpusMismatchResult.ReasonCodes -ccontains "adjudicationCorpusMismatch")) `
        "An adjudication bound to a different corpus was accepted."

    # Claim-level reconciliation, directly.
    $concordant = Get-ReviewerEvalClaimVerdict -Labels @(
        [pscustomobject]@{ labelerId = "x"; verdict = "truePositive"; matchedIssueIds = @("i1", "i2") },
        [pscustomobject]@{ labelerId = "y"; verdict = "truePositive"; matchedIssueIds = @("i1") })
    Assert-Eval ([string]$concordant.Resolution -ceq "concordant" -and (@($concordant.MatchedIssueIds) -join ",") -ceq "i1") `
        "Concordant verdicts did not use the conservative (intersected) match set."
    $discordant = Get-ReviewerEvalClaimVerdict -Labels @(
        [pscustomobject]@{ labelerId = "x"; verdict = "truePositive"; matchedIssueIds = @("i1") },
        [pscustomobject]@{ labelerId = "y"; verdict = "falsePositive"; matchedIssueIds = @() })
    Assert-Eval ([string]$discordant.Resolution -ceq "disputed" -and $null -eq $discordant.Verdict) `
        "An unresolved disagreement was silently resolved."
    $notIndependent = Get-ReviewerEvalClaimVerdict -Labels @(
        [pscustomobject]@{ labelerId = "x"; verdict = "truePositive"; matchedIssueIds = @("i1") },
        [pscustomobject]@{ labelerId = "y"; verdict = "falsePositive"; matchedIssueIds = @() }) `
        -Adjudication ([pscustomobject]@{ adjudicatorId = "x"; verdict = "truePositive"; matchedIssueIds = @("i1") })
    Assert-Eval ([string]$notIndependent.Resolution -ceq "disputed") "A labeler adjudicated their own disagreement."
    $singleLabeler = Get-ReviewerEvalClaimVerdict -Labels @(
        [pscustomobject]@{ labelerId = "x"; verdict = "truePositive"; matchedIssueIds = @("i1") })
    Assert-Eval ([string]$singleLabeler.Resolution -ceq "disputed") "A single verdict was accepted as adjudicated."
    $sameLabelerTwice = Get-ReviewerEvalClaimVerdict -Labels @(
        [pscustomobject]@{ labelerId = "x"; verdict = "truePositive"; matchedIssueIds = @("i1") },
        [pscustomobject]@{ labelerId = "x"; verdict = "truePositive"; matchedIssueIds = @("i1") })
    Assert-Eval ([string]$sameLabelerTwice.Resolution -ceq "disputed") "One labeler voting twice counted as two independent verdicts."

    # -----------------------------------------------------------------------
    # 9. Metrics: denominators, duplicates, unknown/degraded, severity, votes.
    # -----------------------------------------------------------------------
    $verdicts = $adjudicationResult.Verdicts
    $verifiedRun = $runSet.ByArm["verified"]
    $baselineRun = $runSet.ByArm["generalistOnly"]
    $multiPassRun = $runSet.ByArm["multiPassDiscovery"]
    $verifiedAll = Get-ReviewerEvalArmMetrics -Run $verifiedRun -Corpus $corpus -Verdicts $verdicts -Partition all
    $baselineAll = Get-ReviewerEvalArmMetrics -Run $baselineRun -Corpus $corpus -Verdicts $verdicts -Partition all
    $multiPassAll = Get-ReviewerEvalArmMetrics -Run $multiPassRun -Corpus $corpus -Verdicts $verdicts -Partition all

    Assert-Eval ([int]$multiPassAll.duplicateClaims -ge 1 -and [double]$multiPassAll.duplicateRate -gt 0.0) `
        "The duplicate claim in the fixture did not register as a duplicate."
    Assert-Eval ([int]$multiPassAll.rawResolvedClaims -gt [int]$multiPassAll.uniqueResolvedClaims) `
        "Raw and unique claim counts are identical despite a duplicated claim."
    Assert-Eval ([double]$verifiedAll.uniqueClaimPrecision -gt [double]$baselineAll.uniqueClaimPrecision) `
        "Withholding an unsupported claim did not raise the verified arm's precision above the baseline."
    Assert-Eval ([double]$verifiedAll.correctnessRecall -ge [double]$baselineAll.correctnessRecall) `
        "The verified arm's correctness recall fell below the generalist baseline in the seed fixture."
    Assert-Eval ([double]$verifiedAll.conventionRecall -gt 0.0) "Convention recall is zero despite matched convention issues."
    Assert-Eval (@($verifiedAll.issueClassRecall).Count -gt 1) "Issue-class recall was not reported per class."
    Assert-Eval ($null -ne $verifiedAll.severityAccuracy) "Severity accuracy has no denominator."
    Assert-Eval ([int]$verifiedAll.voteDecisions -gt 0 -and $null -ne $verifiedAll.voteAccuracy) "Vote accuracy has no denominator."
    Assert-Eval ([int64]$verifiedAll.costMicroUsd -gt [int64]$baselineAll.costMicroUsd) "Cost is not accumulated per arm."
    Assert-Eval ($null -ne $verifiedAll.latencyMsMedian -and $null -ne $verifiedAll.latencyMsP95) "Latency percentiles were not computed."

    # A disputed example contributes no ground truth, so it must not depress recall.
    $disputedExample = @($corpus.examples | Where-Object { $_.groundTruth.resolution -ceq "disputed" })
    Assert-Eval (@($disputedExample).Count -ge 1) "The seed fixture no longer exercises a disputed example."
    Assert-Eval (@(@($verifiedAll.issueClassRecall) | Where-Object { [string]$_.issueClass -ceq "generatedCodeEdit" }).Count -eq 0) `
        "A disputed example's inventory entered a recall denominator."

    # Degraded / unknown / missing evidence is excluded from denominators AND
    # surfaced, rather than silently counted as a clean run.
    $degradedRun = Copy-EvalObject -Value $verifiedRun
    $degradedRun.derivation.results[0].status = "degraded"
    $degradedMetrics = Get-ReviewerEvalArmMetrics -Run $degradedRun -Corpus $corpus -Verdicts $verdicts -Partition all
    Assert-Eval ([int]$degradedMetrics.degradedExamples -eq 1) "A degraded example was not counted as degraded."
    Assert-Eval ([int]$degradedMetrics.rawClaims -lt [int]$verifiedAll.rawClaims) `
        "A degraded example's claims still entered the metrics."
    $unknownRun = Copy-EvalObject -Value $verifiedRun
    $unknownRun.derivation.results[1].status = "unknown"
    $unknownMetrics = Get-ReviewerEvalArmMetrics -Run $unknownRun -Corpus $corpus -Verdicts $verdicts -Partition all
    Assert-Eval ([int]$unknownMetrics.unknownExamples -eq 1) "An unknown-status example was not counted."
    $missingRun = Copy-EvalObject -Value $verifiedRun
    $missingRun.derivation.results[2].status = "missing"
    $missingMetrics = Get-ReviewerEvalArmMetrics -Run $missingRun -Corpus $corpus -Verdicts $verdicts -Partition all
    Assert-Eval ([int]$missingMetrics.missingExamples -eq 1) "A missing-status example was not counted."

    # Empty everything: null metrics, never a comfortable zero or one.
    $emptyRun = Copy-EvalObject -Value $verifiedRun
    foreach ($result in @($emptyRun.derivation.results)) {
        $result.claims = @()
        $result.status = "complete"
    }
    $emptyMetrics = Get-ReviewerEvalArmMetrics -Run $emptyRun -Corpus $corpus -Verdicts $verdicts -Partition all
    Assert-Eval ($null -eq $emptyMetrics.rawPrecision -and $null -eq $emptyMetrics.uniqueClaimPrecision -and $null -eq $emptyMetrics.duplicateRate) `
        "An arm that produced nothing reported a precision instead of an undefined one."

    # -----------------------------------------------------------------------
    # 10. Rollout qualification: the seed corpus qualifies NOTHING, and the
    #     individual vetoes fire for the right reasons.
    # -----------------------------------------------------------------------
    $verifiedHoldout = Get-ReviewerEvalArmMetrics -Run $verifiedRun -Corpus $corpus -Verdicts $verdicts -Partition holdout
    $baselineHoldout = Get-ReviewerEvalArmMetrics -Run $baselineRun -Corpus $corpus -Verdicts $verdicts -Partition holdout
    $comparison = Get-ReviewerEvalRecallComparison -BaselineMetrics $baselineHoldout `
        -CandidateMetrics $verifiedHoldout -EffectivePolicy $effectivePolicy
    $holdoutScopes = @(@($effectivePolicy.qualifiableScopes) | ForEach-Object {
            Get-ReviewerEvalScopeMetrics -Run $verifiedRun -Corpus $corpus -Verdicts $verdicts `
                -Partition holdout -Pack ([string]$_.pack) -Severity ([string]$_.severity) -EffectivePolicy $effectivePolicy
        })
    $qualification = Test-ReviewerEvalRolloutQualification -EffectivePolicy $effectivePolicy `
        -CorpusIntegrity $integrity -RunSetConsistency $runSet -AdjudicationResult $adjudicationResult `
        -CandidateHoldoutMetrics $verifiedHoldout -Comparison $comparison -HoldoutScopes $holdoutScopes `
        -DegradedExamples 0 -UnknownExamples 0 -MissingExamples 0
    Assert-Eval (-not [bool]$qualification.anyQualified) "A seed corpus qualified a rollout requirement."
    Assert-Eval ($qualification.globalVetoes -ccontains "seedCorpus") "The seed-corpus veto did not fire."
    Assert-Eval ($qualification.globalVetoes -ccontains "zeroQualifyingExamples") "The zero-qualifying-examples veto did not fire."
    Assert-Eval ($qualification.globalVetoes -ccontains "belowMinimumExamples") "The 100-example population floor did not fire."
    foreach ($requirement in @($qualification.requirements)) {
        Assert-Eval (-not [bool]$requirement.ok) "Requirement '$($requirement.id)' qualified on a seed corpus."
    }
    $suggestionRequirement = @($qualification.requirements | Where-Object { [string]$_.id -ceq "unattendedSuggestionComments" })[0]
    Assert-Eval ($suggestionRequirement.reasonCodes -ccontains "suggestionsPreviewOnly") `
        "Suggestions are not held preview-only pending separate qualification."

    # The decisive property: perfect numbers at an absurd sample size still
    # qualify nothing while a single seed record exists. A layer that can grade
    # its own homework is worth nothing regardless of the rest of it.
    $perfectMetrics = [pscustomobject]@{
        eligibleUnattendedFindings = 800; eligibleTruePositives = 800; eligibleFalsePositives = 0
        eligiblePrecision = 1.0; criticalAdjudicatedClaims = 600; criticalFalsePositives = 0
        voteDecisions = 700; wouldApproveCount = 600; falseApprovalCount = 0; voteAccuracy = 1.0
        shouldApproveDecisions = 600; approveCorrectDecisions = 600; approvalRecall = 1.0
    }
    $perfectComparison = [pscustomobject]@{
        inventoryCount = 800; denominatorsAgree = $true; withinCeiling = $true
        regressionUpperBound95 = 0.0; regressionPointEstimate = 0.0
        baselineOnly = 0; candidateOnly = 0; discordantPairs = 0
        primaryEndpoint = "test"
    }
    $perfectScopes = @(@($effectivePolicy.qualifiableScopes) | ForEach-Object {
            [pscustomobject]@{
                pack = [string]$_.pack; severity = [string]$_.severity; sampleCount = 800
                truePositives = 800; falsePositives = 0; precision = 1.0; precisionLowerBound95 = 0.999
                recall = 1.0; recallLowerBound95 = 0.999; boundMethod = "test"
            }
        })
    $perfectQualification = Test-ReviewerEvalRolloutQualification -EffectivePolicy $effectivePolicy `
        -CorpusIntegrity $integrity -RunSetConsistency $runSet -AdjudicationResult $adjudicationResult `
        -CandidateHoldoutMetrics $perfectMetrics -Comparison $perfectComparison -HoldoutScopes $perfectScopes `
        -DegradedExamples 0 -UnknownExamples 0 -MissingExamples 0
    Assert-Eval (-not [bool]$perfectQualification.anyQualified) `
        "A seed corpus with perfect metrics at n=800 qualified a rollout requirement."
    Assert-Eval ($perfectQualification.globalVetoes -ccontains "seedCorpus") `
        "The seed veto was not the reason a perfect-looking seed corpus failed."

    # With the seed vetoes removed, the same perfect numbers DO qualify - which
    # is what proves the vetoes above are doing the work, not an unrelated bug.
    $cleanIntegrity = [pscustomobject]@{
        Ok = $true; ReasonCodes = @(); AdjudicationSalt = $salt
        Population = [pscustomobject]@{
            totalExamples = 1500; qualifyingExamples = 1500; seedExamples = 0
            calibrationExamples = 1200; holdoutExamples = 300
            byStratum = @($script:ReviewerEvalStrata | ForEach-Object {
                    [pscustomobject]@{ stratum = $_; total = 160; calibration = 128; holdout = 32 } })
        }
        Examples = @()
    }
    $cleanAdjudication = [pscustomobject]@{
        Ok = $true; ReasonCodes = @(); Verdicts = @{}; Presented = 800; Resolved = 800
        Abstained = 0; Disputed = 0; Coverage = 1.0; Kappa = 0.9; DisagreementRate = 0.05
    }
    $cleanQualification = Test-ReviewerEvalRolloutQualification -EffectivePolicy $effectivePolicy `
        -CorpusIntegrity $cleanIntegrity -RunSetConsistency $runSet -AdjudicationResult $cleanAdjudication `
        -CandidateHoldoutMetrics $perfectMetrics -Comparison $perfectComparison -HoldoutScopes $perfectScopes `
        -DegradedExamples 0 -UnknownExamples 0 -MissingExamples 0
    $commentRequirement = @($cleanQualification.requirements | Where-Object { [string]$_.id -ceq "unattendedImportantCriticalComments" })[0]
    Assert-Eval ([bool]$commentRequirement.ok) `
        "A clean corpus with 800/800 eligible findings still failed the comment requirement: $($commentRequirement.reasonCodes -join ', ')."
    $approvalRequirement = @($cleanQualification.requirements | Where-Object { [string]$_.id -ceq "approvalVote" })[0]
    Assert-Eval ([bool]$approvalRequirement.ok) `
        "A clean corpus with 700 decisions and zero false approvals still failed the approval requirement: $($approvalRequirement.reasonCodes -join ', ')."

    function Test-CleanQualification {
        param([hashtable]$MetricOverrides = @{}, [hashtable]$ComparisonOverrides = @{},
            [int]$Degraded = 0, [int]$Unknown = 0, [int]$Missing = 0, $Adjudication = $cleanAdjudication)
        $metrics = Copy-EvalObject -Value $perfectMetrics
        foreach ($key in $MetricOverrides.Keys) { $metrics.$key = $MetricOverrides[$key] }
        $comp = Copy-EvalObject -Value $perfectComparison
        foreach ($key in $ComparisonOverrides.Keys) { $comp.$key = $ComparisonOverrides[$key] }
        return Test-ReviewerEvalRolloutQualification -EffectivePolicy $effectivePolicy `
            -CorpusIntegrity $cleanIntegrity -RunSetConsistency $runSet -AdjudicationResult $Adjudication `
            -CandidateHoldoutMetrics $metrics -Comparison $comp -HoldoutScopes $perfectScopes `
            -DegradedExamples $Degraded -UnknownExamples $Unknown -MissingExamples $Missing
    }
    function Get-CommentReasons {
        param([Parameter(Mandatory)]$Qualification)
        return @(@($Qualification.requirements | Where-Object { [string]$_.id -ceq "unattendedImportantCriticalComments" })[0].reasonCodes)
    }
    function Get-ApprovalReasons {
        param([Parameter(Mandatory)]$Qualification)
        return @(@($Qualification.requirements | Where-Object { [string]$_.id -ceq "approvalVote" })[0].reasonCodes)
    }

    # Sample-size boundary: exactly 200 eligible findings passes, 199 does not.
    Assert-Eval ((Get-CommentReasons -Qualification (Test-CleanQualification -MetricOverrides @{
                    eligibleUnattendedFindings = 200; eligibleTruePositives = 200 })) -cnotcontains "sampleCountBelowFloor") `
        "Exactly 200 eligible holdout findings failed the sample-size floor."
    Assert-Eval ((Get-CommentReasons -Qualification (Test-CleanQualification -MetricOverrides @{
                    eligibleUnattendedFindings = 199; eligibleTruePositives = 199 })) -ccontains "sampleCountBelowFloor") `
        "199 eligible holdout findings passed the 200-finding floor."
    # Precision boundary at the exact 98% bar.
    Assert-Eval ((Get-CommentReasons -Qualification (Test-CleanQualification -MetricOverrides @{
                    eligibleUnattendedFindings = 1000; eligibleTruePositives = 980; eligibleFalsePositives = 20
                    eligiblePrecision = 0.98 })) -cnotcontains "precisionBelowFloor") `
        "Exactly 98% observed precision failed the precision floor."
    Assert-Eval ((Get-CommentReasons -Qualification (Test-CleanQualification -MetricOverrides @{
                    eligibleUnattendedFindings = 1000; eligibleTruePositives = 979; eligibleFalsePositives = 21
                    eligiblePrecision = 0.979 })) -ccontains "precisionBelowFloor") `
        "97.9% observed precision passed the 98% precision floor."
    # Lower-bound boundary: high point precision on a small sample must fail.
    Assert-Eval ((Get-CommentReasons -Qualification (Test-CleanQualification -MetricOverrides @{
                    eligibleUnattendedFindings = 200; eligibleTruePositives = 200; eligibleFalsePositives = 0
                    eligiblePrecision = 1.0 })) -cnotcontains "precisionLowerBoundBelowFloor") `
        "200/200 failed the 95% lower-bound floor."
    Assert-Eval ((Get-CommentReasons -Qualification (Test-CleanQualification -MetricOverrides @{
                    eligibleUnattendedFindings = 100; eligibleTruePositives = 98; eligibleFalsePositives = 2
                    eligiblePrecision = 0.98 })) -ccontains "precisionLowerBoundBelowFloor") `
        "98/100 (98.0% point, but a lower bound under 95%) cleared the lower-bound floor."
    # Critical stratum: zero critical claims must NOT read as a passing veto.
    Assert-Eval ((Get-CommentReasons -Qualification (Test-CleanQualification -MetricOverrides @{
                    criticalAdjudicatedClaims = 0; criticalFalsePositives = 0 })) -ccontains "criticalStratumEmpty") `
        "Zero adjudicated critical claims satisfied the zero-critical-false-positive veto."
    Assert-Eval ((Get-CommentReasons -Qualification (Test-CleanQualification -MetricOverrides @{
                    criticalAdjudicatedClaims = 600; criticalFalsePositives = 1 })) -ccontains "criticalFalsePositivesPresent") `
        "A single critical false positive did not veto unattended comments."
    Assert-Eval ((Get-CommentReasons -Qualification (Test-CleanQualification -MetricOverrides @{
                    criticalAdjudicatedClaims = 29; criticalFalsePositives = 0 })) -ccontains "sampleCountBelowFloor") `
        "A critical stratum below its sample floor was accepted."
    # Recall regression.
    Assert-Eval ((Get-CommentReasons -Qualification (Test-CleanQualification -ComparisonOverrides @{ withinCeiling = $false })) `
            -ccontains "recallRegressionAboveCeiling") "A recall regression above the ceiling did not veto."
    Assert-Eval ((Get-CommentReasons -Qualification (Test-CleanQualification -ComparisonOverrides @{ inventoryCount = 0 })) `
            -ccontains "recallDenominatorZero") "An empty recall denominator was treated as no regression."
    Assert-Eval ((Get-CommentReasons -Qualification (Test-CleanQualification -ComparisonOverrides @{ denominatorsAgree = $false })) `
            -ccontains "recallDenominatorZero") "Mismatched recall denominators were compared anyway."
    # Unknown / degraded / missing evidence fails closed.
    Assert-Eval ((Get-CommentReasons -Qualification (Test-CleanQualification -Degraded 1)) -ccontains "evidenceDegraded") `
        "A degraded example did not fail qualification closed."
    Assert-Eval ((Get-CommentReasons -Qualification (Test-CleanQualification -Unknown 1)) -ccontains "evidenceUnknown") `
        "An unknown-status example did not fail qualification closed."
    Assert-Eval ((Get-CommentReasons -Qualification (Test-CleanQualification -Missing 1)) -ccontains "evidenceMissing") `
        "A missing example did not fail qualification closed."
    # Adjudication quality floors.
    $lowCoverage = Copy-EvalObject -Value $cleanAdjudication
    $lowCoverage.Coverage = 0.9
    Assert-Eval ((Get-CommentReasons -Qualification (Test-CleanQualification -Adjudication $lowCoverage)) `
            -ccontains "adjudicationCoverageBelowFloor") "Low adjudication coverage did not veto qualification."
    $nullKappa = Copy-EvalObject -Value $cleanAdjudication
    $nullKappa.Kappa = $null
    Assert-Eval ((Get-CommentReasons -Qualification (Test-CleanQualification -Adjudication $nullKappa)) `
            -ccontains "labelAgreementUndefined") "An undefined agreement statistic was read as agreement."
    $lowKappa = Copy-EvalObject -Value $cleanAdjudication
    $lowKappa.Kappa = 0.2
    Assert-Eval ((Get-CommentReasons -Qualification (Test-CleanQualification -Adjudication $lowKappa)) `
            -ccontains "labelAgreementBelowFloor") "Label agreement below the floor did not veto qualification."
    # Approval vote vetoes.
    Assert-Eval ((Get-ApprovalReasons -Qualification (Test-CleanQualification -MetricOverrides @{ voteDecisions = 299 })) `
            -ccontains "sampleCountBelowFloor") "299 labeled decisions passed the 300-decision floor."
    Assert-Eval ((Get-ApprovalReasons -Qualification (Test-CleanQualification -MetricOverrides @{ voteDecisions = 300 })) `
            -cnotcontains "sampleCountBelowFloor") "Exactly 300 labeled decisions failed the 300-decision floor."
    Assert-Eval ((Get-ApprovalReasons -Qualification (Test-CleanQualification -MetricOverrides @{ falseApprovalCount = 1 })) `
            -ccontains "falseApprovalsPresent") "A single false approval did not veto the approval gate."
    Assert-Eval ((Get-ApprovalReasons -Qualification (Test-CleanQualification -MetricOverrides @{ wouldApproveCount = 0; falseApprovalCount = 0 })) `
            -ccontains "approvalStratumEmpty") "An arm that never approves satisfied the zero-false-approval veto."

    # A policy that declares no important/critical scope must fail closed, not
    # quietly delete the per-scope evidence requirement (and with it the
    # multiplicity penalty).
    $noScopePolicy = ConvertTo-ReviewerEvalEffectivePolicy -Policy (
        $(
            $stripped = Copy-EvalObject -Value $policy
            $stripped.qualifiableScopes = @([pscustomobject]@{ pack = "(generalist)"; severity = "suggestion" })
            $stripped
        ))
    $noScopeQualification = Test-ReviewerEvalRolloutQualification -EffectivePolicy $noScopePolicy `
        -CorpusIntegrity $cleanIntegrity -RunSetConsistency $runSet -AdjudicationResult $cleanAdjudication `
        -CandidateHoldoutMetrics $perfectMetrics -Comparison $perfectComparison -HoldoutScopes @() `
        -DegradedExamples 0 -UnknownExamples 0 -MissingExamples 0
    Assert-Eval ((Get-CommentReasons -Qualification $noScopeQualification) -ccontains "commentScopeNotDeclared") `
        "A policy declaring no important/critical scope still qualified unattended comments."

    # Paired comparison: equal-size but DIFFERENT inventory key sets are not a
    # pairing, and must not be differenced.
    $disjointBaseline = [pscustomobject]@{
        CorrectnessKeys        = [System.Collections.Generic.HashSet[string]]::new([string[]]@("e1|i1", "e1|i2"), [StringComparer]::Ordinal)
        MatchedCorrectnessKeys = [System.Collections.Generic.HashSet[string]]::new([string[]]@("e1|i1"), [StringComparer]::Ordinal)
    }
    $disjointCandidate = [pscustomobject]@{
        CorrectnessKeys        = [System.Collections.Generic.HashSet[string]]::new([string[]]@("e2|i1", "e2|i2"), [StringComparer]::Ordinal)
        MatchedCorrectnessKeys = [System.Collections.Generic.HashSet[string]]::new([string[]]@("e2|i1"), [StringComparer]::Ordinal)
    }
    $disjointComparison = Get-ReviewerEvalRecallComparison -BaselineMetrics $disjointBaseline `
        -CandidateMetrics $disjointCandidate -EffectivePolicy $effectivePolicy
    Assert-Eval (-not [bool]$disjointComparison.denominatorsAgree) `
        "Two equal-sized but disjoint inventory sets were treated as a paired comparison."
    $pairedBaseline = [pscustomobject]@{
        CorrectnessKeys        = [System.Collections.Generic.HashSet[string]]::new([string[]]@("e1|i1", "e1|i2"), [StringComparer]::Ordinal)
        MatchedCorrectnessKeys = [System.Collections.Generic.HashSet[string]]::new([string[]]@("e1|i1"), [StringComparer]::Ordinal)
    }
    $pairedCandidate = [pscustomobject]@{
        CorrectnessKeys        = [System.Collections.Generic.HashSet[string]]::new([string[]]@("e1|i1", "e1|i2"), [StringComparer]::Ordinal)
        MatchedCorrectnessKeys = [System.Collections.Generic.HashSet[string]]::new([string[]]@("e1|i1", "e1|i2"), [StringComparer]::Ordinal)
    }
    $pairedComparison = Get-ReviewerEvalRecallComparison -BaselineMetrics $pairedBaseline `
        -CandidateMetrics $pairedCandidate -EffectivePolicy $effectivePolicy
    Assert-Eval ([bool]$pairedComparison.denominatorsAgree -and [int]$pairedComparison.candidateOnly -eq 1) `
        "A genuine pairing over identical inventory keys was rejected."

    # -----------------------------------------------------------------------
    # 11. Sealing, tamper detection, domain separation, and byte-exact replay.
    # -----------------------------------------------------------------------
    $ephemeralKey = New-EvalTestKey
    $sealDir = Join-Path $sandbox "sealed"
    New-Item -ItemType Directory -Force -Path $sealDir | Out-Null
    $runPath = Save-ReviewerEvalArtifact -Manifest $runs[0] -Directory $sealDir -BaseName "run" -MasterKey $ephemeralKey -Domain run
    $adjudicationPath = Save-ReviewerEvalArtifact -Manifest $adjudication -Directory $sealDir -BaseName "adj" -MasterKey $ephemeralKey -Domain adjudication
    $null = Read-ReviewerEvalArtifact -Path $runPath -MasterKey $ephemeralKey -Domain run
    $null = Read-ReviewerEvalArtifact -Path $adjudicationPath -MasterKey $ephemeralKey -Domain adjudication
    Assert-EvalThrows -Action { Read-ReviewerEvalArtifact -Path $runPath -MasterKey $ephemeralKey -Domain adjudication } `
        -Message "A run artifact was readable under the adjudication domain." -ExpectedMessageLike "signature verification failed"
    Assert-EvalThrows -Action { Read-ReviewerEvalArtifact -Path $adjudicationPath -MasterKey $ephemeralKey -Domain corpus } `
        -Message "An adjudication artifact was readable under the corpus domain." -ExpectedMessageLike "signature verification failed"
    Assert-EvalThrows -Action { Read-ReviewerEvalArtifact -Path $runPath -MasterKey (New-EvalTestKey) -Domain run } `
        -Message "A run artifact verified under a different signing key." -ExpectedMessageLike "signature verification failed"
    $envelope = Get-Content -LiteralPath $runPath -Raw | ConvertFrom-Json -Depth 8
    $envelope.manifestJson = $envelope.manifestJson.Replace("complete", "degraded")
    Set-Content -LiteralPath $runPath -Value ($envelope | ConvertTo-Json -Depth 8) -Encoding utf8NoBOM
    Assert-EvalThrows -Action { Read-ReviewerEvalArtifact -Path $runPath -MasterKey $ephemeralKey -Domain run } `
        -Message "An edited run artifact still verified." -ExpectedMessageLike "signature verification failed"
    Assert-EvalThrows -Action { Save-ReviewerEvalArtifact -Manifest $adjudication -Directory $sealDir -BaseName "wrong" -MasterKey $ephemeralKey -Domain run } `
        -Message "An adjudication manifest was sealed into the run domain." -ExpectedMessageLike "kind does not match"

    # An ISO-8601 timestamp must never reach the sealer, because a round trip
    # through ConvertFrom-Json would make the artifact impossible to re-verify.
    $isoManifest = Copy-EvalObject -Value $runs[0]
    $isoManifest.derivation | Add-Member -NotePropertyName "issuedAt" -NotePropertyValue ([DateTime]::UtcNow) -Force
    Assert-EvalThrows -Action { Save-ReviewerEvalArtifact -Manifest $isoManifest -Directory $sealDir -BaseName "iso" -MasterKey $ephemeralKey -Domain run } `
        -Message "A DateTime value was sealed into an evaluation artifact." -ExpectedMessageLike "integer epoch seconds"

    # Canonicalization round trip: every shipped/derived artifact must survive
    # ConvertFrom-Json and re-canonicalize to identical bytes.
    foreach ($pair in @(@("corpus", $corpus), @("run", $runs[0]), @("adjudication", $adjudication))) {
        $first = ConvertTo-ReviewerVerificationCanonicalJson -Value $pair[1]
        $second = ConvertTo-ReviewerVerificationCanonicalJson -Value ($first | ConvertFrom-Json -Depth 64)
        Assert-Eval ($first -ceq $second) "A $($pair[0]) artifact does not re-canonicalize to identical bytes after a JSON round trip."
    }
    # Derived hashes are stable across a round trip too.
    Assert-Eval ((Get-ReviewerEvalRecordHash -Example $corpus.examples[0]) -ceq
        (Get-ReviewerEvalRecordHash -Example ((ConvertTo-ReviewerVerificationCanonicalJson -Value $corpus.examples[0]) | ConvertFrom-Json -Depth 64))) `
        "A record hash changed after a JSON round trip."

    # -----------------------------------------------------------------------
    # 12. The report: schema, replay equality, and non-promotability.
    # -----------------------------------------------------------------------
    $reportPath = Join-Path $sandbox "report.json"
    $sealedRunPaths = @()
    foreach ($run in $runs) {
        $sealedRunPath = Join-Path $sandbox ("run-" + [string]$run.arm + ".json")
        & $harnessToolPath -SealOnly -SealKind run -SealInput (
            $(
                $plainPath = Join-Path $sandbox ("plain-" + [string]$run.arm + ".json")
                Set-Content -LiteralPath $plainPath -Value ($run | ConvertTo-Json -Depth 32) -Encoding utf8NoBOM
                $plainPath
            )
        ) -OutputPath $sealedRunPath -StateDir $stateDir | Out-Null
        $sealedRunPaths += $sealedRunPath
    }
    $plainAdjudicationPath = Join-Path $sandbox "plain-adjudication.json"
    Set-Content -LiteralPath $plainAdjudicationPath -Value ($adjudication | ConvertTo-Json -Depth 32) -Encoding utf8NoBOM
    $sealedAdjudicationPath = Join-Path $sandbox "adjudication.json"
    & $harnessToolPath -SealOnly -SealKind adjudication -SealInput $plainAdjudicationPath `
        -OutputPath $sealedAdjudicationPath -StateDir $stateDir | Out-Null

    & $harnessToolPath -CorpusFile $corpusPath -RunFiles $sealedRunPaths -AdjudicationFile $sealedAdjudicationPath `
        -StateDir $stateDir -OutputPath $reportPath -ReportVersion 1 -GeneratedAtEpochSeconds 1767484800 | Out-Null
    Assert-Eval (Test-Path -LiteralPath $reportPath) "The harness did not produce a sealed report."
    $report = Read-ReviewerEvalArtifact -Path $reportPath -MasterKey $masterKey -Domain report
    Assert-Eval ([bool](Test-Json -Json ($report | ConvertTo-Json -Depth 32) -SchemaFile $reportSchemaPath)) `
        "The sealed report does not satisfy report.schema.json."
    Assert-Eval (-not [bool]$report.promotable -and ([string]$report.authorizes -ceq "none")) `
        "The report does not declare itself non-promotable."
    Assert-Eval ([bool]$report.transcriptionInput.nonQualifying) "A seed-corpus report did not mark its transcription block non-qualifying."
    Assert-Eval ([bool]$report.transcriptionInput.comment.nonQualifying -and [bool]$report.transcriptionInput.approval.nonQualifying) `
        "A seed-corpus report did not mark BOTH transcription sections non-qualifying."
    Assert-Eval (@($report.transcriptionInput.comment.scopes).Count -eq 0) `
        "A failing comment requirement still emitted transcribable scopes."
    Assert-Eval ([int]$report.transcriptionInput.approval.sampleCount -eq 0 -and
        [int]$report.transcriptionInput.approval.wouldApproveCount -eq 0 -and
        $null -eq $report.transcriptionInput.approval.falseApprovalUpperBound95) `
        "A failing approval requirement still emitted transcribable approval material."
    Assert-Eval (-not [bool]$report.qualification.anyQualified) "The end-to-end seed report qualified something."
    Assert-Eval (@($report.corpusPopulation.deficits) -contains "seedRecordsPresent") "The report omitted the seed-record deficit."
    Assert-Eval ([string]$report.toolBinding.evaluationToolSha256 -match '^[0-9a-f]{64}$') "The composite evaluation tool hash is missing."
    Assert-Eval (@($report.arms).Count -eq 6) "The report does not carry both partitions for all three arms."

    # An operator-supplied expectation turns recorded provenance into a live
    # cross-check; a mismatch must refuse rather than score a stale pair.
    Assert-EvalThrows -Action {
        & $harnessToolPath -CorpusFile $corpusPath -RunFiles $sealedRunPaths `
            -AdjudicationFile $sealedAdjudicationPath -StateDir $stateDir `
            -OutputPath (Join-Path $sandbox "report-stale-binding.json") -ReportVersion 1 `
            -GeneratedAtEpochSeconds 1767484800 -ReviewerScriptSha256 ("3" * 64)
    } -Message "The harness scored runs bound to a reviewer build the operator did not expect." `
        -ExpectedMessageLike "reviewerScriptSha256 does not match"

    # Mixed results: each transcription section must follow ITS OWN
    # requirement, because layer 6 reads the sections independently against its
    # own weaker floors and never consults a rollup.
    $armMetricsForReport = @(
        (Get-ReviewerEvalArmMetrics -Run $verifiedRun -Corpus $corpus -Verdicts $verdicts -Partition holdout),
        (Get-ReviewerEvalArmMetrics -Run $baselineRun -Corpus $corpus -Verdicts $verdicts -Partition holdout)
    )
    function New-MixedReport {
        param([bool]$CommentOk, [bool]$ApprovalOk, [switch]$Seeded)
        $mixedQualification = [pscustomobject][ordered]@{
            boundMethod      = [string]$effectivePolicy.boundMethod
            alphaNumerator   = [int]$effectivePolicy.alphaNumerator
            alphaDenominator = [int]$effectivePolicy.alphaDenominator
            scopeCount       = [int]$effectivePolicy.scopeCount
            globalVetoes     = @()
            requirements     = @(
                [pscustomobject][ordered]@{
                    id = "unattendedImportantCriticalComments"; ok = $CommentOk
                    reasonCodes = @(); observed = [pscustomobject]@{ eligibleHoldoutFindings = 800 }
                },
                [pscustomobject][ordered]@{
                    id = "unattendedSuggestionComments"; ok = $false
                    reasonCodes = @("suggestionsPreviewOnly"); observed = [pscustomobject]@{ separatelyQualified = $false }
                },
                [pscustomobject][ordered]@{
                    id = "approvalVote"; ok = $ApprovalOk
                    reasonCodes = @(); observed = [pscustomobject][ordered]@{
                        labeledDecisions = 700; wouldApproveCount = 600; falseApprovalCount = 0
                        falseApprovalUpperBound95 = 0.005; voteAccuracy = 1.0
                    }
                }
            )
            anyQualified     = ($CommentOk -or $ApprovalOk)
            allQualified     = ($CommentOk -and $ApprovalOk)
        }
        $mixedIntegrity = Copy-EvalObject -Value ([pscustomobject]@{ Ok = $true; ReasonCodes = @(); Population = $integrity.Population })
        if (-not $Seeded) { $mixedIntegrity.Population.seedExamples = 0 }
        return New-ReviewerEvalReport -ReportVersion 1 -GeneratedAtEpochSeconds 1767484800 `
            -ToolBinding $report.toolBinding -Corpus $corpus -CorpusIntegrity $mixedIntegrity `
            -RunSetConsistency $runSet -AdjudicationResult $adjudicationResult `
            -ArmMetrics @($armMetricsForReport) -Comparison $comparison -Qualification $mixedQualification `
            -HoldoutScopes @($holdoutScopes) -EffectivePolicy $effectivePolicy
    }
    $commentOnly = New-MixedReport -CommentOk $true -ApprovalOk $false
    Assert-Eval (-not [bool]$commentOnly.transcriptionInput.comment.nonQualifying) `
        "A passing comment requirement was marked non-qualifying."
    Assert-Eval ([bool]$commentOnly.transcriptionInput.approval.nonQualifying) `
        "A FAILING approval requirement was not marked non-qualifying while comments passed."
    Assert-Eval ([bool]$commentOnly.transcriptionInput.nonQualifying) `
        "The transcription rollup claimed qualification while one section had failed."
    Assert-Eval (@($commentOnly.transcriptionInput.comment.scopes).Count -gt 0) `
        "A passing comment requirement emitted no transcribable scopes."
    Assert-Eval ([int]$commentOnly.transcriptionInput.approval.sampleCount -eq 0 -and
        [int]$commentOnly.transcriptionInput.approval.wouldApproveCount -eq 0 -and
        $null -eq $commentOnly.transcriptionInput.approval.falseApprovalUpperBound95 -and
        $null -eq $commentOnly.transcriptionInput.approval.recall) `
        "A failing approval section still emitted material a human could transcribe into a qualification."

    $approvalOnly = New-MixedReport -CommentOk $false -ApprovalOk $true
    Assert-Eval ([bool]$approvalOnly.transcriptionInput.comment.nonQualifying) `
        "A FAILING comment requirement was not marked non-qualifying while approval passed."
    Assert-Eval (-not [bool]$approvalOnly.transcriptionInput.approval.nonQualifying) `
        "A passing approval requirement was marked non-qualifying."
    Assert-Eval (@($approvalOnly.transcriptionInput.comment.scopes).Count -eq 0) `
        "A failing comment requirement still emitted scopes a human could transcribe into a qualification."
    Assert-Eval ([int]$approvalOnly.transcriptionInput.approval.sampleCount -eq 700) `
        "A passing approval requirement emitted no transcribable sample count."
    Assert-Eval ([bool]$approvalOnly.transcriptionInput.nonQualifying) `
        "The transcription rollup claimed qualification while the comment section had failed."

    $bothPass = New-MixedReport -CommentOk $true -ApprovalOk $true
    Assert-Eval (-not [bool]$bothPass.transcriptionInput.nonQualifying) `
        "A report whose sections both qualify still reported a non-qualifying rollup."
    $bothPassSeeded = New-MixedReport -CommentOk $true -ApprovalOk $true -Seeded
    Assert-Eval ([bool]$bothPassSeeded.transcriptionInput.comment.nonQualifying -and
        [bool]$bothPassSeeded.transcriptionInput.approval.nonQualifying -and
        @($bothPassSeeded.transcriptionInput.comment.scopes).Count -eq 0 -and
        [int]$bothPassSeeded.transcriptionInput.approval.sampleCount -eq 0) `
        "A seed record did not withhold transcription material from otherwise-passing sections."
    foreach ($mixed in @($commentOnly, $approvalOnly, $bothPass, $bothPassSeeded)) {
        Assert-Eval ([bool](Test-Json -Json ($mixed | ConvertTo-Json -Depth 32) -SchemaFile $reportSchemaPath)) `
            "A mixed-result report does not satisfy report.schema.json."
        Assert-Eval ((-not [bool]$mixed.promotable) -and ([string]$mixed.authorizes -ceq "none")) `
            "A mixed-result report did not declare itself non-promotable."
    }

    # Byte-exact replay from identical inputs and an identical timestamp.
    $replayPath = Join-Path $sandbox "report-replay.json"
    & $harnessToolPath -CorpusFile $corpusPath -RunFiles $sealedRunPaths -AdjudicationFile $sealedAdjudicationPath `
        -StateDir $stateDir -OutputPath $replayPath -ReportVersion 1 -GeneratedAtEpochSeconds 1767484800 | Out-Null
    $replay = Read-ReviewerEvalArtifact -Path $replayPath -MasterKey $masterKey -Domain report
    Assert-Eval ((ConvertTo-ReviewerVerificationCanonicalJson -Value $report) -ceq
        (ConvertTo-ReviewerVerificationCanonicalJson -Value $replay)) `
        "Replaying the same inputs did not reproduce a byte-identical report."
    Assert-Eval ([string]$report.derivationSha256 -ceq [string]$replay.derivationSha256) "The derivation hash is not stable across replay."

    # The composite tool binding must change when ANY scoring input changes.
    $baseBinding = Get-ReviewerEvalToolBinding -FileHashes @{
        evaluationLibrarySha256 = "0" * 64; harnessToolSha256 = "1" * 64; importToolSha256 = "2" * 64
        evaluationPolicySha256 = "3" * 64; corpusSchemaSha256 = "4" * 64; runSchemaSha256 = "5" * 64
        adjudicationSchemaSha256 = "6" * 64; reportSchemaSha256 = "7" * 64
    }
    $shiftedBinding = Get-ReviewerEvalToolBinding -FileHashes @{
        evaluationLibrarySha256 = "8" * 64; harnessToolSha256 = "1" * 64; importToolSha256 = "2" * 64
        evaluationPolicySha256 = "3" * 64; corpusSchemaSha256 = "4" * 64; runSchemaSha256 = "5" * 64
        adjudicationSchemaSha256 = "6" * 64; reportSchemaSha256 = "7" * 64
    }
    Assert-Eval ([string]$baseBinding.evaluationToolSha256 -cne [string]$shiftedBinding.evaluationToolSha256) `
        "The composite evaluation tool hash does not change when the scoring library changes."

    # A run set missing an arm must reach the operator as a stated refusal, not
    # as a raw index exception from a guard that never runs.
    Assert-EvalThrows -Action {
        & $harnessToolPath -CorpusFile $corpusPath -RunFiles @($sealedRunPaths[0], $sealedRunPaths[1]) `
            -AdjudicationFile $sealedAdjudicationPath -StateDir $stateDir `
            -OutputPath (Join-Path $sandbox "report-missing-arm.json") -ReportVersion 1 `
            -GeneratedAtEpochSeconds 1767484800
    } -Message "The harness accepted a two-arm run set, or failed for an unexplained reason." `
        -ExpectedMessageLike "exactly three sealed run artifacts"
    Assert-EvalThrows -Action {
        & $harnessToolPath -CorpusFile $corpusPath `
            -RunFiles @($sealedRunPaths[0], $sealedRunPaths[0], $sealedRunPaths[1]) `
            -AdjudicationFile $sealedAdjudicationPath -StateDir $stateDir `
            -OutputPath (Join-Path $sandbox "report-duplicate-arm.json") -ReportVersion 1 `
            -GeneratedAtEpochSeconds 1767484800
    } -Message "The harness scored a run set with a duplicated arm and no verified arm." `
        -ExpectedMessageLike "does not contain both a baseline and a verified arm"

    # Non-promotion, stated against the real gate and verification readers.
    foreach ($kind in @("reviewer-evaluation-corpus", "reviewer-evaluation-run", "reviewer-evaluation-adjudication", "reviewer-evaluation-report")) {
        Assert-Eval (-not (Test-ReviewerGateArtifactKind -Kind $kind -ExpectedKind "reviewer-gate-decision")) `
            "'$kind' satisfied the gate decision kind check."
        Assert-Eval (-not (Test-ReviewerGateArtifactKind -Kind $kind -ExpectedKind "reviewer-gate-qualification")) `
            "'$kind' satisfied the gate qualification kind check."
        Assert-Eval (-not (Test-ReviewerEvalPromotable -Kind $kind)) "'$kind' reported itself as promotable."
    }
    Assert-EvalThrows -Action { Read-ReviewerGateDecision -Path $reportPath -MasterKey $masterKey } `
        -Message "An evaluation report was readable as a sealed gate decision." -ExpectedMessageLike "signature verification failed"
    Assert-EvalThrows -Action { Read-ReviewerVerificationInput -Path $reportPath -MasterKey $masterKey } `
        -Message "An evaluation report was readable as a verification input preview." -ExpectedMessageLike "signature verification failed"
    Assert-EvalThrows -Action { Read-ReviewerVerificationPreview -Path $reportPath -MasterKey $masterKey } `
        -Message "An evaluation report was readable as a verification decision preview." -ExpectedMessageLike "signature verification failed"
    # Read-ReviewerGateQualification deliberately returns a reason code rather
    # than throwing, so assert its documented shape instead of a throw.
    $asQualification = Read-ReviewerGateQualification -Path $reportPath -MasterKey $masterKey
    Assert-Eval ((-not [bool]$asQualification.Ok) -and (@($asQualification.ReasonCodes) -ccontains "qualificationSignatureInvalid")) `
        "An evaluation report was accepted as a gate qualification."
    # The wrapper's own promotion guards must still be present verbatim.
    $wrapperText = [IO.File]::ReadAllText($wrapperPath)
    $rawGuard = "carries a 'kind' property and is not a raw delivery manifest"
    $verifiedGuard = "is not a reviewer-gate-decision artifact"
    Assert-Eval ($wrapperText.IndexOf($rawGuard, [StringComparison]::Ordinal) -ge 0) `
        "The raw promotion path no longer rejects an artifact carrying a 'kind' property."
    Assert-Eval ($wrapperText.IndexOf($verifiedGuard, [StringComparison]::Ordinal) -ge 0) `
        "The verified promotion path no longer requires the exact gate-decision kind."

    # -----------------------------------------------------------------------
    # 12b. Paired-recall set shape, through the REAL metrics pipeline.
    #
    # MatchedCorrectnessKeys must be an ordinal HashSet at 0, 1 and 2+ matches.
    # A PowerShell-unrolled set would arrive as $null (crashing .Contains before
    # any fail-closed guard), as a bare [string] at one match (whose .Contains
    # is SUBSTRING matching, so "X|i10" would "contain" "X|i1" and silently
    # understate the regression), and only as a collection at two or more.
    # -----------------------------------------------------------------------
    $pairManifest = [ordered]@{
        name                 = "reviewer-eval-pairing"
        corpusVersion        = 1
        corpusPin            = [ordered]@{ repositoryId = "example-org/example-pairing"; commitSha = "3" * 40 }
        holdoutPercent       = 20
        partitionSalt        = "pair-partition-salt-0001"
        adjudicationSalt     = "pair-adjudication-salt-0001"
        frozenAtEpochSeconds = 1767225600
        records              = @(
            [ordered]@{
                status      = "seed"
                stratum     = "csharp"
                provenance  = [ordered]@{
                    provider = "GitHub"; repositoryId = "example-org/example-pairing"; prId = "201"
                    sourceCommitSha = "e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1"
                    targetCommitSha = "f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1"
                    changeSetSha256 = "a201a201a201a201a201a201a201a201a201a201a201a201a201a201a201a201"
                    changedFilePathsSha256 = "b201b201b201b201b201b201b201b201b201b201b201b201b201b201b201b201"
                    sourceRef = "refs/heads/pair/one"; importedAtEpochSeconds = 1767225600
                }
                # i1 and i10 collide as prefixes; that is the whole point.
                inventory   = @(
                    [ordered]@{ issueId = "i1"; issueClass = "nullReference"; severity = "important"; convention = $false; correctness = $true; path = "src/One.cs" },
                    [ordered]@{ issueId = "i10"; issueClass = "nullReference"; severity = "important"; convention = $false; correctness = $true; path = "src/One.cs" }
                )
                labels      = @(
                    [ordered]@{ labelerId = "pair-a"; labelerKind = "human"; blind = $true; labeledAtEpochSeconds = 1767225601; issueIds = @("i1", "i10"); decision = "reject" },
                    [ordered]@{ labelerId = "pair-b"; labelerKind = "human"; blind = $true; labeledAtEpochSeconds = 1767225602; issueIds = @("i1", "i10"); decision = "reject" }
                )
                adjudication = $null
            },
            [ordered]@{
                status      = "seed"
                stratum     = "tests"
                provenance  = [ordered]@{
                    provider = "GitHub"; repositoryId = "example-org/example-pairing"; prId = "202"
                    sourceCommitSha = "e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2e2"
                    targetCommitSha = "f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2"
                    changeSetSha256 = "a202a202a202a202a202a202a202a202a202a202a202a202a202a202a202a202"
                    changedFilePathsSha256 = "b202b202b202b202b202b202b202b202b202b202b202b202b202b202b202b202"
                    sourceRef = "refs/heads/pair/two"; importedAtEpochSeconds = 1767225600
                }
                inventory   = @(
                    [ordered]@{ issueId = "i1"; issueClass = "testCoverage"; severity = "important"; convention = $false; correctness = $true; path = "test/Two.cs" }
                )
                labels      = @(
                    [ordered]@{ labelerId = "pair-a"; labelerKind = "human"; blind = $true; labeledAtEpochSeconds = 1767225603; issueIds = @("i1"); decision = "reject" },
                    [ordered]@{ labelerId = "pair-b"; labelerKind = "human"; blind = $true; labeledAtEpochSeconds = 1767225604; issueIds = @("i1"); decision = "reject" }
                )
                adjudication = $null
            }
        )
    }
    $pairManifestPath = Join-Path $sandbox "pair-import.json"
    Set-Content -LiteralPath $pairManifestPath -Value ($pairManifest | ConvertTo-Json -Depth 32) -Encoding utf8NoBOM
    $pairCorpusPath = Join-Path $sandbox "pair-corpus.json"
    & $importToolPath -ImportManifest $pairManifestPath -OutputPath $pairCorpusPath `
        -StateDir $stateDir -AllowSyntheticSeed | Out-Null
    $pairCorpus = Read-ReviewerEvalArtifact -Path $pairCorpusPath -MasterKey $masterKey -Domain corpus
    $pairIntegrity = Test-ReviewerEvalCorpusIntegrity -Corpus $pairCorpus
    Assert-Eval ([bool]$pairIntegrity.Ok) "The pairing corpus failed integrity: $($pairIntegrity.ReasonCodes -join ', ')."
    $pairSha = [string]$pairCorpus.freeze.corpusSha256
    $pairExampleByPr = @{}
    foreach ($example in @($pairCorpus.examples)) { $pairExampleByPr[[string]$example.provenance.prId] = $example }

    function New-PairArmRun {
        <# One arm over the pairing corpus. Each requested "prId|issueId" gets a
           claim that the adjudication will resolve as a true positive matching
           exactly that issue; every example also gets one claim resolved as a
           false positive, so an arm with zero matches still produces resolved
           claims. Claim text is arm-distinct so each arm gets its own blind
           key and therefore its own verdict. #>
        param([Parameter(Mandatory)][string]$Arm, [AllowEmptyCollection()][string[]]$MatchedKeys = @())
        $matchedSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@($MatchedKeys), [StringComparer]::Ordinal)
        $results = [System.Collections.Generic.List[object]]::new()
        $perExample = [System.Collections.Generic.List[object]]::new()
        $script:pairVerdictPlan = $(if ($null -eq $script:pairVerdictPlan) { @{} } else { $script:pairVerdictPlan })
        foreach ($prId in @("201", "202")) {
            $example = $pairExampleByPr[$prId]
            $claims = [System.Collections.Generic.List[object]]::new()
            $index = 0
            $issueIds = @(@($example.inventory) | ForEach-Object { [string]$_.issueId })
            foreach ($issueId in $issueIds) {
                if (-not $matchedSet.Contains("$prId|$issueId")) { continue }
                $text = "$Arm finds $issueId in PR $prId"
                $contentSha = Get-ReviewerEvalClaimContentSha256 -Text $text
                $key = Get-ReviewerEvalBlindClaimKey -CorpusSha256 $pairSha -ExampleId ([string]$example.exampleId) `
                    -Path "src/One.cs" -Severity "important" -ClaimContentSha256 $contentSha
                $script:pairVerdictPlan[$key] = [pscustomobject]@{ Verdict = "truePositive"; Matched = @($issueId) }
                [void]$claims.Add([pscustomobject][ordered]@{
                        claimId = "$Arm-$prId-$index"; blindClaimKey = $key; claimContentSha256 = $contentSha
                        issueClass = "nullReference"; severity = "important"; path = "src/One.cs"
                        pack = "(generalist)"; clusterId = ""; text = $text
                    })
                $index++
            }
            $noiseText = "$Arm notes something unsupported in PR $prId"
            $noiseSha = Get-ReviewerEvalClaimContentSha256 -Text $noiseText
            $noiseKey = Get-ReviewerEvalBlindClaimKey -CorpusSha256 $pairSha -ExampleId ([string]$example.exampleId) `
                -Path "src/One.cs" -Severity "important" -ClaimContentSha256 $noiseSha
            $script:pairVerdictPlan[$noiseKey] = [pscustomobject]@{ Verdict = "falsePositive"; Matched = @() }
            [void]$claims.Add([pscustomobject][ordered]@{
                    claimId = "$Arm-$prId-noise"; blindClaimKey = $noiseKey; claimContentSha256 = $noiseSha
                    issueClass = "readability"; severity = "important"; path = "src/One.cs"
                    pack = "(generalist)"; clusterId = ""; text = $noiseText
                })
            [void]$results.Add([pscustomobject][ordered]@{
                    exampleId = [string]$example.exampleId
                    sourceCommitSha = [string]$example.provenance.sourceCommitSha
                    targetCommitSha = [string]$example.provenance.targetCommitSha
                    changeSetSha256 = [string]$example.provenance.changeSetSha256
                    commitResolution = "resolved"; status = "complete"; vote = "none"
                    claims = @($claims.ToArray())
                })
            [void]$perExample.Add([pscustomobject][ordered]@{
                    exampleId = [string]$example.exampleId; latencyMs = 1000
                    inputTokens = 100; outputTokens = 10; costMicroUsd = 450
                })
        }
        return [pscustomobject][ordered]@{
            kind = "reviewer-evaluation-run"; artifactVersion = 1; schemaVersion = 1
            runId = "pair-$Arm"; arm = $Arm
            derivation = [pscustomobject][ordered]@{
                executedAtEpochSeconds = 1767312000
                corpus = [pscustomobject][ordered]@{
                    name = [string]$pairCorpus.name; corpusVersion = [int]$pairCorpus.corpusVersion
                    corpusSha256 = $pairSha; exampleCount = @($pairCorpus.examples).Count
                }
                binding = $binding
                models = [pscustomobject][ordered]@{
                    generalists = @($arms.models.generalists | ForEach-Object { [string]$_ })
                    conventionSpecialist = [string]$arms.models.conventionSpecialist
                    conventionVerifier = [string]$arms.models.conventionVerifier
                }
                results = @($results.ToArray())
            }
            observations = [pscustomobject][ordered]@{
                pricingTableVersion = [string]$arms.pricingTableVersion
                rates = @(@($arms.rates) | ForEach-Object {
                        [pscustomobject][ordered]@{
                            model = [string]$_.model
                            inputMicroUsdPerKiloToken = [int]$_.inputMicroUsdPerKiloToken
                            outputMicroUsdPerKiloToken = [int]$_.outputMicroUsdPerKiloToken
                        }
                    })
                perExample = @($perExample.ToArray())
            }
        }
    }

    function Get-PairComparison {
        param([AllowEmptyCollection()][string[]]$BaselineMatched = @(), [AllowEmptyCollection()][string[]]$CandidateMatched = @())
        $script:pairVerdictPlan = @{}
        $pairRuns = @(
            (New-PairArmRun -Arm "generalistOnly" -MatchedKeys $BaselineMatched),
            (New-PairArmRun -Arm "multiPassDiscovery" -MatchedKeys $CandidateMatched),
            (New-PairArmRun -Arm "verified" -MatchedKeys $CandidateMatched)
        )
        $pairRunSet = Test-ReviewerEvalRunSetConsistent -Runs $pairRuns -Corpus $pairCorpus
        if (-not $pairRunSet.Ok) { throw "Pairing run set inconsistent: $($pairRunSet.ReasonCodes -join ', ')." }
        $verdicts = [System.Collections.Generic.List[object]]::new()
        $claimByKey = @{}
        foreach ($run in $pairRuns) {
            foreach ($result in @($run.derivation.results)) {
                foreach ($claim in @($result.claims)) { $claimByKey[[string]$claim.blindClaimKey] = $claim }
            }
        }
        foreach ($key in (Get-ReviewerEvalOrdinalSorted -Values @($claimByKey.Keys))) {
            $plan = $script:pairVerdictPlan[$key]
            [void]$verdicts.Add([pscustomobject][ordered]@{
                    blindClaimKey = $key
                    presentedSha256 = Get-ReviewerEvalPresentedSha256 -Claim $claimByKey[$key]
                    labels = @(
                        [pscustomobject][ordered]@{ labelerId = "pair-v-a"; labelerKind = "human"; verdict = [string]$plan.Verdict; matchedIssueIds = @($plan.Matched); verdictAtEpochSeconds = 1767398400 },
                        [pscustomobject][ordered]@{ labelerId = "pair-v-b"; labelerKind = "human"; verdict = [string]$plan.Verdict; matchedIssueIds = @($plan.Matched); verdictAtEpochSeconds = 1767398401 }
                    )
                    adjudication = $null
                })
        }
        $pairAdjudication = [pscustomobject][ordered]@{
            kind = "reviewer-evaluation-adjudication"; artifactVersion = 1; schemaVersion = 1
            adjudicationVersion = 1; corpusSha256 = $pairSha
            presentationOrderSha256 = Get-ReviewerEvalPresentationOrderSha256 `
                -AdjudicationSalt ([string]$pairCorpus.partitionPolicy.adjudicationSalt) `
                -BlindClaimKeys @($claimByKey.Keys)
            verdicts = @($verdicts.ToArray())
        }
        $pairAdjudicationResult = Test-ReviewerEvalAdjudication -Adjudication $pairAdjudication `
            -RunSet $pairRunSet -Corpus $pairCorpus -AdjudicationSalt ([string]$pairCorpus.partitionPolicy.adjudicationSalt)
        if (-not $pairAdjudicationResult.Ok) { throw "Pairing adjudication rejected: $($pairAdjudicationResult.ReasonCodes -join ', ')." }
        $baselineMetrics = Get-ReviewerEvalArmMetrics -Run $pairRunSet.ByArm["generalistOnly"] -Corpus $pairCorpus `
            -Verdicts $pairAdjudicationResult.Verdicts -Partition all
        $candidateMetrics = Get-ReviewerEvalArmMetrics -Run $pairRunSet.ByArm["verified"] -Corpus $pairCorpus `
            -Verdicts $pairAdjudicationResult.Verdicts -Partition all
        return [pscustomobject]@{
            Baseline   = $baselineMetrics
            Candidate  = $candidateMetrics
            Comparison = Get-ReviewerEvalRecallComparison -BaselineMetrics $baselineMetrics `
                -CandidateMetrics $candidateMetrics -EffectivePolicy $effectivePolicy
        }
    }

    # Zero matches on BOTH arms: must not throw, and must report no discordance.
    $pairZero = Get-PairComparison -BaselineMatched @() -CandidateMatched @()
    foreach ($side in @(@("baseline", $pairZero.Baseline), @("candidate", $pairZero.Candidate))) {
        Assert-Eval ($side[1].MatchedCorrectnessKeys -is [System.Collections.Generic.HashSet[string]]) `
            "A zero-match $($side[0]) arm did not carry an ordinal HashSet of matched keys."
        Assert-Eval ($side[1].CorrectnessKeys -is [System.Collections.Generic.HashSet[string]]) `
            "A zero-match $($side[0]) arm did not carry an ordinal HashSet of inventory keys."
    }
    Assert-Eval ([int]$pairZero.Comparison.inventoryCount -eq 3 -and [bool]$pairZero.Comparison.denominatorsAgree) `
        "The pairing corpus did not present three shared correctness items."
    Assert-Eval ([int]$pairZero.Comparison.baselineOnly -eq 0 -and [int]$pairZero.Comparison.candidateOnly -eq 0 -and
        [int]$pairZero.Comparison.discordantPairs -eq 0) `
        "A zero-match comparison reported discordant pairs."
    Assert-Eval ([double]$pairZero.Comparison.regressionPointEstimate -eq 0.0 -and
        [double]$pairZero.Comparison.regressionUpperBound95 -eq 0.0 -and [bool]$pairZero.Comparison.withinCeiling) `
        "A zero-match comparison did not report an exactly-zero regression."

    # One match on the baseline only.
    $pairOne = Get-PairComparison -BaselineMatched @("201|i1") -CandidateMatched @()
    Assert-Eval ($pairOne.Baseline.MatchedCorrectnessKeys -is [System.Collections.Generic.HashSet[string]] -and
        $pairOne.Baseline.MatchedCorrectnessKeys.Count -eq 1) `
        "A single-match arm did not carry a one-element ordinal HashSet."
    Assert-Eval ([int]$pairOne.Comparison.baselineOnly -eq 1 -and [int]$pairOne.Comparison.candidateOnly -eq 0 -and
        [int]$pairOne.Comparison.discordantPairs -eq 1) `
        "A one-versus-zero match comparison miscounted discordant pairs."
    Assert-Eval ([double]$pairOne.Comparison.regressionPointEstimate -gt 0.33 -and
        [double]$pairOne.Comparison.regressionPointEstimate -lt 0.34) `
        "A one-of-three recall regression was not reported as 1/3."

    # THE regression case: one match on each side, prefix-colliding. Substring
    # semantics would report baselineOnly = 0 here and understate the loss.
    $pairCollision = Get-PairComparison -BaselineMatched @("201|i1") -CandidateMatched @("201|i10")
    Assert-Eval ([int]$pairCollision.Comparison.baselineOnly -eq 1 -and [int]$pairCollision.Comparison.candidateOnly -eq 1 -and
        [int]$pairCollision.Comparison.discordantPairs -eq 2) `
        "Prefix-colliding single matches (i1 vs i10) were compared with substring semantics."
    Assert-Eval ([double]$pairCollision.Comparison.regressionPointEstimate -eq 0.0) `
        "A one-for-one swap did not net to a zero point regression."

    # Two or more matches, candidate strictly ahead.
    $pairTwo = Get-PairComparison -BaselineMatched @("201|i1", "201|i10") -CandidateMatched @("201|i1", "201|i10", "202|i1")
    Assert-Eval ($pairTwo.Candidate.MatchedCorrectnessKeys.Count -eq 3 -and $pairTwo.Baseline.MatchedCorrectnessKeys.Count -eq 2) `
        "A multi-match comparison lost members from its matched sets."
    Assert-Eval ([int]$pairTwo.Comparison.baselineOnly -eq 0 -and [int]$pairTwo.Comparison.candidateOnly -eq 1 -and
        [double]$pairTwo.Comparison.regressionPointEstimate -lt 0.0) `
        "A recall improvement was not reported as a negative point regression."
    # Three inventory items cannot certify anything: the exact discordant-pair
    # bound refuses at that denominator even though the point estimate is an
    # improvement. That conservatism is the intended behavior, not a defect.
    Assert-Eval (-not [bool]$pairTwo.Comparison.withinCeiling) `
        "A three-item denominator certified a regression ceiling it cannot support."

    # The zero-match case must reach a fail-closed REPORT, not an exception.
    $pairQualification = Test-ReviewerEvalRolloutQualification -EffectivePolicy $effectivePolicy `
        -CorpusIntegrity $pairIntegrity -RunSetConsistency $runSet -AdjudicationResult $adjudicationResult `
        -CandidateHoldoutMetrics $pairZero.Candidate -Comparison $pairZero.Comparison -HoldoutScopes @() `
        -DegradedExamples 0 -UnknownExamples 0 -MissingExamples 0
    Assert-Eval (-not [bool]$pairQualification.anyQualified) `
        "A zero-match, seed-corpus qualification did not fail closed."
    Assert-Eval ($pairQualification.globalVetoes -ccontains "seedCorpus") `
        "A zero-match qualification lost its seed veto."

    # -----------------------------------------------------------------------
    # 13. Structural invariants: the agent never loads this layer, the library
    #     is pure, and no transcendental math reaches a metric.
    # -----------------------------------------------------------------------
    $libraryText = [IO.File]::ReadAllText($libraryPath)
    foreach ($forbidden in @(('sh' + 'ell('), ('web_' + 'search'), ('web_' + 'fetch'), "Invoke-AgentMcpTool", "Open-AgentMcpSession", "Invoke-AgentGitHubApi")) {
        Assert-Eval ($libraryText.IndexOf($forbidden, [StringComparison]::OrdinalIgnoreCase) -lt 0) `
            "Evaluation.ps1 references '$forbidden'; it must stay a pure, offline library."
    }
    foreach ($transcendental in @("[Math]::Pow", "[Math]::Log", "[Math]::Exp", "[Math]::Sqrt")) {
        Assert-Eval ($libraryText.IndexOf($transcendental, [StringComparison]::OrdinalIgnoreCase) -lt 0) `
            "Evaluation.ps1 uses $transcendental; transcendental results are not bit-identical across platforms, and a bound that differs in its last bit between runners breaks both replay and a threshold comparison."
    }
    Assert-Eval ($wrapperText.IndexOf("Evaluation.ps1", [StringComparison]::OrdinalIgnoreCase) -lt 0) `
        "Start-ReviewerAgent.ps1 references Evaluation.ps1; the agent process must never load the evaluation layer."
    Assert-Eval ($wrapperText.IndexOf("ReviewerEval", [StringComparison]::Ordinal) -lt 0) `
        "Start-ReviewerAgent.ps1 references an evaluation function; the agent process must never reach this layer."
    Assert-Eval ($libraryText.IndexOf("artifact-signing.key", [StringComparison]::OrdinalIgnoreCase) -ge 0) `
        "Evaluation.ps1 no longer refuses the reviewer's own signing key by name."
    Assert-EvalThrows -Action { Get-ReviewerEvalSigningKey -KeyPath (Join-Path $sandbox "artifact-signing.key") } `
        -Message "The evaluation harness opened the reviewer's delivery signing key." -ExpectedMessageLike "refuses to open"
    # Nothing in this layer may name a delivery authorization type.
    foreach ($authorizationToken in @("VerifiedMultiPass", "Add-ReviewerThread", "Set-ReviewerVote")) {
        Assert-Eval ($libraryText.IndexOf($authorizationToken, [StringComparison]::Ordinal) -lt 0) `
            "Evaluation.ps1 references '$authorizationToken'; evaluation must not touch delivery authorization or write paths."
    }
}
finally {
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($failures.Count -eq 0) {
    Write-Host "PASS - $checks evaluation-harness checks." -ForegroundColor Green
    exit 0
}
Write-Host "FAIL - $($failures.Count) of $checks evaluation-harness checks failed:" -ForegroundColor Red
$failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
exit 1
