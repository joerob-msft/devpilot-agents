#requires -Version 7.0

<#
    Layer 7: the evaluation harness library over a FROZEN, labeled,
    commit-pinned corpus.

    This library measures. It never delivers. It has no MCP session, no
    provider transport, no network, no model, no write to any pull request,
    and no code path that mints, edits, or promotes a delivery authorization.
    It is deliberately NOT dot-sourced by Start-ReviewerAgent.ps1: the agent
    process never loads it, so nothing measured here can reach a write or
    vote path even by accident. Only tools/ loads it.

    Load order: this file assumes CrossVerification.ps1 has ALREADY been
    dot-sourced into the same scope, and reuses its canonicalizer, SHA-256
    helper, HMAC signer/verifier, and generic value accessor rather than
    re-implementing them - the same discipline DeliveryGates.ps1 follows.
    Evaluation artifacts are sealed under their OWN HMAC domains
    ("devpilot.reviewer.evaluation.<domain>.v1"), separate from every
    verification and gate domain and from the raw delivery master key, so an
    evaluation artifact can never be read back as - or promoted as - a
    delivery, verification, or gate artifact, and vice versa.

    Four artifact kinds, deliberately separate:

      reviewer-evaluation-corpus        frozen ground truth. Structurally
                                        forbidden from carrying ANY model
                                        output: no claims, no arms, no model
                                        identities, no run references.
      reviewer-evaluation-run           one arm's outputs over the corpus.
                                        Carries no labels and no verdicts.
      reviewer-evaluation-adjudication  blind claim verdicts, keyed by a
                                        content-derived blindClaimKey and
                                        carrying no arm/model identity.
      reviewer-evaluation-report        computed metrics, rollout
                                        qualification, and machine-readable
                                        deficit state. Non-promotable.

    No ISO-8601 timestamp string appears anywhere inside an evaluation
    artifact. ConvertFrom-Json rehydrates an ISO-8601-shaped string as a
    [DateTime], and the verification canonicalizer throws on [DateTime] - so
    a corpus that stored ISO text could be signed once and then never
    re-verified, because recomputing a record hash after a round trip would
    crash. Every instant here is an integer "epoch seconds" field, and
    Test-ReviewerEvalNoRehydratedDateTime rejects any artifact that
    reintroduces one.

    Every number a decision depends on is computed with EXACT integer
    arithmetic (System.Numerics.BigInteger). No transcendental function
    (Pow/Log/Exp/Sqrt) appears on any metric or interval path, because .NET
    does not guarantee bit-identical transcendental results across platforms
    and runtime versions, and a bound that differed in its last bit between a
    Windows and a Linux runner would break both replay equality and a
    threshold comparison at the boundary.
#>

Set-StrictMode -Version Latest

foreach ($requiredVerificationFunction in @(
        "ConvertTo-ReviewerVerificationCanonicalJson", "Get-ReviewerVerificationSha256",
        "Get-ReviewerVerificationObjectSha256", "Get-ReviewerVerificationSignature",
        "Test-ReviewerVerificationSignature", "Get-ReviewerVerificationValue"
    )) {
    if (-not (Get-Command $requiredVerificationFunction -ErrorAction SilentlyContinue)) {
        throw ("Evaluation.ps1 requires CrossVerification.ps1 to already be dot-sourced into this scope " +
            "(missing '$requiredVerificationFunction'). Dot-source CrossVerification.ps1 first.")
    }
}

$script:ReviewerEvalUtf8 = [System.Text.UTF8Encoding]::new($false, $true)

$script:ReviewerEvalArtifactVersion = 1
$script:ReviewerEvalSchemaVersion = 1

$script:ReviewerEvalCorpusKind = "reviewer-evaluation-corpus"
$script:ReviewerEvalRunKind = "reviewer-evaluation-run"
$script:ReviewerEvalAdjudicationKind = "reviewer-evaluation-adjudication"
$script:ReviewerEvalReportKind = "reviewer-evaluation-report"
$script:ReviewerEvalKinds = @(
    $script:ReviewerEvalCorpusKind, $script:ReviewerEvalRunKind,
    $script:ReviewerEvalAdjudicationKind, $script:ReviewerEvalReportKind
)

# The three arms compared on IDENTICAL pinned commits.
$script:ReviewerEvalArms = @("generalistOnly", "multiPassDiscovery", "verified")
$script:ReviewerEvalBaselineArm = "generalistOnly"
$script:ReviewerEvalCandidateArm = "verified"

$script:ReviewerEvalStrata = @(
    "csharp", "tests", "deployment", "settings", "security",
    "generatedCode", "resources", "serviceProviders", "docs"
)
$script:ReviewerEvalSeverities = @("critical", "important", "suggestion")
# Ordinal rank, highest first, for a deterministic "most severe matched item".
$script:ReviewerEvalSeverityRank = @{ critical = 3; important = 2; suggestion = 1 }
$script:ReviewerEvalUnattendedCommentSeverities = @("critical", "important")
$script:ReviewerEvalPartitions = @("calibration", "holdout")
$script:ReviewerEvalExampleStatuses = @("qualifying", "seed")
$script:ReviewerEvalResultStatuses = @("complete", "degraded", "unknown", "missing")
$script:ReviewerEvalCommitResolutions = @("resolved", "unresolved")
$script:ReviewerEvalVotes = @("approve", "none", "abstain")
$script:ReviewerEvalDecisions = @("approve", "reject", "abstain")
$script:ReviewerEvalVerdicts = @("truePositive", "falsePositive", "abstain")
$script:ReviewerEvalResolutions = @("concordant", "adjudicated", "disputed", "abstained")
$script:ReviewerEvalCorrectionReasons = @(
    "labelError", "provenanceError", "inventoryOmission", "duplicateWithdrawal", "strataCorrection"
)
$script:ReviewerEvalLabelerKinds = @("human")

# ---------------------------------------------------------------------------
# Code-defined ceilings and floors. An evaluation policy may only NARROW a cap
# and only RAISE a floor - the same per-key direction table DeliveryGates.ps1
# uses. No policy value can make qualification easier than these constants.
# ---------------------------------------------------------------------------

$script:ReviewerEvalMinExamples = 100
$script:ReviewerEvalMinCalibrationExamples = 80
$script:ReviewerEvalMinHoldoutExamples = 20
$script:ReviewerEvalMinPerStratumExamples = 1
$script:ReviewerEvalMinEligibleHoldoutFindings = 200
$script:ReviewerEvalMinCommentPrecision = 0.98
$script:ReviewerEvalMinCommentPrecisionLowerBound = 0.95
$script:ReviewerEvalMinCriticalAdjudicatedClaims = 30
$script:ReviewerEvalMinApprovalDecisions = 300
$script:ReviewerEvalMinWouldApproveDecisions = 30
$script:ReviewerEvalMaxRecallRegression = 0.02
$script:ReviewerEvalMinAdjudicationCoverage = 0.98
$script:ReviewerEvalMinLabelAgreementKappa = 0.60
$script:ReviewerEvalMaxCriticalFalsePositiveRate = 0.01
$script:ReviewerEvalMaxFalseApprovalRate = 0.01
$script:ReviewerEvalMaxArtifactBytes = 8388608
# Exact BigInteger tail evaluation costs O(n) big-integer multiplications on
# numbers of O(n log b) bits. It is exact and reproducible everywhere, which is
# the point, but it is not free. Above this ceiling the harness refuses to
# certify rather than falling back to an approximation whose last bit differs
# between runners. Policy may narrow this; nothing widens it.
$script:ReviewerEvalMaxExactTrials = 5000
# Reported bounds are searched on a fixed decimal grid, so an emitted bound is
# always an integer over a constant denominator rather than whatever a floating
# iterative solver happened to converge to on this host. 1e-4 is deliberate:
# every threshold this layer compares against (0.98, 0.95, 0.02, 0.01) lands
# EXACTLY on this grid, so no threshold is ever perturbed by quantization, and
# the exact tail arithmetic costs bits proportional to n*log(denominator) - a
# finer grid would buy invisible reporting precision at a real cost in time.
$script:ReviewerEvalBoundGridDenominator = 10000
# 95% one-sided, expressed as an exact rational so the tail comparison stays in
# integer arithmetic: alpha = alphaNumerator / alphaDenominator.
$script:ReviewerEvalAlphaNumerator = 1
$script:ReviewerEvalAlphaDenominator = 20

$script:ReviewerEvalCapKeys = @(
    , @("maxExactTrials", 1, [int64]::MaxValue, $script:ReviewerEvalMaxExactTrials)
    , @("maxCriticalFalsePositiveRate", 0.0, 1.0, $script:ReviewerEvalMaxCriticalFalsePositiveRate)
    , @("maxFalseApprovalRate", 0.0, 1.0, $script:ReviewerEvalMaxFalseApprovalRate)
    , @("maxRecallRegression", 0.0, 1.0, $script:ReviewerEvalMaxRecallRegression)
)
$script:ReviewerEvalFloorKeys = @(
    , @("minExamples", 0, [int64]::MaxValue, $script:ReviewerEvalMinExamples)
    , @("minCalibrationExamples", 0, [int64]::MaxValue, $script:ReviewerEvalMinCalibrationExamples)
    , @("minHoldoutExamples", 0, [int64]::MaxValue, $script:ReviewerEvalMinHoldoutExamples)
    , @("minPerStratumExamples", 0, [int64]::MaxValue, $script:ReviewerEvalMinPerStratumExamples)
    , @("minEligibleHoldoutFindings", 0, [int64]::MaxValue, $script:ReviewerEvalMinEligibleHoldoutFindings)
    , @("minCriticalAdjudicatedClaims", 0, [int64]::MaxValue, $script:ReviewerEvalMinCriticalAdjudicatedClaims)
    , @("minApprovalDecisions", 0, [int64]::MaxValue, $script:ReviewerEvalMinApprovalDecisions)
    , @("minWouldApproveDecisions", 0, [int64]::MaxValue, $script:ReviewerEvalMinWouldApproveDecisions)
    , @("minCommentPrecision", 0.0, 1.0, $script:ReviewerEvalMinCommentPrecision)
    , @("minCommentPrecisionLowerBound95", 0.0, 1.0, $script:ReviewerEvalMinCommentPrecisionLowerBound)
    , @("minAdjudicationCoverage", 0.0, 1.0, $script:ReviewerEvalMinAdjudicationCoverage)
    , @("minLabelAgreementKappa", 0.0, 1.0, $script:ReviewerEvalMinLabelAgreementKappa)
)

# Closed reason-code vocabulary. Anything outside it is rewritten, never passed
# through into a sealed artifact.
$script:ReviewerEvalReasonCodes = @(
    "ok",
    # Corpus integrity / freeze
    "corpusKindInvalid", "corpusVersionUnsupported", "corpusSchemaInvalid",
    "corpusRecordHashMismatch", "corpusFreezeHashMismatch", "corpusPartitionMismatch",
    "corpusDuplicateExample", "corpusPartitionLeakage", "corpusGroupLeakage",
    "corpusStratumUnknown", "corpusGroundTruthMismatch", "corpusLabelerNotHuman",
    "corpusLabelerCountBelowFloor", "corpusAdjudicatorNotIndependent",
    "corpusAdjudicationMissing", "corpusModelIdentityAsLabeler", "corpusForbiddenField",
    "corpusIsoTimestampRejected", "corpusSaltMissing", "corpusPolicyOverridesFreeze",
    "corpusCorrectionOutOfOrder", "corpusCorrectionAuthorInvalid", "postRunCorrection",
    "seedCorpus", "zeroQualifyingExamples",
    # Population deficits
    "belowMinimumExamples", "belowMinimumCalibrationExamples", "belowMinimumHoldoutExamples",
    "stratumUnpopulated", "seedRecordsPresent",
    # Run set
    "runKindInvalid", "runArmUnknown", "runArmDuplicated", "runArmMissing",
    "runCorpusMismatch", "runBindingMismatch", "runExampleSetMismatch",
    "runCommitMismatch", "runStaleCommit", "runCommitUnresolved", "runDuplicateExample",
    "runBlindClaimKeyMismatch", "runModelIdentityMissing", "runObservationsMissing",
    "evidenceIncomplete", "evidenceDegraded", "evidenceUnknown", "evidenceMissing",
    # Adjudication
    "adjudicationKindInvalid", "adjudicationCorpusMismatch", "adjudicationForbiddenField",
    "adjudicationPresentationOrderMismatch", "adjudicationPresentedHashMismatch",
    "adjudicationLabelCountBelowFloor", "adjudicationLabelerNotHuman",
    "adjudicationAdjudicatorNotIndependent", "adjudicationModelIdentityAsLabeler",
    "adjudicationUnknownClaim", "adjudicationDuplicateClaim", "adjudicationMissingClaim",
    "adjudicationCoverageBelowFloor", "labelAgreementBelowFloor", "labelAgreementUndefined",
    "adjudicationMatchedIssueUnknown",
    # Metrics / statistics
    "denominatorZero", "sampleCountBelowFloor", "precisionBelowFloor",
    "precisionLowerBoundBelowFloor", "criticalStratumEmpty", "criticalFalsePositivesPresent",
    "criticalFalsePositiveBoundAboveCeiling", "recallRegressionAboveCeiling",
    "recallDenominatorZero", "approvalStratumEmpty", "falseApprovalsPresent",
    "falseApprovalBoundAboveCeiling", "sampleCountAboveExactCeiling",
    "boundUndefined", "suggestionsPreviewOnly", "suggestionScopeNotDeclared",
    "commentScopeNotDeclared",
    # Structural
    "policyInvalid", "policyVersionMismatch", "policyWidensCeiling",
    "artifactSignatureInvalid", "artifactKindRejected", "artifactVersionUnsupported",
    "artifactTooLarge", "artifactDomainMismatch", "nonPromotableArtifact",
    "unrecognizedReasonRewritten"
)

# Keys that must never appear ANYWHERE inside a corpus artifact. Ground truth
# that quotes model output is not ground truth; it is the model's opinion with
# extra steps, and requirement 2 forbids exactly that.
$script:ReviewerEvalCorpusForbiddenKeys = @(
    "arm", "arms", "model", "models", "modelId", "modelIdentity", "generalistModels",
    "runId", "runs", "claim", "claims", "claimId", "blindClaimKey", "verdict", "verdicts",
    "pack", "packs", "ruleSourceId", "clusterId", "latencyMs", "inputTokens",
    "outputTokens", "costMicroUsd", "verificationOutcome", "passIndex", "precision",
    "recall", "matchedIssueIds"
)

# Keys that must never appear ANYWHERE inside an adjudication artifact. Any one
# of them tells an adjudicator which arm produced the claim in front of them,
# which is precisely what "blind" has to exclude.
$script:ReviewerEvalAdjudicationForbiddenKeys = @(
    "arm", "arms", "model", "models", "modelId", "modelIdentity", "generalistModels",
    "runId", "runs", "pack", "packs", "ruleSourceId", "clusterId", "passIndex",
    "latencyMs", "inputTokens", "outputTokens", "costMicroUsd", "verificationOutcome",
    "partition", "stratum", "convention", "issueClass"
)

# The ONLY claim fields an adjudicator is ever shown. Everything else -
# including the convention flag and the issue class, which only the
# specialist-bearing arms populate distinctively - stays in the run manifest.
$script:ReviewerEvalPresentedClaimKeys = @(
    "blindClaimKey", "claimContentSha256", "path", "severity", "text"
)

function ConvertTo-ReviewerEvalReasonCode {
    param([AllowEmptyString()][string]$Reason = "")
    if ($script:ReviewerEvalReasonCodes -ccontains $Reason) { return $Reason }
    return "unrecognizedReasonRewritten"
}

function Get-ReviewerEvalUniqueReasonCodes {
    param([string[]]$Reasons = @())
    $ordered = [System.Collections.Generic.List[string]]::new()
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($reason in @($Reasons)) {
        $safe = ConvertTo-ReviewerEvalReasonCode -Reason ([string]$reason)
        if ($set.Add($safe)) { [void]$ordered.Add($safe) }
    }
    # Emitted as elements, never as one wrapped array: an @() call site around
    # a comma-wrapped return collapses the whole list into a single element.
    return $ordered.ToArray()
}

function Test-ReviewerEvalExactKeys {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string[]]$Allowed,
        [string[]]$Required = $Allowed
    )
    if ($Object -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    $names = @($Object.PSObject.Properties.Name)
    if (@($names | Where-Object { $Allowed -cnotcontains $_ }).Count -gt 0) { return $false }
    if (@($Required | Where-Object { $names -cnotcontains $_ }).Count -gt 0) { return $false }
    return $true
}

function Get-ReviewerEvalOrdinalSorted {
    <# PowerShell's Sort-Object is culture-aware and unstable. Anything whose
       order reaches a hash is ordinal-sorted explicitly here, or a Windows
       runner and a Linux runner would produce different corpus hashes. #>
    param([AllowEmptyCollection()][string[]]$Values = @())
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($value in @($Values)) { [void]$list.Add([string]$value) }
    $list.Sort([StringComparer]::Ordinal)
    return $list.ToArray()
}

# ---------------------------------------------------------------------------
# Structural guards. All three return a bool or a reason list rather than
# throwing on operator data: a malformed corpus is an operator error that must
# close qualification with a code, not crash the harness mid-run.
# ---------------------------------------------------------------------------

function Test-ReviewerEvalNoRehydratedDateTime {
    <# Walks a parsed artifact and reports whether ConvertFrom-Json rehydrated
       any value as a [DateTime]. That happens for ISO-8601-shaped strings, and
       the verification canonicalizer throws on [DateTime] - so an artifact
       that carries one can be signed once and then never re-verified. #>
    param([AllowNull()]$Value, [int]$Depth = 0)
    if ($Depth -gt 32) { return $false }
    if ($null -eq $Value) { return $true }
    if ($Value -is [DateTime] -or $Value -is [DateTimeOffset]) { return $false }
    if ($Value -is [string] -or $Value -is [bool] -or $Value -is [ValueType]) { return $true }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            if (-not (Test-ReviewerEvalNoRehydratedDateTime -Value $Value[$key] -Depth ($Depth + 1))) { return $false }
        }
        return $true
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        foreach ($property in $Value.PSObject.Properties) {
            if (-not (Test-ReviewerEvalNoRehydratedDateTime -Value $property.Value -Depth ($Depth + 1))) { return $false }
        }
        return $true
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($item in $Value) {
            if (-not (Test-ReviewerEvalNoRehydratedDateTime -Value $item -Depth ($Depth + 1))) { return $false }
        }
        return $true
    }
    return $true
}

function Get-ReviewerEvalPresentKeys {
    <# Every object key present anywhere in a parsed artifact, so a forbidden
       field cannot hide inside a nested object an exact-key check never
       reaches. #>
    param([AllowNull()]$Value, [int]$Depth = 0)
    $found = [System.Collections.Generic.List[string]]::new()
    if ($Depth -gt 32 -or $null -eq $Value) { return $found.ToArray() }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            [void]$found.Add([string]$key)
            foreach ($nested in @(Get-ReviewerEvalPresentKeys -Value $Value[$key] -Depth ($Depth + 1))) { [void]$found.Add($nested) }
        }
        return $found.ToArray()
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        foreach ($property in $Value.PSObject.Properties) {
            [void]$found.Add([string]$property.Name)
            foreach ($nested in @(Get-ReviewerEvalPresentKeys -Value $property.Value -Depth ($Depth + 1))) { [void]$found.Add($nested) }
        }
        return $found.ToArray()
    }
    if ($Value -isnot [string] -and $Value -is [System.Collections.IEnumerable]) {
        foreach ($item in $Value) {
            foreach ($nested in @(Get-ReviewerEvalPresentKeys -Value $item -Depth ($Depth + 1))) { [void]$found.Add($nested) }
        }
    }
    return $found.ToArray()
}

function Get-ReviewerEvalForbiddenKeyHits {
    param(
        [Parameter(Mandatory)][AllowNull()]$Value,
        [Parameter(Mandatory)][string[]]$Forbidden
    )
    $present = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($key in @(Get-ReviewerEvalPresentKeys -Value $Value)) { [void]$present.Add($key) }
    $hits = [System.Collections.Generic.List[string]]::new()
    foreach ($key in @($Forbidden)) { if ($present.Contains($key)) { [void]$hits.Add($key) } }
    return @(Get-ReviewerEvalOrdinalSorted -Values $hits.ToArray())
}

# ---------------------------------------------------------------------------
# Domain-separated sealing. Four domains, none of which can be confused with a
# verification domain ("...verification.input/preview.v1"), a gate domain
# ("...gate.decision/qualification.v1"), or the raw delivery master key.
# ---------------------------------------------------------------------------

function Get-ReviewerEvalDomainKey {
    param(
        [Parameter(Mandatory)][byte[]]$MasterKey,
        [Parameter(Mandatory)][ValidateSet("corpus", "run", "adjudication", "report")][string]$Domain
    )
    $label = "devpilot.reviewer.evaluation.$Domain.v1"
    $hmac = [Security.Cryptography.HMACSHA256]::new($MasterKey)
    try { return , $hmac.ComputeHash($script:ReviewerEvalUtf8.GetBytes($label)) }
    finally { $hmac.Dispose() }
}

function Get-ReviewerEvalKindForDomain {
    param([Parameter(Mandatory)][ValidateSet("corpus", "run", "adjudication", "report")][string]$Domain)
    switch ($Domain) {
        "corpus" { return $script:ReviewerEvalCorpusKind }
        "run" { return $script:ReviewerEvalRunKind }
        "adjudication" { return $script:ReviewerEvalAdjudicationKind }
        default { return $script:ReviewerEvalReportKind }
    }
}

