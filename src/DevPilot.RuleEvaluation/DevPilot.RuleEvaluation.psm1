#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1')
Import-Module (Join-Path $PSScriptRoot '..\DevPilot.ActivePrIntake\DevPilot.ActivePrIntake.psd1')
Import-Module (Join-Path $PSScriptRoot '..\DevPilot.TestClassCoverage\DevPilot.TestClassCoverage.psd1')
Import-Module (Join-Path $PSScriptRoot '..\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1')
Import-Module (Join-Path $PSScriptRoot '..\DevPilot.OwnerCapability\DevPilot.OwnerCapability.psd1')
Import-Module (Join-Path $PSScriptRoot '..\OwnerObservationContract\OwnerObservationContract.psd1')

$script:RuleIds = [ordered]@{
    'bpm-test-ownership@1' = 'mstest-owner'
    'bpm-test-class-coverage@1' = 'bpm-test-class-coverage@1'
    'bpm-redundant-method-coverage@1' = 'bpm-redundant-method-coverage@1'
    'bpm-named-areequal-arguments@1' = 'bpm-named-areequal-arguments@1'
}
$script:RulePolicies = @{
    'bpm-test-class-coverage@1' = 'test-class-coverage'
    'bpm-redundant-method-coverage@1' = 'redundant-method-coverage'
    'bpm-named-areequal-arguments@1' = 'named-areequal-arguments'
}

function Get-RuleDigest {
    param($Value)
    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Value -Depth 32 -Compress))
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Assert-RuleNumber {
    param($Value, [string]$Name, [int]$Minimum, [int]$Maximum)
    if ($Value -is [bool] -or $null -eq $Value -or
        [string]$Value -cnotmatch '^(0|[1-9][0-9]*)$') { throw "Invalid $Name." }
    $number = 0
    if (-not [int]::TryParse([string]$Value, [ref]$number) -or
        $number -lt $Minimum -or $number -gt $Maximum) { throw "Invalid $Name." }
    return $number
}

function Assert-RuleConfig {
    param([Collections.IDictionary]$Config, [Collections.IDictionary]$IntakeConfig,
        [string]$SignatureKey, [bool]$RequireSignature)
    if ($Config.schemaVersion -ne 1 -or $Config.enabled -isnot [bool] -or
        $Config.readOnly -cne $true -or $Config.dryRun -cne $true -or
        $Config.organization -cne $IntakeConfig.organization -or
        [string]$Config.projectId -ine [string]$IntakeConfig.projectId -or
        [string]$Config.repositoryId -ine [string]$IntakeConfig.repositoryId -or
        $Config.rules -isnot [array] -or $Config.rules.Count -ne $script:RuleIds.Count -or
        $Config.limits -isnot [Collections.IDictionary]) {
        throw 'Rule evaluation requires an explicit read-only repository binding and registry.'
    }
    [void](Assert-RuleNumber $Config.limits.maxHeadsPerRun maxHeadsPerRun 1 20)
    [void](Assert-RuleNumber $Config.limits.maxReads maxReads 1 30000)
    [void](Assert-RuleNumber $Config.limits.maxSeconds maxSeconds 1 3600)
    [void](Assert-RuleNumber $Config.limits.maxIntakeAgeMinutes maxIntakeAgeMinutes 1 1440)
    [void](Assert-RuleNumber $Config.limits.maxFindingsPerHead maxFindingsPerHead 1 32)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($rule in $Config.rules) {
        if ($rule -isnot [Collections.IDictionary] -or
            -not $script:RuleIds.Contains([string]$rule.capabilityId) -or
            [string]$rule.ruleId -cne $script:RuleIds[[string]$rule.capabilityId] -or
            $rule.enabled -isnot [bool] -or
            -not $seen.Add([string]$rule.capabilityId)) {
            throw 'Rule registry has an unknown, duplicate, or invalid capability.'
        }
        [void](Assert-RuleNumber $rule.maxFindingsPerHead maxFindingsPerHead 1 32)
        if ($rule.maxFindingsPerHead -gt $Config.limits.maxFindingsPerHead) {
            throw 'Rule cap exceeds the per-head envelope.'
        }
        if ($rule.enabled -and $rule.capabilityId -ceq 'bpm-test-ownership@1') {
            $binding = $rule['binding']
            if ($binding -isnot [Collections.IDictionary] -or
                [string]$binding.ruleRepositoryId -cnotmatch
                    '^[A-Za-z0-9._/-]{1,256}$' -or
                [string]$binding.rulePath -cne
                    'documentation/EngineeringProcesses/Conventions/AutomatedTests.md' -or
                [string]$binding.ruleSection -cne '## Claim ownership' -or
                [string]$binding.ruleCommit -cne
                    'f6db83436b48f48a8521095a888d79f67823bbb2' -or
                [string]$binding.ruleHash -cne
                    'v1:sha256:bc31bfea6b378dffe4a1b28475dc1cac4cd3ee1ab793db57895446ded829ab2f' -or
                [string]$binding.capabilityDigest -cnotmatch
                    '^v1:sha256:[a-f0-9]{64}$' -or
                $rule.model -isnot [Collections.IDictionary] -or
                $rule.model.Count -ne 2 -or
                [string]$rule.model.id -cnotmatch '^[a-zA-Z0-9_.-]{1,128}$' -or
                [string]$rule.model.digest -cne
                    ('v1:sha256:' + (Get-RuleTextDigest ([string]$rule.model.id)))) {
                throw 'owner-rule-binding-unavailable'
            }
            [void](Assert-RuleNumber $binding.ruleLength ruleLength 1 65536)
        }
        if ($rule.enabled -and $script:RulePolicies.ContainsKey([string]$rule.capabilityId)) {
            $binding = $rule['binding']
            $policy = $script:RulePolicies[[string]$rule.capabilityId]
            if ($binding -isnot [Collections.IDictionary] -or
                [string]$binding.ruleRepositoryId -cnotmatch '^[A-Za-z0-9._/-]{1,256}$' -or
                [string]$binding.rulePath -cne
                    "src/DevPilot.OwnerCapability/Policy/$policy.v1.txt" -or
                [string]$binding.ruleCommit -cnotmatch '^[a-f0-9]{40}$' -or
                [string]$binding.ruleHash -cnotmatch '^v1:sha256:[a-f0-9]{64}$' -or
                [string]$binding.capabilityDigest -cne
                    ('v1:sha256:' + (Get-RuleTextDigest "$policy-capability-v1"))) {
                throw 'rule-binding-unavailable'
            }
        }
    }
    if ($Config.enabled -and $RequireSignature) {
        if ([string]::IsNullOrEmpty($SignatureKey) -or
            [string]$Config.signature -cnotmatch '^v1:hmac-sha256:[a-f0-9]{64}$') {
            throw 'invalid-signature'
        }
        $unsigned = [ordered]@{}
        foreach ($key in $Config.Keys) {
            if ([string]$key -cne 'signature') { $unsigned[[string]$key] = $Config[$key] }
        }
        $bytes = [Text.Encoding]::UTF8.GetBytes(
            (ConvertTo-AgentCanonicalJson -InputObject $unsigned))
        $hmac = [Security.Cryptography.HMACSHA256]::new(
            [Text.Encoding]::UTF8.GetBytes($SignatureKey))
        try { $expected = $hmac.ComputeHash($bytes) }
        finally { $hmac.Dispose() }
        $provided = [Convert]::FromHexString(([string]$Config.signature).Substring(15))
        if (-not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
                $expected, $provided)) { throw 'invalid-signature' }
    }
}

function Get-RuleTextDigest {
    param([string]$Text)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
}

function New-RuleContract {
    param([Collections.IDictionary]$Config, [Collections.IDictionary]$Rule,
        [Collections.IDictionary]$Head, [string]$RepositoryRoot)
    $binding = $Rule.binding
    $policy = $script:RulePolicies[[string]$Rule.capabilityId]
    $policyFile = Join-Path $RepositoryRoot (
        "src\DevPilot.OwnerCapability\Policy\$policy.v1.txt")
    if (-not (Test-Path -LiteralPath $policyFile -PathType Leaf)) {
        throw 'rule-binding-unavailable'
    }
    $text = [IO.File]::ReadAllText($policyFile, [Text.UTF8Encoding]::new($false, $true))
    if ([string]$binding.ruleHash -cne ('v1:sha256:' + (Get-RuleTextDigest $text))) {
        throw 'rule-binding-unavailable'
    }
    return New-OwnerAcquisitionContract `
        -RepositoryId ([string]$Head.repositoryId).ToLowerInvariant() `
        -ProjectId ([string]$Head.projectId).ToLowerInvariant() `
        -PullRequestId ([long]$Head.pullRequestId) `
        -SourceCommit ([string]$Head.sourceCommit).ToLowerInvariant() `
        -TargetCommit ([string]$Head.targetCommit).ToLowerInvariant() `
        -TargetRef ([string]$Head.targetRef) `
        -RuleRepositoryId ([string]$binding.ruleRepositoryId) `
        -RulePath ([string]$binding.rulePath) -RuleCommit ([string]$binding.ruleCommit) `
        -RuleSection ([string]$Rule.capabilityId) -RuleHash ([string]$binding.ruleHash) `
        -RuleLength ([Text.Encoding]::UTF8.GetByteCount($text)) `
        -ConfigId 'bounded-rule-evaluation-v1' `
        -ConfigDigest ('v1:sha256:' + (Get-RuleDigest $Config)) `
        -CapabilityId ([string]$Rule.capabilityId) `
        -CapabilityDigest ([string]$binding.capabilityDigest)
}

