#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\..\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1" -Force
Import-Module "$PSScriptRoot\..\DevPilot.OwnerCapability\DevPilot.OwnerCapability.psd1" -Force
Import-Module "$PSScriptRoot\..\DevPilot.OwnerPipeline\DevPilot.OwnerPipeline.psd1" -Force
Import-Module "$PSScriptRoot\..\OwnerObservationContract\OwnerObservationContract.psd1" -Force

$script:RelationSemantics = 'relation-evidence-assessment-v1'
$script:RelationRunnerSemantics = 'relation-evidence-judgment-v1'
$script:RelationDigestPattern = '^v1:sha256:[0-9a-f]{64}$'
$script:RelationCommitPattern = '^[0-9a-f]{40}$'
$script:RelationRefPattern = '^evidence:[a-z0-9][a-z0-9._-]{0,63}$'
$script:RelationSafeIdPattern = '^[a-z0-9][a-z0-9._-]{0,127}$'
$script:RelationRolePattern = '^[a-z][a-z0-9-]{0,63}$'
$script:RelationVerdicts = @('violation', 'compliant', 'unknown')
$script:RelationStates = @('complete', 'unknown')
$script:RelationEvidenceTypes = @(
    'source', 'guidance', 'test', 'discussion', 'runtime', 'synthetic'
)

function Get-RelationMember {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$Default = $null
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

function Test-RelationExactKeys {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Value,
        [Parameter(Mandatory)][string[]]$Expected
    )

    $actual = @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive)
    $wanted = @($Expected | Sort-Object -CaseSensitive)
    return $actual.Count -eq $wanted.Count -and
        ($actual -join "`0") -ceq ($wanted -join "`0")
}

function Assert-RelationExactKeys {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Value,
        [Parameter(Mandatory)][string[]]$Expected,
        [Parameter(Mandatory)][string]$Name
    )

    if (-not (Test-RelationExactKeys -Value $Value -Expected $Expected)) {
        throw "$Name must contain exactly: $($Expected -join ', ')."
    }
}

function Assert-RelationText {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$Name,
        [int]$MaximumLength = 512,
        [switch]$AllowEmpty,
        [switch]$AllowNewline
    )

    if ((-not $AllowEmpty -and [string]::IsNullOrWhiteSpace($Value)) -or
        $Value -cne $Value.Trim() -or
        $Value.Length -gt $MaximumLength -or
        (-not $AllowNewline -and $Value -match '[\r\n]') -or
        $Value -match '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]') {
        throw "$Name must be trimmed, bounded text without unsupported control characters."
    }
}

function ConvertTo-RelationEvidenceCanonicalJson {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    return ConvertTo-AgentCanonicalJson -InputObject $Value
}

function Get-RelationDigest {
    param([Parameter(Mandatory)][AllowNull()][object]$Value)

    return 'v1:sha256:' + (Get-AgentCanonicalDigest -InputObject $Value)
}

function Copy-RelationJsonValue {
    param([Parameter(Mandatory)][AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    $json = ConvertTo-RelationEvidenceCanonicalJson -Value $Value
    return ConvertFrom-Json -InputObject $json -AsHashtable -Depth 32 -NoEnumerate
}

function Test-RelationLimits {
    param([Parameter(Mandatory)][object]$Limits)

    if ($Limits.PSTypeNames -cnotcontains 'DevPilot.RelationEvidence.Limits') {
        throw 'Expected limits created by New-RelationEvidenceLimits.'
    }
}

function New-RelationEvidenceLimits {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 64)][int]$MaximumEvidenceRefs = 32,
        [ValidateRange(1, 16)][int]$MaximumClaims = 8,
        [ValidateRange(1, 32)][int]$MaximumAnchors = 16,
        [ValidateRange(256, 10000)][int]$MaximumEvidenceBytes = 10000,
        [ValidateRange(1024, 11000)][int]$MaximumModelInputBytes = 9000,
        [ValidateRange(128, 8000)][int]$MaximumEvidenceItemCharacters = 4000,
        [ValidateRange(1, 16)][int]$MaximumCitations = 8,
        [ValidateRange(64, 1024)][int]$MaximumExplanationCharacters = 512,
        [ValidateRange(64, 1024)][int]$MaximumRemediationCharacters = 512,
        [ValidateRange(1, 8)][int]$MaximumDiagnostics = 4
    )

    $limits = [pscustomobject][ordered]@{
        MaximumEvidenceRefs = $MaximumEvidenceRefs
        MaximumClaims = $MaximumClaims
        MaximumAnchors = $MaximumAnchors
        MaximumEvidenceBytes = $MaximumEvidenceBytes
        MaximumModelInputBytes = $MaximumModelInputBytes
        MaximumEvidenceItemCharacters = $MaximumEvidenceItemCharacters
        MaximumCitations = $MaximumCitations
        MaximumExplanationCharacters = $MaximumExplanationCharacters
        MaximumRemediationCharacters = $MaximumRemediationCharacters
        MaximumDiagnostics = $MaximumDiagnostics
    }
    $limits.PSTypeNames.Insert(0, 'DevPilot.RelationEvidence.Limits')
    return $limits
}

function Add-RelationDiagnostic {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Diagnostics,
        [Parameter(Mandatory)][object]$Limits,
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Message,
        [string]$ClaimId = ''
    )

    if ($Diagnostics.Count -ge [int]$Limits.MaximumDiagnostics) { return }
    $entry = [ordered]@{
        code = $Code
        message = $Message
    }
    if (-not [string]::IsNullOrWhiteSpace($ClaimId)) { $entry['claimId'] = $ClaimId }
    [void]$Diagnostics.Add($entry)
}

