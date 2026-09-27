#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\..\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1"
Import-Module "$PSScriptRoot\..\DevPilot.ActivePrIntake\DevPilot.ActivePrIntake.psd1"
Import-Module "$PSScriptRoot\..\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1"
Import-Module "$PSScriptRoot\..\DevPilot.OwnerOrchestrator\DevPilot.OwnerOrchestrator.psd1"

$script:OwnerRuleCommit = 'f6db83436b48f48a8521095a888d79f67823bbb2'
$script:OwnerRulePath = 'documentation/EngineeringProcesses/Conventions/AutomatedTests.md'
$script:OwnerRuleHash = 'v1:sha256:bc31bfea6b378dffe4a1b28475dc1cac4cd3ee1ab793db57895446ded829ab2f'
$script:OwnerRuleSection = '## Claim ownership'
$script:OwnerCapability = 'bpm-test-ownership@1'
$script:OwnerAdapterMaterial = 'owner-acquisition-v1|ordinal-paths|complete-pages|subject-race|rule-and-file-byte-cap|explicit-unknown-reasons|expected-replay-payload-digest'

function Get-ActiveOwnerHash {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return 'v1:sha256:' + [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-ActiveOwnerTextHash {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return Get-ActiveOwnerHash -Bytes ([Text.Encoding]::UTF8.GetBytes($Text))
}

function Get-ActiveOwnerJsonHash {
    param($Value)
    return Get-ActiveOwnerTextHash (ConvertTo-Json -InputObject $Value -Depth 32 -Compress)
}

function New-ActiveOwnerUnknown {
    param($Declaration, $RuleDeclaration,
        [string]$DeclarationDigest, [string]$Reason, [string]$ManifestDigest = $null)
    return @{
        state = 'unknown'; reason = $Reason; findings = 0; unknown = 1
        completed = $false; providerWrites = 0; writeToolInvocations = 0
        modelToolInvocations = 0; manifestEntryCount = 1
        manifestDigest = $ManifestDigest
        intakeGeneration = [string]$RuleDeclaration.intakeGeneration
        declarationDigest = $DeclarationDigest
        sourceCommit = [string]$Declaration.sourceCommit
        targetCommit = [string]$Declaration.targetCommit
        targetRef = [string]$Declaration.targetRef
        iterationId = $Declaration.iterationId
        ruleId = [string]$RuleDeclaration.ruleId
    }
}

function New-ActiveOwnerPackage {
    param([Collections.IDictionary]$Declaration, [object[]]$Files,
        [Collections.IDictionary]$LineEvidence, [Collections.IDictionary]$Binding,
        [string]$RuleText)
    $base = [ordered]@{
        schemaVersion = 1
        repositoryId = [string]$Declaration.repositoryId
        projectId = [string]$Declaration.projectId
        pullRequestId = [long]$Declaration.pullRequestId
        sourceCommit = [string]$Declaration.sourceCommit
        targetCommit = [string]$Declaration.targetCommit
        targetRef = [string]$Declaration.targetRef
    }
    $proofs = @($LineEvidence.files)
    if ($proofs.Count -gt 64 -or
        [int]$LineEvidence.changedFiles -ne $proofs.Count -or
        @($proofs | Where-Object changeType -CEQ 'delete').Count +
            $Files.Count -ne $proofs.Count) {
        throw 'changed-lines-mismatch'
    }
    $changes = [Collections.Generic.List[object]]::new()
    $responses = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $Files) {
        if ($file -isnot [Collections.IDictionary] -or
            [string]$file.path -cnotmatch '^/[^?#\x00-\x1f]{1,2048}$' -or
            $file.content -isnot [string] -or
            -not $seen.Add([string]$file.path)) { throw 'source-unverified' }
        $pathDigest = (Get-ActiveOwnerJsonHash ([string]$file.path)).Substring(10)
        $matchedProofs = @($proofs | Where-Object pathDigest -CEQ $pathDigest)
        if ($matchedProofs.Count -ne 1 -or
            $matchedProofs[0].changeType -cnotin @('add', 'edit', 'rename')) {
            throw 'changed-lines-mismatch'
        }
        $proof = $matchedProofs[0]
        if ((Get-ActiveOwnerJsonHash @($file.spans)) -cne
            (Get-ActiveOwnerJsonHash @($proof.spans))) { throw 'changed-lines-mismatch' }
        $path = ([string]$file.path).TrimStart('/')
        $spans = @(
            foreach ($span in @($file.spans)) {
                $start = [int]$span.startLine; $end = [int]$span.endLine
                if ($start -lt 1 -or $end -lt $start) { throw 'changed-lines-mismatch' }
                [ordered]@{ startLine = $start; endLine = $end; state = 'complete'
                    sourceDigest = Get-ActiveOwnerJsonHash @($path, $start, $end) }
            }
        )
        $content = [string]$file.content
        $change = [ordered]@{
            path = $path
            changeType = switch ([string]$proof.changeType) {
                'add' { 'added' } 'rename' { 'renamed' } default { 'modified' }
            }
            isBinary = $false
            sourceDigest = Get-ActiveOwnerTextHash $content
            spans = $spans
        }
        if ($proof.changeType -ceq 'rename') {
            # The intake digest does not expose the old path, so a rename is not safe to evaluate.
            throw 'rename-source-unavailable'
        }
        [void]$changes.Add($change)
        [void]$responses.Add(([ordered]@{} + $base + [ordered]@{
            path = $path; state = 'complete'
            byteLength = [Text.Encoding]::UTF8.GetByteCount($content)
            truncated = $false; content = $content
            sourceDigest = Get-ActiveOwnerTextHash $content
        }))
    }
    foreach ($proof in $proofs | Where-Object changeType -CEQ 'delete') {
        if ([string]$proof.pathDigest -cnotmatch '^[a-f0-9]{64}$') {
            throw 'changed-lines-mismatch'
        }
        # A deletion has no dispatcher-supplied path; do not fabricate a changed-file identity.
        throw 'deleted-path-unavailable'
    }
    $subject = [ordered]@{} + $base + [ordered]@{
        changedFileCount = $Files.Count; state = 'complete'
        sourceDigest = Get-ActiveOwnerJsonHash @($base, $LineEvidence)
    }
    $page = [ordered]@{} + $base + [ordered]@{
        pageOrdinal = 0; continuationToken = $null; nextToken = $null
        state = 'complete'; sourceDigest = Get-ActiveOwnerJsonHash @($changes)
        changes = @($changes.ToArray())
    }
    $rule = [ordered]@{} + $base + [ordered]@{
        ruleRepositoryId = [string]$Binding.ruleRepositoryId
        rulePath = [string]$Binding.rulePath
        ruleCommit = [string]$Binding.ruleCommit
        ruleSection = [string]$Binding.ruleSection
        ruleHash = [string]$Binding.ruleHash
        ruleLength = [long]$Binding.ruleLength
        state = 'complete'; content = $RuleText
        sourceDigest = Get-ActiveOwnerTextHash $RuleText
    }
    return [ordered]@{
        schemaVersion = 1; semantics = 'owner-acquisition-v1'
        contractDigest = Get-ActiveOwnerTextHash $script:OwnerAdapterMaterial
        subjectBefore = $subject; changePages = @($page); rule = $rule
        files = @($responses.ToArray()); subjectAfter = $subject
    }
}

function Get-ActiveOwnerDurableProof {
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$ManifestRoot,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [Parameter(Mandatory)][string]$Identity,
        [Parameter(Mandatory)][string]$ManifestDigest,
        [Parameter(Mandatory)][string]$PayloadDigest,
        [Parameter(Mandatory)][Collections.IDictionary]$ManifestEntry,
        [Parameter(Mandatory)][Collections.IDictionary]$Observation
    )
    $recordPath = Join-Path $CapabilityRoot "records\$Identity.json"
    $declarationPath = Join-Path $CapabilityRoot "declarations\$Identity.json"
    $observationPath = Join-Path $CapabilityRoot "observations\$Identity.json"
    foreach ($path in @($recordPath, $declarationPath, $observationPath)) {
        [void](Assert-AgentTrustedFile -Path $path -AllowedRoot $CapabilityRoot)
    }
    [void](Assert-AgentTrustedFile -Path $ManifestPath -AllowedRoot $ManifestRoot)
    $manifestBytes = [IO.File]::ReadAllBytes($ManifestPath)
    $recordBytes = [IO.File]::ReadAllBytes($recordPath)
    $declarationBytes = [IO.File]::ReadAllBytes($declarationPath)
    $observationBytes = [IO.File]::ReadAllBytes($observationPath)
    $savedManifest = [Text.UTF8Encoding]::new($false, $true).GetString($manifestBytes) |
        ConvertFrom-Json -AsHashtable -Depth 64
    $record = [Text.UTF8Encoding]::new($false, $true).GetString($recordBytes) |
        ConvertFrom-Json -AsHashtable -Depth 64
    $ownerDeclaration = [Text.UTF8Encoding]::new($false, $true).GetString($declarationBytes) |
        ConvertFrom-Json -AsHashtable -Depth 64
    $savedObservation = [Text.UTF8Encoding]::new($false, $true).GetString($observationBytes) |
        ConvertFrom-Json -AsHashtable -Depth 64
    $declarationBody = [ordered]@{}
    foreach ($key in @($ownerDeclaration.Keys)) {
        if ($key -cnotin @('stateDigest', 'facadeBinding')) {
            $declarationBody[[string]$key] = $ownerDeclaration[$key]
        }
    }
    $stateDigest = 'v1:sha256:' + (Get-AgentCanonicalDigest -InputObject $declarationBody)
    $computedManifestDigest = 'v1:sha256:' + (Get-AgentCanonicalDigest -InputObject (
            [ordered]@{
                schemaVersion = 1; kind = 'owner-v2-preview-cohort'
                entries = @($ownerDeclaration)
            }))
    if ($savedManifest.schemaVersion -ne 1 -or
        $savedManifest.kind -cne 'owner-v2-preview-cohort' -or
        @($savedManifest.entries).Count -ne 1 -or
        (Get-AgentCanonicalDigest -InputObject $savedManifest.entries[0]) -cne
            (Get-AgentCanonicalDigest -InputObject $ManifestEntry) -or
        $computedManifestDigest -cne $ManifestDigest -or
        [string]$ownerDeclaration.stateDigest -cne $stateDigest -or
        $Identity -cne $stateDigest.Substring(10) -or
        [string]$ownerDeclaration.mode -cne 'live' -or
        [string]$ownerDeclaration.acquisitionPayloadDigest -cne $PayloadDigest -or
        [string]$ownerDeclaration.rule.hash -cne $script:OwnerRuleHash -or
        [string]$ownerDeclaration.rule.commit -cne $script:OwnerRuleCommit -or
        [string]$ownerDeclaration.rule.path -cne $script:OwnerRulePath -or
        [string]$ownerDeclaration.rule.section -cne $script:OwnerRuleSection) {
        throw 'owner-declaration-integrity-failure'
    }
    $bindings = [ordered]@{
        subjectDigest = $ownerDeclaration.subject
        headDigest = $ownerDeclaration.head
        ruleDigest = $ownerDeclaration.rule
        modelDigest = $ownerDeclaration.model
        configDigest = $ownerDeclaration.config
    }
    foreach ($key in $bindings.Keys) {
        if ([string]$record[$key] -cne ('v1:sha256:' +
                (Get-AgentCanonicalDigest -InputObject $bindings[$key]))) {
            throw 'owner-record-binding-failure'
        }
    }
    $observationDigest = 'v1:sha256:' +
        (Get-AgentCanonicalDigest -InputObject $savedObservation)
    if ($record.schemaVersion -ne 2 -or
        $record.kind -cne 'owner-v2-preview-record' -or
        $record.state -cne 'completed' -or
        $record.mode -cne 'live' -or
        $null -ne $record.lease -or
        [int]$record.attempts -lt 1 -or
        [int]$record.attempts -gt [int]$record.maxAttempts -or
        [string]$record.identity -cne $Identity -or
        [string]$record.stateDigest -cne $stateDigest -or
        [string]$record.acquisitionPayloadDigest -cne $PayloadDigest -or
        [string]$record.capabilityId -cne [string]$ManifestEntry.capability.id -or
        [string]$record.capabilityDigest -cne
            [string]$ManifestEntry.capability.digest -or
        [string]$record.declarationPath -cne "declarations/$Identity.json" -or
        [string]$record.observationPath -cne "observations/$Identity.json" -or
        [string]$record.evidencePath -cne "evidence/$Identity.json" -or
        [string]$record.resultDigest -cne $observationDigest -or
        (Get-AgentCanonicalDigest -InputObject $savedObservation) -cne
            (Get-AgentCanonicalDigest -InputObject $Observation)) {
        throw 'owner-observation-integrity-failure'
    }
    if (-not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
            $recordBytes, [IO.File]::ReadAllBytes($recordPath)) -or
        -not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
            $observationBytes, [IO.File]::ReadAllBytes($observationPath))) {
        throw 'owner-durable-proof-raced'
    }
    return [ordered]@{
        manifestPath = $ManifestPath
        manifestFileDigest = Get-ActiveOwnerHash $manifestBytes
        declarationPath = $declarationPath
        declarationFileDigest = Get-ActiveOwnerHash $declarationBytes
        recordPath = $recordPath
        recordFileDigest = Get-ActiveOwnerHash $recordBytes
        observationPath = $observationPath
        observationFileDigest = Get-ActiveOwnerHash $observationBytes
        observationDigest = $observationDigest
        identity = $Identity
        stateDigest = $stateDigest
        acquisitionPayloadDigest = $PayloadDigest
    }
}

