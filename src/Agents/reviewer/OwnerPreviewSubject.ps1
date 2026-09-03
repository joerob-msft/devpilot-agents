#!/usr/bin/env pwsh
<#
    Everything the Owner preview has to AUTHOR, and nothing it can delegate.

    The preview itself is a composition of tools that already exist: the typed
    cohort-entry evidence builder reads the pull request, the corpus sealer turns
    what it read into a permanently non-promotable snapshot, production role
    capture builds the specialist stimulus, the benchmark-pack materializer binds
    it, and blinded acquisition runs the one model. None of that is re-implemented
    here, because a second copy of any of it would be a second thing to keep in
    step with production.

    What is left over is paperwork: three request documents those tools read, the
    hashes that bind them to each other, and the subject identity this layer files
    its evidence under. That is what lives here.

    One of the three is a genuinely new seam and is called out where it is
    defined: New-OwnerPreviewLegacyProjection. The others are transcriptions of
    published schemas.
#>

Set-StrictMode -Version Latest

$script:OwnerPreviewCapabilityId = 'bpm-test-ownership@1'
$script:OwnerPreviewPackName = 'bpm-test-ownership'
$script:OwnerPreviewSealKind = 'offlineCorpusSeal'

function Get-OwnerPreviewTextSha256 {
    <#
        SHA-256 of a string, through the reviewer's own sealing helper.

        Routed through Get-ReviewerCorpusSealTextSha256 rather than a local
        hasher so this layer cannot end up with a second answer to "what is the
        digest of these bytes" if that helper ever changes how it reads a string.
        Fails closed rather than falling back: a quietly different hash is worse
        than a refusal.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $helper = Get-Command -Name 'Get-ReviewerCorpusSealTextSha256' -CommandType Function -ErrorAction SilentlyContinue
    if ($null -eq $helper) {
        throw "Get-ReviewerCorpusSealTextSha256 is not loaded; dot-source src/Agents/reviewer/CorpusSeal.ps1 before using the Owner preview subject library."
    }
    return [string](& $helper -Text $Text)
}

function Get-OwnerPreviewFileSha256 {
    <# SHA-256 of a file's bytes, through the same helper. #>
    param([Parameter(Mandatory)][string]$Path)
    $helper = Get-Command -Name 'Get-ReviewerCorpusSealSha256' -CommandType Function -ErrorAction SilentlyContinue
    if ($null -eq $helper) {
        throw "Get-ReviewerCorpusSealSha256 is not loaded; dot-source src/Agents/reviewer/CorpusSeal.ps1 before using the Owner preview subject library."
    }
    $bytes = [IO.File]::ReadAllBytes($Path)
    return [string](& $helper -Bytes $bytes)
}

function Get-OwnerPreviewCanonicalSha256 {
    <# SHA-256 over the canonical rendering of an object. #>
    param([Parameter(Mandatory)][AllowNull()]$Value)
    $canonical = [string](ConvertTo-AgentReplayCanonicalJson -Value $Value)
    return (Get-OwnerPreviewTextSha256 -Text $canonical)
}

function Write-OwnerPreviewJsonFile {
    <#
        One JSON document on disk, canonical and UTF-8 without a byte-order mark.

        Canonical rather than pretty because every one of these files is hashed
        by something downstream, and a formatting change that altered a digest
        would look exactly like a tampered file.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowNull()]$Value
    )
    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        [void](New-Item -ItemType Directory -Force -Path $directory)
    }
    $canonical = [string](ConvertTo-AgentReplayCanonicalJson -Value $Value)
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($Path, $canonical, $encoding)
    return $Path
}

function Test-OwnerPreviewPathInsideRepository {
    <#
        Whether a path sits inside a git working tree - main checkout or linked
        worktree.

        The subject root holds captured pull request bytes. Inside a repository
        that is private evidence one `git add` away from being published, which
        is the same reason the corpus sealer refuses a corpus root inside the
        toolkit. Checking here as well means an operator finds out when they name
        the path, not several minutes into a live capture.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $probe = $Path
    while (-not [string]::IsNullOrWhiteSpace($probe)) {
        if (Test-Path -LiteralPath (Join-Path $probe '.git')) { return $true }
        $parent = Split-Path -Parent $probe
        if ($parent -eq $probe) { break }
        $probe = $parent
    }
    return $false
}

