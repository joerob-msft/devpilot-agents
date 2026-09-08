BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1" -Force
}

Describe '<Role> shared Teams cycle lifecycle' -ForEach @(
    @{ Role = 'reviewer'; Prefix = 'Reviewer'; ScriptName = 'Start-ReviewerAgent.ps1' }
    @{ Role = 'review-handler'; Prefix = 'Handler'; ScriptName = 'Start-ReviewHandlerAgent.ps1' }
) {
    BeforeAll {
        $path = (Resolve-Path "$PSScriptRoot\..\src\Agents\$Role\$ScriptName").Path
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        foreach ($definition in $ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -match "^(Get|Invoke|Send|Write|ConvertTo|Test|Build)-$Prefix"
        }, $true)) {
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        $script:cycleFunction = "Invoke-${Prefix}Cycle"
        $script:maintenanceFunction = "Invoke-${Prefix}TeamsMaintenance"
        $script:eventFunction = "Send-${Prefix}Event"
        $script:role = $Role
    }

    BeforeEach {
        $script:calls = [Collections.Generic.List[string]]::new()
        $script:EnableTeamsNotifications = $true
        $script:EnableTeamsPrReferenceWrites = $true
        $script:PreviewOnly = $false
        $script:ManualDispatchManifest = ''
        $script:ReviewerTeamsManualAuthorized = $false
        $script:HandlerTeamsManualAuthorized = $false
        $script:TeamsPrReferenceEnabled = $true
        $script:TeamsThreadReuseEnabled = $true
        $script:TeamsChannelEnabled = $true
        $script:TeamsChannelEvents = @('reviewCompleted', 'prReadyToComplete')
        $script:TeamsTeamId = 'team'
        $script:TeamsChannelId = 'channel'
        $script:Organization = 'example-org'
        $script:ExpectedProject = 'Example Project'
        $script:RepositoryName = 'example-repo'
        $script:OperatorAlias = 'operator'
        $script:PullRequestId = 0
        $script:McpTimeoutSeconds = 15
        $script:McpSensitiveEnvironmentVariables = @()
        $script:CandidatePageLimit = 2
        $script:MaxSourceCommitAgeDays = 30
        $script:SelectionBudgetSeconds = 0
        $script:PullRequestsPerCycle = 1
        $script:ConsecutiveFailureThreshold = 3
        $script:TargetRefName = 'refs/heads/main'
        $script:IncludeOwnPullRequests = $false
        $script:AuthorAliases = @()
        $script:SkipTitlePatterns = @()
        $script:EnableFindingComments = $false
        $script:EnableThreadReplies = $false
        $script:EnableSummaryComment = $false
        $script:EnableApprovalVote = $false
        $script:ForceAnalysis = $false
        $script:BotSubstrings = @()
        $script:SystemSubstrings = @()
        $script:AgentSignatureMarkers = @()
        $script:ReviewerSignatureFooter = 'reviewer-test-signature'
        $script:notificationsStatePath = Join-Path $TestDrive 'notifications.json'
        $script:attemptsStatePath = Join-Path $TestDrive 'attempts.json'
        $script:DurableStateRoot = Join-Path $TestDrive 'durable'
        $script:notificationState = @{}
        $script:repositoryIdentity = @{ verified = $true; key = 'verified-fixture' }
        $script:ReviewerOutputContext = @{ Agent = 'reviewer' }
        $script:HandlerOutputContext = @{ Agent = 'review-handler' }
        $script:ReviewerDurableContext = @{}
        $script:HandlerDurableContext = @{ RoleRoot = $script:DurableStateRoot }
        $script:bootstrapCursorPath = Join-Path $script:DurableStateRoot 'teams-pr-reference-bootstrap.v1.json'
        $script:prs = @(@{
            pullRequestId = 42; status = 'active'; isDraft = $false
            createdBy = @{ uniqueName = 'operator@example.test' }
            lastMergeSourceCommit = @{ commitId = 'a' * 40 }
        })
        Mock Open-AgentMcpSession {
            param($Server)
            @{ Server = $Server; LiveCycle = $Server -eq 'ado'; Process = [pscustomobject]@{ Alive = $true } }
        }
        Mock Close-AgentMcpSession {}
        Mock New-AgentTeamsPrReferenceContext { param($AdoSession, $AllowWrites) @{ Ado = $AdoSession; Writes = [bool]$AllowWrites } }
        Mock Invoke-AgentTeamsNotificationOutbox { [void]$script:calls.Add('drain'); @{ Outcome = 'drained' } }
        Mock Initialize-AgentTeamsPrThread { param($PullRequestId) [void]$script:calls.Add("initialize:$PullRequestId"); @{ Outcome = 'ready' } }
        Mock Publish-AgentEvent {} -RemoveParameterValidation EventType
        Mock Test-AgentManualCancellationRequested { $false }
        Mock Get-AgentDurableRecordsSnapshot { @{} }
        Mock Get-JsonState { param($Path) if ($Path -eq $script:bootstrapCursorPath) { $script:notificationState } else { @{} } }
        Mock Set-JsonState { param($Path, $State) if ($Path -eq $script:bootstrapCursorPath) { $script:notificationState = $State } }
        Mock Remove-StaleAgentAttempts { 0 }
        Mock Invoke-AgentMcpTool { param($Name)
            if ($Name -eq 'repo_pull_request_thread') { [void]$script:calls.Add('feedback'); return @() }
            if ($Name -eq 'repo_pull_request') { return $script:prs[0] }
            throw "Unexpected MCP call $Name"
        }
        Mock Write-Host {}
        Mock Write-Warning {}
        Mock $script:eventFunction {}
        Mock "Write-${Prefix}CycleMetadata" {}
        Mock "Get-${Prefix}ActivePullRequests" {
            [void]$script:calls.Add('enumerate')
            if ($script:role -eq 'review-handler') { return @{ Records = $script:prs; Pages = 1 } }
            return $script:prs
        }
        if ($Role -eq 'reviewer') {
            Mock Get-ReviewerCandidateDecision { @{ Eligible = $true } }
            Mock Get-ReviewerPullRequestThreads { @() }
            Mock Build-ReviewerThreadDigest { @{ AssessmentTargets = @(); AllAssessmentTargets = @() } }
            Mock Test-ReviewerAlreadyReviewed { [void]$script:calls.Add('already-reviewed'); $true }
            Mock Invoke-ReviewerPullRequest { throw 'Completed review must not rerun the model.' }
        }
    }

    It 'drains before candidate selection even when no PR has work' {
        $script:prs = @()
        $result = & $script:cycleFunction -AgencyPath unused -CycleNumber 1
        $result.ExitCode | Should -Be 0 -Because $result.Summary
        $script:calls[0] | Should -Be 'drain'
        $script:calls[1] | Should -Be 'enumerate'
        Should -Invoke Invoke-AgentTeamsNotificationOutbox -Times 1 -ParameterFilter {
            $Role -ceq $script:role -and $ReferenceContext.Ado.LiveCycle -and
            $AllowedEvents.Count -eq 2 -and $PullRequestId -eq 0 -and $DeadlineUtc -gt [DateTime]::UtcNow
        }
    }

    It 'completes maintenance before the already-completed review or actionable-feedback gate' {
        $result = & $script:cycleFunction -AgencyPath unused -CycleNumber 1
        $result.ExitCode | Should -Be 0 -Because $result.Summary
        if ($Role -eq 'reviewer') {
            $script:calls.IndexOf('drain') | Should -BeLessThan $script:calls.IndexOf('already-reviewed')
            Should -Invoke Invoke-ReviewerPullRequest -Times 0
            Should -Invoke New-AgentTeamsPrReferenceContext -Times 1 -ParameterFilter { -not $AllowWrites }
        }
        else {
            $script:calls.IndexOf('initialize:42') | Should -BeLessThan $script:calls.IndexOf('feedback')
            Should -Invoke Initialize-AgentTeamsPrThread -Times 1 -ParameterFilter {
                $ReferenceContext.Writes -and $PullRequestUrl -eq 'https://dev.azure.com/example-org/Example%20Project/_git/example-repo/pullrequest/42'
            }
        }
    }

    It 'performs no Teams calls or enqueues when <Ceiling> is disabled' -ForEach @(
        @{ Ceiling = 'EnableTeamsNotifications' }, @{ Ceiling = 'TeamsChannelEnabled' }
        @{ Ceiling = 'TeamsThreadReuseEnabled' }, @{ Ceiling = 'TeamsPrReferenceEnabled' }
    ) {
        Set-Variable -Name $Ceiling -Value $false -Scope Script
        & $script:cycleFunction -AgencyPath unused -CycleNumber 1 | Out-Null
        Should -Invoke Open-AgentMcpSession -Times 0 -ParameterFilter { $Server -eq 'workiq' }
        Should -Invoke Invoke-AgentTeamsNotificationOutbox -Times 0
        Should -Invoke Initialize-AgentTeamsPrThread -Times 0
    }

    It 'honors PreviewOnly even if all notification switches are contradictory' {
        $script:PreviewOnly = $true
        & $script:cycleFunction -AgencyPath unused -CycleNumber 1 | Out-Null
        Should -Invoke New-AgentTeamsPrReferenceContext -Times 0
        Should -Invoke Open-AgentMcpSession -Times 0 -ParameterFilter { $Server -eq 'workiq' }
        Should -Invoke Initialize-AgentTeamsPrThread -Times 0
        Should -Invoke Invoke-AgentTeamsNotificationOutbox -Times 0
        Should -Invoke Set-JsonState -Times 0
    }

    It 'cannot drain or register roots before manual proceed, including a rejected or cancelled startup' {
        $script:ManualDispatchManifest = 'manual-fixture'
        $script:PullRequestId = 42
        & $script:cycleFunction -AgencyPath unused -CycleNumber 1 | Out-Null
        Should -Invoke New-AgentTeamsPrReferenceContext -Times 0
        Should -Invoke Open-AgentMcpSession -Times 0 -ParameterFilter { $Server -eq 'workiq' }
        Should -Invoke Invoke-AgentTeamsNotificationOutbox -Times 0
        Should -Invoke Initialize-AgentTeamsPrThread -Times 0
        Should -Invoke Set-JsonState -Times 0
    }

    It 'suppresses early maintenance after an authenticated manual cancellation' {
        $script:ManualDispatchManifest = 'manual-fixture'
        $script:PullRequestId = 42
        $script:ReviewerTeamsManualAuthorized = $true
        $script:HandlerTeamsManualAuthorized = $true
        Mock Test-AgentManualCancellationRequested { $true }
        & $script:cycleFunction -AgencyPath unused -CycleNumber 1 | Out-Null
        Should -Invoke New-AgentTeamsPrReferenceContext -Times 0
        Should -Invoke Invoke-AgentTeamsNotificationOutbox -Times 0
        Should -Invoke Initialize-AgentTeamsPrThread -Times 0
    }

    It 'does not let outbox errors prevent idle-cycle completion' {
        Mock Invoke-AgentTeamsNotificationOutbox { throw 'Synthetic outbox error' }
        $script:prs = @()
        $result = & $script:cycleFunction -AgencyPath unused -CycleNumber 1
        $result.ExitCode | Should -Be 0 -Because $result.Summary
        Should -Invoke Publish-AgentEvent -Times 1 -ParameterFilter { $Data.outcome -eq 'deferred' }
        Should -Invoke Close-AgentMcpSession -Times 3
    }

    It 'isolates reviewer outbox timeouts from the work session' -Skip:($Role -ne 'reviewer') {
        $script:adoSessions = [Collections.Generic.List[hashtable]]::new()
        Mock Open-AgentMcpSession {
            param($Server, $TimeoutSeconds)
            $session = @{
                Server = $Server
                Process = [pscustomobject]@{ Alive = $true }
                SessionId = [Guid]::NewGuid().ToString('N')
                TimeoutSeconds = $TimeoutSeconds
            }
            if ($Server -eq 'ado') { $script:adoSessions.Add($session) }
            return $session
        }
        Mock Invoke-AgentTeamsNotificationOutbox {
            param($ReferenceContext)
            $ReferenceContext.Ado.Process = $null
            @{ Outcome = 'deferred' }
        }
        Mock Invoke-AgentMcpTool {
            param($Session, $Name)
            if (-not $Session.Process) { throw 'Agent MCP session is closed.' }
            if ($Name -eq 'repo_pull_request') { return $script:prs[0] }
            throw "Unexpected MCP call $Name"
        }
        $script:McpTimeoutSeconds = 120
        $script:PullRequestId = 42

        $result = & $script:cycleFunction -AgencyPath unused -CycleNumber 1

        $result.ExitCode | Should -Be 0 -Because $result.Summary
        $script:adoSessions.Count | Should -Be 2
        $script:adoSessions[0].TimeoutSeconds | Should -Be 120
        $script:adoSessions[1].TimeoutSeconds | Should -Be 15
        $script:adoSessions[0].Process | Should -Not -BeNullOrEmpty
        $script:adoSessions[1].Process | Should -BeNullOrEmpty
        Should -Invoke Publish-AgentEvent -Times 1 -ParameterFilter {
            $Data.code -eq 'outbox-cycle-error' -and
            $Data.reason -eq 'Teams outbox ADO session closed while draining queued notifications.'
        }
        Should -Invoke Invoke-AgentMcpTool -Times 1 -ParameterFilter {
            $Name -eq 'repo_pull_request' -and $Session.SessionId -eq $script:adoSessions[0].SessionId
        }
    }

    It 'isolates Teams maintenance timeouts from the handler work session' -Skip:($Role -ne 'review-handler') {
        $script:adoSessions = [Collections.Generic.List[hashtable]]::new()
        Mock Open-AgentMcpSession {
            param($Server, $TimeoutSeconds)
            $session = @{
                Server = $Server
                Process = [pscustomobject]@{ Alive = $true }
                SessionId = [Guid]::NewGuid().ToString('N')
                TimeoutSeconds = $TimeoutSeconds
            }
            if ($Server -eq 'ado') { $script:adoSessions.Add($session) }
            return $session
        }
        Mock Initialize-AgentTeamsPrThread {
            param($ReferenceContext)
            $ReferenceContext.Ado.Process = $null
            throw 'Agent MCP response timed out.'
        }
        Mock Invoke-AgentMcpTool {
            param($Session, $Name)
            if (-not $Session.Process) { throw 'Agent MCP session is closed.' }
            if ($Name -eq 'repo_pull_request_thread') { [void]$script:calls.Add('feedback'); return @() }
            if ($Name -eq 'repo_pull_request') { return $script:prs[0] }
            throw "Unexpected MCP call $Name"
        }
        $script:McpTimeoutSeconds = 120

        $result = & $script:cycleFunction -AgencyPath unused -CycleNumber 1

        $result.ExitCode | Should -Be 0 -Because $result.Summary
        $script:adoSessions.Count | Should -Be 3
        $script:adoSessions[0].TimeoutSeconds | Should -Be 120
        $script:adoSessions[1].TimeoutSeconds | Should -Be 15
        $script:adoSessions[2].TimeoutSeconds | Should -Be 15
        $script:adoSessions[0].Process | Should -Not -BeNullOrEmpty
        $script:adoSessions[2].Process | Should -BeNullOrEmpty
        Should -Invoke Publish-AgentEvent -Times 1 -ParameterFilter {
            $Data.code -eq 'reference-maintenance-error' -and
            $Data.reason -eq 'Teams reference maintenance ADO session closed while initializing PR 42.'
        }
        Should -Invoke Invoke-AgentMcpTool -Times 1 -ParameterFilter {
            $Name -eq 'repo_pull_request_thread' -and $Session.SessionId -eq $script:adoSessions[0].SessionId
        }
    }

    It 'reports a maintenance ADO closure during outbox draining' -Skip:($Role -ne 'review-handler') {
        Mock Invoke-AgentTeamsNotificationOutbox {
            param($ReferenceContext)
            $ReferenceContext.Ado.Process = $null
            @{ Outcome = 'deferred' }
        }

        Invoke-HandlerTeamsMaintenance -AgencyPath unused

        Should -Invoke Publish-AgentEvent -Times 1 -ParameterFilter {
            $Data.code -eq 'reference-maintenance-error' -and
            $Data.reason -eq 'Teams reference maintenance ADO session closed while draining the notification outbox.'
        }
    }

    It 'binds a fixed/manual cycle to one of two queued PRs without sending or discarding the other' {
        $script:PullRequestId = 42
        $script:ManualDispatchManifest = 'manual-fixture'
        $script:ReviewerTeamsManualAuthorized = $true
        $script:HandlerTeamsManualAuthorized = $true
        $script:pending = @{
            42 = @{ state = 'queued'; body = 'selected PR event' }
            43 = @{ state = 'queued'; body = 'other PR event' }
        }
        $otherBefore = $script:pending[43] | ConvertTo-Json -Compress
        Mock Invoke-AgentTeamsNotificationOutbox {
            param($PullRequestId)
            foreach ($id in @($script:pending.Keys)) {
                if ($PullRequestId -gt 0 -and $id -ne $PullRequestId) { continue }
                $script:pending[$id].state = 'sent'
            }
        }
        $result = & $script:cycleFunction -AgencyPath unused -CycleNumber 1
        $result.ExitCode | Should -Be 0 -Because $result.Summary
        $script:pending[42].state | Should -Be 'sent'
        ($script:pending[43] | ConvertTo-Json -Compress) | Should -BeExactly $otherBefore
        Should -Invoke Invoke-AgentTeamsNotificationOutbox -Times 1 -ParameterFilter { $PullRequestId -eq 42 }
        Should -Invoke Invoke-AgentTeamsNotificationOutbox -Times 0 -ParameterFilter { $PullRequestId -ne 42 }
    }

    It 'excludes reference metadata posted by a human from ordinary feedback' {
        Mock Test-AgentTeamsPrReferenceComment { param($CommentText) $CommentText -eq 'synthetic-reference' }
        $comment = @{ content = 'synthetic-reference'; authorUniqueName = 'human@example.test'; authorDisplayName = 'Human' }
        if ($Role -eq 'reviewer') {
            Get-ReviewerCommentClass -Comment $comment | Should -Be system
        }
        else {
            $thread = @{ threadId = 1; status = 'active'; comments = @($comment); lastUpdatedDate = '2026-09-07T00:00:00Z' }
            (Get-HandlerThreadClassification -Thread $thread -OperatorAlias operator).Actionable | Should -BeFalse
            Get-HandlerMaxThreadDate -Threads @($thread) | Should -BeNullOrEmpty
        }
    }

    It 'requires explicit handler write permission while retaining read-only outbox delivery' -Skip:($Role -ne 'review-handler') {
        $script:EnableTeamsPrReferenceWrites = $false
        & $script:cycleFunction -AgencyPath unused -CycleNumber 1 | Out-Null
        Should -Invoke Initialize-AgentTeamsPrThread -Times 0
        Should -Invoke Invoke-AgentTeamsNotificationOutbox -Times 1
        Should -Invoke New-AgentTeamsPrReferenceContext -Times 1 -ParameterFilter { -not $AllowWrites }
    }

    It 'bounds bootstrap work and rotates beyond registered PRs across independent calls' -Skip:($Role -ne 'review-handler') {
        $candidates = @(1..15 | ForEach-Object { @{ pullRequestId = $_ } })
        Invoke-HandlerTeamsMaintenance -AgencyPath unused -Candidates $candidates -Bootstrap
        Should -Invoke Initialize-AgentTeamsPrThread -Times 10
        $script:notificationState.lastPrId | Should -Be 10
        Invoke-HandlerTeamsMaintenance -AgencyPath unused -Candidates $candidates -Bootstrap
        @($script:calls | Where-Object { $_ -like 'initialize:*' })[10] | Should -Be 'initialize:11'
    }

    It 'never bootstraps unrelated PRs during a bound manual turn' -Skip:($Role -ne 'review-handler') {
        $script:PullRequestId = 42
        Invoke-HandlerTeamsMaintenance -AgencyPath unused -Candidates @(
            @{ pullRequestId = 41 }, @{ pullRequestId = 42 }, @{ pullRequestId = 43 }
        ) -Bootstrap
        Should -Invoke Initialize-AgentTeamsPrThread -Times 1 -ParameterFilter { $PullRequestId -eq 42 }
        Should -Invoke Initialize-AgentTeamsPrThread -Times 0 -ParameterFilter { $PullRequestId -ne 42 }
    }
}

