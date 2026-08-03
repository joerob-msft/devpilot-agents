#requires -Version 7.0

<#
.SYNOPSIS
    Wrapper-owned Agency ADO MCP client for reviewer-agent PR selection and votes.

.DESCRIPTION
    This file is dot-sourced only by Start-ReviewerAgent.ps1. It starts
    `agency mcp ado --organization <org> --toolsets repos` directly and speaks
    compact, newline-delimited MCP JSON-RPC over stdio. Authentication is the
    current Agency/ADO signed-in user; no PAT, token acquisition, reviewer GUID,
    direct ADO REST call, or model-accessible credential bridge is used.

    All MCP responses are untrusted. The client validates protocol responses,
    tool schemas, repository/PR shapes, exact PR/commit binding, and vote values.
    The model never receives repo_pull_request_write. The only sign-off request
    constructed here has the fixed action "vote" and accepts only Approved or
    WaitingForAuthor.
#>

Set-StrictMode -Version Latest

$script:ReviewerAgencyMcpProtocolVersion = "2025-03-26"
$script:ReviewerAgencyMcpClientName = "devpilot-reviewer-agent-wrapper"

function Test-AgencyMcpGuid {
    param([string]$Value)
    return [bool]($Value -and $Value -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
}

function Test-AgencyMcpStrictInt {
    param($Value, [long]$Min, [long]$Max)
    if ($null -eq $Value -or $Value -is [bool]) { return $false }
    if (-not ($Value -is [int] -or $Value -is [long])) { return $false }
    $number = [long]$Value
    return ($number -ge $Min -and $number -le $Max)
}

function ConvertTo-AgencyAdoAuthorAlias {
    param([Parameter(Mandatory)][string]$UniqueName)
    $value = $UniqueName.Trim()
    if (-not $value -or $value.Length -gt 320) {
        return $null
    }
    if ($value -match '^([^@]+)@[^@]+$') {
        $value = $Matches[1]
    }
    elseif ($value.Contains('\')) {
        $value = $value.Substring($value.LastIndexOf('\') + 1)
    }
    if ($value -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        return $null
    }
    return $value.ToLowerInvariant()
}

function ConvertTo-AgencyAdoUtcDateTime {
    param([Parameter(Mandatory)]$Value)
    if ($Value -is [DateTimeOffset]) {
        return $Value.UtcDateTime
    }
    if ($Value -is [DateTime]) {
        return $Value.ToUniversalTime()
    }
    if ($Value -isnot [string] -or -not $Value -or $Value.Length -gt 100) {
        throw "Agency ADO MCP returned an invalid source-commit date."
    }
    $parsed = [DateTimeOffset]::MinValue
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor
        [Globalization.DateTimeStyles]::AdjustToUniversal
    if (-not [DateTimeOffset]::TryParse(
        $Value,
        [Globalization.CultureInfo]::InvariantCulture,
        $styles,
        [ref]$parsed
    )) {
        throw "Agency ADO MCP returned an invalid source-commit date."
    }
    return $parsed.UtcDateTime
}

function Get-AgencyMcpRequiredProperty {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name
    )
    if ($Object -isnot [System.Management.Automation.PSCustomObject]) {
        throw "Agency MCP returned an unexpected object shape."
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        throw "Agency MCP response omitted a required field."
    }
    return $property.Value
}

function Set-AgencyMcpProcessArguments {
    param(
        [Parameter(Mandatory)][System.Diagnostics.ProcessStartInfo]$ProcessStartInfo,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )
    foreach ($argument in $ArgumentList) {
        $ProcessStartInfo.ArgumentList.Add($argument)
    }
}

function Stop-AgencyMcpProcessTree {
    param([Parameter(Mandatory)][System.Diagnostics.Process]$Process)
    if ($Process.HasExited) { return }

    try {
        $Process.Kill($true)
        return
    }
    catch {}

    try { & taskkill.exe /PID $Process.Id /T /F 2>$null 1>$null } catch {}
    try { $Process.Kill() } catch {}
}

function Close-AgencyAdoMcpSession {
    param(
        [hashtable]$Session,
        [switch]$Abort
    )
    if (-not $Session -or -not $Session.Process) { return }
    $process = [System.Diagnostics.Process]$Session.Process
    try { $process.StandardInput.Close() } catch {}
    if ($Abort -or -not $process.WaitForExit(2000)) {
        Stop-AgencyMcpProcessTree -Process $process
        try { $process.WaitForExit(5000) | Out-Null } catch {}
    }
    $process.Dispose()
    $Session.Process = $null
}

function Receive-AgencyMcpResponse {
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][long]$ExpectedId,
        [Nullable[DateTime]]$DeadlineUtc
    )
    $perCallDeadline = [DateTime]::UtcNow.AddSeconds([int]$Session.TimeoutSeconds)
    # The caller's aggregate budget (e.g. candidate selection) can be tighter
    # than this single call's transport timeout. Track WHICH one bounds us so
    # exhaustion is not misreported as a transport fault - a budget overrun
    # previously surfaced as "response timed out", sending operators chasing
    # tokens and MCP hangs while every underlying read was in fact succeeding.
    $deadline = $perCallDeadline
    $boundedByAggregateBudget = $false
    if ($null -ne $DeadlineUtc -and [DateTime]$DeadlineUtc -lt $deadline) {
        $deadline = [DateTime]$DeadlineUtc
        $boundedByAggregateBudget = $true
    }
    try {
        while ([DateTime]::UtcNow -lt $deadline) {
            $process = [System.Diagnostics.Process]$Session.Process
            if ($process.HasExited) {
                throw "Agency ADO MCP exited before returning a response."
            }
            if ($null -eq $Session.ReadTask) {
                $Session.ReadTask = $process.StandardOutput.ReadLineAsync()
            }
            if (-not $Session.ReadTask.Wait(200)) { continue }

            $line = $Session.ReadTask.Result
            $Session.ReadTask = $null
            if ($null -eq $line) {
                throw "Agency ADO MCP closed stdout before returning a response."
            }
            if ($line.Length -gt 20MB) {
                # Sanity check on a trusted child (the locally installed `agency`
                # binary), not a real memory bound: ReadLineAsync() has already
                # materialized the full line before this check can fire.
                throw "Agency ADO MCP returned an oversized response."
            }

            try {
                $response = $line | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                throw "Agency ADO MCP returned malformed JSON-RPC."
            }
            if ($response -isnot [System.Management.Automation.PSCustomObject] -or
                $null -eq $response.PSObject.Properties["jsonrpc"] -or
                [string]$response.jsonrpc -cne "2.0") {
                throw "Agency ADO MCP returned an invalid JSON-RPC envelope."
            }

            $idProperty = $response.PSObject.Properties["id"]
            if ($null -eq $idProperty) {
                # MCP notifications are permitted while waiting for a response.
                continue
            }
            if (-not (Test-AgencyMcpStrictInt -Value $idProperty.Value -Min 1 -Max ([long]::MaxValue)) -or
                [long]$idProperty.Value -ne $ExpectedId) {
                throw "Agency ADO MCP returned an unexpected response id."
            }

            $hasResult = $null -ne $response.PSObject.Properties["result"]
            $hasError = $null -ne $response.PSObject.Properties["error"]
            if ($hasResult -eq $hasError) {
                throw "Agency ADO MCP returned an invalid result/error envelope."
            }
            if ($hasError) {
                $errorObject = $response.error
                $errorCode = if ($errorObject -and $errorObject.PSObject.Properties["code"]) {
                    [string]$errorObject.code
                }
                else {
                    "unknown"
                }
                throw "Agency ADO MCP request failed (JSON-RPC error code $errorCode)."
            }
            return $response.result
        }
        if ($boundedByAggregateBudget) {
            throw "Agency ADO MCP read stopped because the caller's aggregate budget expired, not because the transport stalled; raise -SelectionBudgetSeconds or reduce the PR queue depth."
        }
        throw "Agency ADO MCP response timed out."
    }
    catch {
        Close-AgencyAdoMcpSession -Session $Session -Abort
        throw
    }
}

function Send-AgencyMcpRequest {
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][hashtable]$Params,
        [Nullable[DateTime]]$DeadlineUtc
    )
    if (-not $Session.Process) { throw "Agency ADO MCP session is closed." }
    $Session.NextId = [long]$Session.NextId + 1
    $requestId = [long]$Session.NextId
    $request = [ordered]@{
        jsonrpc = "2.0"
        id      = $requestId
        method  = $Method
        params  = $Params
    }
    $line = $request | ConvertTo-Json -Compress -Depth 20
    try {
        $Session.Process.StandardInput.WriteLine($line)
        $Session.Process.StandardInput.Flush()
    }
    catch {
        Close-AgencyAdoMcpSession -Session $Session -Abort
        throw "Could not write to Agency ADO MCP."
    }
    return Receive-AgencyMcpResponse -Session $Session -ExpectedId $requestId -DeadlineUtc $DeadlineUtc
}

