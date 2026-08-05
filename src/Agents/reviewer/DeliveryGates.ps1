#requires -Version 7.0

<#
    Delivery gates: fail-closed comment and approval-vote eligibility over the
    SEALED cross-verification preview (CrossVerification.ps1 + the wrapper's
    Invoke-ReviewerCrossVerificationPass artifacts).

    This library never changes discovery, specialist, clustering, or verifier
    behavior, and never mutates an existing preview artifact - it only reads
    the sealed decision/input previews that already exist. Everything here is
    pure (no MCP, no ADO/GitHub call, no network, no write). The wrapper
    (Start-ReviewerAgent.ps1) is the only place that performs a revalidation
    session read or a write.

    Load order: this file assumes CrossVerification.ps1 has ALREADY been dot-
    sourced into the same scope, and reuses its canonicalizer, SHA-256 helper,
    HMAC signer/verifier, and generic value accessor rather than re-implementing
    them (the gate is a security boundary; the verification canonicalizer
    throws on duplicate keys, non-finite numbers, and unsupported types, where
    the delivery canonicalizer silently stringifies). A gate artifact is sealed
    under its OWN HMAC domain, entirely separate from both the verification
    domains and the raw delivery master key, so a verification or delivery
    artifact can never be misread as a gate artifact and vice versa.
#>

Set-StrictMode -Version Latest

foreach ($requiredVerificationFunction in @(
        "ConvertTo-ReviewerVerificationCanonicalJson", "Get-ReviewerVerificationSha256",
        "Get-ReviewerVerificationObjectSha256", "Get-ReviewerVerificationSignature",
        "Test-ReviewerVerificationSignature", "Get-ReviewerVerificationValue"
    )) {
    if (-not (Get-Command $requiredVerificationFunction -ErrorAction SilentlyContinue)) {
        throw ("DeliveryGates.ps1 requires CrossVerification.ps1 to already be dot-sourced into this scope " +
            "(missing '$requiredVerificationFunction'). Dot-source CrossVerification.ps1 first.")
    }
}

$script:ReviewerGateUtf8 = [System.Text.UTF8Encoding]::new($false, $true)

# ---------------------------------------------------------------------------
# Code-defined ceilings. Policy (out-of-repo) may only NARROW a cap and only
# RAISE a floor; it can never widen either direction past these values. See
# ConvertTo-ReviewerGateEffectivePolicy for the direction table.
# ---------------------------------------------------------------------------

$script:ReviewerGateModes = @(
    "off", "shadow", "preview", "humanPromote",
    "unattendedComment", "unattendedCommentAndSuggestion", "approvalVote"
)
$script:ReviewerGateSeverities = @("critical", "important", "suggestion")
# critical is deliberately absent: a false critical is the most expensive false
# positive this agent can produce, and a policy file cannot restore it here -
# only a human reading humanPromotedComment output ever sees one. suggestion IS
# structurally reachable here (unlike critical) but is additionally gated by
# its own SuggestionGateEnabled flag in Test-ReviewerGateCandidateEligible -
# "separately qualified suggestions" requires policy AND scope AND CLI, not
# just this ceiling.
$script:ReviewerGateUnattendedSeverityCeiling = @("important", "suggestion")
$script:ReviewerGateHumanPromotedSeverityCeiling = @("critical", "important", "suggestion")

$script:ReviewerGateMaxCommentsPerRun = 3
$script:ReviewerGateMaxSuggestionsPerRun = 2
$script:ReviewerGateMaxDecisionAgeSeconds = 1800
$script:ReviewerGateMaxQualificationAgeDays = 90
$script:ReviewerGateMinPrecisionFloor = 0.90
$script:ReviewerGateMinRecallFloor = 0.50
$script:ReviewerGateMinCommentSamples = 100
$script:ReviewerGateMinApprovalSamples = 150
$script:ReviewerGateMaxApprovalFalsePositives = 0
$script:ReviewerGateMaxPacks = 32
$script:ReviewerGateMaxRequiredCheckNames = 64
$script:ReviewerGateMaxArtifactBytes = 1048576
# Hard, code-defined, and DELIBERATELY not one of the policy-adjustable cap
# keys below: a superseded decision (Invoke-ReviewerGateReplay's expiry or
# binding-mismatch closure) is a deliberate, one-time invitation for exactly
# one fresh full review - but nothing bounds how many TIMES, in a row, at
# the SAME commit, that could happen if every fresh review's own decision
# also failed to complete before expiring or drifting out of binding again.
# Without a hard ceiling here, a persistently slow/flaky delivery path at
# one commit could drive an unbounded number of full model re-runs. No
# policy value can widen this: it is never read from gate-policy.json, never
# exposed as a policy key, and is not part of $script:ReviewerGateCapKeys.
$script:ReviewerGateMaxSupersededRefreshes = 2

# Cap keys: effective = Min(codeCeiling, policyValue). Policy may only narrow.
$script:ReviewerGateCapKeys = @(
    , @("maxCommentsPerRun", 0, [int64]::MaxValue, $script:ReviewerGateMaxCommentsPerRun)
    , @("maxSuggestionsPerRun", 0, [int64]::MaxValue, $script:ReviewerGateMaxSuggestionsPerRun)
    , @("maxDecisionAgeSeconds", 1, [int64]::MaxValue, $script:ReviewerGateMaxDecisionAgeSeconds)
    , @("maxQualificationAgeDays", 1, [int64]::MaxValue, $script:ReviewerGateMaxQualificationAgeDays)
    , @("maxApprovalFalsePositives", 0, [int64]::MaxValue, $script:ReviewerGateMaxApprovalFalsePositives)
)
# Floor keys: effective = Max(codeFloor, policyValue). Policy may only raise -
# Min-ing a floor would let policy LOWER a safety requirement, which is the
# exact inversion of "narrow only".
$script:ReviewerGateFloorKeys = @(
    , @("minPrecisionLowerBound95", 0.0, 1.0, $script:ReviewerGateMinPrecisionFloor)
    , @("minRecallLowerBound95", 0.0, 1.0, $script:ReviewerGateMinRecallFloor)
    , @("minCommentSampleCount", 0, [int64]::MaxValue, $script:ReviewerGateMinCommentSamples)
    , @("minApprovalSampleCount", 0, [int64]::MaxValue, $script:ReviewerGateMinApprovalSamples)
)

# Withheld reasons that prove the missing candidate was safely accounted for
# elsewhere (a duplicate of something already visible, or a rule this agent
# does not implement). Every other reason - including a bounded-run cap like
# candidateLimit/clusterLimit - means real, unexplored territory exists and
# must close the APPROVAL gate (comment gating is unaffected: that candidate
# simply is not posted).
$script:ReviewerGateSafeWithheldReasons = @(
    "duplicateExistingThread", "duplicatePriorAgent", "duplicateCandidate", "unsupported"
)

# Structurally the only vote this path may ever request. There is no
# 'WaitingForAuthor' and no 'ApprovedWithSuggestions' here on purpose: the
# gate's own comment set is separately eligible from its approval set, so a
# suggestions vote could contradict what unattended posting actually
# published, and a vote that blocks a human's PR is never something this
# layer may decide unattended.
$script:ReviewerGateAllowedVotes = @("Approved")

$script:ReviewerGateArtifactVersion = 1
$script:ReviewerGateSchemaVersion = 1
$script:ReviewerGateDecisionKind = "reviewer-gate-decision"
$script:ReviewerGateQualificationKind = "reviewer-gate-qualification"

# Closed reason-code vocabulary. An unrecognized string is rewritten to
# "unrecognizedReasonRewritten" and logged rather than passed through, the same
# discipline CrossVerification.ps1 applies to a verifier's withheld reason.
$script:ReviewerGateReasonCodes = @(
    # Success
    "ok",
    # Policy
    "gateDisabled", "killSwitchEngaged", "modeNotEnabled", "policyInvalid",
    "policyVersionMismatch", "policyWidensCeiling", "providerUnsupported",
    "packDisabled", "packUnknown", "severityDisabled", "suggestionGateDisabled",
    "runCapReached",
    # Qualification
    "qualificationMissing", "qualificationSignatureInvalid", "qualificationExpired",
    "qualificationCorpusMismatch", "qualificationBindingMismatch", "qualificationScopeMissing",
    "qualificationPrecisionBelowFloor", "qualificationRecallBelowFloor",
    "qualificationSampleCountBelowFloor", "qualificationFalseApprovalsPresent",
    "qualificationToolMismatch",
    # Artifact / binding
    "artifactMissing", "artifactSignatureInvalid", "artifactKindRejected",
    "artifactVersionUnsupported", "artifactDomainMismatch", "decisionExpired",
    "decisionBindingMismatch", "inputArtifactMissing", "inputArtifactSignatureInvalid",
    "inputBindingMismatch", "scriptShaMismatch", "configShaMismatch", "policyShaMismatch",
    "qualificationShaMismatch", "gateLibraryShaMismatch",
    # Verification state
    "verificationDegraded", "verificationIncomplete", "candidateAccountingMismatch",
    "candidateNotVerified", "candidateWithheld", "needsHumanPresent",
    "unknownWithheldReason", "specialistDegraded", "generalistPassIncomplete",
    "generalistPairMismatch", "generalistVoteNotApprove",
    # World freshness
    "sourceCommitMoved", "targetCommitMoved", "changeSetMoved", "changeSetUnreadable",
    "prNotActive", "prIsDraft", "anchorNotInChangeSet", "threadDedupeHit",
    "priorAgentDedupeHit", "threadStatusUnknown", "blockingHumanThreadOpen",
    "authoritativeSourceUnreadable", "authoritativeSourceChanged", "evidenceHunkMismatch",
    # Approval-only
    "checksUnavailable", "checksIncomplete", "checksFailed", "checksNotConfigured",
    "dismissStaleReviewsUnknown", "dismissStaleReviewsDisabled", "eligibilityFirstSeenThisRun",
    "canaryConfirmationMissing", "votePreviouslyCast", "commentDeliveryIncomplete",
    # Gate-delivery record lifecycle (not candidate-level; see "Gate-delivery
    # state machine" in docs/delivery-gates.md)
    "gateProcessingFaulted", "supersededRefreshBudgetExhausted",
    # Monotonicity
    "promotionWouldAdd", "promotionWouldReword", "promotionWouldRaiseSeverity",
    "promotionWouldRelocate",
    # VerifiedMultiPass mint preconditions (Test-ReviewerVerifiedMultiPassPreconditions)
    "verificationNotStructurallyPossible", "prIdMismatch", "decisionSourceCommitMismatch",
    "runNotOk", "runReasonCodesPresent", "verificationInputShaMissing",
    "verificationDecisionShaMissing", "sealedPassCountBelowTwo", "revalidationFailed",
    "coverageNotSealedSubset", "approvalCoverageMalformed", "authorizationRefused",
    # Safety net for an unrecognized string
    "unrecognizedReasonRewritten"
)