function ConvertTo-RelationEvidenceRef {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$InputObject,
        [Parameter(Mandatory)][object]$Limits
    )

    Assert-RelationExactKeys -Value $InputObject -Name EvidenceRef -Expected @(
        'ref', 'type', 'path', 'span', 'digest', 'provenance',
        'roleLabels', 'state', 'content'
    )
    $ref = [string]$InputObject.ref
    $type = [string]$InputObject.type
    $path = ConvertTo-OwnerRepositoryPath -Path ([string]$InputObject.path)
    $state = [string]$InputObject.state
    $digest = [string]$InputObject.digest
    if ($ref -cnotmatch $script:RelationRefPattern) {
        throw 'Evidence ref must be a bounded wrapper-issued evidence identity.'
    }
    if ($type -cnotin $script:RelationEvidenceTypes) {
        throw "Evidence ref '$ref' used an unsupported type."
    }
    if ($state -cnotin $script:RelationStates) {
        throw "Evidence ref '$ref' used an unsupported state."
    }
    if ($digest -cnotmatch $script:RelationDigestPattern) {
        throw "Evidence ref '$ref' must carry a lowercase v1 SHA-256 digest."
    }
    if ($InputObject.span -isnot [Collections.IDictionary]) {
        throw "Evidence ref '$ref' requires a bounded span."
    }
    Assert-RelationExactKeys -Value $InputObject.span -Name "EvidenceRef[$ref].span" -Expected @(
        'startLine', 'endLine'
    )
    $startLine = [int]$InputObject.span.startLine
    $endLine = [int]$InputObject.span.endLine
    if ($startLine -lt 1 -or $endLine -lt $startLine) {
        throw "Evidence ref '$ref' has an invalid span."
    }
    if ($InputObject.provenance -isnot [Collections.IDictionary]) {
        throw "Evidence ref '$ref' requires provenance."
    }
    Assert-RelationExactKeys -Value $InputObject.provenance `
        -Name "EvidenceRef[$ref].provenance" -Expected @(
        'repositoryId', 'commit', 'sourceKind'
    )
    $repositoryId = [string]$InputObject.provenance.repositoryId
    $commit = [string]$InputObject.provenance.commit
    $sourceKind = [string]$InputObject.provenance.sourceKind
    Assert-RelationText -Value $repositoryId -Name "EvidenceRef[$ref].repositoryId" -MaximumLength 256
    if ($commit -cnotmatch $script:RelationCommitPattern) {
        throw "Evidence ref '$ref' requires a lowercase commit binding."
    }
    if ($sourceKind -cnotin @('repository', 'discussion', 'runtime', 'synthetic')) {
        throw "Evidence ref '$ref' used unsupported provenance."
    }
    $roles = @($InputObject.roleLabels | ForEach-Object { [string]$_ })
    if ($roles.Count -eq 0 -or $roles.Count -gt 16) {
        throw "Evidence ref '$ref' requires one to sixteen role labels."
    }
    $roleSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($role in $roles) {
        if ($role -cnotmatch $script:RelationRolePattern -or -not $roleSet.Add($role)) {
            throw "Evidence ref '$ref' has an invalid or duplicate role label."
        }
    }
    $content = $InputObject.content
    if ($state -ceq 'complete') {
        if ($content -isnot [string]) {
            throw "Complete evidence ref '$ref' requires content."
        }
        Assert-RelationText -Value ([string]$content) -Name "EvidenceRef[$ref].content" `
            -MaximumLength ([int]$Limits.MaximumEvidenceItemCharacters) -AllowNewline
        if ((Get-RelationDigest -Value ([string]$content)) -cne $digest) {
            throw "Evidence ref '$ref' content did not match its wrapper-issued digest."
        }
    }
    elseif ($null -ne $content) {
        throw "Unknown evidence ref '$ref' must not carry content."
    }

    return [ordered]@{
        ref = $ref
        type = $type
        path = $path
        span = [ordered]@{
            startLine = $startLine
            endLine = $endLine
        }
        digest = $digest
        provenance = [ordered]@{
            repositoryId = $repositoryId
            commit = $commit
            sourceKind = $sourceKind
        }
        roleLabels = @($roles | Sort-Object -CaseSensitive)
        state = $state
        content = $content
    }
}

function ConvertTo-RelationAnchor {
    param([Parameter(Mandatory)][Collections.IDictionary]$InputObject)

    Assert-RelationExactKeys -Value $InputObject -Name AnchorCandidate -Expected @(
        'anchorId', 'path', 'startLine', 'endLine', 'symbol'
    )
    $anchorId = [string]$InputObject.anchorId
    if ($anchorId -cnotmatch $script:RelationSafeIdPattern) {
        throw 'Anchor candidate identity was invalid.'
    }
    $path = ConvertTo-OwnerRepositoryPath -Path ([string]$InputObject.path)
    $startLine = [int]$InputObject.startLine
    $endLine = [int]$InputObject.endLine
    if ($startLine -lt 1 -or $endLine -lt $startLine) {
        throw "Anchor candidate '$anchorId' has an invalid span."
    }
    $symbol = [string]$InputObject.symbol
    Assert-RelationText -Value $symbol -Name "AnchorCandidate[$anchorId].symbol" -MaximumLength 256
    return [ordered]@{
        anchorId = $anchorId
        path = $path
        startLine = $startLine
        endLine = $endLine
        symbol = $symbol
    }
}

