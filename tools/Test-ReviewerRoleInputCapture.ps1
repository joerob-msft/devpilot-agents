#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Offline synthetic tests for the no-model production role input capture.

.DESCRIPTION
    Every case here is generic and synthetic: an in-repo sealed replay snapshot,
    an in-repo reviewer configuration, and role contexts built from the repo's
    own blinded fixture projections. Nothing contacts a model, a provider or a
    network, and no case reads a private or employer-specific fixture.

    The suite proves the four things the capture mode exists to guarantee:

      1. the exact production prompt is produced and recorded byte for byte,
         and it EQUALS the prompt the PR49 blinded adapter path produces for the
         equivalent synthetic fixture once the per-attempt nonce is aligned;
      2. zero model, agency or provider child processes start, and zero plans,
         tokens, leases, live reads or live writes are created;
      3. an oracle, an expected decision, a wrong identity/model/role/config/ref,
         a substituted stimulus or a missing sealed resource is refused or
         reported as a typed blocker, never worked around; and
      4. the published bundle is atomic, recursively read-only, schema-valid and
         independently re-verifiable, and a concurrent capture cannot clobber it.
#>
[CmdletBinding()]
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Utf8 = [Text.UTF8Encoding]::new($false, $true)

$CaptureTool = Join-Path $PSScriptRoot 'Invoke-ReviewerRoleInputCapture.ps1'
$MaterializeTool = Join-Path $PSScriptRoot 'Convert-ReviewerBlindedBenchmarkPack.ps1'
$AcquireTool = Join-Path $PSScriptRoot 'Invoke-ReviewerBlindedAcquisition.ps1'
$FixtureRoot = Join-Path $RepoRoot 'src\Agents\reviewer\testdata\exact-path'
$ReplayPath = Join-Path $RepoRoot 'src\Agents\reviewer\testdata\replay-v1\synthetic-pr'
$ConfigFile = Join-Path $FixtureRoot 'reviewer.config.json'
$PromptFile = Join-Path $RepoRoot 'src\Agents\reviewer\review-cycle.prompt.md'
$AdapterManifest = Join-Path $FixtureRoot 'adapter-manifest.json'
$SchemaDir = Join-Path $RepoRoot 'src\Agents\reviewer\acquisition\v1'

