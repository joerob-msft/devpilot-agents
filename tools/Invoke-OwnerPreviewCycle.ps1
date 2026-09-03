#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Previews the bpm-test-ownership@1 convention over ONE pull request, with no
    generalist, no provider write, and no second implementation of anything.

.DESCRIPTION
    This tool is deliberately thin. Every step it performs is an existing,
    reviewed production tool; what this adds is the paperwork between them - the
    three request documents they read, the hashes that bind those documents to
    each other, and the subject identity the evidence is filed under.

    `prepare` reads the pull request. It runs the typed cohort-entry evidence
    builder, which opens the same agency-wrapped read-only session the reviewer
    opens and issues exactly the plan it declared and nothing else. The request
    carries no execution plan, so the builder emits the preparation-only shape
    with no slots section at all - no slots means no generalist, which is why
    this preview costs one specialist start rather than three model runs whose
    verdict it would then have to throw away. The corpus that capture produces is
    then sealed into a permanently non-promotable snapshot.

    `run` reads only what `prepare` sealed. Production role capture builds the
    specialist stimulus, the benchmark-pack materializer binds it, and blinded
    acquisition starts the one model under its own supervision, timeouts and
    zero-write telemetry. The result marker is parsed by the reviewer's own v4
    parser.

    NOTHING HERE CAN WRITE. Not as a policy - as a shape. The builder's verbs are
    reads, acquisition refuses a snapshot that is not sealed non-promotable, and
    the run refuses to start at all if any delivery capability is live.

    The report says what ONE capability checked. It carries no vote, no severity
    and no pass/fail, because a layer that checked one convention is not in a
    position to say a pull request is fine.

.PARAMETER Action
    prepare      Read the pull request and seal an immutable subject package.
    run          Run the specialist over a prepared subject and write a preview.
    prepare-run  Both, in one shot.
    status       Print the capability report for an already-run subject.

.PARAMETER SubjectRoot
    The absolute evidence root. Required and absolute, and refused if it sits
    inside a git working tree: captured pull request bytes are private evidence
    and must not live where a commit could publish them.

.PARAMETER RuleCommit
    The commit the ownership rule sections are pinned at. The convention pack
    pins the rule by BRANCH, and a rule bundle section has to name a commit, so
    the operator states it. A wrong value is not a silent hazard: the builder
    reads the section and refuses it when the bytes disagree with the pin.

.OUTPUTS
    One JSON summary line on stdout. Exit codes:
      0  the action completed
      1  the tool was used incorrectly, or a step refused
      2  the pass ran but did not reach a schema-valid result marker
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('prepare', 'run', 'prepare-run', 'status')]
    [string]$Action,

    [Parameter(Mandatory)][string]$SubjectRoot,

    [ValidateRange(1, 2147483647)][int]$PullRequestId = 0,
    [string]$Organization = '',
    [string]$Project = '',
    [string]$RepositoryId = '',
    [string]$RepositoryName = '',
    [string]$TargetRefName = '',
    [ValidatePattern('^$|^[0-9a-fA-F]{40}$')][string]$RuleCommit = '',

    [string]$ConfigFile = '',
    [string]$PromptFile = '',
    [string]$ToolkitRoot = '',
    [string]$RepositoryPath = '',
    [ValidatePattern('^$|^[A-Za-z0-9][A-Za-z0-9._-]{2,63}$')][string]$OperatorAlias = 'owner-preview',
    [string]$Model = '',

    [ValidateSet('live', 'replay')][string]$CaptureMode = 'live',
    [string]$AgencyPath = '',
    [string]$SourceReplayRoot = '',
    [string]$SourceReplaySnapshotName = '',
    [ValidatePattern('^$|^[0-9a-fA-F]{64}$')][string]$SourceReplayManifestDigest = '',

    [ValidatePattern('^$|^[0-9a-f]{64}$')][string]$HeadKey = '',
    [ValidatePattern('^$|^[0-9a-fA-F]{40}$')][string]$ExpectedReviewerBaseCommit = '',
    [string]$ExpectedRef = '',
    [string]$ToolkitRequiredRef = '',
    [string]$SourceRefName = '',
    [string]$DiscoveryGeneralistModel = '',
    [string]$SealKeyRoot = '',
    [string]$SecondGeneralistModel = 'gpt-5.6-sol',

    [switch]$UseOfflineStubAdapter,
    [string]$OfflineModelAdapterManifest = '',

    [ValidateRange(5, 3600)][int]$PerCallTimeoutSeconds = 120,
    [ValidateRange(10, 7200)][int]$ActivityTimeoutSeconds = 600,
    [ValidateRange(10, 7200)][int]$TotalTimeoutSeconds = 1800,
    [ValidateRange(1, 14400)][int]$ChildTimeoutSeconds = 900,

    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $RepoRoot 'src/DevPilot.AgentHarness/DevPilot.AgentHarness.psd1') -Force
