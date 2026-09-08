# Contexts are process-local authority handles, never JSON/model capabilities.
$script:AgentTeamsPrContexts = [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
$script:AgentTeamsReferencePrefix = '[DevPilot Teams PR reference v1]'

function ConvertTo-AgentTeamsGuid {
    param($Value)
    $guid = [Guid]::Empty
    if ($Value -isnot [string] -or -not [Guid]::TryParseExact($Value, 'D', [ref]$guid) -or $guid -eq [Guid]::Empty) {
        throw [IO.InvalidDataException]::new('Invalid immutable Teams reference identity.')
    }
    return $guid.ToString('D').ToLowerInvariant()
}

function Get-AgentTeamsReferenceDeadline {
    param([Nullable[DateTime]]$DeadlineUtc)
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    if ($null -ne $DeadlineUtc -and $DeadlineUtc.ToUniversalTime() -lt $deadline) { $deadline = $DeadlineUtc.ToUniversalTime() }
    return $deadline
}

function New-AgentTeamsPrReferenceContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$AdoSession,
        [Parameter(Mandatory)]$RepositoryIdentity,
        [Parameter(Mandatory)][ValidateSet('reviewer', 'review-handler')][string]$Role,
        [switch]$AllowWrites
    )
    $key = Get-AgentRepositoryIdentityKey $RepositoryIdentity
    $id = ConvertTo-AgentTeamsGuid (Get-AgentProviderValue $RepositoryIdentity repositoryId)
    $organization = Get-AgentProviderValue $RepositoryIdentity organization
    $project = Get-AgentProviderValue $RepositoryIdentity project
    if ((Get-AgentProviderValue $RepositoryIdentity verified) -isnot [bool] -or
        (Get-AgentProviderValue $RepositoryIdentity provider) -isnot [string] -or
        (Get-AgentProviderValue $RepositoryIdentity provider) -cne 'AzureDevOps' -or
        $key -cne "v1:azuredevops:$id" -or $AdoSession.Server -cne 'ado' -or
        $organization -isnot [string] -or $organization -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9-]{0,62}\z' -or
        $project -isnot [string] -or $project.Length -lt 1 -or $project.Length -gt 256 -or $project -match '[\p{C}]') {
        throw [ArgumentException]::new('An existing ADO session and a verified Azure DevOps repository identity are required.')
    }
    $roleValue = $Role.ToLowerInvariant()
    $context = @{ Role = $roleValue; AllowWrites = [bool]$AllowWrites; RepositoryKey = $key }
    $script:AgentTeamsPrContexts.Add($context, @{
            AdoSession = $AdoSession; Role = $roleValue; AllowWrites = [bool]$AllowWrites
            RepositoryKey = $key; RepositoryId = $id; Organization = $organization; Project = $project
        })
    return $context
}

function Get-AgentTeamsPrAuthority {
    param([hashtable]$ReferenceContext, $RepositoryIdentity, [string]$Role = '')
    $authority = $null
    if ($null -eq $ReferenceContext -or -not $script:AgentTeamsPrContexts.TryGetValue($ReferenceContext, [ref]$authority) -or
        $authority.RepositoryKey -cne (Get-AgentRepositoryIdentityKey $RepositoryIdentity) -or
        ($Role -and $authority.Role -cne $Role.ToLowerInvariant())) {
        throw [ArgumentException]::new('A matching process-local Teams PR reference context is required.')
    }
    return $authority
}

function Get-AgentTeamsStoreContext {
    param([string]$DurableStateRoot, $RepositoryIdentity, [string]$TeamId, [string]$ChannelId, [int]$PullRequestId = 0)
    $key = Get-AgentRepositoryIdentityKey $RepositoryIdentity
    if ((Get-AgentProviderValue $RepositoryIdentity verified) -isnot [bool] -or $key.Length -gt 1024 -or
        -not (Test-AgentTeamsOpaqueId $TeamId) -or -not (Test-AgentTeamsOpaqueId $ChannelId)) {
        throw [ArgumentException]::new('Invalid Teams notification scope.')
    }
    $repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $root = Resolve-AgentTrustedRoot -Path $DurableStateRoot -Kind durable-state -RepositoryRoot $repositoryRoot -Create
    foreach ($segment in @((Get-AgentSha256 $key), 'teams-threads', 'v1',
            (Get-AgentSha256 (ConvertTo-Json -InputObject @($TeamId, $ChannelId) -Compress)))) {
        $root = Resolve-AgentTrustedRoot -Path (Join-Path $root $segment) -Kind durable-state -RepositoryRoot $repositoryRoot -Create
    }
    return @{
        Root = $root; RepositoryKey = $key; TeamId = $TeamId; ChannelId = $ChannelId; PullRequestId = $PullRequestId
        StatePath    = Join-Path $root "$PullRequestId.json"
        MessagesPath = "/teams/$([Uri]::EscapeDataString($TeamId))/channels/$([Uri]::EscapeDataString($ChannelId))/messages"
        Scope        = Get-AgentSha256 (ConvertTo-Json -InputObject @('teams-pr-reference-v1', $key, $PullRequestId, $TeamId, $ChannelId) -Compress)
    }
}

function Enter-AgentTeamsStoreLock {
    param([hashtable]$Context, [DateTime]$DeadlineUtc, [switch]$Bootstrap)
    $name = if ($Bootstrap) { 'references.lock' } else { 'threads.lock' }
    $path = Join-Path $Context.Root $name
    Assert-AgentPathHasNoLinks $path
    if (Test-Path -LiteralPath $path) { $null = Assert-AgentTrustedFile $path -AllowedRoot $Context.Root -Private }
    $remaining = [int][Math]::Max(0.0, [Math]::Min(2000.0, ($DeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds))
    $lock = Enter-AgentExclusiveFile -Path $path -ContentionReason state-contended -TimeoutMilliseconds $remaining
    if ($lock.Acquired -and -not $IsWindows) {
        [IO.File]::SetUnixFileMode($path, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
    }
    if (-not $lock.Acquired) { throw [IO.IOException]::new('Teams state is contended.') }
    return $lock
}

function Read-AgentTeamsProtectedJson {
    param([string]$Path, [hashtable]$Context, [int]$MaxBytes = 4MB)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $null = Assert-AgentTrustedFile $Path -AllowedRoot $Context.Root -Private
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -gt $MaxBytes) { throw [IO.InvalidDataException]::new('Teams state exceeds its bound.') }
        $bytes = [byte[]]::new([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -eq 0) { throw [IO.IOException]::new('Incomplete Teams state read.') }
            $offset += $read
        }
    }
    finally { $stream.Dispose() }
    Assert-AgentCapabilityJsonRawShape $bytes -MaxDepth 6 -MaxElements 4096 -MaxStringLength 32768 -ErrorCode teams-state-invalid
    return [Text.UTF8Encoding]::new($false, $true).GetString($bytes) | ConvertFrom-Json -AsHashtable -Depth 8
}