function Resolve-OwnerPreviewSubjectRoot {
    <#
        The absolute, out-of-repository root this layer files evidence under.

        Required and absolute rather than defaulted silently: supervision that
        guesses where evidence lives can end up reading a different subject than
        the one it wrote.
    #>
    param([Parameter(Mandatory)][string]$SubjectRoot)
    if (-not [IO.Path]::IsPathRooted($SubjectRoot)) {
        throw "The subject root '$SubjectRoot' is not absolute. State the full path; a relative evidence root resolves against whatever directory the scheduler happened to start in."
    }
    $full = [IO.Path]::GetFullPath($SubjectRoot)
    if (Test-OwnerPreviewPathInsideRepository -Path $full) {
        throw "The subject root '$full' is inside a git working tree. Captured pull request bytes are private evidence and must not sit where a commit could publish them."
    }
    return $full
}

function Get-OwnerPreviewDefaultSubjectRoot {
    <#
        The conventional per-instance evidence root, matching the review handler's
        own default resolution so an operator has one place to look.
    #>
    param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')][string]$Name)
    $base = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($base)) { $base = Join-Path $HOME '.local-state' }
    return (Join-Path (Join-Path (Join-Path $base 'DevPilot') 'OwnerPreview') $Name)
}

function Assert-OwnerPreviewCapabilityOnly {
    <#
        The configuration must select exactly this one capability.

        Blinded acquisition takes a ROLE, not a pack: `-Role specialist` runs the
        whole convention-specialist role over whatever packs the configuration
        routes. So the only place the scope of this preview can be pinned is the
        configuration, and if it is not pinned there it is not pinned at all -
        the run would quietly widen to every pack whose globs matched.
    #>
    param([Parameter(Mandatory)][string]$ConfigFile)
    if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) {
        throw "The reviewer configuration '$ConfigFile' does not exist."
    }
    $config = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 64
    $conventions = $config.PSObject.Properties['repoConventions']
    if ($null -eq $conventions -or $null -eq $conventions.Value) {
        throw "The reviewer configuration '$ConfigFile' declares no repoConventions; the Owner preview has no capability to run."
    }
    $packsProperty = $conventions.Value.PSObject.Properties['conventionPacks']
    if ($null -eq $packsProperty -or $null -eq $packsProperty.Value) {
        throw "The reviewer configuration '$ConfigFile' declares no repoConventions.conventionPacks; the Owner preview has no capability to run."
    }
    $packList = $packsProperty.Value.PSObject.Properties['packs']
    if ($null -eq $packList -or $null -eq $packList.Value) {
        throw "The reviewer configuration '$ConfigFile' declares no conventionPacks.packs."
    }
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($pack in @($packList.Value)) {
        $nameProperty = $pack.PSObject.Properties['name']
        if ($null -ne $nameProperty) { [void]$names.Add([string]$nameProperty.Value) }
    }
    $declared = $names.ToArray()
    if ($declared.Count -ne 1 -or $declared[0] -cne $script:OwnerPreviewPackName) {
        throw ("The Owner preview runs exactly one capability, '$script:OwnerPreviewPackName', but the configuration " +
            "'$ConfigFile' declares $($declared.Count) pack(s): $($declared -join ', '). " +
            "A specialist role runs every routed pack, so a second pack here would be a second capability nobody asked for.")
    }
    return $declared[0]
}

$script:OwnerPreviewWriteSwitches = @(
    'EnableFindingComments', 'EnableSummaryComment', 'EnableApprovalVote',
    'EnableVerifiedCommentGate', 'EnableVerifiedSuggestionGate', 'EnableVerifiedApprovalGate',
    'PromotePreview', 'PromoteVerifiedPreview'
)

