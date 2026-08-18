#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Deterministic, model-free behavior suite for the blinded transcript acquisition runner.

.DESCRIPTION
    Exercises tools/Invoke-ReviewerBlindedAcquisition.ps1 end-to-end against the offline
    deterministic adapter. A telemetry-wiring regression also drives the production
    subprocess boundary into a local pwsh-backed stub. No real model, network, provider,
    ADO or GitHub write is ever performed; adapter scenarios assert zero real-model starts,
    while the production-boundary regression proves the real-model event detector fires.

    Coverage: success (opus + gpt); missing / truncated / saturated marker retry with a
    fresh distinct nonce; terminal schema/binding failure with no retry; crash; hanging
    grandchild timeout -> exit 124 with recursive tree kill; every input gate (oracle
    leakage, wrong role/model/HEAD/ref/base/snapshot/token, verifier-before-discovery,
    candidate-on-non-verifier, duplicate/consumed lease); verifier candidate independence
    + cluster-hash binding; asymmetric credential boundary + zero-write proof; oracle-free sealed
    package; and tamper / missing / cross-substitution seal verification.
#>
[CmdletBinding()]
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Fixed inputs (all in-repo; no private fixtures, no employer specifics)
# ---------------------------------------------------------------------------
$tool = Join-Path $PSScriptRoot 'Invoke-ReviewerBlindedAcquisition.ps1'
$fixtureRoot = Join-Path $RepoRoot 'src\Agents\reviewer\testdata\exact-path'
$replayRoot = Join-Path $RepoRoot 'src\Agents\reviewer\testdata\replay-v1'
$adapterReal = (Resolve-Path (Join-Path $RepoRoot 'src\Agents\reviewer\offline\Invoke-ReviewerModelAdapter.ps1')).Path
$baseManifest = Join-Path $fixtureRoot 'adapter-manifest.json'
$promptSrc = Join-Path $RepoRoot 'src\Agents\reviewer\review-cycle.prompt.md'
$genProjection = (Resolve-Path (Join-Path $RepoRoot 'tools\testdata\reviewer-acquisition-generalist-projection.json')).Path
$verProjection = (Resolve-Path (Join-Path $RepoRoot 'tools\testdata\reviewer-acquisition-verifier-projection.json')).Path
$candidateFile = (Resolve-Path (Join-Path $RepoRoot 'tools\testdata\reviewer-acquisition-discovery-candidate.json')).Path

$digest = [string]((Get-Content (Join-Path $replayRoot 'synthetic-pr\manifest.json') -Raw | ConvertFrom-Json).manifestDigest)
$expectedBase = [string]((Get-Content $baseManifest -Raw | ConvertFrom-Json).expectedBaseCommit)

# A throwaway full ref materialized only under a detached HEAD; deleted on exit.
$script:TempRef = $null
# A second throwaway ref pointing at a DIFFERENT commit, for the valid-but-wrong
# ref regression (blocker 7); deleted on exit.
$script:WrongRef = $null
$script:WrongRefCommit = $null
$runId = [Guid]::NewGuid().ToString('N')
Push-Location $RepoRoot
try {
    $head = (& git rev-parse HEAD).Trim()
    # The acquisition tool requires ExpectedRef to be a FULL ref (refs/...) that
    # resolves to EXACTLY HEAD; a bare commit id is refused. Prefer the checked-out
    # branch's symbolic ref. Under a detached HEAD (a CI pull_request checkout) there
    # is no branch ref, so materialize a throwaway full ref at HEAD and delete it on
    # exit - never falling back to a bare commit that the tool would reject.
    $symbolic = (& git symbolic-ref --quiet HEAD 2>$null)
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($symbolic)) {
        $ref = $symbolic.Trim()
    }
    else {
        $script:TempRef = "refs/acq-harness/$runId/head"
        & git update-ref $script:TempRef $head 2>$null | Out-Null
        $ref = $script:TempRef
    }
    # A full ref that EXISTS but resolves to a different commit than HEAD (the
    # parent commit), for the valid-but-wrong-ref refusal. Only creatable when a
    # parent commit exists; the b7 test is skipped gracefully otherwise.
    $parent = (& git rev-parse --verify --quiet 'HEAD~1' 2>$null)
    if ($LASTEXITCODE -eq 0 -and $parent) {
        $script:WrongRefCommit = $parent.Trim()
        $script:WrongRef = "refs/acq-harness/$runId/wrong"
        & git update-ref $script:WrongRef $script:WrongRefCommit 2>$null | Out-Null
    }
}
finally { Pop-Location }