function ConvertTo-RelationClaim {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$InputObject,
        [Parameter(Mandatory)][Collections.Generic.Dictionary[string,object]]$EvidenceByRef,
        [Parameter(Mandatory)][Collections.Generic.HashSet[string]]$AnchorIds
    )

    Assert-RelationExactKeys -Value $InputObject -Name Claim -Expected @(
        'claimId', 'question', 'applicability', 'slots',
        'anchorCandidateIds', 'severity', 'policy'
    )
    $claimId = [string]$InputObject.claimId
    if ($claimId -cnotmatch $script:RelationSafeIdPattern) {
        throw 'Claim identity was invalid.'
    }
    $question = [string]$InputObject.question
    Assert-RelationText -Value $question -Name "Claim[$claimId].question" -MaximumLength 1200
    $applicability = [string]$InputObject.applicability
    if ($applicability -cnotin @('applicable', 'not-applicable', 'unknown')) {
        throw "Claim '$claimId' used an unsupported applicability state."
    }
    $severity = [string]$InputObject.severity
    if ($severity -cnotin @('critical', 'high', 'medium', 'low', 'informational')) {
        throw "Claim '$claimId' used an unsupported severity."
    }
    $policy = [string]$InputObject.policy
    Assert-RelationText -Value $policy -Name "Claim[$claimId].policy" -MaximumLength 128

    $slotValues = @($InputObject.slots)
    if ($slotValues.Count -eq 0 -or $slotValues.Count -gt 32) {
        throw "Claim '$claimId' requires one to thirty-two relationship slots."
    }
    $slotRoles = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $slots = [Collections.Generic.List[object]]::new()
    foreach ($slotValue in $slotValues) {
        if ($slotValue -isnot [Collections.IDictionary]) {
            throw "Claim '$claimId' contains an invalid relationship slot."
        }
        Assert-RelationExactKeys -Value $slotValue -Name "Claim[$claimId].slot" -Expected @(
            'role', 'evidenceRef', 'required'
        )
        $role = [string]$slotValue.role
        if ($role -cnotmatch $script:RelationRolePattern -or -not $slotRoles.Add($role)) {
            throw "Claim '$claimId' contains an invalid or duplicate slot role."
        }
        if ($slotValue.required -isnot [bool]) {
            throw "Claim '$claimId' slot '$role' requires a Boolean required flag."
        }
        $evidenceRef = $slotValue.evidenceRef
        if ($null -ne $evidenceRef) {
            if ($evidenceRef -isnot [string] -or
                -not $EvidenceByRef.ContainsKey([string]$evidenceRef)) {
                throw "Claim '$claimId' slot '$role' references unknown evidence."
            }
            $evidence = $EvidenceByRef[[string]$evidenceRef]
            if (@($evidence.roleLabels) -cnotcontains $role) {
                throw "Claim '$claimId' slot '$role' does not match the evidence role binding."
            }
        }
        [void]$slots.Add([ordered]@{
                role = $role
                evidenceRef = $evidenceRef
                required = [bool]$slotValue.required
            })
    }

    $candidateIds = @($InputObject.anchorCandidateIds | ForEach-Object { [string]$_ })
    if ($candidateIds.Count -ne 1) {
        throw "Claim '$claimId' requires exactly one wrapper-owned anchor candidate."
    }
    $candidateSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($candidateId in $candidateIds) {
        if (-not $AnchorIds.Contains($candidateId) -or -not $candidateSet.Add($candidateId)) {
            throw "Claim '$claimId' references an unknown or duplicate anchor candidate."
        }
    }

    return [ordered]@{
        claimId = $claimId
        question = $question
        applicability = $applicability
        slots = @($slots | Sort-Object { [string]$_.role })
        anchorCandidateIds = @($candidateIds)
        severity = $severity
        policy = $policy
    }
}