function Test-OwnerPreviewWriteSwitchName {
    <#
        Whether a name could bind one of the reviewer's write switches.

        Compared case-INSENSITIVELY and by PREFIX, because that is how
        PowerShell's binder works: `-enablesummarycom` binds
        `-EnableSummaryComment` perfectly well. An exact, case-sensitive match
        would refuse only the spelling a careful author used and wave through
        every abbreviation of it, which is the wrong way round - the careless
        spelling is the one worth catching.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)
    $candidate = ([string]$Name).Trim()
    if ($candidate -eq '') { return $false }
    # `-Switch:$true` binds too, so anything before a colon is the name.
    $colon = $candidate.IndexOf(':')
    if ($colon -ge 0) { $candidate = $candidate.Substring(0, $colon) }
    foreach ($switchName in $script:OwnerPreviewWriteSwitches) {
        if ($switchName.StartsWith($candidate, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Assert-OwnerPreviewNoWriteSurface {
    <#
        This tool must not be ABLE to ask for a write.

        Checked against the script's own parameter block rather than asserted in
        prose, because the interesting failure is not today's code - it is the
        edit six months from now that adds one convenient switch. A reviewer
        reading that diff sees a new parameter; this check sees the preview lose
        the only property that makes it safe to run unattended.

        The runtime guarantee is elsewhere and stronger: blinded acquisition
        fails closed unless its sealed telemetry proves zero writes. This is the
        cheap structural half that catches the mistake before anything starts.
    #>
    param([Parameter(Mandatory)][string]$ScriptPath)
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        throw "The Owner preview could not read its own script at '$ScriptPath' to prove it declares no write capability."
    }
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        ([IO.Path]::GetFullPath($ScriptPath)), [ref]$null, [ref]$parseErrors)
    $declared = [System.Collections.Generic.List[string]]::new()
    $parameterBlock = $ast.ParamBlock
    if ($null -ne $parameterBlock) {
        foreach ($parameter in @($parameterBlock.Parameters)) {
            $name = [string]$parameter.Name.VariablePath.UserPath
            if (Test-OwnerPreviewWriteSwitchName -Name $name) { [void]$declared.Add($name) }
        }
    }
    if ($declared.Count -gt 0) {
        throw ("The Owner preview declares write-capable parameter(s) $($declared.ToArray() -join ', '). " +
            "This layer previews one convention and must not be able to request a write at all.")
    }
    return $true
}

function Assert-OwnerPreviewNoWriteArgument {
    <#
        No write switch may reach a child tool.

        The reviewer's write switches are named parameters, so a single stray
        element in an argument vector is the whole distance between a preview and
        a comment on somebody's pull request.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ToolArguments,
        [Parameter(Mandatory)][string]$Stage
    )
    foreach ($argument in @($ToolArguments)) {
        $candidate = [string]$argument
        if (-not $candidate.StartsWith('-')) { continue }
        $trimmed = $candidate.TrimStart('-')
        if (Test-OwnerPreviewWriteSwitchName -Name $trimmed) {
            throw "The $Stage step was about to pass write switch '$candidate'. The Owner preview writes nothing."
        }
    }
    return $true
}

