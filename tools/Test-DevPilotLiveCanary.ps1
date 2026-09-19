#!/usr/bin/env pwsh
#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReviewerConfigFile,
    [Parameter(Mandatory)][string]$ReviewHandlerConfigFile,
    [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$ReviewerPullRequestId,
    [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$ReviewHandlerPullRequestId,
    [ValidateRange(10, 120)][int]$McpTimeoutSeconds = 60,
    [ValidateRange(1, 5)][int]$McpAttempts = 3,
    [ValidateRange(0, 30)][int]$McpRetryDelaySeconds = 5,
    [string]$AgencyPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$toolkitRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $toolkitRoot 'src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
if (-not $AgencyPath) {
    $agency = Get-Command agency -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $AgencyPath = $agency.Source
}

function Read-CanaryConfig {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('reviewer', 'review-handler')][string]$Role
    )

    $agentDir = Join-Path $toolkitRoot "src\Agents\$Role"
    $config = Get-AgentConfig -Path $Path -AgentDir $agentDir
    $repository = Get-AgentConfigObject -Object $config.Raw -Name repository -Where "$Role config"
    return [ordered]@{
        Config = $config.Raw
        Organization = Get-AgentConfigString -Object $repository -Name organization -Where "$Role config.repository"
        Project = Get-AgentConfigString -Object $repository -Name project -Where "$Role config.repository"
        RepositoryName = Get-AgentConfigString -Object $repository -Name name -Where "$Role config.repository"
        RepositoryId = Get-AgentConfigString -Object $repository -Name id -Where "$Role config.repository" `
            -Pattern '^[0-9a-fA-F-]{36}$'
    }
}

$reviewer = Read-CanaryConfig -Path $ReviewerConfigFile -Role reviewer
$handler = Read-CanaryConfig -Path $ReviewHandlerConfigFile -Role review-handler
foreach ($name in @('Organization', 'Project', 'RepositoryName', 'RepositoryId')) {
    if ([string]$reviewer[$name] -cne [string]$handler[$name]) {
        throw "Reviewer and review-handler canary configs disagree on repository field '$name'."
    }
}

$teams = Get-AgentConfigObject -Object $reviewer.Config -Name teamsNotifications `
    -Where 'reviewer config'
$workIq = Get-AgentConfigObject -Object $teams -Name workIq `
    -Where 'reviewer config.teamsNotifications'
$allowedTools = Get-AgentConfigStringArray -Object $workIq -Name toolAllowlist `
    -Where 'reviewer config.teamsNotifications.workIq'
$allowedPaths = Get-AgentConfigStringArray -Object $workIq -Name pathPrefixAllowlist `
    -Where 'reviewer config.teamsNotifications.workIq'

for ($attempt = 1; $attempt -le $McpAttempts; $attempt++) {
    $adoSession = $null
    $workIqSession = $null
    try {
        $adoSession = Open-AgentMcpSession -AgencyPath $AgencyPath -Server ado `
            -Organization $reviewer.Organization -Toolsets @('repos') -TimeoutSeconds $McpTimeoutSeconds
        $adoInvoker = {
            param($Name, $Arguments, $RawText)
            Invoke-AgentMcpTool -Session $adoSession -Name $Name -Arguments $Arguments -RawText:$RawText
        }.GetNewClosure()
        $provider = New-AgentProviderContext -Provider AzureDevOps -Organization $reviewer.Organization `
            -Project $reviewer.Project -RepositoryName $reviewer.RepositoryName `
            -RepositoryId $reviewer.RepositoryId -McpInvoker $adoInvoker -TimeoutSeconds $McpTimeoutSeconds
        $identity = Resolve-AgentProviderRepositoryIdentity -Context $provider
        if (-not $identity.verified -or $identity.repositoryId -cne $reviewer.RepositoryId.ToLowerInvariant()) {
            throw 'Live canary repository identity did not match the configured repository.'
        }

        foreach ($target in @(
                [ordered]@{ Role = 'reviewer'; PullRequestId = $ReviewerPullRequestId },
                [ordered]@{ Role = 'review-handler'; PullRequestId = $ReviewHandlerPullRequestId })) {
            $snapshot = Get-AgentProviderPullRequestSnapshot -Context $provider `
                -PullRequestId $target.PullRequestId
            if ($snapshot.prId -ne $target.PullRequestId -or
                [string]$snapshot.status -ine 'Active' -or $snapshot.isDraft -or
                $snapshot.sourceCommit -cnotmatch '^[0-9a-f]{40}$') {
                throw "Live canary $($target.Role) PR $($target.PullRequestId) is not an active non-draft snapshot."
            }
        }

        $workIqSession = Open-AgentMcpSession -AgencyPath $AgencyPath -Server workiq `
            -TimeoutSeconds $McpTimeoutSeconds
        $me = Invoke-AgentWorkIqTool -Session $workIqSession -Name fetch `
            -Arguments @{ entityUrls = @('/me') } -AllowedTools $allowedTools `
            -AllowedPathPrefixes $allowedPaths
        if ($null -eq $me) { throw 'Live canary WorkIQ /me read returned no data.' }

        return [pscustomobject][ordered]@{
            schemaVersion = 1
            repositoryKey = $identity.key
            reviewerPullRequestId = $ReviewerPullRequestId
            reviewHandlerPullRequestId = $ReviewHandlerPullRequestId
            workIqVerified = $true
        }
    }
    catch {
        $failure = $_
        $message = [string]$failure.Exception.Message
        $recoverable = (Test-AgentRecoverableMcpTransportFailure -Message $message) -or
            $message -ceq 'Agent MCP returned malformed JSON-RPC.' -or
            $message -match '^Agent MCP request failed \(JSON-RPC error code -32000\)(?::|\.|$)'
        if (-not $recoverable -or $attempt -ge $McpAttempts) { throw $failure }
        Write-Warning "Live canary MCP attempt $attempt/$McpAttempts failed; retrying with fresh ADO and WorkIQ sessions. $message"
        if ($McpRetryDelaySeconds -gt 0) { Start-Sleep -Seconds $McpRetryDelaySeconds }
    }
    finally {
        if ($workIqSession) { Close-AgentMcpSession -Session $workIqSession -Abort }
        if ($adoSession) { Close-AgentMcpSession -Session $adoSession -Abort }
    }
}