Describe 'manual wrapper notification argument inheritance' {
    BeforeAll {
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Resolve-Path "$PSScriptRoot\..\tools\Invoke-DevPilotAgentDispatch.ps1").Path, [ref]$null, [ref]$null)
        $definition = $ast.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ManualWrapperNotificationArguments'
        }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    BeforeEach {
        $script:descriptor = @{ launcherControl = @{ automaticWorkers = @(@{
            role = 'review-handler'; arguments = @('-EnableTeamsNotifications', '-EnableTeamsPrReferenceWrites')
        }) } }
    }
    It 'inherits authorized notification and PR write switches without changing model capabilities' {
        @(Get-ManualWrapperNotificationArguments -Role review-handler -RoleDescriptor @{ absoluteDenies = @() }) |
            Should -Be @('-EnableTeamsNotifications', '-EnableTeamsPrReferenceWrites')
        $capability = Get-AgentHarnessCapabilityDescriptor -Role review-handler
        $capability.delegableDefaultOff | Should -Be 'EnableAutoComplete'
        $capability.allowedManualCapabilities | Should -Not -Contain 'EnableTeamsPrReferenceWrites'
    }
    It 'does not take authority from manual-request fields or unrelated automatic roles' {
        @(Get-ManualWrapperNotificationArguments -Role reviewer -RoleDescriptor @{
            absoluteDenies = @(); EnableTeamsPrReferenceWrites = $true; EnableTeamsNotifications = $true
        }) | Should -BeNullOrEmpty
        $script:descriptor = @{}
        @(Get-ManualWrapperNotificationArguments -Role review-handler -RoleDescriptor @{
            absoluteDenies = @(); EnableTeamsPrReferenceWrites = $true
        }) | Should -BeNullOrEmpty
    }
    It 'requires inherited notifications and refuses preview side effects' {
        $descriptor.launcherControl.automaticWorkers[0].arguments = @('-EnableTeamsPrReferenceWrites')
        @(Get-ManualWrapperNotificationArguments -Role review-handler -RoleDescriptor @{ absoluteDenies = @() }) |
            Should -BeNullOrEmpty
        @(Get-ManualWrapperNotificationArguments -Role review-handler -RoleDescriptor @{ absoluteDenies = @('EnableAutoComplete') }) |
            Should -Be @('-PreviewOnly')
    }
    It 'does not interpret model or other option values as permission switches' {
        $descriptor.launcherControl.automaticWorkers[0].arguments = @('-Model', '-EnableTeamsNotifications', '-EnableTeamsPrReferenceWrites')
        @(Get-ManualWrapperNotificationArguments -Role review-handler -RoleDescriptor @{ absoluteDenies = @() }) |
            Should -BeNullOrEmpty
    }
}

