#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\..\DevPilot.OwnerPipeline\DevPilot.OwnerPipeline.psd1" -Force

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
$script:OwnerProviderOperations = @('GetSubject', 'GetChangedFilesPage', 'GetRule', 'GetFile')
$script:OwnerAdapterMaximumJsonNodes = 100000
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
    'New-OwnerAcquisitionContract',
    'New-OwnerAdapterLimits',
    'New-OwnerReadOnlyProviderAdapter',
    'New-OwnerProductionAcquisitionAdapter',
    'New-OwnerReplayFixture',
    'New-OwnerReplayAcquisitionAdapter'
)
