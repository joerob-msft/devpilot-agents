#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1')
Import-Module (Join-Path $PSScriptRoot '..\DevPilot.ActivePrIntake\DevPilot.ActivePrIntake.psd1')
Import-Module (Join-Path $PSScriptRoot '..\DevPilot.RuleEvaluation\DevPilot.RuleEvaluation.psd1')

$script:OwnerCommit = 'f6db83436b48f48a8521095a888d79f67823bbb2'
$script:OwnerHash = 'bc31bfea6b378dffe4a1b28475dc1cac4cd3ee1ab793db57895446ded829ab2f'
$script:DocumentPath = '/documentation/EngineeringProcesses/Conventions/AutomatedTests.md'
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
    $pattern = '(?m)^' + [regex]::Escape($Heading) +
        '[ \t]*(?:\r\n|\n|\r)(?:(?!^##[ \t]).)*(?=^##[ \t]|\z)'
    $matches = [regex]::Matches($Document, $pattern,
        [Text.RegularExpressions.RegexOptions]::Singleline -bor
        [Text.RegularExpressions.RegexOptions]::Multiline)
    if ($matches.Count -ne 1) { throw 'rule-section-unavailable' }
    return $matches[0].Value.Trim()
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
    $namedSection = Get-CanarySection $namedDocument '## Named parameters for Assert'
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
    $unsigned = [ordered]@{}
    foreach ($entry in $config.Keys) {
        if ([string]$entry -cne 'signature') { $unsigned[[string]$entry] = $config[$entry] }
    }
    $hmac = [Security.Cryptography.HMACSHA256]::new(
        [Text.Encoding]::UTF8.GetBytes($key))
    try {
        $config.signature = 'v1:hmac-sha256:' +
            [Convert]::ToHexString($hmac.ComputeHash(
                    [Text.Encoding]::UTF8.GetBytes(
                        (ConvertTo-AgentCanonicalJson -InputObject $unsigned))
                )).ToLowerInvariant()
    }
    finally { $hmac.Dispose() }
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

Export-ModuleMember -Function Invoke-ActivePrCanaryQualification
