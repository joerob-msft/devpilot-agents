#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Builds a private Owner v2 replay manifest from preserved v1 evidence bytes.

.DESCRIPTION
    Reads one preserved v1 evidence package and a normalized v1 observation,
    validates the exact subject, head, target, rule section, changed paths, and
    source bytes, runs the v2 capability parser with a deterministic
    attribute-only judgment handler, then records those independently produced
    v2 requests as replay records for the PR133 offline path.

    The output contains private source and response bytes. Write it only to an
    external, untracked qualification directory. ReferenceManifestPath must
    identify every consumed local byte under the exact V1StateRoot by relative
    path, SHA-256, length, and immutable `critical:<path>` binding.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BaselineObservationPath,
    [Parameter(Mandatory)][string]$V1StateRoot,
    [Parameter(Mandatory)][string]$PreservedEvidenceRoot,
    [AllowEmptyString()][string]$ReferenceManifestPath = '',
    [Parameter(Mandatory)][string]$OutputPath,
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$')]
    [string]$EntryId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
. "$repoRoot\src\DevPilot.OwnerParity\OwnerParityPaths.ps1"
$repoRoot = Resolve-OwnerParitySecurePath `
    -Path $repoRoot -Name RepositoryRoot -Kind Directory
Import-Module "$repoRoot\src\OwnerObserver\OwnerObserver.psd1" -Force
Import-Module "$repoRoot\src\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1" -Force
Import-Module "$repoRoot\src\DevPilot.OwnerCapability\DevPilot.OwnerCapability.psd1" -Force
Import-Module "$repoRoot\src\DevPilot.OwnerModelRunner\DevPilot.OwnerModelRunner.psd1" -Force
Import-Module "$repoRoot\src\DevPilot.OwnerPipeline\DevPilot.OwnerPipeline.psd1" -Force

function Get-ParityCandidateDigest {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return 'v1:sha256:' + [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData(
            [Text.UTF8Encoding]::new($false).GetBytes($Text))
    ).ToLowerInvariant()
}

function Resolve-ParityCandidatePath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('Leaf', 'Container')][string]$PathType,
        [switch]$AllowMissing
    )
    $kind = if ($PathType -eq 'Leaf') { 'File' } else { 'Directory' }
    return Resolve-OwnerParitySecurePath `
        -Path $Path -Name $Name -Kind $kind -AllowMissing:$AllowMissing
}

function Test-ParityCandidatePathWithin {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )
    return Test-OwnerParitySecurePathWithin -Path $Path -Root $Root
}