function Send-AgencyMcpNotification {
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][string]$Method,
        [hashtable]$Params = @{}
    )
    $notification = [ordered]@{
        jsonrpc = "2.0"
        method  = $Method
        params  = $Params
    } | ConvertTo-Json -Compress -Depth 10
    try {
        $Session.Process.StandardInput.WriteLine($notification)
        $Session.Process.StandardInput.Flush()
    }
    catch {
        Close-AgencyAdoMcpSession -Session $Session -Abort
        throw "Could not write an Agency ADO MCP notification."
    }
}

function Assert-AgencyAdoToolSchemas {
    param([Parameter(Mandatory)]$ToolsListResult)
    if ($ToolsListResult -isnot [System.Management.Automation.PSCustomObject]) {
        throw "Agency ADO MCP tools/list returned an unexpected shape."
    }
    $toolsProperty = $ToolsListResult.PSObject.Properties["tools"]
    if ($null -eq $toolsProperty) {
        throw "Agency ADO MCP tools/list omitted tools."
    }
    $tools = @($toolsProperty.Value)
    foreach ($requiredName in @("repo_repository", "repo_pull_request", "repo_pull_request_write", "repo_search_commits")) {
        $matches = @($tools | Where-Object {
            $_ -is [System.Management.Automation.PSCustomObject] -and
            $_.PSObject.Properties["name"] -and
            [string]$_.name -ceq $requiredName
        })
        if ($matches.Count -ne 1) {
            throw "Agency ADO MCP did not expose the required repository tool set."
        }
    }

    foreach ($readName in @("repo_repository", "repo_pull_request", "repo_search_commits")) {
        $readTool = @($tools | Where-Object { [string]$_.name -ceq $readName })[0]
        if (-not $readTool.PSObject.Properties["annotations"] -or
            -not $readTool.annotations.PSObject.Properties["readOnlyHint"] -or
            $readTool.annotations.readOnlyHint -ne $true) {
            throw "Agency ADO MCP did not mark a required read tool as read-only."
        }
    }

    $writeTool = @($tools | Where-Object { [string]$_.name -ceq "repo_pull_request_write" })[0]
    if (-not $writeTool.PSObject.Properties["inputSchema"] -or
        -not $writeTool.inputSchema.PSObject.Properties["properties"] -or
        -not $writeTool.inputSchema.properties.PSObject.Properties["vote"]) {
        throw "Agency ADO MCP vote schema does not support the required vote values."
    }
    $voteProperty = $writeTool.inputSchema.properties.vote
    $voteEnum = @($voteProperty.enum)
    if ($voteEnum -notcontains "Approved" -or $voteEnum -notcontains "WaitingForAuthor") {
        throw "Agency ADO MCP vote schema does not support the required vote values."
    }
}