Describe 'manual startup wrapper-permission authority' {
    BeforeAll { $script:permissionModule = (Get-Command Enter-AgentManualDispatchStartup).Module }
    BeforeEach {
        $script:permissionDescriptor = @{
            roles = @{
                'review-handler' = @{ scriptPath = 'C:\toolkit\handler.ps1'; absoluteDenies = @() }
                reviewer = @{ scriptPath = 'C:\toolkit\reviewer.ps1'; absoluteDenies = @() }
            }
            launcherControl = @{ automaticWorkers = @(@{
                role = 'review-handler'
                arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', 'C:\toolkit\handler.ps1',
                    '-Once', '-EnableTeamsNotifications', '-EnableTeamsPrReferenceWrites')
            }) }
        }
        $script:boundPermissions = @{ EnableTeamsNotifications = $true; EnableTeamsPrReferenceWrites = $true; PreviewOnly = $false }
    }
    It 'accepts inherited owned-source permissions without adding a delegable capability' {
        { & $permissionModule { param($Descriptor, $Bound)
            Assert-AgentManualWrapperPermissions -Role review-handler -Descriptor $Descriptor -BoundWrapperPermissions $Bound
        } $permissionDescriptor $boundPermissions } | Should -Not -Throw
        (Get-AgentHarnessCapabilityDescriptor -Role review-handler).delegableDefaultOff | Should -Be EnableAutoComplete
    }
    It 'denies invented, contradictory, or preview-locked manual permission <Case>' -ForEach @(
        @{ Case = 'no-source' }, @{ Case = 'source-notifications-disabled' }, @{ Case = 'source-writes-disabled' }
        @{ Case = 'option-value' }, @{ Case = 'preview-source' }, @{ Case = 'preview-role' }
        @{ Case = 'preview-child' }, @{ Case = 'wrong-role' }, @{ Case = 'malformed-boolean' }
    ) {
        $role = 'review-handler'
        switch ($Case) {
            no-source { $permissionDescriptor.Remove('launcherControl') }
            source-notifications-disabled { $permissionDescriptor.launcherControl.automaticWorkers[0].arguments =
                @($permissionDescriptor.launcherControl.automaticWorkers[0].arguments | Where-Object { $_ -ne '-EnableTeamsNotifications' }) }
            source-writes-disabled { $permissionDescriptor.launcherControl.automaticWorkers[0].arguments =
                @($permissionDescriptor.launcherControl.automaticWorkers[0].arguments | Where-Object { $_ -ne '-EnableTeamsPrReferenceWrites' }) }
            option-value { $permissionDescriptor.launcherControl.automaticWorkers[0].arguments =
                @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', 'C:\toolkit\handler.ps1',
                    '-EnableTeamsNotifications', '-Model', '-EnableTeamsPrReferenceWrites') }
            preview-source { $permissionDescriptor.launcherControl.automaticWorkers[0].arguments += '-PreviewOnly' }
            preview-role { $permissionDescriptor.roles.'review-handler'.absoluteDenies = @('EnableAutoComplete') }
            preview-child { $boundPermissions.PreviewOnly = $true }
            wrong-role { $role = 'reviewer' }
            malformed-boolean { $boundPermissions.EnableTeamsPrReferenceWrites = 'true' }
        }
        { & $permissionModule { param($Role, $Descriptor, $Bound)
            Assert-AgentManualWrapperPermissions -Role $Role -Descriptor $Descriptor -BoundWrapperPermissions $Bound
        } $role $permissionDescriptor $boundPermissions } | Should -Throw '*launch-failed*'
    }
    It 'accepts a complete preview ceiling but never manufactures a preview authority' {
        $boundPermissions = @{ EnableTeamsNotifications = $false; EnableTeamsPrReferenceWrites = $false; PreviewOnly = $true }
        $permissionDescriptor.roles.'review-handler'.absoluteDenies =
            @((Get-AgentHarnessCapabilityDescriptor -Role review-handler -PreviewOnly).absoluteDenies)
        { & $permissionModule { param($Descriptor, $Bound)
            Assert-AgentManualWrapperPermissions -Role review-handler -Descriptor $Descriptor -BoundWrapperPermissions $Bound
        } $permissionDescriptor $boundPermissions } | Should -Not -Throw
    }
    It 'checks wrapper permissions against the live broker anchor before acquiring manual work authority' {
        $ast = [Management.Automation.Language.Parser]::ParseInput((Get-Command Enter-AgentManualDispatchStartup).Definition, [ref]$null, [ref]$null)
        $commands = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true))
        $anchor = @($commands | Where-Object { $_.GetCommandName() -eq 'Assert-AgentBrokerProcessAnchor' })[0]
        $check = @($commands | Where-Object { $_.GetCommandName() -eq 'Assert-AgentManualWrapperPermissions' })[0]
        $lease = @($commands | Where-Object { $_.GetCommandName() -eq 'Enter-AgentWorkLease' })[0]
        $anchor.Extent.Text | Should -Match '\-PassThru'
        $anchor.Extent.StartOffset | Should -BeLessThan $check.Extent.StartOffset
        $check.Extent.StartOffset | Should -BeLessThan $lease.Extent.StartOffset
    }
}
