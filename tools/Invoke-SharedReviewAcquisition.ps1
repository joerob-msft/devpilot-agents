#!/usr/bin/env pwsh
#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$StateRoot,
    [Parameter(Mandatory)][string]$AcquisitionPath,
    [string]$AzureCliPath = 'az',
    [ValidateRange(1, 4)][int]$MaximumHeadsThisRun = 4,
    [ValidateRange(1, 720)]
    [int]$MaximumSecondsThisRun = 720,
    [switch]$Run,
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $RepoRoot `
        'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
Import-Module (Join-Path $RepoRoot `
        'src\DevPilot.ActivePrIntake\DevPilot.ActivePrIntake.psd1') -Force

$config = Get-Content -LiteralPath $ConfigPath -Raw |
    ConvertFrom-Json -AsHashtable -Depth 64
$provider = New-ActivePrAzureDevOpsProvider `
    -Config $config -AzureCliPath $AzureCliPath
$intake = Invoke-ActivePrIntake `
    -Config $config -Provider $provider `
    -StateRoot $StateRoot -RepositoryRoot $RepoRoot `
    -MaximumHeadsThisRun $MaximumHeadsThisRun `
    -MaximumSecondsThisRun $MaximumSecondsThisRun `
    -IncludeTransientSnapshots -Run:$Run

$directory = Resolve-AgentTrustedRoot `
    -Path (Split-Path -Parent $AcquisitionPath) `
    -Kind durable-state -RepositoryRoot $RepoRoot -Create
$requestedPath = [IO.Path]::GetFullPath($AcquisitionPath)
if (-not (Test-AgentPathWithin `
        -Path $requestedPath -Root $directory)) {
    throw 'Shared acquisition path is outside its private root.'
}
$path = Join-Path $directory (
    '{0}-{1}{2}' -f
    [IO.Path]::GetFileNameWithoutExtension($requestedPath),
    [string]$intake.generation,
    [IO.Path]::GetExtension($requestedPath))
if (-not (Test-AgentPathWithin -Path $path -Root $directory)) {
    throw 'Shared acquisition path is outside its private root.'
}
if (Test-Path -LiteralPath $path) {
    throw 'Shared acquisition generation already exists.'
}
$snapshot = [ordered]@{
    schemaVersion = 1
    kind = 'devpilot-shared-review-acquisition'
    createdUtc = [DateTime]::UtcNow.ToString('o')
    configDigest = [string]$intake.binding.configDigest
    generation = [string]$intake.generation
    intake = $intake
}
$json = ConvertTo-Json -InputObject $snapshot -Depth 100
$bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
if ($bytes.Length -gt 67108864) {
    throw 'Shared acquisition exceeded its 64 MiB bound.'
}
$temporary = Join-Path $directory (
    '.shared-acquisition-' + [guid]::NewGuid().ToString('N'))
try {
    [IO.File]::WriteAllBytes($temporary, $bytes)
    [IO.File]::Move($temporary, $path)
}
finally {
    Remove-Item -LiteralPath $temporary `
        -Force -ErrorAction SilentlyContinue
}
[void](Assert-AgentTrustedFile `
        -Path $path -AllowedRoot $directory -Private)

$blobKeys = @($intake.transientSnapshots.GetEnumerator() |
    ForEach-Object {
        $entry = $_
        @($entry.Value.changes.entries | ForEach-Object {
                '{0}/{1}/{2}/{3}/{4}/{5}' -f
                [string]$config.projectId,
                [string]$config.repositoryId,
                [string]$entry.Value.head.pullRequestId,
                [string]$entry.Value.head.sourceCommit,
                [string]$entry.Value.head.targetCommit,
                [string]$_.path
            })
    } | Sort-Object -Unique)
[ordered]@{
    schemaVersion = 1
    kind = 'devpilot-shared-review-acquisition-result'
    state = [string]$intake.state
    generation = [string]$intake.generation
    configDigest = [string]$intake.binding.configDigest
    acquisitionPath = $path
    acquisitionSha256 = (Get-FileHash `
            -LiteralPath $path -Algorithm SHA256).
        Hash.ToLowerInvariant()
    selectedPrCount = @($intake.heads | Where-Object {
            $_.declaration -is [Collections.IDictionary] -and
            [string]$_.reasonCode -ceq 'rules-incomplete'
        }).Count
    totalUniquePrSnapshotCount =
        @($intake.transientSnapshots.Keys).Count
    uniqueContentBlobCount = $blobKeys.Count
    uniqueContentBlobKeys = $blobKeys
    providerReadCount = [int]$intake.readCount
    providerWrites = 0
    modelWrites = 0
} | ConvertTo-Json -Depth 32