function New-AgencyAdoMcpSession {
    param(
        [Parameter(Mandatory)][string]$AgencyPath,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')][string]$Organization,
        [ValidateRange(5, 120)][int]$TimeoutSeconds = 30
    )
    $processStartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processStartInfo.FileName = $AgencyPath
    Set-AgencyMcpProcessArguments -ProcessStartInfo $processStartInfo -ArgumentList @(
        "mcp", "ado", "--organization", $Organization, "--toolsets", "repos"
    )
    $processStartInfo.UseShellExecute = $false
    $processStartInfo.RedirectStandardInput = $true
    $processStartInfo.RedirectStandardOutput = $true
    $processStartInfo.RedirectStandardError = $true
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    foreach ($propertyName in @("StandardInputEncoding", "StandardOutputEncoding", "StandardErrorEncoding")) {
        if ($processStartInfo.GetType().GetProperty($propertyName)) {
            $processStartInfo.$propertyName = $utf8
        }
    }
    # Strip credential-shaped variables from the child process. Pattern matching
    # rather than a fixed list, so a consumer's own PAT variable is covered too.
    $sensitivePatterns = @('_PAT$', 'ACCESSTOKEN', '_TOKEN$', 'SECRET', 'PASSWORD', 'APIKEY', 'API_KEY')
    $toRemove = New-Object System.Collections.Generic.List[string]
    foreach ($existing in @($processStartInfo.EnvironmentVariables.Keys)) {
        $name = [string]$existing
        if ($name -eq 'AZURE_DEVOPS_EXT_PAT' -or $name -eq 'SYSTEM_ACCESSTOKEN') { [void]$toRemove.Add($name); continue }
        foreach ($pattern in $sensitivePatterns) {
            if ($name -imatch $pattern) { [void]$toRemove.Add($name); break }
        }
    }
    foreach ($variableName in $toRemove) {
        $processStartInfo.EnvironmentVariables.Remove($variableName)
    }
    $process = [System.Diagnostics.Process]::Start($processStartInfo)
    $session = @{
        Process        = $process
        NextId         = [long]0
        ReadTask       = $null
        ErrorDrainTask = $process.StandardError.ReadToEndAsync()
        TimeoutSeconds = $TimeoutSeconds
        VoteCallCount  = 0
    }
    try {
        $initializeResult = Send-AgencyMcpRequest -Session $session -Method "initialize" -Params @{
            protocolVersion = $script:ReviewerAgencyMcpProtocolVersion
            capabilities    = @{}
            clientInfo      = @{
                name    = $script:ReviewerAgencyMcpClientName
                version = "1.0"
            }
        }
        if ($initializeResult -isnot [System.Management.Automation.PSCustomObject] -or
            -not $initializeResult.PSObject.Properties["protocolVersion"] -or
            [string]$initializeResult.protocolVersion -cne $script:ReviewerAgencyMcpProtocolVersion) {
            throw "Agency ADO MCP negotiated an unsupported protocol version."
        }
        Send-AgencyMcpNotification -Session $session -Method "notifications/initialized"
        $toolsResult = Send-AgencyMcpRequest -Session $session -Method "tools/list" -Params @{}
        Assert-AgencyAdoToolSchemas -ToolsListResult $toolsResult
        return $session
    }
    catch {
        Close-AgencyAdoMcpSession -Session $session -Abort
        throw
    }
}

function Invoke-AgencyAdoTool {
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][ValidateSet("repo_repository", "repo_pull_request", "repo_pull_request_write", "repo_search_commits")][string]$Name,
        [Parameter(Mandatory)][hashtable]$Arguments,
        [Nullable[DateTime]]$DeadlineUtc,
        [switch]$RawText
    )
    $toolResult = Send-AgencyMcpRequest -Session $Session -Method "tools/call" -Params @{
        name      = $Name
        arguments = $Arguments
    } -DeadlineUtc $DeadlineUtc
    if ($toolResult -isnot [System.Management.Automation.PSCustomObject]) {
        throw "Agency ADO MCP tool returned an unexpected result shape."
    }
    if ($toolResult.PSObject.Properties["isError"] -and $toolResult.isError -eq $true) {
        throw "Agency ADO MCP tool reported failure."
    }
    $contentProperty = $toolResult.PSObject.Properties["content"]
    if ($null -eq $contentProperty) {
        throw "Agency ADO MCP tool response omitted content."
    }
    $content = @($contentProperty.Value)
    if ($content.Count -ne 1 -or
        $content[0] -isnot [System.Management.Automation.PSCustomObject] -or
        -not $content[0].PSObject.Properties["type"] -or
        [string]$content[0].type -cne "text" -or
        -not $content[0].PSObject.Properties["text"] -or
        $content[0].text -isnot [string] -or
        $content[0].text.Length -gt 20MB) {
        throw "Agency ADO MCP tool returned invalid content."
    }
    if ($RawText) {
        # Not every ADO MCP action answers with JSON. repo_pull_request_write
        # action=vote confirms with a human-readable sentence
        # ("Successfully cast vote 'Approved' on PR #123."), so JSON-parsing it
        # throws AFTER the vote has already been applied - the caller then
        # cannot tell "vote failed" from "vote succeeded, response unreadable".
        # Returning the validated text lets that caller apply its own strict
        # contract. Every read path keeps the JSON default below unchanged.
        return [string]$content[0].text
    }
    try {
        return ($content[0].text | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        throw "Agency ADO MCP tool returned malformed JSON content."
    }
}