function Read-RuleJson {
    param([string]$Path, [int]$MaximumBytes = 8388608)
    $file = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $file.PSIsContainer -and
        -not ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
        $file.Length -gt 0 -and $file.Length -le $MaximumBytes) {
        $bytes = [IO.File]::ReadAllBytes($Path)
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        return @{ bytes = $bytes; value = ($text | ConvertFrom-Json -AsHashtable -Depth 32) }
    }
    throw 'untrusted-state-file'
}

function Assert-RuleProjectEvidence {
    param([Collections.IDictionary]$Head, [string]$Generation)
    $scope = $Head['projectEvidence']
    if ($null -eq $scope) {
        if ($null -ne $Head['projectEvidenceDigest']) {
            throw 'intake-project-evidence-invalid'
        }
        return
    }
    if ($scope -isnot [Collections.IDictionary] -or
        $Head.lineEvidence -isnot [Collections.IDictionary] -or
        [string]$Head.projectEvidenceDigest -cnotmatch '^[a-f0-9]{64}$' -or
        (Get-RuleDigest $scope) -cne $Head.projectEvidenceDigest -or
        $scope.schemaVersion -ne 1 -or
        $scope.kind -cne 'source-bound-project-scope-summary-v1' -or
        $scope.generation -cne $Generation -or
        $scope.declarationDigest -cne $Head.declarationDigest -or
        $scope.repositoryId -ine $Head.declaration.repositoryId -or
        $scope.sourceCommit -cne $Head.sourceCommit -or
        $scope.complete -isnot [bool] -or $scope.files -isnot [array] -or
        $scope.files.Count -gt $Head.lineEvidence.changedFiles -or
        ($null -ne $scope.rootTreeId -and
            [string]$scope.rootTreeId -cnotmatch '^[a-f0-9]{40}$') -or
        ($scope.complete -and $scope.files.Count -gt 0 -and
            [string]$scope.rootTreeId -cnotmatch '^[a-f0-9]{40}$')) {
        throw 'intake-project-evidence-invalid'
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $unknown = 0
    foreach ($file in $scope.files) {
        if ($file -isnot [Collections.IDictionary] -or
            [string]$file.pathDigest -cnotmatch '^[a-f0-9]{64}$' -or
            -not $seen.Add([string]$file.pathDigest) -or
            @($Head.lineEvidence.files | Where-Object {
                    $_.pathDigest -ceq $file.pathDigest -and
                    $_.changeType -cne 'delete'
                }).Count -ne 1 -or
            [string]$file.objectId -cnotmatch '^[a-f0-9]{40}$' -or
            $file.status -cnotin @('complete', 'unknown') -or
            ($file.status -ceq 'complete' -and
                [string]$file.attestationDigest -cnotmatch '^[a-f0-9]{64}$') -or
            ($file.status -ceq 'unknown' -and
                $null -ne $file.attestationDigest)) {
            throw 'intake-project-evidence-invalid'
        }
        if ($file.status -ceq 'unknown') { $unknown++ }
    }
    if ($scope.complete -ne ($unknown -eq 0)) {
        throw 'intake-project-evidence-invalid'
    }
}

function Assert-RuleIntake {
    param([string]$StateRoot, [Collections.IDictionary]$Config,
        [Collections.IDictionary]$IntakeConfig, [string]$RepositoryRoot)
    $root = Resolve-AgentTrustedRoot -Path (Join-Path $StateRoot 'active-pr-intake-v1') `
        -Kind durable-state -RepositoryRoot $RepositoryRoot
    $generationRoot = Resolve-AgentTrustedRoot -Path (Join-Path $root 'generations') `
        -Kind durable-state -RepositoryRoot $RepositoryRoot
    $latest = Read-RuleJson (Join-Path $root 'cohort.json')
    $intake = $latest.value
    if ($intake.schemaVersion -ne 1 -or $intake.kind -cne 'active-pr-intake-cohort' -or
        [string]$intake.generation -cnotmatch '^[a-f0-9]{32}$' -or
        $intake.generationFile -cne (Join-Path 'generations' "$($intake.generation).json") -or
        $intake.inventory.state -cne 'complete' -or
        $intake.binding.organization -cne $Config.organization -or
        [string]$intake.binding.projectId -ine [string]$Config.projectId -or
        [string]$intake.binding.repositoryId -ine [string]$Config.repositoryId -or
        [string]$intake.binding.configDigest -cne (Get-RuleDigest $IntakeConfig)) {
        throw 'intake-incomplete-or-unbound'
    }
    $observed = [DateTimeOffset]::MinValue
    $validTimestamp = if ($intake.observedUtc -is [DateTime]) {
        if ($intake.observedUtc.Kind -ne [DateTimeKind]::Utc) { $false }
        else {
            $observed = [DateTimeOffset]::new($intake.observedUtc)
            $true
        }
    } else {
        [DateTimeOffset]::TryParse([string]$intake.observedUtc, [ref]$observed)
    }
    if (-not $validTimestamp -or
        $observed.Offset -ne [TimeSpan]::Zero -or
        $observed -gt [DateTimeOffset]::UtcNow -or
        ([DateTimeOffset]::UtcNow - $observed).TotalMinutes -gt
            $Config.limits.maxIntakeAgeMinutes) {
        throw 'intake-stale-or-invalid'
    }
    $generation = Read-RuleJson (Join-Path $generationRoot "$($intake.generation).json")
    if (-not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
            $latest.bytes, $generation.bytes)) { throw 'intake-generation-mismatch' }
    if ($intake.heads -isnot [array] -or $intake.heads.Count -gt 2000 -or
        $intake.rules -isnot [array] -or $intake.rules.Count -gt 32 -or
        (Assert-RuleNumber $intake.inventory.discovered discovered 0 2000) -ne $intake.heads.Count -or
        (Assert-RuleNumber $intake.inventory.draft draft 0 10000) -gt
            $IntakeConfig.limits.maxPullRequests -or
        (Assert-RuleNumber $intake.inventory.eligible eligible 0 2000) +
        (Assert-RuleNumber $intake.inventory.excludedOtherTargets excludedOtherTargets 0 2000) -ne
        $intake.heads.Count) { throw 'intake-denominator-invalid' }
    $seen = [Collections.Generic.HashSet[int]]::new()
    $expectedRules = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($rule in $intake.rules) {
        if ([string]$rule.capabilityId -cnotmatch '^[a-zA-Z0-9_.@-]{1,128}$' -or
            [string]$rule.ruleId -cnotmatch '^[a-zA-Z0-9_.@-]{1,128}$' -or
            -not $expectedRules.Add("$($rule.capabilityId):$($rule.ruleId)")) {
            throw 'intake-rules-invalid'
        }
    }
    $master = 0
    foreach ($head in $intake.heads) {
        $id = Assert-RuleNumber $head.pullRequestId pullRequestId 1 ([int]::MaxValue)
        if (-not $seen.Add($id) -or
            [string]$head.targetRef -cnotmatch '^refs/heads/[a-zA-Z0-9._/-]{1,200}$' -or
            $head.rules -isnot [array] -or $head.rules.Count -ne $intake.rules.Count) {
            throw 'intake-head-invalid'
        }
        $headRules = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($rule in $head.rules) {
            if (-not $headRules.Add("$($rule.capabilityId):$($rule.ruleId)") -or
                -not $expectedRules.Contains("$($rule.capabilityId):$($rule.ruleId)") -or
                $rule.status -cnotin @('pending', 'unknown', 'skipped', 'error')) {
                throw 'intake-rules-invalid'
            }
        }
        if ($head.targetRef -ceq 'refs/heads/master') { $master++ }
        elseif ($head.status -cne 'skipped' -or $head.reason -cne 'target-out-of-policy') {
            throw 'intake-target-invalid'
        }
        if ($null -eq $head.lineEvidence) {
            if ($null -ne $head.lineEvidenceDigest -or
                $null -ne $head['projectEvidence'] -or
                $null -ne $head['projectEvidenceDigest']) {
                throw 'intake-evidence-invalid'
            }
            continue
        }
        $declaration = $head.declaration
        $evidence = $head.lineEvidence
        if ($head.status -cne 'pending' -or
            [string]$head.lineEvidenceDigest -cnotmatch '^[a-f0-9]{64}$' -or
            (Get-RuleDigest $evidence) -cne $head.lineEvidenceDigest -or
            (Get-RuleDigest $declaration) -cne $head.declarationDigest -or
            $evidence.generation -cne $intake.generation -or
            $evidence.configDigest -cne $intake.binding.configDigest -or
            $evidence.declarationDigest -cne $head.declarationDigest -or
            $declaration.pullRequestId -ne $id -or
            $declaration.sourceCommit -cne $head.sourceCommit -or
            $declaration.targetCommit -cne $head.targetCommit -or
            $declaration.targetRef -cne $head.targetRef -or
            $declaration.iterationId -ne $head.iterationId -or
            $declaration.status -cne 'active' -or $declaration.isDraft -cne $false -or
            $declaration.projectId -ine $Config.projectId -or
            $declaration.repositoryId -ine $Config.repositoryId -or
            $evidence.changedLines -lt 1 -or
            $evidence.changedLines -ne $evidence.addedLines + $evidence.deletedLines -or
            $evidence.files -isnot [array] -or
            $evidence.files.Count -ne $evidence.changedFiles -or
            $evidence.changedFiles -gt $IntakeConfig.limits.maxChangedFiles -or
            $evidence.changedLines -gt $IntakeConfig.limits.maxChangedLines) {
            throw 'intake-evidence-invalid'
        }
        $added = 0; $deleted = 0
        $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($file in $evidence.files) {
            if ([string]$file.pathDigest -cnotmatch '^[a-f0-9]{64}$' -or
                -not $paths.Add([string]$file.pathDigest) -or
                $file.changeType -cnotin @('add', 'edit', 'delete', 'rename') -or
                $file.spans -isnot [array]) { throw 'intake-evidence-invalid' }
            $count = 0; $last = 0
            foreach ($span in $file.spans) {
                $first = Assert-RuleNumber $span.startLine startLine 1 1000000
                $end = Assert-RuleNumber $span.endLine endLine $first 1000000
                if ($first -le $last -or $end -gt $file.newLineCount) {
                    throw 'intake-evidence-invalid'
                }
                $count += $end - $first + 1; $last = $end
            }
            if ($count -ne $file.addedLines -or
                ($file.addedLines + $file.deletedLines) -lt 1) {
                throw 'intake-evidence-invalid'
            }
            $added += $file.addedLines; $deleted += $file.deletedLines
        }
        if ($added -ne $evidence.addedLines -or $deleted -ne $evidence.deletedLines) {
            throw 'intake-evidence-invalid'
        }
        Assert-RuleProjectEvidence $head $intake.generation
        if ($null -ne $IntakeConfig['projectEvidence'] -and
            $IntakeConfig.projectEvidence.enabled -ceq $true -and
            $null -eq $head['projectEvidence']) {
            throw 'intake-project-evidence-invalid'
        }
    }
    if ($master -ne $intake.inventory.eligible) { throw 'intake-denominator-invalid' }
    foreach ($rule in $intake.rules) {
        if ($rule.evaluated -ne 0 -or $rule.discovered -ne $intake.heads.Count -or
            $rule.eligible -ne $master) { throw 'intake-is-not-evaluation' }
    }
    return $intake
}

