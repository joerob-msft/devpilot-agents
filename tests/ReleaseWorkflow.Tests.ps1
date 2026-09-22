BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $release = Get-Content -LiteralPath (Join-Path $root '.github\workflows\release.yml') -Raw
    $promotion = Get-Content -LiteralPath (Join-Path $root '.github\workflows\release-channel.yml') -Raw
    $canary = Get-Content -LiteralPath (Join-Path $root '.github\workflows\release-canary.yml') -Raw
    $releaseSkill = Get-Content -LiteralPath (
        Join-Path $root '.github\skills\devpilot-release\SKILL.md') -Raw
    $installedQualification = Get-Content -LiteralPath (
        Join-Path $root 'tools\Invoke-InstalledReleaseQualification.ps1') -Raw
    $ciRunner = Get-Content -LiteralPath (Join-Path $root 'tools\Invoke-DevPilotCi.ps1') -Raw
    function Get-WorkflowRunBlocks {
        param([Parameter(Mandatory)][string]$Text)
        @([regex]::Matches($Text, '(?m)^[ ]+run: \|\r?\n(?<body>(?:[ ]{10,}.*(?:\r?\n|$))*)') |
            ForEach-Object { $_.Groups['body'].Value })
    }
}

Describe 'Release publication boundary' {
    It 'keeps publication behind complete deterministic, installed, and live gates' {
        $release | Should -Match '(?s)publish-immutable:.*needs: \[windows-complete, platform-safety, canary-gate, installed-artifact\]'
        $release | Should -Match '(?s)immutable-smoke:.*needs: publish-immutable'
        $release | Should -Match '(?s)promote:.*needs: immutable-smoke'
        $release | Should -Match 'environment: release-publish'
        $release | Should -Match '(?s)promote:.*permissions:\s+contents: write'
        $release | Should -Not -Match 'ssh-key:'
        $release | Should -Not -Match 'create-github-app-token'
        $release | Should -Match 'git tag -a \$tagName \$env:CANDIDATE_COMMIT'
        $release.IndexOf('git tag -a $tagName $env:CANDIDATE_COMMIT') |
            Should -BeLessThan $release.LastIndexOf('Invoke-InstalledReleaseQualification.ps1')
        $release.LastIndexOf('Invoke-InstalledReleaseQualification.ps1') |
            Should -BeLessThan $release.IndexOf('gh release create $tagName')
        $release.IndexOf('gh release create $tagName') |
            Should -BeLessThan $release.IndexOf('git tag -fa v0.4')
        $release.IndexOf('git tag -fa v0.4') |
            Should -BeLessThan $release.IndexOf('push --force')
        $release | Should -Match 'exactly one compatible annotated immutable release tag'
        $release | Should -Match 'main moved after final smoke'
        $release | Should -Match 'resumePublishedTag'
        $release | Should -Match 'WORKFLOW_RUN_SHA: \$\{\{ github\.sha \}\}'
        $release | Should -Match 'Remove temporary immutable smoke cache'
    }

    It 'qualifies a clean commit-addressed consumer installation before publication' {
        $release | Should -Match "mode = 'exactCommit'"
        $release | Should -Match 'Invoke-InstalledReleaseQualification\.ps1'
        $release | Should -Match 'Install-DevPilotAgents\.Tests\.ps1'
        $release | Should -Match 'Start-DevPilot\.Tests\.ps1'
        $release.IndexOf('[IO.File]::ReadAllBytes($pinPath)') |
            Should -BeLessThan $release.IndexOf("mode = 'exactCommit'")
        $release.IndexOf('[IO.File]::WriteAllBytes($pinPath, $originalPin)') |
            Should -BeLessThan $release.IndexOf('New-PesterContainer')
        $release | Should -Match 'Remove temporary installed-artifact cache'
        $installedQualification | Should -Match 'DEVPILOT_INSTALLED_PESTER_PATHS'
        $installedQualification | Should -Match '-NoProfile -NonInteractive'
        $installedQualification | Should -Match 'Push-Location \$dashboard'
        $ciRunner | Should -Match '\$pesterPath = \$env:PATH'
        $ciRunner | Should -Match '(?s)if \(\$IsWindows\).*pwsh\.exe'
        $ciRunner | Should -Match '\./node_modules/bun/bin/bun\.exe'
        $ciRunner | Should -Match '\./dist/test/dispatch\.test\.js'
    }

    It 'makes the separate protected live canary mandatory' {
        $canary | Should -Match 'environment: release-canary'
        $canary | Should -Match 'runs-on: \[self-hosted, Windows, X64, devpilot-canary\]'
        $canary | Should -Match 'Get-Command \$command'
        $canary | Should -Match 'consecutiveRuns must be between 3 and 5'
        $canary | Should -Match 'Canary \$\{\{ inputs\.resolutionMode \}\}'
        $canary | Should -Match 'Remove temporary canary cache'
        $canary | Should -Match 'Test-DevPilotLiveCanary\.ps1'
        $canary | Should -Not -Match 'Start-DevPilot\.ps1'
        $canary | Should -Not -Match '\$env:USERPROFILE = \$env:HOME'
        $canary | Should -Match 'DEVPILOT_SELF_HOSTED_DESKTOP_MCP_AUTH: "1"'
        $canary | Should -Match 'AGENCY_VERBOSITY: error'
        $canary | Should -Match '\$env:LOCALAPPDATA = Join-Path \$env:HOME ''localappdata'''
        $release | Should -Match 'Verify mandatory live canary'
    }

    It 'allows only qualified immutable 0.4 releases to receive rollback promotion' {
        $promotion | Should -Match "mode = 'exactVersion'"
        $promotion | Should -Match 'actions: read'
        $promotion | Should -Not -Match 'ssh-key:'
        $promotion | Should -Match '(?s)qualify:.*environment: release-qualification'
        $promotion | Should -Match '(?s)promote:.*environment: release-publish'
        $promotion | Should -Match 'Target must be an annotated immutable release tag'
        $promotion | Should -Match 'exactly one compatible immutable 0\.4 patch tag'
        $promotion | Should -Match 'Re-resolve and smoke-test rollback target'
        $promotion | Should -Match 'main moved after rollback smoke'
        $promotion | Should -Match 'GH_TOKEN: \$\{\{ github\.token \}\}'
        $promotion | Should -Match 'Rollback stable GitHub Release changed during qualification'
        $promotion | Should -Match 'Remove temporary rollback cache'
        $promotion | Should -Match '(?s)git -c "core\.sshCommand=\$ssh" push --force.*refs/tags/v0\.4'
    }

    It 'keeps write credentials out of every candidate execution block' {
        foreach ($workflow in @($release, $promotion)) {
            $credentialBlocks = @(Get-WorkflowRunBlocks $workflow |
                Where-Object { $_ -match 'RELEASE_DEPLOY_KEY' })
            $credentialBlocks.Count | Should -BeGreaterThan 0
            foreach ($block in $credentialBlocks) {
                $block | Should -Not -Match 'Invoke-InstalledReleaseQualification|Install-DevPilotAgents|Invoke-Pester|npm|node --test|Test-DevPilotVersion'
                $block | Should -Match '\.Replace\("`r`n", "`n"\)'
                $block | Should -Match '\.TrimEnd\(\[char\[\]\]"`r`n"\) \+ "`n"'
                $block | Should -Match '\$\{env:USERNAME\}:\(F\)'
                $block | Should -Match 'Temporary release key cleanup failed'
            }
        }
    }

    It 'passes dispatch inputs through environment variables instead of privileged scripts' {
        foreach ($workflow in @($release, $promotion, $canary)) {
            foreach ($block in Get-WorkflowRunBlocks $workflow) {
                $block | Should -Not -Match '\$\{\{ inputs\.'
            }
        }
    }

    It 'keeps the release skill behind protected workflow boundaries' {
        $releaseSkill | Should -Match '(?m)^name: devpilot-release\r?$'
        $releaseSkill | Should -Not -Match '(?m)^allowed-tools:'
        $releaseSkill | Should -Match 'release-canary\.yml'
        $releaseSkill | Should -Match 'release\.yml'
        $releaseSkill | Should -Match 'Never create or push release tags directly'
        $releaseSkill | Should -Match 'never\s+bypass or self-approve that gate'
        $releaseSkill.IndexOf('gh workflow run release-canary.yml') |
            Should -BeLessThan $releaseSkill.IndexOf('gh workflow run release.yml')
        $releaseSkill | Should -Match 'resumePublishedTag=true'
        $releaseSkill | Should -Match 'use only\s+`release-channel\.yml`'
    }
}
