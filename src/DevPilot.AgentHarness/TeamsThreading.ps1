# Caller-gated channel notifications only. Local mode needs no message reads;
# shared references verify known roots separately. An intent is not delivery.

function Test-AgentTeamsOpaqueId {
    param([AllowNull()]$Value)
    return $Value -is [string] -and $Value.Length -ge 1 -and $Value.Length -le 512 -and
        $Value -notmatch '[\s\p{C}]' -and $Value -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*:' -and
        $Value -cnotin @('.', '..')
}

function Get-AgentTeamsEventKey {
    param([string]$Role, [string]$NotificationEvent, [string]$SourceCommitHash)
    return Get-AgentSha256 -Text (ConvertTo-Json -InputObject @($Role, $NotificationEvent, $SourceCommitHash) -Compress)
}

function New-AgentTeamsThreadResult {
    param(
        [string]$Outcome, [string]$Code, [string]$MessageId = '',
        [AllowNull()][hashtable]$OutputContext, [int]$PullRequestId,
        [ValidateSet('', 'root', 'reply', 'fallback', 'reference', 'outbox')][string]$Operation = '',
        [AllowNull()][Collections.Generic.List[object]]$AuditHistory
    )
    $audit = @{ outcome = $Outcome; code = $Code }
    if ($Operation) { $audit.operation = $Operation }
    $priorAudit = @(if ($null -ne $AuditHistory) { $AuditHistory.ToArray() })
    $result = @{
        Delivered = $Outcome -cin @('root-created', 'reply-delivered', 'fallback-delivered', 'deduped')
        Deduped = $Outcome -ceq 'deduped'
        Queued = $Outcome -ceq 'queued'
        Ready = $Outcome -ceq 'reference-ready'
        Outcome = $Outcome
        Code = $Code
        Audit = @($priorAudit) + @($audit)
    }
    if ($MessageId) { $result.MessageId = $MessageId }
    if ($null -ne $OutputContext) {
        try {
            $operationLabel = if ($Operation) { " ($Operation)" } else { '' }
            $published = Publish-AgentEvent -Context $OutputContext -EventType notification.delivery `
                -Level $(if ($result.Delivered -or $result.Ready) { 'info' } else { 'warning' }) -PrId $PullRequestId `
                -Data $audit -Message "Teams notification${operationLabel}: $Outcome ($Code)."
            if ($null -eq $published) { $result.Audit += @{ outcome = $Outcome; code = 'audit-unavailable' } }
        }
        catch {
            # Observational output must never change a persisted delivery or
            # cause a caller to repeat a message whose send was confirmed.
            $result.Audit += @{ outcome = $Outcome; code = 'audit-unavailable' }
        }
    }
    return $result
}

function Assert-AgentTeamsFields {
    param($Value, [string[]]$Fields)
    if ($Value -isnot [System.Collections.IDictionary] -or $Value.Count -ne $Fields.Count) {
        throw [IO.InvalidDataException]::new('Teams state schema is invalid.')
    }
    foreach ($key in $Value.Keys) {
        if ($Fields -cnotcontains $key) { throw [IO.InvalidDataException]::new('Teams state schema is invalid.') }
    }
}

