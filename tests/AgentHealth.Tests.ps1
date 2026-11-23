BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
    $script:sha1 = 'a' * 40
    $script:sha2 = 'b' * 40
}

Describe 'failure detail extraction' {
    It 'prefers the last Error: line and drops Agency banners, ANSI, and secret lines' {
        $stderr = "`e[36m🤖 Agency v1.2`e[0m`n📁 cwd`n✅ ready`nAuthorization: Bearer abc123`nError: first`n🚀 launching`n`e[31mError: No supported model available`e[0m`nusing token=xyz"
        Get-AgentFailureDetail -StdErr $stderr -FallbackReason 'missing marker' | Should -BeExactly 'Error: No supported model available'
    }
    It 'falls back to stdout Error:, then last non-banner stderr line, then the reason' {
        Get-AgentFailureDetail -StdErr "🤖 banner" -StdOut "x`nError: from stdout" | Should -BeExactly 'Error: from stdout'
        Get-AgentFailureDetail -StdErr "🧠 banner`nsomething broke`n🔌 mcp" | Should -BeExactly 'something broke'
        Get-AgentFailureDetail -StdErr "🤖 only banner`nBearer secret" -FallbackReason "missing  `n marker" | Should -BeExactly 'missing marker'
    }
    It 'never surfaces credential-looking lines (tokens, credentialed URLs, JWTs, SAS)' {
        foreach ($line in @('Error: push to https://x-access-token:ghp_abcdefghijklmn@github.com failed',
                'Error: password=hunter2', 'Error: "token": "abc"', 'Error: eyJhbGciOiJIUzI1NiJ9.e30.sig',
                'Error: https://acct.blob.core.windows.net/c?sv=1&sig=abcd', 'Error: api_key: 123')) {
            Get-AgentFailureDetail -StdErr "$line" -FallbackReason 'redacted fallback' | Should -BeExactly 'redacted fallback' -Because $line
        }
    }
    It 'ignores Agency MCP proxy lines and names a headless permission refusal' {
        $stderr = "🚀 Launching Copilot CLI`nLaunched 6 MCP proxies:`n  - workiq: http://127.0.0.1:63914 (log span: mcp{workiq})"
        $stdout = @(
            '{"type":"tool.execution_start","data":{"toolCallId":"c1","toolName":"powershell","arguments":{"command":"git --no-pager log -5 --format=''%H %s''"}}}'
            '{"type":"tool.execution_complete","data":{"toolCallId":"c1","success":false,"error":{"message":"Permission denied because no interactive user response was available.","code":"denied"}}}'
        ) -join "`n"
        Get-AgentDeniedToolCall -StdOut $stdout | Should -BeExactly "powershell: git --no-pager log -5 --format='%H %s'"
        Get-AgentFailureDetail -StdErr $stderr -StdOut $stdout -FallbackReason "model reported outcome 'no-safe-progress'" -ModelReported |
            Should -BeExactly "model reported outcome 'no-safe-progress'; Copilot refused without interactive approval: powershell: git --no-pager log -5 --format='%H %s'"
        Get-AgentFailureDetail -StdErr $stderr -FallbackReason "model reported outcome 'no-safe-progress'" -ModelReported |
            Should -BeExactly "model reported outcome 'no-safe-progress'"
        Get-AgentFailureDetail -StdErr $stderr -FallbackReason 'copilot exited 1' | Should -BeExactly 'copilot exited 1'
    }
    It 'truncates to 240 single-line characters' {
        $detail = Get-AgentFailureDetail -StdErr ('Error: ' + ('x' * 400))
        $detail.Length | Should -Be 240
        $detail | Should -Match '\.\.\.$'
    }
}