function ConvertTo-ReviewerGateReasonCode {
    <# Rewrites any string outside the closed vocabulary to a safe, logged
       default rather than letting it flow into a sealed artifact unchecked. #>
    param([AllowEmptyString()][string]$Reason = "")
    if ($script:ReviewerGateReasonCodes -ccontains $Reason) { return $Reason }
    return "unrecognizedReasonRewritten"
}

function Get-ReviewerGateUniqueReasonCodes {
    param([string[]]$Reasons = @())
    $seen = [System.Collections.Generic.List[string]]::new()
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($reason in @($Reasons)) {
        $safe = ConvertTo-ReviewerGateReasonCode -Reason ([string]$reason)
        if ($set.Add($safe)) { [void]$seen.Add($safe) }
    }
    return , ($seen.ToArray())
}

# ---------------------------------------------------------------------------
# Generic key-exactness check. Deliberately NOT a dependency on the wrapper's
# Assert-ReviewerExactObjectKeys, so this library stays independently
# dot-sourceable and testable (mirrors CrossVerification.ps1's own
# self-containment). Returns a bool rather than throwing: an operator-supplied
# qualification/policy that fails shape validation must close the gate with a
# reason code, not crash the reviewer cycle.
# ---------------------------------------------------------------------------

function Test-ReviewerGateExactKeys {
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

# ---------------------------------------------------------------------------
# Effective policy: validate + clamp. T-6: direction is per-key, not uniform.
# ---------------------------------------------------------------------------

function ConvertTo-ReviewerGateEffectivePolicy {
    param([Parameter(Mandatory)]$Policy)
    if ([int](Get-ReviewerVerificationValue $Policy "schemaVersion" 0) -ne 1) {
        throw "Gate policy 'schemaVersion' must be exactly 1."
    }
    $mode = [string](Get-ReviewerVerificationValue $Policy "mode" "")
    if ($script:ReviewerGateModes -cnotcontains $mode) {
        throw "Gate policy 'mode' must be one of: $($script:ReviewerGateModes -join ', ')."
    }
    $effective = [ordered]@{
        schemaVersion = 1
        policyVersion = [int](Get-ReviewerVerificationValue $Policy "policyVersion" 0)
        mode          = $mode
    }
    if ($effective.policyVersion -lt 1) { throw "Gate policy 'policyVersion' must be a positive integer." }

    foreach ($entry in @($script:ReviewerGateCapKeys)) {
        $name = [string]$entry[0]; $min = $entry[1]; $max = $entry[2]; $codeCeiling = $entry[3]
        $raw = Get-ReviewerVerificationValue $Policy $name $null
        if ($null -eq $raw -or -not ($raw -is [int] -or $raw -is [long] -or $raw -is [double]) -or
            [double]$raw -lt $min -or [double]$raw -gt $max -or [double]$raw -ne [Math]::Floor([double]$raw)) {
            throw "Gate policy '$name' must be a non-negative integer."
        }
        $effective[$name] = [Math]::Min([int64]$raw, [int64]$codeCeiling)
    }
    foreach ($entry in @($script:ReviewerGateFloorKeys)) {
        $name = [string]$entry[0]; $min = $entry[1]; $max = $entry[2]; $codeFloor = $entry[3]
        $raw = Get-ReviewerVerificationValue $Policy $name $null
        if ($null -eq $raw -or -not ($raw -is [int] -or $raw -is [long] -or $raw -is [double])) {
            throw "Gate policy '$name' must be a number."
        }
        if ([double]$raw -lt $min -or [double]$raw -gt $max) {
            throw "Gate policy '$name' must be from $min through $max."
        }
        if ($codeFloor -is [double]) {
            $effective[$name] = [Math]::Max([double]$raw, [double]$codeFloor)
        }
        else {
            $effective[$name] = [Math]::Max([int64]$raw, [int64]$codeFloor)
        }
    }
    foreach ($name in @("requirePriorRunEligibility", "requireCanaryConfirmation")) {
        $raw = Get-ReviewerVerificationValue $Policy $name $null
        if ($raw -isnot [bool]) { throw "Gate policy '$name' must be a boolean." }
        # These may only be TIGHTENED (true) relative to... there is no code
        # floor to raise past $true, so the raw value is used as-is; the code
        # ceiling for "may this ever be false" is enforced by requiring the
        # operator to opt in per policyVersion, not by this table.
        $effective[$name] = [bool]$raw
    }

    $severitiesRaw = Get-ReviewerVerificationValue $Policy "severities"
    if (-not (Test-ReviewerGateExactKeys -Object $severitiesRaw -Allowed $script:ReviewerGateSeverities)) {
        throw "Gate policy 'severities' must declare exactly: $($script:ReviewerGateSeverities -join ', ')."
    }
    $effectiveSeverities = [ordered]@{}
    foreach ($severity in $script:ReviewerGateSeverities) {
        $cell = Get-ReviewerVerificationValue $severitiesRaw $severity
        if (-not (Test-ReviewerGateExactKeys -Object $cell -Allowed @("unattendedComment", "humanPromotedComment"))) {
            throw "Gate policy 'severities.$severity' must declare exactly unattendedComment/humanPromotedComment."
        }
        $unattended = [bool](Get-ReviewerVerificationValue $cell "unattendedComment" $null)
        $humanPromoted = [bool](Get-ReviewerVerificationValue $cell "humanPromotedComment" $null)
        # Code ceiling: critical can NEVER be unattended, no matter what the
        # policy says. This is a hardcoded override, not a default.
        if ($severity -ceq "critical") { $unattended = $false }
        if ($script:ReviewerGateUnattendedSeverityCeiling -cnotcontains $severity) { $unattended = $false }
        if ($script:ReviewerGateHumanPromotedSeverityCeiling -cnotcontains $severity) { $humanPromoted = $false }
        $effectiveSeverities[$severity] = [pscustomobject][ordered]@{
            unattendedComment    = $unattended
            humanPromotedComment = $humanPromoted
        }
    }
    $effective["severities"] = [pscustomobject]$effectiveSeverities

    $packsRaw = @(Get-ReviewerVerificationValue $Policy "packs" @())
    if ($packsRaw.Count -gt $script:ReviewerGateMaxPacks) {
        throw "Gate policy 'packs' declares $($packsRaw.Count) entries, above the code-defined $($script:ReviewerGateMaxPacks)-entry cap."
    }
    $packNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $effectivePacks = [System.Collections.Generic.List[object]]::new()
    foreach ($pack in $packsRaw) {
        if (-not (Test-ReviewerGateExactKeys -Object $pack -Allowed @("name", "unattendedComment", "humanPromotedComment"))) {
            throw "Every gate policy pack entry must declare exactly name/unattendedComment/humanPromotedComment."
        }
        $name = [string](Get-ReviewerVerificationValue $pack "name" "")
        if (-not $name -or -not $packNames.Add($name)) {
            throw "Gate policy pack names must be non-empty and unique."
        }
        [void]$effectivePacks.Add([pscustomobject][ordered]@{
                name                 = $name
                unattendedComment    = [bool](Get-ReviewerVerificationValue $pack "unattendedComment" $false)
                humanPromotedComment = [bool](Get-ReviewerVerificationValue $pack "humanPromotedComment" $false)
            })
    }
    $effective["packs"] = $effectivePacks.ToArray()

    $approvalRaw = Get-ReviewerVerificationValue $Policy "approval"
    $approvalKeys = @("enabled", "requireChecks", "requiredCheckNames", "requireDismissStaleReviews", "allowOperatorAttestedDismissal")
    if (-not (Test-ReviewerGateExactKeys -Object $approvalRaw -Allowed $approvalKeys)) {
        throw "Gate policy 'approval' must declare exactly: $($approvalKeys -join ', ')."
    }
    $requiredCheckNames = @(Get-ReviewerVerificationValue $approvalRaw "requiredCheckNames" @())
    if ($requiredCheckNames.Count -gt $script:ReviewerGateMaxRequiredCheckNames) {
        throw "Gate policy 'approval.requiredCheckNames' exceeds the code-defined $($script:ReviewerGateMaxRequiredCheckNames)-entry cap."
    }
    foreach ($checkName in $requiredCheckNames) {
        if ($checkName -isnot [string] -or -not $checkName.Trim()) {
            throw "Gate policy 'approval.requiredCheckNames' entries must be non-empty strings."
        }
    }
    $effective["approval"] = [pscustomobject][ordered]@{
        enabled                        = [bool](Get-ReviewerVerificationValue $approvalRaw "enabled" $false)
        requireChecks                  = [bool](Get-ReviewerVerificationValue $approvalRaw "requireChecks" $true)
        requiredCheckNames             = @($requiredCheckNames | ForEach-Object { [string]$_ })
        requireDismissStaleReviews     = [bool](Get-ReviewerVerificationValue $approvalRaw "requireDismissStaleReviews" $true)
        # Accepted for schema completeness. NEVER consulted by Test-ReviewerGateApproval:
        # there is no human-attested vote-casting path in this layer, so honoring
        # this flag for an unattended vote would let operator self-attestation
        # substitute for a positive provider read. See docs/delivery-gates.md.
        allowOperatorAttestedDismissal = [bool](Get-ReviewerVerificationValue $approvalRaw "allowOperatorAttestedDismissal" $false)
    }
    return [pscustomobject]$effective
}

# ---------------------------------------------------------------------------
# HMAC domain separation and sealed artifact envelope.
# ---------------------------------------------------------------------------

function Get-ReviewerGateDomainKey {
    param(
        [Parameter(Mandatory)][byte[]]$MasterKey,
        [Parameter(Mandatory)][ValidateSet("decision", "qualification")][string]$Domain
    )
    $label = "devpilot.reviewer.gate.$Domain.v1"
    $hmac = [Security.Cryptography.HMACSHA256]::new($MasterKey)
    try { return , $hmac.ComputeHash($script:ReviewerGateUtf8.GetBytes($label)) }
    finally { $hmac.Dispose() }
}

function Save-ReviewerGateArtifact {
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$BaseName,
        [Parameter(Mandatory)][byte[]]$MasterKey,
        [Parameter(Mandatory)][ValidateSet("decision", "qualification")][string]$Domain,
        [ValidateRange(1024, [int]::MaxValue)][int]$MaxArtifactBytes = $script:ReviewerGateMaxArtifactBytes
    )
    if ($BaseName -notmatch '^[A-Za-z0-9._-]+$') { throw "Gate artifact base name is unsafe." }
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        throw "Gate artifact directory '$Directory' does not exist."
    }
    $manifestJson = ConvertTo-ReviewerVerificationCanonicalJson -Value $Manifest
    $effectiveMaxArtifactBytes = [Math]::Min($MaxArtifactBytes, $script:ReviewerGateMaxArtifactBytes)
    if ($script:ReviewerGateUtf8.GetByteCount($manifestJson) -gt $effectiveMaxArtifactBytes) {
        throw "Gate artifact exceeded the effective $effectiveMaxArtifactBytes-byte cap."
    }
    $key = Get-ReviewerGateDomainKey -MasterKey $MasterKey -Domain $Domain
    $envelope = [ordered]@{
        manifestJson = $manifestJson
        signatureAlg = "HMACSHA256"
        signature    = Get-ReviewerVerificationSignature -Json $manifestJson -Key $key
    }
    $path = Join-Path $Directory ($BaseName + ".json")
    $nonce = [Guid]::NewGuid().ToString("N")
    $tempPath = "$path.$nonce.tmp"
    try {
        [IO.File]::WriteAllText($tempPath, ($envelope | ConvertTo-Json -Depth 4), $script:ReviewerGateUtf8)
        Move-Item -LiteralPath $tempPath -Destination $path -Force
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
    }
    return $path
}

