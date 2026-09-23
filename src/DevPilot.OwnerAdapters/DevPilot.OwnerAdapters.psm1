#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\..\DevPilot.OwnerPipeline\DevPilot.OwnerPipeline.psd1"

$adapterRequestTypeName = 'DevPilot.OwnerAdapters.OwnerAcquisitionRequest'
if (-not ($adapterRequestTypeName -as [type])) {
    Add-Type -TypeDefinition @'
namespace DevPilot.OwnerAdapters
{
    public sealed class OwnerAdapterLimits
    {
        public int MaximumFiles { get; }
        public long MaximumBytes { get; }
        public int MaximumReads { get; }
        public int MaximumDiagnostics { get; }

        public OwnerAdapterLimits(int maximumFiles, long maximumBytes, int maximumReads, int maximumDiagnostics)
        {
            MaximumFiles = maximumFiles;
            MaximumBytes = maximumBytes;
            MaximumReads = maximumReads;
            MaximumDiagnostics = maximumDiagnostics;
        }
    }

    public sealed class OwnerAcquisitionRequest
    {
        public int SchemaVersion { get { return 1; } }
        public string RepositoryId { get; }
        public string ProjectId { get; }
        public long PullRequestId { get; }
        public string SourceCommit { get; }
        public string TargetCommit { get; }
        public string TargetRef { get; }
        public string RuleRepositoryId { get; }
        public string RulePath { get; }
        public string RuleCommit { get; }
        public string RuleSection { get; }
        public string RuleHash { get; }
        public long RuleLength { get; }
        public string ConfigId { get; }
        public string ConfigDigest { get; }
        public string CapabilityId { get; }
        public string CapabilityDigest { get; }

        public OwnerAcquisitionRequest(
            string repositoryId,
            string projectId,
            long pullRequestId,
            string sourceCommit,
            string targetCommit,
            string targetRef,
            string ruleRepositoryId,
            string rulePath,
            string ruleCommit,
            string ruleSection,
            string ruleHash,
            long ruleLength,
            string configId,
            string configDigest,
            string capabilityId,
            string capabilityDigest)
        {
            RepositoryId = repositoryId;
            ProjectId = projectId;
            PullRequestId = pullRequestId;
            SourceCommit = sourceCommit;
            TargetCommit = targetCommit;
            TargetRef = targetRef;
            RuleRepositoryId = ruleRepositoryId;
            RulePath = rulePath;
            RuleCommit = ruleCommit;
            RuleSection = ruleSection;
            RuleHash = ruleHash;
            RuleLength = ruleLength;
            ConfigId = configId;
            ConfigDigest = configDigest;
            CapabilityId = capabilityId;
            CapabilityDigest = capabilityDigest;
        }
    }

    public sealed class OwnerReplayFixture
    {
        public int SchemaVersion { get { return 1; } }
        public string Semantics { get; }
        public string PayloadJson { get; }
        public string PayloadDigest { get; }
        public string SealDigest { get; }

        public OwnerReplayFixture(string semantics, string payloadJson, string payloadDigest, string sealDigest)
        {
            Semantics = semantics;
            PayloadJson = payloadJson;
            PayloadDigest = payloadDigest;
            SealDigest = sealDigest;
        }
    }
}
'@
}

if (-not ('DevPilot.OwnerAdapters.OwnerDiscussionLimits' -as [type])) {
    Add-Type -TypeDefinition @'
namespace DevPilot.OwnerAdapters
{
    public sealed class OwnerDiscussionLimits
    {
        public int MaximumPages { get; }
        public int PageSize { get; }
        public int MaximumThreads { get; }
        public int MaximumComments { get; }
        public long MaximumBytes { get; }

        public OwnerDiscussionLimits(
            int maximumPages,
            int pageSize,
            int maximumThreads,
            int maximumComments,
            long maximumBytes)
        {
            MaximumPages = maximumPages;
            PageSize = pageSize;
            MaximumThreads = maximumThreads;
            MaximumComments = maximumComments;
            MaximumBytes = maximumBytes;
        }
    }

    public sealed class OwnerDiscussionSnapshot
    {
        public int SchemaVersion { get { return 1; } }
        public string State { get; }
        public string Reason { get; }
        public int PageCount { get; }
        public int ThreadCount { get; }
        public int CommentCount { get; }
        public long ByteCount { get; }
        public string Digest { get; }
        public string[] SourceDigests { get; }
        public object[] Threads { get; }

        public OwnerDiscussionSnapshot(
            string state,
            string reason,
            int pageCount,
            int threadCount,
            int commentCount,
            long byteCount,
            string digest,
            string[] sourceDigests,
            object[] threads)
        {
            State = state;
            Reason = reason;
            PageCount = pageCount;
            ThreadCount = threadCount;
            CommentCount = commentCount;
            ByteCount = byteCount;
            Digest = digest;
            SourceDigests = sourceDigests;
            Threads = threads;
        }
    }
}
'@
}

if (-not ('DevPilot.OwnerAdapters.OwnerAzureDevOpsReviewerIdentity' -as [type])) {
    Add-Type -TypeDefinition @'
namespace DevPilot.OwnerAdapters
{
    public sealed class OwnerAzureDevOpsReviewerIdentity
    {
        public string Id { get; }
        public string Descriptor { get; }
        public string UniqueName { get; }

        public OwnerAzureDevOpsReviewerIdentity(
            string id,
            string descriptor,
            string uniqueName)
        {
            Id = id;
            Descriptor = descriptor;
            UniqueName = uniqueName;
        }
    }
}
'@
}

$script:OwnerAdapterSemantics = 'owner-acquisition-v1'
$script:OwnerAdapterContractMaterial = (
    'owner-acquisition-v1|ordinal-paths|complete-pages|subject-race|' +
    'rule-and-file-byte-cap|explicit-unknown-reasons|expected-replay-payload-digest'
)
$script:OwnerAdapterContractDigest = 'v1:sha256:' + [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($script:OwnerAdapterContractMaterial))
).ToLowerInvariant()
$script:OwnerAdapterStates = @('complete', 'incomplete', 'unknown')
$script:OwnerProviderOperations = @(
    'GetSubject',
    'GetChangedFilesPage',
    'GetRule',
    'GetFile',
    'GetDiscussionPage'
)
$script:OwnerAdapterMaximumJsonNodes = 100000
$script:OwnerDiscussionStates = @('active', 'fixed', 'closed', 'resolved', 'unknown')
$script:OwnerAzureDevOpsDiscussionSemantics = 'owner-azuredevops-discussion-v1'
$script:OwnerAzureDevOpsThreadStatusMap = [ordered]@{
    '0' = 'unknown'
    'unknown' = 'unknown'
    '1' = 'active'
    'active' = 'active'
    '6' = 'active'
    'pending' = 'active'
    '2' = 'fixed'
    'fixed' = 'fixed'
    '3' = 'closed'
    'wontfix' = 'closed'
    'wont_fix' = 'closed'
    '4' = 'closed'
    'closed' = 'closed'
    '5' = 'closed'
    'bydesign' = 'closed'
    'by_design' = 'closed'
}
$script:OwnerAzureDevOpsCommentTypeMap = [ordered]@{
    '0' = 'reject'
    'unknown' = 'reject'
    '1' = 'text'
    'text' = 'text'
    '2' = 'system'
    'codechange' = 'system'
    'code_change' = 'system'
    '3' = 'system'
    'system' = 'system'
}
$script:OwnerAzureDevOpsThreadStatusDefault = 'unknown'
$script:OwnerAzureDevOpsCommentTypeDefault = 'reject'
$script:OwnerAzureDevOpsContextStates = @(
    'current',
    'outdated',
    'ambiguous',
    'notApplicable'
)
$script:OwnerAzureDevOpsReviewerIdentityFields = @(
    'id',
    'descriptor',
    'uniqueName'
)
$script:OwnerAzureDevOpsReviewerIdentityStates = @(
    'matched',
    'foreign',
    'ambiguous'
)
$script:OwnerAzureDevOpsPagingPrefix = 'skip:'
$script:OwnerAzureDevOpsMaximumRestThreads = 1000
$script:OwnerAzureDevOpsDiscussionContractMaterial = ConvertTo-Json -InputObject ([ordered]@{
        semantics = $script:OwnerAzureDevOpsDiscussionSemantics
        source = 'azure-devops-rest'
        reviewerIdentity = $script:OwnerAzureDevOpsReviewerIdentityFields
        reviewerIdentityStates = $script:OwnerAzureDevOpsReviewerIdentityStates
        missingReviewerIdentity = 'ambiguous'
        threadStatus = $script:OwnerAzureDevOpsThreadStatusMap
        threadStatusDefault = $script:OwnerAzureDevOpsThreadStatusDefault
        commentType = $script:OwnerAzureDevOpsCommentTypeMap
        commentTypeDefault = $script:OwnerAzureDevOpsCommentTypeDefault
        contextStates = $script:OwnerAzureDevOpsContextStates
        anchorSource = 'threadContext.filePath+rightFileStart.line'
        iterationRule = (
            'positive-changeTrackingId+secondComparingIteration:' +
            'equal-current,less-outdated,other-ambiguous'
        )
        pageOrdering = @('threadId', 'commentId')
        pagingPrefix = $script:OwnerAzureDevOpsPagingPrefix
        maximumRestThreads = $script:OwnerAzureDevOpsMaximumRestThreads
        fullResponsePaging = 'normalizer-slice'
        pageOffsetRule = 'pageOrdinal*pageSize'
        typedPageDigest = 'canonical-json'
        rawProvenanceDigest = 'canonical-full-rest-response'
    }) -Depth 8 -Compress -EscapeHandling EscapeNonAscii
$script:OwnerAzureDevOpsDiscussionMappingDigest = 'v1:sha256:' + [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($script:OwnerAzureDevOpsDiscussionContractMaterial))
).ToLowerInvariant()
$script:OwnerUnknownReasons = @(
    'binary',
    'cap-exhausted',
    'incomplete',
    'oversize',
    'provider-unknown',
    'spans-incomplete',
    'spans-missing',
    'truncated'
)

function Assert-OwnerAdapterText {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Name,
        [int]$MaximumLength = 512
    )

    if ([string]::IsNullOrWhiteSpace($Value) -or
        $Value -cne $Value.Trim() -or
        $Value.Length -gt $MaximumLength -or
        $Value -match '[\x00-\x1f\x7f]') {
        throw "$Name must be non-empty, trimmed text without control characters and no longer than $MaximumLength characters."
    }
}

function Assert-OwnerAdapterDigest {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Name
    )

    if ($Value -cnotmatch '^v1:sha256:[0-9a-f]{64}$') {
        throw "$Name must be a lowercase v1 SHA-256 digest."
    }
}

function Assert-OwnerAdapterCommit {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Name
    )

    if ($Value -cnotmatch '^[0-9a-f]{40}([0-9a-f]{24})?$') {
        throw "$Name must be a lowercase 40- or 64-character commit identifier."
    }
}

function ConvertTo-OwnerAdapterNode {
    param(
        [Parameter()][AllowNull()][object]$Value,
        [int]$Depth = 0,
        [Parameter(Mandatory)][ref]$NodeCount
    )

    if ($null -eq $Value) { return $null }
    $NodeCount.Value++
    if ($Depth -gt 20 -or $NodeCount.Value -gt $script:OwnerAdapterMaximumJsonNodes) {
        throw 'Adapter fixture exceeded the canonical JSON depth or node bound.'
    }
    if ($Value -is [string] -or $Value -is [bool] -or
        $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [short] -or $Value -is [ushort] -or
        $Value -is [int] -or $Value -is [uint] -or
        $Value -is [long] -or $Value -is [ulong] -or
        $Value -is [decimal] -or $Value -is [double] -or $Value -is [single]) {
        return $Value
    }
    if ($Value -is [Collections.IDictionary]) {
        if ($Value.Count -gt 2048) { throw 'Adapter fixture object exceeded its member bound.' }
        $copy = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
        $keys = [string[]]@($Value.Keys)
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        foreach ($key in $keys) {
            if ([string]::IsNullOrEmpty($key)) { throw 'Adapter fixture keys must be non-empty strings.' }
            $copy[$key] = ConvertTo-OwnerAdapterNode -Value $Value[$key] -Depth ($Depth + 1) -NodeCount $NodeCount
        }
        return $copy
    }
    if ($Value -is [Collections.IList]) {
        if ($Value.Count -gt 1024) { throw 'Adapter fixture array exceeded its item bound.' }
        $items = [Collections.Generic.List[object]]::new()
        foreach ($item in $Value) {
            [void]$items.Add((ConvertTo-OwnerAdapterNode -Value $item -Depth ($Depth + 1) -NodeCount $NodeCount))
        }
        Write-Output -NoEnumerate ([object[]]$items.ToArray())
        return
    }
    if ($Value -is [pscustomobject]) {
        $dictionary = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $dictionary[$property.Name] = $property.Value
        }
        return ConvertTo-OwnerAdapterNode -Value $dictionary -Depth $Depth -NodeCount $NodeCount
    }
    throw "Adapter fixtures accept only JSON-shaped values, not '$($Value.GetType().FullName)'."
}

