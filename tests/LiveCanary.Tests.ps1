BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $scriptPath = Join-Path $root 'tools\Test-DevPilotLiveCanary.ps1'
    $source = Get-Content -LiteralPath $scriptPath -Raw
}

Describe 'Protected live canary contract' {
    It 'parses and performs only explicit ADO and WorkIQ reads' {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $scriptPath, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        $source | Should -Match 'Resolve-AgentProviderRepositoryIdentity'
        $source | Should -Match 'Get-AgentProviderPullRequestSnapshot'
        $source | Should -Match "Invoke-AgentWorkIqTool[\s\S]+-Name fetch"
        $source | Should -Not -Match 'Start-DevPilotDashboard|Start-ReviewerAgent|Start-ReviewHandlerAgent'
        $source | Should -Not -Match 'create_entity|repo_pull_request_write|repo_pull_request_thread_write'
    }

    It 'requires active non-draft snapshots and a successful WorkIQ read' {
        $source | Should -Match '\$snapshot\.prId'
        $source | Should -Match '\$snapshot\.status'
        $source | Should -Match '\$snapshot\.isDraft'
        $source | Should -Match 'WorkIQ /me read returned no data'
        $source | Should -Match 'workIqVerified = \$true'
    }
}