function Get-AgencyAdoRepository {
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$RepositoryName,
        [string]$ExpectedRepositoryId = "",
        [Nullable[DateTime]]$DeadlineUtc
    )
    $repository = Invoke-AgencyAdoTool -Session $Session -Name "repo_repository" -Arguments @{
        action             = "get"
        project            = $Project
        repositoryNameOrId = $RepositoryName
    } -DeadlineUtc $DeadlineUtc
    $repositoryId = Get-AgencyMcpRequiredProperty -Object $repository -Name "id"
    $name = Get-AgencyMcpRequiredProperty -Object $repository -Name "name"
    $projectReference = Get-AgencyMcpRequiredProperty -Object $repository -Name "projectReference"
    $projectName = Get-AgencyMcpRequiredProperty -Object $projectReference -Name "name"
    if (-not (Test-AgencyMcpGuid -Value ([string]$repositoryId)) -or
        [string]$name -cne $RepositoryName -or
        [string]$projectName -cne $Project) {
        throw "Agency ADO MCP repository response did not match the configured scope."
    }
    if ($ExpectedRepositoryId -and [string]$repositoryId -cne $ExpectedRepositoryId) {
        throw "Agency ADO MCP repository '$RepositoryName' resolved to repositoryId '$repositoryId', which does not match the configured expected repository.id '$ExpectedRepositoryId'."
    }
    return @{
        repositoryId = [string]$repositoryId
        name         = [string]$name
        project      = [string]$projectName
    }
}

function ConvertTo-AgencyAdoPullRequestSnapshot {
    param(
        [Parameter(Mandatory)]$PullRequest,
        [Parameter(Mandatory)][string]$ExpectedProject,
        [Parameter(Mandatory)][string]$ExpectedRepositoryId
    )
    $prId = Get-AgencyMcpRequiredProperty -Object $PullRequest -Name "pullRequestId"
    $repository = Get-AgencyMcpRequiredProperty -Object $PullRequest -Name "repository"
    $repositoryId = Get-AgencyMcpRequiredProperty -Object $repository -Name "id"
    $projectReference = Get-AgencyMcpRequiredProperty -Object $repository -Name "projectReference"
    $projectName = Get-AgencyMcpRequiredProperty -Object $projectReference -Name "name"
    $status = Get-AgencyMcpRequiredProperty -Object $PullRequest -Name "status"
    $isDraft = Get-AgencyMcpRequiredProperty -Object $PullRequest -Name "isDraft"
    $targetRefName = Get-AgencyMcpRequiredProperty -Object $PullRequest -Name "targetRefName"
    $sourceCommit = Get-AgencyMcpRequiredProperty -Object $PullRequest -Name "lastMergeSourceCommit"
    $sourceCommitId = Get-AgencyMcpRequiredProperty -Object $sourceCommit -Name "commitId"
    $title = Get-AgencyMcpRequiredProperty -Object $PullRequest -Name "title"
    $authorAlias = $null
    # The exact ADO createdBy.uniqueName (UPN) is captured here - at the same
    # trusted MCP read used for every other candidate field - so it survives
    # selection/rebinding unchanged. It is never sourced from model output;
    # Teams direct-author-message resolution (WorkIQ /users/{uniqueName})
    # reads ONLY this wrapper-owned value.
    $authorUniqueName = $null
    $createdByProperty = $PullRequest.PSObject.Properties["createdBy"]
    if ($createdByProperty -and $null -ne $createdByProperty.Value) {
        $authorUniqueNameProperty = $createdByProperty.Value.PSObject.Properties["uniqueName"]
        if ($authorUniqueNameProperty -and $authorUniqueNameProperty.Value -is [string]) {
            $rawUniqueName = $authorUniqueNameProperty.Value.Trim()
            if ($rawUniqueName -and $rawUniqueName.Length -le 320 -and $rawUniqueName -match '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
                $authorUniqueName = $rawUniqueName
            }
            $authorAlias = ConvertTo-AgencyAdoAuthorAlias -UniqueName $authorUniqueNameProperty.Value
        }
    }
    $descriptionProperty = $PullRequest.PSObject.Properties["description"]
    $description = if ($descriptionProperty -and $null -ne $descriptionProperty.Value) {
        [string]$descriptionProperty.Value
    }
    else {
        ""
    }
    $reviewersProperty = $PullRequest.PSObject.Properties["reviewers"]
    $reviewers = if ($reviewersProperty -and $null -ne $reviewersProperty.Value) {
        @($reviewersProperty.Value)
    }
    else {
        @()
    }

    if (-not (Test-AgencyMcpStrictInt -Value $prId -Min 1 -Max ([int]::MaxValue)) -or
        -not (Test-AgencyMcpGuid -Value ([string]$repositoryId)) -or
        [string]$repositoryId -cne $ExpectedRepositoryId -or
        [string]$projectName -cne $ExpectedProject -or
        $status -isnot [string] -or
        @("Active", "Abandoned", "Completed", "NotSet") -cnotcontains [string]$status -or
        $isDraft -isnot [bool] -or
        $targetRefName -isnot [string] -or
        $sourceCommitId -isnot [string] -or
        $sourceCommitId -notmatch $script:ReviewerAgentCommitIdPattern -or
        $title -isnot [string] -or
        $title.Length -gt 4000 -or
        $description.Length -gt 1MB) {
        throw "Agency ADO MCP pull-request response failed validation."
    }

    $validatedReviewers = @()
    foreach ($reviewer in $reviewers) {
        if ($reviewer -isnot [System.Management.Automation.PSCustomObject]) { continue }
        $idProperty = $reviewer.PSObject.Properties["id"]
        $voteProperty = $reviewer.PSObject.Properties["vote"]
        if (-not $idProperty -or -not (Test-AgencyMcpGuid -Value ([string]$idProperty.Value))) { continue }
        if (-not $voteProperty -or -not (Test-AgencyMcpStrictInt -Value $voteProperty.Value -Min -10 -Max 10)) { continue }
        # Group/team reviewers matter for vote attribution: when an individual
        # votes, ADO also reflects that vote on the aggregated container entry.
        # Tracking isContainer lets vote verification look at real people only.
        $isContainerProperty = $reviewer.PSObject.Properties["isContainer"]
        $validatedReviewers += @{
            id          = [string]$idProperty.Value
            vote        = [int]$voteProperty.Value
            isContainer = [bool]($isContainerProperty -and $isContainerProperty.Value -is [bool] -and $isContainerProperty.Value)
        }
    }

    return @{
        prId             = [int]$prId
        repositoryId     = [string]$repositoryId
        project          = [string]$projectName
        status           = [string]$status
        isDraft          = [bool]$isDraft
        targetRefName    = [string]$targetRefName
        sourceCommitId   = [string]$sourceCommitId
        authorAlias      = $authorAlias
        authorUniqueName = $authorUniqueName
        title            = [string]$title
        description      = $description
        reviewers        = $validatedReviewers
    }
}

