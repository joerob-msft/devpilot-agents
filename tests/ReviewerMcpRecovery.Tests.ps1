BeforeAll {
    $reviewerPath = (Resolve-Path "$PSScriptRoot\..\src\Agents\reviewer\Start-ReviewerAgent.ps1").Path
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $reviewerPath,
        [ref]$tokens,
        [ref]$parseErrors
    )
    $parseErrors | Should -BeNullOrEmpty

    $recoveryFunction = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Test-ReviewerRecoverableMcpFailure'
        }, $true)
    if (-not $recoveryFunction) { throw 'Reviewer MCP recovery helper was not found.' }
    . ([scriptblock]::Create($recoveryFunction.Extent.Text))

    $cycleFunction = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Invoke-ReviewerCycle'
        }, $true)
    if (-not $cycleFunction) { throw 'Reviewer cycle function was not found.' }
    $script:cycleSource = $cycleFunction.Extent.Text
    . ([scriptblock]::Create($cycleFunction.Extent.Text))

    function Send-ReviewerEvent {
        param([string]$EventType, [string]$Level, [int]$Cycle, [int]$PrId, [string]$SourceCommit, [hashtable]$Data, [string]$Message)
    }
    function Open-AgentMcpSession { param([string]$AgencyPath, [string]$Server, [string]$Organization, [string[]]$Toolsets, [int]$TimeoutSeconds, [string[]]$EnvironmentVariablesToRemove) }
    function Close-AgentMcpSession { param([hashtable]$Session) }
    function Invoke-ReviewerTeamsMaintenance { param([string]$AgencyPath) }
    function Get-AgentDurableRecordsSnapshot { param($Context) }
    function Get-JsonState { param([string]$Path) }
    function Get-ReviewerActivePullRequests { param([hashtable]$Session, [string]$Project, [string]$RepositoryName, [string]$TargetRefName) }
    function Remove-StaleAgentAttempts { param([hashtable]$AttemptsState, [int]$MaxAgeDays) }
    function Write-ReviewerCycleMetadata { param([hashtable]$Fields) }
}

Describe 'reviewer MCP session recovery' {
    BeforeEach {
        $script:ReviewerDurableContext = @{}
        $script:reviewerCalls = 0
        $script:PullRequestId = 0
        $script:Organization = 'example-org'
        $script:ExpectedProject = 'ExampleProject'
        $script:RepositoryName = 'example-repository'
        $script:TargetRefName = 'refs/heads/main'
        $script:McpTimeoutSeconds = 30
        $script:McpSensitiveEnvironmentVariables = @()
        $script:attemptsStatePath = Join-Path $TestDrive 'attempts.json'
        $script:MaxSourceCommitAgeDays = 14
        $script:SelectionBudgetSeconds = 30
        $script:PullRequestsPerCycle = 1
        $script:OperatorAlias = 'operator'
        $script:IncludeOwnPullRequests = $false
        $script:AuthorAliases = @()
        $script:SkipTitlePatterns = @()

        Mock Send-ReviewerEvent {}
        Mock Open-AgentMcpSession { return @{ Process = 'synthetic'; TimeoutSeconds = 30 } }
        Mock Close-AgentMcpSession {}
        Mock Invoke-ReviewerTeamsMaintenance {}
        Mock Get-AgentDurableRecordsSnapshot { return @{} }
        Mock Get-JsonState { return @{} }
        Mock Remove-StaleAgentAttempts { return 0 }
        Mock Write-ReviewerCycleMetadata {}
        Mock Write-Host {}
        Mock Write-Warning {}
    }

    It 'recognizes transport closures that are safe to retry with a fresh session' -ForEach @(
        'Agent MCP session is closed.',
        'Could not write to Agent MCP.',
        'Agent MCP exited before returning a response.',
        'Agent MCP closed stdout before returning a response.',
        'Agent MCP response timed out.'
    ) {
        Test-ReviewerRecoverableMcpFailure -Message $_ | Should -BeTrue
    }

    It 'does not retry malformed or provider-rejected responses as transport closures' -ForEach @(
        'Agent MCP returned malformed JSON-RPC.',
        'Agent MCP request failed (JSON-RPC error code -32603).',
        'Unexpected reviewer failure.'
    ) {
        Test-ReviewerRecoverableMcpFailure -Message $_ | Should -BeFalse
    }

    It 'retries only once and preserves PR context if recovery still fails' {
        $script:cycleSource | Should -Match '-McpRecoveryAttempted'
        $script:cycleSource | Should -Match 'return Invoke-ReviewerCycle .* -McpRecoveryAttempted'
        $script:cycleSource | Should -Match 'Send-ReviewerEvent cycle\.failed .* -PrId \$currentPrId'
        $script:cycleSource | Should -Match 'summary = \$failureSummary'
    }

    It 'reopens a closed ADO session and completes the same cycle' {
        Mock Get-ReviewerActivePullRequests {
            $script:reviewerCalls++
            if ($script:reviewerCalls -eq 1) { throw 'Agent MCP session is closed.' }
            return @()
        }

        $result = Invoke-ReviewerCycle -AgencyPath 'agency.exe' -CycleNumber 7

        $result.ExitCode | Should -Be 0
        $script:reviewerCalls | Should -Be 2
        Should -Invoke Open-AgentMcpSession -Times 2
        Should -Invoke Close-AgentMcpSession -Times 2
        Should -Invoke Send-ReviewerEvent -Times 1 -ParameterFilter {
            $EventType -eq 'delivery.retrying' -and
            $Data.nextRetry -eq 'immediate fresh ADO session'
        }
        Should -Invoke Send-ReviewerEvent -Times 1 -ParameterFilter {
            $EventType -eq 'cycle.completed' -and $Data.result -eq 'idle'
        }
    }
}