. (Join-Path $RepoRoot 'src/Agents/reviewer/CorpusSeal.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/ConventionSpecialist.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/AcquisitionPackage.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/OwnerPreviewSubject.ps1')
. (Join-Path $RepoRoot 'src/Agents/reviewer/OwnerPreviewReport.ps1')

$script:OwnerPreviewCapability = 'bpm-test-ownership@1'

function Assert-OwnerPreviewParameter {
    <# One required-for-this-action parameter, named in the refusal. #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ForAction
    )
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "-$Name is required for -Action $ForAction."
    }
    return $Value
}

function Invoke-OwnerPreviewTool {
    <#
        One existing production tool, in its own process.

        Separate processes rather than dot-sourcing: these tools set their own
        strict mode, error preference and script state, and several of them exit
        rather than return. Borrowing their functions would mean inheriting all
        of that into this one.
    #>
    param(
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ToolArguments,
        [Parameter(Mandatory)][string]$Stage
    )
    $toolPath = Join-Path $RepoRoot $Tool
    if (-not (Test-Path -LiteralPath $toolPath -PathType Leaf)) {
        throw "The Owner preview expected the production tool '$Tool' at '$toolPath'."
    }
    $invocation = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $toolPath) + @($ToolArguments)
    [void](Assert-OwnerPreviewNoWriteArgument -ToolArguments $ToolArguments -Stage $Stage)
    $captured = & pwsh @invocation 2>&1
    $exit = $LASTEXITCODE
    $text = (@($captured) | Out-String).Trim()
    if ($exit -ne 0) {
        throw "The $Stage step refused (exit $exit): $text"
    }
    return $text
}

function Get-OwnerPreviewJsonLine {
    <#
        The last JSON object a tool printed.

        These tools print prose for an operator and one machine-readable line for
        automation. Taking the last balanced-looking line rather than the whole
        stream means a progress message can never be parsed as a result.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $lines = @($Text -split "`r?`n")
    for ($index = $lines.Count - 1; $index -ge 0; $index--) {
        $candidate = $lines[$index].Trim()
        if ($candidate.StartsWith('{') -and $candidate.EndsWith('}')) {
            return ($candidate | ConvertFrom-Json -Depth 64)
        }
    }
    throw "No machine-readable summary line was found in tool output: $Text"
}

function Get-OwnerPreviewToolkitHead {
    <# The toolkit commit this preview ran from. #>
    param([Parameter(Mandatory)][string]$Root)
    Push-Location -LiteralPath $Root
    try {
        $head = (& git rev-parse HEAD 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "Could not resolve the toolkit head at '$Root': $head" }
        return ([string]$head).Trim().ToLowerInvariant()
    }
    finally { Pop-Location }
}

function Get-OwnerPreviewRuleSections {
    <#
        The ownership rule's pinned sections, taken from the configuration the
        run will actually use.

        Read from the configuration rather than accepted on the command line so
        the bytes the preview claims to have measured against are the bytes the
        specialist was routed to. Only the commit is supplied by the operator,
        because a pack pins its rule by branch and a section has to name a commit.
    #>
    param(
        [Parameter(Mandatory)][string]$ConfigFile,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$RuleCommit
    )
    $config = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 64
    $conventions = $config.repoConventions
    $packs = $conventions.conventionPacks
    $sourcesProperty = $packs.PSObject.Properties['authoritativeSources']
    if ($null -eq $sourcesProperty -or $null -eq $sourcesProperty.Value) {
        throw "The configuration declares no conventionPacks.authoritativeSources; the ownership rule has no pinned bytes."
    }
    $sourceList = @($sourcesProperty.Value.sources)
    $pack = @($packs.packs) | Where-Object { [string]$_.name -ceq 'bpm-test-ownership' } | Select-Object -First 1
    if ($null -eq $pack) { throw "The configuration declares no 'bpm-test-ownership' pack." }
    $refs = @($pack.authoritativeSourceRefs)
    if ($refs.Count -lt 1) {
        throw "The 'bpm-test-ownership' pack references no authoritative source; there would be no rule to measure against."
    }

    $sections = [System.Collections.Generic.List[object]]::new()
    foreach ($reference in $refs) {
        $source = @($sourceList) | Where-Object { [string]$_.name -ceq [string]$reference } | Select-Object -First 1
        if ($null -eq $source) {
            throw "The pack references authoritative source '$reference', which the configuration does not declare."
        }
        foreach ($field in @('path', 'expectedSha256', 'expectedByteLength')) {
            $property = $source.PSObject.Properties[$field]
            if ($null -eq $property -or $null -eq $property.Value) {
                throw "The authoritative source '$reference' declares no '$field'; an unpinned rule cannot be bound to a commit."
            }
        }
        $sectionEntry = [ordered]@{
            path       = [string]$source.path
            commit     = $RuleCommit.ToLowerInvariant()
            sha256     = ([string]$source.expectedSha256).ToLowerInvariant()
            byteLength = [int]$source.expectedByteLength
        }
        $sectionProperty = $source.PSObject.Properties['section']
        if ($null -ne $sectionProperty) { $sectionEntry['section'] = [string]$sectionProperty.Value }
        [void]$sections.Add([pscustomobject]$sectionEntry)
    }
    return , $sections.ToArray()
}