function Get-ParityCandidateReferencedBytes {
    param([Parameter(Mandatory)][string]$Path)
    $resolved = Resolve-ParityCandidatePath -Path $Path -Name referencedInput -PathType Leaf
    if (-not $script:ParityCandidateReferences.ContainsKey($resolved)) {
        throw "Parity input '$resolved' has no exact local-byte reference."
    }
    $reference = $script:ParityCandidateReferences[$resolved]
    return (Read-OwnerParityExactFile `
            -Root $script:ParityCandidateReferenceRoot -Reference $reference).bytes
}

function Get-ParityCandidateReferencedText {
    param([Parameter(Mandatory)][string]$Path)
    $bytes = Get-ParityCandidateReferencedBytes -Path $Path
    return [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
}

function Get-ParityCandidateReferencedJson {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-ParityCandidateReferencedText -Path $Path) |
        ConvertFrom-Json -AsHashtable -Depth 64
}

function Get-ParityCandidatePayloadText {
    param(
        [Parameter(Mandatory)][string]$ReplayRoot,
        [Parameter(Mandatory)][string]$RelativePath
    )
    $path = Resolve-ParityCandidatePath `
        -Path (Join-Path $ReplayRoot $RelativePath) `
        -Name payloadFile `
        -PathType Leaf
    if (-not (Test-ParityCandidatePathWithin -Path $path -Root $ReplayRoot)) {
        throw 'A preserved replay payload escaped its replay root.'
    }
    $raw = Get-ParityCandidateReferencedText -Path $path
    try {
        $outer = $raw | ConvertFrom-Json -AsHashtable -Depth 64
        if ($outer -is [Collections.IDictionary] -and $outer.Contains('result')) {
            $content = $outer.result.content[0]
            if ($content -is [Collections.IDictionary] -and $content.Contains('text')) {
                return [string]$content.text
            }
            if ($content -is [Collections.IDictionary] -and
                $content.Contains('resource') -and
                $content.resource -is [Collections.IDictionary] -and
                $content.resource.Contains('blob')) {
                $bytes = [Convert]::FromBase64String([string]$content.resource.blob)
                return [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
            }
        }
    }
    catch {
        # Raw file payloads are allowed; JSON provider envelopes are unwrapped.
    }
    return $raw
}

function Get-ParityCandidateMarkdownSection {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Heading
    )
    $wanted = $Heading.Trim()
    if ($wanted -notmatch '^(#{1,6})\s+\S') {
        throw 'The baseline rule section is not an exact ATX heading.'
    }
    $wantedLevel = $Matches[1].Length
    $lines = @($Text -split "`r?`n", 0, 'RegexMatch')
    if ($lines.Count -gt 1 -and [string]$lines[-1] -ceq '') {
        $lines = @($lines[0..($lines.Count - 2)])
    }
    $fence = ''
    $inFence = $false
    $startIndex = -1
    $endIndex = -1
    $matchCount = 0
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = [string]$lines[$index]
        $trimmed = $line.Trim()
        if ($trimmed -match '^(`{3,}|~{3,})') {
            $run = $Matches[1]
            if (-not $inFence) { $inFence = $true; $fence = $run }
            elseif ($run[0] -eq $fence[0] -and $run.Length -ge $fence.Length) {
                $inFence = $false
                $fence = ''
            }
            continue
        }
        if ($inFence -or $line -match '^\s{4,}') { continue }
        if ($trimmed -ceq $wanted) {
            $matchCount++
            if ($startIndex -lt 0) { $startIndex = $index }
            continue
        }
        if ($startIndex -ge 0 -and $endIndex -lt 0 -and
            $trimmed -match '^(#{1,6})\s+\S' -and
            $Matches[1].Length -le $wantedLevel) {
            $endIndex = $index - 1
        }
    }
    if ($matchCount -ne 1) {
        throw "The baseline rule heading resolved $matchCount times; exactly one is required."
    }
    if ($endIndex -lt 0) { $endIndex = $lines.Count - 1 }
    while ($endIndex -gt $startIndex -and
        [string]::IsNullOrWhiteSpace([string]$lines[$endIndex])) {
        $endIndex--
    }
    return $lines[$startIndex..$endIndex] -join "`n"
}

function Get-ParityCandidateInnerJson {
    param(
        [Parameter(Mandatory)][string]$ReplayRoot,
        [Parameter(Mandatory)][string]$RelativePath
    )
    return (Get-ParityCandidatePayloadText `
            -ReplayRoot $ReplayRoot -RelativePath $RelativePath) |
        ConvertFrom-Json -AsHashtable -Depth 64
}

function ConvertTo-ParityCandidatePath {
    param([Parameter(Mandatory)][string]$Path)
    return $Path.Replace('\', '/').TrimStart('/')
}

$baselinePath = Resolve-ParityCandidatePath `
    -Path $BaselineObservationPath -Name BaselineObservationPath -PathType Leaf
$v1Root = Resolve-ParityCandidatePath `
    -Path $V1StateRoot -Name V1StateRoot -PathType Container
$evidenceRoot = Resolve-ParityCandidatePath `
    -Path $PreservedEvidenceRoot -Name PreservedEvidenceRoot -PathType Container
$output = Resolve-ParityCandidatePath `
    -Path $OutputPath -Name OutputPath -PathType Leaf -AllowMissing
if (-not (Test-ParityCandidatePathWithin -Path $evidenceRoot -Root $v1Root)) {
    throw 'PreservedEvidenceRoot must be inside V1StateRoot.'
}
if ((Test-ParityCandidatePathWithin -Path $output -Root $v1Root) -or
    (Test-ParityCandidatePathWithin -Path $output -Root $repoRoot)) {
    throw 'OutputPath must be outside V1StateRoot and the repository.'
}
if ([string]::IsNullOrWhiteSpace($ReferenceManifestPath)) {
    throw 'ReferenceManifestPath is required for exact local-byte replay.'
}
$referenceManifestPathResolved = Resolve-ParityCandidatePath `
    -Path $ReferenceManifestPath -Name ReferenceManifestPath -PathType Leaf
$referenceManifestBytes = [IO.File]::ReadAllBytes($referenceManifestPathResolved)
if ($referenceManifestBytes.Length -gt 4MB) {
    throw 'Reference manifest exceeds the 4 MiB limit.'
}
try {
    $referenceManifest = ([Text.UTF8Encoding]::new($false, $true)).
        GetString($referenceManifestBytes) |
        ConvertFrom-Json -AsHashtable -Depth 32
}
catch {
    throw 'Reference manifest is not valid UTF-8 JSON.'
}
if ([int]$referenceManifest.schemaVersion -ne 1 -or
    [string]$referenceManifest.kind -cne 'owner-parity-local-byte-references') {
    throw 'Reference manifest has the wrong kind or schema version.'
}
$script:ParityCandidateReferenceRoot = Resolve-ParityCandidatePath `
    -Path ([string]$referenceManifest.root) -Name referenceManifest.root -PathType Container
if ($script:ParityCandidateReferenceRoot -cne $v1Root) {
    throw 'Reference manifest root must be the exact V1StateRoot.'
}
$referenceValues = @(Read-OwnerParityReferenceSet `
        -Root $v1Root -References @($referenceManifest.references))
$script:ParityCandidateReferences = [Collections.Generic.Dictionary[string, object]]::new(
    $(if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }))
