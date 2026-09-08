BeforeAll {
    $script:modulePath = Join-Path $PSScriptRoot '..\src\DevPilot.AgentHarness\DevPilot.AgentHarness.psd1'
    Import-Module $modulePath -Force
    # Deliberately outside both the worktree and checkout, not in a system
    # temporary directory. All child processes and fault injection stay here.
    $script:fixtureRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\..\..\TeamsThreading-fixtures-$([Guid]::NewGuid().ToString('N'))"))
    $null = New-Item -ItemType Directory -Path $fixtureRoot
    $script:children = [Collections.Generic.List[object]]::new()
    function Start-TeamsThreadingFixture {
        param([string]$Root, [string]$Role, [string]$Mode = 'send')
        $psi = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })))
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        foreach ($arg in @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'fixtures\TeamsThreading.Child.ps1'),
                '-FixtureRoot', $Root, '-DurableRoot', (Join-Path $Root 'durable'), '-Role', $Role, '-Mode', $Mode)) {
            $psi.ArgumentList.Add($arg)
        }
        $process = [Diagnostics.Process]::Start($psi)
        $child = @{ Process = $process; StdOut = $process.StandardOutput.ReadToEndAsync(); StdErr = $process.StandardError.ReadToEndAsync() }
        $script:children.Add($child)
        return $child
    }
    function Wait-TeamsThreadingFixtureFile {
        param([string]$Path)
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while (-not (Test-Path -LiteralPath $Path)) {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Fixture did not reach its synchronization point.' }
            Start-Sleep -Milliseconds 20
        }
    }
    function Complete-TeamsThreadingFixture {
        param($Child, [int]$ExitCode = 0)
        $Child.Process.WaitForExit(20000) | Should -BeTrue
        $Child.Process.ExitCode | Should -Be $ExitCode -Because $Child.StdErr.GetAwaiter().GetResult()
        if ($ExitCode -eq 0) { return $Child.StdOut.GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable }
    }
}

AfterAll {
    foreach ($child in $script:children) {
        if (-not $child.Process.HasExited) { $child.Process.Kill($true); $child.Process.WaitForExit(5000) | Out-Null }
        $child.Process.Dispose()
    }
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}

Describe 'WorkIQ structured rejection metadata' {
    BeforeEach {
        $script:session = @{ Response = [pscustomobject]@{ structuredContent = [pscustomobject]@{
            statusCode = 429; headers = [pscustomobject]@{ 'Retry-After' = '5' }; data = $null
        } } }
        Mock Send-AgentMcpRequest -ModuleName DevPilot.AgentHarness { param($Session) $Session.Response }
    }

    It 'preserves validated status and optional retry metadata without changing successful data' {
        try {
            Invoke-AgentWorkIqTool -Session $session -Name create_entity -Arguments @{ parentUrl = '/teams/fixture/messages'; jsonBody = @{} }
            throw 'Expected rejection.'
        }
        catch {
            $_.Exception.Data['WorkIqStatusCode'] | Should -Be 429
            $_.Exception.Data['WorkIqRetryAfter'] | Should -BeExactly '5'
        }
        $session.Response.structuredContent.statusCode = 201
        $session.Response.structuredContent.data = [pscustomobject]@{ id = 'message' }
        (Invoke-AgentWorkIqTool -Session $session -Name create_entity -Arguments @{ parentUrl = '/teams/fixture/messages' }).id |
            Should -BeExactly 'message'
    }

    It 'accepts the per-entity envelope and rejects invalid status rather than parsing prose' {
        $session.Response = [pscustomobject]@{ structuredContent = [pscustomobject]@{ results = @(
            [pscustomobject]@{ statusCode = 410; data = $null }
        ) } }
        try {
            Invoke-AgentWorkIqTool -Session $session -Name create_entity -Arguments @{ parentUrl = '/teams/fixture/messages' }
        }
        catch { $_.Exception.Data['WorkIqStatusCode'] | Should -Be 410 }
        $session.Response.structuredContent.results[0].statusCode = '429'
        try {
            Invoke-AgentWorkIqTool -Session $session -Name create_entity -Arguments @{ parentUrl = '/teams/fixture/messages' }
        }
        catch { $_.Exception.Data.Contains('WorkIqStatusCode') | Should -BeFalse }
    }

    It 'retains the tool and path ceilings before calling MCP' {
        { Invoke-AgentWorkIqTool -Session $session -Name delete_entity -Arguments @{ parentUrl = '/teams/fixture' } } | Should -Throw
        { Invoke-AgentWorkIqTool -Session $session -Name create_entity -Arguments @{ parentUrl = 'https://attacker.test/teams/fixture' } } | Should -Throw
        Should -Invoke Send-AgentMcpRequest -ModuleName DevPilot.AgentHarness -Times 0
    }

    It 'preserves legacy independent-channel and direct-message data-return contracts' {
        Mock Send-AgentMcpRequest -ModuleName DevPilot.AgentHarness {
            param($Params)
            if ($Params.name -eq 'fetch') {
                $id = if ($Params.arguments.entityUrls[0].StartsWith('/me')) {
                    '11111111-1111-1111-1111-111111111111'
                } else { '22222222-2222-2222-2222-222222222222' }
                return [pscustomobject]@{ structuredContent = [pscustomobject]@{ results = @(
                    [pscustomobject]@{ statusCode = 200; data = [pscustomobject]@{ id = $id } }
                ) } }
            }
            return [pscustomobject]@{ structuredContent = [pscustomobject]@{
                statusCode = 201; data = [pscustomobject]@{ id = 'legacy-id' }
            } }
        }
        (Send-AgentTeamsChannelMessage -Session $session -TeamId fixture -ChannelId channel -Title title -Body body).id |
            Should -BeExactly 'legacy-id'
        (Send-AgentTeamsDirectMessage -Session $session -RecipientUpn fixture@example.test -Title title -Body body).id |
            Should -BeExactly 'legacy-id'
        Should -Invoke Send-AgentMcpRequest -ModuleName DevPilot.AgentHarness -Times 1 -Exactly -ParameterFilter {
            $Params.name -eq 'create_entity' -and $Params.arguments.parentUrl -eq '/chats/legacy-id/messages'
        }
    }
}

