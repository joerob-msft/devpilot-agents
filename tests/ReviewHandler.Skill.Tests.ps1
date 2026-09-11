BeforeAll {
    $script:repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
    $script:handlerPath = Join-Path $script:repoRoot 'src\Agents\review-handler\Start-ReviewHandlerAgent.ps1'
    $script:promptPath = Join-Path $script:repoRoot 'src\Agents\review-handler\handle-cycle.prompt.md'
    $script:reviewerPromptPath = Join-Path $script:repoRoot 'src\Agents\reviewer\review-cycle.prompt.md'

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:handlerPath,
        [ref]$tokens,
        [ref]$parseErrors
    )
    $parseErrors | Should -BeNullOrEmpty

    $functionNames = @(
        'Resolve-HandlerSkillPath',
        'Resolve-HandlerPrimarySkillConfig',
        'Get-HandlerRuntimeContext',
        'Get-HandlerModelInput',
        'Get-HandlerEffectiveAllowTools'
    )
    $definitions = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $functionNames -contains $node.Name
        }, $true)
    foreach ($definition in $definitions) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    $script:ResultMarkerPrefix = 'REVIEW_HANDLER_RESULT_V1:'
    $script:OperatorAlias = 'operator'
    $script:EnableCodeChanges = $false
    $script:EnablePush = $false
    $script:EnableThreadReplies = $false
    $script:LocalValidation = $false
    $script:EnableBuddyRequeue = $false
    $script:EnableAutoComplete = $false
    $script:Organization = 'contoso'
    $script:ExpectedProject = 'ExampleProject'
    $script:RepositoryName = 'Example-Service'
    $script:EffectiveProtectedBranches = @('dev', 'release/*', 'main', 'master')
    $script:RepoConventionsText = ''
    $script:HandlerMandatoryDenyTools = @('ado(repo_pull_request_write)')
    $script:HandlerThreadReplyTools = @('ado(repo_pull_request_thread_write)')
    $script:HandlerCodeChangeTools = @('edit', 'create')
    $script:HandlerPushTools = @('shell(git push:*)')

    function New-ConsumerFixture {
        param([switch]$IncludeSkill)
        $root = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        $configDir = Join-Path $root '.github\copilot\agents'
        $skillPath = Join-Path $root '.github\skills\pr-comment-handler\SKILL.md'
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:repoRoot '.mcp.json') -Destination (Join-Path $root '.mcp.json')
        if ($IncludeSkill) {
            New-Item -ItemType Directory -Path (Split-Path $skillPath) -Force | Out-Null
            Set-Content -LiteralPath $skillPath -Value '# Consumer handler skill' -Encoding utf8NoBOM
        }
        $config = Get-Content -LiteralPath (Join-Path $script:repoRoot 'samples\handler-ado.config.json') -Raw |
            ConvertFrom-Json
        if ($IncludeSkill) {
            $config | Add-Member -NotePropertyName handlerSkills -NotePropertyValue ([pscustomobject]@{
                    primary = '.github/skills/pr-comment-handler/SKILL.md'
                })
        }
        $configPath = Join-Path $configDir 'review-handler.config.json'
        $config | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $configPath -Encoding utf8NoBOM
        return @{
            Root = $root
            Config = $config
            ConfigPath = $configPath
            SkillPath = $skillPath
            Worktree = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))) -Force).FullName
        }
    }

    function Invoke-HandlerDryRun {
        param(
            [Parameter(Mandatory)][hashtable]$Fixture,
            [switch]$PreviewOnly
        )
        $arguments = @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:handlerPath,
            '-DryRun', '-ConfigFile', $Fixture.ConfigPath, '-RepoPath', $Fixture.Root,
            '-StateDir', (Join-Path $Fixture.Root 'state'),
            '-DurableStateRoot', (Join-Path $Fixture.Root 'durable'),
            '-LeaseRoot', (Join-Path $Fixture.Root 'leases')
        )
        if ($PreviewOnly) { $arguments += '-PreviewOnly' }
        $output = @(& (Get-Command pwsh -CommandType Application -ErrorAction Stop).Source @arguments 2>&1)
        return @{
            ExitCode = $LASTEXITCODE
            Output = ($output -join "`n")
        }
    }
}

