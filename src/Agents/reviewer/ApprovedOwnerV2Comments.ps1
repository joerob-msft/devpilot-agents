#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1')

$script:ApprovedOwnerV2SchemaVersion = 1
$script:ApprovedOwnerV2Capability = 'bpm-test-ownership@1'
$script:ApprovedOwnerV2MarkerPattern =
    '<!--\s*devpilot-owner-comment:v1:([0-9a-f]{64})\s*-->'
$script:ApprovedOwnerV2MaximumSelections = 5

function Get-ApprovedOwnerV2Value {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )
    if ($Value -is [Collections.IDictionary]) {
        if ($Value.Contains($Name)) { return $Value[$Name] }
        return $Default
    }
    if ($null -ne $Value) {
        $property = $Value.PSObject.Properties[$Name]
        if ($null -ne $property) { return $property.Value }
    }
    return $Default
}

function Get-ApprovedOwnerV2Sha256 {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return ([Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($Bytes))).ToLowerInvariant()
}

function Get-ApprovedOwnerV2TextSha256 {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return Get-ApprovedOwnerV2Sha256 -Bytes (
        [Text.UTF8Encoding]::new($false).GetBytes($Text))
}

function Get-ApprovedOwnerV2FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return Get-ApprovedOwnerV2Sha256 -Bytes ([IO.File]::ReadAllBytes($Path))
}

function ConvertTo-ApprovedOwnerV2CanonicalJson {
    param([Parameter(Mandatory)][AllowNull()][object]$Value)
    return ConvertTo-AgentCanonicalJson -InputObject $Value
}

function Get-ApprovedOwnerV2Digest {
    param([Parameter(Mandatory)][AllowNull()][object]$Value)
    return 'v1:sha256:' + (Get-AgentCanonicalDigest -InputObject $Value)
}

function Read-ApprovedOwnerV2Json {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required Owner v2 artifact '$Path' does not exist."
    }
    return Get-Content -LiteralPath $Path -Raw |
        ConvertFrom-Json -AsHashtable -Depth 64
}

function Assert-ApprovedOwnerV2ExactKeys {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Value,
        [Parameter(Mandatory)][string[]]$Expected,
        [Parameter(Mandatory)][string]$Name
    )
    $actual = @($Value.Keys | ForEach-Object { [string]$_ } |
            Sort-Object -CaseSensitive)
    $wanted = @($Expected | Sort-Object -CaseSensitive)
    if ($actual.Count -ne $wanted.Count -or
        ($actual -join "`n") -cne ($wanted -join "`n")) {
        throw "$Name must contain exactly: $($Expected -join ', ')."
    }
}

function Get-ApprovedOwnerV2CapabilityRoot {
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$CapabilityId,
        [Parameter(Mandatory)][string]$CapabilityDigest
    )
    $safe = ($CapabilityId.ToLowerInvariant() -replace '[^a-z0-9_.-]+', '-').Trim('-')
    if ($safe.Length -gt 48) { $safe = $safe.Substring(0, 48).Trim('-') }
    $leaf = "$safe-$($CapabilityDigest.Substring($CapabilityDigest.Length - 64, 12))"
    return Join-Path $StateRoot (
        "owner-v2-preview-state\schema-1\capabilities\$leaf")
}

function New-ApprovedOwnerV2Contract {
    param([Parameter(Mandatory)][Collections.IDictionary]$Declaration)
    $limits = New-OwnerAdapterLimits -MaximumFiles 64 -MaximumBytes 16777216 `
        -MaximumReads 128
    return New-OwnerAcquisitionContract `
        -RepositoryId ([string]$Declaration.subject.repositoryId) `
        -ProjectId ([string]$Declaration.subject.projectId) `
        -PullRequestId ([long]$Declaration.subject.pullRequestId) `
        -SourceCommit ([string]$Declaration.head.sourceCommit) `
        -TargetCommit ([string]$Declaration.target.targetCommit) `
        -TargetRef ([string]$Declaration.target.targetRef) `
        -RuleRepositoryId ([string]$Declaration.rule.repositoryId) `
        -RulePath ([string]$Declaration.rule.path) `
        -RuleCommit ([string]$Declaration.rule.commit) `
        -RuleSection ([string]$Declaration.rule.section) `
        -RuleHash ([string]$Declaration.rule.hash) `
        -RuleLength ([long]$Declaration.rule.length) `
        -ConfigId ([string]$Declaration.config.id) `
        -ConfigDigest ([string]$Declaration.config.digest) `
        -CapabilityId ([string]$Declaration.capability.id) `
        -CapabilityDigest ([string]$Declaration.capability.digest) `
        -Limits $limits
}

function Assert-ApprovedOwnerV2Record {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Record,
        [Parameter(Mandatory)][Collections.IDictionary]$Declaration,
        [Parameter(Mandatory)][string]$Identity,
        [Parameter(Mandatory)][Collections.IDictionary]$Observation
    )
    $expected = @(
        'schemaVersion', 'kind', 'identity', 'stateDigest', 'mode', 'capabilityId',
        'capabilityDigest', 'subjectDigest', 'headDigest', 'ruleDigest', 'modelDigest',
        'configDigest', 'acquisitionPayloadDigest', 'state', 'attempts', 'maxAttempts',
        'lease', 'createdUtc', 'updatedUtc', 'declarationPath', 'evidencePath',
        'observationPath', 'resultDigest', 'incompleteReason'
    )
    if ([int]$Record.schemaVersion -eq 2) { $expected += 'modelExecutionState' }
    Assert-ApprovedOwnerV2ExactKeys -Value $Record -Expected $expected -Name record
    if ([int]$Record.schemaVersion -notin @(1, 2) -or
        [string]$Record.kind -cne 'owner-v2-preview-record' -or
        [string]$Record.identity -cne $Identity -or
        [string]$Record.state -cne 'completed' -or
        $null -ne $Record.lease -or [string]$Record.incompleteReason -cne 'unknown') {
        throw 'Owner v2 record is not one exact completed record.'
    }
    if ([int]$Record.schemaVersion -eq 2 -and
        [string]$Record.modelExecutionState -cne 'attempted') {
        throw 'Completed Owner v2 record has an unexpected model execution state.'
    }
    $bindings = [ordered]@{
        identity = $Identity
        stateDigest = [string]$Declaration.stateDigest
        mode = [string]$Declaration.mode
        capabilityId = [string]$Declaration.capability.id
        capabilityDigest = [string]$Declaration.capability.digest
        subjectDigest = Get-ApprovedOwnerV2Digest $Declaration.subject
        headDigest = Get-ApprovedOwnerV2Digest $Declaration.head
        ruleDigest = Get-ApprovedOwnerV2Digest $Declaration.rule
        modelDigest = Get-ApprovedOwnerV2Digest $Declaration.model
        configDigest = Get-ApprovedOwnerV2Digest $Declaration.config
        acquisitionPayloadDigest = [string]$Declaration.acquisitionPayloadDigest
    }
    foreach ($entry in $bindings.GetEnumerator()) {
        if ([string]$Record[$entry.Key] -cne [string]$entry.Value) {
            throw "Owner v2 record binding '$($entry.Key)' is stale or foreign."
        }
    }
    if ([string]$Record.resultDigest -cne
        (Get-ApprovedOwnerV2Digest -Value $Observation)) {
        throw 'Owner v2 observation no longer matches the completed result digest.'
    }
}

function Get-ApprovedOwnerV2SourceArtifact {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Observation,
        [Parameter(Mandatory)][string]$Kind
    )
    $artifacts = @($Observation.sourceArtifacts | Where-Object {
            [string](Get-ApprovedOwnerV2Value $_ 'kind' '') -ceq $Kind
        })
    if ($artifacts.Count -ne 1 -or
        [string](Get-ApprovedOwnerV2Value $artifacts[0] 'sha256' '') -cnotmatch
        '^[0-9a-f]{64}$') {
        throw "Owner v2 observation requires one exact '$Kind' source artifact."
    }
    return [string](Get-ApprovedOwnerV2Value $artifacts[0] 'sha256' '')
}

function Get-ApprovedOwnerV2SourceArtifacts {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Observation,
        [Parameter(Mandatory)][string]$Kind
    )
    $values = @($Observation.sourceArtifacts | Where-Object {
            [string](Get-ApprovedOwnerV2Value $_ 'kind' '') -ceq $Kind
        } | ForEach-Object {
            [string](Get-ApprovedOwnerV2Value $_ 'sha256' '')
        })
    if ($values.Count -lt 1 -or
        @($values | Where-Object { $_ -cnotmatch '^[0-9a-f]{64}$' }).Count -gt 0 -or
        @($values | Sort-Object -Unique).Count -ne $values.Count) {
        throw "Owner v2 observation requires bounded unique '$Kind' source artifacts."
    }
    return @($values | Sort-Object)
}

