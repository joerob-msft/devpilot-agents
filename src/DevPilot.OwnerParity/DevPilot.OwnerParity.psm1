#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\..\OwnerObserver\OwnerObserver.psd1" -Force
Import-Module "$PSScriptRoot\..\DevPilot.OwnerOrchestrator\DevPilot.OwnerOrchestrator.psd1" -Force
Import-Module "$PSScriptRoot\..\OwnerObservationContract\OwnerObservationContract.psd1" -Force
. "$PSScriptRoot\OwnerParityPaths.ps1"

$script:OwnerParitySchemaPath = Join-Path $PSScriptRoot 'schemas/owner-parity-qualification.v1.json'
$script:OwnerParityRepositoryRoot = Resolve-OwnerParitySecurePath `
    -Path (Join-Path $PSScriptRoot '..\..') -Name RepositoryRoot -Kind Directory
$script:OwnerParityStatuses = @('passed', 'failed', 'blocked', 'notMeasured')
$script:OwnerParityUnknown = 'unknown'

function Get-OwnerParityMember {
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

function Get-OwnerParitySha256 {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))).ToLowerInvariant()
}

function Get-OwnerParityTextSha256 {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return Get-OwnerParitySha256 -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($Text))
}

function Assert-OwnerParityProspectiveTelemetry {
    param(
        [Parameter(Mandatory)][object]$Observation,
        [Parameter(Mandatory)][string]$TelemetryPath,
        [Parameter(Mandatory)][string]$V2StateRoot
    )
    $resolved = Resolve-OwnerParityAbsolutePath `
        -Path $TelemetryPath -Name candidate.telemetryPath -Kind File
    if (-not (Test-OwnerParityPathWithin -Path $resolved -Root $V2StateRoot)) {
        throw 'Candidate telemetryPath must be inside V2StateRoot.'
    }
    $bytes = [IO.File]::ReadAllBytes($resolved)
    if ($bytes.Length -gt 4MB) { throw 'Candidate telemetry exceeds 4 MiB.' }
    try {
        $telemetry = ([Text.UTF8Encoding]::new($false, $true).GetString($bytes)) |
            ConvertFrom-Json -AsHashtable -Depth 64
    }
    catch {
        throw 'Candidate telemetry failed UTF-8 JSON validation.'
    }
    $telemetrySha = Get-OwnerParitySha256 -Bytes $bytes
    $artifactMatches = @($Observation.sourceArtifacts | Where-Object {
            [string]$_.kind -ceq 'owner-model-runner-telemetry' -and
            [string]$_.sha256 -ceq $telemetrySha
        })
    $attempts = Get-OwnerParityMember $telemetry 'attempts'
    $latency = Get-OwnerParityMember $telemetry 'latencyMs'
    $modelStarts = Get-OwnerParityMember $telemetry 'modelStarts'
    $records = @(Get-OwnerParityMember $telemetry 'records')
    $provider = Get-OwnerParityMember $telemetry 'provider'
    $policy = Get-OwnerParityMember $telemetry 'policy'
    if ($artifactMatches.Count -ne 1 -or
        [string](Get-OwnerParityMember $provider 'kind') -cne 'copilot-cli' -or
        [string]::IsNullOrWhiteSpace([string](Get-OwnerParityMember $provider 'modelIdentity')) -or
        @(Get-OwnerParityMember $telemetry 'effectiveTools').Count -ne 0 -or
        [int](Get-OwnerParityMember $telemetry 'providerWrites' -1) -ne 0 -or
        @(Get-OwnerParityMember $policy 'availableTools').Count -ne 0 -or
        (Get-OwnerParityMember $policy 'providerWrite' $true) -ne $false -or
        $attempts -is [bool] -or
        ($attempts -isnot [int] -and $attempts -isnot [long]) -or
        [long]$attempts -ne [long]$Observation.execution.attempts -or
        $records.Count -ne [long]$attempts -or
        $latency -is [bool] -or
        ($latency -isnot [int] -and $latency -isnot [long]) -or
        [long]$latency -ne [long]$Observation.execution.latencyMs -or
        [string]$modelStarts -cne [string]$Observation.execution.modelStarts -or
        ([long]$attempts -gt 0 -and
            @($records | Where-Object processStarted -eq $true).Count -eq 0)) {
        throw 'Candidate prospective telemetry did not prove the normalized real-model execution.'
    }
    return $telemetry
}

function Test-OwnerParityPathWithin {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )
    return Test-OwnerParitySecurePathWithin -Path $Path -Root $Root
}

function Assert-OwnerParityNoLinks {
    param([Parameter(Mandatory)][string]$Path)
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($item -and (
                ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                $null -ne $item.LinkType)) {
            throw "Owner parity path '$Path' traverses a link or reparse point."
        }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
}

function Resolve-OwnerParityAbsolutePath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('Any', 'File', 'Directory')][string]$Kind = 'Any',
        [switch]$AllowMissing
    )
    return Resolve-OwnerParitySecurePath `
        -Path $Path -Name $Name -Kind $Kind -AllowMissing:$AllowMissing
}

function Test-OwnerParityPathIsolation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$V1StateRoot,
        [Parameter(Mandatory)][string]$V2StateRoot,
        [string]$RepositoryRoot = $script:OwnerParityRepositoryRoot
    )
    $v1 = Resolve-OwnerParityAbsolutePath -Path $V1StateRoot -Name 'V1StateRoot' -Kind Directory
    $v2 = Resolve-OwnerParityAbsolutePath -Path $V2StateRoot -Name 'V2StateRoot' -AllowMissing
    $repository = Resolve-OwnerParityAbsolutePath -Path $RepositoryRoot -Name 'RepositoryRoot' -Kind Directory
    $isolated = -not (
        (Test-OwnerParityPathWithin -Path $v1 -Root $v2) -or
        (Test-OwnerParityPathWithin -Path $v2 -Root $v1) -or
        (Test-OwnerParityPathWithin -Path $v2 -Root $repository))
    return [pscustomobject][ordered]@{
        isolated = $isolated
        v1StateRoot = $v1
        v2StateRoot = $v2
        repositoryRoot = $repository
    }
}

function Get-OwnerParityStateSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)
    $resolved = Resolve-OwnerParityAbsolutePath -Path $Root -Name Root -Kind Directory
    $files = @(Get-ChildItem -LiteralPath $resolved -Recurse -File -Force | Sort-Object FullName)
    $lines = [Collections.Generic.List[string]]::new()
    $byteCount = 0L
    $newestTicks = 0L
    foreach ($file in $files) {
        Assert-OwnerParityNoLinks -Path $file.FullName
        $relative = $file.FullName.Substring($resolved.Length).TrimStart(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar)
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $ticks = [long]$file.LastWriteTimeUtc.Ticks
        $byteCount += [long]$file.Length
        if ($ticks -gt $newestTicks) { $newestTicks = $ticks }
        [void]$lines.Add("$relative|$($file.Length)|$ticks|$hash")
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        kind = 'owner-parity-state-snapshot'
        root = $resolved
        fileCount = $files.Count
        byteCount = $byteCount
        newestWriteTicks = $newestTicks
        rootHash = Get-OwnerParityTextSha256 -Text ($lines -join "`n")
    }
}

function Compare-OwnerParitySnapshots {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Before,
        [Parameter(Mandatory)][object]$After
    )
    $fields = @('fileCount', 'byteCount', 'newestWriteTicks', 'rootHash')
    $differences = @(
        foreach ($field in $fields) {
            if ((Get-OwnerParityMember $Before $field) -cne (Get-OwnerParityMember $After $field)) {
                $field
            }
        }
    )
    return [pscustomobject][ordered]@{
        unchanged = $differences.Count -eq 0
        differences = $differences
        before = $Before
        after = $After
    }
}

function New-OwnerParityRollbackProof {
    param(
        [AllowNull()][object]$Expected,
        [Parameter(Mandatory)][object]$Before,
        [Parameter(Mandatory)][object]$After
    )
    $during = Compare-OwnerParitySnapshots -Before $Before -After $After
    $differences = [Collections.Generic.List[string]]::new()
    $baseline = $null
    if ($null -ne $Expected) {
        $baseline = Compare-OwnerParitySnapshots -Before $Expected -After $Before
        foreach ($field in @($baseline.differences)) {
            [void]$differences.Add("preexisting:$field")
        }
    }
    foreach ($field in @($during.differences)) {
        [void]$differences.Add("during:$field")
    }
    return [pscustomobject][ordered]@{
        unchanged = $differences.Count -eq 0
        differences = @($differences)
        expected = $Expected
        qualificationBefore = $Before
        after = $After
    }
}

