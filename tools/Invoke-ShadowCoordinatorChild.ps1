#!/usr/bin/env pwsh
<#
.SYNOPSIS
    The one child the shadow run coordinator starts. Reads a versioned request
    file, runs one reviewed tool, and writes a versioned result file.

.DESCRIPTION
    An adapter, deliberately thin. It owns no policy and reaches no conclusion:
    every step below hands its work to a tool that already exists and was already
    reviewed, and reports what that tool produced. If a step here started
    deciding something, the decision would live in a place nothing else tests.

    Two properties make it usable as a contract:

    The contract is files. The request arrives at -RequestPath and the result
    goes to the path the request names. Nothing contractual is written to
    standard output, so the caller never parses this script's chatter and a
    diagnostic line from a helper cannot become part of a result. Progress output
    from nested tools is silenced for the same reason.

    A failure is a failure. Any error terminates, and the result file is written
    with ok:$false before the non-zero exit. A caller therefore sees a failed
    step both ways round - by exit code and by contract - and a step that dies
    before writing anything leaves no result at all, which the caller also
    refuses.

.EXAMPLE
    ./tools/Invoke-ShadowCoordinatorChild.ps1 -RequestPath <request>.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RequestPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

$script:ShadowChildResultContract = 'devpilot.shadow-run-coordinator.child-result.v1'
$script:ShadowChildRequestContract = 'devpilot.shadow-run-coordinator.child-request.v1'
# The two versioned files the reconciliation step exchanges with its caller. They
# are named here rather than at their use sites so the writer and the reader can
# never drift onto different versions of the same document.
$script:ShadowReconciliationRequestVersion = 'devpilot.shadow-run-coordinator.reconciliation-request.v1'
$script:ShadowReconciliationSummaryVersion = 'devpilot.shadow-run-coordinator.reconciliation-summary.v1'
# The two versioned files the delivery decision exchanges with its caller, on the
# same terms.
$script:ShadowDeliveryRequestVersion = 'devpilot.shadow-run-coordinator.delivery-request.v1'
$script:ShadowDeliverySummaryVersion = 'devpilot.shadow-run-coordinator.delivery-summary.v1'
# The only authorization under which this adapter will evaluate a delivery
# decision. There is no second value and no switch that produces one.
$script:ShadowDeliveryPreviewOnlyKind = 'PreviewOnly'
# A digest of all zeroes says "this decision depended on nothing here", which is
# what the gate library's binding means by an absent dependency.
$script:ShadowDeliveryAbsentDigest = '0' * 64
$script:ShadowChildUtf8 = [System.Text.UTF8Encoding]::new($false, $true)

function Read-ShadowChildRequest {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "The child request '$Path' does not exist."
    }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0) { throw "The child request '$Path' is empty." }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw "The child request '$Path' begins with a byte-order mark; the contract is UTF-8 with no BOM."
    }
    try { $text = $script:ShadowChildUtf8.GetString($bytes) }
    catch { throw "The child request '$Path' is not strict UTF-8." }
    try { $request = $text | ConvertFrom-Json -Depth 32 -ErrorAction Stop }
    catch { throw "The child request '$Path' is not valid JSON." }
    if ($request -isnot [System.Management.Automation.PSCustomObject]) {
        throw "The child request '$Path' is not a JSON object."
    }
    foreach ($name in @('contractVersion', 'correlationId', 'step', 'resultPath', 'childRequestSha256')) {
        if (-not $request.PSObject.Properties[$name]) {
            throw "The child request '$Path' is missing '$name'."
        }
    }
    if ([string]$request.contractVersion -cne $script:ShadowChildRequestContract) {
        throw "The child request '$Path' declares contract '$($request.contractVersion)'."
    }
    return $request
}

function Get-ShadowChildField {
    <#
    .SYNOPSIS
        One declared field, refused rather than defaulted when it is absent or
        the wrong shape.
    #>
    param(
        [Parameter(Mandatory)]$Request,
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('string', 'int', 'bool', 'array')][string]$Type = 'string'
    )
    if (-not $Request.PSObject.Properties[$Name]) {
        throw "The child request is missing '$Name'."
    }
    $value = $Request.$Name
    switch ($Type) {
        'string' {
            if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
                throw "The child request field '$Name' is not a non-empty string."
            }
            return [string]$value
        }
        'int' {
            if ($value -isnot [int] -and $value -isnot [long]) {
                throw "The child request field '$Name' is not an integer."
            }
            return [int]$value
        }
        'bool' {
            if ($value -isnot [bool]) { throw "The child request field '$Name' is not a boolean." }
            return [bool]$value
        }
        'array' {
            # An absent array and an empty one are different facts, and a
            # one-element array that arrived as a scalar is a third. Only a real
            # array is accepted.
            if ($value -isnot [System.Array]) { throw "The child request field '$Name' is not an array." }
            return @($value)
        }
    }
}

function Get-ShadowChildOptionalField {
    <#
    .SYNOPSIS
        A field that may legitimately be absent, returned as '' when it is.
    .DESCRIPTION
        Kept separate from Get-ShadowChildField rather than added to it as a
        switch. A step that reads a required field must fail when it is missing,
        and one shared getter with an -Optional flag makes that failure one
        forgotten parameter away. Two getters make the choice visible at every
        call site.
    #>
    param(
        [Parameter(Mandatory)]$Request,
        [Parameter(Mandatory)][string]$Name
    )
    if (-not $Request.PSObject.Properties[$Name]) { return '' }
    $value = $Request.$Name
    if ($value -isnot [string]) { throw "The child request field '$Name' is not a string." }
    return [string]$value
}

function Write-ShadowChildResult {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$CorrelationId,
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][string]$ChildRequestSha256,
        [Parameter(Mandatory)][bool]$Ok,
        [hashtable]$Fields = @{},
        [string]$ErrorText = ''
    )
    $result = [ordered]@{
        contractVersion = $script:ShadowChildResultContract
        kind = 'shadow-run-coordinator-child-result'
        correlationId = $CorrelationId
        step = $Step
        # Echoed, not recomputed. It binds this result to the exact child request
        # that asked for the work, which is what lets a coordinator that was
        # killed before it could commit adopt this result instead of re-running a
        # step that refuses to repeat itself.
        childRequestSha256 = $ChildRequestSha256
        ok = $Ok
    }
    foreach ($name in ($Fields.Keys | Sort-Object)) { $result[$name] = $Fields[$name] }
    if ($ErrorText) { $result['error'] = $ErrorText }

    $directory = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        [void](New-Item -ItemType Directory -Force -Path $directory)
    }
    # Written through a sibling temporary and moved, so a coordinator reading
    # concurrently sees either no result or a whole one.
    $temporary = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    $text = (ConvertTo-Json -InputObject ([pscustomobject]$result) -Depth 16) + "`n"
    [IO.File]::WriteAllBytes($temporary, $script:ShadowChildUtf8.GetBytes($text))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Invoke-ShadowChildStagePreparation {
    param([Parameter(Mandatory)]$Request, [Parameter(Mandatory)][string]$ToolkitRoot)
    $directory = Get-ShadowChildField -Request $Request -Name 'artifactDirectory'
    $changed = @(Get-ShadowChildField -Request $Request -Name 'changedPaths' -Type array)
    if ($changed.Count -lt 2) {
        throw "The stage preparation needs at least two changed paths; it was given $($changed.Count)."
    }
    . (Join-Path $ToolkitRoot 'src\Agents\reviewer\ShadowPreparation.ps1')
    # The step must be re-enterable: a coordinator killed after publication but
    # before its commit runs this again, and the stage writer names artifacts by
    # a per-call sequence, so leftovers from the lost attempt would accumulate.
    #
    # Only this producer's own output is removed. A blanket '*.json' sweep would
    # take the directory's ownership marker with it, and the stage switch refuses
    # to adopt a populated directory that carries no marker - so the cleanup that
    # exists to make the retry possible would be the thing that made it
    # impossible. The empty reservation tombstones are named after the artifacts
    # they reserve and go with them.
    $stale = @()
    if (Test-Path -LiteralPath $directory) {
        $stale = @(Get-ChildItem -LiteralPath $directory -Filter '*.stage.json' -File -ErrorAction SilentlyContinue)
        foreach ($item in $stale) {
            $reservation = "$($item.FullName).reservation"
            if (Test-Path -LiteralPath $reservation -PathType Leaf) {
                Remove-Item -LiteralPath $reservation -Force
            }
            Remove-Item -LiteralPath $item.FullName -Force
        }
    }
    $prepared = Invoke-ReviewerShadowPreparation -Directory $directory `
        -ChangedPath ([string[]]$changed)
    return @{
        artifactDirectory = [string]$prepared.Directory
        publishedCount = [int]$prepared.PublishedCount
        discardedCount = [int]$stale.Count
    }
}

function Invoke-ShadowChildCorpusSeal {
    param([Parameter(Mandatory)]$Request, [Parameter(Mandatory)][string]$ToolkitRoot)
    $corpusRoot = Get-ShadowChildField -Request $Request -Name 'corpusRoot'
    $indexSha = Get-ShadowChildField -Request $Request -Name 'corpusIndexSha256'
    $recipePath = Get-ShadowChildField -Request $Request -Name 'recipePath'
    $recipeSha = Get-ShadowChildField -Request $Request -Name 'recipeSha256'
    $replayRoot = Get-ShadowChildField -Request $Request -Name 'replayRoot'
    $validateOnly = Get-ShadowChildField -Request $Request -Name 'validateOnly' -Type bool

    # The caller binds the recipe by content, not by path. The digest is checked
    # here for a clear early failure, and passed to the sealer so the SAME digest
    # is checked over the exact bytes it parses - which is what actually closes
    # the window, because a path the coordinator hashed a moment ago is not
    # necessarily the bytes this child seals.
    if (-not (Test-Path -LiteralPath $recipePath -PathType Leaf)) {
        throw "The corpus recipe '$recipePath' does not exist."
    }
    $recipeActual = (Get-FileHash -LiteralPath $recipePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($recipeActual -cne ([string]$recipeSha).ToLowerInvariant()) {
        throw "The corpus recipe '$recipePath' hashes to $recipeActual and the request bound $recipeSha."
    }

    # The sealer resolves its replay root as a real path, so the directory has to
    # exist before it is named. Creating it here is not the same as writing a
    # snapshot into it, which is what -ValidateOnly still refuses to do.
    if (-not (Test-Path -LiteralPath $replayRoot -PathType Container)) {
        [void](New-Item -ItemType Directory -Force -Path $replayRoot)
    }

    $tool = Join-Path $ToolkitRoot 'tools\Save-CorpusReplaySeal.ps1'
    if ($validateOnly) {
        & $tool -CorpusRoot $corpusRoot -CorpusIndexSha256 $indexSha -Recipe $recipePath `
            -RecipeSha256 $recipeSha -ReplayRoot $replayRoot -ValidateOnly | Out-Null
        return @{ validateOnly = $true; replayRoot = [string]$replayRoot }
    }

    # A snapshot this request already published is adopted rather than resealed.
    # The snapshot id is deterministic from the recipe, and the sealer refuses an
    # existing id without -Force, so a coordinator killed after publication but
    # before it could commit would otherwise wedge this output root permanently:
    # every later resume would reseal, be refused, and fail identically. Passing
    # -Force instead would be worse, because it would let a genuinely different
    # request quietly overwrite sealed evidence.
    $adopted = Get-ShadowChildPublishedSnapshot -RecipePath $recipePath -RecipeSha256 $recipeSha `
        -ReplayRoot $replayRoot -ToolkitRoot $ToolkitRoot
    if ($null -ne $adopted) { return $adopted }

    $sealed = & $tool -CorpusRoot $corpusRoot -CorpusIndexSha256 $indexSha -Recipe $recipePath `
        -RecipeSha256 $recipeSha -ReplayRoot $replayRoot
    $sealed = @($sealed)[-1]
    if ($null -eq $sealed -or -not $sealed.PSObject.Properties['SnapshotId']) {
        throw 'The corpus sealer produced no snapshot record.'
    }
    $snapshotId = [string]$sealed.SnapshotId
    $manifestPath = Join-Path (Join-Path $replayRoot $snapshotId) 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "The corpus sealer reported snapshot '$snapshotId' but wrote no manifest at '$manifestPath'."
    }
    return @{
        snapshotName = $snapshotId
        manifestPath = [string]([IO.Path]::GetFullPath($manifestPath))
        manifestSha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        manifestDigest = ([string]$sealed.ManifestDigest).ToLowerInvariant()
        validateOnly = $false
        adopted = $false
    }
}

function Get-ShadowChildPublishedSnapshot {
    <#
    .SYNOPSIS
        The snapshot this recipe already published under this replay root, or
        nothing when there is none.
    .DESCRIPTION
        Adoption is never a matter of trusting what is on disk. The candidate is
        re-verified with the production loader against the digest its own manifest
        declares, so a snapshot that was truncated, tampered with or only half
        published is not adopted: it is left for the sealer to refuse.
    #>
    param(
        [Parameter(Mandatory)][string]$RecipePath,
        [Parameter(Mandatory)][string]$RecipeSha256,
        [Parameter(Mandatory)][string]$ReplayRoot,
        [Parameter(Mandatory)][string]$ToolkitRoot
    )
    if (-not (Test-Path -LiteralPath $RecipePath -PathType Leaf)) { return $null }
    # Read the bytes ONCE and bind them before deriving anything from them. The
    # snapshot id chosen here decides which published snapshot is adopted, so a
    # recipe swapped after the caller hashed it could otherwise point adoption at
    # a snapshot no request in this preparation ever asked for.
    $recipeBytes = [IO.File]::ReadAllBytes($RecipePath)
    $recipeActual = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($recipeBytes)).ToLowerInvariant()
    if ($recipeActual -cne ([string]$RecipeSha256).ToLowerInvariant()) {
        throw "The corpus recipe '$RecipePath' hashes to $recipeActual and the request bound $RecipeSha256."
    }
    $recipe = $script:ShadowChildUtf8.GetString($recipeBytes) | ConvertFrom-Json -Depth 32
    $recipeNames = @($recipe.PSObject.Properties | ForEach-Object { $_.Name })
    if ($recipeNames -notcontains 'snapshotId') { return $null }
    $snapshotId = [string]$recipe.snapshotId
    if ([string]::IsNullOrWhiteSpace($snapshotId)) { return $null }

    $manifestPath = Join-Path (Join-Path $ReplayRoot $snapshotId) 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return $null }

    $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json -Depth 32
    $manifestNames = @($manifest.PSObject.Properties | ForEach-Object { $_.Name })
    if ($manifestNames -notcontains 'manifestDigest') { return $null }
    $digest = ([string]$manifest.manifestDigest).ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($digest)) { return $null }

    Import-Module (Join-Path $ToolkitRoot 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force -ErrorAction Stop
    # The production loader, bound to the digest the manifest declares. If this
    # refuses, the snapshot is not adoptable and the caller reseals.
    [void](New-AgentReplaySnapshot -ReplayRoot $ReplayRoot -SnapshotName $snapshotId -ExpectedManifestDigest $digest)

    return @{
        snapshotName = $snapshotId
        manifestPath = [string]([IO.Path]::GetFullPath($manifestPath))
        manifestSha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        manifestDigest = $digest
        validateOnly = $false
        adopted = $true
    }
}