Import-Module (Join-Path $RepoRoot 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force

$runId = [Guid]::NewGuid().ToString('N')
$runRoot = Join-Path $RepoRoot ("_role_input_test_tmp-" + $runId)
$captureSealKeyPath = Join-Path $runRoot 'capture-seal.key'

$script:Results = [Collections.Generic.List[object]]::new()
function Check {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][bool]$Ok, [string]$Detail = '')
    [void]$script:Results.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail })
    Write-Host ("  [{0}] {1}{2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name,
        $(if ($Detail) { "  ($Detail)" } else { '' })) -ForegroundColor $(if ($Ok) { 'Green' } else { 'Red' })
}
function Sha { param([string]$Path) (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function TextSha { param([string]$Text) ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Utf8.GetBytes($Text)))).ToLowerInvariant() }
function Canon { param($Value) ConvertTo-AgentReplayCanonicalJson -Value $Value }
function Write-Utf8 {
    param([string]$Path, [string]$Text)
    New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, $Utf8)
}
function New-SpecialistReplay {
    param([Parameter(Mandatory)][string]$Destination)
    Copy-Item -LiteralPath $ReplayPath -Destination $Destination -Recurse -Force
    $repoPayload = [ordered]@{
        jsonrpc = '2.0'; id = 1
        result = [ordered]@{ content = @([ordered]@{
                    type = 'text'
                    text = '{"id":"11111111-2222-3333-4444-555555555555","projectReference":{"name":"Widgets"}}'
                }) }
    }
    $payloadPath = Join-Path $Destination 'payloads\repository.json'
    Write-Utf8 $payloadPath (Canon $repoPayload)
    $arguments = [ordered]@{
        action = 'get'; project = 'Widgets'
        repositoryNameOrId = '11111111-2222-3333-4444-555555555555'
    }
    $requestKey = Get-AgentReplayRequestKey -Name 'repo_repository' -Arguments $arguments
    $mPath = Join-Path $Destination 'manifest.json'
    $m = Get-Content $mPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 64
    $m.bindings.models = @('claude-opus-5', 'gpt-5.6-sol', 'claude-sonnet-5')
    $m.resources = @($m.resources) + @([ordered]@{
            tool = 'repo_repository'; arguments = $arguments; requestSha256 = [string]$requestKey.Key
            payloadFile = 'payloads/repository.json'; payloadSha256 = Sha $payloadPath
            payloadByteLength = [long](Get-Item $payloadPath).Length
        })
    $m.Remove('manifestDigest')
    $m.manifestDigest = TextSha (Canon $m)
    Write-Utf8 $mPath (Canon $m)
    [void](New-AgentReplaySnapshot -ReplayRoot (Split-Path $Destination -Parent) -SnapshotName (Split-Path $Destination -Leaf) `
            -ExpectedManifestDigest ([string]$m.manifestDigest))
}
function New-ClassifiedReplay {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$Models = @('claude-opus-5', 'gpt-5.6-sol', 'claude-sonnet-5')
    )
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
    $manifestPath = Join-Path $Destination 'manifest.json'
    $manifest = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 64
    $manifest.bindings.models = @($Models)
    if ([int]$manifest.schemaVersion -eq 1) { $manifest.schemaVersion = 3 }

    $sidecarName = 'offline-corpus-seal.json'
    $sidecarPath = Join-Path $Destination $sidecarName
    $sidecar = [ordered]@{
        schemaVersion  = 1
        kind           = 'reviewer-role-input-capture-synthetic-seal'
        snapshotId     = [string]$manifest.snapshotId
        sealKind       = 'offlineCorpusSeal'
        nonPromotable  = $true
        oracleFree     = $true
        writesPermitted = $false
    }
    Write-Utf8 $sidecarPath (Canon $sidecar)
    $manifest.Remove('manifestDigest')
    $manifest['classification'] = [ordered]@{
        sealKind = 'offlineCorpusSeal'; nonPromotable = $true
        sidecarFile = $sidecarName; sidecarSha256 = Sha $sidecarPath
    }
    $manifest.manifestDigest = TextSha (Canon $manifest)
    Write-Utf8 $manifestPath (Canon $manifest)
    $loaded = New-AgentReplaySnapshot -ReplayRoot (Split-Path $Destination -Parent) `
        -SnapshotName (Split-Path $Destination -Leaf) -ExpectedManifestDigest ([string]$manifest.manifestDigest)
    if (-not [bool]$loaded.Classification.NonPromotable -or
        [string]$loaded.Classification.SealKind -cne 'offlineCorpusSeal') {
        throw 'Synthetic replay did not load as an independently classified non-promotable snapshot.'
    }
    return $loaded
}
function New-V2ReplaySource {
    <#
        Upgrade the synthetic v1 snapshot to schemaVersion 2, which is the only
        schema whose sealed binding carries a merge base and an iteration. The
        real historical packs are v2, so without this the "the seal carries it
        and the request omits it" half of the identity pairing has no coverage.
    #>
    param([Parameter(Mandatory)][string]$Destination)
    Copy-Item -LiteralPath $ReplayPath -Destination $Destination -Recurse -Force
    Get-ChildItem -LiteralPath $Destination -Recurse -Force | ForEach-Object { try { $_.Attributes = 'Normal' } catch { } }
    $transportPath = Join-Path $Destination 'source-transport.json'
    Write-Utf8 $transportPath (Canon ([ordered]@{ schemaVersion = 1; mode = 'mcpFlat'; files = @() }))
    $mPath = Join-Path $Destination 'manifest.json'
    $m = Get-Content $mPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 64
    $m.schemaVersion = 2
    $m.binding['iterationId'] = 1
    $m.binding['commonCommit'] = [string]$m.binding.targetCommit
    $m['sourceTransport'] = [ordered]@{
        mode = 'mcpFlat'; artifactFile = 'source-transport.json'
        artifactSha256 = Sha $transportPath
        artifactByteLength = [long](Get-Item $transportPath).Length
    }
    $m.Remove('manifestDigest')
    $m.manifestDigest = TextSha (Canon $m)
    Write-Utf8 $mPath (Canon $m)
    [void](New-AgentReplaySnapshot -ReplayRoot (Split-Path $Destination -Parent) -SnapshotName (Split-Path $Destination -Leaf) `
            -ExpectedManifestDigest ([string]$m.manifestDigest))
}
function Remove-Tree {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
            ForEach-Object { try { $_.Attributes = 'Normal' } catch { } }
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}
function Invoke-Tool {
    param([Parameter(Mandatory)][string[]]$Arguments, [string]$ToolPath = $CaptureTool)
    $out = & pwsh -NoProfile -File $ToolPath @Arguments 2>&1
    # PowerShell's concise error view wraps long messages and prefixes the
    # continuation lines with '|', so normalize before any message assertion.
    $flat = (($out | Out-String) -replace '[\r\n]+', ' ') -replace '\s*\|\s*', ' '
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = ($flat -replace '\s+', ' ').Trim(); Raw = (($out | Out-String).Trim()) }
}
function Invoke-ExpectedFailure {
    param([string]$Name, [string[]]$Arguments, [string]$Pattern)
    $r = Invoke-Tool -Arguments $Arguments
    Check $Name ($r.ExitCode -ne 0 -and $r.Text -match $Pattern) $r.Text
}

# ---------------------------------------------------------------------------
# Git identity the tool re-resolves from the object store
# ---------------------------------------------------------------------------
$script:TempRef = $null
$script:WrongRef = $null
Push-Location $RepoRoot
try {
    $head = (& git rev-parse HEAD).Trim()
    $symbolic = (& git symbolic-ref --quiet HEAD 2>$null)
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($symbolic)) { $ref = $symbolic.Trim() }
    else {
        $script:TempRef = "refs/role-input-harness/$runId/head"
        & git update-ref $script:TempRef $head 2>$null | Out-Null
        $ref = $script:TempRef
    }
    $parent = (& git rev-parse --verify --quiet 'HEAD~1' 2>$null)
    if ($LASTEXITCODE -eq 0 -and $parent) {
        $script:WrongRef = "refs/role-input-harness/$runId/wrong"
        & git update-ref $script:WrongRef $parent.Trim() 2>$null | Out-Null
    }
    $expectedBase = [string]((Get-Content $AdapterManifest -Raw | ConvertFrom-Json).expectedBaseCommit)
}
finally { Pop-Location }

# ---------------------------------------------------------------------------
# Independent synthetic seal used as capture input. PR50 runs only after capture.
# ---------------------------------------------------------------------------
$manifestPath = Join-Path $ReplayPath 'manifest.json'
$manifestSha = Sha $manifestPath
$configSha = Sha $ConfigFile
$promptSha = Sha $PromptFile
$sourceManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 64
$v1Digest = [string]$sourceManifest.manifestDigest
$replayRootV1 = Split-Path $ReplayPath -Parent
$packBinding = [ordered]@{
    provider     = 'Synthetic'
    repository   = 'example/widgets'
    repositoryId = [string]$sourceManifest.binding.repositoryId
    pr           = [int]$sourceManifest.binding.pullRequestId
    iteration    = 1
    common       = [string]$sourceManifest.binding.targetCommit
    source       = [string]$sourceManifest.binding.sourceCommit
    target       = [string]$sourceManifest.binding.targetCommit
}
function New-CaptureBundle {
    <#
        Build only the minimal request, config and independently classified
        replay that capture consumes. No role provenance or role-scoped
        projection exists until production reaches the model boundary.
    #>
    param([Parameter(Mandatory)][ValidateSet('generalist', 'specialist', 'verifier')][string]$Role,
        [string]$Tag = '', [string]$ConfigSource = $ConfigFile, [string]$ReplaySource = $ReplayPath)
    $name = if ($Tag) { "$Role-$Tag" } else { $Role }
    $packRoot = Join-Path $runRoot "pack-$name"
    $out = Join-Path $runRoot "bundle-$name"
    $configDir = Join-Path $out 'config'
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null
    Copy-Item -LiteralPath $ConfigSource -Destination (Join-Path $configDir 'reviewer.config.json')
    Copy-Item -LiteralPath $PromptFile -Destination (Join-Path $configDir 'review-cycle.prompt.md')

    $snapshotName = [string]((Get-Content (Join-Path $ReplaySource 'manifest.json') -Raw -Encoding UTF8 |
            ConvertFrom-Json -Depth 64).snapshotId)
    $materializedReplayRoot = Join-Path $out 'replay'
    $classifiedPath = Join-Path $materializedReplayRoot $snapshotName
    New-Item -ItemType Directory -Force -Path $materializedReplayRoot | Out-Null
    $loaded = New-ClassifiedReplay -Source $ReplaySource -Destination $classifiedPath
    $materializedManifest = Join-Path $classifiedPath 'manifest.json'

    $bundleConfigSha = Sha (Join-Path $configDir 'reviewer.config.json')
    $bundleManifestPath = Join-Path $ReplaySource 'manifest.json'
    $bundleManifestSha = Sha $bundleManifestPath
    $sealed = Join-Path $packRoot 'sealed-resources'
    New-Item -ItemType Directory -Force -Path $sealed | Out-Null
    $manifestSealed = Join-Path $sealed "$bundleManifestSha-manifest.json"
    [IO.File]::WriteAllBytes($manifestSealed, [IO.File]::ReadAllBytes($bundleManifestPath))

    $minimalLegacy = [ordered]@{
        schemaVersion       = 1
        kind                = 'blinded-reviewer-adapter-input'
        fixtureId           = "synthetic-$name-capture"
        fixtureVersion      = 1
        binding             = $packBinding
        bindingSha256       = TextSha (Canon $packBinding)
        fixtureIndexBinding = [ordered]@{
            fixtureIndexSha256        = ('1' * 64)
            fixtureRecordHash         = ('2' * 64)
            originalFixtureFileSha256 = ('3' * 64)
        }
        resources           = @([ordered]@{
                mediaRole = 'replay-manifest'; sealedPath = "sealed-resources/$bundleManifestSha-manifest.json"
                sha256 = $bundleManifestSha; byteLength = [long](Get-Item $manifestSealed).Length
            })
    }
    $minimalLegacyFile = Join-Path $packRoot 'projections\fixture.minimal.blinded.json'
    Write-Utf8 $minimalLegacyFile (Canon $minimalLegacy)

    # Declare 'common'/'iteration' ONLY when the sealed binding actually carries
    # them. This snapshot carries neither, and capture now refuses a request that
    # asserts identity the seal cannot back, so declaring them unconditionally
    # would be asserting an unverifiable merge base and iteration.
    $identity = [ordered]@{
        provider = [string]$loaded.Provider; organization = [string]$loaded.Binding.Organization
        project = [string]$loaded.Binding.Project; repositoryId = [string]$loaded.Binding.RepositoryId
        prId = [int]$loaded.Binding.PullRequestId
        source = [string]$loaded.Binding.SourceCommit
        target = [string]$loaded.Binding.TargetCommit; changeSet = [string]$loaded.Binding.ChangeSetSha256
    }
    if ($loaded.Binding.Contains('CommonCommit')) { $identity['common'] = [string]$loaded.Binding.CommonCommit }
    if ($loaded.Binding.Contains('IterationId')) { $identity['iteration'] = [int]$loaded.Binding.IterationId }
    $request = [ordered]@{
        schemaVersion = 1; kind = 'reviewer-role-input-capture-request'
        fixtureId = "synthetic-$name-capture"; role = $Role; model = 'claude-opus-5'
        identity = $identity
        snapshot = [ordered]@{
            name = $snapshotName; manifestDigest = [string]$loaded.ManifestDigest
            manifestFileSha256 = Sha $materializedManifest
            configSha256 = $bundleConfigSha
        }
        resources = @([ordered]@{
                mediaRole = 'replay-manifest'; sealedPath = 'manifest.json'; sha256 = Sha $materializedManifest
                byteLength = [long](Get-Item $materializedManifest).Length
            })
    }
    $requestFile = Join-Path $out 'capture-request.json'
    Write-Utf8 $requestFile (Canon $request)
    return [pscustomobject]@{
        Role         = $Role
        Root         = $out
        Request      = $requestFile
        ConfigFile   = Join-Path $configDir 'reviewer.config.json'
        ReplayRoot   = $materializedReplayRoot
        SnapshotName = $snapshotName
        Digest       = [string]$loaded.ManifestDigest
        LegacyFile   = $minimalLegacyFile
        ReplaySource = $ReplaySource
    }
}

function Get-CaptureArgs {
    param([Parameter(Mandatory)]$Bundle, [Parameter(Mandatory)][string]$Out,
        [string]$Model = 'claude-opus-5', [string]$Role, [string]$Request,
        [string]$ConfigOverride, [string]$RefOverride, [string]$HeadOverride, [string[]]$Extra = @())
    $a = @(
        '-Role', $(if ($Role) { $Role } else { $Bundle.Role }),
        '-Model', $Model,
        '-CaptureRequestFile', $(if ($Request) { $Request } else { $Bundle.Request }),
        '-ConfigFile', $(if ($ConfigOverride) { $ConfigOverride } else { $Bundle.ConfigFile }),
        '-ReplayRoot', $Bundle.ReplayRoot, '-ReplaySnapshotName', $Bundle.SnapshotName,
        '-ReplayManifestDigest', $Bundle.Digest, '-PullRequestId', '4242',
        '-ExpectedHeadCommit', $(if ($HeadOverride) { $HeadOverride } else { $head }),
        '-ExpectedRef', $(if ($RefOverride) { $RefOverride } else { $ref }),
        '-OutputRoot', $Out, '-RepoRoot', $RepoRoot, '-SealKeyPath', $captureSealKeyPath
    )
    if (($Role ? $Role : $Bundle.Role) -cne 'generalist') {
        # The surrounding configured models the orchestration needs. The convention
        # specialist model must be the captured model for a specialist capture,
        # because that is the model this configuration would actually launch.
        $captured = if ($Role -ceq 'specialist' -or (-not $Role -and $Bundle.Role -ceq 'specialist')) { $Model } else { 'claude-sonnet-5' }
        $a += @('-SecondGeneralistModel', 'gpt-5.6-sol', '-ConventionSpecialistModel', $captured)
    }
    return @($a + $Extra)
}

function Invoke-CapturedRolePipeline {
        param(
            [Parameter(Mandatory)][string]$Role,
            [Parameter(Mandatory)][string]$CaptureRoot,
            [Parameter(Mandatory)]$Bundle,
            [Parameter(Mandatory)][string]$Model,
            [string]$Candidate,
            [string]$DiscoveryPackage
        )
        $projection = Get-ChildItem (Join-Path $CaptureRoot 'projections') -Filter '*.blinded.json' | Select-Object -First 1
        $provenance = Get-ChildItem (Join-Path $CaptureRoot 'sealed-resources') -Filter "*-role-$Role.json" | Select-Object -First 1
        $materialized = Join-Path $runRoot "pipeline-materialized-$Role"
        $sourceManifestPath = Join-Path $Bundle.ReplaySource 'manifest.json'
        $raw = & pwsh -NoProfile -File $MaterializeTool @(
            '-PackRoot', $CaptureRoot, '-LegacyProjectionFile', $projection.FullName, '-Role', $Role,
            '-RoleProvenanceFile', $provenance.FullName, '-ReplaySnapshotPath', $Bundle.ReplaySource,
            '-ConfigFile', $Bundle.ConfigFile, '-PromptFile', $PromptFile,
            '-ExpectedReplayManifestFileSha256', (Sha $sourceManifestPath),
            '-ExpectedConfigSha256', (Sha $Bundle.ConfigFile), '-ExpectedPromptSha256', $promptSha,
            '-OutputRoot', $materialized, '-RepoRoot', $RepoRoot) 2>&1
        if ($LASTEXITCODE -ne 0) {
            return [pscustomobject]@{ Ready = $false; Detail = (($raw | Out-String).Trim()) }
        }
        $m = (($raw -join '') | ConvertFrom-Json)
        $preflightOut = Join-Path $runRoot "pipeline-preflight-$Role"
        $args = @(
            '-Role', $Role, '-FixtureProjectionFile', (Join-Path $materialized 'projection.json'), '-Model', $Model,
            '-ConfigFile', (Join-Path $materialized 'config\reviewer.config.json'),
            '-ReplayRoot', (Join-Path $materialized 'replay'), '-ReplaySnapshotName', ([string]$m.replaySnapshotName),
            '-ReplayManifestDigest', ([string]$m.replayManifestDigest), '-ExpectedReviewerBaseCommit', $expectedBase,
            '-PullRequestId', '4242', '-ExpectedHeadCommit', $head, '-ExpectedRef', $ref,
            '-OutputRoot', $preflightOut, '-RepoRoot', $RepoRoot,
            '-SealKeyPath', (Join-Path $runRoot 'seal.key'), '-AllowDirtyWorktree', '-Preflight'
        )
        if ($Role -cne 'generalist') {
            $args += @('-DiscoveryGeneralistModel', 'claude-opus-5',
                '-SecondGeneralistModel', 'gpt-5.6-sol', '-ConventionSpecialistModel',
                $(if ($Role -ceq 'specialist') { $Model } else { 'claude-sonnet-5' }))
        }
        if ($Role -ceq 'verifier') {
            $args += @('-ConventionVerifierModel', $Model, '-CandidateInputFile', $Candidate,
                '-DiscoveryPackageRoot', $DiscoveryPackage)
        }
        $pf = & pwsh -NoProfile -File $AcquireTool @args 2>&1
        $pfText = ($pf | Out-String).Trim()
        return [pscustomobject]@{
            Ready = ($LASTEXITCODE -eq 0 -and $pfText -match '"ready"\s*:\s*true' -and -not (Test-Path $preflightOut))
            Detail = $pfText
        }
}

$exitCode = 0
try {
    Remove-Tree $runRoot
    New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
    [IO.File]::WriteAllBytes($captureSealKeyPath, ([byte[]](1..32)))

    # -- 1. Generalist: the exact production prompt, and nothing else ---------
    Write-Host '1/8 generalist capture reaches the exact model boundary and launches nothing' -ForegroundColor Cyan
    $genBundle = New-CaptureBundle -Role generalist
    $genOut = Join-Path $runRoot 'capture-generalist'
    $gen = Invoke-Tool -Arguments (Get-CaptureArgs -Bundle $genBundle -Out $genOut `
            -Extra @('-LegacyProjectionFile', $genBundle.LegacyFile))
    Check 'generalist capture succeeds' ($gen.ExitCode -eq 0) ($gen.Text -replace '\s+', ' ')
    $genResult = $null
    if ($gen.ExitCode -eq 0) {
        $genResult = (@($gen.Raw -split "`n") | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -First 1) | ConvertFrom-Json -Depth 32
    }
    Check 'supervisor proves zero model/agency/provider processes' (
        $null -ne $genResult -and [bool]$genResult.zeroSideEffects -and
        [bool]$genResult.telemetry.fileExists -and
        -not [string]$genResult.telemetry.parseError -and
        -not [string]$genResult.telemetry.proofError -and
        [int]$genResult.telemetry.totalEvents -gt 0 -and
        [int]$genResult.telemetry.sealedReplayServes -gt 0 -and
        [int]$genResult.telemetry.childProcessStarts -eq 0 -and
        [int]$genResult.telemetry.modelOrAgencyStarts -eq 0 -and
        [int]$genResult.telemetry.providerLiveProcessStarts -eq 0 -and
        [int]$genResult.telemetry.providerLiveWrites -eq 0 -and
        [int]$genResult.telemetry.writeToolInvocations -eq 0)

    $supervisorText = [IO.File]::ReadAllText($CaptureTool, $Utf8)
    $telemetryNeedle = '$telemetryFailure = '''''
    Check 'the telemetry sabotage seam is unique in the supervisor' (
        ($supervisorText.Split([string[]]@($telemetryNeedle), [StringSplitOptions]::None).Length - 1) -eq 1)
    foreach ($telemetryCase in @(
            @{
                Name = 'deleted'
                Prefix = "Remove-Item -LiteralPath `$telemetryPath -Force -ErrorAction SilentlyContinue`r`n"
                Pattern = 'Telemetry proof is missing'
            },
            @{
                Name = 'blank'
                Prefix = "[IO.File]::WriteAllText(`$telemetryPath, '', `$Utf8)`r`n"
                Pattern = 'Telemetry proof is empty'
            },
            @{
                Name = 'no-replay'
                Prefix = "`$withoutReplay = @(Get-Content -LiteralPath `$telemetryPath | Where-Object { [string](`$_ | ConvertFrom-Json).event -cne 'provider.replayServed' })`r`n[IO.File]::WriteAllLines(`$telemetryPath, `$withoutReplay, `$Utf8)`r`n"
                Pattern = 'no provider\.replayServed'
            },
            @{
                # A LINE-ALIGNED prefix: still valid JSONL, still carries serves,
                # so the "at least one serve" floor alone would admit it. It is
                # the dangerous shape, because a prefix that stops short of a
                # later process.started reads as "no child process started". The
                # terminal capture.completed record is what refuses it.
                Name = 'prefix-truncated'
                Prefix = "`$kept = @(Get-Content -LiteralPath `$telemetryPath | Where-Object { `$_ } | Select-Object -First 2)`r`n[IO.File]::WriteAllLines(`$telemetryPath, `$kept, `$Utf8)`r`n"
                Pattern = 'terminal capture\.completed'
            },
            @{
                # A sink that continued past the terminal record: whatever wrote
                # the extra events was not the capture, so the sink is no longer
                # a complete account of it.
                Name = 'appended-after-terminal'
                Prefix = "[IO.File]::AppendAllText(`$telemetryPath, (ConvertTo-Json -Compress -InputObject ([ordered]@{ schemaVersion = 1; event = 'process.started'; processId = `$PID; recordedAtUtc = [DateTime]::UtcNow.ToString('o'); data = [ordered]@{ executable = 'notepad' } })) + [Environment]::NewLine, `$Utf8)`r`n"
                Pattern = 'telemetry proves a side effect occurred|not the last telemetry event'
            })) {
        $sabotagedTool = Join-Path $runRoot "Invoke-ReviewerRoleInputCapture-$($telemetryCase.Name).ps1"
        Write-Utf8 $sabotagedTool ($supervisorText.Replace(
                $telemetryNeedle, ([string]$telemetryCase.Prefix + $telemetryNeedle)))
        $sabotagedOut = Join-Path $runRoot "capture-telemetry-$($telemetryCase.Name)"
        $sabotaged = Invoke-Tool -ToolPath $sabotagedTool -Arguments (
            Get-CaptureArgs -Bundle $genBundle -Out $sabotagedOut)
        Check "$($telemetryCase.Name) telemetry sink is refused without publication" (
            $sabotaged.ExitCode -eq 2 -and
            $sabotaged.Text -match [string]$telemetryCase.Pattern -and
            -not (Test-Path -LiteralPath $sabotagedOut)) $sabotaged.Text
    }

    $manifest = Get-Content (Join-Path $genOut 'capture-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 64
    Check 'the exact boundary was reached exactly once' ([int]$manifest.launch.boundaryHits -eq 1)
    Check 'the manifest declares nine zero side effects' (
        @($manifest.sideEffects.PSObject.Properties).Count -eq 9 -and
        @($manifest.sideEffects.PSObject.Properties | Where-Object { [int]$_.Value -ne 0 }).Count -eq 0)
    Check 'the capture authored no plan file' (
        @(Get-ChildItem -LiteralPath $genOut -Recurse -File -Force |
                Where-Object { $_.Name -match 'plan|lease|token' }).Count -eq 0)
    Check 'the bundle is recursively read-only' (
        @(Get-ChildItem -LiteralPath $genOut -Recurse -File -Force |
                Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReadOnly) -eq 0 }).Count -eq 0)
    Check 'the snapshot is recorded non-promotable and write-free' (
        [bool]$manifest.snapshot.nonPromotable -and [bool]$manifest.classification.nonPromotable -and
        -not [bool]$manifest.classification.writesPermitted -and [bool]$manifest.classification.oracleFree)
    Check 'the sealed resource inventory is bound by request and payload hash' (
        @($manifest.snapshot.resources).Count -ge 1 -and
        @($manifest.snapshot.resources | Where-Object { [string]$_.requestSha256 -notmatch '^[0-9a-f]{64}$' }).Count -eq 0)
    Check 'the launch deny set is recorded' (@($manifest.launch.denySet).Count -gt 0)
    Check 'no secret-shaped value appears in the bundle' (
        @(Get-ChildItem -LiteralPath $genOut -Recurse -File -Force | ForEach-Object {
                    [IO.File]::ReadAllText($_.FullName, $Utf8)
                } | Where-Object {
                    $_ -match '(?i)(password|pat=|bearer\s+[A-Za-z0-9._-]{20,}|ghp_[A-Za-z0-9]{20,})'
                }).Count -eq 0)

    $promptPath = Join-Path $genOut 'role-input-prompt.txt'
    $promptText = [IO.File]::ReadAllText($promptPath, $Utf8)
    Check 'the exact prompt bytes are published and hash-bound' (
        (TextSha $promptText) -ceq [string]$manifest.hashes.inputSha256 -and
        [int]([IO.File]::ReadAllBytes($promptPath)).Length -eq [int]$manifest.promptBytes)

    # -- 2. Independent re-verification and tamper detection -----------------
    Write-Host '2/8 the published bundle is independently verifiable and tamper-evident' -ForegroundColor Cyan
    $verify = Invoke-Tool -Arguments @('-VerifyOnly', '-OutputRoot', $genOut, '-SealKeyPath', $captureSealKeyPath)
    Check 'read-only verification of the published bundle succeeds' ($verify.ExitCode -eq 0) ($verify.Text -replace '\s+', ' ')

    $tamperOut = Join-Path $runRoot 'capture-tampered'
    Copy-Item -LiteralPath $genOut -Destination $tamperOut -Recurse -Force
    Get-ChildItem -LiteralPath $tamperOut -Recurse -File -Force | ForEach-Object { $_.Attributes = 'Normal' }
    $tamperedPrompt = Join-Path $tamperOut 'role-input-prompt.txt'
    [IO.File]::WriteAllText($tamperedPrompt, ($promptText + "`nsubstituted stimulus"), $Utf8)
    Get-ChildItem -LiteralPath $tamperOut -Recurse -File -Force | ForEach-Object {
        $_.Attributes = $_.Attributes -bor [IO.FileAttributes]::ReadOnly
    }
    $tamper = Invoke-Tool -Arguments @('-VerifyOnly', '-OutputRoot', $tamperOut, '-SealKeyPath', $captureSealKeyPath)
    Check 'a substituted prompt is detected by verification' ($tamper.ExitCode -ne 0 -and $tamper.Text -match 'changed|disagrees')

    $unboundOut = Join-Path $runRoot 'capture-unbound'
    Copy-Item -LiteralPath $genOut -Destination $unboundOut -Recurse -Force
    $extra = Join-Path $unboundOut 'smuggled.json'
    [IO.File]::WriteAllText($extra, '{"note":"unbound"}', $Utf8)
    (Get-Item -LiteralPath $extra).Attributes = 'ReadOnly'
    $unbound = Invoke-Tool -Arguments @('-VerifyOnly', '-OutputRoot', $unboundOut, '-SealKeyPath', $captureSealKeyPath)
    Check 'an unbound smuggled file is detected by verification' ($unbound.ExitCode -ne 0 -and $unbound.Text -match 'unbound')

    $wrongSealKey = Join-Path $runRoot 'wrong-capture-seal.key'
    [IO.File]::WriteAllBytes($wrongSealKey, ([byte[]](33..64)))
    $wrongKeyVerify = Invoke-Tool -Arguments @('-VerifyOnly', '-OutputRoot', $genOut, '-SealKeyPath', $wrongSealKey)
    Check 'a different HMAC key cannot authenticate the capture' (
        $wrongKeyVerify.ExitCode -ne 0 -and $wrongKeyVerify.Text -match 'HMAC seal mismatch')

    $manifestTamperOut = Join-Path $runRoot 'capture-manifest-tampered'
    Copy-Item -LiteralPath $genOut -Destination $manifestTamperOut -Recurse -Force
    Get-ChildItem -LiteralPath $manifestTamperOut -Recurse -File -Force | ForEach-Object { $_.Attributes = 'Normal' }
    $tamperedManifestPath = Join-Path $manifestTamperOut 'capture-manifest.json'
    $tamperedManifest = [IO.File]::ReadAllText($tamperedManifestPath, $Utf8) | ConvertFrom-Json -Depth 64
    $tamperedManifest.timings.totalDurationMs = [int]$tamperedManifest.timings.totalDurationMs + 1
    [IO.File]::WriteAllText($tamperedManifestPath, ($tamperedManifest | ConvertTo-Json -Depth 64 -Compress), $Utf8)
    Get-ChildItem -LiteralPath $manifestTamperOut -Recurse -File -Force | ForEach-Object {
        $_.Attributes = $_.Attributes -bor [IO.FileAttributes]::ReadOnly
    }
    $manifestTamper = Invoke-Tool -Arguments @('-VerifyOnly', '-OutputRoot', $manifestTamperOut, '-SealKeyPath', $captureSealKeyPath)
    Check 'an edited capture manifest fails its HMAC seal' (
        $manifestTamper.ExitCode -ne 0 -and $manifestTamper.Text -match 'HMAC seal mismatch')

    # -- 3. Prompt-byte equivalence with the PR49 adapter path ---------------
    Write-Host '3/8 the captured prompt equals the PR49 adapter prompt for the equivalent fixture' -ForegroundColor Cyan
    $captureProjection = Get-ChildItem (Join-Path $genOut 'projections') -Filter '*.blinded.json' | Select-Object -First 1
    $captureProvenance = Get-ChildItem (Join-Path $genOut 'sealed-resources') -Filter '*-role-generalist.json' | Select-Object -First 1
    $captureMaterialized = Join-Path $runRoot 'capture-materialized-generalist'
    $materializedRaw = & pwsh -NoProfile -File $MaterializeTool @(
        '-PackRoot', $genOut, '-LegacyProjectionFile', $captureProjection.FullName, '-Role', 'generalist',
        '-RoleProvenanceFile', $captureProvenance.FullName, '-ReplaySnapshotPath', $ReplayPath,
        '-ConfigFile', $ConfigFile, '-PromptFile', $PromptFile,
        '-ExpectedReplayManifestFileSha256', $manifestSha, '-ExpectedConfigSha256', $configSha,
        '-ExpectedPromptSha256', $promptSha, '-OutputRoot', $captureMaterialized, '-RepoRoot', $RepoRoot) 2>&1
    $materializedExit = $LASTEXITCODE
    Check 'capture output materializes through PR50' ($materializedExit -eq 0) (($materializedRaw | Out-String).Trim())
    $captureMaterializedResult = if ($materializedExit -eq 0) { (($materializedRaw -join '') | ConvertFrom-Json) } else { $null }
    $acqOut = Join-Path $runRoot 'acquisition-generalist'
    $acqConfigDir = Join-Path $runRoot 'acq-config'
    New-Item -ItemType Directory -Force -Path $acqConfigDir | Out-Null
    Copy-Item $ConfigFile (Join-Path $acqConfigDir 'reviewer.config.json') -Force
    Copy-Item $PromptFile (Join-Path $acqConfigDir 'review-cycle.prompt.md') -Force
    $acqRaw = & pwsh -NoProfile -File $AcquireTool @(
        '-Role', 'generalist', '-FixtureProjectionFile', (Join-Path $captureMaterialized 'projection.json'), '-Model', 'claude-opus-5',
        '-ConfigFile', (Join-Path $acqConfigDir 'reviewer.config.json'), '-ReplayRoot', (Join-Path $captureMaterialized 'replay'),
        '-ReplaySnapshotName', ([string]$captureMaterializedResult.replaySnapshotName),
        '-ReplayManifestDigest', ([string]$captureMaterializedResult.replayManifestDigest),
        '-OfflineModelAdapterManifest', $AdapterManifest, '-ExpectedReviewerBaseCommit', $expectedBase,
        '-PullRequestId', '4242', '-ExpectedHeadCommit', $head, '-ExpectedRef', $ref,
        '-OutputRoot', $acqOut, '-SealKeyPath', (Join-Path $runRoot 'seal.key'),
        '-AllowDirtyWorktree', '-UseOfflineStubAdapter',
        '-PerCallTimeoutSeconds', '45', '-TotalTimeoutSeconds', '180', '-ActivityTimeoutSeconds', '60') 2>&1
    $acqExit = $LASTEXITCODE
    $acqManifestPath = Join-Path $acqOut 'package\transcript-package.json'
    if ($acqExit -eq 0 -and (Test-Path -LiteralPath $acqManifestPath)) {
        $acqManifest = Get-Content $acqManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 64
        $acqNonce = [string]@($acqManifest.attempts)[-1].nonce
        $captureNonce = [string]$manifest.nonce
        # The ONLY per-attempt difference between the two stimuli is the nonce the
        # runtime context carries. Aligning it and re-hashing proves the remaining
        # bytes - the whole prompt and the whole runtime context - are identical.
        # The substitution must be provably confined: a global Replace that hit
        # nonce-shaped bytes elsewhere could mask a real difference, so count the
        # occurrences on both sides before rewriting anything.
        $captureNonceCount = ($promptText.Split([string[]]@($captureNonce), [StringSplitOptions]::None).Length - 1)
        $acqNonceInCapture = ($promptText.Split([string[]]@($acqNonce), [StringSplitOptions]::None).Length - 1)
        Check 'the capture nonce occurs exactly once in the captured prompt' ($captureNonceCount -eq 1) `
            "occurrences=$captureNonceCount"
        Check 'the acquisition nonce does not already occur in the captured prompt' ($acqNonceInCapture -eq 0) `
            "occurrences=$acqNonceInCapture"
        $aligned = $promptText.Replace($captureNonce, $acqNonce)
        Check 'the capture nonce actually occurs in the captured prompt' ($aligned -cne $promptText)
        Check 'aligning the nonce changed the prompt length by exactly the nonce delta' (
            ($aligned.Length - $promptText.Length) -eq ($acqNonce.Length - $captureNonce.Length)) `
            "delta=$($aligned.Length - $promptText.Length) expected=$($acqNonce.Length - $captureNonce.Length)"
        Check 'captured prompt bytes equal the PR49 adapter prompt bytes' (
            (TextSha $aligned) -ceq [string]$acqManifest.digests.inputSha256) `
            "capture=$((TextSha $aligned).Substring(0,12)) acquisition=$(([string]$acqManifest.digests.inputSha256).Substring(0,12))"
        Check 'the capture and the acquisition agree on the role request digest' (
            [string]$manifest.hashes.requestSha256 -ceq [string]$acqManifest.digests.requestSha256)
        Check 'the capture and the acquisition agree on the prompt-file digest' (
            [string]$manifest.hashes.promptSha256 -ceq [string]$acqManifest.digests.promptSha256)
    }
    else {
        Check 'PR49 adapter acquisition produced a comparable package' $false (($acqRaw | Out-String).Trim() -replace '\s+', ' ')
    }
    $genPipeline = Invoke-CapturedRolePipeline -Role generalist -CaptureRoot $genOut -Bundle $genBundle -Model 'claude-opus-5'
    Check 'generalist capture -> PR50 materialize -> PR49 Preflight succeeds' $genPipeline.Ready $genPipeline.Detail

    # -- 4. Oracle and expected-decision refusal -----------------------------
    Write-Host '4/8 oracle and expected-decision inputs are refused recursively' -ForegroundColor Cyan
    $oracleDir = Join-Path $runRoot 'expected-oracle'
    New-Item -ItemType Directory -Force -Path $oracleDir | Out-Null
    Copy-Item -LiteralPath $genBundle.Request -Destination (Join-Path $oracleDir 'request.json') -Force
    Invoke-ExpectedFailure 'an oracle-named PATH is refused' `
        (Get-CaptureArgs -Bundle $genBundle -Out (Join-Path $runRoot 'capture-badpath') -Request (Join-Path $oracleDir 'request.json')) `
        'names an oracle'

    # Both key cases keep every PATH innocuous, so the refusal can only come from
    # the recursive KEY scan and not incidentally from the path scan.
    $keyedProjection = Join-Path $runRoot 'keyed-projection.json'
    $keyed = Get-Content -LiteralPath $genBundle.Request -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 64
    $keyed['expectedDecision'] = 'approve'
    Write-Utf8 $keyedProjection (ConvertTo-Json $keyed -Depth 64)
    Invoke-ExpectedFailure 'a top-level oracle KEY is refused, naming the field' `
        (Get-CaptureArgs -Bundle $genBundle -Out (Join-Path $runRoot 'capture-keyed') -Request $keyedProjection) `
        'expectedDecision'

    $nestedProjection = Join-Path $runRoot 'nested-projection.json'
    $nested = Get-Content -LiteralPath $genBundle.Request -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 64
    $nested['identity']['groundTruth'] = 'approve'
    Write-Utf8 $nestedProjection (ConvertTo-Json $nested -Depth 64)
    Invoke-ExpectedFailure 'a NESTED oracle key is refused, naming the field' `
        (Get-CaptureArgs -Bundle $genBundle -Out (Join-Path $runRoot 'capture-nested') -Request $nestedProjection) `
        'groundTruth'

    # The reviewer configuration is not covered by a fixture schema, so this case
    # exercises the recursive KEY scan on its own rather than the schema gate.
    $oracleConfigDir = Join-Path $runRoot 'alt-config'
    $oracleConfig = Join-Path $oracleConfigDir 'reviewer.config.json'
    $oracleConfigObject = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 64
    $oracleConfigObject['reviewOracle'] = @{ expectedVerdict = 'approve' }
    Write-Utf8 $oracleConfig (ConvertTo-Json $oracleConfigObject -Depth 64)
    Copy-Item $PromptFile (Join-Path $oracleConfigDir 'review-cycle.prompt.md') -Force
    Invoke-ExpectedFailure 'an oracle key smuggled through the CONFIG is refused' `
        (Get-CaptureArgs -Bundle $genBundle -Out (Join-Path $runRoot 'capture-alt-config') -ConfigOverride $oracleConfig) `
        'forbidden oracle'

    # -- 5. Identity, model, role, config and ref binding --------------------
    Write-Host '5/8 identity, model, role, config and ref are all bound' -ForegroundColor Cyan
    Invoke-ExpectedFailure 'a role that disagrees with the projection is refused' `
        (Get-CaptureArgs -Bundle $genBundle -Out (Join-Path $runRoot 'capture-wrong-role') -Role 'specialist') `
        'declares role'
    Invoke-ExpectedFailure 'a model the sealed snapshot never covered is refused' `
        (Get-CaptureArgs -Bundle $genBundle -Out (Join-Path $runRoot 'capture-wrong-model') -Model 'gpt-5.6-sol') `
        'declares model'
    Invoke-ExpectedFailure 'a head commit that is not HEAD is refused' `
        (Get-CaptureArgs -Bundle $genBundle -Out (Join-Path $runRoot 'capture-wrong-head') -HeadOverride ('0' * 40)) `
        'resolves to'
    if ($script:WrongRef) {
        Invoke-ExpectedFailure 'a valid ref that resolves elsewhere is refused' `
            (Get-CaptureArgs -Bundle $genBundle -Out (Join-Path $runRoot 'capture-wrong-ref') -RefOverride $script:WrongRef) `
            'resolves to'
    }
    $wrongConfig = Join-Path $runRoot 'wrong-config\reviewer.config.json'
    $wrongConfigObject = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 64
    $wrongConfigObject.repository.id = '99999999-8888-7777-6666-555555555555'
    Write-Utf8 $wrongConfig (ConvertTo-Json $wrongConfigObject -Depth 64)
    Copy-Item $PromptFile (Join-Path (Split-Path $wrongConfig -Parent) 'review-cycle.prompt.md') -Force
    # The request must name the MUTATED config's digest. Left pointing at the
    # original, the run is refused by the configSha256 gate before it can reach
    # the repository binding at all, and this check would silently degrade into
    # a second copy of the config-hash test rather than covering the gate it is
    # named for.
    $wrongCfgRequest = Join-Path $runRoot 'request-wrong-config.json'
    $wrongCfgRequestObject = Get-Content -LiteralPath $genBundle.Request -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 64
    $wrongCfgRequestObject.snapshot.configSha256 = (Sha $wrongConfig)
    Write-Utf8 $wrongCfgRequest (Canon $wrongCfgRequestObject)
    $wrongCfg = Invoke-Tool -Arguments (Get-CaptureArgs -Bundle $genBundle -Out (Join-Path $runRoot 'capture-wrong-config') `
            -Request $wrongCfgRequest -ConfigOverride $wrongConfig)
    Check 'a config bound to another repository is refused' (
        $wrongCfg.ExitCode -ne 0 -and $wrongCfg.Text -match 'bound to repository') $wrongCfg.Text
    Invoke-ExpectedFailure 'a missing reviewer config is refused before capture' `
        (Get-CaptureArgs -Bundle $genBundle -Out (Join-Path $runRoot 'capture-missing-config') `
            -ConfigOverride (Join-Path $runRoot 'missing-config\reviewer.config.json')) `
        'does not exist'

    $missingIdentityRequest = Join-Path $runRoot 'request-missing-identity.json'
    $missingIdentity = Get-Content -LiteralPath $genBundle.Request -Raw -Encoding UTF8 |
        ConvertFrom-Json -AsHashtable -Depth 64
    $missingIdentity.identity.Remove('project')
    Write-Utf8 $missingIdentityRequest (ConvertTo-Json $missingIdentity -Depth 64)
    Invoke-ExpectedFailure 'a request missing sealed project identity is schema-refused' `
        (Get-CaptureArgs -Bundle $genBundle -Out (Join-Path $runRoot 'capture-missing-identity') `
            -Request $missingIdentityRequest) `
        'identity/project|project'

    $substituted = Join-Path $runRoot 'substituted-projection.json'
    $substitutedObject = Get-Content -LiteralPath $genBundle.Request -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 64
    $substitutedObject.identity.source = ('f' * 40)
    Write-Utf8 $substituted (ConvertTo-Json $substitutedObject -Depth 64)
    $subOut = Join-Path $runRoot 'capture-substituted'
    $sub = Invoke-Tool -Arguments (Get-CaptureArgs -Bundle $genBundle -Out $subOut -Request $substituted)
    $subPrompt = ''
    if ($sub.ExitCode -eq 0) { $subPrompt = [IO.File]::ReadAllText((Join-Path $subOut 'role-input-prompt.txt'), $Utf8) }
    Check 'a substituted stimulus produces a different prompt, never the original' (
        $sub.ExitCode -ne 0 -or ((TextSha $subPrompt) -cne (TextSha $promptText)))

    # This snapshot's sealed binding carries neither a merge base nor an
    # iteration, so a request that declares either is asserting identity nothing
    # can verify. Before the two-way pairing check these were silently ignored,
    # which let a request state an arbitrary merge base and still be accepted.
    $unbackedCommon = Join-Path $runRoot 'request-unbacked-common.json'
    $unbackedObject = Get-Content -LiteralPath $genBundle.Request -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 64
    $unbackedObject.identity.common = ('a' * 40)
    Write-Utf8 $unbackedCommon (ConvertTo-Json $unbackedObject -Depth 64)
    Invoke-ExpectedFailure 'a request declaring a merge base the seal does not carry is refused' `
        (Get-CaptureArgs -Bundle $genBundle -Out (Join-Path $runRoot 'capture-unbacked-common') -Request $unbackedCommon) `
        "declares 'common'"

    $unbackedIteration = Join-Path $runRoot 'request-unbacked-iteration.json'
    $unbackedIterationObject = Get-Content -LiteralPath $genBundle.Request -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 64
    $unbackedIterationObject.identity.iteration = 99
    Write-Utf8 $unbackedIteration (ConvertTo-Json $unbackedIterationObject -Depth 64)
    Invoke-ExpectedFailure 'a request declaring an iteration the seal does not carry is refused' `
        (Get-CaptureArgs -Bundle $genBundle -Out (Join-Path $runRoot 'capture-unbacked-iteration') -Request $unbackedIteration) `
        "declares 'iteration'"

    # The mirror direction, which only a v2 seal can exercise: the snapshot DOES
    # carry a merge base and an iteration, and a request that stays silent about
    # them must be refused rather than quietly capturing under an identity it
    # never committed to. The real historical packs are all v2.
    $v2Source = Join-Path $runRoot 'v2-replay-source\synthetic-pr'
    New-V2ReplaySource -Destination $v2Source
    $v2Bundle = New-CaptureBundle -Role generalist -Tag v2 -ReplaySource $v2Source
    $v2Request = Get-Content -LiteralPath $v2Bundle.Request -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 64
    Check 'a v2 seal makes the request declare both the merge base and the iteration' (
        $v2Request.identity.Contains('common') -and $v2Request.identity.Contains('iteration'))
    foreach ($omitted in @('common', 'iteration')) {
        $omitFile = Join-Path $runRoot "request-omits-$omitted.json"
        $omitObject = Get-Content -LiteralPath $v2Bundle.Request -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 64
        $omitObject.identity.Remove($omitted)
        Write-Utf8 $omitFile (ConvertTo-Json $omitObject -Depth 64)
        Invoke-ExpectedFailure "a request omitting the $omitted the seal carries is refused" `
            (Get-CaptureArgs -Bundle $v2Bundle -Out (Join-Path $runRoot "capture-omits-$omitted") -Request $omitFile) `
            "omits '$omitted'"
    }
    $v2Wrong = Join-Path $runRoot 'request-v2-wrong-common.json'
    $v2WrongObject = Get-Content -LiteralPath $v2Bundle.Request -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 64
    $v2WrongObject.identity.common = ('b' * 40)
    Write-Utf8 $v2Wrong (ConvertTo-Json $v2WrongObject -Depth 64)
    Invoke-ExpectedFailure 'a request whose merge base disagrees with the seal is refused' `
        (Get-CaptureArgs -Bundle $v2Bundle -Out (Join-Path $runRoot 'capture-v2-wrong-common') -Request $v2Wrong) `
        "common does not match"

    # -- 6. Candidate binding and missing sealed material --------------------
    Write-Host '6/8 the verifier requires an independent candidate; missing sealed material blocks' -ForegroundColor Cyan
    $verBundle = New-CaptureBundle -Role verifier
    Invoke-ExpectedFailure 'a verifier capture without an independent candidate is refused' `
        (Get-CaptureArgs -Bundle $verBundle -Out (Join-Path $runRoot 'capture-verifier-nocand')) `
        'independent capture'
    Invoke-ExpectedFailure 'a generalist capture may not smuggle in a candidate' `
        (Get-CaptureArgs -Bundle $genBundle -Out (Join-Path $runRoot 'capture-gen-cand') `
            -Extra @('-CandidateInputFile', (Join-Path $RepoRoot 'tools\testdata\reviewer-acquisition-discovery-candidate.json'))) `
        'belong to the verifier role alone'
    Invoke-ExpectedFailure 'a verifier candidate with no sealed discovery marker is refused' `
        (Get-CaptureArgs -Bundle $verBundle -Out (Join-Path $runRoot 'capture-verifier-nomarker') `
            -Extra @('-CandidateInputFile', (Join-Path $RepoRoot 'tools\testdata\reviewer-acquisition-discovery-candidate.json'))) `
        'DiscoveryMarkerFile'

    $strippedRoot = Join-Path $runRoot 'stripped-replay'
    Copy-Item -LiteralPath $genBundle.ReplayRoot -Destination $strippedRoot -Recurse -Force
    Get-ChildItem -LiteralPath $strippedRoot -Recurse -Force | ForEach-Object { try { $_.Attributes = 'Normal' } catch { } }
    $victim = Get-ChildItem -LiteralPath (Join-Path $strippedRoot "$($genBundle.SnapshotName)\payloads") -File | Select-Object -First 1
    Remove-Item -LiteralPath $victim.FullName -Force
    $strippedBundle = [pscustomobject]@{
        Role = 'generalist'; Root = $genBundle.Root; Request = $genBundle.Request
        ConfigFile = $genBundle.ConfigFile; ReplayRoot = $strippedRoot
        SnapshotName = $genBundle.SnapshotName; Digest = $genBundle.Digest; LegacyFile = $genBundle.LegacyFile
    }
    $missingOut = Join-Path $runRoot 'capture-missing-payload'
    $missing = Invoke-Tool -Arguments (Get-CaptureArgs -Bundle $strippedBundle -Out $missingOut)
    Check 'a sealed snapshot missing a payload fails closed' ($missing.ExitCode -ne 0) $missing.Text
    Check 'a failed-closed capture publishes no bundle and falls back to nothing live' (
        -not (Test-Path -LiteralPath $missingOut) -or
        -not (Test-Path -LiteralPath (Join-Path $missingOut 'capture-manifest.json')))

    $missingResourceRequest = Join-Path $runRoot 'request-missing-resource.json'
    $missingResource = Get-Content -LiteralPath $genBundle.Request -Raw -Encoding UTF8 |
        ConvertFrom-Json -AsHashtable -Depth 64
    $missingResource.resources[0].sealedPath = 'payloads/missing-capture-resource.json'
    Write-Utf8 $missingResourceRequest (ConvertTo-Json $missingResource -Depth 64)
    $missingResourceOut = Join-Path $runRoot 'capture-missing-resource'
    $missingResourceResult = Invoke-Tool -Arguments (Get-CaptureArgs -Bundle $genBundle `
            -Out $missingResourceOut -Request $missingResourceRequest)
    Check 'a missing request resource with vacuous telemetry is refused without publication' (
        $missingResourceResult.ExitCode -eq 2 -and
        $missingResourceResult.Text -match 'telemetry proof is (missing|empty)' -and
        -not (Test-Path -LiteralPath $missingResourceOut)) `
        $missingResourceResult.Text

    $legacyWithProvenance = Join-Path $runRoot 'pack-generalist\projections\fixture.with-provenance.blinded.json'
    $legacyObject = Get-Content $genBundle.LegacyFile -Raw -Encoding UTF8 |
        ConvertFrom-Json -AsHashtable -Depth 64
    $legacyObject.resources += [ordered]@{
        mediaRole = 'role-provenance-generalist'
        sealedPath = [string]$legacyObject.resources[0].sealedPath
        sha256 = [string]$legacyObject.resources[0].sha256
        byteLength = [long]$legacyObject.resources[0].byteLength
    }
    Write-Utf8 $legacyWithProvenance (Canon $legacyObject)
    Invoke-ExpectedFailure 'legacy identity input containing role provenance is refused' `
        (Get-CaptureArgs -Bundle $genBundle -Out (Join-Path $runRoot 'capture-legacy-provenance') `
            -Extra @('-LegacyProjectionFile', $legacyWithProvenance)) `
        'must not contain role provenance'

    $degradedSpecialistBundle = New-CaptureBundle -Role specialist -Tag degraded
    $degradedSpecialistOut = Join-Path $runRoot 'capture-specialist-degraded'
    $degradedSpecialistResult = Invoke-Tool -Arguments (Get-CaptureArgs -Bundle $degradedSpecialistBundle `
            -Out $degradedSpecialistOut -Model 'claude-opus-5')
    $degradedPath = Join-Path $degradedSpecialistOut 'capture-blocked.json'
    $degradedCapture = if (Test-Path -LiteralPath $degradedPath) {
        Get-Content $degradedPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 32
    } else { $null }
    Check 'a missing authoritative convention source produces typed degraded capture' (
        $degradedSpecialistResult.ExitCode -eq 3 -and $null -ne $degradedCapture -and
        [string]$degradedCapture.status -ceq 'degraded' -and
        [string]$degradedCapture.blockedReason -ceq 'noModelBoundaryReached' -and
        [string]$degradedCapture.blockedDetail -match 'authoritative-source-unavailable') `
        $degradedSpecialistResult.Text
    $degradedVerify = Invoke-Tool -Arguments @(
        '-VerifyOnly', '-OutputRoot', $degradedSpecialistOut, '-SealKeyPath', $captureSealKeyPath)
    Check 'a typed blocked bundle passes its exact schema/seal/inventory verification' (
        $degradedVerify.ExitCode -eq 0 -and
        $degradedVerify.Text -match 'HMAC/SHA seal' -and
        $degradedVerify.Text -match 'exact two-file inventory') $degradedVerify.Text

    $blockedUnbound = Join-Path $runRoot 'capture-blocked-unbound'
    Copy-Item -LiteralPath $degradedSpecialistOut -Destination $blockedUnbound -Recurse -Force
    $blockedExtra = Join-Path $blockedUnbound 'extra.json'
    Write-Utf8 $blockedExtra '{"unbound":true}'
    (Get-Item -LiteralPath $blockedExtra).Attributes = [IO.FileAttributes]::ReadOnly
    $blockedUnboundVerify = Invoke-Tool -Arguments @(
        '-VerifyOnly', '-OutputRoot', $blockedUnbound, '-SealKeyPath', $captureSealKeyPath)
    Check 'blocked-bundle verification rejects an unbound file' (
        $blockedUnboundVerify.ExitCode -eq 2 -and $blockedUnboundVerify.Text -match 'unbound file') `
        $blockedUnboundVerify.Text

    $blockedWritable = Join-Path $runRoot 'capture-blocked-writable'
    Copy-Item -LiteralPath $degradedSpecialistOut -Destination $blockedWritable -Recurse -Force
    (Get-Item -LiteralPath (Join-Path $blockedWritable 'capture-blocked.json') -Force).Attributes =
        [IO.FileAttributes]::Normal
    $blockedWritableVerify = Invoke-Tool -Arguments @(
        '-VerifyOnly', '-OutputRoot', $blockedWritable, '-SealKeyPath', $captureSealKeyPath)
    Check 'blocked-bundle verification rejects a writable bound file' (
        $blockedWritableVerify.ExitCode -eq 2 -and $blockedWritableVerify.Text -match 'not read-only') `
        $blockedWritableVerify.Text

    $blockedReparse = Join-Path $runRoot 'capture-blocked-reparse'
    Copy-Item -LiteralPath $degradedSpecialistOut -Destination $blockedReparse -Recurse -Force
    [void](New-Item -ItemType Junction -Path (Join-Path $blockedReparse 'linked') -Target $genBundle.Root)
    $blockedReparseVerify = Invoke-Tool -Arguments @(
        '-VerifyOnly', '-OutputRoot', $blockedReparse, '-SealKeyPath', $captureSealKeyPath)
    Check 'blocked-bundle verification rejects a reparse-point directory' (
        $blockedReparseVerify.ExitCode -eq 2 -and $blockedReparseVerify.Text -match 'reparse-point directory') `
        $blockedReparseVerify.Text

    $promotableBundle = [pscustomobject]@{
        Role = 'generalist'; Root = $genBundle.Root; Request = $genBundle.Request
        ConfigFile = $ConfigFile; ReplayRoot = $replayRootV1
        SnapshotName = 'synthetic-pr'; Digest = $v1Digest; LegacyFile = $genBundle.LegacyFile
    }
    Invoke-ExpectedFailure 'an UNSEALED (promotable) snapshot is refused' `
        (Get-CaptureArgs -Bundle $promotableBundle -Out (Join-Path $runRoot 'capture-promotable')) `
        'is promotable'

    # -- 7. Concurrency and atomicity ---------------------------------------
    Write-Host '7/8 a capture is atomic and never overwrites a published bundle' -ForegroundColor Cyan
    # Recorded BEFORE the re-run: comparing the published manifest against itself
    # afterwards would be true no matter what the re-run did.
    $publishedManifestSha = Sha (Join-Path $genOut 'capture-manifest.json')
    $foreignWorkRoot = Join-Path $runRoot '.capture-generalist.capture-work-00000000000000000000000000000000'
    New-Item -ItemType Directory -Path $foreignWorkRoot | Out-Null
    Write-Utf8 (Join-Path $foreignWorkRoot 'owner.txt') 'another-run'
    $again = Invoke-Tool -Arguments (Get-CaptureArgs -Bundle $genBundle -Out $genOut)
    Check 'a second capture into a published root is refused' (
        $again.ExitCode -ne 0 -and $again.Text -like '*already exists*') ($again.Text -replace '\s+', ' ')
    Check 'the published bundle survived the refused re-run byte for byte' (
        (Sha (Join-Path $genOut 'capture-manifest.json')) -ceq $publishedManifestSha -and
        (TextSha ([IO.File]::ReadAllText((Join-Path $genOut 'role-input-prompt.txt'), $Utf8))) -ceq (TextSha $promptText))
    Check 'a refused capture never deletes another run work root' (
        (Test-Path -LiteralPath (Join-Path $foreignWorkRoot 'owner.txt') -PathType Leaf))
    Check 'no staging directory was left behind' (
        @(Get-ChildItem -LiteralPath $runRoot -Force -Directory |
                Where-Object { $_.Name -like '*.capture-work' -or $_.Name -like '*staging*' }).Count -eq 0)

    # A GENUINE race, not a sequential re-run: two supervisors are started against
    # the same output root and released together, so they contend inside the
    # check-to-publish window the sequential case can never reach.
    $raceOut = Join-Path $runRoot 'capture-race'
    $raceArgs = @(Get-CaptureArgs -Bundle $genBundle -Out $raceOut)
    $raceScript = Join-Path $RepoRoot 'tools\Invoke-ReviewerRoleInputCapture.ps1'
    $raceGate = Join-Path $runRoot 'race-gate.txt'
    $raceRunner = {
        param($Pwsh, $Script, $ToolArgs, $Gate)
        while (-not (Test-Path -LiteralPath $Gate)) { Start-Sleep -Milliseconds 15 }
        $out = & $Pwsh -NoProfile -File $Script @ToolArgs 2>&1
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = (($out | Out-String) -replace '\s+', ' ') }
    }
    $pwshPath = (Get-Process -Id $PID).Path
    $raceJobs = @(1, 2 | ForEach-Object {
            Start-Job -ScriptBlock $raceRunner -ArgumentList $pwshPath, $raceScript, $raceArgs, $raceGate
        })
    Start-Sleep -Milliseconds 400
    Set-Content -LiteralPath $raceGate -Value 'go' -NoNewline
    $raceResults = @($raceJobs | Wait-Job -Timeout 600 | Receive-Job)
    $raceJobs | Remove-Job -Force -ErrorAction SilentlyContinue
    $raceWinners = @($raceResults | Where-Object { $_.ExitCode -eq 0 })
    $raceLosers = @($raceResults | Where-Object { $_.ExitCode -ne 0 })
    Check 'two concurrent captures both ran to a verdict' ($raceResults.Count -eq 2) `
        "results=$($raceResults.Count)"
    Check 'exactly one concurrent capture won' ($raceWinners.Count -eq 1) `
        "winners=$($raceWinners.Count) losers=$($raceLosers.Count) texts=$(($raceResults | ForEach-Object { "exit=$($_.ExitCode)" }) -join ' ')"
    $raceLoserText = if ($raceLosers.Count -eq 1) { $raceLosers[0].Text } else { "losers=$($raceLosers.Count)" }
    Check 'the losing concurrent capture was refused, not merged' (
        $raceLosers.Count -eq 1 -and
        $raceLosers[0].Text -match 'output lock' -and
        $raceLosers[0].Text -match 'another capture') `
        $raceLoserText
    $raceVerify = Invoke-Tool -Arguments @('-VerifyOnly', '-OutputRoot', $raceOut, '-SealKeyPath', $captureSealKeyPath)
    Check 'the raced bundle independently re-verifies clean' ($raceVerify.ExitCode -eq 0) `
        ($raceVerify.Text -replace '\s+', ' ')
    Check 'the race left no staging, work or lock residue' (
        @(Get-ChildItem -LiteralPath $runRoot -Force |
                Where-Object {
                    $_.Name -like '*capture-race*' -and $_.Name -ne 'capture-race'
                }).Count -eq 0)

    # Telemetry is a falsifier, not a verifier, for a no-model capture: the run
    # stops before the model boundary, so it opens no provider session and an
    # empty sink is the correct outcome. The POSITIVE evidence that the real
    # production path ran is the sealed manifest's single model-boundary hit,
    # which the supervisor asserts and which is covered by the HMAC seal.
    Check 'the sealed manifest positively proves the production path reached the boundary exactly once' (
        [int]$manifest.launch.boundaryHits -eq 1) "boundaryHits=$([int]$manifest.launch.boundaryHits)"

    # -- 8. Preflight is readiness only -------------------------------------
    Write-Host '8/8 Preflight performs every readiness check and writes nothing' -ForegroundColor Cyan
    $preflightOut = Join-Path $runRoot 'preflight-would-write-here'
    $before = @(Get-ChildItem -LiteralPath $runRoot -File -Recurse -Force | ForEach-Object {
            "$($_.FullName.Substring($runRoot.Length))|$($_.Length)|$(Sha $_.FullName)"
        } | Sort-Object)
    $pre = Invoke-Tool -Arguments (@(Get-CaptureArgs -Bundle $genBundle -Out $preflightOut) + @('-Preflight'))
    $after = @(Get-ChildItem -LiteralPath $runRoot -File -Recurse -Force | ForEach-Object {
            "$($_.FullName.Substring($runRoot.Length))|$($_.Length)|$(Sha $_.FullName)"
        } | Sort-Object)
    $preflight = $null
    if ($pre.ExitCode -eq 0) {
        $preflight = (@($pre.Raw -split "`n") | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -First 1) | ConvertFrom-Json -Depth 32
    }
    Check 'Preflight returns typed ready JSON' (
        $pre.ExitCode -eq 0 -and $null -ne $preflight -and [bool]$preflight.ready -and
        [string]$preflight.kind -ceq 'reviewer-role-input-capture-readiness') ($pre.Text -replace '\s+', ' ')
    Check 'Preflight reports zero side effects' (
        $null -ne $preflight -and
        @($preflight.sideEffects.PSObject.Properties | Where-Object { [int]$_.Value -ne 0 }).Count -eq 0)
    Check 'Preflight creates no output root' (-not (Test-Path -LiteralPath $preflightOut))
    Check 'Preflight changes no existing byte' (($before -join "`n") -ceq ($after -join "`n"))

    # -- 9. Specialist and verifier successfully reach the production boundary -
    Write-Host '9/9 specialist and verifier capture successfully from production-derived context' -ForegroundColor Cyan
    $specConfig = Join-Path $runRoot 'specialist-source\reviewer.config.json'
    $specConfigObject = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 64
    $specConfigObject.repoConventions.conventionPacks.packs[0].changedPathGlobs = @('**/*.cs')
    $specConfigObject.repoConventions.authoritativeSources.sources[0].expectedByteLength = 220
    $specConfigObject.repoConventions.authoritativeSources.sources[0].expectedSha256 = '4b63e99eb07cf85e89dfdff08eca824ecfc305dcf2ba6ca4b71a691c978b8e12'
    Write-Utf8 $specConfig (ConvertTo-Json $specConfigObject -Depth 64)
    $specReplay = Join-Path $runRoot 'specialist-replay-source\synthetic-pr'
    New-SpecialistReplay -Destination $specReplay
    $specBundle = New-CaptureBundle -Role specialist -ConfigSource $specConfig -ReplaySource $specReplay
    $verSuccessBundle = New-CaptureBundle -Role verifier -Tag success -ReplaySource $specReplay
    $derivedCandidate = Join-Path $runRoot 'independent-discovery-candidate.json'
    $extractRaw = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Get-ReviewerDiscoveryCandidate.ps1') `
        -DiscoveryPackageRoot (Join-Path $acqOut 'package') -OutputFile $derivedCandidate -RepoRoot $RepoRoot 2>&1
    Check 'verifier candidate is derived from an independent sealed discovery transcript' (
        $LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $derivedCandidate)) (($extractRaw | Out-String).Trim())
    $roleCases = @(
        @{ Role = 'specialist'; Bundle = $specBundle; Model = 'claude-opus-5'; Extra = @(
                '-LegacyProjectionFile', $specBundle.LegacyFile) },
        @{ Role = 'verifier'; Bundle = $verSuccessBundle; Model = 'claude-opus-5'; Extra = @(
                '-CandidateInputFile', $derivedCandidate,
                '-DiscoveryMarkerFile', (Join-Path $acqOut 'package\result-marker.txt'),
                '-LegacyProjectionFile', $verSuccessBundle.LegacyFile) }
    )
    foreach ($case in $roleCases) {
        $role = [string]$case.Role
        $out = Join-Path $runRoot "capture-$role-typed"
        $r = Invoke-Tool -Arguments (Get-CaptureArgs -Bundle $case.Bundle -Out $out -Model ([string]$case.Model) -Extra ([string[]]$case.Extra))
        $readyBundle = Join-Path $out 'capture-manifest.json'
        $blocked = Join-Path $out 'capture-blocked.json'
        $isReady = Test-Path -LiteralPath $readyBundle
        $isBlocked = Test-Path -LiteralPath $blocked
        Check "$role capture succeeds at exactly one typed boundary" (
            $r.ExitCode -eq 0 -and $isReady -and -not $isBlocked) $(if ($isBlocked) {
                [string]((Get-Content $blocked -Raw | ConvertFrom-Json).blockedDetail)
            } else { $r.Text })
        if ($isReady) {
            $m = Get-Content $readyBundle -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 64
            Check "$role capture reached the boundary exactly once and started nothing" (
                [int]$m.launch.boundaryHits -eq 1 -and [string]$m.role -ceq $role -and
                @($m.sideEffects.PSObject.Properties | Where-Object { [int]$_.Value -ne 0 }).Count -eq 0)
            $v = Invoke-Tool -Arguments @('-VerifyOnly', '-OutputRoot', $out, '-SealKeyPath', $captureSealKeyPath)
            Check "$role bundle re-verifies independently" ($v.ExitCode -eq 0) $v.Text
            $pipeline = Invoke-CapturedRolePipeline -Role $role -CaptureRoot $out -Bundle $case.Bundle `
                -Model ([string]$case.Model) -Candidate $(if ($role -ceq 'verifier') { $derivedCandidate } else { '' }) `
                -DiscoveryPackage $(if ($role -ceq 'verifier') { Join-Path $acqOut 'package' } else { '' })
            Check "$role capture -> PR50 materialize -> PR49 Preflight succeeds" $pipeline.Ready $pipeline.Detail
        }
        else {
            Check "$role did not fabricate a ready bundle after failure" (-not $isReady -or $r.ExitCode -ne 0) $r.Text
        }
    }

    # -- 10. The captured model and the discovery generalist model separate ----
    Write-Host '10/10 a specialist capture may run a different model from the discovery generalist' -ForegroundColor Cyan
    $splitRequest = Join-Path $runRoot 'specialist-split-model-request.json'
    $splitObject = Get-Content $specBundle.Request -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 64
    $splitObject.model = 'claude-sonnet-5'
    Write-Utf8 $splitRequest (Canon $splitObject)
    $splitOut = Join-Path $runRoot 'capture-specialist-split-model'
    $split = Invoke-Tool -Arguments (Get-CaptureArgs -Bundle $specBundle -Out $splitOut -Model 'claude-sonnet-5' `
            -Request $splitRequest -Extra @('-DiscoveryGeneralistModel', 'claude-opus-5'))
    $splitManifest = Join-Path $splitOut 'capture-manifest.json'
    Check 'a specialist capture separates the captured model from the discovery generalist' (
        $split.ExitCode -eq 0 -and (Test-Path -LiteralPath $splitManifest)) $split.Text
    # The captured model is observable in the manifest, but the DISCOVERY model
    # is not - it is production's primary generalist, which a no-model capture
    # never records. Without reading it back off the supervisor's own result the
    # positive assertion below would hold just as well for a regression that
    # passed the captured model as the discovery model, which is precisely the
    # conflation this section exists to pin.
    $splitResult = $null
    try { $splitResult = (@($split.Raw -split "`n") | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -First 1) | ConvertFrom-Json -Depth 32 }
    catch { $splitResult = $null }
    Check 'the supervisor reports the discovery generalist distinctly from the captured model' (
        $null -ne $splitResult -and [string]$splitResult.discoveryGeneralistModel -ceq 'claude-opus-5' -and
        [string]$splitResult.model -ceq 'claude-sonnet-5') $split.Text
    if (Test-Path -LiteralPath $splitManifest) {
        $splitM = Get-Content $splitManifest -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 64
        Check 'the separated capture records the specialist model, not the discovery model' (
            [string]$splitM.model -ceq 'claude-sonnet-5' -and [string]$splitM.role -ceq 'specialist' -and
            [int]$splitM.launch.boundaryHits -eq 1 -and
            @($splitM.sideEffects.PSObject.Properties | Where-Object { [int]$_.Value -ne 0 }).Count -eq 0)
    }
    Invoke-ExpectedFailure 'a generalist capture may not separate the discovery generalist model' (
        Get-CaptureArgs -Bundle $genBundle -Out (Join-Path $runRoot 'capture-generalist-split-refused') `
            -Extra @('-DiscoveryGeneralistModel', 'claude-sonnet-5')
    ) 'generalist capture is the discovery generalist'
    Invoke-ExpectedFailure 'an unsealed discovery generalist model is refused' (
        Get-CaptureArgs -Bundle $specBundle -Out (Join-Path $runRoot 'capture-specialist-unsealed-discovery') `
            -Extra @('-DiscoveryGeneralistModel', 'gpt-4o-not-sealed')
    ) 'is not among the models the sealed snapshot was captured for'

    # -- Schemas are versioned and strict ------------------------------------
    foreach ($schema in @(
            'role-input-capture-request.schema.json',
            'role-input-capture.schema.json',
            'role-input-capture-blocked.schema.json')) {
        $text = Get-Content (Join-Path $SchemaDir $schema) -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 64
        Check "$schema is strict about unknown fields" ([bool]($text.additionalProperties -eq $false))
    }
}
finally {
    Remove-Tree $runRoot
    Push-Location $RepoRoot
    try {
        foreach ($temp in @($script:TempRef, $script:WrongRef)) {
            if ($temp) { & git update-ref -d $temp 2>$null | Out-Null }
        }
    }
    finally { Pop-Location }
}

$failed = @($script:Results | Where-Object { -not $_.Ok })
Write-Host ''
Write-Host ("Role input capture: {0}/{1} checks passed." -f ($script:Results.Count - $failed.Count), $script:Results.Count) `
    -ForegroundColor $(if ($failed.Count -eq 0) { 'Green' } else { 'Red' })
if ($failed.Count -gt 0) {
    foreach ($f in $failed) { Write-Host "  FAIL: $($f.Name)  $($f.Detail)" -ForegroundColor Red }
    $exitCode = 1
}
exit $exitCode