function Get-AgencyAdoPullRequestSnapshot {
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][int]$PullRequestId,
        [Nullable[DateTime]]$DeadlineUtc
    )
    if (-not (Test-AgencyMcpGuid -Value $RepositoryId) -or $PullRequestId -le 0) {
        throw "Invalid pull-request scope."
    }
    $pullRequest = Invoke-AgencyAdoTool -Session $Session -Name "repo_pull_request" -Arguments @{
        action        = "get"
        project       = $Project
        repositoryId  = $RepositoryId
        pullRequestId = $PullRequestId
    } -DeadlineUtc $DeadlineUtc
    return ConvertTo-AgencyAdoPullRequestSnapshot -PullRequest $pullRequest `
        -ExpectedProject $Project -ExpectedRepositoryId $RepositoryId
}

function Get-AgencyAdoActivePullRequestIds {
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][string]$TargetRefName,
        [AllowEmptyCollection()][string[]]$AuthorAliases = @(),
        [Nullable[DateTime]]$DeadlineUtc
    )
    $ids = New-Object System.Collections.Generic.HashSet[int]
    $pageSize = 100
    for ($page = 0; $page -lt 100; $page++) {
        $payload = Invoke-AgencyAdoTool -Session $Session -Name "repo_pull_request" -Arguments @{
            action        = "list"
            project       = $Project
            repositoryId  = $RepositoryId
            status        = "Active"
            targetRefName = $TargetRefName
            top           = $pageSize
            skip          = $page * $pageSize
        } -DeadlineUtc $DeadlineUtc
        $entries = if ($null -eq $payload) { @() } else { @($payload) }
        foreach ($entry in $entries) {
            $prId = Get-AgencyMcpRequiredProperty -Object $entry -Name "pullRequestId"
            $status = Get-AgencyMcpRequiredProperty -Object $entry -Name "status"
            $isDraft = Get-AgencyMcpRequiredProperty -Object $entry -Name "isDraft"
            $target = Get-AgencyMcpRequiredProperty -Object $entry -Name "targetRefName"
            $authorAlias = $null
            if (@($AuthorAliases).Count -gt 0) {
                $createdBy = Get-AgencyMcpRequiredProperty -Object $entry -Name "createdBy"
                $authorUniqueName = Get-AgencyMcpRequiredProperty -Object $createdBy -Name "uniqueName"
                if ($authorUniqueName -isnot [string]) {
                    throw "Agency ADO MCP pull-request list author failed validation."
                }
                $authorAlias = ConvertTo-AgencyAdoAuthorAlias -UniqueName $authorUniqueName
            }
            if (-not (Test-AgencyMcpStrictInt -Value $prId -Min 1 -Max ([int]::MaxValue)) -or
                [string]$status -cne "Active" -or
                $isDraft -isnot [bool] -or
                [string]$target -cne $TargetRefName) {
                throw "Agency ADO MCP pull-request list failed validation."
            }
            if (-not $isDraft -and
                (@($AuthorAliases).Count -eq 0 -or $AuthorAliases -ccontains $authorAlias)) {
                [void]$ids.Add([int]$prId)
            }
        }
        if (@($entries).Count -lt $pageSize) {
            return @($ids | Sort-Object)
        }
    }
    throw "Agency ADO MCP pull-request listing exceeded the safety page limit."
}

function Get-AgencyAdoSourceCommitDateUtc {
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][string]$SourceCommitId,
        [Nullable[DateTime]]$DeadlineUtc
    )
    if (-not (Test-AgencyMcpGuid -Value $RepositoryId) -or
        $SourceCommitId -notmatch $script:ReviewerAgentCommitIdPattern) {
        throw "Invalid source-commit scope."
    }
    $payload = Invoke-AgencyAdoTool -Session $Session -Name "repo_search_commits" -Arguments @{
        project          = $Project
        repository       = $RepositoryId
        commitIds        = @($SourceCommitId)
        top              = 1
        includeLinks     = $false
        includeWorkItems = $false
    } -DeadlineUtc $DeadlineUtc
    $commits = if ($null -eq $payload) { @() } else { @($payload) }
    if (@($commits).Count -ne 1) {
        throw "Agency ADO MCP did not return exactly one source commit."
    }
    $commitId = Get-AgencyMcpRequiredProperty -Object $commits[0] -Name "commitId"
    $committer = Get-AgencyMcpRequiredProperty -Object $commits[0] -Name "committer"
    $committerDate = Get-AgencyMcpRequiredProperty -Object $committer -Name "date"
    if ([string]$commitId -cne $SourceCommitId) {
        throw "Agency ADO MCP source-commit response did not match the requested commit."
    }
    return ConvertTo-AgencyAdoUtcDateTime -Value $committerDate
}

function Test-AgencyAdoNotReadyText {
    <#
        Only scans the PR title, not the free-form description: the
        description is untrusted author-controlled text (validated only for
        length) and can legitimately quote one of these tokens, e.g. a
        checklist line "Blocking items [NOT READY]: none", which would
        otherwise cause a silent false skip. isDraft is already checked
        separately by the caller.
    #>
    param([string]$Title, [string]$Description)
    return [bool](
        $Title -match '(?i)\[(WIP|DRAFT|DO NOT MERGE|NOT READY)\]' -or
        $Title -match '(?i)^\s*Draft:'
    )
}

function Test-ReviewedAtSourceCommit {
    param(
        [hashtable]$ReviewedState,
        [int]$PullRequestId,
        [string]$SourceCommit
    )
    if (-not $ReviewedState.ContainsKey("$PullRequestId")) { return $false }
    $record = $ReviewedState["$PullRequestId"]
    if ($null -eq $record -or $record -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    $sourceProperty = $record.PSObject.Properties["sourceCommit"]
    return [bool]($sourceProperty -and $sourceProperty.Value -is [string] -and
        [string]$sourceProperty.Value -ceq $SourceCommit)
}

function Select-DeterministicPullRequestCandidate {
    <#
        $StarvedCandidateKeys (optional) holds "prId:sourceCommit" strings for
        candidates that failed too many consecutive review attempts at their
        exact current source commit. Skipping them here (rather than writing
        reviewed.json) advances selection past a reproducibly-failing PR
        without ever recording it as reviewed  -  a fresh push (new source
        commit) produces a different key and is eligible again immediately.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Snapshots,
        [Parameter(Mandatory)][hashtable]$ReviewedState,
        [Parameter(Mandatory)][string]$ExpectedTargetRefName,
        [AllowEmptyCollection()][string[]]$AuthorAliases = @(),
        [Nullable[DateTime]]$SourceCommitAfterUtc,
        [AllowNull()][System.Collections.Generic.HashSet[string]]$StarvedCandidateKeys = $null
    )
    foreach ($snapshot in @($Snapshots | Sort-Object { $_.prId })) {
        $candidateKey = "$($snapshot.prId):$($snapshot.sourceCommitId)"
        if ([string]$snapshot.status -cne "Active" -or
            [bool]$snapshot.isDraft -or
            [string]$snapshot.targetRefName -cne $ExpectedTargetRefName -or
        ($null -ne $SourceCommitAfterUtc -and [DateTime]$snapshot.sourceCommitDateUtc -lt [DateTime]$SourceCommitAfterUtc) -or
        (@($AuthorAliases).Count -gt 0 -and $AuthorAliases -cnotcontains [string]$snapshot.authorAlias) -or
        (Test-AgencyAdoNotReadyText -Title ([string]$snapshot.title) -Description ([string]$snapshot.description)) -or
        (Test-ReviewedAtSourceCommit -ReviewedState $ReviewedState -PullRequestId ([int]$snapshot.prId) -SourceCommit ([string]$snapshot.sourceCommitId)) -or
        ($null -ne $StarvedCandidateKeys -and $StarvedCandidateKeys.Contains($candidateKey))) {
            continue
        }
        return $snapshot
    }
    return $null
}

function Get-AgencyAdoDeterministicCandidate {
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$RepositoryName,
        [string]$ExpectedRepositoryId = "",
        [Parameter(Mandatory)][string]$ExpectedTargetRefName,
        [Parameter(Mandatory)][hashtable]$ReviewedState,
        [AllowEmptyCollection()][string[]]$AuthorAliases = @(),
        [Nullable[DateTime]]$SourceCommitAfterUtc,
        [Parameter(Mandatory)][DateTime]$DeadlineUtc,
        [AllowNull()][System.Collections.Generic.HashSet[string]]$StarvedCandidateKeys = $null
    )
    if ([DateTime]::UtcNow -ge $DeadlineUtc) {
        throw "Agency ADO deterministic candidate selection exceeded its aggregate deadline."
    }
    $repository = Get-AgencyAdoRepository -Session $Session -Project $Project `
        -RepositoryName $RepositoryName -ExpectedRepositoryId $ExpectedRepositoryId -DeadlineUtc $DeadlineUtc
    $pullRequestIds = @(Get-AgencyAdoActivePullRequestIds -Session $Session -Project $Project `
        -RepositoryId $repository.repositoryId -TargetRefName $ExpectedTargetRefName `
        -AuthorAliases $AuthorAliases -DeadlineUtc $DeadlineUtc)
    foreach ($pullRequestId in @($pullRequestIds | Sort-Object)) {
        if ([DateTime]::UtcNow -ge $DeadlineUtc) {
            throw "Agency ADO deterministic candidate selection exceeded its aggregate deadline."
        }
        $snapshot = Get-AgencyAdoPullRequestSnapshot -Session $Session -Project $Project `
            -RepositoryId $repository.repositoryId -PullRequestId $pullRequestId `
            -DeadlineUtc $DeadlineUtc
        # Apply every DATE-INDEPENDENT rejection before paying for a second
        # round trip. An already-reviewed, starved, draft, wrong-target,
        # wrong-author or not-ready PR needs no commit date at all, and on a
        # busy repo the ascending already-reviewed prefix grows every cycle -
        # paying two round trips per skipped PR is what exhausted the
        # selection budget. Passing -SourceCommitAfterUtc $null reuses the
        # exact same predicate rather than duplicating it here, so the two
        # call sites cannot drift apart.
        if (-not (Select-DeterministicPullRequestCandidate -Snapshots @($snapshot) `
                    -ReviewedState $ReviewedState -ExpectedTargetRefName $ExpectedTargetRefName `
                    -AuthorAliases $AuthorAliases -SourceCommitAfterUtc $null `
                    -StarvedCandidateKeys $StarvedCandidateKeys)) {
            continue
        }
        $snapshot.sourceCommitDateUtc = Get-AgencyAdoSourceCommitDateUtc -Session $Session `
            -Project $Project -RepositoryId $repository.repositoryId `
            -SourceCommitId $snapshot.sourceCommitId -DeadlineUtc $DeadlineUtc
        if ([DateTime]$snapshot.sourceCommitDateUtc -gt [DateTime]::UtcNow.AddMinutes($script:ReviewerAgentFutureCommitToleranceMinutes)) {
            continue
        }
        $candidate = Select-DeterministicPullRequestCandidate -Snapshots @($snapshot) `
            -ReviewedState $ReviewedState -ExpectedTargetRefName $ExpectedTargetRefName `
            -AuthorAliases $AuthorAliases -SourceCommitAfterUtc $SourceCommitAfterUtc `
            -StarvedCandidateKeys $StarvedCandidateKeys
        if ($candidate) { return $candidate }
    }
    return $null
}

function Test-AgencyAdoFreshBinding {
    param(
        [Parameter(Mandatory)][hashtable]$Snapshot,
        [Parameter(Mandatory)][hashtable]$Candidate,
        [Parameter(Mandatory)][string]$ExpectedTargetRefName
    )
    if ($Snapshot.prId -ne $Candidate.prId -or
        [string]$Snapshot.repositoryId -cne [string]$Candidate.repositoryId -or
        [string]$Snapshot.project -cne [string]$Candidate.project -or
        [string]$Snapshot.status -cne "Active" -or
        [bool]$Snapshot.isDraft -or
        [string]$Snapshot.targetRefName -cne $ExpectedTargetRefName -or
        [string]$Snapshot.sourceCommitId -cne [string]$Candidate.sourceCommitId -or
        [string]$Snapshot.authorAlias -cne [string]$Candidate.authorAlias -or
        [string]$Snapshot.authorUniqueName -cne [string]$Candidate.authorUniqueName) {
        return @{ ok = $false; reason = "fresh PR state no longer matches the exact reviewed candidate" }
    }
    return @{ ok = $true; reason = "fresh PR state matches the exact reviewed candidate" }
}

function New-AgencyAdoVoteToolArguments {
    param(
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][int]$PullRequestId,
        [Parameter(Mandatory)][ValidateSet("Approved", "WaitingForAuthor")][string]$Vote
    )
    if (-not (Test-AgencyMcpGuid -Value $RepositoryId) -or $PullRequestId -le 0) {
        throw "Invalid pull-request vote scope."
    }
    return [ordered]@{
        action        = "vote"
        project       = $Project
        repositoryId  = $RepositoryId
        pullRequestId = $PullRequestId
        vote          = $Vote
    }
}