function Get-ReviewerEvalDomainSha256 {
    <# sha256(canonical({ domain = <label>, value = <object> })). Domain
       separation on a HASH, not just on the HMAC: two different structures
       that happen to canonicalize identically still hash differently when
       they are used for different purposes. #>
    param(
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][AllowNull()]$Value
    )
    $wrapped = [pscustomobject][ordered]@{
        domain = "devpilot.reviewer.evaluation.$Domain.v1"
        value  = $Value
    }
    return Get-ReviewerVerificationObjectSha256 -Value $wrapped
}

function Save-ReviewerEvalArtifact {
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$BaseName,
        [Parameter(Mandatory)][byte[]]$MasterKey,
        [Parameter(Mandatory)][ValidateSet("corpus", "run", "adjudication", "report")][string]$Domain,
        [ValidateRange(1024, [int]::MaxValue)][int]$MaxArtifactBytes = $script:ReviewerEvalMaxArtifactBytes
    )
    if ($BaseName -notmatch '^[A-Za-z0-9._-]+$') { throw "Evaluation artifact base name is unsafe." }
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        throw "Evaluation artifact directory '$Directory' does not exist."
    }
    $expectedKind = Get-ReviewerEvalKindForDomain -Domain $Domain
    if ([string](Get-ReviewerVerificationValue $Manifest "kind" "") -cne $expectedKind) {
        throw "Evaluation artifact kind does not match the '$Domain' domain."
    }
    if (-not (Test-ReviewerEvalNoRehydratedDateTime -Value $Manifest)) {
        throw "Evaluation artifacts store instants as integer epoch seconds; a DateTime value reached the sealer."
    }
    $manifestJson = ConvertTo-ReviewerVerificationCanonicalJson -Value $Manifest
    $effectiveMax = [Math]::Min($MaxArtifactBytes, $script:ReviewerEvalMaxArtifactBytes)
    if ($script:ReviewerEvalUtf8.GetByteCount($manifestJson) -gt $effectiveMax) {
        throw "Evaluation artifact exceeded the effective $effectiveMax-byte cap."
    }
    $key = Get-ReviewerEvalDomainKey -MasterKey $MasterKey -Domain $Domain
    $envelope = [ordered]@{
        manifestJson = $manifestJson
        signatureAlg = "HMACSHA256"
        signature    = Get-ReviewerVerificationSignature -Json $manifestJson -Key $key
    }
    $path = Join-Path $Directory ($BaseName + ".json")
    $nonce = [Guid]::NewGuid().ToString("N")
    $tempPath = "$path.$nonce.tmp"
    try {
        [IO.File]::WriteAllText($tempPath, ($envelope | ConvertTo-Json -Depth 4), $script:ReviewerEvalUtf8)
        Move-Item -LiteralPath $tempPath -Destination $path -Force
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
    }
    return $path
}

function Read-ReviewerEvalArtifact {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][byte[]]$MasterKey,
        [Parameter(Mandatory)][ValidateSet("corpus", "run", "adjudication", "report")][string]$Domain,
        [ValidateRange(1024, [int]::MaxValue)][int]$MaxArtifactBytes = $script:ReviewerEvalMaxArtifactBytes
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Evaluation artifact '$Path' does not exist." }
    $effectiveMax = [Math]::Min($MaxArtifactBytes, $script:ReviewerEvalMaxArtifactBytes)
    if ((Get-Item -LiteralPath $Path).Length -gt $effectiveMax) {
        throw "Evaluation artifact '$Path' exceeds the effective $effectiveMax-byte cap."
    }
    $envelope = [IO.File]::ReadAllText($Path, $script:ReviewerEvalUtf8) | ConvertFrom-Json -Depth 8
    $manifestJson = [string](Get-ReviewerVerificationValue $envelope "manifestJson" "")
    $signature = [string](Get-ReviewerVerificationValue $envelope "signature" "")
    if ([string](Get-ReviewerVerificationValue $envelope "signatureAlg" "") -cne "HMACSHA256") {
        throw "Evaluation artifact signature algorithm is invalid."
    }
    $key = Get-ReviewerEvalDomainKey -MasterKey $MasterKey -Domain $Domain
    if (-not $manifestJson -or
        -not (Test-ReviewerVerificationSignature -Json $manifestJson -Key $key -Signature $signature)) {
        throw "Evaluation artifact signature verification failed."
    }
    $manifest = $manifestJson | ConvertFrom-Json -Depth 64
    $expectedKind = Get-ReviewerEvalKindForDomain -Domain $Domain
    if ([string](Get-ReviewerVerificationValue $manifest "kind" "") -cne $expectedKind -or
        [int](Get-ReviewerVerificationValue $manifest "artifactVersion" 0) -ne $script:ReviewerEvalArtifactVersion) {
        throw "Evaluation artifact kind or version is invalid."
    }
    if (-not (Test-ReviewerEvalNoRehydratedDateTime -Value $manifest)) {
        throw "Evaluation artifact carries an ISO-8601 timestamp that ConvertFrom-Json rehydrated as a DateTime; instants must be integer epoch seconds."
    }
    return $manifest
}

function Test-ReviewerEvalArtifactKind {
    <# True only for an exact evaluation kind. Used to prove that no evaluation
       artifact can satisfy a gate or delivery kind check, and vice versa. #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Kind,
        [Parameter(Mandatory)][ValidateSet("corpus", "run", "adjudication", "report")][string]$Domain
    )
    return ($Kind -ceq (Get-ReviewerEvalKindForDomain -Domain $Domain))
}

function Test-ReviewerEvalPromotable {
    <# Always false, for every kind, with no parameter that could make it true.
       Every evaluation artifact carries a 'kind', is sealed under an
       evaluation-only HMAC domain, and is therefore rejected by BOTH promotion
       paths already: the raw one refuses any manifest carrying 'kind' and
       cannot even authenticate a derived-domain envelope with the raw master
       key, and the verified one requires kind == reviewer-gate-decision. This
       predicate exists so a test can assert the invariant directly. It is a
       statement about the artifact, not the control itself - the controls are
       the derived key and the kind checks on the promotion side. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Kind)
    $null = $Kind
    return $false
}

# ---------------------------------------------------------------------------
# Exact binomial statistics.
#
# Every qualification decision is a comparison of EXACT integers, never of a
# floating-point bound produced by an iterative solver. The Clopper-Pearson
# one-sided lower bound L(x, n) satisfies P(X >= x | n, L) = alpha, and the
# tail is increasing in p, so:
#
#     L(x, n) >= p0   <=>   P(X >= x | n, p0) <= alpha
#
# With p0 = a/b and alpha = aNum/aDen, that is
#
#     aDen * SUM_{k=x..n} C(n,k) a^k (b-a)^(n-k)  <=  aNum * b^n
#
# which is a BigInteger comparison and therefore bit-identical on every host.
# The symmetric identity gives the one-sided UPPER bound:
#
#     U(x, n) <= p1   <=>   P(X <= x | n, p1) <= alpha
#
# and P(X <= x | n, p) = P(Y >= n-x | n, 1-p), so one tail routine serves both.
#
# Reported bounds (the numbers an operator transcribes) are searched on a fixed
# 1e-4 decimal grid and are therefore integers over a constant denominator.
# The search is deliberately one-sided-conservative: a reported lower bound is
# the largest grid point that still satisfies the exact test (<= the true
# bound), and a reported upper bound is the smallest grid point that fails it
# (>= the true bound). Quantization can never move a reported number across a
# threshold in the permissive direction. Reported bounds are never themselves
# compared against a floor - the exact integer predicates are.
# ---------------------------------------------------------------------------

function Get-ReviewerEvalBinomialTailAtLeast {
    <# SUM_{k=Successes..Trials} C(Trials,k) A^k (B-A)^(Trials-k), exactly.

       Evaluated with an exact term-ratio recurrence

           T_i = T_{i-1} * (n - x - i + 1) * A / ((x + i) * (B - A))

       where every T_i is an integer, so each BigInteger division is exact.
       Each step therefore multiplies and divides a large accumulator by SMALL
       integers instead of multiplying two large numbers, which is the
       difference between a quadratic and a cubic cost in the trial count.

       -CeilingHint lets a caller that only needs a "<= limit" answer stop as
       soon as the partial sum passes the limit. Terms are non-negative, so the
       partial sums are monotone and an early exit can never change the sign of
       that comparison; the returned value is then some number strictly greater
       than the hint rather than the true tail. #>
    param(
        [Parameter(Mandatory)][int]$Trials,
        [Parameter(Mandatory)][int]$Successes,
        [Parameter(Mandatory)][System.Numerics.BigInteger]$A,
        [Parameter(Mandatory)][System.Numerics.BigInteger]$B,
        [AllowNull()][System.Nullable[System.Numerics.BigInteger]]$CeilingHint = $null
    )
    if ($Trials -lt 0) { throw "Binomial tail requires a non-negative trial count." }
    if ([System.Numerics.BigInteger]::Compare($A, [System.Numerics.BigInteger]::Zero) -lt 0 -or
        [System.Numerics.BigInteger]::Compare($A, $B) -gt 0) {
        throw "Binomial tail requires 0 <= A <= B."
    }
    if ($Successes -gt $Trials) { return [System.Numerics.BigInteger]::Zero }
    if ($Successes -le 0) { return [System.Numerics.BigInteger]::Pow($B, $Trials) }
    $c = [System.Numerics.BigInteger]::Subtract($B, $A)
    if ([System.Numerics.BigInteger]::Compare($A, [System.Numerics.BigInteger]::Zero) -eq 0) {
        return [System.Numerics.BigInteger]::Zero
    }
    if ([System.Numerics.BigInteger]::Compare($c, [System.Numerics.BigInteger]::Zero) -eq 0) {
        # p = 1: the whole mass sits at k = n.
        return [System.Numerics.BigInteger]::Pow($B, $Trials)
    }
    $binom = [System.Numerics.BigInteger]::One
    for ($j = 0; $j -lt $Successes; $j++) {
        $binom = [System.Numerics.BigInteger]::Divide(
            [System.Numerics.BigInteger]::Multiply($binom, [System.Numerics.BigInteger]::op_Implicit($Trials - $j)),
            [System.Numerics.BigInteger]::op_Implicit($j + 1))
    }
    $term = [System.Numerics.BigInteger]::Multiply(
        [System.Numerics.BigInteger]::Multiply($binom, [System.Numerics.BigInteger]::Pow($A, $Successes)),
        [System.Numerics.BigInteger]::Pow($c, $Trials - $Successes))
    $sum = $term
    $m = $Trials - $Successes
    for ($i = 1; $i -le $m; $i++) {
        $term = [System.Numerics.BigInteger]::Divide(
            [System.Numerics.BigInteger]::Multiply(
                [System.Numerics.BigInteger]::Multiply($term, [System.Numerics.BigInteger]::op_Implicit($m - $i + 1)), $A),
            [System.Numerics.BigInteger]::Multiply([System.Numerics.BigInteger]::op_Implicit($Successes + $i), $c))
        $sum = [System.Numerics.BigInteger]::Add($sum, $term)
        if ($null -ne $CeilingHint -and [System.Numerics.BigInteger]::Compare($sum, $CeilingHint) -gt 0) { return $sum }
    }
    return $sum
}

function Test-ReviewerEvalLowerBoundAtLeast {
    <# Exact: is the one-sided Clopper-Pearson lower bound on Successes/Trials
       at least ThresholdNumerator/ThresholdDenominator? Trials = 0 is not
       "no evidence against"; it is no evidence at all, and fails closed. #>
    param(
        [Parameter(Mandatory)][int]$Successes,
        [Parameter(Mandatory)][int]$Trials,
        [Parameter(Mandatory)][int]$ThresholdNumerator,
        [Parameter(Mandatory)][int]$ThresholdDenominator,
        [int]$AlphaNumerator = $script:ReviewerEvalAlphaNumerator,
        [int]$AlphaDenominator = $script:ReviewerEvalAlphaDenominator
    )
    if ($Trials -le 0 -or $Successes -lt 0 -or $Successes -gt $Trials) { return $false }
    if ($ThresholdDenominator -le 0 -or $ThresholdNumerator -lt 0 -or
        $ThresholdNumerator -gt $ThresholdDenominator) {
        return $false
    }
    if ($AlphaNumerator -le 0 -or $AlphaDenominator -le 0) { return $false }
    if ($ThresholdNumerator -eq 0) { return $true }
    if ($Successes -eq 0) { return $false }
    $a = [System.Numerics.BigInteger]::op_Implicit($ThresholdNumerator)
    $b = [System.Numerics.BigInteger]::op_Implicit($ThresholdDenominator)
    $right = [System.Numerics.BigInteger]::Multiply(
        [System.Numerics.BigInteger]::op_Implicit($AlphaNumerator),
        [System.Numerics.BigInteger]::Pow($b, $Trials))
    $hint = [System.Numerics.BigInteger]::Divide($right, [System.Numerics.BigInteger]::op_Implicit($AlphaDenominator))
    $tail = Get-ReviewerEvalBinomialTailAtLeast -Trials $Trials -Successes $Successes -A $a -B $b -CeilingHint $hint
    $left = [System.Numerics.BigInteger]::Multiply($tail, [System.Numerics.BigInteger]::op_Implicit($AlphaDenominator))
    return ([System.Numerics.BigInteger]::Compare($left, $right) -le 0)
}

function Test-ReviewerEvalUpperBoundAtMost {
    <# Exact: is the one-sided Clopper-Pearson UPPER bound on Successes/Trials
       at most ThresholdNumerator/ThresholdDenominator? This is what turns
       "we observed zero bad events" into a claim with a denominator. #>
    param(
        [Parameter(Mandatory)][int]$Successes,
        [Parameter(Mandatory)][int]$Trials,
        [Parameter(Mandatory)][int]$ThresholdNumerator,
        [Parameter(Mandatory)][int]$ThresholdDenominator,
        [int]$AlphaNumerator = $script:ReviewerEvalAlphaNumerator,
        [int]$AlphaDenominator = $script:ReviewerEvalAlphaDenominator
    )
    if ($Trials -le 0 -or $Successes -lt 0 -or $Successes -gt $Trials) { return $false }
    if ($ThresholdDenominator -le 0 -or $ThresholdNumerator -lt 0 -or
        $ThresholdNumerator -gt $ThresholdDenominator) {
        return $false
    }
    if ($AlphaNumerator -le 0 -or $AlphaDenominator -le 0) { return $false }
    if ($ThresholdNumerator -eq $ThresholdDenominator) { return $true }
    if ($Successes -eq $Trials) { return $false }
    $a = [System.Numerics.BigInteger]::op_Implicit($ThresholdNumerator)
    $b = [System.Numerics.BigInteger]::op_Implicit($ThresholdDenominator)
    $right = [System.Numerics.BigInteger]::Multiply(
        [System.Numerics.BigInteger]::op_Implicit($AlphaNumerator),
        [System.Numerics.BigInteger]::Pow($b, $Trials))
    $hint = [System.Numerics.BigInteger]::Divide($right, [System.Numerics.BigInteger]::op_Implicit($AlphaDenominator))
    # P(X <= x | n, p) = P(Y >= n-x | n, 1-p), and P(X <= x | n, p) DECREASES
    # in p, so the set of p satisfying P >= alpha is [0, U]. The bound is
    # therefore at most the threshold exactly when the tail at the threshold
    # has already fallen to alpha or below.
    $tail = Get-ReviewerEvalBinomialTailAtLeast -Trials $Trials -Successes ($Trials - $Successes) `
        -A ([System.Numerics.BigInteger]::Subtract($b, $a)) -B $b -CeilingHint $hint
    $left = [System.Numerics.BigInteger]::Multiply($tail, [System.Numerics.BigInteger]::op_Implicit($AlphaDenominator))
    return ([System.Numerics.BigInteger]::Compare($left, $right) -le 0)
}

function Get-ReviewerEvalLowerBoundGrid {
    <# Largest grid point that still passes the exact lower-bound test, i.e. a
       value <= the true Clopper-Pearson lower bound. Null above the exact
       ceiling and for a zero denominator - both of which fail closed. #>
    param(
        [Parameter(Mandatory)][int]$Successes,
        [Parameter(Mandatory)][int]$Trials,
        [int]$AlphaNumerator = $script:ReviewerEvalAlphaNumerator,
        [int]$AlphaDenominator = $script:ReviewerEvalAlphaDenominator,
        [int]$MaxExactTrials = $script:ReviewerEvalMaxExactTrials
    )
    if ($Trials -le 0 -or $Successes -lt 0 -or $Successes -gt $Trials) { return $null }
    if ($Trials -gt [Math]::Min($MaxExactTrials, $script:ReviewerEvalMaxExactTrials)) { return $null }
    if ($Successes -eq 0) { return 0.0 }
    $grid = $script:ReviewerEvalBoundGridDenominator
    # Invariant: $low passes the exact test, $high does not.
    $low = 0
    $high = $grid
    while ($high - $low -gt 1) {
        $mid = [int](($low + $high) / 2)
        $ok = Test-ReviewerEvalLowerBoundAtLeast -Successes $Successes -Trials $Trials `
            -ThresholdNumerator $mid -ThresholdDenominator $grid `
            -AlphaNumerator $AlphaNumerator -AlphaDenominator $AlphaDenominator
        if ($ok) { $low = $mid } else { $high = $mid }
    }
    return ([double]$low / [double]$grid)
}

function Test-ReviewerEvalTailAtMostAtLeastAlpha {
    <# Pure predicate, no "trivially true" shortcuts: is
       P(X <= Successes | Trials, A/B) >= alpha? The shortcuts in
       Test-ReviewerEvalUpperBoundAtMost answer a different question
       ("is the bound at most this threshold", where a threshold of 1 is
       trivially satisfied) and would break a monotone grid search. #>
    param(
        [Parameter(Mandatory)][int]$Successes,
        [Parameter(Mandatory)][int]$Trials,
        [Parameter(Mandatory)][int]$Numerator,
        [Parameter(Mandatory)][int]$Denominator,
        [int]$AlphaNumerator = $script:ReviewerEvalAlphaNumerator,
        [int]$AlphaDenominator = $script:ReviewerEvalAlphaDenominator
    )
    $a = [System.Numerics.BigInteger]::op_Implicit($Numerator)
    $b = [System.Numerics.BigInteger]::op_Implicit($Denominator)
    $right = [System.Numerics.BigInteger]::Multiply(
        [System.Numerics.BigInteger]::op_Implicit($AlphaNumerator),
        [System.Numerics.BigInteger]::Pow($b, $Trials))
    $hint = [System.Numerics.BigInteger]::Divide($right, [System.Numerics.BigInteger]::op_Implicit($AlphaDenominator))
    $tail = Get-ReviewerEvalBinomialTailAtLeast -Trials $Trials -Successes ($Trials - $Successes) `
        -A ([System.Numerics.BigInteger]::Subtract($b, $a)) -B $b -CeilingHint $hint
    $left = [System.Numerics.BigInteger]::Multiply($tail, [System.Numerics.BigInteger]::op_Implicit($AlphaDenominator))
    return ([System.Numerics.BigInteger]::Compare($left, $right) -ge 0)
}

function Get-ReviewerEvalUpperBoundGrid {
    <# Smallest grid point that FAILS the exact tail test, i.e. a value
       >= the true Clopper-Pearson upper bound. #>
    param(
        [Parameter(Mandatory)][int]$Successes,
        [Parameter(Mandatory)][int]$Trials,
        [int]$AlphaNumerator = $script:ReviewerEvalAlphaNumerator,
        [int]$AlphaDenominator = $script:ReviewerEvalAlphaDenominator,
        [int]$MaxExactTrials = $script:ReviewerEvalMaxExactTrials
    )
    if ($Trials -le 0 -or $Successes -lt 0 -or $Successes -gt $Trials) { return $null }
    if ($Trials -gt [Math]::Min($MaxExactTrials, $script:ReviewerEvalMaxExactTrials)) { return $null }
    if ($Successes -eq $Trials) { return 1.0 }
    $grid = $script:ReviewerEvalBoundGridDenominator
    # Invariant: $low satisfies the tail test, $high does not.
    $low = 0
    $high = $grid
    while ($high - $low -gt 1) {
        $mid = [int](($low + $high) / 2)
        $ok = Test-ReviewerEvalTailAtMostAtLeastAlpha -Successes $Successes -Trials $Trials `
            -Numerator $mid -Denominator $grid `
            -AlphaNumerator $AlphaNumerator -AlphaDenominator $AlphaDenominator
        if ($ok) { $low = $mid } else { $high = $mid }
    }
    return ([double]$high / [double]$grid)
}

function ConvertTo-ReviewerEvalGridNumerator {
    <# Turns a policy fraction into an exact grid numerator. A floor rounds UP
       (harder to satisfy), a ceiling rounds DOWN (harder to satisfy). Rounding
       a threshold in the permissive direction is how a "0.98 precision bar"
       silently becomes 0.9799995. #>
    param(
        [Parameter(Mandatory)][double]$Value,
        [Parameter(Mandatory)][ValidateSet("floor", "ceiling")][string]$Role
    )
    if ($Value -lt 0.0) { $Value = 0.0 }
    if ($Value -gt 1.0) { $Value = 1.0 }
    $grid = [double]$script:ReviewerEvalBoundGridDenominator
    if ($Role -ceq "floor") { return [int][Math]::Ceiling($Value * $grid) }
    return [int][Math]::Floor($Value * $grid)
}

