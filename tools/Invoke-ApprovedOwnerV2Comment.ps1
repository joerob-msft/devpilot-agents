#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Exports, approves, dry-runs, or publishes exact Owner v2 comment selections.

.DESCRIPTION
    This manual command is not used by the scheduler. Export creates an
    unsigned review package. Approve signs one to five exact findings. Invoke
    requires -Approve and defaults to dry-run; -Publish is a separate opt-in.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('initialize-key', 'export', 'approve', 'invoke')]
    [string]$Command,

    [Parameter(Mandatory)][string]$ApprovalRoot,
    [string]$StateRoot,
    [ValidatePattern('^$|^[0-9a-f]{64}$')][string]$Identity,
    [string]$ToolkitConfigPath,
    [string]$ProviderConfigPath,
    [string]$ReviewPackagePath,
    [string]$ApprovalPackagePath,
    [string[]]$FindingId,
    [string]$OperatorId,
    [string]$OperatorDescriptor,
    [string]$OperatorUpn,
    [string]$Reason,
    [switch]$Approve,
    [switch]$Publish,
    [switch]$DryRun,
    [switch]$ApproveUpdate,
    [string]$AzureCliPath = 'az',
    [string]$GitPath = 'git',
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Publish -and $DryRun) {
    throw '-Publish and -DryRun are mutually exclusive.'
}

Import-Module (Join-Path $RepoRoot `
        'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
Import-Module (Join-Path $RepoRoot `
        'src\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1') -Force
Import-Module (Join-Path $RepoRoot `
        'src\DevPilot.OwnerCapability\DevPilot.OwnerCapability.psd1') -Force
. (Join-Path $RepoRoot 'src\Agents\reviewer\ApprovedOwnerV2Comments.ps1')
. (Join-Path $RepoRoot 'src\Agents\reviewer\AzureDevOpsOwnerV2CommentProvider.ps1')

function Resolve-ApprovedOwnerV2PrivatePath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][ValidateSet('reviews', 'approvals')][string]$Area,
        [switch]$RequireExisting
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not [IO.Path]::IsPathFullyQualified($Path)) {
        throw "$Area path must be an absolute path inside the private approval root."
    }
    $resolved = [IO.Path]::GetFullPath($Path)
    $areaRoot = Join-Path $Root $Area
    if (-not (Test-AgentPathWithin -Path $resolved -Root $areaRoot)) {
        throw "$Area path must remain inside '$areaRoot'."
    }
    if ($RequireExisting) {
        [void](Assert-AgentTrustedFile -Path $resolved `
                -AllowedRoot $areaRoot -Private)
    }
    return $resolved
}

$approvalContext = Initialize-ApprovedOwnerV2ApprovalRoot `
    -ApprovalRoot $ApprovalRoot -RepoRoot $RepoRoot
if ($Command -ceq 'initialize-key') {
    Write-Output (ConvertTo-Json -Compress -InputObject ([ordered]@{
                approvalRoot = $approvalContext.Root
                keyPath = $approvalContext.KeyPath
                authorization = 'none'
            }))
    exit 0
}

if ([string]::IsNullOrWhiteSpace($StateRoot) -or
    [string]::IsNullOrWhiteSpace($Identity) -or
    [string]::IsNullOrWhiteSpace($ToolkitConfigPath) -or
    -not [IO.Path]::IsPathFullyQualified($StateRoot) -or
    -not [IO.Path]::IsPathFullyQualified($ToolkitConfigPath)) {
    throw "$Command requires -StateRoot, -Identity, and -ToolkitConfigPath."
}
$evidence = Read-ApprovedOwnerV2Evidence -StateRoot $StateRoot `
    -Identity $Identity -RepoRoot $RepoRoot `
    -ToolkitConfigPath $ToolkitConfigPath

if ($Command -ceq 'export') {
    $package = New-ApprovedOwnerV2ReviewPackage -Evidence $evidence
    if ([string]::IsNullOrWhiteSpace($ReviewPackagePath)) {
        $ReviewPackagePath = Join-Path $approvalContext.Root (
            "reviews\$Identity.review.json")
    }
    $ReviewPackagePath = Resolve-ApprovedOwnerV2PrivatePath `
        -Path $ReviewPackagePath -Root $approvalContext.Root -Area reviews
    [void](Write-ApprovedOwnerV2ImmutableText -Path $ReviewPackagePath `
        -Text ((ConvertTo-ApprovedOwnerV2CanonicalJson $package) + "`n"))
    Write-Output (ConvertTo-Json -Compress -Depth 8 -InputObject ([ordered]@{
                mode = 'export'
                authorization = 'none'
                reviewPackagePath = [IO.Path]::GetFullPath($ReviewPackagePath)
                reviewPackageSha256 = Get-ApprovedOwnerV2FileSha256 $ReviewPackagePath
                proposals = @($package.proposals | ForEach-Object {
                        [ordered]@{
                            findingId = $_.findingId
                            path = $_.path
                            line = $_.line
                            marker = $_.marker
                            bodySha256 = $_.bodySha256
                        }
                    })
            }))
    exit 0
}