function Assert-AgentTeamsThreadState {
    param($State, [hashtable]$Context)
    $fields = @('schemaVersion', 'repositoryKey', 'teamId', 'channelId', 'pullRequestId', 'rootMessageId', 'records')
    $shared = $State -is [Collections.IDictionary] -and (Test-StrictJsonInt $State.schemaVersion -Min 2 -Max 2)
    if ($shared) { $fields += 'rootProvenance' }
    Assert-AgentTeamsFields $State $fields
    if (-not (Test-StrictJsonInt $State.schemaVersion -Min 1 -Max 2) -or
        $State.repositoryKey -isnot [string] -or $State.repositoryKey -cne $Context.RepositoryKey -or
        $State.teamId -isnot [string] -or $State.teamId -cne $Context.TeamId -or
        $State.channelId -isnot [string] -or $State.channelId -cne $Context.ChannelId -or
        -not (Test-StrictJsonInt $State.pullRequestId -Min 1 -Max ([int]::MaxValue)) -or
        $State.pullRequestId -ne $Context.PullRequestId -or
        $State.rootMessageId -isnot [string] -or
        ($State.rootMessageId -and -not (Test-AgentTeamsOpaqueId $State.rootMessageId)) -or
        $State.records -isnot [System.Collections.IDictionary] -or $State.records.Count -gt 256) {
        throw [IO.InvalidDataException]::new('Teams state binding or bounds are invalid.')
    }
    if ($shared -and ($State.rootProvenance -isnot [string] -or
        $State.rootProvenance -cnotin @('none', 'local', 'shared-reference') -or
        (($State.rootMessageId -ceq '') -ne ($State.rootProvenance -ceq 'none')))) {
        throw [IO.InvalidDataException]::new('Teams root provenance is invalid.')
    }
    $confirmedRoots = 0
    $localCanonicalReceipts = 0
    $uncertainRoots = 0
    foreach ($key in $State.records.Keys) {
        $record = $State.records[$key]
        Assert-AgentTeamsFields $record @('role', 'notificationEvent', 'sourceCommitHash', 'kind', 'status', 'messageId', 'attempts', 'retryNotBefore', 'code')
        if ($key -isnot [string] -or $key -cnotmatch '\A[0-9a-f]{64}\z' -or
            $record.role -isnot [string] -or $record.role -cnotin @('reviewer', 'review-handler') -or
            $record.notificationEvent -isnot [string] -or $record.notificationEvent -cnotmatch '\A[a-zA-Z][a-zA-Z0-9-]{0,63}\z' -or
            $record.sourceCommitHash -isnot [string] -or $record.sourceCommitHash -cnotmatch '\A[0-9a-f]{64}\z' -or
            $key -cne (Get-AgentTeamsEventKey $record.role $record.notificationEvent $record.sourceCommitHash) -or
            $record.kind -isnot [string] -or $record.kind -cnotin @('root', 'reply', 'fallback') -or
            $record.status -isnot [string] -or $record.status -cnotin @('not-sent', 'pending', 'unknown', 'delivered', 'failed') -or
            $record.messageId -isnot [string] -or
            -not (Test-StrictJsonInt $record.attempts -Min 0 -Max 3) -or
            -not (Test-StrictJsonInt $record.retryNotBefore -Min 0 -Max 253402300799) -or
            $record.code -isnot [string] -or $record.code -cnotin @(
                'intent', 'confirmed', 'send-unknown', 'http-rejected', 'throttled',
                'throttled-metadata-unavailable', 'stale-root')) {
            throw [IO.InvalidDataException]::new('Teams receipt is invalid.')
        }
        $validTransition = switch -CaseSensitive ($record.status) {
            pending { $record.code -ceq 'intent' -and $record.retryNotBefore -eq 0 }
            unknown { $record.code -ceq 'send-unknown' -and $record.retryNotBefore -eq 0 }
            delivered { $record.code -ceq 'confirmed' -and $record.retryNotBefore -eq 0 }
            failed { $record.code -ceq 'http-rejected' -and $record.retryNotBefore -eq 0 }
            not-sent {
                $record.code -ceq 'throttled' -or
                    ($record.code -ceq 'throttled-metadata-unavailable' -and $record.retryNotBefore -eq 0) -or
                    ($record.code -ceq 'stale-root' -and $record.kind -ceq 'fallback' -and $record.retryNotBefore -eq 0)
            }
        }
        if (-not $validTransition -or $record.attempts -lt 1 -or
            ($record.kind -ceq 'fallback' -and $record.status -cne 'not-sent' -and $record.attempts -lt 2)) {
            throw [IO.InvalidDataException]::new('Teams receipt transition is invalid.')
        }
        if ($record.status -ceq 'delivered') {
            if (-not (Test-AgentTeamsOpaqueId $record.messageId) -or $record.attempts -lt 1 -or $record.code -cne 'confirmed') {
                throw [IO.InvalidDataException]::new('Teams delivery receipt is invalid.')
            }
            if ($record.kind -ceq 'root') {
                $confirmedRoots++
                if ($record.messageId -ceq $State.rootMessageId) { $localCanonicalReceipts++ }
                elseif (-not $shared) { throw [IO.InvalidDataException]::new('Teams root receipt mismatches.') }
            }
        }
        elseif ($record.messageId -cne '') { throw [IO.InvalidDataException]::new('Teams unconfirmed receipt carries a message id.') }
        if ($record.status -cin @('pending', 'unknown') -and $record.attempts -lt 1) {
            throw [IO.InvalidDataException]::new('Teams intent has no attempt.')
        }
        if ($record.kind -ceq 'root' -and $record.status -cin @('pending', 'unknown')) { $uncertainRoots++ }
        if ($record.kind -cne 'root' -and -not $State.rootMessageId) {
            throw [IO.InvalidDataException]::new('Teams reply has no confirmed root.')
        }
    }
    if (($confirmedRoots + $uncertainRoots -gt 1) -or
        (-not $shared -and $State.rootMessageId -and ($confirmedRoots -ne 1 -or $uncertainRoots -ne 0)) -or
        (-not $State.rootMessageId -and ($confirmedRoots -ne 0 -or $uncertainRoots -gt 1)) -or
        ($shared -and $State.rootProvenance -ceq 'local' -and $localCanonicalReceipts -ne 1)) {
        throw [IO.InvalidDataException]::new('Teams root state is inconsistent.')
    }
}

