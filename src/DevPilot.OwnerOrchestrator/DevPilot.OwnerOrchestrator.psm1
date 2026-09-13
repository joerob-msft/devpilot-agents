#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\..\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1" -Force
Import-Module "$PSScriptRoot\..\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1" -Force
Import-Module "$PSScriptRoot\..\DevPilot.OwnerCapability\DevPilot.OwnerCapability.psd1" -Force
Import-Module "$PSScriptRoot\..\OwnerObservationContract\OwnerObservationContract.psd1" -Force
Import-Module "$PSScriptRoot\..\DevPilot.OwnerModelRunner\DevPilot.OwnerModelRunner.psd1" -Force
Import-Module "$PSScriptRoot\..\DevPilot.OwnerPipeline\DevPilot.OwnerPipeline.psd1" -Force

$script:OwnerV2ObservationSchemaPath = Join-Path $PSScriptRoot `
    '..\OwnerObserver\schemas\owner-observation.v1.json'

if ($IsWindows -and -not ('DevPilot.OwnerOrchestrator.NativePaths' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
using System.Text;

namespace DevPilot.OwnerOrchestrator
{
    public static class NativePaths
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern uint QueryDosDevice(
            string deviceName,
            StringBuilder targetPath,
            int maximumCharacterCount);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern uint GetLongPathName(
            string shortPath,
            StringBuilder longPath,
            int bufferLength);
    }
}
'@
}

$script:OwnerV2MaximumEntries = 32
$script:OwnerV2DigestPattern = '^v1:sha256:[0-9a-f]{64}$'
$script:OwnerV2CommitPattern = '^[0-9a-f]{40}$'
$script:OwnerV2SafeIdPattern = '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$'
$script:OwnerV2UnsafeKeyPattern = '(?i)(authorize|authorization|delivery|writer|adapter|tool|secret|password|credential|scheduler|notification|vote|comment|summary|permission|deploy|accessToken|refreshToken|idToken|apiKey|privateKey)'
$script:OwnerV2UnsafeValuePattern = '(?i)(ghp_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|bearer\s+[A-Za-z0-9._-]+|authorization:|password=|secret=|token=)'
$script:OwnerV2States = @('pending', 'running', 'completed', 'incomplete', 'unknown')
$script:OwnerV2TestCheckpoint = $null
$script:OwnerV2RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))

function Invoke-OwnerV2Checkpoint {
    param([Parameter(Mandatory)][string]$Name)
    if ($script:OwnerV2TestCheckpoint -is [scriptblock]) {
        & $script:OwnerV2TestCheckpoint $Name
        return
    }
    if ($script:OwnerV2TestCheckpoint -and $script:OwnerV2TestCheckpoint -ceq $Name) {
        throw "owner-v2-test-checkpoint:$Name"
    }
}

function Get-OwnerV2Member {
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Name
    )
    if ($Value -is [Collections.IDictionary] -and $Value.Contains($Name)) { return $Value[$Name] }
    if ($null -ne $Value) {
        $property = $Value.PSObject.Properties[$Name]
        if ($null -ne $property) { return $property.Value }
    }
    return $null
}

function Test-OwnerV2ExactKeys {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Value,
        [Parameter(Mandatory)][string[]]$Expected
    )
    $actual = @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive)
    $wanted = @($Expected | Sort-Object -CaseSensitive)
    return $actual.Count -eq $wanted.Count -and (($actual -join '|') -ceq ($wanted -join '|'))
}

function Assert-OwnerV2ExactKeys {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Value,
        [Parameter(Mandatory)][string[]]$Expected,
        [Parameter(Mandatory)][string]$Name
    )
    if (-not (Test-OwnerV2ExactKeys -Value $Value -Expected $Expected)) {
        throw "$Name must contain exactly: $($Expected -join ', ')."
    }
}

function Assert-OwnerV2SafeText {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$Name,
        [int]$MaximumLength = 256,
        [switch]$AllowEmpty
    )
    if ((-not $AllowEmpty -and [string]::IsNullOrWhiteSpace($Value)) -or
        $Value.Length -gt $MaximumLength -or
        $Value -match '[\r\n]' -or
        $Value -match $script:OwnerV2UnsafeValuePattern) {
        throw "$Name contained unsafe or unbounded text."
    }
}

function Assert-OwnerV2Digest {
    param([Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)][string]$Name)
    if ($Value -cnotmatch $script:OwnerV2DigestPattern) { throw "$Name must be a lowercase v1 SHA-256 digest." }
}

function Assert-OwnerV2Commit {
    param([Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)][string]$Name)
    if ($Value -cnotmatch $script:OwnerV2CommitPattern) { throw "$Name must be a lowercase 40-character commit id." }
}

function Assert-OwnerV2NoUnsafeShape {
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Value,
        [string]$Path = '$',
        [int]$Depth = 0,
        [ref]$NodeCount
    )
    if ($Depth -gt 32) { throw "JSON shape at $Path exceeded the maximum depth." }
    if ($null -eq $NodeCount) {
        $count = 0
        $NodeCount = [ref]$count
    }
    $NodeCount.Value++
    if ($NodeCount.Value -gt 8192) { throw 'JSON shape exceeded the maximum node count.' }
    if ($null -eq $Value) { return }
    if ($Value -is [string]) {
        $opaqueEvidence = $Path -match (
            '^\$(?:(?:\.entries\[\d+\])?\.acquisition)?\.package\.' +
            '(?:rule\.content|files\[\d+\]\.content)$')
        if (-not $opaqueEvidence -and $Value -match $script:OwnerV2UnsafeValuePattern) {
            throw "JSON value at $Path looked sensitive."
        }
        return
    }
    if ($Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or
        $Value -is [double] -or $Value -is [decimal]) { return }
    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            $name = [string]$key
            if ([string]::IsNullOrWhiteSpace($name) -or $name -match '[\r\n]' -or
                $name -match $script:OwnerV2UnsafeKeyPattern) {
                throw "JSON key '$Path.$name' is unsafe for an Owner v2 preview manifest or record."
            }
            Assert-OwnerV2NoUnsafeShape -Value $Value[$key] -Path "$Path.$name" `
                -Depth ($Depth + 1) -NodeCount $NodeCount
        }
        return
    }
    if ($Value -is [Management.Automation.PSCustomObject]) {
        $map = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) { $map[$property.Name] = $property.Value }
        Assert-OwnerV2NoUnsafeShape -Value $map -Path $Path -Depth $Depth -NodeCount $NodeCount
        return
    }
    if ($Value -is [Collections.IEnumerable]) {
        $index = 0
        foreach ($item in @($Value)) {
            Assert-OwnerV2NoUnsafeShape -Value $item -Path "$Path[$index]" `
                -Depth ($Depth + 1) -NodeCount $NodeCount
            $index++
        }
        return
    }
    throw "JSON value at $Path used unsupported type '$($Value.GetType().FullName)'."
}

function ConvertTo-OwnerV2JsonValue {
    param([Parameter(Mandatory)][AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [bool] -or $Value -is [int] -or $Value -is [long]) { return $Value }
    if ($Value -is [double] -or $Value -is [decimal]) {
        if ([double]$Value % 1 -ne 0) { throw 'Owner v2 preview JSON values must use integral numbers only.' }
        return [long]$Value
    }
    if ($Value -is [Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive)) {
            $result[$key] = ConvertTo-OwnerV2JsonValue -Value $Value[$key]
        }
        return $result
    }
    if ($Value -is [Management.Automation.PSCustomObject]) {
        $result = [ordered]@{}
        foreach ($property in @($Value.PSObject.Properties.Name | Sort-Object -CaseSensitive)) {
            $result[$property] = ConvertTo-OwnerV2JsonValue -Value $Value.PSObject.Properties[$property].Value
        }
        return $result
    }
    if ($Value -is [Collections.IEnumerable]) {
        return , @($Value | ForEach-Object { ConvertTo-OwnerV2JsonValue -Value $_ })
    }
    throw "Unsupported Owner v2 preview JSON type '$($Value.GetType().FullName)'."
}

function ConvertTo-OwnerV2CanonicalJson {
    param([Parameter(Mandatory)][AllowNull()][object]$Value)
    return (ConvertTo-AgentCanonicalJson -InputObject (ConvertTo-OwnerV2JsonValue -Value $Value)) + "`n"
}

function Get-OwnerV2Digest {
    param([Parameter(Mandatory)][AllowNull()][object]$Value)
    return 'v1:sha256:' + (Get-AgentCanonicalDigest -InputObject (ConvertTo-OwnerV2JsonValue -Value $Value))
}

function Get-OwnerV2SafeCapabilityLeaf {
    param(
        [Parameter(Mandatory)][string]$CapabilityId,
        [Parameter(Mandatory)][string]$CapabilityDigest
    )
    $safe = ($CapabilityId.ToLowerInvariant() -replace '[^a-z0-9_.-]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'capability' }
    if ($safe.Length -gt 48) { $safe = $safe.Substring(0, 48).Trim('-') }
    $prefix = $CapabilityDigest.Substring($CapabilityDigest.Length - 64, 12)
    return "$safe-$prefix"
}

function Assert-OwnerV2NoSubstitutedDrive {
    param([Parameter(Mandatory)][string]$Path)
    if (-not $IsWindows) { return }
    $root = [IO.Path]::GetPathRoot($Path)
    if ($root -cnotmatch '^[A-Za-z]:\\$') { return }
    $target = [Text.StringBuilder]::new(32768)
    $length = [DevPilot.OwnerOrchestrator.NativePaths]::QueryDosDevice(
        $root.Substring(0, 2), $target, $target.Capacity)
    if ($length -eq 0) {
        throw "durable-state root drive '$root' could not be resolved to a native device."
    }
    $nativeTarget = $target.ToString().Split([char]0, 2)[0]
    if ($nativeTarget.StartsWith('\??\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'durable-state root must not use a substituted drive.'
    }
}

function ConvertTo-OwnerV2CanonicalWindowsPath {
    param([Parameter(Mandatory)][string]$Path)
    if (-not $IsWindows) { return [IO.Path]::GetFullPath($Path) }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $suffix = [Collections.Generic.List[string]]::new()
    $existing = $fullPath
    while (-not (Test-Path -LiteralPath $existing)) {
        $leaf = Split-Path -Leaf $existing
        if ([string]::IsNullOrEmpty($leaf)) {
            throw "durable-state root '$Path' has no resolvable existing ancestor."
        }
        $suffix.Insert(0, $leaf)
        $parent = Split-Path -Parent $existing
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $existing) {
            throw "durable-state root '$Path' has no resolvable existing ancestor."
        }
        $existing = $parent
    }
    $longPath = [Text.StringBuilder]::new(32768)
    $length = [DevPilot.OwnerOrchestrator.NativePaths]::GetLongPathName(
        $existing, $longPath, $longPath.Capacity)
    if ($length -eq 0 -or $length -ge $longPath.Capacity) {
        throw "durable-state root '$Path' could not be expanded to its canonical Windows path."
    }
    $canonical = $longPath.ToString()
    foreach ($leaf in $suffix) { $canonical = Join-Path $canonical $leaf }
    return [IO.Path]::GetFullPath($canonical)
}

function Resolve-OwnerV2StateRoot {
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [switch]$Create
    )
    if ([string]::IsNullOrWhiteSpace($StateRoot) -or
        -not [IO.Path]::IsPathFullyQualified($StateRoot)) {
        throw 'durable-state root must be a non-empty absolute path.'
    }
    if ($IsWindows -and $StateRoot -match '^(\\\\[?.]\\|\\\?\?\\)') {
        throw 'durable-state root must not use a Windows device-path alias.'
    }
    if ($IsWindows -and $StateRoot -match '^[\\/]{2}') {
        throw 'durable-state root must not use a Windows UNC path.'
    }
    $provider = $null
    $drive = $null
    try {
        $providerPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
            $StateRoot, [ref]$provider, [ref]$drive)
    }
    catch {
        throw "durable-state root '$StateRoot' could not be resolved as a filesystem path."
    }
    if ($null -eq $provider -or $provider.Name -cne 'FileSystem') {
        throw 'durable-state root must use the FileSystem provider.'
    }
    if ($IsWindows -and $providerPath -match '^[\\/]{2}') {
        throw 'durable-state root must not resolve to a Windows UNC path.'
    }
    $nativeStateRoot = ConvertTo-OwnerV2CanonicalWindowsPath -Path $providerPath
    if ($IsWindows -and $nativeStateRoot -match '^(\\\\[?.]\\|\\\?\?\\)') {
        throw 'durable-state root must not resolve through a Windows device-path alias.'
    }
    Assert-OwnerV2NoSubstitutedDrive -Path $nativeStateRoot
    $repositoryRoot = ConvertTo-OwnerV2CanonicalWindowsPath -Path $script:OwnerV2RepositoryRoot
    if ($Create) {
        $created = $false
        $resolved = Resolve-AgentTrustedRoot -Path $nativeStateRoot -Kind durable-state `
            -RepositoryRoot $repositoryRoot -Create -CreatedByCaller ([ref]$created)
        return [IO.Path]::GetFullPath($resolved)
    }
    if ([string]::IsNullOrWhiteSpace($nativeStateRoot) -or
        -not [IO.Path]::IsPathFullyQualified($nativeStateRoot)) {
        throw 'durable-state root must be a non-empty absolute path.'
    }
    $resolved = Resolve-AgentTrustedRoot -Path $nativeStateRoot -Kind durable-state `
        -RepositoryRoot $repositoryRoot
    return [IO.Path]::GetFullPath($resolved)
}

function Assert-OwnerV2PathHasNoLinks {
    param([Parameter(Mandatory)][string]$Path)
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($item) {
            $isLink = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                $null -ne $item.LinkType
            if ($isLink) { throw "Owner v2 preview path '$Path' traverses link or reparse point '$current'." }
        }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
}

function Get-OwnerV2BaseRoot {
    param([Parameter(Mandatory)][string]$StateRoot)
    return Join-Path $StateRoot (Join-Path 'owner-v2-preview-state' 'schema-1')
}

function Get-OwnerV2CapabilityRoot {
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$CapabilityId,
        [Parameter(Mandatory)][string]$CapabilityDigest
    )
    $base = Get-OwnerV2BaseRoot -StateRoot $StateRoot
    $leaf = Get-OwnerV2SafeCapabilityLeaf -CapabilityId $CapabilityId -CapabilityDigest $CapabilityDigest
    return Join-Path (Join-Path $base 'capabilities') $leaf
}