function Test-ReviewerEvalPairedRegressionWithinCeiling {
    <# Paired (McNemar-style) exact bound on the recall REGRESSION of a
       candidate arm against the baseline arm over the SAME inventory items.
       Differencing two independent point estimates ignores that both arms ran
       on identical pinned commits, and would let ordinary noise clear a 2 pp
       bar. Conditioning on the discordant pairs is the standard exact
       treatment: with b baseline-only hits and c candidate-only hits,
       regression = (b - c)/N = (2b - nd)/N with nd = b + c, so an upper bound
       U on b/nd gives an upper bound nd(2U - 1)/N on the regression, and the
       requirement nd(2U-1)/N <= r rearranges to the exact rational threshold
       U <= (r*N + nd) / (2*nd). #>
    param(
        [Parameter(Mandatory)][int]$InventoryCount,
        [Parameter(Mandatory)][int]$BaselineOnly,
        [Parameter(Mandatory)][int]$CandidateOnly,
        [Parameter(Mandatory)][int]$MaxRegressionNumerator,
        [int]$AlphaNumerator = $script:ReviewerEvalAlphaNumerator,
        [int]$AlphaDenominator = $script:ReviewerEvalAlphaDenominator,
        [int]$MaxExactTrials = $script:ReviewerEvalMaxExactTrials
    )
    if ($InventoryCount -le 0 -or $BaselineOnly -lt 0 -or $CandidateOnly -lt 0) { return $false }
    $discordant = $BaselineOnly + $CandidateOnly
    if ($discordant -eq 0) { return $true }
    if ($discordant -gt [Math]::Min($MaxExactTrials, $script:ReviewerEvalMaxExactTrials)) { return $false }
    $grid = $script:ReviewerEvalBoundGridDenominator
    # threshold = (r*N + nd) / (2*nd) with r = MaxRegressionNumerator/grid
    $numerator = [int64]$MaxRegressionNumerator * [int64]$InventoryCount + [int64]$grid * [int64]$discordant
    $denominator = 2L * [int64]$grid * [int64]$discordant
    if ($numerator -ge $denominator) { return $true }
    if ($numerator -le 0) { return $false }
    # Both fit in Int32 by construction: nd is bounded by maxExactTrials
    # (<= 5000 by the code ceiling above), so denominator = 2 * grid * nd is at
    # most 2 * 10000 * 5000 = 1e8, and numerator <= r*N + grid*nd stays below
    # 2.1e13 before reduction and below the denominator after it.
    $gcd = [System.Numerics.BigInteger]::GreatestCommonDivisor(
        [System.Numerics.BigInteger]::op_Implicit($numerator),
        [System.Numerics.BigInteger]::op_Implicit($denominator))
    $reducedNumerator = [int64][System.Numerics.BigInteger]::Divide(
        [System.Numerics.BigInteger]::op_Implicit($numerator), $gcd)
    $reducedDenominator = [int64][System.Numerics.BigInteger]::Divide(
        [System.Numerics.BigInteger]::op_Implicit($denominator), $gcd)
    if ($reducedDenominator -gt [int]::MaxValue -or $reducedNumerator -gt [int]::MaxValue) { return $false }
    return Test-ReviewerEvalUpperBoundAtMost -Successes $BaselineOnly -Trials $discordant `
        -ThresholdNumerator ([int]$reducedNumerator) -ThresholdDenominator ([int]$reducedDenominator) `
        -AlphaNumerator $AlphaNumerator -AlphaDenominator $AlphaDenominator
}

function Get-ReviewerEvalRatio {
    <# A ratio, or $null when the denominator is zero. Never 0, never 1, never
       "assume it is fine" - a missing denominator is missing evidence, and
       missing evidence fails closed at the qualification layer. #>
    param([Parameter(Mandatory)][int]$Numerator, [Parameter(Mandatory)][int]$Denominator)
    if ($Denominator -le 0) { return $null }
    return ([double]$Numerator / [double]$Denominator)
}

# ---------------------------------------------------------------------------
# Corpus identity, partitioning, and freeze.
# ---------------------------------------------------------------------------

$script:ReviewerEvalCorpusTopKeys = @(
    "kind", "artifactVersion", "schemaVersion", "corpusVersion", "name", "corpusPin",
    "frozenAtEpochSeconds", "partitionPolicy", "strata", "examples", "corrections", "freeze"
)
# Where the corpus manifest itself is versioned. The layer-6 qualification
# schema wants one repository id and one 40-hex commit, but an evaluation
# corpus spans many pull requests across possibly many repositories - so this
# pins the CORPUS's own home, not any example's commit, and the per-example
# pins stay in each record's provenance where they belong.
$script:ReviewerEvalCorpusPinKeys = @("repositoryId", "commitSha")
$script:ReviewerEvalPartitionPolicyKeys = @("method", "holdoutPercent", "partitionSalt", "adjudicationSalt")
$script:ReviewerEvalExampleKeys = @(
    "exampleId", "status", "stratum", "partition", "groupKey", "provenance",
    "inventory", "labels", "adjudication", "groundTruth", "recordHash"
)
$script:ReviewerEvalProvenanceKeys = @(
    "provider", "repositoryId", "prId", "sourceCommitSha", "targetCommitSha",
    "changeSetSha256", "changedFilePathsSha256", "sourceRef", "importedAtEpochSeconds", "importToolSha256"
)
$script:ReviewerEvalInventoryKeys = @("issueId", "issueClass", "severity", "convention", "correctness", "path")
$script:ReviewerEvalLabelKeys = @("labelerId", "labelerKind", "blind", "labeledAtEpochSeconds", "issueIds", "decision")
$script:ReviewerEvalCorpusAdjudicationKeys = @(
    "adjudicatorId", "adjudicatorKind", "adjudicatedAtEpochSeconds", "issueIds", "decision"
)
$script:ReviewerEvalGroundTruthKeys = @("resolution", "issueIds", "decision")
$script:ReviewerEvalCorrectionKeys = @(
    "sequence", "correctionVersion", "exampleId", "supersedesRecordHash", "reasonCode",
    "authorId", "authorKind", "appliedAtEpochSeconds"
)
$script:ReviewerEvalFreezeKeys = @("partitionAssignmentSha256", "corpusSha256", "exampleCount")
$script:ReviewerEvalPartitionMethod = "stratified-ordinal-group-hash-v1"

function Get-ReviewerEvalExampleId {
    <# Identity is the pinned change, not the record: repository, provider, PR,
       both commits, and the change-set digest. Re-importing the same PR at the
       same commits produces the same id, so a duplicate is detectable. #>
    param([Parameter(Mandatory)]$Provenance)
    $tuple = [pscustomobject][ordered]@{
        provider        = [string](Get-ReviewerVerificationValue $Provenance "provider" "")
        repositoryId    = [string](Get-ReviewerVerificationValue $Provenance "repositoryId" "")
        prId            = [string](Get-ReviewerVerificationValue $Provenance "prId" "")
        sourceCommitSha = ([string](Get-ReviewerVerificationValue $Provenance "sourceCommitSha" "")).ToLowerInvariant()
        targetCommitSha = ([string](Get-ReviewerVerificationValue $Provenance "targetCommitSha" "")).ToLowerInvariant()
        changeSetSha256 = ([string](Get-ReviewerVerificationValue $Provenance "changeSetSha256" "")).ToLowerInvariant()
    }
    return Get-ReviewerEvalDomainSha256 -Domain "example" -Value $tuple
}

function Get-ReviewerEvalGroupKey {
    <# Leakage control. Partitioning by exampleId alone would split a revert, a
       retarget, a rebase, or a re-open of the SAME change across calibration
       and holdout, because each of those has a different PR id and different
       commits. Grouping by (repository, changed-file-path set) keeps near-twins
       on the same side of the split. #>
    param([Parameter(Mandatory)]$Provenance)
    $tuple = [pscustomobject][ordered]@{
        repositoryId           = [string](Get-ReviewerVerificationValue $Provenance "repositoryId" "")
        changedFilePathsSha256 = ([string](Get-ReviewerVerificationValue $Provenance "changedFilePathsSha256" "")).ToLowerInvariant()
    }
    return Get-ReviewerEvalDomainSha256 -Domain "group" -Value $tuple
}

function Get-ReviewerEvalRecordHash {
    param([Parameter(Mandatory)]$Example)
    $copy = [ordered]@{}
    foreach ($name in (Get-ReviewerEvalOrdinalSorted -Values @($Example.PSObject.Properties.Name))) {
        if ($name -ceq "recordHash") { continue }
        $copy[$name] = $Example.PSObject.Properties[$name].Value
    }
    return Get-ReviewerEvalDomainSha256 -Domain "record" -Value ([pscustomobject]$copy)
}

function Get-ReviewerEvalCorpusSha256 {
    <# The freeze digest covers everything an auditor would have to trust:
       not just the records and the partition policy, but the corpus's own
       name, version, pin, stratum vocabulary, and correction log. Leaving the
       pin outside the digest would mean the repository/commit an operator
       eventually transcribes into a gate qualification was never actually
       frozen, and a re-seal under a different pin would leave every existing
       run and adjudication verifying clean. #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [Parameter(Mandatory)][int]$CorpusVersion,
        [Parameter(Mandatory)]$CorpusPin,
        [Parameter(Mandatory)][int64]$FrozenAtEpochSeconds,
        [Parameter(Mandatory)]$PartitionPolicy,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Strata,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Corrections,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RecordHashes
    )
    $value = [pscustomobject][ordered]@{
        name                 = $Name
        corpusVersion        = $CorpusVersion
        corpusPin            = $CorpusPin
        frozenAtEpochSeconds = $FrozenAtEpochSeconds
        partitionPolicy      = $PartitionPolicy
        strata               = @($Strata)
        corrections          = @($Corrections)
        recordHashes         = @(Get-ReviewerEvalOrdinalSorted -Values $RecordHashes)
    }
    return Get-ReviewerEvalDomainSha256 -Domain "corpus" -Value $value
}

function Get-ReviewerEvalPartitionAssignment {
    <# Deterministic, label-blind, stratified, and coverage-guaranteed.

       Uniform hashing over ~100 examples with a 20% holdout leaves several of
       the nine strata empty by construction, and an empty stratum is exactly
       the case requirement 4 says must be handled rather than averaged away.
       So assignment happens per stratum: within a stratum, whole GROUPS are
       ordered by a salted domain hash and the first ceil(pct * groups / 100)
       become holdout. A group's stratum is the stratum of its ordinally
       smallest example, so a group that spans strata still lands whole. #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Examples,
        [Parameter(Mandatory)][string]$PartitionSalt,
        [Parameter(Mandatory)][int]$HoldoutPercent
    )
    if ($HoldoutPercent -lt 0 -or $HoldoutPercent -gt 100) {
        throw "Corpus holdoutPercent must be between 0 and 100."
    }
    $groups = @{}
    foreach ($example in @($Examples)) {
        $exampleId = [string](Get-ReviewerVerificationValue $example "exampleId" "")
        $groupKey = [string](Get-ReviewerVerificationValue $example "groupKey" "")
        $stratum = [string](Get-ReviewerVerificationValue $example "stratum" "")
        if (-not $groups.ContainsKey($groupKey)) {
            $groups[$groupKey] = [pscustomobject]@{
                GroupKey = $groupKey; Stratum = $stratum; MinExampleId = $exampleId
            }
        }
        else {
            $existing = $groups[$groupKey]
            if ([string]::CompareOrdinal($exampleId, $existing.MinExampleId) -lt 0) {
                $existing.MinExampleId = $exampleId
                $existing.Stratum = $stratum
            }
        }
    }
    $assignment = @{}
    $seenStrata = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $orderedPairs = [System.Collections.Generic.List[string]]::new()
    foreach ($stratum in (Get-ReviewerEvalOrdinalSorted -Values @($groups.Values | ForEach-Object { $_.Stratum }))) {
        if (-not $seenStrata.Add($stratum)) { continue }
        $inStratum = @($groups.Values | Where-Object { $_.Stratum -ceq $stratum })
        $sortKeys = @{}
        foreach ($group in $inStratum) {
            $sortKeys[$group.GroupKey] = Get-ReviewerEvalDomainSha256 -Domain "partition" -Value (
                [pscustomobject][ordered]@{ salt = $PartitionSalt; groupKey = $group.GroupKey })
        }
        $orderedGroupKeys = @(Get-ReviewerEvalOrdinalSorted -Values @(
                $inStratum | ForEach-Object { $sortKeys[$_.GroupKey] + "|" + $_.GroupKey }))
        $holdoutCount = [int][Math]::Ceiling(($HoldoutPercent * $orderedGroupKeys.Count) / 100.0)
        # Never let rounding swallow an entire stratum into holdout: with a
        # single group, ceil(20% * 1) = 1 would put 100% of that stratum on the
        # holdout side and leave calibration empty.
        if ($holdoutCount -gt ($orderedGroupKeys.Count - 1)) { $holdoutCount = $orderedGroupKeys.Count - 1 }
        if ($holdoutCount -lt 0) { $holdoutCount = 0 }
        $index = 0
        foreach ($composite in $orderedGroupKeys) {
            $groupKey = $composite.Substring($composite.IndexOf("|") + 1)
            $partition = $(if ($index -lt $holdoutCount) { "holdout" } else { "calibration" })
            $assignment[$groupKey] = $partition
            [void]$orderedPairs.Add($stratum + "|" + $groupKey + "|" + $partition)
            $index++
        }
    }
    $byExample = @{}
    foreach ($example in @($Examples)) {
        $exampleId = [string](Get-ReviewerVerificationValue $example "exampleId" "")
        $groupKey = [string](Get-ReviewerVerificationValue $example "groupKey" "")
        $byExample[$exampleId] = [string]$assignment[$groupKey]
    }
    $orderedArray = @(Get-ReviewerEvalOrdinalSorted -Values $orderedPairs.ToArray())
    return [pscustomobject][ordered]@{
        Assignment        = $byExample
        AssignmentSha256  = Get-ReviewerEvalDomainSha256 -Domain "partitionAssignment" -Value (
            [pscustomobject][ordered]@{ method = $script:ReviewerEvalPartitionMethod; pairs = $orderedArray })
    }
}

function Get-ReviewerEvalGroundTruth {
    <# Deterministic reconciliation of >=2 independent blind labels.

       Concordant labels ARE the ground truth. Discordant labels are resolved
       only by an adjudicator who is not one of the labelers. An unresolved
       disagreement stays 'disputed' and contributes to nothing: it is not
       silently resolved in either direction, and the example is excluded from
       every denominator it would otherwise appear in. #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Labels,
        [AllowNull()]$Adjudication = $null
    )
    $labelerIds = @($Labels | ForEach-Object { [string](Get-ReviewerVerificationValue $_ "labelerId" "") })
    $distinctLabelers = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($id in $labelerIds) { [void]$distinctLabelers.Add($id) }
    $issueSignatures = @($Labels | ForEach-Object {
            ((Get-ReviewerEvalOrdinalSorted -Values @(@(Get-ReviewerVerificationValue $_ "issueIds" @()) |
                        ForEach-Object { [string]$_ })) -join ",") + "#" +
            [string](Get-ReviewerVerificationValue $_ "decision" "")
        })
    $distinctSignatures = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($signature in $issueSignatures) { [void]$distinctSignatures.Add($signature) }

    if ($Labels.Count -lt 2 -or $distinctLabelers.Count -lt 2) {
        return [pscustomobject][ordered]@{
            resolution = "disputed"; issueIds = @(); decision = "abstain"
            ReasonCodes = @("corpusLabelerCountBelowFloor")
        }
    }
    if ($distinctSignatures.Count -eq 1) {
        $first = $Labels[0]
        return [pscustomobject][ordered]@{
            resolution = "concordant"
            issueIds = @(Get-ReviewerEvalOrdinalSorted -Values @(@(Get-ReviewerVerificationValue $first "issueIds" @()) |
                    ForEach-Object { [string]$_ }))
            decision = [string](Get-ReviewerVerificationValue $first "decision" "")
            ReasonCodes = @()
        }
    }
    if ($null -eq $Adjudication) {
        # A genuinely unresolved disagreement is a normal, recordable outcome,
        # not a malformed corpus. It resolves to nothing, contributes to no
        # denominator, and is counted as a disagreement.
        return [pscustomobject][ordered]@{
            resolution = "disputed"; issueIds = @(); decision = "abstain"
            ReasonCodes = @()
        }
    }
    $adjudicatorId = [string](Get-ReviewerVerificationValue $Adjudication "adjudicatorId" "")
    if ($distinctLabelers.Contains($adjudicatorId)) {
        return [pscustomobject][ordered]@{
            resolution = "disputed"; issueIds = @(); decision = "abstain"
            ReasonCodes = @("corpusAdjudicatorNotIndependent")
        }
    }
    return [pscustomobject][ordered]@{
        resolution = "adjudicated"
        issueIds = @(Get-ReviewerEvalOrdinalSorted -Values @(@(Get-ReviewerVerificationValue $Adjudication "issueIds" @()) |
                ForEach-Object { [string]$_ }))
        decision = [string](Get-ReviewerVerificationValue $Adjudication "decision" "")
        ReasonCodes = @()
    }
}

