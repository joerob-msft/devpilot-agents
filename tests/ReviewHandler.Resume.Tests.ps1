BeforeAll {
    $handlerPath = "$PSScriptRoot\..\src\Agents\review-handler\Start-ReviewHandlerAgent.ps1"
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
            [string]$ResumeSessionId = 'stale-session'
        )
        $calls = New-Object System.Collections.Generic.List[hashtable]
        $responseQueue = New-Object System.Collections.Generic.Queue[hashtable]
        foreach ($response in $Responses) { $responseQueue.Enqueue($response) }
        $invoker = {
            param([hashtable]$Parameters)
            $calls.Add(@{ ArgumentList = @($Parameters.ArgumentList) })
            return $responseQueue.Dequeue()
        }.GetNewClosure()
        $rejected = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

        $launch = Invoke-HandlerCopilotLaunch `
            -AgencyPath 'agency.exe' `
            -ResumeArgumentList @('copilot', '--resume', $ResumeSessionId) `
            -FreshArgumentList @('copilot') `
            -StandardInputContent 'prompt' `
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
        $result = New-TestLaunch -Responses @(
            @{ ExitCode = 1; TimedOut = $false; StdOut = ''; StdErr = 'No session, task, or name matched: stale-session' },
            @{ ExitCode = 0; TimedOut = $false; StdOut = 'ok'; StdErr = '' }
        )

        $result.Calls.Count | Should -Be 2
        $result.Calls[0].ArgumentList | Should -Contain '--resume'
        $result.Calls[1].ArgumentList | Should -Not -Contain '--resume'
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

    It 'does not retry unrelated failures' -ForEach @(
        @{ Name = 'timeout'; Run = @{ ExitCode = -1; TimedOut = $true; StdOut = ''; StdErr = 'No session, task, or name matched' } },
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