function Write-AgentTeamsProtectedJson {
    param([string]$Path, [hashtable]$Context, [Collections.IDictionary]$State)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $State -Depth 8 -Compress))
    Assert-AgentCapabilityJsonRawShape $bytes -MaxDepth 6 -MaxElements 4096 -MaxStringLength 32768 -ErrorCode teams-state-invalid
    $files = @(Get-ChildItem -LiteralPath $Context.Root -Force | Select-Object -First 8193)
    if ($bytes.Length -gt 4MB -or $files.Count -gt 8192 -or
        (-not (Test-Path -LiteralPath $Path) -and
            ($files.Count -ge 8192 -or @($files | Where-Object Name -Like '*.json').Count -ge 4096))) {
        throw [IO.InvalidDataException]::new('Teams state capacity is exhausted.')
    }
    $stage = Join-Path $Context.Root "reference.write-$([Guid]::NewGuid().ToString('N'))"
    try {
        if (Test-Path -LiteralPath $Path) { $null = Assert-AgentTrustedFile $Path -AllowedRoot $Context.Root -Private }
        Write-AgentFileThrough $stage $bytes
        if (-not $IsWindows) { [IO.File]::SetUnixFileMode($stage, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite) }
        $null = Assert-AgentTrustedFile $stage -AllowedRoot $Context.Root -Private
        Install-AgentFileAtomic $stage $Path
        $persisted = Read-AgentTeamsProtectedJson $Path $Context
        if ((Get-AgentCanonicalDigest $State) -cne (Get-AgentCanonicalDigest $persisted)) { throw [IO.IOException]::new('Teams state write was not confirmed.') }
    }
    finally { if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue } }
}

function Invoke-AgentTeamsAdoRead {
    param([hashtable]$Authority, [ValidateSet('repo_pull_request', 'repo_pull_request_thread')][string]$Name,
        [hashtable]$Arguments, [DateTime]$DeadlineUtc)
    if ([DateTime]::UtcNow -ge $DeadlineUtc) { throw [TimeoutException]::new('Teams reference deadline exhausted.') }
    $raw = Invoke-AgentMcpTool -Session $Authority.AdoSession -Name $Name -Arguments $Arguments -DeadlineUtc $DeadlineUtc -RawText
    if ($raw -isnot [string] -or $raw.Length -gt 2MB) { throw [IO.InvalidDataException]::new('Invalid Teams reference response.') }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($raw)
    Assert-AgentCapabilityJsonRawShape $bytes -MaxDepth 16 -MaxElements 4096 -MaxStringLength 65536 -ErrorCode teams-reference-invalid
    return , ($raw | ConvertFrom-Json -AsHashtable -Depth 20 -NoEnumerate)
}

function Get-AgentTeamsFreshPullRequest {
    param([hashtable]$Authority, [int]$PullRequestId, [DateTime]$DeadlineUtc)
    $pr = Invoke-AgentTeamsAdoRead $Authority repo_pull_request @{
        action = 'get'; project = $Authority.Project; repositoryId = $Authority.RepositoryId; pullRequestId = $PullRequestId
    } $DeadlineUtc
    $repository = Get-AgentProviderValue $pr repository
    $project = Get-AgentProviderValue $repository project
    if ($null -eq $project) { $project = Get-AgentProviderValue $repository projectReference }
    $author = Get-AgentProviderValue $pr createdBy
    $source = Get-AgentProviderValue $pr lastMergeSourceCommit
    $head = Get-AgentProviderValue $source commitId
    $uniqueName = Get-AgentProviderValue $author uniqueName
    $projectName = Get-AgentProviderValue $project name
    $projectId = Get-AgentProviderValue $project id
    $status = Get-AgentProviderValue $pr status
    if ($status -is [string]) { $status = $status.ToLowerInvariant() }
    if (-not (Test-StrictJsonInt (Get-AgentProviderValue $pr pullRequestId) -Min $PullRequestId -Max $PullRequestId) -or
        (ConvertTo-AgentTeamsGuid (Get-AgentProviderValue $repository id)) -cne $Authority.RepositoryId -or
        $projectName -isnot [string] -or
        ($projectName -ine $Authority.Project -and ($projectId -isnot [string] -or $projectId -ine $Authority.Project)) -or
        (Get-AgentProviderValue $pr isDraft) -isnot [bool] -or
        $status -isnot [string] -or $status -cnotin @('active', 'completed', 'abandoned') -or
        $head -isnot [string] -or $head -cnotmatch '\A[0-9a-fA-F]{40}(?:[0-9a-fA-F]{24})?\z' -or
        $uniqueName -isnot [string] -or $uniqueName -cnotmatch '\A[^@\s\p{C}]{1,256}@[^@\s\p{C}]{1,253}\z') {
        throw [IO.InvalidDataException]::new('Pull request identity or state is invalid.')
    }
    $url = Get-AgentProviderValue $repository url
    $uri = $null
    if ($url -isnot [string] -or -not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -cne 'https' -or $uri.UserInfo -or $uri.Port -ne 443) {
        throw [IO.InvalidDataException]::new('Repository organization cannot be verified.')
    }
    $organization = if ($uri.Host -ceq 'dev.azure.com') { [Uri]::UnescapeDataString($uri.AbsolutePath.Split('/')[1]) }
    elseif ($uri.Host.EndsWith('.visualstudio.com', [StringComparison]::Ordinal)) { $uri.Host.Substring(0, $uri.Host.Length - '.visualstudio.com'.Length) }
    else { '' }
    if ($organization -ine $Authority.Organization) { throw [IO.InvalidDataException]::new('Repository organization mismatches.') }
    $segments = @($uri.AbsolutePath.Trim('/').Split('/') | ForEach-Object { [Uri]::UnescapeDataString($_) })
    $offset = if ($uri.Host -ceq 'dev.azure.com' -or $segments[0] -ieq 'DefaultCollection') { 1 } else { 0 }
    # ADO emits either a project name or its authoritative GUID in repository URLs.
    if ($segments.Count -eq ($offset + 5)) {
        $projectSegment = $segments[$offset]
        $matchesProjectId = $projectId -is [string] -and
            $projectSegment -ieq (ConvertTo-AgentTeamsGuid $projectId)
        if ($projectSegment -ine $projectName -and -not $matchesProjectId) {
            throw [IO.InvalidDataException]::new('Repository URL project mismatches.')
        }
        $offset++
    }
    if ($uri.Query -or $uri.Fragment -or $segments.Count -ne ($offset + 4) -or
        $segments[$offset] -cne '_apis' -or $segments[$offset + 1] -cne 'git' -or
        $segments[$offset + 2] -cne 'repositories' -or
        (ConvertTo-AgentTeamsGuid $segments[$offset + 3]) -cne $Authority.RepositoryId) {
        throw [IO.InvalidDataException]::new('Repository URL scope mismatches.')
    }
    return @{
        OwnerId = ConvertTo-AgentTeamsGuid (Get-AgentProviderValue $author id)
        OwnerUpn = $uniqueName.ToLowerInvariant(); Head = $head.ToLowerInvariant()
        Active = $status -ceq 'active'; Draft = Get-AgentProviderValue $pr isDraft
    }
}