function Read-ApprovedOwnerV2Evidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$Identity,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ToolkitConfigPath
    )
    $state = [IO.Path]::GetFullPath($StateRoot)
    $toolkitConfig = Read-ApprovedOwnerV2Json -Path $ToolkitConfigPath
    $capability = $toolkitConfig.capability
    if ($capability -isnot [Collections.IDictionary] -or
        [string]$capability.id -cne $script:ApprovedOwnerV2Capability -or
        [string]$capability.implementationSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Toolkit config has no exact Owner v2 capability binding.'
    }
    $subjectProvider = $toolkitConfig.subjectProvider
    $discussionProvider = $toolkitConfig.discussionProvider
    $configuredReviewer = Get-ApprovedOwnerV2Value $discussionProvider `
        'reviewerIdentity'
    if ($subjectProvider -isnot [Collections.IDictionary] -or
        [string]$subjectProvider.kind -cne 'azure-devops-read-only-v1' -or
        $discussionProvider -isnot [Collections.IDictionary] -or
        [string]$discussionProvider.kind -cne
        'azure-devops-rest-owner-discussions-v1' -or
        $configuredReviewer -isnot [Collections.IDictionary]) {
        throw 'Toolkit config has no exact Azure DevOps Owner provider binding.'
    }
    $reviewerIdentity = New-OwnerAzureDevOpsReviewerIdentity `
        -Id ([string]$configuredReviewer.id) `
        -Descriptor ([string]$configuredReviewer.descriptor) `
        -UniqueName ([string]$configuredReviewer.uniqueName)
    $identityAdapter = New-OwnerAzureDevOpsReadOnlyProviderAdapter `
        -Name 'approved-owner-v2-config-validation' `
        -ReviewerIdentity $reviewerIdentity -Handler { throw 'not invoked' }
    if ([string]$discussionProvider.mappingDigest -cne
        [string]$identityAdapter.AzureDevOpsDiscussionMappingDigest -or
        [string]$configuredReviewer.digest -cne
        [string]$identityAdapter.AzureDevOpsReviewerIdentityDigest) {
        throw 'Toolkit config discussion mapping or reviewer identity digest is invalid.'
    }
    $capabilityDigest = 'v1:sha256:' + [string]$capability.implementationSha256
    $root = Get-ApprovedOwnerV2CapabilityRoot -StateRoot $state `
        -CapabilityId ([string]$capability.id) -CapabilityDigest $capabilityDigest
    $declarationPath = Join-Path $root "declarations\$Identity.json"
    $evidencePath = Join-Path $root "evidence\$Identity.json"
    $recordPath = Join-Path $root "records\$Identity.json"
    $observationPath = Join-Path $root "observations\$Identity.json"
    $telemetryPath = Join-Path $root "telemetry\$Identity.json"
    $declaration = Read-ApprovedOwnerV2Json $declarationPath
    $pin = Read-ApprovedOwnerV2Json $evidencePath
    $record = Read-ApprovedOwnerV2Json $recordPath
    $observation = Read-ApprovedOwnerV2Json $observationPath
    $telemetry = Read-ApprovedOwnerV2Json $telemetryPath

    if ([string]$declaration.kind -cne 'owner-v2-preview-declaration' -or
        [string]$declaration.mode -cne 'live' -or
        [string]$declaration.capability.id -cne $script:ApprovedOwnerV2Capability -or
        [string]$declaration.capability.digest -cne $capabilityDigest -or
        [string]$declaration.subject.projectId -cne
        [string]$subjectProvider.projectId -or
        [string]$declaration.subject.repositoryId -cne
        [string]$subjectProvider.repositoryId -or
        [string]$declaration.stateDigest -cne "v1:sha256:$Identity" -or
        [string]$pin.kind -cne 'owner-v2-preview-live-evidence-pin' -or
        [string]$pin.acquisitionPayloadDigest -cne
        [string]$declaration.acquisitionPayloadDigest) {
        throw 'Owner v2 declaration or evidence pin is stale, unsupported, or foreign.'
    }
    if ([int]$observation.schemaVersion -ne 2 -or
        [string]$observation.kind -cne 'owner-observation' -or
        [string]$observation.capability -cne $script:ApprovedOwnerV2Capability -or
        [string]$observation.lifecycle.status -cne 'completed' -or
        -not [bool]$observation.findingsComplete -or
        [int]$observation.counts.unknown -ne 0 -or
        [int]$observation.counts.uncovered -ne 0 -or
        [int]$observation.effects.providerWrites -ne 0 -or
        [int]$observation.effects.writeToolInvocations -ne 0) {
        throw 'Owner v2 observation is not a completed zero-write actionable result.'
    }
    Assert-ApprovedOwnerV2Record -Record $record -Declaration $declaration `
        -Identity $Identity -Observation $observation
    $contract = New-ApprovedOwnerV2Contract -Declaration $declaration
    Set-ApprovedOwnerV2CommentPresentation -Contract $contract `
        -Observation $observation -ToolkitConfig $toolkitConfig
    foreach ($entry in ([ordered]@{
            bindingId = $contract.Binding.BindingId
            subjectKey = $contract.Binding.SubjectKey
            headKey = $contract.Binding.HeadKey
            ruleKey = $contract.Binding.RuleKey
            capabilityKey = $contract.Binding.CapabilityKey
        }).GetEnumerator()) {
        if ([string]$declaration.facadeBinding[$entry.Key] -cne
            [string]$entry.Value) {
            throw "Owner v2 facade binding '$($entry.Key)' is stale or foreign."
        }
    }
    if ([long]$observation.subject.pullRequestId -ne
        [long]$declaration.subject.pullRequestId -or
        [string]$observation.subject.repositoryId -cne
        [string]$declaration.subject.repositoryId -or
        [string]$observation.subject.headCommit -cne
        [string]$declaration.head.sourceCommit -or
        [string]$observation.subject.targetCommit -cne
        [string]$declaration.target.targetCommit -or
        [string]$observation.subject.targetRef -cne
        [string]$declaration.target.targetRef -or
        [string]$observation.rule.commit -cne [string]$declaration.rule.commit -or
        [string]$observation.rule.sha256 -cne
        ([string]$declaration.rule.hash).Substring(10)) {
        throw 'Owner v2 observation subject, target, or rule binding is stale.'
    }
    $toolkit = $toolkitConfig.toolkit
    if ($toolkit -isnot [Collections.IDictionary] -or
        [string]$toolkit.head -cnotmatch '^[0-9a-f]{40}$' -or
        [string]$toolkit.tree -cnotmatch '^[0-9a-f]{40}$') {
        throw 'Toolkit config has no exact toolkit head and tree.'
    }
    return [pscustomobject][ordered]@{
        StateRoot = $state
        CapabilityRoot = $root
        Identity = $Identity
        Declaration = $declaration
        Pin = $pin
        Record = $record
        Observation = $observation
        Telemetry = $telemetry
        Contract = $contract
        Paths = [ordered]@{
            declaration = $declarationPath
            evidence = $evidencePath
            record = $recordPath
            observation = $observationPath
            telemetry = $telemetryPath
            toolkitConfig = [IO.Path]::GetFullPath($ToolkitConfigPath)
        }
        Toolkit = [ordered]@{
            head = [string]$toolkit.head
            tree = [string]$toolkit.tree
            ref = [string]$toolkit.ref
            configSha256 = Get-ApprovedOwnerV2FileSha256 $ToolkitConfigPath
            formatterSha256 = Get-ApprovedOwnerV2FileSha256 (
                Join-Path $RepoRoot 'src\DevPilot.OwnerCapability\DevPilot.OwnerCapability.psm1')
            formatterManifestSha256 = Get-ApprovedOwnerV2FileSha256 (
                Join-Path $RepoRoot 'src\DevPilot.OwnerCapability\DevPilot.OwnerCapability.psd1')
            writerSha256 = Get-ApprovedOwnerV2FileSha256 (
                Join-Path $RepoRoot 'src\Agents\reviewer\ApprovedOwnerV2Comments.ps1')
            providerSha256 = Get-ApprovedOwnerV2FileSha256 (
                Join-Path $RepoRoot `
                    'src\Agents\reviewer\AzureDevOpsOwnerV2CommentProvider.ps1')
            cliSha256 = Get-ApprovedOwnerV2FileSha256 (
                Join-Path $RepoRoot 'tools\Invoke-ApprovedOwnerV2Comment.ps1')
            automaticWriterSha256 = Get-ApprovedOwnerV2FileSha256 (
                Join-Path $RepoRoot `
                    'src\Agents\reviewer\AutomaticOwnerV2Comments.ps1')
            schedulerSha256 = Get-ApprovedOwnerV2FileSha256 (
                Join-Path $RepoRoot 'tools\Invoke-OwnerV2ScheduledDelivery.ps1')
        }
        Provider = [ordered]@{
            kind = [string]$discussionProvider.kind
            organization = [string]$subjectProvider.organization
            projectName = [string]$subjectProvider.projectName
            projectId = [string]$subjectProvider.projectId
            repositoryId = [string]$subjectProvider.repositoryId
            mappingDigest = [string]$discussionProvider.mappingDigest
            reviewerIdentity = [ordered]@{
                id = [string]$reviewerIdentity.Id
                descriptor = [string]$reviewerIdentity.Descriptor
                uniqueName = [string]$reviewerIdentity.UniqueName
                digest = [string]$identityAdapter.AzureDevOpsReviewerIdentityDigest
            }
        }
    }
}

function Get-ApprovedOwnerV2Proposal {
    param(
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][Collections.IDictionary]$Finding
    )
    if ([string]$Finding.identity -notmatch '^owner-v2:[0-9a-f]{64}$' -or
        [string]$Finding.disposition -cne 'violation' -or
        [string]$Finding.constructRef -notmatch '^construct:[0-9a-f]{64}$' -or
        $Finding.binding -isnot [Collections.IDictionary] -or
        $Finding.anchor -isnot [Collections.IDictionary] -or
        [string]$Finding.binding.constructIdentity -notmatch '^v1:sha256:[0-9a-f]{64}$') {
        throw 'Only exact method-level Owner violation findings are writer eligible.'
    }
    $source = $Finding.binding.source.representation
    if ($source -isnot [Collections.IDictionary] -or
        [string]$source.constructIdentity -cne [string]$Finding.constructRef -or
        [string]$source.path -cne [string]$Finding.anchor.path -or
        [string]$source.symbol -cne [string]$Finding.anchor.symbol -or
        [int]$source.startLine -ne [int]$Finding.anchor.line -or
        [int]$source.endLine -ne [int]$Finding.anchor.line) {
        throw 'Owner finding is not one exact eligible method-level anchor.'
    }
    $classification = [string]$Finding.reconciliation.classification
    if ($classification -cnotin @('wouldCreate', 'wouldUpdate', 'noOp')) {
        throw 'Owner finding is not actionable and cannot enter a review package.'
    }
    $marker = Get-OwnerV1WriterMarkerKey -Contract $Evidence.Contract -Finding $Finding
    $body = Format-OwnerV1WriterComment -Contract $Evidence.Contract `
        -Finding $Finding -MarkerKey $marker
    $bodySha256 = Get-ApprovedOwnerV2TextSha256 $body
    if ([string]$Finding.reconciliation.bodySha256 -cne $bodySha256 -or
        [string]$Finding.providerMarker.integrity -cne 'verified' -or
        [string]$Finding.providerMarker.sha256 -cne
        (Get-ApprovedOwnerV2TextSha256 $marker)) {
        throw "Owner finding '$($Finding.identity)' does not match the exact formatter contract."
    }
    return [ordered]@{
        findingId = [string]$Finding.identity
        semanticKey = [string]$Finding.semanticKey
        constructRef = [string]$Finding.constructRef
        constructIdentity = [string]$Finding.binding.constructIdentity
        path = [string]$Finding.anchor.path
        line = [int]$Finding.anchor.line
        symbol = [string]$Finding.anchor.symbol
        marker = $marker
        markerComment = "<!-- devpilot-owner-comment:v1:$marker -->"
        body = $body
        bodySha256 = $bodySha256
        classification = $classification
        rationale = [string]$Finding.reconciliation.reason
    }
}

