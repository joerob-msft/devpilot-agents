#Requires -Version 7.0
<#
.SYNOPSIS
    OPERATOR-ONLY tool that notarizes an already-completed evaluation corpus
    into a signed reviewer delivery-gate qualification artifact.

.DESCRIPTION
    Start-ReviewerAgent.ps1 will only run an unattended comment/suggestion or
    approval-vote gate mode when -GateQualificationFile points at a signed
    artifact meeting code-defined precision/recall/sample/false-approval
    floors (see src/Agents/reviewer/DeliveryGates.ps1). This script is how
    that artifact is produced.

    This tool is NEVER invoked by the reviewer agent. It is not reachable from
    any agent-facing surface: no CLI switch, no MCP tool, no config option
    calls it, and the agent process never shells out to it. It is an operator
    tool, run by a human, from an operator's own machine or pipeline, against
    an evaluation corpus that human already scored.

    It does not run an evaluation. It does not read a pull request, call a
    model, or compute precision/recall/sample counts from raw data - every
    statistical figure (sample counts, true/false positives, precision,
    recall, their 95% lower/upper confidence bounds, and the bound method
    used) is a MANDATORY parameter the operator supplies from a corpus run
    that already happened, entirely outside this tool. This is deliberate: an
    agent that could produce its own qualifying numbers would be grading its
    own homework, so no code path exists here for this tool to invent, infer,
    or estimate a single one of those numbers. All this tool does is validate
    the operator-supplied shape, bind it to specific file hashes and model
    names, sign it with the SAME per-user artifact-signing key
    Start-ReviewerAgent.ps1 already uses (creating that key on first use, in
    the same DPAPI-protected format, if this is run before the agent's own
    first cycle), and write it out in the exact schema the gate verifies.

    The signature proves the artifact was not edited after this tool sealed
    it and that it was sealed by whoever holds this state directory's signing
    key - the same "tamper-evidence, not operator-proofness" guarantee
    documented in Get-ReviewerArtifactSigningKey and in docs/delivery-gates.md.
    It does not, and cannot, prove the corpus numbers themselves are honest;
    that trust boundary is organizational, not cryptographic, and no tool can
    close it from inside the repository under review.

.PARAMETER StateDir
    The SAME -StateDir the target reviewer agent instance uses (or will use).
    The qualification is bound to, and signed with, this directory's
    artifact-signing.key, exactly as Get-ReviewerGateQualification reads it.
    Created if it does not yet exist, but a mismatch here silently means a
    DIFFERENT key than the one the deployed agent actually reads - always
    point this at the real deployment's state directory.

.PARAMETER OutputPath
    Where to write the signed qualification JSON. MUST resolve outside the
    repository under review (Start-ReviewerAgent.ps1 refuses a qualification
    file that resolves inside the reviewed repository); this tool only warns
    if -RepoPathToAvoid is supplied and the output resolves under it, since it
    has no other way to know which repository will eventually read this file.

.PARAMETER RepoPathToAvoid
    Optional. If supplied, this tool warns (does not fail) when -OutputPath
    resolves inside it, as a convenience check for the single most likely
    operator mistake: saving the qualification back into the reviewed clone.

.PARAMETER QualificationVersion
    Monotonic version number for this qualification, >= 1. Bump it each time
    you re-qualify so a stale qualification can be told apart from a current
    one even if both are otherwise valid and unexpired.

.PARAMETER ValidDays
    How many days from now (UTC) this qualification remains current. The gate
    additionally enforces its own code-defined maximum age ceiling regardless
    of what is written here (narrow-only), so a value here longer than that
    ceiling is accepted but has no additional effect.

.PARAMETER EvaluationToolPath
    Path to the tool/notebook/script that produced the corpus results, so its
    SHA-256 can be recorded for provenance. Mutually exclusive with
    -EvaluationToolSha256; supply exactly one.

.PARAMETER EvaluationToolSha256
    Pre-computed lowercase hex SHA-256 of the evaluation tool, if it is not
    available locally to hash directly. Mutually exclusive with
    -EvaluationToolPath; supply exactly one.

.PARAMETER CorpusName
    Human-readable name of the evaluation corpus (e.g. "reviewer-comment-eval-2025H1").

.PARAMETER CorpusVersion
    Version/tag of the corpus itself (e.g. "v3").

.PARAMETER CorpusRepositoryId
    Repository the corpus was drawn from (e.g. "owner/repo" or an ADO
    project/repo identifier).