function New-OwnerPreviewEvidenceRequest {
    <#
        The typed cohort-entry evidence request, to
        reviewer.cohort-entry-evidence-request.v3.json.

        v3 is authored rather than v1 because v3 is the first version in which a
        rule section states the repository its text lives in. This capability's
        rule lives in an engineering-guidance repository that is NOT the
        repository the reviewed pull request is in, and under v1/v2 the builder
        had nothing to issue that read against except the subject repository -
        so the read was refused by the provider and reported as a generic
        envelope failure. v3 also carries the ATX heading the pin describes, so
        the pinned digest of a cut section is compared against that cut rather
        than against the whole document.

        No executionPlan is emitted, and that is the load-bearing detail. A
        request MAY grow a plan carrying exactly two generalist slots; without
        one, the builder emits a preparation-only entry with no slots section at
        all. No slots means no generalist, which means this preview costs one
        specialist model start rather than three model runs whose verdict it
        would then have to discard.

        `reviewer.plannedRunCount` and `runSetKeyPath` are still required by the
        schema and are stated honestly as the inert declarations they are: no run
        set is declared here and nothing launches from this request.
    #>
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{7,63}$')][string]$CorrelationId,
        [Parameter(Mandatory)][string]$ToolkitRoot,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ToolkitHead,
        [Parameter(Mandatory)][string]$RequiredRef,
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][string]$RepositoryName,
        [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$PullRequestId,
        [Parameter(Mandatory)][string]$TargetRefName,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{2,63}$')][string]$OperatorAlias,
        [Parameter(Mandatory)][string]$PowerShellPath,
        [Parameter(Mandatory)][string]$RunSetKeyPath,
        [Parameter(Mandatory)][string]$RuleDeclarationPath,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$RuleDeclarationSha256,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$RuleSections,
        [Parameter(Mandatory)][ValidateSet('live', 'replay')][string]$CaptureMode,
        [Parameter(Mandatory)][string]$OutputRoot,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{3,63}$')][string]$EntryId,
        [Parameter(Mandatory)][string]$SealKeyPath,
        [AllowEmptyString()][string]$AgencyPath = '',
        [AllowEmptyString()][string]$ReplayRoot = '',
        [AllowEmptyString()][string]$ReplaySnapshotName = '',
        [AllowEmptyString()][string]$ReplayManifestDigest = '',
        [ValidateRange(1, 600)][int]$RequestTimeoutSeconds = 120,
        [ValidateRange(1, 14400)][int]$ChildTimeoutSeconds = 900,
        [ValidateRange(1, 4096)][int]$MaxChangedFiles = 64,
        [ValidateRange(1, 33554432)][int]$MaxFileBytes = 262144,
        [ValidateRange(0, 4096)][int]$MaxSiblingFiles = 16,
        [ValidateRange(0, 4096)][int]$MaxThreads = 64,
        [ValidateRange(1, 100)][int]$MinChangedPathCoveragePercent = 80
    )

    if (@($RuleSections).Count -lt 1) {
        throw "A rule bundle with no sections would be a preview measured against nothing."
    }

    $capture = [ordered]@{ mode = $CaptureMode }
    if ($CaptureMode -ceq 'live') {
        if ([string]::IsNullOrWhiteSpace($AgencyPath)) {
            throw "A live capture requires -AgencyPath: it is the agency-wrapped session the read-only plan is issued through."
        }
        $capture['agencyPath'] = $AgencyPath
    }
    else {
        if ([string]::IsNullOrWhiteSpace($ReplayRoot) -or [string]::IsNullOrWhiteSpace($ReplaySnapshotName) -or
            [string]::IsNullOrWhiteSpace($ReplayManifestDigest)) {
            throw "A replay capture requires -ReplayRoot, -ReplaySnapshotName and -ReplayManifestDigest."
        }
        $capture['replayRoot'] = $ReplayRoot
        $capture['replaySnapshotName'] = $ReplaySnapshotName
        $capture['replayManifestDigest'] = $ReplayManifestDigest
    }
    $capture['requestTimeoutSeconds'] = $RequestTimeoutSeconds

    $sections = [System.Collections.Generic.List[object]]::new()
    foreach ($section in @($RuleSections)) {
        # Every field is carried. The v3 request contract requires the rule's own
        # repository triple and the heading its pin describes, and this is the
        # last layer that still has them: a projection that dropped them here
        # produced a request the builder could only resolve by defaulting to the
        # subject repository, which is the defect v3 exists to remove.
        foreach ($field in @('organization', 'project', 'repositoryId', 'path', 'commit', 'section', 'sha256', 'byteLength')) {
            if ($null -eq $section.PSObject.Properties[$field] -or $null -eq $section.PSObject.Properties[$field].Value) {
                throw "A rule section is missing '$field'; a v3 evidence request binds every section to its own repository and heading."
            }
        }
        [void]$sections.Add([ordered]@{
                organization = [string]$section.organization
                project      = [string]$section.project
                repositoryId = [string]$section.repositoryId
                path         = [string]$section.path
                commit       = [string]$section.commit
                section      = [string]$section.section
                sha256       = [string]$section.sha256
                byteLength   = [int]$section.byteLength
            })
    }

    return [ordered]@{
        schemaVersion = 3
        kind          = 'reviewer-cohort-entry-evidence-request'
        correlationId = $CorrelationId
        toolkit       = [ordered]@{
            repositoryRoot = $ToolkitRoot
            head           = $ToolkitHead.ToLowerInvariant()
            requiredRef    = $RequiredRef
        }
        subject       = [ordered]@{
            organization   = $Organization
            project        = $Project
            repositoryId   = $RepositoryId
            repositoryName = $RepositoryName
            pullRequestId  = $PullRequestId
            targetRefName  = $TargetRefName
        }
        reviewer      = [ordered]@{
            configPath          = $ConfigPath
            repositoryPath      = $RepositoryPath
            operatorAlias       = $OperatorAlias
            powerShellPath      = $PowerShellPath
            childTimeoutSeconds = $ChildTimeoutSeconds
            # Inert. The schema requires a planned run count of at least two, and
            # no run set is declared from this request, so nothing reads it.
            plannedRunCount     = 2
            runSetKeyPath       = $RunSetKeyPath
        }
        ruleBundle    = [ordered]@{
            sourceKind        = 'pinnedRepositorySections'
            declarationPath   = $RuleDeclarationPath
            declarationSha256 = $RuleDeclarationSha256
            sections          = $sections.ToArray()
        }
        capture       = $capture
        coverage      = [ordered]@{
            maxChangedFiles               = $MaxChangedFiles
            maxFileBytes                  = $MaxFileBytes
            maxSiblingFiles               = $MaxSiblingFiles
            maxThreads                    = $MaxThreads
            minChangedPathCoveragePercent = $MinChangedPathCoveragePercent
        }
        output        = [ordered]@{
            root        = $OutputRoot
            entryId     = $EntryId
            ordinal     = 1
            sealKeyPath = $SealKeyPath
        }
    }
}