function New-ApprovedOwnerV2ReviewPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Evidence)
    $findings = @($Evidence.Observation.findings)
    if ($findings.Count -lt 1 -or
        [int]$Evidence.Observation.counts.violations -ne $findings.Count) {
        throw 'Owner v2 observation findings are incomplete or mixed.'
    }
    $proposals = @($findings | ForEach-Object {
            Get-ApprovedOwnerV2Proposal -Evidence $Evidence -Finding $_
        } | Sort-Object findingId)
    return [ordered]@{
        schemaVersion = $script:ApprovedOwnerV2SchemaVersion
        kind = 'owner-v2-comment-review-package'
        authorization = 'none'
        state = [ordered]@{
            identity = $Evidence.Identity
            declarationSha256 = Get-ApprovedOwnerV2FileSha256 $Evidence.Paths.declaration
            evidenceSha256 = Get-ApprovedOwnerV2FileSha256 $Evidence.Paths.evidence
            recordSha256 = Get-ApprovedOwnerV2FileSha256 $Evidence.Paths.record
            observationSha256 = Get-ApprovedOwnerV2FileSha256 $Evidence.Paths.observation
            telemetrySha256 = Get-ApprovedOwnerV2FileSha256 $Evidence.Paths.telemetry
            resultDigest = [string]$Evidence.Record.resultDigest
            recordSchemaVersion = [int]$Evidence.Record.schemaVersion
            attempts = [int]$Evidence.Record.attempts
            modelExecutionState = $(if ([int]$Evidence.Record.schemaVersion -eq 2) {
                    [string]$Evidence.Record.modelExecutionState
                }
                else { 'legacy-completed-record' })
        }
        subject = [ordered]@{
            projectId = [string]$Evidence.Declaration.subject.projectId
            repositoryId = [string]$Evidence.Declaration.subject.repositoryId
            pullRequestId = [long]$Evidence.Declaration.subject.pullRequestId
            sourceCommit = [string]$Evidence.Declaration.head.sourceCommit
            targetCommit = [string]$Evidence.Declaration.target.targetCommit
            targetRef = [string]$Evidence.Declaration.target.targetRef
        }
        rule = $Evidence.Declaration.rule
        capability = $Evidence.Declaration.capability
        model = $Evidence.Declaration.model
        config = $Evidence.Declaration.config
        acquisitionPayloadDigest = [string]$Evidence.Declaration.acquisitionPayloadDigest
        discussion = [ordered]@{
            snapshotSha256 = Get-ApprovedOwnerV2SourceArtifact `
                -Observation $Evidence.Observation -Kind 'owner-v2-discussion-snapshot'
            mappingSha256 = Get-ApprovedOwnerV2SourceArtifact `
                -Observation $Evidence.Observation -Kind 'owner-v2-discussion-mapping'
            reviewerIdentitySha256 = Get-ApprovedOwnerV2SourceArtifact `
                -Observation $Evidence.Observation `
                -Kind 'owner-v2-discussion-reviewer-identity'
            rawPageSha256 = @(
                Get-ApprovedOwnerV2SourceArtifacts `
                    -Observation $Evidence.Observation `
                    -Kind 'owner-v2-discussion-raw-page'
            )
        }
        provider = $Evidence.Provider
        toolkit = $Evidence.Toolkit
        observationImplementation = $Evidence.Observation.implementation
        proposals = $proposals
        createdUtc = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    }
}

function Initialize-ApprovedOwnerV2ApprovalRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ApprovalRoot,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $created = $false
    $root = Resolve-AgentTrustedRoot -Path $ApprovalRoot -Kind durable-state `
        -RepositoryRoot $RepoRoot -Create -CreatedByCaller ([ref]$created)
    foreach ($leaf in @('keys', 'reviews', 'approvals', 'intents', 'outcomes')) {
        $path = Join-Path $root $leaf
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            New-Item -ItemType Directory -Path $path | Out-Null
        }
    }
    $keyPath = Join-Path $root 'keys\owner-v2-comment-approval.hmac'
    if (-not (Test-Path -LiteralPath $keyPath -PathType Leaf)) {
        $bytes = [byte[]]::new(32)
        [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
        [IO.File]::WriteAllBytes($keyPath, $bytes)
    }
    [void](Assert-AgentTrustedFile -Path $keyPath -AllowedRoot $root -Private)
    return [pscustomobject]@{ Root = $root; KeyPath = $keyPath }
}

function Get-ApprovedOwnerV2ApprovalKey {
    param([Parameter(Mandatory)][string]$ApprovalRoot)
    $path = Join-Path $ApprovalRoot 'keys\owner-v2-comment-approval.hmac'
    [void](Assert-AgentTrustedFile -Path $path -AllowedRoot $ApprovalRoot -Private)
    $key = [IO.File]::ReadAllBytes($path)
    if ($key.Length -ne 32) { throw 'Owner v2 approval key must be exactly 32 bytes.' }
    return $key
}

function Get-ApprovedOwnerV2Hmac {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][byte[]]$Key
    )
    $hmac = [Security.Cryptography.HMACSHA256]::new($Key)
    try {
        return ([Convert]::ToHexString($hmac.ComputeHash(
                    [Text.UTF8Encoding]::new($false).GetBytes($Text)))).ToLowerInvariant()
    }
    finally { $hmac.Dispose() }
}

function Write-ApprovedOwnerV2ImmutableText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Text
    )
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $existing = [IO.File]::ReadAllBytes($Path)
        if ((Get-ApprovedOwnerV2Sha256 $existing) -cne
            (Get-ApprovedOwnerV2Sha256 $bytes)) {
            throw "Immutable Owner v2 approval artifact '$Path' already has different bytes."
        }
        return $false
    }
    $stream = [IO.File]::Open(
        $Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
    return $true
}

function Write-ApprovedOwnerV2SignedRecord {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][Collections.IDictionary]$Payload,
        [Parameter(Mandatory)][byte[]]$Key
    )
    $manifestJson = ConvertTo-ApprovedOwnerV2CanonicalJson $Payload
    $envelope = [ordered]@{
        schemaVersion = 1
        kind = 'owner-v2-comment-signed-envelope'
        signatureAlg = 'HMACSHA256'
        manifestJson = $manifestJson
        signature = Get-ApprovedOwnerV2Hmac -Text $manifestJson -Key $Key
    }
    [void](Write-ApprovedOwnerV2ImmutableText -Path $Path -Text (
            (ConvertTo-ApprovedOwnerV2CanonicalJson $envelope) + "`n"))
    return $Path
}

function Read-ApprovedOwnerV2SignedRecord {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][byte[]]$Key
    )
    $envelope = Read-ApprovedOwnerV2Json $Path
    Assert-ApprovedOwnerV2ExactKeys -Value $envelope -Name envelope -Expected @(
        'schemaVersion', 'kind', 'signatureAlg', 'manifestJson', 'signature'
    )
    if ([int]$envelope.schemaVersion -ne 1 -or
        [string]$envelope.kind -cne 'owner-v2-comment-signed-envelope' -or
        [string]$envelope.signatureAlg -cne 'HMACSHA256') {
        throw 'Owner v2 signed envelope has an unsupported contract.'
    }
    $expected = Get-ApprovedOwnerV2Hmac -Text ([string]$envelope.manifestJson) -Key $Key
    $actualBytes = [Text.Encoding]::ASCII.GetBytes([string]$envelope.signature)
    $expectedBytes = [Text.Encoding]::ASCII.GetBytes($expected)
    if ($actualBytes.Length -ne $expectedBytes.Length -or
        -not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
            $actualBytes, $expectedBytes)) {
        throw 'Owner v2 signed envelope signature did not verify.'
    }
    $payload = [string]$envelope.manifestJson |
        ConvertFrom-Json -AsHashtable -Depth 64
    if ((ConvertTo-ApprovedOwnerV2CanonicalJson $payload) -cne
        [string]$envelope.manifestJson) {
        throw 'Owner v2 signed envelope did not contain canonical manifest JSON.'
    }
    return $payload
}