function Write-RuleArtifact {
    param([string]$Path, [byte[]]$Bytes, [switch]$Immutable)
    if ($Bytes.Length -gt 8388608) { throw 'rule-state-budget' }
    if ($Immutable -and (Test-Path -LiteralPath $Path)) {
        $existing = Read-RuleJson $Path
        if (-not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
                $existing.bytes, $Bytes)) { throw 'immutable-rule-artifact-changed' }
        return
    }
    $parent = Split-Path -Path $Path -Parent
    $temp = Join-Path $parent ("staging-$([guid]::NewGuid().ToString('N')).json")
    try {
        $stream = [IO.File]::Open($temp, 'CreateNew', 'Write', 'None')
        try { $stream.Write($Bytes); $stream.Flush($true) }
        finally { $stream.Dispose() }
        [IO.File]::Move($temp, $Path, -not $Immutable)
    }
    finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    }
}

function Invoke-RuleRead {
    param([scriptblock]$Provider, [string]$Operation, [Collections.IDictionary]$Arguments,
        [ref]$Reads, [int]$MaximumReads, [Diagnostics.Stopwatch]$Clock, [int]$Seconds)
    if ($Operation -cnotin @('Identity', 'Head', 'Changes', 'Discussions')) {
        throw 'unsupported-read'
    }
    if ($Reads.Value -ge $MaximumReads) { throw 'read-budget' }
    if ($Clock.Elapsed.TotalSeconds -ge $Seconds) { throw 'time-budget' }
    $Reads.Value++
    $Arguments.remainingReads = $MaximumReads - $Reads.Value
    $Arguments.timeoutMilliseconds = [Math]::Max(1, $Seconds * 1000 - [int]$Clock.ElapsedMilliseconds)
    $response = & $Provider $Operation $Arguments
    if ($response -isnot [Collections.IDictionary]) { throw 'provider-contract' }
    if ($null -ne $response['readCount']) {
        $extra = Assert-RuleNumber $response.readCount readCount 0 $MaximumReads
        if ($Reads.Value + $extra -gt $MaximumReads) { throw 'read-budget' }
        $Reads.Value += $extra
    }
    if ($Clock.Elapsed.TotalSeconds -ge $Seconds) { throw 'time-budget' }
    return $response
}

function Assert-RuleHead {
    param([Collections.IDictionary]$Actual, [Collections.IDictionary]$Expected)
    foreach ($name in @('pullRequestId', 'status', 'isDraft', 'sourceRef',
            'targetRef', 'iterationId')) {
        if ($Actual[$name] -cne $Expected[$name]) { throw 'head-drift' }
    }
    foreach ($name in @('projectId', 'repositoryId', 'sourceCommit',
            'targetCommit', 'commonCommit')) {
        if ([string]$Actual[$name] -cnotmatch '^[a-fA-F0-9-]{36,40}$' -or
            [string]$Actual[$name] -ine [string]$Expected[$name]) {
            throw 'head-drift'
        }
    }
    if ($Actual.status -cne 'active' -or $Actual.isDraft -cne $false -or
        $Actual.targetRef -cne 'refs/heads/master') { throw 'head-left-policy' }
}

