#!/usr/bin/env pwsh
[CmdletBinding()]
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$reviewer = Join-Path $RepoRoot 'src\Agents\reviewer\Start-ReviewerAgent.ps1'
$fixtureRoot = Join-Path $RepoRoot 'src\Agents\reviewer\testdata\exact-path'
$sourceReplayRoot = Join-Path $RepoRoot 'src\Agents\reviewer\testdata\replay-v1'
$adapterManifest = Join-Path $fixtureRoot 'adapter-manifest.json'
$oracle = Get-Content (Join-Path $fixtureRoot 'expected-oracle.json') -Raw | ConvertFrom-Json
$expectedBase = [string]((Get-Content $adapterManifest -Raw | ConvertFrom-Json).expectedBaseCommit)
$normalizer = Join-Path $PSScriptRoot 'ConvertTo-ReviewerSemanticDecision.ps1'
$contract = Join-Path $PSScriptRoot 'testdata\reviewer-semantic-normalization-contract.v1.json'
Import-Module (Join-Path $RepoRoot 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force

function New-EmptyThreadReplay {
    param([Parameter(Mandatory)][string]$Sandbox)

    $replayRoot = Join-Path $Sandbox 'replay'
    $snapshotRoot = Join-Path $replayRoot 'synthetic-pr'
    New-Item -ItemType Directory -Path $replayRoot -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceReplayRoot 'synthetic-pr') -Destination $snapshotRoot -Recurse

    $utf8 = [Text.UTF8Encoding]::new($false)
    $payloadPath = Join-Path $snapshotRoot 'payloads\pr-threads.json'
    $payloadBytes = $utf8.GetBytes('{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"[]"}]}}')
    [IO.File]::WriteAllBytes($payloadPath, $payloadBytes)
    $payloadSha = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($payloadBytes)).ToLowerInvariant()

    $manifestPath = Join-Path $snapshotRoot 'manifest.json'
    $manifest = [IO.File]::ReadAllText($manifestPath, $utf8) | ConvertFrom-Json -Depth 32
    $threadResource = @($manifest.resources | Where-Object {
            [string]$_.tool -ceq 'repo_pull_request_thread'
        })
    if ($threadResource.Count -ne 1) { throw 'Exact-path replay did not contain exactly one thread resource.' }
    $threadResource[0].payloadSha256 = $payloadSha
    $threadResource[0].payloadByteLength = $payloadBytes.Length
    $manifest.PSObject.Properties.Remove('manifestDigest')
    $canonical = ConvertTo-AgentReplayCanonicalJson -Value $manifest
    $digest = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($utf8.GetBytes($canonical))).ToLowerInvariant()
    $manifest | Add-Member -NotePropertyName manifestDigest -NotePropertyValue $digest
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 32), $utf8)

    return @{ Root = $replayRoot; Digest = $digest }
}

function Get-TypedArtifactGraph {
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$TelemetryPath,
        [Parameter(Mandatory)][string]$OutputPath
    )
    $artifacts = [Collections.Generic.List[object]]::new()
    $typedFiles = @(Get-ChildItem -LiteralPath $RunRoot -Recurse -File | Where-Object {
            $_.Extension -in @('.json', '.md') -or $_.Name -ceq 'reviewer.log.jsonl'
        } | Sort-Object FullName)
    foreach ($file in $typedFiles) {
        $relative = [IO.Path]::GetRelativePath($RunRoot, $file.FullName)
        $parent = Split-Path $relative -Parent
        $logicalKind = if ([string]::IsNullOrWhiteSpace($parent)) {
            [IO.Path]::GetFileNameWithoutExtension($file.Name)
        }
        else { $parent.Replace('\', '/') }
        $raw = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
        $document = if ($file.Name -ceq 'reviewer.log.jsonl') {
            ,@($raw -split '\r?\n' | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json -Depth 100 })
        }
        elseif ($file.Extension -ceq '.json') { $raw | ConvertFrom-Json -Depth 100 }
        else { $raw }
        [void]$artifacts.Add([pscustomobject][ordered]@{
                logicalKind = $logicalKind
                mediaType = if ($file.Name.EndsWith('.jsonl')) { 'application/x-ndjson' }
                    elseif ($file.Extension -ceq '.md') { 'text/markdown' }
                    else { 'application/json' }
                document = $document
            })
    }
    $telemetry = @(Get-Content -LiteralPath $TelemetryPath -Encoding UTF8 |
            Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json -Depth 32 })
    [void]$artifacts.Add([pscustomobject][ordered]@{
            logicalKind = 'offline-launch-telemetry'
            mediaType = 'application/x-ndjson'
            document = $telemetry
        })
    [pscustomobject][ordered]@{
        schemaVersion = 1
        kind = 'reviewer-exact-path-typed-artifact-graph'
        claim = 'orchestration-correctness-not-model-quality'
        artifacts = @($artifacts)
    } | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
}