function Get-AgentTeamsAuthenticatedOwner {
    param([hashtable]$Session, [hashtable]$Authority, [int]$PullRequestId, [DateTime]$DeadlineUtc)
    if ($Authority.Role -cne 'review-handler' -or -not $Authority.AllowWrites) {
        throw [UnauthorizedAccessException]::new('Teams PR-reference writes are not enabled for this handler.')
    }
    $pr = Get-AgentTeamsFreshPullRequest $Authority $PullRequestId $DeadlineUtc
    if (-not $pr.Active -or $pr.Draft) { throw [InvalidOperationException]::new('Pull request is not active and non-draft.') }
    $me = Invoke-AgentWorkIqTool -Session $Session -Name fetch -AllowedTools @('fetch') -AllowedPathPrefixes @('/me') `
        -Arguments @{ entityUrls = @('/me?$select=id,userPrincipalName') } -DeadlineUtc $DeadlineUtc
    $upn = Get-AgentProviderValue $me userPrincipalName
    if ($upn -isnot [string] -or $upn -cnotmatch '\A[^@\s\p{C}]{1,256}@[^@\s\p{C}]{1,253}\z' -or
        -not [string]::Equals($upn, $pr.OwnerUpn, [StringComparison]::OrdinalIgnoreCase)) {
        throw [UnauthorizedAccessException]::new('The authenticated Teams principal is not the exact PR author.')
    }
    $pr.TeamsAuthorId = ConvertTo-AgentTeamsGuid (Get-AgentProviderValue $me id)
    return $pr
}

function Test-AgentTeamsPrReferenceComment {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$CommentText)
    # Deny-only classification: this deliberately does not grant routing trust.
    return $null -ne $CommentText -and $CommentText.Length -le 4096 -and
    ($CommentText.StartsWith("$script:AgentTeamsReferencePrefix`n", [StringComparison]::Ordinal) -or
    $CommentText.StartsWith("$script:AgentTeamsReferencePrefix`r`n", [StringComparison]::Ordinal))
}

function Get-AgentTeamsReferenceLink {
    param([hashtable]$Context, [string]$MessageId)
    return "https://teams.microsoft.com/l/message/$([Uri]::EscapeDataString($Context.ChannelId))/$([Uri]::EscapeDataString($MessageId))?groupId=$([Uri]::EscapeDataString($Context.TeamId))&parentMessageId=$([Uri]::EscapeDataString($MessageId))"
}

function ConvertTo-AgentTeamsReferenceComment {
    param([hashtable]$Context, [hashtable]$Claim, [ValidateSet('pending', 'ready')][string]$Phase)
    $payload = [ordered]@{
        version = 1; scope = $Context.Scope; phase = $Phase; claim = $Claim.claim
        ownerId = $Claim.ownerId; teamsAuthorId = $Claim.teamsAuthorId
        messageId = $(if ($Phase -ceq 'ready') { $Claim.messageId } else { '' }); adopted = $Claim.adopted
    }
    $text = "$script:AgentTeamsReferencePrefix`n" + (ConvertTo-Json -InputObject $payload -Compress)
    if ($Phase -ceq 'ready') { $text += "`n[Open Teams thread]($(Get-AgentTeamsReferenceLink $Context $Claim.messageId))" }
    if ($text.Length -gt 4096) { throw [IO.InvalidDataException]::new('Teams reference comment exceeds its bound.') }
    return $text
}

function ConvertFrom-AgentTeamsReferenceComment {
    param([string]$Text, [hashtable]$Context)
    if (-not (Test-AgentTeamsPrReferenceComment $Text)) { return $null }
    $lines = $Text -split '\r?\n'
    if ($lines.Count -lt 2 -or $lines.Count -gt 3) { throw [IO.InvalidDataException]::new('Malformed Teams reference marker.') }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($lines[1])
    Assert-AgentCapabilityJsonRawShape $bytes -MaxDepth 2 -MaxElements 16 -MaxStringLength 512 -ErrorCode teams-reference-invalid
    $value = $lines[1] | ConvertFrom-Json -AsHashtable -Depth 3
    Assert-AgentTeamsFields $value @('version', 'scope', 'phase', 'claim', 'ownerId', 'teamsAuthorId', 'messageId', 'adopted')
    if (-not (Test-StrictJsonInt $value.version -Min 1 -Max 1) -or
        $value.scope -isnot [string] -or $value.scope -cnotmatch '\A[0-9a-f]{64}\z' -or
        $value.phase -isnot [string] -or $value.phase -cnotin @('pending', 'ready') -or
        $value.claim -isnot [string] -or $value.claim -cnotmatch '\A[0-9a-f]{36}\z' -or
        $value.adopted -isnot [bool] -or $value.messageId -isnot [string] -or
        ($value.phase -ceq 'pending' -and ($value.messageId -cne '' -or $lines.Count -ne 2)) -or
        ($value.phase -ceq 'ready' -and (-not (Test-AgentTeamsOpaqueId $value.messageId) -or $lines.Count -ne 3))) {
        throw [IO.InvalidDataException]::new('Malformed Teams reference data.')
    }
    $value.ownerId = ConvertTo-AgentTeamsGuid $value.ownerId
    $value.teamsAuthorId = ConvertTo-AgentTeamsGuid $value.teamsAuthorId
    if ($value.scope -cne $Context.Scope) { return $null }
    if ($value.phase -ceq 'ready' -and $lines[2] -cne "[Open Teams thread]($(Get-AgentTeamsReferenceLink $Context $value.messageId))") {
        throw [IO.InvalidDataException]::new('Teams reference link mismatches its bound identifiers.')
    }
    return $value
}

function Get-AgentTeamsAdoPages {
    param([hashtable]$Authority, [hashtable]$Arguments, [DateTime]$DeadlineUtc, [hashtable]$Budget)
    $items = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[long]]::new()
    $skip = 0
    for ($page = 0; $page -lt 20; $page++) {
        if (--$Budget.calls -lt 0) { throw [IO.InvalidDataException]::new('Teams reference read budget exhausted.') }
        $argumentsForPage = @{} + $Arguments
        $argumentsForPage.top = 100
        $argumentsForPage.skip = $skip
        $response = Invoke-AgentTeamsAdoRead $Authority repo_pull_request_thread $argumentsForPage $DeadlineUtc
        $values = @()
        if ($response -is [array]) { $values = $response }
        elseif ($response -is [Collections.IDictionary] -and $response.Contains('value') -and $response.value -is [array]) { $values = $response.value }
        else { throw [IO.InvalidDataException]::new('Invalid Teams reference collection.') }
        if (@($values).Count -gt 100) { throw [IO.InvalidDataException]::new('Oversized Teams reference page.') }
        if ($response -is [Collections.IDictionary] -and $response.Contains('count') -and
            (-not (Test-StrictJsonInt $response.count -Min 0 -Max 100) -or $response.count -ne @($values).Count)) {
            throw [IO.InvalidDataException]::new('Inconsistent Teams reference page count.')
        }
        if (@($values).Count -eq 0) { return , $items.ToArray() }
        foreach ($item in $values) {
            $id = Get-AgentProviderValue $item id
            if (-not (Test-StrictJsonInt $id -Min 1 -Max ([int]::MaxValue)) -or -not $seen.Add([long]$id)) {
                throw [IO.InvalidDataException]::new('Invalid or repeated Teams reference page identifier.')
            }
            $items.Add($item)
        }
        # A short page is not proof of completion: an MCP server can cap top.
        $skip += @($values).Count
    }
    throw [IO.InvalidDataException]::new('Teams reference pagination limit exhausted.')
}

