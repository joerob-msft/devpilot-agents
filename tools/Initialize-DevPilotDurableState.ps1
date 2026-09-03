#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Migrates one legacy agent role state directory into canonical durable state v2.

.DESCRIPTION
    Repository identity and every PR/source-commit record are verified against
    Azure DevOps before the atomic import. Existing v2 records, conflicting
    receipts, and missing pending-delivery manifests fail closed.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('reviewer', 'review-handler')][string]$Role,
    [string]$LegacyStateDir,
    [switch]$ReconciledEmpty,
    [Parameter(Mandatory)][string]$RepositoryRoot,
    [Parameter(Mandatory)][string]$Organization,
    [Parameter(Mandatory)][string]$Project,
    [Parameter(Mandatory)][string]$RepositoryName,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$RepositoryId,
    [string]$DurableStateRoot,
    [string]$LeaseRoot,
    [string]$AgencyPath,
    [Parameter(DontShow)][AllowNull()]$ProviderContext
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force

function Read-LegacyReviewerSigningKey {
    param([Parameter(Mandatory)][string]$Path)
    $allowedRoot = [IO.Path]::GetFullPath((Split-Path $Path -Parent))
    [void](Assert-AgentTrustedFile -Path ([IO.Path]::GetFullPath($Path)) `
        -AllowedRoot $allowedRoot -Private)
    $line = (Get-Content -LiteralPath $Path -Raw -Encoding ASCII).Trim()
    $separator = $line.IndexOf(':')
    $format = if ($separator -gt 0) { $line.Substring(0, $separator) } elseif ($IsWindows) { 'dpapi' } else { 'raw' }
    $encoded = if ($separator -gt 0) { $line.Substring($separator + 1) } else { $line }
    $stored = [Convert]::FromBase64String($encoded)
    $key = switch ($format) {
        'raw' { $stored }
        'dpapi' {
            if (-not $IsWindows) { throw 'A DPAPI reviewer signing key cannot be migrated on this platform.' }
            [Security.Cryptography.ProtectedData]::Unprotect(
                $stored, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        }
        default { throw "Legacy reviewer signing key declares unknown format '$format'." }
    }
    if ($key.Length -ne 32) { throw 'Legacy reviewer signing key is not 32 bytes.' }
    return $key
}

$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
if ([bool]$LegacyStateDir -eq [bool]$ReconciledEmpty) {
    throw 'Specify exactly one of -LegacyStateDir or -ReconciledEmpty.'
}
if ($LegacyStateDir) {
    $LegacyStateDir = (Resolve-Path -LiteralPath $LegacyStateDir).Path
}
if (-not $DurableStateRoot) { $DurableStateRoot = Get-AgentDefaultDurableStateRoot }
if (-not $LeaseRoot) { $LeaseRoot = Get-AgentDefaultLeaseRoot }
$DurableStateRoot = Resolve-AgentTrustedRoot -Path $DurableStateRoot -Kind durable-state `
    -RepositoryRoot $RepositoryRoot -DisallowedRoots @($LegacyStateDir | Where-Object { $_ }) -Create
$LeaseRoot = Resolve-AgentTrustedRoot -Path $LeaseRoot -Kind lease `
    -RepositoryRoot $RepositoryRoot -DisallowedRoots @(@($LegacyStateDir | Where-Object { $_ }) + $DurableStateRoot) -Create

$legacyFile = if ($LegacyStateDir) {
    Join-Path $LegacyStateDir $(if ($Role -eq 'reviewer') { 'reviewed.json' } else { 'handled.json' })
}
else { $null }
if ($legacyFile -and -not (Test-Path -LiteralPath $legacyFile -PathType Leaf)) {
    throw "Declared legacy $Role state file '$legacyFile' does not exist."
}
$legacyRecords = if ($ReconciledEmpty) { @{} } else {
    Get-JsonState -Path $legacyFile -FailClosedOnCorruption
}
if ($null -eq $legacyRecords) { throw "Legacy state '$legacyFile' is corrupt." }

if (-not $ProviderContext -and -not $AgencyPath) {
    $agency = Get-Command agency -ErrorAction Stop
    $AgencyPath = if ($agency.Path) { $agency.Path } else { $agency.Source }
}
$session = $null
$lock = $null
try {
    if ($ProviderContext) {
        $provider = $ProviderContext
    }
    else {
        $session = Open-AgentMcpSession -AgencyPath $AgencyPath -Server ado -Organization $Organization `
            -Toolsets @('repos') -TimeoutSeconds 10
        $invoker = {
            param($Name, $Arguments, $RawText)
            Invoke-AgentMcpTool -Session $session -Name $Name -Arguments $Arguments -RawText:$RawText
        }.GetNewClosure()
        $provider = New-AgentProviderContext -Provider AzureDevOps -Organization $Organization -Project $Project `
            -RepositoryName $RepositoryName -RepositoryId $RepositoryId -McpInvoker $invoker -TimeoutSeconds 10
    }
    $identity = Resolve-AgentProviderRepositoryIdentity -Context $provider
    $reader = {
        param([int]$PullRequestId)
        Get-AgentProviderPullRequestSnapshot -Context $provider -PullRequestId $PullRequestId
    }.GetNewClosure()
    $confirmed = Confirm-AgentLegacyRecordsForMigration -Role $Role -Records $legacyRecords `
        -PullRequestReader $reader

    $context = Get-AgentDurableStateContext -DurableStateRoot $DurableStateRoot `
        -RepositoryIdentity $identity -Role $Role -Create
    $lock = Enter-AgentDurableStateLock -Context $context
    if (-not $lock.Acquired) { throw "Durable state migration could not acquire the repository/role lock (state-contended)." }

    $legacyKeyHash = ''
    if ($Role -eq 'reviewer' -and $LegacyStateDir) {
        $pending = @($confirmed.Values | Where-Object {
                $_ -is [Collections.IDictionary] -and [bool]$_.deliveryPending
            }).Count -gt 0
        $legacyKeyPath = Join-Path $LegacyStateDir 'artifact-signing.key'
        if ($pending -and -not (Test-Path -LiteralPath $legacyKeyPath -PathType Leaf)) {
            throw 'Pending reviewer deliveries require the legacy artifact-signing key for migration.'
        }
        if (Test-Path -LiteralPath $legacyKeyPath -PathType Leaf) {
            $legacyKey = Read-LegacyReviewerSigningKey -Path $legacyKeyPath
            $legacyKeyHash = [Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData($legacyKey)).ToLowerInvariant()
            $durableKeyPath = Join-Path $context.RoleRoot 'artifact-signing.key'
            if (Test-Path -LiteralPath $durableKeyPath) {
                $durableKey = Read-LegacyReviewerSigningKey -Path $durableKeyPath
                $durableKeyHash = [Convert]::ToHexString(
                    [Security.Cryptography.SHA256]::HashData($durableKey)).ToLowerInvariant()
                if ($durableKeyHash -cne $legacyKeyHash) {
                    throw 'Legacy reviewer signing key conflicts with the durable repository/role key.'
                }
            }
            else {
                $tempKeyPath = "$durableKeyPath.tmp-$PID-$([Guid]::NewGuid().ToString('N'))"
                [IO.File]::Copy($legacyKeyPath, $tempKeyPath)
                if (-not $IsWindows) {
                    [IO.File]::SetUnixFileMode($tempKeyPath,
                        [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
                }
                [IO.File]::Move($tempKeyPath, $durableKeyPath)
            }
        }
    }

    $receiptKey = if ($legacyFile) {
        Get-AgentSha256 -Text ([IO.Path]::GetFullPath($legacyFile))
    }
    else {
        Get-AgentSha256 -Text "reconciled-empty:$($identity.key):$Role"
    }
    $receiptHash = if ($legacyFile) {
        Get-AgentCanonicalDigest @{
            stateSha256 = (Get-FileHash -LiteralPath $legacyFile -Algorithm SHA256).Hash.ToLowerInvariant()
            signingKeySha256 = $legacyKeyHash
        }
    }
    else {
        Get-AgentCanonicalDigest @{ schemaVersion = 1; repositoryKey = $identity.key; role = $Role; records = @{} }
    }
    $written = Initialize-AgentDurableState -Context $context -Records $confirmed `
        -ReceiptKey $receiptKey -ReceiptSha256 $receiptHash
    [pscustomobject]@{
        role = $Role
        repositoryKey = $identity.key
        generation = $written.generation
        recordsImported = $confirmed.Count
        receiptSha256 = $receiptHash
        statePath = $context.StatePath
    }
}
finally {
    if ($lock) { Exit-AgentLock -Stream $lock.Stream }
    if ($session) { Close-AgentMcpSession -Session $session }
}
