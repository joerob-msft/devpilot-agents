#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Builds an offline sandbox and the typed request that drives the shadow run
    coordinator to run-set-ready.

.DESCRIPTION
    Test support, dot-sourced rather than run. The sandbox is a real reviewer
    build under real git, a real sealed corpus snapshot, and a real reviewer
    config, because the coordinator's whole claim is that it prepares REAL
    evidence without launching a model. A sandbox that stubbed the sealer or the
    qualification tool would prove nothing about that claim.

    The subject identity is employer-neutral throughout, and the snapshot is
    keyed on the repository NAME because that is what a reviewer passes as
    repositoryId on its opening bounded read.

    Nothing here launches a model or writes outside the sandbox it is given.
#>

Set-StrictMode -Version Latest

function Invoke-ShadowFixtureGit {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Arguments)
    & git -C $Path @Arguments 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed in $Path." }
}

function New-ShadowCoordinatorSandbox {
    <#
    .SYNOPSIS
        Copies the toolkit into the sandbox and commits it, so the coordinator
        can pin an exact head the way a real run does.

    .DESCRIPTION
        Hermetic on purpose: an operator's hooks, signing key or global config
        must not decide whether a qualification passes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Sandbox,
        [Parameter(Mandatory)][string]$ToolkitRoot
    )
    $toolkitCopy = Join-Path $Sandbox 'toolkit'
    [void](New-Item -ItemType Directory -Force -Path $toolkitCopy)
    Copy-Item -Recurse -Force (Join-Path $ToolkitRoot 'src') (Join-Path $toolkitCopy 'src')
    Copy-Item -Recurse -Force (Join-Path $ToolkitRoot 'tools') (Join-Path $toolkitCopy 'tools')
    Copy-Item -Recurse -Force (Join-Path $ToolkitRoot 'samples') (Join-Path $toolkitCopy 'samples')

    # Build outputs are not part of the reviewed build's identity, and copying
    # them would make the pinned head depend on whether someone had built.
    $stale = Join-Path $toolkitCopy 'tools\ShadowRunCoordinator'
    foreach ($name in @('bin', 'obj')) {
        $path = Join-Path $stale $name
        if (Test-Path -LiteralPath $path) { Remove-Item -Recurse -Force -LiteralPath $path }
    }

    $hooks = Join-Path $Sandbox 'empty-hooks'
    [void](New-Item -ItemType Directory -Force -Path $hooks)
    Invoke-ShadowFixtureGit -Path $toolkitCopy -Arguments @('init', '--quiet')
    Invoke-ShadowFixtureGit -Path $toolkitCopy -Arguments @('config', 'core.hooksPath', $hooks)
    Invoke-ShadowFixtureGit -Path $toolkitCopy -Arguments @('config', 'commit.gpgsign', 'false')
    Invoke-ShadowFixtureGit -Path $toolkitCopy -Arguments @('config', 'user.name', 'Shadow Coordinator Test')
    Invoke-ShadowFixtureGit -Path $toolkitCopy -Arguments @('config', 'user.email', 'shadow@example.invalid')
    Invoke-ShadowFixtureGit -Path $toolkitCopy -Arguments @('add', '--all')
    Invoke-ShadowFixtureGit -Path $toolkitCopy -Arguments @('commit', '--quiet', '-m', 'reviewer build under shadow preparation')
    $head = (& git -C $toolkitCopy rev-parse HEAD).Trim()
    Invoke-ShadowFixtureGit -Path $toolkitCopy -Arguments @('branch', 'reviewer-layer', $head)
    Invoke-ShadowFixtureGit -Path $toolkitCopy -Arguments @('checkout', '--quiet', '-b', 'generated-app-worktree')

    return [pscustomobject][ordered]@{
        ToolkitCopy = [string]([IO.Path]::GetFullPath($toolkitCopy))
        Head = $head
        RequiredRef = 'refs/heads/reviewer-layer'
    }
}