function Get-SemanticHash {
    param([Parameter(Mandatory)][string]$GraphPath, [Parameter(Mandatory)][string]$Sandbox)
    return [string](& $normalizer -InputPath $GraphPath -ContractPath $contract `
            -OperationalRoot @($Sandbox, $RepoRoot) -HashOnly)
}

function Invoke-ExactPathRun {
    $sandbox = Join-Path ([IO.Path]::GetTempPath()) ('reviewer-exact-' + [Guid]::NewGuid().ToString('N'))
    $configDir = Join-Path $sandbox 'config'
    $stateDir = Join-Path $sandbox 'state'
    $telemetryPath = Join-Path $sandbox 'offline-telemetry.jsonl'
    New-Item -ItemType Directory -Path $configDir, $stateDir -Force | Out-Null
    $emptyThreadReplay = New-EmptyThreadReplay -Sandbox $sandbox
    Copy-Item (Join-Path $fixtureRoot 'reviewer.config.json') (Join-Path $configDir 'reviewer.config.json')
    Copy-Item (Join-Path $RepoRoot 'src\Agents\reviewer\review-cycle.prompt.md') (Join-Path $configDir 'review-cycle.prompt.md')
    $output = & pwsh -NoProfile -File $reviewer -Once -RepoPath $RepoRoot `
        -ConfigFile (Join-Path $configDir 'reviewer.config.json') -StateDir $stateDir `
        -OperatorAlias fixture-operator -PullRequestId 4242 `
        -Model claude-opus-5 -SecondPassModel gpt-5.6-sol `
        -EnableConventionSpecialist -ConventionSpecialistModel claude-sonnet-5 `
        -EnableVerificationPreview -ConventionVerifierModel claude-opus-5 `
        -CycleTimeoutSeconds 30 -ConventionSpecialistTimeoutSeconds 30 -VerificationTimeoutSeconds 30 `
        -ReplayRoot $emptyThreadReplay.Root -ReplaySnapshotName synthetic-pr -ReplayManifestDigest $emptyThreadReplay.Digest `
        -EnableOfflineModelAdapter -OfflineModelAdapterManifest $adapterManifest `
        -ExpectedReviewerBaseCommit $expectedBase -OfflineTelemetryPath $telemetryPath 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Exact-path reviewer failed: $($output -join [Environment]::NewLine)" }

    $runRoot = Join-Path $stateDir 'replay\synthetic-pr'
    $preview = @(Get-ChildItem (Join-Path $runRoot 'previews') -Filter *.json -File -ErrorAction Stop)
    $specialist = @(Get-ChildItem (Join-Path $runRoot 'convention-specialist-previews') -Filter *.json -File -ErrorAction Stop)
    $verification = @(Get-ChildItem (Join-Path $runRoot 'verification-previews') -Filter *.json -File -ErrorAction Stop)
    if ($preview.Count -ne 1 -or $specialist.Count -ne 1 -or $verification.Count -ne 1) {
        throw 'Exact-path run did not persist exactly one typed artifact for every terminal stage.'
    }
    $previewEnvelope = Get-Content $preview[0].FullName -Raw | ConvertFrom-Json
    $review = $previewEnvelope.manifestJson | ConvertFrom-Json -Depth 64
    $specialistResult = (Get-Content $specialist[0].FullName -Raw | ConvertFrom-Json).manifestJson | ConvertFrom-Json -Depth 64
    $verificationResult = (Get-Content $verification[0].FullName -Raw | ConvertFrom-Json).manifestJson | ConvertFrom-Json -Depth 64
    $events = @(Get-Content -LiteralPath $telemetryPath | ForEach-Object { $_ | ConvertFrom-Json -Depth 32 })
    $processStarts = @($events | Where-Object event -ceq 'process.started')
    $liveProviderEvents = @($events | Where-Object { $_.event -in @('provider.liveProcessStarted', 'provider.liveWrite') })
    $realModelStarts = @($processStarts | Where-Object {
            [IO.Path]::GetFileNameWithoutExtension([string]$_.data.executable) -in @('agency', 'copilot')
        })
    $expectedAdapter = (Resolve-Path (Join-Path $RepoRoot 'src\Agents\reviewer\offline\Invoke-ReviewerModelAdapter.ps1')).Path
    $expectedPwsh = (Get-Command pwsh).Source
    $adapterRoles = @($processStarts | ForEach-Object {
            $arguments = @($_.data.arguments)
            $fileIndex = [Array]::IndexOf($arguments, '-File')
            $roleIndex = [Array]::IndexOf($arguments, '-Role')
            if ($fileIndex -lt 0 -or $roleIndex -lt 0 -or
                [IO.Path]::GetFullPath([string]$arguments[$fileIndex + 1]) -cne $expectedAdapter) {
                throw "Telemetry recorded a child that is not the sealed adapter: $($_ | ConvertTo-Json -Compress -Depth 8)"
            }
            [string]$arguments[$roleIndex + 1]
        } | Sort-Object)
    $expectedRoles = @('blind-gpt', 'blind-opus', 'reciprocal-gpt-verifier', 'reciprocal-opus-verifier') | Sort-Object
    if ($processStarts.Count -ne 4 -or
        @($processStarts | Where-Object { [string]$_.data.executable -cne $expectedPwsh }).Count -ne 0 -or
        ($adapterRoles -join "`n") -cne ($expectedRoles -join "`n") -or
        $realModelStarts.Count -ne 0 -or $liveProviderEvents.Count -ne 0) {
        throw "Direct telemetry rejected launches: child=$($processStarts.Count), realModel=$($realModelStarts.Count), liveProvider=$($liveProviderEvents.Count)."
    }

    $graphPath = Join-Path $sandbox 'semantic-artifact-graph.json'
    Get-TypedArtifactGraph -RunRoot $runRoot -TelemetryPath $telemetryPath -OutputPath $graphPath
    return [pscustomobject][ordered]@{
        sandbox = $sandbox
        graphPath = $graphPath
        semanticSha256 = Get-SemanticHash -GraphPath $graphPath -Sandbox $sandbox
        decision = [ordered]@{
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
            externalWrites = $liveProviderEvents.Count
            realModelLaunches = $realModelStarts.Count
        }
        telemetry = [ordered]@{
            childProcesses = $processStarts.Count
            replayProviderServes = @($events | Where-Object event -ceq 'provider.replayServed').Count
            liveProviderProcesses = @($events | Where-Object event -ceq 'provider.liveProcessStarted').Count
            liveProviderWrites = @($events | Where-Object event -ceq 'provider.liveWrite').Count
        }
    }
}

$first = Invoke-ExactPathRun
$second = Invoke-ExactPathRun
if ($first.semanticSha256 -cne $second.semanticSha256) {
    throw "Repeated complete artifact graphs differ: $($first.semanticSha256) != $($second.semanticSha256)."
}
if ([string]$oracle.expectedSemanticSha256 -notmatch '^[0-9a-f]{64}$' -or
    $first.semanticSha256 -cne [string]$oracle.expectedSemanticSha256) {
    throw "Complete semantic artifact graph drifted: actual $($first.semanticSha256), golden $($oracle.expectedSemanticSha256)."
}
foreach ($property in $oracle.expected.PSObject.Properties) {
    if ($first.decision[$property.Name] -cne $property.Value) {
        throw "Oracle mismatch for '$($property.Name)': actual '$($first.decision[$property.Name])', expected '$($property.Value)'."
    }
}

$sourceGraph = Get-Content -LiteralPath $first.graphPath -Raw | ConvertFrom-Json -Depth 100
$semanticDriftPath = Join-Path $first.sandbox 'semantic-drift.json'
$sourceGraph.claim = 'changed-semantic-claim'
$sourceGraph | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $semanticDriftPath -Encoding utf8NoBOM
if ((Get-SemanticHash -GraphPath $semanticDriftPath -Sandbox $first.sandbox) -ceq $first.semanticSha256) {
    throw 'Semantic normalization failed to detect a retained semantic-field change.'
}

$operationalDriftPath = Join-Path $first.sandbox 'operational-drift.json'
$sourceGraph.claim = 'orchestration-correctness-not-model-quality'
$sourceGraph | Add-Member runId changed-run -Force
$sourceGraph | Add-Member recordedAtUtc '2099-01-01T00:00:00Z' -Force
$sourceGraph | Add-Member durationMs 999999 -Force
$sourceGraph | Add-Member processId 999999 -Force
$sourceGraph | Add-Member nonce changed-nonce -Force
$sourceGraph | Add-Member hmacSignature changed-signature -Force
$sourceGraph | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $operationalDriftPath -Encoding utf8NoBOM
if ((Get-SemanticHash -GraphPath $operationalDriftPath -Sandbox $first.sandbox) -cne $first.semanticSha256) {
    throw 'Semantic normalization retained an explicitly excluded operational-field change.'
}

$logMeasurementDriftPath = Join-Path $first.sandbox 'log-measurement-drift.json'
$logMeasurementGraph = Get-Content -LiteralPath $first.graphPath -Raw | ConvertFrom-Json -Depth 100
$logMeasurementRoundTripPath = Join-Path $first.sandbox 'log-measurement-round-trip.json'
$logMeasurementGraph | ConvertTo-Json -Depth 100 -Compress:$false |
    Set-Content -LiteralPath $logMeasurementRoundTripPath -Encoding utf8NoBOM
if ((Get-SemanticHash -GraphPath $logMeasurementRoundTripPath -Sandbox $first.sandbox) -cne
    $first.semanticSha256) {
    throw 'Semantic artifact graph JSON round-trip changed the digest before the log measurement mutation.'
}
$censusArtifacts = @($logMeasurementGraph.artifacts | Where-Object {
        [string]$_.logicalKind -ceq 'model-start-census.manifest'
    })
if ($censusArtifacts.Count -ne 1) {
    throw "Expected one model-start census manifest artifact, found $($censusArtifacts.Count)."
}
$censusManifest = [string]$censusArtifacts[0].document.manifestJson | ConvertFrom-Json -Depth 32
$censusManifest.logBytes = [int]$censusManifest.logBytes + 27
$censusArtifacts[0].document.manifestJson = $censusManifest | ConvertTo-Json -Depth 32 -Compress
$logMeasurementGraph | ConvertTo-Json -Depth 100 -Compress:$false |
    Set-Content -LiteralPath $logMeasurementDriftPath -Encoding utf8NoBOM
if ((Get-SemanticHash -GraphPath $logMeasurementDriftPath -Sandbox $first.sandbox) -cne $first.semanticSha256) {
    throw 'Semantic normalization retained the operational raw log byte count.'
}

$logSemanticDriftPath = Join-Path $first.sandbox 'log-semantic-drift.json'
$logSemanticGraph = Get-Content -LiteralPath $first.graphPath -Raw | ConvertFrom-Json -Depth 100
$logArtifacts = @($logSemanticGraph.artifacts | Where-Object {
        [string]$_.logicalKind -ceq 'logs' -and [string]$_.mediaType -ceq 'application/x-ndjson'
    })
if ($logArtifacts.Count -ne 1 -or @($logArtifacts[0].document).Count -eq 0) {
    throw 'Expected one non-empty semantic reviewer log artifact.'
}
$logArtifacts[0].document[0] | Add-Member semanticMutation 'changed-log-meaning' -Force
$logSemanticGraph | ConvertTo-Json -Depth 100 -Compress:$false |
    Set-Content -LiteralPath $logSemanticDriftPath -Encoding utf8NoBOM
if ((Get-SemanticHash -GraphPath $logSemanticDriftPath -Sandbox $first.sandbox) -ceq $first.semanticSha256) {
    throw 'Semantic normalization failed to detect a retained reviewer log change.'
}

$setAPath = Join-Path $first.sandbox 'set-order-a.json'
$setBPath = Join-Path $first.sandbox 'set-order-b.json'
$setCPath = Join-Path $first.sandbox 'set-order-regenerated.json'
$setItems = @(
    [pscustomobject]@{ candidateId = 'cand1:bbbb'; verifierModel = 'gpt-5.6-sol' },
    [pscustomobject]@{ candidateId = 'cand1:aaaa'; verifierModel = 'claude-opus-5' }
)
[pscustomobject]@{ assignments = $setItems } |
    ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $setAPath -Encoding utf8NoBOM
[pscustomobject]@{ assignments = @($setItems[1], $setItems[0]) } |
    ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $setBPath -Encoding utf8NoBOM
[pscustomobject]@{ assignments = @(
        [pscustomobject]@{ candidateId = 'cand1:aaaa'; verifierModel = 'gpt-5.6-sol' },
        [pscustomobject]@{ candidateId = 'cand1:bbbb'; verifierModel = 'claude-opus-5' }
    ) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $setCPath -Encoding utf8NoBOM
$setHash = Get-SemanticHash -GraphPath $setAPath -Sandbox $first.sandbox
if ($setHash -cne (Get-SemanticHash -GraphPath $setBPath -Sandbox $first.sandbox) -or
    $setHash -cne (Get-SemanticHash -GraphPath $setCPath -Sandbox $first.sandbox)) {
    throw 'Set permutation or regenerated derived identities changed the semantic digest.'
}

$timestampAPath = Join-Path $first.sandbox 'semantic-timestamp-a.json'
$timestampBPath = Join-Path $first.sandbox 'semantic-timestamp-b.json'
[pscustomobject]@{ findingText = 'The contract says 2030-01-01T00:00:00Z.' } |
    ConvertTo-Json | Set-Content -LiteralPath $timestampAPath -Encoding utf8NoBOM
[pscustomobject]@{ findingText = 'The contract says 2031-01-01T00:00:00Z.' } |
    ConvertTo-Json | Set-Content -LiteralPath $timestampBPath -Encoding utf8NoBOM
if ((Get-SemanticHash -GraphPath $timestampAPath -Sandbox $first.sandbox) -ceq
    (Get-SemanticHash -GraphPath $timestampBPath -Sandbox $first.sandbox)) {
    throw 'A timestamp inside arbitrary semantic text was incorrectly normalized as operational.'
}
$sourcePathA = Join-Path $first.sandbox 'semantic-source-path-a.json'
$sourcePathB = Join-Path $first.sandbox 'semantic-source-path-b.json'
[pscustomobject]@{ filePath = '/src/report-20300101T000000Z.json' } |
    ConvertTo-Json | Set-Content -LiteralPath $sourcePathA -Encoding utf8NoBOM
[pscustomobject]@{ filePath = '/src/report-20310101T000000Z.json' } |
    ConvertTo-Json | Set-Content -LiteralPath $sourcePathB -Encoding utf8NoBOM
if ((Get-SemanticHash -GraphPath $sourcePathA -Sandbox $first.sandbox) -ceq
    (Get-SemanticHash -GraphPath $sourcePathB -Sandbox $first.sandbox)) {
    throw 'A timestamped semantic source path was incorrectly normalized as an artifact path.'
}

Write-Host (("PASS: exact production replay normalized the complete typed artifact graph at {0}; " +
        "telemetry child={1}, replayReads={2}, realModels=0, liveProviderWrites=0.") -f
    $first.semanticSha256, $first.telemetry.childProcesses, $first.telemetry.replayProviderServes)