function New-OwnerParityGate {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('passed', 'failed', 'blocked', 'notMeasured')]
        [string]$Status,
        [Parameter(Mandatory)][string]$EvidenceCode,
        [int]$Measured = 0,
        [int]$Failures = 0,
        [int]$Blocked = 0
    )
    return [ordered]@{
        name = $Name
        status = $Status
        evidenceCode = $EvidenceCode
        measured = $Measured
        failures = $Failures
        blocked = $Blocked
    }
}

function Get-OwnerParityFindingMap {
    param([Parameter(Mandatory)][object]$Observation)
    $map = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($finding in @($Observation.findings)) {
        $identity = [string](Get-OwnerParityMember $finding 'identity' '')
        $disposition = [string](Get-OwnerParityMember $finding 'disposition' '')
        $key = "$disposition|$identity"
        if ($map.ContainsKey($key)) {
            throw "Observation contains duplicate finding selector '$key'."
        }
        $map[$key] = $finding
    }
    return $map
}

function Resolve-OwnerParitySelector {
    param(
        [AllowNull()][object]$Selector,
        [Parameter(Mandatory)][Collections.Generic.Dictionary[string, object]]$Map
    )
    if ($null -eq $Selector) { return $null }
    $identity = [string](Get-OwnerParityMember $Selector 'identity' '')
    $disposition = [string](Get-OwnerParityMember $Selector 'disposition' '')
    $key = "$disposition|$identity"
    if ($Map.ContainsKey($key)) { return $Map[$key] }
    return $null
}

function Test-OwnerParityKnown {
    param([AllowNull()][object]$Value)
    return $null -ne $Value -and
        -not ($Value -is [string] -and
            ([string]::IsNullOrWhiteSpace($Value) -or $Value -ceq $script:OwnerParityUnknown))
}

function Test-OwnerParityAnchorEqual {
    param(
        [AllowNull()][object]$BaselineFinding,
        [AllowNull()][object]$CandidateFinding
    )
    if ($null -eq $BaselineFinding -or $null -eq $CandidateFinding) { return 'notMeasured' }
    $left = Get-OwnerParityMember $BaselineFinding 'semanticKey'
    $right = Get-OwnerParityMember $CandidateFinding 'semanticKey'
    if (-not (Test-OwnerParityKnown $left) -or -not (Test-OwnerParityKnown $right)) {
        return 'notMeasured'
    }
    return $(if ($left -ceq $right) { 'passed' } else { 'failed' })
}

function Test-OwnerParityObservationAccounting {
    param([Parameter(Mandatory)][object]$Observation)
    $measurements = Get-OwnerParityMember $Observation 'measurements'
    foreach ($path in @(
            @('counts', 'checked'),
            @('counts', 'eligible'),
            @('counts', 'advisory'),
            @('counts', 'violations'),
            @('counts', 'unknown'),
            @('counts', 'uncovered'),
            @('execution', 'attempts'),
            @('execution', 'modelStarts'),
            @('execution', 'latencyMs'),
            @('effects', 'operatorIntervention'),
            @('effects', 'providerWrites'),
            @('effects', 'writeToolInvocations'))) {
        $container = Get-OwnerParityMember $measurements $path[0]
        $measurement = Get-OwnerParityMember $container $path[1]
        $status = [string](Get-OwnerParityMember $measurement 'status' '')
        if ($status -notin @('measured', 'unavailable', 'notMeasured')) {
            return $false
        }
        $value = Get-OwnerParityMember $measurement 'value'
        if (($status -ceq 'measured' -and $null -eq $value) -or
            ($status -cne 'measured' -and $null -ne $value)) { return $false }
    }
    return $true
}

