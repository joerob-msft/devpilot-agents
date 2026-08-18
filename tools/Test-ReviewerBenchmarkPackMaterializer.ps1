#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Offline synthetic tests for benchmark-pack materialization and acquisition Preflight.
#>
[CmdletBinding()]
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Utf8 = [Text.UTF8Encoding]::new($false, $true)
$Tool = Join-Path $PSScriptRoot 'Convert-ReviewerBlindedBenchmarkPack.ps1'
$Acquire = Join-Path $PSScriptRoot 'Invoke-ReviewerBlindedAcquisition.ps1'
$ReplayPath = Join-Path $RepoRoot 'src\Agents\reviewer\testdata\replay-v1\synthetic-pr'
$ConfigFile = Join-Path $RepoRoot 'src\Agents\reviewer\testdata\exact-path\reviewer.config.json'
$PromptFile = Join-Path $RepoRoot 'src\Agents\reviewer\review-cycle.prompt.md'
$ReviewerScript = Join-Path $RepoRoot 'src\Agents\reviewer\Start-ReviewerAgent.ps1'
$runRoot = Join-Path $RepoRoot ("_pack_materializer_test_" + [Guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $RepoRoot 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force

$script:Results = [Collections.Generic.List[object]]::new()
function Check {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][bool]$Ok, [string]$Detail = '')
    [void]$script:Results.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail })
    Write-Host ("  [{0}] {1}{2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $(if ($Detail) { " ($Detail)" } else { '' })) `
        -ForegroundColor $(if ($Ok) { 'Green' } else { 'Red' })
}
function Sha { param([string]$Path) return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Canon { param($Value) return (ConvertTo-AgentReplayCanonicalJson -Value $Value) }
function Write-Utf8 {
    param([string]$Path, [string]$Text)
    New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, $Utf8)
}
function Remove-Tree {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Attributes = [IO.FileAttributes]::Normal }
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}
function Invoke-ExpectedFailure {
    param([string]$Name, [scriptblock]$Action, [string]$Like)
    $message = ''
    try { $message = (@(& $Action) | Out-String).Trim() }
    catch { $message = $_.Exception.Message }
    Check $Name ($message -like "*$Like*") $message
}