function Get-RuleTestProjectScope {
    param([object]$Evidence, [string]$RepositoryId, [string]$SourceCommit,
        [string]$Path, [string]$ObjectId)
    if ($Evidence -isnot [Collections.IDictionary] -or
        ($Evidence.schemaVersion -isnot [int] -and
            $Evidence.schemaVersion -isnot [long]) -or
        $Evidence.schemaVersion -ne 1 -or
        $Evidence.kind -cne 'source-bound-evaluated-project-graph-v1' -or
        $Evidence.complete -isnot [bool] -or $Evidence.complete -cne $true -or
        [string]$Evidence.repositoryId -ine $RepositoryId -or
        [string]$Evidence.sourceCommit -ine $SourceCommit -or
        [string]$Evidence.path -cne $Path -or
        [string]$Evidence.objectId -ine $ObjectId -or
        [string]$RepositoryId -cnotmatch
            '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$' -or
        [string]$SourceCommit -cnotmatch '^[a-fA-F0-9]{40}$' -or
        [string]$ObjectId -cnotmatch '^[a-fA-F0-9]{40}$' -or
        $Path -cnotmatch '^/[^?#\x00-\x1f]{1,2048}\.cs$' -or
        $Evidence.projects -isnot [array] -or
        $Evidence.projects.Count -lt 1 -or $Evidence.projects.Count -gt 32) {
        return 'unknown'
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $testCount = 0
    foreach ($project in $Evidence.projects) {
        if ($project -isnot [Collections.IDictionary] -or
            [string]$project.path -cnotmatch '^/[^?#\x00-\x1f]{1,2048}\.csproj$' -or
            [string]$project.objectId -cnotmatch '^[a-fA-F0-9]{40}$' -or
            $project.compileIncluded -cne $true -or
            $project.isTestProject -isnot [bool] -or
            -not $seen.Add([string]$project.path)) {
            return 'unknown'
        }
        if ($project.isTestProject) { $testCount++ }
    }
    if ($testCount -eq $Evidence.projects.Count) { return 'test' }
    if ($testCount -eq 0) { return 'non-test' }
    return 'unknown'
}

function Get-RuleEvaluation {
    param([string]$Capability, [object[]]$Files, [int]$MaximumFindings,
        [object]$Contract, [AllowNull()][object]$Snapshot,
        [string]$RepositoryId, [string]$SourceCommit)
    $findings = 0; $unknown = 0; $projectUnknown = 0
    $boundFindings = [Collections.Generic.List[object]]::new()
    foreach ($file in $Files) {
        if ($file.path -notmatch '\.cs$') { continue }
        $projectRule = $Capability -cin @('bpm-test-class-coverage@2',
            'bpm-redundant-method-coverage@2')
        $projectDigest = ''
        if ($projectRule) {
            $scope = Get-RuleTestProjectScope $file.projectEvidence $RepositoryId `
                $SourceCommit $file.path $file.objectId
            if ($scope -eq 'unknown') { $unknown++; $projectUnknown++; continue }
            if ($scope -eq 'non-test') { continue }
            $projectDigest = Get-RuleDigest $file.projectEvidence
        }
        $spans = @($file.spans | ForEach-Object {
                @{ startLine = [int]$_.startLine; endLine = [int]$_.endLine
                    state = 'complete' }
            })
        $constructs = switch -CaseSensitive ($Capability) {
            'bpm-test-class-coverage@1' {
                @(Get-TestClassCoverageConstructs -Content $file.content -Spans $spans -Path $file.path)
            }
            'bpm-test-class-coverage@2' {
                @(Get-TestClassCoverageConstructs -Content $file.content -Spans $spans `
                    -Path $file.path -AllTestProjectClasses)
            }
            'bpm-redundant-method-coverage@1' {
                @(Get-RedundantMethodCoverageConstructs -Content $file.content -Spans $spans -Path $file.path)
            }
            'bpm-redundant-method-coverage@2' {
                @(Get-RedundantMethodCoverageConstructs -Content $file.content -Spans $spans `
                    -Path $file.path -AllTestProjectClasses)
            }
            'bpm-named-areequal-arguments@1' {
                @(Get-NamedAreEqualConstructs -Content $file.content -Spans $spans -Path $file.path)
            }
        }
        foreach ($item in $constructs) {
            if (-not $item.recognized) { $unknown++; continue }
            if (($Capability -cin @('bpm-test-class-coverage@1',
                        'bpm-test-class-coverage@2') -and
                    -not $item.hasExclude) -or
                ($Capability -cin @('bpm-redundant-method-coverage@1',
                        'bpm-redundant-method-coverage@2') -and
                    $item.reason -ceq 'redundant-method-coverage-exclusion') -or
                ($Capability -ceq 'bpm-named-areequal-arguments@1' -and
                    $item.hasPositional)) {
                $findings++
                $line = if ($Capability -cin @('bpm-test-class-coverage@1',
                        'bpm-test-class-coverage@2')) {
                    [int]$item.declarationLine
                } else { [int]$item.startLine }
                $identity = @($Capability, $file.path, [string]$item.name,
                    [int]$item.declarationLine, $line)
                if ($projectRule) { $identity += $projectDigest }
                $constructRef = 'construct:' + (Get-RuleDigest $identity)
                $binding = New-OwnerCanonicalAnchor -Path $file.path.TrimStart('/') `
                    -StartLine $line -Symbol ([string]$item.name) `
                    -ConstructIdentity $constructRef
                $finding = [ordered]@{
                    disposition = 'violation'; constructRef = $constructRef
                    anchor = [ordered]@{ path = $file.path.TrimStart('/')
                        line = $line; symbol = [string]$item.name }
                    binding = $binding
                }
                if ($Capability -cin @('bpm-redundant-method-coverage@1',
                        'bpm-redundant-method-coverage@2')) {
                    $finding.affectedMethodCount = [int]$item.affectedMethodCount
                    $finding.affectedMethods = @($item.affectedMethods)
                    $finding.affectedAttributeLines = @($item.affectedAttributeLines)
                    $finding.methodListTruncated = [bool]$item.methodListTruncated
                }
                elseif ($Capability -ceq 'bpm-named-areequal-arguments@1') {
                    $finding.affectedCallCount = [int]$item.affectedCallCount
                    $finding.affectedCallLines = @($item.affectedCallLines)
                    $finding.callListTruncated = [bool]$item.callListTruncated
                }
                [void]$boundFindings.Add($finding)
            }
        }
    }
    if ($findings -gt $MaximumFindings) { return @{ state = 'unknown'; reason = 'finding-cap'
            findings = 0; unknown = $findings } }
    if ($projectUnknown -gt 0) {
        return @{ state = 'unknown'; reason = 'test-project-identity-unknown'
            findings = $findings; unknown = $unknown }
    }
    if ($unknown -gt 0) { return @{ state = 'unknown'; reason = 'rule-ambiguous'
            findings = $findings; unknown = $unknown } }
    if ($null -eq $Contract -or $null -eq $Snapshot) {
        return @{ state = 'unknown'; reason = 'discussion-acquisition-unavailable'
            findings = $findings; unknown = [Math]::Max(1, $findings) }
    }
    $observation = [ordered]@{
        capability = $Capability
        lifecycle = @{ status = 'completed' }
        findings = @($boundFindings)
        effects = @{ dedupe = @{} }
        sourceArtifacts = @()
    }
    $resolved = Resolve-OwnerV2DiscussionReconciliation -Observation $observation `
        -Contract $Contract -Snapshot $Snapshot
    $outcomes = [Collections.Generic.List[object]]::new()
    $counts = @{ noOp = 0; humanCovered = 0; wouldCreate = 0; unknown = 0 }
    foreach ($finding in $resolved.findings) {
        $reconciliation = $finding.reconciliation
        $classification = [string]$reconciliation.classification
        $anchor = $finding.anchor
        $lines = if ($Capability -ceq 'bpm-named-areequal-arguments@1') {
            @($finding.affectedCallLines)
        } elseif ($Capability -cin @('bpm-redundant-method-coverage@1',
                'bpm-redundant-method-coverage@2')) {
            @($finding.affectedAttributeLines)
        } else { @([int]$anchor.line) }
        $discussionPattern = switch ($Capability) {
            'bpm-test-class-coverage@1' { '(?i)\b(?:exclu\w*|cover\w*)\b' }
            'bpm-test-class-coverage@2' { '(?i)\b(?:exclu\w*|cover\w*)\b' }
            'bpm-redundant-method-coverage@1' { '(?i)\b(?:method|exclu\w*|cover\w*)\b' }
            'bpm-redundant-method-coverage@2' { '(?i)\b(?:method|exclu\w*|cover\w*)\b' }
            default { '(?i)\b(?:AreEqual|named|expected|actual)\b' }
        }
        $relevant = @($Snapshot.Threads | Where-Object {
                $thread = $_
                $thread.anchor -and
                [string]$thread.anchor.path -ieq [string]$anchor.path -and
                @($lines | Where-Object {
                        [int]$thread.anchor.line -ge ([int]$_ - 2) -and
                        [int]$thread.anchor.line -le ([int]$_ + 2)
                    }).Count -gt 0 -and
                @($thread.comments | Where-Object {
                        [string]$_.commentType -ceq 'text' -and -not $_.isDeleted -and
                        [string]$_.body -match $discussionPattern
                    }).Count -gt 0
            })
        $unanchored = @($Snapshot.Threads | Where-Object {
                -not $_.anchor -and
                @($_.comments | Where-Object {
                        [string]$_.commentType -ceq 'text' -and -not $_.isDeleted -and
                        [string]$_.body -match $discussionPattern
                    }).Count -gt 0
            })
        if ($unanchored.Count -gt 0) { $classification = 'unknown' }
        if ($classification -ceq 'wouldCreate' -and
            $Capability -cin @('bpm-test-class-coverage@2',
                'bpm-redundant-method-coverage@2') -and
            @($relevant | Where-Object {
                    @($_.comments | Where-Object {
                            [string]$_.body -cmatch
                                '<!--\s*devpilot-(?:test-class-coverage|redundant-method-coverage):v1:[0-9a-f]{64}\s*-->'
                        }).Count -gt 0
                }).Count -gt 0) {
            $classification = 'unknown'
        }
        if ($classification -ceq 'wouldUpdate' -or
            ($classification -ceq 'wouldCreate' -and
                ([string]$reconciliation.reason -cne 'reviewer-marker-not-found' -or
                    @($relevant | Where-Object {
                            [string]$_.status -cne 'active' -or
                            [string]$_.contextState -cne 'current' -or $_.isOutdated -or
                            [int]$_.anchor.line -notin $lines
                        }).Count -gt 0))) {
            $classification = 'unknown'
        }
        if (($classification -ceq 'noOp' -or $classification -ceq 'humanCovered') -and
            $relevant.Count -gt 1) {
            $classification = 'unknown'
        }
        if ($classification -ceq 'noOp' -or $classification -ceq 'humanCovered') {
            $threadId = $reconciliation.thread.threadId
            $matched = @($Snapshot.Threads | Where-Object threadId -EQ $threadId)
            if ($matched.Count -ne 1 -or
                [string]$matched[0].contextState -cne 'current' -or
                [string]$matched[0].sourceCommit -cne $Contract.Request.SourceCommit -or
                [string]$matched[0].status -cne 'active' -or
                [bool]$matched[0].isDeleted -or [bool]$matched[0].isOutdated) {
                $classification = 'unknown'
            }
        }
        if (-not $counts.ContainsKey($classification)) { $classification = 'unknown' }
        $counts[$classification]++
        [void]$outcomes.Add([ordered]@{
                findingDigest = Get-RuleDigest @($Capability, $anchor.path,
                    [int]$anchor.line, $anchor.symbol, $finding.constructRef)
                classification = $classification
                reason = if ($classification -ceq [string]$reconciliation.classification) {
                    [string]$reconciliation.reason
                } else { 'discussion-needs-review' }
            })
    }
    if (($counts.noOp + $counts.humanCovered + $counts.wouldCreate + $counts.unknown) -ne $findings) {
        return @{ state = 'unknown'; reason = 'rule-ambiguous'
            findings = $findings; unknown = [Math]::Max(1, $findings) }
    }
    return @{ state = 'evaluated'; reason = 'completed'; findings = $findings
        noOp = [int]$counts.noOp; humanCovered = [int]$counts.humanCovered
        wouldCreate = [int]$counts.wouldCreate; unknown = [int]$counts.unknown
        discussionDigest = $Snapshot.Digest.Substring(10)
        findingOutcomes = @($outcomes) }
}

function Invoke-BoundedRuleEvaluation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Collections.IDictionary]$Config,
        [Parameter(Mandatory)][Collections.IDictionary]$IntakeConfig,
        [Parameter(Mandatory)][scriptblock]$Provider,
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [string]$SignatureKey, [scriptblock]$OwnerEvaluator,
        [int[]]$CanaryPullRequestIds, [switch]$Run)
    Assert-RuleConfig $Config $IntakeConfig $SignatureKey ([bool]$Run)
    if (-not $Run -or -not $Config.enabled) {
        return @{ schemaVersion = 1; kind = 'scheduled-rule-evaluation-disabled'
            enabled = $false; providerReads = 0; providerWrites = 0 }
    }
    if (-not [IO.Path]::IsPathFullyQualified($StateRoot) -or
        -not [IO.Path]::IsPathFullyQualified($RepositoryRoot)) {
        throw 'Rule evaluation state must be an absolute path outside the repository.'
    }
    $relative = [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($RepositoryRoot),
        [IO.Path]::GetFullPath($StateRoot))
    if ($relative -eq '.' -or
        ($relative -notmatch '^\.\.[\\/]|^\.\.$' -and
            -not [IO.Path]::IsPathFullyQualified($relative))) {
        throw 'Rule evaluation state must be an absolute path outside the repository.'
    }
    $state = Resolve-AgentTrustedRoot -Path $StateRoot -Kind durable-state `
        -RepositoryRoot $RepositoryRoot
    $intake = Assert-RuleIntake $state $Config $IntakeConfig $RepositoryRoot
    $canary = $Config['canary']
    if ($null -ne $canary -or $PSBoundParameters.ContainsKey('CanaryPullRequestIds')) {
        if ($canary -isnot [Collections.IDictionary] -or
            $canary.schemaVersion -ne 1 -or
            $canary.intakeGeneration -cne $intake.generation -or
            $canary.intakeConfigDigest -cne $intake.binding.configDigest -or
            $canary.heads -isnot [array] -or
            $canary.heads.Count -lt 1 -or $canary.heads.Count -gt 2 -or
            $CanaryPullRequestIds.Count -ne $canary.heads.Count -or
            $Config.limits.maxHeadsPerRun -gt 2) {
            throw 'canary-binding-mismatch'
        }
        $seenCanaries = [Collections.Generic.HashSet[int]]::new()
        foreach ($pin in $canary.heads) {
            $id = Assert-RuleNumber $pin.pullRequestId pullRequestId 1 ([int]::MaxValue)
            $head = @($intake.heads | Where-Object pullRequestId -EQ $id)
            if (-not $seenCanaries.Add($id) -or
                $id -notin $CanaryPullRequestIds -or $head.Count -ne 1 -or
                $head[0].targetRef -cne 'refs/heads/master' -or
                $head[0].status -cne 'pending' -or
                $null -eq $head[0].lineEvidence -or
                $pin.sourceCommit -cne $head[0].sourceCommit -or
                $pin.targetCommit -cne $head[0].targetCommit -or
                $pin.targetRef -cne $head[0].targetRef -or
                $pin.iterationId -ne $head[0].iterationId -or
                $pin.declarationDigest -cne $head[0].declarationDigest -or
                $pin.lineEvidenceDigest -cne $head[0].lineEvidenceDigest) {
                throw 'canary-binding-mismatch'
            }
        }
    }
    $root = Resolve-AgentTrustedRoot -Path (Join-Path $state 'rule-evaluation-v1') `
        -Kind durable-state -RepositoryRoot $RepositoryRoot -Create
    $generations = Resolve-AgentTrustedRoot -Path (Join-Path $root 'generations') `
        -Kind durable-state -RepositoryRoot $RepositoryRoot -Create
    $observations = Resolve-AgentTrustedRoot -Path (Join-Path $root 'observations') `
        -Kind durable-state -RepositoryRoot $RepositoryRoot -Create
    $declarations = Resolve-AgentTrustedRoot -Path (Join-Path $root 'declarations') `
        -Kind durable-state -RepositoryRoot $RepositoryRoot -Create
    $lockPath = Join-Path $root 'cohort.lock'
    $lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        $latestPath = Join-Path $root 'cohort.json'
        $previous = $null
        if (Test-Path -LiteralPath $latestPath) {
            $latest = Read-RuleJson $latestPath
            $previous = $latest.value
            if ($previous.kind -cne 'scheduled-rule-evaluation-cohort' -or
                [string]$previous.generation -cnotmatch '^[a-f0-9]{32}$' -or
                $previous.binding.organization -cne $Config.organization -or
                [string]$previous.binding.projectId -ine $Config.projectId -or
                [string]$previous.binding.repositoryId -ine $Config.repositoryId -or
                [string]$previous.binding.configDigest -cne (Get-RuleDigest $Config) -or
                $previous.generationFile -cne
                    (Join-Path 'generations' "$($previous.generation).json")) {
                throw 'previous-rule-cohort-invalid'
            }
            $immutable = Read-RuleJson (Join-Path $root $previous.generationFile)
            if (-not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
                    $latest.bytes, $immutable.bytes)) { throw 'previous-rule-cohort-changed' }
        }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $reads = 0
        $limits = $Config.limits
        $identity = Invoke-RuleRead $Provider Identity @{} ([ref]$reads) `
            $limits.maxReads $clock $limits.maxSeconds
        if ($identity.id -ine $IntakeConfig.expectedAccount.id -or
            $identity.descriptor -cne $IntakeConfig.expectedAccount.descriptor -or
            $identity.uniqueName -ine $IntakeConfig.expectedAccount.uniqueName) {
            throw 'account-mismatch'
        }
        $eligible = @($intake.heads | Where-Object targetRef -CEQ 'refs/heads/master' |
            Sort-Object { [int]$_.pullRequestId })
        $start = 0
        if ($previous -and $previous.cursor.nextPullRequestId -and $eligible.Count) {
            $next = Assert-RuleNumber $previous.cursor.nextPullRequestId cursor 1 ([int]::MaxValue)
            while ($start -lt $eligible.Count -and
                $eligible[$start].pullRequestId -lt $next) { $start++ }
            if ($start -eq $eligible.Count) { $start = 0 }
        }
        $selected = [Collections.Generic.HashSet[int]]::new()
        $limit = if ($null -ne $canary) { $canary.heads.Count }
        else { [Math]::Min([int]$limits.maxHeadsPerRun, $eligible.Count) }
        if ($null -ne $canary) {
            foreach ($pin in $canary.heads) {
                [void]$selected.Add([int]$pin.pullRequestId)
            }
        } else {
            for ($i = 0; $i -lt $limit; $i++) {
                [void]$selected.Add([int]$eligible[($start + $i) % $eligible.Count].pullRequestId)
            }
        }
        $generation = [guid]::NewGuid().ToString('N')
        $cohort = [ordered]@{
            schemaVersion = 1; kind = 'scheduled-rule-evaluation-cohort'
            generation = $generation
            generationFile = Join-Path 'generations' "$generation.json"
            intakeGeneration = $intake.generation
            binding = [ordered]@{
                organization = $Config.organization
                projectId = ([string]$Config.projectId).ToLowerInvariant()
                repositoryId = ([string]$Config.repositoryId).ToLowerInvariant()
                configDigest = Get-RuleDigest $Config
            }
            observedUtc = $null
            mode = 'dry-run-read-only'; writerEligible = $false; providerWrites = 0
            inventory = [ordered]@{
                state = 'complete'; discovered = $intake.inventory.discovered
                eligible = $intake.inventory.eligible
                excludedOtherTargets = $intake.inventory.excludedOtherTargets
                draftExcluded = $intake.inventory.draft
            }
            cursor = [ordered]@{ nextPullRequestId = if ($eligible.Count -and
                    $null -eq $canary) {
                    $eligible[($start + $limit) % $eligible.Count].pullRequestId
                } else { $null } }
            heads = @(); rules = @(); gaps = @()
        }
        $heads = [Collections.Generic.List[object]]::new()
        foreach ($head in $intake.heads) {
            $id = [int]$head.pullRequestId
            $picked = $selected.Contains($id)
            $stateName = if ($head.targetRef -cne 'refs/heads/master') {
                'skipped'
            } elseif ($null -eq $head.lineEvidence) { 'unknown' }
            elseif (-not $picked) { 'pending' }
            else { 'pending' }
            $reason = if ($stateName -eq 'skipped') { 'target-out-of-policy' }
            elseif ($stateName -eq 'unknown') { 'changed-lines-unknown' }
            elseif (-not $picked) { 'not-selected' }
            else { 'queued' }
            $entry = [ordered]@{ pullRequestId = $id; sourceCommit = $head.sourceCommit
                targetCommit = $head.targetCommit; targetRef = $head.targetRef
                iterationId = $head.iterationId; rules = @($Config.rules | ForEach-Object {
                        [ordered]@{ capabilityId = $_.capabilityId; ruleId = $_.ruleId
                            status = if (-not $_.enabled) { 'skipped' } else { $stateName }
                            reasonCode = if (-not $_.enabled) { 'rule-disabled' } else { $reason }
                            observationDigest = $null; declarationDigest = $null }
                    }) }
            if ($picked -and $head.lineEvidence -and
                @($entry.rules | Where-Object status -NE 'skipped').Count -gt 0) {
                try {
                    $declaration = $head.declaration
                    $before = Invoke-RuleRead $Provider Head @{ pullRequestId = $id } `
                        ([ref]$reads) $limits.maxReads $clock $limits.maxSeconds
                    Assert-RuleHead $before $declaration
                    $changed = Invoke-RuleRead $Provider Changes @{
                        pullRequestId = $id; iterationId = $declaration.iterationId
                        sourceCommit = $declaration.sourceCommit
                        targetCommit = $declaration.targetCommit
                        commonCommit = $declaration.commonCommit
                        includeEvaluationFiles = $true
                        includeProjectEvidence = (@($Config.rules | Where-Object {
                                    $_.enabled -and $_.capabilityId -cin @(
                                        'bpm-test-class-coverage@2',
                                        'bpm-redundant-method-coverage@2')
                                }).Count -gt 0)
                    } ([ref]$reads) $limits.maxReads $clock $limits.maxSeconds
                    $digestFiles = @($changed.files)
                    if ($changed.changedLines -ne $head.lineEvidence.changedLines -or
                        $changed.changedFiles -ne $head.lineEvidence.changedFiles -or
                        $changed.baseCommit -cne $declaration.commonCommit -or
                        $digestFiles.Count -ne $head.lineEvidence.files.Count -or
                        $changed.evaluationFiles -isnot [array]) {
                        throw 'changed-lines-mismatch'
                    }
                    $files = [Collections.Generic.List[object]]::new()
                    $totalBytes = 0
                    foreach ($proof in $head.lineEvidence.files) {
                        $match = @($digestFiles | Where-Object pathDigest -CEQ $proof.pathDigest)
                        if ($match.Count -ne 1 -or
                            (Get-RuleDigest $match[0]) -cne (Get-RuleDigest $proof)) {
                            throw 'changed-lines-mismatch'
                        }
                        if ($proof.changeType -ceq 'delete') { continue }
                        $sources = @($changed.evaluationFiles | Where-Object {
                                (Get-RuleDigest $_.path) -ceq $proof.pathDigest
                            })
                        if ($sources.Count -ne 1 -or
                            [string]$sources[0].path -cnotmatch '^/[^?#\x00-\x1f]{1,2048}$' -or
                            $sources[0].content -isnot [string] -or
                            [string]$sources[0].objectId -cnotmatch '^[a-f0-9]{40}$' -or
                            [Text.Encoding]::UTF8.GetByteCount($sources[0].content) -gt
                                $IntakeConfig.limits.maxFileBytes) {
                            throw 'source-unverified'
                        }
                        $totalBytes += [Text.Encoding]::UTF8.GetByteCount(
                            $sources[0].content)
                        if ($totalBytes -gt $IntakeConfig.limits.maxTotalBytes) {
                            throw 'source-unverified'
                        }
                        $files.Add(@{ path = $sources[0].path; content = $sources[0].content
                            objectId = $sources[0].objectId
                            projectEvidence = $sources[0]['projectEvidence']
                            spans = $proof.spans })
                    }
                    if ($changed.evaluationFiles.Count -ne $files.Count) {
                        throw 'source-unverified'
                    }
                    $projectBound = $false
                    if ($head['projectEvidence'] -is [Collections.IDictionary] -and
                        $head.projectEvidence.complete -ceq $true -and
                        $changed['projectEvidence'] -is [Collections.IDictionary]) {
                        $expectedScope = [ordered]@{
                            schemaVersion = 1
                            kind = 'source-bound-project-scope-summary-v1'
                            repositoryId = $head.projectEvidence.repositoryId
                            sourceCommit = $head.projectEvidence.sourceCommit
                            rootTreeId = $head.projectEvidence.rootTreeId
                            complete = $head.projectEvidence.complete
                            files = $head.projectEvidence.files
                        }
                        $projectBound = (Get-RuleDigest $expectedScope) -ceq
                            (Get-RuleDigest $changed.projectEvidence)
                        if ($projectBound) {
                            foreach ($receipt in $head.projectEvidence.files) {
                                $source = @($files | Where-Object {
                                        (Get-RuleDigest $_.path) -ceq $receipt.pathDigest -and
                                        $_.objectId -ceq $receipt.objectId
                                    })
                                if ($receipt.status -cne 'complete' -or
                                    $source.Count -ne 1 -or
                                    $source[0].projectEvidence -isnot
                                        [Collections.IDictionary] -or
                                    (Get-RuleDigest $source[0].projectEvidence) -cne
                                        $receipt.attestationDigest) {
                                    $projectBound = $false
                                    break
                                }
                            }
                        }
                    }
                    $discussions = Invoke-RuleRead $Provider Discussions @{
                        pullRequestId = $id; iterationId = $declaration.iterationId
                    } ([ref]$reads) $limits.maxReads $clock $limits.maxSeconds
                    $discussion = Get-ActivePrDiscussionCounts $discussions $IntakeConfig $declaration
                    $after = Invoke-RuleRead $Provider Head @{ pullRequestId = $id } `
                        ([ref]$reads) $limits.maxReads $clock $limits.maxSeconds
                    Assert-RuleHead $after $declaration
                    foreach ($rule in $entry.rules) {
                        if ($rule.status -eq 'skipped') { continue }
                        $projectRule = $rule.capabilityId -cin @(
                            'bpm-test-class-coverage@2', 'bpm-redundant-method-coverage@2')
                        if ($projectRule -and -not $projectBound) {
                            $rule.status = 'unknown'
                            $rule.reasonCode = 'test-project-identity-unknown'
                            continue
                        }
                        if ($clock.Elapsed.TotalSeconds -ge $limits.maxSeconds) {
                            throw 'time-budget'
                        }
                        $ruleConfig = @($Config.rules | Where-Object {
                                $_.capabilityId -ceq $rule.capabilityId
                            })[0]
                        $ruleDeclaration = [ordered]@{
                            schemaVersion = 1; kind = 'scheduled-rule-declaration'
                            generation = $generation; intakeGeneration = $intake.generation
                            pullRequestId = $id
                            sourceCommit = $declaration.sourceCommit
                            targetCommit = $declaration.targetCommit
                            targetRef = $declaration.targetRef
                            iterationId = $declaration.iterationId
                            intakeDeclarationDigest = $head.declarationDigest
                            lineEvidenceDigest = $head.lineEvidenceDigest
                            configDigest = $cohort.binding.configDigest
                            capabilityId = $rule.capabilityId; ruleId = $rule.ruleId
                            ruleBinding = if ($rule.capabilityId -ceq 'bpm-test-ownership@1') {
                                [ordered]@{
                                    ruleRepositoryId = [string]$ruleConfig.binding.ruleRepositoryId
                                    rulePath = [string]$ruleConfig.binding.rulePath
                                    ruleSection = [string]$ruleConfig.binding.ruleSection
                                    ruleCommit = [string]$ruleConfig.binding.ruleCommit
                                    ruleHash = [string]$ruleConfig.binding.ruleHash
                                    ruleLength = [int]$ruleConfig.binding.ruleLength
                                    capabilityDigest = [string]$ruleConfig.binding.capabilityDigest
                                }
                            } else {
                                [ordered]@{
                                    ruleRepositoryId = [string]$ruleConfig.binding.ruleRepositoryId
                                    rulePath = [string]$ruleConfig.binding.rulePath
                                    ruleCommit = [string]$ruleConfig.binding.ruleCommit
                                    ruleHash = [string]$ruleConfig.binding.ruleHash
                                    capabilityDigest = [string]$ruleConfig.binding.capabilityDigest
                                }
                            }
                            maxFindingsPerHead = [int]$ruleConfig.maxFindingsPerHead
                            model = if ($rule.capabilityId -ceq 'bpm-test-ownership@1') {
                                [ordered]@{ id = [string]$ruleConfig.model.id
                                    digest = [string]$ruleConfig.model.digest }
                            } else { $null }
                            writerEligible = $false
                        }
                        if ($projectRule) {
                            $ruleDeclaration.projectEvidenceDigest =
                                $head.projectEvidenceDigest
                        }
                        $declarationBytes = [Text.UTF8Encoding]::new($false).GetBytes(
                            (ConvertTo-Json -InputObject $ruleDeclaration -Depth 16))
                        $rule.declarationDigest = [Convert]::ToHexString(
                            [Security.Cryptography.SHA256]::HashData(
                                $declarationBytes)).ToLowerInvariant()
                        Write-RuleArtifact (Join-Path $declarations `
                                "$($rule.declarationDigest).json") `
                            $declarationBytes -Immutable
                        $evaluation = if ($rule.capabilityId -ceq 'bpm-test-ownership@1') {
                            if ($null -eq $OwnerEvaluator) {
                                @{ state = 'unknown'; reason = 'owner-evaluator-unavailable'
                                    findings = 0; unknown = 1 }
                            } else {
                                & $OwnerEvaluator $declaration $files.ToArray() $discussion `
                                    $head.lineEvidence $generation $ruleConfig `
                                    $ruleDeclaration $rule.declarationDigest $discussions
                            }
                        } else {
                            $contract = New-RuleContract $Config $ruleConfig $declaration $RepositoryRoot
                            $snapshot = Get-ActivePrDiscussionSnapshot $discussions `
                                $IntakeConfig $declaration $contract
                            Get-RuleEvaluation $rule.capabilityId $files.ToArray() `
                                $ruleConfig.maxFindingsPerHead $contract $snapshot `
                                $declaration.repositoryId $declaration.sourceCommit
                        }
                        if ($projectRule) {
                            $finalProjectHead = Invoke-RuleRead $Provider Head @{
                                pullRequestId = $id
                            } ([ref]$reads) $limits.maxReads $clock $limits.maxSeconds
                            Assert-RuleHead $finalProjectHead $declaration
                        }
                        if ($rule.capabilityId -ceq 'bpm-test-ownership@1' -and $OwnerEvaluator) {
                            $postHead = Invoke-RuleRead $Provider Head @{ pullRequestId = $id } `
                                ([ref]$reads) $limits.maxReads $clock $limits.maxSeconds
                            Assert-RuleHead $postHead $declaration
                            $postChanges = Invoke-RuleRead $Provider Changes @{
                                pullRequestId = $id; iterationId = $declaration.iterationId
                                sourceCommit = $declaration.sourceCommit
                                targetCommit = $declaration.targetCommit
                                commonCommit = $declaration.commonCommit
                            } ([ref]$reads) $limits.maxReads $clock $limits.maxSeconds
                            if ($postChanges.changedLines -ne $head.lineEvidence.changedLines -or
                                $postChanges.changedFiles -ne $head.lineEvidence.changedFiles -or
                                $postChanges.baseCommit -cne $declaration.commonCommit -or
                                (Get-RuleDigest @($postChanges.files)) -cne
                                    (Get-RuleDigest @($head.lineEvidence.files))) {
                                throw 'changed-lines-mismatch'
                            }
                            $postDiscussions = Invoke-RuleRead $Provider Discussions @{
                                pullRequestId = $id; iterationId = $declaration.iterationId
                            } ([ref]$reads) $limits.maxReads $clock $limits.maxSeconds
                            [void](Get-ActivePrDiscussionCounts $postDiscussions `
                                $IntakeConfig $declaration)
                            if ((Get-RuleDigest $postDiscussions) -cne
                                (Get-RuleDigest $discussions)) {
                                throw 'discussion-head-mismatch'
                            }
                            $finalHead = Invoke-RuleRead $Provider Head @{
                                pullRequestId = $id
                            } ([ref]$reads) $limits.maxReads $clock $limits.maxSeconds
                            Assert-RuleHead $finalHead $declaration
                        }
                        if ($evaluation -isnot [Collections.IDictionary] -or
                            $evaluation.state -cnotin @('evaluated', 'unknown') -or
                            [string]$evaluation.reason -cnotmatch '^[a-z][a-z0-9-]{0,79}$' -or
                            (Assert-RuleNumber $evaluation.findings findings 0 32) -gt
                                $ruleConfig.maxFindingsPerHead -or
                            (Assert-RuleNumber $evaluation.unknown unknown 0 100000) -gt 32) {
                            $rule.status = 'unknown'; $rule.reasonCode = 'rule-ambiguous'
                            continue
                        }
                        if ($rule.capabilityId -ceq 'bpm-test-ownership@1' -and $OwnerEvaluator -and
                            $evaluation.state -ceq 'evaluated' -and
                            ($evaluation.completed -cne $true -or
                                $evaluation.providerWrites -cne 0 -or
                                $evaluation.writeToolInvocations -cne 0 -or
                                $evaluation.modelToolInvocations -cne 0 -or
                                (Assert-RuleNumber $evaluation.manifestEntryCount `
                                    manifestEntryCount 1 32) -ne 1 -or
                                $evaluation.durableProof -isnot
                                    [Collections.IDictionary] -or
                                [string]$evaluation.durableProof.identity -cnotmatch
                                    '^[a-f0-9]{64}$' -or
                                [string]$evaluation.durableProof.stateDigest -cne
                                    ('v1:sha256:' + [string]$evaluation.durableProof.identity) -or
                                [string]$evaluation.durableProof.observationDigest -cnotmatch
                                    '^v1:sha256:[a-f0-9]{64}$' -or
                                [string]$evaluation.manifestDigest -cnotmatch
                                    '^v1:sha256:[a-f0-9]{64}$' -or
                                $evaluation.intakeGeneration -cne $intake.generation -or
                                $evaluation.declarationDigest -cne
                                    $rule.declarationDigest -or
                                $evaluation.sourceCommit -cne $declaration.sourceCommit -or
                                $evaluation.targetCommit -cne $declaration.targetCommit -or
                                $evaluation.targetRef -cne $declaration.targetRef -or
                                $evaluation.iterationId -ne $declaration.iterationId -or
                                $evaluation.ruleId -cne $rule.ruleId)) {
                            $rule.status = 'unknown'; $rule.reasonCode = 'owner-proof-unbound'
                            continue
                        }
                        if ($evaluation.state -cne 'evaluated') {
                            $rule.status = 'unknown'
                            $rule.reasonCode = [string]$evaluation.reason
                            continue
                        }
                        $outcomes = @($evaluation.findingOutcomes)
                        $counts = @{ noOp = 0; humanCovered = 0; wouldCreate = 0
                            unknown = 0 }
                        $findingIds = [Collections.Generic.HashSet[string]]::new(
                            [StringComparer]::Ordinal)
                        $validOutcomes = $outcomes.Count -eq $evaluation.findings -and
                            [string]$evaluation.discussionDigest -cmatch '^[a-f0-9]{64}$'
                        foreach ($outcome in $outcomes) {
                            if ($outcome -isnot [Collections.IDictionary] -or
                                [string]$outcome.findingDigest -cnotmatch '^[a-f0-9]{64}$' -or
                                -not $findingIds.Add([string]$outcome.findingDigest) -or
                                -not $counts.ContainsKey([string]$outcome.classification) -or
                                [string]$outcome.reason -cnotmatch '^[a-z][a-z0-9-]{0,79}$') {
                                $validOutcomes = $false
                                break
                            }
                            $counts[[string]$outcome.classification]++
                        }
                        foreach ($classification in $counts.Keys) {
                            if ($evaluation[$classification] -cne $counts[$classification]) {
                                $validOutcomes = $false
                            }
                        }
                        if (-not $validOutcomes) {
                            $rule.status = 'unknown'; $rule.reasonCode = 'rule-ambiguous'
                            continue
                        }
                        $observation = [ordered]@{
                            schemaVersion = 1; kind = 'scheduled-rule-observation'
                            generation = $generation; intakeGeneration = $intake.generation
                            pullRequestId = $id
                            sourceCommit = $declaration.sourceCommit
                            targetCommit = $declaration.targetCommit
                            targetRef = $declaration.targetRef
                            iterationId = $declaration.iterationId
                            capabilityId = $rule.capabilityId; ruleId = $rule.ruleId
                            declarationDigest = $rule.declarationDigest
                            completedUtc = [DateTime]::UtcNow.ToString('o')
                            outcome = [ordered]@{ findings = [int]$evaluation.findings
                                noOp = $counts.noOp; humanCovered = $counts.humanCovered
                                wouldCreate = $counts.wouldCreate
                                unknown = $counts.unknown }
                            discussionDigest = [string]$evaluation.discussionDigest
                            findingOutcomes = $outcomes
                            ownerProof = if ($rule.capabilityId -ceq 'bpm-test-ownership@1') {
                                [ordered]@{
                                    completed = $evaluation.completed
                                    manifestDigest = $evaluation.manifestDigest
                                    manifestEntryCount = $evaluation.manifestEntryCount
                                    providerWrites = $evaluation.providerWrites
                                    writeToolInvocations = $evaluation.writeToolInvocations
                                    modelToolInvocations = $evaluation.modelToolInvocations
                                    identity = $evaluation.durableProof.identity
                                    stateDigest = $evaluation.durableProof.stateDigest
                                    observationDigest = $evaluation.durableProof.observationDigest
                                    recordFileDigest =
                                        $evaluation.durableProof.recordFileDigest
                                    manifestFileDigest =
                                        $evaluation.durableProof.manifestFileDigest
                                    acquisitionPayloadDigest =
                                        $evaluation.durableProof.acquisitionPayloadDigest
                                }
                            } else { $null }
                            providerWrites = 0; modelToolInvocations = 0
                        }
                        if ($projectRule) {
                            $observation.projectEvidenceDigest =
                                $head.projectEvidenceDigest
                        }
                        $bytes = [Text.UTF8Encoding]::new($false).GetBytes(
                            (ConvertTo-Json -InputObject $observation -Depth 16))
                        $digest = [Convert]::ToHexString(
                            [Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
                        Write-RuleArtifact (Join-Path $observations "$digest.json") $bytes -Immutable
                        $rule.status = 'evaluated'; $rule.reasonCode = 'completed'
                        $rule.observationDigest = $digest
                    }
                    if ($null -ne $canary) {
                        $finalDiscussions = Invoke-RuleRead $Provider Discussions @{
                            pullRequestId = $id; iterationId = $declaration.iterationId
                        } ([ref]$reads) $limits.maxReads $clock $limits.maxSeconds
                        [void](Get-ActivePrDiscussionCounts $finalDiscussions `
                            $IntakeConfig $declaration)
                        if ((Get-RuleDigest $finalDiscussions) -cne
                            (Get-RuleDigest $discussions)) {
                            throw 'discussion-head-mismatch'
                        }
                        $finalHead = Invoke-RuleRead $Provider Head @{ pullRequestId = $id } `
                            ([ref]$reads) $limits.maxReads $clock $limits.maxSeconds
                        Assert-RuleHead $finalHead $declaration
                    }
                    if ($clock.Elapsed.TotalSeconds -ge $limits.maxSeconds) {
                        throw 'time-budget'
                    }
                }
                catch {
                    $code = [string]$_.Exception.Message
                    if ($code -cin @('immutable-rule-artifact-changed',
                            'untrusted-state-file', 'rule-state-budget')) {
                        $code = 'state-integrity-failed'
                    }
                    if ($code -cnotin @('head-drift', 'head-left-policy', 'changed-lines-mismatch',
                            'source-unverified', 'read-budget', 'time-budget',
                            'account-mismatch', 'invalid-discussions', 'mutable-discussions',
                            'comment-budget', 'state-integrity-failed',
                            'rule-binding-unavailable', 'discussion-head-mismatch')) {
                        $code = 'ado-read-failed'
                    }
                    foreach ($rule in $entry.rules) {
                        if ($rule.status -ne 'skipped') {
                            $rule.status = if ($code -in @('ado-read-failed',
                                    'state-integrity-failed')) { 'error' } else { 'unknown' }
                            $rule.reasonCode = $code
                            $rule.observationDigest = $null
                        }
                    }
                }
            }
            $heads.Add($entry)
        }
        $cohort.heads = @($heads.ToArray())
        $summaries = [Collections.Generic.List[object]]::new()
        foreach ($configured in $Config.rules) {
            $results = @($cohort.heads | ForEach-Object {
                    @($_.rules | Where-Object capabilityId -CEQ $configured.capabilityId)
                })
            $gaps = @($results | Where-Object status -IN @('error', 'unknown') |
                ForEach-Object reasonCode | Sort-Object -Unique)
            $summaries.Add([ordered]@{
                    capabilityId = $configured.capabilityId; ruleId = $configured.ruleId
                    discovered = $intake.inventory.discovered
                    eligible = $intake.inventory.eligible
                    evaluated = @($results | Where-Object status -EQ 'evaluated').Count
                    skipped = @($results | Where-Object status -EQ 'skipped').Count
                    unknown = @($results | Where-Object status -EQ 'unknown').Count
                    error = @($results | Where-Object status -EQ 'error').Count
                    pending = @($results | Where-Object status -EQ 'pending').Count
                    gaps = $gaps
                })
        }
        $cohort.rules = @($summaries.ToArray())
        $cohort.observedUtc = [DateTime]::UtcNow.ToString('o')
        $cohort.readCount = $reads
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes(
            (ConvertTo-Json -InputObject $cohort -Depth 32))
        Write-RuleArtifact (Join-Path $generations "$generation.json") $bytes -Immutable
        Write-RuleArtifact $latestPath $bytes
        return $cohort
    }
    finally { $lock.Dispose() }
}

function Assert-BoundedCandidateIntake {
    param([string]$StateRoot, [Collections.IDictionary]$Dispatcher,
        [Collections.IDictionary]$IntakeConfig, [string]$RepositoryRoot)
    $validation = @{
        organization = $Dispatcher.organization
        projectId = $Dispatcher.projectId
        repositoryId = $Dispatcher.repositoryId
        limits = @{ maxIntakeAgeMinutes = 15 }
    }
    return Assert-RuleIntake $StateRoot $validation $IntakeConfig $RepositoryRoot
}

function Invoke-BoundedCandidateParser {
    param([Collections.IDictionary]$Dispatcher, [Collections.IDictionary]$Rule,
        [Collections.IDictionary]$Head, [object[]]$Files,
        [Collections.IDictionary]$Discussions, [Collections.IDictionary]$IntakeConfig,
        [int]$MaximumFindings)
    $contract = New-OwnerAcquisitionContract `
        -RepositoryId $Head.repositoryId -ProjectId $Head.projectId `
        -PullRequestId $Head.pullRequestId -SourceCommit $Head.sourceCommit `
        -TargetCommit $Head.targetCommit -TargetRef $Head.targetRef `
        -RuleRepositoryId $Rule.repositoryId -RulePath $Rule.path `
        -RuleCommit $Rule.commit -RuleSection $Rule.section `
        -RuleHash $Rule.hash -RuleLength $Rule.length `
        -ConfigId $(if ($Dispatcher.schemaVersion -eq 3) {
                'private-merged-master-canary-v1'
            } else { 'private-canary-signed-intake-v1' }) `
        -ConfigDigest ('v1:sha256:' + (Get-RuleTextDigest (
                    ConvertTo-AgentCanonicalJson -InputObject $Dispatcher))) `
        -CapabilityId $Rule.id -CapabilityDigest $Rule.declarationDigest
    $snapshot = Get-ActivePrDiscussionSnapshot $Discussions $IntakeConfig $Head $contract
    return Get-RuleEvaluation $Rule.id $Files $MaximumFindings $contract `
        $snapshot $Head.repositoryId $Head.sourceCommit
}

Export-ModuleMember -Function Invoke-BoundedRuleEvaluation,
    Assert-BoundedCandidateIntake, Invoke-BoundedCandidateParser
