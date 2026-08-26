BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1" -Force

    function New-TestReviewerContext {
        param([string]$Mode = 'Compact', [bool]$Redirected = $false, [bool]$Ansi = $false)
        $script:reviewerLines = [System.Collections.Generic.List[string]]::new()
        New-AgentOutputContext -Agent reviewer -OutputMode $Mode -IsOutputRedirected $Redirected `
            -SupportsAnsi $Ansi -WindowWidth 120 -WriteLine {
                param($line)
                [void]$script:reviewerLines.Add([string]$line)
            } -WriteRaw {
                param($text)
                [void]$script:reviewerLines.Add([string]$text)
            }
    }
}

Describe 'Reviewer output modes' {
    It 'aggregates hundreds of skips in compact mode' {
        $context = New-TestReviewerContext
        1..300 | ForEach-Object {
            Publish-AgentEvent $context candidate.skipped -Cycle 1 -PrId $_ `
                -Data @{ reason = 'draft'; normalizedReason = 'draft' } -Message "PR $_ skipped (draft)." | Out-Null
        }
        Publish-AgentEvent $context candidates.enumerated -Cycle 1 `
            -Data @{ scanned = 300; pages = 3; skipped = @{ draft = 300 } } | Out-Null

        $script:reviewerLines.Count | Should -Be 2
        $script:reviewerLines[0] | Should -Be 'Scanned 300 PRs across 3 pages'
        $script:reviewerLines[1] | Should -Be 'Skipped 300: 300 draft'
    }

    It 'retains individual skip records in detailed mode' {
        $context = New-TestReviewerContext -Mode Detailed
        Publish-AgentEvent $context candidate.skipped -Cycle 1 -PrId 42 `
            -Data @{ reason = 'draft'; normalizedReason = 'draft' } -Message 'PR 42 skipped (draft).' | Out-Null
        $script:reviewerLines | Should -Contain 'PR 42 skipped (draft).'
    }

    It 'writes one valid JSON object per event without human lines' {
        $context = New-TestReviewerContext -Mode Json
        Publish-AgentEvent $context cycle.started -Cycle 7 -Data @{} -Message 'Cycle 7' | Out-Null
        Publish-AgentEvent $context candidate.skipped -Cycle 7 -PrId 42 -Data @{ reason = 'draft' } | Out-Null

        $script:reviewerLines.Count | Should -Be 2
        foreach ($line in $script:reviewerLines) {
            $event = $line | ConvertFrom-Json
            $event.PSObject.Properties.Name | Should -Be @(
                'schemaVersion', 'agent', 'instanceId', 'processId', 'timestamp', 'sequence', 'eventType',
                'level', 'cycleNumber', 'pullRequestId', 'sourceCommit', 'data', 'message'
            )
            $event.schemaVersion | Should -Be 2
            $event.agent | Should -Be 'reviewer'
            $event.instanceId | Should -Not -BeNullOrEmpty
            $event.processId | Should -BeGreaterThan 0
            $event.sequence | Should -BeGreaterThan 0
        }
        ($script:reviewerLines -join "`n") | Should -Not -Match '^Cycle 7$'
    }

    It 'falls back from Auto when redirected or ANSI is unavailable' {
        (New-TestReviewerContext -Mode Auto -Redirected $true -Ansi $true).Mode | Should -Be 'Compact'
        (New-TestReviewerContext -Mode Auto -Redirected $false -Ansi $false).Mode | Should -Be 'Compact'
        (New-TestReviewerContext -Mode Auto -Redirected $false -Ansi $true).Mode | Should -Be 'Interactive'
        (New-AgentOutputContext -Agent reviewer -OutputMode Auto -IsOutputRedirected $false `
                -SupportsAnsi $true -WindowWidth 40).Mode | Should -Be 'Compact'
    }

    It 'refreshes elapsed time while an interactive phase is running' {
        $writer = [IO.StringWriter]::new()
        $context = New-AgentOutputContext -Agent reviewer -OutputMode Auto `
            -IsOutputRedirected $false -SupportsAnsi $true -WindowWidth 120 `
            -InteractiveWriter $writer -InteractiveRefreshIntervalMilliseconds 100 `
            -UseLiveConsoleWidth $false
        try {
            Publish-AgentEvent $context phase.changed -Cycle 1 -PrId 42 -Data @{
                phase = 'running the model'
                elapsedMilliseconds = 0
            } | Out-Null
            Start-Sleep -Milliseconds 1250
            $writer.ToString() | Should -Match 'PR 42  running the model  1s'
        }
        finally {
            if ($context.InteractiveTimer) { $context.InteractiveTimer.Dispose() }
        }
    }

    It 'makes blocked unfinished delivery prominent with outstanding work' {
        $context = New-TestReviewerContext
        Publish-AgentEvent $context delivery.blocked -Level warning -Cycle 2 -PrId 99 -Data @{
            title = 'Update service'
            reason = 'Change set could not be read.'
            outstanding = @('2 comments', 'summary')
            retryable = $true
            nextRetry = 'next cycle'
        } | Out-Null

        ($script:reviewerLines -join "`n") | Should -Match 'WARNING: DELIVERY BLOCKED - PR 99 - Update service'
        ($script:reviewerLines -join "`n") | Should -Match 'Outstanding: 2 comments, summary. Retryable: yes. Next retry: next cycle.'
    }

    It 'does not dump candidate skip records again across continuous cycles' {
        $context = New-TestReviewerContext
        foreach ($cycle in 1..2) {
            1..173 | ForEach-Object {
                Publish-AgentEvent $context candidate.skipped -Cycle $cycle -PrId $_ `
                    -Data @{ reason = 'already reviewed'; normalizedReason = 'delivered' } | Out-Null
            }
            Publish-AgentEvent $context candidates.enumerated -Cycle $cycle `
                -Data @{ scanned = 173; pages = 2; skipped = @{ delivered = 173 } } | Out-Null
        }

        $script:reviewerLines.Count | Should -Be 4
        @($script:reviewerLines | Where-Object { $_ -match '^Skipped 173:' }).Count | Should -Be 2
    }

    It 'uses sensible singular, plural, and zero-count summaries' {
        (Format-AgentCount 0 PR) | Should -Be '0 PRs'
        (Format-AgentCount 1 PR) | Should -Be '1 PR'
        (Format-AgentCount 2 PR) | Should -Be '2 PRs'
        (Format-AgentSkipSummary @{}) | Should -Be 'Skipped 0: 0 routine skips'
    }

    It 'renders pre-selection phases without a fake PR and explains first-candidate selection' {
        $context = New-TestReviewerContext
        Publish-AgentEvent $context phase.changed -Cycle 3 `
            -Data @{ phase = 'enumerating candidates'; elapsedMilliseconds = 0 } | Out-Null
        Publish-AgentEvent $context candidates.enumerated -Cycle 3 -Data @{
            scanned = 169
            pages = 2
            selected = 1
            skipped = @{}
        } | Out-Null

        $script:reviewerLines[0] | Should -Be 'Cycle 3  enumerating candidates  0s'
        $script:reviewerLines | Should -Not -Match 'PR 0'
        $script:reviewerLines[-1] | Should -Be 'Selected the first eligible candidate; remaining PRs were not evaluated'
    }

    It 'retains bounded preview paths and avoids duplicate cycle completion lines' {
        $context = New-TestReviewerContext
        $previewPath = 'C:\state\previews\pr42-abcdef.json'
        Publish-AgentEvent $context work.completed -Cycle 4 -PrId 42 -Data @{
            result = 'previewed'
            elapsedMilliseconds = 1000
            critical = 0
            important = 0
            suggestion = 0
            delivered = 'preview only'
            previewPath = $previewPath
            reason = 'preview run; no write was requested'
        } | Out-Null
        Publish-AgentEvent $context cycle.completed -Cycle 4 `
            -Message 'PR 42 reviewed (0 findings)' | Out-Null

        $script:reviewerLines | Should -Contain "Preview: $previewPath"
        $script:reviewerLines | Should -Not -Contain 'PR 42 reviewed (0 findings)'
    }

    It 'cannot let rendering failures escape into the reviewer cycle' {
        $context = New-AgentOutputContext -Agent reviewer -OutputMode Compact -WriteLine { throw 'renderer failed' }
        { Publish-AgentEvent $context cycle.started -Cycle 1 | Out-Null } | Should -Not -Throw
    }

    It 'redacts sensitive keys and bounds event content' {
        $context = New-TestReviewerContext -Mode Json
        Publish-AgentEvent $context cycle.failed -Level error -Data @{
            token = 'super-secret'
            detail = ('x' * 1000)
        } -Message 'Authorization: Bearer ghp_abcdefghijklmnopqrstuvwxyz123456' | Out-Null
        $event = $script:reviewerLines[0] | ConvertFrom-Json
        $event.data.token | Should -Be '[REDACTED]'
        $event.data.detail.Length | Should -BeLessOrEqual 515
        $script:reviewerLines[0] | Should -Not -Match 'super-secret'
        $script:reviewerLines[0] | Should -Not -Match 'ghp_abcdefghijklmnopqrstuvwxyz'
    }

    It 'rotates bounded diagnostic logs and retains valid JSON Lines' {
        $directory = Join-Path $TestDrive 'events'
        $path = Join-Path $directory 'agent.events.jsonl'
        $context = New-AgentOutputContext -Agent reviewer -OutputMode Compact -LogPath $path `
            -WriteLine { param($line) }
        $context.LogMaxBytes = 100
        $context.LogRetentionCount = 2

        1..4 | ForEach-Object {
            Publish-AgentEvent $context cycle.started -Cycle $_ -Data @{ detail = ('x' * 80) } | Out-Null
        }

        Test-Path -LiteralPath $path | Should -BeTrue
        Test-Path -LiteralPath "$path.1" | Should -BeTrue
        Test-Path -LiteralPath "$path.2" | Should -BeTrue
        Get-Content -LiteralPath $path | ForEach-Object { { $_ | ConvertFrom-Json } | Should -Not -Throw }
    }

    It 'writes heartbeat and lifecycle events to an isolated instance stream' {
        $directory = Join-Path $TestDrive 'instance-events\reviewer'
        $context = New-AgentOutputContext -Agent reviewer -OutputMode Compact `
            -PerInstanceLogDirectory $directory -HeartbeatIntervalMilliseconds 1000 `
            -WriteLine { param($line) }
        try {
            Publish-AgentEvent $context agent.started -Data @{ repository = 'sample' } | Out-Null
            Start-Sleep -Milliseconds 1250
        }
        finally {
            Close-AgentOutputContext $context
        }

        $context.LogPath | Should -Be (Join-Path $directory "$($context.InstanceId).jsonl")
        $events = @(Get-Content -LiteralPath $context.LogPath | ForEach-Object { $_ | ConvertFrom-Json })
        @($events.eventType) | Should -Be @('agent.started', 'agent.heartbeat', 'agent.stopped')
        @($events.sequence) | Should -Be @(1, 2, 3)
        @($events.instanceId | Select-Object -Unique) | Should -Be @($context.InstanceId)
    }

    It 'serializes foreground events and heartbeats in sequence order' {
        $directory = Join-Path $TestDrive 'concurrent-events\reviewer'
        $context = New-AgentOutputContext -Agent reviewer -OutputMode Compact `
            -PerInstanceLogDirectory $directory -HeartbeatIntervalMilliseconds 1000 `
            -WriteLine { param($line) }
        try {
            Publish-AgentEvent $context agent.started | Out-Null
            1..300 | ForEach-Object {
                Publish-AgentEvent $context phase.changed -Cycle 1 -PrId 42 `
                    -Data @{ phase = 'running'; elapsedMilliseconds = $_ } | Out-Null
                Start-Sleep -Milliseconds 5
            }
        }
        finally {
            Close-AgentOutputContext $context
        }

        $events = @(Get-Content -LiteralPath $context.LogPath | ForEach-Object { $_ | ConvertFrom-Json })
        @($events.sequence) | Should -Be @(1..$events.Count)
        $events[-1].eventType | Should -Be 'agent.stopped'
        @($events[0..($events.Count - 2)].eventType) | Should -Contain 'agent.heartbeat'
    }

    It 'retains only the twenty newest per-instance event streams' {
        $directory = Join-Path $TestDrive 'retained-events\reviewer'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        1..21 | ForEach-Object {
            $path = Join-Path $directory ('{0:D2}.jsonl' -f $_)
            Set-Content -LiteralPath $path -Value '{}'
            (Get-Item -LiteralPath $path).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes($_)
        }

        $context = New-AgentOutputContext -Agent reviewer -OutputMode Compact `
            -PerInstanceLogDirectory $directory -WriteLine { param($line) }
        try {
            Publish-AgentEvent $context cycle.started | Out-Null
        }
        finally {
            Close-AgentOutputContext $context
        }

        @(Get-ChildItem -LiteralPath $directory -File -Filter '*.jsonl').Count | Should -Be 20
        Test-Path -LiteralPath (Join-Path $directory '01.jsonl') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $directory '02.jsonl') | Should -BeFalse
    }
}

Describe 'Shared reviewer and review-handler event contract' {
    It 'interleaves processes without ambiguous producer identity or ordering' {
        $script:combinedLines = [System.Collections.Generic.List[string]]::new()
        $sink = { param($line) [void]$script:combinedLines.Add([string]$line) }
        $reviewer = New-AgentOutputContext -Agent reviewer -OutputMode Json -WriteLine $sink
        $handler = New-AgentOutputContext -Agent review-handler -OutputMode Json -WriteLine $sink

        Publish-AgentEvent $reviewer cycle.started -Cycle 1 | Out-Null
        Publish-AgentEvent $handler cycle.started -Cycle 4 | Out-Null
        Publish-AgentEvent $reviewer agent.waiting -Cycle 1 -Data @{ kind = 'scan'; delayMilliseconds = 1000 } | Out-Null
        Publish-AgentEvent $handler agent.waiting -Cycle 4 -Data @{ kind = 'scan'; delayMilliseconds = 2000 } | Out-Null

        $events = @($script:combinedLines | ForEach-Object { $_ | ConvertFrom-Json })
        @($events | Group-Object agent).Count | Should -Be 2
        @($events | Group-Object instanceId).Count | Should -Be 2
        foreach ($instance in @($events | Group-Object instanceId)) {
            @($instance.Group.sequence) | Should -Be @(1, 2)
            @($instance.Group | Select-Object -ExpandProperty agent -Unique).Count | Should -Be 1
        }
        $reviewer.instanceId | Should -Not -Be $handler.instanceId
    }

    It 'wires both agent scripts to the shared OutputMode infrastructure' -ForEach @(
        @{ Script = 'reviewer\Start-ReviewerAgent.ps1'; Agent = 'reviewer' }
        @{ Script = 'review-handler\Start-ReviewHandlerAgent.ps1'; Agent = 'review-handler' }
    ) {
        $path = Join-Path "$PSScriptRoot\..\src\Agents" $Script
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Resolve-Path $path), [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) |
            Should -Contain 'OutputMode'
        $source = Get-Content -LiteralPath $path -Raw
        $source | Should -Match "New-AgentOutputContext\s+-Agent\s+$([regex]::Escape($Agent))"
        $source | Should -Match 'Publish-AgentEvent'
        $source | Should -Match 'candidate\.skipped'
        $source | Should -Match 'candidates\.enumerated'
        $source | Should -Match 'agent\.waiting'
    }

    It 'emits bounded PR identity and outcome fields for the dashboard' {
        $path = Join-Path "$PSScriptRoot\..\src\Agents\reviewer" 'Start-ReviewerAgent.ps1'
        $source = Get-Content -LiteralPath $path -Raw
        foreach ($field in @('title', 'author', 'url', 'sourceBranch', 'targetBranch', 'threadCount', 'actionableThreadCount', 'changedFileCount')) {
            $source | Should -Match ("(?m)^\s*{0}\s*=" -f [regex]::Escape($field))
        }
        foreach ($field in @('requested', 'delivered', 'summary', 'previewArtifact')) {
            $source | Should -Match ("(?m)^\s*{0}\s*=" -f [regex]::Escape($field))
        }
        $source | Should -Match 'prUrl\s*=\s*Get-ReviewerPullRequestLink\s+-PrId'
    }

    It 'provides a preview-only one-command reviewer watcher and attach mode' {
        $path = Join-Path "$PSScriptRoot\..\tools" 'Watch-DevPilotReviewer.ps1'
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Resolve-Path $path), [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) |
            Should -Contain 'AttachOnly'
        @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) |
            Should -Contain 'Continuous'
        @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) |
            Should -Contain 'IntervalSeconds'
        $source = Get-Content -LiteralPath $path -Raw
        $source | Should -Match "OutputMode = 'Json'"
        $source | Should -Match 'Once = \$true'
        $source | Should -Match 'IntervalSeconds = \$IntervalSeconds'
        $source | Should -Match '\$Continuous\s+-and\s+\$PullRequestId\s+-gt\s+0'
        $source | Should -Not -Match 'EnableFindingComments\s*='
        $source | Should -Not -Match 'EnableThreadReplies\s*='
        $source | Should -Not -Match 'EnableSummaryComment\s*='
        $source | Should -Not -Match 'EnableApprovalVote\s*='
        $source | Should -Not -Match 'EnableTeamsNotifications\s*='
        $source.IndexOf('& $dashboardLauncher -StateDir $StateDir -ValidateOnly') |
            Should -BeLessThan $source.IndexOf('$reviewerProcess = Start-Process')
        $source | Should -Match '\$dashboardCompletedNormally\s*=\s*\$false'
        $source | Should -Match '\$reviewerProcess\.Kill\(\$true\)'
        $source | Should -Match '\(-not \$dashboardCompletedNormally -or \$Continuous\)'
    }

    It 'prefers the co-located harness over a stale loaded module' -ForEach @(
        @{ Script = 'reviewer\Start-ReviewerAgent.ps1'; Config = 'reviewer-ado.config.json' }
        @{ Script = 'review-handler\Start-ReviewHandlerAgent.ps1'; Config = 'handler-ado.config.json' }
    ) {
        $staleModule = Join-Path $TestDrive 'stale\DevPilot.AgentHarness'
        New-Item -ItemType Directory -Path $staleModule -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $staleModule 'DevPilot.AgentHarness.psm1') `
            -Value 'function Get-StaleHarnessMarker { $true }'
        $staleManifest = Join-Path $staleModule 'DevPilot.AgentHarness.psd1'
        New-ModuleManifest -Path $staleManifest -RootModule 'DevPilot.AgentHarness.psm1' `
            -FunctionsToExport 'Get-StaleHarnessMarker'

        $runner = Join-Path $TestDrive 'run-with-stale-harness.ps1'
        Set-Content -LiteralPath $runner -Value @'
param($StaleManifest, $AgentScript, $ConfigFile)
Import-Module $StaleManifest -Force
& $AgentScript -DryRun -OutputMode Json -ConfigFile $ConfigFile
exit $LASTEXITCODE
'@
        $agentScript = Join-Path "$PSScriptRoot\..\src\Agents" $Script
        $configFile = Join-Path "$PSScriptRoot\..\samples" $Config
        $lines = @(& pwsh -NoProfile -File $runner $staleManifest $agentScript $configFile)

        $LASTEXITCODE | Should -Be 0
        $events = @($lines | ForEach-Object { $_ | ConvertFrom-Json })
        $events.Count | Should -BeGreaterOrEqual 3
        $events[0].eventType | Should -Be 'agent.started'
        $events[-1].eventType | Should -Be 'agent.stopped'
        @($events.eventType | Where-Object { $_ -notin @(
                    'agent.started', 'agent.heartbeat', 'work.completed', 'agent.stopped'
                ) }) | Should -BeNullOrEmpty
    }
}