Describe 'durable channel threading' {
    BeforeEach {
        $script:caseRoot = Join-Path $fixtureRoot ([Guid]::NewGuid().ToString('N'))
        $script:durableRoot = Join-Path $caseRoot 'durable'
        $script:session = @{
            Calls = [Collections.Generic.List[object]]::new()
            Responses = [Collections.Generic.Queue[object]]::new()
            DurableRoot = $durableRoot; BlockStateWrite = $false; HeldStream = $null
        }
        $script:arguments = @{
            Session = $session; DurableStateRoot = $durableRoot
            RepositoryIdentity = @{ key = 'v1:github:123456'; verified = $true }
            Role = 'reviewer'; NotificationEvent = 'reviewCompleted'; PullRequestId = 103; SourceCommit = 'commit-one'
            TeamId = 'fixture-team'; ChannelId = '19:fixture@thread.tacv2'
            Title = 'A <title>'; Body = 'A <script>body</script>'
            Links = @('https://example.test/pr/103?a=1&b=2')
        }
        Mock Send-AgentMcpRequest -ModuleName DevPilot.AgentHarness {
            param($Session, $Method, $Params, $DeadlineUtc)
            $Method | Should -BeExactly 'tools/call'
            $Params.name | Should -BeExactly 'create_entity'
            $Params.arguments.Keys | Should -HaveCount 2
            $stateFile = Get-ChildItem -LiteralPath $Session.DurableRoot -Recurse -Filter '*.json' |
                Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match '"pending"' } | Select-Object -First 1
            $stateFile | Should -Not -BeNullOrEmpty -Because 'the intent must be durably installed before every POST'
            $Session.Calls.Add(@{ Params = $Params; At = [DateTimeOffset]::UtcNow; Deadline = $DeadlineUtc })
            if ($Session.ContainsKey('AuditLines')) {
                $Session.Calls[-1].AuditBeforePost = @($Session.AuditLines | ForEach-Object { $_ | ConvertFrom-Json })
            }
            if ($Session.BlockStateWrite) {
                $Session.HeldStream = [IO.File]::Open($stateFile.FullName, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            }
            if ($Session.Responses.Count -eq 0) {
                return [pscustomobject]@{ structuredContent = [pscustomobject]@{
                    statusCode = 201; data = [pscustomobject]@{ id = "message-$($Session.Calls.Count)" }
                } }
            }
            $response = $Session.Responses.Dequeue()
            if ($response -is [Exception]) { throw $response }
            return $response | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        }
    }

    AfterEach {
        if ($session.HeldStream) { $session.HeldStream.Dispose(); $session.HeldStream = $null }
    }

    It 'uses the first event as root and a cross-role event as an encoded reply' {
        $session.Responses.Enqueue(@{ structuredContent = @{ statusCode = 201; data = @{ id = 'opaque/root?#%' } } })
        (Send-AgentTeamsThreadedChannelMessage @arguments).Outcome | Should -BeExactly 'root-created'
        $arguments.Role = 'review-handler'
        $arguments.NotificationEvent = 'prReadyToComplete'
        (Send-AgentTeamsThreadedChannelMessage @arguments).Outcome | Should -BeExactly 'reply-delivered'
        $session.Calls[0].Params.arguments.parentUrl | Should -BeExactly '/teams/fixture-team/channels/19%3Afixture%40thread.tacv2/messages'
        $session.Calls[1].Params.arguments.parentUrl | Should -BeExactly '/teams/fixture-team/channels/19%3Afixture%40thread.tacv2/messages/opaque%2Froot%3F%23%25/replies'
        $html = $session.Calls[0].Params.arguments.jsonBody.body.content
        $html | Should -Match '&lt;script&gt;'
        $html | Should -Not -Match '<script>'
        $html | Should -Match '&amp;b=2'
        $session.Calls[0].Params.arguments.ContainsKey('headers') | Should -BeFalse
    }

    It 'dedupes exactly role/event/commit without storing message text or depending on legacy receipts' {
        $first = Send-AgentTeamsThreadedChannelMessage @arguments
        $second = Send-AgentTeamsThreadedChannelMessage @arguments
        $first.Delivered | Should -BeTrue
        $second.Delivered | Should -BeTrue
        $second.Deduped | Should -BeTrue
        $arguments.SourceCommit = 'commit-two'
        (Send-AgentTeamsThreadedChannelMessage @arguments).Outcome | Should -Be 'reply-delivered'
        $arguments.NotificationEvent = 'reviewFailed'
        $arguments.SourceCommit = ''
        (Send-AgentTeamsThreadedChannelMessage @arguments).Outcome | Should -Be 'reply-delivered'
        $session.Calls.Count | Should -Be 3
        $stateFile = Get-ChildItem -LiteralPath $durableRoot -Recurse -Filter '103.json'
        $text = Get-Content -LiteralPath $stateFile.FullName -Raw
        $text | Should -Not -Match 'commit-one|<title>|<script>|https:|notifications.json'
        $stateFile.FullName | Should -Match '[\\/]([0-9a-f]{64})[\\/]teams-threads[\\/]v1[\\/]([0-9a-f]{64})[\\/]103.json$'
    }

    It 'emits safe notification.delivery events through the optional output context' {
        $lines = [Collections.Generic.List[string]]::new()
        $writeLine = { param($Line) $lines.Add([string]$Line) }.GetNewClosure()
        $output = New-AgentOutputContext -Agent reviewer -OutputMode Json -WriteLine $writeLine
        $arguments.OutputContext = $output
        try {
            (Send-AgentTeamsThreadedChannelMessage @arguments).Outcome | Should -Be 'root-created'
            (Send-AgentTeamsThreadedChannelMessage @arguments).Outcome | Should -Be 'deduped'
            $arguments.Role = 'review-handler'
            $session.Responses.Enqueue([IO.IOException]::new('private provider details'))
            (Send-AgentTeamsThreadedChannelMessage @arguments).Outcome | Should -Be 'unknown'
            $events = @($lines | ForEach-Object { $_ | ConvertFrom-Json })
            $events.Count | Should -Be 3
            @($events.eventType | Select-Object -Unique) | Should -Be @('notification.delivery')
            $events[0].data.outcome | Should -Be 'root-created'
            $events[1].data.outcome | Should -Be 'deduped'
            $events[2].data.outcome | Should -Be 'unknown'
            $events[2].level | Should -Be 'warning'
            $events[0].pullRequestId | Should -Be 103
            $events[0].sourceCommit | Should -Be ''
            ($lines -join "`n") | Should -Not -Match 'fixture-team|commit-one|<script>|private provider|message-1'
        }
        finally { Close-AgentOutputContext $output }
    }

    It 'does not change delivery or cause resends if an output context is unavailable' {
        $arguments.OutputContext = @{ invalid = $true }
        $result = Send-AgentTeamsThreadedChannelMessage @arguments
        $result.Delivered | Should -BeTrue
        $result.Outcome | Should -Be 'root-created'
        $result.Audit.code | Should -Contain 'audit-unavailable'
        (Send-AgentTeamsThreadedChannelMessage @arguments).Outcome | Should -Be 'deduped'
        $session.Calls.Count | Should -Be 1
    }

    It 'isolates current destination, verified repository, and PR' {
        (Send-AgentTeamsThreadedChannelMessage @arguments).Outcome | Should -Be 'root-created'
        $arguments.ChannelId = 'new-channel'
        (Send-AgentTeamsThreadedChannelMessage @arguments).Outcome | Should -Be 'root-created'
        $arguments.TeamId = 'new-team'
        (Send-AgentTeamsThreadedChannelMessage @arguments).Outcome | Should -Be 'root-created'
        $arguments.RepositoryIdentity = @{ key = 'v1:github:654321'; verified = $true }
        (Send-AgentTeamsThreadedChannelMessage @arguments).Outcome | Should -Be 'root-created'
        $arguments.PullRequestId = 104
        (Send-AgentTeamsThreadedChannelMessage @arguments).Outcome | Should -Be 'root-created'
        $session.Calls.Count | Should -Be 5
    }

    It 'rejects invalid identity, numeric/URL destinations, and unsafe link schemes before POST' {
        $arguments.RepositoryIdentity.verified = 'true'
        { Send-AgentTeamsThreadedChannelMessage @arguments } | Should -Throw
        $arguments.RepositoryIdentity.verified = $true
        $arguments.TeamId = 'https://attacker.test'
        { Send-AgentTeamsThreadedChannelMessage @arguments } | Should -Throw
        $arguments.TeamId = 'fixture-team'
        $arguments.Links = @('javascript:alert(1)')
        { Send-AgentTeamsThreadedChannelMessage @arguments } | Should -Throw
        $session.Calls.Count | Should -Be 0
    }

    It 'does not POST for a past deadline or an untrusted repository-contained root' {
        $arguments.DeadlineUtc = [DateTime]::UtcNow.AddSeconds(-1)
        (Send-AgentTeamsThreadedChannelMessage @arguments).Outcome | Should -Be 'deferred'
        $arguments.Remove('DeadlineUtc')
        $arguments.DurableStateRoot = Join-Path $PSScriptRoot 'TeamsThreading-forbidden'
        (Send-AgentTeamsThreadedChannelMessage @arguments).Delivered | Should -BeFalse
        $session.Calls.Count | Should -Be 0
        Test-Path -LiteralPath $arguments.DurableStateRoot | Should -BeFalse
    }

    It 'blocks another root after transport loss without exposing provider prose in audits' {
        $session.Responses.Enqueue([TimeoutException]::new('secret token and private message'))
        $first = Send-AgentTeamsThreadedChannelMessage @arguments
        $first.Outcome | Should -Be 'unknown'
        $first.Delivered | Should -BeFalse
        (Send-AgentTeamsThreadedChannelMessage @arguments).Outcome | Should -Be 'unknown'
        $arguments.Role = 'review-handler'
        (Send-AgentTeamsThreadedChannelMessage @arguments).Code | Should -Be 'root-unknown'
        ($first | ConvertTo-Json -Depth 5) | Should -Not -Match 'secret|token|private|fixture-team|commit-one'
        $session.Calls.Count | Should -Be 1
    }

    It 'blocks the uncertain reply but permits unrelated safe events under a confirmed root' {
        $null = Send-AgentTeamsThreadedChannelMessage @arguments
        $arguments.Role = 'review-handler'
        $session.Responses.Enqueue([IO.IOException]::new('ack lost'))
        (Send-AgentTeamsThreadedChannelMessage @arguments).Outcome | Should -Be 'unknown'
        (Send-AgentTeamsThreadedChannelMessage @arguments).Outcome | Should -Be 'unknown'
        $arguments.SourceCommit = 'commit-two'
        (Send-AgentTeamsThreadedChannelMessage @arguments).Outcome | Should -Be 'reply-delivered'
        $session.Calls.Count | Should -Be 3
    }

    It 'treats malformed success id <Label> as unknown, never a retry or fallback' -ForEach @(
        @{ Label = 'numeric'; Id = 1234 }, @{ Label = 'URL'; Id = 'https://attacker.test/path' },
        @{ Label = 'empty'; Id = '' }, @{ Label = 'long'; Id = ('x' * 513) }, @{ Label = 'dot-segment'; Id = '..' }
    ) {
        $session.Responses.Enqueue(@{ structuredContent = @{ statusCode = 201; data = @{ id = $Id } } })
        (Send-AgentTeamsThreadedChannelMessage @arguments).Outcome | Should -Be 'unknown'
        (Send-AgentTeamsThreadedChannelMessage @arguments).Outcome | Should -Be 'unknown'
        $session.Calls.Count | Should -Be 1
    }

    It 'accepts numeric-looking strings as opaque ids and validates returned channel binding' {
        $session.Responses.Enqueue(@{ structuredContent = @{ statusCode = 201; data = @{
            id = '123456789'; channelIdentity = @{ teamId = $arguments.TeamId; channelId = $arguments.ChannelId }
        } } })
        (Send-AgentTeamsThreadedChannelMessage @arguments).Outcome | Should -Be 'root-created'
        $arguments.Role = 'review-handler'
        $session.Responses.Enqueue(@{ structuredContent = @{ statusCode = 201; data = @{
            id = 'reply'; channelIdentity = @{ teamId = 'other-team'; channelId = $arguments.ChannelId }
        } } })
        (Send-AgentTeamsThreadedChannelMessage @arguments).Outcome | Should -Be 'unknown'
        $session.Calls.Count | Should -Be 2
    }

    It 'validates a returned replyToId against the known root' {
        $null = Send-AgentTeamsThreadedChannelMessage @arguments
        $arguments.Role = 'review-handler'
        $session.Responses.Enqueue(@{ structuredContent = @{ statusCode = 201; data = @{ id = 'reply'; replyToId = 'another-root' } } })
        (Send-AgentTeamsThreadedChannelMessage @arguments).Outcome | Should -Be 'unknown'
    }

    It 'leaves a pending intent after Windows sharing prevents confirmation persistence' -Skip:(-not $IsWindows) {
        $session.BlockStateWrite = $true
        $result = Send-AgentTeamsThreadedChannelMessage @arguments
        $result.Outcome | Should -Be 'unknown'
        $result.Code | Should -Be 'persistence-unknown'
        $session.HeldStream.Dispose()
        $session.HeldStream = $null
        $session.BlockStateWrite = $false
        (Send-AgentTeamsThreadedChannelMessage @arguments).Outcome | Should -Be 'unknown'
        $session.Calls.Count | Should -Be 1
        (Get-Content -LiteralPath (Get-ChildItem $durableRoot -Recurse -Filter '103.json').FullName -Raw) | Should -Match '"pending"'
    }

    It 'does not POST when Windows sharing prevents installing the pre-send intent' -Skip:(-not $IsWindows) {
        $null = Send-AgentTeamsThreadedChannelMessage @arguments
        $statePath = (Get-ChildItem $durableRoot -Recurse -Filter '103.json').FullName
        $arguments.Role = 'review-handler'
        $held = [IO.File]::Open($statePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            (Send-AgentTeamsThreadedChannelMessage @arguments).Delivered | Should -BeFalse
            $session.Calls.Count | Should -Be 1
        }
        finally { $held.Dispose() }
        (Send-AgentTeamsThreadedChannelMessage @arguments).Outcome | Should -Be 'reply-delivered'
    }

    It 'retries only a definite 429 and fully honors a validated delay' {
        $session.Responses.Enqueue(@{ structuredContent = @{ statusCode = 429; headers = @{ 'Retry-After' = '1' } } })
        (Send-AgentTeamsThreadedChannelMessage @arguments).Outcome | Should -Be 'root-created'
        $session.Calls.Count | Should -Be 2
        ($session.Calls[1].At - $session.Calls[0].At).TotalSeconds | Should -BeGreaterOrEqual 1
    }

    It 'caps definite 429 at three attempts across subsequent invocations' {
        1..3 | ForEach-Object {
            $session.Responses.Enqueue(@{ structuredContent = @{ statusCode = 429; headers = @{ 'Retry-After' = '0' } } })
        }
        (Send-AgentTeamsThreadedChannelMessage @arguments).Code | Should -Be 'attempt-limit'
        (Send-AgentTeamsThreadedChannelMessage @arguments).Code | Should -Be 'attempt-limit'
        $session.Calls.Count | Should -Be 3
    }

    It 'does not retry 429 with missing or invalid metadata <Label>' -ForEach @(
        @{ Label = 'missing'; Header = $null }, @{ Label = 'negative'; Header = '-1' },
        @{ Label = 'fractional'; Header = '0.1' }, @{ Label = 'array'; Header = @('1', '2') },
        @{ Label = 'injected'; Header = "0`r`nRetry-After: 0" }, @{ Label = 'overflow'; Header = '99999999999999999999' }
    ) {
        $session.Responses.Enqueue(@{ structuredContent = @{ statusCode = 429; headers = @{ 'Retry-After' = $Header } } })
        (Send-AgentTeamsThreadedChannelMessage @arguments).Code | Should -Be 'throttled-metadata-unavailable'
        (Send-AgentTeamsThreadedChannelMessage @arguments).Code | Should -Be 'throttled-metadata-unavailable'
        $session.Calls.Count | Should -Be 1
    }

    It 'does not shorten an excessive server delay to the remaining deadline' {
        $session.Responses.Enqueue(@{ structuredContent = @{ statusCode = 429; headers = @{ 'Retry-After' = '120' } } })
        $arguments.DeadlineUtc = [DateTime]::UtcNow.AddSeconds(10)
        (Send-AgentTeamsThreadedChannelMessage @arguments).Code | Should -Be 'throttled'
        (Send-AgentTeamsThreadedChannelMessage @arguments).Code | Should -Be 'throttled'
        $session.Calls.Count | Should -Be 1
    }

    It 'accepts a valid HTTP-date Retry-After without making up missing metadata' {
        $session.Responses.Enqueue(@{ structuredContent = @{ statusCode = 429; headers = @{
            'Retry-After' = [DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('r', [Globalization.CultureInfo]::InvariantCulture)
        } } })
        (Send-AgentTeamsThreadedChannelMessage @arguments).Outcome | Should -Be 'root-created'
        $session.Calls.Count | Should -Be 2
    }

    It 'uses one independent fallback for definite stale <Status> without adopting it as the canonical root' -ForEach @(
        @{ Status = 404 }, @{ Status = 410 }
    ) {
        $null = Send-AgentTeamsThreadedChannelMessage @arguments
        $arguments.Role = 'review-handler'
        $session.Responses.Enqueue(@{ structuredContent = @{ statusCode = $Status; data = $null } })
        (Send-AgentTeamsThreadedChannelMessage @arguments).Outcome | Should -Be 'fallback-delivered'
        (Send-AgentTeamsThreadedChannelMessage @arguments).Outcome | Should -Be 'deduped'
        $session.Calls[2].Params.arguments.parentUrl | Should -Not -Match '/replies$'
        $arguments.SourceCommit = 'new-commit'
        (Send-AgentTeamsThreadedChannelMessage @arguments).Outcome | Should -Be 'reply-delivered'
        $session.Calls[3].Params.arguments.parentUrl | Should -Match '/message-1/replies$'
    }

    It 'does not retry or fall back on a server error' {
        $null = Send-AgentTeamsThreadedChannelMessage @arguments
        $arguments.Role = 'review-handler'
        $session.Responses.Enqueue(@{ structuredContent = @{ statusCode = 503; data = $null } })
        (Send-AgentTeamsThreadedChannelMessage @arguments).Outcome | Should -Be 'unknown'
        (Send-AgentTeamsThreadedChannelMessage @arguments).Outcome | Should -Be 'unknown'
        $session.Calls.Count | Should -Be 2
    }

    It 'does not repeat a fallback when its acknowledgement is lost' {
        $null = Send-AgentTeamsThreadedChannelMessage @arguments
        $arguments.Role = 'review-handler'
        $session.Responses.Enqueue(@{ structuredContent = @{ statusCode = 404 } })
        $session.Responses.Enqueue([IO.IOException]::new('ack lost'))
        (Send-AgentTeamsThreadedChannelMessage @arguments).Outcome | Should -Be 'unknown'
        (Send-AgentTeamsThreadedChannelMessage @arguments).Outcome | Should -Be 'unknown'
        $session.Calls.Count | Should -Be 3
        $session.Calls[2].Params.arguments.parentUrl | Should -Not -Match '/replies$'
    }

    It 'audits stale-root transition before fallback and retains <Outcome> fallback context' -ForEach @(
        @{ Outcome = 'unknown'; Response = [IO.IOException]::new('private acknowledgement lost') }
        @{ Outcome = 'failed'; Response = @{ structuredContent = @{ statusCode = 403 } } }
        @{ Outcome = 'fallback-delivered'; Response = @{ structuredContent = @{ statusCode = 201; data = @{ id = 'fallback-message' } } } }
    ) {
        $null = Send-AgentTeamsThreadedChannelMessage @arguments
        $arguments.Role = 'review-handler'
        $arguments.NotificationEvent = 'prReadyToComplete'
        $lines = [Collections.Generic.List[string]]::new()
        $writeLine = { param($Line) $lines.Add([string]$Line) }.GetNewClosure()
        $output = New-AgentOutputContext -Agent review-handler -OutputMode Json -WriteLine $writeLine
        $arguments.OutputContext = $output
        $session.AuditLines = $lines
        $session.Responses.Enqueue(@{ structuredContent = @{ statusCode = 404 } })
        $session.Responses.Enqueue($Response)
        try {
            $result = Send-AgentTeamsThreadedChannelMessage @arguments
            $result.Outcome | Should -Be $Outcome
            $result.Delivered | Should -Be ($Outcome -eq 'fallback-delivered')
            $session.Calls.Count | Should -Be 3
            $before = $session.Calls[2].AuditBeforePost
            $before.Count | Should -Be 1
            $before[0].eventType | Should -Be 'notification.delivery'
            $before[0].data.outcome | Should -Be 'fallback-pending'
            $before[0].data.code | Should -Be 'stale-root'
            $before[0].data.operation | Should -Be 'fallback'
            $events = @($lines | ForEach-Object { $_ | ConvertFrom-Json })
            $events.Count | Should -Be 2
            $events[-1].data.outcome | Should -Be $Outcome
            $events[-1].data.operation | Should -Be 'fallback'
            $result.Audit.Count | Should -Be 2
            $result.Audit[-1].operation | Should -Be 'fallback'
            ($lines -join "`n") | Should -Not -Match 'private acknowledgement|fixture-team|message-1|fallback-message'
            $again = Send-AgentTeamsThreadedChannelMessage @arguments
            $again.Audit[-1].operation | Should -Be 'fallback'
            $session.Calls.Count | Should -Be 3
        }
        finally { Close-AgentOutputContext $output }
    }

    It 'returns explicit non-delivery for a definite authorization rejection' {
        $session.Responses.Enqueue(@{ structuredContent = @{ statusCode = 403; data = $null } })
        (Send-AgentTeamsThreadedChannelMessage @arguments).Outcome | Should -Be 'failed'
        (Send-AgentTeamsThreadedChannelMessage @arguments).Delivered | Should -BeFalse
        $session.Calls.Count | Should -Be 1
    }

    It 'rejects corrupt, duplicated, mismatched and overlarge hostile state <Attack>' -ForEach @(
        @{ Attack = 'corrupt' }, @{ Attack = 'duplicate' }, @{ Attack = 'binding' },
        @{ Attack = 'numeric-root' }, @{ Attack = 'unknown-field' }, @{ Attack = 'oversized' },
        @{ Attack = 'receipt-hash' }, @{ Attack = 'schema-coercion' }, @{ Attack = 'invalid-transition' }
    ) {
        $null = Send-AgentTeamsThreadedChannelMessage @arguments
        $statePath = (Get-ChildItem -LiteralPath $durableRoot -Recurse -Filter '103.json').FullName
        $text = [IO.File]::ReadAllText($statePath)
        $state = $text | ConvertFrom-Json -AsHashtable
        switch ($Attack) {
            corrupt { $text = '{' }
            duplicate { $text = $text.Replace('"schemaVersion":1', '"schemaVersion":1,"schemaVersion":1') }
            binding { $state.channelId = 'attacker-channel'; $text = $state | ConvertTo-Json -Depth 8 -Compress }
            numeric-root { $state.rootMessageId = 1234; $text = $state | ConvertTo-Json -Depth 8 -Compress }
            unknown-field { $state.outboundUrl = 'https://attacker.test'; $text = $state | ConvertTo-Json -Depth 8 -Compress }
            oversized { $text = ' ' * (1MB + 1) }
            receipt-hash {
                $entry = @($state.records.Keys)[0]
                $state.records[$entry].sourceCommitHash = 'f' * 64
                $text = $state | ConvertTo-Json -Depth 8 -Compress
            }
            schema-coercion { $state.schemaVersion = '1'; $text = $state | ConvertTo-Json -Depth 8 -Compress }
            invalid-transition {
                $entry = @($state.records.Keys)[0]
                $state.records[$entry].status = 'not-sent'
                $state.records[$entry].messageId = ''
                $state.rootMessageId = ''
                $text = $state | ConvertTo-Json -Depth 8 -Compress
            }
        }
        [IO.File]::WriteAllText($statePath, $text)
        $result = Send-AgentTeamsThreadedChannelMessage @arguments
        $result.Delivered | Should -BeFalse
        $result.Code | Should -Be 'state-unavailable'
        $session.Calls.Count | Should -Be 1
    }

    It 'fails closed on link traversal in registry state' {
        $null = Send-AgentTeamsThreadedChannelMessage @arguments
        $statePath = (Get-ChildItem -LiteralPath $durableRoot -Recurse -Filter '103.json').FullName
        $destination = Split-Path $statePath -Parent
        $saved = "$destination-saved"
        Move-Item -LiteralPath $destination -Destination $saved
        if ($IsWindows) { $null = New-Item -ItemType Junction -Path $destination -Target $saved }
        else { $null = New-Item -ItemType SymbolicLink -Path $destination -Target $saved }
        try {
            (Send-AgentTeamsThreadedChannelMessage @arguments).Code | Should -Be 'state-unavailable'
            $session.Calls.Count | Should -Be 1
        }
        finally { Remove-Item -LiteralPath $destination -Force }
    }

    It 'rejects a state file readable by another principal' {
        $null = Send-AgentTeamsThreadedChannelMessage @arguments
        $statePath = (Get-ChildItem $durableRoot -Recurse -Filter '103.json').FullName
        if ($IsWindows) {
            $original = Get-Acl -LiteralPath $statePath
            $acl = Get-Acl -LiteralPath $statePath
            $everyone = [Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::WorldSid, $null)
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                $everyone, [Security.AccessControl.FileSystemRights]::Read, [Security.AccessControl.AccessControlType]::Allow))
            Set-Acl -LiteralPath $statePath -AclObject $acl
        }
        else {
            $original = [IO.File]::GetUnixFileMode($statePath)
            [IO.File]::SetUnixFileMode($statePath, $original -bor [IO.UnixFileMode]::OtherRead)
        }
        try {
            (Send-AgentTeamsThreadedChannelMessage @arguments).Code | Should -Be 'state-unavailable'
            $session.Calls.Count | Should -Be 1
        }
        finally {
            if ($IsWindows) { Set-Acl -LiteralPath $statePath -AclObject $original }
            else { [IO.File]::SetUnixFileMode($statePath, $original) }
        }
    }

    It 'does not evict receipts when the bounded registry is full' {
        $null = Send-AgentTeamsThreadedChannelMessage @arguments
        $statePath = (Get-ChildItem -LiteralPath $durableRoot -Recurse -Filter '103.json').FullName
        $state = Get-Content $statePath -Raw | ConvertFrom-Json -AsHashtable
        $module = Get-Module DevPilot.AgentHarness
        for ($index = 1; $index -le 255; $index++) {
            $sourceHash = Get-AgentSha256 "commit-$index"
            $key = & $module { param($Hash) Get-AgentTeamsEventKey reviewer reviewCompleted $Hash } $sourceHash
            $state.records[$key] = @{
                role = 'reviewer'; notificationEvent = 'reviewCompleted'; sourceCommitHash = $sourceHash
                kind = 'reply'; status = 'delivered'; messageId = "fixture-$index"
                attempts = 1; retryNotBefore = 0L; code = 'confirmed'
            }
        }
        [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 8 -Compress))
        $arguments.SourceCommit = 'unseen-commit'
        (Send-AgentTeamsThreadedChannelMessage @arguments).Code | Should -Be 'state-capacity'
        (Get-Content $statePath -Raw | ConvertFrom-Json -AsHashtable).records.Count | Should -Be 256
        $session.Calls.Count | Should -Be 1
    }

    It 'bounds PR files in the destination partition without deleting existing state' {
        $null = Send-AgentTeamsThreadedChannelMessage @arguments
        $statePath = (Get-ChildItem -LiteralPath $durableRoot -Recurse -Filter '103.json').FullName
        $partition = Split-Path $statePath -Parent
        foreach ($id in 200..4294) { [IO.File]::WriteAllText((Join-Path $partition "$id.json"), '{}') }
        $arguments.PullRequestId = 9999
        (Send-AgentTeamsThreadedChannelMessage @arguments).Code | Should -Be 'state-capacity'
        Test-Path -LiteralPath (Join-Path $partition '9999.json') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $partition -Filter '*.json').Count | Should -Be 4096
        $session.Calls.Count | Should -Be 1
    }
}