function Test-ReviewerEvalCorpusIntegrity {
    <# Every property the corpus claims about itself, re-derived and compared:
       record hashes, the freeze hash, the stratified partition assignment,
       ground-truth reconciliation, labeler independence and humanity,
       correction ordering, and the absence of any model-output field. Returns
       reason codes; a corpus that fails ANY of them can qualify nothing. #>
    param(
        [Parameter(Mandatory)]$Corpus,
        [AllowEmptyCollection()][string[]]$ModelIdentities = @(),
        [AllowNull()]$EarliestRunSequence = $null
    )
    $reasons = [System.Collections.Generic.List[string]]::new()

    if ([string](Get-ReviewerVerificationValue $Corpus "kind" "") -cne $script:ReviewerEvalCorpusKind) {
        [void]$reasons.Add("corpusKindInvalid")
        return [pscustomobject][ordered]@{ Ok = $false; ReasonCodes = (Get-ReviewerEvalUniqueReasonCodes -Reasons $reasons.ToArray()); Population = $null; Examples = @() }
    }
    if ([int](Get-ReviewerVerificationValue $Corpus "artifactVersion" 0) -ne $script:ReviewerEvalArtifactVersion -or
        [int](Get-ReviewerVerificationValue $Corpus "schemaVersion" 0) -ne $script:ReviewerEvalSchemaVersion -or
        [int](Get-ReviewerVerificationValue $Corpus "corpusVersion" 0) -lt 1) {
        [void]$reasons.Add("corpusVersionUnsupported")
    }
    if (-not (Test-ReviewerEvalExactKeys -Object $Corpus -Allowed $script:ReviewerEvalCorpusTopKeys)) {
        [void]$reasons.Add("corpusSchemaInvalid")
    }
    if (-not (Test-ReviewerEvalNoRehydratedDateTime -Value $Corpus)) { [void]$reasons.Add("corpusIsoTimestampRejected") }
    $forbiddenHits = @(Get-ReviewerEvalForbiddenKeyHits -Value $Corpus -Forbidden $script:ReviewerEvalCorpusForbiddenKeys)
    if ($forbiddenHits.Count -gt 0) { [void]$reasons.Add("corpusForbiddenField") }

    $partitionPolicy = Get-ReviewerVerificationValue $Corpus "partitionPolicy"
    $corpusPin = Get-ReviewerVerificationValue $Corpus "corpusPin"
    if (-not (Test-ReviewerEvalExactKeys -Object $corpusPin -Allowed $script:ReviewerEvalCorpusPinKeys) -or
        [string]::IsNullOrWhiteSpace([string](Get-ReviewerVerificationValue $corpusPin "repositoryId" "")) -or
        ([string](Get-ReviewerVerificationValue $corpusPin "commitSha" "")) -notmatch '^[0-9a-f]{40}$') {
        [void]$reasons.Add("corpusSchemaInvalid")
    }
    if (-not (Test-ReviewerEvalExactKeys -Object $partitionPolicy -Allowed $script:ReviewerEvalPartitionPolicyKeys)) {
        [void]$reasons.Add("corpusSchemaInvalid")
    }
    $partitionSalt = [string](Get-ReviewerVerificationValue $partitionPolicy "partitionSalt" "")
    $adjudicationSalt = [string](Get-ReviewerVerificationValue $partitionPolicy "adjudicationSalt" "")
    $holdoutPercent = [int](Get-ReviewerVerificationValue $partitionPolicy "holdoutPercent" 0)
    if ([string](Get-ReviewerVerificationValue $partitionPolicy "method" "") -cne $script:ReviewerEvalPartitionMethod) {
        [void]$reasons.Add("corpusSchemaInvalid")
    }
    # Both salts are FROZEN inside the signed corpus, never read from policy: a
    # salt that policy could edit is a one-line way to reshuffle an
    # inconvenient example out of holdout.
    if ($partitionSalt.Length -lt 16 -or $adjudicationSalt.Length -lt 16) { [void]$reasons.Add("corpusSaltMissing") }
    if ($holdoutPercent -lt 1 -or $holdoutPercent -gt 99) { [void]$reasons.Add("corpusSchemaInvalid") }

    $modelIdentitySet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($identity in @($ModelIdentities)) { [void]$modelIdentitySet.Add([string]$identity) }

    $examples = @(Get-ReviewerVerificationValue $Corpus "examples" @())
    $seenExampleIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $seenChangeSets = @{}
    $groupPartitions = @{}
    $recordHashes = [System.Collections.Generic.List[string]]::new()
    $stratumTotals = @{}
    $qualifyingCount = 0
    $seedCount = 0
    $calibrationCount = 0
    $holdoutCount = 0

    foreach ($example in $examples) {
        if (-not (Test-ReviewerEvalExactKeys -Object $example -Allowed $script:ReviewerEvalExampleKeys)) {
            [void]$reasons.Add("corpusSchemaInvalid")
            continue
        }
        $exampleId = [string](Get-ReviewerVerificationValue $example "exampleId" "")
        $status = [string](Get-ReviewerVerificationValue $example "status" "")
        $stratum = [string](Get-ReviewerVerificationValue $example "stratum" "")
        $partition = [string](Get-ReviewerVerificationValue $example "partition" "")
        $groupKey = [string](Get-ReviewerVerificationValue $example "groupKey" "")
        $provenance = Get-ReviewerVerificationValue $example "provenance"

        if ($script:ReviewerEvalExampleStatuses -cnotcontains $status -or
            $script:ReviewerEvalPartitions -cnotcontains $partition) {
            [void]$reasons.Add("corpusSchemaInvalid")
        }
        if ($script:ReviewerEvalStrata -cnotcontains $stratum) { [void]$reasons.Add("corpusStratumUnknown") }
        if (-not (Test-ReviewerEvalExactKeys -Object $provenance -Allowed $script:ReviewerEvalProvenanceKeys)) {
            [void]$reasons.Add("corpusSchemaInvalid")
            continue
        }
        $sourceCommit = ([string](Get-ReviewerVerificationValue $provenance "sourceCommitSha" "")).ToLowerInvariant()
        $targetCommit = ([string](Get-ReviewerVerificationValue $provenance "targetCommitSha" "")).ToLowerInvariant()
        $changeSet = ([string](Get-ReviewerVerificationValue $provenance "changeSetSha256" "")).ToLowerInvariant()
        if ($sourceCommit -notmatch '^[0-9a-f]{40}$' -or $targetCommit -notmatch '^[0-9a-f]{40}$' -or
            $changeSet -notmatch '^[0-9a-f]{64}$' -or
            ([string](Get-ReviewerVerificationValue $provenance "changedFilePathsSha256" "")) -notmatch '^[0-9a-fA-F]{64}$' -or
            ([string](Get-ReviewerVerificationValue $provenance "importToolSha256" "")) -notmatch '^[0-9a-fA-F]{64}$') {
            [void]$reasons.Add("corpusSchemaInvalid")
        }
        # An all-zero pin is a placeholder, not a provenance. Seed fixtures are
        # allowed to be synthetic; a record that claims to be QUALIFYING is not.
        if ($status -ceq "qualifying" -and
            ($sourceCommit -ceq ("0" * 40) -or $targetCommit -ceq ("0" * 40) -or $changeSet -ceq ("0" * 64))) {
            [void]$reasons.Add("corpusSchemaInvalid")
        }
        if ($exampleId -cne (Get-ReviewerEvalExampleId -Provenance $provenance)) { [void]$reasons.Add("corpusSchemaInvalid") }
        if ($groupKey -cne (Get-ReviewerEvalGroupKey -Provenance $provenance)) { [void]$reasons.Add("corpusSchemaInvalid") }
        if (-not $seenExampleIds.Add($exampleId)) { [void]$reasons.Add("corpusDuplicateExample") }

        # The same pinned change appearing twice, or the same group appearing on
        # both sides of the split, is calibration/holdout leakage.
        if ($seenChangeSets.ContainsKey($changeSet)) {
            if ([string]$seenChangeSets[$changeSet] -cne $partition) { [void]$reasons.Add("corpusPartitionLeakage") }
            else { [void]$reasons.Add("corpusDuplicateExample") }
        }
        else { $seenChangeSets[$changeSet] = $partition }
        if ($groupPartitions.ContainsKey($groupKey)) {
            if ([string]$groupPartitions[$groupKey] -cne $partition) { [void]$reasons.Add("corpusGroupLeakage") }
        }
        else { $groupPartitions[$groupKey] = $partition }

        foreach ($item in @(Get-ReviewerVerificationValue $example "inventory" @())) {
            if (-not (Test-ReviewerEvalExactKeys -Object $item -Allowed $script:ReviewerEvalInventoryKeys)) {
                [void]$reasons.Add("corpusSchemaInvalid")
                continue
            }
            if ($script:ReviewerEvalSeverities -cnotcontains [string](Get-ReviewerVerificationValue $item "severity" "")) {
                [void]$reasons.Add("corpusSchemaInvalid")
            }
        }

        $labels = @(Get-ReviewerVerificationValue $example "labels" @())
        foreach ($label in $labels) {
            if (-not (Test-ReviewerEvalExactKeys -Object $label -Allowed $script:ReviewerEvalLabelKeys)) {
                [void]$reasons.Add("corpusSchemaInvalid")
                continue
            }
            if ($script:ReviewerEvalLabelerKinds -cnotcontains [string](Get-ReviewerVerificationValue $label "labelerKind" "")) {
                [void]$reasons.Add("corpusLabelerNotHuman")
            }
            if (-not [bool](Get-ReviewerVerificationValue $label "blind" $false)) { [void]$reasons.Add("corpusLabelerNotHuman") }
            if ($script:ReviewerEvalDecisions -cnotcontains [string](Get-ReviewerVerificationValue $label "decision" "")) {
                [void]$reasons.Add("corpusSchemaInvalid")
            }
            if ($modelIdentitySet.Contains([string](Get-ReviewerVerificationValue $label "labelerId" ""))) {
                [void]$reasons.Add("corpusModelIdentityAsLabeler")
            }
        }
        if ($labels.Count -lt 2) { [void]$reasons.Add("corpusLabelerCountBelowFloor") }

        $adjudication = Get-ReviewerVerificationValue $example "adjudication"
        if ($null -ne $adjudication) {
            if (-not (Test-ReviewerEvalExactKeys -Object $adjudication -Allowed $script:ReviewerEvalCorpusAdjudicationKeys)) {
                [void]$reasons.Add("corpusSchemaInvalid")
            }
            elseif ($modelIdentitySet.Contains([string](Get-ReviewerVerificationValue $adjudication "adjudicatorId" ""))) {
                [void]$reasons.Add("corpusModelIdentityAsLabeler")
            }
        }

        $stored = Get-ReviewerVerificationValue $example "groundTruth"
        $derived = Get-ReviewerEvalGroundTruth -Labels $labels -Adjudication $adjudication
        foreach ($reason in @($derived.ReasonCodes)) { [void]$reasons.Add($reason) }
        if (-not (Test-ReviewerEvalExactKeys -Object $stored -Allowed $script:ReviewerEvalGroundTruthKeys)) {
            [void]$reasons.Add("corpusSchemaInvalid")
        }
        else {
            $storedIssues = (Get-ReviewerEvalOrdinalSorted -Values @(@(Get-ReviewerVerificationValue $stored "issueIds" @()) |
                        ForEach-Object { [string]$_ })) -join ","
            $derivedIssues = ($derived.issueIds) -join ","
            if ($storedIssues -cne $derivedIssues -or
                ([string](Get-ReviewerVerificationValue $stored "decision" "")) -cne ([string]$derived.decision) -or
                ([string](Get-ReviewerVerificationValue $stored "resolution" "")) -cne ([string]$derived.resolution)) {
                [void]$reasons.Add("corpusGroundTruthMismatch")
            }
        }

        $storedRecordHash = [string](Get-ReviewerVerificationValue $example "recordHash" "")
        if ($storedRecordHash -cne (Get-ReviewerEvalRecordHash -Example $example)) {
            [void]$reasons.Add("corpusRecordHashMismatch")
        }
        [void]$recordHashes.Add($storedRecordHash)

        if ($status -ceq "qualifying") { $qualifyingCount++ } else { $seedCount++ }
        if ($partition -ceq "holdout") { $holdoutCount++ } else { $calibrationCount++ }
        if (-not $stratumTotals.ContainsKey($stratum)) {
            $stratumTotals[$stratum] = [pscustomobject]@{ Total = 0; Calibration = 0; Holdout = 0 }
        }
        $stratumTotals[$stratum].Total++
        if ($partition -ceq "holdout") { $stratumTotals[$stratum].Holdout++ } else { $stratumTotals[$stratum].Calibration++ }
    }

    # An empty corpus is not a trivially valid one: with no examples there is
    # nothing to derive a partition assignment from, so the freeze block would
    # otherwise go entirely unverified.
    if ($examples.Count -eq 0) { [void]$reasons.Add("corpusSchemaInvalid") }
    $freeze = Get-ReviewerVerificationValue $Corpus "freeze"
    if (-not (Test-ReviewerEvalExactKeys -Object $freeze -Allowed $script:ReviewerEvalFreezeKeys)) {
        [void]$reasons.Add("corpusSchemaInvalid")
    }
    else {
        $derivedCorpusSha = Get-ReviewerEvalCorpusSha256 `
            -Name ([string](Get-ReviewerVerificationValue $Corpus "name" "")) `
            -CorpusVersion ([int](Get-ReviewerVerificationValue $Corpus "corpusVersion" 0)) `
            -CorpusPin (Get-ReviewerVerificationValue $Corpus "corpusPin") `
            -FrozenAtEpochSeconds ([int64](Get-ReviewerVerificationValue $Corpus "frozenAtEpochSeconds" 0)) `
            -PartitionPolicy $partitionPolicy `
            -Strata @(Get-ReviewerVerificationValue $Corpus "strata" @()) `
            -Corrections @(Get-ReviewerVerificationValue $Corpus "corrections" @()) `
            -RecordHashes $recordHashes.ToArray()
        if ([string](Get-ReviewerVerificationValue $freeze "corpusSha256" "") -cne $derivedCorpusSha) {
            [void]$reasons.Add("corpusFreezeHashMismatch")
        }
        if ([int](Get-ReviewerVerificationValue $freeze "exampleCount" -1) -ne $examples.Count) {
            [void]$reasons.Add("corpusFreezeHashMismatch")
        }
    }
    if ($examples.Count -gt 0 -and $partitionSalt -and $holdoutPercent -ge 1 -and $holdoutPercent -le 99) {
        $derivedAssignment = Get-ReviewerEvalPartitionAssignment -Examples $examples `
            -PartitionSalt $partitionSalt -HoldoutPercent $holdoutPercent
        foreach ($example in $examples) {
            $exampleId = [string](Get-ReviewerVerificationValue $example "exampleId" "")
            if (-not $derivedAssignment.Assignment.ContainsKey($exampleId)) { continue }
            if ([string]$derivedAssignment.Assignment[$exampleId] -cne [string](Get-ReviewerVerificationValue $example "partition" "")) {
                [void]$reasons.Add("corpusPartitionMismatch")
            }
        }
        if ([string](Get-ReviewerVerificationValue $freeze "partitionAssignmentSha256" "") -cne $derivedAssignment.AssignmentSha256) {
            [void]$reasons.Add("corpusFreezeHashMismatch")
        }
    }

    # Corrections are the only sanctioned post-freeze channel, so they are the
    # one an operator with run results in hand would reach for. Ordering is
    # therefore load-bearing, not bookkeeping.
    $expectedSequence = 1
    foreach ($correction in @(Get-ReviewerVerificationValue $Corpus "corrections" @())) {
        if (-not (Test-ReviewerEvalExactKeys -Object $correction -Allowed $script:ReviewerEvalCorrectionKeys)) {
            [void]$reasons.Add("corpusSchemaInvalid")
            continue
        }
        if ([int](Get-ReviewerVerificationValue $correction "sequence" 0) -ne $expectedSequence) {
            [void]$reasons.Add("corpusCorrectionOutOfOrder")
        }
        $expectedSequence++
        if ($script:ReviewerEvalCorrectionReasons -cnotcontains [string](Get-ReviewerVerificationValue $correction "reasonCode" "")) {
            [void]$reasons.Add("corpusSchemaInvalid")
        }
        if ($script:ReviewerEvalLabelerKinds -cnotcontains [string](Get-ReviewerVerificationValue $correction "authorKind" "") -or
            $modelIdentitySet.Contains([string](Get-ReviewerVerificationValue $correction "authorId" ""))) {
            [void]$reasons.Add("corpusCorrectionAuthorInvalid")
        }
        if ([string](Get-ReviewerVerificationValue $correction "supersedesRecordHash" "") -notmatch '^[0-9a-f]{64}$') {
            [void]$reasons.Add("corpusSchemaInvalid")
        }
        if ($null -ne $EarliestRunSequence -and
            [int64](Get-ReviewerVerificationValue $correction "appliedAtEpochSeconds" 0) -ge [int64]$EarliestRunSequence) {
            [void]$reasons.Add("postRunCorrection")
        }
    }
    if ([int](Get-ReviewerVerificationValue $Corpus "corpusVersion" 0) -lt $expectedSequence) {
        [void]$reasons.Add("corpusCorrectionOutOfOrder")
    }

    $byStratum = [System.Collections.Generic.List[object]]::new()
    foreach ($stratum in $script:ReviewerEvalStrata) {
        $entry = $(if ($stratumTotals.ContainsKey($stratum)) { $stratumTotals[$stratum] } else { $null })
        [void]$byStratum.Add([pscustomobject][ordered]@{
                stratum     = $stratum
                total       = $(if ($entry) { [int]$entry.Total } else { 0 })
                calibration = $(if ($entry) { [int]$entry.Calibration } else { 0 })
                holdout     = $(if ($entry) { [int]$entry.Holdout } else { 0 })
            })
    }
    $population = [pscustomobject][ordered]@{
        totalExamples       = $examples.Count
        qualifyingExamples  = $qualifyingCount
        seedExamples        = $seedCount
        calibrationExamples = $calibrationCount
        holdoutExamples     = $holdoutCount
        byStratum           = @($byStratum.ToArray())
    }

    $unique = @(Get-ReviewerEvalUniqueReasonCodes -Reasons $reasons.ToArray())
    return [pscustomobject][ordered]@{
        Ok          = ($unique.Count -eq 0)
        ReasonCodes = $unique
        Population  = $population
        Examples    = @($examples)
        AdjudicationSalt = $adjudicationSalt
    }
}

# ---------------------------------------------------------------------------
# Run manifests: one per arm, over IDENTICAL pinned commits.
# ---------------------------------------------------------------------------

$script:ReviewerEvalRunTopKeys = @("kind", "artifactVersion", "schemaVersion", "runId", "arm", "derivation", "observations")
$script:ReviewerEvalRunDerivationKeys = @("executedAtEpochSeconds", "corpus", "binding", "models", "results")
$script:ReviewerEvalRunCorpusKeys = @("name", "corpusVersion", "corpusSha256", "exampleCount")
$script:ReviewerEvalRunBindingKeys = @(
    "evaluationLibrarySha256", "harnessToolSha256", "importToolSha256", "evaluationPolicySha256",
    "corpusSchemaSha256", "runSchemaSha256", "adjudicationSchemaSha256", "reportSchemaSha256",
    "reviewerScriptSha256", "gateLibrarySha256", "verificationLibrarySha256",
    "verificationPromptSha256", "verificationPolicySha256", "verificationSchemaSha256", "configSha256"
)
$script:ReviewerEvalRunModelKeys = @("generalists", "conventionSpecialist", "conventionVerifier")
$script:ReviewerEvalRunResultKeys = @(
    "exampleId", "sourceCommitSha", "targetCommitSha", "changeSetSha256",
    "commitResolution", "status", "vote", "claims"
)
$script:ReviewerEvalRunClaimKeys = @(
    "claimId", "blindClaimKey", "claimContentSha256", "issueClass", "severity",
    "path", "pack", "clusterId", "text"
)
# Every claim belongs to exactly one qualification scope dimension. The
# generalist pack name is fixed so it matches what the layer-6 gate policy
# ships with; anything else is a convention pack name.
$script:ReviewerEvalGeneralistPack = "(generalist)"
$script:ReviewerEvalRunObservationKeys = @("pricingTableVersion", "rates", "perExample")
$script:ReviewerEvalRunRateKeys = @("model", "inputMicroUsdPerKiloToken", "outputMicroUsdPerKiloToken")
$script:ReviewerEvalRunPerExampleKeys = @("exampleId", "latencyMs", "inputTokens", "outputTokens", "costMicroUsd")

function Get-ReviewerEvalClaimContentSha256 {
    <# The claim text is what an adjudicator actually reads, so it has to be
       pinned by the same key the verdict is filed under. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return Get-ReviewerEvalDomainSha256 -Domain "claimContent" -Value ([pscustomobject][ordered]@{ text = $Text })
}

function Get-ReviewerEvalBlindClaimKey {
    <# Content-derived and corpus-bound. It carries no arm, model, pack, or
       pass information, so two arms that produce the same claim about the same
       anchor share one verdict and an adjudicator cannot tell them apart. The
       merge is a convenience, not the blindness mechanism - the blindness
       mechanism is the presented-field allowlist plus the salted presentation
       order. #>
    param(
        [Parameter(Mandatory)][string]$CorpusSha256,
        [Parameter(Mandatory)][string]$ExampleId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][string]$Severity,
        [Parameter(Mandatory)][string]$ClaimContentSha256
    )
    $value = [pscustomobject][ordered]@{
        corpusSha256       = $CorpusSha256
        exampleId          = $ExampleId
        path               = $Path
        severity           = $Severity
        claimContentSha256 = $ClaimContentSha256
    }
    return Get-ReviewerEvalDomainSha256 -Domain "blindClaim" -Value $value
}

function Get-ReviewerEvalPresentedClaim {
    <# The EXACT projection an adjudicator is shown. Anything not in the
       allowlist - convention flag, issue class, cluster id, model, arm,
       tokens, latency - never leaves the run manifest. #>
    param([Parameter(Mandatory)]$Claim)
    return [pscustomobject][ordered]@{
        blindClaimKey      = [string](Get-ReviewerVerificationValue $Claim "blindClaimKey" "")
        claimContentSha256 = [string](Get-ReviewerVerificationValue $Claim "claimContentSha256" "")
        path               = [string](Get-ReviewerVerificationValue $Claim "path" "")
        severity           = [string](Get-ReviewerVerificationValue $Claim "severity" "")
        text               = [string](Get-ReviewerVerificationValue $Claim "text" "")
    }
}

function Get-ReviewerEvalPresentedSha256 {
    param([Parameter(Mandatory)]$Claim)
    return Get-ReviewerEvalDomainSha256 -Domain "presented" -Value (Get-ReviewerEvalPresentedClaim -Claim $Claim)
}

function Get-ReviewerEvalPresentationOrderSha256 {
    <# Presentation order is derived from a salted hash of each claim key, not
       from run or arm order. Grouping the claims by arm would let an
       adjudicator infer the arm from position alone, which is a blindness
       failure that no amount of field-stripping fixes. #>
    param(
        [Parameter(Mandatory)][string]$AdjudicationSalt,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$BlindClaimKeys
    )
    $composites = [System.Collections.Generic.List[string]]::new()
    foreach ($key in (Get-ReviewerEvalOrdinalSorted -Values $BlindClaimKeys)) {
        $sortHash = Get-ReviewerEvalDomainSha256 -Domain "presentationSort" -Value (
            [pscustomobject][ordered]@{ salt = $AdjudicationSalt; blindClaimKey = $key })
        [void]$composites.Add($sortHash + "|" + $key)
    }
    $ordered = @(Get-ReviewerEvalOrdinalSorted -Values $composites.ToArray() |
            ForEach-Object { $_.Substring($_.IndexOf("|") + 1) })
    return Get-ReviewerEvalDomainSha256 -Domain "presentationOrder" -Value (
        [pscustomobject][ordered]@{ salt = $AdjudicationSalt; order = @($ordered) })
}

function Test-ReviewerEvalRunSetConsistent {
    <# The three arms must be the same measurement taken three ways: same
       corpus, same code/config/prompt/schema binding, same configured model
       identities, same examples, same pinned commits per example. A pair that
       drifted on any of those is not a comparison, it is two experiments, and
       reporting a delta between them would be a category error. Mismatched or
       stale pairs are rejected outright rather than annotated. #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Runs,
        [Parameter(Mandatory)]$Corpus
    )
    $reasons = [System.Collections.Generic.List[string]]::new()
    $byArm = @{}
    foreach ($run in @($Runs)) {
        if ([string](Get-ReviewerVerificationValue $run "kind" "") -cne $script:ReviewerEvalRunKind) {
            [void]$reasons.Add("runKindInvalid")
            continue
        }
        if (-not (Test-ReviewerEvalExactKeys -Object $run -Allowed $script:ReviewerEvalRunTopKeys)) {
            [void]$reasons.Add("runKindInvalid")
            continue
        }
        $arm = [string](Get-ReviewerVerificationValue $run "arm" "")
        if ($script:ReviewerEvalArms -cnotcontains $arm) { [void]$reasons.Add("runArmUnknown"); continue }
        if ($byArm.ContainsKey($arm)) { [void]$reasons.Add("runArmDuplicated"); continue }
        $byArm[$arm] = $run
    }
    foreach ($arm in $script:ReviewerEvalArms) {
        if (-not $byArm.ContainsKey($arm)) { [void]$reasons.Add("runArmMissing") }
    }
    if ($reasons.Count -gt 0) {
        return [pscustomobject][ordered]@{
            Ok = $false; ReasonCodes = (Get-ReviewerEvalUniqueReasonCodes -Reasons $reasons.ToArray())
            ByArm = $byArm; ModelIdentities = @(); EarliestExecutedAtEpochSeconds = $null
        }
    }

    $freeze = Get-ReviewerVerificationValue $Corpus "freeze"
    $corpusSha = [string](Get-ReviewerVerificationValue $freeze "corpusSha256" "")
    $corpusExamples = @(Get-ReviewerVerificationValue $Corpus "examples" @())
    $corpusById = @{}
    foreach ($example in $corpusExamples) {
        $corpusById[[string](Get-ReviewerVerificationValue $example "exampleId" "")] = $example
    }

    $bindingSignatures = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $modelSignatures = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $exampleSetSignatures = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $modelIdentities = [System.Collections.Generic.List[string]]::new()
    $earliest = $null

    foreach ($arm in $script:ReviewerEvalArms) {
        $run = $byArm[$arm]
        $derivation = Get-ReviewerVerificationValue $run "derivation"
        if (-not (Test-ReviewerEvalExactKeys -Object $derivation -Allowed $script:ReviewerEvalRunDerivationKeys)) {
            [void]$reasons.Add("runKindInvalid")
            continue
        }
        $executedAt = [int64](Get-ReviewerVerificationValue $derivation "executedAtEpochSeconds" 0)
        if ($null -eq $earliest -or $executedAt -lt $earliest) { $earliest = $executedAt }

        $runCorpus = Get-ReviewerVerificationValue $derivation "corpus"
        if (-not (Test-ReviewerEvalExactKeys -Object $runCorpus -Allowed $script:ReviewerEvalRunCorpusKeys) -or
            [string](Get-ReviewerVerificationValue $runCorpus "corpusSha256" "") -cne $corpusSha -or
            [string](Get-ReviewerVerificationValue $runCorpus "name" "") -cne [string](Get-ReviewerVerificationValue $Corpus "name" "") -or
            [int](Get-ReviewerVerificationValue $runCorpus "corpusVersion" 0) -ne [int](Get-ReviewerVerificationValue $Corpus "corpusVersion" 0) -or
            [int](Get-ReviewerVerificationValue $runCorpus "exampleCount" -1) -ne $corpusExamples.Count) {
            [void]$reasons.Add("runCorpusMismatch")
        }

        $binding = Get-ReviewerVerificationValue $derivation "binding"
        if (-not (Test-ReviewerEvalExactKeys -Object $binding -Allowed $script:ReviewerEvalRunBindingKeys)) {
            [void]$reasons.Add("runBindingMismatch")
        }
        else { [void]$bindingSignatures.Add((ConvertTo-ReviewerVerificationCanonicalJson -Value $binding)) }

        $models = Get-ReviewerVerificationValue $derivation "models"
        if (-not (Test-ReviewerEvalExactKeys -Object $models -Allowed $script:ReviewerEvalRunModelKeys)) {
            [void]$reasons.Add("runModelIdentityMissing")
        }
        else {
            $generalists = @(@(Get-ReviewerVerificationValue $models "generalists" @()) | ForEach-Object { [string]$_ })
            $specialist = [string](Get-ReviewerVerificationValue $models "conventionSpecialist" "")
            $verifier = [string](Get-ReviewerVerificationValue $models "conventionVerifier" "")
            if ($generalists.Count -ne 2 -or
                @($generalists | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0 -or
                [string]::IsNullOrWhiteSpace($specialist) -or [string]::IsNullOrWhiteSpace($verifier)) {
                [void]$reasons.Add("runModelIdentityMissing")
            }
            foreach ($identity in @($generalists + @($specialist, $verifier))) { [void]$modelIdentities.Add($identity) }
            [void]$modelSignatures.Add((ConvertTo-ReviewerVerificationCanonicalJson -Value $models))
        }

        $observations = Get-ReviewerVerificationValue $run "observations"
        if (-not (Test-ReviewerEvalExactKeys -Object $observations -Allowed $script:ReviewerEvalRunObservationKeys)) {
            [void]$reasons.Add("runObservationsMissing")
        }
        else {
            # Observations are operator-asserted wall-clock facts, not something
            # this layer can recompute. What it CAN check is that the pricing
            # table actually covers every model the arm declares, so a cost
            # figure is at least attributable.
            $ratedModels = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($rate in @(Get-ReviewerVerificationValue $observations "rates" @())) {
                if (-not (Test-ReviewerEvalExactKeys -Object $rate -Allowed $script:ReviewerEvalRunRateKeys)) {
                    [void]$reasons.Add("runObservationsMissing")
                    continue
                }
                [void]$ratedModels.Add([string](Get-ReviewerVerificationValue $rate "model" ""))
            }
            foreach ($entry in @(Get-ReviewerVerificationValue $observations "perExample" @())) {
                if (-not (Test-ReviewerEvalExactKeys -Object $entry -Allowed $script:ReviewerEvalRunPerExampleKeys)) {
                    [void]$reasons.Add("runObservationsMissing")
                }
            }
            $models = Get-ReviewerVerificationValue $derivation "models"
            $declaredModels = @(@(Get-ReviewerVerificationValue $models "generalists" @()) | ForEach-Object { [string]$_ }) +
            @([string](Get-ReviewerVerificationValue $models "conventionSpecialist" ""),
                [string](Get-ReviewerVerificationValue $models "conventionVerifier" ""))
            foreach ($identity in $declaredModels) {
                if ($identity -and -not $ratedModels.Contains($identity)) { [void]$reasons.Add("runObservationsMissing") }
            }
        }

        $seenExamples = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($result in @(Get-ReviewerVerificationValue $derivation "results" @())) {
            if (-not (Test-ReviewerEvalExactKeys -Object $result -Allowed $script:ReviewerEvalRunResultKeys)) {
                [void]$reasons.Add("runKindInvalid")
                continue
            }
            $exampleId = [string](Get-ReviewerVerificationValue $result "exampleId" "")
            if (-not $seenExamples.Add($exampleId)) { [void]$reasons.Add("runDuplicateExample") }
            if (-not $corpusById.ContainsKey($exampleId)) { [void]$reasons.Add("runExampleSetMismatch"); continue }
            if ($script:ReviewerEvalResultStatuses -cnotcontains [string](Get-ReviewerVerificationValue $result "status" "") -or
                $script:ReviewerEvalVotes -cnotcontains [string](Get-ReviewerVerificationValue $result "vote" "") -or
                $script:ReviewerEvalCommitResolutions -cnotcontains [string](Get-ReviewerVerificationValue $result "commitResolution" "")) {
                [void]$reasons.Add("runKindInvalid")
            }
            if ([string](Get-ReviewerVerificationValue $result "commitResolution" "") -cne "resolved") {
                [void]$reasons.Add("runCommitUnresolved")
            }
            $provenance = Get-ReviewerVerificationValue $corpusById[$exampleId] "provenance"
            foreach ($field in @("sourceCommitSha", "targetCommitSha", "changeSetSha256")) {
                $runValue = ([string](Get-ReviewerVerificationValue $result $field "")).ToLowerInvariant()
                $corpusValue = ([string](Get-ReviewerVerificationValue $provenance $field "")).ToLowerInvariant()
                if ($runValue -cne $corpusValue) { [void]$reasons.Add("runStaleCommit") }
            }
            foreach ($claim in @(Get-ReviewerVerificationValue $result "claims" @())) {
                if (-not (Test-ReviewerEvalExactKeys -Object $claim -Allowed $script:ReviewerEvalRunClaimKeys)) {
                    [void]$reasons.Add("runKindInvalid")
                    continue
                }
                if ($script:ReviewerEvalSeverities -cnotcontains [string](Get-ReviewerVerificationValue $claim "severity" "")) {
                    [void]$reasons.Add("runKindInvalid")
                    continue
                }
                # claimContentSha256 must actually be the hash of the claim text
                # that will be presented, or the presented payload would not be
                # pinned by the blind claim key at all.
                if ([string](Get-ReviewerVerificationValue $claim "claimContentSha256" "") -cne
                    (Get-ReviewerEvalClaimContentSha256 -Text ([string](Get-ReviewerVerificationValue $claim "text" "")))) {
                    [void]$reasons.Add("runBlindClaimKeyMismatch")
                }
                $expectedKey = Get-ReviewerEvalBlindClaimKey -CorpusSha256 $corpusSha -ExampleId $exampleId `
                    -Path ([string](Get-ReviewerVerificationValue $claim "path" "")) `
                    -Severity ([string](Get-ReviewerVerificationValue $claim "severity" "")) `
                    -ClaimContentSha256 ([string](Get-ReviewerVerificationValue $claim "claimContentSha256" ""))
                if ([string](Get-ReviewerVerificationValue $claim "blindClaimKey" "") -cne $expectedKey) {
                    [void]$reasons.Add("runBlindClaimKeyMismatch")
                }
            }
        }
        $exampleSignature = ((Get-ReviewerEvalOrdinalSorted -Values @($seenExamples)) -join ",")
        [void]$exampleSetSignatures.Add($exampleSignature)
        if ($seenExamples.Count -ne $corpusExamples.Count) { [void]$reasons.Add("runExampleSetMismatch") }
    }

    if ($bindingSignatures.Count -gt 1) { [void]$reasons.Add("runBindingMismatch") }
    if ($modelSignatures.Count -gt 1) { [void]$reasons.Add("runBindingMismatch") }
    if ($exampleSetSignatures.Count -gt 1) { [void]$reasons.Add("runExampleSetMismatch") }

    $unique = @(Get-ReviewerEvalUniqueReasonCodes -Reasons $reasons.ToArray())
    return [pscustomobject][ordered]@{
        Ok                             = ($unique.Count -eq 0)
        ReasonCodes                    = $unique
        ByArm                          = $byArm
        ModelIdentities                = @(Get-ReviewerEvalOrdinalSorted -Values $modelIdentities.ToArray())
        EarliestExecutedAtEpochSeconds = $earliest
    }
}