for ($index = 0; $index -lt $referenceValues.Count; $index++) {
    $script:ParityCandidateReferences[$referenceValues[$index].path] =
        $referenceManifest.references[$index]
}

$baseline = ConvertFrom-OwnerNormalizedObservationBytes `
    -Bytes (Get-ParityCandidateReferencedBytes -Path $baselinePath)
$statusFiles = @($referenceValues | Where-Object {
        Test-ParityCandidatePathWithin -Path $_.path -Root $evidenceRoot -and
        [IO.Path]::GetFileName($_.path) -ceq 'owner-preview-status.json'
    })
if ($statusFiles.Count -ne 1) {
    throw "PreservedEvidenceRoot contains $($statusFiles.Count) Owner status files; exactly one is required."
}
$runRoot = Split-Path -Parent $statusFiles[0].path
$status = Get-ParityCandidateReferencedJson -Path $statusFiles[0].path
foreach ($binding in @(
        @($status.subject.pullRequestId, $baseline.subject.pullRequestId, 'pull request'),
        @($status.subject.repositoryId, $baseline.subject.repositoryId, 'repository'),
        @($status.subject.sourceCommit, $baseline.subject.headCommit, 'head'),
        @($status.subject.targetCommit, $baseline.subject.targetCommit, 'target'),
        @($status.rule.path, $baseline.rule.path, 'rule path'),
        @($status.rule.section, $baseline.rule.section, 'rule section'),
        @($status.rule.commit, $baseline.rule.commit, 'rule commit'),
        @($status.rule.sha256, $baseline.rule.sha256, 'rule hash'))) {
    if ([string]$binding[0] -cne [string]$binding[1]) {
        throw "Preserved status and normalized baseline disagree on $($binding[2])."
    }
}

$replayManifests = @($referenceValues | Where-Object {
        Test-ParityCandidatePathWithin -Path $_.path -Root (Join-Path $runRoot 'materialized\replay') -and
        [IO.Path]::GetFileName($_.path) -ceq 'manifest.json'
    })
if ($replayManifests.Count -ne 1) {
    throw "Preserved run contains $($replayManifests.Count) replay manifests; exactly one is required."
}
$replayRoot = Split-Path -Parent $replayManifests[0].path
$replayManifest = Get-ParityCandidateReferencedJson -Path $replayManifests[0].path
if ([string]$replayManifest.binding.sourceCommit -cne [string]$baseline.subject.headCommit -or
    [string]$replayManifest.binding.targetCommit -cne [string]$baseline.subject.targetCommit -or
    [long]$replayManifest.binding.pullRequestId -ne [long]$baseline.subject.pullRequestId) {
    throw 'Preserved replay manifest does not match the normalized baseline subject.'
}

$subjectKey = Split-Path -Leaf $runRoot
$hunkPath = Join-Path $evidenceRoot (
    "subjects\$subjectKey\entry\corpus\census\right-hand-hunks.json")
$hunkCensus = Get-ParityCandidateReferencedJson -Path $hunkPath
$hunksByPath = [Collections.Generic.Dictionary[string, object]]::new(
    [StringComparer]::OrdinalIgnoreCase)
foreach ($entry in @($hunkCensus)) {
    $hunksByPath.Add((ConvertTo-ParityCandidatePath -Path ([string]$entry.path)), $entry.hunks)
}

$prResource = @($replayManifest.resources | Where-Object {
        $_.tool -ceq 'repo_pull_request' -and $_.arguments.action -ceq 'get'
    })
$changesResource = @($replayManifest.resources | Where-Object {
        $_.tool -ceq 'repo_pull_request' -and
        $_.arguments.action -ceq 'get_changes' -and
        [string]$_.payloadFile -like '*changes-diffs.json'
    })
$ruleResource = @($replayManifest.resources | Where-Object {
        $_.tool -ceq 'repo_file' -and [string]$_.payloadFile -match 'payloads[/\\]rule-\d+\.txt$'
    })
$fileResources = @($replayManifest.resources | Where-Object {
        $_.tool -ceq 'repo_file' -and [string]$_.payloadFile -match 'payloads[/\\]file-\d+\.txt$'
    })
if ($prResource.Count -ne 1 -or $changesResource.Count -ne 1 -or
    $ruleResource.Count -ne 1 -or $fileResources.Count -lt 1) {
    throw 'Preserved replay resources do not contain one subject, change set, rule, and source file set.'
}
$pr = Get-ParityCandidateInnerJson -ReplayRoot $replayRoot -RelativePath $prResource[0].payloadFile
$changesPayload = Get-ParityCandidateInnerJson `
    -ReplayRoot $replayRoot -RelativePath $changesResource[0].payloadFile