Describe 'failure kind' {
    It 'classifies transient, persistent, and unknown' {
        Get-AgentFailureKind -FailureDetail 'request timed out' | Should -Be 'transient'
        Get-AgentFailureKind -FailureDetail 'HTTP 429 from service' -PreviousFailureDetail 'HTTP 429 from service' | Should -Be 'transient'
        Get-AgentFailureKind -FailureDetail 'Error: No supported model available' -PreviousFailureDetail 'error: no supported  model available' | Should -Be 'persistent'
        Get-AgentFailureKind -FailureDetail 'Error: boom' -PreviousFailureDetail 'Error: other' | Should -Be 'unknown'
    }
    It 'adds failure fields only to failed/deferred work using the previous failure' {
        $data = @{ result = 'deferred'; reason = 'Error: No supported model available' }
        Add-AgentWorkFailureFields -Data $data -HealthState @{ lastFailureDetail = 'Error: No supported model available' }
        $data.failureKind | Should -Be 'persistent'
        $data.failureLogPath | Should -BeExactly ''
        $ok = @{ result = 'reviewed' }
        Add-AgentWorkFailureFields -Data $ok -HealthState $null
        $ok.ContainsKey('failureDetail') | Should -BeFalse
    }
}

Describe 'health state' {
    It 'goes failing after three consecutive failures and alerts once, then recovers once' {
        $state = New-AgentHealthState
        $alerts = foreach ($i in 1..5) {
            (Update-AgentHealthState -State $state -Result 'deferred' -PullRequestId (100 + $i) -SourceCommit $sha1 -FailureDetail 'Error: x').Alert
        }
        @($alerts | Where-Object { $_ }) | Should -BeExactly @('failing')
        $state.consecutiveFailures | Should -Be 5
        (Update-AgentHealthState -State $state -Result 'idle').State | Should -Be 'failing'
        $recovered = Update-AgentHealthState -State $state -Result 'reviewed' -PullRequestId 7 -SourceCommit $sha1
        $recovered.State | Should -Be 'healthy'
        $recovered.Alert | Should -Be 'recovered'
        (Update-AgentHealthState -State $state -Result 'reviewed' -PullRequestId 8 -SourceCommit $sha1).Alert | Should -BeNullOrEmpty
    }
    It 'marks a PR stuck after three identical outcomes, backs off to the cap, and resets on a new commit' {
        $state = New-AgentHealthState
        $now = [DateTime]::new(2026, 11, 18, 0, 0, 0, [DateTimeKind]::Utc)
        $u = $null
        foreach ($i in 1..3) { $u = Update-AgentHealthState -State $state -Result 'validation-failed' -PullRequestId 42 -SourceCommit $sha1 -Outcome 'no-safe-progress' -NowUtc $now -BaseIntervalSeconds 900 }
        $u.State | Should -Be 'stuck'
        $u.Alert | Should -Be 'stuck'
        $u.PullRequestId | Should -Be 42
        @($u.Data.stuck)[0].repeatCount | Should -Be 3
        Get-AgentHealthStuckRetryUtc -State $state -PullRequestId 42 -SourceCommit $sha1 -NowUtc $now | Should -Be $now.AddSeconds(1800)
        foreach ($i in 1..10) { $u = Update-AgentHealthState -State $state -Result 'validation-failed' -PullRequestId 42 -SourceCommit $sha1 -Outcome 'no-safe-progress' -NowUtc $now -BaseIntervalSeconds 900 }
        $u.Alert | Should -BeNullOrEmpty
        Get-AgentStuckBackoffSeconds -RepeatCount 13 -BaseSeconds 900 | Should -Be 14400
        Get-AgentHealthStuckRetryUtc -State $state -PullRequestId 42 -SourceCommit $sha2 -NowUtc $now | Should -BeNullOrEmpty
        $reset = Update-AgentHealthState -State $state -Result 'validation-failed' -PullRequestId 42 -SourceCommit $sha2 -Outcome 'no-safe-progress' -NowUtc $now
        $reset.State | Should -Be 'healthy'
        $state.prs['42'].repeatCount | Should -Be 1
    }
    It 'persists and reloads health.json and ignores a corrupt file' {
        $path = Join-Path $TestDrive 'health.json'
        $state = New-AgentHealthState
        [void](Update-AgentHealthState -State $state -Result 'failed' -PullRequestId 5 -SourceCommit $sha1 -FailureDetail 'Error: y')
        Write-AgentHealthState -Path $path -State $state | Should -BeTrue
        $loaded = Read-AgentHealthState -Path $path
        $loaded.consecutiveFailures | Should -Be 1
        $loaded.prs['5'].sourceCommit | Should -Be $sha1
        Set-Content -LiteralPath $path -Value '{not json'
        (Read-AgentHealthState -Path $path).consecutiveFailures | Should -Be 0
    }
    It 'renders alert text for failing and recovered transitions' {
        $state = New-AgentHealthState
        $u = $null
        foreach ($i in 1..3) { $u = Update-AgentHealthState -State $state -Result 'deferred' -FailureDetail 'No supported model available' }
        Get-AgentHealthAlertText -RoleLabel 'Reviewer' -Update $u -RepositoryName 'repo' | Should -Match '^DevPilot: Reviewer failing on repo - 3 failures in a row since .+: No supported model available$'
        $r = Update-AgentHealthState -State $state -Result 'reviewed' -PullRequestId 9 -SourceCommit $sha1
        Get-AgentHealthAlertText -RoleLabel 'Reviewer' -Update $r -RecoveredPullRequestId 9 | Should -BeExactly 'DevPilot: Reviewer recovered (completed PR #9)'
    }
}