function Get-ApprovedOwnerV2AuthenticatedPriorComments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DeliveryRoot,
        [Parameter(Mandatory)][byte[]]$Key,
        [ValidateSet(
            'owner',
            'named-areequal',
            'contextual-conventions')]
        [string]$Delivery = 'owner'
    )
    if (-not [IO.Path]::IsPathFullyQualified($DeliveryRoot) -or
        -not (Test-Path -LiteralPath $DeliveryRoot -PathType Container) -or
        $Key.Length -ne 32) {
        throw 'Authenticated prior-comment history requires a bounded delivery root and key.'
    }
    $eventKind = if ($Delivery -ceq 'named-areequal') {
        'named-areequal-v2-delivery-event'
    }
    elseif ($Delivery -ceq 'contextual-conventions') {
        'contextual-conventions-v1-delivery-event'
    }
    else { 'owner-v2-delivery-event' }
    $intentKind = if ($Delivery -ceq 'named-areequal') {
        'named-areequal-v2-service-create-intent'
    }
    elseif ($Delivery -ceq 'contextual-conventions') {
        'contextual-conventions-v1-service-create-intent'
    }
    else { 'owner-v2-service-create-intent' }
    $outcomeKind = if ($Delivery -ceq 'named-areequal') {
        'named-areequal-v2-service-create-outcome'
    }
    elseif ($Delivery -ceq 'contextual-conventions') {
        'contextual-conventions-v1-service-create-outcome'
    }
    else { 'owner-v2-service-create-outcome' }
    $proofs = [Collections.Generic.List[object]]::new()
    $eventFiles = @(Get-ChildItem -LiteralPath (
                Join-Path $DeliveryRoot 'events') `
            -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object FullName)
    if ($eventFiles.Count -gt 5000) {
        throw 'Authenticated prior-comment history exceeds the bounded event limit.'
    }
    foreach ($file in $eventFiles) {
        $event = Read-ApprovedOwnerV2SignedRecord `
            -Path $file.FullName -Key $Key
        if ([string]$event.kind -cne $eventKind) {
            throw "Prior-comment event '$($file.FullName)' is foreign."
        }
        if ([string]$event.action -cne 'create' -or
            [string]$event.outcome -cnotin @(
                'created',
                'created-confirmed-after-error',
                'recovered-confirmed') -or
            [int]$event.providerWriteCount -ne 1 -or
            [int]$event.modelWriteCount -ne 0 -or
            [string]$event.providerWriteState -cne 'confirmed') {
            continue
        }
        $runId = [string]$event.runId
        $stateIdentity = [string]$event.finding.stateIdentity
        if ($runId -cnotmatch '^[0-9a-f]{32}$' -or
            $stateIdentity -cnotmatch '^[0-9a-f]{64}$' -or
            [string]$event.eventId -cnotmatch '^[0-9a-f]{32}$' -or
            [long]$event.threadId -lt 1 -or
            [long]$event.commentId -lt 1) {
            continue
        }
        $intentPath = Join-Path $DeliveryRoot (
            "intents\$stateIdentity\$runId.json")
        $outcomePath = Join-Path $DeliveryRoot (
            "outcomes\$stateIdentity\$runId.json")
        if (-not (Test-Path -LiteralPath $intentPath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $outcomePath -PathType Leaf)) {
            continue
        }
        $intent = Read-ApprovedOwnerV2SignedRecord `
            -Path $intentPath -Key $Key
        $outcome = Read-ApprovedOwnerV2SignedRecord `
            -Path $outcomePath -Key $Key
        if ([string]$intent.kind -cne $intentKind -or
            [string]$outcome.kind -cne $outcomeKind -or
            [string]$intent.runId -cne $runId -or
            [string]$outcome.runId -cne $runId -or
            [string]$intent.state.identity -cne $stateIdentity -or
            [string]$outcome.stateIdentity -cne $stateIdentity -or
            [string]$outcome.status -cnotin @(
                'completed',
                'partial',
                'operator-review-required') -or
            [int]$outcome.modelWrites -ne 0 -or
            [int]$outcome.providerWritesConservative -lt 1 -or
            @($outcome.eventIds | Where-Object {
                    [string]$_ -ceq [string]$event.eventId
                }).Count -ne 1) {
            continue
        }
        $selection = @($intent.selections | Where-Object {
                [string]$_.findingId -ceq
                    [string]$event.finding.findingId -and
                [string]$_.marker -ceq
                    [string]$event.finding.marker
            })
        if ($selection.Count -ne 1) {
            continue
        }
        $selection = $selection[0]
        $bodySha256 =
            Get-ApprovedOwnerV2TextSha256 `
                -Text ([string]$selection.body)
        $pullRequestScope =
            [string](Get-ApprovedOwnerV2Value `
                $selection 'scope' '') -ceq
                'pull-request'
        $selectionRuleId = [string](Get-ApprovedOwnerV2Value `
            $selection 'ruleId' '')
        $eventFindingRuleId = [string](Get-ApprovedOwnerV2Value `
            $event.finding 'ruleId' '')
        $selectionBodySha256 = [string](Get-ApprovedOwnerV2Value `
            $selection 'bodySha256' '')
        $eventFindingBodySha256 = [string](Get-ApprovedOwnerV2Value `
            $event.finding 'bodySha256' '')
        if ([Text.Encoding]::UTF8.GetByteCount(
                [string]$selection.body) -gt 65536 -or
            ($Delivery -cne 'owner' -and (
                $bodySha256 -cne $selectionBodySha256 -or
                $bodySha256 -cne $eventFindingBodySha256)) -or
            ($Delivery -ceq 'owner' -and (
                (-not [string]::IsNullOrEmpty($selectionBodySha256) -and
                    $bodySha256 -cne $selectionBodySha256) -or
                (-not [string]::IsNullOrEmpty($eventFindingBodySha256) -and
                    $bodySha256 -cne $eventFindingBodySha256))) -or
            ($pullRequestScope -and (
                [string](Get-ApprovedOwnerV2Value `
                    $event.finding 'scope' '') -cne
                    'pull-request' -or
                [string]$selection.subject -cne
                    [string]$event.finding.subject -or
                [string]$selection.metadataSha256 -cne
                    [string]$event.finding.metadataSha256 -or
                [string]$selection.issueIdentity -cne
                    [string]$event.finding.issueIdentity)) -or
            (-not $pullRequestScope -and (
                [string]$selection.path -ine
                    [string]$event.finding.path -or
                [int]$selection.line -ne
                    [int]$event.finding.line -or
                [string]$selection.symbol -cne
                    [string]$event.finding.symbol)) -or
            ($Delivery -ceq 'contextual-conventions' -and
                [string]::IsNullOrWhiteSpace($selectionRuleId)) -or
            $selectionRuleId -cne $eventFindingRuleId) {
            continue
        }
        if ((Get-ApprovedOwnerV2Digest $intent.subject) -cne
            (Get-ApprovedOwnerV2Digest $event.subject)) {
            continue
        }
        $proof = [ordered]@{
            schemaVersion = 1
            kind =
                'owner-v2-authenticated-prior-comment'
            delivery = $Delivery
            capabilityId =
                [string]$intent.capability.id
            subject = $intent.subject
            rule = $intent.rule
            reviewerIdentity =
                $intent.reviewerIdentity
            reviewerIdentityDigest =
                Get-ApprovedOwnerV2Digest `
                    $intent.reviewerIdentity
            selection = [ordered]@{
                findingId =
                    [string]$selection.findingId
                marker = [string]$selection.marker
                body = [string]$selection.body
                bodySha256 = $bodySha256
                constructIdentity =
                    [string]$selection.constructIdentity
                constructRef =
                    [string]$selection.constructRef
                semanticKey =
                    [string]$selection.semanticKey
                ruleId = $selectionRuleId
                scope = [string](Get-ApprovedOwnerV2Value $selection 'scope' 'changed-line')
            }
            event = [ordered]@{
                eventId = [string]$event.eventId
                runId = $runId
                stateIdentity = $stateIdentity
                threadId = [long]$event.threadId
                commentId = [long]$event.commentId
            }
        }
        $intentIterationId = Get-ApprovedOwnerV2Value `
            $intent 'currentIterationId' $null
        if ($intentIterationId -isnot [bool] -and
            ($intentIterationId -is [int] -or
                $intentIterationId -is [long]) -and
            [long]$intentIterationId -ge 1 -and
            [long]$intentIterationId -le [int]::MaxValue) {
            $proof['currentIterationId'] =
                [long]$intentIterationId
        }
        $intentSnapshotSha256 = [string](Get-ApprovedOwnerV2Value `
            $intent 'discussionSnapshotSha256' '')
        if ($intentSnapshotSha256 -cmatch '^[0-9a-f]{64}$') {
            $proof['discussionSnapshotSha256'] =
                $intentSnapshotSha256
        }
        if ($pullRequestScope) {
            $proof.selection['subject'] =
                [string]$selection.subject
            $proof.selection['metadataSha256'] =
                [string]$selection.metadataSha256
            $proof.selection['issueIdentity'] =
                [string]$selection.issueIdentity
        }
        else {
            $proof.selection['path'] =
                [string]$selection.path
            $proof.selection['line'] =
                [int]$selection.line
            $proof.selection['symbol'] =
                [string]$selection.symbol
        }
        [void]$proofs.Add($proof)
    }
    return $proofs.ToArray()
}