function Read-AgentTeamsThreadState {
    param([hashtable]$Context)
    if (-not (Test-Path -LiteralPath $Context.StatePath)) {
        return @{
            schemaVersion = 1; repositoryKey = $Context.RepositoryKey; teamId = $Context.TeamId
            channelId = $Context.ChannelId; pullRequestId = $Context.PullRequestId
            rootMessageId = ''; records = @{}
        }
    }
    $null = Assert-AgentTrustedFile -Path $Context.StatePath -AllowedRoot $Context.Root -Private
    $stream = [IO.FileStream]::new($Context.StatePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -gt 1MB) { throw [IO.InvalidDataException]::new('Teams state exceeds its size limit.') }
        $bytes = [byte[]]::new([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -eq 0) { throw [IO.InvalidDataException]::new('Teams state read was incomplete.') }
            $offset += $read
        }
    }
    finally { $stream.Dispose() }
    Assert-AgentCapabilityJsonRawShape -Bytes $bytes -MaxDepth 4 -MaxElements 4096 -MaxStringLength 1024 -ErrorCode teams-state-invalid
    $state = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) | ConvertFrom-Json -AsHashtable -Depth 5 -ErrorAction Stop
    Assert-AgentTeamsThreadState $state $Context
    return $state
}

function Write-AgentTeamsThreadState {
    param([hashtable]$Context, $State)
    Assert-AgentTeamsThreadState $State $Context
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $State -Depth 6 -Compress))
    if ($bytes.Length -gt 1MB) { throw [IO.InvalidDataException]::new('Teams state exceeds its size limit.') }
    Assert-AgentCapabilityJsonRawShape -Bytes $bytes -MaxDepth 4 -MaxElements 4096 -MaxStringLength 1024 -ErrorCode teams-state-invalid
    $staging = Join-Path $Context.Root "$($Context.PullRequestId).write-$([Guid]::NewGuid().ToString('N'))"
    try {
        if (Test-Path -LiteralPath $Context.StatePath) {
            $null = Assert-AgentTrustedFile -Path $Context.StatePath -AllowedRoot $Context.Root -Private
        }
        Write-AgentFileThrough -Path $staging -Bytes $bytes
        if (-not $IsWindows) {
            [IO.File]::SetUnixFileMode($staging, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
        }
        $null = Assert-AgentTrustedFile -Path $staging -AllowedRoot $Context.Root -Private
        Install-AgentFileAtomic -Source $staging -Destination $Context.StatePath
        $persisted = Read-AgentTeamsThreadState $Context
        if ((Get-AgentCanonicalDigest $persisted) -cne (Get-AgentCanonicalDigest $State)) {
            throw [IO.InvalidDataException]::new('Teams state write was not confirmed.')
        }
    }
    finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue }
    }
}

