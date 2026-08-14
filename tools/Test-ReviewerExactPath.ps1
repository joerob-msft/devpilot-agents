#!/usr/bin/env pwsh
[CmdletBinding()]
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$reviewer = Join-Path $RepoRoot 'src\Agents\reviewer\Start-ReviewerAgent.ps1'
$fixtureRoot = Join-Path $RepoRoot 'src\Agents\reviewer\testdata\exact-path'
$replayRoot = Join-Path $RepoRoot 'src\Agents\reviewer\testdata\replay-v1'
$adapterManifest = Join-Path $fixtureRoot 'adapter-manifest.json'
$oracle = Get-Content (Join-Path $fixtureRoot 'expected-oracle.json') -Raw | ConvertFrom-Json
$digest = [string]((Get-Content (Join-Path $replayRoot 'synthetic-pr\manifest.json') -Raw | ConvertFrom-Json).manifestDigest)
$expectedBase = [string]((Get-Content $adapterManifest -Raw | ConvertFrom-Json).expectedBaseCommit)

function Invoke-ExactPathRun {
    $sandbox = Join-Path ([IO.Path]::GetTempPath()) ('reviewer-exact-' + [Guid]::NewGuid().ToString('N'))
    $configDir = Join-Path $sandbox 'config'
    $stateDir = Join-Path $sandbox 'state'
    New-Item -ItemType Directory -Path $configDir, $stateDir -Force | Out-Null
    Copy-Item (Join-Path $fixtureRoot 'reviewer.config.json') (Join-Path $configDir 'reviewer.config.json')
    Copy-Item (Join-Path $RepoRoot 'src\Agents\reviewer\review-cycle.prompt.md') (Join-Path $configDir 'review-cycle.prompt.md')
    $output = & pwsh -NoProfile -File $reviewer -Once -RepoPath $RepoRoot `
        -ConfigFile (Join-Path $configDir 'reviewer.config.json') -StateDir $stateDir `
        -OperatorAlias fixture-operator -PullRequestId 4242 `
        -Model claude-opus-5 -SecondPassModel gpt-5.6-sol `
        -EnableConventionSpecialist -ConventionSpecialistModel claude-sonnet-5 `
        -EnableVerificationPreview -ConventionVerifierModel claude-opus-5 `
        -CycleTimeoutSeconds 30 -ConventionSpecialistTimeoutSeconds 30 -VerificationTimeoutSeconds 30 `
        -ReplayRoot $replayRoot -ReplaySnapshotName synthetic-pr -ReplayManifestDigest $digest `
        -EnableOfflineModelAdapter -OfflineModelAdapterManifest $adapterManifest `
        -ExpectedReviewerBaseCommit $expectedBase 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Exact-path reviewer failed: $($output -join [Environment]::NewLine)" }

    $runRoot = Join-Path $stateDir 'replay\synthetic-pr'
    $preview = Get-ChildItem (Join-Path $runRoot 'previews') -Filter *.json -File -ErrorAction Stop
    $specialist = Get-ChildItem (Join-Path $runRoot 'convention-specialist-previews') -Filter *.json -File -ErrorAction Stop
    $verification = Get-ChildItem (Join-Path $runRoot 'verification-previews') -Filter *.json -File -ErrorAction Stop
    if (@($preview).Count -ne 1 -or @($specialist).Count -ne 1 -or @($verification).Count -ne 1) {
        throw 'Exact-path run did not persist exactly one typed artifact for every terminal stage.'
    }
    $previewEnvelope = Get-Content $preview.FullName -Raw | ConvertFrom-Json
    $review = $previewEnvelope.manifestJson | ConvertFrom-Json -Depth 64
    $specialistResult = (Get-Content $specialist.FullName -Raw | ConvertFrom-Json).manifestJson | ConvertFrom-Json -Depth 64
    $verificationResult = (Get-Content $verification.FullName -Raw | ConvertFrom-Json).manifestJson | ConvertFrom-Json -Depth 64
    return [ordered]@{
        generalistPassesComplete = [int]$review.passesCompleted
        rawFindingCount = [int]$review.reportedFindings
        specialistStatus = [string]$specialistResult.status
        specialistCandidateCount = @($specialistResult.candidates).Count
        reciprocalAssignmentCount = @($verificationResult.assignments).Count
        verificationStatus = [string]$verificationResult.status
        eligibleCandidateCount = @($verificationResult.eligiblePreviewCandidates).Count
        deliveryMode = if (-not [bool]$previewEnvelope.replay.promotable -and
            @($output | Where-Object { [string]$_ -match '^Writes: NONE\.' }).Count -eq 1) {
            'shadow-only'
        } else { 'unexpected' }
        externalWrites = @(Get-ChildItem $runRoot -Recurse -File |
                Where-Object { $_.Name -match '(?i)(delivery|post|vote).*(receipt|result)' }).Count
        realModelLaunches = @($output | Where-Object {
                [string]$_ -match '(?i)(starting|launching)\s+(agency|copilot cli)'
            }).Count
    }
}

$first = Invoke-ExactPathRun
$second = Invoke-ExactPathRun
$firstJson = ConvertTo-Json $first -Compress
$secondJson = ConvertTo-Json $second -Compress
if ($firstJson -cne $secondJson) { throw 'Repeated exact-path runs produced different normalized semantic decisions.' }
foreach ($property in $oracle.expected.PSObject.Properties) {
    if ($first[$property.Name] -cne $property.Value) {
        throw "Oracle mismatch for '$($property.Name)': actual '$($first[$property.Name])', expected '$($property.Value)'."
    }
}
Write-Host "PASS: exact production replay reached deterministic shadow delivery through blind, specialist, reciprocal, and reconciliation stages."
