BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $release = Get-Content -LiteralPath (Join-Path $root '.github\workflows\release.yml') -Raw
    $promotion = Get-Content -LiteralPath (Join-Path $root '.github\workflows\release-channel.yml') -Raw
    $canary = Get-Content -LiteralPath (Join-Path $root '.github\workflows\release-canary.yml') -Raw
    $installedQualification = Get-Content -LiteralPath (
        Join-Path $root 'tools\Invoke-InstalledReleaseQualification.ps1') -Raw
    function Get-WorkflowRunBlocks {
        param([Parameter(Mandatory)][string]$Text)
        @([regex]::Matches($Text, '(?m)^[ ]+run: \|\r?\n(?<body>(?:[ ]{10,}.*(?:\r?\n|$))*)') |
            ForEach-Object { $_.Groups['body'].Value })
    }
}

Describe 'Release publication boundary' {
    It 'keeps publication behind complete deterministic, installed, and live gates' {
        $release | Should -Match 'needs: \[windows-complete, platform-safety, canary-gate, installed-artifact\]'
        $release | Should -Match 'environment: release-publish'
        $release | Should -Match 'ssh-key: \$\{\{ secrets\.RELEASE_DEPLOY_KEY \}\}'
        $release | Should -Match '(?s)publish:.*permissions:\s+contents: write'
        $release | Should -Not -Match 'create-github-app-token'
        $release | Should -Match 'git tag -a \$tagName \$env:CANDIDATE_COMMIT'
        $release.IndexOf('Invoke-InstalledReleaseQualification.ps1') |
            Should -BeLessThan $release.IndexOf('gh release create $tagName')
        $release.IndexOf('gh release create $tagName') |
            Should -BeLessThan $release.IndexOf('git push --force origin refs/tags/v0.4')
        $release | Should -Match 'exactly one compatible annotated immutable release tag'
        $release | Should -Match 'main moved after final smoke'
        $release | Should -Match 'resumePublishedTag'
        $release | Should -Match 'WORKFLOW_RUN_SHA: \$\{\{ github\.sha \}\}'
        $release | Should -Match 'Remove temporary publication cache'
    }

    It 'qualifies a clean commit-addressed consumer installation before publication' {
        $release | Should -Match "mode = 'exactCommit'"
        $release | Should -Match 'Invoke-InstalledReleaseQualification\.ps1'
        $release | Should -Match 'Install-DevPilotAgents\.Tests\.ps1'
        $release | Should -Match 'Start-DevPilot\.Tests\.ps1'
        $release | Should -Match 'Remove temporary installed-artifact cache'
        $installedQualification | Should -Match 'DEVPILOT_INSTALLED_PESTER_PATHS'
        $installedQualification | Should -Match '-NoProfile -NonInteractive'
        $installedQualification | Should -Match 'Push-Location \$dashboard'
    }

    It 'makes the separate protected live canary mandatory' {
        $canary | Should -Match 'environment: release-canary'
        $canary | Should -Match 'runs-on: \[self-hosted, Windows, X64, devpilot-canary\]'
        $canary | Should -Match 'Get-Command \$command'
        $canary | Should -Match 'PreviewOnly = \$true'
        $canary | Should -Match 'consecutiveRuns must be between 3 and 5'
        $canary | Should -Match 'Canary \$\{\{ inputs\.resolutionMode \}\}'
        $canary | Should -Match 'Remove temporary canary cache'
        $release | Should -Match 'Verify mandatory live canary'
    }

    It 'allows only qualified immutable 0.4 releases to receive rollback promotion' {
        $promotion | Should -Match "mode = 'exactVersion'"
        $promotion | Should -Match 'actions: read'
        $promotion | Should -Match 'ssh-key: \$\{\{ secrets\.RELEASE_DEPLOY_KEY \}\}'
        $promotion | Should -Match 'Target must be an annotated immutable release tag'
        $promotion | Should -Match 'exactly one compatible immutable 0\.4 patch tag'
        $promotion | Should -Match 'Re-resolve and smoke-test rollback target'
        $promotion | Should -Match 'main moved after rollback smoke'
        $promotion | Should -Match 'GH_TOKEN: \$\{\{ github\.token \}\}'
        $promotion | Should -Match 'Rollback stable GitHub Release changed during qualification'
        $promotion | Should -Match 'Remove temporary rollback cache'
        $promotion | Should -Match 'git push --force origin refs/tags/v0.4'
    }

    It 'passes dispatch inputs through environment variables instead of privileged scripts' {
        foreach ($workflow in @($release, $promotion, $canary)) {
            foreach ($block in Get-WorkflowRunBlocks $workflow) {
                $block | Should -Not -Match '\$\{\{ inputs\.'
            }
        }
    }
}