function Resolve-AgencyAdoVotedReviewerId {
    <#
        The ADO MCP vote action confirms in prose and returns NO reviewer
        identity, and this toolset (repos) exposes no "who am I" call. The
        signed-in reviewer is therefore identified by diffing the PR's
        INDIVIDUAL reviewers around the vote: exactly one identity must have
        moved TO the expected vote value.

        Container/group reviewers are excluded because ADO also reflects an
        individual's vote on the aggregated team entry - counting those would
        always yield two "changed" identities and never verify.

        When nothing changed (an idempotent re-vote of the same value, e.g.
        after a previous cycle cast the vote but failed to record it) exactly
        one individual must already hold the expected value. Anything else -
        zero matches, or two people at the same value with no distinguishing
        change - is genuinely ambiguous and fails closed by returning $null.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Before,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$After,
        [Parameter(Mandatory)][int]$ExpectedVoteValue
    )
    $beforeVotes = @{}
    foreach ($reviewer in $Before) {
        if ([bool]$reviewer.isContainer) { continue }
        $beforeVotes[[string]$reviewer.id] = [int]$reviewer.vote
    }
    $individualsNowExpected = @($After | Where-Object {
            -not [bool]$_.isContainer -and [int]$_.vote -eq $ExpectedVoteValue
        })
    $changedToExpected = @($individualsNowExpected | Where-Object {
            (-not $beforeVotes.ContainsKey([string]$_.id)) -or
            $beforeVotes[[string]$_.id] -ne $ExpectedVoteValue
        })
    if ($changedToExpected.Count -eq 1) { return [string]$changedToExpected[0].id }
    if ($changedToExpected.Count -eq 0 -and $individualsNowExpected.Count -eq 1) {
        return [string]$individualsNowExpected[0].id
    }
    return $null
}

