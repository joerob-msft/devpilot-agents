BeforeAll {
    # [Parser]::ParseFile is a raw .NET API, not a PowerShell provider cmdlet,
    # so it never normalizes a literal backslash-joined string the way
    # Resolve-Path/Get-Content do; on Unix it would look for a single file
    # literally named "..\src\Agents\...\Start-ReviewHandlerAgent.ps1" and
    # fail to find it. Resolve to an OS-native absolute path first.
    $handlerPath = (Resolve-Path "$PSScriptRoot\..\src\Agents\review-handler\Start-ReviewHandlerAgent.ps1").Path
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $handlerPath,
        [ref]$tokens,
        [ref]$parseErrors
    )
    $parseErrors | Should -BeNullOrEmpty

    $functionNames = @(
        'Get-HandlerUsableSessionMatches',
        'Test-HandlerUnknownResumeTarget',
        'Invoke-HandlerCopilotLaunch'
    )
    $definitions = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $functionNames -contains $node.Name
        }, $true)
    foreach ($definition in $definitions) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    function New-TestLaunch {
        param(
            [Parameter(Mandatory)][hashtable[]]$Responses,
            [string]$ResumeSessionId = 'stale-session',
            [string]$StandardInputContent = 'prompt'
        )
        $calls = New-Object System.Collections.Generic.List[hashtable]
        $responseQueue = New-Object System.Collections.Generic.Queue[hashtable]
        foreach ($response in $Responses) { $responseQueue.Enqueue($response) }
        $invoker = {
            param([hashtable]$Parameters)
            $calls.Add(@{
                    ArgumentList = @($Parameters.ArgumentList)
                    StandardInputContent = [string]$Parameters.StandardInputContent
                    WorkingDirectory = [string]$Parameters.WorkingDirectory
                    TimeoutSeconds = [int]$Parameters.TimeoutSeconds
                })
            return $responseQueue.Dequeue()
        }.GetNewClosure()
        $rejected = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

        $launch = Invoke-HandlerCopilotLaunch `
            -AgencyPath 'agency.exe' `
            -ResumeArgumentList @('copilot', '--resume', $ResumeSessionId) `
            -FreshArgumentList @('copilot') `
            -StandardInputContent $StandardInputContent `
            -WorkingDirectory $TestDrive `
            -EnvironmentVariablesToRemove @() `
            -TimeoutSeconds 30 `
            -ResumeSessionId $ResumeSessionId `
            -RejectedSessionIds $rejected `
            -ProcessInvoker $invoker

        return @{
            Launch   = $launch
            Calls    = $calls
            Rejected = $rejected
        }
    }
}

Describe 'review-handler resume fallback' {
    It 'retries an unknown resume target exactly once without --resume' {
        $payload = 'Primary handler skill: C:\consumer\.github\skills\handler\SKILL.md'
        $result = New-TestLaunch -StandardInputContent $payload -Responses @(
            @{ ExitCode = 1; TimedOut = $false; StdOut = ''; StdErr = 'No session, task, or name matched: stale-session' },
            @{ ExitCode = 0; TimedOut = $false; StdOut = 'ok'; StdErr = '' }
        )

        $result.Calls.Count | Should -Be 2
        $result.Calls[0].ArgumentList | Should -Contain '--resume'
        $result.Calls[1].ArgumentList | Should -Not -Contain '--resume'
        $result.Calls[0].StandardInputContent | Should -BeExactly $payload
        $result.Calls[1].StandardInputContent | Should -BeExactly $payload
        $result.Calls[0].WorkingDirectory | Should -BeExactly $TestDrive
        $result.Calls[1].WorkingDirectory | Should -BeExactly $TestDrive
        $result.Launch.RetriedFresh | Should -BeTrue
        $result.Launch.Run.ExitCode | Should -Be 0
        $result.Rejected.Contains('stale-session') | Should -BeTrue
    }

    It 'does not retry a successful resume' {
        $result = New-TestLaunch -Responses @(
            @{ ExitCode = 0; TimedOut = $false; StdOut = 'ok'; StdErr = '' }
        )

        $result.Calls.Count | Should -Be 1
        $result.Launch.RetriedFresh | Should -BeFalse
    }

    It 'retries a timed-out resume once with a fresh session inside the cycle budget' {
        $result = New-TestLaunch -Responses @(
            @{ ExitCode = -1; TimedOut = $true; StdOut = ''; StdErr = '' },
            @{ ExitCode = 0; TimedOut = $false; StdOut = 'ok'; StdErr = '' }
        )

        $result.Calls.Count | Should -Be 2
        $result.Calls[0].ArgumentList | Should -Contain '--resume'
        $result.Calls[1].ArgumentList | Should -Not -Contain '--resume'
        $result.Calls[0].TimeoutSeconds | Should -BeLessOrEqual 30
        $result.Calls[1].TimeoutSeconds | Should -BeLessOrEqual 30
        $result.Launch.RetriedFresh | Should -BeTrue
        $result.Launch.Run.ExitCode | Should -Be 0
        $result.Rejected.Contains('stale-session') | Should -BeTrue
    }

    It 'does not retry unrelated failures' -ForEach @(
        @{ Name = 'authentication'; Run = @{ ExitCode = 1; TimedOut = $false; StdOut = ''; StdErr = 'No authentication information found' } },
        @{ Name = 'tool failure'; Run = @{ ExitCode = 1; TimedOut = $false; StdOut = ''; StdErr = 'failed to start MCP server ado' } },
        @{ Name = 'arbitrary exit'; Run = @{ ExitCode = 17; TimedOut = $false; StdOut = ''; StdErr = 'unexpected failure' } }
    ) {
        $result = New-TestLaunch -Responses @($Run)

        $result.Calls.Count | Should -Be 1
        $result.Launch.RetriedFresh | Should -BeFalse
    }

    It 'returns a failed fresh retry without looping' {
        $result = New-TestLaunch -Responses @(
            @{ ExitCode = 1; TimedOut = $false; StdOut = ''; StdErr = 'No session, task, or name matched' },
            @{ ExitCode = 9; TimedOut = $false; StdOut = ''; StdErr = 'fresh launch failed' }
        )

        $result.Calls.Count | Should -Be 2
        $result.Launch.RetriedFresh | Should -BeTrue
        $result.Launch.Run.ExitCode | Should -Be 9
        $result.Launch.Run.StdErr | Should -Be 'fresh launch failed'
    }

    It 'excludes a rejected session from later selection in the same run' {
        $rejected = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        [void]$rejected.Add('stale-session')
        $sessions = @(
            [pscustomobject]@{ SessionId = 'stale-session' },
            [pscustomobject]@{ SessionId = 'usable-session' }
        )

        $usable = Get-HandlerUsableSessionMatches -Sessions $sessions -RejectedSessionIds $rejected

        $usable.Count | Should -Be 1
        $usable[0].SessionId | Should -Be 'usable-session'
    }
}