function Initialize-OwnerV2CapabilityRoot {
    param([Parameter(Mandatory)][string]$CapabilityRoot)
    foreach ($leaf in @('declarations', 'records', 'evidence', 'observations', 'telemetry', 'index', 'staging')) {
        $path = Join-Path $CapabilityRoot $leaf
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
        Assert-OwnerV2PathHasNoLinks -Path $path
    }
}

function Write-OwnerV2AtomicText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content,
        [switch]$Immutable
    )
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    Assert-OwnerV2PathHasNoLinks -Path $directory
    $utf8 = [Text.UTF8Encoding]::new($false)
    $bytes = $utf8.GetBytes($Content)
    if ($Immutable -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $existing = [IO.File]::ReadAllBytes($Path)
        $same = $existing.Length -eq $bytes.Length
        if ($same) {
            for ($index = 0; $index -lt $bytes.Length; $index++) {
                if ($existing[$index] -ne $bytes[$index]) { $same = $false; break }
            }
        }
        if (-not $same) { throw "Immutable Owner v2 artifact '$Path' already exists with different bytes." }
        return $false
    }
    $tempName = '.owner-v2-stage-' + ([guid]::NewGuid().ToString('N')) + '.json'
    $tempPath = Join-Path $directory $tempName
    $stream = [IO.File]::Open($tempPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
    [IO.File]::Move($tempPath, $Path, -not $Immutable)
    return $true
}

function Write-OwnerV2AtomicJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowNull()][object]$Value,
        [switch]$Immutable
    )
    return Write-OwnerV2AtomicText -Path $Path -Content (ConvertTo-OwnerV2CanonicalJson -Value $Value) -Immutable:$Immutable
}

function Read-OwnerV2JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Owner v2 JSON file '$Path' does not exist." }
    Assert-OwnerV2PathHasNoLinks -Path $Path
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 64
}