# ---------------------------------------------------------------------------
# Blind claim adjudication.
# ---------------------------------------------------------------------------

$script:ReviewerEvalAdjudicationTopKeys = @(
    "kind", "artifactVersion", "schemaVersion", "adjudicationVersion",
    "corpusSha256", "presentationOrderSha256", "verdicts"
)
$script:ReviewerEvalVerdictKeys = @("blindClaimKey", "presentedSha256", "labels", "adjudication")
$script:ReviewerEvalVerdictLabelKeys = @("labelerId", "labelerKind", "verdict", "matchedIssueIds", "verdictAtEpochSeconds")
$script:ReviewerEvalVerdictAdjudicationKeys = @(
    "adjudicatorId", "adjudicatorKind", "verdict", "matchedIssueIds", "adjudicatedAtEpochSeconds"
)

function Get-ReviewerEvalClaimVerdict {
    <# Deterministic reconciliation of >=2 independent blind verdicts on ONE
       claim. Abstentions and unresolved disagreements are NOT quietly dropped
       from the numerator while staying in the denominator, and they are not
       counted as correct either: they leave BOTH, and instead reduce
       adjudication coverage - which is itself a floor. Otherwise precision
       could be driven arbitrarily high just by abstaining on every hard
       claim. #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Labels,
        [AllowNull()]$Adjudication = $null
    )
    $labelerIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($label in @($Labels)) {
        [void]$labelerIds.Add([string](Get-ReviewerVerificationValue $label "labelerId" ""))
    }
    if (@($Labels).Count -lt 2 -or $labelerIds.Count -lt 2) {
        return [pscustomobject][ordered]@{
            Resolution = "disputed"; Verdict = $null; MatchedIssueIds = @()
            ReasonCodes = @("adjudicationLabelCountBelowFloor")
        }
    }
    $verdicts = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($label in @($Labels)) {
        [void]$verdicts.Add([string](Get-ReviewerVerificationValue $label "verdict" ""))
    }
    if ($verdicts.Count -eq 1) {
        $only = @($verdicts)[0]
        if ($only -ceq "abstain") {
            return [pscustomobject][ordered]@{
                Resolution = "abstained"; Verdict = $null; MatchedIssueIds = @(); ReasonCodes = @()
            }
        }
        # Concordant verdict, conservative match set: only issues EVERY labeler
        # independently reported as matched count toward recall.
        $intersection = $null
        foreach ($label in @($Labels)) {
            $ids = [System.Collections.Generic.HashSet[string]]::new(
                [string[]]@(@(Get-ReviewerVerificationValue $label "matchedIssueIds" @()) | ForEach-Object { [string]$_ }),
                [StringComparer]::Ordinal)
            if ($null -eq $intersection) { $intersection = $ids } else { $intersection.IntersectWith($ids) }
        }
        return [pscustomobject][ordered]@{
            Resolution = "concordant"; Verdict = $only
            MatchedIssueIds = @(Get-ReviewerEvalOrdinalSorted -Values @($intersection)); ReasonCodes = @()
        }
    }
    if ($null -eq $Adjudication) {
        return [pscustomobject][ordered]@{
            Resolution = "disputed"; Verdict = $null; MatchedIssueIds = @(); ReasonCodes = @()
        }
    }
    $adjudicatorId = [string](Get-ReviewerVerificationValue $Adjudication "adjudicatorId" "")
    if ($labelerIds.Contains($adjudicatorId)) {
        return [pscustomobject][ordered]@{
            Resolution = "disputed"; Verdict = $null; MatchedIssueIds = @()
            ReasonCodes = @("adjudicationAdjudicatorNotIndependent")
        }
    }
    $adjudicatedVerdict = [string](Get-ReviewerVerificationValue $Adjudication "verdict" "")
    if ($adjudicatedVerdict -ceq "abstain") {
        return [pscustomobject][ordered]@{
            Resolution = "abstained"; Verdict = $null; MatchedIssueIds = @(); ReasonCodes = @()
        }
    }
    return [pscustomobject][ordered]@{
        Resolution = "adjudicated"; Verdict = $adjudicatedVerdict
        MatchedIssueIds = @(Get-ReviewerEvalOrdinalSorted -Values @(
                @(Get-ReviewerVerificationValue $Adjudication "matchedIssueIds" @()) | ForEach-Object { [string]$_ }))
        ReasonCodes = @()
    }
}

function Get-ReviewerEvalFleissKappa {
    <# Fleiss' kappa over the per-claim label verdicts, in its generalized form
       that tolerates a varying number of raters per item. Only +, -, * and /
       on doubles - all IEEE-754 basic operations, which ARE reproducible
       across platforms, unlike the transcendental functions this file avoids
       everywhere. Returns $null when it is undefined (fewer than two rated
       items, or a degenerate category distribution), and $null fails closed
       at the qualification layer rather than being read as agreement. #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$RatingVectors)
    $categories = $script:ReviewerEvalVerdicts
    $usable = @($RatingVectors | Where-Object { @($_).Count -ge 2 })
    if ($usable.Count -lt 2) { return $null }
    $categoryTotals = @{}
    foreach ($category in $categories) { $categoryTotals[$category] = 0 }
    $totalRatings = 0
    $agreementSum = 0.0
    foreach ($vector in $usable) {
        $counts = @{}
        foreach ($category in $categories) { $counts[$category] = 0 }
        foreach ($rating in @($vector)) {
            $value = [string]$rating
            if (-not $counts.ContainsKey($value)) { return $null }
            $counts[$value] = $counts[$value] + 1
        }
        $raters = @($vector).Count
        $sumSquares = 0
        foreach ($category in $categories) {
            $sumSquares += $counts[$category] * $counts[$category]
            $categoryTotals[$category] = $categoryTotals[$category] + $counts[$category]
        }
        $totalRatings += $raters
        $agreementSum += ([double]($sumSquares - $raters)) / ([double]($raters * ($raters - 1)))
    }
    if ($totalRatings -le 0) { return $null }
    $observed = $agreementSum / [double]$usable.Count
    $expected = 0.0
    foreach ($category in $categories) {
        $proportion = [double]$categoryTotals[$category] / [double]$totalRatings
        $expected += $proportion * $proportion
    }
    if ($expected -ge 1.0) { return $null }
    return (($observed - $expected) / (1.0 - $expected))
}