function ConvertTo-OwnerAdapterCanonicalValue {
    param([Parameter()][AllowNull()][object]$Value)

    $nodeCount = 0
    $copy = ConvertTo-OwnerAdapterNode -Value $Value -NodeCount ([ref]$nodeCount)
    if ($Value -is [Collections.IList]) {
        Write-Output -NoEnumerate ([object[]]@($copy))
        return
    }
    return $copy
}

function ConvertTo-OwnerAdapterCanonicalJson {
    param([Parameter()][AllowNull()][object]$Value)

    return ConvertTo-Json -InputObject (ConvertTo-OwnerAdapterCanonicalValue -Value $Value) `
        -Depth 32 -Compress -EscapeHandling EscapeNonAscii
}

function Get-OwnerAdapterDigest {
    param([Parameter(Mandatory)][object]$Value)

    $json = if ($Value -is [string]) { $Value } else { ConvertTo-OwnerAdapterCanonicalJson -Value $Value }
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    return 'v1:sha256:' + [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-OwnerAdapterMember {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Value,
        [Parameter(Mandatory)][string]$Name,
        [switch]$Required
    )

    if ($Value.Contains($Name)) { return $Value[$Name] }
    if ($Required) { throw "Provider response was missing '$Name'." }
    return $null
}

function Assert-OwnerAdapterState {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Name
    )

    if ($Value -cnotin $script:OwnerAdapterStates) {
        throw "$Name must be complete, incomplete, or unknown."
    }
}

function Get-OwnerAdapterBoolean {
    param(
        [Parameter(Mandatory)][object]$Value,
        [Parameter(Mandatory)][string]$Name
    )

    if ($Value -isnot [bool]) { throw "$Name must be a Boolean." }
    return [bool]$Value
}

function Get-OwnerAdapterInt64 {
    param(
        [Parameter(Mandatory)][object]$Value,
        [Parameter(Mandatory)][string]$Name,
        [long]$Minimum = [long]::MinValue,
        [long]$Maximum = [long]::MaxValue
    )

    if ($Value -is [bool] -or
        $Value -isnot [byte] -and $Value -isnot [sbyte] -and
        $Value -isnot [short] -and $Value -isnot [ushort] -and
        $Value -isnot [int] -and $Value -isnot [uint] -and
        $Value -isnot [long] -and $Value -isnot [ulong]) {
        throw "$Name must be an integer."
    }
    $parsed = [long]$Value
    if ($parsed -lt $Minimum -or $parsed -gt $Maximum) {
        throw "$Name was outside its allowed range."
    }
    return $parsed
}

function ConvertTo-OwnerSafePath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    Assert-OwnerAdapterText -Value $Path -Name $Name -MaximumLength 1024
    $normalized = $Path.Replace('\', '/')
    if ($normalized.StartsWith('/') -or
        $normalized -match '^[A-Za-z]:' -or
        $normalized.Contains('//')) {
        throw "$Name must be a repository-relative path."
    }
    $segments = @($normalized.Split('/'))
    if ($segments.Count -eq 0 -or @($segments | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0) {
        throw "$Name contains an unsafe or ambiguous path segment."
    }
    return $normalized
}

function Test-OwnerIdentityResponse {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Response,
        [Parameter(Mandatory)][DevPilot.OwnerAdapters.OwnerAcquisitionRequest]$Request,
        [Parameter(Mandatory)][string]$Operation
    )

    if ((Get-OwnerAdapterMember -Value $Response -Name schemaVersion -Required) -ne 1) {
        throw "$Operation returned an unsupported schema version."
    }
    $expected = [ordered]@{
        repositoryId = $Request.RepositoryId
        projectId = $Request.ProjectId
        pullRequestId = $Request.PullRequestId
        sourceCommit = $Request.SourceCommit
        targetCommit = $Request.TargetCommit
        targetRef = $Request.TargetRef
    }
    foreach ($entry in $expected.GetEnumerator()) {
        $actual = Get-OwnerAdapterMember -Value $Response -Name $entry.Key -Required
        if ([string]$actual -cne [string]$entry.Value) {
            throw "$Operation returned stale or mixed subject identity."
        }
    }
}

function Add-OwnerAdapterDiagnostic {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Diagnostics,
        [Parameter(Mandatory)][DevPilot.OwnerAdapters.OwnerAdapterLimits]$Limits,
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Message
    )

    if ($Diagnostics.Count -ge $Limits.MaximumDiagnostics) { return }
    [void]$Diagnostics.Add([ordered]@{
            code = $Code
            message = $Message
        })
}

function New-OwnerAdapterLimits {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 254)][int]$MaximumFiles = 128,
        [ValidateRange(1, 134217728)][long]$MaximumBytes = 4194304,
        [ValidateRange(4, 2048)][int]$MaximumReads = 256,
        [ValidateRange(1, 16)][int]$MaximumDiagnostics = 8
    )

    return [DevPilot.OwnerAdapters.OwnerAdapterLimits]::new(
        $MaximumFiles,
        $MaximumBytes,
        $MaximumReads,
        $MaximumDiagnostics)
}

function New-OwnerDiscussionLimits {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 100)][int]$MaximumPages = 20,
        [ValidateRange(1, 200)][int]$PageSize = 100,
        [ValidateRange(1, 2000)][int]$MaximumThreads = 1000,
        [ValidateRange(1, 10000)][int]$MaximumComments = 5000,
        [ValidateRange(1, 16777216)][long]$MaximumBytes = 4194304
    )

    if ($MaximumThreads -gt ($MaximumPages * $PageSize)) {
        throw 'MaximumThreads cannot exceed the configured discussion page capacity.'
    }
    return [DevPilot.OwnerAdapters.OwnerDiscussionLimits]::new(
        $MaximumPages,
        $PageSize,
        $MaximumThreads,
        $MaximumComments,
        $MaximumBytes)
}

function New-OwnerAzureDevOpsReviewerIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Descriptor,
        [Parameter(Mandatory)][string]$UniqueName
    )

    $parsedId = [guid]::Empty
    if (-not [guid]::TryParseExact($Id, 'D', [ref]$parsedId) -or
        $parsedId -eq [guid]::Empty) {
        throw 'Azure DevOps reviewer Id must be a non-empty GUID in D format.'
    }
    Assert-OwnerAdapterText -Value $Descriptor -Name Descriptor -MaximumLength 512
    Assert-OwnerAdapterText -Value $UniqueName -Name UniqueName -MaximumLength 320
    if ($UniqueName -cnotmatch '^[^@\s]+@[^@\s]+$') {
        throw 'Azure DevOps reviewer UniqueName must be one exact UPN.'
    }
    return [DevPilot.OwnerAdapters.OwnerAzureDevOpsReviewerIdentity]::new(
        $parsedId.ToString('D').ToLowerInvariant(),
        $Descriptor,
        $UniqueName.ToLowerInvariant())
}

function Get-OwnerAzureDevOpsReviewerIdentityDigest {
    param(
        [Parameter(Mandatory)]
        [DevPilot.OwnerAdapters.OwnerAzureDevOpsReviewerIdentity]$ReviewerIdentity
    )

    $material = [ordered]@{}
    foreach ($field in $script:OwnerAzureDevOpsReviewerIdentityFields) {
        $propertyName = $field.Substring(0, 1).ToUpperInvariant() + $field.Substring(1)
        $material[$field] = $ReviewerIdentity.$propertyName
    }
    return Get-OwnerAdapterDigest -Value $material
}

function Get-OwnerAzureDevOpsDiscussionMappingDigest {
    [CmdletBinding()]
    param()
    return $script:OwnerAzureDevOpsDiscussionMappingDigest
}

function ConvertTo-OwnerAzureDevOpsThreadStatus {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return 'unknown'
    }
    $normalized = ([string]$Value).Trim().ToLowerInvariant()
    if ($script:OwnerAzureDevOpsThreadStatusMap.Contains($normalized)) {
        return [string]$script:OwnerAzureDevOpsThreadStatusMap[$normalized]
    }
    return $script:OwnerAzureDevOpsThreadStatusDefault
}

function ConvertTo-OwnerAzureDevOpsCommentType {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Comment,
        [Parameter(Mandatory)][long]$CommentId
    )

    $raw = Get-OwnerAdapterMember -Value $Comment -Name commentType
    if ($null -eq $raw) {
        throw "Azure DevOps REST comment '$CommentId' omitted commentType."
    }
    $normalized = ([string]$raw).Trim().ToLowerInvariant()
    if (-not $script:OwnerAzureDevOpsCommentTypeMap.Contains($normalized)) {
        throw "Azure DevOps REST comment '$CommentId' used unsupported commentType '$raw'."
    }
    $mapped = [string]$script:OwnerAzureDevOpsCommentTypeMap[$normalized]
    if ($mapped -ceq $script:OwnerAzureDevOpsCommentTypeDefault) {
        throw "Azure DevOps REST comment '$CommentId' used unknown commentType."
    }
    return $mapped
}

function ConvertTo-OwnerAzureDevOpsRestNode {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTime]) {
        return $Value.ToUniversalTime().ToString(
            'o',
            [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [DateTimeOffset]) {
        return $Value.ToUniversalTime().ToString(
            'o',
            [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [Collections.IDictionary]) {
        $map = [ordered]@{}
        foreach ($key in @($Value.Keys)) {
            $map[[string]$key] = ConvertTo-OwnerAzureDevOpsRestNode -Value $Value[$key]
        }
        return $map
    }
    if ($Value -is [Management.Automation.PSCustomObject]) {
        $map = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $map[$property.Name] = ConvertTo-OwnerAzureDevOpsRestNode -Value $property.Value
        }
        return $map
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        return , @($Value | ForEach-Object {
                ConvertTo-OwnerAzureDevOpsRestNode -Value $_
            })
    }
    return $Value
}

function ConvertTo-OwnerAzureDevOpsRawProvenance {
    param([Parameter(Mandatory)][object]$RawResponse)

    $copy = ConvertTo-OwnerAdapterCanonicalValue -Value (
        ConvertTo-OwnerAzureDevOpsRestNode -Value $RawResponse)
    if ($copy -isnot [Collections.IDictionary]) {
        throw 'Azure DevOps REST discussion response must be a dictionary.'
    }
    $rawThreads = @(Get-OwnerAdapterMember -Value $copy -Name value -Required)
    $threads = [Collections.Generic.List[object]]::new()
    foreach ($rawThread in @($rawThreads | Sort-Object {
                [long](Get-OwnerAdapterMember -Value $_ -Name id -Required)
            })) {
        if ($rawThread -isnot [Collections.IDictionary]) {
            throw 'Azure DevOps REST discussion value must contain only thread dictionaries.'
        }
        $thread = ConvertTo-OwnerAdapterCanonicalValue -Value $rawThread
        $comments = @(Get-OwnerAdapterMember -Value $thread -Name comments -Required)
        $thread['comments'] = @($comments | Sort-Object {
                [long](Get-OwnerAdapterMember -Value $_ -Name id -Required)
            })
        [void]$threads.Add($thread)
    }
    $copy['value'] = @($threads)
    return $copy
}

function ConvertTo-OwnerAzureDevOpsDiscussionPage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Arguments,
        [Parameter(Mandatory)][object]$RawResponse,
        [Parameter(Mandatory)][object]$CurrentIteration,
        [Parameter(Mandatory)]
        [DevPilot.OwnerAdapters.OwnerAzureDevOpsReviewerIdentity]$ReviewerIdentity
    )

    $argumentsMap = ConvertTo-OwnerAdapterCanonicalValue -Value $Arguments
    if ($argumentsMap -isnot [Collections.IDictionary]) {
        throw 'Azure DevOps discussion arguments must be a dictionary.'
    }
    $identity = [ordered]@{
        schemaVersion = 1
        repositoryId = [string](Get-OwnerAdapterMember -Value $argumentsMap -Name repositoryId -Required)
        projectId = [string](Get-OwnerAdapterMember -Value $argumentsMap -Name projectId -Required)
        pullRequestId = Get-OwnerAdapterInt64 -Value (
            Get-OwnerAdapterMember -Value $argumentsMap -Name pullRequestId -Required
        ) -Name pullRequestId -Minimum 1
        sourceCommit = [string](Get-OwnerAdapterMember -Value $argumentsMap -Name sourceCommit -Required)
        targetCommit = [string](Get-OwnerAdapterMember -Value $argumentsMap -Name targetCommit -Required)
        targetRef = [string](Get-OwnerAdapterMember -Value $argumentsMap -Name targetRef -Required)
    }
    foreach ($name in @('repositoryId', 'projectId', 'targetRef')) {
        Assert-OwnerAdapterText -Value ([string]$identity[$name]) -Name $name -MaximumLength 512
    }
    Assert-OwnerAdapterCommit -Value $identity.sourceCommit -Name sourceCommit
    Assert-OwnerAdapterCommit -Value $identity.targetCommit -Name targetCommit
    $pageOrdinal = Get-OwnerAdapterInt64 -Value (
        Get-OwnerAdapterMember -Value $argumentsMap -Name pageOrdinal -Required
    ) -Name pageOrdinal -Minimum 0 -Maximum 99
    $pageSize = Get-OwnerAdapterInt64 -Value (
        Get-OwnerAdapterMember -Value $argumentsMap -Name pageSize -Required
    ) -Name pageSize -Minimum 1 -Maximum 200
    $continuationValue = Get-OwnerAdapterMember -Value $argumentsMap -Name continuationToken
    $continuationToken = if ($null -eq $continuationValue -or
        [string]::IsNullOrEmpty([string]$continuationValue)) {
        $null
    }
    else {
        $token = [string]$continuationValue
        Assert-OwnerAdapterText -Value $token -Name continuationToken -MaximumLength 512
        $token
    }
    $pageOffset = $pageOrdinal * $pageSize
    if (($pageOrdinal -eq 0 -and $null -ne $continuationToken) -or
        ($pageOrdinal -gt 0 -and
            $continuationToken -cne "$($script:OwnerAzureDevOpsPagingPrefix)$pageOffset")) {
        throw 'Azure DevOps discussion continuation token did not match the requested page ordinal.'
    }

    $iterationMap = ConvertTo-OwnerAdapterCanonicalValue -Value (
        ConvertTo-OwnerAzureDevOpsRestNode -Value $CurrentIteration)
    if ($iterationMap -isnot [Collections.IDictionary]) {
        throw 'Azure DevOps current iteration must be a dictionary.'
    }
    $iterationId = Get-OwnerAdapterInt64 -Value (
        Get-OwnerAdapterMember -Value $iterationMap -Name id -Required
    ) -Name currentIteration.id -Minimum 1 -Maximum ([int]::MaxValue)
    $iterationSource = [string](Get-OwnerAdapterMember -Value $iterationMap -Name sourceCommit -Required)
    $iterationTarget = [string](Get-OwnerAdapterMember -Value $iterationMap -Name targetCommit -Required)
    Assert-OwnerAdapterCommit -Value $iterationSource -Name currentIteration.sourceCommit
    Assert-OwnerAdapterCommit -Value $iterationTarget -Name currentIteration.targetCommit
    if ($iterationSource -cne $identity.sourceCommit -or
        $iterationTarget -cne $identity.targetCommit) {
        throw 'Azure DevOps current iteration did not match the bound source and target commits.'
    }

    $rawCanonical = ConvertTo-OwnerAzureDevOpsRawProvenance -RawResponse $RawResponse
    $rawMap = $rawCanonical
    $rawProvenanceDigest = Get-OwnerAdapterDigest -Value $rawCanonical
    $rawThreads = @(Get-OwnerAdapterMember -Value $rawMap -Name value -Required)
    $declaredCount = Get-OwnerAdapterInt64 -Value (
        Get-OwnerAdapterMember -Value $rawMap -Name count -Required
    ) -Name discussion.count -Minimum 0 `
        -Maximum $script:OwnerAzureDevOpsMaximumRestThreads
    if ($declaredCount -ne $rawThreads.Count) {
        throw 'Azure DevOps discussion response count did not match its full value array.'
    }
    $orderedRawThreads = @($rawThreads | Sort-Object {
            [long](Get-OwnerAdapterMember -Value $_ -Name id -Required)
        })
    $pageRawThreads = @($orderedRawThreads | Select-Object -Skip $pageOffset -First $pageSize)
    if ($pageOffset -gt $rawThreads.Count -or
        ($pageOffset -lt $rawThreads.Count -and $pageRawThreads.Count -eq 0)) {
        throw 'Azure DevOps discussion page ordinal was outside the full REST response.'
    }
    $reviewerIdentityDigest = Get-OwnerAzureDevOpsReviewerIdentityDigest `
        -ReviewerIdentity $ReviewerIdentity
    $seenThreads = [Collections.Generic.HashSet[long]]::new()
    $normalizedThreads = [Collections.Generic.List[object]]::new()
    foreach ($rawThread in $pageRawThreads) {
        if ($rawThread -isnot [Collections.IDictionary]) {
            $rawThread = ConvertTo-OwnerAdapterCanonicalValue -Value $rawThread
        }
        $threadId = Get-OwnerAdapterInt64 -Value (
            Get-OwnerAdapterMember -Value $rawThread -Name id -Required
        ) -Name thread.id -Minimum 1 -Maximum ([int]::MaxValue)
        if (-not $seenThreads.Add($threadId)) {
            throw "Azure DevOps discussion page repeated thread '$threadId'."
        }
        $threadDeletedValue = Get-OwnerAdapterMember -Value $rawThread -Name isDeleted
        $threadDeleted = if ($null -eq $threadDeletedValue) {
            $false
        }
        else {
            Get-OwnerAdapterBoolean -Value $threadDeletedValue -Name thread.isDeleted
        }
        $status = ConvertTo-OwnerAzureDevOpsThreadStatus -Value (
            Get-OwnerAdapterMember -Value $rawThread -Name status
        )
        $threadContext = Get-OwnerAdapterMember -Value $rawThread -Name threadContext
        $anchor = $null
        $hasFileContext = $false
        if ($null -ne $threadContext) {
            if ($threadContext -isnot [Collections.IDictionary]) {
                throw "Azure DevOps thread '$threadId' threadContext must be a dictionary."
            }
            $filePath = [string](Get-OwnerAdapterMember -Value $threadContext -Name filePath)
            $hasFileContext = -not [string]::IsNullOrWhiteSpace($filePath)
            $rightStart = Get-OwnerAdapterMember -Value $threadContext -Name rightFileStart
            if ($hasFileContext -and
                $rightStart -is [Collections.IDictionary]) {
                $lineValue = Get-OwnerAdapterMember -Value $rightStart -Name line
                if ($null -ne $lineValue) {
                    $line = Get-OwnerAdapterInt64 -Value $lineValue -Name anchor.line `
                        -Minimum 1 -Maximum ([int]::MaxValue)
                    $anchor = [ordered]@{
                        path = ConvertTo-OwnerSafePath -Path $filePath.TrimStart('/') -Name anchor.path
                        line = $line
                    }
                }
            }
        }

        $contextState = if ($hasFileContext) { 'ambiguous' } else { 'notApplicable' }
        $threadSourceCommit = $null
        $isOutdated = $false
        if ($null -ne $anchor) {
            $contextState = 'ambiguous'
            $pullRequestContext = Get-OwnerAdapterMember -Value $rawThread -Name pullRequestThreadContext
            if ($pullRequestContext -is [Collections.IDictionary]) {
                $iterationContext = Get-OwnerAdapterMember -Value $pullRequestContext -Name iterationContext
                $trackingValue = Get-OwnerAdapterMember -Value $pullRequestContext -Name changeTrackingId
                if ($iterationContext -is [Collections.IDictionary] -and
                    $null -ne $trackingValue) {
                    $secondValue = Get-OwnerAdapterMember -Value $iterationContext `
                        -Name secondComparingIteration
                    try {
                        $trackingId = Get-OwnerAdapterInt64 -Value $trackingValue `
                            -Name changeTrackingId -Minimum 1 -Maximum ([int]::MaxValue)
                        $secondIteration = Get-OwnerAdapterInt64 -Value $secondValue `
                            -Name secondComparingIteration -Minimum 1 -Maximum ([int]::MaxValue)
                        [void]$trackingId
                        if ($secondIteration -eq $iterationId) {
                            $contextState = 'current'
                            $threadSourceCommit = $identity.sourceCommit
                        }
                        elseif ($secondIteration -lt $iterationId) {
                            $contextState = 'outdated'
                            $isOutdated = $true
                        }
                    }
                    catch {
                        $contextState = 'ambiguous'
                    }
                }
            }
        }

        $seenComments = [Collections.Generic.HashSet[long]]::new()
        $comments = [Collections.Generic.List[object]]::new()
        foreach ($rawComment in @(
                @(Get-OwnerAdapterMember -Value $rawThread -Name comments -Required) |
                    Sort-Object {
                        [long](Get-OwnerAdapterMember -Value $_ -Name id -Required)
                    }
            )) {
            if ($rawComment -isnot [Collections.IDictionary]) {
                $rawComment = ConvertTo-OwnerAdapterCanonicalValue -Value $rawComment
            }
            $commentId = Get-OwnerAdapterInt64 -Value (
                Get-OwnerAdapterMember -Value $rawComment -Name id -Required
            ) -Name comment.id -Minimum 1 -Maximum ([int]::MaxValue)
            if (-not $seenComments.Add($commentId)) {
                throw "Azure DevOps thread '$threadId' repeated comment '$commentId'."
            }
            $commentType = ConvertTo-OwnerAzureDevOpsCommentType `
                -Comment $rawComment -CommentId $commentId
            $deletedValue = Get-OwnerAdapterMember -Value $rawComment -Name isDeleted
            $commentDeleted = if ($null -eq $deletedValue) {
                $false
            }
            else {
                Get-OwnerAdapterBoolean -Value $deletedValue -Name comment.isDeleted
            }
            $contentValue = Get-OwnerAdapterMember -Value $rawComment -Name content
            if ($null -eq $contentValue -and -not $commentDeleted) {
                throw "Azure DevOps non-deleted comment '$commentId' omitted content."
            }
            $body = if ($null -eq $contentValue) { '' } else { [string]$contentValue }
            if ($body.Length -gt 65536 -or $body -match '\x00') {
                throw "Azure DevOps comment '$commentId' body is unsafe or unbounded."
            }
            $author = Get-OwnerAdapterMember -Value $rawComment -Name author
            $reviewerOwned = $false
            $reviewerIdentityState = 'ambiguous'
            if ($author -is [Collections.IDictionary]) {
                $authorId = [string](Get-OwnerAdapterMember -Value $author -Name id)
                $authorDescriptor = [string](Get-OwnerAdapterMember -Value $author -Name descriptor)
                $authorUniqueName = [string](Get-OwnerAdapterMember -Value $author -Name uniqueName)
                if (-not [string]::IsNullOrWhiteSpace($authorId) -and
                    -not [string]::IsNullOrWhiteSpace($authorDescriptor) -and
                    -not [string]::IsNullOrWhiteSpace($authorUniqueName)) {
                    $reviewerOwned = (
                        $authorId -ieq $ReviewerIdentity.Id -and
                        $authorDescriptor -ceq $ReviewerIdentity.Descriptor -and
                        $authorUniqueName -ieq $ReviewerIdentity.UniqueName
                    )
                    $reviewerIdentityState = if ($reviewerOwned) {
                        'matched'
                    }
                    else {
                        'foreign'
                    }
                }
            }
            [void]$comments.Add([ordered]@{
                    commentId = $commentId
                    commentType = $commentType
                    isDeleted = $commentDeleted
                    reviewerOwned = $reviewerOwned
                    reviewerIdentityState = $reviewerIdentityState
                    body = $body
                    bodyDigest = Get-OwnerAdapterDigest -Value $body
                })
        }
        [void]$normalizedThreads.Add([ordered]@{
                threadId = $threadId
                status = $status
                isDeleted = $threadDeleted
                isOutdated = $isOutdated
                sourceCommit = $threadSourceCommit
                contextState = $contextState
                anchor = $anchor
                comments = @($comments)
            })
    }

    $nextOffset = $pageOffset + $pageRawThreads.Count
    $nextToken = if ($nextOffset -lt $rawThreads.Count) {
        "$($script:OwnerAzureDevOpsPagingPrefix)$nextOffset"
    }
    else {
        $null
    }
    $typedMaterial = [ordered]@{
        semantics = $script:OwnerAzureDevOpsDiscussionSemantics
        mappingDigest = $script:OwnerAzureDevOpsDiscussionMappingDigest
        reviewerIdentityDigest = $reviewerIdentityDigest
        identity = $identity
        pageOrdinal = $pageOrdinal
        continuationToken = $continuationToken
        nextToken = $nextToken
        currentIterationId = $iterationId
        threads = @($normalizedThreads)
    }
    $sourceDigest = Get-OwnerAdapterDigest -Value $typedMaterial
    return [ordered]@{} + $identity + [ordered]@{
        pageOrdinal = $pageOrdinal
        state = 'complete'
        sourceDigest = $sourceDigest
        rawProvenanceDigest = $rawProvenanceDigest
        mappingDigest = $script:OwnerAzureDevOpsDiscussionMappingDigest
        reviewerIdentityDigest = $reviewerIdentityDigest
        currentIterationId = $iterationId
        nextToken = $nextToken
        threads = @($normalizedThreads)
    }
}

