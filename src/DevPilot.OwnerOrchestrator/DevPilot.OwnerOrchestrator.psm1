#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\..\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1"
Import-Module "$PSScriptRoot\..\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1"
Import-Module "$PSScriptRoot\..\DevPilot.OwnerCapability\DevPilot.OwnerCapability.psd1"
Import-Module "$PSScriptRoot\..\OwnerObservationContract\OwnerObservationContract.psd1"
Import-Module "$PSScriptRoot\..\DevPilot.OwnerModelRunner\DevPilot.OwnerModelRunner.psd1"
Import-Module "$PSScriptRoot\..\DevPilot.OwnerPipeline\DevPilot.OwnerPipeline.psd1"
Import-Module "$PSScriptRoot\..\DevPilot.RelationEvidence\DevPilot.RelationEvidence.psd1"

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
$script:RelationV2MaximumEntries = 10
$script:OwnerV2DigestPattern = '^v1:sha256:[0-9a-f]{64}$'
$script:OwnerV2CommitPattern = '^[0-9a-f]{40}$'
$script:OwnerV2SafeIdPattern = '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$'
$script:OwnerV2UnsafeKeyPattern = '(?i)(authorize|authorization|delivery|writer|adapter|tool|secret|password|credential|scheduler|notification|vote|comment|summary|permission|deploy|accessToken|refreshToken|idToken|apiKey|privateKey)'
$script:OwnerV2UnsafeValuePattern = '(?i)(ghp_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|bearer\s+[A-Za-z0-9._-]+|authorization:|password=|secret=|token=)'
$script:OwnerV2States = @('pending', 'running', 'completed', 'incomplete', 'unknown')
$script:OwnerV2ModelExecutionStates = @('notAttempted', 'attempted')
$script:OwnerV2NonRecoverableRetryReasons = @(
    'durable-state-integrity-failure',
    'evidence-cap-exhausted',
    'model-binding-mismatch',
    'orchestrator-refusal',
    'relation-outcome-unknown',
    'rule-evidence-binding-mismatch',
    'rule-evidence-unavailable'
)
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

function Get-OwnerV2RawTextDigest {
    param([Parameter(Mandatory)][string]$Value)
    return 'v1:sha256:' + [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Value))
    ).ToLowerInvariant()
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

function Get-OwnerV2AttemptTelemetryPath {
    param(
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [Parameter(Mandatory)][string]$Identity,
        [Parameter(Mandatory)][int]$Attempt
    )
    return Join-Path (Join-Path $CapabilityRoot 'telemetry') (
        "$Identity.attempt-$($Attempt.ToString('0000')).json")
}

function Assert-OwnerV2Record {
    param([Parameter(Mandatory)][Collections.IDictionary]$Record)
    Assert-OwnerV2NoUnsafeShape -Value $Record
    $expected = @(
        'schemaVersion', 'kind', 'identity', 'stateDigest', 'mode', 'capabilityId',
        'capabilityDigest', 'subjectDigest', 'headDigest', 'ruleDigest', 'modelDigest',
        'configDigest', 'acquisitionPayloadDigest', 'state', 'attempts', 'maxAttempts',
        'lease', 'createdUtc', 'updatedUtc', 'declarationPath', 'evidencePath',
        'observationPath', 'resultDigest', 'incompleteReason'
    )
    if ([int]$Record.schemaVersion -eq 2) { $expected += 'modelExecutionState' }
    Assert-OwnerV2ExactKeys -Value $Record -Name record -Expected $expected
    if ([int]$Record.schemaVersion -notin @(1, 2) -or
        [string]$Record.kind -cne 'owner-v2-preview-record') {
        throw 'Owner v2 record has an unsupported schema or kind.'
    }
    if ([int]$Record.schemaVersion -eq 2 -and
        [string]$Record.modelExecutionState -cnotin $script:OwnerV2ModelExecutionStates) {
        throw 'Owner v2 record model execution state is invalid.'
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

function Assert-OwnerV2RecordBinding {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Record,
        [Parameter(Mandatory)][object]$Entry
    )
    $expected = [ordered]@{
        identity = [string]$Entry.Identity
        stateDigest = [string]$Entry.StateDigest
        mode = [string]$Entry.Declaration.mode
        capabilityId = [string]$Entry.Declaration.capability.id
        capabilityDigest = [string]$Entry.Declaration.capability.digest
        subjectDigest = Get-OwnerV2Digest -Value $Entry.Declaration.subject
        headDigest = Get-OwnerV2Digest -Value $Entry.Declaration.head
        ruleDigest = Get-OwnerV2Digest -Value $Entry.Declaration.rule
        modelDigest = Get-OwnerV2Digest -Value $Entry.Declaration.model
        configDigest = Get-OwnerV2Digest -Value $Entry.Declaration.config
        acquisitionPayloadDigest = [string]$Entry.Declaration.acquisitionPayloadDigest
    }
    foreach ($name in $expected.Keys) {
        if ([string]$Record[$name] -cne [string]$expected[$name]) {
            throw "Owner v2 record binding '$name' did not match the manifest entry."
        }
    }
}

function ConvertTo-OwnerV2CurrentRecord {
    param([Parameter(Mandatory)][Collections.IDictionary]$Record)
    if ([int]$Record.schemaVersion -eq 2) { return $false }
    if ([string]$Record.state -cne 'pending' -or [int]$Record.attempts -ne 0 -or
        $null -ne $Record.resultDigest -or $null -ne $Record.incompleteReason) {
        return $false
    }
    $Record.schemaVersion = 2
    $Record['modelExecutionState'] = 'notAttempted'
    return $true
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
        CapabilityKind = 'owner'
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

function Test-RelationV2PathPattern {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][Collections.IDictionary]$Pattern
    )
    $value = [string]$Pattern.value
    if ([string]$Pattern.kind -ceq 'exact') {
        return $Path -ceq $value
    }
    return $Path -ceq $value -or
        $Path.EndsWith("/$value", [StringComparison]::Ordinal)
}