function Get-OwnerV2RecordPath {
    param([Parameter(Mandatory)][string]$CapabilityRoot, [Parameter(Mandatory)][string]$Identity)
    return Join-Path (Join-Path $CapabilityRoot 'records') "$Identity.json"
}

function Get-OwnerV2DeclarationPath {
    param([Parameter(Mandatory)][string]$CapabilityRoot, [Parameter(Mandatory)][string]$Identity)
    return Join-Path (Join-Path $CapabilityRoot 'declarations') "$Identity.json"
}

function Get-OwnerV2EvidencePath {
    param([Parameter(Mandatory)][string]$CapabilityRoot, [Parameter(Mandatory)][string]$Identity)
    return Join-Path (Join-Path $CapabilityRoot 'evidence') "$Identity.json"
}

function Get-OwnerV2ObservationPath {
    param([Parameter(Mandatory)][string]$CapabilityRoot, [Parameter(Mandatory)][string]$Identity)
    return Join-Path (Join-Path $CapabilityRoot 'observations') "$Identity.json"
}

function Get-OwnerV2TelemetryPath {
    param([Parameter(Mandatory)][string]$CapabilityRoot, [Parameter(Mandatory)][string]$Identity)
    return Join-Path (Join-Path $CapabilityRoot 'telemetry') "$Identity.json"
}

function Assert-OwnerV2Record {
    param([Parameter(Mandatory)][Collections.IDictionary]$Record)
    Assert-OwnerV2NoUnsafeShape -Value $Record
    Assert-OwnerV2ExactKeys -Value $Record -Name record -Expected @(
        'schemaVersion', 'kind', 'identity', 'stateDigest', 'mode', 'capabilityId',
        'capabilityDigest', 'subjectDigest', 'headDigest', 'ruleDigest', 'modelDigest',
        'configDigest', 'acquisitionPayloadDigest', 'state', 'attempts', 'maxAttempts',
        'lease', 'createdUtc', 'updatedUtc', 'declarationPath', 'evidencePath',
        'observationPath', 'resultDigest', 'incompleteReason'
    )
    if ([int]$Record.schemaVersion -ne 1 -or [string]$Record.kind -cne 'owner-v2-preview-record') {
        throw 'Owner v2 record has an unsupported schema or kind.'
    }
    if ([string]$Record.state -cnotin $script:OwnerV2States) { throw 'Owner v2 record state is invalid.' }
    if ([int]$Record.attempts -lt 0 -or [int]$Record.attempts -gt [int]$Record.maxAttempts -or
        [int]$Record.maxAttempts -lt 1 -or [int]$Record.maxAttempts -gt 8) {
        throw 'Owner v2 record attempt counters are invalid.'
    }
    foreach ($name in @('stateDigest', 'capabilityDigest', 'subjectDigest', 'headDigest', 'ruleDigest',
            'modelDigest', 'configDigest', 'acquisitionPayloadDigest')) {
        Assert-OwnerV2Digest -Value ([string]$Record[$name]) -Name $name
    }
}

