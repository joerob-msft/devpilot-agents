BeforeAll {
    $repo = (Resolve-Path "$PSScriptRoot\..").Path
    Import-Module "$repo\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1" -Force
    $handlerPath = Join-Path $repo 'src\Agents\review-handler\Start-ReviewHandlerAgent.ps1'
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $handlerPath, [ref]$null, [ref]$null)
    foreach ($name in @('Get-HandlerMarkerSchema', 'Test-HandlerMarkerBinding', 'Get-HandlerRuntimeContext')) {
        $definition = $ast.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
            }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $script:ResultMarkerPrefix = 'REVIEW_HANDLER_RESULT_V2:'
    $script:HandlerLegacyResultMarkerPrefix = 'REVIEW_HANDLER_RESULT_V1:'
    $script:OperatorAlias = 'operator'
    $script:EnableCodeChanges = $true
    $script:EnablePush = $true
    $script:EnableThreadReplies = $true
    $script:LocalValidation = $true
    $script:EnableBuddyRequeue = $false
    $script:EnableAutoComplete = $false
    $script:Organization = 'example-org'
    $script:ExpectedProject = 'ExampleProject'
    $script:RepositoryName = 'example-repository'
    $script:EffectiveProtectedBranches = @('main')
    $script:PrimaryHandlerSkillPath = ''
    $script:RepoConventionsText = ''
}

