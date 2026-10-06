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
        [Parameter(Mandatory)][Collections.IDictionary]$Config
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
            })
        }
    }
}

function New-NamedBridgeAcquisitionProvider {
    param(
        [Parameter(Mandatory)][scriptblock]$Provider,
        [Parameter(Mandatory)][Collections.IDictionary]$Config,
        [Parameter(Mandatory)][Collections.IDictionary]$Heads,
        [Parameter(Mandatory)][Collections.IDictionary]$Changes,
        [Parameter(Mandatory)][string]$PolicyText
    )

    $reviewer = New-OwnerAzureDevOpsReviewerIdentity `
        -Id ([string]$Config.expectedAccount.id) `
        -Descriptor ([string]$Config.expectedAccount.descriptor) `
        -UniqueName ([string]$Config.expectedAccount.uniqueName)
    $providerCommand = $Provider
    $assertHeadCommand = ${function:Assert-NamedBridgeHead}
    $digestCommand = ${function:Get-NamedBridgeDigest}
    $namedPolicyPath = $script:NamedPolicyPath
    $namedPolicyDigest = $script:NamedPolicyDigest
    $namedCapability = $script:NamedCapability
    $handler = {
        param($Operation, $Arguments)
        $prId = [string][long]$Arguments.pullRequestId
        if (-not $Heads.Contains($prId) -or
            -not $Changes.Contains($prId)) {
            throw 'provider-contract'
        }
        $expected = $Heads[$prId]
        $changeSet = $Changes[$prId]
        switch ($Operation) {
            'GetSubject' {
                $live = & $providerCommand 'Head' @{
                    pullRequestId = [long]$prId
                }
                & $assertHeadCommand -Expected $expected -Actual $live
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
                        [ordered]@{
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
                $live = & $providerCommand 'Head' @{
                    pullRequestId = [long]$prId
                }
                & $assertHeadCommand -Expected $expected -Actual $live
                $raw = & $providerCommand 'Discussions' @{
                    pullRequestId = [long]$prId
                    iterationId = [int]$expected.iterationId
                }
                return ConvertTo-OwnerAzureDevOpsDiscussionPage `
                    -Arguments $Arguments `
                    -RawResponse ([ordered]@{
                        value = @($raw.threads)
                        count = [int]$raw.count
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

    $intake = Invoke-ActivePrIntake `
        -Config $Config -Provider $Provider `
        -StateRoot $StateRoot -RepositoryRoot $RepositoryRoot -Run
    $selected = @($intake.heads | Where-Object {
            $_.declaration -is [Collections.IDictionary] -and
            [string]$_.targetRef -ceq 'refs/heads/master' -and
            [string]$_.reasonCode -ceq 'rules-incomplete'
        })
    if ($selected.Count -lt 1) {
        return [pscustomobject][ordered]@{
            schemaVersion = 1
            kind = 'named-areequal-current-pr-bridge-result'
            state = 'no-eligible-heads'
            intake = $intake
            manifestPath = $null
            records = @()
            providerWrites = 0
            modelWrites = 0
        }
    }

    $heads = [ordered]@{}
    $changes = [ordered]@{}
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($selectedHead in $selected) {
        $head = [ordered]@{} + $selectedHead.declaration
        $id = [string][long]$head.pullRequestId
        $current = & $Provider 'Head' @{
            pullRequestId = [long]$head.pullRequestId
        }
        Assert-NamedBridgeHead -Expected $head -Actual $current
        $changeSet = & $Provider 'Changes' @{
            pullRequestId = [long]$head.pullRequestId
            iterationId = [int]$head.iterationId
            sourceCommit = [string]$head.sourceCommit
            targetCommit = [string]$head.targetCommit
        }
        if ($changeSet.entries -isnot [array] -or
            [int]$changeSet.changedFiles -ne
                @($changeSet.entries).Count -or
            $null -eq $changeSet.changedLines) {
            throw 'changed-line-evidence-unavailable'
        }
        $heads[$id] = $head
        $changes[$id] = $changeSet
        [void]$entries.Add(
            (New-NamedBridgeManifestEntry -Head $head -Config $Config))
    }

    $manifest = [ordered]@{
        schemaVersion = 1
        kind = 'named-areequal-v2-preview-cohort'
        entries = $entries.ToArray()
    }
    Write-NamedBridgeManifest -Path $ManifestPath -Manifest $manifest
    $policyPath = Join-Path $RepositoryRoot (
        $script:NamedPolicyPath.Replace(
            '/', [IO.Path]::DirectorySeparatorChar))
    $policyText = [IO.File]::ReadAllText(
        $policyPath, [Text.UTF8Encoding]::new($false))
    $acquisition = New-NamedBridgeAcquisitionProvider `
        -Provider $Provider -Config $Config -Heads $heads `
        -Changes $changes -PolicyText $policyText
    foreach ($head in $heads.Values) {
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
        }
        catch {
            throw "named-acquisition-preflight:$([string]$_.Exception.Message)"
        }
    }
    [void](Invoke-OwnerV2PreviewPrepare `
            -StateRoot $StateRoot -ManifestPath $ManifestPath)
    $manifestModel = & (Get-Module DevPilot.OwnerOrchestrator) {
        param($Path)
        Read-OwnerV2Manifest -ManifestPath $Path
    } $ManifestPath
    foreach ($entry in $manifestModel.Entries) {
        try {
            [void](& (Get-Module DevPilot.OwnerAdapters) {
                    param($Contract, $Provider)
                    $package = Get-OwnerLivePackage `
                        -Contract $Contract -Provider $Provider
                    ConvertTo-OwnerAcquisitionResponse `
                        -Package $package -Contract $Contract
                } $entry.Contract $acquisition)
        }
        catch {
            throw "named-package-preflight:$([string]$_.Exception.Message):$([string]$_.ScriptStackTrace)"
        }
    }
    $runResult = Invoke-OwnerV2PreviewRun `
        -StateRoot $StateRoot -ManifestPath $ManifestPath `
        -EnableLiveModel -LiveAcquisitionProvider $acquisition
    foreach ($head in $heads.Values) {
        $current = & $Provider 'Head' @{
            pullRequestId = [long]$head.pullRequestId
        }
        Assert-NamedBridgeHead -Expected $head -Actual $current
    }
    if (@($runResult.records | Where-Object {
                [string]$_.state -cne 'completed'
            }).Count -gt 0) {
        $details = @($runResult.records | ForEach-Object {
                $record = $_
                $observation = Get-ChildItem -LiteralPath $StateRoot `
                    -Recurse -File -Filter "$($record.identity).json" |
                    Where-Object { $_.Directory.Name -ceq 'observations' } |
                    Select-Object -First 1
                $errors = if ($null -ne $observation) {
                    @((Get-Content -LiteralPath $observation.FullName -Raw |
                        ConvertFrom-Json -AsHashtable -Depth 32).
                        validationErrors) -join '|'
                }
                else { '' }
                "$($record.identity)=$($record.state)/$($record.reason)/$errors"
            })
        throw ('named-observation-incomplete:' +
            ($details -join ','))
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        kind = 'named-areequal-current-pr-bridge-result'
        state = 'completed'
        intake = $intake
        manifestPath = [IO.Path]::GetFullPath($ManifestPath)
        records = @($runResult.records)
        providerWrites = 0
        modelWrites = 0
    }
}

Export-ModuleMember -Function Invoke-NamedAreEqualCurrentPrBridge