function New-ShadowCoordinatorReviewerConfig {
    <#
    .SYNOPSIS
        A reviewer config bound to the fixture's synthetic subject.

    .DESCRIPTION
        Lives outside the reviewed repository, like the real ones. The repository
        project and name must match the corpus recipe's opening read or the
        preflight will ask for a read the snapshot does not carry.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ToolkitRoot,
        [Parameter(Mandatory)]$Identity
    )
    $config = Get-Content -LiteralPath (Join-Path $ToolkitRoot 'samples\reviewer-ado.config.json') -Raw | ConvertFrom-Json
    $config.repository.organization = $Identity.Organization
    $config.repository.project = $Identity.Project
    $config.repository.name = $Identity.RepositoryName
    $config.repository.id = $Identity.RepositoryId

    # Qualification refuses to infer the specialist and verifier passes from a
    # CLI default, so the config must name them. They are DERIVED from the
    # supported registry rather than written down, so a registry change cannot
    # leave a retired build named here.
    $pair = Get-AgentGeneralistModelPair
    # Bound without an array wrapper on purpose: the registry emits its list
    # un-enumerated, so wrapping it would nest the array inside another one.
    $supported = Get-AgentSupportedModels
    $specialist = [string](@($supported | Where-Object { $_ -cne $pair.First -and $_ -cne $pair.Second }) |
            Select-Object -First 1)
    if (-not $specialist) { $specialist = [string]$pair.Second }
    $config.review.conventionSpecialistModel = $specialist
    $config.review.verification.enabled = $true
    $config.review.verification.conventionVerifierModel = $pair.Second

    [void](New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent))
    Set-Content -LiteralPath $Path -Encoding utf8NoBOM -Value (ConvertTo-Json -InputObject $config -Depth 20 -Compress:$false)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-ShadowCoordinatorPromptAssetDigest {
    <#
    .SYNOPSIS
        The digest the coordinator binds a run's prompts by.

    .DESCRIPTION
        Computed here through the toolkit's own canonicalizer, deliberately: the
        coordinator computes the same value in C#, so agreement between the two
        is a real cross-implementation parity check rather than a restatement of
        one implementation. Only file names and digests take part, so binding a
        run to its prompts never reads prompt text into a decision.
    #>
    param([Parameter(Mandatory)][string]$ToolkitRoot)
    $directory = Join-Path $ToolkitRoot 'src\Agents\reviewer'
    $files = @(Get-ChildItem -LiteralPath $directory -Filter '*.prompt.md' -File |
            Sort-Object -Property Name -CaseSensitive)
    if ($files.Count -eq 0) { throw "'$directory' holds no reviewer prompt asset to bind the run to." }
    $list = @($files | ForEach-Object {
            [ordered]@{
                name = $_.Name
                sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        })
    $canonical = ConvertTo-AgentReplayCanonicalJson -Value $list
    $bytes = [System.Text.UTF8Encoding]::new($false, $true).GetBytes($canonical)
    return ([BitConverter]::ToString([System.Security.Cryptography.SHA256]::HashData($bytes)) -replace '-', '').ToLowerInvariant()
}

function New-ShadowCoordinatorRequestFile {
    <#
    .SYNOPSIS
        Writes the typed coordinator request as strict UTF-8 without a byte-order
        mark, which is the only encoding the coordinator accepts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Request
    )
    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    [void](New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent))
    [System.IO.File]::WriteAllBytes($Path, $utf8.GetBytes((ConvertTo-Json -InputObject $Request -Depth 12 -Compress:$false)))
    return [string]([IO.Path]::GetFullPath($Path))
}