function Get-AgentTeamsPrReference {
    param([hashtable]$Authority, [hashtable]$Context, [hashtable]$PullRequest, [DateTime]$DeadlineUtc)
    $budget = @{ calls = 128 }
    $base = @{ project = $Authority.Project; repositoryId = $Authority.RepositoryId; pullRequestId = $Context.PullRequestId }
    $threads = Get-AgentTeamsAdoPages $Authority (@{ action = 'list' } + $base) $DeadlineUtc $budget
    $claims = [Collections.Generic.List[object]]::new()
    $ready = [Collections.Generic.List[object]]::new()
    $commentsSeen = 0
    foreach ($thread in $threads) {
        $comments = Get-AgentTeamsAdoPages $Authority (@{ action = 'list_comments'; threadId = $thread.id } + $base) $DeadlineUtc $budget
        $commentsSeen += @($comments).Count
        if ($commentsSeen -gt 4096) { throw [IO.InvalidDataException]::new('Teams reference comment limit exhausted.') }
        $initial = $null
        $replies = [Collections.Generic.List[object]]::new()
        foreach ($comment in $comments) {
            $author = Get-AgentProviderValue $comment author
            $authorUpn = Get-AgentProviderValue $author uniqueName
            $text = Get-AgentProviderValue $comment content
            if ($authorUpn -isnot [string] -or $authorUpn -cnotmatch '\A[^@\s\p{C}]{1,256}@[^@\s\p{C}]{1,253}\z') {
                if ($text -is [string] -and $text.StartsWith($script:AgentTeamsReferencePrefix, [StringComparison]::Ordinal)) {
                    throw [IO.InvalidDataException]::new('Teams reference comment author is unavailable.')
                }
                continue
            }
            if ($authorUpn -ine $PullRequest.OwnerUpn) { continue }
            $deleted = Get-AgentProviderValue $comment isDeleted
            if ($null -ne $deleted -and $deleted -isnot [bool]) { throw [IO.InvalidDataException]::new('Invalid Teams reference deletion flag.') }
            if ($deleted -eq $true) { continue }
            if ($text -isnot [string]) { continue }
            if (-not (Test-AgentTeamsPrReferenceComment $text)) {
                if ($text.StartsWith($script:AgentTeamsReferencePrefix, [StringComparison]::Ordinal)) {
                    throw [IO.InvalidDataException]::new('Malformed authenticated Teams reference marker.')
                }
                continue
            }
            $reference = ConvertFrom-AgentTeamsReferenceComment $text $Context
            if (-not $reference) { continue }
            if ($reference.ownerId -cne $PullRequest.OwnerId) { throw [IO.InvalidDataException]::new('Teams reference author mismatches.') }
            if ($comment.id -eq 1 -and $reference.phase -ceq 'pending') { $initial = $reference }
            elseif ($comment.id -gt 1 -and $reference.phase -ceq 'ready') { $replies.Add($reference) }
            else { throw [IO.InvalidDataException]::new('Invalid Teams reference claim ordering.') }
        }
        if (-not $initial -and $replies.Count -gt 0) { throw [IO.InvalidDataException]::new('Teams ready reference has no authenticated claim.') }
        if (-not $initial) { continue }
        $status = Get-AgentProviderValue $thread status
        if (-not (($status -is [string] -and $status -ieq 'closed') -or (Test-StrictJsonInt $status -Min 4 -Max 4))) {
            throw [IO.InvalidDataException]::new('Teams coordination thread is not closed.')
        }
        $initial.threadId = [int]$thread.id
        $claims.Add($initial)
        foreach ($reply in $replies) {
            if ($reply.claim -cne $initial.claim -or $reply.teamsAuthorId -cne $initial.teamsAuthorId -or $reply.adopted -ne $initial.adopted) {
                throw [IO.InvalidDataException]::new('Teams ready reference does not match its claim.')
            }
            $reply.threadId = [int]$thread.id
            $ready.Add($reply)
        }
    }
    if ($ready.Count -gt 0) {
        $first = $ready[0]
        foreach ($other in $ready) {
            if ($other.messageId -cne $first.messageId -or $other.claim -cne $first.claim -or $other.threadId -ne $first.threadId) {
                return @{ Status = 'conflict'; Code = 'reference-conflict' }
            }
        }
        return @{ Status = 'ready'; Reference = $first; Code = 'reference-ready' }
    }
    if ($claims.Count -gt 1) { return @{ Status = 'conflict'; Code = 'reference-conflict' } }
    if ($claims.Count -eq 1) { return @{ Status = 'pending'; Reference = $claims[0]; Code = 'reference-pending' } }
    return @{ Status = 'missing'; Code = 'reference-missing' }
}

function Get-AgentTeamsClaimRootPrefix {
    param([hashtable]$Context, [hashtable]$Claim)
    return "<p>DevPilot Teams PR reference v1: $($Context.Scope).$($Claim.claim)</p>"
}

function Assert-AgentTeamsKnownReferenceRoot {
    param([hashtable]$Session, [hashtable]$Context, [hashtable]$Reference, [DateTime]$DeadlineUtc)
    $path = "$($Context.MessagesPath)/$([Uri]::EscapeDataString($Reference.messageId))"
    $message = Invoke-AgentWorkIqTool -Session $Session -Name fetch -AllowedTools @('fetch') -AllowedPathPrefixes @($path) `
        -Arguments @{ entityUrls = @($path) } -DeadlineUtc $DeadlineUtc
    if ((Get-AgentTeamsConfirmedMessageId $message $Context root '') -cne $Reference.messageId -or
        -not $message.PSObject.Properties['channelIdentity'] -or
        -not $message.PSObject.Properties['replyToId'] -or
        -not $message.PSObject.Properties['deletedDateTime'] -or $null -ne $message.deletedDateTime -or
        (Get-AgentProviderValue $message messageType) -cne 'message') {
        throw [IO.InvalidDataException]::new('The referenced Teams root is not confirmed.')
    }
    $from = Get-AgentProviderValue $message from
    $user = Get-AgentProviderValue $from user
    if ((ConvertTo-AgentTeamsGuid (Get-AgentProviderValue $user id)) -cne $Reference.teamsAuthorId) {
        throw [IO.InvalidDataException]::new('The referenced Teams root author mismatches.')
    }
    if (-not $Reference.adopted) {
        $body = Get-AgentProviderValue $message body
        $html = Get-AgentProviderValue $body content
        $prefix = [regex]::Escape((Get-AgentTeamsClaimRootPrefix $Context $Reference))
        if ((Get-AgentProviderValue $body contentType) -cne 'html' -or $html -isnot [string] -or $html.Length -gt 131072 -or
            -not [regex]::IsMatch($html, "\A\s*(?:<div>\s*)?$prefix",
                [Text.RegularExpressions.RegexOptions]::CultureInvariant, [TimeSpan]::FromMilliseconds(100))) {
            throw [IO.InvalidDataException]::new('The referenced Teams root claim marker mismatches.')
        }
    }
}

function Read-AgentTeamsBootstrap {
    param([hashtable]$Context)
    $state = Read-AgentTeamsProtectedJson (Join-Path $Context.Root "$($Context.PullRequestId).reference.json") $Context -MaxBytes 8192
    if ($null -eq $state) { return $null }
    Assert-AgentTeamsFields $state @('version', 'scope', 'ownerId', 'teamsAuthorId', 'claim', 'phase', 'threadId', 'messageId', 'adopted')
    if (-not (Test-StrictJsonInt $state.version -Min 1 -Max 1) -or
        $state.scope -isnot [string] -or $state.scope -cne $Context.Scope -or
        $state.claim -isnot [string] -or $state.claim -cnotmatch '\A[0-9a-f]{36}\z' -or
        $state.phase -isnot [string] -or $state.phase -cnotin @('claim-intent', 'claimed', 'root-confirmed', 'ready-intent', 'ready') -or
        -not (Test-StrictJsonInt $state.threadId -Min 0 -Max ([int]::MaxValue)) -or
        $state.messageId -isnot [string] -or ($state.messageId -and -not (Test-AgentTeamsOpaqueId $state.messageId)) -or
        $state.adopted -isnot [bool] -or
        ($state.adopted -and -not $state.messageId) -or
        ($state.phase -ceq 'claim-intent' -and $state.threadId -ne 0) -or
        (-not $state.adopted -and $state.phase -cin @('claim-intent', 'claimed') -and $state.messageId) -or
        ($state.phase -cne 'claim-intent' -and $state.threadId -eq 0) -or
        ($state.phase -cin @('root-confirmed', 'ready-intent', 'ready') -and -not $state.messageId)) {
        throw [IO.InvalidDataException]::new('Invalid Teams bootstrap state.')
    }
    $null = ConvertTo-AgentTeamsGuid $state.ownerId
    $null = ConvertTo-AgentTeamsGuid $state.teamsAuthorId
    return $state
}

function Write-AgentTeamsBootstrap {
    param([hashtable]$Context, [hashtable]$State, [DateTime]$DeadlineUtc)
    $lock = Enter-AgentTeamsStoreLock $Context $DeadlineUtc
    try {
        Write-AgentTeamsProtectedJson (Join-Path $Context.Root "$($Context.PullRequestId).reference.json") $Context $State
        $null = Read-AgentTeamsBootstrap $Context
    }
    finally { Exit-AgentLock $lock.Stream }
}

function Get-AgentTeamsLocalThreadSnapshot {
    param([hashtable]$Context, [DateTime]$DeadlineUtc)
    $lock = Enter-AgentTeamsStoreLock $Context $DeadlineUtc
    try { return Read-AgentTeamsThreadState $Context }
    finally { Exit-AgentLock $lock.Stream }
}

function Invoke-AgentTeamsReferenceWrite {
    param([hashtable]$Authority, [hashtable]$Context, [hashtable]$Claim,
        [ValidateSet('create', 'reply')][string]$Action, [DateTime]$DeadlineUtc)
    if ($Authority.Role -cne 'review-handler' -or -not $Authority.AllowWrites -or [DateTime]::UtcNow -ge $DeadlineUtc) {
        throw [InvalidOperationException]::new('Teams reference write is not admitted.')
    }
    $arguments = @{
        action = $Action; project = $Authority.Project; repositoryId = $Authority.RepositoryId; pullRequestId = $Context.PullRequestId
        content = ConvertTo-AgentTeamsReferenceComment $Context $Claim $(if ($Action -ceq 'create') { 'pending' } else { 'ready' })
    }
    if ($Action -ceq 'create') { $arguments.status = 'Closed' }
    else { $arguments.threadId = $Claim.threadId }
    # A write's prose or missing ID is not proof of failure. Reconcile the
    # exact marker through the read API; never parse prose or repeat the POST.
    $null = Invoke-AgentMcpTool -Session $Authority.AdoSession -Name repo_pull_request_thread_write `
        -Arguments $arguments -RawText -DeadlineUtc $DeadlineUtc
}