function Test-ReviewerEvalAdjudication {
    <# Structure, blindness, independence, coverage, and agreement over the
       claim verdicts, resolved against the exact set of claims the run
       manifests actually produced. #>
    param(
        [Parameter(Mandatory)]$Adjudication,
        [Parameter(Mandatory)]$RunSet,
        [Parameter(Mandatory)]$Corpus,
        [Parameter(Mandatory)][string]$AdjudicationSalt
    )
    $reasons = [System.Collections.Generic.List[string]]::new()
    if ([string](Get-ReviewerVerificationValue $Adjudication "kind" "") -cne $script:ReviewerEvalAdjudicationKind -or
        -not (Test-ReviewerEvalExactKeys -Object $Adjudication -Allowed $script:ReviewerEvalAdjudicationTopKeys) -or
        [int](Get-ReviewerVerificationValue $Adjudication "artifactVersion" 0) -ne $script:ReviewerEvalArtifactVersion -or
        [int](Get-ReviewerVerificationValue $Adjudication "schemaVersion" 0) -ne $script:ReviewerEvalSchemaVersion) {
        return [pscustomobject][ordered]@{
            Ok = $false; ReasonCodes = @("adjudicationKindInvalid"); Verdicts = @{}
            Coverage = $null; Kappa = $null; DisagreementRate = $null; Presented = 0; Resolved = 0
            Abstained = 0; Disputed = 0
        }
    }
    $forbiddenHits = @(Get-ReviewerEvalForbiddenKeyHits -Value $Adjudication -Forbidden $script:ReviewerEvalAdjudicationForbiddenKeys)
    if ($forbiddenHits.Count -gt 0) { [void]$reasons.Add("adjudicationForbiddenField") }

    $freeze = Get-ReviewerVerificationValue $Corpus "freeze"
    $corpusSha = [string](Get-ReviewerVerificationValue $freeze "corpusSha256" "")
    if ([string](Get-ReviewerVerificationValue $Adjudication "corpusSha256" "") -cne $corpusSha) {
        [void]$reasons.Add("adjudicationCorpusMismatch")
    }

    $inventoryByExample = @{}
    foreach ($example in @(Get-ReviewerVerificationValue $Corpus "examples" @())) {
        $ids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($item in @(Get-ReviewerVerificationValue $example "inventory" @())) {
            [void]$ids.Add([string](Get-ReviewerVerificationValue $item "issueId" ""))
        }
        $inventoryByExample[[string](Get-ReviewerVerificationValue $example "exampleId" "")] = $ids
    }

    # The presented set is the union of every claim every arm produced.
    $presentedHashes = @{}
    $claimExample = @{}
    foreach ($arm in $script:ReviewerEvalArms) {
        if (-not $RunSet.ByArm.ContainsKey($arm)) { continue }
        $derivation = Get-ReviewerVerificationValue $RunSet.ByArm[$arm] "derivation"
        foreach ($result in @(Get-ReviewerVerificationValue $derivation "results" @())) {
            $exampleId = [string](Get-ReviewerVerificationValue $result "exampleId" "")
            foreach ($claim in @(Get-ReviewerVerificationValue $result "claims" @())) {
                $key = [string](Get-ReviewerVerificationValue $claim "blindClaimKey" "")
                $presentedHashes[$key] = Get-ReviewerEvalPresentedSha256 -Claim $claim
                $claimExample[$key] = $exampleId
            }
        }
    }
    $expectedOrder = Get-ReviewerEvalPresentationOrderSha256 -AdjudicationSalt $AdjudicationSalt `
        -BlindClaimKeys @($presentedHashes.Keys)
    if ([string](Get-ReviewerVerificationValue $Adjudication "presentationOrderSha256" "") -cne $expectedOrder) {
        [void]$reasons.Add("adjudicationPresentationOrderMismatch")
    }

    $modelIdentitySet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($identity in @($RunSet.ModelIdentities)) { [void]$modelIdentitySet.Add([string]$identity) }

    $resolvedByKey = @{}
    $ratingVectors = [System.Collections.Generic.List[object]]::new()
    $seenKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $resolvedCount = 0
    $abstainedCount = 0
    $disputedCount = 0
    $discordantCount = 0
    $ratedCount = 0

    foreach ($verdict in @(Get-ReviewerVerificationValue $Adjudication "verdicts" @())) {
        if (-not (Test-ReviewerEvalExactKeys -Object $verdict -Allowed $script:ReviewerEvalVerdictKeys)) {
            [void]$reasons.Add("adjudicationKindInvalid")
            continue
        }
        $key = [string](Get-ReviewerVerificationValue $verdict "blindClaimKey" "")
        if (-not $seenKeys.Add($key)) { [void]$reasons.Add("adjudicationDuplicateClaim"); continue }
        if (-not $presentedHashes.ContainsKey($key)) { [void]$reasons.Add("adjudicationUnknownClaim"); continue }
        if ([string](Get-ReviewerVerificationValue $verdict "presentedSha256" "") -cne [string]$presentedHashes[$key]) {
            [void]$reasons.Add("adjudicationPresentedHashMismatch")
        }
        $labels = @(Get-ReviewerVerificationValue $verdict "labels" @())
        $ratings = [System.Collections.Generic.List[string]]::new()
        foreach ($label in $labels) {
            if (-not (Test-ReviewerEvalExactKeys -Object $label -Allowed $script:ReviewerEvalVerdictLabelKeys)) {
                [void]$reasons.Add("adjudicationKindInvalid")
                continue
            }
            if ($script:ReviewerEvalLabelerKinds -cnotcontains [string](Get-ReviewerVerificationValue $label "labelerKind" "")) {
                [void]$reasons.Add("adjudicationLabelerNotHuman")
            }
            if ($modelIdentitySet.Contains([string](Get-ReviewerVerificationValue $label "labelerId" ""))) {
                [void]$reasons.Add("adjudicationModelIdentityAsLabeler")
            }
            $labelVerdict = [string](Get-ReviewerVerificationValue $label "verdict" "")
            if ($script:ReviewerEvalVerdicts -cnotcontains $labelVerdict) {
                [void]$reasons.Add("adjudicationKindInvalid")
                continue
            }
            [void]$ratings.Add($labelVerdict)
            foreach ($issueId in @(@(Get-ReviewerVerificationValue $label "matchedIssueIds" @()) | ForEach-Object { [string]$_ })) {
                $exampleId = [string]$claimExample[$key]
                if (-not $inventoryByExample.ContainsKey($exampleId) -or
                    -not $inventoryByExample[$exampleId].Contains($issueId)) {
                    [void]$reasons.Add("adjudicationMatchedIssueUnknown")
                }
            }
        }
        $claimAdjudication = Get-ReviewerVerificationValue $verdict "adjudication"
        if ($null -ne $claimAdjudication) {
            if (-not (Test-ReviewerEvalExactKeys -Object $claimAdjudication -Allowed $script:ReviewerEvalVerdictAdjudicationKeys)) {
                [void]$reasons.Add("adjudicationKindInvalid")
            }
            elseif ($modelIdentitySet.Contains([string](Get-ReviewerVerificationValue $claimAdjudication "adjudicatorId" ""))) {
                [void]$reasons.Add("adjudicationModelIdentityAsLabeler")
            }
            foreach ($issueId in @(@(Get-ReviewerVerificationValue $claimAdjudication "matchedIssueIds" @()) | ForEach-Object { [string]$_ })) {
                $exampleId = [string]$claimExample[$key]
                if (-not $inventoryByExample.ContainsKey($exampleId) -or
                    -not $inventoryByExample[$exampleId].Contains($issueId)) {
                    [void]$reasons.Add("adjudicationMatchedIssueUnknown")
                }
            }
        }
        $reconciled = Get-ReviewerEvalClaimVerdict -Labels $labels -Adjudication $claimAdjudication
        foreach ($reason in @($reconciled.ReasonCodes)) { [void]$reasons.Add($reason) }
        $resolvedByKey[$key] = $reconciled
        if ($ratings.Count -ge 2) {
            [void]$ratingVectors.Add(@($ratings.ToArray()))
            $ratedCount++
            $distinct = [System.Collections.Generic.HashSet[string]]::new([string[]]@($ratings.ToArray()), [StringComparer]::Ordinal)
            if ($distinct.Count -gt 1) { $discordantCount++ }
        }
        switch ([string]$reconciled.Resolution) {
            "abstained" { $abstainedCount++ }
            "disputed" { $disputedCount++ }
            default { $resolvedCount++ }
        }
    }

    foreach ($key in @($presentedHashes.Keys)) {
        if (-not $seenKeys.Contains($key)) { [void]$reasons.Add("adjudicationMissingClaim") }
    }

    $presentedCount = @($presentedHashes.Keys).Count
    $coverage = Get-ReviewerEvalRatio -Numerator $resolvedCount -Denominator $presentedCount
    $kappa = Get-ReviewerEvalFleissKappa -RatingVectors @($ratingVectors.ToArray())
    $disagreementRate = Get-ReviewerEvalRatio -Numerator $discordantCount -Denominator $ratedCount

    $unique = @(Get-ReviewerEvalUniqueReasonCodes -Reasons $reasons.ToArray())
    return [pscustomobject][ordered]@{
        Ok               = ($unique.Count -eq 0)
        ReasonCodes      = $unique
        Verdicts         = $resolvedByKey
        Presented        = $presentedCount
        Resolved         = $resolvedCount
        Abstained        = $abstainedCount
        Disputed         = $disputedCount
        Coverage         = $coverage
        Kappa            = $kappa
        DisagreementRate = $disagreementRate
    }
}

# ---------------------------------------------------------------------------
# Metrics.
#
# Denominator discipline, stated once and applied everywhere below:
#   * Only examples whose run status is "complete" contribute claims, votes,
#     or inventory items. A degraded/unknown/missing example is excluded from
#     EVERY denominator (so it cannot silently depress recall) and is counted
#     separately, where it becomes a fail-closed veto at qualification time.
#   * Only claims with a RESOLVED verdict (concordant or adjudicated) enter a
#     precision numerator or denominator. Abstained and disputed claims leave
#     both, and instead reduce adjudication coverage, which is its own floor.
#   * Unique-claim metrics collapse duplicates by blindClaimKey within an
#     (arm, example). Raw metrics do not. Both are reported, so a sample-size
#     floor can never be met by the same finding restated five ways.
#   * A zero denominator yields $null, never 0 and never 1.
# ---------------------------------------------------------------------------

function Get-ReviewerEvalPercentile {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][int64[]]$Values,
        [Parameter(Mandatory)][int]$PercentNumerator,
        [Parameter(Mandatory)][int]$PercentDenominator
    )
    $sorted = [int64[]]@($Values)
    if ($sorted.Count -eq 0) { return $null }
    [Array]::Sort($sorted)
    $rank = [int][Math]::Ceiling(($PercentNumerator * $sorted.Count) / [double]$PercentDenominator)
    if ($rank -lt 1) { $rank = 1 }
    if ($rank -gt $sorted.Count) { $rank = $sorted.Count }
    return $sorted[$rank - 1]
}

function Get-ReviewerEvalMedian {
    param([Parameter(Mandatory)][AllowEmptyCollection()][int64[]]$Values)
    $sorted = [int64[]]@($Values)
    if ($sorted.Count -eq 0) { return $null }
    [Array]::Sort($sorted)
    $middle = [int]($sorted.Count / 2)
    if ($sorted.Count % 2 -eq 1) { return [double]$sorted[$middle] }
    return (([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2.0)
}

function Get-ReviewerEvalArmMetrics {
    param(
        [Parameter(Mandatory)]$Run,
        [Parameter(Mandatory)]$Corpus,
        [Parameter(Mandatory)][hashtable]$Verdicts,
        [Parameter(Mandatory)][ValidateSet("calibration", "holdout", "all")][string]$Partition
    )
    $examplesById = @{}
    foreach ($example in @(Get-ReviewerVerificationValue $Corpus "examples" @())) {
        $examplesById[[string](Get-ReviewerVerificationValue $example "exampleId" "")] = $example
    }
    $derivation = Get-ReviewerVerificationValue $Run "derivation"
    $observations = Get-ReviewerVerificationValue $Run "observations"
    $observationByExample = @{}
    foreach ($entry in @(Get-ReviewerVerificationValue $observations "perExample" @())) {
        $observationByExample[[string](Get-ReviewerVerificationValue $entry "exampleId" "")] = $entry
    }

    $rawTruePositives = 0; $rawFalsePositives = 0; $rawClaims = 0; $rawResolved = 0
    $uniqueTruePositives = 0; $uniqueFalsePositives = 0; $uniqueClaims = 0; $uniqueResolved = 0
    $severityMatches = 0; $severityComparable = 0
    $eligibleTruePositives = 0; $eligibleFalsePositives = 0
    $criticalTruePositives = 0; $criticalFalsePositives = 0
    $voteDecisions = 0; $voteCorrect = 0; $wouldApprove = 0; $falseApprovals = 0
    $shouldApprove = 0; $approveCorrect = 0
    $completeCount = 0; $degradedCount = 0; $unknownCount = 0; $missingCount = 0
    $inventoryTotal = 0; $inventoryConvention = 0
    $inventoryCorrectness = 0
    $matchedIssueKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $correctnessIssueKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $conventionIssueKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $issueClassTotals = @{}
    $issueClassMatched = @{}
    $latencies = [System.Collections.Generic.List[int64]]::new()
    $inputTokens = [int64]0; $outputTokens = [int64]0; $costMicroUsd = [int64]0

    foreach ($result in @(Get-ReviewerVerificationValue $derivation "results" @())) {
        $exampleId = [string](Get-ReviewerVerificationValue $result "exampleId" "")
        if (-not $examplesById.ContainsKey($exampleId)) { continue }
        $example = $examplesById[$exampleId]
        $examplePartition = [string](Get-ReviewerVerificationValue $example "partition" "")
        if ($Partition -cne "all" -and $examplePartition -cne $Partition) { continue }

        $status = [string](Get-ReviewerVerificationValue $result "status" "")
        # Deliberately if/elseif rather than switch: `continue` inside a
        # PowerShell switch is ambiguous about which construct it leaves.
        if ($status -ceq "complete") { $completeCount++ }
        elseif ($status -ceq "degraded") { $degradedCount++; continue }
        elseif ($status -ceq "unknown") { $unknownCount++; continue }
        else { $missingCount++; continue }

        # Recall denominators are the AGREED ground-truth issues, not the whole
        # candidate inventory. A disputed example has no agreed issues and
        # therefore contributes nothing to any recall denominator, rather than
        # silently depressing recall with items nobody confirmed.
        $groundTruthIds = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]@(@(Get-ReviewerVerificationValue (Get-ReviewerVerificationValue $example "groundTruth") "issueIds" @()) |
                    ForEach-Object { [string]$_ }), [StringComparer]::Ordinal)
        foreach ($item in @(Get-ReviewerVerificationValue $example "inventory" @())) {
            $issueId = [string](Get-ReviewerVerificationValue $item "issueId" "")
            if (-not $groundTruthIds.Contains($issueId)) { continue }
            $issueKey = $exampleId + "|" + $issueId
            $issueClass = [string](Get-ReviewerVerificationValue $item "issueClass" "")
            $inventoryTotal++
            if (-not $issueClassTotals.ContainsKey($issueClass)) {
                $issueClassTotals[$issueClass] = 0
                $issueClassMatched[$issueClass] = 0
            }
            $issueClassTotals[$issueClass] = $issueClassTotals[$issueClass] + 1
            if ([bool](Get-ReviewerVerificationValue $item "convention" $false)) {
                $inventoryConvention++
                [void]$conventionIssueKeys.Add($issueKey)
            }
            if ([bool](Get-ReviewerVerificationValue $item "correctness" $false)) {
                $inventoryCorrectness++
                [void]$correctnessIssueKeys.Add($issueKey)
            }
        }
        $inventorySeverity = @{}
        foreach ($item in @(Get-ReviewerVerificationValue $example "inventory" @())) {
            $inventorySeverity[[string](Get-ReviewerVerificationValue $item "issueId" "")] =
            [string](Get-ReviewerVerificationValue $item "severity" "")
        }

        $seenKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($claim in @(Get-ReviewerVerificationValue $result "claims" @())) {
            $key = [string](Get-ReviewerVerificationValue $claim "blindClaimKey" "")
            $severity = [string](Get-ReviewerVerificationValue $claim "severity" "")
            $rawClaims++
            $isNewUnique = $seenKeys.Add($key)
            if ($isNewUnique) { $uniqueClaims++ }
            if (-not $Verdicts.ContainsKey($key)) { continue }
            $reconciled = $Verdicts[$key]
            if ([string]$reconciled.Resolution -ceq "abstained" -or [string]$reconciled.Resolution -ceq "disputed") { continue }
            $verdict = [string]$reconciled.Verdict
            $rawResolved++
            if ($verdict -ceq "truePositive") { $rawTruePositives++ } else { $rawFalsePositives++ }
            if (-not $isNewUnique) { continue }
            $uniqueResolved++
            if ($verdict -ceq "truePositive") { $uniqueTruePositives++ } else { $uniqueFalsePositives++ }
            if ($script:ReviewerEvalUnattendedCommentSeverities -ccontains $severity) {
                if ($verdict -ceq "truePositive") { $eligibleTruePositives++ } else { $eligibleFalsePositives++ }
            }
            if ($severity -ceq "critical") {
                if ($verdict -ceq "truePositive") { $criticalTruePositives++ } else { $criticalFalsePositives++ }
            }
            if ($verdict -ceq "truePositive") {
                $matchedSeverity = ""
                $bestRank = 0
                foreach ($issueId in @($reconciled.MatchedIssueIds)) {
                    if (-not $groundTruthIds.Contains($issueId)) { continue }
                    [void]$matchedIssueKeys.Add($exampleId + "|" + $issueId)
                    $itemSeverity = [string]$inventorySeverity[$issueId]
                    $rank = 0
                    if ($itemSeverity -and $script:ReviewerEvalSeverityRank.ContainsKey($itemSeverity)) {
                        $rank = [int]$script:ReviewerEvalSeverityRank[$itemSeverity]
                    }
                    if ($rank -gt $bestRank) { $bestRank = $rank; $matchedSeverity = $itemSeverity }
                }
                if ($matchedSeverity) {
                    $severityComparable++
                    if ($matchedSeverity -ceq $severity) { $severityMatches++ }
                }
            }
        }

        $vote = [string](Get-ReviewerVerificationValue $result "vote" "")
        $groundTruth = Get-ReviewerVerificationValue $example "groundTruth"
        $decision = [string](Get-ReviewerVerificationValue $groundTruth "decision" "")
        if ($decision -ceq "approve" -or $decision -ceq "reject") {
            if ($vote -ceq "approve" -or $vote -ceq "none") {
                $voteDecisions++
                if (($vote -ceq "approve") -eq ($decision -ceq "approve")) { $voteCorrect++ }
                if ($decision -ceq "approve") {
                    $shouldApprove++
                    if ($vote -ceq "approve") { $approveCorrect++ }
                }
                if ($vote -ceq "approve") {
                    $wouldApprove++
                    if ($decision -ceq "reject") { $falseApprovals++ }
                }
            }
        }

        if ($observationByExample.ContainsKey($exampleId)) {
            $entry = $observationByExample[$exampleId]
            [void]$latencies.Add([int64](Get-ReviewerVerificationValue $entry "latencyMs" 0))
            $inputTokens += [int64](Get-ReviewerVerificationValue $entry "inputTokens" 0)
            $outputTokens += [int64](Get-ReviewerVerificationValue $entry "outputTokens" 0)
            $costMicroUsd += [int64](Get-ReviewerVerificationValue $entry "costMicroUsd" 0)
        }
    }

    foreach ($issueKey in @($matchedIssueKeys)) {
        $exampleId = $issueKey.Substring(0, $issueKey.IndexOf("|"))
        $issueId = $issueKey.Substring($issueKey.IndexOf("|") + 1)
        if (-not $examplesById.ContainsKey($exampleId)) { continue }
        foreach ($item in @(Get-ReviewerVerificationValue $examplesById[$exampleId] "inventory" @())) {
            if ([string](Get-ReviewerVerificationValue $item "issueId" "") -cne $issueId) { continue }
            $issueClass = [string](Get-ReviewerVerificationValue $item "issueClass" "")
            if ($issueClassMatched.ContainsKey($issueClass)) {
                $issueClassMatched[$issueClass] = $issueClassMatched[$issueClass] + 1
            }
        }
    }

    $matchedCorrectness = 0
    foreach ($issueKey in @($correctnessIssueKeys)) { if ($matchedIssueKeys.Contains($issueKey)) { $matchedCorrectness++ } }
    $matchedConvention = 0
    foreach ($issueKey in @($conventionIssueKeys)) { if ($matchedIssueKeys.Contains($issueKey)) { $matchedConvention++ } }

    $issueClassRecall = [System.Collections.Generic.List[object]]::new()
    foreach ($issueClass in (Get-ReviewerEvalOrdinalSorted -Values @($issueClassTotals.Keys))) {
        [void]$issueClassRecall.Add([pscustomobject][ordered]@{
                issueClass = $issueClass
                matched    = [int]$issueClassMatched[$issueClass]
                total      = [int]$issueClassTotals[$issueClass]
                recall     = Get-ReviewerEvalRatio -Numerator ([int]$issueClassMatched[$issueClass]) -Denominator ([int]$issueClassTotals[$issueClass])
            })
    }

    $eligibleFindings = $eligibleTruePositives + $eligibleFalsePositives
    return [pscustomobject][ordered]@{
        arm                        = [string](Get-ReviewerVerificationValue $Run "arm" "")
        partition                  = $Partition
        completeExamples           = $completeCount
        degradedExamples           = $degradedCount
        unknownExamples            = $unknownCount
        missingExamples            = $missingCount
        rawClaims                  = $rawClaims
        rawResolvedClaims          = $rawResolved
        rawTruePositives           = $rawTruePositives
        rawFalsePositives          = $rawFalsePositives
        rawPrecision               = Get-ReviewerEvalRatio -Numerator $rawTruePositives -Denominator $rawResolved
        uniqueClaims               = $uniqueClaims
        uniqueResolvedClaims       = $uniqueResolved
        uniqueTruePositives        = $uniqueTruePositives
        uniqueFalsePositives       = $uniqueFalsePositives
        uniqueClaimPrecision       = Get-ReviewerEvalRatio -Numerator $uniqueTruePositives -Denominator $uniqueResolved
        duplicateClaims            = ($rawClaims - $uniqueClaims)
        duplicateRate              = Get-ReviewerEvalRatio -Numerator ($rawClaims - $uniqueClaims) -Denominator $rawClaims
        severityComparableClaims   = $severityComparable
        severityAccurateClaims     = $severityMatches
        severityAccuracy           = Get-ReviewerEvalRatio -Numerator $severityMatches -Denominator $severityComparable
        inventoryItems             = $inventoryTotal
        inventoryMatched           = $matchedIssueKeys.Count
        inventoryCorrectnessItems  = $inventoryCorrectness
        inventoryCorrectnessMatched = $matchedCorrectness
        correctnessRecall          = Get-ReviewerEvalRatio -Numerator $matchedCorrectness -Denominator $inventoryCorrectness
        inventoryConventionItems   = $inventoryConvention
        inventoryConventionMatched = $matchedConvention
        conventionRecall           = Get-ReviewerEvalRatio -Numerator $matchedConvention -Denominator $inventoryConvention
        issueClassRecall           = @($issueClassRecall.ToArray())
        eligibleUnattendedFindings = $eligibleFindings
        eligibleTruePositives      = $eligibleTruePositives
        eligibleFalsePositives     = $eligibleFalsePositives
        eligiblePrecision          = Get-ReviewerEvalRatio -Numerator $eligibleTruePositives -Denominator $eligibleFindings
        criticalAdjudicatedClaims  = ($criticalTruePositives + $criticalFalsePositives)
        criticalFalsePositives     = $criticalFalsePositives
        voteDecisions              = $voteDecisions
        voteCorrect                = $voteCorrect
        voteAccuracy               = Get-ReviewerEvalRatio -Numerator $voteCorrect -Denominator $voteDecisions
        wouldApproveCount          = $wouldApprove
        falseApprovalCount         = $falseApprovals
        shouldApproveDecisions     = $shouldApprove
        approveCorrectDecisions    = $approveCorrect
        approvalRecall             = Get-ReviewerEvalRatio -Numerator $approveCorrect -Denominator $shouldApprove
        latencyMsMedian            = Get-ReviewerEvalMedian -Values $latencies.ToArray()
        latencyMsP95               = Get-ReviewerEvalPercentile -Values $latencies.ToArray() -PercentNumerator 95 -PercentDenominator 100
        latencyMsTotal             = $(
            $total = [int64]0
            foreach ($value in @($latencies)) { $total += [int64]$value }
            $total
        )
        inputTokens                = $inputTokens
        outputTokens               = $outputTokens
        costMicroUsd               = $costMicroUsd
        MatchedCorrectnessKeys     = $(
            $matched = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($issueKey in @($correctnessIssueKeys)) { if ($matchedIssueKeys.Contains($issueKey)) { [void]$matched.Add($issueKey) } }
            $matched
        )
        CorrectnessKeys            = $correctnessIssueKeys
    }
}

# ---------------------------------------------------------------------------
# Effective evaluation policy: validate + clamp, per-key direction.
# ---------------------------------------------------------------------------

$script:ReviewerEvalPolicyTopKeys = @(
    "schemaVersion", "policyVersion", "minExamples", "minCalibrationExamples",
    "minHoldoutExamples", "minPerStratumExamples", "minEligibleHoldoutFindings",
    "minCommentPrecision", "minCommentPrecisionLowerBound95", "minCriticalAdjudicatedClaims",
    "minApprovalDecisions", "minWouldApproveDecisions", "minAdjudicationCoverage",
    "minLabelAgreementKappa", "maxRecallRegression", "maxCriticalFalsePositiveRate",
    "maxFalseApprovalRate", "maxExactTrials", "suggestionQualificationEnabled", "qualifiableScopes"
)

function ConvertTo-ReviewerEvalEffectivePolicy {
    <# Caps clamp DOWN to the code ceiling, floors clamp UP to the code floor.
       Note what is NOT here: partitionSalt, adjudicationSalt, and
       holdoutPercent. Those are frozen inside the signed corpus. A salt that
       policy could edit would be a one-line way to reshuffle an inconvenient
       example out of the holdout partition. #>
    param([Parameter(Mandatory)]$Policy)
    if ([int](Get-ReviewerVerificationValue $Policy "schemaVersion" 0) -ne $script:ReviewerEvalSchemaVersion) {
        throw "Evaluation policy 'schemaVersion' must be exactly $script:ReviewerEvalSchemaVersion."
    }
    if ([int](Get-ReviewerVerificationValue $Policy "policyVersion" 0) -lt 1) {
        throw "Evaluation policy 'policyVersion' must be at least 1."
    }
    if (-not (Test-ReviewerEvalExactKeys -Object $Policy `
                -Allowed (@("_note") + $script:ReviewerEvalPolicyTopKeys) `
                -Required $script:ReviewerEvalPolicyTopKeys)) {
        throw "Evaluation policy has unexpected or missing top-level keys."
    }
    $effective = [ordered]@{
        schemaVersion = $script:ReviewerEvalSchemaVersion
        policyVersion = [int](Get-ReviewerVerificationValue $Policy "policyVersion" 1)
    }
    foreach ($entry in $script:ReviewerEvalCapKeys) {
        $name = [string]$entry[0]
        $value = Get-ReviewerVerificationValue $Policy $name $null
        if ($null -eq $value) { throw "Evaluation policy is missing '$name'." }
        $numeric = [double]$value
        if ($numeric -lt [double]$entry[1] -or $numeric -gt [double]$entry[2]) {
            throw "Evaluation policy '$name' is outside its supported range."
        }
        $ceiling = [double]$entry[3]
        $effective[$name] = [Math]::Min($numeric, $ceiling)
    }
    foreach ($entry in $script:ReviewerEvalFloorKeys) {
        $name = [string]$entry[0]
        $value = Get-ReviewerVerificationValue $Policy $name $null
        if ($null -eq $value) { throw "Evaluation policy is missing '$name'." }
        $numeric = [double]$value
        if ($numeric -lt [double]$entry[1] -or $numeric -gt [double]$entry[2]) {
            throw "Evaluation policy '$name' is outside its supported range."
        }
        $floor = [double]$entry[3]
        $effective[$name] = [Math]::Max($numeric, $floor)
    }
    $effective["suggestionQualificationEnabled"] =
    [bool](Get-ReviewerVerificationValue $Policy "suggestionQualificationEnabled" $false)
    # Prespecified, versioned scope list. Qualification may only ever be
    # claimed for a scope declared here BEFORE the numbers were seen, and its
    # size is the multiplicity correction: searching three arms x three
    # severities x N packs for one that clears 95% is not a 95% claim.
    $scopes = [System.Collections.Generic.List[object]]::new()
    foreach ($scope in @(Get-ReviewerVerificationValue $Policy "qualifiableScopes" @())) {
        if (-not (Test-ReviewerEvalExactKeys -Object $scope -Allowed @("pack", "severity"))) {
            throw "Each evaluation policy 'qualifiableScopes' entry must have exactly 'pack' and 'severity'."
        }
        $severity = [string](Get-ReviewerVerificationValue $scope "severity" "")
        if ($script:ReviewerEvalSeverities -cnotcontains $severity) {
            throw "An evaluation policy 'qualifiableScopes' entry has an unrecognized severity."
        }
        [void]$scopes.Add([pscustomobject][ordered]@{
                pack     = [string](Get-ReviewerVerificationValue $scope "pack" "")
                severity = $severity
            })
    }
    $effective["qualifiableScopes"] = @($scopes.ToArray())
    $effective["scopeCount"] = [Math]::Max(1, $scopes.Count)
    $effective["alphaNumerator"] = $script:ReviewerEvalAlphaNumerator
    $effective["alphaDenominator"] = $script:ReviewerEvalAlphaDenominator * [Math]::Max(1, $scopes.Count)
    $effective["boundMethod"] = "clopper-pearson-1sided-95-bonferroni-k$([Math]::Max(1, $scopes.Count))"
    return [pscustomobject]$effective
}

# ---------------------------------------------------------------------------
# Paired recall comparison. Both arms ran the SAME examples at the SAME pinned
# commits, so the correct comparison is paired, not a difference of two
# independent point estimates.
# ---------------------------------------------------------------------------

function Get-ReviewerEvalRecallComparison {
    param(
        [Parameter(Mandatory)]$BaselineMetrics,
        [Parameter(Mandatory)]$CandidateMetrics,
        [Parameter(Mandatory)]$EffectivePolicy
    )
    $baselineKeys = $BaselineMetrics.CorrectnessKeys
    $candidateKeys = $CandidateMetrics.CorrectnessKeys
    $inventoryCount = @($candidateKeys).Count
    # Pairing requires the SAME items, not the same number of items: two
    # disjoint sets of equal size would otherwise be "paired" and every
    # discordant count derived from them would be meaningless.
    $denominatorsAgree = (
        ((Get-ReviewerEvalOrdinalSorted -Values @($baselineKeys)) -join "|") -ceq
        ((Get-ReviewerEvalOrdinalSorted -Values @($candidateKeys)) -join "|")
    )
    $baselineMatched = $BaselineMetrics.MatchedCorrectnessKeys
    $candidateMatched = $CandidateMetrics.MatchedCorrectnessKeys
    $baselineOnly = 0
    $candidateOnly = 0
    foreach ($key in @($baselineMatched)) { if (-not $candidateMatched.Contains($key)) { $baselineOnly++ } }
    foreach ($key in @($candidateMatched)) { if (-not $baselineMatched.Contains($key)) { $candidateOnly++ } }
    $discordant = $baselineOnly + $candidateOnly
    $maxRegressionNumerator = ConvertTo-ReviewerEvalGridNumerator `
        -Value ([double]$EffectivePolicy.maxRecallRegression) -Role ceiling
    $withinCeiling = $false
    if ($denominatorsAgree -and $inventoryCount -gt 0) {
        $withinCeiling = Test-ReviewerEvalPairedRegressionWithinCeiling -InventoryCount $inventoryCount `
            -BaselineOnly $baselineOnly -CandidateOnly $candidateOnly `
            -MaxRegressionNumerator $maxRegressionNumerator `
            -AlphaNumerator ([int]$EffectivePolicy.alphaNumerator) `
            -AlphaDenominator ([int]$EffectivePolicy.alphaDenominator) `
            -MaxExactTrials ([int]$EffectivePolicy.maxExactTrials)
    }
    $regressionUpperBound = $null
    if ($discordant -gt 0 -and $inventoryCount -gt 0) {
        $proportionUpper = Get-ReviewerEvalUpperBoundGrid -Successes $baselineOnly -Trials $discordant `
            -AlphaNumerator ([int]$EffectivePolicy.alphaNumerator) `
            -AlphaDenominator ([int]$EffectivePolicy.alphaDenominator) `
            -MaxExactTrials ([int]$EffectivePolicy.maxExactTrials)
        if ($null -ne $proportionUpper) {
            $regressionUpperBound = ([double]$discordant * (2.0 * [double]$proportionUpper - 1.0)) / [double]$inventoryCount
        }
    }
    elseif ($discordant -eq 0 -and $inventoryCount -gt 0) { $regressionUpperBound = 0.0 }
    return [pscustomobject][ordered]@{
        primaryEndpoint         = "holdout correctness recall, identical inventory denominator, paired exact (discordant-pair) upper bound"
        inventoryCount          = $inventoryCount
        denominatorsAgree       = $denominatorsAgree
        baselineOnly            = $baselineOnly
        candidateOnly           = $candidateOnly
        discordantPairs         = $discordant
        regressionPointEstimate = $(if ($inventoryCount -gt 0) { ([double]($baselineOnly - $candidateOnly)) / [double]$inventoryCount } else { $null })
        regressionUpperBound95  = $regressionUpperBound
        withinCeiling           = $withinCeiling
    }
}

