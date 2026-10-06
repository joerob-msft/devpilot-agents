#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AutomaticOwnerV2Capability = 'bpm-test-ownership@1'
$script:AutomaticNamedAreEqualCapability = 'bpm-named-areequal-arguments@1'
$script:AutomaticNamedAreEqualRoot = 'named-areequal-v1'
$script:AutomaticOwnerV2MaximumCreatesPerRun = 5
$script:AutomaticOwnerV2MaximumCreatesPerPullRequest = 50
$script:AutomaticNamedAreEqualMaximumCreatesPerRun = 2
$script:AutomaticNamedAreEqualMaximumCreatesPerPullRequest = 5

function Read-AutomaticNamedAreEqualEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')]
        [string]$Identity,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ToolkitConfigPath
    )
    return Read-ApprovedOwnerV2Evidence `
        -StateRoot $StateRoot -Identity $Identity -RepoRoot $RepoRoot `
        -ToolkitConfigPath $ToolkitConfigPath -Delivery named-areequal
}

function Get-AutomaticOwnerV2ExitCode {
    param([Parameter(Mandatory)][string]$Health)
    switch ($Health) {
        'healthy' { 0 }
        'disabled' { 0 }
        'partial' { 2 }
        'refused' { 3 }
        default { 1 }
    }
}

function Get-AutomaticOwnerV2RunLimit {
    param(
        [Parameter(Mandatory)][int]$PolicyMaximum,
        [ValidateRange(0, 5)][int]$RequestedMaximum = 5
    )
    if ($PolicyMaximum -lt 1 -or
        $PolicyMaximum -gt $script:AutomaticOwnerV2MaximumCreatesPerRun) {
        throw 'Automatic Owner per-run create ceiling is invalid.'
    }
    return [Math]::Min($PolicyMaximum, $RequestedMaximum)
}

function Get-AutomaticOwnerV2ScheduledHealth {
    param(
        [Parameter(Mandatory)][int]$FailedCount,
        [Parameter(Mandatory)][int]$CompletedCount,
        [Parameter(Mandatory)][bool]$AutomaticEnabled,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$DeliveryResults,
        [Parameter(Mandatory)][int]$RemainingRunCreates,
        [Parameter(Mandatory)][int]$ProcessedRecords
    )
    if ($FailedCount -gt 0 -and $CompletedCount -eq 0) { return 'refused' }
    if ($FailedCount -gt 0) { return 'partial' }
    if (-not $AutomaticEnabled) { return 'disabled' }
    $refusedCount = @($DeliveryResults | Where-Object {
            [string]$_.health -ceq 'refused'
        }).Count
    if ($refusedCount -gt 0) {
        if ($DeliveryResults.Count -gt $refusedCount) { return 'partial' }
        return 'refused'
    }
    if (@($DeliveryResults | Where-Object {
                [string]$_.health -ceq 'partial'
            }).Count -gt 0 -or
        ($RemainingRunCreates -eq 0 -and
            $ProcessedRecords -lt $CompletedCount)) {
        return 'partial'
    }
    return 'healthy'
}

function Initialize-AutomaticOwnerV2DeliveryRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DeliveryRoot,
        [Parameter(Mandatory)][string]$RepoRoot,
        [ValidateSet('owner', 'named-areequal')]
        [string]$Delivery = 'owner'
    )
    if ($Delivery -ceq 'named-areequal') {
        $base = Resolve-AgentTrustedRoot -Path $DeliveryRoot `
            -Kind durable-state -RepositoryRoot $RepoRoot -Create
        $DeliveryRoot = Join-Path $base $script:AutomaticNamedAreEqualRoot
    }
    $created = $false
    $root = Resolve-AgentTrustedRoot -Path $DeliveryRoot -Kind durable-state `
        -RepositoryRoot $RepoRoot -Create -CreatedByCaller ([ref]$created)
    foreach ($leaf in @(
            'keys', 'policies', 'intents', 'outcomes', 'events', 'locks'
        )) {
        $path = Join-Path $root $leaf
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            New-Item -ItemType Directory -Path $path | Out-Null
        }
    }
    $keyPath = Join-Path $root (
        'keys\' + $(if ($Delivery -ceq 'named-areequal') {
            'named-areequal-service-authorization.hmac'
        } else { 'owner-v2-service-authorization.hmac' }))
    if (-not (Test-Path -LiteralPath $keyPath -PathType Leaf)) {
        $bytes = [byte[]]::new(32)
        [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
        [IO.File]::WriteAllBytes($keyPath, $bytes)
    }
    [void](Assert-AgentTrustedFile -Path $keyPath -AllowedRoot $root -Private)
    return [pscustomobject]@{ Root = $root; KeyPath = $keyPath }
}

function Get-AutomaticOwnerV2ServiceKey {
    param(
        [Parameter(Mandatory)][string]$DeliveryRoot,
        [ValidateSet('owner', 'named-areequal')]
        [string]$Delivery = 'owner'
    )
    $path = Join-Path $DeliveryRoot (
        'keys\' + $(if ($Delivery -ceq 'named-areequal') {
            'named-areequal-service-authorization.hmac'
        } else { 'owner-v2-service-authorization.hmac' }))
    [void](Assert-AgentTrustedFile -Path $path -AllowedRoot $DeliveryRoot -Private)
    $key = [IO.File]::ReadAllBytes($path)
    if ($key.Length -ne 32) {
        throw 'Owner v2 service authorization key must be exactly 32 bytes.'
    }
    return $key
}

function Get-AutomaticOwnerV2Configuration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$ToolkitConfig,
        [ValidateSet('owner', 'named-areequal')]
        [string]$Delivery = 'owner'
    )
    $configKey = if ($Delivery -ceq 'named-areequal') {
        'autoCreateNamedAreEqualComments'
    } else { 'autoCreateOwnerComments' }
    if (-not $ToolkitConfig.Contains($configKey)) {
        return [pscustomobject][ordered]@{
            Enabled = $false
            PolicyPath = ''
            PolicySha256 = ''
        }
    }
    $value = $ToolkitConfig[$configKey]
    if ($value -is [bool]) {
        if ($value) {
            throw "$configKey=true requires an exact signed policy binding."
        }
        return [pscustomobject][ordered]@{
            Enabled = $false
            PolicyPath = ''
            PolicySha256 = ''
        }
    }
    if ($value -isnot [Collections.IDictionary]) {
        throw "$configKey must be false or an exact configuration object."
    }
    $enabledValue = Get-ApprovedOwnerV2Value $value 'enabled' $null
    if ($enabledValue -isnot [bool]) {
        throw "$configKey.enabled must be an exact JSON boolean."
    }
    $enabled = [bool]$enabledValue
    if (-not $enabled) {
        throw 'Use the literal false value to disable automatic Owner delivery.'
    }
    Assert-ApprovedOwnerV2ExactKeys -Value $value `
        -Expected @('enabled', 'policyPath', 'policySha256') `
        -Name $configKey
    $path = [string]$value.policyPath
    $sha256 = [string]$value.policySha256
    if (-not [IO.Path]::IsPathFullyQualified($path) -or
        $sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Automatic Owner policy path and SHA-256 binding are invalid.'
    }
    return [pscustomobject][ordered]@{
        Enabled = $true
        PolicyPath = [IO.Path]::GetFullPath($path)
        PolicySha256 = $sha256
    }
}