function Set-AgencyAdoPullRequestVote {
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][int]$PullRequestId,
        [Parameter(Mandatory)][ValidateSet("Approved", "WaitingForAuthor")][string]$Vote
    )
    if ([int]$Session.VoteCallCount -ne 0) {
        throw "The wrapper permits exactly one sign-off vote call per review cycle."
    }
    $Session.VoteCallCount = 1
    $expectedVoteValue = if ($Vote -ceq "Approved") { 10 } else { -5 }

    # Captured BEFORE the write so the reviewer identity can be attributed
    # from the resulting change (the vote response carries no identity).
    $beforeSnapshot = Get-AgencyAdoPullRequestSnapshot -Session $Session -Project $Project `
        -RepositoryId $RepositoryId -PullRequestId $PullRequestId

    $arguments = New-AgencyAdoVoteToolArguments -Project $Project -RepositoryId $RepositoryId `
        -PullRequestId $PullRequestId -Vote $Vote
    $confirmation = Invoke-AgencyAdoTool -Session $Session -Name "repo_pull_request_write" `
        -Arguments $arguments -RawText

    # The vote action answers with a sentence, not JSON. Bind that sentence to
    # THIS exact PR and vote; the authoritative proof is the fresh read below.
    if ([string]::IsNullOrWhiteSpace($confirmation) -or
        $confirmation.Length -gt 2000 -or
        $confirmation -notmatch '(?i)success' -or
        $confirmation -notmatch "(?<![0-9])$PullRequestId(?![0-9])" -or
        $confirmation -cnotmatch [regex]::Escape($Vote)) {
        throw "Agency ADO MCP vote response did not confirm the requested vote for this exact pull request."
    }

    $verifiedSnapshot = Get-AgencyAdoPullRequestSnapshot -Session $Session -Project $Project `
        -RepositoryId $RepositoryId -PullRequestId $PullRequestId
    $reviewerId = Resolve-AgencyAdoVotedReviewerId -Before @($beforeSnapshot.reviewers) `
        -After @($verifiedSnapshot.reviewers) -ExpectedVoteValue $expectedVoteValue
    if (-not $reviewerId -or -not (Test-AgencyMcpGuid -Value ([string]$reviewerId))) {
        throw "Agency ADO MCP vote could not be attributed to exactly one individual reviewer by a fresh PR read."
    }
    return @{
        vote       = $Vote
        reviewerId = [string]$reviewerId
    }
}

function Test-TrackedApprovedVotesSafe {
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][hashtable]$VotesState,
        [Parameter(Mandatory)][string]$ExpectedProject
    )
    $clearedPrIds = New-Object System.Collections.Generic.List[string]
    foreach ($key in @($VotesState.Keys)) {
        $record = $VotesState[$key]
        if ($record -isnot [System.Management.Automation.PSCustomObject]) {
            return @{ ok = $false; reason = "approved-vote state contains an invalid record"; clearedPrIds = @() }
        }
        $stateProperty = $record.PSObject.Properties["state"]
        if ($stateProperty) {
            if ([string]$stateProperty.Value -ceq "pending") {
                return @{ ok = $false; reason = "a prior vote has an uncertain pending outcome; verify it in ADO before sign-off"; clearedPrIds = @() }
            }
            if ([string]$stateProperty.Value -cne "confirmed") {
                return @{ ok = $false; reason = "approved-vote state contains an unknown lifecycle value"; clearedPrIds = @() }
            }
        }
        $voteProperty = $record.PSObject.Properties["vote"]
        if (-not $voteProperty -or [string]$voteProperty.Value -cne "Approved") { continue }
        foreach ($requiredName in @("project", "repositoryId", "prId")) {
            if (-not $record.PSObject.Properties[$requiredName]) {
                return @{ ok = $false; reason = "approved-vote state is incomplete"; clearedPrIds = @() }
            }
        }
        $sourceProperty = if ($record.PSObject.Properties["approvedSourceCommit"]) {
            $record.PSObject.Properties["approvedSourceCommit"]
        }
        else {
            $record.PSObject.Properties["sourceCommit"]
        }
        if (-not $sourceProperty -or
            [string]$record.project -cne $ExpectedProject -or
            -not (Test-AgencyMcpGuid -Value ([string]$record.repositoryId)) -or
            -not (Test-AgencyMcpStrictInt -Value $record.prId -Min 1 -Max ([int]::MaxValue)) -or
            [string]$sourceProperty.Value -notmatch $script:ReviewerAgentCommitIdPattern) {
            return @{ ok = $false; reason = "approved-vote state failed validation"; clearedPrIds = @() }
        }

        $snapshot = Get-AgencyAdoPullRequestSnapshot -Session $Session -Project ([string]$record.project) `
            -RepositoryId ([string]$record.repositoryId) -PullRequestId ([int]$record.prId)
        if ([string]$snapshot.status -cne "Active") {
            $clearedPrIds.Add([string]$record.prId)
            continue
        }
        if ([string]$snapshot.sourceCommitId -ceq [string]$sourceProperty.Value) { continue }

        $reviewerIdProperty = $record.PSObject.Properties["reviewerId"]
        if (-not $reviewerIdProperty -or -not (Test-AgencyMcpGuid -Value ([string]$reviewerIdProperty.Value))) {
            return @{
                ok           = $false
                reason       = "a tracked approval is stale and the repos MCP toolset cannot prove the current signed-in identity; verify/reset the vote manually"
                clearedPrIds = @()
            }
        }
        $matchingReviewer = @($snapshot.reviewers | Where-Object {
            [string]$_.id -ceq [string]$reviewerIdProperty.Value
        })
        if ($matchingReviewer.Count -eq 0) {
            # An absent reviewer entry is not proof that ADO reset the vote -
            # a missing "reviewers" field or a dropped invalid entry in
            # ConvertTo-AgencyAdoPullRequestSnapshot also yields Count 0.
            # Fail closed exactly like the missing-reviewerId branch above.
            return @{
                ok           = $false
                reason       = "a tracked reviewer entry is absent from a fresh PR read, which does not prove ADO reset the vote; verify/reset the vote manually"
                clearedPrIds = @()
            }
        }
        if ([int]$matchingReviewer[0].vote -ne 10) {
            # A reviewer entry is positively present with a different vote:
            # this is actual proof of a reset, safe to clear.
            $clearedPrIds.Add([string]$record.prId)
            continue
        }
        return @{
            ok           = $false
            reason       = "a tracked Approved vote remains on an older source commit; verify ADO reset-on-push policy and clear it before sign-off"
            clearedPrIds = @()
        }
    }
    return @{ ok = $true; reason = "tracked approvals are current or already reset"; clearedPrIds = @($clearedPrIds) }
}
