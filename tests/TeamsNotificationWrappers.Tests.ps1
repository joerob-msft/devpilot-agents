BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1" -Force
}

Describe '<Role> Teams notification integration' -ForEach @(
    @{ Role = 'reviewer'; ScriptName = 'Start-ReviewerAgent.ps1'; NotificationFunction = 'Send-ReviewerTeamsNotification'; HashFunction = 'Get-ReviewerHashValue'; EventParameter = 'NotificationEvent'; NotificationEvent = 'reviewCompleted' }
    @{ Role = 'review-handler'; ScriptName = 'Start-ReviewHandlerAgent.ps1'; NotificationFunction = 'Send-HandlerTeamsNotification'; HashFunction = 'Get-HandlerHashValue'; EventParameter = 'Event'; NotificationEvent = 'prReadyToComplete' }
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
        foreach ($name in @($NotificationFunction, $HashFunction)) {
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
            param([int]$PrId = 42, [AllowEmptyString()][string]$Commit = 'abc123')
            $parameters = @{
                AgencyPath = 'unused-agency'; Title = 'Synthetic notification'; Body = 'Synthetic body'
                PrId = $PrId; SourceCommit = $Commit; Links = @()
            }
            $parameters[$script:eventParameter] = $script:notificationEvent
            & $script:notificationFunction @parameters
        }
    }

    BeforeEach {
        $script:EnableTeamsNotifications = $true
        $script:TeamsThreadReuseEnabled = $true
        $script:TeamsChannelEnabled = $true
        $script:TeamsChannelEvents = @($script:notificationEvent)
        $script:TeamsTeamId = 'synthetic-team'
        $script:TeamsChannelId = 'synthetic-channel'
        $script:TeamsDirectEnabled = $false
        $script:TeamsDirectEvents = @($script:notificationEvent)
        $script:TeamsDirectRecipientFallback = 'author@example.test'
        $script:TeamsDirectRecipient = 'author@example.test'
        $script:notificationsStatePath = Join-Path $TestDrive 'notifications.json'
        $script:DurableStateRoot = Join-Path $TestDrive 'durable'
        $script:repositoryIdentity = @{ verified = $true; key = 'v1:github:12345' }
        $script:ReviewerOutputContext = @{ Agent = 'reviewer' }
        $script:HandlerOutputContext = @{ Agent = 'review-handler' }
        $script:notificationState = @{}
        $script:threadResult = @{ Delivered = $true; Deduped = $false; Outcome = 'root-created'; Code = 'created' }
        Mock Open-AgentMcpSession { return @{ Synthetic = $true } }
        Mock Close-AgentMcpSession {}
        Mock Get-JsonState { return $script:notificationState }
        Mock Set-JsonState { param($State) $script:notificationState = $State }
        Mock Send-AgentTeamsThreadedChannelMessage { return $script:threadResult }
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
            $TeamId -eq 'synthetic-team' -and $ChannelId -eq 'synthetic-channel' -and
            $DurableStateRoot -eq $script:DurableStateRoot -and $null -ne $OutputContext
        }
        Should -Invoke Send-AgentTeamsChannelMessage -Times 0
        Should -Invoke Set-JsonState -Times 1
        Should -Invoke Close-AgentMcpSession -Times 1
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