Describe 'coding-session resolution never resumes DevPilot cycle sessions' {
    BeforeAll {
        Import-Module "$PSScriptRoot\..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1" -Force
        function New-TestSession {
            param([string]$Root, [string]$Id, [string]$NameLine, [string]$UpdatedAt)
            $dir = New-Item -ItemType Directory -Path (Join-Path $Root $Id) -Force
            $lines = @("id: $Id", 'branch: feature/x', "updated_at: $UpdatedAt")
            if ($NameLine) { $lines += $NameLine }
            Set-Content -LiteralPath (Join-Path $dir.FullName 'workspace.yaml') -Value $lines -Encoding utf8NoBOM
        }
    }

    It 'excludes named, prompt-titled, and explicitly excluded sessions and keeps the human coding session' {
        $root = Join-Path $TestDrive 'session-state'
        $dash = [char]0x2014
        New-TestSession -Root $root -Id 'human' -NameLine 'name: Fix the flaky test' -UpdatedAt '2026-01-01T00:00:00Z'
        New-TestSession -Root $root -Id 'named-cycle' -NameLine 'name: "[DevPilot] Review-handler cycle PR 7"' -UpdatedAt '2026-01-05T00:00:00Z'
        New-TestSession -Root $root -Id 'legacy-handler' -NameLine "name: `"# Review-Handler Agent $dash Operational Cycle Prompt`"" -UpdatedAt '2026-01-04T00:00:00Z'
        New-TestSession -Root $root -Id 'legacy-reviewer' -NameLine "name: |`n  # Reviewer Agent $dash Operational Cycle Prompt" -UpdatedAt '2026-01-03T00:00:00Z'
        New-TestSession -Root $root -Id 'launched-here' -UpdatedAt '2026-01-02T00:00:00Z'

        $found = @(Find-CopilotSessionForBranch -Branch 'refs/heads/feature/x' -SessionStateRoot $root -ExcludeSessionIds @('LAUNCHED-HERE'))
        @($found.SessionId) | Should -BeExactly @('human')
        @(Find-CopilotSessionForBranch -Branch 'feature/x' -SessionStateRoot $root).SessionId |
            Should -BeExactly @('launched-here', 'human')
    }

    It 'names new cycle sessions and never names a resumed one' {
        Get-AgentHarnessCycleSessionName -Role review-handler -PullRequestId 42 | Should -BeExactly '[DevPilot] Review-handler cycle PR 42'
        Test-AgentHarnessCycleSessionName -Name (Get-AgentHarnessCycleSessionName -Role reviewer) | Should -BeTrue
        Test-AgentHarnessCycleSessionName -Name 'DevPilot notes' | Should -BeFalse
        $fresh = Get-AgentCopilotArgs -SessionName '[DevPilot] Reviewer cycle PR 1'
        $fresh | Should -Contain '--name=[DevPilot] Reviewer cycle PR 1'
        $resumed = Get-AgentCopilotArgs -SessionName '[DevPilot] Reviewer cycle PR 1' -ResumeSessionId ([Guid]::NewGuid().ToString())
        @($resumed | Where-Object { $_ -like '--name*' }) | Should -BeNullOrEmpty
        { Get-AgentCopilotArgs -SessionName 'bad"name' } | Should -Throw '*unsupported characters*'
    }
}