function New-OwnerAcquisitionContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][ValidateRange(1, [long]::MaxValue)][long]$PullRequestId,
        [Parameter(Mandatory)][string]$SourceCommit,
        [Parameter(Mandatory)][string]$TargetCommit,
        [Parameter(Mandatory)][string]$TargetRef,
        [Parameter(Mandatory)][string]$RuleRepositoryId,
        [Parameter(Mandatory)][string]$RulePath,
        [Parameter(Mandatory)][string]$RuleCommit,
        [Parameter(Mandatory)][string]$RuleSection,
        [Parameter(Mandatory)][string]$RuleHash,
        [Parameter(Mandatory)][ValidateRange(0, [long]::MaxValue)][long]$RuleLength,
        [Parameter(Mandatory)][string]$ConfigId,
        [Parameter(Mandatory)][string]$ConfigDigest,
        [Parameter(Mandatory)][string]$CapabilityId,
        [Parameter(Mandatory)][string]$CapabilityDigest,
        [DevPilot.OwnerAdapters.OwnerAdapterLimits]$Limits = (New-OwnerAdapterLimits)
    )

    if ($Limits.MaximumFiles -lt 1 -or $Limits.MaximumFiles -gt 254 -or
        $Limits.MaximumBytes -lt 1 -or $Limits.MaximumBytes -gt 134217728 -or
        $Limits.MaximumReads -lt 4 -or $Limits.MaximumReads -gt 2048 -or
        $Limits.MaximumDiagnostics -lt 1 -or $Limits.MaximumDiagnostics -gt 16) {
        throw 'Limits were outside the adapter contract bounds.'
    }
    foreach ($item in @(
            @{ Value = $RepositoryId; Name = 'RepositoryId'; Maximum = 256 }
            @{ Value = $ProjectId; Name = 'ProjectId'; Maximum = 256 }
            @{ Value = $TargetRef; Name = 'TargetRef'; Maximum = 512 }
            @{ Value = $RuleRepositoryId; Name = 'RuleRepositoryId'; Maximum = 256 }
            @{ Value = $RuleSection; Name = 'RuleSection'; Maximum = 256 }
            @{ Value = $ConfigId; Name = 'ConfigId'; Maximum = 256 }
            @{ Value = $CapabilityId; Name = 'CapabilityId'; Maximum = 256 }
        )) {
        Assert-OwnerAdapterText -Value $item.Value -Name $item.Name -MaximumLength $item.Maximum
    }
    $safeRulePath = ConvertTo-OwnerSafePath -Path $RulePath -Name RulePath
    Assert-OwnerAdapterCommit -Value $SourceCommit -Name SourceCommit
    Assert-OwnerAdapterCommit -Value $TargetCommit -Name TargetCommit
    Assert-OwnerAdapterCommit -Value $RuleCommit -Name RuleCommit
    Assert-OwnerAdapterDigest -Value $RuleHash -Name RuleHash
    Assert-OwnerAdapterDigest -Value $ConfigDigest -Name ConfigDigest
    Assert-OwnerAdapterDigest -Value $CapabilityDigest -Name CapabilityDigest
    if ($RuleLength -gt $Limits.MaximumBytes) {
        throw 'RuleLength cannot exceed the configured byte cap.'
    }
    if ($TargetRef -cnotmatch '^refs/(heads|tags)/[^~^:?*\[\\]+$') {
        throw 'TargetRef must be a full safe refs/heads or refs/tags name.'
    }

    $request = [DevPilot.OwnerAdapters.OwnerAcquisitionRequest]::new(
        $RepositoryId,
        $ProjectId,
        $PullRequestId,
        $SourceCommit,
        $TargetCommit,
        $TargetRef,
        $RuleRepositoryId,
        $safeRulePath,
        $RuleCommit,
        $RuleSection,
        $RuleHash,
        $RuleLength,
        $ConfigId,
        $ConfigDigest,
        $CapabilityId,
        $CapabilityDigest)

    $subjectKey = 'owner-subject-v1:' + (Get-OwnerAdapterDigest -Value ([ordered]@{
                repositoryId = $RepositoryId
                projectId = $ProjectId
                pullRequestId = $PullRequestId
            }))
    $headKey = 'owner-head-v1:' + (Get-OwnerAdapterDigest -Value ([ordered]@{
                sourceCommit = $SourceCommit
                targetCommit = $TargetCommit
                targetRef = $TargetRef
            }))
    $ruleKey = 'owner-rule-v1:' + (Get-OwnerAdapterDigest -Value ([ordered]@{
                repositoryId = $RuleRepositoryId
                path = $safeRulePath
                commit = $RuleCommit
                section = $RuleSection
                hash = $RuleHash
                length = $RuleLength
            }))
    $capabilityKey = 'owner-capability-v1:' + (Get-OwnerAdapterDigest -Value ([ordered]@{
                configId = $ConfigId
                configDigest = $ConfigDigest
                capabilityId = $CapabilityId
                capabilityDigest = $CapabilityDigest
                acquisitionLimits = [ordered]@{
                    maximumFiles = $Limits.MaximumFiles
                    maximumBytes = $Limits.MaximumBytes
                    maximumReads = $Limits.MaximumReads
                    maximumDiagnostics = $Limits.MaximumDiagnostics
                }
            }))
    $binding = New-OwnerPipelineBinding `
        -SubjectKey $subjectKey `
        -HeadKey $headKey `
        -RuleKey $ruleKey `
        -CapabilityKey $capabilityKey `
        -AuthorizationKey 'authority:preview-only'

    $contract = [pscustomobject][ordered]@{
        SchemaVersion = 1
        Request = $request
        Limits = $Limits
        Binding = $binding
    }
    $contract.PSTypeNames.Insert(0, 'DevPilot.OwnerAdapters.AcquisitionContract')
    return $contract
}

function New-OwnerReadOnlyProviderAdapter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Handler
    )

    Assert-OwnerAdapterText -Value $Name -Name Name -MaximumLength 128
    $provider = [pscustomobject][ordered]@{
        Name = $Name
        Operations = [string[]]$script:OwnerProviderOperations
        Handler = $Handler
        WriteAllowed = $false
    }
    $provider.PSTypeNames.Insert(0, 'DevPilot.OwnerAdapters.ReadOnlyProvider')
    return $provider
}

function New-OwnerAzureDevOpsReadOnlyProviderAdapter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]
        [DevPilot.OwnerAdapters.OwnerAzureDevOpsReviewerIdentity]$ReviewerIdentity,
        [Parameter(Mandatory)][scriptblock]$Handler
    )

    $provider = New-OwnerReadOnlyProviderAdapter -Name $Name -Handler $Handler
    $provider | Add-Member -NotePropertyName AzureDevOpsDiscussionMappingDigest `
        -NotePropertyValue $script:OwnerAzureDevOpsDiscussionMappingDigest
    $provider | Add-Member -NotePropertyName AzureDevOpsReviewerIdentityDigest `
        -NotePropertyValue (
            Get-OwnerAzureDevOpsReviewerIdentityDigest -ReviewerIdentity $ReviewerIdentity
        )
    return $provider
}

function Test-OwnerAcquisitionContract {
    param([Parameter(Mandatory)][object]$Contract)

    if ($Contract -isnot [pscustomobject] -or
        $Contract.PSTypeNames -cnotcontains 'DevPilot.OwnerAdapters.AcquisitionContract' -or
        $Contract.Request -isnot [DevPilot.OwnerAdapters.OwnerAcquisitionRequest] -or
        $Contract.Limits -isnot [DevPilot.OwnerAdapters.OwnerAdapterLimits] -or
        $Contract.Binding -isnot [DevPilot.OwnerPipeline.OwnerPipelineBinding]) {
        throw 'Expected an acquisition contract created by New-OwnerAcquisitionContract.'
    }
    $request = $Contract.Request
    $expected = New-OwnerAcquisitionContract `
        -RepositoryId $request.RepositoryId `
        -ProjectId $request.ProjectId `
        -PullRequestId $request.PullRequestId `
        -SourceCommit $request.SourceCommit `
        -TargetCommit $request.TargetCommit `
        -TargetRef $request.TargetRef `
        -RuleRepositoryId $request.RuleRepositoryId `
        -RulePath $request.RulePath `
        -RuleCommit $request.RuleCommit `
        -RuleSection $request.RuleSection `
        -RuleHash $request.RuleHash `
        -RuleLength $request.RuleLength `
        -ConfigId $request.ConfigId `
        -ConfigDigest $request.ConfigDigest `
        -CapabilityId $request.CapabilityId `
        -CapabilityDigest $request.CapabilityDigest `
        -Limits $Contract.Limits
    if ($Contract.Binding.BindingId -cne $expected.Binding.BindingId) {
        throw 'Acquisition contract binding did not match its immutable request and limits.'
    }
}

