#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Extracts the independently captured discovery candidate a verifier acquisition
    consumes, projecting it SOLELY from a sealed generalist or specialist discovery
    transcript
    package through the EXACT production candidate-extraction and clustering path.

.DESCRIPTION
    A verifier blinded acquisition may NEVER derive its candidate from truth, from a
    co-run discovery pass, or from any expected answer. It consumes exactly one
    artifact: a candidate set that was extracted from a SEPARATE, already-sealed
    generalist or convention-specialist discovery capture.

    This is the operator-facing extraction step that produces that artifact. It reads
    ONLY the sealed discovery package's own result marker, parses it with the exact
    production CLI-envelope reader and result-marker prefix, and runs the production
    ConvertTo-ReviewerVerificationCandidates / Get-ReviewerVerificationClusters
    functions over the single discovery pass. The emitted candidate carries the exact
    source fixture, source model, result-marker binding, cluster id and per-candidate
    hashes the sealed discovery marker produces - the same values the acquisition
    child re-derives and requires to match before it will launch. Nothing here reads
    an oracle, an expected decision, or the fixture being verified.

    The output is a schema-valid reviewer-discovery-candidate-input document. No model,
    network, provider, ADO or GitHub call is made.

.PARAMETER DiscoveryPackageRoot
    The sealed generalist discovery transcript package directory (the one whose
    capture-core.json role is 'generalist' and terminalStatus is 'captured').

.PARAMETER OutputFile
    Path the extracted candidate JSON is written to (UTF-8, no BOM).

.PARAMETER SealKeyPath
    HMAC key used to authenticate the immutable acquisition transcript package.

.PARAMETER SourceFixtureId
    OPTIONAL cross-check only. The candidate's sourceFixtureId is DERIVED from the
    sealed discovery package's own capture-core evidence (its fixtureId), never from
    operator input. When supplied, this value is asserted to equal the package's
    sealed fixtureId and is otherwise ignored, so an operator can confirm - but never
    assert - which fixture the sealed discovery ran against.