Describe 'operator skip file' {
    It 'holds a candidate only at the skipped commit and ignores invalid files' {
        $dir = Join-Path $TestDrive 'role'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $file = Join-Path $dir 'skipped-prs.json'
        @{ schemaVersion = 1; entries = @(
                @{ repositoryKey = 'v1:ado:org:proj:repo'; pullRequestId = 77; sourceCommit = $sha1; skippedAtUtc = '2026-11-18T00:00:00Z' },
                @{ repositoryKey = 'v1:ado:org:proj:repo'; pullRequestId = -1; sourceCommit = 'nothex' },
                @{ repositoryKey = ''; pullRequestId = 88; sourceCommit = $sha1 }) } |
            ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $file
        Get-AgentCandidateHold -StateDir $dir -HealthState $null -RepositoryKey 'v1:ado:org:proj:repo' -PullRequestId 88 -SourceCommit $sha1 |
            Should -BeNullOrEmpty -Because 'a skip without a repository key must not apply to every repository'
        $hold = Get-AgentCandidateHold -StateDir $dir -HealthState $null -RepositoryKey 'v1:ado:org:proj:repo' -PullRequestId 77 -SourceCommit $sha1
        $hold.Kind | Should -Be 'operatorSkipped'
        $hold.Message | Should -BeExactly 'PR 77 skipped by operator until a new commit'
        Get-AgentCandidateHold -StateDir $dir -HealthState $null -PullRequestId 77 -SourceCommit $sha2 | Should -BeNullOrEmpty
        Get-AgentCandidateHold -StateDir $dir -HealthState $null -RepositoryKey 'v1:ado:other' -PullRequestId 77 -SourceCommit $sha1 | Should -BeNullOrEmpty
        Set-Content -LiteralPath $file -Value 'garbage'
        Get-AgentCandidateHold -StateDir $dir -HealthState $null -PullRequestId 77 -SourceCommit $sha1 | Should -BeNullOrEmpty
    }
}

