#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot `
    '..\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1')
Import-Module (Join-Path $PSScriptRoot `
    '..\DevPilot.ActivePrIntake\DevPilot.ActivePrIntake.psd1')
Import-Module (Join-Path $PSScriptRoot `
    '..\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1')
Import-Module (Join-Path $PSScriptRoot `
    '..\DevPilot.OwnerOrchestrator\DevPilot.OwnerOrchestrator.psd1')

$script:NamedCapability = 'bpm-named-areequal-arguments@1'
$script:NamedCapabilityDigest =
    'v1:sha256:7ed3583591b43dbb351292ea9a37a53fc32fc9f0fd3403c821e3209310598e3a'
$script:NamedPolicyPath =
    'src/DevPilot.OwnerCapability/Policy/named-areequal-arguments.v1.txt'
$script:NamedPolicyDigest =
    'v1:sha256:8b9fa35bd2bc96e9f0dbfc878806b540603ab4f255ddf41bf120311913b831f4'
$script:NamedConfigId = 'named-areequal-arguments-v1-user-approved'

function Get-NamedBridgeDigest {
    param([Parameter(Mandatory)][AllowNull()][object]$Value)
    return 'v1:sha256:' +
        (Get-AgentCanonicalDigest -InputObject $Value)
}

function Get-NamedBridgeTextDigest {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return 'v1:sha256:' + [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($Value))).ToLowerInvariant()
}

function Assert-NamedBridgeConfig {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Config,
        [Parameter(Mandatory)][string]$RepositoryRoot
    )

    if ($Config.rules -isnot [array] -or $Config.rules.Count -ne 1 -or
        [string]$Config.rules[0].id -cne $script:NamedCapability -or
        [string]$Config.rules[0].capability -cne $script:NamedCapability -or
        $Config.namedRule -isnot [Collections.IDictionary] -or
        $Config.toolkit -isnot [Collections.IDictionary] -or
        $Config.capability -isnot [Collections.IDictionary] -or
        [string]$Config.capability.id -cne $script:NamedCapability -or
        [string]$Config.capability.implementationSha256 -cne
            $script:NamedCapabilityDigest.Substring(10) -or
        $Config.subjectProvider -isnot [Collections.IDictionary] -or
        $Config.discussionProvider -isnot [Collections.IDictionary]) {
        throw 'Named bridge requires exactly one named AreEqual rule.'
    }
    if ($Config.Contains('autoCreateNamedAreEqualComments') -and
        ($Config.autoCreateNamedAreEqualComments -isnot [bool] -or
            [bool]$Config.autoCreateNamedAreEqualComments)) {
        throw 'Named bridge requires automatic delivery to remain literal false.'
    }
    $policyPath = Join-Path $RepositoryRoot (
        $script:NamedPolicyPath.Replace(
            '/', [IO.Path]::DirectorySeparatorChar))
    $policy = [IO.File]::ReadAllText(
        $policyPath, [Text.UTF8Encoding]::new($false))
    if ((Get-NamedBridgeTextDigest $policy) -cne
            $script:NamedPolicyDigest -or
        [Text.Encoding]::UTF8.GetByteCount($policy) -ne 653 -or
        [string]$Config.namedRule.path -cne
            $script:NamedPolicyPath -or
        [string]$Config.namedRule.section -cne
            $script:NamedCapability -or
        [string]$Config.namedRule.hash -cne
            $script:NamedPolicyDigest -or
        [long]$Config.namedRule.length -ne 653 -or
        [string]$Config.namedRule.repositoryId -notmatch
            '^[A-Za-z0-9_.-]{1,256}$' -or
        [string]$Config.toolkit.head -cnotmatch '^[0-9a-f]{40}$' -or
        [string]$Config.toolkit.tree -cnotmatch '^[0-9a-f]{40}$' -or
        [string]$Config.toolkit.ref -notmatch '^refs/heads/.+') {
        throw 'Named bridge rule or toolkit binding is invalid.'
    }
    if ([int]$Config.limits.maxChangedFiles -gt 64 -or
        [int]$Config.limits.maxChangedLines -gt 100000) {
        throw 'Named bridge exceeds the existing Owner acquisition bounds.'
    }
}

function Assert-NamedBridgeHead {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Expected,
        [Parameter(Mandatory)][Collections.IDictionary]$Actual
    )
    foreach ($name in @(
            'repositoryId', 'projectId', 'pullRequestId', 'sourceRef',
            'targetRef', 'sourceCommit', 'targetCommit', 'iterationId',
            'status', 'isDraft'
        )) {
        if ([string]$Expected[$name] -cne [string]$Actual[$name]) {
            throw 'head-drift'
        }
    }
}

function New-NamedBridgeManifestEntry {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Head,
        [Parameter(Mandatory)][Collections.IDictionary]$Config,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')]
        [string]$SharedSnapshotDigest
    )

    $subject = [ordered]@{
        repositoryId = ([string]$Head.repositoryId).ToLowerInvariant()
        projectId = ([string]$Head.projectId).ToLowerInvariant()
        pullRequestId = [long]$Head.pullRequestId
    }
    $headBinding = [ordered]@{
        sourceCommit = ([string]$Head.sourceCommit).ToLowerInvariant()
    }
    $target = [ordered]@{
        targetCommit = ([string]$Head.targetCommit).ToLowerInvariant()
        targetRef = [string]$Head.targetRef
    }
    $rule = [ordered]@{
        repositoryId = [string]$Config.namedRule.repositoryId
        path = $script:NamedPolicyPath
        commit = [string]$Config.toolkit.head
        section = $script:NamedCapability
        hash = $script:NamedPolicyDigest
        length = 653
    }
    $capability = [ordered]@{
        id = $script:NamedCapability
        digest = $script:NamedCapabilityDigest
    }
    $model = [ordered]@{
        id = 'none'
        digest = Get-NamedBridgeTextDigest 'none'
    }
    $configBinding = [ordered]@{
        id = $script:NamedConfigId
        digest = Get-NamedBridgeTextDigest $script:NamedConfigId
    }
    return [ordered]@{
        id = "named-areequal-pr-$([long]$Head.pullRequestId)-$(
            ([string]$Head.sourceCommit).Substring(0, 8))"
        mode = 'live'
        subject = $subject
        head = $headBinding
        target = $target
        rule = $rule
        capability = $capability
        model = $model
        config = $configBinding
        acquisition = [ordered]@{
            payloadDigest = Get-NamedBridgeDigest ([ordered]@{
                subject = $subject
                head = $headBinding
                target = $target
                rule = $rule
                capability = $capability
                config = $configBinding
                iterationId = [int]$Head.iterationId
                sharedSnapshotDigest = $SharedSnapshotDigest
            })
        }
    }
}

function New-NamedBridgeAcquisitionProvider {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Config,
        [Parameter(Mandatory)][Collections.IDictionary]$Heads,
        [Parameter(Mandatory)][Collections.IDictionary]$Changes,
        [Parameter(Mandatory)][Collections.IDictionary]$Snapshots,
        [Parameter(Mandatory)][string]$PolicyText
    )

    $reviewer = New-OwnerAzureDevOpsReviewerIdentity `
        -Id ([string]$Config.expectedAccount.id) `
        -Descriptor ([string]$Config.expectedAccount.descriptor) `
        -UniqueName ([string]$Config.expectedAccount.uniqueName)
    $digestCommand = ${function:Get-NamedBridgeDigest}
    $discussionPageCommand = Get-Command `
        -Name ConvertTo-OwnerAzureDevOpsDiscussionPage `
        -Module DevPilot.OwnerAdapters -CommandType Function `
        -ErrorAction Stop
    $namedPolicyPath = $script:NamedPolicyPath
    $namedPolicyDigest = $script:NamedPolicyDigest
    $namedCapability = $script:NamedCapability
    $handler = {
        param($Operation, $Arguments)
        $prId = [string][long]$Arguments.pullRequestId
        if (-not $Heads.Contains($prId) -or
            -not $Changes.Contains($prId) -or
            -not $Snapshots.Contains($prId)) {
            throw 'provider-contract'
        }
        $expected = $Heads[$prId]
        $changeSet = $Changes[$prId]
        $snapshot = $Snapshots[$prId]
        switch ($Operation) {
            'GetSubject' {
                return [ordered]@{
                    schemaVersion = 1
                    repositoryId = [string]$expected.repositoryId
                    projectId = [string]$expected.projectId
                    pullRequestId = [long]$expected.pullRequestId
                    sourceCommit = [string]$expected.sourceCommit
                    targetCommit = [string]$expected.targetCommit
                    targetRef = [string]$expected.targetRef
                    changedFileCount = @($changeSet.entries).Count
                    state = 'complete'
                    sourceDigest = & $digestCommand $expected
                }
            }
            'GetChangedFilesPage' {
                if ([int]$Arguments.pageOrdinal -ne 0 -or
                    $null -ne $Arguments.continuationToken) {
                    throw 'provider-contract'
                }
                return [ordered]@{
                    schemaVersion = 1
                    repositoryId = [string]$expected.repositoryId
                    projectId = [string]$expected.projectId
                    pullRequestId = [long]$expected.pullRequestId
                    sourceCommit = [string]$expected.sourceCommit
                    targetCommit = [string]$expected.targetCommit
                    targetRef = [string]$expected.targetRef
                    pageOrdinal = 0
                    continuationToken = $null
                    nextToken = $null
                    state = 'complete'
                    sourceDigest = & $digestCommand @(
                        $changeSet.entries | ForEach-Object {
                            [ordered]@{
                                path = $_.path
                                changeType = $_.changeType
                                sourceDigest = $_.sourceDigest
                                spans = $_.spans
                            }
                        })
                    changes = @($changeSet.entries | ForEach-Object {
                        $change = [ordered]@{
                            path = [string]$_.path
                            changeType = $(switch -Regex (
                                [string]$_.changeType) {
                                '^add$' { 'added'; break }
                                '^edit$' { 'modified'; break }
                                '^delete$' { 'deleted'; break }
                                'rename' { 'renamed'; break }
                                default { throw 'provider-contract' }
                            })
                            isBinary = [string]$_.state -cne 'complete'
                            sourceDigest = [string]$_.sourceDigest
                            spans = @($_.spans)
                        }
                        if ($change.changeType -ceq 'renamed' -and
                            $_.oldPath) {
                            $change['oldPath'] = [string]$_.oldPath
                        }
                        $change
                    })
                }
            }
            'GetRule' {
                return [ordered]@{
                    schemaVersion = 1
                    repositoryId = [string]$expected.repositoryId
                    projectId = [string]$expected.projectId
                    pullRequestId = [long]$expected.pullRequestId
                    sourceCommit = [string]$expected.sourceCommit
                    targetCommit = [string]$expected.targetCommit
                    targetRef = [string]$expected.targetRef
                    ruleRepositoryId =
                        [string]$Arguments.ruleRepositoryId
                    rulePath = [string]$Arguments.rulePath
                    ruleCommit = [string]$Arguments.ruleCommit
                    ruleSection = [string]$Arguments.ruleSection
                    ruleHash = [string]$Arguments.ruleHash
                    ruleLength = [long]$Arguments.ruleLength
                    state = 'complete'
                    content = $PolicyText
                    sourceDigest = $namedPolicyDigest
                }
            }
            'GetFile' {
                $matches = @($changeSet.entries | Where-Object {
                        [string]$_.path -ceq [string]$Arguments.path
                    })
                if ($matches.Count -ne 1) { throw 'provider-contract' }
                $file = $matches[0]
                return [ordered]@{
                    schemaVersion = 1
                    repositoryId = [string]$expected.repositoryId
                    projectId = [string]$expected.projectId
                    pullRequestId = [long]$expected.pullRequestId
                    sourceCommit = [string]$expected.sourceCommit
                    targetCommit = [string]$expected.targetCommit
                    targetRef = [string]$expected.targetRef
                    path = [string]$file.path
                    state = [string]$file.state
                    byteLength = [long]$file.byteLength
                    truncated = $false
                    content = $file.content
                    sourceDigest = [string]$file.sourceDigest
                }
            }
            'GetDiscussionPage' {
                return & $discussionPageCommand `
                    -Arguments $Arguments `
                    -RawResponse ([ordered]@{
                        value = @($snapshot.discussions.threads)
                        count =
                            [int]$snapshot.discussions.count
                    }) `
                    -CurrentIteration ([ordered]@{
                        id = [int]$expected.iterationId
                        sourceCommit = [string]$expected.sourceCommit
                        targetCommit = [string]$expected.targetCommit
                    }) -ReviewerIdentity $reviewer
            }
            default { throw 'provider-contract' }
        }
    }.GetNewClosure()
    return New-OwnerAzureDevOpsReadOnlyProviderAdapter `
        -Name 'named-areequal-current-pr-read-only' `
        -ReviewerIdentity $reviewer -Handler $handler
}