# ---------------------------------------------------------------------------
# Repo-relative scratch (never committed; removed on entry and exit)
# ---------------------------------------------------------------------------
$runRoot = Join-Path $RepoRoot ("_acq_test_tmp-" + $runId)
function Remove-Tree {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
            ForEach-Object { try { $_.Attributes = 'Normal' } catch { } }
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}
function Get-LaunchLeasePath {
    param([Parameter(Mandatory)][string]$OutputRoot)
    $full = [IO.Path]::GetFullPath($OutputRoot)
    $parent = [IO.Path]::GetDirectoryName($full)
    $leaf = [IO.Path]::GetFileName($full.TrimEnd(
            [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($full)
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    return Join-Path $parent (".$leaf.$($hash.Substring(0, 16)).acquisition.lease")
}
Remove-Tree $runRoot
New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
$configDir = Join-Path $runRoot 'config'
$logDir = Join-Path $runRoot 'logs'
$manRoot = Join-Path $runRoot 'manifests'
New-Item -ItemType Directory -Force -Path $configDir, $logDir, $manRoot | Out-Null
Copy-Item (Join-Path $fixtureRoot 'reviewer.config.json') (Join-Path $configDir 'reviewer.config.json') -Force
Copy-Item $promptSrc (Join-Path $configDir 'review-cycle.prompt.md') -Force
$configFile = Join-Path $configDir 'reviewer.config.json'
$verificationConfigFile = Join-Path $configDir 'reviewer-verification.config.json'
$verificationConfig = Get-Content $configFile -Raw | ConvertFrom-Json -Depth 64
$verificationConfig.review.conventionSpecialistModel = 'claude-sonnet-5'
$verificationConfig.review.verification.enabled = $true
$verificationConfig.review.verification.conventionVerifierModel = 'gpt-5.6-sol'
[IO.File]::WriteAllText($verificationConfigFile,
    ($verificationConfig | ConvertTo-Json -Depth 64), [Text.UTF8Encoding]::new($false))
$sealKey = Join-Path $runRoot 'seal.key'

# -- Convention snapshot inputs (specialist role): a sealed replay snapshot that
#    actually serves repo identity so a convention pack is selected and the
#    specialist launches a real (stub) subprocess, plus its config variant whose
#    authoritative-source pin matches the served content.
$conventionReplayRoot = (Resolve-Path (Join-Path $RepoRoot 'tools\testdata\replay-convention')).Path
$conventionDigest = [string]((Get-Content (Join-Path $conventionReplayRoot 'synthetic-convention-pr\manifest.json') -Raw | ConvertFrom-Json).manifestDigest)
$spConfigDir = Join-Path $runRoot 'config-convention'
New-Item -ItemType Directory -Force -Path $spConfigDir | Out-Null
Copy-Item (Join-Path $conventionReplayRoot 'reviewer.config.json') (Join-Path $spConfigDir 'reviewer.config.json') -Force
Copy-Item $promptSrc (Join-Path $spConfigDir 'review-cycle.prompt.md') -Force
$spConfigFile = Join-Path $spConfigDir 'reviewer.config.json'
$reviewerScript = (Resolve-Path (Join-Path $RepoRoot 'src\Agents\reviewer\Start-ReviewerAgent.ps1')).Path
. (Join-Path $RepoRoot 'src\Agents\reviewer\AcquisitionPackage.ps1')
. (Join-Path $RepoRoot 'src\Agents\reviewer\ReviewFacts.ps1')

# The production plan binds the current reviewer script. Materialize a run-local
# fixture projection so any legitimate wrapper edit keeps the fixture exact while
# stale or tampered script bindings are still rejected by the child.
$spProjection = Join-Path $runRoot 'specialist-projection.json'
$spProjectionObject = Get-Content `
    (Join-Path $RepoRoot 'tools\testdata\reviewer-acquisition-specialist-projection.json') -Raw |
    ConvertFrom-Json -Depth 100
$currentReviewerSha = (Get-FileHash -LiteralPath $reviewerScript -Algorithm SHA256).Hash.ToLowerInvariant()
$spConventionPlan = $spProjectionObject.specialist.conventionPlanJson | ConvertFrom-Json -Depth 100
$spConventionPlan.scriptSha256 = $currentReviewerSha
$spProjectionObject.specialist.conventionPlanJson = $spConventionPlan | ConvertTo-Json -Depth 100 -Compress
$spFactPlan = $spProjectionObject.specialist.factPlanJson | ConvertFrom-Json -Depth 100
@($spFactPlan.hashes.scriptClosure | Where-Object {
        [string]$_.path -ceq 'Start-ReviewerAgent.ps1'
    })[0].sha256 = $currentReviewerSha
$spFactBody = [pscustomobject][ordered]@{
    planVersion = $spFactPlan.planVersion; schemaVersion = $spFactPlan.schemaVersion
    extractorVersion = $spFactPlan.extractorVersion; status = $spFactPlan.status
    binding = $spFactPlan.binding; hashes = $spFactPlan.hashes; domains = $spFactPlan.domains
    facts = $spFactPlan.facts; factCount = $spFactPlan.factCount
}
$spFactCanonical = ConvertTo-ReviewerFactCanonicalJson -Value $spFactBody
$spFactPlan.canonicalBytes = [Text.UTF8Encoding]::new($false).GetByteCount($spFactCanonical)
$spFactPlan.planSha256 = Get-ReviewerFactSha256 -Text $spFactCanonical
$spProjectionObject.specialist.factPlanJson = $spFactPlan | ConvertTo-Json -Depth 100 -Compress
[IO.File]::WriteAllText($spProjection, ($spProjectionObject | ConvertTo-Json -Depth 100),
    [Text.UTF8Encoding]::new($false))

# ---------------------------------------------------------------------------
# Result harness
# ---------------------------------------------------------------------------
$script:Results = [System.Collections.Generic.List[object]]::new()
function Check {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][bool]$Cond, [string]$Detail = '')
    $script:Results.Add([pscustomobject]@{ Name = $Name; Ok = $Cond; Detail = $Detail })
    $tag = if ($Cond) { 'PASS' } else { 'FAIL' }
    $color = if ($Cond) { 'Green' } else { 'Red' }
    $suffix = if ($Detail) { "  ($Detail)" } else { '' }
    Write-Host ("  [{0}] {1}{2}" -f $tag, $Name, $suffix) -ForegroundColor $color
}

function Read-Json { param([string]$Path) return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 64) }

# Clone the exact-path adapter manifest into its own directory, repoint adapterScript
# at the real (unchanged) adapter via a RELATIVE path, and mutate the blinded generalist
# role's behavior. adapterScriptSha256 stays valid because the script bytes never change.
function New-VariantManifest {
    param([Parameter(Mandatory)][string]$Tag, [Parameter(Mandatory)][string]$Behavior, [hashtable]$RoleExtra,
        [string]$RoleName = 'blind-opus', [string]$AdapterScriptOverride)
    $dir = Join-Path $manRoot $Tag
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $m = Get-Content $baseManifest -Raw | ConvertFrom-Json -Depth 64
    $m.adapterScript = if ($AdapterScriptOverride) { [IO.Path]::GetRelativePath($dir, $AdapterScriptOverride) } else { [IO.Path]::GetRelativePath($dir, $adapterReal) }
    $m.roles.$RoleName.behavior = $Behavior
    if ($RoleExtra) { foreach ($k in $RoleExtra.Keys) { $m.roles.$RoleName | Add-Member -NotePropertyName $k -NotePropertyValue $RoleExtra[$k] -Force } }
    $path = Join-Path $dir 'adapter-manifest.json'
    ($m | ConvertTo-Json -Depth 64) | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Get-CommonArgs {
    param(
        [Parameter(Mandatory)][string]$Out, [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string]$Projection, [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$Manifest, [string]$SnapshotDigest = $digest,
        [string]$SecondGeneralistModel = $(if ($Model -ceq 'gpt-5.6-sol') { 'claude-opus-5' } else { 'gpt-5.6-sol' }),
        [string]$Config = $configFile,
        [string]$SpecialistModel,
        [switch]$OmitSecondGeneralistModel,
        [int]$PerCall = 30, [int]$Total = 90, [int]$Activity = 30
    )
    $args = @(
        '-Role', $Role, '-FixtureProjectionFile', $Projection, '-Model', $Model,
        '-ConfigFile', $Config, '-ReplayRoot', $replayRoot,
        '-ReplaySnapshotName', 'synthetic-pr', '-ReplayManifestDigest', $SnapshotDigest,
        '-OfflineModelAdapterManifest', $Manifest, '-ExpectedReviewerBaseCommit', $expectedBase,
        '-PullRequestId', '4242', '-ExpectedHeadCommit', $head, '-ExpectedRef', $ref,
        '-OutputRoot', $Out, '-SealKeyPath', $sealKey, '-AllowDirtyWorktree', '-UseOfflineStubAdapter',
        '-PerCallTimeoutSeconds', "$PerCall", '-TotalTimeoutSeconds', "$Total", '-ActivityTimeoutSeconds', "$Activity"
    )
    if (-not $OmitSecondGeneralistModel) {
        $args += @('-SecondGeneralistModel', $SecondGeneralistModel)
    }
    if ($SpecialistModel) {
        $args += @('-ConventionSpecialistModel', $SpecialistModel)
    }
    return $args
}

function Get-ProductionArgs {
    param([Parameter(Mandatory)][string]$Out)
    return @(
        '-Role', 'generalist', '-FixtureProjectionFile', $genProjection, '-Model', 'claude-opus-5',
        '-SecondGeneralistModel', 'gpt-5.6-sol',
        '-ConfigFile', $configFile, '-ReplayRoot', $replayRoot,
        '-ReplaySnapshotName', 'synthetic-pr', '-ReplayManifestDigest', $digest,
        '-ExpectedReviewerBaseCommit', $expectedBase,
        '-PullRequestId', '4242', '-ExpectedHeadCommit', $head, '-ExpectedRef', $ref,
        '-OutputRoot', $Out, '-SealKeyPath', $sealKey, '-AllowDirtyWorktree',
        '-PerCallTimeoutSeconds', '30', '-TotalTimeoutSeconds', '90', '-ActivityTimeoutSeconds', '30'
    )
}

function Invoke-Tool {
    param([Parameter(Mandatory)][string[]]$ToolArgs, [Parameter(Mandatory)][string]$LogName)
    $log = Join-Path $logDir $LogName
    & pwsh -NoProfile -File $tool @ToolArgs *> $log
    return [pscustomobject]@{ Exit = $LASTEXITCODE; Log = $log }
}

function New-OutDir { param([string]$Name) $p = Join-Path $runRoot $Name; return $p }

# The exact production parser/run status literals (disjoint from the old coarse
# ok/timeout/processFailure/markerMissing/terminal remaps). Membership proves the
# sealed attempt preserved a real production classification, not a remap.
$script:ProductionMarkerStatuses = @(
    'success', 'missingMarker', 'malformedMarker', 'nonObject', 'truncated',
    'overflow', 'schemaInvalid', 'wrongBinding', 'ambiguousMarker',
    'modelMismatch', 'staleBinding', 'verdictSetMismatch', 'toolViolation'
)

function Assert-ExactAttempt {
    # Blocker 3: a sealed attempt record must preserve the EXACT production parser/
    # run status, the human reason string and the offending-field detail verbatim -
    # never a coarse ok/terminal/markerMissing remap and never the typed class
    # echoed back as the reason.
    param(
        [Parameter(Mandatory)]$Attempt, [Parameter(Mandatory)][string]$Label,
        [string]$ExpectStatus = '', [object]$ExpectRetryable = $null,
        [switch]$ExpectDetailNonEmpty, [string]$ExpectDetail = '', [string]$ReasonLike = ''
    )
    $st = [string]$Attempt.markerStatus
    $rs = [string]$Attempt.reason
    $dt = [string]$Attempt.detail
    Check "$Label markerStatus is a production class" ($script:ProductionMarkerStatuses -ccontains $st) ("got='$st'")
    if ($ExpectStatus) { Check "$Label markerStatus=$ExpectStatus" ($st -ceq $ExpectStatus) ("got='$st'") }
    # The reason is a human string, never the typed class echoed back (blocker 3).
    Check "$Label reason is a non-empty human string (not the class)" ($rs.Length -gt 0 -and $rs -cne $st) ("reason='$rs' status='$st'")
    if ($ReasonLike) { Check "$Label reason names the offending detail" ($rs -match $ReasonLike) ("reason='$rs'") }
    if ($null -ne $ExpectRetryable) { Check "$Label retryable=$ExpectRetryable" ([bool]$Attempt.retryable -eq [bool]$ExpectRetryable) ("got=$([bool]$Attempt.retryable)") }
    if ($ExpectDetailNonEmpty) { Check "$Label detail names the offending field" ($dt.Length -gt 0) ("detail='$dt'") }
    if ($ExpectDetail) { Check "$Label detail=$ExpectDetail" ($dt -ceq $ExpectDetail) ("got='$dt'") }
}

# Build the full verifier acquisition arg set: a verifier drives the EXACT
# production cross-verification cycle, so it needs the surrounding cross-check
# model set plus the sealed discovery package + independently captured candidate.
function Get-VerifierArgs {
    param([Parameter(Mandatory)][string]$Out, [Parameter(Mandatory)][string]$Manifest,
        [Parameter(Mandatory)][string]$DiscoveryPackage, [Parameter(Mandatory)][string]$Candidate,
        [string]$Model = 'claude-opus-5', [string]$SpecialistModel = 'claude-sonnet-5',
        [int]$PerCall = 45, [int]$Total = 160, [int]$Activity = 60,
        [switch]$UseConventionSnapshot)
    # The reciprocal cross-verification pair is the canonical {opus, gpt} generalist
    # pair; the verifier model to capture is one of them, so the OTHER configured
    # generalist model is simply its partner. Naming the partner (never the verifier
    # model itself) as the second generalist keeps the two configured review-pass
    # models distinct while still binding the sealed discovery (opus) model as one of
    # them - a GPT verifier therefore pairs with opus, an opus verifier with gpt.
    $partnerGeneralist = if ($Model -ceq 'gpt-5.6-sol') { 'claude-opus-5' } else { 'gpt-5.6-sol' }
    $verifierConfig = if ($UseConventionSnapshot) { $spConfigFile } else { $configFile }
    $verifierReplayRoot = if ($UseConventionSnapshot) { $conventionReplayRoot } else { $replayRoot }
    $verifierSnapshot = if ($UseConventionSnapshot) { 'synthetic-convention-pr' } else { 'synthetic-pr' }
    $verifierDigest = if ($UseConventionSnapshot) { $conventionDigest } else { $digest }
    return @(
        '-Role', 'verifier', '-FixtureProjectionFile', $verProjection, '-Model', $Model,
        '-ConfigFile', $verifierConfig, '-ReplayRoot', $verifierReplayRoot,
        '-ReplaySnapshotName', $verifierSnapshot, '-ReplayManifestDigest', $verifierDigest,
        '-OfflineModelAdapterManifest', $Manifest, '-ExpectedReviewerBaseCommit', $expectedBase,
        '-PullRequestId', '4242', '-ExpectedHeadCommit', $head, '-ExpectedRef', $ref,
        '-OutputRoot', $Out, '-SealKeyPath', $sealKey, '-AllowDirtyWorktree', '-UseOfflineStubAdapter',
        '-CandidateInputFile', $Candidate, '-DiscoveryPackageRoot', $DiscoveryPackage,
        '-SecondGeneralistModel', $partnerGeneralist, '-ConventionSpecialistModel', $SpecialistModel,
        '-PerCallTimeoutSeconds', "$PerCall", '-TotalTimeoutSeconds', "$Total", '-ActivityTimeoutSeconds', "$Activity"
    )
}

function Copy-MutatedCandidate {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Mutation
    )
    $candidate = Get-Content -LiteralPath $Source -Raw -Encoding UTF8 |
        ConvertFrom-Json -AsHashtable -Depth 64
    & $Mutation $candidate
    $path = Join-Path $runRoot $Name
    [IO.File]::WriteAllText(
        $path,
        ($candidate | ConvertTo-Json -Depth 64),
        [Text.UTF8Encoding]::new($false))
    return $path
}

function Copy-ResealedPackageVariant {
    param(
        [Parameter(Mandatory)][string]$SourcePackage,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Mutation
    )
    $root = New-OutDir $Name
    Remove-Tree $root
    $package = Join-Path $root 'package'
    Copy-Item -LiteralPath $SourcePackage -Destination $package -Recurse -Force
    Get-ChildItem -LiteralPath $package -Recurse -Force |
        ForEach-Object { try { $_.Attributes = 'Normal' } catch { } }

    $corePath = Join-Path $package 'capture-core.json'
    $core = Get-Content -LiteralPath $corePath -Raw -Encoding UTF8 |
        ConvertFrom-Json -AsHashtable -Depth 64
    $manifestPath = Join-Path $package 'transcript-package.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 |
        ConvertFrom-Json -AsHashtable -Depth 64
    & $Mutation $core $manifest
    $coreText = ConvertTo-ReviewerAcquisitionPackageCanonicalText -JsonText (
        $core | ConvertTo-Json -Depth 64 -Compress)
    [IO.File]::WriteAllText($corePath, $coreText, [Text.UTF8Encoding]::new($false))

    $coreEntry = @($manifest.files | Where-Object { [string]$_.name -ceq 'capture-core.json' })[0]
    $coreEntry.bytes = [IO.File]::ReadAllBytes($corePath).Length
    $coreEntry.sha256 = (Get-FileHash -LiteralPath $corePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifestText = ConvertTo-ReviewerAcquisitionPackageCanonicalText -JsonText (
        $manifest | ConvertTo-Json -Depth 64 -Compress)
    [IO.File]::WriteAllText($manifestPath, $manifestText, [Text.UTF8Encoding]::new($false))

    $key = [IO.File]::ReadAllBytes($sealKey)
    $hmac = [Security.Cryptography.HMACSHA256]::new($key)
    try {
        $hmacHex = [Convert]::ToHexString(
            $hmac.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($manifestText))).ToLowerInvariant()
    }
    finally { $hmac.Dispose() }
    $seal = [ordered]@{
        schemaVersion = 1
        kind = 'reviewer-blinded-transcript-package-seal'
        manifestSha256 = Get-ReviewerAcquisitionPackageTextSha256 -Text $manifestText
        manifestHmac = $hmacHex
        sealedUtc = [DateTime]::UtcNow.ToString('o')
    }
    [IO.File]::WriteAllText(
        (Join-Path $package 'transcript-package.seal'),
        ($seal | ConvertTo-Json -Depth 8),
        [Text.UTF8Encoding]::new($false))
    Get-ChildItem -LiteralPath $package -File -Recurse -Force |
        ForEach-Object { $_.Attributes = $_.Attributes -bor [IO.FileAttributes]::ReadOnly }
    return $package
}

function Copy-ResealedPackageWithStaleScript {
    param([Parameter(Mandatory)][string]$SourcePackage)
    return Copy-ResealedPackageVariant -SourcePackage $SourcePackage `
        -Name 'specialist_stale_script' -Mutation {
            param($core, $manifest)
            $core.digests.scriptSha256 = ('0' * 64)
            $manifest.digests.scriptSha256 = ('0' * 64)
        }
}

function Copy-ResealedPackageWithoutSourceProjection {
    param([Parameter(Mandatory)][string]$SourcePackage)
    return Copy-ResealedPackageVariant -SourcePackage $SourcePackage `
        -Name 'specialist_legacy_package' -Mutation {
            param($core, $manifest)
            [void]$core.Remove('sourceProjection')
            [void]$core.Remove('conventionSpecialistEnabled')
            [void]$core.Remove('conventionSpecialistModel')
            [void]$manifest.Remove('conventionSpecialistEnabled')
            [void]$manifest.Remove('conventionSpecialistModel')
        }
}

# Build the full specialist acquisition arg set against the convention snapshot
# (which serves repo identity so a convention pack is selected and the specialist
# launches). The captured model is the convention specialist; the surrounding
# generalist pair is named separately for the exact production input build.
function Get-SpecialistArgs {
    param([Parameter(Mandatory)][string]$Out, [Parameter(Mandatory)][string]$Manifest,
        [string]$Model = 'claude-sonnet-5', [int]$PerCall = 45, [int]$Total = 160, [int]$Activity = 60)
    return @(
        '-Role', 'specialist', '-FixtureProjectionFile', $spProjection, '-Model', $Model,
        '-ConfigFile', $spConfigFile, '-ReplayRoot', $conventionReplayRoot,
        '-ReplaySnapshotName', 'synthetic-convention-pr', '-ReplayManifestDigest', $conventionDigest,
        '-OfflineModelAdapterManifest', $Manifest, '-ExpectedReviewerBaseCommit', $expectedBase,
        '-PullRequestId', '4242', '-ExpectedHeadCommit', $head, '-ExpectedRef', $ref,
        '-OutputRoot', $Out, '-SealKeyPath', $sealKey, '-AllowDirtyWorktree', '-UseOfflineStubAdapter',
        '-DiscoveryGeneralistModel', 'claude-opus-5', '-SecondGeneralistModel', 'gpt-5.6-sol',
        '-PerCallTimeoutSeconds', "$PerCall", '-TotalTimeoutSeconds', "$Total", '-ActivityTimeoutSeconds', "$Activity"
    )
}

# Invoke Start-ReviewerAgent.ps1's acquisition gate DIRECTLY (bypassing the outer
# supervisor) to prove the inner authorization-token gate and adapter containment
# refuse before any launch. Reuses a real plan + its bound projection; the token is
# handed only through the scrubbed env var, never argv. A fresh empty output root is
# supplied because the gates fire before any output-root binding.
function Invoke-ChildDirect {
    param(
        [Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)][string]$PlanFile,
        [Parameter(Mandatory)][string]$Projection, [string]$Model = 'claude-opus-5',
        [hashtable]$Env = @{}, [switch]$OmitTestOnlySwitch, [switch]$ForbiddenTelemetryOnly,
        [string]$AdapterManifest,
        [string]$RepoPathOverride, [string]$OutputRootOverride, [string]$StateDirOverride,
        [string]$Config = $configFile, [switch]$EnableSpecialist,
        [string]$SpecialistModel
    )
    $man = if ($AdapterManifest) { $AdapterManifest } else { $baseManifest }
    $od = if ($OutputRootOverride) { $OutputRootOverride } else { $p = New-OutDir ("direct_" + $Label); Remove-Tree $p; New-Item -ItemType Directory -Force -Path $p | Out-Null; $p }
    $st = if ($StateDirOverride) { $StateDirOverride } else { Join-Path $runRoot ("directstate_" + $Label) }
    New-Item -ItemType Directory -Force -Path $st | Out-Null
    $rp = if ($RepoPathOverride) { $RepoPathOverride } else { $RepoRoot }
    $tp = Join-Path $runRoot ("directtel_" + $Label + ".jsonl")
    $childArgs = @(
        '-NoProfile', '-File', $reviewerScript, '-Once', '-RepoPath', $rp,
        '-ConfigFile', $Config, '-StateDir', $st, '-OperatorAlias', 'acquisition-operator',
        '-PullRequestId', '4242', '-Model', $Model, '-CycleTimeoutSeconds', '45',
        '-SecondPassModel', 'gpt-5.6-sol',
        '-ReplayRoot', $replayRoot, '-ReplaySnapshotName', 'synthetic-pr', '-ReplayManifestDigest', $digest,
        '-ExpectedReviewerBaseCommit', $expectedBase,
        '-AcquireTranscriptRole', 'generalist', '-AcquisitionPlanFile', $PlanFile,
        '-AcquisitionFixtureProjectionFile', $Projection, '-AcquisitionOutputRoot', $od
    )
    if ($EnableSpecialist) {
        $childArgs += @(
            '-EnableConventionSpecialist', '-ConventionSpecialistModel', $SpecialistModel,
            '-ConventionSpecialistTimeoutSeconds', '45')
    }
    if ($ForbiddenTelemetryOnly) {
        $childArgs += @('-OfflineTelemetryPath', $tp)
    }
    else {
        $childArgs += @(
            '-OfflineTelemetryPath', $tp,
            '-EnableOfflineModelAdapter', '-OfflineModelAdapterManifest', $man
        )
        if (-not $OmitTestOnlySwitch) { $childArgs += '-AcquisitionTestOnlyOfflineAdapter' }
    }
    $log = Join-Path $logDir ("direct-" + $Label + ".log")
    $prev = @{}
    foreach ($k in $Env.Keys) { $prev[$k] = [Environment]::GetEnvironmentVariable($k); Set-Item "Env:$k" $Env[$k] }
    try { & pwsh @childArgs *> $log } finally { foreach ($k in $Env.Keys) { if ($null -eq $prev[$k]) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue } else { Set-Item "Env:$k" $prev[$k] } } }
    $ec = $LASTEXITCODE
    $captured = Test-Path -LiteralPath (Join-Path $od 'capture-core.json')
    $logText = if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Raw } else { '' }
    $modelStarts = if (Test-Path -LiteralPath $tp) {
        @(Get-Content -LiteralPath $tp | Where-Object { $_ } |
            ForEach-Object { $_ | ConvertFrom-Json -Depth 16 } |
            Where-Object { [string]$_.event -ceq 'process.started' }).Count
    } else { 0 }
    return [pscustomobject]@{
        Exit = $ec; Captured = $captured; Log = [string]$logText
        ModelStarts = [int]$modelStarts
    }
}

# Recompute the outer supervisor's plan HMAC (key = SHA-256(token) bytes, HMAC-SHA256
# over the exact plan text, lowercase hex) so a test can author a re-signed plan whose
# every identity is authentically bound under a KNOWN token - the same construction the
# inner gate verifies. Used only to prove fail-closed refusals (non-git RepoPath, etc.).
function Get-TestPlanHmacHex {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$Token)
    $u = [System.Text.UTF8Encoding]::new($false, $true)
    $keyBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash($u.GetBytes($Token))
    $h = [System.Security.Cryptography.HMACSHA256]::new($keyBytes)
    try { return ([BitConverter]::ToString($h.ComputeHash($u.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $h.Dispose() }
}

# Author a re-signed plan variant: rewrite selected JSON string values (each supplied as
# an old->new raw pair, replaced in their exact JSON-encoded form) and emit a matching
# HMAC signature sidecar under $Token. Writes both with no-BOM UTF-8 so the bytes the
# inner gate reads are exactly the bytes signed.
function New-ResignedPlan {
    param(
        [Parameter(Mandatory)][string]$SrcPlan, [Parameter(Mandatory)][string]$DstPlan,
        [Parameter(Mandatory)][string]$Token, [hashtable[]]$Replace = @()
    )
    $u = [System.Text.UTF8Encoding]::new($false, $true)
    $text = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $SrcPlan).Path, $u)
    foreach ($r in $Replace) {
        $oldEnc = ($r.Old | ConvertTo-Json); $newEnc = ($r.New | ConvertTo-Json)
        if (-not $text.Contains($oldEnc)) { throw "plan text does not contain $oldEnc for re-sign replacement" }
        $text = $text.Replace($oldEnc, $newEnc)
    }
    [IO.File]::WriteAllText($DstPlan, $text, $u)
    $sig = [ordered]@{
        schemaVersion = 1
        kind          = 'reviewer-blinded-acquisition-plan-signature'
        algorithm     = 'HMACSHA256'
        signature     = (Get-TestPlanHmacHex -Text $text -Token $Token)
    }
    [IO.File]::WriteAllText("$DstPlan.sig", (($sig | ConvertTo-Json -Depth 8)), $u)
}


$forbiddenKeys = @('oracle', 'expected', 'expecteddecision', 'groundtruth', 'answerkey', 'adjudication',
    'golden', 'goldendecision', 'verdicttruth', 'correctness', 'deliveryeligibility', 'label', 'labels',
    'truth', 'decision', 'answer')
function Get-ForbiddenHits {
    param([AllowNull()]$Node, [string]$Path = '$')
    $hits = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Node) { return $hits.ToArray() }
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $Node.PSObject.Properties) {
            $lower = $p.Name.ToLowerInvariant()
            if ($forbiddenKeys -contains $lower -or $lower.Contains('oracle') -or $lower.Contains('groundtruth')) { [void]$hits.Add("$Path.$($p.Name)") }
            foreach ($h in (Get-ForbiddenHits -Node $p.Value -Path "$Path.$($p.Name)")) { [void]$hits.Add($h) }
        }
    }
    elseif ($Node -isnot [string] -and $Node -is [System.Collections.IEnumerable]) {
        $i = 0; foreach ($item in @($Node)) { foreach ($h in (Get-ForbiddenHits -Node $item -Path "$Path[$i]")) { [void]$hits.Add($h) }; $i++ }
    }
    return $hits.ToArray()
}

# ---------------------------------------------------------------------------
# Group A - Input gate refusals (fast, no child launch, exit != 0, never sealed)
# ---------------------------------------------------------------------------
Write-Host "`n== Group A: input gate refusals ==" -ForegroundColor Cyan

# oracle leakage: a projection carrying an expected-decision field is rejected by the
# recursive forbidden-key scan behind the strict schema.
$oracleProj = Join-Path $runRoot 'proj-oracle.json'
$pj = Get-Content $genProjection -Raw | ConvertFrom-Json -Depth 64
$pj | Add-Member -NotePropertyName expectedDecision -NotePropertyValue 'approve' -Force
($pj | ConvertTo-Json -Depth 64) | Set-Content -LiteralPath $oracleProj -Encoding UTF8

function Test-Gate {
    param([string]$Name, [string[]]$ToolArgs, [string]$Out, [string]$ExpectedError)
    $r = Invoke-Tool -ToolArgs $ToolArgs -LogName ("gate-" + $Name + ".log")
    $sealed = Test-Path -LiteralPath (Join-Path $Out 'package\transcript-package.json')
    Check ("gate/$Name refuses (exit!=0)") ($r.Exit -ne 0) ("exit=$($r.Exit)")
    Check ("gate/$Name leaves no sealed package") (-not $sealed)
    if ($ExpectedError) {
        $gateLog = Get-Content -LiteralPath $r.Log -Raw
        Check ("gate/$Name reports expected refusal") ($gateLog -like "*$ExpectedError*") $gateLog
    }
}

$oOut = New-OutDir 'gate_oracle'
Test-Gate 'oracleLeakage' (Get-CommonArgs -Out $oOut -Role generalist -Projection $oracleProj -Model claude-opus-5 -Manifest $baseManifest) $oOut

$wrOut = New-OutDir 'gate_wrongRole'
Test-Gate 'wrongRole' (Get-CommonArgs -Out $wrOut -Role generalist -Projection $verProjection -Model claude-opus-5 -Manifest $baseManifest) $wrOut

$umOut = New-OutDir 'gate_badModel'
Test-Gate 'unsupportedModel' (Get-CommonArgs -Out $umOut -Role generalist -Projection $genProjection -Model 'totally-not-a-model' -Manifest $baseManifest) $umOut

$missingSecondOut = New-OutDir 'gate_missingSecond'
Test-Gate 'missingSecondGeneralist' (Get-CommonArgs -Out $missingSecondOut -Role generalist `
        -Projection $genProjection -Model 'claude-opus-5' -Manifest $baseManifest `
        -OmitSecondGeneralistModel) $missingSecondOut 'requires -SecondGeneralistModel'

$equalSecondOut = New-OutDir 'gate_equalSecond'
Test-Gate 'equalSecondGeneralist' (Get-CommonArgs -Out $equalSecondOut -Role generalist `
        -Projection $genProjection -Model 'claude-opus-5' -Manifest $baseManifest `
        -SecondGeneralistModel 'claude-opus-5') $equalSecondOut 'requires two distinct'

$unsupportedSecondOut = New-OutDir 'gate_unsupportedSecond'
Test-Gate 'unsupportedSecondGeneralist' (Get-CommonArgs -Out $unsupportedSecondOut -Role generalist `
        -Projection $genProjection -Model 'claude-opus-5' -Manifest $baseManifest `
        -SecondGeneralistModel 'unsupported-generalist') $unsupportedSecondOut 'unsupported model id'

$nonCurrentSecondOut = New-OutDir 'gate_nonCurrentSecond'
Test-Gate 'nonCurrentSecondGeneralist' (Get-CommonArgs -Out $nonCurrentSecondOut -Role generalist `
        -Projection $genProjection -Model 'claude-opus-5' -Manifest $baseManifest `
        -SecondGeneralistModel 'gpt-5.6-terra') $nonCurrentSecondOut 'current configured generalist pairing'

$differentDiscoveryOut = New-OutDir 'gate_differentDiscovery'
Test-Gate 'differentDiscoveryGeneralist' ((Get-CommonArgs -Out $differentDiscoveryOut -Role generalist `
            -Projection $genProjection -Model 'claude-opus-5' -Manifest $baseManifest) +
        @('-DiscoveryGeneralistModel', 'gpt-5.6-sol')) $differentDiscoveryOut `
    'generalist acquisition is the discovery generalist'

$missingDiscoveryOut = New-OutDir 'gate_missingDiscovery'
$missingDiscoveryArgs = @(Get-SpecialistArgs -Out $missingDiscoveryOut -Manifest $baseManifest)
$missingDiscoveryArgs = @(for ($i = 0; $i -lt $missingDiscoveryArgs.Count; $i++) {
        if ([string]$missingDiscoveryArgs[$i] -ceq '-DiscoveryGeneralistModel') {
            $i++
            continue
        }
        $missingDiscoveryArgs[$i]
    })
Test-Gate 'missingDiscoveryGeneralist' $missingDiscoveryArgs $missingDiscoveryOut `
    'requires -DiscoveryGeneralistModel'

$emptyDiscoveryOut = New-OutDir 'gate_emptyDiscovery'
$emptyDiscoveryArgs = @(Get-SpecialistArgs -Out $emptyDiscoveryOut -Manifest $baseManifest)
$emptyDiscoveryIndex = [Array]::IndexOf(
    $emptyDiscoveryArgs, '-DiscoveryGeneralistModel')
$emptyDiscoveryArgs[$emptyDiscoveryIndex + 1] = ' '
Test-Gate 'emptyDiscoveryGeneralist' $emptyDiscoveryArgs $emptyDiscoveryOut `
    'requires -DiscoveryGeneralistModel'

$whOut = New-OutDir 'gate_wrongHead'
$whArgs = (Get-CommonArgs -Out $whOut -Role generalist -Projection $genProjection -Model claude-opus-5 -Manifest $baseManifest)
$whArgs = $whArgs | ForEach-Object { if ($_ -ceq $head) { '0000000000000000000000000000000000000000' } else { $_ } }
Test-Gate 'wrongHead' $whArgs $whOut

$wfOut = New-OutDir 'gate_wrongRef'
$wfArgs = @('-Role', 'generalist', '-FixtureProjectionFile', $genProjection, '-Model', 'claude-opus-5',
    '-SecondGeneralistModel', 'gpt-5.6-sol',
    '-ConfigFile', $configFile, '-ReplayRoot', $replayRoot, '-ReplaySnapshotName', 'synthetic-pr',
    '-ReplayManifestDigest', $digest,
    '-ExpectedReviewerBaseCommit', $expectedBase, '-PullRequestId', '4242', '-ExpectedHeadCommit', $head,
    '-ExpectedRef', 'refs/heads/definitely-not-a-real-branch', '-OutputRoot', $wfOut, '-SealKeyPath', $sealKey, '-AllowDirtyWorktree')
Test-Gate 'wrongRef' $wfArgs $wfOut 'Expected ref'

$nbOut = New-OutDir 'gate_nonAncestorBase'
$nbArgs = @('-Role', 'generalist', '-FixtureProjectionFile', $genProjection, '-Model', 'claude-opus-5',
    '-SecondGeneralistModel', 'gpt-5.6-sol',
    '-ConfigFile', $configFile, '-ReplayRoot', $replayRoot, '-ReplaySnapshotName', 'synthetic-pr',
    '-ReplayManifestDigest', $digest,
    '-ExpectedReviewerBaseCommit', '1111111111111111111111111111111111111111', '-PullRequestId', '4242',
    '-ExpectedHeadCommit', $head, '-ExpectedRef', $ref, '-OutputRoot', $nbOut, '-SealKeyPath', $sealKey, '-AllowDirtyWorktree')
Test-Gate 'nonAncestorBase' $nbArgs $nbOut

$smOut = New-OutDir 'gate_stubMissingManifest'
$smArgs = @('-Role', 'generalist', '-FixtureProjectionFile', $genProjection, '-Model', 'claude-opus-5',
    '-SecondGeneralistModel', 'gpt-5.6-sol',
    '-ConfigFile', $configFile, '-ReplayRoot', $replayRoot, '-ReplaySnapshotName', 'synthetic-pr',
    '-ReplayManifestDigest', $digest, '-ExpectedReviewerBaseCommit', $expectedBase, '-PullRequestId', '4242',
    '-ExpectedHeadCommit', $head, '-ExpectedRef', $ref, '-OutputRoot', $smOut, '-SealKeyPath', $sealKey,
    '-AllowDirtyWorktree', '-UseOfflineStubAdapter')
Test-Gate 'stubMissingManifest' $smArgs $smOut 'requires -OfflineModelAdapterManifest'

$tmOut = New-OutDir 'gate_manifestWithoutStub'
$tmArgs = @('-Role', 'generalist', '-FixtureProjectionFile', $genProjection, '-Model', 'claude-opus-5',
    '-SecondGeneralistModel', 'gpt-5.6-sol',
    '-ConfigFile', $configFile, '-ReplayRoot', $replayRoot, '-ReplaySnapshotName', 'synthetic-pr',
    '-ReplayManifestDigest', $digest, '-OfflineModelAdapterManifest', $baseManifest,
    '-ExpectedReviewerBaseCommit', $expectedBase, '-PullRequestId', '4242', '-ExpectedHeadCommit', $head,
    '-ExpectedRef', $ref, '-OutputRoot', $tmOut, '-SealKeyPath', $sealKey, '-AllowDirtyWorktree')
Test-Gate 'manifestWithoutStub' $tmArgs $tmOut 'test-only and requires -UseOfflineStubAdapter'

$vcOut = New-OutDir 'gate_verifierNoCand'
Test-Gate 'verifierBeforeDiscovery' (Get-CommonArgs -Out $vcOut -Role verifier -Projection $verProjection -Model claude-opus-5 -Manifest $baseManifest) $vcOut

$cnOut = New-OutDir 'gate_candNonVerifier'
Test-Gate 'candidateOnNonVerifier' ((Get-CommonArgs -Out $cnOut -Role generalist -Projection $genProjection -Model claude-opus-5 -Manifest $baseManifest) + @('-CandidateInputFile', $candidateFile)) $cnOut

$wtOut = New-OutDir 'gate_weakToken'
Test-Gate 'weakTokenTooShort' ((Get-CommonArgs -Out $wtOut -Role generalist -Projection $genProjection -Model claude-opus-5 -Manifest $baseManifest) + @('-AuthorizationToken', 'abc123')) $wtOut

$leOut = New-OutDir 'gate_lowEntropyToken'
Test-Gate 'lowEntropyToken' ((Get-CommonArgs -Out $leOut -Role generalist -Projection $genProjection -Model claude-opus-5 -Manifest $baseManifest) + @('-AuthorizationToken', ('a' * 40))) $leOut

# Capture the production child argv without starting the reviewer. This isolates
# the supervisor's exact Start-ReviewerAgent invocation from the offline adapter.
$argvCapture = Join-Path $runRoot 'generalist-child-argv.json'
$reviewerArgvStub = Join-Path $runRoot 'Start-ReviewerAgent-argv-stub.ps1'
$escapedArgvCapture = $argvCapture.Replace("'", "''")
@"
[IO.File]::WriteAllText('$escapedArgvCapture', (`$args | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new(`$false))
exit 91
"@ | Set-Content -LiteralPath $reviewerArgvStub -Encoding UTF8
$supervisorSource = [IO.File]::ReadAllText($tool, [Text.UTF8Encoding]::new($false, $true))
$reviewerAssignment = "`$ReviewerScript = Join-Path `$RepoRoot 'src\Agents\reviewer\Start-ReviewerAgent.ps1'"
Check 'production reviewer assignment has one replacement point' (
    ($supervisorSource.Split([string[]]@($reviewerAssignment),
            [StringSplitOptions]::None).Length - 1) -eq 1)
$argvSupervisor = Join-Path $runRoot 'Invoke-ReviewerBlindedAcquisition-argv-stub.ps1'
$stubAssignment = "`$ReviewerScript = '$($reviewerArgvStub.Replace("'", "''"))'"
[IO.File]::WriteAllText($argvSupervisor,
    $supervisorSource.Replace($reviewerAssignment, $stubAssignment),
    [Text.UTF8Encoding]::new($false))
$argvOut = New-OutDir 'generalist_child_argv'
& pwsh -NoProfile -File $argvSupervisor @(
    Get-CommonArgs -Out $argvOut -Role generalist -Projection $genProjection `
        -Model 'claude-opus-5' -Manifest $baseManifest) *> (Join-Path $logDir 'generalist-child-argv.log')
[object[]]$capturedChildArgv = @(if (Test-Path -LiteralPath $argvCapture) {
    @([IO.File]::ReadAllText($argvCapture, [Text.UTF8Encoding]::new($false, $true)) |
            ConvertFrom-Json)
} else { @() })
$primaryIndexes = @()
$secondIndexes = @()
if ($capturedChildArgv.Count -gt 0) {
    $primaryIndexes = @(0..($capturedChildArgv.Count - 1) | Where-Object {
            [string]$capturedChildArgv[$_] -ceq '-Model'
        })
    $secondIndexes = @(0..($capturedChildArgv.Count - 1) | Where-Object {
            [string]$capturedChildArgv[$_] -ceq '-SecondPassModel'
        })
}
Check 'generalist production child receives Opus primary exactly once' (
    $primaryIndexes.Count -eq 1 -and
    [string]$capturedChildArgv[$primaryIndexes[0] + 1] -ceq 'claude-opus-5') (
    $capturedChildArgv -join ' ')
Check 'generalist production child receives GPT second pass exactly once' (
    $secondIndexes.Count -eq 1 -and
    [string]$capturedChildArgv[$secondIndexes[0] + 1] -ceq 'gpt-5.6-sol') (
    $capturedChildArgv -join ' ')
Check 'generalist production child remains specialist-disabled for unchanged config' (
    @($capturedChildArgv | Where-Object {
            [string]$_ -cin @('-EnableConventionSpecialist', '-ConventionSpecialistModel')
        }).Count -eq 0) ($capturedChildArgv -join ' ')

$verificationArgvCapture = Join-Path $runRoot 'generalist-verification-child-argv.json'
$verificationArgvStub = Join-Path $runRoot 'Start-ReviewerAgent-verification-argv-stub.ps1'
$escapedVerificationArgvCapture = $verificationArgvCapture.Replace("'", "''")
@"
[IO.File]::WriteAllText('$escapedVerificationArgvCapture', (`$args | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new(`$false))
exit 91
"@ | Set-Content -LiteralPath $verificationArgvStub -Encoding UTF8
$verificationArgvSupervisor = Join-Path $runRoot 'Invoke-ReviewerBlindedAcquisition-verification-argv-stub.ps1'
$verificationStubAssignment = "`$ReviewerScript = '$($verificationArgvStub.Replace("'", "''"))'"
[IO.File]::WriteAllText($verificationArgvSupervisor,
    $supervisorSource.Replace($reviewerAssignment, $verificationStubAssignment),
    [Text.UTF8Encoding]::new($false))
$verificationArgvOut = New-OutDir 'generalist_verification_child_argv'
$verificationArgvLog = Join-Path $logDir 'generalist-verification-child-argv.log'
& pwsh -NoProfile -File $verificationArgvSupervisor @(
    Get-CommonArgs -Out $verificationArgvOut -Role generalist -Projection $genProjection `
        -Model 'claude-opus-5' -Manifest $baseManifest -Config $verificationConfigFile) *> $verificationArgvLog
[object[]]$verificationChildArgv = @(if (Test-Path -LiteralPath $verificationArgvCapture) {
    @([IO.File]::ReadAllText($verificationArgvCapture, [Text.UTF8Encoding]::new($false, $true)) |
            ConvertFrom-Json)
} else { @() })
$verificationEnableIndexes = @()
$verificationModelIndexes = @()
if ($verificationChildArgv.Count -gt 0) {
    $verificationEnableIndexes = @(0..($verificationChildArgv.Count - 1) |
        Where-Object { [string]$verificationChildArgv[$_] -ceq '-EnableConventionSpecialist' })
    $verificationModelIndexes = @(0..($verificationChildArgv.Count - 1) |
        Where-Object { [string]$verificationChildArgv[$_] -ceq '-ConventionSpecialistModel' })
}
Check 'verification-enabled generalist child receives specialist enable exactly once' (
    $verificationEnableIndexes.Count -eq 1) ($verificationChildArgv -join ' ')
Check 'verification-enabled generalist child receives configured specialist model exactly once' (
    $verificationModelIndexes.Count -eq 1 -and
    [string]$verificationChildArgv[$verificationModelIndexes[0] + 1] -ceq
        'claude-sonnet-5') ($verificationChildArgv -join ' ')
$verificationPrimaryIndex = [Array]::IndexOf($verificationChildArgv, '-Model')
$verificationSecondIndex = [Array]::IndexOf($verificationChildArgv, '-SecondPassModel')
Check 'verification-enabled generalist child still receives the exact Opus plus GPT pair' (
    @($verificationChildArgv | Where-Object { [string]$_ -ceq '-Model' }).Count -eq 1 -and
    @($verificationChildArgv | Where-Object { [string]$_ -ceq '-SecondPassModel' }).Count -eq 1 -and
    [string]$verificationChildArgv[$verificationPrimaryIndex + 1] -ceq 'claude-opus-5' -and
    [string]$verificationChildArgv[$verificationSecondIndex + 1] -ceq 'gpt-5.6-sol') (
    $verificationChildArgv -join ' ')

$overrideArgvCapture = Join-Path $runRoot 'generalist-override-child-argv.json'
$overrideArgvStub = Join-Path $runRoot 'Start-ReviewerAgent-override-argv-stub.ps1'
$escapedOverrideArgvCapture = $overrideArgvCapture.Replace("'", "''")
@"
[IO.File]::WriteAllText('$escapedOverrideArgvCapture', (`$args | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new(`$false))
exit 91
"@ | Set-Content -LiteralPath $overrideArgvStub -Encoding UTF8
$overrideArgvSupervisor = Join-Path $runRoot 'Invoke-ReviewerBlindedAcquisition-override-argv-stub.ps1'
$overrideStubAssignment = "`$ReviewerScript = '$($overrideArgvStub.Replace("'", "''"))'"
[IO.File]::WriteAllText($overrideArgvSupervisor,
    $supervisorSource.Replace($reviewerAssignment, $overrideStubAssignment),
    [Text.UTF8Encoding]::new($false))
$overrideArgvOut = New-OutDir 'generalist_override_child_argv'
& pwsh -NoProfile -File $overrideArgvSupervisor @(
    Get-CommonArgs -Out $overrideArgvOut -Role generalist -Projection $genProjection `
        -Model 'claude-opus-5' -Manifest $baseManifest -Config $verificationConfigFile `
        -SpecialistModel 'claude-haiku-4.5') *> (
    Join-Path $logDir 'generalist-override-child-argv.log')
[object[]]$overrideChildArgv = @(if (Test-Path -LiteralPath $overrideArgvCapture) {
    @([IO.File]::ReadAllText($overrideArgvCapture, [Text.UTF8Encoding]::new($false, $true)) |
            ConvertFrom-Json)
} else { @() })
$overrideModelIndexes = @()
if ($overrideChildArgv.Count -gt 0) {
    $overrideModelIndexes = @(0..($overrideChildArgv.Count - 1) | Where-Object {
            [string]$overrideChildArgv[$_] -ceq '-ConventionSpecialistModel'
        })
}
Check 'explicit generalist specialist override takes precedence exactly once' (
    $overrideModelIndexes.Count -eq 1 -and
    [string]$overrideChildArgv[$overrideModelIndexes[0] + 1] -ceq
        'claude-haiku-4.5') ($overrideChildArgv -join ' ')

$unsupportedSpecialistOut = New-OutDir 'gate_unsupported_generalist_specialist'
Test-Gate 'unsupportedGeneralistSpecialist' (Get-CommonArgs -Out $unsupportedSpecialistOut `
        -Role generalist -Projection $genProjection -Model 'claude-opus-5' -Manifest $baseManifest `
        -Config $verificationConfigFile -SpecialistModel 'unsupported-specialist') `
    $unsupportedSpecialistOut 'unsupported model id'
Check 'unsupported generalist specialist is rejected before reviewer launch' (
    -not (Test-Path -LiteralPath (
            Join-Path $unsupportedSpecialistOut 'work\reviewer-stdout.log')))

$forwardingFragment = "'-Model', `$childPrimaryModel, '-SecondPassModel', `$SecondGeneralistModel,"
Check 'second-pass forwarding has one sabotage point' (
    ($supervisorSource.Split([string[]]@($forwardingFragment),
            [StringSplitOptions]::None).Length - 1) -eq 1)
$omittedSecondSupervisor = Join-Path $runRoot 'Invoke-ReviewerBlindedAcquisition-second-omitted.ps1'
[IO.File]::WriteAllText($omittedSecondSupervisor,
    $supervisorSource.Replace($forwardingFragment, "'-Model', `$childPrimaryModel,"),
    [Text.UTF8Encoding]::new($false))
$omittedForwardOut = New-OutDir 'generalist_second_omitted'
& pwsh -NoProfile -File $omittedSecondSupervisor @(
    Get-CommonArgs -Out $omittedForwardOut -Role generalist -Projection $genProjection `
        -Model 'claude-opus-5' -Manifest $baseManifest) *> (Join-Path $logDir 'generalist-second-omitted.log')
$omittedForwardExit = $LASTEXITCODE
$omittedForwardLog = Get-Content (Join-Path $logDir 'generalist-second-omitted.log') -Raw
$omittedChildStderr = Join-Path $omittedForwardOut 'work\reviewer-stderr.log'
if (Test-Path -LiteralPath $omittedChildStderr) {
    $omittedForwardLog += "`n" + (Get-Content -LiteralPath $omittedChildStderr -Raw)
}
Check 'omitting second-pass forwarding reproduces the child pre-boundary refusal' (
    $omittedForwardExit -ne 0 -and
    $omittedForwardLog -match 'SecondPassModel|secondGeneralistModel' -and
    -not (Test-Path -LiteralPath (Join-Path $omittedForwardOut 'package\transcript-package.json'))) `
    $omittedForwardLog

$generalistSpecialistCondition = "if (`$Role -eq 'generalist' -and `$conventionSpecialistEnabled)"
Check 'generalist specialist forwarding has one omission-sabotage point' (
    ($supervisorSource.Split([string[]]@($generalistSpecialistCondition),
            [StringSplitOptions]::None).Length - 1) -eq 1)
$omittedSpecialistSupervisor = Join-Path $runRoot 'Invoke-ReviewerBlindedAcquisition-specialist-omitted.ps1'
[IO.File]::WriteAllText($omittedSpecialistSupervisor,
    $supervisorSource.Replace($generalistSpecialistCondition,
        "if (`$Role -eq 'generalist' -and `$false)"),
    [Text.UTF8Encoding]::new($false))
$omittedSpecialistOut = New-OutDir 'generalist_specialist_omitted'
$omittedSpecialistLogPath = Join-Path $logDir 'generalist-specialist-omitted.log'
& pwsh -NoProfile -File $omittedSpecialistSupervisor @(
    Get-CommonArgs -Out $omittedSpecialistOut -Role generalist -Projection $genProjection `
        -Model 'claude-opus-5' -Manifest $baseManifest -Config $verificationConfigFile) *> $omittedSpecialistLogPath
$omittedSpecialistExit = $LASTEXITCODE
$omittedSpecialistLog = Get-Content $omittedSpecialistLogPath -Raw
$omittedSpecialistChildStderr = Join-Path $omittedSpecialistOut 'work\reviewer-stderr.log'
if (Test-Path -LiteralPath $omittedSpecialistChildStderr) {
    $omittedSpecialistLog += "`n" + (Get-Content -LiteralPath $omittedSpecialistChildStderr -Raw)
}
Check 'omitting generalist specialist forwarding reproduces verification refusal' (
    $omittedSpecialistExit -ne 0 -and
    $omittedSpecialistLog -match
        'Verification preview requires -EnableConventionSpecialist' -and
    -not (Test-Path -LiteralPath (
            Join-Path $omittedSpecialistOut 'package\transcript-package.json'))) `
    $omittedSpecialistLog

# ---------------------------------------------------------------------------
# Group B - Snapshot digest mismatch is refused inside the sealed child
# ---------------------------------------------------------------------------
Write-Host "`n== Group B: wrong snapshot digest (child replay refusal) ==" -ForegroundColor Cyan
$sdOut = New-OutDir 'child_wrongSnapshot'
$wrongDigest = ('0' * 63) + '1'
$sdMan = New-VariantManifest -Tag 'wrongSnapshot' -Behavior 'success'
$sd = Invoke-Tool -ToolArgs (Get-CommonArgs -Out $sdOut -Role generalist -Projection $genProjection -Model claude-opus-5 -Manifest $sdMan -SnapshotDigest $wrongDigest) -LogName 'child-wrongSnapshot.log'
Check 'snapshotDigestMismatch refuses (exit!=0)' ($sd.Exit -ne 0) ("exit=$($sd.Exit)")
Check 'snapshotDigestMismatch leaves no sealed package' (-not (Test-Path -LiteralPath (Join-Path $sdOut 'package\transcript-package.json')))

# Production telemetry and credential-boundary regression: put a harmless
# pwsh-backed executable at the agency boundary. It records only credential
# variable NAMES/booleans to a test-owned file, never values, then exits before a
# model or tool can run. This proves the exact Copilot subprocess receives GitHub
# authentication variables (whose precedence remains owned by Copilot CLI) but
# no ADO/write credential.
$prodOut = New-OutDir 'production_telemetry_wiring'
$fakeAgencyDir = Join-Path $runRoot 'fake-agency'
New-Item -ItemType Directory -Force -Path $fakeAgencyDir | Out-Null
$fakeAgencyScript = Join-Path $fakeAgencyDir 'fake-agency.ps1'
$fakeAgencyPath = Join-Path $fakeAgencyDir 'agency.cmd'
@'
$ErrorActionPreference = 'Stop'
$githubNames = @('COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')
$adoNames = @('AZURE_DEVOPS_EXT_PAT', 'SYSTEM_ACCESSTOKEN')
$presentGithub = @($githubNames | Where-Object {
        -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($_))
    })
$presentAdo = @($adoNames | Where-Object {
        -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($_))
    })
$selected = if ($presentGithub.Count -gt 0) { [string]$presentGithub[0] } else { '' }
$reportPath = Join-Path $PSScriptRoot 'credential-probe.json'
[pscustomobject][ordered]@{
    githubAuthPresent = [bool]$selected
    githubAuthVariable = $selected
    githubVariablesPresent = $presentGithub
    adoCredentialsPresent = ($presentAdo.Count -gt 0)
} | ConvertTo-Json -Compress | Set-Content -LiteralPath $reportPath -Encoding utf8
$null = [Console]::In.ReadToEnd()
if (-not $selected) {
    [Console]::Error.WriteLine('error: No authentication information found for this host.')
}
else {
    [Console]::Error.WriteLine('credential boundary probe stopped before model launch')
}
exit 70
'@ | Set-Content -LiteralPath $fakeAgencyScript -Encoding utf8
Set-Content -LiteralPath $fakeAgencyPath -Encoding ascii -Value `
    '@pwsh -NoProfile -File "%~dp0fake-agency.ps1" %*'
$sentinelTelemetry = Join-Path $runRoot 'parent-telemetry-must-not-be-used.jsonl'
$credentialVariableNames = @(
    'AZURE_DEVOPS_EXT_PAT', 'SYSTEM_ACCESSTOKEN',
    'COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN'
)
function Invoke-ProductionCredentialProbe {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Out,
        [string[]]$GitHubNames = @(),
        [switch]$AssertTelemetryIsolation
    )
    $trackedNames = @($credentialVariableNames) + @(
        'PATH', 'DEVPILOT_OFFLINE_TELEMETRY_MODE',
        'DEVPILOT_OFFLINE_TELEMETRY_PATH'
    )
    $saved = @{}
    foreach ($nameToSave in $trackedNames) {
        $saved[$nameToSave] = [Environment]::GetEnvironmentVariable($nameToSave)
    }
    $sentinels = [System.Collections.Generic.List[string]]::new()
    $probePath = Join-Path $fakeAgencyDir 'credential-probe.json'
    try {
        Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue
        foreach ($credentialName in $credentialVariableNames) {
            Remove-Item "Env:$credentialName" -ErrorAction SilentlyContinue
        }
        foreach ($adoName in @('AZURE_DEVOPS_EXT_PAT', 'SYSTEM_ACCESSTOKEN')) {
            $value = "$adoName-ACQ-$([Guid]::NewGuid().ToString('N'))"
            Set-Item "Env:$adoName" $value
            [void]$sentinels.Add($value)
        }
        foreach ($githubName in $GitHubNames) {
            $value = "$githubName-ACQ-$([Guid]::NewGuid().ToString('N'))"
            Set-Item "Env:$githubName" $value
            [void]$sentinels.Add($value)
        }
        $env:PATH = $fakeAgencyDir + [IO.Path]::PathSeparator + [string]$saved['PATH']
        if ($AssertTelemetryIsolation) {
            $env:DEVPILOT_OFFLINE_TELEMETRY_MODE = 'parent-sentinel'
            $env:DEVPILOT_OFFLINE_TELEMETRY_PATH = $sentinelTelemetry
        }
        $run = Invoke-Tool -ToolArgs (Get-ProductionArgs -Out $Out) -LogName "production-$Name.log"
    }
    finally {
        foreach ($nameToRestore in $trackedNames) {
            if ($null -eq $saved[$nameToRestore]) {
                Remove-Item "Env:$nameToRestore" -ErrorAction SilentlyContinue
            }
            else { Set-Item "Env:$nameToRestore" $saved[$nameToRestore] }
        }
    }
    $parentUnchanged = @($trackedNames | Where-Object {
            [Environment]::GetEnvironmentVariable($_) -cne $saved[$_]
        }).Count -eq 0
    return [pscustomobject]@{
        Run = $run
        Probe = if (Test-Path -LiteralPath $probePath) { Read-Json $probePath } else { $null }
        ProbePath = $probePath
        Sentinels = @($sentinels)
        ParentUnchanged = $parentUnchanged
    }
}

$prodProbe = Invoke-ProductionCredentialProbe -Name 'all-auth' -Out $prodOut `
    -GitHubNames @('COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN') -AssertTelemetryIsolation
$prod = $prodProbe.Run
if ($prod.Exit -ne 0) {
    throw "Production acquisition did not reach the stub model boundary without adapter parameters (exit=$($prod.Exit))."
}
Check 'Copilot boundary retains GitHub authentication' `
    ($null -ne $prodProbe.Probe -and [bool]$prodProbe.Probe.githubAuthPresent)
Check 'Copilot boundary preserves all GitHub auth names for CLI-owned precedence' `
    ((@($prodProbe.Probe.githubVariablesPresent) -join ',') -ceq
        'COPILOT_GITHUB_TOKEN,GH_TOKEN,GITHUB_TOKEN')
Check 'Copilot boundary receives no ADO/write-provider credential' `
    (-not [bool]$prodProbe.Probe.adoCredentialsPresent)
Check 'production probe leaves parent environment unchanged' $prodProbe.ParentUnchanged

$ghProbeOut = New-OutDir 'production_auth_gh'
$ghProbe = Invoke-ProductionCredentialProbe -Name 'gh-auth' -Out $ghProbeOut `
    -GitHubNames @('GH_TOKEN')
Check 'GH_TOKEN independently reaches the Copilot boundary' `
    ([string]$ghProbe.Probe.githubAuthVariable -ceq 'GH_TOKEN') `
    ("observed=$([string]$ghProbe.Probe.githubAuthVariable)")
Check 'GH_TOKEN probe leaves parent environment unchanged' $ghProbe.ParentUnchanged

$githubProbeOut = New-OutDir 'production_auth_github'
$githubProbe = Invoke-ProductionCredentialProbe -Name 'github-auth' -Out $githubProbeOut `
    -GitHubNames @('GITHUB_TOKEN')
Check 'GITHUB_TOKEN independently reaches the Copilot boundary' `
    ([string]$githubProbe.Probe.githubAuthVariable -ceq 'GITHUB_TOKEN') `
    ("observed=$([string]$githubProbe.Probe.githubAuthVariable)")
Check 'GITHUB_TOKEN probe leaves parent environment unchanged' $githubProbe.ParentUnchanged

$missingAuthOut = New-OutDir 'production_auth_missing'
$missingAuthProbe = Invoke-ProductionCredentialProbe -Name 'missing-auth' -Out $missingAuthOut
Check 'missing GitHub auth reaches boundary as absent' `
    ($null -ne $missingAuthProbe.Probe -and -not [bool]$missingAuthProbe.Probe.githubAuthPresent -and
        [string]::IsNullOrEmpty([string]$missingAuthProbe.Probe.githubAuthVariable))
Check 'missing-auth probe leaves parent environment unchanged' $missingAuthProbe.ParentUnchanged
$missingAuthManifest = Read-Json (Join-Path $missingAuthOut 'package\transcript-package.json')
$missingAuthAttempt = @($missingAuthManifest.attempts)[-1]
Check 'missing GitHub auth is a typed environment failure' `
    ([string]$missingAuthAttempt.markerStatus -ceq 'environment') `
    ("status=$([string]$missingAuthAttempt.markerStatus)")
Check 'missing GitHub auth reports authentication failure' `
    ([string]$missingAuthAttempt.reason -match 'could not authenticate to GitHub') `
    ("reason=$([string]$missingAuthAttempt.reason)")

$allCredentialSentinels = @(
    @($prodProbe.Sentinels) + @($ghProbe.Sentinels) +
    @($githubProbe.Sentinels) + @($missingAuthProbe.Sentinels)
)
$credentialBoundaryFiles = @(Get-ChildItem -LiteralPath $runRoot -Recurse -File)
$credentialLeakFiles = @($credentialBoundaryFiles | Where-Object {
        $text = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue
        @($allCredentialSentinels | Where-Object {
                $text -match [regex]::Escape($_)
            }).Count -gt 0
    })
Check 'no unique credential sentinel in package/stdout/stderr/telemetry/probe files' `
    ($credentialLeakFiles.Count -eq 0) ("leakedFiles=$($credentialLeakFiles.Count)")

$prodTelemetryPath = Join-Path $prodOut 'work\telemetry.jsonl'
$prodEvents = if (Test-Path -LiteralPath $prodTelemetryPath) {
    @(Get-Content -LiteralPath $prodTelemetryPath -Encoding UTF8 | Where-Object { $_ } |
        ForEach-Object { $_ | ConvertFrom-Json -Depth 32 })
} else { @() }
$prodStarts = @($prodEvents | Where-Object { [string]$_.event -ceq 'process.started' })
$prodReady = @($prodEvents | Where-Object { [string]$_.event -ceq 'acquisition.childReady' })
if ($prodReady.Count -ne 1 -or
    [bool]$prodReady[0].data.offlineTelemetryArgumentPresent -or
    [bool]$prodReady[0].data.offlineAdapterArgumentPresent) {
    throw "Production child argv requested offline adapter telemetry (ready events=$($prodReady.Count))."
}
if ($prodReady.Count -ne 1 -or
    [string]$prodReady[0].data.telemetryMode -cne 'production-test-only' -or
    [IO.Path]::GetFullPath([string]$prodReady[0].data.telemetryPath) -cne [IO.Path]::GetFullPath($prodTelemetryPath) -or
    (Test-Path -LiteralPath $sentinelTelemetry)) {
    throw 'Production child did not receive the exact owned telemetry mode/path.'
}
$outerSource = Get-Content -LiteralPath $tool -Raw
if ($outerSource -match '\$env:DEVPILOT_OFFLINE_TELEMETRY_(MODE|PATH)\s*=') {
    throw 'The acquisition supervisor mutates the global telemetry environment.'
}
$prodManifestPath = Join-Path $prodOut 'package\transcript-package.json'
if (Test-Path -LiteralPath $prodManifestPath) {
    $prodManifest = Read-Json $prodManifestPath
    $prodTelemetryFile = @($prodManifest.files | Where-Object { [string]$_.name -ceq 'telemetry.jsonl' })
    if ($prodStarts.Count -lt 1 -or [int]$prodManifest.telemetry.realModelStarts -lt 1) {
        throw "Production telemetry missed the stubbed real-model boundary (starts=$($prodStarts.Count), real=$([int]$prodManifest.telemetry.realModelStarts))."
    }
    if (-not [bool]$prodManifest.telemetry.fileExists -or [int]$prodManifest.telemetry.totalEvents -le 0 -or
        $prodTelemetryFile.Count -ne 1 -or
        [int64]$prodTelemetryFile[0].bytes -ne [int64]$prodManifest.telemetry.sinkBytes -or
        [string]$prodTelemetryFile[0].sha256 -cne [string]$prodManifest.telemetry.sinkSha256) {
        throw 'Production package telemetry did not bind the owned sink hash, length, and events.'
    }
}
else { throw "Production telemetry package is missing: $prodManifestPath" }

# Blocker 2: a blinded projection whose canonical binding disagrees with the sealed
# replay Bound (here a DIFFERENT sourceCommit) is refused by the outer supervisor
# BEFORE any lease / plan / launch. Caller-supplied projection identity can never
# override the authoritative sealed-snapshot target.
$xcJson = Get-Content $genProjection -Raw | ConvertFrom-Json -Depth 64
$xcJson.binding.sourceCommit = 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
$xcProjection = Join-Path $runRoot 'projection-crosscommit.json'
($xcJson | ConvertTo-Json -Depth 64) | Set-Content -LiteralPath $xcProjection -Encoding UTF8
$xcOut = New-OutDir 'crosscommit'
$xcMan = New-VariantManifest -Tag 'crossCommit' -Behavior 'success'
$xc = Invoke-Tool -ToolArgs (Get-CommonArgs -Out $xcOut -Role generalist -Projection $xcProjection -Model claude-opus-5 -Manifest $xcMan) -LogName 'crosscommit.log'
Check 'projection sourceCommit != sealed replay Bound is refused (blocker 2)' (($xc.Exit -ne 0) -and -not (Test-Path -LiteralPath (Join-Path $xcOut 'package\transcript-package.json'))) ("exit=$($xc.Exit)")

# Blocker 2: targetCommit and changeSetDigest are now REQUIRED on every projection
# binding and compared UNCONDITIONALLY. A non-verifier (generalist) projection whose
# targetCommit disagrees with the sealed replay Bound target is refused before launch,
# proving the compare is not verifier-only and not gated on an optional field.
$xtJson = Get-Content $genProjection -Raw | ConvertFrom-Json -Depth 64
$xtJson.binding.targetCommit = 'f0e1d2c3b4a5f6e7d8c9b0a1f2e3d4c5b6a70000'
$xtProjection = Join-Path $runRoot 'projection-crosstarget.json'
($xtJson | ConvertTo-Json -Depth 64) | Set-Content -LiteralPath $xtProjection -Encoding UTF8
$xtOut = New-OutDir 'crosstarget'
$xtMan = New-VariantManifest -Tag 'crossTarget' -Behavior 'success'
$xt = Invoke-Tool -ToolArgs (Get-CommonArgs -Out $xtOut -Role generalist -Projection $xtProjection -Model claude-opus-5 -Manifest $xtMan) -LogName 'crosstarget.log'
Check 'projection targetCommit != sealed replay Bound is refused for a non-verifier (blocker 2)' (($xt.Exit -ne 0) -and -not (Test-Path -LiteralPath (Join-Path $xtOut 'package\transcript-package.json'))) ("exit=$($xt.Exit)")

# Blocker 2: a projection missing the now-required targetCommit/changeSetDigest binding
# fields is refused by the versioned fixture-projection schema itself.
$xmJson = Get-Content $genProjection -Raw | ConvertFrom-Json -Depth 64
$xmJson.binding.PSObject.Properties.Remove('changeSetDigest')
$xmProjection = Join-Path $runRoot 'projection-missingtarget.json'
($xmJson | ConvertTo-Json -Depth 64) | Set-Content -LiteralPath $xmProjection -Encoding UTF8
$xmOut = New-OutDir 'missingtarget'
$xmMan = New-VariantManifest -Tag 'missingTarget' -Behavior 'success'
$xm = Invoke-Tool -ToolArgs (Get-CommonArgs -Out $xmOut -Role generalist -Projection $xmProjection -Model claude-opus-5 -Manifest $xmMan) -LogName 'missingtarget.log'
Check 'projection missing required changeSetDigest binding is schema-refused (blocker 2)' (($xm.Exit -ne 0) -and -not (Test-Path -LiteralPath (Join-Path $xmOut 'package\transcript-package.json'))) ("exit=$($xm.Exit)")

# ---------------------------------------------------------------------------
# Group C - Stub-driven inner behaviors through the exact production path
# ---------------------------------------------------------------------------
Write-Host "`n== Group C: exact-path stub behaviors ==" -ForegroundColor Cyan

function Test-Behavior {
    param(
        [string]$Name, [string]$Behavior, [string]$Model, [hashtable]$RoleExtra,
        [int]$ExpectExit, [string]$ExpectStatus, [int]$ExpectAttempts,
        [string]$ExpectReported, [switch]$DistinctNonces, [int]$PerCall = 30, [int]$Total = 90, [int]$Activity = 30
    )
    $out = New-OutDir ("beh_" + $Name)
    $man = New-VariantManifest -Tag $Name -Behavior $Behavior -RoleExtra $RoleExtra
    $r = Invoke-Tool -ToolArgs (Get-CommonArgs -Out $out -Role generalist -Projection $genProjection -Model $Model -Manifest $man -PerCall $PerCall -Total $Total -Activity $Activity) -LogName ("beh-" + $Name + ".log")
    Check ("$Name exit=$ExpectExit") ($r.Exit -eq $ExpectExit) ("got=$($r.Exit)")
    $mp = Join-Path $out 'package\transcript-package.json'
    if (-not (Test-Path -LiteralPath $mp)) { Check "$Name sealed manifest present" $false 'missing'; return }
    $m = Read-Json $mp
    Check ("$Name status=$ExpectStatus") ([string]$m.terminalStatus -eq $ExpectStatus) ("got=$([string]$m.terminalStatus)")
    Check ("$Name attempts=$ExpectAttempts") (@($m.attempts).Count -eq $ExpectAttempts) ("got=$(@($m.attempts).Count)")
    Check ("$Name reportedModel='$ExpectReported'") ([string]$m.reportedModel -eq $ExpectReported) ("got='$([string]$m.reportedModel)'")
    $expectedSecond = if ($Model -ceq 'gpt-5.6-sol') { 'claude-opus-5' } else { 'gpt-5.6-sol' }
    Check ("$Name bundle binds second generalist") (
        [string]$m.secondGeneralistModel -ceq $expectedSecond) (
        "got='$([string]$m.secondGeneralistModel)'")
    Check ("$Name zero real-model starts") ([int]$m.telemetry.realModelStarts -eq 0 -and [int]$m.telemetry.modelSubprocessStarts -ge 1) ("real=$([int]$m.telemetry.realModelStarts) sub=$([int]$m.telemetry.modelSubprocessStarts)")
    $telemetryFile = @($m.files | Where-Object { [string]$_.name -ceq 'telemetry.jsonl' })
    Check ("$Name zeroWriteVerified and telemetry sink bound") `
        ([bool]$m.telemetry.zeroWriteVerified -and
        [bool]$m.telemetry.fileExists -and [int]$m.telemetry.totalEvents -gt 0 -and
        $telemetryFile.Count -eq 1 -and
        [int64]$telemetryFile[0].bytes -eq [int64]$m.telemetry.sinkBytes -and
        [string]$telemetryFile[0].sha256 -ceq [string]$m.telemetry.sinkSha256) ''
    # Blocker 3: the stub adapter emits a result envelope (usage) and an
    # assistant.message whenever the model "ran" -> reportedModel is non-empty.
    # In that case the exact production parser MUST surface real usage (modelRan
    # true, usage.reported true, unavailable false) rather than the old bug where
    # usage always came back unavailable. crash/saturation emit no envelope, so
    # usage stays unavailable and modelRan false.
    $modelRan = ($ExpectReported -ne '')
    Check ("$Name usage.reported matches modelRan ($modelRan)") ((-not [bool]$m.usage.unavailable) -eq $modelRan) ("unavailable=$([bool]$m.usage.unavailable) reported=$([bool]$m.usage.reported)")
    if ($modelRan) {
        Check ("$Name usage carries real parser fields") ([bool]$m.usage.reported -and ($null -ne $m.usage.premiumRequests) -and ($null -ne $m.usage.totalApiDurationMs) -and ($null -ne $m.usage.sessionDurationMs)) ("pr=$($m.usage.premiumRequests) api=$($m.usage.totalApiDurationMs) sess=$($m.usage.sessionDurationMs)")
        $ta = @($m.attempts)[-1]
        Check ("$Name terminal attempt modelRan=true") ([bool]$ta.modelRan) ("modelRan=$([bool]$ta.modelRan)")
        Check ("$Name terminal attempt usage reported") ([bool]$ta.usage.reported -and -not [bool]$ta.usage.unavailable) ("rep=$([bool]$ta.usage.reported) unavail=$([bool]$ta.usage.unavailable)")
    }
    else {
        Check ("$Name usage unavailable") ([bool]$m.usage.unavailable) ''
    }
    if ($DistinctNonces) {
        $ns = @(@($m.attempts) | ForEach-Object { [string]$_.nonce })
        Check ("$Name retry uses a fresh distinct nonce") ($ns.Count -ge 2 -and $ns[0] -cne $ns[1]) ("$($ns -join ',')")
        Check ("$Name first attempt retryable") ([bool]@($m.attempts)[0].retryable) ''
    }
}

Test-Behavior -Name 'successOpus' -Behavior 'success' -Model 'claude-opus-5' -ExpectExit 0 -ExpectStatus 'captured' -ExpectAttempts 1 -ExpectReported 'claude-opus-5'
Test-Behavior -Name 'successGpt' -Behavior 'success' -Model 'gpt-5.6-sol' -ExpectExit 0 -ExpectStatus 'captured' -ExpectAttempts 1 -ExpectReported 'gpt-5.6-sol'
Test-Behavior -Name 'missingMarker' -Behavior 'missingMarker' -Model 'claude-opus-5' -ExpectExit 0 -ExpectStatus 'captureFailedRetriesExhausted' -ExpectAttempts 2 -ExpectReported 'claude-opus-5' -DistinctNonces
Test-Behavior -Name 'truncatedMarker' -Behavior 'truncatedMarker' -Model 'claude-opus-5' -ExpectExit 0 -ExpectStatus 'captureFailedRetriesExhausted' -ExpectAttempts 2 -ExpectReported 'claude-opus-5' -DistinctNonces
Test-Behavior -Name 'stdoutSaturation' -Behavior 'stdoutSaturation' -Model 'claude-opus-5' -RoleExtra @{ byteCount = 100000 } -ExpectExit 0 -ExpectStatus 'captureFailedRetriesExhausted' -ExpectAttempts 2 -ExpectReported '' -DistinctNonces
Test-Behavior -Name 'wrongBinding' -Behavior 'wrongBinding' -Model 'claude-opus-5' -ExpectExit 0 -ExpectStatus 'captureFailedTerminal' -ExpectAttempts 1 -ExpectReported 'claude-opus-5'
Test-Behavior -Name 'crash' -Behavior 'crash' -Model 'claude-opus-5' -RoleExtra @{ exitCode = 70 } -ExpectExit 0 -ExpectStatus 'crash' -ExpectAttempts 1 -ExpectReported ''

$verificationEnabledOut = New-OutDir 'beh_verificationEnabledGeneralist'
$verificationEnabledManifest = New-VariantManifest -Tag 'verificationEnabledGeneralist' `
    -Behavior 'success'
$verificationEnabledRun = Invoke-Tool -ToolArgs (
    Get-CommonArgs -Out $verificationEnabledOut -Role generalist -Projection $genProjection `
        -Model 'claude-opus-5' -Manifest $verificationEnabledManifest `
        -Config $verificationConfigFile) -LogName 'beh-verification-enabled-generalist.log'
Check 'verification-enabled generalist acquisition succeeds' (
    $verificationEnabledRun.Exit -eq 0) "exit=$($verificationEnabledRun.Exit)"
$verificationEnabledPackagePath = Join-Path $verificationEnabledOut 'package\transcript-package.json'
if (Test-Path -LiteralPath $verificationEnabledPackagePath) {
    $verificationEnabledPackage = Read-Json $verificationEnabledPackagePath
    Check 'verification-enabled package remains generalist and binds specialist configuration' (
        [string]$verificationEnabledPackage.role -ceq 'generalist' -and
        [bool]$verificationEnabledPackage.conventionSpecialistEnabled -and
        [string]$verificationEnabledPackage.conventionSpecialistModel -ceq 'claude-sonnet-5')
    Check 'verification-enabled generalist starts exactly one model subprocess' (
        [int]$verificationEnabledPackage.telemetry.modelSubprocessStarts -eq 1 -and
        [int]$verificationEnabledPackage.telemetry.realModelStarts -eq 0) (
        "subprocesses=$([int]$verificationEnabledPackage.telemetry.modelSubprocessStarts)")
    $verificationTelemetry = @(Get-Content (
            Join-Path $verificationEnabledOut 'package\telemetry.jsonl') |
        Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json -Depth 32 })
    $verificationStarts = @($verificationTelemetry | Where-Object {
            [string]$_.event -ceq 'process.started'
        })
    Check 'verification-enabled boundary has one generalist and zero specialist starts' (
        $verificationStarts.Count -eq 1 -and
        (([string]$verificationStarts[0].data.arguments) -match 'blind-opus') -and
        (([string]$verificationStarts[0].data.arguments) -notmatch 'specialist')) (
        $verificationStarts | ConvertTo-Json -Depth 16 -Compress)
    $packageSchema = Join-Path $RepoRoot `
        'src\Agents\reviewer\acquisition\v1\transcript-package.schema.json'
    foreach ($invalidSpecialistBinding in @(
            @{ Enabled = $true; Model = $null; Name = 'enabled/null' },
            @{ Enabled = $false; Model = 'claude-sonnet-5'; Name = 'disabled/model' })) {
        $invalidPackage = $verificationEnabledPackage | ConvertTo-Json -Depth 64 |
            ConvertFrom-Json -AsHashtable -Depth 64
        $invalidPackage.conventionSpecialistEnabled = $invalidSpecialistBinding.Enabled
        $invalidPackage.conventionSpecialistModel = $invalidSpecialistBinding.Model
        $invalidPackageValid = ConvertTo-Json $invalidPackage -Depth 64 |
            Test-Json -SchemaFile $packageSchema -ErrorAction SilentlyContinue
        Check "package schema rejects $($invalidSpecialistBinding.Name) specialist binding" (
            -not $invalidPackageValid)
    }
}
else {
    Check 'verification-enabled package is present' $false $verificationEnabledRun.Log
}

$successOpusPlan = Read-Json (Join-Path (New-OutDir 'beh_successOpus') 'work\acquisition-plan.json')
Check 'authored generalist plan hash-binds the second model' (
    [string]$successOpusPlan.model -ceq 'claude-opus-5' -and
    [string]$successOpusPlan.secondGeneralistModel -ceq 'gpt-5.6-sol')
$verificationEnabledPlan = Read-Json (
    Join-Path $verificationEnabledOut 'work\acquisition-plan.json')
Check 'verification-enabled plan hash-binds specialist enable and model' (
    [bool]$verificationEnabledPlan.conventionSpecialistEnabled -and
    [string]$verificationEnabledPlan.conventionSpecialistModel -ceq 'claude-sonnet-5')

# Blocker 3: the generalist attempt ledger also preserves the exact production
# parser status/reason (never a coarse remap). A retryable emission slip keeps its
# typed class; a wrong binding is the typed terminal 'wrongBinding'.
$genMiss = Read-Json (Join-Path (New-OutDir 'beh_missingMarker') 'package\transcript-package.json')
Assert-ExactAttempt -Attempt (@($genMiss.attempts)[0]) -Label 'generalist missingMarker' -ExpectStatus 'missingMarker' -ExpectRetryable $true
$genWrong = Read-Json (Join-Path (New-OutDir 'beh_wrongBinding') 'package\transcript-package.json')
Assert-ExactAttempt -Attempt (@($genWrong.attempts)[-1]) -Label 'generalist wrongBinding' -ExpectStatus 'wrongBinding' -ExpectRetryable $false

# ---------------------------------------------------------------------------
# Group D - Hanging grandchild -> per/total deadline -> exit 124 + tree kill
# ---------------------------------------------------------------------------
Write-Host "`n== Group D: hanging grandchild timeout ==" -ForegroundColor Cyan
$toOut = New-OutDir 'beh_timeout'
$toMan = New-VariantManifest -Tag 'timeout' -Behavior 'timeout' -RoleExtra @{ delaySeconds = 45 }
$to = Invoke-Tool -ToolArgs (Get-CommonArgs -Out $toOut -Role generalist -Projection $genProjection -Model claude-opus-5 -Manifest $toMan -PerCall 30 -Total 12 -Activity 10) -LogName 'beh-timeout.log'
Check 'timeout exit=124' ($to.Exit -eq 124) ("got=$($to.Exit)")
Check 'timeout leaves no sealed package' (-not (Test-Path -LiteralPath (Join-Path $toOut 'package\transcript-package.json')))
$tePath = Join-Path $toOut 'package\terminal-evidence.json'
Check 'timeout writes terminal evidence' (Test-Path -LiteralPath $tePath)
if (Test-Path -LiteralPath $tePath) {
    $te = Read-Json $tePath
    Check 'timeout terminalStatus=timeout' ([string]$te.terminalStatus -eq 'timeout') ("got=$([string]$te.terminalStatus)")
    Check 'timeout evidence binds second generalist' (
        [string]$te.secondGeneralistModel -ceq 'gpt-5.6-sol') (
        "got='$([string]$te.secondGeneralistModel)'")
    $teTelemetryFile = @($te.files | Where-Object { [string]$_.name -ceq 'telemetry.jsonl' })
    Check 'timeout evidence proves zero real-model and binds telemetry sink' `
        ([int]$te.telemetry.realModelStarts -eq 0 -and
        [bool]$te.telemetry.fileExists -and [int]$te.telemetry.totalEvents -gt 0 -and
        $teTelemetryFile.Count -eq 1 -and
        [int64]$teTelemetryFile[0].bytes -eq [int64]$te.telemetry.sinkBytes -and
        [string]$teTelemetryFile[0].sha256 -ceq [string]$te.telemetry.sinkSha256)
    $childPid = [int]$te.supervisor.ProcessId
    $alive = $null
    try { $alive = Get-Process -Id $childPid -ErrorAction SilentlyContinue } catch { $alive = $null }
    Check 'timeout recursively killed the owned tree (child pid gone)' ($null -eq $alive) ("pid=$childPid")
}

# ---------------------------------------------------------------------------
# Group E - Seal integrity: intact / tamper / missing / cross-substitution
# ---------------------------------------------------------------------------
Write-Host "`n== Group E: seal verification ==" -ForegroundColor Cyan
$sealBase = New-OutDir 'beh_successOpus'   # reuse the sealed opus package from Group C
$verifyArgs = @('-VerifyOnly', '-OutputRoot', $sealBase, '-SealKeyPath', $sealKey)
$vi = Invoke-Tool -ToolArgs $verifyArgs -LogName 'verify-intact.log'
Check 'verifyOnly intact -> exit 0' ($vi.Exit -eq 0) ("exit=$($vi.Exit)")

$pairMismatchPackage = Copy-ResealedPackageVariant `
    -SourcePackage (Join-Path $sealBase 'package') `
    -Name 'second-generalist-manifest-core-mismatch' -Mutation {
        param($core, $manifest)
        $manifest.secondGeneralistModel = 'claude-opus-5'
    }
$pairMismatchRoot = Split-Path $pairMismatchPackage -Parent
$pairMismatch = Invoke-Tool -ToolArgs @(
    '-VerifyOnly', '-OutputRoot', $pairMismatchRoot, '-SealKeyPath', $sealKey
) -LogName 'verify-second-generalist-mismatch.log'
Check 'manifest/core second-generalist mismatch -> exit 2' (
    $pairMismatch.Exit -eq 2) ("exit=$($pairMismatch.Exit)")

$specialistMismatchPackage = Copy-ResealedPackageVariant `
    -SourcePackage (Join-Path $verificationEnabledOut 'package') `
    -Name 'specialist-manifest-core-mismatch' -Mutation {
        param($core, $manifest)
        $manifest.conventionSpecialistModel = 'claude-haiku-4.5'
    }
$specialistMismatchRoot = Split-Path $specialistMismatchPackage -Parent
$specialistMismatch = Invoke-Tool -ToolArgs @(
    '-VerifyOnly', '-OutputRoot', $specialistMismatchRoot, '-SealKeyPath', $sealKey
) -LogName 'verify-specialist-mismatch.log'
Check 'manifest/core convention-specialist mismatch -> exit 2' (
    $specialistMismatch.Exit -eq 2) ("exit=$($specialistMismatch.Exit)")

$specialistCoreTypePackage = Copy-ResealedPackageVariant `
    -SourcePackage (Join-Path $verificationEnabledOut 'package') `
    -Name 'specialist-core-boolean-string' -Mutation {
        param($core, $manifest)
        $core.conventionSpecialistEnabled = 'true'
    }
$specialistCoreTypeRoot = Split-Path $specialistCoreTypePackage -Parent
$specialistCoreType = Invoke-Tool -ToolArgs @(
    '-VerifyOnly', '-OutputRoot', $specialistCoreTypeRoot, '-SealKeyPath', $sealKey
) -LogName 'verify-specialist-core-boolean-string.log'
Check 'capture core string specialist-enabled value -> exit 2' (
    $specialistCoreType.Exit -eq 2) ("exit=$($specialistCoreType.Exit)")

$disabledCoreModelPackage = Copy-ResealedPackageVariant `
    -SourcePackage (Join-Path $sealBase 'package') `
    -Name 'disabled-core-empty-specialist-model' -Mutation {
        param($core, $manifest)
        $core.conventionSpecialistModel = ''
    }
$disabledCoreModelRoot = Split-Path $disabledCoreModelPackage -Parent
$disabledCoreModel = Invoke-Tool -ToolArgs @(
    '-VerifyOnly', '-OutputRoot', $disabledCoreModelRoot, '-SealKeyPath', $sealKey
) -LogName 'verify-disabled-core-empty-specialist-model.log'
Check 'disabled capture core empty specialist model -> exit 2' (
    $disabledCoreModel.Exit -eq 2) ("exit=$($disabledCoreModel.Exit)")

$partialLegacyCorePackage = Copy-ResealedPackageVariant `
    -SourcePackage (Join-Path $verificationEnabledOut 'package') `
    -Name 'partial-legacy-core-specialist-binding' -Mutation {
        param($core, $manifest)
        [void]$manifest.Remove('conventionSpecialistEnabled')
        [void]$manifest.Remove('conventionSpecialistModel')
        [void]$core.Remove('conventionSpecialistModel')
    }
$partialLegacyCoreRoot = Split-Path $partialLegacyCorePackage -Parent
$partialLegacyCore = Invoke-Tool -ToolArgs @(
    '-VerifyOnly', '-OutputRoot', $partialLegacyCoreRoot, '-SealKeyPath', $sealKey
) -LogName 'verify-partial-legacy-core-specialist-binding.log'
Check 'partial legacy capture core specialist binding -> exit 2' (
    $partialLegacyCore.Exit -eq 2) ("exit=$($partialLegacyCore.Exit)")

# Read-only seal: bound files at EVERY depth must carry the ReadOnly attribute.
$pkgDir = Join-Path $sealBase 'package'
$roViolations = @(Get-ChildItem -LiteralPath $pkgDir -File -Recurse -Force | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReadOnly) })
Check 'sealed package files are read-only' ($roViolations.Count -eq 0) ("writable=$($roViolations.Count)")

function Copy-Package { param([string]$Name) $dst = New-OutDir $Name; Remove-Tree $dst; $pkgDst = Join-Path $dst 'package'; New-Item -ItemType Directory -Force -Path $pkgDst | Out-Null
    # Recurse so nested bound artifacts (e.g. supervisor/*.log) are faithfully
    # reproduced; a non-recursive copy would drop them and pollute the tamper
    # tests with spurious missing-file failures.
    Copy-Item -Path (Join-Path $pkgDir '*') -Destination $pkgDst -Recurse -Force
    Get-ChildItem -LiteralPath $pkgDst -Recurse -Force | ForEach-Object { try { (Get-Item -LiteralPath $_.FullName -Force).Attributes = 'Normal' } catch { } }
    return $dst }

$tamperOut = Copy-Package 'seal_tamper'
$core = Join-Path $tamperOut 'package\capture-core.json'
$bytes = [IO.File]::ReadAllBytes($core); $bytes[[int]($bytes.Length / 2)] = $bytes[[int]($bytes.Length / 2)] -bxor 0x20; [IO.File]::WriteAllBytes($core, $bytes)
$vt = Invoke-Tool -ToolArgs @('-VerifyOnly', '-OutputRoot', $tamperOut, '-SealKeyPath', $sealKey) -LogName 'verify-tamper.log'
Check 'verifyOnly tamper -> exit 2' ($vt.Exit -eq 2) ("exit=$($vt.Exit)")

$missOut = Copy-Package 'seal_missing'
Remove-Item -LiteralPath (Join-Path $missOut 'package\result-marker.txt') -Force
$vm = Invoke-Tool -ToolArgs @('-VerifyOnly', '-OutputRoot', $missOut, '-SealKeyPath', $sealKey) -LogName 'verify-missing.log'
Check 'verifyOnly missing bound file -> exit 2' ($vm.Exit -eq 2) ("exit=$($vm.Exit)")

$subOut = Copy-Package 'seal_substitution'
Set-Content -LiteralPath (Join-Path $subOut 'package\injected-extra.txt') -Value 'unbound injection' -Encoding UTF8
$vs = Invoke-Tool -ToolArgs @('-VerifyOnly', '-OutputRoot', $subOut, '-SealKeyPath', $sealKey) -LogName 'verify-substitution.log'
Check 'verifyOnly cross-substitution -> exit 2' ($vs.Exit -eq 2) ("exit=$($vs.Exit)")

# -- Blocker 4: read-only immutability is VERIFIED fail-closed -----------------
# A sealed package whose bytes are ALL intact but which carries even a single
# WRITABLE bound file (a cleared read-only bit - including on a hidden or nested
# file) is rejected. Copy-PackageReadOnly reproduces the sealed read-only state so
# the ONLY thing under test is the writable hole; the intact copy verifies exit 0
# first, isolating the read-only bit as the sole cause of the exit-2 refusals.
function Copy-PackageReadOnly {
    param([string]$Name)
    $dst = New-OutDir $Name; Remove-Tree $dst
    $pkgDst = Join-Path $dst 'package'
    New-Item -ItemType Directory -Force -Path $pkgDst | Out-Null
    # Recurse so the faithful copy includes the nested bound supervisor logs, then
    # set EVERY file (any depth, incl. hidden) read-only to reproduce the sealed
    # immutable state.
    Copy-Item -Path (Join-Path $pkgDir '*') -Destination $pkgDst -Recurse -Force
    Get-ChildItem -LiteralPath $pkgDst -File -Recurse -Force | ForEach-Object {
        (Get-Item -LiteralPath $_.FullName -Force).Attributes = [IO.FileAttributes]::ReadOnly
    }
    return $dst
}
$roIntact = Copy-PackageReadOnly 'seal_ro_intact'
$vroi = Invoke-Tool -ToolArgs @('-VerifyOnly', '-OutputRoot', $roIntact, '-SealKeyPath', $sealKey) -LogName 'verify-ro-intact.log'
Check 'read-only faithful copy verifies intact -> exit 0' ($vroi.Exit -eq 0) ("exit=$($vroi.Exit)")

# The read-only hole targets a GENUINELY BOUND, NESTED artifact - the sealed
# supervisor stdout log under the package's supervisor/ subdirectory (blocker 4).
# The intact copy above already proved this nested artifact verifies when it is
# read-only; here only its read-only bit is cleared, so the sole cause of the
# exit-2 refusal is the writable nested bound file, and the diagnostic must name
# that exact nested path (proving the recursive read-only seal descends below the
# package root rather than false-passing on a top-level file).
$roHole = Copy-PackageReadOnly 'seal_ro_hole'
$roHoleTarget = Join-Path $roHole 'package\supervisor\supervisor-stdout.log'
Check 'nested bound artifact exists in faithful copy' (Test-Path -LiteralPath $roHoleTarget) 'missing supervisor/supervisor-stdout.log'
Check 'nested bound artifact is read-only before the hole' ([bool]((Get-Item -LiteralPath $roHoleTarget -Force).Attributes -band [IO.FileAttributes]::ReadOnly)) 'not read-only'
(Get-Item -LiteralPath $roHoleTarget -Force).Attributes = [IO.FileAttributes]::Normal
$vrh = Invoke-Tool -ToolArgs @('-VerifyOnly', '-OutputRoot', $roHole, '-SealKeyPath', $sealKey) -LogName 'verify-ro-hole.log'
Check 'verifyOnly writable nested bound file -> exit 2' ($vrh.Exit -eq 2) ("exit=$($vrh.Exit)")
$vrhLog = Get-Content -LiteralPath $vrh.Log -Raw
Check 'writable nested bound file names the specific artifact' ($vrhLog -match 'writable file present \(not read-only\): supervisor/supervisor-stdout\.log') 'missing specific diagnostic'

# hidden + nested writable: the OTHER nested bound supervisor log made hidden (and
# thereby writable). -Force surfacing must still catch it as writable.
$roHidden = Copy-PackageReadOnly 'seal_ro_hidden'
(Get-Item -LiteralPath (Join-Path $roHidden 'package\supervisor\supervisor-stderr.log') -Force).Attributes = [IO.FileAttributes]::Hidden
$vrhid = Invoke-Tool -ToolArgs @('-VerifyOnly', '-OutputRoot', $roHidden, '-SealKeyPath', $sealKey) -LogName 'verify-ro-hidden.log'
Check 'verifyOnly writable HIDDEN nested bound file -> exit 2' ($vrhid.Exit -eq 2) ("exit=$($vrhid.Exit)")

$roNested = Copy-PackageReadOnly 'seal_ro_nested'
New-Item -ItemType Directory -Force -Path (Join-Path $roNested 'package\nested') | Out-Null
Set-Content -LiteralPath (Join-Path $roNested 'package\nested\extra.txt') -Value 'nested writable' -Encoding UTF8
$vrn = Invoke-Tool -ToolArgs @('-VerifyOnly', '-OutputRoot', $roNested, '-SealKeyPath', $sealKey) -LogName 'verify-ro-nested.log'
Check 'verifyOnly nested writable unbound file -> exit 2' ($vrn.Exit -eq 2) ("exit=$($vrn.Exit)")

# ---------------------------------------------------------------------------
# Group F - Oracle-free sealed package (defence-in-depth recursive scan)
# ---------------------------------------------------------------------------
Write-Host "`n== Group F: oracle-free sealed package ==" -ForegroundColor Cyan
$mfHits = @(Get-ForbiddenHits -Node (Read-Json (Join-Path $sealBase 'package\transcript-package.json')))
Check 'sealed manifest carries no oracle/expected/label keys' ($mfHits.Count -eq 0) ("hits=$($mfHits -join ',')")
$coreHits = @(Get-ForbiddenHits -Node (Read-Json (Join-Path $sealBase 'package\capture-core.json')))
Check 'capture core carries no oracle/expected/label keys' ($coreHits.Count -eq 0) ("hits=$($coreHits -join ',')")

# ---------------------------------------------------------------------------
# Group G - Verifier: REAL execution through the exact production verifier path,
#           seeded by a SEALED, independently captured generalist discovery
#           package (blockers 1 + 3). The candidate is extracted from the sealed
#           discovery marker, never from truth, and its provenance (package
#           manifest digest, marker digest, candidate/cluster hash) is bound into
#           the sealed verifier package. Verifier marker failure is TERMINAL.
# ---------------------------------------------------------------------------
Write-Host "`n== Group G: verifier real execution (sealed discovery provenance) ==" -ForegroundColor Cyan
$discPkg = Join-Path (New-OutDir 'beh_successOpus') 'package'   # reuse Group C's sealed generalist capture

# The verifier candidate is EXTRACTED from the sealed discovery marker through the
# EXACT production candidate-extraction + clustering path (the generic operator tool
# tools\Get-ReviewerDiscoveryCandidate.ps1), never hand-authored and never truth-
# derived. The acquisition child INDEPENDENTLY re-derives the same candidate set and
# cluster from the same sealed marker and refuses to launch unless they match exactly
# (blocker A). Extracting it here at run time is mandatory: candidateHash binds the
# per-run nonce and reviewed HEAD, so no committed static candidate could ever match.
$extractTool = Join-Path $PSScriptRoot 'Get-ReviewerDiscoveryCandidate.ps1'
$genFixtureId = [string]((Get-Content $genProjection -Raw | ConvertFrom-Json).fixtureId)
$derivedCand = Join-Path $runRoot 'derived-candidate.json'
& pwsh -NoProfile -File $extractTool -DiscoveryPackageRoot $discPkg -SealKeyPath $sealKey `
    -OutputFile $derivedCand -SourceFixtureId $genFixtureId *> (Join-Path $logDir 'extract-candidate.log')
$exExtract = $LASTEXITCODE
Check 'discovery candidate extracted from the sealed discovery marker' (($exExtract -eq 0) -and (Test-Path -LiteralPath $derivedCand)) ("exit=$exExtract")

# G1 - happy path: the verifier captures a transcript through the exact production cycle.
$vgOut = New-OutDir 'verifier_exec'
$vgMan = New-VariantManifest -Tag 'verifierExec' -Behavior 'success' -RoleName 'reciprocal-opus-verifier'
$vg = Invoke-Tool -ToolArgs (Get-VerifierArgs -Out $vgOut -Manifest $vgMan -DiscoveryPackage $discPkg -Candidate $derivedCand) -LogName 'verifier-exec.log'
Check 'verifier exit=0' ($vg.Exit -eq 0) ("exit=$($vg.Exit)")
$vgPkg = Join-Path $vgOut 'package\transcript-package.json'
Check 'verifier sealed a transcript package' (Test-Path -LiteralPath $vgPkg)
if (Test-Path -LiteralPath $vgPkg) {
    $vmf = Read-Json $vgPkg
    Check 'verifier role=verifier' ([string]$vmf.role -eq 'verifier') ("role=$([string]$vmf.role)")
    Check 'verifier reportedModel=claude-opus-5' ([string]$vmf.reportedModel -eq 'claude-opus-5') ("got=$([string]$vmf.reportedModel)")
    Check 'verifier status=captured' ([string]$vmf.terminalStatus -eq 'captured') ("got=$([string]$vmf.terminalStatus)")
    Check 'verifier single invocation (attempts=1)' (@($vmf.attempts).Count -eq 1) ("got=$(@($vmf.attempts).Count)")
    Check 'verifier zero real-model starts' ([int]$vmf.telemetry.realModelStarts -eq 0 -and [int]$vmf.telemetry.modelSubprocessStarts -ge 1) ("real=$([int]$vmf.telemetry.realModelStarts)")
    Check 'verifier zeroWriteVerified' ([bool]$vmf.telemetry.zeroWriteVerified)
    $dg = $vmf.digests
    Check 'verifier binds discovery package manifest digest' ([bool]([string]$dg.discoveryPackageManifestSha256 -match '^[0-9a-f]{64}$'))
    Check 'verifier binds discovery marker digest' ([bool]([string]$dg.discoveryMarkerSha256 -match '^[0-9a-f]{64}$'))
    Check 'verifier binds candidate extraction hash' ([bool]([string]$dg.candidateExtractionHash -match '^[0-9a-f]{64}$'))
    Check 'verifier binds candidate + cluster hash' ([bool]([string]$dg.clusterHash -match '^[0-9a-f]{64}$') -and [bool]([string]$dg.candidateInputSha256 -match '^[0-9a-f]{64}$'))
    $realMarkerSha = (Get-FileHash -LiteralPath (Join-Path $discPkg 'result-marker.txt') -Algorithm SHA256).Hash.ToLowerInvariant()
    Check 'verifier discovery marker digest matches the sealed discovery package' ([string]$dg.discoveryMarkerSha256 -eq $realMarkerSha) ("bound=$([string]$dg.discoveryMarkerSha256)")
    Check 'verifier package carries no oracle/expected keys' (@(Get-ForbiddenHits -Node $vmf).Count -eq 0)
}

# G2 - terminal no-retry: a verifier marker failure never triggers a fresh-nonce retry.
$vtOut = New-OutDir 'verifier_terminal'
$vtMan = New-VariantManifest -Tag 'verifierTerminal' -Behavior 'missingMarker' -RoleName 'reciprocal-opus-verifier'
$vtr = Invoke-Tool -ToolArgs (Get-VerifierArgs -Out $vtOut -Manifest $vtMan -DiscoveryPackage $discPkg -Candidate $derivedCand) -LogName 'verifier-terminal.log'
$vtPkg = Join-Path $vtOut 'package\transcript-package.json'
if (Test-Path -LiteralPath $vtPkg) {
    $vtm = Read-Json $vtPkg
    Check 'verifier marker failure is terminal (no retry, attempts<=1)' (@($vtm.attempts).Count -le 1) ("attempts=$(@($vtm.attempts).Count)")
    Check 'verifier marker failure did not falsely capture' ([string]$vtm.terminalStatus -ne 'captured') ("status=$([string]$vtm.terminalStatus)")
    # Blocker 3: the sealed verifier attempt preserves the exact production run
    # class ('missingMarker'), the human reason and terminal (non-retryable)
    # semantics - never a coarse remap.
    Assert-ExactAttempt -Attempt (@($vtm.attempts)[-1]) -Label 'verifier missingMarker' -ExpectStatus 'missingMarker' -ExpectRetryable $false
}
else {
    $vtEv = Join-Path $vtOut 'package\terminal-evidence.json'
    Check 'verifier marker failure produced terminal evidence (no capture)' (Test-Path -LiteralPath $vtEv) ("exit=$($vtr.Exit)")
}

# G2b (blocker 3) - a verifier WRONG-BINDING marker (a replayed/wrong exact nonce)
# is the typed 'wrongBinding' run class naming its offending field, terminal and
# never retried - distinct from a missing marker.
$vwbOut = New-OutDir 'verifier_wrongbinding'
$vwbMan = New-VariantManifest -Tag 'verifierWrongBinding' -Behavior 'wrongBinding' -RoleName 'reciprocal-opus-verifier'
$vwb = Invoke-Tool -ToolArgs (Get-VerifierArgs -Out $vwbOut -Manifest $vwbMan -DiscoveryPackage $discPkg -Candidate $derivedCand) -LogName 'verifier-wrongbinding.log'
$vwbPkg = Join-Path $vwbOut 'package\transcript-package.json'
if (Test-Path -LiteralPath $vwbPkg) {
    $vwbm = Read-Json $vwbPkg
    Check 'verifier wrongBinding did not falsely capture' ([string]$vwbm.terminalStatus -ne 'captured') ("status=$([string]$vwbm.terminalStatus)")
    Assert-ExactAttempt -Attempt (@($vwbm.attempts)[-1]) -Label 'verifier wrongBinding' -ExpectStatus 'wrongBinding' -ExpectRetryable $false -ExpectDetail 'nonce'
}
else {
    Check 'verifier wrongBinding produced terminal evidence (no capture)' (Test-Path -LiteralPath (Join-Path $vwbOut 'package\terminal-evidence.json')) ("exit=$($vwb.Exit)")
}

# G2c (blocker 3) - verifier modelMismatch for BOTH reciprocal models: the CLI
# envelope reports a DIFFERENT model than the authorized verifier model, which the
# exact production verifier run classifies as the typed 'modelMismatch' class with
# a human reason naming the reported model. Terminal, no retry. The package binds
# BOTH identities: requestedModel is the authorized plan.model (what was authorized
# and launched), while reportedModel faithfully records the CLI envelope's actual
# claim (the mismatched identity) - the blinded capture never launders the reported
# model into the authorized one, which is exactly what makes the mismatch provable.
foreach ($vm in @(
        @{ Tag = 'opus'; Role = 'reciprocal-opus-verifier'; Model = 'claude-opus-5'; Other = 'gpt-5.6-sol' },
        @{ Tag = 'gpt'; Role = 'reciprocal-gpt-verifier'; Model = 'gpt-5.6-sol'; Other = 'claude-opus-5' })) {
    $mmOut = New-OutDir ("verifier_mm_" + $vm.Tag)
    $mmMan = New-VariantManifest -Tag ("verifierMM_" + $vm.Tag) -Behavior 'success' -RoleName $vm.Role -RoleExtra @{ reportedModelOverride = $vm.Other }
    $mm = Invoke-Tool -ToolArgs (Get-VerifierArgs -Out $mmOut -Manifest $mmMan -DiscoveryPackage $discPkg -Candidate $derivedCand -Model $vm.Model) -LogName ("verifier-mm-" + $vm.Tag + ".log")
    $mmPkg = Join-Path $mmOut 'package\transcript-package.json'
    if (Test-Path -LiteralPath $mmPkg) {
        $mmm = Read-Json $mmPkg
        Check "verifier $($vm.Tag) modelMismatch did not falsely capture" ([string]$mmm.terminalStatus -ne 'captured') ("status=$([string]$mmm.terminalStatus)")
        Check "verifier $($vm.Tag) modelMismatch reportedModel is the CLI-claimed (mismatched) model" ([string]$mmm.reportedModel -eq $vm.Other) ("got=$([string]$mmm.reportedModel) want=$($vm.Other)")
        Check "verifier $($vm.Tag) modelMismatch requestedModel is the authorized plan model" ([string]$mmm.requestedModel -eq $vm.Model) ("got=$([string]$mmm.requestedModel) want=$($vm.Model)")
        Assert-ExactAttempt -Attempt (@($mmm.attempts)[-1]) -Label "verifier $($vm.Tag) modelMismatch" -ExpectStatus 'modelMismatch' -ExpectRetryable $false -ReasonLike 'instead of'
    }
    else {
        Check "verifier $($vm.Tag) modelMismatch produced terminal evidence (no capture)" (Test-Path -LiteralPath (Join-Path $mmOut 'package\terminal-evidence.json')) ("exit=$($mm.Exit)")
    }
}

# G3 - a discovery package that is NOT an independent generalist capture (here a
# verifier package) is refused: the verifier never derives its candidate from a
# verifier self-capture.
$vbOut = New-OutDir 'verifier_baddiscovery'
$vbMan = New-VariantManifest -Tag 'verifierBadDisc' -Behavior 'success' -RoleName 'reciprocal-opus-verifier'
$vb = Invoke-Tool -ToolArgs (Get-VerifierArgs -Out $vbOut -Manifest $vbMan -DiscoveryPackage (Join-Path $vgOut 'package') -Candidate $derivedCand) -LogName 'verifier-baddisc.log'
Check 'verifier with a non-generalist discovery package is refused' (($vb.Exit -ne 0) -and -not (Test-Path -LiteralPath (Join-Path $vbOut 'package\transcript-package.json'))) ("exit=$($vb.Exit)")

# G4 (blocker A) - a candidate whose derived set was TAMPERED (one candidateHash
# flipped) no longer matches the set the child derives from the sealed discovery
# marker, so the verifier refuses before capturing anything. This proves the child
# re-derives the candidate through the exact production extraction/cluster path and
# requires exact equality - the candidate is the projection of the sealed discovery,
# never a fabricated or truth-derived one.
$tamperCand = Join-Path $runRoot 'derived-candidate-tampered.json'
$cj = Get-Content $derivedCand -Raw | ConvertFrom-Json -Depth 64
$origHash = [string]$cj.candidates[0].candidateHash
$flip = if ($origHash.Substring(0, 1) -ceq 'a') { 'b' } else { 'a' }
$cj.candidates[0].candidateHash = $flip + $origHash.Substring(1)
$cj.candidates[0].candidateId = "cand1:$($cj.candidates[0].candidateHash)"
($cj | ConvertTo-Json -Depth 64) | Set-Content -LiteralPath $tamperCand -Encoding UTF8
$vzOut = New-OutDir 'verifier_tampered'
$vzMan = New-VariantManifest -Tag 'verifierTampered' -Behavior 'success' -RoleName 'reciprocal-opus-verifier'
$vz = Invoke-Tool -ToolArgs (Get-VerifierArgs -Out $vzOut -Manifest $vzMan -DiscoveryPackage $discPkg -Candidate $tamperCand) -LogName 'verifier-tampered.log'
Check 'verifier refuses a candidate not derived from the sealed marker (blocker A)' (($vz.Exit -ne 0) -and -not (Test-Path -LiteralPath (Join-Path $vzOut 'package\transcript-package.json'))) ("exit=$($vz.Exit)")

# G5 (blocker B) - the AUTHORIZED plan.model is exactly the captured verifier model.
# A GPT verifier (not just Opus) captures a transcript reporting exactly gpt-5.6-sol,
# scoring the same opus-origin discovery candidate through the reciprocal assignment.
$vgpOut = New-OutDir 'verifier_gpt'
$vgpMan = New-VariantManifest -Tag 'verifierGpt' -Behavior 'success' -RoleName 'reciprocal-gpt-verifier'
$vgp = Invoke-Tool -ToolArgs (Get-VerifierArgs -Out $vgpOut -Manifest $vgpMan -DiscoveryPackage $discPkg -Candidate $derivedCand -Model 'gpt-5.6-sol') -LogName 'verifier-gpt.log'
Check 'gpt verifier exit=0' ($vgp.Exit -eq 0) ("exit=$($vgp.Exit)")
$vgpPkg = Join-Path $vgpOut 'package\transcript-package.json'
Check 'gpt verifier sealed a transcript package' (Test-Path -LiteralPath $vgpPkg)
if (Test-Path -LiteralPath $vgpPkg) {
    $vgpm = Read-Json $vgpPkg
    Check 'gpt verifier role=verifier' ([string]$vgpm.role -eq 'verifier') ("role=$([string]$vgpm.role)")
    Check 'gpt verifier reportedModel=gpt-5.6-sol' ([string]$vgpm.reportedModel -eq 'gpt-5.6-sol') ("got=$([string]$vgpm.reportedModel)")
    Check 'gpt verifier status=captured' ([string]$vgpm.terminalStatus -eq 'captured') ("got=$([string]$vgpm.terminalStatus)")
    Check 'gpt verifier zero real-model starts' ([int]$vgpm.telemetry.realModelStarts -eq 0 -and [int]$vgpm.telemetry.modelSubprocessStarts -ge 1) ("real=$([int]$vgpm.telemetry.realModelStarts)")
}

# G6 (blocker B) - naming a verifier model different from the captured -Model is
# refused up front; acquisition captures exactly the authorized model, never a
# second/other verifier model in the same declaration.
$vmmOut = New-OutDir 'verifier_modelMismatch'
$vmmArgs = (Get-VerifierArgs -Out $vmmOut -Manifest $vgMan -DiscoveryPackage $discPkg -Candidate $derivedCand) + @('-ConventionVerifierModel', 'gpt-5.6-sol')
$vmm = Invoke-Tool -ToolArgs $vmmArgs -LogName 'verifier-modelmismatch.log'
Check 'verifier refuses a differing convention verifier model (blocker B)' (($vmm.Exit -ne 0) -and -not (Test-Path -LiteralPath (Join-Path $vmmOut 'package\transcript-package.json'))) ("exit=$($vmm.Exit)")

# G7 (blocker 1) - a candidate whose resultMarkerBinding disagrees with the sealed
# discovery marker (here a DIFFERENT sourceCommit) is refused. The outer derives the
# result-marker prefix + FULL binding DIRECTLY from the sealed discovery marker and
# rejects caller metadata that does not equal the derived provenance, before any
# verifier launch. This is distinct from G4 (a tampered candidateHash): here the
# candidate's declared source-commit binding itself is not marker-derived.
$provCand = Join-Path $runRoot 'derived-candidate-badbinding.json'
$pj = Get-Content $derivedCand -Raw | ConvertFrom-Json -Depth 64
$pj.resultMarkerBinding.sourceCommit = 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
($pj | ConvertTo-Json -Depth 64) | Set-Content -LiteralPath $provCand -Encoding UTF8
$vpOut = New-OutDir 'verifier_badbinding'
$vpMan = New-VariantManifest -Tag 'verifierBadBinding' -Behavior 'success' -RoleName 'reciprocal-opus-verifier'
$vp = Invoke-Tool -ToolArgs (Get-VerifierArgs -Out $vpOut -Manifest $vpMan -DiscoveryPackage $discPkg -Candidate $provCand) -LogName 'verifier-badbinding.log'
Check 'verifier refuses a candidate binding not derived from the sealed marker (blocker 1)' (($vp.Exit -ne 0) -and -not (Test-Path -LiteralPath (Join-Path $vpOut 'package\transcript-package.json'))) ("exit=$($vp.Exit)")

# G8 (blocker 1) - the source fixture is DERIVED from the sealed discovery package's
# capture-core evidence, never asserted by the operator. A candidate whose declared
# sourceFixtureId disagrees with the sealed discovery package fixtureId is refused
# before any verifier launch.
$xfCand = Join-Path $runRoot 'derived-candidate-crossfixture.json'
$xfj = Get-Content $derivedCand -Raw | ConvertFrom-Json -Depth 64
$xfj.sourceFixtureId = 'some-other-fixture'
($xfj | ConvertTo-Json -Depth 64) | Set-Content -LiteralPath $xfCand -Encoding UTF8
$xfOut = New-OutDir 'verifier_crossfixture'
$xfMan = New-VariantManifest -Tag 'verifierCrossFixture' -Behavior 'success' -RoleName 'reciprocal-opus-verifier'
$xf = Invoke-Tool -ToolArgs (Get-VerifierArgs -Out $xfOut -Manifest $xfMan -DiscoveryPackage $discPkg -Candidate $xfCand) -LogName 'verifier-crossfixture.log'
Check 'verifier refuses a candidate sourceFixtureId != sealed package fixtureId (blocker 1)' (($xf.Exit -ne 0) -and -not (Test-Path -LiteralPath (Join-Path $xfOut 'package\transcript-package.json'))) ("exit=$($xf.Exit)")

# G9 (blocker 1) - the extraction helper itself derives sourceFixtureId from the sealed
# package and REFUSES an operator -SourceFixtureId that disagrees with the sealed
# evidence: the operator can confirm the fixture but can never assert it.
$hxLog = Join-Path $logDir 'extract-crossfixture.log'
& pwsh -NoProfile -File $extractTool -DiscoveryPackageRoot $discPkg -SealKeyPath $sealKey `
    -OutputFile (Join-Path $runRoot 'unused-crossfixture.json') -SourceFixtureId 'not-the-package-fixture' *> $hxLog
$hxExit = $LASTEXITCODE
Check 'extraction helper refuses a -SourceFixtureId != sealed package fixtureId (blocker 1)' ($hxExit -ne 0) ("exit=$hxExit")

# G10 (blocker 1) - with NO -SourceFixtureId the helper derives the fixture SOLELY from
# the sealed package evidence, and the derived candidate's sourceFixtureId equals it.
$derivedNoFix = Join-Path $runRoot 'derived-candidate-nofix.json'
& pwsh -NoProfile -File $extractTool -DiscoveryPackageRoot $discPkg -SealKeyPath $sealKey `
    -OutputFile $derivedNoFix *> (Join-Path $logDir 'extract-nofix.log')
$nfExit = $LASTEXITCODE
Check 'extraction helper derives a candidate without -SourceFixtureId (blocker 1)' (($nfExit -eq 0) -and (Test-Path -LiteralPath $derivedNoFix)) ("exit=$nfExit")
if (Test-Path -LiteralPath $derivedNoFix) {
    $nfj = Read-Json $derivedNoFix
    Check 'derived candidate sourceFixtureId equals sealed package fixtureId (blocker 1)' ([string]$nfj.sourceFixtureId -eq $genFixtureId) ("got=$([string]$nfj.sourceFixtureId)")
}

# ---------------------------------------------------------------------------
# Group H - Duplicate / consumed lease (no resume, no replacement)
# ---------------------------------------------------------------------------
Write-Host "`n== Group H: duplicate / consumed lease ==" -ForegroundColor Cyan
Check 'first run left a consumed launch lease' (Test-Path -LiteralPath (Get-LaunchLeasePath -OutputRoot $sealBase))
$dupMan = New-VariantManifest -Tag 'dup' -Behavior 'success'
$dup = Invoke-Tool -ToolArgs (Get-CommonArgs -Out $sealBase -Role generalist -Projection $genProjection -Model claude-opus-5 -Manifest $dupMan) -LogName 'duplicate.log'
Check 'second run into a consumed output root refuses' ($dup.Exit -ne 0) ("exit=$($dup.Exit)")
$leaseLoserOut = New-OutDir 'lease_loser_no_root'
Remove-Tree $leaseLoserOut
$leaseLoserPath = Get-LaunchLeasePath -OutputRoot $leaseLoserOut
[IO.File]::WriteAllText($leaseLoserPath, 'preexisting lease', [Text.UTF8Encoding]::new($false))
try {
    $leaseLoser = Invoke-Tool -ToolArgs (Get-CommonArgs -Out $leaseLoserOut -Role generalist `
            -Projection $genProjection -Model claude-opus-5 -Manifest $dupMan) -LogName 'lease-loser-no-root.log'
    Check 'lease loser refuses before launch' ($leaseLoser.Exit -ne 0) ("exit=$($leaseLoser.Exit)")
    Check 'lease loser does not create the output root' (-not (Test-Path -LiteralPath $leaseLoserOut))
}
finally {
    Remove-Item -LiteralPath $leaseLoserPath -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Group I - Credential scrub + zero-write proof
# ---------------------------------------------------------------------------
Write-Host "`n== Group I: credential scrub / zero-write ==" -ForegroundColor Cyan
$sentinel = 'ACQ_SENTINEL_' + ([Guid]::NewGuid().ToString('N'))
$credentialParentValues = @{}
foreach ($credentialName in $credentialVariableNames) {
    $credentialParentValues[$credentialName] = [Environment]::GetEnvironmentVariable($credentialName)
    Set-Item "Env:$credentialName" "$credentialName-$sentinel-$([Guid]::NewGuid().ToString('N'))"
}
try {
    $credOut = New-OutDir 'cred_scrub'
    $credMan = New-VariantManifest -Tag 'cred' -Behavior 'success'
    $cr = Invoke-Tool -ToolArgs (Get-CommonArgs -Out $credOut -Role generalist -Projection $genProjection -Model claude-opus-5 -Manifest $credMan) -LogName 'cred-scrub.log'
    Check 'credential run seals successfully' ($cr.Exit -eq 0) ("exit=$($cr.Exit)")
    Check 'offline MCP/tool adapter receives neither credential family' ($cr.Exit -eq 0) `
        'the adapter fails closed if any ADO or GitHub credential is present'
    $leaks = @(Get-ChildItem -LiteralPath $credOut -Recurse -File | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue) -match [regex]::Escape($sentinel) })
    Check 'no credential value written to any acquisition artifact' ($leaks.Count -eq 0) ("leakedFiles=$($leaks.Count)")
    $logLeak = (Get-Content -LiteralPath $cr.Log -Raw -ErrorAction SilentlyContinue) -match [regex]::Escape($sentinel)
    Check 'no credential value in supervisor output' (-not $logLeak)
    $cm = Read-Json (Join-Path $credOut 'package\transcript-package.json')
    Check 'telemetry proves no provider live process' ([int]$cm.telemetry.providerLiveProcessStarts -eq 0)
    Check 'telemetry proves no provider/tool write' ([int]$cm.telemetry.providerLiveWrites -eq 0 -and [int]$cm.telemetry.writeToolInvocations -eq 0)
    $pkgText = (Get-ChildItem -LiteralPath (Join-Path $credOut 'package') -File -Recurse -Force | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
    Check 'no authorization token persisted in the package' (-not ($pkgText -match 'authorizationToken')) ''

    $adapterGuardLog = Join-Path $logDir 'credential-adapter-negative.log'
    $emptyBinding = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{}'))
    & pwsh -NoProfile -File $adapterReal -ManifestPath $baseManifest -Role blind-opus `
        -Model claude-opus-5 -ExpectedBaseCommit $expectedBase -BindingBase64 $emptyBinding `
        *> $adapterGuardLog
    $adapterGuardExit = $LASTEXITCODE
    $adapterGuardText = Get-Content -LiteralPath $adapterGuardLog -Raw
    Check 'offline adapter fails closed when invoked with a credential' `
        ($adapterGuardExit -ne 0 -and
            $adapterGuardText -match 'credential boundary violated: AZURE_DEVOPS_EXT_PAT is present') `
        ("exit=$adapterGuardExit")
    Check 'offline adapter refusal reports no credential value' `
        (-not ($adapterGuardText -match [regex]::Escape($sentinel)))
}
finally {
    foreach ($credentialName in $credentialVariableNames) {
        if ($null -eq $credentialParentValues[$credentialName]) {
            Remove-Item "Env:$credentialName" -ErrorAction SilentlyContinue
        }
        else { Set-Item "Env:$credentialName" $credentialParentValues[$credentialName] }
    }
}
Check 'parent credential environment restored after run' `
    (@($credentialVariableNames | Where-Object {
                [Environment]::GetEnvironmentVariable($_) -cne $credentialParentValues[$_]
            }).Count -eq 0)

# ---------------------------------------------------------------------------
# Group J - Specialist: REAL execution through the exact production specialist
#           path (New-ReviewerConventionSpecialistInput, the convention-review
#           marker schema/scan window, the exact parser) and its OWN bounded
#           fresh-nonce retry loop. Driven against the convention snapshot that
#           serves repo identity so a convention pack is actually selected.
# ---------------------------------------------------------------------------
Write-Host "`n== Group J: specialist real execution (bounded fresh-nonce retry) ==" -ForegroundColor Cyan
function Test-Specialist {
    param([string]$Name, [string]$Behavior, [hashtable]$RoleExtra, [int]$ExpectAttempts,
        [string]$ExpectStatus, [switch]$DistinctNonces, [switch]$LooseTerminal)
    $out = New-OutDir ("sp_" + $Name)
    $man = New-VariantManifest -Tag ("sp_" + $Name) -Behavior $Behavior -RoleName 'specialist' -RoleExtra $RoleExtra
    $r = Invoke-Tool -ToolArgs (Get-SpecialistArgs -Out $out -Manifest $man) -LogName ("sp-" + $Name + ".log")
    Check "specialist $Name exit=0" ($r.Exit -eq 0) ("got=$($r.Exit)")
    $mp = Join-Path $out 'package\transcript-package.json'
    if (-not (Test-Path -LiteralPath $mp)) { Check "specialist $Name sealed manifest present" $false 'missing'; return }
    $m = Read-Json $mp
    Check "specialist $Name role=specialist" ([string]$m.role -eq 'specialist') ("got=$([string]$m.role)")
    Check "specialist $Name reportedModel=claude-sonnet-5" ([string]$m.reportedModel -eq 'claude-sonnet-5') ("got=$([string]$m.reportedModel)")
    Check "specialist $Name attempts=$ExpectAttempts" (@($m.attempts).Count -eq $ExpectAttempts) ("got=$(@($m.attempts).Count)")
    if ($LooseTerminal) {
        Check "specialist $Name terminal (not captured, no retry)" ([string]$m.terminalStatus -ne 'captured' -and [string]$m.terminalStatus -ne 'captureFailedRetriesExhausted') ("got=$([string]$m.terminalStatus)")
    }
    else {
        Check "specialist $Name status=$ExpectStatus" ([string]$m.terminalStatus -eq $ExpectStatus) ("got=$([string]$m.terminalStatus)")
    }
    Check "specialist $Name zero real-model starts" ([int]$m.telemetry.realModelStarts -eq 0 -and [int]$m.telemetry.modelSubprocessStarts -ge 1) ("real=$([int]$m.telemetry.realModelStarts) sub=$([int]$m.telemetry.modelSubprocessStarts)")
    Check "specialist $Name zeroWriteVerified" ([bool]$m.telemetry.zeroWriteVerified) ''
    Check "specialist $Name marker prefix is the convention marker" ([string]$m.resultMarkerPrefix -like 'CONVENTION_REVIEW_RESULT_V2:*') ("got=$([string]$m.resultMarkerPrefix)")
    if ($DistinctNonces) {
        $ns = @(@($m.attempts) | ForEach-Object { [string]$_.nonce })
        Check "specialist $Name retry uses a fresh distinct nonce" ($ns.Count -ge 2 -and $ns[0] -cne $ns[1]) ("$($ns -join ',')")
        Check "specialist $Name first attempt was retryable" ([bool]@($m.attempts)[0].retryable) ''
    }
}
$specialistFindingTemplate = [ordered]@{
    schemaVersion = 2
    prId = '{{binding.prId}}'
    repositoryId = '{{binding.repositoryId}}'
    project = '{{binding.project}}'
    reviewedSourceCommit = '{{binding.reviewedSourceCommit}}'
    targetCommit = '{{binding.targetCommit}}'
    changeSetDigest = '{{binding.changeSetDigest}}'
    conventionPlanSha256 = '{{binding.conventionPlanSha256}}'
    factPlanSha256 = '{{binding.factPlanSha256}}'
    configSha256 = '{{binding.configSha256}}'
    scriptSha256 = '{{binding.scriptSha256}}'
    promptSha256 = '{{binding.promptSha256}}'
    candidates = @([ordered]@{
            candidateId = 'immutable-state-reassignment'; category = 'convention'
            severity = 'suggestion'; anchorKind = 'changedFile'; filePath = '/src/Widget.cs'; line = 15
            primaryTarget = 'cf0:15'; manifestations = ''; packName = 'widget-core'
            ruleSourceId = 'widget-rules'
            ruleSourceRepositoryId = '11111111-2222-3333-4444-555555555555'
            ruleSourcePath = '/docs/conventions.md'
            ruleSourceCommit = 'f0e1d2c3b4a5f6e7d8c9b0a1f2e3d4c5b6a7f8e9'
            ruleSourceSha256 = '4b63e99eb07cf85e89dfdff08eca824ecfc305dcf2ba6ca4b71a691c978b8e12'
            ruleSection = 'Immutable state'; ruleQuote = 'never reassigning it'
            diffEvidence = 'The changed Rename method reassigns widgetId after construction.'
            impactCategory = 'none'
            impact = 'The object no longer preserves the authoritative immutable-state convention.'
            expectedFixOrValidation = 'Remove the reassignment or construct a new immutable widget.'
            siblingStatus = 'notRequired'; siblingEvidence = ''
            siblingNotRequiredReason = 'The violation is fully established by the changed assignment.'
            factIds = ''; confidence = 'high'; residualRiskSummary = ''
            semanticCandidateVersion = 2
            changedCodeFix = [ordered]@{
                action = 'remove'; targets = 'cf0:15'; conventionKey = 'ImmutableState'
                valueSource = 'authoritativeRule'; evidenceFactIds = ''
            }
            existingDebtFollowUp = [ordered]@{
                status = 'none'; evidenceFactId = ''; selectorKey = ''; scopeKind = ''; scopePath = ''
                comparableCount = 0; compliantCount = 0; action = ''
            }
        })
    ruleCoverage = @([ordered]@{
            ruleRef = 'rs0'
            ruleSourceSha256 = '4b63e99eb07cf85e89dfdff08eca824ecfc305dcf2ba6ca4b71a691c978b8e12'
            ruleQuote = 'never reassigning it'; status = 'violation'; scope = 'none'
            violatingConstructs = 'as0'; compliantConstructs = ''
            notInReachConstructs = 'dc0'; unknownConstructs = ''
            violatingChangedFileTargets = 'cf0:15'
            codeEvidence = 'The changed line reassigns widgetId after construction.'
            siblingStatus = 'notRequired'; siblingEvidence = ''
            candidateId = 'immutable-state-reassignment'; notes = ''
        })
    withheld = @(); residualRisks = @(); nonce = '{{binding.nonce}}'
}
Test-Specialist -Name 'success' -Behavior 'success' -RoleExtra @{ markerTemplate = $specialistFindingTemplate } `
    -ExpectAttempts 1 -ExpectStatus 'captured'
Test-Specialist -Name 'missingMarker' -Behavior 'missingMarker' -ExpectAttempts 3 -ExpectStatus 'captureFailedRetriesExhausted' -DistinctNonces
Test-Specialist -Name 'truncatedMarker' -Behavior 'truncatedMarker' -ExpectAttempts 3 -ExpectStatus 'captureFailedRetriesExhausted' -DistinctNonces
Test-Specialist -Name 'schemaInvalidMarker' -Behavior 'schemaInvalidMarker' -ExpectAttempts 3 -ExpectStatus 'captureFailedRetriesExhausted' -DistinctNonces
Test-Specialist -Name 'wrongBinding' -Behavior 'wrongBinding' -ExpectAttempts 1 -LooseTerminal

# Blocker 3: the specialist attempt ledger preserves the EXACT production parser
# status/reason/detail verbatim (never a coarse ok/terminal/markerMissing remap or
# a rejectionClass-as-reason). Each retryable emission slip keeps its typed class
# and retryability; the wrong-binding attempt is terminal and names its field.
$spMiss = Read-Json (Join-Path (New-OutDir 'sp_missingMarker') 'package\transcript-package.json')
Assert-ExactAttempt -Attempt (@($spMiss.attempts)[0]) -Label 'specialist missingMarker' -ExpectStatus 'missingMarker' -ExpectRetryable $true
$spTrunc = Read-Json (Join-Path (New-OutDir 'sp_truncatedMarker') 'package\transcript-package.json')
Assert-ExactAttempt -Attempt (@($spTrunc.attempts)[0]) -Label 'specialist truncatedMarker' -ExpectStatus 'truncated' -ExpectRetryable $true
$spSchema = Read-Json (Join-Path (New-OutDir 'sp_schemaInvalidMarker') 'package\transcript-package.json')
Assert-ExactAttempt -Attempt (@($spSchema.attempts)[0]) -Label 'specialist schemaInvalidMarker' -ExpectStatus 'schemaInvalid' -ExpectRetryable $true -ExpectDetailNonEmpty
$spWrong = Read-Json (Join-Path (New-OutDir 'sp_wrongBinding') 'package\transcript-package.json')
Assert-ExactAttempt -Attempt (@($spWrong.attempts)[-1]) -Label 'specialist wrongBinding' -ExpectStatus 'wrongBinding' -ExpectRetryable $false -ExpectDetail 'nonce'

# J2 - an authenticated specialist package projects convention-origin candidates,
# and either configured generalist can verify them. The specialist itself cannot.
$specialistPackage = Join-Path (New-OutDir 'sp_success') 'package'
$specialistCandidate = Join-Path $runRoot 'specialist-discovery-candidate.json'
& pwsh -NoProfile -File $extractTool -DiscoveryPackageRoot $specialistPackage `
    -SealKeyPath $sealKey -ExpectedSourceScriptSha256 $currentReviewerSha `
    -OutputFile $specialistCandidate *> (Join-Path $logDir 'specialist-extract.log')
$specialistExtractExit = $LASTEXITCODE
Check 'specialist package extracts an authenticated candidate' (
    $specialistExtractExit -eq 0 -and (Test-Path -LiteralPath $specialistCandidate)) "exit=$specialistExtractExit"
$wrongPinCandidate = Join-Path $runRoot 'specialist-wrong-script-pin-candidate.json'
& pwsh -NoProfile -File $extractTool -DiscoveryPackageRoot $specialistPackage `
    -SealKeyPath $sealKey -ExpectedSourceScriptSha256 ('0' * 64) `
    -OutputFile $wrongPinCandidate *> (Join-Path $logDir 'specialist-extract-wrong-script-pin.log')
Check 'specialist candidate extraction rejects a mismatched explicit source-script pin' (
    $LASTEXITCODE -ne 0 -and -not (Test-Path -LiteralPath $wrongPinCandidate))

$legacySpecialistPackage = Copy-ResealedPackageWithoutSourceProjection -SourcePackage $specialistPackage
$legacySpecialistCandidate = Join-Path $runRoot 'specialist-legacy-discovery-candidate.json'
& pwsh -NoProfile -File $extractTool -DiscoveryPackageRoot $legacySpecialistPackage `
    -SealKeyPath $sealKey -ExpectedSourceScriptSha256 $currentReviewerSha `
    -OutputFile $legacySpecialistCandidate *> (Join-Path $logDir 'specialist-legacy-extract.log')
$legacySpecialistExtractExit = $LASTEXITCODE
Check 'authenticated pre-sourceProjection specialist package derives a convention candidate' (
    $legacySpecialistExtractExit -eq 0 -and (Test-Path -LiteralPath $legacySpecialistCandidate)) `
    "exit=$legacySpecialistExtractExit"
if (Test-Path -LiteralPath $specialistCandidate) {
    $sc = Read-Json $specialistCandidate
    Check 'specialist candidate preserves specialist/convention origin' (
        [string]$sc.sourceRole -ceq 'specialist' -and
        [string]$sc.sourceModel -ceq 'claude-sonnet-5' -and
        @($sc.candidates).Count -gt 0 -and
        @($sc.candidates | Where-Object {
                [string]$_.originKind -cne 'convention' -or
                [string]$_.originModel -cne 'claude-sonnet-5'
            }).Count -eq 0)

    foreach ($target in @(
            @{ Tag = 'opus'; Model = 'claude-opus-5'; RoleName = 'reciprocal-opus-verifier';
                Package = $specialistPackage; Candidate = $specialistCandidate },
            @{ Tag = 'gpt'; Model = 'gpt-5.6-sol'; RoleName = 'reciprocal-gpt-verifier';
                Package = $legacySpecialistPackage; Candidate = $legacySpecialistCandidate })) {
        $out = New-OutDir "specialist_verifier_$($target.Tag)"
        $manifest = New-VariantManifest -Tag "specialistVerifier$($target.Tag)" `
            -Behavior 'success' -RoleName $target.RoleName
        $run = Invoke-Tool -ToolArgs (Get-VerifierArgs -Out $out -Manifest $manifest `
                -DiscoveryPackage $target.Package -Candidate $target.Candidate `
                -Model $target.Model -UseConventionSnapshot) -LogName "specialist-verifier-$($target.Tag).log"
        Check "specialist candidate -> $($target.Tag) verifier succeeds" ($run.Exit -eq 0) "exit=$($run.Exit)"
        if (Test-Path -LiteralPath (Join-Path $out 'package\transcript-package.json')) {
            $sealedVerifier = Read-Json (Join-Path $out 'package\transcript-package.json')
            Check "$($target.Tag) verifier seals exact target model" (
                [string]$sealedVerifier.role -ceq 'verifier' -and
                [string]$sealedVerifier.requestedModel -ceq [string]$target.Model -and
                [string]$sealedVerifier.terminalStatus -ceq 'captured')
        }
    }

    $badOrigin = Join-Path $runRoot 'specialist-candidate-badorigin.json'
    $badOriginObject = Read-Json $specialistCandidate
    $badOriginObject.candidates[0].originKind = 'generalist'
    ($badOriginObject | ConvertTo-Json -Depth 64) | Set-Content -LiteralPath $badOrigin -Encoding UTF8
    $badOriginOut = New-OutDir 'specialist_verifier_badorigin'
    $badOriginManifest = New-VariantManifest -Tag 'specialistVerifierBadOrigin' `
        -Behavior 'success' -RoleName 'reciprocal-opus-verifier'
    $badOriginRun = Invoke-Tool -ToolArgs (Get-VerifierArgs -Out $badOriginOut `
            -Manifest $badOriginManifest -DiscoveryPackage $specialistPackage `
            -Candidate $badOrigin -UseConventionSnapshot) -LogName 'specialist-verifier-badorigin.log'
    Check 'specialist candidate with fabricated generalist origin is rejected' ($badOriginRun.Exit -ne 0) "exit=$($badOriginRun.Exit)"

    $specialistTargetOut = New-OutDir 'specialist_as_verifier'
    $specialistTargetManifest = New-VariantManifest -Tag 'specialistAsVerifier' `
        -Behavior 'success' -RoleName 'reciprocal-opus-verifier'
    $specialistTargetRun = Invoke-Tool -ToolArgs (Get-VerifierArgs -Out $specialistTargetOut `
            -Manifest $specialistTargetManifest -DiscoveryPackage $specialistPackage `
            -Candidate $specialistCandidate -Model 'claude-sonnet-5' -UseConventionSnapshot) `
        -LogName 'specialist-as-verifier.log'
    Check 'configured specialist is rejected as verifier target' ($specialistTargetRun.Exit -ne 0) "exit=$($specialistTargetRun.Exit)"
}

# ---------------------------------------------------------------------------
# Group K - Inner authorization-token gate + adapter containment, proven by
#           invoking Start-ReviewerAgent's acquisition child DIRECTLY (bypassing
#           the outer supervisor). The token is handed only through the scrubbed
#           env var, never argv; the gate constant-time verifies its SHA-256
#           against the plan before any launch (blockers 2 + 4).
# ---------------------------------------------------------------------------
Write-Host "`n== Group K: inner token gate + adapter containment (direct child) ==" -ForegroundColor Cyan
$kBase = New-OutDir 'direct_planbase'
$kMan = New-VariantManifest -Tag 'directPlanBase' -Behavior 'success'
$kb = Invoke-Tool -ToolArgs (Get-CommonArgs -Out $kBase -Role generalist -Projection $genProjection -Model claude-opus-5 -Manifest $kMan) -LogName 'direct-planbase.log'
Check 'group K plan-base run sealed' ($kb.Exit -eq 0) ("exit=$($kb.Exit)")
$kPlan = Join-Path $kBase 'work\acquisition-plan.json'
if (-not (Test-Path -LiteralPath $kPlan)) { Check 'group K prerequisite plan exists' $false "missing $kPlan" }
else {
    $planObj = Read-Json $kPlan
    Check 'authored plan binds only the token SHA-256 (raw token never persisted)' (($planObj.PSObject.Properties['authorizationTokenSha256']) -and -not ($planObj.PSObject.Properties['authorizationToken'])) ''
    # Missing token -> refuse at the token gate (a direct bypass is refused).
    $k1 = Invoke-ChildDirect -Label 'missingToken' -PlanFile $kPlan -Projection $genProjection -Env @{}
    Check 'direct child with NO token refuses' (($k1.Exit -ne 0) -and -not $k1.Captured) ("exit=$($k1.Exit)")
    Check 'direct child no-token cites the missing authorization' ($k1.Log -match 'none was presented') ''
    # Wrong token -> constant-time mismatch -> refuse before any launch.
    $k2 = Invoke-ChildDirect -Label 'wrongToken' -PlanFile $kPlan -Projection $genProjection -Env @{ REVIEWER_ACQUISITION_TOKEN = ('f' * 64) }
    Check 'direct child with WRONG token refuses' (($k2.Exit -ne 0) -and -not $k2.Captured) ("exit=$($k2.Exit)")
    Check 'direct child wrong-token cites a plan mismatch' ($k2.Log -match 'does not match the plan') ''
    # Adapter containment: no explicit test-only switch -> refuse at startup.
    $k3 = Invoke-ChildDirect -Label 'noSwitch' -PlanFile $kPlan -Projection $genProjection -Env @{ REVIEWER_ACQUISITION_TOKEN = ('f' * 64) } -OmitTestOnlySwitch
    Check 'direct child without the test-only switch refuses (containment)' (($k3.Exit -ne 0) -and -not $k3.Captured) ("exit=$($k3.Exit)")
    Check 'no-switch cites the missing test-only switch' ($k3.Log -match 'AcquisitionTestOnlyOfflineAdapter') ''
    # The production acquisition accepts ExpectedReviewerBaseCommit as a plan
    # binding, but the forbidden telemetry CLI switch still requests adapter mode
    # and must reproduce the original partial-adapter rejection.
    $kTelemetryEnv = @{
        REVIEWER_ACQUISITION_TOKEN       = ('f' * 64)
        DEVPILOT_OFFLINE_TELEMETRY_MODE = 'production-test-only'
        DEVPILOT_OFFLINE_TELEMETRY_PATH = (Join-Path $runRoot 'direct-forbidden-env.jsonl')
    }
    $kForbidden = Invoke-ChildDirect -Label 'forbiddenTelemetry' -PlanFile $kPlan `
        -Projection $genProjection -Env $kTelemetryEnv -ForbiddenTelemetryOnly
    if ($kForbidden.Exit -eq 0 -or $kForbidden.Captured -or
        $kForbidden.Log -notmatch 'offline model adapter requires all of') {
        throw "Forbidden production -OfflineTelemetryPath did not reproduce the partial-adapter rejection (exit=$($kForbidden.Exit))."
    }
    # Adapter containment: a manifest pointing at a NON-pinned adapter script -> refuse.
    $wrongAdapterDir = Join-Path $runRoot 'wrong-adapter'
    New-Item -ItemType Directory -Force -Path $wrongAdapterDir | Out-Null
    $wrongAdapterScript = Join-Path $wrongAdapterDir 'Invoke-ReviewerModelAdapter.ps1'
    Copy-Item -LiteralPath $adapterReal -Destination $wrongAdapterScript -Force
    $wrongAdapterMan = New-VariantManifest -Tag 'wrongAdapter' -Behavior 'success' -AdapterScriptOverride $wrongAdapterScript
    $k4 = Invoke-ChildDirect -Label 'wrongScript' -PlanFile $kPlan -Projection $genProjection -Env @{ REVIEWER_ACQUISITION_TOKEN = ('f' * 64) } -AdapterManifest $wrongAdapterMan
    Check 'direct child with a non-pinned adapter script refuses (containment)' (($k4.Exit -ne 0) -and -not $k4.Captured) ("exit=$($k4.Exit)")
    Check 'wrong-script cites the pinned adapter' ($k4.Log -match 'pins the offline adapter') ''

    # -- Blocker C/F: HMAC plan signature + fail-closed identity, proven with a plan
    #    authored under a KNOWN strong token so a VALID token can be presented and the
    #    OTHER failure isolated. The token is >=32 chars with ample entropy; it is
    #    handed only through the scrubbed env var, never argv, never persisted.
    $knownToken = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 48 | ForEach-Object { [char]$_ })
    $kcBase = New-OutDir 'direct_knownplanbase'
    $kcMan = New-VariantManifest -Tag 'directKnownPlanBase' -Behavior 'success'
    $kc = Invoke-Tool -ToolArgs ((Get-CommonArgs -Out $kcBase -Role generalist -Projection $genProjection -Model claude-opus-5 -Manifest $kcMan) + @('-AuthorizationToken', $knownToken)) -LogName 'direct-knownplanbase.log'
    Check 'group K known-token plan-base run sealed' ($kc.Exit -eq 0) ("exit=$($kc.Exit)")
    $kcPlan = Join-Path $kcBase 'work\acquisition-plan.json'
    $kcSig = "$kcPlan.sig"
    if ((Test-Path -LiteralPath $kcPlan) -and (Test-Path -LiteralPath $kcSig)) {
        $kcPlanObj = Read-Json $kcPlan
        Check 'outer authored a plan HMAC-signature sidecar (blocker C)' (Test-Path -LiteralPath $kcSig)
        Check 'plan signature never carries the raw token' (-not ((Get-Content -LiteralPath $kcSig -Raw) -match [regex]::Escape($knownToken))) ''

        # C1 tampered-plan: flip one char of a NON-token plan field but keep the original
        # signature -> the HMAC no longer covers the plan bytes -> refuse before launch.
        $u8 = [System.Text.UTF8Encoding]::new($false, $true)
        $c1Plan = Join-Path $runRoot 'plan-tampered.json'
        $c1Text = [IO.File]::ReadAllText($kcPlan, $u8)
        $flipPid = if ([string]$kcPlanObj.planId.Substring(0, 1) -ceq 'a') { 'b' } else { 'a' }
        $c1Text = $c1Text.Replace(([string]$kcPlanObj.planId | ConvertTo-Json), (($flipPid + [string]$kcPlanObj.planId.Substring(1)) | ConvertTo-Json))
        [IO.File]::WriteAllText($c1Plan, $c1Text, $u8)
        Copy-Item -LiteralPath $kcSig -Destination "$c1Plan.sig" -Force
        $c1 = Invoke-ChildDirect -Label 'tamperedPlan' -PlanFile $c1Plan -Projection $genProjection -Env @{ REVIEWER_ACQUISITION_TOKEN = $knownToken }
        Check 'direct child with a TAMPERED plan refuses (blocker C)' (($c1.Exit -ne 0) -and -not $c1.Captured) ("exit=$($c1.Exit)")
        Check 'tampered-plan cites a tampered/replayed plan' ($c1.Log -match 'tampered or replayed') ''

        # Even a correctly re-signed plan cannot substitute the second model: the
        # child binds that authenticated field to its one configured argv value.
        $c1SecondPlan = Join-Path $runRoot 'plan-second-substituted.json'
        New-ResignedPlan -SrcPlan $kcPlan -DstPlan $c1SecondPlan -Token $knownToken `
            -Replace @(@{ Old = 'gpt-5.6-sol'; New = 'gpt-5.6-terra' })
        $c1Second = Invoke-ChildDirect -Label 'substitutedSecondModel' `
            -PlanFile $c1SecondPlan -Projection $genProjection `
            -Env @{ REVIEWER_ACQUISITION_TOKEN = $knownToken }
        Check 're-signed second-model substitution refuses before launch' (
            $c1Second.Exit -ne 0 -and -not $c1Second.Captured -and
            $c1Second.Log -match 'secondGeneralistModel binding') ("exit=$($c1Second.Exit)")

        $kcVerificationBase = New-OutDir 'direct_known_verification_planbase'
        $kcVerificationManifest = New-VariantManifest -Tag 'directKnownVerificationPlanBase' `
            -Behavior 'success'
        $kcVerification = Invoke-Tool -ToolArgs ((
                Get-CommonArgs -Out $kcVerificationBase -Role generalist `
                    -Projection $genProjection -Model claude-opus-5 `
                    -Manifest $kcVerificationManifest -Config $verificationConfigFile) +
            @('-AuthorizationToken', $knownToken)) -LogName 'direct-known-verification-planbase.log'
        Check 'known-token verification plan-base run sealed' (
            $kcVerification.Exit -eq 0) "exit=$($kcVerification.Exit)"
        $kcVerificationPlan = Join-Path $kcVerificationBase 'work\acquisition-plan.json'
        $tamperedSpecialistPlan = Join-Path $runRoot 'plan-specialist-tampered.json'
        $tamperedSpecialistText = [IO.File]::ReadAllText($kcVerificationPlan, $u8).
            Replace('"claude-sonnet-5"', '"claude-haiku-4.5"')
        [IO.File]::WriteAllText($tamperedSpecialistPlan, $tamperedSpecialistText, $u8)
        Copy-Item -LiteralPath "$kcVerificationPlan.sig" `
            -Destination "$tamperedSpecialistPlan.sig" -Force
        $tamperedSpecialist = Invoke-ChildDirect -Label 'tamperedSpecialistPlan' `
            -PlanFile $tamperedSpecialistPlan -Projection $genProjection `
            -Config $verificationConfigFile -EnableSpecialist `
            -SpecialistModel 'claude-sonnet-5' `
            -Env @{ REVIEWER_ACQUISITION_TOKEN = $knownToken }
        Check 'specialist-model plan tamper is HMAC-refused before launch' (
            $tamperedSpecialist.Exit -ne 0 -and -not $tamperedSpecialist.Captured -and
            $tamperedSpecialist.Log -match 'tampered or replayed') (
            "exit=$($tamperedSpecialist.Exit)")

        $mismatchedSpecialist = Invoke-ChildDirect -Label 'mismatchedSpecialistArgv' `
            -PlanFile $kcVerificationPlan -Projection $genProjection `
            -Config $verificationConfigFile -EnableSpecialist `
            -SpecialistModel 'claude-haiku-4.5' `
            -Env @{ REVIEWER_ACQUISITION_TOKEN = $knownToken }
        Check 'supported specialist argv/plan mismatch refuses before launch' (
            $mismatchedSpecialist.Exit -ne 0 -and
            -not $mismatchedSpecialist.Captured -and
            $mismatchedSpecialist.ModelStarts -eq 0 -and
            $mismatchedSpecialist.Log -match 'effective convention specialist model') (
            "exit=$($mismatchedSpecialist.Exit)")

        # C2 wrong-root / replay into a different context: present the VALID token + the
        # authentic plan + its real signature, but an output root that is NOT the plan's
        # bound package directory -> token + HMAC pass, the identity binding fails closed.
        $c2 = Invoke-ChildDirect -Label 'wrongRoot' -PlanFile $kcPlan -Projection $genProjection -Env @{ REVIEWER_ACQUISITION_TOKEN = $knownToken }
        Check 'direct child with a WRONG output root refuses (blocker C)' (($c2.Exit -ne 0) -and -not $c2.Captured) ("exit=$($c2.Exit)")
        Check 'wrong-root cites the bound package directory' ($c2.Log -match 'bound package directory') ''

        # C3 non-git RepoPath (blocker F): re-sign an authentic plan whose repoPath and
        # outputRoot are a NON-git directory, then present the matching token + RepoPath +
        # output root so token / HMAC / identity all pass, and prove the child fails CLOSED
        # on git HEAD resolution rather than silently skipping the ref/HEAD identity.
        $nonGit = Join-Path $runRoot 'nongit-repo'; New-Item -ItemType Directory -Force -Path $nonGit | Out-Null
        # A brand-new directory INSIDE the worktree would let git walk UP to the
        # enclosing repository and resolve the real HEAD, masking the fail-closed
        # path. Plant a .git gitfile pointing at a non-existent gitdir so git treats
        # this as a (broken) repository boundary: `git -C <dir> rev-parse HEAD` then
        # exits non-zero instead of ascending, exercising the blocker-F throw.
        Set-Content -LiteralPath (Join-Path $nonGit '.git') -Value ('gitdir: ' + (Join-Path $runRoot 'no-such-gitdir')) -NoNewline -Encoding ascii
        $ngRoot = Join-Path $runRoot 'nongit-out'; New-Item -ItemType Directory -Force -Path $ngRoot | Out-Null
        $ngPkg = Join-Path $ngRoot 'package'; New-Item -ItemType Directory -Force -Path $ngPkg | Out-Null
        $c3Plan = Join-Path $runRoot 'plan-nongit.json'
        New-ResignedPlan -SrcPlan $kcPlan -DstPlan $c3Plan -Token $knownToken -Replace @(
            @{ Old = [string]$kcPlanObj.repoPath; New = (Resolve-Path -LiteralPath $nonGit).Path },
            @{ Old = [string]$kcPlanObj.outputRoot; New = (Resolve-Path -LiteralPath $ngRoot).Path }
        )
        $c3 = Invoke-ChildDirect -Label 'nonGitRepo' -PlanFile $c3Plan -Projection $genProjection -Env @{ REVIEWER_ACQUISITION_TOKEN = $knownToken } -RepoPathOverride $nonGit -OutputRootOverride $ngPkg
        Check 'direct child with a NON-git RepoPath fails closed (blocker F)' (($c3.Exit -ne 0) -and -not $c3.Captured) ("exit=$($c3.Exit)")
        Check 'non-git cites fail-closed HEAD resolution' ($c3.Log -match 'fails closed on HEAD resolution') ''

        # C4 one-shot lease (blocker C anti-replay): a genuine plan presented with its
        # valid token + signature + correct output root passes the gate and CAPTURES
        # (the accept path of the constant-time signature check); re-presenting the SAME
        # plan in the SAME child state refuses at the atomic one-shot plan lease.
        $kcPkg = Join-Path $kcBase 'package'
        Get-ChildItem -LiteralPath $kcPkg -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Attributes = 'Normal' } catch { } }
        Remove-Item -LiteralPath $kcPkg -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path $kcPkg | Out-Null
        $replaySt = Join-Path $runRoot 'directstate_replay'
        $c4a = Invoke-ChildDirect -Label 'replayFirst' -PlanFile $kcPlan -Projection $genProjection -Env @{ REVIEWER_ACQUISITION_TOKEN = $knownToken } -OutputRootOverride $kcPkg -StateDirOverride $replaySt
        Check 'direct child with a valid signed plan captures (blocker C accept path)' (($c4a.Exit -eq 0) -and $c4a.Captured) ("exit=$($c4a.Exit)")
        $c4b = Invoke-ChildDirect -Label 'replaySecond' -PlanFile $kcPlan -Projection $genProjection -Env @{ REVIEWER_ACQUISITION_TOKEN = $knownToken } -OutputRootOverride $kcPkg -StateDirOverride $replaySt
        Check 'direct child replay of the same plan refuses at the one-shot lease (blocker C)' ($c4b.Exit -ne 0) ("exit=$($c4b.Exit)")
        Check 'replay cites a consumed plan' ($c4b.Log -match 'already been consumed') ''
    }
    else { Check 'group K known-token prerequisite plan + signature exist' $false "missing $kcPlan(.sig)" }
}

# ---------------------------------------------------------------------------
# Group L - Truly concurrent, differing-input runs race for the SAME output
#           root. The atomic CreateNew launch lease guarantees exactly one
#           winner seals a package and the loser mutates nothing (blocker 5).
# ---------------------------------------------------------------------------
Write-Host "`n== Group L: concurrent differing-input lease ==" -ForegroundColor Cyan
$lOut = New-OutDir 'concurrent_lease'
Remove-Tree $lOut   # must NOT pre-create: the lease is the first output-root mutation
$lManA = New-VariantManifest -Tag 'concA' -Behavior 'success' -RoleName 'blind-opus'
$lManB = New-VariantManifest -Tag 'concB' -Behavior 'success' -RoleName 'blind-gpt'
$argsA = Get-CommonArgs -Out $lOut -Role generalist -Projection $genProjection -Model claude-opus-5 -Manifest $lManA
$argsB = Get-CommonArgs -Out $lOut -Role generalist -Projection $genProjection -Model gpt-5.6-sol -Manifest $lManB
$jobBlock = { param($t, $a, $l) & pwsh -NoProfile -File $t @a *> $l; $LASTEXITCODE }
$jobA = Start-Job -ScriptBlock $jobBlock -ArgumentList $tool, $argsA, (Join-Path $logDir 'concurrent-A.log')
$jobB = Start-Job -ScriptBlock $jobBlock -ArgumentList $tool, $argsB, (Join-Path $logDir 'concurrent-B.log')
$null = Wait-Job -Job $jobA, $jobB -Timeout 180
$exA = [int](@(Receive-Job $jobA) | Select-Object -Last 1)
$exB = [int](@(Receive-Job $jobB) | Select-Object -Last 1)
Remove-Job $jobA, $jobB -Force
$sealed = @(Get-ChildItem -LiteralPath $lOut -Recurse -File -Filter 'transcript-package.json' -ErrorAction SilentlyContinue)
Check 'concurrent: exactly one sealed transcript package' ($sealed.Count -eq 1) ("sealed=$($sealed.Count) exitA=$exA exitB=$exB")
Check 'concurrent: at least one run refused (lease loser)' ($exA -ne 0 -or $exB -ne 0) ("exitA=$exA exitB=$exB")
Check 'concurrent: at least one run won (sealed, exit 0)' ($exA -eq 0 -or $exB -eq 0) ("exitA=$exA exitB=$exB")
if ($sealed.Count -eq 1) {
    $cv = Invoke-Tool -ToolArgs @('-VerifyOnly', '-OutputRoot', $lOut, '-SealKeyPath', $sealKey) -LogName 'concurrent-verify.log'
    Check 'concurrent: winner package self-verifies intact' ($cv.Exit -eq 0) ("exit=$($cv.Exit)")
}

# ---------------------------------------------------------------------------
# Group M - Recursive evidence integrity: nested-file injection, TRUE cross-
#           substitution from a separate valid package, and tamper of the
#           HMAC-authenticated terminal evidence for BOTH timeout and crash.
#           Every terminal artifact must additionally be read-only (blocker 6).
# ---------------------------------------------------------------------------
Write-Host "`n== Group M: recursive evidence integrity ==" -ForegroundColor Cyan
function Copy-PackageFrom {
    param([string]$SrcPackageDir, [string]$Name)
    $dst = New-OutDir $Name; Remove-Tree $dst
    $dstPkg = Join-Path $dst 'package'; New-Item -ItemType Directory -Force -Path $dstPkg | Out-Null
    foreach ($f in @(Get-ChildItem -LiteralPath $SrcPackageDir -Recurse -File)) {
        $rel = [IO.Path]::GetRelativePath($SrcPackageDir, $f.FullName)
        $t = Join-Path $dstPkg $rel
        New-Item -ItemType Directory -Force -Path (Split-Path $t -Parent) | Out-Null
        Copy-Item -LiteralPath $f.FullName -Destination $t -Force
        (Get-Item -LiteralPath $t).Attributes = 'Normal'
    }
    return $dst
}

# Assert that a terminal-evidence package rejects BOTH a seal tamper and a nested
# unbound-file injection. The manifest tamper appends a byte so the manifest still
# parses (no verifier crash) but its canonical text + SHA-256/HMAC seal no longer
# match; the injection proves the recursive inventory rejects unbound files.
function Test-TerminalEvidenceTamper {
    param([string]$SrcPackageDir, [string]$Name)
    $c1 = Copy-PackageFrom -SrcPackageDir $SrcPackageDir -Name ($Name + '_seal')
    $mf = Join-Path $c1 'package\terminal-evidence.json'
    [IO.File]::WriteAllBytes($mf, ([IO.File]::ReadAllBytes($mf) + [byte]0x20))
    $r1 = Invoke-Tool -ToolArgs @('-VerifyOnly', '-OutputRoot', $c1, '-SealKeyPath', $sealKey) -LogName ($Name + '-seal-tamper.log')
    Check "$Name terminal-evidence seal tamper -> exit 2" ($r1.Exit -eq 2) ("exit=$($r1.Exit)")
    $c2 = Copy-PackageFrom -SrcPackageDir $SrcPackageDir -Name ($Name + '_inject')
    New-Item -ItemType Directory -Force -Path (Join-Path $c2 'package\nested') | Out-Null
    Set-Content -LiteralPath (Join-Path $c2 'package\nested\x.txt') -Value 'nested injection' -Encoding UTF8
    $r2 = Invoke-Tool -ToolArgs @('-VerifyOnly', '-OutputRoot', $c2, '-SealKeyPath', $sealKey) -LogName ($Name + '-inject.log')
    Check "$Name terminal-evidence nested injection -> exit 2" ($r2.Exit -eq 2) ("exit=$($r2.Exit)")
}

# M1 - a nested unbound file injected into a copied success package is rejected.
$nestOut = Copy-Package 'evidence_nested'
New-Item -ItemType Directory -Force -Path (Join-Path $nestOut 'package\nested') | Out-Null
Set-Content -LiteralPath (Join-Path $nestOut 'package\nested\x.txt') -Value 'nested injection' -Encoding UTF8
$nv = Invoke-Tool -ToolArgs @('-VerifyOnly', '-OutputRoot', $nestOut, '-SealKeyPath', $sealKey) -LogName 'evidence-nested.log'
Check 'nested-file injection -> exit 2' ($nv.Exit -eq 2) ("exit=$($nv.Exit)")

# M2 - TRUE cross-substitution: swap a bound file's content for the same-named
#      file from a SEPARATE valid sealed package (individually valid, wrong hash).
$gptCore = Join-Path (New-OutDir 'beh_successGpt') 'package\capture-core.json'
if (Test-Path -LiteralPath $gptCore) {
    $xsubOut = Copy-Package 'evidence_xsub'
    Copy-Item -LiteralPath $gptCore -Destination (Join-Path $xsubOut 'package\capture-core.json') -Force
    (Get-Item -LiteralPath (Join-Path $xsubOut 'package\capture-core.json')).Attributes = 'Normal'
    $xv = Invoke-Tool -ToolArgs @('-VerifyOnly', '-OutputRoot', $xsubOut, '-SealKeyPath', $sealKey) -LogName 'evidence-xsub.log'
    Check 'cross-substitution from a separate valid package -> exit 2' ($xv.Exit -eq 2) ("exit=$($xv.Exit)")
}
else { Check 'cross-substitution prerequisite (beh_successGpt) present' $false 'missing gpt package' }

# M3 - the HMAC-authenticated TIMEOUT terminal evidence rejects seal tamper and
#      nested injection; every timeout artifact is read-only.
$toPkgDir = Join-Path (New-OutDir 'beh_timeout') 'package'
if (Test-Path -LiteralPath (Join-Path $toPkgDir 'terminal-evidence.json')) {
    $toRo = @(Get-ChildItem -LiteralPath $toPkgDir -File -Recurse -Force | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReadOnly) })
    Check 'timeout terminal artifacts are read-only' ($toRo.Count -eq 0) ("writable=$($toRo.Count)")
    Test-TerminalEvidenceTamper -SrcPackageDir $toPkgDir -Name 'timeout'
}
else { Check 'timeout terminal-evidence prerequisite present' $false 'missing timeout evidence' }

# M4 - the HMAC-authenticated CRASH terminal evidence rejects seal tamper and
#      nested injection. The wrong-snapshot child (Group B) crashes at replay
#      load, so the outer writes crash terminal evidence.
$crPkgDir = Join-Path (New-OutDir 'child_wrongSnapshot') 'package'
$crEvidence = Join-Path $crPkgDir 'terminal-evidence.json'
if (Test-Path -LiteralPath $crEvidence) {
    $crRo = @(Get-ChildItem -LiteralPath $crPkgDir -File -Recurse -Force | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReadOnly) })
    Check 'crash terminal artifacts are read-only' ($crRo.Count -eq 0) ("writable=$($crRo.Count)")
    Test-TerminalEvidenceTamper -SrcPackageDir $crPkgDir -Name 'crash'
    $ce = Read-Json $crEvidence
    Check 'crash terminal evidence records a crash status' ([string]$ce.terminalStatus -eq 'crash') ("got=$([string]$ce.terminalStatus)")
}
else { Check 'crash terminal-evidence prerequisite present' $false 'missing crash evidence' }

# ---------------------------------------------------------------------------
# Group N - Ref identity: a full ref that EXISTS but resolves to a commit other
#           than HEAD (valid-but-wrong ref) is refused (blocker 7).
# ---------------------------------------------------------------------------
Write-Host "`n== Group N: valid-but-wrong ref ==" -ForegroundColor Cyan
if ($script:WrongRef) {
    $nOut = New-OutDir 'wrong_ref_valid'
    $nMan = New-VariantManifest -Tag 'wrongRefValid' -Behavior 'success'
    $nArgs = @(
        '-Role', 'generalist', '-FixtureProjectionFile', $genProjection, '-Model', 'claude-opus-5',
        '-ConfigFile', $configFile, '-ReplayRoot', $replayRoot,
        '-ReplaySnapshotName', 'synthetic-pr', '-ReplayManifestDigest', $digest,
        '-OfflineModelAdapterManifest', $nMan, '-ExpectedReviewerBaseCommit', $expectedBase,
        '-PullRequestId', '4242', '-ExpectedHeadCommit', $head, '-ExpectedRef', $script:WrongRef,
        '-OutputRoot', $nOut, '-SealKeyPath', $sealKey, '-AllowDirtyWorktree', '-UseOfflineStubAdapter',
        '-PerCallTimeoutSeconds', '30', '-TotalTimeoutSeconds', '90', '-ActivityTimeoutSeconds', '30'
    )
    $n = Invoke-Tool -ToolArgs $nArgs -LogName 'wrong-ref-valid.log'
    Check 'valid-but-wrong ref (resolves to non-HEAD) is refused' (($n.Exit -ne 0) -and -not (Test-Path -LiteralPath (Join-Path $nOut 'package\transcript-package.json'))) ("exit=$($n.Exit)")
}
else {
    Write-Host '  [SKIP] no parent commit available to materialize a valid-but-wrong ref' -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Group O - An authenticated specialist convention package is an independent
#           discovery source for either generalist verifier. The specialist
#           itself remains ineligible as a verifier, and every role/model/
#           fixture/snapshot/candidate provenance mismatch fails before launch.
# ---------------------------------------------------------------------------
Write-Host "`n== Group O: specialist-origin verifier acquisition ==" -ForegroundColor Cyan
$spPackage = $specialistPackage
$spCandidate = $specialistCandidate
Check 'specialist-origin rejection matrix has an authenticated source package and candidate' (
    (Test-Path -LiteralPath (Join-Path $spPackage 'transcript-package.json')) -and
    (Test-Path -LiteralPath $spCandidate))
if (Test-Path -LiteralPath $spCandidate) {
    $snapshotPackage = Join-Path $runRoot 'specialist-byte-snapshot-package'
    Copy-Item -LiteralPath $spPackage -Destination $snapshotPackage -Recurse -Force
    $verifiedByteSnapshot = Assert-ReviewerAcquisitionTranscriptPackage `
        -PackageRoot $snapshotPackage -SealKeyPath $sealKey `
        -SchemaPath (Join-Path $RepoRoot 'src\Agents\reviewer\acquisition\v1\transcript-package.schema.json') `
        -RequireCaptured
    $testUtf8 = [Text.UTF8Encoding]::new($false, $true)
    $mutableSnapshotMarker = Join-Path $snapshotPackage 'result-marker.txt'
    (Get-Item -LiteralPath $mutableSnapshotMarker -Force).Attributes = [IO.FileAttributes]::Normal
    [IO.File]::WriteAllText($mutableSnapshotMarker, 'post-verification replacement', $testUtf8)
    Check 'authenticated package verifier retains the exact verified marker bytes after source mutation' (
        [string]$verifiedByteSnapshot.MarkerText -cne
            [IO.File]::ReadAllText($mutableSnapshotMarker, $testUtf8) -and
        (Get-ReviewerAcquisitionPackageBytesSha256 -Bytes ([byte[]]$verifiedByteSnapshot.MarkerBytes)) -ceq
            [string]$verifiedByteSnapshot.MarkerSha256)
    $acquisitionToolText = [IO.File]::ReadAllText($tool, $testUtf8)
    $captureToolText = [IO.File]::ReadAllText(
        (Join-Path $PSScriptRoot 'Invoke-ReviewerRoleInputCapture.ps1'), $testUtf8)
    Check 'verifier supervisors stage authenticated bytes instead of reopening package payload paths' (
        $acquisitionToolText -match 'discoveryPackage\.MarkerBytes' -and
        $acquisitionToolText -notmatch 'ReadAllText\(\$discoveryMarkerPath' -and
        $captureToolText -match 'discoveryPackage\.MarkerBytes' -and
        $captureToolText -notmatch 'ReadAllText\(\[string\]\$discoveryPackage\.MarkerPath')

    $spCandidateJson = Read-Json $spCandidate
    Check 'specialist candidate binds the configured specialist model and role' (
        [string]$spCandidateJson.sourceRole -ceq 'specialist' -and
        [string]$spCandidateJson.sourceModel -ceq 'claude-sonnet-5')
    Check 'every specialist-origin candidate is a convention candidate' (
        @($spCandidateJson.candidates).Count -gt 0 -and
        @($spCandidateJson.candidates | Where-Object {
                [string]$_.originKind -cne 'convention' -or
                [string]$_.originModel -cne [string]$spCandidateJson.sourceModel
            }).Count -eq 0)

    foreach ($target in @('gpt-5.6-sol', 'claude-opus-5')) {
        $roleName = if ($target -ceq 'gpt-5.6-sol') {
            'reciprocal-gpt-verifier'
        } else {
            'reciprocal-opus-verifier'
        }
        $targetOut = New-OutDir ("specialist_to_" + $roleName)
        $targetManifest = New-VariantManifest -Tag ("specialistTo" + $roleName) -Behavior 'success' -RoleName $roleName
        $targetRun = Invoke-Tool -ToolArgs (Get-VerifierArgs -Out $targetOut -Manifest $targetManifest `
                -DiscoveryPackage $spPackage -Candidate $spCandidate -Model $target -UseConventionSnapshot) `
            -LogName ("specialist-to-" + $roleName + '.log')
        Check "specialist package can seed a fresh $target verifier" (
            ($targetRun.Exit -eq 0) -and
            (Test-Path -LiteralPath (Join-Path $targetOut 'package\transcript-package.json'))) `
            ("exit=$($targetRun.Exit)")
    }

    $spWrongRole = Copy-MutatedCandidate -Source $spCandidate -Name 'specialist-wrong-role.json' -Mutation {
        param($c) $c.sourceRole = 'generalist'
    }
    $spWrongProvenance = Copy-MutatedCandidate -Source $spCandidate -Name 'specialist-wrong-provenance.json' -Mutation {
        param($c) $c.candidates[0].originKind = 'generalist'
    }
    $spWrongHash = Copy-MutatedCandidate -Source $spCandidate -Name 'specialist-wrong-hash.json' -Mutation {
        param($c) $c.candidates[0].candidateHash = ('0' * 64)
    }
    $spWrongFixture = Copy-MutatedCandidate -Source $spCandidate -Name 'specialist-wrong-fixture.json' -Mutation {
        param($c) $c.sourceFixtureId = 'fabricated-specialist-fixture'
    }
    $spStalePackage = Copy-ResealedPackageWithStaleScript -SourcePackage $spPackage
    $spStaleCandidate = Join-Path $runRoot 'specialist-stale-script-candidate.json'
    & pwsh -NoProfile -File $extractTool -DiscoveryPackageRoot $spStalePackage -SealKeyPath $sealKey `
        -ExpectedSourceScriptSha256 ('0' * 64) -OutputFile $spStaleCandidate `
        *> (Join-Path $logDir 'specialist-stale-script-extract.log')
    Check 'authenticated stale-script specialist package can be independently decoded for gate testing' (
        ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $spStaleCandidate))
    $specialistRejects = @(
        @{ Name = 'wrong specialist candidate role'; Candidate = $spWrongRole; SpecialistModel = 'claude-sonnet-5'; Convention = $true; Target = 'gpt-5.6-sol' },
        @{ Name = 'wrong specialist candidate provenance'; Candidate = $spWrongProvenance; SpecialistModel = 'claude-sonnet-5'; Convention = $true; Target = 'gpt-5.6-sol' },
        @{ Name = 'fabricated specialist candidate hash'; Candidate = $spWrongHash; SpecialistModel = 'claude-sonnet-5'; Convention = $true; Target = 'gpt-5.6-sol' },
        @{ Name = 'cross-fixture specialist candidate'; Candidate = $spWrongFixture; SpecialistModel = 'claude-sonnet-5'; Convention = $true; Target = 'gpt-5.6-sol' },
        @{ Name = 'wrong configured specialist model'; Candidate = $spCandidate; SpecialistModel = 'gpt-5.4'; Convention = $true; Target = 'gpt-5.6-sol' },
        @{ Name = 'cross-snapshot specialist package'; Candidate = $spCandidate; SpecialistModel = 'claude-sonnet-5'; Convention = $false; Target = 'gpt-5.6-sol' },
        @{ Name = 'specialist target verifier'; Candidate = $spCandidate; SpecialistModel = 'claude-sonnet-5'; Convention = $true; Target = 'claude-sonnet-5' }
    )
    foreach ($case in $specialistRejects) {
        $caseOut = New-OutDir ('reject_' + ([regex]::Replace([string]$case.Name, '[^a-zA-Z0-9]+', '_')))
        $caseManifest = New-VariantManifest -Tag ([regex]::Replace([string]$case.Name, '[^a-zA-Z0-9]+', '')) `
            -Behavior 'success' -RoleName 'reciprocal-gpt-verifier'
        $caseArgs = Get-VerifierArgs -Out $caseOut -Manifest $caseManifest -DiscoveryPackage $spPackage `
            -Candidate ([string]$case.Candidate) -Model ([string]$case.Target) `
            -SpecialistModel ([string]$case.SpecialistModel)
        if ([bool]$case.Convention) { $caseArgs += '-UseConventionSnapshot' }
        $caseRun = Invoke-Tool -ToolArgs $caseArgs -LogName (
            'reject-' + ([regex]::Replace([string]$case.Name, '[^a-zA-Z0-9]+', '-')) + '.log')
        Check "$($case.Name) is refused before a verifier capture" (
            ($caseRun.Exit -ne 0) -and
            -not (Test-Path -LiteralPath (Join-Path $caseOut 'package\transcript-package.json'))) `
            ("exit=$($caseRun.Exit)")
    }
    if (Test-Path -LiteralPath $spStaleCandidate) {
        $staleOut = New-OutDir 'reject_specialist_stale_script'
        $staleManifest = New-VariantManifest -Tag 'specialistStaleScript' -Behavior 'success' `
            -RoleName 'reciprocal-gpt-verifier'
        $staleRun = Invoke-Tool -ToolArgs (Get-VerifierArgs -Out $staleOut -Manifest $staleManifest `
                -DiscoveryPackage $spStalePackage -Candidate $spStaleCandidate -Model 'gpt-5.6-sol' `
                -UseConventionSnapshot) -LogName 'reject-specialist-stale-script.log'
        Check 'stale reviewer-script identity in an authenticated specialist package is refused' (
            ($staleRun.Exit -ne 0) -and
            -not (Test-Path -LiteralPath (Join-Path $staleOut 'package\transcript-package.json'))) `
            ("exit=$($staleRun.Exit)")
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
$failed = @($script:Results | Where-Object { -not $_.Ok })
$passCount = $script:Results.Count - $failed.Count
$sumColor = if ($failed.Count -eq 0) { 'Green' } else { 'Red' }
Write-Host ("`n================ {0}/{1} checks passed ================" -f $passCount, $script:Results.Count) -ForegroundColor $sumColor
if ($failed.Count -gt 0) {
    Write-Host 'Failed checks:' -ForegroundColor Red
    foreach ($f in $failed) { Write-Host ("  - {0} {1}" -f $f.Name, $f.Detail) -ForegroundColor Red }
}

if ($failed.Count -eq 0) {
    Remove-Tree $runRoot
}
else {
    Write-Host "Preserved failed-run evidence: $runRoot" -ForegroundColor Yellow
}
# Delete any throwaway refs materialized for the ref-identity tests.
Push-Location $RepoRoot
try {
    if ($script:TempRef) { & git update-ref -d $script:TempRef 2>$null | Out-Null }
    if ($script:WrongRef) { & git update-ref -d $script:WrongRef 2>$null | Out-Null }
}
finally { Pop-Location }
if ($failed.Count -gt 0) { exit 1 } else { exit 0 }
