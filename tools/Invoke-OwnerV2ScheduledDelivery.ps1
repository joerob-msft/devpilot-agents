#!/usr/bin/env pwsh
#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StateRoot,
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][string]$ToolkitConfigPath,
    [Parameter(Mandatory)][string]$DeliveryRoot,
    [int]$MaxAttempts = 3,
    [int]$LeaseSeconds = 300,
    [switch]$EnableLiveModel,
    [string]$LiveModel,
    [ValidateSet('COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')]
    [string]$LiveCredentialEnvironmentName,
    [AllowNull()][object]$LiveAcquisitionProvider,
    [AllowNull()][object]$LiveModelProvider,
    [AllowNull()][object]$DeliveryProvider,
    [string]$AzureCliPath = 'az',
    [string]$GitPath = 'git',
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($path in @(
        $StateRoot, $ManifestPath, $ToolkitConfigPath, $DeliveryRoot
    )) {
    if (-not [IO.Path]::IsPathFullyQualified($path)) {
        throw 'Scheduled Owner paths must all be absolute.'
    }
}

Import-Module (Join-Path $RepoRoot `
        'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
Import-Module (Join-Path $RepoRoot `
        'src\DevPilot.OwnerAdapters\DevPilot.OwnerAdapters.psd1') -Force
Import-Module (Join-Path $RepoRoot `
        'src\DevPilot.OwnerCapability\DevPilot.OwnerCapability.psd1') -Force
Import-Module (Join-Path $RepoRoot `
        'src\DevPilot.OwnerOrchestrator\DevPilot.OwnerOrchestrator.psd1') -Force
. (Join-Path $RepoRoot 'src\Agents\reviewer\ApprovedOwnerV2Comments.ps1')
. (Join-Path $RepoRoot 'src\Agents\reviewer\AutomaticOwnerV2Comments.ps1')
. (Join-Path $RepoRoot `
    'src\Agents\reviewer\AzureDevOpsOwnerV2CommentProvider.ps1')

$manifest = Read-ApprovedOwnerV2Json -Path $ManifestPath
if ([string]$manifest.kind -cne 'owner-v2-preview-cohort') {
    throw 'Scheduled automatic Owner delivery accepts only the Owner cohort.'
}

[void](Invoke-OwnerV2PreviewPrepare -StateRoot $StateRoot `
        -ManifestPath $ManifestPath -MaxAttempts $MaxAttempts)
$liveArguments = @{}
if ($EnableLiveModel) { $liveArguments.EnableLiveModel = $true }
if ($LiveModel) { $liveArguments.LiveModel = $LiveModel }
if ($LiveCredentialEnvironmentName) {
    $liveArguments.LiveCredentialEnvironmentName =
        $LiveCredentialEnvironmentName
}
if ($null -ne $LiveAcquisitionProvider) {
    $liveArguments.LiveAcquisitionProvider = $LiveAcquisitionProvider
}
if ($null -ne $LiveModelProvider) {
    $liveArguments.LiveModelProvider = $LiveModelProvider
}
$observation = Invoke-OwnerV2PreviewRun -StateRoot $StateRoot `
    -ManifestPath $ManifestPath -LeaseSeconds $LeaseSeconds @liveArguments

$toolkit = Read-ApprovedOwnerV2Json -Path $ToolkitConfigPath
$automatic = Get-AutomaticOwnerV2Configuration -ToolkitConfig $toolkit
$completed = @($observation.records | Where-Object {
        [string]$_.state -ceq 'completed'
    } | Sort-Object identity)
$deliveryResults = [Collections.Generic.List[object]]::new()
$remainingRunCreates = 5
$processedRecords = 0

if ($automatic.Enabled) {
    $deliveryReady = $false
    try {
        $context = Initialize-AutomaticOwnerV2DeliveryRoot `
            -DeliveryRoot $DeliveryRoot -RepoRoot $RepoRoot
        [void](Assert-AgentTrustedFile -Path $automatic.PolicyPath `
                -AllowedRoot (Join-Path $context.Root 'policies') -Private)
        if ((Get-ApprovedOwnerV2FileSha256 $automatic.PolicyPath) -cne
            $automatic.PolicySha256) {
            throw 'Configured automatic Owner service policy file digest changed.'
        }
        $key = Get-AutomaticOwnerV2ServiceKey -DeliveryRoot $context.Root
        $policy = Read-ApprovedOwnerV2SignedRecord `
            -Path $automatic.PolicyPath -Key $key
        $remainingRunCreates = Get-AutomaticOwnerV2RunLimit `
            -PolicyMaximum ([int]$policy.limits.maxCreatesPerRun)
        $provider = if ($null -ne $DeliveryProvider) {
            [scriptblock]$DeliveryProvider
        }
        else {
            New-ApprovedOwnerV2AzureDevOpsProvider `
                -ProviderConfigPath $ToolkitConfigPath `
                -AzureCliPath $AzureCliPath -GitPath $GitPath
        }
        $deliveryReady = $true
    }
    catch {
        [void]$deliveryResults.Add([pscustomobject][ordered]@{
                kind = 'owner-v2-automatic-delivery-result'
                health = 'refused'
                providerWrites = 0
                modelWrites = 0
                remainingWouldCreate = 0
                events = @()
                diagnostic = Get-AutomaticOwnerV2Diagnostic `
                    -Code 'policy-preflight-refused' `
                    -Message 'Automatic delivery policy preflight failed.'
            })
    }
    if ($deliveryReady) {
        foreach ($record in $completed) {
            $evidence = Read-ApprovedOwnerV2Evidence -StateRoot $StateRoot `
                -Identity ([string]$record.identity) -RepoRoot $RepoRoot `
                -ToolkitConfigPath $ToolkitConfigPath
            $result = Invoke-AutomaticOwnerV2Comments -Evidence $evidence `
                -Policy $policy -DeliveryRoot $context.Root -Key $key `
                -Provider $provider -MaximumCreates $remainingRunCreates
            [void]$deliveryResults.Add($result)
            $processedRecords++
            $remainingRunCreates -= [int]$result.providerWrites
            if ($remainingRunCreates -le 0) { break }
        }
    }
}

$failedCount = @($observation.records | Where-Object {
        [string]$_.state -cne 'completed'
    }).Count
$health = Get-AutomaticOwnerV2ScheduledHealth `
    -FailedCount $failedCount -CompletedCount $completed.Count `
    -AutomaticEnabled $automatic.Enabled `
    -DeliveryResults $deliveryResults.ToArray() `
    -RemainingRunCreates $remainingRunCreates `
    -ProcessedRecords $processedRecords
$providerWrites = 0
foreach ($deliveryResult in $deliveryResults) {
    $providerWrites += [int]$deliveryResult.providerWrites
}
$result = [pscustomobject][ordered]@{
    schemaVersion = 1
    kind = 'owner-v2-scheduled-delivery-result'
    health = $health
    observation = [ordered]@{
        records = @($observation.records).Count
        completed = $completed.Count
        failed = $failedCount
    }
    delivery = [ordered]@{
        enabled = $automatic.Enabled
        providerWrites = $providerWrites
        modelWrites = 0
        remainingRunCreates = $remainingRunCreates
        results = $deliveryResults.ToArray()
    }
    relationWrites = 0
}
$result
exit (Get-AutomaticOwnerV2ExitCode -Health $health)
