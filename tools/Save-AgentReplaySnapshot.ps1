#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Writes a versioned replay-snapshot manifest over already-recorded MCP
    responses so a reviewer cycle can be re-run offline.

.DESCRIPTION
    This tool NEVER talks to a repository host. It takes payload files an
    operator has already captured - each the exact JSON-RPC response line a
    read returned - and seals them into the manifest New-AgentReplaySnapshot
    reads: exact request keys, per-payload hashes, and a canonical digest over
    the whole manifest.

    Separating capture from sealing is deliberate. Capture is host-specific and
    credentialed; sealing is pure and can therefore be tested, reviewed and run
    anywhere, including on the synthetic fixture this repository ships.

    The -Recipe file is a JSON array of records:

        [
          {
            "tool": "repo_pull_request",
            "arguments": { "action": "get", "project": "P", "pullRequestId": 1 },
            "payloadFile": "payloads/pr-get.json"
          }
        ]

    Every payloadFile is a path relative to -SnapshotPath and must already
    exist. Recording a write tool, or any action outside the replay read set,
    is refused here as well as at load.

.EXAMPLE
    ./tools/Save-AgentReplaySnapshot.ps1 `
        -SnapshotPath ./src/Agents/reviewer/testdata/replay-v1/synthetic-pr `
        -Recipe ./src/Agents/reviewer/testdata/replay-v1/synthetic-pr/recipe.json `
        -Organization contoso -Project widgets -RepositoryId 11111111-2222-3333-4444-555555555555 `
        -PullRequestId 7 -SourceCommit aaaa... -TargetCommit bbbb...
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SnapshotPath,
    [Parameter(Mandatory)][string]$Recipe,
    [Parameter(Mandatory)][string]$Organization,
    [Parameter(Mandatory)][string]$Project,
    [Parameter(Mandatory)][string]$RepositoryId,
    [Parameter(Mandatory)][int]$PullRequestId,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$SourceCommit,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$TargetCommit,
    [string]$Provider = "ado",
    [ValidatePattern('^\d{8}T\d{6}Z$')][string]$CapturedUtc,
    [string]$ConfigSha256 = ("0" * 64),
    [string]$ScriptSha256 = ("0" * 64),
    [string]$PromptSha256 = ("0" * 64),
    [string[]]$Models = @(),
    [string]$ChangeSetPayloadFile,
    [string]$SourceTransportArtifactFile,
    [ValidateRange(0, [int]::MaxValue)][int]$IterationId = 0,
    [ValidatePattern('^$|^[0-9a-fA-F]{40}$')][string]$CommonCommit = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot "..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1") -Force

$utf8 = [System.Text.UTF8Encoding]::new($false, $true)
function Get-Sha256Hex {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

$snapshotFull = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $SnapshotPath).Path)
$snapshotName = Split-Path $snapshotFull -Leaf
$records = @(Get-Content -LiteralPath $Recipe -Raw | ConvertFrom-Json)
if ($records.Count -lt 1) { throw "Recipe '$Recipe' declares no resources." }

$resources = [System.Collections.Generic.List[object]]::new()
$digestResources = [System.Collections.Generic.List[object]]::new()
$seen = @{}
foreach ($record in $records) {
    $tool = [string]$record.tool
    $arguments = $record.arguments
    $permitted = Test-AgentReplayToolPermitted -Name $tool -Arguments $arguments
    if (-not $permitted.Permitted) {
        throw "Recipe records $($permitted.Reason); a replay snapshot may only carry reads."
    }
    $relative = [string]$record.payloadFile
    $payloadPath = Join-Path $snapshotFull ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $payloadPath -PathType Leaf)) {
        throw "Recipe references payload '$relative', which does not exist under '$snapshotFull'."
    }
    $bytes = [System.IO.File]::ReadAllBytes($payloadPath)
    $key = Get-AgentReplayRequestKey -Name $tool -Arguments $arguments
    if ($seen.ContainsKey($key.Key)) { throw "Recipe records the same '$tool' request twice." }
    $seen[$key.Key] = $true

    $entry = [ordered]@{
        tool              = $tool
        arguments         = $arguments
        requestSha256     = $key.Key
        payloadFile       = $relative
        payloadSha256     = (Get-Sha256Hex -Bytes $bytes)
        payloadByteLength = [long]$bytes.Length
    }
    [void]$resources.Add($entry)
    # Digest field order is irrelevant (the canonical form sorts keys), but the
    # SET of fields is not: it must be exactly what the loader recomputes.
    [void]$digestResources.Add([ordered]@{
            tool              = $tool
            requestSha256     = $key.Key
            payloadFile       = $relative
            payloadSha256     = $entry.payloadSha256
            payloadByteLength = $entry.payloadByteLength
            arguments         = $arguments
        })
}

