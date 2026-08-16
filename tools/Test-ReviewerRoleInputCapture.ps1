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
$ReviewerScript = Join-Path $RepoRoot 'src\Agents\reviewer\Start-ReviewerAgent.ps1'
$FixtureRoot = Join-Path $RepoRoot 'src\Agents\reviewer\testdata\exact-path'
$ReplayPath = Join-Path $RepoRoot 'src\Agents\reviewer\testdata\replay-v1\synthetic-pr'
$ConfigFile = Join-Path $FixtureRoot 'reviewer.config.json'
$PromptFile = Join-Path $RepoRoot 'src\Agents\reviewer\review-cycle.prompt.md'
$AdapterManifest = Join-Path $FixtureRoot 'adapter-manifest.json'
$GeneralistProjection = Join-Path $RepoRoot 'tools\testdata\reviewer-acquisition-generalist-projection.json'
$SchemaDir = Join-Path $RepoRoot 'src\Agents\reviewer\acquisition\v1'

Import-Module (Join-Path $RepoRoot 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force

$runId = [Guid]::NewGuid().ToString('N')
$runRoot = Join-Path $RepoRoot ("_role_input_test_tmp-" + $runId)

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
function Remove-Tree {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
            ForEach-Object { try { $_.Attributes = 'Normal' } catch { } }
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}
function Invoke-Tool {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $out = & pwsh -NoProfile -File $CaptureTool @Arguments 2>&1
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
# Synthetic legacy pack -> PR50 materializer -> non-promotable sealed bundle
# ---------------------------------------------------------------------------
$manifestPath = Join-Path $ReplayPath 'manifest.json'
$manifestSha = Sha $manifestPath
$configSha = Sha $ConfigFile
$promptSha = Sha $PromptFile
$scriptSha = Sha $ReviewerScript
$sourceManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 64
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
# The generalist role context is taken VERBATIM from the repo's own blinded
# generalist projection, so the capture and the PR49 adapter path are given
# byte-identical stimulus and their prompts are directly comparable.
$generalistFixture = Get-Content -LiteralPath $GeneralistProjection -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 64
$roleContexts = @{
    generalist = [ordered]@{
        sourceBranch             = [string]$generalistFixture.generalist.sourceBranch
        authorAlias              = [string]$generalistFixture.generalist.authorAlias
        title                    = [string]$generalistFixture.generalist.title
        threadDigestText         = [string]$generalistFixture.generalist.threadDigestText
        authoritativeSourcesText = [string]$generalistFixture.generalist.authoritativeSourcesText
        pinnedSourceText         = [string]$generalistFixture.generalist.pinnedSourceText
    }
    specialist = [ordered]@{ conventionPlanJson = '{"planVersion":1,"status":"synthetic"}'; factPlanJson = '{}' }
    verifier   = [ordered]@{
        targetCommit    = [string]$sourceManifest.binding.targetCommit
        changeSetDigest = [string]$sourceManifest.binding.changeSetSha256
        configSha256    = $configSha
        scriptSha256    = $scriptSha
        promptSha256    = $promptSha
    }
}

function New-CaptureBundle {
    <#
        Build a synthetic legacy benchmark pack and run it through PR50's
        materializer, producing exactly the artifact a capture consumes: a
        role-scoped blinded projection plus a permanently non-promotable sealed
        replay snapshot, config and prompt evidence.
    #>
    param([Parameter(Mandatory)][ValidateSet('generalist', 'specialist', 'verifier')][string]$Role,
        [string]$Tag = '')
    $name = if ($Tag) { "$Role-$Tag" } else { $Role }
    $packRoot = Join-Path $runRoot "pack-$name"
    $sealed = Join-Path $packRoot 'sealed-resources'
    New-Item -ItemType Directory -Force -Path $sealed | Out-Null
    $manifestSealed = Join-Path $sealed "$manifestSha-manifest.json"
    [IO.File]::WriteAllBytes($manifestSealed, [IO.File]::ReadAllBytes($manifestPath))
    $provenance = [ordered]@{
        schemaVersion = 1
        kind          = 'reviewer-model-visible-role-provenance'
        fixtureId     = "synthetic-$name-capture"
        role          = $Role
        bindingSha256 = TextSha (Canon $packBinding)
        configSha256  = $configSha
        scriptSha256  = $scriptSha
        promptSha256  = $promptSha
        context       = $roleContexts[$Role]
    }
    $provTmp = Join-Path $packRoot 'role.tmp.json'
    Write-Utf8 $provTmp (Canon $provenance)
    $provSha = Sha $provTmp
    $provSealed = Join-Path $sealed "$provSha-role-$Role.json"
    Move-Item -LiteralPath $provTmp -Destination $provSealed
    $legacy = [ordered]@{
        schemaVersion       = 1
        kind                = 'blinded-reviewer-adapter-input'
        fixtureId           = "synthetic-$name-capture"
        fixtureVersion      = 1
        binding             = $packBinding
        bindingSha256       = [string]$provenance.bindingSha256
        fixtureIndexBinding = [ordered]@{
            fixtureIndexSha256        = ('1' * 64)
            fixtureRecordHash         = ('2' * 64)
            originalFixtureFileSha256 = ('3' * 64)
        }
        resources           = @(
            [ordered]@{ mediaRole = 'replay-manifest'; sealedPath = "sealed-resources/$manifestSha-manifest.json"; sha256 = $manifestSha; byteLength = [long](Get-Item $manifestSealed).Length },
            [ordered]@{ mediaRole = "role-provenance-$Role"; sealedPath = "sealed-resources/$provSha-role-$Role.json"; sha256 = $provSha; byteLength = [long](Get-Item $provSealed).Length }
        )
    }
    $legacyFile = Join-Path $packRoot 'projections\fixture.blinded.json'
    Write-Utf8 $legacyFile (ConvertTo-Json $legacy -Depth 64)
    $out = Join-Path $runRoot "bundle-$name"
    $json = & pwsh -NoProfile -File $MaterializeTool @(
        '-PackRoot', $packRoot, '-LegacyProjectionFile', $legacyFile, '-Role', $Role,
        '-RoleProvenanceFile', $provSealed, '-ReplaySnapshotPath', $ReplayPath,
        '-ConfigFile', $ConfigFile, '-PromptFile', $PromptFile,
        '-ExpectedReplayManifestFileSha256', $manifestSha, '-ExpectedConfigSha256', $configSha,
        '-ExpectedPromptSha256', $promptSha, '-OutputRoot', $out, '-RepoRoot', $RepoRoot)
    if ($LASTEXITCODE -ne 0) { throw "materialization failed for $name : $($json -join '')" }
    $result = ($json -join '') | ConvertFrom-Json
    return [pscustomobject]@{
        Role         = $Role
        Root         = $out
        Projection   = Join-Path $out 'projection.json'
        ConfigFile   = Join-Path $out 'config\reviewer.config.json'
        ReplayRoot   = Join-Path $out 'replay'
        SnapshotName = [string]$result.replaySnapshotName
        Digest       = [string]$result.replayManifestDigest
        LegacyFile   = $legacyFile
    }
}

function Get-CaptureArgs {
    param([Parameter(Mandatory)]$Bundle, [Parameter(Mandatory)][string]$Out,
        [string]$Model = 'claude-opus-5', [string]$Role, [string]$Projection,
        [string]$ConfigOverride, [string]$RefOverride, [string]$HeadOverride, [string[]]$Extra = @())
    $a = @(
        '-Role', $(if ($Role) { $Role } else { $Bundle.Role }),
        '-Model', $Model,
        '-FixtureProjectionFile', $(if ($Projection) { $Projection } else { $Bundle.Projection }),
        '-ConfigFile', $(if ($ConfigOverride) { $ConfigOverride } else { $Bundle.ConfigFile }),
        '-ReplayRoot', $Bundle.ReplayRoot, '-ReplaySnapshotName', $Bundle.SnapshotName,
        '-ReplayManifestDigest', $Bundle.Digest, '-PullRequestId', '4242',
        '-ExpectedHeadCommit', $(if ($HeadOverride) { $HeadOverride } else { $head }),
        '-ExpectedRef', $(if ($RefOverride) { $RefOverride } else { $ref }),
        '-OutputRoot', $Out, '-RepoRoot', $RepoRoot
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

$exitCode = 0
try {
    Remove-Tree $runRoot
    New-Item -ItemType Directory -Force -Path $runRoot | Out-Null

    # -- 1. Generalist: the exact production prompt, and nothing else ---------
    Write-Host '1/8 generalist capture reaches the exact model boundary and launches nothing' -ForegroundColor Cyan
    $genBundle = New-CaptureBundle -Role generalist
    $genOut = Join-Path $runRoot 'capture-generalist'
    $gen = Invoke-Tool -Arguments (Get-CaptureArgs -Bundle $genBundle -Out $genOut)
    Check 'generalist capture succeeds' ($gen.ExitCode -eq 0) ($gen.Text -replace '\s+', ' ')
    $genResult = $null
    if ($gen.ExitCode -eq 0) {
        $genResult = (@($gen.Raw -split "`n") | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -First 1) | ConvertFrom-Json -Depth 32
    }
    Check 'supervisor proves zero model/agency/provider processes' (
        $null -ne $genResult -and [bool]$genResult.zeroSideEffects -and
        [int]$genResult.telemetry.childProcessStarts -eq 0 -and
        [int]$genResult.telemetry.modelOrAgencyStarts -eq 0 -and
        [int]$genResult.telemetry.providerLiveProcessStarts -eq 0 -and
        [int]$genResult.telemetry.providerLiveWrites -eq 0)

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
    $verify = Invoke-Tool -Arguments @('-VerifyOnly', '-OutputRoot', $genOut)
    Check 'read-only verification of the published bundle succeeds' ($verify.ExitCode -eq 0) ($verify.Text -replace '\s+', ' ')

    $tamperOut = Join-Path $runRoot 'capture-tampered'
    Copy-Item -LiteralPath $genOut -Destination $tamperOut -Recurse -Force
    Get-ChildItem -LiteralPath $tamperOut -Recurse -File -Force | ForEach-Object { $_.Attributes = 'Normal' }
    $tamperedPrompt = Join-Path $tamperOut 'role-input-prompt.txt'
    [IO.File]::WriteAllText($tamperedPrompt, ($promptText + "`nsubstituted stimulus"), $Utf8)
    Get-ChildItem -LiteralPath $tamperOut -Recurse -File -Force | ForEach-Object {
        $_.Attributes = $_.Attributes -bor [IO.FileAttributes]::ReadOnly
    }
    $tamper = Invoke-Tool -Arguments @('-VerifyOnly', '-OutputRoot', $tamperOut)
    Check 'a substituted prompt is detected by verification' ($tamper.ExitCode -ne 0 -and $tamper.Text -match 'changed|disagrees')

    $unboundOut = Join-Path $runRoot 'capture-unbound'
    Copy-Item -LiteralPath $genOut -Destination $unboundOut -Recurse -Force
    $extra = Join-Path $unboundOut 'smuggled.json'
    [IO.File]::WriteAllText($extra, '{"note":"unbound"}', $Utf8)
    (Get-Item -LiteralPath $extra).Attributes = 'ReadOnly'
    $unbound = Invoke-Tool -Arguments @('-VerifyOnly', '-OutputRoot', $unboundOut)
    Check 'an unbound smuggled file is detected by verification' ($unbound.ExitCode -ne 0 -and $unbound.Text -match 'unbound')

    # -- 3. Prompt-byte equivalence with the PR49 adapter path ---------------
    Write-Host '3/8 the captured prompt equals the PR49 adapter prompt for the equivalent fixture' -ForegroundColor Cyan
    $acqOut = Join-Path $runRoot 'acquisition-generalist'
    $acqConfigDir = Join-Path $runRoot 'acq-config'
    New-Item -ItemType Directory -Force -Path $acqConfigDir | Out-Null
    Copy-Item $ConfigFile (Join-Path $acqConfigDir 'reviewer.config.json') -Force
    Copy-Item $PromptFile (Join-Path $acqConfigDir 'review-cycle.prompt.md') -Force
    $replayRootV1 = Split-Path $ReplayPath -Parent
    $v1Digest = [string]((Get-Content $manifestPath -Raw | ConvertFrom-Json).manifestDigest)
    $acqRaw = & pwsh -NoProfile -File $AcquireTool @(
        '-Role', 'generalist', '-FixtureProjectionFile', $GeneralistProjection, '-Model', 'claude-opus-5',
        '-ConfigFile', (Join-Path $acqConfigDir 'reviewer.config.json'), '-ReplayRoot', $replayRootV1,
        '-ReplaySnapshotName', 'synthetic-pr', '-ReplayManifestDigest', $v1Digest,
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
        $aligned = $promptText.Replace($captureNonce, $acqNonce)
        Check 'the capture nonce actually occurs in the captured prompt' ($aligned -cne $promptText)
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

    # -- 4. Oracle and expected-decision refusal -----------------------------
    Write-Host '4/8 oracle and expected-decision inputs are refused recursively' -ForegroundColor Cyan
    $oracleDir = Join-Path $runRoot 'expected-oracle'
    New-Item -ItemType Directory -Force -Path $oracleDir | Out-Null
    Copy-Item -LiteralPath $genBundle.Projection -Destination (Join-Path $oracleDir 'projection.json') -Force
    Invoke-ExpectedFailure 'an oracle-named PATH is refused' `
        (Get-CaptureArgs -Bundle $genBundle -Out (Join-Path $runRoot 'capture-badpath') -Projection (Join-Path $oracleDir 'projection.json')) `
        'names an oracle'

    # Both key cases keep every PATH innocuous, so the refusal can only come from
    # the recursive KEY scan and not incidentally from the path scan.
    $keyedProjection = Join-Path $runRoot 'keyed-projection.json'
    $keyed = Get-Content -LiteralPath $genBundle.Projection -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 64
    $keyed['expectedDecision'] = 'approve'
    Write-Utf8 $keyedProjection (ConvertTo-Json $keyed -Depth 64)
    Invoke-ExpectedFailure 'a top-level oracle KEY is refused, naming the field' `
        (Get-CaptureArgs -Bundle $genBundle -Out (Join-Path $runRoot 'capture-keyed') -Projection $keyedProjection) `
        'expectedDecision'

    $nestedProjection = Join-Path $runRoot 'nested-projection.json'
    $nested = Get-Content -LiteralPath $genBundle.Projection -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 64
    $nested['generalist']['pinnedSourceText'] = 'plain stimulus'
    $nested['binding']['groundTruth'] = 'approve'
    Write-Utf8 $nestedProjection (ConvertTo-Json $nested -Depth 64)
    Invoke-ExpectedFailure 'a NESTED oracle key is refused, naming the field' `
        (Get-CaptureArgs -Bundle $genBundle -Out (Join-Path $runRoot 'capture-nested') -Projection $nestedProjection) `
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
        'not among the models'
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
    $wrongCfg = Invoke-Tool -Arguments (Get-CaptureArgs -Bundle $genBundle -Out (Join-Path $runRoot 'capture-wrong-config') -ConfigOverride $wrongConfig)
    Check 'a config bound to another repository is refused' (
        $wrongCfg.ExitCode -ne 0 -and $wrongCfg.Text -match 'bound to repository') $wrongCfg.Text

    $substituted = Join-Path $runRoot 'substituted-projection.json'
    $substitutedObject = Get-Content -LiteralPath $genBundle.Projection -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 64
    $substitutedObject.generalist.title = 'Substituted role stimulus'
    Write-Utf8 $substituted (ConvertTo-Json $substitutedObject -Depth 64)
    $subOut = Join-Path $runRoot 'capture-substituted'
    $sub = Invoke-Tool -Arguments (Get-CaptureArgs -Bundle $genBundle -Out $subOut -Projection $substituted)
    $subPrompt = ''
    if ($sub.ExitCode -eq 0) { $subPrompt = [IO.File]::ReadAllText((Join-Path $subOut 'role-input-prompt.txt'), $Utf8) }
    Check 'a substituted stimulus produces a different prompt, never the original' (
        $sub.ExitCode -ne 0 -or ((TextSha $subPrompt) -cne (TextSha $promptText)))

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
        Role = 'generalist'; Root = $genBundle.Root; Projection = $genBundle.Projection
        ConfigFile = $genBundle.ConfigFile; ReplayRoot = $strippedRoot
        SnapshotName = $genBundle.SnapshotName; Digest = $genBundle.Digest; LegacyFile = $genBundle.LegacyFile
    }
    $missingOut = Join-Path $runRoot 'capture-missing-payload'
    $missing = Invoke-Tool -Arguments (Get-CaptureArgs -Bundle $strippedBundle -Out $missingOut)
    Check 'a sealed snapshot missing a payload fails closed' ($missing.ExitCode -ne 0) $missing.Text
    Check 'a failed-closed capture publishes no bundle and falls back to nothing live' (
        -not (Test-Path -LiteralPath $missingOut) -or
        -not (Test-Path -LiteralPath (Join-Path $missingOut 'capture-manifest.json')))

    $promotableBundle = [pscustomobject]@{
        Role = 'generalist'; Root = $genBundle.Root; Projection = $GeneralistProjection
        ConfigFile = $ConfigFile; ReplayRoot = $replayRootV1
        SnapshotName = 'synthetic-pr'; Digest = $v1Digest; LegacyFile = $genBundle.LegacyFile
    }
    Invoke-ExpectedFailure 'an UNSEALED (promotable) snapshot is refused' `
        (Get-CaptureArgs -Bundle $promotableBundle -Out (Join-Path $runRoot 'capture-promotable')) `
        'is promotable'

    # -- 7. Concurrency and atomicity ---------------------------------------
    Write-Host '7/8 a capture is atomic and never overwrites a published bundle' -ForegroundColor Cyan
    $again = Invoke-Tool -Arguments (Get-CaptureArgs -Bundle $genBundle -Out $genOut)
    Check 'a second capture into a published root is refused' (
        $again.ExitCode -ne 0 -and $again.Text -like '*already exists*') ($again.Text -replace '\s+', ' ')
    Check 'the published bundle survived the refused re-run byte for byte' (
        (Sha (Join-Path $genOut 'capture-manifest.json')) -ceq (Sha (Join-Path $genOut 'capture-manifest.json')) -and
        (TextSha ([IO.File]::ReadAllText((Join-Path $genOut 'role-input-prompt.txt'), $Utf8))) -ceq (TextSha $promptText))
    Check 'no staging directory was left behind' (
        @(Get-ChildItem -LiteralPath $runRoot -Force -Directory |
                Where-Object { $_.Name -like '*.capture-work' -or $_.Name -like '*staging*' }).Count -eq 0)

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

    # -- 9. Specialist and verifier always land on a TYPED outcome -----------
    Write-Host '9/9 specialist and verifier land on a typed outcome, never on fabrication' -ForegroundColor Cyan
    $specBundle = New-CaptureBundle -Role specialist
    $roleCases = @(
        @{ Role = 'specialist'; Bundle = $specBundle; Model = 'claude-opus-5'; Extra = @() },
        @{ Role = 'verifier'; Bundle = $verBundle; Model = 'claude-opus-5'; Extra = @(
                '-CandidateInputFile', (Join-Path $RepoRoot 'tools\testdata\reviewer-acquisition-discovery-candidate.json')) }
    )
    foreach ($case in $roleCases) {
        $role = [string]$case.Role
        $out = Join-Path $runRoot "capture-$role-typed"
        $r = Invoke-Tool -Arguments (Get-CaptureArgs -Bundle $case.Bundle -Out $out -Model ([string]$case.Model) -Extra ([string[]]$case.Extra))
        $readyBundle = Join-Path $out 'capture-manifest.json'
        $blocked = Join-Path $out 'capture-blocked.json'
        $isReady = Test-Path -LiteralPath $readyBundle
        $isBlocked = Test-Path -LiteralPath $blocked
        Check "$role capture lands on exactly one typed artifact" (
            ($isReady -bxor $isBlocked) -or (-not $isReady -and -not $isBlocked -and $r.ExitCode -ne 0)) $r.Text
        if ($isReady) {
            $m = Get-Content $readyBundle -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 64
            Check "$role capture reached the boundary exactly once and started nothing" (
                [int]$m.launch.boundaryHits -eq 1 -and [string]$m.role -ceq $role -and
                @($m.sideEffects.PSObject.Properties | Where-Object { [int]$_.Value -ne 0 }).Count -eq 0)
            $v = Invoke-Tool -Arguments @('-VerifyOnly', '-OutputRoot', $out)
            Check "$role bundle re-verifies independently" ($v.ExitCode -eq 0) $v.Text
        }
        elseif ($isBlocked) {
            $b = Get-Content $blocked -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 64
            Check "$role blocker is typed, reaches no boundary and invents nothing" (
                @('blocked', 'degraded') -ccontains [string]$b.status -and
                [int]$b.boundaryHits -eq 0 -and [string]$b.blockedReason -and -not [bool]$b.ready -and
                @($b.sideEffects.PSObject.Properties | Where-Object { [int]$_.Value -ne 0 }).Count -eq 0) `
                "status=$([string]$b.status) reason=$([string]$b.blockedReason)"
            Check "$role blocker publishes no prompt it could not legitimately build" (
                -not (Test-Path -LiteralPath (Join-Path $out 'role-input-prompt.txt')))
            $bv = Invoke-Tool -Arguments @('-VerifyOnly', '-OutputRoot', $out)
            Check "$role typed blocker re-verifies independently" ($bv.ExitCode -eq 0) $bv.Text
        }
        else {
            Check "$role refusal names its cause and leaves nothing behind" (
                $r.ExitCode -ne 0 -and -not (Test-Path -LiteralPath $out)) $r.Text
        }
    }

    # -- Schemas are versioned and strict ------------------------------------
    foreach ($schema in @('role-input-capture.schema.json', 'role-input-capture-blocked.schema.json')) {
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
