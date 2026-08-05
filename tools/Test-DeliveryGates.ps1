#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Offline safety tests for the layer-6 delivery-gate library
    (src/Agents/reviewer/DeliveryGates.ps1).

.DESCRIPTION
    No network, no ADO/GitHub, no Copilot process, no model. Every gate
    decision is a pure function of sealed inputs, so this exercises the
    library directly: effective-policy clamping direction, HMAC domain
    separation and tamper detection, qualification verification and
    threshold boundaries, candidate-facet joining, per-candidate and
    per-run eligibility, monotonic manifest keys/subsetting, and the
    independent approval predicate.

    Wrapper-INTEGRATION behavior (call-ordering invariance, the dedicated
    revalidation session, PromoteVerifiedPreview, replay authority
    re-derivation and decision-binding re-verification, the gate-delivery
    state machine (superseded vs. superseded-budget-exhausted vs. faulted
    vs. delivered/pending-replay), the no-second-raw-delivery gate refresh,
    the raw pending-plan replay guard, the verbatim preservation of a raw
    delivery-plan pointer across a gate-only refresh, and the
    ADO-always-closes-approval property) is covered by self-checks 24-42 in
    Start-ReviewerAgent.ps1 -DryRun, the same way the existing
    verification/specialist integrations are proven there rather than here.

.EXAMPLE
    ./tools/Test-DeliveryGates.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "src\Agents\reviewer\CrossVerification.ps1")
. (Join-Path $repoRoot "src\Agents\reviewer\DeliveryGates.ps1")

$policyPath = Join-Path $repoRoot "src\Agents\reviewer\gates\v1\policy.json"
$policySchemaPath = Join-Path $repoRoot "src\Agents\reviewer\gates\v1\policy.schema.json"
$qualificationSchemaPath = Join-Path $repoRoot "src\Agents\reviewer\gates\v1\qualification.schema.json"
$gateLibraryPath = Join-Path $repoRoot "src\Agents\reviewer\DeliveryGates.ps1"
$wrapperPath = Join-Path $repoRoot "src\Agents\reviewer\Start-ReviewerAgent.ps1"

$null = Get-Content -LiteralPath $policySchemaPath -Raw | ConvertFrom-Json -Depth 32
$null = Get-Content -LiteralPath $qualificationSchemaPath -Raw | ConvertFrom-Json -Depth 32
$defaultPolicy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json -Depth 32
$gateLibraryText = [IO.File]::ReadAllText($gateLibraryPath)
$wrapperText = [IO.File]::ReadAllText($wrapperPath)

$failures = [System.Collections.Generic.List[string]]::new()
$checks = 0

function Assert-Gate {
    param([bool]$Condition, [Parameter(Mandatory)][string]$Message)
    $script:checks++
    if (-not $Condition) { [void]$script:failures.Add($Message) }
}

function Assert-GateThrows {
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$Message)
    $script:checks++
    try { & $Action | Out-Null; [void]$script:failures.Add($Message) } catch {}
}

function Copy-GateObject {
    param([Parameter(Mandatory)]$Value)
    return ($Value | ConvertTo-Json -Depth 32 | ConvertFrom-Json -Depth 32)
}

function New-TestMasterKey {
    $key = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Fill($key)
    return , $key
}

function New-EnabledPolicy {
    <# A policy permissive enough to exercise unattended/approval paths, built
       by mutating a deep copy of the shipped all-off default so every OTHER
       field stays representative of what ships. #>
    param([string]$Mode = "unattendedComment")
    $policy = Copy-GateObject -Value $defaultPolicy
    $policy.mode = $Mode
    $policy.severities.important.unattendedComment = $true
    $policy.severities.suggestion.unattendedComment = $true
    $policy.packs[0].unattendedComment = $true
    $policy.maxSuggestionsPerRun = 2
    $policy.approval.enabled = $true
    return $policy
}

function New-TestQualification {
    param(
        [double]$PrecisionLowerBound95 = 0.97,
        [double]$RecallLowerBound95 = 0.70,
        [int]$CommentSampleCount = 250,
        [int]$ApprovalSampleCount = 200,
        [int]$FalseApprovalCount = 0,
        [string]$Pack = "(generalist)",
        [string]$Severity = "important",
        [hashtable]$AgentBindingOverrides = @{},
        [string]$IssuedAtUtc = ([DateTime]::UtcNow.AddDays(-1).ToString("o")),
        [string]$ExpiresAtUtc = ([DateTime]::UtcNow.AddDays(29).ToString("o"))
    )
    $agentBinding = [ordered]@{
        scriptSha256              = "a" * 64
        gateLibrarySha256         = "b" * 64
        verificationLibrarySha256 = "c" * 64
        verificationPromptSha256  = "d" * 64
        verificationPolicySha256  = "e" * 64
        verificationSchemaSha256  = "f" * 64
        generalistModels          = @("claude-opus-5", "gpt-5.6-sol")
        conventionSpecialistModel = "claude-opus-5"
        conventionVerifierModel   = "gpt-5.6-sol"
    }
    foreach ($key in $AgentBindingOverrides.Keys) { $agentBinding[$key] = $AgentBindingOverrides[$key] }
    return [pscustomobject][ordered]@{
        kind                  = "reviewer-gate-qualification"
        artifactVersion       = 1
        schemaVersion         = 1
        qualificationVersion  = 1
        issuedAtUtc           = $IssuedAtUtc
        expiresAtUtc          = $ExpiresAtUtc
        evaluationToolSha256  = "0" * 64
        corpus                = [pscustomobject][ordered]@{
            name = "synthetic-corpus"; version = "1"; repositoryId = ("a" * 8) + "-" + ("b" * 4) + "-" + ("c" * 4) + "-" + ("d" * 4) + "-" + ("e" * 12)
            commitSha = "1" * 40; itemCount = 214; sha256 = "9" * 64
        }
        agentBinding          = [pscustomobject]$agentBinding
        comment               = [pscustomobject][ordered]@{
            scopes = @([pscustomobject][ordered]@{
                    pack = $Pack; severity = $Severity; sampleCount = $CommentSampleCount
                    truePositives = 61; falsePositives = 2; precision = 0.968
                    precisionLowerBound95 = $PrecisionLowerBound95; recall = 0.72; recallLowerBound95 = $RecallLowerBound95
                    boundMethod = "wilson-1sided-95"
                })
        }
        approval              = [pscustomobject][ordered]@{
            sampleCount = $ApprovalSampleCount; wouldApproveCount = 96; falseApprovalCount = $FalseApprovalCount
            falseApprovalUpperBound95 = 0.02; boundMethod = "ruleOfThree-1sided-95"; recall = 0.74; recallLowerBound95 = $RecallLowerBound95
        }
    }
}

function New-TestFacet {
    param(
        [string]$CandidateId = "cand1:" + ("a" * 64),
        [string]$CandidateHash = ("a" * 64),
        [string]$OriginKind = "generalist",
        [string]$Pack = "(generalist)",
        [string]$Severity = "important",
        [string]$FilePath = "/src/a.cs",
        [int]$Line = 10,
        [string]$Comment = "Fix the null check."
    )
    return [pscustomobject][ordered]@{
        candidateId = $CandidateId; candidateHash = $CandidateHash; originKind = $OriginKind
        pack = $Pack; severity = $Severity; filePath = $FilePath; line = $Line
        comment = $Comment; evidence = "evidence text"; confidence = "high"
    }
}

function New-TestBinding {
    param([hashtable]$Overrides = @{})
    $binding = @{
        prId = 42; repositoryId = "repo-1"; organization = "contoso"; project = "Example"
        sourceCommit = "1" * 40; targetCommit = "2" * 40; changeSetDigest = "3" * 64
        verificationDecisionSha256 = "d" * 64; verificationInputSha256 = "i" * 64
        conventionPlanSha256 = "c" * 64; factPlanSha256 = "f" * 64; specialistArtifactSha256 = "s" * 64
        packPolicySha256 = "p" * 64; configSha256 = "cf" * 64; scriptSha256 = "sc" * 64
        gateLibrarySha256 = "gl" * 32; gatePolicySha256 = "gp" * 32; qualificationSha256 = "q" * 64
        verificationLibrarySha256 = "vl" * 32; verificationPromptSha256 = "vp" * 32
        verificationPolicySha256 = "vpo" * 21 + "vp"; verificationSchemaSha256 = "vs" * 32
        threadSetDigest = "t" * 64; checksSnapshotSha256 = "0" * 64; policySnapshotSha256 = "0" * 64
        passesRequested = 2; generalistPassModels = "claude-opus-5|gpt-5.6-sol"
    }
    foreach ($key in $Overrides.Keys) { $binding[$key] = $Overrides[$key] }
    return $binding
}

function New-Decision {
    param(
        [object[]]$Facets,
        $EffectivePolicy,
        $Qualification = $null,
        [string[]]$ChangedPaths = @("/src/a.cs"),
        [object[]]$ThreadFacts = @(),
        $RunAccounting = [pscustomobject]@{ Ok = $true; ReasonCodes = @() },
        [bool]$SuggestionGateEnabled = $false
    )
    return New-ReviewerGateDecision -Binding (New-TestBinding) -EffectivePolicy $EffectivePolicy -Qualification $Qualification `
        -Facets $Facets -ChangedPaths $ChangedPaths -ThreadFacts $ThreadFacts -RunAccounting $RunAccounting `
        -SuggestionGateEnabled:$SuggestionGateEnabled -CreatedAtUtc ([DateTime]::UtcNow)
}