function New-OwnerPreviewPrepared {
    <#
        The whole read-only half: capture the pull request, seal it, and file the
        subject under the key that describes it.
    #>
    param([Parameter(Mandatory)][string]$Root)

    [void](Assert-OwnerPreviewNoWriteSurface -ScriptPath $PSCommandPath)
    [void](Assert-OwnerPreviewCapabilityOnly -ConfigFile $ConfigFile)

    $toolkit = if ($ToolkitRoot -ne '') { [IO.Path]::GetFullPath($ToolkitRoot) } else { [IO.Path]::GetFullPath($RepoRoot) }
    $toolkitHead = Get-OwnerPreviewToolkitHead -Root $toolkit
    $sections = Get-OwnerPreviewRuleSections -ConfigFile $ConfigFile -RuleCommit $RuleCommit
    $configSha = Get-OwnerPreviewFileSha256 -Path $ConfigFile

    $correlationId = 'ownerprev-' + ([guid]::NewGuid().ToString('N').Substring(0, 16))
    $staging = Join-Path (Join-Path $Root '.staging') $correlationId
    $entryRoot = Join-Path $staging 'entry'
    $replayRoot = Join-Path $staging 'replay'
    $packRoot = Join-Path $staging 'pack'
    foreach ($directory in @($staging, $replayRoot, $packRoot)) {
        [void](New-Item -ItemType Directory -Force -Path $directory)
    }
    $prepared = $null

    try {

    $sealKeyPath = Get-OwnerPreviewSealKeyPath -Name 'entry'
    $runSetKeyPath = Get-OwnerPreviewSealKeyPath -Name 'run-set'

    $entryId = "owner-$PullRequestId"
    $request = New-OwnerPreviewEvidenceRequest -CorrelationId $correlationId -ToolkitRoot $toolkit `
        -ToolkitHead $toolkitHead -RequiredRef (Get-OwnerPreviewToolkitRequiredRef -Root $toolkit) `
        -Organization $Organization -Project $Project -RepositoryId $RepositoryId `
        -RepositoryName $RepositoryName -PullRequestId $PullRequestId -TargetRefName $TargetRefName `
        -ConfigPath ([IO.Path]::GetFullPath($ConfigFile)) `
        -RepositoryPath ([IO.Path]::GetFullPath($(if ($RepositoryPath -ne '') { $RepositoryPath } else { $toolkit }))) `
        -OperatorAlias $OperatorAlias -PowerShellPath (Get-OwnerPreviewPowerShellPath) `
        -RunSetKeyPath $runSetKeyPath -RuleDeclarationPath ([IO.Path]::GetFullPath($ConfigFile)) `
        -RuleDeclarationSha256 $configSha -RuleSections $sections `
        -CaptureMode $CaptureMode -AgencyPath $AgencyPath -ReplayRoot $SourceReplayRoot `
        -ReplaySnapshotName $SourceReplaySnapshotName -ReplayManifestDigest $SourceReplayManifestDigest `
        -OutputRoot $entryRoot -EntryId $entryId -SealKeyPath $sealKeyPath `
        -ChildTimeoutSeconds $ChildTimeoutSeconds -RequestTimeoutSeconds $PerCallTimeoutSeconds

    $requestPath = Join-Path $staging 'cohort-entry-request.json'
    [void](Write-OwnerPreviewJsonFile -Path $requestPath -Value $request)

    $builderText = Invoke-OwnerPreviewTool -Tool 'tools/New-ShadowCohortEntryEvidence.ps1' `
        -ToolArguments @('-RequestPath', $requestPath) -Stage 'pull request capture'
    $builder = Get-OwnerPreviewJsonLine -Text $builderText
    if ([int]$builder.modelStarts -ne 0 -or [int]$builder.providerWrites -ne 0) {
        throw "The capture reported $([int]$builder.modelStarts) model start(s) and $([int]$builder.providerWrites) provider write(s); preparation reads and does nothing else."
    }

    $recipePath = Join-Path (Join-Path $builder.root 'entry') 'corpus-seal-recipe.json'
    if (-not (Test-Path -LiteralPath $recipePath -PathType Leaf)) {
        throw "The published entry has no offline corpus seal recipe at '$recipePath'."
    }
    $recipe = Get-Content -LiteralPath $recipePath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 64
    $recipeSha = Get-OwnerPreviewFileSha256 -Path $recipePath

    [void](Invoke-OwnerPreviewTool -Tool 'tools/Save-CorpusReplaySeal.ps1' -ToolArguments @(
            '-CorpusRoot', (Join-Path $builder.root 'corpus'),
            '-CorpusIndexSha256', ([string]$builder.corpusIndexSha256),
            '-Recipe', $recipePath, '-RecipeSha256', $recipeSha,
            '-ReplayRoot', $replayRoot) -Stage 'corpus seal')

    # Read the sealed identity back off disk rather than parsing it out of the
    # sealer's console prose: the manifest is the artifact, the prose is a
    # courtesy.
    $snapshot = Read-OwnerPreviewSealedSnapshot -ReplayRoot $replayRoot -SnapshotName ([string]$recipe.snapshotId)
    $sealDigest = Get-OwnerPreviewFileSha256 -Path (Join-Path $snapshot.SnapshotPath 'offline-corpus-seal.json')
    $seed = New-OwnerPreviewLegacyProjection -Snapshot $snapshot -PackRoot $packRoot `
        -CorpusIndexSha256 ([string]$builder.corpusIndexSha256) -SealDigest $sealDigest

    $subjectKey = Get-OwnerPreviewSubjectKey -Organization $Organization -Project $Project `
        -RepositoryId $RepositoryId -PullRequestId $PullRequestId
    $headKey = Get-OwnerPreviewHeadKey -SubjectKey $subjectKey -SourceCommit $snapshot.SourceCommit `
        -RuleSections $sections -ReplayManifestDigest $snapshot.ManifestDigest -Model $Model `
        -ConfigSha256 $configSha -ToolkitHead $toolkitHead

    $subjectsRoot = Join-Path $Root 'subjects'
    [void](New-Item -ItemType Directory -Force -Path $subjectsRoot)
    $destination = Join-Path $subjectsRoot $headKey
    $completed = Join-Path $destination 'subject.json'
    if (Test-Path -LiteralPath $destination) {
        if (Test-Path -LiteralPath $completed -PathType Leaf) {
            # The same head, rule set, model and toolkit was already prepared. Its
            # evidence is not rebuilt: a second preparation would produce a second
            # answer to a question already on disk.
            $prepared = Read-OwnerPreviewSubject -Root $Root -HeadKey $headKey
            return $prepared
        }
        # A directory with no subject.json is a preparation that was interrupted
        # between the move and the record. Reusing it would return "prepared" for
        # a package nothing finished, and rebuilding over it silently would
        # discard whatever is there - so it is refused and named instead.
        throw ("The subject directory '$destination' exists but records no subject.json, so an earlier " +
            "preparation did not finish. Inspect it and remove it deliberately before preparing this head again.")
    }
    Move-Item -LiteralPath $staging -Destination $destination

    $subject = [ordered]@{
        schemaVersion  = 1
        kind           = 'reviewer-owner-preview-subject'
        capability     = $script:OwnerPreviewCapability
        subjectKey     = $subjectKey
        headKey        = $headKey
        correlationId  = $correlationId
        preparedUtc    = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        captureMode    = $CaptureMode
        toolkitHead    = $toolkitHead
        sourceRefName  = $(if ($SourceRefName -ne '') { $SourceRefName } elseif ($ExpectedRef -ne '') { $ExpectedRef } else { $TargetRefName })
        configSha256   = $configSha
        model          = $Model
        entryId        = $entryId
        subject        = [ordered]@{
            organization   = $snapshot.Organization
            project        = $snapshot.Project
            repositoryId   = $snapshot.RepositoryId
            repositoryName = $snapshot.RepositoryName
            pullRequestId  = [int]$snapshot.PullRequestId
            iterationId    = [int]$snapshot.IterationId
            sourceCommit   = $snapshot.SourceCommit
            targetCommit   = $snapshot.TargetCommit
            targetRefName  = $TargetRefName
        }
        rule           = [ordered]@{
            declarationPath   = ([IO.Path]::GetFullPath($ConfigFile))
            declarationSha256 = $configSha
            sections          = @($sections)
        }
        snapshot       = [ordered]@{
            snapshotId     = $snapshot.SnapshotId
            manifestDigest = $snapshot.ManifestDigest
            sealKind       = $snapshot.SealKind
            nonPromotable  = $true
        }
        paths          = [ordered]@{
            root              = $destination
            entryRoot         = (Join-Path $destination 'entry')
            replayRoot        = (Join-Path $destination 'replay')
            packRoot          = (Join-Path $destination 'pack')
            legacyProjection  = (Join-Path (Join-Path (Join-Path $destination 'pack') 'projections') 'owner-preview.minimal.blinded.json')
            snapshotPath      = (Join-Path (Join-Path $destination 'replay') $snapshot.SnapshotId)
        }
        spend          = [ordered]@{ modelStarts = 0; providerWrites = 0 }
    }
    [void](Write-OwnerPreviewJsonFile -Path (Join-Path $destination 'subject.json') -Value $subject)

    $prepared = $subject

    }

    finally {

        # Captured pull request bytes must never be left behind by a refusal.

        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }

    }

    return $prepared
}

function Get-OwnerPreviewToolkitRequiredRef {
    <#
        The ref the TOOLKIT checkout is required to be on.

        Deliberately not the same value as the pull request's ref, and kept in a
        separate function because they were once the same one. The builder pins
        the toolkit head and refuses when the required ref does not resolve to
        it, so borrowing the subject's ref here refuses every run that is not on
        main - and borrowing this one for the subject would assert that a pull
        request lives on the branch the toolkit happens to be checked out at.

        Defaults to the branch this checkout is actually on, because the honest
        answer to "which ref is this toolkit" is one git can be asked.
    #>
    param([Parameter(Mandatory)][string]$Root)
    if ($ToolkitRequiredRef -ne '') { return $ToolkitRequiredRef }
    Push-Location -LiteralPath $Root
    try {
        $symbolic = (& git symbolic-ref -q HEAD 2>&1)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$symbolic)) {
            throw ("The toolkit at '$Root' is not on a named branch, so its required ref cannot be derived. " +
                "State it with -ToolkitRequiredRef.")
        }
        return ([string]$symbolic).Trim()
    }
    finally { Pop-Location }
}

function Get-OwnerPreviewSealKeyPath {
    <#
        Where an HMAC seal key lives: outside the evidence it authenticates.

        A key stored beside the package it seals proves nothing - whoever can
        edit the package can mint a matching seal. The production default for
        these tools is a private per-user key, and this mirrors it rather than
        writing one into a directory that is published, copied or archived as
        evidence.
    #>
    param([Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,31}$')][string]$Name)
    if ($SealKeyRoot -ne '') { $base = [IO.Path]::GetFullPath($SealKeyRoot) }
    else { $base = Join-Path (Join-Path $HOME '.devpilot') 'owner-preview' }
    if (-not (Test-Path -LiteralPath $base -PathType Container)) {
        [void](New-Item -ItemType Directory -Force -Path $base)
    }
    return (Join-Path $base "owner-preview-$Name.key")
}

function Get-OwnerPreviewDiscoveryGeneralistModel {
    <#
        The configured generalist first-pass model name.

        Specialist acquisition refuses to start without it, and capture pairs it
        with the second generalist model to check the configured pair. It names
        a model; it does not start one - a specialist role runs the specialist
        and nothing else.
    #>
    if ($DiscoveryGeneralistModel -ne '') { return $DiscoveryGeneralistModel }
    $pair = Get-AgentGeneralistModelPair
    return [string]$pair.First
}

function Get-OwnerPreviewPowerShellPath {
    <# This PowerShell, stated rather than searched for. #>
    $process = Get-Process -Id $PID
    return [string]$process.Path
}

function Read-OwnerPreviewSubject {
    <#
        A prepared subject, with its key re-derived from what is on disk.

        The key is recomputed rather than trusted: a subject whose recorded head
        key does not match its own contents is a package something has edited,
        and a preview built on it would be filed under the wrong question.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$HeadKey
    )
    $path = Join-Path (Join-Path (Join-Path $Root 'subjects') $HeadKey) 'subject.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "No prepared subject '$HeadKey' under '$Root'. Run -Action prepare first."
    }
    $subject = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 64 -AsHashtable
    $recomputed = Get-OwnerPreviewHeadKey -SubjectKey ([string]$subject.subjectKey) `
        -SourceCommit ([string]$subject.subject.sourceCommit) `
        -RuleSections @($subject.rule.sections) `
        -ReplayManifestDigest ([string]$subject.snapshot.manifestDigest) `
        -Model ([string]$subject.model) -ConfigSha256 ([string]$subject.configSha256) `
        -ToolkitHead ([string]$subject.toolkitHead)
    if ($recomputed -cne [string]$subject.headKey) {
        throw ("The subject at '$path' records head key $([string]$subject.headKey) but its own contents " +
            "compute $recomputed. Evidence that disagrees with its own identity is refused rather than used.")
    }
    return $subject
}

function Invoke-OwnerPreviewSpecialist {
    <#
        The one model start, through the tools that already own model supervision.

        Capture builds the stimulus and starts nothing. The materializer binds it.
        Acquisition runs the model under its own timeouts, attempt accounting and
        zero-write telemetry. This function threads paths and reads the result.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Subject,
        [Parameter(Mandatory)][string]$Root
    )
    [void](Assert-OwnerPreviewNoWriteSurface -ScriptPath $PSCommandPath)

    $discoveryGeneralistModel = Get-OwnerPreviewDiscoveryGeneralistModel

    $headKey = [string]$Subject['headKey']
    $runRoot = Join-Path (Join-Path $Root 'runs') $headKey
    if (Test-Path -LiteralPath $runRoot) { Remove-Item -LiteralPath $runRoot -Recurse -Force }
    [void](New-Item -ItemType Directory -Force -Path $runRoot)

    $paths = $Subject['paths']
    $snapshotPath = [string]$paths['snapshotPath']
    $replayRoot = [string]$paths['replayRoot']
    $snapshotId = [string]$Subject['snapshot']['snapshotId']
    $manifestPath = Join-Path $snapshotPath 'manifest.json'
    $manifestSha = Get-OwnerPreviewFileSha256 -Path $manifestPath
    $configPath = [string]$Subject['rule']['declarationPath']
    $configSha = [string]$Subject['configSha256']
    $model = [string]$Subject['model']

    $snapshot = Read-OwnerPreviewSealedSnapshot -ReplayRoot $replayRoot -SnapshotName $snapshotId
    $seed = [pscustomobject]@{
        FixtureId          = $snapshotId
        ManifestSha256     = $manifestSha
        SealedResourceName = "$manifestSha-manifest.json"
        SealedResourcePath = (Join-Path (Join-Path ([string]$paths['packRoot']) 'sealed-resources') "$manifestSha-manifest.json")
        ByteLength         = [long](@(Get-Item -LiteralPath $manifestPath)[0].Length)
    }
    $captureRequest = New-OwnerPreviewCaptureRequest -Snapshot $snapshot -LegacyProjection $seed `
        -Model $model -ConfigSha256 $configSha -ManifestFileSha256 $manifestSha
    $captureRequestPath = Join-Path $runRoot 'capture-request.json'
    [void](Write-OwnerPreviewJsonFile -Path $captureRequestPath -Value $captureRequest)

    $captureRoot = Join-Path $runRoot 'capture'
    # The seal key authenticates this package, so it must not live inside it. A
    # key sitting next to the evidence it seals means anyone who can edit the
    # evidence can re-seal it, which is the same as not sealing it.
    $sealKeyPath = Get-OwnerPreviewSealKeyPath -Name 'capture'
    $captureArguments = @(
        '-Role', 'specialist', '-Model', $model,
        '-CaptureRequestFile', $captureRequestPath, '-ConfigFile', $configPath,
        '-ReplayRoot', $replayRoot, '-ReplaySnapshotName', $snapshotId,
        '-ReplayManifestDigest', ([string]$Subject['snapshot']['manifestDigest']),
        '-PullRequestId', ([string][int]$Subject['subject']['pullRequestId']),
        # The TOOLKIT's head and ref, not the pull request's. Both child tools
        # resolve these against the checkout named by -RepoRoot, so stating the
        # reviewed pull request's commit here would assert that the toolkit is
        # checked out at somebody else's branch and refuse every run. The pull
        # request's own identity travels in -PullRequestId and in the sealed
        # snapshot binding, which those tools cross-check separately.
        '-ExpectedHeadCommit', ([string]$Subject['toolkitHead']),
        '-ExpectedRef', (Get-OwnerPreviewToolkitRequiredRef -Root $RepoRoot),
        '-OutputRoot', $captureRoot, '-RepoRoot', $RepoRoot, '-SealKeyPath', $sealKeyPath,
        '-LegacyProjectionFile', ([string]$paths['legacyProjection']),
        '-SecondGeneralistModel', $SecondGeneralistModel,
        '-ConventionSpecialistModel', $model,
        '-DiscoveryGeneralistModel', $discoveryGeneralistModel
    )
    [void](Invoke-OwnerPreviewTool -Tool 'tools/Invoke-ReviewerRoleInputCapture.ps1' `
            -ToolArguments $captureArguments -Stage 'specialist input capture')

    $projections = @(Get-ChildItem -LiteralPath (Join-Path $captureRoot 'projections') -Filter '*.blinded.json' -ErrorAction SilentlyContinue)
    if ($projections.Count -lt 1) {
        throw "Capture published no re-materialized projection; the benchmark pack materializer has nothing to bind."
    }
    $provenances = @(Get-ChildItem -LiteralPath (Join-Path $captureRoot 'sealed-resources') -Filter '*-role-specialist.json' -ErrorAction SilentlyContinue)
    if ($provenances.Count -lt 1) {
        throw "Capture published no specialist role provenance."
    }

    $materialized = Join-Path $runRoot 'materialized'
    $promptPath = if ($PromptFile -ne '') { $PromptFile } else { Join-Path $RepoRoot 'src/Agents/reviewer/review-cycle.prompt.md' }
    $materializeText = Invoke-OwnerPreviewTool -Tool 'tools/Convert-ReviewerBlindedBenchmarkPack.ps1' -ToolArguments @(
        '-PackRoot', $captureRoot, '-LegacyProjectionFile', $projections[0].FullName, '-Role', 'specialist',
        '-RoleProvenanceFile', $provenances[0].FullName, '-ReplaySnapshotPath', $snapshotPath,
        '-ConfigFile', $configPath, '-PromptFile', $promptPath,
        '-ExpectedReplayManifestFileSha256', $manifestSha,
        '-ExpectedConfigSha256', $configSha,
        '-ExpectedPromptSha256', (Get-OwnerPreviewFileSha256 -Path $promptPath),
        '-SecondGeneralistModel', $SecondGeneralistModel,
        '-ConventionSpecialistModel', $model,
        '-OutputRoot', $materialized, '-RepoRoot', $RepoRoot) -Stage 'benchmark pack materialization'
    $materialize = Get-OwnerPreviewJsonLine -Text $materializeText

    $acquisitionRoot = Join-Path $runRoot 'acquisition'
    $acquireArguments = @(
        '-Role', 'specialist',
        '-FixtureProjectionFile', (Join-Path $materialized 'projection.json'),
        '-Model', $model,
        '-ConfigFile', (Join-Path (Join-Path $materialized 'config') 'reviewer.config.json'),
        '-ReplayRoot', (Join-Path $materialized 'replay'),
        '-ReplaySnapshotName', ([string]$materialize.replaySnapshotName),
        '-ReplayManifestDigest', ([string]$materialize.replayManifestDigest),
        '-ExpectedReviewerBaseCommit', $ExpectedReviewerBaseCommit,
        '-PullRequestId', ([string][int]$Subject['subject']['pullRequestId']),
        '-ExpectedHeadCommit', ([string]$Subject['toolkitHead']),
        '-ExpectedRef', (Get-OwnerPreviewToolkitRequiredRef -Root $RepoRoot),
        '-OutputRoot', $acquisitionRoot, '-RepoRoot', $RepoRoot,
        '-SealKeyPath', (Get-OwnerPreviewSealKeyPath -Name 'acquisition'),
        '-SecondGeneralistModel', $SecondGeneralistModel,
        '-ConventionSpecialistModel', $model,
        '-DiscoveryGeneralistModel', $discoveryGeneralistModel,
        '-PerCallTimeoutSeconds', ([string]$PerCallTimeoutSeconds),
        '-ActivityTimeoutSeconds', ([string]$ActivityTimeoutSeconds),
        '-TotalTimeoutSeconds', ([string]$TotalTimeoutSeconds)
    )
    if ($UseOfflineStubAdapter) { $acquireArguments += '-UseOfflineStubAdapter' }
    if ($OfflineModelAdapterManifest -ne '') {
        $acquireArguments += @('-OfflineModelAdapterManifest', $OfflineModelAdapterManifest)
    }
    [void](Invoke-OwnerPreviewTool -Tool 'tools/Invoke-ReviewerBlindedAcquisition.ps1' `
            -ToolArguments $acquireArguments -Stage 'specialist acquisition')

    return $acquisitionRoot
}

function Read-OwnerPreviewSealedResult {
    <#
        The run's result, read only out of the HMAC-sealed acquisition package.

        Deliberately not a search of the acquisition tree. That tree also holds
        each attempt's RAW model stdout, the supervisor and reviewer console
        logs, and - for a specialist run - the sealed discovery marker that was
        handed IN as an input, which carries the same marker prefix. Picking the
        first file that happens to contain the prefix would let a retried
        attempt, a console echo, or an input document stand in for the terminal
        answer, and the model's stdout is derived from attacker-controlled pull
        request bytes.

        So the package's seal is verified first and the marker and nonce are
        taken from the bytes that seal covers. A package that is absent or does
        not verify yields nothing, which the caller reports as an incomplete
        pass rather than a clean one.
    #>
    param(
        [Parameter(Mandatory)][string]$AcquisitionRoot,
        [Parameter(Mandatory)][string]$SealKeyPath
    )
    $packageRoot = Join-Path $AcquisitionRoot 'package'
    $empty = [pscustomobject]@{ MarkerText = ''; Nonce = ''; Diagnostic = '' }
    if (-not (Test-Path -LiteralPath $packageRoot -PathType Container)) {
        $empty.Diagnostic = "The acquisition published no sealed package at '$packageRoot'."
        return $empty
    }
    $schemaPath = Join-Path $RepoRoot 'src/Agents/reviewer/acquisition/v1/transcript-package.schema.json'
    try {
        $verified = Assert-ReviewerAcquisitionTranscriptPackage -PackageRoot $packageRoot `
            -SealKeyPath $SealKeyPath -SchemaPath $schemaPath
    }
    catch {
        $empty.Diagnostic = "The sealed acquisition package did not verify: $([string]$_.Exception.Message)"
        return $empty
    }
    return [pscustomobject]@{
        MarkerText = [string]$verified.MarkerText
        Nonce      = [string]$verified.Core.nonce
        Diagnostic = ''
    }
}