function Read-OwnerPreviewSealedSnapshot {
    <#
        The identity of a sealed snapshot, read from the one file that travels
        with it.

        Read from manifest.json rather than recomputed, and every field required
        downstream is demanded rather than defaulted. The legacy projection below
        has to assert an iteration and a merge base; asserting either one from a
        guess would be asserting identity the seal cannot back, which is exactly
        what production role capture refuses.
    #>
    param(
        [Parameter(Mandatory)][string]$ReplayRoot,
        [Parameter(Mandatory)][string]$SnapshotName,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RepositoryName
    )
    $snapshotPath = Join-Path $ReplayRoot $SnapshotName
    $manifestPath = Join-Path $snapshotPath 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "The sealed snapshot '$SnapshotName' has no manifest.json under '$ReplayRoot'."
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 64

    $classification = $manifest.PSObject.Properties['classification']
    if ($null -eq $classification -or $null -eq $classification.Value) {
        throw "The snapshot '$SnapshotName' carries no classification; the Owner preview consumes only a permanently non-promotable seal."
    }
    $nonPromotable = $classification.Value.PSObject.Properties['nonPromotable']
    $sealKind = $classification.Value.PSObject.Properties['sealKind']
    if ($null -eq $nonPromotable -or -not [bool]$nonPromotable.Value) {
        throw "The snapshot '$SnapshotName' is not classified non-promotable; the Owner preview refuses a promotable input."
    }
    if ($null -eq $sealKind -or [string]$sealKind.Value -cne $script:OwnerPreviewSealKind) {
        throw "The snapshot '$SnapshotName' is sealed as '$([string]$sealKind.Value)', not '$script:OwnerPreviewSealKind'."
    }

    $binding = $manifest.binding
    $required = @('organization', 'project', 'repositoryId', 'pullRequestId',
        'iterationId', 'sourceCommit', 'commonCommit', 'targetCommit')
    foreach ($field in $required) {
        $property = $binding.PSObject.Properties[$field]
        if ($null -eq $property -or $null -eq $property.Value -or [string]$property.Value -eq '') {
            throw "The sealed snapshot binding for '$SnapshotName' omits '$field'; the Owner preview will not assert identity the seal cannot back."
        }
    }

    return [pscustomobject][ordered]@{
        SnapshotId     = [string]$manifest.snapshotId
        SnapshotPath   = $snapshotPath
        ManifestPath   = $manifestPath
        ManifestDigest = [string]$manifest.manifestDigest
        Provider       = [string]$manifest.provider
        SealKind       = [string]$sealKind.Value
        Organization   = [string]$binding.organization
        Project        = [string]$binding.project
        RepositoryId   = [string]$binding.repositoryId
        # The production replay manifest intentionally keys repositories by GUID.
        # The name was independently validated by the sealer against the corpus
        # index and is carried from that validated recipe/subject, not invented
        # from a manifest field the replay contract does not publish.
        RepositoryName = $RepositoryName
        PullRequestId  = [int]$binding.pullRequestId
        IterationId    = [int]$binding.iterationId
        SourceCommit   = [string]$binding.sourceCommit
        CommonCommit   = [string]$binding.commonCommit
        TargetCommit   = [string]$binding.targetCommit
        ChangeSetSha256 = [string]$binding.changeSetSha256
    }
}

