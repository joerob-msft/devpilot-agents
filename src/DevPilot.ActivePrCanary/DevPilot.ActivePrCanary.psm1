#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1')
Import-Module (Join-Path $PSScriptRoot '..\DevPilot.ActivePrIntake\DevPilot.ActivePrIntake.psd1')
Import-Module (Join-Path $PSScriptRoot '..\DevPilot.RuleEvaluation\DevPilot.RuleEvaluation.psd1')

$script:OwnerCommit = 'f6db83436b48f48a8521095a888d79f67823bbb2'
$script:OwnerHash = 'bc31bfea6b378dffe4a1b28475dc1cac4cd3ee1ab793db57895446ded829ab2f'
$script:NamedSectionHash = 'b3935a2ac811353d1da72e9a310938679cf119963677bd2ebc90510aab85a03a'
$script:NamedSectionLength = 412
# The inherited Owner/Named pin has not been reviewed against the corrected source repository.
$script:OwnerSourceReviewedInApprovedRepository = $false
$script:DocumentPath = '/documentation/EngineeringProcesses/Conventions/AutomatedTests.md'
$script:CoverageCommit = '7e6620ec40c9bc37c5a5e13d506053b0139c9206'
$script:CoverageDocumentHash = '68a5cb1aa2604b971c8c446c77ef50f74409407f65eaa2e9389acd636cddacee'
$script:CoverageDocumentLength = 16286
# The merged source is acquired only through fresh, user-authorized read-only proof.
$script:MergedMasterPin = $null
$script:StaticPolicies = @(
    @{ name = 'class'; index = 1; file = 'test-class-coverage' },
    @{ name = 'redundant'; index = 2; file = 'redundant-method-coverage' },
    @{ name = 'named'; index = 3; file = 'named-areequal-arguments' }
)

function Get-CanaryHash {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-CanaryTextHash {
    param([AllowEmptyString()][string]$Text)
    return Get-CanaryHash ([Text.Encoding]::UTF8.GetBytes($Text))
}

function Assert-CanarySourceSelector {
    param([Collections.IDictionary]$Selector, [string]$Key,
        [string]$Organization)
    $fields = @('schemaVersion', 'kind', 'organization', 'projectName',
        'repositoryName', 'signature')
    if ($Selector -isnot [Collections.IDictionary] -or
        $Selector.Count -ne $fields.Count) {
        throw 'source-selector-invalid'
    }
    foreach ($field in $fields) {
        if (-not $Selector.Contains($field)) {
            throw 'source-selector-invalid'
        }
    }
    if ($Selector.schemaVersion -ne 1 -or
        $Selector.kind -cne 'private-canary-source-selector' -or
        [string]$Selector.organization -cnotmatch '^[A-Za-z0-9_-]{1,128}$' -or
        [string]$Selector.projectName -cnotmatch '^[\w .-]{1,128}$' -or
        [string]$Selector.projectName -in @('.', '..') -or
        [string]$Selector.repositoryName -cnotmatch '^[A-Za-z0-9._-]{1,128}$' -or
        [string]$Selector.repositoryName -in @('.', '..') -or
        $Organization -cne [string]$Selector.organization -or
        $Key -cnotmatch '^[A-Za-z0-9+/]{64}$' -or
        [string]$Selector.signature -cnotmatch '^v1:hmac-sha256:[a-f0-9]{64}$') {
        throw 'source-selector-invalid'
    }
    $expected = Get-CanarySignature $Selector $Key
    if (-not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
            [Convert]::FromHexString($Selector.signature.Substring(15)),
            [Convert]::FromHexString($expected.Substring(15)))) {
        throw 'source-selector-invalid'
    }
    return $Selector
}

function Assert-CanaryDiscoverySelector {
    param([Collections.IDictionary]$Selector, [string]$Organization,
        [int]$PullRequestId)
    $fields = @('organization', 'projectName', 'repositoryName')
    if ($Selector -isnot [Collections.IDictionary] -or
        $Selector.Count -ne $fields.Count -or
        $PullRequestId -ne 17307009) {
        throw 'source-selector-invalid'
    }
    foreach ($field in $fields) {
        if (-not $Selector.Contains($field)) {
            throw 'source-selector-invalid'
        }
    }
    if ([string]$Selector.organization -cnotmatch '^[A-Za-z0-9_-]{1,128}$' -or
        [string]$Selector.projectName -cnotmatch '^[\w .-]{1,128}$' -or
        [string]$Selector.projectName -in @('.', '..') -or
        [string]$Selector.repositoryName -cnotmatch '^[A-Za-z0-9._-]{1,128}$' -or
        [string]$Selector.repositoryName -in @('.', '..') -or
        $Organization -cne [string]$Selector.organization) {
        throw 'source-selector-invalid'
    }
    return $Selector
}

function Read-CanaryPrivateSourceSelector {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SelectorPath,
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][string]$RepositoryRoot)
    try {
        if (-not [IO.Path]::IsPathFullyQualified($SelectorPath) -or
            -not [IO.Path]::IsPathFullyQualified($KeyPath) -or
            (Test-AgentPathWithin $SelectorPath $RepositoryRoot) -or
            (Test-AgentPathWithin $KeyPath $RepositoryRoot)) {
            throw 'source-selector-invalid'
        }
        $selectorFile = Assert-AgentTrustedFile -Path $SelectorPath -Private
        $keyFile = Assert-AgentTrustedFile -Path $KeyPath -Private
        if ((Get-Item -LiteralPath $selectorFile).Length -gt 4096 -or
            (Get-Item -LiteralPath $keyFile).Length -gt 256) {
            throw 'source-selector-invalid'
        }
        $selector = Get-Content -LiteralPath $selectorFile -Raw |
            ConvertFrom-Json -AsHashtable -Depth 4
        $key = (Get-Content -LiteralPath $keyFile -Raw).Trim()
        return @{ selector = $selector; key = $key }
    }
    catch { throw 'source-selector-invalid' }
}

function Assert-CanarySource {
    param([Collections.IDictionary]$Source, [string]$Path, [string]$Commit)
    if ($Source -isnot [Collections.IDictionary] -or
        $Source.approved -cne $true -or
        [string]$Source.projectName -cnotmatch '^[\w .-]{1,128}$' -or
        [string]$Source.repositoryName -cnotmatch '^[A-Za-z0-9._-]{1,128}$' -or
        [string]$Source.repositoryId -cnotmatch
            '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$' -or
        [string]$Source.commit -cnotmatch '^[a-f0-9]{40}$' -or
        [string]$Source.path -cne $Path -or
        ($Commit -and [string]$Source.commit -cne $Commit)) {
        throw 'rule-source-not-approved'
    }
}

function Get-CanarySection {
    param([string]$Document, [string]$Heading)
    return (Get-CanaryRawSection $Document $Heading).Trim()
}

function Get-CanaryRawSection {
    param([string]$Document, [string]$Heading)
    $pattern = '(?m)^' + [regex]::Escape($Heading) +
        '[ \t]*(?:\r\n|\n|\r)(?:(?!^##[ \t]).)*(?=^##[ \t]|\z)'
    $sections = [regex]::Matches($Document, $pattern,
        [Text.RegularExpressions.RegexOptions]::Singleline -bor
        [Text.RegularExpressions.RegexOptions]::Multiline)
    if ($sections.Count -ne 1) { throw 'rule-section-unavailable' }
    return $sections[0].Value
}

function Read-CanarySource {
    param([scriptblock]$Provider, [Collections.IDictionary]$Source, [string]$Path)
    $result = & $Provider RuleSource @{
        projectName = $Source.projectName
        repositoryName = $Source.repositoryName
        repositoryId = $Source.repositoryId
        commit = $Source.commit
        path = $Path
    }
    if ($result -isnot [Collections.IDictionary] -or
        $result.content -isnot [string] -or
        [string]$result.projectName -cne [string]$Source.projectName -or
        [string]$result.repositoryName -cne [string]$Source.repositoryName -or
        [string]$result.repositoryId -ine [string]$Source.repositoryId -or
        [string]$result.commit -cne [string]$Source.commit -or
        [string]$result.path -cne $Path -or
        [Text.Encoding]::UTF8.GetByteCount($result.content) -gt 262144) {
        throw 'rule-source-mismatch'
    }
    return [string]$result.content
}

function Get-CanaryCoverageDeclarations {
    param([string]$Document, [string]$RepositoryId,
        [string]$Commit = $script:CoverageCommit)
    $lines = [regex]::Split($Document, '\r\n|\n|\r')
    if ($lines.Count -lt 223) { throw 'coverage-source-section-mismatch' }
    $headingIndex = -1
    for ($i = 0; $i -lt 220; $i++) {
        if ($lines[$i] -cmatch '^## [^\r\n]+$') { $headingIndex = $i }
    }
    if ($headingIndex -lt 0 -or
        @($lines[220..222] | Where-Object { $_ -cmatch '^## ' }).Count -ne 0) {
        throw 'coverage-source-section-mismatch'
    }
    $heading = $lines[$headingIndex]
    $sectionHash = 'v1:sha256:' +
        (Get-CanaryTextHash (Get-CanarySection $Document $heading))
    $ruleIds = @('bpm-test-class-coverage@2',
        'bpm-redundant-method-coverage@2')
    return @(
        for ($i = 0; $i -lt 2; $i++) {
            $line = @(221, 223)[$i]
            $declaration = [ordered]@{
                ruleId = $ruleIds[$i]
                repositoryId = $RepositoryId.ToLowerInvariant()
                commit = $Commit
                path = $script:DocumentPath.Substring(1)
                section = $heading
                sectionHash = $sectionHash
                policyLine = $line
                policyLineHash = 'v1:sha256:' + (Get-CanaryTextHash $lines[$line - 1])
            }
            [ordered]@{
                ruleId = $ruleIds[$i]
                declarationDigest = 'v1:sha256:' + (Get-CanaryTextHash (
                        ConvertTo-AgentCanonicalJson -InputObject $declaration))
                sectionHash = $sectionHash
                policyLine = $line
                policyLineHash = $declaration.policyLineHash
                section = $heading
            }
        }
    )
}

function Assert-CanaryMergedPin {
    param([Collections.IDictionary]$Pin)
    $fields = @('sourceCommit', 'mergeCommit', 'documentHash',
        'documentLength', 'blobId', 'sectionHash', 'classLineHash',
        'redundantLineHash', 'classDeclarationDigest',
        'redundantDeclarationDigest')
    if ($Pin -isnot [Collections.IDictionary] -or
        $Pin.Count -ne $fields.Count) {
        throw 'merged-master-pin-unavailable'
    }
    foreach ($field in $fields) {
        if (-not $Pin.Contains($field)) {
            throw 'merged-master-pin-unavailable'
        }
    }
    if (
        [string]$Pin.sourceCommit -cne $script:CoverageCommit -or
        [string]$Pin.mergeCommit -cnotmatch '^[a-f0-9]{40}$' -or
        [string]$Pin.documentHash -cnotmatch '^[a-f0-9]{64}$' -or
        [string]$Pin.documentHash -cne $script:CoverageDocumentHash -or
        [string]$Pin.documentLength -cnotmatch '^[1-9][0-9]{0,5}$' -or
        [int]$Pin.documentLength -ne $script:CoverageDocumentLength -or
        [int]$Pin.documentLength -gt 262144 -or
        [string]$Pin.blobId -cnotmatch '^[a-f0-9]{40}$' -or
        [string]$Pin.sectionHash -cnotmatch '^v1:sha256:[a-f0-9]{64}$' -or
        [string]$Pin.classLineHash -cnotmatch '^v1:sha256:[a-f0-9]{64}$' -or
        [string]$Pin.redundantLineHash -cnotmatch '^v1:sha256:[a-f0-9]{64}$' -or
        [string]$Pin.classDeclarationDigest -cnotmatch '^v1:sha256:[a-f0-9]{64}$' -or
        [string]$Pin.redundantDeclarationDigest -cnotmatch '^v1:sha256:[a-f0-9]{64}$') {
        throw 'merged-master-pin-unavailable'
    }
}

function Assert-CanaryReviewedMergedPin {
    param([Collections.IDictionary]$Envelope, [string]$Key,
        [Collections.IDictionary]$SourceSelector)
    if ($Envelope -isnot [Collections.IDictionary] -or
        $Envelope.Count -ne 5) {
        throw 'merged-master-pin-unavailable'
    }
    foreach ($field in @('schemaVersion', 'kind', 'selectorSignature',
            'pin', 'signature')) {
        if (-not $Envelope.Contains($field)) {
            throw 'merged-master-pin-unavailable'
        }
    }
    if (
        $Envelope.schemaVersion -ne 1 -or
        $Envelope.kind -cne 'private-reviewed-merged-master-pin' -or
        $Envelope.pin -isnot [Collections.IDictionary] -or
        $SourceSelector -isnot [Collections.IDictionary] -or
        [string]$Envelope.selectorSignature -cne
            [string]$SourceSelector.signature -or
        [string]$Envelope.selectorSignature -cnotmatch
            '^v1:hmac-sha256:[a-f0-9]{64}$' -or
        $Key -cnotmatch '^[A-Za-z0-9+/]{64}$' -or
        [string]$Envelope.signature -cnotmatch
            '^v1:hmac-sha256:[a-f0-9]{64}$') {
        throw 'merged-master-pin-unavailable'
    }
    $signature = [Convert]::FromHexString($Envelope.signature.Substring(15))
    if (-not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
            $signature, [Convert]::FromHexString(
                (Get-CanarySignature $Envelope $Key).Substring(15)))) {
        throw 'merged-master-pin-unavailable'
    }
    Assert-CanaryMergedPin $Envelope.pin
    $pin = [ordered]@{}
    foreach ($field in $Envelope.pin.Keys) {
        $pin[[string]$field] = $Envelope.pin[$field]
    }
    return $pin
}

function Read-CanaryPrivateMergedPin {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PinPath,
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][Collections.IDictionary]$SourceSelector)
    try {
        if (-not [IO.Path]::IsPathFullyQualified($PinPath) -or
            -not [IO.Path]::IsPathFullyQualified($KeyPath) -or
            (Test-AgentPathWithin $PinPath $RepositoryRoot) -or
            (Test-AgentPathWithin $KeyPath $RepositoryRoot)) {
            throw 'merged-master-pin-unavailable'
        }
        $pinFile = Assert-AgentTrustedFile -Path $PinPath -Private
        $keyFile = Assert-AgentTrustedFile -Path $KeyPath -Private
        if ((Get-Item -LiteralPath $pinFile).Length -gt 4096 -or
            (Get-Item -LiteralPath $keyFile).Length -gt 256) {
            throw 'merged-master-pin-unavailable'
        }
        $envelope = Get-Content -LiteralPath $pinFile -Raw |
            ConvertFrom-Json -AsHashtable -Depth 6
        $key = (Get-Content -LiteralPath $keyFile -Raw).Trim()
        [void](Assert-CanaryReviewedMergedPin $envelope $key $SourceSelector)
        return @{ envelope = $envelope; key = $key }
    }
    catch { throw 'merged-master-pin-unavailable' }
}

function Assert-CanaryMergedMasterHead {
    param([scriptblock]$Read, [string]$RepositoryId, [string]$ProjectId,
        [Collections.IDictionary]$Pin, [string]$ExpectedMaster,
        [Collections.IDictionary]$SourceSelector)
    $request = @{ projectName = $SourceSelector.projectName; repositoryId = $RepositoryId }
    $pr = & $Read PullRequest $request
    $iterations = & $Read Iterations $request
    if ($pr -isnot [Collections.IDictionary] -or
        [string]$pr.pullRequestId -cne '17307009' -or
        [string]$pr.repository.id -ine $RepositoryId -or
        [string]$pr.repository.project.id -ine $ProjectId -or
        [string]$pr.repository.project.name -cne [string]$SourceSelector.projectName -or
        [string]$pr.status -cne 'completed' -or
        [string]$pr.targetRefName -cne 'refs/heads/master' -or
        [string]$pr.sourceRefName -cnotmatch
            '^refs/heads/[A-Za-z0-9._/-]{1,512}$' -or
        [string]$pr.lastMergeSourceCommit.commitId -ine $Pin.sourceCommit -or
        [string]$pr.lastMergeCommit.commitId -ine $Pin.mergeCommit -or
        $iterations.value -isnot [array] -or
        $iterations.value.Count -lt 1 -or $iterations.value.Count -gt 200) {
        throw 'merged-master-pr-unverified'
    }
    $seen = [Collections.Generic.HashSet[int]]::new()
    foreach ($iteration in $iterations.value) {
        $id = 0
        if ($iteration -isnot [Collections.IDictionary] -or
            -not [int]::TryParse([string]$iteration.id, [ref]$id) -or
            $id -lt 1 -or -not $seen.Add($id) -or
            [string]$iteration.sourceRefCommit.commitId -cnotmatch
                '^[a-fA-F0-9]{40}$') {
            throw 'merged-master-pr-unverified'
        }
    }
    $latest = @($iterations.value | Sort-Object { [int]$_.id } |
        Select-Object -Last 1)[0]
    if ([string]$latest.sourceRefCommit.commitId -ine $Pin.sourceCommit) {
        throw 'merged-master-pr-unverified'
    }
    $refs = & $Read Ref (@{ projectName = $SourceSelector.projectName
            repositoryId = $RepositoryId; sourceRef = 'refs/heads/master' })
    if ($refs.value -isnot [array] -or $refs.value.Count -gt 100) {
        throw 'merged-master-ref-unverified'
    }
    $matched = @($refs.value | Where-Object name -CEQ 'refs/heads/master')
    if ($matched.Count -ne 1 -or
        [string]$matched[0].objectId -cnotmatch '^[a-fA-F0-9]{40}$' -or
        ($ExpectedMaster -and
            [string]$matched[0].objectId -ine $ExpectedMaster)) {
        throw 'merged-master-ref-unverified'
    }
    return ([string]$matched[0].objectId).ToLowerInvariant()
}

function Assert-CanaryMergedHistory {
    param([scriptblock]$Read, [string]$RepositoryId,
        [string]$MasterCommit, [string]$MergeCommit,
        [Collections.IDictionary]$SourceSelector)
    $pending = [Collections.Generic.Queue[string]]::new()
    $visited = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    $pending.Enqueue($MasterCommit)
    while ($pending.Count -gt 0) {
        if ($visited.Count -ge 64) { throw 'merged-master-history-unproved' }
        $id = $pending.Dequeue()
        if (-not $visited.Add($id)) { continue }
        $commit = & $Read Commit @{ projectName = $SourceSelector.projectName
            repositoryId = $RepositoryId; commit = $id }
        if ([string]$commit.commitId -ine $id -or
            $commit.parents -isnot [array] -or
            $commit.parents.Count -gt 16) {
            throw 'merged-master-history-unproved'
        }
        if ($id -ieq $MergeCommit) { return }
        foreach ($parent in $commit.parents) {
            if ([string]$parent -cnotmatch '^[a-fA-F0-9]{40}$') {
                throw 'merged-master-history-unproved'
            }
            if (-not $visited.Contains([string]$parent)) {
                $pending.Enqueue(([string]$parent).ToLowerInvariant())
            }
        }
    }
    throw 'merged-master-history-unproved'
}