function Test-OwnerProviderAdapter {
    param([Parameter(Mandatory)][object]$Provider)

    if ($Provider -isnot [pscustomobject] -or
        $Provider.PSTypeNames -cnotcontains 'DevPilot.OwnerAdapters.ReadOnlyProvider' -or
        $Provider.Handler -isnot [scriptblock] -or
        $Provider.WriteAllowed -ne $false -or
        @($Provider.Operations).Count -ne $script:OwnerProviderOperations.Count -or
        (Compare-Object -CaseSensitive @($Provider.Operations) $script:OwnerProviderOperations)) {
        throw 'Expected an unchanged read-only provider created by New-OwnerReadOnlyProviderAdapter.'
    }
}

function Invoke-OwnerProviderRead {
    param(
        [Parameter(Mandatory)][object]$Provider,
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][Collections.IDictionary]$Arguments,
        [Parameter(Mandatory)][DevPilot.OwnerAdapters.OwnerAdapterLimits]$Limits,
        [Parameter(Mandatory)][ref]$ReadCount
    )

    if ($Operation -cnotin $script:OwnerProviderOperations) {
        throw "Provider operation '$Operation' is not read-only adapter surface."
    }
    if ($ReadCount.Value -ge $Limits.MaximumReads) {
        throw 'Read-only provider read cap exhausted.'
    }
    $ReadCount.Value++
    $handler = $Provider.Handler
    $values = @(& $handler $Operation ([pscustomobject](ConvertTo-OwnerAdapterCanonicalValue -Value $Arguments)))
    if ($values.Count -ne 1 -or $values[0] -isnot [Collections.IDictionary]) {
        throw "Provider operation '$Operation' must return exactly one dictionary."
    }
    return ConvertTo-OwnerAdapterCanonicalValue -Value $values[0]
}

function ConvertTo-OwnerDiscussionStatus {
    param([Parameter(Mandatory)][string]$Value)

    $normalized = $Value.Trim().ToLowerInvariant()
    if ($normalized -cnotin $script:OwnerDiscussionStates) {
        throw "Discussion thread status '$Value' is not supported."
    }
    return $normalized
}