.PARAMETER CorpusCommitSha
    Full 40-hex-character commit SHA the corpus was evaluated against.

.PARAMETER CorpusItemCount
    Total number of corpus items (>= 1).

.PARAMETER CorpusPath
    Path to a corpus manifest/archive file to hash for -CorpusSha256 directly.
    Mutually exclusive with -CorpusSha256; supply exactly one.

.PARAMETER CorpusSha256
    Pre-computed lowercase hex SHA-256 identifying the exact corpus contents.
    Mutually exclusive with -CorpusPath; supply exactly one.

.PARAMETER ReviewerScriptPath
    Path to the Start-ReviewerAgent.ps1 build this qualification is bound to.

.PARAMETER GateLibraryPath
    Path to the DeliveryGates.ps1 build this qualification is bound to.

.PARAMETER VerificationLibraryPath
    Path to the CrossVerification.ps1 build this qualification is bound to.

.PARAMETER VerificationPromptPath
    Path to the cross-verification prompt file this qualification is bound to.

.PARAMETER VerificationPolicyPath
    Path to the cross-verification policy file this qualification is bound to.

.PARAMETER VerificationSchemaPath
    Path to the cross-verification schema file this qualification is bound to.

.PARAMETER GeneralistModels
    Exactly two generalist model identifiers - the exact configured dual
    generalist pair the corpus was evaluated with.

.PARAMETER ConventionSpecialistModel
    The convention-specialist model identifier the corpus was evaluated with.

.PARAMETER ConventionVerifierModel
    The cross-verification model identifier the corpus was evaluated with.

.PARAMETER CommentScopesFile
    Optional path to a JSON file containing an array of per (pack, severity)
    comment evaluation scopes, each with EXACTLY these keys: pack, severity
    (critical|important|suggestion), sampleCount, truePositives,
    falsePositives, precision, precisionLowerBound95, recall,
    recallLowerBound95, boundMethod. Omit for an approval-only qualification
    (comment.scopes is written as an empty array).

.PARAMETER ApprovalSampleCount
    Total approval-corpus sample count (>= 0).

.PARAMETER ApprovalWouldApproveCount
    Of the approval-corpus sample, how many cases the gate's exact predicate
    would have approved (<= ApprovalSampleCount).

.PARAMETER ApprovalFalseApprovalCount
    Of the cases the gate's predicate would have approved, how many were
    actually wrong to approve. The code-defined ceiling requires this be 0
    for the approval gate to ever be reachable; a nonzero value is still
    written faithfully here; Start-ReviewerAgent.ps1 closes the approval gate
    if it exceeds the effective ceiling.

.PARAMETER ApprovalFalseApprovalUpperBound95
    Upper 95% confidence bound on the false-approval rate, in [0, 1].

.PARAMETER ApprovalBoundMethod
    Name of the statistical method used for the confidence bounds above (e.g.
    "wilson", "clopper-pearson", "jeffreys").

.PARAMETER ApprovalRecall
    Point estimate of approval recall, in [0, 1].

.PARAMETER ApprovalRecallLowerBound95
    Lower 95% confidence bound on approval recall, in [0, 1].