function Read-ReviewerGateArtifact {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][byte[]]$MasterKey,
        [Parameter(Mandatory)][ValidateSet("decision", "qualification")][string]$Domain,
        [ValidateRange(1024, [int]::MaxValue)][int]$MaxArtifactBytes = $script:ReviewerGateMaxArtifactBytes
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Gate artifact '$Path' does not exist." }
    $effectiveMaxArtifactBytes = [Math]::Min($MaxArtifactBytes, $script:ReviewerGateMaxArtifactBytes)
    if ((Get-Item -LiteralPath $Path).Length -gt $effectiveMaxArtifactBytes) {
        throw "Gate artifact '$Path' exceeds the effective $effectiveMaxArtifactBytes-byte cap."
    }
    $envelope = [IO.File]::ReadAllText($Path, $script:ReviewerGateUtf8) | ConvertFrom-Json -Depth 8
    $manifestJson = [string](Get-ReviewerVerificationValue $envelope "manifestJson" "")
    $signature = [string](Get-ReviewerVerificationValue $envelope "signature" "")
    if ([string](Get-ReviewerVerificationValue $envelope "signatureAlg" "") -cne "HMACSHA256") {
        throw "Gate artifact signature algorithm is invalid."
    }
    $key = Get-ReviewerGateDomainKey -MasterKey $MasterKey -Domain $Domain
    if (-not $manifestJson -or
        -not (Test-ReviewerVerificationSignature -Json $manifestJson -Key $key -Signature $signature)) {
        throw "Gate artifact signature verification failed."
    }
    $manifest = $manifestJson | ConvertFrom-Json -Depth 32
    $expectedKind = if ($Domain -ceq "decision") { $script:ReviewerGateDecisionKind } else { $script:ReviewerGateQualificationKind }
    if (-not (Test-ReviewerGateArtifactKind -Kind ([string](Get-ReviewerVerificationValue $manifest "kind" "")) -ExpectedKind $expectedKind) -or
        [int](Get-ReviewerVerificationValue $manifest "artifactVersion" 0) -ne $script:ReviewerGateArtifactVersion) {
        throw "Gate artifact kind or version is invalid."
    }
    return $manifest
}

function Test-ReviewerGateArtifactKind {
    <# Rejects a raw delivery manifest (no 'kind' field at all), a
       verification-input-preview, and a verification-decision-preview: only
       the exact expected gate kind ever matches. #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Kind,
        [string]$ExpectedKind = $script:ReviewerGateDecisionKind
    )
    return ($Kind -ceq $ExpectedKind)
}

function Save-ReviewerGateDecision {
    param(
        [Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$BaseName, [Parameter(Mandatory)][byte[]]$MasterKey,
        [ValidateRange(1024, [int]::MaxValue)][int]$MaxArtifactBytes = $script:ReviewerGateMaxArtifactBytes
    )
    return Save-ReviewerGateArtifact -Manifest $Manifest -Directory $Directory -BaseName $BaseName `
        -MasterKey $MasterKey -Domain decision -MaxArtifactBytes $MaxArtifactBytes
}

function Read-ReviewerGateDecision {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][byte[]]$MasterKey)
    return Read-ReviewerGateArtifact -Path $Path -MasterKey $MasterKey -Domain decision
}

function Save-ReviewerGateQualification {
    param(
        [Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$BaseName, [Parameter(Mandatory)][byte[]]$MasterKey,
        [ValidateRange(1024, [int]::MaxValue)][int]$MaxArtifactBytes = $script:ReviewerGateMaxArtifactBytes
    )
    return Save-ReviewerGateArtifact -Manifest $Manifest -Directory $Directory -BaseName $BaseName `
        -MasterKey $MasterKey -Domain qualification -MaxArtifactBytes $MaxArtifactBytes
}

function Read-ReviewerGateQualification {
    <# Envelope verify -> kind/version (via Read-ReviewerGateArtifact) -> exact
       top-level schema keys. Never throws on a malformed-but-well-signed
       qualification (an operator error, not a programming error): returns
       Ok=$false with a reason code so the caller can log and close instead of
       crashing the whole reviewer cycle over an optional artifact. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][byte[]]$MasterKey)
    $manifest = $null
    try {
        $manifest = Read-ReviewerGateArtifact -Path $Path -MasterKey $MasterKey -Domain qualification
    }
    catch {
        return [pscustomobject][ordered]@{ Ok = $false; ReasonCodes = @("qualificationSignatureInvalid"); Qualification = $null }
    }
    $topKeys = @(
        "kind", "artifactVersion", "schemaVersion", "qualificationVersion", "issuedAtUtc", "expiresAtUtc",
        "evaluationToolSha256", "corpus", "agentBinding", "comment", "approval"
    )
    if (-not (Test-ReviewerGateExactKeys -Object $manifest -Allowed $topKeys) -or
        [int](Get-ReviewerVerificationValue $manifest "qualificationVersion" 0) -lt 1) {
        return [pscustomobject][ordered]@{ Ok = $false; ReasonCodes = @("qualificationBindingMismatch"); Qualification = $null }
    }
    return [pscustomobject][ordered]@{ Ok = $true; ReasonCodes = @(); Qualification = $manifest }
}

function Get-ReviewerGateStableDateTimeText {
    <#
        ConvertFrom-Json (PowerShell 7+) auto-detects an ISO-8601-shaped JSON
        string and silently rehydrates it as a [DateTime] .NET object rather
        than leaving it as a string - a documented ConvertFrom-Json behavior,
        not something this codebase's JSON handling does deliberately. A bare
        [string] cast of that DateTime then calls its parameterless
        ToString(), which renders using the PROCESS'S CURRENT CULTURE: on a
        machine whose locale orders day/month differently, or has no "Z"/
        offset marker in its short format, the resulting text can silently
        misparse under TryParse(..., InvariantCulture, RoundtripKind, ...) -
        or parse to the WRONG instant without even failing. That would make
        the same sealed decision or qualification read as expired on one
        machine and current on another, which a fail-closed expiry check must
        never depend on. This normalizes either shape (a value a test built
        directly as a string, or one ConvertFrom-Json coerced to DateTime)
        back to invariant, culture-independent round-trip ("o") text first.
    #>
    param($Value)
    if ($Value -is [DateTime]) {
        return $Value.ToString("o", [Globalization.CultureInfo]::InvariantCulture)
    }
    return [string]$Value
}