function ConvertTo-OwnerDiscussionThread {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Thread,
        [Parameter(Mandatory)][DevPilot.OwnerAdapters.OwnerDiscussionLimits]$Limits,
        [Parameter(Mandatory)][ref]$CommentCount,
        [Parameter(Mandatory)][ref]$ByteCount
    )

    $threadId = Get-OwnerAdapterInt64 -Value (
        Get-OwnerAdapterMember -Value $Thread -Name threadId -Required
    ) -Name threadId -Minimum 1 -Maximum ([int]::MaxValue)
    $status = ConvertTo-OwnerDiscussionStatus -Value (
        [string](Get-OwnerAdapterMember -Value $Thread -Name status -Required)
    )
    $isDeleted = Get-OwnerAdapterBoolean -Value (
        Get-OwnerAdapterMember -Value $Thread -Name isDeleted -Required
    ) -Name isDeleted
    $isOutdated = Get-OwnerAdapterBoolean -Value (
        Get-OwnerAdapterMember -Value $Thread -Name isOutdated -Required
    ) -Name isOutdated

    $sourceCommitValue = Get-OwnerAdapterMember -Value $Thread -Name sourceCommit
    $sourceCommit = if ($null -eq $sourceCommitValue -or
        [string]::IsNullOrWhiteSpace([string]$sourceCommitValue)) {
        $null
    }
    else {
        $value = [string]$sourceCommitValue
        Assert-OwnerAdapterCommit -Value $value -Name sourceCommit
        $value
    }
    $contextStateValue = Get-OwnerAdapterMember -Value $Thread -Name contextState

    $anchorValue = Get-OwnerAdapterMember -Value $Thread -Name anchor
    $anchor = $null
    if ($null -ne $anchorValue) {
        if ($anchorValue -isnot [Collections.IDictionary]) {
            throw 'Discussion thread anchor must be a dictionary or null.'
        }
        $anchor = [ordered]@{
            path = ConvertTo-OwnerSafePath -Path (
                [string](Get-OwnerAdapterMember -Value $anchorValue -Name path -Required)
            ) -Name anchor.path
            line = Get-OwnerAdapterInt64 -Value (
                Get-OwnerAdapterMember -Value $anchorValue -Name line -Required
            ) -Name anchor.line -Minimum 1 -Maximum ([int]::MaxValue)
        }
    }
    $contextState = if ($null -eq $contextStateValue -or
        [string]::IsNullOrWhiteSpace([string]$contextStateValue)) {
        if ($isOutdated) { 'outdated' }
        elseif ($null -ne $sourceCommit) { 'current' }
        elseif ($null -ne $anchor) { 'ambiguous' }
        else { 'notApplicable' }
    }
    else {
        [string]$contextStateValue
    }
    if ($contextState -cnotin $script:OwnerAzureDevOpsContextStates) {
        throw "Discussion thread '$threadId' has unsupported contextState '$contextState'."
    }
    if (($contextState -ceq 'current' -and (
                $null -eq $anchor -or $null -eq $sourceCommit -or $isOutdated
            )) -or
        ($contextState -ceq 'outdated' -and (
                $null -eq $anchor -or $null -ne $sourceCommit -or -not $isOutdated
            )) -or
        ($contextState -ceq 'ambiguous' -and (
                $null -ne $sourceCommit -or $isOutdated
            )) -or
        ($contextState -ceq 'notApplicable' -and (
                $null -ne $anchor -or $null -ne $sourceCommit -or $isOutdated
            ))) {
        $contextState = 'ambiguous'
        $sourceCommit = $null
        $isOutdated = $false
    }

    $comments = [Collections.Generic.List[object]]::new()
    $seenComments = [Collections.Generic.HashSet[long]]::new()
    foreach ($comment in @(Get-OwnerAdapterMember -Value $Thread -Name comments -Required)) {
        if ($comment -isnot [Collections.IDictionary]) {
            throw 'Discussion threads must contain only comment dictionaries.'
        }
        $commentId = Get-OwnerAdapterInt64 -Value (
            Get-OwnerAdapterMember -Value $comment -Name commentId -Required
        ) -Name commentId -Minimum 1 -Maximum ([int]::MaxValue)
        if (-not $seenComments.Add($commentId)) {
            throw "Discussion thread '$threadId' repeated comment '$commentId'."
        }
        $commentCount.Value++
        if ($CommentCount.Value -gt $Limits.MaximumComments) {
            throw 'Discussion acquisition exceeded the configured comment cap.'
        }
        $commentDeleted = Get-OwnerAdapterBoolean -Value (
            Get-OwnerAdapterMember -Value $comment -Name isDeleted -Required
        ) -Name comment.isDeleted
        $reviewerOwned = Get-OwnerAdapterBoolean -Value (
            Get-OwnerAdapterMember -Value $comment -Name reviewerOwned -Required
        ) -Name comment.reviewerOwned
        $identityStateValue = Get-OwnerAdapterMember -Value $comment `
            -Name reviewerIdentityState
        $reviewerIdentityState = if ($null -eq $identityStateValue -or
            [string]::IsNullOrWhiteSpace([string]$identityStateValue)) {
            if ($reviewerOwned) { 'matched' } else { 'foreign' }
        }
        else {
            [string]$identityStateValue
        }
        if ($reviewerIdentityState -cnotin $script:OwnerAzureDevOpsReviewerIdentityStates -or
            ($reviewerOwned -and $reviewerIdentityState -cne 'matched') -or
            (-not $reviewerOwned -and $reviewerIdentityState -ceq 'matched')) {
            throw "Discussion comment '$commentId' reviewer identity state is inconsistent."
        }
        $commentType = [string](Get-OwnerAdapterMember -Value $comment -Name commentType -Required)
        if ($commentType -cnotin @('text', 'system')) {
            throw "Discussion comment '$commentId' has unsupported type '$commentType'."
        }
        $body = [string](Get-OwnerAdapterMember -Value $comment -Name body -Required)
        if ($body.Length -gt 65536 -or $body -match '\x00') {
            throw "Discussion comment '$commentId' body is unsafe or unbounded."
        }
        $bodyBytes = [Text.Encoding]::UTF8.GetByteCount($body)
        $byteCount.Value += $bodyBytes
        if ($ByteCount.Value -gt $Limits.MaximumBytes) {
            throw 'Discussion acquisition exceeded the configured UTF-8 byte cap.'
        }
        $declaredBodyDigest = [string](Get-OwnerAdapterMember -Value $comment -Name bodyDigest -Required)
        Assert-OwnerAdapterDigest -Value $declaredBodyDigest -Name comment.bodyDigest
        $actualBodyDigest = Get-OwnerAdapterDigest -Value $body
        if ($actualBodyDigest -cne $declaredBodyDigest) {
            throw "Discussion comment '$commentId' body digest did not match its text."
        }
        [void]$comments.Add([ordered]@{
                commentId = $commentId
                commentType = $commentType
                isDeleted = $commentDeleted
                reviewerOwned = $reviewerOwned
                reviewerIdentityState = $reviewerIdentityState
                body = $body
                bodyDigest = $actualBodyDigest
            })
    }

    return [ordered]@{
        threadId = $threadId
        status = $status
        isDeleted = $isDeleted
        isOutdated = $isOutdated
        sourceCommit = $sourceCommit
        contextState = $contextState
        anchor = $anchor
        comments = @($comments | Sort-Object { [long]$_.commentId })
    }
}

function Get-OwnerDiscussionSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Contract,
        [Parameter(Mandatory)][object]$Provider,
        [DevPilot.OwnerAdapters.OwnerDiscussionLimits]$Limits = (New-OwnerDiscussionLimits),
        [switch]$RequireAzureDevOpsProvenance
    )

    Test-OwnerAcquisitionContract -Contract $Contract
    Test-OwnerProviderAdapter -Provider $Provider
    $expectedAzureMappingDigest = $null
    $expectedAzureReviewerDigest = $null
    if ($RequireAzureDevOpsProvenance) {
        $mappingProperty = $Provider.PSObject.Properties[
            'AzureDevOpsDiscussionMappingDigest'
        ]
        $reviewerProperty = $Provider.PSObject.Properties[
            'AzureDevOpsReviewerIdentityDigest'
        ]
        if ($null -eq $mappingProperty -or $null -eq $reviewerProperty) {
            throw 'Azure DevOps discussion acquisition requires a reviewer-bound provider adapter.'
        }
        $expectedAzureMappingDigest = [string]$mappingProperty.Value
        $expectedAzureReviewerDigest = [string]$reviewerProperty.Value
        Assert-OwnerAdapterDigest -Value $expectedAzureMappingDigest `
            -Name AzureDevOpsDiscussionMappingDigest
        Assert-OwnerAdapterDigest -Value $expectedAzureReviewerDigest `
            -Name AzureDevOpsReviewerIdentityDigest
        if ($expectedAzureMappingDigest -cne
            $script:OwnerAzureDevOpsDiscussionMappingDigest) {
            throw 'Azure DevOps provider adapter used an unsupported discussion mapping.'
        }
    }
    if ($Limits.MaximumPages -lt 1 -or $Limits.MaximumPages -gt 100 -or
        $Limits.PageSize -lt 1 -or $Limits.PageSize -gt 200 -or
        $Limits.MaximumThreads -lt 1 -or $Limits.MaximumThreads -gt 2000 -or
        $Limits.MaximumComments -lt 1 -or $Limits.MaximumComments -gt 10000 -or
        $Limits.MaximumBytes -lt 1 -or $Limits.MaximumBytes -gt 16777216 -or
        $Limits.MaximumThreads -gt ($Limits.MaximumPages * $Limits.PageSize)) {
        throw 'Discussion limits were outside the adapter contract bounds.'
    }

    $request = $Contract.Request
    $baseArguments = [ordered]@{
        repositoryId = $request.RepositoryId
        projectId = $request.ProjectId
        pullRequestId = $request.PullRequestId
        sourceCommit = $request.SourceCommit
        targetCommit = $request.TargetCommit
        targetRef = $request.TargetRef
    }
    $readCount = 0
    $pageOrdinal = 0
    $token = $null
    $tokens = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $threads = [Collections.Generic.List[object]]::new()
    $seenThreads = [Collections.Generic.HashSet[long]]::new()
    $sourceDigests = [Collections.Generic.List[string]]::new()
    $rawProvenanceDigests = [Collections.Generic.List[string]]::new()
    $mappingDigest = $null
    $reviewerIdentityDigest = $null
    $currentIterationId = $null
    $expectedRawProvenanceDigest = $null
    $commentCount = 0
    $byteCount = 0L
    do {
        if ($pageOrdinal -ge $Limits.MaximumPages) {
            throw 'Discussion pagination exceeded the configured page cap.'
        }
        $requestedToken = $token
        $arguments = [ordered]@{}
        foreach ($entry in $baseArguments.GetEnumerator()) { $arguments[$entry.Key] = $entry.Value }
        $arguments['pageOrdinal'] = $pageOrdinal
        $arguments['pageSize'] = $Limits.PageSize
        $arguments['continuationToken'] = $token
        $page = Invoke-OwnerProviderRead -Provider $Provider -Operation GetDiscussionPage `
            -Arguments $arguments -Limits (
                [DevPilot.OwnerAdapters.OwnerAdapterLimits]::new(
                    1,
                    $Limits.MaximumBytes,
                    $Limits.MaximumPages,
                    1)
            ) -ReadCount ([ref]$readCount)
        Test-OwnerIdentityResponse -Response $page -Request $request -Operation GetDiscussionPage
        if ([int](Get-OwnerAdapterMember -Value $page -Name pageOrdinal -Required) -ne $pageOrdinal) {
            throw 'Discussion pagination returned a stale or ambiguous page ordinal.'
        }
        $pageState = [string](Get-OwnerAdapterMember -Value $page -Name state -Required)
        Assert-OwnerAdapterState -Value $pageState -Name discussion.state
        if ($pageState -cne 'complete') {
            throw 'Discussion pagination returned an incomplete or unknown page.'
        }
        $sourceDigest = [string](Get-OwnerAdapterMember -Value $page -Name sourceDigest -Required)
        Assert-OwnerAdapterDigest -Value $sourceDigest -Name discussion.sourceDigest
        [void]$sourceDigests.Add($sourceDigest)
        $pageRawDigest = Get-OwnerAdapterMember -Value $page -Name rawProvenanceDigest
        $pageMappingDigest = Get-OwnerAdapterMember -Value $page -Name mappingDigest
        $pageReviewerDigest = Get-OwnerAdapterMember -Value $page -Name reviewerIdentityDigest
        $pageIterationId = Get-OwnerAdapterMember -Value $page -Name currentIterationId
        $hasAzureProvenance = $null -ne $pageRawDigest -or
            $null -ne $pageMappingDigest -or
            $null -ne $pageReviewerDigest -or
            $null -ne $pageIterationId
        if ($RequireAzureDevOpsProvenance -or $hasAzureProvenance) {
            if ($null -eq $pageRawDigest -or $null -eq $pageMappingDigest -or
                $null -eq $pageReviewerDigest -or $null -eq $pageIterationId) {
                throw 'Azure DevOps discussion page omitted required provenance fields.'
            }
            $pageRawDigest = [string]$pageRawDigest
            $pageMappingDigest = [string]$pageMappingDigest
            $pageReviewerDigest = [string]$pageReviewerDigest
            Assert-OwnerAdapterDigest -Value $pageRawDigest -Name discussion.rawProvenanceDigest
            Assert-OwnerAdapterDigest -Value $pageMappingDigest -Name discussion.mappingDigest
            Assert-OwnerAdapterDigest -Value $pageReviewerDigest -Name discussion.reviewerIdentityDigest
            if ($pageMappingDigest -cne $script:OwnerAzureDevOpsDiscussionMappingDigest) {
                throw 'Azure DevOps discussion page used an unsupported mapping contract.'
            }
            if ($RequireAzureDevOpsProvenance -and (
                    $pageMappingDigest -cne $expectedAzureMappingDigest -or
                    $pageReviewerDigest -cne $expectedAzureReviewerDigest
                )) {
                throw 'Azure DevOps discussion page did not match the provider reviewer binding.'
            }
            $pageIterationId = Get-OwnerAdapterInt64 -Value $pageIterationId `
                -Name discussion.currentIterationId -Minimum 1 -Maximum ([int]::MaxValue)
            if ($null -eq $mappingDigest) {
                $mappingDigest = $pageMappingDigest
                $reviewerIdentityDigest = $pageReviewerDigest
                $currentIterationId = $pageIterationId
            }
            elseif ($mappingDigest -cne $pageMappingDigest -or
                $reviewerIdentityDigest -cne $pageReviewerDigest -or
                [long]$currentIterationId -ne [long]$pageIterationId) {
                throw 'Azure DevOps discussion pages disagreed on mapping, reviewer, or iteration provenance.'
            }
            if ($null -eq $expectedRawProvenanceDigest) {
                $expectedRawProvenanceDigest = $pageRawDigest
                [void]$rawProvenanceDigests.Add($pageRawDigest)
            }
            elseif ($expectedRawProvenanceDigest -cne $pageRawDigest) {
                throw 'Azure DevOps discussion pages came from different full REST responses.'
            }
        }
        $pageThreads = @(Get-OwnerAdapterMember -Value $page -Name threads -Required)
        if ($pageThreads.Count -gt $Limits.PageSize) {
            throw 'Discussion provider returned more threads than the requested page size.'
        }
        $pageNormalizedThreads = [Collections.Generic.List[object]]::new()
        foreach ($thread in $pageThreads) {
            if ($thread -isnot [Collections.IDictionary]) {
                throw 'Discussion pages must contain only thread dictionaries.'
            }
            $normalized = ConvertTo-OwnerDiscussionThread -Thread $thread -Limits $Limits `
                -CommentCount ([ref]$commentCount) -ByteCount ([ref]$byteCount)
            if (-not $seenThreads.Add([long]$normalized.threadId)) {
                throw "Discussion pagination repeated thread '$($normalized.threadId)'."
            }
            if ([string]$normalized.contextState -ceq 'current' -and
                [string]$normalized.sourceCommit -cne $request.SourceCommit) {
                throw "Current discussion thread '$($normalized.threadId)' did not bind the current source commit."
            }
            [void]$pageNormalizedThreads.Add($normalized)
            [void]$threads.Add($normalized)
            if ($threads.Count -gt $Limits.MaximumThreads) {
                throw 'Discussion acquisition exceeded the configured thread cap.'
            }
        }
        $nextTokenValue = Get-OwnerAdapterMember -Value $page -Name nextToken
        $nextToken = if ($null -eq $nextTokenValue -or
            [string]::IsNullOrEmpty([string]$nextTokenValue)) {
            $null
        }
        else {
            $next = [string]$nextTokenValue
            Assert-OwnerAdapterText -Value $next -Name discussion.nextToken -MaximumLength 512
            if ($pageThreads.Count -eq 0) {
                throw 'Non-final discussion pages cannot be empty.'
            }
            if (-not $tokens.Add($next)) {
                throw 'Discussion pagination repeated a continuation token.'
            }
            $next
        }
        if ($RequireAzureDevOpsProvenance -or $hasAzureProvenance) {
            $pageIdentity = [ordered]@{ schemaVersion = 1 }
            foreach ($entry in $baseArguments.GetEnumerator()) {
                $pageIdentity[$entry.Key] = $entry.Value
            }
            $expectedSourceDigest = Get-OwnerAdapterDigest -Value ([ordered]@{
                    semantics = $script:OwnerAzureDevOpsDiscussionSemantics
                    mappingDigest = $pageMappingDigest
                    reviewerIdentityDigest = $pageReviewerDigest
                    identity = $pageIdentity
                    pageOrdinal = $pageOrdinal
                    continuationToken = $requestedToken
                    nextToken = $nextToken
                    currentIterationId = $pageIterationId
                    threads = @($pageNormalizedThreads)
                })
            if ($sourceDigest -cne $expectedSourceDigest) {
                throw 'Azure DevOps discussion page source digest did not match its typed content.'
            }
        }
        $token = $nextToken
        $pageOrdinal++
    } while ($null -ne $token)

    $orderedThreads = @($threads | Sort-Object { [long]$_.threadId })
    $digestMaterial = [ordered]@{
        schemaVersion = 1
        identity = $baseArguments
        limits = [ordered]@{
            maximumPages = $Limits.MaximumPages
            pageSize = $Limits.PageSize
            maximumThreads = $Limits.MaximumThreads
            maximumComments = $Limits.MaximumComments
            maximumBytes = $Limits.MaximumBytes
        }
        sourceDigests = @($sourceDigests)
        rawProvenanceDigests = @($rawProvenanceDigests)
        mappingDigest = $(if ($null -eq $mappingDigest) { 'unknown' } else { $mappingDigest })
        reviewerIdentityDigest = $(if ($null -eq $reviewerIdentityDigest) {
                'unknown'
            }
            else {
                $reviewerIdentityDigest
            })
        currentIterationId = $(if ($null -eq $currentIterationId) {
                'unknown'
            }
            else {
                $currentIterationId
            })
        threads = $orderedThreads
    }
    $digest = Get-OwnerAdapterDigest -Value $digestMaterial
    $snapshot = [DevPilot.OwnerAdapters.OwnerDiscussionSnapshot]::new(
        'complete',
        'complete',
        $pageOrdinal,
        $orderedThreads.Count,
        $commentCount,
        $byteCount,
        $digest,
        [string[]]@($sourceDigests),
        [object[]]$orderedThreads)
    $snapshot | Add-Member -NotePropertyName RawProvenanceDigests `
        -NotePropertyValue ([string[]]@($rawProvenanceDigests))
    $snapshot | Add-Member -NotePropertyName MappingDigest `
        -NotePropertyValue $(if ($null -eq $mappingDigest) { 'unknown' } else { $mappingDigest })
    $snapshot | Add-Member -NotePropertyName ReviewerIdentityDigest `
        -NotePropertyValue $(if ($null -eq $reviewerIdentityDigest) {
            'unknown'
        }
        else {
            $reviewerIdentityDigest
        })
    $snapshot | Add-Member -NotePropertyName CurrentIterationId `
        -NotePropertyValue $(if ($null -eq $currentIterationId) {
            'unknown'
        }
        else {
            $currentIterationId
        })
    return $snapshot
}