function Assert-CanaryMergedMasterProof {
    param([scriptblock]$Read, [string]$RepositoryId, [string]$ProjectId,
        [Collections.IDictionary]$Pin,
        [Collections.IDictionary]$SourceSelector)
    Assert-CanaryMergedPin $Pin
    $master = Assert-CanaryMergedMasterHead $Read $RepositoryId $ProjectId `
        $Pin '' $SourceSelector
    Assert-CanaryMergedHistory $Read $RepositoryId $master $Pin.mergeCommit `
        $SourceSelector
    $merge = Read-CanaryVerifiedDocument $Read $RepositoryId `
        $Pin.mergeCommit $SourceSelector
    $current = Read-CanaryVerifiedDocument $Read $RepositoryId `
        $master $SourceSelector
    $bytes = [Text.Encoding]::UTF8.GetBytes($merge.text)
    if ($bytes.Length -ne [int]$Pin.documentLength -or
        (Get-CanaryHash $bytes) -cne $Pin.documentHash -or
        $merge.blobId -cne $Pin.blobId -or
        $current.blobId -cne $Pin.blobId -or
        $current.text -cne $merge.text) {
        throw 'merged-master-document-drift'
    }
    $declarations = @(Get-CanaryCoverageDeclarations $merge.text `
            $RepositoryId $Pin.mergeCommit)
    if ($declarations.Count -ne 2 -or
        $declarations[0].sectionHash -cne $Pin.sectionHash -or
        $declarations[1].sectionHash -cne $Pin.sectionHash -or
        $declarations[0].policyLineHash -cne $Pin.classLineHash -or
        $declarations[1].policyLineHash -cne $Pin.redundantLineHash -or
        $declarations[0].declarationDigest -cne $Pin.classDeclarationDigest -or
        $declarations[1].declarationDigest -cne $Pin.redundantDeclarationDigest) {
        throw 'merged-master-declaration-drift'
    }
    return @{ masterCommit = $master; mergeCommit = $Pin.mergeCommit
        document = $merge; declarations = $declarations }
}

function Invoke-CanaryMergedMasterPreflight {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$ExpectedAccountUniqueName,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [string]$AzureCliPath = 'az', [scriptblock]$Read,
        [Collections.IDictionary]$SourceSelector, [string]$SourceSelectorKey,
        [Collections.IDictionary]$MergedPinEnvelope, [string]$MergedPinKey,
        [switch]$Run)
    if (-not $Run) {
        return @{ state = 'disabled'; providerReads = 0; providerWrites = 0 }
    }
    if ($Organization -cnotmatch '^[A-Za-z0-9_-]{1,128}$' -or
        $ExpectedAccountUniqueName -cnotmatch '^[^@\s]+@[^@\s]+$' -or
        -not [IO.Path]::IsPathFullyQualified($RepositoryRoot)) {
        throw 'merged-master-input-invalid'
    }
    [void](Assert-CanarySourceSelector $SourceSelector $SourceSelectorKey $Organization)
    $mergedPin = Assert-CanaryReviewedMergedPin $MergedPinEnvelope `
        $MergedPinKey $SourceSelector
    $session = $null
    try {
        if (-not $Read) {
            $session = New-PrivateCanaryBearerSession $RepositoryRoot $AzureCliPath
            $deadline = [DateTime]::UtcNow.AddSeconds(120)
            $aadGet = ${function:Invoke-CanaryAadGet}
            $Read = {
                param($Operation, $Request)
                & $aadGet $session.client $session.token $Organization `
                    $Operation $Request $deadline
            }.GetNewClosure()
        }
        $budget = @{ count = 0 }
        $bounded = {
            param($Operation, $Request)
            if ($budget.count -ge 120 -or $Operation -cnotin @(
                    'IdentityProof', 'GraphUser', 'GraphStorageKey',
                    'Project', 'Repository', 'PullRequest', 'Iterations',
                    'Ref', 'Commit', 'Item', 'RawItem')) {
                throw 'merged-master-read-budget'
            }
            $budget.count++
            $result = & $Read $Operation $Request
            if ($result -isnot [Collections.IDictionary]) {
                throw 'merged-master-read-inaccessible'
            }
            return $result
        }.GetNewClosure()
        $identity = Assert-CanaryAccountProof $bounded $ExpectedAccountUniqueName
        $engineering = & $bounded Project @{ projectName = $SourceSelector.projectName }
        $enghub = & $bounded Repository @{ projectName = $SourceSelector.projectName
            repositoryName = $SourceSelector.repositoryName }
        $guid = '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$'
        if ([string]$engineering.id -cnotmatch $guid -or
            [string]$engineering.name -cne [string]$SourceSelector.projectName -or
            [string]$enghub.id -cnotmatch $guid -or
            [string]$enghub.name -cne [string]$SourceSelector.repositoryName -or
            [string]$enghub.project.id -ine [string]$engineering.id -or
            [string]$enghub.project.name -cne [string]$SourceSelector.projectName) {
            throw 'merged-master-repository-mismatch'
        }
        $proof = Assert-CanaryMergedMasterProof $bounded `
            ([string]$enghub.id).ToLowerInvariant() `
            ([string]$engineering.id) $mergedPin $SourceSelector
        [void](Assert-CanaryMergedMasterHead $bounded `
            ([string]$enghub.id).ToLowerInvariant() `
            ([string]$engineering.id) $mergedPin $proof.masterCommit `
            $SourceSelector)
        $finalIdentity = Assert-CanaryAccountProof $bounded $ExpectedAccountUniqueName
        Assert-CanaryAccountBinding $finalIdentity $identity
        return @{ schemaVersion = 1; state = 'merged-master-proved-read-only'
            reviewedSourceCommit = $mergedPin.sourceCommit
            mergeCommit = $proof.mergeCommit; masterCommit = $proof.masterCommit
            documentHash = 'v1:sha256:' + $mergedPin.documentHash
            providerReads = $budget.count; providerWrites = 0 }
    }
    finally { if ($session) { $session.client.Dispose() } }
}

function Invoke-CanaryMergedMasterDiscovery {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$ExpectedAccountUniqueName,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [string]$AzureCliPath = 'az', [scriptblock]$Read,
        [Collections.IDictionary]$SourceSelector,
        [int]$SourcePullRequestId,
        [switch]$Run)
    if (-not $Run) {
        return @{ state = 'disabled'; providerReads = 0; providerWrites = 0 }
    }
    if ($Organization -cnotmatch '^[A-Za-z0-9_-]{1,128}$' -or
        $ExpectedAccountUniqueName -cnotmatch '^[^@\s]+@[^@\s]+$' -or
        -not [IO.Path]::IsPathFullyQualified($RepositoryRoot)) {
        throw 'merged-master-input-invalid'
    }
    [void](Assert-CanaryDiscoverySelector $SourceSelector $Organization `
            $SourcePullRequestId)
    $session = $null
    try {
        if (-not $Read) {
            $session = New-PrivateCanaryBearerSession $RepositoryRoot $AzureCliPath
            $deadline = [DateTime]::UtcNow.AddSeconds(120)
            $aadGet = ${function:Invoke-CanaryAadGet}
            $Read = {
                param($Operation, $Request)
                & $aadGet $session.client $session.token $Organization `
                    $Operation $Request $deadline
            }.GetNewClosure()
        }
        $budget = @{ count = 0 }
        $bounded = {
            param($Operation, $Request)
            if ($budget.count -ge 120 -or $Operation -cnotin @(
                    'IdentityProof', 'GraphUser', 'GraphStorageKey',
                    'Project', 'Repository', 'PullRequest', 'Iterations',
                    'Ref', 'Commit', 'Item', 'RawItem')) {
                throw 'merged-master-read-budget'
            }
            $budget.count++
            $result = & $Read $Operation $Request
            if ($result -isnot [Collections.IDictionary]) {
                throw 'merged-master-read-inaccessible'
            }
            return $result
        }.GetNewClosure()
        $identity = Assert-CanaryAccountProof $bounded $ExpectedAccountUniqueName
        $engineering = & $bounded Project @{ projectName = $SourceSelector.projectName }
        $enghub = & $bounded Repository @{ projectName = $SourceSelector.projectName
            repositoryName = $SourceSelector.repositoryName }
        $guid = '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$'
        if ([string]$engineering.id -cnotmatch $guid -or
            [string]$engineering.name -cne [string]$SourceSelector.projectName -or
            [string]$enghub.id -cnotmatch $guid -or
            [string]$enghub.name -cne [string]$SourceSelector.repositoryName -or
            [string]$enghub.project.id -ine [string]$engineering.id -or
            [string]$enghub.project.name -cne [string]$SourceSelector.projectName) {
            throw 'merged-master-repository-mismatch'
        }
        $engId = ([string]$enghub.id).ToLowerInvariant()
        $pr = & $bounded PullRequest @{
            projectName = $SourceSelector.projectName; repositoryId = $engId }
        if ($pr -isnot [Collections.IDictionary] -or
            $pr.lastMergeCommit -isnot [Collections.IDictionary] -or
            [string]$pr.lastMergeCommit.commitId -cnotmatch
                '^[a-fA-F0-9]{40}$') {
            throw 'merged-master-pr-unverified'
        }
        $provisional = @{ sourceCommit = $script:CoverageCommit
            mergeCommit = ([string]$pr.lastMergeCommit.commitId).ToLowerInvariant() }
        $master = Assert-CanaryMergedMasterHead $bounded $engId `
            ([string]$engineering.id) $provisional '' $SourceSelector
        Assert-CanaryMergedHistory $bounded $engId $master `
            $provisional.mergeCommit $SourceSelector
        $candidate = Read-CanaryVerifiedDocument $bounded $engId `
            $script:CoverageCommit $SourceSelector
        $candidateBytes = [Text.Encoding]::UTF8.GetBytes($candidate.text)
        if ($candidateBytes.Length -ne $script:CoverageDocumentLength -or
            (Get-CanaryHash $candidateBytes) -cne $script:CoverageDocumentHash) {
            throw 'reviewed-source-bytes-mismatch'
        }
        $merge = Read-CanaryVerifiedDocument $bounded $engId `
            $provisional.mergeCommit $SourceSelector
        $current = Read-CanaryVerifiedDocument $bounded $engId $master `
            $SourceSelector
        $mergeBytes = [Text.Encoding]::UTF8.GetBytes($merge.text)
        if ($mergeBytes.Length -ne $candidateBytes.Length -or
            $merge.text -cne $candidate.text -or
            $current.text -cne $merge.text -or
            $current.blobId -cne $merge.blobId) {
            throw 'merged-master-content-differs-human-review'
        }
        $reviewed = @(Get-CanaryCoverageDeclarations $candidate.text `
                $engId $script:CoverageCommit)
        $merged = @(Get-CanaryCoverageDeclarations $merge.text `
                $engId $provisional.mergeCommit)
        if ($reviewed.Count -ne 2 -or $merged.Count -ne 2 -or
            $merged[0].sectionHash -cne $reviewed[0].sectionHash -or
            $merged[1].sectionHash -cne $reviewed[1].sectionHash -or
            $merged[0].policyLineHash -cne $reviewed[0].policyLineHash -or
            $merged[1].policyLineHash -cne $reviewed[1].policyLineHash) {
            throw 'merged-master-section-differs-human-review'
        }
        $pin = @{
            sourceCommit = $script:CoverageCommit
            mergeCommit = $provisional.mergeCommit
            documentHash = Get-CanaryHash $mergeBytes
            documentLength = $mergeBytes.Length
            blobId = $merge.blobId
            sectionHash = $merged[0].sectionHash
            classLineHash = $merged[0].policyLineHash
            redundantLineHash = $merged[1].policyLineHash
            classDeclarationDigest = $merged[0].declarationDigest
            redundantDeclarationDigest = $merged[1].declarationDigest
        }
        Assert-CanaryMergedPin $pin
        [void](Assert-CanaryMergedMasterHead $bounded $engId `
            ([string]$engineering.id) $provisional $master $SourceSelector)
        $finalIdentity = Assert-CanaryAccountProof $bounded $ExpectedAccountUniqueName
        Assert-CanaryAccountBinding $finalIdentity $identity
        return [ordered]@{
            schemaVersion = 1
            state = 'discovered-merged-source-no-state'
            candidateBytesMatch = $true
            observedMasterCommit = $master
            proposedPin = $pin
            providerReads = $budget.count
            providerWrites = 0
        }
    }
    finally { if ($session) { $session.client.Dispose() } }
}