.EXAMPLE
    # Approval-only qualification, corpus results already computed elsewhere.
    ./tools/New-ReviewerGateQualification.ps1 `
        -StateDir "$env:LOCALAPPDATA\DevPilot\Reviewer\bpm" `
        -OutputPath "C:\secure\quals\bpm-2025-06.json" `
        -QualificationVersion 1 -ValidDays 90 `
        -EvaluationToolPath C:\eval\score_corpus.py `
        -CorpusName "bpm-approval-eval" -CorpusVersion "v1" `
        -CorpusRepositoryId "contoso/bpm" -CorpusCommitSha (git rev-parse HEAD) `
        -CorpusItemCount 400 -CorpusPath C:\eval\corpus-v1.tar.gz `
        -ReviewerScriptPath .\src\Agents\reviewer\Start-ReviewerAgent.ps1 `
        -GateLibraryPath .\src\Agents\reviewer\DeliveryGates.ps1 `
        -VerificationLibraryPath .\src\Agents\reviewer\CrossVerification.ps1 `
        -VerificationPromptPath .\src\Agents\reviewer\prompts\cross-verification.prompt.md `
        -VerificationPolicyPath .\src\Agents\reviewer\verification\v1\policy.json `
        -VerificationSchemaPath .\src\Agents\reviewer\verification\v1\decision.schema.json `
        -GeneralistModels (Get-AgentGeneralistModelPair).Models `
        -ConventionSpecialistModel (Get-AgentGeneralistModelPair).First `
        -ConventionVerifierModel (Get-AgentGeneralistModelPair).Second `
        -ApprovalSampleCount 400 -ApprovalWouldApproveCount 210 -ApprovalFalseApprovalCount 0 `
        -ApprovalFalseApprovalUpperBound95 0.009 -ApprovalBoundMethod wilson `
        -ApprovalRecall 0.97 -ApprovalRecallLowerBound95 0.94
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StateDir,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$RepoPathToAvoid,

    [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$QualificationVersion,
    [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$ValidDays,

    [string]$EvaluationToolPath,
    [ValidatePattern('^[0-9a-fA-F]{64}$')][string]$EvaluationToolSha256,

    [Parameter(Mandatory)][string]$CorpusName,
    [Parameter(Mandatory)][string]$CorpusVersion,
    [Parameter(Mandatory)][string]$CorpusRepositoryId,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$CorpusCommitSha,
    [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$CorpusItemCount,
    [string]$CorpusPath,
    [ValidatePattern('^[0-9a-fA-F]{64}$')][string]$CorpusSha256,

    [Parameter(Mandatory)][string]$ReviewerScriptPath,
    [Parameter(Mandatory)][string]$GateLibraryPath,
    [Parameter(Mandatory)][string]$VerificationLibraryPath,
    [Parameter(Mandatory)][string]$VerificationPromptPath,
    [Parameter(Mandatory)][string]$VerificationPolicyPath,
    [Parameter(Mandatory)][string]$VerificationSchemaPath,

    [Parameter(Mandatory)][ValidateCount(2, 2)][string[]]$GeneralistModels,
    [Parameter(Mandatory)][string]$ConventionSpecialistModel,
    [Parameter(Mandatory)][string]$ConventionVerifierModel,

    [string]$CommentScopesFile,

    [Parameter(Mandatory)][ValidateRange(0, [int]::MaxValue)][int]$ApprovalSampleCount,
    [Parameter(Mandatory)][ValidateRange(0, [int]::MaxValue)][int]$ApprovalWouldApproveCount,
    [Parameter(Mandatory)][ValidateRange(0, [int]::MaxValue)][int]$ApprovalFalseApprovalCount,
    [Parameter(Mandatory)][ValidateRange(0.0, 1.0)][double]$ApprovalFalseApprovalUpperBound95,
    [Parameter(Mandatory)][string]$ApprovalBoundMethod,
    [Parameter(Mandatory)][ValidateRange(0.0, 1.0)][double]$ApprovalRecall,
    [Parameter(Mandatory)][ValidateRange(0.0, 1.0)][double]$ApprovalRecallLowerBound95
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "src\Agents\reviewer\CrossVerification.ps1")
. (Join-Path $repoRoot "src\Agents\reviewer\DeliveryGates.ps1")
$qualificationSchemaPath = Join-Path $repoRoot "src\Agents\reviewer\gates\v1\qualification.schema.json"

# ---------------------------------------------------------------------------
# Argument shape checks that ValidateSet/ValidateRange cannot express.
# ---------------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($EvaluationToolPath) -eq [string]::IsNullOrWhiteSpace($EvaluationToolSha256)) {
    throw "Supply exactly one of -EvaluationToolPath or -EvaluationToolSha256."
}
if ([string]::IsNullOrWhiteSpace($CorpusPath) -eq [string]::IsNullOrWhiteSpace($CorpusSha256)) {
    throw "Supply exactly one of -CorpusPath or -CorpusSha256."
}
if ($ApprovalWouldApproveCount -gt $ApprovalSampleCount) {
    throw "-ApprovalWouldApproveCount cannot exceed -ApprovalSampleCount."
}
if ($ApprovalFalseApprovalCount -gt $ApprovalWouldApproveCount) {
    throw "-ApprovalFalseApprovalCount cannot exceed -ApprovalWouldApproveCount (a false approval is a would-approve case)."
}
foreach ($mustExistPath in @(
        $ReviewerScriptPath, $GateLibraryPath, $VerificationLibraryPath,
        $VerificationPromptPath, $VerificationPolicyPath, $VerificationSchemaPath
    )) {
    if (-not (Test-Path -LiteralPath $mustExistPath -PathType Leaf)) {
        throw "Binding file '$mustExistPath' does not exist."
    }
}
if (@($GeneralistModels | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
    throw "-GeneralistModels entries must be non-empty."
}

# ---------------------------------------------------------------------------
# Self-contained signing-key read/create, byte-compatible with
# Get-ReviewerArtifactSigningKey in Start-ReviewerAgent.ps1. Duplicated
# (rather than dot-sourcing the 7000+ line wrapper, which parses its own CLI
# params and has top-level side effects) so this operator tool stays small,
# reviewable, and safe to run outside any reviewer-agent invocation context.
# ---------------------------------------------------------------------------

function Get-ReviewerGateQualificationSigningKey {
    param([Parameter(Mandatory)][string]$KeyPath)
    if (Test-Path -LiteralPath $KeyPath) {
        $line = (Get-Content -LiteralPath $KeyPath -Raw).Trim()
        $format = $(if ($IsWindows) { 'dpapi' } else { 'raw' })
        $sep = $line.IndexOf(':')
        if ($sep -gt 0) {
            $format = $line.Substring(0, $sep)
            $line = $line.Substring($sep + 1)
        }
        $stored = [System.Convert]::FromBase64String($line)
        switch ($format) {
            'raw' { return , $stored }
            'dpapi' {
                try { return , [System.Security.Cryptography.ProtectedData]::Unprotect($stored, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser) }
                catch { throw "The artifact signing key at $KeyPath could not be decrypted for this user: $($_.Exception.Message)" }
            }
            default { throw "The artifact signing key at $KeyPath declares an unknown storage format '$format'." }
        }
    }
    Write-Warning ("No artifact-signing key exists yet at '$KeyPath': creating one now. If the target reviewer " +
        "agent has already run at least once against this state directory, this should never happen - stop and " +
        "confirm -StateDir points at the real deployment before continuing, or this qualification will be signed " +
        "with a key the deployed agent will never read.")
    $key = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($key)
    $toStore = $key
    $storedFormat = 'raw'
    if ($IsWindows) {
        try {
            $toStore = [System.Security.Cryptography.ProtectedData]::Protect($key, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
            $storedFormat = 'dpapi'
        }
        catch { Write-Warning "DPAPI is unavailable; the signing key is stored unencrypted at $KeyPath and is only as private as that file." }
    }
    Set-Content -LiteralPath $KeyPath -Value ("${storedFormat}:" + [System.Convert]::ToBase64String($toStore)) -Encoding ascii
    return , $key
}

# ---------------------------------------------------------------------------
# Resolve/derive every hash this qualification binds to.
# ---------------------------------------------------------------------------

$evaluationToolSha256Resolved = if ($EvaluationToolPath) {
    (Get-FileHash -LiteralPath $EvaluationToolPath -Algorithm SHA256).Hash.ToLowerInvariant()
} else { $EvaluationToolSha256.ToLowerInvariant() }

$corpusSha256Resolved = if ($CorpusPath) {
    (Get-FileHash -LiteralPath $CorpusPath -Algorithm SHA256).Hash.ToLowerInvariant()
} else { $CorpusSha256.ToLowerInvariant() }

$scriptSha256 = (Get-FileHash -LiteralPath $ReviewerScriptPath -Algorithm SHA256).Hash.ToLowerInvariant()
$gateLibrarySha256 = (Get-FileHash -LiteralPath $GateLibraryPath -Algorithm SHA256).Hash.ToLowerInvariant()
$verificationLibrarySha256 = (Get-FileHash -LiteralPath $VerificationLibraryPath -Algorithm SHA256).Hash.ToLowerInvariant()
$verificationPromptSha256 = (Get-FileHash -LiteralPath $VerificationPromptPath -Algorithm SHA256).Hash.ToLowerInvariant()
$verificationPolicySha256 = (Get-FileHash -LiteralPath $VerificationPolicyPath -Algorithm SHA256).Hash.ToLowerInvariant()
$verificationSchemaSha256 = (Get-FileHash -LiteralPath $VerificationSchemaPath -Algorithm SHA256).Hash.ToLowerInvariant()

# ---------------------------------------------------------------------------
# Comment scopes: optional. Each entry is validated for the EXACT schema key
# set (Test-ReviewerGateExactKeys - the same function the gate library itself
# uses to reject a policy/qualification with a typo'd or extra key) before
# being copied into the manifest.
# ---------------------------------------------------------------------------

$requiredCommentScopeKeys = @(
    "pack", "severity", "sampleCount", "truePositives", "falsePositives",
    "precision", "precisionLowerBound95", "recall", "recallLowerBound95", "boundMethod"
)
$commentScopes = @()
if ($CommentScopesFile) {
    if (-not (Test-Path -LiteralPath $CommentScopesFile -PathType Leaf)) {
        throw "-CommentScopesFile '$CommentScopesFile' does not exist."
    }
    $rawScopes = @(Get-Content -LiteralPath $CommentScopesFile -Raw | ConvertFrom-Json -Depth 8)
    foreach ($scope in $rawScopes) {
        if (-not (Test-ReviewerGateExactKeys -Object $scope -Allowed $requiredCommentScopeKeys)) {
            throw "A -CommentScopesFile entry does not have exactly the required keys: $($requiredCommentScopeKeys -join ', ')."
        }
        $severity = [string]$scope.severity
        if ($script:ReviewerGateSeverities -cnotcontains $severity) {
            throw "A -CommentScopesFile entry has an unrecognized severity '$severity'."
        }
        if ([string]::IsNullOrWhiteSpace([string]$scope.pack)) { throw "A -CommentScopesFile entry has an empty pack." }
        foreach ($fraction in @("precision", "precisionLowerBound95", "recall", "recallLowerBound95")) {
            $value = [double]$scope.$fraction
            if ($value -lt 0.0 -or $value -gt 1.0) { throw "A -CommentScopesFile entry's '$fraction' must be in [0, 1]." }
        }
        foreach ($count in @("sampleCount", "truePositives", "falsePositives")) {
            if ([int]$scope.$count -lt 0) { throw "A -CommentScopesFile entry's '$count' cannot be negative." }
        }
        if ([string]::IsNullOrWhiteSpace([string]$scope.boundMethod)) { throw "A -CommentScopesFile entry has an empty boundMethod." }
        $commentScopes += , ([ordered]@{
                pack                   = [string]$scope.pack
                severity               = $severity
                sampleCount            = [int]$scope.sampleCount
                truePositives          = [int]$scope.truePositives
                falsePositives         = [int]$scope.falsePositives
                precision              = [double]$scope.precision
                precisionLowerBound95  = [double]$scope.precisionLowerBound95
                recall                 = [double]$scope.recall
                recallLowerBound95     = [double]$scope.recallLowerBound95
                boundMethod            = [string]$scope.boundMethod
            })
    }
}

# ---------------------------------------------------------------------------
# Assemble, schema-validate, sign, write, and round-trip verify.
# ---------------------------------------------------------------------------

$issuedAtUtc = [DateTime]::UtcNow
$expiresAtUtc = $issuedAtUtc.AddDays($ValidDays)

$manifest = [ordered]@{
    kind                  = $script:ReviewerGateQualificationKind
    artifactVersion       = $script:ReviewerGateArtifactVersion
    schemaVersion         = $script:ReviewerGateSchemaVersion
    qualificationVersion  = $QualificationVersion
    issuedAtUtc           = $issuedAtUtc.ToString("o")
    expiresAtUtc          = $expiresAtUtc.ToString("o")
    evaluationToolSha256  = $evaluationToolSha256Resolved
    corpus                = [ordered]@{
        name         = $CorpusName
        version      = $CorpusVersion
        repositoryId = $CorpusRepositoryId
        commitSha    = $CorpusCommitSha.ToLowerInvariant()
        itemCount    = $CorpusItemCount
        sha256       = $corpusSha256Resolved
    }
    agentBinding          = [ordered]@{
        scriptSha256               = $scriptSha256
        gateLibrarySha256          = $gateLibrarySha256
        verificationLibrarySha256 = $verificationLibrarySha256
        verificationPromptSha256  = $verificationPromptSha256
        verificationPolicySha256  = $verificationPolicySha256
        verificationSchemaSha256  = $verificationSchemaSha256
        generalistModels           = @($GeneralistModels)
        conventionSpecialistModel = $ConventionSpecialistModel
        conventionVerifierModel   = $ConventionVerifierModel
    }
    comment               = [ordered]@{ scopes = @($commentScopes) }
    approval              = [ordered]@{
        sampleCount               = $ApprovalSampleCount
        wouldApproveCount         = $ApprovalWouldApproveCount
        falseApprovalCount        = $ApprovalFalseApprovalCount
        falseApprovalUpperBound95 = $ApprovalFalseApprovalUpperBound95
        boundMethod                = $ApprovalBoundMethod
        recall                     = $ApprovalRecall
        recallLowerBound95         = $ApprovalRecallLowerBound95
    }
}

$manifestJsonForSchemaCheck = $manifest | ConvertTo-Json -Depth 10
if (-not (Test-Json -Json $manifestJsonForSchemaCheck -SchemaFile $qualificationSchemaPath)) {
    throw "The assembled qualification manifest failed its own versioned JSON schema; this is a bug in this tool, not an operator input error."
}

if ($RepoPathToAvoid -and (Test-Path -LiteralPath $RepoPathToAvoid -PathType Container)) {
    $resolvedRepoPathToAvoid = (Resolve-Path -LiteralPath $RepoPathToAvoid).Path.TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $resolvedOutputParent = Split-Path -Parent $OutputPath
    if ($resolvedOutputParent -and (Test-Path -LiteralPath $resolvedOutputParent -PathType Container)) {
        $resolvedOutputParentFull = (Resolve-Path -LiteralPath $resolvedOutputParent).Path
        if ($resolvedOutputParentFull -ieq $resolvedRepoPathToAvoid -or
            $resolvedOutputParentFull.StartsWith($resolvedRepoPathToAvoid + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Warning ("-OutputPath resolves inside -RepoPathToAvoid ('$RepoPathToAvoid'). " +
                "Start-ReviewerAgent.ps1 refuses a qualification file that resolves inside the reviewed " +
                "repository - move this file outside it before pointing -GateQualificationFile at it.")
        }
    }
}

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
$resolvedStateDir = (Resolve-Path -LiteralPath $StateDir).Path
$keyPath = Join-Path $resolvedStateDir "artifact-signing.key"
$masterKey = Get-ReviewerGateQualificationSigningKey -KeyPath $keyPath

$outputDirectory = Split-Path -Parent $OutputPath
if (-not $outputDirectory) { $outputDirectory = "." }
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
$outputDirectory = (Resolve-Path -LiteralPath $outputDirectory).Path
$baseName = [IO.Path]::GetFileNameWithoutExtension($OutputPath)
if ($baseName -notmatch '^[A-Za-z0-9._-]+$') {
    throw "-OutputPath's file name ('$baseName') must match [A-Za-z0-9._-]+ once its extension is removed."
}

$savedPath = Save-ReviewerGateQualification -Manifest ([pscustomobject]$manifest) -Directory $outputDirectory `
    -BaseName $baseName -MasterKey $masterKey