function New-AutomaticOwnerV2ServicePolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z0-9][a-z0-9_.-]{2,63}$')]
        [string]$PolicyId,
        [ValidateRange(1, 5)][int]$MaxCreatesPerRun = 5,
        [ValidateRange(1, 50)][int]$MaxCreatesPerPullRequest = 25,
        [string]$CreatedUtc = ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))
    )
    $namedAreEqual =
        [string]$Evidence.Declaration.capability.id -ceq
            $script:AutomaticNamedAreEqualCapability
    if ($namedAreEqual) {
        if (-not $PSBoundParameters.ContainsKey('MaxCreatesPerRun')) {
            $MaxCreatesPerRun =
                $script:AutomaticNamedAreEqualMaximumCreatesPerRun
        }
        if (-not $PSBoundParameters.ContainsKey(
                'MaxCreatesPerPullRequest')) {
            $MaxCreatesPerPullRequest =
                $script:AutomaticNamedAreEqualMaximumCreatesPerPullRequest
        }
    }
    if ($MaxCreatesPerPullRequest -lt $MaxCreatesPerRun) {
        throw 'The per-PR create ceiling cannot be lower than the per-run ceiling.'
    }
    if (-not $namedAreEqual -and
        [string]$Evidence.Declaration.capability.id -cne
            $script:AutomaticOwnerV2Capability) {
        throw 'Automatic delivery evidence uses an unsupported capability.'
    }
    if ($namedAreEqual -and
        [string]$Evidence.Declaration.rule.path -cne
            $script:ApprovedNamedAreEqualPolicyPath) {
        throw 'Named AreEqual requires its exact rule path.'
    }
    if ($namedAreEqual -and (
            $MaxCreatesPerRun -gt
                $script:AutomaticNamedAreEqualMaximumCreatesPerRun -or
            $MaxCreatesPerPullRequest -gt
                $script:AutomaticNamedAreEqualMaximumCreatesPerPullRequest)) {
        throw 'Named AreEqual service policy create ceilings exceed 2 per run or 5 per pull request.'
    }
    $copy = {
        param($Value)
        return ConvertTo-ApprovedOwnerV2CanonicalJson $Value |
            ConvertFrom-Json -AsHashtable -Depth 64
    }
    $implementation = [ordered]@{
        toolkitHead = [string]$Evidence.Toolkit.head
        toolkitTree = [string]$Evidence.Toolkit.tree
        formatterSha256 = [string]$Evidence.Toolkit.formatterSha256
        formatterManifestSha256 =
            [string]$Evidence.Toolkit.formatterManifestSha256
        approvedWriterSha256 = [string]$Evidence.Toolkit.writerSha256
        providerSha256 = [string]$Evidence.Toolkit.providerSha256
        automaticWriterSha256 =
            [string]$Evidence.Toolkit.automaticWriterSha256
        schedulerSha256 = [string]$Evidence.Toolkit.schedulerSha256
    }
    if ($namedAreEqual) {
        $implementation['parserSha256'] =
            [string]$Evidence.Toolkit.parserSha256
        $implementation['parserManifestSha256'] =
            [string]$Evidence.Toolkit.parserManifestSha256
    }
    return [ordered]@{
        schemaVersion = 1
        kind = $(if ($namedAreEqual) {
                'named-areequal-v1-service-authorization-policy'
            } else { 'owner-v2-service-authorization-policy' })
        enabled = $true
        policyId = $PolicyId
        repository = [ordered]@{
            projectId = [string]$Evidence.Declaration.subject.projectId
            repositoryId = [string]$Evidence.Declaration.subject.repositoryId
        }
        capability = & $copy $Evidence.Declaration.capability
        rule = & $copy $Evidence.Declaration.rule
        reviewerIdentity = & $copy $Evidence.Provider.reviewerIdentity
        implementation = $implementation
        limits = [ordered]@{
            maxCreatesPerRun = $MaxCreatesPerRun
            maxCreatesPerPullRequest = $MaxCreatesPerPullRequest
        }
        authority = [ordered]@{
            action = 'create'
            classification = 'wouldCreate'
            construct = $(if ($namedAreEqual) {
                    'changed-mstest-method-areequal-calls'
                } else { 'changed-mstest-method' })
            disposition = 'violation'
            updates = $false
            threadStatusWrites = $false
            relationCapability = $false
            modelAuthorization = $false
        }
        createdUtc = $CreatedUtc
    }
}

function Write-AutomaticOwnerV2ServicePolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][Collections.IDictionary]$Policy,
        [Parameter(Mandatory)][byte[]]$Key
    )
    return Write-ApprovedOwnerV2SignedRecord -Path $Path -Payload $Policy -Key $Key
}