# ===========================================================================
# 1. Defaults off / kill-switch direction
# ===========================================================================

$offEffective = ConvertTo-ReviewerGateEffectivePolicy -Policy $defaultPolicy
Assert-Gate ($offEffective.mode -ceq "off") "The shipped default policy does not resolve to mode='off'."
Assert-Gate (@($offEffective.packs | Where-Object { [bool]$_.unattendedComment -or [bool]$_.humanPromotedComment -and $_.name -ne "(generalist)" }).Count -ge 0) "Sanity: packs array is readable."
foreach ($severity in @("critical", "important", "suggestion")) {
    Assert-Gate (-not [bool](Get-ReviewerVerificationValue $offEffective.severities $severity).unattendedComment) "Shipped default enables unattended comments for '$severity'."
}
$offDecision = New-Decision -Facets @(New-TestFacet) -EffectivePolicy $offEffective
Assert-Gate (@($offDecision.unattendedComments).Count -eq 0 -and @($offDecision.unattendedSuggestions).Count -eq 0) "A fully-qualifying candidate produced an unattended comment/suggestion under the shipped OFF default."

# ===========================================================================
# 2. Effective-policy clamp direction (T-6): caps narrow, floors only raise
# ===========================================================================

$capPolicy = Copy-GateObject -Value $defaultPolicy
$capPolicy.maxCommentsPerRun = 999999
$capEffective = ConvertTo-ReviewerGateEffectivePolicy -Policy $capPolicy
Assert-Gate ($capEffective.maxCommentsPerRun -eq $script:ReviewerGateMaxCommentsPerRun) "A policy raising maxCommentsPerRun above the code ceiling was not clamped down."

$floorPolicy = Copy-GateObject -Value $defaultPolicy
$floorPolicy.minPrecisionLowerBound95 = 0.01
$floorEffective = ConvertTo-ReviewerGateEffectivePolicy -Policy $floorPolicy
Assert-Gate ($floorEffective.minPrecisionLowerBound95 -eq $script:ReviewerGateMinPrecisionFloor) "A policy lowering minPrecisionLowerBound95 below the code floor was not clamped up (inverted floor direction)."

$raisedFloorPolicy = Copy-GateObject -Value $defaultPolicy
$raisedFloorPolicy.minPrecisionLowerBound95 = 0.99
$raisedFloorEffective = ConvertTo-ReviewerGateEffectivePolicy -Policy $raisedFloorPolicy
Assert-Gate ($raisedFloorEffective.minPrecisionLowerBound95 -eq 0.99) "A policy legitimately RAISING a floor above the code floor was clamped back down."

$falsePositivePolicy = Copy-GateObject -Value $defaultPolicy
$falsePositivePolicy.maxApprovalFalsePositives = 5
$falsePositiveEffective = ConvertTo-ReviewerGateEffectivePolicy -Policy $falsePositivePolicy
Assert-Gate ($falsePositiveEffective.maxApprovalFalsePositives -eq 0) "A policy raising maxApprovalFalsePositives above 0 was not clamped to the code ceiling of 0."

Assert-GateThrows { ConvertTo-ReviewerGateEffectivePolicy -Policy ([pscustomobject]@{ schemaVersion = 1; mode = "not-a-real-mode" }) } "An invalid gate policy mode was accepted."

$criticalOverridePolicy = New-EnabledPolicy
$criticalOverridePolicy.severities.critical.unattendedComment = $true
$criticalOverrideEffective = ConvertTo-ReviewerGateEffectivePolicy -Policy $criticalOverridePolicy
Assert-Gate (-not [bool]$criticalOverrideEffective.severities.critical.unattendedComment) "Policy was able to enable unattended critical comments; the code ceiling must override this unconditionally."

$widenedPacksPolicy = Copy-GateObject -Value $defaultPolicy
$widenedPacksPolicy.packs = @(1..40 | ForEach-Object { [pscustomobject]@{ name = "pack-$_"; unattendedComment = $false; humanPromotedComment = $false } })
Assert-GateThrows { ConvertTo-ReviewerGateEffectivePolicy -Policy $widenedPacksPolicy } "A policy declaring more packs than the code-defined cap was accepted."

# ===========================================================================
# 3. HMAC domain separation, artifact envelope, tamper detection
# ===========================================================================

