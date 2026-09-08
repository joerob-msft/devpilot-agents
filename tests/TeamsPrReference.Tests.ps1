BeforeAll {
    $script:module = $null
    $script:fixtureRoot = Join-Path $TestDrive 'TeamsPrReference-fixtures'
    $null = New-Item -ItemType Directory -Path $fixtureRoot
    $toolkitSrc = Join-Path $fixtureRoot 'toolkit\src'
    $null = New-Item -ItemType Directory -Path $toolkitSrc -Force
    Copy-Item (Join-Path $PSScriptRoot '..\src\DevPilot.AgentHarness') $toolkitSrc -Recurse
    # Pester cannot resolve module-scoped mocks when a prior suite's copy is also loaded.
    Get-Module DevPilot.AgentHarness | Remove-Module -Force
    Import-Module (Join-Path $toolkitSrc 'DevPilot.AgentHarness\DevPilot.AgentHarness.psd1') -Force
    $script:module = (Get-Command New-AgentTeamsPrReferenceContext).Module
    function Add-TeamsReferenceFixture {
        param([string]$RootId = 'shared-root', [switch]$Pending, [string]$AuthorId = '', [string]$Nonce = '')
        if (-not $AuthorId) { $AuthorId = $script:fake.OwnerId }
        if (-not $Nonce) { $Nonce = New-AgentNonce }
        $context = @{
            Scope = Get-AgentSha256 (ConvertTo-Json -InputObject @('teams-pr-reference-v1', $script:identity.key, 103, 'fixture-team', 'fixture-channel') -Compress)
            TeamId = 'fixture-team'; ChannelId = 'fixture-channel'
        }
        $claim = @{ claim = $Nonce; ownerId = $AuthorId; teamsAuthorId = $script:fake.Me.id; messageId = $RootId; adopted = $false }
        $pendingText = & $script:module { param($Context, $Claim) ConvertTo-AgentTeamsReferenceComment $Context $Claim pending } $context $claim
        $readyText = & $script:module { param($Context, $Claim) ConvertTo-AgentTeamsReferenceComment $Context $Claim ready } $context $claim
        $comments = [Collections.Generic.List[object]]::new()
        $authorUpn = if ($AuthorId -eq $script:fake.OwnerId) { $script:fake.Pr.createdBy.uniqueName } else { 'other@example.test' }
        $comments.Add(@{ id = 1; content = $pendingText; author = @{ uniqueName = $authorUpn; displayName = 'Fixture author' }; isDeleted = $false })
        if (-not $Pending) { $comments.Add(@{ id = 2; content = $readyText; author = @{ uniqueName = $authorUpn; displayName = 'Fixture author' }; isDeleted = $false }) }
        $thread = @{ id = $script:fake.Threads.Count + 1; status = 'closed'; comments = $comments }
        $script:fake.Threads.Add($thread)
        $prefix = & $script:module { param($Context, $Claim) Get-AgentTeamsClaimRootPrefix $Context $Claim } $context $claim
        $script:fake.Roots[$RootId] = @{
            id = $RootId; channelIdentity = @{ teamId = 'fixture-team'; channelId = 'fixture-channel' }
            replyToId = $null; deletedDateTime = $null; messageType = 'message'
            from = @{ user = @{ id = $script:fake.Me.id } }
            body = @{ contentType = 'html'; content = $prefix + (New-AgentTeamsMessageHtml -Title 'Fixture root' -Body 'Fixture body') }
        }
        return $thread
    }
}

AfterAll {
    if ($script:module) { Remove-Module -ModuleInfo $script:module -Force }
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}