function Assert-AutomaticOwnerV2ServicePolicy {
    param(
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][Collections.IDictionary]$Policy
    )
    Assert-ApprovedOwnerV2ExactKeys -Value $Policy -Name policy -Expected @(
        'schemaVersion', 'kind', 'enabled', 'policyId', 'repository', 'capability',
        'rule', 'reviewerIdentity', 'implementation', 'limits', 'authority',
        'createdUtc'
    )
    $namedAreEqual =
        [string]$Evidence.Declaration.capability.id -ceq
            $script:AutomaticNamedAreEqualCapability
    $expectedKind = if ($namedAreEqual) {
        'named-areequal-v1-service-authorization-policy'
    } else { 'owner-v2-service-authorization-policy' }
    $expectedConstruct = if ($namedAreEqual) {
        'changed-mstest-method-areequal-calls'
    } else { 'changed-mstest-method' }
    if ([int]$Policy.schemaVersion -ne 1 -or
        [string]$Policy.kind -cne $expectedKind -or
        -not [bool]$Policy.enabled -or
        [string]$Policy.policyId -cnotmatch '^[a-z0-9][a-z0-9_.-]{2,63}$') {
        throw 'Automatic Owner service policy is disabled or unsupported.'
    }
    $runLimit = [int]$Policy.limits.maxCreatesPerRun
    $prLimit = [int]$Policy.limits.maxCreatesPerPullRequest
    $maximumRun = if ($namedAreEqual) {
        $script:AutomaticNamedAreEqualMaximumCreatesPerRun
    }
    else { $script:AutomaticOwnerV2MaximumCreatesPerRun }
    $maximumPr = if ($namedAreEqual) {
        $script:AutomaticNamedAreEqualMaximumCreatesPerPullRequest
    }
    else { $script:AutomaticOwnerV2MaximumCreatesPerPullRequest }
    if ($runLimit -lt 1 -or
        $runLimit -gt $maximumRun -or
        $prLimit -lt $runLimit -or
        $prLimit -gt $maximumPr) {
        throw 'Automatic Owner service policy create ceilings are invalid.'
    }
    foreach ($digest in @(
            [string]$Policy.implementation.toolkitHead,
            [string]$Policy.implementation.toolkitTree
        )) {
        if ($digest -cnotmatch '^[0-9a-f]{40}$') {
            throw 'Automatic Owner toolkit implementation identity is invalid.'
        }
    }
    $implementationDigests = @(
            [string]$Policy.implementation.formatterSha256,
            [string]$Policy.implementation.formatterManifestSha256,
            [string]$Policy.implementation.approvedWriterSha256,
            [string]$Policy.implementation.providerSha256,
            [string]$Policy.implementation.automaticWriterSha256,
            [string]$Policy.implementation.schedulerSha256
        )
    if ($namedAreEqual) {
        $implementationDigests += @(
            [string]$Policy.implementation.parserSha256,
            [string]$Policy.implementation.parserManifestSha256
        )
    }
    foreach ($digest in $implementationDigests) {
        if ($digest -cnotmatch '^[0-9a-f]{64}$') {
            throw 'Automatic Owner implementation digest is invalid.'
        }
    }
    if ($namedAreEqual) {
        if ([string]::IsNullOrWhiteSpace(
                [string]$Evidence.Paths.parser) -or
            [string]::IsNullOrWhiteSpace(
                [string]$Evidence.Paths.parserManifest)) {
            throw 'Named AreEqual evidence has no parser implementation paths.'
        }
        $currentParser =
            Get-ApprovedOwnerV2FileSha256 $Evidence.Paths.parser
        $currentManifest =
            Get-ApprovedOwnerV2FileSha256 $Evidence.Paths.parserManifest
        if ($currentParser -cne
                [string]$Evidence.Toolkit.parserSha256 -or
            $currentManifest -cne
                [string]$Evidence.Toolkit.parserManifestSha256 -or
            $currentParser -cne
                [string]$Policy.implementation.parserSha256 -or
            $currentManifest -cne
                [string]$Policy.implementation.parserManifestSha256) {
            throw 'Named AreEqual parser implementation changed.'
        }
    }
    $authority = $Policy.authority
    if ([string]$authority.action -cne 'create' -or
        [string]$authority.classification -cne 'wouldCreate' -or
        [string]$authority.construct -cne $expectedConstruct -or
        [string]$authority.disposition -cne 'violation' -or
        [bool]$authority.updates -or [bool]$authority.threadStatusWrites -or
        [bool]$authority.relationCapability -or
        [bool]$authority.modelAuthorization) {
        throw 'Automatic Owner service policy exceeds create-only authority.'
    }
    $expected = New-AutomaticOwnerV2ServicePolicy -Evidence $Evidence `
        -PolicyId ([string]$Policy.policyId) `
        -MaxCreatesPerRun $runLimit -MaxCreatesPerPullRequest $prLimit `
        -CreatedUtc ([string]$Policy.createdUtc)
    foreach ($name in @(
            'repository', 'capability', 'rule', 'reviewerIdentity',
            'implementation', 'limits', 'authority'
        )) {
        if ((Get-ApprovedOwnerV2Digest $Policy[$name]) -cne
            (Get-ApprovedOwnerV2Digest $expected[$name])) {
            throw "Automatic Owner service policy binding '$name' is stale or foreign."
        }
    }
}

function Get-AutomaticOwnerV2Diagnostic {
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Message
    )
    if ($Code -cnotmatch '^[a-z0-9][a-z0-9-]{2,63}$') {
        throw 'Automatic Owner diagnostic code is invalid.'
    }
    $clean = ($Message -replace '[\x00-\x1f\x7f]', ' ').Trim()
    if ($clean.Length -gt 256) { $clean = $clean.Substring(0, 256) }
    return [ordered]@{ code = $Code; message = $clean }
}

function Write-AutomaticOwnerV2Event {
    param(
        [Parameter(Mandatory)][string]$DeliveryRoot,
        [Parameter(Mandatory)][Collections.IDictionary]$Event,
        [Parameter(Mandatory)][byte[]]$Key
    )
    $path = Join-Path $DeliveryRoot (
        "events\$($Event.eventId).json")
    [void](Write-ApprovedOwnerV2SignedRecord -Path $path -Payload $Event -Key $Key)
    return $path
}

function New-AutomaticOwnerV2Event {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][Collections.IDictionary]$Selection,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Outcome,
        [Parameter(Mandatory)][string]$RunHealth,
        [long]$ThreadId = 0,
        [long]$CommentId = 0,
        [string]$Url = '',
        [int]$ProviderWriteCount = 0,
        [ValidateSet('none', 'confirmed', 'unknown')]
        [string]$ProviderWriteState = 'none',
        [AllowNull()][Collections.IDictionary]$Diagnostic = $null
    )
    $namedAreEqual =
        [string]$Evidence.Declaration.capability.id -ceq
            $script:AutomaticNamedAreEqualCapability
    $event = [ordered]@{
        schemaVersion = 1
        kind = $(if ($namedAreEqual) {
                'named-areequal-v2-delivery-event'
            } else { 'owner-v2-delivery-event' })
        eventId = [guid]::NewGuid().ToString('N')
        runId = $RunId
        occurredUtc = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
        runHealth = $RunHealth
        subject = [ordered]@{
            projectId = [string]$Evidence.Declaration.subject.projectId
            repositoryId = [string]$Evidence.Declaration.subject.repositoryId
            pullRequestId = [long]$Evidence.Declaration.subject.pullRequestId
            sourceCommit = [string]$Evidence.Declaration.head.sourceCommit
            targetCommit = [string]$Evidence.Declaration.target.targetCommit
            targetRef = [string]$Evidence.Declaration.target.targetRef
        }
        finding = [ordered]@{
            stateIdentity = [string]$Evidence.Identity
            findingId = [string]$Selection.findingId
            marker = [string]$Selection.marker
            path = [string]$Selection.path
            line = [int]$Selection.line
            symbol = [string]$Selection.symbol
        }
        action = $Action
        outcome = $Outcome
        threadId = $(if ($ThreadId -gt 0) { $ThreadId } else { $null })
        commentId = $(if ($CommentId -gt 0) { $CommentId } else { $null })
        url = $(if ($Url) { $Url } else { $null })
        modelWriteCount = 0
        providerWriteCount = $ProviderWriteCount
        providerWriteState = $ProviderWriteState
        diagnostic = $Diagnostic
    }
    if ($namedAreEqual) {
        if ([string]$Selection.bodySha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw 'Named AreEqual audit requires an exact formatted body digest.'
        }
        $event['capabilityId'] =
            $script:AutomaticNamedAreEqualCapability
        $event.finding['bodySha256'] = [string]$Selection.bodySha256
    }
    return $event
}

function Get-AutomaticOwnerV2CommentUrl {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Provider,
        [Parameter(Mandatory)][long]$PullRequestId,
        [Parameter(Mandatory)][long]$ThreadId
    )
    $organization = ([string]$Provider.organization).TrimEnd('/')
    $project = [Uri]::EscapeDataString([string]$Provider.projectName)
    $repository = [Uri]::EscapeDataString([string]$Provider.repositoryId)
    if (-not $organization -or -not $project -or -not $repository -or
        $ThreadId -lt 1) {
        return ''
    }
    return "$organization/$project/_git/$repository/pullrequest/" +
        "${PullRequestId}?_a=files&discussionId=$ThreadId"
}

function New-AutomaticNamedAreEqualReviewPackage {
    param([Parameter(Mandatory)]$Evidence)
    return [pscustomobject]@{
        proposals = @($Evidence.Observation.findings |
            Where-Object {
                [string]$_.reconciliation.classification -cin @(
                    'wouldCreate', 'noOp', 'humanCovered')
            } | ForEach-Object {
                Get-ApprovedOwnerV2Proposal `
                    -Evidence $Evidence -Finding $_ `
                    -Delivery named-areequal
            } | Sort-Object findingId)
    }
}

function Assert-AutomaticNamedAreEqualLiveNoOp {
    param(
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)][Collections.IDictionary]$Selection,
        [Parameter(Mandatory)][string]$SourceCommit
    )
    $entry = Get-AutomaticOwnerV2ConfirmedEntry `
        -Snapshot $Snapshot -Selection $Selection -NamedAreEqual `
        -SourceCommit $SourceCommit
    if ($null -eq $entry) {
        throw 'Named AreEqual marker/body is not one exact current no-op.'
    }
}

function Invoke-AutomaticOwnerV2Read {
    param(
        [Parameter(Mandatory)][scriptblock]$Provider,
        [Parameter(Mandatory)][hashtable]$Arguments,
        [int]$MaximumAttempts = 3
    )
    $last = $null
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try { return & $Provider 'ReadCurrent' $Arguments }
        catch {
            $last = $_
            if ($attempt -lt $MaximumAttempts) {
                Start-Sleep -Milliseconds ([Math]::Min(1000, 100 * $attempt))
            }
        }
    }
    throw $last
}

function Assert-AutomaticOwnerV2EvidenceCurrent {
    param(
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][Collections.IDictionary]$Intent
    )
    $namedAreEqual =
        [string]$Evidence.Declaration.capability.id -ceq
            $script:AutomaticNamedAreEqualCapability
    $bindings = [ordered]@{
        declarationSha256 =
            Get-ApprovedOwnerV2FileSha256 $Evidence.Paths.declaration
        evidenceSha256 = Get-ApprovedOwnerV2FileSha256 $Evidence.Paths.evidence
        recordSha256 = Get-ApprovedOwnerV2FileSha256 $Evidence.Paths.record
        observationSha256 =
            Get-ApprovedOwnerV2FileSha256 $Evidence.Paths.observation
        telemetrySha256 = $(if ($namedAreEqual) {
                'not-applicable'
            }
            else {
                Get-ApprovedOwnerV2FileSha256 $Evidence.Paths.telemetry
            })
        resultDigest = [string]$Evidence.Record.resultDigest
    }
    if ($namedAreEqual) {
        $bindings['parserSha256'] =
            Get-ApprovedOwnerV2FileSha256 $Evidence.Paths.parser
        $bindings['parserManifestSha256'] =
            Get-ApprovedOwnerV2FileSha256 $Evidence.Paths.parserManifest
    }
    foreach ($entry in $bindings.GetEnumerator()) {
        if ([string]$Intent.state[$entry.Key] -cne [string]$entry.Value) {
            throw "Automatic Owner state binding '$($entry.Key)' changed."
        }
    }
}

function Get-AutomaticOwnerV2ConfirmedEntry {
    param(
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)][Collections.IDictionary]$Selection,
        [switch]$NamedAreEqual,
        [string]$SourceCommit = ''
    )
    $entries = @(Get-ApprovedOwnerV2MarkerEntries -Snapshot $Snapshot `
            -Marker ([string]$Selection.marker) -Pattern $(if ($NamedAreEqual) {
                '<!--\s*devpilot-named-areequal:v1:([0-9a-f]{64})\s*-->'
            } else { $script:ApprovedOwnerV2MarkerPattern }))
    $confirmed = @($entries | Where-Object {
            [bool]$_.Comment.reviewerOwned -and
            [string]$_.Comment.reviewerIdentityState -ceq 'matched' -and
            [string]$_.Comment.body -ceq [string]$Selection.body -and
            -not [bool]$_.Comment.isDeleted
        })
    if ($confirmed.Count -eq 1 -and $entries.Count -eq 1) {
        if ($NamedAreEqual -and (
                [string]::IsNullOrWhiteSpace($SourceCommit) -or
                [bool]$confirmed[0].Thread.isDeleted -or
                [bool]$confirmed[0].Thread.isOutdated -or
                [string]$confirmed[0].Thread.status -cne 'active' -or
                [string]$confirmed[0].Thread.contextState -cne 'current' -or
                [string]$confirmed[0].Thread.sourceCommit -cne $SourceCommit -or
                $null -eq $confirmed[0].Thread.anchor -or
                [string]$confirmed[0].Thread.anchor.path -ine
                    [string]$Selection.path -or
                [int]$confirmed[0].Thread.anchor.line -ne
                    [int]$Selection.line)) {
            throw "Finding '$($Selection.findingId)' readback is stale."
        }
        return $confirmed[0]
    }
    if ($entries.Count -gt 0) {
        throw "Finding '$($Selection.findingId)' marker is duplicate, foreign, or stale."
    }
    return $null
}