$changeSetSha = "0" * 64
if ($ChangeSetPayloadFile) {
    $changeSetPath = Join-Path $snapshotFull ($ChangeSetPayloadFile -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    $changeSetSha = Get-Sha256Hex -Bytes ([System.IO.File]::ReadAllBytes($changeSetPath))
}

$captured = if ($CapturedUtc) { $CapturedUtc } else { [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ") }
$binding = [ordered]@{
    organization    = $Organization
    project         = $Project
    repositoryId    = $RepositoryId
    pullRequestId   = $PullRequestId
    sourceCommit    = $SourceCommit
    targetCommit    = $TargetCommit
    changeSetSha256 = $changeSetSha
}
$bindings = [ordered]@{
    configSha256 = $ConfigSha256.ToLowerInvariant()
    scriptSha256 = $ScriptSha256.ToLowerInvariant()
    promptSha256 = $PromptSha256.ToLowerInvariant()
    models       = @($Models)
}
$schemaVersion = 1
$sourceTransport = $null
if ($SourceTransportArtifactFile) {
    if ($IterationId -lt 1 -or -not $CommonCommit) {
        throw "Schema-v2 source replay requires authoritative -IterationId and -CommonCommit."
    }
    $CommonCommit = $CommonCommit.ToLowerInvariant()
    $sourcePath = Join-Path $snapshotFull ($SourceTransportArtifactFile -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Source-transport artifact '$SourceTransportArtifactFile' does not exist under '$snapshotFull'."
    }
    $sourceBytes = [IO.File]::ReadAllBytes($sourcePath)
    if ($sourceBytes.Length -lt 2 -or $sourceBytes.Length -gt 16777216) {
        throw "Source-transport artifact is $($sourceBytes.Length) bytes; expected 2..16777216."
    }
    $sourceText = $utf8.GetString($sourceBytes)
    try { $sourceArtifact = $sourceText | ConvertFrom-Json -AsHashtable -Depth 64 -ErrorAction Stop }
    catch { throw "Source-transport artifact is not valid strict UTF-8 JSON." }
    if ((ConvertTo-AgentReplayCanonicalJson -Value $sourceArtifact) -cne $sourceText) {
        throw "Source-transport artifact is not canonical JSON."
    }
    if ([int]$sourceArtifact.schemaVersion -ne 1 -or
        [string]$sourceArtifact.kind -cne "reviewer-source-transport-replay" -or
        @("mcpFlat", "azureDevOpsCliFallback", "legacyMcp") -cnotcontains [string]$sourceArtifact.mode) {
        throw "Source-transport artifact kind, version, or mode is unsupported."
    }
    $sourceBinding = $sourceArtifact.binding
    if ([string]$sourceBinding.organization -cne $Organization -or
        [string]$sourceBinding.project -cne $Project -or
        [string]$sourceBinding.repositoryId -cne $RepositoryId.ToLowerInvariant() -or
        [int]$sourceBinding.pullRequestId -ne $PullRequestId -or
        [int]$sourceBinding.iterationId -ne $IterationId -or
        [string]$sourceBinding.commonCommit -cne $CommonCommit -or
        [string]$sourceBinding.sourceCommit -cne $SourceCommit -or
        [string]$sourceBinding.targetCommit -cne $TargetCommit -or
        [string]$sourceBinding.changeSetSha256 -cne $changeSetSha) {
        throw "Source-transport artifact binding does not match the snapshot being sealed."
    }
    $schemaVersion = 2
    $binding["iterationId"] = $IterationId
    $binding["commonCommit"] = $CommonCommit
    $sourceTransport = [ordered]@{
        mode = [string]$sourceArtifact.mode
        artifactFile = $SourceTransportArtifactFile
        artifactSha256 = Get-Sha256Hex -Bytes $sourceBytes
        artifactByteLength = [long]$sourceBytes.Length
    }
}
$digestInput = [ordered]@{
    schemaVersion = $schemaVersion
    kind          = "agent-replay-snapshot"
    snapshotId    = $snapshotName
    capturedUtc   = $captured
    provider      = $Provider
    binding       = $binding
    bindings      = $bindings
    resources     = @($digestResources.ToArray())
}
if ($schemaVersion -eq 2) { $digestInput["sourceTransport"] = $sourceTransport }
$digest = Get-Sha256Hex -Bytes ($utf8.GetBytes((ConvertTo-AgentReplayCanonicalJson -Value $digestInput)))

$manifest = [ordered]@{
    schemaVersion  = $schemaVersion
    kind           = "agent-replay-snapshot"
    snapshotId     = $snapshotName
    capturedUtc    = $captured
    provider       = $Provider
    binding        = $binding
    bindings       = $bindings
    resources      = @($resources.ToArray())
    manifestDigest = $digest
}
if ($schemaVersion -eq 2) {
    $manifest.Remove("manifestDigest")
    $manifest["sourceTransport"] = $sourceTransport
    $manifest["manifestDigest"] = $digest
}
$manifestPath = Join-Path $snapshotFull "manifest.json"
[System.IO.File]::WriteAllBytes($manifestPath, $utf8.GetBytes(($manifest | ConvertTo-Json -Depth 20)))

# Prove the manifest we just wrote is one the loader accepts, rather than
# claiming it. A writer that emits an unloadable snapshot is worse than none.
$verified = New-AgentReplaySnapshot -ReplayRoot (Split-Path $snapshotFull -Parent) -SnapshotName $snapshotName -ExpectedManifestDigest $digest
Write-Host ("Sealed replay snapshot '{0}': {1} resource(s), {2} payload byte(s), digest {3}" -f `
        $verified.SnapshotId, $verified.ResourceCount, $verified.PayloadBytes, $verified.ManifestDigest) -ForegroundColor Green