function New-OwnerPreviewLegacyProjection {
    <#
        THE ONE NEW SEAM IN THIS LAYER.

        Production role capture only re-materializes the projection the benchmark
        pack materializer needs when it is HANDED a legacy
        `blinded-reviewer-adapter-input` document to re-materialize. Without one
        it still publishes, but it publishes only a standalone projection, which
        does not satisfy the materializer's legacy binding check - so the chain
        stops one step short of acquisition.

        Nothing in the repository produced that document outside a test helper,
        and the acquisition documentation says adding the flow is deliberately
        outside that tool. So it is added here, minimally: one seed, sealing
        exactly one resource - the manifest of the snapshot this subject was
        prepared from.

        The three fixtureIndexBinding hashes are DERIVED, not invented. The test
        helper fills them with repeated digits because nothing downstream reads
        them there; a production seed that shipped placeholder hashes would be a
        production artifact carrying three fields that look like evidence and are
        not. Each one is bound to something real about this subject instead.
    #>
    param(
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)][string]$PackRoot,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$CorpusIndexSha256,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$SealDigest
    )

    $sealedDirectory = Join-Path $PackRoot 'sealed-resources'
    if (-not (Test-Path -LiteralPath $sealedDirectory -PathType Container)) {
        [void](New-Item -ItemType Directory -Force -Path $sealedDirectory)
    }

    $manifestSha = Get-OwnerPreviewFileSha256 -Path $Snapshot.ManifestPath
    $sealedName = "$manifestSha-manifest.json"
    $sealedFull = Join-Path $sealedDirectory $sealedName
    $manifestBytes = [IO.File]::ReadAllBytes($Snapshot.ManifestPath)
    [IO.File]::WriteAllBytes($sealedFull, $manifestBytes)

    $binding = [ordered]@{
        provider     = $Snapshot.Provider
        repository   = $Snapshot.RepositoryName
        repositoryId = $Snapshot.RepositoryId
        pr           = [int]$Snapshot.PullRequestId
        iteration    = [int]$Snapshot.IterationId
        common       = ([string]$Snapshot.CommonCommit).ToLowerInvariant()
        source       = ([string]$Snapshot.SourceCommit).ToLowerInvariant()
        target       = ([string]$Snapshot.TargetCommit).ToLowerInvariant()
    }

    $projection = [ordered]@{
        schemaVersion       = 1
        kind                = 'blinded-reviewer-adapter-input'
        fixtureId           = [string]$Snapshot.SnapshotId
        fixtureVersion      = 1
        binding             = $binding
        bindingSha256       = (Get-OwnerPreviewCanonicalSha256 -Value $binding)
        fixtureIndexBinding = [ordered]@{
            # The corpus this subject was sealed from.
            fixtureIndexSha256        = $CorpusIndexSha256
            # The seal that published it.
            fixtureRecordHash         = $SealDigest
            # The manifest file these bytes actually are.
            originalFixtureFileSha256 = $manifestSha
        }
        resources           = @(
            [ordered]@{
                mediaRole  = 'replay-manifest'
                sealedPath = "sealed-resources/$sealedName"
                sha256     = $manifestSha
                byteLength = [long]$manifestBytes.LongLength
            }
        )
    }

    $projectionsDirectory = Join-Path $PackRoot 'projections'
    $projectionPath = Join-Path $projectionsDirectory 'owner-preview.minimal.blinded.json'
    [void](Write-OwnerPreviewJsonFile -Path $projectionPath -Value $projection)

    return [pscustomobject][ordered]@{
        Path               = $projectionPath
        PackRoot           = $PackRoot
        ManifestSha256     = $manifestSha
        SealedResourcePath = $sealedFull
        SealedResourceName = $sealedName
        ByteLength         = [long]$manifestBytes.LongLength
        FixtureId          = [string]$Snapshot.SnapshotId
    }
}