function Get-ReviewerEvalScopeMetrics {
    <# One (pack, severity) scope, in exactly the shape the layer-6
       qualification schema consumes - so an operator transcribes numbers
       rather than reshaping them, and a transcription error is obvious.

       Pooling across severities or across packs is deliberately impossible
       here: a pooled important+suggestion precision would otherwise be able to
       carry the important scope past a bar it never met on its own. #>
    param(
        [Parameter(Mandatory)]$Run,
        [Parameter(Mandatory)]$Corpus,
        [Parameter(Mandatory)][hashtable]$Verdicts,
        [Parameter(Mandatory)][ValidateSet("calibration", "holdout", "all")][string]$Partition,
        [Parameter(Mandatory)][string]$Pack,
        [Parameter(Mandatory)][string]$Severity,
        [Parameter(Mandatory)]$EffectivePolicy
    )
    $examplesById = @{}
    foreach ($example in @(Get-ReviewerVerificationValue $Corpus "examples" @())) {
        $examplesById[[string](Get-ReviewerVerificationValue $example "exampleId" "")] = $example
    }
    $isGeneralistScope = ($Pack -ceq $script:ReviewerEvalGeneralistPack)
    $truePositives = 0
    $falsePositives = 0
    $inventoryTotal = 0
    $inventoryMatched = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $derivation = Get-ReviewerVerificationValue $Run "derivation"

    foreach ($result in @(Get-ReviewerVerificationValue $derivation "results" @())) {
        $exampleId = [string](Get-ReviewerVerificationValue $result "exampleId" "")
        if (-not $examplesById.ContainsKey($exampleId)) { continue }
        $example = $examplesById[$exampleId]
        if ($Partition -cne "all" -and
            [string](Get-ReviewerVerificationValue $example "partition" "") -cne $Partition) {
            continue
        }
        if ([string](Get-ReviewerVerificationValue $result "status" "") -cne "complete") { continue }

        $groundTruthIds = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]@(@(Get-ReviewerVerificationValue (Get-ReviewerVerificationValue $example "groundTruth") "issueIds" @()) |
                    ForEach-Object { [string]$_ }), [StringComparer]::Ordinal)
        foreach ($item in @(Get-ReviewerVerificationValue $example "inventory" @())) {
            if (-not $groundTruthIds.Contains([string](Get-ReviewerVerificationValue $item "issueId" ""))) { continue }
            if ([string](Get-ReviewerVerificationValue $item "severity" "") -cne $Severity) { continue }
            $isConvention = [bool](Get-ReviewerVerificationValue $item "convention" $false)
            if ($isGeneralistScope -eq $isConvention) { continue }
            $inventoryTotal++
        }
        $seenKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($claim in @(Get-ReviewerVerificationValue $result "claims" @())) {
            if ([string](Get-ReviewerVerificationValue $claim "severity" "") -cne $Severity) { continue }
            if ([string](Get-ReviewerVerificationValue $claim "pack" "") -cne $Pack) { continue }
            $key = [string](Get-ReviewerVerificationValue $claim "blindClaimKey" "")
            if (-not $seenKeys.Add($key)) { continue }
            if (-not $Verdicts.ContainsKey($key)) { continue }
            $reconciled = $Verdicts[$key]
            if ([string]$reconciled.Resolution -ceq "abstained" -or [string]$reconciled.Resolution -ceq "disputed") { continue }
            if ([string]$reconciled.Verdict -ceq "truePositive") {
                $truePositives++
                foreach ($issueId in @($reconciled.MatchedIssueIds)) {
                    if (-not $groundTruthIds.Contains($issueId)) { continue }
                    foreach ($item in @(Get-ReviewerVerificationValue $example "inventory" @())) {
                        if ([string](Get-ReviewerVerificationValue $item "issueId" "") -cne $issueId) { continue }
                        if ([string](Get-ReviewerVerificationValue $item "severity" "") -cne $Severity) { continue }
                        $isConvention = [bool](Get-ReviewerVerificationValue $item "convention" $false)
                        if ($isGeneralistScope -eq $isConvention) { continue }
                        [void]$inventoryMatched.Add($exampleId + "|" + $issueId)
                    }
                }
            }
            else { $falsePositives++ }
        }
    }

    $sampleCount = $truePositives + $falsePositives
    $precision = Get-ReviewerEvalRatio -Numerator $truePositives -Denominator $sampleCount
    $recall = Get-ReviewerEvalRatio -Numerator $inventoryMatched.Count -Denominator $inventoryTotal
    $precisionLowerBound = $null
    if ($sampleCount -gt 0) {
        $precisionLowerBound = Get-ReviewerEvalLowerBoundGrid -Successes $truePositives -Trials $sampleCount `
            -AlphaNumerator ([int]$EffectivePolicy.alphaNumerator) `
            -AlphaDenominator ([int]$EffectivePolicy.alphaDenominator) `
            -MaxExactTrials ([int]$EffectivePolicy.maxExactTrials)
    }
    $recallLowerBound = $null
    if ($inventoryTotal -gt 0) {
        $recallLowerBound = Get-ReviewerEvalLowerBoundGrid -Successes $inventoryMatched.Count -Trials $inventoryTotal `
            -AlphaNumerator ([int]$EffectivePolicy.alphaNumerator) `
            -AlphaDenominator ([int]$EffectivePolicy.alphaDenominator) `
            -MaxExactTrials ([int]$EffectivePolicy.maxExactTrials)
    }
    return [pscustomobject][ordered]@{
        pack                  = $Pack
        severity              = $Severity
        sampleCount           = $sampleCount
        truePositives         = $truePositives
        falsePositives        = $falsePositives
        precision             = $precision
        precisionLowerBound95 = $precisionLowerBound
        recall                = $recall
        recallLowerBound95    = $recallLowerBound
        boundMethod           = [string]$EffectivePolicy.boundMethod
        inventoryItems        = $inventoryTotal
        inventoryMatched      = $inventoryMatched.Count
    }
}

# ---------------------------------------------------------------------------
# Executable rollout qualification.
#
# Nothing here mints, edits, or signs a delivery authorization. It answers one
# question - "would these numbers, on this corpus, satisfy the declared rollout
# bars?" - and the answer travels to a human, who decides whether to run the
# operator-only qualification tool. Layer 6's own code-defined ceilings are
# untouched: even a fully qualifying report cannot make a `critical` severity
# unattended, because DeliveryGates.ps1 excludes critical from its unattended
# severity ceiling and no policy or artifact can restore it.
# ---------------------------------------------------------------------------