Describe 'model preflight' {
    It 'runs the agency copilot path from a temp directory and succeeds on exit 0' {
        $script:seen = $null
        $launcher = { param($Path, $Arguments, $WorkDir, $Timeout) $script:seen = @{ Path = $Path; Args = $Arguments; Dir = $WorkDir; Exists = (Test-Path $WorkDir) }; @{ ExitCode = 0; StdOut = 'OK'; StdErr = '' } }
        (Invoke-AgentModelPreflight -Model 'gpt-x' -AgencyPath 'fake-agency' -Launcher $launcher).Succeeded | Should -BeTrue
        $seen.Path | Should -Be 'fake-agency'
        $seen.Args[0..1] | Should -BeExactly @('copilot', '--')
        ($seen.Args -join ' ') | Should -Match '--model gpt-x --name=\[DevPilot\] model preflight --session-id=[0-9a-f-]{36}'
        $seen.Exists | Should -BeTrue
        $seen.Dir | Should -BeLike "$([IO.Path]::GetTempPath())*"
        Test-Path $seen.Dir | Should -BeFalse
    }
    It 'throws the operator-facing message with the sanitized failure detail' {
        $launcher = { param($Path, $Arguments, $WorkDir, $Timeout) @{ ExitCode = 1; StdOut = ''; StdErr = "🤖 Agency`nAuthorization: Bearer s3cret`nError: No supported model available" } }
        { Assert-AgentModelPreflight -Models @('m1', 'm1') -Launcher $launcher } |
            Should -Throw "DevPilot model preflight failed for model 'm1': Error: No supported model available. Choose a supported model (copilot --help) or pass -SkipModelPreflight."
    }
    It 'reports timeouts and describes the plan line, including skip' {
        $launcher = { param($Path, $Arguments, $WorkDir, $Timeout) @{ ExitCode = -1; TimedOut = $true } }
        (Invoke-AgentModelPreflight -Model 'm' -TimeoutSeconds 5 -Launcher $launcher).FailureDetail | Should -Be 'timed out after 5 s'
        Get-AgentModelPreflightPlanLine -Models @('a', 'b', 'a') | Should -BeExactly '  Model preflight     : will verify a, b before starting agents'
        Get-AgentModelPreflightPlanLine -Models @('a') -Skip | Should -BeExactly '  Model preflight     : skipped (-SkipModelPreflight)'
    }
    It 'is wired into Watch after ShouldProcess with a -SkipModelPreflight opt-out' {
        $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\tools\Watch-DevPilotAgents.ps1') -Raw
        $source | Should -Match '\[switch\]\$SkipModelPreflight'
        $source.IndexOf('Assert-AgentModelPreflight') | Should -BeGreaterThan $source.IndexOf('$PSCmdlet.ShouldProcess(')
        $validated = $source.IndexOf("Assert-AgentSupportedModel -ModelId `$model -Where 'model preflight'")
        $validated | Should -BeGreaterThan -1
        $validated | Should -BeLessThan $source.IndexOf('Assert-AgentModelPreflight -Models') -Because 'model names are validated before any process starts'
        $source | Should -Match 'Get-AgentModelPreflightPlanLine'
    }
}

Describe 'review-handler unattended shell guidance' {
    It 'gives the model the wrapper-captured git state and warns about refused % commands' {
        $source = Get-Content -Raw (Join-Path $PSScriptRoot '..\src\Agents\review-handler\Start-ReviewHandlerAgent.ps1')
        $source | Should -Match '-LocalGitState \$localGitState'
        $source | Should -Match 'log -5 --oneline'
        $source | Should -Match 'containing a ``%`` character'
        $source | Should -Match '-ModelReported:\(\$run\.ExitCode -eq 0'
    }
}

Describe 'model preflight session arguments' {
    It 'names only a brand-new session and reports the Copilot CLI error, not the Agency wrapper' {
        $box = @{}
        $launcher = {
            param($Path, $Arguments, $WorkDir, $Timeout)
            $box.Arguments = $Arguments
            @{ ExitCode = 1; StdOut = ''; StdErr = "error: option '-n, --name <name>' cannot be used with option '--session-id <id>'`nError: Agent execution failed: launch_engine - copilot.exe exited with non-zero status (exit code: 1)" }
        }
        $launcher = $launcher.GetNewClosure()
        $probe = Invoke-AgentModelPreflight -Model 'gpt-x' -AgencyPath 'fake-agency' -Launcher $launcher
        $captured = $box.Arguments
        $probe.FailureDetail | Should -BeExactly "error: option '-n, --name <name>' cannot be used with option '--session-id <id>'"
        @($captured | Where-Object { $_ -match '^--session-id=[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' }).Count | Should -Be 1
        $captured | Should -Contain '--name=[DevPilot] model preflight'
    }
}