function Invoke-ShadowChildRunSetDeclare {
    param([Parameter(Mandatory)]$Request, [Parameter(Mandatory)][string]$ToolkitRoot)
    $qualificationRoot = Get-ShadowChildField -Request $Request -Name 'qualificationRoot'
    # Optional, and resolved to the production agent when absent. It is the plan
    # digest's business rather than this adapter's which agent runs: the digest
    # seals the script path AND its content hash, so a declaration made naming
    # one agent cannot be launched naming another.
    $reviewerScriptPath = Get-ShadowChildOptionalField -Request $Request -Name 'reviewerScriptPath'
    if (-not $reviewerScriptPath) {
        $reviewerScriptPath = Join-Path $ToolkitRoot 'src\Agents\reviewer\Start-ReviewerAgent.ps1'
    }
    $arguments = @{
        Mode = 'Declare'
        RepoPath = (Get-ShadowChildField -Request $Request -Name 'reviewerRepositoryPath')
        ConfigFile = (Get-ShadowChildField -Request $Request -Name 'reviewerConfigPath')
        OperatorAlias = (Get-ShadowChildField -Request $Request -Name 'operatorAlias')
        PullRequestId = (Get-ShadowChildField -Request $Request -Name 'pullRequestId' -Type int)
        ReplayRoot = (Get-ShadowChildField -Request $Request -Name 'replayRoot')
        ReplaySnapshotName = (Get-ShadowChildField -Request $Request -Name 'snapshotName')
        ReplayManifestDigest = (Get-ShadowChildField -Request $Request -Name 'manifestDigest')
        QualificationRoot = $qualificationRoot
        ExpectedCommit = (Get-ShadowChildField -Request $Request -Name 'expectedCommit')
        RequiredRef = (Get-ShadowChildField -Request $Request -Name 'requiredRef')
        ReviewerScriptPath = $reviewerScriptPath
        SlotCount = (Get-ShadowChildField -Request $Request -Name 'plannedRunCount' -Type int)
        RunSetKeyPath = (Get-ShadowChildField -Request $Request -Name 'runSetKeyPath')
        Purpose = 'shadow-run-coordinator preparation'
    }

    $tool = Join-Path $ToolkitRoot 'tools\Invoke-ReviewerReplayQualification.ps1'
    $runSetDirectory = Join-Path $qualificationRoot 'runset'

    # Adoption, for the same reason the sealer has it: a declaration this request
    # already published is adopted rather than declared a second time. The
    # qualification tool refuses a second declaration outright, so re-running it
    # after a kill that landed between publication and the coordinator's commit
    # would wedge the run permanently.
    #
    # A found declaration is not evidence on its own. Adoption re-verifies its
    # signature and then binds it to the FULL plan this request would have
    # declared - the reviewed repository, the config, the operator, the commit and
    # ref, the models and every timeout - through the same production assertions
    # the qualification tool itself uses. Snapshot, digest and slot count alone
    # cannot see a declaration that was sealed for a different qualification, and
    # a signature cannot either: one key signs every declaration in a root.
    $existing = @(Get-ChildItem -LiteralPath $runSetDirectory -Filter 'runset-*.json' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike '*.sig' })
    if ($existing.Count -eq 1) {
        Import-Module (Join-Path $ToolkitRoot 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force -ErrorAction Stop
        . (Join-Path $ToolkitRoot 'src\Agents\reviewer\QualificationPreflight.ps1')
        . (Join-Path $ToolkitRoot 'src\Agents\reviewer\ReplayQualification.ps1')
        $compareTool = Join-Path $ToolkitRoot 'tools\Compare-ReviewerReplayRuns.ps1'
        $tokenPath = Join-Path $runSetDirectory 'launch-authorization.token'
        # The plan digest binds the launch-authorization hash, and Declare mints
        # that token at random - so the plan is reproducible only by reading the
        # token the declaration itself minted, exactly as the RunSlot path does.
        # A declaration whose token is gone is not adoptable: without it the plan
        # cannot be reproduced, and adopting on the strength of the fields that
        # remain is the substitution this check exists to refuse.
        if (-not (Test-Path -LiteralPath $tokenPath -PathType Leaf)) {
            throw ("The standing run set at '$runSetDirectory' has no launch-authorization token, " +
                'so the plan it was sealed under cannot be reproduced and it is not adopted.')
        }
        $adoptionLaunchHash = Get-ReviewerQualificationLaunchTokenHash `
            -Token (([IO.File]::ReadAllText($tokenPath)).Trim())
        # Reproduced exactly as the qualification tool builds it, so the digest
        # below is the digest the declaration was sealed under or the declaration
        # is not this preparation's.
        $adoptionPlan = New-ReviewerReplayQualificationPlan -RepoPath $arguments.RepoPath `
            -ConfigFile $arguments.ConfigFile -OperatorAlias $arguments.OperatorAlias `
            -PullRequestId $arguments.PullRequestId -ReplayRoot $arguments.ReplayRoot `
            -ReplaySnapshotName $arguments.ReplaySnapshotName `
            -ReplayManifestDigest $arguments.ReplayManifestDigest -QualificationRoot $qualificationRoot `
            -ReviewerScriptPath $arguments.ReviewerScriptPath `
            -ToolkitRepositoryPath '' -ExpectedCommit $arguments.ExpectedCommit `
            -RequiredRef $arguments.RequiredRef -SlotCount $arguments.SlotCount `
            -LaunchAuthorizationHash $adoptionLaunchHash
        $adoptionPlanDigest = Get-ReviewerQualificationPlanDigest -Plan $adoptionPlan
        # Verification and plan binding share one refusal: adoption is a POSITIVE
        # proof that the standing declaration is this preparation's, so anything
        # that stops that proof - an unverifiable seal as much as a foreign plan -
        # means the set is not adopted.
        try {
            $adoptionVerified = Get-VerifiedRunSetDeclaration -RunSetDirectory $runSetDirectory `
                -CompareTool $compareTool -RunSetKeyPath $arguments.RunSetKeyPath
            Assert-ReviewerQualificationDeclarationMatchesPlan -Declaration $adoptionVerified.Declaration `
                -Plan $adoptionPlan -ExpectedPlanDigest $adoptionPlanDigest
        }
        catch {
            throw ("The standing run set belongs to another preparation and is not adopted: " +
                "$($_.Exception.Message)")
        }
        return @{
            runSetPath = [string]$adoptionVerified.Path
            launchTokenPresent = $true
            adopted = $true
        }
    }
    if ($existing.Count -gt 1) {
        throw "'$runSetDirectory' already holds $($existing.Count) run set(s); exactly one or none was expected."
    }

    & $tool @arguments | Out-Null

    $declared = @(Get-ChildItem -LiteralPath $runSetDirectory -Filter 'runset-*.json' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike '*.sig' })
    if ($declared.Count -ne 1) {
        throw "The declaration published $($declared.Count) run set(s) under '$runSetDirectory'; exactly one was expected."
    }
    $tokenPath = Join-Path $runSetDirectory 'launch-authorization.token'
    return @{
        runSetPath = [string]$declared[0].FullName
        launchTokenPresent = [bool](Test-Path -LiteralPath $tokenPath -PathType Leaf)
        adopted = $false
    }
}

function Invoke-ShadowChildRunSetVerify {
    param([Parameter(Mandatory)]$Request, [Parameter(Mandatory)][string]$ToolkitRoot)
    $runSetPath = Get-ShadowChildField -Request $Request -Name 'runSetPath'
    $keyPath = Get-ShadowChildField -Request $Request -Name 'runSetKeyPath'
    $tool = Join-Path $ToolkitRoot 'tools\Compare-ReviewerReplayRuns.ps1'
    $emitted = & $tool -VerifyRunSet -RunSetPath $runSetPath -KeyPath @($keyPath) -RunSetKeyPath $keyPath
    $json = @($emitted | Where-Object { $_ -is [string] })[-1]
    if (-not $json) { throw 'The run-set verification emitted no manifest.' }
    $manifest = $json | ConvertFrom-Json -Depth 16
    return @{
        signatureVerified = $true
        setId = [string]$manifest.setId
        snapshotName = [string]$manifest.snapshotName
        plannedRunCount = [int]$manifest.plannedRunCount
    }
}

function Invoke-ShadowChildRunSetStatus {
    param([Parameter(Mandatory)]$Request, [Parameter(Mandatory)][string]$ToolkitRoot)
    $qualificationRoot = Get-ShadowChildField -Request $Request -Name 'qualificationRoot'
    $reportPath = Join-Path $qualificationRoot 'coordinator-status.json'
    # The FULL plan inputs, not just the key: without them the status tool reports
    # an unauthenticated evidence view and cannot say whether the declaration is
    # genuinely signed. Run-set-ready is an authenticated claim, so the weaker
    # read would not support it.
    $arguments = @{
        QualificationRoot = $qualificationRoot
        RunSetKeyPath = (Get-ShadowChildField -Request $Request -Name 'runSetKeyPath')
        RepoPath = (Get-ShadowChildField -Request $Request -Name 'reviewerRepositoryPath')
        ConfigFile = (Get-ShadowChildField -Request $Request -Name 'reviewerConfigPath')
        OperatorAlias = (Get-ShadowChildField -Request $Request -Name 'operatorAlias')
        PullRequestId = (Get-ShadowChildField -Request $Request -Name 'pullRequestId' -Type int)
        ReplayRoot = (Get-ShadowChildField -Request $Request -Name 'replayRoot')
        ReplaySnapshotName = (Get-ShadowChildField -Request $Request -Name 'snapshotName')
        ReplayManifestDigest = (Get-ShadowChildField -Request $Request -Name 'manifestDigest')
        ExpectedCommit = (Get-ShadowChildField -Request $Request -Name 'expectedCommit')
        RequiredRef = (Get-ShadowChildField -Request $Request -Name 'requiredRef')
        SlotCount = (Get-ShadowChildField -Request $Request -Name 'plannedRunCount' -Type int)
        ReportPath = $reportPath
    }
    $statusReviewerScript = Get-ShadowChildOptionalField -Request $Request -Name 'reviewerScriptPath'
    if ($statusReviewerScript) { $arguments.ReviewerScriptPath = $statusReviewerScript }
    $tool = Join-Path $ToolkitRoot 'tools\Get-ReviewerReplayQualificationStatus.ps1'
    $status = & $tool @arguments
    $status = @($status | Where-Object { $_ -is [System.Management.Automation.PSCustomObject] })[-1]
    if ($null -eq $status) { throw 'The qualification status tool produced no status.' }
    if (-not $status.PSObject.Properties['declaration'] -or $null -eq $status.declaration) {
        throw 'The qualification status reports no declaration.'
    }
    if ([bool]$status.signatureUnverified) {
        throw 'The qualification status could not verify the declaration signature.'
    }
    if ([bool]$status.declarationCorrupt) {
        throw 'The qualification status reports a corrupt declaration.'
    }
    return @{
        launchTokenPresent = [bool]$status.declaration.launchTokenPresent
        plannedRunCount = [int]$status.declaration.plannedRunCount
        setId = [string]$status.declaration.setId
        slotAttemptCount = [int]$status.slotsAttempted
        # A census of the reviewer processes this run set has launched: one attempt
        # record per launch. Diagnostic, and named for what it counts rather than
        # for what it was once mistaken for.
        slotAttemptRecordCount = @(Get-ChildItem -LiteralPath $qualificationRoot -Filter 'slot*-attempt.json' `
                -File -Recurse -ErrorAction SilentlyContinue).Count
        # A census of the run directories a reviewer would have to have created
        # before it could start a model. Measured by enumeration, so that the
        # 'nothing has run yet' the coordinator asserts before launching is a
        # reading of the disk and not a constant that would say the same either way.
        preLaunchRunRootCount = @(Get-ChildItem -LiteralPath $qualificationRoot -Directory -Recurse `
                -Filter 'replay' -ErrorAction SilentlyContinue |
                ForEach-Object { @(Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue) } |
                Where-Object { $null -ne $_ }).Count
        statusReportPath = [string]([IO.Path]::GetFullPath($reportPath))
    }
}

# ---------------------------------------------------------------------------
# Supervised slot steps.
#
# The coordinator owns authorization, durable state and process supervision. It
# owns none of what follows: the plan, the declaration binding, the launch
# authorization, the run itself and the terminal evidence are all the reviewed
# qualification path's, and these three steps do no more than run it and report
# what it produced. Nothing here selects a model, ranks a candidate, arbitrates a
# severity or reaches a verdict, and nothing here writes to any provider.
# ---------------------------------------------------------------------------

function Get-ShadowChildArgumentValue {
    <#
    .SYNOPSIS
        One integer value out of a slot's sealed argument array.
    .DESCRIPTION
        Read from the argv the plan digest seals rather than from a parameter
        default, so the number a supervisor is bounded by is the number the
        declaration was signed over. An absent or unparsable value is refused: a
        default substituted here would be a budget nobody sealed.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Argv,
        [Parameter(Mandatory)][string]$Name
    )
    for ($index = 0; $index -lt $Argv.Count - 1; $index++) {
        if ($Argv[$index] -ceq $Name) {
            $parsed = 0
            if (-not [int]::TryParse($Argv[$index + 1], [ref]$parsed)) {
                throw "The sealed slot argument '$Name' carries '$($Argv[$index + 1])', which is not an integer."
            }
            return $parsed
        }
    }
    throw "The sealed slot arguments carry no '$Name'."
}

function Get-ShadowChildSlotContext {
    <#
    .SYNOPSIS
        Rebuilds the reviewed qualification plan for one slot and binds it to the
        signed declaration.
    .DESCRIPTION
        A read, not a second construction. The plan comes from the production
        builder and the binding from the production assertions, so a plan this
        adapter could build but the declaration was not sealed under is refused
        by the same code that refuses it in the qualification tool itself.
    #>
    param([Parameter(Mandatory)]$Request, [Parameter(Mandatory)][string]$ToolkitRoot)

    $qualificationRoot = Get-ShadowChildField -Request $Request -Name 'qualificationRoot'
    $slotName = Get-ShadowChildField -Request $Request -Name 'slotName'
    $tokenPath = Get-ShadowChildField -Request $Request -Name 'launchAuthorizationTokenPath'
    $reviewerScriptPath = Get-ShadowChildOptionalField -Request $Request -Name 'reviewerScriptPath'
    if (-not $reviewerScriptPath) {
        $reviewerScriptPath = Join-Path $ToolkitRoot 'src\Agents\reviewer\Start-ReviewerAgent.ps1'
    }
    if (-not (Test-Path -LiteralPath $tokenPath -PathType Leaf)) {
        throw "The launch-authorization token '$tokenPath' does not exist."
    }

    $runSetDirectory = Join-Path $qualificationRoot 'runset'
    # The inventory check comes first and returns the token the published set
    # actually carries. A set whose token is gone is an incomplete publish, and
    # reading the caller's token file instead would let a slot launch against a
    # set that is missing the very thing its plan digest seals.
    $publishedToken = Assert-ReviewerQualificationPublishedInventory -RunSetDirectory $runSetDirectory
    $presentedToken = ([IO.File]::ReadAllText($tokenPath)).Trim()
    if ($presentedToken -cne $publishedToken) {
        throw ('The launch-authorization token presented for this slot is not the token the published run set ' +
            'carries, so the plan it was sealed under cannot be reproduced.')
    }
    $launchHash = Get-ReviewerQualificationLaunchTokenHash -Token $presentedToken

    $plan = New-ReviewerReplayQualificationPlan `
        -RepoPath (Get-ShadowChildField -Request $Request -Name 'reviewerRepositoryPath') `
        -ConfigFile (Get-ShadowChildField -Request $Request -Name 'reviewerConfigPath') `
        -OperatorAlias (Get-ShadowChildField -Request $Request -Name 'operatorAlias') `
        -PullRequestId (Get-ShadowChildField -Request $Request -Name 'pullRequestId' -Type int) `
        -ReplayRoot (Get-ShadowChildField -Request $Request -Name 'replayRoot') `
        -ReplaySnapshotName (Get-ShadowChildField -Request $Request -Name 'snapshotName') `
        -ReplayManifestDigest (Get-ShadowChildField -Request $Request -Name 'manifestDigest') `
        -QualificationRoot $qualificationRoot `
        -ReviewerScriptPath $reviewerScriptPath `
        -ToolkitRepositoryPath '' `
        -ExpectedCommit (Get-ShadowChildField -Request $Request -Name 'expectedCommit') `
        -RequiredRef (Get-ShadowChildField -Request $Request -Name 'requiredRef') `
        -SlotCount (Get-ShadowChildField -Request $Request -Name 'plannedRunCount' -Type int) `
        -LaunchAuthorizationHash $launchHash
    $planDigest = Get-ReviewerQualificationPlanDigest -Plan $plan

    $target = @(@($plan.Slots) | Where-Object { $_.Name -ceq $slotName }) | Select-Object -First 1
    if (-not $target) {
        throw "Slot '$slotName' is not part of this $($plan.SlotCount)-slot plan."
    }

    # The caller may declare, opaquely, which sealed arguments this slot must
    # have been planned with. The strings are never interpreted here either -
    # they are matched against the slot's own sealed argv, which the plan digest
    # covers. That makes the declaration a BINDING rather than an instruction:
    # the caller cannot choose what the slot runs, only refuse to proceed if the
    # reviewed plan did not already choose what the caller expected.
    $bindSealed = Get-ShadowChildField -Request $Request -Name 'bindSealedArguments' -Type bool
    if ($bindSealed) {
        $declaredArguments = @(Get-ShadowChildField -Request $Request -Name 'opaqueSlotArguments' -Type array)
        if (@($declaredArguments).Count -eq 0) {
            throw "Slot '$slotName' asks to bind sealed arguments and declares none."
        }
        $sealedArguments = @(@($target.Arguments) | ForEach-Object { [string]$_ })
        foreach ($declared in $declaredArguments) {
            if ($sealedArguments -cnotcontains [string]$declared) {
                # The value is not echoed. A caller that guessed wrongly learns
                # that it guessed wrongly, and a log of this refusal does not
                # become a record of what was guessed.
                throw ("Slot '$slotName' was declared with an argument the reviewed plan did not seal for it, " +
                    "so the plan the caller expected is not the plan this set was declared under.")
            }
        }
    }

    $compareTool = Join-Path $ToolkitRoot 'tools\Compare-ReviewerReplayRuns.ps1'
    $keyPath = Get-ShadowChildField -Request $Request -Name 'runSetKeyPath'
    $verified = Get-VerifiedRunSetDeclaration -RunSetDirectory $runSetDirectory `
        -CompareTool $compareTool -RunSetKeyPath $keyPath
    Assert-ReviewerQualificationDeclarationMatchesPlan -Declaration $verified.Declaration `
        -Plan $plan -ExpectedPlanDigest $planDigest

    # The caller declared which plan and which set it authorized. Checked here so
    # a plan that drifted between authorization and use is refused by the step
    # that would have acted on it, rather than noticed afterwards.
    $expectedPlanDigest = Get-ShadowChildOptionalField -Request $Request -Name 'expectedPlanDigest'
    if ($expectedPlanDigest -and $expectedPlanDigest -cne $planDigest) {
        throw "The rebuilt qualification plan digests to '$planDigest' and the caller authorized '$expectedPlanDigest'."
    }
    $expectedSetId = Get-ShadowChildOptionalField -Request $Request -Name 'expectedSetId'
    if ($expectedSetId -and $expectedSetId -cne [string]$verified.Declaration.setId) {
        throw "The published run set is '$([string]$verified.Declaration.setId)' and the caller authorized '$expectedSetId'."
    }

    return @{
        Plan = $plan
        PlanDigest = $planDigest
        Target = $target
        SetId = [string]$verified.Declaration.setId
        LaunchHash = $launchHash
        LaunchTokenPath = ([IO.Path]::GetFullPath($tokenPath))
        RunSetDirectory = $runSetDirectory
        RunSetKeyPath = $keyPath
        ReviewerScriptPath = $reviewerScriptPath
        AttemptPath = (Join-Path $plan.RunDirectory "$($target.Name)-attempt.json")
    }
}

function Invoke-ShadowChildSlotPlan {
    <#
    .SYNOPSIS
        Reports the plan a launch would use, and whether the launch is still
        available. Launches nothing.
    .NOTES
        The reviewed qualification sources are loaded HERE rather than inside the
        context builder. Dot-sourcing from inside a function defines its
        functions in that function's own scope, which is gone the moment it
        returns; loading at the step keeps them alive for the whole step and,
        because a called function runs in a child scope, the context builder sees
        them too.
    #>
    param([Parameter(Mandatory)]$Request, [Parameter(Mandatory)][string]$ToolkitRoot)
    Import-Module (Join-Path $ToolkitRoot 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force -ErrorAction Stop
    . (Join-Path $ToolkitRoot 'src\Agents\reviewer\QualificationPreflight.ps1')
    . (Join-Path $ToolkitRoot 'src\Agents\reviewer\ReplayQualification.ps1')
    $context = Get-ShadowChildSlotContext -Request $Request -ToolkitRoot $ToolkitRoot
    $plan = $context.Plan
    $target = $context.Target
    # Read through the production resolver rather than by constructing a path.
    # On Windows a constructed open is case-insensitive, so a physical
    # 'Slot1-terminal.json' would answer for 'slot1-terminal.json'.
    $terminalPath = Resolve-ReviewerQualificationSlotTerminalPath -RunDirectory $plan.RunDirectory `
        -SlotName $target.Name
    # The one budget the plan does not publish as a field: the longest a single
    # reviewed call may take. It is read back out of the slot's own sealed argv,
    # which the plan digest covers, so a supervisor bounded by it is bounded by
    # the sealed plan rather than by a number invented here.
    $perCallTimeoutSeconds = [Math]::Max(
        (Get-ShadowChildArgumentValue -Argv $target.Arguments -Name '-CycleTimeoutSeconds'),
        [Math]::Max(
            (Get-ShadowChildArgumentValue -Argv $target.Arguments -Name '-ConventionSpecialistTimeoutSeconds'),
            (Get-ShadowChildArgumentValue -Argv $target.Arguments -Name '-VerificationTimeoutSeconds')))
    return @{
        setId = $context.SetId
        planDigest = $context.PlanDigest
        launchAuthorizationHash = $context.LaunchHash
        reviewerScriptSha256 = [string]$plan.ReviewerScriptSha256
        slotName = [string]$target.Name
        slotStateDir = [string]$target.StateDir
        slotTerminalPath = [string]$target.TerminalPath
        slotAttemptExists = [bool](Test-Path -LiteralPath $context.AttemptPath)
        slotTerminalExists = [bool]($null -ne $terminalPath)
        slotTimeoutSeconds = [int]$plan.SlotTimeoutSeconds
        progressTimeoutSeconds = [int]$plan.ProgressTimeoutSeconds
        perCallTimeoutSeconds = $perCallTimeoutSeconds
        head = [string]$plan.GitIdentity.head
        requiredRef = [string]$plan.GitIdentity.requiredRef
        headClean = [bool]$plan.GitIdentity.clean
        deliveryMode = [string]$plan.DeliveryMode
        promotable = [bool]$plan.Promotable
    }
}

function Invoke-ShadowChildSlotRun {
    <#
    .SYNOPSIS
        Runs exactly one slot through the reviewed qualification tool and reports
        that it produced terminal evidence.
    .DESCRIPTION
        The exit code is DATA here, not a verdict. A qualification slot whose
        reviewed run fails exits non-zero by design and writes an immutable
        terminal record saying so - a perfectly successful supervision of an
        unsuccessful run. So this step succeeds when the evidence exists and
        fails when it does not, and the exit code travels alongside as an opaque
        number for the caller's record.

        Loads the reviewed sources at this scope for the reason given on
        Invoke-ShadowChildSlotPlan.
    #>
    param([Parameter(Mandatory)]$Request, [Parameter(Mandatory)][string]$ToolkitRoot)
    Import-Module (Join-Path $ToolkitRoot 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force -ErrorAction Stop
    . (Join-Path $ToolkitRoot 'src\Agents\reviewer\QualificationPreflight.ps1')
    . (Join-Path $ToolkitRoot 'src\Agents\reviewer\ReplayQualification.ps1')
    $context = Get-ShadowChildSlotContext -Request $Request -ToolkitRoot $ToolkitRoot
    $plan = $context.Plan
    $target = $context.Target
    if (Test-Path -LiteralPath $context.AttemptPath) {
        throw ("Slot '$($target.Name)' has already been attempted; its single-use launch authorization is spent " +
            'and this adapter does not attempt a slot twice.')
    }

    $tool = Join-Path $ToolkitRoot 'tools\Invoke-ReviewerReplayQualification.ps1'
    $arguments = @{
        Mode = 'RunSlot'
        Slot = [string]$target.Name
        RepoPath = (Get-ShadowChildField -Request $Request -Name 'reviewerRepositoryPath')
        ConfigFile = (Get-ShadowChildField -Request $Request -Name 'reviewerConfigPath')
        OperatorAlias = (Get-ShadowChildField -Request $Request -Name 'operatorAlias')
        PullRequestId = (Get-ShadowChildField -Request $Request -Name 'pullRequestId' -Type int)
        ReplayRoot = (Get-ShadowChildField -Request $Request -Name 'replayRoot')
        ReplaySnapshotName = (Get-ShadowChildField -Request $Request -Name 'snapshotName')
        ReplayManifestDigest = (Get-ShadowChildField -Request $Request -Name 'manifestDigest')
        QualificationRoot = (Get-ShadowChildField -Request $Request -Name 'qualificationRoot')
        ExpectedCommit = (Get-ShadowChildField -Request $Request -Name 'expectedCommit')
        RequiredRef = (Get-ShadowChildField -Request $Request -Name 'requiredRef')
        ReviewerScriptPath = $context.ReviewerScriptPath
        SlotCount = (Get-ShadowChildField -Request $Request -Name 'plannedRunCount' -Type int)
        RunSetKeyPath = $context.RunSetKeyPath
        LaunchAuthorizationTokenPath = $context.LaunchTokenPath
    }

    # Invoked as a child script rather than dot-sourced. The tool ends in `exit`,
    # which dot-sourced would terminate this adapter before it could write its
    # own result file - and a supervised step that leaves no result is exactly
    # the fault the file contract exists to catch.
    $global:LASTEXITCODE = 0
    & $tool @arguments
    $slotExitCode = if ($null -eq $global:LASTEXITCODE) { -1 } else { [int]$global:LASTEXITCODE }

    $terminalPath = Resolve-ReviewerQualificationSlotTerminalPath -RunDirectory $plan.RunDirectory `
        -SlotName $target.Name
    return @{
        terminalWritten = [bool]($null -ne $terminalPath)
        terminalPath = [string]$(if ($terminalPath) { $terminalPath } else { $target.TerminalPath })
        childExitCode = $slotExitCode
        slotName = [string]$target.Name
        setId = $context.SetId
        planDigest = $context.PlanDigest
    }
}

function Invoke-ShadowChildSlotVerify {
    <#
    .SYNOPSIS
        Reads the slot's immutable terminal evidence through the reviewed
        readers and reports it verbatim.
    .DESCRIPTION
        Every judgement in the result below belongs to something else. The status
        word is the terminal artifact's, the signature is the declaration's, the
        inventory is the published set's, and the counts are censuses of files on
        disk. This step adds structure and nothing else.

        Loads the reviewed sources at this scope for the reason given on
        Invoke-ShadowChildSlotPlan.
    #>
    param([Parameter(Mandatory)]$Request, [Parameter(Mandatory)][string]$ToolkitRoot)
    Import-Module (Join-Path $ToolkitRoot 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force -ErrorAction Stop
    . (Join-Path $ToolkitRoot 'src\Agents\reviewer\QualificationPreflight.ps1')
    . (Join-Path $ToolkitRoot 'src\Agents\reviewer\ReplayQualification.ps1')
    . (Join-Path $ToolkitRoot 'src\Agents\reviewer\ModelStartCensus.ps1')
    $context = Get-ShadowChildSlotContext -Request $Request -ToolkitRoot $ToolkitRoot
    $plan = $context.Plan
    $target = $context.Target

    $terminalPath = Resolve-ReviewerQualificationSlotTerminalPath -RunDirectory $plan.RunDirectory `
        -SlotName $target.Name
    if (-not $terminalPath) {
        throw "Slot '$($target.Name)' has no terminal evidence under '$($plan.RunDirectory)'."
    }
    # Refuses a writable terminal on the caller's behalf, so immutability is
    # asserted by the reviewed reader rather than re-implemented here.
    $terminal = Read-ReviewerQualificationSlotTerminal -TerminalPath $terminalPath
    if ($null -eq $terminal) {
        throw "Slot '$($target.Name)' terminal evidence at '$terminalPath' could not be read."
    }
    foreach ($name in @('kind', 'slot', 'setId', 'planDigest', 'status', 'exitCode', 'timedOut')) {
        if (-not $terminal.PSObject.Properties[$name]) {
            throw "The terminal evidence at '$terminalPath' is missing '$name'."
        }
    }
    if ([string]$terminal.kind -cne 'reviewer.replay-qualification.terminal.v1') {
        throw "The terminal evidence at '$terminalPath' declares kind '$([string]$terminal.kind)'."
    }
    if ([string]$terminal.slot -cne [string]$target.Name) {
        throw "The terminal evidence at '$terminalPath' is slot '$([string]$terminal.slot)', not '$($target.Name)'."
    }

    $attempts = @(Get-ChildItem -LiteralPath $plan.RunDirectory -Filter 'slot*-attempt.json' `
            -File -ErrorAction SilentlyContinue)
    $bytes = [IO.File]::ReadAllBytes($terminalPath)

    # The census of what this slot's run actually started, by role, taken from the
    # run's own published per-attempt evidence. A run that ended 'complete'
    # published everything it was going to publish, so its census is exact; a run
    # that failed or was killed may have started an attempt whose record it never
    # got to write, so its census is a measured floor and says so. The caller
    # bounds that gap rather than assuming it is zero.
    $runRoot = Join-Path (Join-Path ([string]$target.StateDir) 'replay') ([string]$plan.Snapshot.Name)
    $censusExact = ([string]$terminal.status -ceq 'complete')
    $census = $null
    $censusFault = ''
    if (Test-Path -LiteralPath $runRoot -PathType Container) {
        try {
            $census = Get-ReviewerModelStartCensus -RunRoot $runRoot -Argv ([string[]]$target.Arguments)
        }
        catch {
            # A run that ended cleanly and left evidence this build cannot read is
            # a contradiction and is refused. A run that failed or was killed
            # mid-write is not: a truncated log or a half-sealed preview is the
            # ordinary shape of an interruption, and refusing it would stop the
            # whole cohort over an outcome the design already carries. That run is
            # charged its plan's full bound below instead.
            if ($censusExact) { throw }
            $censusFault = [string]$_.Exception.Message
        }
    }
    elseif ($censusExact) {
        throw ("Slot '$($target.Name)' reports a complete run and left no run directory at '$runRoot', so the model " +
            'starts it made cannot be counted. A completed run that published no evidence is refused, not read as zero.')
    }
    else {
        # Nothing was created under the run root at all, so nothing published and
        # nothing can be counted from it. Left as a null census, which is charged
        # its plan's full bound below.
        $censusFault = "The run root '$runRoot' does not exist."
    }

    # What this slot could have spent beyond what it managed to record. Zero for a
    # run that ended cleanly; otherwise the reviewed side's own arithmetic over
    # the sealed plan, which knows that an interrupted cross-verification phase
    # hides every launch it made rather than one.
    $unmeasuredAllowance = Get-ReviewerModelStartUnmeasuredAllowance -Argv ([string[]]$target.Arguments) `
        -ReviewerScriptPath ([string]$context.ReviewerScriptPath) -RunEndedComplete $censusExact -Census $census
    if ($null -eq $census) {
        $census = [pscustomobject][ordered]@{
            realModelStarts = 0
            byRole = [pscustomobject][ordered]@{ generalist = 0; specialist = 0; verifier = 0 }
            complete = $true
            incompleteReason = ''
            logRecordCount = 0
            basis = 'unreadableEvidence'
        }
    }

    # A run that ENDED CLEANLY and published cycle records without a single
    # generalist attempt record contradicts itself: every complete run makes at
    # least one first-pass attempt, so its evidence is missing rather than small
    # and the census must not be spent against a ceiling. The same shape on a run
    # that failed or timed out is a legitimate pre-launch refusal, and it is
    # already carried by the unmeasured allowance rather than by stopping the
    # cohort the entry belongs to.
    $censusComplete = [bool]$census.complete
    $censusDetail = [string]$census.incompleteReason
    if ($censusFault.Length -gt 0) { $censusDetail = $censusFault }
    if ($censusComplete -and $censusExact -and [int]$census.byRole.generalist -eq 0 -and
        [int]$census.logRecordCount -gt 0) {
        $censusComplete = $false
        $censusDetail = ('The run ended complete having published cycle records and no generalist attempt record, so ' +
            'the model starts it made cannot be counted from its own evidence.')
    }

    # The second census, of a second unit: the cross-verifier ASSIGNMENTS this
    # slot's run stood on. Taken from the run's own sealed previews and kept
    # entirely apart from the model-start census, because an assignment is not a
    # process - grouping means one launch can serve a whole cluster - and adding
    # or substituting one for the other is the defect this exists to remove.
    $assignmentCensus = $null
    $assignmentFault = ''
    if (Test-Path -LiteralPath $runRoot -PathType Container) {
        try {
            $assignmentCensus = Get-ReviewerVerifierAssignmentCensus -RunRoot $runRoot -Argv ([string[]]$target.Arguments)
        }
        catch {
            # Same asymmetry as the model-start census above: a run that ended
            # cleanly and left unreadable assignment evidence contradicts itself
            # and is refused; an interrupted one is charged its plan's bound.
            if ($censusExact) { throw }
            $assignmentFault = [string]$_.Exception.Message
        }
    }
    elseif ($censusExact) {
        throw ("Slot '$($target.Name)' reports a complete run and left no run directory at '$runRoot', so the verifier " +
            'assignments it stood on cannot be counted. A completed run that published no evidence is refused, not read as zero.')
    }
    else {
        $assignmentFault = "The run root '$runRoot' does not exist."
    }
    $assignmentAllowance = Get-ReviewerVerifierAssignmentUnmeasuredAllowance -Argv ([string[]]$target.Arguments) `
        -ReviewerScriptPath ([string]$context.ReviewerScriptPath) -RunEndedComplete $censusExact -Census $assignmentCensus
    $assignmentComplete = $true
    $assignmentDetail = ''
    $assignmentTotal = 0
    $assignmentByModel = @()
    $verifierProcessStarts = 0
    if ($null -eq $assignmentCensus) {
        $assignmentComplete = $false
        $assignmentDetail = [string]$assignmentFault
    }
    else {
        $assignmentComplete = [bool]$assignmentCensus.complete
        $assignmentDetail = [string]$assignmentCensus.incompleteReason
        $assignmentTotal = [int]$assignmentCensus.realVerifierAssignments
        $assignmentByModel = @($assignmentCensus.byVerifierModel)
        $verifierProcessStarts = [int]$assignmentCensus.verifierProcessStarts
    }

    return @{
        terminalStatus = [string]$terminal.status
        terminalExitCode = [int]$terminal.exitCode
        terminalTimedOut = [bool]$terminal.timedOut
        terminalImmutable = [bool](Get-Item -LiteralPath $terminalPath).IsReadOnly
        terminalSetId = [string]$terminal.setId
        terminalPlanDigest = [string]$terminal.planDigest
        terminalSlot = [string]$terminal.slot
        terminalPath = [string]$terminalPath
        terminalSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        # Reaching this line means the declaration verified under its key and the
        # published inventory was complete: both are asserted by the shared
        # context builder, which throws rather than returning a false.
        signatureVerified = $true
        inventoryVerified = $true
        slotAttemptCount = [int]$attempts.Count
        # A census of the reviewer PROCESSES this run set has launched - one
        # attempt record per launched slot, counted across the qualification root.
        # Diagnostic only, and named for what it counts: it was once called a
        # model invocation count, which is how a two-slot run that started four
        # models came to be budgeted as three.
        slotAttemptRecordCount = @(Get-ChildItem -LiteralPath (Get-ShadowChildField -Request $Request -Name 'qualificationRoot') `
                -Filter 'slot*-attempt.json' -File -Recurse -ErrorAction SilentlyContinue).Count
        realModelStartCount = [int]$census.realModelStarts
        realModelStartsGeneralist = [int]$census.byRole.generalist
        realModelStartsSpecialist = [int]$census.byRole.specialist
        realModelStartsVerifier = [int]$census.byRole.verifier
        realModelStartCensusComplete = [bool]$censusComplete
        realModelStartCensusExact = [bool]$censusExact
        # What this slot could have spent and could not record. The cohort ceiling
        # is checked against the sum of this and the measured count, which is what
        # makes the check an upper bound rather than a floor.
        realModelStartUnmeasuredAllowance = [int]$unmeasuredAllowance
        realModelStartCensusBasis = [string]$census.basis
        realModelStartCensusDetail = [string]$censusDetail
        # The assignment census. 'realVerifierAssignmentCount' is THE figure a
        # cohort's verifier ceiling is spent in - one per candidate per required
        # reciprocal model, distinct across every sealed preview. The process
        # count beside it is the grouped launch census and is a diagnostic: a
        # ceiling checked against it would be a ceiling that shrank the moment
        # grouping worked.
        realVerifierAssignmentCount = [int]$assignmentTotal
        realVerifierAssignmentsByModel = @($assignmentByModel)
        realVerifierAssignmentCensusComplete = [bool]$assignmentComplete
        realVerifierAssignmentUnmeasuredAllowance = [int]$assignmentAllowance
        realVerifierAssignmentCensusDetail = [string]$assignmentDetail
        verifierProcessStartCount = [int]$verifierProcessStarts
        deliveryMode = [string]$plan.DeliveryMode
        promotable = [bool]$plan.Promotable
    }
}

function Get-ShadowChildReplayDerivedKey {
    <#
    .SYNOPSIS
        The replay-domain key for one signing key file, so a sealed comparison
        can be opened rather than merely parsed.
    .DESCRIPTION
        The chain this walks - key file, replay artifact domain, then the preview
        domain the envelope is signed under - is pinned by the seal-parity vector
        'replay-runset-domain-chain', so a divergence between this derivation and
        the one the comparison sealed with is a failing parity vector rather than
        a signature error nobody can explain. Read-only: the reviewer's own
        reader mints a key when the file is absent, and a comparison verified
        against a freshly-invented key would have verified nothing.
    #>
    param([Parameter(Mandatory)][string]$Path)
    # A signing key is 32 bytes plus a short format prefix; reading an operator
    # typo that happens to be a gigabyte helps nobody. The size is taken through
    # [IO.FileInfo] rather than Get-Item so no command result is assigned and
    # then measured, which is the flattening shape PSEN009 exists to refuse.
    $info = [IO.FileInfo]::new($Path)
    if (-not $info.Exists) { throw "The signing key at '$Path' does not exist." }
    if ($info.Length -gt 8192) {
        throw "The signing key at '$Path' is $($info.Length) bytes; a key file is a single short line."
    }
    $line = ([IO.File]::ReadAllText($Path)).Trim()
    $format = $(if ($IsWindows) { 'dpapi' } else { 'raw' })
    $separator = $line.IndexOf(':')
    if ($separator -gt 0) {
        $format = $line.Substring(0, $separator)
        $line = $line.Substring($separator + 1)
    }
    $stored = [Convert]::FromBase64String($line)
    $master = switch ($format) {
        'raw' { $stored }
        'dpapi' {
            try {
                [Security.Cryptography.ProtectedData]::Unprotect(
                    $stored, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
            }
            catch { throw "The signing key at '$Path' could not be decrypted for this user." }
        }
        default { throw "The signing key at '$Path' declares an unknown storage format '$format'." }
    }
    if ($master.Length -lt 32) { throw "Artifact signing key '$Path' is too short." }
    $hmac = [Security.Cryptography.HMACSHA256]::new($master)
    try { return , $hmac.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes('devpilot.reviewer.replay.artifact.v1')) }
    finally { $hmac.Dispose() }
}

function Get-ShadowChildReconcileContext {
    <#
    .SYNOPSIS
        Rebuilds the reviewed plan for the whole declared set and puts it through
        the production readiness gate.
    .DESCRIPTION
        Every judgement is the reviewed code's. This function verifies the sealed
        declaration under its key, confirms the published inventory, reproduces
        the plan digest the set was sealed under, and requires every slot to have
        completed with no live child - all through
        Assert-ReviewerQualificationSetReconcilable, which is the same gate the
        qualification tool's own -Mode Reconcile calls. What is added here is the
        locating of each slot's sealed run artifact and signing key, so the
        comparison runs over the runs this set declared rather than over whatever
        happens to be on disk.
    #>
    param([Parameter(Mandatory)]$Request, [Parameter(Mandatory)][string]$ToolkitRoot)

    $qualificationRoot = Get-ShadowChildField -Request $Request -Name 'qualificationRoot'
    $requiredRunCount = Get-ShadowChildField -Request $Request -Name 'requiredRunCount' -Type int
    $outputDirectory = Get-ShadowChildField -Request $Request -Name 'reconciliationOutputDirectory'
    $reviewerScriptPath = Get-ShadowChildOptionalField -Request $Request -Name 'reviewerScriptPath'
    if (-not $reviewerScriptPath) {
        $reviewerScriptPath = Join-Path $ToolkitRoot 'src\Agents\reviewer\Start-ReviewerAgent.ps1'
    }
    $runSetDirectory = Join-Path $qualificationRoot 'runset'
    # Reconciliation holds no authorization of its own; it reads the token the
    # published set carries. The caller still presents the token it was given, so
    # a caller acting on a set other than the one it was authorized for is
    # refused here rather than discovered afterwards in the plan digest.
    $publishedToken = Assert-ReviewerQualificationPublishedInventory -RunSetDirectory $runSetDirectory
    $tokenPath = Get-ShadowChildField -Request $Request -Name 'launchAuthorizationTokenPath'
    if (-not (Test-Path -LiteralPath $tokenPath -PathType Leaf)) {
        throw "The launch-authorization token '$tokenPath' does not exist."
    }
    $presentedToken = ([IO.File]::ReadAllText($tokenPath)).Trim()
    if ($presentedToken -cne $publishedToken) {
        throw ('The launch-authorization token presented for this reconciliation is not the token the published ' +
            'run set carries, so the plan it was sealed under cannot be reproduced.')
    }
    $launchHash = Get-ReviewerQualificationLaunchTokenHash -Token $publishedToken

    $plan = New-ReviewerReplayQualificationPlan `
        -RepoPath (Get-ShadowChildField -Request $Request -Name 'reviewerRepositoryPath') `
        -ConfigFile (Get-ShadowChildField -Request $Request -Name 'reviewerConfigPath') `
        -OperatorAlias (Get-ShadowChildField -Request $Request -Name 'operatorAlias') `
        -PullRequestId (Get-ShadowChildField -Request $Request -Name 'pullRequestId' -Type int) `
        -ReplayRoot (Get-ShadowChildField -Request $Request -Name 'replayRoot') `
        -ReplaySnapshotName (Get-ShadowChildField -Request $Request -Name 'snapshotName') `
        -ReplayManifestDigest (Get-ShadowChildField -Request $Request -Name 'manifestDigest') `
        -QualificationRoot $qualificationRoot `
        -ReviewerScriptPath $reviewerScriptPath `
        -ToolkitRepositoryPath '' `
        -ExpectedCommit (Get-ShadowChildField -Request $Request -Name 'expectedCommit') `
        -RequiredRef (Get-ShadowChildField -Request $Request -Name 'requiredRef') `
        -SlotCount (Get-ShadowChildField -Request $Request -Name 'plannedRunCount' -Type int) `
        -LaunchAuthorizationHash $launchHash
    if ([int]$plan.SlotCount -ne $requiredRunCount) {
        throw "The reconciliation was asked for $requiredRunCount run(s) and the plan declares $([int]$plan.SlotCount)."
    }

    $compareTool = Join-Path $ToolkitRoot 'tools\Compare-ReviewerReplayRuns.ps1'
    $keyPath = Get-ShadowChildField -Request $Request -Name 'runSetKeyPath'
    # The shared readiness gate, which throws unless every slot completed and no
    # recorded child is alive. Reaching the next line is the whole of this
    # adapter's claim that the set is reconcilable.
    $reconciled = Assert-ReviewerQualificationSetReconcilable -Plan $plan `
        -CompareTool $compareTool -RunSetKeyPath $keyPath
    $setId = [string]$reconciled.Declaration.setId
    $planDigest = [string]$reconciled.Declaration.planDigest

    $expectedPlanDigest = Get-ShadowChildOptionalField -Request $Request -Name 'expectedPlanDigest'
    if ($expectedPlanDigest -and $expectedPlanDigest -cne $planDigest) {
        throw "The verified declaration seals plan '$planDigest' and the caller authorized '$expectedPlanDigest'."
    }
    $expectedSetId = Get-ShadowChildOptionalField -Request $Request -Name 'expectedSetId'
    if ($expectedSetId -and $expectedSetId -cne $setId) {
        throw "The published run set is '$setId' and the caller authorized '$expectedSetId'."
    }

    # The gate above already refused anything but exactly one sealed declaration
    # under this directory, so naming it here cannot pick between candidates.
    $declarationPaths = @(Get-ChildItem -LiteralPath $runSetDirectory -Filter 'runset-*.json' -File `
            -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*.sig' } | ForEach-Object { $_.FullName })
    if (@($declarationPaths).Count -ne 1) {
        throw "Expected exactly one sealed run-set declaration under '$runSetDirectory'; found $(@($declarationPaths).Count)."
    }

    # One sealed run artifact per slot, and exactly one. A slot directory holding
    # two would leave the comparison to choose, and a comparison that chose which
    # of a run's artifacts to believe would be making the very judgement this
    # whole path exists to keep out of the caller.
    #
    # A slot's artifacts are not loose in its state directory: the reviewer keeps
    # a replayed run under 'replay/<snapshot>' so two snapshots replayed into one
    # state directory cannot blur together. The snapshot named here is the one
    # THE PLAN seals, not one read off the disk, so a stray sibling directory
    # left by some other snapshot can never be the one compared. The defect this
    # closes is a reconciliation that looked directly under the state directory,
    # found nothing, and refused a set whose two runs had both completed.
    $artifactPaths = @()
    $keyPaths = @()
    foreach ($slot in @($plan.Slots)) {
        $runRoot = Join-Path (Join-Path ([string]$slot.StateDir) 'replay') ([string]$plan.Snapshot.Name)
        $previewDirectory = Join-Path $runRoot 'convention-specialist-previews'
        $found = @()
        if (Test-Path -LiteralPath $previewDirectory -PathType Container) {
            $found = @(Get-ChildItem -LiteralPath $previewDirectory -Filter '*.json' -File -ErrorAction SilentlyContinue |
                    Sort-Object -Property Name | ForEach-Object { $_.FullName })
        }
        if (@($found).Count -ne 1) {
            throw ("Slot '$($slot.Name)' offers $(@($found).Count) sealed run artifact(s) under '$previewDirectory'; " +
                'a reconciliation compares exactly one run per slot.')
        }
        $slotKeyPath = Join-Path $runRoot 'artifact-signing.key'
        if (-not (Test-Path -LiteralPath $slotKeyPath -PathType Leaf)) {
            throw "Slot '$($slot.Name)' has no artifact signing key at '$slotKeyPath', so its run artifact cannot be opened."
        }
        $artifactPaths += @($found)[0]
        $keyPaths += $slotKeyPath
    }

    return @{
        Plan = $plan
        PlanDigest = $planDigest
        SetId = $setId
        RunSetDirectory = $runSetDirectory
        RunSetPath = [string]@($declarationPaths)[0]
        RunSetKeyPath = $keyPath
        CompareTool = $compareTool
        OutputDirectory = $outputDirectory
        RequiredRunCount = $requiredRunCount
        ArtifactPaths = @($artifactPaths)
        KeyPaths = @($keyPaths)
        AttemptPath = (Join-Path $outputDirectory 'reconcile-attempt.json')
        ReconciledSlots = @($reconciled.Slots)
    }
}

function Invoke-ShadowChildReconcilePlan {
    <#
    .SYNOPSIS
        Reports the comparison a reconciliation would run, and whether its single
        authorization is still available. Compares nothing.
    #>
    param([Parameter(Mandatory)]$Request, [Parameter(Mandatory)][string]$ToolkitRoot)
    Import-Module (Join-Path $ToolkitRoot 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force -ErrorAction Stop
    . (Join-Path $ToolkitRoot 'src\Agents\reviewer\QualificationPreflight.ps1')
    . (Join-Path $ToolkitRoot 'src\Agents\reviewer\ReplayQualification.ps1')
    $context = Get-ShadowChildReconcileContext -Request $Request -ToolkitRoot $ToolkitRoot
    $plan = $context.Plan
    $perCallTimeoutSeconds = [Math]::Max(
        (Get-ShadowChildArgumentValue -Argv @($plan.Slots)[0].Arguments -Name '-CycleTimeoutSeconds'),
        [Math]::Max(
            (Get-ShadowChildArgumentValue -Argv @($plan.Slots)[0].Arguments -Name '-ConventionSpecialistTimeoutSeconds'),
            (Get-ShadowChildArgumentValue -Argv @($plan.Slots)[0].Arguments -Name '-VerificationTimeoutSeconds')))
    return @{
        setId = $context.SetId
        planDigest = $context.PlanDigest
        requiredRunCount = [int]$context.RequiredRunCount
        artifactCount = @($context.ArtifactPaths).Count
        outputDirectory = [string]$context.OutputDirectory
        reconciliationAttemptExists = [bool](Test-Path -LiteralPath $context.AttemptPath)
        # Reaching this line means the shared readiness gate accepted the set; it
        # throws rather than returning a false.
        reconciliationReady = $true
        slotTimeoutSeconds = [int]$plan.SlotTimeoutSeconds
        progressTimeoutSeconds = [int]$plan.ProgressTimeoutSeconds
        perCallTimeoutSeconds = $perCallTimeoutSeconds
        head = [string]$plan.GitIdentity.head
        requiredRef = [string]$plan.GitIdentity.requiredRef
        headClean = [bool]$plan.GitIdentity.clean
        deliveryMode = [string]$plan.DeliveryMode
        promotable = [bool]$plan.Promotable
    }
}

function Invoke-ShadowChildReconcileRun {
    <#
    .SYNOPSIS
        Runs the production comparison over the declared set exactly once, and
        writes the versioned summary its caller reads.
    .DESCRIPTION
        -FailOnDisagreement is deliberately NOT passed. Turning disagreement into
        a non-zero exit would hand the caller a reading of the runs, and the
        caller is a program that must never form one. The exit code travels as an
        opaque number instead, and the comparison's own sealed artifact is the
        record of what it found.
    #>
    param([Parameter(Mandatory)]$Request, [Parameter(Mandatory)][string]$ToolkitRoot)
    Import-Module (Join-Path $ToolkitRoot 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force -ErrorAction Stop
    . (Join-Path $ToolkitRoot 'src\Agents\reviewer\QualificationPreflight.ps1')
    . (Join-Path $ToolkitRoot 'src\Agents\reviewer\ReplayQualification.ps1')
    $context = Get-ShadowChildReconcileContext -Request $Request -ToolkitRoot $ToolkitRoot

    $reconcileInput = Read-ShadowChildReconcileInput -Request $Request -Context $context

    if (-not (Test-Path -LiteralPath $context.OutputDirectory -PathType Container)) {
        [void](New-Item -ItemType Directory -Force -Path $context.OutputDirectory)
    }
    # The attempt record is made with CreateNew before anything runs, so a
    # second comparison of the same set is refused by the file system rather
    # than by a check that a racing process could pass at the same instant.
    $attemptJson = ConvertTo-Json -InputObject ([ordered]@{
            kind = 'devpilot.shadow-run-coordinator.reconcile-attempt.v1'
            correlationId = [string]$Request.correlationId
            setId = $context.SetId
            planDigest = $context.PlanDigest
            recordedAtUtc = [DateTime]::UtcNow.ToString('o')
        }) -Depth 5
    try {
        $attemptStream = [IO.File]::Open($context.AttemptPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    }
    catch [IO.IOException] {
        throw ("This set has already been reconciled: '$($context.AttemptPath)' exists. A reconciliation is consumed " +
            'when it is attempted, whether or not it finished.')
    }
    try {
        $attemptBytes = [Text.UTF8Encoding]::new($false).GetBytes($attemptJson)
        $attemptStream.Write($attemptBytes, 0, $attemptBytes.Length)
    }
    finally { $attemptStream.Dispose() }
    Set-ItemProperty -LiteralPath $context.AttemptPath -Name IsReadOnly -Value $true

    $before = @(Get-ChildItem -LiteralPath $context.OutputDirectory -Filter 'reconciliation-*' -File `
            -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })

    $global:LASTEXITCODE = 0
    & $context.CompareTool -ArtifactPath @($context.ArtifactPaths) -KeyPath @($context.KeyPaths) `
        -RunSetPath $context.RunSetPath -RunSetKeyPath $context.RunSetKeyPath `
        -RequiredRunCount ([int]$context.RequiredRunCount) -OutputDirectory $context.OutputDirectory | Out-Null
    $comparisonExitCode = if ($null -eq $global:LASTEXITCODE) { -1 } else { [int]$global:LASTEXITCODE }

    $after = @(Get-ChildItem -LiteralPath $context.OutputDirectory -Filter 'reconciliation-*' -File `
            -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    $produced = @($after | Where-Object { $before -notcontains $_ })
    $reportPath = @($produced | Where-Object { $_ -like '*.md' })
    $artifactPath = @($produced | Where-Object { $_ -like '*.json' })
    if (@($reportPath).Count -ne 1 -or @($artifactPath).Count -ne 1) {
        throw ("The comparison produced $(@($reportPath).Count) report(s) and $(@($artifactPath).Count) sealed " +
            "artifact(s) under '$($context.OutputDirectory)'; exactly one of each is the contract.")
    }

    $summary = [ordered]@{
        contractVersion = $script:ShadowReconciliationSummaryVersion
        kind = 'shadow-run-coordinator-reconciliation-summary'
        correlationId = [string]$Request.correlationId
        reconciliationRequestSha256 = [string]$reconcileInput.RequestSha256
        setId = $context.SetId
        planDigest = $context.PlanDigest
        requiredRunCount = [int]$context.RequiredRunCount
        comparisonExitCode = $comparisonExitCode
        reportPath = [string]@($reportPath)[0]
        artifactPath = [string]@($artifactPath)[0]
        generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $summaryPath = [string]$reconcileInput.SummaryPath
    $summaryDirectory = Split-Path -Parent $summaryPath
    if ($summaryDirectory -and -not (Test-Path -LiteralPath $summaryDirectory -PathType Container)) {
        [void](New-Item -ItemType Directory -Force -Path $summaryDirectory)
    }
    $summaryText = ConvertTo-Json -InputObject $summary -Depth 6
    [IO.File]::WriteAllText($summaryPath, $summaryText, [Text.UTF8Encoding]::new($false))
    $summaryBytes = [IO.File]::ReadAllBytes($summaryPath)
    $reportBytes = [IO.File]::ReadAllBytes(@($reportPath)[0])
    $artifactBytes = [IO.File]::ReadAllBytes(@($artifactPath)[0])

    return @{
        summaryWritten = $true
        summaryPath = $summaryPath
        summarySha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($summaryBytes)).ToLowerInvariant()
        comparisonExitCode = $comparisonExitCode
        setId = $context.SetId
        planDigest = $context.PlanDigest
        # Digested where they were produced, so the caller can pin them now and
        # require the verification step to have read these exact bytes rather
        # than whatever stands at the same paths by then.
        reportPath = [string]@($reportPath)[0]
        reportSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($reportBytes)).ToLowerInvariant()
        artifactPath = [string]@($artifactPath)[0]
        artifactSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($artifactBytes)).ToLowerInvariant()
    }
}

function Invoke-ShadowChildReconcileVerify {
    <#
    .SYNOPSIS
        Opens the sealed comparison under its key and reports its status, its
        digests and a census of its own numbers.
    .DESCRIPTION
        No finding identity, no finding text, no severity and no verdict crosses
        this boundary. What the caller receives is the reconciliation's own
        outcome digest, the digests of the two files it produced, and a list of
        named counts it may carry without being able to reason about any of them.
    #>
    param([Parameter(Mandatory)]$Request, [Parameter(Mandatory)][string]$ToolkitRoot)
    Import-Module (Join-Path $ToolkitRoot 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force -ErrorAction Stop
    . (Join-Path $ToolkitRoot 'src\Agents\reviewer\QualificationPreflight.ps1')
    . (Join-Path $ToolkitRoot 'src\Agents\reviewer\ReplayQualification.ps1')
    # The comparison's own sources, loaded so its artifact is opened with the
    # primitives that sealed it. Re-deriving an HMAC here would be a second
    # implementation of the seal, and a second implementation is a second thing
    # that can disagree with the first.
    . (Join-Path $ToolkitRoot 'src\Agents\reviewer\SourceTransport.ps1')
    . (Join-Path $ToolkitRoot 'src\Agents\reviewer\ConventionSpecialist.ps1')
    . (Join-Path $ToolkitRoot 'src\Agents\reviewer\CrossVerification.ps1')
    . (Join-Path $ToolkitRoot 'src\Agents\reviewer\RunReconciliation.ps1')
    $context = Get-ShadowChildReconcileContext -Request $Request -ToolkitRoot $ToolkitRoot

    $summaryPath = Get-ShadowChildField -Request $Request -Name 'summaryPath'
    if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
        throw "The reconciliation summary '$summaryPath' does not exist."
    }
    $summaryBytes = [IO.File]::ReadAllBytes($summaryPath)
    $summary = [Text.UTF8Encoding]::new($false).GetString($summaryBytes) | ConvertFrom-Json
    foreach ($name in @('contractVersion', 'setId', 'planDigest', 'requiredRunCount', 'reportPath', 'artifactPath')) {
        if (-not $summary.PSObject.Properties[$name]) {
            throw "The reconciliation summary at '$summaryPath' is missing '$name'."
        }
    }
    if ([string]$summary.contractVersion -cne $script:ShadowReconciliationSummaryVersion) {
        throw "The reconciliation summary at '$summaryPath' declares contract '$([string]$summary.contractVersion)'."
    }
    if ([string]$summary.setId -cne $context.SetId) {
        throw "The reconciliation summary names run set '$([string]$summary.setId)', not '$($context.SetId)'."
    }
    if ([string]$summary.planDigest -cne $context.PlanDigest) {
        throw "The reconciliation summary names plan '$([string]$summary.planDigest)', not '$($context.PlanDigest)'."
    }

    $reportPath = [string]$summary.reportPath
    $artifactPath = [string]$summary.artifactPath
    foreach ($produced in @($reportPath, $artifactPath)) {
        if (-not (Test-Path -LiteralPath $produced -PathType Leaf)) {
            throw "The reconciliation summary names '$produced', which does not exist."
        }
    }

    # Each file is read ONCE, and everything said about it - the signature check,
    # the parse, the digest returned to the caller - is said about those exact
    # bytes. Two reads of one path are two different files if anything replaces
    # it in between, and the digest returned here is what binds this verification
    # to the artifact the run watched being produced.
    $artifactBytes = [IO.File]::ReadAllBytes($artifactPath)
    $reportBytes = [IO.File]::ReadAllBytes($reportPath)
    $artifactText = ([Text.UTF8Encoding]::new($false, $true)).GetString($artifactBytes)
    $reportText = ([Text.UTF8Encoding]::new($false, $true)).GetString($reportBytes)

    # Opened with the reviewed primitives under the first run's key, which is the
    # key the comparison sealed it with. A cleartext read would accept a file
    # anybody could have written into the output directory afterwards.
    $masterKey = Get-ShadowChildReplayDerivedKey -Path @($context.KeyPaths)[0]
    $envelope = $artifactText | ConvertFrom-Json
    $manifestJson = [string](Get-ReviewerConventionSpecialistValue $envelope 'manifestJson' '')
    $signature = [string](Get-ReviewerConventionSpecialistValue $envelope 'signature' '')
    $domainKey = Get-ReviewerConventionSpecialistDomainKey -MasterKey $masterKey -Domain preview
    if (-not $manifestJson -or -not (Test-ReviewerConventionSpecialistSignature -Json $manifestJson -Key $domainKey -Signature $signature)) {
        throw "The sealed comparison at '$artifactPath' does not verify under the run set's key."
    }
    $manifest = $manifestJson | ConvertFrom-Json -Depth 32
    if ([string]$manifest.kind -cne $script:ReviewerRunReconciliationKind) {
        throw "The sealed comparison at '$artifactPath' declares kind '$([string]$manifest.kind)'."
    }
    # The declaration lives INSIDE the seal, and this is where it earns its
    # place. Without these three checks the only thing tying the artifact to
    # this run set is the unsealed summary that named its path, so a different
    # comparison sealed under the same key - another set's, or an earlier one's -
    # would be read and reported as this set's outcome.
    $sealedQualification = $manifest.qualification
    if ($null -eq $sealedQualification) {
        throw "The sealed comparison at '$artifactPath' carries no qualification, so it cannot be shown to be this run set's."
    }
    if ([string]$sealedQualification.setId -cne $context.SetId) {
        throw "The sealed comparison at '$artifactPath' is for run set '$([string]$sealedQualification.setId)', not '$($context.SetId)'."
    }
    if ([int]$sealedQualification.plannedRunCount -ne [int]$context.RequiredRunCount) {
        throw ("The sealed comparison at '$artifactPath' declares $([int]$sealedQualification.plannedRunCount) planned run(s) " +
            "and this set plans $([int]$context.RequiredRunCount).")
    }
    # The Markdown is not signed, but its digest is - so the report is read back
    # and hashed with the same primitive the comparison sealed it with. A report
    # rewritten after the comparison is refused here rather than reported.
    if ([string]$manifest.reportPath -cne [string]$reportPath) {
        throw "The sealed comparison names its report '$([string]$manifest.reportPath)' and the summary names '$reportPath'."
    }
    $sealedReportSha = Get-ReviewerConventionSpecialistSha256 -Text $reportText
    if ([string]$manifest.reportSha256 -cne [string]$sealedReportSha) {
        throw "The comparison report at '$reportPath' digests to $sealedReportSha and its seal binds $([string]$manifest.reportSha256)."
    }
    $reconciliation = $manifest.reconciliation
    if ($null -eq $reconciliation) {
        throw "The sealed comparison at '$artifactPath' carries no reconciliation."
    }

    return @{
        summarySha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($summaryBytes)).ToLowerInvariant()
        # The comparison's own words, passed through. This adapter does not decide
        # whether a set reconciled; it reports what the reviewed code decided.
        reconciliationStatus = [string]$(if ([bool]$reconciliation.reconciled) { 'reconciled' } else { 'unreconciled' })
        reconciliationSha256 = [string]$reconciliation.reconciliationSha256
        reportPath = [string]$reportPath
        reportSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($reportBytes)).ToLowerInvariant()
        artifactPath = [string]$artifactPath
        artifactSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($artifactBytes)).ToLowerInvariant()
        artifactSignatureVerified = $true
        artifactPromotable = [bool]$manifest.promotable
        runCount = [int]$reconciliation.runCount
        requiredRunCount = [int]$reconciliation.requiredRunCount
        setId = $context.SetId
        planDigest = $context.PlanDigest
        # A census, in a fixed order, of numbers the comparison computed. The
        # names are labels for a human reading the audit; the caller carries them
        # without being able to act on any of them.
        counts = @(
            [ordered]@{ name = 'runs'; value = [int]$reconciliation.runCount }
            [ordered]@{ name = 'requiredRuns'; value = [int]$reconciliation.requiredRunCount }
            [ordered]@{ name = 'stableRows'; value = [int]$reconciliation.stableRowCount }
            [ordered]@{ name = 'unstableRows'; value = [int]$reconciliation.unstableRowCount }
            [ordered]@{ name = 'agreedCandidates'; value = [int]$reconciliation.agreedCandidateCount }
            [ordered]@{ name = 'candidates'; value = @($reconciliation.candidates).Count }
            [ordered]@{ name = 'problems'; value = @($reconciliation.problems).Count }
        )
    }
}