function Get-AutomaticOwnerV2DeliveryHistory {
    param(
        [Parameter(Mandatory)][string]$DeliveryRoot,
        [Parameter(Mandatory)][byte[]]$Key,
        [Parameter(Mandatory)]$Evidence
    )
    $markers = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    $blocked = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    $expectedKind = if ([string]$Evidence.Declaration.capability.id -ceq
        $script:AutomaticNamedAreEqualCapability) {
        'named-areequal-v2-delivery-event'
    } else { 'owner-v2-delivery-event' }
    foreach ($file in @(Get-ChildItem -LiteralPath (
                    Join-Path $DeliveryRoot 'events') -Filter '*.json' -File `
                -ErrorAction SilentlyContinue)) {
        $event = Read-ApprovedOwnerV2SignedRecord -Path $file.FullName -Key $Key
        if ([string]$event.kind -cne $expectedKind) {
            throw "Automatic Owner event '$($file.FullName)' is foreign."
        }
        if ([string]$event.subject.repositoryId -cne
            [string]$Evidence.Declaration.subject.repositoryId -or
            [long]$event.subject.pullRequestId -ne
            [long]$Evidence.Declaration.subject.pullRequestId) {
            continue
        }
        if ([string]$event.outcome -cin @(
                'created', 'created-confirmed-after-error', 'recovered-confirmed'
            )) {
            [void]$markers.Add([string]$event.finding.marker)
        }
        elseif ([string]$event.outcome -ceq 'ambiguous-post-write') {
            [void]$blocked.Add([string]$event.finding.marker)
        }
    }
    return [pscustomobject]@{
        CreatedMarkers = $markers
        BlockedMarkers = $blocked
    }
}

function Repair-AutomaticOwnerV2Intents {
    param(
        [Parameter(Mandatory)][string]$DeliveryRoot,
        [Parameter(Mandatory)][byte[]]$Key,
        [Parameter(Mandatory)][scriptblock]$Provider,
        [Parameter(Mandatory)]$Evidence
    )
    $events = [Collections.Generic.List[object]]::new()
    $namedAreEqual =
        [string]$Evidence.Declaration.capability.id -ceq
            $script:AutomaticNamedAreEqualCapability
    $intentRoot = Join-Path $DeliveryRoot "intents\$($Evidence.Identity)"
    $outcomeRoot = Join-Path $DeliveryRoot "outcomes\$($Evidence.Identity)"
    foreach ($file in @(Get-ChildItem -LiteralPath $intentRoot `
                -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $intentEvents = [Collections.Generic.List[object]]::new()
        $outcomePath = Join-Path $outcomeRoot $file.Name
        if (Test-Path -LiteralPath $outcomePath -PathType Leaf) {
            [void](Read-ApprovedOwnerV2SignedRecord -Path $outcomePath -Key $Key)
            continue
        }
        $intent = Read-ApprovedOwnerV2SignedRecord -Path $file.FullName -Key $Key
        $expectedIntentKind = if ($namedAreEqual) {
            'named-areequal-v2-service-create-intent'
        } else { 'owner-v2-service-create-intent' }
        if ([string]$intent.kind -cne $expectedIntentKind -or
            [string]$intent.state.identity -cne [string]$Evidence.Identity) {
            throw "Automatic Owner intent '$($file.FullName)' is foreign."
        }
        $live = Invoke-AutomaticOwnerV2Read -Provider $Provider -Arguments @{
            evidence = $Evidence
            operator = $intent.reviewerIdentity
            selections = @($intent.selections)
        }
        $recovered = 0
        $ambiguous = 0
        foreach ($selection in @($intent.selections)) {
            $entry = $null
            try {
                $entry = Get-AutomaticOwnerV2ConfirmedEntry `
                    -Snapshot $live.Snapshot -Selection $selection `
                    -NamedAreEqual:$namedAreEqual `
                    -SourceCommit ([string]$Evidence.Declaration.head.sourceCommit)
                if ($namedAreEqual -and $null -ne $entry) {
                    $approval = [ordered]@{
                        subject = $intent.subject
                        provider = $Evidence.Provider
                        operator = $intent.reviewerIdentity
                    }
                    if ([int]$live.Snapshot.CurrentIterationId -ne
                        [int]$intent.currentIterationId) {
                        throw 'Interrupted create belongs to an older iteration.'
                    }
                    $readback = Assert-ApprovedOwnerV2LiveRead `
                        -Evidence $Evidence -Approval $approval -Live $live `
                        -Selections @($selection) `
                        -ExpectedSnapshotSha256 (
                            ([string]$live.Snapshot.Digest).Substring(10)) `
                        -Delivery named-areequal
                    if ([string]$readback.Classifications[
                            [string]$selection.findingId] -cne 'noOp') {
                        throw 'Interrupted create has no current exact readback.'
                    }
                }
            }
            catch { $entry = $null }
            if ($null -ne $entry) {
                $recovered++
                $event = New-AutomaticOwnerV2Event `
                    -RunId ([string]$intent.runId) -Evidence $Evidence `
                    -Selection $selection -Action create `
                    -Outcome recovered-confirmed -RunHealth partial `
                    -ThreadId ([long]$entry.Thread.threadId) `
                    -CommentId ([long]$entry.Comment.commentId) `
                    -Url (Get-AutomaticOwnerV2CommentUrl `
                        -Provider $Evidence.Provider `
                        -PullRequestId ([long]$intent.subject.pullRequestId) `
                        -ThreadId ([long]$entry.Thread.threadId)
                    ) -ProviderWriteCount 1 -ProviderWriteState confirmed
            }
            else {
                $ambiguous++
                $event = New-AutomaticOwnerV2Event `
                    -RunId ([string]$intent.runId) -Evidence $Evidence `
                    -Selection $selection -Action create `
                    -Outcome ambiguous-post-write -RunHealth refused `
                    -ProviderWriteCount 1 -ProviderWriteState unknown `
                    -Diagnostic (Get-AutomaticOwnerV2Diagnostic `
                        -Code 'interrupted-intent' `
                        -Message 'Interrupted create intent requires incident review.')
            }
            [void](Write-AutomaticOwnerV2Event -DeliveryRoot $DeliveryRoot `
                    -Event $event -Key $Key)
            [void]$intentEvents.Add($event)
            [void]$events.Add($event)
        }
        $outcome = [ordered]@{
            schemaVersion = 1
            kind = $(if ($namedAreEqual) {
                    'named-areequal-v2-service-create-outcome'
                } else { 'owner-v2-service-create-outcome' })
            runId = [string]$intent.runId
            stateIdentity = [string]$Evidence.Identity
            status = $(if ($ambiguous -gt 0) {
                    'operator-review-required'
                }
                else { 'recovered-confirmed' })
            providerWrites = 'unknown'
            recoveryProviderWrites = 0
            confirmedFromReadback = $recovered
            ambiguous = $ambiguous
            eventIds = @($intentEvents.ToArray() | ForEach-Object {
                    [string](Get-ApprovedOwnerV2Value $_ 'eventId' '')
                })
            createdUtc = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
        }
        [void](Write-ApprovedOwnerV2SignedRecord -Path $outcomePath `
                -Payload $outcome -Key $Key)
    }
    return $events.ToArray()
}

function Invoke-AutomaticOwnerV2Comments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][Collections.IDictionary]$Policy,
        [Parameter(Mandatory)][string]$DeliveryRoot,
        [Parameter(Mandatory)][byte[]]$Key,
        [Parameter(Mandatory)][scriptblock]$Provider,
        [ValidateRange(0, 5)][int]$MaximumCreates = 5
    )
    $runId = [guid]::NewGuid().ToString('N')
    $namedAreEqual =
        [string]$Evidence.Declaration.capability.id -ceq
            $script:AutomaticNamedAreEqualCapability
    $resultKind = if ($namedAreEqual) {
        'named-areequal-v2-automatic-delivery-result'
    } else { 'owner-v2-automatic-delivery-result' }
    $events = [Collections.Generic.List[object]]::new()
    $repaired = @()
    $writes = 0
    $intentPath = $null
    $outcomePath = $null
    if ($namedAreEqual -and
        (Split-Path -Leaf ([IO.Path]::GetFullPath($DeliveryRoot))) -cne
            $script:AutomaticNamedAreEqualRoot) {
        throw 'Named AreEqual requires its separate private delivery root.'
    }
    $lockPath = Join-Path $DeliveryRoot 'locks\delivery.lock'
    $lock = [IO.File]::Open(
        $lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None)
    try {
        try {
            Assert-AutomaticOwnerV2ServicePolicy `
                -Evidence $Evidence -Policy $Policy
        }
        catch {
            return [pscustomobject][ordered]@{
                schemaVersion = 1
                kind = $resultKind
                runId = $runId
                health = 'refused'
                providerWrites = 0
                modelWrites = 0
                remainingWouldCreate = @($Evidence.Observation.findings |
                    Where-Object {
                        [string]$_.reconciliation.classification -ceq 'wouldCreate'
                    }).Count
                events = @()
                diagnostic = Get-AutomaticOwnerV2Diagnostic `
                    -Code 'policy-refused' `
                    -Message 'Service policy did not match the completed observation.'
            }
        }

        $repaired = @(Repair-AutomaticOwnerV2Intents `
                -DeliveryRoot $DeliveryRoot -Key $Key -Provider $Provider `
                -Evidence $Evidence)
        $history = Get-AutomaticOwnerV2DeliveryHistory `
            -DeliveryRoot $DeliveryRoot -Key $Key -Evidence $Evidence
        $prRemaining = if ($history.BlockedMarkers.Count -gt 0) {
            0
        }
        else {
            [int]$Policy.limits.maxCreatesPerPullRequest -
                $history.CreatedMarkers.Count
        }
        $runLimit = Get-AutomaticOwnerV2RunLimit `
            -PolicyMaximum ([int]$Policy.limits.maxCreatesPerRun) `
            -RequestedMaximum $MaximumCreates
        $available = [Math]::Max(0, [Math]::Min($runLimit, $prRemaining))

        try {
            if ($namedAreEqual) {
                $historical = @($Evidence.Observation.findings | Where-Object {
                        [string]$_.reconciliation.classification -ceq
                            'unknown' -and
                        [string]$_.reconciliation.reason -ceq
                            'historical-human-review-needs-review'
                    })
                if ($historical.Count -gt 0) {
                    foreach ($finding in $historical) {
                        $marker = Get-NamedAreEqualMarkerKey `
                            -Contract $Evidence.Contract -Finding $finding
                        $body = Format-NamedAreEqualComment `
                            -Contract $Evidence.Contract -Finding $finding `
                            -MarkerKey $marker
                        $selection = [ordered]@{
                            findingId = [string]$finding.identity
                            marker = $marker
                            bodySha256 =
                                Get-ApprovedOwnerV2TextSha256 $body
                            path = [string]$finding.anchor.path
                            line = [int]$finding.anchor.line
                            symbol = [string]$finding.anchor.symbol
                        }
                        $event = New-AutomaticOwnerV2Event `
                            -RunId $runId -Evidence $Evidence `
                            -Selection $selection -Action none `
                            -Outcome refused -RunHealth refused `
                            -ThreadId $(if (
                                [string]$finding.reconciliation.thread.
                                    availability -ceq 'available') {
                                    [long]$finding.reconciliation.thread.threadId
                                } else { 0 }) `
                            -Diagnostic (Get-AutomaticOwnerV2Diagnostic `
                                -Code 'historical-human-review-needs-review' `
                                -Message 'Historical human review requires operator review before automatic delivery.')
                        [void](Write-AutomaticOwnerV2Event `
                            -DeliveryRoot $DeliveryRoot -Event $event -Key $Key)
                        [void]$events.Add($event)
                    }
                    return [pscustomobject][ordered]@{
                        schemaVersion = 1
                        kind = $resultKind
                        runId = $runId
                        health = 'refused'
                        providerWrites = 0
                        modelWrites = 0
                        remainingWouldCreate = 0
                        events = @($repaired + $events.ToArray())
                        diagnostic = Get-AutomaticOwnerV2Diagnostic `
                            -Code 'historical-human-review-needs-review' `
                            -Message 'Historical human review blocked automatic delivery.'
                    }
                }
                $proposals = @($Evidence.Observation.findings |
                    Where-Object {
                        [string]$_.reconciliation.classification -cin @(
                            'wouldCreate', 'noOp', 'humanCovered')
                    } | ForEach-Object {
                        Get-ApprovedOwnerV2Proposal `
                            -Evidence $Evidence -Finding $_ `
                            -Delivery named-areequal
                    } | Sort-Object findingId)
                $review = [pscustomobject]@{ proposals = $proposals }
            }
            else {
                $review = New-ApprovedOwnerV2ReviewPackage -Evidence $Evidence
            }
        }
        catch {
            return [pscustomobject][ordered]@{
                schemaVersion = 1
                kind = $resultKind
                runId = $runId
                health = 'refused'
                providerWrites = 0
                modelWrites = 0
                remainingWouldCreate = 0
                events = @($repaired + $events.ToArray())
                diagnostic = Get-AutomaticOwnerV2Diagnostic `
                    -Code 'finding-contract-refused' `
                    -Message 'Observation contains an ineligible Owner finding.'
            }
        }
        if ($namedAreEqual -and @($review.proposals | Where-Object {
                    [string]$_.classification -ceq 'humanCovered'
                }).Count -gt 0) {
            return [pscustomobject][ordered]@{
                schemaVersion = 1
                kind = $resultKind
                runId = $runId
                health = 'refused'
                providerWrites = 0
                modelWrites = 0
                remainingWouldCreate = @($review.proposals | Where-Object {
                        [string]$_.classification -ceq 'wouldCreate'
                    }).Count
                events = @($repaired + $events.ToArray())
                diagnostic = Get-AutomaticOwnerV2Diagnostic `
                    -Code 'current-human-review-covers-method' `
                    -Message 'Current human review blocks automatic delivery for this method.'
            }
        }
        if (@($review.proposals | Where-Object {
                    [string]$_.classification -ceq 'wouldUpdate'
                }).Count -gt 0) {
            return [pscustomobject][ordered]@{
                schemaVersion = 1
                kind = $resultKind
                runId = $runId
                health = 'refused'
                providerWrites = 0
                modelWrites = 0
                remainingWouldCreate = 0
                events = @($repaired + $events.ToArray())
                diagnostic = Get-AutomaticOwnerV2Diagnostic `
                    -Code 'update-not-authorized' `
                    -Message 'Automatic Owner authority never permits updates.'
            }
        }
        $allCreate = @($review.proposals | Where-Object {
                [string]$_.classification -ceq 'wouldCreate'
            } | Sort-Object findingId)
        $candidates = @($allCreate | Where-Object {
                -not $history.CreatedMarkers.Contains([string]$_.marker) -and
                -not $history.BlockedMarkers.Contains([string]$_.marker)
            })
        $selections = @($candidates | Select-Object -First $available)
        if ($selections.Count -eq 0) {
            $accounted = @($allCreate | Where-Object {
                    $history.CreatedMarkers.Contains([string]$_.marker)
                }).Count
            $health = if ($allCreate.Count -eq 0 -or
                $accounted -eq $allCreate.Count) {
                'healthy'
            }
            elseif ($history.BlockedMarkers.Count -gt 0 -or $prRemaining -le 0) {
                'refused'
            }
            else { 'partial' }
            return [pscustomobject][ordered]@{
                schemaVersion = 1
                kind = $resultKind
                runId = $runId
                health = $health
                providerWrites = 0
                modelWrites = 0
                remainingWouldCreate = $candidates.Count
                events = @($repaired + $events.ToArray())
                diagnostic = $(if ($health -ceq 'refused') {
                        Get-AutomaticOwnerV2Diagnostic `
                            -Code 'delivery-ceiling-or-block' `
                            -Message 'Per-PR ceiling or ambiguous-write block refused delivery.'
                    }
                    else { $null })
            }
        }

        $authorization = [ordered]@{
            subject = [ordered]@{
                projectId = [string]$Evidence.Declaration.subject.projectId
                repositoryId = [string]$Evidence.Declaration.subject.repositoryId
                pullRequestId = [long]$Evidence.Declaration.subject.pullRequestId
                sourceCommit = [string]$Evidence.Declaration.head.sourceCommit
                targetCommit = [string]$Evidence.Declaration.target.targetCommit
                targetRef = [string]$Evidence.Declaration.target.targetRef
            }
            provider = $Evidence.Provider
            operator = [ordered]@{
                id = [string]$Evidence.Provider.reviewerIdentity.id
                descriptor = [string]$Evidence.Provider.reviewerIdentity.descriptor
                uniqueName = [string]$Evidence.Provider.reviewerIdentity.uniqueName
            }
        }
        try {
            $initial = Invoke-AutomaticOwnerV2Read -Provider $Provider -Arguments @{
                evidence = $Evidence
                operator = $authorization.operator
                selections = $selections
            }
            $snapshot = Get-ApprovedOwnerV2SourceArtifact `
                -Observation $Evidence.Observation `
                -Kind 'owner-v2-discussion-snapshot'
            $liveState = Assert-ApprovedOwnerV2LiveRead `
                -Evidence $Evidence -Approval $authorization -Live $initial `
                -Selections $selections -ExpectedSnapshotSha256 $snapshot `
                -Delivery $(if ($namedAreEqual) {
                    'named-areequal'
                } else { 'owner' })
            if ($namedAreEqual -and @($selections | Where-Object {
                        [string]$liveState.Classifications[
                            [string]$_.findingId] -cnotin @(
                                'wouldCreate', 'noOp')
                    }).Count -gt 0) {
                throw 'Named AreEqual live classification is not create-only eligible.'
            }
            $iterationId = [int]$initial.Snapshot.CurrentIterationId
            if ($iterationId -lt 1) {
                throw 'Current pull request iteration is missing.'
            }
        }
        catch {
            return [pscustomobject][ordered]@{
                schemaVersion = 1
                kind = $resultKind
                runId = $runId
                health = 'refused'
                providerWrites = 0
                modelWrites = 0
                remainingWouldCreate = $candidates.Count
                events = @($repaired + $events.ToArray())
                diagnostic = Get-AutomaticOwnerV2Diagnostic `
                    -Code 'live-preflight-refused' `
                    -Message 'Live PR, identity, anchor, source, or discussion drifted.'
            }
        }

        $intentState = [ordered]@{
            identity = [string]$Evidence.Identity
            resultDigest = [string]$Evidence.Record.resultDigest
            declarationSha256 =
                Get-ApprovedOwnerV2FileSha256 $Evidence.Paths.declaration
            evidenceSha256 =
                Get-ApprovedOwnerV2FileSha256 $Evidence.Paths.evidence
            recordSha256 =
                Get-ApprovedOwnerV2FileSha256 $Evidence.Paths.record
            observationSha256 =
                Get-ApprovedOwnerV2FileSha256 $Evidence.Paths.observation
            telemetrySha256 = $(if ($namedAreEqual) {
                    'not-applicable'
                }
                else {
                    Get-ApprovedOwnerV2FileSha256 $Evidence.Paths.telemetry
                })
        }
        if ($namedAreEqual) {
            $intentState['parserSha256'] =
                Get-ApprovedOwnerV2FileSha256 $Evidence.Paths.parser
            $intentState['parserManifestSha256'] =
                Get-ApprovedOwnerV2FileSha256 `
                    $Evidence.Paths.parserManifest
        }
        $intent = [ordered]@{
            schemaVersion = 1
            kind = $(if ($namedAreEqual) {
                    'named-areequal-v2-service-create-intent'
                } else { 'owner-v2-service-create-intent' })
            runId = $runId
            policyDigest = Get-ApprovedOwnerV2Digest $Policy
            state = $intentState
            subject = $authorization.subject
            currentIterationId = $iterationId
            discussionSnapshotSha256 = $snapshot
            rule = $Evidence.Declaration.rule
            capability = $Evidence.Declaration.capability
            reviewerIdentity = $authorization.operator
            implementation = $Policy.implementation
            selections = $selections
            createdUtc = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
        }
        $intentPath = Write-ApprovedOwnerV2SignedRecord -Path (
            Join-Path $DeliveryRoot "intents\$($Evidence.Identity)\$runId.json"
        ) -Payload $intent -Key $Key

        $expectedSnapshot = $snapshot
        $status = 'completed'
        $diagnostic = $null
        foreach ($selection in $selections) {
            try {
                Assert-AutomaticOwnerV2EvidenceCurrent `
                    -Evidence $Evidence -Intent $intent
                $fresh = Invoke-AutomaticOwnerV2Read `
                    -Provider $Provider -Arguments @{
                    evidence = $Evidence
                    operator = $authorization.operator
                    selections = @($selection)
                }
                if ([int]$fresh.Snapshot.CurrentIterationId -ne $iterationId) {
                    throw 'Current pull request iteration changed.'
                }
                $freshState = Assert-ApprovedOwnerV2LiveRead `
                    -Evidence $Evidence -Approval $authorization -Live $fresh `
                    -Selections @($selection) `
                    -ExpectedSnapshotSha256 $expectedSnapshot `
                    -Delivery $(if ($namedAreEqual) {
                        'named-areequal'
                    } else { 'owner' })
                Assert-AutomaticOwnerV2EvidenceCurrent `
                    -Evidence $Evidence -Intent $intent
                $classification = [string]$freshState.Classifications[
                    [string]$selection.findingId]
                if ($classification -ceq 'noOp') {
                    $event = New-AutomaticOwnerV2Event -RunId $runId `
                        -Evidence $Evidence -Selection $selection -Action none `
                        -Outcome noOp -RunHealth healthy
                    [void](Write-AutomaticOwnerV2Event `
                            -DeliveryRoot $DeliveryRoot -Event $event -Key $Key)
                    [void]$events.Add($event)
                    continue
                }
                if ($classification -cne 'wouldCreate') {
                    throw 'Live classification is not create-only eligible.'
                }
                $anchor = @($freshState.Anchors | Where-Object {
                        [string]$_.path -ieq [string]$selection.path -and
                        [int]$selection.line -ge [int]$_.startLine -and
                        [int]$selection.line -le [int]$_.endLine
                    })[0]
                $writeError = $null
                $writeCounted = $false
                try {
                    & $Provider 'CreateThread' @{
                        evidence = $Evidence
                        operator = $authorization.operator
                        selection = $selection
                        anchor = $anchor
                    } | Out-Null
                    $writes++
                    $writeCounted = $true
                }
                catch { $writeError = $_ }

                try {
                    $confirmed = Invoke-AutomaticOwnerV2Read `
                        -Provider $Provider -Arguments @{
                        evidence = $Evidence
                        operator = $authorization.operator
                        selections = @($selection)
                    }
                }
                catch {
                    if (-not $writeCounted) {
                        $writes++
                        $writeCounted = $true
                    }
                    $event = New-AutomaticOwnerV2Event -RunId $runId `
                        -Evidence $Evidence -Selection $selection -Action create `
                        -Outcome ambiguous-post-write -RunHealth refused `
                        -ProviderWriteCount 1 -ProviderWriteState unknown `
                        -Diagnostic (Get-AutomaticOwnerV2Diagnostic `
                            -Code 'readback-unavailable' `
                            -Message 'Create readback was unavailable; automatic retry is blocked.')
                    [void](Write-AutomaticOwnerV2Event `
                            -DeliveryRoot $DeliveryRoot -Event $event -Key $Key)
                    [void]$events.Add($event)
                    $status = 'operator-review-required'
                    $diagnostic = $event.diagnostic
                    break
                }
                $entry = $null
                try {
                    $entry = Get-AutomaticOwnerV2ConfirmedEntry `
                        -Snapshot $confirmed.Snapshot -Selection $selection `
                        -NamedAreEqual:$namedAreEqual `
                        -SourceCommit ([string]$Evidence.Declaration.head.sourceCommit)
                }
                catch { $entry = $null }
                if ($null -eq $entry) {
                    if (-not $writeCounted) {
                        $writes++
                        $writeCounted = $true
                    }
                    $event = New-AutomaticOwnerV2Event -RunId $runId `
                        -Evidence $Evidence -Selection $selection -Action create `
                        -Outcome ambiguous-post-write -RunHealth refused `
                        -ProviderWriteCount 1 -ProviderWriteState unknown `
                        -Diagnostic (Get-AutomaticOwnerV2Diagnostic `
                            -Code 'readback-unconfirmed' `
                            -Message 'Create result was not confirmed; automatic retry is blocked.')
                    [void](Write-AutomaticOwnerV2Event `
                            -DeliveryRoot $DeliveryRoot -Event $event -Key $Key)
                    [void]$events.Add($event)
                    $status = 'operator-review-required'
                    $diagnostic = $event.diagnostic
                    break
                }
                $expectedSnapshot = ([string]$confirmed.Snapshot.Digest).Substring(10)
                $outcome = if ($null -ne $writeError) {
                    'created-confirmed-after-error'
                }
                else { 'created' }
                if (-not $writeCounted) {
                    $writes++
                    $writeCounted = $true
                }
                $event = New-AutomaticOwnerV2Event -RunId $runId `
                    -Evidence $Evidence -Selection $selection -Action create `
                    -Outcome $outcome -RunHealth healthy `
                    -ThreadId ([long]$entry.Thread.threadId) `
                    -CommentId ([long]$entry.Comment.commentId) `
                    -Url (Get-AutomaticOwnerV2CommentUrl `
                        -Provider $Evidence.Provider `
                        -PullRequestId ([long]$authorization.subject.pullRequestId) `
                        -ThreadId ([long]$entry.Thread.threadId)
                    ) -ProviderWriteCount 1 -ProviderWriteState confirmed
                [void](Write-AutomaticOwnerV2Event `
                        -DeliveryRoot $DeliveryRoot -Event $event -Key $Key)
                [void]$events.Add($event)
                $liveState = $freshState
                Start-Sleep -Milliseconds 100
            }
            catch {
                $event = New-AutomaticOwnerV2Event -RunId $runId `
                    -Evidence $Evidence -Selection $selection -Action create `
                    -Outcome refused -RunHealth partial `
                    -Diagnostic (Get-AutomaticOwnerV2Diagnostic `
                        -Code 'pre-write-refused' `
                        -Message 'Pre-write state drifted; finding remains actionable.')
                [void](Write-AutomaticOwnerV2Event `
                        -DeliveryRoot $DeliveryRoot -Event $event -Key $Key)
                [void]$events.Add($event)
                $status = 'partial'
                $diagnostic = $event.diagnostic
                break
            }
        }
        $remaining = [Math]::Max(0, $candidates.Count - @(
                $events.ToArray() | Where-Object {
                    [string](Get-ApprovedOwnerV2Value $_ 'outcome' '') -cin @(
                        'created', 'created-confirmed-after-error', 'noOp'
                    )
                }).Count)
        if ($status -ceq 'completed' -and $remaining -gt 0) {
            $status = 'partial'
        }
        $outcomeRecord = [ordered]@{
            schemaVersion = 1
            kind = $(if ($namedAreEqual) {
                    'named-areequal-v2-service-create-outcome'
                } else { 'owner-v2-service-create-outcome' })
            runId = $runId
            stateIdentity = [string]$Evidence.Identity
            status = $status
            providerWrites = $(if ($status -ceq 'operator-review-required') {
                    'unknown'
                }
                else { $writes })
            providerWritesConservative = $writes
            modelWrites = 0
            eventIds = @($events.ToArray() | ForEach-Object {
                    [string](Get-ApprovedOwnerV2Value $_ 'eventId' '')
                })
            remainingWouldCreate = $remaining
            diagnostic = $diagnostic
            createdUtc = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
        }
        $outcomePath = Write-ApprovedOwnerV2SignedRecord -Path (
            Join-Path $DeliveryRoot "outcomes\$($Evidence.Identity)\$runId.json"
        ) -Payload $outcomeRecord -Key $Key
        return [pscustomobject][ordered]@{
            schemaVersion = 1
            kind = $resultKind
            runId = $runId
            health = $(if ($status -ceq 'completed') { 'healthy' }
                elseif ($status -ceq 'operator-review-required') { 'refused' }
                else { 'partial' })
            providerWrites = $writes
            modelWrites = 0
            remainingWouldCreate = $remaining
            intentPath = $intentPath
            outcomePath = $outcomePath
            events = @($repaired + $events.ToArray())
            diagnostic = $diagnostic
        }
    }
    finally { $lock.Dispose() }
}