function Invoke-CanaryMergedPinProvisionCore {
    [CmdletBinding()]
    param([string]$StateRoot, [string]$RepositoryRoot,
        [Collections.IDictionary]$SourceSelector, [int]$SourcePullRequestId,
        [string]$DocumentPath,
        [string]$ExpectedAccountUniqueName,
        [string]$AzureCliPath = 'az', [scriptblock]$Read,
        [switch]$Run)
    if (-not $Run) {
        return @{ state = 'disabled'; providerReads = 0
            providerWrites = 0; privateFilesWritten = 0 }
    }
    if (-not [IO.Path]::IsPathFullyQualified($StateRoot) -or
        -not [IO.Path]::IsPathFullyQualified($RepositoryRoot)) {
        throw 'merged-master-private-root-invalid'
    }
    $root = [IO.Path]::GetFullPath($StateRoot)
    $parent = Split-Path $root -Parent
    if ((Split-Path $root -Leaf) -cnotmatch
            '^private-merged-pin-[a-f0-9]{32}$' -or
        (Test-AgentPathWithin $root $RepositoryRoot) -or
        (Test-AgentPathWithin $RepositoryRoot $root) -or
        (Test-Path -LiteralPath $root) -or
        (Test-Path -LiteralPath "$root.staging")) {
        throw 'merged-master-private-root-invalid'
    }
    try {
        [void](Resolve-AgentTrustedRoot -Path $parent -Kind durable-state `
                -RepositoryRoot $RepositoryRoot)
    }
    catch { throw 'merged-master-private-root-invalid' }
    $organization = if ($SourceSelector) {
        [string]$SourceSelector['organization']
    } else { '' }
    if ($DocumentPath -cne $script:DocumentPath) {
        throw 'source-selector-invalid'
    }
    [void](Assert-CanaryDiscoverySelector $SourceSelector $organization `
            $SourcePullRequestId)
    if (-not $Read) {
        $ExpectedAccountUniqueName = Get-CanaryWorkAccountUpn $AzureCliPath
    } elseif ($ExpectedAccountUniqueName -cnotmatch '^[^@\s]+@[^@\s]+$') {
        throw 'canary-work-account-unavailable'
    }
    $route = @{ organization = $organization
        projectName = [string]$SourceSelector.projectName
        repositoryName = [string]$SourceSelector.repositoryName }
    $proof = Invoke-CanaryMergedMasterDiscovery `
        -Organization $organization `
        -ExpectedAccountUniqueName $ExpectedAccountUniqueName `
        -RepositoryRoot $RepositoryRoot -AzureCliPath $AzureCliPath `
        -SourceSelector $route -SourcePullRequestId $SourcePullRequestId `
        -Read $Read -Run
    if ($proof.state -cne 'discovered-merged-source-no-state' -or
        $proof.candidateBytesMatch -cne $true -or
        $proof.proposedPin -isnot [Collections.IDictionary]) {
        throw 'merged-master-proof-unavailable'
    }
    Assert-CanaryMergedPin $proof.proposedPin
    $verifiedPin = [ordered]@{}
    foreach ($field in $proof.proposedPin.Keys) {
        $verifiedPin[[string]$field] = $proof.proposedPin[$field]
    }
    $staging = "$root.staging"
    $created = $false
    $published = $false
    try {
        if ((Test-Path -LiteralPath $root) -or
            (Test-Path -LiteralPath $staging)) {
            throw 'merged-master-private-root-invalid'
        }
        [void](Resolve-AgentTrustedRoot -Path $parent -Kind durable-state `
                -RepositoryRoot $RepositoryRoot)
        [void](Resolve-AgentTrustedRoot -Path $staging -Kind durable-state `
                -RepositoryRoot $RepositoryRoot -Create `
                -CreatedByCaller ([ref]$created))
        if (-not $created) { throw 'merged-master-private-root-invalid' }
        $selectorKey = [Convert]::ToBase64String(
            [Security.Cryptography.RandomNumberGenerator]::GetBytes(48))
        $selector = [ordered]@{
            schemaVersion = 1; kind = 'private-canary-source-selector'
            organization = $route.organization
            projectName = $route.projectName
            repositoryName = $route.repositoryName
            signature = ''
        }
        $selector.signature = Get-CanarySignature $selector $selectorKey
        [void](Assert-CanarySourceSelector $selector $selectorKey $organization)
        $key = [Convert]::ToBase64String(
            [Security.Cryptography.RandomNumberGenerator]::GetBytes(48))
        $envelope = [ordered]@{
            schemaVersion = 1; kind = 'private-reviewed-merged-master-pin'
            selectorSignature = $selector.signature
            pin = $verifiedPin; signature = ''
        }
        $envelope.signature = Get-CanarySignature $envelope $key
        $selectorKeyPath = Join-Path $staging 'source-selector.key'
        $selectorPath = Join-Path $staging 'source-selector.json'
        $keyPath = Join-Path $staging 'merged-pin.key'
        $pinPath = Join-Path $staging 'merged-pin.json'
        Write-CanaryPrivateFile $selectorKeyPath (
            [Text.Encoding]::UTF8.GetBytes($selectorKey))
        Write-CanaryPrivateFile $selectorPath ([Text.Encoding]::UTF8.GetBytes(
                (ConvertTo-Json -InputObject $selector -Depth 4 -Compress)))
        Write-CanaryPrivateFile $keyPath ([Text.Encoding]::UTF8.GetBytes($key))
        Write-CanaryPrivateFile $pinPath ([Text.Encoding]::UTF8.GetBytes(
                (ConvertTo-Json -InputObject $envelope -Depth 8 -Compress)))
        foreach ($path in @($selectorKeyPath, $selectorPath, $keyPath, $pinPath)) {
            [void](Assert-AgentTrustedFile -Path $path `
                    -AllowedRoot $staging -Private)
        }
        [IO.Directory]::Move($staging, $root)
        $published = $true
        $created = $false
        [void](Resolve-AgentTrustedRoot -Path $root -Kind durable-state `
                -RepositoryRoot $RepositoryRoot)
        foreach ($name in @('source-selector.key', 'source-selector.json',
                'merged-pin.key', 'merged-pin.json')) {
            [void](Assert-AgentTrustedFile -Path (Join-Path $root $name) `
                    -AllowedRoot $root -Private)
        }
        $savedSelector = Read-CanaryPrivateSourceSelector `
            -SelectorPath (Join-Path $root 'source-selector.json') `
            -KeyPath (Join-Path $root 'source-selector.key') `
            -RepositoryRoot $RepositoryRoot
        [void](Assert-CanarySourceSelector $savedSelector.selector `
                $savedSelector.key $organization)
        [void](Read-CanaryPrivateMergedPin `
                -PinPath (Join-Path $root 'merged-pin.json') `
                -KeyPath (Join-Path $root 'merged-pin.key') `
                -RepositoryRoot $RepositoryRoot `
                -SourceSelector $savedSelector.selector)
        return @{ state = 'private-source-pin-prepared-unactivated'
            providerReads = $proof.providerReads; providerWrites = 0
            privateFilesWritten = 4 }
    }
    catch {
        $cleanup = if ($published) { $root } elseif ($created) { $staging }
        if ($cleanup) {
            try {
                Remove-AgentContainedDirectory -Path $cleanup `
                    -AllowedRoot $parent `
                    -LeafPattern '^private-merged-pin-[a-f0-9]{32}(\.staging)?$'
            }
            catch { throw 'merged-master-private-cleanup-failed' }
        }
        throw 'merged-master-private-provision-failed'
    }
}

function Invoke-PrivateCanaryMergedPinProvision {
    [CmdletBinding()]
    param([string]$StateRoot, [string]$RepositoryRoot,
        [Collections.IDictionary]$SourceSelector, [int]$SourcePullRequestId,
        [string]$DocumentPath,
        [string]$AzureCliPath = 'az',
        [switch]$Run)
    if (-not $Run) {
        return @{ state = 'disabled'; providerReads = 0
            providerWrites = 0; privateFilesWritten = 0 }
    }
    return Invoke-CanaryMergedPinProvisionCore -StateRoot $StateRoot `
        -RepositoryRoot $RepositoryRoot -SourceSelector $SourceSelector `
        -SourcePullRequestId $SourcePullRequestId `
        -DocumentPath $DocumentPath -AzureCliPath $AzureCliPath -Run
}

function Assert-CanaryCoverageSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$ApprovedSources,
        [Parameter(Mandatory)][scriptblock]$Provider,
        [Collections.IDictionary]$SourceSelector,
        [string]$SourceSelectorKey,
        [switch]$Run
    )
    if (-not $Run) {
        return [ordered]@{ state = 'disabled'; headVerified = $false
            providerReads = 0; providerWrites = 0 }
    }
    $sourceOrg = if ($SourceSelector) {
        [string]$SourceSelector['organization']
    } else { '' }
    [void](Assert-CanarySourceSelector $SourceSelector $SourceSelectorKey $sourceOrg)
    $ruleIds = @('bpm-test-class-coverage@2',
        'bpm-redundant-method-coverage@2')
    $sources = @($ApprovedSources[$ruleIds[0]], $ApprovedSources[$ruleIds[1]])
    foreach ($i in 0..1) {
        $source = $sources[$i]
        Assert-CanarySource $source $script:DocumentPath $script:CoverageCommit
        if ([string]$source.ruleId -cne $ruleIds[$i] -or
            [string]$source.organization -cne
                [string]$SourceSelector.organization -or
            [string]$source.projectName -cne
                [string]$SourceSelector.projectName -or
            [string]$source.repositoryName -cne
                [string]$SourceSelector.repositoryName -or
            [string]$source.provenance -cne 'unmerged-reviewed-pr' -or
            [string]$source.reviewedPullRequestId -cne '17307009' -or
            [string]$source.reviewedHead -cne $script:CoverageCommit -or
            [string]$source.documentHash -cne
                ('v1:sha256:' + $script:CoverageDocumentHash) -or
            [string]$source.declarationDigest -cnotmatch '^v1:sha256:[a-f0-9]{64}$') {
            throw 'coverage-source-not-approved'
        }
    }
    if ([string]$sources[0].repositoryId -ine [string]$sources[1].repositoryId) {
        throw 'coverage-source-identity-mismatch'
    }
    $document = Read-CanarySource $Provider $sources[0] $script:DocumentPath
    $bytes = [Text.Encoding]::UTF8.GetBytes($document)
    if ($bytes.Length -ne $script:CoverageDocumentLength -or
        (Get-CanaryHash $bytes) -cne $script:CoverageDocumentHash) {
        throw 'coverage-source-bytes-mismatch'
    }
    $declarations = @(Get-CanaryCoverageDeclarations $document `
            ([string]$sources[0].repositoryId))
    for ($i = 0; $i -lt 2; $i++) {
        if ([string]$sources[$i].declarationDigest -cne
            $declarations[$i].declarationDigest) {
            throw 'coverage-declaration-digest-mismatch'
        }
    }
    return [ordered]@{
        schemaVersion = 1
        state = 'immutable-candidate-only'
        provenance = 'unmerged-reviewed-pr'
        reviewCaution = 'pending-human-review; not-master-authority'
        reviewedPullRequestId = 17307009
        reviewedHead = $script:CoverageCommit
        headVerified = $false
        repositoryId = ([string]$sources[0].repositoryId).ToLowerInvariant()
        commit = $script:CoverageCommit
        path = $script:DocumentPath.Substring(1)
        documentHash = 'v1:sha256:' + $script:CoverageDocumentHash
        declarations = @($declarations | ForEach-Object {
                [ordered]@{ ruleId = $_.ruleId
                    declarationDigest = $_.declarationDigest
                    sectionHash = $_.sectionHash; policyLine = $_.policyLine }
            })
    }
}

function Write-CanaryPrivateFile {
    param([string]$Path, [byte[]]$Bytes)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        if (-not $IsWindows) {
            [IO.File]::SetUnixFileMode($Path, (
                [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite))
        }
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
}

function Get-CanarySignature {
    param([Collections.IDictionary]$Config, [string]$Key)
    $unsigned = [ordered]@{}
    foreach ($entry in $Config.Keys) {
        if ([string]$entry -cne 'signature') { $unsigned[[string]$entry] = $Config[$entry] }
    }
    $hmac = [Security.Cryptography.HMACSHA256]::new(
        [Text.Encoding]::UTF8.GetBytes($Key))
    try {
        return 'v1:hmac-sha256:' +
            [Convert]::ToHexString($hmac.ComputeHash(
                    [Text.Encoding]::UTF8.GetBytes(
                        (ConvertTo-AgentCanonicalJson -InputObject $unsigned))
                )).ToLowerInvariant()
    }
    finally { $hmac.Dispose() }
}

function Get-CanaryGitValue {
    param([string]$RepositoryRoot, [string[]]$Arguments)
    try { $answer = & git -C $RepositoryRoot @Arguments 2>$null }
    catch { throw 'local-rule-source-unavailable' }
    if ($LASTEXITCODE -ne 0 -or @($answer).Count -ne 1 -or
        [string]$answer -cnotmatch '^[a-f0-9]{40}$') {
        throw 'local-rule-source-unavailable'
    }
    return [string]$answer
}

function Get-CanaryGitRepository {
    param([string]$RepositoryRoot)
    try { $url = & git -C $RepositoryRoot remote get-url origin 2>$null }
    catch { throw 'local-rule-source-unavailable' }
    if ($LASTEXITCODE -ne 0 -or @($url).Count -ne 1 -or
        [string]$url -cnotmatch
            '^(?:https://github\.com/|git@github\.com:)(?<owner>[A-Za-z0-9._-]+)/(?<repo>[A-Za-z0-9._-]+?)(?:\.git)?$') {
        throw 'local-rule-source-unavailable'
    }
    return "$($Matches.owner)/$($Matches.repo)"
}

function Get-CanaryAadToken {
    param([string]$AzureCliPath, [string]$Resource)
    if ($Resource -cnotmatch
        '^https://[A-Za-z0-9-]+\.vssps\.visualstudio\.com/?$') {
        throw 'bootstrap-credential-unavailable'
    }
    try {
        $command = Get-Command $AzureCliPath -CommandType Application,ExternalScript `
            -ErrorAction Stop | Select-Object -First 1
        $response = & $command.Source account get-access-token --resource `
            $Resource --output json `
            --only-show-errors 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'bootstrap-credential-unavailable' }
        $credential = $response | ConvertFrom-Json -AsHashtable -Depth 8
        if ($credential.tokenType -ine 'Bearer' -or
            [string]$credential.accessToken -cnotmatch
                '^[A-Za-z0-9._~+/-]{40,8192}(?:={0,2})$') {
            throw 'bootstrap-credential-unavailable'
        }
        return [string]$credential.accessToken
    }
    catch { throw 'bootstrap-credential-unavailable' }
}

function Get-CanaryWorkAccountUpn {
    param([string]$AzureCliPath)
    try {
        $command = Get-Command $AzureCliPath -CommandType Application,ExternalScript `
            -ErrorAction Stop | Select-Object -First 1
        $response = & $command.Source account show --output json `
            --only-show-errors 2>$null | ConvertFrom-Json -AsHashtable -Depth 8
        if ($LASTEXITCODE -ne 0 -or
            $response -isnot [Collections.IDictionary] -or
            $response.user -isnot [Collections.IDictionary] -or
            $response.user.type -cne 'user' -or
            $response.environmentName -cne 'AzureCloud' -or
            [string]$response.tenantId -cnotmatch
                '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$' -or
            [string]$response.id -cnotmatch
                '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$' -or
            [string]$response.user.name -cnotmatch '^[^@\s]+@[^@\s]+$') {
            throw 'canary-work-account-unavailable'
        }
        return [string]$response.user.name
    }
    catch { throw 'canary-work-account-unavailable' }
}

function New-PrivateCanaryBearerSession {
    param([string]$RepositoryRoot, [string]$AzureCliPath)
    $template = Get-Content -LiteralPath (Join-Path $RepositoryRoot `
            'samples\active-pr-intake.config.json') -Raw |
        ConvertFrom-Json -AsHashtable
    $token = Get-CanaryAadToken $AzureCliPath ([string]$template.identityResource)
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(120)
    return @{ token = $token; client = $client }
}

function Get-CanaryIdentityPayload {
    param([byte[]]$Bytes, [AllowEmptyString()][string]$MediaType,
        [bool]$Encoded, [switch]$AllowMissingUniqueName)
    if ($Encoded) { return @{ reason = 'encoded-response' } }
    if ($MediaType -and $MediaType -cne 'application/json' -and
        $MediaType -cnotmatch '^application/[A-Za-z0-9._-]+\+json$') {
        return @{ reason = 'non-json-media' }
    }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xef -and
        $Bytes[1] -eq 0xbb -and $Bytes[2] -eq 0xbf) {
        return @{ reason = 'utf8-bom' }
    }
    try { $text = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes) }
    catch [Text.DecoderFallbackException] {
        return @{ reason = 'invalid-utf8' }
    }
    catch { return @{ reason = 'unclassified' } }
    try { $result = $text | ConvertFrom-Json -AsHashtable -Depth 12 }
    catch {
        $document = $null
        try {
            $options = [Text.Json.JsonDocumentOptions]::new()
            $options.MaxDepth = 65536
            $document = [Text.Json.JsonDocument]::Parse($text, $options)
        }
        catch [Text.Json.JsonException] {
            return @{ reason = 'invalid-json' }
        }
        catch { return @{ reason = 'unclassified' } }
        finally { if ($document) { $document.Dispose() } }
        $shallow = $null
        try {
            $options.MaxDepth = 12
            $shallow = [Text.Json.JsonDocument]::Parse($text, $options)
        }
        catch [Text.Json.JsonException] {
            return @{ reason = 'json-depth-over-12' }
        }
        catch { return @{ reason = 'unclassified' } }
        finally { if ($shallow) { $shallow.Dispose() } }
        return @{ reason = 'unclassified' }
    }
    if ($result -isnot [Collections.IDictionary] -or
        $result['authenticatedUser'] -isnot [Collections.IDictionary]) {
        return @{ reason = 'identity-fields-missing' }
    }
    $user = $result['authenticatedUser']
    foreach ($field in @('id', 'subjectDescriptor')) {
        if (-not $user.Contains($field)) {
            return @{ reason = 'identity-fields-missing' }
        }
    }
    if (-not $AllowMissingUniqueName -and -not $user.Contains('uniqueName')) {
        return @{ reason = 'identity-fields-missing' }
    }
    return @{ reason = 'valid'; identity = @{
            id = $user['id']; descriptor = $user['subjectDescriptor']
            uniqueName = $user['uniqueName'] } }
}

function Assert-CanaryAccountProof {
    param([scriptblock]$Read, [string]$ExpectedUpn)
    $guid = '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$'
    $identity = & $Read IdentityProof @{}
    if ($identity -isnot [Collections.IDictionary] -or
        [string]$identity.id -cnotmatch $guid -or
        [string]$identity.descriptor -cnotmatch '^[A-Za-z0-9._-]{1,512}$' -or
        ($null -ne $identity['uniqueName'] -and
            ([string]$identity.uniqueName -cnotmatch '^[^@\s]+@[^@\s]+$' -or
                [string]$identity.uniqueName -ine $ExpectedUpn))) {
        throw 'canary-principal-mismatch'
    }
    $user = & $Read GraphUser @{ subjectDescriptor = $identity.descriptor }
    if ($user -isnot [Collections.IDictionary] -or
        [string]$user.descriptor -cne [string]$identity.descriptor -or
        [string]$user.subjectKind -cne 'user' -or
        [string]$user.principalName -cnotmatch '^[^@\s]+@[^@\s]+$' -or
        [string]$user.principalName -ine $ExpectedUpn) {
        throw 'canary-principal-mismatch'
    }
    $storage = & $Read GraphStorageKey @{
        subjectDescriptor = $identity.descriptor }
    if ($storage -isnot [Collections.IDictionary] -or
        [string]$storage.value -cnotmatch $guid -or
        [string]$storage.value -ine [string]$identity.id) {
        throw 'canary-principal-mismatch'
    }
    $proof = [ordered]@{
        id = ([string]$identity.id).ToLowerInvariant()
        descriptor = [string]$identity.descriptor
        principalName = ([string]$user.principalName).ToLowerInvariant()
    }
    if ($null -ne $identity['uniqueName']) {
        $proof.uniqueName = ([string]$identity.uniqueName).ToLowerInvariant()
    }
    return $proof
}

function Assert-CanaryAccountBinding {
    param([Collections.IDictionary]$Actual,
        [Collections.IDictionary]$Expected)
    if ($Expected.Count -eq 2 -and
        $Expected.Contains('id') -and $Expected.Contains('descriptor')) {
        if ($Actual -isnot [Collections.IDictionary] -or
            [string]$Actual.id -ine [string]$Expected.id -or
            [string]$Actual.descriptor -cne [string]$Expected.descriptor) {
            throw 'canary-identity-drift'
        }
        return
    }
    if ($Actual -isnot [Collections.IDictionary] -or
        $Expected -isnot [Collections.IDictionary] -or
        [string]$Actual.id -ine [string]$Expected.id -or
        [string]$Actual.descriptor -cne [string]$Expected.descriptor -or
        [string]$Actual.principalName -ine [string]$Expected.principalName -or
        ($Actual.Contains('uniqueName') -ne $Expected.Contains('uniqueName')) -or
        ($Expected.Contains('uniqueName') -and
            [string]$Actual.uniqueName -ine [string]$Expected.uniqueName)) {
        throw 'canary-identity-drift'
    }
}

function Invoke-CanaryAadGet {
    param([Net.Http.HttpClient]$Client, [string]$Token, [string]$Organization,
        [string]$Operation, [Collections.IDictionary]$Request,
        [DateTime]$Deadline, [Collections.IDictionary]$ReadTelemetry)
    $guid = '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$'
    $sha = '^[a-f0-9]{40}$'
    $project = [string]$Request['projectName']
    $repository = [string]$Request['repositoryId']
    $commit = [string]$Request['commit']
    $path = [string]$Request['path']
    $esc = [Uri]::EscapeDataString
    $base = "https://dev.azure.com/$Organization"
    $url = switch -CaseSensitive ($Operation) {
        { $_ -cin @('Identity', 'IdentityProof') } {
            "$base/_apis/connectionData?api-version=7.1-preview.1"
        }
        { $_ -cin @('GraphUser', 'GraphStorageKey') } {
            $descriptor = [string]$Request['subjectDescriptor']
            if ($descriptor -cnotmatch '^[A-Za-z0-9._-]{1,512}$') {
                throw 'bootstrap-request-invalid'
            }
            $graphBase = "https://vssps.dev.azure.com/$Organization/_apis/graph"
            if ($Operation -ceq 'GraphUser') {
                "$graphBase/users/$($esc.Invoke($descriptor))?api-version=7.1-preview.1"
            } else {
                "$graphBase/storagekeys/$($esc.Invoke($descriptor))?api-version=7.1"
            }
        }
        Project {
            if ($project -cnotmatch '^[\w .-]{1,128}$' -or
                $project -in @('.', '..')) {
                throw 'bootstrap-request-invalid'
            }
            "$base/_apis/projects/$($esc.Invoke($project))?api-version=7.1"
        }
        Repository {
            if ($project -cnotmatch '^[\w .-]{1,128}$' -or
                $project -in @('.', '..') -or
                [string]$Request.repositoryName -cnotmatch
                    '^[A-Za-z0-9._-]{1,128}$' -or
                [string]$Request.repositoryName -in @('.', '..')) {
                throw 'bootstrap-request-invalid'
            }
            "$base/$($esc.Invoke($project))/_apis/git/repositories/" +
                "$($esc.Invoke([string]$Request.repositoryName))?api-version=7.1"
        }
        PullRequest {
            if ($project -cnotmatch '^[\w .-]{1,128}$' -or
                $repository -cnotmatch $guid) { throw 'bootstrap-request-invalid' }
            "$base/$($esc.Invoke($project))/_apis/git/repositories/$repository/" +
                'pullRequests/17307009?api-version=7.1'
        }
        Iterations {
            if ($project -cnotmatch '^[\w .-]{1,128}$' -or
                $repository -cnotmatch $guid) { throw 'bootstrap-request-invalid' }
            "$base/$($esc.Invoke($project))/_apis/git/repositories/$repository/" +
                'pullRequests/17307009/iterations?api-version=7.1'
        }
        Ref {
            if ($project -cnotmatch '^[\w .-]{1,128}$' -or
                $repository -cnotmatch $guid -or
                [string]$Request.sourceRef -cnotmatch
                    '^refs/heads/[A-Za-z0-9._/-]{1,512}$') {
                throw 'bootstrap-request-invalid'
            }
            "$base/$($esc.Invoke($project))/_apis/git/repositories/$repository/" +
                "refs?filter=$($esc.Invoke(([string]$Request.sourceRef).Substring(5)))" +
                '&$top=100&api-version=7.1'
        }
        Commit {
            if ($project -cnotmatch '^[\w .-]{1,128}$' -or
                $repository -cnotmatch $guid -or $commit -cnotmatch $sha) {
                throw 'bootstrap-request-invalid'
            }
            "$base/$($esc.Invoke($project))/_apis/git/repositories/$repository/" +
                "commits/$commit`?api-version=7.1"
        }
        { $_ -cin @('Item', 'RawItem') } {
            if ($project -cnotmatch '^[\w .-]{1,128}$' -or
                $repository -cnotmatch $guid -or $commit -cnotmatch $sha -or
                $path -cne $script:DocumentPath) {
                throw 'bootstrap-request-invalid'
            }
            "$base/$($esc.Invoke($project))/_apis/git/repositories/$repository/" +
                "items?path=$($esc.Invoke($path))&versionDescriptor.version=$commit" +
                '&versionDescriptor.versionType=commit&' +
                $(if ($Operation -ceq 'Item') {
                        'includeContent=false&includeContentMetadata=true&'
                    } else { '' }) + 'api-version=7.1'
        }
        default { throw 'bootstrap-request-invalid' }
    }
    $limit = if ($Operation -ceq 'RawItem') { 262144 } else { 65536 }
    $message = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $url)
    $message.Headers.Authorization =
        [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Token)
    $message.Headers.Accept.ParseAdd($(if ($Operation -ceq 'RawItem') {
                'application/octet-stream'
            } else { 'application/json' }))
    $remaining = [Math]::Max(1, [int]($Deadline - [DateTime]::UtcNow).TotalMilliseconds)
    $cancel = [Threading.CancellationTokenSource]::new($remaining)
    $failureStatus = 0
    $throttled = $false
    $phase = 'send'
    $decodeReason = ''
    try {
        $response = $Client.SendAsync($message,
            [Net.Http.HttpCompletionOption]::ResponseHeadersRead,
            $cancel.Token).GetAwaiter().GetResult()
        try {
            $failureStatus = [int]$response.StatusCode
            $delay = @($response.Headers | Where-Object {
                $_.Key -match '(?i)^x-(?:ms-|vss-)?ratelimit-delay$' -and
                @($_.Value | Where-Object {
                    [string]$_ -match '^\s*(?:[1-9][0-9]*(?:\.[0-9]+)?|0\.[0-9]*[1-9][0-9]*)\s*$'
                }).Count -gt 0
            }).Count -gt 0
            if ($failureStatus -in @(429, 503) -or
                $response.Headers.RetryAfter -or $delay) {
                $throttled = $true
                if ($ReadTelemetry) {
                    $ReadTelemetry.lastHttpStatus = $failureStatus
                }
                throw 'bootstrap-read-throttled'
            }
            if (-not $response.IsSuccessStatusCode) {
                if ($ReadTelemetry) {
                    $ReadTelemetry.lastHttpStatus = $failureStatus
                }
                throw 'bootstrap-read-inaccessible'
            }
            $failureStatus = 0
            $phase = 'read'
            if ($null -ne $response.Content.Headers.ContentLength -and
                    $response.Content.Headers.ContentLength -gt $limit) {
                throw 'bootstrap-read-inaccessible'
            }
            $mediaType = if ($response.Content.Headers.ContentType) {
                [string]$response.Content.Headers.ContentType.MediaType
            } else { '' }
            $encoded = $response.Content.Headers.ContentEncoding.Count -gt 0
            $stream = $response.Content.ReadAsStreamAsync(
                $cancel.Token).GetAwaiter().GetResult()
            $output = [IO.MemoryStream]::new()
            $buffer = [byte[]]::new(8192)
            try {
                while (($n = $stream.ReadAsync($buffer, 0, $buffer.Length,
                            $cancel.Token).GetAwaiter().GetResult()) -gt 0) {
                    if ($output.Length + $n -gt $limit) {
                        throw 'bootstrap-read-inaccessible'
                    }
                    $output.Write($buffer, 0, $n)
                }
                $bytes = $output.ToArray()
            }
            finally { $output.Dispose() }
        }
        finally { $response.Dispose() }
        if ($Operation -ceq 'RawItem') { return @{ bytes = $bytes } }
        $phase = 'decode'
        if ($Operation -cin @('Identity', 'IdentityProof')) {
            $classified = Get-CanaryIdentityPayload -Bytes $bytes `
                -MediaType $mediaType -Encoded $encoded `
                -AllowMissingUniqueName:($Operation -ceq 'IdentityProof')
            $decodeReason = [string]$classified.reason
            if ($decodeReason -cne 'valid') {
                throw 'bootstrap-read-inaccessible'
            }
            return $classified.identity
        }
        if ($Operation -cin @('GraphUser', 'GraphStorageKey')) {
            if ($encoded -or
                ($mediaType -and $mediaType -cne 'application/json' -and
                    $mediaType -cnotmatch '^application/[A-Za-z0-9._-]+\+json$') -or
                ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and
                    $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf)) {
                throw 'bootstrap-read-inaccessible'
            }
            $result = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) |
                ConvertFrom-Json -AsHashtable -Depth 12
            if ($result -isnot [Collections.IDictionary]) {
                throw 'bootstrap-read-inaccessible'
            }
            return $result
        }
        $result = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) |
            ConvertFrom-Json -AsHashtable -Depth 12
        return $result
    }
    catch {
        if ($throttled) { throw "bootstrap-read-throttled:$Operation" }
        if ($failureStatus -gt 0) {
            throw ('bootstrap-read-inaccessible:{0}:http-{1}' -f
                $Operation, $failureStatus)
        }
        if ($Operation -cin @('Identity', 'IdentityProof') -and
            $phase -ceq 'decode' -and
            $decodeReason -cin @('encoded-response', 'non-json-media',
                'utf8-bom', 'invalid-utf8', 'invalid-json',
                'json-depth-over-12', 'identity-fields-missing',
                'unclassified')) {
            throw "bootstrap-read-inaccessible:$($Operation):$decodeReason"
        }
        throw ('bootstrap-read-inaccessible:{0}:{1}' -f $Operation, $phase)
    }
    finally {
        $cancel.Dispose()
        $message.Dispose()
    }
}