function Write-NamedBridgeManifest {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][Collections.IDictionary]$Manifest
    )
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $temporary = Join-Path $directory (
        '.named-manifest-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText(
            $temporary,
            (ConvertTo-Json -InputObject $Manifest -Depth 32) + "`n",
            [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $backup = Join-Path $directory (
                '.named-manifest-backup-' + [guid]::NewGuid().ToString('N'))
            [IO.File]::Replace($temporary, $Path, $backup, $true)
            Remove-Item -LiteralPath $backup -Force
        }
        else {
            [IO.File]::Move($temporary, $Path)
        }
    }
    finally {
        Remove-Item -LiteralPath $temporary `
            -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-NamedAreEqualCurrentPrBridge {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Config,
        [Parameter(Mandatory)][scriptblock]$Provider,
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [ValidateRange(0, 4)][int]$MaximumHeadsThisRun = 0,
        [AllowNull()][Collections.IDictionary]$PreparedIntake = $null,
        [switch]$Run
    )

    Assert-NamedBridgeConfig `
        -Config $Config -RepositoryRoot $RepositoryRoot
    if (-not $Run -or -not [bool]$Config.enabled) {
        $disabled = Invoke-ActivePrIntake `
            -Config $Config -Provider $Provider `
            -StateRoot $StateRoot -RepositoryRoot $RepositoryRoot
        return [pscustomobject][ordered]@{
            schemaVersion = 1
            kind = 'named-areequal-current-pr-bridge-result'
            state = 'disabled'
            intake = $disabled
            manifestPath = $null
            records = @()
            providerWrites = 0
            modelWrites = 0
        }
    }

    $intake = if ($null -ne $PreparedIntake) {
        $PreparedIntake
    }
    else {
        Invoke-ActivePrIntake `
            -Config $Config -Provider $Provider `
            -StateRoot $StateRoot -RepositoryRoot $RepositoryRoot `
            -MaximumHeadsThisRun $MaximumHeadsThisRun `
            -IncludeTransientSnapshots -Run
    }
    $snapshots = $intake.transientSnapshots
    [void]$intake.Remove('transientSnapshots')
    $selected = @($intake.heads | Where-Object {
            [string]$_.targetRef -ceq 'refs/heads/master' -and
            [string]$_.reasonCode -cnotin @(
                'not-selected', 'target-out-of-policy')
        })
    if ($selected.Count -lt 1) {
        $knownEmpty = [bool]$intake.populationKnown -and
            [string]$intake.inventory.state -ceq 'complete' -and
            [int]$intake.counts.error -eq 0 -and
            [int]$intake.inventory.eligible -eq 0
        return [pscustomobject][ordered]@{
            schemaVersion = 1
            kind = 'named-areequal-current-pr-bridge-result'
            state = $(if ($knownEmpty) {
                    'known-empty'
                } else { 'unknown' })
            intake = $intake
            manifestPath = $null
            records = @()
            providerWrites = 0
            modelWrites = 0
        }
    }

    $heads = [ordered]@{}
    $changes = [ordered]@{}
    $entriesById = [ordered]@{}
    $batchFailures = [Collections.Generic.List[object]]::new()
    foreach ($selectedHead in $selected) {
        $id = [string][long]$selectedHead.pullRequestId
        try {
            if ($selectedHead.declaration -isnot
                    [Collections.IDictionary] -or
                $snapshots -isnot [Collections.IDictionary] -or
                -not $snapshots.Contains($id)) {
                throw 'named-shared-snapshot-missing'
            }
            $head = [ordered]@{} + $selectedHead.declaration
            $snapshot = $snapshots[$id]
            Assert-NamedBridgeHead -Expected $head `
                -Actual $snapshot.head
            $changeSet = $snapshot.changes
            if ($changeSet.entries -isnot [array] -or
                [int]$changeSet.changedFiles -ne
                    @($changeSet.entries).Count -or
                $null -eq $changeSet.changedLines) {
                throw 'changed-line-evidence-unavailable'
            }
            $heads[$id] = $head
            $changes[$id] = $changeSet
            $entriesById[$id] =
                New-NamedBridgeManifestEntry `
                    -Head $head -Config $Config `
                    -SharedSnapshotDigest (
                        [string]$snapshot.sourceDigest)
        }
        catch {
            [void]$batchFailures.Add([ordered]@{
                    pullRequestId = [long]$selectedHead.pullRequestId
                    identity = $null
                    state = 'unknown'
                    reason = 'acquisition-incomplete'
                    stage = 'snapshot'
                })
        }
    }
    $policyPath = Join-Path $RepositoryRoot (
        $script:NamedPolicyPath.Replace(
            '/', [IO.Path]::DirectorySeparatorChar))
    $policyText = [IO.File]::ReadAllText(
        $policyPath, [Text.UTF8Encoding]::new($false))
    $acquisition = New-NamedBridgeAcquisitionProvider `
        -Config $Config -Heads $heads -Changes $changes `
        -Snapshots $snapshots -PolicyText $policyText
    $acceptedIds = [Collections.Generic.List[string]]::new()
    foreach ($pair in $heads.GetEnumerator()) {
        $head = $pair.Value
        $arguments = @{
            repositoryId = [string]$head.repositoryId
            projectId = [string]$head.projectId
            pullRequestId = [long]$head.pullRequestId
            sourceCommit = [string]$head.sourceCommit
            targetCommit = [string]$head.targetCommit
            targetRef = [string]$head.targetRef
        }
        try {
            [void](& $acquisition.Handler 'GetSubject' $arguments)
            $page = & $acquisition.Handler 'GetChangedFilesPage' (
                $arguments + @{
                    pageOrdinal = 0
                    continuationToken = $null
                    pageSize = 64
                })
            [void](& $acquisition.Handler 'GetRule' (
                $arguments + @{
                    ruleRepositoryId =
                        [string]$Config.namedRule.repositoryId
                    rulePath = $script:NamedPolicyPath
                    ruleCommit = [string]$Config.toolkit.head
                    ruleSection = $script:NamedCapability
                    ruleHash = $script:NamedPolicyDigest
                    ruleLength = 653
                }))
            foreach ($change in @($page.changes | Where-Object {
                        [string]$_.changeType -cne 'deleted' -and
                        -not [bool]$_.isBinary
                    })) {
                [void](& $acquisition.Handler 'GetFile' (
                    $arguments + @{ path = [string]$change.path }))
            }
            [void](& $acquisition.Handler 'GetDiscussionPage' (
                $arguments + @{
                    pageOrdinal = 0
                    continuationToken = $null
                    pageSize = 100
                }))
            [void]$acceptedIds.Add([string]$pair.Key)
        }
        catch {
            [void]$batchFailures.Add([ordered]@{
                    pullRequestId = [long]$head.pullRequestId
                    identity = $null
                    state = 'unknown'
                    reason = 'acquisition-incomplete'
                    stage = 'provider-preflight'
                })
        }
    }
    $acceptedHeads = [ordered]@{}
    $acceptedChanges = [ordered]@{}
    $acceptedSnapshots = [ordered]@{}
    $acceptedEntries = [Collections.Generic.List[object]]::new()
    foreach ($id in $acceptedIds) {
        $acceptedHeads[$id] = $heads[$id]
        $acceptedChanges[$id] = $changes[$id]
        $acceptedSnapshots[$id] = $snapshots[$id]
        [void]$acceptedEntries.Add($entriesById[$id])
    }
    if ($acceptedEntries.Count -eq 0) {
        return [pscustomobject][ordered]@{
            schemaVersion = 1
            kind = 'named-areequal-current-pr-bridge-result'
            state = 'partial'
            intake = $intake
            manifestPath = $null
            records = @()
            outcomes = $batchFailures.ToArray()
            completedCount = 0
            incompleteCount = $batchFailures.Count
            providerWrites = 0
            modelWrites = 0
        }
    }
    $heads = $acceptedHeads
    $changes = $acceptedChanges
    $snapshots = $acceptedSnapshots
    $acquisition = New-NamedBridgeAcquisitionProvider `
        -Config $Config -Heads $heads -Changes $changes `
        -Snapshots $snapshots -PolicyText $policyText
    $manifest = [ordered]@{
        schemaVersion = 1
        kind = 'named-areequal-v2-preview-cohort'
        entries = $acceptedEntries.ToArray()
    }
    Write-NamedBridgeManifest -Path $ManifestPath -Manifest $manifest
    [void](Invoke-OwnerV2PreviewPrepare `
            -StateRoot $StateRoot -ManifestPath $ManifestPath)
    $manifestModel = & (Get-Module DevPilot.OwnerOrchestrator) {
        param($Path)
        Read-OwnerV2Manifest -ManifestPath $Path
    } $ManifestPath
    $packageAccepted = [Collections.Generic.List[long]]::new()
    foreach ($entry in $manifestModel.Entries) {
        try {
            [void](& (Get-Module DevPilot.OwnerAdapters) {
                    param($Contract, $Provider)
                    $package = Get-OwnerLivePackage `
                        -Contract $Contract -Provider $Provider
                    ConvertTo-OwnerAcquisitionResponse `
                        -Package $package -Contract $Contract
                } $entry.Contract $acquisition)
            [void]$packageAccepted.Add(
                [long]$entry.Declaration.subject.pullRequestId)
        }
        catch {
            [void]$batchFailures.Add([ordered]@{
                    pullRequestId =
                        [long]$entry.Declaration.subject.pullRequestId
                    identity = $null
                    state = 'unknown'
                    reason = 'acquisition-incomplete'
                    stage = 'package-preflight'
                })
        }
    }
    if ($packageAccepted.Count -ne $manifestModel.Entries.Count) {
        $manifest.entries = @($manifest.entries |
            Where-Object {
                $packageAccepted.Contains(
                    [long]$_.subject.pullRequestId)
            })
        if (@($manifest.entries).Count -eq 0) {
            return [pscustomobject][ordered]@{
                schemaVersion = 1
                kind = 'named-areequal-current-pr-bridge-result'
                state = 'partial'
                intake = $intake
                manifestPath = $null
                records = @()
                outcomes = $batchFailures.ToArray()
                completedCount = 0
                incompleteCount = $batchFailures.Count
                providerWrites = 0
                modelWrites = 0
            }
        }
        Write-NamedBridgeManifest `
            -Path $ManifestPath -Manifest $manifest
        $manifestModel = & (Get-Module DevPilot.OwnerOrchestrator) {
            param($Path)
            Read-OwnerV2Manifest -ManifestPath $Path
        } $ManifestPath
    }
    $runResult = Invoke-OwnerV2PreviewRun `
        -StateRoot $StateRoot -ManifestPath $ManifestPath `
        -EnableLiveModel -LiveAcquisitionProvider $acquisition
    $postHeadFailures = [Collections.Generic.HashSet[long]]::new()
    foreach ($head in @($heads.Values | Where-Object {
                $packageAccepted.Contains(
                    [long]$_.pullRequestId)
            })) {
        try {
            $current = & $Provider 'Head' @{
                pullRequestId = [long]$head.pullRequestId
            }
            Assert-NamedBridgeHead -Expected $head -Actual $current
        }
        catch {
            [void]$postHeadFailures.Add(
                [long]$head.pullRequestId)
        }
    }
    $records = [Collections.Generic.List[object]]::new()
    $matchedPostHeadFailures =
        [Collections.Generic.HashSet[long]]::new()
    $recordOutcomes = @($runResult.records | ForEach-Object {
            $record = $_
            $observation = Get-ChildItem -LiteralPath $StateRoot `
                -Recurse -File -Filter "$($record.identity).json" |
                Where-Object { $_.Directory.Name -ceq 'observations' } |
                Select-Object -First 1
            $observationValue = if ($null -ne $observation) {
                Get-Content -LiteralPath $observation.FullName -Raw |
                    ConvertFrom-Json -AsHashtable -Depth 64
            }
            else { $null }
            $pullRequestId = if (
                $observationValue -is
                    [Collections.IDictionary]
            ) {
                [long]$observationValue.subject.pullRequestId
            }
            else { 0 }
            $postHeadRefused =
                $pullRequestId -gt 0 -and
                $postHeadFailures.Contains($pullRequestId)
            if ($postHeadRefused) {
                [void]$matchedPostHeadFailures.Add(
                    $pullRequestId)
            }
            $recordValue = [ordered]@{}
            if ($record -is [Collections.IDictionary]) {
                foreach ($key in $record.Keys) {
                    $recordValue[[string]$key] =
                        $record[$key]
                }
            }
            else {
                foreach ($property in
                    $record.PSObject.Properties) {
                    $recordValue[$property.Name] =
                        $property.Value
                }
            }
            if ($postHeadRefused) {
                $recordValue.state = 'unknown'
                $recordValue.reason =
                    'post-evaluation-head-refused'
            }
            [void]$records.Add(
                [pscustomobject]$recordValue)
            [ordered]@{
                identity = [string]$record.identity
                pullRequestId = $pullRequestId
                state = $(if ($postHeadRefused) {
                        'unknown'
                    } else { [string]$record.state })
                reason = $(if ($postHeadRefused) {
                        'post-evaluation-head-refused'
                    } else { [string]$record.reason })
                stage = $(if ($postHeadRefused) {
                        'post-head'
                    } else { 'evaluation' })
                observationPath = $(if ($null -ne $observation) {
                        $observation.FullName
                    } else { $null })
                observationStatus = $(if (
                        $observationValue -is
                            [Collections.IDictionary]
                    ) {
                        [string]$observationValue.lifecycle.status
                    } else { $null })
                unknown = $(if (
                        $observationValue -is
                            [Collections.IDictionary]
                    ) {
                        [int]$observationValue.counts.unknown
                    } else { $null })
                findingsComplete = $(if (
                        $observationValue -is
                            [Collections.IDictionary]
                    ) {
                        [bool]$observationValue.findingsComplete
                    } else { $false })
                validationErrors = $(if (
                        $observationValue -is
                            [Collections.IDictionary]
                    ) {
                        @($observationValue.validationErrors)
                    } else { @() })
            }
        })
    foreach ($pullRequestId in $postHeadFailures) {
        if (-not $matchedPostHeadFailures.Contains(
                $pullRequestId)) {
            [void]$batchFailures.Add([ordered]@{
                    pullRequestId = $pullRequestId
                    identity = $null
                    state = 'unknown'
                    reason =
                        'post-evaluation-head-refused'
                    stage = 'post-head'
                })
        }
    }
    $outcomes = @($batchFailures.ToArray()) +
        @($recordOutcomes)
    $incomplete = @($outcomes | Where-Object {
            [string]$_['state'] -cne 'completed' -or
            -not $_.Contains('observationStatus') -or
            [string]$_['observationStatus'] -cne
                'completed' -or
            -not $_.Contains('findingsComplete') -or
            -not [bool]$_['findingsComplete'] -or
            -not $_.Contains('unknown') -or
            [int]$_['unknown'] -ne 0 -or
            -not $_.Contains('validationErrors') -or
            @($_['validationErrors']).Count -ne 0
        })
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        kind = 'named-areequal-current-pr-bridge-result'
        state = $(if ($incomplete.Count -eq 0) {
                'completed'
            } else { 'partial' })
        intake = $intake
        manifestPath = [IO.Path]::GetFullPath($ManifestPath)
        records = $records.ToArray()
        outcomes = @($outcomes)
        completedCount = @($records.ToArray() | Where-Object {
                [string]$_.state -ceq 'completed'
            }).Count
        incompleteCount = $incomplete.Count
        providerWrites = 0
        modelWrites = 0
    }
}

Export-ModuleMember -Function Invoke-NamedAreEqualCurrentPrBridge