function Approve-OwnerV2ReviewPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReviewPackagePath,
        [Parameter(Mandatory)][string]$ApprovalPath,
        [Parameter(Mandatory)][string[]]$FindingId,
        [Parameter(Mandatory)][string]$OperatorId,
        [Parameter(Mandatory)][string]$OperatorDescriptor,
        [Parameter(Mandatory)][string]$OperatorUpn,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][byte[]]$Key,
        [switch]$ApproveUpdate
    )
    if ($FindingId.Count -lt 1 -or
        $FindingId.Count -gt $script:ApprovedOwnerV2MaximumSelections) {
        throw 'Approve one to five exact Owner finding IDs.'
    }
    if ($OperatorId -cnotmatch '^[0-9a-fA-F-]{36}$' -or
        [string]::IsNullOrWhiteSpace($OperatorDescriptor) -or
        $OperatorUpn -cnotmatch '^[^@\s]+@[^@\s]+$' -or
        [string]::IsNullOrWhiteSpace($Reason) -or $Reason.Length -gt 1024 -or
        $Reason -match '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]') {
        throw 'Approval requires exact operator GUID, descriptor, UPN, and printable reason.'
    }
    $review = Read-ApprovedOwnerV2Json $ReviewPackagePath
    if ([string]$review.kind -cne 'owner-v2-comment-review-package' -or
        [string]$review.authorization -cne 'none') {
        throw 'Only an unsigned Owner v2 review package can be approved.'
    }
    if ([string]$OperatorId -ine
        [string]$review.provider.reviewerIdentity.id -or
        [string]$OperatorDescriptor -cne
        [string]$review.provider.reviewerIdentity.descriptor -or
        [string]$OperatorUpn -ine
        [string]$review.provider.reviewerIdentity.uniqueName) {
        throw 'Approval operator identity does not match the configured reviewer.'
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $selected = [Collections.Generic.List[object]]::new()
    foreach ($id in $FindingId) {
        if (-not $seen.Add($id)) { throw "Finding '$id' was selected more than once." }
        $matches = @($review.proposals | Where-Object {
                [string]$_.findingId -ceq $id
            })
        if ($matches.Count -ne 1) { throw "Finding '$id' is unknown or ambiguous." }
        if ([string]$matches[0].classification -ceq 'wouldUpdate' -and
            -not $ApproveUpdate) {
            throw "Finding '$id' is an update and requires explicit -ApproveUpdate."
        }
        [void]$selected.Add($matches[0])
    }
    $payload = [ordered]@{
        schemaVersion = 1
        kind = 'owner-v2-approved-comment-selection'
        reviewPackageSha256 = Get-ApprovedOwnerV2FileSha256 $ReviewPackagePath
        reviewPackageDigest = Get-ApprovedOwnerV2Digest $review
        state = $review.state
        subject = $review.subject
        rule = $review.rule
        capability = $review.capability
        model = $review.model
        config = $review.config
        acquisitionPayloadDigest = $review.acquisitionPayloadDigest
        discussion = $review.discussion
        provider = $review.provider
        toolkit = $review.toolkit
        observationImplementation = $review.observationImplementation
        operator = [ordered]@{
            id = $OperatorId.ToLowerInvariant()
            descriptor = $OperatorDescriptor
            uniqueName = $OperatorUpn.ToLowerInvariant()
        }
        reason = $Reason
        approveUpdate = [bool]$ApproveUpdate
        selections = $selected.ToArray()
        approvedUtc = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    }
    return Write-ApprovedOwnerV2SignedRecord -Path $ApprovalPath `
        -Payload $payload -Key $Key
}

function Assert-ApprovedOwnerV2ApprovalCurrent {
    param(
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][Collections.IDictionary]$Approval
    )
    if ([string]$Approval.kind -cne 'owner-v2-approved-comment-selection' -or
        @($Approval.selections).Count -lt 1 -or
        @($Approval.selections).Count -gt $script:ApprovedOwnerV2MaximumSelections) {
        throw 'Signed Owner v2 approval has an unsupported selection contract.'
    }
    $review = New-ApprovedOwnerV2ReviewPackage -Evidence $Evidence
    $bindings = @(
        @('identity', $review.state.identity, $Approval.state.identity),
        @('declarationSha256', $review.state.declarationSha256,
            $Approval.state.declarationSha256),
        @('evidenceSha256', $review.state.evidenceSha256,
            $Approval.state.evidenceSha256),
        @('recordSha256', $review.state.recordSha256,
            $Approval.state.recordSha256),
        @('observationSha256', $review.state.observationSha256,
            $Approval.state.observationSha256),
        @('telemetrySha256', $review.state.telemetrySha256,
            $Approval.state.telemetrySha256),
        @('resultDigest', $review.state.resultDigest, $Approval.state.resultDigest),
        @('recordSchemaVersion', [string]$review.state.recordSchemaVersion,
            [string]$Approval.state.recordSchemaVersion),
        @('attempts', [string]$review.state.attempts, [string]$Approval.state.attempts),
        @('modelExecutionState', $review.state.modelExecutionState,
            $Approval.state.modelExecutionState),
        @('sourceCommit', $review.subject.sourceCommit, $Approval.subject.sourceCommit),
        @('targetCommit', $review.subject.targetCommit, $Approval.subject.targetCommit),
        @('targetRef', $review.subject.targetRef, $Approval.subject.targetRef),
        @('rule', (Get-ApprovedOwnerV2Digest $review.rule),
            (Get-ApprovedOwnerV2Digest $Approval.rule)),
        @('capability', (Get-ApprovedOwnerV2Digest $review.capability),
            (Get-ApprovedOwnerV2Digest $Approval.capability)),
        @('model', (Get-ApprovedOwnerV2Digest $review.model),
            (Get-ApprovedOwnerV2Digest $Approval.model)),
        @('config', (Get-ApprovedOwnerV2Digest $review.config),
            (Get-ApprovedOwnerV2Digest $Approval.config)),
        @('acquisitionPayloadDigest', $review.acquisitionPayloadDigest,
            $Approval.acquisitionPayloadDigest),
        @('discussion', (Get-ApprovedOwnerV2Digest $review.discussion),
            (Get-ApprovedOwnerV2Digest $Approval.discussion)),
        @('provider', (Get-ApprovedOwnerV2Digest $review.provider),
            (Get-ApprovedOwnerV2Digest $Approval.provider)),
        @('toolkit', (Get-ApprovedOwnerV2Digest $review.toolkit),
            (Get-ApprovedOwnerV2Digest $Approval.toolkit)),
        @('observationImplementation',
            (Get-ApprovedOwnerV2Digest $review.observationImplementation),
            (Get-ApprovedOwnerV2Digest $Approval.observationImplementation))
    )
    foreach ($binding in $bindings) {
        if ([string]$binding[1] -cne [string]$binding[2]) {
            throw "Signed Owner v2 approval binding '$($binding[0])' is stale."
        }
    }
    foreach ($selection in @($Approval.selections)) {
        $matches = @($review.proposals | Where-Object {
                [string]$_.findingId -ceq [string]$selection.findingId
            })
        if ($matches.Count -ne 1 -or
            (Get-ApprovedOwnerV2Digest $matches[0]) -cne
            (Get-ApprovedOwnerV2Digest $selection)) {
            throw "Signed Owner v2 selection '$($selection.findingId)' was modified or is stale."
        }
    }
}

function Get-ApprovedOwnerV2MarkerEntries {
    param(
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)][string]$Marker
    )
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($thread in @($Snapshot.Threads)) {
        foreach ($comment in @($thread.comments)) {
            foreach ($match in [regex]::Matches(
                    [string]$comment.body, $script:ApprovedOwnerV2MarkerPattern)) {
                if ([string]$match.Groups[1].Value -ceq $Marker) {
                    [void]$entries.Add([pscustomobject]@{
                            Thread = $thread
                            Comment = $comment
                        })
                }
            }
        }
    }
    return $entries.ToArray()
}

function Get-ApprovedOwnerV2RecomputedSnapshotDigest {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Subject,
        [Parameter(Mandatory)][string]$MappingDigest,
        [Parameter(Mandatory)][string]$ReviewerIdentityDigest,
        [Parameter(Mandatory)][long]$CurrentIterationId,
        [AllowEmptyCollection()][object[]]$Threads = @(),
        [int]$MaximumPages = 20,
        [int]$PageSize = 100,
        [int]$MaximumThreads = 1000,
        [int]$MaximumComments = 5000,
        [long]$MaximumBytes = 4194304
    )
    $baseArguments = [ordered]@{
        repositoryId = [string]$Subject.repositoryId
        projectId = [string]$Subject.projectId
        pullRequestId = [long]$Subject.pullRequestId
        sourceCommit = [string]$Subject.sourceCommit
        targetCommit = [string]$Subject.targetCommit
        targetRef = [string]$Subject.targetRef
    }
    $pageIdentity = [ordered]@{ schemaVersion = 1 }
    foreach ($entry in $baseArguments.GetEnumerator()) {
        $pageIdentity[$entry.Key] = $entry.Value
    }
    $orderedThreads = @($Threads | Sort-Object { [long]$_.threadId })
    $sourceDigests = [Collections.Generic.List[string]]::new()
    $pageOrdinal = 0
    do {
        $pageOffset = $pageOrdinal * $PageSize
        $continuationToken = if ($pageOrdinal -eq 0) {
            $null
        }
        else {
            "skip:$pageOffset"
        }
        $pageThreads = @($orderedThreads | Select-Object -Skip $pageOffset -First $PageSize)
        $nextOffset = $pageOffset + $pageThreads.Count
        $nextToken = if ($nextOffset -lt $orderedThreads.Count) {
            "skip:$nextOffset"
        }
        else {
            $null
        }
        $pageMaterial = [ordered]@{
            semantics = 'owner-azuredevops-discussion-v1'
            mappingDigest = $MappingDigest
            reviewerIdentityDigest = $ReviewerIdentityDigest
            identity = $pageIdentity
            pageOrdinal = $pageOrdinal
            continuationToken = $continuationToken
            nextToken = $nextToken
            currentIterationId = $CurrentIterationId
            threads = @($pageThreads)
        }
        [void]$sourceDigests.Add((Get-ApprovedOwnerV2Digest $pageMaterial))
        $pageOrdinal++
    } while ($null -ne $nextToken)

    $digestMaterial = [ordered]@{
        schemaVersion = 1
        identity = $baseArguments
        limits = [ordered]@{
            maximumPages = $MaximumPages
            pageSize = $PageSize
            maximumThreads = $MaximumThreads
            maximumComments = $MaximumComments
            maximumBytes = $MaximumBytes
        }
        sourceDigests = @($sourceDigests)
        mappingDigest = $MappingDigest
        reviewerIdentityDigest = $ReviewerIdentityDigest
        currentIterationId = $CurrentIterationId
        threads = $orderedThreads
    }
    return Get-ApprovedOwnerV2Digest $digestMaterial
}

function Test-ApprovedOwnerV2ReconciledSnapshotDigest {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Approval,
        [Parameter(Mandatory)]$Live,
        [Parameter(Mandatory)][string]$ExpectedSnapshotSha256,
        [AllowEmptyCollection()][object[]]$AuthenticatedPriorComments = @(),
        [AllowNull()]$Evidence = $null
    )
    $snapshot = $Live.Snapshot
    if ($null -eq $snapshot -or
        [string]$snapshot.State -cne 'complete' -or
        [string]$snapshot.Reason -cne 'complete' -or
        @($AuthenticatedPriorComments).Count -eq 0) {
        return $false
    }
    $subject = Get-ApprovedOwnerV2Value $Approval 'subject'
    $operator = Get-ApprovedOwnerV2Value $Approval 'operator'
    $provider = Get-ApprovedOwnerV2Value $Approval 'provider'
    if ($subject -isnot [Collections.IDictionary] -or
        $operator -isnot [Collections.IDictionary] -or
        $provider -isnot [Collections.IDictionary] -or
        (Get-ApprovedOwnerV2Value $provider 'reviewerIdentity') -isnot [Collections.IDictionary]) {
        return $false
    }
    $mappingDigest = [string]$snapshot.MappingDigest
    $reviewerIdentityDigest = [string]$snapshot.ReviewerIdentityDigest
    if ($mappingDigest -cne [string]$provider.mappingDigest -or
        $reviewerIdentityDigest -cne [string]$provider.reviewerIdentity.digest) {
        return $false
    }
    if ($Approval.Contains('discussion') -and
        $Approval.discussion -is [Collections.IDictionary]) {
        if ($mappingDigest -cne ('v1:sha256:' + [string]$Approval.discussion.mappingSha256) -or
            $reviewerIdentityDigest -cne ('v1:sha256:' + [string]$Approval.discussion.reviewerIdentitySha256)) {
            return $false
        }
    }
    if ($snapshot.CurrentIterationId -is [bool] -or
        ($snapshot.CurrentIterationId -isnot [int] -and
            $snapshot.CurrentIterationId -isnot [long])) {
        return $false
    }
    $currentIterationId = [long]$snapshot.CurrentIterationId
    if ($currentIterationId -lt 1 -or $currentIterationId -gt [int]::MaxValue) {
        return $false
    }
    if ($subject.Contains('iterationId') -and $null -ne $subject['iterationId']) {
        $subjectIterationId = $subject['iterationId']
        if ($subjectIterationId -is [bool] -or
            ($subjectIterationId -isnot [int] -and $subjectIterationId -isnot [long]) -or
            [long]$subjectIterationId -ne $currentIterationId) {
            return $false
        }
    }
    if ($null -ne $Evidence -and
        $Evidence.PSObject.Properties.Match('Declaration').Count -gt 0 -and
        $Evidence.Declaration -is [Collections.IDictionary] -and
        $Evidence.Declaration.Contains('head') -and
        $Evidence.Declaration['head'] -is [Collections.IDictionary] -and
        $Evidence.Declaration['head'].Contains('iterationId') -and
        $null -ne $Evidence.Declaration['head']['iterationId']) {
        $declIterationId = $Evidence.Declaration['head']['iterationId']
        if ($declIterationId -is [bool] -or
            ($declIterationId -isnot [int] -and $declIterationId -isnot [long]) -or
            [long]$declIterationId -ne $currentIterationId) {
            return $false
        }
    }

    $proofByThreadId = @{}
    $seenEventIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($proof in @($AuthenticatedPriorComments)) {
        if ($proof -isnot [Collections.IDictionary] -or
            [string](Get-ApprovedOwnerV2Value $proof 'kind' '') -cne
                'owner-v2-authenticated-prior-comment' -or
            $proof.subject -isnot [Collections.IDictionary] -or
            $proof.reviewerIdentity -isnot [Collections.IDictionary] -or
            $proof.selection -isnot [Collections.IDictionary] -or
            $proof.event -isnot [Collections.IDictionary]) {
            continue
        }
        if ([string]$proof.subject.repositoryId -cne [string]$subject.repositoryId -or
            [string]$proof.subject.projectId -cne [string]$subject.projectId -or
            [long]$proof.subject.pullRequestId -ne [long]$subject.pullRequestId -or
            [string]$proof.subject.sourceCommit -cne [string]$subject.sourceCommit -or
            [string]$proof.subject.targetCommit -cne [string]$subject.targetCommit -or
            [string]$proof.subject.targetRef -cne [string]$subject.targetRef) {
            continue
        }
        if ([string](Get-ApprovedOwnerV2Value $proof.reviewerIdentity 'id' '') -cne
                [string](Get-ApprovedOwnerV2Value $operator 'id' '') -or
            [string](Get-ApprovedOwnerV2Value $proof.reviewerIdentity 'descriptor' '') -cne
                [string](Get-ApprovedOwnerV2Value $operator 'descriptor' '') -or
            [string](Get-ApprovedOwnerV2Value $proof.reviewerIdentity 'uniqueName' '') -cne
                [string](Get-ApprovedOwnerV2Value $operator 'uniqueName' '') -or
            [string](Get-ApprovedOwnerV2Value $proof 'reviewerIdentityDigest' '') -cne $reviewerIdentityDigest) {
            return $false
        }
        $proofIterationId = Get-ApprovedOwnerV2Value $proof 'currentIterationId' $null
        if ($proofIterationId -is [bool] -or
            ($proofIterationId -isnot [int] -and $proofIterationId -isnot [long]) -or
            [long]$proofIterationId -ne $currentIterationId) {
            return $false
        }
        $threadId = [long]$proof.event.threadId
        $commentId = [long]$proof.event.commentId
        $eventId = [string](Get-ApprovedOwnerV2Value $proof.event 'eventId' '')
        if ($threadId -lt 1 -or $commentId -lt 1 -or $eventId -cnotmatch '^[0-9a-f]{32}$') {
            return $false
        }
        if ($proofByThreadId.ContainsKey($threadId) -or -not $seenEventIds.Add($eventId)) {
            return $false
        }
        $proofByThreadId[$threadId] = $proof
    }
    if ($proofByThreadId.Count -eq 0) {
        return $false
    }

    $removableThreadIds = [Collections.Generic.List[long]]::new()
    foreach ($thread in @($snapshot.Threads | Sort-Object { [long]$_.threadId })) {
        if ($thread -isnot [Collections.IDictionary]) {
            continue
        }
        $threadId = [long]$thread.threadId
        if (-not $proofByThreadId.ContainsKey($threadId)) {
            continue
        }
        if ([string]$thread.status -cne 'active' -or
            [bool]$thread.isDeleted -or
            [bool]$thread.isOutdated) {
            return $false
        }
        $comments = @($thread.comments)
        if ($comments.Count -ne 1 -or
            $comments[0] -isnot [Collections.IDictionary]) {
            return $false
        }
        $comment = $comments[0]
        if ([bool]$comment.isDeleted -or
            [string]$comment.commentType -cne 'text' -or
            -not [bool]$comment.reviewerOwned -or
            [string]$comment.reviewerIdentityState -cne 'matched') {
            return $false
        }
        $commentBody = [string]$comment.body
        $commentBodyDigest = [string]$comment.bodyDigest
        $commentBodySha256 = Get-ApprovedOwnerV2TextSha256 -Text $commentBody
        if ($commentBodyDigest -cne "v1:sha256:$commentBodySha256") {
            return $false
        }
        $proof = $proofByThreadId[$threadId]
        $proofDelivery = [string](Get-ApprovedOwnerV2Value $proof 'delivery' '')
        $expectedMarkerPrefix = switch ($proofDelivery) {
            'owner' { 'devpilot-owner-comment:v1' }
            'named-areequal' { 'devpilot-named-areequal:v1' }
            'contextual-conventions' { 'devpilot-contextual-convention:v1' }
            default { '' }
        }
        $marker = [string](Get-ApprovedOwnerV2Value $proof.selection 'marker' '')
        if ([string]::IsNullOrEmpty($expectedMarkerPrefix) -or
            $marker -cnotmatch '^[0-9a-f]{64}$' -or
            [long]$comment.commentId -ne [long]$proof.event.commentId -or
            $commentBody -cne [string]$proof.selection.body -or
            $commentBodySha256 -cne [string]$proof.selection.bodySha256 -or
            $commentBody -cnotmatch (
                '<!-- ' +
                [regex]::Escape($expectedMarkerPrefix) +
                ':' +
                [regex]::Escape($marker) +
                ' -->')) {
            return $false
        }
        $scope = [string](Get-ApprovedOwnerV2Value $proof.selection 'scope' 'changed-line')
        if ($scope -ceq 'pull-request') {
            if ($null -ne $thread.anchor -or
                [string]$thread.contextState -cne 'notApplicable' -or
                $null -ne $thread.sourceCommit) {
                return $false
            }
        }
        else {
            if ($thread.anchor -isnot [Collections.IDictionary] -or
                [string]$thread.anchor.path -ine [string]$proof.selection.path -or
                [long]$thread.anchor.line -ne [long]$proof.selection.line -or
                [string]$thread.contextState -cne 'current' -or
                [string]$thread.sourceCommit -cne [string]$subject.sourceCommit) {
                return $false
            }
        }
        [void]$removableThreadIds.Add($threadId)
    }
    if ($removableThreadIds.Count -eq 0) {
        return $false
    }

    $expectedDigest = "v1:sha256:$ExpectedSnapshotSha256"
    $orderedRemovable = @($removableThreadIds | Sort-Object)
    for ($startIndex = 0; $startIndex -lt $orderedRemovable.Count; $startIndex++) {
        $removeSet = [Collections.Generic.HashSet[long]]::new()
        for ($idx = $startIndex; $idx -lt $orderedRemovable.Count; $idx++) {
            [void]$removeSet.Add([long]$orderedRemovable[$idx])
        }
        $remainingThreads = @($snapshot.Threads | Where-Object {
                -not $removeSet.Contains([long]$_.threadId)
            })
        $recomputedDigest = Get-ApprovedOwnerV2RecomputedSnapshotDigest `
            -Subject $subject `
            -MappingDigest $mappingDigest `
            -ReviewerIdentityDigest $reviewerIdentityDigest `
            -CurrentIterationId $currentIterationId `
            -Threads $remainingThreads
        if ($recomputedDigest -ceq $expectedDigest) {
            return $true
        }
    }
    return $false
}