# RawDiscussions is the dispatcher's already-read @{ count; threads } response;
# $discussion is its verified aggregate, not a source of raw threads.
function New-ActiveOwnerEvaluator {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [AllowNull()][byte[]]$RuleBytes,
        [AllowNull()][Collections.IDictionary]$ReviewerIdentity,
        [AllowNull()][Collections.IDictionary]$IntakeConfig,
        [switch]$EnableLiveModel,
        [AllowNull()][object]$LiveModelProvider,
        [AllowNull()][string]$LiveModel,
        [ValidateSet('COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')]
        [AllowNull()][string]$LiveCredentialEnvironmentName,
        [ValidateRange(1, 8)][int]$MaxAttempts = 3,
        [ValidateRange(1, 86400)][int]$LeaseSeconds = 300
    )
    $parameters = @{
        StateRoot = $StateRoot; RuleBytes = $RuleBytes
        ReviewerIdentity = $ReviewerIdentity; IntakeConfig = $IntakeConfig
        EnableLiveModel = [bool]$EnableLiveModel
        LiveModelProvider = $LiveModelProvider; LiveModel = $LiveModel
        MaxAttempts = $MaxAttempts; LeaseSeconds = $LeaseSeconds
    }
    if (-not [string]::IsNullOrWhiteSpace($LiveCredentialEnvironmentName)) {
        $parameters.LiveCredentialEnvironmentName = $LiveCredentialEnvironmentName
    }
    $invoke = ${function:Invoke-ActiveOwnerEvaluation}
    return {
        param($declaration, $files, $discussion, $lineEvidence, $generation,
            $ruleConfig, $ruleDeclaration, $declarationDigest, $rawDiscussions)
        & $invoke -Declaration $declaration -Files $files -Discussion $discussion `
            -LineEvidence $lineEvidence -Generation $generation `
            -RuleConfig $ruleConfig -RuleDeclaration $ruleDeclaration `
            -DeclarationDigest $declarationDigest -RawDiscussions $rawDiscussions `
            @parameters
    }.GetNewClosure()
}