$roundTrip = Read-ReviewerGateQualification -Path $savedPath -MasterKey $masterKey
if (-not $roundTrip.Ok) {
    throw "The qualification artifact was written but failed its own round-trip verification ($($roundTrip.ReasonCodes -join ', ')). This is a bug in this tool; the file at '$savedPath' should be deleted."
}

Write-Host "Qualification artifact written and verified: $savedPath" -ForegroundColor Green
Write-Host "  kind                 : $($manifest.kind) (schemaVersion $($manifest.schemaVersion), qualificationVersion $($manifest.qualificationVersion))"
Write-Host "  issued / expires     : $($manifest.issuedAtUtc)  ->  $($manifest.expiresAtUtc)  ($ValidDays day(s))"
Write-Host "  corpus               : $CorpusName $CorpusVersion @ $CorpusRepositoryId#$($CorpusCommitSha.ToLowerInvariant()) ($CorpusItemCount items)"
Write-Host "  agent binding models : generalists=[$($GeneralistModels -join ', ')] specialist=$ConventionSpecialistModel verifier=$ConventionVerifierModel"
if ($commentScopes.Count -gt 0) {
    Write-Host "  comment scopes       :"
    foreach ($scope in $commentScopes) {
        Write-Host ("    {0,-20} {1,-11} n={2,-6} precisionLB95={3:0.000} recallLB95={4:0.000}" -f `
                $scope.pack, $scope.severity, $scope.sampleCount, $scope.precisionLowerBound95, $scope.recallLowerBound95)
    }
}
else {
    Write-Host "  comment scopes       : (none - approval-only qualification)"
}
Write-Host ("  approval             : n={0} wouldApprove={1} falseApprovals={2} falseApprovalUB95={3:0.000} recallLB95={4:0.000} ({5})" -f `
        $ApprovalSampleCount, $ApprovalWouldApproveCount, $ApprovalFalseApprovalCount, `
        $ApprovalFalseApprovalUpperBound95, $ApprovalRecallLowerBound95, $ApprovalBoundMethod)
Write-Host ""
Write-Host "Point Start-ReviewerAgent.ps1 -GateQualificationFile at this path (from outside the reviewed repository)." -ForegroundColor DarkGray