function New-RelationEvidenceRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][long]$PullRequestId,
        [Parameter(Mandatory)][string]$SourceCommit,
        [Parameter(Mandatory)][string]$TargetCommit,
        [Parameter(Mandatory)][string]$TargetRef,
        [Parameter(Mandatory)][string]$CapabilityId,
        [Parameter(Mandatory)][string]$CapabilityDigest,
        [Parameter(Mandatory)][string]$RuleId,
        [Parameter(Mandatory)][string]$RuleDigest,
        [Parameter(Mandatory)][string]$RuleText,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$EvidenceRefs,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Claims,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$AnchorCandidates,
        [object]$Limits = (New-RelationEvidenceLimits)
    )

    Test-RelationLimits -Limits $Limits
    foreach ($pair in @(
            @('RepositoryId', $RepositoryId, 256),
            @('ProjectId', $ProjectId, 256),
            @('CapabilityId', $CapabilityId, 256),
            @('RuleId', $RuleId, 256)
        )) {
        Assert-RelationText -Value ([string]$pair[1]) -Name ([string]$pair[0]) `
            -MaximumLength ([int]$pair[2])
    }
    if ($PullRequestId -lt 1) { throw 'PullRequestId must be positive.' }
    if ($SourceCommit -cnotmatch $script:RelationCommitPattern -or
        $TargetCommit -cnotmatch $script:RelationCommitPattern) {
        throw 'SourceCommit and TargetCommit must be lowercase 40-character commit ids.'
    }
    Assert-RelationText -Value $TargetRef -Name TargetRef -MaximumLength 256
    if ($CapabilityDigest -cnotmatch $script:RelationDigestPattern -or
        $RuleDigest -cnotmatch $script:RelationDigestPattern) {
        throw 'CapabilityDigest and RuleDigest must be lowercase v1 SHA-256 digests.'
    }
    Assert-RelationText -Value $RuleText -Name RuleText -MaximumLength 4000 -AllowNewline
    if ((Get-RelationDigest -Value $RuleText) -cne $RuleDigest) {
        throw 'RuleText did not match RuleDigest.'
    }
    if ($EvidenceRefs.Count -gt [int]$Limits.MaximumEvidenceRefs -or
        $Claims.Count -eq 0 -or $Claims.Count -gt [int]$Limits.MaximumClaims -or
        $AnchorCandidates.Count -eq 0 -or
        $AnchorCandidates.Count -gt [int]$Limits.MaximumAnchors) {
        throw 'Relation-evidence declaration exceeded a configured item bound.'
    }

    $evidenceByRef = [Collections.Generic.Dictionary[string,object]]::new(
        [StringComparer]::Ordinal)
    $normalizedEvidence = [Collections.Generic.List[object]]::new()
    $evidenceBytes = 0
    foreach ($evidenceValue in $EvidenceRefs) {
        if ($evidenceValue -isnot [Collections.IDictionary]) {
            throw 'Evidence refs must be dictionaries.'
        }
        $evidence = ConvertTo-RelationEvidenceRef -InputObject $evidenceValue -Limits $Limits
        if ($evidenceByRef.ContainsKey([string]$evidence.ref)) {
            throw "Duplicate evidence ref '$($evidence.ref)'."
        }
        $expectedSourceKind = switch ([string]$evidence.type) {
            'synthetic' { 'synthetic' }
            'discussion' { 'discussion' }
            'runtime' { 'runtime' }
            default { 'repository' }
        }
        if ([string]$evidence.provenance.repositoryId -cne $RepositoryId) {
            throw "Evidence ref '$($evidence.ref)' did not match the request repository binding."
        }
        if ([string]$evidence.provenance.commit -cnotin @($SourceCommit, $TargetCommit)) {
            throw "Evidence ref '$($evidence.ref)' did not match an allowed request commit binding."
        }
        if ([string]$evidence.provenance.sourceKind -cne $expectedSourceKind) {
            throw "Evidence ref '$($evidence.ref)' did not match its type provenance."
        }
        $evidenceByRef.Add([string]$evidence.ref, $evidence)
        if ($evidence.state -ceq 'complete') {
            $evidenceBytes += [Text.Encoding]::UTF8.GetByteCount([string]$evidence.content)
        }
        [void]$normalizedEvidence.Add($evidence)
    }
    if ($evidenceBytes -gt [int]$Limits.MaximumEvidenceBytes) {
        throw 'Model-visible evidence exceeded the configured evidence byte and token upper bound.'
    }

    $anchorIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $normalizedAnchors = [Collections.Generic.List[object]]::new()
    foreach ($anchorValue in $AnchorCandidates) {
        if ($anchorValue -isnot [Collections.IDictionary]) {
            throw 'Anchor candidates must be dictionaries.'
        }
        $anchor = ConvertTo-RelationAnchor -InputObject $anchorValue
        if (-not $anchorIds.Add([string]$anchor.anchorId)) {
            throw "Duplicate anchor candidate '$($anchor.anchorId)'."
        }
        [void]$normalizedAnchors.Add($anchor)
    }

    $claimIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $normalizedClaims = [Collections.Generic.List[object]]::new()
    foreach ($claimValue in $Claims) {
        if ($claimValue -isnot [Collections.IDictionary]) {
            throw 'Claims must be dictionaries.'
        }
        $claim = ConvertTo-RelationClaim -InputObject $claimValue `
            -EvidenceByRef $evidenceByRef -AnchorIds $anchorIds
        if (-not $claimIds.Add([string]$claim.claimId)) {
            throw "Duplicate claim '$($claim.claimId)'."
        }
        [void]$normalizedClaims.Add($claim)
    }

    $binding = New-OwnerPipelineBinding `
        -SubjectKey "repository:$RepositoryId/pull-request:$PullRequestId" `
        -HeadKey $SourceCommit `
        -RuleKey "$RuleId@$RuleDigest" `
        -CapabilityKey "$CapabilityId@$CapabilityDigest" `
        -AuthorizationKey 'authority:preview-only'
    $declaration = [ordered]@{
        schemaVersion = 1
        semantics = $script:RelationSemantics
        bindingId = $binding.BindingId
        subject = [ordered]@{
            repositoryId = $RepositoryId
            projectId = $ProjectId
            pullRequestId = $PullRequestId
            sourceCommit = $SourceCommit
            targetCommit = $TargetCommit
            targetRef = $TargetRef
        }
        capability = [ordered]@{
            id = $CapabilityId
            digest = $CapabilityDigest
        }
        rule = [ordered]@{
            id = $RuleId
            digest = $RuleDigest
            content = $RuleText
        }
        claims = @($normalizedClaims | Sort-Object { [string]$_.claimId })
        anchors = @($normalizedAnchors | Sort-Object { [string]$_.anchorId })
        budgets = [ordered]@{
            maximumEvidenceBytes = [int]$Limits.MaximumEvidenceBytes
            evidenceBytes = $evidenceBytes
            evidenceTokenUpperBound = $evidenceBytes
            maximumModelInputBytes = [int]$Limits.MaximumModelInputBytes
            maximumCitations = [int]$Limits.MaximumCitations
            maximumExplanationCharacters = [int]$Limits.MaximumExplanationCharacters
            maximumRemediationCharacters = [int]$Limits.MaximumRemediationCharacters
        }
    }
    $request = [ordered]@{
        declaration = $declaration
        evidenceRefs = @($normalizedEvidence | Sort-Object { [string]$_.ref })
    }
    $copy = Copy-RelationJsonValue -Value $request
    $result = [pscustomobject][ordered]@{
        Binding = $binding
        Request = $copy
        RequestDigest = Get-RelationDigest -Value $copy
        Limits = $Limits
    }
    $result.PSTypeNames.Insert(0, 'DevPilot.RelationEvidence.Request')
    return $result
}

function Test-RelationRequest {
    param([Parameter(Mandatory)][object]$Request)

    if ($Request.PSTypeNames -cnotcontains 'DevPilot.RelationEvidence.Request' -or
        $Request.Binding -isnot [DevPilot.OwnerPipeline.OwnerPipelineBinding] -or
        $Request.Request -isnot [Collections.IDictionary] -or
        [string]$Request.Request.declaration.bindingId -cne $Request.Binding.BindingId -or
        [string]$Request.RequestDigest -cne (Get-RelationDigest -Value $Request.Request)) {
        throw 'Expected an immutable request created by New-RelationEvidenceRequest.'
    }
    Test-RelationLimits -Limits $Request.Limits
}

function New-RelationEvidenceAcquisitionAdapter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Request,
        [string]$Name = 'relation-evidence-bounded-acquisition'
    )

    Test-RelationRequest -Request $Request
    Assert-RelationText -Value $Name -Name Name -MaximumLength 128
    $captured = Copy-RelationJsonValue -Value $Request.Request
    $bindingId = $Request.Binding.BindingId
    $copyCommand = Get-Command Copy-RelationJsonValue -CommandType Function
    return New-OwnerPipelineAdapter -Stage acquisition -Name $Name -Handler {
        param($context)
        if ([string]$context.binding.BindingId -cne $bindingId) {
            throw 'Acquisition context did not preserve the request binding.'
        }
        $units = [Collections.Generic.List[object]]::new()
        [void]$units.Add([ordered]@{
                unitId = 'declaration'
                state = 'complete'
                data = & $copyCommand -Value $captured.declaration
            })
        $hasUnknown = $false
        foreach ($evidence in @($captured.evidenceRefs)) {
            if ([string]$evidence.state -ceq 'unknown') { $hasUnknown = $true }
            [void]$units.Add([ordered]@{
                    unitId = [string]$evidence.ref
                    state = [string]$evidence.state
                    data = & $copyCommand -Value $evidence
                })
        }
        return [ordered]@{
            schemaVersion = 1
            bindingId = $bindingId
            state = $(if ($hasUnknown) { 'incomplete' } else { 'complete' })
            evidenceUnits = @($units)
        }
    }.GetNewClosure()
}

function Invoke-RelationRunner {
    param(
        [Parameter(Mandatory)][object]$Runner,
        [Parameter(Mandatory)][Collections.IDictionary]$Request,
        [Parameter(Mandatory)][string[]]$AllowedEvidenceRefs,
        [Parameter(Mandatory)][object]$Limits
    )

    $before = Get-RelationDigest -Value $Request
    try {
        $values = @(& $Runner.Handler ([pscustomobject]$Request))
    }
    catch {
        return [pscustomobject]@{ Valid = $false; Failure = 'runner-failed'; Verdict = 'unknown' }
    }
    if ((Get-RelationDigest -Value $Request) -cne $before -or
        $values.Count -ne 1 -or $values[0] -isnot [Collections.IDictionary]) {
        return [pscustomobject]@{ Valid = $false; Failure = 'runner-response-invalid'; Verdict = 'unknown' }
    }
    $response = $values[0]
    $keys = @($response.Keys | ForEach-Object { [string]$_ })
    $allowedShapes = @(
        @('schemaVersion', 'executionUnitId', 'verdict', 'citedEvidenceRefs', 'explanation'),
        @('schemaVersion', 'executionUnitId', 'verdict', 'citedEvidenceRefs', 'explanation', 'remediation')
    )
    if (-not @($allowedShapes | Where-Object {
                (Test-RelationExactKeys -Value $response -Expected $_)
            }).Count -or
        $response.schemaVersion -ne 3 -or
        [string]$response.executionUnitId -cne [string]$Request.executionUnitId -or
        [string]$response.verdict -cnotin $script:RelationVerdicts -or
        $response.citedEvidenceRefs -isnot [Collections.IList] -or
        $response.explanation -isnot [string]) {
        return [pscustomobject]@{ Valid = $false; Failure = 'runner-response-invalid'; Verdict = 'unknown' }
    }
    $explanation = [string]$response.explanation
    try {
        Assert-RelationText -Value $explanation -Name Explanation `
            -MaximumLength ([int]$Limits.MaximumExplanationCharacters)
    }
    catch {
        return [pscustomobject]@{ Valid = $false; Failure = 'runner-response-invalid'; Verdict = 'unknown' }
    }
    $remediation = $null
    if ($response.Contains('remediation')) {
        if ($response.remediation -isnot [string]) {
            return [pscustomobject]@{ Valid = $false; Failure = 'runner-response-invalid'; Verdict = 'unknown' }
        }
        $remediation = [string]$response.remediation
        try {
            Assert-RelationText -Value $remediation -Name Remediation `
                -MaximumLength ([int]$Limits.MaximumRemediationCharacters)
        }
        catch {
            return [pscustomobject]@{ Valid = $false; Failure = 'runner-response-invalid'; Verdict = 'unknown' }
        }
    }
    $citations = @($response.citedEvidenceRefs | ForEach-Object { [string]$_ })
    if ($citations.Count -gt [int]$Limits.MaximumCitations -or
        ([string]$response.verdict -cne 'unknown' -and $citations.Count -eq 0)) {
        return [pscustomobject]@{ Valid = $false; Failure = 'runner-response-invalid'; Verdict = 'unknown' }
    }
    $allowed = [Collections.Generic.HashSet[string]]::new(
        [string[]]$AllowedEvidenceRefs, [StringComparer]::Ordinal)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($citation in $citations) {
        if (-not $allowed.Contains($citation) -or -not $seen.Add($citation)) {
            return [pscustomobject]@{ Valid = $false; Failure = 'runner-response-invalid'; Verdict = 'unknown' }
        }
    }
    return [pscustomobject]@{
        Valid = $true
        Failure = $(if ([string]$response.verdict -ceq 'unknown') { 'model-unknown' } else { $null })
        Verdict = [string]$response.verdict
        Citations = @($citations)
        Explanation = $explanation
        Remediation = $remediation
    }
}

function Invoke-RelationEvidenceCapabilityResponse {
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][object]$Runner,
        [Parameter(Mandatory)][object]$Limits
    )

    $binding = Get-RelationMember -Value $Context -Name binding
    $evidence = Get-RelationMember -Value $Context -Name evidence
    $bindingId = [string](Get-RelationMember -Value $binding -Name BindingId)
    $evidenceDigest = [string](Get-RelationMember -Value $evidence -Name evidenceDigest)
    if ($bindingId -cne [string](Get-RelationMember -Value $evidence -Name bindingId) -or
        $evidenceDigest -cnotmatch $script:RelationDigestPattern) {
        throw 'Capability context did not preserve the facade binding and evidence digest.'
    }
    $diagnostics = [Collections.Generic.List[object]]::new()
    $units = @(Get-RelationMember -Value $evidence -Name evidenceUnits)
    $declarations = @($units | Where-Object {
            [string](Get-RelationMember -Value $_ -Name unitId) -ceq 'declaration'
        })
    if ($declarations.Count -ne 1 -or
        [string](Get-RelationMember -Value $declarations[0] -Name state) -cne 'complete') {
        Add-RelationDiagnostic -Diagnostics $diagnostics -Limits $Limits `
            -Code 'declaration-unknown' -Message 'The bounded relation declaration was unavailable.'
        return [ordered]@{
            schemaVersion = 1
            bindingId = $bindingId
            state = 'unknown'
            assessments = @(
                [ordered]@{
                    assessmentId = 'relation:' + (Get-RelationDigest -Value $bindingId).Substring(10)
                    evidenceUnitIds = @('declaration')
                    state = 'unknown'
                    data = [ordered]@{
                        state = 'unknown'
                        reason = 'declaration-unavailable'
                    }
                    findings = @()
                }
            )
            diagnostics = @($diagnostics)
        }
    }
    $declaration = Get-RelationMember -Value $declarations[0] -Name data
    if ([string](Get-RelationMember -Value $declaration -Name semantics) -cne $script:RelationSemantics -or
        [string](Get-RelationMember -Value $declaration -Name bindingId) -cne $bindingId) {
        throw 'Relation declaration did not preserve its semantics or binding.'
    }
    $unitById = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($unit in $units) {
        $unitById.Add([string](Get-RelationMember -Value $unit -Name unitId), $unit)
    }
    $anchorsById = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($anchor in @(Get-RelationMember -Value $declaration -Name anchors)) {
        $anchorsById.Add([string](Get-RelationMember -Value $anchor -Name anchorId), $anchor)
    }

    $assessments = [Collections.Generic.List[object]]::new()
    foreach ($claim in @(Get-RelationMember -Value $declaration -Name claims)) {
        $claimId = [string](Get-RelationMember -Value $claim -Name claimId)
        $assessmentId = 'relation:' + (Get-RelationDigest -Value ([ordered]@{
                    bindingId = $bindingId
                    evidenceDigest = $evidenceDigest
                    claimId = $claimId
                })).Substring(10)
        $assessmentRefs = [Collections.Generic.List[string]]::new()
        $assessmentRefSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $modelRefs = [Collections.Generic.List[string]]::new()
        $modelRefSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $missingRequired = $false
        foreach ($slot in @(Get-RelationMember -Value $claim -Name slots)) {
            $ref = Get-RelationMember -Value $slot -Name evidenceRef
            if ($null -eq $ref) {
                if ([bool](Get-RelationMember -Value $slot -Name required)) {
                    $missingRequired = $true
                }
                continue
            }
            $refText = [string]$ref
            if ($assessmentRefSet.Add($refText)) { [void]$assessmentRefs.Add($refText) }
            $isComplete = $unitById.ContainsKey($refText) -and
                [string](Get-RelationMember -Value $unitById[$refText] -Name state) -ceq 'complete'
            if (-not $isComplete) {
                if ([bool](Get-RelationMember -Value $slot -Name required)) {
                    $missingRequired = $true
                }
                continue
            }
            if ($modelRefSet.Add($refText)) { [void]$modelRefs.Add($refText) }
        }
        $assessmentUnits = @('declaration') + @($assessmentRefs)
        $applicability = [string](Get-RelationMember -Value $claim -Name applicability)
        if ($applicability -ceq 'not-applicable') {
            [void]$assessments.Add([ordered]@{
                    assessmentId = $assessmentId
                    evidenceUnitIds = $assessmentUnits
                    state = 'complete'
                    data = [ordered]@{
                        state = 'notEligible'
                        reason = 'claim-not-applicable'
                        claimId = $claimId
                    }
                    findings = @()
                })
            continue
        }
        if ($applicability -ceq 'unknown' -or $missingRequired) {
            [void]$assessments.Add([ordered]@{
                    assessmentId = $assessmentId
                    evidenceUnitIds = $assessmentUnits
                    state = 'unknown'
                    data = [ordered]@{
                        state = 'unknown'
                        reason = $(if ($applicability -ceq 'unknown') {
                                'applicability-unknown'
                            }
                            else {
                                'required-evidence-unavailable'
                            })
                        claimId = $claimId
                    }
                    findings = @()
                })
            continue
        }

        $claimSlots = @(Get-RelationMember -Value $claim -Name slots)
        $modelEvidence = @(
            foreach ($refText in $modelRefs) {
                $data = Get-RelationMember -Value $unitById[$refText] -Name data
                [ordered]@{
                    roles = @(
                        $claimSlots |
                            Where-Object {
                                [string](Get-RelationMember -Value $_ -Name evidenceRef) -ceq $refText
                            } |
                            ForEach-Object {
                                [string](Get-RelationMember -Value $_ -Name role)
                            } |
                            Sort-Object -Unique
                    )
                    ref = [string](Get-RelationMember -Value $data -Name ref)
                    type = [string](Get-RelationMember -Value $data -Name type)
                    path = [string](Get-RelationMember -Value $data -Name path)
                    span = Get-RelationMember -Value $data -Name span
                    digest = [string](Get-RelationMember -Value $data -Name digest)
                    provenance = Get-RelationMember -Value $data -Name provenance
                    content = [string](Get-RelationMember -Value $data -Name content)
                }
            }
        )
        $executionUnitId = 'unit:' + (Get-RelationDigest -Value ([ordered]@{
                    semantics = $script:RelationRunnerSemantics
                    bindingId = $bindingId
                    evidenceDigest = $evidenceDigest
                    claimId = $claimId
                })).Substring(10)
        $budgets = Get-RelationMember -Value $declaration -Name budgets
        $modelRequest = [ordered]@{
            schemaVersion = 1
            semantics = $script:RelationRunnerSemantics
            executionUnitId = $executionUnitId
            capability = Get-RelationMember -Value $declaration -Name capability
            rule = Get-RelationMember -Value $declaration -Name rule
            claim = [ordered]@{
                claimId = $claimId
                question = [string](Get-RelationMember -Value $claim -Name question)
            }
            evidence = $modelEvidence
            budgets = [ordered]@{
                maximumCitations = [int](Get-RelationMember -Value $budgets -Name maximumCitations)
                maximumExplanationCharacters = [int](
                    Get-RelationMember -Value $budgets -Name maximumExplanationCharacters)
                maximumRemediationCharacters = [int](
                    Get-RelationMember -Value $budgets -Name maximumRemediationCharacters)
            }
        }
        $modelBytes = [Text.Encoding]::UTF8.GetByteCount(
            (ConvertTo-RelationEvidenceCanonicalJson -Value $modelRequest))
        if ($modelBytes -gt [int](Get-RelationMember -Value $budgets -Name maximumModelInputBytes)) {
            Add-RelationDiagnostic -Diagnostics $diagnostics -Limits $Limits `
                -Code 'model-input-cap-exhausted' `
                -Message 'A relation assessment exceeded the wrapper-owned model input cap.' `
                -ClaimId $claimId
            [void]$assessments.Add([ordered]@{
                    assessmentId = $assessmentId
                    evidenceUnitIds = $assessmentUnits
                    state = 'unknown'
                    data = [ordered]@{
                        state = 'unknown'
                        reason = 'model-input-cap-exhausted'
                        claimId = $claimId
                    }
                    findings = @()
                })
            continue
        }

        $runnerResult = Invoke-RelationRunner -Runner $Runner -Request $modelRequest `
            -AllowedEvidenceRefs @($modelRefs) -Limits $Limits
        if (-not $runnerResult.Valid) {
            Add-RelationDiagnostic -Diagnostics $diagnostics -Limits $Limits `
                -Code ([string]$runnerResult.Failure) `
                -Message 'A relation assessment returned no usable semantic response.' `
                -ClaimId $claimId
            [void]$assessments.Add([ordered]@{
                    assessmentId = $assessmentId
                    evidenceUnitIds = $assessmentUnits
                    state = 'unknown'
                    data = [ordered]@{
                        state = 'unknown'
                        reason = [string]$runnerResult.Failure
                        claimId = $claimId
                    }
                    findings = @()
                })
            continue
        }
        if ($runnerResult.Verdict -ceq 'unknown') {
            [void]$assessments.Add([ordered]@{
                    assessmentId = $assessmentId
                    evidenceUnitIds = $assessmentUnits
                    state = 'unknown'
                    data = [ordered]@{
                        state = 'unknown'
                        reason = 'model-unknown'
                        claimId = $claimId
                        citedEvidenceRefs = @($runnerResult.Citations)
                        explanation = [string]$runnerResult.Explanation
                    }
                    findings = @()
                })
            continue
        }

        $assessmentData = [ordered]@{
            state = [string]$runnerResult.Verdict
            reason = 'semantic-judgment'
            claimId = $claimId
            citedEvidenceRefs = @($runnerResult.Citations)
            explanation = [string]$runnerResult.Explanation
        }
        if ($null -ne $runnerResult.Remediation) {
            $assessmentData['remediation'] = [string]$runnerResult.Remediation
        }
        $findings = @()
        if ($runnerResult.Verdict -ceq 'violation') {
            $anchorId = [string](@(Get-RelationMember -Value $claim -Name anchorCandidateIds)[0])
            $anchor = $anchorsById[$anchorId]
            $findingId = 'relation-evidence:' + (Get-RelationDigest -Value ([ordered]@{
                        bindingId = $bindingId
                        capability = Get-RelationMember -Value $declaration -Name capability
                        rule = Get-RelationMember -Value $declaration -Name rule
                        claimId = $claimId
                        anchor = $anchor
                        evidenceDigest = $evidenceDigest
                        verdict = 'violation'
                    })).Substring(10)
            $findingData = [ordered]@{
                disposition = 'violation'
                capabilityId = [string](Get-RelationMember -Value (
                        Get-RelationMember -Value $declaration -Name capability
                    ) -Name id)
                ruleId = [string](Get-RelationMember -Value (
                        Get-RelationMember -Value $declaration -Name rule
                    ) -Name id)
                claimId = $claimId
                bindingId = $bindingId
                evidenceDigest = $evidenceDigest
                citedEvidenceRefs = @($runnerResult.Citations)
                explanation = [string]$runnerResult.Explanation
                severity = [string](Get-RelationMember -Value $claim -Name severity)
                policy = [string](Get-RelationMember -Value $claim -Name policy)
                anchor = Copy-RelationJsonValue -Value $anchor
            }
            if ($null -ne $runnerResult.Remediation) {
                $findingData['remediation'] = [string]$runnerResult.Remediation
            }
            $findings = @(
                [ordered]@{
                    findingId = $findingId
                    summary = 'A bounded relationship claim was assessed as a violation.'
                    data = $findingData
                }
            )
        }
        [void]$assessments.Add([ordered]@{
                assessmentId = $assessmentId
                evidenceUnitIds = $assessmentUnits
                state = 'complete'
                data = $assessmentData
                findings = $findings
            })
    }

    return [ordered]@{
        schemaVersion = 1
        bindingId = $bindingId
        state = $(if (@($assessments | Where-Object state -CEQ 'unknown').Count) {
                'unknown'
            }
            else {
                'complete'
            })
        assessments = @($assessments)
        diagnostics = @($diagnostics)
    }
}

function New-RelationEvidenceCapabilityAdapter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Runner,
        [object]$Limits = (New-RelationEvidenceLimits),
        [string]$Name = 'relation-evidence-contextual-capability'
    )

    if ($Runner.PSTypeNames -cnotcontains 'DevPilot.OwnerCapability.SemanticRunner' -or
        $Runner.Handler -isnot [scriptblock]) {
        throw 'Expected a semantic runner created by New-OwnerSemanticRunner.'
    }
    Test-RelationLimits -Limits $Limits
    Assert-RelationText -Value $Name -Name Name -MaximumLength 128
    $capturedRunner = $Runner
    $capturedLimits = $Limits
    $invokeCommand = Get-Command Invoke-RelationEvidenceCapabilityResponse -CommandType Function
    return New-OwnerPipelineAdapter -Stage capability -Name $Name -Handler {
        param($context)
        return & $invokeCommand -Context $context -Runner $capturedRunner -Limits $capturedLimits
    }.GetNewClosure()
}

function ConvertTo-RelationEvidenceObservation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$PipelineResult,
        [object]$Runner,
        [string]$ImplementationId = 'relation-evidence-preview',
        [string]$ImplementationVersion = '0.1'
    )

    Assert-RelationText -Value $ImplementationId -Name ImplementationId -MaximumLength 128
    Assert-RelationText -Value $ImplementationVersion -Name ImplementationVersion -MaximumLength 64
    $evidence = Get-RelationMember -Value $PipelineResult -Name evidence
    $validation = Get-RelationMember -Value $PipelineResult -Name validation
    $preview = Get-RelationMember -Value $PipelineResult -Name preview
    if ($null -eq $evidence -or $null -eq $validation -or $null -eq $preview) {
        throw 'A completed facade result with evidence, validation, and preview is required.'
    }
    $declarationUnit = @(
        @(Get-RelationMember -Value $evidence -Name evidenceUnits) |
            Where-Object {
                [string](Get-RelationMember -Value $_ -Name unitId) -ceq 'declaration'
            }
    )
    if ($declarationUnit.Count -ne 1) {
        throw 'The relation observation requires exactly one declaration evidence unit.'
    }
    $declaration = Get-RelationMember -Value $declarationUnit[0] -Name data
    $assessments = @(Get-RelationMember -Value $validation -Name assessments)
    $findings = @(Get-RelationMember -Value $preview -Name findings)
    $unknown = @($assessments | Where-Object state -CEQ 'unknown').Count
    $compliant = @($assessments | Where-Object {
            [string](Get-RelationMember -Value (
                    Get-RelationMember -Value $_ -Name data
                ) -Name state) -ceq 'compliant'
        }).Count
    $notApplicable = @($assessments | Where-Object {
            [string](Get-RelationMember -Value (
                    Get-RelationMember -Value $_ -Name data
                ) -Name state) -ceq 'notEligible'
        }).Count
    $telemetry = $null
    if ($null -ne $Runner) {
        if ($Runner.PSObject.Properties['TelemetryProvider'] -eq $null -or
            $Runner.TelemetryProvider -isnot [scriptblock]) {
            throw 'The supplied semantic runner does not expose observation telemetry.'
        }
        $telemetryValues = @(& $Runner.TelemetryProvider)
        if ($telemetryValues.Count -ne 1 -or
            $telemetryValues[0] -isnot [Collections.IDictionary]) {
            throw 'Semantic runner telemetry violated the observation contract.'
        }
        $telemetry = Copy-RelationJsonValue -Value $telemetryValues[0]
    }
    else {
        $telemetry = [ordered]@{
            attempts = @($assessments | Where-Object {
                    [string](Get-RelationMember -Value (
                            Get-RelationMember -Value $_ -Name data
                        ) -Name reason) -ceq 'semantic-judgment'
                }).Count
            modelStarts = 'unknown'
            modelCalls = 'unknown'
            latencyMs = 0
            refusalReason = 'runner-telemetry-not-requested'
            providerWrites = 0
            effectiveTools = @()
            records = @()
        }
    }
    $completed = [string](Get-RelationMember -Value $PipelineResult -Name state) -cne 'failed' -and
        $unknown -eq 0
    $observationRecords = @(
        foreach ($record in @(Get-RelationMember -Value $telemetry -Name records -Default @())) {
            [ordered]@{
                executionUnitId = Get-RelationMember -Value $record -Name executionUnitId
                attempt = Get-RelationMember -Value $record -Name attempt
                processStarted = Get-RelationMember -Value $record -Name processStarted
                modelStarted = Get-RelationMember -Value $record -Name modelStarted
                latencyMs = Get-RelationMember -Value $record -Name latencyMs
                outcome = Get-RelationMember -Value $record -Name outcome
                inputDigest = Get-RelationMember -Value $record -Name inputDigest
                subjectBinding = Get-RelationMember -Value $record -Name subjectBinding
                invocationDigest = Get-RelationMember -Value $record -Name invocationDigest
                stdoutDigest = Get-RelationMember -Value $record -Name stdoutDigest
                stderrDigest = Get-RelationMember -Value $record -Name stderrDigest
                exitCode = Get-RelationMember -Value $record -Name exitCode
                timeout = Get-RelationMember -Value $record -Name timeout
            }
        }
    )
    return [ordered]@{
        schemaVersion = 1
        kind = 'relation-evidence-observation'
        implementation = [ordered]@{
            id = $ImplementationId
            version = $ImplementationVersion
        }
        capability = Get-RelationMember -Value $declaration -Name capability
        subject = Get-RelationMember -Value $declaration -Name subject
        rule = [ordered]@{
            id = [string](Get-RelationMember -Value (
                    Get-RelationMember -Value $declaration -Name rule
                ) -Name id)
            digest = [string](Get-RelationMember -Value (
                    Get-RelationMember -Value $declaration -Name rule
                ) -Name digest)
        }
        lifecycle = [ordered]@{
            status = $(if ($completed) { 'completed' } else { 'incomplete' })
            completed = $completed
            incomplete = -not $completed
        }
        counts = [ordered]@{
            claims = $assessments.Count
            violations = $findings.Count
            compliant = $compliant
            unknown = $unknown
            notApplicable = $notApplicable
        }
        findingsComplete = $completed
        findings = Copy-RelationJsonValue -Value $findings
        outcomes = Copy-RelationJsonValue -Value @(
            foreach ($assessment in $assessments) {
                [ordered]@{
                    assessmentId = [string](Get-RelationMember -Value $assessment -Name assessmentId)
                    state = [string](Get-RelationMember -Value $assessment -Name state)
                    data = Get-RelationMember -Value $assessment -Name data
                    writerEligible = $false
                }
            }
        )
        execution = [ordered]@{
            attempts = Get-RelationMember -Value $telemetry -Name attempts
            modelStarts = Get-RelationMember -Value $telemetry -Name modelStarts
            modelCalls = Get-RelationMember -Value $telemetry -Name modelCalls
            latencyMs = Get-RelationMember -Value $telemetry -Name latencyMs
            refusalReason = [string](Get-RelationMember -Value $telemetry -Name refusalReason)
            records = $observationRecords
        }
        effects = [ordered]@{
            providerWrites = 0
            writeToolInvocations = 0
            effectiveTools = @()
            deliveryAuthorized = $false
        }
        budgets = Get-RelationMember -Value $declaration -Name budgets
        evidenceDigest = [string](Get-RelationMember -Value $evidence -Name evidenceDigest)
    }
}

Export-ModuleMember -Function @(
    'ConvertTo-RelationEvidenceCanonicalJson',
    'ConvertTo-RelationEvidenceObservation',
    'New-RelationEvidenceAcquisitionAdapter',
    'New-RelationEvidenceCapabilityAdapter',
    'New-RelationEvidenceLimits',
    'New-RelationEvidenceRequest'
)
