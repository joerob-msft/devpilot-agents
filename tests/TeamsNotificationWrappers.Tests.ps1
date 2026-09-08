BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1" -Force
}

Describe '<Role> Teams notification integration' -ForEach @(
    @{ Role = 'reviewer'; ScriptName = 'Start-ReviewerAgent.ps1'; NotificationFunction = 'Send-ReviewerTeamsNotification'; HashFunction = 'Get-ReviewerHashValue'; LinkFunction = 'Get-ReviewerPullRequestLink'; EventParameter = 'NotificationEvent'; NotificationEvent = 'reviewCompleted' }
    @{ Role = 'review-handler'; ScriptName = 'Start-ReviewHandlerAgent.ps1'; NotificationFunction = 'Send-HandlerTeamsNotification'; HashFunction = 'Get-HandlerHashValue'; LinkFunction = 'Get-HandlerPullRequestLink'; EventParameter = 'Event'; NotificationEvent = 'prReadyToComplete' }
) {
    BeforeAll {
        $tokens = $null
        $parseErrors = $null
        $path = (Resolve-Path "$PSScriptRoot\..\src\Agents\$Role\$ScriptName").Path
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count) { throw "Agent script contains parse errors: $parseErrors" }
        $threadFlagAssignment = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
                $node.Left.VariablePath.UserPath -eq 'TeamsThreadReuseEnabled'
        }, $true)
        if (-not $threadFlagAssignment) { throw 'Missing threading flag configuration assignment' }
        $script:threadFlagConfig = [scriptblock]::Create($threadFlagAssignment.Extent.Text)
        $referenceFlagAssignment = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
                $node.Left.VariablePath.UserPath -eq 'TeamsPrReferenceEnabled'
        }, $true)
        $script:referenceFlagConfig = [scriptblock]::Create($referenceFlagAssignment.Extent.Text)
        $functionsToLoad = @($NotificationFunction, $HashFunction, $LinkFunction)
        if ($Role -eq 'review-handler') { $functionsToLoad += 'Get-HandlerTeamsNotificationSourceCommit' }
        foreach ($name in $functionsToLoad) {
            $definition = $ast.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $true)
            if (-not $definition) { throw "Missing function $name" }
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        $script:notificationRole = $Role
        $script:notificationFunction = $NotificationFunction
        $script:eventParameter = $EventParameter
        $script:notificationEvent = $NotificationEvent
        $script:notificationAgentPath = $path

        function Invoke-TestNotification {
            param(
                [int]$PrId = 42, [AllowEmptyString()][string]$Commit = 'abc123', [string[]]$Links = @(),
                [string]$SourceRefName = '', [string]$ExpectedSourceCommit = '', [string]$EventOverride = ''
            )
            $parameters = @{
                AgencyPath = 'unused-agency'; Title = 'Synthetic notification'; Body = 'Synthetic body'
                PrId = $PrId; SourceCommit = $Commit; Links = $Links
            }
            $parameters[$script:eventParameter] = if ($EventOverride) { $EventOverride } else { $script:notificationEvent }
            if ($SourceRefName) {
                $parameters.SourceRefName = $SourceRefName
                $parameters.ExpectedSourceCommit = $ExpectedSourceCommit
            }
            & $script:notificationFunction @parameters
        }
    }

    BeforeEach {
        $script:EnableTeamsNotifications = $true
        $script:EnableTeamsPrReferenceWrites = $false
        $script:PreviewOnly = $false
        $script:ManualDispatchManifest = ''
        $script:PullRequestId = 42
        $script:ReviewerTeamsManualAuthorized = $false
        $script:HandlerTeamsManualAuthorized = $false
        $script:TeamsPrReferenceEnabled = $false
        $script:ReviewerTeamsAdoSession = $null
        $script:HandlerTeamsAdoSession = $null
        $script:McpSensitiveEnvironmentVariables = @()
        $script:TeamsThreadReuseEnabled = $true
        $script:TeamsChannelEnabled = $true
        $script:TeamsChannelEvents = @($script:notificationEvent)
        $script:TeamsTeamId = 'synthetic-team'
        $script:TeamsChannelId = 'synthetic-channel'
        $script:TeamsDirectEnabled = $false
        $script:TeamsDirectEvents = @($script:notificationEvent)
        $script:TeamsDirectRecipientFallback = 'author@example.test'
        $script:TeamsDirectRecipient = 'author@example.test'
        $script:Organization = 'example-org'
        $script:ExpectedProject = 'ExampleProject'
        $script:RepositoryName = 'example-repository'
        $script:notificationsStatePath = Join-Path $TestDrive 'notifications.json'
        $script:DurableStateRoot = Join-Path $TestDrive 'durable'
        $script:repositoryIdentity = @{
            verified = $true; key = 'v1:github:12345'; project = 'verified-project-id'
            repositoryId = 'verified-repository-id'
        }
        $script:ReviewerOutputContext = @{ Agent = 'reviewer' }
        $script:HandlerOutputContext = @{ Agent = 'review-handler' }
        $script:notificationState = @{}
        $script:threadResult = @{ Delivered = $true; Deduped = $false; Outcome = 'root-created'; Code = 'created' }
        Mock Open-AgentMcpSession { return @{ Synthetic = $true } }
        Mock Close-AgentMcpSession {}
        Mock Get-JsonState { return $script:notificationState }
        Mock Set-JsonState { param($State) $script:notificationState = $State }
        Mock Send-AgentTeamsThreadedChannelMessage { return $script:threadResult }
        Mock New-AgentTeamsPrReferenceContext { param($AdoSession, $AllowWrites) return @{ AdoSession = $AdoSession; AllowWrites = [bool]$AllowWrites } }
        Mock Invoke-AgentMcpTool { throw 'Unexpected MCP transport call' }
        Mock Test-AgentManualCancellationRequested { $false }
        Mock Send-AgentTeamsChannelMessage { return @{ id = 'independent-message' } }
        Mock Send-AgentTeamsDirectMessage { return @{ id = 'direct-message' } }
        Mock Publish-AgentEvent {} -RemoveParameterValidation EventType
        Mock Write-Host {}
        Mock Write-Warning {}
    }

    It 'defaults an omitted threading property to true without enabling notifications' {
        $teamsChannelCfg = [pscustomobject]@{ enabled = $false }
        . $script:threadFlagConfig
        $TeamsThreadReuseEnabled | Should -BeTrue
        $teamsChannelCfg.enabled | Should -BeFalse
    }

    It 'defaults omitted shared references off and validates explicit boolean values' {
        $teamsChannelCfg = [pscustomobject]@{}
        . $script:referenceFlagConfig
        $TeamsPrReferenceEnabled | Should -BeFalse
        foreach ($flag in @($false, $true)) {
            $teamsChannelCfg = [pscustomobject]@{ prReferenceEnabled = $flag }
            . $script:referenceFlagConfig
            $TeamsPrReferenceEnabled | Should -Be $flag
        }
        foreach ($invalid in @('true', 1, $null, @($true))) {
            $teamsChannelCfg = [pscustomobject]@{ prReferenceEnabled = $invalid }
            { . $script:referenceFlagConfig } | Should -Throw '*must be a JSON boolean*'
        }
    }

    It 'honors an explicit JSON boolean <Flag>' -ForEach @(@{ Flag = $false }, @{ Flag = $true }) {
        $teamsChannelCfg = [pscustomobject]@{ threadReuseEnabled = $Flag }
        . $script:threadFlagConfig
        $TeamsThreadReuseEnabled | Should -Be $Flag
    }

    It 'rejects an explicitly invalid threading value <Label>' -ForEach @(
        @{ Label = 'string'; Value = 'true' }
        @{ Label = 'number'; Value = 1 }
        @{ Label = 'null'; Value = $null }
        @{ Label = 'singleton array'; Value = @($true) }
    ) {
        $teamsChannelCfg = [pscustomobject]@{ threadReuseEnabled = $Value }
        { . $script:threadFlagConfig } | Should -Throw '*must be a JSON boolean*'
    }

    It 'starts an unchanged consumer configuration with <Mode> notifications' -ForEach @(
        @{ Mode = 'disabled' }, @{ Mode = 'direct-only' }
    ) {
        $sample = if ($script:notificationRole -eq 'reviewer') { 'reviewer-ado.config.json' } else { 'handler-ado.config.json' }
        $config = Get-Content -LiteralPath "$PSScriptRoot\..\samples\$sample" -Raw | ConvertFrom-Json
        $config.teamsNotifications.channel.PSObject.Properties.Remove('threadReuseEnabled')
        $config.teamsNotifications.channel.enabled = $false
        $config.teamsNotifications.directAuthor.enabled = $Mode -eq 'direct-only'
        $config.teamsNotifications.directAuthor.recipientUpn = 'author@example.test'
        $configPath = Join-Path $TestDrive "$script:notificationRole-$Mode.config.json"
        $config | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $configPath -Encoding utf8
        $childArguments = @('-NoProfile', '-File', $script:notificationAgentPath, '-DryRun', '-OutputMode', 'Json',
            '-ConfigFile', $configPath, '-RepoPath', (Resolve-Path "$PSScriptRoot\..").Path)
        if ($Mode -eq 'direct-only') { $childArguments += '-EnableTeamsNotifications' }
        $lines = @(& pwsh @childArguments)
        $LASTEXITCODE | Should -Be 0
        $events = @($lines | ForEach-Object { $_ | ConvertFrom-Json })
        $events[0].eventType | Should -Be 'agent.started'
        $events[-1].eventType | Should -Be 'agent.stopped'
        @($events | Where-Object { $_.eventType -eq 'work.completed' -and $_.data.result -eq 'failed' }).Count | Should -Be 0
    }

    It 'passes the verified repository, role, destination and durable root to shared threading' {
        Invoke-TestNotification
        Should -Invoke Send-AgentTeamsThreadedChannelMessage -Times 1 -Exactly -ParameterFilter {
            $RepositoryIdentity.verified -eq $true -and $Role -eq $script:notificationRole -and
            $PullRequestId -eq 42 -and $SourceCommit -eq 'abc123' -and
            $PullRequestUrl -eq 'https://dev.azure.com/example-org/ExampleProject/_git/example-repository/pullrequest/42' -and
            $TeamId -eq 'synthetic-team' -and $ChannelId -eq 'synthetic-channel' -and
            $DurableStateRoot -eq $script:DurableStateRoot -and $null -ne $OutputContext
        }
        Should -Invoke Send-AgentTeamsChannelMessage -Times 0
        Should -Invoke Set-JsonState -Times 1
        Should -Invoke Close-AgentMcpSession -Times 1
    }

    It 'builds PR routing identity from trusted config rather than caller-supplied links' {
        Invoke-TestNotification -Links @('https://example.test/unrelated/pull/42')
        Should -Invoke Send-AgentTeamsThreadedChannelMessage -Times 1 -Exactly -ParameterFilter {
            $PullRequestUrl -eq 'https://dev.azure.com/example-org/ExampleProject/_git/example-repository/pullrequest/42'
        }
    }

    It 'escapes every trusted PR URL component including valid project spaces' {
        $script:Organization = 'example org'
        $script:ExpectedProject = 'Example Project'
        $script:RepositoryName = 'example repo#1'
        Invoke-TestNotification -Links @('https://example.test/fake')
        Should -Invoke Send-AgentTeamsThreadedChannelMessage -Times 1 -ParameterFilter {
            $PullRequestUrl -ceq 'https://dev.azure.com/example%20org/Example%20Project/_git/example%20repo%231/pullrequest/42'
        }
    }

    It 'passes a read-only live ADO reference context without opening a second ADO session' {
        $script:TeamsPrReferenceEnabled = $true
        $script:ReviewerTeamsAdoSession = @{ LiveCycle = $true }
        $script:HandlerTeamsAdoSession = @{ LiveCycle = $true }
        Invoke-TestNotification
        Should -Invoke New-AgentTeamsPrReferenceContext -Times 1 -ParameterFilter {
            $AdoSession.LiveCycle -and -not $AllowWrites -and $Role -ceq $script:notificationRole
        }
        Should -Invoke Send-AgentTeamsThreadedChannelMessage -Times 1 -ParameterFilter { $ReferenceContext.AdoSession.LiveCycle }
        Should -Invoke Open-AgentMcpSession -Times 0 -ParameterFilter { $Server -ceq 'ado' }
    }

    It 'opens and closes a dedicated reference session outside a cycle' {
        $script:TeamsPrReferenceEnabled = $true
        Invoke-TestNotification
        Should -Invoke Open-AgentMcpSession -Times 1 -ParameterFilter { $Server -ceq 'ado' }
        Should -Invoke Close-AgentMcpSession -Times 2
    }

    It 'never grants reference writes to the reviewer and requires the explicit handler switch' {
        $script:TeamsPrReferenceEnabled = $true
        $script:EnableTeamsPrReferenceWrites = $true
        Invoke-TestNotification
        Should -Invoke New-AgentTeamsPrReferenceContext -Times 1 -ParameterFilter {
            [bool]$AllowWrites -eq ($script:notificationRole -ceq 'review-handler')
        }
    }

    It 'fails closed for shared channel references while keeping direct delivery independent' {
        $script:TeamsPrReferenceEnabled = $true
        $script:TeamsDirectEnabled = $true
        Mock New-AgentTeamsPrReferenceContext { throw 'Unverified reference context' }
        Invoke-TestNotification
        Should -Invoke Send-AgentTeamsThreadedChannelMessage -Times 0
        Should -Invoke Send-AgentTeamsChannelMessage -Times 0
        Should -Invoke Send-AgentTeamsDirectMessage -Times 1
        Should -Invoke Close-AgentMcpSession -Times 2
    }

    It 'does not call or queue any notification under the absolute preview ceiling' {
        $script:PreviewOnly = $true
        $script:TeamsPrReferenceEnabled = $true
        $script:EnableTeamsPrReferenceWrites = $true
        $script:TeamsDirectEnabled = $true
        Invoke-TestNotification
        Should -Invoke Open-AgentMcpSession -Times 0
        Should -Invoke Get-JsonState -Times 0
        Should -Invoke Send-AgentTeamsThreadedChannelMessage -Times 0
        Should -Invoke Send-AgentTeamsDirectMessage -Times 0
    }

    It 'does not deliver notifications for a denied or cancelled-before-proceed manual startup' {
        $script:ManualDispatchManifest = 'manual-fixture'
        $script:TeamsPrReferenceEnabled = $true
        $script:TeamsDirectEnabled = $true
        Invoke-TestNotification
        Should -Invoke Open-AgentMcpSession -Times 0
        Should -Invoke Get-JsonState -Times 0
        Should -Invoke Test-AgentManualCancellationRequested -Times 0
    }

    It 'retains normal event delivery after proceed but suppresses a subsequently cancelled manual turn' {
        $script:ManualDispatchManifest = 'manual-fixture'
        $script:ReviewerTeamsManualAuthorized = $true
        $script:HandlerTeamsManualAuthorized = $true
        Invoke-TestNotification
        Should -Invoke Send-AgentTeamsThreadedChannelMessage -Times 1
        Mock Test-AgentManualCancellationRequested { $true }
        Invoke-TestNotification
        Should -Invoke Send-AgentTeamsThreadedChannelMessage -Times 1
        Should -Invoke Get-JsonState -Times 1
    }

    It 'reports durable queued delivery without recording success or claiming a failed send' {
        $script:threadResult = @{ Delivered = $false; Deduped = $false; Queued = $true; Outcome = 'queued'; Code = 'reference-pending' }
        Invoke-TestNotification
        Should -Invoke Set-JsonState -Times 0
        Should -Invoke Send-AgentTeamsChannelMessage -Times 0
        Should -Invoke Write-Warning -Times 0
        Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -match 'queued.*not yet delivered' }
    }

    It 'binds post-push handler notification queues to the fresh validated PR head' -Skip:($Role -ne 'review-handler') {
        $script:TeamsPrReferenceEnabled = $true
        $script:HandlerTeamsAdoSession = @{ LiveCycle = $true }
        $script:threadResult = @{ Delivered = $false; Deduped = $false; Queued = $true; Outcome = 'queued'; Code = 'reference-pending' }
        Mock Invoke-AgentMcpTool {
            @{ pullRequestId = 42; status = 'active'; isDraft = $false
                sourceRefName = 'refs/heads/operator/topic'; repository = @{ id = 'verified-repository-id' }
                lastMergeSourceCommit = @{ commitId = 'b' * 40 } }
        }
        Invoke-TestNotification -Commit ('a' * 40) -SourceRefName 'refs/heads/operator/topic' -ExpectedSourceCommit ('b' * 40)
        Should -Invoke Invoke-AgentMcpTool -Times 1 -ParameterFilter {
            $Name -eq 'repo_pull_request' -and $Arguments.action -eq 'get' -and
            $Arguments.project -eq 'verified-project-id' -and $Arguments.repositoryId -eq 'verified-repository-id'
        }
        Should -Invoke Send-AgentTeamsThreadedChannelMessage -Times 1 -ParameterFilter { $SourceCommit -eq ('b' * 40) }
        Should -Invoke Set-JsonState -Times 0
    }

    It 'refreshes a failure notification even when a failed model already pushed without a marker' -Skip:($Role -ne 'review-handler') {
        $script:TeamsPrReferenceEnabled = $true
        $script:TeamsChannelEvents += 'handlerFailed'
        Mock Invoke-AgentMcpTool {
            @{ pullRequestId = 42; status = 'active'; isDraft = $false
                sourceRefName = 'refs/heads/operator/topic'; repository = @{ id = 'verified-repository-id' }
                lastMergeSourceCommit = @{ commitId = 'b' * 40 } }
        }
        Invoke-TestNotification -Commit ('a' * 40) -SourceRefName 'refs/heads/operator/topic' -EventOverride handlerFailed
        Should -Invoke Send-AgentTeamsThreadedChannelMessage -Times 1 -ParameterFilter { $SourceCommit -eq ('b' * 40) }
    }

    It 'does not retag ready work onto an unrelated or unverifiable head, and preserves independent DMs' -Skip:($Role -ne 'review-handler') {
        $script:TeamsPrReferenceEnabled = $true
        $script:TeamsDirectEnabled = $true
        Mock Invoke-AgentMcpTool {
            @{ pullRequestId = 42; status = 'active'; isDraft = $false
                sourceRefName = 'refs/heads/operator/topic'; repository = @{ id = 'verified-repository-id' }
                lastMergeSourceCommit = @{ commitId = 'c' * 40 } }
        }
        Invoke-TestNotification -Commit ('a' * 40) -SourceRefName 'refs/heads/operator/topic' -ExpectedSourceCommit ('b' * 40)
        Should -Invoke Send-AgentTeamsThreadedChannelMessage -Times 0
        Should -Invoke Send-AgentTeamsChannelMessage -Times 0
        Should -Invoke Send-AgentTeamsDirectMessage -Times 1
    }

    It 'does not bypass the notification capability ceiling' {
        $script:EnableTeamsNotifications = $false
        Invoke-TestNotification
        Should -Invoke Open-AgentMcpSession -Times 0
        Should -Invoke Get-JsonState -Times 0
        Should -Invoke Send-AgentTeamsThreadedChannelMessage -Times 0
    }

    It 'preserves independent channel delivery when threading is disabled' {
        $script:TeamsThreadReuseEnabled = $false
        Invoke-TestNotification
        Invoke-TestNotification
        Should -Invoke Send-AgentTeamsChannelMessage -Times 1 -Exactly
        Should -Invoke Send-AgentTeamsThreadedChannelMessage -Times 0
    }

    It 'keeps direct-only delivery independent even with the channel threading flag set' {
        $script:TeamsChannelEnabled = $false
        $script:TeamsDirectEnabled = $true
        Invoke-TestNotification
        Invoke-TestNotification
        Should -Invoke Send-AgentTeamsDirectMessage -Times 1 -Exactly
        Should -Invoke Send-AgentTeamsThreadedChannelMessage -Times 0
        Should -Invoke Send-AgentTeamsChannelMessage -Times 0
    }

    It 'falls back independently without a verified repository' {
        $script:repositoryIdentity.verified = $false
        Invoke-TestNotification
        Should -Invoke Send-AgentTeamsChannelMessage -Times 1 -Exactly
        Should -Invoke Send-AgentTeamsThreadedChannelMessage -Times 0
        Should -Invoke Publish-AgentEvent -Times 1 -ParameterFilter {
            $EventType -eq 'notification.delivery' -and $Data.outcome -eq 'fallback-delivered'
        }
    }

    It 'does not create a thread for a non-PR notification' {
        Invoke-TestNotification -PrId 0
        Should -Invoke Send-AgentTeamsChannelMessage -Times 1 -Exactly
        Should -Invoke Send-AgentTeamsThreadedChannelMessage -Times 0
    }

    It 'lets the shared destination-bound ledger decide despite a legacy channel receipt' {
        $key = "$script:notificationEvent|42|abc123"
        $script:notificationState[$key] = @{ destinations = @('channel') }
        $script:notificationState["$key|channel"] = @{ destination = 'channel' }
        Invoke-TestNotification
        $script:TeamsChannelId = 'another-synthetic-channel'
        Invoke-TestNotification
        Should -Invoke Send-AgentTeamsThreadedChannelMessage -Times 2 -Exactly
        Should -Invoke Send-AgentTeamsThreadedChannelMessage -Times 1 -Exactly -ParameterFilter {
            $ChannelId -eq 'another-synthetic-channel'
        }
    }

    It 'does not mark <Outcome> delivery successful or fall back to another POST' -ForEach @(
        @{ Outcome = 'unknown' }, @{ Outcome = 'failed' }, @{ Outcome = 'deferred' }
    ) {
        $script:threadResult = @{ Delivered = $false; Deduped = $false; Outcome = $Outcome; Code = 'synthetic-failure' }
        { Invoke-TestNotification } | Should -Not -Throw
        Should -Invoke Set-JsonState -Times 0
        Should -Invoke Send-AgentTeamsChannelMessage -Times 0
        Should -Invoke Write-Warning -Times 1
    }

    It 'accepts a durable dedupe receipt without claiming another send' {
        $script:threadResult = @{ Delivered = $false; Deduped = $true; Outcome = 'deduped'; Code = 'already-delivered' }
        Invoke-TestNotification
        Should -Invoke Set-JsonState -Times 1
        Should -Invoke Write-Warning -Times 0
        Should -Invoke Send-AgentTeamsChannelMessage -Times 0
    }

    It 'retries an unfinished channel without re-sending a successful direct notification' {
        $script:TeamsDirectEnabled = $true
        $script:threadResult = @{ Delivered = $false; Deduped = $false; Outcome = 'unknown'; Code = 'unconfirmed' }
        Invoke-TestNotification
        $script:threadResult = @{ Delivered = $true; Deduped = $false; Outcome = 'reply-delivered'; Code = 'replied' }
        Invoke-TestNotification
        Should -Invoke Send-AgentTeamsThreadedChannelMessage -Times 2 -Exactly
        Should -Invoke Send-AgentTeamsDirectMessage -Times 1 -Exactly
    }

    It 'retries a failed direct notification after a successful channel notification' {
        $script:TeamsDirectEnabled = $true
        Mock Send-AgentTeamsDirectMessage { throw 'Synthetic direct failure' }
        Invoke-TestNotification
        $script:threadResult = @{ Delivered = $false; Deduped = $true; Outcome = 'deduped'; Code = 'already-delivered' }
        Invoke-TestNotification
        Should -Invoke Send-AgentTeamsThreadedChannelMessage -Times 2 -Exactly
        Should -Invoke Send-AgentTeamsDirectMessage -Times 2 -Exactly
    }

    It 'does not let a thrown channel failure suppress direct delivery' {
        $script:TeamsDirectEnabled = $true
        Mock Send-AgentTeamsThreadedChannelMessage { throw 'Synthetic channel failure' }
        { Invoke-TestNotification } | Should -Not -Throw
        Should -Invoke Send-AgentTeamsDirectMessage -Times 1 -Exactly
        Should -Invoke Send-AgentTeamsChannelMessage -Times 0
    }

    It 'keeps notification state read failures nonfatal' {
        Mock Get-JsonState { throw 'Synthetic read failure' }
        { Invoke-TestNotification } | Should -Not -Throw
        Should -Invoke Write-Warning -Times 1
        Should -Invoke Open-AgentMcpSession -Times 0
        Should -Invoke Publish-AgentEvent -Times 1 -ParameterFilter {
            $EventType -eq 'notification.delivery' -and $Data.code -eq 'notification-wrapper-error'
        }
    }

    It 'keeps notification state write failures nonfatal and closes the session' {
        Mock Set-JsonState { throw 'Synthetic write failure' }
        { Invoke-TestNotification } | Should -Not -Throw
        Should -Invoke Write-Warning -Times 1
        Should -Invoke Close-AgentMcpSession -Times 1
    }

    It 'keeps session initialization failures nonfatal' {
        Mock Open-AgentMcpSession { throw 'Synthetic startup failure' }
        { Invoke-TestNotification } | Should -Not -Throw
        Should -Invoke Write-Warning -Times 1
        Should -Invoke Close-AgentMcpSession -Times 0
    }

    It 'keeps session cleanup failures nonfatal after confirmed delivery' {
        Mock Close-AgentMcpSession { throw 'Synthetic cleanup failure' }
        { Invoke-TestNotification } | Should -Not -Throw
        Should -Invoke Set-JsonState -Times 1
        Should -Invoke Write-Warning -Times 1
        Should -Invoke Publish-AgentEvent -Times 1 -ParameterFilter {
            $EventType -eq 'notification.delivery' -and $Data.code -eq 'session-cleanup-error'
        }
    }

    It 'allows failure notifications without a source commit' {
        Invoke-TestNotification -Commit ''
        Should -Invoke Send-AgentTeamsThreadedChannelMessage -Times 1 -Exactly -ParameterFilter {
            $SourceCommit -eq '' -and $PullRequestId -eq 42
        }
    }
}