function ConvertTo-RelationV2Declaration {
    param([Parameter(Mandatory)][Collections.IDictionary]$Entry)

    Assert-OwnerV2NoUnsafeShape -Value $Entry
    Assert-OwnerV2ExactKeys -Value $Entry -Name entry -Expected @(
        'id', 'subject', 'head', 'target', 'rule', 'capability', 'model', 'config'
    )
    Assert-OwnerV2SafeText -Value ([string]$Entry.id) -Name id -MaximumLength 128
    if ([string]$Entry.id -cnotmatch $script:OwnerV2SafeIdPattern) {
        throw 'Relation preview entry id must be a safe identifier.'
    }
    Assert-OwnerV2ExactKeys -Value $Entry.subject -Name subject -Expected @(
        'repositoryId', 'projectId', 'pullRequestId'
    )
    Assert-OwnerV2ExactKeys -Value $Entry.head -Name head -Expected @('sourceCommit')
    Assert-OwnerV2ExactKeys -Value $Entry.target -Name target -Expected @(
        'targetCommit', 'targetRef'
    )
    Assert-OwnerV2ExactKeys -Value $Entry.rule -Name rule -Expected @(
        'id', 'repositoryId', 'path', 'commit', 'section', 'hash', 'length'
    )
    Assert-OwnerV2ExactKeys -Value $Entry.capability -Name capability -Expected @('id', 'digest')
    Assert-OwnerV2ExactKeys -Value $Entry.model -Name model -Expected @('id', 'digest')
    Assert-OwnerV2ExactKeys -Value $Entry.config -Name config -Expected @(
        'id', 'digest', 'claimId', 'question', 'severity', 'policy', 'anchorRole', 'selectors'
    )
    foreach ($item in @(
            @{ Value = [string]$Entry.subject.repositoryId; Name = 'subject.repositoryId'; Max = 256 },
            @{ Value = [string]$Entry.subject.projectId; Name = 'subject.projectId'; Max = 256 },
            @{ Value = [string]$Entry.target.targetRef; Name = 'target.targetRef'; Max = 512 },
            @{ Value = [string]$Entry.rule.id; Name = 'rule.id'; Max = 256 },
            @{ Value = [string]$Entry.rule.repositoryId; Name = 'rule.repositoryId'; Max = 256 },
            @{ Value = [string]$Entry.rule.path; Name = 'rule.path'; Max = 512 },
            @{ Value = [string]$Entry.rule.section; Name = 'rule.section'; Max = 256 },
            @{ Value = [string]$Entry.capability.id; Name = 'capability.id'; Max = 256 },
            @{ Value = [string]$Entry.model.id; Name = 'model.id'; Max = 128 },
            @{ Value = [string]$Entry.config.id; Name = 'config.id'; Max = 256 },
            @{ Value = [string]$Entry.config.claimId; Name = 'config.claimId'; Max = 128 },
            @{ Value = [string]$Entry.config.question; Name = 'config.question'; Max = 1200 },
            @{ Value = [string]$Entry.config.policy; Name = 'config.policy'; Max = 128 },
            @{ Value = [string]$Entry.config.anchorRole; Name = 'config.anchorRole'; Max = 64 }
        )) {
        Assert-OwnerV2SafeText -Value $item.Value -Name $item.Name -MaximumLength $item.Max
    }
    if ([long]$Entry.subject.pullRequestId -lt 1) {
        throw 'subject.pullRequestId must be positive.'
    }
    Assert-OwnerV2Commit -Value ([string]$Entry.head.sourceCommit) -Name head.sourceCommit
    Assert-OwnerV2Commit -Value ([string]$Entry.target.targetCommit) -Name target.targetCommit
    Assert-OwnerV2Commit -Value ([string]$Entry.rule.commit) -Name rule.commit
    foreach ($item in @(
            @{ Value = [string]$Entry.rule.hash; Name = 'rule.hash' },
            @{ Value = [string]$Entry.capability.digest; Name = 'capability.digest' },
            @{ Value = [string]$Entry.model.digest; Name = 'model.digest' },
            @{ Value = [string]$Entry.config.digest; Name = 'config.digest' }
        )) {
        Assert-OwnerV2Digest -Value $item.Value -Name $item.Name
    }
    if ([long]$Entry.rule.length -lt 1 -or [long]$Entry.rule.length -gt 4000) {
        throw 'rule.length must be between 1 and 4000 bytes.'
    }
    if ([string]$Entry.config.severity -cnotin @(
            'critical', 'high', 'medium', 'low', 'informational'
        )) {
        throw 'config.severity is invalid.'
    }
    if ([string]$Entry.config.claimId -cnotmatch '^[a-z0-9][a-z0-9_.-]{0,127}$' -or
        [string]$Entry.config.anchorRole -cnotmatch '^[a-z][a-z0-9-]{0,63}$') {
        throw 'Relation claim and anchor role identities must use neutral safe identifiers.'
    }

    $selectors = @($Entry.config.selectors)
    if ($selectors.Count -lt 1 -or $selectors.Count -gt 16) {
        throw 'config.selectors must contain 1 to 16 bounded role selectors.'
    }
    $roles = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $hasTrigger = $false
    $anchorSelectorRequired = $false
    $normalizedSelectors = [Collections.Generic.List[object]]::new()
    foreach ($selector in $selectors) {
        if ($selector -isnot [Collections.IDictionary]) {
            throw 'Relation selectors must be dictionaries.'
        }
        Assert-OwnerV2ExactKeys -Value $selector -Name selector -Expected @(
            'role', 'required', 'trigger', 'evidenceType', 'patterns'
        )
        $role = [string]$selector.role
        if ($role -cnotmatch '^[a-z][a-z0-9-]{0,63}$' -or -not $roles.Add($role)) {
            throw 'Relation selector roles must be unique neutral identifiers.'
        }
        if ($selector.required -isnot [bool] -or $selector.trigger -isnot [bool]) {
            throw "Relation selector '$role' requires Boolean required and trigger values."
        }
        if ([bool]$selector.trigger) { $hasTrigger = $true }
        if ($role -ceq [string]$Entry.config.anchorRole -and [bool]$selector.required) {
            $anchorSelectorRequired = $true
        }
        $evidenceType = [string]$selector.evidenceType
        if ($evidenceType -cnotin @('source', 'guidance', 'test')) {
            throw "Relation selector '$role' used an unsupported evidence type."
        }
        $patterns = @($selector.patterns)
        if ($patterns.Count -lt 1 -or $patterns.Count -gt 4) {
            throw "Relation selector '$role' requires 1 to 4 path patterns."
        }
        $normalizedPatterns = [Collections.Generic.List[object]]::new()
        foreach ($pattern in $patterns) {
            if ($pattern -isnot [Collections.IDictionary]) {
                throw "Relation selector '$role' path patterns must be dictionaries."
            }
            Assert-OwnerV2ExactKeys -Value $pattern -Name pattern -Expected @('kind', 'value')
            $kind = [string]$pattern.kind
            $value = [string]$pattern.value
            if ($kind -cnotin @('exact', 'suffix') -or
                [string]::IsNullOrWhiteSpace($value) -or $value.Length -gt 512 -or
                $value -match '[\r\n*?\[\]\\]' -or $value.StartsWith('/', [StringComparison]::Ordinal) -or
                $value.Contains('..', [StringComparison]::Ordinal)) {
                throw "Relation selector '$role' used an unsafe exact or glob-suffix pattern."
            }
            [void]$normalizedPatterns.Add([ordered]@{ kind = $kind; value = $value })
        }
        [void]$normalizedSelectors.Add([ordered]@{
                role = $role
                required = [bool]$selector.required
                trigger = [bool]$selector.trigger
                evidenceType = $evidenceType
                patterns = @($normalizedPatterns)
            })
    }
    if (-not $hasTrigger -or -not $roles.Contains([string]$Entry.config.anchorRole) -or
        -not $anchorSelectorRequired) {
        throw 'Relation routing requires a trigger selector and a required anchor role selector.'
    }
    $configForDigest = [ordered]@{
        id = [string]$Entry.config.id
        claimId = [string]$Entry.config.claimId
        question = [string]$Entry.config.question
        severity = [string]$Entry.config.severity
        policy = [string]$Entry.config.policy
        anchorRole = [string]$Entry.config.anchorRole
        selectors = @($normalizedSelectors | Sort-Object { [string]$_.role })
    }
    if ((Get-OwnerV2Digest -Value $configForDigest) -cne [string]$Entry.config.digest) {
        throw 'config.digest did not match the bounded relation routing declaration.'
    }
    $normalizedConfig = [ordered]@{} + $configForDigest
    $normalizedConfig['digest'] = [string]$Entry.config.digest
    $normalizedEntry = [ordered]@{
        id = [string]$Entry.id
        mode = 'live'
        subject = ConvertTo-OwnerV2JsonValue -Value $Entry.subject
        head = ConvertTo-OwnerV2JsonValue -Value $Entry.head
        target = ConvertTo-OwnerV2JsonValue -Value $Entry.target
        rule = ConvertTo-OwnerV2JsonValue -Value $Entry.rule
        capability = ConvertTo-OwnerV2JsonValue -Value $Entry.capability
        model = ConvertTo-OwnerV2JsonValue -Value $Entry.model
        config = ConvertTo-OwnerV2JsonValue -Value $normalizedConfig
    }
    $acquisitionPayloadDigest = Get-OwnerV2Digest -Value ([ordered]@{
            subject = $normalizedEntry.subject
            head = $normalizedEntry.head
            target = $normalizedEntry.target
            rule = $normalizedEntry.rule
            selectors = $normalizedEntry.config.selectors
        })
    $contractEntry = [ordered]@{} + $normalizedEntry
    $contractEntry['acquisition'] = [ordered]@{ payloadDigest = $acquisitionPayloadDigest }
    $contract = New-OwnerV2AcquisitionContract -Entry $contractEntry
    $declarationForDigest = [ordered]@{
        schemaVersion = 1
        kind = 'relation-v2-preview-declaration'
        mode = 'live'
        subject = $normalizedEntry.subject
        head = $normalizedEntry.head
        target = $normalizedEntry.target
        rule = $normalizedEntry.rule
        capability = $normalizedEntry.capability
        model = $normalizedEntry.model
        config = $normalizedEntry.config
        acquisitionPayloadDigest = $acquisitionPayloadDigest
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
        CapabilityKind = 'relation'
        Identity = $identity
        StateDigest = $stateDigest
        Declaration = $declaration
        Evidence = [ordered]@{
            schemaVersion = 1
            kind = 'relation-v2-live-acquisition-pin'
            acquisitionPayloadDigest = $acquisitionPayloadDigest
        }
        Contract = $contract
        ReplayRecords = @()
        CapabilityRoot = $null
        ManifestEntry = ConvertTo-OwnerV2JsonValue -Value $normalizedEntry
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
    $kind = [string]$manifest.kind
    if ([int]$manifest.schemaVersion -ne 1 -or
        $kind -cnotin @('owner-v2-preview-cohort', 'relation-v2-preview-cohort')) {
        throw 'Preview manifest must use schemaVersion 1 and a supported bounded cohort kind.'
    }
    $entries = @($manifest.entries)
    $maximumEntries = if ($kind -ceq 'relation-v2-preview-cohort') {
        $script:RelationV2MaximumEntries
    }
    else {
        $script:OwnerV2MaximumEntries
    }
    if ($entries.Count -lt 1 -or $entries.Count -gt $maximumEntries) {
        throw "Preview manifest must contain 1 to $maximumEntries entries."
    }
    $declarations = @($entries | ForEach-Object {
            if ($kind -ceq 'relation-v2-preview-cohort') {
                ConvertTo-RelationV2Declaration -Entry $_
            }
            else {
                ConvertTo-OwnerV2Declaration -Entry $_
            }
        } |
        Sort-Object -Property StateDigest)
    $manifestDigest = Get-OwnerV2Digest -Value ([ordered]@{
            schemaVersion = 1
            kind = $kind
            entries = @($declarations | ForEach-Object { $_.Declaration })
        })
    return [pscustomobject][ordered]@{
        Path = $resolved
        Digest = $manifestDigest
        Kind = $kind
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
        schemaVersion = 2
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
        modelExecutionState = 'notAttempted'
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
        modelExecutionState = $(if ([int]$Record.schemaVersion -eq 2) {
                [string]$Record.modelExecutionState
            }
            else { 'unknown' })
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

function Test-OwnerV2LiveRetryEligible {
    param(
        [Parameter(Mandatory)][object]$Entry,
        [Parameter(Mandatory)][Collections.IDictionary]$Record,
        [Parameter(Mandatory)][bool]$EnableLiveModel,
        [AllowNull()][object]$AcquisitionProvider,
        [AllowNull()][object]$ModelProvider,
        [AllowNull()][string]$Model,
        [AllowNull()][string]$CredentialEnvironmentName
    )
    if ([string]$Entry.Declaration.mode -cne 'live' -or -not $EnableLiveModel) {
        return $false
    }
    if ([int]$Record.schemaVersion -ne 2 -or
        [string]$Record.modelExecutionState -cne 'notAttempted' -or
        [int]$Record.attempts -ge [int]$Record.maxAttempts -or
        $null -eq $AcquisitionProvider -or
        ($null -eq $ModelProvider -and (
            [string]::IsNullOrWhiteSpace($Model) -or
            [string]::IsNullOrWhiteSpace($CredentialEnvironmentName)
        ))) {
        return $false
    }
    return [string]$Record.incompleteReason -cnotin $script:OwnerV2NonRecoverableRetryReasons
}

function Set-OwnerV2ModelExecutionAttempted {
    param(
        [Parameter(Mandatory)][string]$CapabilityRoot,
        [Parameter(Mandatory)][string]$RecordPath,
        [Parameter(Mandatory)][string]$ReservationId
    )
    $lock = Enter-AgentLock -Path (Join-Path $CapabilityRoot 'owner-v2-preview.lock') `
        -AgentName 'owner-v2-orchestrator'
    try {
        $record = Read-OwnerV2JsonFile -Path $RecordPath
        Assert-OwnerV2Record -Record $record
        if ([int]$record.schemaVersion -ne 2 -or [string]$record.state -cne 'running' -or
            $record.lease -isnot [Collections.IDictionary] -or
            [string]$record.lease.id -cne $ReservationId) {
            throw 'Owner v2 model execution reservation was lost before launch.'
        }
        if ([string]$record.modelExecutionState -ceq 'attempted') { return }
        $record.modelExecutionState = 'attempted'
        $record.updatedUtc = 'utc:' + ([DateTime]::UtcNow).ToString('o')
        [void](Write-OwnerV2AtomicJson -Path $RecordPath -Value $record)
        [void](Write-OwnerV2Index -CapabilityRoot $CapabilityRoot)
    }
    finally {
        Exit-AgentLock -Stream $lock
    }
}

function New-OwnerV2AttemptTrackingRunner {
    param(
        [Parameter(Mandatory)][object]$Runner,
        [Parameter(Mandatory)][scriptblock]$MarkModelAttempted
    )
    $marked = $false
    $handler = {
        param($Request)
        if (-not $marked) {
            & $MarkModelAttempted
            $marked = $true
        }
        & $Runner.Handler $Request
    }.GetNewClosure()
    $telemetryProvider = { & $Runner.TelemetryProvider }.GetNewClosure()
    return New-OwnerSemanticRunner -Name ([string]$Runner.Name) -Handler $handler `
        -TelemetryProvider $telemetryProvider
}

function New-RelationV2UnavailableObservation {
    param(
        [Parameter(Mandatory)][object]$Entry,
        [Parameter(Mandatory)][string]$Reason,
        [ValidateSet('incomplete', 'unknown')][string]$Status = 'incomplete'
    )
    return [ordered]@{
        schemaVersion = 1
        kind = 'relation-evidence-observation'
        implementation = [ordered]@{ id = 'relation-v2-preview-orchestrator'; version = '0.1' }
        capability = ConvertTo-OwnerV2JsonValue -Value $Entry.Declaration.capability
        subject = [ordered]@{
            repositoryId = [string]$Entry.Declaration.subject.repositoryId
            projectId = [string]$Entry.Declaration.subject.projectId
            pullRequestId = [long]$Entry.Declaration.subject.pullRequestId
            sourceCommit = [string]$Entry.Declaration.head.sourceCommit
            targetCommit = [string]$Entry.Declaration.target.targetCommit
            targetRef = [string]$Entry.Declaration.target.targetRef
        }
        rule = [ordered]@{
            id = [string]$Entry.Declaration.rule.id
            digest = [string]$Entry.Declaration.rule.hash
        }
        lifecycle = [ordered]@{
            status = $Status
            completed = $false
            incomplete = $Status -ceq 'incomplete'
            unknown = $Status -ceq 'unknown'
        }
        counts = [ordered]@{
            claims = 1
            violations = 0
            compliant = 0
            unknown = 1
            notApplicable = 0
        }
        findingsComplete = $false
        findings = @()
        outcomes = @(
            [ordered]@{
                assessmentId = 'relation:unavailable'
                state = 'unknown'
                data = [ordered]@{ state = 'unknown'; reason = $Reason }
                writerEligible = $false
            }
        )
        execution = [ordered]@{
            attempts = 0
            modelStarts = 0
            modelCalls = 0
            latencyMs = 0
            refusalReason = $Reason
            cost = [ordered]@{ status = 'unavailable'; reason = 'provider-cost-unavailable' }
            records = @()
        }
        effects = [ordered]@{
            providerWrites = 0
            writeToolInvocations = 0
            effectiveTools = @()
            deliveryAuthorized = $false
        }
        budgets = [ordered]@{
            maximumEvidenceBytes = 10000
            maximumModelInputBytes = 9000
        }
        evidenceDigest = $null
        requestDigest = $null
        sourceArtifacts = @()
        limitations = @('static-source-assessment', 'runtime-behavior-unverified')
        validationErrors = @()
    }
}

function New-RelationV2LiveOutcome {
    param(
        [Parameter(Mandatory)][object]$Entry,
        [Parameter(Mandatory)][string]$Reason,
        [ValidateSet('incomplete', 'unknown')][string]$State = 'incomplete',
        [AllowNull()][object]$Telemetry
    )
    return [pscustomobject]@{
        Observation = New-RelationV2UnavailableObservation -Entry $Entry -Reason $Reason `
            -Status $State
        Telemetry = $Telemetry
        State = $State
        Reason = $Reason
    }
}

function Get-RelationV2AcquisitionSnapshot {
    param(
        [Parameter(Mandatory)][object]$Entry,
        [Parameter(Mandatory)][object]$Provider
    )
    $adapter = New-OwnerProductionAcquisitionAdapter -Contract $Entry.Contract `
        -Provider $Provider -Name 'relation-v2-production-acquisition'
    $values = @(& $adapter.Handler ([pscustomobject][ordered]@{
                schemaVersion = 1
                binding = $Entry.Contract.Binding
            }))
    if ($values.Count -ne 1 -or $values[0] -isnot [Collections.IDictionary]) {
        throw 'Relation acquisition did not return one bounded provider snapshot.'
    }
    return ConvertTo-OwnerV2JsonValue -Value $values[0]
}

function New-RelationV2RequestFromSnapshot {
    param(
        [Parameter(Mandatory)][object]$Entry,
        [Parameter(Mandatory)][Collections.IDictionary]$Snapshot
    )
    $ruleUnits = @($Snapshot.evidenceUnits | Where-Object {
            [string]$_.unitId -ceq 'rule'
        })
    if ($ruleUnits.Count -ne 1 -or [string]$ruleUnits[0].state -cne 'complete' -or
        $ruleUnits[0].data.content -isnot [string]) {
        return [pscustomobject]@{ Request = $null; Reason = 'rule-evidence-unavailable' }
    }
    $ruleText = [string]$ruleUnits[0].data.content
    if ([Text.Encoding]::UTF8.GetByteCount($ruleText) -ne [long]$Entry.Declaration.rule.length -or
        (Get-OwnerV2RawTextDigest -Value $ruleText) -cne [string]$Entry.Declaration.rule.hash) {
        return [pscustomobject]@{ Request = $null; Reason = 'rule-evidence-binding-mismatch' }
    }
    $fileUnits = @($Snapshot.evidenceUnits | Where-Object {
            ([string]$_.unitId).StartsWith('file:', [StringComparison]::Ordinal)
        })
    $selectedByRole = [Collections.Generic.Dictionary[string,object]]::new(
        [StringComparer]::Ordinal)
    $selectorResults = [Collections.Generic.List[object]]::new()
    $missingRequired = $false
    $routingUnknown = $false
    $triggerMatched = $false
    foreach ($selector in @($Entry.Declaration.config.selectors)) {
        $matchingUnits = [Collections.Generic.List[object]]::new()
        foreach ($unit in $fileUnits) {
            $path = [string]$unit.data.path
            $matched = $false
            foreach ($pattern in @($selector.patterns)) {
                if (Test-RelationV2PathPattern -Path $path -Pattern $pattern) {
                    $matched = $true
                    break
                }
            }
            if ($matched) { [void]$matchingUnits.Add($unit) }
        }
        $role = [string]$selector.role
        $selected = if ($matchingUnits.Count -eq 1) { $matchingUnits[0] } else { $null }
        if ($matchingUnits.Count -gt 1) { $routingUnknown = $true }
        if ($null -eq $selected -and [bool]$selector.required) { $missingRequired = $true }
        if ($null -ne $selected -and [bool]$selector.trigger) { $triggerMatched = $true }
        if ($null -ne $selected) { $selectedByRole[$role] = $selected }
        [void]$selectorResults.Add([ordered]@{
                selector = $selector
                selected = $selected
            })
    }
    $groups = [Collections.Generic.SortedDictionary[string,object]]::new(
        [StringComparer]::Ordinal)
    $roleRefs = [Collections.Generic.Dictionary[string,string]]::new(
        [StringComparer]::Ordinal)
    foreach ($result in $selectorResults) {
        $selected = $result.selected
        if ($null -eq $selected) { continue }
        $selector = $result.selector
        $role = [string]$selector.role
        $key = [string]$selected.unitId + [char]0 + [string]$selector.evidenceType
        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = [ordered]@{
                selected = $selected
                type = [string]$selector.evidenceType
                ref = "evidence:$role"
                roles = [Collections.Generic.List[string]]::new()
            }
        }
        [void]$groups[$key].roles.Add($role)
        $roleRefs[$role] = [string]$groups[$key].ref
    }
    $slots = [Collections.Generic.List[object]]::new()
    foreach ($result in $selectorResults) {
        $selector = $result.selector
        $role = [string]$selector.role
        [void]$slots.Add([ordered]@{
                role = $role
                evidenceRef = $(if ($roleRefs.ContainsKey($role)) { $roleRefs[$role] } else { $null })
                required = [bool]$selector.required
            })
    }
    $evidenceRefs = [Collections.Generic.List[object]]::new()
    foreach ($group in $groups.Values) {
        $selected = $group.selected
        $content = $selected.data.content
        $complete = [string]$selected.state -ceq 'complete' -and $content -is [string]
        $spans = @($selected.data.spans)
        $startLine = if ($spans.Count) {
            [int](($spans | ForEach-Object { [int]$_.startLine } |
                    Measure-Object -Minimum).Minimum)
        }
        else { 1 }
        $endLine = if ($spans.Count) {
            [int](($spans | ForEach-Object { [int]$_.endLine } |
                    Measure-Object -Maximum).Maximum)
        }
        elseif ($complete) {
            [Math]::Max(1, ([regex]::Matches([string]$content, "`n").Count + 1))
        }
        else { 1 }
        [void]$evidenceRefs.Add([ordered]@{
                ref = [string]$group.ref
                type = [string]$group.type
                path = [string]$selected.data.path
                span = [ordered]@{ startLine = $startLine; endLine = $endLine }
                digest = $(if ($complete) {
                        Get-OwnerV2Digest -Value ([string]$content)
                    }
                    else {
                        [string]$selected.data.sourceDigest
                    })
                provenance = [ordered]@{
                    repositoryId = [string]$Entry.Declaration.subject.repositoryId
                    commit = [string]$Entry.Declaration.head.sourceCommit
                    sourceKind = 'repository'
                }
                roleLabels = @($group.roles | Sort-Object -CaseSensitive)
                state = $(if ($complete) { 'complete' } else { 'unknown' })
                content = $(if ($complete) { [string]$content } else { $null })
            })
    }
    $evidenceBytes = [long]((
            @($evidenceRefs | Where-Object state -CEQ 'complete' | ForEach-Object {
                    [Text.Encoding]::UTF8.GetByteCount([string]$_.content)
                }) | Measure-Object -Sum
        ).Sum)
    if ($evidenceBytes -gt 10000) {
        foreach ($evidence in $evidenceRefs) {
            $evidence.state = 'unknown'
            $evidence.content = $null
        }
        $missingRequired = $true
    }
    $applicability = if ($missingRequired -or $routingUnknown) {
        'unknown'
    }
    elseif (-not $triggerMatched) {
        'not-applicable'
    }
    else {
        'applicable'
    }
    $anchorRole = [string]$Entry.Declaration.config.anchorRole
    $anchorUnit = if ($selectedByRole.ContainsKey($anchorRole)) {
        $selectedByRole[$anchorRole]
    }
    elseif ($fileUnits.Count) {
        $fileUnits[0]
    }
    else {
        $null
    }
    $anchorSpans = @($(if ($null -ne $anchorUnit) { $anchorUnit.data.spans }))
    $anchorPath = if ($null -ne $anchorUnit) {
        [string]$anchorUnit.data.path
    }
    else {
        [string]$Entry.Declaration.rule.path
    }
    $anchorStart = if ($anchorSpans.Count) {
        [int](($anchorSpans | ForEach-Object { [int]$_.startLine } |
                Measure-Object -Minimum).Minimum)
    }
    else { 1 }
    $anchorEnd = if ($anchorSpans.Count) {
        [int](($anchorSpans | ForEach-Object { [int]$_.endLine } |
                Measure-Object -Maximum).Maximum)
    }
    else { $anchorStart }
    $limits = New-RelationEvidenceLimits -MaximumEvidenceRefs 16 `
        -MaximumEvidenceBytes 10000 -MaximumModelInputBytes 9000
    $request = New-RelationEvidenceRequest `
        -RepositoryId ([string]$Entry.Declaration.subject.repositoryId) `
        -ProjectId ([string]$Entry.Declaration.subject.projectId) `
        -PullRequestId ([long]$Entry.Declaration.subject.pullRequestId) `
        -SourceCommit ([string]$Entry.Declaration.head.sourceCommit) `
        -TargetCommit ([string]$Entry.Declaration.target.targetCommit) `
        -TargetRef ([string]$Entry.Declaration.target.targetRef) `
        -CapabilityId ([string]$Entry.Declaration.capability.id) `
        -CapabilityDigest ([string]$Entry.Declaration.capability.digest) `
        -RuleId ([string]$Entry.Declaration.rule.id) `
        -RuleDigest (Get-OwnerV2Digest -Value $ruleText) `
        -RuleText $ruleText `
        -EvidenceRefs @($evidenceRefs) `
        -Claims @(
            [ordered]@{
                claimId = [string]$Entry.Declaration.config.claimId
                question = [string]$Entry.Declaration.config.question
                applicability = $applicability
                slots = @($slots)
                anchorCandidateIds = @('selected-anchor')
                severity = [string]$Entry.Declaration.config.severity
                policy = [string]$Entry.Declaration.config.policy
            }
        ) `
        -AnchorCandidates @(
            [ordered]@{
                anchorId = 'selected-anchor'
                path = $anchorPath
                startLine = $anchorStart
                endLine = $anchorEnd
                symbol = "role:$anchorRole"
            }
        ) `
        -Limits $limits
    return [pscustomobject]@{
        Request = $request
        Reason = $(if ($evidenceBytes -gt 10000) { 'evidence-cap-exhausted' } else { $null })
    }
}

function Invoke-RelationV2Live {
    param(
        [Parameter(Mandatory)][object]$Entry,
        [Parameter(Mandatory)][bool]$EnableLiveModel,
        [AllowNull()][object]$AcquisitionProvider,
        [AllowNull()][object]$ModelProvider,
        [AllowNull()][string]$Model,
        [AllowNull()][string]$CredentialEnvironmentName,
        [Parameter(Mandatory)][scriptblock]$MarkModelAttempted
    )
    if (-not $EnableLiveModel) {
        return New-RelationV2LiveOutcome -Entry $Entry -Reason 'live-model-disabled'
    }
    if ($null -eq $AcquisitionProvider) {
        return New-RelationV2LiveOutcome -Entry $Entry -Reason 'acquisition-provider-unavailable'
    }
    $provider = $ModelProvider
    if ($null -eq $provider) {
        if ([string]::IsNullOrWhiteSpace($Model) -or
            [string]::IsNullOrWhiteSpace($CredentialEnvironmentName)) {
            return New-RelationV2LiveOutcome -Entry $Entry `
                -Reason 'live-model-configuration-missing'
        }
        $provider = New-OwnerCopilotCliModelProvider -Model $Model `
            -CredentialEnvironmentName $CredentialEnvironmentName
    }
    $preflight = Test-OwnerModelProviderPreflight -Provider $provider
    if ([string]$preflight.modelIdentity -cne [string]$Entry.Declaration.model.id) {
        return New-RelationV2LiveOutcome -Entry $Entry -Reason 'model-binding-mismatch' `
            -Telemetry (New-OwnerV2PreflightTelemetry -Preflight $preflight `
                -Reason 'model-binding-mismatch')
    }
    if (-not [bool]$preflight.available) {
        $reason = [string]$preflight.reason
        return New-RelationV2LiveOutcome -Entry $Entry -Reason $reason `
            -Telemetry (New-OwnerV2PreflightTelemetry -Preflight $preflight -Reason $reason)
    }

    $snapshot = Get-RelationV2AcquisitionSnapshot -Entry $Entry -Provider $AcquisitionProvider
    $built = New-RelationV2RequestFromSnapshot -Entry $Entry -Snapshot $snapshot
    if ($null -eq $built.Request) {
        $unavailable = New-RelationV2LiveOutcome -Entry $Entry -Reason ([string]$built.Reason) `
            -State unknown -Telemetry (New-OwnerV2PreflightTelemetry -Preflight $preflight `
                -Reason ([string]$built.Reason))
        $unavailable | Add-Member -NotePropertyName Acquisition -NotePropertyValue $snapshot
        $unavailable | Add-Member -NotePropertyName Request -NotePropertyValue $null
        return $unavailable
    }
    $runner = New-RelationEvidenceModelProcessRunner -Provider $provider `
        -Limits (New-OwnerModelRunnerLimits -MaximumAttemptsPerUnit 1) -EnableRealLaunch
    $runner = New-OwnerV2AttemptTrackingRunner -Runner $runner `
        -MarkModelAttempted $MarkModelAttempted
    $request = $built.Request
    $result = Invoke-OwnerReviewPipeline -Binding $request.Binding `
        -AcquisitionAdapter (New-RelationEvidenceAcquisitionAdapter -Request $request) `
        -CapabilityAdapter (New-RelationEvidenceCapabilityAdapter -Runner $runner -Limits $request.Limits)
    $observation = ConvertTo-RelationEvidenceObservation -PipelineResult $result -Runner $runner `
        -ImplementationId 'relation-v2-preview-orchestrator' -ImplementationVersion '0.1'
    $observation['requestDigest'] = [string]$request.RequestDigest
    $observation.rule['modelDigest'] = [string]$observation.rule.digest
    $observation.rule.digest = [string]$Entry.Declaration.rule.hash
    Assert-OwnerV2PipelineNoWrites -PipelineResult $result -Observation $observation
    $telemetry = New-OwnerV2PersistedTelemetry `
        -Telemetry (Get-OwnerModelRunnerTelemetry -Runner $runner) -Preflight $preflight
    $unknown = @($observation.outcomes | Where-Object state -CEQ 'unknown').Count -gt 0
    return [pscustomobject]@{
        Observation = $observation
        Telemetry = $telemetry
        State = $(if ($unknown) { 'unknown' } else { 'completed' })
        Reason = $(if ($unknown) {
                if ($built.Reason) { [string]$built.Reason } else { 'relation-outcome-unknown' }
            }
            else { $null })
        Acquisition = $snapshot
        Request = $request.Request
    }
}

function Invoke-OwnerV2Live {
    param(
        [Parameter(Mandatory)][object]$Entry,
        [Parameter(Mandatory)][bool]$EnableLiveModel,
        [AllowNull()][object]$AcquisitionProvider,
        [AllowNull()][object]$ModelProvider,
        [AllowNull()][string]$Model,
        [AllowNull()][string]$CredentialEnvironmentName,
        [Parameter(Mandatory)][scriptblock]$MarkModelAttempted
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
        return New-OwnerV2LiveOutcome -Entry $Entry -Reason 'model-binding-mismatch' `
            -Telemetry (New-OwnerV2PreflightTelemetry -Preflight $preflight `
                -Reason 'model-binding-mismatch')
    }
    if (-not [bool]$preflight.available) {
        $reason = [string]$preflight.reason
        return New-OwnerV2LiveOutcome -Entry $Entry -Reason $reason `
            -Telemetry (New-OwnerV2PreflightTelemetry -Preflight $preflight -Reason $reason)
    }

    $runner = New-OwnerModelProcessRunner -Provider $provider `
        -Limits (New-OwnerModelRunnerLimits -MaximumAttemptsPerUnit 1) `
        -EnableRealLaunch
    $runner = New-OwnerV2AttemptTrackingRunner -Runner $runner `
        -MarkModelAttempted $MarkModelAttempted
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
            Assert-OwnerV2RecordBinding -Record $record -Entry $entry
            if (ConvertTo-OwnerV2CurrentRecord -Record $record) {
                [void](Write-OwnerV2AtomicJson -Path $recordPath -Value $record)
                [void](Write-OwnerV2Index -CapabilityRoot $capabilityRoot)
            }
            $now = [DateTime]::UtcNow
            $retryEligible = Test-OwnerV2LiveRetryEligible -Entry $entry -Record $record `
                -EnableLiveModel ([bool]$EnableLiveModel) `
                -AcquisitionProvider $LiveAcquisitionProvider `
                -ModelProvider $LiveModelProvider `
                -Model $LiveModel `
                -CredentialEnvironmentName $LiveCredentialEnvironmentName
            if ([string]$record.state -ceq 'completed' -or
                ([string]$record.state -cin @('incomplete', 'unknown') -and -not $retryEligible)) {
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
            if ([string]$record.state -ceq 'running' -and
                (Test-OwnerV2LeaseStale -Record $record -NowUtc $now) -and (
                    [int]$record.schemaVersion -ne 2 -or
                    [string]$record.modelExecutionState -ceq 'attempted'
                )) {
                $record.state = 'incomplete'
                $record.lease = $null
                $record.updatedUtc = 'utc:' + $now.ToString('o')
                $record.incompleteReason = $(if ([int]$record.schemaVersion -eq 2) {
                        'interrupted-after-model-attempt'
                    }
                    else { 'legacy-model-execution-unknown' })
                [void](Write-OwnerV2AtomicJson -Path $recordPath -Value $record)
                [void](Write-OwnerV2Index -CapabilityRoot $capabilityRoot)
                [void]$ran.Add([ordered]@{
                        identity = $identity
                        state = 'incomplete'
                        attempts = [int]$record.attempts
                        reason = [string]$record.incompleteReason
                    })
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
        $relationAcquisition = $null
        $relationRequest = $null
        $finalState = 'unknown'
        $reason = $null
        $executionTracker = @{ State = $(if ([int]$record.schemaVersion -eq 2) {
                    [string]$record.modelExecutionState
                }
                else { 'unknown' }) }
        $setModelExecutionAttemptedCommand = ${function:Set-OwnerV2ModelExecutionAttempted}
        $markModelAttempted = {
            & $setModelExecutionAttemptedCommand -CapabilityRoot $capabilityRoot `
                -RecordPath $recordPath -ReservationId $reservationId
            $executionTracker.State = 'attempted'
        }.GetNewClosure()
        try {
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
                if ([string]$entry.Declaration.mode -cne 'live' -and
                    [string]$evidence.acquisitionPayloadDigest -cne
                    [string]$entry.Declaration.acquisitionPayloadDigest) {
                    throw 'Evidence payload digest did not match the declaration.'
                }
            }
            catch {
                throw "[owner-v2-durable-integrity] $([string]$_.Exception.Message)"
            }
            if ([string]$entry.Declaration.mode -ceq 'live') {
                $outcome = if ([string]$entry.CapabilityKind -ceq 'relation') {
                    Invoke-RelationV2Live -Entry $entry `
                        -EnableLiveModel ([bool]$EnableLiveModel) `
                        -AcquisitionProvider $LiveAcquisitionProvider `
                        -ModelProvider $LiveModelProvider `
                        -Model $LiveModel `
                        -CredentialEnvironmentName $LiveCredentialEnvironmentName `
                        -MarkModelAttempted $markModelAttempted
                }
                else {
                    Invoke-OwnerV2Live -Entry $entry `
                        -EnableLiveModel ([bool]$EnableLiveModel) `
                        -AcquisitionProvider $LiveAcquisitionProvider `
                        -ModelProvider $LiveModelProvider `
                        -Model $LiveModel `
                        -CredentialEnvironmentName $LiveCredentialEnvironmentName `
                        -MarkModelAttempted $markModelAttempted
                }
                $observation = $outcome.Observation
                $telemetry = $outcome.Telemetry
                $acquisitionProperty = $outcome.PSObject.Properties['Acquisition']
                $requestProperty = $outcome.PSObject.Properties['Request']
                $relationAcquisition = if ($null -ne $acquisitionProperty) {
                    $acquisitionProperty.Value
                }
                $relationRequest = if ($null -ne $requestProperty) { $requestProperty.Value }
                $finalState = [string]$outcome.State
                $reason = [string]$outcome.Reason
            }
            else {
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
            $reason = if (([string]$_.Exception.Message).StartsWith(
                    '[owner-v2-durable-integrity]', [StringComparison]::Ordinal)) {
                'durable-state-integrity-failure'
            }
            elseif ([string]$executionTracker.State -ceq 'notAttempted') {
                'pre-model-execution-failure'
            }
            else { 'orchestrator-refusal' }
            if ([string]$entry.CapabilityKind -ceq 'relation') {
                $observation = New-RelationV2UnavailableObservation -Entry $entry `
                    -Reason $reason -Status unknown
                $observation.execution.attempts = [int]$record.attempts
                $observation['validationErrors'] = @([string]$_.Exception.Message)
            }
            else {
                $observation = New-OwnerV2LiveUnavailableObservation -Entry $entry `
                    -Reason $reason
                $observation.lifecycle.status = 'unknown'
                $observation.lifecycle.completed = 'unknown'
                $observation.lifecycle.incomplete = 'unknown'
                $observation.lifecycle.pending = 'unknown'
                $observation.execution.attempts = [int]$record.attempts
                $observation.execution.modelStarts = 'unknown'
                $observation.execution.latencyMs = 'unknown'
                $observation.execution.refusalReason = $reason
                $observation.execution.incompleteReason = $reason
                $observation.measurements.execution.attempts =
                    New-OwnerMeasurement -Status measured -Value ([int]$record.attempts)
                $observation.measurements.execution.modelStarts =
                    New-OwnerMeasurement -Status unavailable -Reason $reason
                $observation.measurements.execution.latencyMs =
                    New-OwnerMeasurement -Status unavailable -Reason $reason
                $observation.validationErrors = @([string]$_.Exception.Message)
            }
            $finalState = 'unknown'
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
            if ($null -ne $relationAcquisition) {
                    $acquisitionPath = Join-Path (Join-Path $capabilityRoot 'evidence') `
                        "$identity.acquisition.json"
                    [void](Write-OwnerV2AtomicJson -Path $acquisitionPath `
                        -Value $relationAcquisition -Immutable)
                    $acquisitionSha = ([Convert]::ToHexString(
                            [Security.Cryptography.SHA256]::HashData(
                                [IO.File]::ReadAllBytes($acquisitionPath)))).ToLowerInvariant()
                    $observation.sourceArtifacts = @($observation.sourceArtifacts) + @(
                        [ordered]@{
                            kind = 'relation-live-acquisition'
                            sha256 = $acquisitionSha
                            signature = 'not-applicable'
                        }
                    )
            }
            if ($null -ne $relationRequest) {
                    $requestPath = Join-Path (Join-Path $capabilityRoot 'evidence') `
                        "$identity.request.json"
                    [void](Write-OwnerV2AtomicJson -Path $requestPath -Value $relationRequest -Immutable)
                    $requestSha = ([Convert]::ToHexString(
                            [Security.Cryptography.SHA256]::HashData(
                                [IO.File]::ReadAllBytes($requestPath)))).ToLowerInvariant()
                    $observation.sourceArtifacts = @($observation.sourceArtifacts) + @(
                        [ordered]@{
                            kind = 'relation-model-request'
                            sha256 = $requestSha
                            signature = 'not-applicable'
                        }
                    )
            }
            if ($null -ne $telemetry) {
                $attemptTelemetryPath = Get-OwnerV2AttemptTelemetryPath `
                    -CapabilityRoot $capabilityRoot -Identity $identity `
                    -Attempt ([int]$record.attempts)
                [void](Write-OwnerV2AtomicJson -Path $attemptTelemetryPath `
                    -Value $telemetry -Immutable)
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
                    modelExecutionState = 'unknown'
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
