#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Runs the REAL capture producer over real sealed acquisition packages, one per
    role, and reports exactly which capture cardinality cells that covers.

.DESCRIPTION
    Capture is the one stage boundary whose producer cannot be driven at an
    arbitrary cardinality. Assert-ReviewerAcquisitionTranscriptPackage
    authenticates a sealed, HMAC-bound on-disk transcript package; the only way
    to hand it a census is to mint a package that carries one. The coverage
    matrix therefore recorded capture's sixty producer cells as boundary-only,
    with a residual explaining that the producing function was never executed.

    This tool executes it. It mints packages offline through
    tools/Invoke-ReviewerBlindedAcquisition.ps1 with the stub adapter - no model,
    no network - for as many roles as can be minted, runs the shipping producer
    over each one with the stage shadow switch on, and records the census that
    reached the registered contract boundary AND landed in a versioned file.

    The output is deliberately a census, not a verdict. Some cardinality classes
    are unreachable by construction - by the schema or by the producer - and some are merely untested here, and those
    are two different facts. The report splits them PER COLLECTION under
    cellsNotReached, because the split is not the same for all three:

      * zero      - schema-forbidden for files and attempt statuses (both carry
                    minItems 1), merely untested for directories (no minItems).
      * duplicate - forbidden for file and directory names by the PRODUCER, not
                    by the schema: no uniqueItems is declared anywhere, and it is
                    Assert-ReviewerAcquisitionTranscriptPackage plus the
                    filesystem that refuse. Merely untested for attempt statuses.
      * max       - the corpus max cell is thirty-two, which attempts cannot
                    reach at all (maxItems 8); files and directories are uncapped
                    so thirty-two of either is legal and simply unminted here.

    Read cellsNotReached rather than this list: it carries the authoritative
    per-collection split and this summary can drift.

    Nothing private is written into the repository, and that is enforced rather
    than assumed: every artifact lands under -OutputRoot, and an -OutputRoot whose
    full path is, or is under, this repository is refused outright. That check is
    lexical - GetFullPath on the intended path, compared against the repository
    root - so it catches the ordinary mistake and not a symlink or junction that
    points back into the repository from somewhere outside it.

.EXAMPLE
    ./tools/Invoke-ReviewerCaptureCellCensus.ps1 -OutputRoot C:\temp\capture-census
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),
    [Parameter(Mandatory)][string]$OutputRoot,
    [ValidateSet('generalist', 'specialist', 'verifier')]
    [string[]]$Roles = @('generalist', 'specialist', 'verifier'),
    [int]$PerCallTimeoutSeconds = 60,
    [int]$TotalTimeoutSeconds = 220,
    [int]$ActivityTimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath
. (Join-Path $RepoRoot 'src\Agents\reviewer\StageProducers.ps1')
. (Join-Path $RepoRoot 'src\Agents\reviewer\SourceTransport.ps1')
. (Join-Path $RepoRoot 'src\Agents\reviewer\CrossVerification.ps1')
. (Join-Path $RepoRoot 'src\Agents\reviewer\DeliveryGates.ps1')
. (Join-Path $RepoRoot 'src\Agents\reviewer\AcquisitionPackage.ps1')
. (Join-Path $RepoRoot 'src\Agents\reviewer\ReviewFacts.ps1')

function Remove-Tree {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
        ForEach-Object { try { $_.Attributes = 'Normal' } catch { } }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
}