$key = Get-ApprovedOwnerV2ApprovalKey -ApprovalRoot $approvalContext.Root
if ($Command -ceq 'approve') {
    if (-not $Approve) { throw 'approve requires explicit -Approve.' }
    if ([string]::IsNullOrWhiteSpace($ReviewPackagePath) -or
        [string]::IsNullOrWhiteSpace($ApprovalPackagePath) -or
        @($FindingId).Count -lt 1) {
        throw 'approve requires review/approval package paths and exact -FindingId values.'
    }
    $ReviewPackagePath = Resolve-ApprovedOwnerV2PrivatePath `
        -Path $ReviewPackagePath -Root $approvalContext.Root -Area reviews `
        -RequireExisting
    $ApprovalPackagePath = Resolve-ApprovedOwnerV2PrivatePath `
        -Path $ApprovalPackagePath -Root $approvalContext.Root -Area approvals
    $path = Approve-OwnerV2ReviewPackage `
        -ReviewPackagePath $ReviewPackagePath `
        -ApprovalPath $ApprovalPackagePath `
        -FindingId $FindingId `
        -OperatorId $OperatorId `
        -OperatorDescriptor $OperatorDescriptor `
        -OperatorUpn $OperatorUpn `
        -Reason $Reason `
        -Key $key `
        -ApproveUpdate:$ApproveUpdate
    Write-Output (ConvertTo-Json -Compress -InputObject ([ordered]@{
                mode = 'approve'
                approvalPackagePath = [IO.Path]::GetFullPath($path)
                approvalPackageSha256 = Get-ApprovedOwnerV2FileSha256 $path
                selectionCount = @($FindingId).Count
            }))
    exit 0
}

if (-not $Approve) { throw 'invoke requires explicit -Approve.' }
if ([string]::IsNullOrWhiteSpace($ApprovalPackagePath) -or
    [string]::IsNullOrWhiteSpace($ProviderConfigPath) -or
    -not [IO.Path]::IsPathFullyQualified($ProviderConfigPath)) {
    throw 'invoke requires -ApprovalPackagePath and -ProviderConfigPath.'
}
$ApprovalPackagePath = Resolve-ApprovedOwnerV2PrivatePath `
    -Path $ApprovalPackagePath -Root $approvalContext.Root -Area approvals `
    -RequireExisting
$approval = Read-ApprovedOwnerV2SignedRecord -Path $ApprovalPackagePath -Key $key
$provider = New-ApprovedOwnerV2AzureDevOpsProvider `
    -ProviderConfigPath $ProviderConfigPath `
    -AzureCliPath $AzureCliPath -GitPath $GitPath
$result = Invoke-ApprovedOwnerV2Comments -Evidence $evidence `
    -Approval $approval -ApprovalRoot $approvalContext.Root `
    -Key $key -Provider $provider -Publish:$Publish `
    -ApproveUpdate:$ApproveUpdate
Write-Output (ConvertTo-Json -Compress -Depth 12 -InputObject $result)
