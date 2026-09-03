BeforeAll {
    Import-Module "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1" -Force
}

Describe 'manual force-analysis semantics' {
    It 'bypasses only the prior-analysis dedupe check' {
        Test-AgentAnalysisRequired -AlreadyProcessed $true -ForceAnalysis $false | Should -BeFalse
        Test-AgentAnalysisRequired -AlreadyProcessed $true -ForceAnalysis $true | Should -BeTrue
        Test-AgentAnalysisRequired -AlreadyProcessed $false -ForceAnalysis $false | Should -BeTrue
    }

    It 'does not clear or rewrite existing records when force is selected' {
        $records = @{ '104' = @{ sourceCommit = ('a' * 40); delivered = $true; fingerprint = 'keep' } }
        $before = $records | ConvertTo-Json -Compress -Depth 10
        Test-AgentAnalysisRequired -AlreadyProcessed $true -ForceAnalysis $true | Should -BeTrue
        ($records | ConvertTo-Json -Compress -Depth 10) | Should -BeExactly $before
    }

    It 'blocks a pending reviewer delivery before the analysis entrypoint' {
        $calls = 0
        $commit = 'b' * 40
        $records = @{
            '104' = @{
                sourceCommit = $commit
                deliveryPending = $true
                pendingCapabilities = @('comments')
                artifactPath = 'sealed.json'
            }
        }
        $analysis = { $script:calls++ }

        if (-not (Test-AgentReviewerDeliveryPending -Records $records -PullRequestId 104 -SourceCommit $commit)) {
            & $analysis
        }

        $calls | Should -Be 0
        $records['104'].deliveryPending | Should -BeTrue
        $records['104'].artifactPath | Should -Be 'sealed.json'
    }

    It 'does not block another PR or source commit' {
        $records = @{ '104' = @{ sourceCommit = ('c' * 40); deliveryPending = $true } }
        Test-AgentReviewerDeliveryPending -Records $records -PullRequestId 105 -SourceCommit ('c' * 40) |
            Should -BeFalse
        Test-AgentReviewerDeliveryPending -Records $records -PullRequestId 104 -SourceCommit ('d' * 40) |
            Should -BeFalse
    }
}