Describe 'isolated process durability and cross-role serialization' {
    BeforeEach {
        $script:processRoot = Join-Path $fixtureRoot ([Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $processRoot
    }

    It 'serializes two genuine processes to one root and a reply, then dedupes after restart' {
        $first = Start-TeamsThreadingFixture $processRoot reviewer hold-root
        Wait-TeamsThreadingFixtureFile (Join-Path $processRoot 'root-post-entered')
        $second = Start-TeamsThreadingFixture $processRoot review-handler
        Wait-TeamsThreadingFixtureFile (Join-Path $processRoot 'review-handler.started')
        Start-Sleep -Milliseconds 250
        [IO.File]::WriteAllText((Join-Path $processRoot 'release-root'), 'ready')
        (Complete-TeamsThreadingFixture $first).Outcome | Should -Be 'root-created'
        (Complete-TeamsThreadingFixture $second).Outcome | Should -Be 'reply-delivered'
        $rootCall = Get-Content (Join-Path $processRoot 'reviewer.post.json') -Raw | ConvertFrom-Json
        $replyCall = Get-Content (Join-Path $processRoot 'review-handler.post.json') -Raw | ConvertFrom-Json
        $rootCall.arguments.parentUrl | Should -Not -Match '/replies$'
        $replyCall.arguments.parentUrl | Should -Match '/fixture-root/replies$'
        $restart = Start-TeamsThreadingFixture $processRoot reviewer
        (Complete-TeamsThreadingFixture $restart).Outcome | Should -Be 'deduped'
    }

    It 'defers contention rather than bypassing a concurrent root creator' {
        $first = Start-TeamsThreadingFixture $processRoot reviewer hold-root
        Wait-TeamsThreadingFixtureFile (Join-Path $processRoot 'root-post-entered')
        $second = Start-TeamsThreadingFixture $processRoot review-handler
        $result = Complete-TeamsThreadingFixture $second
        $result.Code | Should -Be 'state-contended'
        $result.Delivered | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $processRoot 'review-handler.post.json') | Should -BeFalse
        [IO.File]::WriteAllText((Join-Path $processRoot 'release-root'), 'ready')
        (Complete-TeamsThreadingFixture $first).Outcome | Should -Be 'root-created'
    }

    It 'never repeats a root after a process crash at <Mode>' -ForEach @(
        @{ Mode = 'crash-intent'; ExitCode = 73 }, @{ Mode = 'crash-ack'; ExitCode = 74 }
    ) {
        $first = Start-TeamsThreadingFixture $processRoot reviewer $Mode
        Complete-TeamsThreadingFixture $first $ExitCode
        $restart = Start-TeamsThreadingFixture $processRoot review-handler
        (Complete-TeamsThreadingFixture $restart).Code | Should -Be 'root-unknown'
        Test-Path -LiteralPath (Join-Path $processRoot 'review-handler.post.json') | Should -BeFalse
        $retry = Start-TeamsThreadingFixture $processRoot reviewer
        (Complete-TeamsThreadingFixture $retry).Outcome | Should -Be 'unknown'
    }
}