function New-OwnerSyntheticFileResponse {
    param(
        [Parameter(Mandatory)][DevPilot.OwnerAdapters.OwnerAcquisitionRequest]$Request,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][string]$SourceDigest
    )

    return [ordered]@{
        schemaVersion = 1
        repositoryId = $Request.RepositoryId
        projectId = $Request.ProjectId
        pullRequestId = $Request.PullRequestId
        sourceCommit = $Request.SourceCommit
        targetCommit = $Request.TargetCommit
        targetRef = $Request.TargetRef
        path = $Path
        state = $State
        byteLength = 0
        truncated = $false
        content = $null
        sourceDigest = $SourceDigest
        unavailableReason = $Reason
    }
}

function Get-OwnerLivePackage {
    param(
        [Parameter(Mandatory)][object]$Contract,
        [Parameter(Mandatory)][object]$Provider
    )

    $request = $Contract.Request
    $limits = $Contract.Limits
    $readCount = 0
    $baseArguments = [ordered]@{
        repositoryId = $request.RepositoryId
        projectId = $request.ProjectId
        pullRequestId = $request.PullRequestId
        sourceCommit = $request.SourceCommit
        targetCommit = $request.TargetCommit
        targetRef = $request.TargetRef
    }
    $subjectBefore = Invoke-OwnerProviderRead -Provider $Provider -Operation GetSubject `
        -Arguments $baseArguments -Limits $limits -ReadCount ([ref]$readCount)
    Test-OwnerIdentityResponse -Response $subjectBefore -Request $request -Operation GetSubject
    if ([string](Get-OwnerAdapterMember -Value $subjectBefore -Name state -Required) -cne 'complete') {
        throw 'Subject identity must be complete before acquisition.'
    }
    $changedFileCount = Get-OwnerAdapterInt64 `
        -Value (Get-OwnerAdapterMember -Value $subjectBefore -Name changedFileCount -Required) `
        -Name changedFileCount -Minimum 0 -Maximum $limits.MaximumFiles

    $pages = [Collections.Generic.List[object]]::new()
    $changes = [Collections.Generic.List[object]]::new()
    $tokens = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $token = $null
    $pageOrdinal = 0
    do {
        $pageArguments = [ordered]@{}
        foreach ($entry in $baseArguments.GetEnumerator()) { $pageArguments[$entry.Key] = $entry.Value }
        $pageArguments['continuationToken'] = $token
        $pageArguments['pageOrdinal'] = $pageOrdinal
        $page = Invoke-OwnerProviderRead -Provider $Provider -Operation GetChangedFilesPage `
            -Arguments $pageArguments -Limits $limits -ReadCount ([ref]$readCount)
        Test-OwnerIdentityResponse -Response $page -Request $request -Operation GetChangedFilesPage
        if ([int](Get-OwnerAdapterMember -Value $page -Name pageOrdinal -Required) -ne $pageOrdinal) {
            throw 'Changed-file pagination returned a stale or ambiguous page ordinal.'
        }
        [void]$pages.Add($page)
        $pageChanges = @(Get-OwnerAdapterMember -Value $page -Name changes -Required)
        foreach ($change in $pageChanges) {
            if ($change -isnot [Collections.IDictionary]) {
                throw 'Changed-file pages must contain only dictionaries.'
            }
            [void]$changes.Add($change)
            if ($changes.Count -gt $changedFileCount) {
                throw 'Changed-file pagination exceeded the subject denominator.'
            }
        }
        $nextTokenValue = Get-OwnerAdapterMember -Value $page -Name nextToken
        $token = if ($null -eq $nextTokenValue -or [string]::IsNullOrEmpty([string]$nextTokenValue)) {
            $null
        }
        else {
            $next = [string]$nextTokenValue
            Assert-OwnerAdapterText -Value $next -Name nextToken -MaximumLength 512
            if ($pageChanges.Count -eq 0) {
                throw 'Non-final changed-file pages cannot be empty.'
            }
            if (-not $tokens.Add($next)) { throw 'Changed-file pagination repeated a continuation token.' }
            $next
        }
        $pageOrdinal++
        if ($pageOrdinal -gt [Math]::Max(1, $limits.MaximumFiles)) {
            throw 'Changed-file pagination exceeded the file-derived page cap.'
        }
    } while ($null -ne $token)

    if ($changes.Count -ne $changedFileCount) {
        throw 'Changed-file pagination did not match the subject denominator.'
    }

    $ruleArguments = [ordered]@{}
    foreach ($entry in $baseArguments.GetEnumerator()) { $ruleArguments[$entry.Key] = $entry.Value }
    $ruleArguments['ruleRepositoryId'] = $request.RuleRepositoryId
    $ruleArguments['rulePath'] = $request.RulePath
    $ruleArguments['ruleCommit'] = $request.RuleCommit
    $ruleArguments['ruleSection'] = $request.RuleSection
    $ruleArguments['ruleHash'] = $request.RuleHash
    $ruleArguments['ruleLength'] = $request.RuleLength
    $ruleArguments['maximumBytes'] = $limits.MaximumBytes
    $rule = Invoke-OwnerProviderRead -Provider $Provider -Operation GetRule `
        -Arguments $ruleArguments -Limits $limits -ReadCount ([ref]$readCount)

    $files = [Collections.Generic.List[object]]::new()
    $ruleContent = Get-OwnerAdapterMember -Value $rule -Name content
    if ($null -ne $ruleContent -and $ruleContent -isnot [string]) {
        throw 'Rule content must be text or null.'
    }
    $bytesRead = if ($null -eq $ruleContent) {
        0L
    }
    else {
        [long][Text.Encoding]::UTF8.GetByteCount([string]$ruleContent)
    }
    if ($bytesRead -gt $limits.MaximumBytes) {
        $rule = [ordered]@{
            schemaVersion = 1
            repositoryId = $request.RepositoryId
            projectId = $request.ProjectId
            pullRequestId = $request.PullRequestId
            sourceCommit = $request.SourceCommit
            targetCommit = $request.TargetCommit
            targetRef = $request.TargetRef
            ruleRepositoryId = $request.RuleRepositoryId
            rulePath = $request.RulePath
            ruleCommit = $request.RuleCommit
            ruleSection = $request.RuleSection
            ruleHash = $request.RuleHash
            ruleLength = $request.RuleLength
            state = 'unknown'
            content = $null
            sourceDigest = $request.RuleHash
            unavailableReason = 'oversize'
        }
        $bytesRead = 0L
    }
    foreach ($change in $changes) {
        $path = ConvertTo-OwnerSafePath -Path ([string](Get-OwnerAdapterMember -Value $change -Name path -Required)) `
            -Name path
        $changeType = [string](Get-OwnerAdapterMember -Value $change -Name changeType -Required)
        $isBinary = Get-OwnerAdapterBoolean `
            -Value (Get-OwnerAdapterMember -Value $change -Name isBinary -Required) -Name isBinary
        $changeDigest = [string](Get-OwnerAdapterMember -Value $change -Name sourceDigest -Required)
        Assert-OwnerAdapterDigest -Value $changeDigest -Name sourceDigest
        if ($changeType -ceq 'deleted') {
            [void]$files.Add((New-OwnerSyntheticFileResponse -Request $request -Path $path `
                    -State complete -Reason deleted -SourceDigest $changeDigest))
            continue
        }
        if ($isBinary) {
            [void]$files.Add((New-OwnerSyntheticFileResponse -Request $request -Path $path `
                    -State unknown -Reason binary -SourceDigest $changeDigest))
            continue
        }
        if ($readCount -ge ($limits.MaximumReads - 1) -or $bytesRead -ge $limits.MaximumBytes) {
            [void]$files.Add((New-OwnerSyntheticFileResponse -Request $request -Path $path `
                    -State unknown -Reason cap-exhausted -SourceDigest $changeDigest))
            continue
        }
        $fileArguments = [ordered]@{}
        foreach ($entry in $baseArguments.GetEnumerator()) { $fileArguments[$entry.Key] = $entry.Value }
        $fileArguments['path'] = $path
        $fileArguments['maximumBytes'] = $limits.MaximumBytes - $bytesRead
        $file = Invoke-OwnerProviderRead -Provider $Provider -Operation GetFile `
            -Arguments $fileArguments -Limits $limits -ReadCount ([ref]$readCount)
        Test-OwnerIdentityResponse -Response $file -Request $request -Operation GetFile
        if ([string](Get-OwnerAdapterMember -Value $file -Name path -Required) -cne $path) {
            throw 'File response path did not match the requested changed path.'
        }
        $content = Get-OwnerAdapterMember -Value $file -Name content
        if ($null -ne $content -and $content -isnot [string]) {
            throw 'File content must be text or null.'
        }
        if ($null -ne $content) {
            $contentBytes = [Text.Encoding]::UTF8.GetByteCount([string]$content)
            if ($bytesRead + $contentBytes -gt $limits.MaximumBytes) {
                [void]$files.Add((New-OwnerSyntheticFileResponse -Request $request -Path $path `
                        -State unknown -Reason oversize -SourceDigest $changeDigest))
                continue
            }
            $bytesRead += $contentBytes
        }
        [void]$files.Add($file)
    }

    if ($readCount -ge $limits.MaximumReads) {
        throw 'Read cap left no room for the mandatory subject race check.'
    }
    $subjectAfter = Invoke-OwnerProviderRead -Provider $Provider -Operation GetSubject `
        -Arguments $baseArguments -Limits $limits -ReadCount ([ref]$readCount)
    Test-OwnerIdentityResponse -Response $subjectAfter -Request $request -Operation GetSubject

    return ConvertTo-OwnerAdapterCanonicalValue -Value ([ordered]@{
        schemaVersion = 1
        semantics = $script:OwnerAdapterSemantics
        contractDigest = $script:OwnerAdapterContractDigest
        subjectBefore = $subjectBefore
        changePages = @($pages)
        rule = $rule
        files = @($files)
        subjectAfter = $subjectAfter
    })
}

function ConvertTo-OwnerSpanData {
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Spans)

    $normalized = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($span in $Spans) {
        if ($null -eq $span) { continue }
        if ($span -is [Collections.IList] -and $span.Count -eq 0) { continue }
        if ($span -isnot [Collections.IDictionary]) { throw 'Changed spans must be dictionaries.' }
        $startLine = [int](Get-OwnerAdapterMember -Value $span -Name startLine -Required)
        $endLine = [int](Get-OwnerAdapterMember -Value $span -Name endLine -Required)
        $state = [string](Get-OwnerAdapterMember -Value $span -Name state -Required)
        $sourceDigest = [string](Get-OwnerAdapterMember -Value $span -Name sourceDigest -Required)
        Assert-OwnerAdapterState -Value $state -Name span.state
        Assert-OwnerAdapterDigest -Value $sourceDigest -Name span.sourceDigest
        if ($startLine -lt 1 -or $endLine -lt $startLine) { throw 'Changed span line bounds are invalid.' }
        $key = '{0:D10}:{1:D10}' -f $startLine, $endLine
        if (-not $seen.Add($key)) { throw 'Changed spans contained an ambiguous duplicate.' }
        [void]$normalized.Add([ordered]@{
                startLine = $startLine
                endLine = $endLine
                state = $state
                sourceDigest = $sourceDigest
            })
    }
    $array = @($normalized)
    [Array]::Sort($array, [Collections.Generic.Comparer[object]]::Create({
                param($left, $right)
                $start = [int]$left['startLine'] - [int]$right['startLine']
                if ($start -ne 0) { return $start }
                return [int]$left['endLine'] - [int]$right['endLine']
            }))
    for ($index = 1; $index -lt $array.Count; $index++) {
        if ([int]$array[$index]['startLine'] -le [int]$array[$index - 1]['endLine']) {
            throw 'Changed spans contained overlapping evidence ranges.'
        }
    }
    Write-Output -NoEnumerate ([object[]]$array)
}

function ConvertTo-OwnerAcquisitionResponse {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Package,
        [Parameter(Mandatory)][object]$Contract
    )

    $request = $Contract.Request
    $limits = $Contract.Limits
    if ((Get-OwnerAdapterMember -Value $Package -Name schemaVersion -Required) -ne 1 -or
        [string](Get-OwnerAdapterMember -Value $Package -Name semantics -Required) -cne $script:OwnerAdapterSemantics -or
        [string](Get-OwnerAdapterMember -Value $Package -Name contractDigest -Required) -cne $script:OwnerAdapterContractDigest) {
        throw 'Live and replay acquisition semantics did not match the adapter contract.'
    }

    $subjectBefore = Get-OwnerAdapterMember -Value $Package -Name subjectBefore -Required
    $subjectAfter = Get-OwnerAdapterMember -Value $Package -Name subjectAfter -Required
    if ($subjectBefore -isnot [Collections.IDictionary] -or $subjectAfter -isnot [Collections.IDictionary]) {
        throw 'Subject race checks must be dictionaries.'
    }
    Test-OwnerIdentityResponse -Response $subjectBefore -Request $request -Operation subjectBefore
    Test-OwnerIdentityResponse -Response $subjectAfter -Request $request -Operation subjectAfter
    $beforeState = [string](Get-OwnerAdapterMember -Value $subjectBefore -Name state -Required)
    $afterState = [string](Get-OwnerAdapterMember -Value $subjectAfter -Name state -Required)
    if ($beforeState -cne 'complete' -or $afterState -cne 'complete') {
        throw 'Subject race checks must both be complete.'
    }
    $subjectBeforeDigest = [string](Get-OwnerAdapterMember -Value $subjectBefore -Name sourceDigest -Required)
    $subjectAfterDigest = [string](Get-OwnerAdapterMember -Value $subjectAfter -Name sourceDigest -Required)
    Assert-OwnerAdapterDigest -Value $subjectBeforeDigest -Name subjectBefore.sourceDigest
    Assert-OwnerAdapterDigest -Value $subjectAfterDigest -Name subjectAfter.sourceDigest
    if ($subjectBeforeDigest -cne $subjectAfterDigest) {
        throw 'Subject identity changed during acquisition.'
    }
    $changedFileCount = Get-OwnerAdapterInt64 `
        -Value (Get-OwnerAdapterMember -Value $subjectBefore -Name changedFileCount -Required) `
        -Name subjectBefore.changedFileCount -Minimum 0 -Maximum $limits.MaximumFiles
    $afterChangedFileCount = Get-OwnerAdapterInt64 `
        -Value (Get-OwnerAdapterMember -Value $subjectAfter -Name changedFileCount -Required) `
        -Name subjectAfter.changedFileCount -Minimum 0 -Maximum $limits.MaximumFiles
    if ($afterChangedFileCount -ne $changedFileCount) {
        throw 'Subject denominator changed or exceeded the file cap.'
    }

    $diagnostics = [Collections.Generic.List[object]]::new()
    $artifactDigests = [Collections.Generic.List[object]]::new()
    [void]$artifactDigests.Add([ordered]@{ artifact = 'subject'; digest = $subjectBeforeDigest })
    $changes = [Collections.Generic.List[object]]::new()
    $expectedPage = 0
    $expectedToken = $null
    $seenTokens = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($page in @(Get-OwnerAdapterMember -Value $Package -Name changePages -Required)) {
        if ($page -isnot [Collections.IDictionary]) { throw 'Changed-file pages must be dictionaries.' }
        Test-OwnerIdentityResponse -Response $page -Request $request -Operation changePage
        if ([int](Get-OwnerAdapterMember -Value $page -Name pageOrdinal -Required) -ne $expectedPage) {
            throw 'Changed-file package contained missing, repeated, or reordered pages.'
        }
        $pageToken = Get-OwnerAdapterMember -Value $page -Name continuationToken
        if (($null -eq $expectedToken -and $null -ne $pageToken) -or
            ($null -ne $expectedToken -and [string]$pageToken -cne $expectedToken)) {
            throw 'Changed-file package contained a broken continuation chain.'
        }
        $pageState = [string](Get-OwnerAdapterMember -Value $page -Name state -Required)
        Assert-OwnerAdapterState -Value $pageState -Name page.state
        if ($pageState -cne 'complete') {
            throw 'Partial changed-file pagination cannot establish the subject denominator.'
        }
        $pageDigest = [string](Get-OwnerAdapterMember -Value $page -Name sourceDigest -Required)
        Assert-OwnerAdapterDigest -Value $pageDigest -Name page.sourceDigest
        [void]$artifactDigests.Add([ordered]@{ artifact = "change-page:$expectedPage"; digest = $pageDigest })
        $pageChanges = @(Get-OwnerAdapterMember -Value $page -Name changes -Required)
        foreach ($change in $pageChanges) {
            if ($change -isnot [Collections.IDictionary]) { throw 'Changed-file page entries must be dictionaries.' }
            [void]$changes.Add($change)
            if ($changes.Count -gt $changedFileCount) {
                throw 'Changed-file package exceeded the subject denominator.'
            }
        }
        $nextTokenValue = Get-OwnerAdapterMember -Value $page -Name nextToken
        $expectedToken = if ($null -eq $nextTokenValue -or [string]::IsNullOrEmpty([string]$nextTokenValue)) {
            $null
        }
        else {
            $nextToken = [string]$nextTokenValue
            Assert-OwnerAdapterText -Value $nextToken -Name page.nextToken -MaximumLength 512
            if ($pageChanges.Count -eq 0) {
                throw 'Non-final changed-file pages cannot be empty.'
            }
            if (-not $seenTokens.Add($nextToken)) {
                throw 'Changed-file package repeated a continuation token.'
            }
            $nextToken
        }
        $expectedPage++
        if ($expectedPage -gt [Math]::Max(1, $limits.MaximumFiles)) {
            throw 'Changed-file package exceeded the file-derived page cap.'
        }
    }
    if ($null -ne $expectedToken) {
        throw 'Changed-file package ended before its continuation chain completed.'
    }
    if ($changes.Count -ne $changedFileCount) {
        throw 'Changed-file package did not preserve the subject denominator.'
    }

    $filesByPath = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($file in @(Get-OwnerAdapterMember -Value $Package -Name files -Required)) {
        if ($file -isnot [Collections.IDictionary]) { throw 'File responses must be dictionaries.' }
        Test-OwnerIdentityResponse -Response $file -Request $request -Operation file
        $rawFilePath = [string](Get-OwnerAdapterMember -Value $file -Name path -Required)
        $filePath = ConvertTo-OwnerSafePath -Path $rawFilePath -Name file.path
        if ($rawFilePath -cne $filePath) {
            throw 'File response paths must already use canonical separators.'
        }
        if ($filesByPath.ContainsKey($filePath)) { throw 'File package contained a duplicate path.' }
        $filesByPath.Add($filePath, $file)
    }

    $pathSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $normalizedChanges = [Collections.Generic.List[object]]::new()
    foreach ($change in $changes) {
        $path = ConvertTo-OwnerSafePath -Path ([string](Get-OwnerAdapterMember -Value $change -Name path -Required)) `
            -Name change.path
        if (-not $pathSet.Add($path)) { throw 'Changed files contained an ambiguous duplicate path.' }
        $changeType = [string](Get-OwnerAdapterMember -Value $change -Name changeType -Required)
        if ($changeType -cnotin @('added', 'modified', 'deleted', 'renamed')) {
            throw 'Changed file used an unsupported change type.'
        }
        $oldPath = Get-OwnerAdapterMember -Value $change -Name oldPath
        if ($changeType -ceq 'renamed') {
            if ($null -eq $oldPath) { throw 'Renamed files require an old path.' }
            $oldPath = ConvertTo-OwnerSafePath -Path ([string]$oldPath) -Name change.oldPath
            if ([StringComparer]::OrdinalIgnoreCase.Equals($oldPath, $path)) {
                throw 'Rename paths must be distinct.'
            }
        }
        elseif ($null -ne $oldPath) {
            throw 'Only renamed files may include an old path.'
        }
        $changeDigest = [string](Get-OwnerAdapterMember -Value $change -Name sourceDigest -Required)
        Assert-OwnerAdapterDigest -Value $changeDigest -Name change.sourceDigest
        $spanValues = @(Get-OwnerAdapterMember -Value $change -Name spans -Required)
        $spans = ConvertTo-OwnerSpanData -Spans $spanValues
        [void]$normalizedChanges.Add([ordered]@{
                path = $path
                oldPath = $oldPath
                changeType = $changeType
                isBinary = Get-OwnerAdapterBoolean `
                    -Value (Get-OwnerAdapterMember -Value $change -Name isBinary -Required) -Name change.isBinary
                sourceDigest = $changeDigest
                spans = $spans
            })
    }
    $changeArray = @($normalizedChanges)
    [Array]::Sort($changeArray, [Collections.Generic.Comparer[object]]::Create({
                param($left, $right)
                return [StringComparer]::Ordinal.Compare([string]$left['path'], [string]$right['path'])
            }))

    $rule = Get-OwnerAdapterMember -Value $Package -Name rule -Required
    if ($rule -isnot [Collections.IDictionary]) { throw 'Rule response must be a dictionary.' }
    Test-OwnerIdentityResponse -Response $rule -Request $request -Operation rule
    foreach ($entry in ([ordered]@{
                ruleRepositoryId = $request.RuleRepositoryId
                rulePath = $request.RulePath
                ruleCommit = $request.RuleCommit
                ruleSection = $request.RuleSection
                ruleHash = $request.RuleHash
                ruleLength = $request.RuleLength
            }).GetEnumerator()) {
        if ([string](Get-OwnerAdapterMember -Value $rule -Name $entry.Key -Required) -cne [string]$entry.Value) {
            throw 'Rule response changed authoritative identity.'
        }
    }
    $ruleState = [string](Get-OwnerAdapterMember -Value $rule -Name state -Required)
    Assert-OwnerAdapterState -Value $ruleState -Name rule.state
    $ruleSourceDigest = [string](Get-OwnerAdapterMember -Value $rule -Name sourceDigest -Required)
    Assert-OwnerAdapterDigest -Value $ruleSourceDigest -Name rule.sourceDigest
    $ruleContent = Get-OwnerAdapterMember -Value $rule -Name content
    if ($null -ne $ruleContent -and $ruleContent -isnot [string]) { throw 'Rule content must be text or null.' }
    if ($ruleState -ceq 'complete') {
        if ($null -eq $ruleContent -or
            [Text.Encoding]::UTF8.GetByteCount([string]$ruleContent) -ne $request.RuleLength -or
            (Get-OwnerAdapterDigest -Value ([string]$ruleContent)) -cne $request.RuleHash) {
            throw 'Complete rule content did not match its authoritative hash and length.'
        }
    }
    $ruleReasonValue = Get-OwnerAdapterMember -Value $rule -Name unavailableReason
    $ruleUnknownReason = if ($null -eq $ruleReasonValue) { $null } else { [string]$ruleReasonValue }
    if ($null -ne $ruleUnknownReason -and $ruleUnknownReason -cnotin $script:OwnerUnknownReasons) {
        throw 'Rule response used an unsupported unavailable reason.'
    }
    [void]$artifactDigests.Add([ordered]@{ artifact = 'rule'; digest = $ruleSourceDigest })

    $units = [Collections.Generic.List[object]]::new()
    $ruleUnitState = if ($ruleState -ceq 'complete') { 'complete' } else { 'unknown' }
    if ($ruleUnitState -ceq 'unknown') {
        Add-OwnerAdapterDiagnostic -Diagnostics $diagnostics -Limits $limits `
            -Code 'rule-evidence-unknown' -Message 'Authoritative rule evidence was incomplete or unknown.'
    }
    [void]$units.Add([ordered]@{
            unitId = 'rule'
            state = $ruleUnitState
            data = [ordered]@{
                repositoryId = $request.RuleRepositoryId
                path = $request.RulePath
                commit = $request.RuleCommit
                section = $request.RuleSection
                hash = $request.RuleHash
                length = $request.RuleLength
                sourceState = $ruleState
                unknownReason = if ($ruleUnitState -ceq 'unknown') {
                    if ($null -ne $ruleUnknownReason) { $ruleUnknownReason }
                    elseif ($ruleState -ceq 'incomplete') { 'incomplete' }
                    else { 'provider-unknown' }
                }
                else {
                    $null
                }
                sourceDigest = $ruleSourceDigest
                content = $ruleContent
            }
        })

    $ordinal = 0
    $totalContentBytes = if ($null -eq $ruleContent) {
        0L
    }
    else {
        [long][Text.Encoding]::UTF8.GetByteCount([string]$ruleContent)
    }
    foreach ($change in $changeArray) {
        $path = [string]$change['path']
        if (-not $filesByPath.ContainsKey($path)) { throw 'Changed-file package omitted a file evidence response.' }
        $file = $filesByPath[$path]
        $fileState = [string](Get-OwnerAdapterMember -Value $file -Name state -Required)
        Assert-OwnerAdapterState -Value $fileState -Name file.state
        $fileDigest = [string](Get-OwnerAdapterMember -Value $file -Name sourceDigest -Required)
        Assert-OwnerAdapterDigest -Value $fileDigest -Name file.sourceDigest
        $byteLength = Get-OwnerAdapterInt64 `
            -Value (Get-OwnerAdapterMember -Value $file -Name byteLength -Required) `
            -Name file.byteLength -Minimum 0
        $truncated = Get-OwnerAdapterBoolean `
            -Value (Get-OwnerAdapterMember -Value $file -Name truncated -Required) -Name file.truncated
        $content = Get-OwnerAdapterMember -Value $file -Name content
        if ($byteLength -lt 0 -or $null -ne $content -and $content -isnot [string]) {
            throw 'File response contained invalid length or content.'
        }
        if ($null -ne $content) {
            $actualBytes = [Text.Encoding]::UTF8.GetByteCount([string]$content)
            $totalContentBytes += $actualBytes
            if ($fileState -ceq 'complete' -and
                ($actualBytes -ne $byteLength -or
                    (Get-OwnerAdapterDigest -Value ([string]$content)) -cne $fileDigest)) {
                throw 'Complete file content did not match its source digest or byte length.'
            }
        }
        if ($fileState -ceq 'complete' -and
            $change['changeType'] -cne 'deleted' -and
            ($null -eq $content -or $truncated)) {
            throw 'Complete non-deleted file evidence requires untruncated content.'
        }
        if ($change['changeType'] -ceq 'deleted' -and $null -ne $content) {
            throw 'Deleted file evidence cannot contain current content.'
        }
        if ($totalContentBytes -gt $limits.MaximumBytes) {
            throw 'File package exceeded the configured byte cap.'
        }
        $spanStates = @($change['spans'] | ForEach-Object { $_['state'] })
        $providerReasonValue = Get-OwnerAdapterMember -Value $file -Name unavailableReason
        $providerReason = if ($null -eq $providerReasonValue) { $null } else { [string]$providerReasonValue }
        if ($null -ne $providerReason -and $providerReason -cnotin $script:OwnerUnknownReasons -and
            $providerReason -cne 'deleted') {
            throw 'File response used an unsupported unavailable reason.'
        }
        if ($providerReason -ceq 'deleted' -and $change['changeType'] -cne 'deleted') {
            throw 'Only deleted changes may use the deleted unavailable reason.'
        }
        $evidenceState = if (
            $fileState -cne 'complete' -or
            $truncated -or
            [bool]$change['isBinary'] -or
            $change['spans'].Count -eq 0 -and $change['changeType'] -cne 'deleted' -or
            $spanStates -contains 'incomplete' -or
            $spanStates -contains 'unknown') {
            'unknown'
        }
        else {
            'complete'
        }
        $unknownReason = if ($evidenceState -ceq 'complete') {
            $null
        }
        elseif ([bool]$change['isBinary']) {
            'binary'
        }
        elseif ($truncated) {
            'truncated'
        }
        elseif ($null -ne $providerReason -and $providerReason -cne 'deleted') {
            $providerReason
        }
        elseif ($change['spans'].Count -eq 0) {
            'spans-missing'
        }
        elseif ($spanStates -contains 'incomplete' -or $spanStates -contains 'unknown') {
            'spans-incomplete'
        }
        elseif ($fileState -ceq 'incomplete') {
            'incomplete'
        }
        else {
            'provider-unknown'
        }
        if ($evidenceState -ceq 'unknown') {
            Add-OwnerAdapterDiagnostic -Diagnostics $diagnostics -Limits $limits `
                -Code 'file-evidence-unknown' -Message "File evidence for ordinal $ordinal was incomplete or unknown."
        }
        [void]$artifactDigests.Add([ordered]@{ artifact = "change:$ordinal"; digest = $change['sourceDigest'] })
        [void]$artifactDigests.Add([ordered]@{ artifact = "file:$ordinal"; digest = $fileDigest })
        [void]$units.Add([ordered]@{
                unitId = ('file:{0:D6}' -f $ordinal)
                state = $evidenceState
                data = [ordered]@{
                    path = $path
                    oldPath = $change['oldPath']
                    changeType = $change['changeType']
                    isBinary = $change['isBinary']
                    spans = $change['spans']
                    sourceState = $fileState
                    unknownReason = $unknownReason
                    sourceDigest = $fileDigest
                    byteLength = $byteLength
                    truncated = $truncated
                    content = $content
                }
            })
        $ordinal++
    }
    if ($filesByPath.Count -ne $changeArray.Count) {
        throw 'File package contained evidence outside the changed-file denominator.'
    }
    [void]$units.Add([ordered]@{
            unitId = 'identity'
            state = 'complete'
            data = [ordered]@{
                repositoryId = $request.RepositoryId
                projectId = $request.ProjectId
                pullRequestId = $request.PullRequestId
                sourceCommit = $request.SourceCommit
                targetCommit = $request.TargetCommit
                targetRef = $request.TargetRef
                configId = $request.ConfigId
                configDigest = $request.ConfigDigest
                capabilityId = $request.CapabilityId
                capabilityDigest = $request.CapabilityDigest
                acquisitionLimits = [ordered]@{
                    maximumFiles = $limits.MaximumFiles
                    maximumBytes = $limits.MaximumBytes
                    maximumReads = $limits.MaximumReads
                    maximumDiagnostics = $limits.MaximumDiagnostics
                }
                sourceArtifactDigests = @($artifactDigests)
            }
        })

    $unitStates = @($units | ForEach-Object { $_['state'] })
    $snapshotState = if ($unitStates -contains 'unknown') { 'unknown' }
    elseif ($unitStates -contains 'incomplete') { 'incomplete' }
    else { 'complete' }
    return [ordered]@{
        schemaVersion = 1
        bindingId = $Contract.Binding.BindingId
        state = $snapshotState
        evidenceUnits = @($units)
        diagnostics = @($diagnostics)
    }
}

