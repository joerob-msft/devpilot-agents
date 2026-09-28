#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1')
Import-Module (Join-Path $PSScriptRoot '..\DevPilot.ActivePrIntake\DevPilot.ActivePrIntake.psd1')
Import-Module (Join-Path $PSScriptRoot '..\DevPilot.ActivePrCanary\DevPilot.ActivePrCanary.psm1')
Import-Module (Join-Path $PSScriptRoot '..\DevPilot.RuleEvaluation\DevPilot.RuleEvaluation.psd1')

$script:CanaryRules = @('bpm-test-ownership@1',
    'bpm-test-class-coverage@2', 'bpm-redundant-method-coverage@2',
    'bpm-named-areequal-arguments@1')

function Get-PrivateCanaryDigest {
    param($Value)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes(
                (ConvertTo-Json -InputObject $Value -Depth 32 -Compress))
        )).ToLowerInvariant()
}

function Read-PrivateCanaryFile {
    param([string]$Root, [string]$Name, [int]$MaxBytes = 8388608,
        [switch]$Text)
    $path = Join-Path $Root $Name
    [void](Assert-AgentTrustedFile -Path $path -AllowedRoot $Root -Private)
    $file = Get-Item -LiteralPath $path -Force
    if ($file.Length -lt 1 -or $file.Length -gt $MaxBytes) {
        throw 'canary-private-file-invalid'
    }
    $value = [Text.UTF8Encoding]::new($false, $true).GetString(
        [IO.File]::ReadAllBytes($path))
    if ($Text) { return $value }
    return ($value | ConvertFrom-Json -AsHashtable -Depth 32)
}

function Assert-PrivateCanarySignature {
    param([Collections.IDictionary]$Config, [string]$Key)
    if ($Key -cnotmatch '^[A-Za-z0-9+/]{64}$' -or
        [string]$Config.signature -cnotmatch '^v1:hmac-sha256:[a-f0-9]{64}$') {
        throw 'canary-signature-invalid'
    }
    $unsigned = [ordered]@{}
    foreach ($name in $Config.Keys) {
        if ([string]$name -cne 'signature') {
            $unsigned[[string]$name] = $Config[$name]
        }
    }
    $hmac = [Security.Cryptography.HMACSHA256]::new(
        [Text.Encoding]::UTF8.GetBytes($Key))
    try {
        $expected = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes(
                (ConvertTo-AgentCanonicalJson -InputObject $unsigned)))
    }
    finally { $hmac.Dispose() }
    if (-not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
            $expected, [Convert]::FromHexString($Config.signature.Substring(15)))) {
        throw 'canary-signature-invalid'
    }
}