$masterKey = New-TestMasterKey
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ("gate-test-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempDir | Out-Null
try {
    $decisionManifest = [ordered]@{ kind = $script:ReviewerGateDecisionKind; artifactVersion = 1; note = "test" }
    $qualificationManifest = [ordered]@{ kind = $script:ReviewerGateQualificationKind; artifactVersion = 1; note = "test" }

    $decisionPath = Save-ReviewerGateDecision -Manifest $decisionManifest -Directory $tempDir -BaseName "decision1" -MasterKey $masterKey
    $qualificationPath = Save-ReviewerGateQualification -Manifest $qualificationManifest -Directory $tempDir -BaseName "qualification1" -MasterKey $masterKey

    $readBack = Read-ReviewerGateDecision -Path $decisionPath -MasterKey $masterKey
    Assert-Gate ([string]$readBack.note -ceq "test") "A gate decision artifact did not round-trip through save/read."

    Assert-GateThrows { Read-ReviewerGateArtifact -Path $decisionPath -MasterKey $masterKey -Domain qualification } "A decision artifact was accepted under the qualification HMAC domain."
    Assert-GateThrows { Read-ReviewerGateArtifact -Path $qualificationPath -MasterKey $masterKey -Domain decision } "A qualification artifact was accepted under the decision HMAC domain."

    $wrongKey = New-TestMasterKey
    Assert-GateThrows { Read-ReviewerGateDecision -Path $decisionPath -MasterKey $wrongKey } "A gate decision verified under the wrong master key."

    $verificationKey = Get-ReviewerVerificationDomainKey -MasterKey $masterKey -Domain preview
    $verificationManifest = [ordered]@{ kind = "verification-decision-preview"; artifactVersion = 1 }
    $verificationPath = Save-ReviewerVerificationPreview -Manifest $verificationManifest -Directory $tempDir -BaseName "verif1" -MasterKey $masterKey
    Assert-GateThrows { Read-ReviewerGateDecision -Path $verificationPath -MasterKey $masterKey } "A verification-decision-preview artifact was accepted as a gate decision (H-7 cross-promotion)."

    $rawEnvelope = [ordered]@{
        manifestJson = (ConvertTo-ReviewerVerificationCanonicalJson -Value ([ordered]@{ artifactVersion = 3; organization = "contoso" }))
        signatureAlg = "HMACSHA256"
        signature    = Get-ReviewerVerificationSignature -Json (ConvertTo-ReviewerVerificationCanonicalJson -Value ([ordered]@{ artifactVersion = 3; organization = "contoso" })) -Key $masterKey
    }
    $rawPath = Join-Path $tempDir "raw1.json"
    [IO.File]::WriteAllText($rawPath, ($rawEnvelope | ConvertTo-Json -Depth 4))
    Assert-GateThrows { Read-ReviewerGateDecision -Path $rawPath -MasterKey $masterKey } "A raw delivery-shaped artifact (signed with the RAW master key, no derived domain) was accepted as a gate decision."

    # One flipped byte in manifestJson must invalidate the seal.
    $rawEnvelopeJson = Get-Content -LiteralPath $decisionPath -Raw | ConvertFrom-Json
    $tamperedManifestJson = $rawEnvelopeJson.manifestJson -replace '"test"', '"TEST"'
    $tamperedEnvelope = [ordered]@{ manifestJson = $tamperedManifestJson; signatureAlg = "HMACSHA256"; signature = $rawEnvelopeJson.signature }
    $tamperedPath = Join-Path $tempDir "tampered1.json"
    [IO.File]::WriteAllText($tamperedPath, ($tamperedEnvelope | ConvertTo-Json -Depth 4))
    Assert-GateThrows { Read-ReviewerGateDecision -Path $tamperedPath -MasterKey $masterKey } "A single flipped byte in a gate decision's manifestJson was not detected."

    $decisionDomainKey = [Convert]::ToBase64String((Get-ReviewerGateDomainKey -MasterKey $masterKey -Domain decision))
    $qualificationDomainKey = [Convert]::ToBase64String((Get-ReviewerGateDomainKey -MasterKey $masterKey -Domain qualification))
    Assert-Gate ($decisionDomainKey -cne $qualificationDomainKey) "Decision and qualification derived domain keys are identical."

    # A REAL, schema-shaped qualification (the shape New-ReviewerGateQualification.ps1
    # produces and Get-ReviewerGateQualification in the wrapper reads) must round-trip
    # through Read-ReviewerGateQualification's exact-key/version check, not just the
    # generic envelope check above.
    $realQualification = New-TestQualification
    $realQualificationPath = Save-ReviewerGateQualification -Manifest $realQualification -Directory $tempDir `
        -BaseName "qualification-real" -MasterKey $masterKey
    $realQualificationRead = Read-ReviewerGateQualification -Path $realQualificationPath -MasterKey $masterKey
    Assert-Gate ($realQualificationRead.Ok -eq $true) `
        "A real, schema-shaped qualification artifact (the exact shape the operator tool produces) failed Read-ReviewerGateQualification."
    Assert-Gate ([int](Get-ReviewerVerificationValue $realQualificationRead.Qualification "artifactVersion" -1) -eq 1) `
        "A round-tripped qualification lost its artifactVersion field."

    # The converse must also hold: a qualification missing artifactVersion (the exact
    # bug this test pins) is REJECTED, not silently accepted. A shallow PSObject copy is
    # used (not a JSON round-trip): ConvertFrom-Json auto-detects the ISO-8601 date
    # strings here and would silently rehydrate them as [DateTime], which the strict
    # canonicalizer correctly refuses to serialize - that would test a JSON quirk, not
    # the artifactVersion check this test exists to pin.
    $missingArtifactVersion = $realQualification.PSObject.Copy()
    $missingArtifactVersion.PSObject.Properties.Remove("artifactVersion")
    $missingArtifactVersionPath = Save-ReviewerGateQualification -Manifest $missingArtifactVersion -Directory $tempDir `
        -BaseName "qualification-no-version" -MasterKey $masterKey
    $missingArtifactVersionRead = Read-ReviewerGateQualification -Path $missingArtifactVersionPath -MasterKey $masterKey
    Assert-Gate ($missingArtifactVersionRead.Ok -eq $false) `
        "A qualification artifact missing its mandatory artifactVersion field was accepted."
}
finally {
    Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
}

# ===========================================================================
# 4. Qualification read/current/satisfies
# ===========================================================================

$qualification = New-TestQualification
$liveBinding = @{
    NowUtc = [DateTime]::UtcNow; ScriptSha256 = "a" * 64; GateLibrarySha256 = "b" * 64
    VerificationLibrarySha256 = "c" * 64; VerificationPromptSha256 = "d" * 64
    VerificationPolicySha256 = "e" * 64; VerificationSchemaSha256 = "f" * 64
    GeneralistModels = @("claude-opus-5", "gpt-5.6-sol"); ConventionSpecialistModel = "claude-opus-5"
    ConventionVerifierModel = "gpt-5.6-sol"; EvaluationToolSha256 = ""
}
$current = Test-ReviewerGateQualificationCurrent -Qualification $qualification -LiveBinding $liveBinding -MaxQualificationAgeDays 90
Assert-Gate ([bool]$current.Ok) "A fresh, matching qualification was not accepted as current."

# Round-trip through the REAL save/read pipeline, and under a NON-INVARIANT
# current culture: ConvertFrom-Json auto-detects ISO-8601 date strings and
# rehydrates them as [DateTime], and en-GB's day-before-month short format
# ("04/08/2026" for August 4th) would silently misparse as April 8th under
# InvariantCulture assumptions if a bare [string] cast were ever used instead
# of Get-ReviewerGateStableDateTimeText - this must be judged identically
# regardless of the reading machine's locale.
$dateTimeTestDir = Join-Path ([IO.Path]::GetTempPath()) ("gate-datetime-test-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $dateTimeTestDir | Out-Null
$savedCulture = [Threading.Thread]::CurrentThread.CurrentCulture
try {
    $qualificationForRoundTrip = New-TestQualification
    $roundTripPath = Save-ReviewerGateQualification -Manifest $qualificationForRoundTrip -Directory $dateTimeTestDir `
        -BaseName "qualification-datetime" -MasterKey $masterKey

    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo("en-GB")
    $roundTrippedRead = Read-ReviewerGateQualification -Path $roundTripPath -MasterKey $masterKey
    Assert-Gate ($roundTrippedRead.Ok -eq $true) "A round-tripped qualification failed to read back under a non-invariant current culture (en-GB)."
    $roundTrippedCurrent = Test-ReviewerGateQualificationCurrent -Qualification $roundTrippedRead.Qualification `
        -LiveBinding $liveBinding -MaxQualificationAgeDays 90
    Assert-Gate ([bool]$roundTrippedCurrent.Ok) `
        "A fresh qualification, round-tripped through disk (ConvertFrom-Json's DateTime auto-coercion) and evaluated under a non-invariant current culture (en-GB), was not accepted as current - expiry judgment is locale-dependent."

    # A decision's expiry must be equally locale-independent after round-tripping.
    $decisionNotYetExpired = [ordered]@{
        kind                 = $script:ReviewerGateDecisionKind; artifactVersion = 1
        decisionExpiresAtUtc = ([DateTime]::UtcNow.AddMinutes(30).ToString("o", [Globalization.CultureInfo]::InvariantCulture))
    }
    $decisionNotYetExpiredPath = Save-ReviewerGateDecision -Manifest $decisionNotYetExpired -Directory $dateTimeTestDir `
        -BaseName "decision-datetime-fresh" -MasterKey $masterKey
    $decisionNotYetExpiredRead = Read-ReviewerGateDecision -Path $decisionNotYetExpiredPath -MasterKey $masterKey
    Assert-Gate (-not (Test-ReviewerGateDecisionExpired -Decision $decisionNotYetExpiredRead -NowUtc ([DateTime]::UtcNow))) `
        "A gate decision 30 minutes from expiry, round-tripped through disk and evaluated under a non-invariant current culture (en-GB), was reported already expired."

    $decisionAlreadyExpired = [ordered]@{
        kind                 = $script:ReviewerGateDecisionKind; artifactVersion = 1
        decisionExpiresAtUtc = ([DateTime]::UtcNow.AddMinutes(-30).ToString("o", [Globalization.CultureInfo]::InvariantCulture))
    }
    $decisionAlreadyExpiredPath = Save-ReviewerGateDecision -Manifest $decisionAlreadyExpired -Directory $dateTimeTestDir `
        -BaseName "decision-datetime-expired" -MasterKey $masterKey
    $decisionAlreadyExpiredRead = Read-ReviewerGateDecision -Path $decisionAlreadyExpiredPath -MasterKey $masterKey
    Assert-Gate ((Test-ReviewerGateDecisionExpired -Decision $decisionAlreadyExpiredRead -NowUtc ([DateTime]::UtcNow))) `
        "A gate decision 30 minutes PAST expiry, round-tripped through disk and evaluated under a non-invariant current culture (en-GB), was reported still current."
}
finally {
    [Threading.Thread]::CurrentThread.CurrentCulture = $savedCulture
    Remove-Item -Recurse -Force $dateTimeTestDir -ErrorAction SilentlyContinue
}

$expired = New-TestQualification -ExpiresAtUtc ([DateTime]::UtcNow.AddDays(-1).ToString("o"))
$expiredCurrent = Test-ReviewerGateQualificationCurrent -Qualification $expired -LiveBinding $liveBinding -MaxQualificationAgeDays 90
Assert-Gate (-not $expiredCurrent.Ok -and ($expiredCurrent.ReasonCodes -ccontains "qualificationExpired")) "An expired qualification was accepted."

$stale = New-TestQualification -IssuedAtUtc ([DateTime]::UtcNow.AddDays(-95).ToString("o"))
$staleCurrent = Test-ReviewerGateQualificationCurrent -Qualification $stale -LiveBinding $liveBinding -MaxQualificationAgeDays 90
Assert-Gate (-not $staleCurrent.Ok -and ($staleCurrent.ReasonCodes -ccontains "qualificationExpired")) "A qualification older than maxQualificationAgeDays was accepted as current."

$mismatchedBinding = New-TestQualification -AgentBindingOverrides @{ scriptSha256 = "9" * 64 }
$mismatchedCurrent = Test-ReviewerGateQualificationCurrent -Qualification $mismatchedBinding -LiveBinding $liveBinding -MaxQualificationAgeDays 90
Assert-Gate (-not $mismatchedCurrent.Ok -and ($mismatchedCurrent.ReasonCodes -ccontains "qualificationBindingMismatch")) "A qualification bound to a DIFFERENT script sha256 was accepted as current."

$modelMismatch = New-TestQualification -AgentBindingOverrides @{ generalistModels = @("claude-opus-5", "some-other-model") }
$modelMismatchCurrent = Test-ReviewerGateQualificationCurrent -Qualification $modelMismatch -LiveBinding $liveBinding -MaxQualificationAgeDays 90
Assert-Gate (-not $modelMismatchCurrent.Ok -and ($modelMismatchCurrent.ReasonCodes -ccontains "qualificationBindingMismatch")) "A qualification bound to a different generalist model pair was accepted as current."

$toolMismatchBinding = $liveBinding.Clone(); $toolMismatchBinding.EvaluationToolSha256 = "z" * 64
$toolMismatchCurrent = Test-ReviewerGateQualificationCurrent -Qualification $qualification -LiveBinding $toolMismatchBinding -MaxQualificationAgeDays 90
Assert-Gate (-not $toolMismatchCurrent.Ok -and ($toolMismatchCurrent.ReasonCodes -ccontains "qualificationToolMismatch")) "A qualification's evaluationToolSha256 mismatch against a supplied live tool hash was not detected."

$enabledEffective = ConvertTo-ReviewerGateEffectivePolicy -Policy (New-EnabledPolicy)

$goodScope = Test-ReviewerGateQualificationSatisfies -Qualification $qualification -Aspect "comment" -Pack "(generalist)" -Severity "important" -EffectivePolicy $enabledEffective
Assert-Gate ([bool]$goodScope.Ok) "A qualification scope meeting every floor was rejected."

$missingScope = Test-ReviewerGateQualificationSatisfies -Qualification $qualification -Aspect "comment" -Pack "(generalist)" -Severity "suggestion" -EffectivePolicy $enabledEffective
Assert-Gate (-not $missingScope.Ok -and ($missingScope.ReasonCodes -ccontains "qualificationScopeMissing")) "A qualification with no matching (pack, severity) scope was accepted."

# Boundary: sampleCount at floor-1 fails, at floor passes.
$floorSamples = [int]$enabledEffective.minCommentSampleCount
$belowFloor = New-TestQualification -CommentSampleCount ($floorSamples - 1)
$atFloor = New-TestQualification -CommentSampleCount $floorSamples
Assert-Gate (-not (Test-ReviewerGateQualificationSatisfies -Qualification $belowFloor -Aspect "comment" -Pack "(generalist)" -Severity "important" -EffectivePolicy $enabledEffective).Ok) "A comment sample count one BELOW the floor was accepted."
Assert-Gate ((Test-ReviewerGateQualificationSatisfies -Qualification $atFloor -Aspect "comment" -Pack "(generalist)" -Severity "important" -EffectivePolicy $enabledEffective).Ok) "A comment sample count exactly AT the floor was rejected."

# Boundary: precisionLowerBound95 at floor-epsilon fails, at floor passes.
$precisionFloor = [double]$enabledEffective.minPrecisionLowerBound95
$belowPrecision = New-TestQualification -PrecisionLowerBound95 ($precisionFloor - 0.001)
$atPrecision = New-TestQualification -PrecisionLowerBound95 $precisionFloor
Assert-Gate (-not (Test-ReviewerGateQualificationSatisfies -Qualification $belowPrecision -Aspect "comment" -Pack "(generalist)" -Severity "important" -EffectivePolicy $enabledEffective).Ok) "A precisionLowerBound95 just below the floor was accepted."
Assert-Gate ((Test-ReviewerGateQualificationSatisfies -Qualification $atPrecision -Aspect "comment" -Pack "(generalist)" -Severity "important" -EffectivePolicy $enabledEffective).Ok) "A precisionLowerBound95 exactly at the floor was rejected."

# Zero false approvals is meaningless without a sample floor: sampleCount
# below the approval floor fails even with falseApprovalCount=0.
$zeroFalseSmallSample = New-TestQualification -ApprovalSampleCount ([int]$enabledEffective.minApprovalSampleCount - 1) -FalseApprovalCount 0
Assert-Gate (-not (Test-ReviewerGateQualificationSatisfies -Qualification $zeroFalseSmallSample -Aspect "approval" -EffectivePolicy $enabledEffective).Ok) "Zero false approvals under the approval sample floor was accepted (the whole point of the sample floor)."
$oneFalseApproval = New-TestQualification -FalseApprovalCount 1
Assert-Gate (-not (Test-ReviewerGateQualificationSatisfies -Qualification $oneFalseApproval -Aspect "approval" -EffectivePolicy $enabledEffective).Ok) "A single observed false approval was accepted."
$zeroFalseGoodSample = New-TestQualification -ApprovalSampleCount ([int]$enabledEffective.minApprovalSampleCount) -FalseApprovalCount 0
Assert-Gate ((Test-ReviewerGateQualificationSatisfies -Qualification $zeroFalseGoodSample -Aspect "approval" -EffectivePolicy $enabledEffective).Ok) "Zero false approvals with a sample count exactly at the floor was rejected."

# ===========================================================================
# 5. Candidate-facet joining (T-2)
# ===========================================================================

$conventionPlan = [pscustomobject][ordered]@{
    selectedPacks = @([pscustomobject][ordered]@{
            name = "csharp-core"
            sources = @([pscustomobject][ordered]@{ sourceId = "shared-rules" })
        })
}
$inputManifest = [pscustomobject][ordered]@{
    candidates = @(
        [pscustomobject][ordered]@{ candidateId = "cand1:" + ("a" * 64); ruleSourceId = "" }
        [pscustomobject][ordered]@{ candidateId = "cand1:" + ("b" * 64); ruleSourceId = "shared-rules" }
        [pscustomobject][ordered]@{ candidateId = "cand1:" + ("c" * 64); ruleSourceId = "unresolved-source" }
    )
}
$eligibleForFacets = @(
    [pscustomobject]@{ candidateId = "cand1:" + ("a" * 64); candidateHash = "a" * 64; originKind = "generalist"; severity = "important"; filePath = "/src/a.cs"; line = 1; comment = "c1"; evidence = "e"; confidence = "high" }
    [pscustomobject]@{ candidateId = "cand1:" + ("b" * 64); candidateHash = "b" * 64; originKind = "convention"; severity = "important"; filePath = "/src/b.cs"; line = 2; comment = "c2"; evidence = "e"; confidence = "high" }
    [pscustomobject]@{ candidateId = "cand1:" + ("c" * 64); candidateHash = "c" * 64; originKind = "convention"; severity = "important"; filePath = "/src/c.cs"; line = 3; comment = "c3"; evidence = "e"; confidence = "high" }
)
$facets = @(Get-ReviewerGateCandidateFacets -Eligible $eligibleForFacets -InputManifest $inputManifest -ConventionPlan $conventionPlan)
Assert-Gate ((@($facets | Where-Object { $_.candidateId -eq "cand1:" + ("a" * 64) })[0].pack) -ceq "(generalist)") "A generalist-origin candidate was not assigned the synthetic '(generalist)' pack."
Assert-Gate ((@($facets | Where-Object { $_.candidateId -eq "cand1:" + ("b" * 64) })[0].pack) -ceq "csharp-core") "A convention-origin candidate did not resolve its pack via ruleSourceId -> conventionPlan.selectedPacks[].sources[].sourceId."
Assert-Gate ((@($facets | Where-Object { $_.candidateId -eq "cand1:" + ("c" * 64) })[0].pack) -ceq "") "A convention-origin candidate whose ruleSourceId does not resolve to any selected pack was assigned a non-empty pack."

# ===========================================================================
# 6. Per-candidate eligibility
# ===========================================================================

$important = New-TestFacet -Severity "important"
$critical = New-TestFacet -CandidateId ("cand1:" + ("b" * 64)) -CandidateHash ("b" * 64) -Severity "critical"
$suggestion = New-TestFacet -CandidateId ("cand1:" + ("c" * 64)) -CandidateHash ("c" * 64) -Severity "suggestion"
$unknownPack = New-TestFacet -CandidateId ("cand1:" + ("d" * 64)) -CandidateHash ("d" * 64) -Pack "totally-unknown-pack"

$eligibleImportant = Test-ReviewerGateCandidateEligible -Facet $important -EffectivePolicy $enabledEffective -Purpose "unattendedComment" -ChangedPaths @("/src/a.cs") -ThreadFacts @()
Assert-Gate ([bool]$eligibleImportant.Ok) "An important-severity, allowed-pack candidate with a current anchor was not eligible."

$criticalResult = Test-ReviewerGateCandidateEligible -Facet $critical -EffectivePolicy $enabledEffective -Purpose "unattendedComment" -ChangedPaths @("/src/a.cs") -ThreadFacts @()
Assert-Gate (-not [bool]$criticalResult.Ok -and ($criticalResult.ReasonCodes -ccontains "severityDisabled")) "A critical-severity candidate was eligible for the unattended comment gate."

$suggestionNoFlag = Test-ReviewerGateCandidateEligible -Facet $suggestion -EffectivePolicy $enabledEffective -Purpose "unattendedComment" -ChangedPaths @("/src/a.cs") -ThreadFacts @() -SuggestionGateEnabled:$false
Assert-Gate (-not [bool]$suggestionNoFlag.Ok -and ($suggestionNoFlag.ReasonCodes -ccontains "suggestionGateDisabled")) "A suggestion was eligible for the unattended comment gate without the separate suggestion gate flag."
$suggestionWithFlag = Test-ReviewerGateCandidateEligible -Facet $suggestion -EffectivePolicy $enabledEffective -Purpose "unattendedComment" -ChangedPaths @("/src/a.cs") -ThreadFacts @() -SuggestionGateEnabled:$true
Assert-Gate ([bool]$suggestionWithFlag.Ok) "A suggestion was NOT eligible with the separate suggestion gate flag enabled and policy allowing it."

$unknownPackResult = Test-ReviewerGateCandidateEligible -Facet $unknownPack -EffectivePolicy $enabledEffective -Purpose "unattendedComment" -ChangedPaths @("/src/a.cs") -ThreadFacts @()
Assert-Gate (-not [bool]$unknownPackResult.Ok -and ($unknownPackResult.ReasonCodes -ccontains "packUnknown")) "A candidate from an unrecognized pack was eligible."

# Commit/anchor currency: an anchor no longer in the (fresh) changed-path set fails closed.
$movedAnchor = Test-ReviewerGateCandidateEligible -Facet $important -EffectivePolicy $enabledEffective -Purpose "unattendedComment" -ChangedPaths @("/src/other.cs") -ThreadFacts @()
Assert-Gate (-not [bool]$movedAnchor.Ok -and ($movedAnchor.ReasonCodes -ccontains "anchorNotInChangeSet")) "A candidate whose file is no longer in the pinned change set was still eligible."

# Thread dedupe / blocking-thread / unknown-thread-state currency.
$closedThread = @{ filePath = "/src/a.cs"; line = 10; status = "Closed" }
$closedResult = Test-ReviewerGateCandidateEligible -Facet $important -EffectivePolicy $enabledEffective -Purpose "unattendedComment" -ChangedPaths @("/src/a.cs") -ThreadFacts @($closedThread)
Assert-Gate ([bool]$closedResult.Ok) "A candidate co-located with a CLOSED thread was made ineligible; closed threads must not block."
$activeThread = @{ filePath = "/src/a.cs"; line = 10; status = "Active" }
$blockingResult = Test-ReviewerGateCandidateEligible -Facet $important -EffectivePolicy $enabledEffective -Purpose "unattendedComment" -ChangedPaths @("/src/a.cs") -ThreadFacts @($activeThread)
Assert-Gate (-not [bool]$blockingResult.Ok -and ($blockingResult.ReasonCodes -ccontains "blockingHumanThreadOpen")) "A candidate co-located with an ACTIVE (open, blocking) human thread was still eligible."
$unknownThread = @{ filePath = "/src/a.cs"; line = 10; status = "unknown" }
$unknownThreadResult = Test-ReviewerGateCandidateEligible -Facet $important -EffectivePolicy $enabledEffective -Purpose "unattendedComment" -ChangedPaths @("/src/a.cs") -ThreadFacts @($unknownThread)
Assert-Gate (-not [bool]$unknownThreadResult.Ok -and ($unknownThreadResult.ReasonCodes -ccontains "threadStatusUnknown")) "A candidate co-located with a thread whose status defaulted to 'unknown' was still eligible (T-9)."
$defaultStatusThread = @{ filePath = "/src/a.cs"; line = 10 }
$defaultStatusResult = Test-ReviewerGateCandidateEligible -Facet $important -EffectivePolicy $enabledEffective -Purpose "unattendedComment" -ChangedPaths @("/src/a.cs") -ThreadFacts @($defaultStatusThread)
Assert-Gate (-not [bool]$defaultStatusResult.Ok -and ($defaultStatusResult.ReasonCodes -ccontains "threadStatusUnknown")) "A thread record with no status field at all was treated as non-blocking instead of unknown."

# humanPromotedComment purpose reaches a broader severity ceiling (includes suggestion, excludes nothing critical does not already exclude).
$criticalHumanPromoted = Test-ReviewerGateCandidateEligible -Facet $critical -EffectivePolicy $enabledEffective -Purpose "humanPromotedComment" -ChangedPaths @("/src/a.cs") -ThreadFacts @()
Assert-Gate ([bool]$criticalHumanPromoted.Ok) "A critical-severity candidate was NOT eligible for humanPromotedComment; critical must be human-reachable even though it can never be unattended."

# ===========================================================================
# 7. Verification run-level accounting / degradation
# ===========================================================================

$completeAccounting = Test-ReviewerGateVerificationComplete -Status "complete" -InputArtifactPath "C:\fake\input.json" `
    -InputManifestSha256 ("a" * 64) -TotalCandidateCount 2 `
    -Eligible @(@{ candidateId = "x1" }) -Withheld @(@{ candidateId = "x2"; reason = "duplicateCandidate" })
Assert-Gate ([bool]$completeAccounting.Ok) "A complete, correctly-accounted verification run was reported as not-Ok."

$degraded = Test-ReviewerGateVerificationComplete -Status "degraded" -InputArtifactPath "" -InputManifestSha256 ("0" * 64) `
    -TotalCandidateCount 0 -Eligible @() -Withheld @()
Assert-Gate (-not $degraded.Ok -and ($degraded.ReasonCodes -ccontains "verificationDegraded") -and ($degraded.ReasonCodes -ccontains "verificationIncomplete")) "A degraded verification pass (empty is not clean, T-3) was reported Ok."

$accountingMismatch = Test-ReviewerGateVerificationComplete -Status "complete" -InputArtifactPath "C:\fake\input.json" `
    -InputManifestSha256 ("a" * 64) -TotalCandidateCount 5 -Eligible @(@{ candidateId = "x1" }) -Withheld @(@{ candidateId = "x2"; reason = "duplicateCandidate" })
Assert-Gate (-not $accountingMismatch.Ok -and ($accountingMismatch.ReasonCodes -ccontains "candidateAccountingMismatch")) "A totalCandidateCount that does not match eligible+withheld was reported Ok (an injected/missing candidate was not caught)."

$unknownWithheldReason = Test-ReviewerGateVerificationComplete -Status "complete" -InputArtifactPath "C:\fake\input.json" `
    -InputManifestSha256 ("a" * 64) -TotalCandidateCount 1 -Eligible @() -Withheld @(@{ candidateId = "x1"; reason = "not-a-real-reason" })
Assert-Gate (-not $unknownWithheldReason.Ok -and ($unknownWithheldReason.ReasonCodes -ccontains "unknownWithheldReason")) "An unrecognized withheld reason string was accepted."

$needsHumanPresent = Test-ReviewerGateVerificationComplete -Status "complete" -InputArtifactPath "C:\fake\input.json" `
    -InputManifestSha256 ("a" * 64) -TotalCandidateCount 1 -Eligible @() -Withheld @(@{ candidateId = "x1"; reason = "needsHuman" })
Assert-Gate (-not $needsHumanPresent.Ok -and ($needsHumanPresent.ReasonCodes -ccontains "needsHumanPresent")) "A withheld 'needsHuman' verdict was not flagged with needsHumanPresent."

# ===========================================================================
# 8. Decision building: run accounting failure closes ALL candidates
# ===========================================================================

$degradedRunDecision = New-Decision -Facets @(New-TestFacet) -EffectivePolicy $enabledEffective -Qualification $qualification `
    -RunAccounting ([pscustomobject]@{ Ok = $false; ReasonCodes = @("verificationDegraded") })
Assert-Gate (-not [bool]$degradedRunDecision.runOk -and @($degradedRunDecision.unattendedComments).Count -eq 0) "A decision built over a degraded run accounting still produced unattended-eligible comments."
Assert-Gate (@($degradedRunDecision.candidates | Where-Object { $_.unattendedCommentReasons -ccontains "verificationDegraded" }).Count -eq 1) "A candidate under a degraded run was not tagged with the run's own reason code."

# ===========================================================================
# 9. Monotonic manifest key / subset (remove-only)
# ===========================================================================

$original = [pscustomobject]@{ candidateHash = "a" * 64; severity = "important"; filePath = "/src/a.cs"; line = 10; comment = "Original text." }
$reworded = [pscustomobject]@{ candidateHash = "a" * 64; severity = "important"; filePath = "/src/a.cs"; line = 10; comment = "DIFFERENT text." }
$relocated = [pscustomobject]@{ candidateHash = "a" * 64; severity = "important"; filePath = "/src/other.cs"; line = 10; comment = "Original text." }
$raisedSeverity = [pscustomobject]@{ candidateHash = "a" * 64; severity = "critical"; filePath = "/src/a.cs"; line = 10; comment = "Original text." }
$added = [pscustomobject]@{ candidateHash = "z" * 64; severity = "important"; filePath = "/src/z.cs"; line = 1; comment = "A brand new finding never sealed." }

Assert-Gate ((Get-ReviewerGateManifestKey -Entry $original) -ne (Get-ReviewerGateManifestKey -Entry $reworded)) "Rewording a comment did not change its monotonic key."
Assert-Gate ((Get-ReviewerGateManifestKey -Entry $original) -ne (Get-ReviewerGateManifestKey -Entry $relocated)) "Relocating a finding did not change its monotonic key."
Assert-Gate ((Get-ReviewerGateManifestKey -Entry $original) -ne (Get-ReviewerGateManifestKey -Entry $raisedSeverity)) "Raising severity did not change the monotonic key."

$sealed = @($original)
function Get-SubsetCount {
    <# Select-ReviewerGateSubset returns , (array) like Select-ReviewerManifestSubset,
       so it must be called BARE - wrapping the call itself in @() would nest
       the result and silently make Count 1 forever (the exact footgun the
       existing codebase's own comment at the raw promotion call site warns
       about). Assigning bare first, then wrapping the MATERIALIZED variable,
       is safe. #>
    param([object[]]$Approved, [object[]]$Allowed)
    $subsetResult = Select-ReviewerGateSubset -Approved $Approved -Allowed $Allowed
    return @($subsetResult).Count
}
Assert-Gate ((Get-SubsetCount -Approved @($reworded) -Allowed $sealed) -eq 0) "A reworded entry survived Select-ReviewerGateSubset against the originally sealed set."
Assert-Gate ((Get-SubsetCount -Approved @($relocated) -Allowed $sealed) -eq 0) "A relocated entry survived Select-ReviewerGateSubset against the originally sealed set."
Assert-Gate ((Get-SubsetCount -Approved @($raisedSeverity) -Allowed $sealed) -eq 0) "A severity-raised entry survived Select-ReviewerGateSubset against the originally sealed set."
Assert-Gate ((Get-SubsetCount -Approved @($original, $added) -Allowed $sealed) -eq 1) "An entry never in the sealed set (an addition) survived Select-ReviewerGateSubset."
Assert-Gate ((Get-SubsetCount -Approved @($original) -Allowed @()) -eq 0) "A legitimate removal (world no longer allows an originally-approved entry) was not honoured - Allowed=@() must drop everything."
Assert-Gate ((Get-SubsetCount -Approved @($original) -Allowed $sealed) -eq 1) "A legitimate, unchanged, still-allowed entry did not survive Select-ReviewerGateSubset."

# ===========================================================================
# 10. Approval predicate: every precondition is independently testable
# ===========================================================================

$approvalEffective = ConvertTo-ReviewerGateEffectivePolicy -Policy (New-EnabledPolicy -Mode "approvalVote")

function New-PassingApprovalArgs {
    return @{
        EffectivePolicy = $approvalEffective
        Qualification = (New-TestQualification)
        ProviderIsGitHub = $true
        RunAccountingOk = $true
        AllWithheldReasonsSafe = $true
        NoNeedsHumanPresent = $true
        GeneralistPairComplete = $true
        GeneralistBothApprove = $true
        SpecialistOkForApproval = $true
        RawGateApproves = $true
        GateHumanPromotableCount = 0
        GateImportantOrHigherCount = 0
        GateImportantOrHigherConfirmedCount = 0
        ChecksKnown = $true
        ChecksAllSuccess = $true
        DismissalKnown = $true
        DismissesStaleReviews = $true
        PriorRunFingerprintMatches = $true
        CanaryConfirmed = $true
        CommitUnchanged = $true
        AuthoritativeSourcesCurrent = $true
        AlreadyVotedThisCommit = $false
    }
}

$passingArgs = New-PassingApprovalArgs
$passingApproval = Test-ReviewerGateApproval @passingArgs
Assert-Gate ([bool]$passingApproval.Ok) "An approval request satisfying EVERY precondition was rejected: $($passingApproval.ReasonCodes -join ',')."

$approvalFlipTable = @(
    , @("ProviderIsGitHub", $false, "providerUnsupported")
    , @("RunAccountingOk", $false, "verificationDegraded")
    , @("AllWithheldReasonsSafe", $false, "candidateWithheld")
    , @("NoNeedsHumanPresent", $false, "needsHumanPresent")
    , @("GeneralistPairComplete", $false, "generalistPassIncomplete")
    , @("GeneralistBothApprove", $false, "generalistVoteNotApprove")
    , @("SpecialistOkForApproval", $false, "specialistDegraded")
    , @("RawGateApproves", $false, "generalistVoteNotApprove")
    , @("GateHumanPromotableCount", 1, "gateFindingsUndelivered")
    , @("GateImportantOrHigherCount", 1, "gateFindingsUndelivered")
    , @("GateImportantOrHigherConfirmedCount", 1, "gateFindingsUndelivered")
    , @("ChecksKnown", $false, "checksUnavailable")
    , @("ChecksAllSuccess", $false, "checksFailed")
    , @("DismissalKnown", $false, "dismissStaleReviewsUnknown")
    , @("DismissesStaleReviews", $false, "dismissStaleReviewsDisabled")
    , @("PriorRunFingerprintMatches", $false, "eligibilityFirstSeenThisRun")
    , @("CanaryConfirmed", $false, "canaryConfirmationMissing")
    , @("CommitUnchanged", $false, "sourceCommitMoved")
    , @("AuthoritativeSourcesCurrent", $false, "authoritativeSourceChanged")
    , @("AlreadyVotedThisCommit", $true, "votePreviouslyCast")
)
foreach ($case in $approvalFlipTable) {
    $flipArgs = New-PassingApprovalArgs
    $flipArgs[[string]$case[0]] = $case[1]
    $result = Test-ReviewerGateApproval @flipArgs
    Assert-Gate (-not [bool]$result.Ok -and ($result.ReasonCodes -ccontains [string]$case[2])) `
        "Flipping '$($case[0])' to $($case[1]) did not close approval with reason '$($case[2])' (got: $($result.ReasonCodes -join ','))."
}