function Test-ReviewerGateQualificationCurrent {
    <# Expiry, corpus/tool/agent binding against LIVE values. Pure: the caller
       supplies every live value (script/library/prompt/policy/schema hashes,
       generalist model pair, specialist/verifier model names, current time) so
       this stays independently testable without touching disk or the clock in
       a way a test cannot control. #>
    param(
        [Parameter(Mandatory)]$Qualification,
        [Parameter(Mandatory)][hashtable]$LiveBinding,
        [Parameter(Mandatory)][int]$MaxQualificationAgeDays
    )
    $reasons = [System.Collections.Generic.List[string]]::new()
    $issuedAtUtc = Get-ReviewerGateStableDateTimeText (Get-ReviewerVerificationValue $Qualification "issuedAtUtc" "")
    $expiresAtUtc = Get-ReviewerGateStableDateTimeText (Get-ReviewerVerificationValue $Qualification "expiresAtUtc" "")
    $issued = [DateTime]::MinValue
    $expires = [DateTime]::MinValue
    $issuedOk = [DateTime]::TryParse($issuedAtUtc, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind, [ref]$issued)
    $expiresOk = [DateTime]::TryParse($expiresAtUtc, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind, [ref]$expires)
    $now = [DateTime]$LiveBinding.NowUtc
    if (-not $issuedOk -or -not $expiresOk -or $expires -le $issued) {
        [void]$reasons.Add("qualificationExpired")
    }
    else {
        if ($now -ge $expires) { [void]$reasons.Add("qualificationExpired") }
        $effectiveMaxAgeDays = [Math]::Min($MaxQualificationAgeDays, $script:ReviewerGateMaxQualificationAgeDays)
        if (($now - $issued).TotalDays -gt $effectiveMaxAgeDays) { [void]$reasons.Add("qualificationExpired") }
    }
    $agentBinding = Get-ReviewerVerificationValue $Qualification "agentBinding"
    foreach ($pair in @(
            , @("scriptSha256", [string]$LiveBinding.ScriptSha256)
            , @("gateLibrarySha256", [string]$LiveBinding.GateLibrarySha256)
            , @("verificationLibrarySha256", [string]$LiveBinding.VerificationLibrarySha256)
            , @("verificationPromptSha256", [string]$LiveBinding.VerificationPromptSha256)
            , @("verificationPolicySha256", [string]$LiveBinding.VerificationPolicySha256)
            , @("verificationSchemaSha256", [string]$LiveBinding.VerificationSchemaSha256)
            , @("conventionSpecialistModel", [string]$LiveBinding.ConventionSpecialistModel)
            , @("conventionVerifierModel", [string]$LiveBinding.ConventionVerifierModel)
        )) {
        $qualValue = [string](Get-ReviewerVerificationValue $agentBinding ([string]$pair[0]) "")
        if (-not [string]::Equals($qualValue, [string]$pair[1], [StringComparison]::Ordinal)) {
            [void]$reasons.Add("qualificationBindingMismatch")
        }
    }
    $qualModels = @(@(Get-ReviewerVerificationValue $agentBinding "generalistModels" @()) | ForEach-Object { [string]$_ } | Sort-Object)
    $liveModels = @(@($LiveBinding.GeneralistModels) | ForEach-Object { [string]$_ } | Sort-Object)
    if (($qualModels -join "|") -cne ($liveModels -join "|")) { [void]$reasons.Add("qualificationBindingMismatch") }

    $corpus = Get-ReviewerVerificationValue $Qualification "corpus"
    if ([string]::IsNullOrWhiteSpace([string](Get-ReviewerVerificationValue $corpus "name" "")) -or
        [int](Get-ReviewerVerificationValue $corpus "itemCount" 0) -lt 1) {
        [void]$reasons.Add("qualificationCorpusMismatch")
    }

    $liveToolSha = [string]$LiveBinding.EvaluationToolSha256
    if ($liveToolSha) {
        $qualToolSha = [string](Get-ReviewerVerificationValue $Qualification "evaluationToolSha256" "")
        if (-not [string]::Equals($qualToolSha, $liveToolSha, [StringComparison]::OrdinalIgnoreCase)) {
            [void]$reasons.Add("qualificationToolMismatch")
        }
    }
    $unique = Get-ReviewerGateUniqueReasonCodes -Reasons $reasons.ToArray()
    if ($unique.Count -eq 0) { return [pscustomobject][ordered]@{ Ok = $true; ReasonCodes = @() } }
    return [pscustomobject][ordered]@{ Ok = $false; ReasonCodes = $unique }
}

function Test-ReviewerGateQualificationSatisfies {
    <# (qualification, aspect, pack, severity) -> Ok/ReasonCodes against the
       EFFECTIVE (already-clamped) policy's sample/precision/recall/false-
       approval floors. Comments care about precision; approval cares about
       recall AND a sample floor high enough that "zero false approvals" means
       something (rule-of-three: 0/n failures bounds the true failure rate at
       roughly 3/n with 95% confidence, so n has to be large before "zero" is a
       real claim rather than a small sample that has not failed yet). #>
    param(
        [Parameter(Mandatory)]$Qualification,
        [Parameter(Mandatory)][ValidateSet("comment", "approval")][string]$Aspect,
        [AllowEmptyString()][string]$Pack = "",
        [AllowEmptyString()][string]$Severity = "",
        [Parameter(Mandatory)]$EffectivePolicy
    )
    $reasons = [System.Collections.Generic.List[string]]::new()
    if ($Aspect -ceq "comment") {
        $commentNode = Get-ReviewerVerificationValue $Qualification "comment"
        $scopes = @(Get-ReviewerVerificationValue $commentNode "scopes" @())
        $matching = @($scopes | Where-Object {
                ([string](Get-ReviewerVerificationValue $_ "pack" "")) -ceq $Pack -and
                ([string](Get-ReviewerVerificationValue $_ "severity" "")) -ceq $Severity
            })
        if ($matching.Count -ne 1) {
            return [pscustomobject][ordered]@{ Ok = $false; ReasonCodes = @("qualificationScopeMissing") }
        }
        $scope = $matching[0]
        if ([int](Get-ReviewerVerificationValue $scope "sampleCount" 0) -lt [int]$EffectivePolicy.minCommentSampleCount) {
            [void]$reasons.Add("qualificationSampleCountBelowFloor")
        }
        if ([double](Get-ReviewerVerificationValue $scope "precisionLowerBound95" 0.0) -lt [double]$EffectivePolicy.minPrecisionLowerBound95) {
            [void]$reasons.Add("qualificationPrecisionBelowFloor")
        }
        if ([double](Get-ReviewerVerificationValue $scope "recallLowerBound95" 0.0) -lt [double]$EffectivePolicy.minRecallLowerBound95) {
            [void]$reasons.Add("qualificationRecallBelowFloor")
        }
    }
    else {
        $approval = Get-ReviewerVerificationValue $Qualification "approval"
        if ([int](Get-ReviewerVerificationValue $approval "sampleCount" 0) -lt [int]$EffectivePolicy.minApprovalSampleCount) {
            [void]$reasons.Add("qualificationSampleCountBelowFloor")
        }
        if ([int](Get-ReviewerVerificationValue $approval "falseApprovalCount" 0) -gt [int]$EffectivePolicy.maxApprovalFalsePositives) {
            [void]$reasons.Add("qualificationFalseApprovalsPresent")
        }
        if ([double](Get-ReviewerVerificationValue $approval "recallLowerBound95" 0.0) -lt [double]$EffectivePolicy.minRecallLowerBound95) {
            [void]$reasons.Add("qualificationRecallBelowFloor")
        }
    }
    $unique = Get-ReviewerGateUniqueReasonCodes -Reasons $reasons.ToArray()
    if ($unique.Count -eq 0) { return [pscustomobject][ordered]@{ Ok = $true; ReasonCodes = @() } }
    return [pscustomobject][ordered]@{ Ok = $false; ReasonCodes = $unique }
}

# ---------------------------------------------------------------------------
# Candidate facets: join the verified/eligible record to its pack via the
# sealed input manifest and convention plan (T-2). The eligible record alone
# carries no ruleSourceId and no pack.
# ---------------------------------------------------------------------------

function Get-ReviewerGateCandidateFacets {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Eligible,
        [Parameter(Mandatory)]$InputManifest,
        $ConventionPlan = $null
    )
    $candidateById = @{}
    foreach ($candidate in @(Get-ReviewerVerificationValue $InputManifest "candidates" @())) {
        $id = [string](Get-ReviewerVerificationValue $candidate "candidateId" "")
        if ($id -and -not $candidateById.ContainsKey($id)) { $candidateById[$id] = $candidate }
    }
    $sourceToPack = @{}
    foreach ($pack in @(Get-ReviewerVerificationValue $ConventionPlan "selectedPacks" @())) {
        $packName = [string](Get-ReviewerVerificationValue $pack "name" "")
        foreach ($source in @(Get-ReviewerVerificationValue $pack "sources" @())) {
            $sourceId = [string](Get-ReviewerVerificationValue $source "sourceId" "")
            if ($sourceId -and -not $sourceToPack.ContainsKey($sourceId)) { $sourceToPack[$sourceId] = $packName }
        }
    }
    $facets = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($Eligible)) {
        $candidateId = [string](Get-ReviewerVerificationValue $item "candidateId" "")
        $originKind = [string](Get-ReviewerVerificationValue $item "originKind" "")
        $ruleSourceId = ""
        if ($candidateById.ContainsKey($candidateId)) {
            $ruleSourceId = [string](Get-ReviewerVerificationValue $candidateById[$candidateId] "ruleSourceId" "")
        }
        $pack = ""
        if ($originKind -ceq "generalist") { $pack = "(generalist)" }
        elseif ($ruleSourceId -and $sourceToPack.ContainsKey($ruleSourceId)) { $pack = $sourceToPack[$ruleSourceId] }
        [void]$facets.Add([pscustomobject][ordered]@{
                candidateId   = $candidateId
                candidateHash = [string](Get-ReviewerVerificationValue $item "candidateHash" "")
                originKind    = $originKind
                pack          = $pack
                severity      = [string](Get-ReviewerVerificationValue $item "severity" "")
                filePath      = [string](Get-ReviewerVerificationValue $item "filePath" "")
                line          = [int](Get-ReviewerVerificationValue $item "line" 0)
                comment       = [string](Get-ReviewerVerificationValue $item "comment" "")
                evidence      = [string](Get-ReviewerVerificationValue $item "evidence" "")
                confidence    = [string](Get-ReviewerVerificationValue $item "confidence" "")
            })
    }
    return $facets.ToArray()
}