function Assert-ApprovedOwnerV2LiveRead {
    param(
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][Collections.IDictionary]$Approval,
        [Parameter(Mandatory)]$Live,
        [Parameter(Mandatory)][object[]]$Selections,
        [Parameter(Mandatory)][string]$ExpectedSnapshotSha256,
        [AllowEmptyCollection()]
        [object[]]$AuthenticatedPriorComments = @(),
        [ValidateSet('owner', 'named-areequal', 'contextual-conventions')]
        [string]$Delivery = 'owner'
    )
    $subject = $Approval.subject
    $pr = $Live.PullRequest
    if ([string]$pr.status -cne 'active' -or [bool]$pr.isDraft -or
        [string]$pr.repositoryId -cne [string]$subject.repositoryId -or
        [string]$pr.projectId -cne [string]$subject.projectId -or
        [long]$pr.pullRequestId -ne [long]$subject.pullRequestId -or
        [string]$pr.sourceCommit -cne [string]$subject.sourceCommit -or
        [string]$pr.targetCommit -cne [string]$subject.targetCommit -or
        [string]$pr.targetRef -cne [string]$subject.targetRef) {
        throw 'Live pull request head, target, ref, status, or repository binding changed.'
    }
    $operator = $Approval.operator
    if ($Live.ProviderBinding -isnot [Collections.IDictionary] -or
        (Get-ApprovedOwnerV2Digest $Live.ProviderBinding) -cne
        (Get-ApprovedOwnerV2Digest $Approval.provider)) {
        throw 'Live Azure DevOps provider configuration is stale or foreign.'
    }
    if ([string]$Live.Reviewer.id -cne [string]$operator.id -or
        [string]$Live.Reviewer.descriptor -cne [string]$operator.descriptor -or
        [string]$Live.Reviewer.uniqueName -cne [string]$operator.uniqueName) {
        throw 'Live Azure DevOps reviewer identity is missing, ambiguous, or foreign.'
    }
    if ([string]$Live.Snapshot.Digest -cne "v1:sha256:$ExpectedSnapshotSha256" -and
        -not (Test-ApprovedOwnerV2ReconciledSnapshotDigest `
                -Approval $Approval `
                -Live $Live `
                -ExpectedSnapshotSha256 $ExpectedSnapshotSha256 `
                -AuthenticatedPriorComments $AuthenticatedPriorComments `
                -Evidence $Evidence)) {
        throw 'Live discussion snapshot changed; require a fresh scheduled observation and approval.'
    }
    foreach ($selection in $Selections) {
        $anchors = @($Live.Anchors | Where-Object {
                [string]$_.path -ieq [string]$selection.path -and
                [int]$selection.line -ge [int]$_.startLine -and
                [int]$selection.line -le [int]$_.endLine
            })
        if ($anchors.Count -ne 1 -or [int]$anchors[0].changeTrackingId -lt 1) {
            throw "Anchor '$($selection.path):$($selection.line)' is stale or ambiguous."
        }
        $entries = @(Get-ApprovedOwnerV2MarkerEntries -Snapshot $Live.Snapshot `
                -Marker ([string]$selection.marker))
        if (@($entries | Where-Object {
                    -not [bool]$_.Comment.reviewerOwned -or
                    [string]$_.Comment.reviewerIdentityState -cne 'matched'
                }).Count -gt 0) {
            throw "Finding '$($selection.findingId)' has a foreign copied marker."
        }
        if ($entries.Count -gt 1) {
            throw "Finding '$($selection.findingId)' has duplicate reviewer markers."
        }
    }
    $selectedFindings = @()
    foreach ($selection in $Selections) {
        $sourceFinding = @($Evidence.Observation.findings | Where-Object {
                [string]$_.identity -ceq [string]$selection.findingId
            })[0]
        $selectedFindings += (
            $sourceFinding | ConvertTo-Json -Depth 32 -Compress |
                ConvertFrom-Json -AsHashtable -Depth 32)
    }
    $mini = [ordered]@{
        lifecycle = [ordered]@{ status = 'completed' }
        findings = $selectedFindings
        effects = [ordered]@{
            dedupe = [ordered]@{}
            providerWrites = 0
            writeToolInvocations = 0
        }
        sourceArtifacts = @()
    }
    $resolved = Resolve-OwnerV2DiscussionReconciliation -Observation $mini `
        -Contract $Evidence.Contract -Snapshot $Live.Snapshot
    $classifications = [ordered]@{}
    foreach ($finding in @($resolved.findings)) {
        $classifications[[string]$finding.identity] =
            [string]$finding.reconciliation.classification
    }
    return [pscustomobject]@{
        Classifications = $classifications
        Anchors = $Live.Anchors
    }
}

function Write-ApprovedOwnerV2Audit {
    param(
        [Parameter(Mandatory)][string]$ApprovalRoot,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$InvocationId,
        [Parameter(Mandatory)][Collections.IDictionary]$Payload,
        [Parameter(Mandatory)][byte[]]$Key
    )
    $identity = [string](Get-ApprovedOwnerV2Value $Payload 'stateIdentity' '')
    if ($identity -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Owner v2 audit payload has an invalid state identity.'
    }
    return Write-ApprovedOwnerV2SignedRecord -Path (
        Join-Path $ApprovalRoot "$Phase\$identity\$InvocationId.json") `
        -Payload $Payload -Key $Key
}