function Read-ShadowChildReconcileInput {
    <#
    .SYNOPSIS
        Reads the caller's strict versioned reconciliation input and binds it to
        this set.
    #>
    param([Parameter(Mandatory)]$Request, [Parameter(Mandatory)]$Context)
    $inputPath = Get-ShadowChildField -Request $Request -Name 'reconciliationRequestPath'
    $expectedSha = Get-ShadowChildField -Request $Request -Name 'reconciliationRequestSha256'
    if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
        throw "The reconciliation input '$inputPath' does not exist."
    }
    $text = [IO.File]::ReadAllText($inputPath, [Text.UTF8Encoding]::new($false))
    $document = $text | ConvertFrom-Json
    foreach ($name in @('contractVersion', 'correlationId', 'setId', 'planDigest', 'requiredRunCount', 'outputDirectory', 'summaryPath')) {
        if (-not $document.PSObject.Properties[$name]) {
            throw "The reconciliation input at '$inputPath' is missing '$name'."
        }
    }
    if ([string]$document.contractVersion -cne $script:ShadowReconciliationRequestVersion) {
        throw "The reconciliation input at '$inputPath' declares contract '$([string]$document.contractVersion)'."
    }
    if ([string]$document.correlationId -cne [string]$Request.correlationId) {
        throw "The reconciliation input at '$inputPath' belongs to correlation '$([string]$document.correlationId)'."
    }
    if ([string]$document.setId -cne $Context.SetId) {
        throw "The reconciliation input at '$inputPath' names run set '$([string]$document.setId)'."
    }
    if ([string]$document.planDigest -cne $Context.PlanDigest) {
        throw "The reconciliation input at '$inputPath' names plan '$([string]$document.planDigest)'."
    }
    if ([int]$document.requiredRunCount -ne [int]$Context.RequiredRunCount) {
        throw "The reconciliation input at '$inputPath' asks for $([int]$document.requiredRunCount) run(s)."
    }
    # Compared over the canonical bytes the caller committed a digest for, so a
    # file edited between the caller's commit and this read is refused here
    # rather than acted on.
    $actualSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
            [IO.File]::ReadAllBytes($inputPath))).ToLowerInvariant()
    if ($actualSha -cne $expectedSha) {
        throw ("The reconciliation input at '$inputPath' hashes to $actualSha and the caller committed " +
            "$expectedSha; the file changed after it was authorized.")
    }
    return @{
        SummaryPath = [string]$document.summaryPath
        RequestSha256 = $actualSha
    }
}