$sourceManifest = Get-Content -LiteralPath (Join-Path $ReplayPath 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 64
$binding = [ordered]@{
    provider = 'Synthetic'
    repository = 'example/widgets'
    repositoryId = [string]$sourceManifest.binding.repositoryId
    pr = [int]$sourceManifest.binding.pullRequestId
    iteration = 1
    common = [string]$sourceManifest.binding.targetCommit
    source = [string]$sourceManifest.binding.sourceCommit
    target = [string]$sourceManifest.binding.targetCommit
}
$configSha = Sha $ConfigFile
$promptSha = Sha $PromptFile
$scriptSha = Sha $ReviewerScript
$manifestPath = Join-Path $ReplayPath 'manifest.json'
$manifestSha = Sha $manifestPath
$head = (& git -C $RepoRoot rev-parse HEAD).Trim()
$ref = (& git -C $RepoRoot symbolic-ref --quiet HEAD 2>$null)
$tempRef = $null
if ($LASTEXITCODE -ne 0 -or -not $ref) {
    $tempRef = "refs/materializer-test/$([Guid]::NewGuid().ToString('N'))"
    & git -C $RepoRoot update-ref $tempRef $head
    $ref = $tempRef
}
else { $ref = $ref.Trim() }

function New-Pack {
    param([string]$Name, [ValidateSet('generalist', 'specialist', 'verifier')][string]$Role)
    $root = Join-Path $runRoot $Name
    $sealed = Join-Path $root 'sealed-resources'
    New-Item -ItemType Directory -Force -Path $sealed | Out-Null
    $manifestSealed = Join-Path $sealed "$manifestSha-manifest.json"
    [IO.File]::WriteAllBytes($manifestSealed, [IO.File]::ReadAllBytes($manifestPath))
    $context = switch ($Role) {
        'generalist' {
            [ordered]@{
                sourceBranch = 'feature/widget-rename'
                authorAlias = 'synthetic-author'
                title = 'Rename widget identifier'
                threadDigestText = '- (no existing human or prior-agent review threads)'
                authoritativeSourcesText = ''
                pinnedSourceText = ''
            }
        }
        'specialist' {
            [ordered]@{ conventionPlanJson = '{"planVersion":1,"status":"synthetic"}'; factPlanJson = '{}' }
        }
        'verifier' {
            [ordered]@{
                targetCommit = [string]$sourceManifest.binding.targetCommit
                changeSetDigest = [string]$sourceManifest.binding.changeSetSha256
                configSha256 = $configSha
                scriptSha256 = $scriptSha
                promptSha256 = $promptSha
            }
        }
    }
    $provenance = [ordered]@{
        schemaVersion = 1
        kind = 'reviewer-model-visible-role-provenance'
        fixtureId = "synthetic-$Role-pack"
        role = $Role
        bindingSha256 = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Utf8.GetBytes((Canon $binding))))).ToLowerInvariant()
        configSha256 = $configSha
        scriptSha256 = $scriptSha
        promptSha256 = $promptSha
        context = $context
    }
    $provenanceTemp = Join-Path $root 'role.tmp.json'
    Write-Utf8 $provenanceTemp (Canon $provenance)
    $provenanceSha = Sha $provenanceTemp
    $provenanceSealed = Join-Path $sealed "$provenanceSha-role-$Role.json"
    Move-Item -LiteralPath $provenanceTemp -Destination $provenanceSealed
    $legacy = [ordered]@{
        schemaVersion = 1
        kind = 'blinded-reviewer-adapter-input'
        fixtureId = "synthetic-$Role-pack"
        fixtureVersion = 1
        binding = $binding
        bindingSha256 = [string]$provenance.bindingSha256
        fixtureIndexBinding = [ordered]@{
            fixtureIndexSha256 = ('1' * 64)
            fixtureRecordHash = ('2' * 64)
            originalFixtureFileSha256 = ('3' * 64)
        }
        resources = @(
            [ordered]@{
                mediaRole = 'replay-manifest'
                sealedPath = "sealed-resources/$manifestSha-manifest.json"
                sha256 = $manifestSha
                byteLength = [long](Get-Item $manifestSealed).Length
            },
            [ordered]@{
                mediaRole = "role-provenance-$Role"
                sealedPath = "sealed-resources/$provenanceSha-role-$Role.json"
                sha256 = $provenanceSha
                byteLength = [long](Get-Item $provenanceSealed).Length
            }
        )
    }
    $projectionFile = Join-Path $root 'projections\fixture.blinded.json'
    Write-Utf8 $projectionFile (ConvertTo-Json $legacy -Depth 64)
    return [pscustomobject]@{
        Root = $root
        Projection = $projectionFile
        Provenance = $provenanceSealed
        Role = $Role
    }
}

function Get-MaterializeArgs {
    param($Pack, [string]$Out)
    return @(
        '-PackRoot', $Pack.Root, '-LegacyProjectionFile', $Pack.Projection,
        '-Role', $Pack.Role, '-RoleProvenanceFile', $Pack.Provenance,
        '-ReplaySnapshotPath', $ReplayPath, '-ConfigFile', $ConfigFile, '-PromptFile', $PromptFile,
        '-ExpectedReplayManifestFileSha256', $manifestSha, '-ExpectedConfigSha256', $configSha,
        '-ExpectedPromptSha256', $promptSha, '-SecondGeneralistModel', 'gpt-5.6-sol',
        '-OutputRoot', $Out, '-RepoRoot', $RepoRoot
    )
}