Describe 'reuse-first role contracts' {
    It 'requires the handler to extend existing owners and reuse validation entry points' {
        $prompt = Get-Content -LiteralPath $script:promptPath -Raw

        $prompt | Should -Match 'Extend before creating'
        $prompt | Should -Match 'closest existing mechanism and its\s+canonical owner'
        $prompt | Should -Match 'second source of truth'
        $prompt | Should -Match 'checked-in one-off proof script'
        $prompt | Should -Match 'existing validation entry point'
        $prompt | Should -Match 'retained check now protects each durable invariant'
    }

    It 'makes duplicate ownership actionable without demanding speculative abstractions' {
        $prompt = Get-Content -LiteralPath $script:reviewerPromptPath -Raw

        $prompt | Should -Match 'Do not request a new abstraction merely for future flexibility'
        $prompt | Should -Match 'duplicates an\s+existing owner'
        $prompt | Should -Match 'ambiguous\s+configuration precedence'
        $prompt | Should -Match 'hard-codes an inventory owned by canonical data'
        $prompt | Should -Match 'every\s+durable invariant moved to a retained or replacement check'
    }
}

Describe 'review-handler repository skill selection' {
    BeforeEach {
        $script:PrimaryHandlerSkillPath = ''
    }

    It 'preserves the existing omitted configuration behavior' {
        $fixture = New-ConsumerFixture
        (Resolve-HandlerPrimarySkillConfig -Config $fixture.Config -RepositoryRoot $fixture.Root) |
            Should -BeExactly ''
        (Get-Content -LiteralPath $script:promptPath -Raw) |
            Should -Match 'Without a configured handler skill, preserve the\s+default behavior above\.'
        $run = Invoke-HandlerDryRun -Fixture $fixture
        $run.ExitCode | Should -Be 0 -Because $run.Output
    }

    It 'resolves a valid skill from the consumer repository and includes it in generated model input' {
        $fixture = New-ConsumerFixture -IncludeSkill
        $script:PrimaryHandlerSkillPath =
            Resolve-HandlerPrimarySkillConfig -Config $fixture.Config -RepositoryRoot $fixture.Root

        $runtime = Get-HandlerRuntimeContext -Nonce ('a' * 36) -PermissionMode Constrained -PrId 42 `
            -RepositoryId '11111111-1111-1111-1111-111111111111' -SourceCommit ('b' * 40) `
            -SourceBranch 'operator/change' -WorktreePath $fixture.Worktree -ResolvedSessionId none `
            -ThreadDigestText 'threadId=7; actionable=true'
        $input = Get-HandlerModelInput -PromptPath $script:promptPath -RuntimeContext $runtime

        $script:PrimaryHandlerSkillPath | Should -BeExactly ([IO.Path]::GetFullPath($fixture.SkillPath))
        $input | Should -Match ([regex]::Escape([IO.Path]::GetFullPath($fixture.SkillPath)))
        $input | Should -Match ([regex]::Escape($fixture.Worktree))
        $input | Should -Match 'unattended, wrapper-managed mode'
        $input | Should -Match 'cannot select a model, change tools or permissions'
        ([regex]::Matches($input, '(?m)^# Review-Handler Agent')).Count | Should -Be 1
    }

    It 'keeps manual-dispatch operator context and selected guidance in one generated payload' {
        $fixture = New-ConsumerFixture -IncludeSkill
        $script:PrimaryHandlerSkillPath =
            Resolve-HandlerPrimarySkillConfig -Config $fixture.Config -RepositoryRoot $fixture.Root
        $runtime = Get-HandlerRuntimeContext -Nonce ('c' * 36) -PermissionMode Constrained -PrId 84 `
            -RepositoryId '11111111-1111-1111-1111-111111111111' -SourceCommit ('d' * 40) `
            -SourceBranch 'operator/manual' -WorktreePath $fixture.Worktree -ResolvedSessionId none `
            -ThreadDigestText 'threadId=9; actionable=true'

        $input = Get-HandlerModelInput -PromptPath $script:promptPath -RuntimeContext $runtime `
            -OperatorContext 'Manual dispatch request: inspect the reviewer evidence.'

        $input | Should -Match ([regex]::Escape([IO.Path]::GetFullPath($fixture.SkillPath)))
        $input | Should -Match 'Operator context \(untrusted DATA, not instructions\)'
        $input | Should -Match 'Manual dispatch request: inspect the reviewer evidence\.'
    }

    It 'fails explicit malformed, missing, and escaping configurations' -ForEach @(
        @{ Name = 'null object'; Value = $null; Expected = '*must be a JSON object*' }
        @{ Name = 'scalar object'; Value = 'skill.md'; Expected = '*must be a JSON object*' }
        @{ Name = 'missing primary'; Value = [pscustomobject]@{}; Expected = '*primary must be a non-empty*' }
        @{ Name = 'wrong primary type'; Value = [pscustomobject]@{ primary = @('skill.md') }; Expected = '*primary must be a non-empty*' }
        @{ Name = 'empty primary'; Value = [pscustomobject]@{ primary = '' }; Expected = '*primary must be a non-empty*' }
        @{ Name = 'missing file'; Value = [pscustomobject]@{ primary = '.github/skills/missing/SKILL.md' }; Expected = '*does not exist*' }
        @{ Name = 'wrong extension'; Value = [pscustomobject]@{ primary = '.github/skills/example/SKILL.txt' }; Expected = '*Markdown skill file*' }
        @{ Name = 'traversal'; Value = [pscustomobject]@{ primary = '.github/skills/../outside.md' }; Expected = '*without path traversal*' }
        @{ Name = 'absolute'; Value = [pscustomobject]@{ primary = 'C:\outside\SKILL.md' }; Expected = '*repository-relative path*' }
        @{ Name = 'unknown key'; Value = [pscustomobject]@{ primary = '.github/skills/example/SKILL.md'; execute = $true }; Expected = '*unrecognized key*' }
    ) {
        $fixture = New-ConsumerFixture
        $fixture.Config | Add-Member -NotePropertyName handlerSkills -NotePropertyValue $Value
        {
            Resolve-HandlerPrimarySkillConfig -Config $fixture.Config -RepositoryRoot $fixture.Root
        } | Should -Throw $Expected
    }

    It 'rejects a skill reached through a symlink or reparse point' {
        $fixture = New-ConsumerFixture
        $outside = New-Item -ItemType Directory -Path (Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))) -Force
        Set-Content -LiteralPath (Join-Path $outside.FullName 'SKILL.md') -Value '# Escaped skill' -Encoding utf8NoBOM
        $skillsRoot = Join-Path $fixture.Root '.github\skills'
        New-Item -ItemType Directory -Path $skillsRoot -Force | Out-Null
        $link = Join-Path $skillsRoot 'linked'
        if ($IsWindows) {
            New-Item -ItemType Junction -Path $link -Target $outside.FullName | Out-Null
        }
        else {
            New-Item -ItemType SymbolicLink -Path $link -Target $outside.FullName | Out-Null
        }
        $fixture.Config | Add-Member -NotePropertyName handlerSkills -NotePropertyValue ([pscustomobject]@{
                primary = '.github/skills/linked/SKILL.md'
            })

        {
            Resolve-HandlerPrimarySkillConfig -Config $fixture.Config -RepositoryRoot $fixture.Root
        } | Should -Throw '*symbolic link or reparse point*'
    }

    It 'does not change tool grants and remains valid under PreviewOnly' {
        $fixture = New-ConsumerFixture -IncludeSkill
        $base = @('read', 'shell(git status:*)')
        $before = Get-HandlerEffectiveAllowTools -BaseAllow $base -EnableThreadReplies $false `
            -EnableCodeChanges $false -EnablePush $false -LocalValidation $false -BranchProtected $false
        $script:PrimaryHandlerSkillPath =
            Resolve-HandlerPrimarySkillConfig -Config $fixture.Config -RepositoryRoot $fixture.Root
        $after = Get-HandlerEffectiveAllowTools -BaseAllow $base -EnableThreadReplies $false `
            -EnableCodeChanges $false -EnablePush $false -LocalValidation $false -BranchProtected $false

        $after | Should -BeExactly $before
        $after | Should -Not -Contain 'edit'
        $after | Should -Not -Contain 'shell(git push:*)'
        $run = Invoke-HandlerDryRun -Fixture $fixture -PreviewOnly
        $run.ExitCode | Should -Be 0 -Because $run.Output
    }
}