function New-OwnerPreviewCaptureRequest {
    <#
        The production role-input capture request, to
        reviewer.production-role-input-capture-request.v1.json.

        Identity is copied from the sealed snapshot rather than from the
        operator's command line. Capture refuses a request that asserts identity
        the seal cannot back, and the seal is the only party here in a position
        to know.
    #>
    param(
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)]$LegacyProjection,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')][string]$Model,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ConfigSha256,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ManifestFileSha256
    )
    $identity = [ordered]@{
        provider     = $Snapshot.Provider
        organization = $Snapshot.Organization
        project      = $Snapshot.Project
        repositoryId = $Snapshot.RepositoryId
        prId         = [int]$Snapshot.PullRequestId
        iteration    = [int]$Snapshot.IterationId
        source       = ([string]$Snapshot.SourceCommit).ToLowerInvariant()
        common       = ([string]$Snapshot.CommonCommit).ToLowerInvariant()
        target       = ([string]$Snapshot.TargetCommit).ToLowerInvariant()
        changeSet    = ([string]$Snapshot.ChangeSetSha256).ToLowerInvariant()
    }
    return [ordered]@{
        schemaVersion = 1
        kind          = 'reviewer-role-input-capture-request'
        fixtureId     = [string]$LegacyProjection.FixtureId
        role          = 'specialist'
        model         = $Model
        identity      = $identity
        snapshot      = [ordered]@{
            name               = [string]$Snapshot.SnapshotId
            manifestDigest     = ([string]$Snapshot.ManifestDigest).ToLowerInvariant()
            manifestFileSha256 = $ManifestFileSha256
            configSha256       = $ConfigSha256
        }
        resources     = @(
            [ordered]@{
                mediaRole  = 'replay-manifest'
                sealedPath = "sealed-resources/$([string]$LegacyProjection.SealedResourceName)"
                sha256     = [string]$LegacyProjection.ManifestSha256
                byteLength = [long]$LegacyProjection.ByteLength
            }
        )
    }
}

function Get-OwnerPreviewSubjectKey {
    <#
        The repository-and-pull-request identity, composed the way the cohort
        registry composes its own subject key so two layers naming the same
        subject produce the same string.
    #>
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][int]$PullRequestId
    )
    $repository = ("{0}/{1}/{2}" -f $Organization, $Project, $RepositoryId).ToLowerInvariant()
    return (Get-OwnerPreviewTextSha256 -Text ("{0}#{1}" -f $repository, $PullRequestId))
}

function Get-OwnerPreviewHeadKey {
    <#
        The charge key: everything that would make this a DIFFERENT preview.

        A subject key alone is not enough. It answers "which pull request", and
        two runs over one pull request at different heads, against different rule
        bytes, or with a different model are not the same evidence. Every input
        that could change a verdict is bound in here, so a changed head or a
        re-pinned rule becomes a new subject rather than silently overwriting the
        old one's answer.
    #>
    param(
        [Parameter(Mandatory)][string]$SubjectKey,
        [Parameter(Mandatory)][string]$SourceCommit,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$RuleSections,
        [Parameter(Mandatory)][string]$ReplayManifestDigest,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$ConfigSha256,
        [Parameter(Mandatory)][string]$ToolkitHead
    )
    $sections = [System.Collections.Generic.List[object]]::new()
    $ordered = @($RuleSections) | Sort-Object -Property `
    @{ Expression = { [string]$_.repositoryId } },
    @{ Expression = { [string]$_.path } },
    @{ Expression = { [string]$_.section } },
    @{ Expression = { [string]$_.commit } },
    @{ Expression = { [string]$_.sha256 } }
    foreach ($section in $ordered) {
        # repositoryId and section are bound here for the same reason path and
        # commit are: a rule read from a different repository, or a pin taken
        # over a different heading of the same document, is a different rule and
        # therefore a different preview. Leaving them out would let two
        # materially different previews collide on one key.
        [void]$sections.Add([ordered]@{
                repositoryId = ([string]$section.repositoryId).ToLowerInvariant()
                path         = [string]$section.path
                commit       = ([string]$section.commit).ToLowerInvariant()
                section      = [string]$section.section
                sha256       = ([string]$section.sha256).ToLowerInvariant()
            })
    }
    $material = [ordered]@{
        capability           = $script:OwnerPreviewCapabilityId
        subjectKey           = $SubjectKey.ToLowerInvariant()
        sourceCommit         = $SourceCommit.ToLowerInvariant()
        ruleSections         = $sections.ToArray()
        replayManifestDigest = $ReplayManifestDigest.ToLowerInvariant()
        model                = $Model
        configSha256         = $ConfigSha256.ToLowerInvariant()
        toolkitHead          = $ToolkitHead.ToLowerInvariant()
    }
    return (Get-OwnerPreviewCanonicalSha256 -Value $material)
}