Describe 'source-scoped failure attempts' {
    It 'does not carry a legacy PR-wide starvation count into a source-scoped record' {
        $attempts = @{ '42' = @{ count = 3; lastReason = 'legacy failure' } }
        (Get-AgentSourceScopedAttemptRecord -Record $attempts['42'] -SourceCommit ('a' * 40)).MatchesSource |
            Should -BeFalse
        (Remove-AgentAttemptRecordForDifferentSource -AttemptsState $attempts -PullRequestId 42 `
                -SourceCommit ('a' * 40)) | Should -BeTrue
        $attempts.ContainsKey('42') | Should -BeFalse
    }

    It 'counts only consecutive deterministic failures on the same source commit' {
        $attempts = @{}
        1..3 | ForEach-Object {
            Set-AgentSourceScopedAttemptRecord -AttemptsState $attempts -PullRequestId 42 `
                -SourceCommit ('a' * 40) -FailureClass deterministic -Reason "validation failure $_" | Out-Null
        }
        $record = Get-AgentSourceScopedAttemptRecord -Record $attempts['42'] -SourceCommit ('a' * 40)
        $record.DeterministicCount | Should -Be 3
        $record.FailureClass | Should -BeExactly deterministic

        Set-AgentSourceScopedAttemptRecord -AttemptsState $attempts -PullRequestId 42 `
            -SourceCommit ('a' * 40) -FailureClass source-changed -Reason 'source advanced' | Out-Null
        (Get-AgentSourceScopedAttemptRecord -Record $attempts['42'] -SourceCommit ('a' * 40)).DeterministicCount |
            Should -Be 3
    }

    It 'automatically clears a record when the source commit changes' {
        $attempts = @{}
        Set-AgentSourceScopedAttemptRecord -AttemptsState $attempts -PullRequestId 42 `
            -SourceCommit ('a' * 40) -FailureClass deterministic -Reason 'validation failed' | Out-Null
        (Remove-AgentAttemptRecordForDifferentSource -AttemptsState $attempts -PullRequestId 42 `
                -SourceCommit ('b' * 40)) | Should -BeTrue
        $attempts.Count | Should -Be 0
    }

    It 'survives Set-JsonState and Get-JsonState nested-object round trips' {
        $path = Join-Path $TestDrive 'attempts.json'
        $attempts = @{}
        Set-AgentSourceScopedAttemptRecord -AttemptsState $attempts -PullRequestId 42 `
            -SourceCommit ('a' * 40) -FailureClass deterministic -Reason 'validation failed' | Out-Null
        Set-JsonState -Path $path -State $attempts
        $reloaded = Get-JsonState -Path $path
        $reloaded['42'].GetType().Name | Should -BeExactly PSCustomObject
        $record = Get-AgentSourceScopedAttemptRecord -Record $reloaded['42'] -SourceCommit ('a' * 40)
        $record.MatchesSource | Should -BeTrue
        $record.DeterministicCount | Should -Be 1
    }

    It 'carries deterministic validation count across an agent-authored pushed commit' {
        $attempts = @{}
        1..2 | ForEach-Object {
            Set-AgentSourceScopedAttemptRecord -AttemptsState $attempts -PullRequestId 42 `
                -SourceCommit ('a' * 40) -FailureClass deterministic -Reason "validation failure $_" | Out-Null
        }
        $carry = (Get-AgentSourceScopedAttemptRecord -Record $attempts['42'] -SourceCommit ('a' * 40)).DeterministicCount
        Set-AgentSourceScopedAttemptRecord -AttemptsState $attempts -PullRequestId 42 `
            -SourceCommit ('b' * 40) -FailureClass deterministic -Reason 'validation still failing' `
            -CarryDeterministicCount $carry | Out-Null
        (Get-AgentSourceScopedAttemptRecord -Record $attempts['42'] -SourceCommit ('b' * 40)).DeterministicCount |
            Should -Be 3
    }

    It 'wires source revalidation before starvation and reserves deterministic counting for validation' {
        $handler = Get-Content "$repo\src\Agents\review-handler\Start-ReviewHandlerAgent.ps1" -Raw
        $reviewer = Get-Content "$repo\src\Agents\reviewer\Start-ReviewerAgent.ps1" -Raw
        foreach ($source in $handler, $reviewer) {
            $source.IndexOf('Remove-AgentAttemptRecordForDifferentSource') |
                Should -BeLessThan $source.IndexOf('$attempts -ge $ConsecutiveFailureThreshold')
            $source | Should -Match "failureClass = 'source-changed'"
            $source | Should -Match 'countedTowardStarvation = \$false'
        }
        $handler | Should -Match '-FailureClass deterministic'
        $handler | Should -Match 'validation failed'
        $reviewer | Should -Match 'Get-ReviewerLastActivitySortKey'
    }
}

Describe 'handler terminal recovery contract' {
    It 'accepts a bound V2 source-change marker' {
        $nonce = 'n' * 36
        $repoId = '11111111-1111-1111-1111-111111111111'
        $bound = 'a' * 40
        $observed = 'b' * 40
        $json = @{
            schemaVersion = 2; prId = 42; repositoryId = $repoId; project = 'ExampleProject'
            handledSourceCommit = $bound; threadsAddressed = 0; threadsReplied = 0
            commitsPushed = 0; pushedCommit = $null; validation = 'skipped'
            readyToComplete = $false; nonce = $nonce; outcome = 'source-changed'
            observedSourceCommit = $observed
        } | ConvertTo-Json -Compress
        $marker = ConvertFrom-AgentResultMarker -StdOutText "REVIEW_HANDLER_RESULT_V2: $json" `
            -MarkerPrefix 'REVIEW_HANDLER_RESULT_V2:' `
            -Schema (Get-HandlerMarkerSchema -ExpectedProject ExampleProject -ExpectedNonce $nonce -SchemaVersion 2)
        $marker.outcome | Should -BeExactly source-changed
        $marker.observedSourceCommit | Should -BeExactly $observed
        Test-HandlerMarkerBinding -Marker $marker -PrId 42 -RepositoryId $repoId -SourceCommit $bound |
            Should -BeTrue
    }

    It 'retains V1 parsing compatibility' {
        $nonce = 'n' * 36
        $repoId = '11111111-1111-1111-1111-111111111111'
        $bound = 'a' * 40
        $json = @{
            schemaVersion = 1; prId = 42; repositoryId = $repoId; project = 'ExampleProject'
            handledSourceCommit = $bound; threadsAddressed = 1; threadsReplied = 1
            commitsPushed = 0; pushedCommit = $null; validation = 'skipped'
            readyToComplete = $false; nonce = $nonce
        } | ConvertTo-Json -Compress
        $marker = ConvertFrom-AgentResultMarker -StdOutText "REVIEW_HANDLER_RESULT_V1: $json" `
            -MarkerPrefix 'REVIEW_HANDLER_RESULT_V1:' `
            -Schema (Get-HandlerMarkerSchema -ExpectedProject ExampleProject -ExpectedNonce $nonce -SchemaVersion 1)
        $marker.schemaVersion | Should -Be 1
    }

    It 'injects exact deadline and reconciliation instructions into runtime context' {
        $started = [DateTime]'2026-09-18T01:00:00Z'
        $context = Get-HandlerRuntimeContext -Nonce ('n' * 36) -PermissionMode BroadCodeTools `
            -PrId 42 -RepositoryId '11111111-1111-1111-1111-111111111111' `
            -SourceCommit ('a' * 40) -SourceBranch feature/test -WorktreePath $TestDrive `
            -ResolvedSessionId none -ThreadDigestText 'threadId=1; actionable=true' `
            -CycleStartedAtUtc $started -CycleDeadlineUtc $started.AddMinutes(30) `
            -FinalizationCutoffUtc $started.AddMinutes(27) -EffectiveFinalizationReserveSeconds 180 `
            -RecoveryFailureClass partial-work-unconfirmed -RecoveryReason 'prior marker missing'
        $context | Should -Match 'Hard cycle deadline UTC'
        $context | Should -Match '2026-09-18T01:30:00'
        $context | Should -Match 'Reserved finalization window: `180`'
        $context | Should -Match 'Before any new write, reconcile'
    }

    It 'documents the V2 non-success outcomes in the prompt' {
        $prompt = Get-Content "$repo\src\Agents\review-handler\handle-cycle.prompt.md" -Raw
        $prompt | Should -Match 'REVIEW_HANDLER_RESULT_V2'
        $prompt | Should -Match 'source-changed'
        $prompt | Should -Match 'deadline-reached'
        $prompt | Should -Match 'finalization cutoff'
    }
}