function Assert-PrivateCanaryConfig {
    param([Collections.IDictionary]$Config, [Collections.IDictionary]$Intake,
        [Collections.IDictionary]$ProviderConfig,
        [Collections.IDictionary]$Registry)
    if ($Config.schemaVersion -ne 3 -or
        $Config.kind -cne 'private-canary-signed-intake' -or
        $Config.principalProof -cne 'aad-graph-storage-key-v1' -or
        $Intake.schemaVersion -ne 2 -or
        $Intake.principalProof -cne $Config.principalProof -or
        $ProviderConfig.operator.expectedCliUpn -ine
            [string]$Config.expectedAccount.principalName -or
        $Config.enabled -cne $false -or $Config.readOnly -cne $true -or
        $Config.dryRun -cne $true -or $Config.writerEligible -cne $false -or
        $Config.modelEnabled -cne $false -or
        $Config.sourceAuthority -cne 'merged-master-verified-read-only' -or
        $Config.organization -cne $Intake.organization -or
        $Config.organization -cne
            "https://dev.azure.com/$($ProviderConfig.repository.organization)" -or
        [string]$Config.projectId -ine [string]$ProviderConfig.projectId -or
        [string]$Config.repositoryId -ine [string]$ProviderConfig.repository.id -or
        [string]$Config.projectId -ine [string]$Intake.projectId -or
        [string]$Config.repositoryId -ine [string]$Intake.repositoryId -or
        (ConvertTo-AgentCanonicalJson -InputObject $Config.expectedAccount) -cne
            (ConvertTo-AgentCanonicalJson -InputObject $Intake.expectedAccount) -or
        (ConvertTo-AgentCanonicalJson -InputObject $Config.expectedAccount) -cne
            (ConvertTo-AgentCanonicalJson -InputObject $ProviderConfig.expectedAccount) -or
        $Config.receiptDigest -cne $Registry.receiptDigest -or
        $Registry.schemaVersion -ne 3 -or
        $Registry.sourceAuthority -cne $Config.sourceAuthority -or
        $Registry.state -cne 'verified-not-evaluated' -or
        $Registry.evaluated -cne $false -or
        $Registry.writerEligible -cne $false -or
        $Registry.providerWrites -ne 0 -or
        $Config.rules -isnot [array] -or $Config.rules.Count -ne 4 -or
        $Config.heads -isnot [array] -or
        $Config.heads.Count -lt 1 -or $Config.heads.Count -gt 2 -or
        $Config.limits -isnot [Collections.IDictionary] -or
        $Config.limits.maxHeadsPerRun -ne $Config.heads.Count -or
        $Config.limits.maxReads -lt 1 -or $Config.limits.maxReads -gt 3000 -or
        $Config.limits.maxSeconds -lt 1 -or $Config.limits.maxSeconds -gt 240 -or
        $Config.limits.maxFindingsPerHead -lt 1 -or
        $Config.limits.maxFindingsPerHead -gt 8) {
        throw 'canary-config-invalid'
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($binding in $Config.rules) {
        $id = [string]$binding.capabilityId
        $source = $Registry.rules[$id]
        if ($id -cnotin $script:CanaryRules -or -not $seen.Add($id) -or
            $binding.enabled -cne $false -or $binding.evaluated -cne $false -or
            $binding.writerEligible -cne $false -or
            $source -isnot [Collections.IDictionary] -or
            $source.enabled -cne $false -or $source.evaluated -cne $false -or
            $source.writerEligible -cne $false -or
            $binding.sourceAuthority -cne $source.sourceAuthority -or
            $binding.sourceCommit -cne $source.sourceCommit -or
            $binding.sourceHash -cne $source.sourceHash -or
            $binding.declarationDigest -cne $source.declarationDigest) {
            throw 'canary-rule-binding-invalid'
        }
    }
    if ($seen.Count -ne 4 -or
        $Registry.rules['bpm-test-class-coverage@2'].declarationDigest -ceq
            $Registry.rules['bpm-redundant-method-coverage@2'].declarationDigest -or
        $Intake.projectEvidence.enabled -cne $true -or
        $Intake.enabled -cne $true -or
        $Intake.readOnly -cne $true -or $Intake.dryRun -cne $true) {
        throw 'canary-rule-binding-invalid'
    }
}

function Assert-PrivateCanaryHead {
    param([Collections.IDictionary]$Actual, [Collections.IDictionary]$Expected)
    foreach ($name in @('pullRequestId', 'status', 'isDraft', 'sourceRef',
            'targetRef', 'iterationId', 'repositoryId', 'projectId',
            'sourceCommit', 'targetCommit', 'commonCommit')) {
        if ([string]$Actual[$name] -cne [string]$Expected[$name]) {
            throw 'canary-head-drift'
        }
    }
    if ($Actual.status -cne 'active' -or $Actual.isDraft -cne $false -or
        $Actual.targetRef -cne 'refs/heads/master') {
        throw 'canary-head-left-policy'
    }
}

function Invoke-PrivateCanaryEvaluation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [string]$AzureCliPath = 'az',
        [scriptblock]$Read,
        [scriptblock]$Provider,
        [switch]$Run
    )
    if (-not $Run) {
        return [ordered]@{ state = 'disabled'; evaluated = $false
            providerReads = 0; providerWrites = 0; modelToolInvocations = 0
            writerEligible = $false }
    }
    if (-not [IO.Path]::IsPathFullyQualified($StateRoot) -or
        -not [IO.Path]::IsPathFullyQualified($RepositoryRoot) -or
        (Test-AgentPathWithin $StateRoot $RepositoryRoot) -or
        (Test-AgentPathWithin $RepositoryRoot $StateRoot)) {
        throw 'canary-state-root-must-be-external'
    }
    $root = Resolve-AgentTrustedRoot -Path $StateRoot -Kind durable-state `
        -RepositoryRoot $RepositoryRoot
    $config = Read-PrivateCanaryFile $root 'canary-dispatcher.json'
    $key = Read-PrivateCanaryFile $root 'signature.key' 128 -Text
    Assert-PrivateCanarySignature $config $key
    $providerConfig = Read-PrivateCanaryFile $root 'provider-config.json'
    $sources = Read-PrivateCanaryFile $root 'approved-sources.json'
    $intakeConfig = Read-PrivateCanaryFile $root 'canary-intake.json'
    if ([bool]$Read -ne [bool]$Provider) {
        throw 'bound-transport-invalid'
    }
    $session = $null
    try {
    if (-not $Read) {
        $canaryModule = Get-Module DevPilot.ActivePrCanary
        $session = & $canaryModule {
            param($Root, $Cli)
            New-PrivateCanaryBearerSession $Root $Cli
        } $RepositoryRoot $AzureCliPath
    }
    $registryArgs = @{ ProviderConfig = $providerConfig
        ApprovedSources = $sources; RepositoryRoot = $RepositoryRoot; Run = $true }
    if ($Read) { $registryArgs.Read = $Read }
    $registry = if ($Read) {
        New-VerifiedCanaryRuleRegistry @registryArgs
    } else {
        Invoke-PrivateCanaryRuleRegistry @registryArgs -BearerSession $session
    }
    Assert-PrivateCanaryConfig $config $intakeConfig $providerConfig $registry
    $intakeRoot = Resolve-AgentTrustedRoot `
        -Path (Join-Path $root 'active-pr-intake-v1') -Kind durable-state `
        -RepositoryRoot $RepositoryRoot
    $generations = Resolve-AgentTrustedRoot `
        -Path (Join-Path $intakeRoot 'generations') -Kind durable-state `
        -RepositoryRoot $RepositoryRoot
    $latest = Read-PrivateCanaryFile $intakeRoot 'cohort.json'
    if ([string]$latest.generation -cnotmatch '^[a-f0-9]{32}$') {
        throw 'canary-intake-generation-invalid'
    }
    $immutable = Read-PrivateCanaryFile $generations "$($latest.generation).json" -Text
    $latestText = Read-PrivateCanaryFile $intakeRoot 'cohort.json' -Text
    if ($latestText -cne $immutable) {
        throw 'canary-intake-generation-invalid'
    }
    $intake = Assert-BoundedCandidateIntake $root $config $intakeConfig $RepositoryRoot
    if ($intake.generation -cne $config.intakeGeneration -or
        $intake.binding.configDigest -cne $config.intakeConfigDigest -or
        $intake.binding.accountProofDigest -cne
            (Get-PrivateCanaryDigest $config.expectedAccount) -or
        $intake.populationKnown -cne $true -or
        $intake.gapCounts.enumerationUnknown -ne 0 -or
        $intake.gapCounts.duplicateEntries -ne 0 -or
        $intake.inventory.active -ne
            ($intake.inventory.draft + $intake.inventory.nonDraft) -or
        $intake.inventory.nonDraft -ne
            ($intake.inventory.eligible +
                $intake.inventory.nonDraftExcludedOtherTargets)) {
        throw 'canary-intake-incomplete'
    }
    $selected = [Collections.Generic.List[object]]::new()
    $ids = [Collections.Generic.HashSet[int]]::new()
    foreach ($pin in $config.heads) {
        $id = 0
        if ($pin -isnot [Collections.IDictionary] -or
            -not [int]::TryParse([string]$pin.pullRequestId, [ref]$id) -or
            $id -lt 1 -or -not $ids.Add($id)) {
            throw 'canary-head-pin-invalid'
        }
        $matchingHeads = @($intake.heads | Where-Object pullRequestId -EQ $id)
        if ($matchingHeads.Count -ne 1 -or $matchingHeads[0].status -cne 'pending' -or
            $matchingHeads[0].targetRef -cne 'refs/heads/master' -or
            $matchingHeads[0].lineEvidence -isnot [Collections.IDictionary] -or
            $matchingHeads[0].projectEvidence.complete -cne $true) {
            throw 'canary-head-pin-invalid'
        }
        $head = $matchingHeads[0]
        foreach ($name in @('sourceCommit', 'targetCommit', 'targetRef',
                'iterationId', 'declarationDigest', 'lineEvidenceDigest',
                'projectEvidenceDigest')) {
            if ([string]$pin[$name] -cne [string]$head[$name]) {
                throw 'canary-head-pin-invalid'
            }
        }
        $selected.Add($head)
    }
    if (-not $Provider) {
        $Provider = New-ActivePrAzureDevOpsProvider -Config $intakeConfig `
            -BearerToken $session.token -BoundClient $session.client `
            -VerifyReadPrincipal
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $reads = [pscustomobject]@{ count = [int]$registry.providerReads }
    $readOnly = {
        param([string]$Operation, [Collections.IDictionary]$Arguments)
        if ($Operation -cnotin @('Identity', 'Head', 'Changes', 'Discussions') -or
            $reads.count -ge [int]$config.limits.maxReads -or
            $clock.Elapsed.TotalSeconds -ge [int]$config.limits.maxSeconds) {
            throw 'canary-read-budget-or-operation'
        }
        $reads.count++
        $Arguments.remainingReads = [int]$config.limits.maxReads - $reads.count
        $Arguments.timeoutMilliseconds = [Math]::Max(1,
            [int]([int]$config.limits.maxSeconds * 1000 - $clock.ElapsedMilliseconds))
        $answer = & $Provider $Operation $Arguments
        if ($answer -isnot [Collections.IDictionary]) { throw 'canary-provider-invalid' }
        if ($null -ne $answer['readCount']) {
            $additional = 0
            if (-not [int]::TryParse([string]$answer.readCount, [ref]$additional) -or
                $additional -lt 0 -or
                $reads.count + $additional -gt [int]$config.limits.maxReads) {
                throw 'canary-read-budget-or-operation'
            }
            $reads.count += $additional
        }
        if ($clock.Elapsed.TotalSeconds -ge [int]$config.limits.maxSeconds) {
            throw 'canary-time-budget'
        }
        return $answer
    }.GetNewClosure()
    $identity = & $readOnly Identity @{}
    if ([string]$identity.id -ine [string]$config.expectedAccount.id -or
        [string]$identity.descriptor -cne [string]$config.expectedAccount.descriptor -or
        [string]$identity.principalName -ine
            [string]$config.expectedAccount.principalName -or
        ($identity.Contains('uniqueName') -ne
            $config.expectedAccount.Contains('uniqueName')) -or
        ($config.expectedAccount.Contains('uniqueName') -and
            [string]$identity.uniqueName -ine
                [string]$config.expectedAccount.uniqueName)) {
        throw 'canary-principal-drift'
    }
    $results = [Collections.Generic.List[object]]::new()
    foreach ($head in $selected) {
        $declaration = $head.declaration
        $id = [int]$head.pullRequestId
        Assert-PrivateCanaryHead (& $readOnly Head @{ pullRequestId = $id }) $declaration
        $changes = & $readOnly Changes @{
            pullRequestId = $id; iterationId = $declaration.iterationId
            sourceCommit = $declaration.sourceCommit
            targetCommit = $declaration.targetCommit
            commonCommit = $declaration.commonCommit
            includeEvaluationFiles = $true; includeProjectEvidence = $true
        }
        if ($changes.changedFiles -ne $head.lineEvidence.changedFiles -or
            $changes.changedLines -ne $head.lineEvidence.changedLines -or
            $changes.baseCommit -cne $declaration.commonCommit -or
            $changes.files -isnot [array] -or
            (Get-PrivateCanaryDigest @($changes.files)) -cne
                (Get-PrivateCanaryDigest @($head.lineEvidence.files)) -or
            $changes.evaluationFiles -isnot [array] -or
            $changes.evaluationFiles.Count -ne
                @($head.lineEvidence.files | Where-Object changeType -NE 'delete').Count) {
            throw 'canary-changed-lines-drift'
        }
        $expectedScope = [ordered]@{
            schemaVersion = 1; kind = 'source-bound-project-scope-summary-v1'
            repositoryId = $head.projectEvidence.repositoryId
            sourceCommit = $head.projectEvidence.sourceCommit
            rootTreeId = $head.projectEvidence.rootTreeId
            complete = $head.projectEvidence.complete
            files = $head.projectEvidence.files
        }
        if ($changes.projectEvidence -isnot [Collections.IDictionary] -or
            (ConvertTo-AgentCanonicalJson $changes.projectEvidence) -cne
                (ConvertTo-AgentCanonicalJson $expectedScope) -or
            $changes.projectEvidence.complete -cne $true) {
            throw 'canary-project-graph-drift'
        }
        $files = [Collections.Generic.List[object]]::new()
        $totalBytes = 0
        foreach ($proof in $head.lineEvidence.files) {
            if ($proof.changeType -ceq 'delete') { continue }
            $matchingFiles = @($changes.evaluationFiles | Where-Object {
                    (Get-PrivateCanaryDigest $_.path) -ceq $proof.pathDigest
                })
            if ($matchingFiles.Count -ne 1 -or
                [string]$matchingFiles[0].path -cnotmatch '^/[^?#\x00-\x1f]{1,2048}$' -or
                $matchingFiles[0].content -isnot [string] -or
                [string]$matchingFiles[0].objectId -cnotmatch '^[a-f0-9]{40}$' -or
                [Text.Encoding]::UTF8.GetByteCount($matchingFiles[0].content) -gt
                    [int]$intakeConfig.limits.maxFileBytes) {
                throw 'canary-source-unverified'
            }
            $source = $matchingFiles[0]
            $bytes = [Text.Encoding]::UTF8.GetBytes($source.content)
            $totalBytes += $bytes.Length
            if ($totalBytes -gt [int]$intakeConfig.limits.maxTotalBytes) {
                throw 'canary-source-unverified'
            }
            $header = [Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
            $blobId = [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData(
                    [byte[]]($header + $bytes))).ToLowerInvariant()
            if ($blobId -cne $source.objectId) { throw 'canary-source-unverified' }
            if ($source.path -cmatch '\.cs$') {
                $receipts = @($head.projectEvidence.files | Where-Object {
                        $_.pathDigest -ceq $proof.pathDigest -and
                        $_.objectId -ceq $source.objectId -and
                        $_.status -ceq 'complete'
                    })
                if ($receipts.Count -ne 1 -or
                    $source.projectEvidence -isnot [Collections.IDictionary] -or
                    (Get-PrivateCanaryDigest $source.projectEvidence) -cne
                        $receipts[0].attestationDigest -or
                    $source.projectEvidence.complete -cne $true -or
                    [string]$source.projectEvidence.repositoryId -ine
                        [string]$declaration.repositoryId -or
                    [string]$source.projectEvidence.sourceCommit -cne
                        [string]$declaration.sourceCommit -or
                    [string]$source.projectEvidence.path -cne $source.path -or
                    [string]$source.projectEvidence.objectId -cne $source.objectId) {
                    throw 'canary-project-graph-drift'
                }
            }
            $files.Add(@{ path = $source.path; content = $source.content
                objectId = $source.objectId; spans = $proof.spans
                projectEvidence = $source['projectEvidence'] })
        }
        $discussion = & $readOnly Discussions @{
            pullRequestId = $id; iterationId = $declaration.iterationId
        }
        [void](Get-ActivePrDiscussionCounts $discussion $intakeConfig $declaration)
        $evaluations = [Collections.Generic.List[object]]::new()
        $findingCount = 0
        foreach ($ruleId in $script:CanaryRules) {
            if ($ruleId -ceq 'bpm-test-ownership@1') {
                $evaluations.Add([ordered]@{ capabilityId = $ruleId
                    status = 'unknown'; reason = 'owner-not-evaluated'
                    findings = 0; humanCovered = 0; wouldCreate = 0; unknown = 1 })
                continue
            }
            $source = $sources.rules[$ruleId]
            $registryRule = $registry.rules[$ruleId]
            $binding = [ordered]@{
                id = $ruleId
                repositoryId = if ($ruleId -ceq 'bpm-named-areequal-arguments@1') {
                    $source.ruleRepository
                } else { $source.repositoryId }
                path = $source.path.TrimStart('/')
                commit = $source.commit
                section = $ruleId
                hash = $registryRule.sourceHash
                length = if ($ruleId -ceq 'bpm-named-areequal-arguments@1') {
                    ([IO.File]::ReadAllBytes(
                            (Join-Path $RepositoryRoot $source.path))).Length
                } else { [int]$source.documentLength }
                declarationDigest = $registryRule.declarationDigest
            }
            $evaluation = Invoke-BoundedCandidateParser $config $binding `
                $declaration $files.ToArray() $discussion $intakeConfig `
                ([int]$config.limits.maxFindingsPerHead)
            if ($evaluation.state -cnotin @('evaluated', 'unknown') -or
                $evaluation.findings -gt [int]$config.limits.maxFindingsPerHead) {
                throw 'canary-evaluation-invalid'
            }
            $findingCount += [int]$evaluation.findings
            if ($findingCount -gt [int]$config.limits.maxFindingsPerHead) {
                throw 'canary-finding-cap'
            }
            if ($evaluation.state -ceq 'evaluated') {
                $outcomes = @($evaluation.findingOutcomes)
                $seenFindings = [Collections.Generic.HashSet[string]]::new(
                    [StringComparer]::Ordinal)
                if ($outcomes.Count -ne $evaluation.findings -or
                    [string]$evaluation.discussionDigest -cnotmatch '^[a-f0-9]{64}$' -or
                    @($outcomes | Where-Object {
                            [string]$_.findingDigest -cnotmatch '^[a-f0-9]{64}$' -or
                            -not $seenFindings.Add([string]$_.findingDigest) -or
                            $_.classification -cnotin @('noOp', 'humanCovered',
                                'wouldCreate', 'unknown')
                        }).Count -gt 0 -or
                    $evaluation.findings -ne
                        ($evaluation.noOp + $evaluation.humanCovered +
                            $evaluation.wouldCreate + $evaluation.unknown)) {
                    throw 'canary-finding-collision'
                }
            }
            $evaluations.Add([ordered]@{
                capabilityId = $ruleId
                status = if ($evaluation.state -ceq 'evaluated' -and
                    $evaluation.unknown -eq 0) { 'evaluated' } else { 'unknown' }
                reason = [string]$evaluation.reason
                findings = [int]$evaluation.findings
                humanCovered = if ($evaluation.state -ceq 'evaluated') {
                    [int]$evaluation.humanCovered
                } else { 0 }
                wouldCreate = if ($evaluation.state -ceq 'evaluated') {
                    [int]$evaluation.wouldCreate
                } else { 0 }
                unknown = if ($evaluation.state -ceq 'evaluated') {
                    [int]$evaluation.unknown
                } else { [Math]::Max(1, [int]$evaluation.unknown) }
            })
        }
        $after = & $readOnly Discussions @{
            pullRequestId = $id; iterationId = $declaration.iterationId
        }
        [void](Get-ActivePrDiscussionCounts $after $intakeConfig $declaration)
        if ((Get-PrivateCanaryDigest $discussion) -cne
            (Get-PrivateCanaryDigest $after)) {
            throw 'canary-discussion-drift'
        }
        Assert-PrivateCanaryHead (& $readOnly Head @{ pullRequestId = $id }) $declaration
        $results.Add([ordered]@{ pullRequestId = $id; rules = @($evaluations.ToArray()) })
    }
    $summary = @($script:CanaryRules | ForEach-Object {
            $ruleId = $_
            $entries = @($results | ForEach-Object {
                    @($_.rules | Where-Object capabilityId -CEQ $ruleId)
                })
            $humanCovered = 0
            $wouldCreate = 0
            foreach ($entry in $entries) {
                $humanCovered += [int]$entry.humanCovered
                $wouldCreate += [int]$entry.wouldCreate
            }
            [ordered]@{
                capabilityId = $ruleId
                evaluated = @($entries | Where-Object status -CEQ 'evaluated').Count
                unknown = @($entries | Where-Object status -CEQ 'unknown').Count
                humanCovered = $humanCovered
                wouldCreate = $wouldCreate
                pending = 0
                skipped = [int]$intake.inventory.excludedOtherTargets
            }
        })
    $finalIdentity = & $readOnly Identity @{}
    if ((ConvertTo-AgentCanonicalJson -InputObject $finalIdentity) -cne
        (ConvertTo-AgentCanonicalJson -InputObject $identity)) {
        throw 'canary-principal-drift'
    }
    return [ordered]@{
        schemaVersion = 3; kind = 'private-canary-read-only-evaluation'
        state = 'merged-master-read-only'
        sourceAuthority = 'merged-master-verified-read-only'
        intakeGeneration = $intake.generation
        selected = $results.Count
        draft = [int]$intake.inventory.draft
        skipped = [int]$intake.inventory.excludedOtherTargets
        pending = [int]$intake.inventory.eligible - $results.Count
        rules = $summary; heads = @($results.ToArray())
        providerReads = $reads.count; providerWrites = 0
        modelToolInvocations = 0; writerEligible = $false
    }
    }
    finally { if ($session) { $session.client.Dispose() } }
}

Export-ModuleMember -Function Invoke-PrivateCanaryEvaluation