function Get-ShadowChildFileSha256 {
    <#
    .SYNOPSIS
        The lowercase hex SHA-256 of one file's bytes.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "'$Path' does not exist, so it cannot be digested."
    }
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($Path))).ToLowerInvariant()
}

function Import-ShadowChildDeliverySource {
    <#
    .SYNOPSIS
        Loads the reviewed libraries a delivery decision is evaluated by.
    .DESCRIPTION
        The gate library is loaded, not reimplemented. Every judgement a delivery
        decision contains - what a candidate is, whether it is eligible, what the
        policy currently permits, how the decision is sealed - is made by
        DeliveryGates.ps1, which is reviewed code with its own suite. This adapter
        supplies inputs and carries the answer.

        This must be DOT-SOURCED by its caller - '. Import-ShadowChildDeliverySource'
        - because a dot-source inside a function body defines its names in that
        function's scope and loses them on return. Dotting the call runs the body in
        the caller's scope, where the loaded names stay visible to the caller and to
        everything the caller goes on to call. Every other step in this adapter loads
        the same libraries directly in its own handler body for the same reason.
    #>
    param([Parameter(Mandatory)][string]$ToolkitRoot)
    Import-Module (Join-Path $ToolkitRoot 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force -ErrorAction Stop
    . (Join-Path $ToolkitRoot 'src\Agents\reviewer\QualificationPreflight.ps1')
    . (Join-Path $ToolkitRoot 'src\Agents\reviewer\ReplayQualification.ps1')
    . (Join-Path $ToolkitRoot 'src\Agents\reviewer\SourceTransport.ps1')
    . (Join-Path $ToolkitRoot 'src\Agents\reviewer\ConventionSpecialist.ps1')
    . (Join-Path $ToolkitRoot 'src\Agents\reviewer\CrossVerification.ps1')
    . (Join-Path $ToolkitRoot 'src\Agents\reviewer\RunReconciliation.ps1')
    . (Join-Path $ToolkitRoot 'src\Agents\reviewer\DeliveryGates.ps1')
}

function Get-ShadowChildDeliveryContext {
    <#
    .SYNOPSIS
        Rebuilds everything a preview-only delivery decision would be evaluated
        over, and answers - from the live policy, through the reviewed gate
        library - what such a decision could currently write.
    .DESCRIPTION
        The set must already be reconcilable on the shared readiness gate's terms,
        because a decision over a set whose runs are still moving is a decision
        over nothing. On top of that this locates the one sealed comparison the
        set produced, opens it under the run set's own key, and binds the decision
        to that comparison's digest.

        The capability answer is derived, never asserted: the shipped gate policy
        is put through ConvertTo-ReviewerGateEffectivePolicy and then through
        Get-ReviewerGateWritesCurrentlyRequested with every switch ON, which is
        the same authority the production delivery path consults. Asking with the
        switches on measures what the policy would currently PERMIT rather than
        what this adapter chose to abstain from. A policy that
        currently permitted a write would produce a true here, and the caller
        refuses a true before it starts anything.
    #>
    param([Parameter(Mandatory)]$Request, [Parameter(Mandatory)][string]$ToolkitRoot)

    $authorizationKind = Get-ShadowChildField -Request $Request -Name 'authorizationKind'
    if ($authorizationKind -cne $script:ShadowDeliveryPreviewOnlyKind) {
        throw ("This adapter evaluates a delivery decision under '$($script:ShadowDeliveryPreviewOnlyKind)' and nothing else; " +
            "the caller asked for '$authorizationKind'.")
    }
    $reconcile = Get-ShadowChildReconcileContext -Request $Request -ToolkitRoot $ToolkitRoot
    $outputDirectory = Get-ShadowChildField -Request $Request -Name 'deliveryOutputDirectory'
    if ((Get-ShadowChildPathKey -Path $outputDirectory) -ceq (Get-ShadowChildPathKey -Path ([string]$reconcile.OutputDirectory))) {
        throw ("The delivery would write into the comparison's own output directory '$outputDirectory', where the file it " +
            'reads and the file it produces could not be told apart.')
    }

    # Exactly one sealed comparison, for the reason the comparison itself demands
    # exactly one run artifact per slot: choosing between two would be a judgement
    # about which comparison to believe.
    $artifacts = @(Get-ChildItem -LiteralPath $reconcile.OutputDirectory -Filter 'reconciliation-*.json' -File `
            -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    if (@($artifacts).Count -ne 1) {
        throw ("Expected exactly one sealed comparison under '$($reconcile.OutputDirectory)'; found " +
            "$(@($artifacts).Count). A delivery decision closes over one comparison.")
    }
    $artifactPath = [string]@($artifacts)[0]
    $artifactBytes = [IO.File]::ReadAllBytes($artifactPath)
    $artifactText = ([Text.UTF8Encoding]::new($false, $true)).GetString($artifactBytes)

    # Opened under the run set's key with the reviewed primitives, so a comparison
    # anybody could have dropped into the output directory is refused rather than
    # decided over.
    $masterKey = Get-ShadowChildReplayDerivedKey -Path @($reconcile.KeyPaths)[0]
    $envelope = $artifactText | ConvertFrom-Json
    $manifestJson = [string](Get-ReviewerConventionSpecialistValue $envelope 'manifestJson' '')
    $signature = [string](Get-ReviewerConventionSpecialistValue $envelope 'signature' '')
    $domainKey = Get-ReviewerConventionSpecialistDomainKey -MasterKey $masterKey -Domain preview
    if (-not $manifestJson -or -not (Test-ReviewerConventionSpecialistSignature -Json $manifestJson -Key $domainKey -Signature $signature)) {
        throw "The sealed comparison at '$artifactPath' does not verify under the run set's key."
    }
    $manifest = $manifestJson | ConvertFrom-Json -Depth 32
    if ([string]$manifest.kind -cne $script:ReviewerRunReconciliationKind) {
        throw "The sealed comparison at '$artifactPath' declares kind '$([string]$manifest.kind)'."
    }
    if ([bool]$manifest.promotable) {
        throw "The sealed comparison at '$artifactPath' claims to be promotable; a preview-only delivery decides over nothing promotable."
    }
    $sealedQualification = $manifest.qualification
    if ($null -eq $sealedQualification -or [string]$sealedQualification.setId -cne $reconcile.SetId) {
        throw "The sealed comparison at '$artifactPath' is not this run set's, so no decision may be built over it."
    }
    $reconciliation = $manifest.reconciliation
    if ($null -eq $reconciliation) {
        throw "The sealed comparison at '$artifactPath' carries no reconciliation."
    }
    if ([int]$reconciliation.requiredRunCount -ne [int]$reconcile.RequiredRunCount) {
        throw ("The sealed comparison requires $([int]$reconciliation.requiredRunCount) run(s) and this delivery was " +
            "asked for $([int]$reconcile.RequiredRunCount).")
    }

    # The live policy, put through the reviewed reader, and then through the one
    # authority that says what a write switch would be permitted to do.
    #
    # Every switch is asked ON here, deliberately. This adapter never sets a
    # write switch and never will, so asking with them off would only measure
    # its own abstinence and would answer false whatever the policy said. Asking
    # with them on measures the POLICY: it answers whether a write capability is
    # in reach at all, which is the question the typed side refuses on.
    $configPath = Get-ShadowChildField -Request $Request -Name 'reviewerConfigPath'
    $gateLibraryPath = Join-Path $ToolkitRoot 'src\Agents\reviewer\DeliveryGates.ps1'
    $policyPath = Join-Path $ToolkitRoot 'src\Agents\reviewer\gates\v1\policy.json'
    $verificationLibraryPath = Join-Path $ToolkitRoot 'src\Agents\reviewer\RunReconciliation.ps1'
    $policy = [IO.File]::ReadAllText($policyPath, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    $effective = ConvertTo-ReviewerGateEffectivePolicy -Policy $policy
    $reachable = Get-ReviewerGateWritesCurrentlyRequested -EffectivePolicy $effective `
        -CommentSwitchOn $true -SuggestionSwitchOn $true -ApprovalSwitchOn $true

    return @{
        Reconcile = $reconcile
        SetId = [string]$reconcile.SetId
        PlanDigest = [string]$reconcile.PlanDigest
        RequiredRunCount = [int]$reconcile.RequiredRunCount
        OutputDirectory = $outputDirectory
        AttemptPath = (Join-Path $outputDirectory 'delivery-attempt.json')
        DecisionBaseName = 'delivery-decision'
        ArtifactPath = $artifactPath
        ArtifactSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($artifactBytes)).ToLowerInvariant()
        ReconciliationSha256 = [string]$reconciliation.reconciliationSha256
        Reconciliation = $reconciliation
        MasterKey = $masterKey
        EffectivePolicy = $effective
        ConfigSha256 = Get-ShadowChildFileSha256 -Path $configPath
        PolicySha256 = Get-ShadowChildFileSha256 -Path $policyPath
        GateLibrarySha256 = Get-ShadowChildFileSha256 -Path $gateLibraryPath
        VerificationLibrarySha256 = Get-ShadowChildFileSha256 -Path $verificationLibraryPath
        ScriptSha256 = Get-ShadowChildFileSha256 -Path $PSCommandPath
        PullRequestId = Get-ShadowChildField -Request $Request -Name 'pullRequestId' -Type int
        # Derived from the policy through the reviewed library, with every write
        # switch asked ON, so these say what the world would currently PERMIT
        # rather than what this adapter chose to ask for.
        CommentsEnabled = [bool]($reachable.Comments -or $reachable.Suggestions)
        VotesEnabled = [bool]$reachable.Approval
        GatesEnabled = [bool](([string]$effective.mode -cne 'off') -or [bool]$effective.approval.enabled)
    }
}

function Get-ShadowChildPathKey {
    <# Case-folded, separator-folded comparison key for one path. #>
    param([Parameter(Mandatory)][string]$Path)
    return ([IO.Path]::GetFullPath($Path)).TrimEnd('\', '/').ToLowerInvariant()
}

function Invoke-ShadowChildDeliveryPlan {
    <#
    .SYNOPSIS
        Reports the delivery decision that would be evaluated, what it would be
        bound to, and what it could currently write. Decides nothing and writes
        nothing.
    #>
    param([Parameter(Mandatory)]$Request, [Parameter(Mandatory)][string]$ToolkitRoot)
    . Import-ShadowChildDeliverySource -ToolkitRoot $ToolkitRoot
    $context = Get-ShadowChildDeliveryContext -Request $Request -ToolkitRoot $ToolkitRoot
    $plan = $context.Reconcile.Plan
    $perCallTimeoutSeconds = [Math]::Max(
        (Get-ShadowChildArgumentValue -Argv @($plan.Slots)[0].Arguments -Name '-CycleTimeoutSeconds'),
        [Math]::Max(
            (Get-ShadowChildArgumentValue -Argv @($plan.Slots)[0].Arguments -Name '-ConventionSpecialistTimeoutSeconds'),
            (Get-ShadowChildArgumentValue -Argv @($plan.Slots)[0].Arguments -Name '-VerificationTimeoutSeconds')))
    return @{
        setId = $context.SetId
        planDigest = $context.PlanDigest
        requiredRunCount = [int]$context.RequiredRunCount
        outputDirectory = [string]$context.OutputDirectory
        deliveryAttemptExists = [bool](Test-Path -LiteralPath $context.AttemptPath)
        # Reaching this line means the shared readiness gate accepted the set and
        # its one sealed comparison opened under the set's key; both throw rather
        # than returning a false.
        deliveryReady = $true
        authorizationKind = $script:ShadowDeliveryPreviewOnlyKind
        commentsEnabled = [bool]$context.CommentsEnabled
        votesEnabled = [bool]$context.VotesEnabled
        gatesEnabled = [bool]$context.GatesEnabled
        # The reviewed plan's own answer, not this adapter's.
        promotable = [bool]$plan.Promotable
        providerWriteCount = 0
        writeToolInvocations = 0
        reconciliationSha256 = [string]$context.ReconciliationSha256
        reconciliationArtifactPath = [string]$context.ArtifactPath
        reconciliationArtifactSha256 = [string]$context.ArtifactSha256
        configSha256 = [string]$context.ConfigSha256
        policySha256 = [string]$context.PolicySha256
        slotTimeoutSeconds = [int]$plan.SlotTimeoutSeconds
        progressTimeoutSeconds = [int]$plan.ProgressTimeoutSeconds
        perCallTimeoutSeconds = $perCallTimeoutSeconds
        head = [string]$plan.GitIdentity.head
        requiredRef = [string]$plan.GitIdentity.requiredRef
        headClean = [bool]$plan.GitIdentity.clean
    }
}

function Invoke-ShadowChildDeliveryRun {
    <#
    .SYNOPSIS
        Evaluates the reviewed delivery decision exactly once, in preview only,
        seals it, and writes the versioned summary its caller reads.
    .DESCRIPTION
        Nothing here posts, votes, sets a status or opens a connection. The gate
        library is a pure function over inputs: it returns a manifest, and this
        adapter seals that manifest to disk beside the comparison it closed over.
        The two write counters this step reports are the count of provider
        operations it performed, and they are constants because there is no
        expression anywhere in this file that could make either of them anything
        else.

        The capability answer is taken again here rather than trusted from the
        caller's file, so a policy edited between authorization and launch stops
        the evaluation instead of being evaluated under.
    #>
    param([Parameter(Mandatory)]$Request, [Parameter(Mandatory)][string]$ToolkitRoot)
    . Import-ShadowChildDeliverySource -ToolkitRoot $ToolkitRoot
    $context = Get-ShadowChildDeliveryContext -Request $Request -ToolkitRoot $ToolkitRoot
    if ($context.CommentsEnabled -or $context.VotesEnabled -or $context.GatesEnabled) {
        throw ('The current gate policy permits a write (comments=' + [string]$context.CommentsEnabled +
            ', votes=' + [string]$context.VotesEnabled + ', gates=' + [string]$context.GatesEnabled +
            '). A preview-only delivery decision is not evaluated while anything could write.')
    }
    $deliveryInput = Read-ShadowChildDeliveryInput -Request $Request -Context $context

    if (-not (Test-Path -LiteralPath $context.OutputDirectory -PathType Container)) {
        [void](New-Item -ItemType Directory -Force -Path $context.OutputDirectory)
    }
    # CreateNew before anything is evaluated, so a second decision over the same
    # set is refused by the file system rather than by a check a racing process
    # could pass at the same instant.
    $attemptJson = ConvertTo-Json -InputObject ([ordered]@{
            kind = 'devpilot.shadow-run-coordinator.delivery-attempt.v1'
            correlationId = [string]$Request.correlationId
            setId = $context.SetId
            planDigest = $context.PlanDigest
            authorizationKind = $script:ShadowDeliveryPreviewOnlyKind
            recordedAtUtc = [DateTime]::UtcNow.ToString('o')
        }) -Depth 5
    try {
        $attemptStream = [IO.File]::Open($context.AttemptPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    }
    catch [IO.IOException] {
        throw ("This set has already had a delivery decision evaluated: '$($context.AttemptPath)' exists. The " +
            'authorization is consumed when it is attempted, whether or not it finished.')
    }
    try {
        $attemptBytes = [Text.UTF8Encoding]::new($false).GetBytes($attemptJson)
        $attemptStream.Write($attemptBytes, 0, $attemptBytes.Length)
    }
    finally { $attemptStream.Dispose() }
    Set-ItemProperty -LiteralPath $context.AttemptPath -Name IsReadOnly -Value $true

    $evaluationExitCode = 0
    $reconciliation = $context.Reconciliation
    # The comparison's own candidates, carried into the gate library's facet
    # shape. No field is invented and none is interpreted: what the comparison
    # called a severity stays a severity, and an identity it refused to form
    # stays empty, which the library treats as ineligible on its own terms.
    $eligible = @(@($reconciliation.candidates) | ForEach-Object {
            [pscustomobject][ordered]@{
                candidateId = [string]$_.semanticCandidateId
                candidateHash = [string]$_.semanticIdentitySha256
                originKind = ''
                severity = [string]$_.severity
                filePath = [string]$_.filePath
                line = [int]$_.line
                comment = [string]$_.comment
                evidence = ''
                confidence = ''
            }
        })
    # Computed outside the array expression: an argument list carrying an
    # explicit null inside @() is exactly the phantom-element shape the boundary
    # analyzer refuses, and hoisting it costs nothing.
    $facetResult = Get-ReviewerGateCandidateFacets -Eligible $eligible -InputManifest $null -ConventionPlan $null
    $facets = @($facetResult)
    # The comparison's own conclusion about whether it produced a usable run,
    # passed through. This adapter does not form a second opinion.
    $runAccounting = [pscustomobject][ordered]@{
        Ok = [bool]$reconciliation.reconciled
        ReasonCodes = @(if ([bool]$reconciliation.reconciled) { @() } else { @('reconciliationUnreconciled') })
    }
    $head = ([string]$context.Reconcile.Plan.GitIdentity.head).ToLowerInvariant()
    $binding = @{
        prId = [int]$context.PullRequestId
        repositoryId = [string]$context.SetId
        organization = 'devpilot.shadow'
        project = 'shadow-run-coordinator'
        sourceCommit = $head
        targetCommit = $head
        changeSetDigest = [string]$context.PlanDigest
        # The comparison IS this decision's verification: its outcome digest and
        # the digest of the sealed file that carried it.
        verificationDecisionSha256 = [string]$context.ReconciliationSha256
        verificationInputSha256 = [string]$context.ArtifactSha256
        specialistArtifactSha256 = [string]$context.ArtifactSha256
        configSha256 = [string]$context.ConfigSha256
        scriptSha256 = [string]$context.ScriptSha256
        gateLibrarySha256 = [string]$context.GateLibrarySha256
        gatePolicySha256 = [string]$context.PolicySha256
        verificationLibrarySha256 = [string]$context.VerificationLibrarySha256
        # All-zero means this decision depended on none of these, which is the
        # honest answer: a shadow comparison has no convention plan, no fact
        # plan, no pack policy, no gate qualification, no prompt, no thread set
        # and no provider snapshot behind it.
        conventionPlanSha256 = $script:ShadowDeliveryAbsentDigest
        factPlanSha256 = $script:ShadowDeliveryAbsentDigest
        packPolicySha256 = $script:ShadowDeliveryAbsentDigest
        qualificationSha256 = $script:ShadowDeliveryAbsentDigest
        verificationPromptSha256 = $script:ShadowDeliveryAbsentDigest
        verificationPolicySha256 = $script:ShadowDeliveryAbsentDigest
        verificationSchemaSha256 = $script:ShadowDeliveryAbsentDigest
        threadSetDigest = $script:ShadowDeliveryAbsentDigest
        checksSnapshotSha256 = $script:ShadowDeliveryAbsentDigest
        policySnapshotSha256 = $script:ShadowDeliveryAbsentDigest
        passesRequested = [int]$context.RequiredRunCount
        generalistPassModels = ''
    }
    $decision = New-ReviewerGateDecision -Binding $binding -EffectivePolicy $context.EffectivePolicy `
        -Qualification $null -Facets $facets -ChangedPaths @() -ThreadFacts @() `
        -RunAccounting $runAccounting -SuggestionGateEnabled:$false -CreatedAtUtc ([DateTime]::UtcNow)
    $decisionPath = Save-ReviewerGateDecision -Manifest $decision -Directory $context.OutputDirectory `
        -BaseName $context.DecisionBaseName -MasterKey $context.MasterKey

    $summary = [ordered]@{
        contractVersion = $script:ShadowDeliverySummaryVersion
        kind = 'shadow-run-coordinator-delivery-summary'
        correlationId = [string]$Request.correlationId
        deliveryRequestSha256 = [string]$deliveryInput.RequestSha256
        setId = $context.SetId
        planDigest = $context.PlanDigest
        requiredRunCount = [int]$context.RequiredRunCount
        authorizationKind = $script:ShadowDeliveryPreviewOnlyKind
        reconciliationSha256 = [string]$context.ReconciliationSha256
        reconciliationArtifactSha256 = [string]$context.ArtifactSha256
        decisionPath = [string]$decisionPath
        evaluationExitCode = $evaluationExitCode
        providerWriteCount = 0
        writeToolInvocations = 0
        generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $summaryPath = [string]$deliveryInput.SummaryPath
    $summaryDirectory = Split-Path -Parent $summaryPath
    if ($summaryDirectory -and -not (Test-Path -LiteralPath $summaryDirectory -PathType Container)) {
        [void](New-Item -ItemType Directory -Force -Path $summaryDirectory)
    }
    [IO.File]::WriteAllText($summaryPath, (ConvertTo-Json -InputObject $summary -Depth 6 -Compress:$false), [Text.UTF8Encoding]::new($false))

    return @{
        summaryWritten = $true
        summaryPath = $summaryPath
        summarySha256 = Get-ShadowChildFileSha256 -Path $summaryPath
        evaluationExitCode = $evaluationExitCode
        setId = $context.SetId
        planDigest = $context.PlanDigest
        decisionPath = [string]$decisionPath
        decisionSha256 = Get-ShadowChildFileSha256 -Path $decisionPath
        # Constants because nothing in this file can produce any other value.
        providerWriteCount = 0
        writeToolInvocations = 0
    }
}

function Invoke-ShadowChildDeliveryVerify {
    <#
    .SYNOPSIS
        Opens the sealed decision under its key and reports its status, its
        digests, its census, and the fact that it wrote nowhere.
    .DESCRIPTION
        No candidate identity, no finding text, no severity, no verdict and no
        vote crosses this boundary. The status word is derived here, in
        PowerShell, from the reviewed decision's own numbers, because deciding
        what a decision means is exactly the judgement the caller must not hold.
    #>
    param([Parameter(Mandatory)]$Request, [Parameter(Mandatory)][string]$ToolkitRoot)
    . Import-ShadowChildDeliverySource -ToolkitRoot $ToolkitRoot
    $context = Get-ShadowChildDeliveryContext -Request $Request -ToolkitRoot $ToolkitRoot

    $summaryPath = Get-ShadowChildField -Request $Request -Name 'summaryPath'
    if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
        throw "The delivery summary '$summaryPath' does not exist."
    }
    $summaryBytes = [IO.File]::ReadAllBytes($summaryPath)
    $summary = ([Text.UTF8Encoding]::new($false, $true)).GetString($summaryBytes) | ConvertFrom-Json
    foreach ($name in @('contractVersion', 'setId', 'planDigest', 'requiredRunCount', 'authorizationKind',
            'decisionPath', 'reconciliationSha256', 'providerWriteCount', 'writeToolInvocations')) {
        if (-not $summary.PSObject.Properties[$name]) {
            throw "The delivery summary at '$summaryPath' is missing '$name'."
        }
    }
    if ([string]$summary.contractVersion -cne $script:ShadowDeliverySummaryVersion) {
        throw "The delivery summary at '$summaryPath' declares contract '$([string]$summary.contractVersion)'."
    }
    if ([string]$summary.setId -cne $context.SetId) {
        throw "The delivery summary names run set '$([string]$summary.setId)', not '$($context.SetId)'."
    }
    if ([string]$summary.planDigest -cne $context.PlanDigest) {
        throw "The delivery summary names plan '$([string]$summary.planDigest)', not '$($context.PlanDigest)'."
    }
    if ([string]$summary.authorizationKind -cne $script:ShadowDeliveryPreviewOnlyKind) {
        throw "The delivery summary declares authorization '$([string]$summary.authorizationKind)'."
    }
    if ([string]$summary.reconciliationSha256 -cne [string]$context.ReconciliationSha256) {
        throw ("The delivery summary closes over comparison $([string]$summary.reconciliationSha256) and this set's " +
            "comparison is $([string]$context.ReconciliationSha256).")
    }
    if ([int]$summary.providerWriteCount -ne 0 -or [int]$summary.writeToolInvocations -ne 0) {
        throw ("The delivery summary at '$summaryPath' records $([int]$summary.providerWriteCount) provider write(s) " +
            "and $([int]$summary.writeToolInvocations) write tool invocation(s).")
    }

    $decisionPath = [string]$summary.decisionPath
    if (-not (Test-Path -LiteralPath $decisionPath -PathType Leaf)) {
        throw "The delivery summary names a sealed decision at '$decisionPath', which does not exist."
    }
    $decisionBytes = [IO.File]::ReadAllBytes($decisionPath)
    # Opened with the reviewed reader, which verifies the envelope under the gate
    # decision domain key and refuses any other kind or artifact version. A
    # cleartext parse would accept a file anybody could have written here.
    $decision = Read-ReviewerGateDecision -Path $decisionPath -MasterKey $context.MasterKey
    if ([string]$decision.changeSetDigest -cne $context.PlanDigest) {
        throw "The sealed decision at '$decisionPath' is bound to change set '$([string]$decision.changeSetDigest)'."
    }
    if ([string]$decision.verificationDecisionSha256 -cne [string]$context.ReconciliationSha256) {
        throw ("The sealed decision at '$decisionPath' closes over comparison " +
            "$([string]$decision.verificationDecisionSha256), not $([string]$context.ReconciliationSha256).")
    }
    if ([string]$decision.gatePolicySha256 -cne [string]$context.PolicySha256) {
        throw "The sealed decision at '$decisionPath' was evaluated under a different gate policy than the one on disk."
    }

    $candidateCount = @($decision.candidates).Count
    $unattendedCommentCount = @($decision.unattendedComments).Count
    $unattendedSuggestionCount = @($decision.unattendedSuggestions).Count
    $unattendedCount = $unattendedCommentCount + $unattendedSuggestionCount
    # The judgement, made here and only here. The caller receives the word and
    # carries it; it has no branch on any of these four values.
    $status = $(if (-not [bool]$decision.runOk) { 'degraded' }
        elseif ($candidateCount -eq 0) { 'noFindings' }
        elseif ($unattendedCount -eq 0) { 'withheld' }
        else { 'eligiblePreview' })
    # A decision sealed in a mode that permits nothing can promote nothing. The
    # answer is derived from the sealed manifest rather than asserted.
    $promotable = [bool]([string]$decision.mode -cne 'off')

    return @{
        summarySha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($summaryBytes)).ToLowerInvariant()
        deliveryStatus = $status
        decisionPath = $decisionPath
        decisionSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($decisionBytes)).ToLowerInvariant()
        decisionSignatureVerified = $true
        decisionPromotable = $promotable
        authorizationKind = [string]$summary.authorizationKind
        commentsEnabled = [bool]$context.CommentsEnabled
        votesEnabled = [bool]$context.VotesEnabled
        gatesEnabled = [bool]$context.GatesEnabled
        providerWriteCount = 0
        writeToolInvocations = 0
        reconciliationSha256 = [string]$context.ReconciliationSha256
        runCount = [int]$context.Reconciliation.runCount
        requiredRunCount = [int]$context.Reconciliation.requiredRunCount
        setId = $context.SetId
        planDigest = $context.PlanDigest
        # A census, in a fixed order, of numbers the reviewed evaluation computed.
        # The names are labels for a human reading the audit; the caller carries
        # them without being able to act on any of them.
        counts = @(
            [ordered]@{ name = 'runs'; value = [int]$context.Reconciliation.runCount }
            [ordered]@{ name = 'requiredRuns'; value = [int]$context.Reconciliation.requiredRunCount }
            [ordered]@{ name = 'candidates'; value = $candidateCount }
            [ordered]@{ name = 'unattendedComments'; value = $unattendedCommentCount }
            [ordered]@{ name = 'unattendedSuggestions'; value = $unattendedSuggestionCount }
            [ordered]@{ name = 'humanPromotable'; value = [int]$decision.gateHumanPromotableCount }
            [ordered]@{ name = 'importantOrHigher'; value = [int]$decision.gateImportantOrHigherCount }
            [ordered]@{ name = 'runReasonCodes'; value = @($decision.runReasonCodes).Count }
        )
    }
}

function Read-ShadowChildDeliveryInput {
    <#
    .SYNOPSIS
        Reads the caller's strict versioned delivery input, binds it to this set
        and this comparison, and refuses any authorization but preview-only.
    #>
    param([Parameter(Mandatory)]$Request, [Parameter(Mandatory)]$Context)
    $inputPath = Get-ShadowChildField -Request $Request -Name 'deliveryRequestPath'
    $expectedSha = Get-ShadowChildOptionalField -Request $Request -Name 'deliveryRequestSha256'
    if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
        throw "The delivery input '$inputPath' does not exist."
    }
    $text = [IO.File]::ReadAllText($inputPath, [Text.UTF8Encoding]::new($false))
    $document = $text | ConvertFrom-Json
    foreach ($name in @('contractVersion', 'correlationId', 'setId', 'planDigest', 'requiredRunCount',
            'authorizationKind', 'commentsEnabled', 'votesEnabled', 'gatesEnabled', 'providerWriteBudget',
            'reconciliationSha256', 'reconciliationArtifactSha256', 'outputDirectory', 'summaryPath')) {
        if (-not $document.PSObject.Properties[$name]) {
            throw "The delivery input at '$inputPath' is missing '$name'."
        }
    }
    if ([string]$document.contractVersion -cne $script:ShadowDeliveryRequestVersion) {
        throw "The delivery input at '$inputPath' declares contract '$([string]$document.contractVersion)'."
    }
    if ([string]$document.correlationId -cne [string]$Request.correlationId) {
        throw "The delivery input at '$inputPath' belongs to correlation '$([string]$document.correlationId)'."
    }
    if ([string]$document.setId -cne $Context.SetId) {
        throw "The delivery input at '$inputPath' names run set '$([string]$document.setId)'."
    }
    if ([string]$document.planDigest -cne $Context.PlanDigest) {
        throw "The delivery input at '$inputPath' names plan '$([string]$document.planDigest)'."
    }
    if ([int]$document.requiredRunCount -ne [int]$Context.RequiredRunCount) {
        throw "The delivery input at '$inputPath' asks for $([int]$document.requiredRunCount) run(s)."
    }
    if ([string]$document.authorizationKind -cne $script:ShadowDeliveryPreviewOnlyKind) {
        throw "The delivery input at '$inputPath' authorizes '$([string]$document.authorizationKind)'."
    }
    if ([bool]$document.commentsEnabled -or [bool]$document.votesEnabled -or [bool]$document.gatesEnabled) {
        throw "The delivery input at '$inputPath' turns on a write capability, which this adapter never evaluates under."
    }
    if ([int]$document.providerWriteBudget -ne 0) {
        throw "The delivery input at '$inputPath' budgets $([int]$document.providerWriteBudget) provider write(s)."
    }
    # The comparison this decision is authorized to close over, byte for byte.
    if ([string]$document.reconciliationSha256 -cne [string]$Context.ReconciliationSha256) {
        throw ("The delivery input at '$inputPath' closes over comparison $([string]$document.reconciliationSha256) " +
            "and this set's comparison is $([string]$Context.ReconciliationSha256).")
    }
    if ([string]$document.reconciliationArtifactSha256 -cne [string]$Context.ArtifactSha256) {
        throw ("The delivery input at '$inputPath' binds artifact $([string]$document.reconciliationArtifactSha256) " +
            "and the sealed comparison on disk digests to $([string]$Context.ArtifactSha256).")
    }
    $actualSha = Get-ShadowChildFileSha256 -Path $inputPath
    if ($expectedSha -and $actualSha -cne $expectedSha) {
        throw ("The delivery input at '$inputPath' hashes to $actualSha and the caller committed " +
            "$expectedSha; the file changed after it was authorized.")
    }
    return @{
        SummaryPath = [string]$document.summaryPath
        RequestSha256 = $actualSha
    }
}

# ---------------------------------------------------------------------------
# One step, one tool, one result file.
# ---------------------------------------------------------------------------
$request = Read-ShadowChildRequest -Path $RequestPath
$correlationId = [string]$request.correlationId
$step = [string]$request.step
$resultPath = [string]$request.resultPath
$childRequestSha256 = [string]$request.childRequestSha256

try {
    $toolkitRoot = Get-ShadowChildField -Request $request -Name 'toolkitRoot'
    if (-not (Test-Path -LiteralPath $toolkitRoot -PathType Container)) {
        throw "The toolkit root '$toolkitRoot' does not exist."
    }
    # The step name carries the slot it acts on, and so does the request. They
    # have to agree: a request that named slot1 while the caller invoked the
    # slot2 step would run one slot under the other's exchange file, its nonce
    # and its adoption scope, and every later check would be self-consistent.
    if ($step -match '^slot([0-9]+)(Plan|Prelaunch|Run|Verify)\z') {
        $stepSlotName = "slot$($Matches[1])"
        $requestSlotName = Get-ShadowChildField -Request $request -Name 'slotName'
        if ($requestSlotName -cne $stepSlotName) {
            throw "Step '$step' acts on '$stepSlotName' and the request names slot '$requestSlotName'."
        }
    }
    $fields = switch -Regex ($step) {
        '^stagePreparation$' { Invoke-ShadowChildStagePreparation -Request $request -ToolkitRoot $toolkitRoot }
        '^corpusSealValidate$' { Invoke-ShadowChildCorpusSeal -Request $request -ToolkitRoot $toolkitRoot }
        '^corpusSeal$' { Invoke-ShadowChildCorpusSeal -Request $request -ToolkitRoot $toolkitRoot }
        '^runSetDeclare$' { Invoke-ShadowChildRunSetDeclare -Request $request -ToolkitRoot $toolkitRoot }
        '^runSetVerify$' { Invoke-ShadowChildRunSetVerify -Request $request -ToolkitRoot $toolkitRoot }
        '^runSetStatus$' { Invoke-ShadowChildRunSetStatus -Request $request -ToolkitRoot $toolkitRoot }
        # One step name per slot, so each slot's derivation, launch and
        # verification live in their own exchange files. A shared name would let
        # a result published for one slot be adopted as the other's answer, and
        # the two would then differ only by whatever the request happened to say.
        '^slot[0-9]+Plan$' { Invoke-ShadowChildSlotPlan -Request $request -ToolkitRoot $toolkitRoot }
        # The same derivation under a second name. The caller uses it as a probe
        # immediately before the irreversible launch, and a distinct step keeps
        # that probe out of the adoption path the committed plan result lives in.
        '^slot[0-9]+Prelaunch$' { Invoke-ShadowChildSlotPlan -Request $request -ToolkitRoot $toolkitRoot }
        '^slot[0-9]+Run$' { Invoke-ShadowChildSlotRun -Request $request -ToolkitRoot $toolkitRoot }
        '^slot[0-9]+Verify$' { Invoke-ShadowChildSlotVerify -Request $request -ToolkitRoot $toolkitRoot }
        '^reconcilePlan$' { Invoke-ShadowChildReconcilePlan -Request $request -ToolkitRoot $toolkitRoot }
        '^reconcilePrelaunch$' { Invoke-ShadowChildReconcilePlan -Request $request -ToolkitRoot $toolkitRoot }
        '^reconcileRun$' { Invoke-ShadowChildReconcileRun -Request $request -ToolkitRoot $toolkitRoot }
        '^reconcileVerify$' { Invoke-ShadowChildReconcileVerify -Request $request -ToolkitRoot $toolkitRoot }
        '^deliveryPlan$' { Invoke-ShadowChildDeliveryPlan -Request $request -ToolkitRoot $toolkitRoot }
        # The same derivation under a second name, used as the probe immediately
        # before the irreversible evaluation, for the reason the slots have one.
        '^deliveryPrelaunch$' { Invoke-ShadowChildDeliveryPlan -Request $request -ToolkitRoot $toolkitRoot }
        '^deliveryRun$' { Invoke-ShadowChildDeliveryRun -Request $request -ToolkitRoot $toolkitRoot }
        '^deliveryVerify$' { Invoke-ShadowChildDeliveryVerify -Request $request -ToolkitRoot $toolkitRoot }
        default { throw "'$step' is not a step this adapter performs." }
    }
    Write-ShadowChildResult -Path $resultPath -CorrelationId $correlationId -Step $step `
        -ChildRequestSha256 $childRequestSha256 -Ok $true -Fields $fields
    Write-Host "$correlationId $step ok" -ForegroundColor DarkGray
    exit 0
}
catch {
    $message = [string]$_.Exception.Message
    try {
        Write-ShadowChildResult -Path $resultPath -CorrelationId $correlationId -Step $step `
            -ChildRequestSha256 $childRequestSha256 -Ok $false -ErrorText $message
    }
    catch {
        # A result that cannot be written is reported by exit code alone; the
        # caller refuses a missing result file, so nothing is lost by silence.
        Write-Host "could not write the result file: $($_.Exception.Message)" -ForegroundColor DarkGray
    }
    Write-Host "$correlationId $step failed: $message" -ForegroundColor Red
    exit 1
}