$noQualArgs = New-PassingApprovalArgs
$noQualArgs.Qualification = $null
$noQualResult = Test-ReviewerGateApproval @noQualArgs
Assert-Gate (-not [bool]$noQualResult.Ok -and ($noQualResult.ReasonCodes -ccontains "qualificationMissing")) "Approval proceeded with a null qualification."

$modeOffArgs = New-PassingApprovalArgs
$modeOffArgs.EffectivePolicy = $offEffective
$modeOffResult = Test-ReviewerGateApproval @modeOffArgs
Assert-Gate (-not [bool]$modeOffResult.Ok -and ($modeOffResult.ReasonCodes -ccontains "modeNotEnabled")) "Approval proceeded while the effective policy mode was 'off'."

# ===========================================================================
# 11. Reason-code closed vocabulary and safe rewrite
# ===========================================================================

Assert-Gate ((ConvertTo-ReviewerGateReasonCode -Reason "packUnknown") -ceq "packUnknown") "A recognized reason code was rewritten."
Assert-Gate ((ConvertTo-ReviewerGateReasonCode -Reason "totally-made-up-reason") -ceq "unrecognizedReasonRewritten") "An unrecognized reason code string was not rewritten to the safe default."

# ===========================================================================
# 12. Determinism: identical inputs seal identical canonical content
# ===========================================================================