try {
    Remove-Tree $runRoot
    New-Item -ItemType Directory -Path $runRoot | Out-Null

    $nonPairSecondPack = New-Pack -Name 'non-pair-second' -Role generalist
    $nonPairSecondArgs = @(Get-MaterializeArgs $nonPairSecondPack (
            Join-Path $runRoot 'non-pair-second-out'))
    $nonPairSecondIndex = [Array]::IndexOf(
        $nonPairSecondArgs, '-SecondGeneralistModel')
    $nonPairSecondArgs[$nonPairSecondIndex + 1] = 'gpt-5.6-terra'
    Invoke-ExpectedFailure 'supported second generalist outside configured pair blocks' {
        & pwsh -NoProfile -File $Tool @nonPairSecondArgs 2>&1
    } 'requires one member of the current configured generalist pair'

    $unsupportedSecondPack = New-Pack -Name 'unsupported-second' -Role generalist
    $unsupportedSecondArgs = @(Get-MaterializeArgs $unsupportedSecondPack (
            Join-Path $runRoot 'unsupported-second-out'))
    $unsupportedSecondIndex = [Array]::IndexOf(
        $unsupportedSecondArgs, '-SecondGeneralistModel')
    $unsupportedSecondArgs[$unsupportedSecondIndex + 1] = 'unsupported-generalist'
    Invoke-ExpectedFailure 'unsupported second generalist blocks' {
        & pwsh -NoProfile -File $Tool @unsupportedSecondArgs 2>&1
    } 'unsupported model id'

    $missingPairedPack = New-Pack -Name 'missing-paired-generalist' -Role generalist
    $missingPairedArgs = @(Get-MaterializeArgs $missingPairedPack (
            Join-Path $runRoot 'missing-paired-generalist-out'))
    $missingPairedIndex = [Array]::IndexOf(
        $missingPairedArgs, '-SecondGeneralistModel')
    $missingPairedArgs[$missingPairedIndex + 1] = 'claude-opus-5'
    Invoke-ExpectedFailure 'source replay missing paired generalist blocks' {
        & pwsh -NoProfile -File $Tool @missingPairedArgs 2>&1
    } "does not bind the paired generalist 'gpt-5.6-sol'"

    $bundles = @{}
    foreach ($role in @('generalist', 'specialist', 'verifier')) {
        $pack = New-Pack -Name "pack-$role" -Role $role
        $out = Join-Path $runRoot "bundle-$role"
        $json = & pwsh -NoProfile -File $Tool @(Get-MaterializeArgs $pack $out)
        Check "$role materializes" ($LASTEXITCODE -eq 0 -and (Test-Path (Join-Path $out 'transformation-manifest.json'))) ($json -join '')
        $result = ($json -join '') | ConvertFrom-Json
        $bundles[$role] = [pscustomobject]@{ Pack = $pack; Out = $out; Result = $result }
        $projection = Get-Content (Join-Path $out 'projection.json') -Raw | ConvertFrom-Json
        Check "$role projection is role-scoped" ([string]$projection.role -ceq $role -and $null -ne $projection.$role)
        $files = @(Get-ChildItem -LiteralPath $out -File -Recurse -Force)
        Check "$role bundle is recursively read-only" (@($files | Where-Object {
                    ($_.Attributes -band [IO.FileAttributes]::ReadOnly) -eq 0
                }).Count -eq 0)
        $verify = & pwsh -NoProfile -File $Tool -VerifyOnly -OutputRoot $out `
            -ExpectedTransformationManifestSha256 ([string]$result.transformationManifestSha256) -RepoRoot $RepoRoot
        Check "$role read-only verification succeeds" ($LASTEXITCODE -eq 0 -and ($verify -join '') -match 'reviewer-blinded-benchmark-pack-transformation')
    }

    $missingContextProjection = Get-Content (Join-Path $bundles.generalist.Out 'projection.json') -Raw |
        ConvertFrom-Json -AsHashtable -Depth 64
    [void]$missingContextProjection.Remove('generalist')
    $missingContextJson = ConvertTo-Json $missingContextProjection -Depth 64
    $missingContextValid = $missingContextJson | Test-Json `
        -SchemaFile (Join-Path $RepoRoot 'src\Agents\reviewer\acquisition\v1\fixture-projection.schema.json') `
        -ErrorAction SilentlyContinue
    Check 'projection schema requires role-matching context' (-not $missingContextValid)

    # Preflight must perform all readiness checks while leaving the filesystem
    # byte-for-byte untouched: no output root, lease, plan, token, process or model.
    $generalist = $bundles.generalist
    $preflightOut = Join-Path $runRoot 'preflight-would-write-here'
    $preflightLeasePattern = '.*preflight-would-write-here.*\.acquisition\.lease'
    $before = @(Get-ChildItem -LiteralPath $runRoot -File -Recurse -Force | ForEach-Object {
            "$($_.FullName.Substring($runRoot.Length))|$($_.Length)|$(Sha $_.FullName)"
        } | Sort-Object)
    $pwshPath = (Get-Process -Id $PID).Path
    $savedPath = $env:PATH
    try {
        # A missing executable search path proves Preflight does not launch git
        # or any other child process; pwsh itself is invoked by its absolute path.
        $env:PATH = ''
        $preflightJson = & $pwshPath -NoProfile -File $Acquire -Preflight -Role generalist `
            -FixtureProjectionFile (Join-Path $generalist.Out 'projection.json') -Model 'claude-opus-5' `
            -SecondGeneralistModel 'gpt-5.6-sol' `
            -ConfigFile (Join-Path $generalist.Out 'config\reviewer.config.json') `
            -ReplayRoot (Join-Path $generalist.Out 'replay') -ReplaySnapshotName $generalist.Result.replaySnapshotName `
            -ReplayManifestDigest $generalist.Result.replayManifestDigest -ExpectedReviewerBaseCommit $head `
            -PullRequestId 4242 -ExpectedHeadCommit $head -ExpectedRef $ref -OutputRoot $preflightOut `
            -RepoRoot $RepoRoot -AllowDirtyWorktree
    }
    finally { $env:PATH = $savedPath }
    if ($LASTEXITCODE -ne 0) { throw "Preflight failed: $($preflightJson -join '')" }
    $preflight = ($preflightJson -join '') | ConvertFrom-Json -Depth 32
    $after = @(Get-ChildItem -LiteralPath $runRoot -File -Recurse -Force | ForEach-Object {
            "$($_.FullName.Substring($runRoot.Length))|$($_.Length)|$(Sha $_.FullName)"
        } | Sort-Object)
    Check 'Preflight returns typed ready JSON' ($LASTEXITCODE -eq 0 -and [bool]$preflight.ready -and
        [string]$preflight.kind -ceq 'reviewer-blinded-acquisition-readiness' -and
        [string]$preflight.model -ceq 'claude-opus-5' -and
        [string]$preflight.secondGeneralistModel -ceq 'gpt-5.6-sol')
    Check 'Preflight reports zero side effects' (
        [int]$preflight.sideEffects.planFilesCreated -eq 0 -and [int]$preflight.sideEffects.tokensMinted -eq 0 -and
        [int]$preflight.sideEffects.leasesCreated -eq 0 -and [int]$preflight.sideEffects.processesStarted -eq 0 -and
        [int]$preflight.sideEffects.modelsStarted -eq 0 -and [int]$preflight.sideEffects.providerWrites -eq 0)
    Check 'Preflight creates no output or lease' (-not (Test-Path $preflightOut) -and
        @(Get-ChildItem -LiteralPath $runRoot -Force | Where-Object { $_.Name -match $preflightLeasePattern }).Count -eq 0)
    Check 'Preflight changes no existing byte' (($before -join "`n") -ceq ($after -join "`n"))
    $generalistTransformation = Get-Content `
        (Join-Path $generalist.Out 'transformation-manifest.json') -Raw |
        ConvertFrom-Json -Depth 32
    $generalistSidecar = Get-Content (Join-Path $generalist.Out `
            "replay\$($generalist.Result.replaySnapshotName)\benchmark-pack-materialization.json") `
        -Raw | ConvertFrom-Json -Depth 32
    Check 'materialized bundle binds the second generalist in manifest and replay sidecar' (
        [string]$generalistTransformation.output.secondGeneralistModel -ceq 'gpt-5.6-sol' -and
        [string]$generalistSidecar.secondGeneralistModel -ceq 'gpt-5.6-sol')

    $secondModelTamperBundle = Join-Path $runRoot 'bundle-second-model-tampered'
    Copy-Item -LiteralPath $generalist.Out -Destination $secondModelTamperBundle -Recurse
    Get-ChildItem -LiteralPath $secondModelTamperBundle -File -Recurse -Force |
        ForEach-Object { $_.Attributes = [IO.FileAttributes]::Normal }
    $tamperedSidecarPath = Join-Path $secondModelTamperBundle `
        "replay\$($generalist.Result.replaySnapshotName)\benchmark-pack-materialization.json"
    $tamperedSidecar = Get-Content $tamperedSidecarPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 32
    $tamperedSidecar.secondGeneralistModel = 'gpt-5.6-terra'
    Write-Utf8 $tamperedSidecarPath (Canon $tamperedSidecar)
    Invoke-ExpectedFailure 'second-generalist bundle tamper blocks verification' {
        & pwsh -NoProfile -File $Tool -VerifyOnly -OutputRoot $secondModelTamperBundle `
            -ExpectedTransformationManifestSha256 $generalist.Result.transformationManifestSha256 `
            -RepoRoot $RepoRoot 2>&1
    } 'mismatch'

    $substitutedProjection = Join-Path $runRoot 'substituted-projection.json'
    $substitutedProjectionObject = Get-Content (Join-Path $generalist.Out 'projection.json') -Raw |
        ConvertFrom-Json -AsHashtable -Depth 64
    $substitutedProjectionObject.generalist.title = 'Substituted role stimulus'
    Write-Utf8 $substitutedProjection (ConvertTo-Json $substitutedProjectionObject -Depth 64)
    Invoke-ExpectedFailure 'Preflight rejects materialized projection substitution' {
        & $pwshPath -NoProfile -File $Acquire -Preflight -Role generalist `
            -FixtureProjectionFile $substitutedProjection -Model 'claude-opus-5' `
            -SecondGeneralistModel 'gpt-5.6-sol' `
            -ConfigFile (Join-Path $generalist.Out 'config\reviewer.config.json') `
            -ReplayRoot (Join-Path $generalist.Out 'replay') `
            -ReplaySnapshotName $generalist.Result.replaySnapshotName `
            -ReplayManifestDigest $generalist.Result.replayManifestDigest -ExpectedReviewerBaseCommit $head `
            -PullRequestId 4242 -ExpectedHeadCommit $head -ExpectedRef $ref `
            -OutputRoot (Join-Path $runRoot 'substituted-projection-output') -RepoRoot $RepoRoot `
            -AllowDirtyWorktree 2>&1
    } 'materialization does not bind the supplied projectionSha256'

    $substitutedBundle = Join-Path $runRoot 'bundle-substituted-config'
    Copy-Item -LiteralPath $generalist.Out -Destination $substitutedBundle -Recurse
    $substitutedConfig = Join-Path $substitutedBundle 'config\reviewer.config.json'
    (Get-Item -LiteralPath $substitutedConfig -Force).Attributes = [IO.FileAttributes]::Normal
    [IO.File]::AppendAllText($substitutedConfig, ' ', $Utf8)
    Invoke-ExpectedFailure 'Preflight rejects materialized config substitution' {
        & $pwshPath -NoProfile -File $Acquire -Preflight -Role generalist `
            -FixtureProjectionFile (Join-Path $substitutedBundle 'projection.json') -Model 'claude-opus-5' `
            -SecondGeneralistModel 'gpt-5.6-sol' `
            -ConfigFile $substitutedConfig -ReplayRoot (Join-Path $substitutedBundle 'replay') `
            -ReplaySnapshotName $generalist.Result.replaySnapshotName `
            -ReplayManifestDigest $generalist.Result.replayManifestDigest -ExpectedReviewerBaseCommit $head `
            -PullRequestId 4242 -ExpectedHeadCommit $head -ExpectedRef $ref `
            -OutputRoot (Join-Path $runRoot 'substituted-preflight-output') -RepoRoot $RepoRoot -AllowDirtyWorktree 2>&1
    } 'materialization does not bind the supplied configSha256'

    $missingPack = New-Pack -Name 'missing-role' -Role generalist
    $missingOut = Join-Path $runRoot 'missing-role-out'
    Invoke-ExpectedFailure 'missing role provenance blocks' {
        & pwsh -NoProfile -File $Tool -PackRoot $missingPack.Root -LegacyProjectionFile $missingPack.Projection `
            -Role generalist -RoleProvenanceFile (Join-Path $missingPack.Root 'does-not-exist.json') `
            -ReplaySnapshotPath $ReplayPath -ConfigFile $ConfigFile -PromptFile $PromptFile `
            -ExpectedReplayManifestFileSha256 $manifestSha -ExpectedConfigSha256 $configSha `
            -ExpectedPromptSha256 $promptSha -SecondGeneralistModel 'gpt-5.6-sol' `
            -OutputRoot $missingOut -RepoRoot $RepoRoot 2>&1
    } 'does not exist'
    Check 'missing provenance rejection writes no bundle' (-not (Test-Path $missingOut))

    $oraclePack = New-Pack -Name 'oracle-field' -Role generalist
    $oracleObj = Get-Content $oraclePack.Provenance -Raw | ConvertFrom-Json -AsHashtable -Depth 64
    $oracleObj.context['oracle'] = 'forbidden'
    Write-Utf8 $oraclePack.Provenance (ConvertTo-Json $oracleObj -Depth 64)
    $oracleSha = Sha $oraclePack.Provenance
    $oracleSealed = Join-Path (Split-Path $oraclePack.Provenance -Parent) "$oracleSha-role-generalist.json"
    Move-Item -LiteralPath $oraclePack.Provenance -Destination $oracleSealed
    $oracleProjection = Get-Content $oraclePack.Projection -Raw | ConvertFrom-Json -AsHashtable -Depth 64
    $oracleProjection.resources[1].sealedPath = "sealed-resources/$oracleSha-role-generalist.json"
    $oracleProjection.resources[1].sha256 = $oracleSha
    $oracleProjection.resources[1].byteLength = [long](Get-Item $oracleSealed).Length
    Write-Utf8 $oraclePack.Projection (ConvertTo-Json $oracleProjection -Depth 64)
    $oraclePack.Provenance = $oracleSealed
    Invoke-ExpectedFailure 'recursive oracle field blocks' {
        & pwsh -NoProfile -File $Tool @(Get-MaterializeArgs $oraclePack (Join-Path $runRoot 'oracle-out')) 2>&1
    } 'failed schema'

    $encodedPack = New-Pack -Name 'encoded-oracle' -Role specialist
    $encodedObj = Get-Content $encodedPack.Provenance -Raw | ConvertFrom-Json -AsHashtable -Depth 64
    $encodedObj.context.conventionPlanJson = '{"expectedDecision":"approve"}'
    Write-Utf8 $encodedPack.Provenance (ConvertTo-Json $encodedObj -Depth 64)
    $encodedSha = Sha $encodedPack.Provenance
    $encodedSealed = Join-Path (Split-Path $encodedPack.Provenance -Parent) "$encodedSha-role-specialist.json"
    Move-Item -LiteralPath $encodedPack.Provenance -Destination $encodedSealed
    $encodedProjection = Get-Content $encodedPack.Projection -Raw | ConvertFrom-Json -AsHashtable -Depth 64
    $encodedProjection.resources[1].sealedPath = "sealed-resources/$encodedSha-role-specialist.json"
    $encodedProjection.resources[1].sha256 = $encodedSha
    $encodedProjection.resources[1].byteLength = [long](Get-Item $encodedSealed).Length
    Write-Utf8 $encodedPack.Projection (ConvertTo-Json $encodedProjection -Depth 64)
    $encodedPack.Provenance = $encodedSealed
    Invoke-ExpectedFailure 'JSON-encoded oracle field blocks' {
        & pwsh -NoProfile -File $Tool @(Get-MaterializeArgs $encodedPack (Join-Path $runRoot 'encoded-out')) 2>&1
    } 'decoded JSON contains forbidden oracle/expected material'

    $pathPack = New-Pack -Name 'oracle-path' -Role generalist
    $pathObj = Get-Content $pathPack.Projection -Raw | ConvertFrom-Json -AsHashtable -Depth 64
    $pathObj.resources[1].sealedPath = 'sealed-resources/oracle/role.json'
    Write-Utf8 $pathPack.Projection (ConvertTo-Json $pathObj -Depth 64)
    Invoke-ExpectedFailure 'oracle path blocks' {
        & pwsh -NoProfile -File $Tool @(Get-MaterializeArgs $pathPack (Join-Path $runRoot 'oracle-path-out')) 2>&1
    } 'forbidden oracle/expected segment'

    $aliasPack = New-Pack -Name 'alias-path' -Role generalist
    $aliasObj = Get-Content $aliasPack.Projection -Raw | ConvertFrom-Json -AsHashtable -Depth 64
    $aliasObj.resources[1].sealedPath = 'sealed-resources/../role.json'
    Write-Utf8 $aliasPack.Projection (ConvertTo-Json $aliasObj -Depth 64)
    Invoke-ExpectedFailure 'path alias blocks' {
        & pwsh -NoProfile -File $Tool @(Get-MaterializeArgs $aliasPack (Join-Path $runRoot 'alias-out')) 2>&1
    } 'rooted, aliased, or traverses'

    $streamPack = New-Pack -Name 'stream-path' -Role generalist
    $streamObj = Get-Content $streamPack.Projection -Raw | ConvertFrom-Json -AsHashtable -Depth 64
    $streamObj.resources[1].sealedPath = 'sealed-resources/role.json:alternate'
    Write-Utf8 $streamPack.Projection (ConvertTo-Json $streamObj -Depth 64)
    Invoke-ExpectedFailure 'alternate-stream path blocks' {
        & pwsh -NoProfile -File $Tool @(Get-MaterializeArgs $streamPack (Join-Path $runRoot 'stream-out')) 2>&1
    } 'non-portable or alias-capable segment'

    $ambiguousPack = New-Pack -Name 'ambiguous' -Role generalist
    $ambiguousObj = Get-Content $ambiguousPack.Projection -Raw | ConvertFrom-Json -AsHashtable -Depth 64
    $ambiguousObj.resources += $ambiguousObj.resources[0].Clone()
    $ambiguousObj.resources[2].sealedPath = [string]$ambiguousObj.resources[0].sealedPath
    Write-Utf8 $ambiguousPack.Projection (ConvertTo-Json $ambiguousObj -Depth 64)
    Invoke-ExpectedFailure 'ambiguous duplicate provenance blocks' {
        & pwsh -NoProfile -File $Tool @(Get-MaterializeArgs $ambiguousPack (Join-Path $runRoot 'ambiguous-out')) 2>&1
    } 'repeats sealed resource'

    $conflictingPack = New-Pack -Name 'conflicting-role-provenance' -Role generalist
    $conflictingProjection = Get-Content $conflictingPack.Projection -Raw |
        ConvertFrom-Json -AsHashtable -Depth 64
    $existingRoleResource = $conflictingProjection.resources[1]
    $alternateRolePath = ([string]$existingRoleResource.sealedPath) -replace '\.json$', '-alternate.json'
    Copy-Item -LiteralPath $conflictingPack.Provenance `
        -Destination (Join-Path $conflictingPack.Root ($alternateRolePath -replace '/', '\'))
    $alternateRoleResource = $existingRoleResource.Clone()
    $alternateRoleResource.sealedPath = $alternateRolePath
    $conflictingProjection.resources += $alternateRoleResource
    Write-Utf8 $conflictingPack.Projection (ConvertTo-Json $conflictingProjection -Depth 64)
    Invoke-ExpectedFailure 'multiple role provenance resources block' {
        & pwsh -NoProfile -File $Tool @(Get-MaterializeArgs $conflictingPack (Join-Path $runRoot 'conflicting-role-out')) 2>&1
    } 'must seal exactly one role-provenance-generalist resource'

    $subPack = New-Pack -Name 'substitution' -Role generalist
    $subArgs = Get-MaterializeArgs $subPack (Join-Path $runRoot 'substitution-out')
    $badManifestSha = ('f' * 64)
    $subArgs[15] = $badManifestSha
    Invoke-ExpectedFailure 'replay substitution blocks' {
        & pwsh -NoProfile -File $Tool @subArgs 2>&1
    } 'operator-pinned manifest bytes'

    $promptPathPack = New-Pack -Name 'prompt-path' -Role generalist
    $alternatePrompt = Join-Path $promptPathPack.Root 'same-prompt-different-path.md'
    [IO.File]::WriteAllBytes($alternatePrompt, [IO.File]::ReadAllBytes($PromptFile))
    $promptPathArgs = Get-MaterializeArgs $promptPathPack (Join-Path $runRoot 'prompt-path-out')
    $promptPathArgs[13] = $alternatePrompt
    Invoke-ExpectedFailure 'prompt path substitution blocks' {
        & pwsh -NoProfile -File $Tool @promptPathArgs 2>&1
    } 'not the independently supplied prompt'

    $oversizedPack = New-Pack -Name 'oversized' -Role generalist
    $oversizedProjection = Get-Content $oversizedPack.Projection -Raw | ConvertFrom-Json -AsHashtable -Depth 64
    $oversizedProjection.resources = @(0..16 | ForEach-Object {
            [ordered]@{
                mediaRole = 'source-context'
                sealedPath = "sealed-resources/$('a' * 64)-declared-$_.json"
                sha256 = ('a' * 64)
                byteLength = 67108864
            }
        })
    Write-Utf8 $oversizedPack.Projection (ConvertTo-Json $oversizedProjection -Depth 64)
    Invoke-ExpectedFailure 'aggregate sealed-resource limit blocks' {
        & pwsh -NoProfile -File $Tool @(Get-MaterializeArgs $oversizedPack (Join-Path $runRoot 'oversized-out')) 2>&1
    } 'exceeding the 1073741824-byte materialization limit'

    $collisionPack = New-Pack -Name 'collision' -Role generalist
    $collisionOut = Join-Path $runRoot 'collision-out'
    New-Item -ItemType Directory -Path $collisionOut | Out-Null
    Invoke-ExpectedFailure 'existing output collision blocks' {
        & pwsh -NoProfile -File $Tool @(Get-MaterializeArgs $collisionPack $collisionOut) 2>&1
    } 'already exists'

    $concurrentPack = New-Pack -Name 'concurrent' -Role generalist
    $concurrentOut = Join-Path $runRoot 'concurrent-out'
    $concurrentHash = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
                $Utf8.GetBytes([IO.Path]::GetFullPath($concurrentOut))))).ToLowerInvariant().Substring(0, 16)
    $concurrentLock = Join-Path $runRoot ".concurrent-out.$concurrentHash.materialize.lock"
    Write-Utf8 $concurrentLock '{}'
    Invoke-ExpectedFailure 'concurrent publication lock blocks' {
        & pwsh -NoProfile -File $Tool @(Get-MaterializeArgs $concurrentPack $concurrentOut) 2>&1
    } 'concurrent or repeated publication is refused'
    Check 'concurrent loser writes no bundle' (-not (Test-Path $concurrentOut))

    $tamperBundle = $bundles.specialist
    $tamperPath = Join-Path $tamperBundle.Out 'projection.json'
    (Get-Item $tamperPath -Force).Attributes = [IO.FileAttributes]::Normal
    [IO.File]::AppendAllText($tamperPath, ' ', $Utf8)
    Invoke-ExpectedFailure 'tamper blocks verification' {
        & pwsh -NoProfile -File $Tool -VerifyOnly -OutputRoot $tamperBundle.Out `
            -ExpectedTransformationManifestSha256 $tamperBundle.Result.transformationManifestSha256 -RepoRoot $RepoRoot 2>&1
    } 'SHA-256 mismatch'

    $missingBundle = $bundles.verifier
    $missingPath = Join-Path $missingBundle.Out 'projection.json'
    (Get-Item $missingPath -Force).Attributes = [IO.FileAttributes]::Normal
    Remove-Item -LiteralPath $missingPath -Force
    Invoke-ExpectedFailure 'missing file blocks verification' {
        & pwsh -NoProfile -File $Tool -VerifyOnly -OutputRoot $missingBundle.Out `
            -ExpectedTransformationManifestSha256 $missingBundle.Result.transformationManifestSha256 -RepoRoot $RepoRoot 2>&1
    } 'missing bound file'

    $extraBundle = $bundles.generalist
    if ([OperatingSystem]::IsWindows()) {
        $adsPath = Join-Path $extraBundle.Out 'projection.json'
        (Get-Item -LiteralPath $adsPath -Force).Attributes = [IO.FileAttributes]::Normal
        Set-Content -LiteralPath $adsPath -Stream 'oracle' -Value '{}' -NoNewline
        (Get-Item -LiteralPath $adsPath -Force).Attributes = [IO.FileAttributes]::ReadOnly
        Invoke-ExpectedFailure 'alternate data stream blocks verification' {
            & pwsh -NoProfile -File $Tool -VerifyOnly -OutputRoot $extraBundle.Out `
                -ExpectedTransformationManifestSha256 $extraBundle.Result.transformationManifestSha256 -RepoRoot $RepoRoot 2>&1
        } 'contains alternate data stream'
        (Get-Item -LiteralPath $adsPath -Force).Attributes = [IO.FileAttributes]::Normal
        Remove-Item -LiteralPath $adsPath -Stream 'oracle' -Force
        (Get-Item -LiteralPath $adsPath -Force).Attributes = [IO.FileAttributes]::ReadOnly
    }
    $emptyDirectory = Join-Path $extraBundle.Out 'empty'
    New-Item -ItemType Directory -Path $emptyDirectory | Out-Null
    Invoke-ExpectedFailure 'extra empty directory blocks verification' {
        & pwsh -NoProfile -File $Tool -VerifyOnly -OutputRoot $extraBundle.Out `
            -ExpectedTransformationManifestSha256 $extraBundle.Result.transformationManifestSha256 -RepoRoot $RepoRoot 2>&1
    } 'extra unbound directory'
    Remove-Item -LiteralPath $emptyDirectory -Force
    $extraPath = Join-Path $extraBundle.Out 'extra.json'
    Write-Utf8 $extraPath '{}'
    (Get-Item $extraPath -Force).Attributes = (Get-Item $extraPath -Force).Attributes -bor [IO.FileAttributes]::ReadOnly
    Invoke-ExpectedFailure 'extra file blocks verification' {
        & pwsh -NoProfile -File $Tool -VerifyOnly -OutputRoot $extraBundle.Out `
            -ExpectedTransformationManifestSha256 $extraBundle.Result.transformationManifestSha256 -RepoRoot $RepoRoot 2>&1
    } 'extra unbound file'
}
finally {
    if ($tempRef) { & git -C $RepoRoot update-ref -d $tempRef 2>$null | Out-Null }
    Remove-Tree $runRoot
}

$failed = @($script:Results | Where-Object { -not $_.Ok })
Write-Host "`nReviewer benchmark-pack materializer: $($script:Results.Count - $failed.Count)/$($script:Results.Count) passed." `
    -ForegroundColor $(if ($failed.Count -eq 0) { 'Green' } else { 'Red' })
if ($failed.Count -gt 0) { exit 1 }
exit 0