$changeByPath = [Collections.Generic.Dictionary[string, object]]::new(
    [StringComparer]::OrdinalIgnoreCase)
foreach ($change in @($changesPayload.changes)) {
    $path = ConvertTo-ParityCandidatePath -Path ([string]$change.item.path)
    if ($changeByPath.ContainsKey($path)) {
        throw "Preserved changes contain duplicate path '$path'."
    }
    $changeByPath.Add($path, $change)
}

$identity = [ordered]@{
    schemaVersion = 1
    repositoryId = [string]$baseline.subject.repositoryId
    projectId = if ($pr.repository -is [Collections.IDictionary] -and
        $pr.repository.Contains('project') -and
        $pr.repository.project -is [Collections.IDictionary] -and
        $pr.repository.project.Contains('id')) {
        [string]$pr.repository.project.id
    }
    else {
        [string]$replayManifest.binding.project
    }
    pullRequestId = [long]$baseline.subject.pullRequestId
    sourceCommit = [string]$baseline.subject.headCommit
    targetCommit = [string]$baseline.subject.targetCommit
    targetRef = [string]$pr.targetRefName
}
$normalizedChanges = [Collections.Generic.List[object]]::new()
$files = [Collections.Generic.List[object]]::new()
$filePaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($resource in $fileResources | Sort-Object payloadFile) {
    $path = ConvertTo-ParityCandidatePath -Path ([string]$resource.arguments.path)
    if (-not $filePaths.Add($path)) {
        throw "Preserved source resources contain duplicate path '$path'."
    }
    if (-not $changeByPath.ContainsKey($path) -or -not $hunksByPath.ContainsKey($path)) {
        throw "Preserved source '$path' lacks matching change and hunk evidence."
    }
    $content = Get-ParityCandidatePayloadText `
        -ReplayRoot $replayRoot -RelativePath ([string]$resource.payloadFile)
    $contentDigest = Get-ParityCandidateDigest -Text $content
    $spans = @(
        foreach ($span in @($hunksByPath[$path])) {
            [ordered]@{
                startLine = [int]$span.newStart
                endLine = [int]$span.newStart + [int]$span.newCount - 1
                state = 'complete'
                sourceDigest = Get-ParityCandidateDigest `
                    -Text "$path|$($span.newStart)|$($span.newCount)|$contentDigest"
            }
        }
    )
    $changeType = switch -CaseSensitive ([string]$changeByPath[$path].changeType) {
        'Add' { 'added' }
        'Edit' { 'modified' }
        'Rename' { 'renamed' }
        'Delete' { throw "Deleted change '$path' lacks replayable current-source evidence." }
        default { throw "Unsupported preserved change type '$($_)'." }
    }
    $changeRecord = [ordered]@{
        path = $path
        changeType = $changeType
        isBinary = $false
        sourceDigest = Get-ParityCandidateDigest `
            -Text "$path|$changeType|$contentDigest"
        spans = $spans
    }
    [void]$normalizedChanges.Add($changeRecord)
    $file = [ordered]@{} + $identity
    $file['path'] = $path
    $file['state'] = 'complete'
    $file['byteLength'] = [Text.UTF8Encoding]::new($false).GetByteCount($content)
    $file['truncated'] = $false
    $file['content'] = $content
    $file['sourceDigest'] = $contentDigest
    [void]$files.Add($file)
}
if ($filePaths.Count -ne $changeByPath.Count -or
    $filePaths.Count -ne $hunksByPath.Count) {
    throw 'Preserved replay evidence does not cover every changed path and hunk census entry exactly once.'
}
foreach ($path in $changeByPath.Keys) {
    if (-not $filePaths.Contains($path) -or -not $hunksByPath.ContainsKey($path)) {
        throw "Preserved changed path '$path' lacks exact source or hunk evidence."
    }
}

$wholeRule = Get-ParityCandidatePayloadText `
    -ReplayRoot $replayRoot -RelativePath ([string]$ruleResource[0].payloadFile)
$ruleText = Get-ParityCandidateMarkdownSection `
    -Text $wholeRule -Heading ([string]$baseline.rule.section)
$ruleBytes = [Text.UTF8Encoding]::new($false).GetByteCount($ruleText)
$ruleDigest = Get-ParityCandidateDigest -Text $ruleText
if ($ruleBytes -ne [int]$status.rule.byteLength -or
    $ruleDigest.Substring(10) -cne [string]$baseline.rule.sha256) {
    throw 'Extracted preserved rule section does not match the signed v1 hash and length.'
}

$capabilityDigest = Get-ParityCandidateDigest -Text 'owner-mstest-owner-capability-v2'
$contract = New-OwnerAcquisitionContract `
    -RepositoryId $identity.repositoryId `
    -ProjectId $identity.projectId `
    -PullRequestId $identity.pullRequestId `
    -SourceCommit $identity.sourceCommit `
    -TargetCommit $identity.targetCommit `
    -TargetRef $identity.targetRef `
    -RuleRepositoryId ([string]$ruleResource[0].arguments.repositoryId) `
    -RulePath (ConvertTo-ParityCandidatePath -Path ([string]$baseline.rule.path)) `
    -RuleCommit ([string]$baseline.rule.commit) `
    -RuleSection ([string]$baseline.rule.section) `
    -RuleHash $ruleDigest `
    -RuleLength $ruleBytes `
    -ConfigId 'owner-parity-private' `
    -ConfigDigest (Get-ParityCandidateDigest -Text "owner-parity-private|$EntryId") `
    -CapabilityId ([string]$baseline.capability) `
    -CapabilityDigest $capabilityDigest

$subjectDigest = Get-ParityCandidateDigest -Text (
    "$($identity.repositoryId)|$($identity.projectId)|$($identity.pullRequestId)|" +
    "$($identity.sourceCommit)|$($identity.targetCommit)|$($identity.targetRef)|$($files.Count)")
$subject = [ordered]@{} + $identity
$subject['changedFileCount'] = $files.Count
$subject['state'] = 'complete'
$subject['sourceDigest'] = $subjectDigest
$page = [ordered]@{} + $identity
$page['pageOrdinal'] = 0
$page['continuationToken'] = $null
$page['nextToken'] = $null
$page['state'] = 'complete'
$page['sourceDigest'] = Get-ParityCandidateDigest -Text (
    ($normalizedChanges | ConvertTo-Json -Depth 16 -Compress))
$page['changes'] = @($normalizedChanges)
$rule = [ordered]@{} + $identity
$rule['ruleRepositoryId'] = $contract.Request.RuleRepositoryId
$rule['rulePath'] = $contract.Request.RulePath
$rule['ruleCommit'] = $contract.Request.RuleCommit
$rule['ruleSection'] = $contract.Request.RuleSection
$rule['ruleHash'] = $contract.Request.RuleHash
$rule['ruleLength'] = $contract.Request.RuleLength
$rule['state'] = 'complete'
$rule['content'] = $ruleText
$rule['sourceDigest'] = $ruleDigest
$package = [ordered]@{
    schemaVersion = 1
    semantics = 'owner-acquisition-v1'
    contractDigest = 'v1:sha256:7a6f3a79b5b87e38c8ca92a19886fff1f814336e331da8136c860f4f101d85b5'
    subjectBefore = $subject
    changePages = @($page)
    rule = $rule
    files = @($files)
    subjectAfter = ([ordered]@{} + $subject)
}
$fixture = New-OwnerReplayFixture -Package $package
$requests = [Collections.Generic.List[object]]::new()
$judgments = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
$captureRunner = New-OwnerSemanticRunner -Name 'owner-parity-deterministic-capture' -Handler {
    param($request)
    $copy = ConvertFrom-Json -InputObject (
        ConvertTo-Json -InputObject $request -Depth 16 -Compress
    ) -AsHashtable -Depth 16
    [void]$requests.Add($copy)
    $judgment = if (@($request.construct.attributes) -contains 'Owner') {
        'compliant'
    }
    else {
        'violation'
    }
    $judgments[[string]$request.executionUnitId] = $judgment
    return [ordered]@{
        schemaVersion = 2
        executionUnitId = [string]$request.executionUnitId
        judgment = $judgment
    }
}.GetNewClosure()
$captureCapability = New-OwnerV2CapabilityAdapter `
    -Runner $captureRunner `
    -CapabilityId ([string]$baseline.capability) `
    -CapabilityDigest $capabilityDigest
$captureResult = Invoke-OwnerReviewPipeline `
    -Binding $contract.Binding `
    -AcquisitionAdapter (New-OwnerReplayAcquisitionAdapter `
        -Contract $contract -Fixture $fixture -ExpectedPayloadDigest $fixture.PayloadDigest) `
    -CapabilityAdapter $captureCapability
if ($captureResult.delivery.attempted -ne $false -or
    [int]$captureResult.delivery.writeCount -ne 0 -or
    $captureResult.preview.writeAllowed -ne $false) {
    throw 'Deterministic capture unexpectedly exposed delivery authority.'
}

$records = @(
    foreach ($request in $requests) {
        $nonce = (Get-ParityCandidateDigest -Text ([string]$request.executionUnitId)).
            Substring(10, 36)
        $record = New-OwnerModelReplayRecord `
            -Request $request `
            -Judgment $judgments[[string]$request.executionUnitId] `
            -Nonce $nonce
        [ordered]@{
            executionUnitId = [string]$record.executionUnitId
            nonce = [string]$record.nonce
            inputDigest = [string]$record.inputDigest
            subjectBinding = [string]$record.subjectBinding
            responseBytesBase64 = [Convert]::ToBase64String($record.responseBytes)
        }
    }
)
$manifest = [ordered]@{
    schemaVersion = 1
    kind = 'owner-v2-preview-cohort'
    entries = @(
        [ordered]@{
            id = $EntryId
            mode = 'replay'
            subject = [ordered]@{
                repositoryId = $identity.repositoryId
                projectId = $identity.projectId
                pullRequestId = $identity.pullRequestId
            }
            head = [ordered]@{ sourceCommit = $identity.sourceCommit }
            target = [ordered]@{
                targetCommit = $identity.targetCommit
                targetRef = $identity.targetRef
            }
            rule = [ordered]@{
                repositoryId = $contract.Request.RuleRepositoryId
                path = $contract.Request.RulePath
                commit = $contract.Request.RuleCommit
                section = $contract.Request.RuleSection
                hash = $contract.Request.RuleHash
                length = $contract.Request.RuleLength
            }
            capability = [ordered]@{
                id = [string]$baseline.capability
                digest = $capabilityDigest
            }
            model = [ordered]@{
                id = 'owner-offline-deterministic-replay'
                digest = Get-ParityCandidateDigest -Text 'owner-offline-deterministic-replay-v1'
            }
            config = [ordered]@{
                id = 'owner-parity-private'
                digest = $contract.Request.ConfigDigest
            }
            acquisition = [ordered]@{
                payloadDigest = $fixture.PayloadDigest
                package = $package
            }
            replay = [ordered]@{
                modelRecords = $records
            }
        }
    )
}

[void](Write-OwnerParitySecureText `
        -Path $output `
        -Content ((ConvertTo-Json -InputObject $manifest -Depth 64) + "`n"))

[pscustomobject][ordered]@{
    schemaVersion = 1
    kind = 'owner-parity-replay-candidate-result'
    outputPath = $output
    entryId = $EntryId
    sourceFiles = $files.Count
    changedSpans = @($normalizedChanges.spans).Count
    executionUnits = $requests.Count
    deterministicViolations = @($judgments.Values | Where-Object { $_ -ceq 'violation' }).Count
    acquisitionPayloadDigest = $fixture.PayloadDigest
    providerWrites = 0
    writeToolInvocations = 0
}