function Invoke-OwnerParityGateEvaluation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Baseline,
        [Parameter(Mandatory)][object]$Candidate,
        [Parameter(Mandatory)][object]$Evidence,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Adjudication
    )
    if (-not (Test-OwnerObservation -Observation $Baseline) -or
        -not (Test-OwnerObservation -Observation $Candidate)) {
        throw 'Owner parity gate evaluation requires valid normalized observations.'
    }
    $baselineMap = Get-OwnerParityFindingMap -Observation $Baseline
    $candidateMap = Get-OwnerParityFindingMap -Observation $Candidate
    $evidenceClass = [string](Get-OwnerParityMember $Evidence 'class' 'unknown')
    $inputContract = [string](Get-OwnerParityMember $Evidence 'inputContract' 'unknown')
    $truthCoverage = [string](Get-OwnerParityMember $Evidence 'truthCoverage' 'none')
    $semanticProvenance = [string](Get-OwnerParityMember $Evidence 'semanticProvenance' 'unknown')
    $semanticEvidence = $semanticProvenance -in @(
        'offline-replay-recorded-model',
        'prospective-real-model')
    $strongEvidence = $evidenceClass -ceq 'preserved-exact-bytes' -and
        $inputContract -ceq 'independently-validated' -and
        $semanticEvidence
    $provenanceEvidenceCode = if ($semanticProvenance -ceq 'offline-replay-deterministic') {
        'deterministic-oracle-not-semantic-evidence'
    }
    else {
        'provenance-insufficient'
    }

    $units = @(
        foreach ($unit in $Adjudication) {
            $baselineSelector = Get-OwnerParityMember $unit 'baseline'
            $candidateSelector = Get-OwnerParityMember $unit 'candidate'
            $baselineFinding = Resolve-OwnerParitySelector `
                -Selector $baselineSelector -Map $baselineMap
            $candidateFinding = Resolve-OwnerParitySelector `
                -Selector $candidateSelector -Map $candidateMap
            if ($null -ne $baselineSelector -and $null -eq $baselineFinding) {
                throw "Adjudication '$([string](Get-OwnerParityMember $unit 'key'))' references a missing baseline finding."
            }
            [pscustomobject][ordered]@{
                source = $unit
                baselineFinding = $baselineFinding
                candidateFinding = $candidateFinding
            }
        }
    )

    $baselineViolations = @($Baseline.findings | Where-Object disposition -CEQ 'violation')
    $candidateViolations = @($Candidate.findings | Where-Object disposition -CEQ 'violation')
    $baselineViolationCount = Get-OwnerParityMember `
        $Baseline.counts 'violations' $script:OwnerParityUnknown
    $candidateViolationCount = Get-OwnerParityMember `
        $Candidate.counts 'violations' $script:OwnerParityUnknown
    $baselineViolationInventoryConsistent =
        (Test-OwnerParityKnown $baselineViolationCount) -and
        [int]$baselineViolationCount -eq $baselineViolations.Count
    $candidateViolationInventoryConsistent =
        (Test-OwnerParityKnown $candidateViolationCount) -and
        [int]$candidateViolationCount -eq $candidateViolations.Count
    $candidateViolationMetric = if (Test-OwnerParityKnown $candidateViolationCount) {
        [int]$candidateViolationCount
    }
    else {
        $candidateViolations.Count
    }
    $mappedBaselineViolationKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($unit in $units) {
        if ($null -eq $unit.baselineFinding -or
            [string]$unit.baselineFinding.disposition -cne 'violation') {
            continue
        }
        $eligibility = [string](Get-OwnerParityMember $unit.source 'eligibility')
        $truth = [string](Get-OwnerParityMember $unit.source 'truth')
        $conclusive = ($eligibility -ceq 'method' -and $truth -in @('violation', 'compliant')) -or
            $eligibility -ceq 'class-advisory'
        if (-not $conclusive) { continue }
        $selector = Get-OwnerParityMember $unit.source 'baseline'
        [void]$mappedBaselineViolationKeys.Add(
            'violation|' + [string](Get-OwnerParityMember $selector 'identity' ''))
    }
    $unadjudicatedBaselineViolations = @($baselineViolations | Where-Object {
            -not $mappedBaselineViolationKeys.Contains('violation|' + [string]$_.identity)
        }).Count
    $verifiedUnits = @($units | Where-Object {
            [string](Get-OwnerParityMember $_.source 'eligibility') -ceq 'method' -and
            [string](Get-OwnerParityMember $_.source 'truth') -ceq 'violation' -and
            $null -ne $_.baselineFinding -and
            [string]$_.baselineFinding.disposition -ceq 'violation'
        })
    $retainedCount = @($verifiedUnits | Where-Object {
            $null -ne $_.candidateFinding -and
            [string]$_.candidateFinding.disposition -ceq 'violation'
        }).Count
    $missingVerifiedCount = $verifiedUnits.Count - $retainedCount
    $retentionGate = if ($strongEvidence -and
        $Candidate.findingsComplete -eq $true -and
        $candidateViolationInventoryConsistent -and
        $missingVerifiedCount -gt 0) {
        New-OwnerParityGate -Name findingRetention -Status failed `
            -EvidenceCode 'verified-method-findings-lost' -Measured $verifiedUnits.Count `
            -Failures $missingVerifiedCount
    }
    elseif ($Baseline.findingsComplete -ne $true -or
        -not $baselineViolationInventoryConsistent -or
        $unadjudicatedBaselineViolations -gt 0) {
        New-OwnerParityGate -Name findingRetention -Status blocked `
            -EvidenceCode 'baseline-findings-or-adjudication-incomplete' `
            -Measured $verifiedUnits.Count `
            -Blocked ([Math]::Max(1, $unadjudicatedBaselineViolations))
    }
    elseif ($verifiedUnits.Count -eq 0) {
        New-OwnerParityGate -Name findingRetention -Status notMeasured `
            -EvidenceCode 'no-verified-method-findings'
    }
    elseif (-not $strongEvidence) {
        New-OwnerParityGate -Name findingRetention -Status blocked `
            -EvidenceCode $provenanceEvidenceCode `
            -Measured $verifiedUnits.Count -Blocked $verifiedUnits.Count
    }
    elseif ($Candidate.findingsComplete -ne $true -or
        -not $candidateViolationInventoryConsistent) {
        New-OwnerParityGate -Name findingRetention -Status blocked `
            -EvidenceCode 'candidate-findings-incomplete' `
            -Measured $verifiedUnits.Count -Blocked ([Math]::Max(1, $missingVerifiedCount))
    }
    elseif ($retainedCount -eq $verifiedUnits.Count) {
        New-OwnerParityGate -Name findingRetention -Status passed `
            -EvidenceCode 'all-verified-method-findings-retained' -Measured $verifiedUnits.Count
    }
    else {
        throw 'Owner parity retention evaluation reached an inconsistent state.'
    }

    $mappedCandidateViolationKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $eligibleFalsePositives = 0
    $unadjudicatedCandidateViolations = 0
    $unresolvedNonRetentionSelectors = @($units | Where-Object {
            $null -ne (Get-OwnerParityMember $_.source 'candidate') -and
            $null -eq $_.candidateFinding -and
            -not (
                [string](Get-OwnerParityMember $_.source 'eligibility') -ceq 'method' -and
                [string](Get-OwnerParityMember $_.source 'truth') -ceq 'violation'
            )
        }).Count
    foreach ($unit in $units) {
        if ($null -eq $unit.candidateFinding -or
            [string]$unit.candidateFinding.disposition -cne 'violation') { continue }
        $candidateSelector = Get-OwnerParityMember $unit.source 'candidate'
        $candidateKey = 'violation|' + [string](Get-OwnerParityMember $candidateSelector 'identity' '')
        $eligibility = [string](Get-OwnerParityMember $unit.source 'eligibility')
        $truth = [string](Get-OwnerParityMember $unit.source 'truth')
        $conclusive = ($eligibility -ceq 'method' -and $truth -in @('violation', 'compliant')) -or
            $eligibility -ceq 'class-advisory'
        if ($conclusive) { [void]$mappedCandidateViolationKeys.Add($candidateKey) }
        if ($eligibility -ceq 'method' -and $truth -ceq 'compliant') {
            $eligibleFalsePositives++
        }
    }
    foreach ($finding in $candidateViolations) {
        $key = 'violation|' + [string]$finding.identity
        if (-not $mappedCandidateViolationKeys.Contains($key)) { $unadjudicatedCandidateViolations++ }
    }
    $falsePositiveGate = if ($Candidate.findingsComplete -ne $true -or
        -not $candidateViolationInventoryConsistent) {
        New-OwnerParityGate -Name eligibleFalsePositives -Status blocked `
            -EvidenceCode 'candidate-findings-incomplete' -Measured $candidateViolationMetric `
            -Blocked ([Math]::Max(1, $unadjudicatedCandidateViolations))
    }
    elseif ($unresolvedNonRetentionSelectors -gt 0) {
        New-OwnerParityGate -Name eligibleFalsePositives -Status blocked `
            -EvidenceCode 'candidate-selectors-unresolved' -Measured $candidateViolations.Count `
            -Blocked $unresolvedNonRetentionSelectors
    }
    elseif ($truthCoverage -cne 'complete') {
        New-OwnerParityGate -Name eligibleFalsePositives -Status blocked `
            -EvidenceCode 'adjudicated-truth-incomplete' -Measured $candidateViolations.Count `
            -Blocked ([Math]::Max(1, $unadjudicatedCandidateViolations))
    }
    elseif (-not $strongEvidence) {
        New-OwnerParityGate -Name eligibleFalsePositives -Status blocked `
            -EvidenceCode $provenanceEvidenceCode `
            -Measured $candidateViolations.Count -Blocked 1
    }
    elseif ($eligibleFalsePositives -gt 0) {
        New-OwnerParityGate -Name eligibleFalsePositives -Status failed `
            -EvidenceCode 'new-comment-eligible-false-positive' -Measured $candidateViolations.Count `
            -Failures $eligibleFalsePositives
    }
    elseif ($unadjudicatedCandidateViolations -gt 0) {
        New-OwnerParityGate -Name eligibleFalsePositives -Status blocked `
            -EvidenceCode 'candidate-findings-unadjudicated' -Measured $candidateViolations.Count `
            -Blocked $unadjudicatedCandidateViolations
    }
    else {
        New-OwnerParityGate -Name eligibleFalsePositives -Status passed `
            -EvidenceCode 'zero-new-eligible-false-positives' -Measured $candidateViolations.Count
    }

    $bindingFields = @(
        @('capability', $Baseline.capability, $Candidate.capability),
        @('subject.pullRequestId', $Baseline.subject.pullRequestId, $Candidate.subject.pullRequestId),
        @('subject.repositoryId', $Baseline.subject.repositoryId, $Candidate.subject.repositoryId),
        @('subject.headCommit', $Baseline.subject.headCommit, $Candidate.subject.headCommit),
        @('subject.targetCommit', $Baseline.subject.targetCommit, $Candidate.subject.targetCommit),
        @('subject.targetRef', $Baseline.subject.targetRef, $Candidate.subject.targetRef),
        @('rule.path', $Baseline.rule.path, $Candidate.rule.path),
        @('rule.section', $Baseline.rule.section, $Candidate.rule.section),
        @('rule.commit', $Baseline.rule.commit, $Candidate.rule.commit),
        @('rule.sha256', $Baseline.rule.sha256, $Candidate.rule.sha256)
    )
    $bindingMismatches = 0
    $bindingUnknown = 0
    foreach ($field in $bindingFields) {
        if (-not (Test-OwnerParityKnown $field[1]) -or -not (Test-OwnerParityKnown $field[2])) {
            $bindingUnknown++
        }
        elseif ($field[1] -cne $field[2]) {
            $bindingMismatches++
        }
    }
    $anchorMeasured = 0
    $anchorFailures = 0
    foreach ($unit in $units) {
        $anchor = Test-OwnerParityAnchorEqual `
            -BaselineFinding $unit.baselineFinding -CandidateFinding $unit.candidateFinding
        if ($anchor -ceq 'passed') { $anchorMeasured++ }
        elseif ($anchor -ceq 'failed') { $anchorMeasured++; $anchorFailures++ }
    }
    $bindingGate = if ($bindingMismatches + $anchorFailures -gt 0) {
        New-OwnerParityGate -Name bindingEquivalence -Status failed `
            -EvidenceCode 'binding-mismatch' `
            -Measured (($bindingFields.Count - $bindingUnknown) + $anchorMeasured) `
            -Failures ($bindingMismatches + $anchorFailures)
    }
    elseif ($unresolvedNonRetentionSelectors -gt 0) {
        New-OwnerParityGate -Name bindingEquivalence -Status blocked `
            -EvidenceCode 'candidate-selectors-unresolved' `
            -Measured (($bindingFields.Count - $bindingUnknown) + $anchorMeasured) `
            -Blocked $unresolvedNonRetentionSelectors
    }
    elseif ($bindingUnknown -eq $bindingFields.Count) {
        New-OwnerParityGate -Name bindingEquivalence -Status notMeasured `
            -EvidenceCode 'bindings-unavailable'
    }
    else {
        New-OwnerParityGate -Name bindingEquivalence -Status passed `
            -EvidenceCode 'canonical-semantic-bindings-equal' `
            -Measured (($bindingFields.Count - $bindingUnknown) + $anchorMeasured)
    }
    $providerMarkers = @($units | ForEach-Object {
            foreach ($finding in @($_.baselineFinding, $_.candidateFinding)) {
                if ($null -eq $finding) { continue }
                $marker = Get-OwnerParityMember $finding 'providerMarker'
                [ordered]@{
                    availability = [string](Get-OwnerParityMember $marker 'availability' 'unavailable')
                    integrity = [string](Get-OwnerParityMember $marker 'integrity' 'unavailable')
                }
            }
        })

    $baselineUnknowns = @($Baseline.findings | Where-Object disposition -CEQ 'unknown')
    $mappedBaselineUnknownKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $unknownFailures = 0
    $unknownBlocked = 0
    foreach ($unit in $units) {
        if ($null -eq $unit.baselineFinding -or
            [string]$unit.baselineFinding.disposition -cne 'unknown') { continue }
        $baselineSelector = Get-OwnerParityMember $unit.source 'baseline'
        [void]$mappedBaselineUnknownKeys.Add(
            'unknown|' + [string](Get-OwnerParityMember $baselineSelector 'identity' ''))
        if ($null -eq $unit.candidateFinding) {
            $unknownBlocked++
        }
        elseif ([string]$unit.candidateFinding.disposition -cne 'unknown') {
            $unknownFailures++
        }
    }
    foreach ($finding in $baselineUnknowns) {
        if (-not $mappedBaselineUnknownKeys.Contains('unknown|' + [string]$finding.identity)) {
            $unknownBlocked++
        }
    }
    $baselineUnknownCount = Get-OwnerParityMember $Baseline.counts 'unknown' $script:OwnerParityUnknown
    if (-not (Test-OwnerParityKnown $baselineUnknownCount)) {
        $unknownBlocked++
    }
    elseif ([int]$baselineUnknownCount -gt $baselineUnknowns.Count) {
        $unknownBlocked += [int]$baselineUnknownCount - $baselineUnknowns.Count
    }
    elseif ([int]$baselineUnknownCount -lt $baselineUnknowns.Count) {
        $unknownBlocked++
    }
    if ($Baseline.findingsComplete -ne $true) { $unknownBlocked++ }
    $candidateUnknowns = @($Candidate.findings | Where-Object disposition -CEQ 'unknown')
    $candidateUnknownCount = Get-OwnerParityMember `
        $Candidate.counts 'unknown' $script:OwnerParityUnknown
    if ($Candidate.findingsComplete -ne $true -or
        -not (Test-OwnerParityKnown $candidateUnknownCount) -or
        [int]$candidateUnknownCount -ne $candidateUnknowns.Count) {
        $unknownBlocked++
    }
    $baselineUncovered = Get-OwnerParityMember $Baseline.counts 'uncovered' $script:OwnerParityUnknown
    if (Test-OwnerParityKnown $baselineUncovered) {
        $unknownBlocked += [int]$baselineUncovered
    }
    else {
        $unknownBlocked++
    }
    $unknownGate = if ($unknownFailures -gt 0) {
        New-OwnerParityGate -Name unknownIntegrity -Status failed `
            -EvidenceCode 'unknown-converted-to-known' -Measured $baselineUnknowns.Count `
            -Failures $unknownFailures
    }
    elseif ($unknownBlocked -gt 0) {
        New-OwnerParityGate -Name unknownIntegrity -Status blocked `
            -EvidenceCode 'unit-outcome-not-exposed' -Measured $baselineUnknowns.Count `
            -Blocked $unknownBlocked
    }
    elseif ($baselineUnknowns.Count -eq 0 -and
        (-not (Test-OwnerParityKnown $baselineUncovered) -or [int]$baselineUncovered -eq 0)) {
        New-OwnerParityGate -Name unknownIntegrity -Status notMeasured `
            -EvidenceCode 'no-baseline-unknown-units'
    }
    else {
        New-OwnerParityGate -Name unknownIntegrity -Status passed `
            -EvidenceCode 'all-baseline-unknown-units-remain-unknown' -Measured $baselineUnknowns.Count
    }

    $candidateProviderWrites = $Candidate.effects.providerWrites
    $candidateToolWrites = $Candidate.effects.writeToolInvocations
    $offlineProvenance = $semanticProvenance -in @(
        'offline-replay-recorded-model',
        'offline-replay-deterministic')
    $writeGate = if (
        ((Test-OwnerParityKnown $candidateProviderWrites) -and
            [long]$candidateProviderWrites -ne 0) -or
        ((Test-OwnerParityKnown $candidateToolWrites) -and
            [long]$candidateToolWrites -ne 0)) {
        New-OwnerParityGate -Name writeIsolation -Status failed `
            -EvidenceCode 'candidate-write-observed' -Measured 2 -Failures 1
    }
    elseif (-not (Test-OwnerParityKnown $candidateProviderWrites) -or
        -not (Test-OwnerParityKnown $candidateToolWrites)) {
        New-OwnerParityGate -Name writeIsolation -Status blocked `
            -EvidenceCode 'candidate-write-accounting-unknown' -Blocked 1
    }
    elseif (-not $offlineProvenance -and $semanticProvenance -cne 'prospective-real-model') {
        New-OwnerParityGate -Name writeIsolation -Status blocked `
            -EvidenceCode 'execution-provenance-unknown' -Measured 2 -Blocked 1
    }
    else {
        New-OwnerParityGate -Name writeIsolation -Status passed `
            -EvidenceCode 'zero-provider-and-tool-writes' -Measured 2
    }

    $latencyGate = if (
        (Test-OwnerParityObservationAccounting -Observation $Baseline) -and
        (Test-OwnerParityObservationAccounting -Observation $Candidate)) {
        New-OwnerParityGate -Name latencyAccounting -Status passed `
            -EvidenceCode 'measurement-state-explicit' -Measured 24
    }
    else {
        New-OwnerParityGate -Name latencyAccounting -Status failed `
            -EvidenceCode 'accounting-field-omitted' -Measured 24 -Failures 1
    }

    return [pscustomobject][ordered]@{
        gates = @(
            $retentionGate
            $falsePositiveGate
            $bindingGate
            $unknownGate
            $writeGate
            $latencyGate
        )
        metrics = [ordered]@{
            verifiedMethodFindings = $verifiedUnits.Count
            retainedMethodFindings = $retainedCount
            candidateViolations = $candidateViolationMetric
            eligibleFalsePositives = $eligibleFalsePositives
            baselineUnknownFindings = $baselineUnknowns.Count
            candidateCompleted = $Candidate.lifecycle.completed
            baselineCompleted = $Baseline.lifecycle.completed
            retentionMeasured = [string]$retentionGate.status -in @('passed', 'failed')
            retentionPopulationKnown = [string]$retentionGate.status -cne 'blocked'
            falsePositiveMeasured = [string]$falsePositiveGate.status -in @('passed', 'failed')
            providerMarkersAvailable = @($providerMarkers |
                Where-Object availability -CEQ 'available').Count
            providerMarkersVerified = @($providerMarkers |
                Where-Object integrity -CEQ 'verified').Count
            providerMarkersInvalid = @($providerMarkers |
                Where-Object integrity -CEQ 'invalid').Count
        }
    }
}

function Read-OwnerParityManifest {
    param([Parameter(Mandatory)][string]$Path)
    $resolved = Resolve-OwnerParityAbsolutePath -Path $Path -Name QualificationManifestPath -Kind File
    $bytes = [IO.File]::ReadAllBytes($resolved)
    if ($bytes.Length -gt 4MB) { throw 'Owner parity qualification manifest exceeds 4 MiB.' }
    try {
        $text = ([Text.UTF8Encoding]::new($false, $true)).GetString($bytes)
        if (-not (Test-Json -Json $text -SchemaFile $script:OwnerParitySchemaPath -ErrorAction Stop)) {
            throw 'schema'
        }
        $manifest = $text | ConvertFrom-Json -AsHashtable -Depth 64
    }
    catch {
        throw 'Owner parity qualification manifest failed schema or UTF-8 JSON validation.'
    }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $headKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $referenceIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $referencePaths = [Collections.Generic.HashSet[string]]::new(
        $(if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }))
    foreach ($reference in @($manifest.attestation.critical) + @($manifest.attestation.volatile)) {
        if (-not $referenceIds.Add([string]$reference.id)) {
            throw "Owner parity attestation reference id '$($reference.id)' is duplicated."
        }
        $relative = ConvertTo-OwnerParityRelativePath `
            -Path ([string]$reference.relativePath) -Name attestation.relativePath
        if (-not $referencePaths.Add($relative)) {
            throw "Owner parity attestation path '$relative' is duplicated or case-colliding."
        }
    }
    $candidateReferences = [Collections.Generic.HashSet[string]]::new(
        $(if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }))
    foreach ($entry in @($manifest.entries)) {
        if (-not $ids.Add([string]$entry.id)) {
            throw "Owner parity qualification entry id '$($entry.id)' is duplicated."
        }
        if (-not $headKeys.Add([string]$entry.baseline.headKey)) {
            throw "Owner parity qualification baseline headKey '$($entry.baseline.headKey)' is duplicated."
        }
        if ([string]$entry.candidate.mode -ceq 'read') {
            $candidateProvenance = [string](Get-OwnerParityMember `
                    $entry.candidate 'semanticProvenance' 'unknown')
            if ([string]$entry.evidence.semanticProvenance -cne $candidateProvenance) {
                throw "Owner parity qualification entry '$($entry.id)' candidate and evidence provenance must match."
            }
            $candidateReference = 'read|' + (Resolve-OwnerParityAbsolutePath `
                    -Path ([string]$entry.candidate.observationPath) `
                    -Name candidate.observationPath -Kind File -AllowMissing) + '|' +
                $(if ($candidateProvenance -ceq 'prospective-real-model') {
                        Resolve-OwnerParityAbsolutePath `
                            -Path ([string]$entry.candidate.telemetryPath) `
                            -Name candidate.telemetryPath -Kind File -AllowMissing
                    }
                    else { 'none' })
            if (-not $candidateReferences.Add($candidateReference)) {
                throw "Owner parity qualification candidate observation is reused by multiple entries."
            }
        }
        elseif ([string]$entry.candidate.mode -ceq 'run') {
            $candidateReference = 'run|' + (Resolve-OwnerParityAbsolutePath `
                    -Path ([string]$entry.candidate.manifestPath) `
                    -Name candidate.manifestPath -Kind File -AllowMissing) + '|' +
                [string]$entry.candidate.entryId
            if (-not $candidateReferences.Add($candidateReference)) {
                throw "Owner parity qualification candidate replay is reused by multiple entries."
            }
        }
        $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $baselineSelectors = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $candidateSelectors = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($unit in @($entry.adjudication)) {
            if (-not $keys.Add([string]$unit.key)) {
                throw "Owner parity qualification entry '$($entry.id)' has duplicate adjudication keys."
            }
            if ($null -ne $unit.baseline) {
                $selector = [string]$unit.baseline.disposition + '|' +
                    [string]$unit.baseline.identity
                if (-not $baselineSelectors.Add($selector)) {
                    throw "Owner parity qualification entry '$($entry.id)' reuses a baseline selector."
                }
            }
            if ($null -ne $unit.candidate) {
                $selector = [string]$unit.candidate.disposition + '|' +
                    [string]$unit.candidate.identity
                if (-not $candidateSelectors.Add($selector)) {
                    throw "Owner parity qualification entry '$($entry.id)' reuses a candidate selector."
                }
            }
        }
    }
    return [pscustomobject][ordered]@{
        path = $resolved
        sha256 = Get-OwnerParitySha256 -Bytes $bytes
        value = $manifest
    }
}

function Get-OwnerParityCandidateProvenance {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Candidate,
        [AllowNull()][Collections.IDictionary]$Manifest
    )
    switch -CaseSensitive ([string]$Candidate.mode) {
        'unavailable' { return 'unavailable' }
        'read' { return 'unknown' }
        'run' {
            if ($null -ne $Manifest -and
                [string]$Manifest.entries[0].model.id -ceq 'owner-offline-deterministic-replay') {
                return 'offline-replay-deterministic'
            }
            return 'unknown'
        }
    }
    return 'unknown'
}

function Resolve-OwnerParityCandidate {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Candidate,
        [Parameter(Mandatory)][string]$V2StateRoot
    )
    if ([string]$Candidate.mode -ceq 'unavailable') {
        return [pscustomobject][ordered]@{
            observation = $null
            observationPath = $null
            runState = 'blocked'
            blockingReason = [string]$Candidate.reason
            runReason = [string]$Candidate.reason
            semanticProvenance = 'unavailable'
            errorId = $null
            candidateCompleted = $script:OwnerParityUnknown
        }
    }
    if ([string]$Candidate.mode -ceq 'read') {
        $observationPath = Resolve-OwnerParityAbsolutePath `
            -Path ([string]$Candidate.observationPath) -Name observationPath -Kind File
        if (-not (Test-OwnerParityPathWithin -Path $observationPath -Root $V2StateRoot)) {
            throw 'Candidate observationPath must be inside V2StateRoot.'
        }
        $observation = Read-OwnerNormalizedObservation -Path $observationPath
        $semanticProvenance = [string](Get-OwnerParityMember `
                $Candidate 'semanticProvenance' 'unknown')
        if ($semanticProvenance -ceq 'prospective-real-model') {
            [void](Assert-OwnerParityProspectiveTelemetry `
                    -Observation $observation `
                    -TelemetryPath ([string]$Candidate.telemetryPath) `
                    -V2StateRoot $V2StateRoot)
        }
        return [pscustomobject][ordered]@{
            observation = $observation
            observationPath = $observationPath
            runState = 'read'
            blockingReason = $null
            runReason = 'provided-observation'
            semanticProvenance = $semanticProvenance
            errorId = $null
            candidateCompleted = $observation.lifecycle.completed
        }
    }

    $manifestPath = Resolve-OwnerParityAbsolutePath `
        -Path ([string]$Candidate.manifestPath) -Name candidate.manifestPath -Kind File
    $v2Manifest = Get-Content -LiteralPath $manifestPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 64
    if (@($v2Manifest.entries).Count -ne 1 -or
        [string]$v2Manifest.entries[0].id -cne [string]$Candidate.entryId) {
        throw 'Each parity candidate manifest must contain exactly its declared entryId.'
    }
    $semanticProvenance = Get-OwnerParityCandidateProvenance `
        -Candidate $Candidate -Manifest $v2Manifest
    try {
        $prepared = Invoke-OwnerV2PreviewPrepare -StateRoot $V2StateRoot -ManifestPath $manifestPath
    }
    catch {
        $reason = if ($_.Exception.Message -match '^JSON value at .+ looked sensitive\.$') {
            'manifest-rejected-sensitive-content'
        }
        else {
            'candidate-prepare-failed'
        }
        return [pscustomobject][ordered]@{
            observation = $null
            observationPath = $null
            runState = 'blocked'
            blockingReason = $reason
            runReason = $reason
            semanticProvenance = $semanticProvenance
            errorId = [string]$_.FullyQualifiedErrorId
            candidateCompleted = $script:OwnerParityUnknown
        }
    }
    try {
        $run = Invoke-OwnerV2PreviewRun -StateRoot $V2StateRoot -ManifestPath $manifestPath
    }
    catch {
        return [pscustomobject][ordered]@{
            observation = $null
            observationPath = $null
            runState = 'blocked'
            blockingReason = 'candidate-run-failed'
            runReason = 'candidate-run-failed'
            semanticProvenance = $semanticProvenance
            errorId = [string]$_.FullyQualifiedErrorId
            candidateCompleted = $script:OwnerParityUnknown
        }
    }
    $record = @($prepared.records)
    if ($record.Count -ne 1) { throw 'Owner v2 prepare did not return exactly one parity record.' }
    $runRecord = @($run.records)
    if ($runRecord.Count -ne 1 -or
        [string]$runRecord[0].identity -cne [string]$record[0].identity) {
        throw 'Owner v2 run did not return the prepared parity record.'
    }
    $candidateState = [string]$runRecord[0].state
    $runReason = [string]$runRecord[0].reason
    $blockingReason = if ($candidateState -cne 'completed') {
        switch -CaseSensitive ($runReason) {
            'launcher-unavailable' { 'candidate-launcher-unavailable' }
            'orchestrator-refusal' { 'candidate-orchestrator-refusal' }
            'reservation-lost' { 'candidate-reservation-lost' }
            'lease-active' { 'candidate-lease-active' }
            'maximum-attempts' { 'candidate-maximum-attempts' }
            'not-prepared' { 'candidate-not-prepared' }
            default { 'candidate-run-incomplete' }
        }
    }
    else { $null }
    $observationPath = Join-Path (
        Join-Path ([string]$record[0].capabilityRoot) 'observations'
    ) "$([string]$record[0].identity).json"
    $observationPath = Resolve-OwnerParityAbsolutePath `
        -Path $observationPath -Name 'generated candidate observation' -Kind File -AllowMissing
    if (-not (Test-OwnerParityPathWithin -Path $observationPath -Root $V2StateRoot)) {
        throw 'Generated candidate observation escaped V2StateRoot.'
    }
    if (-not (Test-Path -LiteralPath $observationPath -PathType Leaf)) {
        $knownIncomplete = $candidateState -in @('incomplete', 'unknown')
        return [pscustomobject][ordered]@{
            observation = $null
            observationPath = $observationPath
            runState = 'blocked'
            blockingReason = 'candidate-observation-absent'
            runReason = $runReason
            semanticProvenance = $semanticProvenance
            errorId = $null
            candidateCompleted = $(if ($knownIncomplete) {
                    $false
                }
                else {
                    $script:OwnerParityUnknown
                })
        }
    }
    try {
        $observation = Read-OwnerNormalizedObservation -Path $observationPath
    }
    catch {
        return [pscustomobject][ordered]@{
            observation = $null
            observationPath = $observationPath
            runState = 'blocked'
            blockingReason = 'candidate-observation-invalid'
            runReason = $runReason
            semanticProvenance = $semanticProvenance
            errorId = [string]$_.FullyQualifiedErrorId
            candidateCompleted = $(if ($candidateState -in @('incomplete', 'unknown')) {
                    $false
                }
                else {
                    $script:OwnerParityUnknown
                })
        }
    }
    return [pscustomobject][ordered]@{
        observation = $observation
        observationPath = $observationPath
        runState = $(if ($candidateState -cne 'completed') {
                'offline-replay-terminal-incomplete'
            }
            elseif ([bool]$record[0].created) {
                'offline-replay'
            }
            else {
                'offline-replay-existing-terminal'
            })
        blockingReason = $blockingReason
        runReason = $runReason
        semanticProvenance = $semanticProvenance
        errorId = $null
        candidateCompleted = $observation.lifecycle.completed
    }
}

function New-OwnerParityUnavailableEvaluation {
    param(
        [Parameter(Mandatory)][object]$Baseline,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Adjudication,
        [Parameter(Mandatory)][string]$Reason,
        [AllowNull()][object]$CandidateCompleted = $script:OwnerParityUnknown
    )
    $baselineMap = Get-OwnerParityFindingMap -Observation $Baseline
    $baselineViolations = @($Baseline.findings | Where-Object disposition -CEQ 'violation')
    $baselineViolationCount = Get-OwnerParityMember `
        $Baseline.counts 'violations' $script:OwnerParityUnknown
    $baselineViolationInventoryConsistent =
        (Test-OwnerParityKnown $baselineViolationCount) -and
        [int]$baselineViolationCount -eq $baselineViolations.Count
    $mappedBaselineViolations = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $verifiedMethodFindings = @(
        foreach ($unit in $Adjudication) {
            $baselineFinding = Resolve-OwnerParitySelector `
                -Selector (Get-OwnerParityMember $unit 'baseline') -Map $baselineMap
            if ($null -ne $baselineFinding -and
                [string]$baselineFinding.disposition -ceq 'violation') {
                $eligibility = [string](Get-OwnerParityMember $unit 'eligibility')
                $truth = [string](Get-OwnerParityMember $unit 'truth')
                $conclusive = ($eligibility -ceq 'method' -and
                    $truth -in @('violation', 'compliant')) -or
                    $eligibility -ceq 'class-advisory'
                if ($conclusive) {
                    $selector = Get-OwnerParityMember $unit 'baseline'
                    [void]$mappedBaselineViolations.Add(
                        'violation|' + [string](Get-OwnerParityMember $selector 'identity' ''))
                }
            }
            if ([string](Get-OwnerParityMember $unit 'eligibility') -cne 'method' -or
                [string](Get-OwnerParityMember $unit 'truth') -cne 'violation') {
                continue
            }
            if ($null -ne $baselineFinding -and
                [string]$baselineFinding.disposition -ceq 'violation') {
                $baselineFinding
            }
        }
    )
    $unadjudicatedBaselineViolations = @($baselineViolations | Where-Object {
            -not $mappedBaselineViolations.Contains('violation|' + [string]$_.identity)
        }).Count
    $baselineUnknowns = @($Baseline.findings | Where-Object disposition -CEQ 'unknown').Count
    $baselineUnknownCount = Get-OwnerParityMember $Baseline.counts 'unknown' $script:OwnerParityUnknown
    $baselineUncovered = Get-OwnerParityMember $Baseline.counts 'uncovered' $script:OwnerParityUnknown
    $blockedUnknowns = if (Test-OwnerParityKnown $baselineUnknownCount) {
        [Math]::Max($baselineUnknowns, [int]$baselineUnknownCount)
    }
    else {
        $baselineUnknowns + 1
    }
    if (Test-OwnerParityKnown $baselineUncovered) {
        $blockedUnknowns += [int]$baselineUncovered
    }
    else {
        $blockedUnknowns++
    }
    if ($Baseline.findingsComplete -ne $true) { $blockedUnknowns++ }
    $reasonCode = "candidate-unavailable-$Reason"
    $retentionGate = if ($Baseline.findingsComplete -ne $true -or
        -not $baselineViolationInventoryConsistent -or
        $unadjudicatedBaselineViolations -gt 0) {
        New-OwnerParityGate -Name findingRetention -Status blocked `
            -EvidenceCode 'baseline-findings-or-adjudication-incomplete' `
            -Blocked ([Math]::Max(1, $unadjudicatedBaselineViolations))
    }
    elseif ($verifiedMethodFindings.Count -gt 0) {
        New-OwnerParityGate -Name findingRetention -Status blocked `
            -EvidenceCode $reasonCode -Blocked $verifiedMethodFindings.Count
    }
    else {
        New-OwnerParityGate -Name findingRetention -Status notMeasured `
            -EvidenceCode 'no-verified-method-findings'
    }
    return [pscustomobject][ordered]@{
        gates = @(
            $retentionGate
            (New-OwnerParityGate -Name eligibleFalsePositives -Status blocked `
                    -EvidenceCode $reasonCode -Blocked 1)
            (New-OwnerParityGate -Name bindingEquivalence -Status blocked `
                    -EvidenceCode $reasonCode -Blocked 1)
            $(if ($blockedUnknowns -gt 0) {
                    New-OwnerParityGate -Name unknownIntegrity -Status blocked `
                        -EvidenceCode $reasonCode -Blocked $blockedUnknowns
                }
                else {
                    New-OwnerParityGate -Name unknownIntegrity -Status notMeasured `
                        -EvidenceCode 'no-baseline-unknown-units'
                })
            (New-OwnerParityGate -Name writeIsolation -Status blocked `
                    -EvidenceCode $reasonCode -Blocked 1)
            (New-OwnerParityGate -Name latencyAccounting -Status blocked `
                    -EvidenceCode $reasonCode -Blocked 12)
        )
        metrics = [ordered]@{
            verifiedMethodFindings = $verifiedMethodFindings.Count
            retainedMethodFindings = 0
            candidateViolations = 0
            eligibleFalsePositives = 0
            baselineUnknownFindings = $baselineUnknowns
            candidateCompleted = $CandidateCompleted
            baselineCompleted = $Baseline.lifecycle.completed
            retentionMeasured = $false
            retentionPopulationKnown = [string]$retentionGate.status -cne 'blocked'
            falsePositiveMeasured = $false
        }
    }
}

function Get-OwnerParityAggregateStatus {
    param([Parameter(Mandatory)][string[]]$Statuses)
    if ($Statuses -contains 'failed') { return 'failed' }
    if ($Statuses -contains 'blocked') { return 'blocked' }
    if ($Statuses -contains 'passed') { return 'passed' }
    return 'notMeasured'
}

function New-OwnerParityCompletionGate {
    param([Parameter(Mandatory)][object[]]$EntryReports)
    $candidateUnknownCompletion = @($EntryReports | Where-Object {
            $_.metrics.candidateCompleted -isnot [bool]
        }).Count
    $unknownCompletion = @($EntryReports | Where-Object {
            $_.metrics.baselineCompleted -isnot [bool] -or
            $_.metrics.candidateCompleted -isnot [bool]
        }).Count
    $measuredEntries = @($EntryReports | Where-Object {
            $_.metrics.baselineCompleted -is [bool] -and
            $_.metrics.candidateCompleted -is [bool]
        })
    $knownBaselineCompleted = @($EntryReports | Where-Object {
            $_.metrics.baselineCompleted -eq $true
        }).Count
    $knownCandidateCompleted = @($EntryReports | Where-Object {
            $_.metrics.candidateCompleted -eq $true
        }).Count
    $completionDecisivelyLower =
        ($knownCandidateCompleted + $candidateUnknownCompletion) -lt $knownBaselineCompleted
    $retentionEntries = @($EntryReports | Where-Object {
            $_.metrics.retentionMeasured -eq $true
        })
    $verified = [int](($retentionEntries | ForEach-Object {
                    [int]$_.metrics.verifiedMethodFindings
                } | Measure-Object -Sum).Sum)
    $retained = [int](($retentionEntries | ForEach-Object {
                    [int]$_.metrics.retainedMethodFindings
                } | Measure-Object -Sum).Sum)
    $unknownRetention = @($EntryReports | Where-Object {
            (Get-OwnerParityMember $_.metrics 'retentionPopulationKnown' $false) -ne $true
        }).Count
    $retentionReliable = $verified -eq 0 -or
        $retained -ge $verified
    if ($completionDecisivelyLower -or -not $retentionReliable) {
        return New-OwnerParityGate -Name completionReliability -Status failed `
            -EvidenceCode 'candidate-completion-or-retention-rate-lower' `
            -Measured $measuredEntries.Count -Failures 1
    }
    if ($unknownCompletion + $unknownRetention -gt 0) {
        return New-OwnerParityGate -Name completionReliability -Status blocked `
            -EvidenceCode 'completion-or-retention-unavailable' `
            -Measured $measuredEntries.Count -Blocked ($unknownCompletion + $unknownRetention)
    }
    if ($measuredEntries.Count -eq 0) {
        return New-OwnerParityGate -Name completionReliability -Status notMeasured `
            -EvidenceCode 'completion-unavailable'
    }
    return New-OwnerParityGate -Name completionReliability -Status passed `
        -EvidenceCode 'candidate-completion-and-retention-not-lower' -Measured $measuredEntries.Count
}

function Write-OwnerParityJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Value
    )
    $content = (ConvertTo-Json -InputObject $Value -Depth 64) + "`n"
    return Write-OwnerParitySecureText -Path $Path -Content $content
}

function ConvertTo-OwnerParitySanitizedSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Report)
    $entries = @($Report.entries)
    $gates = @($Report.gates)
    $verified = [int](($entries.metrics.verifiedMethodFindings | Measure-Object -Sum).Sum)
    $retentionEntries = @($entries | Where-Object { $_.metrics.retentionMeasured -eq $true })
    $retained = [int](($retentionEntries | ForEach-Object {
                [int]$_.metrics.retainedMethodFindings
            } | Measure-Object -Sum).Sum)
    $structuralMatches = [int](($entries.metrics.retainedMethodFindings | Measure-Object -Sum).Sum)
    $retentionUnmeasured = [int](($entries | Where-Object {
                    $_.metrics.retentionMeasured -ne $true
                } | ForEach-Object {
                    [int]$_.metrics.verifiedMethodFindings
                } | Measure-Object -Sum).Sum)
    $candidateViolations = [int](($entries.metrics.candidateViolations | Measure-Object -Sum).Sum)
    $falsePositiveEntries = @($entries | Where-Object {
            $_.metrics.falsePositiveMeasured -eq $true
        })
    $falsePositives = if ($falsePositiveEntries.Count -gt 0) {
        [int](($falsePositiveEntries.metrics.eligibleFalsePositives | Measure-Object -Sum).Sum)
    }
    else { $null }
    $baselineComplete = @($entries | Where-Object {
            $_.metrics.baselineCompleted -eq $true
        }).Count
    $candidateComplete = @($entries | Where-Object {
            $_.metrics.candidateCompleted -eq $true
        }).Count
    $candidateCompletionUnknown = @($entries | Where-Object {
            $_.metrics.candidateCompleted -isnot [bool]
        }).Count
    $prospectiveEntries = @($entries | Where-Object {
            $entryEvidence = Get-OwnerParityMember $_ 'evidence'
            [string](Get-OwnerParityMember `
                    $entryEvidence 'semanticProvenance' 'unknown') -ceq 'prospective-real-model'
        })
    $prospectiveStatus = if ($prospectiveEntries.Count -eq 0) {
        'blocked'
    }
    elseif (@($gates | Where-Object status -CEQ 'failed').Count -gt 0) {
        'failed'
    }
    elseif (@($gates | Where-Object status -CEQ 'blocked').Count -gt 0) {
        'blocked'
    }
    else {
        'passed'
    }
    return [ordered]@{
        schemaVersion = 2
        kind = 'owner-parity-sanitized-summary'
        scope = $(if ($prospectiveEntries.Count -gt 0) {
                'prospective-real-model'
            }
            else {
                'retrospective-offline'
            })
        sample = [ordered]@{
            entries = $entries.Count
            baselineCompleted = $baselineComplete
            candidateCompleted = $candidateComplete
            candidateCompletionUnknown = $candidateCompletionUnknown
            verifiedMethodFindings = $verified
            retainedMethodFindings = $retained
            retentionUnmeasured = $retentionUnmeasured
            structuralMethodMatches = $structuralMatches
            candidateViolations = $candidateViolations
            eligibleFalsePositives = $falsePositives
            falsePositiveMeasuredEntries = $falsePositiveEntries.Count
            falsePositiveUnmeasuredEntries = $entries.Count - $falsePositiveEntries.Count
        }
        gates = @(
            foreach ($gate in $gates) {
                [ordered]@{
                    name = [string]$gate.name
                    status = [string]$gate.status
                    evidenceCode = [string]$gate.evidenceCode
                    measured = [int]$gate.measured
                    failures = [int]$gate.failures
                    blocked = [int]$gate.blocked
                }
            }
        )
        prospectiveRealModel = [ordered]@{
            status = $prospectiveStatus
            evidenceCode = $(if ($prospectiveEntries.Count -eq 0) {
                    'safe-real-model-launcher-unavailable'
                }
                elseif ($prospectiveStatus -ceq 'passed') {
                    'prospective-real-model-qualified'
                }
                elseif ($prospectiveStatus -ceq 'failed') {
                    'prospective-real-model-gates-failed'
                }
                else {
                    'prospective-real-model-gates-blocked'
                })
        }
        rollback = [ordered]@{
            unchanged = [bool]$Report.rollback.unchanged
            differingFields = @($Report.rollback.differences).Count
        }
    }
}

function Invoke-OwnerParityQualification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$V1StateRoot,
        [Parameter(Mandatory)][string]$V2StateRoot,
        [Parameter(Mandatory)][string]$QualificationManifestPath,
        [Parameter(Mandatory)][string]$PrivateReportPath,
        [Parameter(Mandatory)][string]$SanitizedSummaryPath
    )
    $isolation = Test-OwnerParityPathIsolation `
        -V1StateRoot $V1StateRoot -V2StateRoot $V2StateRoot
    if (-not $isolation.isolated) {
        throw 'V2StateRoot must be separate from v1 and outside the repository.'
    }
    $privatePath = Resolve-OwnerParityAbsolutePath `
        -Path $PrivateReportPath -Name PrivateReportPath -AllowMissing
    $summaryPath = Resolve-OwnerParityAbsolutePath `
        -Path $SanitizedSummaryPath -Name SanitizedSummaryPath -AllowMissing
    foreach ($path in @($privatePath, $summaryPath)) {
        if (Test-OwnerParityPathWithin -Path $path -Root $isolation.v1StateRoot) {
            throw 'Owner parity output paths must not be inside V1StateRoot.'
        }
        if (Test-OwnerParityPathWithin -Path $privatePath -Root $script:OwnerParityRepositoryRoot) {
            throw 'PrivateReportPath must be outside the repository.'
        }
    }
    [void](Resolve-OwnerParityAbsolutePath `
            -Path (Split-Path -Parent $privatePath) -Name PrivateReportDirectory -Kind Directory)
    [void](Resolve-OwnerParityAbsolutePath `
            -Path (Split-Path -Parent $summaryPath) -Name SanitizedSummaryDirectory -Kind Directory)

    $manifest = Read-OwnerParityManifest -Path $QualificationManifestPath
    if (-not (Test-Path -LiteralPath $isolation.v2StateRoot)) {
        [void](New-Item -ItemType Directory -Path $isolation.v2StateRoot)
    }
    [void](Resolve-OwnerParityAbsolutePath `
            -Path $isolation.v2StateRoot -Name V2StateRoot -Kind Directory)
    $before = Get-OwnerParityAttestationSnapshot `
        -Root $isolation.v1StateRoot -Attestation $manifest.value.attestation `
        -ValidateVolatileBaseline
    $snapshotRoot = New-OwnerParityImmutableSnapshotRoot `
        -DestinationRoot (Join-Path $isolation.v2StateRoot (
                '.v1-read-snapshot-' + [guid]::NewGuid().ToString('N'))) `
        -Snapshot $before
    $entryReports = [Collections.Generic.List[object]]::new()
    $executionError = $null
    try {
        foreach ($entry in @($manifest.value.entries)) {
            $baseline = Read-OwnerV1Observation `
                -StateRoot $snapshotRoot `
                -SubjectRootOverride $snapshotRoot `
                -StateRootRelocationSource $isolation.v1StateRoot `
                -SubjectRootRelocationSource $isolation.v1StateRoot `
                -HeadKey ([string]$entry.baseline.headKey)
            try {
                $candidateResult = Resolve-OwnerParityCandidate `
                    -Candidate $entry.candidate -V2StateRoot $isolation.v2StateRoot
            }
            catch {
                $candidateResult = [pscustomobject][ordered]@{
                    observation = $null
                    observationPath = $null
                    runState = 'blocked'
                    blockingReason = 'candidate-resolution-failed'
                    runReason = 'candidate-resolution-failed'
                    semanticProvenance = 'unknown'
                    errorId = [string]$_.FullyQualifiedErrorId
                    candidateCompleted = $script:OwnerParityUnknown
                }
            }
            if ([string]$entry.evidence.semanticProvenance -cne
                [string]$candidateResult.semanticProvenance) {
                $candidateResult.observation = $null
                $candidateResult.runState = 'blocked'
                $candidateResult.blockingReason = 'candidate-provenance-mismatch'
                $candidateResult.candidateCompleted = $script:OwnerParityUnknown
            }
            $evaluation = if ($null -eq $candidateResult.observation) {
                New-OwnerParityUnavailableEvaluation `
                    -Baseline $baseline `
                    -Adjudication @($entry.adjudication) `
                    -Reason ([string]$candidateResult.blockingReason) `
                    -CandidateCompleted $candidateResult.candidateCompleted
            }
            else {
                Invoke-OwnerParityGateEvaluation `
                    -Baseline $baseline `
                    -Candidate $candidateResult.observation `
                    -Evidence $entry.evidence `
                    -Adjudication @($entry.adjudication)
            }
            [void]$entryReports.Add([ordered]@{
                    id = [string]$entry.id
                    evidence = $entry.evidence
                    baseline = $baseline
                    candidate = $candidateResult.observation
                    candidateObservationPath = $candidateResult.observationPath
                    candidateRunState = $candidateResult.runState
                    candidateBlockingReason = $candidateResult.blockingReason
                    candidateRunReason = $candidateResult.runReason
                    candidateErrorId = $candidateResult.errorId
                    gates = @($evaluation.gates)
                    metrics = $evaluation.metrics
                })
        }
    }
    catch {
        $executionError = $_
    }
    finally {
        try {
            $after = Get-OwnerParityAttestationSnapshot `
                -Root $isolation.v1StateRoot -Attestation $manifest.value.attestation
        }
        finally {
            if (Test-Path -LiteralPath $snapshotRoot -PathType Container) {
                Remove-Item -LiteralPath $snapshotRoot -Recurse -Force
            }
        }
    }
    $rollback = Compare-OwnerParityAttestationSnapshots `
        -Before $before -After $after -Attestation $manifest.value.attestation
    Remove-OwnerParitySnapshotContent -Snapshot $before
    Remove-OwnerParitySnapshotContent -Snapshot $after
    if ($executionError) { throw $executionError }

    $aggregateGates = [Collections.Generic.List[object]]::new()
    foreach ($name in @(
            'findingRetention',
            'eligibleFalsePositives',
            'bindingEquivalence',
            'unknownIntegrity',
            'writeIsolation',
            'latencyAccounting')) {
        $matching = @($entryReports | ForEach-Object { $_.gates } | Where-Object name -CEQ $name)
        [void]$aggregateGates.Add([ordered]@{
                name = $name
                status = Get-OwnerParityAggregateStatus -Statuses @($matching.status)
                evidenceCode = if (@($matching.evidenceCode | Select-Object -Unique).Count -eq 1) {
                    [string]$matching[0].evidenceCode
                }
                else {
                    'mixed-cohort-evidence'
                }
                measured = [int](($matching.measured | Measure-Object -Sum).Sum)
                failures = [int](($matching.failures | Measure-Object -Sum).Sum)
                blocked = [int](($matching.blocked | Measure-Object -Sum).Sum)
            })
    }
    [void]$aggregateGates.Add((New-OwnerParityCompletionGate -EntryReports @($entryReports)))
    $rollbackStatus = if ($rollback.unchanged) {
        'passed'
    }
    else {
        'failed'
    }
    [void]$aggregateGates.Add((New-OwnerParityGate -Name rollbackProof `
            -Status $rollbackStatus `
            -EvidenceCode $(if ($rollback.unchanged) {
                    'critical-bytes-identical-and-volatile-append-only'
                }
                else {
                    'read-only-attestation-failed'
                }) `
            -Measured (@($manifest.value.attestation.critical).Count +
                @($manifest.value.attestation.volatile).Count) `
            -Failures $(if ($rollbackStatus -ceq 'failed') { 1 } else { 0 }) `
            -Blocked 0))

    $report = [ordered]@{
        schemaVersion = 2
        kind = 'owner-parity-private-report'
        manifestSha256 = $manifest.sha256
        v1StateRoot = $isolation.v1StateRoot
        v2StateRoot = $isolation.v2StateRoot
        entries = @($entryReports)
        gates = @($aggregateGates)
        rollback = $rollback
    }
    $summary = ConvertTo-OwnerParitySanitizedSummary -Report $report
    [void](Write-OwnerParityJson -Path $privatePath -Value $report)
    [void](Write-OwnerParityJson -Path $summaryPath -Value $summary)
    return [pscustomobject][ordered]@{
        report = $report
        summary = $summary
        privateReportPath = $privatePath
        sanitizedSummaryPath = $summaryPath
    }
}

Export-ModuleMember -Function @(
    'Compare-OwnerParitySnapshots',
    'ConvertTo-OwnerParitySanitizedSummary',
    'Get-OwnerParityStateSnapshot',
    'Invoke-OwnerParityGateEvaluation',
    'Invoke-OwnerParityQualification',
    'Test-OwnerParityPathIsolation'
)
