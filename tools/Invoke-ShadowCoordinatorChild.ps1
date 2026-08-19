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
    $replayRoot = Get-ShadowChildField -Request $Request -Name 'replayRoot'
    $validateOnly = Get-ShadowChildField -Request $Request -Name 'validateOnly' -Type bool

    # The sealer resolves its replay root as a real path, so the directory has to
    # exist before it is named. Creating it here is not the same as writing a
    # snapshot into it, which is what -ValidateOnly still refuses to do.
    if (-not (Test-Path -LiteralPath $replayRoot -PathType Container)) {
        [void](New-Item -ItemType Directory -Force -Path $replayRoot)
    }

    $tool = Join-Path $ToolkitRoot 'tools\Save-CorpusReplaySeal.ps1'
    if ($validateOnly) {
        & $tool -CorpusRoot $corpusRoot -CorpusIndexSha256 $indexSha -Recipe $recipePath `
            -ReplayRoot $replayRoot -ValidateOnly | Out-Null
        return @{ validateOnly = $true; replayRoot = [string]$replayRoot }
    }

    # A snapshot this request already published is adopted rather than resealed.
    # The snapshot id is deterministic from the recipe, and the sealer refuses an
    # existing id without -Force, so a coordinator killed after publication but
    # before it could commit would otherwise wedge this output root permanently:
    # every later resume would reseal, be refused, and fail identically. Passing
    # -Force instead would be worse, because it would let a genuinely different
    # request quietly overwrite sealed evidence.
    $adopted = Get-ShadowChildPublishedSnapshot -RecipePath $recipePath -ReplayRoot $replayRoot -ToolkitRoot $ToolkitRoot
    if ($null -ne $adopted) { return $adopted }

    $sealed = & $tool -CorpusRoot $corpusRoot -CorpusIndexSha256 $indexSha -Recipe $recipePath `
        -ReplayRoot $replayRoot
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
        [Parameter(Mandatory)][string]$ReplayRoot,
        [Parameter(Mandatory)][string]$ToolkitRoot
    )
    if (-not (Test-Path -LiteralPath $RecipePath -PathType Leaf)) { return $null }
    $recipe = [IO.File]::ReadAllText($RecipePath) | ConvertFrom-Json -Depth 32
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
    # A found declaration is not evidence on its own. Adoption re-reads it and
    # requires it to name THIS request's snapshot, snapshot manifest digest and
    # planned run count before it is accepted, so a run set left behind by some
    # other preparation cannot be adopted into this one just by being the only
    # file in the directory.
    $existing = @(Get-ChildItem -LiteralPath $runSetDirectory -Filter 'runset-*.json' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike '*.sig' })
    if ($existing.Count -eq 1) {
        $tokenPath = Join-Path $runSetDirectory 'launch-authorization.token'
        $adoptedText = [IO.File]::ReadAllText($existing[0].FullName, $script:ShadowChildUtf8)
        $adoptedRecord = $adoptedText | ConvertFrom-Json -Depth 24
        if (-not $adoptedRecord.PSObject.Properties['manifestJson']) {
            throw "The standing run set '$($existing[0].Name)' carries no manifest."
        }
        $adoptedManifest = [string]$adoptedRecord.manifestJson | ConvertFrom-Json -Depth 24
        $expected = [ordered]@{
            snapshotName = [string]$arguments.ReplaySnapshotName
            snapshotManifestDigest = [string]$arguments.ReplayManifestDigest
            plannedRunCount = [int]$arguments.SlotCount
        }
        foreach ($field in @($expected.Keys)) {
            if (-not $adoptedManifest.PSObject.Properties[$field]) {
                throw "The standing run set declares no '$field'."
            }
            $found = $adoptedManifest.$field
            $want = $expected[$field]
            $agrees = if ($want -is [int]) { ([int]$found -eq [int]$want) } else { ([string]$found -ceq [string]$want) }
            if (-not $agrees) {
                throw "The standing run set declares $field '$found' and this request prepared '$want'; it belongs to another preparation and is not adopted."
            }
        }
        return @{
            runSetPath = [string]$existing[0].FullName
            launchTokenPresent = [bool](Test-Path -LiteralPath $tokenPath -PathType Leaf)
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
        # Measured by enumeration rather than asserted. Every reviewer invocation
        # that could reach a model leaves a slot attempt record behind, so the
        # census of those records on disk is the census of model invocations this
        # preparation caused. A hard-coded zero would read identically on a run
        # that had invoked a model and on one that had not.
        modelInvocationCount = @(Get-ChildItem -LiteralPath $qualificationRoot -Filter 'slot*-attempt.json' `
                -File -Recurse -ErrorAction SilentlyContinue).Count
        statusReportPath = [string]([IO.Path]::GetFullPath($reportPath))
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
    $fields = switch ($step) {
        'stagePreparation' { Invoke-ShadowChildStagePreparation -Request $request -ToolkitRoot $toolkitRoot }
        'corpusSealValidate' { Invoke-ShadowChildCorpusSeal -Request $request -ToolkitRoot $toolkitRoot }
        'corpusSeal' { Invoke-ShadowChildCorpusSeal -Request $request -ToolkitRoot $toolkitRoot }
        'runSetDeclare' { Invoke-ShadowChildRunSetDeclare -Request $request -ToolkitRoot $toolkitRoot }
        'runSetVerify' { Invoke-ShadowChildRunSetVerify -Request $request -ToolkitRoot $toolkitRoot }
        'runSetStatus' { Invoke-ShadowChildRunSetStatus -Request $request -ToolkitRoot $toolkitRoot }
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