function Get-ReviewerGateNormalizedPath {
    param([AllowEmptyString()][string]$Path = "")
    return $Path.Trim().Replace('\', '/').TrimStart('/').TrimEnd('/').ToLowerInvariant()
}

function Test-ReviewerGateCandidateEligible {
    <# Pure predicate over ONE facet + the current world snapshot. Fails closed
       on every unknown: an unknown pack, an unrecognized severity, a thread
       whose status defaulted to "unknown", and a missing anchor are all
       treated as ineligible, never as "assume fine". #>
    param(
        [Parameter(Mandatory)]$Facet,
        [Parameter(Mandatory)]$EffectivePolicy,
        [Parameter(Mandatory)][ValidateSet("unattendedComment", "humanPromotedComment")][string]$Purpose,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ChangedPaths,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ThreadFacts,
        [bool]$SuggestionGateEnabled = $false
    )
    $reasons = [System.Collections.Generic.List[string]]::new()
    $pack = [string]$Facet.pack
    $severity = [string]$Facet.severity

    if (-not $pack) {
        [void]$reasons.Add("packUnknown")
    }
    else {
        $packPolicy = @($EffectivePolicy.packs | Where-Object { [string]$_.name -ceq $pack })
        if ($packPolicy.Count -eq 0) { [void]$reasons.Add("packUnknown") }
        else {
            $allowed = if ($Purpose -ceq "unattendedComment") { [bool]$packPolicy[0].unattendedComment } else { [bool]$packPolicy[0].humanPromotedComment }
            if (-not $allowed) { [void]$reasons.Add("packDisabled") }
        }
    }

    if ($script:ReviewerGateSeverities -cnotcontains $severity) {
        [void]$reasons.Add("severityDisabled")
    }
    else {
        $severityPolicy = Get-ReviewerVerificationValue $EffectivePolicy.severities $severity
        $sevAllowed = if ($Purpose -ceq "unattendedComment") { [bool]$severityPolicy.unattendedComment } else { [bool]$severityPolicy.humanPromotedComment }
        if (-not $sevAllowed) { [void]$reasons.Add("severityDisabled") }
        if ($Purpose -ceq "unattendedComment") {
            if ($severity -ceq "suggestion") {
                # Suggestions are a SEPARATE code ceiling from the plain
                # unattended-comment one: allowed only with the explicit,
                # independently-gated suggestion flag, never by the
                # important-only ceiling array membership check below.
                if (-not $SuggestionGateEnabled) { [void]$reasons.Add("suggestionGateDisabled") }
            }
            elseif ($script:ReviewerGateUnattendedSeverityCeiling -cnotcontains $severity) {
                [void]$reasons.Add("severityDisabled")
            }
        }
    }

    $path = Get-ReviewerGateNormalizedPath -Path ([string]$Facet.filePath)
    $line = [int]$Facet.line
    if (-not $path -or $line -lt 1) {
        # Gate publication v1 requires a valid, CURRENT file+line anchor. Raw
        # delivery still accepts and posts a PR-level finding with no file
        # anchor (self-check 8) - that path is unmodified. This layer never
        # does: without an anchor there is nothing to re-check against the
        # current change set or an existing thread, so treating it as
        # eligible would be exactly the "assume fine" this predicate refuses
        # everywhere else. Safest default: ineligible.
        [void]$reasons.Add("anchorNotInChangeSet")
    }
    else {
        $changedNormalized = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($changedPath in @($ChangedPaths)) {
            $normalized = Get-ReviewerGateNormalizedPath -Path ([string]$changedPath)
            if ($normalized) { [void]$changedNormalized.Add($normalized) }
        }
        if (-not $changedNormalized.Contains($path)) {
            [void]$reasons.Add("anchorNotInChangeSet")
        }
    }

    foreach ($thread in @($ThreadFacts)) {
        $threadPath = Get-ReviewerGateNormalizedPath -Path ([string](Get-ReviewerVerificationValue $thread "filePath" ""))
        $threadLine = [int](Get-ReviewerVerificationValue $thread "line" 0)
        if (-not $path -or $path -cne $threadPath -or $line -ne $threadLine) { continue }
        $status = [string](Get-ReviewerVerificationValue $thread "status" "unknown")
        if ($status -cne "Closed" -and $status -cne "Fixed" -and $status -cne "Active") {
            [void]$reasons.Add("threadStatusUnknown")
        }
        elseif ($status -ceq "Active") {
            [void]$reasons.Add("blockingHumanThreadOpen")
        }
    }

    $unique = Get-ReviewerGateUniqueReasonCodes -Reasons $reasons.ToArray()
    if ($unique.Count -eq 0) { return [pscustomobject][ordered]@{ Ok = $true; ReasonCodes = @() } }
    return [pscustomobject][ordered]@{ Ok = $false; ReasonCodes = $unique }
}

function Test-ReviewerGateVerificationComplete {
    <# T-3: empty is not clean. Requires status=="complete", a real (non-empty,
       non-all-zero) input artifact binding, and the accounting identity: every
       candidate in totalCandidateCount appears exactly once across
       eligible union withheld. Returns the run-level reasons; per-candidate
       reasons are Test-ReviewerGateCandidateEligible's job. #>
    param(
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][AllowEmptyString()][string]$InputArtifactPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$InputManifestSha256,
        [Parameter(Mandatory)][int]$TotalCandidateCount,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Eligible,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Withheld
    )
    $reasons = [System.Collections.Generic.List[string]]::new()
    if ($Status -cne "complete") { [void]$reasons.Add("verificationDegraded") }
    if (-not $InputArtifactPath -or -not $InputManifestSha256 -or $InputManifestSha256 -ceq ("0" * 64)) {
        [void]$reasons.Add("verificationIncomplete")
    }
    $ids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $duplicateOrMissing = $false
    foreach ($item in @($Eligible)) {
        $id = [string](Get-ReviewerVerificationValue $item "candidateId" "")
        if (-not $id -or -not $ids.Add($id)) { $duplicateOrMissing = $true }
    }
    foreach ($item in @($Withheld)) {
        $id = [string](Get-ReviewerVerificationValue $item "candidateId" "")
        if (-not $id -or -not $ids.Add($id)) { $duplicateOrMissing = $true }
        $reason = [string](Get-ReviewerVerificationValue $item "reason" "")
        if ($script:ReviewerVerificationWithheldReasons -cnotcontains $reason) {
            [void]$reasons.Add("unknownWithheldReason")
        }
        if ($reason -ceq "needsHuman") { [void]$reasons.Add("needsHumanPresent") }
    }
    if ($duplicateOrMissing -or $ids.Count -ne $TotalCandidateCount) {
        [void]$reasons.Add("candidateAccountingMismatch")
    }
    $unique = Get-ReviewerGateUniqueReasonCodes -Reasons $reasons.ToArray()
    if ($unique.Count -eq 0) { return [pscustomobject][ordered]@{ Ok = $true; ReasonCodes = @() } }
    return [pscustomobject][ordered]@{ Ok = $false; ReasonCodes = $unique }
}

# ---------------------------------------------------------------------------
# Monotonic manifest key (remove-only promotion/delivery subsetting).
# ---------------------------------------------------------------------------