function Initialize-AgentTeamsPrThread {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][hashtable]$ReferenceContext,
        [Parameter(Mandatory)][string]$DurableStateRoot,
        [Parameter(Mandatory)]$RepositoryIdentity,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$PullRequestId,
        [Parameter(Mandatory)][string]$PullRequestUrl,
        [Parameter(Mandatory)][string]$TeamId, [Parameter(Mandatory)][string]$ChannelId,
        [Nullable[DateTime]]$DeadlineUtc, [AllowNull()][hashtable]$OutputContext, [switch]$PreviewOnly
    )
    $resultOptions = @{ OutputContext = $OutputContext; PullRequestId = $PullRequestId; Operation = 'reference' }
    if ($PreviewOnly) { return New-AgentTeamsThreadResult deferred preview @resultOptions }
    $authority = Get-AgentTeamsPrAuthority $ReferenceContext $RepositoryIdentity
    $deadline = Get-AgentTeamsReferenceDeadline $DeadlineUtc
    $lock = $null
    $mutationPossible = $false
    try {
        Assert-AgentTeamsPayload @{
            pullRequestId = $PullRequestId; pullRequestUrl = $PullRequestUrl; notificationEvent = 'threadInitialized'
            sourceCommit = ''; title = "PR $PullRequestId notifications"; body = 'Automated review notifications for this pull request.'
            links = @($PullRequestUrl); status = 'queued'
        }
        if ([DateTime]::UtcNow -ge $deadline) { return New-AgentTeamsThreadResult deferred deadline @resultOptions }
        $context = Get-AgentTeamsStoreContext $DurableStateRoot $RepositoryIdentity $TeamId $ChannelId $PullRequestId
        # Local order: bootstrap lock -> short thread/outbox lock. No role lock
        # is acquired here. Use one author bootstrapper per PR: comments are
        # not an atomic global mutex, and simultaneous unseen claims can race.
        $lock = Enter-AgentTeamsStoreLock $context $deadline -Bootstrap
        $pr = Get-AgentTeamsFreshPullRequest $authority $PullRequestId $deadline
        if (-not $pr.Active -or $pr.Draft) { return New-AgentTeamsThreadResult deferred pr-ineligible @resultOptions }
        $reference = Get-AgentTeamsPrReference $authority $context $pr $deadline
        if ($reference.Status -ceq 'ready') {
            Assert-AgentTeamsKnownReferenceRoot $Session $context $reference.Reference $deadline
            return New-AgentTeamsThreadResult reference-ready reference-ready $reference.Reference.messageId @resultOptions
        }
        if ($authority.Role -cne 'review-handler' -or -not $authority.AllowWrites) {
            return New-AgentTeamsThreadResult deferred reference-writes-disabled @resultOptions
        }
        if ($reference.Status -ceq 'conflict') { return New-AgentTeamsThreadResult deferred reference-conflict @resultOptions }
        $owner = Get-AgentTeamsAuthenticatedOwner $Session $authority $PullRequestId $deadline
        $claim = Read-AgentTeamsBootstrap $context
        if ($claim -and ($claim.ownerId -cne $owner.OwnerId -or $claim.teamsAuthorId -cne $owner.TeamsAuthorId)) {
            return New-AgentTeamsThreadResult deferred bootstrap-identity-changed @resultOptions
        }
        if ($reference.Status -ceq 'pending' -and (-not $claim -or $reference.Reference.claim -cne $claim.claim)) {
            return New-AgentTeamsThreadResult deferred reference-pending @resultOptions
        }
        if ($reference.Status -ceq 'missing') {
            if ($claim) { return New-AgentTeamsThreadResult unknown claim-publication-unknown @resultOptions }
            $local = Get-AgentTeamsLocalThreadSnapshot $context $deadline
            if (-not $local.rootMessageId -and @($local.records.Values | Where-Object {
                        $_.kind -ceq 'root' -and $_.status -cin @('pending', 'unknown')
                    }).Count -gt 0) { return New-AgentTeamsThreadResult unknown root-unknown @resultOptions }
            $claim = @{
                version = 1; scope = $context.Scope; ownerId = $owner.OwnerId; teamsAuthorId = $owner.TeamsAuthorId
                claim = New-AgentNonce; phase = 'claim-intent'; threadId = 0
                messageId = $local.rootMessageId; adopted = [bool]$local.rootMessageId
            }
            if ($claim.adopted) {
                if (@($local.records.Values | Where-Object {
                            $_.kind -ceq 'root' -and $_.status -ceq 'delivered' -and $_.messageId -ceq $claim.messageId
                        }).Count -ne 1) { return New-AgentTeamsThreadResult deferred legacy-root-unproven @resultOptions }
                Assert-AgentTeamsKnownReferenceRoot $Session $context $claim $deadline
            }
            Write-AgentTeamsBootstrap $context $claim $deadline
            $mutationPossible = $true
            try { Invoke-AgentTeamsReferenceWrite $authority $context $claim create $deadline } catch { }
            $pr = Get-AgentTeamsFreshPullRequest $authority $PullRequestId $deadline
            $reference = Get-AgentTeamsPrReference $authority $context $pr $deadline
        }
        if ($reference.Status -ceq 'conflict') { return New-AgentTeamsThreadResult deferred reference-conflict @resultOptions }
        if ($reference.Status -ceq 'ready') {
            Assert-AgentTeamsKnownReferenceRoot $Session $context $reference.Reference $deadline
            return New-AgentTeamsThreadResult reference-ready reference-ready $reference.Reference.messageId @resultOptions
        }
        if ($reference.Status -cne 'pending' -or $reference.Reference.claim -cne $claim.claim -or
            $reference.Reference.teamsAuthorId -cne $claim.teamsAuthorId -or $reference.Reference.adopted -ne $claim.adopted) {
            return New-AgentTeamsThreadResult unknown claim-publication-unknown @resultOptions
        }
        if ($claim.threadId -gt 0 -and $claim.threadId -ne $reference.Reference.threadId) {
            return New-AgentTeamsThreadResult deferred reference-conflict @resultOptions
        }
        $claim.threadId = $reference.Reference.threadId
        if ($claim.phase -ceq 'claim-intent') { $claim.phase = 'claimed'; Write-AgentTeamsBootstrap $context $claim $deadline }
        if ($claim.phase -cin @('ready-intent', 'ready')) {
            return New-AgentTeamsThreadResult unknown ready-publication-unknown @resultOptions
        }
        $owner = Get-AgentTeamsAuthenticatedOwner $Session $authority $PullRequestId $deadline
        if ($owner.OwnerId -cne $claim.ownerId -or $owner.TeamsAuthorId -cne $claim.teamsAuthorId) {
            return New-AgentTeamsThreadResult deferred bootstrap-identity-changed @resultOptions
        }
        $reference = Get-AgentTeamsPrReference $authority $context $owner $deadline
        if ($reference.Status -ceq 'ready') {
            Assert-AgentTeamsKnownReferenceRoot $Session $context $reference.Reference $deadline
            return New-AgentTeamsThreadResult reference-ready reference-ready $reference.Reference.messageId @resultOptions
        }
        if ($reference.Status -cne 'pending' -or $reference.Reference.claim -cne $claim.claim -or
            $reference.Reference.threadId -ne $claim.threadId) {
            return New-AgentTeamsThreadResult deferred reference-conflict @resultOptions
        }
        if (-not $claim.messageId) {
            $local = Get-AgentTeamsLocalThreadSnapshot $context $deadline
            $bootstrapKey = Get-AgentTeamsEventKey review-handler threadInitialized (Get-AgentSha256 '')
            $receipt = $local.records[$bootstrapKey]
            if ($receipt -and $receipt.status -cin @('pending', 'unknown')) {
                return New-AgentTeamsThreadResult unknown root-unknown @resultOptions
            }
            if ($receipt -and $receipt.status -ceq 'delivered' -and $receipt.kind -ceq 'root') {
                $claim.messageId = $receipt.messageId
            }
            else {
                $mutationPossible = $true
                $created = Invoke-AgentTeamsLocalChannelMessage -Session $Session -DurableStateRoot $DurableStateRoot `
                    -RepositoryIdentity $RepositoryIdentity -Role review-handler -NotificationEvent threadInitialized `
                    -PullRequestId $PullRequestId -SourceCommit '' -TeamId $TeamId -ChannelId $ChannelId `
                    -Title "PR $PullRequestId notifications" -Body 'Automated review notifications for this pull request.' `
                    -Links @($PullRequestUrl) -DeadlineUtc $deadline -OutputContext $OutputContext `
                    -SharedAuthority @{ Mode = 'bootstrap'; RootPrefix = Get-AgentTeamsClaimRootPrefix $context $claim }
                if (-not $created.Delivered) { return $created }
                $claim.messageId = $created.MessageId
            }
        }
        Assert-AgentTeamsKnownReferenceRoot $Session $context $claim $deadline
        $claim.phase = 'root-confirmed'
        Write-AgentTeamsBootstrap $context $claim $deadline
        $owner = Get-AgentTeamsAuthenticatedOwner $Session $authority $PullRequestId $deadline
        if ($owner.OwnerId -cne $claim.ownerId -or $owner.TeamsAuthorId -cne $claim.teamsAuthorId) {
            return New-AgentTeamsThreadResult deferred bootstrap-identity-changed @resultOptions
        }
        $reference = Get-AgentTeamsPrReference $authority $context $owner $deadline
        if ($reference.Status -ceq 'ready') {
            Assert-AgentTeamsKnownReferenceRoot $Session $context $reference.Reference $deadline
            return New-AgentTeamsThreadResult reference-ready reference-ready $reference.Reference.messageId @resultOptions
        }
        if ($reference.Status -cne 'pending' -or $reference.Reference.claim -cne $claim.claim) {
            return New-AgentTeamsThreadResult deferred reference-conflict @resultOptions
        }
        if ([DateTime]::UtcNow -ge $deadline) { return New-AgentTeamsThreadResult deferred deadline @resultOptions }
        $claim.phase = 'ready-intent'
        Write-AgentTeamsBootstrap $context $claim $deadline
        $mutationPossible = $true
        try { Invoke-AgentTeamsReferenceWrite $authority $context $claim reply $deadline } catch { }
        $pr = Get-AgentTeamsFreshPullRequest $authority $PullRequestId $deadline
        $reference = Get-AgentTeamsPrReference $authority $context $pr $deadline
        if ($reference.Status -cne 'ready' -or $reference.Reference.claim -cne $claim.claim -or
            $reference.Reference.messageId -cne $claim.messageId -or $reference.Reference.threadId -ne $claim.threadId) {
            return New-AgentTeamsThreadResult unknown ready-publication-unknown @resultOptions
        }
        Assert-AgentTeamsKnownReferenceRoot $Session $context $reference.Reference $deadline
        $claim.phase = 'ready'
        Write-AgentTeamsBootstrap $context $claim $deadline
        return New-AgentTeamsThreadResult reference-ready reference-ready $claim.messageId @resultOptions
    }
    catch {
        if ($mutationPossible) { return New-AgentTeamsThreadResult unknown bootstrap-unconfirmed @resultOptions }
        return New-AgentTeamsThreadResult deferred reference-unavailable @resultOptions
    }
    finally { if ($lock) { Exit-AgentLock $lock.Stream } }
}

function Assert-AgentTeamsPayload {
    param([Collections.IDictionary]$Payload)
    Assert-AgentTeamsFields $Payload @('pullRequestId', 'pullRequestUrl', 'notificationEvent', 'sourceCommit', 'title', 'body', 'links', 'status')
    if (-not (Test-StrictJsonInt $Payload.pullRequestId -Min 1 -Max ([int]::MaxValue)) -or
        $Payload.notificationEvent -isnot [string] -or $Payload.notificationEvent -cnotmatch '\A[a-zA-Z][a-zA-Z0-9-]{0,63}\z' -or
        $Payload.sourceCommit -isnot [string] -or $Payload.sourceCommit -cnotmatch '\A[0-9A-Za-z._-]{0,128}\z' -or
        $Payload.title -isnot [string] -or $Payload.title.Length -lt 1 -or $Payload.title.Length -gt 4096 -or
        $Payload.body -isnot [string] -or $Payload.body.Length -lt 1 -or $Payload.body.Length -gt 24576 -or
        $Payload.links -isnot [array] -or $Payload.links.Count -gt 16 -or
        $Payload.status -isnot [string] -or $Payload.status -cnotin @('queued', 'unknown', 'failed', 'stale') -or $Payload.pullRequestUrl -isnot [string]) {
        throw [IO.InvalidDataException]::new('Invalid Teams outbox payload.')
    }
    foreach ($link in @($Payload.links) + @($Payload.pullRequestUrl)) {
        $uri = $null
        if ($link -isnot [string] -or $link.Length -gt 2048 -or $link -match '[\p{C}]' -or
            -not [Uri]::TryCreate($link, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.UserInfo) {
            throw [IO.InvalidDataException]::new('Invalid Teams outbox link.')
        }
    }
    $prUri = [Uri]$Payload.pullRequestUrl
    if ($prUri.Query -or $prUri.Fragment -or -not $prUri.AbsolutePath.EndsWith("/$($Payload.pullRequestId)", [StringComparison]::Ordinal)) {
        throw [IO.InvalidDataException]::new('Invalid Teams outbox pull request URL.')
    }
}

function Get-AgentTeamsOutboxKey {
    param([string]$Role, [Collections.IDictionary]$Payload)
    $event = Get-AgentTeamsEventKey $Role $Payload.notificationEvent (Get-AgentSha256 $Payload.sourceCommit)
    return Get-AgentSha256 "$($Payload.pullRequestId):$event"
}

function Read-AgentTeamsOutbox {
    param([hashtable]$Context, [string]$Role)
    $state = Read-AgentTeamsProtectedJson (Join-Path $Context.Root "outbox.$Role.json") $Context
    if ($null -eq $state) {
        return @{ version = 1; repositoryKey = $Context.RepositoryKey; teamId = $Context.TeamId; channelId = $Context.ChannelId; role = $Role; cursor = ''; entries = @{} }
    }
    Assert-AgentTeamsFields $state @('version', 'repositoryKey', 'teamId', 'channelId', 'role', 'cursor', 'entries')
    if (-not (Test-StrictJsonInt $state.version -Min 1 -Max 1) -or
        $state.repositoryKey -isnot [string] -or $state.repositoryKey -cne $Context.RepositoryKey -or
        $state.teamId -isnot [string] -or $state.teamId -cne $Context.TeamId -or
        $state.channelId -isnot [string] -or $state.channelId -cne $Context.ChannelId -or
        $state.role -isnot [string] -or $state.role -cne $Role -or
        $state.cursor -isnot [string] -or $state.cursor -cnotmatch '\A(?:[0-9a-f]{64})?\z' -or
        $state.entries -isnot [Collections.IDictionary] -or $state.entries.Count -gt 128) {
        throw [IO.InvalidDataException]::new('Teams outbox binding or bounds are invalid.')
    }
    foreach ($key in $state.entries.Keys) {
        Assert-AgentTeamsPayload $state.entries[$key]
        if ($key -isnot [string] -or $key -cne (Get-AgentTeamsOutboxKey $Role $state.entries[$key])) {
            throw [IO.InvalidDataException]::new('Teams outbox event binding is invalid.')
        }
    }
    return $state
}

function Write-AgentTeamsOutbox {
    param([hashtable]$Context, [string]$Role, [Collections.IDictionary]$State)
    Write-AgentTeamsProtectedJson (Join-Path $Context.Root "outbox.$Role.json") $Context $State
    $null = Read-AgentTeamsOutbox $Context $Role
}

function Set-AgentTeamsOutboxDisposition {
    param([hashtable]$Context, [string]$Role, [string]$Key,
        [ValidateSet('delivered', 'unknown', 'failed', 'stale')][string]$Status, [DateTime]$DeadlineUtc)
    $lock = Enter-AgentTeamsStoreLock $Context $DeadlineUtc
    try {
        $outbox = Read-AgentTeamsOutbox $Context $Role
        if ($outbox.entries.Contains($Key)) {
            if ($Status -ceq 'delivered') { $outbox.entries.Remove($Key) }
            else { $outbox.entries[$Key].status = $Status }
            Write-AgentTeamsOutbox $Context $Role $outbox
        }
    }
    finally { Exit-AgentLock $lock.Stream }
}

function Send-AgentTeamsSharedChannelMessage {
    param(
        [hashtable]$Session, [hashtable]$ReferenceContext, [string]$DurableStateRoot, $RepositoryIdentity,
        [string]$Role, [string]$NotificationEvent, [int]$PullRequestId, [AllowEmptyString()][string]$SourceCommit,
        [string]$TeamId, [string]$ChannelId, [string]$Title, [string]$Body, [string[]]$Links = @(),
        [string]$PullRequestUrl = '', [Nullable[DateTime]]$DeadlineUtc, [hashtable]$OutputContext, [switch]$PreviewOnly
    )
    $Role = $Role.ToLowerInvariant()
    $options = @{ OutputContext = $OutputContext; PullRequestId = $PullRequestId; Operation = 'outbox' }
    if ($PreviewOnly) { return New-AgentTeamsThreadResult deferred preview @options }
    $authority = Get-AgentTeamsPrAuthority $ReferenceContext $RepositoryIdentity $Role
    $deadline = Get-AgentTeamsReferenceDeadline $DeadlineUtc
    $payload = @{
        pullRequestId = $PullRequestId; pullRequestUrl = $PullRequestUrl; notificationEvent = $NotificationEvent
        sourceCommit = $SourceCommit; title = $Title; body = $Body; links = @($Links); status = 'queued'
    }
    Assert-AgentTeamsPayload $payload
    $queued = $false
    $result = $null
    try {
        $context = Get-AgentTeamsStoreContext $DurableStateRoot $RepositoryIdentity $TeamId $ChannelId $PullRequestId
        $key = Get-AgentTeamsOutboxKey $Role $payload
        $lock = Enter-AgentTeamsStoreLock $context $deadline
        try {
            $state = Read-AgentTeamsThreadState $context
            $eventKey = Get-AgentTeamsEventKey $Role $NotificationEvent (Get-AgentSha256 $SourceCommit)
            $receipt = $state.records[$eventKey]
            if ($receipt -and $receipt.status -ceq 'delivered') {
                $result = New-AgentTeamsThreadResult deduped confirmed $receipt.messageId @options
                $outbox = Read-AgentTeamsOutbox $context $Role
                if ($outbox.entries.Contains($key)) { $outbox.entries.Remove($key); Write-AgentTeamsOutbox $context $Role $outbox }
                return $result
            }
            $outbox = Read-AgentTeamsOutbox $context $Role
            if ($receipt -and $receipt.status -cin @('pending', 'unknown', 'failed')) {
                $status = if ($receipt.status -ceq 'failed') { 'failed' } else { 'unknown' }
                if ($outbox.entries.Contains($key)) { $outbox.entries[$key].status = $status; Write-AgentTeamsOutbox $context $Role $outbox }
                return New-AgentTeamsThreadResult $status $receipt.code @options
            }
            if (-not $outbox.entries.Contains($key)) {
                if ($outbox.entries.Count -ge 128) { return New-AgentTeamsThreadResult failed outbox-capacity @options }
                $outbox.entries[$key] = $payload
                Write-AgentTeamsOutbox $context $Role $outbox
            }
            else { $payload = $outbox.entries[$key] }
            if ($payload.status -cne 'queued') { return New-AgentTeamsThreadResult deferred outbox-quarantined @options }
            $queued = $true
        }
        finally { Exit-AgentLock $lock.Stream }
        $pr = Get-AgentTeamsFreshPullRequest $authority $PullRequestId $deadline
        if (-not $pr.Active -or $pr.Draft -or
            ($payload.sourceCommit -and $payload.sourceCommit -ine $pr.Head) -or
            ($payload.notificationEvent -ceq 'prReadyToComplete' -and -not $payload.sourceCommit)) {
            Set-AgentTeamsOutboxDisposition $context $Role $key stale $deadline
            return New-AgentTeamsThreadResult deferred outbox-stale @options
        }
        $reference = Get-AgentTeamsPrReference $authority $context $pr $deadline
        if ($reference.Status -cne 'ready') { return New-AgentTeamsThreadResult queued $reference.Code @options }
        Assert-AgentTeamsKnownReferenceRoot $Session $context $reference.Reference $deadline
        $result = Invoke-AgentTeamsLocalChannelMessage -Session $Session -DurableStateRoot $DurableStateRoot `
            -RepositoryIdentity $RepositoryIdentity -Role $Role -NotificationEvent $payload.notificationEvent `
            -PullRequestId $PullRequestId -SourceCommit $payload.sourceCommit -TeamId $TeamId -ChannelId $ChannelId `
            -Title $payload.title -Body $payload.body -Links $payload.links -DeadlineUtc $deadline -OutputContext $OutputContext `
            -SharedAuthority @{ Mode = 'reply'; RootId = $reference.Reference.messageId }
        if ($result.Delivered) { Set-AgentTeamsOutboxDisposition $context $Role $key delivered $deadline }
        elseif ($result.Outcome -cin @('unknown', 'failed')) { Set-AgentTeamsOutboxDisposition $context $Role $key $result.Outcome $deadline }
        elseif ($result.Outcome -ceq 'deferred') { return New-AgentTeamsThreadResult queued $result.Code @options }
        return $result
    }
    catch {
        if ($result) {
            $cleanup = New-AgentTeamsThreadResult deferred outbox-cleanup-deferred @options
            $result.Audit += $cleanup.Audit
            return $result
        }
        if ($queued) { return New-AgentTeamsThreadResult queued reference-unavailable @options }
        return New-AgentTeamsThreadResult failed outbox-unavailable @options
    }
}

function Invoke-AgentTeamsNotificationOutbox {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Session, [Parameter(Mandatory)][hashtable]$ReferenceContext,
        [Parameter(Mandatory)][string]$DurableStateRoot, [Parameter(Mandatory)]$RepositoryIdentity,
        [Parameter(Mandatory)][ValidateSet('reviewer', 'review-handler')][string]$Role,
        [Parameter(Mandatory)][string]$TeamId, [Parameter(Mandatory)][string]$ChannelId,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AllowedEvents,
        [ValidateRange(0, 2147483647)][int]$PullRequestId = 0,
        [Nullable[DateTime]]$DeadlineUtc, [hashtable]$OutputContext, [switch]$PreviewOnly
    )
    $summary = @{ Delivered = $false; Deduped = $false; Outcome = 'outbox-drained'; Code = 'outbox-drained'
        Processed = 0; DeliveredCount = 0; QueuedCount = 0; QuarantinedCount = 0; Results = @()
    }
    if ($PreviewOnly) { $summary.Outcome = 'deferred'; $summary.Code = 'preview'; return $summary }
    $Role = $Role.ToLowerInvariant()
    $null = Get-AgentTeamsPrAuthority $ReferenceContext $RepositoryIdentity $Role
    if ($AllowedEvents.Count -gt 64 -or @($AllowedEvents | Where-Object { $_ -cnotmatch '\A[a-zA-Z][a-zA-Z0-9-]{0,63}\z' }).Count -gt 0) {
        throw [ArgumentException]::new('Invalid Teams event subscriptions.')
    }
    $deadline = Get-AgentTeamsReferenceDeadline $DeadlineUtc
    try {
        $context = Get-AgentTeamsStoreContext $DurableStateRoot $RepositoryIdentity $TeamId $ChannelId
        $lock = Enter-AgentTeamsStoreLock $context $deadline
        try { $outbox = Read-AgentTeamsOutbox $context $Role }
        finally { Exit-AgentLock $lock.Stream }
        $keys = @($outbox.entries.Keys | Sort-Object)
        $ordered = @($keys | Where-Object { [StringComparer]::Ordinal.Compare($_, $outbox.cursor) -gt 0 }) +
        @($keys | Where-Object { [StringComparer]::Ordinal.Compare($_, $outbox.cursor) -le 0 })
        $lastKey = ''
        foreach ($key in $ordered) {
            $entry = $outbox.entries[$key]
            if ($PullRequestId -gt 0 -and $entry.pullRequestId -ne $PullRequestId) { continue }
            if ($entry.status -cne 'queued' -or $AllowedEvents -cnotcontains $entry.notificationEvent) { continue }
            if ($summary.Processed -ge 10 -or [DateTime]::UtcNow -ge $deadline) { break }
            $result = Send-AgentTeamsThreadedChannelMessage -Session $Session -ReferenceContext $ReferenceContext `
                -DurableStateRoot $DurableStateRoot -RepositoryIdentity $RepositoryIdentity -Role $Role `
                -NotificationEvent $entry.notificationEvent -PullRequestId $entry.pullRequestId -SourceCommit $entry.sourceCommit `
                -TeamId $TeamId -ChannelId $ChannelId -Title $entry.title -Body $entry.body -Links $entry.links `
                -PullRequestUrl $entry.pullRequestUrl -DeadlineUtc $deadline -OutputContext $OutputContext
            $summary.Processed++
            if ($result.Delivered) { $summary.DeliveredCount++ }
            $summary.Results += $result
            $lastKey = $key
        }
        $lock = Enter-AgentTeamsStoreLock $context $deadline
        try {
            $outbox = Read-AgentTeamsOutbox $context $Role
            if ($lastKey -and $PullRequestId -eq 0) { $outbox.cursor = $lastKey; Write-AgentTeamsOutbox $context $Role $outbox }
            $scopedEntries = @($outbox.entries.Values | Where-Object { $PullRequestId -eq 0 -or $_.pullRequestId -eq $PullRequestId })
            $summary.QueuedCount = @($scopedEntries | Where-Object status -CEQ queued).Count
            $summary.QuarantinedCount = @($scopedEntries | Where-Object status -CNE queued).Count
        }
        finally { Exit-AgentLock $lock.Stream }
        return $summary
    }
    catch {
        $summary.Outcome = 'deferred'
        $summary.Code = 'outbox-unavailable'
        $diagnostic = New-AgentTeamsThreadResult deferred outbox-unavailable -Operation outbox -OutputContext $OutputContext
        $summary.Audit = $diagnostic.Audit
        return $summary
    }
}