function Save-OwnerPreviewOutcome {
    <#
        The status and the report on disk.

        Building the status is the library's job and is tested there; this only
        decides where the two artifacts land.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Subject,
        [Parameter(Mandatory)][AllowEmptyString()][string]$MarkerText,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExpectedNonce,
        [Parameter(Mandatory)][string]$RunRoot
    )
    $status = New-OwnerPreviewOutcome -Subject $Subject -MarkerText $MarkerText -ExpectedNonce $ExpectedNonce
    [void](Write-OwnerPreviewJsonFile -Path (Join-Path $RunRoot 'owner-preview-status.json') -Value $status)
    $report = Format-OwnerPreviewReport -Status $status
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText((Join-Path $RunRoot 'owner-preview-report.md'), $report, $encoding)
    return $status
}

$exitCode = 0
try {
    $root = Resolve-OwnerPreviewSubjectRoot -SubjectRoot $SubjectRoot
    [void](New-Item -ItemType Directory -Force -Path $root)

    switch ($Action) {
        'status' {
            [void](Assert-OwnerPreviewParameter -Value $HeadKey -Name 'HeadKey' -ForAction 'status')
            $statusPath = Join-Path (Join-Path (Join-Path $root 'runs') $HeadKey) 'owner-preview-status.json'
            if (-not (Test-Path -LiteralPath $statusPath -PathType Leaf)) {
                throw "No preview status for subject '$HeadKey'. Run -Action run first."
            }
            $recorded = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 64 -AsHashtable
            Write-Host (Format-OwnerPreviewReport -Status $recorded)
            Write-Output (ConvertTo-Json -Depth 8 -Compress -InputObject ([ordered]@{
                        action = 'status'; headKey = $HeadKey
                        terminal = [string]$recorded.terminal.status
                        checked = [int]$recorded.counts.checked
                        violations = [int]$recorded.counts.violations
                        unknown = [int]$recorded.counts.unknown
                    }))
            break
        }
        default {
            $prepared = $null
            if ($Action -ceq 'prepare' -or $Action -ceq 'prepare-run') {
                foreach ($pair in @(
                        @{ Value = $ConfigFile; Name = 'ConfigFile' },
                        @{ Value = $Organization; Name = 'Organization' },
                        @{ Value = $Project; Name = 'Project' },
                        @{ Value = $RepositoryId; Name = 'RepositoryId' },
                        @{ Value = $RepositoryName; Name = 'RepositoryName' },
                        @{ Value = $TargetRefName; Name = 'TargetRefName' },
                        @{ Value = $RuleCommit; Name = 'RuleCommit' },
                        @{ Value = $Model; Name = 'Model' })) {
                    [void](Assert-OwnerPreviewParameter -Value ([string]$pair.Value) -Name ([string]$pair.Name) -ForAction $Action)
                }
                if ($PullRequestId -lt 1) { throw "-PullRequestId is required for -Action $Action." }
                $prepared = New-OwnerPreviewPrepared -Root $root
            }
            if ($Action -ceq 'prepare') {
                Write-Output (ConvertTo-Json -Depth 8 -Compress -InputObject ([ordered]@{
                            action = 'prepare'
                            headKey = [string]$prepared.headKey
                            subjectKey = [string]$prepared.subjectKey
                            snapshotId = [string]$prepared.snapshot.snapshotId
                            manifestDigest = [string]$prepared.snapshot.manifestDigest
                            sourceCommit = [string]$prepared.subject.sourceCommit
                            modelStarts = 0
                            providerWrites = 0
                        }))
                break
            }

            $activeKey = if ($null -ne $prepared) { [string]$prepared.headKey } else {
                [string](Assert-OwnerPreviewParameter -Value $HeadKey -Name 'HeadKey' -ForAction 'run')
            }
            # Checked here rather than discovered by a child binder: acquisition
            # declares it mandatory, and finding that out after capture and
            # materialization have already run and written a package wastes two
            # stages to report a missing argument.
            [void](Assert-OwnerPreviewParameter -Value $ExpectedReviewerBaseCommit `
                    -Name 'ExpectedReviewerBaseCommit' -ForAction $Action)
            $subject = Read-OwnerPreviewSubject -Root $root -HeadKey $activeKey
            $acquisitionRoot = Invoke-OwnerPreviewSpecialist -Subject $subject -Root $root
            $runRoot = Join-Path (Join-Path $root 'runs') $activeKey
            $sealed = Read-OwnerPreviewSealedResult -AcquisitionRoot $acquisitionRoot -SealKeyPath (Join-Path $runRoot 'acquisition-seal.key')
            $status = Save-OwnerPreviewOutcome -Subject $subject -MarkerText $sealed.MarkerText -ExpectedNonce $sealed.Nonce -RunRoot $runRoot
            if ([string]$status.terminal.status -cne 'completed') { $exitCode = 2 }
            Write-Output (ConvertTo-Json -Depth 8 -Compress -InputObject ([ordered]@{
                        action = $Action
                        headKey = $activeKey
                        terminal = [string]$status.terminal.status
                        checked = [int]$status.counts.checked
                        violations = [int]$status.counts.violations
                        unknown = [int]$status.counts.unknown
                        modelStarts = [int]$status.spend.modelStarts
                        providerWrites = 0
                        reportPath = (Join-Path $runRoot 'owner-preview-report.md')
                    }))
        }
    }
}
catch {
    Write-Error ([string]$_.Exception.Message)
    exit 1
}
exit $exitCode