function New-OwnerProductionAcquisitionAdapter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Contract,
        [Parameter(Mandatory)][object]$Provider,
        [string]$Name = 'production-acquisition'
    )

    Test-OwnerAcquisitionContract -Contract $Contract
    Test-OwnerProviderAdapter -Provider $Provider
    $capturedContract = $Contract
    $capturedProvider = $Provider
    $getLivePackageCommand = Get-Command Get-OwnerLivePackage -CommandType Function
    $convertResponseCommand = Get-Command ConvertTo-OwnerAcquisitionResponse -CommandType Function
    return New-OwnerPipelineAdapter -Stage acquisition -Name $Name -Handler {
        param($context)
        if ($context.binding.BindingId -cne $capturedContract.Binding.BindingId) {
            throw 'Production acquisition received a different facade binding.'
        }
        $package = & $getLivePackageCommand -Contract $capturedContract -Provider $capturedProvider
        return & $convertResponseCommand -Package $package -Contract $capturedContract
    }.GetNewClosure()
}

function New-OwnerReplayFixture {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Collections.IDictionary]$Package)

    $canonicalPackage = ConvertTo-OwnerAdapterCanonicalValue -Value $Package
    $payloadJson = ConvertTo-OwnerAdapterCanonicalJson -Value $canonicalPackage
    $payloadDigest = Get-OwnerAdapterDigest -Value $payloadJson
    $sealDigest = Get-OwnerAdapterDigest -Value ([ordered]@{
            semantics = $script:OwnerAdapterSemantics
            contractDigest = $script:OwnerAdapterContractDigest
            payloadDigest = $payloadDigest
        })
    return [DevPilot.OwnerAdapters.OwnerReplayFixture]::new(
        $script:OwnerAdapterSemantics,
        $payloadJson,
        $payloadDigest,
        $sealDigest)
}