$decisionA = New-Decision -Facets @(New-TestFacet) -EffectivePolicy $enabledEffective -Qualification $qualification
Start-Sleep -Milliseconds 5
$decisionB = New-Decision -Facets @(New-TestFacet) -EffectivePolicy $enabledEffective -Qualification $qualification
$zeroCandidateDecision = New-Decision -Facets @() -EffectivePolicy $enabledEffective -Qualification $qualification
Assert-Gate ([int]$decisionA.gateHumanPromotableCount -eq 1 -and
    [int]$decisionA.gateImportantOrHigherCount -eq 1 -and
    @($decisionA.gateImportantOrHigherKeys).Count -eq 1) `
    "A verified specialist important finding was not sealed into approval-blocking gate-owned accounting."
Assert-Gate ([int]$zeroCandidateDecision.gateHumanPromotableCount -eq 0 -and
    [int]$zeroCandidateDecision.gateImportantOrHigherCount -eq 0 -and
    @($zeroCandidateDecision.gateImportantOrHigherKeys).Count -eq 0) `
    "A zero-candidate decision did not seal zero gate-owned approval-blocking accounting."
# createdAtUtc/decisionExpiresAtUtc are the only time-dependent fields; strip
# them before comparing so the rest of the seal is proven reproducible.
$stripTimestamps = { param($d) [pscustomobject][ordered]@{ candidates = $d.candidates; unattendedComments = $d.unattendedComments; runOk = $d.runOk; mode = $d.mode } }
$hashA = Get-ReviewerVerificationObjectSha256 -Value (& $stripTimestamps $decisionA)
$hashB = Get-ReviewerVerificationObjectSha256 -Value (& $stripTimestamps $decisionB)
Assert-Gate ($hashA -ceq $hashB) "Two decisions built from IDENTICAL inputs (ignoring only the two documented timestamp fields) produced different sealed content."