.PARAMETER RepoRoot
    Repository root (defaults to this script's parent's parent).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DiscoveryPackageRoot,
    [Parameter(Mandatory)][string]$OutputFile,
    [Parameter(Mandatory)][string]$SealKeyPath,
    [ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ExpectedSourceScriptSha256,
    [string]$SourceFixtureId,
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Utf8 = [System.Text.UTF8Encoding]::new($false, $true)

# Load the EXACT production candidate-extraction / clustering functions and the
# shared CLI-envelope reader. CrossVerification.ps1 is self-contained (it defines
# its own script-scoped limits), so dot-sourcing it standalone is faithful.
Import-Module (Join-Path $RepoRoot 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psm1') -Force -DisableNameChecking
. (Join-Path $RepoRoot 'src\Agents\reviewer\SourceTransport.ps1')
. (Join-Path $RepoRoot 'src\Agents\reviewer\ConventionSpecialist.ps1')
. (Join-Path $RepoRoot 'src\Agents\reviewer\CrossVerification.ps1')
. (Join-Path $RepoRoot 'src\Agents\reviewer\AcquisitionPackage.ps1')

$package = Assert-ReviewerAcquisitionTranscriptPackage -PackageRoot $DiscoveryPackageRoot `
    -SealKeyPath $SealKeyPath `
    -SchemaPath (Join-Path $RepoRoot 'src\Agents\reviewer\acquisition\v1\transcript-package.schema.json') `
    -RequireCaptured
$pkg = [string]$package.Root
$core = $package.Core
$sourceRole = [string]$core.role
if ($sourceRole -notin @('generalist', 'specialist')) {
    throw "The discovery package is a '$sourceRole' capture; candidate extraction requires an independent generalist or specialist discovery capture."
}
$sourceModel = [string]$core.requestedModel
$markerPrefix = [string]$core.resultMarkerPrefix
if (-not $sourceModel -or -not $markerPrefix) {
    throw "The discovery capture-core is missing its requestedModel or resultMarkerPrefix binding."
}
if (-not $PSBoundParameters.ContainsKey('ExpectedSourceScriptSha256')) {
    $ExpectedSourceScriptSha256 = (Get-FileHash -LiteralPath (
            Join-Path $RepoRoot 'src\Agents\reviewer\Start-ReviewerAgent.ps1'
        ) -Algorithm SHA256).Hash.ToLowerInvariant()
}
if (([string]$core.digests.scriptSha256).ToLowerInvariant() -cne
    $ExpectedSourceScriptSha256.ToLowerInvariant()) {
    throw "The authenticated discovery package does not match the explicitly pinned source reviewer script."
}
# The candidate's source fixture is DERIVED from the sealed discovery package's own
# capture-core evidence (blocker 1), never from operator input. A package that does
# not carry its sealed fixtureId cannot seed a provable candidate.
$packageFixtureId = [string]$(if ($core.PSObject.Properties['fixtureId']) { $core.fixtureId } else { '' })
if ([string]::IsNullOrWhiteSpace($packageFixtureId)) {
    throw "The sealed discovery capture-core is missing its fixtureId; the candidate source fixture cannot be proven from the package."
}
if ($PSBoundParameters.ContainsKey('SourceFixtureId') -and $SourceFixtureId -and
    ($SourceFixtureId -cne $packageFixtureId)) {
    throw "The supplied -SourceFixtureId '$SourceFixtureId' does not equal the sealed discovery package fixtureId '$packageFixtureId'; the candidate source fixture is derived from the package, never asserted by the operator."
}

# Parse the sealed discovery marker with the EXACT production CLI-envelope reader,
# then strip the production result-marker prefix - byte-for-byte the same rebuild the
# acquisition child performs, so the derived candidate/cluster hashes match exactly.
$markerText = [string]$package.MarkerText
$cliOutcome = Get-AgentCliJsonOutcome -StdOutText $markerText
$answer = if ($cliOutcome -and $cliOutcome.Answer) { [string]$cliOutcome.Answer } else { $markerText }
$answer = $answer.Trim()
$prefixIndex = $answer.IndexOf($markerPrefix, [System.StringComparison]::Ordinal)
if ($prefixIndex -ge 0) {
    $answer = $answer.Substring($prefixIndex + $markerPrefix.Length).Trim()
}
$marker = $null
try { $marker = $answer | ConvertFrom-Json -Depth 64 }
catch { throw "The sealed discovery result marker is not valid JSON; cannot extract a candidate." }

# Derive candidates and clusters through the EXACT production functions from the
# single authenticated source marker. Specialist findings enter the same blind union
# as convention-origin candidates; the specialist itself is never a verifier.
$specialistCandidates = @()
if ($sourceRole -ceq 'specialist') {
    $specialistSchema = Get-ReviewerConventionSpecialistMarkerSchema `
        -ExpectedProject ([string]$core.snapshotIdentity.project) -ExpectedNonce ([string]$core.nonce)
    # Route the specialist capture through the specialist-specific wrapper the
    # production reviewer uses, not the generic reader. The wrapper supplies the
    # -CandidateNormalizer that rewrites an empty changedCodeFix.evidenceFactIds
    # JSON array to the schema's no-evidence empty string; parsing with the bare
    # ConvertFrom-AgentResultMarkerOutcome bypasses it and rejects a specialist
    # marker every production call site accepts.
    $specialistOutcome = ConvertFrom-ReviewerConventionSpecialistResultMarkerOutcome `
        -StdOutText $markerText -Schema $specialistSchema `
        -ScanWindowChars (Get-ReviewerConventionSpecialistScanWindowChars)
    if ([string]$specialistOutcome.Status -cne 'success') {
        throw "The sealed specialist result marker failed the exact production schema: $([string]$specialistOutcome.Status)."
    }
    $marker = $specialistOutcome.Value
    $specialistCandidates = @(Get-ReviewerAuthenticatedSpecialistCandidates -Core $core -Marker $marker)
}
$derived = @(ConvertTo-ReviewerIndependentDiscoveryCandidates -SourceRole $sourceRole `
        -SourceModel $sourceModel -Marker $marker -SpecialistCandidates $specialistCandidates)
if ($derived.Count -eq 0) {
    throw "The sealed discovery marker yielded no candidates; a verifier cross-check requires at least one discovery finding."
}
$clusters = @(Get-ReviewerVerificationClusters -Candidates $derived)
$clusterIds = @(@($clusters | ForEach-Object { [string]$_.clusterId }) | Sort-Object -Unique)
if ($clusterIds.Count -ne 1) {
    throw "The sealed discovery marker derived $($clusterIds.Count) clusters; acquisition binds a single-cluster discovery candidate."
}

$candidateList = @($derived | ForEach-Object {
        [ordered]@{
            candidateId   = [string]$_.candidateId
            candidateHash = [string]$_.candidateHash
            originKind    = [string]$_.originKind
            originModel   = [string]$_.originModel
            originArtifactSha256 = [string]$_.originArtifactSha256
            severity      = [string]$_.severity
            filePath      = [string]$_.filePath
            line          = [int]$_.line
            comment       = [string]$_.comment
        }
    })

$candidate = [ordered]@{
    schemaVersion       = 1
    kind                = 'reviewer-discovery-candidate-input'
    sourceFixtureId     = $packageFixtureId
    sourceRole          = $sourceRole
    sourceModel         = $sourceModel
    resultMarkerPrefix  = $markerPrefix
    resultMarkerBinding = [ordered]@{
        prId         = [int]$marker.prId
        repositoryId = [string]$marker.repositoryId
        project      = [string]$marker.project
        sourceCommit = [string]$marker.reviewedSourceCommit
    }
    clusterId           = [string]$clusterIds[0]
    candidates          = $candidateList
}

$json = $candidate | ConvertTo-Json -Depth 32
if (-not [System.IO.Path]::IsPathRooted($OutputFile)) {
    $OutputFile = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $OutputFile))
}
$outDir = Split-Path -Parent $OutputFile
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}
[IO.File]::WriteAllText($OutputFile, $json, $Utf8)
Write-Host "Extracted discovery candidate: cluster=$([string]$clusterIds[0]) candidates=$($candidateList.Count) -> $OutputFile" -ForegroundColor Green