function Get-AgentTeamsRetryNotBefore {
    param([AllowNull()]$Value)
    if ($Value -isnot [string] -or $Value.Length -gt 128) { return $null }
    $seconds = 0L
    if ($Value -cmatch '^[0-9]{1,10}$' -and [long]::TryParse($Value, [ref]$seconds) -and $seconds -le [int]::MaxValue) {
        # Round upward: never shorten the server's requested delay.
        return [long][Math]::Ceiling(([DateTimeOffset]::UtcNow.AddSeconds($seconds)).ToUnixTimeMilliseconds() / 1000.0)
    }
    $date = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParseExact($Value, 'r', [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$date)) {
        return [long][Math]::Max(0L, $date.ToUnixTimeSeconds())
    }
    return $null
}

function Get-AgentTeamsConfirmedMessageId {
    param($Response, [hashtable]$Context, [string]$Kind, [string]$RootMessageId)
    if ($Response -isnot [System.Management.Automation.PSCustomObject]) { return $null }
    $id = $Response.PSObject.Properties['id']
    if (-not $id -or -not (Test-AgentTeamsOpaqueId $id.Value)) { return $null }
    $channel = $Response.PSObject.Properties['channelIdentity']
    if ($channel) {
        if ($channel.Value -isnot [System.Management.Automation.PSCustomObject]) { return $null }
        foreach ($name in @('teamId', 'channelId')) {
            $property = $channel.Value.PSObject.Properties[$name]
            if (-not $property -or $property.Value -isnot [string] -or $property.Value -cne $Context[$name]) { return $null }
        }
    }
    foreach ($name in @('teamId', 'channelId')) {
        $property = $Response.PSObject.Properties[$name]
        if ($property -and ($property.Value -isnot [string] -or $property.Value -cne $Context[$name])) { return $null }
    }
    $reply = $Response.PSObject.Properties['replyToId']
    if ($reply) {
        if ($Kind -ceq 'reply') {
            if ($reply.Value -isnot [string] -or $reply.Value -cne $RootMessageId) { return $null }
        }
        elseif ($null -ne $reply.Value -and $reply.Value -cne '') { return $null }
    }
    return $id.Value
}