function New-OwnerV2AcquisitionContract {
    param([Parameter(Mandatory)][Collections.IDictionary]$Entry)
    $limits = if ([string]$Entry.mode -ceq 'live') {
        New-OwnerAdapterLimits -MaximumFiles 64 -MaximumBytes 16777216 -MaximumReads 128
    }
    else {
        New-OwnerAdapterLimits
    }
    return New-OwnerAcquisitionContract `
        -RepositoryId ([string]$Entry.subject.repositoryId) `
        -ProjectId ([string]$Entry.subject.projectId) `
        -PullRequestId ([long]$Entry.subject.pullRequestId) `
        -SourceCommit ([string]$Entry.head.sourceCommit) `
        -TargetCommit ([string]$Entry.target.targetCommit) `
        -TargetRef ([string]$Entry.target.targetRef) `
        -RuleRepositoryId ([string]$Entry.rule.repositoryId) `
        -RulePath ([string]$Entry.rule.path) `
        -RuleCommit ([string]$Entry.rule.commit) `
        -RuleSection ([string]$Entry.rule.section) `
        -RuleHash ([string]$Entry.rule.hash) `
        -RuleLength ([long]$Entry.rule.length) `
        -ConfigId ([string]$Entry.config.id) `
        -ConfigDigest ([string]$Entry.config.digest) `
        -CapabilityId ([string]$Entry.capability.id) `
        -CapabilityDigest ([string]$Entry.capability.digest) `
        -Limits $limits
}

function ConvertTo-OwnerV2ModelReplayRecord {
    param([Parameter(Mandatory)][Collections.IDictionary]$Record)
    Assert-OwnerV2ExactKeys -Value $Record -Name replay.modelRecords -Expected @(
        'executionUnitId', 'nonce', 'inputDigest', 'subjectBinding', 'responseBytesBase64'
    )
    Assert-OwnerV2SafeText -Value ([string]$Record.executionUnitId) -Name executionUnitId -MaximumLength 128
    Assert-OwnerV2SafeText -Value ([string]$Record.nonce) -Name nonce -MaximumLength 64
    Assert-OwnerV2Digest -Value ([string]$Record.inputDigest) -Name inputDigest
    Assert-OwnerV2Digest -Value ([string]$Record.subjectBinding) -Name subjectBinding
    $base64 = [string]$Record.responseBytesBase64
    if ($base64 -cnotmatch '^[A-Za-z0-9+/]*={0,2}$' -or $base64.Length -gt 1398104) {
        throw 'Replay response bytes must be bounded canonical base64.'
    }
    $bytes = [Convert]::FromBase64String($base64)
    if ([Convert]::ToBase64String($bytes) -cne $base64) { throw 'Replay response bytes were not canonical base64.' }
    return [pscustomobject][ordered]@{
        executionUnitId = [string]$Record.executionUnitId
        nonce = [string]$Record.nonce
        inputDigest = [string]$Record.inputDigest
        subjectBinding = [string]$Record.subjectBinding
        responseBytes = $bytes
    }
}

function Assert-OwnerV2PackageBinding {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Entry,
        [Parameter(Mandatory)][Collections.IDictionary]$Package
    )
    function TestIdentity {
        param(
            [Parameter(Mandatory)][Collections.IDictionary]$Value,
            [Parameter(Mandatory)][string]$Name
        )
        if ([string]$Value.repositoryId -cne [string]$Entry.subject.repositoryId -or
            [string]$Value.projectId -cne [string]$Entry.subject.projectId -or
            [long]$Value.pullRequestId -ne [long]$Entry.subject.pullRequestId -or
            [string]$Value.sourceCommit -cne [string]$Entry.head.sourceCommit -or
            [string]$Value.targetCommit -cne [string]$Entry.target.targetCommit -or
            [string]$Value.targetRef -cne [string]$Entry.target.targetRef) {
            throw "Replay acquisition package $Name did not match the exact manifest subject/head/target binding."
        }
    }

    foreach ($name in @('subjectBefore', 'subjectAfter')) {
        $value = Get-OwnerV2Member -Value $Package -Name $name
        if ($value -isnot [Collections.IDictionary]) { throw "Replay acquisition package missing $name." }
        TestIdentity -Value $value -Name $name
    }
    $rule = Get-OwnerV2Member -Value $Package -Name 'rule'
    if ($rule -isnot [Collections.IDictionary]) { throw 'Replay acquisition package missing rule.' }
    TestIdentity -Value $rule -Name 'rule'
    if ([string]$rule.ruleRepositoryId -cne [string]$Entry.rule.repositoryId -or
        [string]$rule.rulePath -cne [string]$Entry.rule.path -or
        [string]$rule.ruleCommit -cne [string]$Entry.rule.commit -or
        [string]$rule.ruleSection -cne [string]$Entry.rule.section -or
        [string]$rule.ruleHash -cne [string]$Entry.rule.hash -or
        [long]$rule.ruleLength -ne [long]$Entry.rule.length) {
        throw 'Replay acquisition package rule did not match the exact manifest rule binding.'
    }
    foreach ($page in @(Get-OwnerV2Member -Value $Package -Name 'changePages')) {
        if ($page -isnot [Collections.IDictionary]) { throw 'Replay acquisition package page was malformed.' }
        TestIdentity -Value $page -Name 'changePages'
    }
    foreach ($file in @(Get-OwnerV2Member -Value $Package -Name 'files')) {
        if ($file -isnot [Collections.IDictionary]) { throw 'Replay acquisition package file was malformed.' }
        TestIdentity -Value $file -Name 'files'
    }
}

function ConvertTo-OwnerV2Declaration {
    param([Parameter(Mandatory)][Collections.IDictionary]$Entry)

    Assert-OwnerV2NoUnsafeShape -Value $Entry
    $mode = [string](Get-OwnerV2Member -Value $Entry -Name mode)
    $expectedEntryKeys = if ($mode -ceq 'replay') {
        @('id', 'mode', 'subject', 'head', 'target', 'rule', 'capability', 'model', 'config', 'acquisition', 'replay')
    }
    else {
        @('id', 'mode', 'subject', 'head', 'target', 'rule', 'capability', 'model', 'config', 'acquisition')
    }
    Assert-OwnerV2ExactKeys -Value $Entry -Name entry -Expected $expectedEntryKeys
    if ($mode -cnotin @('replay', 'live')) { throw 'Owner v2 preview entry mode must be replay or live.' }
    Assert-OwnerV2SafeText -Value ([string]$Entry.id) -Name id -MaximumLength 128
    if ([string]$Entry.id -cnotmatch $script:OwnerV2SafeIdPattern) { throw 'Entry id must be a safe identifier.' }

    Assert-OwnerV2ExactKeys -Value $Entry.subject -Name subject -Expected @('repositoryId', 'projectId', 'pullRequestId')
    Assert-OwnerV2ExactKeys -Value $Entry.head -Name head -Expected @('sourceCommit')
    Assert-OwnerV2ExactKeys -Value $Entry.target -Name target -Expected @('targetCommit', 'targetRef')
    Assert-OwnerV2ExactKeys -Value $Entry.rule -Name rule -Expected @('repositoryId', 'path', 'commit', 'section', 'hash', 'length')
    Assert-OwnerV2ExactKeys -Value $Entry.capability -Name capability -Expected @('id', 'digest')
    Assert-OwnerV2ExactKeys -Value $Entry.model -Name model -Expected @('id', 'digest')
    Assert-OwnerV2ExactKeys -Value $Entry.config -Name config -Expected @('id', 'digest')
    $expectedAcquisitionKeys = if ($mode -ceq 'replay') { @('payloadDigest', 'package') } else { @('payloadDigest') }
    Assert-OwnerV2ExactKeys -Value $Entry.acquisition -Name acquisition -Expected $expectedAcquisitionKeys

    foreach ($item in @(
            @{ Value = [string]$Entry.subject.repositoryId; Name = 'subject.repositoryId'; Max = 256 },
            @{ Value = [string]$Entry.subject.projectId; Name = 'subject.projectId'; Max = 256 },
            @{ Value = [string]$Entry.target.targetRef; Name = 'target.targetRef'; Max = 512 },
            @{ Value = [string]$Entry.rule.repositoryId; Name = 'rule.repositoryId'; Max = 256 },
            @{ Value = [string]$Entry.rule.path; Name = 'rule.path'; Max = 512 },
            @{ Value = [string]$Entry.rule.section; Name = 'rule.section'; Max = 256 },
            @{ Value = [string]$Entry.capability.id; Name = 'capability.id'; Max = 256 },
            @{ Value = [string]$Entry.model.id; Name = 'model.id'; Max = 128 },
            @{ Value = [string]$Entry.config.id; Name = 'config.id'; Max = 256 }
        )) {
        Assert-OwnerV2SafeText -Value $item.Value -Name $item.Name -MaximumLength $item.Max
    }
    if ([long]$Entry.subject.pullRequestId -lt 1 -or [long]$Entry.subject.pullRequestId -gt 9223372036854775807) {
        throw 'subject.pullRequestId is outside the Owner v2 preview bounds.'
    }
    Assert-OwnerV2Commit -Value ([string]$Entry.head.sourceCommit) -Name head.sourceCommit
    Assert-OwnerV2Commit -Value ([string]$Entry.target.targetCommit) -Name target.targetCommit
    Assert-OwnerV2Commit -Value ([string]$Entry.rule.commit) -Name rule.commit
    Assert-OwnerV2Digest -Value ([string]$Entry.rule.hash) -Name rule.hash
    Assert-OwnerV2Digest -Value ([string]$Entry.capability.digest) -Name capability.digest
    Assert-OwnerV2Digest -Value ([string]$Entry.model.digest) -Name model.digest
    Assert-OwnerV2Digest -Value ([string]$Entry.config.digest) -Name config.digest
    Assert-OwnerV2Digest -Value ([string]$Entry.acquisition.payloadDigest) -Name acquisition.payloadDigest
    if ([long]$Entry.rule.length -lt 1 -or [long]$Entry.rule.length -gt 134217728) {
        throw 'rule.length is outside the Owner v2 preview bounds.'
    }

    $contract = New-OwnerV2AcquisitionContract -Entry $Entry
    $replayRecords = @()
    $evidence = $null
    if ($mode -ceq 'replay') {
        Assert-OwnerV2ExactKeys -Value $Entry.replay -Name replay -Expected @('modelRecords')
        $replayRecords = @($Entry.replay.modelRecords | ForEach-Object { ConvertTo-OwnerV2ModelReplayRecord -Record $_ })
        Assert-OwnerV2PackageBinding -Entry $Entry -Package $Entry.acquisition.package
        $fixture = New-OwnerReplayFixture -Package $Entry.acquisition.package
        if ($fixture.PayloadDigest -cne [string]$Entry.acquisition.payloadDigest) {
            throw 'Replay acquisition package did not match the independently pinned payload digest.'
        }
        $evidence = [ordered]@{
            schemaVersion = 2
            kind = 'owner-v2-preview-replay-evidence'
            acquisitionPayloadDigest = [string]$Entry.acquisition.payloadDigest
            package = ConvertTo-OwnerV2JsonValue -Value $Entry.acquisition.package
        }
    }
    else {
        $evidence = [ordered]@{
            schemaVersion = 1
            kind = 'owner-v2-preview-live-evidence-pin'
            acquisitionPayloadDigest = [string]$Entry.acquisition.payloadDigest
        }
    }

    $declarationForDigest = [ordered]@{
        schemaVersion = 1
        kind = 'owner-v2-preview-declaration'
        mode = $mode
        subject = ConvertTo-OwnerV2JsonValue -Value $Entry.subject
        head = ConvertTo-OwnerV2JsonValue -Value $Entry.head
        target = ConvertTo-OwnerV2JsonValue -Value $Entry.target
        rule = ConvertTo-OwnerV2JsonValue -Value $Entry.rule
        capability = ConvertTo-OwnerV2JsonValue -Value $Entry.capability
        model = ConvertTo-OwnerV2JsonValue -Value $Entry.model
        config = ConvertTo-OwnerV2JsonValue -Value $Entry.config
        acquisitionPayloadDigest = [string]$Entry.acquisition.payloadDigest
        replay = if ($mode -ceq 'replay') {
            [ordered]@{
                modelRecords = @($Entry.replay.modelRecords | ForEach-Object { ConvertTo-OwnerV2JsonValue -Value $_ })
            }
        }
        else { $null }
    }
    $stateDigest = Get-OwnerV2Digest -Value $declarationForDigest
    $identity = $stateDigest.Substring(10)
    $declaration = [ordered]@{} + $declarationForDigest
    $declaration['stateDigest'] = $stateDigest
    $declaration['facadeBinding'] = [ordered]@{
        bindingId = $contract.Binding.BindingId
        subjectKey = $contract.Binding.SubjectKey
        headKey = $contract.Binding.HeadKey
        ruleKey = $contract.Binding.RuleKey
        capabilityKey = $contract.Binding.CapabilityKey
    }
    return [pscustomobject][ordered]@{
        Identity = $identity
        StateDigest = $stateDigest
        Declaration = $declaration
        Evidence = $evidence
        Contract = $contract
        ReplayRecords = @($replayRecords)
        CapabilityRoot = $null
        ManifestEntry = ConvertTo-OwnerV2JsonValue -Value $Entry
    }
}

function Read-OwnerV2Manifest {
    param([Parameter(Mandatory)][string]$ManifestPath)
    if ([string]::IsNullOrWhiteSpace($ManifestPath) -or -not [IO.Path]::IsPathFullyQualified($ManifestPath)) {
        throw 'ManifestPath must be a non-empty absolute path.'
    }
    $resolved = Assert-AgentTrustedFile -Path $ManifestPath
    $manifest = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json -AsHashtable -Depth 64
    Assert-OwnerV2NoUnsafeShape -Value $manifest
    Assert-OwnerV2ExactKeys -Value $manifest -Name manifest -Expected @('schemaVersion', 'kind', 'entries')
    if ([int]$manifest.schemaVersion -ne 1 -or [string]$manifest.kind -cne 'owner-v2-preview-cohort') {
        throw 'Owner v2 preview manifest must use schemaVersion 1 and kind owner-v2-preview-cohort.'
    }
    $entries = @($manifest.entries)
    if ($entries.Count -lt 1 -or $entries.Count -gt $script:OwnerV2MaximumEntries) {
        throw "Owner v2 preview manifest must contain 1 to $script:OwnerV2MaximumEntries entries."
    }
    $declarations = @($entries | ForEach-Object { ConvertTo-OwnerV2Declaration -Entry $_ } |
        Sort-Object -Property StateDigest)
    $manifestDigest = Get-OwnerV2Digest -Value ([ordered]@{
            schemaVersion = 1
            kind = 'owner-v2-preview-cohort'
            entries = @($declarations | ForEach-Object { $_.Declaration })
        })
    return [pscustomobject][ordered]@{
        Path = $resolved
        Digest = $manifestDigest
        Entries = @($declarations)
    }
}

function New-OwnerV2Record {
    param(
        [Parameter(Mandatory)][object]$Entry,
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [int]$MaxAttempts = 3
    )
    if ($MaxAttempts -lt 1 -or $MaxAttempts -gt 8) { throw 'MaxAttempts must be between 1 and 8.' }
    $identity = $Entry.Identity
    $nowText = 'utc:' + ([DateTime]::UtcNow).ToString('o')
    return [ordered]@{
        schemaVersion = 1
        kind = 'owner-v2-preview-record'
        identity = $identity
        stateDigest = $Entry.StateDigest
        mode = [string]$Entry.Declaration.mode
        capabilityId = [string]$Entry.Declaration.capability.id
        capabilityDigest = [string]$Entry.Declaration.capability.digest
        subjectDigest = Get-OwnerV2Digest -Value $Entry.Declaration.subject
        headDigest = Get-OwnerV2Digest -Value $Entry.Declaration.head
        ruleDigest = Get-OwnerV2Digest -Value $Entry.Declaration.rule
        modelDigest = Get-OwnerV2Digest -Value $Entry.Declaration.model
        configDigest = Get-OwnerV2Digest -Value $Entry.Declaration.config
        acquisitionPayloadDigest = [string]$Entry.Declaration.acquisitionPayloadDigest
        state = 'pending'
        attempts = 0
        maxAttempts = $MaxAttempts
        lease = $null
        createdUtc = $nowText
        updatedUtc = $nowText
        declarationPath = "declarations/$identity.json"
        evidencePath = "evidence/$identity.json"
        observationPath = "observations/$identity.json"
        resultDigest = $null
        incompleteReason = $null
    }
}

function Get-OwnerV2IndexRecord {
    param([Parameter(Mandatory)][Collections.IDictionary]$Record)
    return [ordered]@{
        identity = [string]$Record.identity
        stateDigest = [string]$Record.stateDigest
        state = [string]$Record.state
        mode = [string]$Record.mode
        capabilityId = [string]$Record.capabilityId
        capabilityDigest = [string]$Record.capabilityDigest
        subjectDigest = [string]$Record.subjectDigest
        headDigest = [string]$Record.headDigest
        ruleDigest = [string]$Record.ruleDigest
        modelDigest = [string]$Record.modelDigest
        configDigest = [string]$Record.configDigest
        attempts = [int]$Record.attempts
        maxAttempts = [int]$Record.maxAttempts
        updatedUtc = [string]$Record.updatedUtc
        incompleteReason = $Record.incompleteReason
    }
}

function Get-OwnerV2CapabilityRecords {
    param([Parameter(Mandatory)][string]$CapabilityRoot)
    $recordDir = Join-Path $CapabilityRoot 'records'
    if (-not (Test-Path -LiteralPath $recordDir -PathType Container)) { return @() }
    Assert-OwnerV2PathHasNoLinks -Path $recordDir
    $records = [Collections.Generic.List[object]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $recordDir -Filter '*.json' -File | Sort-Object Name)) {
        if ($file.Name -cmatch '^\.owner-v2-stage-[0-9a-f]{32}\.json$') { continue }
        if ($file.Name -cnotmatch '^[0-9a-f]{64}\.json$') { throw "Malformed Owner v2 record filename '$($file.Name)'." }
        $record = Read-OwnerV2JsonFile -Path $file.FullName
        Assert-OwnerV2Record -Record $record
        [void]$records.Add($record)
    }
    return @($records)
}

function Write-OwnerV2Index {
    param([Parameter(Mandatory)][string]$CapabilityRoot)
    $records = @(Get-OwnerV2CapabilityRecords -CapabilityRoot $CapabilityRoot |
        Sort-Object -Property @{ Expression = { [string]$_.identity }; Ascending = $true })
    $index = [ordered]@{
        schemaVersion = 1
        kind = 'owner-v2-preview-index'
        records = @($records | ForEach-Object { Get-OwnerV2IndexRecord -Record $_ })
    }
    [void](Write-OwnerV2AtomicJson -Path (Join-Path (Join-Path $CapabilityRoot 'index') 'records.json') -Value $index)
    return $index
}

function Test-OwnerV2LeaseStale {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Record,
        [Parameter(Mandatory)][DateTime]$NowUtc
    )
    if ([string]$Record.state -cne 'running') { return $false }
    if ($null -eq $Record.lease -or $Record.lease -isnot [Collections.IDictionary] -or
        -not $Record.lease.Contains('expiresUtc')) { return $true }
    $expires = [DateTime]::MinValue
    $expiresText = [string]$Record.lease.expiresUtc
    if ($expiresText.StartsWith('utc:', [StringComparison]::Ordinal)) {
        $expiresText = $expiresText.Substring(4)
    }
    if (-not [DateTime]::TryParse($expiresText, [ref]$expires)) { return $true }
    return $expires.ToUniversalTime() -le $NowUtc
}

function Assert-OwnerV2PipelineNoWrites {
    param(
        [Parameter(Mandatory)][object]$PipelineResult,
        [Parameter(Mandatory)][Collections.IDictionary]$Observation
    )
    if ($null -eq $PipelineResult.preview -or $PipelineResult.preview.writeAllowed -ne $false -or
        $null -eq $PipelineResult.delivery -or [string]$PipelineResult.delivery.state -cne 'not-authorized' -or
        $PipelineResult.delivery.attempted -ne $false -or [int]$PipelineResult.delivery.writeCount -ne 0) {
        throw 'Owner v2 orchestrator refuses any facade result with delivery authority or attempted writes.'
    }
    if ([int]$Observation.effects.providerWrites -ne 0 -or [int]$Observation.effects.writeToolInvocations -ne 0) {
        throw 'Owner v2 observation reported provider or tool writes.'
    }
}

function Invoke-OwnerV2Replay {
    param([Parameter(Mandatory)][object]$Entry)
    $fixture = New-OwnerReplayFixture -Package $Entry.ManifestEntry.acquisition.package
    $acquisition = New-OwnerReplayAcquisitionAdapter -Contract $Entry.Contract `
        -Fixture $fixture -ExpectedPayloadDigest ([string]$Entry.Declaration.acquisitionPayloadDigest)
    $runnerFixture = New-OwnerModelReplayFixture -Records @($Entry.ReplayRecords)
    $runner = New-OwnerModelReplayRunner -Fixture $runnerFixture
    $capability = New-OwnerV2CapabilityAdapter -Runner $runner `
        -CapabilityId ([string]$Entry.Declaration.capability.id) `
        -CapabilityDigest ([string]$Entry.Declaration.capability.digest)
    $result = Invoke-OwnerReviewPipeline -Binding $Entry.Contract.Binding `
        -AcquisitionAdapter $acquisition -CapabilityAdapter $capability
    $observation = ConvertTo-OwnerV2Observation -PipelineResult $result -Runner $runner
    Assert-OwnerV2PipelineNoWrites -PipelineResult $result -Observation $observation
    return [pscustomobject][ordered]@{
        PipelineResult = $result
        Observation = $observation
    }
}

function New-OwnerV2PersistedTelemetry {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Telemetry,
        [Parameter(Mandatory)][object]$Preflight
    )
    $persisted = [ordered]@{}
    foreach ($key in @($Telemetry.Keys)) { $persisted[[string]$key] = $Telemetry[$key] }
    $persisted['writeToolInvocations'] = 0
    $persisted['acceptedArgvRisk'] = [ordered]@{
        explicitlyEnabled = $true
        accepted = [string]$Preflight.promptTransport -ceq 'argv' -and
            [bool]$Preflight.localProcessMetadataExposure
        promptTransport = [string]$Preflight.promptTransport
        localProcessMetadataExposure = [bool]$Preflight.localProcessMetadataExposure
        risk = [string]$Preflight.risk
    }
    return $persisted
}

function New-OwnerV2PreflightTelemetry {
    param(
        [Parameter(Mandatory)][object]$Preflight,
        [Parameter(Mandatory)][string]$Reason
    )
    return New-OwnerV2PersistedTelemetry -Preflight $Preflight -Telemetry ([ordered]@{
            attempts = 0
            modelStarts = 0
            modelCalls = 0
            modelStartsMinimum = 0
            latencyMs = 0
            refusalReason = $Reason
            providerWrites = 0
            effectiveTools = @($Preflight.effectiveTools)
            provider = [ordered]@{
                kind = 'copilot-cli'
                modelIdentity = [string]$Preflight.modelIdentity
                promptTransport = [string]$Preflight.promptTransport
                localProcessMetadataExposure = [bool]$Preflight.localProcessMetadataExposure
            }
            policy = [ordered]@{
                availableTools = @($Preflight.effectiveTools)
                providerWrite = $false
            }
            records = @()
        })
}

function New-OwnerV2LiveOutcome {
    param(
        [Parameter(Mandatory)][object]$Entry,
        [Parameter(Mandatory)][string]$Reason,
        [AllowNull()][object]$Telemetry
    )
    return [pscustomobject][ordered]@{
        Observation = New-OwnerV2LiveUnavailableObservation -Entry $Entry -Reason $Reason
        Telemetry = $Telemetry
        State = 'incomplete'
        Reason = $Reason
    }
}

function Invoke-OwnerV2Live {
    param(
        [Parameter(Mandatory)][object]$Entry,
        [Parameter(Mandatory)][bool]$EnableLiveModel,
        [AllowNull()][object]$AcquisitionProvider,
        [AllowNull()][object]$ModelProvider,
        [AllowNull()][string]$Model,
        [AllowNull()][string]$CredentialEnvironmentName
    )
    if (-not $EnableLiveModel) {
        return New-OwnerV2LiveOutcome -Entry $Entry -Reason 'live-model-disabled'
    }
    if ($null -eq $AcquisitionProvider) {
        return New-OwnerV2LiveOutcome -Entry $Entry -Reason 'acquisition-provider-unavailable'
    }

    $provider = $ModelProvider
    if ($null -eq $provider) {
        if ([string]::IsNullOrWhiteSpace($Model) -or
            [string]::IsNullOrWhiteSpace($CredentialEnvironmentName)) {
            return New-OwnerV2LiveOutcome -Entry $Entry `
                -Reason 'live-model-configuration-missing'
        }
        $provider = New-OwnerCopilotCliModelProvider -Model $Model `
            -CredentialEnvironmentName $CredentialEnvironmentName
    }
    $preflight = Test-OwnerModelProviderPreflight -Provider $provider
    if ([string]$preflight.modelIdentity -cne [string]$Entry.Declaration.model.id) {
        return New-OwnerV2LiveOutcome -Entry $Entry -Reason 'model-binding-mismatch'
    }
    if (-not [bool]$preflight.available) {
        $reason = [string]$preflight.reason
        return New-OwnerV2LiveOutcome -Entry $Entry -Reason $reason `
            -Telemetry (New-OwnerV2PreflightTelemetry -Preflight $preflight -Reason $reason)
    }

    $runner = New-OwnerModelProcessRunner -Provider $provider `
        -Limits (New-OwnerModelRunnerLimits -MaximumAttemptsPerUnit 1) `
        -EnableRealLaunch
    $acquisition = New-OwnerProductionAcquisitionAdapter `
        -Contract $Entry.Contract -Provider $AcquisitionProvider
    $capability = New-OwnerV2CapabilityAdapter -Runner $runner `
        -CapabilityId ([string]$Entry.Declaration.capability.id) `
        -CapabilityDigest ([string]$Entry.Declaration.capability.digest)
    $result = Invoke-OwnerReviewPipeline -Binding $Entry.Contract.Binding `
        -AcquisitionAdapter $acquisition -CapabilityAdapter $capability
    $observation = ConvertTo-OwnerV2Observation -PipelineResult $result -Runner $runner `
        -ImplementationId 'owner-v2-preview-orchestrator' -ImplementationVersion '0.3.0'
    Assert-OwnerV2PipelineNoWrites -PipelineResult $result -Observation $observation
    $telemetry = New-OwnerV2PersistedTelemetry `
        -Telemetry (Get-OwnerModelRunnerTelemetry -Runner $runner) `
        -Preflight $preflight
    $state = if ([string]$observation.lifecycle.status -ceq 'completed') { 'completed' }
    elseif ([string]$observation.lifecycle.status -ceq 'incomplete') { 'incomplete' }
    else { 'unknown' }
    return [pscustomobject][ordered]@{
        Observation = $observation
        Telemetry = $telemetry
        State = $state
        Reason = [string]$observation.execution.incompleteReason
    }
}

function New-OwnerV2LiveUnavailableObservation {
    param(
        [Parameter(Mandatory)][object]$Entry,
        [Parameter(Mandatory)][string]$Reason
    )
    $observation = [ordered]@{
        schemaVersion = 2
        kind = 'owner-observation'
        implementation = [ordered]@{ id = 'owner-v2-preview-orchestrator'; version = '0.3.0' }
        capability = [string]$Entry.Declaration.capability.id
        subject = [ordered]@{
            pullRequestId = [long]$Entry.Declaration.subject.pullRequestId
            repositoryId = [string]$Entry.Declaration.subject.repositoryId
            headCommit = [string]$Entry.Declaration.head.sourceCommit
            targetCommit = [string]$Entry.Declaration.target.targetCommit
            targetRef = [string]$Entry.Declaration.target.targetRef
        }
        rule = [ordered]@{
            identity = 'rule:' + ([string]$Entry.Declaration.rule.hash).Substring(10)
            path = ConvertTo-OwnerRepositoryPath -Path ([string]$Entry.Declaration.rule.path)
            section = [string]$Entry.Declaration.rule.section
            commit = [string]$Entry.Declaration.rule.commit
            sha256 = ([string]$Entry.Declaration.rule.hash).Substring(10)
        }
        lifecycle = [ordered]@{
            status = 'incomplete'
            prepared = $true
            completed = $false
            incomplete = $true
            pending = $false
        }
        counts = [ordered]@{
            checked = 0
            eligible = 0
            advisory = 0
            violations = 0
            unknown = 0
            uncovered = 1
        }
        findingsComplete = $false
        findings = @()
        execution = [ordered]@{
            attempts = 0
            modelStarts = 0
            latencyMs = 0
            refusalReason = $Reason
            incompleteReason = $Reason
        }
        effects = [ordered]@{
            providerWrites = 0
            writeToolInvocations = 0
            dedupe = [ordered]@{ created = 0; updated = 0; noOp = 0; wouldCreate = 0; wouldUpdate = 0; unknown = 1 }
            operatorIntervention = $true
        }
        measurements = [ordered]@{
            counts = [ordered]@{
                checked = New-OwnerMeasurement -Status measured -Value 0
                eligible = New-OwnerMeasurement -Status measured -Value 0
                advisory = New-OwnerMeasurement -Status measured -Value 0
                violations = New-OwnerMeasurement -Status measured -Value 0
                unknown = New-OwnerMeasurement -Status measured -Value 0
                uncovered = New-OwnerMeasurement -Status measured -Value 1
            }
            execution = [ordered]@{
                attempts = New-OwnerMeasurement -Status measured -Value 0
                modelStarts = New-OwnerMeasurement -Status measured -Value 0
                latencyMs = New-OwnerMeasurement -Status measured -Value 0
            }
            effects = [ordered]@{
                providerWrites = New-OwnerMeasurement -Status measured -Value 0
                writeToolInvocations = New-OwnerMeasurement -Status measured -Value 0
                operatorIntervention = New-OwnerMeasurement -Status measured -Value $true
            }
        }
        sourceArtifacts = @(
            [ordered]@{
                kind = 'owner-v2-live-acquisition-pin'
                sha256 = ([string]$Entry.Declaration.acquisitionPayloadDigest).Substring(10)
                signature = 'not-applicable'
            }
        )
        validationErrors = @("$Reason`: live Owner v2 preview did not start a model")
    }
    $observationJson = $observation | ConvertTo-Json -Depth 64 -Compress
    if (-not (Test-Json -Json $observationJson `
            -SchemaFile $script:OwnerV2ObservationSchemaPath -ErrorAction Stop)) {
        throw 'Owner v2 unavailable observation failed owner-observation schema validation.'
    }
    return $observation
}

function Invoke-OwnerV2PreviewPrepare {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$ManifestPath,
        [int]$MaxAttempts = 3
    )
    $resolvedStateRoot = Resolve-OwnerV2StateRoot -StateRoot $StateRoot -Create
    $manifest = Read-OwnerV2Manifest -ManifestPath $ManifestPath
    $prepared = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in @($manifest.Entries)) {
        if (-not $seen.Add($entry.Identity)) { continue }
        $capabilityRoot = Get-OwnerV2CapabilityRoot -StateRoot $resolvedStateRoot `
            -CapabilityId ([string]$entry.Declaration.capability.id) `
            -CapabilityDigest ([string]$entry.Declaration.capability.digest)
        $entry.CapabilityRoot = $capabilityRoot
        Initialize-OwnerV2CapabilityRoot -CapabilityRoot $capabilityRoot
        $lock = Enter-AgentLock -Path (Join-Path $capabilityRoot 'owner-v2-preview.lock') -AgentName 'owner-v2-orchestrator'
        try {
            $identity = $entry.Identity
            $declarationPath = Get-OwnerV2DeclarationPath -CapabilityRoot $capabilityRoot -Identity $identity
            $evidencePath = Get-OwnerV2EvidencePath -CapabilityRoot $capabilityRoot -Identity $identity
            $recordPath = Get-OwnerV2RecordPath -CapabilityRoot $capabilityRoot -Identity $identity
            [void](Write-OwnerV2AtomicJson -Path $declarationPath -Value $entry.Declaration -Immutable)
            [void](Write-OwnerV2AtomicJson -Path $evidencePath -Value $entry.Evidence -Immutable)
            Invoke-OwnerV2Checkpoint -Name 'prepare-before-publish'
            $created = $false
            if (Test-Path -LiteralPath $recordPath -PathType Leaf) {
                $record = Read-OwnerV2JsonFile -Path $recordPath
                Assert-OwnerV2Record -Record $record
            }
            else {
                $record = New-OwnerV2Record -Entry $entry -CapabilityRoot $capabilityRoot -MaxAttempts $MaxAttempts
                [void](Write-OwnerV2AtomicJson -Path $recordPath -Value $record)
                $created = $true
            }
            $index = Write-OwnerV2Index -CapabilityRoot $capabilityRoot
            [void]$prepared.Add([ordered]@{
                    identity = $identity
                    stateDigest = $entry.StateDigest
                    capabilityRoot = $capabilityRoot
                    state = [string]$record.state
                    created = $created
                })
        }
        finally {
            Exit-AgentLock -Stream $lock
        }
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        kind = 'owner-v2-preview-prepare-result'
        stateRoot = $resolvedStateRoot
        manifestDigest = $manifest.Digest
        records = @($prepared | Sort-Object identity)
    }
}

function Invoke-OwnerV2PreviewRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$ManifestPath,
        [int]$LeaseSeconds = 300,
        [switch]$EnableLiveModel,
        [AllowNull()][object]$LiveAcquisitionProvider,
        [AllowNull()][object]$LiveModelProvider,
        [AllowNull()][string]$LiveModel,
        [ValidateSet('COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')]
        [AllowNull()][string]$LiveCredentialEnvironmentName
    )
    if ($LeaseSeconds -lt 1 -or $LeaseSeconds -gt 86400) { throw 'LeaseSeconds must be between 1 and 86400.' }
    $resolvedStateRoot = Resolve-OwnerV2StateRoot -StateRoot $StateRoot -Create
    $manifest = Read-OwnerV2Manifest -ManifestPath $ManifestPath
    $ran = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in @($manifest.Entries)) {
        if (-not $seen.Add($entry.Identity)) { continue }
        $capabilityRoot = Get-OwnerV2CapabilityRoot -StateRoot $resolvedStateRoot `
            -CapabilityId ([string]$entry.Declaration.capability.id) `
            -CapabilityDigest ([string]$entry.Declaration.capability.digest)
        $entry.CapabilityRoot = $capabilityRoot
        Initialize-OwnerV2CapabilityRoot -CapabilityRoot $capabilityRoot
        $identity = $entry.Identity
        $recordPath = Get-OwnerV2RecordPath -CapabilityRoot $capabilityRoot -Identity $identity
        $observationPath = Get-OwnerV2ObservationPath -CapabilityRoot $capabilityRoot -Identity $identity
        $telemetryPath = Get-OwnerV2TelemetryPath -CapabilityRoot $capabilityRoot -Identity $identity
        $reserved = $false
        $reservationId = $null
        $record = $null
        $lock = Enter-AgentLock -Path (Join-Path $capabilityRoot 'owner-v2-preview.lock') -AgentName 'owner-v2-orchestrator'
        try {
            if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) {
                [void]$ran.Add([ordered]@{ identity = $identity; state = 'unknown'; reason = 'not-prepared' })
                continue
            }
            $record = Read-OwnerV2JsonFile -Path $recordPath
            Assert-OwnerV2Record -Record $record
            $now = [DateTime]::UtcNow
            if ([string]$record.state -ceq 'completed' -or [string]$record.state -ceq 'unknown' -or
                ([string]$record.state -ceq 'incomplete' -and
                    [string]$record.incompleteReason -cne 'interrupted')) {
                [void]$ran.Add([ordered]@{
                        identity = $identity
                        state = [string]$record.state
                        reason = 'already-terminal'
                    })
                continue
            }
            if ([string]$record.state -ceq 'running' -and -not (Test-OwnerV2LeaseStale -Record $record -NowUtc $now)) {
                [void]$ran.Add([ordered]@{ identity = $identity; state = 'running'; reason = 'lease-active' })
                continue
            }
            if ([int]$record.attempts -ge [int]$record.maxAttempts) {
                $record.state = 'incomplete'
                $record.lease = $null
                $record.updatedUtc = 'utc:' + $now.ToString('o')
                $record.incompleteReason = 'maximum-attempts'
                [void](Write-OwnerV2AtomicJson -Path $recordPath -Value $record)
                [void](Write-OwnerV2Index -CapabilityRoot $capabilityRoot)
                [void]$ran.Add([ordered]@{ identity = $identity; state = 'incomplete'; reason = 'maximum-attempts' })
                continue
            }
            $record.state = 'running'
            $record.attempts = [int]$record.attempts + 1
            $record.updatedUtc = 'utc:' + $now.ToString('o')
            $record.incompleteReason = $null
            $record.lease = [ordered]@{
                id = [guid]::NewGuid().ToString('N')
                acquiredUtc = 'utc:' + $now.ToString('o')
                expiresUtc = 'utc:' + $now.AddSeconds($LeaseSeconds).ToString('o')
            }
            $reservationId = [string]$record.lease.id
            [void](Write-OwnerV2AtomicJson -Path $recordPath -Value $record)
            [void](Write-OwnerV2Index -CapabilityRoot $capabilityRoot)
            $reserved = $true
            Invoke-OwnerV2Checkpoint -Name 'run-after-reservation'
        }
        finally {
            Exit-AgentLock -Stream $lock
        }
        if (-not $reserved) { continue }

        $outcome = $null
        $observation = $null
        $telemetry = $null
        $finalState = 'unknown'
        $reason = $null
        try {
            $declarationPath = Get-OwnerV2DeclarationPath -CapabilityRoot $capabilityRoot -Identity $identity
            $evidencePath = Get-OwnerV2EvidencePath -CapabilityRoot $capabilityRoot -Identity $identity
            $declaration = Read-OwnerV2JsonFile -Path $declarationPath
            $evidence = Read-OwnerV2JsonFile -Path $evidencePath
            Assert-OwnerV2NoUnsafeShape -Value $declaration
            Assert-OwnerV2NoUnsafeShape -Value $evidence
            if ((Get-OwnerV2Digest -Value ($declaration | ForEach-Object {
                            $copy = [ordered]@{}
                            foreach ($key in @($_.Keys | Where-Object {
                                        $_ -cne 'stateDigest' -and $_ -cne 'facadeBinding'
                                    } | Sort-Object -CaseSensitive)) {
                                $copy[$key] = $_[$key]
                            }
                            $copy
                        })) -cne [string]$entry.StateDigest) {
                throw 'Declaration digest did not match the manifest entry.'
            }
            if ([string]$entry.Declaration.mode -ceq 'live') {
                $outcome = Invoke-OwnerV2Live -Entry $entry `
                    -EnableLiveModel ([bool]$EnableLiveModel) `
                    -AcquisitionProvider $LiveAcquisitionProvider `
                    -ModelProvider $LiveModelProvider `
                    -Model $LiveModel `
                    -CredentialEnvironmentName $LiveCredentialEnvironmentName
                $observation = $outcome.Observation
                $telemetry = $outcome.Telemetry
                $finalState = [string]$outcome.State
                $reason = [string]$outcome.Reason
            }
            else {
                if ([string]$evidence.acquisitionPayloadDigest -cne [string]$entry.Declaration.acquisitionPayloadDigest) {
                    throw 'Evidence payload digest did not match the declaration.'
                }
                $outcome = Invoke-OwnerV2Replay -Entry $entry
                $observation = $outcome.Observation
                $lifecycleStatus = [string]$observation.lifecycle.status
                $finalState = if ($lifecycleStatus -ceq 'completed') { 'completed' }
                elseif ($lifecycleStatus -ceq 'incomplete') { 'incomplete' }
                else { 'unknown' }
                $reason = [string]$observation.execution.incompleteReason
            }
        }
        catch {
            $observation = New-OwnerV2LiveUnavailableObservation -Entry $entry `
                -Reason 'orchestrator-refusal'
            $observation.lifecycle.status = 'unknown'
            $observation.execution.attempts = [int]$record.attempts
            $observation.execution.modelStarts = 'unknown'
            $observation.execution.latencyMs = 'unknown'
            $observation.execution.refusalReason = 'orchestrator-refusal'
            $observation.execution.incompleteReason = 'orchestrator-refusal'
            $observation.measurements.execution.attempts =
                New-OwnerMeasurement -Status measured -Value ([int]$record.attempts)
            $observation.measurements.execution.modelStarts =
                New-OwnerMeasurement -Status unavailable -Reason 'orchestrator-refusal'
            $observation.measurements.execution.latencyMs =
                New-OwnerMeasurement -Status unavailable -Reason 'orchestrator-refusal'
            $observation.validationErrors = @([string]$_.Exception.Message)
            $finalState = 'unknown'
            $reason = 'orchestrator-refusal'
        }

        Invoke-OwnerV2Checkpoint -Name 'run-before-publish'
        $lock = Enter-AgentLock -Path (Join-Path $capabilityRoot 'owner-v2-preview.lock') -AgentName 'owner-v2-orchestrator'
        try {
            $record = Read-OwnerV2JsonFile -Path $recordPath
            Assert-OwnerV2Record -Record $record
            if ([string]$record.state -cne 'running' -or
                $record.lease -isnot [Collections.IDictionary] -or
                [string]$record.lease.id -cne $reservationId) {
                [void]$ran.Add([ordered]@{
                        identity = $identity
                        state = [string]$record.state
                        attempts = [int]$record.attempts
                        resultDigest = $record.resultDigest
                        reason = 'reservation-lost'
                    })
                continue
            }
            if ($null -ne $telemetry) {
                [void](Write-OwnerV2AtomicJson -Path $telemetryPath -Value $telemetry)
                $telemetrySha = ([Convert]::ToHexString(
                        [Security.Cryptography.SHA256]::HashData(
                            [IO.File]::ReadAllBytes($telemetryPath)))).ToLowerInvariant()
                $observation.sourceArtifacts = @($observation.sourceArtifacts) + @(
                    [ordered]@{
                        kind = 'owner-model-runner-telemetry'
                        sha256 = $telemetrySha
                        signature = 'not-applicable'
                    }
                )
            }
            [void](Write-OwnerV2AtomicJson -Path $observationPath -Value $observation)
            $record.state = $finalState
            $record.lease = $null
            $record.updatedUtc = 'utc:' + ([DateTime]::UtcNow).ToString('o')
            $record.resultDigest = Get-OwnerV2Digest -Value $observation
            $record.incompleteReason = $reason
            [void](Write-OwnerV2AtomicJson -Path $recordPath -Value $record)
            [void](Write-OwnerV2Index -CapabilityRoot $capabilityRoot)
            [void]$ran.Add([ordered]@{
                    identity = $identity
                    state = $finalState
                    attempts = [int]$record.attempts
                    resultDigest = [string]$record.resultDigest
                    reason = $reason
                    telemetryPath = $(if ($null -ne $telemetry) { $telemetryPath } else { $null })
                })
        }
        finally {
            Exit-AgentLock -Stream $lock
        }
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        kind = 'owner-v2-preview-run-result'
        stateRoot = $resolvedStateRoot
        manifestDigest = $manifest.Digest
        records = @($ran | Sort-Object identity)
    }
}

function Get-OwnerV2PreviewStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$ManifestPath
    )
    $resolvedStateRoot = Resolve-OwnerV2StateRoot -StateRoot $StateRoot
    $manifest = Read-OwnerV2Manifest -ManifestPath $ManifestPath
    $records = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in @($manifest.Entries)) {
        if (-not $seen.Add($entry.Identity)) { continue }
        $capabilityRoot = Get-OwnerV2CapabilityRoot -StateRoot $resolvedStateRoot `
            -CapabilityId ([string]$entry.Declaration.capability.id) `
            -CapabilityDigest ([string]$entry.Declaration.capability.digest)
        $recordPath = Get-OwnerV2RecordPath -CapabilityRoot $capabilityRoot -Identity $entry.Identity
        if (Test-Path -LiteralPath $recordPath -PathType Leaf) {
            $record = Read-OwnerV2JsonFile -Path $recordPath
            Assert-OwnerV2Record -Record $record
            [void]$records.Add((Get-OwnerV2IndexRecord -Record $record))
        }
        else {
            [void]$records.Add([ordered]@{
                    identity = $entry.Identity
                    stateDigest = $entry.StateDigest
                    state = 'unknown'
                    mode = [string]$entry.Declaration.mode
                    capabilityId = [string]$entry.Declaration.capability.id
                    capabilityDigest = [string]$entry.Declaration.capability.digest
                    subjectDigest = Get-OwnerV2Digest -Value $entry.Declaration.subject
                    headDigest = Get-OwnerV2Digest -Value $entry.Declaration.head
                    ruleDigest = Get-OwnerV2Digest -Value $entry.Declaration.rule
                    modelDigest = Get-OwnerV2Digest -Value $entry.Declaration.model
                    configDigest = Get-OwnerV2Digest -Value $entry.Declaration.config
                    attempts = 0
                    maxAttempts = 0
                    updatedUtc = $null
                    incompleteReason = 'not-prepared'
                })
        }
    }
    $sortedRecords = @($records | Sort-Object identity)
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        kind = 'owner-v2-preview-status'
        stateRoot = $resolvedStateRoot
        manifestDigest = $manifest.Digest
        records = @($sortedRecords)
        index = [ordered]@{
            schemaVersion = 1
            kind = 'owner-v2-preview-index'
            records = @($sortedRecords)
        }
    }
}

Export-ModuleMember -Function @(
    'Get-OwnerV2PreviewStatus',
    'Invoke-OwnerV2PreviewPrepare',
    'Invoke-OwnerV2PreviewRun'
)