function New-OwnerReplayAcquisitionAdapter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Contract,
        [Parameter(Mandatory)][DevPilot.OwnerAdapters.OwnerReplayFixture]$Fixture,
        [Parameter(Mandatory)][string]$ExpectedPayloadDigest,
        [string]$Name = 'replay-acquisition'
    )

    Test-OwnerAcquisitionContract -Contract $Contract
    Assert-OwnerAdapterDigest -Value $ExpectedPayloadDigest -Name ExpectedPayloadDigest
    if ($Fixture.PayloadDigest -cne $ExpectedPayloadDigest) {
        throw 'Replay fixture did not match the independently pinned payload digest.'
    }
    $capturedContract = $Contract
    $capturedFixture = $Fixture
    $capturedExpectedPayloadDigest = $ExpectedPayloadDigest
    $semantics = $script:OwnerAdapterSemantics
    $contractDigest = $script:OwnerAdapterContractDigest
    $digestCommand = Get-Command Get-OwnerAdapterDigest -CommandType Function
    $canonicalValueCommand = Get-Command ConvertTo-OwnerAdapterCanonicalValue -CommandType Function
    $convertResponseCommand = Get-Command ConvertTo-OwnerAcquisitionResponse -CommandType Function
    return New-OwnerPipelineAdapter -Stage acquisition -Name $Name -Handler {
        param($context)
        if ($context.binding.BindingId -cne $capturedContract.Binding.BindingId) {
            throw 'Replay acquisition received a different facade binding.'
        }
        if ($capturedFixture.Semantics -cne $semantics -or
            $capturedFixture.PayloadDigest -cne $capturedExpectedPayloadDigest -or
            (& $digestCommand -Value $capturedFixture.PayloadJson) -cne $capturedFixture.PayloadDigest -or
            (& $digestCommand -Value ([ordered]@{
                        semantics = $capturedFixture.Semantics
                        contractDigest = $contractDigest
                        payloadDigest = $capturedFixture.PayloadDigest
                    })) -cne $capturedFixture.SealDigest) {
            throw 'Replay fixture seal did not match its payload or semantics.'
        }
        $decodedPackage = ConvertFrom-Json -InputObject $capturedFixture.PayloadJson -AsHashtable -Depth 32
        $package = & $canonicalValueCommand -Value $decodedPackage
        return & $convertResponseCommand -Package $package -Contract $capturedContract
    }.GetNewClosure()
}

Export-ModuleMember -Function @(
    'ConvertTo-OwnerAzureDevOpsDiscussionPage',
    'Get-OwnerAzureDevOpsDiscussionMappingDigest',
    'New-OwnerAcquisitionContract',
    'New-OwnerAdapterLimits',
    'New-OwnerAzureDevOpsReadOnlyProviderAdapter',
    'New-OwnerAzureDevOpsReviewerIdentity',
    'New-OwnerDiscussionLimits',
    'New-OwnerReadOnlyProviderAdapter',
    'New-OwnerProductionAcquisitionAdapter',
    'Get-OwnerDiscussionSnapshot',
    'New-OwnerReplayFixture',
    'New-OwnerReplayAcquisitionAdapter'
)