# ===========================================================================
# 13. No-rejection / closed vote set / no gate-library write tools (source scan)
# ===========================================================================

Assert-Gate (($script:ReviewerGateAllowedVotes.Count -eq 1) -and ($script:ReviewerGateAllowedVotes[0] -ceq "Approved")) "ReviewerGateAllowedVotes is not the single-element closed set @('Approved')."
foreach ($forbiddenVoteToken in @("WaitingForAuthor", "Rejected", "ApprovedWithSuggestions")) {
    Assert-Gate ($gateLibraryText.IndexOf("`"$forbiddenVoteToken`"", [StringComparison]::Ordinal) -lt 0) "DeliveryGates.ps1 contains a literal reference to the forbidden vote '$forbiddenVoteToken'."
}
foreach ($forbiddenToolToken in @(('sh' + 'ell('), ('web_' + 'search'), ('web_' + 'fetch'), "Invoke-AgentMcpTool", "Open-AgentMcpSession")) {
    Assert-Gate ($gateLibraryText.IndexOf($forbiddenToolToken, [StringComparison]::Ordinal) -lt 0) "DeliveryGates.ps1 references '$forbiddenToolToken'; the gate library must remain a pure, network-free, MCP-free library."
}
Assert-Gate ($wrapperText.IndexOf('$script:ReviewerGateAllowedVotes = @("Approved")', [StringComparison]::Ordinal) -ge 0 -or
    $gateLibraryText.IndexOf('$script:ReviewerGateAllowedVotes = @("Approved")', [StringComparison]::Ordinal) -ge 0) `
    "Could not locate the literal, hardcoded gate-allowed-votes declaration in either the wrapper or the gate library."
# The gate's own vote call in the wrapper must be the literal string
# "Approved" - never a variable that could carry another value.
Assert-Gate ($wrapperText -match 'Set-ReviewerVote\s+-Session\s+\$sessionForWrite\s+-PrId\s+\$prId\s+-Vote\s+"Approved"') `
    "The wrapper's gate delivery path does not cast the vote with the literal, hardcoded string ""Approved""."

# ===========================================================================
# 14. Artifact-kind rejection (Test-ReviewerGateArtifactKind)
# ===========================================================================

Assert-Gate (Test-ReviewerGateArtifactKind -Kind "reviewer-gate-decision") "The exact expected gate-decision kind was rejected."
foreach ($otherKind in @("", "verification-input-preview", "verification-decision-preview", "reviewer-gate-qualification")) {
    Assert-Gate (-not (Test-ReviewerGateArtifactKind -Kind $otherKind)) "Test-ReviewerGateArtifactKind accepted kind='$otherKind' as a valid gate decision."
}

# ===========================================================================
# 15. Empty-path / line<1 PR-level candidate is ineligible for the gate
#     (finding 2 - anchorNotInChangeSet, safest default; raw delivery's own
#     PR-level acceptance in self-check 8 is untouched by this)
# ===========================================================================

$prLevelFacet = New-TestFacet -FilePath "" -Line 0
$prLevelResult = Test-ReviewerGateCandidateEligible -Facet $prLevelFacet -EffectivePolicy $enabledEffective `
    -Purpose "unattendedComment" -ChangedPaths @("/src/a.cs") -ThreadFacts @()
Assert-Gate (-not [bool]$prLevelResult.Ok -and ($prLevelResult.ReasonCodes -ccontains "anchorNotInChangeSet")) `
    "A PR-level candidate (empty filePath) was eligible for the gate; gate publication v1 requires a valid, current anchor."

$prLevelHumanPromoted = Test-ReviewerGateCandidateEligible -Facet $prLevelFacet -EffectivePolicy $enabledEffective `
    -Purpose "humanPromotedComment" -ChangedPaths @("/src/a.cs") -ThreadFacts @()
Assert-Gate (-not [bool]$prLevelHumanPromoted.Ok -and ($prLevelHumanPromoted.ReasonCodes -ccontains "anchorNotInChangeSet")) `
    "A PR-level candidate (empty filePath) was eligible for humanPromotedComment; the anchor requirement applies to both purposes."

$lineZeroFacet = New-TestFacet -FilePath "/src/a.cs" -Line 0
$lineZeroResult = Test-ReviewerGateCandidateEligible -Facet $lineZeroFacet -EffectivePolicy $enabledEffective `
    -Purpose "unattendedComment" -ChangedPaths @("/src/a.cs") -ThreadFacts @()
Assert-Gate (-not [bool]$lineZeroResult.Ok -and ($lineZeroResult.ReasonCodes -ccontains "anchorNotInChangeSet")) `
    "A candidate with a real file path but line<1 was eligible for the gate."

# A PR-level candidate must be ineligible even when NO thread would otherwise
# block it (proving the anchor check itself closes it, not a side effect of
# skipping the thread-blocking loop for a path-less facet) and even when an
# ACTIVE (blocking) thread exists at the same nominal anchor as the facet
# would-be location - it must never accidentally slip through because the
# thread-blocking loop also skips path-less facets.
$prLevelWithActiveThread = Test-ReviewerGateCandidateEligible -Facet $prLevelFacet -EffectivePolicy $enabledEffective `
    -Purpose "unattendedComment" -ChangedPaths @("/src/a.cs") -ThreadFacts @(@{ filePath = ""; line = 0; status = "Active" })
Assert-Gate (-not [bool]$prLevelWithActiveThread.Ok -and ($prLevelWithActiveThread.ReasonCodes -ccontains "anchorNotInChangeSet")) `
    "A PR-level candidate was eligible even alongside an Active PR-level thread; anchor ineligibility must hold regardless of thread state."

# ===========================================================================
# 16. Get-ReviewerGateWritesCurrentlyRequested: the single write-authority
#     source of truth (findings 1 and 3)
# ===========================================================================

$offForAuthority = ConvertTo-ReviewerGateEffectivePolicy -Policy (New-EnabledPolicy -Mode "off")
$shadowForAuthority = ConvertTo-ReviewerGateEffectivePolicy -Policy (New-EnabledPolicy -Mode "shadow")
$commentForAuthority = ConvertTo-ReviewerGateEffectivePolicy -Policy (New-EnabledPolicy -Mode "unattendedComment")
$suggestionForAuthority = ConvertTo-ReviewerGateEffectivePolicy -Policy (New-EnabledPolicy -Mode "unattendedCommentAndSuggestion")
$approvalForAuthority = ConvertTo-ReviewerGateEffectivePolicy -Policy (New-EnabledPolicy -Mode "approvalVote")

$authorityTable = @(
    , @("off, all switches on", $offForAuthority, $true, $true, $true, $false, $false, $false)
    , @("shadow, all switches on", $shadowForAuthority, $true, $true, $true, $false, $false, $false)
    , @("unattendedComment, all switches on", $commentForAuthority, $true, $true, $true, $true, $false, $false)
    , @("unattendedComment, comment switch OFF", $commentForAuthority, $false, $true, $true, $false, $false, $false)
    , @("unattendedCommentAndSuggestion, all switches on", $suggestionForAuthority, $true, $true, $true, $true, $true, $false)
    , @("unattendedCommentAndSuggestion, suggestion switch OFF", $suggestionForAuthority, $true, $false, $true, $true, $false, $false)
    , @("approvalVote, all switches on", $approvalForAuthority, $true, $true, $true, $true, $true, $true)
    , @("approvalVote, approval switch OFF", $approvalForAuthority, $true, $true, $false, $true, $true, $false)
)
foreach ($case in $authorityTable) {
    $label = [string]$case[0]; $policy = $case[1]
    $commentSwitch = [bool]$case[2]; $suggestionSwitch = [bool]$case[3]; $approvalSwitch = [bool]$case[4]
    $expectComments = [bool]$case[5]; $expectSuggestions = [bool]$case[6]; $expectApproval = [bool]$case[7]
    $authority = Get-ReviewerGateWritesCurrentlyRequested -EffectivePolicy $policy `
        -CommentSwitchOn $commentSwitch -SuggestionSwitchOn $suggestionSwitch -ApprovalSwitchOn $approvalSwitch
    Assert-Gate (([bool]$authority.Comments -eq $expectComments) -and ([bool]$authority.Suggestions -eq $expectSuggestions) -and
        ([bool]$authority.Approval -eq $expectApproval)) `
        "Get-ReviewerGateWritesCurrentlyRequested for '$label' returned Comments=$($authority.Comments) Suggestions=$($authority.Suggestions) Approval=$($authority.Approval), expected $expectComments/$expectSuggestions/$expectApproval."
}
$approvalDisabledInPolicy = ConvertTo-ReviewerGateEffectivePolicy -Policy (New-EnabledPolicy -Mode "approvalVote")
$approvalDisabledInPolicy.approval.enabled = $false
$approvalDisabledAuthority = Get-ReviewerGateWritesCurrentlyRequested -EffectivePolicy $approvalDisabledInPolicy `
    -CommentSwitchOn $true -SuggestionSwitchOn $true -ApprovalSwitchOn $true
Assert-Gate (-not [bool]$approvalDisabledAuthority.Approval) "Get-ReviewerGateWritesCurrentlyRequested granted approval authority when policy.approval.enabled was false."

# ===========================================================================
# 17. Test-ReviewerGateDecisionBinding: stale bindings close every write
#     (finding 4 - no escape hatch, only supplied keys are checked)
# ===========================================================================

$freshLiveBinding = @{
    scriptSha256 = "a" * 64; configSha256 = "b" * 64; gatePolicySha256 = "c" * 64
    gateLibrarySha256 = "d" * 64; verificationLibrarySha256 = "e" * 64; verificationPromptSha256 = "f" * 64
    verificationPolicySha256 = "1" * 64; verificationSchemaSha256 = "2" * 64; packPolicySha256 = "3" * 64
    qualificationSha256 = "4" * 64; repositoryId = "repo-1"; organization = "contoso"; project = "widgets"
    sourceCommit = "5" * 40; targetCommit = "6" * 40; changeSetDigest = "7" * 64
}
$decisionForBinding = [pscustomobject]$freshLiveBinding
$freshBindingCheck = Test-ReviewerGateDecisionBinding -Decision $decisionForBinding -LiveBinding $freshLiveBinding
Assert-Gate ([bool]$freshBindingCheck.Ok) "A decision whose EVERY recorded binding exactly matches the current live values was rejected."

$bindingMismatchTable = @(
    , @("scriptSha256", ("z" * 64), "scriptShaMismatch")
    , @("configSha256", ("z" * 64), "configShaMismatch")
    , @("gatePolicySha256", ("z" * 64), "policyShaMismatch")
    , @("packPolicySha256", ("z" * 64), "policyShaMismatch")
    , @("gateLibrarySha256", ("z" * 64), "gateLibraryShaMismatch")
    , @("verificationLibrarySha256", ("z" * 64), "gateLibraryShaMismatch")
    , @("verificationPromptSha256", ("z" * 64), "gateLibraryShaMismatch")
    , @("verificationPolicySha256", ("z" * 64), "gateLibraryShaMismatch")
    , @("verificationSchemaSha256", ("z" * 64), "gateLibraryShaMismatch")
    , @("qualificationSha256", ("z" * 64), "qualificationShaMismatch")
    , @("repositoryId", "some-other-repo", "decisionBindingMismatch")
    , @("organization", "some-other-org", "decisionBindingMismatch")
    , @("project", "some-other-project", "decisionBindingMismatch")
    , @("sourceCommit", ("8" * 40), "sourceCommitMoved")
    , @("targetCommit", ("9" * 40), "targetCommitMoved")
    , @("changeSetDigest", ("0" * 64), "changeSetMoved")
)
foreach ($case in $bindingMismatchTable) {
    $key = [string]$case[0]; $staleLiveValue = [string]$case[1]; $expectedReason = [string]$case[2]
    # A plain, freshly-built hashtable copy (not a JSON round-trip) so
    # ContainsKey/indexer semantics match the function's contract exactly.
    $staleHashtable = @{}
    foreach ($k in $freshLiveBinding.Keys) { $staleHashtable[$k] = $freshLiveBinding[$k] }
    $staleHashtable[$key] = $staleLiveValue
    $staleResult = Test-ReviewerGateDecisionBinding -Decision $decisionForBinding -LiveBinding $staleHashtable
    Assert-Gate (-not [bool]$staleResult.Ok -and ($staleResult.ReasonCodes -ccontains $expectedReason)) `
        "A decision sealed under a stale '$key' was not rejected with reason '$expectedReason' (got: $($staleResult.ReasonCodes -join ','))."
}

# No escape hatch: a key the caller does not supply is left UNCHECKED, never
# defaulted to "match" and never defaulted to "mismatch" - the caller alone
# decides what it can currently attest to.
$partialLiveBinding = @{ scriptSha256 = "a" * 64 }
$partialResult = Test-ReviewerGateDecisionBinding -Decision $decisionForBinding -LiveBinding $partialLiveBinding
Assert-Gate ([bool]$partialResult.Ok) "Supplying only ONE live binding key (a real match) was rejected; unsupplied keys must be left unchecked, not treated as mismatches."
$partialMismatchBinding = @{ scriptSha256 = "z" * 64 }
$partialMismatchResult = Test-ReviewerGateDecisionBinding -Decision $decisionForBinding -LiveBinding $partialMismatchBinding
Assert-Gate (-not [bool]$partialMismatchResult.Ok -and (@($partialMismatchResult.ReasonCodes).Count -eq 1) -and
    ($partialMismatchResult.ReasonCodes -ccontains "scriptShaMismatch")) `
    "Supplying only one live binding key (a real mismatch) did not close on exactly that one reason."
$emptyLiveBindingResult = Test-ReviewerGateDecisionBinding -Decision $decisionForBinding -LiveBinding @{}
Assert-Gate ([bool]$emptyLiveBindingResult.Ok) "An empty LiveBinding (nothing currently live to compare) was rejected; it must vacuously pass rather than assume mismatch."

# Finding 3 (Opus re-review round 3): qualification revocation. A sealed
# value of all-zero means the decision never depended on ANY qualification
# (e.g. humanPromote mode) and must always pass regardless of the live
# value - including when nothing live resolves at all. A sealed NON-zero
# value must be compared unconditionally, including against an all-zero
# LIVE value (a qualification that resolved when sealed but has since been
# removed, tampered, or had its argument dropped) - that is the revoked-
# qualification case this must close, never silently skip.
$allZeroSha256 = "0" * 64
$neverQualifiedDecision = [pscustomobject]@{ qualificationSha256 = $allZeroSha256 }
$neverQualifiedVsLiveZero = Test-ReviewerGateDecisionBinding -Decision $neverQualifiedDecision -LiveBinding @{ qualificationSha256 = $allZeroSha256 }
Assert-Gate ([bool]$neverQualifiedVsLiveZero.Ok) "A decision sealed with an all-zero qualificationSha256 (never depended on one) was rejected when the live value was also all-zero."
$neverQualifiedVsLiveReal = Test-ReviewerGateDecisionBinding -Decision $neverQualifiedDecision -LiveBinding @{ qualificationSha256 = ("4" * 64) }
Assert-Gate ([bool]$neverQualifiedVsLiveReal.Ok) "A decision sealed with an all-zero qualificationSha256 (never depended on one) was rejected merely because a real qualification is now live; it must never regress a decision that never needed one."
$revokedQualificationResult = Test-ReviewerGateDecisionBinding -Decision $decisionForBinding -LiveBinding @{ qualificationSha256 = $allZeroSha256 }
Assert-Gate ((-not [bool]$revokedQualificationResult.Ok) -and ($revokedQualificationResult.ReasonCodes -ccontains "qualificationShaMismatch")) `
    "A decision sealed under a REAL (non-zero) qualificationSha256 was NOT rejected when the live qualification is now all-zero (missing/invalid/revoked) - a revoked qualification must close a decision that depended on one, never be silently skipped."
$matchingQualificationResult = Test-ReviewerGateDecisionBinding -Decision $decisionForBinding -LiveBinding @{ qualificationSha256 = ("4" * 64) }
Assert-Gate ([bool]$matchingQualificationResult.Ok) "A decision sealed under a real qualificationSha256 was rejected when the identical qualification is still live."

# ===========================================================================
# 18. Test-ReviewerGateWriteConfirmed: confirm-by-reread, partial failure
#     (finding 6 - deterministic, no MCP session required)
# ===========================================================================

$confirmedSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
[void]$confirmedSet.Add("fingerprint-1")
[void]$confirmedSet.Add("fingerprint-2")
$fullConfirm = Test-ReviewerGateWriteConfirmed -IntendedFingerprints @("fingerprint-1", "fingerprint-2") -ConfirmedFingerprints $confirmedSet
Assert-Gate ([bool]$fullConfirm.Complete -and $fullConfirm.Posted -eq 2 -and $fullConfirm.Intended -eq 2) `
    "Every intended fingerprint was confirmed present, but completeness was not reported true."

$partialConfirmSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
[void]$partialConfirmSet.Add("fingerprint-1")
$partialConfirm = Test-ReviewerGateWriteConfirmed -IntendedFingerprints @("fingerprint-1", "fingerprint-2") -ConfirmedFingerprints $partialConfirmSet
Assert-Gate (-not [bool]$partialConfirm.Complete -and $partialConfirm.Posted -eq 1 -and $partialConfirm.Intended -eq 2) `
    "A PARTIAL comment failure (1 of 2 fingerprints confirmed) was reported complete - this is the exact condition that must prevent a vote."

$noneConfirmSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$noneConfirm = Test-ReviewerGateWriteConfirmed -IntendedFingerprints @("fingerprint-1") -ConfirmedFingerprints $noneConfirmSet
Assert-Gate (-not [bool]$noneConfirm.Complete -and $noneConfirm.Posted -eq 0) "Zero confirmed fingerprints out of one intended was reported complete."

$emptyIntendedConfirm = Test-ReviewerGateWriteConfirmed -IntendedFingerprints @() -ConfirmedFingerprints $noneConfirmSet
Assert-Gate ([bool]$emptyIntendedConfirm.Complete -and $emptyIntendedConfirm.Intended -eq 0) "Intending to post NOTHING was not reported complete (vacuously true)."

# ===========================================================================
# 19. Test-ReviewerGateSupersededBudget: hard, code-defined, policy-immune
#     ceiling on how many times a decision can be superseded at one commit
#     (Opus follow-up finding 2 - "bound superseded expiry/binding refresh
#     invitations to a small code-defined max")
# ===========================================================================

$budgetWithin0 = Test-ReviewerGateSupersededBudget -CurrentSupersededCount 0
Assert-Gate ([bool]$budgetWithin0.WithinBudget -and [int]$budgetWithin0.NextSupersededCount -eq 1) `
    "A PR never superseded before (count 0) was not granted its first supersede (count 1)."
$budgetWithin1 = Test-ReviewerGateSupersededBudget -CurrentSupersededCount 1
Assert-Gate ([bool]$budgetWithin1.WithinBudget -and [int]$budgetWithin1.NextSupersededCount -eq 2) `
    "A PR superseded once before (count 1) was not granted its second supersede (count 2), still within the budget of $($script:ReviewerGateMaxSupersededRefreshes)."
$budgetExceeded2 = Test-ReviewerGateSupersededBudget -CurrentSupersededCount 2
Assert-Gate ((-not [bool]$budgetExceeded2.WithinBudget) -and [int]$budgetExceeded2.NextSupersededCount -eq 2) `
    "A PR already superseded $($script:ReviewerGateMaxSupersededRefreshes) times was granted ANOTHER supersede instead of closing terminally, or its count changed even though it did not supersede again."
$budgetExceeded5 = Test-ReviewerGateSupersededBudget -CurrentSupersededCount 5
Assert-Gate ((-not [bool]$budgetExceeded5.WithinBudget) -and [int]$budgetExceeded5.NextSupersededCount -eq 5) `
    "A PR far past the budget was granted another supersede, or its count was changed by a denied attempt."
Assert-Gate ($script:ReviewerGateMaxSupersededRefreshes -eq 2) `
    "The shipped hard supersede-refresh ceiling changed from the expected value of 2; if this is intentional, update this pinned assertion and docs/delivery-gates.md together."
Assert-Gate ($script:ReviewerGateCapKeys -cnotcontains "maxSupersededRefreshes") `
    "maxSupersededRefreshes must never become a policy-adjustable cap key; it is a hard, code-defined ceiling no policy value can widen."
Assert-Gate (($script:ReviewerGateReasonCodes -ccontains "supersededRefreshBudgetExhausted") -and
    ($script:ReviewerGateReasonCodes -ccontains "gateProcessingFaulted")) `
    "The gate-delivery record lifecycle reason codes (supersededRefreshBudgetExhausted, gateProcessingFaulted) are missing from the closed reason-code vocabulary."

if ($failures.Count -gt 0) {
    Write-Host "Delivery-gate contract: $($failures.Count) failure(s) across $checks checks." -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host "  FAIL - $failure" -ForegroundColor Red }
    exit 1
}
Write-Host "Delivery-gate contract: all $checks checks passed." -ForegroundColor Green