function Invoke-AgentTeamsLocalChannelMessage {
    <#
        The wrapper must gate this call and validate DurableStateRoot against
        its actual consumer repository. This helper revalidates private paths.
        Lock order: existing caller role authority -> destination thread lock;
        never acquire another role lock. A partition lock also bounds PR files.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][string]$DurableStateRoot,
        [Parameter(Mandatory)]$RepositoryIdentity,
        [Parameter(Mandatory)][ValidateSet('reviewer', 'review-handler')][string]$Role,
        [Parameter(Mandatory)][ValidatePattern('\A[a-zA-Z][a-zA-Z0-9-]{0,63}\z')][string]$NotificationEvent,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$PullRequestId,
        [Parameter(Mandatory)][AllowEmptyString()][ValidatePattern('\A[0-9A-Za-z._-]{0,128}\z')][string]$SourceCommit,
        [Parameter(Mandatory)][string]$TeamId,
        [Parameter(Mandatory)][string]$ChannelId,
        [Parameter(Mandatory)][ValidateLength(1, 4096)][string]$Title,
        [Parameter(Mandatory)][ValidateLength(1, 24576)][string]$Body,
        [string[]]$Links = @(),
        [Nullable[DateTime]]$DeadlineUtc,
        [AllowNull()][hashtable]$OutputContext,
        [AllowNull()][hashtable]$SharedAuthority
    )
    $repositoryKey = Get-AgentRepositoryIdentityKey $RepositoryIdentity
    if ((Get-AgentProviderValue $RepositoryIdentity 'verified') -isnot [bool] -or $repositoryKey.Length -gt 1024 -or
        $repositoryKey -cnotmatch '\Av1:(azuredevops|github):[^:\p{C}\s]+\z') {
        throw [ArgumentException]::new('A verified repository identity is required.')
    }
    if (-not (Test-AgentTeamsOpaqueId $TeamId) -or -not (Test-AgentTeamsOpaqueId $ChannelId)) {
        throw [ArgumentException]::new('Teams destination identifiers are invalid.')
    }
    if ($Links.Count -gt 16) { throw [ArgumentException]::new('Too many Teams notification links.') }
    foreach ($link in $Links) {
        $uri = $null
        if ($null -eq $link -or $link.Length -gt 2048 -or
            -not [Uri]::TryCreate($link, [UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -cne 'https' -or $uri.UserInfo -or $link -match '[\r\n]') {
            throw [ArgumentException]::new('Teams notification links must be bounded HTTPS URLs without user information.')
        }
    }
    $Role = $Role.ToLowerInvariant()
    $resultOptions = @{
        OutputContext = $OutputContext; PullRequestId = $PullRequestId; Operation = ''
        AuditHistory = [Collections.Generic.List[object]]::new()
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    if ($null -ne $DeadlineUtc -and $DeadlineUtc.ToUniversalTime() -lt $deadline) { $deadline = $DeadlineUtc.ToUniversalTime() }
    if ($deadline -le [DateTime]::UtcNow) { return New-AgentTeamsThreadResult deferred deadline @resultOptions }
    $context = @{
        RepositoryKey = $repositoryKey; TeamId = $TeamId; ChannelId = $ChannelId; PullRequestId = $PullRequestId
    }
    $lock = $null
    $sendMayHaveLanded = $false
    try {
        $repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $root = Resolve-AgentTrustedRoot -Path $DurableStateRoot -Kind durable-state -RepositoryRoot $repositoryRoot -Create
        foreach ($segment in @((Get-AgentSha256 $repositoryKey), 'teams-threads', 'v1',
                (Get-AgentSha256 (ConvertTo-Json -InputObject @($TeamId, $ChannelId) -Compress)))) {
            $root = Resolve-AgentTrustedRoot -Path (Join-Path $root $segment) -Kind durable-state -RepositoryRoot $repositoryRoot -Create
        }
        $context.Root = $root
        $context.StatePath = Join-Path $root "$PullRequestId.json"
        $lockPath = Join-Path $root 'threads.lock'
        Assert-AgentPathHasNoLinks -Path $lockPath
        if (Test-Path -LiteralPath $lockPath) {
            $null = Assert-AgentTrustedFile -Path $lockPath -AllowedRoot $root -Private
        }
        $remaining = [int][Math]::Max(0, [Math]::Min(2000, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
        $lock = Enter-AgentExclusiveFile -Path $lockPath -ContentionReason state-contended -TimeoutMilliseconds $remaining
        if (-not $lock.Acquired) { return New-AgentTeamsThreadResult deferred state-contended @resultOptions }
        if (-not $IsWindows) {
            [IO.File]::SetUnixFileMode($lockPath, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
        }
        # Do not repair or adopt orphan writes: the installed pending intent is
        # authoritative after a crash. Leftovers count toward the hard file cap.
        $files = @(Get-ChildItem -LiteralPath $root -Force | Select-Object -First 8193)
        if ($files.Count -gt 8192 -or
            (-not (Test-Path -LiteralPath $context.StatePath) -and @($files | Where-Object Name -Like '*.json').Count -ge 4096)) {
            return New-AgentTeamsThreadResult failed state-capacity @resultOptions
        }
        $state = Read-AgentTeamsThreadState $context
        $sourceHash = Get-AgentSha256 $SourceCommit
        $eventKey = Get-AgentTeamsEventKey $Role $NotificationEvent $sourceHash
        $record = $state.records[$eventKey]
        if ($null -ne $record) {
            $resultOptions.Operation = $record.kind
            if ($record.status -ceq 'delivered') { return New-AgentTeamsThreadResult deduped confirmed $record.messageId @resultOptions }
            if ($record.status -cin @('pending', 'unknown')) { return New-AgentTeamsThreadResult unknown send-unknown @resultOptions }
            if ($record.status -ceq 'failed') { return New-AgentTeamsThreadResult failed $record.code @resultOptions }
        }
        if ($null -ne $SharedAuthority) {
            if ($SharedAuthority.Mode -ceq 'reply') {
                if (-not (Test-AgentTeamsOpaqueId $SharedAuthority.RootId)) { throw 'Invalid shared root authority.' }
                $state.schemaVersion = 2
                $state.rootMessageId = $SharedAuthority.RootId
                $state.rootProvenance = 'shared-reference'
                Write-AgentTeamsThreadState $context $state
                if ($record -and $record.status -ceq 'not-sent') { $record.kind = 'reply' }
            }
            elseif ($SharedAuthority.Mode -cne 'bootstrap' -or $state.rootMessageId) {
                return New-AgentTeamsThreadResult deferred bootstrap-local-root-changed @resultOptions
            }
        }
        if (-not $state.rootMessageId -and @($state.records.Values | Where-Object {
                    $_.kind -ceq 'root' -and $_.status -cin @('pending', 'unknown')
                }).Count -gt 0) {
            return New-AgentTeamsThreadResult unknown root-unknown @resultOptions
        }
        if ($null -eq $record) {
            if ($state.records.Count -ge 256) { return New-AgentTeamsThreadResult failed state-capacity @resultOptions }
            $record = @{
                role = $Role; notificationEvent = $NotificationEvent; sourceCommitHash = $sourceHash
                kind = $(if ($state.rootMessageId) { 'reply' } else { 'root' })
                status = 'not-sent'; messageId = ''; attempts = 0; retryNotBefore = 0L; code = 'deadline'
            }
            $state.records[$eventKey] = $record
        }
        elseif ($record.kind -ceq 'root' -and $state.rootMessageId) {
            # A definitely unsent root can become a reply if a different event
            # created the canonical root while this one was throttled.
            $record.kind = 'reply'
        }
        $resultOptions.Operation = $record.kind
        $messagesPath = "/teams/$([Uri]::EscapeDataString($TeamId))/channels/$([Uri]::EscapeDataString($ChannelId))/messages"
        $html = New-AgentTeamsMessageHtml -Title $Title -Body $Body -Links $Links
        if ($SharedAuthority -and $SharedAuthority.Mode -ceq 'bootstrap') { $html = $SharedAuthority.RootPrefix + $html }
        while ($true) {
            if ($record.attempts -ge 3) { return New-AgentTeamsThreadResult deferred attempt-limit @resultOptions }
            if ($record.code -ceq 'throttled-metadata-unavailable') {
                return New-AgentTeamsThreadResult deferred throttled-metadata-unavailable @resultOptions
            }
            $waitMilliseconds = [Math]::Max(0.0, $record.retryNotBefore * 1000.0 - [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
            if ([DateTime]::UtcNow.AddMilliseconds($waitMilliseconds) -ge $deadline) {
                return New-AgentTeamsThreadResult deferred $(if ($waitMilliseconds -gt 0) { 'throttled' } else { 'deadline' }) @resultOptions
            }
            if ($waitMilliseconds -gt 0) { Start-Sleep -Milliseconds ([int][Math]::Ceiling($waitMilliseconds)) }
            if ([DateTime]::UtcNow -ge $deadline) { return New-AgentTeamsThreadResult deferred deadline @resultOptions }
            $path = $messagesPath
            if ($record.kind -ceq 'reply') { $path += "/$([Uri]::EscapeDataString($state.rootMessageId))/replies" }
            $record.attempts++
            $record.status = 'pending'
            $record.code = 'intent'
            $record.retryNotBefore = 0L
            Write-AgentTeamsThreadState $context $state
            $sendMayHaveLanded = $true
            $response = $null
            $httpStatus = 0
            $retryAfter = $null
            try {
                $response = Invoke-AgentWorkIqTool -Session $Session -Name create_entity -AllowedTools @('create_entity') `
                    -AllowedPathPrefixes @($path) -Arguments @{
                        parentUrl = $path; jsonBody = @{ body = @{ contentType = 'html'; content = $html } }
                    } -DeadlineUtc $deadline
            }
            catch {
                if ($_.Exception.Data.Contains('WorkIqStatusCode') -and
                    (Test-StrictJsonInt $_.Exception.Data['WorkIqStatusCode'] -Min 100 -Max 599)) {
                    $httpStatus = [int]$_.Exception.Data['WorkIqStatusCode']
                    $retryAfter = $_.Exception.Data['WorkIqRetryAfter']
                }
            }
            # Only explicit rejections are known not to have landed. Server
            # errors, timeouts, lost acknowledgements and malformed 2xx remain
            # unknown; never blindly repeat or independently fall back.
            if ($httpStatus -eq 429) {
                $sendMayHaveLanded = $false
                $record.status = 'not-sent'
                $retryNotBefore = Get-AgentTeamsRetryNotBefore $retryAfter
                $record.code = $(if ($null -eq $retryNotBefore) { 'throttled-metadata-unavailable' } else { 'throttled' })
                $record.retryNotBefore = $(if ($null -eq $retryNotBefore) { 0L } else { $retryNotBefore })
                Write-AgentTeamsThreadState $context $state
                continue
            }
            if (-not $SharedAuthority -and $httpStatus -in @(404, 410) -and $record.kind -ceq 'reply') {
                $sendMayHaveLanded = $false
                $record.kind = 'fallback'
                $record.status = 'not-sent'
                $record.code = 'stale-root'
                $resultOptions.Operation = 'fallback'
                $transition = New-AgentTeamsThreadResult fallback-pending stale-root @resultOptions
                foreach ($entry in $transition.Audit) { $resultOptions.AuditHistory.Add($entry) }
                Write-AgentTeamsThreadState $context $state
                continue
            }
            if ($httpStatus -ge 400 -and $httpStatus -le 499 -and $httpStatus -ne 408) {
                $sendMayHaveLanded = $false
                $record.status = 'failed'
                $record.code = 'http-rejected'
                Write-AgentTeamsThreadState $context $state
                return New-AgentTeamsThreadResult failed http-rejected @resultOptions
            }
            $messageId = Get-AgentTeamsConfirmedMessageId $response $context $record.kind $state.rootMessageId
            if (-not $messageId) {
                $record.status = 'unknown'
                $record.code = 'send-unknown'
                Write-AgentTeamsThreadState $context $state
                return New-AgentTeamsThreadResult unknown send-unknown @resultOptions
            }
            $record.status = 'delivered'
            $record.messageId = $messageId
            $record.code = 'confirmed'
            if ($record.kind -ceq 'root') {
                $state.rootMessageId = $messageId
                if ($state.schemaVersion -eq 2) { $state.rootProvenance = 'local' }
            }
            Write-AgentTeamsThreadState $context $state
            $outcome = switch ($record.kind) {
                root { 'root-created' }
                reply { 'reply-delivered' }
                fallback { 'fallback-delivered' }
            }

            return New-AgentTeamsThreadResult $outcome confirmed $messageId @resultOptions
        }
    }
    catch {
        # Never include provider prose, notification content, state paths or
        # identity data in the audit/exception surface.
        if ($sendMayHaveLanded) { return New-AgentTeamsThreadResult unknown persistence-unknown @resultOptions }
        return New-AgentTeamsThreadResult failed state-unavailable @resultOptions
    }
    finally { if ($lock -and $lock.Acquired) { Exit-AgentLock $lock.Stream } }
}

function Send-AgentTeamsThreadedChannelMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][string]$DurableStateRoot,
        [Parameter(Mandatory)]$RepositoryIdentity,
        [Parameter(Mandatory)][ValidateSet('reviewer', 'review-handler')][string]$Role,
        [Parameter(Mandatory)][ValidatePattern('\A[a-zA-Z][a-zA-Z0-9-]{0,63}\z')][string]$NotificationEvent,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$PullRequestId,
        [Parameter(Mandatory)][AllowEmptyString()][ValidatePattern('\A[0-9A-Za-z._-]{0,128}\z')][string]$SourceCommit,
        [Parameter(Mandatory)][string]$TeamId, [Parameter(Mandatory)][string]$ChannelId,
        [Parameter(Mandatory)][ValidateLength(1, 4096)][string]$Title,
        [Parameter(Mandatory)][ValidateLength(1, 24576)][string]$Body,
        [string[]]$Links = @(), [string]$PullRequestUrl = '',
        [Nullable[DateTime]]$DeadlineUtc, [AllowNull()][hashtable]$OutputContext,
        [AllowNull()][hashtable]$ReferenceContext, [switch]$PreviewOnly
    )
    if ($PreviewOnly) {
        return New-AgentTeamsThreadResult deferred preview -OutputContext $OutputContext -PullRequestId $PullRequestId
    }
    if ($null -ne $ReferenceContext) { return Send-AgentTeamsSharedChannelMessage @PSBoundParameters }
    $arguments = @{} + $PSBoundParameters
    foreach ($name in @('ReferenceContext', 'PreviewOnly', 'PullRequestUrl')) { $arguments.Remove($name) }
    return Invoke-AgentTeamsLocalChannelMessage @arguments
}