function Repair-ApprovedOwnerV2Audits {
    param(
        [Parameter(Mandatory)][string]$ApprovalRoot,
        [Parameter(Mandatory)][byte[]]$Key,
        [Parameter(Mandatory)][scriptblock]$Provider,
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][Collections.IDictionary]$Approval
    )
    $repaired = [Collections.Generic.List[object]]::new()
    $identity = [string]$Approval.state.identity
    $intentRoot = Join-Path $ApprovalRoot "intents\$identity"
    $outcomeRoot = Join-Path $ApprovalRoot "outcomes\$identity"
    foreach ($file in @(Get-ChildItem -LiteralPath $intentRoot `
                -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $outcomePath = Join-Path $outcomeRoot $file.Name
        if (Test-Path -LiteralPath $outcomePath -PathType Leaf) {
            [void](Read-ApprovedOwnerV2SignedRecord -Path $outcomePath -Key $Key)
            continue
        }
        $intent = Read-ApprovedOwnerV2SignedRecord -Path $file.FullName -Key $Key
        if ([string]$intent.kind -cne 'owner-v2-comment-intent' -or
            [string]$intent.stateIdentity -cne [string]$Approval.state.identity) {
            throw "Interrupted Owner v2 intent '$($file.FullName)' is foreign."
        }
        $live = & $Provider 'ReadCurrent' @{
            evidence = $Evidence
            operator = $Approval.operator
            selections = @($intent.selections)
        }
        $confirmed = 0
        foreach ($selection in @($intent.selections)) {
            $entries = @(Get-ApprovedOwnerV2MarkerEntries -Snapshot $live.Snapshot `
                    -Marker ([string]$selection.marker))
            if (@($entries | Where-Object {
                        [bool]$_.Comment.reviewerOwned -and
                        [string]$_.Comment.body -ceq [string]$selection.body -and
                        -not [bool]$_.Comment.isDeleted
                    }).Count -eq 1) {
                $confirmed++
            }
        }
        $outcome = [ordered]@{
            schemaVersion = 1
            kind = 'owner-v2-comment-outcome'
            invocationId = [string]$intent.invocationId
            stateIdentity = [string]$intent.stateIdentity
            status = $(if ($confirmed -eq @($intent.selections).Count) {
                    'recovered-confirmed'
                }
                else { 'interrupted' })
            providerWrites = 'unknown'
            recoveryProviderWrites = 0
            confirmedFromReadback = $confirmed
            createdUtc = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
        }
        [void](Write-ApprovedOwnerV2SignedRecord -Path $outcomePath `
                -Payload $outcome -Key $Key)
        [void]$repaired.Add($outcome)
    }
    return , $repaired.ToArray()
}

function Invoke-ApprovedOwnerV2Comments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][Collections.IDictionary]$Approval,
        [Parameter(Mandatory)][string]$ApprovalRoot,
        [Parameter(Mandatory)][byte[]]$Key,
        [Parameter(Mandatory)][scriptblock]$Provider,
        [switch]$Publish,
        [switch]$ApproveUpdate
    )
    Assert-ApprovedOwnerV2ApprovalCurrent -Evidence $Evidence -Approval $Approval
    if (@($Approval.selections | Where-Object {
                [string]$_.classification -ceq 'wouldUpdate'
            }).Count -gt 0 -and
        (-not [bool]$Approval.approveUpdate -or -not $ApproveUpdate)) {
        throw 'Approved updates require signed approval and runtime -ApproveUpdate.'
    }
    $initial = & $Provider 'ReadCurrent' @{
        evidence = $Evidence
        operator = $Approval.operator
        selections = @($Approval.selections)
    }
    $expectedSnapshot = [string]$Approval.discussion.snapshotSha256
    $liveState = Assert-ApprovedOwnerV2LiveRead -Evidence $Evidence `
        -Approval $Approval -Live $initial -Selections @($Approval.selections) `
        -ExpectedSnapshotSha256 $expectedSnapshot
    $repaired = Repair-ApprovedOwnerV2Audits -ApprovalRoot $ApprovalRoot `
        -Key $Key -Provider $Provider -Evidence $Evidence -Approval $Approval
    $invocationId = [guid]::NewGuid().ToString('N')
    $intent = [ordered]@{
        schemaVersion = 1
        kind = 'owner-v2-comment-intent'
        invocationId = $invocationId
        stateIdentity = [string]$Approval.state.identity
        resultDigest = [string]$Approval.state.resultDigest
        publish = [bool]$Publish
        approveUpdate = [bool]$ApproveUpdate
        operator = $Approval.operator
        reason = [string]$Approval.reason
        initialDiscussionSha256 = $expectedSnapshot
        selections = @($Approval.selections)
        createdUtc = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    }
    $intentPath = Write-ApprovedOwnerV2Audit -ApprovalRoot $ApprovalRoot `
        -Phase intents -InvocationId $invocationId -Payload $intent -Key $Key
    $writes = 0
    $results = [Collections.Generic.List[object]]::new()
    try {
        foreach ($selection in @($Approval.selections)) {
            $classification = [string]$liveState.Classifications[
                [string]$selection.findingId]
            if (-not $Publish) {
                [void]$results.Add([ordered]@{
                        findingId = [string]$selection.findingId
                        outcome = $classification
                        marker = [string]$selection.marker
                        bodySha256 = [string]$selection.bodySha256
                        providerWrites = 0
                    })
                continue
            }

            Assert-ApprovedOwnerV2ApprovalCurrent -Evidence $Evidence -Approval $Approval
            $fresh = & $Provider 'ReadCurrent' @{
                evidence = $Evidence
                operator = $Approval.operator
                selections = @($selection)
            }
            $freshState = Assert-ApprovedOwnerV2LiveRead -Evidence $Evidence `
                -Approval $Approval -Live $fresh -Selections @($selection) `
                -ExpectedSnapshotSha256 $expectedSnapshot
            $classification = [string]$freshState.Classifications[
                [string]$selection.findingId]
            if ($classification -ceq 'noOp') {
                [void]$results.Add([ordered]@{
                        findingId = [string]$selection.findingId
                        outcome = 'noOp'
                        marker = [string]$selection.marker
                        bodySha256 = [string]$selection.bodySha256
                        providerWrites = 0
                    })
                continue
            }
            if ($classification -ceq 'wouldUpdate') {
                if (-not [bool]$Approval.approveUpdate -or -not $ApproveUpdate) {
                    throw "Finding '$($selection.findingId)' requires explicit update approval."
                }
                $entries = @(Get-ApprovedOwnerV2MarkerEntries `
                        -Snapshot $fresh.Snapshot -Marker ([string]$selection.marker))
                if ($entries.Count -ne 1 -or
                    -not [bool]$entries[0].Comment.reviewerOwned) {
                    throw "Finding '$($selection.findingId)' update target is missing or ambiguous."
                }
                & $Provider 'UpdateComment' @{
                    evidence = $Evidence
                    operator = $Approval.operator
                    selection = $selection
                    threadId = [long]$entries[0].Thread.threadId
                    commentId = [long]$entries[0].Comment.commentId
                } | Out-Null
            }
            elseif ($classification -ceq 'wouldCreate') {
                $anchor = @($freshState.Anchors | Where-Object {
                        [string]$_.path -ieq [string]$selection.path -and
                        [int]$selection.line -ge [int]$_.startLine -and
                        [int]$selection.line -le [int]$_.endLine
                    })[0]
                & $Provider 'CreateThread' @{
                    evidence = $Evidence
                    operator = $Approval.operator
                    selection = $selection
                    anchor = $anchor
                } | Out-Null
            }
            else {
                throw "Finding '$($selection.findingId)' is no longer actionable."
            }
            $writes++
            $confirmed = & $Provider 'ReadCurrent' @{
                evidence = $Evidence
                operator = $Approval.operator
                selections = @($selection)
            }
            $entries = @(Get-ApprovedOwnerV2MarkerEntries `
                    -Snapshot $confirmed.Snapshot -Marker ([string]$selection.marker))
            if (@($entries | Where-Object {
                        [bool]$_.Comment.reviewerOwned -and
                        [string]$_.Comment.body -ceq [string]$selection.body -and
                        -not [bool]$_.Comment.isDeleted
                    }).Count -ne 1) {
                throw "Provider write for '$($selection.findingId)' was not confirmed by readback."
            }
            $expectedSnapshot = ([string]$confirmed.Snapshot.Digest).Substring(10)
            $liveState = Assert-ApprovedOwnerV2LiveRead -Evidence $Evidence `
                -Approval $Approval -Live $confirmed -Selections @($selection) `
                -ExpectedSnapshotSha256 $expectedSnapshot
            [void]$results.Add([ordered]@{
                    findingId = [string]$selection.findingId
                    outcome = $(if ($classification -ceq 'wouldUpdate') {
                            'updated'
                        }
                        else { 'created' })
                    marker = [string]$selection.marker
                    bodySha256 = [string]$selection.bodySha256
                    providerWrites = 1
                })
        }
        $outcome = [ordered]@{
            schemaVersion = 1
            kind = 'owner-v2-comment-outcome'
            invocationId = $invocationId
            stateIdentity = [string]$Approval.state.identity
            status = 'completed'
            providerWrites = $writes
            finalDiscussionSha256 = $expectedSnapshot
            results = $results.ToArray()
            createdUtc = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
        }
        $outcomePath = Write-ApprovedOwnerV2Audit -ApprovalRoot $ApprovalRoot `
            -Phase outcomes -InvocationId $invocationId -Payload $outcome -Key $Key
        return [pscustomobject][ordered]@{
            mode = $(if ($Publish) { 'publish' } else { 'dryRun' })
            providerWrites = $writes
            intentPath = $intentPath
            outcomePath = $outcomePath
            repairedAudits = @($repaired)
            results = $results.ToArray()
        }
    }
    catch {
        $failure = [ordered]@{
            schemaVersion = 1
            kind = 'owner-v2-comment-outcome'
            invocationId = $invocationId
            stateIdentity = [string]$Approval.state.identity
            status = 'failed'
            providerWrites = $writes
            diagnostic = [string]$_.Exception.Message
            results = $results.ToArray()
            createdUtc = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
        }
        [void](Write-ApprovedOwnerV2Audit -ApprovalRoot $ApprovalRoot `
                -Phase outcomes -InvocationId $invocationId -Payload $failure -Key $Key)
        throw
    }
}

function Set-ApprovedOwnerV2CommentPresentation {
    param(
        [Parameter(Mandatory)][object]$Contract,
        [Parameter(Mandatory)][Collections.IDictionary]$Observation,
        [Parameter(Mandatory)][Collections.IDictionary]$ToolkitConfig
    )
    $delivery = 'owner'
    Assert-OwnerCommentRuleReferences -References $ToolkitConfig['commentRuleReferences'] `
        -Repository $ToolkitConfig['commentRuleRepository'] -Delivery $delivery
    $artifacts = @($Observation.sourceArtifacts | Where-Object {
        [string](Get-ApprovedOwnerV2Value $_ 'kind' '') -ceq
            'owner-v2-comment-presentation'
    })
    if ($artifacts.Count -eq 0) { return }
    if ($artifacts.Count -ne 1 -or
        [string]$artifacts[0].sha256 -cne (
            Get-ApprovedOwnerV2TextSha256 'owner-v2-comment-presentation:subject-provider-links-v1') -or
        [string]$artifacts[0].signature -cne 'not-applicable') {
        throw 'Owner v2 observation has an unknown or ambiguous comment presentation mode.'
    }
    $Contract | Add-Member -NotePropertyName CommentPresentation `
        -NotePropertyValue ([ordered]@{
            subjectProvider = $ToolkitConfig.subjectProvider
            ruleReferences = $ToolkitConfig['commentRuleReferences']
            ruleRepository = $ToolkitConfig['commentRuleRepository']
        })
}