# The output root is scrubbed and rebuilt below, so a caller pointing it at the
# repository would destroy tracked files and then fill the tree with private run
# state. Refuse before anything is removed, not after.
$resolvedRepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath.TrimEnd('\', '/')
$intendedRoot = [IO.Path]::GetFullPath(
    [IO.Path]::Combine((Get-Location).ProviderPath, $OutputRoot)).TrimEnd('\', '/')
if ($intendedRoot -eq $resolvedRepoRoot -or
    $intendedRoot.StartsWith($resolvedRepoRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "The capture cell census refuses an -OutputRoot inside the repository ('$intendedRoot'). This tool erases and rebuilds that directory and fills it with private run state; point it somewhere the repository does not own."
}

Remove-Tree -Path $OutputRoot
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$OutputRoot = (Resolve-Path -LiteralPath $OutputRoot).ProviderPath

# ---------------------------------------------------------------------------
# Offline acquisition inputs. Every one of these is a checked-in fixture; the
# adapter is the offline stub, so no provider is reachable from here.
# ---------------------------------------------------------------------------
$acquisitionTool = Join-Path $RepoRoot 'tools\Invoke-ReviewerBlindedAcquisition.ps1'
$fixtureRoot = Join-Path $RepoRoot 'src\Agents\reviewer\testdata\exact-path'
$replayRoot = (Resolve-Path (Join-Path $RepoRoot 'src\Agents\reviewer\testdata\replay-v1')).ProviderPath
$conventionReplayRoot = (Resolve-Path (Join-Path $RepoRoot 'tools\testdata\replay-convention')).ProviderPath
$baseManifest = Join-Path $fixtureRoot 'adapter-manifest.json'
$promptSource = Join-Path $RepoRoot 'src\Agents\reviewer\review-cycle.prompt.md'
$reviewerScript = (Resolve-Path (Join-Path $RepoRoot 'src\Agents\reviewer\Start-ReviewerAgent.ps1')).ProviderPath
$generalistProjection = (Resolve-Path (Join-Path $RepoRoot 'tools\testdata\reviewer-acquisition-generalist-projection.json')).ProviderPath
$verifierProjection = (Resolve-Path (Join-Path $RepoRoot 'tools\testdata\reviewer-acquisition-verifier-projection.json')).ProviderPath
# The verifier's candidate set must be the exact production-derived projection of the
# sealed discovery package it is handed, and that package carries a per-run nonce, so
# no committed static candidate can match. It is extracted from the sealed marker by
# the same tool the acquisition harness uses.
$candidateExtractTool = (Resolve-Path (Join-Path $RepoRoot 'tools\Get-ReviewerDiscoveryCandidate.ps1')).ProviderPath
$script:DerivedCandidateFile = Join-Path $OutputRoot 'derived-candidate.json'

$digest = [string]((Get-Content (Join-Path $replayRoot 'synthetic-pr\manifest.json') -Raw | ConvertFrom-Json).manifestDigest)
$conventionDigest = [string]((Get-Content (Join-Path $conventionReplayRoot 'synthetic-convention-pr\manifest.json') -Raw | ConvertFrom-Json).manifestDigest)
$expectedBase = [string]((Get-Content $baseManifest -Raw | ConvertFrom-Json).expectedBaseCommit)

Push-Location $RepoRoot
try {
    $head = (& git rev-parse HEAD).Trim()
    $ref = (& git symbolic-ref --quiet HEAD).Trim()
}
finally { Pop-Location }
if ([string]::IsNullOrWhiteSpace($ref)) {
    throw 'The acquisition tool needs a full ref that resolves to HEAD; this worktree is on a detached HEAD.'
}

$configDir = Join-Path $OutputRoot 'config'
New-Item -ItemType Directory -Force -Path $configDir | Out-Null
Copy-Item (Join-Path $fixtureRoot 'reviewer.config.json') (Join-Path $configDir 'reviewer.config.json') -Force
Copy-Item $promptSource (Join-Path $configDir 'review-cycle.prompt.md') -Force
$configFile = Join-Path $configDir 'reviewer.config.json'

$conventionConfigDir = Join-Path $OutputRoot 'config-convention'
New-Item -ItemType Directory -Force -Path $conventionConfigDir | Out-Null
Copy-Item (Join-Path $conventionReplayRoot 'reviewer.config.json') (Join-Path $conventionConfigDir 'reviewer.config.json') -Force
Copy-Item $promptSource (Join-Path $conventionConfigDir 'review-cycle.prompt.md') -Force
$conventionConfigFile = Join-Path $conventionConfigDir 'reviewer.config.json'

$sealKey = Join-Path $OutputRoot 'seal.key'

# The specialist plan binds the reviewer script that is actually on disk. The
# checked-in projection was minted against an older wrapper, so it is rebound
# run-locally: a legitimate edit to the wrapper keeps the fixture exact, while a
# stale or tampered binding is still refused by the child.
$specialistProjection = Join-Path $OutputRoot 'specialist-projection.json'
$specialistObject = Get-Content (Join-Path $RepoRoot 'tools\testdata\reviewer-acquisition-specialist-projection.json') -Raw |
    ConvertFrom-Json -Depth 100
$currentReviewerSha = (Get-FileHash -LiteralPath $reviewerScript -Algorithm SHA256).Hash.ToLowerInvariant()
$conventionPlan = $specialistObject.specialist.conventionPlanJson | ConvertFrom-Json -Depth 100
$conventionPlan.scriptSha256 = $currentReviewerSha
$specialistObject.specialist.conventionPlanJson = $conventionPlan | ConvertTo-Json -Depth 100 -Compress
$factPlan = $specialistObject.specialist.factPlanJson | ConvertFrom-Json -Depth 100
@($factPlan.hashes.scriptClosure | Where-Object { [string]$_.path -ceq 'Start-ReviewerAgent.ps1' })[0].sha256 = $currentReviewerSha
$factBody = [pscustomobject][ordered]@{
    planVersion = $factPlan.planVersion; schemaVersion = $factPlan.schemaVersion
    extractorVersion = $factPlan.extractorVersion; status = $factPlan.status
    binding = $factPlan.binding; hashes = $factPlan.hashes; domains = $factPlan.domains
    facts = $factPlan.facts; factCount = $factPlan.factCount
}
$factCanonical = ConvertTo-ReviewerFactCanonicalJson -Value $factBody
$factPlan.canonicalBytes = [Text.UTF8Encoding]::new($false).GetByteCount($factCanonical)
$factPlan.planSha256 = Get-ReviewerFactSha256 -Text $factCanonical
$specialistObject.specialist.factPlanJson = $factPlan | ConvertTo-Json -Depth 100 -Compress
[IO.File]::WriteAllText($specialistProjection, ($specialistObject | ConvertTo-Json -Depth 100 -Compress:$false),
    [Text.UTF8Encoding]::new($false))

function Get-RoleArgument {
    param(
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string]$Out,
        [string]$DiscoveryPackageRoot = ''
    )
    switch ($Role) {
        'generalist' {
            return @(
                '-Role', 'generalist', '-FixtureProjectionFile', $generalistProjection,
                '-Model', 'claude-opus-5', '-SecondGeneralistModel', 'gpt-5.6-sol',
                '-ConfigFile', $configFile, '-ReplayRoot', $replayRoot,
                '-ReplaySnapshotName', 'synthetic-pr', '-ReplayManifestDigest', $digest
            )
        }
        'specialist' {
            return @(
                '-Role', 'specialist', '-FixtureProjectionFile', $specialistProjection,
                '-Model', 'claude-sonnet-5', '-ConfigFile', $conventionConfigFile,
                '-ReplayRoot', $conventionReplayRoot, '-ReplaySnapshotName', 'synthetic-convention-pr',
                '-ReplayManifestDigest', $conventionDigest,
                '-DiscoveryGeneralistModel', 'claude-opus-5', '-SecondGeneralistModel', 'gpt-5.6-sol'
            )
        }
        'verifier' {
            return @(
                '-Role', 'verifier', '-FixtureProjectionFile', $verifierProjection,
                '-Model', 'claude-opus-5', '-ConfigFile', $configFile,
                '-ReplayRoot', $replayRoot, '-ReplaySnapshotName', 'synthetic-pr',
                '-ReplayManifestDigest', $digest,
                '-CandidateInputFile', $script:DerivedCandidateFile, '-DiscoveryPackageRoot', $DiscoveryPackageRoot,
                '-SecondGeneralistModel', 'gpt-5.6-sol', '-ConventionSpecialistModel', 'claude-sonnet-5'
            )
        }
    }
    throw "Unknown acquisition role '$Role'."
}

function Invoke-RoleAcquisition {
    param(
        [Parameter(Mandatory)][string]$Role,
        [string]$DiscoveryPackageRoot = ''
    )
    $out = Join-Path $OutputRoot $Role
    Remove-Tree -Path $out
    $arguments = [string[]]@(Get-RoleArgument -Role $Role -Out $out -DiscoveryPackageRoot $DiscoveryPackageRoot) + [string[]]@(
        '-OfflineModelAdapterManifest', $baseManifest, '-ExpectedReviewerBaseCommit', $expectedBase,
        '-PullRequestId', '4242', '-ExpectedHeadCommit', $head, '-ExpectedRef', $ref,
        '-OutputRoot', $out, '-SealKeyPath', $sealKey, '-AllowDirtyWorktree', '-UseOfflineStubAdapter',
        '-PerCallTimeoutSeconds', "$PerCallTimeoutSeconds", '-TotalTimeoutSeconds', "$TotalTimeoutSeconds",
        '-ActivityTimeoutSeconds', "$ActivityTimeoutSeconds"
    )
    $logPath = Join-Path $OutputRoot "$Role-acquisition.log"
    & pwsh -NoProfile -File $acquisitionTool @arguments *> $logPath
    $exitCode = $LASTEXITCODE
    $packageRoot = Join-Path $out 'package'
    return [pscustomobject]@{
        Role = $Role
        ExitCode = $exitCode
        PackageRoot = $packageRoot
        Minted = ($exitCode -eq 0 -and (Test-Path -LiteralPath (Join-Path $packageRoot 'transcript-package.json') -PathType Leaf))
        Log = $logPath
    }
}

# ---------------------------------------------------------------------------
# Mint, then run the shipping producer over what was minted.
# ---------------------------------------------------------------------------

$shadowDirectory = Join-Path $OutputRoot 'stage-artifacts'
New-Item -ItemType Directory -Force -Path $shadowDirectory | Out-Null

$previewPolicy = [pscustomobject]@{
    mode = 'previewOnly'
    approval = [pscustomobject]@{ enabled = $false }
}

$observations = [System.Collections.Generic.List[object]]::new()
$mintings = [System.Collections.Generic.List[object]]::new()
$generalistPackageRoot = ''

Clear-ReviewerStageShadowContractLedger
$null = Enable-ReviewerStageShadowContract -Directory $shadowDirectory -EffectivePolicy $previewPolicy `
    -CommentSwitchOn $false -SuggestionSwitchOn $false -ApprovalSwitchOn $false `
    -Reason 'capture-cell-census'
try {
    # The verifier binds a discovery package produced by a generalist run, so
    # generalist is minted first whenever a verifier is asked for.
    $orderedRoles = [string[]]@('generalist', 'specialist', 'verifier' | Where-Object { $Roles -ccontains $_ })
    if (($Roles -ccontains 'verifier') -and -not ($orderedRoles -ccontains 'generalist')) {
        $orderedRoles = [string[]]@('generalist') + $orderedRoles
    }

    foreach ($role in $orderedRoles) {
        $minting = Invoke-RoleAcquisition -Role $role -DiscoveryPackageRoot $generalistPackageRoot
        [void]$mintings.Add($minting)
        if (-not $minting.Minted) {
            Write-Host "capture-cell-census: role '$role' did not mint a package (exit $($minting.ExitCode)); see $($minting.Log)."
            continue
        }
        if ($role -ceq 'generalist') {
            $generalistPackageRoot = [string]$minting.PackageRoot
            # Derive the verifier's candidate set from the sealed discovery marker
            # this run just produced. The marker is nonce-bound, so this is the only
            # candidate set the production cross-verification cycle will accept.
            $generalistFixtureId = [string]((Get-Content $generalistProjection -Raw | ConvertFrom-Json).fixtureId)
            & pwsh -NoProfile -File $candidateExtractTool -DiscoveryPackageRoot $generalistPackageRoot `
                -SealKeyPath $sealKey -OutputFile $script:DerivedCandidateFile `
                -SourceFixtureId $generalistFixtureId *> (Join-Path $OutputRoot 'derive-candidate.log')
            if ($LASTEXITCODE -ne 0) {
                throw "The discovery candidate set could not be derived from the sealed generalist package; see $(Join-Path $OutputRoot 'derive-candidate.log')."
            }
        }

        $before = 0
        foreach ($entry in (Get-ReviewerStageShadowContractLedger)) { $before++ }
        # The shipping producer, over production-produced bytes, publishing
        # through the registered boundary and into a versioned file.
        $package = Assert-ReviewerAcquisitionTranscriptPackage -PackageRoot ([string]$minting.PackageRoot) `
            -SealKeyPath $sealKey -RequireCaptured
        $records = [object[]]@()
        foreach ($entry in (Get-ReviewerStageShadowContractLedger)) { $records += , $entry }
        if ($records.Count -ne $before + 1) {
            throw "The capture producer for role '$role' published $($records.Count - $before) artifact(s), not 1."
        }
        $record = $records[$records.Count - 1]
        $counts = [ordered]@{}
        foreach ($field in [string[]]@('packageFiles', 'packageDirectories', 'attemptMarkerStatuses')) {
            $counts[$field] = if ($null -ne $record.ObservedCounts -and $record.ObservedCounts.Contains($field)) {
                [int]$record.ObservedCounts[$field]
            }
            else { -1 }
        }
        [void]$observations.Add([pscustomobject][ordered]@{
                role = $role
                packageRoot = [string]$minting.PackageRoot
                artifact = [string]$record.Name
                producerManifestSha256 = [string]$package.ManifestSha256
                producerAttemptMarkerStatuses = [int](@($package.AttemptMarkerStatuses).Count)
                artifactSha256 = [string]$record.Sha256
                readOnly = [bool]$record.ReadOnly
                observedCounts = $counts
            })
        Write-Host ("capture-cell-census: role '{0}' published {1} - files={2} directories={3} attemptMarkers={4}." -f
            $role, $record.Name, $counts['packageFiles'], $counts['packageDirectories'], $counts['attemptMarkerStatuses'])
    }
}
finally {
    Disable-ReviewerStageShadowContract
}

# ---------------------------------------------------------------------------
# What the census covers, and what it provably cannot.
# ---------------------------------------------------------------------------

$variantCounts = [ordered]@{ zero = 0; one = 1; many = 3; max = 32; duplicate = 3 }
$captureFields = [string[]]@('packageFiles', 'packageDirectories', 'attemptMarkerStatuses')

$reached = [ordered]@{}
foreach ($field in $captureFields) {
    $seen = [System.Collections.Generic.List[int]]::new()
    foreach ($observation in $observations) {
        $value = [int]$observation.observedCounts[$field]
        if ($value -ge 0 -and -not $seen.Contains($value)) { [void]$seen.Add($value) }
    }
    $classes = [System.Collections.Generic.List[string]]::new()
    foreach ($variant in $variantCounts.Keys) {
        if ($variant -ceq 'duplicate') { continue }
        if ($seen.Contains([int]$variantCounts[$variant]) -and -not $classes.Contains($variant)) {
            [void]$classes.Add($variant)
        }
    }
    # A census the corpus has no named class for is still evidence the producer
    # ran; it is reported under its own name rather than rounded into one.
    $unclassified = [int[]]@($seen | Where-Object {
            $value = $_
            -not (@($variantCounts.Values) -contains $value)
        })
    $reached[$field] = [pscustomobject][ordered]@{
        observedCardinalities = [int[]]@($seen.ToArray())
        namedVariantsReached = [string[]]@($classes.ToArray())
        cardinalitiesWithoutANamedVariant = $unclassified
    }
}

# Why the cells this census does not reach are not reached. Two separate reasons,
# kept separate on purpose: a cell the schema forbids is genuinely unreachable, and
# a cell nothing here happens to produce is merely untested. Collapsing the second
# into the first is how an omission gets promoted to an impossibility.
$notReached = [ordered]@{
    zero = [pscustomobject][ordered]@{
        reason = 'schema-forbidden for two of three collections, untested for the third'
        schemaForbidden = [string[]]@('packageFiles', 'attemptMarkerStatuses')
        producerForbidden = [string[]]@()
        untested = [string[]]@('packageDirectories')
        note = 'transcript-package.schema.json sets minItems 1 on both files and attempts, so a sealed package can carry neither an empty file census nor an empty attempt ledger. directories carries no minItems at all: a package with zero directories is schema-legal and this census simply never minted one, because every synthetic acquisition fixture writes at least one directory. The zero cell for all three is held by the registered boundary, driven directly.'
    }
    duplicate = [pscustomobject][ordered]@{
        reason = 'producer-forbidden for bound names, untested for attempt statuses'
        schemaForbidden = [string[]]@()
        producerForbidden = [string[]]@('packageFiles', 'packageDirectories')
        untested = [string[]]@('attemptMarkerStatuses')
        note = 'Note the basis: transcript-package.schema.json sets no uniqueItems on files or directories, so this cell is NOT schema-forbidden. It is forbidden by the producer - a directory cannot hold two entries with the same name, and Assert-ReviewerAcquisitionTranscriptPackage refuses duplicate bound names outright - which is a procedural refusal, not a document constraint. attempts carries no uniqueItems either, but nothing refuses it: two attempts may legitimately end in the same terminal status, and this census produced one attempt per role, so that cell is untested here rather than impossible. The duplicate cell is held by the registered boundary, driven directly.'
    }
    max = [pscustomobject][ordered]@{
        reason = 'schema-forbidden for attempt statuses at the corpus max, untested for the rest'
        schemaForbidden = [string[]]@('attemptMarkerStatuses')
        producerForbidden = [string[]]@()
        untested = [string[]]@('packageFiles', 'packageDirectories')
        note = 'The corpus max cell is 32 elements. attempts is capped at maxItems 8, so a 32-status attempt ledger cannot be minted at all - that cell is genuinely unreachable, though eight is reachable and untested. files and directories carry no upper bound, so 32 of either is schema-legal; no synthetic acquisition fixture binds that many, so those two are untested by omission rather than by construction. The max cell is held by the registered boundary, driven directly.'
    }
}

# The capture family is five acquisition schemas, not one. The transcript package is
# the only one the capture stage producer itself judges; the discovery candidate
# document is produced and read back on the same run, by the production extractor and
# the production cross-verification cycle, so it is reported here under its own name
# rather than folded into the stage producer's census.
$derivedCandidateCount = -1
if (Test-Path -LiteralPath $script:DerivedCandidateFile) {
    $derivedCandidate = Get-Content -LiteralPath $script:DerivedCandidateFile -Raw | ConvertFrom-Json -Depth 32
    $derivedCandidateCount = [int](@($derivedCandidate.candidates).Count)
}
$relatedProducerPaths = [ordered]@{
    'capture/transcript-package.v1' = [pscustomobject][ordered]@{
        producer = 'Assert-ReviewerAcquisitionTranscriptPackage'
        executed = ($observations.Count -gt 0)
        note = 'Executed once per sealed role package above; its judged census is what the capture stage artifact carries.'
    }
    'capture/discovery-candidate-input.v1' = [pscustomobject][ordered]@{
        producer = 'tools/Get-ReviewerDiscoveryCandidate.ps1, read back by tools/Invoke-ReviewerBlindedAcquisition.ps1'
        executed = ($derivedCandidateCount -ge 0)
        observedCandidates = $derivedCandidateCount
        note = 'The extractor derives the candidate set from the sealed discovery marker, and the verifier cycle recomputes it from the same package and refuses any set that is not the exact production-derived projection. A committed static candidate set is refused by that reader, so the document read here is the one this run produced.'
    }
    'capture/role-input-capture.v1' = [pscustomobject][ordered]@{
        producer = 'tools/Invoke-ReviewerRoleInputCapture.ps1'
        executed = $false
        note = 'Not executed by this census. Its five inventoried rows remain held by the registered boundary.'
    }
    'capture/role-input-capture-request.v1' = [pscustomobject][ordered]@{
        producer = 'tools/Invoke-ReviewerRoleInputCapture.ps1 request projection'
        executed = $false
        note = 'Not executed by this census. Its inventoried row remains held by the registered boundary.'
    }
    'capture/legacy-benchmark-projection.v1' = [pscustomobject][ordered]@{
        producer = 'legacy benchmark projection schema'
        executed = $false
        note = 'Not executed by this census. Its inventoried row remains held by the registered boundary.'
    }
}

$report = [ordered]@{
    schemaVersion = 1
    kind = 'reviewer.capture-cell-census.v1'
    description = 'What the shipping capture producer published when run over real sealed acquisition packages, with the stage shadow switch on.'
    repoHead = $head
    rolesRequested = [string[]]@($Roles)
    rolesMinted = [string[]]@($observations | ForEach-Object { [string]$_.role })
    rolesNotMinted = [string[]]@($mintings | Where-Object { -not $_.Minted } | ForEach-Object { [string]$_.Role })
    producerExecuted = ($observations.Count -gt 0)
    observations = [object[]]@($observations.ToArray())
    reachedByField = $reached
    relatedProducerPaths = $relatedProducerPaths
    cellsNotReached = $notReached
    # Not runtime instrumentation, and labelled so nobody reads it as such. These
    # record WHY this run cannot have called a model or written outside its output
    # root, so the basis can be checked rather than taken on faith: the acquisition
    # tools are driven with the synthetic offline package producer, the stage shadow
    # switch refuses to open while any delivery capability is live, and every path
    # written below is under $OutputRoot.
    noModelBasis = 'Every role above was minted through the synthetic acquisition package producer with no provider configured; the shadow switch that published the capture artifacts refuses to open while any delivery capability is live. tools/Test-ReviewerStageShadow.ps1 additionally proves by token scan that the switch and its runner name no provider, model, or external-write API.'
    noExternalWriteBasis = 'Every file this tool creates is under the output root it was given, and the stage artifacts are published into a directory the shadow switch owns and marks. Nothing here calls a network or a package manager. It does invoke git, but only the read-only identity queries needed to stamp provenance on a synthetic package; no git command it runs writes to a repository or a remote.'
    outputRoot = [string]$OutputRoot
}
$reportPath = Join-Path $OutputRoot 'capture-cell-census.json'
[IO.File]::WriteAllText($reportPath, (ConvertTo-Json -InputObject $report -Depth 12 -Compress:$false) + "`n",
    [Text.UTF8Encoding]::new($false))

if ($observations.Count -eq 0) {
    Write-Host "FAIL: the capture producer was not executed over any sealed package; see $OutputRoot."
    exit 1
}
# A role that failed to mint is a failed census, not a smaller one. Reporting a
# partial run as a pass is how "the producer was exercised" quietly becomes "the
# producer was exercised for whichever roles happened to work".
$notMinted = [string[]]@($mintings | Where-Object { -not $_.Minted } | ForEach-Object { [string]$_.Role })
if ($notMinted.Count -gt 0) {
    Write-Host ("FAIL: {0} requested role(s) did not mint a sealed package ({1}); see {2}." -f
        $notMinted.Count, ($notMinted -join ', '), $OutputRoot)
    exit 1
}
Write-Host ("PASS: capture producer executed over {0} sealed package(s) ({1}); census at {2}." -f
    $observations.Count, ([string[]]@($observations | ForEach-Object { [string]$_.role }) -join ', '), $reportPath)
exit 0