function Invoke-PrivateCanaryIdentityDiagnostic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$ExpectedAccountUniqueName,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [string]$AzureCliPath = 'az',
        [scriptblock]$Read,
        [switch]$VerifyGraph,
        [switch]$Run
    )
    if ($Organization -cnotmatch '^[A-Za-z0-9_-]{1,128}$' -or
        $ExpectedAccountUniqueName -cnotmatch '^[^@\s]+@[^@\s]+$' -or
        -not [IO.Path]::IsPathFullyQualified($RepositoryRoot)) {
        throw 'identity-diagnostic-input-invalid'
    }
    if (-not $Run) {
        return [ordered]@{ state = 'disabled'; reason = 'disabled'
            getAttempts = 0; providerWrites = 0; modelToolInvocations = 0 }
    }
    $client = $null
    try {
        if (-not $Read) {
            $template = Get-Content -LiteralPath (Join-Path $RepositoryRoot `
                    'samples\active-pr-intake.config.json') -Raw |
                ConvertFrom-Json -AsHashtable
            $token = Get-CanaryAadToken $AzureCliPath `
                ([string]$template.identityResource)
            $handler = [Net.Http.HttpClientHandler]::new()
            $handler.AllowAutoRedirect = $false
            $client = [Net.Http.HttpClient]::new($handler)
            $client.Timeout = [TimeSpan]::FromSeconds(30)
            $aadGet = ${function:Invoke-CanaryAadGet}
            $readClient = $client
            $readToken = $token
            $readOrg = $Organization
            $readDeadline = [DateTime]::UtcNow.AddSeconds(90)
            $Read = {
                param($Operation, $Request)
                & $aadGet $readClient $readToken $readOrg `
                    $Operation $Request $readDeadline
            }.GetNewClosure()
        }
        if ($VerifyGraph) {
            $attempts = [pscustomobject]@{ Count = 0 }
            $reason = 'unclassified'
            $bounded = {
                param([string]$Operation, [Collections.IDictionary]$Request)
                if ($attempts.Count -ge 3 -or $Operation -cnotin @(
                        'IdentityProof', 'GraphUser', 'GraphStorageKey')) {
                    throw 'identity-diagnostic-budget'
                }
                $attempts.Count++
                return & $Read $Operation $Request
            }.GetNewClosure()
            try {
                $identity = & $bounded IdentityProof @{}
                $guid = '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$'
                if ($identity -isnot [Collections.IDictionary] -or
                    [string]$identity['id'] -cnotmatch $guid -or
                    [string]$identity['descriptor'] -cnotmatch
                        '^[A-Za-z0-9._-]{1,512}$') {
                    $reason = 'identity-fields-invalid'
                    throw 'identity-proof-stopped'
                }
                $descriptor = [string]$identity['descriptor']
                $uniqueName = [string]$identity['uniqueName']
                if ($null -ne $identity['uniqueName'] -and
                    ($uniqueName -cnotmatch '^[^@\s]+@[^@\s]+$' -or
                        $uniqueName -ine $ExpectedAccountUniqueName)) {
                    $reason = 'optional-name-mismatch'
                    throw 'identity-proof-stopped'
                }
                $user = & $bounded GraphUser @{
                    subjectDescriptor = $descriptor
                }
                if ($user -isnot [Collections.IDictionary] -or
                    [string]$user['descriptor'] -cne $descriptor -or
                    [string]$user['subjectKind'] -cne 'user' -or
                    [string]$user['principalName'] -cnotmatch
                        '^[^@\s]+@[^@\s]+$' -or
                    [string]$user['principalName'] -ine
                        $ExpectedAccountUniqueName) {
                    $reason = 'graph-user-mismatch'
                    throw 'identity-proof-stopped'
                }
                $storage = & $bounded GraphStorageKey @{
                    subjectDescriptor = $descriptor
                }
                if ($storage -isnot [Collections.IDictionary] -or
                    [string]$storage['value'] -cnotmatch $guid -or
                    [string]$storage['value'] -ine [string]$identity['id']) {
                    $reason = 'storage-key-mismatch'
                    throw 'identity-proof-stopped'
                }
                return [ordered]@{ state = 'verified'; reason = 'valid'
                    getAttempts = $attempts.Count; providerWrites = 0
                    modelToolInvocations = 0 }
            }
            catch {
                $message = [string]$_.Exception.Message
                if ($message -cmatch
                        '^bootstrap-read-inaccessible:IdentityProof:(encoded-response|non-json-media|utf8-bom|invalid-utf8|invalid-json|json-depth-over-12|identity-fields-missing|unclassified)$') {
                    $reason = $Matches[1]
                } elseif ($reason -ceq 'unclassified' -and
                    $message -cmatch
                        '^bootstrap-read-inaccessible:(IdentityProof|GraphUser|GraphStorageKey):http-[0-9]{3}$') {
                    $reason = 'http-failure'
                }
                return [ordered]@{ state = 'unknown'; reason = $reason
                    getAttempts = $attempts.Count; providerWrites = 0
                    modelToolInvocations = 0 }
            }
        }
        try {
            $identity = & $Read Identity @{}
        }
        catch {
            $message = [string]$_.Exception.Message
            $reason = if ($message -cmatch
                    '^bootstrap-read-inaccessible:Identity:(encoded-response|non-json-media|utf8-bom|invalid-utf8|invalid-json|json-depth-over-12|identity-fields-missing|unclassified)$') {
                $Matches[1]
            } elseif ($message -cmatch
                    '^bootstrap-read-inaccessible:Identity:http-[0-9]{3}$') {
                'http-failure'
            } elseif ($message -ceq 'bootstrap-read-inaccessible:Identity:send') {
                'send-failure'
            } elseif ($message -ceq 'bootstrap-read-inaccessible:Identity:read') {
                'read-failure'
            } else { 'unclassified' }
            return [ordered]@{ state = 'unknown'; reason = $reason
                getAttempts = 1; providerWrites = 0; modelToolInvocations = 0 }
        }
        $reason = 'valid'
        if ($identity -isnot [Collections.IDictionary] -or
            [string]$identity['id'] -cnotmatch
                '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$' -or
            [string]$identity['descriptor'] -cnotmatch '^\S{1,512}$' -or
            [string]$identity['uniqueName'] -cnotmatch '^[^@\s]+@[^@\s]+$') {
            $reason = 'identity-fields-invalid'
        } elseif ([string]$identity['uniqueName'] -ine $ExpectedAccountUniqueName) {
            $reason = 'principal-mismatch'
        }
        return [ordered]@{
            state = if ($reason -ceq 'valid') { 'verified' } else { 'unknown' }
            reason = $reason; getAttempts = 1
            providerWrites = 0; modelToolInvocations = 0
        }
    }
    finally { if ($client) { $client.Dispose() } }
}

function Assert-CanaryBootstrapHead {
    param([scriptblock]$Read, [string]$RepositoryId, [string]$ProjectId,
        [Collections.IDictionary]$SourceSelector)
    $request = @{ projectName = $SourceSelector.projectName; repositoryId = $RepositoryId }
    $pr = & $Read PullRequest $request
    $iterations = & $Read Iterations $request
    if ($pr -isnot [Collections.IDictionary] -or
        [string]$pr.pullRequestId -cne '17307009' -or
        [string]$pr.repository.id -ine $RepositoryId -or
        [string]$pr.repository.project.id -ine $ProjectId -or
        [string]$pr.repository.project.name -cne [string]$SourceSelector.projectName -or
        [string]$pr.status -cne 'active' -or
        [string]$pr.sourceRefName -cnotmatch
            '^refs/heads/[A-Za-z0-9._/-]{1,512}$' -or
        $iterations.value -isnot [array] -or
        $iterations.value.Count -lt 1 -or $iterations.value.Count -gt 200) {
        throw 'coverage-pr-head-unverified'
    }
    $seen = [Collections.Generic.HashSet[int]]::new()
    foreach ($iteration in $iterations.value) {
        $id = 0
        if ($iteration -isnot [Collections.IDictionary] -or
            -not [int]::TryParse([string]$iteration.id, [ref]$id) -or
            $id -lt 1 -or -not $seen.Add($id) -or
            [string]$iteration.sourceRefCommit.commitId -cnotmatch
                '^[a-fA-F0-9]{40}$') {
            throw 'coverage-pr-head-unverified'
        }
    }
    $latest = @($iterations.value | Sort-Object { [int]$_.id } |
        Select-Object -Last 1)[0]
    if ([string]$pr.lastMergeSourceCommit.commitId -ine $script:CoverageCommit -or
        [string]$latest.sourceRefCommit.commitId -ine $script:CoverageCommit -or
        [string]$latest.id -cnotmatch '^[1-9][0-9]*$') {
        throw 'coverage-pr-head-unverified'
    }
    $refs = & $Read Ref (@{ projectName = $SourceSelector.projectName
            repositoryId = $RepositoryId; sourceRef = $pr.sourceRefName })
    $matched = @($refs.value | Where-Object name -CEQ $pr.sourceRefName)
    if ($refs.value -isnot [array] -or $refs.value.Count -gt 100 -or
        $matched.Count -ne 1 -or
        [string]$matched[0].objectId -ine $script:CoverageCommit) {
        throw 'coverage-pr-head-unverified'
    }
}

function Read-CanaryVerifiedDocument {
    param([scriptblock]$Read, [string]$RepositoryId, [string]$Revision,
        [Collections.IDictionary]$SourceSelector)
    $request = @{ projectName = $SourceSelector.projectName; repositoryId = $RepositoryId
        path = $script:DocumentPath; commit = $Revision }
    $item = & $Read Item $request
    if ($item -isnot [Collections.IDictionary] -or
        [string]$item.path -cne $script:DocumentPath -or
        [string]$item.objectId -cnotmatch '^[a-fA-F0-9]{40}$' -or
        [string]$item.gitObjectType -cne 'blob' -or
        $item['isFolder'] -eq $true -or $item['isSymLink'] -eq $true) {
        throw 'bootstrap-blob-unverified'
    }
    $raw = & $Read RawItem $request
    if ($raw -isnot [Collections.IDictionary] -or
        $raw.bytes -isnot [byte[]] -or $raw.bytes.Length -gt 262144) {
        throw 'bootstrap-blob-unverified'
    }
    $bytes = [byte[]]$raw.bytes
    $header = [Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
    $oid = [Convert]::ToHexString(
        [Security.Cryptography.SHA1]::HashData(
            [byte[]]($header + $bytes))).ToLowerInvariant()
    if ($oid -ine [string]$item.objectId) {
        throw 'bootstrap-blob-unverified'
    }
    try {
        return @{ text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
            blobId = $oid }
    }
    catch { throw 'bootstrap-blob-unverified' }
}

function Invoke-PrivateCanaryBootstrap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$RepositoryName,
        [Parameter(Mandatory)][string]$ExpectedAccountUniqueName,
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [string]$AzureCliPath = 'az',
        [Collections.IDictionary]$SourceSelector,
        [string]$SourceSelectorKey,
        [Collections.IDictionary]$MergedPinEnvelope,
        [string]$MergedPinKey,
        [scriptblock]$Read,
        [ValidateSet('FourRule', 'CoverageOnly')][string]$Mode = 'FourRule',
        [switch]$Run
    )
    if ($Mode -ceq 'CoverageOnly') {
        return Invoke-PrivateCoverageCanaryBootstrap @PSBoundParameters
    }
    if ($Organization -cnotmatch '^[A-Za-z0-9_-]{1,128}$' -or
        $ProjectName -cnotmatch '^[\w .-]{1,128}$' -or
        $ProjectName -in @('.', '..') -or
        $RepositoryName -cnotmatch '^[A-Za-z0-9._-]{1,128}$' -or
        $RepositoryName -in @('.', '..') -or
        $ExpectedAccountUniqueName -cnotmatch '^[^@\s]+@[^@\s]+$' -or
        -not [IO.Path]::IsPathFullyQualified($StateRoot) -or
        -not [IO.Path]::IsPathFullyQualified($RepositoryRoot) -or
        (Test-AgentPathWithin $StateRoot $RepositoryRoot)) {
        throw 'bootstrap-input-invalid'
    }
    if (Test-Path -LiteralPath $StateRoot) {
        throw 'canary-state-root-must-be-new'
    }
    if (-not $Run) {
        return [ordered]@{ state = 'disabled'; providerReads = 0
            providerWrites = 0; signed = $false }
    }
    [void](Assert-CanarySourceSelector $SourceSelector $SourceSelectorKey $Organization)
    $mergedPin = Assert-CanaryReviewedMergedPin $MergedPinEnvelope `
        $MergedPinKey $SourceSelector
    if (-not $script:OwnerSourceReviewedInApprovedRepository) {
        throw 'owner-source-provenance-unreviewed'
    }
    $client = $null
    $created = $false
    $root = $null
    try {
        if (-not $Read) {
            $template = Get-Content -LiteralPath (Join-Path $RepositoryRoot `
                    'samples\active-pr-intake.config.json') -Raw |
                ConvertFrom-Json -AsHashtable
            $token = Get-CanaryAadToken $AzureCliPath `
                ([string]$template.identityResource)
            $handler = [Net.Http.HttpClientHandler]::new()
            $handler.AllowAutoRedirect = $false
            $client = [Net.Http.HttpClient]::new($handler)
            $client.Timeout = [TimeSpan]::FromSeconds(120)
            $readOrg = $Organization
            $readToken = $token
            $readClient = $client
            $readDeadline = [DateTime]::UtcNow.AddSeconds(120)
            $aadGet = ${function:Invoke-CanaryAadGet}
            $Read = {
                param($Operation, $Request)
                & $aadGet $readClient $readToken $readOrg `
                    $Operation $Request $readDeadline
            }.GetNewClosure()
        }
        $readBudget = @{ count = 0 }
        $bounded = {
            param($Operation, $Request)
            if ($readBudget.count -ge 120) { throw 'bootstrap-read-budget' }
            $readBudget.count++
            $result = & $Read $Operation $Request
            if ($result -isnot [Collections.IDictionary]) {
                throw 'bootstrap-read-inaccessible'
            }
            return $result
        }.GetNewClosure()
        $identity = Assert-CanaryAccountProof $bounded $ExpectedAccountUniqueName
        $project = & $bounded Project @{ projectName = $ProjectName }
        $repository = & $bounded Repository @{
            projectName = $ProjectName; repositoryName = $RepositoryName }
        $engineering = & $bounded Project @{
            projectName = $SourceSelector.projectName }
        $enghub = & $bounded Repository @{
            projectName = $SourceSelector.projectName
            repositoryName = $SourceSelector.repositoryName }
        $guid = '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$'
        if ([string]$project.id -cnotmatch $guid -or
            [string]$project.name -cne $ProjectName -or
            [string]$repository.id -cnotmatch $guid -or
            [string]$repository.name -cne $RepositoryName -or
            [string]$repository.project.id -ine [string]$project.id -or
            [string]$repository.project.name -cne $ProjectName -or
            [string]$engineering.id -cnotmatch $guid -or
            [string]$engineering.name -cne [string]$SourceSelector.projectName -or
            [string]$enghub.id -cnotmatch $guid -or
            [string]$enghub.name -cne [string]$SourceSelector.repositoryName -or
            [string]$enghub.project.id -ine [string]$engineering.id -or
            [string]$enghub.project.name -cne [string]$SourceSelector.projectName) {
            throw 'bootstrap-repository-mismatch'
        }
        $engId = ([string]$enghub.id).ToLowerInvariant()
        $proof = Assert-CanaryMergedMasterProof $bounded $engId `
            ([string]$engineering.id) $mergedPin $SourceSelector
        Assert-CanaryMergedHistory $bounded $engId $proof.masterCommit `
            $script:OwnerCommit $SourceSelector
        $ownerSource = Read-CanaryVerifiedDocument $bounded $engId `
            $script:OwnerCommit $SourceSelector
        $currentOwner = Read-CanaryVerifiedDocument $bounded $engId `
            $proof.masterCommit $SourceSelector
        $ownerSection = Get-CanarySection $ownerSource.text '## Claim ownership'
        $namedSection = Get-CanaryRawSection $ownerSource.text `
            '## Named parameters for Assert'
        $currentOwnerSection = Get-CanarySection $currentOwner.text '## Claim ownership'
        $currentNamedSection = Get-CanaryRawSection $currentOwner.text `
            '## Named parameters for Assert'
        if ((Get-CanaryTextHash $ownerSection) -cne $script:OwnerHash -or
            $ownerSection -cne $currentOwnerSection -or
            (Get-CanaryTextHash $namedSection) -cne $script:NamedSectionHash -or
            $namedSection -cne $currentNamedSection -or
            [Text.Encoding]::UTF8.GetByteCount($namedSection) -ne
                $script:NamedSectionLength) {
            throw 'bootstrap-section-mismatch'
        }
        $declarations = $proof.declarations
        [void](Assert-CanaryMergedMasterHead $bounded $engId `
            ([string]$engineering.id) $mergedPin `
            $proof.masterCommit $SourceSelector)
        $finalIdentity = Assert-CanaryAccountProof $bounded $ExpectedAccountUniqueName
        Assert-CanaryAccountBinding $finalIdentity $identity
        $policyPath = 'src/DevPilot.OwnerCapability/Policy/named-areequal-arguments.v1.txt'
        $localPath = Join-Path $RepositoryRoot (
            $policyPath -replace '/', [IO.Path]::DirectorySeparatorChar)
        $local = [IO.File]::ReadAllBytes($localPath)
        $localCommit = Get-CanaryGitValue $RepositoryRoot @('rev-parse', 'HEAD')
        if ($local.Length -gt 65536 -or
            (Get-CanaryGitValue $RepositoryRoot @(
                    'rev-parse', "${localCommit}:$policyPath")) -cne
            (Get-CanaryGitValue $RepositoryRoot @('hash-object', '--', $policyPath)) -or
            (Get-CanaryGitValue $RepositoryRoot @('rev-parse', 'HEAD')) -cne
                $localCommit) {
            throw 'local-rule-source-unavailable'
        }
        $localRepository = Get-CanaryGitRepository $RepositoryRoot
        $providerConfig = [ordered]@{
            provider = 'AzureDevOps'
            repository = [ordered]@{
                organization = $Organization; project = $ProjectName
                name = $RepositoryName
                id = ([string]$repository.id).ToLowerInvariant()
            }
            projectId = ([string]$project.id).ToLowerInvariant()
            expectedAccount = [ordered]@{
                id = $identity.id; descriptor = $identity.descriptor }
        }
        $engSource = [ordered]@{
            organization = $Organization
            projectName = $SourceSelector.projectName
            repositoryName = $SourceSelector.repositoryName
            repositoryId = $engId; path = $script:DocumentPath
        }
        $owner = [ordered]@{} + $engSource
        $owner.approved = $true
        $owner.commit = $script:OwnerCommit
        $owner.section = '## Claim ownership'
        $owner.sectionHash = 'v1:sha256:' + $script:OwnerHash
        $owner.blobId = $ownerSource.blobId
        $owner.sectionLength = [Text.Encoding]::UTF8.GetByteCount($ownerSection)
        $owner.declarationDigest = 'v1:sha256:' + (Get-CanaryTextHash (
                ConvertTo-AgentCanonicalJson -InputObject ([ordered]@{
                        ruleId = 'bpm-test-ownership@1'; repositoryId = $engId
                        commit = $script:OwnerCommit; path = $script:DocumentPath
                        sectionHash = $owner.sectionHash
                        sectionLength = $owner.sectionLength
                    })))
        $namedSectionSource = [ordered]@{} + $engSource
        $namedSectionSource.approved = $true
        $namedSectionSource.commit = $script:OwnerCommit
        $namedSectionSource.section = '## Named parameters for Assert'
        $namedSectionSource.sectionHash = 'v1:sha256:' + $script:NamedSectionHash
        $namedSectionSource.blobId = $ownerSource.blobId
        $namedSectionSource.sectionLength = $script:NamedSectionLength
        $rules = [ordered]@{}
        for ($i = 0; $i -lt 2; $i++) {
            $source = [ordered]@{} + $engSource
            $source.approved = $true
            $source.ruleId = $declarations[$i].ruleId
            $source.commit = $proof.mergeCommit
            $source.provenance = 'reviewed-merged-master-read-only'
            $source.reviewedPullRequestId = 17307009
            $source.reviewedHead = $script:CoverageCommit
            $source.mergeCommit = $proof.mergeCommit
            $source.masterCommit = $proof.masterCommit
            $source.documentHash = 'v1:sha256:' + $mergedPin.documentHash
            $source.documentLength = $mergedPin.documentLength
            $source.blobId = $proof.document.blobId
            $source.section = $declarations[$i].section
            $source.sectionHash = $declarations[$i].sectionHash
            $source.policyLine = $declarations[$i].policyLine
            $source.policyLineHash = $declarations[$i].policyLineHash
            $source.declarationDigest = $declarations[$i].declarationDigest
            $rules[$declarations[$i].ruleId] = $source
        }
        $rules['bpm-test-ownership@1'] = $owner
        $namedRule = [ordered]@{
            approved = $true; provenance = 'repository-local-commit'
            ruleRepository = $localRepository
            commit = $localCommit; path = $policyPath
            policyHash = 'v1:sha256:' + (Get-CanaryHash $local)
            capabilityDigest = 'v1:sha256:' +
                (Get-CanaryTextHash 'named-areequal-arguments-capability-v1')
            namedSectionHash = 'v1:sha256:' + $script:NamedSectionHash
        }
        $namedRule.declarationDigest = 'v1:sha256:' + (Get-CanaryTextHash (
                ConvertTo-AgentCanonicalJson -InputObject ([ordered]@{
                        ruleId = 'bpm-named-areequal-arguments@1'
                        ruleRepository = $namedRule.ruleRepository
                        commit = $localCommit; path = $policyPath
                        policyHash = $namedRule.policyHash
                        namedSectionHash = $namedRule.namedSectionHash
                        capabilityDigest = $namedRule.capabilityDigest
                    })))
        $rules['bpm-named-areequal-arguments@1'] = $namedRule
        $manifest = [ordered]@{
            schemaVersion = 6; kind = 'private-merged-master-canary-sources'
            sourceAuthority = 'merged-master-verified-read-only'
            accountProofDigest = 'v1:sha256:' + (Get-CanaryTextHash (
                ConvertTo-AgentCanonicalJson -InputObject $providerConfig.expectedAccount))
            verifiedUtc = [DateTime]::UtcNow.ToString('o')
            namedSection = $namedSectionSource
            rules = $rules
        }
        $root = Resolve-AgentTrustedRoot -Path $StateRoot -Kind durable-state `
            -RepositoryRoot $RepositoryRoot -Create -CreatedByCaller ([ref]$created)
        if (-not $created) { throw 'canary-state-root-must-be-new' }
        foreach ($entry in @(
                @{ name = 'provider-config.json'; value = $providerConfig },
                @{ name = 'approved-sources.json'; value = $manifest })) {
            $file = Join-Path $root $entry.name
            Write-CanaryPrivateFile $file ([Text.Encoding]::UTF8.GetBytes(
                    (ConvertTo-Json -InputObject $entry.value -Depth 16)))
            [void](Assert-AgentTrustedFile -Path $file -AllowedRoot $root -Private)
        }
        return [ordered]@{
            state = 'prepared-read-only'; signed = $false
            canaryExecuted = $false; providerReads = $readBudget.count
            providerWrites = 0
            ruleCount = 4; mergedRuleCount = 2
            documentHash = 'v1:sha256:' + $mergedPin.documentHash
            localCommit = $localCommit
        }
    }
    catch {
        $failure = $_
        if ($created -and $root -and (Test-Path -LiteralPath $root)) {
            try { Remove-Item -LiteralPath $root -Recurse -Force }
            catch { throw 'canary-private-state-cleanup-failed' }
        }
        throw $failure
    }
    finally { if ($client) { $client.Dispose() } }
}

function Invoke-PrivateCoverageCanaryBootstrap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$RepositoryName,
        [Parameter(Mandatory)][string]$ExpectedAccountUniqueName,
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [string]$AzureCliPath = 'az',
        [Collections.IDictionary]$SourceSelector,
        [string]$SourceSelectorKey,
        [Collections.IDictionary]$MergedPinEnvelope,
        [string]$MergedPinKey,
        [scriptblock]$Read,
        [ValidateSet('FourRule', 'CoverageOnly')][string]$Mode = 'CoverageOnly',
        [switch]$Run
    )
    if (-not $Run) {
        return @{ state = 'disabled'; signed = $false
            providerReads = 0; providerWrites = 0 }
    }
    if ($Mode -cne 'CoverageOnly' -or
        $Organization -cnotmatch '^[A-Za-z0-9_-]{1,128}$' -or
        $ProjectName -cnotmatch '^[\w .-]{1,128}$' -or
        $ProjectName -in @('.', '..') -or
        $RepositoryName -cnotmatch '^[A-Za-z0-9._-]{1,128}$' -or
        $RepositoryName -in @('.', '..') -or
        $ExpectedAccountUniqueName -cnotmatch '^[^@\s]+@[^@\s]+$' -or
        -not [IO.Path]::IsPathFullyQualified($StateRoot) -or
        -not [IO.Path]::IsPathFullyQualified($RepositoryRoot) -or
        (Test-AgentPathWithin $StateRoot $RepositoryRoot) -or
        (Test-AgentPathWithin $RepositoryRoot $StateRoot) -or
        (Test-Path -LiteralPath $StateRoot)) {
        throw 'coverage-bootstrap-input-invalid'
    }
    [void](Assert-CanarySourceSelector $SourceSelector $SourceSelectorKey $Organization)
    $pin = Assert-CanaryReviewedMergedPin $MergedPinEnvelope `
        $MergedPinKey $SourceSelector
    if (-not $Read) {
        $ExpectedAccountUniqueName = Get-CanaryWorkAccountUpn $AzureCliPath
    }
    $session = $null
    try {
        if (-not $Read) {
            $session = New-PrivateCanaryBearerSession $RepositoryRoot $AzureCliPath
            $deadline = [DateTime]::UtcNow.AddSeconds(120)
            $aadGet = ${function:Invoke-CanaryAadGet}
            $Read = {
                param($Operation, $Request)
                & $aadGet $session.client $session.token $Organization `
                    $Operation $Request $deadline
            }.GetNewClosure()
        }
        $budget = @{ count = 0 }
        $bounded = {
            param($Operation, $Request)
            if ($budget.count -ge 120 -or $Operation -cnotin @(
                    'IdentityProof', 'GraphUser', 'GraphStorageKey',
                    'Project', 'Repository', 'PullRequest', 'Iterations',
                    'Ref', 'Commit', 'Item', 'RawItem')) {
                throw 'coverage-bootstrap-read-budget'
            }
            $budget.count++
            $answer = & $Read $Operation $Request
            if ($answer -isnot [Collections.IDictionary]) {
                throw 'coverage-bootstrap-read-inaccessible'
            }
            return $answer
        }.GetNewClosure()
        $identity = Assert-CanaryAccountProof $bounded $ExpectedAccountUniqueName
        $project = & $bounded Project @{ projectName = $ProjectName }
        $repository = & $bounded Repository @{
            projectName = $ProjectName; repositoryName = $RepositoryName }
        $sourceProject = & $bounded Project @{
            projectName = $SourceSelector.projectName }
        $sourceRepository = & $bounded Repository @{
            projectName = $SourceSelector.projectName
            repositoryName = $SourceSelector.repositoryName }
        $guid = '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$'
        if ([string]$project.id -cnotmatch $guid -or
            [string]$project.name -cne $ProjectName -or
            [string]$repository.id -cnotmatch $guid -or
            [string]$repository.name -cne $RepositoryName -or
            [string]$repository.project.id -ine [string]$project.id -or
            [string]$repository.project.name -cne $ProjectName -or
            [string]$sourceProject.id -cnotmatch $guid -or
            [string]$sourceProject.name -cne [string]$SourceSelector.projectName -or
            [string]$sourceRepository.id -cnotmatch $guid -or
            [string]$sourceRepository.name -cne [string]$SourceSelector.repositoryName -or
            [string]$sourceRepository.project.id -ine [string]$sourceProject.id -or
            [string]$sourceRepository.project.name -cne
                [string]$SourceSelector.projectName) {
            throw 'coverage-bootstrap-repository-mismatch'
        }
        $sourceId = ([string]$sourceRepository.id).ToLowerInvariant()
        $proof = Assert-CanaryMergedMasterProof $bounded $sourceId `
            ([string]$sourceProject.id) $pin $SourceSelector
        [void](Assert-CanaryMergedMasterHead $bounded $sourceId `
                ([string]$sourceProject.id) $pin $proof.masterCommit `
                $SourceSelector)
        Assert-CanaryAccountBinding `
            (Assert-CanaryAccountProof $bounded $ExpectedAccountUniqueName) $identity
        $providerConfig = [ordered]@{
            provider = 'AzureDevOps'
            repository = [ordered]@{
                organization = $Organization; project = $ProjectName
                name = $RepositoryName
                id = ([string]$repository.id).ToLowerInvariant()
            }
            projectId = ([string]$project.id).ToLowerInvariant()
            expectedAccount = [ordered]@{
                id = $identity.id; descriptor = $identity.descriptor }
        }
        $rules = [ordered]@{}
        foreach ($declaration in $proof.declarations) {
            $rules[$declaration.ruleId] = [ordered]@{
                approved = $true
                ruleId = $declaration.ruleId
                organization = $Organization
                projectName = $SourceSelector.projectName
                repositoryName = $SourceSelector.repositoryName
                repositoryId = $sourceId
                path = $script:DocumentPath
                commit = $proof.mergeCommit
                provenance = 'reviewed-merged-master-read-only'
                reviewedPullRequestId = 17307009
                reviewedHead = $script:CoverageCommit
                mergeCommit = $proof.mergeCommit
                masterCommit = $proof.masterCommit
                documentHash = 'v1:sha256:' + $pin.documentHash
                documentLength = $pin.documentLength
                blobId = $proof.document.blobId
                section = $declaration.section
                sectionHash = $declaration.sectionHash
                policyLine = $declaration.policyLine
                policyLineHash = $declaration.policyLineHash
                declarationDigest = $declaration.declarationDigest
            }
        }
        $receipt = [ordered]@{
            schemaVersion = 7
            kind = 'private-coverage-only-merged-sources'
            mode = 'coverage-only'
            sourceAuthority = 'merged-master-verified-read-only'
            accountProofDigest = 'v1:sha256:' + (Get-CanaryTextHash (
                    ConvertTo-AgentCanonicalJson $providerConfig.expectedAccount))
            verifiedUtc = [DateTime]::UtcNow.ToString('o')
            rules = $rules
        }
        $created = $false
        $root = $null
        try {
            $root = Resolve-AgentTrustedRoot -Path $StateRoot `
                -Kind durable-state -RepositoryRoot $RepositoryRoot `
                -Create -CreatedByCaller ([ref]$created)
            if (-not $created) { throw 'coverage-state-root-must-be-new' }
            foreach ($entry in @(
                    @{ name = 'provider-config.json'; value = $providerConfig },
                    @{ name = 'approved-sources.json'; value = $receipt })) {
                $file = Join-Path $root $entry.name
                Write-CanaryPrivateFile $file ([Text.Encoding]::UTF8.GetBytes(
                        (ConvertTo-Json -InputObject $entry.value -Depth 16)))
                [void](Assert-AgentTrustedFile -Path $file -AllowedRoot $root -Private)
            }
        }
        catch {
            if ($created -and $root) {
                Remove-AgentContainedDirectory -Path $root `
                    -AllowedRoot (Split-Path $root -Parent) `
                    -LeafPattern ('^' + [regex]::Escape(
                            (Split-Path $root -Leaf)) + '$')
            }
            throw
        }
        return @{ state = 'coverage-sources-prepared-read-only'
            ruleCount = 2; signed = $false; providerReads = $budget.count
            providerWrites = 0; writerEligible = $false }
    }
    finally { if ($session) { $session.client.Dispose() } }
}

function New-VerifiedCoverageCanaryRuleRegistry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$ProviderConfig,
        [Parameter(Mandatory)][Collections.IDictionary]$ApprovedSources,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [scriptblock]$Read,
        [string]$ExpectedAccountUniqueName,
        [Collections.IDictionary]$SourceSelector,
        [string]$SourceSelectorKey,
        [Collections.IDictionary]$MergedPinEnvelope,
        [string]$MergedPinKey,
        [ValidateSet('FourRule', 'CoverageOnly')][string]$Mode = 'CoverageOnly',
        [switch]$Run
    )
    if (-not $Run) {
        return @{ state = 'disabled'; providerReads = 0; providerWrites = 0
            evaluated = $false; writerEligible = $false }
    }
    if ($Mode -cne 'CoverageOnly' -or -not $Read -or
        $ExpectedAccountUniqueName -cnotmatch '^[^@\s]+@[^@\s]+$' -or
        -not [IO.Path]::IsPathFullyQualified($RepositoryRoot) -or
        $ProviderConfig.provider -cne 'AzureDevOps' -or
        $ProviderConfig.Contains('operator') -or
        $ProviderConfig.repository -isnot [Collections.IDictionary] -or
        $ProviderConfig.expectedAccount -isnot [Collections.IDictionary] -or
        $ProviderConfig.expectedAccount.Count -ne 2 -or
        [string]$ProviderConfig.expectedAccount.id -cnotmatch
            '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$' -or
        [string]$ProviderConfig.expectedAccount.descriptor -cnotmatch
            '^[A-Za-z0-9._-]{1,512}$' -or
        [string]$ProviderConfig.repository.organization -cnotmatch
            '^[A-Za-z0-9_-]{1,128}$' -or
        [string]$ProviderConfig.repository.project -cnotmatch
            '^[\w .-]{1,128}$' -or
        [string]$ProviderConfig.repository.name -cnotmatch
            '^[A-Za-z0-9._-]{1,128}$' -or
        [string]$ProviderConfig.repository.id -cnotmatch
            '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$' -or
        [string]$ProviderConfig.projectId -cnotmatch
            '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$' -or
        $ApprovedSources.schemaVersion -ne 7 -or
        $ApprovedSources.kind -cne 'private-coverage-only-merged-sources' -or
        $ApprovedSources.mode -cne 'coverage-only' -or
        $ApprovedSources.sourceAuthority -cne
            'merged-master-verified-read-only' -or
        $ApprovedSources.accountProofDigest -cne ('v1:sha256:' +
            (Get-CanaryTextHash (ConvertTo-AgentCanonicalJson `
                $ProviderConfig.expectedAccount))) -or
        $ApprovedSources.rules -isnot [Collections.IDictionary] -or
        $ApprovedSources.rules.Count -ne 2) {
        throw 'coverage-receipt-invalid'
    }
    [void](Assert-CanarySourceSelector $SourceSelector $SourceSelectorKey `
            ([string]$ProviderConfig.repository.organization))
    $pin = Assert-CanaryReviewedMergedPin $MergedPinEnvelope `
        $MergedPinKey $SourceSelector
    $budget = @{ count = 0 }
    $bounded = {
        param($Operation, $Request)
        if ($budget.count -ge 120 -or $Operation -cnotin @(
                'IdentityProof', 'GraphUser', 'GraphStorageKey',
                'Project', 'Repository', 'PullRequest', 'Iterations',
                'Ref', 'Commit', 'Item', 'RawItem')) {
            throw 'coverage-registry-read-budget'
        }
        $budget.count++
        $answer = & $Read $Operation $Request
        if ($answer -isnot [Collections.IDictionary]) {
            throw 'coverage-registry-read-inaccessible'
        }
        return $answer
    }.GetNewClosure()
    $identity = Assert-CanaryAccountProof $bounded $ExpectedAccountUniqueName
    Assert-CanaryAccountBinding $identity $ProviderConfig.expectedAccount
    $projectName = [string]$ProviderConfig.repository.project
    $project = & $bounded Project @{ projectName = $projectName }
    $repository = & $bounded Repository @{
        projectName = $projectName
        repositoryName = $ProviderConfig.repository.name }
    $sourceProject = & $bounded Project @{
        projectName = $SourceSelector.projectName }
    $sourceRepository = & $bounded Repository @{
        projectName = $SourceSelector.projectName
        repositoryName = $SourceSelector.repositoryName }
    $guid = '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$'
    if ([string]$project.id -ine [string]$ProviderConfig.projectId -or
        [string]$project.name -cne $projectName -or
        [string]$repository.id -ine [string]$ProviderConfig.repository.id -or
        [string]$repository.name -cne [string]$ProviderConfig.repository.name -or
        [string]$repository.project.id -ine [string]$project.id -or
        [string]$repository.project.name -cne $projectName -or
        [string]$sourceProject.id -cnotmatch $guid -or
        [string]$sourceProject.name -cne [string]$SourceSelector.projectName -or
        [string]$sourceRepository.id -cnotmatch $guid -or
        [string]$sourceRepository.name -cne
            [string]$SourceSelector.repositoryName -or
        [string]$sourceRepository.project.id -ine [string]$sourceProject.id -or
        [string]$sourceRepository.project.name -cne
            [string]$SourceSelector.projectName) {
        throw 'coverage-registry-identity-drift'
    }
    $sourceId = ([string]$sourceRepository.id).ToLowerInvariant()
    $proof = Assert-CanaryMergedMasterProof $bounded $sourceId `
        ([string]$sourceProject.id) $pin $SourceSelector
    $registryRules = [ordered]@{}
    $recordedMaster = $null
    foreach ($declaration in $proof.declarations) {
        $source = $ApprovedSources.rules[$declaration.ruleId]
        Assert-CanarySource $source $script:DocumentPath $proof.mergeCommit
        if ($source.ruleId -cne $declaration.ruleId -or
            $source.organization -cne
                [string]$ProviderConfig.repository.organization -or
            $source.projectName -cne [string]$SourceSelector.projectName -or
            $source.repositoryName -cne [string]$SourceSelector.repositoryName -or
            [string]$source.repositoryId -ine $sourceId -or
            $source.provenance -cne 'reviewed-merged-master-read-only' -or
            $source.reviewedPullRequestId -ne 17307009 -or
            $source.reviewedHead -cne $script:CoverageCommit -or
            $source.mergeCommit -cne $proof.mergeCommit -or
            [string]$source.masterCommit -cnotmatch '^[a-f0-9]{40}$' -or
            ($null -ne $recordedMaster -and
                $source.masterCommit -cne $recordedMaster) -or
            $source.documentHash -cne ('v1:sha256:' + $pin.documentHash) -or
            $source.documentLength -ne $pin.documentLength -or
            $source.blobId -cne $proof.document.blobId -or
            $source.section -cne $declaration.section -or
            $source.sectionHash -cne $declaration.sectionHash -or
            $source.policyLine -ne $declaration.policyLine -or
            $source.policyLineHash -cne $declaration.policyLineHash -or
            $source.declarationDigest -cne $declaration.declarationDigest) {
            throw 'coverage-receipt-drift'
        }
        $recordedMaster = [string]$source.masterCommit
        $registryRules[$declaration.ruleId] = [ordered]@{
            id = $declaration.ruleId; enabled = $false; evaluated = $false
            writerEligible = $false
            sourceAuthority = 'verified-merged-master-read-only'
            sourceCommit = $proof.mergeCommit
            sourceHash = $declaration.sectionHash
            policyLineHash = $declaration.policyLineHash
            declarationDigest = $declaration.declarationDigest
        }
    }
    if ($recordedMaster -cne $proof.masterCommit -and
        $recordedMaster -cne $proof.mergeCommit) {
        try {
            Assert-CanaryMergedHistory $bounded $sourceId $proof.masterCommit `
                $recordedMaster $SourceSelector
        }
        catch {
            if ($_.Exception.Message -ceq 'merged-master-history-unproved') {
                throw 'coverage-source-master-lineage-unproved'
            }
            throw
        }
        $recordedDocument = Read-CanaryVerifiedDocument $bounded $sourceId `
            $recordedMaster $SourceSelector
        if ($recordedDocument.blobId -cne $pin.blobId -or
            $recordedDocument.text -cne $proof.document.text) {
            throw 'coverage-source-snapshot-drift'
        }
    }
    [void](Assert-CanaryMergedMasterHead $bounded $sourceId `
            ([string]$sourceProject.id) $pin $proof.masterCommit `
            $SourceSelector)
    Assert-CanaryAccountBinding `
        (Assert-CanaryAccountProof $bounded $ExpectedAccountUniqueName) $identity
    return [ordered]@{
        schemaVersion = 7; kind = 'verified-coverage-only-canary-registry'
        mode = 'coverage-only'; state = 'verified-not-evaluated'
        sourceAuthority = 'merged-master-verified-read-only'
        currentMasterCommit = $proof.masterCommit
        receiptDigest = 'v1:sha256:' + (Get-CanaryTextHash (
                ConvertTo-AgentCanonicalJson ([ordered]@{
                        schemaVersion = $ApprovedSources.schemaVersion
                        kind = $ApprovedSources.kind
                        mode = $ApprovedSources.mode
                        sourceAuthority = $ApprovedSources.sourceAuthority
                        accountProofDigest = $ApprovedSources.accountProofDigest
                        rules = $ApprovedSources.rules
                    })))
        providerReads = $budget.count; providerWrites = 0
        evaluated = $false; writerEligible = $false
        rules = $registryRules
    }
}

function New-VerifiedCanaryRuleRegistry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$ProviderConfig,
        [Parameter(Mandatory)][Collections.IDictionary]$ApprovedSources,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [scriptblock]$Read,
        [string]$ExpectedAccountUniqueName,
        [Collections.IDictionary]$SourceSelector,
        [string]$SourceSelectorKey,
        [Collections.IDictionary]$MergedPinEnvelope,
        [string]$MergedPinKey,
        [ValidateSet('FourRule', 'CoverageOnly')][string]$Mode = 'FourRule',
        [switch]$Run
    )
    if ($Mode -ceq 'CoverageOnly') {
        return New-VerifiedCoverageCanaryRuleRegistry @PSBoundParameters
    }
    if (-not $Run) {
        return [ordered]@{ state = 'disabled'; providerReads = 0
            providerWrites = 0; evaluated = $false; writerEligible = $false }
    }
    $mergedPin = Assert-CanaryReviewedMergedPin $MergedPinEnvelope `
        $MergedPinKey $SourceSelector
    if (-not $script:OwnerSourceReviewedInApprovedRepository) {
        throw 'owner-source-provenance-unreviewed'
    }
    if (-not $Read -or
        $ExpectedAccountUniqueName -cnotmatch '^[^@\s]+@[^@\s]+$' -or
        -not [IO.Path]::IsPathFullyQualified($RepositoryRoot) -or
        $ProviderConfig.provider -cne 'AzureDevOps' -or
        $ProviderConfig.repository -isnot [Collections.IDictionary] -or
        $ProviderConfig.expectedAccount -isnot [Collections.IDictionary] -or
        [string]$ProviderConfig.repository.organization -cnotmatch '^[A-Za-z0-9_-]{1,128}$' -or
        [string]$ProviderConfig.repository.project -cnotmatch '^[\w .-]{1,128}$' -or
        [string]$ProviderConfig.repository.name -cnotmatch '^[A-Za-z0-9._-]{1,128}$' -or
        [string]$ProviderConfig.repository.id -cnotmatch
            '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$' -or
        [string]$ProviderConfig.projectId -cnotmatch
            '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$' -or
        [string]$ProviderConfig.expectedAccount.id -cnotmatch
            '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$' -or
        [string]$ProviderConfig.expectedAccount.descriptor -cnotmatch '^\S{1,512}$' -or
        $ProviderConfig.expectedAccount.Count -ne 2 -or
        -not $ProviderConfig.expectedAccount.Contains('id') -or
        -not $ProviderConfig.expectedAccount.Contains('descriptor') -or
        $ProviderConfig.Contains('operator') -or
        $ApprovedSources.schemaVersion -ne 6 -or
        $ApprovedSources.kind -cne 'private-merged-master-canary-sources' -or
        $ApprovedSources.accountProofDigest -cne ('v1:sha256:' +
            (Get-CanaryTextHash (ConvertTo-AgentCanonicalJson `
                -InputObject $ProviderConfig.expectedAccount))) -or
        $ApprovedSources.sourceAuthority -cne
            'merged-master-verified-read-only' -or
        $ApprovedSources.rules -isnot [Collections.IDictionary] -or
        $ApprovedSources.rules.Count -ne 4) {
        throw 'canary-receipt-invalid'
    }
    [void](Assert-CanarySourceSelector $SourceSelector $SourceSelectorKey `
            ([string]$ProviderConfig.repository.organization))
    $rules = $ApprovedSources.rules
    $owner = $rules['bpm-test-ownership@1']
    $namedSection = $ApprovedSources['namedSection']
    $named = $rules['bpm-named-areequal-arguments@1']
    $class = $rules['bpm-test-class-coverage@2']
    $redundant = $rules['bpm-redundant-method-coverage@2']
    $engId = [string]$owner.repositoryId
    foreach ($source in @($owner, $namedSection, $class, $redundant)) {
        $expectedCommit = if ($source -eq $class -or $source -eq $redundant) {
            $mergedPin.mergeCommit
        } else { $script:OwnerCommit }
        Assert-CanarySource $source $script:DocumentPath $expectedCommit
        if ([string]$source.organization -cne
                [string]$ProviderConfig.repository.organization -or
            [string]$source.projectName -cne
                [string]$SourceSelector.projectName -or
            [string]$source.repositoryName -cne
                [string]$SourceSelector.repositoryName -or
            [string]$source.repositoryId -cne $engId -or
            [string]$source.blobId -cnotmatch '^[a-f0-9]{40}$') {
            throw 'canary-receipt-invalid'
        }
    }
    if ($owner.section -cne '## Claim ownership' -or
        $owner.sectionHash -cne ('v1:sha256:' + $script:OwnerHash) -or
        [string]$owner.sectionLength -cnotmatch '^[1-9][0-9]{0,4}$' -or
        [int]$owner.sectionLength -gt 65536 -or
        $namedSection.section -cne '## Named parameters for Assert' -or
        $namedSection.sectionHash -cne
            ('v1:sha256:' + $script:NamedSectionHash) -or
        $namedSection.sectionLength -ne $script:NamedSectionLength -or
        $namedSection.blobId -cne $owner.blobId -or
        $owner.declarationDigest -cne ('v1:sha256:' + (Get-CanaryTextHash (
                    ConvertTo-AgentCanonicalJson -InputObject ([ordered]@{
                            ruleId = 'bpm-test-ownership@1'
                            repositoryId = $engId
                            commit = $script:OwnerCommit
                            path = $script:DocumentPath
                            sectionHash = $owner.sectionHash
                            sectionLength = $owner.sectionLength
                        }))))) {
        throw 'canary-receipt-invalid'
    }
    $readBudget = @{ count = 0 }
    $bounded = {
        param($Operation, $Request)
        if ($readBudget.count -ge 120 -or $Operation -cnotin @('IdentityProof',
                'GraphUser', 'GraphStorageKey', 'Project',
                'Repository', 'PullRequest', 'Iterations', 'Ref', 'Commit',
                'Item', 'RawItem')) {
            throw 'registry-read-budget'
        }
        $readBudget.count++
        $answer = & $Read $Operation $Request
        if ($answer -isnot [Collections.IDictionary]) {
            throw 'registry-read-inaccessible'
        }
        return $answer
    }.GetNewClosure()
    $identity = Assert-CanaryAccountProof $bounded $ExpectedAccountUniqueName
    $projectName = [string]$ProviderConfig.repository.project
    $project = & $bounded Project @{ projectName = $projectName }
    $repo = & $bounded Repository @{
        projectName = $projectName
        repositoryName = [string]$ProviderConfig.repository.name
    }
    $engineering = & $bounded Project @{
        projectName = $SourceSelector.projectName }
    $enghub = & $bounded Repository @{
        projectName = $SourceSelector.projectName
        repositoryName = $SourceSelector.repositoryName
    }
    Assert-CanaryAccountBinding $identity $ProviderConfig.expectedAccount
    if ([string]$project.id -ine [string]$ProviderConfig.projectId -or
        [string]$project.name -cne $projectName -or
        [string]$repo.id -ine [string]$ProviderConfig.repository.id -or
        [string]$repo.name -cne [string]$ProviderConfig.repository.name -or
        [string]$repo.project.id -ine [string]$project.id -or
        [string]$repo.project.name -cne $projectName -or
        [string]$engineering.id -cnotmatch
            '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$' -or
        [string]$engineering.name -cne [string]$SourceSelector.projectName -or
        [string]$enghub.id -ine $engId -or
        [string]$enghub.name -cne [string]$SourceSelector.repositoryName -or
        [string]$enghub.project.id -ine [string]$engineering.id -or
        [string]$enghub.project.name -cne [string]$SourceSelector.projectName) {
        throw 'canary-identity-drift'
    }
    $proof = Assert-CanaryMergedMasterProof $bounded $engId `
        ([string]$engineering.id) $mergedPin $SourceSelector
    Assert-CanaryMergedHistory $bounded $engId $proof.masterCommit `
        $script:OwnerCommit $SourceSelector
    $ownerSource = Read-CanaryVerifiedDocument $bounded $engId `
        $script:OwnerCommit $SourceSelector
    $currentOwner = Read-CanaryVerifiedDocument $bounded $engId `
        $proof.masterCommit $SourceSelector
    $ownerBytes = Get-CanarySection $ownerSource.text '## Claim ownership'
    $namedBytes = Get-CanaryRawSection $ownerSource.text `
        '## Named parameters for Assert'
    $currentOwnerBytes = Get-CanarySection $currentOwner.text '## Claim ownership'
    $currentNamedBytes = Get-CanaryRawSection $currentOwner.text `
        '## Named parameters for Assert'
    if ($ownerSource.blobId -cne $owner.blobId -or
        (Get-CanaryTextHash $ownerBytes) -cne $script:OwnerHash -or
        $ownerBytes -cne $currentOwnerBytes -or
        [Text.Encoding]::UTF8.GetByteCount($ownerBytes) -ne
            [int]$owner.sectionLength -or
        (Get-CanaryTextHash $namedBytes) -cne $script:NamedSectionHash -or
        $namedBytes -cne $currentNamedBytes -or
        [Text.Encoding]::UTF8.GetByteCount($namedBytes) -ne
            $script:NamedSectionLength) {
        throw 'canary-section-drift'
    }
    $declarations = $proof.declarations
    $candidateSources = @($class, $redundant)
    for ($i = 0; $i -lt 2; $i++) {
        $source = $candidateSources[$i]
        $expected = $declarations[$i]
        if ($source.ruleId -cne $expected.ruleId -or
            $source.provenance -cne 'reviewed-merged-master-read-only' -or
            $source.reviewedPullRequestId -ne 17307009 -or
            $source.reviewedHead -cne $script:CoverageCommit -or
            $source.mergeCommit -cne $proof.mergeCommit -or
            $source.masterCommit -cne $proof.masterCommit -or
            $source.documentLength -ne $mergedPin.documentLength -or
            $source.documentHash -cne
                ('v1:sha256:' + $mergedPin.documentHash) -or
            $source.blobId -cne $proof.document.blobId -or
            $source.section -cne $expected.section -or
            $source.sectionHash -cne $expected.sectionHash -or
            $source.policyLine -ne $expected.policyLine -or
            $source.policyLineHash -cne $expected.policyLineHash -or
            $source.declarationDigest -cne $expected.declarationDigest) {
            throw 'coverage-receipt-drift'
        }
    }
    [void](Assert-CanaryMergedMasterHead $bounded $engId `
        ([string]$engineering.id) $mergedPin `
        $proof.masterCommit $SourceSelector)
    $finalIdentity = Assert-CanaryAccountProof $bounded $ExpectedAccountUniqueName
    Assert-CanaryAccountBinding $finalIdentity $identity
    $path = 'src/DevPilot.OwnerCapability/Policy/named-areequal-arguments.v1.txt'
    if ($named -isnot [Collections.IDictionary] -or
        $named.approved -cne $true -or
        $named.provenance -cne 'repository-local-commit' -or
        $named.path -cne $path -or
        [string]$named.commit -cnotmatch '^[a-f0-9]{40}$' -or
        $named.ruleRepository -cne (Get-CanaryGitRepository $RepositoryRoot) -or
        $named.namedSectionHash -cne $namedSection.sectionHash -or
        $named.capabilityDigest -cne ('v1:sha256:' + (
                Get-CanaryTextHash 'named-areequal-arguments-capability-v1')) -or
        $named.policyHash -cnotmatch '^v1:sha256:[a-f0-9]{64}$') {
        throw 'named-rule-receipt-invalid'
    }
    $localPath = Join-Path $RepositoryRoot (
        $path -replace '/', [IO.Path]::DirectorySeparatorChar)
    $local = [IO.File]::ReadAllBytes($localPath)
    if ($local.Length -gt 65536 -or
        $named.policyHash -cne ('v1:sha256:' + (Get-CanaryHash $local)) -or
        (Get-CanaryGitValue $RepositoryRoot @(
                'rev-parse', "$($named.commit):$path")) -cne
        (Get-CanaryGitValue $RepositoryRoot @('hash-object', '--', $path)) -or
        $named.declarationDigest -cne ('v1:sha256:' + (Get-CanaryTextHash (
                    ConvertTo-AgentCanonicalJson -InputObject ([ordered]@{
                            ruleId = 'bpm-named-areequal-arguments@1'
                            ruleRepository = $named.ruleRepository
                            commit = $named.commit; path = $path
                            policyHash = $named.policyHash
                            namedSectionHash = $named.namedSectionHash
                            capabilityDigest = $named.capabilityDigest
                        }))))) {
        throw 'named-rule-receipt-invalid'
    }
    $registry = [ordered]@{}
    foreach ($ruleId in @('bpm-test-ownership@1',
            'bpm-test-class-coverage@2',
            'bpm-redundant-method-coverage@2',
            'bpm-named-areequal-arguments@1')) {
        $source = $rules[$ruleId]
        $registry[$ruleId] = [ordered]@{
            id = $ruleId
            enabled = $false
            evaluated = $false
            writerEligible = $false
            sourceAuthority = if ($ruleId -in @(
                    'bpm-test-class-coverage@2',
                    'bpm-redundant-method-coverage@2')) {
                'verified-merged-master-read-only'
            } elseif ($ruleId -eq 'bpm-named-areequal-arguments@1') {
                'repository-local-commit'
            } else { 'pinned-owner-section' }
            declarationDigest = [string]$source.declarationDigest
            sourceCommit = [string]$source.commit
            sourceHash = if ($ruleId -eq 'bpm-named-areequal-arguments@1') {
                [string]$source.policyHash
            } else { [string]$source.sectionHash }
        }
    }
    return [ordered]@{
        schemaVersion = 5
        kind = 'verified-read-only-canary-registry'
        state = 'verified-not-evaluated'
        sourceAuthority = 'merged-master-verified-read-only'
        receiptDigest = 'v1:sha256:' + (Get-CanaryTextHash (
                ConvertTo-AgentCanonicalJson -InputObject ([ordered]@{
                        schemaVersion = $ApprovedSources.schemaVersion
                        kind = $ApprovedSources.kind
                        sourceAuthority = $ApprovedSources.sourceAuthority
                        accountProofDigest = $ApprovedSources.accountProofDigest
                        namedSection = $namedSection
                        rules = $rules
                    })))
        verifiedUtc = [DateTime]::UtcNow.ToString('o')
        providerReads = $readBudget.count
        providerWrites = 0
        evaluated = $false
        writerEligible = $false
        owner = 'not-attempted;no-model-or-tools'
        rules = $registry
    }
}

function Invoke-PrivateCanaryRuleRegistry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$ProviderConfig,
        [Parameter(Mandatory)][Collections.IDictionary]$ApprovedSources,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [string]$AzureCliPath = 'az',
        [Collections.IDictionary]$BearerSession,
        [Collections.IDictionary]$ReadTelemetry,
        [string]$ExpectedAccountUniqueName,
        [Collections.IDictionary]$SourceSelector,
        [string]$SourceSelectorKey,
        [Collections.IDictionary]$MergedPinEnvelope,
        [string]$MergedPinKey,
        [ValidateSet('FourRule', 'CoverageOnly')][string]$Mode = 'FourRule',
        [switch]$Run
    )
    if (-not $Run) {
        return New-VerifiedCanaryRuleRegistry -ProviderConfig $ProviderConfig `
            -ApprovedSources $ApprovedSources -RepositoryRoot $RepositoryRoot `
            -Mode $Mode
    }
    $organization = [string]$ProviderConfig.repository.organization
    if ($organization -cnotmatch '^[A-Za-z0-9_-]{1,128}$') {
        throw 'canary-receipt-invalid'
    }
    [void](Assert-CanarySourceSelector $SourceSelector $SourceSelectorKey $organization)
    [void](Assert-CanaryReviewedMergedPin $MergedPinEnvelope `
            $MergedPinKey $SourceSelector)
    if (-not $BearerSession) {
        $ExpectedAccountUniqueName = Get-CanaryWorkAccountUpn $AzureCliPath
    } elseif ($ExpectedAccountUniqueName -cnotmatch '^[^@\s]+@[^@\s]+$') {
        throw 'canary-work-account-unavailable'
    }
    $owned = $null
    try {
        if ($BearerSession) {
            if ($BearerSession.client -isnot [Net.Http.HttpClient] -or
                [string]$BearerSession.token -cnotmatch
                    '^[A-Za-z0-9._~+/=-]{40,8192}$') {
                throw 'bound-transport-invalid'
            }
            $session = $BearerSession
        } else {
            $owned = New-PrivateCanaryBearerSession $RepositoryRoot $AzureCliPath
            $session = $owned
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(120)
        $aadGet = ${function:Invoke-CanaryAadGet}
        $read = {
            param($Operation, $Request)
            if ($ReadTelemetry) { $ReadTelemetry.attemptedGets++ }
            try {
                $answer = & $aadGet $session.client $session.token $organization `
                    $Operation $Request $deadline -ReadTelemetry $ReadTelemetry
                if ($ReadTelemetry) { $ReadTelemetry.completedGets++ }
                return $answer
            }
            catch {
                if ($ReadTelemetry) {
                    if ($_.Exception.Message -match '^bootstrap-read-throttled:') {
                        $ReadTelemetry.throttleEvents++
                    }
                    if ($_.Exception.Message -match ':http-(\d{3})$') {
                        $ReadTelemetry.lastHttpStatus = [int]$Matches[1]
                    }
                }
                throw
            }
        }.GetNewClosure()
        return New-VerifiedCanaryRuleRegistry -ProviderConfig $ProviderConfig `
            -ApprovedSources $ApprovedSources -RepositoryRoot $RepositoryRoot `
            -Read $read -ExpectedAccountUniqueName $ExpectedAccountUniqueName `
            -SourceSelector $SourceSelector -SourceSelectorKey $SourceSelectorKey `
            -MergedPinEnvelope $MergedPinEnvelope -MergedPinKey $MergedPinKey `
            -Mode $Mode -Run
    }
    finally { if ($owned) { $owned.client.Dispose() } }
}

function New-CanaryIntakeFailureDiagnostic {
    param([Collections.IDictionary]$Cohort, [int[]]$Selection,
        [Collections.IDictionary]$TransportTelemetry,
        [Collections.IDictionary]$ProviderCalls, [object]$RegistryReads,
        [Collections.IDictionary]$SourceTelemetry)
    $safeReasons = @('account-mismatch', 'invalid-page', 'mutable-page',
        'keyset-invalid-date', 'keyset-newer', 'keyset-unseen-equal',
        'keyset-changed-echo', 'keyset-order', 'keyset-duplicate',
        'keyset-terminal-unproved',
        'page-cursor-collision', 'canary-not-in-complete-eligible-inventory',
        'missing-page', 'page-budget', 'pr-budget', 'read-budget', 'time-budget',
        'page-inaccessible', 'provider-inaccessible', 'head-drift',
        'head-inconsistent', 'invalid-head', 'iteration-inaccessible',
        'project-identity-unknown', 'unknown-heads', 'diff-budget',
        'duplicate-list-entries-reconciled')
    $reasons = if ($Cohort) {
        @($Cohort.reasonCodes | Where-Object { $_ -cin $safeReasons } |
            Select-Object -Unique)
    } else { @() }
    $checks = [Collections.Generic.List[string]]::new()
    if ($Cohort) {
        if ($Cohort.inventory.state -cne 'complete') {
            $checks.Add('inventory-incomplete')
        }
        if ($Cohort.populationKnown -cne $true) {
            $checks.Add('population-unknown')
        }
        if ($Cohort.gapCounts.enumerationUnknown -ne 0) {
            $checks.Add('enumeration-gap')
        }
        if ($Cohort.gapCounts.duplicateEntries -ne 0) {
            $checks.Add('duplicate-entries')
        }
        if ($null -ne $Cohort.inventory.nonDraft -and
            $Cohort.inventory.nonDraft -ne $Cohort.heads.Count) {
            $checks.Add('non-draft-cardinality')
        }
        if ($null -ne $Cohort.inventory.active -and
            $Cohort.inventory.active -ne
                ($Cohort.inventory.draft + $Cohort.inventory.nonDraft)) {
            $checks.Add('active-cardinality')
        }
        if ($null -ne $Cohort.inventory.eligible -and
            $Cohort.inventory.eligible -ne
                ($Cohort.inventory.nonDraft -
                    $Cohort.inventory.excludedOtherTargets)) {
            $checks.Add('eligible-cardinality')
        }
    }
    $inventoryKnown = $Cohort -and $checks.Count -eq 0 -and
        $null -ne $Cohort.inventory.nonDraft -and
        $null -ne $Cohort.inventory.active -and
        $null -ne $Cohort.inventory.draft -and
        $null -ne $Cohort.inventory.eligible -and
        $null -ne $Cohort.inventory.excludedOtherTargets
    $selected = @($Selection | ForEach-Object {
            $id = $_
            $matches = @(if ($Cohort) {
                    $Cohort.heads | Where-Object pullRequestId -EQ $id
                })
            $head = if ($matches.Count -eq 1) { $matches[0] } else { $null }
            [ordered]@{
                pullRequestId = $id
                inventoryEligible = if ($inventoryKnown) {
                    $null -ne $head -and $head.targetRef -ceq 'refs/heads/master'
                } else { $null }
                headProof = if ($head -and
                    $head.status -cin @('pending', 'unknown', 'skipped')) {
                    [string]$head.status
                } else { 'unknown' }
                reason = if ($head -and $head.reason -cin $safeReasons) {
                    [string]$head.reason
                } elseif ($head -and $head.status -ceq 'pending') {
                    'rules-not-evaluated'
                } else { 'unavailable' }
                limitKind = if ($head -and
                    $head.reason -ceq 'diff-budget') {
                    'maxDiffCells'
                } else { $null }
                limitCount = $null
            }
        })
    if ($Cohort) {
        if (@($selected | Where-Object {
                    $_.inventoryEligible -eq $false -or
                    $_.headProof -cne 'pending'
                }).Count -gt 0) {
            $checks.Add('selected-head-or-evidence-unknown')
        }
    }
    $driftDetected = $Cohort -and (
        $Cohort.gapCounts.drift -gt 0 -or
        @($reasons | Where-Object {
                $_ -cin @('mutable-page', 'page-cursor-collision', 'head-drift')
            }).Count -gt 0)
    return [ordered]@{
        schemaVersion = 1
        kind = 'private-canary-intake-failure-diagnostic'
        state = 'blocked'
        failureCode = $null
        failedChecks = @($checks.ToArray())
        reasonCodes = $reasons
        selected = $selected
        inventory = if ($Cohort) {
            [ordered]@{
                state = if ($Cohort.inventory.state -cin @('complete', 'unknown')) {
                    [string]$Cohort.inventory.state
                } else { 'unknown' }
                populationKnown = $Cohort.populationKnown -ceq $true
                active = $Cohort.inventory.active
                nonDraft = $Cohort.inventory.nonDraft
                draft = $Cohort.inventory.draft
                eligible = $Cohort.inventory.eligible
                headCount = $Cohort.heads.Count
                enumerationUnknown = [int]$Cohort.gapCounts.enumerationUnknown
                duplicateEntries = [int]$Cohort.gapCounts.duplicateEntries
                drift = [int]$Cohort.gapCounts.drift
                firstPassPages = [int]$Cohort.pages.first
                secondPassPages = [int]$Cohort.pages.second
                intakeReportedReads = $Cohort.readCount
            }
        } else { $null }
        provider = [ordered]@{
            attemptedCalls = [int]$ProviderCalls.attempted
            completedCalls = [int]$ProviderCalls.completed
            attemptedGets = if ($TransportTelemetry) {
                [int]$TransportTelemetry.attemptedGets
            } else { $null }
            completedGets = if ($TransportTelemetry) {
                [int]$TransportTelemetry.completedGets
            } else { $null }
            sourceRegistryCompletedGets = $RegistryReads
            sourceAttemptedGets = if ($SourceTelemetry) {
                [int]$SourceTelemetry.attemptedGets
            } else { $null }
            sourceCompletedGets = if ($SourceTelemetry) {
                [int]$SourceTelemetry.completedGets
            } else { $null }
            totalAttemptedGets = if ($SourceTelemetry -and
                ($TransportTelemetry -or $ProviderCalls.attempted -eq 0)) {
                [int]$SourceTelemetry.attemptedGets +
                    $(if ($TransportTelemetry) {
                        [int]$TransportTelemetry.attemptedGets
                    } else { 0 })
            } else { $null }
            totalCompletedGets = if ($SourceTelemetry -and
                ($TransportTelemetry -or $ProviderCalls.attempted -eq 0)) {
                [int]$SourceTelemetry.completedGets +
                    $(if ($TransportTelemetry) {
                        [int]$TransportTelemetry.completedGets
                    } else { 0 })
            } else { $null }
            throttleEvents = if ($SourceTelemetry -and $TransportTelemetry) {
                [int]$SourceTelemetry.throttleEvents +
                    [int]$TransportTelemetry.throttleEvents
            } elseif ($TransportTelemetry) {
                [int]$TransportTelemetry.throttleEvents
            } elseif ($SourceTelemetry) {
                [int]$SourceTelemetry.throttleEvents
            } else { $null }
            lastHttpStatus = if ($TransportTelemetry -and
                $null -ne $TransportTelemetry.lastHttpStatus) {
                $TransportTelemetry.lastHttpStatus
            } elseif ($SourceTelemetry) {
                $SourceTelemetry.lastHttpStatus
            } else { $null }
        }
        throttleState = if (($TransportTelemetry -and
                $TransportTelemetry.throttleEvents -gt 0) -or
            ($SourceTelemetry -and $SourceTelemetry.throttleEvents -gt 0)) {
            'detected'
        } elseif ($TransportTelemetry -and $SourceTelemetry) {
            'not-observed'
        } else { 'unknown' }
        driftState = if ($driftDetected) {
            'detected'
        } elseif ($Cohort -and $Cohort.inventory.state -ceq 'complete') {
            'not-observed'
        } else { 'unknown' }
        privateIntakePersisted = $null
        signed = $false
        evaluated = $false
        writerEligible = $false
        providerWrites = 0
    }
}

function Invoke-PrivateCanarySignedIntake {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$ProviderConfig,
        [Parameter(Mandatory)][Collections.IDictionary]$ApprovedSources,
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][int[]]$CanaryPullRequestIds,
        [string]$AzureCliPath = 'az',
        [string]$ExpectedAccountUniqueName,
        [Collections.IDictionary]$SourceSelector,
        [string]$SourceSelectorKey,
        [Collections.IDictionary]$MergedPinEnvelope,
        [string]$MergedPinKey,
        [scriptblock]$Read,
        [scriptblock]$Provider,
        [ValidateSet('FourRule', 'CoverageOnly')][string]$Mode = 'FourRule',
        [ref]$FailureDiagnostic,
        [switch]$Run
    )
    if ($CanaryPullRequestIds.Count -lt 1 -or $CanaryPullRequestIds.Count -gt 2 -or
        @($CanaryPullRequestIds | Where-Object { $_ -lt 1 }).Count -gt 0 -or
        @($CanaryPullRequestIds | Select-Object -Unique).Count -ne
            $CanaryPullRequestIds.Count) { throw 'invalid-canary-selection' }
    if (-not [IO.Path]::IsPathFullyQualified($StateRoot) -or
        -not [IO.Path]::IsPathFullyQualified($RepositoryRoot) -or
        (Test-AgentPathWithin $StateRoot $RepositoryRoot) -or
        (Test-AgentPathWithin $RepositoryRoot $StateRoot)) {
        throw 'state-root-must-be-external'
    }
    if (Test-Path -LiteralPath $StateRoot) { throw 'canary-state-root-must-be-new' }
    if (-not $Run) {
        return [ordered]@{ state = 'disabled'; signed = $false
            evaluated = $false; providerReads = 0; providerWrites = 0
            modelToolInvocations = 0; writerEligible = $false }
    }
    $sourceSnapshot = ConvertTo-Json -InputObject $ApprovedSources -Depth 32 -Compress
    $providerSnapshot = ConvertTo-Json -InputObject $ProviderConfig -Depth 32 -Compress
    if ([bool]$Read -ne [bool]$Provider) {
        throw 'bound-transport-invalid'
    }
    [void](Assert-CanarySourceSelector $SourceSelector $SourceSelectorKey `
            ([string]$ProviderConfig.repository.organization))
    [void](Assert-CanaryReviewedMergedPin $MergedPinEnvelope `
            $MergedPinKey $SourceSelector)
    if (-not $Read) {
        $ExpectedAccountUniqueName = Get-CanaryWorkAccountUpn $AzureCliPath
    } elseif ($ExpectedAccountUniqueName -cnotmatch '^[^@\s]+@[^@\s]+$') {
        throw 'canary-work-account-unavailable'
    }
    $session = $null
    $created = $false
    $root = $null
    $creationState = @{ created = $false }
    $registry = $null
    $gate = @{ pins = $null; finalRegistry = $null; cohort = $null }
    $providerCalls = @{ attempted = 0; completed = 0; failureCode = $null }
    $transportTelemetry = $null
    $sourceTelemetry = $null
    try {
    if (-not $Read) {
        $session = New-PrivateCanaryBearerSession $RepositoryRoot $AzureCliPath
    }
    $registryArgs = @{ ProviderConfig = $ProviderConfig
        ApprovedSources = $ApprovedSources; RepositoryRoot = $RepositoryRoot
        Mode = $Mode
        ExpectedAccountUniqueName = $ExpectedAccountUniqueName
        SourceSelector = $SourceSelector
        SourceSelectorKey = $SourceSelectorKey
        MergedPinEnvelope = $MergedPinEnvelope
        MergedPinKey = $MergedPinKey; Run = $true }
    if ($Read) {
        $registryArgs.Read = $Read
        $registry = New-VerifiedCanaryRuleRegistry @registryArgs
    } else {
        $sourceTelemetry = [ordered]@{
            attemptedGets = 0; completedGets = 0; throttleEvents = 0
            lastHttpStatus = $null
        }
        $registryArgs.ReadTelemetry = $sourceTelemetry
        $registry = Invoke-PrivateCanaryRuleRegistry @registryArgs `
            -BearerSession $session
    }
    if ($registry.state -cne 'verified-not-evaluated' -or
        $registry.rules.Count -ne $(if ($Mode -ceq 'CoverageOnly') { 2 } else { 4 }) -or
        $registry.providerWrites -ne 0) {
        throw 'canary-registry-incomplete'
    }
    $templateRoot = Join-Path $RepositoryRoot 'samples'
    $intake = Get-Content -LiteralPath (Join-Path $templateRoot `
            'active-pr-intake.config.json') -Raw | ConvertFrom-Json -AsHashtable
    $intake.organization = "https://dev.azure.com/$($ProviderConfig.repository.organization)"
    $intake.projectName = [string]$ProviderConfig.repository.project
    $intake.projectId = [string]$ProviderConfig.projectId
    $intake.repositoryId = [string]$ProviderConfig.repository.id
    $intake.schemaVersion = 3
    $intake.principalProof = 'aad-graph-storage-key-alias-free-v2'
    $intake.expectedAccount = $ProviderConfig.expectedAccount
    $intake.enabled = $true
    $intake.pagination = [ordered]@{ mode = 'created-time-keyset' }
    if ($Mode -ceq 'CoverageOnly') {
        $intake.headProof = 'iteration-source-current-target-v1'
    }
    $intake.projectEvidence.enabled = $true
    $intake.rules = @($registry.rules.Keys | ForEach-Object {
            [ordered]@{ id = [string]$_; capability = [string]$_ }
        })
    $intake.limits.maxHeadsPerRun = $CanaryPullRequestIds.Count
    if (-not $Provider) {
        $transportTelemetry = [ordered]@{
            attemptedGets = 0; completedGets = 0; throttleEvents = 0
            lastHttpStatus = $null
        }
        $Provider = New-ActivePrAzureDevOpsProvider -Config $intake `
            -BearerToken $session.token -BoundClient $session.client `
            -VerifyReadPrincipal -ExpectedPrincipalName $ExpectedAccountUniqueName `
            -TransportTelemetry $transportTelemetry
    }
    $innerProvider = $Provider
    $Provider = {
        param($operation, $request)
        $providerCalls.attempted++
        try {
            $answer = & $innerProvider $operation $request
            $providerCalls.completed++
            return $answer
        }
        catch {
            if ($_.Exception.Message -ceq 'read-throttled') {
                $providerCalls.failureCode = 'read-throttled'
            }
            throw
        }
    }.GetNewClosure()
    $preflight = & $Provider Identity @{ timeoutMilliseconds = 120000 }
    Assert-CanaryAccountBinding $preflight $ProviderConfig.expectedAccount
    if ([string]$preflight.principalName -ine $ExpectedAccountUniqueName -or
        ($preflight.Contains('uniqueName') -and
            [string]$preflight.uniqueName -ine $ExpectedAccountUniqueName)) {
        throw 'canary-principal-drift'
    }
    $preflightReads = 1
    if ($null -ne $preflight['readCount']) {
        $extra = 0
        if (-not [int]::TryParse([string]$preflight.readCount,
                [ref]$extra) -or $extra -lt 0 -or $extra -gt 2) {
            throw 'canary-provider-invalid'
        }
        $preflightReads += $extra
    }
    $beforePersist = {
        param([Collections.IDictionary]$cohort)
        $gate.cohort = $cohort
        if ($cohort.inventory.state -cne 'complete' -or
            $cohort.populationKnown -cne $true -or
            $cohort.gapCounts.enumerationUnknown -ne 0 -or
            $cohort.gapCounts.duplicateEntries -ne 0 -or
            $cohort.inventory.nonDraft -ne $cohort.heads.Count -or
            $cohort.inventory.active -ne
                ($cohort.inventory.draft + $cohort.inventory.nonDraft) -or
            $cohort.inventory.eligible -ne
                ($cohort.inventory.nonDraft - $cohort.inventory.excludedOtherTargets)) {
            throw 'canary-inventory-unknown'
        }
        $pins = @($CanaryPullRequestIds | ForEach-Object {
                $id = $_
                $heads = @($cohort.heads | Where-Object pullRequestId -EQ $id)
                if ($heads.Count -ne 1 -or
                    $heads[0].status -cne 'pending' -or
                    $heads[0].targetRef -cne 'refs/heads/master' -or
                    ($Mode -ceq 'CoverageOnly' -and
                        [string]$heads[0].currentTargetCommit -cnotmatch
                            '^[a-f0-9]{40}$') -or
                    $null -eq $heads[0].lineEvidence -or
                    [string]$heads[0].lineEvidenceDigest -cnotmatch '^[a-f0-9]{64}$' -or
                    $null -eq $heads[0].projectEvidence -or
                    $heads[0].projectEvidence.complete -cne $true -or
                    [string]$heads[0].projectEvidenceDigest -cnotmatch '^[a-f0-9]{64}$') {
                    throw 'canary-head-or-evidence-unknown'
                }
                $pin = [ordered]@{
                    pullRequestId = $id
                    sourceCommit = $heads[0].sourceCommit
                    targetCommit = $heads[0].targetCommit
                    targetRef = $heads[0].targetRef
                    iterationId = $heads[0].iterationId
                    declarationDigest = $heads[0].declarationDigest
                    lineEvidenceDigest = $heads[0].lineEvidenceDigest
                    projectEvidenceDigest = $heads[0].projectEvidenceDigest
                }
                if ($Mode -ceq 'CoverageOnly') {
                    $pin.currentTargetCommit = $heads[0].currentTargetCommit
                }
                $pin
            })
        if ($Read) {
            $finalRegistry = New-VerifiedCanaryRuleRegistry @registryArgs
        } else {
            $finalRegistry = Invoke-PrivateCanaryRuleRegistry @registryArgs `
                -BearerSession $session
        }
        if ($finalRegistry.receiptDigest -cne $registry.receiptDigest -or
            ($Mode -ceq 'CoverageOnly' -and
                $finalRegistry.currentMasterCommit -cne
                    $registry.currentMasterCommit) -or
            $finalRegistry.state -cne 'verified-not-evaluated' -or
            (ConvertTo-Json -InputObject $ApprovedSources -Depth 32 -Compress) -cne
                $sourceSnapshot -or
            (ConvertTo-Json -InputObject $ProviderConfig -Depth 32 -Compress) -cne
                $providerSnapshot) {
            throw 'canary-source-drift'
        }
        $gate.pins = $pins
        $gate.finalRegistry = $finalRegistry
    }.GetNewClosure()
    $root = $StateRoot
    $cohort = Invoke-ActivePrIntake -Config $intake -Provider $Provider `
        -StateRoot $root -RepositoryRoot $RepositoryRoot `
        -CanaryPullRequestIds $CanaryPullRequestIds -BeforePersist $beforePersist `
        -CreationState $creationState `
        -ExpectedPrincipalName $ExpectedAccountUniqueName `
        -ExpectedIdentity $preflight -Run
    $created = $creationState.created
    if (-not $created -or $null -eq $gate.pins -or
        $null -eq $gate.finalRegistry) {
        throw 'canary-intake-not-verified'
    }
    $pins = $gate.pins
    $finalRegistry = $gate.finalRegistry
    $config = [ordered]@{
        schemaVersion = if ($Mode -ceq 'CoverageOnly') { 8 } else { 5 }
        kind = if ($Mode -ceq 'CoverageOnly') {
            'private-coverage-only-signed-intake'
        } else { 'private-canary-signed-intake' }
        principalProof = 'aad-graph-storage-key-alias-free-v2'
        enabled = $false
        readOnly = $true
        dryRun = $true
        writerEligible = $false
        modelEnabled = $false
        organization = $intake.organization
        projectId = $intake.projectId
        repositoryId = $intake.repositoryId
        expectedAccount = $intake.expectedAccount
        sourceAuthority = 'merged-master-verified-read-only'
        receiptDigest = $registry.receiptDigest
        intakeGeneration = $cohort.generation
        intakeConfigDigest = $cohort.binding.configDigest
        heads = $pins
        rules = @($registry.rules.Keys | ForEach-Object {
                $rule = $registry.rules[$_]
                $binding = [ordered]@{
                    capabilityId = $rule.id
                    enabled = $false
                    evaluated = $false
                    writerEligible = $false
                    sourceAuthority = $rule.sourceAuthority
                    sourceCommit = $rule.sourceCommit
                    sourceHash = $rule.sourceHash
                    declarationDigest = $rule.declarationDigest
                }
                if ($Mode -ceq 'CoverageOnly') {
                    $binding.policyLineHash = $rule.policyLineHash
                }
                $binding
            })
        limits = [ordered]@{
            maxHeadsPerRun = $CanaryPullRequestIds.Count
            maxReads = 3000
            maxSeconds = 240
            maxFindingsPerHead = 8
        }
        signature = ''
    }
    if ($Mode -ceq 'CoverageOnly') {
        $config.mode = 'coverage-only'
        $config.headProof = 'iteration-source-current-target-v1'
        $config.sourceMasterCommit = $registry.currentMasterCommit
    }
    $key = [Convert]::ToBase64String(
        [Security.Cryptography.RandomNumberGenerator]::GetBytes(48))
    $config.signature = Get-CanarySignature $config $key
    foreach ($entry in @(
            @{ name = 'provider-config.json'; value = $ProviderConfig },
            @{ name = 'approved-sources.json'; value = $ApprovedSources },
            @{ name = 'canary-intake.json'; value = $intake },
            @{ name = 'canary-dispatcher.json'; value = $config })) {
        $file = Join-Path $root $entry.name
        Write-CanaryPrivateFile $file ([Text.Encoding]::UTF8.GetBytes(
                (ConvertTo-Json -InputObject $entry.value -Depth 32)))
        [void](Assert-AgentTrustedFile -Path $file -AllowedRoot $root -Private)
    }
    $keyFile = Join-Path $root 'signature.key'
    Write-CanaryPrivateFile $keyFile ([Text.Encoding]::ASCII.GetBytes($key))
    [void](Assert-AgentTrustedFile -Path $keyFile -AllowedRoot $root -Private)
    return [ordered]@{
        state = 'signed-intake-not-evaluated'
        signed = $true
        evaluated = $false
        writerEligible = $false
        providerReads = $registry.providerReads + $preflightReads +
            $cohort.readCount + $finalRegistry.providerReads
        providerWrites = 0
        modelToolInvocations = 0
        inventory = [ordered]@{
            active = $cohort.inventory.active
            nonDraft = $cohort.inventory.nonDraft
            draft = $cohort.inventory.draft
            eligible = $cohort.inventory.eligible
            pagesFirst = $cohort.pages.first
            pagesSecond = $cohort.pages.second
        }
        intakeGeneration = $cohort.generation
        selected = $pins.Count
        pending = $cohort.counts.deferred + $pins.Count
        skipped = $cohort.counts.skipped
        unknown = $cohort.counts.error
        rules = @($config.rules | ForEach-Object {
                [ordered]@{ capabilityId = $_.capabilityId
                    evaluated = 0; humanCovered = 0; wouldCreate = 0
                    unknown = $pins.Count }
            }) + @(if ($Mode -ceq 'CoverageOnly') {
                foreach ($id in @('bpm-test-ownership@1',
                        'bpm-named-areequal-arguments@1')) {
                    [ordered]@{ capabilityId = $id; status = 'unknown'
                        reason = 'not-attempted'; evaluated = 0
                        humanCovered = 0; wouldCreate = 0
                        unknown = $pins.Count }
                }
            })
    }
    }
    catch {
        $failure = $_
        if ($FailureDiagnostic) {
            $diagnostic = New-CanaryIntakeFailureDiagnostic $gate.cohort `
                $CanaryPullRequestIds $transportTelemetry $providerCalls `
                $(if ($registry) { $registry.providerReads } else { $null }) `
                $sourceTelemetry
            $safeFailures = @('canary-inventory-unknown',
                'canary-head-or-evidence-unknown', 'canary-source-drift',
                'read-throttled', 'canary-principal-drift',
                'canary-intake-not-verified', 'canary-state-root-must-be-new')
            if ($Mode -ceq 'CoverageOnly') {
                $safeFailures += @('coverage-receipt-drift',
                    'coverage-receipt-invalid',
                    'coverage-source-master-lineage-unproved',
                    'coverage-source-snapshot-drift',
                    'coverage-registry-identity-drift',
                    'merged-master-history-unproved',
                    'merged-master-pr-unverified',
                    'merged-master-ref-unverified',
                    'merged-master-document-drift',
                    'merged-master-declaration-drift',
                    'bootstrap-blob-unverified', 'canary-principal-mismatch',
                    'canary-identity-drift')
            }
            $diagnostic.failureCode = if ($failure.Exception.Message -cin
                $safeFailures) {
                [string]$failure.Exception.Message
            } elseif ($Mode -ceq 'CoverageOnly' -and
                $failure.Exception.Message -cmatch
                    '^bootstrap-read-throttled:(IdentityProof|GraphUser|GraphStorageKey|Project|Repository|PullRequest|Iterations|Ref|Commit|Item|RawItem)$') {
                'read-throttled'
            } else { 'canary-preflight-incomplete' }
            if ($providerCalls.failureCode -ceq 'read-throttled' -or
                $diagnostic.failureCode -ceq 'read-throttled') {
                $diagnostic.throttleState = 'detected'
            }
            if ($diagnostic.failureCode -ceq 'canary-source-drift') {
                $diagnostic.driftState = 'detected'
            }
            $FailureDiagnostic.Value = $diagnostic
        }
        $cleanupFailed = $false
        if ($null -ne $creationState -and $creationState.created) {
            try {
                $root = [string]$creationState.root
                $canonical = [IO.Path]::GetFullPath($StateRoot)
                $comparison = if ($IsWindows) {
                    [StringComparison]::OrdinalIgnoreCase
                } else { [StringComparison]::Ordinal }
                if (-not $root.Equals($canonical, $comparison) -or
                    (Test-AgentPathWithin $root $RepositoryRoot) -or
                    (Test-AgentPathWithin $RepositoryRoot $root)) {
                    throw 'canary-private-state-cleanup-failed'
                }
                $parent = [IO.Path]::GetDirectoryName($root)
                if (-not $parent -or
                    $parent.Equals($root, $comparison)) {
                    throw 'canary-private-state-cleanup-failed'
                }
                Remove-AgentContainedDirectory -Path $root `
                    -AllowedRoot $parent -LeafPattern (
                        '^(?:' + [regex]::Escape(
                            [IO.Path]::GetFileName($root)) + ')$')
            }
            catch { $cleanupFailed = $true }
        }
        if ($FailureDiagnostic) {
            if ($cleanupFailed) {
                $FailureDiagnostic.Value.failureCode =
                    'canary-private-state-cleanup-failed'
            }
            try {
                $FailureDiagnostic.Value.privateIntakePersisted =
                    Test-Path -LiteralPath $StateRoot -ErrorAction Stop
            }
            catch { $FailureDiagnostic.Value.privateIntakePersisted = $null }
        }
        if ($cleanupFailed) { throw 'canary-private-state-cleanup-failed' }
        throw $failure
    }
    finally { if ($session) { $session.client.Dispose() } }
}

function Invoke-ActivePrCanaryQualification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$ProviderConfig,
        [Parameter(Mandatory)][Collections.IDictionary]$ApprovedSources,
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][int[]]$CanaryPullRequestIds,
        [string]$AzureCliPath = 'az',
        [scriptblock]$Provider,
        [switch]$Run
    )
    if ($CanaryPullRequestIds.Count -lt 1 -or $CanaryPullRequestIds.Count -gt 2 -or
        @($CanaryPullRequestIds | Where-Object { $_ -lt 1 }).Count -gt 0 -or
        @($CanaryPullRequestIds | Select-Object -Unique).Count -ne
            $CanaryPullRequestIds.Count) { throw 'invalid-canary-selection' }
    if (-not [IO.Path]::IsPathFullyQualified($RepositoryRoot) -or
        -not [IO.Path]::IsPathFullyQualified($StateRoot) -or
        (Test-AgentPathWithin -Path $StateRoot -Root $RepositoryRoot)) {
        throw 'state-root-must-be-external'
    }
    if (Test-Path -LiteralPath $StateRoot) { throw 'canary-state-root-must-be-new' }
    $repository = $ProviderConfig['repository']
    $account = $ProviderConfig['expectedAccount']
    $alias = [string]$ProviderConfig.operator.defaultAlias
    if ($ProviderConfig.provider -cne 'AzureDevOps' -or
        $repository -isnot [Collections.IDictionary] -or
        [string]$repository.organization -cnotmatch '^[A-Za-z0-9_-]{1,128}$' -or
        [string]$repository.project -cnotmatch '^[\w .-]{1,128}$' -or
        [string]$repository.name -cnotmatch '^[A-Za-z0-9._-]{1,128}$' -or
        [string]$repository.id -cnotmatch
            '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$' -or
        [string]$alias -cnotmatch '^[a-zA-Z0-9._%+-]+(?:@[a-zA-Z0-9.-]+)?$') {
        throw 'private-provider-identity-unavailable'
    }
    $expectedProjectId = [string]$ProviderConfig['projectId']
    if (($expectedProjectId -and $expectedProjectId -cnotmatch
            '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$') -or
        ($null -ne $account -and ($account -isnot [Collections.IDictionary] -or
            [string]$account.id -cnotmatch
                '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$' -or
            [string]$account.descriptor -cnotmatch '^\S{1,512}$' -or
            [string]$account.uniqueName -cnotmatch '^[^@\s]+@[^@\s]+$'))) {
        throw 'private-provider-identity-unavailable'
    }
    if ($ApprovedSources -isnot [Collections.IDictionary]) {
        throw 'rule-source-not-approved'
    }
    Assert-CanarySource $ApprovedSources['owner'] $script:DocumentPath $script:OwnerCommit
    Assert-CanarySource $ApprovedSources['namedSection'] $script:DocumentPath ''
    foreach ($policy in $script:StaticPolicies) {
        $path = "/src/DevPilot.OwnerCapability/Policy/$($policy.file).v1.txt"
        Assert-CanarySource $ApprovedSources[$policy.name] $path ''
    }
    $templateRoot = Join-Path $RepositoryRoot 'samples'
    $intake = Get-Content -LiteralPath (Join-Path $templateRoot `
            'active-pr-intake.config.json') -Raw |
        ConvertFrom-Json -AsHashtable
    $config = Get-Content -LiteralPath (Join-Path $templateRoot `
            'rule-evaluation.config.json') -Raw |
        ConvertFrom-Json -AsHashtable
    $intake.organization = "https://dev.azure.com/$($repository.organization)"
    $intake.projectName = [string]$repository.project
    $intake.projectId = ''
    $intake.repositoryId = [string]$repository.id
    $intake.rules = @($config.rules | ForEach-Object {
            @{ id = [string]$_.ruleId; capability = [string]$_.capabilityId }
        })
    $intake.limits.maxHeadsPerRun = $CanaryPullRequestIds.Count
    $intake.limits.maxReads = 3000
    $intake.limits.maxSeconds = 240
    $config.organization = $intake.organization
    $config.projectId = $intake.projectId
    $config.repositoryId = $intake.repositoryId
    $config.limits.maxHeadsPerRun = $CanaryPullRequestIds.Count
    $config.limits.maxReads = 3000
    $config.limits.maxSeconds = 240
    if (-not $Run) {
        return @{ state = 'disabled'; owner = 'unknown/not-attempted'
            providerReads = 0; providerWrites = 0 }
    }
    if (-not $Provider) {
        $Provider = New-ActivePrAzureDevOpsProvider -Config $intake `
            -AzureCliPath $AzureCliPath -Bootstrap -VerifyReadPrincipal
    }
    $identity = & $Provider Identity @{}
    $metadata = & $Provider Metadata @{ repositoryName = $repository.name }
    if ($identity -isnot [Collections.IDictionary] -or
        [string]$identity.id -cnotmatch
            '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$' -or
        [string]$identity.descriptor -cnotmatch '^\S{1,512}$' -or
        [string]$identity.uniqueName -cnotmatch '^[^@\s]+@[^@\s]+$' -or
        ($alias -ine [string]$identity.uniqueName -and
            $alias -ine ([string]$identity.uniqueName).Split('@')[0]) -or
        ($null -ne $account -and
            ([string]$identity.id -ine [string]$account.id -or
                [string]$identity.descriptor -cne [string]$account.descriptor -or
                [string]$identity.uniqueName -ine [string]$account.uniqueName)) -or
        $metadata -isnot [Collections.IDictionary] -or
        [string]$metadata.projectId -cnotmatch
            '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$' -or
        ($expectedProjectId -and
            [string]$metadata.projectId -ine $expectedProjectId) -or
        [string]$metadata.projectName -cne [string]$repository.project -or
        [string]$metadata.repositoryId -ine [string]$repository.id -or
        [string]$metadata.repositoryName -cne [string]$repository.name) {
        throw 'private-provider-identity-mismatch'
    }
    $intake.projectId = [string]$metadata.projectId
    $intake.expectedAccount = [ordered]@{
        id = [string]$identity.id
        descriptor = [string]$identity.descriptor
        uniqueName = [string]$identity.uniqueName
    }
    $config.projectId = $intake.projectId
    if (-not $PSBoundParameters.ContainsKey('Provider')) {
        $Provider = New-ActivePrAzureDevOpsProvider -Config $intake `
            -AzureCliPath $AzureCliPath -VerifyReadPrincipal
    }
    $intake.enabled = $true
    $root = Resolve-AgentTrustedRoot -Path $StateRoot -Kind durable-state `
        -RepositoryRoot $RepositoryRoot -Create
    $intakeResult = Invoke-ActivePrIntake -Config $intake -Provider $Provider `
        -StateRoot $root -RepositoryRoot $RepositoryRoot `
        -CanaryPullRequestIds $CanaryPullRequestIds -Run
    if ($intakeResult.inventory.state -cne 'complete' -or
        $intakeResult.populationKnown -cne $true -or
        $intakeResult.gapCounts.enumerationUnknown -ne 0) {
        throw 'canary-inventory-unknown'
    }
    $pins = @($CanaryPullRequestIds | ForEach-Object {
            $id = $_
            $head = @($intakeResult.heads | Where-Object pullRequestId -EQ $id)
            if ($head.Count -ne 1 -or $head[0].targetRef -cne 'refs/heads/master' -or
                $head[0].status -cne 'pending' -or $null -eq $head[0].lineEvidence) {
                throw 'canary-head-or-evidence-unknown'
            }
            [ordered]@{
                pullRequestId = $id
                sourceCommit = $head[0].sourceCommit
                targetCommit = $head[0].targetCommit
                targetRef = $head[0].targetRef
                iterationId = $head[0].iterationId
                declarationDigest = $head[0].declarationDigest
                lineEvidenceDigest = $head[0].lineEvidenceDigest
            }
        })
    $document = Read-CanarySource $Provider $ApprovedSources.owner $script:DocumentPath
    $ownerSection = Get-CanarySection $document '## Claim ownership'
    if ((Get-CanaryTextHash $ownerSection) -cne $script:OwnerHash -or
        [Text.Encoding]::UTF8.GetByteCount($ownerSection) -gt 65536) {
        throw 'owner-rule-digest-mismatch'
    }
    $namedDocument = Read-CanarySource $Provider $ApprovedSources.namedSection `
        $script:DocumentPath
    $namedSection = Get-CanaryRawSection $namedDocument '## Named parameters for Assert'
    if ((Get-CanaryTextHash $namedSection) -cne $script:NamedSectionHash -or
        [Text.Encoding]::UTF8.GetByteCount($namedSection) -ne
            $script:NamedSectionLength) {
        throw 'named-rule-digest-mismatch'
    }
    $config.provenance = [ordered]@{
        ownerSection = [ordered]@{
            repositoryId = [string]$ApprovedSources.owner.repositoryId
            commit = $script:OwnerCommit
            path = $script:DocumentPath.Substring(1)
            section = '## Claim ownership'
            hash = 'v1:sha256:' + $script:OwnerHash
            length = [Text.Encoding]::UTF8.GetByteCount($ownerSection)
        }
        namedSection = [ordered]@{
            repositoryId = [string]$ApprovedSources.namedSection.repositoryId
            commit = [string]$ApprovedSources.namedSection.commit
            path = $script:DocumentPath.Substring(1)
            section = '## Named parameters for Assert'
            hash = 'v1:sha256:' + (Get-CanaryTextHash $namedSection)
            length = [Text.Encoding]::UTF8.GetByteCount($namedSection)
        }
    }
    foreach ($policy in $script:StaticPolicies) {
        $source = $ApprovedSources[$policy.name]
        $path = "/src/DevPilot.OwnerCapability/Policy/$($policy.file).v1.txt"
        $remoteText = Read-CanarySource $Provider $source $path
        $localPath = Join-Path $RepositoryRoot (
            "src\DevPilot.OwnerCapability\Policy\$($policy.file).v1.txt")
        $localText = [IO.File]::ReadAllText($localPath,
            [Text.UTF8Encoding]::new($false, $true))
        if ((Get-CanaryTextHash $remoteText) -cne (Get-CanaryTextHash $localText)) {
            throw 'static-rule-digest-mismatch'
        }
        $rule = $config.rules[$policy.index]
        $rule.enabled = $true
        $rule.binding = [ordered]@{
            ruleRepositoryId = [string]$source.repositoryId
            rulePath = $path.Substring(1)
            ruleCommit = [string]$source.commit
            ruleHash = 'v1:sha256:' + (Get-CanaryTextHash $localText)
            capabilityDigest = 'v1:sha256:' + (
                Get-CanaryTextHash "$($policy.file)-capability-v1")
        }
    }
    $config.canary = [ordered]@{
        schemaVersion = 1
        intakeGeneration = [string]$intakeResult.generation
        intakeConfigDigest = [string]$intakeResult.binding.configDigest
        heads = $pins
    }
    $config.enabled = $true
    $config.signature = ''
    $keyBytes = [Security.Cryptography.RandomNumberGenerator]::GetBytes(48)
    $key = [Convert]::ToBase64String($keyBytes)
    $config.signature = Get-CanarySignature $config $key
    Write-CanaryPrivateFile (Join-Path $root 'signature.key') `
        ([Text.Encoding]::ASCII.GetBytes($key))
    [void](Assert-AgentTrustedFile -Path (Join-Path $root 'signature.key') `
            -AllowedRoot $root -Private)
    Write-CanaryPrivateFile (Join-Path $root 'canary-intake.json') `
        ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $intake -Depth 32)))
    Write-CanaryPrivateFile (Join-Path $root 'canary-evaluation.json') `
        ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $config -Depth 32)))
    $result = Invoke-BoundedRuleEvaluation -Config $config -IntakeConfig $intake `
        -Provider $Provider -StateRoot $root -RepositoryRoot $RepositoryRoot `
        -SignatureKey $key -CanaryPullRequestIds $CanaryPullRequestIds -Run
    $selectedResults = @($result.heads | Where-Object {
            $_.pullRequestId -in $CanaryPullRequestIds
        })
    return [ordered]@{
        state = if (@($selectedResults | ForEach-Object {
                    @($_.rules | Where-Object status -IN @('unknown', 'error'))
                }).Count -gt 0) { 'unknown' } else { 'read-only' }
        owner = 'unknown/not-attempted'
        inventory = [ordered]@{
            active = $intakeResult.inventory.active
            draft = $intakeResult.inventory.draft
            eligible = $intakeResult.inventory.eligible
            pagesFirst = $intakeResult.pages.first
            pagesSecond = $intakeResult.pages.second
        }
        intakeGeneration = $intakeResult.generation
        evaluationGeneration = $result.generation
        configDigest = $result.binding.configDigest
        ruleDigests = @($config.rules | Where-Object enabled | ForEach-Object {
                $_.binding.ruleHash
            })
        selected = $selectedResults.Count
        ruleCounts = @($config.rules | ForEach-Object {
                $rule = $_
                $entries = @($selectedResults | ForEach-Object {
                        @($_.rules | Where-Object capabilityId -CEQ $rule.capabilityId)
                    })
                [ordered]@{
                    capabilityId = $rule.capabilityId
                    evaluated = @($entries | Where-Object status -EQ 'evaluated').Count
                    unknown = if ($rule.capabilityId -ceq 'bpm-test-ownership@1') {
                        $selectedResults.Count
                    } else {
                        @($entries | Where-Object status -IN @('unknown', 'error')).Count
                    }
                    wouldCreate = @($entries | Where-Object status -EQ 'evaluated' |
                        ForEach-Object {
                            $observation = Get-Content -LiteralPath (
                                Join-Path $root "rule-evaluation-v1\observations\$($_.observationDigest).json"
                            ) -Raw | ConvertFrom-Json -AsHashtable
                            $observation.outcome.wouldCreate
                        } | Measure-Object -Sum).Sum
                }
            })
        providerWrites = 0
        writerEligible = $false
    }
}

Export-ModuleMember -Function Invoke-ActivePrCanaryQualification,
    Assert-CanaryCoverageSource, Invoke-CanaryMergedMasterPreflight,
    Invoke-CanaryMergedMasterDiscovery, Invoke-PrivateCanaryMergedPinProvision,
    Get-CanaryWorkAccountUpn,
    Read-CanaryPrivateSourceSelector, Read-CanaryPrivateMergedPin,
    Invoke-PrivateCanaryBootstrap,
    New-VerifiedCanaryRuleRegistry, Invoke-PrivateCanaryRuleRegistry,
    Invoke-PrivateCanarySignedIntake, Invoke-PrivateCanaryIdentityDiagnostic