function Publish-ShadowCoordinatorLaunchToken {
    <#
    .SYNOPSIS
        Moves the declaration's published launch-authorization token to the
        operator-held path the request names.

    .DESCRIPTION
        Deliberately a copy of the PUBLISHED token rather than a fresh 64-hex
        string: the slot step compares what the request presents against what the
        run set published, and a fixture that minted its own value would test the
        comparison against a constant instead of against the declaration.

    .PARAMETER Corrupt
        Write a well-formed but different token, for the refusal path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunSetDirectory,
        [Parameter(Mandatory)][string]$TokenPath,
        [switch]$Corrupt
    )
    $published = Join-Path $RunSetDirectory 'launch-authorization.token'
    if (-not (Test-Path -LiteralPath $published -PathType Leaf)) {
        throw "The run set under '$RunSetDirectory' published no launch-authorization token to hand over."
    }
    $token = ([IO.File]::ReadAllText($published)).Trim()
    if ($Corrupt) {
        $bytes = [byte[]]::new(32)
        [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
        $token = ([BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
    }
    [void](New-Item -ItemType Directory -Force -Path (Split-Path $TokenPath -Parent))
    [IO.File]::WriteAllBytes($TokenPath, ([Text.UTF8Encoding]::new($false)).GetBytes($token))
    return [string]([IO.Path]::GetFullPath($TokenPath))
}

function New-ShadowCoordinatorFixture {
    <#
    .SYNOPSIS
        Builds everything one coordinator run needs and returns the request path.

    .PARAMETER Sandbox
        A directory OUTSIDE the toolkit repository. The corpus sealer refuses a
        corpus inside it, which is the guard that keeps private evidence out of
        the repository, and the fixture is held to the same rule.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Sandbox,
        [Parameter(Mandatory)][string]$ToolkitRoot,
        [string]$CorrelationId = ('shadow-' + [Guid]::NewGuid().ToString('N').Substring(0, 12)),
        [ValidateRange(1, 14400)][int]$ChildTimeoutSeconds = 900,
        [switch]$ShadowSlotEnabled,
        # Build the corpus through the typed control plane instead of handing the
        # coordinator one that already exists. The source corpus is written
        # read-only, which is what a real captured corpus is.
        [switch]$StageCorpus,
        [ValidateRange(30, 3600)][int]$SupervisionGraceSeconds = 60
    )

    [void](New-Item -ItemType Directory -Force -Path $Sandbox)
    $build = New-ShadowCoordinatorSandbox -Sandbox $Sandbox -ToolkitRoot $ToolkitRoot
    $corpus = New-ReviewerCorpusSealFixture -Root $Sandbox -ToolkitRoot $ToolkitRoot `
        -AsImmutableSource:$StageCorpus.IsPresent
    $identity = $corpus.Identity

    $configPath = Join-Path $Sandbox 'inputs\reviewer.config.json'
    $configSha = New-ShadowCoordinatorReviewerConfig -Path $configPath -ToolkitRoot $ToolkitRoot -Identity $identity

    $reviewedRepo = Join-Path $Sandbox 'reviewed-repo'
    [void](New-Item -ItemType Directory -Force -Path $reviewedRepo)

    # The run-set signing key, written in the toolkit's own "<format>:<base64>"
    # storage form. Stored raw rather than DPAPI-protected because a fixture key
    # guards nothing and must not depend on the host's protection store; it is
    # random per sandbox and never leaves it.
    $keyPath = Join-Path $Sandbox 'inputs\run-set.key'
    $keyBytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($keyBytes)
    [void](New-Item -ItemType Directory -Force -Path (Split-Path $keyPath -Parent))
    Set-Content -LiteralPath $keyPath -Encoding ascii -NoNewline `
        -Value ('raw:' + [Convert]::ToBase64String($keyBytes))

    # Digests are taken from the SANDBOX build, which is the build the request
    # pins and the coordinator will read.
    $schemaPath = Join-Path $build.ToolkitCopy 'src\Agents\reviewer\schemas\reviewer.stage-producer-contracts.v1.json'
    $schemaSha = (Get-FileHash -LiteralPath $schemaPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $promptSha = Get-ShadowCoordinatorPromptAssetDigest -ToolkitRoot $build.ToolkitCopy

    # The changed-path census the request declares. The coordinator validates and
    # passes it through rather than inventing one, so the fixture has to supply a
    # real file, exactly as a production caller would.
    $changedPathsPath = Join-Path $Sandbox 'inputs\changed-paths.json'
    $changedPaths = [ordered]@{
        contractVersion = 'devpilot.shadow-run-coordinator.changed-paths.v1'
        kind = 'shadow-run-coordinator-changed-paths'
        changedPaths = @($corpus.ChangedPaths)
    }
    $changedPathsText = (ConvertTo-Json -InputObject ([pscustomobject]$changedPaths) -Depth 8 -Compress:$false) + "`n"
    [IO.File]::WriteAllBytes($changedPathsPath,
        ([Text.UTF8Encoding]::new($false)).GetBytes($changedPathsText))

    # Named, not created. The declaration mints this token; an operator moves it
    # here out of band. Creating it now would let a slot launch on a token no
    # declaration ever published, which is the exact authorization the one-shot
    # lease exists to make impossible.
    $launchTokenPath = Join-Path $Sandbox 'inputs\launch-authorization.token'

    $outputRoot = [string]([IO.Path]::GetFullPath((Join-Path $Sandbox 'shadow-output')))

    # The stage declaration, written only when this run is the one that builds
    # the corpus. Absent otherwise, which is what every request written before
    # this slice says and what the PowerShell corpus path keeps saying.
    $stage = $null
    if ($StageCorpus.IsPresent) {
        $stage = New-ReviewerCorpusStageRequestFile `
            -Path (Join-Path $Sandbox 'inputs\corpus-stage.json') `
            -SourceCorpusRoot $corpus.SourceCorpusRoot `
            -DestinationCorpusRoot $corpus.CorpusRoot `
            -OutputRoot $outputRoot `
            -CorrelationId $CorrelationId `
            -ToolkitHead $build.Head `
            -IndexSha256 $corpus.CorpusIndexSha256 `
            -Identity $identity `
            -Content $corpus.Content
    }

    $request = @{
        contractVersion = 'devpilot.shadow-run-coordinator.request.v1'
        kind = 'shadow-run-preparation'
        correlationId = $CorrelationId
        toolkit = @{ repositoryRoot = $build.ToolkitCopy; head = $build.Head }
        subject = @{
            organization = $identity.Organization
            project = $identity.Project
            repository = $identity.RepositoryName
            pullRequestId = $identity.PullRequestId
            iterationId = $identity.IterationId
            sourceCommit = $identity.SourceCommit
            commonCommit = $identity.CommonCommit
            targetCommit = $identity.TargetCommit
        }
        digests = @{ configSha256 = $configSha; promptSha256 = $promptSha; schemaSha256 = $schemaSha }
        corpus = @{
            root = $corpus.CorpusRoot
            indexSha256 = $corpus.CorpusIndexSha256
            recipePath = $corpus.RecipePath
            changedPathsPath = [string]([IO.Path]::GetFullPath($changedPathsPath))
        }
        output = @{ root = $outputRoot }
        children = @{
            powerShellPath = [string](Get-Process -Id $PID).Path
            timeoutSeconds = $ChildTimeoutSeconds
        }
        qualification = @{
            operatorAlias = 'example-operator'
            reviewerConfigPath = [string]([IO.Path]::GetFullPath($configPath))
            reviewerRepositoryPath = [string]([IO.Path]::GetFullPath($reviewedRepo))
            expectedCommit = $build.Head
            requiredRef = $build.RequiredRef
            plannedRunCount = 2
            runSetKeyPath = [string]([IO.Path]::GetFullPath($keyPath))
        }
        # The slot authorization is a SEPARATE section from the qualification one
        # on purpose. Preparation is authorized by the request; starting a run is
        # authorized by an operator who also holds the single-use token, and the
        # token file named here does not exist yet - it is minted by the
        # declaration this request has not made. A fixture that pre-created it
        # would be describing a run set nobody declared.
        slot = @{
            shadowSlotEnabled = $ShadowSlotEnabled.IsPresent
            name = 'slot1'
            reviewerScriptPath = [string]([IO.Path]::GetFullPath(
                    (Join-Path $build.ToolkitCopy 'src\Agents\reviewer\Start-ReviewerAgent.ps1')))
            launchAuthorizationTokenPath = [string]([IO.Path]::GetFullPath($launchTokenPath))
            supervisionGraceSeconds = $SupervisionGraceSeconds
        }
    }

    if ($stage) {
        $request.Add('corpusStage', @{
                stagingEnabled = $true
                requestPath = $stage.Path
                requestSha256 = $stage.Sha256
            })
    }

    $requestPath = New-ShadowCoordinatorRequestFile -Path (Join-Path $Sandbox 'inputs\request.json') -Request $request

    return [pscustomobject][ordered]@{
        Sandbox = [string]([IO.Path]::GetFullPath($Sandbox))
        ToolkitCopy = $build.ToolkitCopy
        Head = $build.Head
        RequiredRef = $build.RequiredRef
        Identity = $identity
        CorpusRoot = $corpus.CorpusRoot
        SourceCorpusRoot = $corpus.SourceCorpusRoot
        StageRequestPath = $(if ($stage) { $stage.Path } else { $null })
        StageRequestSha256 = $(if ($stage) { $stage.Sha256 } else { $null })
        StagePayloadCount = $(if ($stage) { $stage.PayloadCount } else { 0 })
        CorpusIndexSha256 = $corpus.CorpusIndexSha256
        RecipePath = $corpus.RecipePath
        ChangedPathsPath = [string]([IO.Path]::GetFullPath($changedPathsPath))
        SnapshotName = $corpus.SnapshotName
        ConfigPath = [string]([IO.Path]::GetFullPath($configPath))
        RunSetKeyPath = [string]([IO.Path]::GetFullPath($keyPath))
        LaunchTokenPath = [string]([IO.Path]::GetFullPath($launchTokenPath))
        RunSetDirectory = [string]([IO.Path]::GetFullPath(
                (Join-Path $request.output.root 'qualification\runset')))
        ReviewerScriptPath = [string]$request.slot.reviewerScriptPath
        OutputRoot = [string]$request.output.root
        CorrelationId = $CorrelationId
        RequestPath = $requestPath
        Request = $request
    }
}