function Test-ReviewerEvalRolloutQualification {
    param(
        [Parameter(Mandatory)]$EffectivePolicy,
        [Parameter(Mandatory)]$CorpusIntegrity,
        [Parameter(Mandatory)]$RunSetConsistency,
        [Parameter(Mandatory)]$AdjudicationResult,
        [Parameter(Mandatory)]$CandidateHoldoutMetrics,
        [Parameter(Mandatory)]$Comparison,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$HoldoutScopes,
        [Parameter(Mandatory)][int]$DegradedExamples,
        [Parameter(Mandatory)][int]$UnknownExamples,
        [Parameter(Mandatory)][int]$MissingExamples
    )
    $global = [System.Collections.Generic.List[string]]::new()
    foreach ($reason in @($CorpusIntegrity.ReasonCodes)) { [void]$global.Add($reason) }
    foreach ($reason in @($RunSetConsistency.ReasonCodes)) { [void]$global.Add($reason) }
    foreach ($reason in @($AdjudicationResult.ReasonCodes)) { [void]$global.Add($reason) }

    $population = $CorpusIntegrity.Population
    if ($null -eq $population) { [void]$global.Add("corpusSchemaInvalid") }
    else {
        if ([int]$population.seedExamples -gt 0) { [void]$global.Add("seedCorpus") }
        if ([int]$population.qualifyingExamples -lt 1) { [void]$global.Add("zeroQualifyingExamples") }
        if ([int]$population.totalExamples -lt [int]$EffectivePolicy.minExamples) { [void]$global.Add("belowMinimumExamples") }
        if ([int]$population.calibrationExamples -lt [int]$EffectivePolicy.minCalibrationExamples) {
            [void]$global.Add("belowMinimumCalibrationExamples")
        }
        if ([int]$population.holdoutExamples -lt [int]$EffectivePolicy.minHoldoutExamples) {
            [void]$global.Add("belowMinimumHoldoutExamples")
        }
        foreach ($entry in @($population.byStratum)) {
            if ([int]$entry.total -lt [int]$EffectivePolicy.minPerStratumExamples) { [void]$global.Add("stratumUnpopulated") }
        }
    }
    if ($DegradedExamples -gt 0) { [void]$global.Add("evidenceDegraded") }
    if ($UnknownExamples -gt 0) { [void]$global.Add("evidenceUnknown") }
    if ($MissingExamples -gt 0) { [void]$global.Add("evidenceMissing") }

    $coverage = $AdjudicationResult.Coverage
    if ($null -eq $coverage) { [void]$global.Add("denominatorZero") }
    elseif ([double]$coverage -lt [double]$EffectivePolicy.minAdjudicationCoverage) {
        [void]$global.Add("adjudicationCoverageBelowFloor")
    }
    $kappa = $AdjudicationResult.Kappa
    if ($null -eq $kappa) { [void]$global.Add("labelAgreementUndefined") }
    elseif ([double]$kappa -lt [double]$EffectivePolicy.minLabelAgreementKappa) {
        [void]$global.Add("labelAgreementBelowFloor")
    }
    $globalCodes = @(Get-ReviewerEvalUniqueReasonCodes -Reasons $global.ToArray())

    # --- Requirement 1: unattended important/critical comments ---------------
    $commentReasons = [System.Collections.Generic.List[string]]::new()
    foreach ($code in $globalCodes) { [void]$commentReasons.Add($code) }
    $eligible = [int]$CandidateHoldoutMetrics.eligibleUnattendedFindings
    $eligibleTp = [int]$CandidateHoldoutMetrics.eligibleTruePositives
    if ($eligible -lt [int]$EffectivePolicy.minEligibleHoldoutFindings) { [void]$commentReasons.Add("sampleCountBelowFloor") }
    $eligiblePrecision = $CandidateHoldoutMetrics.eligiblePrecision
    if ($null -eq $eligiblePrecision) { [void]$commentReasons.Add("denominatorZero") }
    elseif ($eligible -le 0) { [void]$commentReasons.Add("denominatorZero") }
    else {
        # Exact rational comparison, not a float one: truePositives/n >= floor
        # becomes truePositives * gridDenominator >= floorNumerator * n.
        $precisionPointNumerator = ConvertTo-ReviewerEvalGridNumerator `
            -Value ([double]$EffectivePolicy.minCommentPrecision) -Role floor
        if (([int64]$eligibleTp * [int64]$script:ReviewerEvalBoundGridDenominator) -lt
            ([int64]$precisionPointNumerator * [int64]$eligible)) {
            [void]$commentReasons.Add("precisionBelowFloor")
        }
    }
    $precisionFloorNumerator = ConvertTo-ReviewerEvalGridNumerator `
        -Value ([double]$EffectivePolicy.minCommentPrecisionLowerBound95) -Role floor
    $lowerBoundOk = $false
    if ($eligible -gt 0) {
        if ($eligible -gt [int]$EffectivePolicy.maxExactTrials) { [void]$commentReasons.Add("sampleCountAboveExactCeiling") }
        else {
            $lowerBoundOk = Test-ReviewerEvalLowerBoundAtLeast -Successes $eligibleTp -Trials $eligible `
                -ThresholdNumerator $precisionFloorNumerator `
                -ThresholdDenominator $script:ReviewerEvalBoundGridDenominator `
                -AlphaNumerator ([int]$EffectivePolicy.alphaNumerator) `
                -AlphaDenominator ([int]$EffectivePolicy.alphaDenominator)
        }
    }
    if (-not $lowerBoundOk) { [void]$commentReasons.Add("precisionLowerBoundBelowFloor") }

    # "Zero critical false positives" only means something with a denominator:
    # an arm that produced no critical claims at all has zero critical false
    # positives too, and that must not read as a passing veto.
    $criticalAdjudicated = [int]$CandidateHoldoutMetrics.criticalAdjudicatedClaims
    $criticalFalsePositives = [int]$CandidateHoldoutMetrics.criticalFalsePositives
    if ($criticalAdjudicated -eq 0) { [void]$commentReasons.Add("criticalStratumEmpty") }
    elseif ($criticalAdjudicated -lt [int]$EffectivePolicy.minCriticalAdjudicatedClaims) {
        [void]$commentReasons.Add("sampleCountBelowFloor")
    }
    if ($criticalFalsePositives -gt 0) { [void]$commentReasons.Add("criticalFalsePositivesPresent") }
    $criticalRateCeiling = ConvertTo-ReviewerEvalGridNumerator `
        -Value ([double]$EffectivePolicy.maxCriticalFalsePositiveRate) -Role ceiling
    $criticalBoundOk = $false
    if ($criticalAdjudicated -gt 0 -and $criticalAdjudicated -le [int]$EffectivePolicy.maxExactTrials) {
        $criticalBoundOk = Test-ReviewerEvalUpperBoundAtMost -Successes $criticalFalsePositives `
            -Trials $criticalAdjudicated -ThresholdNumerator $criticalRateCeiling `
            -ThresholdDenominator $script:ReviewerEvalBoundGridDenominator `
            -AlphaNumerator ([int]$EffectivePolicy.alphaNumerator) `
            -AlphaDenominator ([int]$EffectivePolicy.alphaDenominator)
    }
    if (-not $criticalBoundOk) { [void]$commentReasons.Add("criticalFalsePositiveBoundAboveCeiling") }

    if ([int]$Comparison.inventoryCount -le 0 -or -not [bool]$Comparison.denominatorsAgree) {
        [void]$commentReasons.Add("recallDenominatorZero")
    }
    if (-not [bool]$Comparison.withinCeiling) { [void]$commentReasons.Add("recallRegressionAboveCeiling") }

    # A scope list that declares no important/critical scope would otherwise
    # delete the per-scope evidence requirement entirely - the loop below
    # simply would not run - and would also drop the Bonferroni penalty to k=1.
    # "No declared scope" is an absence of evidence, not a pass.
    $commentScopeDeclared = @(@($EffectivePolicy.qualifiableScopes) | Where-Object {
            $script:ReviewerEvalUnattendedCommentSeverities -ccontains [string]$_.severity
        }).Count -gt 0
    if (-not $commentScopeDeclared) { [void]$commentReasons.Add("commentScopeNotDeclared") }
    foreach ($scope in @($HoldoutScopes)) {
        if ($script:ReviewerEvalUnattendedCommentSeverities -cnotcontains [string]$scope.severity) { continue }
        if ([int]$scope.sampleCount -lt 1) { [void]$commentReasons.Add("sampleCountBelowFloor") }
        if ($null -eq $scope.precisionLowerBound95) { [void]$commentReasons.Add("boundUndefined") }
        elseif ([double]$scope.precisionLowerBound95 -lt [double]$EffectivePolicy.minCommentPrecisionLowerBound95) {
            [void]$commentReasons.Add("precisionLowerBoundBelowFloor")
        }
    }
    $commentCodes = @(Get-ReviewerEvalUniqueReasonCodes -Reasons $commentReasons.ToArray())

    # --- Requirement 2: suggestions stay preview-only ------------------------
    $suggestionReasons = [System.Collections.Generic.List[string]]::new()
    foreach ($code in $globalCodes) { [void]$suggestionReasons.Add($code) }
    $suggestionScopeDeclared = @(@($EffectivePolicy.qualifiableScopes) |
            Where-Object { [string]$_.severity -ceq "suggestion" }).Count -gt 0
    if (-not [bool]$EffectivePolicy.suggestionQualificationEnabled) { [void]$suggestionReasons.Add("suggestionsPreviewOnly") }
    if (-not $suggestionScopeDeclared) { [void]$suggestionReasons.Add("suggestionScopeNotDeclared") }
    foreach ($scope in @($HoldoutScopes)) {
        if ([string]$scope.severity -cne "suggestion") { continue }
        if ([int]$scope.sampleCount -lt [int]$EffectivePolicy.minEligibleHoldoutFindings) {
            [void]$suggestionReasons.Add("sampleCountBelowFloor")
        }
        if ($null -eq $scope.precisionLowerBound95) { [void]$suggestionReasons.Add("boundUndefined") }
        elseif ([double]$scope.precisionLowerBound95 -lt [double]$EffectivePolicy.minCommentPrecisionLowerBound95) {
            [void]$suggestionReasons.Add("precisionLowerBoundBelowFloor")
        }
    }
    $suggestionCodes = @(Get-ReviewerEvalUniqueReasonCodes -Reasons $suggestionReasons.ToArray())

    # --- Requirement 3: approval voting --------------------------------------
    $approvalReasons = [System.Collections.Generic.List[string]]::new()
    foreach ($code in $globalCodes) { [void]$approvalReasons.Add($code) }
    $decisions = [int]$CandidateHoldoutMetrics.voteDecisions
    $wouldApprove = [int]$CandidateHoldoutMetrics.wouldApproveCount
    $falseApprovals = [int]$CandidateHoldoutMetrics.falseApprovalCount
    if ($decisions -lt [int]$EffectivePolicy.minApprovalDecisions) { [void]$approvalReasons.Add("sampleCountBelowFloor") }
    if ($wouldApprove -eq 0) { [void]$approvalReasons.Add("approvalStratumEmpty") }
    elseif ($wouldApprove -lt [int]$EffectivePolicy.minWouldApproveDecisions) { [void]$approvalReasons.Add("sampleCountBelowFloor") }
    if ($falseApprovals -gt 0) { [void]$approvalReasons.Add("falseApprovalsPresent") }
    $falseApprovalCeiling = ConvertTo-ReviewerEvalGridNumerator `
        -Value ([double]$EffectivePolicy.maxFalseApprovalRate) -Role ceiling
    $approvalBoundOk = $false
    $falseApprovalUpperBound = $null
    if ($wouldApprove -gt 0 -and $wouldApprove -le [int]$EffectivePolicy.maxExactTrials) {
        $approvalBoundOk = Test-ReviewerEvalUpperBoundAtMost -Successes $falseApprovals -Trials $wouldApprove `
            -ThresholdNumerator $falseApprovalCeiling `
            -ThresholdDenominator $script:ReviewerEvalBoundGridDenominator `
            -AlphaNumerator ([int]$EffectivePolicy.alphaNumerator) `
            -AlphaDenominator ([int]$EffectivePolicy.alphaDenominator)
        $falseApprovalUpperBound = Get-ReviewerEvalUpperBoundGrid -Successes $falseApprovals -Trials $wouldApprove `
            -AlphaNumerator ([int]$EffectivePolicy.alphaNumerator) `
            -AlphaDenominator ([int]$EffectivePolicy.alphaDenominator) `
            -MaxExactTrials ([int]$EffectivePolicy.maxExactTrials)
    }
    if (-not $approvalBoundOk) { [void]$approvalReasons.Add("falseApprovalBoundAboveCeiling") }
    $approvalCodes = @(Get-ReviewerEvalUniqueReasonCodes -Reasons $approvalReasons.ToArray())

    $eligibleLowerBound = $null
    if ($eligible -gt 0) {
        $eligibleLowerBound = Get-ReviewerEvalLowerBoundGrid -Successes $eligibleTp -Trials $eligible `
            -AlphaNumerator ([int]$EffectivePolicy.alphaNumerator) `
            -AlphaDenominator ([int]$EffectivePolicy.alphaDenominator) `
            -MaxExactTrials ([int]$EffectivePolicy.maxExactTrials)
    }
    $criticalUpperBound = $null
    if ($criticalAdjudicated -gt 0) {
        $criticalUpperBound = Get-ReviewerEvalUpperBoundGrid -Successes $criticalFalsePositives `
            -Trials $criticalAdjudicated -AlphaNumerator ([int]$EffectivePolicy.alphaNumerator) `
            -AlphaDenominator ([int]$EffectivePolicy.alphaDenominator) `
            -MaxExactTrials ([int]$EffectivePolicy.maxExactTrials)
    }

    $requirements = @(
        [pscustomobject][ordered]@{
            id          = "unattendedImportantCriticalComments"
            ok          = ($commentCodes.Count -eq 0)
            reasonCodes = $commentCodes
            observed    = [pscustomobject][ordered]@{
                eligibleHoldoutFindings           = $eligible
                truePositives                     = $eligibleTp
                falsePositives                    = [int]$CandidateHoldoutMetrics.eligibleFalsePositives
                precision                         = $eligiblePrecision
                precisionLowerBound95             = $eligibleLowerBound
                criticalAdjudicatedClaims         = $criticalAdjudicated
                criticalFalsePositives            = $criticalFalsePositives
                criticalFalsePositiveUpperBound95 = $criticalUpperBound
                recallRegressionUpperBound95      = $Comparison.regressionUpperBound95
            }
        },
        [pscustomobject][ordered]@{
            id          = "unattendedSuggestionComments"
            ok          = ($suggestionCodes.Count -eq 0)
            reasonCodes = $suggestionCodes
            observed    = [pscustomobject][ordered]@{
                separatelyQualified = [bool]$EffectivePolicy.suggestionQualificationEnabled
                scopeDeclared       = $suggestionScopeDeclared
            }
        },
        [pscustomobject][ordered]@{
            id          = "approvalVote"
            ok          = ($approvalCodes.Count -eq 0)
            reasonCodes = $approvalCodes
            observed    = [pscustomobject][ordered]@{
                labeledDecisions          = $decisions
                wouldApproveCount         = $wouldApprove
                falseApprovalCount        = $falseApprovals
                falseApprovalUpperBound95 = $falseApprovalUpperBound
                voteAccuracy              = $CandidateHoldoutMetrics.voteAccuracy
            }
        }
    )
    return [pscustomobject][ordered]@{
        boundMethod      = [string]$EffectivePolicy.boundMethod
        alphaNumerator   = [int]$EffectivePolicy.alphaNumerator
        alphaDenominator = [int]$EffectivePolicy.alphaDenominator
        scopeCount       = [int]$EffectivePolicy.scopeCount
        globalVetoes     = $globalCodes
        requirements     = $requirements
        anyQualified     = (@($requirements | Where-Object { [bool]$_.ok }).Count -gt 0)
        allQualified     = (@($requirements | Where-Object { -not [bool]$_.ok }).Count -eq 0)
    }
}

# ---------------------------------------------------------------------------
# Report assembly. Auditable, replayable, and structurally non-promotable.
# ---------------------------------------------------------------------------

$script:ReviewerEvalReportTopKeys = @(
    "kind", "artifactVersion", "schemaVersion", "reportVersion", "generatedAtEpochSeconds",
    "toolBinding", "corpusBinding", "derivationSha256", "observationsSha256",
    "corpusPopulation", "adjudicationQuality", "arms", "comparison", "qualification",
    "transcriptionInput", "promotable", "authorizes"
)
$script:ReviewerEvalToolBindingKeys = @(
    "evaluationLibrarySha256", "harnessToolSha256", "importToolSha256", "evaluationPolicySha256",
    "corpusSchemaSha256", "runSchemaSha256", "adjudicationSchemaSha256", "reportSchemaSha256",
    "evaluationToolSha256"
)
$script:ReviewerEvalReportMetricKeys = @(
    "arm", "partition", "completeExamples", "degradedExamples", "unknownExamples", "missingExamples",
    "rawClaims", "rawResolvedClaims", "rawTruePositives", "rawFalsePositives", "rawPrecision",
    "uniqueClaims", "uniqueResolvedClaims", "uniqueTruePositives", "uniqueFalsePositives",
    "uniqueClaimPrecision", "duplicateClaims", "duplicateRate", "severityComparableClaims",
    "severityAccurateClaims", "severityAccuracy", "inventoryItems", "inventoryMatched",
    "inventoryCorrectnessItems", "inventoryCorrectnessMatched", "correctnessRecall",
    "inventoryConventionItems", "inventoryConventionMatched", "conventionRecall", "issueClassRecall",
    "eligibleUnattendedFindings", "eligibleTruePositives", "eligibleFalsePositives",
    "eligiblePrecision", "criticalAdjudicatedClaims", "criticalFalsePositives", "voteDecisions",
    "voteCorrect", "voteAccuracy", "wouldApproveCount", "falseApprovalCount",
    "shouldApproveDecisions", "approveCorrectDecisions", "approvalRecall", "latencyMsMedian",
    "latencyMsP95", "latencyMsTotal", "inputTokens", "outputTokens", "costMicroUsd"
)

function ConvertTo-ReviewerEvalReportMetrics {
    <# Projects a metrics object down to the reportable fields, dropping the
       internal matched-issue sets used for the paired comparison. #>
    param([Parameter(Mandatory)]$Metrics)
    $projected = [ordered]@{}
    foreach ($name in $script:ReviewerEvalReportMetricKeys) {
        $projected[$name] = $Metrics.PSObject.Properties[$name].Value
    }
    return [pscustomobject]$projected
}

function Get-ReviewerEvalToolBinding {
    <# One composite hash over EVERY file that can change a number: the
       library where the math lives, both tools, the policy, and all four
       schemas. Binding a qualification to the harness entry point alone would
       let the scoring code change freely underneath it. This composite is
       what an operator passes to the reviewer's -GateEvaluationToolSha256. #>
    param([Parameter(Mandatory)][hashtable]$FileHashes)
    $binding = [ordered]@{}
    foreach ($name in $script:ReviewerEvalToolBindingKeys) {
        if ($name -ceq "evaluationToolSha256") { continue }
        $value = [string]$FileHashes[$name]
        if ($value -notmatch '^[0-9a-f]{64}$') { throw "Tool binding '$name' must be a lowercase hex SHA-256." }
        $binding[$name] = $value
    }
    $composite = Get-ReviewerEvalDomainSha256 -Domain "toolBinding" -Value ([pscustomobject]$binding)
    $binding["evaluationToolSha256"] = $composite
    return [pscustomobject]$binding
}

function New-ReviewerEvalReport {
    <# Pure assembly of an already-computed evaluation into the sealed report
       shape. Given identical inputs and an identical -GeneratedAtEpochSeconds
       it produces byte-identical canonical JSON, which is what makes replay
       verification meaningful. #>
    param(
        [Parameter(Mandatory)][int]$ReportVersion,
        [Parameter(Mandatory)][int64]$GeneratedAtEpochSeconds,
        [Parameter(Mandatory)]$ToolBinding,
        [Parameter(Mandatory)]$Corpus,
        [Parameter(Mandatory)]$CorpusIntegrity,
        [Parameter(Mandatory)]$RunSetConsistency,
        [Parameter(Mandatory)]$AdjudicationResult,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ArmMetrics,
        [Parameter(Mandatory)]$Comparison,
        [Parameter(Mandatory)]$Qualification,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$HoldoutScopes,
        [Parameter(Mandatory)]$EffectivePolicy
    )
    $freeze = Get-ReviewerVerificationValue $Corpus "freeze"
    $population = $CorpusIntegrity.Population

    $deficits = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $population) {
        if ([int]$population.totalExamples -lt [int]$EffectivePolicy.minExamples) { [void]$deficits.Add("belowMinimumExamples") }
        if ([int]$population.calibrationExamples -lt [int]$EffectivePolicy.minCalibrationExamples) {
            [void]$deficits.Add("belowMinimumCalibrationExamples")
        }
        if ([int]$population.holdoutExamples -lt [int]$EffectivePolicy.minHoldoutExamples) {
            [void]$deficits.Add("belowMinimumHoldoutExamples")
        }
        if ([int]$population.seedExamples -gt 0) { [void]$deficits.Add("seedRecordsPresent") }
        if ([int]$population.qualifyingExamples -lt 1) { [void]$deficits.Add("zeroQualifyingExamples") }
        foreach ($entry in @($population.byStratum)) {
            if ([int]$entry.total -lt [int]$EffectivePolicy.minPerStratumExamples) { [void]$deficits.Add("stratumUnpopulated") }
        }
    }

    $derivations = [System.Collections.Generic.List[object]]::new()
    $observations = [System.Collections.Generic.List[object]]::new()
    foreach ($arm in $script:ReviewerEvalArms) {
        if (-not $RunSetConsistency.ByArm.ContainsKey($arm)) { continue }
        $run = $RunSetConsistency.ByArm[$arm]
        [void]$derivations.Add((Get-ReviewerVerificationValue $run "derivation"))
        [void]$observations.Add((Get-ReviewerVerificationValue $run "observations"))
    }

    $reportMetrics = [System.Collections.Generic.List[object]]::new()
    foreach ($metrics in @($ArmMetrics)) { [void]$reportMetrics.Add((ConvertTo-ReviewerEvalReportMetrics -Metrics $metrics)) }

    $anySeed = ($null -ne $population -and [int]$population.seedExamples -gt 0)
    $transcriptionScopes = [System.Collections.Generic.List[object]]::new()
    foreach ($scope in @($HoldoutScopes)) {
        [void]$transcriptionScopes.Add([pscustomobject][ordered]@{
                pack                  = [string]$scope.pack
                severity              = [string]$scope.severity
                sampleCount           = [int]$scope.sampleCount
                truePositives         = [int]$scope.truePositives
                falsePositives        = [int]$scope.falsePositives
                precision             = $scope.precision
                precisionLowerBound95 = $scope.precisionLowerBound95
                recall                = $scope.recall
                recallLowerBound95    = $scope.recallLowerBound95
                boundMethod           = [string]$scope.boundMethod
            })
    }
    $approvalObserved = @(@($Qualification.requirements | Where-Object { [string]$_.id -ceq "approvalVote" }) |
            Select-Object -First 1)
    if (@($approvalObserved).Count -eq 0) { throw "The qualification result is missing its approvalVote requirement." }
    $approvalObserved = $approvalObserved[0].observed
    $candidateHoldout = @(@($ArmMetrics) | Where-Object {
            [string]$_.arm -ceq $script:ReviewerEvalCandidateArm -and [string]$_.partition -ceq "holdout"
        } | Select-Object -First 1)
    $candidateHoldout = $(if (@($candidateHoldout).Count -gt 0) { $candidateHoldout[0] } else { $null })

    $manifest = [ordered]@{
        kind                    = $script:ReviewerEvalReportKind
        artifactVersion         = $script:ReviewerEvalArtifactVersion
        schemaVersion           = $script:ReviewerEvalSchemaVersion
        reportVersion           = $ReportVersion
        generatedAtEpochSeconds = $GeneratedAtEpochSeconds
        toolBinding             = $ToolBinding
        corpusBinding           = [ordered]@{
            name          = [string](Get-ReviewerVerificationValue $Corpus "name" "")
            corpusVersion = [int](Get-ReviewerVerificationValue $Corpus "corpusVersion" 0)
            corpusSha256  = [string](Get-ReviewerVerificationValue $freeze "corpusSha256" "")
            exampleCount  = [int](Get-ReviewerVerificationValue $freeze "exampleCount" 0)
        }
        # Split deliberately: two executions of the same arms reproduce the
        # derivation subtree but never the observation subtree (latency, tokens,
        # and therefore cost are wall-clock facts, not deterministic outputs).
        # Replay equality is asserted on derivationSha256 alone.
        derivationSha256        = Get-ReviewerEvalDomainSha256 -Domain "derivationSet" -Value @($derivations.ToArray())
        observationsSha256      = Get-ReviewerEvalDomainSha256 -Domain "observationSet" -Value @($observations.ToArray())
        corpusPopulation        = [ordered]@{
            totalExamples       = $(if ($population) { [int]$population.totalExamples } else { 0 })
            qualifyingExamples  = $(if ($population) { [int]$population.qualifyingExamples } else { 0 })
            seedExamples        = $(if ($population) { [int]$population.seedExamples } else { 0 })
            calibrationExamples = $(if ($population) { [int]$population.calibrationExamples } else { 0 })
            holdoutExamples     = $(if ($population) { [int]$population.holdoutExamples } else { 0 })
            byStratum           = $(if ($population) { @($population.byStratum) } else { @() })
            required            = [ordered]@{
                minExamples            = [int]$EffectivePolicy.minExamples
                minCalibrationExamples = [int]$EffectivePolicy.minCalibrationExamples
                minHoldoutExamples     = [int]$EffectivePolicy.minHoldoutExamples
                minPerStratumExamples  = [int]$EffectivePolicy.minPerStratumExamples
            }
            deficits            = @(Get-ReviewerEvalOrdinalSorted -Values $deficits.ToArray())
        }
        adjudicationQuality     = [ordered]@{
            presentedClaims  = [int]$AdjudicationResult.Presented
            resolvedClaims   = [int]$AdjudicationResult.Resolved
            abstainedClaims  = [int]$AdjudicationResult.Abstained
            disputedClaims   = [int]$AdjudicationResult.Disputed
            coverage         = $AdjudicationResult.Coverage
            disagreementRate = $AdjudicationResult.DisagreementRate
            fleissKappa      = $AdjudicationResult.Kappa
            floors           = [ordered]@{
                minAdjudicationCoverage = [double]$EffectivePolicy.minAdjudicationCoverage
                minLabelAgreementKappa  = [double]$EffectivePolicy.minLabelAgreementKappa
            }
        }
        arms                    = @($reportMetrics.ToArray())
        comparison              = $Comparison
        qualification           = $Qualification
        # Field-for-field the layer-6 qualification shape, so an operator
        # transcribes rather than reshapes. This is NOT a qualification: it is
        # unsigned by any gate domain, carries no agent binding, and authorizes
        # nothing. Producing a signed qualification stays a deliberate human
        # act through tools/New-ReviewerGateQualification.ps1.
        transcriptionInput      = [ordered]@{
            nonQualifying = ($anySeed -or -not [bool]$Qualification.anyQualified)
            authorizes    = "none"
            corpus        = [ordered]@{
                name         = [string](Get-ReviewerVerificationValue $Corpus "name" "")
                version      = [string][int](Get-ReviewerVerificationValue $Corpus "corpusVersion" 0)
                repositoryId = [string](Get-ReviewerVerificationValue (Get-ReviewerVerificationValue $Corpus "corpusPin") "repositoryId" "")
                commitSha    = [string](Get-ReviewerVerificationValue (Get-ReviewerVerificationValue $Corpus "corpusPin") "commitSha" "")
                itemCount    = [int](Get-ReviewerVerificationValue $freeze "exampleCount" 0)
                sha256       = [string](Get-ReviewerVerificationValue $freeze "corpusSha256" "")
            }
            comment       = [ordered]@{ scopes = @($transcriptionScopes.ToArray()) }
            approval      = [ordered]@{
                sampleCount               = [int]$approvalObserved.labeledDecisions
                wouldApproveCount         = [int]$approvalObserved.wouldApproveCount
                falseApprovalCount        = [int]$approvalObserved.falseApprovalCount
                falseApprovalUpperBound95 = $approvalObserved.falseApprovalUpperBound95
                boundMethod               = [string]$EffectivePolicy.boundMethod
                recall                    = $(if ($candidateHoldout) { $candidateHoldout.approvalRecall } else { $null })
                recallLowerBound95        = $(
                    if ($candidateHoldout -and [int]$candidateHoldout.shouldApproveDecisions -gt 0) {
                        Get-ReviewerEvalLowerBoundGrid -Successes ([int]$candidateHoldout.approveCorrectDecisions) `
                            -Trials ([int]$candidateHoldout.shouldApproveDecisions) `
                            -AlphaNumerator ([int]$EffectivePolicy.alphaNumerator) `
                            -AlphaDenominator ([int]$EffectivePolicy.alphaDenominator) `
                            -MaxExactTrials ([int]$EffectivePolicy.maxExactTrials)
                    }
                    else { $null }
                )
            }
        }
        promotable              = $false
        authorizes              = "none"
    }
    return [pscustomobject]$manifest
}

# ---------------------------------------------------------------------------
# Evaluation-only signing key.
#
# Deliberately NOT the reviewer's artifact-signing.key. Domain separation stops
# artifact CONFUSION; it does nothing about key POSSESSION. Whoever holds the
# reviewer state directory's key can mint a reviewer-gate-qualification and a
# reviewer-gate-decision, so an evaluation harness that opened that file would
# be handing that capability to every host that ever runs an evaluation - a CI
# runner, a shared build agent, a future automated job.
#
# The refusal below is by leaf name, so it is a guard-rail against the obvious
# operator mistake rather than a security boundary: a copy or a rename defeats
# it. The actual boundary is that this library has no code path that emits a
# gate or delivery kind at all, and seals only under derived
# devpilot.reviewer.evaluation.<domain>.v1 keys.
#
# Evaluation sealing is tamper-evidence over an audit trail. It is not, and is
# not intended to be, a delivery trust root.
# ---------------------------------------------------------------------------

function Get-ReviewerEvalSigningKey {
    param([Parameter(Mandatory)][string]$KeyPath)
    $leaf = Split-Path -Leaf $KeyPath
    if ($leaf -ieq "artifact-signing.key") {
        throw ("The evaluation harness refuses to open 'artifact-signing.key'. That key signs reviewer gate " +
            "decisions and qualifications; an evaluation run must never be able to mint one. Use a separate " +
            "evaluation state directory with its own 'evaluation-signing.key'.")
    }
    if (Test-Path -LiteralPath $KeyPath) {
        $line = (Get-Content -LiteralPath $KeyPath -Raw).Trim()
        $format = $(if ($IsWindows) { 'dpapi' } else { 'raw' })
        $separator = $line.IndexOf(':')
        if ($separator -gt 0) {
            $format = $line.Substring(0, $separator)
            $line = $line.Substring($separator + 1)
        }
        $stored = [System.Convert]::FromBase64String($line)
        switch ($format) {
            'raw' { return , $stored }
            'dpapi' {
                try {
                    return , [System.Security.Cryptography.ProtectedData]::Unprotect(
                        $stored, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
                }
                catch { throw "The evaluation signing key at $KeyPath could not be decrypted for this user: $($_.Exception.Message)" }
            }
            default { throw "The evaluation signing key at $KeyPath declares an unknown storage format '$format'." }
        }
    }
    $key = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($key)
    $toStore = $key
    $storedFormat = 'raw'
    if ($IsWindows) {
        try {
            $toStore = [System.Security.Cryptography.ProtectedData]::Protect(
                $key, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
            $storedFormat = 'dpapi'
        }
        catch { Write-Warning "DPAPI is unavailable; the evaluation signing key is stored unencrypted at $KeyPath." }
    }
    Set-Content -LiteralPath $KeyPath -Value ("${storedFormat}:" + [System.Convert]::ToBase64String($toStore)) -Encoding ascii
    return , $key
}

function Get-ReviewerEvalFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