Describe 'authenticated Teams PR references and durable outbox' {
    BeforeEach {
        $script:caseRoot = Join-Path $fixtureRoot ([Guid]::NewGuid().ToString('N'))
        $script:identity = @{
            schemaVersion = 1; provider = 'AzureDevOps'; repositoryId = '11111111-1111-1111-1111-111111111111'
            organization = 'exampleorg'; project = 'widgets'; repositoryName = 'service'
            key = 'v1:azuredevops:11111111-1111-1111-1111-111111111111'; verified = $true
        }
        $script:fake = @{
            OwnerId = '33333333-3333-3333-3333-333333333333'
            ActorId = '33333333-3333-3333-3333-333333333333'
            Me = @{ id = '22222222-2222-2222-2222-222222222222'; userPrincipalName = 'author@example.test' }
            Threads = [Collections.Generic.List[object]]::new(); Roots = @{}
            Reads = [Collections.Generic.List[object]]::new(); Writes = [Collections.Generic.List[object]]::new()
            TeamsPosts = [Collections.Generic.List[object]]::new(); TeamsReads = [Collections.Generic.List[string]]::new()
            ClaimLost = $false; ClaimNotLanded = $false; ReadyLost = $false; ReadyNotLanded = $false; RootLost = $false
            RefReadFails = $false; PageCap = 100; IgnoreSkip = $false; ReplyFails = $false; ConflictOnClaim = $false
            ReplyLost = $false; KnownReadFails = $false; CorruptOutboxOnReply = ''; ReadyHideAfterWrite = $false
            HiddenThroughThread = 0
            OtherPrs = @{}
        }
        $fake.Pr = @{
            pullRequestId = 103; status = 'Active'; isDraft = $false
            createdBy = @{ id = $fake.OwnerId; uniqueName = 'author@example.test'; displayName = 'Fixture author' }
            lastMergeSourceCommit = @{ commitId = ('a' * 40) }
            repository = @{
                id = $identity.repositoryId; projectReference = @{ id = '66666666-6666-6666-6666-666666666666'; name = 'widgets' }
                url = "https://dev.azure.com/exampleorg/66666666-6666-6666-6666-666666666666/_apis/git/repositories/$($identity.repositoryId)"
            }
        }
        $script:ado = @{ Server = 'ado'; Fake = $fake }
        $script:workiq = @{ Server = 'workiq'; Fake = $fake }
        $script:handlerContext = New-AgentTeamsPrReferenceContext -AdoSession $ado -RepositoryIdentity $identity -Role review-handler -AllowWrites
        $script:reviewerContext = New-AgentTeamsPrReferenceContext -AdoSession $ado -RepositoryIdentity $identity -Role reviewer
        $script:initialize = @{
            Session = $workiq; ReferenceContext = $handlerContext; DurableStateRoot = (Join-Path $caseRoot 'handler')
            RepositoryIdentity = $identity; PullRequestId = 103; PullRequestUrl = 'https://dev.azure.com/exampleorg/widgets/_git/service/pullrequest/103'
            TeamId = 'fixture-team'; ChannelId = 'fixture-channel'
        }
        $script:send = @{
            Session = $workiq; ReferenceContext = $reviewerContext; DurableStateRoot = (Join-Path $caseRoot 'reviewer')
            RepositoryIdentity = $identity; Role = 'reviewer'; NotificationEvent = 'reviewCompleted'; PullRequestId = 103
            PullRequestUrl = $initialize.PullRequestUrl; SourceCommit = ('a' * 40)
            TeamId = 'fixture-team'; ChannelId = 'fixture-channel'; Title = 'Review <completed>'; Body = 'Synthetic <script>body</script>'
            Links = @($initialize.PullRequestUrl)
        }
        $script:drain = @{
            Session = $workiq; ReferenceContext = $reviewerContext; DurableStateRoot = $send.DurableStateRoot
            RepositoryIdentity = $identity; Role = 'reviewer'; TeamId = 'fixture-team'; ChannelId = 'fixture-channel'
            AllowedEvents = @('reviewCompleted', 'prReadyToComplete')
        }
        Mock Send-AgentMcpRequest -ModuleName DevPilot.AgentHarness {
            param($Session, $Method, $Params)
            if ($Method -cne 'tools/call') { throw 'Fixture refused unexpected protocol.' }
            $f = $Session.Fake
            $args = $Params.arguments
            if ($Session.Server -ceq 'ado') {
                if ($Params.name -ceq 'repo_pull_request_thread_write') {
                    $f.Writes.Add($args)
                    if ($args.action -ceq 'create') {
                        if ($f.ClaimNotLanded) { throw [IO.IOException]::new('synthetic claim transport failure') }
                        if ($args.status -cne 'Closed') { throw 'Fixture requires a closed coordination thread.' }
                        $comments = [Collections.Generic.List[object]]::new()
                        $actorUpn = if ($f.ActorId -eq $f.OwnerId) { $f.Pr.createdBy.uniqueName } else { 'other@example.test' }
                        $comments.Add(@{ id = 1; content = $args.content; author = @{ uniqueName = $actorUpn }; isDeleted = $false })
                        $thread = @{ id = $f.Threads.Count + 1; status = 'closed'; comments = $comments }
                        $f.Threads.Add($thread)
                        if ($f.ConflictOnClaim) {
                            $other = $args.content.Replace(($args.content -split "`n")[1], (
                                (($args.content -split "`n")[1] | ConvertFrom-Json -AsHashtable) |
                                    ForEach-Object { $_.claim = 'f' * 36; $_ | ConvertTo-Json -Compress }))
                            $f.Threads.Add(@{ id = $f.Threads.Count + 1; status = 'closed'; comments = @(
                                @{ id = 1; content = $other; author = @{ uniqueName = $actorUpn }; isDeleted = $false }
                            ) })
                        }
                        if ($f.ClaimLost) { throw [IO.IOException]::new('synthetic claim acknowledgement lost') }
                    }
                    elseif ($args.action -ceq 'reply') {
                        if ($f.ReadyNotLanded) { throw [IO.IOException]::new('synthetic ready transport failure') }
                        $thread = @($f.Threads | Where-Object id -EQ $args.threadId)[0]
                        $actorUpn = if ($f.ActorId -eq $f.OwnerId) { $f.Pr.createdBy.uniqueName } else { 'other@example.test' }
                        $thread.comments.Add(@{ id = $thread.comments.Count + 1; content = $args.content; author = @{ uniqueName = $actorUpn }; isDeleted = $false })
                        if ($f.ReadyHideAfterWrite) { $f.RefReadFails = $true }
                        if ($f.ReadyLost) { throw [IO.IOException]::new('synthetic ready acknowledgement lost') }
                    }
                    else { throw 'Fixture refused a non-coordination write.' }
                    return [pscustomobject]@{ content = @([pscustomobject]@{ text = 'Synthetic write confirmed, without an identifier.' }) }
                }
                $f.Reads.Add(@{ Name = $Params.name; Arguments = $args })
                if ($Params.name -ceq 'repo_pull_request') {
                    $value = if ($f.OtherPrs.ContainsKey([int]$args.pullRequestId)) { $f.OtherPrs[[int]$args.pullRequestId] } else { $f.Pr }
                }
                elseif ($Params.name -ceq 'repo_pull_request_thread') {
                    if ($f.RefReadFails) { throw [IO.IOException]::new('synthetic reference read unavailable') }
                    if ($args.action -ceq 'list') {
                        $all = @($f.Threads | Where-Object { $_.id -gt $f.HiddenThroughThread } |
                            ForEach-Object { @{ id = $_.id; status = $_.status } })
                    }
                    elseif ($args.action -ceq 'list_comments') {
                        $thread = @($f.Threads | Where-Object id -EQ $args.threadId)[0]
                        $all = @($thread.comments)
                    }
                    else { throw 'Fixture refused unexpected ADO read.' }
                    $skip = if ($f.IgnoreSkip) { 0 } else { $args.skip }
                    $value = @($all | Select-Object -Skip $skip -First ([Math]::Min($args.top, $f.PageCap)))
                }
                else { throw 'Fixture refused unexpected ADO tool.' }
                return [pscustomobject]@{ content = @([pscustomobject]@{ text = (ConvertTo-Json -InputObject $value -Depth 20 -Compress) }) }
            }
            if ($Session.Server -cne 'workiq') { throw 'Fixture refused unknown server.' }
            if ($Params.name -ceq 'fetch') {
                $url = $args.entityUrls[0]
                $f.TeamsReads.Add($url)
                if ($url -ceq '/me?$select=id,userPrincipalName') { $value = $f.Me }
                elseif ($url -cmatch '\A/teams/fixture-team/channels/fixture-channel/messages/([^/?]+)\z') {
                    if ($f.KnownReadFails) { throw [IO.IOException]::new('Synthetic root read unavailable.') }
                    $id = [Uri]::UnescapeDataString($Matches[1])
                    if (-not $f.Roots.ContainsKey($id)) {
                        return [pscustomobject]@{ isError = $true; content = @(); structuredContent = [pscustomobject]@{
                            results = @([pscustomobject]@{ statusCode = 404; data = $null; error = 'Synthetic missing root.' })
                        } }
                    }
                    $value = $f.Roots[$id]
                }
                else { throw 'Fixture forbids Teams history enumeration or arbitrary paths.' }
                return @{ structuredContent = @{ results = @(@{ statusCode = 200; data = $value }) } } |
                    ConvertTo-Json -Depth 20 | ConvertFrom-Json
            }
            if ($Params.name -cne 'create_entity' -or
                $args.parentUrl -cnotmatch '\A/teams/fixture-team/channels/fixture-channel/messages(?:/[^/]+/replies)?\z') {
                throw 'Fixture refused unexpected Teams POST.'
            }
            $f.TeamsPosts.Add($args)
            $reply = $args.parentUrl.EndsWith('/replies')
            if ($reply -and $f.ReplyFails) {
                return [pscustomobject]@{ isError = $true; content = @(); structuredContent = [pscustomobject]@{ statusCode = 404; data = $null } }
            }
            if ($reply -and $f.ReplyLost) { throw [IO.IOException]::new('Synthetic reply acknowledgement lost.') }
            if ($reply -and $f.CorruptOutboxOnReply) { [IO.File]::WriteAllText($f.CorruptOutboxOnReply, '{}') }
            $id = if ($reply) { "reply-$($f.TeamsPosts.Count)" } else { "root-$($f.TeamsPosts.Count)" }
            if (-not $reply) {
                $f.Roots[$id] = @{
                    id = $id; body = $args.jsonBody.body; replyToId = $null; deletedDateTime = $null; messageType = 'message'
                    channelIdentity = @{ teamId = 'fixture-team'; channelId = 'fixture-channel' }; from = @{ user = @{ id = $f.Me.id } }
                }
                if ($f.RootLost) { throw [IO.IOException]::new('synthetic Teams acknowledgement lost') }
            }
            return @{ structuredContent = @{ statusCode = 201; data = @{ id = $id } } } | ConvertTo-Json -Depth 12 | ConvertFrom-Json
        }
    }

    It 'publishes a closed pending claim, creates one bound root, and confirms its ready reply' {
        $result = Initialize-AgentTeamsPrThread @initialize
        $result.Ready | Should -BeTrue
        $fake.Writes.Count | Should -Be 2
        $fake.Writes[0].action | Should -Be 'create'
        $fake.Writes[0].status | Should -Be 'Closed'
        $fake.Writes[1].action | Should -Be 'reply'
        $fake.Writes[1].threadId | Should -Be 1
        $fake.TeamsPosts.Count | Should -Be 1
        $fake.TeamsPosts[0].jsonBody.body.content | Should -Match '\A<p>DevPilot Teams PR reference v1: [0-9a-f]{64}\.[0-9a-f]{36}</p>'
        (Initialize-AgentTeamsPrThread @initialize).Ready | Should -BeTrue
        $fake.Writes.Count | Should -Be 2
        $fake.TeamsPosts.Count | Should -Be 1
        @($fake.Reads | Where-Object { $_.Arguments.repositoryId -cne $identity.repositoryId }).Count | Should -Be 0
    }

    It 'queues before a reference exists, then drains without repeating review work' {
        $queued = Send-AgentTeamsThreadedChannelMessage @send
        $queued.Outcome | Should -Be 'queued'
        $queued.Queued | Should -BeTrue
        $queued.Delivered | Should -BeFalse
        $fake.TeamsPosts.Count | Should -Be 0
        (Initialize-AgentTeamsPrThread @initialize).Ready | Should -BeTrue
        $drained = Invoke-AgentTeamsNotificationOutbox @drain
        $drained.DeliveredCount | Should -Be 1
        $drained.QueuedCount | Should -Be 0
        $fake.TeamsPosts.Count | Should -Be 2
        $fake.TeamsPosts[1].parentUrl | Should -Match '/root-1/replies$'
        $fake.TeamsPosts[1].jsonBody.body.content | Should -Match '&lt;script&gt;body&lt;/script&gt;'
        (Send-AgentTeamsThreadedChannelMessage @send).Deduped | Should -BeTrue
        $fake.TeamsPosts.Count | Should -Be 2
    }

    It 'normalizes supported PR status <State> without changing activity semantics' -ForEach @(
        @{ State = 'Active'; ExpectedActive = $true }, @{ State = 'active'; ExpectedActive = $true }
        @{ State = 'Completed'; ExpectedActive = $false }, @{ State = 'completed'; ExpectedActive = $false }
        @{ State = 'Abandoned'; ExpectedActive = $false }, @{ State = 'abandoned'; ExpectedActive = $false }
    ) {
        $fake.Pr.status = $State
        $actual = & $script:module {
            param($ReferenceContext, $Identity)
            $authority = Get-AgentTeamsPrAuthority $ReferenceContext $Identity reviewer
            Get-AgentTeamsFreshPullRequest $authority 103 ([DateTime]::UtcNow.AddSeconds(60))
        } $reviewerContext $identity
        $actual.Active | Should -Be $ExpectedActive
        $fake.Writes.Count | Should -Be 0
        $fake.TeamsPosts.Count | Should -Be 0
    }

    It 'rejects unsupported or malformed PR status <State>' -ForEach @(
        @{ State = 'Active ' }, @{ State = 'Draft' }, @{ State = '' }, @{ State = 1 }
    ) {
        $fake.Pr.status = $State
        {
            & $script:module {
                param($ReferenceContext, $Identity)
                $authority = Get-AgentTeamsPrAuthority $ReferenceContext $Identity reviewer
                Get-AgentTeamsFreshPullRequest $authority 103 ([DateTime]::UtcNow.AddSeconds(60))
            } $reviewerContext $identity
        } | Should -Throw '*identity or state is invalid*'
        $fake.Writes.Count | Should -Be 0
        $fake.TeamsPosts.Count | Should -Be 0
    }

    It 'accepts project or projectReference metadata with name or authoritative GUID URL paths' -ForEach @(
        @{ Field = 'project'; Segment = 'widgets' }, @{ Field = 'projectReference'; Segment = 'widgets' }
        @{ Field = 'project'; Segment = '66666666-6666-6666-6666-666666666666' }
        @{ Field = 'projectReference'; Segment = '66666666-6666-6666-6666-666666666666' }
    ) {
        $metadata = $fake.Pr.repository.projectReference
        $fake.Pr.repository.Remove('projectReference')
        $fake.Pr.repository[$Field] = $metadata
        $fake.Pr.repository.url = "https://dev.azure.com/exampleorg/$Segment/_apis/git/repositories/$($identity.repositoryId)"
        (Initialize-AgentTeamsPrThread @initialize).Ready | Should -BeTrue
        $fake.Threads[0].comments[0].author.ContainsKey('id') | Should -BeFalse
    }

    It 'rejects mismatched repository URL project and repository GUID segments' -ForEach @(
        @{ Url = 'https://dev.azure.com/exampleorg/77777777-7777-7777-7777-777777777777/_apis/git/repositories/11111111-1111-1111-1111-111111111111' }
        @{ Url = 'https://dev.azure.com/exampleorg/66666666-6666-6666-6666-666666666666/_apis/git/repositories/77777777-7777-7777-7777-777777777777' }
    ) {
        $fake.Pr.repository.url = $Url
        (Initialize-AgentTeamsPrThread @initialize).Ready | Should -BeFalse
        $fake.TeamsPosts.Count | Should -Be 0
        $fake.Writes.Count | Should -Be 0
    }

    It 'retains verified legacy organization URL compatibility' -ForEach @(
        @{ LegacyPath = '/widgets' }
        @{ LegacyPath = '/DefaultCollection/widgets' }
        @{ LegacyPath = '/DefaultCollection' }
    ) {
        $fake.Pr.repository.url = 'https://{0}.visualstudio.com{1}/_apis/git/repositories/{2}' -f `
            $identity.organization, $LegacyPath, $identity.repositoryId
        (Initialize-AgentTeamsPrThread @initialize).Ready | Should -BeTrue
    }

    It 'rejects reference comments without a server UPN even if they expose the owner id and display name' {
        $thread = Add-TeamsReferenceFixture
        foreach ($comment in $thread.comments) {
            $comment.author.Remove('uniqueName')
            $comment.author.id = $fake.OwnerId
            $comment.author.displayName = 'Fixture author'
        }
        (Send-AgentTeamsThreadedChannelMessage @send).Queued | Should -BeTrue
        (Initialize-AgentTeamsPrThread @initialize).Ready | Should -BeFalse
        $fake.TeamsPosts.Count | Should -Be 0
        $fake.Writes.Count | Should -Be 0
    }

    It 'flushes a fixed PR without reading, sending, discarding, or moving the cursor for another queued PR' {
        (Send-AgentTeamsThreadedChannelMessage @send).Queued | Should -BeTrue
        $other = $send.Clone()
        $other.PullRequestId = 104
        $other.PullRequestUrl = $send.PullRequestUrl.Replace('/103', '/104')
        $otherPr = $fake.Pr | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
        $otherPr.pullRequestId = 104
        $fake.OtherPrs[104] = $otherPr
        (Send-AgentTeamsThreadedChannelMessage @other).Queued | Should -BeTrue
        $otherPr.status = 'completed'
        $null = Add-TeamsReferenceFixture
        $outboxPath = (Get-ChildItem $send.DurableStateRoot -Filter outbox.reviewer.json -Recurse).FullName
        $before = Get-Content $outboxPath -Raw | ConvertFrom-Json -AsHashtable
        $otherKey = @($before.entries.Keys | Where-Object { $before.entries[$_].pullRequestId -eq 104 })[0]
        $otherBefore = Get-AgentCanonicalDigest $before.entries[$otherKey]
        $fake.Reads.Clear()
        $result = Invoke-AgentTeamsNotificationOutbox @drain -PullRequestId 103
        $result.DeliveredCount | Should -Be 1
        $result.Processed | Should -Be 1
        @($fake.Reads | Where-Object { $_.Arguments.pullRequestId -ne 103 }).Count | Should -Be 0
        $fake.TeamsPosts.Count | Should -Be 1
        $after = Get-Content $outboxPath -Raw | ConvertFrom-Json -AsHashtable
        (Get-AgentCanonicalDigest $after.entries[$otherKey]) | Should -BeExactly $otherBefore
        $after.cursor | Should -BeExactly $before.cursor
    }

    It 'allows an automatic unbound drain to inspect and quarantine stale notifications across queued PRs' {
        (Send-AgentTeamsThreadedChannelMessage @send).Queued | Should -BeTrue
        $other = $send.Clone()
        $other.PullRequestId = 104
        $other.PullRequestUrl = $send.PullRequestUrl.Replace('/103', '/104')
        $otherPr = $fake.Pr | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
        $otherPr.pullRequestId = 104
        $fake.OtherPrs[104] = $otherPr
        (Send-AgentTeamsThreadedChannelMessage @other).Queued | Should -BeTrue
        $fake.Pr.status = 'completed'
        $otherPr.status = 'completed'
        $fake.Reads.Clear()
        $result = Invoke-AgentTeamsNotificationOutbox @drain -PullRequestId 0
        $result.Processed | Should -Be 2
        $result.QuarantinedCount | Should -Be 2
        $readIds = @($fake.Reads | Where-Object Name -EQ repo_pull_request |
            ForEach-Object { $_.Arguments.pullRequestId } | Sort-Object -Unique)
        $readIds | Should -Be @(103, 104)
        $fake.TeamsPosts.Count | Should -Be 0
    }

    It 'retains source-less starvation events as PR-scoped health notifications rather than ready assertions' {
        $send.NotificationEvent = 'candidateStarved'
        $send.SourceCommit = ''
        $send.Title = 'Candidate is starved'
        (Send-AgentTeamsThreadedChannelMessage @send).Queued | Should -BeTrue
        $fake.Pr.lastMergeSourceCommit.commitId = 'b' * 40
        $null = Add-TeamsReferenceFixture
        $drain.AllowedEvents = @('candidateStarved')
        $result = Invoke-AgentTeamsNotificationOutbox @drain -PullRequestId 103
        $result.DeliveredCount | Should -Be 1
        $result.QuarantinedCount | Should -Be 0
        (Send-AgentTeamsThreadedChannelMessage @send).Deduped | Should -BeTrue
        $fake.TeamsPosts.Count | Should -Be 1
        $fake.TeamsPosts[0].parentUrl | Should -Match '/shared-root/replies$'
    }

    It 'does not let reviewer initialization or a mutated context enable PR writes' {
        $reviewerContext.Role = 'review-handler'
        $reviewerContext.AllowWrites = $true
        $initialize.ReferenceContext = $reviewerContext
        (Initialize-AgentTeamsPrThread @initialize).Code | Should -Be 'reference-writes-disabled'
        $fake.Writes.Count | Should -Be 0
        $fake.TeamsPosts.Count | Should -Be 0
        $initialize.ReferenceContext = $handlerContext.Clone()
        { Initialize-AgentTeamsPrThread @initialize } | Should -Throw
    }

    It 'rejects author aliases and different authenticated principals' {
        $fake.Me.userPrincipalName = 'author.alias@example.test'
        (Initialize-AgentTeamsPrThread @initialize).Ready | Should -BeFalse
        $fake.Writes.Count | Should -Be 0
        $fake.TeamsPosts.Count | Should -Be 0
        $fake.Me.userPrincipalName = 'AUTHOR@EXAMPLE.TEST'
        (Initialize-AgentTeamsPrThread @initialize).Ready | Should -BeTrue
    }

    It 'requires the created ADO claim to belong to the immutable PR author before creating Teams roots' {
        $fake.ActorId = '44444444-4444-4444-4444-444444444444'
        (Initialize-AgentTeamsPrThread @initialize).Ready | Should -BeFalse
        $fake.Writes.Count | Should -Be 1
        $fake.TeamsPosts.Count | Should -Be 0
    }

    It 'never writes, queues, or sends during PreviewOnly' {
        (Initialize-AgentTeamsPrThread @initialize -PreviewOnly).Code | Should -Be 'preview'
        (Send-AgentTeamsThreadedChannelMessage @send -PreviewOnly).Code | Should -Be 'preview'
        (Invoke-AgentTeamsNotificationOutbox @drain -PreviewOnly).Code | Should -Be 'preview'
        $fake.Reads.Count | Should -Be 0
        $fake.Writes.Count | Should -Be 0
        $fake.TeamsPosts.Count | Should -Be 0
        Test-Path -LiteralPath $caseRoot | Should -BeFalse
    }

    It 'reconciles lost pending and ready acknowledgements without duplicate PR comments' {
        $fake.ClaimLost = $true
        $fake.ReadyLost = $true
        (Initialize-AgentTeamsPrThread @initialize).Ready | Should -BeTrue
        (Initialize-AgentTeamsPrThread @initialize).Ready | Should -BeTrue
        $fake.Writes.Count | Should -Be 2
        $fake.Threads[0].comments.Count | Should -Be 2
        $fake.TeamsPosts.Count | Should -Be 1
    }

    It 'never blindly retries an uncertain claim write' {
        $fake.ClaimNotLanded = $true
        (Initialize-AgentTeamsPrThread @initialize).Ready | Should -BeFalse
        $fake.ClaimNotLanded = $false
        (Initialize-AgentTeamsPrThread @initialize).Code | Should -Be 'claim-publication-unknown'
        $fake.Writes.Count | Should -Be 1
        $fake.TeamsPosts.Count | Should -Be 0
    }

    It 'quarantines a lost Teams root acknowledgement rather than enumerating or reposting' {
        $fake.RootLost = $true
        (Initialize-AgentTeamsPrThread @initialize).Outcome | Should -Be 'unknown'
        $fake.RootLost = $false
        (Initialize-AgentTeamsPrThread @initialize).Code | Should -Be 'root-unknown'
        $fake.TeamsPosts.Count | Should -Be 1
        $fake.Writes.Count | Should -Be 1
        @($fake.TeamsReads | Where-Object { $_ -match '\$top|\$filter|\$skiptoken|/messages$' }).Count | Should -Be 0
    }

    It 'does not append a ready reference twice when its first POST may not have landed' {
        $fake.ReadyNotLanded = $true
        (Initialize-AgentTeamsPrThread @initialize).Code | Should -Be 'ready-publication-unknown'
        $fake.ReadyNotLanded = $false
        (Initialize-AgentTeamsPrThread @initialize).Code | Should -Be 'ready-publication-unknown'
        $fake.TeamsPosts.Count | Should -Be 1
        $fake.Writes.Count | Should -Be 2
    }

    It 'never takes over a pending claim from another installation' {
        $null = Add-TeamsReferenceFixture -Pending
        (Initialize-AgentTeamsPrThread @initialize).Code | Should -Be 'reference-pending'
        (Send-AgentTeamsThreadedChannelMessage @send).Outcome | Should -Be 'queued'
        $fake.Writes.Count | Should -Be 0
        $fake.TeamsPosts.Count | Should -Be 0
    }

    It 'fails closed when another same-author claim appears during registration' {
        $fake.ConflictOnClaim = $true
        (Initialize-AgentTeamsPrThread @initialize).Ready | Should -BeFalse
        $fake.TeamsPosts.Count | Should -Be 0
        $fake.Writes.Count | Should -Be 1
    }

    It 'adopts one authenticated ready root across independent local state roots without global dedupe' {
        $null = Add-TeamsReferenceFixture
        (Send-AgentTeamsThreadedChannelMessage @send).Outcome | Should -Be 'reply-delivered'
        $send.DurableStateRoot = Join-Path $caseRoot 'another-reviewer'
        (Send-AgentTeamsThreadedChannelMessage @send).Outcome | Should -Be 'reply-delivered'
        $fake.TeamsPosts.Count | Should -Be 2
        @($fake.TeamsPosts | Where-Object { -not $_.parentUrl.EndsWith('/shared-root/replies') }).Count | Should -Be 0
        $fake.Writes.Count | Should -Be 0
    }

    It 'rejects conflicting ready roots and forged non-owner reference authors' {
        $null = Add-TeamsReferenceFixture -RootId one
        $null = Add-TeamsReferenceFixture -RootId two
        (Send-AgentTeamsThreadedChannelMessage @send).Code | Should -Be 'reference-conflict'
        $fake.TeamsPosts.Count | Should -Be 0
        $fake.Threads.Clear()
        $null = Add-TeamsReferenceFixture -AuthorId '44444444-4444-4444-4444-444444444444'
        (Send-AgentTeamsThreadedChannelMessage @send).Code | Should -Be 'reference-missing'
        $fake.TeamsPosts.Count | Should -Be 0
    }

    It 'honors capped ADO pages and reads a confirming empty page rather than guessing completion' {
        $fake.PageCap = 1
        $null = Add-TeamsReferenceFixture
        (Send-AgentTeamsThreadedChannelMessage @send).Outcome | Should -Be 'reply-delivered'
        $commentSkips = @($fake.Reads | Where-Object { $_.Arguments.action -eq 'list_comments' } | ForEach-Object { $_.Arguments.skip })
        $commentSkips | Should -Be @(0, 1, 2)
    }

    It 'queues on repeated or denied reference pages without creating roots' {
        $null = Add-TeamsReferenceFixture
        $fake.IgnoreSkip = $true
        (Send-AgentTeamsThreadedChannelMessage @send).Outcome | Should -Be 'queued'
        $fake.TeamsPosts.Count | Should -Be 0
        $fake.IgnoreSkip = $false
        $fake.RefReadFails = $true
        (Send-AgentTeamsThreadedChannelMessage @send).Outcome | Should -Be 'queued'
        $fake.TeamsPosts.Count | Should -Be 0
    }

    It 'rechecks active, draft, and head state before independently draining queued notifications' -ForEach @(
        @{ Change = 'head' }, @{ Change = 'draft' }, @{ Change = 'completed' }
    ) {
        $send.NotificationEvent = 'prReadyToComplete'
        (Send-AgentTeamsThreadedChannelMessage @send).Queued | Should -BeTrue
        $null = Add-TeamsReferenceFixture
        switch ($Change) {
            head { $fake.Pr.lastMergeSourceCommit.commitId = 'b' * 40 }
            draft { $fake.Pr.isDraft = $true }
            completed { $fake.Pr.status = 'completed' }
        }
        $result = Invoke-AgentTeamsNotificationOutbox @drain
        $result.DeliveredCount | Should -Be 0
        $result.QuarantinedCount | Should -Be 1
        $fake.TeamsPosts.Count | Should -Be 0
    }

    It 'uses current event subscriptions and current destination before draining' {
        $null = Send-AgentTeamsThreadedChannelMessage @send
        $null = Add-TeamsReferenceFixture
        $drain.AllowedEvents = @()
        (Invoke-AgentTeamsNotificationOutbox @drain).Processed | Should -Be 0
        $drain.AllowedEvents = @('reviewCompleted')
        $drain.ChannelId = 'another-channel'
        (Invoke-AgentTeamsNotificationOutbox @drain).Processed | Should -Be 0
        $fake.TeamsPosts.Count | Should -Be 0
        $drain.ChannelId = 'fixture-channel'
        (Invoke-AgentTeamsNotificationOutbox @drain).DeliveredCount | Should -Be 1
    }

    It 'does not independently fall back when an authenticated shared root becomes stale' {
        $null = Add-TeamsReferenceFixture
        $fake.ReplyFails = $true
        (Send-AgentTeamsThreadedChannelMessage @send).Delivered | Should -BeFalse
        (Invoke-AgentTeamsNotificationOutbox @drain).QuarantinedCount | Should -Be 1
        $fake.TeamsPosts.Count | Should -Be 1
        $fake.TeamsPosts[0].parentUrl | Should -Match '/shared-root/replies$'
    }

    It 'denies coordination text as feedback without treating that classification as routing authentication' {
        Test-AgentTeamsPrReferenceComment 'Ordinary review feedback.' | Should -BeFalse
        $thread = Add-TeamsReferenceFixture -AuthorId '44444444-4444-4444-4444-444444444444'
        Test-AgentTeamsPrReferenceComment $thread.comments[0].content | Should -BeTrue
        Test-AgentTeamsPrReferenceComment ($thread.comments[0].content + ('x' * 4096)) | Should -BeFalse
        (Send-AgentTeamsThreadedChannelMessage @send).Code | Should -Be 'reference-missing'
    }

    It 'shares a ready root across roles and source commits while keeping installation receipts distinct' {
        $null = Add-TeamsReferenceFixture
        (Send-AgentTeamsThreadedChannelMessage @send).Delivered | Should -BeTrue
        $send.Role = 'review-handler'
        $send.ReferenceContext = $handlerContext
        (Send-AgentTeamsThreadedChannelMessage @send).Outcome | Should -Be 'reply-delivered'
        $send.SourceCommit = 'b' * 40
        $fake.Pr.lastMergeSourceCommit.commitId = $send.SourceCommit
        (Send-AgentTeamsThreadedChannelMessage @send).Outcome | Should -Be 'reply-delivered'
        $fake.TeamsPosts.Count | Should -Be 3
        @($fake.TeamsPosts | Where-Object { -not $_.parentUrl.EndsWith('/shared-root/replies') }).Count | Should -Be 0
    }

    It 'does not adopt a reference for another <Scope>' -ForEach @(
        @{ Scope = 'repository' }, @{ Scope = 'destination' }, @{ Scope = 'PR' }
    ) {
        $null = Add-TeamsReferenceFixture
        switch ($Scope) {
            repository {
                $identity.repositoryId = '55555555-5555-5555-5555-555555555555'
                $identity.key = "v1:azuredevops:$($identity.repositoryId)"
                $fake.Pr.repository.id = $identity.repositoryId
                $fake.Pr.repository.url = "https://dev.azure.com/exampleorg/66666666-6666-6666-6666-666666666666/_apis/git/repositories/$($identity.repositoryId)"
                $send.ReferenceContext = New-AgentTeamsPrReferenceContext -AdoSession $ado -RepositoryIdentity $identity -Role reviewer
            }
            destination { $send.ChannelId = 'another-channel' }
            PR {
                $send.PullRequestId = 104
                $send.PullRequestUrl = $send.PullRequestUrl.Replace('/103', '/104')
                $fake.Pr.pullRequestId = 104
            }
        }
        (Send-AgentTeamsThreadedChannelMessage @send).Code | Should -Be 'reference-missing'
        $fake.TeamsPosts.Count | Should -Be 0
        $fake.TeamsReads.Count | Should -Be 0
    }

    It 'adopts only the author verified protected legacy root and preserves its real receipt' {
        $localSend = @{} + $send
        $localSend.Remove('ReferenceContext')
        $localSend.DurableStateRoot = $initialize.DurableStateRoot
        $localSend.Role = 'review-handler'
        (Send-AgentTeamsThreadedChannelMessage @localSend).Outcome | Should -Be 'root-created'
        (Initialize-AgentTeamsPrThread @initialize).Ready | Should -BeTrue
        $fake.TeamsPosts.Count | Should -Be 1
        $ready = ($fake.Threads[0].comments[1].content -split "`n")[1] | ConvertFrom-Json
        $ready.adopted | Should -BeTrue
        $ready.messageId | Should -Be 'root-1'
        $send.DurableStateRoot = $initialize.DurableStateRoot
        (Send-AgentTeamsThreadedChannelMessage @send).Outcome | Should -Be 'reply-delivered'
        $state = Get-Content (Get-ChildItem $initialize.DurableStateRoot -Filter 103.json -Recurse).FullName -Raw | ConvertFrom-Json -AsHashtable
        $state.schemaVersion | Should -Be 2
        @($state.records.Values | Where-Object { $_.kind -eq 'root' -and $_.status -eq 'delivered' }).Count | Should -Be 1
    }

    It 'does not publish a legacy root whose actual Teams author is different' {
        $localSend = @{} + $send
        $localSend.Remove('ReferenceContext')
        $localSend.DurableStateRoot = $initialize.DurableStateRoot
        $null = Send-AgentTeamsThreadedChannelMessage @localSend
        $fake.Roots['root-1'].from.user.id = '55555555-5555-5555-5555-555555555555'
        (Initialize-AgentTeamsPrThread @initialize).Ready | Should -BeFalse
        $fake.TeamsPosts.Count | Should -Be 1
        $fake.Writes.Count | Should -Be 0
    }

    It 'preserves a pre-upgrade uncertain event while allowing a distinct event under an authenticated root' {
        $localSend = @{} + $send
        $localSend.Remove('ReferenceContext')
        $fake.RootLost = $true
        (Send-AgentTeamsThreadedChannelMessage @localSend).Outcome | Should -Be 'unknown'
        $fake.RootLost = $false
        $null = Add-TeamsReferenceFixture
        (Send-AgentTeamsThreadedChannelMessage @send).Outcome | Should -Be 'unknown'
        $send.NotificationEvent = 'reviewFailed'
        (Send-AgentTeamsThreadedChannelMessage @send).Outcome | Should -Be 'reply-delivered'
        $state = Get-Content (Get-ChildItem $send.DurableStateRoot -Filter 103.json -Recurse).FullName -Raw | ConvertFrom-Json -AsHashtable
        $state.schemaVersion | Should -Be 2
        @($state.records.Values | Where-Object status -EQ unknown).Count | Should -Be 1
        @($state.records.Values | Where-Object { $_.kind -eq 'root' -and $_.status -eq 'delivered' }).Count | Should -Be 0
        $fake.TeamsPosts.Count | Should -Be 2
    }

    It 'recovers a confirmed local root after interruption before ready publication without another Teams POST' {
        $fake.KnownReadFails = $true
        (Initialize-AgentTeamsPrThread @initialize).Ready | Should -BeFalse
        $fake.KnownReadFails = $false
        $initialize.ReferenceContext = New-AgentTeamsPrReferenceContext -AdoSession $ado -RepositoryIdentity $identity -Role review-handler -AllowWrites
        (Initialize-AgentTeamsPrThread @initialize).Ready | Should -BeTrue
        $fake.TeamsPosts.Count | Should -Be 1
        $fake.Writes.Count | Should -Be 2
    }

    It 'reconciles a ready POST acknowledged only by a later read after restart' {
        $fake.ReadyHideAfterWrite = $true
        (Initialize-AgentTeamsPrThread @initialize).Ready | Should -BeFalse
        $fake.RefReadFails = $false
        $initialize.ReferenceContext = New-AgentTeamsPrReferenceContext -AdoSession $ado -RepositoryIdentity $identity -Role review-handler -AllowWrites
        (Initialize-AgentTeamsPrThread @initialize).Ready | Should -BeTrue
        $fake.Writes.Count | Should -Be 2
        $fake.TeamsPosts.Count | Should -Be 1
    }

    It 'quarantines a lost reply acknowledgement across independent drain invocations' {
        $null = Add-TeamsReferenceFixture
        $fake.ReplyLost = $true
        (Send-AgentTeamsThreadedChannelMessage @send).Outcome | Should -Be 'unknown'
        $fake.ReplyLost = $false
        (Invoke-AgentTeamsNotificationOutbox @drain).QuarantinedCount | Should -Be 1
        (Send-AgentTeamsThreadedChannelMessage @send).Outcome | Should -Be 'unknown'
        $fake.TeamsPosts.Count | Should -Be 1
    }

    It 'keeps confirmed delivery truthful during outbox cleanup failure and dedupes after recovery' {
        $null = Send-AgentTeamsThreadedChannelMessage @send
        $outboxPath = (Get-ChildItem $send.DurableStateRoot -Filter outbox.reviewer.json -Recurse).FullName
        $snapshot = [IO.File]::ReadAllText($outboxPath)
        $null = Add-TeamsReferenceFixture
        $fake.CorruptOutboxOnReply = $outboxPath
        $result = Send-AgentTeamsThreadedChannelMessage @send
        $result.Delivered | Should -BeTrue
        @($result.Audit.code) | Should -Contain 'outbox-cleanup-deferred'
        (Send-AgentTeamsThreadedChannelMessage @send).Deduped | Should -BeTrue
        [IO.File]::WriteAllText($outboxPath, $snapshot)
        $fake.CorruptOutboxOnReply = ''
        $drained = Invoke-AgentTeamsNotificationOutbox @drain
        $drained.DeliveredCount | Should -Be 1
        $drained.Results[0].Deduped | Should -BeTrue
        $drained.QueuedCount | Should -Be 0
        $fake.TeamsPosts.Count | Should -Be 1
    }

    It 'rejects malformed authenticated coordination markers instead of treating them as absent' -ForEach @(
        @{ Damage = 'oversized' }, @{ Damage = 'truncated' }, @{ Damage = 'duplicate-field' },
        @{ Damage = 'wrong-link' }, @{ Damage = 'open-thread' }, @{ Damage = 'deleted-type' }, @{ Damage = 'status-type' }
    ) {
        $thread = Add-TeamsReferenceFixture
        switch ($Damage) {
            oversized { $thread.comments[0].content += 'x' * 4096 }
            truncated { $thread.comments[0].content = '[DevPilot Teams PR reference v1]' }
            duplicate-field { $thread.comments[0].content = $thread.comments[0].content.Replace('"version":1', '"version":1,"version":1') }
            wrong-link { $thread.comments[1].content = $thread.comments[1].content.Replace('https://teams.microsoft.com/', 'https://elsewhere.example.test/') }
            open-thread { $thread.status = 'active' }
            deleted-type { $thread.comments[0].isDeleted = 'false' }
            status-type { $thread.status = $true }
        }
        (Initialize-AgentTeamsPrThread @initialize).Ready | Should -BeFalse
        (Send-AgentTeamsThreadedChannelMessage @send).Outcome | Should -Be 'queued'
        $fake.TeamsPosts.Count | Should -Be 0
        $fake.Writes.Count | Should -Be 0
    }

    It 'rejects a known root with invalid <Field> without independent fallback' -ForEach @(
        @{ Field = 'id' }, @{ Field = 'channel' }, @{ Field = 'author' }, @{ Field = 'deleted' },
        @{ Field = 'reply' }, @{ Field = 'marker' }, @{ Field = 'missing' }
    ) {
        $null = Add-TeamsReferenceFixture
        $root = $fake.Roots['shared-root']
        switch ($Field) {
            id { $root.id = 123 }
            channel { $root.channelIdentity.channelId = 'another-channel' }
            author { $root.from.user.id = '55555555-5555-5555-5555-555555555555'
            }
            deleted { $root.deletedDateTime = '2026-01-01T00:00:00Z' }
            reply { $root.replyToId = 'parent-root' }
            marker { $root.body.content = '<script>unsafe</script>' + $root.body.content }
            missing { $fake.Roots.Remove('shared-root') }
        }
        (Send-AgentTeamsThreadedChannelMessage @send).Queued | Should -BeTrue
        (Initialize-AgentTeamsPrThread @initialize).Ready | Should -BeFalse
        $fake.TeamsPosts.Count | Should -Be 0
        $fake.Writes.Count | Should -Be 0
    }

    It 'bounds reference pagination and defers instead of interpreting an incomplete history as absence' {
        for ($i = 1; $i -le 20; $i++) { $fake.Threads.Add(@{ id = $i; status = 'closed'; comments = @() }) }
        $fake.PageCap = 1
        (Send-AgentTeamsThreadedChannelMessage @send).Queued | Should -BeTrue
        @($fake.Reads | Where-Object { $_.Arguments.action -eq 'list' }).Count | Should -Be 20
        $fake.TeamsPosts.Count | Should -Be 0
    }

    It 'does not silently overwrite queued payloads when the same event is enqueued again' {
        $null = Send-AgentTeamsThreadedChannelMessage @send
        $send.Body = 'Changed body must not replace the completed review payload.'
        $null = Send-AgentTeamsThreadedChannelMessage @send
        $null = Add-TeamsReferenceFixture
        (Invoke-AgentTeamsNotificationOutbox @drain).DeliveredCount | Should -Be 1
        $fake.TeamsPosts[0].jsonBody.body.content | Should -Match 'Synthetic'
        $fake.TeamsPosts[0].jsonBody.body.content | Should -Not -Match 'Changed body'
    }

    It 'bounds the outbox at 128 entries without silently evicting pending notifications' {
        $null = Send-AgentTeamsThreadedChannelMessage @send
        $context = & $module { param($Settings) Get-AgentTeamsStoreContext $Settings.DurableStateRoot $Settings.RepositoryIdentity $Settings.TeamId $Settings.ChannelId } $send
        $outbox = & $module { param($Context) Read-AgentTeamsOutbox $Context reviewer } $context
        $payload = @($outbox.entries.Values)[0]
        for ($i = 1; $i -le 127; $i++) {
            $entry = @{} + $payload
            $entry.notificationEvent = "fixtureEvent$i"
            $key = & $module { param($Entry) Get-AgentTeamsOutboxKey reviewer $Entry } $entry
            $outbox.entries[$key] = $entry
        }
        & $module { param($Context, $State) Write-AgentTeamsOutbox $Context reviewer $State } $context $outbox
        $send.NotificationEvent = 'anotherEvent'
        (Send-AgentTeamsThreadedChannelMessage @send).Code | Should -Be 'outbox-capacity'
        $persisted = & $module { param($Context) Read-AgentTeamsOutbox $Context reviewer } $context
        $persisted.entries.Count | Should -Be 128
        $fake.TeamsPosts.Count | Should -Be 0
    }

    It 'fails closed on corrupted or rebound outbox state' -ForEach @(
        @{ Damage = 'corrupt' }, @{ Damage = 'scope' }, @{ Damage = 'key' }, @{ Damage = 'url' }, @{ Damage = 'scope-boolean' }
    ) {
        $null = Send-AgentTeamsThreadedChannelMessage @send
        $path = (Get-ChildItem $send.DurableStateRoot -Filter outbox.reviewer.json -Recurse).FullName
        $outbox = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
        switch ($Damage) {
            corrupt { $text = '{"version":' }
            scope { $outbox.channelId = 'another-channel' }
            scope-boolean { foreach ($field in @('repositoryKey', 'teamId', 'channelId', 'role')) { $outbox[$field] = $true } }
            key { $outbox.entries['bad-key'] = @($outbox.entries.Values)[0] }
            url { @($outbox.entries.Values)[0].links = @('http://not-https.example.test') }
        }
        if ($Damage -ne 'corrupt') { $text = $outbox | ConvertTo-Json -Depth 8 -Compress }
        [IO.File]::WriteAllText($path, $text)
        $null = Add-TeamsReferenceFixture
        (Send-AgentTeamsThreadedChannelMessage @send).Code | Should -Be 'outbox-unavailable'
        (Invoke-AgentTeamsNotificationOutbox @drain).Code | Should -Be 'outbox-unavailable'
        $fake.TeamsPosts.Count | Should -Be 0
    }

    It 'rejects malformed durable bootstrap state instead of creating another pending claim' -ForEach @(
        @{ ScopeValue = ('0' * 64) }, @{ ScopeValue = $true }
    ) {
        $fake.ClaimNotLanded = $true
        $null = Initialize-AgentTeamsPrThread @initialize
        $fake.ClaimNotLanded = $false
        $path = (Get-ChildItem $initialize.DurableStateRoot -Filter 103.reference.json -Recurse).FullName
        $state = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
        $state.scope = $ScopeValue
        [IO.File]::WriteAllText($path, ($state | ConvertTo-Json -Compress))
        (Initialize-AgentTeamsPrThread @initialize).Ready | Should -BeFalse
        $fake.Writes.Count | Should -Be 1
        $fake.TeamsPosts.Count | Should -Be 0
    }

    It 'accepts the ADO numeric closed status without accepting a truthy non-status value' {
        $thread = Add-TeamsReferenceFixture
        $thread.status = 4
        (Send-AgentTeamsThreadedChannelMessage @send).Delivered | Should -BeTrue
    }

    It 'drains at most ten queued events and advances a persistent fair cursor' {
        $null = Send-AgentTeamsThreadedChannelMessage @send
        $context = & $module { param($Settings) Get-AgentTeamsStoreContext $Settings.DurableStateRoot $Settings.RepositoryIdentity $Settings.TeamId $Settings.ChannelId } $send
        $outbox = & $module { param($Context) Read-AgentTeamsOutbox $Context reviewer } $context
        $payload = @($outbox.entries.Values)[0]
        $events = @('reviewCompleted')
        for ($i = 1; $i -le 12; $i++) {
            $entry = @{} + $payload
            $entry.notificationEvent = "fixtureEvent$i"
            $events += $entry.notificationEvent
            $key = & $module { param($Entry) Get-AgentTeamsOutboxKey reviewer $Entry } $entry
            $outbox.entries[$key] = $entry
        }
        & $module { param($Context, $State) Write-AgentTeamsOutbox $Context reviewer $State } $context $outbox
        $keys = @($outbox.entries.Keys | Sort-Object)
        $drain.AllowedEvents = $events
        (Invoke-AgentTeamsNotificationOutbox @drain).Processed | Should -Be 10
        $first = & $module { param($Context) Read-AgentTeamsOutbox $Context reviewer } $context
        $first.cursor | Should -BeExactly $keys[9]
        (Invoke-AgentTeamsNotificationOutbox @drain).Processed | Should -Be 10
        $second = & $module { param($Context) Read-AgentTeamsOutbox $Context reviewer } $context
        $second.cursor | Should -BeExactly $keys[6]
        $second.entries.Count | Should -Be 13
        $fake.TeamsPosts.Count | Should -Be 0
    }

    It 'retains the outbox after deadline expiry without issuing an unbounded read or send' {
        $send.DeadlineUtc = [DateTime]::UtcNow.AddSeconds(-1)
        (Send-AgentTeamsThreadedChannelMessage @send).Queued | Should -BeTrue
        $fake.Reads.Count | Should -Be 0
        $fake.TeamsPosts.Count | Should -Be 0
        $drain.DeadlineUtc = [DateTime]::UtcNow.AddSeconds(-1)
        (Invoke-AgentTeamsNotificationOutbox @drain).Processed | Should -Be 0
    }

    It 'rejects a publicly readable outbox file before using any queued payload' -Skip:(-not $IsWindows) {
        $null = Send-AgentTeamsThreadedChannelMessage @send
        $path = (Get-ChildItem $send.DurableStateRoot -Filter outbox.reviewer.json -Recurse).FullName
        $acl = Get-Acl -LiteralPath $path
        $everyone = [Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::WorldSid, $null)
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($everyone, 'Read', 'Allow'))
        Set-Acl -LiteralPath $path -AclObject $acl
        $null = Add-TeamsReferenceFixture
        (Invoke-AgentTeamsNotificationOutbox @drain).Code | Should -Be 'outbox-unavailable'
        $fake.TeamsPosts.Count | Should -Be 0
    }

    It 'exposes the same-author stale-read race and defers once conflicting ready roots become visible' {
        (Initialize-AgentTeamsPrThread @initialize).Ready | Should -BeTrue
        # Simulate another installation reading a replica that has not observed
        # the first claim. PR comments cannot provide an atomic create-if-absent.
        $fake.HiddenThroughThread = 1
        $initialize.DurableStateRoot = Join-Path $caseRoot 'second-author-installation'
        $initialize.ReferenceContext = New-AgentTeamsPrReferenceContext -AdoSession $ado -RepositoryIdentity $identity -Role review-handler -AllowWrites
        (Initialize-AgentTeamsPrThread @initialize).Ready | Should -BeTrue
        $fake.TeamsPosts.Count | Should -Be 2
        $fake.HiddenThroughThread = 0
        (Send-AgentTeamsThreadedChannelMessage @send).Code | Should -Be 'reference-conflict'
        $fake.TeamsPosts.Count | Should -Be 2
    }

    It 'keeps reference scope stable across repository renames' {
        $null = Add-TeamsReferenceFixture
        $identity.repositoryName = 'renamed-service'
        $send.PullRequestUrl = $send.PullRequestUrl.Replace('/service/', '/renamed-service/')
        (Send-AgentTeamsThreadedChannelMessage @send).Outcome | Should -Be 'reply-delivered'
        $fake.TeamsPosts[0].parentUrl | Should -Match '/shared-root/replies$'
    }

    It 'quarantines ready-to-complete notifications without source-commit authority' {
        $null = Add-TeamsReferenceFixture
        $send.NotificationEvent = 'prReadyToComplete'
        $send.SourceCommit = ''
        (Send-AgentTeamsThreadedChannelMessage @send).Code | Should -Be 'outbox-stale'
        (Invoke-AgentTeamsNotificationOutbox @drain).QuarantinedCount | Should -Be 1
        $fake.TeamsPosts.Count | Should -Be 0
    }

    It 'rejects a state exceeding reader bounds before replacing a valid outbox' {
        $null = Send-AgentTeamsThreadedChannelMessage @send
        $context = & $module { param($Settings) Get-AgentTeamsStoreContext $Settings.DurableStateRoot $Settings.RepositoryIdentity $Settings.TeamId $Settings.ChannelId } $send
        $path = Join-Path $context.Root 'outbox.reviewer.json'
        $before = [IO.File]::ReadAllText($path)
        $state = & $module { param($Context) Read-AgentTeamsOutbox $Context reviewer } $context
        @($state.entries.Values)[0].body = 'x' * 40000
        { & $module { param($Context, $State) Write-AgentTeamsOutbox $Context reviewer $State } $context $state } | Should -Throw
        [IO.File]::ReadAllText($path) | Should -BeExactly $before
    }
}