function Get-ReviewerGateManifestKey {
    <# candidateHash|severity|path|line|sha256(comment). Including the FINAL
       decided severity makes a severity raise structurally impossible: it
       changes the key, so a raised-severity entry can never match the
       originally sealed one and fails the subset test outright. #>
    param([Parameter(Mandatory)]$Entry)
    $comment = [string](Get-ReviewerVerificationValue $Entry "comment" "")
    return ("{0}|{1}|{2}|{3}|{4}" -f `
            ([string](Get-ReviewerVerificationValue $Entry "candidateHash" "")),
        ([string](Get-ReviewerVerificationValue $Entry "severity" "")).ToLowerInvariant(),
        (Get-ReviewerGateNormalizedPath -Path ([string](Get-ReviewerVerificationValue $Entry "filePath" ""))),
        ([int](Get-ReviewerVerificationValue $Entry "line" 0)),
        (Get-ReviewerVerificationSha256 -Text $comment))
}

function Select-ReviewerGateSubset {
    <# Remove-only: returns the entries of $Approved whose key is present in
       $Allowed, preserving $Approved's order. No escape hatch - a caller that
       wants to widen this set is calling the wrong function. #>
    param([object[]]$Approved, [object[]]$Allowed)
    $allowedKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in @($Allowed)) { [void]$allowedKeys.Add((Get-ReviewerGateManifestKey -Entry $item)) }
    $kept = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($Approved)) {
        if ($allowedKeys.Contains((Get-ReviewerGateManifestKey -Entry $item))) { [void]$kept.Add($item) }
    }
    return , ($kept.ToArray())
}

# ---------------------------------------------------------------------------
# Sealed gate decision.
# ---------------------------------------------------------------------------

function Get-ReviewerGateCappedSubset {
    <# Deterministic, severity-first then candidateHash-ascending cap. Used to
       bound how many comments/suggestions a single run may post, mirroring
       the existing per-PR posting cap's determinism without depending on the
       wrapper's own ranking helper (this stays a pure, self-contained library
       function). #>
    param([object[]]$Entries = @(), [int]$MaxCount = 0)
    if ($MaxCount -le 0) { return @() }
    $severityRank = @{ critical = 0; important = 1; suggestion = 2 }
    $ordered = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @($Entries)) { [void]$ordered.Add($entry) }
    $ordered.Sort([System.Comparison[object]] {
            param($left, $right)
            $leftRank = if ($severityRank.ContainsKey([string]$left.severity)) { $severityRank[[string]$left.severity] } else { 99 }
            $rightRank = if ($severityRank.ContainsKey([string]$right.severity)) { $severityRank[[string]$right.severity] } else { 99 }
            if ($leftRank -ne $rightRank) { return $leftRank - $rightRank }
            return [StringComparer]::Ordinal.Compare([string]$left.candidateHash, [string]$right.candidateHash)
        })
    return (@($ordered) | Select-Object -First $MaxCount)
}

function New-ReviewerGateDecision {
    <#
        Pure. Builds the sealed gate-decision body over ALREADY-VALIDATED
        inputs: the caller is responsible for revalidating the world (this
        function does not read anything, it only decides and binds).

        Binding must contain (all strings pre-lowercased/pre-normalized by the
        caller where applicable): prId, repositoryId, organization, project,
        sourceCommit, targetCommit, changeSetDigest, verificationDecisionSha256,
        verificationInputSha256, conventionPlanSha256, factPlanSha256,
        specialistArtifactSha256, packPolicySha256, configSha256, scriptSha256,
        gateLibrarySha256, gatePolicySha256, qualificationSha256,
        verificationLibrarySha256, verificationPromptSha256,
        verificationPolicySha256, verificationSchemaSha256, threadSetDigest,
        checksSnapshotSha256, policySnapshotSha256, passesRequested,
        generalistPassModels.

        passesRequested/generalistPassModels seal how many raw generalist
        passes this decision was actually built from and which of them
        COMPLETED with the exact model pair - sourced by the caller from the
        completed raw-pass artifacts, never from the caller's own live config.
        A later verified-delivery mint reads these SEALED values (never
        $ReviewPassModels) to decide whether this decision may ever back a
        VerifiedMultiPass grant, so a decision sealed under a two-pass config
        cannot be laundered through a process running with fewer configured
        passes later.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Binding,
        [Parameter(Mandatory)]$EffectivePolicy,
        $Qualification = $null,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Facets,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ChangedPaths,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ThreadFacts,
        [Parameter(Mandatory)]$RunAccounting,
        [bool]$SuggestionGateEnabled = $false,
        [AllowEmptyString()][string]$QualificationExpiresAtUtc = "",
        [Parameter(Mandatory)][DateTime]$CreatedAtUtc
    )
    $bindingKeys = @(
        "prId", "repositoryId", "organization", "project", "sourceCommit", "targetCommit",
        "changeSetDigest", "verificationDecisionSha256", "verificationInputSha256",
        "conventionPlanSha256", "factPlanSha256", "specialistArtifactSha256", "packPolicySha256",
        "configSha256", "scriptSha256", "gateLibrarySha256", "gatePolicySha256",
        "qualificationSha256", "verificationLibrarySha256", "verificationPromptSha256",
        "verificationPolicySha256", "verificationSchemaSha256", "threadSetDigest",
        "checksSnapshotSha256", "policySnapshotSha256", "passesRequested", "generalistPassModels"
    )
    foreach ($key in $bindingKeys) {
        if (-not $Binding.ContainsKey($key)) { throw "Gate decision binding is missing '$key'." }
    }

    $candidateEntries = [System.Collections.Generic.List[object]]::new()
    $unattendedComments = [System.Collections.Generic.List[object]]::new()
    $humanPromotable = [System.Collections.Generic.List[object]]::new()

    foreach ($facet in @($Facets)) {
        $unattended = if ($RunAccounting.Ok) {
            Test-ReviewerGateCandidateEligible -Facet $facet -EffectivePolicy $EffectivePolicy `
                -Purpose "unattendedComment" -ChangedPaths $ChangedPaths -ThreadFacts $ThreadFacts `
                -SuggestionGateEnabled:$SuggestionGateEnabled
        }
        else {
            [pscustomobject][ordered]@{ Ok = $false; ReasonCodes = Get-ReviewerGateUniqueReasonCodes -Reasons $RunAccounting.ReasonCodes }
        }
        $humanPromoted = if ($RunAccounting.Ok) {
            Test-ReviewerGateCandidateEligible -Facet $facet -EffectivePolicy $EffectivePolicy `
                -Purpose "humanPromotedComment" -ChangedPaths $ChangedPaths -ThreadFacts $ThreadFacts
        }
        else {
            [pscustomobject][ordered]@{ Ok = $false; ReasonCodes = Get-ReviewerGateUniqueReasonCodes -Reasons $RunAccounting.ReasonCodes }
        }
        $qualificationOk = $true
        $qualificationReasons = @()
        if ($Qualification) {
            $qc = Test-ReviewerGateQualificationSatisfies -Qualification $Qualification -Aspect "comment" `
                -Pack ([string]$facet.pack) -Severity ([string]$facet.severity) -EffectivePolicy $EffectivePolicy
            $qualificationOk = [bool]$qc.Ok
            $qualificationReasons = @($qc.ReasonCodes)
        }
        else {
            $qualificationOk = $false
            $qualificationReasons = @("qualificationMissing")
        }
        $unattendedOk = [bool]$unattended.Ok -and $qualificationOk
        $unattendedReasons = if ([bool]$unattended.Ok) {
            Get-ReviewerGateUniqueReasonCodes -Reasons (@($unattended.ReasonCodes) + @($qualificationReasons))
        }
        else {
            Get-ReviewerGateUniqueReasonCodes -Reasons $unattended.ReasonCodes
        }

        $entry = [pscustomobject][ordered]@{
            candidateId               = [string]$facet.candidateId
            candidateHash             = [string]$facet.candidateHash
            pack                      = [string]$facet.pack
            severity                  = [string]$facet.severity
            filePath                  = [string]$facet.filePath
            line                      = [int]$facet.line
            comment                   = [string]$facet.comment
            gateKey                   = Get-ReviewerGateManifestKey -Entry $facet
            unattendedCommentOk       = $unattendedOk
            unattendedCommentReasons  = @(if ($unattendedOk) { @("ok") } else { $unattendedReasons })
            humanPromotedCommentOk    = [bool]$humanPromoted.Ok
            humanPromotedCommentReasons = @(if ([bool]$humanPromoted.Ok) { @("ok") } else { @($humanPromoted.ReasonCodes) })
        }
        [void]$candidateEntries.Add($entry)
        if ($entry.unattendedCommentOk) { [void]$unattendedComments.Add($entry) }
        if ($entry.humanPromotedCommentOk) { [void]$humanPromotable.Add($entry) }
    }

    $cappedComments = @(Get-ReviewerGateCappedSubset -Entries @($unattendedComments | Where-Object { $_.severity -cne "suggestion" }) `
            -MaxCount ([int]$EffectivePolicy.maxCommentsPerRun))
    $cappedSuggestions = @(Get-ReviewerGateCappedSubset -Entries @($unattendedComments | Where-Object { $_.severity -ceq "suggestion" }) `
            -MaxCount ([int]$EffectivePolicy.maxSuggestionsPerRun))

    $decisionExpiresAtUtc = $CreatedAtUtc.AddSeconds([Math]::Min([int]$EffectivePolicy.maxDecisionAgeSeconds, $script:ReviewerGateMaxDecisionAgeSeconds))

    $runReasonCodesValue = if ([bool]$RunAccounting.Ok) { @() } else { Get-ReviewerGateUniqueReasonCodes -Reasons $RunAccounting.ReasonCodes }
    $manifest = [ordered]@{
        kind                      = $script:ReviewerGateDecisionKind
        artifactVersion           = $script:ReviewerGateArtifactVersion
        schemaVersion             = $script:ReviewerGateSchemaVersion
        mode                      = [string]$EffectivePolicy.mode
        prId                      = [int]$Binding.prId
        repositoryId              = [string]$Binding.repositoryId
        organization              = [string]$Binding.organization
        project                   = [string]$Binding.project
        sourceCommit              = ([string]$Binding.sourceCommit).ToLowerInvariant()
        targetCommit              = ([string]$Binding.targetCommit).ToLowerInvariant()
        changeSetDigest           = ([string]$Binding.changeSetDigest).ToLowerInvariant()
        verificationDecisionSha256 = [string]$Binding.verificationDecisionSha256
        verificationInputSha256   = [string]$Binding.verificationInputSha256
        conventionPlanSha256      = [string]$Binding.conventionPlanSha256
        factPlanSha256            = [string]$Binding.factPlanSha256
        specialistArtifactSha256  = [string]$Binding.specialistArtifactSha256
        packPolicySha256          = [string]$Binding.packPolicySha256
        configSha256              = [string]$Binding.configSha256
        scriptSha256              = [string]$Binding.scriptSha256
        gateLibrarySha256         = [string]$Binding.gateLibrarySha256
        gatePolicySha256          = [string]$Binding.gatePolicySha256
        qualificationSha256       = [string]$Binding.qualificationSha256
        verificationLibrarySha256 = [string]$Binding.verificationLibrarySha256
        verificationPromptSha256  = [string]$Binding.verificationPromptSha256
        verificationPolicySha256  = [string]$Binding.verificationPolicySha256
        verificationSchemaSha256  = [string]$Binding.verificationSchemaSha256
        threadSetDigest           = [string]$Binding.threadSetDigest
        checksSnapshotSha256      = [string]$Binding.checksSnapshotSha256
        policySnapshotSha256      = [string]$Binding.policySnapshotSha256
        passesRequested           = [int]$Binding.passesRequested
        generalistPassModels      = [string]$Binding.generalistPassModels
        runOk                     = [bool]$RunAccounting.Ok
        runReasonCodes            = $runReasonCodesValue
        candidates                = $candidateEntries.ToArray()
        unattendedComments        = $cappedComments
        unattendedSuggestions     = $cappedSuggestions
        humanPromotableComments   = $humanPromotable.ToArray()
        createdAtUtc              = $CreatedAtUtc.ToString("o", [Globalization.CultureInfo]::InvariantCulture)
        decisionExpiresAtUtc      = $decisionExpiresAtUtc.ToString("o", [Globalization.CultureInfo]::InvariantCulture)
        qualificationExpiresAtUtc = $QualificationExpiresAtUtc
    }
    return [pscustomobject]$manifest
}

function Test-ReviewerGateDecisionExpired {
    param([Parameter(Mandatory)]$Decision, [Parameter(Mandatory)][DateTime]$NowUtc)
    $expires = [DateTime]::MinValue
    $text = Get-ReviewerGateStableDateTimeText (Get-ReviewerVerificationValue $Decision "decisionExpiresAtUtc" "")
    if (-not [DateTime]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind, [ref]$expires)) {
        return $true
    }
    return ($NowUtc -ge $expires)
}

function Test-ReviewerGateSupersededBudget {
    <#
        Pure: whether one more supersede (Invoke-ReviewerGateReplay's expiry
        or binding-mismatch closure marking a record superseded=$true, a
        one-time invitation for exactly one fresh full review) is still
        within the hard, code-defined $script:ReviewerGateMaxSupersededRefreshes
        budget for this exact PR+commit, given how many times it has already
        been superseded (CurrentSupersededCount, carried forward from record
        to record as long as the source commit does not change - see
        "Gate-delivery state machine" in docs/delivery-gates.md).

        No escape hatch: this budget is never read from policy, so no
        gate-policy.json, however permissive, can widen it. When the budget
        would be exceeded, NextSupersededCount is deliberately left at
        CurrentSupersededCount unchanged - the count reflects actual
        supersedes, and this attempt does not become one; it closes
        terminally instead.
    #>
    param([Parameter(Mandatory)][int]$CurrentSupersededCount)
    $next = $CurrentSupersededCount + 1
    $withinBudget = ($next -le $script:ReviewerGateMaxSupersededRefreshes)
    return [pscustomobject][ordered]@{
        WithinBudget        = $withinBudget
        NextSupersededCount = $(if ($withinBudget) { $next } else { $CurrentSupersededCount })
    }
}

# ---------------------------------------------------------------------------
# Approval: independent AND, never a modification of the existing raw vote
# gate. Pure: every fact the approval decision depends on is a boolean or
# small value the caller resolved (from live reads or the sealed decision),
# so every precondition is independently testable by flipping one input.
# ---------------------------------------------------------------------------

function Test-ReviewerGateApproval {
    param(
        [Parameter(Mandatory)]$EffectivePolicy,
        $Qualification = $null,
        [Parameter(Mandatory)][bool]$ProviderIsGitHub,
        [Parameter(Mandatory)][bool]$RunAccountingOk,
        [Parameter(Mandatory)][bool]$AllWithheldReasonsSafe,
        [Parameter(Mandatory)][bool]$NoNeedsHumanPresent,
        [Parameter(Mandatory)][bool]$GeneralistPairComplete,
        [Parameter(Mandatory)][bool]$GeneralistBothApprove,
        [Parameter(Mandatory)][bool]$SpecialistOkForApproval,
        [Parameter(Mandatory)][bool]$RawGateApproves,
        [Parameter(Mandatory)][bool]$ChecksKnown,
        [Parameter(Mandatory)][bool]$ChecksAllSuccess,
        [Parameter(Mandatory)][bool]$DismissalKnown,
        [Parameter(Mandatory)][bool]$DismissesStaleReviews,
        [Parameter(Mandatory)][bool]$PriorRunFingerprintMatches,
        [Parameter(Mandatory)][bool]$CanaryConfirmed,
        [Parameter(Mandatory)][bool]$CommitUnchanged,
        [Parameter(Mandatory)][bool]$AuthoritativeSourcesCurrent,
        [Parameter(Mandatory)][bool]$AlreadyVotedThisCommit
    )
    $reasons = [System.Collections.Generic.List[string]]::new()
    if ($EffectivePolicy.mode -cne "approvalVote" -or -not [bool]$EffectivePolicy.approval.enabled) {
        [void]$reasons.Add("modeNotEnabled")
    }
    if (-not $ProviderIsGitHub) { [void]$reasons.Add("providerUnsupported") }
    if (-not $RunAccountingOk) { [void]$reasons.Add("verificationDegraded") }
    if (-not $AllWithheldReasonsSafe) { [void]$reasons.Add("candidateWithheld") }
    if (-not $NoNeedsHumanPresent) { [void]$reasons.Add("needsHumanPresent") }
    if (-not $GeneralistPairComplete) { [void]$reasons.Add("generalistPassIncomplete") }
    if ($GeneralistPairComplete -and -not $GeneralistBothApprove) { [void]$reasons.Add("generalistVoteNotApprove") }
    if (-not $SpecialistOkForApproval) { [void]$reasons.Add("specialistDegraded") }
    if (-not $RawGateApproves) { [void]$reasons.Add("generalistVoteNotApprove") }
    if ([bool]$EffectivePolicy.approval.requireChecks) {
        if (-not $ChecksKnown) { [void]$reasons.Add("checksUnavailable") }
        elseif (-not $ChecksAllSuccess) { [void]$reasons.Add("checksFailed") }
    }
    if ([bool]$EffectivePolicy.approval.requireDismissStaleReviews) {
        if (-not $DismissalKnown) { [void]$reasons.Add("dismissStaleReviewsUnknown") }
        elseif (-not $DismissesStaleReviews) { [void]$reasons.Add("dismissStaleReviewsDisabled") }
    }
    if ([bool]$EffectivePolicy.requirePriorRunEligibility -and -not $PriorRunFingerprintMatches) {
        [void]$reasons.Add("eligibilityFirstSeenThisRun")
    }
    if ([bool]$EffectivePolicy.requireCanaryConfirmation -and -not $CanaryConfirmed) {
        [void]$reasons.Add("canaryConfirmationMissing")
    }
    if (-not $CommitUnchanged) { [void]$reasons.Add("sourceCommitMoved") }
    if (-not $AuthoritativeSourcesCurrent) { [void]$reasons.Add("authoritativeSourceChanged") }
    if ($AlreadyVotedThisCommit) { [void]$reasons.Add("votePreviouslyCast") }
    if ($null -eq $Qualification) {
        [void]$reasons.Add("qualificationMissing")
    }
    else {
        $qc = Test-ReviewerGateQualificationSatisfies -Qualification $Qualification -Aspect "approval" -EffectivePolicy $EffectivePolicy
        if (-not $qc.Ok) { foreach ($reasonCode in $qc.ReasonCodes) { [void]$reasons.Add($reasonCode) } }
    }
    $unique = Get-ReviewerGateUniqueReasonCodes -Reasons $reasons.ToArray()
    if ($unique.Count -eq 0) { return [pscustomobject][ordered]@{ Ok = $true; ReasonCodes = @() } }
    return [pscustomobject][ordered]@{ Ok = $false; ReasonCodes = $unique }
}

function Get-ReviewerGateEligibilityFingerprint {
    <# sha256(canonical(sourceCommit, changeSetDigest, totalCandidateCount,
       decisionSha256, gatePolicySha256)). "No approval in the run eligibility
       was first discovered" needs a definition for the empty set: this
       fingerprint is what a PRIOR run's persisted record is compared against,
       so approval requires a prior run at the SAME commit with the SAME
       fingerprint, never the run that first discovered it. #>
    param(
        [Parameter(Mandatory)][string]$SourceCommit,
        [Parameter(Mandatory)][string]$ChangeSetDigest,
        [Parameter(Mandatory)][int]$TotalCandidateCount,
        [Parameter(Mandatory)][string]$DecisionSha256,
        [Parameter(Mandatory)][string]$GatePolicySha256
    )
    return Get-ReviewerVerificationObjectSha256 -Value ([ordered]@{
            sourceCommit         = $SourceCommit.ToLowerInvariant()
            changeSetDigest      = $ChangeSetDigest.ToLowerInvariant()
            totalCandidateCount  = $TotalCandidateCount
            decisionSha256       = $DecisionSha256
            gatePolicySha256     = $GatePolicySha256
        })
}

function Get-ReviewerGateWritesCurrentlyRequested {
    <#
        Pure: the single, current authority for what layer 6 may attempt
        this run - the CLI switch AND the CURRENT effective policy mode, for
        each capability independently. Every call site that decides whether
        to write - the direct delivery path, a replay, the delivery
        function's own belt-and-braces re-check, and the startup banner -
        computes this the SAME way, so a switch removed or a policy mode
        downgraded since an earlier point is honored everywhere, not just
        wherever happened to compute it first. A persisted "this was
        requested" record from an earlier attempt is an upper bound on what
        a replay may still attempt, never a substitute for asking this
        again - the caller is responsible for intersecting the two.
    #>
    param(
        [Parameter(Mandatory)]$EffectivePolicy,
        [Parameter(Mandatory)][bool]$CommentSwitchOn,
        [Parameter(Mandatory)][bool]$SuggestionSwitchOn,
        [Parameter(Mandatory)][bool]$ApprovalSwitchOn
    )
    $mode = [string]$EffectivePolicy.mode
    $commentModeAllowed = ($mode -cin @("unattendedComment", "unattendedCommentAndSuggestion", "approvalVote"))
    $suggestionModeAllowed = ($mode -cin @("unattendedCommentAndSuggestion", "approvalVote"))
    $approvalModeAllowed = ($mode -ceq "approvalVote" -and [bool]$EffectivePolicy.approval.enabled)
    return [pscustomobject][ordered]@{
        Comments    = ($CommentSwitchOn -and $commentModeAllowed)
        Suggestions = ($SuggestionSwitchOn -and $suggestionModeAllowed)
        Approval    = ($ApprovalSwitchOn -and $approvalModeAllowed)
    }
}

function Test-ReviewerGateDecisionBinding {
    <#
        Pure: re-verifies a SEALED decision's recorded bindings against
        CURRENT live values, called before every write a sealed decision
        could still cause - a human-promoted publish or a replay - so a
        decision sealed under a script, config, gate policy, gate library,
        verification library/prompt/policy/schema, convention-pack policy,
        or qualification that has since changed can no longer authorize
        anything, however recently it was sealed.

        No escape hatch: every key present in LiveBinding is compared
        unconditionally, EXCEPT qualificationSha256, which has one narrow,
        deliberate special case: a sealed value of all-zero (this decision
        never depended on any qualification at all) always matches
        regardless of what is live, so decisions that never needed a
        qualification (e.g. humanPromote mode) are never regressed by a
        qualification being added, removed, or rotated later. Any sealed
        NON-zero qualification hash is still compared unconditionally
        against the live value (including against all-zero, i.e. "no
        qualification currently resolves") - a qualification a decision DID
        depend on can never be silently skipped just because the caller has
        nothing live to compare it against; that is exactly the revoked-
        qualification case this must close. A key the caller does not
        supply at all (because nothing currently live can attest to it yet
        - e.g. source/target/change-set before a revalidation has run) is
        left unchecked rather than defaulted to "match": the caller decides
        what it currently has a live value for, never this function.
    #>
    param(
        [Parameter(Mandatory)]$Decision,
        [Parameter(Mandatory)][hashtable]$LiveBinding
    )
    $reasons = [System.Collections.Generic.List[string]]::new()
    foreach ($pair in @(
            , @("scriptSha256", "scriptShaMismatch")
            , @("configSha256", "configShaMismatch")
            , @("gatePolicySha256", "policyShaMismatch")
            , @("packPolicySha256", "policyShaMismatch")
            , @("gateLibrarySha256", "gateLibraryShaMismatch")
            , @("verificationLibrarySha256", "gateLibraryShaMismatch")
            , @("verificationPromptSha256", "gateLibraryShaMismatch")
            , @("verificationPolicySha256", "gateLibraryShaMismatch")
            , @("verificationSchemaSha256", "gateLibraryShaMismatch")
            , @("repositoryId", "decisionBindingMismatch")
            , @("organization", "decisionBindingMismatch")
            , @("project", "decisionBindingMismatch")
            , @("sourceCommit", "sourceCommitMoved")
            , @("targetCommit", "targetCommitMoved")
            , @("changeSetDigest", "changeSetMoved")
        )) {
        $key = [string]$pair[0]
        if (-not $LiveBinding.ContainsKey($key)) { continue }
        $liveValue = [string]$LiveBinding[$key]
        $sealedValue = [string](Get-ReviewerVerificationValue $Decision $key "")
        if (-not [string]::Equals($sealedValue, $liveValue, [StringComparison]::OrdinalIgnoreCase)) {
            [void]$reasons.Add([string]$pair[1])
        }
    }
    # Special-cased, never folded into the generic loop above: a sealed
    # value of all-zero means this decision never depended on ANY
    # qualification (e.g. a humanPromote-mode decision), so it always
    # passes regardless of whatever qualification happens to be live right
    # now - there is nothing to revoke. A sealed NON-zero value, however,
    # is compared unconditionally against whatever the live value is,
    # INCLUDING all-zero (no qualification currently resolves at all): a
    # decision that DID depend on a qualification must close the instant
    # that qualification is missing, invalid, or its argument is dropped -
    # a revoked qualification can never be silently skipped just because
    # nothing live is available to compare it against.
    if ($LiveBinding.ContainsKey("qualificationSha256")) {
        $sealedQualificationSha256 = [string](Get-ReviewerVerificationValue $Decision "qualificationSha256" "")
        $allZero = ("0" * 64)
        if (-not [string]::Equals($sealedQualificationSha256, $allZero, [StringComparison]::OrdinalIgnoreCase)) {
            $liveQualificationSha256 = [string]$LiveBinding["qualificationSha256"]
            if (-not [string]::Equals($sealedQualificationSha256, $liveQualificationSha256, [StringComparison]::OrdinalIgnoreCase)) {
                [void]$reasons.Add("qualificationShaMismatch")
            }
        }
    }
    $unique = Get-ReviewerGateUniqueReasonCodes -Reasons $reasons.ToArray()
    if ($unique.Count -eq 0) { return [pscustomobject][ordered]@{ Ok = $true; ReasonCodes = @() } }
    return [pscustomobject][ordered]@{ Ok = $false; ReasonCodes = $unique }
}

function Test-ReviewerVerifiedMultiPassPreconditions {
    <#
        Pure, no MCP: the full conjunctive precondition set a VerifiedMultiPass
        grant must satisfy, extracted so tools/Test-DeliveryGates.ps1 can drive
        every refusal reason directly, without a live MCP session, an on-disk
        artifact, or a running wrapper process.

        This is a REFUSAL matrix, never a positive-evidence one: every input
        here can only ADD a reason code (never remove one another added), so
        there is no code path by which policy, qualification, or a caller
        argument alone can force Ok=$true - Ok is $true only when every single
        conjunct independently holds. The caller (the wrapper's sole mint,
        New-ReviewerVerifiedMultiPassAuthorization) is responsible for the
        parts that cannot be pure: reading/verifying the artifact itself
        (HMAC domain + kind), and performing the dedicated fresh revalidation
        whose OUTCOME is passed in here as plain booleans/strings.

        Returns @{ Ok; ReasonCodes }.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('gateComments', 'gateApproval', 'gatePromotion')][string]$Purpose,
        [Parameter(Mandatory)]$Decision,
        [Parameter(Mandatory)][int]$PrId,
        [Parameter(Mandatory)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$CoverageKeys,
        [Parameter(Mandatory)][hashtable]$LiveBinding,
        [Parameter(Mandatory)][DateTime]$NowUtc,
        # Derived ONLY from $IsTwoPass, $EffectiveEnableVerificationPreview, the
        # literal claude-opus-5/gpt-5.6-sol pair, and $EnableConventionSpecialist
        # - never from gate policy (T10): the shape of what can even be
        # ATTEMPTED must never be a function of an out-of-repo policy file.
        [Parameter(Mandatory)][bool]$StructurallyPossible,
        # Narrowing-only signal: gate policy mode 'off' always refuses: never a
        # path to a POSITIVE grant, only ever a way to close one.
        [Parameter(Mandatory)][bool]$GatePolicyIsOff,
        [Parameter(Mandatory)][bool]$RevalidationOk,
        [Parameter(Mandatory)][bool]$PrIsActive,
        [Parameter(Mandatory)][bool]$PrIsDraft,
        [Parameter(Mandatory)][bool]$SourceCommitUnchanged
    )
    $reasons = [System.Collections.Generic.List[string]]::new()
    $allZero = ("0" * 64)

    if (-not $StructurallyPossible) { [void]$reasons.Add("verificationNotStructurallyPossible") }
    if ($GatePolicyIsOff) { [void]$reasons.Add("gateDisabled") }

    if ([int](Get-ReviewerVerificationValue $Decision "prId" -1) -ne $PrId) { [void]$reasons.Add("prIdMismatch") }
    if (-not [string]::Equals([string](Get-ReviewerVerificationValue $Decision "sourceCommit" ""), $ExpectedSourceCommit, [StringComparison]::OrdinalIgnoreCase)) {
        [void]$reasons.Add("decisionSourceCommitMismatch")
    }

    if (Test-ReviewerGateDecisionExpired -Decision $Decision -NowUtc $NowUtc) { [void]$reasons.Add("decisionExpired") }

    $bindingCheck = Test-ReviewerGateDecisionBinding -Decision $Decision -LiveBinding $LiveBinding
    if (-not $bindingCheck.Ok) { foreach ($reason in @($bindingCheck.ReasonCodes)) { [void]$reasons.Add($reason) } }

    if (-not [bool](Get-ReviewerVerificationValue $Decision "runOk" $false)) { [void]$reasons.Add("runNotOk") }
    if (@(Get-ReviewerVerificationValue $Decision "runReasonCodes" @()).Count -gt 0) { [void]$reasons.Add("runReasonCodesPresent") }
    $verificationInputSha256 = [string](Get-ReviewerVerificationValue $Decision "verificationInputSha256" "")
    if (-not $verificationInputSha256 -or $verificationInputSha256 -ceq $allZero) { [void]$reasons.Add("verificationInputShaMissing") }
    $verificationDecisionSha256 = [string](Get-ReviewerVerificationValue $Decision "verificationDecisionSha256" "")
    if (-not $verificationDecisionSha256 -or $verificationDecisionSha256 -ceq $allZero) { [void]$reasons.Add("verificationDecisionShaMissing") }

    # P2/T4/T5: sealed pass count and model pair, read from the DECISION's own
    # sealed binding - never from the caller's live $ReviewPassModels/config, so
    # a decision sealed under a two-pass config cannot be laundered through a
    # process running fewer passes later, and a degraded/incomplete pair (only
    # completion, not request, would miss this) always refuses.
    if ([int](Get-ReviewerVerificationValue $Decision "passesRequested" 0) -lt 2) { [void]$reasons.Add("sealedPassCountBelowTwo") }
    if (-not [bool](Get-ReviewerVerificationValue $Decision "generalistPairComplete" $false)) { [void]$reasons.Add("generalistPassIncomplete") }
    $expectedModelPair = (@("claude-opus-5", "gpt-5.6-sol") | Sort-Object) -join '|'
    if (([string](Get-ReviewerVerificationValue $Decision "generalistPassModels" "")) -cne $expectedModelPair) {
        [void]$reasons.Add("generalistPairMismatch")
    }

    # P8: unexplored territory (an unsafe withheld reason) means the union is
    # not fully verified - required for approval, where a false negative is
    # unrecoverable once a human stops looking.
    if ($Purpose -ceq "gateApproval" -and -not [bool](Get-ReviewerVerificationValue $Decision "allWithheldReasonsSafe" $false)) {
        [void]$reasons.Add("unknownWithheldReason")
    }

    # P9: when the dedicated revalidation session itself could not read live
    # state (RevalidationOk=$false), PrIsActive/PrIsDraft/SourceCommitUnchanged
    # carry no real information at all - the caller has nothing live to report
    # and any value it passes here is a placeholder, never an observation.
    # Short-circuit to the single honest reason (revalidationFailed) rather
    # than ALSO adding prNotActive/sourceCommitMoved fabricated from missing/
    # placeholder data: a transient availability failure must never be
    # reported as if it were a live fact about the PR's state.
    if (-not $RevalidationOk) {
        [void]$reasons.Add("revalidationFailed")
    }
    else {
        if (-not $PrIsActive) { [void]$reasons.Add("prNotActive") }
        if ($PrIsDraft) { [void]$reasons.Add("prIsDraft") }
        if (-not $SourceCommitUnchanged) { [void]$reasons.Add("sourceCommitMoved") }
    }

    # P10: coverage can only ever be a subset of what THIS sealed decision
    # already approved for THIS purpose - never a caller-declared set, and
    # never widened afterward (Select-ReviewerGateSubset/remove-only narrowing
    # is applied again, later, by the caller against LIVE eligibility; this
    # only bounds against the SEALED candidate universe).
    $allowedKeys = $null
    if ($Purpose -ceq "gateComments") {
        $allowedKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($entry in @(@(Get-ReviewerVerificationValue $Decision "unattendedComments" @()) + @(Get-ReviewerVerificationValue $Decision "unattendedSuggestions" @()))) {
            [void]$allowedKeys.Add((Get-ReviewerGateManifestKey -Entry $entry))
        }
    }
    elseif ($Purpose -ceq "gatePromotion") {
        $allowedKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($entry in @(Get-ReviewerVerificationValue $Decision "humanPromotableComments" @())) {
            [void]$allowedKeys.Add((Get-ReviewerGateManifestKey -Entry $entry))
        }
    }
    if ($null -ne $allowedKeys) {
        $outOfCoverage = @(@($CoverageKeys) | Where-Object { -not $allowedKeys.Contains($_) })
        if ($outOfCoverage.Count -gt 0) { [void]$reasons.Add("coverageNotSealedSubset") }
    }
    elseif ($Purpose -ceq "gateApproval") {
        # Approval coverage is not a candidate set at all - a single, fixed
        # sentinel binding the grant to exactly one PR/commit/action, so it
        # can never be reinterpreted as authorizing a comment write.
        $expectedApprovalCoverage = "$PrId|$($ExpectedSourceCommit.ToLowerInvariant())|Approved"
        if (@($CoverageKeys).Count -ne 1 -or ([string]@($CoverageKeys)[0]) -cne $expectedApprovalCoverage) {
            [void]$reasons.Add("approvalCoverageMalformed")
        }
    }

    $unique = Get-ReviewerGateUniqueReasonCodes -Reasons $reasons.ToArray()
    if ($unique.Count -eq 0) { return [pscustomobject][ordered]@{ Ok = $true; ReasonCodes = @() } }
    return [pscustomobject][ordered]@{ Ok = $false; ReasonCodes = $unique }
}

function Test-ReviewerGateWriteConfirmed {
    <#
        Pure: given the fingerprints this delivery intended to have present
        and the fingerprints actually confirmed present after a FRESH
        re-read (never the write replies), decides whether delivery is
        complete. Extracted so "confirm by re-read, never trust the write
        reply" - the same discipline every write in this agent already uses
        - is testable without a live MCP session: a caller simulates a
        partial failure by simply confirming fewer fingerprints than were
        intended, with no session, no write, and no network involved.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$IntendedFingerprints,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$ConfirmedFingerprints
    )
    $posted = @(@($IntendedFingerprints) | Where-Object { $ConfirmedFingerprints.Contains($_) }).Count
    return [pscustomobject][ordered]@{
        Posted   = $posted
        Intended = @($IntendedFingerprints).Count
        Complete = ($posted -eq @($IntendedFingerprints).Count)
    }
}