function Invoke-ActiveOwnerEvaluation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Declaration,
        [Parameter(Mandatory)][object[]]$Files,
        [Parameter(Mandatory)][Collections.IDictionary]$Discussion,
        [Parameter(Mandatory)][Collections.IDictionary]$LineEvidence,
        [Parameter(Mandatory)][string]$Generation,
        [Parameter(Mandatory)][Collections.IDictionary]$RuleConfig,
        [Parameter(Mandatory)][Collections.IDictionary]$RuleDeclaration,
        [Parameter(Mandatory)][string]$DeclarationDigest,
        [AllowNull()][Collections.IDictionary]$RawDiscussions,
        [Parameter(Mandatory)][string]$StateRoot,
        [AllowNull()][byte[]]$RuleBytes,
        [AllowNull()][Collections.IDictionary]$ReviewerIdentity,
        [AllowNull()][Collections.IDictionary]$IntakeConfig,
        [switch]$EnableLiveModel,
        [AllowNull()][object]$LiveModelProvider,
        [AllowNull()][string]$LiveModel,
        [ValidateSet('COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')]
        [AllowNull()][string]$LiveCredentialEnvironmentName,
        [ValidateRange(1, 8)][int]$MaxAttempts = 3,
        [ValidateRange(1, 86400)][int]$LeaseSeconds = 300
    )
    $unknown = {
        param($reason, $digest)
        New-ActiveOwnerUnknown -Declaration $Declaration -RuleDeclaration $RuleDeclaration `
            -DeclarationDigest $DeclarationDigest `
            -Reason $reason -ManifestDigest $digest
    }
    $binding = $RuleConfig.binding
    if ($binding -isnot [Collections.IDictionary] -or
        $RuleDeclaration.ruleBinding -isnot [Collections.IDictionary] -or
        [string]$RuleConfig.capabilityId -cne $script:OwnerCapability -or
        [string]$RuleConfig.ruleId -cne 'mstest-owner' -or
        [string]$RuleDeclaration.ruleId -cne 'mstest-owner' -or
        [string]$RuleDeclaration.capabilityId -cne $script:OwnerCapability -or
        [string]$binding.rulePath -cne $script:OwnerRulePath -or
        [string]$binding.ruleCommit -cne $script:OwnerRuleCommit -or
        [string]$binding.ruleSection -cne $script:OwnerRuleSection -or
        [string]$binding.ruleHash -cne $script:OwnerRuleHash -or
        [string]$binding.ruleRepositoryId -cnotmatch '^[A-Za-z0-9._/-]{1,256}$' -or
        [string]$binding.capabilityDigest -cnotmatch '^v1:sha256:[a-f0-9]{64}$' -or
        [long]$binding.ruleLength -lt 1 -or [long]$binding.ruleLength -gt 65536) {
        return & $unknown 'owner-rule-binding-unavailable' $null
    }
    foreach ($key in @('ruleRepositoryId', 'rulePath', 'ruleCommit', 'ruleSection',
            'ruleHash', 'ruleLength', 'capabilityDigest')) {
        if ([string]$RuleDeclaration.ruleBinding[$key] -cne [string]$binding[$key]) {
            return & $unknown 'owner-rule-binding-unavailable' $null
        }
    }
    $modelBinding = $RuleConfig.model
    if ($modelBinding -isnot [Collections.IDictionary] -or
        $modelBinding.Count -ne 2 -or
        -not $modelBinding.Contains('id') -or
        -not $modelBinding.Contains('digest') -or
        [string]$modelBinding.id -cnotmatch '^[a-zA-Z0-9_.-]{1,128}$' -or
        [string]$modelBinding.digest -cne
            (Get-ActiveOwnerTextHash ([string]$modelBinding.id)) -or
        [string]$RuleDeclaration.model.id -cne [string]$modelBinding.id -or
        [string]$RuleDeclaration.model.digest -cne [string]$modelBinding.digest) {
        return & $unknown 'owner-model-binding-unavailable' $null
    }
    if ($RuleDeclaration.sourceCommit -cne $Declaration.sourceCommit -or
        $RuleDeclaration.targetCommit -cne $Declaration.targetCommit -or
        $RuleDeclaration.targetRef -cne $Declaration.targetRef -or
        $RuleDeclaration.iterationId -ne $Declaration.iterationId -or
        $LineEvidence.generation -cne $RuleDeclaration.intakeGeneration -or
        $LineEvidence.declarationDigest -cne $RuleDeclaration.intakeDeclarationDigest -or
        $RuleDeclaration.generation -cne $Generation -or
        [long]$RuleDeclaration.pullRequestId -ne [long]$Declaration.pullRequestId -or
        [string]$DeclarationDigest -cnotmatch '^[a-f0-9]{64}$' -or
        [string]$Generation -cnotmatch '^[a-f0-9]{32}$' -or
        [string]$RuleDeclaration.configDigest -cnotmatch '^[a-f0-9]{64}$' -or
        (Get-ActiveOwnerJsonHash $LineEvidence).Substring(10) -cne
            [string]$RuleDeclaration.lineEvidenceDigest -or
        (Get-ActiveOwnerJsonHash $Declaration).Substring(10) -cne
            [string]$RuleDeclaration.intakeDeclarationDigest -or
        (Get-ActiveOwnerTextHash (ConvertTo-Json -InputObject $RuleDeclaration -Depth 16)).Substring(10) -cne
            $DeclarationDigest) {
        return & $unknown 'owner-head-binding-mismatch' $null
    }
    if ($null -eq $RuleBytes -or $RuleBytes.Length -ne [long]$binding.ruleLength -or
        (Get-ActiveOwnerHash $RuleBytes) -cne $script:OwnerRuleHash) {
        return & $unknown 'owner-rule-bytes-unavailable' $null
    }
    if (-not $EnableLiveModel -or
        ($null -eq $LiveModelProvider -and
            ([string]::IsNullOrWhiteSpace($LiveModel) -or
                [string]::IsNullOrWhiteSpace($LiveCredentialEnvironmentName)))) {
        return & $unknown 'live-model-disabled-or-unavailable' $null
    }
    $modelId = if ($null -ne $LiveModelProvider) {
        [string]$LiveModelProvider.ModelIdentity
    } else { [string]$LiveModel }
    if ($modelId -cne [string]$modelBinding.id -or
        ($null -ne $LiveModelProvider -and
            -not [string]::IsNullOrEmpty([string]$LiveModel) -and
            [string]$LiveModel -cne $modelId)) {
        return & $unknown 'owner-model-binding-mismatch' $null
    }
    if ($null -eq $ReviewerIdentity -or
        $ReviewerIdentity.id -cnotmatch '^[0-9a-fA-F-]{36}$' -or
        [string]::IsNullOrWhiteSpace([string]$ReviewerIdentity.descriptor) -or
        [string]::IsNullOrWhiteSpace([string]$ReviewerIdentity.uniqueName)) {
        return & $unknown 'reviewer-identity-unavailable' $null
    }
    if ($null -eq $IntakeConfig -or $null -eq $RawDiscussions) {
        return & $unknown 'discussion-evidence-unavailable' $null
    }
    if ([string]$ReviewerIdentity.id -cne [string]$IntakeConfig.expectedAccount.id -or
        [string]$ReviewerIdentity.descriptor -cne
            [string]$IntakeConfig.expectedAccount.descriptor -or
        [string]$ReviewerIdentity.uniqueName -cne
            [string]$IntakeConfig.expectedAccount.uniqueName) {
        return & $unknown 'reviewer-identity-unavailable' $null
    }
    try {
        $ruleText = [Text.UTF8Encoding]::new($false, $true).GetString($RuleBytes)
        if (-not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
                $RuleBytes, [Text.Encoding]::UTF8.GetBytes($ruleText))) {
            throw 'noncanonical-rule-bytes'
        }
        $package = New-ActiveOwnerPackage -Declaration $Declaration -Files $Files `
            -LineEvidence $LineEvidence -Binding $binding -RuleText $ruleText
        $digest = (New-OwnerReplayFixture -Package $package).PayloadDigest
        $manifest = [ordered]@{
            schemaVersion = 1; kind = 'owner-v2-preview-cohort'
            entries = @([ordered]@{
                id = 'owner-' + $DeclarationDigest.Substring(0, 24)
                mode = 'live'
                subject = [ordered]@{
                    repositoryId = [string]$Declaration.repositoryId
                    projectId = [string]$Declaration.projectId
                    pullRequestId = [long]$Declaration.pullRequestId
                }
                head = [ordered]@{ sourceCommit = [string]$Declaration.sourceCommit }
                target = [ordered]@{
                    targetCommit = [string]$Declaration.targetCommit
                    targetRef = [string]$Declaration.targetRef
                }
                rule = [ordered]@{
                    repositoryId = [string]$binding.ruleRepositoryId
                    path = $script:OwnerRulePath; commit = $script:OwnerRuleCommit
                    section = $script:OwnerRuleSection; hash = $script:OwnerRuleHash
                    length = [long]$binding.ruleLength
                }
                capability = [ordered]@{ id = $script:OwnerCapability
                    digest = [string]$binding.capabilityDigest }
                model = [ordered]@{
                    id = [string]$modelBinding.id
                    digest = [string]$modelBinding.digest
                }
                config = [ordered]@{ id = 'bounded-rule-evaluation-v1'
                    digest = 'v1:sha256:' + [string]$RuleDeclaration.configDigest }
                acquisition = [ordered]@{ payloadDigest = $digest }
            })
        }
        $reviewer = New-OwnerAzureDevOpsReviewerIdentity `
            -Id ([string]$ReviewerIdentity.id) `
            -Descriptor ([string]$ReviewerIdentity.descriptor) `
            -UniqueName ([string]$ReviewerIdentity.uniqueName)
        if ($RawDiscussions.threads -isnot [array]) {
            throw 'discussion-acquisition-unavailable'
        }
        $verifiedCounts = Get-ActivePrDiscussionCounts -Response $RawDiscussions `
            -Config $IntakeConfig -Head $Declaration
        if ((Get-ActiveOwnerJsonHash $verifiedCounts) -cne
            (Get-ActiveOwnerJsonHash $Discussion)) {
            throw 'discussion-head-mismatch'
        }
        $rawCopy = ConvertFrom-Json -AsHashtable -Depth 64 -InputObject (
            ConvertTo-Json -InputObject $RawDiscussions -Depth 64 -Compress)
        $raw = [ordered]@{ count = [int]$rawCopy.count
            value = @($rawCopy.threads) }
        $currentIteration = [ordered]@{
            id = [int]$Declaration.iterationId
            sourceCommit = [string]$Declaration.sourceCommit
            targetCommit = [string]$Declaration.targetCommit
        }
        $convert = Get-Command ConvertTo-OwnerAzureDevOpsDiscussionPage
        $captured = $package
        $handler = {
            param($operation, $arguments)
            switch -CaseSensitive ($operation) {
                'GetSubject' { return $captured.subjectBefore }
                'GetChangedFilesPage' {
                    if ([int]$arguments.pageOrdinal -ne 0 -or
                        $null -ne $arguments.continuationToken) { throw 'unexpected-page' }
                    return $captured.changePages[0]
                }
                'GetRule' { return $captured.rule }
                'GetFile' {
                    $matchedFiles = @($captured.files |
                        Where-Object path -CEQ $arguments.path)
                    if ($matchedFiles.Count -ne 1) { throw 'unexpected-file' }
                    return $matchedFiles[0]
                }
                'GetDiscussionPage' {
                    return & $convert -Arguments $arguments -RawResponse $raw `
                        -CurrentIteration $currentIteration -ReviewerIdentity $reviewer
                }
                default { throw 'read-operation-not-authorized' }
            }
        }.GetNewClosure()
        $provider = New-OwnerAzureDevOpsReadOnlyProviderAdapter `
            -Name 'active-owner-read-only' -ReviewerIdentity $reviewer -Handler $handler
        $contract = New-OwnerAcquisitionContract `
            -RepositoryId ([string]$Declaration.repositoryId) `
            -ProjectId ([string]$Declaration.projectId) `
            -PullRequestId ([long]$Declaration.pullRequestId) `
            -SourceCommit ([string]$Declaration.sourceCommit) `
            -TargetCommit ([string]$Declaration.targetCommit) `
            -TargetRef ([string]$Declaration.targetRef) `
            -RuleRepositoryId ([string]$binding.ruleRepositoryId) `
            -RulePath $script:OwnerRulePath -RuleCommit $script:OwnerRuleCommit `
            -RuleSection $script:OwnerRuleSection -RuleHash $script:OwnerRuleHash `
            -RuleLength ([long]$binding.ruleLength) `
            -ConfigId 'bounded-rule-evaluation-v1' `
            -ConfigDigest ('v1:sha256:' + [string]$RuleDeclaration.configDigest) `
            -CapabilityId $script:OwnerCapability `
            -CapabilityDigest ([string]$binding.capabilityDigest) `
            -Limits (New-OwnerAdapterLimits -MaximumFiles 64 `
                -MaximumBytes 16777216 -MaximumReads 128)
        $snapshot = Get-OwnerDiscussionSnapshot -Contract $contract -Provider $provider `
            -Limits (New-OwnerDiscussionLimits -MaximumPages 20 -PageSize 100 `
                -MaximumThreads 1000 -MaximumComments 5000 -MaximumBytes 4194304) `
            -RequireAzureDevOpsProvenance
        if ($snapshot.CurrentIterationId -ne [int]$Declaration.iterationId -or
            $snapshot.ThreadCount -ne $raw.count) {
            throw 'discussion-head-mismatch'
        }
        $state = Join-Path $StateRoot 'active-owner-evaluation-v1'
        if (-not [IO.Path]::IsPathFullyQualified($StateRoot)) {
            throw 'state-root-untrusted'
        }
        $manifestRoot = Join-Path $state 'manifests'
        $null = Resolve-AgentTrustedRoot -Path $manifestRoot -Kind durable-state `
            -RepositoryRoot ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))) -Create
        $manifestPath = Join-Path $manifestRoot (
            "$($Generation)-$($DeclarationDigest).json")
        $manifestBytes = [Text.Encoding]::UTF8.GetBytes(
            (ConvertTo-Json -InputObject $manifest -Depth 16 -Compress) + "`n")
        if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            if (-not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
                    [IO.File]::ReadAllBytes($manifestPath), $manifestBytes)) {
                throw 'immutable-manifest-mismatch'
            }
        } else {
            $stream = [IO.File]::Open($manifestPath, [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $stream.Write($manifestBytes); $stream.Flush($true) }
            finally { $stream.Dispose() }
        }
        $prepared = Invoke-OwnerV2PreviewPrepare -StateRoot $state `
            -ManifestPath $manifestPath -MaxAttempts $MaxAttempts
        if (@($prepared.records).Count -ne 1) { throw 'manifest-entry-count' }
        $runParameters = @{
            StateRoot = $state; ManifestPath = $manifestPath
            LeaseSeconds = $LeaseSeconds; EnableLiveModel = $true
            LiveAcquisitionProvider = $provider
            LiveModelProvider = $LiveModelProvider; LiveModel = $LiveModel
        }
        if (-not [string]::IsNullOrWhiteSpace($LiveCredentialEnvironmentName)) {
            $runParameters.LiveCredentialEnvironmentName =
                $LiveCredentialEnvironmentName
        }
        $run = Invoke-OwnerV2PreviewRun @runParameters
        $record = $prepared.records[0]
        $recordPath = Join-Path $record.capabilityRoot "records\$($record.identity).json"
        $observationPath = Join-Path $record.capabilityRoot "observations\$($record.identity).json"
        $telemetryPath = Join-Path $record.capabilityRoot "telemetry\$($record.identity).json"
        $persisted = Get-Content -LiteralPath $recordPath -Raw |
            ConvertFrom-Json -AsHashtable -Depth 64
        if ($persisted.state -cne 'completed' -or
            $run.manifestDigest -cne $prepared.manifestDigest -or
            -not (Test-Path -LiteralPath $observationPath -PathType Leaf)) {
            return & $unknown $(if ($run.records[0].reason) {
                    [string]$run.records[0].reason
                } else { 'owner-orchestrator-incomplete' }) $prepared.manifestDigest
        }
        $observation = Get-Content -LiteralPath $observationPath -Raw |
            ConvertFrom-Json -AsHashtable -Depth 64
        if (-not (Test-Path -LiteralPath $telemetryPath -PathType Leaf)) {
            throw 'model-telemetry-unavailable'
        }
        $telemetry = Get-Content -LiteralPath $telemetryPath -Raw |
            ConvertFrom-Json -AsHashtable -Depth 64
        if ($observation.lifecycle.status -cne 'completed' -or
            $observation.findingsComplete -cne $true -or
            $observation.effects.providerWrites -cne 0 -or
            $observation.effects.writeToolInvocations -cne 0 -or
            $telemetry.providerWrites -cne 0 -or
            $telemetry.writeToolInvocations -cne 0 -or
            $telemetry.policy.providerWrite -cne $false -or
            @($telemetry.effectiveTools).Count -ne 0 -or
            @($telemetry.policy.availableTools).Count -ne 0 -or
            $observation.capability -cne $script:OwnerCapability -or
            $observation.subject.headCommit -cne $Declaration.sourceCommit -or
            $observation.subject.targetCommit -cne $Declaration.targetCommit -or
            $observation.subject.targetRef -cne $Declaration.targetRef -or
            $observation.rule.sha256 -cne $script:OwnerRuleHash.Substring(10)) {
            throw 'owner-observation-unbound'
        }
        $proof = Get-ActiveOwnerDurableProof -ManifestPath $manifestPath `
            -ManifestRoot $manifestRoot -CapabilityRoot $record.capabilityRoot `
            -Identity $record.identity -ManifestDigest $prepared.manifestDigest `
            -PayloadDigest $digest -ManifestEntry $manifest.entries[0] `
            -Observation $observation
        $outcomes = [Collections.Generic.List[object]]::new()
        $counts = @{ noOp = 0; humanCovered = 0; wouldCreate = 0; unknown = 0 }
        $findingIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($finding in @($observation.findings)) {
            $classification = [string]$finding.reconciliation.classification
            if (-not $counts.ContainsKey($classification) -or
                [string]$finding.identity -cnotmatch '^owner-v2:[a-f0-9]{64}$' -or
                -not $findingIds.Add([string]$finding.identity)) {
                throw 'owner-finding-integrity-failure'
            }
            $reason = [string]$finding.reconciliation.reason
            if ($reason -cnotmatch '^[a-z][a-z0-9-]{0,79}$') {
                throw 'owner-finding-integrity-failure'
            }
            $counts[$classification]++
            [void]$outcomes.Add([ordered]@{
                findingDigest = (Get-ActiveOwnerJsonHash @(
                    $script:OwnerCapability, $finding.identity,
                    $finding.anchor.path, $finding.anchor.line)).Substring(10)
                classification = $classification; reason = $reason
            })
        }
        if ($outcomes.Count -gt [int]$RuleConfig.maxFindingsPerHead -or
            $outcomes.Count -gt 32 -or [int]$observation.counts.unknown -gt 0) {
            return & $unknown 'owner-findings-ambiguous' $prepared.manifestDigest
        }
        $discussionDigests = @($observation.findings | ForEach-Object {
                [string]$_.reconciliation.discussionSha256 } | Select-Object -Unique)
        $discussionDigest = $snapshot.Digest.Substring(10)
        if ($discussionDigests.Count -gt 1 -or
            ($discussionDigests.Count -eq 1 -and
                $discussionDigests[0] -cne $discussionDigest)) {
            throw 'discussion-snapshot-mismatch'
        }
        if ([int]$observation.counts.violations -ne $outcomes.Count) {
            throw 'owner-finding-count-mismatch'
        }
        if ($outcomes.Count -gt 0) {
            $snapshotArtifacts = @($observation.sourceArtifacts | Where-Object {
                    $_.kind -ceq 'owner-v2-discussion-snapshot'
                })
            if ($snapshotArtifacts.Count -ne 1 -or
                [string]$snapshotArtifacts[0].sha256 -cne $discussionDigest -or
                [int]$observation.effects.dedupe.noOp -ne $counts.noOp -or
                [int]$observation.effects.dedupe.humanCovered -ne $counts.humanCovered -or
                [int]$observation.effects.dedupe.wouldCreate -ne $counts.wouldCreate -or
                [int]$observation.effects.dedupe.unknown -ne $counts.unknown -or
                [int]$observation.effects.dedupe.wouldUpdate -ne 0) {
                throw 'discussion-outcome-mismatch'
            }
        }
        return @{
            state = 'evaluated'; reason = 'completed'
            findings = $outcomes.Count; unknown = $counts.unknown
            noOp = $counts.noOp; humanCovered = $counts.humanCovered
            wouldCreate = $counts.wouldCreate
            discussionDigest = $discussionDigest
            findingOutcomes = @($outcomes.ToArray())
            completed = $true; providerWrites = 0; writeToolInvocations = 0
            modelToolInvocations = 0; manifestEntryCount = 1
            manifestDigest = $prepared.manifestDigest
            durableProof = $proof
            intakeGeneration = [string]$RuleDeclaration.intakeGeneration
            declarationDigest = $DeclarationDigest
            sourceCommit = [string]$Declaration.sourceCommit
            targetCommit = [string]$Declaration.targetCommit
            targetRef = [string]$Declaration.targetRef
            iterationId = $Declaration.iterationId
            ruleId = [string]$RuleDeclaration.ruleId
        }
    }
    catch {
        return & $unknown 'owner-evaluation-unavailable' $null
    }
}

Export-ModuleMember -Function New-ActiveOwnerEvaluator, Invoke-ActiveOwnerEvaluation
